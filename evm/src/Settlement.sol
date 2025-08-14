
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/RandaoLib.sol";
import "./imports/IArbitrator.sol";
import "./imports/IArbitrable.sol";
import "./imports/IEvidence.sol";
import "./Auction.sol";
import "./Basket.sol";
import "./AuctionFactory.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Settlement - Simplified Resolution System
/// @notice Two-phase resolution: proposals with 2:1 threshold, then jury if disputed
/// @dev Jurors are selected from 6909 token holders, no separate staking required
contract Settlement is ReentrancyGuard, IArbitrator, IEvidence {
    using RandaoLib for bytes;
    using Math for uint;
    
    // ============ Enums ============
    
    enum VoteChoice { None, No, Yes, ForceMajeur }
    enum ProposalStatus { None, Active, Executed, Disputed, Expired }
    
    // ============ Structs ============
    
    struct Proposal {
        address proposer;
        bool outcome;
        uint stake;
        uint supportStake;
        uint opposeStake;
        uint createdAt;
        ProposalStatus status;
        mapping(address => uint) supporters;
        mapping(address => uint) opposers;
    }
    
    struct DisputeRound {
        address[] selectedJurors;
        mapping(address => VoteChoice) votes;
        mapping(address => bool) hasVoted;
        uint[3] voteCounts; // [No, Yes, ForceMajeur]
        uint votingDeadline;
        VoteChoice verdict;
        bool finalized;
        bool appealed;
    }
    
    struct Dispute {
        address market;
        uint proposalId;
        uint currentRound;
        uint createdAt;
        DisputeStatus status;
        bool isFinalized;
    }
    
    // ============ Constants ============
    
    // Proposal settings
    uint private constant MIN_PROPOSAL_STAKE = 0.1 ether;
    uint private constant PROPOSAL_VOTING_PERIOD = 3 days;
    uint private constant PROPOSAL_EXECUTION_DELAY = 1 days;
    uint private constant SUPPORT_THRESHOLD = 2; // 2:1 ratio
    
    // Jury settings
    uint private constant JURY_SIZE = 7;
    uint private constant MIN_JUROR_BALANCE = 100e18;  // 100 6909 tokens to be eligible
    uint private constant EVIDENCE_PERIOD = 2 days;
    uint private constant VOTING_PERIOD = 3 days;
    uint private constant APPEAL_PERIOD = 1 days;
    uint private constant APPEAL_MULTIPLIER = 3;
    uint private constant MAX_ROUNDS = 3;
    uint private constant SLASH_PERCENT = 10;      // 10% of juror's 6909 balance
    
    // Timeouts
    uint private constant ACTIVITY_TIMEOUT = 7 days;
    uint private constant ABSOLUTE_TIMEOUT = 30 days;
    
    // ============ State Variables ============
    
    // Core addresses
    address public basketContract;
    address public auctionFactory;
    
    // Proposals
    mapping(address => mapping(uint => Proposal)) public proposals;
    mapping(address => uint) public proposalCount;
    mapping(address => uint) public activeProposalId;
    mapping(address => uint) public lastActivity;
    
    // Disputes
    mapping(uint => Dispute) public disputes;
    mapping(uint => mapping(uint => DisputeRound)) public rounds;
    mapping(address => uint) public marketDispute;
    uint public disputeCount;
    
    // Juror tracking (no staking, just activity)
    mapping(address => uint) public activeDisputes;  // How many disputes they're in
    mapping(address => uint) public totalVotes;      // Total votes cast
    mapping(address => uint) public wrongVotes;      // Times voted against final verdict
    
    // RANDAO for jury selection
    mapping(uint => uint[3]) public disputeRandomBlocks;
    mapping(uint => bool) public randomnessRequested;
    
    // Meta evidence
    mapping(uint => string) public metaEvidenceURIs;
    uint public metaEvidenceCount;
    
    // ============ Events ============
    
    event ProposalCreated(address indexed market, uint proposalId, address proposer, bool outcome);
    event ProposalSupported(address indexed market, uint proposalId, address supporter, uint amount);
    event ProposalOpposed(address indexed market, uint proposalId, address opposer, uint amount);
    event ProposalExecuted(address indexed market, uint proposalId);
    event ProposalDisputed(address indexed market, uint proposalId, uint disputeId);
    
    event JurorSelected(address indexed juror, uint disputeId, uint round);
    event JurorSlashed(address indexed juror, uint amount);
    event JuryRequested(uint indexed disputeId, uint round);
    event JurySelected(uint indexed disputeId, uint round, address[] jurors);
    event VoteSubmitted(uint indexed disputeId, uint round, address juror);
    event VerdictReached(uint indexed disputeId, uint round, VoteChoice verdict);
    event DisputeAppealed(uint indexed disputeId, uint round);
    event DisputeCreated(uint indexed disputeId, IArbitrable market, uint choices);
    
    // ============ Constructor ============
    
    constructor() {}
    
    function initialize(address _basket, address _factory) external {
        require(basketContract == address(0), "Already initialized");
        basketContract = _basket;
        auctionFactory = _factory;
    }
    
    // ============ Proposal System ============
    
    function proposeSettlement(address market, bool outcome) 
        external payable nonReentrant returns (uint proposalId) {
        require(msg.value >= MIN_PROPOSAL_STAKE, "Insufficient stake");
        require(_isValidMarket(market), "Invalid market");
        require(_canPropose(market), "Cannot propose");
        
        proposalId = ++proposalCount[market];
        Proposal storage proposal = proposals[market][proposalId];
        
        proposal.proposer = msg.sender;
        proposal.outcome = outcome;
        proposal.stake = msg.value;
        proposal.createdAt = block.timestamp;
        proposal.status = ProposalStatus.Active;
        
        activeProposalId[market] = proposalId;
        lastActivity[market] = block.timestamp;
        
        emit ProposalCreated(market, proposalId, msg.sender, outcome);
    }
    
    function supportProposal(address market, uint proposalId) external payable nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(_inVotingPeriod(proposal), "Voting ended");
        require(msg.value > 0, "No stake");
        
        proposal.supportStake += msg.value;
        proposal.supporters[msg.sender] += msg.value;
        lastActivity[market] = block.timestamp;
        
        emit ProposalSupported(market, proposalId, msg.sender, msg.value);
    }
    
    function opposeProposal(address market, uint proposalId) external payable nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(_inVotingPeriod(proposal), "Voting ended");
        require(msg.value > 0, "No stake");
        
        proposal.opposeStake += msg.value;
        proposal.opposers[msg.sender] += msg.value;
        lastActivity[market] = block.timestamp;
        
        emit ProposalOpposed(market, proposalId, msg.sender, msg.value);
    }
    
    function executeProposal(address market, uint proposalId) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(!_inVotingPeriod(proposal), "Still voting");
        require(_canExecute(proposal), "Cannot execute");
        
        proposal.status = ProposalStatus.Executed;
        activeProposalId[market] = 0;
        
        // Execute on market
        uint ruling = proposal.outcome ? 1 : 0;
        IArbitrable(market).rule(0, ruling);
        
        emit ProposalExecuted(market, proposalId);
    }
    
    function disputeProposal(address market, uint proposalId, string calldata evidence, string calldata evidenceHash) 
        external payable nonReentrant returns (uint disputeId) {
        require(msg.value >= MIN_PROPOSAL_STAKE, "Insufficient stake");
        
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(!_inVotingPeriod(proposal), "Still voting");
        
        proposal.status = ProposalStatus.Disputed;
        activeProposalId[market] = 0;
        
        // Create dispute
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
    
    // ============ Jury System (6909 Balance Based) ============
    
    /// @notice Check if address is eligible to be a juror based on 6909 balance
    function isEligibleJuror(address juror) public view returns (bool) {
        uint balance = Basket(basketContract).totalBalances(juror);
        return balance >= MIN_JUROR_BALANCE && activeDisputes[juror] == 0;
    }
    
    /// @notice Get all potential jurors from 6909 holders
    function getPotentialJurors() public view returns (address[] memory, uint) {
        Basket basket = Basket(basketContract);
        uint latestHolder = basket.latest_holder();
        
        // First pass: count eligible jurors
        uint eligibleCount = 0;
        for (uint i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligibleCount++;
            }
        }
        
        // Second pass: collect eligible jurors
        address[] memory eligibleJurors = new address[](eligibleCount);
        uint index = 0;
        for (uint i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligibleJurors[index++] = holder;
            }
        }
        
        return (eligibleJurors, eligibleCount);
    }
    
    function requestJurySelection(uint disputeId) external {
        Dispute storage dispute = disputes[disputeId];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp > dispute.createdAt + EVIDENCE_PERIOD, "Evidence period active");
        
        uint round = dispute.currentRound;
        require(!randomnessRequested[disputeId], "Already requested");
        
        // Store future block numbers for RANDAO
        disputeRandomBlocks[disputeId] = [
            block.number + 3,
            block.number + 4,
            block.number + 5
        ];
        
        randomnessRequested[disputeId] = true;
        emit JuryRequested(disputeId, round);
    }
    
    function fulfillJurySelection(uint disputeId, bytes[] calldata headers) external {
        Dispute storage dispute = disputes[disputeId];
        uint round = dispute.currentRound;
        
        require(randomnessRequested[disputeId], "Not requested");
        require(headers.length == 3, "Need 3 headers");
        
        uint[3] memory blocks = disputeRandomBlocks[disputeId];
        require(block.number > blocks[2], "Too early");
        
        // Extract RANDAO values from block headers
        bytes32 randao1 = RandaoLib.getHistoricalRandaoValue(blocks[0], headers[0]);
        bytes32 randao2 = RandaoLib.getHistoricalRandaoValue(blocks[1], headers[1]);
        bytes32 randao3 = RandaoLib.getHistoricalRandaoValue(blocks[2], headers[2]);
        
        // Combine for better randomness
        bytes32 combinedRandom = keccak256(abi.encodePacked(randao1, randao2, randao3));
        
        // Select jury from eligible 6909 holders
        address[] memory selected = _selectJurorsWithRandomness(uint(combinedRandom));
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        disputeRound.selectedJurors = selected;
        disputeRound.votingDeadline = block.timestamp + VOTING_PERIOD;
        
        // Mark jurors as active
        for (uint i = 0; i < selected.length; i++) {
            activeDisputes[selected[i]]++;
            emit JurorSelected(selected[i], disputeId, round);
        }
        
        disputes[disputeId].status = DisputeStatus.Appealable;
        emit JurySelected(disputeId, round, selected);
    }
    
    function submitVote(uint disputeId, uint round, VoteChoice vote) external {
        require(vote != VoteChoice.None, "Invalid vote");
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        require(_isSelectedJuror(disputeRound.selectedJurors, msg.sender), "Not juror");
        require(!disputeRound.hasVoted[msg.sender], "Already voted");
        require(block.timestamp <= disputeRound.votingDeadline, "Voting ended");
        
        disputeRound.hasVoted[msg.sender] = true;
        disputeRound.votes[msg.sender] = vote;
        disputeRound.voteCounts[uint(vote) - 1]++;
        
        totalVotes[msg.sender]++;
        
        emit VoteSubmitted(disputeId, round, msg.sender);
        
        // Check if verdict reached
        uint totalVoted = disputeRound.voteCounts[0] + disputeRound.voteCounts[1] + disputeRound.voteCounts[2];
        if (totalVoted >= (JURY_SIZE / 2) + 1) {
            _finalizeRound(disputeId, round);
        }
    }
    
    function _finalizeRound(uint disputeId, uint round) internal {
        DisputeRound storage disputeRound = rounds[disputeId][round];
        
        // Determine verdict
        uint maxVotes = 0;
        VoteChoice verdict = VoteChoice.None;
        for (uint i = 0; i < 3; i++) {
            if (disputeRound.voteCounts[i] > maxVotes) {
                maxVotes = disputeRound.voteCounts[i];
                verdict = VoteChoice(i + 1);
            }
        }
        
        disputeRound.verdict = verdict;
        disputeRound.finalized = true;
        
        // Free jurors
        for (uint i = 0; i < disputeRound.selectedJurors.length; i++) {
            activeDisputes[disputeRound.selectedJurors[i]]--;
        }
        
        emit VerdictReached(disputeId, round, verdict);
    }
    
    // ============ Appeals ============
    
    function appeal(uint _disputeID, bytes calldata) external payable override {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.currentRound < MAX_ROUNDS - 1, "Max rounds");
        
        DisputeRound storage lastRound = rounds[_disputeID][dispute.currentRound];
        require(lastRound.finalized, "Not finalized");
        require(!lastRound.appealed, "Already appealed");
        
        uint requiredStake = MIN_PROPOSAL_STAKE * (APPEAL_MULTIPLIER ** dispute.currentRound);
        require(msg.value >= requiredStake, "Insufficient stake");
        
        lastRound.appealed = true;
        dispute.currentRound++;
        dispute.status = DisputeStatus.Waiting;
        
        // Reset randomness for new round
        randomnessRequested[_disputeID] = false;
        
        emit DisputeAppealed(_disputeID, dispute.currentRound - 1);
    }
    
    // ============ Finalization ============
    
    function finalizeDispute(uint disputeId) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.isFinalized, "Already finalized");
        
        uint finalRound = dispute.currentRound;
        DisputeRound storage round = rounds[disputeId][finalRound];
        require(round.finalized, "Round not finalized");
        
        // Check if appealable
        bool canFinalize = dispute.currentRound >= MAX_ROUNDS - 1 ||
                          block.timestamp > round.votingDeadline + APPEAL_PERIOD;
        require(canFinalize, "Still appealable");
        
        // Slash overturned rounds (only those who voted wrong)
        if (finalRound > 0) {
            for (uint i = 0; i < finalRound; i++) {
                _slashRound(disputeId, i, round.verdict);
            }
        }
        
        dispute.isFinalized = true;
        dispute.status = DisputeStatus.Solved;
        
        // Execute ruling
        uint ruling = uint(round.verdict) - 1;
        IArbitrable(dispute.market).rule(disputeId, ruling);
    }
    
    function _slashRound(uint disputeId, uint round, VoteChoice finalVerdict) internal {
        DisputeRound storage slashRound = rounds[disputeId][round];
        
        for (uint i = 0; i < slashRound.selectedJurors.length; i++) {
            address jurorAddr = slashRound.selectedJurors[i];
            
            // Only slash jurors who voted against the final verdict
            if (slashRound.votes[jurorAddr] != finalVerdict && 
                slashRound.votes[jurorAddr] != VoteChoice.None) {
                
                // Calculate slash amount (10% of their 6909 balance)
                uint balance = Basket(basketContract).totalBalances(jurorAddr);
                uint slashAmount = (balance * SLASH_PERCENT) / 100;
                
                if (slashAmount > 0) {
                    // Burn the tokens
                    Basket(basketContract).turn(jurorAddr, slashAmount);
                    wrongVotes[jurorAddr]++;
                    
                    emit JurorSlashed(jurorAddr, slashAmount);
                }
            }
        }
    }
    
    // ============ Claim Proposal Stakes ============
    
    function claimStakes(address market, uint proposalId) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Executed, "Not executed");
        
        uint amount = 0;
        
        // Proposer gets all stakes if executed
        if (msg.sender == proposal.proposer) {
            amount = proposal.stake + proposal.supportStake + proposal.opposeStake;
            proposal.stake = 0;
            proposal.supportStake = 0;
            proposal.opposeStake = 0;
        }
        // Supporters get proportional share of opposition
        else if (proposal.supporters[msg.sender] > 0) {
            uint supporterStake = proposal.supporters[msg.sender];
            uint totalSupport = proposal.supportStake;
            uint winnings = proposal.opposeStake;
            
            amount = supporterStake + (winnings * supporterStake / totalSupport);
            proposal.supporters[msg.sender] = 0;
        }
        
        require(amount > 0, "Nothing to claim");
        
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }
    
    // ============ Internal Helpers ============
    
    function _selectJurorsWithRandomness(uint randomSeed) internal view returns (address[] memory) {
        // Get all eligible jurors
        (address[] memory eligibleJurors, uint eligibleCount) = getPotentialJurors();
        require(eligibleCount >= JURY_SIZE, "Not enough eligible jurors");
        
        address[] memory selected = new address[](JURY_SIZE);
        bool[] memory used = new bool[](eligibleCount);
        
        // Fisher-Yates shuffle variant for selection
        for (uint i = 0; i < JURY_SIZE; i++) {
            uint remaining = eligibleCount - i;
            // Use randomSeed to generate deterministic but unpredictable selection
            uint index = uint(keccak256(abi.encode(randomSeed, i))) % remaining;
            
            // Find the index-th unused juror
            uint currentIndex = 0;
            for (uint j = 0; j < eligibleCount; j++) {
                if (!used[j]) {
                    if (currentIndex == index) {
                        selected[i] = eligibleJurors[j];
                        used[j] = true;
                        break;
                    }
                    currentIndex++;
                }
            }
        }
        
        return selected;
    }
    
    function _isValidMarket(address market) internal view returns (bool) {
        AuctionFactory factory = AuctionFactory(auctionFactory);
        return factory.isValidAuction(market);
    }
    
    function _canPropose(address market) internal view returns (bool) {
        if (activeProposalId[market] > 0) return false;
        if (marketDispute[market] > 0) return false;
        
        Auction auction = Auction(payable(market));
        (
            string memory question,
            uint resolutionTime,
            bool resolved,
            bool outcome,
            bool requiresContent,
            uint contentDeadline,
            uint minParticipants,
            ,
            ,
            
        ) = auction.getPredictionConfig();
        
        if (resolved) return false;
        if (block.timestamp < resolutionTime) return false;
        
        return true;
    }
    
    function _inVotingPeriod(Proposal storage proposal) internal view returns (bool) {
        return block.timestamp <= proposal.createdAt + PROPOSAL_VOTING_PERIOD;
    }
    
    function _canExecute(Proposal storage proposal) internal view returns (bool) {
        if (block.timestamp < proposal.createdAt + PROPOSAL_VOTING_PERIOD + PROPOSAL_EXECUTION_DELAY) {
            return false;
        }
        
        uint totalSupport = proposal.stake + proposal.supportStake;
        uint totalOppose = proposal.opposeStake;
        
        return totalSupport >= totalOppose * SUPPORT_THRESHOLD;
    }
    
    function _isSelectedJuror(address[] memory jurors, address juror) internal pure returns (bool) {
        for (uint i = 0; i < jurors.length; i++) {
            if (jurors[i] == juror) return true;
        }
        return false;
    }
    
    // ============ Timeouts ============
    
    function forceTimeoutResolution(uint disputeId) external {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.isFinalized, "Already finalized");
        
        address market = dispute.market;
        require(_isValidMarket(market), "Invalid market");
        
        Auction auction = Auction(payable(market));
        (, uint resolutionTime, , , , , , , , ) = auction.getPredictionConfig();
        
        bool timeout = block.timestamp > resolutionTime + ABSOLUTE_TIMEOUT ||
                      block.timestamp > dispute.createdAt + ACTIVITY_TIMEOUT;
        require(timeout, "No timeout");
        
        dispute.isFinalized = true;
        dispute.status = DisputeStatus.Solved;
        
        // Force majeur on timeout
        IArbitrable(market).rule(disputeId, 2);
    }
    
    // ============ Meta Evidence ============
    
    function createPredictionMarketMetaEvidence() external returns (uint) {
        return createMetaEvidence(
            "Standard Prediction Market",
            "Resolution based on objective outcome",
            "",
            "[{\"title\":\"NO\",\"description\":\"Event did not occur\"},{\"title\":\"YES\",\"description\":\"Event occurred\"},{\"title\":\"Force Majeur\",\"description\":\"Cancel due to unforeseen circumstances\"}]",
            ""
        );
    }
    
    function createMetaEvidence(
        string memory _title,
        string memory _description,
        string memory _question,
        string memory _rulingOptions,
        string memory _fileURI
    ) public returns (uint) {
        uint id = metaEvidenceCount++;
        
        // Build JSON properly
        bytes memory json = abi.encodePacked(
            '{"title":"', _title,
            '","description":"', _description,
            '","question":"', _question,
            '","rulingOptions":', _rulingOptions,
            ',"fileURI":"', _fileURI, '"}'
        );
        
        metaEvidenceURIs[id] = string(json);
        emit MetaEvidence(id, metaEvidenceURIs[id]);
        return id;
    }
    
    function initiateDisputeWithMetaEvidence(
        address market,
        uint _metaEvidenceId,
        string calldata evidence,
        string calldata evidenceHash
    ) external payable returns (uint disputeId) {
        // First create a proposal to dispute
        uint proposalId = this.proposeSettlement{value: msg.value / 2}(market, false);
        
        // Then immediately dispute it
        return this.disputeProposal{value: msg.value / 2}(market, proposalId, evidence, evidenceHash);
    }
    
    // ============ IArbitrator Implementation ============
    
    function createDispute(uint _choices, bytes calldata _extraData) external payable override returns (uint disputeID) {
        require(msg.value >= MIN_PROPOSAL_STAKE, "Insufficient fee");
        require(_choices >= 2, "Need choices");
        
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
    
    function arbitrationCost(bytes calldata) external pure override returns (uint) {
        return MIN_PROPOSAL_STAKE;
    }
    
    function appealCost(uint _disputeID, bytes calldata) external view override returns (uint) {
        return MIN_PROPOSAL_STAKE * (APPEAL_MULTIPLIER ** disputes[_disputeID].currentRound);
    }
    
    function disputeStatus(uint _disputeID) external view override returns (DisputeStatus) {
        return disputes[_disputeID].status;
    }
    
    function currentRuling(uint _disputeID) external view override returns (uint) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized) {
            return uint(round.verdict) - 1;
        }
        return 0;
    }
    
    function appealPeriod(uint _disputeID) external view override returns (uint start, uint end) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized && dispute.currentRound < MAX_ROUNDS - 1) {
            start = block.timestamp;
            end = start + APPEAL_PERIOD;
        }
    }
    
    function submitEvidence(uint _disputeID, string calldata _evidence) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp <= dispute.createdAt + EVIDENCE_PERIOD, "Evidence period ended");
        
        emit Evidence(IArbitrator(address(this)), _disputeID, msg.sender, _evidence);
    }
    
    // ============ View Functions ============
    
    function canSettle(address market) external view returns (bool canSettleResult, string memory reason) {
        if (!_isValidMarket(market)) {
            return (false, "Invalid market");
        }
        
        Auction auction = Auction(payable(market));
        (, uint resolutionTime, bool resolved, , , , , , , ) = auction.getPredictionConfig();
        
        if (resolved) {
            return (false, "Already resolved");
        }
        
        if (block.timestamp < resolutionTime) {
            return (false, "Resolution time not reached");
        }
        
        if (activeProposalId[market] > 0) {
            Proposal storage proposal = proposals[market][activeProposalId[market]];
            if (_inVotingPeriod(proposal)) {
                return (false, "Active proposal in voting period");
            }
            if (block.timestamp < proposal.createdAt + PROPOSAL_VOTING_PERIOD + PROPOSAL_EXECUTION_DELAY) {
                return (false, "Proposal in execution delay period");
            }
            if (_canExecute(proposal)) {
                return (true, "Proposal ready for execution");
            }
            return (false, "Proposal lacks support");
        }
        
        if (marketDispute[market] > 0) {
            return (false, "Under dispute");
        }
        
        if (block.timestamp > resolutionTime + ABSOLUTE_TIMEOUT) {
            return (true, "Absolute timeout reached");
        }
        
        return (true, "Ready for new settlement proposal");
    }
    
    function getEligibleJurorCount() external view returns (uint) {
        (, uint count) = getPotentialJurors();
        return count;
    }
}
