
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Basket} from "./Basket.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface ICourt {
    function getMarketConfig(uint64 marketId) external view returns (
    uint8 numSides, uint8 numWinners, bool requiresUnanimous, bool requiresSignature);
    function isInResolutionPhase(uint64 marketId) external view returns (bool);
    function getRequiresAppSignature(uint64 marketId) external view returns (bool);
    function getCurrentRound(uint64 marketId) external view returns (uint8);
}

interface IJury {
    function isJuror(uint64 marketId, uint8 round, address addr) external view returns (bool);
    function getJurors(uint64 marketId, uint8 round) external view returns (address[] memory);
    function getCorrectJurors(uint64 marketId, uint8 round) external view returns (address[] memory);
}

contract Proof is ReentrancyGuard, Ownable {
    enum EvalType { CONCURRING, MAJORITY, // +
      DISSENTING_RELEVANCY, DISSENTING_ACCURACY } // -
    enum AffidavitQuality { NOT_EVALUATED, GOOD, BAD }

    struct Affidavit {
        address witness;
        string evidenceUrl;
        bytes32 contentHash;
        uint64 timestamp;
        uint8 supportedSide;
        bytes32 solanaKey;
        AffidavitQuality quality;
    }

    struct AffidavitParams {
        uint64 marketId;
        string evidenceUrl;
        bytes32 contentHash;
        uint8 supportedSide;
        bytes32 solanaKey;
        bytes32[] merkleProof;
        bytes ethSig;
        bytes appSig;
        uint64 timestamp;
    }

    struct AffidavitStats {
        uint8 concurringCount;
        uint8 majorityCount;
        uint8 dissRelevancy;
        uint8 dissAccuracy;
    }

    struct Evaluation {
        address evaluator;
        EvalType evalType;
        string reasoning;
        uint64 timestamp;
    }

    struct BatchEvaluation {
        uint affidavitId;
        EvalType evalType;
        string reasoning;
    }

    struct FinalizationState {
        uint cursor; // Next affidavit index to process
        bool complete; // Whether finalization is done
        address[] correctJurors; // Cached for this round
        bytes32[] badAddresses;
        uint8[] badSides;
    }

    address public immutable basket;
    address public court;
    address public jury;

    uint public constant MAX_AFFIDAVITS_PER_ADDRESS = 4;
    uint public constant MAX_BATCH_SIZE = 5000;
    uint public constant FINALIZE_BATCH_SIZE = 50;

    mapping(bytes32 => bool) public approvedAppKeys;
    mapping(uint64 => bytes32) public merkleRoots;
    mapping(uint64 => Affidavit[]) public affidavits;

    mapping(uint64 => mapping(uint => Evaluation[])) public evaluations;
    mapping(uint64 => mapping(address => uint)) public evaluationCount;
    mapping(uint64 => mapping(uint => AffidavitStats)) public stats;
    mapping(uint64 => mapping(address => uint)) public submissionCount;
    mapping(uint64 => mapping(uint => mapping(address => bool))) public hasEvaluated;
    mapping(uint64 => mapping(uint => mapping(address => EvalType))) public evalTypes;
    mapping(uint64 => mapping(address => uint)) public jurorLastResolutionStart;

    mapping(uint64 => FinalizationState) public finalizationState;
    mapping(uint64 => uint) public resolutionStartIndex;
    mapping(uint64 => mapping(address => uint)) public currentResolutionEvalCount;

    event AffidavitSubmitted(uint64 indexed marketId, uint indexed affidavitId, address witness, uint8 supportedSide);
    event BatchEvaluated(uint64 indexed marketId, address indexed juror, uint count);
    event AffidavitQualitySet(uint64 indexed marketId, uint indexed affidavitId, AffidavitQuality quality);
    event FinalizationProgress(uint64 indexed marketId, uint processed, uint total);

    error MaxSubmissionsReached();
    error InvalidMerkleProof();
    error NotJuror();
    error AppSigExpired();
    error SubmissionsClosed();
    error AlreadyEvaluated();
    error CannotEvaluateOwnAffidavit();
    error ReasoningRequired();
    error InvalidAffidavit();
    error BatchTooLarge();
    error FinalizationAlreadyComplete();

    constructor(address _basket) Ownable(msg.sender) {
        basket = _basket;
    }

    function setCourt(address _court) external onlyOwner {
        require(court == address(0), "Already set");
        court = _court;
    }

    function setJury(address _jury) external onlyOwner {
        require(jury == address(0), "Already set");
        jury = _jury;
    }

    function approveAppKey( // no jailbreakers
        bytes32 appKeyHash) external onlyOwner {
        approvedAppKeys[appKeyHash] = true;
    }

    function updateMerkleRoot(
        uint64 marketId, bytes32 merkleRoot) external {
        require(msg.sender == court || msg.sender == basket, "Only court/basket");
        merkleRoots[marketId] = merkleRoot;
    }

    function submitAffidavit(AffidavitParams calldata p)
        external returns (uint affidavitId) {
        require(ICourt(court).isInResolutionPhase(p.marketId), "Not in resolution phase");
        (uint8 numSides,,,) = ICourt(court).getMarketConfig(p.marketId);
        require(p.supportedSide < numSides, "Invalid side");
        uint8 currentRound = ICourt(court).getCurrentRound(p.marketId);
        if (IJury(jury).getJurors(p.marketId, currentRound).length == 21) {
            revert SubmissionsClosed();
        }
        if (submissionCount[p.marketId][msg.sender] >= MAX_AFFIDAVITS_PER_ADDRESS)
            revert MaxSubmissionsReached();

        if (!_verifyMerkleProof(p.merkleProof,
            merkleRoots[p.marketId],
            p.solanaKey, msg.sender))
            revert InvalidMerkleProof();

        _verifySignatures(p.marketId, p.solanaKey, p.contentHash,
            p.supportedSide, p.timestamp, p.ethSig, p.appSig);

        affidavitId = affidavits[p.marketId].length;
        affidavits[p.marketId].push(Affidavit({ witness: msg.sender,
            evidenceUrl: p.evidenceUrl, contentHash: p.contentHash,
            timestamp: uint64(block.timestamp), supportedSide: p.supportedSide,
            solanaKey: p.solanaKey, quality: AffidavitQuality.NOT_EVALUATED
        }));
        submissionCount[p.marketId][msg.sender]++;
        emit AffidavitSubmitted(p.marketId,
          affidavitId, msg.sender, p.supportedSide);
    }

    function _verifySignatures(uint64 marketId, bytes32 solanaKey,
        bytes32 contentHash, uint8 supportedSide, uint64 timestamp,
        bytes calldata ethSig, bytes calldata appSig) internal view {
        uint8 currentRound = ICourt(court).getCurrentRound(marketId);
        bytes32 msgHash = keccak256(abi.encodePacked(
            "QU!D", marketId, currentRound, solanaKey, block.chainid
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19claro:\n32", msgHash));
        require(ECDSA.recover(ethSigned, ethSig) == msg.sender, "sig");

        if (_requiresAppSignature(marketId)) {
            require(appSig.length > 0, "App signature required");
            if (block.timestamp > timestamp + 1 hours) revert AppSigExpired();
            bytes32 appSigned = keccak256(abi.encodePacked(
                "\x19claro:\n32", msg.sender, msgHash, contentHash, supportedSide, timestamp
            ));
            address appSigner = ECDSA.recover(appSigned, appSig);
            require(approvedAppKeys[keccak256(abi.encodePacked(appSigner))], "sig");
        }
    }

    function _verifyMerkleProof(bytes32[] calldata proof, bytes32 root,
        bytes32 solanaKey, address ethSigner) internal pure returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(solanaKey, ethSigner));
        bytes32 computedHash = keccak256(abi.encodePacked(leaf));
        for (uint i = 0; i < proof.length; i++) {
            computedHash = computedHash < proof[i]
                ? keccak256(abi.encodePacked(
                      computedHash, proof[i]))
                : keccak256(abi.encodePacked(
                      proof[i], computedHash));
        }          return computedHash == root;
    }

    function submitBatchEvaluations(uint64 marketId,
        BatchEvaluation[] calldata evals) external {
        uint8 currentRound = ICourt(court).getCurrentRound(marketId);
        if (!IJury(jury).isJuror(marketId, currentRound, msg.sender)) revert NotJuror();
        if (evals.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint i = 0; i < evals.length; i++)
            _processEvaluation(marketId, evals[i]);

        emit BatchEvaluated(marketId, msg.sender, evals.length);
    }

    function _processEvaluation(uint64 marketId, BatchEvaluation calldata eval) internal {
        if (eval.affidavitId >= affidavits[marketId].length) revert InvalidAffidavit();
        if (hasEvaluated[marketId][eval.affidavitId][msg.sender]) revert AlreadyEvaluated();
        Affidavit storage affidavit = affidavits[marketId][eval.affidavitId];

        if (affidavit.witness == msg.sender) revert CannotEvaluateOwnAffidavit();
        if ((eval.evalType == EvalType.CONCURRING ||
             eval.evalType == EvalType.DISSENTING_ACCURACY) &&
            bytes(eval.reasoning).length == 0) {
            revert ReasoningRequired();
        }
        hasEvaluated[marketId][eval.affidavitId][msg.sender] = true;
        evaluationCount[marketId][msg.sender]++;

        // Track evaluations of NEW affidavits (current resolution) separately
        if (eval.affidavitId >= resolutionStartIndex[marketId]) {
            // Reset count if this is the first evaluation in a new resolution
            if (jurorLastResolutionStart[marketId][msg.sender] != resolutionStartIndex[marketId]) {
                currentResolutionEvalCount[marketId][msg.sender] = 0;
                jurorLastResolutionStart[marketId][msg.sender] = resolutionStartIndex[marketId];
            }
            currentResolutionEvalCount[marketId][msg.sender]++;
        }
        evalTypes[marketId][eval.affidavitId][msg.sender] = eval.evalType;
        AffidavitStats storage s = stats[marketId][eval.affidavitId];
        if (eval.evalType == EvalType.CONCURRING) { s.concurringCount++;
            evaluations[marketId][eval.affidavitId].push(Evaluation({
                evaluator: msg.sender, evalType: eval.evalType,
                reasoning: eval.reasoning, timestamp: uint64(block.timestamp)
            }));
        } else if (eval.evalType == EvalType.MAJORITY) {
            s.majorityCount++;
        } else if (eval.evalType == EvalType.DISSENTING_RELEVANCY) {
            s.dissRelevancy++;
        } else if (eval.evalType == EvalType.DISSENTING_ACCURACY) {
            s.dissAccuracy++;
            evaluations[marketId][eval.affidavitId].push(Evaluation({
                evaluator: msg.sender, evalType: eval.evalType,
                reasoning: eval.reasoning,
                timestamp: uint64(block.timestamp)
            }));
        }
    }

    /// @notice Initialize finalization - called by Court
    /// @dev Sets up state for batched processing
    /// @param marketId The market ID
    /// @param round The round number
    function finalizeEvaluations(uint64 marketId,
        uint8 round) external { require(msg.sender == court, "Only court");
        FinalizationState storage state = finalizationState[marketId];
        if (state.complete) return;
        if (state.correctJurors.length == 0) {
            state.correctJurors = IJury(jury).getCorrectJurors(marketId, round);
            // Start from resolutionStartIndex to skip
            // old affidavits from previous resolutions
            state.cursor = resolutionStartIndex[marketId];
        }
        uint totalAffidavits = affidavits[marketId].length;
        uint endIndex = state.cursor + FINALIZE_BATCH_SIZE;
        if (endIndex > totalAffidavits) endIndex = totalAffidavits;

        for (uint i = state.cursor; i < endIndex; i++) {
            _finalizeAffidavit(marketId, i, state.correctJurors);
        }
        state.cursor = endIndex;
        if (state.cursor >= totalAffidavits) {
            state.complete = true;
        }
        emit FinalizationProgress(marketId,
          state.cursor, totalAffidavits);
    }

    /// @notice Continue finalization - can be called by anyone if not complete
    /// @dev Allows keepers to help process large batches
    /// @param marketId The market ID
    function continueFinalization(uint64 marketId) external {
        FinalizationState storage state = finalizationState[marketId];
        require(state.correctJurors.length > 0, "Not initialized");
        if (state.complete) revert FinalizationAlreadyComplete();

        uint totalAffidavits = affidavits[marketId].length;
        uint endIndex = state.cursor + FINALIZE_BATCH_SIZE;
        if (endIndex > totalAffidavits) endIndex = totalAffidavits;

        for (uint i = state.cursor; i < endIndex; i++) {
            _finalizeAffidavit(marketId, i, state.correctJurors);
        }
        state.cursor = endIndex;
        if (state.cursor >= totalAffidavits) {
            state.complete = true;
        }
        emit FinalizationProgress(marketId,
            state.cursor, totalAffidavits);
    }

    /// @param marketId The market ID
    /// @param affidavitIndex The affidavit index
    /// @param correctJurors Array of jurors who voted correctly
    function _finalizeAffidavit(uint64 marketId,
        uint affidavitIndex, address[] memory correctJurors) internal {
        Affidavit storage affidavit = affidavits[marketId][affidavitIndex];
        if (affidavit.quality != AffidavitQuality.NOT_EVALUATED) return;
        uint relevantEvals = 0; uint dissents = 0; bool isBad = false;
        for (uint j = 0; j < correctJurors.length; j++) {
            if (hasEvaluated[marketId][affidavitIndex][correctJurors[j]]) { relevantEvals++;
                EvalType et = evalTypes[marketId][affidavitIndex][correctJurors[j]];
                if (et == EvalType.DISSENTING_ACCURACY || et == EvalType.DISSENTING_RELEVANCY) {
                    dissents++;
                }
            }
        } FinalizationState storage state = finalizationState[marketId];
        if (relevantEvals == 0) {
            isBad = true;
        } else {
            uint pct = (dissents * 10000) / relevantEvals;
            if (pct >= 5000) {
                isBad = true;
            }
        } if (isBad) {
            affidavit.quality = AffidavitQuality.BAD;
            if (state.badAddresses.length < 100) {
                state.badAddresses.push(affidavit.solanaKey);
                state.badSides.push(affidavit.supportedSide);
            }
        } else {
            affidavit.quality = AffidavitQuality.GOOD;
        }
        emit AffidavitQualitySet(marketId,
        affidavitIndex, affidavit.quality);
    }

    /// @notice Check if finalization is complete
    /// @param marketId The market ID
    /// @return complete Whether finalization is done
    /// @return cursor Current processing position
    /// @return total Total affidavits to process
    function getFinalizationStatus(uint64 marketId) external view
        returns (bool complete, uint cursor, uint total) {
        FinalizationState storage state = finalizationState[marketId];
        return (state.complete, state.cursor, affidavits[marketId].length);
    }

    /// @notice Reset finalization state (for new rounds)
    /// @param marketId The market ID
    function resetFinalization(uint64 marketId) external {
        require(msg.sender == court, "Only court");
        delete finalizationState[marketId];
    }

    /// @notice Reset submission state for re-resolution (called when new resolution starts)
    /// @dev Clears finalization state and tracks starting index for new affidavits
    /// @param marketId The market ID
    function resetForNewResolution(uint64 marketId) external {
        require(msg.sender == court, "Only court");
        delete finalizationState[marketId];
        // Track where new affidavits start - old ones already have quality set
        // This allows efficient iteration in finalizeEvaluations
        resolutionStartIndex[marketId] = affidavits[marketId].length;

        // Note: submissionCount per address is NOT reset - this is intentional
        // Users who submitted bad affidavits in previous resolution shouldn't
        // get unlimited new attempts. The merkle tree also changed, so their
        // Solana positions may no longer be valid anyway.
    }

    function getBadAffidavitAddresses(uint64 marketId) external view
        returns (bytes32[] memory, uint8[] memory) {
        FinalizationState storage state = finalizationState[marketId];
        require(state.complete, "Finalization not complete");
        return (state.badAddresses, state.badSides);
    }

    function _requiresAppSignature(uint64 marketId)
        internal view returns (bool) {
        return ICourt(court).getRequiresAppSignature(marketId);
    }

    function getAffidavitCount(uint64 marketId)
        external view returns (uint) {
        return affidavits[marketId].length;
    }

    function getEvaluations(uint64 marketId, uint affidavitId)
        external view returns (Evaluation[] memory) {
        return evaluations[marketId][affidavitId];
    }

    function getAffidavitStats(uint64 marketId, uint affidavitId)
        external view returns (AffidavitStats memory) {
        return stats[marketId][affidavitId];
    }

    function getResolutionStartIndex(uint64 marketId)
        external view returns (uint) {
        return resolutionStartIndex[marketId];
    }

    function getCurrentResolutionEvalCount(uint64 marketId, address juror)
        external view returns (uint) {
        return currentResolutionEvalCount[marketId][juror];
    }
}
