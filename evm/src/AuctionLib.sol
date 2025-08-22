// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/SortedSet.sol";
import "./Basket.sol";
import "./Aux.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library AuctionLib {
    using Math for uint;
    using SortedSetLib for SortedSetLib.Set;
    
    // Constants
    uint internal constant MIN_BET_USD = 100e18;
    uint internal constant BASE_FEE_BPS = 50; // Simple 0.5% flat fee
    uint internal constant INITIAL_SHARES_PER_EPOCH = 10000e18;
    uint internal constant SHARES_DECAY_RATE = 10;
    uint internal constant CLEAR_GAS_PER_BID = 30000;
    uint internal constant EXTENSION_THRESHOLD = 2 minutes;
    uint internal constant EXTENSION_DURATION = 5 minutes;
    uint internal constant MAX_EXTENSIONS = 3;
    uint internal constant MAX_BATCH_SIZE = 50; // Increased from 40 to prevent stuffing
    
    // Storage slot for lastClearBlock
    bytes32 constant LAST_CLEAR_BLOCK_SLOT = keccak256("auction.lastClearBlock");
    
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
    
    struct BidContext {
        address bidder;
        uint amount;
        uint price;
        bool isYes;
        bool isETH;
        uint96 epochIndex;
        uint96 nextBidId;
        bool bettingWindowClosed;
        bool resolved;
    }
    
    struct ClearResult {
        uint newTotalYesShares;
        uint newTotalNoShares;
        uint newTotalPoolUSD;
        uint totalBidsCleared;
        uint compensation;
        address[] yesTraders;
        uint[] yesAmounts;
        address[] noTraders;
        uint[] noAmounts;
    }
    
    // Storage access helpers
    function getLastClearBlock(address auction) internal view returns (uint) {
        bytes32 slot = keccak256(abi.encode(auction, LAST_CLEAR_BLOCK_SLOT));
        uint value;
        assembly {
            value := sload(slot)
        }
        return value;
    }
    
    function setLastClearBlock(address auction, uint blockNumber) internal {
        bytes32 slot = keccak256(abi.encode(auction, LAST_CLEAR_BLOCK_SLOT));
        assembly {
            sstore(slot, blockNumber)
        }
    }
    
    // Main bid processing
    function processBidLogic(
        BidContext memory ctx,
        address auxSystem,
        address basketAddress,
        mapping(address => bool) storage hasParticipated,
        address[] storage participants
    ) external returns (uint bidId, uint usdAmount, uint protocolFee) {
        validateBid(ctx.price, ctx.amount, ctx.bettingWindowClosed, ctx.resolved);
        
        // Track participant
        if (!hasParticipated[ctx.bidder]) {
            participants.push(ctx.bidder);
        }
        
        // Simple flat fee - no gaming possible
        uint feeBps = BASE_FEE_BPS;
        
        if (ctx.isETH) {
            protocolFee = (ctx.amount * feeBps) / 10000;
            uint actualBetETH = ctx.amount - protocolFee;
            // Mock conversion for testing
            usdAmount = actualBetETH * 3000; // Assume $3000/ETH
        } else {
            usdAmount = ctx.amount;
            protocolFee = (usdAmount * feeBps) / 10000;
            usdAmount -= protocolFee;
        }
        
        require(usdAmount >= MIN_BET_USD, "Below min");
        
        bidId = ctx.nextBidId;
        return (bidId, usdAmount, protocolFee);
    }
    
    function depositToken(
        address basketAddress,
        address from,
        address token,
        uint amount
    ) external returns (uint) {
        // TEMPORARY: Mock conversion for testing
        // TODO: Uncomment for production
        // return Basket(basketAddress).deposit(from, token, amount);
        
        // Mock: assume 1:1 conversion for testing
        return amount;
    }
    
    // Batch clearing with improved memory management
    function clearBatchesForBlock(
        mapping(uint => AuctionStructs.Batch) storage batchesYes,
        mapping(uint => AuctionStructs.Batch) storage batchesNo,
        uint blockToClear,
        AuctionStructs.Epoch storage epoch,
        mapping(address => uint128) storage userYesShares,
        mapping(address => uint128) storage userNoShares,
        uint totalYesShares,
        uint totalNoShares,
        uint totalPoolUSD,
        address basketAddress
    ) external returns (ClearResult memory result) {
        result.newTotalYesShares = totalYesShares;
        result.newTotalNoShares = totalNoShares;
        result.newTotalPoolUSD = totalPoolUSD;
        
        // Process YES batch
        if (batchesYes[blockToClear].trades.length > 0) {
            uint poolAdded;
            (result.yesTraders, result.yesAmounts, poolAdded) = processBatchAndAllocate(
                batchesYes[blockToClear],
                true,
                epoch,
                userYesShares,
                basketAddress
            );
            result.newTotalYesShares += sumArray(result.yesAmounts);
            result.newTotalPoolUSD += poolAdded;
            result.totalBidsCleared += batchesYes[blockToClear].trades.length;
            delete batchesYes[blockToClear];
        }
        
        // Process NO batch
        if (batchesNo[blockToClear].trades.length > 0) {
            uint poolAdded;
            (result.noTraders, result.noAmounts, poolAdded) = processBatchAndAllocate(
                batchesNo[blockToClear],
                false,
                epoch,
                userNoShares,
                basketAddress
            );
            result.newTotalNoShares += sumArray(result.noAmounts);
            result.newTotalPoolUSD += poolAdded;
            result.totalBidsCleared += batchesNo[blockToClear].trades.length;
            delete batchesNo[blockToClear];
        }
        
        // Calculate compensation
        if (result.totalBidsCleared > 0) {
            result.compensation = calculateGasCompensation(result.totalBidsCleared, tx.gasprice, totalPoolUSD / 100);
        }
    }
    
    function processBatchAndAllocate(
        AuctionStructs.Batch storage batch,
        bool isYes,
        AuctionStructs.Epoch storage epoch,
        mapping(address => uint128) storage userShares,
        address basketAddress
    ) internal returns (address[] memory traders, uint[] memory amounts, uint poolAdded) {
        uint length = batch.trades.length;
        traders = new address[](length);
        amounts = new uint[](length);
        
        // Sort by price (simplified bubble sort for small batches)
        uint[] memory indices = new uint[](length);
        for (uint i = 0; i < length; i++) {
            indices[i] = i;
        }
        
        for (uint i = 0; i < length - 1; i++) {
            for (uint j = 0; j < length - i - 1; j++) {
                if (batch.trades[indices[j]].pricePerShare < batch.trades[indices[j + 1]].pricePerShare) {
                    uint temp = indices[j];
                    indices[j] = indices[j + 1];
                    indices[j + 1] = temp;
                }
            }
        }
        
        // Allocate shares
        uint remaining = epoch.sharesAvailable > epoch.sharesAllocated ? 
                        epoch.sharesAvailable - epoch.sharesAllocated : 0;
        
        for (uint i = 0; i < length; i++) {
            AuctionStructs.Trade memory trade = batch.trades[indices[i]];
            traders[i] = trade.sender;
            
            uint sharesRequested = (trade.amount * 1e18) / trade.pricePerShare;
            uint sharesAllocated = Math.min(sharesRequested, remaining);
            
            if (sharesAllocated > 0) {
                userShares[trade.sender] += uint128(sharesAllocated);
                amounts[i] = sharesAllocated;
                epoch.sharesAllocated += sharesAllocated;
                remaining -= sharesAllocated;
                
                uint usdUsed = (sharesAllocated * trade.pricePerShare) / 1e18;
                poolAdded += usdUsed;
                
                if (sharesAllocated < sharesRequested) {
                    uint refund = trade.amount - usdUsed;
                    processRefund(basketAddress, trade.sender, refund);
                }
            } else {
                processRefund(basketAddress, trade.sender, trade.amount);
            }
            
            if (remaining == 0) break;
        }
    }
    
    function clearEpochWithSortedSet(
        AuctionStructs.Epoch storage epoch,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        mapping(address => uint128) storage userYesShares,
        mapping(address => uint128) storage userNoShares,
        address basketAddress
    ) external returns (uint totalYesAllocated, uint totalNoAllocated, uint totalUSDUsed) {
        require(!epoch.cleared, "Cleared");
        require(block.timestamp >= epoch.endTime, "Not ended");
        
        uint allocated = allocateWithSortedSet(epoch.sortedBidIds, allBids, epoch.sharesAvailable);
        
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        for (uint i = 0; i < sortedKeys.length; i++) {
            uint bidId = uint32(sortedKeys[i]);
            AuctionStructs.Bid storage bid = allBids[bidId];
            
            if (bid.sharesAllocated > 0) {
                if (bid.isYes) {
                    userYesShares[bid.bidder] += uint128(bid.sharesAllocated);
                    totalYesAllocated += bid.sharesAllocated;
                } else {
                    userNoShares[bid.bidder] += uint128(bid.sharesAllocated);
                    totalNoAllocated += bid.sharesAllocated;
                }
                
                uint usdUsed = (bid.sharesAllocated * bid.pricePerShare) / 1e18;
                totalUSDUsed += usdUsed;
                
                if (bid.sharesAllocated < bid.sharesRequested) {
                    uint refund = bid.usdAmount - usdUsed;
                    processRefund(basketAddress, bid.bidder, refund);
                }
            } else if (bid.processed) {
                processRefund(basketAddress, bid.bidder, bid.usdAmount);
            }
        }
        
        epoch.sharesAllocated = allocated;
        epoch.cleared = true;
        epoch.clearer = msg.sender;
    }
    
    function allocateWithSortedSet(
        SortedSetLib.Set storage sortedBids,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        uint sharesAvailable
    ) internal returns (uint sharesAllocated) {
        uint[] memory sortedKeys = sortedBids.getSortedSet();
        if (sortedKeys.length == 0) return 0;
        
        uint remaining = sharesAvailable;
        uint currentPrice = type(uint).max;
        uint tierStart = 0;
        
        for (uint i = 0; i <= sortedKeys.length; i++) {
            bool lastIter = (i == sortedKeys.length);
            uint bidPrice = lastIter ? 0 : (type(uint).max - (sortedKeys[i] >> 32));
            
            if (bidPrice != currentPrice || lastIter) {
                if (i > tierStart) {
                    uint allocated = allocateTier(sortedKeys, allBids, tierStart, i - 1, remaining);
                    sharesAllocated += allocated;
                    remaining -= allocated;
                    if (remaining == 0) break;
                }
                currentPrice = bidPrice;
                tierStart = i;
            }
        }
    }
    
    function allocateTier(
        uint[] memory sortedKeys,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        uint startIdx,
        uint endIdx,
        uint sharesRemaining
    ) internal returns (uint allocated) {
        if (sharesRemaining == 0) return 0;
        
        uint tierDemand = 0;
        for (uint i = startIdx; i <= endIdx; i++) {
            uint bidId = uint32(sortedKeys[i]);
            if (!allBids[bidId].processed) {
                tierDemand += allBids[bidId].sharesRequested;
            }
        }
        
        if (tierDemand == 0) return 0;
        
        if (tierDemand <= sharesRemaining) {
            for (uint i = startIdx; i <= endIdx; i++) {
                uint bidId = uint32(sortedKeys[i]);
                AuctionStructs.Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    bid.sharesAllocated = bid.sharesRequested;
                    allocated += bid.sharesRequested;
                    bid.processed = true;
                }
            }
        } else {
            for (uint i = startIdx; i <= endIdx; i++) {
                uint bidId = uint32(sortedKeys[i]);
                AuctionStructs.Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    uint allocation = (bid.sharesRequested * sharesRemaining) / tierDemand;
                    bid.sharesAllocated = allocation;
                    allocated += allocation;
                    bid.processed = true;
                }
            }
        }
    }
    
    // View functions
    function getCurrentEpochInfo(
        AuctionStructs.Epoch storage epoch,
        uint currentEpochIndex,
        uint totalEpochs,
        bool bettingWindowClosed
    ) external view returns (uint index, uint currentPrice, uint timeRemaining, uint bidCount, bool isActive) {
        index = currentEpochIndex;
        if (index >= totalEpochs) return (index, 0, 0, 0, false);
        
        uint allocated = epoch.sharesAllocated;
        uint available = epoch.sharesAvailable;
        currentPrice = available > 0 ? (allocated * 1e18) / available : 1e18;
        currentPrice = currentPrice < 0.01e18 ? 0.01e18 : (currentPrice > 1e18 ? 1e18 : currentPrice);
        timeRemaining = epoch.endTime > block.timestamp ? epoch.endTime - block.timestamp : 0;
        bidCount = epoch.totalBids;
        isActive = !bettingWindowClosed && !epoch.cleared;
    }
    
    function getMarketMetrics(
        uint marketDepth,
        uint protocolFees,
        uint lastClear
    ) external pure returns (uint, uint, uint, uint, uint) {
        uint threshold = calculateBatchThreshold(marketDepth);
        return (marketDepth, threshold, 0, protocolFees, lastClear); // 0 for removed entropy
    }
    
    function calculateMarketDepth(
        uint totalYesShares,
        uint totalNoShares,
        uint totalPoolUSD
    ) external pure returns (uint) {
        return totalPoolUSD;
    }
    
    function calculateUserPayout(
        address user,
        bool outcome,
        uint128 userYesShares,
        uint128 userNoShares,
        uint totalYesShares,
        uint totalNoShares,
        uint totalPoolUSD
    ) external pure returns (uint) {
        uint userWinningShares = outcome ? userYesShares : userNoShares;
        uint totalWinningShares = outcome ? totalYesShares : totalNoShares;
        
        if (userWinningShares == 0 || totalWinningShares == 0) return 0;
        return (userWinningShares * totalPoolUSD) / totalWinningShares;
    }
    
    // Price tier functions
    function getPriceTierAt(uint index) internal pure returns (uint) {
        if (index == 0) return 0.10e18;
        if (index == 1) return 0.20e18;
        if (index == 2) return 0.30e18;
        if (index == 3) return 0.40e18;
        if (index == 4) return 0.50e18;
        if (index == 5) return 0.60e18;
        if (index == 6) return 0.70e18;
        if (index == 7) return 0.80e18;
        if (index == 8) return 0.90e18;
        return 1.00e18;
    }
    
    function normalizePriceToTier(uint rawPrice) public pure returns (uint) {
        for (uint i = 0; i < 10; i++) {
            if (rawPrice <= getPriceTierAt(i)) {
                return getPriceTierAt(i);
            }
        }
        return getPriceTierAt(9);
    }
    
    // Anti-sniping extension check
    function checkEpochExtension(uint epochEndTime, uint extensionCount) public view returns (bool shouldExtend, uint newEndTime) {
        uint timeRemaining = epochEndTime > block.timestamp ? epochEndTime - block.timestamp : 0;
        
        if (timeRemaining < EXTENSION_THRESHOLD && extensionCount < MAX_EXTENSIONS) {
            shouldExtend = true;
            newEndTime = epochEndTime + EXTENSION_DURATION;
        } else {
            shouldExtend = false;
            newEndTime = epochEndTime;
        }
    }
    
    function checkEpochProgression(
        AuctionStructs.Epoch storage epoch,
        uint currentEpochIndex,
        uint totalEpochs
    ) public view returns (bool shouldProgress, bool shouldCloseWindow) {
        if (currentEpochIndex >= totalEpochs) {
            return (false, true);
        }
        
        bool timeExpired = block.timestamp >= epoch.endTime;
        bool nearlyAllocated = epoch.sharesAllocated >= (epoch.sharesAvailable * 95) / 100;
        
        shouldProgress = timeExpired || nearlyAllocated;
        shouldCloseWindow = shouldProgress && (currentEpochIndex + 1 >= totalEpochs);
    }
    
    function initializeEpoch(AuctionStructs.Epoch storage epoch, uint epochIndex) public {
        epoch.startTime = block.timestamp;
        epoch.endTime = block.timestamp + 1 hours;
        epoch.sharesAvailable = calculateEpochShares(epochIndex);
        epoch.sharesAllocated = 0;
        epoch.totalBids = 0;
        epoch.totalGasCollected = 0;
        epoch.cleared = false;
    }
    
    function queueBidToBatch(
        mapping(uint => AuctionStructs.Batch) storage batches,
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        uint maxBatchSize
    ) external returns (uint targetBlock) {
        targetBlock = block.number;
        
        while (batches[targetBlock].trades.length >= maxBatchSize) {
            targetBlock++;
        }
        
        batches[targetBlock].trades.push(AuctionStructs.Trade({
            sender: bidder,
            amount: usdAmount,
            pricePerShare: pricePerShare
        }));
        batches[targetBlock].total += usdAmount;
    }
    
    // Helper functions
    function swapETHtoUSD(address auxAddress, address basketAddress, uint ethAmount) public returns (uint usdReceived) {
        usdReceived = ethAmount * 3000; // Mock for testing
    }
    
    function processRefund(address basketAddress, address user, uint amount) public {
        if (amount > 0) {
            Basket(basketAddress).mint(user, amount, basketAddress, 0);
        }
    }
    
    function calculateEpochShares(uint epochIndex) public pure returns (uint) {
        uint shares = INITIAL_SHARES_PER_EPOCH;
        
        for (uint i = 0; i < epochIndex && i < 20; i++) {
            shares = (shares * (100 - SHARES_DECAY_RATE)) / 100;
        }
        
        return shares < 1000e18 ? 1000e18 : shares;
    }
    
    function calculateGasCompensation(uint bidsCleared, uint gasPrice, uint availableFees) public pure returns (uint compensation) {
        uint estimatedGas = CLEAR_GAS_PER_BID * bidsCleared + 50000;
        compensation = estimatedGas * gasPrice * 2;
        
        uint maxCompensation = availableFees / 20;
        if (compensation > maxCompensation) {
            compensation = maxCompensation;
        }
    }
    
    function calculateBatchThreshold(uint totalMarketDepth) public pure returns (uint) {
        if (totalMarketDepth < 10000e18) return 1000e18;
        if (totalMarketDepth < 100000e18) return 2000e18;
        if (totalMarketDepth < 1000000e18) return 5000e18;
        return 10000e18;
    }
    
    function shouldClearBatch(uint yesBidsCount, uint noBidsCount, uint yesTotal, uint noTotal) public pure returns (bool) {
        return (yesBidsCount + noBidsCount >= 10) || (yesTotal + noTotal >= 50000e18);
    }
    
    function validateBid(uint pricePerShare, uint amount, bool bettingWindowClosed, bool resolved) public pure {
        require(!bettingWindowClosed && !resolved, "Closed");
        
        bool validTier = false;
        for (uint i = 0; i < 10; i++) {
            if (pricePerShare == getPriceTierAt(i)) {
                validTier = true;
                break;
            }
        }
        require(validTier, "Invalid tier");
        require(amount >= MIN_BET_USD || amount >= 0.03 ether, "Below min");
    }
    
    // Additional anti-grief: Check if user has too many pending bids
    function checkBidLimit(uint[] memory userBids, uint maxPendingBids) public pure {
        require(userBids.length < maxPendingBids, "Too many bids");
    }
    
    function sumArray(uint[] memory arr) internal pure returns (uint sum) {
        for (uint i = 0; i < arr.length; i++) {
            sum += arr[i];
        }
    }
}

library AuctionStructs {
    struct Bid {
        address bidder;
        uint usdAmount;
        uint pricePerShare;
        uint sharesRequested;
        uint sharesAllocated;
        uint96 epochIndex;
        uint timestamp;
        bool isYes;
        bool processed;
    }
    
    struct Epoch {
        uint startTime;
        uint endTime;
        uint sharesAvailable;
        uint sharesAllocated;
        uint totalBids;
        uint totalGasCollected;
        bool cleared;
        address clearer;
        SortedSetLib.Set sortedBidIds;
        uint8 extensionCount;
    }
    
    struct Trade {
        address sender;
        uint amount;
        uint pricePerShare;
    }
    
    struct Batch {
        Trade[] trades;
        uint total;
    }
}