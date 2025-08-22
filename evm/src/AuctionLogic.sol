// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AuctionStorage.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title AuctionLogic
 * @notice Logic library for Auction contracts
 * @dev All heavy computation moved here to reduce main contract bytecode
 */
library AuctionLogic {
    using Math for uint;
    using SortedSetLib for SortedSetLib.Set;
    
    // Constants
    uint internal constant MIN_BET_USD = 100e18;
    uint internal constant BASE_FEE_BPS = 50;
    uint internal constant INITIAL_SHARES_PER_EPOCH = 10000e18;
    uint internal constant SHARES_DECAY_RATE = 10;
    uint internal constant CLEAR_GAS_PER_BID = 30000;
    uint internal constant EXTENSION_THRESHOLD = 2 minutes;
    uint internal constant EXTENSION_DURATION = 5 minutes;
    uint internal constant MAX_EXTENSIONS = 3;
    uint internal constant MAX_BATCH_SIZE = 50;
    
    struct InitParams {
        string name;
        string symbol;
        uint32 auctionDuration;
        uint32 totalEpochs;
        address owner;
        address settlementSystem;
        address rover;
        address aux;
        address basket;
    }
    
    // ============ Initialization ============
    
    function initialize(
        AuctionStorage.State storage state,
        InitParams calldata params
    ) external {
        state.core.initialized = true;
        state.core.nextBidId = 1;
        state.core.dynamicBatchThreshold = 1000e18;
        
        state.params.name = params.name;
        state.params.symbol = params.symbol;
        state.params.auctionDuration = params.auctionDuration;
        state.params.totalEpochs = params.totalEpochs;
        
        state.addresses.settlementSystem = params.settlementSystem;
        state.addresses.auxSystem = params.aux;
        state.addresses.protocolTreasury = params.owner;
        state.addresses.rover = params.rover;
        state.addresses.basket = params.basket;
        
        // Initialize first epoch
        initializeEpoch(state.epochs[0], 0);
    }
    
    function initializeMarket(
        AuctionStorage.State storage state,
        string calldata question,
        uint resolutionTime,
        uint metaEvidenceId,
        bool requiresContent,
        uint contentDeadline,
        uint minParticipants
    ) external {
        require(!state.market.marketInitialized, "Already initialized");
        state.market.marketInitialized = true;
        state.market.question = question;
        state.market.resolutionTime = resolutionTime;
        state.market.metaEvidenceId = uint32(metaEvidenceId);
        state.market.requiresContent = requiresContent;
        state.market.contentDeadline = contentDeadline;
        state.market.minParticipants = uint32(minParticipants);
    }
    
    // ============ Bidding Logic ============
    
    function processBid(
        AuctionStorage.State storage state,
        address bidder,
        uint amount,
        uint pricePerShare,
        bool isYes,
        bool isETH
    ) external returns (uint bidId) {
        require(!state.core.bettingWindowClosed && !state.market.resolved, "Closed");
        
        // Normalize price to tier
        pricePerShare = normalizePriceToTier(pricePerShare);
        
        // Calculate fee
        uint fee = (amount * BASE_FEE_BPS) / 10000;
        uint netAmount = amount - fee;
        state.core.totalProtocolFees += uint128(fee);
        
        // Convert to USD
        uint usdAmount;
        if (isETH) {
            usdAmount = netAmount * 3000; // Mock conversion
        } else {
            usdAmount = netAmount;
        }
        
        require(usdAmount >= MIN_BET_USD, "Below minimum");
        
        // Track participant
        if (!state.hasParticipated[bidder]) {
            state.hasParticipated[bidder] = true;
            state.participants.push(bidder);
            state.core.participantCount++;
        }
        
        // Update market depth
        state.core.totalMarketDepth += uint128(usdAmount);
        state.core.dynamicBatchThreshold = uint128(calculateBatchThreshold(state.core.totalMarketDepth));
        
        // Create bid
        bidId = state.core.nextBidId++;
        state.allBids[bidId] = AuctionStorage.Bid({
            bidder: bidder,
            usdAmount: usdAmount,
            pricePerShare: pricePerShare,
            sharesRequested: (usdAmount * 1e18) / pricePerShare,
            sharesAllocated: 0,
            epochIndex: state.core.currentEpochIndex,
            timestamp: block.timestamp,
            isYes: isYes,
            processed: false,
            minted: false
        });
        
        state.userBidIds[bidder].push(bidId);
        
        // Add to epoch
        AuctionStorage.Epoch storage epoch = state.epochs[state.core.currentEpochIndex];
        epoch.totalBids++;
        epoch.totalGasCollected += fee;
        
        uint sortKey = (type(uint).max - pricePerShare) << 32 | bidId;
        epoch.sortedBidIds.insert(sortKey);
        
        // Queue to batch
        queueBidToBatch(
            isYes ? state.batchesYes : state.batchesNo,
            bidder,
            usdAmount,
            pricePerShare,
            block.number
        );
        
        // Check epoch progression
        checkAndProgressEpoch(state);
        
        // Auto-clear if threshold met
        if (shouldAutoClear(state)) {
            clearBatches(state, address(this));
        }
    }
    
    // ============ Batch Processing (REFACTORED) ============
    
    function clearBatches(
        AuctionStorage.State storage state,
        address clearer
    ) public returns (uint cleared, uint compensation) {
        uint blockToClear = state.core.lastClearBlock;
        if (blockToClear >= block.number) return (0, 0);
        
        // Process YES batch
        if (state.batchesYes[blockToClear].trades.length > 0) {
            cleared += _processBatchType(state, blockToClear, true);
        }
        
        // Process NO batch  
        if (state.batchesNo[blockToClear].trades.length > 0) {
            cleared += _processBatchType(state, blockToClear, false);
        }
        
        state.core.lastClearBlock = uint32(block.number);
        
        // Calculate compensation separately to reduce stack
        if (clearer != address(this) && cleared > 0) {
            compensation = _calculateCompensation(cleared, state.core.totalProtocolFees);
            if (compensation > 0) {
                state.core.totalProtocolFees -= uint128(compensation);
                state.core.totalGasCompensation += uint128(compensation);
            }
        }
    }
    
    function _processBatchType(
        AuctionStorage.State storage state,
        uint blockToClear,
        bool isYes
    ) internal returns (uint processed) {
        AuctionStorage.Batch storage batch = isYes ? 
            state.batchesYes[blockToClear] : 
            state.batchesNo[blockToClear];
            
        processed = _processSingleBatch(
            state,
            batch,
            isYes,
            state.core.currentEpochIndex
        );
        
        // Clear batch after processing
        delete batch.trades;
        batch.total = 0;
    }
    
    function _processSingleBatch(
        AuctionStorage.State storage state,
        AuctionStorage.Batch storage batch,
        bool isYes,
        uint epochIndex
    ) internal returns (uint processed) {
        uint remaining = _getRemainingShares(state.epochs[epochIndex]);
        if (remaining == 0) return 0;
        
        uint length = batch.trades.length;
        if (length == 0) return 0;
        
        // Sort batch by price (simplified bubble sort)
        _sortBatch(batch, length);
        
        // Process allocations
        processed = _allocateShares(
            state,
            batch,
            isYes,
            remaining,
            epochIndex
        );
    }
    
    function _getRemainingShares(AuctionStorage.Epoch storage epoch) internal view returns (uint) {
        return epoch.sharesAvailable > epoch.sharesAllocated ? 
               epoch.sharesAvailable - epoch.sharesAllocated : 0;
    }
    
    function _sortBatch(AuctionStorage.Batch storage batch, uint length) internal {
        for (uint i = 0; i < length - 1; i++) {
            for (uint j = 0; j < length - i - 1; j++) {
                if (batch.trades[j].pricePerShare < batch.trades[j + 1].pricePerShare) {
                    AuctionStorage.Trade memory temp = batch.trades[j];
                    batch.trades[j] = batch.trades[j + 1];
                    batch.trades[j + 1] = temp;
                }
            }
        }
    }
    
    function _allocateShares(
        AuctionStorage.State storage state,
        AuctionStorage.Batch storage batch,
        bool isYes,
        uint remaining,
        uint epochIndex
    ) internal returns (uint processed) {
        uint length = batch.trades.length;
        
        for (uint i = 0; i < length && remaining > 0; i++) {
            remaining = _processTrade(
                state,
                batch.trades[i],
                isYes,
                remaining,
                epochIndex
            );
            processed++;
        }
    }
    
    function _processTrade(
        AuctionStorage.State storage state,
        AuctionStorage.Trade memory trade,
        bool isYes,
        uint remaining,
        uint epochIndex
    ) internal returns (uint newRemaining) {
        uint sharesRequested = (trade.amount * 1e18) / trade.pricePerShare;
        uint sharesAllocated = Math.min(sharesRequested, remaining);
        
        if (sharesAllocated > 0) {
            // Update user shares
            if (isYes) {
                state.userYesShares[trade.sender] += uint128(sharesAllocated);
                state.market.totalYesShares += uint128(sharesAllocated);
            } else {
                state.userNoShares[trade.sender] += uint128(sharesAllocated);
                state.market.totalNoShares += uint128(sharesAllocated);
            }
            
            // Update epoch
            state.epochs[epochIndex].sharesAllocated += sharesAllocated;
            
            // Update pool
            uint usdUsed = (sharesAllocated * trade.pricePerShare) / 1e18;
            state.totalPoolUSD += usdUsed;
            
            // Handle refund if partial fill
            if (sharesAllocated < sharesRequested) {
                uint refund = trade.amount - usdUsed;
                _issueRefund(state.addresses.basket, trade.sender, refund);
            }
            
            newRemaining = remaining - sharesAllocated;
        } else {
            // Full refund
            _issueRefund(state.addresses.basket, trade.sender, trade.amount);
            newRemaining = remaining;
        }
    }
    
    function _calculateCompensation(uint cleared, uint availableFees) internal view returns (uint) {
        uint estimatedGas = CLEAR_GAS_PER_BID * cleared + 50000;
        uint compensation = estimatedGas * tx.gasprice * 2;
        
        uint maxCompensation = availableFees / 20;
        if (compensation > maxCompensation) {
            compensation = maxCompensation;
        }
        
        return compensation;
    }
    
    function _issueRefund(address basketAddress, address user, uint amount) internal {
        if (amount > 0) {
            Basket(basketAddress).mint(user, amount, basketAddress, 0);
        }
    }
    
    // ============ Epoch Management ============
    
    function clearEpoch(
        AuctionStorage.State storage state,
        uint epochIndex
    ) external returns (uint yesAllocated, uint noAllocated) {
        AuctionStorage.Epoch storage epoch = state.epochs[epochIndex];
        require(!epoch.cleared, "Already cleared");
        require(block.timestamp >= epoch.endTime || epochIndex < state.core.currentEpochIndex, "Not ended");
        
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        uint remaining = epoch.sharesAvailable;
        
        // Process in price order (highest first)
        for (uint i = 0; i < sortedKeys.length && remaining > 0; i++) {
            uint bidId = uint32(sortedKeys[i]);
            AuctionStorage.Bid storage bid = state.allBids[bidId];
            
            if (!bid.processed) {
                uint allocation = Math.min(bid.sharesRequested, remaining);
                bid.sharesAllocated = allocation;
                bid.processed = true;
                
                if (allocation > 0) {
                    if (bid.isYes) {
                        state.userYesShares[bid.bidder] += uint128(allocation);
                        state.market.totalYesShares += uint128(allocation);
                        yesAllocated += allocation;
                    } else {
                        state.userNoShares[bid.bidder] += uint128(allocation);
                        state.market.totalNoShares += uint128(allocation);
                        noAllocated += allocation;
                    }
                    
                    remaining -= allocation;
                    epoch.sharesAllocated += allocation;
                    
                    uint usdUsed = (allocation * bid.pricePerShare) / 1e18;
                    state.totalPoolUSD += usdUsed;
                    
                    // Refund excess
                    if (allocation < bid.sharesRequested) {
                        uint refund = bid.usdAmount - usdUsed;
                        Basket(state.addresses.basket).mint(bid.bidder, refund, state.addresses.basket, 0);
                    }
                } else {
                    // Full refund
                    Basket(state.addresses.basket).mint(bid.bidder, bid.usdAmount, state.addresses.basket, 0);
                }
            }
        }
        
        epoch.cleared = true;
        epoch.clearer = msg.sender;
    }
    
    function checkAndProgressEpoch(AuctionStorage.State storage state) internal {
        AuctionStorage.Epoch storage epoch = state.epochs[state.core.currentEpochIndex];
        
        // Check anti-sniping
        uint timeRemaining = epoch.endTime > block.timestamp ? epoch.endTime - block.timestamp : 0;
        if (timeRemaining < EXTENSION_THRESHOLD && epoch.extensionCount < MAX_EXTENSIONS) {
            epoch.endTime += EXTENSION_DURATION;
            epoch.extensionCount++;
        }
        
        // Check progression
        bool timeExpired = block.timestamp >= epoch.endTime;
        bool nearlyAllocated = epoch.sharesAllocated >= (epoch.sharesAvailable * 95) / 100;
        
        if (timeExpired || nearlyAllocated) {
            if (state.core.currentEpochIndex + 1 < state.params.totalEpochs) {
                state.core.currentEpochIndex++;
                initializeEpoch(state.epochs[state.core.currentEpochIndex], state.core.currentEpochIndex);
            } else {
                state.core.bettingWindowClosed = true;
            }
        }
    }
    
    // ============ Settlement ============
    
    function calculatePayout(
        AuctionStorage.State storage state,
        address user
    ) external view returns (uint) {
        if (!state.market.resolved || state.market.forceMajeurRefunds) return 0;
        
        uint userWinningShares = state.market.outcome ? 
            state.userYesShares[user] : state.userNoShares[user];
        uint totalWinningShares = state.market.outcome ? 
            state.market.totalYesShares : state.market.totalNoShares;
        
        if (userWinningShares == 0 || totalWinningShares == 0) return 0;
        return (userWinningShares * state.totalPoolUSD) / totalWinningShares;
    }
    
    function processClaim(
        AuctionStorage.State storage state,
        address user
    ) external returns (uint payout) {
        require(state.market.resolved && !state.market.forceMajeurRefunds, "Not resolved");
        
        // Calculate payout inline instead of calling calculatePayout
        uint userWinningShares = state.market.outcome ? 
            state.userYesShares[user] : state.userNoShares[user];
        uint totalWinningShares = state.market.outcome ? 
            state.market.totalYesShares : state.market.totalNoShares;
        
        if (userWinningShares == 0 || totalWinningShares == 0) {
            payout = 0;
        } else {
            payout = (userWinningShares * state.totalPoolUSD) / totalWinningShares;
        }
        
        require(payout > 0, "No payout");
        
        state.userYesShares[user] = 0;
        state.userNoShares[user] = 0;
        
        Basket(state.addresses.basket).mint(user, payout, state.addresses.basket, 0);
    }
    
    function processForceMajeurRefund(
        AuctionStorage.State storage state,
        address user
    ) external returns (uint refund) {
        require(state.market.forceMajeurRefunds, "No force majeur");
        
        uint userShares = state.userYesShares[user] + state.userNoShares[user];
        require(userShares > 0, "No shares");
        
        state.userYesShares[user] = 0;
        state.userNoShares[user] = 0;
        
        uint totalShares = state.market.totalYesShares + state.market.totalNoShares;
        refund = (userShares * state.totalPoolUSD) / totalShares;
        
        Basket(state.addresses.basket).mint(user, refund, state.addresses.basket, 0);
    }
    
    // ============ View Functions ============
    
    function getCurrentEpochInfo(
        AuctionStorage.State storage state
    ) external view returns (uint, uint, uint, uint, bool) {
        uint index = state.core.currentEpochIndex;
        if (index >= state.params.totalEpochs) return (index, 0, 0, 0, false);
        
        AuctionStorage.Epoch storage epoch = state.epochs[index];
        uint currentPrice = epoch.sharesAvailable > 0 ? 
            (epoch.sharesAllocated * 1e18) / epoch.sharesAvailable : 1e18;
        currentPrice = currentPrice < 0.01e18 ? 0.01e18 : (currentPrice > 1e18 ? 1e18 : currentPrice);
        
        uint timeRemaining = epoch.endTime > block.timestamp ? epoch.endTime - block.timestamp : 0;
        
        return (index, currentPrice, timeRemaining, epoch.totalBids, !state.core.bettingWindowClosed && !epoch.cleared);
    }
    
    function getMarketMetrics(
        AuctionStorage.State storage state
    ) external view returns (uint, uint, uint, uint, uint) {
        return (
            state.core.totalMarketDepth,
            state.core.dynamicBatchThreshold,
            0, // Removed entropy
            state.core.totalProtocolFees,
            state.core.lastClearBlock
        );
    }
    
    function getPredictionSummary(
        AuctionStorage.State storage state
    ) external view returns (string memory, uint, uint, uint, uint, bool, bool) {
        uint probability = 0;
        if (state.market.totalYesShares + state.market.totalNoShares > 0) {
            probability = (uint(state.market.totalYesShares) * 100) / 
                         (state.market.totalYesShares + state.market.totalNoShares);
        }
        
        return (
            state.market.question,
            state.market.totalYesShares,
            state.market.totalNoShares,
            state.totalPoolUSD,
            probability,
            state.market.resolved,
            state.market.outcome
        );
    }
    
    // ============ Helper Functions ============
    
    function normalizePriceToTier(uint rawPrice) internal pure returns (uint) {
        uint[10] memory tiers = [
            uint(0.10e18), 0.20e18, 0.30e18, 0.40e18, 0.50e18,
            0.60e18, 0.70e18, 0.80e18, 0.90e18, 1.00e18
        ];
        
        for (uint i = 0; i < 10; i++) {
            if (rawPrice <= tiers[i]) return tiers[i];
        }
        return tiers[9];
    }
    
    function calculateBatchThreshold(uint marketDepth) internal pure returns (uint) {
        if (marketDepth < 10000e18) return 1000e18;
        if (marketDepth < 100000e18) return 2000e18;
        if (marketDepth < 1000000e18) return 5000e18;
        return 10000e18;
    }
    
    function shouldAutoClear(AuctionStorage.State storage state) internal view returns (bool) {
        uint lastBlock = state.core.lastClearBlock;
        uint yesCount = state.batchesYes[lastBlock].trades.length;
        uint noCount = state.batchesNo[lastBlock].trades.length;
        uint total = state.batchesYes[lastBlock].total + state.batchesNo[lastBlock].total;
        
        return (yesCount + noCount >= 10) || (total >= 50000e18);
    }
    
    function calculateGasCompensation(
        uint bidsCleared,
        uint gasPrice,
        uint availableFees
    ) internal pure returns (uint) {
        uint estimatedGas = CLEAR_GAS_PER_BID * bidsCleared + 50000;
        uint compensation = estimatedGas * gasPrice * 2;
        
        uint maxCompensation = availableFees / 20;
        if (compensation > maxCompensation) {
            compensation = maxCompensation;
        }
        
        return compensation;
    }
    
    function initializeEpoch(
        AuctionStorage.Epoch storage epoch,
        uint epochIndex
    ) internal {
        epoch.startTime = block.timestamp;
        epoch.endTime = block.timestamp + 1 hours;
        epoch.sharesAvailable = calculateEpochShares(epochIndex);
        epoch.sharesAllocated = 0;
        epoch.totalBids = 0;
        epoch.totalGasCollected = 0;
        epoch.cleared = false;
    }
    
    function calculateEpochShares(uint epochIndex) internal pure returns (uint) {
        uint shares = INITIAL_SHARES_PER_EPOCH;
        for (uint i = 0; i < epochIndex && i < 20; i++) {
            shares = (shares * (100 - SHARES_DECAY_RATE)) / 100;
        }
        return shares < 1000e18 ? 1000e18 : shares;
    }
    
    function queueBidToBatch(
        mapping(uint => AuctionStorage.Batch) storage batches,
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        uint targetBlock
    ) internal {
        while (batches[targetBlock].trades.length >= MAX_BATCH_SIZE) {
            targetBlock++;
        }
        
        batches[targetBlock].trades.push(AuctionStorage.Trade({
            sender: bidder,
            amount: usdAmount,
            pricePerShare: pricePerShare
        }));
        batches[targetBlock].total += usdAmount;
    }
    
    function depositToken(
        address basketAddress,
        address from,
        address token,
        uint amount
    ) external returns (uint) {
        // TEMPORARY: Mock for testing
        // return Basket(basketAddress).deposit(from, token, amount);
        return amount; // 1:1 mock
    }
}