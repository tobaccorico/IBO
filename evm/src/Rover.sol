
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9.0;

import {Amp} from "./Amp.sol";
import {Aux} from "./Aux.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {TickMath} from "./imports/v3/TickMath.sol";
import {FullMath} from "./imports/v3/FullMath.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./imports/v3/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "./imports/v3/INonfungiblePositionManager.sol";
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; 
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum

// import "lib/forge-std/src/console.sol"; 
contract Rover is ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    address public immutable USDC;

    WETH public immutable weth;
    uint public YIELD; // %
    uint public ID; // V3 NFT
    uint public LAST_REPACK;
    uint private _deployed;
    struct Deposit {
        // Masterchef-style
        // snapshots of fees:
        uint fees_eth;
        uint fees_usd;
        uint128 liq;
    } Amp public AMP;
    address public AUX;
    bool token1isWETH;

    int24 internal UPPER_TICK;
    int24 internal LOWER_TICK;
    int24 internal LAST_TICK;
    uint constant WAD = 1e18;

    uint24 constant POOL_FEE = 3000;
    int24 constant MAX_TICK = 887220;
    int24 constant TICK_SPACING = 60;
    INonfungiblePositionManager NFPM;
    mapping(address => Deposit) positions;    
    
    address public POOL; address public ROUTER;
    uint128 liquidityUnderManagement; // UniV3
    uint public USD_FEES; uint public ETH_FEES;    
    
    function fetch(address beneficiary) public 
        returns (Deposit memory, uint, uint160) { 
        Deposit memory LP = positions[beneficiary];
        (uint160 sqrtPrice, 
         int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        LAST_TICK = tick; uint price = getPrice(sqrtPrice);
        return (LP, price, sqrtPrice);
    }   receive() external payable {}

    modifier onlyUs {
        require(msg.sender == AUX
             || msg.sender == address(AMP), "403"); _;
    }

    constructor(address _amp,
        address _weth, address _usdc,
        address _nfpm, address _pool, 
        address _router) { USDC = _usdc;
        POOL = _pool; ROUTER = _router;
        _deployed = block.timestamp;
        weth = WETH(payable(_weth));
        AMP = Amp(payable(_amp)); 

        address token0 = IUniswapV3Pool(POOL).token0();
        address token1 = IUniswapV3Pool(POOL).token1();
        token1isWETH = (token1 == _weth);
        
        require((token1isWETH && token0 == _usdc) || 
                (!token1isWETH && token0 == _usdc), 
                "wrong pool");

        NFPM = INonfungiblePositionManager(_nfpm);
        ERC20(weth).approve(_amp, type(uint256).max);
        ERC20(USDC).approve(_amp, type(uint256).max);
        ERC20(weth).approve(_router, type(uint256).max);
        ERC20(USDC).approve(_router, type(uint256).max);
        ERC20(weth).approve(_nfpm, type(uint256).max);
        ERC20(USDC).approve(_nfpm, type(uint256).max);
    }

    function setAux(address _aux) external onlyUs {
        require(AUX == address(0)); AUX = _aux;
    }

    function _repackNFT(uint amount0, uint amount1,
        uint price) internal { uint128 liquidity;
        (LOWER_TICK, UPPER_TICK) = _adjustTicks(LAST_TICK);
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
                NFPM.burn(ID); 
            }
        } if (liquidity > 0 || ID == 0) {     
            if (amount0 == 0 && amount1 == 0) return;
            (uint wethAmount, uint usdcAmount) = token1isWETH ? 
                (amount1, amount0) : (amount0, amount1);

            (wethAmount, usdcAmount) = _swap(
                wethAmount, usdcAmount, price);  
                        
            (ID, liquidityUnderManagement,,) = NFPM.mint(
                INonfungiblePositionManager.MintParams({ 
                    token0: token1isWETH ? USDC : address(weth),
                    token1: token1isWETH ? address(weth) : USDC, 
                    fee: POOL_FEE,  
                    tickLower: LOWER_TICK, tickUpper: UPPER_TICK, 
                    amount0Desired: token1isWETH ? usdcAmount : wethAmount,
                    amount1Desired: token1isWETH ? wethAmount : usdcAmount,
                    amount0Min: 0, amount1Min: 0, recipient: address(this), 
                    deadline: block.timestamp 
            })); LAST_REPACK = block.timestamp;
        } // metrics at the expense of sometimes doing 1 extra swap:
        else { (uint collected0, uint collected1) = _collect(price);
            amount0 += collected0; amount1 += collected1;
            if (amount0 > 0 || amount1 > 0) {
                (liquidity,,) = NFPM.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                            ID, amount0, amount1, 0, 0, block.timestamp));
                                    liquidityUnderManagement += liquidity;
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
    function getPrice(uint160 sqrtRatioX96)
        public view returns (uint price) {
        uint256 casted = uint256(sqrtRatioX96);
        uint256 ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64); 
        
        if (token1isWETH)
            // Price is USDC per WETH (ratio of token0/token1)
            price = FullMath.mulDiv(1 << 128, WAD * 1e12, ratioX128);
        else
            // Price is USDC per WETH (ratio of token1/token0)
            price = FullMath.mulDiv(ratioX128, WAD * 1e12, 1 << 128);   
    }

    function _collect(uint price) internal 
        returns (uint amount0, uint amount1) {
        (amount0, amount1) = NFPM.collect( 
            INonfungiblePositionManager.CollectParams(ID,
                address(this), type(uint128).max, type(uint128).max
            )); // "collect calls to the tip sayin' how ya changed"
        if (price > 0) { // also collect metrics about earnings...
            (amount0, amount1) = _swap(amount0, amount1, price);
            if (token1isWETH) { 
                ETH_FEES += amount1; 
                USD_FEES += amount0 * 1e12;
            } else {
                ETH_FEES += amount0; 
                USD_FEES += amount1 * 1e12;
            }
        }
    }

    function _withdrawAndCollect(uint128 liquidity) internal 
        returns (uint amount0, uint amount1, uint128 liq) {
        require(liquidity > 0, "nothing to decrease");
        if (liquidity > liquidityUnderManagement) {
            liquidity = liquidityUnderManagement;
            liquidityUnderManagement = 0;
        } else {
            liquidityUnderManagement -= liquidity;
        }   liq = liquidity;
        NFPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                ID, liquidity, 0, 0, block.timestamp));  
                      (amount0, amount1) = _collect(0);
    } // careful to prevent fee double count...param^
    function _adjustToNearestIncrement(int24 input)
        internal pure returns (int24) {
        int24 remainder = input % TICK_SPACING;
        if (remainder == 0) return input;
        
        int24 result = remainder >= TICK_SPACING / 2
            ? input + (TICK_SPACING - remainder)
            : input - remainder;
        
        return result > MAX_TICK ? MAX_TICK :
            result < -MAX_TICK ? -MAX_TICK :
            result;
    }
    function _adjustTicks(int24 currentTick) internal // winding
        pure returns (int24 lower, int24 upper) { // staircase...
        int256 tickDelta = (int256(currentTick) * 357) / 10000;
        tickDelta = tickDelta == 0 ? TICK_SPACING : tickDelta;
    
        upper = _adjustToNearestIncrement(
            currentTick + int24(tickDelta));
        lower = _adjustToNearestIncrement(
            currentTick - int24(tickDelta));
       
        if (upper == lower)
            upper += TICK_SPACING;
            return (lower, upper);
    }
    
    function _swap(uint eth, uint usdc, uint price) internal 
        returns (uint, uint) { uint targetETH; uint targetUSDC;
        uint usd = FullMath.mulDiv(eth, price, WAD);
        // if we assumed a 1:1 ratio of eth value
        // to usdc, then this is how'd we balance:
        // int delta = (int(usd) - int(scaled))
        //            / int(2 * price / 1e18);
        // if (delta < 0) { // sell $
        //     selling = uint(delta * -1);
        //     selling = FullMath.mulDiv(
        //         selling, price, 1e30);
        //     usdc -= selling;
        //     eth += ISwapRouter(ROUTER).exactInput(
        //         ISwapRouter.ExactInputParams(abi.encodePacked(
        //             USDC, POOL_FEE, address(weth)), address(this),
        //             block.timestamp, selling, 0));
        // }
        (int24 tick_lower, int24 tick_upper) = _adjustTicks(LAST_TICK);
        uint160 lower = TickMath.getSqrtPriceAtTick(tick_lower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tick_upper);
        uint160 current = TickMath.getSqrtPriceAtTick(LAST_TICK); 
        uint128 liquidity; uint scaled = usdc * 1e12; // precision     
        liquidity = token1isWETH ? LiquidityAmounts.getLiquidityForAmount1(
                                                        current, upper, eth) : 
                                    LiquidityAmounts.getLiquidityForAmount0(
                                                        current, upper, eth);    
        
        // v4-periphery/src/lib/LiqAmounts doesn't have this function...
        (targetETH, targetUSDC) = LiquidityAmounts.getAmountsForLiquidity(
                                         current, lower, upper, liquidity);
        if (token1isWETH)
            (targetETH, targetUSDC) = (targetUSDC, targetETH);

        targetUSDC *= 1e12; 
        if (scaled > targetUSDC) {
            scaled -= targetUSDC;
            scaled /= 1e12;
            ERC20(USDC).transfer(
            address(AMP), scaled);
            AMP.putUSDC(scaled);
            scaled = targetUSDC;
            // ^ this has to stay in 1e18
            // as weth, for formula purposes 
        } 
        if (eth > targetETH) { eth -= targetETH;
            weth.transfer(address(AMP), eth);
            AMP.put(eth); eth = targetETH;
        } 
        if (targetUSDC > scaled) {
            uint k = FullMath.mulDiv(
            targetETH, WAD, targetUSDC);
            uint denom = WAD + FullMath.mulDiv(
                                 k, price, WAD);
        
            uint ky = k * (scaled + 1);
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
            uint selling = FullMath.mulDiv(
                      WAD, eth - ky, denom);
           
            eth -= selling; 
            scaled += ISwapRouter(ROUTER).exactInput(
                ISwapRouter.ExactInputParams(abi.encodePacked(
                    address(weth), POOL_FEE, USDC), address(this),
                    block.timestamp, selling, 0)) * 1e12;
            
            ky = FullMath.mulDiv(
                eth, WAD, scaled);
        } 
        return (eth, scaled / 1e12);
    }

    // if deposited once prior, then
    function deposit(uint amount) // withdraw first... 
        external nonReentrant payable { uint in_dollars; 
        (Deposit memory LP, uint price, uint160 sqrtPrice) = fetch(msg.sender);
        if (amount > 0) weth.transferFrom(msg.sender, address(this), amount);
        if (msg.value > 0) weth.deposit{ value: msg.value }(); 
        LP.fees_eth = ETH_FEES; LP.fees_usd = USD_FEES;
        
        positions[msg.sender] = LP; 
        (amount, in_dollars) = _swap(amount + msg.value, 0, price);
        (uint amount0, uint amount1) = token1isWETH ? 
        (in_dollars, amount) : (amount, in_dollars);

        LP.liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice,
                  TickMath.getSqrtPriceAtTick(LOWER_TICK),
                  TickMath.getSqrtPriceAtTick(UPPER_TICK),
                  amount0, amount1); _repackNFT(amount0, 
                                        amount1, price);
    }

    function take(uint amount) // withdraw ETH
        public onlyUs returns (uint wethAmount) { 
        uint amount0; uint amount1; uint128 liquidity;
        if (token1isWETH)
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                         TickMath.getSqrtPriceAtTick(LAST_TICK),  
                        TickMath.getSqrtPriceAtTick(UPPER_TICK), amount / 2);
        else
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                         TickMath.getSqrtPriceAtTick(LAST_TICK),  
                        TickMath.getSqrtPriceAtTick(UPPER_TICK), amount / 2);
              
        (amount0, amount1, ) = _withdrawAndCollect(liquidity);      
        uint usdcAmount = token1isWETH ? amount0 : amount1;
        wethAmount = token1isWETH ? amount1 : amount0;
        
        wethAmount += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(USDC, POOL_FEE, address(weth)),
                    address(this), block.timestamp, usdcAmount, 0));
                              weth.transfer(msg.sender, wethAmount);
    }

    function depositUSDC(uint amount, 
        uint price) onlyUs public { uint amount0; uint amount1;
        ERC20(USDC).transferFrom(address(AUX), address(this), amount);
        (uint eth, uint usd) = _swap(0, amount, price);
        ETH_FEES += eth; USD_FEES += usd * 1e12;
        (amount0, amount1) = token1isWETH ? 
                (usd, eth) : (eth, usd);
        
        (uint128 liquidity,,) = NFPM.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    ID, amount0, amount1, 0, 0, block.timestamp));
                            liquidityUnderManagement += liquidity;
    }

    function withdrawUSDC(uint amount) public 
        onlyUs returns (uint usd) { uint eth;
        uint128 liquidity;
        if (token1isWETH)
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                         TickMath.getSqrtPriceAtTick(LAST_TICK),  
                        TickMath.getSqrtPriceAtTick(UPPER_TICK), amount / 2);
        else
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                         TickMath.getSqrtPriceAtTick(LAST_TICK),  
                        TickMath.getSqrtPriceAtTick(UPPER_TICK), amount / 2);

        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);
        (eth, usd) = token1isWETH ? (amount1, amount0) : (amount0, amount1);
        usd += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(weth), POOL_FEE, address(USDC)),
                                    address(this), block.timestamp, eth, 0));
                                       ERC20(USDC).transfer(msg.sender, usd);
    }
    
    // @param (amount) is actually
    // a % of their total liquidity
    // if msg.sender != address(AUX)
    function withdraw(uint amount) 
        public nonReentrant payable { 
        uint amount0; uint amount1; 
        require(amount > 0 
             && amount <= 1000, "%");
    
        (Deposit memory LP, uint price, 
        uint160 sqrtPrice) = fetch(msg.sender);
        uint128 withdrawing = uint128(FullMath.mulDiv(amount, uint(LP.liq), 1000)); 
        
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                                TickMath.getSqrtPriceAtTick(LAST_TICK), 
                                TickMath.getSqrtPriceAtTick(LOWER_TICK),
                                TickMath.getSqrtPriceAtTick(UPPER_TICK),
                                withdrawing);
        
        uint ethAmount = token1isWETH ? amount1 : amount0;
        uint usdAmount = token1isWETH ? amount0 : amount1;
        uint eth_fees = ETH_FEES; uint usd_fees = USD_FEES;

        ethAmount += FullMath.mulDiv((eth_fees - LP.fees_eth),
                        LP.liq, liquidityUnderManagement);

        usdAmount += FullMath.mulDiv((usd_fees - LP.fees_usd),
                        LP.liq, liquidityUnderManagement) / 1e12;
        
        
        uint expected = ethAmount + FullMath.mulDiv(usdAmount, price, WAD);
        (amount0, amount1) = token1isWETH ? (usdAmount, ethAmount) 
                                          : (ethAmount, usdAmount);
        
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice,
                                TickMath.getSqrtPriceAtTick(LOWER_TICK),
                                TickMath.getSqrtPriceAtTick(UPPER_TICK),
                                amount0, amount1);
    
        (amount0, amount1, liquidity) = _withdrawAndCollect(liquidity);    
        (ethAmount, usdAmount) = token1isWETH ? (amount1, amount0) 
                                              : (amount0, amount1);
        
        ethAmount += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                            abi.encodePacked(address(USDC), POOL_FEE, address(weth)),
                                    address(this), block.timestamp, usdAmount, 0));    
        weth.withdraw(ethAmount); 
        LP.liq -= liquidity;
        if (expected > ethAmount)
            ethAmount += AMP.get(
             expected - ethAmount);

        (bool success, ) = msg.sender.call{ 
            value: ethAmount }(""); 
            require(success, "$");
    
        if (LP.liq == 0) { delete positions[msg.sender]; }
        else { LP.fees_eth = eth_fees; LP.fees_usd = usd_fees; 
                        positions[msg.sender] = LP; }  
    }
}
