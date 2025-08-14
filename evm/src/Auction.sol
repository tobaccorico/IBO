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

/// @title Auction - Belgian Auction with ERC404 Integration
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
    bool public paused;
    AuctionParams public params;
    
    // Epoch management
    mapping(uint => Epoch) internal epochs;  // Changed from public to internal
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
    
    // ============ Events ============
    
    event BidPlaced(address indexed bidder, uint usdAmount, uint pricePerShare, bool isYes, uint epoch, uint bidId);
    event EpochCleared(uint indexed epoch, uint sharesAllocated, address clearer, uint gasCompensation);
    event BettingWindowClosed(uint totalEpochs);
    event PredictionResolved(bool outcome);
    event ForceMajeurDeclared();
    event PayoutClaimed(address indexed user, uint amount, bool wasForceMajeur);
    event ContentSubmitted(address indexed submitter, string contentURI);
    event ParticipantAdded(address indexed participant);
    event Paused();
    event Unpaused();
    
    // ============ Modifiers ============
    
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == params.owner, "Not owner");
        _;
    }
    
    // ============ Constructor & Initialization ============
    
    constructor() ERC404("", "", 18) {}
    
    function initialize(AuctionParams memory _params) external {
        require(!initialized, "Already initialized");
        initialized = true;
        
        params = _params;
        settlementSystem = Settlement(_params.settlementSystem);
        auxSystem = Aux(payable(_params.aux));
        
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
    ) external onlyOwner {
        require(resolutionTime_ > block.timestamp + params.auctionDuration, "Invalid resolution");
        
        predictionConfig.question = question_;
        predictionConfig.resolutionTime = resolutionTime_;
        predictionConfig.requiresContent = requiresContent_;
        predictionConfig.contentDeadline = contentDeadline_;
        predictionConfig.minParticipants = minParticipants_;
        metaEvidenceId = metaEvidenceId_;
    }
    
    // ============ Emergency Controls ============
    
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }
    
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }
    
    // ============ Core Belgian Auction Functions ============
    
    /// @notice Place a Belgian auction bid with ETH at your confidence level
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    function placePredictionBid(uint pricePerShare, bool isYes) external payable nonReentrant whenNotPaused {
        require(!bettingWindowClosed, "Betting closed");
        require(!predictionConfig.resolved, "Already resolved");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        require(msg.value > 0, "No ETH sent");
        
        _updateEpochIfNeeded();
        
        // Track participant
        _addParticipant(msg.sender);
        
        // Calculate gas contribution
        uint gasContribution = (msg.value * GAS_FEE_BPS) / 10000;
        uint actualBetETH = msg.value - gasContribution;
        require(actualBetETH > 0, "Too small after gas");
        
        // Swap ETH directly to Basket tokens via Aux
        // Pass address(Basket) as the token parameter to get 6909 tokens
        uint usdReceived = auxSystem.swap{value: actualBetETH}(
            address(params.basket),   // Get Basket tokens directly
            false,                    // Selling ETH
            actualBetETH,
            0
        );
        require(usdReceived >= MIN_BET_USD, "Below minimum USD");
        
        // Calculate shares at their price
        uint sharesRequested = (usdReceived * 1e18) / pricePerShare;
        
        // Create and store bid
        _createBid(msg.sender, usdReceived, pricePerShare, sharesRequested, isYes);
        
        // Update gas collection
        epochs[currentEpochIndex].totalGasCollected += gasContribution;
        totalGasFeesCollected += gasContribution;
    }
    
    /// @notice Place a Belgian auction bid with USD tokens
    /// @param token The USD token to use (must be accepted by Basket)
    /// @param amount Amount of tokens to bet
    /// @param pricePerShare Your confidence expressed as price (0.01 to 1.00)
    /// @param isYes True for YES side, false for NO side
    function placePredictionBidWithToken(
        address token,
        uint amount,
        uint pricePerShare,
        bool isYes
    ) external nonReentrant whenNotPaused {
        require(!bettingWindowClosed, "Betting closed");
        require(!predictionConfig.resolved, "Already resolved");
        require(pricePerShare >= 0.01e18 && pricePerShare <= 1e18, "Invalid price");
        require(Basket(params.basket).isStable(token) || Basket(params.basket).isVault(token), "Invalid token");
        
        _updateEpochIfNeeded();
        
        // Track participant
        _addParticipant(msg.sender);
        
        // Transfer tokens from user
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Deposit to Basket
        IERC20(token).approve(params.basket, amount);
        uint deposited = Basket(params.basket).deposit(address(this), token, amount);
        
        // Scale to 18 decimals if needed
        uint decimals = IERC20(token).decimals();
        if (decimals < 18) {
            deposited = deposited * 10**(18 - decimals);
        }
        
        require(deposited >= MIN_BET_USD, "Below minimum USD");
        
        // Calculate shares
        uint sharesRequested = (deposited * 1e18) / pricePerShare;
        
        // Create and store bid
        _createBid(msg.sender, deposited, pricePerShare, sharesRequested, isYes);
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
    
    /// @notice Place bid with content (for rap battles)
    function placePredictionBidWithContent(
        uint pricePerShare,
        bool isYes,
        string calldata contentURI
    ) external payable nonReentrant whenNotPaused {
        require(predictionConfig.requiresContent, "Content not required");
        require(block.timestamp <= predictionConfig.contentDeadline, "Content deadline passed");
        require(bytes(contentURI).length > 0, "Empty content");
        
        // Store content
        if (bytes(predictionConfig.contentSubmissions[msg.sender]).length == 0) {
            predictionConfig.contentSubmitters.push(msg.sender);
        }
        predictionConfig.contentSubmissions[msg.sender] = contentURI;
        
        emit ContentSubmitted(msg.sender, contentURI);
        
        // Place the bid
        this.placePredictionBid{value: msg.value}(pricePerShare, isYes);
    }
    
    // ============ Participant Tracking ============
    
    function _addParticipant(address participant) internal {
        if (!hasParticipated[participant]) {
            hasParticipated[participant] = true;
            participants.push(participant);
            participantCount++;
            emit ParticipantAdded(participant);
        }
    }
    
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }
    
    function getParticipantCount() external view returns (uint) {
        return participantCount;
    }
    
    // ============ Epoch Management ============
    
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
    
    // ============ Belgian Auction Clearing with Gas Compensation ============
    
    /// @notice Clear epoch with Belgian mechanics - highest bidders first
    /// @dev Caller gets gas compensation from collected fees
    function clearEpoch(uint epochIndex) external nonReentrant {
        Epoch storage epoch = epochs[epochIndex];
        require(!epoch.cleared, "Already cleared");
        require(epochIndex < currentEpochIndex || bettingWindowClosed, "Epoch not ended");
        
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
        
        // Store refunds to process after iteration (reentrancy protection)
        address[] memory refundRecipients = new address[](sortedKeys.length);
        uint[] memory refundAmounts = new uint[](sortedKeys.length);
        uint refundCount = 0;
        
        // Process in sorted order (highest price first)
        for (uint i = 0; i < sortedKeys.length && sharesRemaining > 0; i++) {
            uint bidId = uint32(sortedKeys[i]); // Extract bid ID from sort key
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
                
                // Mint ERC404 tokens
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
            }
        }
        
        epoch.cleared = true;
        epoch.clearer = msg.sender;
        epoch.sharesAllocated = totalSharesAllocated;
        predictionConfig.totalPoolUSD += totalUSDUsed;
        
        // Process refunds after all state changes (reentrancy protection)
        for (uint i = 0; i < refundCount; i++) {
            Basket(params.basket).mint(refundRecipients[i], refundAmounts[i], params.basket, 0);
        }
        
        // Gas compensation calculation
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
                
                // Send compensation
                (bool success,) = msg.sender.call{value: compensation}("");
                require(success, "Gas compensation failed");
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
    
    // ============ ERC404 Burn Helper ============
    
    /// @notice Internal function to burn ERC404 tokens
    /// @dev Handles both ERC20 and ERC721 portions of the burn
    function _burnERC404(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        // First handle any whole ERC721 tokens that need to be burned
        uint256 erc721sToBurn = amount / units;
        for (uint256 i = 0; i < erc721sToBurn; i++) {
            if (_owned[from].length > 0) {
                _withdrawAndStoreERC721(from);
            }
        }
        
        // Then burn the ERC20 portion
        // This reduces balance and totalSupply
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
        
        // Burn ERC404 tokens
        if (userShares > 0) {
            _burnERC404(msg.sender, userShares);
        }
        
        // Pay from Basket
        Basket(params.basket).mint(msg.sender, payoutUSD, params.basket, 0);
        
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
            _burnERC404(msg.sender, userTotalShares);
        }
        
        // Refund from Basket
        Basket(params.basket).mint(msg.sender, refundUSD, params.basket, 0);
        
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
    
    // ============ Content Market Functions ============
    
    /// @notice Enable refunds if content requirements not met
    function enableContentRefunds() external {
        require(predictionConfig.requiresContent, "Not content market");
        require(block.timestamp > predictionConfig.contentDeadline, "Deadline not passed");
        require(predictionConfig.contentSubmitters.length < predictionConfig.minParticipants, "Requirements met");
        require(!forceMajeurRefunds, "Already enabled");
        
        forceMajeurRefunds = true;
        emit ForceMajeurDeclared();
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
        isActive = !bettingWindowClosed && !epoch.cleared && !paused;
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
    
    // Add getter function for epochs
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
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Accept ETH for gas fees
    }
    
    // ============ ERC404 tokenURI Implementation ============
    
    function tokenURI(uint256 id) public view override returns (string memory) {
        return string('');
    }
}