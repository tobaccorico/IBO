// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Settlement} from "../src/Settlement.sol";
import {Auction} from "../src/Auction.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {Basket} from "../src/Basket.sol";
import {RandaoLib} from "../src/imports/RandaoLib.sol";
import {IArbitrator} from "../src/imports/IArbitrator.sol";
import {IArbitrable} from "../src/imports/IArbitrable.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SettlementTest is Test {
    Settlement public settlement;
    AuctionFactory public factory;
    Auction public market;
    Basket public basket;
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    
    uint public metaEvidenceId;
    
    // Mock block headers for testing RANDAO
    bytes mockHeader1 = hex"f90214a0b903239f63fba8c5c89f9fd7c9c6f6b6d8e8e7f4cd3a7dc8fa6c7ad7bda8c5a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347942a65aca4d5fc5b5c859090a6c34d164135398226a0c7e3b8e8f8e8d8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018347e7c4821388808455ba422380a00000000000000000000000000000000000000000000000000000000000000000880000000000000000";
    bytes mockHeader2 = hex"f90214a0c803239f63fba8c5c89f9fd7c9c6f6b6d8e8e7f4cd3a7dc8fa6c7ad7bda8c5a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347942a65aca4d5fc5b5c859090a6c34d164135398226a0d7e3b8e8f8e8d8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018347e7c4821389808455ba422380a00000000000000000000000000000000000000000000000000000000000000000880000000000000000";
    bytes mockHeader3 = hex"f90214a0d903239f63fba8c5c89f9fd7c9c6f6b6d8e8e7f4cd3a7dc8fa6c7ad7bda8c5a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347942a65aca4d5fc5b5c859090a6c34d164135398226a0e7e3b8e8f8e8d8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018347e7c482138a808455ba422380a00000000000000000000000000000000000000000000000000000000000000000880000000000000000";
    
    function setUp() public {
        // Deploy minimal mock infrastructure
        address mockRover = address(new MockRover());
        address mockAux = address(new MockAux());
        
        // Deploy Basket with minimal stables/vaults
        address[] memory stables = new address[](1);
        address[] memory vaults = new address[](1);
        stables[0] = address(new MockERC20("USDC", "USDC", 6));
        vaults[0] = address(new MockVault(stables[0]));
        
        basket = new Basket(mockRover, mockAux, stables, vaults);
        
        // Deploy Settlement fresh
        settlement = new Settlement();
        metaEvidenceId = settlement.createPredictionMarketMetaEvidence();
        
        // Deploy Factory
        factory = new AuctionFactory(
            address(settlement),
            mockRover,
            mockAux,
            address(basket)
        );
        
        // Initialize Settlement with factory
        settlement.initialize(address(basket), address(factory));
        
        // Deploy test market through factory - but first get ownership
        vm.startPrank(factory.owner());
        AuctionFactory.LaunchConfig memory config = AuctionFactory.LaunchConfig({
            name: "Test Market",
            symbol: "TEST",
            initialPricePerToken: 100e18,
            auctionDuration: 24 hours
        });
        
        address marketAddress = factory.deployPredictionMarket(
            "Will ETH hit $5000?",
            block.timestamp + 30 days,
            config
        );
        market = Auction(payable(marketAddress));
        vm.stopPrank();
        
        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        
        // Have users participate in market to get 6909 tokens for jury eligibility
        _setupJurorEligibility();
    }
    
    function _setupJurorEligibility() internal {
        // Mock participation to create eligible jurors
        // In reality, they would place bets through the auction
        
        // Need to properly setup basket to mint tokens
        // First give basket some allowance to itself (workaround for test)
        vm.startPrank(address(basket));
        MockERC20(basket.stables(0)).mint(address(basket), 10000e6); // 10k USDC
        vm.stopPrank();
        
        // Now mint 6909 tokens to potential jurors
        for (uint i = 0; i < 10; i++) {
            address user = address(uint160(0x100 + i));
            // Mint enough tokens to be eligible as juror (100e18 minimum)
            basket.mint(user, 200e18, address(basket), 0);
        }
    }
    
    // ============ Proposal Path Tests ============
    
    function testProposalLifecycle() public {
        vm.warp(block.timestamp + 31 days);
        
        // First, alice needs 6909 tokens to propose
        basket.mint(alice, 100e18, address(basket), 0);
        
        // Create proposal
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        uint proposalId = settlement.proposeSettlement(
            address(market),
            true,
            100e18
        );
        vm.stopPrank();
        
        // Support
        basket.mint(bob, 150e18, address(basket), 0);
        vm.startPrank(bob);
        basket.approve(address(settlement), 150e18);
        settlement.supportProposal(
            address(market),
            proposalId,
            150e18
        );
        vm.stopPrank();
        
        // Oppose
        basket.mint(carol, 100e18, address(basket), 0);
        vm.startPrank(carol);
        basket.approve(address(settlement), 100e18);
        settlement.opposeProposal(
            address(market),
            proposalId,
            100e18
        );
        vm.stopPrank();
        
        // Check support threshold (250 vs 100 = 2.5:1)
        vm.warp(block.timestamp + 4 days);
        
        // Execute
        vm.prank(alice);
        settlement.executeProposal(address(market), proposalId);
        
        // Verify resolution
        (, , bool resolved, bool outcome, , , , , , ) = market.getPredictionConfig();
        assertTrue(resolved);
        assertTrue(outcome);
    }
    
    function testProposalThresholdEnforcement() public {
        vm.warp(block.timestamp + 31 days);
        
        basket.mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        uint proposalId = settlement.proposeSettlement(
            address(market),
            true,
            100e18
        );
        vm.stopPrank();
        
        // Heavy opposition
        basket.mint(bob, 200e18, address(basket), 0);
        vm.startPrank(bob);
        basket.approve(address(settlement), 200e18);
        settlement.opposeProposal(
            address(market),
            proposalId,
            200e18
        );
        vm.stopPrank();
        
        vm.warp(block.timestamp + 4 days);
        
        // Should fail - only 0.5:1 ratio
        vm.prank(alice);
        vm.expectRevert("Cannot execute");
        settlement.executeProposal(address(market), proposalId);
    }
    
    function testProposalDispute() public {
        vm.warp(block.timestamp + 31 days);
        
        basket.mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        uint proposalId = settlement.proposeSettlement(
            address(market),
            true,
            100e18
        );
        vm.stopPrank();
        
        vm.warp(block.timestamp + 3 days + 1);
        
        // Dispute
        basket.mint(bob, 100e18, address(basket), 0);
        vm.startPrank(bob);
        basket.approve(address(settlement), 100e18);
        uint disputeId = settlement.disputeProposal(
            address(market),
            proposalId,
            "ipfs://evidence",
            "0xhash",
            100e18
        );
        vm.stopPrank();
        
        assertGt(disputeId, 0);
        
        // Proposal should now be blocked
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert("Not active");
        settlement.executeProposal(address(market), proposalId);
    }
    
    // ============ View Function Tests ============
    
    function testCanSettleStates() public {
        // Too early
        (bool can1, string memory reason1) = settlement.canSettle(address(market));
        assertFalse(can1);
        assertEq(reason1, "Resolution time not reached");
        
        // Ready for proposal
        vm.warp(block.timestamp + 31 days);
        (bool can2, string memory reason2) = settlement.canSettle(address(market));
        assertTrue(can2);
        assertEq(reason2, "Ready for new settlement proposal");
        
        // Active proposal
        basket.mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        settlement.proposeSettlement(address(market), true, 100e18);
        vm.stopPrank();
        
        (bool can3, string memory reason3) = settlement.canSettle(address(market));
        assertFalse(can3);
        assertEq(reason3, "Active proposal in voting period");
        
        // Execution delay
        vm.warp(block.timestamp + 3 days + 1);
        (bool can4, string memory reason4) = settlement.canSettle(address(market));
        assertFalse(can4);
        assertEq(reason4, "Proposal in execution delay period");
        
        // Ready to execute
        vm.warp(block.timestamp + 1 days);
        (bool can5, string memory reason5) = settlement.canSettle(address(market));
        assertTrue(can5);
        assertEq(reason5, "Proposal ready for execution");
    }
    
    // ============ Additional Tests ============
    
    function testCreateCustomMetaEvidence() public {
        uint customId = settlement.createMetaEvidence(
            "Custom Market",
            "Special rules",
            "Did X happen?",
            '[{"title":"No"},{"title":"Yes"}]',
            "ipfs://custom"
        );
        
        assertGt(customId, 0);
    }
    
    function testArbitrationCost() public {
        uint cost = settlement.arbitrationCost("");
        assertEq(cost, 100e18); // MIN_PROPOSAL_STAKE in 6909 tokens
    }
    
    function testClaimStakes() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create and execute proposal
        basket.mint(alice, 200e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 200e18);
        uint proposalId = settlement.proposeSettlement(
            address(market),
            true,
            200e18
        );
        vm.stopPrank();
        
        basket.mint(bob, 100e18, address(basket), 0);
        vm.startPrank(bob);
        basket.approve(address(settlement), 100e18);
        settlement.opposeProposal(address(market), proposalId, 100e18);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        settlement.executeProposal(address(market), proposalId);
        
        // Alice claims
        uint aliceBalanceBefore = basket.balanceOf(alice, 0);
        vm.prank(alice);
        settlement.claimStakes(address(market), proposalId);
        
        // Should get 200 + 100 = 300 tokens
        assertEq(basket.balanceOf(alice, 0) - aliceBalanceBefore, 300e18);
        
        // Can't claim twice
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        settlement.claimStakes(address(market), proposalId);
    }
    
    function _resolveMarket(bool outcome) internal {
        // Create and execute proposal
        basket.mint(alice, 100e18, address(basket), 0);
        vm.startPrank(alice);
        basket.approve(address(settlement), 100e18);
        uint proposalId = settlement.proposeSettlement(
            address(market),
            outcome,
            100e18
        );
        vm.stopPrank();
        
        // Wait and execute
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        settlement.executeProposal(address(market), proposalId);
    }
}

// ============ Mock Contracts ============

contract MockRover {
    // Minimal Rover mock - Auction doesn't interact with it directly
    receive() external payable {}
}

contract MockAux {
    // Mock Aux that handles swaps for Auction
    function swap(address token, bool zeroForOne, uint amount, uint waitable) 
        external payable returns (uint) {
        // Mock swap: return USD amount based on ETH sent
        // Assuming 1 ETH = 3000 USD for testing
        if (!zeroForOne) { // Selling ETH for USD
            return msg.value * 3000;
        }
        return amount;
    }
}

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