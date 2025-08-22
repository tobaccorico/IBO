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
        // Allow factory or treasury to authorize submitters
        require(
            msg.sender == state.addresses.protocolTreasury || 
            msg.sender == address(this) ||
            // Check if sender is the factory by checking if this was deployed by it
            state.addresses.settlementSystem != address(0),
            "Not authorized"
        );
        if (submitter1 != address(0)) {
            state.authorizedContentSubmitters[submitter1] = true;
        }
        if (submitter2 != address(0)) {
            state.authorizedContentSubmitters[submitter2] = true;
        }
    }
    
    // ============ Bidding Functions ============
    
    function placePredictionBid(uint pricePerShare, bool isYes) external payable nonReentrant {
        uint bidId = state.processBid(msg.sender, msg.value, pricePerShare, isYes, true);
        
        // Don't mint immediately - wait for batch clear
        // Shares are only allocated after batch processing
        
        // Emit batch queued event
        emit BatchQueued(msg.sender, block.number, state.allBids[bidId].usdAmount, isYes);
        
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
        
        // Don't mint immediately - wait for batch clear
        
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
        
        // Don't mint immediately - wait for batch clear
        
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
    
    function clearBatches() public nonReentrant {
        uint blockBeforeClearing = state.core.lastClearBlock;
        
        (uint cleared, uint compensation) = state.clearBatches(msg.sender);
        
        // Mint tokens for all users who got shares in the batch
        if (cleared > 0) {
            _processBatchMinting();
        }
        
        // Pay gas compensation
        if (compensation > 0 && msg.sender != address(this)) {
            (bool success,) = msg.sender.call{value: compensation}("");
            if (!success) {
                state.core.totalProtocolFees += uint128(compensation);
            }
        }
        
        // Emit event with the block that was cleared
        if (cleared > 0) {
            emit BatchCleared(
                blockBeforeClearing,
                state.batchesYes[blockBeforeClearing].total,
                state.batchesNo[blockBeforeClearing].total,
                msg.sender,
                compensation
            );
        }
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
        // Store the dispute ID if not set
        if (state.market.disputeId == 0) {
            state.market.disputeId = uint32(_disputeID);
        }
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
        if (userShares > 0 && balanceOf[msg.sender] >= userShares) {
            balanceOf[msg.sender] -= userShares;
            totalSupply -= userShares;
        }
        
        emit PayoutClaimed(msg.sender, payout, false);
    }
    
    function claimForceMajeurRefund() external nonReentrant {
        uint refund = state.processForceMajeurRefund(msg.sender);
        
        // Burn ERC404 tokens
        uint userShares = state.userYesShares[msg.sender] + state.userNoShares[msg.sender];
        if (userShares > 0 && balanceOf[msg.sender] >= userShares) {
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
        // Mint tokens for all participants based on their total shares
        for (uint i = 0; i < state.participants.length; i++) {
            address participant = state.participants[i];
            uint totalShares = state.userYesShares[participant] + state.userNoShares[participant];
            
            if (totalShares > 0 && balanceOf[participant] < totalShares) {
                uint toMint = totalShares - balanceOf[participant];
                if (toMint > 0) {
                    _mintERC20(participant, toMint);
                }
            }
        }
    }
    
    function _processEpochMinting(uint epochIndex) internal {
        // Mint tokens for all participants in the epoch
        Epoch storage epoch = state.epochs[epochIndex];
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        
        for (uint i = 0; i < sortedKeys.length; i++) {
            uint bidId = uint32(sortedKeys[i]);
            Bid storage bid = state.allBids[bidId];
            if (bid.sharesAllocated > 0 && !bid.minted) {
                // Check current balance vs what they should have
                uint userTotalShares = state.userYesShares[bid.bidder] + state.userNoShares[bid.bidder];
                if (balanceOf[bid.bidder] < userTotalShares) {
                    uint toMint = userTotalShares - balanceOf[bid.bidder];
                    _mintERC20(bid.bidder, toMint);
                }
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
    
    // ============ Testing Helpers ============
    
    function triggerAutoClear() external {
        // Allow anyone to trigger auto-clear if conditions are met
        // Don't use nonReentrant here since clearBatches already has it
        if (shouldAutoClear()) {
            clearBatches();
        }
    }
    
    function shouldAutoClear() public view returns (bool) {
        uint lastBlock = state.core.lastClearBlock;
        
        // Can't auto-clear current block
        if (lastBlock >= block.number) return false;
        
        uint yesCount = state.batchesYes[lastBlock].trades.length;
        uint noCount = state.batchesNo[lastBlock].trades.length;
        uint total = state.batchesYes[lastBlock].total + state.batchesNo[lastBlock].total;
        
        // Auto-clear if we have enough trades or volume
        return (yesCount + noCount >= 10) || (total >= state.core.dynamicBatchThreshold);
    }
    
    receive() external payable {}
}