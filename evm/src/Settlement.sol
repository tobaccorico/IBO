// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./imports/RandaoLib.sol";
import "./imports/IArbitrator.sol";
import "./imports/IArbitrable.sol";
import "./imports/IEvidence.sol";

import "./Safta.sol";
import "./Basket.sol";
import {SaftaFactory} from "./SF.sol";
import "./SettlementLib.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Settlement
 * @notice Dispute resolution system for Safta prediction markets
 * @dev Singleton contract managing all market settlements
 */
contract Settlement is ReentrancyGuard, IArbitrator, IEvidence {
    using RandaoLib for bytes;
    
    enum VoteChoice { None, No, Yes, ForceMajeur }
    enum ProposalStatus { None, Active, Executed, Disputed, Expired }
    
    struct Proposal {
        address proposer;
        bool outcome;
        uint256 stake;
        uint256 supportStake;
        uint256 opposeStake;
        uint256 createdAt;
        ProposalStatus status;
        mapping(address => uint256) supporters;
        mapping(address => uint256) opposers;
    }
    
    struct DisputeRound {
        address[] selectedJurors;
        mapping(address => VoteChoice) votes;
        mapping(address => bool) hasVoted;
        uint256[3] voteCounts;
        uint256 votingDeadline;
        VoteChoice verdict;
        bool finalized;
        bool appealed;
    }
    
    struct Dispute {
        address market;
        uint256 proposalId;
        uint256 currentRound;
        uint256 createdAt;
        DisputeStatus status;
        bool isFinalized;
    }
    
    // Constants
    uint256 private constant MIN_STAKE = 100e18;
    uint256 private constant VOTE_PERIOD = 3 days;
    uint256 private constant EXEC_DELAY = 1 days;
    uint256 private constant SUPPORT_RATIO = 2;
    uint256 private constant JURY_SIZE = 7;
    uint256 private constant MIN_JUROR_BAL = 100e18;
    uint256 private constant EVIDENCE_PER = 2 days;
    uint256 private constant VOTING_PER = 3 days;
    uint256 private constant APPEAL_PER = 1 days;
    uint256 private constant APPEAL_MULT = 3;
    uint256 private constant MAX_ROUNDS = 3;
    uint256 private constant SLASH_PCT = 10;
    uint256 private constant TIMEOUT = 7 days;
    uint256 private constant ABS_TIMEOUT = 30 days;
    uint256 private constant MIN_POOL = 20;
    
    // State
    address public basketContract;
    address public doppler404Factory;
    
    mapping(address => mapping(uint256 => Proposal)) public proposals;
    mapping(address => uint256) public proposalCount;
    mapping(address => uint256) public activeProposalId;
    mapping(address => uint256) public lastActivity;
    
    mapping(uint256 => Dispute) public disputes;
    mapping(uint256 => mapping(uint256 => DisputeRound)) public rounds;
    mapping(address => uint256) public marketDispute;
    uint256 public disputeCount;
    
    mapping(address => uint256) public activeDisputes;
    mapping(address => uint256) public totalVotes;
    mapping(address => uint256) public wrongVotes;
    
    mapping(uint256 => uint256[3]) public disputeRandomBlocks;
    mapping(uint256 => bool) public randomnessRequested;
    
    mapping(uint256 => string) public metaEvidenceURIs;
    uint256 public metaEvidenceCount;
    
    // Events
    event ProposalCreated(address indexed market, uint256 proposalId, address proposer, bool outcome, uint256 stake);
    event ProposalSupported(address indexed market, uint256 proposalId, address supporter, uint256 amount);
    event ProposalOpposed(address indexed market, uint256 proposalId, address opposer, uint256 amount);
    event ProposalExecuted(address indexed market, uint256 proposalId);
    event ProposalDisputed(address indexed market, uint256 proposalId, uint256 disputeId);
    event JurorSelected(address indexed juror, uint256 disputeId, uint256 round);
    event JurorSlashed(address indexed juror, uint256 amount);
    event JuryRequested(uint256 indexed disputeId, uint256 round);
    event JurySelected(uint256 indexed disputeId, uint256 round, address[] jurors);
    event VoteSubmitted(uint256 indexed disputeId, uint256 round, address juror);
    event VerdictReached(uint256 indexed disputeId, uint256 round, VoteChoice verdict);
    event DisputeAppealed(uint256 indexed disputeId, uint256 round);
    event DisputeCreated(uint256 indexed disputeId, IArbitrable market, uint256 choices);
    event SettlementRewardClaimed(address indexed user, uint256 amount);
    
    constructor() {}
    
    // Add admin function for emergency resolution
    function admin() external view returns (address) {
        return SaftaFactory(doppler404Factory).owner();
    }
    
    function initialize(address _basket, address _factory) external {
        require(basketContract == address(0), "Already initialized");
        basketContract = _basket;
        doppler404Factory = _factory;
    }
    
    // ============ Proposal System ============
    
    function proposeSettlement(
        address market,
        bool outcome,
        uint256 stakeAmount
    ) external nonReentrant returns (uint256 proposalId) {
        require(stakeAmount >= MIN_STAKE, "Insufficient stake");
        require(_isValidMarket(market), "Invalid market");
        require(_canPropose(market), "Cannot propose");
        
        // Transfer basket tokens as stake
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            stakeAmount
        );
        
        proposalId = ++proposalCount[market];
        Proposal storage proposal = proposals[market][proposalId];
        
        proposal.proposer = msg.sender;
        proposal.outcome = outcome;
        proposal.stake = stakeAmount;
        proposal.createdAt = block.timestamp;
        proposal.status = ProposalStatus.Active;
        
        activeProposalId[market] = proposalId;
        lastActivity[market] = block.timestamp;
        
        emit ProposalCreated(market, proposalId, msg.sender, outcome, stakeAmount);
    }
    
    function supportProposal(address market, uint256 proposalId, uint256 amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp <= proposal.createdAt + VOTE_PERIOD, "Voting ended");
        require(amount > 0, "No stake");
        
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        
        proposal.supportStake += amount;
        proposal.supporters[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalSupported(market, proposalId, msg.sender, amount);
    }
    
    function opposeProposal(address market, uint256 proposalId, uint256 amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp <= proposal.createdAt + VOTE_PERIOD, "Voting ended");
        require(amount > 0, "No stake");
        
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        
        proposal.opposeStake += amount;
        proposal.opposers[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalOpposed(market, proposalId, msg.sender, amount);
    }
    
    function executeProposal(address market, uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > proposal.createdAt + VOTE_PERIOD, "Still voting");
        
        bool canExecute = SettlementLib.canExecuteProposal(
            proposal.stake + proposal.supportStake,
            proposal.opposeStake,
            SUPPORT_RATIO,
            proposal.createdAt,
            VOTE_PERIOD,
            EXEC_DELAY
        );
        require(canExecute, "Cannot execute");
        
        proposal.status = ProposalStatus.Executed;
        activeProposalId[market] = 0;
        
        // Call resolve on Safta market (binary only)
        Safta(market).resolveMarket(proposal.outcome);
        
        emit ProposalExecuted(market, proposalId);
    }
    
    function disputeProposal(
        address market,
        uint256 proposalId,
        string calldata evidence,
        string calldata,
        uint256 disputeStake
    ) external nonReentrant returns (uint256 disputeId) {
        require(disputeStake >= MIN_STAKE, "Insufficient stake");
        
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > proposal.createdAt + VOTE_PERIOD, "Still voting");
        
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            disputeStake
        );
        
        proposal.status = ProposalStatus.Disputed;
        activeProposalId[market] = 0;
        
        disputeId = ++disputeCount;
        disputes[disputeId] = Dispute({
            market: market,
            proposalId: proposalId,
            currentRound: 0,
            createdAt: block.timestamp,
            status: DisputeStatus.Waiting,
            isFinalized: false
        });
        
        marketDispute[market] = disputeId;
        
        emit ProposalDisputed(market, proposalId, disputeId);
        emit Evidence(IArbitrator(address(this)), disputeId, msg.sender, evidence);
    }
    
    // ============ Jury System ============
    
    function isEligibleJuror(address juror) public view returns (bool) {
        uint256 balance = Basket(basketContract).totalBalances(juror);
        return balance >= MIN_JUROR_BAL && activeDisputes[juror] == 0;
    }
    
    function getPotentialJurors() public view returns (address[] memory, uint256) {
        Basket basket = Basket(basketContract);
        uint256 latestHolder = basket.latest_holder();
        
        uint256 eligibleCount = 0;
        for (uint256 i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligibleCount++;
            }
        }
        
        require(eligibleCount >= MIN_POOL, "Not enough eligible jurors");
        
        address[] memory eligibleJurors = new address[](eligibleCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligibleJurors[index++] = holder;
            }
        }
        
        return (eligibleJurors, eligibleCount);
    }
    
    function requestJurySelection(uint256 disputeId) external {
        Dispute storage dispute = disputes[disputeId];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp > dispute.createdAt + EVIDENCE_PER, "Evidence period active");
        
        uint256 round = dispute.currentRound;
        require(!randomnessRequested[disputeId], "Already requested");
        
        disputeRandomBlocks[disputeId] = [
            block.number + 3,
            block.number + 4,
            block.number + 5
        ];
        
        randomnessRequested[disputeId] = true;
        emit JuryRequested(disputeId, round);
    }
    
    function fulfillJurySelection(uint256 disputeId, bytes[] calldata headers) external {
        Dispute storage dispute = disputes[disputeId];
        uint256 round = dispute.currentRound;
        
        require(randomnessRequested[disputeId], "Not requested");
        require(headers.length == 3, "Need 3 headers");
        
        uint256[3] memory blocks = disputeRandomBlocks[disputeId];
        require(block.number > blocks[2], "Too early");
        
        bytes32 randao1 = RandaoLib.getHistoricalRandaoValue(blocks[0], headers[0]);
        bytes32 randao2 = RandaoLib.getHistoricalRandaoValue(blocks[1], headers[1]);
        bytes32 randao3 = RandaoLib.getHistoricalRandaoValue(blocks[2], headers[2]);
        
        bytes32 combinedRandom = keccak256(abi.encodePacked(randao1, randao2, randao3));
        
        address[] memory selected = SettlementLib.selectJurorsFromHolders(
            basketContract,
            uint256(combinedRandom),
            JURY_SIZE,
            MIN_JUROR_BAL,
            activeDisputes
        );
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        disputeRound.selectedJurors = selected;
        disputeRound.votingDeadline = block.timestamp + VOTING_PER;
        
        for (uint256 i = 0; i < selected.length; i++) {
            activeDisputes[selected[i]]++;
            emit JurorSelected(selected[i], disputeId, round);
        }
        
        disputes[disputeId].status = DisputeStatus.Appealable;
        emit JurySelected(disputeId, round, selected);
    }
    
    function submitVote(uint256 disputeId, uint256 round, VoteChoice vote) external {
        require(vote != VoteChoice.None, "Invalid vote");
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        require(_isSelectedJuror(disputeRound.selectedJurors, msg.sender), "Not juror");
        require(!disputeRound.hasVoted[msg.sender], "Already voted");
        require(block.timestamp <= disputeRound.votingDeadline, "Voting ended");
        
        disputeRound.hasVoted[msg.sender] = true;
        disputeRound.votes[msg.sender] = vote;
        disputeRound.voteCounts[uint256(vote) - 1]++;
        
        totalVotes[msg.sender]++;
        
        emit VoteSubmitted(disputeId, round, msg.sender);
        
        uint256 totalVoted = disputeRound.voteCounts[0] + disputeRound.voteCounts[1] + disputeRound.voteCounts[2];
        if (totalVoted >= (JURY_SIZE / 2) + 1) {
            _finalizeRound(disputeId, round);
        }
    }
    
    function _finalizeRound(uint256 disputeId, uint256 round) internal {
        DisputeRound storage disputeRound = rounds[disputeId][round];
        
        uint256 maxVotes = 0;
        VoteChoice verdict = VoteChoice.None;
        for (uint256 i = 0; i < 3; i++) {
            if (disputeRound.voteCounts[i] > maxVotes) {
                maxVotes = disputeRound.voteCounts[i];
                verdict = VoteChoice(i + 1);
            }
        }
        
        disputeRound.verdict = verdict;
        disputeRound.finalized = true;
        
        for (uint256 i = 0; i < disputeRound.selectedJurors.length; i++) {
            activeDisputes[disputeRound.selectedJurors[i]]--;
        }
        
        emit VerdictReached(disputeId, round, verdict);
    }
    
    function appeal(uint256 _disputeID, bytes calldata) external payable override {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.currentRound < MAX_ROUNDS - 1, "Max rounds");
        
        DisputeRound storage lastRound = rounds[_disputeID][dispute.currentRound];
        require(lastRound.finalized, "Not finalized");
        require(!lastRound.appealed, "Already appealed");
        
        uint256 requiredStake = MIN_STAKE * (APPEAL_MULT ** dispute.currentRound);
        
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            requiredStake
        );
        
        lastRound.appealed = true;
        dispute.currentRound++;
        dispute.status = DisputeStatus.Waiting;
        
        randomnessRequested[_disputeID] = false;
        
        emit DisputeAppealed(_disputeID, dispute.currentRound - 1);
    }
    
    function finalizeDispute(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.isFinalized, "Already finalized");
        
        uint256 finalRound = dispute.currentRound;
        DisputeRound storage round = rounds[disputeId][finalRound];
        require(round.finalized, "Round not finalized");
        
        bool canFinalize = dispute.currentRound >= MAX_ROUNDS - 1 ||
                          block.timestamp > round.votingDeadline + APPEAL_PER;
        require(canFinalize, "Still appealable");
        
        if (finalRound > 0) {
            for (uint256 i = 0; i < finalRound; i++) {
                _slashRound(disputeId, i, round.verdict);
            }
        }
        
        dispute.isFinalized = true;
        dispute.status = DisputeStatus.Solved;
        
        uint256 ruling = uint256(round.verdict) - 1;
        IArbitrable(dispute.market).rule(disputeId, ruling);
    }
    
    function _slashRound(uint256 disputeId, uint256 round, VoteChoice finalVerdict) internal {
        DisputeRound storage slashRound = rounds[disputeId][round];
        
        for (uint256 i = 0; i < slashRound.selectedJurors.length; i++) {
            address jurorAddr = slashRound.selectedJurors[i];
            
            if (slashRound.votes[jurorAddr] != finalVerdict && 
                slashRound.votes[jurorAddr] != VoteChoice.None) {
                
                uint256 balance = Basket(basketContract).totalBalances(jurorAddr);
                uint256 slashAmount = (balance * SLASH_PCT) / 100;
                
                if (slashAmount > 0) {
                    // Transfer slashed tokens to settlement pool
                    Basket(basketContract).transferFrom(
                        jurorAddr,
                        address(this),
                        slashAmount
                    );
                    wrongVotes[jurorAddr]++;
                    
                    emit JurorSlashed(jurorAddr, slashAmount);
                }
            }
        }
    }
    
    // ============ Helper Functions ============
    
    function forceTimeoutResolution(address market) external {
        Dispute storage dispute = disputes[marketDispute[market]];
        
        if (dispute.createdAt > 0 && !dispute.isFinalized) {
            // Check if dispute timeout reached
            bool timeout = block.timestamp > dispute.createdAt + TIMEOUT;
            require(timeout, "No timeout");
            
            dispute.isFinalized = true;
            dispute.status = DisputeStatus.Solved;
            
            // Default to NO outcome on timeout
            IArbitrable(market).rule(marketDispute[market], 0);
        } else {
            // No dispute - check absolute timeout
            Safta doppler = Safta(market);
            (,uint256 resolutionTime,,,,) = doppler.getMarketInfo();
            
            bool absTimeout = block.timestamp > resolutionTime + ABS_TIMEOUT;
            require(absTimeout, "No absolute timeout");
            
            // Force resolve as NO
            doppler.resolveMarket(false);
        }
    }
    
    function claimSettlementReward(address market) external nonReentrant {
        // Implementation for claiming rewards after successful settlement
        emit SettlementRewardClaimed(msg.sender, 0);
    }
    
    function claimStakes(address market, uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Executed, "Not executed");
        
        uint256 amount = 0;
        
        if (msg.sender == proposal.proposer) {
            amount = proposal.stake + proposal.supportStake + proposal.opposeStake;
            proposal.stake = 0;
            proposal.supportStake = 0;
            proposal.opposeStake = 0;
        }
        else if (proposal.supporters[msg.sender] > 0) {
            uint256 supporterStake = proposal.supporters[msg.sender];
            uint256 totalSupport = proposal.supportStake;
            uint256 winnings = proposal.opposeStake;
            
            amount = supporterStake + (winnings * supporterStake / totalSupport);
            proposal.supporters[msg.sender] = 0;
        }
        
        require(amount > 0, "Nothing to claim");
        
        Basket(basketContract).transfer(msg.sender, amount);
    }
    
    function canSettle(address market) external view returns (bool canSettleResult, string memory reason) {
        if (!_isValidMarket(market)) {
            return (false, "Invalid market");
        }
        
        Safta doppler = Safta(market);
        (,uint256 resolutionTime,,,,) = doppler.getMarketInfo();
        
        // Check if already resolved
        if (doppler.isResolved()) {
            return (false, "Already resolved");
        }
        
        if (block.timestamp < resolutionTime) {
            return (false, "Resolution time not reached");
        }
        
        if (activeProposalId[market] > 0) {
            Proposal storage proposal = proposals[market][activeProposalId[market]];
            if (block.timestamp <= proposal.createdAt + VOTE_PERIOD) {
                return (false, "Active proposal in voting period");
            }
            if (block.timestamp < proposal.createdAt + VOTE_PERIOD + EXEC_DELAY) {
                return (false, "Proposal in execution delay period");
            }
            
            bool canExec = SettlementLib.canExecuteProposal(
                proposal.stake + proposal.supportStake,
                proposal.opposeStake,
                SUPPORT_RATIO,
                proposal.createdAt,
                VOTE_PERIOD,
                EXEC_DELAY
            );
            
            if (canExec) {
                return (true, "Proposal ready for execution");
            }
            return (false, "Proposal lacks support");
        }
        
        if (marketDispute[market] > 0) {
            return (false, "Under dispute");
        }
        
        if (block.timestamp > resolutionTime + ABS_TIMEOUT) {
            return (true, "Absolute timeout reached");
        }
        
        return (true, "Ready for new settlement proposal");
    }
    
    function getProposalOutcome(address market, uint256 proposalId) external view returns (bool) {
        return proposals[market][proposalId].outcome;
    }
    
    function getProposalSupport(address market, uint256 proposalId) external view returns (uint256) {
        Proposal storage proposal = proposals[market][proposalId];
        return proposal.stake + proposal.supportStake;
    }
    
    function isRegisteredMarket(address market) external view returns (bool) {
        return _isValidMarket(market);
    }
    
    function getEligibleJurorCount() external view returns (uint256) {
        (, uint256 count) = getPotentialJurors();
        return count;
    }
    
    function submitEvidence(uint256 _disputeID, string calldata _evidence) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp <= dispute.createdAt + EVIDENCE_PER, "Evidence period ended");
        
        emit Evidence(IArbitrator(address(this)), _disputeID, msg.sender, _evidence);
    }
    
    function _isValidMarket(address market) internal view returns (bool) {
        return SaftaFactory(doppler404Factory).isValidMarket(market);
    }
    
    function _canPropose(address market) internal view returns (bool) {
        Safta doppler = Safta(market);
        (,uint256 resolutionTime,,,,) = doppler.getMarketInfo();
        
        // Check if already resolved
        if (doppler.isResolved()) return false;
        
        // Check resolution time
        if (block.timestamp < resolutionTime) return false;
        
        return true;
    }
    
    function _isSelectedJuror(address[] memory jurors, address juror) internal pure returns (bool) {
        for (uint256 i = 0; i < jurors.length; i++) {
            if (jurors[i] == juror) return true;
        }
        return false;
    }
    
    // ============ IArbitrator Implementation ============
    
    function createDispute(uint256 _choices, bytes calldata _extraData) external payable override returns (uint256 disputeID) {
        require(_choices >= 2, "Need choices");
        
        uint256 requiredStake = MIN_STAKE;
        Basket(basketContract).transferFrom(
            msg.sender,
            address(this),
            requiredStake
        );
        
        disputeID = ++disputeCount;
        disputes[disputeID] = Dispute({
            market: msg.sender,
            proposalId: 0,
            currentRound: 0,
            createdAt: block.timestamp,
            status: DisputeStatus.Waiting,
            isFinalized: false
        });
        
        marketDispute[msg.sender] = disputeID;
        emit DisputeCreated(disputeID, IArbitrable(msg.sender), _choices);
    }
    
    function arbitrationCost(bytes calldata) external pure override returns (uint256) {
        return MIN_STAKE;
    }
    
    function appealCost(uint256 _disputeID, bytes calldata) external view override returns (uint256) {
        return MIN_STAKE * (APPEAL_MULT ** disputes[_disputeID].currentRound);
    }
    
    function disputeStatus(uint256 _disputeID) external view override returns (DisputeStatus) {
        return disputes[_disputeID].status;
    }
    
    function currentRuling(uint256 _disputeID) external view override returns (uint256) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized) {
            return uint256(round.verdict) - 1;
        }
        return 0;
    }
    
    function appealPeriod(uint256 _disputeID) external view override returns (uint256 start, uint256 end) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized && dispute.currentRound < MAX_ROUNDS - 1) {
            start = block.timestamp;
            end = start + APPEAL_PER;
        }
    }
}