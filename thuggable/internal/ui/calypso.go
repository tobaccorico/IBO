package ui

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"thuggable-go/internal/storage"
	"thuggable-go/internal/quid"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/programs/system"
	"github.com/gagliardetto/solana-go/rpc"
	"github.com/mr-tron/base58"
	"github.com/shopspring/decimal"
)

type Asset struct {
	Ticker     string
	Decimals   int
	Allocation decimal.Decimal
}

type CalypsoPythPriceResponse struct {
	Parsed []struct {
		ID    string `json:"id"`
		Price struct {
			Price string `json:"price"`
			Expo  int    `json:"expo"`
		} `json:"price"`
	} `json:"parsed"`
}

// Pyth price feed IDs
var TOKEN_IDS = map[string]string{
	"SOL": "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
	"JUP": "0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996",
	"JTO": "b43660a5f790c69354b0729a5ef9d50d68f1df92107540210b9cccba1f947cc2",
	"JLP": "c811abc82b4bad1f9bd711a2773ccaa935b03ecef974236942cec5e0eb845a3a",
}

// Pyth oracle account addresses (these would be the on-chain accounts)
var PYTH_ACCOUNTS = map[string]string{
	"SOL": "H6ARHf6YXhGYeQfUzQNGk6rDNnLBQKrenN712K4AQJEG",
	"JTO": "D8UUgr8a3aR3yUeHLu7v8FWK7E8Y5sSU7qrYBXUJXBQ5",
	"JUP": "g6eRCbboSwK4tSWngn773RCMexr1APQr4uA9bGZBYfo",
	"JLP": "2uPQGum8X4ZkxMHxrAW1QuhXcse1AHegHuMBz3ir4Wo6", // placeholder
}

// Target portfolio allocations
var ASSETS = map[string]Asset{
	"SOL": {"SOL", 9, decimal.NewFromFloat(0.4)},
	"JTO": {"JTO", 9, decimal.NewFromFloat(0.2)},
	"JUP": {"JUP", 6, decimal.NewFromFloat(0.2)},
	"JLP": {"JLP", 6, decimal.NewFromFloat(0.2)},
}

const (
	CHECK_INTERVAL    = 60
	STASH_ADDRESS     = "StAshdD7TkoNrWqsrbPTwRjCdqaCfMgfVCwKpvaGhuC"
	PYTH_API_ENDPOINT = "https://hermes.pyth.network/v2/updates/price/latest"
	JITO_BUNDLE_URL   = "https://mainnet.block-engine.jito.wtf/api/v1/bundles"
	CLPSO_ENDPOINT    = "https://mainnet.helius-rpc.com/?api-key=001ad922-c61a-4dce-9097-6f8684b0f8c7"
)

var (
	REBALANCE_THRESHOLD    = decimal.NewFromFloat(0.0042)
	STASH_THRESHOLD        = decimal.NewFromFloat(10)
	STASH_AMOUNT           = decimal.NewFromFloat(1)
	DOUBLE_STASH_THRESHOLD = STASH_THRESHOLD.Mul(decimal.NewFromInt(2))
	lastStashValue         *decimal.Decimal
	initialPortfolioValue  *decimal.Decimal
)

type CalypsoBot struct {
	window             fyne.Window
	status             *widget.Label
	log                *widget.Entry
	startStopButton    *widget.Button
	isRunning          bool
	checkInterval      int
	rebalanceThreshold decimal.Decimal
	stashThreshold     decimal.Decimal
	stashAmount        decimal.Decimal
	stashAddress       string
	client             *rpc.Client
	quidClient         *quid.Client
	fromAccount        *solana.PrivateKey
	retryDelay         time.Duration
	walletSelect       *widget.Select
	stashSelect        *widget.Select
	app                fyne.App
	container          *fyne.Container
	stashInput         *widget.Entry
	allocations        map[string]*widget.Entry
	allocationStatus   *widget.Label
	startButtonEnabled bool
	validationIcons    map[string]*widget.Label
}

func NewCalypsoScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
	bot := &CalypsoBot{
		window:             window,
		status:             widget.NewLabel("Bot Status: Stopped"),
		log:                widget.NewMultiLineEntry(),
		isRunning:          false,
		checkInterval:      CHECK_INTERVAL,
		rebalanceThreshold: REBALANCE_THRESHOLD,
		stashThreshold:     STASH_THRESHOLD,
		stashAmount:        STASH_AMOUNT,
		client:             rpc.New(CLPSO_ENDPOINT),
		quidClient:         quid.NewClient(CLPSO_ENDPOINT),
		retryDelay:         time.Second,
		app:                app,
		allocationStatus:   widget.NewLabel(""),
		startButtonEnabled: false,
		validationIcons:    make(map[string]*widget.Label),
		allocations:        make(map[string]*widget.Entry),
	}

	// Initialize startStopButton early
	bot.startStopButton = widget.NewButton("Start Bot", bot.toggleBot)
	bot.startStopButton.Disable()

	bot.log.Disable()
	bot.log.SetMinRowsVisible(9)

	// Get available wallets
	wallets, err := bot.listWalletFiles()
	if err != nil {
		bot.logMessage(fmt.Sprintf("Error listing wallet files: %v", err))
		wallets = []string{}
	}

	// Operating wallet selector
	bot.walletSelect = widget.NewSelect(wallets, func(value string) {
		bot.loadSelectedWallet(value)
	})
	bot.walletSelect.PlaceHolder = "Select Operating Wallet"

	// Stash address configuration
	stashMethodRadio := widget.NewRadioGroup([]string{"Select from Wallets", "Enter Address"}, func(value string) {
		if value == "Select from Wallets" {
			bot.stashSelect.Show()
			bot.stashInput.Hide()
		} else {
			bot.stashSelect.Hide()
			bot.stashInput.Show()
		}
	})
	stashMethodRadio.Horizontal = true

	bot.stashSelect = widget.NewSelect(wallets, func(value string) {
		if pubKey, err := bot.getPublicKeyFromWallet(value); err == nil {
			bot.stashAddress = pubKey
			bot.logMessage(fmt.Sprintf("Set stash address to: %s", pubKey))
		}
	})
	bot.stashSelect.PlaceHolder = "Select Stash Wallet"

	bot.stashInput = widget.NewEntry()
	bot.stashInput.SetPlaceHolder("Enter Solana address")
	bot.stashInput.OnChanged = func(value string) {
		if value != "" {
			bot.stashAddress = value
			bot.logMessage(fmt.Sprintf("Set custom stash address to: %s", value))
		}
	}
	bot.stashInput.Hide()

	stashMethodRadio.SetSelected("Select from Wallets")

	// Allocations configuration
	allocationsContainer := container.NewGridWithColumns(3)
	allocationsContainer.Add(widget.NewLabelWithStyle("Asset", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}))
	allocationsContainer.Add(widget.NewLabelWithStyle("Allocation (%)", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}))
	allocationsContainer.Add(widget.NewLabelWithStyle("Status", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}))

	for asset := range ASSETS {
		allocationsContainer.Add(widget.NewLabelWithStyle(asset, fyne.TextAlignLeading, fyne.TextStyle{}))

		entry := widget.NewEntry()
		entry.SetText(ASSETS[asset].Allocation.Mul(decimal.NewFromFloat(100)).String())
		entry.OnChanged = func(asset string) func(string) {
			return func(value string) {
				if alloc, err := decimal.NewFromString(value); err == nil {
					details := ASSETS[asset]
					details.Allocation = alloc.Div(decimal.NewFromFloat(100))
					ASSETS[asset] = details
					bot.validateAndUpdateAllocations()
				} else {
					bot.validationIcons[asset].SetText("❌")
					bot.updateStartButtonState(false)
				}
			}
		}(asset)
		bot.allocations[asset] = entry
		allocationsContainer.Add(entry)

		statusIcon := widget.NewLabel("✓")
		bot.validationIcons[asset] = statusIcon
		allocationsContainer.Add(statusIcon)
	}

	bot.allocationStatus.TextStyle = fyne.TextStyle{Bold: true}
	bot.validateAndUpdateAllocations()

	// Bot settings
	settingsContainer := container.NewGridWithColumns(2)

	settingsContainer.Add(widget.NewLabelWithStyle("Check Interval (seconds)", fyne.TextAlignLeading, fyne.TextStyle{}))
	checkIntervalEntry := widget.NewEntry()
	checkIntervalEntry.SetText(fmt.Sprintf("%d", bot.checkInterval))
	checkIntervalEntry.OnChanged = func(value string) {
		if interval, _ := strconv.Atoi(value); interval > 0 {
			bot.checkInterval = interval
		}
	}
	settingsContainer.Add(checkIntervalEntry)

	settingsContainer.Add(widget.NewLabelWithStyle("Rebalance Threshold", fyne.TextAlignLeading, fyne.TextStyle{}))
	rebalanceThresholdEntry := widget.NewEntry()
	rebalanceThresholdEntry.SetText(bot.rebalanceThreshold.String())
	rebalanceThresholdEntry.OnChanged = func(value string) {
		if threshold, err := decimal.NewFromString(value); err == nil {
			bot.rebalanceThreshold = threshold
		}
	}
	settingsContainer.Add(rebalanceThresholdEntry)

	settingsContainer.Add(widget.NewLabelWithStyle("Stash Threshold ($)", fyne.TextAlignLeading, fyne.TextStyle{}))
	stashThresholdEntry := widget.NewEntry()
	stashThresholdEntry.SetText(bot.stashThreshold.String())
	stashThresholdEntry.OnChanged = func(value string) {
		if threshold, err := decimal.NewFromString(value); err == nil {
			bot.stashThreshold = threshold
		}
	}
	settingsContainer.Add(stashThresholdEntry)

	settingsContainer.Add(widget.NewLabelWithStyle("Stash Amount ($)", fyne.TextAlignLeading, fyne.TextStyle{}))
	stashAmountEntry := widget.NewEntry()
	stashAmountEntry.SetText(bot.stashAmount.String())
	stashAmountEntry.OnChanged = func(value string) {
		if amount, err := decimal.NewFromString(value); err == nil {
			bot.stashAmount = amount
		}
	}
	settingsContainer.Add(stashAmountEntry)

	allocationsContent := container.NewVBox(
		container.NewPadded(allocationsContainer),
		container.NewPadded(bot.allocationStatus),
	)

	configContainer := container.NewHSplit(
		widget.NewCard("Asset Allocations", "", allocationsContent),
		widget.NewCard("Bot Settings", "", container.NewPadded(settingsContainer)),
	)
	configContainer.SetOffset(0.5)

	// Main layout
	bot.container = container.NewVBox(
		widget.NewCard(
			"Wallet Selection",
			"",
			container.NewPadded(bot.walletSelect),
		),
		widget.NewCard(
			"Stash Configuration",
			"",
			container.NewVBox(
				container.NewPadded(stashMethodRadio),
				container.NewPadded(bot.stashSelect),
				container.NewPadded(bot.stashInput),
			),
		),
		configContainer,
		bot.startStopButton,
		bot.status,
		bot.log,
	)

	bot.validateAndUpdateAllocations()
	return bot.container
}

func (b *CalypsoBot) listWalletFiles() ([]string, error) {
	walletStorage := storage.NewWalletStorage(b.app)
	walletMap, err := walletStorage.LoadWallets()
	if err != nil {
		return nil, err
	}

	var walletFiles []string
	for walletID := range walletMap {
		walletFiles = append(walletFiles, walletID)
	}

	sort.Strings(walletFiles)
	return walletFiles, nil
}

func (b *CalypsoBot) loadSelectedWallet(walletID string) {
	walletStorage := storage.NewWalletStorage(b.app)
	walletMap, err := walletStorage.LoadWallets()
	if err != nil {
		b.logMessage(fmt.Sprintf("Error loading wallets: %v", err))
		return
	}

	encryptedData, ok := walletMap[walletID]
	if !ok {
		b.logMessage(fmt.Sprintf("Wallet %s not found", walletID))
		return
	}

	passwordEntry := widget.NewPasswordEntry()
	passwordEntry.SetPlaceHolder("Enter wallet password")

	dialog.ShowCustomConfirm("Decrypt Wallet", "Unlock", "Cancel", passwordEntry, func(unlock bool) {
		if !unlock {
			return
		}

		decryptedKey, err := decrypt(encryptedData, passwordEntry.Text)
		if err != nil {
			dialog.ShowError(fmt.Errorf("Failed to decrypt wallet: %v", err), b.window)
			return
		}

		privateKey := solana.MustPrivateKeyFromBase58(string(decryptedKey))
		b.fromAccount = &privateKey

		b.logMessage(fmt.Sprintf("Loaded wallet with public key: %s", privateKey.PublicKey().String()))
	}, b.window)
}

func (b *CalypsoBot) getPublicKeyFromWallet(walletID string) (string, error) {
	return walletID, nil
}

func (b *CalypsoBot) validateAndUpdateAllocations() {
	total := decimal.Zero
	allValid := true

	for asset, entry := range b.allocations {
		value, err := decimal.NewFromString(entry.Text)
		if err != nil || value.IsNegative() {
			b.validationIcons[asset].SetText("❌")
			allValid = false
			continue
		}

		total = total.Add(value)

		if value.IsPositive() || value.IsZero() {
			b.validationIcons[asset].SetText("✓")
		} else {
			b.validationIcons[asset].SetText("❌")
			allValid = false
		}
	}

	if total.Equal(decimal.NewFromFloat(100)) {
		b.allocationStatus.SetText(fmt.Sprintf("Total Allocation: %.1f%% ✓", total.InexactFloat64()))
		if allValid {
			b.updateStartButtonState(true)
			return
		}
	} else {
		b.allocationStatus.SetText(fmt.Sprintf("Total Allocation: %.1f%% ❌ (Must equal 100%%)", total.InexactFloat64()))
	}

	b.updateStartButtonState(false)
}

func (b *CalypsoBot) updateStartButtonState(enabled bool) {
	b.startButtonEnabled = enabled
	if b.startStopButton != nil {
		if enabled {
			b.startStopButton.Enable()
		} else {
			b.startStopButton.Disable()
		}
	}
}

func (b *CalypsoBot) toggleBot() {
	if b.isRunning {
		b.stopBot()
	} else {
		if !b.startButtonEnabled {
			dialog.ShowError(fmt.Errorf("Cannot start bot: Invalid allocations"), b.window)
			return
		}
		b.startBot()
	}
}

func (b *CalypsoBot) startBot() {
	b.isRunning = true
	b.status.SetText("Bot Status: Running")
	b.startStopButton.SetText("Stop Bot")
	b.log.SetText("")
	go b.runBot()
}

func (b *CalypsoBot) stopBot() {
	b.isRunning = false
	b.status.SetText("Bot Status: Stopped")
	b.startStopButton.SetText("Start Bot")
	b.logMessage("Bot stopped.")
}

func (b *CalypsoBot) runBot() {
	b.logMessage("Bot started - Using Quid Protocol for synthetic exposure management")
	for b.isRunning {
		b.performBotCycle()
		time.Sleep(time.Duration(b.checkInterval) * time.Second)
	}
}

func (b *CalypsoBot) performBotCycle() {
	b.logMessage("Starting portfolio check...")

	if b.fromAccount == nil {
		b.logMessage("No wallet loaded")
		return
	}

	walletAddress := b.fromAccount.PublicKey().String()
	b.logMessage(fmt.Sprintf("Wallet address: %s", walletAddress))

	// Get current synthetic positions from Quid
	positions, err := b.getQuidPositions(walletAddress)
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to get Quid positions: %v", err))
		return
	}

	// Get current prices
	prices, err := b.getPrices()
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to get prices: %v", err))
		return
	}

	// Calculate portfolio value based on synthetic exposure
	totalValue := b.calculateSyntheticPortfolioValue(positions, prices)
	b.logMessage(fmt.Sprintf("Total synthetic portfolio value: $%s", totalValue.StringFixed(2)))

	if initialPortfolioValue == nil {
		initialPortfolioValue = &totalValue
		b.logMessage(fmt.Sprintf("Initialized initial portfolio value to: $%s", initialPortfolioValue.StringFixed(2)))
	}

	delta := totalValue.Sub(*initialPortfolioValue)
	b.logMessage(fmt.Sprintf("Current P&L: $%s", delta.StringFixed(2)))

	b.printSyntheticPortfolio(positions, prices, totalValue)

	// Calculate needed exposure adjustments
	adjustments := b.calculateExposureAdjustments(positions, prices, totalValue)
	b.logMessage("Exposure adjustments calculated")

	needRebalance := b.checkNeedRebalance(positions, prices, totalValue)

	// Check for stashing
	if lastStashValue != nil && (delta.GreaterThanOrEqual(STASH_THRESHOLD) || delta.LessThanOrEqual(STASH_THRESHOLD.Neg())) {
		b.logMessage("Stashing threshold reached. Executing stash and rebalance.")
		b.executeStashAndRebalance(adjustments, prices, totalValue, delta)
	} else if needRebalance {
		b.logMessage("\nRebalancing needed. Adjusting synthetic exposures.")
		b.executeQuidRebalance(adjustments, prices)
	} else {
		b.logMessage("\nPortfolio is balanced and no stashing needed.")
	}

	if lastStashValue == nil {
		lastStashValue = &totalValue
		b.logMessage(fmt.Sprintf("Initialized last stash value to: $%s", lastStashValue.StringFixed(2)))
	}
}

// Get synthetic positions from Quid protocol
func (b *CalypsoBot) getQuidPositions(walletAddress string) (map[string]SyntheticPosition, error) {
	// This would fetch the depositor account and parse positions
	// For now, return mock data
	positions := map[string]SyntheticPosition{
		"SOL": {Exposure: decimal.NewFromFloat(10.5), Pledged: decimal.NewFromFloat(1000)},
		"JTO": {Exposure: decimal.NewFromFloat(-50), Pledged: decimal.NewFromFloat(500)},  // negative = short
		"JUP": {Exposure: decimal.NewFromFloat(100), Pledged: decimal.NewFromFloat(800)},
		"JLP": {Exposure: decimal.NewFromFloat(25), Pledged: decimal.NewFromFloat(300)},
	}
	return positions, nil
}

type SyntheticPosition struct {
	Exposure decimal.Decimal // Can be negative (short)
	Pledged  decimal.Decimal // Collateral allocated
}

func (b *CalypsoBot) calculateSyntheticPortfolioValue(positions map[string]SyntheticPosition, prices map[string]decimal.Decimal) decimal.Decimal {
	totalValue := decimal.Zero
	
	// Add up the value of all positions
	for asset, pos := range positions {
		if price, exists := prices[asset]; exists {
			// Exposure value (can be negative for shorts)
			exposureValue := pos.Exposure.Mul(price)
			// Add pledged collateral
			totalValue = totalValue.Add(pos.Pledged).Add(exposureValue)
		}
	}
	
	return totalValue
}

func (b *CalypsoBot) printSyntheticPortfolio(positions map[string]SyntheticPosition, prices map[string]decimal.Decimal, totalValue decimal.Decimal) {
	b.logMessage("\nCurrent Synthetic Portfolio:")
	b.logMessage("---------------------------")
	b.logMessage("Asset  Exposure    Collateral   Value ($)   Allocation  Target")
	b.logMessage(strings.Repeat("-", 65))
	
	for asset, details := range ASSETS {
		pos, exists := positions[asset]
		if !exists {
			pos = SyntheticPosition{Exposure: decimal.Zero, Pledged: decimal.Zero}
		}
		
		price := prices[asset]
		exposureValue := pos.Exposure.Mul(price)
		totalPositionValue := pos.Pledged.Add(exposureValue)
		allocation := totalPositionValue.Div(totalValue).Mul(decimal.NewFromInt(100))
		targetAllocation := details.Allocation.Mul(decimal.NewFromInt(100))
		
		exposureStr := fmt.Sprintf("%12s", pos.Exposure.StringFixed(3))
		if pos.Exposure.IsNegative() {
			exposureStr += " (SHORT)"
		}
		
		b.logMessage(fmt.Sprintf("%-6s %s %12s %12s %11s%% %8s%%",
			asset,
			exposureStr,
			pos.Pledged.StringFixed(2),
			totalPositionValue.StringFixed(2),
			allocation.StringFixed(2),
			targetAllocation.StringFixed(2)))
	}
	
	b.logMessage(strings.Repeat("-", 65))
	b.logMessage(fmt.Sprintf("%-6s %37s %12s %11s %8s",
		"Total", "", totalValue.StringFixed(2), "100.00%", "100.00%"))
}

type ExposureAdjustment struct {
	Asset          string
	CurrentValue   decimal.Decimal
	TargetValue    decimal.Decimal
	AdjustmentUSD  decimal.Decimal
	AdjustmentUnits decimal.Decimal
}

func (b *CalypsoBot) calculateExposureAdjustments(positions map[string]SyntheticPosition, prices map[string]decimal.Decimal, totalValue decimal.Decimal) []ExposureAdjustment {
	var adjustments []ExposureAdjustment
	
	for asset, details := range ASSETS {
		pos, exists := positions[asset]
		if !exists {
			pos = SyntheticPosition{Exposure: decimal.Zero, Pledged: decimal.Zero}
		}
		
		price := prices[asset]
		currentValue := pos.Pledged.Add(pos.Exposure.Mul(price))
		targetValue := totalValue.Mul(details.Allocation)
		adjustmentUSD := targetValue.Sub(currentValue)
		adjustmentUnits := adjustmentUSD.Div(price)
		
		adjustments = append(adjustments, ExposureAdjustment{
			Asset:           asset,
			CurrentValue:    currentValue,
			TargetValue:     targetValue,
			AdjustmentUSD:   adjustmentUSD,
			AdjustmentUnits: adjustmentUnits,
		})
	}
	
	return adjustments
}

func (b *CalypsoBot) checkNeedRebalance(positions map[string]SyntheticPosition, prices map[string]decimal.Decimal, totalValue decimal.Decimal) bool {
	for asset, details := range ASSETS {
		pos, exists := positions[asset]
		if !exists {
			pos = SyntheticPosition{Exposure: decimal.Zero, Pledged: decimal.Zero}
		}
		
		price := prices[asset]
		currentValue := pos.Pledged.Add(pos.Exposure.Mul(price))
		currentAllocation := currentValue.Div(totalValue)
		
		if currentAllocation.Sub(details.Allocation).Abs().GreaterThan(b.rebalanceThreshold) {
			return true
		}
	}
	return false
}

func (b *CalypsoBot) executeQuidRebalance(adjustments []ExposureAdjustment, prices map[string]decimal.Decimal) {
	b.logMessage("\nExecuting Quid rebalance via synthetic exposure adjustments:")
	b.logMessage(strings.Repeat("-", 70))
	b.logMessage("Asset  Action        Amount          Units      Value ($)")
	b.logMessage(strings.Repeat("-", 70))
	
	var instructions []solana.Instruction
	
	for _, adj := range adjustments {
		if adj.AdjustmentUSD.Abs().LessThan(decimal.NewFromFloat(1)) {
			continue // Skip tiny adjustments
		}
		
		action := "INCREASE"
		if adj.AdjustmentUSD.IsNegative() {
			action = "DECREASE"
		}
		
		// Build withdraw instruction with exposure=true
		amount := quid.CalculateExposureAmount(
			adj.AdjustmentUSD.Abs().InexactFloat64(),
			adj.Asset,
			adj.AdjustmentUSD.IsPositive(),
		)
		
		pythAccounts := []solana.PublicKey{}
		if pythAddr, exists := PYTH_ACCOUNTS[adj.Asset]; exists {
			pythAccounts = append(pythAccounts, solana.MustPublicKeyFromBase58(pythAddr))
		}
		
		instruction, err := b.quidClient.BuildWithdrawInstruction(
			b.fromAccount.PublicKey(),
			amount,
			adj.Asset,
			true, // exposure adjustment
			pythAccounts,
		)
		if err != nil {
			b.logMessage(fmt.Sprintf("Error building instruction for %s: %v", adj.Asset, err))
			continue
		}
		
		instructions = append(instructions, instruction)
		
		b.logMessage(fmt.Sprintf("%-6s %-12s %12s %12s %12s",
			adj.Asset,
			action,
			adj.AdjustmentUSD.Abs().StringFixed(2),
			adj.AdjustmentUnits.Abs().StringFixed(6),
			adj.AdjustmentUSD.StringFixed(2)))
	}
	
	b.logMessage(strings.Repeat("-", 70))
	
	if len(instructions) == 0 {
		b.logMessage("No adjustments needed")
		return
	}
	
	// Build and send transaction
	b.sendQuidTransaction(instructions)
}

func (b *CalypsoBot) executeStashAndRebalance(adjustments []ExposureAdjustment, prices map[string]decimal.Decimal, totalValue, delta decimal.Decimal) {
	stashAmount := b.stashAmount
	doubleStashTriggered := false
	
	if delta.GreaterThanOrEqual(DOUBLE_STASH_THRESHOLD) {
		doubleStashTriggered = true
		stashAmount = b.stashAmount.Mul(decimal.NewFromInt(2))
		b.logMessage("Double stash threshold reached.")
	}
	
	b.logMessage(fmt.Sprintf("Stashing $%s USDC to %s", stashAmount.String(), b.stashAddress))
	
	// Execute rebalance with Quid
	b.executeQuidRebalance(adjustments, prices)
	
	// Create stash transaction (simple SOL transfer)
	stashTx, err := b.createStashTransaction(stashAmount)
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to create stash transaction: %v", err))
		return
	}
	
	// Send stash transaction
	sig, err := b.client.SendTransaction(context.Background(), stashTx)
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to send stash transaction: %v", err))
		return
	}
	
	b.logMessage(fmt.Sprintf("Stash transaction sent: %s", sig.String()))
	
	if doubleStashTriggered {
		b.logMessage("Double stash completed.")
	}
	
	// Reset values
	lastStashValue = &totalValue
	initialPortfolioValue = &totalValue
}

func (b *CalypsoBot) sendQuidTransaction(instructions []solana.Instruction) {
	recent, err := b.client.GetRecentBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to get blockhash: %v", err))
		return
	}
	
	// Add tip transaction
	tipTx, err := b.createTipTransaction()
	if err != nil {
		b.logMessage(fmt.Sprintf("Warning: Failed to create tip: %v", err))
	}
	
	// Build main transaction
	tx, err := solana.NewTransaction(
		instructions,
		recent.Value.Blockhash,
		solana.TransactionPayer(b.fromAccount.PublicKey()),
	)
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to build transaction: %v", err))
		return
	}
	
	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	if err != nil {
		b.logMessage(fmt.Sprintf("Failed to sign transaction: %v", err))
		return
	}
	
	// Send bundle if we have tip, otherwise send single tx
	if tipTx != nil {
		bundleID, err := b.sendBundle([]*solana.Transaction{tx, tipTx})
		if err != nil {
			b.logMessage(fmt.Sprintf("Failed to send bundle: %v", err))
			return
		}
		b.logMessage(fmt.Sprintf("Bundle sent: %s", bundleID))
	} else {
		sig, err := b.client.SendTransaction(context.Background(), tx)
		if err != nil {
			b.logMessage(fmt.Sprintf("Failed to send transaction: %v", err))
			return
		}
		b.logMessage(fmt.Sprintf("Transaction sent: %s", sig.String()))
	}
}

func (b *CalypsoBot) createStashTransaction(amount decimal.Decimal) (*solana.Transaction, error) {
	// This would create a USDC transfer to stash address
	// For now, create a simple SOL transfer as placeholder
	recent, err := b.client.GetRecentBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, err
	}
	
	lamports := uint64(amount.Mul(decimal.NewFromFloat(0.001)).Mul(decimal.NewFromInt(solana.LAMPORTS_PER_SOL)).IntPart())
	
	instruction := system.NewTransferInstruction(
		lamports,
		b.fromAccount.PublicKey(),
		solana.MustPublicKeyFromBase58(b.stashAddress),
	).Build()
	
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(b.fromAccount.PublicKey()),
	)
	if err != nil {
		return nil, err
	}
	
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	
	return tx, err
}

func (b *CalypsoBot) getPrices() (map[string]decimal.Decimal, error) {
	b.logMessage("Fetching asset prices from Pyth...")

	baseURL, err := url.Parse(PYTH_API_ENDPOINT)
	if err != nil {
		return nil, fmt.Errorf("failed to parse URL: %v", err)
	}

	params := url.Values{}
	for _, id := range TOKEN_IDS {
		params.Add("ids[]", id)
	}
	params.Set("parsed", "true")
	baseURL.RawQuery = params.Encode()

	resp, err := http.Get(baseURL.String())
	if err != nil {
		return nil, fmt.Errorf("failed to fetch prices: %v", err)
	}
	defer resp.Body.Close()

	var pythResp CalypsoPythPriceResponse
	if err := json.NewDecoder(resp.Body).Decode(&pythResp); err != nil {
		return nil, fmt.Errorf("failed to decode price response: %v", err)
	}

	prices := make(map[string]decimal.Decimal)
	for _, item := range pythResp.Parsed {
		for token, id := range TOKEN_IDS {
			if id == item.ID {
				price, err := decimal.NewFromString(item.Price.Price)
				if err != nil {
					return nil, fmt.Errorf("failed to parse price for %s: %v", token, err)
				}
				exponent := decimal.New(1, int32(item.Price.Expo))
				prices[token] = price.Mul(exponent)
				break
			}
		}
	}

	b.logMessage("Asset prices fetched successfully")
	return prices, nil
}

func (b *CalypsoBot) createTipTransaction() (*solana.Transaction, error) {
	recent, err := b.client.GetRecentBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, fmt.Errorf("failed to get recent blockhash: %v", err)
	}

	builder := solana.NewTransactionBuilder()
	builder.SetFeePayer(b.fromAccount.PublicKey())
	builder.SetRecentBlockHash(recent.Value.Blockhash)

	tipRecipients := []string{
		"juLesoSmdTcRtzjCzYzRoHrnF8GhVu6KCV7uxq7nJGp",
		"DttWaMuVvTiduZRnguLF7jNxTgiMBZ1hyAumKUiL2KRL",
	}

	for _, recipient := range tipRecipients {
		tipInstruction := system.NewTransferInstruction(
			100_000, // 0.0001 SOL
			b.fromAccount.PublicKey(),
			solana.MustPublicKeyFromBase58(recipient),
		).Build()

		builder.AddInstruction(tipInstruction)
	}

	tx, err := builder.Build()
	if err != nil {
		return nil, fmt.Errorf("failed to build transaction: %v", err)
	}

	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to sign tip transaction: %v", err)
	}

	return tx, nil
}

func (b *CalypsoBot) sendBundle(transactions []*solana.Transaction) (string, error) {
	encodedTransactions := make([]string, len(transactions))
	for i, tx := range transactions {
		encodedTx, err := tx.MarshalBinary()
		if err != nil {
			return "", fmt.Errorf("failed to encode transaction: %v", err)
		}
		encodedTransactions[i] = base58.Encode(encodedTx)
	}

	bundleData := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "sendBundle",
		"params":  []interface{}{encodedTransactions},
	}

	bundleJSON, err := json.Marshal(bundleData)
	if err != nil {
		return "", fmt.Errorf("failed to marshal bundle data: %v", err)
	}

	resp, err := http.Post(JITO_BUNDLE_URL, "application/json", bytes.NewBuffer(bundleJSON))
	if err != nil {
		return "", fmt.Errorf("failed to send bundle: %v", err)
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	respBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}

	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("failed to decode bundle response: %v", err)
	}

	if errorData, ok := result["error"]; ok {
		return "", fmt.Errorf("bundle error: %v", errorData)
	}

	bundleID, ok := result["result"].(string)
	if !ok {
		return "", fmt.Errorf("invalid bundle response")
	}

	return bundleID, nil
}

func (b *CalypsoBot) logMessage(message string) {
	log.Println(message)
	b.log.SetText(b.log.Text + message + "\n")
}

func decrypt(encryptedData string, password string) ([]byte, error) {
	key := []byte(padKey(password))
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	ciphertext, err := hex.DecodeString(encryptedData)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	nonce, ciphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, err
	}

	return plaintext, nil
}