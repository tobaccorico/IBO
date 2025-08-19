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

/// @title Settlement - Simplified Resolution System with 6909 Token Staking
/// @notice Two-phase resolution: proposals with 2:1 threshold, then jury if disputed
/// @dev Jurors are selected from 6909 token holders, stakes are in 6909 tokens
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
        uint stake;              // 6909 tokens staked
        uint supportStake;       // 6909 tokens supporting
        uint opposeStake;        // 6909 tokens opposing
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
    
    // Proposal settings (in 6909 tokens)
    uint private constant MIN_PROPOSAL_STAKE = 100e18;     // 100 6909 tokens minimum
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
    
    // MEV Protection for jury selection
    uint private constant MIN_JUROR_POOL_SIZE = 20;  // Need at least 20 eligible jurors
    
    // ============ Events ============
    
    event ProposalCreated(address indexed market, uint proposalId, address proposer, bool outcome, uint stake);
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
    
    /// @notice Initialize the settlement system with basket and factory addresses
    /// @dev Can only be called once to set up the system
    /// @param _basket The Basket (6909) contract address for token operations
    /// @param _factory The AuctionFactory address for market validation
    function initialize(address _basket, address _factory) external {
        require(basketContract == address(0), "Already initialized");
        basketContract = _basket;
        auctionFactory = _factory;
    }
    
    // ============ Proposal System (6909 Token Stakes) ============
    
    /// @notice Propose a settlement outcome for a prediction market
    /// @dev First phase of resolution - requires staking 6909 tokens
    /// @param market The prediction market to settle
    /// @param outcome Proposed outcome (true for YES, false for NO)
    /// @param stakeAmount Amount of 6909 tokens to stake (min 100e18)
    /// @return proposalId The ID of the created proposal
    function proposeSettlement(address market, bool outcome, uint stakeAmount) 
        external nonReentrant returns (uint proposalId) {
        require(stakeAmount >= MIN_PROPOSAL_STAKE, "Insufficient stake");
        require(_isValidMarket(market), "Invalid market");
        require(_canPropose(market), "Cannot propose");
        
        // Transfer 6909 tokens from proposer
        Basket(basketContract).transferFrom(msg.sender, address(this), stakeAmount);
        
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
    
    /// @notice Support an active proposal by staking additional tokens
    /// @dev Supporters share in winnings if proposal executes successfully
    /// @param market The prediction market address
    /// @param proposalId The proposal to support
    /// @param amount Amount of 6909 tokens to stake in support
    function supportProposal(address market, uint proposalId, uint amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(_inVotingPeriod(proposal), "Voting ended");
        require(amount > 0, "No stake");
        
        // Transfer 6909 tokens from supporter
        Basket(basketContract).transferFrom(msg.sender, address(this), amount);
        
        proposal.supportStake += amount;
        proposal.supporters[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalSupported(market, proposalId, msg.sender, amount);
    }
    
    /// @notice Oppose an active proposal by staking tokens
    /// @dev Opposers prevent execution if total opposition >= support/2
    /// @param market The prediction market address
    /// @param proposalId The proposal to oppose
    /// @param amount Amount of 6909 tokens to stake in opposition
    function opposeProposal(address market, uint proposalId, uint amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(_inVotingPeriod(proposal), "Voting ended");
        require(amount > 0, "No stake");
        
        // Transfer 6909 tokens from opposer
        Basket(basketContract).transferFrom(msg.sender, address(this), amount);
        
        proposal.opposeStake += amount;
        proposal.opposers[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalOpposed(market, proposalId, msg.sender, amount);
    }
    
    /// @notice Execute a proposal that has met the support threshold
    /// @dev Requires 2:1 support ratio and execution delay passed
    /// @param market The prediction market address
    /// @param proposalId The proposal to execute
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
    
    /// @notice Dispute a proposal and trigger jury resolution
    /// @dev Transitions from proposal system to jury system
    /// @param market The prediction market address
    /// @param proposalId The proposal to dispute
    /// @param evidence IPFS URI or other evidence link
    /// @param evidenceHash Hash of evidence for verification
    /// @param disputeStake Amount to stake for dispute (returned if successful)
    /// @return disputeId The created dispute ID
    function disputeProposal(address market, uint proposalId, string calldata evidence, string calldata evidenceHash, uint disputeStake) 
        external nonReentrant returns (uint disputeId) {
        require(disputeStake >= MIN_PROPOSAL_STAKE, "Insufficient stake");
        
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(!_inVotingPeriod(proposal), "Still voting");
        
        // Transfer dispute stake
        Basket(basketContract).transferFrom(msg.sender, address(this), disputeStake);
        
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
    /// @dev Jurors must hold at least MIN_JUROR_BALANCE tokens and not be in active disputes
    /// @param juror Address to check eligibility
    /// @return Whether the address can serve as a juror
    function isEligibleJuror(address juror) public view returns (bool) {
        uint balance = Basket(basketContract).totalBalances(juror);
        return balance >= MIN_JUROR_BALANCE && activeDisputes[juror] == 0;
    }
    
    /// @notice Get all potential jurors from 6909 holders
    /// @dev Scans all holders and filters for eligibility, requires minimum pool size
    /// @return Array of eligible juror addresses and count
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
        
        // MEV Protection: Require minimum pool size
        require(eligibleCount >= MIN_JUROR_POOL_SIZE, "Not enough eligible jurors");
        
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
    
    /// @notice Request jury selection using future block randomness
    /// @dev Stores future block numbers for RANDAO-based selection
    /// @param disputeId The dispute requiring jury selection
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
    
    /// @notice Fulfill jury selection with block headers
    /// @dev Uses RANDAO values from multiple blocks for unpredictable selection
    /// @param disputeId The dispute to select jury for
    /// @param headers Array of 3 block headers for randomness extraction
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
    
    /// @notice Submit vote as a selected juror
    /// @dev Jurors vote on the dispute outcome: No, Yes, or Force Majeur
    /// @param disputeId The dispute being voted on
    /// @param round The round of voting (for appeals)
    /// @param vote The vote choice (No=0, Yes=1, ForceMajeur=2)
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
    
    /// @notice Finalize a voting round and determine verdict
    /// @dev Called automatically when majority is reached
    /// @param disputeId The dispute being finalized
    /// @param round The round to finalize
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
    
    /// @notice Appeal a jury decision to trigger another round
    /// @dev Each appeal round requires 3x more stake than previous
    /// @param _disputeID The dispute to appeal
    function appeal(uint _disputeID, bytes calldata) external payable override {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.currentRound < MAX_ROUNDS - 1, "Max rounds");
        
        DisputeRound storage lastRound = rounds[_disputeID][dispute.currentRound];
        require(lastRound.finalized, "Not finalized");
        require(!lastRound.appealed, "Already appealed");
        
        uint requiredStake = MIN_PROPOSAL_STAKE * (APPEAL_MULTIPLIER ** dispute.currentRound);
        
        // Transfer appeal stake in 6909 tokens
        Basket(basketContract).transferFrom(msg.sender, address(this), requiredStake);
        
        lastRound.appealed = true;
        dispute.currentRound++;
        dispute.status = DisputeStatus.Waiting;
        
        // Reset randomness for new round
        randomnessRequested[_disputeID] = false;
        
        emit DisputeAppealed(_disputeID, dispute.currentRound - 1);
    }
    
    // ============ Finalization ============
    
    /// @notice Finalize dispute and execute ruling
    /// @dev Slashes overturned jurors and executes final verdict
    /// @param disputeId The dispute to finalize
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
    
    /// @notice Slash jurors who voted against the final verdict
    /// @dev Burns 10% of their 6909 balance as penalty for wrong vote
    /// @param disputeId The dispute being finalized
    /// @param round The round to slash
    /// @param finalVerdict The final verdict to compare against
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
    
    /// @notice Claim stakes after proposal execution
    /// @dev Proposer gets all stakes, supporters get proportional share of opposition
    /// @param market The prediction market address
    /// @param proposalId The executed proposal
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
        
        // Transfer 6909 tokens back
        Basket(basketContract).transfer(msg.sender, amount);
    }
    
    // ============ Internal Helpers ============
    
    /// @notice Select jurors using provided randomness
    /// @dev Fisher-Yates shuffle variant for fair selection
    /// @param randomSeed Random value for selection
    /// @return Array of selected juror addresses
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
    
    /// @notice Check if market is valid (deployed by factory)
    /// @param market Address to validate
    /// @return Whether market is valid
    function _isValidMarket(address market) internal view returns (bool) {
        AuctionFactory factory = AuctionFactory(auctionFactory);
        return factory.isValidAuction(market);
    }
    
    /// @notice Check if market can receive proposals
    /// @dev Market must be past resolution time and not have active proposals/disputes
    /// @param market Market to check
    /// @return Whether proposals can be made
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
    
    /// @notice Check if proposal is in voting period
    /// @param proposal Proposal to check
    /// @return Whether voting is active
    function _inVotingPeriod(Proposal storage proposal) internal view returns (bool) {
        return block.timestamp <= proposal.createdAt + PROPOSAL_VOTING_PERIOD;
    }
    
    /// @notice Check if proposal can be executed
    /// @dev Requires 2:1 support ratio and execution delay
    /// @param proposal Proposal to check
    /// @return Whether execution is allowed
    function _canExecute(Proposal storage proposal) internal view returns (bool) {
        if (block.timestamp < proposal.createdAt + PROPOSAL_VOTING_PERIOD + PROPOSAL_EXECUTION_DELAY) {
            return false;
        }
        
        uint totalSupport = proposal.stake + proposal.supportStake;
        uint totalOppose = proposal.opposeStake;
        
        return totalSupport >= totalOppose * SUPPORT_THRESHOLD;
    }
    
    /// @notice Check if address is selected juror
    /// @param jurors Array of selected jurors
    /// @param juror Address to check
    /// @return Whether address is in array
    function _isSelectedJuror(address[] memory jurors, address juror) internal pure returns (bool) {
        for (uint i = 0; i < jurors.length; i++) {
            if (jurors[i] == juror) return true;
        }
        return false;
    }
    
    // ============ Timeouts ============
    
    /// @notice Force resolution for inactive disputes
    /// @dev Prevents markets from being stuck indefinitely
    /// @param disputeId Dispute to force resolve
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
    
    /// @notice Create standard meta evidence for prediction markets
    /// @dev Defines the resolution rules and options
    /// @return ID of created meta evidence
    function createPredictionMarketMetaEvidence() external returns (uint) {
        return createMetaEvidence(
            "Standard Prediction Market",
            "Resolution based on objective outcome",
            "",
            "[{\"title\":\"NO\",\"description\":\"Event did not occur\"},{\"title\":\"YES\",\"description\":\"Event occurred\"},{\"title\":\"Force Majeur\",\"description\":\"Cancel due to unforeseen circumstances\"}]",
            ""
        );
    }
    
    /// @notice Create custom meta evidence
    /// @dev Allows markets to define custom resolution rules
    /// @param _title Title of the resolution type
    /// @param _description Description of resolution process
    /// @param _question The question being resolved
    /// @param _rulingOptions JSON array of possible rulings
    /// @param _fileURI Additional documentation URI
    /// @return ID of created meta evidence
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
    
    /// @notice Create dispute with meta evidence
    /// @dev Shortcut to create proposal and immediately dispute it
    /// @param market Market to dispute
    /// @param _metaEvidenceId Meta evidence defining resolution rules
    /// @param evidence Evidence supporting dispute
    /// @param evidenceHash Hash of evidence
    /// @param stakeAmount Total stake amount (split between proposal and dispute)
    /// @return disputeId Created dispute ID
    function initiateDisputeWithMetaEvidence(
        address market,
        uint _metaEvidenceId,
        string calldata evidence,
        string calldata evidenceHash,
        uint stakeAmount
    ) external returns (uint disputeId) {
        // First create a proposal to dispute
        uint proposalId = this.proposeSettlement(market, false, stakeAmount / 2);
        
        // Then immediately dispute it
        return this.disputeProposal(market, proposalId, evidence, evidenceHash, stakeAmount / 2);
    }
    
    // ============ IArbitrator Implementation ============
    
    /// @notice Create a dispute (IArbitrator interface)
    /// @dev Direct dispute creation for IArbitrable contracts
    /// @param _choices Number of ruling options
    /// @param _extraData Additional data (unused)
    /// @return disputeID Created dispute ID
    function createDispute(uint _choices, bytes calldata _extraData) external payable override returns (uint disputeID) {
        require(_choices >= 2, "Need choices");
        
        // For direct dispute creation, require 6909 token transfer separately
        uint requiredStake = MIN_PROPOSAL_STAKE;
        Basket(basketContract).transferFrom(msg.sender, address(this), requiredStake);
        
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
    
    /// @notice Get arbitration cost
    /// @dev Returns minimum stake required in 6909 tokens
    /// @return Cost in 6909 tokens
    function arbitrationCost(bytes calldata) external pure override returns (uint) {
        return MIN_PROPOSAL_STAKE;
    }
    
    /// @notice Get appeal cost for a dispute
    /// @dev Cost increases exponentially with each round
    /// @param _disputeID Dispute to check
    /// @return Cost in 6909 tokens
    function appealCost(uint _disputeID, bytes calldata) external view override returns (uint) {
        return MIN_PROPOSAL_STAKE * (APPEAL_MULTIPLIER ** disputes[_disputeID].currentRound);
    }
    
    /// @notice Get dispute status
    /// @param _disputeID Dispute to check
    /// @return Current status
    function disputeStatus(uint _disputeID) external view override returns (DisputeStatus) {
        return disputes[_disputeID].status;
    }
    
    /// @notice Get current ruling for a dispute
    /// @dev Returns the verdict of the current round if finalized
    /// @param _disputeID Dispute to check
    /// @return Ruling (0=NO, 1=YES, 2=Force Majeur)
    function currentRuling(uint _disputeID) external view override returns (uint) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized) {
            return uint(round.verdict) - 1;
        }
        return 0;
    }
    
    /// @notice Get appeal period for a dispute
    /// @dev Returns time window for appeals if applicable
    /// @param _disputeID Dispute to check
    /// @return start Start of appeal period
    /// @return end End of appeal period
    function appealPeriod(uint _disputeID) external view override returns (uint start, uint end) {
        Dispute storage dispute = disputes[_disputeID];
        DisputeRound storage round = rounds[_disputeID][dispute.currentRound];
        
        if (round.finalized && dispute.currentRound < MAX_ROUNDS - 1) {
            start = block.timestamp;
            end = start + APPEAL_PERIOD;
        }
    }
    
    /// @notice Submit evidence for a dispute
    /// @dev Can be called during evidence period
    /// @param _disputeID Dispute to submit evidence for
    /// @param _evidence Evidence URI or data
    function submitEvidence(uint _disputeID, string calldata _evidence) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp <= dispute.createdAt + EVIDENCE_PERIOD, "Evidence period ended");
        
        emit Evidence(IArbitrator(address(this)), _disputeID, msg.sender, _evidence);
    }
    
    // ============ View Functions ============
    
    /// @notice Check if market can be settled
    /// @dev Comprehensive check of market settlement state
    /// @param market Market to check
    /// @return canSettleResult Whether settlement is possible
    /// @return reason Human-readable reason
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
    
    /// @notice Get count of eligible jurors
    /// @dev Useful for checking if jury selection is possible
    /// @return Number of eligible jurors
    function getEligibleJurorCount() external view returns (uint) {
        (, uint count) = getPotentialJurors();
        return count;
    }
}