
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MessageCodec} from "./MessageCodec.sol";
import {Types} from "./Types.sol";

interface IVogue {
    function takeETH(uint howMuch,
        address recipient) external
        returns (uint);
}

interface IUniswapV3Pool {
    function slot0() external
    view returns (uint160, int24,
    uint16, uint16, uint16,
    uint8, bool);
}

interface ISwapRouter {
    struct ExactInputParams { bytes path;
        address recipient; uint256 deadline;
        uint256 amountIn; uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params)
                       external payable returns (uint256);
}

interface IAux {
    function take(address who,
        uint amount, address token,
        bool strict) external returns (uint);
}

interface IJury {
    function stablecoinToMarket(address) external view returns (uint64);
    function getDepegStats(address) external view
        returns (MessageCodec.DepegStats memory);
}

/* TODO uncomment for L2
interface IChainlinkOracle {
    function latestRoundData() external view
    returns (uint80, int, uint, uint, uint80);
}

interface IDSRRate {
    function getRate() external view returns (uint);
}

interface ISCRVOracle {
    function pricePerShare() external view returns (uint);
}
*/

interface IRover {
    function take(uint amount) external returns (uint);
    function withdrawUSDC(uint amount) external returns (uint);
    function deposit(uint amount) external;
    function depositUSDC(uint amount, uint price) external;
}

interface IPool {
    function getReserveAToken(address asset) external view returns (address);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IVogueCore {
    function POOLED_ETH() external view returns (uint);
    function POOLED_USD() external view returns (uint);
    function MAX_POOLED_USD() external view returns (uint);
    function token1isETH() external view returns (bool);
    function swap(uint160 sqrtPriceX96, address sender,
        bool forOne, address token, uint amount) external returns (uint);
}

/// @notice Minimal interface for Liquity V2 StabilityPool
/// @dev 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF (WETH)
interface IStabilityPool {
    function provideToSP(uint256 _topUp, bool _doClaim) external;
    function withdrawFromSP(uint256 _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint256);
    function getDepositorYieldGainWithPending(address _depositor) external view returns (uint256);
}

interface ITeller {
    function share() external view returns (address);
    function asset() external view returns (address);
    function todayTimestamp() external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
    function convertToShares(uint assets) external view returns (uint);
    function deposit(uint assets, address receiver) external returns (uint shares);
    function redeem(uint shares, address receiver, address owner) external returns (uint assets);
    function redemptionLimitRemaining(address account, uint day) external view returns (uint);
    function limit(address) external view returns (uint56 depositLimit, uint56 redeemLimit);
}

library BasketLib {
    uint public constant WAD = 1e18;
    uint public constant WEEK = 604800;
    uint public constant MONTH = 2420000;

    // Oracle type flags
    uint8 public constant ORACLE_CHAINLINK = 3;
    uint8 public constant ORACLE_CRV = 2;
    uint8 public constant ORACLE_DSR_RATE = 1;

    error StaleOracle();
    error BadPrice();
    struct Metrics {
        uint total;
        uint last;
        uint yield;
        uint trackingStart;
        uint yieldAccum;
    }

    function computeMetrics(Metrics memory stats,
        uint elapsed, uint total) internal
        view returns (Metrics memory) {
        if (stats.trackingStart == 0) {
            stats.trackingStart = block.timestamp;
        }
        // Periodic yield since last snapshot
        stats.yield = (stats.total > 0 && total > stats.total)
            ? FullMath.mulDiv(WAD, total - stats.total,
                                          stats.total) : 0;
        // Accumulate this period's yield immediately
        if (stats.last > 0) {
            stats.yieldAccum += stats.yield * elapsed;
        }
        stats.total = total;
        stats.last = block.timestamp;

        return stats;
    }

    function getAverageYield(Metrics memory stats) external view returns (uint) {
        if (stats.trackingStart == 0) return 0;
        uint totalTime = block.timestamp - stats.trackingStart;
        uint timeSinceUpdate = block.timestamp - stats.last;
        uint currentAccum = stats.yieldAccum + stats.yield * timeSinceUpdate;
        return currentAccum / (totalTime + 1);
    }

    /// @notice Calculate SP position
    //  & yield contribution in get_deposits
    /// @param sp StabilityPool address...
    /// @param depositor Address to check
    /// @param reserved Untouchable amount
    /// @param state Current SP tracking state
    /// @return totalValue Position value (compounded + yield - reserved)
    /// @return yieldContrib Contribution to amounts[12] for weighted average
    function calcSPValue(address sp, address depositor,
        uint reserved, SPState memory state) external
        view returns (uint totalValue, uint yieldContrib) {
        if (sp == address(0)) return (0, 0);

        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(depositor);
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(depositor);
        totalValue = compounded + yieldGain; totalValue -= Math.min(totalValue, reserved);
        if (totalValue == 0) return (0, 0);

        // Calculate time-weighted APY for yield contribution
        uint currentPrincipalTime = state.spPrincipalTime +
            state.spValue * (block.timestamp - state.spLastUpdate);

        if (currentPrincipalTime > 0 && state.spTotalYield > 0) {
            uint rate = FullMath.mulDiv(state.spTotalYield,
                WAD * 365 days, currentPrincipalTime);
            yieldContrib = FullMath.mulDiv(totalValue, WAD + rate, WAD);
        } else {
            yieldContrib = totalValue; // no yield history, 1:1
        }
    }

    struct SPState {
        uint spValue;         // original principal tracking (not compounded yield)
        uint spTotalYield;    // cumulative harvested yield (USD value, WAD)
        uint spPrincipalTime; // cumulative (principal * seconds)
        uint spLastUpdate;    // last update timestamp
    }

    /// @notice Result from SP withdraw operation
    struct SPWithdrawResult {
        uint sent;            // BOLD amount being sent out
        uint toRedeposit;     // BOLD amount to redeposit (already done)
        uint wethGain;        // ETH collateral gained (caller handles swap)
        uint boldReceived;    // Total BOLD received from SP
        // Updated state values - caller must write these
        uint newSpValue;
        uint newSpTotalYield;
        uint newSpPrincipalTime;
        uint newSpLastUpdate;
    }

    /// @notice Execute SP withdrawal and return results with updated state
    /// @dev Performs withdrawFromSP and provideToSP, caller handles WETH swap
    /// @param sp StabilityPool address
    /// @param bold BOLD token address
    /// @param weth WETH token address
    /// @param amount Requested withdrawal amount
    /// @param ethPrice Current ETH price (WAD) for yield calculation
    /// @param state Current SP tracking state
    /// @return r Result with amounts and updated state values
    function withdrawFromSP(address sp, address bold,
        address weth, uint amount, uint ethPrice,
        SPState memory state) external returns (SPWithdrawResult memory r) {
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(address(this));
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(address(this));
        uint totalBold = compounded + yieldGain;
        if (totalBold == 0) return r;

        // Only from principal, not yield...
        amount = Math.min(amount, compounded);
        uint wethBefore = WETH9(payable(weth)).balanceOf(address(this));
        uint boldBefore = IERC20(bold).balanceOf(address(this));
        IStabilityPool(sp).withdrawFromSP(compounded, true);

        r.boldReceived = IERC20(bold).balanceOf(address(this)) - boldBefore;
        r.wethGain = WETH9(payable(weth)).balanceOf(address(this)) - wethBefore;

        // Send only from principal
        r.sent = Math.min(amount, r.boldReceived);
        // Redeposit everything else (includes all yield)
        r.toRedeposit = r.boldReceived - r.sent;

        r.newSpPrincipalTime = state.spPrincipalTime +
           state.spValue * (block.timestamp - state.spLastUpdate);
        r.newSpLastUpdate = block.timestamp;

        // Only ETH gains count as harvested (BOLD yield compounds)
        uint wethValueUSD = FullMath.mulDiv(r.wethGain, ethPrice, WAD);
        r.newSpTotalYield = state.spTotalYield + wethValueUSD;

        // Sent is all principal
        r.newSpValue = state.spValue > r.sent ? state.spValue - r.sent : 0;
        if (r.toRedeposit > 0) IStabilityPool(sp).provideToSP(r.toRedeposit, false);

    }

    /// @notice Deposit BOLD to StabilityPool and return updated state
    /// @param sp StabilityPool address
    /// @param amount Amount to deposit
    /// @param state Current SP tracking state
    /// @return newSpValue Updated spValue
    /// @return newSpPrincipalTime Updated spPrincipalTime
    /// @return newSpLastUpdate Updated spLastUpdate
    function depositToSP(address sp,
        uint amount, SPState memory state) external
        returns (uint newSpValue, uint newSpPrincipalTime, uint newSpLastUpdate) {
        newSpPrincipalTime = state.spPrincipalTime + state.spValue * (
                                 block.timestamp - state.spLastUpdate);

        newSpValue = state.spValue + amount;
        newSpLastUpdate = block.timestamp;
        IStabilityPool(sp).provideToSP(amount, false);
    }

    /// @notice Dynamic deposit fee:
    /// linear decay from 2% to 0.25%
    /// @param amount Amount being deposited
    /// @param current Current untouchable amount
    /// @param target Target amount (seeded * multiplier)
    /// @return cut Fee amount to deduct from deposit
    function depositFee(uint amount, uint current,
        uint target) public pure returns (uint cut) { // 0.25% floor
        if (current >= target || target == 0) return amount / 400;
        // Linear decay: rate = 2% - (2% - 0.25%) * (current/target)
        // = 2% - 1.75% * progress = (200 - 175 * progress) / 10000
        // Simplified: amount * (200 - 175 * current / target) / 10000
        uint bps = 200 - (175 * current / target);
        cut = FullMath.mulDiv(amount, bps, 10000);
    }

    /// @notice Dynamic target multiplier: decays from 3x to 1x over 2 years
    /// @param trackingStart Timestamp when tracking started
    /// @return multiplier Between 1e18 and 3e18 (WAD-scaled)
    function getTargetMultiplier(uint trackingStart) public view returns (uint) {
        uint elapsed = block.timestamp - trackingStart;
        uint maturity = 730 days; // 2 years
        if (elapsed >= maturity) return 1e18; // 1x floor
        // Linear decay: 3x -> 1x over maturity period
        return (3e18 * maturity - 2e18 * elapsed) / maturity;
    }

    /// @notice Effective multiplier: min(time_based, backing_based)
    /// @param seeded Total raw deposits from seed investors (post-increment)
    /// @param untouchable Current untouchable reserves
    /// @param trackingStart Timestamp when first seed occurred
    function getEffectiveMultiplier(uint seeded, uint untouchable,
        uint trackingStart) public view returns (uint) {

        // Time-based ceiling: 3x → 1x over 2 years
        uint timeMult = getTargetMultiplier(trackingStart);

        // Bootstrap phase: no fees collected yet, use time-based
        if (untouchable == 0) return timeMult;

        // Max possible liability if all seed investors got 3x
        uint maxLiability = seeded * 3;

        //  ratio: untouchable / maxLiability, capped at 100%)
        uint backingRatio = untouchable >= maxLiability ? WAD
            : FullMath.mulDiv(untouchable, WAD, maxLiability);
        // Backing multiplier: 1x at 0% backed, 3x at 100% backed
        uint backingMult = WAD + 2 * backingRatio;
        return timeMult < backingMult
             ? timeMult : backingMult;
    }

    /// @notice ETH price from sqrtPriceX96
    /// @param sqrtPriceX96 Square root price
    /// @param token0isUSD Whether token0 is USD
    /// @return price ETH price in USD 1e18
    function getPrice(uint160 sqrtPriceX96, bool token0isUSD)
        public pure returns (uint price) {
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
               casted, casted, 1 << 64);

        if (token0isUSD) {
          price = FullMath.mulDiv(1 << 128,
              WAD * 1e12, ratioX128);
        } else {
          price = FullMath.mulDiv(ratioX128,
              WAD * 1e12, 1 << 128);
        }
    }

    function getUSYCRedeemable(address teller) public view returns
        (uint) { address usycToken = ITeller(teller).share();
        uint usycBalance = ITeller(teller).convertToAssets(
                           IERC20(usycToken).balanceOf(msg.sender));
        uint dailyLimit = ITeller(teller).redemptionLimitRemaining(
                      msg.sender, ITeller(teller).todayTimestamp());
        return Math.min(usycBalance, dailyLimit) * 1e12; // Scale to 1e18
    }

    function getUSYCValue(// time value of money
        address teller, address holder) external
        view returns (uint value, uint yield) {
        if (teller == address(0)) return (0, 0);
        address usyc = ITeller(teller).share();
        uint shares = IERC20(usyc).balanceOf(holder);
        uint assets = ITeller(teller).convertToAssets(shares); // USDC 6 dec
        value = assets * 1e12; // Scale to 18 dec
        // Yield = value above par (1 USYC started at $1)
        uint parValue = shares * 1e12; // par = 1:1 with USDC
        yield = value > parValue ? value - parValue : 0;
    }

    function withdrawUSYC(address teller,
        address recipient, uint amount)
        external returns (uint sent,
        uint sharesUsed) { address usyc = ITeller(teller).share();
        uint shares = IERC20(usyc).balanceOf(address(this));
        shares = Math.min(ITeller(teller).convertToShares(amount), shares);

        uint today = ITeller(teller).todayTimestamp();
        uint remaining = ITeller(teller).redemptionLimitRemaining(
                                             address(this), today);
        sharesUsed = Math.min(shares,
        ITeller(teller).convertToShares(remaining));
        if (sharesUsed > 0) sent = ITeller(teller).redeem(sharesUsed,
                                            recipient, address(this));
    }

    function depositUSYC(address teller,
        address aave, address usdc, uint amount,
        uint maxPooledUSD) public returns
        (uint pulled, uint deposited) {
        if (amount == 0) return (0, 0);
        uint maxToUSYC = amount;  // Default: can put everything in USYC
        address aUSDC = IPool(aave).getReserveAToken(usdc);

        if (maxPooledUSD > 0) {
            // Need to keep minAave in AAVE for instant LP withdrawals
            uint usycDailyLimit = ITeller(teller).redemptionLimitRemaining(
                            address(this), ITeller(teller).todayTimestamp());

            address usycToken = ITeller(teller).share();
            uint usycBalance = ITeller(teller).convertToAssets(
                     IERC20(usycToken).balanceOf(address(this)));

            uint effectiveLimit = Math.min(usycBalance,
                                        usycDailyLimit);

            uint minAave = maxPooledUSD > effectiveLimit ?
                           maxPooledUSD - effectiveLimit : 0;

            // aToken balance = underlying 1:1
            uint currentAave = IERC20(aUSDC).balanceOf(address(this));
            uint afterDeposit = currentAave + amount;
            maxToUSYC = afterDeposit > minAave ?
                        afterDeposit - minAave : 0;
        }
        uint balBefore = IERC20(usdc).balanceOf(address(this));
        (uint56 depositLimit,) = ITeller(teller).limit(address(this));
        uint toTeller = Math.min(Math.min(amount,
                uint(depositLimit)), maxToUSYC);

        if (toTeller > 0) {
            try ITeller(teller).deposit(toTeller, address(this))
                returns (uint) { pulled = balBefore -
                    IERC20(usdc).balanceOf(address(this));
            } catch {}
        } deposited = amount > pulled ? amount - pulled : 0;
    }

    function ticksToPrice(int56 tickCum0,
        int56 tickCum1, uint32 period, bool token0isUSD) external
        pure returns (uint price) { int56 delta = tickCum1 - tickCum0;
        int24 averageTick = int24(delta / int56(uint56(period)));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(averageTick);
        price = getPrice(sqrtPriceX96, token0isUSD);
    }

    uint public constant BASE = 4;                 // Fixed base fee (bps)
    uint private constant ABS_MULT = 40;          // Linear absolute: risk × 0.4
    uint private constant REL_SPREAD_MAX = 120;   // Max relative spread at full intensity
    uint private constant INTENSITY_START = 1200; // 12% max_risk threshold
    uint private constant INTENSITY_RANGE = 3500; // Full intensity at 47%
    uint private constant RISK_WEIGHT = 7;        // 70% weight (÷10)
    uint private constant CONC_WEIGHT = 3;        // 30% weight (÷10)
    uint private constant INTERACTION_COEF = 15;  // 0.15 as integer (÷100)
    uint private constant INTERACTION_CLAMP = 2000; // ±20% as ±2000/10000
    uint private constant MAX_FEE = 420;

    // Anti-manipulation constants
    uint private constant MIN_MARKET_CAPITAL = 10_000e6;  // $10k minimum in prediction market
    uint private constant CONF_DAMPENING_THRESHOLD = 7000; // 70% confidence threshold
    uint private constant CONF_DAMPENING_FACTOR = 5000;    // Halve excess above threshold
    uint128 public constant GAS_FINAL_RULING = 200_000;
    /// @notice risk statistics for fee calculation
    struct BasketStats { uint minRisk; uint maxRisk;
                         uint avgRisk; uint nTokens; }

    /* TODO uncomment, L2 specific helper functions per deployment

    /// @notice Calculate pro-rata withdrawal amounts for L2 basket
    /// @dev Split into helper to reduce stack depth
    /// @param sixDecMask Bitmask where bit i is set if token i has 6 decimals
    function calcWithdrawAmounts(uint amount,
        uint[14] memory deposits, int indexToSkip,
        bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices,
        uint16 sixDecMask) external
        pure returns (uint[12] memory w) {
        if (deposits[1] == 0 || amount == 0) return w;
        for (uint i = 0; i < 12; i++) {
            if (int(i) == indexToSkip
            || deposits[i + 2] == 0) continue;
            w[i] = _calcOne(amount, deposits[1],
                deposits[i + 2], i, strict,
                prices, priceIndices, sixDecMask);
        }
    }

    function _calcOne(uint amount, uint total, uint dep,
        uint i, bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices,
        uint16 sixDecMask) private pure
        returns (uint share) { uint price = 0;
        if (priceIndices[0] == i) price = prices[0];
        else if (priceIndices[1] == i) price = prices[1];
        else if (priceIndices[2] == i) price = prices[2];

        // Calculate value for share calc
        uint val = price > 0 ? FullMath.mulDiv(dep, price, WAD) : dep;

        // Pro-rata share
        share = FullMath.mulDiv(amount, FullMath.mulDiv(WAD, val, total), WAD);

        // Convert back to RAW if staked
        if (price > 0) share = FullMath.mulDiv(share, WAD, price);

        // Cap at available
        if (!strict && share > dep) share = dep;

        // Apply divisor for 6-decimal tokens (check bit i in mask)
        if ((sixDecMask >> i) & 1 != 0) share /= 1e12;
    }

    /// @notice Get staked token price from oracle
    /// @param oracle Oracle address
    /// @param oracleType Type of oracle (use ORACLE_* constants)
    /// @return price Price in WAD (1e18)
    function getStakedPrice(address oracle, uint8 oracleType)
        external view returns (uint price) {
        if (oracleType == ORACLE_DSR_RATE) {
            price = IDSRRate(oracle).getRate();
        } else if (oracleType == ORACLE_CRV) {
            price = ISCRVOracle(oracle).pricePerShare();
        } else if (oracleType == ORACLE_CHAINLINK) {
            (, int answer,, uint ts,) = IChainlinkOracle(oracle).latestRoundData();
            price = uint(answer);
            if (ts == 0 || ts > block.timestamp) revert StaleOracle();
        }
        if (price < WAD) revert BadPrice();
    }

    struct StakedPairs {
        uint8[4] base;    // Base token indices
        uint8[4] staked;  // Corresponding staked token indices
    }

    function getBaseIndex(uint idx,
        StakedPairs memory pairs)
        internal pure returns (uint) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return pairs.base[i];

        return idx;
    }

    /// @notice Get combined deposits for a base token + its staked variant
    function getCombinedDeposits(uint base, uint[14] memory deps,
        StakedPairs memory pairs) internal pure returns
        (uint) { uint combined = deps[base + 2];
        for (uint i = 0; i < 4; i++) if (pairs.base[i] == base) {
                combined += deps[pairs.staked[i] + 2]; break;
        } return combined;
    }

    function isStakedToken(uint idx,
        StakedPairs memory pairs)
        internal pure returns (bool) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return true;

        return false;
    }

    /// @dev Build basket stats - separated to reduce stack depth
    function _buildBasket(uint[14] memory deps,
        StakedPairs memory pairs, address[] memory stables,
        address jury) private view returns (BasketStats memory basket) {
        uint[8] memory risks; uint validRisks;
        for (uint i = 0; i < stables.length; i++) {
            if (isStakedToken(i, pairs)) continue;
            if (getCombinedDeposits(i, deps, pairs) == 0) continue;
            basket.nTokens++;
            uint64 mktId = IJury(jury).stablecoinToMarket(stables[i]);
            if (mktId != 0) {
                MessageCodec.DepegStats memory s = IJury(jury).getDepegStats(stables[i]);
                if (s.timestamp > 0) { risks[validRisks] = calcRisk(s); validRisks++; }
            }
        } if (validRisks == 0) {
            basket.minRisk = type(uint).max; // Signal no valid risk data
            return basket;
        }
        basket.minRisk = type(uint).max; uint sum;
        for (uint j = 0; j < validRisks; j++) {
            if (risks[j] < basket.minRisk) basket.minRisk = risks[j];
            if (risks[j] > basket.maxRisk) basket.maxRisk = risks[j];
            sum += risks[j];
        }   basket.avgRisk = sum / validRisks;
    }

    /// @notice Unified fee calculation using StakedPairs config
    function calcFeeWithPairs(uint idx, uint[14] memory deps,
        StakedPairs memory pairs, address[] memory stables,
        address jury) external view returns (uint) {
        uint base = getBaseIndex(idx, pairs);
        if (IJury(jury).stablecoinToMarket(stables[base]) == 0) return 0;

        MessageCodec.DepegStats memory stats = IJury(jury).getDepegStats(stables[base]);
        if (stats.timestamp == 0) return BASE;
        if (deps[1] == 0) return BASE;

        uint concentration = (getCombinedDeposits(
            base, deps, pairs) * 10000) / deps[1];

        BasketStats memory basket = _buildBasket(deps, pairs, stables, jury);
        if (basket.nTokens == 0 || basket.minRisk == type(uint).max) return BASE;
        return calcFee(stats, concentration, basket);
    }

    function calcFeeUni(uint idx, uint[7] memory deps, address[] memory stables,
        address jury) external view returns (uint) {
        uint base = (idx == 3) ? 2 : idx; // sUSDS maps to USDS
        if (IJury(jury).stablecoinToMarket(stables[base]) == 0) return 0;
        MessageCodec.DepegStats memory stats = IJury(jury).getDepegStats(stables[base]);
        if (stats.timestamp == 0 || deps[1] == 0) return BASE;
        uint combined = (idx >= 2 && idx <= 3) ? deps[4] + deps[5] : deps[idx + 2];
        uint conc = (combined * 10000) / deps[1];
        BasketStats memory basket = _buildUni(deps, stables, jury);
        if (basket.nTokens == 0 || basket.minRisk == type(uint).max) return BASE;
        return calcFee(stats, conc, basket);
    }

    function _buildUni(uint[7] memory deps, address[] memory stables,
        address jury) private view returns (BasketStats memory b) {
        uint[5] memory risks; uint valid;
        for (uint i = 0; i < 5; i++) {
            if (i == 3) continue; // skip sUSDS, count USDS
            uint dep = (i == 2) ? deps[4] + deps[5] : deps[i + 2];
            if (dep == 0) continue;
            b.nTokens++;
            uint64 mktId = IJury(jury).stablecoinToMarket(stables[i]);
            if (mktId != 0) {
                MessageCodec.DepegStats memory s = IJury(jury).getDepegStats(stables[i]);
                if (s.timestamp > 0) risks[valid++] = calcRisk(s);
            }
        }
        if (valid == 0) { b.minRisk = type(uint).max; return b; }
        b.minRisk = type(uint).max; uint sum;
        for (uint j = 0; j < valid; j++) {
            if (risks[j] < b.minRisk) b.minRisk = risks[j];
            if (risks[j] > b.maxRisk) b.maxRisk = risks[j];
            sum += risks[j];
        }   b.avgRisk = sum / valid;
    }

    function calcFeePoly(uint idx, uint[8] memory deps, address[] memory stables,
        address jury) external view returns (uint) {
        if (IJury(jury).stablecoinToMarket(stables[idx]) == 0) return 0;
        MessageCodec.DepegStats memory stats = IJury(jury).getDepegStats(stables[idx]);
        if (stats.timestamp == 0 || deps[1] == 0) return BASE;
        uint conc = (deps[idx + 2] * 10000) / deps[1];
        BasketStats memory basket = _buildPoly(deps, stables, jury);
        if (basket.nTokens == 0 || basket.minRisk == type(uint).max) return BASE;
        return calcFee(stats, conc, basket);
    }

    function _buildPoly(uint[8] memory deps, address[] memory stables,
        address jury) private view returns (BasketStats memory b) {
        uint[6] memory risks; uint valid;
        for (uint i = 0; i < 6; i++) {
            if (deps[i + 2] == 0) continue;
            b.nTokens++;
            uint64 mktId = IJury(jury).stablecoinToMarket(stables[i]);
            if (mktId != 0) {
                MessageCodec.DepegStats memory s = IJury(jury).getDepegStats(stables[i]);
                if (s.timestamp > 0) risks[valid++] = calcRisk(s);
            }
        } if (valid == 0) { b.minRisk = type(uint).max; return b; }

        b.minRisk = type(uint).max; uint sum;
        for (uint j = 0; j < valid; j++) {
            if (risks[j] < b.minRisk) b.minRisk = risks[j];
            if (risks[j] > b.maxRisk) b.maxRisk = risks[j];
            sum += risks[j];
        }   b.avgRisk = sum / valid;
    }
    */

    /// @notice Build LayerZero Type 3 options for cross-chain messages
    /// @param msgType Message type (FINAL_RULING or EXTEND_MARKET)
    /// @return options Encoded LZ options bytes
    function buildOptions(uint8 msgType) external
        pure returns (bytes memory) { uint128 gas;
        if (msgType == 6) gas = GAS_FINAL_RULING;
        else revert("Unknown message type");

        // LayerZero V2 Type 3 Options Format:
        // [type(uint16)][workerID(uint8)][optionLength(uint16)][optionType(uint8)][gas(uint128)][value(uint128)]
        // See: https://docs.layerzero.network/v2/developers/evm/configuration/options
        // OPTION_TYPE_LZRECEIVE contains (uint128 _gas, uint128 _value)

        uint128 value = 10_000_000; // 0.01 SOL in lamports
        // Total size: 2 + 1 + 2 + 1 + 16 + 16 = 38 bytes
        bytes memory options = new bytes(38);

        // Type 3 header (uint16 big-endian)
        options[0] = 0x00;
        options[1] = 0x03;

        // Worker ID: Executor (uint8)
        options[2] = 0x01;

        // Option length: 33 bytes = 1 (option type) + 16 (gas) + 16 (value)
        options[3] = 0x00;
        options[4] = 0x21; // 0x21 = 33

        // Option type: LZRECEIVE (uint8)
        options[5] = 0x01;

        // Gas (uint128 = 16 bytes, big-endian)
        for (uint i = 0; i < 16; i++) {
            options[6 + i] = bytes1(uint8(gas >> (120 - i * 8)));
        }
        // Value (uint128 = 16 bytes, big-endian)
        for (uint i = 0; i < 16; i++) {
            options[22 + i] = bytes1(uint8(value >> (120 - i * 8)));
        }
        return options;
    }

    /// @notice Extract composeMsg from send() calldata
    /// @dev Uses assembly to efficiently parse SendParam struct
    /// @return payload The extracted compose message bytes
    /* ---------------------------------------------------------------*
     * extracts SendParam.composeMsg from calldata...
     * assumes send(SendParam, MessagingFee, address)
     * [0] = dstEid(uint32), [1] = to(bytes32), [2] = amountLD(uint),
     * [3] = minAmountLD(uint), [4] = extraOptions(bytes),
     * [5] = composeMsg(bytes),    [6] = oftCmd(bytes)
     * ---------------------------------------------------------------*/
    function extract(bytes calldata original)
        external pure returns (bytes memory payload) {
        assembly { let base := original.offset
            let off0 := calldataload(add(base, 4))
            let structStart := add(add(base, 4), off0)
            let composeHeadPos := add(structStart, 0xA0)
            let composeOffset := calldataload(composeHeadPos)
            let composePos := add(structStart, composeOffset)
            let len := calldataload(composePos)

            let ptr := mload(0x40)
            mstore(ptr, len)
            calldatacopy(add(ptr, 0x20), add(composePos, 0x20), len)
            let size := add(0x20, and(add(len, 0x1f), not(0x1f)))
            mstore(0x40, add(ptr, size))
            payload := ptr
        }
    }

    /// @notice Dampen extreme confidence values to reduce manipulation potential
    /// @param conf Confidence value in basis points (0-10000)
    /// @return Dampened confidence value
    function _dampenConfidence(uint conf) internal pure returns (uint) {
        if (conf <= CONF_DAMPENING_THRESHOLD) return conf;
        uint excess = conf - CONF_DAMPENING_THRESHOLD;
        uint dampenedExcess = (excess * CONF_DAMPENING_FACTOR) / 10000;
        return CONF_DAMPENING_THRESHOLD + dampenedExcess;
    }

    /// @notice Calculate fee for depositing a specific stablecoin
    /// @param s Stats for this token from prediction market
    /// @param concentration Token's % of basket (basis points)
    /// @param basket Basket-wide stats
    /// @return Fee in basis points
    function calcFee(MessageCodec.DepegStats memory s, uint concentration,
        BasketStats memory basket) public view returns (uint) {
        // No data or completely stale (>7 days): return base fee
        if (s.timestamp == 0) return BASE;
        uint staleness = block.timestamp - s.timestamp;
        if (staleness > 7 days) return BASE;
        // Confirmed depeg: maximum fee
        if (s.depegged) return MAX_FEE;
        // Calculate risk score with
        // anti-manipulation protections
        uint risk = calcRisk(s);
        // Decay risk toward neutral (5000) after 1 day of staleness
        // This prevents attackers from blocking LayerZero messages to
        // keep favorable risk scores frozen
        if (staleness > 1 days) {
            // Linear decay over 6 days (from day 1 to day 7)
            uint decayProgress = ((staleness - 1 days) * 10000) / 6 days;
            if (decayProgress > 10000) decayProgress = 10000;
            // Interpolate toward neutral (5000)
            if (risk > 5000) {
                risk = risk - FullMath.mulDiv(risk - 5000,
                                    decayProgress, 10000);
            } else {
                risk = risk + FullMath.mulDiv(5000 - risk,
                                    decayProgress, 10000);
            }
        } // Calculate absolute premium based on risk
        uint absPremium = (risk * ABS_MULT) / 10000;
        // Check if there's meaningful risk differentiation in the basket
        uint riskRange = basket.maxRisk > basket.minRisk
                      ? basket.maxRisk - basket.minRisk : 1;

        // If risk range is too narrow,
        // just return base + absolute premium
        if (riskRange <= 100) return BASE + absPremium;

        // Calculate position score
        // (combines risk and concentration)
        uint position = _calcPosition(risk,
            concentration, basket, riskRange);
        // Quadratic scaling for position
        uint posSquared = (position * position) / 10000;
        // Intensity scales with max risk in basket
        uint intensity = basket.maxRisk < INTENSITY_START ? 0 :
            (basket.maxRisk >= INTENSITY_START + INTENSITY_RANGE ? 10000
                    : ((basket.maxRisk - INTENSITY_START) * 10000) / INTENSITY_RANGE);

        uint totalSpread = 4 + (intensity * (REL_SPREAD_MAX - 4)) / 10000;
        uint fee = BASE + absPremium + (posSquared * totalSpread) / 10000;
        return fee > MAX_FEE ? MAX_FEE : fee;
    }

    /// @notice Calculate position score
    /// combining risk and concentration
    function _calcPosition(uint risk,
        uint concentration, BasketStats memory basket,
        uint riskRange) internal pure returns (uint) {
        uint riskScore = risk >= basket.minRisk ? (
                    (risk - basket.minRisk) * 10000) / riskRange : 0;
                            if (riskScore > 10000) riskScore = 10000;

        uint avgConc = 10000 / basket.nTokens;
        uint concScore = (concentration * 5000) / avgConc;
        if (concScore > 10000) concScore = 10000;

        uint combined = (RISK_WEIGHT *
            riskScore + CONC_WEIGHT * concScore) / 10;
        int riskDev = int(risk) - int(basket.avgRisk);
        int concDevScaled = int((concentration * 100) / avgConc) - 100;
        int interaction = (riskDev * concDevScaled *
            int(INTERACTION_COEF)) / int(riskRange * 100);

        if (interaction > int(INTERACTION_CLAMP)) interaction = int(INTERACTION_CLAMP);
        if (interaction < -int(INTERACTION_CLAMP)) interaction = -int(INTERACTION_CLAMP);

        int position = int(combined) + interaction;
        if (position < 0) position = 0;
        if (position > 10000) position = 10000;
        return uint(position);
    }

    /// @notice risk score from prediction market data
    /// @dev Includes anti-manipulation: minimum capital
    /// requirement and confidence dampening
    /// @param s Depeg stats from prediction market
    /// @return Risk score in basis points
    /// (0 = safe, 10000 = definitely depegging)
    function calcRisk(MessageCodec.DepegStats memory s)
        public pure returns (uint) {
        // Confirmed depeg: maximum risk
        if (s.depegged) return 10000;
        // minimum market capital to prevent cheap manipulation
        uint totalCapital = uint(s.capPeg) + uint(s.capDepeg);
        if (totalCapital < MIN_MARKET_CAPITAL) {
            return 6500; // Neutral when insufficient liquidity to trust signal
        } // Dampen extreme confidence values to reduce manipulation potential
        // Without this, an attacker could stake with 99% confidence to amplify
        // their position's effect on the conviction-weighted calculation
        // Conviction-weighted calculation: capital × dampened_confidence
        uint confDepeg = _dampenConfidence(uint(s.avgConfDepeg));
        uint confPeg = _dampenConfidence(uint(s.avgConfPeg));
        uint convDepeg = uint(s.capDepeg) * confDepeg;
        uint convPeg = uint(s.capPeg) * confPeg;
        uint totalConv = convPeg + convDepeg;
        // No conviction: neutral risk...
        if (totalConv == 0) return 5000;
        // pro rata to depeg bet's conviction
        return (convDepeg * 10000) / totalConv;
    }

    /// @notice basket-wide statistics for fee calc
    function calcBasketStats(uint[] memory risks)
        public pure returns (BasketStats memory b) {
        if (risks.length == 0) return b;
        b.nTokens = risks.length;
        b.minRisk = type(uint).max;
        b.maxRisk = 0; uint sum = 0;

        for (uint i = 0; i < risks.length; i++) {
            if (risks[i] < b.minRisk) b.minRisk = risks[i];
            if (risks[i] > b.maxRisk) b.maxRisk = risks[i];
            sum += risks[i];
        }   b.avgRisk = sum / risks.length;
    }

    /// @notice Find index of last mature batch
    function matureBatches(uint[] memory batches,
        uint currentTimestamp, uint deployedTime)
        external pure returns (int i) {
        uint currentMonth = (currentTimestamp - deployedTime) / MONTH;
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--)
            if (batches[uint(i)] <= currentMonth) return i;

        return -1;
    }

    /// @param thresholdPercent Max deviation
    function isManipulated(uint spot, uint twap,
        uint thresholdPercent) public pure returns (bool) {
        uint dev = spot > twap ? spot - twap : twap - spot;
        return dev * 100 > twap * thresholdPercent;
    }

    /// fetch V3 spot, check against twap
    function isV3Manipulated(address pool,
        bool token1isWETH, uint twapPrice)
        public view returns (bool) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return isManipulated(getPrice(sqrtPriceX96, token1isWETH), twapPrice, 2);
    }

    function calculateVaultWithdrawal(address vault, uint amount)
        external view returns (uint sharesNeeded, uint assetsReceived) {
        uint vaultBalance = IERC4626(vault).balanceOf(address(this));
        sharesNeeded = IERC4626(vault).convertToShares(amount);
        sharesNeeded = Math.min(vaultBalance, sharesNeeded);
        assetsReceived = IERC4626(vault).convertToAssets(sharesNeeded);
        return (sharesNeeded, assetsReceived);
    }

    /// @notice Scale token amounts between precisions...
    function scaleTokenAmount(uint amount, address token,
        bool scaleUp) external view returns (uint scaled) {
        uint decimals = IERC20(token).decimals();
        uint scale = decimals < 18 ? 18 - decimals : 0;
        scaled = scale > 0 ? (scaleUp ? amount * (10 ** scale):
              amount / (10 ** scale)) : amount; return scaled;
    }

    /// @notice Fee calculation for L1 (no staked pairs)
    /// @param token The token to calculate fee for
    /// @param idx Token index in stables array
    /// @param deps Deposits array from get_deposits()
    /// @param stables Array of stablecoin addresses
    /// @param jury Jury contract address
    function calcFeeL1(address token, uint idx,
        uint[13] memory deps, address[] memory stables,
        address jury) public view returns (uint) {
        if (IJury(jury).stablecoinToMarket(token) == 0) return BASE;

        MessageCodec.DepegStats memory stats = IJury(jury).getDepegStats(token);
        if (stats.timestamp == 0) return BASE;

        uint totalDeposits = deps[0];
        if (totalDeposits == 0) return BASE;

        uint concentration = (deps[idx + 1] * 10000) / totalDeposits;
        uint[] memory risks = new uint[](stables.length);
        uint validRisks = 0; uint stablesInBasket = 0;
        for (uint i = 0; i < stables.length; i++) {
            if (deps[i + 1] < 100 * WAD) continue;
            stablesInBasket++;
            uint64 mktId = IJury(jury).stablecoinToMarket(stables[i]);
            if (mktId != 0) {
                MessageCodec.DepegStats memory s = IJury(jury).getDepegStats(stables[i]);
                if (s.timestamp > 0) risks[validRisks++] = calcRisk(s);
            }
        } if (validRisks == 0) return BASE;
        uint[] memory validRisksArray = new uint[](validRisks);
        for (uint i = 0; i < validRisks; i++) validRisksArray[i] = risks[i];
        BasketStats memory basket = calcBasketStats(validRisksArray);
        basket.nTokens = stablesInBasket;
        return calcFee(stats, concentration, basket);
    }

    /// @notice Calculate fee with automatic index lookup
    /// @dev Wrapper around calcFeeL1 that finds index internally
    function calcFeeL1WithLookup(address token,
        uint[13] memory deps, address[] memory stables,
        address jury) external view returns (uint) {
        uint len = stables.length;
        for (uint i; i < len;) {
            if (stables[i] == token)
                return calcFeeL1(token,
                i, deps, stables, jury);
            unchecked { ++i; }
        } return 0;
    }

    /// @notice Find token with highest imbalance score (fee)
    /// @dev Higher fee = more overweight + risky = priority to reduce
    /// @return idx Index of most imbalanced token
    /// @return fee Imbalance score (higher = reduce first)
    /// @return excess Amount over equal weight (18 dec)
    function getMostImbalanced(uint[13] memory deps,
        address[] memory stables, address jury) external
        view returns (uint idx, uint fee, uint excess) {
        uint total = deps[0];
        if (total == 0) return (0, 0, 0);
        uint len = stables.length; uint high;
        for (uint i; i < len;) {
            if (deps[i + 1] > 100 * WAD) {
                uint f = calcFeeL1(stables[i],
                        i, deps, stables, jury);
                if (f > high) { high = f; idx = i; }
            } unchecked { ++i; }
        } fee = high;
        uint eq = total / len;
        if (deps[idx + 1] > eq)
            excess = deps[idx + 1] - eq;
    }

    /// @notice get ETH from V3 selling USDC when V4 pool is short on ETH...
    function arbETH(Types.AuxContext memory ctx, uint shortfall,
        uint price ) external returns (uint got, bool failed) {
        uint usdNeeded = convert(shortfall, price, false);
        uint took = IAux(address(this)).take(address(this),
                                usdNeeded, ctx.usdc, false);
        if (took == 0)
            return (0, false);

         got = swapUSDCtoWETH(ctx,
               took / 1e12, price);

        if (got == 0)
            return (0, false);

        if (ctx.isAAVE)
            IPool(ctx.vault).supply(
            ctx.weth, got, ctx.v4, 0);
        else
            got = IERC4626(ctx.vault).convertToAssets(
             IERC4626(ctx.vault).deposit(got, ctx.v4));
    }

    function swapWETHtoUSDC(Types.AuxContext memory ctx,
        uint amountIn, uint price) public returns (uint amountOut) {
        uint poolUSDC = IERC20(ctx.usdc).balanceOf(ctx.v3Pool);
        uint max = convert(poolUSDC, price, true);
        if (amountIn > max) amountIn = max;
        if (amountIn > 0) {
            uint minOut = convert(amountIn, price, false) * 99500 / 100000;
            (bool ok, bytes memory ret) = ctx.v3Router.call(abi.encodeWithSelector(
                ISwapRouter.exactInput.selector, ISwapRouter.ExactInputParams(
                    abi.encodePacked(ctx.weth, ctx.v3Fee, ctx.usdc),
                    address(this), block.timestamp, amountIn, minOut)));
            if (ok && ret.length >= 32) amountOut = abi.decode(ret, (uint));
        }
    }

    /// @notice Source USDC externally: Rover first, then V3
    function sourceExternalUSD(Types.AuxContext memory ctx, address rover,
        uint wethIn, uint price) public returns (uint usdcOut) {
        if (rover != address(0)) {
            uint targetUSDC = convert(wethIn, price, false);
            uint fromRover = IRover(rover).withdrawUSDC(targetUSDC);
            if (fromRover > 0) {
                // Deposit proportional WETH for what Rover gave us
                uint wethForRover = convert(fromRover, price, true);
                IRover(rover).deposit(wethForRover); usdcOut = fromRover;
                wethIn = wethIn > wethForRover ? wethIn - wethForRover : 0;
            }
        } if (wethIn > 0) usdcOut += swapWETHtoUSDC(ctx, wethIn, price);
    }

    /// @notice Source WETH externally: Rover first, then V3
    function sourceExternalWETH(Types.AuxContext memory ctx, address rover,
        uint usdcIn, uint price) public returns (uint wethOut) {
        if (rover != address(0)) {
            uint targetWETH = convert(usdcIn, price, true);
            uint fromRover = IRover(rover).take(targetWETH);
            if (fromRover > 0) {
                // Deposit proportional USDC for what Rover gave us
                uint usdcForRover = convert(fromRover, price, false);
                IRover(rover).depositUSDC(usdcForRover, price);
                wethOut = fromRover;
                usdcIn = usdcIn > usdcForRover ? usdcIn - usdcForRover : 0;
            }
        } if (usdcIn > 0) wethOut += swapUSDCtoWETH(ctx, usdcIn, price);
    }

    /// @notice Unified token sourcing: V4.takeETH (optional) → Rover → V3
    /// @param target Amount of output token needed
    /// @param input Available input token to swap
    /// @param price Current price for external swaps
    /// @param v4Price Price for V4.takeETH calc (0 = skip V4, use target directly if !forUSD)
    /// @param forUSD true = WETH→USDC, false = USDC→WETH
    function source(Types.AuxContext memory ctx, address vogue,
        address rover, uint target, uint input, uint price,
        uint v4Price, bool forUSD) external
        returns (uint got, uint used) {
        if (forUSD) { // Want USDC from WETH...
            // Tier 1: V4.takeETH → swap to USDC
            if (vogue != address(0) && v4Price > 0) {
                uint ethNeeded = convert(target, v4Price, true);
                uint gotETH = IVogue(vogue).takeETH(ethNeeded, address(this));
                if (gotETH > 0) { WETH9(payable(ctx.weth)).deposit{value: gotETH}();
                    uint gotUSDC = sourceExternalUSD(ctx, rover, gotETH, price);
                    // Track V4 ETH to reduce user's available input
                    target = target > gotUSDC ? target - gotUSDC : 0;
                    got += gotUSDC; used += gotETH;
                }
            } // Tier 2: User's WETH → swap to USDC
            if (target > 0 && input > used) { uint available = input - used;
                uint selling = Math.min(convert(target, price, true), available);
                if (selling > 0) { got += sourceExternalUSD(
                                 ctx, rover, selling, price);
                                             used += selling;
                }
            }
        } else { // Want WETH from USDC...
            // Tier 1: V4.takeETH directly
            if (vogue != address(0)) {
                got = IVogue(vogue).takeETH(target, address(this));
                if (got > 0)
                    WETH9(payable(ctx.weth)).deposit{value: got}();
            } // Tier 2: User's USDC → swap to WETH
            if (got < target && input > 0) {
                used = Math.min(convert(target - got, price, false), input);
                if (used > 0)
                    got += sourceExternalWETH(ctx, rover, used, price);
            }
        }
    }

    function routeSwap(Types.AuxContext memory ctx, address core,
        address rover, uint160 sqrtPriceX96, bool zeroForOne,
        address token, uint amount, uint pooled, uint v4Price,
        uint v3Price, address recipient) external
        returns (uint out) {
        if (!isManipulated(getPrice(sqrtPriceX96,
            IVogueCore(core).token1isETH()), v4Price, 2)) {
            pooled = Math.min(amount, convert(
                pooled, v4Price, token != address(0)));
            if (pooled > 0) {
                if (token != address(0)) {
                    if (ctx.isAAVE)
                        IPool(ctx.vault).supply(ctx.weth,
                                        pooled, ctx.v4, 0);
                    else
                        IERC4626(ctx.vault).deposit(pooled, ctx.v4);
                }
                out = IVogueCore(core).swap(sqrtPriceX96,
                    recipient, zeroForOne, token, pooled);
            }
        } else { pooled = 0; }
        v4Price = amount - pooled;
        if (v4Price > 0) {
            require(!isV3Manipulated(ctx.v3Pool,
                IVogueCore(core).token1isETH(), v3Price));
            if (token == address(0)) {
                v4Price = IAux(address(this)).take(address(this),
                                        v4Price, ctx.usdc, false);
                if (v4Price > 0) {
                    v4Price = sourceExternalWETH(ctx,
                            rover, v4Price, v3Price);
                    WETH9(payable(ctx.weth)).withdraw(v4Price);
                    (zeroForOne,) = recipient.call{
                                  value: v4Price}("");
                    require(zeroForOne); out += v4Price;
                }
            } else {
                v4Price = sourceExternalUSD(ctx,
                            rover, v4Price, v3Price);
                IERC20(ctx.usdc).transfer(
                     recipient, v4Price);
                          out += v4Price;
            }
        }
    }

    /// @notice Swap USDC→WETH via V3, capped at pool liquidity
    function swapUSDCtoWETH(Types.AuxContext memory ctx,
        uint amountIn, uint price) public returns (uint amountOut) {
        uint poolWETH = IERC20(ctx.weth).balanceOf(ctx.v3Pool);
        uint max = convert(poolWETH, price, false);
        if (amountIn > max) amountIn = max;
        if (amountIn > 0) {
            uint minOut = convert(amountIn, price, true) * 99500 / 100000; // TODO slippage?
            (bool ok, bytes memory ret) = ctx.v3Router.call(abi.encodeWithSelector(
                ISwapRouter.exactInput.selector, ISwapRouter.ExactInputParams(
                    abi.encodePacked(ctx.usdc, ctx.v3Fee, ctx.weth),
                    address(this), block.timestamp, amountIn, minOut)));
            if (ok && ret.length >= 32) amountOut = abi.decode(ret, (uint));
        }
    }

    /// @notice Get available AAVE liquidity (min of aToken balance and reserve)
    function aaveAvailable(address aave, address asset) public view returns (uint) {
        address aToken = IPool(aave).getReserveAToken(asset);
        uint balance = IERC20(aToken).balanceOf(address(this));
        uint reserve = IERC20(asset).balanceOf(aToken);
        return Math.min(balance, reserve);
    }

    /// @notice Convert amount between ETH (18 dec) and USD (6 dec) using price
    function convert(uint amount, uint price, bool toETH) public pure returns (uint) {
        return toETH ? FullMath.mulDiv(amount * 1e12, WAD, price)  // USD to ETH
                     : FullMath.mulDiv(amount, price, WAD) / 1e12; // ETH to USD
    }
}
