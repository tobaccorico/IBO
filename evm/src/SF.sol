// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Safta } from "./Safta.sol";
import { Base } from "./Base.sol";
import { Settlement } from "./Settlement.sol";
import { Basket } from "./Basket.sol";
import { Rover } from "./Rover.sol";
import { Aux } from "./Aux.sol";

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";

import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

contract SaftaFactory {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    event MarketDeployed(
        address indexed market,
        address indexed hook,
        string question,
        uint256 resolutionTime
    );
    event HookDeployed(address indexed hook, uint160 prefix);
    event MarketRegistered(address indexed market);
    event LiquidityProvided(address indexed market, uint256 amount);
    event MarketTypeDeployed(string marketType, address market);
    event CustomParametersSet(address market, bytes params);

    IPoolManager public immutable poolManager;
    Basket public immutable basket;
    Aux public immutable aux;
    Settlement public immutable settlement;
    Rover public immutable rover;
    Base public immutable belgianHook; // Singleton hook
    
    address[] public markets;
    address[] public deployedHooks;
    mapping(address => bool) public isValidMarket;
    mapping(address => address) public marketToHook;
    mapping(address => MarketMetadata) public marketMetadata;
    mapping(string => address[]) public marketsByType;
    mapping(address => uint256) public marketIndex;
    
    struct MarketMetadata {
        string question;
        uint256 resolutionTime;
        uint256 deployTime;
        address deployer;
        string marketType;
        bool isActive;
        uint256 totalLiquidity;
    }
    
    uint24 public constant MARKET_FEE = 3000; // 0.3% in basis points
    uint256 public constant INITIAL_404_SUPPLY = 1000000e18;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MIN_RESOLUTION_TIME = 1 hours;
    uint256 public constant MAX_RESOLUTION_TIME = 365 days;
    
    address public owner;
    uint256 public deploymentNonce;
    bool public paused;
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Factory paused");
        _;
    }
    
    constructor(
        address _poolManager,
        address _basket,
        address payable _aux,
        address _settlement,
        address _rover,
        address _belgianHook
    ) {
        poolManager = IPoolManager(_poolManager);
        basket = Basket(_basket);
        aux = Aux(_aux);
        settlement = Settlement(_settlement);
        rover = Rover(_rover);
        belgianHook = Base(_belgianHook);
        owner = msg.sender;
        
        // Set factory in the hook
        belgianHook.setFactory(address(this));
    }
    
    // ============ Market Deployment Functions ============
    
    function deployStandardMarket(
        string memory question,
        uint256 resolutionTime,
        bool provideLiquidity
    ) external whenNotPaused returns (address marketAddress, address hookAddress) {
        _validateDeployment(question, resolutionTime);
        
        // Deploy new Safta market
        Safta newMarket = new Safta(
            _generateMarketName(question),
            _generateMarketSymbol(),
            18,
            INITIAL_404_SUPPLY,
            address(basket),
            payable(address(aux)),
            address(settlement),
            address(belgianHook),
            address(poolManager)
        );
        
        marketAddress = address(newMarket);
        hookAddress = address(belgianHook); // Use singleton hook
        
        // Create pool key
        PoolKey memory poolKey = _createPoolKey(marketAddress, address(basket), hookAddress);
        
        // Initialize liquidity if requested
        uint256 initialLiquidity = 0;
        if (provideLiquidity) {
            initialLiquidity = _provideInitialLiquidity(marketAddress);
        }
        
        // Initialize market with pool configuration
        newMarket.initializeMarket(
            question,
            resolutionTime,
            poolKey,
            initialLiquidity
        );
        
        // Register market
        _registerMarket(marketAddress, hookAddress, question, resolutionTime, "STANDARD");
        
        emit MarketDeployed(marketAddress, hookAddress, question, resolutionTime);
        
        return (marketAddress, hookAddress);
    }
    
    function deployCustomMarket(
        string memory question,
        uint256 resolutionTime,
        string memory name,
        string memory symbol,
        uint256 epochDuration,
        uint160 targetPrefix
    ) external whenNotPaused returns (address marketAddress, address hookAddress) {
        _validateDeployment(question, resolutionTime);
        require(epochDuration >= 1 minutes && epochDuration <= 7 days, "Invalid epoch");
        
        // Deploy custom hook if prefix specified
        if (targetPrefix > 0) {
            hookAddress = _deployCustomHook(targetPrefix);
            deployedHooks.push(hookAddress);
            emit HookDeployed(hookAddress, targetPrefix);
        } else {
            hookAddress = address(belgianHook);
        }
        
        // Deploy market with custom parameters
        Safta newMarket = new Safta(
            name,
            symbol,
            18,
            INITIAL_404_SUPPLY,
            address(basket),
            payable(address(aux)),
            address(settlement),
            hookAddress,
            address(poolManager)
        );
        
        marketAddress = address(newMarket);
        
        // Create pool key with custom settings
        PoolKey memory poolKey = _createPoolKey(marketAddress, address(basket), hookAddress);
        
        // Initialize with custom epoch duration
        newMarket.initializeMarket(
            question,
            resolutionTime,
            poolKey,
            0
        );
        
        // Set custom parameters in hook
        Base(hookAddress).initializeAuction(
            poolKey.toId(),
            block.timestamp,
            epochDuration,
            epochDuration / 4, // price epoch
            10000,  // starting tick
            -10000, // ending tick
            (resolutionTime - block.timestamp) / epochDuration, // total epochs
            INITIAL_404_SUPPLY / 2, // tokens to sell
            0,  // min proceeds
            type(uint256).max // max proceeds
        );
        
        _registerMarket(marketAddress, hookAddress, question, resolutionTime, "CUSTOM");
        
        bytes memory customParams = abi.encode(epochDuration, targetPrefix);
        emit CustomParametersSet(marketAddress, customParams);
        
        return (marketAddress, hookAddress);
    }
    
    function deploySimplePrediction(
        string memory question,
        uint256 daysUntilResolution
    ) external whenNotPaused returns (address) {
        uint256 resolutionTime = block.timestamp + (daysUntilResolution * 1 days);
        (address market, ) = this.deployStandardMarket(question, resolutionTime, true);
        return market;
    }
    
    function deployComplexMarket(
        string memory question,
        uint256 resolutionTime,
        bytes calldata hookConfig,
        bytes calldata marketConfig
    ) external whenNotPaused returns (address marketAddress, address hookAddress) {
        _validateDeployment(question, resolutionTime);
        
        // Decode configurations
        (uint256 epochDuration, uint160 targetPrefix, bool useCustomHook) = 
            abi.decode(hookConfig, (uint256, uint160, bool));
        
        (string memory name, string memory symbol, uint256 initialSupply, bool provideLiquidity) = 
            abi.decode(marketConfig, (string, string, uint256, bool));
        
        // Deploy hook if needed
        if (useCustomHook) {
            hookAddress = _deployCustomHook(targetPrefix);
        } else {
            hookAddress = address(belgianHook);
        }
        
        // Deploy market
        Safta newMarket = new Safta(
            name,
            symbol,
            18,
            initialSupply > 0 ? initialSupply : INITIAL_404_SUPPLY,
            address(basket),
            payable(address(aux)),
            address(settlement),
            hookAddress,
            address(poolManager)
        );
        
        marketAddress = address(newMarket);
        
        // Initialize
        PoolKey memory poolKey = _createPoolKey(marketAddress, address(basket), hookAddress);
        
        uint256 liquidity = provideLiquidity ? _provideInitialLiquidity(marketAddress) : 0;
        
        newMarket.initializeMarket(question, resolutionTime, poolKey, liquidity);
        
        _registerMarket(marketAddress, hookAddress, question, resolutionTime, "COMPLEX");
        
        return (marketAddress, hookAddress);
    }
    
    // ============ Helper Functions ============
    
    function _validateDeployment(string memory question, uint256 resolutionTime) internal view {
        require(bytes(question).length > 0, "Empty question");
        require(bytes(question).length <= 256, "Question too long");
        require(resolutionTime > block.timestamp + MIN_RESOLUTION_TIME, "Too soon");
        require(resolutionTime <= block.timestamp + MAX_RESOLUTION_TIME, "Too far");
    }
    
    function _createPoolKey(
        address token0,
        address token1,
        address hook
    ) internal pure returns (PoolKey memory) {
        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);
        
        // Ensure proper ordering
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
        
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: MARKET_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
    
    function _registerMarket(
        address marketAddress,
        address hookAddress,
        string memory question,
        uint256 resolutionTime,
        string memory marketType
    ) internal {
        markets.push(marketAddress);
        isValidMarket[marketAddress] = true;
        marketToHook[marketAddress] = hookAddress;
        marketIndex[marketAddress] = markets.length - 1;
        marketsByType[marketType].push(marketAddress);
        
        marketMetadata[marketAddress] = MarketMetadata({
            question: question,
            resolutionTime: resolutionTime,
            deployTime: block.timestamp,
            deployer: msg.sender,
            marketType: marketType,
            isActive: true,
            totalLiquidity: 0
        });
        
        // Register with hook
        PoolKey memory poolKey = _createPoolKey(marketAddress, address(basket), hookAddress);
        Base(hookAddress).registerMarket(poolKey.toId(), marketAddress);
        
        emit MarketRegistered(marketAddress);
        emit MarketTypeDeployed(marketType, marketAddress);
    }
    
    function _provideInitialLiquidity(address marketAddress) internal returns (uint256) {
        uint256 liquidity = basket.totalBalances(address(this));
        if (liquidity > 0) {
            basket.approve(marketAddress, liquidity);
            marketMetadata[marketAddress].totalLiquidity = liquidity;
            emit LiquidityProvided(marketAddress, liquidity);
        }
        return liquidity;
    }
    
    function _deployCustomHook(uint160 targetPrefix) internal returns (address) {
        bytes memory hookBytecode = type(Base).creationCode;
        bytes memory constructorArgs = abi.encode(
            poolManager,
            address(basket),
            address(rover),
            address(settlement)
        );
        
        return _deployWithPrefix(
            abi.encodePacked(hookBytecode, constructorArgs),
            targetPrefix
        );
    }
    
    function _deployWithPrefix(
        bytes memory bytecode,
        uint160 targetPrefix
    ) internal returns (address) {
        address deployed;
        uint256 salt = deploymentNonce;
        
        while (salt < deploymentNonce + 10000) {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    bytes1(0xff),
                    address(this),
                    salt,
                    keccak256(bytecode)
                )
            );
            
            if (uint160(uint256(hash)) >> 144 == targetPrefix) {
                assembly {
                    deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
                }
                deploymentNonce = salt + 1;
                break;
            }
            salt++;
        }
        
        require(deployed != address(0), "Prefix not found");
        return deployed;
    }
    
    function _generateMarketName(string memory question) internal pure returns (string memory) {
        bytes memory questionBytes = bytes(question);
        uint256 length = questionBytes.length > 20 ? 20 : questionBytes.length;
        bytes memory nameBytes = new bytes(length + 7);
        
        for (uint256 i = 0; i < 6; i++) {
            nameBytes[i] = bytes("SAFTA-")[i];
        }
        
        for (uint256 i = 0; i < length; i++) {
            nameBytes[i + 6] = questionBytes[i];
        }
        
        return string(nameBytes);
    }
    
    function _generateMarketSymbol() internal returns (string memory) {
        uint256 nonce = deploymentNonce++;
        return string(abi.encodePacked("SAFTA", _uint256ToString(nonce)));
    }
    
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    // ============ Admin Functions ============
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    function updateOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }
    
    function withdrawFees() external onlyOwner {
        uint256 balance = basket.totalBalances(address(this));
        if (balance > 0) {
            basket.transfer(owner, balance);
        }
    }
    
    function deactivateMarket(address market) external onlyOwner {
        require(isValidMarket[market], "Invalid market");
        marketMetadata[market].isActive = false;
    }
    
    // ============ View Functions ============
    
    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }
    
    function getMarket(uint256 index) external view returns (address) {
        return markets[index];
    }
    
    function getActiveMarkets() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            if (marketMetadata[markets[i]].isActive) {
                activeCount++;
            }
        }
        
        address[] memory activeMarkets = new address[](activeCount);
        uint256 j = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            if (marketMetadata[markets[i]].isActive) {
                activeMarkets[j++] = markets[i];
            }
        }
        
        return activeMarkets;
    }
    
    function getMarketsByType(string memory marketType) external view returns (address[] memory) {
        return marketsByType[marketType];
    }
    
    function getMarketMetadata(address market) external view returns (
        string memory question,
        uint256 resolutionTime,
        uint256 deployTime,
        address deployer,
        string memory marketType,
        bool isActive,
        uint256 totalLiquidity
    ) {
        MarketMetadata memory meta = marketMetadata[market];
        return (
            meta.question,
            meta.resolutionTime,
            meta.deployTime,
            meta.deployer,
            meta.marketType,
            meta.isActive,
            meta.totalLiquidity
        );
    }
    
    function getHookCount() external view returns (uint256) {
        return deployedHooks.length;
    }
    
    function getHook(uint256 index) external view returns (address) {
        return deployedHooks[index];
    }
    
    function getMarketHook(address market) external view returns (address) {
        return marketToHook[market];
    }
    
    function isMarketActive(address market) external view returns (bool) {
        return marketMetadata[market].isActive;
    }
    
    function getDeploymentNonce() external view returns (uint256) {
        return deploymentNonce;
    }
}