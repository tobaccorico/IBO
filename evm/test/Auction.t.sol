// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {Basket} from "../src/Basket.sol";
import {Aux} from "../src/Aux.sol";
import {Rover} from "../src/Rover.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract AuctionTest is Test {
    AuctionFactory public factory;
    Auction public predictionMarket;
    Settlement public settlement;
    Basket public basket;
    Aux public aux;
    Rover public rover;
    
    // Mock addresses for testing
    address public usdc;
    address public weth;
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    
    uint public metaEvidenceId;
    
    function setUp() public {
        // Deploy core infrastructure in correct order
        
        // 1. Deploy mock tokens
        usdc = address(new MockERC20("USDC", "USDC", 6));
        weth = address(new MockWETH());
        
        // 2. Deploy mock Uniswap V3 pool
        address mockV3Pool = address(new MockV3Pool(usdc, weth));
        
        // 3. Deploy mock pool manager for V4
        IPoolManager poolManager = IPoolManager(address(new MockPoolManager()));
        
        // 4. Deploy Rover (V4 router)
        rover = new Rover(poolManager);
        
        // 5. Deploy Aux with dependencies
        aux = new Aux(
            address(rover),
            mockV3Pool,
            address(0), // mock V3 router
            address(0), // mock WETH vault
            address(0), // mock AAVE
            address(0), // mock data provider
            address(0)  // mock address provider
        );
        
        // 6. Deploy Basket with stables/vaults
        address[] memory stables = new address[](1);
        address[] memory vaults = new address[](1);
        stables[0] = usdc;
        vaults[0] = address(new MockVault(usdc));
        
        basket = new Basket(address(rover), address(aux), stables, vaults);
        
        // 7. Setup Rover and Aux connection
        rover.setup{value: 1 wei}(address(basket), address(aux), mockV3Pool);
        aux.setQuid{value: 1 wei}(address(basket));
        
        // 8. Deploy Settlement
        settlement = new Settlement();
        metaEvidenceId = settlement.createPredictionMarketMetaEvidence();
        
        // 9. Deploy Factory
        factory = new AuctionFactory(
            address(settlement),
            address(rover),
            address(aux),
            address(basket)
        );
        
        // 10. Update Settlement with factory
        settlement.initialize(address(basket), address(factory));
        
        // 11. Deploy test prediction market
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
        
        // Fund Aux with USDC for swaps
        MockERC20(usdc).mint(address(aux), 10_000_000e6);
        
        // Add required methods to Aux for testing
        _setupAuxMethods();
    }
    
    function _setupAuxMethods() internal {
        // Mock the processPayout and refundExcess methods
        // In production, these would be part of Aux contract
    }
    
    // ============ Core Belgian Auction Tests ============
    
    function testPlacePredictionBid() public {
        // Alice bets YES at 60% confidence
        vm.startPrank(alice);
        
        // Approve WETH if needed
        if (weth != address(0)) {
            IERC20(weth).approve(address(aux), type(uint).max);
        }
        
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
    
    function testUSDFlowIntegration() public {
        // Place bet
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: 10 ether}(0.7e18, true);
        
        // USD should be in Basket, not Auction
        assertEq(IERC20(usdc).balanceOf(address(predictionMarket)), 0);
        assertGt(basket.totalSupply(), 0); // Basket should have minted shares
    }
    
    function testPayoutIntegration() public {
        // Setup: Place bets and resolve
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
        
        // Alice claims payout
        uint aliceBasketBefore = basket.totalBalances(alice);
        vm.prank(alice);
        predictionMarket.claimPredictionPayout();
        uint aliceBasketAfter = basket.totalBalances(alice);
        
        assertGt(aliceBasketAfter, aliceBasketBefore, "Alice should receive 6909 tokens");
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
        
        // Try to buy more than available
        uint pricePerShare = 0.01e18;
        uint ethNeeded = (sharesAvailable * 2 * pricePerShare) / 1e18;
        
        vm.deal(alice, ethNeeded * 2);
        vm.prank(alice);
        predictionMarket.placePredictionBid{value: ethNeeded}(pricePerShare, true);
        
        // Clear epoch
        vm.warp(block.timestamp + 2 hours);
        predictionMarket.clearEpoch(0);
        
        // Alice should have received partial fill and refund
        uint aliceBasketBalance = basket.totalBalances(alice);
        assertGt(aliceBasketBalance, 0, "Should have refund in 6909 tokens");
    }
    
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
    
    // ============ Helpers ============
    
    function _resolveMarket(bool outcome) internal {
        // Create and execute proposal
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(predictionMarket),
            outcome
        );
        
        // Wait and execute
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        settlement.executeProposal(address(predictionMarket), proposalId);
    }
}

// ============ Mock Contracts ============

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    string public name;
    string public symbol;
    uint8 public decimals;
    
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped ETH", "WETH", 18) {}
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}

contract MockV3Pool {
    address public token0;
    address public token1;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function slot0() external pure returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        // Mock price: 1 ETH = 3000 USDC
        sqrtPriceX96 = 2.73861e21; // sqrt(3000) * 2^96
        tick = 0;
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract MockPoolManager {
    function initialize(address, uint160) external pure returns (int24) {
        return 0;
    }
    
    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

contract MockVault {
    address public asset;
    
    constructor(address _asset) {
        asset = _asset;
    }
    
    function deposit(uint256 assets, address) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        return assets; // 1:1 for simplicity
    }
}