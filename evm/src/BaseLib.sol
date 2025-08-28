// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

library BaseLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    int256 constant I_WAD = 1e18;
    
    // Safe casting helpers
    function toInt24(int256 value) public pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "SafeCast: value doesn't fit in int24");
        return int24(value);
    }
    
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in uint128");
        return uint128(value);
    }
    
    struct SlugData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }
    
    struct BelgianState {
        uint40 lastEpoch;
        int256 tickAccumulator;
        uint256 totalBasketIn;
        uint256 total404Out;
        uint256 totalProceeds;
        uint256 minimumProceeds;
        uint256 maximumProceeds;
        int128 feesAccrued0;
        int128 feesAccrued1;
    }
    
    struct AuctionParams {
        uint256 startingTime;
        uint256 endingTime;
        uint256 epochLength;
        int24 startingTick;
        int24 endingTick;
        int24 gamma;
        uint256 numPDSlugs;
        bool isToken0;
        int24 upperSlugRange;
    }
    
    function getCurrentEpoch(
        uint256 startingTime,
        uint256 epochLength
    ) internal view returns (uint256) {
        if (block.timestamp < startingTime) return 1;
        return (block.timestamp - startingTime) / epochLength + 1;
    }
    
    function getRemainingEpochs(
        uint256 endingTime,
        uint256 epochLength
    ) internal view returns (uint256) {
        if (block.timestamp >= endingTime) return 0;
        return (endingTime - block.timestamp) / epochLength;
    }
    
    function getExpectedTokensSold(
        AuctionParams memory params,
        uint256 total404Out,
        uint256 epochOffset
    ) internal view returns (uint256) {
        uint256 totalDuration = params.endingTime - params.startingTime;
        uint256 targetTime = block.timestamp + (epochOffset * params.epochLength);
        
        if (targetTime > params.endingTime) targetTime = params.endingTime;
        
        uint256 elapsed = targetTime - params.startingTime;
        return (total404Out * elapsed) / totalDuration;
    }
    
    function calculateConfidenceAdjustment(
        uint256 avgConfidence,
        int24 gamma
    ) internal pure returns (int256) {
        if (avgConfidence == 0) return 0;
        
        // Convert to tick adjustment (-gamma to +gamma range)
        int256 adjustment = (int256(avgConfidence) - 7500) * int256(gamma) / 2500;
        return adjustment * I_WAD;
    }
    
    function getTicksBasedOnState(
        int256 accumulator,
        int24 tickSpacing,
        int24 startingTick,
        int24 gamma,
        bool isToken0
    ) internal pure returns (int24 lower, int24 upper) {
        int24 accumulatorDelta = toInt24(accumulator / I_WAD);
        int24 adjustedTick = startingTick + accumulatorDelta;
        
        lower = alignTickWithSpacing(adjustedTick, tickSpacing, false);
        
        if (isToken0) {
            upper = lower + gamma;
        } else {
            upper = lower - gamma;
        }
    }
    
    function alignTickWithSpacing(
        int24 tick,
        int24 tickSpacing,
        bool roundUp
    ) internal pure returns (int24) {
        if (tick < 0) {
            return roundUp ? 
                tick / tickSpacing * tickSpacing :
                (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
        } else {
            return roundUp ?
                (tick + tickSpacing - 1) / tickSpacing * tickSpacing :
                tick / tickSpacing * tickSpacing;
        }
    }
    
    function computeLowerSlug(
        PoolKey memory key,
        uint256 totalTokensSold,
        uint256 numeraireAvailable,
        int24 tickLower,
        int24 currentTick,
        bool isToken0
    ) internal pure returns (SlugData memory slug) {
        if (numeraireAvailable == 0 || totalTokensSold == 0) {
            return SlugData({
                tickLower: currentTick,
                tickUpper: currentTick,
                liquidity: 0
            });
        }
        
        slug.tickLower = tickLower;
        slug.tickUpper = currentTick;
        
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(currentTick);
        
        if (isToken0) {
            slug.liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLower,
                sqrtPriceUpper,
                numeraireAvailable
            );
        } else {
            slug.liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceLower,
                sqrtPriceUpper,
                numeraireAvailable
            );
        }
    }
    
    function computeUpperSlug(
        PoolKey memory key,
        AuctionParams memory params,
        uint256 totalTokensSold,
        uint256 total404Out,
        int24 currentTick,
        uint256 assetAvailable
    ) internal view returns (SlugData memory slug, uint256 assetRemaining) {
        uint256 expectedSold = getExpectedTokensSold(params, total404Out, 1);
        int256 tokensDelta = int256(expectedSold) - int256(totalTokensSold);
        
        uint256 tokensToLP;
        if (tokensDelta > 0) {
            tokensToLP = uint256(tokensDelta) > assetAvailable ? 
                assetAvailable : uint256(tokensDelta);
            
            int24 range = params.upperSlugRange > key.tickSpacing ? 
                params.upperSlugRange : key.tickSpacing;
            
            slug.tickLower = currentTick;
            slug.tickUpper = alignTickWithSpacing(
                params.isToken0 ? currentTick + range : currentTick - range,
                key.tickSpacing,
                false
            );
            
            if (slug.tickLower != slug.tickUpper && tokensToLP > 0) {
                uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(slug.tickLower);
                uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(slug.tickUpper);
                
                if (params.isToken0) {
                    slug.liquidity = LiquidityAmounts.getLiquidityForAmount0(
                        sqrtPriceLower,
                        sqrtPriceUpper,
                        tokensToLP
                    );
                } else {
                    slug.liquidity = LiquidityAmounts.getLiquidityForAmount1(
                        sqrtPriceLower,
                        sqrtPriceUpper,
                        tokensToLP
                    );
                }
            }
        } else {
            slug.tickLower = currentTick;
            slug.tickUpper = currentTick;
            slug.liquidity = 0;
        }
        
        assetRemaining = assetAvailable - tokensToLP;
    }
    
    function computePriceDiscoverySlugs(
        PoolKey memory key,
        AuctionParams memory params,
        SlugData memory upperSlug,
        int24 tickUpper,
        uint256 assetAvailable
    ) internal view returns (SlugData[] memory) {
        uint256 pdCount = params.numPDSlugs;
        
        if (assetAvailable == 0 || pdCount == 0) {
            return new SlugData[](0);
        }
        
        uint256 epochsRemaining = getRemainingEpochs(params.endingTime, params.epochLength);
        uint256 slugsToPlace = epochsRemaining < pdCount ? epochsRemaining : pdCount;
        
        if (slugsToPlace == 0) return new SlugData[](0);
        
        SlugData[] memory slugs = new SlugData[](slugsToPlace);
        int24 rangeDelta = (tickUpper - upperSlug.tickUpper) / int24(int256(slugsToPlace));
        
        if (params.isToken0) {
            rangeDelta = rangeDelta < key.tickSpacing ? key.tickSpacing : rangeDelta;
        } else {
            rangeDelta = rangeDelta < -key.tickSpacing ? rangeDelta : -key.tickSpacing;
        }
        
        uint256 tokensPerSlug = assetAvailable / slugsToPlace;
        int24 tick = upperSlug.tickUpper;
        
        for (uint256 i = 0; i < slugsToPlace; i++) {
            slugs[i].tickLower = tick;
            tick = alignTickWithSpacing(tick + rangeDelta, key.tickSpacing, false);
            slugs[i].tickUpper = tick;
            
            if (tokensPerSlug > 0 && slugs[i].tickLower != slugs[i].tickUpper) {
                uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(slugs[i].tickLower);
                uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(slugs[i].tickUpper);
                
                if (params.isToken0) {
                    slugs[i].liquidity = LiquidityAmounts.getLiquidityForAmount0(
                        sqrtPriceLower,
                        sqrtPriceUpper,
                        tokensPerSlug
                    );
                } else {
                    slugs[i].liquidity = LiquidityAmounts.getLiquidityForAmount1(
                        sqrtPriceLower,
                        sqrtPriceUpper,
                        tokensPerSlug
                    );
                }
            }
        }
        
        return slugs;
    }
    
    function calculateConfidenceFee(
        uint256 confidence
    ) internal pure returns (uint24) {
        if (confidence >= 9000) return 1000;      // 0.1% for 90%+ confidence
        if (confidence >= 7500) return 2000;      // 0.2% for 75%+ confidence
        if (confidence >= 6000) return 3000;      // 0.3% for 60%+ confidence
        return 4000;                              // 0.4% for lower confidence
    }
}