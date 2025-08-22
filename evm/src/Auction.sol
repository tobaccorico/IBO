// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/ERC404.sol";
import "./imports/IArbitrable.sol";
import "./imports/IArbitrator.sol";
import "./imports/SortedSet.sol";
import "./AuctionStorage.sol";
import "./AuctionLogic.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Auction
 * @notice Main auction contract - implementation for proxy pattern
 * @dev Delegates heavy logic to AuctionLogic library to reduce bytecode
 */
contract Auction is ERC404, ReentrancyGuard, IArbitrable, AuctionStorage {
    using AuctionLogic for State;
    using SortedSetLib for SortedSetLib.Set;
    
    // Events
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event BatchQueued(address indexed bidder, uint blockNumber, uint amount, bool isYes);
    event BatchCleared(uint indexed blockNumber, uint totalYes, uint totalNo, address clearer, uint compensation);
    event MarketDepthUpdated(uint newDepth, uint batchThreshold);
    event EpochAdvanced(uint indexed newEpoch);
    event EpochExtended(uint indexed epoch, uint newEndTime);
    event PredictionResolved(bool outcome);
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    event ParticipantAdded(address indexed participant);
    
    constructor() ERC404("", "", 18) {
        units = 1e18;
    }
    
    // ============ Initialization ============
    
    function initialize(AuctionLogic.InitParams calldata params) external {
        require(!state.core.initialized, "Already initialized");
        state.initialize(params);
        
        // Set ERC404 properties
        name = params.name;
        symbol = params.symbol;
    }
    
    function initializePredictionMarket(
        string calldata _question,
        uint _resolutionTime,
        uint _metaEvidenceId,
        bool _requiresContent,
        uint _contentDeadline,
        uint _minParticipants
    ) external {
        state.initializeMarket(
            _question,
            _resolutionTime,
            _metaEvidenceId,
            _requiresContent,
            _contentDeadline,
            _minParticipants
        );
    }
    
    function setAuthorizedSubmitters(address submitter1, address submitter2) external {
        require(msg.sender == state.addresses.protocolTreasury, "Not authorized");
        state.authorizedContentSubmitters[submitter1] = true;
        state.authorizedContentSubmitters[submitter2] = true;
    }
    
    // ============ Bidding Functions ============
    
    function placePredictionBid(uint pricePerShare, bool isYes) external payable nonReentrant {
        uint bidId = state.processBid(msg.sender, msg.value, pricePerShare, isYes, true);
        
        // Mint ERC404 tokens for allocated shares
        uint sharesAllocated = state.allBids[bidId].sharesAllocated;
        if (sharesAllocated > 0) {
            _mintERC20(msg.sender, sharesAllocated);
        }
        
        emit BidPlaced(
            msg.sender,
            state.allBids[bidId].usdAmount,
            state.allBids[bidId].pricePerShare,
            isYes,
            state.core.currentEpochIndex,
            bidId
        );
    }
    
    function placePredictionBidWithToken(
        uint pricePerShare,
        bool isYes,
        address token,
        uint amount
    ) external nonReentrant {
        // Deposit token and get USD value
        uint usdAmount = AuctionLogic.depositToken(
            state.addresses.basket,
            msg.sender,
            token,
            amount
        );
        
        uint bidId = state.processBid(msg.sender, usdAmount, pricePerShare, isYes, false);
        
        // Mint ERC404 tokens
        uint sharesAllocated = state.allBids[bidId].sharesAllocated;
        if (sharesAllocated > 0) {
            _mintERC20(msg.sender, sharesAllocated);
        }
        
        emit BidPlaced(
            msg.sender,
            state.allBids[bidId].usdAmount,
            state.allBids[bidId].pricePerShare,
            isYes,
            state.core.currentEpochIndex,
            bidId
        );
    }
    
    function placePredictionBidWithContent(
        uint pricePerShare,
        bool isYes,
        string calldata contentURI
    ) external payable nonReentrant {
        require(state.market.requiresContent, "Content not required");
        require(state.authorizedContentSubmitters[msg.sender], "Not authorized");
        require(block.timestamp <= state.market.contentDeadline, "Content deadline passed");
        require(state.market.contentSubmissionCount < 2, "Max content reached");
        
        state.market.contentSubmissionCount++;
        
        uint bidId = state.processBid(msg.sender, msg.value, pricePerShare, isYes, true);
        
        // Mint ERC404 tokens
        uint sharesAllocated = state.allBids[bidId].sharesAllocated;
        if (sharesAllocated > 0) {
            _mintERC20(msg.sender, sharesAllocated);
        }
        
        emit BidPlaced(
            msg.sender,
            state.allBids[bidId].usdAmount,
            state.allBids[bidId].pricePerShare,
            isYes,
            state.core.currentEpochIndex,
            bidId
        );
    }
    
    // ============ Batch Processing ============
    
    function clearBatches() external nonReentrant {
        (uint cleared, uint compensation) = state.clearBatches(msg.sender);
        
        // Mint tokens for cleared batches
        _processBatchMinting();
        
        // Pay gas compensation
        if (compensation > 0 && msg.sender != address(this)) {
            (bool success,) = msg.sender.call{value: compensation}("");
            if (!success) {
                state.core.totalProtocolFees += uint128(compensation);
            }
        }
        
        emit BatchCleared(
            state.core.lastClearBlock - 1,
            state.batchesYes[state.core.lastClearBlock - 1].total,
            state.batchesNo[state.core.lastClearBlock - 1].total,
            msg.sender,
            compensation
        );
    }
    
    function clearEpoch(uint epochIndex) external nonReentrant {
        (uint yesAllocated, uint noAllocated) = state.clearEpoch(epochIndex);
        
        // Mint tokens for epoch allocations
        _processEpochMinting(epochIndex);
        
        emit EpochAdvanced(epochIndex);
    }
    
    // ============ Settlement Interface ============
    
    function rule(uint _disputeID, uint _ruling) external override {
        require(msg.sender == state.addresses.settlementSystem, "Only settlement");
        require(_disputeID == state.market.disputeId, "Wrong dispute");
        
        if (_ruling == 0) {
            state.market.resolved = true;
            state.market.outcome = false;
        } else if (_ruling == 1) {
            state.market.resolved = true;
            state.market.outcome = true;
        } else if (_ruling == 2) {
            state.market.forceMajeurRefunds = true;
        }
        
        emit PredictionResolved(state.market.outcome);
        emit Ruling(IArbitrator(state.addresses.settlementSystem), _disputeID, _ruling);
    }
    
    // ============ Claim Functions ============
    
    function calculatePredictionPayout(address user) external view returns (uint) {
        return state.calculatePayout(user);
    }
    
    function claimPredictionPayout() external nonReentrant {
        uint payout = state.processClaim(msg.sender);
        
        // Burn ERC404 tokens
        uint userShares = state.userYesShares[msg.sender] + state.userNoShares[msg.sender];
        if (userShares > 0) {
            balanceOf[msg.sender] -= userShares;
            totalSupply -= userShares;
        }
        
        emit PayoutClaimed(msg.sender, payout, false);
    }
    
    function claimForceMajeurRefund() external nonReentrant {
        uint refund = state.processForceMajeurRefund(msg.sender);
        
        // Burn ERC404 tokens
        uint userShares = state.userYesShares[msg.sender] + state.userNoShares[msg.sender];
        if (userShares > 0) {
            balanceOf[msg.sender] -= userShares;
            totalSupply -= userShares;
        }
        
        emit PayoutClaimed(msg.sender, refund, true);
    }
    
    // ============ View Functions ============
    
    function getCurrentEpochInfo() external view returns (uint, uint, uint, uint, bool) {
        return state.getCurrentEpochInfo();
    }
    
    function getMarketMetrics() external view returns (uint, uint, uint, uint, uint) {
        return state.getMarketMetrics();
    }
    
    function getUserPosition(address user) external view returns (uint, uint, uint, uint) {
        uint estimatedPayout = state.market.resolved ? state.calculatePayout(user) : 0;
        return (
            state.userYesShares[user],
            state.userNoShares[user],
            balanceOf[user],
            estimatedPayout
        );
    }
    
    function getPredictionSummary() external view returns (
        string memory,
        uint,
        uint,
        uint,
        uint,
        bool,
        bool
    ) {
        return state.getPredictionSummary();
    }
    
    function getBatchInfo(uint blockNumber) external view returns (uint, uint, uint, uint) {
        return (
            state.batchesYes[blockNumber].total,
            state.batchesNo[blockNumber].total,
            state.batchesYes[blockNumber].trades.length,
            state.batchesNo[blockNumber].trades.length
        );
    }
    
    // Getters for external contracts
    function bettingWindowClosed() external view returns (bool) {
        return state.core.bettingWindowClosed;
    }
    
    function resolved() external view returns (bool) {
        return state.market.resolved;
    }
    
    function outcome() external view returns (bool) {
        return state.market.outcome;
    }
    
    function forceMajeurRefunds() external view returns (bool) {
        return state.market.forceMajeurRefunds;
    }
    
    function resolutionTime() external view returns (uint) {
        return state.market.resolutionTime;
    }
    
    function currentEpochIndex() external view returns (uint) {
        return state.core.currentEpochIndex;
    }
    
    function lastClearBlock() external view returns (uint) {
        return state.core.lastClearBlock;
    }
    
    // ============ Internal Helpers ============
    
    function _processBatchMinting() internal {
        // Implementation would mint tokens based on batch results
        // This is simplified - actual implementation would track allocations
    }
    
    function _processEpochMinting(uint epochIndex) internal {
        // Mint tokens for all participants in the epoch
        Epoch storage epoch = state.epochs[epochIndex];
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        
        for (uint i = 0; i < sortedKeys.length; i++) {
            uint bidId = uint32(sortedKeys[i]);
            Bid storage bid = state.allBids[bidId];
            if (bid.sharesAllocated > 0 && !bid.minted) {
                _mintERC20(bid.bidder, bid.sharesAllocated);
                bid.minted = true;
            }
        }
    }
    
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
    
    function withdrawProtocolFees() external {
        require(msg.sender == state.addresses.protocolTreasury, "Not authorized");
        uint amount = state.core.totalProtocolFees;
        state.core.totalProtocolFees = 0;
        (bool success,) = state.addresses.protocolTreasury.call{value: amount}("");
        require(success, "Transfer failed");
    }
    
    receive() external payable {}
}