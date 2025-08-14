// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./AuctionFactory.sol";
import "./Settlement.sol";
import "./Basket.sol";

/// @title AuctionHelpers - Simplified UX for Social Betting Platform
/// @notice Helper functions for easy interaction with Belgian auction prediction markets
/// @dev Provides user-friendly interfaces for betting, content submission, and payout claims
contract AuctionHelpers {
    
    AuctionFactory public immutable factory;
    Settlement public immutable settlement;
    Basket public immutable basket;
    
    // ============ Structs for View Functions ============
    
    struct SimpleMarketView {
        string question;
        uint currentPrice;           // Current epoch price in USD
        uint timeRemaining;          // Time left in current epoch
        uint totalYesShares;
        uint totalNoShares;
        uint totalPoolUSD;
        uint impliedProbability;     // 0-100 (YES probability based on stakes)
        bool isActive;               // Can still place bets
        bool isResolved;
        bool outcome;                // Final result if resolved
    }
    
    struct UserPosition {
        uint yesShares;              // User's YES position
        uint noShares;               // User's NO position
        uint total404Tokens;         // Total ERC404 tokens held
        uint estimatedPayout;        // Estimated payout if current outcome
        bool canClaimPayout;         // If resolved and user won
        bool canClaimRefund;         // If force majeur declared
    }
    
    struct BettingAdvice {
        bool isGoodTiming;           // Based on price and activity
        string reason;               // Explanation
        uint suggestedAmount;        // For desired position size
        uint expectedTokens;         // Tokens they'd receive
    }
    
    // ============ Constructor ============
    
    constructor(address _factory, address _settlement, address _basket) {
        factory = AuctionFactory(_factory);
        settlement = Settlement(_settlement);
        basket = Basket(_basket);
    }
    
    // ============ Simple Betting Functions ============
    
    /// @notice Place a simple YES bet on prediction market
    /// @param auction The prediction market contract
    /// @dev User just sends ETH, system handles conversion and token allocation
    function betYes(Auction auction) external payable {
        // Default to 100% confidence (1.0)
        auction.placePredictionBid{value: msg.value}(1e18, true);
    }
    
    /// @notice Place a simple NO bet on prediction market  
    /// @param auction The prediction market contract
    function betNo(Auction auction) external payable {
        // Default to 100% confidence (1.0)
        auction.placePredictionBid{value: msg.value}(1e18, false);
    }
    
    /// @notice Place YES bet with slippage protection
    /// @param auction The prediction market contract
    /// @param maxPricePerShare Maximum price willing to pay per share
    function betYesWithSlippage(Auction auction, uint maxPricePerShare) external payable {
        (, uint currentPrice, , , ) = auction.getCurrentEpochInfo();
        require(currentPrice <= maxPricePerShare, "Price too high");
        auction.placePredictionBid{value: msg.value}(maxPricePerShare, true);
    }
    
    /// @notice Place NO bet with slippage protection
    /// @param auction The prediction market contract
    /// @param maxPricePerShare Maximum price willing to pay per share
    function betNoWithSlippage(Auction auction, uint maxPricePerShare) external payable {
        (, uint currentPrice, , , ) = auction.getCurrentEpochInfo();
        require(currentPrice <= maxPricePerShare, "Price too high");
        auction.placePredictionBid{value: msg.value}(maxPricePerShare, false);
    }
    
    /// @notice Place bet with content submission (for rap battles, etc.)
    /// @param auction The prediction market contract
    /// @param pricePerShare Your confidence level (0.01 to 1.00)
    /// @param isYes True for YES bet, false for NO bet
    /// @param contentURI IPFS link to submitted content
    function betWithContent(
        Auction auction,
        uint pricePerShare,
        bool isYes,
        string calldata contentURI
    ) external payable {
        auction.placePredictionBidWithContent{value: msg.value}(pricePerShare, isYes, contentURI);
    }
    
    /// @notice Quick bet with automatic amount suggestion
    /// @param auction The prediction market contract
    /// @param pricePerShare Your confidence level (0.01 to 1.00)  
    /// @param isYes True for YES bet, false for NO bet
    /// @param desiredUSDAmount How much USD worth of position they want
    function betWithUSDTarget(
        Auction auction,
        uint pricePerShare,
        bool isYes,
        uint desiredUSDAmount
    ) external payable {
        // Calculate required ETH based on desired USD
        // Assume $3000/ETH for estimation (in production, use oracle)
        uint ethNeeded = (desiredUSDAmount * 1e18) / 3000e18;
        
        require(msg.value >= ethNeeded, "Insufficient ETH for desired USD amount");
        
        auction.placePredictionBid{value: msg.value}(pricePerShare, isYes);
    }
    
    // ============ Payout & Claim Functions ============
    
    /// @notice Claim all available rewards (auto-detects type)
    /// @param auction The prediction market contract
    function claimAll(Auction auction) external {
        // Try to claim prediction payout
        try auction.claimPredictionPayout() {
            return; // Successfully claimed normal payout
        } catch {
            // Try to claim force majeur refund
            try auction.claimForceMajeurRefund() {
                return; // Successfully claimed refund
            } catch {
                revert("Nothing to claim");
            }
        }
    }
    
    /// @notice Claim payout and immediately convert some to different token
    /// @param auction The prediction market contract  
    /// @param convertToToken Token to convert some payout to (empty for no conversion)
    /// @param convertAmount Amount to convert (in 6909 tokens)
    function claimAndConvert(
        Auction auction,
        address convertToToken,
        uint convertAmount
    ) external {
        // Claim the payout first
        auction.claimPredictionPayout();
        
        // Convert if requested
        if (convertToToken != address(0) && convertAmount > 0) {
            require(basket.balanceOf(msg.sender, 0) >= convertAmount, "Insufficient balance for conversion");
            basket.take(msg.sender, convertAmount, convertToToken, false);
        }
    }
    
    // ============ Market Creation Helpers ============
    
    /// @notice Create simple prediction market with sensible defaults
    /// @param question The prediction question
    /// @param daysUntilResolution How many days until outcome can be determined
    function createSimplePrediction(
        string memory question,
        uint daysUntilResolution
    ) external returns (address) {
        return factory.deploySimplePrediction(question, daysUntilResolution);
    }
    
    /// @notice Create rap battle with automatic configuration
    /// @param challenger Your username/name
    /// @param challenged Person you're challenging
    /// @param hoursToRespond How many hours they have to submit content
    function createRapBattle(
        string memory challenger,
        string memory challenged,
        uint hoursToRespond
    ) external returns (address) {
        require(hoursToRespond >= 24 && hoursToRespond <= 168, "Must be 1-7 days"); // 24 hours to 7 days
        
        AuctionFactory.LaunchConfig memory config = AuctionFactory.LaunchConfig({
            name: string(abi.encodePacked("RAP: ", challenger, " vs ", challenged)),
            symbol: "RAP",
            initialPricePerToken: 50e18,  // $50 starting price for rap battles
            auctionDuration: 24 hours     // 24-hour betting window
        });
        
        uint responseDeadline = block.timestamp + (hoursToRespond * 1 hours);
        
        return factory.deployRapBattleMarket(challenger, challenged, responseDeadline, config);
    }
    
    // ============ Information & Analysis Functions ============
    
    /// @notice Get simple market overview
    /// @param auction The prediction market contract
    function getMarketOverview(Auction auction) external view returns (SimpleMarketView memory) {
        // Get prediction summary
        (
            string memory question,
            uint totalYesShares,
            uint totalNoShares,
            uint totalPoolUSD,
            uint impliedProbability,
            bool isResolved,
            bool outcome
        ) = auction.getPredictionSummary();
        
        // Get current epoch info
        (
            , // index
            uint currentPrice,
            uint timeRemaining,
            , // bidCount
            bool isActive
        ) = auction.getCurrentEpochInfo();
        
        return SimpleMarketView({
            question: question,
            currentPrice: currentPrice,
            timeRemaining: timeRemaining,
            totalYesShares: totalYesShares,
            totalNoShares: totalNoShares,
            totalPoolUSD: totalPoolUSD,
            impliedProbability: impliedProbability,
            isActive: isActive,
            isResolved: isResolved,
            outcome: outcome
        });
    }
    
    /// @notice Get user's complete position
    /// @param auction The prediction market contract
    /// @param user User address to check
    function getUserPosition(Auction auction, address user) external view returns (UserPosition memory) {
        (
            uint yesShares,
            uint noShares,
            uint total404Tokens,
            uint estimatedPayout
        ) = auction.getUserPosition(user);
        
        // Check if resolved and what user can claim
        (, , , , , bool isResolved, bool outcome) = auction.getPredictionSummary();
        
        bool canClaimPayout = false;
        bool canClaimRefund = false;
        
        if (isResolved) {
            // Check for force majeur
            if (auction.forceMajeurRefunds()) {
                canClaimRefund = (yesShares + noShares) > 0;
            } else {
                // Normal resolution - check if user won
                if (outcome && yesShares > 0) canClaimPayout = true;
                if (!outcome && noShares > 0) canClaimPayout = true;
            }
        }
        
        return UserPosition({
            yesShares: yesShares,
            noShares: noShares,
            total404Tokens: total404Tokens,
            estimatedPayout: estimatedPayout,
            canClaimPayout: canClaimPayout,
            canClaimRefund: canClaimRefund
        });
    }
    
    /// @notice Get betting advice for current market conditions
    /// @param auction The prediction market contract
    /// @param desiredPositionUSD How much USD position they want
    function getBettingAdvice(
        Auction auction,
        uint desiredPositionUSD
    ) external view returns (BettingAdvice memory) {
        (, uint currentPrice, uint timeRemaining, uint bidCount, bool isActive) = auction.getCurrentEpochInfo();
        
        if (!isActive) {
            return BettingAdvice({
                isGoodTiming: false,
                reason: "Betting window closed",
                suggestedAmount: 0,
                expectedTokens: 0
            });
        }
        
        uint tokensExpected = desiredPositionUSD / currentPrice;
        uint ethNeeded = (desiredPositionUSD * 1e18) / 3000e18; // Assume $3000 ETH
        
        // Analyze timing
        bool isGoodTiming = true;
        string memory reason;
        
        if (timeRemaining < 5 minutes) {
            isGoodTiming = false;
            reason = "Epoch ending soon - wait for next epoch with lower price";
        } else if (bidCount < 2) {
            isGoodTiming = true;
            reason = "Good timing - early in epoch with low competition";
        } else if (bidCount > 10) {
            isGoodTiming = false;
            reason = "High competition in this epoch - consider waiting";
        } else {
            isGoodTiming = true;
            reason = "Reasonable timing for entry";
        }
        
        return BettingAdvice({
            isGoodTiming: isGoodTiming,
            reason: reason,
            suggestedAmount: ethNeeded,
            expectedTokens: tokensExpected
        });
    }
    
    /// @notice Calculate potential returns for a bet
    /// @param auction The prediction market contract
    /// @param betAmount Amount to bet in ETH
    /// @param pricePerShare Your confidence level
    /// @param betYesFlag True for YES bet, false for NO bet
    function calculatePotentialReturns(
        Auction auction,
        uint betAmount,
        uint pricePerShare,
        bool betYesFlag
    ) external view returns (
        uint tokensReceived,
        uint potentialPayout,
        uint returnPercentage,
        string memory scenario
    ) {
        // Convert ETH to approximate USD (simplified)
        uint usdAmount = betAmount * 3000e18 / 1e18; // Assume $3000 ETH
        tokensReceived = usdAmount / pricePerShare;
        
        // Get current market state
        (, uint totalYesShares, uint totalNoShares, uint totalPoolUSD, , , ) = auction.getPredictionSummary();
        
        // Simulate what pool would look like after this bet
        uint newTotalYes = totalYesShares;
        uint newTotalNo = totalNoShares;
        uint newTotalPool = totalPoolUSD + usdAmount;
        
        if (betYesFlag) {
            newTotalYes += tokensReceived;
            scenario = "If YES wins";
        } else {
            newTotalNo += tokensReceived;
            scenario = "If NO wins";
        }
        
        // Calculate potential payout
        if (betYesFlag && newTotalYes > 0) {
            potentialPayout = (tokensReceived * newTotalPool) / newTotalYes;
        } else if (!betYesFlag && newTotalNo > 0) {
            potentialPayout = (tokensReceived * newTotalPool) / newTotalNo;
        }
        
        // Calculate return percentage
        if (potentialPayout > usdAmount) {
            returnPercentage = ((potentialPayout - usdAmount) * 100) / usdAmount;
        }
    }
    
    /// @notice Check market health and activity
    /// @param auction The prediction market contract
    function getMarketHealth(Auction auction) external view returns (
        bool isHealthy,
        string memory status,
        uint activityScore,  // 0-100
        string[] memory warnings
    ) {
        (, , , uint totalPoolUSD, , bool isResolved, ) = auction.getPredictionSummary();
        (, , uint timeRemaining, uint bidCount, bool isActive) = auction.getCurrentEpochInfo();
        
        string[] memory warningsList = new string[](5);
        uint warningCount = 0;
        
        // Check if healthy
        isHealthy = true;
        status = "Active and healthy";
        
        if (isResolved) {
            status = "Resolved - check for payouts";
            activityScore = 0;
        } else if (!isActive) {
            status = "Betting window closed - awaiting resolution";
            activityScore = 0;
        } else {
            // Calculate activity score based on pool size and bid frequency
            activityScore = Math.min(100, (totalPoolUSD / 1000e18) * 20 + (bidCount * 5));
            
            // Generate warnings
            if (totalPoolUSD < 100e18) {
                warningsList[warningCount++] = "Low liquidity - small total pool";
                isHealthy = false;
            }
            
            if (bidCount == 0) {
                warningsList[warningCount++] = "No recent activity";
                isHealthy = false;
            }
            
            if (timeRemaining < 10 minutes) {
                warningsList[warningCount++] = "Epoch ending soon";
            }
            
            // Check for evidence submissions (potential disputes)
            (
                string memory name,
                string memory symbol,
                uint auctionDuration,
                uint totalEpochs,
                address owner,
                address settlementSystem,
                address rover,
                address aux,
                address basket
            ) = auction.params();
            try Settlement(settlementSystem).marketDispute(address(auction)) returns (uint disputeId) {
                if (disputeId > 0) {
                    warningsList[warningCount++] = "Active dispute - resolution may be delayed";
                }
            } catch {
                // No dispute
            }
        }
        
        // Resize warnings array
        warnings = new string[](warningCount);
        for (uint i = 0; i < warningCount; i++) {
            warnings[i] = warningsList[i];
        }
    }
    
    // ============ Batch Operations ============
    
    /// @notice Get overview of multiple markets
    /// @param auctions Array of prediction market contracts
    function getMultipleMarketOverviews(
        Auction[] calldata auctions
    ) external view returns (SimpleMarketView[] memory) {
        SimpleMarketView[] memory overviews = new SimpleMarketView[](auctions.length);
        
        for (uint i = 0; i < auctions.length; i++) {
            overviews[i] = this.getMarketOverview(auctions[i]);
        }
        
        return overviews;
    }
    
    /// @notice Claim from multiple markets in one transaction
    /// @param auctions Array of prediction market contracts to claim from
    function batchClaim(Auction[] calldata auctions) external {
        for (uint i = 0; i < auctions.length; i++) {
            try auctions[i].claimPredictionPayout() {
                // Successfully claimed
            } catch {
                try auctions[i].claimForceMajeurRefund() {
                    // Successfully claimed refund
                } catch {
                    // Nothing to claim from this market
                }
            }
        }
    }
    
    // ============ Utility Functions ============
    
    /// @notice Convert ETH amount to approximate USD for display
    /// @param ethAmount Amount in ETH
    /// @return Approximate USD value (assuming $3000 ETH)
    function ethToUSD(uint ethAmount) external pure returns (uint) {
        return ethAmount * 3000; // Simplified conversion
    }
    
    /// @notice Get all markets user has positions in
    /// @param user User address to check
    /// @return Markets where user has active positions
    function getUserActiveMarkets(address user) external view returns (address[] memory) {
        address[] memory allAuctions = factory.getAuctions();
        address[] memory activeMarkets = new address[](allAuctions.length);
        uint activeCount = 0;
        
        for (uint i = 0; i < allAuctions.length; i++) {
            Auction auction = Auction(payable(allAuctions[i]));
            (uint yesShares, uint noShares, , ) = auction.getUserPosition(user);
            
            if (yesShares > 0 || noShares > 0) {
                activeMarkets[activeCount++] = allAuctions[i];
            }
        }
        
        // Resize array to actual length
        address[] memory result = new address[](activeCount);
        for (uint i = 0; i < activeCount; i++) {
            result[i] = activeMarkets[i];
        }
        
        return result;
    }
    
    /// @notice Get implied probability from confidence betting
    /// @param auction The prediction market contract
    /// @return yesProb YES probability (0-100)
    /// @return noProb NO probability (0-100)
    function getImpliedProbabilities(Auction auction) external view returns (uint yesProb, uint noProb) {
        (, uint totalYesShares, uint totalNoShares, , , , ) = auction.getPredictionSummary();
        
        uint total = totalYesShares + totalNoShares;
        if (total > 0) {
            yesProb = (totalYesShares * 100) / total;
            noProb = (totalNoShares * 100) / total;
        } else {
            yesProb = 50;
            noProb = 50;
        }
    }
}