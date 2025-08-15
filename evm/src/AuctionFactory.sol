// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./Settlement.sol";
import "./Rover.sol";
import "./Aux.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AuctionFactory - Deploy Belgian Auctions for Social Betting
/// @notice Factory for deploying prediction markets using minimal proxy pattern
/// @dev All markets use shared infrastructure (Settlement, Rover, Aux, Basket)
contract AuctionFactory is Ownable {
    using Clones for address;
    
    // ============ Structs ============
    
    struct LaunchConfig {
        string name;
        string symbol;
        uint initialPricePerToken;   // Starting price in USD (e.g., $100)
        uint auctionDuration;        // Betting window duration (e.g., 24 hours)
    }
    
    // ============ State Variables ============
    
    // Core infrastructure (shared across all markets)
    address public immutable auctionImplementation;
    Settlement public immutable settlementSystem;
    Rover public immutable rover;
    Aux public aux;  // Changed from immutable to allow casting
    Basket public immutable basket;
    
    // Deployed auction tracking
    address[] public auctions;
    mapping(address => LaunchConfig) public configs;
    mapping(address => address[]) public creatorAuctions;
    mapping(address => bool) public isValidAuction;
    
    // Default values
    uint public defaultInitialPrice = 100e18;  // $100 starting price
    uint public defaultDuration = 24 hours;    // 24-hour betting window
    uint public protocolFeeRate = 250;         // 2.5% in basis points
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
        rover = Rover(_rover);
        aux = Aux(payable(_aux));
        basket = Basket(_basket);
        protocolFeeRecipient = msg.sender;
        
        // Deploy implementation once
        auctionImplementation = address(new Auction());
    }
    
    // ============ Prediction Market Deployment ============

    function deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        LaunchConfig memory config
    ) external returns (address) {
        return _deployPredictionMarket(question, resolutionTime, config);
    }
    
    /// @notice Deploy standard prediction market
    /// @param question The prediction question
    /// @param resolutionTime When the outcome can be determined
    /// @param config Auction configuration (price, duration, etc.)
    function _deployPredictionMarket(
        string memory question,
        uint resolutionTime,
        LaunchConfig memory config
    ) internal returns (address) {
        require(bytes(question).length > 0, "Empty question");
        
        // Apply defaults if not specified
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        
        require(resolutionTime > block.timestamp + config.auctionDuration, "Invalid resolution time");
        
        // Deploy clone
        address clone = auctionImplementation.clone();
        
        // Calculate total epochs (1 hour each)
        uint totalEpochs = config.auctionDuration / 1 hours;
        require(totalEpochs > 0, "Duration too short");
        
        // Initialize clone
        Auction.AuctionParams memory params = Auction.AuctionParams({
            name: config.name,
            symbol: config.symbol,
            auctionDuration: config.auctionDuration,
            totalEpochs: totalEpochs,
            owner: protocolFeeRecipient,  // Pass protocol fee recipient as owner
            settlementSystem: address(settlementSystem),
            rover: address(rover),
            aux: address(aux),
            basket: address(basket)
        });
        
        Auction(payable(clone)).initialize(params);
        
        // Create meta-evidence for this type of market
        uint metaEvidenceId = settlementSystem.createPredictionMarketMetaEvidence();
        
        // Initialize as prediction market
        Auction(payable(clone)).initializePredictionMarket(
            question,
            resolutionTime,
            metaEvidenceId,
            false,  // requiresContent
            0,      // contentDeadline  
            0       // minParticipants
        );
        
        // Register and track
        _registerAuction(clone, config);
        
        emit AuctionDeployed(clone, msg.sender, config.name, true, question);
        
        return clone;
    }
    
    /// @notice Deploy rap battle prediction market (requires content submission)
    /// @param challenger Name/address of challenger
    /// @param challenged Name/address of person being challenged
    /// @param responseDeadline Deadline for challenged person to respond with content
    /// @param config Auction configuration
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
        
        uint resolutionTime = responseDeadline + 7 days; // 7 days for voting after content
        
        // Apply defaults
        if (config.initialPricePerToken == 0) {
            config.initialPricePerToken = defaultInitialPrice;
        }
        if (config.auctionDuration == 0) {
            config.auctionDuration = defaultDuration;
        }
        
        // Deploy clone
        address clone = auctionImplementation.clone();
        
        uint totalEpochs = config.auctionDuration / 1 hours;
        require(totalEpochs > 0, "Duration too short");
        
        // Initialize clone
        Auction.AuctionParams memory params = Auction.AuctionParams({
            name: string(abi.encodePacked("D: ", _substring(challenger, 0, 10), " vs ", _substring(challenged, 0, 10))),
            symbol: "D",
            auctionDuration: config.auctionDuration,
            totalEpochs: totalEpochs,
            owner: protocolFeeRecipient,  // Pass protocol fee recipient as owner
            settlementSystem: address(settlementSystem),
            rover: address(rover),
            aux: address(aux),
            basket: address(basket)
        });
        
        Auction(payable(clone)).initialize(params);
        
        // Create custom meta-evidence for rap battles
        string memory rulingOptions = string(abi.encodePacked(
            '[{"title":"',
            challenger,
            ' wins"},{"title":"',
            challenged,
            ' wins"},{"title":"Draw/Cancel"}]'
        ));
        
        uint metaEvidenceId = settlementSystem.createMetaEvidence(
            "Rap Battle Resolution",
            "Community voting on rap battle winner based on submitted content",
            question,
            rulingOptions,
            "ipfs://QmRapBattleRules"
        );
        
        // Initialize as content-required prediction market
        Auction(payable(clone)).initializePredictionMarket(
            question,
            resolutionTime,
            metaEvidenceId,
            true,              // requiresContent
            responseDeadline,  // contentDeadline
            2                  // minParticipants (both must submit)
        );
        
        // Set authorized content submitters
        // In a real implementation, these would be verified addresses
        Auction(payable(clone)).setAuthorizedSubmitters(
            msg.sender,        // Challenger is deployer
            address(0)         // Challenged address to be set later
        );
        
        // Register and track
        _registerAuction(clone, config);
        
        emit AuctionDeployed(clone, msg.sender, config.name, true, question);
        
        return clone;
    }
    
    /// @notice Deploy simple prediction market with basic question
    /// @param question Simple yes/no question
    /// @param daysUntilResolution How many days until outcome can be determined
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
    
    /// @notice Register auction with all systems
    function _registerAuction(address clone, LaunchConfig memory config) internal {
        // Track auction
        auctions.push(clone);
        configs[clone] = config;
        creatorAuctions[msg.sender].push(clone);
        isValidAuction[clone] = true;
        
        // Protocol treasury is set during initialization in Auction contract
        // The protocolFeeRecipient is passed as the owner parameter
    }
    
    /// @notice Extract substring for naming
    function _substring(string memory str, uint start, uint end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end > strBytes.length) end = strBytes.length;
        if (start >= end) return "";
        
        bytes memory result = new bytes(end - start);
        for (uint i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }
    
    // ============ View Functions ============
    
    /// @notice Get all deployed auctions
    function getAuctions() external view returns (address[] memory) {
        return auctions;
    }
    
    /// @notice Get auctions created by specific address
    function getAuctionsByCreator(address creator) external view returns (address[] memory) {
        return creatorAuctions[creator];
    }
    
    /// @notice Get detailed auction information
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
        
        isPrediction = true; // All our auctions are prediction markets
        
        // Get prediction market details
        (
            question,
            ,  // totalYesShares
            ,  // totalNoShares
            totalPoolUSD,
            ,  // impliedProbability
            isResolved,
            // outcome
        ) = auctionContract.getPredictionSummary();
        
        // Get current epoch info
        (
            ,  // index
            currentPrice,
            ,  // timeRemaining
            ,  // bidCount
            isActive
        ) = auctionContract.getCurrentEpochInfo();
    }
    
    /// @notice Get infrastructure addresses
    function getInfrastructure() external view returns (
        address _settlement,
        address _rover,
        address _aux,
        address _basket
    ) {
        return (
            address(settlementSystem),
            address(rover),
            address(aux),
            address(basket)
        );
    }
    
    // ============ Admin Functions ============
    
    /// @notice Update default values
    function setDefaults(uint _initialPrice, uint _duration) external onlyOwner {
        require(_initialPrice >= 1e18, "Price too low");  // Min $1
        require(_duration >= 1 hours, "Duration too short");
        require(_duration <= 7 days, "Duration too long");
        
        defaultInitialPrice = _initialPrice;
        defaultDuration = _duration;
        
        emit DefaultsUpdated(_initialPrice, _duration);
    }
    
    /// @notice Update protocol fee
    function setProtocolFee(uint _rate, address _recipient) external onlyOwner {
        require(_rate <= 1000, "Fee too high"); // Max 10%
        require(_recipient != address(0), "Invalid recipient");
        
        protocolFeeRate = _rate;
        protocolFeeRecipient = _recipient;
        
        emit ProtocolFeeUpdated(_rate, _recipient);
    }
}