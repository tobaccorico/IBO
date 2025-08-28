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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseLib} from "./BaseLib.sol";
import {Basket} from "./Basket.sol";

import {Settlement} from "./Settlement.sol";
import {Safta} from "./Safta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Position data for tracking liquidity
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

/**
 * @title Base - Belgian Auction Hook for Safta Markets
 * @notice Implements confidence-weighted Belgian auctions with decreasing prices
 * @dev Singleton hook managing all prediction market pools with slug-based liquidity
 */
contract Base is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // ============ Constants ============
    uint256 constant WAD = 1e18;
    int256 constant I_WAD = 1e18;
    uint256 constant NUM_DEFAULT_SLUGS = 3;
    uint256 constant MAX_PRICE_DISCOVERY_SLUGS = 10;
    
    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));
    
    // ============ State Variables ============
    mapping(PoolId => BaseLib.BelgianState) public state;
    mapping(PoolId => mapping(bytes32 => Position)) public positions;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => address) public poolMarkets;
    mapping(PoolId => bool) public earlyExit;
    mapping(PoolId => bool) public insufficientProceeds;
    
    // Belgian auction parameters stored separately for gas optimization
    mapping(PoolId => BaseLib.AuctionParams) public auctionParams;
    
    // Track top of curve for bounds checking
    mapping(PoolId => int24) public topOfCurveTick;
    
    // Batch processing for confidence-weighted orders
    mapping(PoolId => mapping(uint256 => Order[])) public epochOrders;
    
    struct Order {
        address trader;
        uint256 basketAmount;
        uint256 confidence;
        bool isYes;
        uint256 timestamp;
    }
    
    Basket public immutable basket;
    Settlement public immutable settlement;
    address public factory;
    
    // ============ Events ============
    event Rebalance(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint256 epoch);
    event BatchProcessed(PoolId indexed poolId, uint256 epoch, uint256 ordersProcessed);
    event EarlyExit(PoolId indexed poolId, uint256 epoch);
    event InsufficientProceeds(PoolId indexed poolId);
    event Swap(PoolId indexed poolId, int24 currentTick, uint256 totalProceeds, uint256 totalTokensSold);
    
    // ============ Errors ============
    error MaximumProceedsReached();
    error InvalidSwapAfterMaturity();
    error SwapBelowRange();
    
    
    constructor(
        IPoolManager _poolManager,
        address _basket,
        address _settlement
    ) BaseHook(_poolManager) {
        basket = Basket(_basket);
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
    
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        poolKeys[poolId] = key;
        
        // Initialize Belgian auction with decreasing prices
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        
        BaseLib.AuctionParams memory params;
        params.startingTime = block.timestamp;
        params.endingTime = block.timestamp + 30 days;
        params.epochLength = 1 hours;
        params.startingTick = tick + 10000;  // Start high tick (low YES price)
        params.endingTick = tick - 10000;    // End low tick (high YES price)
        params.gamma = 1000;  // Max tick adjustment per epoch
        params.numPDSlugs = 5;
        params.isToken0 = Currency.unwrap(key.currency0) == poolMarkets[poolId];
        
        // Calculate upper slug range
        uint256 timeDelta = params.endingTime - params.startingTime;
        uint256 normalizedEpochDelta = FullMath.mulDiv(params.epochLength, WAD, timeDelta);
        params.upperSlugRange = BaseLib.toInt24(
            int256(FullMath.mulDiv(normalizedEpochDelta,
            uint256(int256(params.gamma)), WAD)));
        
        auctionParams[poolId] = params;
        
        // Initialize state
        state[poolId].lastEpoch = 1;
        state[poolId].minimumProceeds = 1000 * WAD;
        state[poolId].maximumProceeds = 1000000 * WAD;
        
        return BaseHook.beforeInitialize.selector;
    }
    
    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Initialize liquidity slugs
        poolManager.unlock(abi.encode(CallbackData({
            key: key,
            poolId: poolId,
            sender: sender,
            tick: tick,
            action: Action.INITIALIZE
        })));
        
        return BaseHook.afterInitialize.selector;
    }
    
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Check early exit
        if (earlyExit[poolId]) revert MaximumProceedsReached();
        
        // Check if we should rebalance for new epoch
        uint256 currentEpoch = _getCurrentEpoch(poolId);
        if (currentEpoch > state[poolId].lastEpoch) {
            _rebalance(poolId, key);
        }
        
        // Record trade for batch processing with confidence
        _recordTrade(poolId, params, sender);
        
        // Calculate dynamic fee based on confidence
        uint24 fee = _calculateConfidenceFee(poolId, sender);
        
        // For 404 tokens, no fees
        address market = poolMarkets[poolId];
        if (Currency.unwrap(key.currency0) == market || Currency.unwrap(key.currency1) == market) {
            fee = 0 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }
    
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        BaseLib.BelgianState storage s = state[poolId];
        
        // Update proceeds and tokens sold
        bool basketIs0 = Currency.unwrap(key.currency0) == address(basket);
        
        if (basketIs0) {
            if (delta.amount0() < 0) {
                s.totalProceeds += uint256(-int256(delta.amount0()));
            }
            s.total404Out += uint256(int256(delta.amount1()));
        } else {
            if (delta.amount1() < 0) {
                s.totalProceeds += uint256(-int256(delta.amount1()));
            }
            s.total404Out += uint256(int256(delta.amount0()));
        }
        
        // Check bounds and reset if needed
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        
        // Keep price within curve bounds
        Position memory lowerPos = positions[poolId][LOWER_SLUG_SALT];
        BaseLib.AuctionParams memory auctionParams_ = auctionParams[poolId];
        
        if (auctionParams_.isToken0 ? currentTick < lowerPos.tickLower : currentTick > lowerPos.tickLower) {
            _resetPrice(key, lowerPos.tickLower, !auctionParams_.isToken0);
        } else if (auctionParams_.isToken0 ? currentTick > topOfCurveTick[poolId] : currentTick < topOfCurveTick[poolId]) {
            _resetPrice(key, topOfCurveTick[poolId], auctionParams_.isToken0);
        }
        
        // Check early exit condition
        if (s.totalProceeds >= s.maximumProceeds && !earlyExit[poolId]) {
            earlyExit[poolId] = true;
            emit EarlyExit(poolId, _getCurrentEpoch(poolId));
        }
        
        emit Swap(poolId, currentTick, s.totalProceeds, s.total404Out);
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Only allow authorized liquidity providers
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP"
        );
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Only allow authorized removal
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP removal"
        );
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }
    
    // ============ Belgian Auction Logic ============
    
    function _rebalance(PoolId poolId, PoolKey memory key) internal {
        uint256 currentEpoch = _getCurrentEpoch(poolId);
        BaseLib.BelgianState storage s = state[poolId];
        BaseLib.AuctionParams memory auctionParams_ = auctionParams[poolId];
        
        // Process pending orders from previous epoch
        _processEpochOrders(poolId, s.lastEpoch);
        
        // Calculate confidence-weighted adjustments
        int256 confidenceAdjustment = _calculateConfidenceAdjustment(poolId);
        s.tickAccumulator += confidenceAdjustment;
        
        // Clear existing positions
        Position[] memory prevPositions = _getExistingPositions(poolId);
        (BalanceDelta cleared, BalanceDelta fees) = _clearPositions(prevPositions, key);
        
        // Update fees
        s.feesAccrued0 += fees.amount0();
        s.feesAccrued1 += fees.amount1();
        
        // Calculate new tick positions based on accumulator
        (int24 tickLower, int24 tickUpper) = BaseLib.getTicksBasedOnState(
            s.tickAccumulator,
            key.tickSpacing,
            auctionParams_.startingTick,
            auctionParams_.gamma,
            auctionParams_.isToken0
        );
        
        // Get current pool state
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        currentTick = BaseLib.alignTickWithSpacing(currentTick, key.tickSpacing, false);
        
        // Calculate available liquidity
        uint256 numeraireAvailable = _getNumeraireAvailable(poolId, cleared, auctionParams_.isToken0);
        uint256 assetAvailable = _getAssetAvailable(poolId, cleared, auctionParams_.isToken0);
        
        // Compute new slug positions using library
        BaseLib.SlugData memory lowerSlug = BaseLib.computeLowerSlug(
            key,
            s.total404Out,
            numeraireAvailable,
            tickLower,
            currentTick,
            auctionParams_.isToken0
        );
        
        (BaseLib.SlugData memory upperSlug, uint256 assetRemaining) = BaseLib.computeUpperSlug(
            key,
            auctionParams_,
            s.total404Out,
            s.total404Out,
            currentTick,
            assetAvailable
        );
        
        BaseLib.SlugData[] memory pdSlugs = BaseLib.computePriceDiscoverySlugs(
            key,
            auctionParams_,
            upperSlug,
            tickUpper,
            assetRemaining
        );
        
        // Convert SlugData to Position and update
        Position[] memory newPositions = _convertToPositions(lowerSlug, upperSlug, pdSlugs);
        _updatePositions(poolId, newPositions, key, sqrtPriceX96, currentTick);
        
        // Store positions
        _storePositions(poolId, newPositions);
        
        // Update top of curve
        if (pdSlugs.length > 0) {
            topOfCurveTick[poolId] = pdSlugs[pdSlugs.length - 1].tickUpper;
        } else {
            topOfCurveTick[poolId] = upperSlug.tickUpper;
        }
        
        // Update state
        s.lastEpoch = uint40(currentEpoch);
        
        emit Rebalance(poolId, tickLower, tickUpper, currentEpoch);
    }
    
    function _processEpochOrders(PoolId poolId, uint256 epoch) internal {
        Order[] memory orders = epochOrders[poolId][epoch];
        if (orders.length == 0) return;
        
        uint256 totalWeightedYes;
        uint256 totalWeightedNo;
        
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 weighted = (orders[i].basketAmount * orders[i].confidence) / 10000;
            if (orders[i].isYes) {
                totalWeightedYes += weighted;
            } else {
                totalWeightedNo += weighted;
            }
        }
        
        state[poolId].totalBasketIn += totalWeightedYes + totalWeightedNo;
        
        emit BatchProcessed(poolId, epoch, orders.length);
        delete epochOrders[poolId][epoch];
    }
    
    // ============ Helper Functions ============
    
    function _getCurrentEpoch(PoolId poolId) public view returns (uint256) {
        BaseLib.AuctionParams memory params = auctionParams[poolId];
        return BaseLib.getCurrentEpoch(params.startingTime, params.epochLength);
    }
    
    function _calculateConfidenceAdjustment(PoolId poolId) internal view returns (int256) {
        uint256 epoch = state[poolId].lastEpoch;
        Order[] memory orders = epochOrders[poolId][epoch];
        
        if (orders.length == 0) return 0;
        
        uint256 totalConfidence;
        uint256 totalAmount;
        
        for (uint256 i = 0; i < orders.length; i++) {
            totalConfidence += orders[i].confidence * orders[i].basketAmount;
            totalAmount += orders[i].basketAmount;
        }
        
        if (totalAmount == 0) return 0;
        
        uint256 avgConfidence = totalConfidence / totalAmount;
        return BaseLib.calculateConfidenceAdjustment(avgConfidence, auctionParams[poolId].gamma);
    }
    
    function _calculateConfidenceFee(PoolId poolId, address trader) internal view returns (uint24) {
        address market = poolMarkets[poolId];
        if (market == address(0)) return 3000;
        
        try Safta(market).getConfidence(trader) returns (uint256 confidence) {
            return BaseLib.calculateConfidenceFee(confidence);
        } catch {
            return 3000;
        }
    }
    
    function _recordTrade(
        PoolId poolId,
        IPoolManager.SwapParams calldata params,
        address trader
    ) internal {
        uint256 epoch = _getCurrentEpoch(poolId);
        uint256 confidence = 7500; // Default 75%
        
        Order memory order = Order({
            trader: trader,
            basketAmount: uint256(params.amountSpecified > 0 ? 
                int256(params.amountSpecified) : 
                -int256(params.amountSpecified)),
            confidence: confidence,
            isYes: params.zeroForOne,
            timestamp: block.timestamp
        });
        
        epochOrders[poolId][epoch].push(order);
    }
    
    function _resetPrice(PoolKey memory key, int24 targetTick, bool zeroForOne) internal {
        uint160 sqrtPriceLimit = TickMath.getSqrtPriceAtTick(
            zeroForOne ? targetTick - 1 : targetTick + 1
        );
        
        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 1,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            ""
        );
    }
    
    function _getExistingPositions(PoolId poolId) internal view returns (Position[] memory) {
        BaseLib.AuctionParams memory params = auctionParams[poolId];
        Position[] memory prevPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + params.numPDSlugs);
        prevPositions[0] = positions[poolId][LOWER_SLUG_SALT];
        prevPositions[1] = positions[poolId][UPPER_SLUG_SALT];
        
        for (uint256 i = 0; i < params.numPDSlugs; i++) {
            prevPositions[NUM_DEFAULT_SLUGS - 1 + i] = positions[poolId][bytes32(uint256(DISCOVERY_SLUG_SALT) + i)];
        }
        
        return prevPositions;
    }
    
    function _clearPositions(
        Position[] memory positionsArray,
        PoolKey memory key
    ) internal returns (BalanceDelta total, BalanceDelta fees) {
        for (uint256 i = 0; i < positionsArray.length; i++) {
            if (positionsArray[i].liquidity > 0) {
                (BalanceDelta delta, BalanceDelta posFees) = poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: positionsArray[i].tickLower,
                        tickUpper: positionsArray[i].tickUpper,
                        liquidityDelta: -int256(uint256(positionsArray[i].liquidity)),
                        salt: bytes32(uint256(positionsArray[i].salt))
                    }),
                    ""
                );
                
                total = toBalanceDelta(
                    total.amount0() + delta.amount0(),
                    total.amount1() + delta.amount1()
                );
                
                fees = toBalanceDelta(
                    fees.amount0() + posFees.amount0(),
                    fees.amount1() + posFees.amount1()
                );
            }
        }
    }
    
    function toBalanceDelta(int128 amount0, int128 amount1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap(int256(uint256(uint128(amount0)) << 128 | uint128(amount1)));
    }
    function _getNumeraireAvailable(PoolId poolId, BalanceDelta cleared, bool isToken0) internal view returns (uint256) {
        if (isToken0) {
            return uint256(uint128(cleared.amount1())) + basket.totalBalances(address(this));
        } else {
            return uint256(uint128(cleared.amount0())) + basket.totalBalances(address(this));
        }
    }
    
    function _getAssetAvailable(PoolId poolId, BalanceDelta cleared, bool isToken0) internal view returns (uint256) {
        address market = poolMarkets[poolId];
        if (isToken0) {
            return uint256(uint128(cleared.amount0())) + IERC20(market).balanceOf(address(this));
        } else {
            return uint256(uint128(cleared.amount1())) + IERC20(market).balanceOf(address(this));
        }
    }
    
    function _convertToPositions(
        BaseLib.SlugData memory lowerSlug,
        BaseLib.SlugData memory upperSlug,
        BaseLib.SlugData[] memory pdSlugs
    ) internal pure returns (Position[] memory) {
        Position[] memory newPositions = new Position[](NUM_DEFAULT_SLUGS - 1 + pdSlugs.length);
        
        newPositions[0] = Position({
            tickLower: lowerSlug.tickLower,
            tickUpper: lowerSlug.tickUpper,
            liquidity: lowerSlug.liquidity,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        
        newPositions[1] = Position({
            tickLower: upperSlug.tickLower,
            tickUpper: upperSlug.tickUpper,
            liquidity: upperSlug.liquidity,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });
        
        for (uint256 i = 0; i < pdSlugs.length; i++) {
            newPositions[NUM_DEFAULT_SLUGS - 1 + i] = Position({
                tickLower: pdSlugs[i].tickLower,
                tickUpper: pdSlugs[i].tickUpper,
                liquidity: pdSlugs[i].liquidity,
                salt: uint8(uint256(DISCOVERY_SLUG_SALT) + i)
            });
        }
        
        return newPositions;
    }
    
    function _updatePositions(
        PoolId poolId,
        Position[] memory newPositions,
        PoolKey memory key,
        uint160 currentPrice,
        int24 targetTick
    ) internal {
        uint160 targetPrice = TickMath.getSqrtPriceAtTick(targetTick);
        if (targetPrice != currentPrice) {
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: targetPrice < currentPrice,
                    amountSpecified: 1,
                    sqrtPriceLimitX96: targetPrice
                }),
                ""
            );
        }
        
        for (uint256 i = 0; i < newPositions.length; i++) {
            if (newPositions[i].liquidity > 0) {
                poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: newPositions[i].tickLower,
                        tickUpper: newPositions[i].tickUpper,
                        liquidityDelta: int256(uint256(newPositions[i].liquidity)),
                        salt: bytes32(uint256(newPositions[i].salt))
                    }),
                    ""
                );
            }
        }
        
        _settleCurrencyDeltas(key);
    }
    
    function _settleCurrencyDeltas(PoolKey memory key) internal {
        int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
        int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);
        
        if (currency0Delta > 0) {
            poolManager.take(key.currency0, address(this), uint256(currency0Delta));
        }
        
        if (currency1Delta > 0) {
            poolManager.take(key.currency1, address(this), uint256(currency1Delta));
        }
        
        if (currency0Delta < 0) {
            poolManager.sync(key.currency0);
            if (Currency.unwrap(key.currency0) != address(0)) {
                key.currency0.transfer(address(poolManager), uint256(-currency0Delta));
            }
            poolManager.settle{value: Currency.unwrap(key.currency0) == address(0) ? uint256(-currency0Delta) : 0}();
        }
        
        if (currency1Delta < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(-currency1Delta));
            poolManager.settle();
        }
    }
    
    function _storePositions(PoolId poolId, Position[] memory newPositions) internal {
        positions[poolId][LOWER_SLUG_SALT] = newPositions[0];
        positions[poolId][UPPER_SLUG_SALT] = newPositions[1];
        
        for (uint256 i = 2; i < newPositions.length; i++) {
            positions[poolId][bytes32(uint256(DISCOVERY_SLUG_SALT) + i - 2)] = newPositions[i];
        }
    }
    
    function _setupRefundLiquidity(PoolId poolId) internal {
        PoolKey memory key = poolKeys[poolId];
        BaseLib.BelgianState memory s = state[poolId];
        
        if (s.total404Out == 0 || s.totalProceeds == 0) return;
        
        uint256 avgPrice = (s.totalProceeds * WAD) / s.total404Out;
        uint160 sqrtPriceX96 = uint160(Math.sqrt(avgPrice) << 48);
        int24 targetTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        targetTick = BaseLib.alignTickWithSpacing(targetTick, key.tickSpacing, false);
        
        Position[] memory prevPositions = _getExistingPositions(poolId);
        _clearPositions(prevPositions, key);
        
        Position memory refundPosition = Position({
            tickLower: auctionParams[poolId].isToken0 ? targetTick - key.tickSpacing : targetTick + key.tickSpacing,
            tickUpper: targetTick,
            liquidity: LiquidityAmounts.getLiquidityForAmounts(
                TickMath.getSqrtPriceAtTick(targetTick - key.tickSpacing),
                TickMath.getSqrtPriceAtTick(targetTick),
                TickMath.getSqrtPriceAtTick(targetTick), // current price
                s.totalProceeds,
                s.total404Out
            ),
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        
        positions[poolId][LOWER_SLUG_SALT] = refundPosition;
    }
    
    // ============ Callback Data ============
    
    enum Action { INITIALIZE, REBALANCE, MIGRATE }
    
    struct CallbackData {
        PoolKey key;
        PoolId poolId;
        address sender;
        int24 tick;
        Action action;
    }
    
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        
        CallbackData memory cb = abi.decode(data, (CallbackData));
        
        if (cb.action == Action.INITIALIZE) {
            return _handleInitialize(cb);
        } else if (cb.action == Action.REBALANCE) {
            return _handleRebalance(cb);
        } else {
            return _handleMigrate(cb);
        }
    }
    
    function _handleInitialize(CallbackData memory cb) internal returns (bytes memory) {
        state[cb.poolId].lastEpoch = 1;
        BaseLib.AuctionParams memory params = auctionParams[cb.poolId];
        
        (int24 tickLower, int24 tickUpper) = BaseLib.getTicksBasedOnState(
            0, cb.key.tickSpacing, params.startingTick, params.gamma, params.isToken0
        );
        
        BaseLib.SlugData memory lowerSlug = BaseLib.SlugData({
            tickLower: cb.tick,
            tickUpper: cb.tick,
            liquidity: 0
        });
        
        uint256 initialTokens = state[cb.poolId].total404Out > 0 ? 
            state[cb.poolId].total404Out : 10000e18;
            
        (BaseLib.SlugData memory upperSlug, uint256 remaining) = BaseLib.computeUpperSlug(
            cb.key, params, 0, initialTokens, cb.tick, initialTokens
        );
        
        BaseLib.SlugData[] memory pdSlugs = BaseLib.computePriceDiscoverySlugs(
            cb.key, params, upperSlug, tickUpper, remaining
        );
        
        Position[] memory newPositions = _convertToPositions(lowerSlug, upperSlug, pdSlugs);
        _updatePositions(cb.poolId, newPositions, cb.key, TickMath.getSqrtPriceAtTick(cb.tick), cb.tick);
        _storePositions(cb.poolId, newPositions);
        
        return new bytes(0);
    }
    
    function _handleRebalance(CallbackData memory cb) internal returns (bytes memory) {
        return new bytes(0);
    }
    
    function _handleMigrate(CallbackData memory cb) internal returns (bytes memory) {
        Position[] memory allPositions = _getExistingPositions(cb.poolId);
        (BalanceDelta total, BalanceDelta fees) = _clearPositions(allPositions, cb.key);
        _transferToSender(cb.key, cb.sender, total);
        return abi.encode(total, fees);
    }
    
    function _transferToSender(PoolKey memory key, address recipient, BalanceDelta delta) internal {
        int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
        int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);
        
        if (currency0Delta > 0) {
            poolManager.take(key.currency0, recipient, uint256(currency0Delta));
        }
        
        if (currency1Delta > 0) {
            poolManager.take(key.currency1, recipient, uint256(currency1Delta));
        }
    }
    
    // ============ External Functions ============
    
    function setFactory(address _factory) external {
        require(factory == address(0), "Already set");
        factory = _factory;
    }
    
    function registerMarket(PoolId poolId, address market) external {
        require(msg.sender == factory, "Only factory");
        poolMarkets[poolId] = market;
    }
    
    function initializeAuction(
        PoolId poolId,
        uint256 _startTime,
        uint256 _epochLength,
        int24 _startingTick,
        int24 _endingTick,
        uint256 totalEpochs,
        uint256 numTokensToSell,
        uint256 _minimumProceeds,
        uint256 _maximumProceeds
    ) external {
        require(msg.sender == factory, "Only factory");
        
        BaseLib.AuctionParams storage params = auctionParams[poolId];
        params.startingTime = _startTime;
        params.endingTime = _startTime + (_epochLength * totalEpochs);
        params.epochLength = _epochLength;
        params.startingTick = _startingTick;
        params.endingTick = _endingTick;
        
        state[poolId].minimumProceeds = _minimumProceeds;
        state[poolId].maximumProceeds = _maximumProceeds;
        state[poolId].total404Out = numTokensToSell;
    }
    
    function processBatch(PoolId poolId, uint256 epoch, uint256) external returns (uint256) {
        _processEpochOrders(poolId, epoch);
        return state[poolId].total404Out > 0 ? 
            state[poolId].totalBasketIn * WAD / state[poolId].total404Out : WAD;
    }
    
    function updatePrice(PoolId poolId, uint256) external {
        uint256 currentEpoch = _getCurrentEpoch(poolId);
        if (currentEpoch > state[poolId].lastEpoch) {
            _rebalance(poolId, poolKeys[poolId]);
        }
    }
    
    function executeTrade(
        PoolId poolId,
        address trader,
        uint256 yesShares,
        uint256 noShares,
        uint256 confidence
    ) external returns (uint256) {
        require(msg.sender == poolMarkets[poolId], "Only market");
        
        Order memory order = Order({
            trader: trader,
            basketAmount: yesShares + noShares,
            confidence: confidence,
            isYes: yesShares > noShares,
            timestamp: block.timestamp
        });
        
        uint256 epoch = _getCurrentEpoch(poolId);
        epochOrders[poolId][epoch].push(order);
        
        return (order.basketAmount * confidence) / 10000;
    }
    
    function stakeLiquidity(
        PoolId poolId,
        address provider,
        uint256 token404Amount,
        uint256 basketAmount
    ) external {
        require(msg.sender == poolMarkets[poolId], "Only market");
        state[poolId].totalBasketIn += basketAmount;
    }
    
    function unstakeLiquidity(
        PoolId poolId,
        address provider,
        uint256 token404Amount,
        uint256 basketAmount
    ) external {
        require(msg.sender == poolMarkets[poolId], "Only market");
        if (state[poolId].totalBasketIn >= basketAmount) {
            state[poolId].totalBasketIn -= basketAmount;
        }
    }
    
    function resolveMarket(PoolId poolId, bool outcome) external {
        require(msg.sender == poolMarkets[poolId] || msg.sender == address(settlement), "Unauthorized");
        
        if (state[poolId].totalProceeds < state[poolId].minimumProceeds) {
            insufficientProceeds[poolId] = true;
            emit InsufficientProceeds(poolId);
            _setupRefundLiquidity(poolId);
        }
    }
    
    // View functions for compatibility
    function getCurrentTick(PoolId poolId) external view returns (int24) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
    
    function getAuctionInfo(PoolId poolId) external view returns (
        uint256, uint256, uint256, int24, int24, uint256, uint256
    ) {
        BaseLib.AuctionParams memory params = auctionParams[poolId];
        return (
            params.startingTime,
            params.endingTime,
            params.epochLength,
            params.startingTick,
            params.endingTick,
            params.numPDSlugs,
            uint256(uint24(params.gamma))
        );
    }
    
    function getBasketBalance(PoolId poolId) external view returns (uint256) {
        return state[poolId].totalBasketIn;
    }
    
    function collectFees(PoolId poolId) external returns (uint256, uint256) {
        BaseLib.BelgianState storage s = state[poolId];
        uint256 fee0 = s.feesAccrued0 > 0 ? uint256(int256(s.feesAccrued0)) : 0;
        uint256 fee1 = s.feesAccrued1 > 0 ? uint256(int256(s.feesAccrued1)) : 0;
        s.feesAccrued0 = 0;
        s.feesAccrued1 = 0;
        return (fee0, fee1);
    }
    
    function isResolved(PoolId poolId) external view returns (bool) {
        return insufficientProceeds[poolId] || earlyExit[poolId];
    }
    
    function getOutcome(PoolId poolId) external view returns (bool) {
        return !insufficientProceeds[poolId];
    }
    
    function getPoolKey(PoolId poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    function owner() external view returns (address) {
        return settlement.admin();
    }
    
    function admin() external view returns (address) {
        return settlement.admin();
    }
}