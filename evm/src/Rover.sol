
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "./Amp.sol";
import {Aux} from "./Aux.sol";

// import {AuxBase as Aux} from "./L2/AuxBase.sol";
// import {AuxArb as Aux} from "./L2/AuxArb.sol";
// import {AuxPoly as Aux} from "./L2/AuxPoly.sol";
// import {AuxUni as Aux} from "./L2/AuxUni.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {TickMath} from "./imports/v3/TickMath.sol";
import {FullMath} from "./imports/v3/FullMath.sol";

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./imports/v3/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "./imports/v3/INonfungiblePositionManager.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1, Arbitrum, Poly

contract Rover is ReentrancyGuard, Ownable {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    address public immutable USDC;
    WETH public immutable weth;
    uint public YIELD; // %
    uint public ID; // NFT

    uint constant WAD = 1e18;
    bool public token1isWETH;
    uint public totalShares;
    uint public LAST_REPACK;
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    int24 public LAST_TICK;
    uint private _deployed;

    int24 constant MAX_TICK = 887220;
    address public AUX; Amp public AMP;
    INonfungiblePositionManager public NFPM;
    mapping(address => uint128) public positions;

    int24 TICK_SPACING; uint24 public POOL_FEE;
    address public POOL; address public ROUTER;
    uint128 public liquidityUnderManagement;

    function fetch(address beneficiary) public
        returns (uint128, uint, uint160) {
        uint128 liq = positions[beneficiary];
        (uint160 sqrtPrice,
         int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        LAST_TICK = tick; uint price = getPrice(sqrtPrice);
        _repackNFT(0, 0, price); return (liq, price, sqrtPrice);
    }   receive() external payable {}

    modifier onlyUs {
        require(msg.sender == AUX
             || msg.sender == address(AMP), "403"); _;
    }

    constructor(address _amp,
        address _weth, address _usdc,
        address _nfpm, address _pool,
        address _router) Ownable(msg.sender) {
        USDC = _usdc; POOL = _pool;
        _deployed = block.timestamp;
        weth = WETH(payable(_weth));
        if (_amp != address(0)) {
            AMP = Amp(payable(_amp));
            ERC20(weth).approve(_amp, type(uint).max);
            ERC20(USDC).approve(_amp, type(uint).max);
        }
        ROUTER = _router; totalShares = 1;
        POOL_FEE = IUniswapV3Pool(POOL).fee();
        TICK_SPACING = IUniswapV3Pool(POOL).tickSpacing();
        address token0 = IUniswapV3Pool(POOL).token0();
        address token1 = IUniswapV3Pool(POOL).token1();
        token1isWETH = (token1 == _weth);

        require((token1isWETH && token0 == _usdc) ||
               (!token1isWETH && token1 == _usdc),
               "wrong pool");

        NFPM = INonfungiblePositionManager(_nfpm);
        ERC20(weth).approve(_router, type(uint).max);
        ERC20(USDC).approve(_router, type(uint).max);
        ERC20(weth).approve(_nfpm, type(uint).max);
        ERC20(USDC).approve(_nfpm, type(uint).max);
    }

    function setAux(address _aux) external onlyOwner {
        require(AUX == address(0)); AUX = _aux;
        renounceOwnership();
    }

    function _repackNFT(uint amount0, uint amount1,
             uint price) internal { uint128 liquidity;
        (int24 newLower, int24 newUpper) = _adjustTicks(LAST_TICK);
        if (LAST_REPACK != 0) { // not the first time packing the NFT
            if ((LAST_TICK > UPPER_TICK || LAST_TICK < LOWER_TICK) &&
            // "to improve is to change, to perfect is to change often"
                block.timestamp - LAST_REPACK >= 10 minutes) {
                // we want to make sure that all of the WETH deposited to this
                // contract is always in range (collecting), total range is ~7%
                // below and above tick, as voltage regulators watch currents
                // and control a relay (which turns on & off the alternator,
                // if below or above 12 volts, re-charging battery as such)
                (,,,,,,, liquidity,,,,) = NFPM.positions(ID);
                (uint collected0,
                 uint collected1,) = _withdrawAndCollect(liquidity);
                amount0 += collected0; amount1 += collected1;
                NFPM.burn(ID); ID = 0;
                // Update ticks for new position after burning
                LOWER_TICK = newLower;
                UPPER_TICK = newUpper;
            }
        } else {
            // First time ever - set initial ticks
            LOWER_TICK = newLower;
            UPPER_TICK = newUpper;
        }
        if (liquidity > 0 || ID == 0) {
            if (amount0 == 0 && amount1 == 0) return;
            // Convert to (wethAmount, usdcAmount) for potential _swap
            (uint wethAmount, uint usdcAmount) = token1isWETH ?
                (amount1, amount0) : (amount0, amount1);

            // Only skip _swap if:
            // - We didn't just burn a position (liquidity == 0), AND
            // - We have pre-balanced amounts from deposit() (both > 0)
            // When liquidity > 0, we just burned and collected amounts that
            // are unbalanced for the NEW tick range - must rebalance via _swap
            bool needsSwap = liquidity > 0 || wethAmount == 0 || usdcAmount == 0;
            if (needsSwap) {
                (wethAmount, usdcAmount) = _swap(
                    wethAmount, usdcAmount, price);
            }
            // Convert back to (amount0, amount1) for mint
            // token0 is always the lower address
            (uint mintAmount0, uint mintAmount1) = token1isWETH ?
                (usdcAmount, wethAmount) : (wethAmount, usdcAmount);

            (ID, liquidityUnderManagement,,) = NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token1isWETH ? USDC : address(weth),
                    token1: token1isWETH ? address(weth) : USDC,
                    fee: POOL_FEE,
                    tickLower: LOWER_TICK, tickUpper: UPPER_TICK,
                    amount0Desired: mintAmount0,
                    amount1Desired: mintAmount1,
                    amount0Min: 0, amount1Min: 0, recipient: address(this),
                    deadline: block.timestamp
            })); LAST_REPACK = block.timestamp;
        } // metrics at the expense of sometimes doing 1 extra swap:
        else { (uint collected0, uint collected1) = _collect(price);
            amount0 += collected0; amount1 += collected1;
            if (amount0 > 0 || amount1 > 0) {
                // Try to compound collected fees. May fail if:
                // - Position is in-range but fees are single-sided
                // - Amounts are too small to create any liquidity
                // On failure, tokens stay in contract for next deposit/repack
                try NFPM.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                            ID, amount0, amount1, 0, 0, block.timestamp))
                returns (uint128 addedLiquidity, uint, uint) {
                    liquidityUnderManagement += addedLiquidity;
                } catch {
                    // Silently continue - tokens remain in contract
                }
            }
        }
    } function repackNFT() public nonReentrant
        returns (uint160) { (uint160 sqrtPriceX96,
        int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        LAST_TICK = tick; _repackNFT(0, 0,
              getPrice(sqrtPriceX96));
                  return sqrtPriceX96;
    }

    // from v3-periphery/OracleLibrary...
    // Returns price as USDC per WETH (scaled to 18 decimals)
    function getPrice(uint160 sqrtRatioX96)
        public view returns (uint price) {
        uint casted = uint(sqrtRatioX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);

        if (token1isWETH)
            // sqrtPrice represents token0/token1 = USDC/WETH
            // We want USDC per WETH, so invert: WETH/USDC -> 1/(USDC/WETH)
            price = FullMath.mulDiv(1 << 128, WAD * 1e12, ratioX128);
        else
            // sqrtPrice represents token0/token1 = WETH/USDC
            // We want USDC per WETH, which is the ratio * decimal adjustment
            price = FullMath.mulDiv(ratioX128, WAD * 1e12, 1 << 128);
    }

    function _collect(uint price) internal
        returns (uint amount0, uint amount1) {
        (amount0, amount1) = NFPM.collect(
            INonfungiblePositionManager.CollectParams(ID,
                address(this), type(uint128).max, type(uint128).max
            )); // "collect calls to the tip sayin' how ya changed"
    }

    function _withdrawAndCollect(uint128 liquidity) internal
        returns (uint amount0, uint amount1, uint128 liq) {
        // Early return if nothing requested or no position
        if (liquidity == 0 || ID == 0) return (0, 0, 0);
        // Get actual position liquidity from NFT - this is ground truth
        (,,,,,,, uint128 positionLiquidity,,,,) = NFPM.positions(ID);
        // Cap to actual available in NFT position (prevents NFPM revert)
        if (liquidity > positionLiquidity) {
            liquidity = positionLiquidity;
        }
        // Also cap to our tracking variable
        if (liquidity > liquidityUnderManagement) {
            liquidity = liquidityUnderManagement;
            liquidityUnderManagement = 0;
        } else {
            liquidityUnderManagement -= liquidity;
        }
        if (liquidity > 0) {
            NFPM.decreaseLiquidity(// there's liquidity to withdraw
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    ID, liquidity, 0, 0, block.timestamp));
            (amount0, amount1) = _collect(0);
            return (amount0, amount1, liquidity);
        }
        return (0, 0, 0);
    }

    function _adjustToNearestIncrement(int24 input)
        internal view returns (int24) {
        int24 remainder = input % TICK_SPACING;
        if (remainder == 0) return input;
        if (remainder < 0) remainder += TICK_SPACING;
        int24 result = remainder >= TICK_SPACING / 2
            ? input + (TICK_SPACING - remainder)
            : input - remainder;

        return result >  MAX_TICK ?  MAX_TICK :
               result < -MAX_TICK ? -MAX_TICK : result;
    }

    function _adjustTicks(int24 currentTick) internal
        view returns (int24 lower, int24 upper) {
        // Calculate tick delta as ~3.57% of current tick
        int256 tickDelta = (int256(currentTick) * 357) / 10000;
        // Take absolute value - we always want
        // to expand outward from current tick
        if (tickDelta < 0) tickDelta = -tickDelta;
        if (tickDelta < TICK_SPACING) tickDelta = TICK_SPACING;
        // Lower tick is always currentTick - delta (more negative)
        // Upper tick is always currentTick + delta (more positive)
        lower = _adjustToNearestIncrement(currentTick - int24(int256(tickDelta)));
        upper = _adjustToNearestIncrement(currentTick + int24(int256(tickDelta)));
        // Ensure proper ordering (safety check)
        if (lower > upper)
            (lower, upper) = (upper, lower);

        // Ensure they're not equal
        if (upper == lower)
            upper += TICK_SPACING;
    }

    function _getTickSqrtPrices() internal view returns
        (uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtCurrent) {
        sqrtLower = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER_TICK);
        sqrtCurrent = TickMath.getSqrtPriceAtTick(LAST_TICK);
    }

    function _swap(uint eth, uint usdc, uint price)
        internal returns (uint, uint) {
        if (eth == 0 && usdc == 0) return (0, 0);
        uint targetETH; uint targetUSDC; usdc *= 1e12;
        {
            (uint160 sqrtLower,
            uint160 sqrtUpper,
            uint160 sqrtCurrent) = _getTickSqrtPrices();
            uint128 liquidity;
            if (eth > 0) {
                // We have ETH, calculate liquidity based on ETH amount
                if (token1isWETH) {
                    // ETH is token1, use getLiquidityForAmount1
                    liquidity = LiquidityAmounts.getLiquidityForAmount1(
                                            sqrtCurrent, sqrtUpper, eth);
                } else {
                    // ETH is token0, use getLiquidityForAmount0
                    liquidity = LiquidityAmounts.getLiquidityForAmount0(
                                            sqrtCurrent, sqrtUpper, eth);
                }
            } else {
                // We have USDC, calculate liquidity based on USDC amount
                if (token1isWETH) {
                    // USDC is token0, use getLiquidityForAmount0
                    liquidity = LiquidityAmounts.getLiquidityForAmount0(
                                           sqrtLower, sqrtCurrent, usdc);
                } else {
                    // USDC is token1, use getLiquidityForAmount1
                    liquidity = LiquidityAmounts.getLiquidityForAmount1(
                                           sqrtLower, sqrtCurrent, usdc);
                }
            }
            if (liquidity == 0) return (eth, usdc / 1e12);
            // Get target amounts for this liquidity
            (uint amount0, uint amount1) = LiquidityAmounts.getAmountsForLiquidity(
                                      sqrtCurrent, sqrtLower, sqrtUpper, liquidity);
            if (token1isWETH) {
                targetETH = amount1;
                targetUSDC = amount0;
            } else {
                targetETH = amount0;
                targetUSDC = amount1;
            }
        }
        if (targetETH == 0
         && targetUSDC == 0) return (eth, usdc / 1e12);
        // Assume ETH is X and USDC is Y...
        // the formula is (x - ky)/(1 + kp);
        // we're selling X to buy Y, where
        // p is the price of ETH. So, the
        // derivation steps: assume n
        // is amount being swapped...
        // (x - n)/(y + np) = k target
        // x - n = ky + knp
        // x - ky = n + knp
        // x - ky = n(1 + kp)
        targetUSDC *= 1e12;
        if (usdc > targetUSDC)
            usdc = targetUSDC;

        if (eth > targetETH)
            eth = targetETH;

        if (targetUSDC > usdc && eth > 0 && targetUSDC > 0) {
            uint k = FullMath.mulDiv(targetETH, WAD, targetUSDC);
            uint ky = FullMath.mulDiv(k, usdc, WAD);
            if (eth > ky) {
                uint kp = FullMath.mulDiv(ky, price, WAD);
                if (kp == 0) kp = 1;
                uint toSwap = FullMath.mulDiv(WAD, eth - ky, WAD + kp);
                if (toSwap > 0 && toSwap <= eth) { eth -= toSwap;
                    usdc += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                                          abi.encodePacked(address(weth), POOL_FEE, USDC),
                                          address(this), block.timestamp, toSwap, 0)) * 1e12;
                }
            }
        }
        if (targetETH > eth && usdc > 0
         && targetUSDC > 0 && targetETH > 0) { uint toSwapScaled;
            uint k = FullMath.mulDiv(targetETH, WAD, targetUSDC);
            if (k == 0) return (eth, usdc / 1e12);
            uint kp = FullMath.mulDiv(k, price, WAD);
            if (kp == 0) return (eth, usdc / 1e12);
            if (eth > 0) {
                uint ethValueInUsdc = FullMath.mulDiv(eth, WAD, k);
                toSwapScaled = usdc > ethValueInUsdc ?
                               usdc - ethValueInUsdc : 0;
            } else {
                toSwapScaled = usdc;
            }
            if (toSwapScaled > 0) {
                uint toSwap = FullMath.mulDiv(WAD, toSwapScaled,
                    WAD + FullMath.mulDiv(WAD, WAD, kp)) / 1e12;

                // Cap at available USDC...
                uint maxSwap = usdc / 1e12;
                if (toSwap > maxSwap) toSwap = maxSwap;
                if (toSwap > 0) { usdc -= toSwap * 1e12;
                    eth += ISwapRouter(ROUTER).exactInput(
                        ISwapRouter.ExactInputParams(abi.encodePacked(USDC, POOL_FEE,
                          address(weth)),address(this), block.timestamp, toSwap, 0));
                }
            }
        } return (eth, usdc / 1e12);
    }

    function deposit(uint amount)
        external nonReentrant payable {
        (uint128 liq, uint price, uint160 sqrtPrice) = fetch(msg.sender);

        if (amount > 0) weth.transferFrom(msg.sender, address(this), amount);
        if (msg.value > 0) weth.deposit{value: msg.value}(); uint in_dollars;
        (amount, in_dollars) = _swap(amount + msg.value, 0, price);

        (uint amount0, uint amount1) = token1isWETH ?
        (in_dollars, amount) : (amount, in_dollars);

        (uint160 sqrtLower, uint160 sqrtUpper,) = _getTickSqrtPrices();
        uint128 newLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPrice, sqrtLower, sqrtUpper, amount0, amount1);

        uint128 newShares;
        if (totalShares == 0) {
            newShares = newLiq;
        } else {
            // Use max to prevent new depositors from benefiting if NAV decreased
            // - If LUM > totalShares (fees accrued): new depositors get fewer shares
            // - If LUM < totalShares (loss occurred): new depositors get 1:1 (neutral)
            uint denominator = liquidityUnderManagement > totalShares ?
                               liquidityUnderManagement : totalShares;

            newShares = uint128(FullMath.mulDiv(uint(newLiq),
                                   totalShares, denominator));
        }
        totalShares += newShares;
        _repackNFT(amount0, amount1, price);
        positions[msg.sender] += newShares;
    }

    // LP.liq = user's share (set at deposit, doesn't auto-grow)
    // liquidityUnderManagement = actual V3 position liquidity
    // (grows when fees compound via increaseLiquidity); when
    // fees compound: liquidityUnderManagement += newLiquidity,
    // but NO individual LP.liq changes;
    // totalShares ≠ liquidityUnderManagement
    // because the gap = compounded fees...
    function take(uint amount) public onlyUs
        returns (uint wethAmount) { repackNFT();
        uint128 liquidity; uint usdcAmount;
        (uint160 sqrtLower, uint160 sqrtUpper,
         uint160 sqrtCurrent) = _getTickSqrtPrices();

        liquidity = token1isWETH ? LiquidityAmounts.getLiquidityForAmount1(
                                        sqrtCurrent, sqrtUpper, amount / 2):
                                    LiquidityAmounts.getLiquidityForAmount0(
                                         sqrtCurrent, sqrtUpper, amount / 2);

        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);
        if (token1isWETH) { usdcAmount = amount0; wethAmount = amount1; }
        else { wethAmount = amount0; usdcAmount = amount1; }
        if (usdcAmount > 0)
            wethAmount += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                                       abi.encodePacked(USDC, POOL_FEE, address(weth)),
                                        address(this), block.timestamp, usdcAmount, 0));
        if (wethAmount > 0)
            weth.transfer(msg.sender, wethAmount);
    }

    function depositUSDC(uint amount, uint price) public onlyUs { repackNFT();
        ERC20(USDC).transferFrom(msg.sender, address(this), amount);
        (uint eth, uint usd) = _swap(0, amount, price);
        // Convert to (amount0, amount1) for increaseLiquidity
        (uint amount0, uint amount1) = token1isWETH ? (usd, eth) : (eth, usd);
        (uint128 liquidity, , ) = NFPM.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(
                    ID, amount0, amount1, 0, 0, block.timestamp));
                            liquidityUnderManagement += liquidity;
    }

    function withdrawUSDC(uint amount)
        public onlyUs returns (uint usd) {
        uint eth; repackNFT(); uint128 liquidity;

        (uint160 sqrtLower, uint160 sqrtUpper,
         uint160 sqrtCurrent) = _getTickSqrtPrices();

        liquidity = token1isWETH ?
                     LiquidityAmounts.getLiquidityForAmount0(
                          sqrtLower, sqrtCurrent, amount / 2):
                     LiquidityAmounts.getLiquidityForAmount1(
                          sqrtLower, sqrtCurrent, amount / 2);
        (uint amount0,
         uint amount1, ) = _withdrawAndCollect(liquidity);
        if (token1isWETH) { eth = amount1; usd = amount0; }
        else { eth = amount0; usd = amount1; }

        if (eth > 0)
            usd += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                        abi.encodePacked(address(weth), POOL_FEE, address(USDC)),
                                        address(this), block.timestamp, eth, 0));
        if (usd > 0)
            ERC20(USDC).transfer(msg.sender, usd);
    }

    // @param (amount) is actually
    // a % of their total liquidity
    // if msg.sender != address(AUX)
    function withdraw(uint amount) public nonReentrant {
        require(amount > 0 && amount <= 1000, "%");
        (uint128 liq,
         uint price, uint160 sqrtPrice) = fetch(msg.sender);

        require(liq > 0, "nothing to withdraw");
        uint128 withdrawingShares = uint128(FullMath.mulDiv(
                                    amount, uint(liq), 1000));

        uint128 liquidity = uint128(FullMath.mulDiv(liquidityUnderManagement,
                                            withdrawingShares, totalShares));

        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);
        (uint ethAmount, uint usdAmount) = token1isWETH ? (amount1, amount0)
                                                        : (amount0, amount1);
        if (usdAmount > 0)
            ethAmount += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                             abi.encodePacked(address(USDC), POOL_FEE, address(weth)),
                                        address(this), block.timestamp, usdAmount, 0));
        weth.withdraw(ethAmount);
        liq -= withdrawingShares;
        totalShares -= withdrawingShares;
        // LP receives swap output...
        // (bearing the slippage cost)
        (bool success, ) = msg.sender.call{
                          value: ethAmount}("");
                          require(success, "$");

        if (liq > 0) positions[msg.sender] = liq;
        else delete positions[msg.sender];
    }
}
