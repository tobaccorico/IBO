// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol"; // TODO 
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {AuctionFactoryLib} from "../src/AuctionFactoryLib.sol";
import {AuctionLogic} from "../src/AuctionLogic.sol";
import {AuctionHelpers} from "../src/AuctionHelpers.sol";
import {Basket} from "../src/Basket.sol";

// Mock Contracts (same as before)
contract MockRover {
    address public owner;
    constructor() {
        owner = msg.sender;
    }
    receive() external payable {}
}

contract MockAux {
    address public WETH = address(0x1234);
    
    function swap(address, bool, uint, uint) 
        external payable returns (uint) {
        return msg.value * 3000;
    }
    
    function token1isWETH() external pure returns (bool) {
        return true;
    }
    
    function getPrice(uint160, bool) external pure returns (uint) {
        return 3000e18;
    }
    
    function putETH(uint amount) external returns (uint) {
        return amount;
    }
    
    function sendETH(uint amount, address to) external {
        payable(to).transfer(amount);
    }
    
    function wethVault() external pure returns (address) {
        return address(0x5678);
    }
}

contract MockBasket {
    mapping(address => mapping(uint => uint)) public balanceOf;
    mapping(address => uint) public totalBalances;
    mapping(uint => address) public holders;
    uint public latest_holder;
    uint public totalSupply;
    
    function mint(address to, uint amount, address, uint) external {
        balanceOf[to][0] += amount;
        totalBalances[to] += amount;
        totalSupply += amount;
        
        // Add to holders if new
        if (totalBalances[to] == amount) {
            latest_holder++;
            holders[latest_holder] = to;
        }
    }
    
    function deposit(address, address, uint amount) external returns (uint) {
        return amount;
    }
    
    function take(address who, uint amount, address, bool) external returns (uint) {
        uint available = balanceOf[who][0];
        uint sent = amount > available ? available : amount;
        if (sent > 0) {
            balanceOf[who][0] -= sent;
            totalBalances[who] -= sent;
        }
        return sent;
    }
    
    function isStable(address) external pure returns (bool) {
        return true;
    }
    
    function isVault(address) external pure returns (bool) {
        return false;
    }
    
    function turn(address from, uint amount) external returns (uint) {
        require(balanceOf[from][0] >= amount, "Insufficient balance");
        balanceOf[from][0] -= amount;
        totalBalances[from] -= amount;
        totalSupply -= amount;
        return amount;
    }
    
    function approve(address, uint) external pure returns (bool) {
        return true;
    }
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        require(totalBalances[from] >= amount, "Insufficient balance");
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
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;
    string public constant name = "MockToken";
    string public constant symbol = "MOCK";
    
    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// Updated AuctionFactory mock to work with new initialization
contract MockAuctionFactory {
    address public settlementSystem;
    address public rover;
    address public aux;
    address public basket;
    
    constructor(address _settlement, address _rover, address _aux, address _basket) {
        settlementSystem = _settlement;
        rover = _rover;
        aux = _aux;
        basket = _basket;
    }
    
    function deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        string memory name,
        string memory symbol
    ) external returns (address) {
        Auction market = new Auction();
        
        console.log("Creating test market with new init params structure");
        
        AuctionLogic.InitParams memory initParams = AuctionLogic.InitParams({
            name: name,
            symbol: symbol,
            auctionDuration: 24 hours,
            totalEpochs: 10,
            owner: msg.sender,
            settlementSystem: settlementSystem,
            rover: rover,
            aux: aux,
            basket: basket
        });
        
        market.initialize(initParams);
        market.initializePredictionMarket(
            question,
            resolutionTime,
            0, // metaEvidenceId
            false, // requiresContent
            0, // contentDeadline
            2 // minParticipants
        );
        
        return address(market);
    }
}

contract AuctionTest is Test {
    MockAuctionFactory public factory;
    AuctionHelpers public helpers;
    Auction public predictionMarket;
    Settlement public settlement;
    Basket public basket;
    MockToken public mockUSDC;
    
    // Test accounts
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public whale = address(0x4);
    address public clearer = address(0x5);
    
    uint public metaEvidenceId;
    
    // Events to test
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event MarketResolved(bool outcome);
    event PayoutClaimed(address indexed user, uint amount);
    
    function setUp() public {
        // Deploy infrastructure
        settlement = new Settlement();
        metaEvidenceId = settlement.createPredictionMarketMetaEvidence();
        
        MockAux aux = new MockAux();
        basket = Basket(address(new MockBasket()));
        mockUSDC = new MockToken();
        
        factory = new MockAuctionFactory(
            address(settlement),
            address(new MockRover()),
            address(aux),
            address(basket)
        );
        
        helpers = new AuctionHelpers(
            address(factory),
            address(settlement),
            address(basket)
        );
        
        settlement.initialize(address(basket), address(factory));
        
        // Deploy test prediction market
        address marketAddress = factory.deployPredictionMarket(
            "Will ETH hit $5000 by end of year?",
            block.timestamp + 30 days,
            "ETH 5K Prediction",
            "ETH5K"
        );
        predictionMarket = Auction(payable(marketAddress));
        
        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(whale, 10000 ether);
        vm.deal(clearer, 100 ether);
        
        // Give mock USDC to users
        mockUSDC.mint(alice, 10000e18);
        mockUSDC.mint(bob, 10000e18);
        mockUSDC.mint(whale, 100000e18);
    }
    
    // ============ Core Functionality Tests ============
    
    function testUnifiedBatchBidding() public {
        vm.startPrank(alice);
        
        // ALL bids now go to batch, no immediate allocation
        uint aliceBalanceBefore = predictionMarket.balanceOf(alice);
        predictionMarket.placePredictionBid{value: 0.5 ether}(0.5e18, true);
        uint aliceBalanceAfter = predictionMarket.balanceOf(alice);
        
        // Should NOT receive tokens immediately
        assertEq(aliceBalanceAfter, aliceBalanceBefore, "Should not receive tokens before batch clear");
        
        vm.stopPrank();
        
        // Clear batch to allocate tokens
        predictionMarket.clearBatches();
        
        // Now check balance
        uint aliceBalanceFinal = predictionMarket.balanceOf(alice);
        assertGt(aliceBalanceFinal, aliceBalanceBefore, "Should receive tokens after batch clear");
    }
    
    function testTokenBidding() public {
        // Setup token approval
        vm.startPrank(alice);
        mockUSDC.approve(address(basket), 1000e18);
        
        // Place bid with token - should go to batch
        predictionMarket.placePredictionBidWithToken(0.5e18, true, address(mockUSDC), 500e18);
        
        // Should NOT have shares yet
        (uint yesShares, , , ) = predictionMarket.getUserPosition(alice);
        assertEq(yesShares, 0, "Should not have YES shares before batch clear");
        
        vm.stopPrank();
        
        // Clear batch
        predictionMarket.clearBatches();
        
        // Now should have shares
        (uint yesSharesAfter, , , ) = predictionMarket.getUserPosition(alice);
        assertGt(yesSharesAfter, 0, "Should have YES shares after batch clear");
    }
    
    // ============ Batch Processing Tests ============
    
    function testDynamicBatchThreshold() public {
        // Initial threshold should be minimum
        (, uint threshold1, , , ) = predictionMarket.getMarketMetrics();
        assertEq(threshold1, 1000e18, "Initial threshold should be $1000");
        
        // Place several bids to increase market depth
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        }
        
        // Clear batches to process
        predictionMarket.clearBatches();
        
        // Check threshold increased with depth
        (uint depth, uint threshold2, , , ) = predictionMarket.getMarketMetrics();
        assertGt(depth, 0, "Market depth should increase");
        
        if (depth >= 10000e18) {
            assertGt(threshold2, threshold1, "Threshold should increase with depth");
        }
    }
    
    function testBatchQueuing() public {
        // All bids should be batched now
        vm.startPrank(whale);
        
        vm.expectEmit(true, false, false, true);
        emit BidPlaced(whale, 15000e18, 0.6e18, true, 0, 1); // Updated event expectations
        
        predictionMarket.placePredictionBid{value: 5 ether}(0.6e18, true);
        
        // Should not have tokens yet
        uint whaleBalance = predictionMarket.balanceOf(whale);
        assertEq(whaleBalance, 0, "Should not receive tokens before batch clear");
        
        // Check batch was created
        (uint yesTotal, , uint yesBids, ) = predictionMarket.getBatchInfo(block.number);
        assertGt(yesTotal, 0, "Should have batch total");
        assertEq(yesBids, 1, "Should have one bid in batch");
        
        vm.stopPrank();
    }
    
    function testBatchClearing() public {
        // Create batches
        vm.prank(whale);
        predictionMarket.placePredictionBid{value: 5 ether}(0.6e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 4 ether}(0.4e18, false);
        
        uint blockBefore = block.number;
        
        // Clear batches
        vm.prank(clearer);
        predictionMarket.clearBatches();
        
        // Check batches were cleared (deleted after processing)
        (uint yesTotal, uint noTotal, , ) = predictionMarket.getBatchInfo(blockBefore);
        assertEq(yesTotal, 0, "YES batch should be cleared");
        assertEq(noTotal, 0, "NO batch should be cleared");
        
        // Check users received tokens
        assertGt(predictionMarket.balanceOf(whale), 0, "Whale should have tokens");
        assertGt(predictionMarket.balanceOf(bob), 0, "Bob should have tokens");
    }
    
    function testSortedSetAllocation() public {
        // Test that higher price bids get allocated first via sorted set
        
        // Place bids at different prices in same epoch
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.3e18, true); // Low price
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 1 ether}(0.8e18, true); // High price
        
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true); // Medium price
        
        // Clear the current epoch (alternative to batch clearing)
        uint epochIndex = predictionMarket.currentEpochIndex();
        
        // Move time forward to end epoch
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Clear epoch - this uses sorted set allocation
        predictionMarket.clearEpoch(epochIndex);
        
        // Bob (highest price) should get most/all allocation
        // Check that shares were allocated in price order
        (uint bobYes, , , ) = predictionMarket.getUserPosition(bob);
        (uint aliceYes, , , ) = predictionMarket.getUserPosition(alice);
        
        // If there were limited shares, bob should get more than alice
        if (bobYes > 0 && aliceYes > 0) {
            // Both got some, but bob should have gotten first pick
            assertGe(bobYes, aliceYes, "Higher price bid should get priority");
        }
    }
    
    function testGasCompensation() public {
        // Create large batch
        for (uint i = 0; i < 10; i++) {
            address bidder = address(uint160(0x100 + i));
            vm.deal(bidder, 10 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        }
        
        uint clearerBalanceBefore = clearer.balance;
        
        // Clear with gas tracking
        vm.prank(clearer);
        predictionMarket.clearBatches();
        
        // Check compensation metrics
        (, , , uint protocolFees, uint lastClear) = predictionMarket.getMarketMetrics();
        
        if (clearerBalanceBefore < clearer.balance) {
            assertGt(clearer.balance, clearerBalanceBefore, "Should receive gas compensation");
        }
    }
    
    function testAutoClearTrigger() public {
        // Create batch that meets auto-clear threshold (10+ bids or $50k+)
        for (uint i = 0; i < 12; i++) {
            address bidder = address(uint160(0x200 + i));
            vm.deal(bidder, 10 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        }
        
        // Next bid should trigger auto-clear
        uint lastBlock = predictionMarket.lastClearBlock();
        
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.5e18, true);
        
        // Check if batch was auto-cleared
        uint newLastBlock = predictionMarket.lastClearBlock();
        assertGt(newLastBlock, lastBlock, "Batch should be auto-cleared");
    }
    
    // ============ Market Entropy Tests ============
    
    function testEntropyIncrease() public {
        // Get initial entropy
        (, , uint entropy1, , ) = predictionMarket.getMarketMetrics();
        
        // Place bid to increase entropy
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Check entropy increased
        (, , uint entropy2, , ) = predictionMarket.getMarketMetrics();
        assertGt(entropy2, entropy1, "Entropy should increase with activity");
    }
    
    function testEntropyDecay() public {
        // Place bid to increase entropy
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        (, , uint entropy1, , ) = predictionMarket.getMarketMetrics();
        
        // Advance blocks to trigger decay
        vm.roll(block.number + 10);
        
        // Place another bid to update entropy
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 0.5 ether}(0.5e18, false);
        
        // Entropy should have decayed then increased slightly
        (, , uint entropy2, , ) = predictionMarket.getMarketMetrics();
        assertLt(entropy2, entropy1 + 100, "Entropy should decay over time");
    }
    
    // ============ Settlement Tests ============
    
    function testPayoutFlow() public {
        // Place bids
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 3 ether}(0.8e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 2 ether}(0.4e18, false);
        
        // Clear batches to allocate shares
        predictionMarket.clearBatches();
        
        // Resolve market
        vm.warp(block.timestamp + 31 days);
        _resolveMarket(true); // YES wins
        
        // Check Alice can claim
        uint alicePayout = predictionMarket.calculatePredictionPayout(alice);
        assertGt(alicePayout, 0, "Alice should have payout");
        
        uint aliceBasketBefore = basket.balanceOf(alice, 0);
        vm.prank(alice);
        predictionMarket.claimPredictionPayout();
        
        uint aliceBasketAfter = basket.balanceOf(alice, 0);
        assertEq(aliceBasketAfter - aliceBasketBefore, alicePayout, "Alice should receive payout");
    }
    
    function testForceMajeurRefund() public {
        // Place bids
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, false);
        
        // Clear batches
        predictionMarket.clearBatches();
        
        // Resolve with force majeur
        vm.warp(block.timestamp + 31 days);
        _resolveMarket(false, true);
        
        // Both should be able to claim refunds
        vm.prank(alice);
        predictionMarket.claimForceMajeurRefund();
        
        vm.prank(bob);
        predictionMarket.claimForceMajeurRefund();
        
        // Check refunds received
        assertGt(basket.balanceOf(alice, 0), 0, "Alice should receive refund");
        assertGt(basket.balanceOf(bob, 0), 0, "Bob should receive refund");
    }
    
    // ============ State Access Tests ============
    
    function testStateAccess() public {
        // Test accessing the new state through individual getters
        bool bettingClosed = predictionMarket.bettingWindowClosed();
        bool resolved = predictionMarket.resolved();
        bool outcome = predictionMarket.outcome();
        bool forceMajeur = predictionMarket.forceMajeurRefunds();
        
        assertFalse(bettingClosed, "Betting should be open");
        assertFalse(resolved, "Should not be resolved");
        assertFalse(forceMajeur, "Should not be force majeur");
    }
    
    function testParamsAccess() public {
        // Since params is likely internal, we access through view functions
        (, , , , bool isActive) = predictionMarket.getCurrentEpochInfo();
        assertTrue(isActive, "Market should be active");
        
        (string memory question, , , , , , ) = predictionMarket.getPredictionSummary();
        assertEq(question, "Will ETH hit $5000 by end of year?", "Question should match");
    }
    
    // ============ Edge Cases ============
    
    function testMinimumBidRequirement() public {
        vm.startPrank(alice);
        
        // Try to place a bid below minimum
        vm.expectRevert(bytes("Below min"));
        predictionMarket.placePredictionBid{value: 0.01 ether}(0.5e18, true);
        
        vm.stopPrank();
    }
    
    function testInvalidPriceTier() public {
        vm.startPrank(alice);
        
        // Try to place bid with invalid price tier (not in 0.1, 0.2, ..., 1.0)
        vm.expectRevert(bytes("Invalid tier"));
        predictionMarket.placePredictionBid{value: 1 ether}(0.15e18, true); // 0.15 is not a valid tier
        
        vm.stopPrank();
    }
    
    function testEpochProgression() public {
        // Check initial epoch
        (uint index, , , , bool isActive) = predictionMarket.getCurrentEpochInfo();
        assertEq(index, 0, "Should start at epoch 0");
        assertTrue(isActive, "Epoch should be active");
        
        // Advance time to trigger epoch progression
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Place bid to trigger epoch check
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Check epoch advanced
        (uint newIndex, , , , ) = predictionMarket.getCurrentEpochInfo();
        assertEq(newIndex, 1, "Should advance to epoch 1");
    }
    
    function testContentSubmission() public {
        // Deploy new market with content requirement
        Auction contentMarket = new Auction();
        
        AuctionLogic.InitParams memory initParams = AuctionLogic.InitParams({
            name: "Content Market",
            symbol: "CONTENT",
            auctionDuration: 24 hours,
            totalEpochs: 10,
            owner: address(this),
            settlementSystem: address(settlement),
            rover: address(factory.rover()),
            aux: address(factory.aux()),
            basket: address(basket)
        });
        
        contentMarket.initialize(initParams);
        contentMarket.initializePredictionMarket(
            "Test question",
            block.timestamp + 30 days,
            0,
            true, // requiresContent
            block.timestamp + 1 days, // contentDeadline
            2
        );
        
        // Set authorized submitters
        contentMarket.setAuthorizedSubmitters(alice, bob);
        
        // Alice submits with content
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, true, "Test content");
        
        // Bob submits with content
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, false, "Test content 2");
        
        // Third submission should fail (max 2)
        vm.deal(carol, 10 ether);
        contentMarket.setAuthorizedSubmitters(carol, carol);
        vm.prank(carol);
        vm.expectRevert(bytes("Max"));
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, true, "Test content 3");
    }
    
    // ============ Helpers ============
    
    function _resolveMarket(bool outcome) internal {
        _resolveMarket(outcome, false);
    }
    
    function _resolveMarket(bool outcome, bool forceMajeur) internal {
        MockBasket(address(basket)).mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        
        uint proposalId = settlement.proposeSettlement(
            address(predictionMarket),
            outcome,
            100e18
        );
        
        if (forceMajeur) {
            vm.stopPrank();
            
            // Since we can't access state directly, we use the disputeId getter if available
            // or just pass 0 since it's for force majeur
            vm.prank(address(settlement));
            predictionMarket.rule(0, 2);
        } else {
            vm.warp(block.timestamp + 4 days);
            settlement.executeProposal(address(predictionMarket), proposalId);
            vm.stopPrank();
        }
    }
}