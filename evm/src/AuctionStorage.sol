// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/SortedSet.sol";

/**
 * @title AuctionStorage
 * @notice Storage layout for Auction contracts
 * @dev Separated to allow logic upgrades while maintaining state
 */
contract AuctionStorage {
    using SortedSetLib for SortedSetLib.Set;
    
    // ============ Structs ============
    
    struct CoreState {
        bool initialized;
        bool bettingWindowClosed;
        uint32 currentEpochIndex;
        uint32 nextBidId;
        uint32 participantCount;
        uint32 lastClearBlock;
        uint128 totalProtocolFees;
        uint128 totalGasCompensation;
        uint128 totalMarketDepth;
        uint128 dynamicBatchThreshold;
    }
    
    struct MarketState {
        bool marketInitialized;
        bool resolved;
        bool outcome;
        bool forceMajeurRefunds;
        bool requiresContent;
        uint8 contentSubmissionCount;
        uint32 disputeId;
        uint32 metaEvidenceId;
        uint32 minParticipants;
        uint128 totalYesShares;
        uint128 totalNoShares;
        uint resolutionTime;
        uint contentDeadline;
        string question;
    }
    
    struct AddressConfig {
        address settlementSystem;
        address auxSystem;
        address protocolTreasury;
        address rover;
        address basket;
    }
    
    struct MarketParams {
        string name;
        string symbol;
        uint32 auctionDuration;
        uint32 totalEpochs;
    }
    
    struct Bid {
        address bidder;
        uint usdAmount;
        uint pricePerShare;
        uint sharesRequested;
        uint sharesAllocated;
        uint96 epochIndex;
        uint timestamp;
        bool isYes;
        bool processed;
        bool minted;
    }
    
    struct Epoch {
        uint startTime;
        uint endTime;
        uint sharesAvailable;
        uint sharesAllocated;
        uint totalBids;
        uint totalGasCollected;
        bool cleared;
        address clearer;
        SortedSetLib.Set sortedBidIds;
        uint8 extensionCount;
    }
    
    struct Trade {
        address sender;
        uint amount;
        uint pricePerShare;
    }
    
    struct Batch {
        Trade[] trades;
        uint total;
    }
    
    struct State {
        CoreState core;
        MarketState market;
        AddressConfig addresses;
        MarketParams params;
        uint totalPoolUSD;
        
        // Mappings
        mapping(uint => Epoch) epochs;
        mapping(uint => Bid) allBids;
        mapping(address => uint[]) userBidIds;
        mapping(address => uint128) userYesShares;
        mapping(address => uint128) userNoShares;
        mapping(address => bool) hasParticipated;
        mapping(address => bool) authorizedContentSubmitters;
        mapping(uint => Batch) batchesYes;
        mapping(uint => Batch) batchesNo;
        
        address[] participants;
    }
    
    // ============ Storage ============
    
    State internal state;
}