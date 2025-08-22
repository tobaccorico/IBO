// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./Settlement.sol";
import "./AuctionFactoryLib.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AuctionFactory - Deploy Belgian Auctions for Social Betting
contract AuctionFactory is Ownable {
    
    // Core infrastructure
    address public immutable auctionImplementation;
    Settlement public immutable settlementSystem;
    address public immutable rover;
    address public immutable aux;
    address public immutable basket;
    
    // Tracking
    address[] public auctions;
    mapping(address => AuctionFactoryLib.LaunchConfig) public configs;
    mapping(address => address[]) public creatorAuctions;
    mapping(address => bool) public isValidAuction;
    
    // Settings
    uint public defaultInitialPrice = 100e18;
    uint public defaultDuration = 24 hours;
    uint public protocolFeeRate = 250;
    address public protocolFeeRecipient;
    
    event AuctionDeployed(
        address indexed auction,
        address indexed creator,
        string name,
        bool isPrediction,
        string question
    );
    
    event DefaultsUpdated(uint initialPrice, uint duration);
    event ProtocolFeeUpdated(uint rate, address recipient);
    
    constructor(
        address _settlementSystem,
        address _rover,
        address _aux,
        address _basket
    ) Ownable(msg.sender) {
        require(_settlementSystem != address(0), "Invalid settlement");
        require(_rover != address(0), "Invalid rover");
        require(_aux != address(0), "Invalid aux");
        require(_basket != address(0), "Invalid basket");
        
        settlementSystem = Settlement(_settlementSystem);
        rover = _rover;
        aux = _aux;
        basket = _basket;
        protocolFeeRecipient = msg.sender;
        auctionImplementation = address(new Auction());
    }
    
    function deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        AuctionFactoryLib.LaunchConfig memory config
    ) external returns (address) {
        require(bytes(question).length > 0, "Empty question");
        
        // Apply defaults
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        
        require(resolutionTime > block.timestamp + config.auctionDuration, "Invalid resolution time");
        
        // Deploy market
        address market = AuctionFactoryLib.deployMarket(
            auctionImplementation,
            config,
            [address(settlementSystem), rover, aux, basket],
            protocolFeeRecipient
        );
        
        // Setup prediction
        AuctionFactoryLib.setupPrediction(
            market,
            address(settlementSystem),
            question,
            resolutionTime,
            false,
            0
        );
        
        // Register
        _registerAuction(market, config);
        
        emit AuctionDeployed(market, msg.sender, config.name, true, question);
        return market;
    }
    
    function deployRapBattleMarket(
        string memory challenger,
        string memory challenged,
        uint responseDeadline,
        AuctionFactoryLib.LaunchConfig memory config
    ) external returns (address) {
        require(responseDeadline > block.timestamp, "Invalid response deadline");
        require(bytes(challenger).length > 0 && bytes(challenged).length > 0, "Empty names");
        
        string memory question = string(abi.encodePacked(
            "Rap Battle: ", challenger, " vs ", challenged
        ));
        
        uint resolutionTime = responseDeadline + 7 days;
        
        // Apply defaults and update name if needed
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        if (bytes(config.name).length == 0) {
            config.name = string(abi.encodePacked(
                "D: ", 
                AuctionFactoryLib.substring(challenger, 0, 10), 
                " vs ", 
                AuctionFactoryLib.substring(challenged, 0, 10)
            ));
        }
        if (bytes(config.symbol).length == 0) {
            config.symbol = "D";
        }
        
        // Deploy market
        address market = AuctionFactoryLib.deployMarket(
            auctionImplementation,
            config,
            [address(settlementSystem), rover, aux, basket],
            protocolFeeRecipient
        );
        
        // Setup as content-required prediction
        AuctionFactoryLib.setupPrediction(
            market,
            address(settlementSystem),
            question,
            resolutionTime,
            true,
            responseDeadline
        );
        
        // Set authorized submitters
        Auction(payable(market)).setAuthorizedSubmitters(msg.sender, address(0));
        
        // Register
        _registerAuction(market, config);
        
        emit AuctionDeployed(market, msg.sender, config.name, true, question);
        return market;
    }
    
    function deploySimplePrediction(
        string memory question,
        uint daysUntilResolution
    ) external returns (address) {
        require(daysUntilResolution >= 1 && daysUntilResolution <= 365, "Invalid duration");
        
        AuctionFactoryLib.LaunchConfig memory config = AuctionFactoryLib.LaunchConfig({
            name: string(abi.encodePacked("Q: ", AuctionFactoryLib.substring(question, 0, 20))),
            symbol: "Q",
            initialPricePerToken: defaultInitialPrice,
            auctionDuration: defaultDuration
        });
        
        uint resolutionTime = block.timestamp + (daysUntilResolution * 1 days);
        
        // Inline the logic instead of calling deployPredictionMarket
        require(bytes(question).length > 0, "Empty question");
        
        // Deploy market
        address market = AuctionFactoryLib.deployMarket(
            auctionImplementation,
            config,
            [address(settlementSystem), rover, aux, basket],
            protocolFeeRecipient
        );
        
        // Setup prediction
        AuctionFactoryLib.setupPrediction(
            market,
            address(settlementSystem),
            question,
            resolutionTime,
            false,
            0
        );
        
        // Register
        _registerAuction(market, config);
        
        emit AuctionDeployed(market, msg.sender, config.name, true, question);
        return market;
    }

    function _registerAuction(address auction, AuctionFactoryLib.LaunchConfig memory config) internal {
        auctions.push(auction);
        configs[auction] = config;
        creatorAuctions[msg.sender].push(auction);
        isValidAuction[auction] = true;
    }
    
    // View functions
    function getAuctions() external view returns (address[] memory) {
        return auctions;
    }
    
    function getAuctionsByCreator(address creator) external view returns (address[] memory) {
        return creatorAuctions[creator];
    }
    
    function getAuctionInfo(address auction) external view returns (
        AuctionFactoryLib.LaunchConfig memory config,
        bool isPrediction,
        string memory question,
        uint currentPrice,
        uint totalPoolUSD,
        bool isActive,
        bool isResolved
    ) {
        require(isValidAuction[auction], "Invalid auction");
        
        config = configs[auction];
        Auction auctionContract = Auction(payable(auction));
        
        isPrediction = true; // All our markets are predictions
        
        // Get prediction market details
        (
            question,
            ,
            ,
            totalPoolUSD,
            ,
            isResolved,
        ) = auctionContract.getPredictionSummary();
        
        // Get current epoch info
        (
            ,
            currentPrice,
            ,
            ,
            isActive
        ) = auctionContract.getCurrentEpochInfo();
    }
    
    function getInfrastructure() external view returns (
        address _implementation,
        address _settlement,
        address _rover,
        address _aux,
        address _basket
    ) {
        return (
            auctionImplementation,
            address(settlementSystem),
            rover,
            aux,
            basket
        );
    }
    
    // Admin functions
    function setDefaults(uint _initialPrice, uint _duration) external onlyOwner {
        require(_initialPrice >= 1e18, "Price too low");
        require(_duration >= 1 hours, "Duration too short");
        require(_duration <= 7 days, "Duration too long");
        
        defaultInitialPrice = _initialPrice;
        defaultDuration = _duration;
        
        emit DefaultsUpdated(_initialPrice, _duration);
    }
    
    function setProtocolFee(uint _rate, address _recipient) external onlyOwner {
        require(_rate <= 1000, "Fee too high"); // Max 10%
        require(_recipient != address(0), "Invalid recipient");
        
        protocolFeeRate = _rate;
        protocolFeeRecipient = _recipient;
        
        emit ProtocolFeeUpdated(_rate, _recipient);
    }
}