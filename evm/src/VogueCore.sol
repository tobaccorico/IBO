// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from "./Aux.sol";
import {Vogue} from "./Vogue.sol";
import {mockToken} from "./mockToken.sol";
import {Types} from "./imports/Types.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {stdMath} from "forge-std/StdMath.sol";
import "lib/forge-std/src/console.sol"; // TODO

// does not hold tokens, just a logic
contract VogueCore is SafeCallback {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;    

    mapping(uint => Types.Batch) swapsZeroForOne;
    mapping(uint => Types.Batch) swapsOneForZero;
    
    mockToken internal mockETH; 
    mockToken internal mockUSD;
    uint constant WAD = 1e18;
    bool public token1isETH;
    Aux AUX; Vogue VOGUE;
    PoolKey VANILLA; 
    enum Action { 
        Swap, BatchSwap, 
        Repack, ModLP,
        OutsideRange
    }
    // currently "in-range"...
    // which is distinct from 
    // its mockToken.totalSupply()
    uint public POOLED_ETH;
    uint public POOLED_USD;

    uint public LAST_REPACK;
    // range = between ticks
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    
    // ^ timestamp allows us
    // to measure APY% for...
    uint public USD_FEES;
    uint public ETH_FEES;
    uint public YIELD;
    
    
    modifier onlyAux {
        require(msg.sender == address(AUX)
             || msg.sender == address(VOGUE), "403"); _;
    } bytes internal constant ZERO_BYTES = bytes("");
    constructor(IPoolManager _manager) 
        SafeCallback(_manager) {}
       
    function setup(address _vogue, 
        address _aux, address _poolETH) external { 
        require(address(VOGUE) == address(0), "!");
        mockETH = new mockToken(address(this), 18);
        mockUSD = new mockToken(address(this), 6);
        address token0; address token1; 
        if (address(mockETH) > address(mockUSD)) { 
            token1isETH = true;
            token0 = address(mockUSD); 
            token1 = address(mockETH);
        } else {
            token0 = address(mockETH); 
            token1 = address(mockUSD);
        }   AUX = Aux(payable(_aux));
        
        VOGUE = Vogue(payable(_vogue));
        VANILLA = PoolKey({
            currency0: Currency.wrap(
                     address(token0)),
            currency1: Currency.wrap(
                     address(token1)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))}); 

        (,int24 tickETH,,,,,) = IUniswapV3Pool(_poolETH).slot0();
        mockUSD.approve(address(poolManager), type(uint).max);
        mockETH.approve(address(poolManager), type(uint).max);
        
        if (token1isETH)
            tickETH *= AUX.token1isWETH() ? int24(1) : int24(-1);
        else 
            tickETH *= AUX.token1isWETH() ? int24(-1) : int24(1);
        
        poolManager.initialize(VANILLA, 
        TickMath.getSqrtPriceAtTick(tickETH));
    }
   
    function modLP(uint160 sqrtPriceX96, uint deltaETH, uint deltaUSD,
    int24 tickLower, int24 tickUpper, address sender) public onlyAux {
        abi.decode(poolManager.unlock(abi.encode(
                Action.ModLP, sqrtPriceX96, deltaETH, deltaUSD, 
                tickLower, tickUpper, sender)), (BalanceDelta));
    }

    function outOfRange(address sender, int liquidity, 
        int24 tickLower, int24 tickUpper, address token) 
        public onlyAux { 
        abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, sender, liquidity, 
            tickLower, tickUpper, token)), (BalanceDelta));
    }

    // this is for batched swaps, which clear through simple ASS...
    function pushSwap(bool zeroForOne, // < direction of this swap
        Types.Trade calldata trade, uint waitable) onlyAux public 
        returns (uint currentBlock) { currentBlock = block.number;
        Types.Batch storage forOne; Types.Batch storage forZero;
       
        forOne = swapsZeroForOne[currentBlock];
        forZero = swapsOneForZero[currentBlock];
        while (forOne.swaps.length + forZero.swaps.length > 30) {
            currentBlock += 1;
            forOne = swapsZeroForOne[currentBlock];
            forZero = swapsOneForZero[currentBlock];
        }
        Types.Batch storage ourBatch; // < will be writing to this
        require(waitable >= currentBlock - block.number, "time");
        ourBatch = zeroForOne ? forOne : forZero;
        ourBatch.swaps.push(trade); 
        ourBatch.total += trade.amount;
    } 

    function getSwapsETH(uint blockNumber) public view returns 
        (Types.Batch memory, Types.Batch memory) {
        if (token1isETH)
            return (swapsOneForZero[blockNumber], 
                    swapsZeroForOne[blockNumber]);
        else
            return (swapsZeroForOne[blockNumber], 
                    swapsOneForZero[blockNumber]);
    }
    
    function swap(uint160 sqrtPriceX96, address sender, 
        bool forOne, address token, uint amount) 
        onlyAux public returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(Action.Swap, 
            sqrtPriceX96, sender, forOne, token, amount)), (BalanceDelta));
    }
    
    function batchSwap(uint160 sqrtPriceX96, uint blockNumber, 
        uint splitForUSD, uint splitForETH, uint gotForETH, 
        uint gotForUSD) onlyAux public returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(Action.BatchSwap, 
                    sqrtPriceX96, blockNumber, splitForUSD, splitForETH, 
                    gotForETH, gotForUSD)), (BalanceDelta));
    }

    // what does it take for her to call me back
    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte; BalanceDelta delta;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminator = Action(firstByte);
        // ^ similar to Solana program entrypoint
        if (discriminator == Action.Swap) {
             (uint160 sqrtPriceX96, address sender, bool forOne,
                address token, uint amount) = abi.decode(data[32:], 
                 (uint160, address, bool, address, uint));
            
            delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                    zeroForOne: forOne, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                          !forOne, 300) }), ZERO_BYTES);
            if (token1isETH)
                _handleDelta0isUSD(delta, true, false, sender, token);
            else
                _handleDelta1isUSD(delta, true, false, sender, token);
        } 
        else if (discriminator == Action.BatchSwap) {
            // NOTE: order is crucial (first buy ETH)
            (uint160 sqrtPriceX96, uint lastBlock,
             uint splitForUSD, uint splitForETH,
             uint gotForETH, uint gotForUSD) = abi.decode(
                data[32:], (uint160, uint, uint, uint, uint, uint));

            uint swapped; uint i;
            (Types.Batch memory forUSD,
            Types.Batch memory forETH) = getSwapsETH(lastBlock);
            
            uint amount = forETH.total - splitForETH;
            // we substract split because that amount
            // was already covered by V3, only needs
            // to be distributed (not swapped by V4) 
            if (amount > 0) { // selling USD for ETH
                delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({ 
                    zeroForOne: token1isETH, amountSpecified: -int(amount), 
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                     !token1isETH, 1000) }), ZERO_BYTES);
                if (token1isETH)
                    (, swapped) = _handleDelta0isUSD(delta, true, false, 
                                                address(0), address(0));
                else
                    (swapped, ) = _handleDelta1isUSD(delta, true, false, 
                                                address(0), address(0));
                // obtain new price... 
                swapped += gotForUSD; // in light of the above swaps...
                (sqrtPriceX96,,,) = poolManager.getSlot0(VANILLA.toId()); 
                require(stdMath.delta(swapped, FullMath.mulDiv(forETH.total * 1e12, WAD, 
                                    AUX.getPrice(sqrtPriceX96))) <= swapped / 50);

                for (i = 0; i < forETH.swaps.length; i++) {
                    // we get the ETH amount to send by...
                    amount = FullMath.mulDiv(swapped, // % given from
                    // dollars being sold by sender over total dollars 
                              forETH.swaps[i].amount, forETH.total);
                    VOGUE.takeETH(amount, forETH.swaps[i].sender);
                }
            } amount = forUSD.total - splitForUSD;
            // we substract split because that amount
            // was already covered by V3, only needs
            // to be distributed (not swapped by V4) 
            if (amount > 0) { // selling ETH for USD
                delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                    zeroForOne: !token1isETH, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                      token1isETH, 1000) }), ZERO_BYTES);
                if (token1isETH)
                    (swapped,) = _handleDelta0isUSD(delta, true, true, 
                                                address(0), address(0));
                else // keep is true because we do AUX.take in the loop
                    (, swapped) = _handleDelta1isUSD(delta, true, true, 
                                                address(0), address(0));
           
                address out; uint scale; swapped += gotForETH;
                (sqrtPriceX96,,,) = poolManager.getSlot0(VANILLA.toId());
                require(stdMath.delta(swapped, FullMath.mulDiv(forUSD.total, 
                        AUX.getPrice(sqrtPriceX96), WAD * 1e12)) <= swapped / 50);

                for (i = 0; i < forUSD.swaps.length; i++) {
                    out = forUSD.swaps[i].token;
                    amount = FullMath.mulDiv(swapped, 
                        forUSD.swaps[i].amount, forUSD.total);

                    scale = IERC20(out).decimals() - 6; 
                    amount *= scale > 0 ? (10 ** scale) : 1;
                    uint actualReceived = AUX.take(forUSD.swaps[i].sender, 
                                                    amount, out, false);
                }
            } delete swapsOneForZero[lastBlock];
              delete swapsZeroForOne[lastBlock];
        } 
        else if (discriminator == Action.Repack) {
            // remove all liquidity, then add it back
            (uint128 myLiquidity, uint160 sqrtPriceX96,
            int24 tickLower, int24 tickUpper) = abi.decode(
                    data[32:], (uint128, uint160, int24, int24));
            
            uint price = AUX.getPrice(sqrtPriceX96);        
            uint eth_fees; uint usd_fees;
            // ^ these 2 are accounting our gains
            // collected since last repack event
            uint delta0; uint delta1; 
            
            POOLED_USD = 0; POOLED_ETH = 0; BalanceDelta fees; 
            (delta, fees) = _modifyLiquidity(-int(uint(myLiquidity)), 
                                            tickLower, tickUpper);
            if (token1isETH) { 
                (delta0, // who is irrelevant (address(0))
                 delta1) = _handleDelta0isUSD(delta, false, true, 
                                        address(0), address(0));
             
                usd_fees = uint(int(fees.amount0()));
                eth_fees = uint(int(fees.amount1()));
                
                YIELD = _calculateYield(eth_fees, usd_fees,
                                    delta1, delta0, price);
            } else { 
                (delta0, // who is irrelevant (address(0))
                 delta1) = _handleDelta1isUSD(delta, false, true, 
                                        address(0), address(0));

                usd_fees = uint(int(fees.amount1()));
                eth_fees = uint(int(fees.amount0()));

                YIELD = _calculateYield(eth_fees, usd_fees, 
                                    delta0, delta1, price);
            } (tickLower,, 
               tickUpper,) = _updateTicks(
                        sqrtPriceX96, 200);
           
            UPPER_TICK = tickUpper;
            LOWER_TICK = tickLower;
            USD_FEES += usd_fees;
            ETH_FEES += eth_fees;
            
            if (token1isETH) {
                (delta0, delta1) = VOGUE.addLiquidityHelper(
                                            0, delta1, price);

                delta = _modLP(delta0, delta1, tickLower,
                                tickUpper, sqrtPriceX96);

                _handleDelta0isUSD(delta, true, false,
                            address(0), address(0));
            } else {
                (delta1, delta0) = VOGUE.addLiquidityHelper(
                                            0, delta0, price);

                delta = _modLP(delta1, delta0, tickLower,
                                tickUpper, sqrtPriceX96);
                
                _handleDelta1isUSD(delta, true, false,
                                address(0), address(0));
            }
        } else if (discriminator == Action.OutsideRange) {
            (address sender, int liquidity, 
            int24 tickLower, int24 tickUpper, address token) = abi.decode(
                         data[32:], (address, int, int24, int24, address));

            (delta, ) = _modifyLiquidity(liquidity,
                            tickLower, tickUpper);

            if (token1isETH)
                _handleDelta0isUSD(delta, false, false,
                                        sender, token);
            else
                _handleDelta1isUSD(delta, false, false,
                                        sender, token);
        }
        else if (discriminator == Action.ModLP) {
            (uint160 sqrtPriceX96, uint deltaETH, uint deltaUSD,
            int24 tickLower, int24 tickUpper, address sender) = abi.decode(
                    data[32:], (uint160, uint, uint, int24, int24, address));
            
            delta = _modLP(deltaUSD, deltaETH, tickLower,
                                tickUpper, sqrtPriceX96); 
                                bool keep = deltaUSD == 0;    
            if (token1isETH)
                _handleDelta0isUSD(delta, true, keep, 
                                sender, address(0));
            else
                _handleDelta1isUSD(delta, true, keep, 
                                sender, address(0));
        }   
        return abi.encode(delta);
    } 

    // if who = address(0), keep & token are
    // irrelevant (for repack and batch swaps)
    function _handleDelta0isUSD(BalanceDelta delta, bool inRange, 
        bool keep, address who, address token) internal 
        returns (uint delta0, uint delta1) {
        if (delta.amount0() > 0) {
            delta0 = uint(int(delta.amount0()));
            VANILLA.currency0.take(poolManager,
                address(this), delta0, false);
            
            mockUSD.burn(delta0); 
            if (inRange) POOLED_USD -= delta0;
            if (!keep && token != address(0)) {
                uint scale = IERC20(token).decimals() - 6;
                if (scale > 0) // upscale
                    delta0 *= 10 ** scale;
    
                // up to 2% tolerance for fees
                uint actualReceived = AUX.take(who,
                         delta0, token, false);

                console.log("1actualReceived", actualReceived);
                console.log("1delta0", delta0);

                require(stdMath.delta(delta0, 
                        actualReceived) <= delta0 / 50, "fee");
            } // keep is for preventing disbursal of $ 
            // when single-sided LPs withdraw their ETH 
        } else if (delta.amount0() < 0) {
            delta0 = uint(int(-delta.amount0())); 
            mockUSD.mint(delta0);
            
            VANILLA.currency0.settle(poolManager, 
                    address(this), delta0, false);
            if (inRange) POOLED_USD += delta0;
        } 
        if (delta.amount1() > 0) { 
            delta1 = uint(int(delta.amount1()));
            VANILLA.currency1.take(poolManager, 
                address(this), delta1, false);
            
            mockETH.burn(delta1); 
            if (inRange) POOLED_ETH -= delta1;
            if (who != address(0)) VOGUE.takeETH(delta1, who);
        } 
        else if (delta.amount1() < 0) {
            delta1 = uint(int(-delta.amount1())); 
            mockETH.mint(delta1);
            
            VANILLA.currency1.settle(poolManager, 
                    address(this), delta1, false);
            if (inRange) POOLED_ETH += delta1;
        }
    }

    function _handleDelta1isUSD(BalanceDelta delta, bool inRange, 
        bool keep, address who, address token) internal 
        returns (uint delta0, uint delta1) { 
        if (delta.amount0() > 0) {
            delta0 = uint(int(delta.amount0())); 
            VANILLA.currency0.take(poolManager, 
                address(this), delta0, false);
            
            mockETH.burn(delta0);
            if (inRange) POOLED_ETH -= delta0;
            if (who != address(0)) VOGUE.takeETH(delta0, who);          
        } // liquidity pool received ETH
        else if (delta.amount0() < 0) { 
            delta0 = uint(int(-delta.amount0())); 
            mockETH.mint(delta0);
            
            VANILLA.currency0.settle(poolManager, 
                address(this), delta0, false);
            if (inRange) POOLED_ETH += delta0;
        } 
        if (delta.amount1() > 0) { 
            delta1 = uint(int(delta.amount1()));
            VANILLA.currency1.take(poolManager,
                address(this), delta1, false);
            
            mockUSD.burn(delta1); 
            if (inRange) POOLED_USD -= delta1;
            if (!keep && token != address(0)) {
                uint scale = IERC20(token).decimals() - 6;
                if (scale > 0) // upscale
                    delta1 *= 10 ** scale;
                
                // Increase tolerance for fees - allow up to 2% difference
                uint actualReceived = AUX.take(who, delta1, token, false);
                console.log("0actualReceived", actualReceived);
                console.log("0delta1", delta1);
                require(stdMath.delta(delta1, 
                        actualReceived) <= delta1 / 50, "fee");
            } // keep is for preventing disbursal of $ 
            // when single-sided LPs withdraw their ETH 
        } 
        else if (delta.amount1() < 0) {
            delta1 = uint(int(-delta.amount1())); 
            mockUSD.mint(delta1);
            
            VANILLA.currency1.settle(poolManager, 
                    address(this), delta1, false);
            if (inRange) POOLED_USD += delta1;
        }
    }

    function _modifyLiquidity(int delta, // liquidity delta
        int24 lowerTick, int24 upperTick) internal returns 
        (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            VANILLA, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }
    
    function _modLP(uint deltaUSD, uint deltaETH, 
        int24 tickLower, int24 tickUpper, 
        uint160 sqrtPriceX96) internal
        returns (BalanceDelta) { int flip = deltaUSD > 0 ? int(1) : int(-1);
        uint128 liquidity = token1isETH ? LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, deltaETH) : 
                    LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, 
                        TickMath.getSqrtPriceAtTick(tickUpper), deltaETH);
                               
        (BalanceDelta totalDelta, 
         BalanceDelta feesAccrued) = _modifyLiquidity(flip * 
            int(uint(liquidity)), tickLower, tickUpper);
        return totalDelta; // if we called _modify with (-) liquidity
        // then funds left the pool, so totalDelta should be positive
    }
    
    function alignTick(int24 tick, int24 width)
        public pure returns (int24) {
        if (tick < 0 && tick % width != 0) {
            return ((tick - width + 1) / width) * width;
        }   return (tick / width) * width;
    }

    function _updateTicks(uint160 sqrtPriceX96, uint delta) 
        internal view returns (int24 tickLower, uint160 lower, 
                             int24 tickUpper, uint160 upper) {
        
        lower = _paddedSqrtPrice(sqrtPriceX96, false, delta);
        upper = _paddedSqrtPrice(sqrtPriceX96, true, delta);

        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minPrice");
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxPrice");

        tickLower = alignTick(TickMath.getTickAtSqrtPrice(lower), int24(10));        
        tickUpper = alignTick(TickMath.getTickAtSqrtPrice(upper), int24(10));
    }

    function _calculateYield(uint fees, uint usd_fees, uint delta, 
        uint deltaUSD, uint price) internal returns (uint yield) {
        uint last_repack = LAST_REPACK;
        if (last_repack > 0) { // extrapolate (guestimate) an annual % yield... 
            // based on the % fee yield of the last period (in between repacks)
            yield = FullMath.mulDiv(365 days / (block.timestamp - last_repack),
                           usd_fees * 1e12 + FullMath.mulDiv(price, fees, WAD), 
                          deltaUSD * 1e12 + FullMath.mulDiv(price, delta, WAD));

            LAST_REPACK = block.timestamp; 
        } 
    }

    function _paddedSqrtPrice(uint160 sqrtPriceX96, 
        bool up, uint delta) internal view returns (uint160) {
        uint factor = up ? FixedPointMathLib.sqrt((10000 + delta) * 1e18 / 10000) 
                         : FixedPointMathLib.sqrt((10000 - delta) * 1e18 / 10000);
        return uint160(FixedPointMathLib.mulDivDown(sqrtPriceX96, factor, 1e9));
    }

    function _repack() internal returns 
        (uint160 sqrtPriceX96, int24 tickLower, 
        int24 tickUpper, uint128 myLiquidity) { 
        int24 currentTick; PoolId pool = VANILLA.toId();
        
        tickUpper = UPPER_TICK; tickLower = LOWER_TICK;
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(pool);
        if (currentTick > tickUpper || currentTick < tickLower) { 
            myLiquidity = poolManager.getLiquidity(pool);
            if (myLiquidity > 0) { // rm, then add liquidity
                poolManager.unlock(abi.encode(Action.Repack,
                                  myLiquidity, sqrtPriceX96, 
                                    tickLower, tickUpper));
            } else { // we only go in here once (first time)
                (tickLower,, 
                 tickUpper,) = _updateTicks(sqrtPriceX96, 200);
                // 1% delta up, 1% down from ^^^^^^ (2% wide)
                UPPER_TICK = tickUpper; 
                LOWER_TICK = tickLower;
            }            
        }
    }
    function repack() public onlyAux returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        (sqrtPriceX96, tickLower, tickUpper, myLiquidity) = _repack();
    }
}
