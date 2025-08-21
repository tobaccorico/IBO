// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./Settlement.sol";

/// @title AuctionFactoryLib - Helper library to reduce AuctionFactory size
/// @notice Extracts market creation logic to reduce contract size
library AuctionFactoryLib {
    
    /// @notice Initialize auction with core parameters
    /// @param clone Address of the cloned auction
    /// @param name Market name
    /// @param symbol Market symbol
    /// @param auctionDuration Duration of auction
    /// @param owner Owner address
    /// @param settlementSystem Settlement contract address
    /// @param rover Rover contract address
    /// @param aux Aux contract address
    /// @param basket Basket contract address
    function initializeAuction(
        address clone,
        string memory name,
        string memory symbol,
        uint auctionDuration,
        address owner,
        address settlementSystem,
        address rover,
        address aux,
        address basket
    ) external {
        uint totalEpochs = auctionDuration / 1 hours;
        require(totalEpochs > 0, "Duration too short");
        
        // FIXED: Use uint instead of uint128 to match Auction.sol expectations
        Auction.AuctionParams memory params = Auction.AuctionParams({
            name: name,
            symbol: symbol,
            auctionDuration: auctionDuration,    // FIXED: uint instead of uint128
            totalEpochs: totalEpochs,            // FIXED: uint instead of uint128
            owner: owner,
            settlementSystem: settlementSystem,
            rover: rover,
            aux: aux,
            basket: basket
        });
        
        Auction(payable(clone)).initialize(params);
    }
    
    /// @notice Initialize prediction market parameters
    /// @param clone Address of the cloned auction
    /// @param question Prediction question
    /// @param resolutionTime When outcome can be determined
    /// @param settlementSystem Settlement contract for meta evidence
    /// @param requiresContent Whether content submission is required
    /// @param contentDeadline Deadline for content submission
    /// @param minParticipants Minimum participants required
    function initializePredictionMarket(
        address clone,
        string memory question,
        uint resolutionTime,
        address settlementSystem,
        bool requiresContent,
        uint contentDeadline,
        uint minParticipants
    ) external {
        uint metaEvidenceId = Settlement(settlementSystem).createPredictionMarketMetaEvidence();
        
        Auction(payable(clone)).initializePredictionMarket(
            question,
            resolutionTime,
            metaEvidenceId,
            requiresContent,
            contentDeadline,
            minParticipants
        );
    }
    
    /// @notice Create meta evidence for rap battles
    /// @param settlementSystem Settlement contract address
    /// @param challenger Name of challenger
    /// @param challenged Name of challenged person
    /// @param question Full question text
    /// @return metaEvidenceId Created meta evidence ID
    function createRapBattleMetaEvidence(
        address settlementSystem,
        string memory challenger,
        string memory challenged,
        string memory question
    ) external returns (uint metaEvidenceId) {
        string memory rulingOptions = string(abi.encodePacked(
            '[{"title":"',
            challenger,
            ' wins"},{"title":"',
            challenged,
            ' wins"},{"title":"Draw/Cancel"}]'
        ));
        
        metaEvidenceId = Settlement(settlementSystem).createMetaEvidence(
            "Rap Battle Resolution",
            "Community voting on rap battle winner based on submitted content",
            question,
            rulingOptions,
            "ipfs://QmRapBattleRules"
        );
    }
    
    /// @notice Extract substring helper
    /// @param str Source string
    /// @param start Starting index
    /// @param end Ending index (exclusive)
    /// @return Substring result
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