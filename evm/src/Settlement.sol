// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/RandaoLib.sol";
import "./imports/IArbitrator.sol";
import "./imports/IArbitrable.sol";
import "./imports/IEvidence.sol";
import "./Auction.sol";
import "./Basket.sol";
import "./AuctionFactory.sol";
import "./SettlementLib.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Settlement is ReentrancyGuard, IArbitrator, IEvidence {
    using RandaoLib for bytes;
    
    enum VoteChoice { None, No, Yes, ForceMajeur }
    enum ProposalStatus { None, Active, Executed, Disputed, Expired }
    
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
        uint[3] voteCounts;
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
    
    // Constants (shortened names)
    uint private constant MIN_STAKE = 100e18;
    uint private constant VOTE_PERIOD = 3 days;
    uint private constant EXEC_DELAY = 1 days;
    uint private constant SUPPORT_RATIO = 2;
    uint private constant JURY_SIZE = 7;
    uint private constant MIN_JUROR_BAL = 100e18;
    uint private constant EVIDENCE_PER = 2 days;
    uint private constant VOTING_PER = 3 days;
    uint private constant APPEAL_PER = 1 days;
    uint private constant APPEAL_MULT = 3;
    uint private constant MAX_ROUNDS = 3;
    uint private constant SLASH_PCT = 10;
    uint private constant TIMEOUT = 7 days;
    uint private constant ABS_TIMEOUT = 30 days;
    uint private constant MIN_POOL = 20;
    
    // State
    address public basketContract;
    address public auctionFactory;
    
    mapping(address => mapping(uint => Proposal)) public proposals;
    mapping(address => uint) public proposalCount;
    mapping(address => uint) public activeProposalId;
    mapping(address => uint) public lastActivity;
    
    mapping(uint => Dispute) public disputes;
    mapping(uint => mapping(uint => DisputeRound)) public rounds;
    mapping(address => uint) public marketDispute;
    uint public disputeCount;
    
    mapping(address => uint) public activeDisputes;
    mapping(address => uint) public totalVotes;
    mapping(address => uint) public wrongVotes;
    
    mapping(uint => uint[3]) public disputeRandomBlocks;
    mapping(uint => bool) public randomnessRequested;
    
    mapping(uint => string) public metaEvidenceURIs;
    uint public metaEvidenceCount;
    
    // Events
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
    
    constructor() {}
    
    function initialize(address _basket, address _factory) external {
        require(basketContract == address(0), "Already initialized");
        basketContract = _basket;
        auctionFactory = _factory;
    }
    
    // Proposal System
    function proposeSettlement(address market, bool outcome, uint stakeAmount) 
        external nonReentrant returns (uint proposalId) {
        SettlementLib.validateProposal(market, stakeAmount, MIN_STAKE);
        
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

    function getRoundVerdict(uint disputeId, uint round) external view returns (VoteChoice) {
        return rounds[disputeId][round].verdict;
    }
    
    function supportProposal(address market, uint proposalId, uint amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp <= proposal.createdAt + VOTE_PERIOD, "Voting ended");
        require(amount > 0, "No stake");
        
        Basket(basketContract).transferFrom(msg.sender, address(this), amount);
        
        proposal.supportStake += amount;
        proposal.supporters[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalSupported(market, proposalId, msg.sender, amount);
    }
    
    function opposeProposal(address market, uint proposalId, uint amount) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp <= proposal.createdAt + VOTE_PERIOD, "Voting ended");
        require(amount > 0, "No stake");
        
        Basket(basketContract).transferFrom(msg.sender, address(this), amount);
        
        proposal.opposeStake += amount;
        proposal.opposers[msg.sender] += amount;
        lastActivity[market] = block.timestamp;
        
        emit ProposalOpposed(market, proposalId, msg.sender, amount);
    }
    
    function executeProposal(address market, uint proposalId) external nonReentrant {
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
        
        uint ruling = proposal.outcome ? 1 : 0;
        IArbitrable(market).rule(0, ruling);
        
        emit ProposalExecuted(market, proposalId);
    }
    
    function disputeProposal(
        address market,
        uint proposalId,
        string calldata evidence,
        string calldata,
        uint disputeStake
    ) external nonReentrant returns (uint disputeId) {
        require(disputeStake >= MIN_STAKE, "Insufficient stake");
        
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > proposal.createdAt + VOTE_PERIOD, "Still voting");
        
        Basket(basketContract).transferFrom(msg.sender, address(this), disputeStake);
        
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
    
    // Jury System
    function isEligibleJuror(address juror) public view returns (bool) {
        uint balance = Basket(basketContract).totalBalances(juror);
        return balance >= MIN_JUROR_BAL && activeDisputes[juror] == 0;
    }
    
    function getPotentialJurors() public view returns (address[] memory, uint) {
        Basket basket = Basket(basketContract);
        uint latestHolder = basket.latest_holder();
        
        uint eligibleCount = 0;
        for (uint i = 1; i <= latestHolder; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligibleCount++;
            }
        }
        
        require(eligibleCount >= MIN_POOL, "Not enough eligible jurors");
        
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
        require(block.timestamp > dispute.createdAt + EVIDENCE_PER, "Evidence period active");
        
        uint round = dispute.currentRound;
        require(!randomnessRequested[disputeId], "Already requested");
        
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
        
        bytes32 randao1 = RandaoLib.getHistoricalRandaoValue(blocks[0], headers[0]);
        bytes32 randao2 = RandaoLib.getHistoricalRandaoValue(blocks[1], headers[1]);
        bytes32 randao3 = RandaoLib.getHistoricalRandaoValue(blocks[2], headers[2]);
        
        bytes32 combinedRandom = keccak256(abi.encodePacked(randao1, randao2, randao3));
        
        address[] memory selected = SettlementLib.selectJurorsFromHolders(
            basketContract,
            uint(combinedRandom),
            JURY_SIZE,
            MIN_JUROR_BAL,
            activeDisputes
        );
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        disputeRound.selectedJurors = selected;
        disputeRound.votingDeadline = block.timestamp + VOTING_PER;
        
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
        
        uint totalVoted = disputeRound.voteCounts[0] + disputeRound.voteCounts[1] + disputeRound.voteCounts[2];
        if (totalVoted >= (JURY_SIZE / 2) + 1) {
            _finalizeRound(disputeId, round);
        }
    }
    
    function _finalizeRound(uint disputeId, uint round) internal {
        DisputeRound storage disputeRound = rounds[disputeId][round];
        
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
        
        for (uint i = 0; i < disputeRound.selectedJurors.length; i++) {
            activeDisputes[disputeRound.selectedJurors[i]]--;
        }
        
        emit VerdictReached(disputeId, round, verdict);
    }
    
    function appeal(uint _disputeID, bytes calldata) external payable override {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.currentRound < MAX_ROUNDS - 1, "Max rounds");
        
        DisputeRound storage lastRound = rounds[_disputeID][dispute.currentRound];
        require(lastRound.finalized, "Not finalized");
        require(!lastRound.appealed, "Already appealed");
        
        uint requiredStake = MIN_STAKE * (APPEAL_MULT ** dispute.currentRound);
        
        Basket(basketContract).transferFrom(msg.sender, address(this), requiredStake);
        
        lastRound.appealed = true;
        dispute.currentRound++;
        dispute.status = DisputeStatus.Waiting;
        
        randomnessRequested[_disputeID] = false;
        
        emit DisputeAppealed(_disputeID, dispute.currentRound - 1);
    }
    
    function finalizeDispute(uint disputeId) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.isFinalized, "Already finalized");
        
        uint finalRound = dispute.currentRound;
        DisputeRound storage round = rounds[disputeId][finalRound];
        require(round.finalized, "Round not finalized");
        
        bool canFinalize = dispute.currentRound >= MAX_ROUNDS - 1 ||
                          block.timestamp > round.votingDeadline + APPEAL_PER;
        require(canFinalize, "Still appealable");
        
        if (finalRound > 0) {
            for (uint i = 0; i < finalRound; i++) {
                _slashRound(disputeId, i, round.verdict);
            }
        }
        
        dispute.isFinalized = true;
        dispute.status = DisputeStatus.Solved;
        
        uint ruling = uint(round.verdict) - 1;
        IArbitrable(dispute.market).rule(disputeId, ruling);
    }
    
    function _slashRound(uint disputeId, uint round, VoteChoice finalVerdict) internal {
        DisputeRound storage slashRound = rounds[disputeId][round];
        
        for (uint i = 0; i < slashRound.selectedJurors.length; i++) {
            address jurorAddr = slashRound.selectedJurors[i];
            
            if (slashRound.votes[jurorAddr] != finalVerdict && 
                slashRound.votes[jurorAddr] != VoteChoice.None) {
                
                uint slashAmount = SettlementLib.calculateSlashAmount(
                    basketContract,
                    jurorAddr,
                    SLASH_PCT
                );
                
                if (slashAmount > 0) {
                    Basket(basketContract).turn(jurorAddr, slashAmount);
                    wrongVotes[jurorAddr]++;
                    
                    emit JurorSlashed(jurorAddr, slashAmount);
                }
            }
        }
    }
    
    function claimStakes(address market, uint proposalId) external nonReentrant {
        Proposal storage proposal = proposals[market][proposalId];
        require(proposal.status == ProposalStatus.Executed, "Not executed");
        
        uint amount = 0;
        
        if (msg.sender == proposal.proposer) {
            amount = proposal.stake + proposal.supportStake + proposal.opposeStake;
            proposal.stake = 0;
            proposal.supportStake = 0;
            proposal.opposeStake = 0;
        }
        else if (proposal.supporters[msg.sender] > 0) {
            uint supporterStake = proposal.supporters[msg.sender];
            uint totalSupport = proposal.supportStake;
            uint winnings = proposal.opposeStake;
            
            amount = supporterStake + (winnings * supporterStake / totalSupport);
            proposal.supporters[msg.sender] = 0;
        }
        
        require(amount > 0, "Nothing to claim");
        
        Basket(basketContract).transfer(msg.sender, amount);
    }
    
    function _isSelectedJuror(address[] memory jurors, address juror) internal pure returns (bool) {
        for (uint i = 0; i < jurors.length; i++) {
            if (jurors[i] == juror) return true;
        }
        return false;
    }
    
    function forceTimeoutResolution(uint disputeId) external {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.isFinalized, "Already finalized");
        
        address market = dispute.market;
        Auction auction = Auction(payable(market));
        uint resolutionTime = auction.resolutionTime();
        
        bool timeout = block.timestamp > resolutionTime + ABS_TIMEOUT ||
                      block.timestamp > dispute.createdAt + TIMEOUT;
        require(timeout, "No timeout");
        
        dispute.isFinalized = true;
        dispute.status = DisputeStatus.Solved;
        
        IArbitrable(market).rule(disputeId, 2);
    }
    
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
        uint,
        string calldata evidence,
        string calldata evidenceHash,
        uint stakeAmount
    ) external returns (uint disputeId) {
        uint proposalId = this.proposeSettlement(market, false, stakeAmount / 2);
        return this.disputeProposal(market, proposalId, evidence, evidenceHash, stakeAmount / 2);
    }
    
    function createDispute(uint _choices, bytes calldata) external payable override returns (uint disputeID) {
        require(_choices >= 2, "Need choices");
        
        uint requiredStake = MIN_STAKE;
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
    
    function arbitrationCost(bytes calldata) external pure override returns (uint) {
        return MIN_STAKE;
    }
    
    function appealCost(uint _disputeID, bytes calldata) external view override returns (uint) {
        return MIN_STAKE * (APPEAL_MULT ** disputes[_disputeID].currentRound);
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
            end = start + APPEAL_PER;
        }
    }
    
    function submitEvidence(uint _disputeID, string calldata _evidence) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.createdAt > 0, "Invalid dispute");
        require(block.timestamp <= dispute.createdAt + EVIDENCE_PER, "Evidence period ended");
        
        emit Evidence(IArbitrator(address(this)), _disputeID, msg.sender, _evidence);
    }
    
    function canSettle(address market) external view returns (bool canSettleResult, string memory reason) {
        // Check if valid market by trying to call a function
        try Auction(payable(market)).bettingWindowClosed() returns (bool) {
            // Valid market
        } catch {
            return (false, "Invalid market");
        }
        
        Auction auction = Auction(payable(market));
        (, , , , , bool resolved, ) = auction.getPredictionSummary();
        uint resolutionTime = auction.resolutionTime();
        
        if (resolved) {
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
    
    function getEligibleJurorCount() external view returns (uint) {
        (, uint count) = getPotentialJurors();
        return count;
    }
}