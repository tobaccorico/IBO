
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Basket} from "./Basket.sol";
import {RandaoLib} from "./imports/RandaoLib.sol";
import {MessageCodec} from "./imports/MessageCodec.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface IProof {
    function getAffidavitCount(uint64 marketId) external view returns (uint);
    function evaluationCount(uint64 marketId, address juror) external view returns (uint);
    function getResolutionStartIndex(uint64 marketId) external view returns (uint);
    function getCurrentResolutionEvalCount(uint64 marketId, address juror) external view returns (uint);
}

interface ICourt {
    function getMarketConfig(uint64 marketId) external view returns (
        uint8 numSides, uint8 numWinners, bool requiresUnanimous, bool requiresSignature);
    function getRoundStartTime(uint64 marketId) external view returns (uint);
    function getCurrentRound(uint64 marketId) external view returns (uint8);
    function getVerdictTimestamp(uint64 marketId) external view returns (uint);
    function getFinalVerdict(uint64 marketId) external view returns (uint8[] memory);
    function owner() external view returns (address);
    function transferSlashedToJury(uint64 marketId) external;
    function clearPostDistribution(uint64 marketId) external;
}

contract Jury is Ownable, ReentrancyGuard {
    address public court;
    address public proof;
    address public immutable basket;

    uint constant REVEAL_SIZE = 12;
    uint constant FULL_JURY = 21;
    uint constant COMMIT_PERIOD = 4 days;
    uint constant REVEAL_WINDOW = 12 hours;
    uint constant APPEAL_WINDOW = 7 days;
    uint constant BASE_COMP_TIMEOUT = 7 days;

    struct Round {
        uint8 numSides;
        uint8 numWinners;
        bool requiresUnanimous;
        address appellant;
        address[] jurors;
        uint[] revealedIndices;
        bool finalized;
        uint8[] verdict;
        bool unanimous;
        bool meetsThreshold;
    }

    struct Compensation {
        uint baseFromSolana;
        uint slashedOnEth;
        bool baseReceived;
        bool distributed;
    }

    mapping(uint64 => mapping(uint8 => Round)) public rounds;
    mapping(uint64 => mapping(address => bool)) public hasServed;
    mapping(uint64 => mapping(address => uint)) public lockedStake;
    mapping(uint64 => mapping(uint8 => uint)) public affidavitSnapshot;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public revealed;
    mapping(uint64 => mapping(uint8 => mapping(address => uint8[]))) public votes;
    mapping(uint64 => mapping(uint8 => mapping(address => bytes32))) public commits;
    mapping(uint64 => mapping(uint8 => mapping(address => address))) public delegates;

    // Moved from Court
    mapping(uint64 => Compensation) public compensation;
    mapping(uint64 => address) public marketToStablecoin;
    mapping(address => uint64) public stablecoinToMarket;
    mapping(address => MessageCodec.DepegStats) public depegStats;

    event JuryFulfilled(uint64 indexed marketId, uint8 round);
    event InsufficientStakers(uint64 indexed marketId, uint8 round, uint current, uint needed);
    event VoteCommitted(uint64 indexed marketId, uint8 round, address juror);
    event VoteRevealed(uint64 indexed marketId, uint8 round, address juror);
    event RoundFinalized(uint64 indexed marketId, uint8 round);
    event JurorSlashed(address juror, uint amount);
    event JurorCompensated(address juror, uint amount);
    event JuryCompensated(uint64 indexed marketId, uint total);
    event DepegStatsUpdated(address indexed stablecoin, uint64 marketId);

    error OnlyCourt();
    error OnlyBasket();
    error AlreadyCommitted();
    error AlreadyFulfilled();
    error AlreadyFinalized();
    error DoubleSpend();

    modifier onlyCourt() {
        if (court == address(0) || msg.sender != court) revert OnlyCourt();
        _;
    }

    modifier onlyBasket() {
        if (msg.sender != basket) revert OnlyBasket();
        _;
    }

    constructor(address _basket) Ownable(msg.sender) {
        basket = _basket;
    }

    function setup(address _court, address _proof) external onlyOwner {
        court = _court; proof = _proof; renounceOwnership();
    }

    function registerDepegMarket(uint64 marketId, address stablecoin) external onlyCourt {
        require(stablecoin != address(0) && marketToStablecoin[marketId] == address(0));
        marketToStablecoin[marketId] = stablecoin;
        stablecoinToMarket[stablecoin] = marketId;
    }

    function getDepegStats(address stablecoin) external
        view returns (MessageCodec.DepegStats memory) {
        return depegStats[stablecoin];
    }

    // TODO: comment out before mainnet deployment (testing only)
    // function setDepegStatsForTesting(address token,
    //     MessageCodec.DepegStats memory stats) external {
    //     depegStats[token] = stats;
    // }

    function receiveJuryFunds(uint64 marketId, uint amount,
        bytes calldata rawMessage) external nonReentrant onlyBasket {
        Compensation storage comp = compensation[marketId];

        // Get market state to check if there's an active resolution
        (uint8 numSides,,,) = ICourt(court).getMarketConfig(marketId);
        uint verdictTs = ICourt(court).getVerdictTimestamp(marketId);

        // Late compensation detection:
        // If no active resolution (numSides = 0) AND no pending verdict (verdictTimestamp = 0),
        // this is late compensation from a previous resolution → send to treasury
        if (numSides == 0 && verdictTs == 0) {
            Basket(basket).transfer(ICourt(court).owner(), amount);
            return;
        }

        // If already distributed for current resolution → also late, send to treasury
        if (comp.distributed) {
            Basket(basket).transfer(ICourt(court).owner(), amount);
            return;
        }
        if (comp.baseReceived) revert DoubleSpend();
        comp.baseFromSolana = amount;
        comp.baseReceived = true;

        address stablecoin = marketToStablecoin[marketId];
        if (stablecoin != address(0) && MessageCodec.hasDepegStats(rawMessage)) {
            MessageCodec.DepegStats memory stats = MessageCodec.parseDepegStats(rawMessage);
            stats.timestamp = uint40(block.timestamp);
            depegStats[stablecoin] = stats;
            emit DepegStatsUpdated(stablecoin, marketId);
        }
        _tryDistribute(marketId);
    }

    function addSlashedEth(uint64 marketId, uint amount) external onlyCourt {
        compensation[marketId].slashedOnEth += amount;
    }

    function refundAppealCost(uint64 marketId, uint amount) external onlyCourt {
        compensation[marketId].slashedOnEth -= amount;
    }

    function markCompensationTimedOut(uint64 marketId) external onlyCourt {
        Compensation storage comp = compensation[marketId];
        comp.baseFromSolana = 0; comp.baseReceived = true;
    }

    function tryDistribute(uint64 marketId) external nonReentrant {
        _tryDistribute(marketId);
    }

    function _tryDistribute(uint64 marketId) internal {
        Compensation storage comp = compensation[marketId];
        uint verdictTs = ICourt(court).getVerdictTimestamp(marketId);

        if (verdictTs == 0 || block.timestamp <= verdictTs + APPEAL_WINDOW ||
            !comp.baseReceived || comp.distributed) return;

        comp.distributed = true;

        // Capture slashed amount before transfer (transfer will clear tracking)
        uint ethSlashed = comp.slashedOnEth;

        // Pull slashed appeal costs from Court now that we're ready to distribute
        ICourt(court).transferSlashedToJury(marketId);

        uint8[] memory finalVerdict = ICourt(court).getFinalVerdict(marketId);
        uint8 finalRound = ICourt(court).getCurrentRound(marketId);

        uint distributed = _distributeCompensation(marketId, finalRound,
                    finalVerdict, comp.baseFromSolana, ethSlashed
        );
        emit JuryCompensated(marketId, distributed);

        // Clear preserved Court state now that distribution is complete
        ICourt(court).clearPostDistribution(marketId);

        // Don't delete compensation struct - keep distributed = true
        // so late-arriving compensation from Solana goes
        // to treasury (receiveJuryFunds checks this)...
        // Reset amounts to 0 to save gas on future reads
        comp.baseFromSolana = 0;
        comp.slashedOnEth = 0;
    }

    function _distributeCompensation(uint64 marketId, uint8 finalRound,
        uint8[] memory finalVerdict, uint baseComp, uint ethSlashed)
        internal returns (uint distributed) { uint correctCount = 0;
        address[] memory correctJurors = new address[]((finalRound + 1) * FULL_JURY);
        uint pool = baseComp + ethSlashed;
        for (uint8 r = 0; r <= finalRound; r++) {
            (uint slashed, uint correct) = _processRoundJurors(
                marketId, r, finalVerdict, correctJurors, correctCount);

            pool += slashed;
            correctCount = correct;
        }
        if (correctCount > 0) {
            uint perJuror = pool / correctCount;
            for (uint i = 0; i < correctCount; i++) {
                Basket(basket).transfer(correctJurors[i], perJuror);
                distributed += perJuror;
            }
        } else {
            // No correct jurors - send to treasury
            Basket(basket).transfer(owner(), pool);
            distributed = pool;
        } return distributed;
    }

    function isCompensationDistributed(uint64 marketId) external view returns (bool) {
        return compensation[marketId].distributed;
    }

    /// @notice Check if compensation has been received from Solana
    function isCompensationReceived(uint64 marketId) external view returns (bool) {
        return compensation[marketId].baseReceived;
    }

    /// @notice Get the slashed ETH amount Court needs to transfer before distribution
    function getSlashedAmount(uint64 marketId) external view returns (uint) {
        return compensation[marketId].slashedOnEth;
    }

    /// @notice Clear slashed amount after Court transfers tokens
    function clearSlashedAmount(uint64 marketId) external onlyCourt {
        compensation[marketId].slashedOnEth = 0;
    }

    /// @notice Reset compensation struct for new resolution
    /// @dev Called by Court when a new resolution starts (handles re-resolution case)
    function resetCompensation(uint64 marketId) external onlyCourt {
        delete compensation[marketId];
    }

    function voirDire(uint64 marketId, uint8 round,
        bytes[] calldata headers) external onlyCourt returns (bool) {
        Round storage r = rounds[marketId][round];

        // For round 0 with existing data (finalized or not), clear ALL old round data
        // This handles re-resolution after: normal completion, force majeure, missed windows
        // Ensures jurors from old appeal rounds can be selected for new resolution
        if (round == 0 && (r.finalized || r.jurors.length > 0)) {
            for (uint8 oldRound = 0; oldRound < 10; oldRound++) { // MAX_TOTAL_ROUNDS = 10
                Round storage oldR = rounds[marketId][oldRound];
                if (oldR.jurors.length == 0) continue;
                for (uint i = 0; i < oldR.jurors.length; i++) {
                    address juror = oldR.jurors[i];
                    uint stake = lockedStake[marketId][juror];
                    if (stake > 0) {
                        Basket(basket).unlockFromJury(juror, stake);
                        lockedStake[marketId][juror] = 0;
                    }
                    hasServed[marketId][juror] = false;
                    delete commits[marketId][oldRound][juror];
                    delete revealed[marketId][oldRound][juror];
                    delete votes[marketId][oldRound][juror];
                    delete delegates[marketId][oldRound][juror];
                }
                delete rounds[marketId][oldRound];
                delete affidavitSnapshot[marketId][oldRound];
            }
        } else if (r.finalized || r.jurors.length > 0) {
            // RETRY within same resolution: clear only this round's data
            for (uint i = 0; i < r.jurors.length; i++) {
                address juror = r.jurors[i];
                uint stake = lockedStake[marketId][juror];
                if (stake > 0) {
                    Basket(basket).unlockFromJury(juror, stake);
                    lockedStake[marketId][juror] = 0;
                }
                hasServed[marketId][juror] = false;
                delete commits[marketId][round][juror];
                delete revealed[marketId][round][juror];
                delete votes[marketId][round][juror];
                delete delegates[marketId][round][juror];
            }
            delete rounds[marketId][round];
            delete affidavitSnapshot[marketId][round];
        }
        // Re-fetch storage reference after potential delete
        r = rounds[marketId][round];
        if (r.numSides == 0) {
            (r.numSides, r.numWinners,
            r.requiresUnanimous,) = _getMarketConfig(marketId);
        }
        require(ICourt(court).getRoundStartTime(marketId) > 0, "No active resolution");
        require(round == ICourt(court).getCurrentRound(marketId), "Wrong round");
        require(headers.length <= 10);
        require(headers.length >= 3, "need 3 headers");
        bytes32 seed = RandaoLib.getHistoricalRandaoValue(block.number - 1, headers[0]);
        seed = keccak256(abi.encodePacked(seed,
            RandaoLib.getHistoricalRandaoValue(block.number - 2, headers[1]),
            RandaoLib.getHistoricalRandaoValue(block.number - 3, headers[2])));

        for (uint i = 3; i < headers.length; i++) {
            seed = keccak256(abi.encodePacked(seed,
                RandaoLib.getHistoricalRandaoValue(block.number - (i + 1), headers[i])));
        }
        uint poolSize = Basket(basket).latest_holder();
        if (poolSize < FULL_JURY) {
            emit InsufficientStakers(marketId,
                round, poolSize, FULL_JURY); return false;
        }
        uint selected = 0;
        uint maxAttempts = poolSize * 3;
        if (maxAttempts > 100) maxAttempts = 100;
        if (maxAttempts < FULL_JURY * 2) maxAttempts = FULL_JURY * 2;
        for (uint i = 0; i < maxAttempts && selected < FULL_JURY; i++) {
            seed = keccak256(abi.encodePacked(seed, i));
            uint idx = uint(seed) % Basket(basket).latest_holder();
            address candidate = Basket(basket).holders(idx);
            if (_selectAndLockJuror(marketId, candidate, r)) selected++;
        }
        if (selected != FULL_JURY) return false;
        // Snapshot counts only NEW affidavits from current resolution
        // Old affidavits (from previous resolutions) are already finalized
        uint totalAffidavits = IProof(proof).getAffidavitCount(marketId);
        uint startIndex = IProof(proof).getResolutionStartIndex(marketId);
        affidavitSnapshot[marketId][round] = totalAffidavits - startIndex;
        return true;
    }

    function commitVote(uint64 marketId, uint8 round,
        bytes32 commitment, address delegate) external {
        Round storage r = rounds[marketId][round];
        require(!r.finalized, "finalized");
        require(r.jurors.length > 0, "inactive");

        // Enforce commit deadline to prevent late commits after observing reveals
        uint roundStart = ICourt(court).getRoundStartTime(marketId);
        require(roundStart > 0, "round not started");
        require(block.timestamp <= roundStart + COMMIT_PERIOD, "commit period ended");

        bool found = false;
        for (uint i = 0; i < r.jurors.length; i++) {
            if (r.jurors[i] == msg.sender) { found = true; break; }
        }
        require(found, "not juror");

        if (commits[marketId][round][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (delegate != address(0)) delegates[marketId][round][msg.sender] = delegate;

        commits[marketId][round][msg.sender] = commitment;
        emit VoteCommitted(marketId, round, msg.sender);
    }

    function revealVote(uint64 marketId, uint8 round,
        uint8[] calldata sides, bytes32 salt, address juror) external {
        Round storage r = rounds[marketId][round];
        require(!r.finalized, "finalized");
        uint snapshot = affidavitSnapshot[marketId][round];
        if (snapshot > 0) {
            // Check evaluations of NEW affidavits only (current resolution)
            require(IProof(proof).getCurrentResolutionEvalCount(marketId, juror) >= snapshot, "evaluate");
        }
        require(msg.sender == delegates[marketId][round][juror] || msg.sender == juror, "403");
        // Fetch roundStart from Court to prevent timing manipulation
        uint roundStart = ICourt(court).getRoundStartTime(marketId);

        require(roundStart > 0, "round not started");
        require(block.timestamp >= roundStart + COMMIT_PERIOD, "early");
        require(block.timestamp <= roundStart + COMMIT_PERIOD + REVEAL_WINDOW, "late");

        require(!revealed[marketId][round][juror], "revealed");
        require(commits[marketId][round][juror] == keccak256(abi.encode(sides, salt)), "invalid");

        revealed[marketId][round][juror] = true;
        votes[marketId][round][juror] = sides;
        emit VoteRevealed(marketId, round, juror);
    }

    function finalizeRound(uint64 marketId, uint8 round,
        uint roundStart, bytes[] calldata headers) external onlyCourt {
        Round storage r = rounds[marketId][round];
        if (r.finalized) revert AlreadyFinalized();
        // Defense-in-depth: verify roundStart matches Court's storage
        require(roundStart == ICourt(court).getRoundStartTime(marketId), "roundStart mismatch");
        if (r.revealedIndices.length == 0) {
            require(block.timestamp > roundStart + COMMIT_PERIOD, "commit active");
            uint commitCount = 0;
            for (uint i = 0; i < r.jurors.length; i++) {
                if (commits[marketId][round][r.jurors[i]] != bytes32(0)) commitCount++;
            }
            require(commitCount >= REVEAL_SIZE, "commits");
            require(headers.length >= 2, "headers");

            bytes32 seed = RandaoLib.getHistoricalRandaoValue(block.number - 1, headers[0]);
            seed = keccak256(abi.encodePacked(seed, RandaoLib.getHistoricalRandaoValue(
                                                        block.number - 2, headers[1])));
            for (uint i = 2; i < headers.length; i++) {
                seed = keccak256(abi.encodePacked(seed,
                    RandaoLib.getHistoricalRandaoValue(
                    block.number - (i + 1), headers[i])));
            }
            address[] memory committed = new address[](commitCount);
            uint idx = 0;
            for (uint i = 0; i < r.jurors.length; i++) {
                if (commits[marketId][round][r.jurors[i]] != bytes32(0)) {
                    committed[idx++] = r.jurors[i];
                }
            } bool[] memory selected = new bool[](commitCount);
            for (uint i = 0; i < REVEAL_SIZE; i++) {
                uint index;
                do {
                    seed = keccak256(abi.encodePacked(seed, i));
                    index = uint(seed) % commitCount;
                } while (selected[index]);
                selected[index] = true;
                for (uint j = 0; j < r.jurors.length; j++) {
                    if (r.jurors[j] == committed[index]) {
                        r.revealedIndices.push(j);
                        break;
                    }
                }
            }
        } uint revealCount = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) revealCount++;
        }
        if (r.numWinners > 1) {
            (r.verdict,
             r.unanimous,
             r.meetsThreshold) = _getMultiWinner(marketId, round, r);
        } else {
            uint8[] memory voteCounts = new uint8[](r.numSides);
            for (uint i = 0; i < r.revealedIndices.length; i++) {
                address juror = r.jurors[r.revealedIndices[i]];
                if (revealed[marketId][round][juror]) {
                    uint8[] memory jurorVotes = votes[marketId][round][juror];
                    if (jurorVotes.length > 0 && jurorVotes[0] < r.numSides) {
                        voteCounts[jurorVotes[0]]++;
                    }
                }
            } uint8 maxVotes = 0;
            uint8 winningSide = 0;
            for (uint8 side = 0; side < r.numSides; side++) {
                if (voteCounts[side] > maxVotes) {
                    maxVotes = voteCounts[side];
                    winningSide = side;
                }
            }
            r.unanimous = (revealCount > 0 && maxVotes == revealCount);
            r.meetsThreshold = (revealCount > 0 && maxVotes * 3 >= revealCount * 2);
            r.verdict = new uint8[](1);
            r.verdict[0] = winningSide;
        }   r.finalized = true;

        emit RoundFinalized(marketId, round);
    }

    function getStoredVerdict(uint64 marketId, uint8 round)
        external view returns (uint8[] memory verdict,
        bool unanimous, bool meetsThreshold) {
        Round storage r = rounds[marketId][round];
        return (r.verdict, r.unanimous, r.meetsThreshold);
    }

    function _selectAndLockJuror(uint64 marketId,
        address candidate, Round storage r) internal returns (bool) {
        if (hasServed[marketId][candidate]) return false;
        uint balance = Basket(basket).balanceOf(candidate);
        uint stake = (balance * 2000) / 10000;
        r.jurors.push(candidate);

        hasServed[marketId][candidate] = true;
        lockedStake[marketId][candidate] = stake;
        Basket(basket).lockForJury(candidate, stake);
        return true;
    }

    function _getMultiWinner(uint64 marketId, uint8 round, Round storage r)
        internal view returns (uint8[] memory, bool, bool) {
        uint8[][] memory positionVotes = new uint8[][](r.numWinners);
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            positionVotes[pos] = new uint8[](r.numSides);
        }
        uint revealCount = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) revealCount++;
        }
        for (uint i = 0; i < revealCount; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) {
                uint8[] memory ranking = votes[marketId][round][juror];
                for (uint8 pos = 0; pos < r.numWinners && pos < ranking.length; pos++) {
                    if (ranking[pos] < r.numSides) {
                        positionVotes[pos][ranking[pos]]++;
                    }
                }
            }
        } uint8[] memory winners = new uint8[](r.numWinners);
        uint8[] memory winnerVotes = new uint8[](r.numWinners);
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            uint8 maxVotes = 0;
            for (uint8 side = 0; side < r.numSides; side++) {
                if (positionVotes[pos][side] > maxVotes ||
                    (positionVotes[pos][side] == maxVotes &&
                    uint(keccak256(abi.encodePacked(
                        blockhash(block.number - 1),
                        pos, side))) % 2 == 0)) {
                            maxVotes = positionVotes[pos][side];
                            winners[pos] = side;
                }
            } winnerVotes[pos] = maxVotes;
        }
        if (revealCount == 0) {
            return (winners, false, false);  // Hung jury
        }
        // Check threshold (2/3 majority) for each position
        bool meetsThreshold = true;
        uint threshold = (revealCount * 2) / 3;
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            if (winnerVotes[pos] < threshold) {
                meetsThreshold = false;
                break;
            }
        }
        // Unanimous = all jurors voted exactly the same ranking
        bool unanimous = true;
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            if (winnerVotes[pos] != revealCount) {
                unanimous = false;
                break;
            }
        } return (winners, unanimous, meetsThreshold);
    }

    function getCorrectJurors(uint64 marketId,
        uint8 round) external view returns (address[] memory) {
        Round storage r = rounds[marketId][round];
        uint8[] memory finalVerdict = r.verdict;
        uint correct = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror] &&
                _verdictMatches(votes[marketId][round][juror], finalVerdict)) {
                correct++;
            }
        } address[] memory correctJurors = new address[](correct);
        uint idx = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror] &&
                _verdictMatches(votes[marketId][round][juror], finalVerdict)) {
                correctJurors[idx++] = juror;
            }
        } return correctJurors;
    }

    function isJuror(uint64 marketId, uint8 round,
        address addr) external view returns (bool) {
        Round storage r = rounds[marketId][round];
        for (uint i = 0; i < r.jurors.length; i++) {
            if (r.jurors[i] == addr) return true;
        }
        return false;
    }

    function _processRoundJurors(uint64 marketId,
        uint8 r, uint8[] memory finalVerdict,
        address[] memory correctJurors, uint correctCount)
        internal returns (uint slashed, uint newCorrectCount) {
        Round storage round = rounds[marketId][r];
        newCorrectCount = correctCount;

        for (uint i = 0; i < round.revealedIndices.length; i++) {
            uint jurorIndex = round.revealedIndices[i];
            address juror = round.jurors[jurorIndex];
            uint stake = lockedStake[marketId][juror];
            if (stake == 0) continue;
            if (!revealed[marketId][r][juror]) {
                Basket(basket).unlockFromJury(juror, stake);
                Basket(basket).turn(juror, stake);
                slashed += stake;
                emit JurorSlashed(juror, stake);
            } else if (_verdictMatches(votes[marketId][r][juror], finalVerdict)) {
                Basket(basket).unlockFromJury(juror, stake);
                correctJurors[newCorrectCount++] = juror;
            } else {
                // Minority voter: stake returned, no compensation
                // Incentive preserved: majority gets pool share, minority gets nothing
                Basket(basket).unlockFromJury(juror, stake);
            }
            lockedStake[marketId][juror] = 0;
        }
        for (uint i = 0; i < round.jurors.length; i++) {
            address juror = round.jurors[i];
            uint stake = lockedStake[marketId][juror];
            if (stake > 0) {
                Basket(basket).unlockFromJury(juror, stake);
                lockedStake[marketId][juror] = 0;
            }
        }
    }

    function _verdictMatches(uint8[] memory a,
        uint8[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function setAppellant(uint64 marketId,
        uint8 round, address appellant) external onlyCourt {
        rounds[marketId][round].appellant = appellant;
    }

    function getAppellant(uint64 marketId,
        uint8 round) external view returns (address) {
        return rounds[marketId][round].appellant;
    }

    function getJurors(uint64 marketId,
        uint8 round) external view
        returns (address[] memory) {
        return rounds[marketId][round].jurors;
    }

    function _getMarketConfig(uint64 marketId) internal
        view returns (uint8 numSides, uint8 numWinners,
        bool requiresUnanimous, bool requiresSignature) {
        return ICourt(court).getMarketConfig(marketId);
    }
}
