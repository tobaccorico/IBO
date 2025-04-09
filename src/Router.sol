
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Basket} from "./Basket.sol";
import {Auxiliary} from "./Auxiliary.sol";
import {mockToken} from "./mockToken.sol";
import {Types} from "./imports/Types.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base

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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract Router is SafeCallback, Ownable {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    PoolKey VANILLA;
    IUniswapV3Pool v3Pool;
    mockToken private mockETH; 
    mockToken private mockUSD;
    Basket QUID; Auxiliary AUX;

    mapping(uint => Types.Batch) swapsZeroForOne;
    mapping(uint => Types.Batch) swapsOneForZero;

    mapping(address => uint[]) positions;
    // ^ allows several selfManaged positions
    mapping(uint => Types.SelfManaged) selfManaged;
    // ^ key is the tokenId
    uint internal tokenId;
    // ^ always incrementing

    enum Action { Swap,
        Repack, ModLP,
        OutsideRange
    } // from AUX...
    
    uint public POOLED_USD;
    // ^ currently "in-range"
    uint public POOLED_ETH;
    // these define "in-range"
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for:
    uint public USD_FEES;
    uint public ETH_FEES;
    uint public YIELD; // TODO:
    // use ring buffer to average
    // out the yield over a week

    uint constant WAD = 1e18;

    bytes internal constant ZERO_BYTES = bytes("");
    constructor(IPoolManager _manager) 
        SafeCallback(_manager) 
        Ownable(msg.sender) {}

    modifier onlyAux {
        require(msg.sender == address(AUX), "403"); _;
    }
    
    // must send $1 USDC to address(this) & attach msg.value 1 wei
    function setup(address _quid, address _aux, 
        address _pool) external payable onlyOwner {
        // these virtual balances represent assets inside the curve
        mockToken temporaryToken = new mockToken(address(this), 18);
        mockToken tokenTemporary = new mockToken(address(this), 6);
        if (address(temporaryToken) > address(tokenTemporary)) {
            mockETH = temporaryToken; mockUSD = tokenTemporary;
        } else { 
            mockETH = tokenTemporary; mockUSD = temporaryToken;
        }    
        require(mockUSD.decimals() == 6, "1e6");
        require(address(QUID) == address(0), "QUID");
        QUID = Basket(_quid); VANILLA = PoolKey({
            currency0: Currency.wrap(address(mockUSD)),
            currency1: Currency.wrap(address(mockETH)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))}); 

        renounceOwnership(); require(QUID.V4() == address(this), "!");
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(_pool).slot0();
        poolManager.initialize(VANILLA, sqrtPriceX96);
        
        AUX = Auxiliary(payable(_aux));
        mockUSD.approve(address(poolManager),
                        type(uint256).max);
        mockETH.approve(address(poolManager),
                        type(uint256).max);
    }

    // "distance" is how far away from current price
    // measured in ticks (100 = 1%); negative = add
    function outOfRange(address sender, uint amount, 
        address token, int24 distance, uint range) 
        public onlyAux returns (uint next) {

        require(distance % 200 == 0 && distance != 0
            && (distance >= -5000 || distance <= 5000), "distance");
        require(range >= 100 && range <= 1000 && range % 50 == 0, "width");

        (uint160 sqrtPriceX96,
        int24 lowerTick, int24 upperTick,) = repack();
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(
            TickMath.getTickAtSqrtPrice(sqrtPriceX96)
            - int24(distance) // shift away from current
            // price using tick value +/- 2-50% going in
            // increments of 1 % (half a % for the range)
        );
         int liquidity; 
        (int24 tickLower, uint160 lower,
         int24 tickUpper, uint160 upper) = updateTicks(
                                      sqrtPriceX96, range);
        if (token == address(0)) {
            require(lowerTick > tickUpper, "right");
            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmount1(
                    lower, upper, amount
                )));
        } else {
            require(tickLower > upperTick, "left");
            amount = QUID.deposit(sender, token, amount);
            uint scale = IERC20(token).decimals() - 6;
            amount /= scale > 0 ? (10 ** scale) : 1;
            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmount0(
                    lower, upper, amount
                )));
        }
        Types.SelfManaged memory newPosition = Types.SelfManaged({
            owner: sender, lower: tickLower, 
            upper: tickUpper, liq: liquidity
        });
        next = tokenId + 1;
        selfManaged[next] = newPosition;
        positions[sender].push(next);
        tokenId = next;
        _outOfRange(sender, liquidity, 
                tickLower, tickUpper);
    }

    function reclaim(uint id, int percent) external {
        Types.SelfManaged memory position = selfManaged[id];
        require(position.owner == msg.sender, "403");
        require(percent > 0 && percent < 101, "%");
        int liquidity = position.liq * percent / 100;
        uint[] storage myIds = positions[msg.sender];
        uint lastIndex = myIds.length - 1;
        if (percent == 100) { delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) {
                        myIds[i] = myIds[lastIndex];
                    }   myIds.pop(); break;
                }
            }
        } else {    position.liq -= liquidity;
            require(position.liq > 0, "reclaim");
            selfManaged[id] = position;
        }
        _outOfRange(msg.sender, -liquidity, 
            position.lower, position.upper);
    } 


    function _outOfRange(address sender, int liquidity, int24 tickLower, 
        int24 tickUpper) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, sender, liquidity,
            tickLower, tickUpper)), (BalanceDelta));
    }

    function modLP(uint160 sqrtPriceX96, uint delta1, uint delta0, 
        int24 tickLower, int24 tickUpper, address sender) // ^ USD
        public onlyAux returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(
                Action.ModLP, sqrtPriceX96, delta1, delta0, 
                tickLower, tickUpper, sender)), (BalanceDelta));
    }
    
    function pushSwapZeroForOne(Types.Trade calldata trade) onlyAux public {
        Types.Batch storage ourBatch = swapsZeroForOne[block.number];
        Types.Batch memory otherBatch = swapsOneForZero[block.number];
        if (ourBatch.swaps.length + otherBatch.swaps.length > 30) 
            ourBatch = swapsZeroForOne[block.number + 1];
        ourBatch.swaps.push(trade); 
        ourBatch.total += trade.amount;
    }

    function pushSwapOneForZero(Types.Trade calldata trade) onlyAux public {
        Types.Batch storage ourBatch = swapsOneForZero[block.number];
        Types.Batch memory otherBatch = swapsZeroForOne[block.number];
        if (ourBatch.swaps.length + otherBatch.swaps.length > 30) // TODO liable to overfill the following batch
            ourBatch = swapsOneForZero[block.number + 1];
        
        ourBatch.swaps.push(trade); 
        ourBatch.total += trade.amount;
    }

    function getSwaps(uint whichBlock) public view returns 
        (Types.Batch memory, Types.Batch memory) {
        return (swapsOneForZero[whichBlock], 
                swapsZeroForOne[whichBlock]);
    }
    
    function swap(uint160 sqrtPriceX96, uint lastBlock, 
        uint splitForZero, uint splitForOne, 
        uint gotForZero, uint gotForOne) 
        onlyAux public returns (bytes memory) {
        abi.decode(poolManager.unlock(abi.encode(Action.Swap, 
            sqrtPriceX96, lastBlock, splitForZero, splitForOne, 
            gotForZero, gotForOne)), (BalanceDelta));
        
        return abi.encode(gasleft());   
    }

    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte; BalanceDelta delta;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminant = Action(firstByte);
        if (discriminant == Action.Swap) {
            // first we buy ETH then we sell it
            (uint160 sqrtPriceX96, uint lastBlock,
             uint splitForZero, uint splitForOne,
             uint gotForZero, uint gotForOne) = abi.decode(
                data[32:], (uint160, uint, uint, uint, uint, uint));
                    
            Types.Batch memory forZero = swapsOneForZero[lastBlock];
            Types.Batch memory forOne = swapsZeroForOne[lastBlock];
            uint amount = forOne.total - splitForOne;
            if (amount > 0) {
                delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                        false, 3000) }), ZERO_BYTES);
               
                (, uint delta1) = _handleDelta(delta, true, 
                                        false, address(0));
                 
                for (uint i = 0; i < forOne.swaps.length; i++) {
                    amount = FullMath.mulDiv(delta1 + gotForOne, 
                              forOne.swaps[i].amount, forOne.total);
                    
                    AUX.sendETH(amount, forOne.swaps[i].sender);
                }
                delete swapsZeroForOne[lastBlock];
                (sqrtPriceX96,,,) = poolManager.getSlot0(VANILLA.toId());
            }
            amount = forZero.total - splitForZero;
            if (amount > 0) {
                delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                    zeroForOne: false, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                        true, 3000) }), ZERO_BYTES);
                
                (uint delta0,) = _handleDelta(delta, true, 
                                        false, address(0));
                address out; uint scale;
                for (uint i = 0; i < forZero.swaps.length; i++) {
                    amount = FullMath.mulDiv(delta0 + gotForZero, 
                             forZero.swaps[i].amount, forZero.total);
                    
                    out = forZero.swaps[i].token;
                    scale = IERC20(out).decimals() - 6; 
                    amount *= scale > 0 ? (10 ** scale) : 1;
                    
                    require(stdMath.delta(amount, QUID.take(
                       forZero.swaps[i].sender, amount, out)) <= 5);
                }
                delete swapsOneForZero[lastBlock];
            }
        } 
        else if (discriminant == Action.Repack) {
            (uint128 myLiquidity, uint160 sqrtPriceX96,
            int24 tickLower, int24 tickUpper) = abi.decode(
                data[32:], (uint128, uint160, int24, int24));
                uint price = AUX.getPrice(sqrtPriceX96, false);

            BalanceDelta fees; POOLED_ETH = 0; POOLED_USD = 0;
            (delta, // helper resets ^^^^^^^^^^^^^^^^^^^^^^^^
             fees) = _modifyLiquidity(
                -int(uint(myLiquidity)),
                 tickLower, tickUpper);

            (uint delta0, // who address is irrelevant for this call...
             uint delta1) = _handleDelta(delta, false, true, address(0));
            
            uint eth_fees = uint(int(fees.amount1()));
            uint usd_fees = uint(int(fees.amount0()));
            
            if (LAST_REPACK > 0) { // extrapolate (guestimate) an annual % yield... 
                // based on the % fee yield of the last period (in between repacks)
                YIELD = FullMath.mulDiv(365 days / (block.timestamp - LAST_REPACK),
                    usd_fees * 1e12 + FullMath.mulDiv(price, eth_fees, WAD), 
                        delta0 * 1e12 + FullMath.mulDiv(price, delta1, WAD));
            }
            LAST_REPACK = block.timestamp; 
            
            (tickLower,, 
             tickUpper,) = updateTicks(sqrtPriceX96, 200);
            
            UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            USD_FEES += usd_fees; ETH_FEES += eth_fees;

            (delta0, delta1) = AUX.addLiquidityHelper(
                                     0, delta1, price);

            delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96);
            
            // keep and who are irrelevant for this call
            _handleDelta(delta, true, false, address(0));
        } 
        else if (discriminant == Action.OutsideRange) {
            (address sender, int liquidity, 
            int24 tickLower, int24 tickUpper) = abi.decode(
                    data[32:], (address, int, int24, int24));

            (delta, ) = _modifyLiquidity(liquidity,
                            tickLower, tickUpper);

            _handleDelta(delta, false, false, sender);
        }
        else if (discriminant == Action.ModLP) {
            (uint160 sqrtPriceX96, uint delta1, uint delta0,
            int24 tickLower, int24 tickUpper, address sender) = abi.decode(
                data[32:], (uint160, uint, uint, int24, int24, address));

            delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96);
            
            _handleDelta(delta, true, delta0 > 0, sender);
        }
        return abi.encode(delta);
    }

    function _handleDelta(BalanceDelta delta, 
        bool inRange, bool keep, address who) internal 
        returns (uint delta0, uint delta1) {
        if (delta.amount0() > 0) {
            delta0 = uint(int(delta.amount0()));
            VANILLA.currency0.take(poolManager,
                address(this), delta0, false);
            mockUSD.burn(delta0); 
            if (inRange) POOLED_USD -= delta0;
            if (!keep && who != address(0)) {
                delta0 *=  1e12;
                require(stdMath.delta(delta0, QUID.take(
                             who, delta0, address(QUID))) <= 5);
            } // keep is for preventing disbursal of $ 
            // when single-sided LPs withdraw their ETH 
        }
        else if (delta.amount0() < 0) {
            delta0 = uint(int(-delta.amount0())); mockUSD.mint(delta0);
            VANILLA.currency0.settle(poolManager, address(this), delta0, false);
            if (inRange) POOLED_USD += delta0;
        }
        if (delta.amount1() > 0) { delta1 = uint(int(delta.amount1()));
            VANILLA.currency1.take(poolManager, address(this), delta1, false);
            mockETH.burn(delta1); if (inRange) POOLED_ETH -= delta1;
            if (who != address(0)) AUX.sendETH(delta1, who);
        }
        else if (delta.amount1() < 0) {
            delta1 = uint(int(-delta.amount1())); mockETH.mint(delta1);
            VANILLA.currency1.settle(poolManager, address(this), delta1, false);
            if (inRange) POOLED_ETH += delta1;
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
    
    function _modLP(uint deltaZero, uint deltaOne, int24 tickLower,
        int24 tickUpper, uint160 sqrtPriceX96) internal returns
        (BalanceDelta) {  int flip = deltaOne > 0 ? int(1) : int(-1);
        (BalanceDelta totalDelta, // ^ this gets recalculated anyway
         BalanceDelta feesAccrued) = _modifyLiquidity(flip * int(uint(
               _calculateLiquidity(tickLower, sqrtPriceX96, deltaOne))),
                                   tickLower, tickUpper); // ^ ETH...
        return totalDelta; // if we called _modify with (-) liquidity
        // then funds left the pool, so totalDelta should be positive.
    }

    function _calculateLiquidity(int24 tickLower, uint160 sqrtPriceX96, 
        uint delta) internal pure returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, delta);
    }

    function _alignTick(int24 tick)
        internal pure returns (int24) {
        if (tick < 0 && tick % 10 != 0) {
            return ((tick - 10 + 1) / 10) * 10;
        }   return (tick / 10) * 10;
    }

    function updateTicks(uint160 sqrtPriceX96, uint delta) public pure returns
        (int24 tickLower, uint160 lower, int24 tickUpper, uint160 upper) {
        lower = _paddedSqrtPrice(sqrtPriceX96, false, delta);
        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minSqrtPrice");
        tickLower = _alignTick(TickMath.getTickAtSqrtPrice(lower));
        upper = _paddedSqrtPrice(sqrtPriceX96, true, delta);
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxSqrtPrice");
        tickUpper = _alignTick(TickMath.getTickAtSqrtPrice(upper));
    }

    function _paddedSqrtPrice(uint160 sqrtPriceX96, 
        bool up, uint delta) internal pure returns (uint160) { 
        uint x = up ? FixedPointMathLib.sqrt(1e18 + delta * 1e14):
                      FixedPointMathLib.sqrt(1e18 - delta * 1e14);
        return uint160(FixedPointMathLib.mulDivDown(x, uint(sqrtPriceX96),
                       FixedPointMathLib.sqrt(1e18)));
    }

    function repack() public onlyAux returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) { 
        int24 currentTick; PoolId id = VANILLA.toId();
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(id);
            tickUpper = UPPER_TICK;     tickLower = LOWER_TICK;
        if (currentTick > tickUpper || currentTick < tickLower) {
            myLiquidity = poolManager.getLiquidity(id);
            if (myLiquidity > 0) { // remove, then add liquidity
                poolManager.unlock(abi.encode(Action.Repack,
                                  myLiquidity, sqrtPriceX96, 
                                    tickLower, tickUpper));
            } else {
                (tickLower,, 
                tickUpper,) = updateTicks(sqrtPriceX96, 200);
                // 1% delta up, 1% down from ^^^^^^^^^^ total 2
                UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            }            
        }
    }
}
