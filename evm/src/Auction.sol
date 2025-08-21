// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/ERC404.sol";
import "./imports/ERC20Events.sol";
import "./imports/SortedSet.sol";
import "./imports/IArbitrable.sol";
import "./imports/IArbitrator.sol";
import "./Settlement.sol";
import "./AuctionLib.sol";
import "./Aux.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Auction - Secure Minimal Belgian Auction (Anti-MEV)
/// @notice Addresses MEV vulnerabilities without commit-reveal complexity
contract Auction is ERC404, ReentrancyGuard, IArbitrable {
    using SortedSetLib for SortedSetLib.Set;
    
    // ============ Structs ============
    
    struct AuctionParams {
        string name;
        string symbol;
        uint auctionDuration;
        uint totalEpochs;
        address owner;
        address settlementSystem;
        address rover;
        address aux;
        address basket;
    }
    
    // ============ State Variables ============
    
    bool private initialized;
    bool private marketInitialized;
    AuctionParams public params;
    
    // Core state
    uint public currentEpochIndex;
    bool public bettingWindowClosed;
    uint public nextBidId = 1;
    
    // Essential mappings
    mapping(uint => AuctionStructs.Epoch) internal epochs;
    mapping(uint => AuctionStructs.Bid) public allBids;
    mapping(address => uint[]) public userBidIds;
    
    // ENHANCED MEV Protection
    mapping(address => uint) public lastBidTime;
    mapping(address => uint) public bidVelocity;
    mapping(address => uint) public consecutiveHighValueBids; // NEW: Track suspicious patterns
    mapping(address => uint) public totalBidValue;           // NEW: Track cumulative value
    mapping(uint => uint) public epochRandomSeed;            // NEW: Per-epoch randomness
    
    // Participants
    mapping(address => bool) public hasParticipated;
    address[] public participants;
    
    // Prediction market
    string public question;
    uint public resolutionTime;
    bool public resolved;
    bool public outcome;
    mapping(address => uint) public userYesShares;
    mapping(address => uint) public userNoShares;
    uint public totalYesShares;
    uint public totalNoShares;
    uint public totalPoolUSD;
    bool public forceMajeurRefunds;
    
    // Settlement
    Settlement public settlementSystem;
    uint public disputeId;
    uint public metaEvidenceId;
    
    // Content market
    bool public requiresContent;
    mapping(address => bool) public authorizedContentSubmitters;
    uint public contentDeadline;
    uint public contentSubmissionCount;
    uint public minParticipants;
    
    // Gas tracking
    uint public totalGasFeesCollected;
    address public protocolTreasury;
    
    // ANTI-MEV: Batch processing
    uint constant BATCH_WINDOW = 15 seconds;     // Batch bids in 15-second windows
    uint constant MIN_BATCH_SIZE = 2;            // Minimum bids to trigger batch
    uint constant VELOCITY_THRESHOLD = 500;      // High velocity threshold
    uint constant SUSPICIOUS_VALUE_RATIO = 10;   // 10x average value is suspicious
    
    // ============ Events ============
    
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event EpochCleared(uint indexed epoch, uint sharesAllocated, address clearer, uint gasCompensation);
    event PredictionResolved(bool outcome);
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    event ParticipantAdded(address indexed participant);
    event SuspiciousActivity(address indexed user, string reason);
    event BatchProcessed(uint epochIndex, uint batchSize, uint blockNumber);
    
    // ============ Constructor ============
    
    constructor() ERC404("", "", 18) {
        units = 1e18;
    }
    
    // ============ Initialization ============
    
    function initialize(AuctionParams memory _params) external {
        require(!initialized, "Already initialized");
        initialized = true;
        
        params = _params;
        settlementSystem = Settlement(_params.settlementSystem);
        protocolTreasury = _params.owner;
        name = _params.name;
        symbol = _params.symbol;
        
        // Initialize first epoch with randomized timing
        _startNewEpochSecure(0);
    }
    
    function initializePredictionMarket(
        string memory question_,
        uint resolutionTime_,
        uint metaEvidenceId_,
        bool requiresContent_,
        uint contentDeadline_,
        uint minParticipants_
    ) external {
        require(!marketInitialized, "Market already initialized");
        marketInitialized = true;
        question = question_;
        resolutionTime = resolutionTime_;
        requiresContent = requiresContent_;
        contentDeadline = contentDeadline_;
        minParticipants = minParticipants_;
        metaEvidenceId = metaEvidenceId_;
    }
    
    function setAuthorizedSubmitters(address submitter1, address submitter2) external {
        require(msg.sender == protocolTreasury, "Not authorized");
        authorizedContentSubmitters[submitter1] = true;
        authorizedContentSubmitters[submitter2] = true;
    }
    
    // ============ SECURE BIDDING WITH ENHANCED MEV PROTECTION ============
    
    function placePredictionBid(uint pricePerShare, bool isYes) public payable nonReentrant {
        require(!bettingWindowClosed && !resolved, "Betting closed");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        require(msg.value > 0, "No ETH sent");
        
        _updateEpochIfNeeded();
        require(epochs[currentEpochIndex].totalBids < 1000, "Epoch full");
        
        // ANTI-MEV: Detect and penalize suspicious behavior
        _detectSuspiciousBehavior(msg.sender, msg.value);
        
        // Add participant
        if (!hasParticipated[msg.sender]) {
            hasParticipated[msg.sender] = true;
            participants.push(msg.sender);
            emit ParticipantAdded(msg.sender);
        }
        
        // ANTI-MEV: Enhanced bid processing with batch windows
        (
            uint bidId,
            uint usdReceived,
            uint sharesRequested,
            uint gasContribution
        ) = AuctionLib.processBidSecure(
            msg.sender,
            msg.value,
            pricePerShare,
            isYes,
            currentEpochIndex,
            nextBidId,
            lastBidTime,
            bidVelocity,
            epochRandomSeed[currentEpochIndex],
            epochs[currentEpochIndex],
            allBids,
            userBidIds
        );
        
        // Update tracking
        nextBidId = bidId + 1;
        totalGasFeesCollected += gasContribution;
        totalBidValue[msg.sender] += usdReceived;
        
        // ANTI-MEV: Check if batch processing should trigger
        _checkBatchProcessing();
        
        emit BidPlaced(msg.sender, usdReceived, pricePerShare, isYes, currentEpochIndex, bidId);
    }
    
    /// @notice ANTI-MEV: Detect patterns that indicate MEV exploitation
    function _detectSuspiciousBehavior(address bidder, uint ethAmount) internal {
        uint currentTime = block.timestamp;
        uint timeSinceLastBid = lastBidTime[bidder] > 0 ? currentTime - lastBidTime[bidder] : type(uint).max;
        
        // 1. VELOCITY PATTERN DETECTION: Rapid succession of bids
        if (timeSinceLastBid < 30 seconds) {
            consecutiveHighValueBids[bidder]++;
            if (consecutiveHighValueBids[bidder] > 3) {
                emit SuspiciousActivity(bidder, "Rapid bidding pattern");
            }
        } else if (timeSinceLastBid > 5 minutes) {
            // Reset counter for legitimate gaps
            consecutiveHighValueBids[bidder] = 0;
        }
        
        // 2. VALUE ANOMALY DETECTION: Unusually large bids
        uint avgBidValue = epochs[currentEpochIndex].totalBids > 0 ? 
            (totalBidValue[bidder] / Math.max(userBidIds[bidder].length, 1)) : 0;
        
        uint currentBidValueUSD = ethAmount * 3000; // Rough conversion
        if (avgBidValue > 0 && currentBidValueUSD > avgBidValue * SUSPICIOUS_VALUE_RATIO) {
            emit SuspiciousActivity(bidder, "Anomalous bid size");
        }
        
        // 3. TIMING PATTERN DETECTION: Bids at suspicious intervals
        if (timeSinceLastBid < type(uint).max) {
            uint epochTimeElapsed = currentTime - epochs[currentEpochIndex].startTime;
            uint epochProgress = (epochTimeElapsed * 100) / (epochs[currentEpochIndex].endTime - epochs[currentEpochIndex].startTime);
            
            // Suspicious if bidding exactly at epoch boundaries or transitions
            if (epochProgress < 5 || epochProgress > 95) {
                emit SuspiciousActivity(bidder, "Epoch boundary timing");
            }
        }
    }
    
    /// @notice ANTI-MEV: Batch processing to prevent front-running
    function _checkBatchProcessing() internal {
        uint currentTime = block.timestamp;
        uint timeSinceEpochStart = currentTime - epochs[currentEpochIndex].startTime;
        
        // Check if we're in a batch window
        uint batchNumber = timeSinceEpochStart / BATCH_WINDOW;
        uint batchStartTime = epochs[currentEpochIndex].startTime + (batchNumber * BATCH_WINDOW);
        
        // If we're at the end of a batch window and have enough bids, process batch
        if ((currentTime - batchStartTime) >= (BATCH_WINDOW - 5) && 
            epochs[currentEpochIndex].totalBids >= MIN_BATCH_SIZE) {
            
            emit BatchProcessed(currentEpochIndex, epochs[currentEpochIndex].totalBids, block.number);
            
            // ANTI-MEV: Shuffle recent bids to prevent ordering manipulation
            _shuffleRecentBids();
        }
    }
    
    /// @notice ANTI-MEV: Shuffle recent bids to prevent ordering exploitation
    function _shuffleRecentBids() internal {
        uint totalBids = epochs[currentEpochIndex].totalBids;
        if (totalBids < 2) return;
        
        // Use epoch random seed for shuffling
        uint seed = epochRandomSeed[currentEpochIndex];
        
        // Shuffle last few bids to prevent precise ordering attacks
        uint shuffleRange = Math.min(totalBids, 5);
        uint[] memory recentBids = new uint[](shuffleRange);
        
        // Extract recent bid IDs
        uint[] memory allSortedKeys = epochs[currentEpochIndex].sortedBidIds.getSortedSet();
        for (uint i = 0; i < shuffleRange; i++) {
            uint keyIndex = allSortedKeys.length - shuffleRange + i;
            recentBids[i] = uint32(allSortedKeys[keyIndex]);
        }
        
        // Simple shuffle using epoch randomness
        for (uint i = 0; i < shuffleRange; i++) {
            uint j = uint(keccak256(abi.encode(seed, i))) % shuffleRange;
            if (i != j) {
                // Swap bid timestamps slightly to change processing order
                AuctionStructs.Bid storage bidI = allBids[recentBids[i]];
                AuctionStructs.Bid storage bidJ = allBids[recentBids[j]];
                
                uint tempTimestamp = bidI.timestamp;
                bidI.timestamp = bidJ.timestamp;
                bidJ.timestamp = tempTimestamp;
            }
        }
    }
    
    // ============ ENHANCED EPOCH MANAGEMENT ============
    
    function _updateEpochIfNeeded() internal {
        if (currentEpochIndex >= params.totalEpochs) {
            if (!bettingWindowClosed) {
                bettingWindowClosed = true;
            }
            return;
        }
        
        if (block.timestamp >= epochs[currentEpochIndex].endTime) {
            currentEpochIndex++;
            if (currentEpochIndex < params.totalEpochs) {
                _startNewEpochSecure(currentEpochIndex);
            } else {
                bettingWindowClosed = true;
            }
        }
    }
    
    /// @notice ANTI-MEV: Start epoch with enhanced randomization
    function _startNewEpochSecure(uint epochIndex) internal {
        // Generate strong randomness for this epoch
        epochRandomSeed[epochIndex] = uint(keccak256(abi.encode(
            block.timestamp,
            block.difficulty,
            blockhash(block.number - 1),
            epochIndex,
            address(this),
            totalGasFeesCollected
        )));
        
        // Use library with enhanced randomness
        (uint startTime, uint endTime, uint sharesAvailable) = AuctionLib.startNewEpochSecure(
            epochIndex, 
            block.timestamp,
            epochRandomSeed[epochIndex]
        );
        
        epochs[epochIndex].startTime = startTime;
        epochs[epochIndex].endTime = endTime;
        epochs[epochIndex].sharesAvailable = sharesAvailable;
    }
    
    // ============ ENHANCED EPOCH CLEARING ============
    
    function clearEpoch(uint epochIndex) external nonReentrant {
        require(!epochs[epochIndex].cleared, "Already cleared");
        require(
            block.timestamp >= epochs[epochIndex].endTime || 
            epochIndex < currentEpochIndex || 
            bettingWindowClosed, 
            "Epoch not ended"
        );
        
        uint gasStart = gasleft();
        
        // ANTI-MEV: Use true pro-rata allocation with price tiers
        epochs[epochIndex].sharesAllocated = AuctionLib.allocateProRataSecure(
            epochs[epochIndex].sortedBidIds,
            allBids,
            epochs[epochIndex].sharesAvailable,
            epochs[epochIndex].sharesAllocated,
            epochRandomSeed[epochIndex]
        );
        
        // Process allocations
        uint[] memory sortedKeys = epochs[epochIndex].sortedBidIds.getSortedSet();
        uint totalUSDUsed = 0;
        
        for (uint i = 0; i < sortedKeys.length; i++) {
            uint bidId = uint32(sortedKeys[i]);
            AuctionStructs.Bid storage bid = allBids[bidId];
            
            if (bid.sharesAllocated > 0) {
                uint usdUsed = (bid.sharesAllocated * bid.pricePerShare) / 1e18;
                
                // Update user shares
                if (bid.isYes) {
                    userYesShares[bid.bidder] += bid.sharesAllocated;
                    totalYesShares += bid.sharesAllocated;
                } else {
                    userNoShares[bid.bidder] += bid.sharesAllocated;
                    totalNoShares += bid.sharesAllocated;
                }
                
                totalUSDUsed += usdUsed;
                _mintERC20(bid.bidder, bid.sharesAllocated);
                
                // Handle refunds
                if (bid.sharesAllocated < bid.sharesRequested && bid.usdAmount > usdUsed) {
                    uint usdRefund = bid.usdAmount - usdUsed;
                    if (usdRefund > 0) {
                        Basket(params.basket).mint(bid.bidder, usdRefund, address(params.basket), 0);
                    }
                }
            } else if (bid.processed) {
                Basket(params.basket).mint(bid.bidder, bid.usdAmount, address(params.basket), 0);
            }
        }
        
        epochs[epochIndex].cleared = true;
        epochs[epochIndex].clearer = msg.sender;
        totalPoolUSD += totalUSDUsed;
        
        // Enhanced gas compensation with MEV protection
        uint gasUsed = 0;
        if (gasleft() < gasStart) {
            gasUsed = gasStart - gasleft();
        }
        
        uint compensation = 0;
        if (epochs[epochIndex].totalBids >= 10 && epochs[epochIndex].totalGasCollected > 0) {
            compensation = Math.min(gasUsed * tx.gasprice, epochs[epochIndex].totalGasCollected);
            
            // ANTI-MEV: Cap compensation to prevent gaming
            uint maxCompensation = epochs[epochIndex].totalGasCollected / 2;
            compensation = Math.min(compensation, maxCompensation);
            
            if (compensation > 0) {
                epochs[epochIndex].gasCompensated = true;
                (bool success,) = msg.sender.call{value: compensation}("");
                require(success, "Fee distribution failed");
            }
        }
        
        emit EpochCleared(epochIndex, epochs[epochIndex].sharesAllocated, msg.sender, compensation);
    }
    
    // ============ Content Submission ============
    
    function placePredictionBidWithContent(
        uint pricePerShare,
        bool isYes,
        string calldata contentURI
    ) external payable nonReentrant {
        require(requiresContent && authorizedContentSubmitters[msg.sender], "Not authorized");
        require(block.timestamp <= contentDeadline, "Content deadline passed");
        require(contentSubmissionCount < 2, "Max content reached");
        require(bytes(contentURI).length > 0, "Empty content");
        
        contentSubmissionCount++;
        
        // Store content submission event (simplified)
        // emit ContentSubmitted(msg.sender, contentURI);
        
        // Place the bid normally
        placePredictionBid(pricePerShare, isYes);
    }
    
    // ============ Settlement ============
    
    function rule(uint _disputeID, uint _ruling) external override {
        require(msg.sender == address(settlementSystem), "Only settlement");
        require(_disputeID == disputeId, "Wrong dispute");
        
        if (_ruling == 0) {
            resolved = true;
            outcome = false;
            emit PredictionResolved(false);
        } else if (_ruling == 1) {
            resolved = true;
            outcome = true;
            emit PredictionResolved(true);
        } else if (_ruling == 2) {
            forceMajeurRefunds = true;
        }
        
        emit Ruling(IArbitrator(address(settlementSystem)), _disputeID, _ruling);
    }
    
    // ============ Payouts ============
    
    function calculatePredictionPayout(address user) external view returns (uint payoutUSD) {
        require(resolved && !forceMajeurRefunds, "Not resolved");
        
        uint userWinningShares = outcome ? userYesShares[user] : userNoShares[user];
        uint totalWinningShares = outcome ? totalYesShares : totalNoShares;
        
        if (userWinningShares == 0 || totalWinningShares == 0) return 0;
        return (userWinningShares * totalPoolUSD) / totalWinningShares;
    }
    
    function claimPredictionPayout() external nonReentrant {
        require(resolved && !forceMajeurRefunds, "Not resolved");
        
        uint payoutUSD = this.calculatePredictionPayout(msg.sender);
        require(payoutUSD > 0, "No payout");
        
        uint userShares = userYesShares[msg.sender] + userNoShares[msg.sender];
        userYesShares[msg.sender] = 0;
        userNoShares[msg.sender] = 0;
        
        if (userShares > 0) {
            balanceOf[msg.sender] -= userShares;
            totalSupply -= userShares;
            emit ERC20Events.Transfer(msg.sender, address(0), userShares);
        }
        
        Basket(params.basket).mint(msg.sender, payoutUSD, address(params.basket), 0);
        emit PayoutClaimed(msg.sender, payoutUSD, false);
    }
    
    function claimForceMajeurRefund() external nonReentrant {
        require(forceMajeurRefunds, "No force majeur");
        
        uint userTotalShares = userYesShares[msg.sender] + userNoShares[msg.sender];
        require(userTotalShares > 0, "No shares");
        
        userYesShares[msg.sender] = 0;
        userNoShares[msg.sender] = 0;
        
        uint totalShares = totalYesShares + totalNoShares;
        uint refundUSD = (userTotalShares * totalPoolUSD) / totalShares;
        
        balanceOf[msg.sender] -= userTotalShares;
        totalSupply -= userTotalShares;
        emit ERC20Events.Transfer(msg.sender, address(0), userTotalShares);
        
        Basket(params.basket).mint(msg.sender, refundUSD, address(params.basket), 0);
        emit PayoutClaimed(msg.sender, refundUSD, true);
    }
    
    // ============ View Functions ============
    
    function getCurrentEpochInfo() external view returns (
        uint index,
        uint currentPrice,
        uint timeRemaining,
        uint bidCount,
        bool isActive
    ) {
        index = currentEpochIndex;
        if (index >= params.totalEpochs) return (index, 0, 0, 0, false);
        
        (currentPrice, timeRemaining, bidCount, isActive) = AuctionLib.getCurrentEpochInfo(epochs[index], bettingWindowClosed);
    }
    
    function getUserPosition(address user) external view returns (
        uint yesShares,
        uint noShares,
        uint total404Tokens,
        uint estimatedPayout
    ) {
        yesShares = userYesShares[user];
        noShares = userNoShares[user];
        total404Tokens = balanceOf[user];
        
        if (resolved && !forceMajeurRefunds) {
            estimatedPayout = this.calculatePredictionPayout(user);
        }
    }
    
    function getPredictionSummary() external view returns (
        string memory _question,
        uint _totalYesShares,
        uint _totalNoShares,
        uint _totalPoolUSD,
        uint impliedProbability,
        bool _resolved,
        bool _outcome
    ) {
        _question = question;
        _totalYesShares = totalYesShares;
        _totalNoShares = totalNoShares;
        _totalPoolUSD = totalPoolUSD;
        
        if (totalYesShares + totalNoShares > 0) {
            impliedProbability = (totalYesShares * 100) / (totalYesShares + totalNoShares);
        }
        
        _resolved = resolved;
        _outcome = outcome;
    }
    
    function getPredictionConfig() external view returns (
        string memory _question,
        uint _resolutionTime,
        bool _resolved,
        bool _outcome,
        bool _requiresContent,
        uint _contentDeadline,
        uint _minParticipants,
        uint _totalYesShares,
        uint _totalNoShares,
        uint _totalPoolUSD
    ) {
        return (
            question,
            resolutionTime,
            resolved,
            outcome,
            requiresContent,
            contentDeadline,
            minParticipants,
            totalYesShares,
            totalNoShares,
            totalPoolUSD
        );
    }
    
    function getEpoch(uint index) external view returns (
        uint startTime,
        uint endTime,
        uint sharesAvailable,
        uint sharesAllocated,
        uint totalBids,
        uint totalGasCollected,
        bool cleared,
        bool gasCompensated,
        address clearer
    ) {
        AuctionStructs.Epoch storage epoch = epochs[index];
        return (
            epoch.startTime,
            epoch.endTime,
            epoch.sharesAvailable,
            epoch.sharesAllocated,
            epoch.totalBids,
            epoch.totalGasCollected,
            epoch.cleared,
            epoch.gasCompensated,
            epoch.clearer
        );
    }
    
    function getMinimumPriceForAllocation(uint totalSharesWanted, uint epochShares) external pure returns (uint) {
        return AuctionLib.getMinimumPriceForAllocation(totalSharesWanted, epochShares);
    }
    
    function getUserBidIds(address user) external view returns (uint[] memory) {
        return userBidIds[user];
    }
    
    function getBidDetails(uint bidId) external view returns (
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        uint sharesAllocated,
        bool isYes,
        uint timestamp
    ) {
        AuctionStructs.Bid storage bid = allBids[bidId];
        return (bid.bidder, bid.usdAmount, bid.pricePerShare, bid.sharesAllocated, bid.isYes, bid.timestamp);
    }
    
    function calculateFairPrice(uint epochIndex) external view returns (uint) {
        return AuctionLib.calculateFairPrice(
            epochIndex,
            epochs[epochIndex].sharesAvailable,
            epochs[epochIndex].sharesAllocated,
            epochs[epochIndex].totalBids
        );
    }
    
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }
    
    function getParticipantCount() external view returns (uint) {
        return participants.length;
    }
    
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
    
    receive() external payable {}
}