// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Auction.sol";
import "./AuctionFactory.sol";
import "./AuctionFactoryLib.sol";
import "./Settlement.sol";
import "./Basket.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AuctionHelpers - Simplified UX for Social Betting Platform
/// @notice Helper functions for easy interaction with Belgian auction prediction markets
/// @dev Provides user-friendly interfaces for betting, content submission, and payout claims
contract AuctionHelpers {
    using Math for uint;
    
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
        uint epochSharesRemaining;   // Shares left in current epoch
        uint minimumPriceFor10Percent; // Min price to get 10% of epoch
    }
    
    struct UserPosition {
        uint yesShares;              // User's YES position
        uint noShares;               // User's NO position
        uint total404Tokens;         // Total ERC404 tokens held
        uint estimatedPayout;        // Estimated payout if current outcome
        bool canClaimPayout;         // If resolved and user won
        bool canClaimRefund;         // If force majeur declared
        uint avgStrikePrice;         // User's weighted average entry price
    }
    
    struct BettingAdvice {
        bool isGoodTiming;           // Based on price and activity
        string reason;               // Explanation
        uint suggestedAmount;        // For desired position size
        uint expectedTokens;         // Tokens they'd receive
        uint minimumPrice;           // Minimum price for their allocation
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
    
    /// @notice Place bet with content submission (for rap battles)
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
    /// @param convertAmount Amount to convert (in basket tokens)
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
        require(hoursToRespond >= 24 && hoursToRespond <= 168, "Must be 1-7 days");
        
        AuctionFactoryLib.LaunchConfig memory config = AuctionFactoryLib.LaunchConfig({
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
            uint index,
            uint currentPrice,
            uint timeRemaining,
            , // bidCount
            bool isActive
        ) = auction.getCurrentEpochInfo();
        
        // For simplified view, we'll estimate shares remaining
        // In the new architecture, this would need to be exposed via a getter
        uint epochSharesRemaining = 1000e18; // Placeholder
        uint minimumPriceFor10Percent = currentPrice + 0.1e18; // Simplified calculation
        
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
            outcome: outcome,
            epochSharesRemaining: epochSharesRemaining,
            minimumPriceFor10Percent: minimumPriceFor10Percent
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
        
        // Calculate average price estimation
        uint avgPrice = 0;
        if (yesShares > 0 || noShares > 0) {
            // Estimate based on market totals
            (, uint totalYes, uint totalNo, uint totalPool, , , ) = auction.getPredictionSummary();
            if (totalYes + totalNo > 0) {
                avgPrice = (totalPool * 1e18) / (totalYes + totalNo);
            }
        }
        
        return UserPosition({
            yesShares: yesShares,
            noShares: noShares,
            total404Tokens: total404Tokens,
            estimatedPayout: estimatedPayout,
            canClaimPayout: canClaimPayout,
            canClaimRefund: canClaimRefund,
            avgStrikePrice: avgPrice
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
                expectedTokens: 0,
                minimumPrice: 0
            });
        }
        
        // Calculate tokens at current price
        uint tokensExpected = (desiredPositionUSD * 1e18) / currentPrice;
        uint ethNeeded = (desiredPositionUSD * 1e18) / 3000e18; // Assume $3000 ETH
        
        // Analyze timing
        bool isGoodTiming = true;
        string memory reason;
        
        if (timeRemaining < 5 minutes) {
            isGoodTiming = false;
            reason = "Epoch ending soon - wait for next epoch with fresh shares";
        } else if (currentPrice > 0.8e18) {
            isGoodTiming = false;
            reason = "High current price - consider waiting for better entry";
        } else if (bidCount < 5) {
            isGoodTiming = true;
            reason = "Early in epoch with good availability";
        } else {
            isGoodTiming = true;
            reason = "Reasonable entry conditions";
        }
        
        return BettingAdvice({
            isGoodTiming: isGoodTiming,
            reason: reason,
            suggestedAmount: ethNeeded,
            expectedTokens: tokensExpected,
            minimumPrice: currentPrice
        });
    }
    
    /// @notice Check market health
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
            // Calculate activity score
            activityScore = Math.min(100, (totalPoolUSD / 1000e18) * 20 + (bidCount * 5));
            
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
        }
        
        // Resize warnings array
        warnings = new string[](warningCount);
        for (uint i = 0; i < warningCount; i++) {
            warnings[i] = warningsList[i];
        }
    }
    
    /// @notice Get optimal bidding strategy based on market state
    /// @param auction The prediction market contract
    /// @param budget User's total budget in ETH
    /// @param targetSide True for YES, false for NO
    function getOptimalStrategy(
        Auction auction,
        uint budget,
        bool targetSide
    ) external view returns (
        uint recommendedPrice,
        uint recommendedEpoch,
        string memory strategy
    ) {
        (uint currentEpoch, uint currentPrice, , , ) = auction.getCurrentEpochInfo();
        
        // Calculate USD from ETH budget
        uint budgetUSD = budget * 3000; // Assuming $3000/ETH
        
        if (currentPrice > 0.7e18) {
            recommendedEpoch = currentEpoch + 1;
            recommendedPrice = 0.1e18; // Low price for next epoch
            strategy = "Wait for next epoch - current price too high";
        } else if (currentPrice < 0.3e18) {
            recommendedEpoch = currentEpoch;
            recommendedPrice = 0.05e18; // Very low price early
            strategy = "Bid now at low price - good entry point";
        } else {
            recommendedEpoch = currentEpoch;
            recommendedPrice = currentPrice + 0.1e18; // Slightly above current
            strategy = "Bid slightly above current price for better fill probability";
        }
    }
}