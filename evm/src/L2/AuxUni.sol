
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rover} from "../Rover.sol";
import {Basket} from "../Basket.sol";
import {VogueCore} from "../VogueCore.sol";

import {Types} from "../imports/Types.sol";
import {VogueUni as Vogue} from "./VogueUni.sol";
import {BasketLib} from "../imports/BasketLib.sol";
import {FeeLib} from "../imports/FeeLib.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";

import {IUniswapV3Pool} from "../imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IV3SwapRouter as ISwapRouter} from "../imports/v3/IV3SwapRouter.sol";

interface IHook {
    function getDepegStats(address token)
        external view returns (Types.DepegStats memory);
}

/// @title AuxUnichain
/// @notice Unichain: 5 stables [USDC, USDT, USDS, sUSDS, FRAX]
/// USDC/USDT -> Morpho vaults, USDS/sUSDS/FRAX -> direct
/// Has Rover (V3), NO AAVE, NO Amp
contract AuxUni is // Auxiliary
    Ownable, ReentrancyGuard {
    BasketLib.Metrics internal metrics;
    WETH9 public WETH; Rover V3;
    IERC20 USDC; Basket QUID;
    Vogue V4; VogueCore CORE;
    bool public token1isWETH;
    address[] public stables;

    mapping(address => address) public vaults;
    mapping(address => uint) internal deposits;
    mapping(address => uint) internal toIndex;
    mapping(address => uint) public untouchables;

    IERC4626 public wethVault;
    IUniswapV3Pool v3PoolWETH;
    address internal v3Router;
    uint constant WAD = 1e18;
    uint public untouchable;
    uint24 internal v3Fee;

    error Unauthorized();
    error InvalidToken();
    error Untouchable();
    error InvalidIndex();
    error NoDeposit();

    uint lastBlock;
    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != address(this))
                revert Unauthorized(); _;
    }

    constructor(address _vogue, address _core,
        address _wethVault, address _amp,
        address _aave, address _v3poolWETH,
        address _v3router, address _v3,
        address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {

        stables = _stables;
        lastBlock = block.number - 1;
        wethVault = IERC4626(_wethVault);

        v3PoolWETH = IUniswapV3Pool(_v3poolWETH);
        address token0 = v3PoolWETH.token0();
        address token1 = v3PoolWETH.token1();
        v3Fee = v3PoolWETH.fee();
        v3Router = _v3router;

        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true;
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        }

        V4 = Vogue(payable(_vogue));
        CORE = VogueCore(_core);
        if (_v3 != address(0))
            V3 = Rover(payable(_v3));
        // USDC, USDT -> Morpho vaults
        for (uint i = 0; i < 2; i++) {
            vaults[stables[i]] = _vaults[i];
            IERC20(stables[i]).approve(
            _vaults[i], type(uint).max);
            toIndex[stables[i]] = i + 1;
        }
        // USDS, sUSDS, FRAX -> direct
        for (uint i = 2; i < stables.length; i++) {
            toIndex[stables[i]] = i + 1;
        }
    } fallback() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[7] memory amounts = get_deposits();
            stats = BasketLib.computeMetrics(stats,
                elapsed, amounts[0], amounts[1], amounts[1]);
            metrics = stats;
        } return (stats.total,
                  stats.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function setQuid(address _quid) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        USDC.approve(address(v3Router), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
        WETH.approve(address(v3Router), type(uint).max);
        if (address(V3) != address(0)) {
            WETH.approve(address(V3), type(uint).max);
            USDC.approve(address(V3), type(uint).max);
        }
    }
    function getStables() external view
        returns (address[] memory) {
        // Return only base stables (not staked wrappers)
        // for Hook/UMA market registration.
        // sUSDS (index 3) shares a side with USDS.
        address[] memory bases = new address[](4);
        bases[0] = stables[0]; // USDC
        bases[1] = stables[1]; // USDT
        bases[2] = stables[2]; // USDS
        bases[3] = stables[4]; // FRAX
        return bases;
    }

    function getTWAP(uint32 period)
        public view returns (uint price) {
        uint32[] memory secondsAgos = new uint32[](2);
        int56[] memory tickCumulatives; bool token0isUSD;
        if (period == 0) { secondsAgos[0] = 1800; secondsAgos[1] = 0;
            (tickCumulatives, ) = v3PoolWETH.observe(secondsAgos);
            period = 1800; token0isUSD = token1isWETH;
        } else {
            secondsAgos[0] = period; secondsAgos[1] = 0;
            tickCumulatives = CORE.observe(secondsAgos);
            token0isUSD = V4.token1isETH();
        }
        price = BasketLib.ticksToPrice(tickCumulatives[0],
                 tickCumulatives[1], period, token0isUSD);
    }

    /// @param token either token we are paying or want to get
    /// @param forETH ^ for $ --> ETH, opposite for ETH --> $
    /// @param amount Amount to swap (either ETH, QD, or $)
    /// @param minOut Minimum output (slippage protection)
    function swap(address token, bool forETH, uint amount, uint minOut)
        public payable nonReentrant returns (uint max) {
        bool stable; bool zeroForOne;
        Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();
        stable = toIndex[token] > 0;
        if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
            max = CORE.POOLED_USD();
        }
        else { max = CORE.POOLED_ETH();
            zeroForOne = V4.token1isETH();
            if (token == address(QUID)) {
                (uint burned, uint seedBurned) = QUID.turn(
                                        msg.sender, amount);
                amount = burned;
                if (seedBurned > 0) {
                    for (uint i = 0; i < stables.length; i++) {
                        uint share = FullMath.mulDiv(
                            untouchables[stables[i]],
                            seedBurned, burned);
                        _tip(share, stables[i], -1);
                    }
                }
            } else amount = deposit(msg.sender,
                              token, amount);
            token = address(0);
        }
        (max,) = BasketLib.routeSwap(ctx,
            Types.RouteParams({ sqrtPriceX96: sqrtPriceX96,
                zeroForOne: zeroForOne, token: token,
                recipient: msg.sender, amount: amount,
                pooled: max, v4Price: getTWAP(1800),
                v3Price: getTWAP(0) }));
            require(max >= minOut);
    }

    function _buildContext() internal view returns (Types.AuxContext memory) {
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), v3Router: v3Router,
            weth: address(WETH), usdc: address(USDC), vault: address(wethVault),
            v4: address(V4), core: address(CORE), rover: address(V3),
            v3Fee: v3Fee, hub: address(0), isAAVE: false });
    }

    function arbETH(uint shortfall)
        public onlyUs returns (uint got) {
        (got,) = BasketLib.arbETH(_buildContext(),
                          shortfall, getTWAP(0));
    }

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount)
        external { uint price = getTWAP(1800);
        uint usdAvailable; uint ethExcess;
        { (uint total, ) = get_metrics(false);
            uint pooledETH = CORE.POOLED_ETH();
            uint pooledUSD = CORE.POOLED_USD() * 1e12;
            usdAvailable = total > pooledUSD ?
                                total - pooledUSD : 0;

            uint ethAvailable = wethVault.maxWithdraw(address(this));
            ethExcess = ethAvailable > pooledETH ?
                             ethAvailable - pooledETH : 0;
        }
        uint reserved = Math.min(amount, usdAvailable
            + FullMath.mulDiv(ethExcess, price, WAD));

        (uint burned, uint seedBurned) = QUID.turn(
        msg.sender, Math.min(reserved, usdAvailable));

        if (burned == 0) return;
        uint taken = _take(msg.sender,
        burned, address(QUID), seedBurned);
        if (taken < reserved) {
            uint ethToUse = Math.min(FullMath.mulDiv(
              reserved - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                uint received = V4.takeETH(ethToUse,
                                     address(this));

                WETH.deposit{value: received}();
                require(!BasketLib.isV3Manipulated(address(v3PoolWETH),
                                                  token1isWETH, price));

                received = BasketLib.sourceExternalUSD(_buildContext(),
                                                      received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    /// @notice [raw, total, USDC, USDT, USDS, sUSDS, FRAX]
    function get_deposits() public view
        returns (uint[7] memory amounts) {
        uint balance; uint reserved;
        reserved = untouchables[stables[0]];
        balance = IERC4626(vaults[stables[0]]).maxWithdraw(address(this));
        { uint res6 = reserved / 1e12; // scale 18→6 for comparison
          amounts[2] = (balance > res6 ? balance - res6 : 0) * 1e12; }

        balance = deposits[stables[0]]; // 18-dec like reserved
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        // USDT - Morpho vault (6 dec)
        reserved = untouchables[stables[1]];
        balance = IERC4626(vaults[stables[1]]).maxWithdraw(address(this));
        { uint res6 = reserved / 1e12;
          amounts[3] = (balance > res6 ? balance - res6 : 0) * 1e12; }

        balance = deposits[stables[1]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        amounts[1] = amounts[2] + amounts[3];

        // USDS - direct (18 dec)
        reserved = untouchables[stables[2]];
        balance = IERC20(stables[2]).balanceOf(address(this));
        amounts[4] = balance > reserved ? balance - reserved : 0;
        amounts[0] += amounts[4];
        amounts[1] += amounts[4];

        // sUSDS - direct (18 dec), no oracle - treat as 1:1
        reserved = untouchables[stables[3]];
        balance = IERC20(stables[3]).balanceOf(address(this));
        amounts[5] = balance > reserved ? balance - reserved : 0;
        amounts[0] += amounts[5];
        amounts[1] += amounts[5];

        // FRAX - direct (18 dec)
        reserved = untouchables[stables[4]];
        balance = IERC20(stables[4]).balanceOf(address(this));
        amounts[6] = balance > reserved ? balance - reserved : 0;
        amounts[0] += amounts[6];
        amounts[1] += amounts[6];
    }

    function getFee(address token)
        public view returns (uint) {
        uint idx = type(uint).max;
        for (uint i = 0; i < stables.length; i++)
        if (stables[i] == token) { idx = i; break; }
        if (idx == type(uint).max) return 0;
        uint[7] memory deps = get_deposits();
        return FeeLib.calcFeeUni(idx, deps,
                stables, address(QUID.HOOK()));
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination; whatever's in there: yours to take
    function _take(address who, uint amount, address token,
        uint seed) internal returns (uint sent) {
        int indexToSkip = -1;
        uint withdrawn; uint reserved;
        if (token != address(QUID)) {
            uint index = toIndex[token]; uint max;
            if (index == 0 || index > 5) revert InvalidIndex();
            if (index < 3) {
                max = IERC4626(vaults[token]).maxWithdraw(address(this));
            } else {
                max = IERC20(token).balanceOf(address(this));
            }
            reserved = BasketLib.scaleTokenAmount(
                untouchables[token], token, false); // native dec
            max = max > reserved ? max - reserved : 0;
            uint fee = max > 0 ? (getFee(token) * WAD) / 10000 : 0;

            uint needed = (fee > 0 && fee < WAD / 10) ?
                FullMath.mulDiv(amount, WAD - fee, WAD) : amount;

            // Haircut applies to ALL redeemers during depeg, not just seed
            { address hookAddr = address(QUID.HOOK());
              if (hookAddr != address(0)) {
                Types.DepegStats memory ds = IHook(hookAddr).getDepegStats(token);
                if (ds.depegged) { uint retained = FullMath.mulDiv(
                                    needed, QUID.getHaircut(), 10000);
                                    needed -= retained;
                }
              }
            }
            indexToSkip = int(index - 1);
            if (seed > 0) { _tip(seed, token, -1);
                sent = _withdraw(who, index, needed);
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(sent, token, true);
            }
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (fee > 0)
                    withdrawn = FullMath.mulDiv(
                      withdrawn, WAD - fee, WAD);

                { uint scaled = BasketLib.scaleTokenAmount(withdrawn, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(withdrawn, token, true);
            } else {
                withdrawn = _withdraw(who, index, max);
                if (fee > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - fee, WAD);
                else sent = withdrawn;

                amount -= sent;
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                sent = BasketLib.scaleTokenAmount(sent, token, true);
            }
        } amount = BasketLib.scaleTokenAmount(amount, token, true);
        if (amount > 0) { uint[7] memory amounts = get_deposits();
            amount = seed == 0 ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount, amounts,
                                    indexToSkip, seed);
        }
    }

    function _executeProRata(address who, uint amount,
        uint[7] memory amounts, int indexToSkip,
        uint seed) private returns (uint sent) {
        if (amounts[1] == 0 || amount == 0) return 0;
        uint haircutBps; address hookAddr = address(QUID.HOOK());
        if (hookAddr != address(0)) haircutBps = QUID.getHaircut();
        for (uint i = 0; i < 5; i++) {
            if (int(i) == indexToSkip || amounts[i + 2] == 0) continue;
            uint dep = amounts[i + 2];
            uint share = FullMath.mulDiv(amount,
                FullMath.mulDiv(WAD, dep, amounts[1]), WAD);
            if (seed == 0 && share > dep) share = dep;
            if (seed > 0) _tip(FullMath.mulDiv(share,
                                seed, amount), stables[i], -1);
            if (hookAddr != address(0)) {
                Types.DepegStats memory ds = IHook(hookAddr).getDepegStats(stables[i]);
                if (ds.depegged) share -= FullMath.mulDiv(share, haircutBps, 10000);
            }
            if (i < 2) share /= 1e12;
            if (share > 0) sent += _executeWithdraw(who, i, share);
        }
    }

    function _executeWithdraw(address who, uint i,
        uint amt) private returns (uint out) {
        uint divisor = (i < 2) ? 1e12 : 1;
        address stable = stables[i]; out = amt * divisor;
        deposits[stable] -= Math.min(deposits[stable], out);
        if (i < 2)
            out = _withdraw(who, i + 1, amt) * divisor;
        else
            IERC20(stable).transfer(who, amt);
    }

    function take(address who, uint amount,
        address token, uint seed) public
        onlyUs returns (uint) { return _take(
                  who, amount, token, seed);
    }

    function _withdraw(address to,
        uint toIndex, uint amount)
        internal returns (uint sent) {
        if (amount == 0) return 0;
        if (toIndex < 3)  {
            address vault = vaults[stables[toIndex - 1]];
            (uint shares,
             uint assets) = BasketLib.calculateVaultWithdrawal(
                                                 vault, amount);
            if (shares == 0) return 0;
            sent = IERC4626(vault).redeem(
                 shares, to, address(this));
        } else { sent = amount;
            IERC20(stables[toIndex - 1]).transfer(
                                       to, amount);
        }
    }

    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        uint index = toIndex[token];
        if (index == 0) revert InvalidIndex();
        usd = Math.min(amount,
        IERC20(token).allowance(from,
                    address(this)));

        IERC20(token).transferFrom(from,
                    address(this), usd);
        if (usd == 0) revert NoDeposit();

        amount = BasketLib.scaleTokenAmount(
                           usd, token, true);

        deposits[token] += amount;
        if (index < 3)
            IERC4626(vaults[token]).deposit(usd,
                                   address(this));
        if (msg.sender == address(QUID)) {
            uint _target = QUID.target();
            if (untouchable < _target) {
                uint fee = BasketLib.seedFee(usd, untouchable,
                                    _target, getAverageYield());
                if (fee > 0) {
                    _tip(fee, token, 1);
                }
            }
        }
    } function _tip(uint cut, address token, int sign) internal {
        cut = BasketLib.scaleTokenAmount(cut, token, true);
        if (sign > 0) {
            untouchables[token] += cut; untouchable += cut;
        } else {
            cut = Math.min(cut, untouchables[token]);
            untouchables[token] -= cut;
            untouchable -= Math.min(untouchable, cut);
        }
    }

    function _depositETH(address sender,
        uint amount) internal returns (uint sent) {
        if (msg.value > 0) { sent = msg.value;
            WETH.deposit{value: msg.value}();
        }
        if (amount > 0) { uint available = Math.min(
                WETH.allowance(sender, address(this)),
                WETH.balanceOf(sender));

            uint took = Math.min(amount, available);
            if (took > 0) { WETH.transferFrom(sender,
                                address(this), took);
                                        sent += took;
            }
        } require(sent > 0);
    }
}
