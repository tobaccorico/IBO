// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {Basket} from "../src/Basket.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

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
        
        // Deploy Factory (Rover address can be zero since Auction doesn't use it)
        factory = new AuctionFactory(
            address(settlement),
            address(0), // Rover not needed by Auction
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
    
    // ============ Core Belgian Auction Tests ============
    
    function testPlacePredictionBid() public {
        // Alice bets YES at 60% confidence
        vm.startPrank(alice);
        predictionMarket.placePredictionBid{value: 10 ether}(0.6e18, true);
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
    
    function testBelgianPricePriority() public {
        // Place bids at different confidence levels
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 5 ether}(0.3e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 5 ether}(0.8e18, true);
        
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 5 ether}(0.5e18, true);
        
        // Move past epoch
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Clear epoch
        predictionMarket.clearEpoch(0);
        
        // Check allocations - Bob should get shares first (highest price)
        uint[] memory bobBids = predictionMarket.getUserBidIds(bob);
        (, , , uint bobShares, , ) = predictionMarket.getBidDetails(bobBids[0]);
        assertGt(bobShares, 0, "Bob should get shares");
    }
    
    function testGasCompensation() public {
        // Place multiple bids to qualify for gas compensation
        for (uint i = 0; i < 15; i++) {
            address bidder = address(uint160(0x100 + i));
            vm.deal(bidder, 10 ether);
            vm.prank(bidder);
            predictionMarket.placePredictionBid{value: 1 ether}(0.5e18, true);
        }
        
        // Check gas collected
        (, , , , , uint gasCollected, , , ) = predictionMarket.getEpoch(0);
        assertGt(gasCollected, 0, "Should have collected gas fees");
        
        // Move past epoch
        vm.warp(block.timestamp + 2 hours);
        
        // Track clearer balance
        uint clearerBalanceBefore = carol.balance;
        
        // Clear epoch
        vm.prank(carol);
        predictionMarket.clearEpoch(0);
        
        // Check compensation
        uint clearerBalanceAfter = carol.balance;
        assertGt(clearerBalanceAfter, clearerBalanceBefore, "Clearer should be compensated");
    }
    
    function testShareScarcity() public {
        // Check initial epoch shares
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        assertEq(sharesAvailable, 10000e18); // INITIAL_SHARES_PER_EPOCH
        
        // Force epoch transition
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 0.1 ether}(0.5e18, true);
        
        // Check second epoch has fewer shares
        (, , uint sharesEpoch1, , , , , , ) = predictionMarket.getEpoch(1);
        assertEq(sharesEpoch1, 9000e18); // 10% decay
    }
    
    // ============ Content Market Tests ============
    
    function testContentMarketFlow() public {
        // Deploy content market
        address rapBattle = factory.deployRapBattleMarket(
            "Drake",
            "Kendrick",
            block.timestamp + 2 days,
            AuctionFactory.LaunchConfig({
                name: "RAP: Drake vs Kendrick",
                symbol: "RAP",
                initialPricePerToken: 50e18,
                auctionDuration: 24 hours
            })
        );
        
        Auction rapAuction = Auction(payable(rapBattle));
        
        // Set alice as authorized submitter
        vm.prank(factory.owner());
        rapAuction.setAuthorizedSubmitters(alice, bob);
        
        // Submit content and bet
        vm.prank(alice);
        rapAuction.placePredictionBidWithContent{value: 5 ether}(
            0.9e18,
            true,
            "ipfs://drake-track"
        );
        
        // Check content stored
        (address[] memory submitters, ) = rapAuction.getContentSubmissions();
        assertEq(submitters.length, 1);
        assertEq(submitters[0], alice);
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
        // Setup: Place bets
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 10 ether}(0.8e18, true);
        
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 20 ether}(0.4e18, false);
        
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
        vm.expectRevert("Too small after gas");
        predictionMarket.placePredictionBid{value: 0.0001 ether}(0.5e18, true);
    }
    
    function testPartialFillRefunds() public {
        // Get available shares
        (, , uint sharesAvailable, , , , , , ) = predictionMarket.getEpoch(0);
        
        // Try to buy more than available at very low price
        uint pricePerShare = 0.01e18;
        uint ethNeeded = (sharesAvailable * 2 * pricePerShare) / (1e18 * 3000); // Assuming 3000 USD/ETH
        
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
        // Test that shows why different confidence levels matter
        
        // Early bird gets good price
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 10 ether}(0.1e18, true); // 10% confidence
        
        // Medium confidence
        vm.prank(bob);
        predictionMarket.placePredictionBid{value: 10 ether}(0.5e18, true); // 50% confidence
        
        // High confidence (will get shares first)
        vm.prank(carol);
        predictionMarket.placePredictionBid{value: 10 ether}(0.9e18, true); // 90% confidence
        
        // Clear epoch
        vm.warp(block.timestamp + 2 hours);
        predictionMarket.clearEpoch(0);
        
        // Check share allocations - Carol gets first priority
        uint[] memory carolBids = predictionMarket.getUserBidIds(carol);
        uint[] memory aliceBids = predictionMarket.getUserBidIds(alice);
        
        (, , , uint carolShares, , ) = predictionMarket.getBidDetails(carolBids[0]);
        (, , , uint aliceShares, , ) = predictionMarket.getBidDetails(aliceBids[0]);
        
        // Carol gets fewer shares (paid more per share)
        // Alice gets more shares (paid less per share)
        assertGt(aliceShares, carolShares, "Low confidence should get more shares");
        
        // Resolve market as YES
        vm.warp(block.timestamp + 31 days);
        _resolveMarket(true);
        
        // Calculate returns - Alice should have higher return despite same bet amount
        uint alicePayout = predictionMarket.calculatePredictionPayout(alice);
        uint carolPayout = predictionMarket.calculatePredictionPayout(carol);
        
        // Return = (Payout / Paid) - 1
        uint aliceReturn = (alicePayout * 100) / (10 ether * 3000); // Assuming 3000 USD/ETH
        uint carolReturn = (carolPayout * 100) / (10 ether * 3000);
        
        assertGt(aliceReturn, carolReturn, "Lower confidence entry should yield higher return");
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

// ============ Mock Contracts ============

contract MockAux {
    // Mock Aux that handles ETH->USD swaps for Auction
    function swap(address token, bool zeroForOne, uint amount, uint waitable) 
        external payable returns (uint) {
        // Mock swap: return USD amount based on ETH sent
        // Assuming 1 ETH = 3000 USD for testing
        if (!zeroForOne) { // Selling ETH for USD
            // Account for gas fee (0.5%)
            uint gasContribution = (msg.value * 50) / 10000;
            uint actualETH = msg.value - gasContribution;
            return actualETH * 3000; // Return USD amount
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