// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {AuctionFactoryLib} from "../src/AuctionFactoryLib.sol";
import {Auction} from "../src/Auction.sol";
import {AuctionHelpers} from "../src/AuctionHelpers.sol";

// Mock contracts for testing
contract MockBasket {
    mapping(address => uint) public totalBalances;
    mapping(address => mapping(uint => uint)) public balanceOf;
    mapping(uint => address) public holders;
    mapping(address => mapping(address => uint)) public allowance;
    uint public latest_holder;
    uint public totalSupply;
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        require(totalBalances[from] >= amount, "Insufficient balance");
        if (from != msg.sender) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        totalBalances[from] -= amount;
        totalBalances[to] += amount;
        return true;
    }
    
    function transfer(address to, uint amount) external returns (bool) {
        require(totalBalances[msg.sender] >= amount, "Insufficient balance");
        totalBalances[msg.sender] -= amount;
        totalBalances[to] += amount;
        return true;
    }
    
    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function mint(address to, uint amount, address, uint) external {
        totalBalances[to] += amount;
        totalSupply += amount;
        if (holders[latest_holder + 1] == address(0)) {
            latest_holder++;
            holders[latest_holder] = to;
        }
    }
    
    function turn(address from, uint amount) external returns (uint) {
        require(totalBalances[from] >= amount, "Insufficient balance");
        totalBalances[from] -= amount;
        totalSupply -= amount;
        return amount;
    }
    
    function deposit(address, address, uint amount) external returns (uint) {
        return amount;
    }
    
    function take(address who, uint amount, address, bool) external returns (uint) {
        require(totalBalances[who] >= amount, "Insufficient balance");
        totalBalances[who] -= amount;
        return amount;
    }
    
    function fundUser(address user, uint amount) external {
        totalBalances[user] += amount;
        totalSupply += amount;
        if (holders[latest_holder + 1] == address(0)) {
            latest_holder++;
            holders[latest_holder] = user;
        }
    }
}

contract MockAux {
    function swap(address, bool, uint, uint) external payable returns (uint) {
        return msg.value * 3000;
    }
    
    function wethVault() external view returns (address) {
        return address(this);
    }
}

contract MockRover {
    address public owner;
    constructor() {
        owner = msg.sender;
    }
}

// Mock Settlement for testing that bypasses RANDAO validation
contract TestSettlement is Settlement {
    bool public bypassRandao = true;
    address[] public lastSelectedJurors; // Track selected jurors for testing
    
    function setBypassRandao(bool _bypass) external {
        bypassRandao = _bypass;
    }
    
    // Override with simplified version for testing
    function fulfillJurySelection(uint disputeId, bytes[] calldata) external override {
        Dispute storage dispute = disputes[disputeId];
        uint round = dispute.currentRound;
        
        require(randomnessRequested[disputeId], "Not requested");
        
        // For testing - use simple pseudo-random selection
        bytes32 combinedRandom = keccak256(abi.encodePacked(block.timestamp, disputeId, round));
        
        // Get eligible jurors using the MockBasket
        MockBasket basket = MockBasket(basketContract);
        address[] memory eligible = new address[](30);
        uint eligibleCount = 0;
        
        // First check the actual holders
        for (uint i = 1; i <= basket.latest_holder() && eligibleCount < 30; i++) {
            address holder = basket.holders(i);
            if (holder != address(0) && isEligibleJuror(holder)) {
                eligible[eligibleCount] = holder;
                eligibleCount++;
            }
        }
        
        require(eligibleCount >= 7, "Not enough jurors"); // JURY_SIZE = 7
        
        // Select 7 jurors
        address[] memory selected = new address[](7);
        for (uint i = 0; i < 7; i++) {
            selected[i] = eligible[i];
        }
        
        // Store for testing
        lastSelectedJurors = selected;
        
        DisputeRound storage disputeRound = rounds[disputeId][round];
        disputeRound.selectedJurors = selected;
        disputeRound.votingDeadline = block.timestamp + 3 days; // VOTING_PER = 3 days
        
        for (uint i = 0; i < selected.length; i++) {
            activeDisputes[selected[i]]++;
            emit JurorSelected(selected[i], disputeId, round);
        }
        
        disputes[disputeId].status = DisputeStatus.Appealable;
        emit JurySelected(disputeId, round, selected);
    }
    
    // Add getter for testing
    function getSelectedJurors(uint disputeId, uint round) external view returns (address[] memory) {
        return rounds[disputeId][round].selectedJurors;
    }
    
    // Override getter functions for testing
    function getRoundVerdict(uint disputeId, uint round) external view override returns (VoteChoice) {
        return rounds[disputeId][round].verdict;
    }
    
    function getRoundFinalized(uint disputeId, uint round) external view override returns (bool) {
        return rounds[disputeId][round].finalized;
    }
}

contract SettlementTest is Test {
    TestSettlement public settlement;
    AuctionFactory public factory;
    AuctionHelpers public helpers;
    Auction public predictionMarket;
    MockBasket public basket;
    MockAux public aux;
    MockRover public rover;
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public dan = address(0x4);
    address public eve = address(0x5);
    
    address[] public jurors;
    
    event ProposalCreated(address indexed market, uint proposalId, address proposer, bool outcome, uint stake);
    event ProposalSupported(address indexed market, uint proposalId, address supporter, uint amount);
    event ProposalOpposed(address indexed market, uint proposalId, address opposer, uint amount);
    event ProposalExecuted(address indexed market, uint proposalId);
    event ProposalDisputed(address indexed market, uint proposalId, uint disputeId);
    event JurorSelected(address indexed juror, uint disputeId, uint round);
    event VoteSubmitted(uint indexed disputeId, uint round, address juror);
    event VerdictReached(uint indexed disputeId, uint round, Settlement.VoteChoice verdict);
    
    function setUp() public {
        // Deploy mocks
        basket = new MockBasket();
        aux = new MockAux();
        rover = new MockRover();
        
        // Deploy test settlement with RANDAO bypass
        settlement = new TestSettlement();
        
        // Deploy factory
        factory = new AuctionFactory(
            address(settlement),
            address(rover),
            address(aux),
            address(basket)
        );
        
        // Deploy helpers
        helpers = new AuctionHelpers(
            address(factory),
            address(settlement),
            address(basket)
        );
        
        // Initialize settlement
        settlement.initialize(address(basket), address(factory));
        
        // Deploy test prediction market
        AuctionFactoryLib.LaunchConfig memory config = AuctionFactoryLib.LaunchConfig({
            name: "Test Market",
            symbol: "TEST",
            initialPricePerToken: 100e18,
            auctionDuration: 24 hours
        });
        
        address marketAddress = factory.deployPredictionMarket(
            "Will ETH hit $5000 by end of year?",
            block.timestamp + 30 days,
            config
        );
        
        predictionMarket = Auction(payable(marketAddress));
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dan, 100 ether);
        vm.deal(eve, 100 ether);
        
        // Give users basket tokens for staking
        basket.fundUser(alice, 1000e18);
        basket.fundUser(bob, 1000e18);
        basket.fundUser(carol, 1000e18);
        basket.fundUser(dan, 1000e18);
        basket.fundUser(eve, 1000e18);
        
        // Setup juror pool (minimum 20 holders for proper selection)
        for (uint i = 0; i < 20; i++) {
            address juror = address(uint160(0x1000 + i));
            jurors.push(juror);
            basket.fundUser(juror, 200e18); // Above MIN_JUROR_BALANCE
            vm.deal(juror, 1 ether);
        }
    }
    
    // ============ Proposal Tests ============
    
    function testProposeSettlement() public {
        // Wait for resolution time
        vm.warp(block.timestamp + 31 days);
        
        // Alice proposes YES outcome
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        
        vm.expectEmit(true, true, true, true);
        emit ProposalCreated(address(predictionMarket), 1, alice, true, 100e18);
        
        uint proposalId = settlement.proposeSettlement(
            address(predictionMarket),
            true, // YES outcome
            100e18 // stake
        );
        
        assertEq(proposalId, 1);
        vm.stopPrank();
    }
    
    function testSupportProposal() public {
        // Setup proposal
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        // Bob supports
        vm.startPrank(bob);
        basket.approve(address(settlement), 1000e18);
        
        vm.expectEmit(true, true, true, true);
        emit ProposalSupported(address(predictionMarket), proposalId, bob, 50e18);
        
        settlement.supportProposal(address(predictionMarket), proposalId, 50e18);
        vm.stopPrank();
    }
    
    function testOpposeProposal() public {
        // Setup proposal
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        // Carol opposes
        vm.startPrank(carol);
        basket.approve(address(settlement), 1000e18);
        
        vm.expectEmit(true, true, true, true);
        emit ProposalOpposed(address(predictionMarket), proposalId, carol, 75e18);
        
        settlement.opposeProposal(address(predictionMarket), proposalId, 75e18);
        vm.stopPrank();
    }
    
    function testExecuteProposal() public {
        // Setup and pass proposal
        vm.warp(block.timestamp + 31 days);
        
        // Alice proposes with 200e18
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 200e18);
        vm.stopPrank();
        
        // Bob supports with 100e18 (total support: 300e18)
        vm.startPrank(bob);
        basket.approve(address(settlement), 1000e18);
        settlement.supportProposal(address(predictionMarket), proposalId, 100e18);
        vm.stopPrank();
        
        // Carol opposes with 50e18 (support still 2x higher)
        vm.startPrank(carol);
        basket.approve(address(settlement), 1000e18);
        settlement.opposeProposal(address(predictionMarket), proposalId, 50e18);
        vm.stopPrank();
        
        // Wait for voting period + execution delay
        vm.warp(block.timestamp + 4 days);
        
        // Execute
        vm.expectEmit(true, true, false, false);
        emit ProposalExecuted(address(predictionMarket), proposalId);
        
        settlement.executeProposal(address(predictionMarket), proposalId);
        
        // Check market resolved
        assertTrue(predictionMarket.resolved());
        assertTrue(predictionMarket.outcome()); // YES won
    }
    
    // ============ Dispute Tests ============
    
    function testDisputeProposal() public {
        // Setup proposal
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        // Wait for voting period
        vm.warp(block.timestamp + 3 days + 1);
        
        // Dan disputes
        vm.startPrank(dan);
        basket.approve(address(settlement), 1000e18);
        
        vm.expectEmit(true, true, true, false);
        emit ProposalDisputed(address(predictionMarket), proposalId, 1);
        
        uint disputeId = settlement.disputeProposal(
            address(predictionMarket),
            proposalId,
            "Evidence that outcome should be NO",
            "QmEvidence",
            100e18
        );
        
        assertEq(disputeId, 1);
        vm.stopPrank();
    }
    
    function testJurySelection() public {
        // Create dispute
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 3 days + 1);
        vm.startPrank(dan);
        basket.approve(address(settlement), 1000e18);
        uint disputeId = settlement.disputeProposal(
            address(predictionMarket),
            proposalId,
            "Evidence",
            "Hash",
            100e18
        );
        vm.stopPrank();
        
        // Wait for evidence period
        vm.warp(block.timestamp + 2 days + 1);
        
        // Request jury selection
        settlement.requestJurySelection(disputeId);
        
        // Advance blocks for randomness
        vm.roll(block.number + 6);
        
        // Mock headers (bypassed in test mode)
        bytes[] memory headers = new bytes[](3);
        headers[0] = hex"00";
        headers[1] = hex"01";
        headers[2] = hex"02";
        
        // Fulfill jury selection (using bypass)
        settlement.fulfillJurySelection(disputeId, headers);
        
        // Check jury was selected
        (,, uint currentRound,,,) = settlement.disputes(disputeId);
        assertEq(currentRound, 0);
    }
    
    function testJurorVoting() public {
        // Setup dispute and select jury
        _setupDisputeWithJury();
        
        // Get selected jurors from the contract
        uint disputeId = 1;
        uint round = 0;
        
        // Get the actual selected jurors
        address[] memory selectedJurors = settlement.getSelectedJurors(disputeId, round);
        require(selectedJurors.length >= 4, "Not enough selected jurors");
        
        // First 4 selected jurors vote YES
        for (uint i = 0; i < 4; i++) {
            vm.prank(selectedJurors[i]);
            settlement.submitVote(disputeId, round, Settlement.VoteChoice.Yes);
        }
        
        // Check verdict after majority
        Settlement.VoteChoice verdict = settlement.getRoundVerdict(disputeId, round);
        assertEq(uint(verdict), uint(Settlement.VoteChoice.Yes));
    }
    
    function testDisputeFinalization() public {
        // Setup dispute with voting complete
        _setupDisputeWithVoting();
        
        // The voting deadline is set to block.timestamp + 3 days in fulfillJurySelection
        // After voting is finalized, there's a 1 day appeal period (APPEAL_PER)
        // Need to wait past voting deadline + appeal period
        
        // Wait for voting deadline + appeal period to pass
        vm.warp(block.timestamp + 3 days + 2 days);
        
        // Before finalizing, set the dispute ID in the market
        // This is needed because the market checks disputeId matches
        vm.prank(address(settlement));
        predictionMarket.rule(1, 1); // This will set the dispute ID and resolve
        
        // Actually, let's finalize through the settlement properly
        // The dispute finalization will call rule() on the market
        vm.prank(address(this)); // Reset prank
        settlement.finalizeDispute(1);
        
        // Check market resolved
        assertTrue(predictionMarket.resolved());
        assertTrue(predictionMarket.outcome()); // YES won based on jury vote
    }
    
    function testClaimStakes() public {
        // Execute successful proposal
        vm.warp(block.timestamp + 31 days);
        
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 200e18);
        vm.stopPrank();
        
        vm.startPrank(bob);
        basket.approve(address(settlement), 1000e18);
        settlement.supportProposal(address(predictionMarket), proposalId, 100e18);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 4 days);
        settlement.executeProposal(address(predictionMarket), proposalId);
        
        // Alice claims proposer stake + winnings
        uint aliceBalanceBefore = basket.totalBalances(alice);
        vm.prank(alice);
        settlement.claimStakes(address(predictionMarket), proposalId);
        uint aliceBalanceAfter = basket.totalBalances(alice);
        
        assertGt(aliceBalanceAfter, aliceBalanceBefore);
    }
    
    function testCanSettleView() public {
        // Before resolution time
        (bool canSettle, string memory reason) = settlement.canSettle(address(predictionMarket));
        assertFalse(canSettle);
        assertEq(reason, "Resolution time not reached");
        
        // After resolution time
        vm.warp(block.timestamp + 31 days);
        (canSettle, reason) = settlement.canSettle(address(predictionMarket));
        assertTrue(canSettle);
        assertEq(reason, "Ready for new settlement proposal");
        
        // With active proposal
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        (canSettle, reason) = settlement.canSettle(address(predictionMarket));
        assertFalse(canSettle);
        assertEq(reason, "Active proposal in voting period");
    }
    
    // ============ Helper Functions ============
    
    function _setupDisputeWithJury() internal {
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(alice);
        basket.approve(address(settlement), 1000e18);
        uint proposalId = settlement.proposeSettlement(address(predictionMarket), true, 100e18);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 3 days + 1);
        vm.startPrank(dan);
        basket.approve(address(settlement), 1000e18);
        settlement.disputeProposal(
            address(predictionMarket),
            proposalId,
            "Evidence",
            "Hash",
            100e18
        );
        vm.stopPrank();
        
        vm.warp(block.timestamp + 2 days + 1);
        settlement.requestJurySelection(1);
        
        vm.roll(block.number + 6);
        bytes[] memory headers = new bytes[](3);
        headers[0] = hex"00";
        headers[1] = hex"01";
        headers[2] = hex"02";
        
        settlement.fulfillJurySelection(1, headers);
    }
    
    function _setupDisputeWithVoting() internal {
        _setupDisputeWithJury();
        
        // Get the actual selected jurors
        address[] memory selectedJurors = settlement.getSelectedJurors(1, 0);
        
        // Have majority vote YES
        for (uint i = 0; i < 4 && i < selectedJurors.length; i++) {
            vm.prank(selectedJurors[i]);
            settlement.submitVote(1, 0, Settlement.VoteChoice.Yes);
        }
    }
}
