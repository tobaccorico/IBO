
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Jury} from "../Jury.sol";
import {Rover} from "../Rover.sol";
import {Basket} from "../Basket.sol";
import {VogueCore} from "../VogueCore.sol";
import {Types} from "../imports/Types.sol";
import {BasketLib} from "../imports/BasketLib.sol";
import {VogueUni as Vogue} from "./VogueUni.sol";

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

/// @title AuxUnichain
/// @notice Unichain: 5 stables [USDC, USDT, USDS, sUSDS, FRAX]
/// USDC/USDT -> Morpho vaults, USDS/sUSDS/FRAX -> direct
/// Has Rover (V3), NO AAVE, NO Amp
contract AuxUni is // Auxiliary
    Ownable, ReentrancyGuard {
    uint constant target = 500000 * WAD;
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
    Jury public jury;

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
                              elapsed, amounts[1]);
            metrics = stats;
        } return (stats.total,
                  stats.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function setQuid(address _quid, address _jury,
        address _court) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        QUID.setup(_court, _jury); jury = Jury(_jury);
        USDC.approve(address(v3Router), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
        WETH.approve(address(v3Router), type(uint).max);
        if (address(V3) != address(0)) {
            WETH.approve(address(V3), type(uint).max);
            USDC.approve(address(V3), type(uint).max);
        }
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
        Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();
        bool stable; bool zeroForOne;
        stable = toIndex[token] > 0;
        if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
            max = CORE.POOLED_USD();
        }
        else { max = CORE.POOLED_ETH();
            zeroForOne = V4.token1isETH();
            amount = token == address(QUID) ?
               QUID.turn(msg.sender, amount):
               deposit(msg.sender, token, amount);

            token = address(0);
        }
        max = BasketLib.routeSwap(ctx, address(CORE),
            address(V3), sqrtPriceX96, zeroForOne,
            token, amount, max, getTWAP(1800),
            getTWAP(0), msg.sender);
            require(max >= minOut);
    }

    function _buildContext() internal view returns (Types.AuxContext memory) {
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), v3Router: v3Router,
            weth: address(WETH), usdc: address(USDC), vault: address(wethVault),
            v4: address(V4), v3Fee: v3Fee, isAAVE: false });
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
        (uint total, ) = get_metrics(false);
        uint reserved = CORE.POOLED_ETH();
        uint pooledUSD = CORE.POOLED_USD() * 1e12;
        uint usdAvailable = total > pooledUSD ?
                            total - pooledUSD : 0;

        uint ethAvailable = wethVault.maxWithdraw(address(this));
        uint ethExcess = ethAvailable > reserved ?
                         ethAvailable - reserved : 0;

        uint ethValue = FullMath.mulDiv(
                  ethExcess, price, WAD);

        amount = QUID.turn(msg.sender, Math.min(amount,
                             usdAvailable + ethValue));

        if (amount == 0) return;
        uint taken = _take(msg.sender,
        amount, address(QUID), false);

        if (taken < amount) {
            uint ethToUse = Math.min(FullMath.mulDiv(
              amount - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                uint received = V4.takeETH(ethToUse,
                                     address(this));

                WETH.deposit{value: received}();
                require(!BasketLib.isV3Manipulated(address(v3PoolWETH),
                                                  token1isWETH, price));

                received = BasketLib.sourceExternalUSD(_buildContext(),
                                         address(V3), received, price);

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
        amounts[2] = (balance > reserved ? balance - reserved : 0) * 1e12;

        reserved *= 1e12;
        balance = deposits[stables[0]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        // USDT - Morpho vault (6 dec)
        reserved = untouchables[stables[1]];
        balance = IERC4626(vaults[stables[1]]).maxWithdraw(address(this));
        amounts[3] = (balance > reserved ? balance - reserved : 0) * 1e12;

        reserved *= 1e12;
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
        return BasketLib.calcFeeUni(idx,
            deps, stables, address(jury));
    }

    function _take(address who, uint amount, address token,
        bool strict) internal returns (uint sent) {
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
            reserved = untouchables[token];
            max = max > reserved ? max - reserved : 0;
            uint fee = max > 0 ? (getFee(token) * WAD) / 10000 : 0;

            uint needed = (fee > 0 && fee < WAD / 10) ?
                FullMath.mulDiv(amount, WAD + fee, WAD) : amount;

            indexToSkip = int(index - 1);
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (strict) {
                    untouchables[token] -= withdrawn;
                    untouchable -= (index < 3) ? withdrawn * 1e12 : withdrawn;
                }
                if (fee > 0)
                    withdrawn = FullMath.mulDiv(
                      withdrawn, WAD - fee, WAD);

                deposits[token] -= BasketLib.scaleTokenAmount(withdrawn, token, true);
                return withdrawn;
            } else {
                withdrawn = _withdraw(who, index, max);
                if (strict) {
                    untouchables[token] -= withdrawn;
                    untouchable -= (index < 3) ? withdrawn * 1e12 : withdrawn;
                }
                if (fee > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - fee, WAD);
                else sent = withdrawn;

                amount -= sent;
                deposits[token] -= BasketLib.scaleTokenAmount(sent, token, true);
                if (strict) return sent;
            }
        } amount = BasketLib.scaleTokenAmount(amount, token, true);
        if (amount > 0) { uint[7] memory amounts = get_deposits();
            amount = !strict ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount, amounts,
                                    indexToSkip, strict);
        }
    }

    function _executeProRata(address who, uint amount,
        uint[7] memory amounts, int indexToSkip,
        bool strict) private returns (uint sent) {
        if (amounts[1] == 0 || amount == 0) return 0;
        for (uint i = 0; i < 5; i++) {
            if (int(i) == indexToSkip || amounts[i + 2] == 0) continue;
            uint dep = amounts[i + 2];
            uint share = FullMath.mulDiv(amount,
                FullMath.mulDiv(WAD, dep, amounts[1]), WAD);
            if (!strict && share > dep) share = dep;
            if (i < 2) share /= 1e12;
            if (share > 0) sent += _executeWithdraw(who, i, share, strict);
        }
    }

    function _executeWithdraw(address who, uint i,
        uint amt, bool strict) private returns (uint out) {
        uint divisor = (i < 2) ? 1e12 : 1;
        address stable = stables[i]; out = amt * divisor;
        deposits[stable] -= out;
        if (strict) {
            untouchables[stable] -= amt;
            untouchable -= out;
        }
        if (i < 2)
            out = _withdraw(who, i + 1, amt) * divisor;
        else
            IERC20(stable).transfer(who, amt);
    }

    function take(address who, uint amount,
        address token, bool strict) public
        onlyUs returns (uint) { return _take(
                  who, amount, token, strict);
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
        } else {
            sent = amount;
            IERC20(stables[toIndex - 1]).transfer(to, amount);
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
        if (untouchable > 0
        && msg.sender == address(QUID)) {
            if (untouchable < target) {
                uint cut = BasketLib.depositFee(
                       usd, untouchable, target);

                untouchables[token] += cut; usd -= cut;
                untouchable += BasketLib.scaleTokenAmount(
                                         cut, token, true);
            }
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
