
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHook, IUMA} from "./UMA.sol";
import {Basket} from "./Basket.sol";
import {Types} from "./imports/Types.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
/// @title N-outcome LSMR for "which stablecoin depegs this week"
/// @notice Side 0 = "none depegs". Sides 1..N = each stablecoin.
/// Single market, weekly rounds. Time decay rewards early signal.
/// Rollover positions recommit each round for fresh LMSR entry.
contract Hook is IHook { Types.Market internal _market;
    uint public constant FEE_BPS = 400; // 4% on fresh orders
    uint public constant ROLLOVER_FEE_BPS = 200; // 2% on recommit
    uint public constant MIN_ORDER = 1e18; // 1 QD (18 decimals)
    uint public constant CONSOLATION_BPS = 2000; // 20% to losers
    uint public constant REVEAL_WINDOW = 48 hours;
    int128  public constant INITIAL_B = 10_000e18;
    /// @dev decay lambda for 12-outcome weekly market.
    /// Derived from: λ_base(5) × complexity_adj(0.774)
    /// × duration_factor(0.327) = 1.265, scaled ×100 → 127.
    /// Falls in the linear-quadratic blend zone (100 < λ ≤ 200):
    /// t = 26 → 74% linear + 26% quadratic
    /// Full week (100% participation) → 100% weight
    /// Mid-week entry (50%) → ~43% weight
    /// Day 5 entry  (29%) → ~23% weight
    /// Last minute (~0%) → 10% floor
    struct RevealEntry { uint confidence; bytes32 salt; }
    Basket public immutable QUID; IUMA public immutable UMA;
    uint public constant DECAY_FLOOR = 1000; // 10% min. weight
    uint constant NEUTRAL_CONFIDENCE = 5000; // fifty-fifty
    uint public constant LAMBDA = 127; // same as liveness
    uint constant WAD = 1e18;

    mapping(address => uint8) public stablecoinToSide;
    mapping(address => mapping(uint8 => Types.Position)) internal _positions;
    mapping(address => mapping(uint8 => Types.PositionEntry[])) internal _entries;

    /// @dev Parallel freeze counters — replace single-assertion bools.
    /// Trading blocked when pendingAssertions > 0.
    /// Sells also blocked when pendingDisputes > 0.
    uint public pendingAssertions;
    uint public pendingDisputes;
    uint public accumulatedFees;

    /// @dev Σ(confidence × capital) per side
    /// this round, accumulated during reveals
    uint[12] internal _confCapAccum;
    /// @dev Total revealed capital per side this round
    uint[12] internal _revealedCapPerSide;
    /// @dev Last round's average confidence
    /// per side — used as Bayesian prior in calcRisk
    uint[12] internal _lastRoundAvgConf;

    event OrderPlaced(address indexed user, uint8 side, uint capital, uint tokens);
    event PositionSold(address indexed user, uint8 side, uint tokens, uint returned);
    event ConfidenceRevealed(address indexed user, uint8 side, uint confidence);
    event PayoutPushed(address indexed user, uint8 side, uint amount);
    event Recommitted(address indexed user, uint8 side, uint tokens);
    event MarketCreated(uint8 numSides); event WeightsCalculated();

    error OnlyUMA(); error InvalidSide(uint8 side, uint8 max);
    error StalePosition(uint posRound, uint mktRound);
    error OrderTooSmall(uint amount, uint minimum);
    constructor(address _uma, address _quid) {
        UMA  = IUMA(_uma); QUID = Basket(_quid);
    }

    function createMarket(address[] calldata stables) external {
        require(msg.sender == address(QUID)
             || msg.sender == address(UMA));

        uint8 numSides = uint8(stables.length) + 1;
        require(numSides <= 12, "too many sides");
        require(_market.numSides == 0, "exists");

        _market.numSides = numSides;
        _market.startTime = block.timestamp;
        _market.roundStartTime = block.timestamp;
        _market.b = INITIAL_B; _market.roundNumber = 1;

        for (uint8 i; i < stables.length; i++)
            stablecoinToSide[stables[i]] = i + 1;

        emit MarketCreated(numSides);
    }

    modifier onlyUMA() {
        if (msg.sender != address(UMA))
            revert OnlyUMA(); _; }

    function trigger(uint timestamp,
        uint8 winningSide) external
        override onlyUMA {
        require(winningSide < _market.numSides, "invalid side");
        _market.resolved = true; _market.winningSide = winningSide;
        _market.resolutionTimestamp = timestamp;
        _market.revealDeadline = block.timestamp + REVEAL_WINDOW;
        if (pendingAssertions > 0) pendingAssertions--;
    }

    function onAssertionFiled() external override onlyUMA {
        pendingAssertions++;
    }

    function onDisputeStarted() external override onlyUMA {
        pendingDisputes++;
    }

    function onAssertionRejected() external override onlyUMA {
        if (pendingAssertions > 0) pendingAssertions--;
    }

    function onDisputeEnded() external override onlyUMA {
        if (pendingDisputes > 0) pendingDisputes--;
    }

    function paid() external view override returns (bool) {
        return _market.payoutsComplete;
    }

    /// @notice Resets market-level state for a new round.
    /// Individual positions are NOT iterated. Stale positions
    /// are gated by lastRound checks on every interaction.
    function resetForNewRound() external override onlyUMA {
        for (uint8 side; side < _market.numSides; side++) {
            uint revealedCapital = _revealedCapPerSide[side];
            if (revealedCapital > 0)
                _lastRoundAvgConf[side] = _confCapAccum[side] / revealedCapital;
            else
                _lastRoundAvgConf[side] = 0;
            _confCapAccum[side] = 0;
            _revealedCapPerSide[side] = 0;
        }
        _market.resolved = false;
        _market.winningSide = 0;
        _market.resolutionTimestamp = 0;
        _market.totalCapital = 0;
        _market.positionsTotal = 0;
        _market.positionsRevealed = 0;
        _market.positionsPaidOut = 0;
        _market.positionsWeighed = 0;
        _market.totalWinnerCapital = 0;
        _market.totalLoserCapital = 0;
        _market.totalWinnerWeight = 0;
        _market.totalLoserWeight = 0;
        _market.weightsComplete = false;
        _market.payoutsComplete = false;
        _market.revealDeadline = 0;
        pendingAssertions = 0;
        pendingDisputes = 0;

        delete _market.q;
        delete _market.capitalPerSide;

        _market.roundStartTime = block.timestamp;
        _market.roundNumber++;
    }

    function getMarketCapital() external view
        override returns (uint) {
        return _market.totalCapital;
    }

    /// @dev Convert gas used to QD via ETH TWAP
    function _gasToQD(uint gasUsed) internal
        view returns (uint) { if (gasUsed == 0) return 0;
        return FullMath.mulDiv(gasUsed * block.basefee,
                       QUID.AUX().getTWAP(0), WAD);
    }

    /// @dev Swap QD → ETH via Aux and forward to keeper.
    /// Fallback: transfer QD directly if swap fails...
    function _reimburseKeeper(uint qdAmount) internal {
        if (qdAmount == 0) return;
        uint ethBefore = address(this).balance;
        try QUID.AUX().swap{value: 0}(address(QUID), true, qdAmount, 0) {
            uint got = address(this).balance - ethBefore;
            if (got > 0) {
                (bool ok,) = msg.sender.call{value: got}("");
                if (!ok) {} // swallowed — keeper missed ETH but protocol OK
            }
        } catch {
            uint qdBal = QUID.balances(address(this));
            if (qdBal < qdAmount) qdAmount = qdBal;
            if (qdAmount > 0) QUID.transfer(msg.sender, qdAmount);
        }
    }
    receive() external payable {}

    function placeOrder(uint8 side, uint capital,
        bool autoRollover, bytes32 commitHash, address delegate) external {
        if (side >= _market.numSides) revert InvalidSide(side, _market.numSides);
        if (capital < MIN_ORDER) revert OrderTooSmall(capital, MIN_ORDER);
        require(commitHash != bytes32(0), "commit required");

        require(!_market.resolved, "resolved");
        require(pendingDisputes == 0, "dispute pending");
        require(pendingAssertions == 0, "assertion pending");
        QUID.transferFrom(msg.sender, address(this), capital);

        uint fee = (capital * FEE_BPS) / 10000;
        uint netCapital = capital - fee;
        accumulatedFees += fee;
        uint tokens = _buyTokens(_market, side, netCapital);

        Types.Position storage position = _positions[msg.sender][side];
        if (position.user == address(0)) {
            position.user = msg.sender; position.side = side;
            position.lastRound = _market.roundNumber;
            _market.positionsTotal++;
        } else if (position.lastRound < _market.roundNumber) {
            uint staleCapital = position.totalCapital;
            if (staleCapital > 0)
                QUID.transfer(msg.sender, staleCapital);

            position.totalCapital = 0;
            position.totalTokens = 0;
            position.lastRound = _market.roundNumber;
            position.revealed = false;
            position.revealedConfidence = 0;
            position.weight = 0;
            position.paidOut = false;
            _market.positionsTotal++;
            delete _entries[msg.sender][side];
        }
        position.delegate = delegate;
        position.totalCapital += netCapital;
        position.totalTokens += tokens;
        position.autoRollover = autoRollover;
        position.entryTimestamp = block.timestamp;

        _entries[msg.sender][side].push(Types.PositionEntry({
            capital: netCapital, tokens: tokens,
            commitmentHash: commitHash,
            timestamp: block.timestamp,
            revealedConfidence: 0 }));

        _market.totalCapital += netCapital;
        _market.capitalPerSide[side] += netCapital;
        emit OrderPlaced(msg.sender, side, netCapital, tokens);
    }

    /// @notice Sell tokens back to the LMSR curve.
    /// returned = LMSR refund (can be > or < capitalReduced).
    /// Any LMSR loss (capitalReduced > returned) goes to accumulatedFees
    /// so no phantom QD accumulates in the contract.
    function sellPosition(uint8 side,
        uint tokensToSell) external {
        require(!_market.resolved, "resolved");
        require(pendingDisputes == 0, "dispute pending");
        require(pendingAssertions == 0, "assertion pending");
        Types.Position storage position = _positions[msg.sender][side];

        if (position.lastRound != _market.roundNumber)
            revert StalePosition(position.lastRound, _market.roundNumber);
        require(position.totalTokens >= tokensToSell);

        uint returned = _sellTokens(_market, side, tokensToSell);
        uint capitalReduced;
        {
            Types.PositionEntry[] storage entries = _entries[msg.sender][side];
            uint length = entries.length;
            uint[] memory oldCapitals = new uint[](length);
            uint[] memory oldTokens = new uint[](length);
            for (uint index; index < length; index++) {
                oldCapitals[index] = entries[index].capital;
                oldTokens[index] = entries[index].tokens;
            }
            uint[] memory newCapitals; uint[] memory newTokens;
            (newCapitals, newTokens, capitalReduced) = UMA.reduceEntries(
                oldCapitals, oldTokens, tokensToSell, position.totalTokens);
            uint writeIndex;
            for (uint index; index < length; index++) {
                if (newTokens[index] == 0) continue;
                if (writeIndex != index) entries[writeIndex] = entries[index];
                entries[writeIndex].capital = newCapitals[index];
                entries[writeIndex].tokens  = newTokens[index];
                writeIndex++;
            }
            while (entries.length > writeIndex) entries.pop();
        }
        position.totalTokens  -= tokensToSell;
        position.totalCapital -= capitalReduced;
        _market.totalCapital  -= capitalReduced;
        _market.capitalPerSide[side] -= capitalReduced;
        if (position.totalTokens == 0) _market.positionsTotal--;

        // LMSR loss: user gets less than their entry cost removed.
        // Difference stays in contract — route to fees so it's tracked.
        if (capitalReduced > returned)
            accumulatedFees += capitalReduced - returned;

        // Solvency cap: never pay more than Hook actually holds
        uint balance = QUID.balances(address(this));
        if (returned > balance) returned = balance;

        QUID.transfer(msg.sender, returned);
        emit PositionSold(msg.sender, side, tokensToSell, returned);
    }

    /// @notice Reveal + compute weight in one pass.
    /// Stale autoRollover: enter LMSR, auto-reveal NEUTRAL.
    /// Fresh commits: verify reveals from keeper (MongoDB).
    /// Zero-hash entries: auto-reveal NEUTRAL.
    /// Gas reimbursed from accumulatedFees.
    /// @param reveals Flat array of {confidence, salt} for committed entries
    /// @param revealCounts Per-user count — 0 for pure rollover / already revealed
    function calculateWeights(address[] calldata users, uint8[] calldata sides,
        RevealEntry[] calldata reveals, uint[] calldata revealCounts)
        external { uint gasStart = gasleft();
        require(_market.resolved);
        require(users.length == sides.length, "length mismatch");
        require(users.length == revealCounts.length, "length mismatch");
        require(_market.positionsPaidOut == 0, "payouts started");
        require(block.timestamp >= _market.revealDeadline, "reveal window open");
        uint revealCursor;

        for (uint index; index < users.length; index++) {
            address user = users[index]; uint8 side = sides[index];
            Types.Position storage position = _positions[user][side];

            if (position.weight > 0 || position.paidOut) {
                revealCursor += revealCounts[index]; continue; }

            // ── Stale autoRollover: create entry for weight calculation ──
            // Fee already deducted in pushPayouts when capital was retained.
            // No _buyTokens: computeWeight uses capitals/timestamps, not tokens.
            // _market.q is deleted on resetForNewRound anyway.
            if (position.lastRound < _market.roundNumber) {
                if (!position.autoRollover || position.totalCapital == 0) {
                    revealCursor += revealCounts[index]; continue; }

                uint capital = position.totalCapital;
                position.totalTokens = 0;
                position.lastRound = _market.roundNumber;
                position.revealed = false;
                position.revealedConfidence = 0;
                position.weight = 0; position.paidOut = false;
                position.entryTimestamp = _market.roundStartTime;

                _market.totalCapital += capital;
                _market.capitalPerSide[side] += capital;
                _market.positionsTotal++;

                delete _entries[user][side];
                _entries[user][side].push(Types.PositionEntry({
                    capital: capital, tokens: 0,
                    commitmentHash: bytes32(0),
                    timestamp: _market.roundStartTime,
                    revealedConfidence: 0 }));

                emit Recommitted(user, side, capital);
            }
            if (position.lastRound != _market.roundNumber) {
                revealCursor += revealCounts[index]; continue; }

            if (!position.revealed) {
                uint count = revealCounts[index];
                uint start = revealCursor; revealCursor += count;
                _revealPosition(user, side, reveals, start, count);
            } else { revealCursor += revealCounts[index]; }

            bool isWinner = side == _market.winningSide; uint weight;
            { Types.PositionEntry[] storage entries = _entries[user][side];
                uint length = entries.length;
                uint[] memory capitals = new uint[](length);
                uint[] memory timestamps = new uint[](length);
                for (uint entry; entry < length; entry++) {
                    capitals[entry] = entries[entry].capital;
                    timestamps[entry] = entries[entry].timestamp;
                }
                weight = UMA.computeWeight(capitals, timestamps,
                    _market.roundStartTime, _market.resolutionTimestamp,
                    LAMBDA, DECAY_FLOOR, position.revealedConfidence, isWinner);
            }
            if (weight == 0) {
                position.paidOut = true;
                _market.positionsPaidOut++;
                _market.positionsWeighed++;
                emit PayoutPushed(user, side, 0);
                continue;
            }
            position.weight = weight;
            if (isWinner) _market.totalWinnerWeight += weight;
            else _market.totalLoserWeight += weight;
            _market.positionsWeighed++;
        }
        if (_market.positionsWeighed >= _market.positionsRevealed)
            _market.weightsComplete = true;

        // Reimburse keeper from protocol fees
        uint gasCost = _gasToQD(gasStart - gasleft() + 21000);
        uint qdBal = QUID.balances(address(this));
        if (gasCost > qdBal) gasCost = qdBal;
        if (gasCost > 0 && gasCost <= accumulatedFees) {
            accumulatedFees -= gasCost;
            _reimburseKeeper(gasCost);
        }
        emit WeightsCalculated();
    }

    /// @notice Push payouts in one pass. Rollover positions retain
    /// capital (minus fee) for next round's LMSR entry.
    /// Gas reimbursed from accumulatedFees.
    function pushPayouts(address[] calldata users,
        uint8[] calldata sides) external {
        uint gasStart = gasleft();
        require(_market.weightsComplete);
        require(_market.positionsWeighed == _market.positionsRevealed,
            "weights not finalized");

        uint winnerWeight = _market.totalWinnerWeight;
        uint loserWeight = _market.totalLoserWeight;
        uint loserCapital = _market.totalLoserCapital;

        uint8 winner = _market.winningSide;
        uint roundNum = _market.roundNumber;

        for (uint index; index < users.length; index++) {
            address user = users[index]; uint8 side = sides[index];
            Types.Position storage position = _positions[user][side];
            if (position.paidOut) continue;
            if (position.lastRound != roundNum) continue;
            if (position.weight == 0) continue;

            position.paidOut = true;
            _market.positionsPaidOut++;

            uint payout = UMA.computePayout(
                position.totalCapital, position.weight,
                winnerWeight, loserWeight,
                loserCapital, CONSOLATION_BPS,
                side == winner);

            uint balance = QUID.balances(address(this));
            if (payout > balance) payout = balance;
            if (position.autoRollover) {
                // Retain for next round, deduct rollover fee on capital.
                // Fee is on original stake, not on winnings.
                // LMSR entry deferred to calculateWeights.
                uint fee = (position.totalCapital * ROLLOVER_FEE_BPS) / 10000;
                if (fee >= payout) fee = 0; // don't eat entire payout
                accumulatedFees += fee;
                position.totalCapital = payout - fee;
                position.totalTokens = 0;
                position.revealed = false;
                position.revealedConfidence = 0;
                position.weight = 0;
                position.paidOut = false;
                delete _entries[user][side];
            } else {
                QUID.transfer(user, payout);
            }
            emit PayoutPushed(user, side, payout);
        }

        if (_market.positionsPaidOut >= _market.positionsRevealed)
            _market.payoutsComplete = true;

        // Reimburse keeper from protocol fees
        uint gasCost = _gasToQD(gasStart - gasleft() + 21000);
        uint qdBal = QUID.balances(address(this));
        if (gasCost > qdBal) gasCost = qdBal;
        if (gasCost > 0 && gasCost <= accumulatedFees) {
            accumulatedFees -= gasCost;
            _reimburseKeeper(gasCost);
        }
    }

    function settleAssertion() external {
        UMA.settleAssertion();
    }

    function depegPending() external view returns (bool) {
        return _market.resolved && _market.winningSide > 0;
    }

    /// @notice Burn accumulated prediction market fees.
    function burnAccumulatedFees() external {
        require(!_market.resolved
        || _market.payoutsComplete);
        uint fees = accumulatedFees;
        require(fees > 0); accumulatedFees = 0;
        QUID.turn(address(this), fees);
    }

    function getLMSRPrice(uint8 side)
        external view returns (uint) {
        return FeeLib.price(_market.q,
        _market.numSides, _market.b, side);
    }

    function getLMSRCost(uint8 side, int128 delta)
        external view returns (uint) {
        return FeeLib.cost(_market.q, _market.numSides,
                              _market.b, side, delta);
    }

    /// @dev Reveal entries for a position. Extracted to avoid stack-too-deep.
    function _revealPosition(address user, uint8 side,
        RevealEntry[] calldata reveals, uint start, uint count) internal {
        Types.Position storage position = _positions[user][side];
        Types.PositionEntry[] storage entries = _entries[user][side];
        uint cursor; uint weightedConfidenceSum;

        for (uint entry; entry < entries.length; entry++) {
            if (entries[entry].commitmentHash == bytes32(0)) {
                entries[entry].revealedConfidence = NEUTRAL_CONFIDENCE;
                weightedConfidenceSum += entries[entry].capital * NEUTRAL_CONFIDENCE;
            } else {
                require(cursor < count, "not enough reveals");
                RevealEntry calldata reveal = reveals[start + cursor];
                require(reveal.confidence >= 100 && reveal.confidence <= 10000
                        && reveal.confidence % 100 == 0, "bad confidence");

                require(keccak256(abi.encodePacked(reveal.confidence, reveal.salt))
                        == entries[entry].commitmentHash, "hash mismatch");

                entries[entry].revealedConfidence = reveal.confidence;
                weightedConfidenceSum += entries[entry].capital * reveal.confidence;
                cursor++;
            }
        } require(cursor == count, "extra reveals");

        uint averageConfidence = position.totalCapital > 0
            ? weightedConfidenceSum / position.totalCapital
            : NEUTRAL_CONFIDENCE;

        position.revealed = true;
        position.revealedConfidence = averageConfidence;
        _market.positionsRevealed++;

        _confCapAccum[side] += position.totalCapital * averageConfidence;
        _revealedCapPerSide[side] += position.totalCapital;

        if (side == _market.winningSide)
            _market.totalWinnerCapital += position.totalCapital;
        else
            _market.totalLoserCapital += position.totalCapital;

        emit ConfidenceRevealed(user, side, averageConfidence);
    }

    function _buyTokens(Types.Market storage market,
        uint8 side, uint netCapital) internal
        returns (uint tokens) { int128 deltaQ;
        (tokens, deltaQ) = UMA.buyTokens(market.q,
            market.numSides, market.b, side, netCapital);
            market.q[side] += deltaQ;
    }

    function _sellTokens(Types.Market storage market, uint8 side, uint tokensToSell)
        internal returns (uint returned) { int128 deltaQ;
        (returned, deltaQ) = UMA.sellTokens(market.q,
                market.numSides, market.b, side, tokensToSell);
                market.q[side] -= deltaQ;
    }

    function getMarket() external
        view returns (Types.Market memory) { return _market; }
    function getPosition(address user, uint8 side) external
        view returns (Types.Position memory) {
            return _positions[user][side];
    }

    function getPositionEntries(address user, uint8 side) external
        view returns (Types.PositionEntry[] memory) {
            return _entries[user][side];
    }

    function getDepegStats(address stablecoin) external
        view returns (Types.DepegStats memory stats) {
        uint8 side = stablecoinToSide[stablecoin];
        if (side == 0) return stats;
        if (_market.numSides == 0) return stats;

        stats.capOnSide = _market.capitalPerSide[side];
        stats.capNone = _market.capitalPerSide[0];
        stats.capTotal = _market.totalCapital;

        stats.depegged = _market.resolved && _market.winningSide == side;
        stats.avgConf = _lastRoundAvgConf[side]; stats.side = side;
    }

    function getAllPrices() external view
        returns (uint[] memory prices) {
        prices = new uint[](_market.numSides);
        for (uint8 i; i < _market.numSides; i++)
            prices[i] = FeeLib.price(_market.q,
                _market.numSides, _market.b, i);
    }

    function getCapitalPerSide() external
        view returns (uint[12] memory) {
        return _market.capitalPerSide;
    }

    function getRoundStartTime() external
        view returns (uint) {
        return _market.roundStartTime;
    }
}
