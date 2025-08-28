// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC404 } from "./imports/ERC404.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import {ERC721Events} from "./imports/ERC721Events.sol";
import {ERC20Events} from "./imports/ERC20Events.sol";

import { IArbitrable } from "./imports/IArbitrable.sol";
import { Settlement } from "./Settlement.sol";
import { Basket } from "./Basket.sol";
import { Base } from "./Base.sol";
import { Aux } from "./Aux.sol";

import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title Safta - Safe Agreement for Future Tokens 
 * @notice Confidence-weighted prediction market integrated with Belgian auction hook
 * @dev ERC404 implementation that interfaces with Base hook for price discovery
 */
contract Safta is ERC404, ReentrancyGuard, IArbitrable {
    using Strings for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    
    // ============ Core Contracts ============
    Basket public immutable basket;
    Aux public immutable aux;
    Settlement public immutable settlement;
    Base public immutable belgianHook;
    IPoolManager public immutable poolManager;
    
    address public deployer;
    
    // ============ Market State ============
    struct Market {
        string question;
        uint256 resolutionTime;
        uint32 metaEvidenceId;
        uint32 disputeId;
        bool resolved;
        bool binaryOutcome;
        uint256 scalarOutcome;
    }
    
    struct Position {
        uint128 yesShares;
        uint128 noShares;
        uint256 basketDeposited;
        uint256 weightedYesShares;
        uint256 weightedNoShares;
        uint256 avgConfidence;
        bool hasClaimed;
    }
    
    Market public market;
    PoolKey public poolKey;
    PoolId public poolId;
    
    mapping(address => Position) public positions;
    mapping(address => uint256) public pendingShares; // Shares awaiting batch clear
    
    // ============ Confidence System ============
    uint256 public constant CONFIDENCE_SCALE = 10000;
    uint256 public constant MIN_CONFIDENCE = 5100;
    uint256 public constant MAX_CONFIDENCE = 9900;
    uint256 public constant DEFAULT_CONFIDENCE = 7500;
    
    mapping(address => uint256) public userConfidence;
    mapping(address => uint256) public confidenceUpdatedAt;
    uint256 public confidenceCooldown = 1 hours;
    
    // Track total volumes for resolution
    uint256 public totalYesVolume;
    uint256 public totalNoVolume;
    
    // ============ Events ============
    event MarketCreated(string question, uint256 resolutionTime, PoolId poolId);
    event PositionOpened(address indexed user, uint256 amount, bool isYes, uint256 confidence);
    event PositionClosed(address indexed user, uint256 yesShares, uint256 noShares);
    event ConfidenceUpdated(address indexed user, uint256 newConfidence);
    event SharesAllocated(address indexed user, uint256 shares, bool isYes);
    event MarketResolved(bool outcome, uint256 scalarOutcome);
    event RewardsClaimed(address indexed user, uint256 amount);
    event DisputeCreated(uint256 disputeId);
    error NothingToClaim();
    
    // ============ Modifiers ============
    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer");
        _;
    }
    
    modifier marketNotResolved() {
        require(!market.resolved, "Market resolved");
        _;
    }
    
    modifier marketResolved() {
        require(market.resolved, "Market not resolved");
        _;
    }
    
    // ============ Constructor ============
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _totalSupply,
        address _basket,
        address payable _aux,
        address _settlement,
        address _belgianHook,
        address _poolManager
    ) ERC404(_name, _symbol, _decimals) {
        basket = Basket(_basket);
        aux = Aux(_aux);
        settlement = Settlement(_settlement);
        belgianHook = Base(_belgianHook);
        poolManager = IPoolManager(_poolManager);
        deployer = msg.sender;
        
        // Mint initial supply to contract for liquidity
        _mintERC20(address(this), _totalSupply);
    }
    
    // ============ Market Initialization ============
    function initializeMarket(
        string memory _question,
        uint256 _resolutionTime,
        PoolKey memory _poolKey,
        uint256 _initialLiquidity
    ) external onlyDeployer {
        require(bytes(market.question).length == 0, "Already initialized");
        
        market.question = _question;
        market.resolutionTime = _resolutionTime;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        
        // Register with hook
        belgianHook.registerMarket(poolId, address(this));
        
        // Provide initial liquidity if specified
        if (_initialLiquidity > 0) {
            _provideLiquidity(_initialLiquidity);
        }
        
        market.metaEvidenceId = uint32(block.timestamp % type(uint32).max);
        
        emit MarketCreated(_question, _resolutionTime, poolId);
    }
    
    // ============ Trading Functions (Hook Integration) ============
    
    /**
     * @notice Open position by swapping through the pool
     * @dev Hook intercepts swap and processes with Belgian auction
     */
    function openPosition(
        uint256 amount,
        bool isYes,
        uint256 confidence
    ) external nonReentrant marketNotResolved {
        require(amount > 0, "Amount must be positive");
        require(confidence >= MIN_CONFIDENCE && confidence <= MAX_CONFIDENCE, "Invalid confidence");
        
        // Transfer basket tokens from user
        basket.transferFrom(msg.sender, address(this), amount);
        
        // Update user confidence
        if (userConfidence[msg.sender] != confidence) {
            _updateConfidence(msg.sender, confidence);
        }
        
        // Track deposit
        Position storage pos = positions[msg.sender];
        pos.basketDeposited += amount;
        pos.avgConfidence = _updateAvgConfidence(pos, confidence, amount);
        
        // Record pending shares (actual allocation happens after batch)
        pendingShares[msg.sender] += amount;
        
        // Swap through pool - hook will handle Belgian auction mechanics
        _swapThroughPool(amount, isYes, confidence);
        
        emit PositionOpened(msg.sender, amount, isYes, confidence);
    }
    
    /**
     * @notice Execute swap through Uniswap pool with hook interception
     */
    function _swapThroughPool(uint256 amount, bool isYes, uint256 confidence) internal {
        // Approve pool manager to use basket tokens
        basket.approve(address(poolManager), amount);
        
        // Determine swap direction based on token ordering and YES/NO
        bool zeroForOne = _getSwapDirection(isYes);
        
        // Execute swap - hook's beforeSwap will intercept
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: 0 // No limit, let Belgian auction determine price
            }),
            abi.encode(confidence) // Pass confidence as hook data
        );
        
        // Process delta to update user position
        _processSwapDelta(msg.sender, delta, isYes);
    }
    
    /**
     * @notice Process swap results and allocate shares
     */
    function _processSwapDelta(address user, BalanceDelta delta, bool isYes) internal {
        // Calculate shares received from swap
        uint256 sharesReceived;
        
        if (Currency.unwrap(poolKey.currency0) == address(this)) {
            // 404 token is token0
            sharesReceived = uint256(uint128(delta.amount0()));
        } else {
            // 404 token is token1
            sharesReceived = uint256(uint128(delta.amount1()));
        }
        
        if (sharesReceived > 0) {
            Position storage pos = positions[user];
            
            // Allocate shares based on YES/NO
            if (isYes) {
                pos.yesShares += uint128(sharesReceived);
                pos.weightedYesShares += (sharesReceived * pos.avgConfidence) / CONFIDENCE_SCALE;
                totalYesVolume += sharesReceived;
            } else {
                pos.noShares += uint128(sharesReceived);
                pos.weightedNoShares += (sharesReceived * pos.avgConfidence) / CONFIDENCE_SCALE;
                totalNoVolume += sharesReceived;
            }
            
            // Clear pending shares
            if (pendingShares[user] >= sharesReceived) {
                pendingShares[user] -= sharesReceived;
            } else {
                pendingShares[user] = 0;
            }
            
            // Mint 404 tokens
            _mintERC20(user, sharesReceived);
            
            emit SharesAllocated(user, sharesReceived, isYes);
        }
    }
    
    /**
     * @notice Close position by swapping back through pool
     */
    function closePosition(uint256 shareAmount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        uint256 totalShares = uint256(pos.yesShares) + uint256(pos.noShares);
        
        require(shareAmount > 0 && shareAmount <= totalShares, "Invalid share amount");
        require(balanceOf[msg.sender] >= shareAmount, "Insufficient balance");
        
        // Calculate proportional amounts
        uint256 yesToClose = (shareAmount * uint256(pos.yesShares)) / totalShares;
        uint256 noToClose = (shareAmount * uint256(pos.noShares)) / totalShares;
        
        // Update position
        pos.yesShares -= uint128(yesToClose);
        pos.noShares -= uint128(noToClose);
        
        // Proportionally reduce weighted shares
        if (totalShares > 0) {
            pos.weightedYesShares = (pos.weightedYesShares * (totalShares - shareAmount)) / totalShares;
            pos.weightedNoShares = (pos.weightedNoShares * (totalShares - shareAmount)) / totalShares;
        }
        
        // Burn 404 tokens
        _burnTokens(msg.sender, shareAmount);
        
        // Swap back through pool if market not resolved
        if (!market.resolved) {
            _swapBackThroughPool(shareAmount, yesToClose > noToClose);
        }
        
        emit PositionClosed(msg.sender, yesToClose, noToClose);
    }
    
    function _swapBackThroughPool(uint256 amount, bool wasYes) internal {
        // Approve pool manager - use the public approve function
        approve(address(poolManager), amount);
        
        // Swap 404 tokens back to basket
        bool zeroForOne = !_getSwapDirection(wasYes);
        
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount), // Negative for exact input
                sqrtPriceLimitX96: 0
            }),
            ""
        );
        
        // Transfer basket tokens back to user
        uint256 basketReceived;
        if (Currency.unwrap(poolKey.currency0) == address(basket)) {
            basketReceived = uint256(uint128(-delta.amount0()));
        } else {
            basketReceived = uint256(uint128(-delta.amount1()));
        }
        
        if (basketReceived > 0) {
            basket.transfer(msg.sender, basketReceived);
        }
    }
    
    function _getSwapDirection(bool isYes) internal view returns (bool) {
        // Determine swap direction based on token ordering
        bool basketIs0 = Currency.unwrap(poolKey.currency0) == address(basket);
        
        // If buying YES: swap basket for 404
        // If buying NO: also swap basket for 404 (market maker determines price difference)
        return basketIs0;
    }
    
    // ============ Liquidity Functions ============
    
    function _provideLiquidity(uint256 amount) internal {
        basket.approve(address(belgianHook), amount);
        belgianHook.stakeLiquidity(poolId, address(this), amount, amount);
    }
    
    function addLiquidity(uint256 basketAmount) external nonReentrant {
        basket.transferFrom(msg.sender, address(this), basketAmount);
        
        // Calculate proportional 404 tokens
        uint256 token404Amount = totalSupply > 0 ? 
            (basketAmount * totalSupply) / basket.totalBalances(address(this)) : basketAmount;
        
        // Mint LP tokens
        _mintERC20(msg.sender, token404Amount);
        
        // Stake in hook
        basket.approve(address(belgianHook), basketAmount);
        belgianHook.stakeLiquidity(poolId, msg.sender, token404Amount, basketAmount);
    }
    
    function removeLiquidity(uint256 token404Amount) external nonReentrant {
        require(balanceOf[msg.sender] >= token404Amount, "Insufficient balance");
        
        // Calculate proportional basket amount
        uint256 basketAmount = (token404Amount * basket.totalBalances(address(this))) / totalSupply;
        
        // Unstake from hook
        belgianHook.unstakeLiquidity(poolId, msg.sender, token404Amount, basketAmount);
        
        // Burn LP tokens
        _burnTokens(msg.sender, token404Amount);
        
        // Return basket tokens
        basket.transfer(msg.sender, basketAmount);
    }
    
    // ============ Helper Functions ============
    
    function _updateAvgConfidence(
        Position memory pos,
        uint256 newConfidence,
        uint256 newAmount
    ) internal pure returns (uint256) {
        uint256 totalWeighted = pos.weightedYesShares + pos.weightedNoShares + (newAmount * newConfidence / CONFIDENCE_SCALE);
        uint256 totalAmount = uint256(pos.yesShares) + uint256(pos.noShares) + newAmount;
        return totalAmount > 0 ? (totalWeighted * CONFIDENCE_SCALE) / totalAmount : DEFAULT_CONFIDENCE;
    }
    
    function _updateConfidence(address user, uint256 newConfidence) internal {
        require(
            block.timestamp >= confidenceUpdatedAt[user] + confidenceCooldown,
            "Confidence on cooldown"
        );
        
        userConfidence[user] = newConfidence;
        confidenceUpdatedAt[user] = block.timestamp;
        
        emit ConfidenceUpdated(user, newConfidence);
    }
    
    function _burnTokens(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        balanceOf[from] -= amount;
        totalSupply -= amount;
        
        // Burn NFTs
        uint256 nftsToBurn = amount / units;
        for (uint256 i = 0; i < nftsToBurn; i++) {
            if (_owned[from].length > 0) {
                uint256 tokenId = _owned[from][_owned[from].length - 1];
                _owned[from].pop();
                delete _ownedData[tokenId];
                emit ERC721Events.Transfer(from, address(0), tokenId);
            }
        }
        
        emit ERC20Events.Transfer(from, address(0), amount);
    }
    
    // ============ Settlement Functions ============
    
    function requestResolution() external {
        require(block.timestamp >= market.resolutionTime, "Resolution time not reached");
        require(!market.resolved, "Already resolved");
        
        uint256 disputeId = settlement.createDispute(2, "");
        market.disputeId = uint32(disputeId);
        
        emit DisputeCreated(market.disputeId);
    }
    
    function rule(uint256 _disputeId, uint256 _ruling) external override {
        require(msg.sender == address(settlement), "Only settlement");
        require(_disputeId == market.disputeId, "Invalid dispute");
        require(!market.resolved, "Already resolved");
        
        market.resolved = true;
        
        if (_ruling == 1) {
            market.binaryOutcome = false; // NO wins
        } else if (_ruling == 2) {
            market.binaryOutcome = true;  // YES wins
        } else {
            market.binaryOutcome = false;
            market.scalarOutcome = 0; // Enable refunds
        }
        
        // Notify hook of resolution
        belgianHook.resolveMarket(poolId, market.binaryOutcome);
        
        emit MarketResolved(market.binaryOutcome, market.scalarOutcome);
    }
    
    function claimRewards() external nonReentrant marketResolved {
        Position storage pos = positions[msg.sender];
        require(!pos.hasClaimed, "Already claimed");
        
        pos.hasClaimed = true;
        
        uint256 payout = 0;
        
        if (market.binaryOutcome) {
            payout = pos.weightedYesShares;
        } else {
            payout = pos.weightedNoShares;
        }
        
        if (payout > 0) {
            uint256 totalPool = basket.totalBalances(address(this));
            uint256 totalWeightedShares = market.binaryOutcome ? 
                _getTotalWeightedYesShares() : 
                _getTotalWeightedNoShares();
            
            if (totalWeightedShares > 0) {
                uint256 reward = (payout * totalPool) / totalWeightedShares;
                basket.transfer(msg.sender, reward);
                emit RewardsClaimed(msg.sender, reward);
            }
        }
    }
    
    // ============ View Functions ============
    
    function _getTotalWeightedYesShares() internal view returns (uint256) {
        return totalYesVolume * DEFAULT_CONFIDENCE / CONFIDENCE_SCALE;
    }
    
    function _getTotalWeightedNoShares() internal view returns (uint256) {
        return totalNoVolume * DEFAULT_CONFIDENCE / CONFIDENCE_SCALE;
    }
    
    function getConfidence(address user) public view returns (uint256) {
        uint256 conf = userConfidence[user];
        return conf > 0 ? conf : DEFAULT_CONFIDENCE;
    }
    
    // ============ Callback from Hook ============
    
    function updateFromHook(
        uint256 total404Out,
        uint256 totalBasketIn
    ) external {
        require(msg.sender == address(belgianHook), "Only hook");
        // Hook can update market state after batch processing
    }
    
    // ============ Test Compatibility Functions ============
    
    function placeBid(uint256 amount, bool isYes, uint256 confidence) external {
        // Scale confidence from 0-100 to 5100-9900
        uint256 scaledConf = MIN_CONFIDENCE + (confidence * (MAX_CONFIDENCE - MIN_CONFIDENCE) / 100);
        this.openPosition(amount, isYes, scaledConf);
    }
    
    function processBatch(uint256 epochNumber) external {
        // Hook handles batch processing automatically
        // This is a no-op for compatibility
    }
    
    function claimWinnings() external returns (uint256) {
        uint256 before = basket.totalBalances(msg.sender);
        this.claimRewards();
        return basket.totalBalances(msg.sender) - before;
    }
    
    function getCurrentEpoch() external pure returns (uint256) {
        return 0; // Hook manages epochs
    }
    
    function getPoolId() external view returns (PoolId) {
        return poolId;
    }
    
    function isResolved() external view returns (bool) {
        return market.resolved;
    }
    
    function getOutcome() external view returns (bool) {
        return market.binaryOutcome;
    }
    
    function resolveMarket(bool outcome) external {
        require(msg.sender == address(settlement), "Only settlement");
        require(!market.resolved, "Already resolved");
        
        market.resolved = true;
        market.binaryOutcome = outcome;
        
        belgianHook.resolveMarket(poolId, outcome);
        emit MarketResolved(outcome, 0);
    }
    
    function getMarketInfo() external view returns (
        string memory question,
        uint256 resolutionTime,
        bool resolved,
        bool outcome,
        uint256 yesVolume,
        uint256 noVolume
    ) {
        return (
            market.question,
            market.resolutionTime,
            market.resolved,
            market.binaryOutcome,
            totalYesVolume,
            totalNoVolume
        );
    }
    
    function getMarket() external view returns (
        string memory question,
        uint256 resolutionTime,
        uint32 metaEvidenceId,
        uint32 disputeId,
        bool resolved,
        bool,  // unused placeholder for compatibility
        uint256,  // unused placeholder
        bool binaryOutcome
    ) {
        return (
            market.question,
            market.resolutionTime,
            market.metaEvidenceId,
            market.disputeId,
            market.resolved,
            false,  // was isScalar, now always false
            0,      // was scalarOutcome, now always 0
            market.binaryOutcome
        );
    }
    
    function getPosition(address user) external view returns (
        uint128 yesShares,
        uint128 noShares,
        uint256 basketDeposited,
        uint256 avgConfidence,
        bool hasClaimed
    ) {
        Position memory pos = positions[user];
        return (
            pos.yesShares,
            pos.noShares,
            pos.basketDeposited,
            pos.avgConfidence,
            pos.hasClaimed
        );
    }
    
    function triggerForceMajeur(string memory reason) external {
        require(msg.sender == address(settlement), "Only settlement");
        market.resolved = true;
        market.binaryOutcome = false; // Default to NO on force majeur
        emit MarketResolved(false, 0);
    }
    
    function isInForceMajeur() external view returns (bool) {
        // In force majeur, positions would be refundable
        Position memory pos = positions[msg.sender];
        return market.resolved && !pos.hasClaimed;
    }
    
    function claimRefund() external returns (uint256) {
        Position storage pos = positions[msg.sender];
        require(market.resolved && !pos.hasClaimed, "Cannot refund");
        
        uint256 refund = pos.basketDeposited;
        pos.hasClaimed = true;
        pos.basketDeposited = 0;
        
        if (refund > 0) {
            basket.transfer(msg.sender, refund);
        }
        
        return refund;
    }
    
    function buyWithETH(
        uint256 basketAmount,
        bool isYes,
        uint256 confidence
    ) external payable nonReentrant marketNotResolved {
        require(msg.value > 0, "Must send ETH");
        
        // Swap ETH to basket via Aux
        aux.swap{value: msg.value}(address(basket), false, 0, 2);
        
        // Get basket balance after swap
        uint256 basketBalance = basket.totalBalances(address(this));
        require(basketBalance >= basketAmount, "Insufficient basket after swap");
        
        // Open position with swapped basket tokens
        Position storage pos = positions[msg.sender];
        pos.basketDeposited += basketAmount;
        
        uint256 weightedAmount = (basketAmount * confidence) / CONFIDENCE_SCALE;
        
        if (isYes) {
            pos.yesShares += uint128(basketAmount);
            pos.weightedYesShares += weightedAmount;
            totalYesVolume += basketAmount;
        } else {
            pos.noShares += uint128(basketAmount);
            pos.weightedNoShares += weightedAmount;
            totalNoVolume += basketAmount;
        }
        
        _mintERC20(msg.sender, basketAmount);
        emit PositionOpened(msg.sender, basketAmount, isYes, confidence);
    }
    
    function buyWithStable(
        uint256 basketAmount,
        address stablecoin,
        uint256 stableAmount,
        bool isYes,
        uint256 confidence
    ) external nonReentrant marketNotResolved {
        // Transfer stablecoin from user
        IERC20(stablecoin).transferFrom(msg.sender, address(this), stableAmount);
        
        // Approve basket to use stablecoin
        IERC20(stablecoin).approve(address(basket), stableAmount);
        
        // Mint basket tokens
        basket.mint(address(this), basketAmount, stablecoin, 0);
        
        // Open position
        this.openPosition(basketAmount, isYes, confidence);
    }
    
    // ============ ERC404 Overrides ============
    
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address tokenOwner = ownerOf(tokenId);
        require(tokenOwner != address(0), "Token does not exist");
        
        Position memory pos = positions[tokenOwner];
        
        string memory svg = _generateSVG(tokenId, pos);
        
        string memory json = string(abi.encodePacked(
            '{"name": "Safta Position #', tokenId.toString(), '",',
            '"description": "Prediction market position for: ', market.question, '",',
            '"image": "data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes": [',
                '{"trait_type": "YES Shares", "value": ', uint256(pos.yesShares).toString(), '},',
                '{"trait_type": "NO Shares", "value": ', uint256(pos.noShares).toString(), '},',
                '{"trait_type": "Confidence", "value": ', (pos.avgConfidence / 100).toString(), '},',
                '{"trait_type": "Basket Deposited", "value": ', pos.basketDeposited.toString(), '}',
            ']}'
        ));
        
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }
    
    function _generateSVG(uint256 tokenId, Position memory pos) internal view returns (string memory) {
        uint256 yesPercent = 0;
        uint256 total = uint256(pos.yesShares) + uint256(pos.noShares);
        if (total > 0) {
            yesPercent = (uint256(pos.yesShares) * 100) / total;
        }
        
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#1a1a2e"/>',
            '<text x="200" y="50" text-anchor="middle" fill="#eee" font-size="20">Position #', tokenId.toString(), '</text>',
            '<rect x="50" y="100" width="300" height="40" fill="#16213e" stroke="#0f3460" stroke-width="2"/>',
            '<rect x="50" y="100" width="', (yesPercent * 3).toString(), '" height="40" fill="#00ff00" opacity="0.6"/>',
            '<text x="200" y="125" text-anchor="middle" fill="#fff" font-size="16">YES: ', yesPercent.toString(), '%</text>',
            '<text x="200" y="180" text-anchor="middle" fill="#aaa" font-size="14">Confidence: ', (pos.avgConfidence / 100).toString(), '%</text>',
            '<text x="200" y="220" text-anchor="middle" fill="#aaa" font-size="12">', market.question, '</text>',
            '</svg>'
        ));
    }
}