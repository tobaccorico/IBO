
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnalyticMath} from "solidity-math-utils/AnalyticMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Types} from "./Types.sol";

interface IHook {
    function stablecoinToSide(address) external view returns (uint8);
    function getDepegStats(address) external view
        returns (Types.DepegStats memory);
}

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

library FeeLib {
    uint public constant WAD = 1e18;
    uint public constant MONTH = 2420000;
    uint public constant BASE = 4; // Fixed base fee (bps)
    uint public constant MAX_FEE = 5000;
    uint private constant MIN_MARKET_CAPITAL = 10_000e18;
    uint8 internal constant MAX_SIDES = 12;
    uint constant E_NUM = 2718281828;
    uint constant E_DEN = 1000000000;

    // Oracle type flags
    uint8 public constant ORACLE_CHAINLINK = 3;
    uint8 public constant ORACLE_CRV = 2;
    uint8 public constant ORACLE_DSR_RATE = 1;
    error StaleOracle();
    error BadPrice();

    function depositFee(uint amount, uint bps)
        public pure returns (uint) {
        return FullMath.mulDiv(
            amount, bps, 10000);
    }

    /// @dev fee(X) = max(0, totalExposure - riskX)
    ///      where totalExposure = Σ(share_i × risk_i) across all tokens
    ///      Withdrawing the depegged token → fee = 0 (heals basket)
    ///      Withdrawing a healthy token    → fee = basket's depeg exposure
    ///      Equal risk across all tokens   → fee = BASE (no selective advantage)
    /// @param thisRisk calcRisk score for the token being withdrawn (bps)
    function calcFee(uint thisRisk,
        uint totalExposure) public pure returns (uint) {
        if (totalExposure <= thisRisk) return BASE;
        uint fee = totalExposure - thisRisk;
        if (fee < BASE) return BASE;
        return fee > MAX_FEE ? MAX_FEE : fee;
    }

    /// @notice risk score from prediction market data
    /// @dev Simple capital-ratio model matching Hook's Types.DepegStats
    /// @param s Depeg stats from prediction market hook
    /// @return Risk score in basis points
    /// (0 = safe, 10000 = definitely depegging)
    function calcRisk(Types.DepegStats memory s)
        internal pure returns (uint) {
        if (s.depegged) return 10000;

        bool hasPrior = s.avgConf > 0;
        uint prior = hasPrior ? uint(s.avgConf) : 6500;
        if (s.capTotal == 0) return prior;

        uint capitalSignal = (uint(s.capOnSide) * 10000) / uint(s.capTotal);
        uint n = uint(s.capTotal) / MIN_MARKET_CAPITAL;
        if (n == 0) return prior;  // thin market → prior only
        // Thick market with no prior → pure capital signal
        if (!hasPrior) return capitalSignal;

        // Thick market with prior → Bayesian blend
        return (prior + n * capitalSignal) / (1 + n);
    }

    function calcFeeL1(address token, uint idx,
        uint[13] memory deps, address[] memory stables,
        address hook) public view returns (uint) {
        uint totalDeposits = deps[12];
        if (totalDeposits == 0) return BASE;
        // Token without prediction market → no M1 signal, base fee only
        if (IHook(hook).stablecoinToSide(token) == 0) return BASE;
        // Get this token's risk score
        uint thisRisk; uint totalExposure;
        { Types.DepegStats memory stats = IHook(hook).getDepegStats(token);
          thisRisk = stats.side > 0 ? calcRisk(stats) : 0; }
        // Compute basket-wide totalExposure = Σ(share_i × risk_i)
        // Each term: (deps[i+1] / totalDeposits) × risk_i  →  in bps
        for (uint i = 0; i < stables.length; i++) {
            if (deps[i + 1] < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);

            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (deps[i + 1] * risk) / totalDeposits;
            }
        } return calcFee(thisRisk, totalExposure);
    }

    /// @notice Calculate fee with automatic index lookup
    /// @dev Wrapper around calcFeeL1 that finds index internally
    function calcFeeL1WithLookup(address token,
        uint[13] memory deps, address[] memory stables,
        address hook) external view returns (uint) {
        uint len = stables.length;
        for (uint i; i < len;) {
            if (stables[i] == token)
                return calcFeeL1(token,
                i, deps, stables, hook);
            unchecked { ++i; }
        } return 0;
    }

    /// @notice Find token with highest imbalance score (fee)
    /// @dev Higher fee = more overweight + risky = priority to reduce
    /// @return idx Index of most imbalanced token
    /// @return fee Imbalance score (higher = reduce first)
    /// @return excess Amount over equal weight (18 dec)
    function getMostImbalanced(uint[13] memory deps,
        address[] memory stables, address hook) external
        view returns (uint idx, uint fee, uint excess) {
        uint len = stables.length; uint high;
        uint total = deps[12];
        if (total == 0)
        return (0, 0, 0);
        for (uint i; i < len;) {
            if (deps[i + 1] > 100 * WAD) {
                uint f = calcFeeL1(stables[i],
                        i, deps, stables, hook);
                if (f > high) { high = f; idx = i; }
            } unchecked { ++i; }
        } fee = high;
        uint eq = total / len;
        if (deps[idx + 1] > eq)
            excess = deps[idx + 1] - eq;
    }

    // ─── LMSR ────────────────────────────────────

    function price(int128[MAX_SIDES] memory q,
        uint8 n, int128 b, uint8 side) public
        pure returns (uint p) {
        int256 maxQ = _max(q, n);
        uint eSide; uint eSum;
        for (uint8 j; j < n; j++) {
            uint ej = _expNorm(q[j], maxQ, b);
            eSum += ej;
            if (j == side) eSide = ej;
        }
        if (eSum == 0) return WAD / n;
        p = (eSide * WAD) / eSum;
    }

    /// @notice Cost of buying `delta` tokens on `side`
    /// @return c Unsigned cost in WAD
    function cost(int128[MAX_SIDES] memory q, uint8 n,
        int128 b, uint8 side, int128 delta) public
        pure returns (uint c) { int128[MAX_SIDES] memory qA;
        uint lseBefore = _logSumExp(q, n, b);
        for (uint8 j; j < n; j++) qA[j] = q[j];
        qA[side] += delta;
        uint lseAfter = _logSumExp(qA, n, b);
        uint bAbs = uint(int256(b));
        c = lseAfter >= lseBefore
            ? (bAbs * (lseAfter - lseBefore)) / WAD
            : (bAbs * (lseBefore - lseAfter)) / WAD;
    }

    /// @dev exp((q_j − maxQ) / b),
    /// result WAD-scaled. arg ≤ 0.
    function _expNorm(int128 qj,
        int256 maxQ, int128 b)
        internal pure returns (uint) {
        int256 d = int256(qj) - maxQ; // ≤ 0
        if (d == 0) return WAD;
        uint absD = uint(-d);
        uint absB = uint(int256(b));
        // exp(-x) < 1 wei (WAD) when x > ~41.4
        // (18 × ln(10)). Safe margin at 100.
        if (absD / absB > 100) return 0;
        (uint pN, uint pD) =
            AnalyticMath.pow(E_NUM,
             E_DEN, absD, absB);
        if (pN == 0) return 0;
        return (pD * WAD) / pN;
         // 1 / exp(|d|/b)
    }

    /// @dev max/b + ln(Σ exp((q_j−max)/b))  in WAD
    function _logSumExp(int128[MAX_SIDES] memory q,
      uint8 n, int128 b) internal pure returns (uint) {
        int256 maxQ = _max(q, n); uint sum; uint lnWad;
        for (uint8 j; j < n; j++)
            sum += _expNorm(q[j], maxQ, b);
        // ln(sum) where sum is WAD-scaled
        if (sum > WAD) { (uint lnN, uint lnD) =
                   AnalyticMath.log(sum, WAD);
                    lnWad = (lnN * WAD) / lnD;
        } // else ln(≤1) ≤ 0, clamp to 0
        // add back maxQ / b
        uint bAbs = uint(int256(b));
        if (maxQ >= 0)
            lnWad += (uint(maxQ) * WAD) / bAbs;
        else {
            uint sub = (uint(-maxQ) * WAD) / bAbs;
            lnWad = lnWad > sub ? lnWad - sub : 0;
        } return lnWad;
    }

    function _max(int128[MAX_SIDES] memory q, uint8 n)
        internal pure returns (int256 m) {
        m = int256(q[0]);
        for (uint8 j = 1; j < n; j++)
            if (int256(q[j]) > m) m = int256(q[j]);
    }

    // ─── L2 fee helpers ────────────

    struct StakedPairs {
        uint8[4] base;    // Base token indices
        uint8[4] staked;  // Corresponding staked token indices
    }

    function getStakedPrice(address oracle, uint8 oracleType)
        public view returns (uint price) {
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

    function getBaseIndex(uint idx,
        StakedPairs memory pairs)
        internal pure returns (uint) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return pairs.base[i];

        return idx;
    }

    function getCombinedDeposits(uint base, uint[14] memory deps,
        StakedPairs memory pairs) internal pure returns (uint) {
        uint combined = deps[base + 2];
        for (uint i = 0; i < 4; i++)
            if (pairs.base[i] == base) {
                combined += deps[pairs.staked[i] + 2];
                break;
            }

        return combined;
    }

    function isStakedToken(uint idx,
        StakedPairs memory pairs)
        internal pure returns (bool) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return true;

        return false;
    }

    function calcFeeWithPairs(uint idx, uint[14] memory deps,
        StakedPairs memory pairs, address[] memory stables,
        address hook) external view returns (uint) {
        uint base = getBaseIndex(idx, pairs);
        if (IHook(hook).stablecoinToSide(stables[base]) == 0) return BASE;

        Types.DepegStats memory stats = IHook(hook).getDepegStats(stables[base]);
        if (stats.side == 0) return BASE;

        uint totalDeposits = deps[1];
        if (totalDeposits == 0) return BASE;

        uint thisRisk = calcRisk(stats);

        uint totalExposure;
        for (uint i = 0; i < stables.length; i++) {
            if (isStakedToken(i, pairs)) continue;
            uint combined = getCombinedDeposits(i, deps, pairs);
            if (combined < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);
            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (combined * risk) / totalDeposits;
            }
        }
        return calcFee(thisRisk, totalExposure);
    }

    function calcFeeUni(uint idx, uint[7] memory deps, address[] memory stables,
        address hook) external view returns (uint) {
        uint base = (idx == 3) ? 2 : idx; // sUSDS maps to USDS
        if (IHook(hook).stablecoinToSide(stables[base]) == 0) return BASE;
        Types.DepegStats memory stats = IHook(hook).getDepegStats(stables[base]);
        if (stats.side == 0 || deps[1] == 0) return BASE;

        uint thisRisk = calcRisk(stats);

        uint totalExposure;
        for (uint i = 0; i < 5; i++) {
            if (i == 3) continue; // skip sUSDS, count USDS
            uint dep = (i == 2) ? deps[4] + deps[5] : deps[i + 2];
            if (dep < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);
            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (dep * risk) / deps[1];
            }
        }
        return calcFee(thisRisk, totalExposure);
    }

    function calcFeePoly(uint idx, uint[8] memory deps, address[] memory stables,
        address hook) external view returns (uint) {
        if (IHook(hook).stablecoinToSide(stables[idx]) == 0) return BASE;
        Types.DepegStats memory stats = IHook(hook).getDepegStats(stables[idx]);
        if (stats.side == 0 || deps[1] == 0) return BASE;

        uint thisRisk = calcRisk(stats);

        uint totalExposure;
        for (uint i = 0; i < 6; i++) {
            if (deps[i + 2] < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);
            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (deps[i + 2] * risk) / deps[1];
            }
        }
        return calcFee(thisRisk, totalExposure);
    }

    function calcWithdrawAmounts(uint amount,
        uint[14] memory deposits, int indexToSkip,
        bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices,
        uint16 sixDecMask) public pure
        returns (uint[12] memory w) {
        uint totalDeposits = deposits[1];
        if (totalDeposits == 0) return w;

        for (uint i = 0; i < 12; i++) {
            if (int(i) == indexToSkip) continue;

            w[i] = _calcOne(amount, totalDeposits,
                deposits[i + 2], i, strict, prices,
                priceIndices, sixDecMask);
        }
    }

    function _calcOne(uint amount, uint total, uint dep,
        uint i, bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices,
        uint16 sixDecMask) internal pure returns (uint out) {
        if (dep == 0) return 0;
        uint share = FullMath.mulDiv(amount, dep, total);

        // Apply staked price conversion if this index has a price
        uint p;
        if (priceIndices[0] == i) p = prices[0];
        else if (priceIndices[1] == i) p = prices[1];
        else if (priceIndices[2] == i) p = prices[2];
        if (p > 0 && p != WAD)
            share = FullMath.mulDiv(share, WAD, p);

        // Apply 6-decimal divisor if bit is set
        bool isSixDec = (sixDecMask >> i) & 1 == 1;
        if (isSixDec) {
            share = share / 1e12;
            if (strict && share * 1e12 > dep)
                share = dep / 1e12;
        } else if (strict && share > dep) {
            share = dep;
        }

        out = share;
    }
}
