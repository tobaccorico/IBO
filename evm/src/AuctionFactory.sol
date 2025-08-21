// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./Settlement.sol";
import "./AuctionFactoryLib.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AuctionFactory - Deploy Belgian Auctions for Social Betting
/// @notice Factory for deploying prediction markets using minimal proxy pattern
/// @dev All markets use shared infrastructure (Settlement, Rover, Aux, Basket)
contract AuctionFactory is Ownable {
    using Clones for address;
    
    // ============ Structs ============
    
    /// @dev Configuration for launching new markets
    struct LaunchConfig {
        string name;
        string symbol;
        uint initialPricePerToken;
        uint auctionDuration;
    }
    
    // ============ State Variables ============
    
    // Core infrastructure (shared across all markets)
    address public immutable auctionImplementation;
    Settlement public immutable settlementSystem;
    address public immutable rover;
    address public immutable aux;
    address public immutable basket;
    
    // Deployed auction tracking
    address[] public auctions;
    mapping(address => LaunchConfig) public configs;
    mapping(address => address[]) public creatorAuctions;
    mapping(address => bool) public isValidAuction;
    
    // Default values
    uint public defaultInitialPrice = 100e18;
    uint public defaultDuration = 24 hours;
    uint public protocolFeeRate = 250;
    address public protocolFeeRecipient;
    
    // ============ Events ============
    
    event AuctionDeployed(
        address indexed auction,
        address indexed creator,
        string name,
        bool isPrediction,
        string question
    );
    
    event DefaultsUpdated(uint initialPrice, uint duration);
    event ProtocolFeeUpdated(uint rate, address recipient);
    
    // ============ Constructor ============
    
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
        
        // Deploy implementation once
        auctionImplementation = address(new Auction());
    }
    
    // ============ Market Deployment ============

    function deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        LaunchConfig memory config
    ) external returns (address) {
        return _deployPredictionMarket(question, resolutionTime, config);
    }
    
    function _deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        LaunchConfig memory config
    ) internal returns (address) {
        require(bytes(question).length > 0, "Empty question");
        
        // Apply defaults
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        
        require(resolutionTime > block.timestamp + config.auctionDuration, "Invalid resolution time");
        
        // Deploy clone
        address clone = auctionImplementation.clone();
        
        // Initialize using library
        AuctionFactoryLib.initializeAuction(
            clone,
            config.name,
            config.symbol,
            config.auctionDuration,
            protocolFeeRecipient,
            address(settlementSystem),
            rover,
            aux,
            basket
        );
        
        // Initialize prediction market using library
        AuctionFactoryLib.initializePredictionMarket(
            clone,
            question,
            resolutionTime,
            address(settlementSystem),
            false,
            0,
            0
        );
        
        // Register and track
        _registerAuction(clone, config);
        
        emit AuctionDeployed(clone, msg.sender, config.name, true, question);
        
        return clone;
    }
    
    function deployRapBattleMarket(
        string memory challenger,
        string memory challenged,
        uint responseDeadline,
        LaunchConfig memory config
    ) external returns (address) {
        require(responseDeadline > block.timestamp, "Invalid response deadline");
        require(bytes(challenger).length > 0 && bytes(challenged).length > 0, "Empty names");
        
        string memory question = string(abi.encodePacked(
            "Rap Battle: ",
            challenger,
            " vs ",
            challenged
        ));
        
        uint resolutionTime = responseDeadline + 7 days;
        
        // Apply defaults
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        
        // Deploy clone
        address clone = auctionImplementation.clone();
        
        // Initialize using library
        AuctionFactoryLib.initializeAuction(
            clone,
            string(abi.encodePacked("D: ", _substring(challenger, 0, 10), " vs ", _substring(challenged, 0, 10))),
            "D",
            config.auctionDuration,
            protocolFeeRecipient,
            address(settlementSystem),
            rover,
            aux,
            basket
        );
        
        // Create meta evidence using library
        uint metaEvidenceId = AuctionFactoryLib.createRapBattleMetaEvidence(
            address(settlementSystem),
            challenger,
            challenged,
            question
        );
        
        // Initialize as content-required prediction market
        Auction(payable(clone)).initializePredictionMarket(
            question,
            resolutionTime,
            metaEvidenceId,
            true,
            responseDeadline,
            2
        );
        
        // Set authorized content submitters
        Auction(payable(clone)).setAuthorizedSubmitters(
            msg.sender,
            address(0)
        );
        
        // Register and track
        _registerAuction(clone, config);
        
        emit AuctionDeployed(clone, msg.sender, config.name, true, question);
        
        return clone;
    }
    
    function deploySimplePrediction(
        string memory question,
        uint daysUntilResolution
    ) external returns (address) {
        require(daysUntilResolution >= 1 && daysUntilResolution <= 365, "Invalid duration");
        
        LaunchConfig memory config = LaunchConfig({
            name: string(abi.encodePacked("Q: ", _substring(question, 0, 20))),
            symbol: "Q",
            initialPricePerToken: defaultInitialPrice,
            auctionDuration: defaultDuration
        });
        
        uint resolutionTime = block.timestamp + (daysUntilResolution * 1 days);
        
        return _deployPredictionMarket(question, resolutionTime, config);
    }
    
    // ============ Internal Functions ============
    
    function _registerAuction(address clone, LaunchConfig memory config) internal {
        auctions.push(clone);
        configs[clone] = config;
        creatorAuctions[msg.sender].push(clone);
        isValidAuction[clone] = true;
    }
    
    function _substring(string memory str, uint start, uint end) internal pure returns (string memory) {
        return AuctionFactoryLib.substring(str, start, end);
    }
    
    // ============ View Functions ============
    
    function getAuctions() external view returns (address[] memory) {
        return auctions;
    }
    
    function getAuctionsByCreator(address creator) external view returns (address[] memory) {
        return creatorAuctions[creator];
    }
    
    function getAuctionInfo(address auction) external view returns (
        LaunchConfig memory config,
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
        
        isPrediction = true;
        
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
        address _settlement,
        address _rover,
        address _aux,
        address _basket
    ) {
        return (
            address(settlementSystem),
            rover,
            aux,
            basket
        );
    }
    
    // ============ Admin Functions ============
    
    function setDefaults(uint _initialPrice, uint _duration) external onlyOwner {
        require(_initialPrice >= 1e18, "Price too low");
        require(_duration >= 1 hours, "Duration too short");
        require(_duration <= 7 days, "Duration too long");
        
        defaultInitialPrice = _initialPrice;
        defaultDuration = _duration;
        
        emit DefaultsUpdated(_initialPrice, _duration);
    }
    
    function setProtocolFee(uint _rate, address _recipient) external onlyOwner {
        require(_rate <= 1000, "Fee too high");
        require(_recipient != address(0), "Invalid recipient");
        
        protocolFeeRate = _rate;
        protocolFeeRecipient = _recipient;
        
        emit ProtocolFeeUpdated(_rate, _recipient);
    }
}