// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/**
 * @title BasketLib
 * @notice Shared library for pure calculations used by both Basket contracts
 * @dev Only contains external pure functions to reduce contract bytecode size
 */
library BasketLib {
    uint constant WAD = 1e18;
    
    /**
     * @notice Determine which batches have matured
     * @param batches Array of batch IDs (months)
     * @param currentTimestamp Current block timestamp
     * @param deployedTime Contract deployment timestamp
     * @return i Index of last mature batch (-1 if none)
     */
    function matureBatches(
        uint[] memory batches, 
        uint currentTimestamp, 
        uint deployedTime
    ) external pure returns (int i) {
        uint currentMonth = (currentTimestamp - deployedTime) / 2420000; // ~28 days
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--) {
            if (batches[uint(i)] <= currentMonth) {
                return i;
            }
        }
        return -1;
    }
    
    /**
     * @notice Calculate sigmoid-based fee for rebalancing
     * @param actual Current concentration
     * @param target Target concentration  
     * @param multiplier Fee multiplier
     * @return fee18 Fee in 18 decimal format
     */
    function sigmoidFee(
        uint actual, 
        uint target, 
        uint multiplier
    ) public pure returns (uint fee18) {
        uint deviation;
        if (actual > target) {
            deviation = ((actual - target) * WAD) / target;
        } else {
            deviation = ((target - actual) * WAD) / target;
        }
        
        // Scale deviation for sensitivity
        deviation = deviation / 2;
        
        // Sigmoid: deviation / (WAD + deviation)
        uint sigmoidOutput = (deviation * WAD) / (WAD + deviation);
        
        // Apply multiplier to get final fee
        fee18 = (sigmoidOutput * multiplier) / WAD;
        
        // Cap maximum fee at 0.2% (20 basis points)
        if (fee18 > 2e15) {
            fee18 = 2e15;
        }
    }
    
    /**
     * @notice Calculate rebalancing fee based on vault concentrations
     * @param tokenBalance Current balance of the token/vault
     * @param totalValue Total value across all vaults
     * @param targetConcentration Target concentration for this token
     * @param isMinting Whether this is a deposit (true) or withdrawal (false)
     * @param multiplier Base fee multiplier
     * @return fee18 Fee in 18 decimal format
     */
    function calculateFee(uint tokenBalance,
        uint totalValue, uint targetConcentration,
        bool isMinting, uint multiplier) external
        pure returns (uint fee18) {
        // No fees when basket is empty
        if (totalValue == 0 || tokenBalance == 0) {
            return 0;
        }
        
        uint actual = (tokenBalance * WAD) / totalValue;
        
        // Ensure target is not zero
        if (targetConcentration == 0) {
            return 0;
        }
        
        // For single asset basket (>99% concentration), no fees
        if (actual >= WAD * 99 / 100) {
            return 0;
        }
        
        // No fee if close to target (within 5%)
        uint deviation = actual > targetConcentration ? 
            actual - targetConcentration : 
            targetConcentration - actual;
        
        if (deviation < WAD / 20) {
            return 0;
        }
        
        if (isMinting) {
            // Only charge fee if depositing to overweight vault
            if (actual > targetConcentration) {
                return sigmoidFee(actual, targetConcentration, multiplier);
            }
        } else {
            // Only charge fee if withdrawing from underweight vault
            if (actual < targetConcentration) {
                return sigmoidFee(targetConcentration, actual, multiplier);
            }
        }
        
        return 0;
    }
    
    /**
     * @notice Apply exponential moving average to update concentration
     * @param currentConcentration Current concentration value
     * @param newTarget New target from voting
     * @param alpha Smoothing factor (in WAD units)
     * @return Updated concentration
     */
    function updateConcentrationEMA(
        uint currentConcentration,
        uint newTarget,
        uint alpha
    ) external pure returns (uint) {
        return (newTarget * alpha + currentConcentration * (WAD - alpha)) / WAD;
    }
}