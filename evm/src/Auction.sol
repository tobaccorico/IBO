// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./imports/ERC404.sol";
import "./imports/ERC20Events.sol";
import "./imports/SortedSet.sol";
import "./imports/IArbitrable.sol";
import "./imports/IArbitrator.sol";
import "./Settlement.sol";
import "./Rover.sol";
import "./Aux.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/// @title Auction - Belgian Auction with ERC404 Integration and MEV Protection
/// @notice Pay-your-confidence mechanics with batch clearing and gas compensation
/// @dev Handles both ETH (via Aux) and direct USD deposits to Basket
contract Auction is ERC404, ReentrancyGuard, IArbitrable {
    using Math for uint;
    using SortedSetLib for SortedSetLib.Set;

    // ============ Constants ============
    
    uint private constant EPOCH_DURATION = 1 hours;
    uint private constant MIN_BET_USD = 1e18;                      // $1 minimum
    uint private constant GAS_FEE_BPS = 50;                        // 0.5% in basis points
    uint private constant INITIAL_SHARES_PER_EPOCH = 10000e18;
    uint private constant SHARES_DECAY_RATE = 10;                  // 10% decay per epoch
    uint private constant CLEARING_GAS_ESTIMATE = 200000;          // Gas for clearing
    uint private constant MIN_BIDS_FOR_GAS_COMP = 10;              // Minimum bids to qualify
    uint private constant MAX_BIDS_PER_EPOCH = 1000;               // DoS protection
    uint private constant MAX_ALLOCATION_PER_ADDRESS = 2500;       // 25% max per address per epoch
    
    // ============ Structs ============
    
    /// @dev Individual bid with Belgian mechanics
    struct Bid {
        address bidder;
        uint usdAmount;           // USD amount deposited to Basket
        uint pricePerShare;       // Their confidence/price (0.01 to 1.00)
        uint sharesRequested;
        uint sharesAllocated;
        uint epochIndex;
        uint timestamp;
        bool isYes;
        bool processed;
    }
    
    /// @dev Epoch with sorted bid tracking
    struct Epoch {
        uint startTime;
        uint endTime;
        uint sharesAvailable;
        uint sharesAllocated;
        uint totalBids;
        uint totalGasCollected;   // Gas fees collected this epoch
        bool cleared;
        bool gasCompensated;      // Track if clearer was compensated
        address clearer;          // Who cleared this epoch
        mapping(address => uint) allocatedShares; // Track per-address allocations
        SortedSetLib.Set sortedBidIds;  // Sorted by price descending
    }
    
    /// @dev Core auction parameters
    struct AuctionParams {
        string name;
        string symbol;
        uint auctionDuration;         // Total betting window
        uint totalEpochs;             // Number of epochs
        address owner;
        address settlementSystem;
        address rover;
        address aux;
        address basket;
    }
    
    /// @dev Prediction market configuration
    struct PredictionConfig {
        string question;
        uint resolutionTime;
        bool resolved;
        bool outcome;
        mapping(address => uint) userYesShares;
        mapping(address => uint) userNoShares;
        mapping(address => uint) avgStrikePrice;
        uint totalYesShares;
        uint totalNoShares;
        uint totalPoolUSD;            // Total USD in Basket for this market
        bool requiresContent;
        mapping(address => string) contentSubmissions;
        address[] contentSubmitters;
        uint contentDeadline;
        uint minParticipants;
    }
    
    // ============ State Variables ============
    
    bool private initialized;
    AuctionParams public params;
    
    // Epoch management
    mapping(uint => Epoch) internal epochs;
    uint public currentEpochIndex;
    bool public bettingWindowClosed;
    
    // Bid tracking
    mapping(uint => Bid) public allBids;
    mapping(address => uint[]) public userBidIds;
    uint public nextBidId = 1;
    
    // Participant tracking for jury selection
    mapping(address => bool) public hasParticipated;
    address[] public participants;
    uint public participantCount;
    
    // Prediction market state
    PredictionConfig public predictionConfig;
    bool public forceMajeurRefunds;
    
    // Settlement integration
    Settlement public settlementSystem;
    Aux public auxSystem;
    uint public disputeId;
    uint public metaEvidenceId;
    
    // Gas compensation tracking
    uint public totalGasFeesCollected;
    uint public totalGasFeesDistributed;
    address public protocolTreasury;
    
    // Content market support
    mapping(address => bool) public authorizedContentSubmitters;
    uint public contentSubmissionCount;
    
    // MEV protection
    mapping(uint => mapping(address => uint)) public epochAllocations; // epoch => address => total shares
    
    // ============ Events ============
    
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event EpochCleared(uint indexed epoch, uint sharesAllocated, address clearer, uint gasCompensation);
    event BettingWindowClosed(uint totalEpochs);
    event PredictionResolved(bool outcome);
    event ForceMajeurDeclared();
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    event ContentSubmitted(address indexed submitter, string contentURI);
    event ParticipantAdded(address indexed participant);
    
    // ============ Constructor & Initialization ============
    
    constructor() ERC404("", "", 18) {
        // Set units to 1e18 to effectively disable NFT minting
        // This makes the system work with ERC20 tokens only
        units = 1e18;
    }
    
    function initialize(AuctionParams memory _params) external {
        require(!initialized, "Already initialized");
        initialized = true;
        
        params = _params;
        settlementSystem = Settlement(_params.settlementSystem);
        auxSystem = Aux(payable(_params.aux));
        protocolTreasury = _params.owner; // Set protocol treasury to owner
        
        name = _params.name;
        symbol = _params.symbol;
        
        _startNewEpoch();
    }
    
    function initializePredictionMarket(
        string memory question_,
        uint resolutionTime_,
        uint metaEvidenceId_,
        bool requiresContent_,
        uint contentDeadline_,
        uint minParticipants_
    ) external {
        require(msg.sender == params.owner, "Not owner");
        require(resolutionTime_ > block.timestamp + params.auctionDuration, "Invalid resolution");
        
        predictionConfig.question = question_;
        predictionConfig.resolutionTime = resolutionTime_;
        predictionConfig.requiresContent = requiresContent_;
        predictionConfig.contentDeadline = contentDeadline_;
        predictionConfig.minParticipants = minParticipants_;
        metaEvidenceId = metaEvidenceId_;
    }
    
    function setAuthorizedSubmitters(address submitter1, address submitter2) external {
        require(msg.sender == params.owner, "Not owner");
        require(predictionConfig.requiresContent, "Not content market");
        authorizedContentSubmitters[submitter1] = true;
        authorizedContentSubmitters[submitter2] = true;
    }
    
    // ============ MEV Protection State ============
    
    // Velocity tracking for dynamic fees
    mapping(address => uint) public lastBidTime;
    mapping(address => uint) public bidVelocity; // 0-1000 (0-10x multiplier)
    
    // Batch processing for sandwich resistance  
    uint constant BATCH_WINDOW = 5 minutes;
    mapping(uint => uint[]) public batchBidIds; // batchId => array of bid IDs
    mapping(uint => bool) public batchProcessed;
    
    // MEV Protection: Track recent large trades
    uint constant WHALE_WINDOW = 15 minutes;
    mapping(uint => uint) public epochWhaleActivity; // epoch => large trade USD in last window
    uint constant WHALE_THRESHOLD = 10000e18; // $10k USD
    
    // Price impact tracking
    mapping(uint => uint) public epochPriceImpact; // epoch => cumulative price impact
    
    // ============ Core Belgian Auction Functions ============
    
    /// @notice Calculate minimum price based on total allocation (MEV protection)
    function getMinimumPriceForAllocation(uint totalSharesWanted, uint epochShares) public pure returns (uint) {
        if (epochShares == 0) return 1e18;
        
        uint percentOfEpoch = (totalSharesWanted * 100) / epochShares;
        
        // Exponential curve - the more you want, the more you pay
        if (percentOfEpoch <= 5) return 0.01e18;   // 1¢ for ≤5%
        if (percentOfEpoch <= 10) return 0.05e18;  // 5¢ for ≤10%
        if (percentOfEpoch <= 20) return 0.15e18;  // 15¢ for ≤20%
        if (percentOfEpoch <= 30) return 0.30e18;  // 30¢ for ≤30%
        if (percentOfEpoch <= 40) return 0.50e18;  // 50¢ for ≤40%
        if (percentOfEpoch <= 50) return 0.70e18;  // 70¢ for ≤50%
        if (percentOfEpoch <= 75) return 0.85e18;  // 85¢ for ≤75%
        return 0.95e18; // 95¢ for >75%
    }
    
    /// @notice Calculate dynamic fee based on bidding velocity
    function calculateDynamicGasFee(address bidder) internal returns (uint feeBps) {
        uint timeSinceLastBid = block.timestamp - lastBidTime[bidder];
        
        // Update velocity
        if (timeSinceLastBid < 1 minutes) {
            // Rapid bidding - increase velocity
            bidVelocity[bidder] = Math.min(bidVelocity[bidder] + 200, 1000);
        } else if (timeSinceLastBid < 5 minutes) {
            // Moderate speed
            bidVelocity[bidder] = Math.min(bidVelocity[bidder] + 50, 1000);
        } else {
            // Decay velocity
            uint decay = (timeSinceLastBid / 1 minutes) * 10;
            bidVelocity[bidder] = bidVelocity[bidder] > decay ? 
                                   bidVelocity[bidder] - decay : 0;
        }
        
        lastBidTime[bidder] = block.timestamp;
        
        // Base fee 0.5% + velocity penalty (up to 10x = 5%)
        return GAS_FEE_BPS + (GAS_FEE_BPS * bidVelocity[bidder] / 100);
    }
    
    /// @notice Place a Belgian auction bid with ETH at your confidence level
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    function placePredictionBid(uint pricePerShare, bool isYes) public payable nonReentrant {
        require(!bettingWindowClosed, "Betting closed");
        require(!predictionConfig.resolved, "Already resolved");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        require(msg.value > 0, "No ETH sent");
        
        _updateEpochIfNeeded();
        
        // Track participant
        _addParticipant(msg.sender);
        
        // Calculate dynamic gas fee based on velocity
        uint dynamicFeeBps = calculateDynamicGasFee(msg.sender);
        uint gasContribution = (msg.value * dynamicFeeBps) / 10000;
        uint actualBetETH = msg.value - gasContribution;
        require(actualBetETH > 0, "Too small after gas");
        
        // Swap ETH to USD via Aux
        uint usdReceived = auxSystem.swap{value: actualBetETH}(
            address(params.basket),
            false,
            actualBetETH,
            0
        );
        require(usdReceived >= MIN_BET_USD, "Below minimum USD");
        
        // Calculate shares at their price
        uint sharesRequested = (usdReceived * 1e18) / pricePerShare;
        
        // MEV Protection: Check if price meets minimum for desired allocation
        Epoch storage currentEpoch = epochs[currentEpochIndex];
        
        // Calculate total shares this address would have
        uint currentShares = 0;
        uint batchId = block.timestamp / BATCH_WINDOW;
        
        // Count shares in current batch
        uint[] storage currentBatchBids = batchBidIds[batchId];
        for (uint i = 0; i < currentBatchBids.length; i++) {
            Bid storage bid = allBids[currentBatchBids[i]];
            if (bid.bidder == msg.sender) {
                currentShares += bid.sharesRequested;
            }
        }
        
        uint totalSharesWanted = currentShares + sharesRequested;
        
        // Enforce minimum price based on total allocation
        uint minimumPrice = getMinimumPriceForAllocation(
            totalSharesWanted, 
            currentEpoch.sharesAvailable
        );
        require(pricePerShare >= minimumPrice, "Price too low for allocation");
        
        // Additional MEV protection: Detect potential sandwich attacks
        _updateWhaleTracking(usdReceived);
        
        // Apply price impact for large trades
        if (usdReceived > WHALE_THRESHOLD / 10) { // $1k+ trades
            uint impact = (usdReceived * 100) / predictionConfig.totalPoolUSD;
            if (impact > 5) { // >5% of pool
                // Require higher confidence for large market impact
                uint impactMultiplier = 100 + (impact - 5) * 2; // 2% per 1% over 5%
                minimumPrice = (minimumPrice * impactMultiplier) / 100;
                require(pricePerShare >= minimumPrice, "Price too low for market impact");
            }
        }
        
        // Create bid but don't process immediately (batch processing)
        uint bidId = nextBidId++;
        allBids[bidId] = Bid({
            bidder: msg.sender,
            usdAmount: usdReceived,
            pricePerShare: pricePerShare,
            sharesRequested: sharesRequested,
            sharesAllocated: 0,
            epochIndex: currentEpochIndex,
            timestamp: block.timestamp,
            isYes: isYes,
            processed: false
        });
        
        // Add to current batch
        currentBatchBids.push(bidId);
        userBidIds[msg.sender].push(bidId);
        
        // Update gas collection
        currentEpoch.totalGasCollected += gasContribution;
        totalGasFeesCollected += gasContribution;
        
        emit BidPlaced(msg.sender, usdReceived, pricePerShare, isYes, currentEpochIndex, bidId);
        
        // Try to process previous batch if ready
        uint previousBatch = batchId - 1;
        if (!batchProcessed[previousBatch] && batchBidIds[previousBatch].length > 0) {
            _processBatch(previousBatch);
        }
        
        // Auto-process current batch if it's getting large or time has passed
        if (currentBatchBids.length >= 20 || 
            (currentBatchBids.length > 0 && block.timestamp % BATCH_WINDOW > (BATCH_WINDOW - 30))) {
            _processBatch(batchId);
        }
    }
    
    /// @notice Track whale activity for MEV protection
    function _updateWhaleTracking(uint usdAmount) internal {
        if (usdAmount >= WHALE_THRESHOLD) {
            epochWhaleActivity[currentEpochIndex] += usdAmount;
            
            // If too much whale activity, increase batch window temporarily
            if (epochWhaleActivity[currentEpochIndex] > WHALE_THRESHOLD * 5) {
                // This signals potential manipulation
                epochPriceImpact[currentEpochIndex] += 100; // basis points
            }
        }
    }
    
    /// @notice Process a batch of bids together (MEV resistant)
    function _processBatch(uint batchId) internal {
        if (batchProcessed[batchId]) return;
        
        uint[] storage bidIds = batchBidIds[batchId];
        if (bidIds.length == 0) return;
        
        // Randomize order within batch to prevent gaming
        if (bidIds.length > 1) {
            // Simple randomization using block data
            uint seed = uint(keccak256(abi.encode(block.timestamp, block.prevrandao)));
            for (uint i = bidIds.length - 1; i > 0; i--) {
                uint j = seed % (i + 1);
                uint temp = bidIds[i];
                bidIds[i] = bidIds[j];
                bidIds[j] = temp;
                seed = uint(keccak256(abi.encode(seed)));
            }
        }
        
        // Check if batch is for current epoch
        uint epochIndex = allBids[bidIds[0]].epochIndex;
        if (epochIndex != currentEpochIndex && !epochs[epochIndex].cleared) {
            // Add all bids to epoch's sorted set
            for (uint i = 0; i < bidIds.length; i++) {
                Bid storage bid = allBids[bidIds[i]];
                if (bid.epochIndex == epochIndex) {
                    // Insert into sorted set
                    uint sortKey = (type(uint).max - bid.pricePerShare) << 32 | bidIds[i];
                    epochs[epochIndex].sortedBidIds.insert(sortKey);
                    epochs[epochIndex].totalBids++;
                }
            }
        }
        
        batchProcessed[batchId] = true;
    }
    
    /// @notice Place bid with content (for rap battles)
    function placePredictionBidWithContent(
        uint pricePerShare,
        bool isYes,
        string calldata contentURI
    ) external payable nonReentrant {
        require(predictionConfig.requiresContent, "Content not required");
        require(authorizedContentSubmitters[msg.sender], "Not authorized submitter");
        require(block.timestamp <= predictionConfig.contentDeadline, "Content deadline passed");
        require(bytes(contentURI).length > 0, "Empty content");
        require(contentSubmissionCount < 2, "Max content reached");
        
        // Store content
        if (bytes(predictionConfig.contentSubmissions[msg.sender]).length == 0) {
            predictionConfig.contentSubmitters.push(msg.sender);
            contentSubmissionCount++;
        }
        predictionConfig.contentSubmissions[msg.sender] = contentURI;
        
        emit ContentSubmitted(msg.sender, contentURI);
        
        // Place the bid normally
        placePredictionBid(pricePerShare, isYes);
    }
    
    /// @notice Internal function to create and store bid
    function _createBid(
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        uint sharesRequested,
        bool isYes
    ) internal {
        // DoS protection
        require(epochs[currentEpochIndex].totalBids < MAX_BIDS_PER_EPOCH, "Epoch full");
        
        uint bidId = nextBidId++;
        allBids[bidId] = Bid({
            bidder: bidder,
            usdAmount: usdAmount,
            pricePerShare: pricePerShare,
            sharesRequested: sharesRequested,
            sharesAllocated: 0,
            epochIndex: currentEpochIndex,
            timestamp: block.timestamp,
            isYes: isYes,
            processed: false
        });
        
        // Insert into sorted set (higher prices = higher priority)
        uint sortKey = (type(uint).max - pricePerShare) << 32 | bidId;
        epochs[currentEpochIndex].sortedBidIds.insert(sortKey);
        
        userBidIds[bidder].push(bidId);
        epochs[currentEpochIndex].totalBids++;
        
        emit BidPlaced(bidder, usdAmount, pricePerShare, isYes, currentEpochIndex, bidId);
    }
    
    // ============ Belgian Auction Clearing with Gas Compensation ============
    
    /// @notice Clear epoch with Belgian mechanics - highest bidders first
    /// @dev Processes batched bids to prevent sandwich attacks
    function clearEpoch(uint epochIndex) external nonReentrant {
        Epoch storage epoch = epochs[epochIndex];
        require(!epoch.cleared, "Already cleared");
        require(epochIndex < currentEpochIndex || bettingWindowClosed, "Epoch not ended");
        
        // Process any remaining batches for this epoch
        uint currentBatch = block.timestamp / BATCH_WINDOW;
        for (uint batch = (epoch.startTime / BATCH_WINDOW); batch < currentBatch; batch++) {
            if (!batchProcessed[batch] && batchBidIds[batch].length > 0) {
                _processBatch(batch);
            }
        }
        
        uint gasStart = gasleft();
        
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        if (sortedKeys.length == 0) {
            epoch.cleared = true;
            epoch.clearer = msg.sender;
            return;
        }
        
        uint sharesRemaining = epoch.sharesAvailable;
        uint totalSharesAllocated = 0;
        uint totalUSDUsed = 0;
        
        // Store refunds to process after iteration
        address[] memory refundRecipients = new address[](sortedKeys.length);
        uint[] memory refundAmounts = new uint[](sortedKeys.length);
        uint refundCount = 0;
        
        // Process in sorted order (highest price first)
        for (uint i = 0; i < sortedKeys.length && sharesRemaining > 0; i++) {
            uint bidId = uint32(sortedKeys[i]);
            Bid storage bid = allBids[bidId];
            
            if (bid.processed) continue;
            
            uint sharesToAllocate = Math.min(bid.sharesRequested, sharesRemaining);
            
            if (sharesToAllocate > 0) {
                bid.sharesAllocated = sharesToAllocate;
                bid.processed = true;
                
                // Calculate actual USD used
                uint usdUsed = (sharesToAllocate * bid.pricePerShare) / 1e18;
                
                // Update user shares
                if (bid.isYes) {
                    predictionConfig.userYesShares[bid.bidder] += sharesToAllocate;
                    predictionConfig.totalYesShares += sharesToAllocate;
                } else {
                    predictionConfig.userNoShares[bid.bidder] += sharesToAllocate;
                    predictionConfig.totalNoShares += sharesToAllocate;
                }
                
                // Update weighted average strike price
                _updateUserStrikePrice(bid.bidder, bid.pricePerShare, sharesToAllocate);
                
                // Track totals
                sharesRemaining -= sharesToAllocate;
                totalSharesAllocated += sharesToAllocate;
                totalUSDUsed += usdUsed;
                
                // Mint ERC20 tokens only (no NFTs due to high units value)
                _mintERC20(bid.bidder, sharesToAllocate);
                
                // Store refund info for partial fills
                if (sharesToAllocate < bid.sharesRequested) {
                    uint usdRefund = bid.usdAmount - usdUsed;
                    if (usdRefund > 0) {
                        refundRecipients[refundCount] = bid.bidder;
                        refundAmounts[refundCount] = usdRefund;
                        refundCount++;
                    }
                }
            } else {
                // Full refund for bids that couldn't allocate
                refundRecipients[refundCount] = bid.bidder;
                refundAmounts[refundCount] = bid.usdAmount;
                refundCount++;
                bid.processed = true;
            }
        }
        
        epoch.cleared = true;
        epoch.clearer = msg.sender;
        epoch.sharesAllocated = totalSharesAllocated;
        predictionConfig.totalPoolUSD += totalUSDUsed;
        
        // Process refunds after all state changes
        for (uint i = 0; i < refundCount; i++) {
            if (refundAmounts[i] > 0) {
                Basket(params.basket).mint(refundRecipients[i], refundAmounts[i], address(params.basket), 0);
            }
        }
        
        // Gas compensation with MEV protection (3-way split)
        uint gasUsed = gasStart - gasleft();
        uint compensation = 0;
        
        if (epoch.totalBids >= MIN_BIDS_FOR_GAS_COMP && epoch.totalGasCollected > 0) {
            compensation = Math.min(
                gasUsed * tx.gasprice,
                epoch.totalGasCollected
            );
            
            if (compensation > 0) {
                epoch.gasCompensated = true;
                totalGasFeesDistributed += compensation;
                
                // Split fees: 1/3 clearer, 1/3 treasury, 1/3 burned
                uint clearerShare = compensation / 3;
                uint treasuryShare = compensation / 3;
                // Remainder stays in contract (effective burn)
                
                (bool success1,) = msg.sender.call{value: clearerShare}("");
                (bool success2,) = protocolTreasury.call{value: treasuryShare}("");
                require(success1 && success2, "Fee distribution failed");
            }
        }
        
        emit EpochCleared(epochIndex, totalSharesAllocated, msg.sender, compensation);
    }
    
    function _updateUserStrikePrice(address user, uint newPrice, uint newShares) internal {
        uint currentShares = predictionConfig.userYesShares[user] + predictionConfig.userNoShares[user] - newShares;
        uint currentAvg = predictionConfig.avgStrikePrice[user];
        
        if (currentShares == 0) {
            predictionConfig.avgStrikePrice[user] = newPrice;
        } else {
            uint totalValue = (currentShares * currentAvg) + (newShares * newPrice);
            predictionConfig.avgStrikePrice[user] = totalValue / (currentShares + newShares);
        }
    }
    
    // ============ Simplified ERC20 Burn (No NFT handling) ============
    
    function _burnERC20Only(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        // Just burn ERC20 tokens
        balanceOf[from] -= amount;
        totalSupply -= amount;
        
        emit ERC20Events.Transfer(from, address(0), amount);
    }
    
    // ============ Resolution & Payouts ============
    
    /// @notice Calculate user's payout
    function calculatePredictionPayout(address user) external view returns (uint payoutUSD) {
        require(predictionConfig.resolved, "Not resolved");
        require(!forceMajeurRefunds, "Use force majeur refund");
        
        uint userWinningShares;
        uint totalWinningShares;
        
        if (predictionConfig.outcome) {
            userWinningShares = predictionConfig.userYesShares[user];
            totalWinningShares = predictionConfig.totalYesShares;
        } else {
            userWinningShares = predictionConfig.userNoShares[user];
            totalWinningShares = predictionConfig.totalNoShares;
        }
        
        if (userWinningShares == 0 || totalWinningShares == 0) return 0;
        
        payoutUSD = (userWinningShares * predictionConfig.totalPoolUSD) / totalWinningShares;
    }
    
    /// @notice Claim prediction payout in 6909 tokens
    function claimPredictionPayout() external nonReentrant {
        require(predictionConfig.resolved, "Not resolved");
        require(!forceMajeurRefunds, "Use force majeur");
        
        uint payoutUSD = this.calculatePredictionPayout(msg.sender);
        require(payoutUSD > 0, "No payout");
        
        // Reset user shares
        uint userShares = predictionConfig.userYesShares[msg.sender] + 
                         predictionConfig.userNoShares[msg.sender];
        predictionConfig.userYesShares[msg.sender] = 0;
        predictionConfig.userNoShares[msg.sender] = 0;
        
        // Burn ERC20 tokens only
        if (userShares > 0) {
            _burnERC20Only(msg.sender, userShares);
        }
        
        // Pay from Basket in 6909 tokens
        Basket(params.basket).mint(msg.sender, payoutUSD, address(params.basket), 0);
        
        emit PayoutClaimed(msg.sender, payoutUSD, false);
    }
    
    /// @notice Claim force majeur refund
    function claimForceMajeurRefund() external nonReentrant {
        require(forceMajeurRefunds, "No force majeur");
        
        uint userYesShares = predictionConfig.userYesShares[msg.sender];
        uint userNoShares = predictionConfig.userNoShares[msg.sender];
        uint userTotalShares = userYesShares + userNoShares;
        
        require(userTotalShares > 0, "No shares");
        
        // Reset shares
        predictionConfig.userYesShares[msg.sender] = 0;
        predictionConfig.userNoShares[msg.sender] = 0;
        
        // Calculate proportional refund
        uint totalShares = predictionConfig.totalYesShares + predictionConfig.totalNoShares;
        uint refundUSD = (userTotalShares * predictionConfig.totalPoolUSD) / totalShares;
        
        // Burn tokens
        if (userTotalShares > 0) {
            _burnERC20Only(msg.sender, userTotalShares);
        }
        
        // Refund from Basket
        Basket(params.basket).mint(msg.sender, refundUSD, address(params.basket), 0);
        
        emit PayoutClaimed(msg.sender, refundUSD, true);
    }
    
    // ============ Settlement Integration ============
    
    function rule(uint _disputeID, uint _ruling) external override {
        require(msg.sender == address(settlementSystem), "Only settlement");
        require(_disputeID == disputeId, "Wrong dispute");
        require(!predictionConfig.resolved || !forceMajeurRefunds, "Already finalized");
        
        if (_ruling == 0) {
            // NO wins
            predictionConfig.resolved = true;
            predictionConfig.outcome = false;
            emit PredictionResolved(false);
        } else if (_ruling == 1) {
            // YES wins
            predictionConfig.resolved = true;
            predictionConfig.outcome = true;
            emit PredictionResolved(true);
        } else if (_ruling == 2) {
            // Force majeur
            forceMajeurRefunds = true;
            emit ForceMajeurDeclared();
        }
        
        emit Ruling(IArbitrator(params.settlementSystem), _disputeID, _ruling);
    }
    
    // ============ Helper Functions ============
    
    function _addParticipant(address participant) internal {
        if (!hasParticipated[participant]) {
            hasParticipated[participant] = true;
            participants.push(participant);
            participantCount++;
            emit ParticipantAdded(participant);
        }
    }
    
    function _updateEpochIfNeeded() internal {
        if (currentEpochIndex >= params.totalEpochs) {
            if (!bettingWindowClosed) {
                bettingWindowClosed = true;
                emit BettingWindowClosed(params.totalEpochs);
            }
            return;
        }
        
        Epoch storage currentEpoch = epochs[currentEpochIndex];
        
        if (block.timestamp >= currentEpoch.endTime) {
            currentEpochIndex++;
            if (currentEpochIndex < params.totalEpochs) {
                _startNewEpoch();
            } else {
                bettingWindowClosed = true;
                emit BettingWindowClosed(params.totalEpochs);
            }
        }
    }
    
    function _startNewEpoch() internal {
        uint epochIndex = currentEpochIndex;
        
        // Calculate decreasing shares
        uint sharesAvailable = INITIAL_SHARES_PER_EPOCH;
        for (uint i = 0; i < epochIndex; i++) {
            sharesAvailable = (sharesAvailable * (100 - SHARES_DECAY_RATE)) / 100;
        }
        
        epochs[epochIndex].startTime = block.timestamp;
        epochs[epochIndex].endTime = block.timestamp + EPOCH_DURATION;
        epochs[epochIndex].sharesAvailable = sharesAvailable;
        epochs[epochIndex].sharesAllocated = 0;
        epochs[epochIndex].totalBids = 0;
        epochs[epochIndex].totalGasCollected = 0;
        epochs[epochIndex].cleared = false;
        epochs[epochIndex].gasCompensated = false;
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
        
        if (index >= params.totalEpochs) {
            return (index, 0, 0, 0, false);
        }
        
        Epoch storage epoch = epochs[index];
        
        // Price discovery based on demand
        uint sharesAvailable = epoch.sharesAvailable - epoch.sharesAllocated;
        if (sharesAvailable > 0 && epoch.sharesAvailable > 0) {
            currentPrice = (1e18 * (epoch.sharesAvailable - sharesAvailable)) / epoch.sharesAvailable;
            currentPrice = Math.max(currentPrice, 0.01e18);
            currentPrice = Math.min(currentPrice, 1e18);
        } else {
            currentPrice = 1e18;
        }
        
        timeRemaining = epoch.endTime > block.timestamp ? epoch.endTime - block.timestamp : 0;
        bidCount = epoch.totalBids;
        isActive = !bettingWindowClosed && !epoch.cleared;
    }
    
    function getUserPosition(address user) external view returns (
        uint yesShares,
        uint noShares,
        uint total404Tokens,
        uint estimatedPayout
    ) {
        yesShares = predictionConfig.userYesShares[user];
        noShares = predictionConfig.userNoShares[user];
        total404Tokens = balanceOf[user];
        
        if (predictionConfig.resolved && !forceMajeurRefunds) {
            estimatedPayout = this.calculatePredictionPayout(user);
        }
    }
    
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }
    
    function getParticipantCount() external view returns (uint) {
        return participantCount;
    }
    
    function getPredictionSummary() external view returns (
        string memory question,
        uint totalYesShares,
        uint totalNoShares,
        uint totalPoolUSD,
        uint impliedProbability,
        bool resolved,
        bool outcome
    ) {
        question = predictionConfig.question;
        totalYesShares = predictionConfig.totalYesShares;
        totalNoShares = predictionConfig.totalNoShares;
        totalPoolUSD = predictionConfig.totalPoolUSD;
        
        if (totalYesShares + totalNoShares > 0) {
            impliedProbability = (totalYesShares * 100) / (totalYesShares + totalNoShares);
        }
        
        resolved = predictionConfig.resolved;
        outcome = predictionConfig.outcome;
    }
    
    function getPredictionConfig() external view returns (
        string memory question,
        uint resolutionTime,
        bool resolved,
        bool outcome,
        bool requiresContent,
        uint contentDeadline,
        uint minParticipants,
        uint totalYesShares,
        uint totalNoShares,
        uint totalPoolUSD
    ) {
        return (
            predictionConfig.question,
            predictionConfig.resolutionTime,
            predictionConfig.resolved,
            predictionConfig.outcome,
            predictionConfig.requiresContent,
            predictionConfig.contentDeadline,
            predictionConfig.minParticipants,
            predictionConfig.totalYesShares,
            predictionConfig.totalNoShares,
            predictionConfig.totalPoolUSD
        );
    }
    
    function getBidDetails(uint bidId) external view returns (
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        uint sharesAllocated,
        bool isYes,
        bool processed
    ) {
        Bid storage bid = allBids[bidId];
        return (
            bid.bidder,
            bid.usdAmount,
            bid.pricePerShare,
            bid.sharesAllocated,
            bid.isYes,
            bid.processed
        );
    }
    
    function getUserBidIds(address user) external view returns (uint[] memory) {
        return userBidIds[user];
    }
    
    function getContentSubmissions() external view returns (address[] memory submitters, string[] memory) {
        uint len = predictionConfig.contentSubmitters.length;
        string[] memory submissions = new string[](len);
        
        for (uint i = 0; i < len; i++) {
            submissions[i] = predictionConfig.contentSubmissions[predictionConfig.contentSubmitters[i]];
        }
        
        return (predictionConfig.contentSubmitters, submissions);
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
        Epoch storage epoch = epochs[index];
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
    
    // ============ Utility Functions ============
    
    function enableContentRefunds() external {
        require(predictionConfig.requiresContent, "Not content market");
        require(block.timestamp > predictionConfig.contentDeadline, "Deadline not passed");
        require(contentSubmissionCount < 2, "Requirements met");
        require(!forceMajeurRefunds, "Already enabled");
        
        forceMajeurRefunds = true;
        emit ForceMajeurDeclared();
    }
    
    // ============ ERC404 tokenURI Implementation ============
    
    function tokenURI(uint256 id) public view override returns (string memory) {
        return string('');
    }
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Accept ETH for gas fees
    }
}