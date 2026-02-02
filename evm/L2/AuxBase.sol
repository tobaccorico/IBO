
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "../Amp.sol";
import {Rover} from "../Rover.sol";
import {Basket} from "../Basket.sol";
import {VogueCore} from "../VogueCore.sol";
import {BasketLib} from "../BasketLib.sol";
import {Types} from "../imports/Types.sol";
import {VogueUni as Vogue} from "./VogueUni.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
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

contract AuxBase is // Auxiliary
    Ownable, ReentrancyGuard {
    bool public token1isWETH;
    VogueCore internal CORE;
    address internal jury;

    IERC20 internal USDC;
    Basket internal QUID;

    address internal DSR;
    address internal CRV;
    Vogue internal V4;

    address[] internal stables;
    WETH9 public WETH; Rover V3;

    mapping(address => uint) internal untouchables;
    mapping(address => address) internal vaults;
    mapping(address => uint) internal deposits;
    mapping(address => uint) internal toIndex;

    IUniswapV3Pool internal v3PoolWETH;
    BasketLib.Metrics internal metrics;
    uint constant target = 500000 * WAD;

    IERC4626 internal wethVault;
    uint internal untouchable;
    address internal v3Router;
    uint internal lastBlock;
    uint constant WAD = 1e18;
    uint24 internal v3Fee;

    error Unauthorized();
    error NotInitialized();
    error InvalidToken();
    error Untouchable();
    error NoDeposit();

    Amp internal AMP;
    IPool internal AAVE;

    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID) // you're my religion...
         && msg.sender != address(this)) revert Unauthorized(); _;
    }

    modifier onlyAmped {  // I can't envision that for a minute...
        if (address(AMP) == address(0)) revert NotInitialized(); _;
    }

    /// @notice init (plug) Aux with addresses
    /// @dev optional: V3 rover & AAVE amp...
    /// @param _vogue UniV4 rover  address...
    /// @param _wethVault Morpho for WETH deposits
    /// @param _v3poolWETH V3 pool
    /// @param _v3router V3 router for swaps
    /// @param _v3 our wrapper around UniV3
    /// @param _amp AAVE yield-amplifier...
    constructor(address _vogue, address _core,
        address _wethVault, address _amp,
        address _aave, address _v3poolWETH,
        address _v3router, address _v3,
        address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {

        stables = _stables; uint i;
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
        }   AAVE = IPool(_aave);

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
        // GHO uses AAVE, store aToken
        // address for balance queries
        vaults[stables[i]] = _vaults[i];
        IERC20(stables[i]).approve(
        address(AAVE), type(uint).max);
        toIndex[stables[i]] = i + 1;
        unchecked { ++i; }
        while (i < stables.length) {
            toIndex[stables[i]] = i + 1;
            unchecked { ++i; }
        }
        DSR = 0x49aF4eE75Ae62C2229bb2486a59Aa1a999f050f0;
        CRV = 0x3d8EADb739D1Ef95dd53D718e4810721837c69c1;
    } fallback() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[14] memory amounts = get_deposits();
            stats = BasketLib.computeMetrics(stats,
                    elapsed, amounts[0], amounts[1]);

            metrics = stats;
        }
        return (stats.total, stats.yield);
    }

    function getAverageYield() external view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function _getPrice(uint index) internal
        view returns (uint price) {
        if (index == 10) {
            price = BasketLib.getStakedPrice(
                0xdEd37FC1400B8022968441356f771639ad1B23aA,
                BasketLib.ORACLE_CHAINLINK);
        } else if (index == 11) {
            price = BasketLib.getStakedPrice(
                CRV, BasketLib.ORACLE_CRV);
        } else if (index == 1) {
            price = BasketLib.getStakedPrice(
                DSR, BasketLib.ORACLE_DSR_RATE);
        }
    }

    function setQuid(address _quid, address _jury,
        address _court) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        QUID.setup(_court, _jury); jury = _jury;
        USDC.approve(address(v3Router), type(uint).max);
        WETH.approve(address(v3Router), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
        WETH.approve(address(AMP), type(uint).max);
        USDC.approve(address(AMP), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        USDC.approve(address(V3), type(uint).max);
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

    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable
        external { uint twapPrice = getTWAP(0);
        amount = _depositETH(msg.sender, amount);
        uint usdcNeeded = BasketLib.convert(amount, twapPrice, false);
        uint took = _take(address(this), usdcNeeded, address(USDC), false);
        if (took <= usdcNeeded) { // TODO why use getTWAP(0) first then pass in getTWAP(1800)??
            require(v3Fair(twapPrice));
            (uint more, uint used) = BasketLib.source(_buildContext(),
                address(V4), address(V3), usdcNeeded - took, amount,
                twapPrice, getTWAP(1800), true);
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
            AAVE.supply(address(WETH),
            ethReceived, address(V4), 0);

            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            !V4.token1isETH(), address(USDC), ethReceived);

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(v3Fair(twapPrice));
        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(
            _buildContext(), address(V4), address(V3),
            targetETH, usdcAmount, twapPrice, 0, false);

        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
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
                uint received = V4.takeETH(ethToUse, address(this));
                WETH.deposit{value: received}(); require(v3Fair(price));
                received = BasketLib.sourceExternalUSD(_buildContext(),
                                         address(V3), received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    // amounts[1] represents the total
    // in terms of final $ melt value
    // amounts[0] assumes 1 sUSDS or 1 sUSDE = $1 regardless
    function get_deposits() public view // yield approximated...
        returns (uint[14] memory amounts) {
        uint balance; uint i; uint reserved;
        reserved = untouchables[stables[0]];
        balance = IERC4626(vaults[stables[0]]).maxWithdraw(address(this));
        amounts[2] = (balance > reserved ? balance - reserved : 0) * 1e12;

        reserved *= 1e12;
        balance = deposits[stables[0]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        reserved = untouchables[stables[1]];
        balance = IERC4626(vaults[stables[1]]).maxWithdraw(address(this));
        amounts[3] = balance > reserved ? balance - reserved : 0;

        balance = deposits[stables[1]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        amounts[1] += amounts[2] + FullMath.mulDiv(
                    _getPrice(1), amounts[3], WAD);

        reserved = untouchables[stables[2]];
        balance = IERC20(vaults[stables[2]]).balanceOf(address(this));
        amounts[4] = balance > reserved ? balance - reserved : 0;
        amounts[0] += IERC20(stables[2]).balanceOf(address(this));
        amounts[1] += amounts[4]; // aGHO (principal + yield)

        // we have only one token that is deposited on AAVE (GHO)
        uint len = stables.length;
        for (i = 3; i < 10;) { // USDT, DAI, FRAX, USDE, USDS, CRVUSD, SFRAX
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;
            amounts[i + 2] = i == 3 ? balance * 1e12 : balance; // scale USDT
            amounts[0] += amounts[i + 2]; // these tokens aren't deposited
            amounts[1] += amounts[i + 2]; // anywhere to earn extra yield
            unchecked { ++i; }
        }
        for (i = 10; i < len;) {
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(
                                     address(this));
            balance = balance > reserved
                    ? balance - reserved : 0;
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

    function getFee(address token)
        public view returns (uint) {
        uint idx = type(uint).max;
        uint len = stables.length;
        for (uint i; i < len;) {
            if (stables[i] == token)
            { idx = i; break; }
            unchecked { ++i; }
        }
        if (idx == type(uint).max) return 0;
        uint[14] memory deps = get_deposits();
        return BasketLib.calcFeeWithPairs(idx, deps,
            BasketLib.StakedPairs({ base: [5, 6, 7, 8],
                staked: [9, 10, 1, 11] }), stables, jury);
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination: whatever's in there, yours to take
    function _take(address who, uint amount, address token,
        bool strict) internal returns (uint sent) {
        int indexToSkip = -1; uint i;
        uint withdrawn; uint reserved;
        if (token != address(QUID)) {
            uint index = toIndex[token]; uint max;
            if (index == 0 || index >= 13) revert InvalidToken();
            if (index < 3) {
                max = IERC4626(vaults[token]).maxWithdraw(address(this));
            }
            else if (index == 3) {
                max = IERC20(vaults[token]).balanceOf(address(this));
            } else {
                max = IERC20(token).balanceOf(address(this));
            }
            reserved = untouchables[token];
            max = max > reserved ? max - reserved : 0;
            i = max > 0 ? (getFee(token) * WAD) / 10000 : 0;

            uint needed = (i > 0 && i < WAD / 10) ?
                FullMath.mulDiv(amount, WAD + i, WAD) : amount;

            indexToSkip = int(index - 1);
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (strict) {
                    untouchables[token] -= withdrawn;
                    untouchable -= (index == 1 || index == 4)
                            ? withdrawn * 1e12 : withdrawn;
                }
                if (i > 0) withdrawn = FullMath.mulDiv(
                          withdrawn, WAD - i, WAD);

                deposits[token] -= BasketLib.scaleTokenAmount(
                                        withdrawn, token, true);
                return withdrawn;
            } else {
                withdrawn = _withdraw(who, index, max);
                if (strict) {
                    untouchables[token] -= withdrawn;
                    untouchable -= (index == 1 || index == 4)
                            ? withdrawn * 1e12 : withdrawn;
                }
                if (i > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - i, WAD);
                else sent = withdrawn;

                amount -= sent;
                deposits[token] -= BasketLib.scaleTokenAmount(
                                            sent, token, true);
                if (strict)
                    return sent;
            }
        } amount = BasketLib.scaleTokenAmount(
                          amount, token, true);
        if (amount > 0) {
            uint[14] memory amounts = get_deposits();
            amount = !strict ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount,
                amounts, indexToSkip, strict);
        }
    }

    /// @dev Separated to reduce stack depth in _take
    function _executeProRata(address who, uint amount,
        uint[14] memory amounts, int indexToSkip,
        bool strict) private returns (uint sent) {
        uint[12] memory w = BasketLib.calcWithdrawAmounts(amount, amounts,
            indexToSkip, strict, [_getPrice(1), _getPrice(10), _getPrice(11)],
            [uint8(1), uint8(10), uint8(11)], 9); // 0b1001 = USDC(0), USDT(3)
        for (uint i; i < 12; ++i) if (w[i] > 0)
            sent += _executeWithdraw(who, i, w[i], strict);
    }

    /// @dev Execute single withdrawal, separated to reduce stack depth
    function _executeWithdraw(address who, uint i, uint amt,
        bool strict) private returns (uint out) {
        uint div = (i == 0 || i == 3) ? 1e12 : 1;
        address s = stables[i]; out =  amt * div; deposits[s] -= out;
        if (strict) { untouchables[s] -= amt; untouchable -= out; }
        if (i < 2) out = _withdraw(
            who, i + 1, amt) * div;
        else if (i == 2) {
          out = AAVE.withdraw(s,
            amt, address(this));
          IERC20(s).transfer(who, out);
        }
        else IERC20(s).transfer(who, amt);
    }

    // Base stables: [USDC, SUSDS, GHO, USDT, DAI,
    // FRAX, USDE, USDS, CRVUSD, SFRAX, SUSDE, SCRVUSD]

    // strict = return one token as much
    // as we can, otherwise (if false)...
    // if entire amount isn't fulfilled
    // by token, remainer gets split pro
    // rata amongst the rest of basket...
    function take(address who, uint amount,
        address token, bool strict) public
        onlyUs returns (uint) { return _take(
                  who, amount, token, strict);
    }

    function _withdraw(address to, // 1e18 for sUSDS, 1e6 for USDC
        uint toIndex, uint amount) internal returns (uint sent) {
        if (amount == 0) return 0;  // Early return for 0 amounts
        if (toIndex < 3)  {
            address vault = vaults[stables[toIndex - 1]];
            (uint shares,) = BasketLib.calculateVaultWithdrawal(
                                                vault, amount);
            if (shares == 0) return 0;  // Skip if no shares to redeem
            sent = IERC4626(vault).redeem(shares, to, address(this));
        }
        else if (toIndex == 3) {
            sent = AAVE.withdraw(stables[2], amount, to);
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
        IERC20(token).allowance(from,
                    address(this)));

        IERC20(token).transferFrom(from,
                    address(this), usd);
        if (usd == 0) revert NoDeposit();
        // deposit into external yield-bearing vaults
        // normalise the precision for compatibility
        amount = BasketLib.scaleTokenAmount(
                            usd, token, true);

        deposits[token] += amount;
        if (index < 3) { // USDT, USDC for Arb , and for
        // Base it's just USDC (no USDT) and sUSDS...
            IERC4626(vaults[token]).deposit(usd,
                                    address(this));
        } // GHO only for Base (+ DAI, FRAX for Arb)
        else if (index == 3)
            AAVE.supply(token, usd,
                address(this), 0);

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
