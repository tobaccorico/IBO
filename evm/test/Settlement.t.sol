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
        // Deploy mock infrastructure
        address mockRover = address(0x5);
        address mockAux = address(0x6);
        
        // Deploy Basket
        address[] memory stables = new address[](1);
        address[] memory vaults = new address[](1);
        stables[0] = address(new MockERC20("USDC", "USDC", 6));
        vaults[0] = address(new MockVault(stables[0]));
        
        basket = new Basket(mockRover, mockAux, stables, vaults);
        
        // Deploy Settlement
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
        
        // Deploy test market
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
        
        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        
        // Have users participate in market to get 6909 tokens
        _setupJurorEligibility();
    }
    
    function _setupJurorEligibility() internal {
        // Have multiple users bet to get 6909 tokens
        address[] memory users = new address[](10);
        for (uint i = 0; i < 10; i++) {
            users[i] = address(uint160(0x100 + i));
            vm.deal(users[i], 10 ether);
            
            // Place bet to get 6909 tokens
            vm.prank(users[i]);
            market.placePredictionBid{value: 2 ether}(0.5e18, i % 2 == 0);
        }
        
        // Clear epoch so they get their tokens
        vm.warp(block.timestamp + 2 hours);
        market.clearEpoch(0);
        
        // Now these users should have 6909 tokens and be eligible as jurors
    }
    
    // ============ Proposal Path Tests ============
    
    function testProposalLifecycle() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create proposal
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            true
        );
        
        // Support
        vm.prank(bob);
        settlement.supportProposal{value: 0.15 ether}(
            address(market),
            proposalId
        );
        
        // Oppose
        vm.prank(carol);
        settlement.opposeProposal{value: 0.1 ether}(
            address(market),
            proposalId
        );
        
        // Check support threshold (0.25 vs 0.1 = 2.5:1)
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
        
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            true
        );
        
        // Heavy opposition
        vm.prank(bob);
        settlement.opposeProposal{value: 0.2 ether}(
            address(market),
            proposalId
        );
        
        vm.warp(block.timestamp + 4 days);
        
        // Should fail - only 0.5:1 ratio
        vm.prank(alice);
        vm.expectRevert("Insufficient support");
        settlement.executeProposal(address(market), proposalId);
    }
    
    function testProposalDispute() public {
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            true
        );
        
        vm.warp(block.timestamp + 3 days + 1);
        
        // Dispute
        vm.prank(bob);
        uint disputeId = settlement.disputeProposal{value: 0.1 ether}(
            address(market),
            proposalId,
            "ipfs://evidence",
            "0xhash"
        );
        
        assertGt(disputeId, 0);
        
        // Proposal should now be blocked
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert("Under dispute");
        settlement.executeProposal(address(market), proposalId);
    }
    
    // ============ Jury System Tests ============

    function testJurySelection() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create dispute via proposal
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            false
        );
        
        vm.warp(block.timestamp + 3 days + 1);
        
        vm.prank(bob);
        uint disputeId = settlement.disputeProposal{value: 0.1 ether}(
            address(market),
            proposalId,
            "ipfs://evidence",
            "0xhash"
        );
        
        // Wait for evidence period
        vm.warp(block.timestamp + 2 days + 1);
        
        // Request jury
        vm.prank(alice);
        settlement.requestJurySelection(disputeId);
        
        // Get the random blocks
        uint[3] memory blocks;
        blocks[0] = settlement.disputeRandomBlocks(disputeId, 0);
        blocks[1] = settlement.disputeRandomBlocks(disputeId, 1);
        blocks[2] = settlement.disputeRandomBlocks(disputeId, 2);
        
        // Fast forward past all 3 blocks
        vm.roll(block.number + 6);
        
        // Mock fulfillment would happen here with proper headers
        // In real test, oracle would provide the headers
    }
    
    function testJurorSlashing() public {
        // This would test the slashing mechanism
        // Setup: Create dispute, have jury vote, finalize with different verdict
        // Check that wrong voters get 10% of their 6909 slashed
    }
    
    // ============ IArbitrator Tests ============
    
    function testCreateDisputeViaArbitrator() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create dispute through IArbitrator interface
        vm.prank(address(market));
        uint disputeId = settlement.createDispute{value: 0.1 ether}(
            2, // binary choice
            abi.encode(address(market))
        );
        
        assertGt(disputeId, 0);
        
        // Check dispute was created
        IArbitrator.DisputeStatus status = settlement.disputeStatus(disputeId);
        assertTrue(status == IArbitrator.DisputeStatus.Waiting);
    }
    
    function testArbitrationCost() public {
        uint cost = settlement.arbitrationCost("");
        assertEq(cost, 0.1 ether); // MIN_PROPOSAL_STAKE
    }
    
    function testAppealFlow() public {
        // Would test the appeal mechanism with increasing costs
    }
    
    // ============ Evidence Tests ============
    
    function testSubmitEvidence() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create dispute
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            false
        );
        
        vm.warp(block.timestamp + 3 days + 1);
        
        vm.prank(bob);
        uint disputeId = settlement.disputeProposal{value: 0.1 ether}(
            address(market),
            proposalId,
            "ipfs://initial-evidence",
            "0xhash"
        );
        
        // Submit additional evidence
        vm.prank(carol);
        settlement.submitEvidence(disputeId, "ipfs://additional-evidence");
        
        // Evidence should be stored (we can't directly check but event should be emitted)
    }
    
    // ============ Timeout Tests ============
    
    function testActivityTimeout() public {
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            true
        );
        
        // Abandon for 7+ days
        vm.warp(block.timestamp + 8 days);
        
        (bool canSettle, string memory reason) = settlement.canSettle(address(market));
        assertTrue(canSettle);
    }
    
    function testAbsoluteTimeout() public {
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(alice);
        settlement.proposeSettlement{value: 0.1 ether}(
            address(market),
            true
        );
        
        // Wait 30+ days
        vm.warp(block.timestamp + 31 days);
        
        (bool canSettle, ) = settlement.canSettle(address(market));
        assertTrue(canSettle);
    }
    
    // ============ Meta-Evidence Tests ============
    
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
        vm.prank(alice);
        settlement.proposeSettlement{value: 0.1 ether}(address(market), true);
        
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
    
    // ============ Stake Distribution Tests ============
    
    function testClaimStakes() public {
        vm.warp(block.timestamp + 31 days);
        
        // Create and execute proposal
        vm.prank(alice);
        uint proposalId = settlement.proposeSettlement{value: 0.2 ether}(
            address(market),
            true
        );
        
        vm.prank(bob);
        settlement.opposeProposal{value: 0.1 ether}(address(market), proposalId);
        
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        settlement.executeProposal(address(market), proposalId);
        
        // Alice claims
        uint aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        settlement.claimStakes(address(market), proposalId);
        
        // Should get 0.2 + 0.1 = 0.3 ETH
        assertEq(alice.balance - aliceBalanceBefore, 0.3 ether);
        
        // Can't claim twice
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        settlement.claimStakes(address(market), proposalId);
    }
}

// Mock contracts
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