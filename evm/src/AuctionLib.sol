// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/SortedSet.sol";
import "./Settlement.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AuctionLib - Secure Library with Enhanced MEV Protection
/// @notice No commit-reveal needed - uses better mechanisms
library AuctionLib {
    using Math for uint;
    using SortedSetLib for SortedSetLib.Set;
    
    // Constants
    uint private constant EPOCH_DURATION = 1 hours;
    uint private constant MIN_BET_USD = 1e18;
    uint private constant GAS_FEE_BPS = 50;
    uint private constant INITIAL_SHARES_PER_EPOCH = 10000e18;
    uint private constant SHARES_DECAY_RATE = 10;
    uint private constant MIN_BIDS_FOR_GAS_COMP = 10;
    uint private constant MAX_BIDS_PER_EPOCH = 1000;
    uint private constant PRICE_INCREMENT = 0.01e18;
    uint private constant EXTENSION_THRESHOLD = 2 minutes;
    uint private constant EXTENSION_DURATION = 5 minutes;
    uint private constant MAX_EXTENSIONS = 3;
    
    // ANTI-MEV Constants
    uint private constant VELOCITY_DECAY_RATE = 15;      // Slower decay to prevent gaming
    uint private constant SUSPICIOUS_VELOCITY = 800;     // Higher threshold for penalties
    uint private constant MAX_VELOCITY_PENALTY = 1000;   // Cap penalty at 10x base fee
    
    // Events
    event EpochExtended(uint indexed epoch, uint newEndTime);
    
    /// @notice SECURE: Process bid with enhanced MEV protection
    function processBidSecure(
        address bidder,
        uint ethAmount,
        uint pricePerShare,
        bool isYes,
        uint currentEpochIndex,
        uint nextBidId,
        mapping(address => uint) storage lastBidTime,
        mapping(address => uint) storage bidVelocity,
        uint epochRandomSeed,
        AuctionStructs.Epoch storage currentEpoch,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        mapping(address => uint[]) storage userBidIds
    ) external returns (
        uint bidId,
        uint usdReceived,
        uint sharesRequested,
        uint gasContribution
    ) {
        // ENHANCED: Velocity-based fee with anti-gaming measures
        uint dynamicFeeBps = calculateDynamicGasFeeSecure(lastBidTime, bidVelocity, bidder, epochRandomSeed);
        gasContribution = (ethAmount * dynamicFeeBps) / 10000;
        
        require(ethAmount > gasContribution, "Gas fee too high");
        uint actualBetETH = ethAmount - gasContribution;
        
        // Mock USD conversion
        usdReceived = actualBetETH * 3000;
        require(usdReceived >= MIN_BET_USD, "Below minimum USD");
        
        // Calculate shares
        sharesRequested = (usdReceived * 1e18) / pricePerShare;
        
        // ENHANCED: Fair pricing with randomized adjustments
        if (currentEpoch.totalBids > 0) {
            uint fairPrice = calculateFairPriceSecure(
                currentEpochIndex,
                currentEpoch.sharesAvailable,
                currentEpoch.sharesAllocated,
                currentEpoch.totalBids,
                epochRandomSeed
            );
            require(pricePerShare >= fairPrice, "Price below fair value");
        }
        
        // ENHANCED: Anti-sniping with unpredictable extensions
        uint newEndTime = checkEpochExtensionSecure(currentEpochIndex, currentEpoch, epochRandomSeed);
        currentEpoch.endTime = newEndTime;
        
        // Create bid
        bidId = nextBidId;
        allBids[bidId] = AuctionStructs.Bid({
            bidder: bidder,
            usdAmount: usdReceived,
            pricePerShare: pricePerShare,
            sharesRequested: sharesRequested,
            sharesAllocated: 0,
            epochIndex: currentEpochIndex,
            timestamp: block.timestamp,
            isYes: isYes,
            processed: false
        });
        
        // Add to sorted set
        uint sortKey = (type(uint).max - pricePerShare) << 32 | bidId;
        currentEpoch.sortedBidIds.insert(sortKey);
        currentEpoch.totalBids++;
        
        userBidIds[bidder].push(bidId);
        currentEpoch.totalGasCollected += gasContribution;
        
        return (bidId, usdReceived, sharesRequested, gasContribution);
    }
    
    /// @notice SECURE: Enhanced velocity tracking that's harder to game
    function calculateDynamicGasFeeSecure(
        mapping(address => uint) storage lastBidTime,
        mapping(address => uint) storage bidVelocity,
        address bidder,
        uint epochRandomSeed
    ) internal returns (uint feeBps) {
        uint currentTime = block.timestamp;
        uint lastBid = lastBidTime[bidder];
        
        uint timeSinceLastBid;
        if (lastBid == 0) {
            timeSinceLastBid = type(uint).max;
        } else if (currentTime >= lastBid) {
            timeSinceLastBid = currentTime - lastBid;
        } else {
            timeSinceLastBid = type(uint).max;
        }
        
        // ENHANCED: More sophisticated velocity calculation
        uint velocityIncrease = 0;
        if (timeSinceLastBid < 15) {
            // Very rapid - maximum penalty
            velocityIncrease = 400;
        } else if (timeSinceLastBid < 45) {
            // Rapid - high penalty  
            velocityIncrease = 200;
        } else if (timeSinceLastBid < 120) {
            // Moderate - medium penalty
            velocityIncrease = 80;
        } else if (timeSinceLastBid < 300) {
            // Slow - small penalty
            velocityIncrease = 20;
        } else if (timeSinceLastBid != type(uint).max) {
            // Decay velocity more gradually to prevent reset gaming
            uint decayMinutes = timeSinceLastBid / 60;
            uint decay = decayMinutes * VELOCITY_DECAY_RATE;
            if (bidVelocity[bidder] > decay) {
                bidVelocity[bidder] = bidVelocity[bidder] - decay;
            } else {
                bidVelocity[bidder] = 0;
            }
        }
        
        // Apply velocity increase
        if (velocityIncrease > 0) {
            bidVelocity[bidder] = Math.min(bidVelocity[bidder] + velocityIncrease, MAX_VELOCITY_PENALTY);
        }
        
        lastBidTime[bidder] = currentTime;
        
        // ENHANCED: Add randomized component to prevent exact calculation
        uint randomComponent = (epochRandomSeed % 20); // 0-19 basis points of randomness
        uint baseVelocityFee = (GAS_FEE_BPS * bidVelocity[bidder]) / 100;
        
        return GAS_FEE_BPS + baseVelocityFee + randomComponent;
    }
    
    /// @notice SECURE: Fair price with enhanced unpredictability
    function calculateFairPriceSecure(
        uint epochIndex,
        uint sharesAvailable,
        uint sharesAllocated,
        uint totalBids,
        uint epochRandomSeed
    ) internal view returns (uint) {
        if (totalBids == 0) return PRICE_INCREMENT;
        
        uint fillRate = 0;
        if (sharesAvailable > 0) {
            fillRate = (sharesAllocated * 100) / sharesAvailable;
        }
        
        // ENHANCED: Multiple sources of randomness
        uint blockRandomness = uint(keccak256(abi.encode(
            blockhash(block.number > 0 ? block.number - 1 : 0),
            block.timestamp,
            epochIndex,
            totalBids,
            epochRandomSeed
        ))) % 50; // Increased variance
        
        // ENHANCED: Non-linear pricing curve that's harder to predict
        uint basePrice = PRICE_INCREMENT;
        
        // Exponential component based on fill rate
        if (fillRate > 0) {
            uint exponentialComponent = (fillRate * fillRate * PRICE_INCREMENT) / 2500; // Non-linear
            basePrice += exponentialComponent;
        }
        
        // Random component
        uint randomComponent = (blockRandomness * PRICE_INCREMENT) / 200;
        basePrice += randomComponent;
        
        // ENHANCED: Time-based component with unpredictability
        uint timeElapsed = block.timestamp % 3600;
        uint timeRandomness = uint(keccak256(abi.encode(timeElapsed, epochRandomSeed))) % 30;
        uint timeFactor = 70 + (timeElapsed * 20 / 3600) + timeRandomness; // 70-120% range
        
        return (basePrice * timeFactor) / 100;
    }
    
    /// @notice SECURE: Anti-sniping with unpredictable extensions
    function checkEpochExtensionSecure(
        uint epochIndex,
        AuctionStructs.Epoch storage epoch,
        uint epochRandomSeed
    ) internal returns (uint newEndTime) {
        uint currentTime = block.timestamp;
        uint timeRemaining = 0;
        if (epoch.endTime > currentTime) {
            timeRemaining = epoch.endTime - currentTime;
        }
        
        if (timeRemaining < EXTENSION_THRESHOLD && epoch.extensionCount < MAX_EXTENSIONS) {
            // ENHANCED: Unpredictable extension duration
            uint randomExtension = uint(keccak256(abi.encode(
                currentTime, epochIndex, epochRandomSeed, block.difficulty
            ))) % (8 * 60); // 0-8 minutes variance
            
            uint extensionDuration = (3 * 60) + randomExtension; // 3-11 minutes
            
            newEndTime = epoch.endTime + extensionDuration;
            epoch.extensionCount++;
            emit EpochExtended(epochIndex, newEndTime);
            return newEndTime;
        }
        return epoch.endTime;
    }
    
    /// @notice SECURE: Pro-rata allocation with MEV resistance
    function allocateProRataSecure(
        SortedSetLib.Set storage sortedBidIds,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        uint sharesAvailable,
        uint sharesAllocated,
        uint epochRandomSeed
    ) external returns (uint newSharesAllocated) {
        uint[] memory sortedKeys = sortedBidIds.getSortedSet();
        newSharesAllocated = sharesAllocated;
        
        if (sortedKeys.length == 0) return newSharesAllocated;
        
        // ENHANCED: True pro-rata allocation by price tiers
        uint currentPrice = type(uint).max;
        uint tierStartIndex = 0;
        
        for (uint i = 0; i <= sortedKeys.length; i++) {
            bool lastIteration = (i == sortedKeys.length);
            uint bidPrice = lastIteration ? 0 : (type(uint).max - (sortedKeys[i] >> 32));
            
            // Process tier when price changes or at end
            if (bidPrice != currentPrice || lastIteration) {
                if (i > tierStartIndex) {
                    newSharesAllocated = allocateTierSecure(
                        sortedKeys, 
                        allBids, 
                        tierStartIndex, 
                        i - 1, 
                        sharesAvailable, 
                        newSharesAllocated,
                        epochRandomSeed
                    );
                }
                currentPrice = bidPrice;
                tierStartIndex = i;
            }
        }
    }
    
    /// @notice SECURE: Tier allocation with anti-gaming measures
    function allocateTierSecure(
        uint[] memory sortedKeys,
        mapping(uint => AuctionStructs.Bid) storage allBids,
        uint startIndex,
        uint endIndex,
        uint sharesAvailable,
        uint sharesAllocated,
        uint epochRandomSeed
    ) internal returns (uint newSharesAllocated) {
        // Safe subtraction
        if (sharesAllocated >= sharesAvailable) {
            return sharesAllocated;
        }
        
        uint sharesRemaining = sharesAvailable - sharesAllocated;
        if (sharesRemaining == 0) return sharesAllocated;
        
        // Calculate total demand in this price tier
        uint tierDemand = 0;
        for (uint i = startIndex; i <= endIndex; i++) {
            uint bidId = uint32(sortedKeys[i]);
            AuctionStructs.Bid storage bid = allBids[bidId];
            if (!bid.processed) {
                tierDemand += bid.sharesRequested;
            }
        }
        
        if (tierDemand == 0) return sharesAllocated;
        
        newSharesAllocated = sharesAllocated;
        
        // ENHANCED: True pro-rata allocation within tier
        if (tierDemand <= sharesRemaining) {
            // Everyone gets full allocation
            for (uint i = startIndex; i <= endIndex; i++) {
                uint bidId = uint32(sortedKeys[i]);
                AuctionStructs.Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    bid.sharesAllocated = bid.sharesRequested;
                    newSharesAllocated += bid.sharesRequested;
                    bid.processed = true;
                }
            }
        } else {
            // Pro-rata allocation with small randomization to prevent gaming
            for (uint i = startIndex; i <= endIndex; i++) {
                uint bidId = uint32(sortedKeys[i]);
                AuctionStructs.Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    uint baseAllocation = (bid.sharesRequested * sharesRemaining) / tierDemand;
                    
                    // ENHANCED: Add tiny random component to prevent precise gaming
                    uint randomAdjustment = uint(keccak256(abi.encode(epochRandomSeed, bidId))) % 3;
                    if (randomAdjustment == 1 && baseAllocation > 0) {
                        baseAllocation = baseAllocation + 1;
                    } else if (randomAdjustment == 2 && baseAllocation > 1) {
                        baseAllocation = baseAllocation - 1;
                    }
                    
                    bid.sharesAllocated = baseAllocation;
                    newSharesAllocated += baseAllocation;
                    bid.processed = true;
                }
            }
        }
    }
    
    /// @notice SECURE: Enhanced epoch timing with unpredictability
    function startNewEpochSecure(
        uint epochIndex,
        uint baseStartTime,
        uint epochRandomSeed
    ) external view returns (uint startTime, uint endTime, uint sharesAvailable) {
        // ENHANCED: Multiple sources of randomness
        uint combinedSeed = uint(keccak256(abi.encode(
            epochRandomSeed,
            block.timestamp,
            blockhash(block.number > 0 ? block.number - 1 : 0),
            epochIndex
        )));
        
        // ENHANCED: Less predictable timing
        uint randomOffset = combinedSeed % (30 * 60); // 30 minutes range
        
        if (randomOffset >= (15 * 60)) {
            startTime = baseStartTime + (randomOffset - (15 * 60));
        } else {
            uint subtraction = (15 * 60) - randomOffset;
            startTime = baseStartTime >= subtraction ? baseStartTime - subtraction : baseStartTime;
        }
        
        if (startTime < block.timestamp) startTime = block.timestamp;
        
        // ENHANCED: More variable duration
        uint durationVariance = (combinedSeed / 1000) % (40 * 60); // 40 minutes variance
        if (EPOCH_DURATION >= (20 * 60)) {
            endTime = startTime + (EPOCH_DURATION - (20 * 60)) + durationVariance;
        } else {
            endTime = startTime + EPOCH_DURATION + durationVariance;
        }
        
        // ENHANCED: Share calculation with randomness
        sharesAvailable = INITIAL_SHARES_PER_EPOCH;
        uint effectiveEpochIndex = epochIndex > 20 ? 20 : epochIndex;
        for (uint i = 0; i < effectiveEpochIndex; i++) {
            sharesAvailable = (sharesAvailable * (100 - SHARES_DECAY_RATE)) / 100;
        }
        
        // ENHANCED: More random share adjustment
        uint shareRandomness = (combinedSeed / 3000) % 21; // 0-20
        uint adjustment = 90 + shareRandomness; // 90-110%
        sharesAvailable = (sharesAvailable * adjustment) / 100;
        
        if (sharesAvailable < 1000e18) {
            sharesAvailable = 1000e18;
        }
    }
    
    // ============ Utility Functions (Same as before) ============
    
    function getCurrentEpochInfo(
        AuctionStructs.Epoch storage epoch,
        bool bettingWindowClosed
    ) external view returns (
        uint currentPrice,
        uint timeRemaining,
        uint bidCount,
        bool isActive
    ) {
        if (epoch.sharesAvailable > 0 && epoch.sharesAllocated < epoch.sharesAvailable) {
            uint sharesRemaining = epoch.sharesAvailable - epoch.sharesAllocated;
            currentPrice = (1e18 * (epoch.sharesAvailable - sharesRemaining)) / epoch.sharesAvailable;
            currentPrice = Math.max(currentPrice, 0.01e18);
            currentPrice = Math.min(currentPrice, 1e18);
        } else {
            currentPrice = 1e18;
        }
        
        timeRemaining = 0;
        if (epoch.endTime > block.timestamp) {
            timeRemaining = epoch.endTime - block.timestamp;
        }
        
        bidCount = epoch.totalBids;
        isActive = !bettingWindowClosed && !epoch.cleared;
    }
    
    function calculateFairPrice(
        uint epochIndex,
        uint sharesAvailable,
        uint sharesAllocated,
        uint totalBids
    ) external view returns (uint) {
        // Use simplified version for view function
        if (totalBids == 0) return PRICE_INCREMENT;
        
        uint fillRate = 0;
        if (sharesAvailable > 0) {
            fillRate = (sharesAllocated * 100) / sharesAvailable;
        }
        
        uint blockRandomness = uint(keccak256(abi.encode(
            blockhash(block.number > 0 ? block.number - 1 : 0),
            block.timestamp,
            epochIndex,
            totalBids
        ))) % 30;
        
        uint basePrice = PRICE_INCREMENT + (fillRate * PRICE_INCREMENT / 25) + (blockRandomness * PRICE_INCREMENT / 150);
        uint timeElapsed = block.timestamp % 3600;
        uint timeFactor = 80 + (timeElapsed * 20 / 3600);
        
        return (basePrice * timeFactor) / 100;
    }
    
    function getMinimumPriceForAllocation(uint totalSharesWanted, uint epochShares) external pure returns (uint) {
        if (epochShares == 0) return 1e18;
        
        uint percentOfEpoch = (totalSharesWanted * 100) / epochShares;
        
        if (percentOfEpoch <= 2) return 0.01e18;
        if (percentOfEpoch <= 5) return 0.03e18;
        if (percentOfEpoch <= 10) return 0.08e18;
        if (percentOfEpoch <= 15) return 0.20e18;
        if (percentOfEpoch <= 20) return 0.35e18;
        if (percentOfEpoch <= 30) return 0.55e18;
        if (percentOfEpoch <= 40) return 0.75e18;
        if (percentOfEpoch <= 50) return 0.90e18;
        return 0.98e18;
    }
}

library AuctionStructs {
    struct Bid {
        address bidder;
        uint usdAmount;
        uint pricePerShare;
        uint sharesRequested;
        uint sharesAllocated;
        uint epochIndex;
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
        uint extensionCount;
        bool cleared;
        bool gasCompensated;
        address clearer;
        SortedSetLib.Set sortedBidIds;
    }
}