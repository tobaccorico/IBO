
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/**
 * @title BasketLib
 * @dev Shared library for pure calculations used by both Basket contracts
 */
library BasketLib {
    uint public constant WAD = 1e18;
    uint public constant WEEK = 604800;
    uint public constant MONTH = 2420000;
    
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
        uint currentMonth = (currentTimestamp - deployedTime) / MONTH;
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--) {
            if (batches[uint(i)] <= currentMonth) {
                return i;
            }
        }
        return -1;
    }
    
    /**
     * @notice Process withdrawal with fee calculation
     * @param amount Amount requested
     * @param max Maximum available
     * @param fee Fee percentage in WAD
     * @return amountNeeded Amount needed including fee
     * @return amountReceived Amount user receives after fee
     */
    function processWithdrawalWithFee(
        uint amount, uint max, uint fee
    ) external pure returns (uint amountNeeded, 
        uint amountReceived) { amountNeeded = amount;
        
        if (fee > 0 && fee < WAD / 10) {
            amountNeeded = FullMath.mulDiv(
                    amount, WAD + fee, WAD);
        }
        if (max >= amountNeeded) {
            amountReceived = fee > 0 ? 
                FullMath.mulDiv(amountNeeded, WAD - fee, WAD) : amountNeeded;

            return (amountNeeded, amountReceived);
        } else {
            amountReceived = fee > 0 ? 
                FullMath.mulDiv(max, WAD - fee, WAD) : 
                max;
            return (max, amountReceived);
        }
    }
    
    /**
     * @notice Calculate vault withdrawal amount
     * @param vault Vault address
     * @param amount Amount to withdraw in assets
     * @return sharesNeeded Shares to burn
     * @return assetsReceived Assets received
     */
    function calculateVaultWithdrawal(address vault, uint amount)
        external view returns (uint sharesNeeded, uint assetsReceived) {
        uint vaultBalance = IERC4626(vault).balanceOf(address(this));
        sharesNeeded = IERC4626(vault).convertToShares(amount);
        sharesNeeded = Math.min(vaultBalance, sharesNeeded);
        assetsReceived = IERC4626(vault).convertToAssets(sharesNeeded);
        return (sharesNeeded, assetsReceived);
    }
    
    /**
     * @notice Scale amount based on token decimals
     * @param amount Amount to scale
     * @param token Token address
     * @param scaleUp True to scale up, false to scale down
     * @return scaled Scaled amount
     */
    function scaleTokenAmount(uint amount, address token,
        bool scaleUp) external view returns (uint scaled) {
        uint decimals = IERC20(token).decimals();
        uint scale = decimals < 18 ? 18 - decimals : 0;
        if (scale > 0) { scaled = scaleUp ? 
                            amount * (10 ** scale) : 
                            amount / (10 ** scale);
        } else {
            scaled = amount;
        }   return scaled;
    }

}
