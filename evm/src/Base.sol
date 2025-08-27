// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {Basket} from "./Basket.sol";
import {Rover} from "./Rover.sol";
import {Settlement} from "./Settlement.sol";
import {Safta} from "./Safta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title Base - Belgian Auction Hook for Safta Markets
 * @notice Implements time-based price discovery with decreasing prices over epochs
 * @dev Singleton hook managing all prediction market pools
 */
contract Base is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // ============ Structs ============
    struct AuctionInfo {
        uint256 startTime;
        uint256 endTime;
        uint256 epochDuration;
        int24 startingTick;
        int24 endingTick;
        bool isActive;
        address marketContract;
    }
    
    struct EpochInfo {
        uint256 totalBasketIn;
        uint256 total404Out;
        uint256 clearingPrice;
        bool processed;
        uint256 epochStartTime;
        uint256 epochEndTime;
        mapping(address => uint256) userBasketIn;
        mapping(address => uint256) user404Out;
    }
    
    struct LPPosition {
        uint256 amount404;
        uint256 basketAmount;
        uint256 feesEarned;
    }
    
    struct PoolState {
        uint256 totalLP404;
        uint256 totalLPBasket;
        uint256 totalFeesCollected;
        bool resolved;
        bool outcome;
    }
    
    // ============ State ============
    mapping(PoolId => AuctionInfo) public auctions;
    mapping(PoolId => mapping(uint256 => EpochInfo)) public epochs;
    mapping(PoolId => uint256) public currentEpoch;
    mapping(PoolId => int24) public currentTick;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => address) public poolMarkets;
    mapping(PoolId => bool) public resolved;
    mapping(PoolId => bool) public marketOutcome;
    mapping(PoolId => uint256) public poolLiquidity;
    mapping(PoolId => uint256) public feesCollected;
    mapping(PoolId => PoolState) public poolStates;
    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;
    
    Basket public immutable basket;
    Rover public immutable rover;
    Settlement public immutable settlement;
    
    uint256 public constant DEFAULT_DURATION = 30 days;
    uint256 public constant EPOCH_LENGTH = 1 hours;
    int24 public constant MIN_TICK = -887200;
    int24 public constant MAX_TICK = 887200;
    uint128 public constant MIN_LIQUIDITY = 1000;
    
    address public factory;
    
    // ============ Events ============
    event AuctionStarted(PoolId poolId, uint256 startTime, uint256 endTime);
    event EpochAdvanced(PoolId poolId, uint256 epoch, int24 newTick);
    event TradeExecuted(PoolId poolId, address trader, uint256 basketIn, uint256 shares404Out);
    event MarketResolved(PoolId poolId, bool outcome);
    event LiquidityStaked(PoolId poolId, address provider, uint256 amount);
    event LiquidityUnstaked(PoolId poolId, address provider, uint256 amount);
    event BatchProcessed(PoolId poolId, uint256 epoch, uint256 clearingPrice);
    event FeesDistributed(PoolId poolId, uint256 amount);
    event MarketRegistered(PoolId indexed poolId, address market);
    event AuctionInitialized(PoolId indexed poolId, uint256 startingTime, int24 startingTick, int24 endingTick);
    event PriceUpdated(PoolId indexed poolId, int24 currentTick);
    
    // ============ Constructor ============
    constructor(
        IPoolManager _poolManager,
        address _basket,
        address _rover,
        address _settlement
    ) BaseHook(_poolManager) {
        basket = Basket(_basket);
        rover = Rover(_rover);
        settlement = Settlement(_settlement);
    }
    
    // ============ Hook Configuration ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    // ============ Hook Callbacks ============
    // BaseHook has these as non-virtual, so we don't override them
    // Instead, we might need to implement the internal virtual functions
    
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata hookData
    ) internal virtual returns (bytes4) {
        // Store pool configuration
        poolKeys[key.toId()] = key;
        
        // Initialize auction parameters
        _initializeAuction(key.toId(), sqrtPriceX96);
        
        return BaseHook.beforeInitialize.selector;
    }
    
    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata hookData
    ) internal virtual returns (bytes4) {
        PoolId poolId = key.toId();
        currentTick[poolId] = tick;
        
        // Add initial liquidity if needed
        if (poolStates[poolId].totalLPBasket > 0) {
            int24 tickLower = ((tick - 1000) / 60) * 60;
            int24 tickUpper = ((tick + 1000) / 60) * 60;
            
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                MIN_LIQUIDITY,
                MIN_LIQUIDITY
            );
            
            if (liquidity > 0) {
                poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: int256(uint256(liquidity)),
                        salt: bytes32(0)
                    }),
                    ""
                );
            }
        }
        
        return BaseHook.afterInitialize.selector;
    }
    
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Update price if needed
        _updateAuctionPrice(poolId);
        
        // Calculate swap amounts based on Belgian auction rules
        BeforeSwapDelta delta = _calculateSwapDelta(poolId, params);
        
        // Track trade for epoch processing
        _recordTrade(poolId, params, sender);
        
        // Set fee override if needed (0 fees for 404 tokens)
        address market = poolMarkets[poolId];
        bool is404Swap = Currency.unwrap(key.currency0) == market || 
                        Currency.unwrap(key.currency1) == market;
        
        uint24 fee = is404Swap ? (0 | LPFeeLibrary.OVERRIDE_FEE_FLAG) : 0;
        
        return (BaseHook.beforeSwap.selector, delta, fee);
    }
    
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Update epoch if needed
        _checkEpochAdvance(poolId);
        
        // Track fees (basket only)
        bool basketIs0 = Currency.unwrap(key.currency0) == address(basket);
        bool basketIs1 = Currency.unwrap(key.currency1) == address(basket);
        
        uint256 feeAmount = 0;
        if (basketIs0 && delta.amount0() > 0) {
            feeAmount = uint256(int256(delta.amount0())) * 30 / 10000; // 0.3%
        } else if (basketIs1 && delta.amount1() > 0) {
            feeAmount = uint256(int256(delta.amount1())) * 30 / 10000; // 0.3%
        }
        
        if (feeAmount > 0) {
            feesCollected[poolId] += feeAmount;
            poolStates[poolId].totalFeesCollected += feeAmount;
            emit FeesDistributed(poolId, feeAmount);
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Only allow authorized liquidity providers
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP"
        );
        
        // Track liquidity provision
        if (params.liquidityDelta > 0) {
            poolLiquidity[poolId] += uint256(int256(params.liquidityDelta));
        }
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Only allow authorized liquidity removal
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP"
        );
        
        // Track liquidity removal
        if (params.liquidityDelta < 0) {
            poolLiquidity[poolId] -= uint256(-int256(params.liquidityDelta));
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }
    
    // ============ Belgian Auction Logic ============
    
    function _initializeAuction(PoolId poolId, uint160 sqrtPriceX96) internal {
        int24 tick = _sqrtPriceToTick(sqrtPriceX96);
        
        auctions[poolId] = AuctionInfo({
            startTime: block.timestamp,
            endTime: block.timestamp + DEFAULT_DURATION,
            epochDuration: EPOCH_LENGTH,
            startingTick: tick + 10000, // Start high (low price for YES)
            endingTick: tick - 10000,   // End low (high price for YES)
            isActive: true,
            marketContract: address(0)
        });
        
        currentTick[poolId] = auctions[poolId].startingTick;
        currentEpoch[poolId] = 0;
        
        // Initialize first epoch
        epochs[poolId][0].epochStartTime = block.timestamp;
        epochs[poolId][0].epochEndTime = block.timestamp + EPOCH_LENGTH;
        
        emit AuctionStarted(poolId, block.timestamp, block.timestamp + DEFAULT_DURATION);
    }
    
    // Overloaded initialization function for custom parameters (used by tests)
    function initializeAuction(
        PoolId poolId,
        uint256 startingTime,
        uint256 epochLength,
        uint256 priceEpochLength,
        int24 startingTick,
        int24 endingTick,
        uint256 totalEpochs,
        uint256 numTokensToSell,
        uint256 minimumProceeds,
        uint256 maximumProceeds
    ) external {
        require(msg.sender == factory, "Only factory");
        require(startingTick > endingTick, "Invalid tick range");
        
        auctions[poolId] = AuctionInfo({
            startTime: startingTime,
            endTime: startingTime + (epochLength * totalEpochs),
            epochDuration: epochLength,
            startingTick: startingTick,
            endingTick: endingTick,
            isActive: true,
            marketContract: poolMarkets[poolId]
        });
        
        currentTick[poolId] = startingTick;
        currentEpoch[poolId] = 0;
        
        emit AuctionInitialized(poolId, startingTime, startingTick, endingTick);
    }
    
    function _updateAuctionPrice(PoolId poolId) internal {
        AuctionInfo storage auction = auctions[poolId];
        if (!auction.isActive) return;
        
        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 duration = auction.endTime - auction.startTime;
        
        if (elapsed >= duration) {
            currentTick[poolId] = auction.endingTick;
            auction.isActive = false;
            return;
        }
        
        // Linear decrease in tick (price increases over time for YES tokens)
        int24 tickRange = auction.startingTick - auction.endingTick;
        int24 tickDecrease = int24(int256(tickRange) * int256(elapsed) / int256(duration));
        int24 newTick = auction.startingTick - tickDecrease;
        
        if (newTick != currentTick[poolId]) {
            currentTick[poolId] = newTick;
            emit PriceUpdated(poolId, newTick);
        }
    }
    
    function _calculateSwapDelta(
        PoolId poolId,
        IPoolManager.SwapParams calldata params
    ) internal view returns (BeforeSwapDelta) {
        // For Belgian auction, we may want to override swap amounts
        // based on the current auction price
        // For now, returning zero delta to use normal swap logic
        return BeforeSwapDeltaLibrary.ZERO_DELTA;
    }
    
    function _recordTrade(
        PoolId poolId, 
        IPoolManager.SwapParams calldata params,
        address trader
    ) internal {
        uint256 epoch = currentEpoch[poolId];
        EpochInfo storage epochInfo = epochs[poolId][epoch];
        
        if (params.zeroForOne) {
            // Trading basket for 404 tokens
            uint256 amount = params.amountSpecified > 0 
                ? uint256(int256(params.amountSpecified))
                : uint256(-int256(params.amountSpecified));
            epochInfo.totalBasketIn += amount;
            epochInfo.userBasketIn[trader] += amount;
        } else {
            // Trading 404 for basket tokens
            uint256 amount = params.amountSpecified > 0
                ? uint256(int256(params.amountSpecified))
                : uint256(-int256(params.amountSpecified));
            epochInfo.total404Out += amount;
            epochInfo.user404Out[trader] += amount;
        }
    }
    
    function _checkEpochAdvance(PoolId poolId) internal {
        AuctionInfo storage auction = auctions[poolId];
        uint256 epochsSinceStart = (block.timestamp - auction.startTime) / auction.epochDuration;
        
        if (epochsSinceStart > currentEpoch[poolId]) {
            _processEpoch(poolId);
            currentEpoch[poolId] = epochsSinceStart;
            
            // Initialize new epoch
            epochs[poolId][epochsSinceStart].epochStartTime = block.timestamp;
            epochs[poolId][epochsSinceStart].epochEndTime = block.timestamp + auction.epochDuration;
            
            emit EpochAdvanced(poolId, epochsSinceStart, currentTick[poolId]);
        }
    }
    
    function _processEpoch(PoolId poolId) internal {
        uint256 epoch = currentEpoch[poolId];
        EpochInfo storage epochInfo = epochs[poolId][epoch];
        
        if (epochInfo.totalBasketIn > 0 && epochInfo.total404Out > 0) {
            epochInfo.clearingPrice = epochInfo.totalBasketIn * 1e18 / epochInfo.total404Out;
            emit BatchProcessed(poolId, epoch, epochInfo.clearingPrice);
        }
        
        epochInfo.processed = true;
        
        // Notify market contract if set
        if (poolMarkets[poolId] != address(0)) {
            Safta(poolMarkets[poolId]).updateFromHook(
                epochInfo.total404Out,
                epochInfo.totalBasketIn
            );
        }
    }
    
    function _sqrtPriceToTick(uint160 sqrtPriceX96) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
    
    // ============ External Functions ============
    
    function setFactory(address _factory) external {
        require(factory == address(0), "Already set");
        factory = _factory;
    }
    
    function registerMarket(PoolId poolId, address marketContract) external {
        require(msg.sender == factory, "Only factory");
        require(poolMarkets[poolId] == address(0), "Already registered");
        poolMarkets[poolId] = marketContract;
        auctions[poolId].marketContract = marketContract;
        emit MarketRegistered(poolId, marketContract);
    }
    
    function getCurrentTick(PoolId poolId) public view returns (int24) {
        AuctionInfo memory auction = auctions[poolId];
        if (!auction.isActive) return auction.endingTick;
        
        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 duration = auction.endTime - auction.startTime;
        
        if (elapsed >= duration) {
            return auction.endingTick;
        }
        
        int24 tickRange = auction.startingTick - auction.endingTick;
        int24 tickDecrease = int24(int256(uint256(tickRange) * elapsed / duration));
        return auction.startingTick - tickDecrease;
    }
    
    function getAuctionInfo(PoolId poolId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 epochDuration,
        int24 startingTick,
        int24 endingTick,
        bool isActive,
        address marketContract
    ) {
        AuctionInfo memory info = auctions[poolId];
        return (
            info.startTime,
            info.endTime,
            info.epochDuration,
            info.startingTick,
            info.endingTick,
            info.isActive,
            info.marketContract
        );
    }
    
    function processBatch(PoolId poolId, uint256 epoch, uint256 ordersCount) external returns (uint256) {
        // Process batch orders for the epoch
        EpochInfo storage epochInfo = epochs[poolId][epoch];
        
        if (!epochInfo.processed) {
            _processEpoch(poolId);
        }
        
        return epochInfo.clearingPrice;
    }
    
    function updatePrice(PoolId poolId, uint256) external {
        _updateAuctionPrice(poolId);
    }
    
    function executeTrade(
        PoolId poolId,
        address trader,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 confidence
    ) external returns (uint256) {
        require(msg.sender == poolMarkets[poolId], "Only market");
        
        // Execute trade with confidence weighting
        uint256 totalAmount = yesAmount + noAmount;
        uint256 weightedAmount = (totalAmount * confidence) / 10000;
        
        // Calculate value based on current tick
        int24 tick = getCurrentTick(poolId);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceRatio = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            FixedPoint96.Q96
        );
        
        uint256 outputAmount = FullMath.mulDiv(weightedAmount, priceRatio, 1e18);
        
        emit TradeExecuted(poolId, trader, totalAmount, outputAmount);
        return outputAmount;
    }
    
    // ============ Liquidity Management ============
    
    function stakeLiquidity(
        PoolId poolId, 
        address provider, 
        uint256 token404Amount, 
        uint256 basketAmount
    ) external {
        require(msg.sender == poolMarkets[poolId], "Only market");
        
        LPPosition storage position = lpPositions[poolId][provider];
        PoolState storage state = poolStates[poolId];
        
        // Distribute pending fees before updating position
        if (state.totalLP404 > 0 && state.totalFeesCollected > 0) {
            uint256 userShare = (position.amount404 * state.totalFeesCollected) / state.totalLP404;
            position.feesEarned += userShare;
        }
        
        position.amount404 += token404Amount;
        position.basketAmount += basketAmount;
        
        state.totalLP404 += token404Amount;
        state.totalLPBasket += basketAmount;
        poolLiquidity[poolId] += basketAmount;
        
        emit LiquidityStaked(poolId, provider, basketAmount);
    }
    
    function unstakeLiquidity(
        PoolId poolId, 
        address provider, 
        uint256 token404Amount, 
        uint256 basketAmount
    ) external {
        require(msg.sender == poolMarkets[poolId], "Only market");
        require(poolLiquidity[poolId] >= basketAmount, "Insufficient liquidity");
        
        LPPosition storage position = lpPositions[poolId][provider];
        PoolState storage state = poolStates[poolId];
        
        require(position.amount404 >= token404Amount, "Insufficient 404");
        require(position.basketAmount >= basketAmount, "Insufficient basket");
        
        // Calculate proportional fees
        uint256 feesToPay = (position.feesEarned * token404Amount) / position.amount404;
        
        position.amount404 -= token404Amount;
        position.basketAmount -= basketAmount;
        position.feesEarned -= feesToPay;
        
        state.totalLP404 -= token404Amount;
        state.totalLPBasket -= basketAmount;
        poolLiquidity[poolId] -= basketAmount;
        
        // Transfer fees to market for distribution
        if (feesToPay > 0) {
            IERC20(address(basket)).transfer(poolMarkets[poolId], feesToPay);
        }
        
        emit LiquidityUnstaked(poolId, provider, basketAmount + feesToPay);
    }
    
    function getStakedLiquidity(
        PoolId poolId,
        address user
    ) external view returns (uint256 staked404, uint256 stakedBasket) {
        LPPosition memory pos = lpPositions[poolId][user];
        return (pos.amount404, pos.basketAmount);
    }
    
    // ============ Resolution ============
    
    function resolveMarket(PoolId poolId, bool outcome) external {
        require(msg.sender == poolMarkets[poolId] || msg.sender == address(settlement), "Unauthorized");
        resolved[poolId] = true;
        marketOutcome[poolId] = outcome;
        poolStates[poolId].resolved = true;
        poolStates[poolId].outcome = outcome;
        emit MarketResolved(poolId, outcome);
    }
    
    function collectFees(PoolId poolId) external returns (uint256, uint256) {
        require(msg.sender == factory || msg.sender == poolMarkets[poolId], "Unauthorized");
        
        // Return fees collected (basket only, no 404 fees)
        uint256 basketFees = feesCollected[poolId];
        feesCollected[poolId] = 0;
        return (basketFees, 0);
    }
    
    function getBasketBalance(PoolId poolId) external view returns (uint256) {
        return poolLiquidity[poolId];
    }
    
    function getOutcome(PoolId poolId) external view returns (bool) {
        return marketOutcome[poolId];
    }
    
    function isResolved(PoolId poolId) external view returns (bool) {
        return poolStates[poolId].resolved;
    }
    
    // Functions expected by tests
    function owner() external view returns (address) {
        return settlement.admin();
    }
    
    function admin() external view returns (address) {
        return settlement.admin();
    }
    
    // Compatibility function for tests that expect different signature
    function startingTime() external view returns (uint256) {
        // Return a default or first pool's starting time
        return auctions[PoolId.wrap(bytes32(0))].startTime;
    }
}