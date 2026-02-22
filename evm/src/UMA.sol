
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Types} from "./imports/Types.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptimisticOracleV3Interface} from "./imports/OOV3Interface.sol";

interface IHook {
    function trigger(uint timestamp, uint8 winningSide) external;
    function onAssertionFiled() external;
    function onDisputeStarted() external;
    function onAssertionRejected() external;
    function onDisputeEnded() external;
    function paid() external view returns (bool);
    function resetForNewRound() external;
    function getRoundStartTime() external view returns (uint);
    function getMarketCapital() external view returns (uint);
}

/// @dev Hook calls these pure math functions on UMA via STATICCALL.
///      LMSR internals (cost, exp) inline from BasketLib into UMA's bytecode.
interface IUMA { function settleAssertion() external;
    function getAssertionInfo() external view returns
    (uint8 phase, uint8 claimedSide, uint round, uint8 rejections);
    function buyTokens(int128[12] memory q, uint8 numSides, int128 b, uint8 side, uint netCap) external pure returns (uint tokens, int128 deltaQ);
    function sellTokens(int128[12] memory q, uint8 numSides, int128 b, uint8 side, uint tokSell) external pure returns (uint returned, int128 deltaQ);
    function computeWeight(uint[] memory capitals, uint[] memory timestamps, uint roundStart, uint resTs, uint lambda, uint floor, uint confidence, bool isWinner) external pure returns (uint);
    function computePayout(uint capital, uint weight, uint totalWinWeight, uint totalLoseWeight, uint totalLoserCap, uint consolBps, bool isWinner) external pure returns (uint);
    function reduceEntries(uint[] memory capitals, uint[] memory tokens, uint tokensToSell, uint totalTokens) external pure returns (uint[] memory, uint[] memory, uint);
}

/// @title UMA — OOV3 phase machine for single depeg market
/// @notice Weekly rounds. Asserter claims which side won.
///         Parallel assertions: multiple claimants can file simultaneously.
///         First confirmed assertion wins. Side 0 ("none depegged") is
///         decoupled from OOV3 — uses a permissionless timeout via resolveAsNone().
///         Caller funds the bond via transferFrom — returned on success,
///         lost on rejection. Escalating bond makes griefing exponentially expensive.
contract UMA is Ownable {
    uint public constant LIVENESS = 127 hours;
    uint public constant REVEAL_WINDOW = 48 hours;
    uint public constant BOND_FLOOR = 100e6; // $100 in USDC (6 dec)
    uint public constant BOND_CEILING = 10_000e6; // $10k in USDC (6 dec)

    uint public constant MAX_PARALLEL_ASSERTIONS = 12;
    IERC20 public immutable BOND_TOKEN;
    uint public constant BOND_BPS = 1;
    uint8 constant MAX_SIDES = 12;
    uint constant WAD = 1e18;

    OptimisticOracleV3Interface public immutable OO;
    address public FORWARDER; // CRE KeystoneForwarder
    IHook public HOOK; address public QUID; // Basket
    bool public marketRegistered;
    Types.Market internal market;

    // ═══════════════════════════════════════════════════════════════
    //  Parallel assertion tracking
    //  Multiple asserters can file claims simultaneously.
    //  First confirmed assertion resolves the market.
    //  Rejected assertions decrement the counter; when all are
    //  rejected the market returns to Trading and Hook unfreezes.
    // ═══════════════════════════════════════════════════════════════
    struct AssertionContext {
        address asserter;       // who funded the bond
        uint8   claimedSide;    // 1..N (never 0 — that uses resolveAsNone)
        uint    bond;           // amount transferred from asserter
        uint    requestTimestamp;
        uint    round;          // which market round this belongs to
        bool    disputed;       // set by assertionDisputedCallback
    }
    mapping(bytes32 => AssertionContext) public assertions;
    bytes32[] public pendingAssertionIds;
    uint public activeAssertionCount;
    /// @dev round → side → assertionId. Prevents duplicate per side per round.
    /// Cleared on rejection (re-opens the side). Scoped by round.
    mapping(uint => mapping(uint8 => bytes32)) public sideAssertionId;

    error WrongPhase(Types.Phase actual, Types.Phase expected);
    mapping(bytes32 => Types.ForensicEvidence) public evidence;
    mapping(bytes32 => bool) public evidenceSubmitted;

    uint public watchdogDisputeCount;
    uint8 public minConfidence = 80;
    error NotQUID(); error NotOO();
    error InvalidSide(uint8, uint8);
    error NotForwarder();

    event MarketRegistered(uint8 numSides);
    event ResolutionRequested(bytes32 assertionId,
                    uint8 claimedSide, uint bond);

    event AssertionDisputed();
    event AssertionSettled(
    uint8 winningSide, bool truthful);
    event MarketRestarted(uint round);
    event DisputeForensicsRequested(
        bytes32 indexed assertionId,
        uint8 claimedSide,
        uint requestTimestamp
    );

    event ForensicEvidenceStored(
        bytes32 indexed assertionId,
        uint8 recommendedSide,
        uint8 confidence
    );
    event WatchdogDispute(
        bytes32 indexed assertionId,
        uint8 claimedSide, uint8 recommendedSide,
        int maxDeviationBps, uint8 confidence, bytes32 evidenceHash
    );

    event WatchdogSkipped(bytes32 indexed assertionId, string reason);
    modifier onlyQUID() { if (msg.sender != QUID) revert NotQUID(); _; }
    modifier onlyOO() { if (msg.sender != address(OO)) revert NotOO(); _; }

    modifier onlyForwarder() {
        if (msg.sender != FORWARDER)
            revert NotForwarder(); _; }

    modifier inPhase(Types.Phase p) {
        if (market.phase != p)
            revert WrongPhase(market.phase, p); _;
    }

    constructor(address _oo, address _bond)
        Ownable(msg.sender) {
        OO = OptimisticOracleV3Interface(_oo);
        BOND_TOKEN = IERC20(_bond);
    }

   /// @dev Set the CRE KeystoneForwarder address.
   /// Callable once by owner. Deploy UMA first, then set
   /// forwarder when Chainlink publishes the mainnet address.
   function setForwarder(address _f) external onlyOwner {
       require(FORWARDER == address(0), "already set");
       require(_f != address(0), "zero address");
       FORWARDER = _f;
   }

    /// @dev onlyOwner prevents frontrunning during deployment.
    function setQUID(address _q) external onlyOwner { require(QUID == address(0)); QUID = _q; }
    function setHook(address _h) external onlyOwner { require(address(HOOK) == address(0)); HOOK = IHook(_h); }
    function registerMarket(address[] calldata stables) external onlyQUID {
        require(!marketRegistered, "exists");
        marketRegistered = true;
        uint8 n = uint8(stables.length);
        market.numSides = n + 1;
        market.phase = Types.Phase.Trading;
        market.roundNumber = 1;
        emit MarketRegistered(market.numSides);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Side 0 resolution — permissionless timeout, no OOV3
    //  "None depegged" is the default outcome when a full round
    //  passes without a depeg claim. Anyone can trigger after
    //  MONTH elapsed from round start. No bond needed.
    // ═══════════════════════════════════════════════════════════════

    /// @notice Resolve as "none depegged" — permissionless timeout.
    /// Callable by anyone once MONTH has elapsed since round start.
    /// Bypasses OOV3 entirely since side 0 is the default/null outcome.
    function resolveAsNone() external inPhase(Types.Phase.Trading) {
        require(block.timestamp >=
            HOOK.getRoundStartTime() + FeeLib.MONTH,
            "round not mature");

        market.phase = Types.Phase.Resolved;
        market.winningSide = 0;
        market.revealDeadline = block.timestamp + REVEAL_WINDOW;
        market.consecutiveRejections = 0;

        HOOK.trigger(block.timestamp, 0);
        emit AssertionSettled(0, true);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Depeg assertions (side > 0) — OOV3 backed, caller-funded
    //  Multiple assertions can coexist. First confirmed wins.
    //  Bond pulled from msg.sender → returned on success, lost on
    //  rejection. Escalating bond after consecutive rejections makes
    //  griefing exponentially expensive.
    // ═══════════════════════════════════════════════════════════════

    /// @notice Assert which side won this round.
    /// Side 0 ("none depegged") must use resolveAsNone().
    /// Caller funds the bond — returned on success, lost on rejection.
    /// Multiple asserters may file in parallel; first confirmed wins.
    function requestResolution(uint8 claimedSide)
        external returns (bytes32 assertionId) {
        require(claimedSide > 0, "use resolveAsNone");
        require(market.phase == Types.Phase.Trading
             || market.phase == Types.Phase.Asserting,
                "market not accepting assertions");

        require(activeAssertionCount < MAX_PARALLEL_ASSERTIONS, "too many pending assertions");
        if (claimedSide >= market.numSides) revert InvalidSide(claimedSide, market.numSides);
        require(sideAssertionId[market.roundNumber][claimedSide] == bytes32(0),
                "side already asserted");

        uint bond = getMinimumBond();
        // Pull bond from caller — skin in the game
        BOND_TOKEN.transferFrom(msg.sender, address(this), bond);
        BOND_TOKEN.approve(address(OO), bond);

        bytes memory claim = abi.encodePacked(
            "Depeg market round ", _uint2str(market.roundNumber),
            " outcome: side ", _uint2str(uint(claimedSide))
        );
        // asserter = address(this) → bond returns here on success
        // callbackRecipient = address(this) → callbacks come here
        assertionId = OO.assertTruth(
            claim, address(this), address(this),
            address(0), uint64(LIVENESS), BOND_TOKEN,
            bond, OO.defaultIdentifier(), bytes32(0)
        );
        // Track this assertion
        assertions[assertionId] = AssertionContext({
            asserter: msg.sender,
            claimedSide: claimedSide,
            bond: bond,
            requestTimestamp: block.timestamp,
            round: market.roundNumber,
            disputed: false
        });
        sideAssertionId[market.roundNumber][claimedSide] = assertionId;
        pendingAssertionIds.push(assertionId);
        activeAssertionCount++;

        // First assertion in this round freezes trading
        if (market.phase == Types.Phase.Trading) {
            market.phase = Types.Phase.Asserting;
            HOOK.onAssertionFiled();
        }
        emit ResolutionRequested(
        assertionId, claimedSide, bond);
    }

    /// @notice Settle all pending assertions whose liveness has expired.
    function settleAssertion() external {
        require(market.phase == Types.Phase.Asserting
             || market.phase == Types.Phase.Disputed, "wrong phase");
        for (uint i; i < pendingAssertionIds.length; i++) {
            bytes32 id = pendingAssertionIds[i];
            if (assertions[id].asserter != address(0)) {
                try OO.settleAssertion(id) {} catch {}
            }
        }
    }

    function assertionResolvedCallback(bytes32 assertionId,
        bool truthful) external onlyOO {
        AssertionContext memory ctx = assertions[assertionId];
        if (ctx.asserter == address(0)) return; // unknown / already processed
        // Stale assertion from previous round disputed late;
        // must NOT touch Hook state for the current round...
        // Without this guard, a $0 dispute on a stale assertion
        // sets disputeFrozen=true permanently (no recovery path).
        if (ctx.round != market.roundNumber) {
            delete assertions[assertionId]; return;
        }
        delete assertions[assertionId];
        if (activeAssertionCount > 0) activeAssertionCount--;

        if (truthful) {
            if (market.phase == Types.Phase.Resolved) {
                // Market already resolved by a faster assertion — just refund
                BOND_TOKEN.transfer(ctx.asserter, ctx.bond);
                emit AssertionSettled(market.winningSide, true);
                if (ctx.disputed) HOOK.onDisputeEnded();
                return;
            }
            market.phase = Types.Phase.Resolved;
            market.winningSide = ctx.claimedSide;
            market.revealDeadline = block.timestamp + REVEAL_WINDOW;
            market.consecutiveRejections = 0;

            HOOK.trigger(block.timestamp, ctx.claimedSide);
            // OOV3 returned the bond to us — refund the winning asserter
            BOND_TOKEN.transfer(ctx.asserter, ctx.bond);
        } else {
            // Rejected — asserter loses bond (OOV3 slashed it)
            if (market.consecutiveRejections < 255)
                market.consecutiveRejections++;
            // Re-open this side for a fresh assertion
            if (ctx.round == market.roundNumber)
                sideAssertionId[ctx.round][ctx.claimedSide] = bytes32(0);

            // All assertions exhausted → unfreeze
            if (activeAssertionCount == 0
                && market.phase != Types.Phase.Resolved) {
                market.phase = Types.Phase.Trading;
                // roundStartTime intentionally NOT reset — early entrants
                // keep their time-decay advantage. Resetting would let a
                // $100 false assertion wipe the entire decay curve.
                HOOK.onAssertionRejected();
            }
        }
        emit AssertionSettled(market.winningSide, truthful);
        if (ctx.disputed) HOOK.onDisputeEnded();
    }

    function assertionDisputedCallback
        (bytes32 assertionId) external onlyOO {
        AssertionContext storage ctx = assertions[assertionId];
        require(ctx.asserter != address(0), "unknown assertion");
        ctx.disputed = true;
        if (market.phase == Types.Phase.Asserting)
            market.phase = Types.Phase.Disputed;
        HOOK.onDisputeStarted();
        emit AssertionDisputed();
        // Request deep forensic evidence from CRE (Trigger B).
        // If no CRE workflow is listening, fires into the void.
        emit DisputeForensicsRequested(assertionId,
        ctx.claimedSide, ctx.requestTimestamp);
    }

    function restartMarket() external inPhase(Types.Phase.Resolved) {
        require(block.timestamp >= market.revealDeadline && HOOK.paid());
        market.winningSide = 0;
        market.phase = Types.Phase.Trading;
        market.consecutiveRejections = 0;
        market.revealDeadline = 0;
        market.roundNumber++;
        activeAssertionCount = 0;
        delete pendingAssertionIds;
        HOOK.resetForNewRound();
        emit MarketRestarted(
          market.roundNumber);
    }

    /// @notice Admin-initiated dispute against a specific assertion.
    /// Uses this contract's USDC reserves for the dispute bond.
    /// @param _assertionId The assertion to dispute.
    ///        If bytes32(0), disputes the first pending assertion.
    function executeDispute(bytes32 _assertionId) public onlyOwner {
        if (_assertionId == bytes32(0)) {
            require(pendingAssertionIds.length > 0, "no assertions");
            _assertionId = pendingAssertionIds[0];
        }
        AssertionContext memory ctx = assertions[_assertionId];
        require(ctx.asserter != address(0), "unknown assertion");

        uint bond = ctx.bond; // match the asserter's bond
        require(BOND_TOKEN.balanceOf(address(this)) >= bond, "insufficient bond reserves");
        BOND_TOKEN.approve(address(OO), bond);
        OO.disputeAssertion(_assertionId, address(this));
        // NOTE: assertionDisputedCallback fires synchronously
    }

    /// @notice Backward-compatible overload — disputes first pending.
    function executeDispute() external onlyOwner {
        executeDispute(bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Stores evidence for DVM voters. Advisory only — the DVM
    //  vote is the sole source of truth for market resolution.
    //  Anyone can submit. First write per assertionId wins.
    // ═══════════════════════════════════════════════════════════════
    /// @notice Store forensic evidence for a disputed assertion.
    /// Restricted to CRE forwarder to prevent front-running with garbage.
    /// Idempotent: first submission per assertionId wins.
    function storeEvidence(bytes32 assertionId, uint8 claimedSide,
        uint8 recommendedSide, int maxDeviationBps,
        uint8 confidence, bytes32 evidenceHash) external onlyForwarder {
        _storeEvidence(assertionId, claimedSide, recommendedSide,
                        maxDeviationBps, confidence, evidenceHash);
    }

    function _storeEvidence(bytes32 assertionId,
        uint8 claimedSide, uint8 recommendedSide,
        int maxDeviationBps, uint8 confidence,
        bytes32 evidenceHash) internal {
        if (evidenceSubmitted[assertionId]) return;
        evidenceSubmitted[assertionId] = true;
        evidence[assertionId] = Types.ForensicEvidence({
            claimedSide: claimedSide,
            recommendedSide: recommendedSide,
            maxDeviationBps: maxDeviationBps,
            confidence: confidence,
            evidenceHash: evidenceHash,
            timestamp: block.timestamp
        });
        emit ForensicEvidenceStored(assertionId,
                recommendedSide, confidence);
    }

    function getEvidence(bytes32 assertionId) external
        view returns (Types.ForensicEvidence memory) {
        return evidence[assertionId];
    }

    // ═══════════════════════════════════════════════════════════════
    //  Receives reports from Chainlink CRE via KeystoneForwarder.
    //  If evidence contradicts the assertion with high confidence,
    //  auto-disputes via OOV3 using USDC held by this contract.
    //  DVM vote remains the sole source of truth.
    // ═══════════════════════════════════════════════════════════════
    /// @notice Called by CRE KeystoneForwarder with forensic analysis.
    ///         Stores evidence AND auto-disputes if warranted.
    ///         Implements IReceiver.onReport(bytes metadata, bytes report).
    function onReport(bytes calldata, bytes calldata report)
        external onlyForwarder {
        (bytes32 assertionId, uint8 claimedSide,
            uint8 recommendedSide, int maxDeviationBps,
            uint8 confidence, bytes32 evidenceHash) = abi.decode(report,
                            (bytes32, uint8, uint8, int, uint8, bytes32));
        _storeEvidence(assertionId, claimedSide, recommendedSide,
                        maxDeviationBps, confidence, evidenceHash);

        // Auto-dispute only for known pending undisputed assertions
        AssertionContext memory ctx = assertions[assertionId];
        if (ctx.asserter == address(0)) {
            emit WatchdogSkipped(assertionId, "unknown assertion");
            return;
        }
        if (ctx.disputed) {
            emit WatchdogSkipped(assertionId, "already disputed");
            return;
        }
        if (market.phase == Types.Phase.Resolved) {
            emit WatchdogSkipped(assertionId, "already resolved");
            return;
        }
        if (claimedSide == recommendedSide) {
            emit WatchdogSkipped(assertionId, "evidence agrees");
            return;
        }
        if (confidence < minConfidence) {
            emit WatchdogSkipped(assertionId, "confidence below threshold");
            return;
        }
        uint bond = ctx.bond; // match the asserter's bond
        if (BOND_TOKEN.balanceOf(address(this)) < bond) {
            emit WatchdogSkipped(assertionId, "insufficient bond balance");
            return;
        }
        BOND_TOKEN.approve(address(OO), bond);
        OO.disputeAssertion(assertionId, address(this));
        // NOTE: assertionDisputedCallback fires synchronously above
        watchdogDisputeCount++;
        emit WatchdogDispute(
            assertionId, claimedSide, recommendedSide,
            maxDeviationBps, confidence, evidenceHash
        );
    }

    /// @notice How many auto-disputes this contract can afford.
    /// When assertions are active, uses the current escalated bond.
    /// Otherwise falls back to OOV3's minimum bond.
    function disputeCapacity() external view returns (uint) {
        uint bond = activeAssertionCount > 0 ? getMinimumBond():
                         OO.getMinimumBond(address(BOND_TOKEN));

        if (bond == 0) return type(uint).max;
        return BOND_TOKEN.balanceOf(address(this)) / bond;
    }

    function setMinConfidence(uint8 _min) external onlyOwner {
        require(_min <= 100, "invalid threshold");
        minConfidence = _min;
    }

    function withdrawBond(uint amount,
        address to) external onlyOwner {
        BOND_TOKEN.transfer(to, amount);
    }

    /// @notice Bond = clamp(capital_usdc × BOND_BPS, FLOOR, CEILING) × 2^rejections
    /// First assertion: normal bond. After 1 rejection: 2×. After 2: 4×.
    /// Capped at BOND_CEILING to prevent overflow. Resets on success or new round.
    function getMinimumBond() public view returns (uint) {
        uint capital = HOOK.getMarketCapital();
        uint capitalUSDC = capital / 1e12;
        // WAD (18 dec) → USDC (6 dec)

        uint bp = (capitalUSDC * BOND_BPS) / 10000;
        uint base = bp < BOND_FLOOR ? BOND_FLOOR :
                    bp > BOND_CEILING ? BOND_CEILING : bp;

        uint8 rej = market.consecutiveRejections;
        uint8 shift = rej > 7 ? 7 : rej; // cap at 128×
        uint escalated = base << shift;

        if (escalated > BOND_CEILING) escalated = BOND_CEILING;
        uint ooMin = OO.getMinimumBond(address(BOND_TOKEN));
        return escalated > ooMin ? escalated : ooMin;
    }

    function isTradingEnabled()
        external view returns (bool) {
        Types.Phase p = market.phase;
        return p == Types.Phase.Trading
            || p == Types.Phase.Asserting;
    }

    function isRevealOpen()
        external view returns (bool) {
        return market.phase == Types.Phase.Resolved
        && block.timestamp < market.revealDeadline;
    }

    function getNumSides() external
        view returns (uint8) {
        return market.numSides;
    }

    function getAssertionInfo() external view
        returns (uint8 phase, uint8 claimedSide,
                 uint round, uint8 rejections) {

        return (uint8(market.phase), market.winningSide,
        market.roundNumber, market.consecutiveRejections);
    }

    /// @notice Bond needed to dispute the first pending assertion,
    /// or OOV3 minimum if none are active.
    function getBondForDispute() external view returns (uint) {
        if (pendingAssertionIds.length > 0) {
            bytes32 id = pendingAssertionIds[0];
            AssertionContext memory ctx = assertions[id];
            if (ctx.asserter != address(0)) return ctx.bond;
        }
        return OO.getMinimumBond(address(BOND_TOKEN));
    }

    /// @notice Get details of a specific pending assertion.
    function getAssertion(bytes32 assertionId) external view
        returns (address asserter, uint bond, uint8 claimedSide,
                 uint round, uint requestTimestamp, bool disputed) {
        AssertionContext memory ctx = assertions[assertionId];
        return (ctx.asserter, ctx.bond, ctx.claimedSide,
                ctx.round, ctx.requestTimestamp, ctx.disputed);
    }

    function getPendingAssertionCount() external
        view returns (uint) {
        return activeAssertionCount;
    }

    function _uint2str(uint v) internal
        pure returns (bytes memory) {
        if (v == 0) return "0";
        uint t = v; uint d;
        while (t != 0) {
            d++; t /= 10;
        }
        bytes memory b = new bytes(d);
        while (v != 0) {
            b[--d] = bytes1(uint8(48 + v % 10));
            v /= 10;
        } return b;
    }

    /// @notice Binary search to buy tokens on LMSR curve.
    /// All values in WAD (18-decimal). No scaling needed.
    function buyTokens(int128[MAX_SIDES] memory q,
        uint8 numSides, int128 b, uint8 side,
        uint netCap) external pure
        returns (uint tokens, int128 deltaQ) {
        int128 capWAD = int128(int256(netCap));
        // At minimum price (1/numSides), max tokens ≈ capWAD × numSides.
        // 2× safety margin covers price movement during purchase.
        // _expNorm clamps exp(-x) → 0 for x > 100 to avoid overflow.
        int128 lo; int128 hi = capWAD * int128(int256(
                          uint256(numSides))) * 2;
        for (uint i; i < 64; i++) {
            int128 mid = (lo + hi) / 2;
            uint c = FeeLib.cost(q,
                numSides, b, side, mid);
            if (c <= uint(uint128(capWAD))) lo = mid;
            else hi = mid;
            if (hi - lo <= 1) break; // converge to 1 wei
        } tokens = uint(uint128(lo)); deltaQ = lo;
    }

    /// @notice All values in WAD (18-decimal)...
    function sellTokens(int128[MAX_SIDES] memory q,
        uint8 numSides, int128 b, uint8 side,
        uint tokSell) external pure // LMSR
        returns (uint returned, int128 deltaQ) {
        int128 tokWAD = int128(int256(tokSell));
        uint refund = FeeLib.cost(q,
            numSides, b, side, -tokWAD);
        returned = refund; deltaQ = tokWAD;
    }

    /// @notice Compute a single position's payout weight.
    /// capitals[] are in WAD. decay is in bps (0-10000).
    /// Result: weight = confFactor × Σ(capital × decay) / 10000
    function computeWeight(uint[] memory capitals,
        uint[] memory timestamps, uint roundStart,
        uint resTs, uint lambda, uint floor,
        uint confidence, bool isWinner)
        external pure returns (uint weight) {
        uint timeWeightedCap; uint decay;
        for (uint j; j < capitals.length; j++) {
            if (resTs <= roundStart) decay = 10000;
            else { uint p; // participation in bps
                { // scope: mktD & posD die here (stack relief)
                    uint mktD = resTs - roundStart;
                    uint posD = timestamps[j] <= roundStart ? mktD :
                        (timestamps[j] >= resTs ? 0 : resTs - timestamps[j]);
                    p = Math.min((posD * 10000) / mktD, 10000);
                } // ← mktD, posD freed from stack
                if (lambda <= 100) decay = p;
                else if (lambda <= 200) {
                    uint t = lambda - 100;
                    uint qd = (p * p) / 10000;
                    decay = (p * (100 - t) + qd * t) / 100;
                } else {
                    uint qd = (p * p) / 10000;
                    decay = (qd * p) / 10000;
                }
                if (decay < floor) decay = floor;
            } timeWeightedCap += capitals[j] * decay;
        } uint twcWAD = timeWeightedCap / 10000;
        // timeWeightedCap is WAD × bps. Divide by 10000 to get WAD...
        // confidence is 100-10000 (1-100%). Normalize to WAD fraction.
        uint confNorm = (confidence * WAD) / 10000;
        if (isWinner)
            weight = FullMath.mulDiv(
                confNorm, twcWAD, WAD);

        else { uint inv = WAD - confNorm;
            weight = FullMath.mulDiv(inv > 0 ?
                        inv : 1, twcWAD, WAD);
        }
    }

    /// @notice Compute a single position's payout amount (18-decimal)...
    /// If no winners exist, entire loser capital goes to consolation pool
    /// to prevent permanent capital lock.
    function computePayout(uint capital, uint weight,
        uint totalWinWeight, uint totalLoseWeight, // 20% goes back...
        uint totalLoserCap, uint consolBps, bool isWinner) external pure
        returns (uint payout) { uint winnerPool; uint consolPool;
        if (totalWinWeight == 0) { // No winners: all loser capital
            // → consolation (no one to receive winner pool)
            winnerPool = 0; consolPool = totalLoserCap;
        } else {
            winnerPool = FullMath.mulDiv(totalLoserCap,
                            10000 - consolBps, 10000);
            consolPool = totalLoserCap - winnerPool;
        }
        if (isWinner) {
            uint bonus = totalWinWeight > 0 ? FullMath.mulDiv(
                           winnerPool, weight, totalWinWeight) : 0;

            payout = capital + bonus;
        } else {
            payout = totalLoseWeight > 0 ?
                FullMath.mulDiv(consolPool,
                    weight, totalLoseWeight): 0;
        }
    }

    /// @notice Pro-rata reduce entries selling tokens
    function reduceEntries(uint[] memory capitals,
        uint[] memory tokens, uint tokensToSell,
        uint totalTokens) external pure returns (
        uint[] memory newCapitals,
        uint[] memory newTokens,
        uint totalCapReduced) {
        uint len = capitals.length;
        newCapitals = new uint[](len);
        newTokens = new uint[](len);
        for (uint i; i < len; i++) {
            newCapitals[i] = capitals[i];
            newTokens[i] = tokens[i];
        }
        uint tokensRemaining = tokensToSell;
        for (uint i; i < len; i++) {
            if (newTokens[i] == 0) continue;
            // Last active entry absorbs rounding residual
            uint tokFromEntry;
            if (tokensRemaining >= newTokens[i]) {
                tokFromEntry = newTokens[i];
            } else if (i == len - 1 || _isLastActive(newTokens, i + 1, len)) {
                tokFromEntry = tokensRemaining;
            } else {
                tokFromEntry = (newTokens[i] *
                     tokensToSell) / totalTokens;
                if (tokFromEntry > tokensRemaining)
                    tokFromEntry = tokensRemaining;
            }
            if (tokFromEntry >= newTokens[i]) {
                totalCapReduced += newCapitals[i];
                newCapitals[i] = 0;
                newTokens[i] = 0;
            } else {
                uint capFromEntry = (newCapitals[i]
                      * tokFromEntry) / newTokens[i];

                newTokens[i] -= tokFromEntry;
                newCapitals[i] -= capFromEntry;
                totalCapReduced += capFromEntry;
            }
            tokensRemaining -= tokFromEntry;
            if (tokensRemaining == 0) break;
        }
    }

    /// @dev Check if all entries from `start` to `end` have zero tokens
    function _isLastActive(uint[] memory toks,
        uint start, uint end) internal pure returns (bool) {
        for (uint j = start; j < end; j++)
            if (toks[j] > 0) return false;
        return true;
    }
}
