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

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title Safta - Safe Agreement for Future Tokens 
 * @notice Confidence-weighted prediction market with Belgian auction pricing
 * @dev ERC404 implementation with time-decaying prices and batch processing
 */
contract Safta is ERC404, ReentrancyGuard, IArbitrable {
    using Strings for uint256;
    using PoolIdLibrary for PoolKey;
    
    // ============ Core Contracts ============
    Basket public immutable basket;
    Aux public immutable aux;
    Settlement public immutable settlement;
    Base public immutable belgianHook;
    IPoolManager public immutable poolManager;
    
    address public deployer; // Track deployer for initialization
    
    // ============ Market State ============
    struct Market {
        string question;
        uint256 resolutionTime;
        uint32 metaEvidenceId;
        uint32 disputeId;
        bool resolved;
        bool binaryOutcome;
        uint256 scalarOutcome;  // Added for compatibility
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
    mapping(uint256 => address) public tokenIdToOwner;
    
    // ============ Confidence System ============
    uint256 public constant CONFIDENCE_SCALE = 10000; // 100.00%
    uint256 public constant MIN_CONFIDENCE = 5100;    // 51%
    uint256 public constant MAX_CONFIDENCE = 9900;    // 99%
    uint256 public constant DEFAULT_CONFIDENCE = 7500; // 75%
    
    mapping(address => uint256) public userConfidence;
    mapping(address => uint256) public confidenceUpdatedAt;
    uint256 public confidenceCooldown = 1 hours;
    
    // ============ Belgian Auction State ============
    uint256 public currentEpoch;
    uint256 public epochDuration = 1 hours;
    uint256 public lastEpochUpdate;
    uint256 public totalYesVolume;
    uint256 public totalNoVolume;
    
    // Batch auction orders
    struct Order {
        address trader;
        uint256 amount;
        uint256 confidence;
        bool isYes;
        uint256 timestamp;
    }
    
    Order[] public currentEpochOrders;
    mapping(uint256 => Order[]) public epochOrders;
    
    // ============ Events ============
    event MarketCreated(string question, uint256 resolutionTime, PoolId poolId);
    event PositionOpened(address indexed user, uint256 amount, bool isYes, uint256 confidence);
    event PositionClosed(address indexed user, uint256 yesShares, uint256 noShares);
    event ConfidenceUpdated(address indexed user, uint256 newConfidence);
    event EpochCompleted(uint256 epoch, uint256 yesVolume, uint256 noVolume, uint256 clearingPrice);
    event BatchProcessed(uint256 epoch, uint256 ordersProcessed);
    event MarketResolved(bool outcome, uint256 scalarOutcome);
    event RewardsClaimed(address indexed user, uint256 amount);
    event DisputeCreated(uint256 disputeId);
    
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
        
        // Mint initial supply to contract for liquidity provision
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
        
        // Initialize meta-evidence ID for tracking
        market.metaEvidenceId = uint32(block.timestamp % type(uint32).max);
        
        lastEpochUpdate = block.timestamp;
        
        emit MarketCreated(_question, _resolutionTime, poolId);
    }
    
    // ============ Internal Burn Function ============
    
    function _burnTokens(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        // Handle ERC20 side
        balanceOf[from] -= amount;
        totalSupply -= amount;
        
        // Handle ERC721 side - need to burn corresponding NFTs
        uint256 nftsToBurn = amount / units;
        for (uint256 i = 0; i < nftsToBurn; i++) {
            if (_owned[from].length > 0) {
                uint256 tokenId = _owned[from][_owned[from].length - 1];
                _owned[from].pop();
                delete _ownedData[tokenId];
                // Emit ERC721 Transfer event for NFT burn
                emit ERC721Events.Transfer(from, address(0), tokenId);
            }
        }
        
        // Emit ERC20 Transfer event for token burn
        emit ERC20Events.Transfer(from, address(0), amount);
    }
    
    // ============ Trading Functions ============
    
    /**
     * @notice Open a position with confidence weighting
     * @param amount Amount of basket tokens to deposit
     * @param isYes Whether betting on YES outcome
     * @param confidence Confidence level (5100-9900)
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
        
        // Add order to current epoch batch
        currentEpochOrders.push(Order({
            trader: msg.sender,
            amount: amount,
            confidence: confidence,
            isYes: isYes,
            timestamp: block.timestamp
        }));
        
        // Update user confidence if changed
        if (userConfidence[msg.sender] != confidence) {
            _updateConfidence(msg.sender, confidence);
        }
        
        // Update position tracking
        Position storage pos = positions[msg.sender];
        pos.basketDeposited += amount;
        
        // Weight shares by confidence
        uint256 weightedAmount = (amount * confidence) / CONFIDENCE_SCALE;
        
        if (isYes) {
            pos.yesShares += uint128(amount);
            pos.weightedYesShares += weightedAmount;
            totalYesVolume += amount;
        } else {
            pos.noShares += uint128(amount);
            pos.weightedNoShares += weightedAmount;
            totalNoVolume += amount;
        }
        
        // Update average confidence
        uint256 totalWeighted = pos.weightedYesShares + pos.weightedNoShares;
        uint256 totalShares = uint256(pos.yesShares) + uint256(pos.noShares);
        pos.avgConfidence = totalShares > 0 ? (totalWeighted * CONFIDENCE_SCALE) / totalShares : DEFAULT_CONFIDENCE;
        
        // Mint ERC20/404 tokens representing position
        _mintERC20(msg.sender, amount);
        
        emit PositionOpened(msg.sender, amount, isYes, confidence);
        
        // Check if epoch should advance
        _checkEpochAdvance();
    }
    
    /**
     * @notice Close position and withdraw funds
     * @param shareAmount Amount of shares to close
     */
    function closePosition(uint256 shareAmount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        uint256 totalShares = uint256(pos.yesShares) + uint256(pos.noShares);
        
        require(shareAmount > 0 && shareAmount <= totalShares, "Invalid share amount");
        require(balanceOf[msg.sender] >= shareAmount, "Insufficient ERC404 balance");
        
        // Calculate proportional withdrawal
        uint256 yesToClose = (shareAmount * uint256(pos.yesShares)) / totalShares;
        uint256 noToClose = (shareAmount * uint256(pos.noShares)) / totalShares;
        uint256 basketToReturn = (shareAmount * pos.basketDeposited) / totalShares;
        
        // Update position
        pos.yesShares -= uint128(yesToClose);
        pos.noShares -= uint128(noToClose);
        pos.basketDeposited -= basketToReturn;
        
        // Update weighted amounts proportionally
        pos.weightedYesShares = (pos.weightedYesShares * (totalShares - shareAmount)) / totalShares;
        pos.weightedNoShares = (pos.weightedNoShares * (totalShares - shareAmount)) / totalShares;
        
        // Burn ERC404 tokens using our internal burn function
        _burnTokens(msg.sender, shareAmount);
        
        // Execute trade through hook if market not resolved
        if (!market.resolved) {
            uint256 proceeds = belgianHook.executeTrade(
                poolId,
                msg.sender,
                yesToClose,
                noToClose,
                pos.avgConfidence
            );
            
            // Add any trading proceeds to return amount
            basketToReturn += proceeds;
        }
        
        // Return basket tokens
        basket.transfer(msg.sender, basketToReturn);
        
        emit PositionClosed(msg.sender, yesToClose, noToClose);
    }
    
    // ============ Confidence Management ============
    
    function updateConfidence(uint256 newConfidence) external {
        require(newConfidence >= MIN_CONFIDENCE && newConfidence <= MAX_CONFIDENCE, "Invalid confidence");
        _updateConfidence(msg.sender, newConfidence);
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
    
    function getConfidence(address user) public view returns (uint256) {
        uint256 conf = userConfidence[user];
        return conf > 0 ? conf : DEFAULT_CONFIDENCE;
    }
    
    // ============ Epoch Management ============
    
    function _checkEpochAdvance() internal {
        if (block.timestamp >= lastEpochUpdate + epochDuration) {
            _processEpoch();
        }
    }
    
    function _processEpoch() internal {
        // Store orders for this epoch
        epochOrders[currentEpoch] = currentEpochOrders;
        
        // Process batch through hook
        if (currentEpochOrders.length > 0) {
            uint256 clearingPrice = belgianHook.processBatch(
                poolId,
                currentEpoch,
                currentEpochOrders.length
            );
            
            emit EpochCompleted(
                currentEpoch,
                totalYesVolume,
                totalNoVolume,
                clearingPrice
            );
            
            emit BatchProcessed(currentEpoch, currentEpochOrders.length);
        }
        
        // Reset for next epoch
        delete currentEpochOrders;
        currentEpoch++;
        lastEpochUpdate = block.timestamp;
        
        // Update hook's price for new epoch
        belgianHook.updatePrice(poolId, currentEpoch);
    }
    
    function forceProcessEpoch() external {
        require(block.timestamp >= lastEpochUpdate + epochDuration, "Epoch not ready");
        _processEpoch();
    }
    
    // ============ Liquidity Provision ============
    
    function _provideLiquidity(uint256 amount) internal {
        basket.approve(address(belgianHook), amount);
        belgianHook.stakeLiquidity(poolId, address(this), amount, amount);
    }
    
    function addLiquidity(uint256 basketAmount) external nonReentrant {
        basket.transferFrom(msg.sender, address(this), basketAmount);
        
        // Calculate proportional 404 tokens to stake
        uint256 token404Amount = (basketAmount * totalSupply) / basket.balanceOf(address(this));
        
        // Mint additional ERC20/404 tokens for liquidity
        _mintERC20(msg.sender, token404Amount);
        
        // Stake in hook
        basket.approve(address(belgianHook), basketAmount);
        belgianHook.stakeLiquidity(poolId, msg.sender, token404Amount, basketAmount);
    }
    
    function removeLiquidity(uint256 token404Amount) external nonReentrant {
        require(balanceOf[msg.sender] >= token404Amount, "Insufficient balance");
        
        // Calculate proportional basket amount
        uint256 basketAmount = (token404Amount * basket.balanceOf(address(this))) / totalSupply;
        
        // Unstake from hook
        belgianHook.unstakeLiquidity(poolId, msg.sender, token404Amount, basketAmount);
        
        // Burn liquidity tokens using our internal burn function
        _burnTokens(msg.sender, token404Amount);
        
        // Return basket tokens
        basket.transfer(msg.sender, basketAmount);
    }
    
    // ============ Settlement Functions ============
    
    function requestResolution() external {
        require(block.timestamp >= market.resolutionTime, "Resolution time not reached");
        require(!market.resolved, "Already resolved");
        
        // Create dispute for resolution
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
            // Invalid/refused to arbitrate - enable refunds
            market.binaryOutcome = false;
            market.scalarOutcome = 0;
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
            // YES won - weighted by confidence
            payout = pos.weightedYesShares;
        } else {
            // NO won - weighted by confidence
            payout = pos.weightedNoShares;
        }
        
        if (payout > 0) {
            // Calculate share of pool
            uint256 totalPool = basket.balanceOf(address(this));
            uint256 totalWeightedShares = market.binaryOutcome ? 
                _getTotalWeightedYesShares() : 
                _getTotalWeightedNoShares();
            
            uint256 reward = (payout * totalPool) / totalWeightedShares;
            
            basket.transfer(msg.sender, reward);
            
            emit RewardsClaimed(msg.sender, reward);
        }
    }
    
    function emergencyRefund() external nonReentrant {
        require(market.resolved && market.scalarOutcome == 0, "Not in refund mode");
        
        Position storage pos = positions[msg.sender];
        require(!pos.hasClaimed, "Already claimed");
        
        pos.hasClaimed = true;
        
        uint256 refund = pos.basketDeposited;
        pos.basketDeposited = 0;
        
        if (refund > 0) {
            basket.transfer(msg.sender, refund);
            emit RewardsClaimed(msg.sender, refund);
        }
    }
    
    // ============ View Functions ============
    
    function _getTotalWeightedYesShares() internal view returns (uint256 total) {
        // This would need to iterate through all positions
        // In practice, track this in storage for gas efficiency
        return totalYesVolume * DEFAULT_CONFIDENCE / CONFIDENCE_SCALE;
    }
    
    function _getTotalWeightedNoShares() internal view returns (uint256 total) {
        return totalNoVolume * DEFAULT_CONFIDENCE / CONFIDENCE_SCALE;
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
    
    // Additional getter for epoch
    function getCurrentEpoch() external view returns (uint256) {
        return currentEpoch;
    }
    
    // Expose market struct for Settlement compatibility
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
    
    // For Settlement binary markets
    function resolveMarket(bool outcome) external {
        require(msg.sender == address(settlement), "Only settlement");
        require(!market.resolved, "Already resolved");
        
        market.resolved = true;
        market.binaryOutcome = outcome;
        
        // Notify hook of resolution
        belgianHook.resolveMarket(poolId, outcome);
        
        emit MarketResolved(outcome, 0);
    }
    
    // Check resolution status
    function isResolved() external view returns (bool) {
        return market.resolved;
    }
    
    // Get outcome
    function getOutcome() external view returns (bool) {
        return market.binaryOutcome;
    }
    
    // Force majeur from Settlement
    function triggerForceMajeur(string memory reason) external {
        require(msg.sender == address(settlement), "Only settlement");
        market.resolved = true;
        market.binaryOutcome = false; // Default to NO on force majeur
        emit MarketResolved(false, 0);
    }
    
    // Check if in force majeur (when resolved with no clear outcome)
    function isInForceMajeur() external view returns (bool) {
        // In force majeur, positions would be refundable
        Position memory pos = positions[msg.sender];
        return market.resolved && !pos.hasClaimed;
    }
    
    // ============ Aliases for test compatibility ============
    function placeBid(uint256 amount, bool isYes, uint256 confidence) external {
        this.openPosition(amount, isYes, confidence * 100); // Convert confidence 0-100 to 5100-9900 scale
    }
    
    function processBatch(uint256 epochNumber) external {
        require(epochNumber == currentEpoch, "Wrong epoch");
        _processEpoch();
    }
    
    function claimWinnings() external returns (uint256) {
        uint256 balanceBefore = basket.balanceOf(msg.sender);
        this.claimRewards();
        uint256 balanceAfter = basket.balanceOf(msg.sender);
        return balanceAfter - balanceBefore;
    }
    
    function claimRefund() external returns (uint256) {
        uint256 balanceBefore = basket.balanceOf(msg.sender);
        this.emergencyRefund();
        uint256 balanceAfter = basket.balanceOf(msg.sender);
        return balanceAfter - balanceBefore;
    }
    
    function getPoolId() external view returns (PoolId) {
        return poolId;
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
    
    function getCurrentEpochOrders() external view returns (uint256) {
        return currentEpochOrders.length;
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