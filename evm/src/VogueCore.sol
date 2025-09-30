// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from "./Aux.sol";
import {Vogue} from "./Vogue.sol";
import {mockToken} from "./mockToken.sol";
import {Types} from "./imports/Types.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
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

import "lib/forge-std/src/console.sol"; // TODO

contract VogueCore is SafeCallback {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;    
    
    uint public POOLED_ETH;
    uint public POOLED_USD;

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
        }   
        AUX = Aux(payable(_aux));
        VOGUE = Vogue(payable(_vogue));
        VANILLA = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))}); 

        (,int24 tickETH,,,,,) = IUniswapV3Pool(_poolETH).slot0();
        mockUSD.approve(address(poolManager), type(uint).max);
        mockETH.approve(address(poolManager), type(uint).max);
        
        if (token1isETH)
            tickETH *= AUX.token1isWETH() ? int24(1) : int24(-1);
        else
            tickETH *= AUX.token1isWETH() ? int24(-1) : int24(1);       

        poolManager.initialize(VANILLA, TickMath.getSqrtPriceAtTick(tickETH));
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
    
    function swap(uint160 sqrtPriceX96, address sender, 
        bool forOne, address token, uint amount) 
        onlyAux public returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(Action.Swap, 
            sqrtPriceX96, sender, forOne, token, amount)), (BalanceDelta));
    }
    
    function batchSwap(uint160 sqrtPriceX96, uint blockNumber, 
        uint splitForUSD, uint splitForETH) onlyAux public 
        returns (uint swappedForUSD, uint swappedForETH) {
        (swappedForUSD, swappedForETH) = abi.decode(poolManager.unlock(abi.encode(Action.BatchSwap, 
                                sqrtPriceX96, blockNumber, splitForUSD, splitForETH)), (uint, uint));
    }

    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminator = Action(firstByte);
        if (discriminator == Action.Swap) {
            return _handleSwapAction(data[32:]);
        } else if (discriminator == Action.BatchSwap) {
            return _handleBatchSwapAction(data[32:]);
        } else if (discriminator == Action.Repack) {
            return _handleRepackAction(data[32:]);
        } else if (discriminator == Action.OutsideRange) {
            return _handleOutsideRangeAction(data[32:]);
        } else if (discriminator == Action.ModLP) {
            return _handleModLPAction(data[32:]);
        }
        return "";
    }

    function _handleSwapAction(bytes calldata data) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, address sender, bool forOne,
            address token, uint amount) = abi.decode(data, 
             (uint160, address, bool, address, uint));
        
        BalanceDelta delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                zeroForOne: forOne, amountSpecified: -int(amount),
                sqrtPriceLimitX96: VOGUE.paddedSqrtPrice(sqrtPriceX96, 
                                      !forOne, 300) }), ZERO_BYTES);
        
        _handleDelta(delta, true, false, sender, token);
        return abi.encode(delta);
    }

    function _handleBatchSwapAction(bytes calldata data) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, uint lastBlock,
        uint splitForUSD, uint splitForETH) = abi.decode(
            data, (uint160, uint, uint, uint));

        (Types.Batch memory forUSD,
        Types.Batch memory forETH) = VOGUE.getSwapsETH(lastBlock);
        if (forETH.total > splitForETH) {
            BalanceDelta delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({ 
                zeroForOne: token1isETH, 
                amountSpecified: -int(forETH.total - splitForETH), 
                sqrtPriceLimitX96: VOGUE.paddedSqrtPrice(sqrtPriceX96, !token1isETH, 1000) 
            }), ZERO_BYTES);
            if (token1isETH)
                (, splitForETH) = _handleDelta(delta, true, false, address(0), address(0));
            else
                (splitForETH, ) = _handleDelta(delta, true, false, address(0), address(0));
        }
        if (forUSD.total > splitForUSD) {
            BalanceDelta delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                zeroForOne: !token1isETH, 
                amountSpecified: -int(forUSD.total - splitForUSD),
                sqrtPriceLimitX96: VOGUE.paddedSqrtPrice(sqrtPriceX96, token1isETH, 1000) 
            }), ZERO_BYTES);
            if (token1isETH)
                (splitForUSD,) = _handleDelta(delta, true, true, address(0), address(0));
            else
                (, splitForUSD) = _handleDelta(delta, true, true, address(0), address(0));
        }
        return abi.encode(splitForETH, splitForUSD);
    }

    function _handleRepackAction(bytes calldata data) internal returns (bytes memory) {
        (uint128 myLiquidity, uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper) = abi.decode(
                data, (uint128, uint160, int24, int24));
        
        POOLED_USD = 0; POOLED_ETH = 0;
        (BalanceDelta delta, BalanceDelta fees) = _modifyLiquidity(
            -int(uint(myLiquidity)), tickLower, tickUpper);
        
        uint price = AUX.getPrice(sqrtPriceX96);
        (uint delta0, uint delta1) = _handleDelta(delta, false, true, address(0), address(0));
        if (token1isETH) { 
            (delta0, delta1) = VOGUE.addLiquidityHelper(0, delta1, price);
            delta = _modLP(delta0, delta1, tickLower, tickUpper, sqrtPriceX96);
        } else {     
            (delta1, delta0) = VOGUE.addLiquidityHelper(0, delta0, price);
            delta = _modLP(delta1, delta0, tickLower, tickUpper, sqrtPriceX96);
        }
        _handleDelta(delta, true, false, address(0), address(0));

        return abi.encode(price, uint(int(fees.amount0())), uint(int(fees.amount1())), 
                                uint(int(delta.amount0())), uint(int(delta.amount1())));
    }

    function _handleOutsideRangeAction(bytes calldata data) internal returns (bytes memory) {
        (address sender, int liquidity, 
        int24 tickLower, int24 tickUpper, address token) = abi.decode(
                     data, (address, int, int24, int24, address));

        (BalanceDelta delta, ) = _modifyLiquidity(liquidity, tickLower, tickUpper);
        _handleDelta(delta, false, false, sender, token);
        return abi.encode(delta);
    }

    function _handleModLPAction(bytes calldata data) internal returns (bytes memory) {
        (uint160 sqrtPriceX96, uint deltaETH, uint deltaUSD,
        int24 tickLower, int24 tickUpper, address sender) = abi.decode(
                data, (uint160, uint, uint, int24, int24, address));
        
        BalanceDelta delta = _modLP(deltaUSD, deltaETH, tickLower, tickUpper, sqrtPriceX96);
        bool keep = deltaUSD == 0;
        _handleDelta(delta, true, keep, sender, address(0));
        return abi.encode(delta);
    }

    function _handleDelta(BalanceDelta delta, bool inRange, bool keep, 
        address who, address token) internal returns (uint, uint) {
        Currency usdCurrency = token1isETH ? VANILLA.currency0 : VANILLA.currency1;
        Currency ethCurrency = token1isETH ? VANILLA.currency1 : VANILLA.currency0;
        mockToken usdToken = token1isETH ? mockUSD : mockETH;
        mockToken ethToken = token1isETH ? mockETH : mockUSD;
        
        int128 usdDelta = token1isETH ? delta.amount0() : delta.amount1();
        int128 ethDelta = token1isETH ? delta.amount1() : delta.amount0();
      
        uint usdAmount;
        uint ethAmount;
        if (usdDelta > 0) {
            usdAmount = uint(int(usdDelta)); 
            usdCurrency.take(poolManager, address(this), usdAmount, false);
            usdToken.burn(usdAmount);
            if (inRange) POOLED_USD -= usdAmount;
            
            if (!keep && token != address(0)) { 
                uint took = AUX.take(who, usdAmount, token, false);
            }
        }
        else if (usdDelta < 0) {
            usdAmount = uint(int(-usdDelta));
            usdToken.mint(usdAmount);
            usdCurrency.settle(poolManager, address(this), usdAmount, false);
            if (inRange) POOLED_USD += usdAmount;
        }
        if (ethDelta > 0) {
            ethAmount = uint(int(ethDelta));
            ethCurrency.take(poolManager, address(this), ethAmount, false);
            ethToken.burn(ethAmount);
            if (inRange) POOLED_ETH -= ethAmount;
            if (who != address(0)) VOGUE.takeETH(ethAmount, who);
        } 
        else if (ethDelta < 0) {
            ethAmount = uint(int(-ethDelta));
            ethToken.mint(ethAmount);
            ethCurrency.settle(poolManager, address(this), ethAmount, false);
            if (inRange) POOLED_ETH += ethAmount;
        }
        if (token1isETH) return (usdAmount, ethAmount);
        else return (ethAmount, usdAmount);
    }

    function _modifyLiquidity(int delta, int24 lowerTick, int24 upperTick) 
        internal returns (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            VANILLA, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }
    
    function _modLP(uint deltaUSD, uint deltaETH, 
        int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96) 
        internal returns (BalanceDelta) {
        
        int flip = deltaUSD > 0 ? int(1) : int(-1);
        uint128 liquidity = token1isETH ? LiquidityAmounts.getLiquidityForAmount1(
                            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, deltaETH) : 
                            LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, 
                                TickMath.getSqrtPriceAtTick(tickUpper), deltaETH);
                                    
        (BalanceDelta totalDelta, ) = _modifyLiquidity(
            flip * int(uint(liquidity)), tickLower, tickUpper);
        return totalDelta;
    }
    
    function poolStats() public returns (uint160 sqrtPriceX96, 
        int24 currentTick, uint128 liquidity) { 
        PoolId pool = VANILLA.toId();
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(pool);
        liquidity = poolManager.getLiquidity(pool);
    }

    function repack(uint128 myLiquidity, uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper) public onlyAux 
        returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1) {
        (price, fees0, fees1, delta0, delta1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Repack, myLiquidity, 
                sqrtPriceX96, tickLower, tickUpper)), 
            (uint, uint, uint, uint, uint));
    }
}