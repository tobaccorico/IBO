
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9.0;

import {AuxV3} from "./AuxV3.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {TickMath} from "./imports/v3/TickMath.sol";
import {FullMath} from "./imports/v3/FullMath.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./imports/v3/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "./imports/v3/INonfungiblePositionManager.sol";
import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; 

// import "lib/forge-std/src/console.sol"; 
contract Router is ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    address public immutable USDC;

    WETH public immutable wS;
    uint public YIELD; // %
    uint public ID; // V3 NFT
    uint public LAST_REPACK;
    
    uint internal PENDING_wS;
    // ^ single-sided liqudity
    // that is waiting for $
    // before it's deposited
    uint private _deployed;
    struct Deposit {
        // Masterchef-style
        // snapshots of fees:
        uint fees_S;
        uint fees_usd;
        uint128 liq;
    } AuxV3 public AUX;

    int24 internal UPPER_TICK;
    int24 internal LOWER_TICK;
    int24 internal LAST_TICK;
    uint constant WAD = 1e18;

    uint24 constant POOL_FEE = 3000;
    int24 constant MAX_TICK = 887220;
    int24 constant TICK_SPACING = 60;
    INonfungiblePositionManager NFPM;

    address public POOL; address public ROUTER;
    uint128 liquidityUnderManagement; // UniV3
    uint public USD_FEES; uint public S_FEES;
    mapping(address => Deposit) positions;    
    
    function fetch(address beneficiary) public 
        returns (Deposit memory, uint, uint160) { 
        Deposit memory LP = positions[beneficiary];
        (uint160 sqrtPrice, 
         int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        LAST_TICK = tick; uint price = getPrice(sqrtPrice);
        return (LP, price, sqrtPrice);
    }   receive() external payable {}

    modifier onlyAux {
        require(msg.sender == address(AUX), "403"); _;
    }

    constructor(address _aux,
        address _weth, address _usdc,
        address _nfpm, address _pool, 
        address _router) { USDC = _usdc;
        POOL = _pool; ROUTER = _router;
        _deployed = block.timestamp;
        wS = WETH(payable(_weth));
        AUX = AuxV3(payable(_aux)); 

        NFPM = INonfungiblePositionManager(_nfpm);
        ERC20(wS).approve(_aux, type(uint256).max);
        ERC20(USDC).approve(_aux, type(uint256).max);
        ERC20(wS).approve(_router, type(uint256).max);
        ERC20(USDC).approve(_router, type(uint256).max);
        ERC20(wS).approve(_nfpm, type(uint256).max);
        ERC20(USDC).approve(_nfpm, type(uint256).max);
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
                (amount0, amount1) = _swap(
                   amount0, amount1, price);  
                (ID, liquidityUnderManagement,,) = NFPM.mint(
                    INonfungiblePositionManager.MintParams({ token0: address(wS),
                        token1: address(USDC), fee: POOL_FEE, tickLower: LOWER_TICK,
                            tickUpper: UPPER_TICK, amount0Desired: amount0,
                    amount1Desired: amount1, amount0Min: 0, amount1Min: 0,
                    recipient: address(this), deadline: block.timestamp }));
                                              LAST_REPACK = block.timestamp;
        } // metrics at the expense of sometimes doing 1 extra swap:
        else { (uint collected0, uint collected1) = _collect(price);
            amount0 += collected0; amount1 += collected1;
            (liquidity,,) = NFPM.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    ID, amount0, amount1, 0, 0, block.timestamp));
                            liquidityUnderManagement += liquidity;
        } 
    } function repackNFT() public nonReentrant
        returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,
        ,,,,,) = IUniswapV3Pool(POOL).slot0();
        _repackNFT(0, 0, getPrice(sqrtPriceX96));
        // TODO test ID before and after, after
        // set_price_eth in mainnetFork
    }
    
    // from v3-periphery/OracleLibrary...
    function getPrice(uint160 sqrtRatioX96)
        public view returns (uint price) {
        uint256 casted = uint256(sqrtRatioX96);
        uint256 ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64); 
        price = FullMath.mulDiv(
            ratioX128, WAD * 1e12, 
            1 << 128
        );
    }

    function _collect(uint price) internal 
        returns (uint amount0, uint amount1) {
        (amount0, amount1) = NFPM.collect( 
            INonfungiblePositionManager.CollectParams(ID,
                address(this), type(uint128).max, type(uint128).max
            )); // "collect calls to the tip sayin' how ya changed"
        if (price > 0) { // we also collect metrics about earnings...
            (amount0, amount1) = _swap(amount0, amount1, price);
                S_FEES += amount0; USD_FEES += amount1 * 1e12;
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
        pure returns (int24 lower, int24 upper) { // staircase
        int256 tickDelta = (int256(currentTick) * 357) / 10000;
        tickDelta = tickDelta == 0 ? TICK_SPACING : tickDelta;
    
        upper = _adjustToNearestIncrement(
            currentTick + int24(tickDelta));
        lower = _adjustToNearestIncrement(
            currentTick - int24(tickDelta));
       
        if (upper == lower) { 
            upper += TICK_SPACING;
        }   return (lower, upper);
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
        //             USDC, POOL_FEE, address(wS)), address(this),
        //             block.timestamp, selling, 0));
        // }
        (int24 tick_lower, int24 tick_upper) = _adjustTicks(LAST_TICK);
        uint160 lower = TickMath.getSqrtPriceAtTick(tick_lower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tick_upper);
        uint160 current = TickMath.getSqrtPriceAtTick(LAST_TICK); 
        uint128 liquidity; uint scaled = usdc * 1e12; // precision 
        liquidity = LiquidityAmounts.getLiquidityForAmount0(
                                        current, upper, eth);

        (targetETH, targetUSDC) = LiquidityAmounts.getAmountsForLiquidity(
                                         current, lower, upper, liquidity);
        targetUSDC *= 1e12; // must also divide at the end for precision
        if (scaled >= targetUSDC) {
            scaled -= targetUSDC;
            AUX.putUSDC(scaled / 1e12);
            scaled = targetUSDC;
            // ^ this has to stay in 1e18
            // as wS, for formula purposes 
        } /* else { // TODO see untouchable in Aux.sol for workaround
            scaled += AUX.withdrawUSDC(targetUSDC - scaled) * 1e12;
        } */ // libable to touch margin USDC
        if (eth > targetETH) {
            eth -= targetETH;
            AUX.putS(eth);
            eth = targetETH;
        } /* else { // adds the most that it can
            eth += AUX.getS(targetETH - eth);
        } */ // liable to touch margin eth
        if (targetUSDC > scaled) {
            uint k = FullMath.mulDiv(
            targetETH, WAD, targetUSDC);
            uint denom = WAD + FullMath.mulDiv(
                                 k, price, WAD);
        
            uint ky = k * (scaled + 1);
            // assume eth is X and usdc is Y...
            // our formula is (x - ky)/(1 + kp);
            // we are selling X to buy Y, where
            // p is the price of eth, and the
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
                    address(wS), POOL_FEE, USDC), address(this),
                    /* block.timestamp, */ selling, 0)) * 1e12;
            
            ky = FullMath.mulDiv(
                eth, WAD, scaled);
        } return (eth, scaled / 1e12);
    }

    // if deposited once prior, then
    function depositS(uint amount) // withdraw first... 
        external nonReentrant payable { uint in_dollars; 
        (Deposit memory LP, uint price, uint160 sqrtPrice) = fetch(msg.sender);
        if (amount > 0) wS.transferFrom(msg.sender, address(this), amount);
        if (msg.value > 0) wS.deposit{ value: msg.value }(); 
        LP.fees_S = S_FEES; LP.fees_usd = USD_FEES;
        
        positions[msg.sender] = LP; 
        (amount, in_dollars) = _swap(amount, 0, price);
        LP.liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice,
                TickMath.getSqrtPriceAtTick(LOWER_TICK),
                TickMath.getSqrtPriceAtTick(UPPER_TICK),
                amount, in_dollars); _repackNFT(amount, 
                                    in_dollars, price);
    }

    function withdrawS(uint amount, uint price)
        public onlyAux returns (uint withdrawn) {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
                                TickMath.getSqrtPriceAtTick(LAST_TICK),  
                                TickMath.getSqrtPriceAtTick(UPPER_TICK), 
                                amount / 2);
        
        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);      
        amount0 += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(USDC), POOL_FEE, address(wS)),
                        address(this), /* block.timestamp, */ amount1, 0));
                                  wS.transfer(address(AUX), amount0);
    }

    function depositUSDC(uint amount, uint price) onlyAux public {
        ERC20(USDC).transferFrom(address(AUX), address(this), amount);
        (uint amount0, uint amount1) = _swap(0, amount, price);
        S_FEES += amount0; USD_FEES += amount1 * 1e12;
        (uint128 liquidity,,) = NFPM.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    ID, amount0, amount1, 0, 0, block.timestamp));
                            liquidityUnderManagement += liquidity;
    }

    function withdrawUSDC(uint amount, uint price) 
        public onlyAux returns (uint withdrawn) {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
                                TickMath.getSqrtPriceAtTick(LAST_TICK),  
                                TickMath.getSqrtPriceAtTick(UPPER_TICK), 
                                amount / 2);
        
        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);      
        amount1 += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(wS), POOL_FEE, address(USDC)),
                        address(this), /* block.timestamp, */ amount0, 0));
                               ERC20(USDC).transfer(address(AUX), amount1);
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
        uint128 liquidating = uint128(FullMath.mulDiv(amount, uint(LP.liq), 1000)); 
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                                TickMath.getSqrtPriceAtTick(LAST_TICK), 
                                TickMath.getSqrtPriceAtTick(LOWER_TICK),
                                TickMath.getSqrtPriceAtTick(UPPER_TICK),
                                liquidating);
            
        uint eth_fees = S_FEES; uint usd_fees = USD_FEES;
        amount0 += FullMath.mulDiv((eth_fees - LP.fees_S),
                        LP.liq, liquidityUnderManagement);

        amount1 += FullMath.mulDiv((usd_fees - LP.fees_usd),
                        LP.liq, liquidityUnderManagement) / 1e12;
        
        uint expected = amount0 + FullMath.mulDiv(amount1, price, WAD);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice,
                                TickMath.getSqrtPriceAtTick(LOWER_TICK),
                                TickMath.getSqrtPriceAtTick(UPPER_TICK),
                                amount0, amount1);
    
        (amount0, amount1, liquidity) = _withdrawAndCollect(liquidity);      
        amount0 += ISwapRouter(ROUTER).exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(USDC), POOL_FEE, address(wS)),
                        address(this), /* block.timestamp, */ amount1, 0));    
    
        wS.withdraw(amount0); 
        LP.liq -= liquidity;
        if (expected > amount0)
            amount0 += AUX.getS(
             expected - amount0);

        (bool success, ) = msg.sender.call{ 
            value: amount0 }(""); 
            require(success, "$");
    
        if (LP.liq == 0) { delete positions[msg.sender]; }
        else { LP.fees_S = eth_fees; LP.fees_usd = usd_fees; 
                        positions[msg.sender] = LP; }  
    }
}
