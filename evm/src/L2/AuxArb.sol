
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "../Amp.sol";
import {Rover} from "../Rover.sol";
import {Vogue} from "../Vogue.sol";
import {Basket} from "../Basket.sol";

import {VogueCore} from "../VogueCore.sol";
import {Types} from "../imports/Types.sol";
import {BasketLib} from "../imports/BasketLib.sol";
import {FeeLib} from "../imports/FeeLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "../imports/v3/ISwapRouter.sol";

import {IUniswapV3Pool} from "../imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface IHook {
    function getDepegStats(address token)
        external view returns (Types.DepegStats memory);
}

interface IHub {
    function getAssetId(address underlying)
            external view returns (uint256);
}

interface AAVEv4 {
    function getReserveId(address hub,
    uint assetId) external returns (uint);

    function withdraw(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint, uint);

    function supply(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint256, uint256);

    function getUserSuppliedAssets(uint reserveId,
        address user) external view returns (uint);
}

contract AuxArb is // Auxiliary
    Ownable, ReentrancyGuard {
    address[] public stables;
    WETH9 public WETH; Rover V3;
    bool public token1isWETH;
    VogueCore internal CORE;
    uint24 internal v3Fee;

    IERC20 internal USDC;
    Basket internal QUID;
    address internal DSR;
    address internal CRV;
    Vogue internal V4;

    mapping(address => uint) internal untouchables;
    mapping(address => address) internal vaults;
    mapping(address => uint) internal deposits;
    mapping(address => uint) internal toIndex;

    BasketLib.Metrics internal metrics;
    IUniswapV3Pool internal v3PoolWETH;
    address internal v3Router;
    uint internal untouchable;
    uint constant WAD = 1e18;

    error NotInitialized();
    error Unauthorized();
    error InvalidToken();
    error Untouchable();
    error NoDeposit();

    IPool internal AAVE;
    Amp internal AMP;
    uint lastBlock;
    uint public vogueETH; // WETH attributed to Vogue pool
    uint internal _lastTotalETH;
    AAVEv4 internal SPOKE;
    IHub internal HUB;

    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != address(this))
                revert Unauthorized(); _;
    }
    modifier onlyAmped {
        if (address(AMP) == address(0))
            revert NotInitialized(); _;
    }

    // Arb stables: [USDC, USDT, DAI,
    // GHO, FRAX, USDE, USDS, CRVUSD,
    // SFRAX, SUSDS, SUSDE, SCRVUSD]

    /// @notice init (plug) Aux with addresses
    /// @dev optional: V3 rover & AAVE amp...
    /// @param _vogue UniV4 rover entrypoint
    /// @param _core UniV4 rover logic
    /// @param _aave AAVE v3 pool
    /// @param _v3poolWETH V3 pool
    /// @param _v3router V3 router for swaps
    /// @param _v3 our wrapper around UniV3
    constructor(address _vogue, address _core, address _amp,
        address _aave, address _v3poolWETH, address _v3router,
        address _v3, address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {
        stables = _stables;

        AAVE = IPool(_aave); uint i;
        lastBlock = block.number - 1;

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
        if (_amp != address(0))
            AMP = Amp(payable(_amp));
        if (_v3 != address(0))
            V3 = Rover(payable(_v3));
        for (; i < 2;) {
            vaults[stables[i]] = _vaults[i];
            IERC20(stables[i]).approve(
            _vaults[i], type(uint).max);
            toIndex[stables[i]] = i + 1;
            unchecked { ++i; }
        }
        while (i < 5) {
            vaults[stables[i]] = _vaults[i];
            IERC20(stables[i]).approve(
            address(AAVE), type(uint).max);
            toIndex[stables[i]] = i + 1; unchecked { ++i; }
        }
        uint len = stables.length;
        while (i < len) {
            toIndex[stables[i]] = i + 1; unchecked { ++i; }
        }
        DSR = 0x73750DbD85753074e452B2C27fB9e3B0E75Ff3B8;
        CRV = 0x3195A313F409714e1f173ca095Dba7BfBb5767F7;
    } fallback() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[14] memory amounts = _fee_deposits();
            stats = BasketLib.computeMetrics(stats,
                elapsed, amounts[0], amounts[1], amounts[1]);
            metrics = stats;
        } return (stats.total,
                  stats.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function _getPrice(uint index) internal
        view returns (uint price) {
        if (index == 10) {
            price = FeeLib.getStakedPrice(
                0x605EA726F0259a30db5b7c9ef39Df9fE78665C44,
                FeeLib.ORACLE_CHAINLINK);
        } else if (index == 11) {
            price = FeeLib.getStakedPrice(
                CRV, FeeLib.ORACLE_CRV);
        } else if (index == 9) {
            price = FeeLib.getStakedPrice(
                DSR, FeeLib.ORACLE_DSR_RATE);
        }
    }

    function setQuid(address _quid) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        USDC.approve(address(v3Router), type(uint).max);
        WETH.approve(address(v3Router), type(uint).max);
        WETH.approve(address(AAVE), type(uint).max);
        WETH.approve(address(AMP), type(uint).max);
        USDC.approve(address(AMP), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        USDC.approve(address(V3), type(uint).max);
    }
    function getStables() external view
        returns (address[] memory) {
        // Return only base stables (not staked wrappers)
        // for Hook/UMA market registration. Staked tokens
        // share sides with their base via StakedPairs.
        address[] memory bases = new address[](8);
        for (uint i; i < 8; i++) bases[i] = stables[i];
        return bases;
    }

    /// @notice No USYC on Arbitrum
    function getUSYCRedeemable() external pure returns (uint) {
        return 0;
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

    function v3Fair(uint twapPrice) public view returns (bool) {
        return !BasketLib.isV3Manipulated(address(v3PoolWETH),
                                      token1isWETH, twapPrice);
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
        } _syncETH();
        uint poolSupplied;
        (max, poolSupplied) = BasketLib.routeSwap(ctx,
            Types.RouteParams({ sqrtPriceX96: sqrtPriceX96,
                zeroForOne: zeroForOne, token: token,
                recipient: msg.sender, amount: amount,
                pooled: max, v4Price: getTWAP(1800),
                v3Price: getTWAP(0) }));
            if (poolSupplied > 0) {
                vogueETH += poolSupplied;
                _lastTotalETH = _availableETH();
            }   require(max >= minOut);
    }

    function _buildContext() internal view returns (Types.AuxContext memory) {
        address aave = address(SPOKE) != address(0) ? address(SPOKE) : address(AAVE);
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), hub: address(HUB),
            v3Router: v3Router, weth: address(WETH), usdc: address(USDC),
            vault: aave, v4: address(V4), core: address(CORE),
            rover: address(V3), v3Fee: v3Fee, isAAVE: true });
    }

    function _availableETH() internal returns (uint) {
        if (address(SPOKE) == address(0))
            return BasketLib.aaveAvailableV3(
                address(AAVE), address(WETH));
        else { uint reserveId = SPOKE.getReserveId(address(HUB),
                                HUB.getAssetId(address(WETH)));
            return SPOKE.getUserSuppliedAssets(
                      reserveId, address(this));
        }
    }

    function _syncETH() internal {
        if (_lastTotalETH > 0) {
            uint avail = _availableETH();
            if (avail > _lastTotalETH)
                vogueETH += (avail - _lastTotalETH)
                          * vogueETH / _lastTotalETH;
            _lastTotalETH = avail;
        }
    }

    function _supplyAAVE(address asset, uint amount,
        address to, bool v4) internal returns (uint deposited) {
        if (asset == address(WETH)) _syncETH();
        deposited = BasketLib.supplyAAVE(v4 ? address(SPOKE) : address(AAVE),
                                        asset, amount, to, address(HUB));
        if (asset == address(WETH))
            _lastTotalETH = _availableETH();
    }

    function _withdrawAAVE(address asset, uint amount,
        address to, bool v4) internal returns (uint drawn) {
        if (asset == address(WETH)) _syncETH();
        drawn = BasketLib.withdrawAAVE(v4 ? address(SPOKE) : address(AAVE),
                                           asset, amount, to, address(HUB));
        if (asset == address(WETH))
            _lastTotalETH = _availableETH();
    }

    function vogueETHOp(uint amount, uint8 op)
        external returns (uint ret) {
        require(msg.sender == address(V4));
        if (op == 0) { // deposit
            WETH.transferFrom(msg.sender, address(this), amount);
            _supplyAAVE(address(WETH), amount, address(this),
                address(HUB) != address(0)); vogueETH += amount;
        } else if (op == 1) { // take
            amount = Math.min(amount, vogueETH);
            ret = _withdrawAAVE(address(WETH), amount,
            address(this), address(HUB) != address(0));
            vogueETH -= Math.min(ret, vogueETH);
            WETH.transfer(msg.sender, ret);
        } else { // sync
            _syncETH(); ret = vogueETH;
        }
    }

    function setV4(address _hub, address _spoke) external
        onlyOwner { require(!AMP.hasOpenDebt());
        uint i; uint[3] memory amounts;
        uint weth = _withdrawAAVE(address(WETH), _availableETH(),
                    address(this), address(HUB) != address(0));
        for (i = 0; i < 3; i++) {
            amounts[i] = _withdrawAAVE(stables[i + 2], 0,
            address(this), address(HUB) != address(0));
        } SPOKE = AAVEv4(_spoke); HUB = IHub(_hub);
        WETH.approve(_hub, type(uint).max);
        for (i = 0; i < 3; i++) {
            IERC20(stables[i + 2]).approve(
                  _hub, type(uint).max);
            _supplyAAVE(stables[i + 2], amounts[i],
                        address(this), true);
        } _supplyAAVE(address(WETH),
         weth, address(this), true);
        _lastTotalETH = _availableETH();
        AMP.setV4(_hub, _spoke);
        renounceOwnership();
    }

    function arbETH(uint shortfall)
        public onlyUs returns (uint got) {
        _syncETH();
        (got,) = BasketLib.arbETH(_buildContext(),
                            shortfall, getTWAP(0));
        if (got > 0) {
            vogueETH += got;
            _lastTotalETH = _availableETH();
        }
    }

    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable
        external { uint twapPrice = getTWAP(0);
        amount = _depositETH(msg.sender, amount);
        uint usdcNeeded = BasketLib.convert(amount, twapPrice, false);
        uint took = _take(address(this), usdcNeeded, address(USDC), 0);
        if (took <= usdcNeeded) {
            require(v3Fair(twapPrice));
            (uint more, uint used) = BasketLib.source(_buildContext(),
                usdcNeeded - took, amount, twapPrice, true);
                   took += more; amount -= used;

        } require(took >= usdcNeeded * 99 / 100);
        AMP.leverETH(msg.sender, amount, took / 1e12);
    }

    function leverUSD(uint amount, address token)
        external returns (uint usdcAmount) {
        usdcAmount = amount; uint160 sqrtPriceX96;
        if (token == address(USDC)) {
            USDC.transferFrom(msg.sender,
                address(this), usdcAmount);
        } else {
            (sqrtPriceX96,,,) = V4.repack();
            uint depositedAmount = deposit(
             msg.sender, token, usdcAmount);
            uint scale = IERC20(token).decimals() - 6;
            depositedAmount /= scale > 0 ? 10 ** scale : 1;

            // Swap stable → ETH → USDC through V4 pool
            CORE.swap(sqrtPriceX96, address(this),
            V4.token1isETH(), token, depositedAmount);
            uint ethReceived = address(this).balance;

            WETH.deposit{value: ethReceived}();
            _supplyAAVE(address(WETH), ethReceived,
            address(this), address(HUB) != address(0));

            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            !V4.token1isETH(), address(USDC), ethReceived);
            vogueETH += ethReceived;

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(v3Fair(twapPrice));
        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(
            _buildContext(), targetETH, usdcAmount, twapPrice, false);

        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
    }

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount)
        external { uint price = getTWAP(1800); _syncETH();
        uint usdAvailable; uint ethExcess;
        { (uint total, ) = get_metrics(false);
            uint pooledUSD = CORE.POOLED_USD() * 1e12;
            usdAvailable = total > pooledUSD ?
                                total - pooledUSD : 0;

            uint ethAvailable = _availableETH();

            ethExcess = ethAvailable > vogueETH ?
                             ethAvailable - vogueETH : 0;
        }
        uint reserved = Math.min(amount, usdAvailable
            + FullMath.mulDiv(ethExcess, price, WAD));

        (uint burned, uint seedBurned) = QUID.turn(
        msg.sender, Math.min(reserved, usdAvailable));

        if (burned == 0) return;
        uint taken = _take(msg.sender, burned,
                    address(QUID), seedBurned);
        if (taken < reserved) {
            uint ethToUse = Math.min(FullMath.mulDiv(
              reserved - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                require(v3Fair(price));
                uint received = _withdrawAAVE(address(WETH), ethToUse,
                            address(this), address(HUB) != address(0));

                received = BasketLib.sourceExternalUSD(_buildContext(),
                                                      received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    // amounts[1] represents the total
    // in terms of final $ melt value
    // amounts[0] assumes 1 sUSDS or 1 sUSDE = $1 regardless
    function _fee_deposits() internal view
        returns (uint[14] memory amounts) {
        uint balance; uint i; uint reserved;
        // USDC - Morpho vault (6 dec)
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

        amounts[1] += amounts[2] + amounts[3]; // < gains accounted
        for (i = 2; i < 5;) { // DAI, FRAX, and GHO are aTokens...
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(vaults[stable]).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;
            amounts[i + 2] = balance;

            amounts[0] += IERC20(stable).balanceOf(address(this));
            amounts[1] += balance; // aTokens (principal + yield)
            unchecked { ++i; }
        }
        for (i = 5; i < 9;) { // USDE, USDS, CRVUSD, SFRAX...
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;

            amounts[i + 2] = balance; // the balance for given token
            amounts[0] += balance; // these tokens aren't deposited
            amounts[1] += balance; // anywhere to earn extra yield
            unchecked { ++i; }
        }
        uint len = stables.length;
        for (i = 9; i < len;) {
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;
            amounts[0] += balance;

            balance = FullMath.mulDiv(
            _getPrice(i), balance, WAD);
            amounts[1] += balance;
            amounts[i + 2] = balance;
            unchecked { ++i; }
        }
        // amounts[1] should be higher than
    } // amounts[0] so their ratio gives us
    // the total APY % of the whole basket;
    // calculations differ in Basket.sol...

    /// @notice Vogue-compatible: uint[13] where [12]=TVL, [11]=0 (no SP)
    function get_deposits() external view
        returns (uint[13] memory out) {
        uint[14] memory full = _fee_deposits();
        out[0] = full[0]; // yield-weighted
        // Base tokens [1..8] = full[2..9] (8 base stables)
        for (uint i; i < 8;) {
            out[i + 1] = full[i + 2];
            unchecked { ++i; }
        }
        // Fold staked into base: SFRAX→FRAX, SUSDS→USDS, SUSDE→USDE, SCRVUSD→CRVUSD
        // base indices in out: FRAX=5, USDE=6, USDS=7, CRVUSD=8
        // staked in full: SFRAX=full[10], SUSDS=full[11], SUSDE=full[12], SCRVUSD=full[13]
        out[5] += full[10]; // FRAX += SFRAX
        out[6] += full[12]; // USDE += SUSDE
        out[7] += full[11]; // USDS += SUSDS
        out[8] += full[13]; // CRVUSD += SCRVUSD
        // [9..10] = 0, [11] = 0 (no SP on Arb)
        out[12] = full[1]; // TVL = full[1] (gains total)
    }

    function getFee(address token)
        public view returns (uint) {
        uint idx = toIndex[token];
        if (idx == 0) return 0;
        idx -= 1; // toIndex is 1-based
        uint[14] memory deps = _fee_deposits();
        return FeeLib.calcFeeWithPairs(idx, deps,
            FeeLib.StakedPairs({ base: [4, 5, 6, 7],
                    staked: [8, 10, 9, 11] }), stables,
                    address(QUID.HOOK()));
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination; whatever's in there: yours to take
    function _take(address who, uint amount, address token,
        uint seed) internal returns (uint sent) {
        int indexToSkip = -1; uint i;
        uint withdrawn; uint reserved;
        if (token != address(QUID)) {
            uint index = toIndex[token]; uint max;
            if (index == 0 || index >= 13) revert InvalidToken();
            if (index < 3) {
                max = IERC4626(vaults[token]).maxWithdraw(address(this));
            } else if (index < 6) {
                max = IERC20(vaults[token]).balanceOf(address(this));
            } else {
                max = IERC20(token).balanceOf(address(this));
            }
            reserved = BasketLib.scaleTokenAmount(
                untouchables[token], token, false); // native dec
            max = max > reserved ? max - reserved : 0;
            i = max > 0 ? (getFee(token) * WAD) / 10000 : 0;

            uint needed = (i > 0 && i < WAD / 10) ?
                FullMath.mulDiv(amount, WAD - i, WAD) : amount;

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
                sent = BasketLib.scaleTokenAmount(sent, token, true);
                deposits[token] -= Math.min(deposits[token], sent);
                return sent;
            }
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (i > 0) withdrawn = FullMath.mulDiv(
                                withdrawn, WAD - i, WAD);

                withdrawn = BasketLib.scaleTokenAmount(withdrawn, token, true);
                deposits[token] -= Math.min(deposits[token], withdrawn);
                return withdrawn;
            } else {
                withdrawn = _withdraw(who, index, max);
                if (i > 0) sent = FullMath.mulDiv(withdrawn, WAD - i, WAD);
                else sent = withdrawn;

                amount -= sent;
                sent = BasketLib.scaleTokenAmount(sent, token, true);
                deposits[token] -= Math.min(deposits[token], sent);
            }
        } // only heaven i'll be sent to is
        amount = BasketLib.scaleTokenAmount(
                        amount, token, true);
        if (amount > 0) { // when i'm a loan with you
            uint[14] memory amounts = _fee_deposits();
            amount = seed == 0 ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount,
                 amounts, indexToSkip, seed);
        }
    }

    function _executeProRata(address who, uint amount,
        uint[14] memory amounts, int indexToSkip,
        uint seed) private returns (uint sent) { // bitmasked withdrawal
        uint[12] memory w = FeeLib.calcWithdrawAmounts(amount, amounts,
            indexToSkip, seed > 0, [_getPrice(9), _getPrice(10), _getPrice(11)],
            [uint8(9), uint8(10), uint8(11)], 3); // 0b11 = USDC(0), USDT(1)

        uint haircutBps; address hookAddr = address(QUID.HOOK());
        if (hookAddr != address(0)) haircutBps = QUID.getHaircut();
        for (uint i; i < 12; ++i)
            if (w[i] > 0) {
                if (seed > 0) _tip(FullMath.mulDiv(w[i],
                                    seed, amount), stables[i], -1);
                if (hookAddr != address(0)) {
                    Types.DepegStats memory ds = IHook(hookAddr).getDepegStats(stables[i]);
                    if (ds.depegged) w[i] -= FullMath.mulDiv(w[i], haircutBps, 10000);
                }
                sent += _executeWithdraw(
                    who, i, w[i]);
            }
    }

    function _executeWithdraw(address who, uint i, uint amt)
        private returns (uint out) {
        uint div = (i < 2) ? 1e12 : 1;
        uint mid = stables.length / 2 - 1;
        address s = stables[i];
        out = amt * div;
        deposits[s] -= Math.min(deposits[s], out);
        if (i < 2) out = _withdraw(who, i + 1, amt) * 1e12;
        else if (i < mid) { out = AAVE.withdraw(s, amt,
                                          address(this));
            IERC20(s).transfer(who, out);
        }
        else IERC20(s).transfer(who, amt);
    }

    // strict = return one token as much
    // as we can, otherwise (if false)...
    // if entire amount isn't fulfilled
    // by token, remainer gets split pro
    // rata amongst the rest of basket...
    function take(address who, uint amount, address token, uint seed)
        public onlyUs returns (uint) { return _take(
                         who, amount, token, seed);
    }

    function _withdraw(address to, // 1e18 for sUSDS, 1e6 for USDC
        uint toIndex, uint amount) internal returns (uint sent) {
        if (amount == 0) return 0;  // Early return for 0 amounts
        if (toIndex < 3) {
            address vault = vaults[stables[toIndex - 1]];
            (uint shares,) = BasketLib.calculateVaultWithdrawal(
                                                  vault, amount);
            if (shares == 0) return 0; // skip if no shares to redeem
            sent = IERC4626(vault).redeem(shares, to, address(this));
        }
        else if (toIndex > 2 && toIndex < 6) {
            sent = AAVE.withdraw(stables[toIndex - 1], amount, to);
        }
        else { sent = amount;
            IERC20(stables[toIndex - 1]).transfer(to, amount);
        }
    }

    // there's never an incentive
    // for EOAs to call this since
    // mint() is the only way to
    // get yield for a deposit...
    // so it's assumed only our
    // contracts will call this
    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        uint index = toIndex[token];
        if (index == 0) revert InvalidToken();
        usd = Math.min(amount,
        IERC20(token).allowance(
            from, address(this)));
        IERC20(token).transferFrom(
            from, address(this), usd);
        if (usd == 0) revert NoDeposit();
        // deposit into external yield-bearing vaults
        // normalise the precision for compatibility
        amount = BasketLib.scaleTokenAmount(
                           usd, token, true);

        deposits[token] += amount;
        if (index < 3)
            IERC4626(vaults[token]).deposit(usd,
                              address(this));
        else if (index < 6)
            AAVE.supply(token, usd,
                address(this), 0);

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
