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
    uint private constant MIN_BIDS_FOR_GAS_COMP = 10;              // Minimum bids to qualify
    uint private constant MAX_BIDS_PER_EPOCH = 1000;               // DoS protection
    
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
    bool private marketInitialized;
    AuctionParams public params;
    
    // Epoch management
    mapping(uint => Epoch) internal epochs;
    uint public currentEpochIndex;
    bool public bettingWindowClosed;
    
    // Bid tracking
    mapping(uint => Bid) public allBids;
    mapping(address => uint[]) public userBidIds;
    uint public nextBidId = 1;
    
    // Commit-reveal for large bids (MEV protection)
    mapping(bytes32 => uint) public commitments; // commitment => block number
    mapping(bytes32 => uint) public committedETH; // commitment => ETH amount
    uint constant COMMIT_REVEAL_THRESHOLD_ETH = 5 ether; // Use commit-reveal for bids > 5 ETH
    uint constant COMMIT_REVEAL_THRESHOLD_USD = 15000e18; // Or > $15,000 USD (assuming ~$3000/ETH)
    uint constant REVEAL_DELAY = 2; // Must wait 2 blocks before revealing
    
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
    
    // ============ Events ============
    
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event BidCommitted(address indexed bidder, bytes32 commitment, uint ethAmount);
    event BidRevealed(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes);
    event EpochCleared(uint indexed epoch, uint sharesAllocated, address clearer, uint gasCompensation);
    event BettingWindowClosed(uint totalEpochs);
    event PredictionResolved(bool outcome);
    event ForceMajeurDeclared();
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    event ContentSubmitted(address indexed submitter, string contentURI);
    event ParticipantAdded(address indexed participant);
    event EpochExtended(uint indexed epoch, uint newEndTime);
    
    // ============ Constructor & Initialization ============
    
    /// @notice Constructor sets up ERC404 with units preventing NFT minting
    /// @dev Units = 1e18 means users need 1e18 tokens for 1 NFT, effectively disabling NFTs
    constructor() ERC404("", "", 18) {
        // Set units to 1e18 to effectively disable NFT minting
        // This makes the system work with ERC20 tokens only
        units = 1e18;
    }
    
    /// @notice Initialize auction with core parameters
    /// @dev Called by factory clone pattern, can only be called once
    /// @param _params Struct containing all initialization parameters
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
    
    /// @notice Initialize as prediction market with specific question and rules
    /// @dev Called after basic initialization to set prediction market parameters
    /// @param question_ The yes/no question being predicted
    /// @param resolutionTime_ When the outcome can be determined
    /// @param metaEvidenceId_ Reference to resolution rules in Settlement contract
    /// @param requiresContent_ Whether participants must submit content (for rap battles)
    /// @param contentDeadline_ Deadline for content submission if required
    /// @param minParticipants_ Minimum participants needed (e.g., 2 for rap battles)
    function initializePredictionMarket(
        string memory question_,
        uint resolutionTime_,
        uint metaEvidenceId_,
        bool requiresContent_,
        uint contentDeadline_,
        uint minParticipants_
    ) external {
        require(!marketInitialized, "Market already initialized");
        require(resolutionTime_ > block.timestamp + params.auctionDuration, "Invalid resolution");
        
        marketInitialized = true;
        predictionConfig.question = question_;
        predictionConfig.resolutionTime = resolutionTime_;
        predictionConfig.requiresContent = requiresContent_;
        predictionConfig.contentDeadline = contentDeadline_;
        predictionConfig.minParticipants = minParticipants_;
        metaEvidenceId = metaEvidenceId_;
    }
    
    /// @notice Set authorized content submitters for content-based markets
    /// @dev Only callable by protocol treasury or owner, used for rap battles
    /// @param submitter1 First authorized submitter (e.g., challenger)
    /// @param submitter2 Second authorized submitter (e.g., challenged)
    function setAuthorizedSubmitters(address submitter1, address submitter2) external {
        require(msg.sender == protocolTreasury || msg.sender == params.owner, "Not authorized");
        require(predictionConfig.requiresContent, "Not content market");
        authorizedContentSubmitters[submitter1] = true;
        authorizedContentSubmitters[submitter2] = true;
    }
    
    // ============ MEV Protection State ============
    
    // Velocity tracking for dynamic fees
    mapping(address => uint) public lastBidTime;
    mapping(address => uint) public bidVelocity; // 0-1000 (0-10x multiplier)
    
    // Price discovery protection
    mapping(uint => uint) public epochMinPrice; // epoch => minimum accepted price
    mapping(uint => uint) public epochMaxPrice; // epoch => maximum price paid
    uint constant PRICE_INCREMENT = 0.01e18; // 1 cent increments
    
    // Anti-sniping: Dynamic epoch extension
    uint constant EXTENSION_THRESHOLD = 2 minutes;
    uint constant EXTENSION_DURATION = 5 minutes;
    mapping(uint => uint) public epochExtensions; // epoch => number of extensions
    uint constant MAX_EXTENSIONS = 3;
    
    // ============ Core Belgian Auction Functions ============
    
    /// @notice Calculate dynamic fee based on bidding velocity
    /// @dev Penalizes rapid bidding to prevent spam and manipulation
    /// @param bidder Address of the bidder
    /// @return feeBps Fee in basis points (50 = 0.5% base, up to 500 = 5%)
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
    
    /// @notice Calculate fair price based on demand curve
    /// @dev Prevents predictable pricing that could be gamed by MEV bots
    /// @param epochIndex The epoch to calculate price for
    /// @return Dynamic minimum price based on fill rate and randomness
    function calculateFairPrice(uint epochIndex) public view returns (uint) {
        Epoch storage epoch = epochs[epochIndex];
        if (epoch.totalBids == 0) return PRICE_INCREMENT;
        
        // Use a smoother curve that's less predictable
        uint fillRate = epoch.sharesAvailable > 0 ? (epoch.sharesAllocated * 100) / epoch.sharesAvailable : 0;
        
        // Add some randomness based on block hash to prevent exact calculations
        uint blockRandomness = uint(keccak256(abi.encode(blockhash(block.number - 1), epochIndex))) % 20;
        
        // Base price with some unpredictability
        uint basePrice = PRICE_INCREMENT + (fillRate * PRICE_INCREMENT / 20) + (blockRandomness * PRICE_INCREMENT / 100);
        
        // Time decay to encourage early participation
        uint timeElapsed = block.timestamp > epoch.startTime ? block.timestamp - epoch.startTime : 0;
        uint timeFactor = 100 - (timeElapsed * 10 / EPOCH_DURATION); // Decreases over time
        
        return (basePrice * timeFactor) / 100;
    }
    
    /// @notice Anti-sniping: Extend epoch if bid near end
    /// @dev Prevents last-second sniping attacks common in auctions
    /// @param epochIndex The epoch to potentially extend
    function _checkEpochExtension(uint epochIndex) internal {
        Epoch storage epoch = epochs[epochIndex];
        uint timeRemaining = epoch.endTime > block.timestamp ? 
                            epoch.endTime - block.timestamp : 0;
        
        if (timeRemaining < EXTENSION_THRESHOLD && 
            epochExtensions[epochIndex] < MAX_EXTENSIONS) {
            epoch.endTime += EXTENSION_DURATION;
            epochExtensions[epochIndex]++;
            emit EpochExtended(epochIndex, epoch.endTime);
        }
    }
    
    /// @notice Calculate minimum price based on total allocation (MEV protection)
    /// @dev Exponential curve prevents whales from dominating epochs cheaply
    /// @param totalSharesWanted Number of shares desired
    /// @param epochShares Total shares available in epoch
    /// @return Minimum price required for that allocation percentage
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
    
    /// @notice Commit a large bid (MEV protection via commit-reveal)
    /// @dev Prevents front-running of large bids by hiding details until reveal
    /// @param commitment Hash of (price, isYes, nonce)
    function commitBid(bytes32 commitment) external payable nonReentrant {
        require(msg.value >= COMMIT_REVEAL_THRESHOLD_ETH, "Use direct bid for small amounts");
        require(!bettingWindowClosed, "Betting closed");
        require(commitments[commitment] == 0, "Already committed");
        
        _updateEpochIfNeeded();
        
        commitments[commitment] = block.number;
        committedETH[commitment] = msg.value;
        
        emit BidCommitted(msg.sender, commitment, msg.value);
    }
    
    /// @notice Commit a large USD bid via stablecoin/vault deposit
    /// @dev Alternative to ETH commits for stablecoin users
    /// @param commitment Hash of (price, isYes, nonce)
    /// @param token Token to deposit (stable or vault)
    /// @param amount Amount to deposit
    function commitBidWithToken(
        bytes32 commitment,
        address token,
        uint amount
    ) external nonReentrant {
        require(!bettingWindowClosed, "Betting closed");
        require(commitments[commitment] == 0, "Already committed");
        
        // Deposit token and get USD value
        uint usdAmount = Basket(params.basket).deposit(msg.sender, token, amount);
        require(usdAmount >= COMMIT_REVEAL_THRESHOLD_USD, "Use direct bid for small amounts");
        
        _updateEpochIfNeeded();
        
        commitments[commitment] = block.number;
        // Store USD amount in ETH mapping (we'll handle it differently in reveal)
        committedETH[commitment] = usdAmount | (1 << 255); // Set high bit to indicate USD
        
        emit BidCommitted(msg.sender, commitment, usdAmount);
    }
    
    /// @notice Reveal a committed bid
    /// @dev Must wait REVEAL_DELAY blocks to prevent block manipulation
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    /// @param nonce Random value used in commitment
    function revealBid(uint pricePerShare, bool isYes, uint nonce) external nonReentrant {
        bytes32 commitment = keccak256(abi.encode(msg.sender, pricePerShare, isYes, nonce));
        
        require(commitments[commitment] > 0, "Invalid commitment");
        require(block.number >= commitments[commitment] + REVEAL_DELAY, "Too early to reveal");
        require(block.number <= commitments[commitment] + 256, "Too late to reveal"); // Within 256 blocks
        
        uint storedAmount = committedETH[commitment];
        delete commitments[commitment];
        delete committedETH[commitment];
        
        // Check if this was a USD commit (high bit set)
        bool isUSD = (storedAmount >> 255) == 1;
        
        if (isUSD) {
            // Clear the high bit to get actual USD amount
            uint usdAmount = storedAmount & ((1 << 255) - 1);
            _processBidInternalUSD(msg.sender, usdAmount, pricePerShare, isYes, true);
            emit BidRevealed(msg.sender, usdAmount, pricePerShare, isYes);
        } else {
            // ETH commit - process normally
            _processBidInternal(msg.sender, storedAmount, pricePerShare, isYes, true);
            emit BidRevealed(msg.sender, storedAmount * 3000, pricePerShare, isYes);
        }
    }
    
    /// @notice Place a Belgian auction bid with ETH at your confidence level
    /// @dev Main entry point for regular bids, enforces commit-reveal for large amounts
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    function placePredictionBid(uint pricePerShare, bool isYes) public payable nonReentrant {
        require(!bettingWindowClosed, "Betting closed");
        require(!predictionConfig.resolved, "Already resolved");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        require(msg.value > 0, "No ETH sent");
        
        // Large bids should use commit-reveal
        require(msg.value < COMMIT_REVEAL_THRESHOLD_ETH, "Use commitBid for large amounts");
        
        _updateEpochIfNeeded();
        
        _processBidInternal(msg.sender, msg.value, pricePerShare, isYes, false);
    }
    
    /// @notice Place a bid with stablecoin or vault token
    /// @dev Alternative to ETH bidding for stablecoin users
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    /// @param token Token to use for payment
    /// @param amount Amount of token to use
    function placePredictionBidWithToken(
        uint pricePerShare,
        bool isYes,
        address token,
        uint amount
    ) external nonReentrant {
        require(!bettingWindowClosed, "Betting closed");
        require(!predictionConfig.resolved, "Already resolved");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        
        // Deposit token and get USD value
        uint usdAmount = Basket(params.basket).deposit(msg.sender, token, amount);
        require(usdAmount >= MIN_BET_USD, "Below minimum USD");
        
        // Large USD bids should use commit-reveal
        require(usdAmount < COMMIT_REVEAL_THRESHOLD_USD, "Use commitBidWithToken for large amounts");
        
        _updateEpochIfNeeded();
        
        _processBidInternalUSD(msg.sender, usdAmount, pricePerShare, isYes, false);
    }
    
    /// @notice Internal function to process ETH bids
    /// @dev Handles participant tracking, gas fees, swap to USD, and bid creation
    /// @param bidder Address placing the bid
    /// @param ethAmount ETH amount sent
    /// @param pricePerShare Confidence level (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    /// @param skipFairPrice Whether to skip fair price check (for commit-reveal)
    function _processBidInternal(
        address bidder,
        uint ethAmount,
        uint pricePerShare,
        bool isYes,
        bool skipFairPrice
    ) internal {
        // Check if epoch is full
        require(epochs[currentEpochIndex].totalBids < MAX_BIDS_PER_EPOCH, "Epoch full");
        
        // Track participant
        _addParticipant(bidder);
        
        // Calculate dynamic gas fee based on velocity
        uint dynamicFeeBps = calculateDynamicGasFee(bidder);
        uint gasContribution = (ethAmount * dynamicFeeBps) / 10000;
        uint actualBetETH = ethAmount - gasContribution;
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
        
        // MEV Protection: Enforce fair pricing (skip for commit-reveal bids)
        if (!skipFairPrice && epochs[currentEpochIndex].totalBids > 0) {
            uint fairPrice = calculateFairPrice(currentEpochIndex);
            require(pricePerShare >= fairPrice, "Price below fair value");
        }
        
        // Update epoch price bounds
        if (epochMinPrice[currentEpochIndex] == 0 || pricePerShare < epochMinPrice[currentEpochIndex]) {
            epochMinPrice[currentEpochIndex] = pricePerShare;
        }
        if (pricePerShare > epochMaxPrice[currentEpochIndex]) {
            epochMaxPrice[currentEpochIndex] = pricePerShare;
        }
        
        // Anti-sniping check
        _checkEpochExtension(currentEpochIndex);
        
        // Create bid
        uint bidId = nextBidId++;
        allBids[bidId] = Bid({
            bidder: bidder,
            usdAmount: usdReceived,
            pricePerShare: pricePerShare,
            sharesRequested: sharesRequested,
            sharesAllocated: 0,
            epochIndex: currentEpochIndex,
            timestamp: block.timestamp,
            isYes: isYes,
            processed: false
        });
        
        // Add to epoch's sorted set immediately
        uint sortKey = (type(uint).max - pricePerShare) << 32 | bidId;
        epochs[currentEpochIndex].sortedBidIds.insert(sortKey);
        epochs[currentEpochIndex].totalBids++;
        
        userBidIds[bidder].push(bidId);
        
        // Update gas collection
        epochs[currentEpochIndex].totalGasCollected += gasContribution;
        totalGasFeesCollected += gasContribution;
        
        emit BidPlaced(bidder, usdReceived, pricePerShare, isYes, currentEpochIndex, bidId);
    }
    
    /// @notice Pro-rata allocation to prevent gaming
    /// @dev Ensures bids at same price get proportional shares, not first-come-first-served
    /// @param epochIndex The epoch to allocate shares for
    function _allocateProRata(uint epochIndex) internal {
        Epoch storage epoch = epochs[epochIndex];
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        
        // Group bids by price tier
        uint currentPrice = type(uint).max;
        uint tierStartIndex = 0;
        
        for (uint i = 0; i <= sortedKeys.length; i++) {
            bool lastIteration = (i == sortedKeys.length);
            uint bidPrice = lastIteration ? 0 : (type(uint).max - (sortedKeys[i] >> 32));
            
            // Process tier when price changes or at end
            if (bidPrice != currentPrice || lastIteration) {
                if (i > tierStartIndex) {
                    _allocateTier(epochIndex, sortedKeys, tierStartIndex, i - 1);
                }
                currentPrice = bidPrice;
                tierStartIndex = i;
            }
        }
    }
    
    /// @notice Allocate shares within a price tier pro-rata
    /// @dev Core Belgian auction logic - same price = same treatment
    /// @param epochIndex The epoch being allocated
    /// @param sortedKeys Array of sorted bid keys
    /// @param startIndex Start of this price tier
    /// @param endIndex End of this price tier
    function _allocateTier(
        uint epochIndex,
        uint[] memory sortedKeys,
        uint startIndex,
        uint endIndex
    ) internal {
        Epoch storage epoch = epochs[epochIndex];
        uint sharesRemaining = epoch.sharesAvailable - epoch.sharesAllocated;
        if (sharesRemaining == 0) return;
        
        // Calculate total demand in this price tier
        uint tierDemand = 0;
        for (uint i = startIndex; i <= endIndex; i++) {
            uint bidId = uint32(sortedKeys[i]);
            Bid storage bid = allBids[bidId];
            if (!bid.processed) {
                tierDemand += bid.sharesRequested;
            }
        }
        
        if (tierDemand == 0) return;
        
        // If tier demand is less than remaining shares, everyone gets full allocation
        if (tierDemand <= sharesRemaining) {
            for (uint i = startIndex; i <= endIndex; i++) {
                uint bidId = uint32(sortedKeys[i]);
                Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    bid.sharesAllocated = bid.sharesRequested;
                    epoch.sharesAllocated += bid.sharesRequested;
                    bid.processed = true;
                }
            }
        } else {
            // Pro-rata allocation since oversubscribed
            for (uint i = startIndex; i <= endIndex; i++) {
                uint bidId = uint32(sortedKeys[i]);
                Bid storage bid = allBids[bidId];
                if (!bid.processed) {
                    uint allocation = (bid.sharesRequested * sharesRemaining) / tierDemand;
                    bid.sharesAllocated = allocation;
                    epoch.sharesAllocated += allocation;
                    bid.processed = true;
                }
            }
        }
    }
    
    /// @notice Internal function to process USD bids (from stablecoins)
    /// @dev Similar to ETH processing but without gas fees or swaps
    /// @param bidder Address placing the bid
    /// @param usdAmount USD amount already in Basket
    /// @param pricePerShare Confidence level (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    /// @param skipFairPrice Whether to skip fair price check
    function _processBidInternalUSD(
        address bidder,
        uint usdAmount,
        uint pricePerShare,
        bool isYes,
        bool skipFairPrice
    ) internal {
        // Check if epoch is full
        require(epochs[currentEpochIndex].totalBids < MAX_BIDS_PER_EPOCH, "Epoch full");
        
        // Track participant
        _addParticipant(bidder);
        
        // For USD bids, no gas fee since they're not using ETH
        // Calculate shares at their price
        uint sharesRequested = (usdAmount * 1e18) / pricePerShare;
        
        // MEV Protection: Enforce fair pricing (skip for commit-reveal bids)
        if (!skipFairPrice && epochs[currentEpochIndex].totalBids > 0) {
            uint fairPrice = calculateFairPrice(currentEpochIndex);
            require(pricePerShare >= fairPrice, "Price below fair value");
        }
        
        // Update epoch price bounds
        if (epochMinPrice[currentEpochIndex] == 0 || pricePerShare < epochMinPrice[currentEpochIndex]) {
            epochMinPrice[currentEpochIndex] = pricePerShare;
        }
        if (pricePerShare > epochMaxPrice[currentEpochIndex]) {
            epochMaxPrice[currentEpochIndex] = pricePerShare;
        }
        
        // Anti-sniping check
        _checkEpochExtension(currentEpochIndex);
        
        // Create bid
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
        
        // Add to epoch's sorted set immediately
        uint sortKey = (type(uint).max - pricePerShare) << 32 | bidId;
        epochs[currentEpochIndex].sortedBidIds.insert(sortKey);
        epochs[currentEpochIndex].totalBids++;
        
        userBidIds[bidder].push(bidId);
        
        // No gas collection for USD bids
        
        emit BidPlaced(bidder, usdAmount, pricePerShare, isYes, currentEpochIndex, bidId);
    }
    
    /// @notice Place bid with content (for rap battles)
    /// @dev Requires authorized submitter and content submission before deadline
    /// @param pricePerShare Your confidence level
    /// @param isYes True for backing first submitter
    /// @param contentURI IPFS URI of submitted content
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
    
    // ============ Belgian Auction Clearing with Gas Compensation ============
    
    /// @notice Clear epoch with pro-rata allocation for same price tiers
    /// @dev Anyone can call this after epoch ends to earn gas compensation
    /// @param epochIndex The epoch to clear
    function clearEpoch(uint epochIndex) external nonReentrant {
        Epoch storage epoch = epochs[epochIndex];
        require(!epoch.cleared, "Already cleared");
        
        // Check if epoch has ended based on time OR if it's a past epoch
        require(
            block.timestamp >= epoch.endTime || 
            epochIndex < currentEpochIndex || 
            bettingWindowClosed, 
            "Epoch not ended"
        );
        
        uint gasStart = gasleft();
        
        // Use pro-rata allocation to prevent gaming
        _allocateProRata(epochIndex);
        
        // Process all allocations and mint tokens
        uint[] memory sortedKeys = epoch.sortedBidIds.getSortedSet();
        uint totalUSDUsed = 0;
        
        // Store refunds to process after iteration
        address[] memory refundRecipients = new address[](sortedKeys.length);
        uint[] memory refundAmounts = new uint[](sortedKeys.length);
        uint refundCount = 0;
        
        for (uint i = 0; i < sortedKeys.length; i++) {
            uint bidId = uint32(sortedKeys[i]);
            Bid storage bid = allBids[bidId];
            
            if (bid.sharesAllocated > 0) {
                // Calculate actual USD used
                uint usdUsed = (bid.sharesAllocated * bid.pricePerShare) / 1e18;
                
                // Update user shares
                if (bid.isYes) {
                    predictionConfig.userYesShares[bid.bidder] += bid.sharesAllocated;
                    predictionConfig.totalYesShares += bid.sharesAllocated;
                } else {
                    predictionConfig.userNoShares[bid.bidder] += bid.sharesAllocated;
                    predictionConfig.totalNoShares += bid.sharesAllocated;
                }
                
                // Update weighted average strike price
                _updateUserStrikePrice(bid.bidder, bid.pricePerShare, bid.sharesAllocated);
                
                // Track totals
                totalUSDUsed += usdUsed;
                
                // Mint ERC20 tokens only (no NFTs due to high units value)
                _mintERC20(bid.bidder, bid.sharesAllocated);
                
                // Store refund info for partial fills
                if (bid.sharesAllocated < bid.sharesRequested) {
                    uint usdRefund = bid.usdAmount - usdUsed;
                    if (usdRefund > 0) {
                        refundRecipients[refundCount] = bid.bidder;
                        refundAmounts[refundCount] = usdRefund;
                        refundCount++;
                    }
                }
            } else if (bid.processed) {
                // Full refund for bids that couldn't allocate
                refundRecipients[refundCount] = bid.bidder;
                refundAmounts[refundCount] = bid.usdAmount;
                refundCount++;
            }
        }
        
        epoch.cleared = true;
        epoch.clearer = msg.sender;
        predictionConfig.totalPoolUSD += totalUSDUsed;
        
        // Process refunds after all state changes
        for (uint i = 0; i < refundCount; i++) {
            if (refundAmounts[i] > 0) {
                Basket(params.basket).mint(refundRecipients[i], refundAmounts[i], address(params.basket), 0);
            }
        }
        
        // Gas compensation
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
                
                (bool success1,) = msg.sender.call{value: clearerShare}("");
                (bool success2,) = protocolTreasury.call{value: treasuryShare}("");
                require(success1 && success2, "Fee distribution failed");
            }
        }
        
        emit EpochCleared(epochIndex, epoch.sharesAllocated, msg.sender, compensation);
    }
    
    /// @notice Update user's weighted average strike price
    /// @dev Tracks average entry price for analytics and potential future features
    /// @param user User address
    /// @param newPrice Price of new shares
    /// @param newShares Number of new shares
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
    
    /// @notice Burn ERC20 tokens without NFT logic
    /// @dev Simplified burn since units = 1e18 prevents NFT minting
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function _burnERC20Only(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        // Just burn ERC20 tokens
        balanceOf[from] -= amount;
        totalSupply -= amount;
        
        emit ERC20Events.Transfer(from, address(0), amount);
    }
    
    // ============ Resolution & Payouts ============
    
    /// @notice Calculate user's payout
    /// @dev Winners get proportional share of total pool based on their shares
    /// @param user User address to calculate payout for
    /// @return payoutUSD Amount user can claim in USD (6909 tokens)
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
    /// @dev Burns user's shares and mints 6909 tokens as payout
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
    /// @dev Returns proportional share of pool when market is cancelled
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
    
    /// @notice Receive ruling from Settlement contract
    /// @dev Implements IArbitrable interface for modular dispute resolution
    /// @param _disputeID ID of the dispute being ruled on
    /// @param _ruling The ruling (0=NO, 1=YES, 2=Force Majeur)
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
    
    /// @notice Add participant for jury pool tracking
    /// @dev Critical for fair jury selection in dispute resolution
    /// @param participant Address to add to participant list
    function _addParticipant(address participant) internal {
        if (!hasParticipated[participant]) {
            hasParticipated[participant] = true;
            participants.push(participant);
            participantCount++;
            emit ParticipantAdded(participant);
        }
    }
    
    /// @notice Update epoch if time has passed
    /// @dev Automatically transitions to next epoch or closes betting window
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
    
    /// @notice Start a new epoch with decaying share availability
    /// @dev Each epoch has 10% fewer shares to create scarcity
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
    
    /// @notice Get current epoch information
    /// @dev Provides real-time market state for UIs
    /// @return index Current epoch number
    /// @return currentPrice Implied price based on demand
    /// @return timeRemaining Seconds until epoch ends
    /// @return bidCount Number of bids in epoch
    /// @return isActive Whether epoch accepts bids
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
    
    /// @notice Get user's position in the market
    /// @dev Shows shares held and potential payout
    /// @param user User address to query
    /// @return yesShares Number of YES shares held
    /// @return noShares Number of NO shares held
    /// @return total404Tokens Total ERC404 tokens held
    /// @return estimatedPayout Payout if resolved now
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
    
    /// @notice Get all participants (for jury selection)
    /// @dev Critical for Settlement contract's jury selection
    /// @return Array of all participant addresses
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }
    
    /// @notice Get participant count
    /// @return Number of unique participants
    function getParticipantCount() external view returns (uint) {
        return participantCount;
    }
    
    /// @notice Get prediction market summary
    /// @dev High-level market state for UIs
    /// @return question The prediction question
    /// @return totalYesShares Total YES shares minted
    /// @return totalNoShares Total NO shares minted
    /// @return totalPoolUSD Total USD in pool
    /// @return impliedProbability YES probability (0-100)
    /// @return resolved Whether market is resolved
    /// @return outcome Final outcome if resolved
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
    
    /// @notice Get full prediction configuration
    /// @dev Detailed market parameters
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
    
    /// @notice Get bid details
    /// @param bidId The bid ID to query
    /// @return bidder Address who placed bid
    /// @return usdAmount USD value of bid
    /// @return pricePerShare Confidence level
    /// @return sharesAllocated Shares received
    /// @return isYes Side of bet
    /// @return processed Whether bid was processed
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
    
    /// @notice Get user's bid IDs
    /// @param user User address
    /// @return Array of bid IDs for user
    function getUserBidIds(address user) external view returns (uint[] memory) {
        return userBidIds[user];
    }
    
    /// @notice Get content submissions for content markets
    /// @return submitters Array of submitter addresses
    /// @return Array of content URIs
    function getContentSubmissions() external view returns (address[] memory submitters, string[] memory) {
        uint len = predictionConfig.contentSubmitters.length;
        string[] memory submissions = new string[](len);
        
        for (uint i = 0; i < len; i++) {
            submissions[i] = predictionConfig.contentSubmissions[predictionConfig.contentSubmitters[i]];
        }
        
        return (predictionConfig.contentSubmitters, submissions);
    }
    
    /// @notice Get epoch details
    /// @param index Epoch index to query
    /// @return startTime When epoch started
    /// @return endTime When epoch ends
    /// @return sharesAvailable Total shares in epoch
    /// @return sharesAllocated Shares already allocated
    /// @return totalBids Number of bids
    /// @return totalGasCollected Gas fees collected
    /// @return cleared Whether epoch is cleared
    /// @return gasCompensated Whether gas was compensated
    /// @return clearer Address that cleared epoch
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
    
    /// @notice Enable force majeur refunds for content markets
    /// @dev Allows refunds if content requirements not met
    function enableContentRefunds() external {
        require(predictionConfig.requiresContent, "Not content market");
        require(block.timestamp > predictionConfig.contentDeadline, "Deadline not passed");
        require(contentSubmissionCount < 2, "Requirements met");
        require(!forceMajeurRefunds, "Already enabled");
        
        forceMajeurRefunds = true;
        emit ForceMajeurDeclared();
    }
    
    // ============ ERC404 tokenURI Implementation ============
    
    /// @notice Return empty URI since NFTs are disabled
    /// @dev Required by ERC404 but unused due to high units value
    /// @param id Token ID (unused)
    /// @return Empty string
    function tokenURI(uint256 id) public view override returns (string memory) {
        return string('');
    }
    
    // ============ Receive ETH ============
    
    /// @notice Accept ETH for gas fees
    /// @dev Allows contract to receive gas compensation
    receive() external payable {
        // Accept ETH for gas fees
    }
}