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
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

import {Basket} from "./Basket.sol";
import {Rover} from "./Rover.sol";
import {Settlement} from "./Settlement.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Position data for a liquidity slug
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

/// @notice Current state of the Belgian auction pool
struct State {
    uint40 lastEpoch;
    int256 tickAccumulator;
    uint256 totalBasketIn;
    uint256 total404Out;
    uint256 totalProceeds;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    int128 feesAccrued0;  // Split BalanceDelta into components
    int128 feesAccrued1;
}

/**
 * @title Base - Belgian Auction Hook with Confidence Slugs
 */
contract Base is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // ============ Constants ============
    uint256 constant WAD = 1e18;
    int256 constant I_WAD = 1e18;
    uint256 constant NUM_DEFAULT_SLUGS = 3;
    
    bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
    bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
    bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));
    
    // ============ State Variables ============
    mapping(PoolId => State) public state;
    mapping(PoolId => mapping(bytes32 => Position)) public positions;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => address) public poolMarkets;
    mapping(PoolId => bool) public earlyExit;
    mapping(PoolId => bool) public insufficientProceeds;
    
    mapping(PoolId => uint256) public startingTime;
    mapping(PoolId => uint256) public endingTime;
    mapping(PoolId => int24) public startingTick;
    mapping(PoolId => int24) public endingTick;
    mapping(PoolId => uint256) public epochLength;
    mapping(PoolId => int24) public gamma;
    mapping(PoolId => uint256) public numPDSlugs;
    mapping(PoolId => bool) public isToken0;
    
    mapping(PoolId => mapping(uint256 => Order[])) public epochOrders;
    
    struct Order {
        address trader;
        uint256 basketAmount;
        uint256 confidence;
        bool isYes;
    }
    
    Basket public immutable basket;
    Rover public immutable rover;
    Settlement public immutable settlement;
    
    address public factory;
    
    // ============ Events ============
    event Rebalance(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint256 epoch);
    event BatchProcessed(PoolId indexed poolId, uint256 epoch, uint256 ordersProcessed);
    event EarlyExit(PoolId indexed poolId, uint256 epoch);
    event InsufficientProceeds(PoolId indexed poolId);
    
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
    
    // ============ Hook Callbacks - Fixed Signatures ============
    
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        poolKeys[poolId] = key;
        
        startingTime[poolId] = block.timestamp;
        endingTime[poolId] = block.timestamp + 30 days;
        epochLength[poolId] = 1 hours;
        
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        startingTick[poolId] = tick - 10000;
        endingTick[poolId] = tick + 10000;
        
        gamma[poolId] = 1000;
        numPDSlugs[poolId] = 5;
        
        isToken0[poolId] = Currency.unwrap(key.currency0) == poolMarkets[poolId];
        
        state[poolId].lastEpoch = 1;
        state[poolId].minimumProceeds = 1000 * WAD;
        state[poolId].maximumProceeds = 1000000 * WAD;
        
        return BaseHook.beforeInitialize.selector;
    }
    
    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        _initializeSlugs(poolId, key, sqrtPriceX96, tick);
        return BaseHook.afterInitialize.selector;
    }
    
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        uint256 currentEpoch = _getCurrentEpoch(poolId);
        if (currentEpoch > state[poolId].lastEpoch) {
            _rebalance(poolId, key);
        }
        
        _recordTrade(poolId, params, sender);
        
        uint24 fee = _calculateConfidenceFee(poolId, sender);
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }
    
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        State storage s = state[poolId];
        
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
        
        if (s.totalProceeds >= s.maximumProceeds && !earlyExit[poolId]) {
            earlyExit[poolId] = true;
            emit EarlyExit(poolId, _getCurrentEpoch(poolId));
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP"
        );
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        
        require(
            sender == poolMarkets[poolId] || 
            sender == address(this) ||
            sender == factory,
            "Unauthorized LP removal"
        );
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }
    
    // ============ Internal Functions ============
    
    function _initializeSlugs(
        PoolId poolId,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal {
        Position memory lowerSlug = Position({
            tickLower: tick - 1000,
            tickUpper: tick,
            liquidity: 0,
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        
        Position memory upperSlug = Position({
            tickLower: tick,
            tickUpper: tick + 1000,
            liquidity: 0,
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });
        
        positions[poolId][LOWER_SLUG_SALT] = lowerSlug;
        positions[poolId][UPPER_SLUG_SALT] = upperSlug;
        
        for (uint256 i = 0; i < numPDSlugs[poolId]; i++) {
            Position memory pdSlug = Position({
                tickLower: tick + int24(int256(1000 * (i + 1))),
                tickUpper: tick + int24(int256(1000 * (i + 2))),
                liquidity: 0,
                salt: uint8(uint256(DISCOVERY_SLUG_SALT) + i)
            });
            positions[poolId][bytes32(uint256(DISCOVERY_SLUG_SALT) + i)] = pdSlug;
        }
    }
    
    function _rebalance(PoolId poolId, PoolKey memory key) internal {
        uint256 currentEpoch = _getCurrentEpoch(poolId);
        State storage s = state[poolId];
        
        _processEpochOrders(poolId, s.lastEpoch);
        
        int256 confidenceAdjustment = _calculateConfidenceAdjustment(poolId);
        s.tickAccumulator += confidenceAdjustment;
        
        Position[] memory prevPositions = new Position[](NUM_DEFAULT_SLUGS + numPDSlugs[poolId] - 1);
        prevPositions[0] = positions[poolId][LOWER_SLUG_SALT];
        prevPositions[1] = positions[poolId][UPPER_SLUG_SALT];
        for (uint256 i = 0; i < numPDSlugs[poolId]; i++) {
            prevPositions[NUM_DEFAULT_SLUGS - 1 + i] = positions[poolId][bytes32(uint256(DISCOVERY_SLUG_SALT) + i)];
        }
        
        (BalanceDelta cleared, BalanceDelta fees) = _clearPositions(prevPositions, key);
        
        // Store fees separately since BalanceDelta doesn't have add
        s.feesAccrued0 = s.feesAccrued0 + fees.amount0();
        s.feesAccrued1 = s.feesAccrued1 + fees.amount1();
        
        Position[] memory newPositions = _computeNewSlugs(poolId, key, confidenceAdjustment);
        
        _updatePositions(poolId, newPositions, key);
        
        s.lastEpoch = uint40(currentEpoch);
        
        emit Rebalance(poolId, newPositions[0].tickLower, newPositions[1].tickUpper, currentEpoch);
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
                
                // Manually accumulate deltas
                int128 newAmount0 = total.amount0() + delta.amount0();
                int128 newAmount1 = total.amount1() + delta.amount1();
                total = toBalanceDelta(newAmount0, newAmount1);
                
                int128 newFee0 = fees.amount0() + posFees.amount0();
                int128 newFee1 = fees.amount1() + posFees.amount1();
                fees = toBalanceDelta(newFee0, newFee1);
            }
        }
    }
    
    function _updatePositions(
        PoolId poolId, 
        Position[] memory newPositions,
        PoolKey memory key
    ) internal {
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
                
                if (i == 0) {
                    positions[poolId][LOWER_SLUG_SALT] = newPositions[i];
                } else if (i == 1) {
                    positions[poolId][UPPER_SLUG_SALT] = newPositions[i];
                } else {
                    positions[poolId][bytes32(uint256(DISCOVERY_SLUG_SALT) + i - 2)] = newPositions[i];
                }
            }
        }
    }
    
    function _computeNewSlugs(
        PoolId poolId,
        PoolKey memory key,
        int256 confidenceAdjustment
    ) internal view returns (Position[] memory) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        currentTick += int24(confidenceAdjustment / I_WAD);
        
        uint256 totalLiquidity = _getTotalAvailableLiquidity(poolId);
        
        Position[] memory newPositions = new Position[](NUM_DEFAULT_SLUGS + numPDSlugs[poolId] - 1);
        
        newPositions[0] = Position({
            tickLower: currentTick - 1000,
            tickUpper: currentTick,
            liquidity: uint128(totalLiquidity * 40 / 100),
            salt: uint8(uint256(LOWER_SLUG_SALT))
        });
        
        newPositions[1] = Position({
            tickLower: currentTick,
            tickUpper: currentTick + 1000,
            liquidity: uint128(totalLiquidity * 30 / 100),
            salt: uint8(uint256(UPPER_SLUG_SALT))
        });
        
        uint128 pdLiquidity = uint128(totalLiquidity * 30 / 100 / numPDSlugs[poolId]);
        for (uint256 i = 0; i < numPDSlugs[poolId]; i++) {
            newPositions[2 + i] = Position({
                tickLower: currentTick + int24(int256(1000 * (i + 1))),
                tickUpper: currentTick + int24(int256(1000 * (i + 2))),
                liquidity: pdLiquidity,
                salt: uint8(uint256(DISCOVERY_SLUG_SALT) + i)
            });
        }
        
        return newPositions;
    }
    
    // ============ Helper Functions ============
    
    function _recordTrade(
        PoolId poolId,
        IPoolManager.SwapParams calldata params,
        address trader
    ) internal {
        uint256 epoch = _getCurrentEpoch(poolId);
        uint256 confidence = 7500;
        
        Order memory order = Order({
            trader: trader,
            basketAmount: uint256(params.amountSpecified > 0 ? 
                int256(params.amountSpecified) : 
                -int256(params.amountSpecified)),
            confidence: confidence,
            isYes: params.zeroForOne
        });
        
        epochOrders[poolId][epoch].push(order);
    }
    
    function _processEpochOrders(PoolId poolId, uint256 epoch) internal {
        Order[] memory orders = epochOrders[poolId][epoch];
        if (orders.length == 0) return;
        
        uint256 totalWeightedYes;
        uint256 totalWeightedNo;
        
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 weighted = orders[i].basketAmount * orders[i].confidence / 10000;
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
    
    function _getCurrentEpoch(PoolId poolId) internal view returns (uint256) {
        if (block.timestamp < startingTime[poolId]) return 1;
        return (block.timestamp - startingTime[poolId]) / epochLength[poolId] + 1;
    }
    
    function _calculateConfidenceAdjustment(PoolId poolId) internal view returns (int256) {
        return gamma[poolId] * I_WAD / 2;
    }
    
    function _calculateConfidenceFee(PoolId poolId, address trader) internal view returns (uint24) {
        return 3000;
    }
    
    function _getTotalAvailableLiquidity(PoolId poolId) internal view returns (uint256) {
        return basket.balanceOf(poolMarkets[poolId]);
    }
    
    // ============ Utility function for BalanceDelta ============
    function toBalanceDelta(int128 amount0, int128 amount1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap(bytes32(abi.encodePacked(amount0, amount1)));
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
    
    // Add missing TickMath import helper
    function TickMath() internal pure returns (address) {
        return address(0); // This should import from v4-core
    }
    
    // Additional functions for compatibility...
    
    function getAuctionInfo(PoolId poolId) external view returns (
        uint256 _startTime,
        uint256 _endTime,
        uint256 _epochLength,
        int24 _startTick,
        int24 _endTick,
        uint256 _numPDSlugs,
        uint256 _gamma
    ) {
        return (
            startingTime[poolId],
            endingTime[poolId],
            epochLength[poolId],
            startingTick[poolId],
            endingTick[poolId],
            numPDSlugs[poolId],
            uint256(gamma[poolId])
        );
    }
    
    function getCurrentTick(PoolId poolId) external view returns (int24) {
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // Would need proper TickMath import
        return 0; // Placeholder
    }
    
    function getBasketBalance(PoolId poolId) external view returns (uint256) {
        return basket.balanceOf(poolMarkets[poolId]);
    }
    
    function collectFees(PoolId poolId) external returns (uint256, uint256) {
        State storage s = state[poolId];
        uint256 fee0 = s.feesAccrued0 > 0 ? uint256(int256(s.feesAccrued0)) : 0;
        uint256 fee1 = s.feesAccrued1 > 0 ? uint256(int256(s.feesAccrued1)) : 0;
        s.feesAccrued0 = 0;
        s.feesAccrued1 = 0;
        return (fee0, fee1);
    }
    
    function isResolved(PoolId poolId) external view returns (bool) {
        // Implementation would check settlement status
        return false;
    }
    
    function getOutcome(PoolId poolId) external view returns (bool) {
        // Implementation would check settlement outcome
        return false;
    }
    
    function resolveMarket(PoolId poolId, bool outcome) external {
        require(msg.sender == poolMarkets[poolId], "Only market");
        // Implementation would handle market resolution
    }
    
    function updatePrice(PoolId poolId, uint256 epoch) external {
        // Implementation would update price for epoch
    }
    
    function processBatch(PoolId poolId, uint256 epoch, uint256 ordersCount) external returns (uint256) {
        _processEpochOrders(poolId, epoch);
        return state[poolId].totalBasketIn * WAD / state[poolId].total404Out;
    }
    
    function executeTrade(
        PoolId poolId,
        address trader,
        uint256 yesShares,
        uint256 noShares,
        uint256 confidence
    ) external returns (uint256) {
        // Implementation for trade execution
        return 0;
    }
    
    function stakeLiquidity(
        PoolId poolId,
        address provider,
        uint256 token404Amount,
        uint256 basketAmount
    ) external {
        // Implementation for liquidity staking
    }
    
    function unstakeLiquidity(
        PoolId poolId,
        address provider,
        uint256 token404Amount,
        uint256 basketAmount
    ) external {
        // Implementation for liquidity unstaking
    }
    
    function owner() external view returns (address) {
        return settlement.admin();
    }
    
    function admin() external view returns (address) {
        return settlement.admin();
    }
}