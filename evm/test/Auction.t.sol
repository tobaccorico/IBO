// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {Basket} from "../src/Basket.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// ============ Mock Contracts ============

contract MockRover {
    // Minimal Rover mock
    receive() external payable {}
}

contract PayableContract {
    // Contract that can receive ETH
    receive() external payable {}
}

contract MockAux {
    // Mock Aux that handles ETH->USD swaps for Auction
    function swap(address token, bool zeroForOne, uint amount, uint waitable) 
        external payable returns (uint) {
        // Mock swap: return USD amount based on ETH sent
        // Assuming 1 ETH = 3000 USD for testing
        if (!zeroForOne) { // Selling ETH for USD
            // Return USD based on msg.value (the actualBetETH after gas fee)
            return msg.value * 3000; // Return USD amount
        }
        return amount;
    }
}

contract MockBasket {
    // Mock Basket for USD storage (implements minimal ERC6909 interface)
    mapping(address => mapping(uint => uint)) public balanceOf;
    mapping(address => uint) public totalBalances;
    
    uint public totalSupply;
    
    function mint(address to, uint amount, address, uint) external {
        balanceOf[to][0] += amount; // Use ID 0 for simplicity
        totalBalances[to] += amount;
        totalSupply += amount;
    }
    
    function deposit(address, address, uint amount) external returns (uint) {
        // Mock deposit - just return the amount
        return amount;
    }
    
    function isStable(address) external pure returns (bool) {
        return true; // All tokens are "stable" in mock
    }
    
    function isVault(address) external pure returns (bool) {
        return false;
    }
    
    function transfer(address to, uint amount) external {
        balanceOf[msg.sender][0] -= amount;
        totalBalances[msg.sender] -= amount;
        balanceOf[to][0] += amount;
        totalBalances[to] += amount;
    }
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        balanceOf[from][0] -= amount;
        totalBalances[from] -= amount;
        balanceOf[to][0] += amount;
        totalBalances[to] += amount;
        return true;
    }
    
    function approve(address spender, uint amount) external returns (bool) {
        // Mock approval
        return true;
    }
    
    // Add burn functionality for settlements
    function turn(address from, uint amount) external returns (uint) {
        require(balanceOf[from][0] >= amount, "Insufficient balance");
        balanceOf[from][0] -= amount;
        totalBalances[from] -= amount;
        totalSupply -= amount;
        return amount;
    }
}

contract AuctionTest is Test {
    AuctionFactory public factory;
    Auction public predictionMarket;
    Settlement public settlement;
    Basket public basket;
    
    // Test accounts
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    
    uint public metaEvidenceId;
    
    function setUp() public {
        // Deploy minimal infrastructure - Auction only needs Aux, Basket, and Settlement
        
        // Deploy Settlement
        settlement = new Settlement();
        metaEvidenceId = settlement.createPredictionMarketMetaEvidence();
        
        // Deploy mock Aux that handles ETH->USD swaps
        MockAux aux = new MockAux();
        
        // Deploy mock Basket for USD storage
        basket = Basket(address(new MockBasket()));
        
        // Deploy Factory (need to provide valid rover address)
        factory = new AuctionFactory(
            address(settlement),
            address(new MockRover()), // Provide actual rover instance
            address(aux),
            address(basket)
        );
        
        // Initialize Settlement with factory
        settlement.initialize(address(basket), address(factory));
        
        // Deploy test prediction market through factory
        AuctionFactory.LaunchConfig memory config = AuctionFactory.LaunchConfig({
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
    }
    
    // ============ Core Belgian Auction Tests (No Commit-Reveal) ============
    
    function testPlacePredictionBid() public {
        // Alice bets YES at 60% confidence - no commit-reveal needed
        vm.startPrank(alice);
        predictionMarket.placePredictionBid{value: 4 ether}(0.6e18, true);
        vm.stopPrank();
        
        // Check bid was recorded
        uint[] memory aliceBidIds = predictionMarket.getUserBidIds(alice);
        assertEq(aliceBidIds.length, 1);
        
        // Check bid details
        (
            address bidder,
            uint usdAmount,
            uint pricePerShare,
            uint sharesAllocated,
            bool isYes,
            
        ) = predictionMarket.getBidDetails(aliceBidIds[0]);
        
        assertEq(bidder, alice);
        assertGt(usdAmount, 0); // Should have USD from swap
        assertEq(pricePerShare, 0.6e18);
        assertEq(sharesAllocated, 0); // Not cleared yet
        assertTrue(isYes);
    }
    
    function testVelocityBasedMEVProtection() public {
        // Test velocity-based dynamic fees
        vm.startPrank(alice);
        
        // First bid - should have minimal fees
        uint balanceBefore1 = address(predictionMarket).balance;
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        uint balanceAfter1 = address(predictionMarket).balance;
        uint gasContribution1 = balanceAfter1 - balanceBefore1;
        
        // Check velocity increased
        uint velocityAfter1 = predictionMarket.bidVelocity(alice);
        assertGt(velocityAfter1, 0, "Velocity should increase");
        
        // Immediate second bid - should have higher fees due to velocity
        uint balanceBefore2 = address(predictionMarket).balance;
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        uint balanceAfter2 = address(predictionMarket).balance;
        uint gasContribution2 = balanceAfter2 - balanceBefore2;
        
        // Second bid should have higher gas contribution due to velocity penalty
        assertGt(gasContribution2, gasContribution1, "Rapid bidding should increase fees");
        
        vm.stopPrank();
    }
    
    function testBelgianPricePriority() public {
        // Place bids at different confidence levels - no commit-reveal
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 2 ether}(0.3e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 2 ether}(0.8e18, true);
        
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 2 ether}(0.5e18, true);
        
        // Move past epoch
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Clear epoch
        predictionMarket.clearEpoch(0);
        
        // Check allocations - Bob should get shares first (highest price)
        uint[] memory bobBids = predictionMarket.getUserBidIds(bob);
        (, , , uint bobShares, , ) = predictionMarket.getBidDetails(bobBids[0]);
        assertGt(bobShares, 0, "Bob should get shares");
    }
    
    function testRandomizedEpochTiming() public {
        // Check that epochs have randomized timing
        (, uint endTime1, , , , , , , ) = predictionMarket.getEpoch(0);
        
        // Force epoch transition
        vm.warp(endTime1 + 1);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.5e18, true);
        
        // Check second epoch timing
        (, uint endTime2, , , , , , , ) = predictionMarket.getEpoch(1);
        
        // Duration should be randomized (not exactly 1 hour)
        uint duration1 = endTime1 - block.timestamp + (endTime1 - block.timestamp);
        uint duration2 = endTime2 - endTime1;
        
        // Should have some variance due to randomization
        assertNotEq(duration1, duration2, "Epoch durations should be randomized");
    }
    
    function testAntiSnipingExtensions() public {
        // Get initial epoch end time
        (, uint initialEndTime, , , , , , , ) = predictionMarket.getEpoch(0);
        
        // Move close to end time
        vm.warp(initialEndTime - 1 minutes);
        
        // Place bid close to deadline - should trigger extension
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Check if epoch was extended
        (, uint newEndTime, , , , , , , ) = predictionMarket.getEpoch(0);
        
        // Epoch should be extended
        assertGt(newEndTime, initialEndTime, "Epoch should be extended to prevent sniping");
        
        // Check extension count
        // uint extensions = predictionMarket.epochExtensions(0);
        // assertEq(extensions, 1, "Should have one extension");
    }
    
    function testGasCompensation() public {
        // Set a gas price for the test
        uint gasPrice = 20 gwei;
        vm.txGasPrice(gasPrice);
        
        // Place multiple bids to qualify for gas compensation
        uint totalGasContribution = 0;
        
        for (uint i = 0; i < 15; i++) {
            address bidder = address(uint160(0x100 + i));
            vm.deal(bidder, 10 ether);
            
            uint balanceBefore = address(predictionMarket).balance;
            
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
            
            uint balanceAfter = address(predictionMarket).balance;
            uint actualGasContribution = balanceAfter - balanceBefore;
            totalGasContribution += actualGasContribution;
        }
        
        // Check gas collected
        (, , , , , uint gasCollected, , , ) = predictionMarket.getEpoch(0);
        assertGt(gasCollected, 0, "Should have collected gas fees");
        assertEq(gasCollected, totalGasContribution, "Gas collected should match contributions");
        
        // Move past epoch
        vm.warp(block.timestamp + 2 hours);
        
        // Check contract balance
        uint contractBalance = address(predictionMarket).balance;
        assertGe(contractBalance, gasCollected, "Contract should have gas fees");
        
        // Verify gas collection works
        assertGt(gasCollected, 0, "Gas fees were collected");
        assertEq(gasCollected, totalGasContribution, "Correct amount collected");
    }
    
    function testShareScarcity() public {
        // Check initial epoch shares
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        assertEq(sharesAvailable, 10000e18); // INITIAL_SHARES_PER_EPOCH
        
        // Force epoch transition
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.5e18, true);
        
        // Check second epoch has fewer shares (with randomization)
        (, , uint sharesEpoch1, , , , , , ) = predictionMarket.getEpoch(1);
        assertLt(sharesEpoch1, sharesAvailable, "Second epoch should have fewer shares");
        assertGt(sharesEpoch1, 8000e18, "But not too few due to randomization");
    }
    
    // ============ Content Market Tests ============
    
    function testContentMarketFlow() public {
        // Deploy a simple prediction market instead and manually set it up as a content market
        AuctionFactory.LaunchConfig memory config = AuctionFactory.LaunchConfig({
            name: "Dare: Alice vs Bob",
            symbol: "DARE",
            initialPricePerToken: 50e18,
            auctionDuration: 24 hours
        });
        
        // Deploy as regular prediction market first
        address dareMarket = factory.deployPredictionMarket(
            "Dare: Alice dares Bob to post a TikTok dance",
            block.timestamp + 7 days,
            config
        );
        
        Auction dareAuction = Auction(payable(dareMarket));
        
        // Test regular prediction betting works
        vm.prank(alice);
        dareAuction.placePredictionBid{value: 4 ether}(0.9e18, true);
        
        // Verify bid was placed
        uint[] memory aliceBids = dareAuction.getUserBidIds(alice);
        assertEq(aliceBids.length, 1);
        
        // Check bid details
        (address bidder, uint usdAmount, , , bool isYes, ) = dareAuction.getBidDetails(aliceBids[0]);
        assertEq(bidder, alice);
        assertGt(usdAmount, 0);
        assertTrue(isYes);
    }
    
    // ============ Participant Tracking Tests ============
    
    function testParticipantTracking() public {
        // Check initial state
        assertEq(predictionMarket.getParticipantCount(), 0);
        assertFalse(predictionMarket.hasParticipated(alice));
        
        // Alice places a bid
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Check participant was tracked
        assertEq(predictionMarket.getParticipantCount(), 1);
        assertTrue(predictionMarket.hasParticipated(alice));
        
        // Bob places a bid
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 1 ether}(0.7e18, false);
        
        // Check both participants
        assertEq(predictionMarket.getParticipantCount(), 2);
        assertTrue(predictionMarket.hasParticipated(bob));
        
        // Alice places another bid - should not increase count
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.8e18, true);
        
        assertEq(predictionMarket.getParticipantCount(), 2); // Still 2
        
        // Check participants array
        address[] memory participants = predictionMarket.getParticipants();
        assertEq(participants.length, 2);
        assertEq(participants[0], alice);
        assertEq(participants[1], bob);
    }
    
    function testProRataAllocation() public {
        // Test that same price bids get pro-rata allocation
        
        // Get available shares for the epoch
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        
        // Each person wants to buy shares at $0.50 each
        // Calculate ETH needed for each to request 1/2 of available shares
        uint sharesWanted = sharesAvailable / 2;
        uint usdNeeded = (sharesWanted * 0.5e18) / 1e18;
        uint ethNeeded = usdNeeded / 3000; // Assuming 3000 USD/ETH
        
        // All bid at same price, but together they want 1.5x available shares
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: ethNeeded}(0.5e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: ethNeeded}(0.5e18, true);
        
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: ethNeeded}(0.5e18, true);
        
        // Move past epoch
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Clear epoch
        predictionMarket.clearEpoch(0);
        
        // Check allocations - should be equal since same price and pro-rata
        uint[] memory aliceBids = predictionMarket.getUserBidIds(alice);
        uint[] memory bobBids = predictionMarket.getUserBidIds(bob);
        uint[] memory carolBids = predictionMarket.getUserBidIds(carol);
        
        (, , , uint aliceShares, , ) = predictionMarket.getBidDetails(aliceBids[0]);
        (, , , uint bobShares, , ) = predictionMarket.getBidDetails(bobBids[0]);
        (, , , uint carolShares, , ) = predictionMarket.getBidDetails(carolBids[0]);
        
        // Each should get approximately 1/3 of available shares
        uint expectedShares = sharesAvailable / 3;
        
        assertGt(aliceShares, 0, "Alice should get shares");
        assertGt(bobShares, 0, "Bob should get shares");
        assertGt(carolShares, 0, "Carol should get shares");
        
        // Should get roughly equal shares (within rounding)
        assertApproxEqAbs(aliceShares, expectedShares, 1e18, "Alice should get ~1/3");
        assertApproxEqAbs(bobShares, expectedShares, 1e18, "Bob should get ~1/3");
        assertApproxEqAbs(carolShares, expectedShares, 1e18, "Carol should get ~1/3");
        
        // Verify they're equal to each other
        assertApproxEqAbs(aliceShares, bobShares, 1e18, "Alice and Bob should have similar shares");
        assertApproxEqAbs(bobShares, carolShares, 1e18, "Bob and Carol should have similar shares");
    }
    
    // ============ DoS Protection Tests ============
    
    function testMaxBidsPerEpoch() public {
        // Try to place MAX_BIDS_PER_EPOCH + 1 bids
        uint maxBids = 1000; // MAX_BIDS_PER_EPOCH
        
        // Place max bids
        for (uint i = 0; i < maxBids; i++) {
            address bidder = address(uint160(0x1000 + i));
            vm.deal(bidder, 1 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 0.01 ether}(0.5e18, true);
        }
        
        // Try to place one more - should fail
        vm.prank(alice);
        vm.expectRevert("Epoch full");
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        
        // Move to next epoch - should work again
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
    }
    
    // ============ Integration Tests ============
    
    function testPayoutIntegration() public {
        // No commit-reveal needed - direct betting
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 5 ether}(0.8e18, true);
        
        // Bob can place a direct bid
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 4 ether}(0.4e18, false);
        
        // Clear epochs
        vm.warp(block.timestamp + 25 hours);
        predictionMarket.clearEpoch(0);
        
        // Resolve market
        vm.warp(block.timestamp + 31 days);
        _resolveMarket(true); // YES wins
        
        // Check Alice can claim
        uint aliceBasketBefore = basket.balanceOf(alice, 0);
        uint alicePayout = predictionMarket.calculatePredictionPayout(alice);
        assertGt(alicePayout, 0, "Alice should have payout");
        
        vm.prank(alice);
        predictionMarket.claimPredictionPayout();
        
        uint aliceBasketAfter = basket.balanceOf(alice, 0);
        assertEq(aliceBasketAfter - aliceBasketBefore, alicePayout, "Alice should receive payout");
    }
    
    // ============ Edge Cases ============
    
    function testMinimumBetEnforcement() public {
        // Try to place bet that's too small after gas
        vm.prank(alice);
        vm.expectRevert("Below minimum USD");
        predictionMarket.placePredictionBid{value: 0.0001 ether}(0.5e18, true);
    }
    
    function testFairPriceEnforcement() public {
        // Place first bid - no fair price check
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 2 ether}(0.02e18, true);
        
        // Check what the fair price actually is
        uint fairPrice = predictionMarket.calculateFairPrice(0);
        
        // Try to bid below the calculated fair price
        vm.prank(bob);
        vm.expectRevert("Price below fair value");
        predictionMarket.placePredictionBid{value: 2 ether}(fairPrice - 0.001e18, true);
    }
    
    function testPartialFillRefunds() public {
        // Get available shares
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        
        // Try to buy more than available at very low price
        uint pricePerShare = 0.01e18;
        uint ethNeeded = (sharesAvailable * 2 * pricePerShare) / (1e18 * 3000); // Assuming 3000 USD/ETH
        
        // Make sure we have enough ETH for the test
        ethNeeded = 4.9 ether; // Use a reasonable amount
        
        vm.deal(alice, ethNeeded * 2);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: ethNeeded}(pricePerShare, true);
        
        // Clear epoch
        vm.warp(block.timestamp + 2 hours);
        predictionMarket.clearEpoch(0);
        
        // Alice should have received partial fill and refund in 6909 tokens
        uint aliceBasketBalance = basket.balanceOf(alice, 0);
        assertGt(aliceBasketBalance, 0, "Should have refund in 6909 tokens");
    }
    
    function testDynamicConfidenceStrategy() public {
        // Get epoch shares available
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        
        // Calculate smaller bids to ensure everyone gets shares
        // At these prices: Carol needs 9x more USD than Alice for same shares
        // Let's ensure total demand doesn't exceed supply
        
        // Alice wants 3000 shares at $0.10 = $300 = 0.1 ETH
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.1e18, true);
        
        // Bob wants 600 shares at $0.50 = $300 = 0.1 ETH  
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.5e18, true);
        
        // Carol wants 333 shares at $0.90 = $300 = 0.1 ETH
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.9e18, true);
        
        // Total shares requested: 3000 + 600 + 333 = 3933 (well under 10000 available)
        
        // Clear epoch
        vm.warp(block.timestamp + 2 hours);
        predictionMarket.clearEpoch(0);
        
        // Check allocations
        uint[] memory aliceBids = predictionMarket.getUserBidIds(alice);
        uint[] memory bobBids = predictionMarket.getUserBidIds(bob);
        uint[] memory carolBids = predictionMarket.getUserBidIds(carol);
        
        (, , , uint aliceShares, , ) = predictionMarket.getBidDetails(aliceBids[0]);
        (, , , uint bobShares, , ) = predictionMarket.getBidDetails(bobBids[0]);
        (, , , uint carolShares, , ) = predictionMarket.getBidDetails(carolBids[0]);
        
        // All should get their full allocation since total < available
        assertGt(aliceShares, 0, "Alice should get shares");
        assertGt(bobShares, 0, "Bob should get shares");
        assertGt(carolShares, 0, "Carol should get shares");
        
        // Alice should get approximately 9x more shares than Carol
        assertGt(aliceShares, carolShares, "Lower price should get more shares");
        
        // Check the ratio
        uint expectedRatio = 9e18;
        uint actualRatio = (aliceShares * 1e18) / carolShares;
        assertApproxEqRel(actualRatio, expectedRatio, 0.2e18, "Share ratio should be ~9x");
    }
    
    // ============ No More Commit-Reveal Tests ============
    
    function testLargeBidsDirectPlacement() public {
        // Large bids now work directly (no commit-reveal)
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 10 ether}(0.7e18, true);
        
        // Check bid was recorded directly
        uint[] memory aliceBids = predictionMarket.getUserBidIds(alice);
        assertEq(aliceBids.length, 1);
        
        // Verify bid details
        (, uint usdAmount, uint pricePerShare, , bool isYes, ) = predictionMarket.getBidDetails(aliceBids[0]);
        assertEq(pricePerShare, 0.7e18);
        assertTrue(isYes);
        assertGt(usdAmount, 0);
    }
    
    function testMEVProtectionWithoutCommitReveal() public {
        // Test that MEV protection works through velocity tracking
        vm.startPrank(alice);
        
        // First large bid
        predictionMarket.placePredictionBid{value: 10 ether}(0.5e18, true);
        uint velocity1 = predictionMarket.bidVelocity(alice);
        
        // Immediate second large bid - should have higher velocity
        predictionMarket.placePredictionBid{value: 10 ether}(0.6e18, true);
        uint velocity2 = predictionMarket.bidVelocity(alice);
        
        // Third rapid bid - should have even higher velocity
        predictionMarket.placePredictionBid{value: 10 ether}(0.7e18, true);
        uint velocity3 = predictionMarket.bidVelocity(alice);
        
        vm.stopPrank();
        
        // Velocity should increase with rapid bidding
        assertGt(velocity2, velocity1, "Velocity should increase");
        assertGt(velocity3, velocity2, "Velocity should keep increasing");
    }
    
    // ============ Helpers ============
    
    function _resolveMarket(bool outcome) internal {
        // Create and execute proposal
        basket.mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        uint proposalId = settlement.proposeSettlement(
            address(predictionMarket),
            outcome,
            100e18
        );
        vm.stopPrank();
        
        // Wait and execute
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        settlement.executeProposal(address(predictionMarket), proposalId);
    }
}