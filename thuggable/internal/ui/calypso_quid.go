package ui

import (
	"context"
	"fmt"
	"math"
	"thuggable-go/internal/quid"
	
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"
	"github.com/shopspring/decimal"
)

// QuidRebalancer handles portfolio rebalancing using quid protocol
type QuidRebalancer struct {
	quidClient   *quid.Client
	rpcClient    *rpc.Client
	pythFeeds    map[string]solana.PublicKey
}

// RebalanceStrategy represents how to adjust positions
type RebalanceStrategy struct {
	Ticker           string
	CurrentExposure  decimal.Decimal
	TargetExposure   decimal.Decimal
	ExposureChange   decimal.Decimal
	CurrentPrice     decimal.Decimal
	RequiresAction   bool
}

// CalculateQuidRebalance determines exposure adjustments needed
func (bot *CalypsoBot) calculateQuidRebalance(
	positions map[string]decimal.Decimal,
	prices map[string]decimal.Decimal,
	totalValue decimal.Decimal,
) ([]RebalanceStrategy, error) {
	
	strategies := []RebalanceStrategy{}
	
	for asset, targetAllocation := range ASSETS {
		if asset == "USDC" {
			continue // Skip USDC as it's our collateral
		}
		
		// Current exposure value
		currentExposure := positions[asset].Mul(prices[asset])
		currentAllocation := currentExposure.Div(totalValue)
		
		// Target exposure value
		targetExposure := totalValue.Mul(targetAllocation.Allocation)
		
		// Calculate needed change
		exposureChange := targetExposure.Sub(currentExposure)
		allocationDiff := currentAllocation.Sub(targetAllocation.Allocation).Abs()
		
		// Only rebalance if difference exceeds threshold
		if allocationDiff.GreaterThan(bot.rebalanceThreshold) {
			strategy := RebalanceStrategy{
				Ticker:          asset,
				CurrentExposure: currentExposure,
				TargetExposure:  targetExposure,
				ExposureChange:  exposureChange,
				CurrentPrice:    prices[asset],
				RequiresAction:  true,
			}
			strategies = append(strategies, strategy)
			
			bot.logMessage(fmt.Sprintf(
				"%s: Current %.2f%% (Target %.2f%%) - Need to %s exposure by $%.2f",
				asset,
				currentAllocation.Mul(decimal.NewFromInt(100)).InexactFloat64(),
				targetAllocation.Allocation.Mul(decimal.NewFromInt(100)).InexactFloat64(),
				map[bool]string{true: "increase", false: "decrease"}[exposureChange.IsPositive()],
				exposureChange.Abs().InexactFloat64(),
			))
		}
	}
	
	return strategies, nil
}

// ExecuteQuidRebalance performs the rebalancing using quid
func (bot *CalypsoBot) executeQuidRebalance(strategies []RebalanceStrategy) error {
	if len(strategies) == 0 {
		bot.logMessage("No rebalancing needed")
		return nil
	}
	
	bot.logMessage(fmt.Sprintf("Executing %d exposure adjustments via Quid", len(strategies)))
	
	// Build withdraw instructions for each adjustment
	instructions := []solana.Instruction{}
	
	for _, strategy := range strategies {
		// Convert USD change to asset units
		assetUnits := strategy.ExposureChange.Div(strategy.CurrentPrice)
		
		// Convert to smallest units based on decimals
		asset := ASSETS[strategy.Ticker]
		smallestUnits := assetUnits.Mul(decimal.New(1, int32(asset.Decimals)))
		
		// Build withdraw instruction with exposure=true
		pythAccounts := []solana.PublicKey{}
		if pythFeed, exists := bot.pythPriceFeeds[strategy.Ticker]; exists {
			pythAccounts = append(pythAccounts, pythFeed)
		}
		
		instruction, err := bot.quidClient.BuildWithdrawInstruction(
			bot.fromAccount.PublicKey(),
			smallestUnits.IntPart(),
			strategy.Ticker,
			true, // exposure adjustment
			pythAccounts,
		)
		if err != nil {
			return fmt.Errorf("failed to build instruction for %s: %v", strategy.Ticker, err)
		}
		
		instructions = append(instructions, instruction)
		
		bot.logMessage(fmt.Sprintf(
			"Adjusting %s exposure by %.6f units ($%.2f)",
			strategy.Ticker,
			assetUnits.InexactFloat64(),
			strategy.ExposureChange.InexactFloat64(),
		))
	}
	
	// Get recent blockhash
	recent, err := bot.client.GetRecentBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return fmt.Errorf("failed to get blockhash: %v", err)
	}
	
	// Build transaction with all adjustments
	tx, err := solana.NewTransaction(
		instructions,
		recent.Value.Blockhash,
		solana.TransactionPayer(bot.fromAccount.PublicKey()),
	)
	if err != nil {
		return fmt.Errorf("failed to build transaction: %v", err)
	}
	
	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(bot.fromAccount.PublicKey()) {
			return bot.fromAccount
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to sign transaction: %v", err)
	}
	
	// Create tip transaction
	tipTx, err := bot.createTipTransaction()
	if err != nil {
		bot.logMessage(fmt.Sprintf("Warning: Failed to create tip transaction: %v", err))
		// Continue without tip
		tipTx = nil
	}
	
	// Send bundle
	var bundleID string
	if tipTx != nil {
		bundleID, err = bot.sendBundle([]*solana.Transaction{tx, tipTx})
	} else {
		// Send single transaction if tip failed
		sig, err := bot.client.SendTransaction(context.Background(), tx)
		if err == nil {
			bundleID = sig.String()
		}
	}
	
	if err != nil {
		return fmt.Errorf("failed to send transaction: %v", err)
	}
	
	bot.logMessage(fmt.Sprintf("Rebalancing transaction sent: %s", bundleID))
	return nil
}

// GetQuidPositions fetches current positions from quid
func (bot *CalypsoBot) getQuidPositions() (map[string]decimal.Decimal, error) {
	// This would fetch and decode the depositor account
	// For now, return mock data
	positions := map[string]decimal.Decimal{
		"SOL": decimal.NewFromFloat(10.5),
		"JTO": decimal.NewFromFloat(1000),
		"JUP": decimal.NewFromFloat(500),
		"JLP": decimal.NewFromFloat(100),
	}
	
	return positions, nil
}

// CheckPositionHealth verifies all positions are healthy before rebalancing
func (bot *CalypsoBot) checkPositionHealth(positions map[string]decimal.Decimal, prices map[string]decimal.Decimal) bool {
	// Calculate total exposure and collateral
	totalExposure := decimal.Zero
	
	for asset, position := range positions {
		if price, exists := prices[asset]; exists {
			exposure := position.Mul(price)
			totalExposure = totalExposure.Add(exposure.Abs())
		}
	}
	
	// Get available collateral (would come from depositor account)
	availableCollateral := decimal.NewFromFloat(10000) // Mock value
	
	// Check if we have sufficient collateral (with safety margin)
	utilizationRate := totalExposure.Div(availableCollateral)
	maxUtilization := decimal.NewFromFloat(0.8) // 80% max utilization
	
	if utilizationRate.GreaterThan(maxUtilization) {
		bot.logMessage(fmt.Sprintf(
			"Warning: High utilization rate %.2f%% - skipping rebalance",
			utilizationRate.Mul(decimal.NewFromInt(100)).InexactFloat64(),
		))
		return false
	}
	
	return true
}

// MonitorLiquidationRisk checks if any positions are at risk
func (bot *CalypsoBot) monitorLiquidationRisk(positions map[string]decimal.Decimal, prices map[string]decimal.Decimal) {
	for asset, position := range positions {
		if position.IsZero() {
			continue
		}
		
		price := prices[asset]
		exposureValue := position.Mul(price).Abs()
		
		// Check if position exceeds 10% profit/loss threshold
		// This is simplified - actual calculation would consider pledged amount
		
		bot.logMessage(fmt.Sprintf(
			"%s position: %.2f units at $%.2f = $%.2f exposure",
			asset,
			position.InexactFloat64(),
			price.InexactFloat64(),
			exposureValue.InexactFloat64(),
		))
	}
}