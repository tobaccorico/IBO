// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Jury} from "./Jury.sol";
import {Proof} from "./Proof.sol";
import {Basket} from "./Basket.sol";
import {MessageCodec} from "./imports/MessageCodec.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

contract Court is Ownable, ReentrancyGuard {
    mapping(address => bool) public authorizedBaskets;
    mapping(uint64 => address) public marketToBasket;

    Jury public immutable jury;
    Proof public immutable proof;

    uint constant APPEAL_WINDOW = 7 days;
    uint8 constant EXTENSION_MARKER = 101;

    uint constant MAX_APPEALS = 3;
    uint constant MAX_HUNG_JURIES = 3;
    uint constant MAX_TOTAL_ROUNDS = 10;

    uint constant COMMIT_PERIOD = 4 days;
    uint constant REVEAL_WINDOW = 12 hours;
    uint constant FINALIZE_BLOCK_WINDOW = 50;

    enum AppealGround {
        HUNG_JURY, INCORRECT_VERDICT,
        NEW_EVIDENCE, FABRICATION,
        BIAS, EXCLUSIONARY
    }
    struct Appeal {
        address appellant;
        AppealGround ground;
        uint[] affidavitIds;
        string reasoning;
        uint timestamp;
        bool sustained;
        uint cost;
    }

    struct Resolution {
        uint8 numSides;
        uint8 numWinners;
        bool requiresUnanimous;
        bool requiresAppSignature;
        bool isDepegMarket;
        bool allowsExtensions;
        uint8 currentRound;
        uint8 hungJuryCount;
        uint8 appealCount;
        uint appealCost;
        uint8[] verdict;
        bytes32 resolutionRequester;
        bytes32[] slashingAddresses;
        uint8[] slashingSides;
    }

    mapping(uint64 => bytes) public rulingData;
    mapping(uint64 => Resolution) public resolutions;
    mapping(uint64 => uint) public roundStartTime;
    mapping(uint64 => uint) public verdictTimestamp;
    mapping(uint64 => uint) public finalizeEligibleBlock;
    mapping(uint64 => mapping(uint8 => Appeal)) public appeals;

    event VerdictReached(uint64 indexed marketId, uint8 round, uint8[] verdict);
    event HungJury(uint64 indexed marketId, uint8 round, uint8 count);
    event JurySelectionFailed(uint64 indexed marketId, uint8 round);
    event JurySelectionComplete(uint64 indexed marketId, uint8 round);
    event AppealFiled(uint64 indexed marketId, uint8 round, address appellant,
             AppealGround ground, uint[] affidavitIds, uint8 appealCount);

    event MarketDataEvicted(uint64 indexed marketId, uint gasRefund);
    event AppealResult(uint64 indexed marketId, uint8 round, bool sustained);
    event ResolutionFinalized(uint64 indexed marketId, uint8[] verdict);
    event MarketExtended(uint64 indexed marketId);
    event ForceMajeure(uint64 indexed marketId);
    event BasketAdded(address indexed basket);
    event CourtSealed();
    event MissedWindowRecovery(uint64 indexed marketId, uint8 round);

    error ResolutionActive();
    error CompensationPending();
    error NoVerdictToAppeal();
    error AlreadyFinalized();
    error MaxRoundsExceeded();
    error MaxAppealsReached();
    error Unauthorized();
    error OutsideFinalizeWindow();
    error AppealWindowActive();
    error NoVerdictToExecute();
    error AlreadyExecuted();
    error ZeroAddress();
    error AlreadyAuthorized();
    error NoBasketForMarket();
    error WindowNotExpired();
    error WrongRound();
    error RoundNotStarted();
    error JuryNotSelected();
    error JuryAlreadySelected();
    error NoPendingFinalization();
    error HasVerdict();
    error NoVerdictStored();
    error AppealLate();
    error SpecifyAffidavits();
    error FinalizationIncomplete();
    error TooEarly();

    constructor(address _firstBasket,
        address _jury, address _proof) Ownable(msg.sender) {
        if (_firstBasket == address(0)) revert ZeroAddress();
        authorizedBaskets[_firstBasket] = true;
        emit BasketAdded(_firstBasket);
        jury = Jury(_jury);
        proof = Proof(_proof);
    }

    receive() external payable {}

    function addBasket(address _basket) external onlyOwner {
        if (_basket == address(0)) revert ZeroAddress();
        if (authorizedBaskets[_basket]) revert AlreadyAuthorized();
        authorizedBaskets[_basket] = true;
        emit BasketAdded(_basket);
    }

    function sealAndRenounce() external onlyOwner {
        emit CourtSealed();
        renounceOwnership();
    }

    function registerDepegMarket(uint64 marketId, address stablecoin) external onlyOwner {
        jury.registerDepegMarket(marketId, stablecoin);
    }

    function receiveResolutionRequest(bytes calldata lzMessage) external {
        if (!authorizedBaskets[msg.sender]) revert Unauthorized();

        MessageCodec.ResolutionRequestData memory req = MessageCodec.decodeResolutionRequest(lzMessage);
        Resolution storage res = resolutions[req.marketId];

        // If a previous resolution exists but compensation not yet distributed,
        // block new requests to prevent overwriting state needed for distribution
        if (verdictTimestamp[req.marketId] > 0 && !jury.isCompensationDistributed(req.marketId)) {
            revert CompensationPending();
        }

        // After compensation distributed, clearPostDistribution clears numSides
        // So this check handles both first resolution AND re-resolution
        if (res.numSides != 0) revert ResolutionActive();

        // Reset compensation state for new resolution cycle
        // This handles re-resolution case where distributed=true from previous cycle
        jury.resetCompensation(req.marketId);

        // Reset proof state for new resolution (clears submission counts)
        proof.resetForNewResolution(req.marketId);

        res.requiresAppSignature = req.requiresSignature;
        res.requiresUnanimous = req.requiresUnanimous;
        res.numWinners = req.numWinners;
        res.isDepegMarket = req.isDepegMarket;
        res.allowsExtensions = req.allowsExtensions;
        res.resolutionRequester = req.requester;
        res.appealCost = req.appealCost;
        res.numSides = req.numSides;

        marketToBasket[req.marketId] = msg.sender;
        proof.updateMerkleRoot(req.marketId, req.merkleRoot);
        roundStartTime[req.marketId] = block.timestamp;
    }

    function progressToJurySelection(uint64 marketId, uint8 round,
        bytes[] calldata headers) external nonReentrant {
        Resolution storage res = resolutions[marketId];
        if (res.currentRound != round) revert WrongRound();
        if (roundStartTime[marketId] == 0) revert RoundNotStarted();
        // Prevent re-selection if jury already selected for this round
        if (finalizeEligibleBlock[marketId] != 0) revert JuryAlreadySelected();

        bool success = jury.voirDire(marketId, round, headers);
        if (!success) { res.hungJuryCount++;
            if (res.hungJuryCount >= MAX_HUNG_JURIES) {
                res.verdict = new uint8[](0);
                _sendRuling(marketId);
                emit ForceMajeure(marketId);
                return;
            }
            emit JurySelectionFailed(marketId, round);
            return;
        }
        uint blocksUntilRevealEnd = (COMMIT_PERIOD + REVEAL_WINDOW) / 12;
        finalizeEligibleBlock[marketId] = block.number + blocksUntilRevealEnd;
        emit JurySelectionComplete(marketId, round);
    }

    function finalizeRound(uint64 marketId,
        bytes[] calldata headers) external nonReentrant {
        uint eligible = finalizeEligibleBlock[marketId];
        if (eligible == 0) revert JuryNotSelected();
        if (block.number < eligible || block.number > eligible + FINALIZE_BLOCK_WINDOW) {
            revert OutsideFinalizeWindow();
        }
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] != 0 &&
            block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW)
            revert AlreadyFinalized();

        jury.finalizeRound(marketId, res.currentRound,
            roundStartTime[marketId], headers);

        (uint8[] memory verdict, bool unanimous, bool meetsThreshold) =
            jury.getStoredVerdict(marketId, res.currentRound);

        if (!meetsThreshold || (res.requiresUnanimous && !unanimous)) {
            _handleHungJury(marketId);
            return;
        }
        address appellant = jury.getAppellant(marketId, res.currentRound);
        if (appellant != address(0)) {
            bool sustained = !_verdictMatches(res.verdict, verdict);
            appeals[marketId][res.currentRound].sustained = sustained;
            if (sustained) {
                uint cost = appeals[marketId][res.currentRound].cost;
                jury.refundAppealCost(marketId, cost);
                Basket(marketToBasket[marketId]).transfer(appellant, cost);
            } else if (unanimous) {
                // Failed frivolous appeal with unanimous verdict - finalize immediately
                // Appellant penalty: appeal cost already burned (not refunded)
                _finalize(marketId);
                emit AppealResult(marketId, res.currentRound, false);
                return;
            }
            emit AppealResult(marketId, res.currentRound, sustained);
        }
        res.verdict = verdict;
        verdictTimestamp[marketId] = block.timestamp;

        if (verdict.length == 1) {
            if (verdict[0] == EXTENSION_MARKER) {
                _collectBadAffidavits(marketId);
                _sendRuling(marketId);
                emit MarketExtended(marketId);
                return;
            }
        }
        emit VerdictReached(marketId, res.currentRound, verdict);
    }

    function recoverMissedWindow(uint64 marketId) external nonReentrant {
        uint eligible = finalizeEligibleBlock[marketId];
        if (eligible == 0) revert NoPendingFinalization();
        if (block.number <= eligible + FINALIZE_BLOCK_WINDOW) revert WindowNotExpired();
        // Only block if we have a verdict AND no appeal round is active
        // (roundStartTime > verdictTimestamp means appeal filed, new round started)
        if (verdictTimestamp[marketId] != 0 &&
            roundStartTime[marketId] <= verdictTimestamp[marketId]) revert HasVerdict();

        emit MissedWindowRecovery(marketId, resolutions[marketId].currentRound);
        _handleHungJury(marketId);
    }

    error AppealRoundInProgress();

    function executeVerdict(uint64 marketId) external nonReentrant {
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToExecute();
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) revert AppealWindowActive();
        // Prevent execution during active appeal round
        // If roundStartTime > verdictTimestamp, an appeal was filed and new round started
        if (roundStartTime[marketId] > verdictTimestamp[marketId]) revert AppealRoundInProgress();
        if (rulingData[marketId].length > 0) revert AlreadyExecuted();
        if (res.verdict.length == 0) revert NoVerdictStored();

        // Slashed appeal costs transferred when Jury distributes (via transferSlashedToJury)
        jury.tryDistribute(marketId);
        _finalize(marketId);
    }

    function fileAppeal(uint64 marketId, AppealGround ground,
        uint[] calldata affidavitIds, string calldata reasoning)
        external nonReentrant returns (uint8) {
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToAppeal();
        if (block.timestamp > verdictTimestamp[marketId] + APPEAL_WINDOW) revert AppealLate();
        // Cannot appeal after ruling already sent (force majeure/extension/frivolous appeal)
        if (rulingData[marketId].length > 0) revert AlreadyExecuted();
        // Prevent filing multiple appeals before jury selection
        // An appeal round is active if roundStartTime > verdictTimestamp
        if (roundStartTime[marketId] > verdictTimestamp[marketId]) revert AppealRoundInProgress();
        if (res.appealCount >= MAX_APPEALS) revert MaxAppealsReached();
        if (ground == AppealGround.FABRICATION || ground == AppealGround.BIAS ||
            ground == AppealGround.EXCLUSIONARY) {
            if (affidavitIds.length == 0) revert SpecifyAffidavits();
        }
        uint cost = _appealCost(marketId, res.appealCount);
        Basket(marketToBasket[marketId]).transferFrom(msg.sender, address(this), cost);
        jury.addSlashedEth(marketId, cost);

        res.appealCount++;
        res.currentRound++;
        if (res.currentRound >= MAX_TOTAL_ROUNDS) revert MaxRoundsExceeded();

        appeals[marketId][res.currentRound] = Appeal({
            appellant: msg.sender,
            ground: ground,
            affidavitIds: affidavitIds,
            reasoning: reasoning,
            timestamp: block.timestamp,
            cost: cost,
            sustained: false
        });
        delete finalizeEligibleBlock[marketId];
        roundStartTime[marketId] = block.timestamp;
        jury.setAppellant(marketId, res.currentRound, msg.sender);

        emit AppealFiled(marketId, res.currentRound,
        msg.sender, ground, affidavitIds, res.appealCount);
        return res.currentRound;
    }

    function _finalize(uint64 marketId) internal {
        _collectBadAffidavits(marketId);
        _sendRuling(marketId); _evictMarketData(marketId);
        emit ResolutionFinalized(marketId, resolutions[marketId].verdict);
    }

    function _evictMarketData(uint64 marketId) internal {
        Resolution storage res = resolutions[marketId];
        uint8 maxRound = res.currentRound;

        // Clear state not needed for jury compensation
        // Preserve: verdict, currentRound, verdictTimestamp, marketToBasket (needed for _tryDistribute)
        // numSides stays non-zero to indicate this market was resolved (blocks duplicate requests)
        res.numWinners = 0;
        res.requiresAppSignature = false;
        res.requiresUnanimous = false;
        res.hungJuryCount = 0;
        res.appealCost = 0;
        res.appealCount = 0;
        res.resolutionRequester = bytes32(0);
        res.isDepegMarket = false;
        res.allowsExtensions = false;

        delete res.slashingSides;
        delete res.slashingAddresses;

        for (uint8 i = 0; i <= maxRound; i++) {
            delete appeals[marketId][i].affidavitIds;
            delete appeals[marketId][i].reasoning;
        }

        delete roundStartTime[marketId];
        delete finalizeEligibleBlock[marketId];
        uint slotsCleared = 10 + maxRound * 5;
        emit MarketDataEvicted(marketId, slotsCleared * 15000);
    }

    function _collectBadAffidavits(uint64 marketId) internal {
        Resolution storage res = resolutions[marketId];
        (bool complete, uint cursor,
        uint total) = proof.getFinalizationStatus(marketId);
        if (total == 0) return;
        if (!complete && cursor == 0) {
            proof.finalizeEvaluations(marketId, res.currentRound);
            (complete,,) = proof.getFinalizationStatus(marketId);
        }
        if (!complete) revert FinalizationIncomplete();
        (bytes32[] memory badAddresses,
           uint8[] memory badSides) = proof.getBadAffidavitAddresses(marketId);

        uint remaining = res.slashingAddresses.length < 100
                 ? 100 - res.slashingAddresses.length : 0;

        uint toAdd = badAddresses.length < remaining ?
                     badAddresses.length : remaining;

        for (uint i = 0; i < toAdd; i++) {
            res.slashingAddresses.push(badAddresses[i]);
            res.slashingSides.push(badSides[i]);
        }   proof.resetFinalization(marketId);
    }

    function _handleHungJury(uint64 marketId) internal {
        Resolution storage res = resolutions[marketId]; res.hungJuryCount++;
        emit HungJury(marketId, res.currentRound, res.hungJuryCount);

        if (res.hungJuryCount < MAX_HUNG_JURIES
         && res.currentRound + 1 < MAX_TOTAL_ROUNDS) {
            // Copy appellant to next round if this was an appeal round
            address currentAppellant = jury.getAppellant(marketId, res.currentRound);
            uint currentAppealCost = appeals[marketId][res.currentRound].cost;
            res.currentRound++;
            if (currentAppellant != address(0)) {
                // Carry forward appellant tracking for hung jury retry
                jury.setAppellant(marketId, res.currentRound, currentAppellant);
                appeals[marketId][res.currentRound].appellant = currentAppellant;
                appeals[marketId][res.currentRound].cost = currentAppealCost;
            }
            delete finalizeEligibleBlock[marketId];
            roundStartTime[marketId] = block.timestamp;
        } else {
            if (res.isDepegMarket && !res.allowsExtensions) {
                // Force majeure: market cancelled, no winners
                // Resolution requester not explicitly slashed - force majeure
                // already punishes all participants via lost positions
                delete res.verdict;
                _collectBadAffidavits(marketId);
                _sendRuling(marketId);
                emit ForceMajeure(marketId);
            } else {
                res.verdict = new uint8[](1);
                res.verdict[0] = EXTENSION_MARKER;
                _collectBadAffidavits(marketId);
                _sendRuling(marketId);
                emit MarketExtended(marketId);
            }
        }
    }

    function _sendRuling(uint64 marketId) internal {
        // Set verdictTimestamp if not already set (for force majeure/extension paths)
        // This ensures _tryDistribute in Jury can proceed after appeal window
        if (verdictTimestamp[marketId] == 0) {
            verdictTimestamp[marketId] = block.timestamp;
        }

        Resolution storage res = resolutions[marketId];
        bytes memory message = MessageCodec.encodeFinalRuling(
            marketId, res.verdict,
            res.slashingAddresses, res.slashingSides);

        rulingData[marketId] = message;
        address originatingBasket = marketToBasket[marketId];
        if (originatingBasket == address(0)) revert NoBasketForMarket();
        Basket(originatingBasket).sendToSolana{value: 0.05 ether}(message);
    }

    function _verdictMatches(uint8[] memory a,
        uint8[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _appealCost(uint64 marketId,
        uint8 appealIndex) internal view returns (uint) {
        uint base = resolutions[marketId].appealCost;
        for (uint i = 0; i < appealIndex; i++) {
            base = (base * 15000) / 10000;
        }
        return base;
    }

    error RulingNotSent();

    /// @notice Timeout if jury compensation never arrives from Solana
    /// @param marketId The market ID
    function timeoutJuryCompensation(uint64 marketId) external nonReentrant {
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToExecute();
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) revert TooEarly();
        // Ruling must have been sent before we can timeout waiting for compensation
        if (rulingData[marketId].length == 0) revert RulingNotSent();
        // If ruling not sent, prevent timeout during active appeal round
        // (But if rulingData exists, resolution is final regardless of roundStartTime)
        if (jury.isCompensationReceived(marketId)) revert AlreadyExecuted();
        // Slashed appeal costs transferred when Jury distributes (via transferSlashedToJury)
        jury.markCompensationTimedOut(marketId);
        jury.tryDistribute(marketId);
    }

    function transferSlashedToJury(uint64 marketId) external {
        require(msg.sender == address(jury), "Only jury");
        uint slashed = jury.getSlashedAmount(marketId);
        if (slashed > 0) {
            Basket(marketToBasket[marketId]).transfer(address(jury), slashed);
            jury.clearSlashedAmount(marketId);
        }
    }

    /// @notice Called by Jury after compensation distributed to clear remaining preserved state
    function clearPostDistribution(uint64 marketId) external {
        require(msg.sender == address(jury), "Only jury");
        // Clear state that was preserved for distribution
        delete verdictTimestamp[marketId];
        delete marketToBasket[marketId];
        delete rulingData[marketId];
        // Clear state that might be stale from force majeure paths
        delete roundStartTime[marketId];
        delete finalizeEligibleBlock[marketId];
        Resolution storage res = resolutions[marketId];
        res.currentRound = 0;
        res.numSides = 0;  // Allow new resolution request
        res.hungJuryCount = 0;  // Reset for new resolution
        res.appealCount = 0;    // Reset for new resolution
        res.appealCost = 0;     // Reset for new resolution
        delete res.verdict;
        // Clear slashing arrays to prevent accumulation across re-resolutions
        delete res.slashingAddresses;
        delete res.slashingSides;
    }

    function isInResolutionPhase(uint64 marketId) external view returns (bool) {
        return roundStartTime[marketId] > 0 && verdictTimestamp[marketId] == 0;
    }

    function getRequiresAppSignature(uint64 marketId)
        external view returns (bool) {
        return resolutions[marketId].requiresAppSignature;
    }

    function getMarketConfig(uint64 marketId) external
        view returns (uint8 numSides, uint8 numWinners,
        bool requiresUnanimous, bool requiresSignature) {
        Resolution storage res = resolutions[marketId];
        return (res.numSides, res.numWinners,
            res.requiresUnanimous,
            res.requiresAppSignature);
    }

    function getRoundStartTime(uint64 marketId)
        external view returns (uint) {
        return roundStartTime[marketId];
    }

    function getCurrentRound(uint64 marketId)
        external view returns (uint8) {
        return resolutions[marketId].currentRound;
    }

    function getVerdictTimestamp(uint64 marketId)
        external view returns (uint) {
        return verdictTimestamp[marketId];
    }

    function getFinalVerdict(uint64 marketId)
        external view returns (uint8[] memory) {
        return resolutions[marketId].verdict;
    }

    function getAppeal(uint64 marketId, uint8 round) external view returns (
        address appellant, AppealGround ground, uint[] memory affidavitIds,
        string memory reasoning, uint timestamp, uint cost, bool sustained) {
        Appeal storage appeal = appeals[marketId][round];
        return (appeal.appellant, appeal.ground, appeal.affidavitIds,
                appeal.reasoning, appeal.timestamp, appeal.cost, appeal.sustained);
    }

    function getFinalizeWindow(uint64 marketId) external
        view returns (uint eligibleBlock, uint windowEnd) {
        eligibleBlock = finalizeEligibleBlock[marketId];
        windowEnd = eligibleBlock + FINALIZE_BLOCK_WINDOW;
    }

    function isReadyForExecution(uint64 marketId)
        external view returns (bool ready, string memory reason) {
        if (verdictTimestamp[marketId] == 0) return (false, "No verdict yet");
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) return (false, "Appeal window active");
        if (rulingData[marketId].length > 0) return (false, "Already executed");
        if (resolutions[marketId].verdict.length == 0) return (false, "No verdict stored");
        (bool finalized,, uint total) = proof.getFinalizationStatus(marketId);
        if (total > 0 && !finalized) return (false, "Affidavit finalization not complete");
        return (true, "");
    }
}
