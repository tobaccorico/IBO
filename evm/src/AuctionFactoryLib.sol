// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./AuctionLogic.sol";
import "./Settlement.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/// @title AuctionFactoryLib - Deployment logic for Factory
library AuctionFactoryLib {
    using Clones for address;
    
    struct LaunchConfig {
        string name;
        string symbol;
        uint initialPricePerToken;
        uint auctionDuration;
    }
    
    /// @notice Deploy and initialize a new auction market
    function deployMarket(
        address implementation,
        LaunchConfig memory config,
        address[4] memory infrastructure, // [settlement, rover, aux, basket]
        address protocolTreasury
    ) external returns (address clone) {
        // Deploy clone
        clone = implementation.clone();
        
        // Initialize
        uint32 totalEpochs = uint32(config.auctionDuration / 1 hours);
        require(totalEpochs > 0, "Duration too short");
        
        AuctionLogic.InitParams memory params = AuctionLogic.InitParams({
            name: config.name,
            symbol: config.symbol,
            auctionDuration: uint32(config.auctionDuration),
            totalEpochs: totalEpochs,
            owner: protocolTreasury,
            settlementSystem: infrastructure[0],
            rover: infrastructure[1],
            aux: infrastructure[2],
            basket: infrastructure[3]
        });
        
        Auction(payable(clone)).initialize(params);
    }
    
    /// @notice Setup prediction market parameters
    function setupPrediction(
        address market,
        address settlement,
        string memory question,
        uint resolutionTime,
        bool requiresContent,
        uint contentDeadline
    ) external {
        uint metaEvidenceId;
        
        if (requiresContent) {
            // For rap battles, create custom meta evidence
            metaEvidenceId = createRapBattleMetaEvidence(settlement, question);
        } else {
            // For standard predictions, use default meta evidence
            metaEvidenceId = Settlement(settlement).createPredictionMarketMetaEvidence();
        }
        
        Auction(payable(market)).initializePredictionMarket(
            question,
            resolutionTime,
            metaEvidenceId,
            requiresContent,
            contentDeadline,
            2 // minParticipants
        );
    }
    
    /// @notice Create rap battle specific meta evidence
    function createRapBattleMetaEvidence(
        address settlement,
        string memory question
    ) internal returns (uint) {
        // Extract challenger and challenged from question for better ruling options
        bytes memory questionBytes = bytes(question);
        uint vsIndex = findVsIndex(questionBytes);
        
        string memory rulingOptions;
        if (vsIndex > 0) {
            // Found " vs ", extract names
            string memory challenger = extractName(questionBytes, 12, vsIndex); // Skip "Rap Battle: "
            string memory challenged = extractName(questionBytes, vsIndex + 4, questionBytes.length);
            
            rulingOptions = string(abi.encodePacked(
                '[{"title":"',
                challenger,
                ' wins"},{"title":"',
                challenged,
                ' wins"},{"title":"Draw/Cancel"}]'
            ));
        } else {
            // Fallback if parsing fails
            rulingOptions = '[{"title":"Challenger wins"},{"title":"Challenged wins"},{"title":"Draw/Cancel"}]';
        }
        
        return Settlement(settlement).createMetaEvidence(
            "Rap Battle Resolution",
            "Community voting on rap battle winner based on submitted content",
            question,
            rulingOptions,
            "ipfs://QmRapBattleRules"
        );
    }
    
    /// @notice Find " vs " in bytes
    function findVsIndex(bytes memory data) internal pure returns (uint) {
        if (data.length < 4) return 0;
        
        for (uint i = 0; i < data.length - 3; i++) {
            if (data[i] == 0x20 && // space
                data[i+1] == 0x76 && // v
                data[i+2] == 0x73 && // s
                data[i+3] == 0x20) { // space
                return i;
            }
        }
        return 0;
    }
    
    /// @notice Extract name from bytes
    function extractName(bytes memory data, uint start, uint end) internal pure returns (string memory) {
        if (start >= end || start >= data.length) return "";
        if (end > data.length) end = data.length;
        
        bytes memory result = new bytes(end - start);
        for (uint i = start; i < end; i++) {
            result[i - start] = data[i];
        }
        return string(result);
    }
    
    /// @notice Extract substring helper
    function substring(string memory str, uint start, uint end) external pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end > strBytes.length) end = strBytes.length;
        if (start >= end) return "";
        
        bytes memory result = new bytes(end - start);
        for (uint i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }
}