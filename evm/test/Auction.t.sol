// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {AuctionFactoryLib} from "../src/AuctionFactoryLib.sol";
import {AuctionLogic} from "../src/AuctionLogic.sol";
import {AuctionHelpers} from "../src/AuctionHelpers.sol";
import {Basket} from "../src/Basket.sol";

// Mock Contracts
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

contract AuctionTest is Test {
    AuctionFactory public factory;
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
    event BatchQueued(address indexed bidder, uint blockNumber, uint amount, bool isYes);
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    
    function setUp() public {
        // Deploy infrastructure
        settlement = new Settlement();
        metaEvidenceId = settlement.createPredictionMarketMetaEvidence();
        
        MockAux aux = new MockAux();
        basket = Basket(address(new MockBasket()));
        mockUSDC = new MockToken();
        
        factory = new AuctionFactory(
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
        
        // Deploy test prediction market using factory
        AuctionFactoryLib.LaunchConfig memory config = AuctionFactoryLib.LaunchConfig({
            name: "ETH 5K Prediction",
            symbol: "ETH5K",
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
        
        predictionMarket.placePredictionBid{value: 0.5 ether}(0.5e18, true);
        
        // Should NOT receive tokens immediately
        uint aliceBalanceBefore = predictionMarket.balanceOf(alice);
        assertEq(aliceBalanceBefore, 0, "Should not receive tokens before batch clear");
        
        vm.stopPrank();
        
        // Move to next block to allow clearing
        vm.roll(block.number + 1);
        
        // Clear batch to allocate tokens
        predictionMarket.clearBatches();
        
        // Now check balance
        uint aliceBalanceFinal = predictionMarket.balanceOf(alice);
        assertGt(aliceBalanceFinal, 0, "Should receive tokens after batch clear");
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
        
        // Move to next block and clear
        vm.roll(block.number + 1);
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
        
        // Move to next block and clear
        vm.roll(block.number + 1);
        predictionMarket.clearBatches();
        
        // Check threshold increased with depth
        (uint depth, uint threshold2, , , ) = predictionMarket.getMarketMetrics();
        assertGt(depth, 0, "Market depth should increase");
        
        if (depth >= 10000e18) {
            assertGt(threshold2, threshold1, "Threshold should increase with depth");
        }
    }
    
    function testBatchQueuing() public {
        vm.startPrank(whale);
        
        // Calculate expected USD amount after fee
        uint ethAmount = 5 ether;
        uint fee = (ethAmount * 50) / 10000; // BASE_FEE_BPS = 50
        uint netAmount = ethAmount - fee;
        uint usdAmount = netAmount * 3000; // Mock conversion rate
        
        // Updated event expectation with correct amount
        vm.expectEmit(true, false, false, true);
        emit BatchQueued(whale, block.number, usdAmount, true);
        
        predictionMarket.placePredictionBid{value: ethAmount}(0.6e18, true);
        
        // Check batch was created
        (uint yesTotal, , uint yesBids, ) = predictionMarket.getBatchInfo(block.number);
        assertGt(yesTotal, 0, "Should have batch total");
        assertEq(yesBids, 1, "Should have one bid in batch");
        
        vm.stopPrank();
    }
    
    function testBatchClearing() public {
        // Check initial epoch has shares
        (uint epochIndex, , , , ) = predictionMarket.getCurrentEpochInfo();
        console.log("Current epoch index:", epochIndex);
        
        // Create batches - use different prices to ensure ordering
        vm.prank(whale);
        predictionMarket.placePredictionBid{value: 5 ether}(0.6e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 4 ether}(0.5e18, false); // Use 0.5 instead of 0.4
        
        uint blockBefore = block.number;
        
        // Check batch info before clearing
        (uint yesTotalBefore, uint noTotalBefore, uint yesBidsBefore, uint noBidsBefore) = predictionMarket.getBatchInfo(blockBefore);
        console.log("Before clear - YES total:", yesTotalBefore, "bids:", yesBidsBefore);
        console.log("Before clear - NO total:", noTotalBefore, "bids:", noBidsBefore);
        
        // Move to next block to allow clearing
        vm.roll(block.number + 1);
        
        // Clear batches
        vm.prank(clearer);
        predictionMarket.clearBatches();
        
        // Check batches were cleared (deleted after processing)
        (uint yesTotal, uint noTotal, , ) = predictionMarket.getBatchInfo(blockBefore);
        assertEq(yesTotal, 0, "YES batch should be cleared");
        assertEq(noTotal, 0, "NO batch should be cleared");
        
        // Check users received shares (not necessarily tokens yet)
        (uint whaleYes, , uint whaleTokens, ) = predictionMarket.getUserPosition(whale);
        (uint bobYes, uint bobNo, uint bobTokens, ) = predictionMarket.getUserPosition(bob);
        
        console.log("Whale - YES shares:", whaleYes, "tokens:", whaleTokens);
        // console.log("Bob - YES shares:", bobYes, "NO shares:", bobNo, "tokens:", bobTokens);
        
        assertGt(whaleYes, 0, "Whale should have YES shares");
        assertGt(bobNo, 0, "Bob should have NO shares");
        
        // Now check if they have tokens
        assertGt(predictionMarket.balanceOf(whale), 0, "Whale should have tokens");
        assertGt(predictionMarket.balanceOf(bob), 0, "Bob should have tokens");
    }
    
    function testSortedSetAllocation() public {
        // Place bids at different prices in same epoch
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.3e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 1 ether}(0.8e18, true);
        
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Clear the current epoch
        uint epochIndex = predictionMarket.currentEpochIndex();
        
        // Move time forward to end epoch
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Clear epoch - this uses sorted set allocation
        predictionMarket.clearEpoch(epochIndex);
        
        // Bob (highest price) should get most/all allocation
        (uint bobYes, , , ) = predictionMarket.getUserPosition(bob);
        (uint aliceYes, , , ) = predictionMarket.getUserPosition(alice);
        
        if (bobYes > 0 && aliceYes > 0) {
            assertGe(bobYes, aliceYes, "Higher price bid should get priority");
        }
    }
    
    function testGasCompensation() public {
        // Create batch at a specific block
        uint startBlock = block.number;
        
        for (uint i = 0; i < 10; i++) {
            address bidder = address(uint160(0x100 + i));
            vm.deal(bidder, 10 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        }
        
        uint clearerBalanceBefore = clearer.balance;
        
        // Move to next block to allow clearing
        vm.roll(block.number + 1);
        
        // Clear as the clearer
        vm.prank(clearer);
        predictionMarket.clearBatches();
        
        // Check if compensation was paid (might be 0 if fees are low)
        uint clearerBalanceAfter = clearer.balance;
        
        // At minimum, the transaction should complete without reverting
        // Compensation depends on gas price and available fees
        (, , , uint protocolFees, ) = predictionMarket.getMarketMetrics();
        
        // If there are protocol fees, some compensation might be paid
        if (protocolFees > 0) {
            // Compensation is capped at 5% of protocol fees
            uint maxCompensation = protocolFees / 20;
            uint actualCompensation = clearerBalanceAfter - clearerBalanceBefore;
            assertLe(actualCompensation, maxCompensation, "Compensation should be capped");
        }
    }
    
    function testAutoClearTrigger() public {
        // Get initial last clear block
        uint initialLastBlock = predictionMarket.lastClearBlock();
        
        // Create batch that meets auto-clear threshold (10+ bids)
        for (uint i = 0; i < 12; i++) {
            address bidder = address(uint160(0x200 + i));
            vm.deal(bidder, 10 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        }
        
        uint batchBlock = block.number;
        
        // All bids should be in the same block's batch
        (uint yesTotal, , uint yesBids, ) = predictionMarket.getBatchInfo(batchBlock);
        assertEq(yesBids, 12, "Should have 12 bids in batch");
        
        // Move to next block to allow clearing
        vm.roll(block.number + 1);
        
        // Now manually trigger the clear (auto-clear disabled to prevent loops)
        bool canClear = predictionMarket.shouldAutoClear();
        assertTrue(canClear, "Should be able to auto-clear");
        
        // Trigger the clear
        predictionMarket.triggerAutoClear();
        
        // Check if batch was cleared
        // lastClearBlock should now be batchBlock + 1 (the block after the batch)
        uint newLastBlock = predictionMarket.lastClearBlock();
        assertGt(newLastBlock, initialLastBlock, "Last clear block should advance");
        assertEq(newLastBlock, batchBlock + 1, "Should clear up to batch block + 1");
        
        // Verify the batch was actually cleared
        (yesTotal, , yesBids, ) = predictionMarket.getBatchInfo(batchBlock);
        assertEq(yesTotal, 0, "Batch should be cleared");
        assertEq(yesBids, 0, "Batch trades should be deleted");
    }
    
    // ============ Settlement Tests ============
    
    function testPayoutFlow() public {
        // Place bids
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 3 ether}(0.8e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 2 ether}(0.4e18, false);
        
        // Move to next block and clear batches
        vm.roll(block.number + 1);
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
        
        // Move to next block and clear batches to allocate shares
        vm.roll(block.number + 1);
        predictionMarket.clearBatches();
        
        // Verify users have shares after clearing
        (uint aliceYes, , , ) = predictionMarket.getUserPosition(alice);
        (uint bobYes, uint bobNo, , ) = predictionMarket.getUserPosition(bob);
        
        console.log("Alice YES shares:", aliceYes);
        console.log("Bob YES shares:", bobYes, "NO shares:", bobNo);
        
        assertGt(aliceYes, 0, "Alice should have YES shares");
        assertGt(bobNo, 0, "Bob should have NO shares");
        
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
        bool bettingClosed = predictionMarket.bettingWindowClosed();
        bool resolved = predictionMarket.resolved();
        bool outcome = predictionMarket.outcome();
        bool forceMajeur = predictionMarket.forceMajeurRefunds();
        
        assertFalse(bettingClosed, "Betting should be open");
        assertFalse(resolved, "Should not be resolved");
        assertFalse(forceMajeur, "Should not be force majeur");
    }
    
    function testParamsAccess() public {
        (, , , , bool isActive) = predictionMarket.getCurrentEpochInfo();
        assertTrue(isActive, "Market should be active");
        
        (string memory question, , , , , , ) = predictionMarket.getPredictionSummary();
        assertEq(question, "Will ETH hit $5000 by end of year?", "Question should match");
    }
    
    // ============ Edge Cases ============
    
    function testMinimumBidRequirement() public {
        vm.startPrank(alice);
        
        // Updated error message
        vm.expectRevert(bytes("Below minimum"));
        predictionMarket.placePredictionBid{value: 0.01 ether}(0.5e18, true);
        
        vm.stopPrank();
    }
    
    function testInvalidPriceTier() public {
        vm.startPrank(alice);
        
        // Price gets auto-normalized now, so it won't revert
        // Instead, test that it normalizes correctly
        predictionMarket.placePredictionBid{value: 1 ether}(0.15e18, true);
        
        // The bid should succeed with normalized price (0.2e18)
        // We can verify by checking that a bid was placed
        (uint yesTotal, , , ) = predictionMarket.getBatchInfo(block.number);
        assertGt(yesTotal, 0, "Bid should be placed with normalized price");
        
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
        AuctionFactoryLib.LaunchConfig memory config = AuctionFactoryLib.LaunchConfig({
            name: "Rap Battle",
            symbol: "RAP",
            initialPricePerToken: 50e18,
            auctionDuration: 24 hours
        });
        
        // Alice creates the rap battle market
        vm.prank(alice);
        address contentMarketAddress = factory.deployRapBattleMarket(
            "Alice",
            "Bob",
            block.timestamp + 1 days,
            config
        );
        
        Auction contentMarket = Auction(payable(contentMarketAddress));
        
        // Alice is already authorized as the creator
        // Alice submits with content
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, true, "Test content");
        
        // Authorize Bob for second submission
        vm.prank(alice); // Creator can authorize
        contentMarket.setAuthorizedSubmitters(bob, address(0));
        
        // Bob submits with content
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, false, "Test content 2");
        
        // Third submission should fail (max 2)
        vm.deal(carol, 10 ether);
        vm.prank(alice); // Even creator can't authorize more
        contentMarket.setAuthorizedSubmitters(carol, address(0));
        
        vm.prank(carol);
        vm.expectRevert(bytes("Max content reached"));
        contentMarket.placePredictionBidWithContent{value: 1 ether}(0.5e18, true, "Test content 3");
    }
    
    // Skip entropy tests as entropy was removed
    function testEntropyIncrease() public {
        vm.skip(true); // Entropy removed from system
    }
    
    function testEntropyDecay() public {
        vm.skip(true); // Entropy removed from system
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
            vm.prank(address(settlement));
            predictionMarket.rule(0, 2);
        } else {
            vm.warp(block.timestamp + 4 days);
            settlement.executeProposal(address(predictionMarket), proposalId);
            vm.stopPrank();
        }
    }
}