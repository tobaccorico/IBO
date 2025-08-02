package ui

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
	"thuggable-go/internal/storage"
	"thuggable-go/internal/quid"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/programs/system"
	"github.com/gagliardetto/solana-go/rpc"
	"github.com/mr-tron/base58"
	"github.com/shopspring/decimal"
)

const (
	CNDTNL_PYTH_PRICE_URL  = "https://hermes.pyth.network/v2/updates/price/latest"
	CNDTNL_JITO_BUNDLE_URL = "https://mainnet.block-engine.jito.wtf/api/v1/bundles"
	CNDTNL_ENDPOINT        = "https://special-blue-fog.solana-mainnet.quiknode.pro/d009d548b4b9dd9f062a8124a868fb915937976c/"
	CNDTNL_CHECK_INTERVAL  = 60
)

// Pyth price feed IDs for supported assets
var PythPriceIDs = map[string]string{
	"SOL": "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
	"JUP": "0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996",
	"JTO": "b43660a5f790c69354b0729a5ef9d50d68f1df92107540210b9cccba1f947cc2",
	"BTC": "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
	"XAU": "765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508ceb4a9e88d3d8bd0530c", // Gold
}

// Pyth oracle account addresses
var PYTH_ACCOUNTS = map[string]string{
	"SOL": "H6ARHf6YXhGYeQfUzQNGk6rDNnLBQKrenN712K4AQJEG",
	"JTO": "D8UUgr8a3aR3yUeHLu7v8FWK7E8Y5sSU7qrYBXUJXBQ5",
	"JUP": "g6eRCbboSwK4tSWngn773RCMexr1APQr4uA9bGZBYfo",
	"BTC": "GVXRSBjFk6e6J3NbVPXohDJetcTjaeeuykUpbQF8UoMU",
	"XAU": "GZXW7j9C8UvWDtgTMqhXbHpbcaKdT1eKqnHHNBHHjqzC", // placeholder
}

// Supported price condition operators
var ConditionOperators = []string{"Greater Than (>)", "Less Than (<)", "Equal To (=)", "Greater Than or Equal (>=)", "Less Than or Equal (<=)"}

// Supported action types with Quid
var ActionTypes = []string{"Increase Exposure", "Decrease Exposure", "Close Position"}

// Supported assets for monitoring with Quid
var MonitoredAssets = map[string]PriceAsset{
	"SOL": {"SOL", "So11111111111111111111111111111111111111112", 9},
	"JUP": {"JUP", "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN", 6},
	"JTO": {"JTO", "jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL", 9},
	"BTC": {"BTC", "3NZ9JMVBmGAqocybic2c7LQCJScmgsAZ6vQqTDzcqmJh", 8},
	"XAU": {"XAU", "8yDmC2PUH4qkKNDNQUxMjULG2bKJGW4g6mBDK5fFnEti", 6},
}

// Types for the conditional bot implementation
type PriceAsset struct {
	Symbol    string
	TokenMint string
	Decimals  int
}

type PriceCondition struct {
	Asset     string
	Operator  string
	Price     decimal.Decimal
	Triggered bool
}

type TradeAction struct {
	Type     string
	Asset    string
	Amount   decimal.Decimal  // In percentage or units
	Executed bool
}

type ConditionalTrade struct {
	ID         string
	Condition  PriceCondition
	Action     TradeAction
	Active     bool
	CreatedAt  time.Time
	ExecutedAt *time.Time
}

type ConditionalBotScreen struct {
	window          fyne.Window
	app             fyne.App
	log             *widget.Entry
	status          *widget.Label
	startStopButton *widget.Button
	isRunning       bool
	trades          []*ConditionalTrade
	activeTrades    sync.Map
	tradesContainer *fyne.Container
	client          *rpc.Client
	quidClient      *quid.Client
	container       *fyne.Container
	walletSelect    *widget.Select
	fromAccount     *solana.PrivateKey
	pythPriceFeeds  map[string]solana.PublicKey

	// Form fields for creating new conditions
	assetSelect       *widget.Select
	operatorSelect    *widget.Select
	priceEntry        *widget.Entry
	actionTypeSelect  *widget.Select
	targetAssetSelect *widget.Select
	amountEntry       *widget.Entry
	amountTypeRadio   *widget.RadioGroup
}

// Create a new conditional bot screen
func NewConditionalBotScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
	bot := &ConditionalBotScreen{
		window:    window,
		app:       app,
		log:       widget.NewMultiLineEntry(),
		status:    widget.NewLabel("Bot Status: Stopped"),
		isRunning: false,
		trades:    make([]*ConditionalTrade, 0),
		client:    rpc.New(CNDTNL_ENDPOINT),
		quidClient: quid.NewClient(CNDTNL_ENDPOINT),
		pythPriceFeeds: make(map[string]solana.PublicKey),
	}

	// Initialize Pyth price feeds
	for asset, address := range PYTH_ACCOUNTS {
		bot.pythPriceFeeds[asset] = solana.MustPublicKeyFromBase58(address)
	}

	bot.log.Disable()
	bot.log.SetMinRowsVisible(9)

	// Initialize startStopButton
	bot.startStopButton = widget.NewButton("Start Bot", bot.toggleBot)
	bot.startStopButton.Disable()

	// Get available wallets
	wallets, err := bot.listWalletFiles()
	if err != nil {
		bot.logMessage(fmt.Sprintf("Error listing wallet files: %v", err))
		wallets = []string{}
	}

	// Wallet selector
	bot.walletSelect = widget.NewSelect(wallets, func(value string) {
		bot.logMessage(fmt.Sprintf("Selected wallet: %s", value))
		bot.loadSelectedWallet(value)
	})
	bot.walletSelect.PlaceHolder = "Select Operating Wallet"

	// Initialize form fields for creating conditions
	bot.assetSelect = widget.NewSelect(getKeys(MonitoredAssets), func(value string) {})
	bot.assetSelect.PlaceHolder = "Select Asset to Monitor"

	bot.operatorSelect = widget.NewSelect(ConditionOperators, func(value string) {})
	bot.operatorSelect.PlaceHolder = "Select Condition"

	bot.priceEntry = widget.NewEntry()
	bot.priceEntry.SetPlaceHolder("Enter Price (e.g., 100.50)")

	bot.actionTypeSelect = widget.NewSelect(ActionTypes, func(value string) {
		// Update UI based on action type
		bot.updateActionFields(value)
	})
	bot.actionTypeSelect.PlaceHolder = "Select Action"

	bot.targetAssetSelect = widget.NewSelect(getKeys(MonitoredAssets), func(value string) {})
	bot.targetAssetSelect.PlaceHolder = "Select Target Asset"

	bot.amountEntry = widget.NewEntry()
	bot.amountEntry.SetPlaceHolder("Enter Amount")

	bot.amountTypeRadio = widget.NewRadioGroup([]string{"Percentage (%)", "Units"}, nil)
	bot.amountTypeRadio.SetSelected("Percentage (%)")

	// Button to add a new condition
	addButton := widget.NewButton("Add Condition", bot.addNewCondition)

	// Trades container for displaying active conditions
	bot.tradesContainer = container.NewVBox()

	// Form for adding new conditions
	formCard := widget.NewCard("Create New Condition", "",
		container.NewVBox(
			container.NewGridWithColumns(2,
				widget.NewLabel("Asset to Monitor:"),
				bot.assetSelect,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Condition:"),
				bot.operatorSelect,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Target Price:"),
				bot.priceEntry,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Action:"),
				bot.actionTypeSelect,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Target Asset:"),
				bot.targetAssetSelect,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Amount Type:"),
				bot.amountTypeRadio,
			),
			container.NewGridWithColumns(2,
				widget.NewLabel("Amount:"),
				bot.amountEntry,
			),
			addButton,
		),
	)

	// Active conditions display
	activeConditionsCard := widget.NewCard("Active Conditions", "",
		container.NewVScroll(bot.tradesContainer),
	)

	// Main layout
	bot.container = container.NewVBox(
		widget.NewCard("Wallet Selection", "", container.NewPadded(bot.walletSelect)),
		formCard,
		activeConditionsCard,
		bot.startStopButton,
		bot.status,
		bot.log,
	)

	// Load any existing conditions
	bot.refreshTradesDisplay()

	return bot.container
}

// Get map keys as a string slice
func getKeys(m interface{}) []string {
	var keys []string

	switch v := m.(type) {
	case map[string]PriceAsset:
		for k := range v {
			keys = append(keys, k)
		}
	}

	sort.Strings(keys)
	return keys
}

// Update action fields based on selected action type
func (b *ConditionalBotScreen) updateActionFields(actionType string) {
	switch actionType {
	case "Close Position":
		b.targetAssetSelect.Disable()
		b.amountEntry.Disable()
		b.amountTypeRadio.Disable()
	default:
		b.targetAssetSelect.Enable()
		b.amountEntry.Enable()
		b.amountTypeRadio.Enable()
	}
}

func (b *ConditionalBotScreen) listWalletFiles() ([]string, error) {
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

func (b *ConditionalBotScreen) loadSelectedWallet(walletID string) {
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
		b.startStopButton.Enable()
	}, b.window)
}

// Add a new conditional trade
func (b *ConditionalBotScreen) addNewCondition() {
	// Validate form fields
	if b.assetSelect.Selected == "" ||
		b.operatorSelect.Selected == "" ||
		b.priceEntry.Text == "" ||
		b.actionTypeSelect.Selected == "" {
		dialog.ShowError(fmt.Errorf("Please fill in all required fields"), b.window)
		return
	}

	// Additional validation for non-close actions
	if b.actionTypeSelect.Selected != "Close Position" &&
		(b.targetAssetSelect.Selected == "" || b.amountEntry.Text == "") {
		dialog.ShowError(fmt.Errorf("Please specify target asset and amount"), b.window)
		return
	}

	// Parse price
	price, err := decimal.NewFromString(b.priceEntry.Text)
	if err != nil {
		dialog.ShowError(fmt.Errorf("Invalid price value: %v", err), b.window)
		return
	}

	// Parse amount if needed
	var amount decimal.Decimal
	if b.actionTypeSelect.Selected != "Close Position" {
		amount, err = decimal.NewFromString(b.amountEntry.Text)
		if err != nil {
			dialog.ShowError(fmt.Errorf("Invalid amount value: %v", err), b.window)
			return
		}
	}

	// Create new trade condition
	trade := &ConditionalTrade{
		ID: fmt.Sprintf("trade_%d", time.Now().UnixNano()),
		Condition: PriceCondition{
			Asset:     b.assetSelect.Selected,
			Operator:  b.operatorSelect.Selected,
			Price:     price,
			Triggered: false,
		},
		Action: TradeAction{
			Type:     b.actionTypeSelect.Selected,
			Asset:    b.targetAssetSelect.Selected,
			Amount:   amount,
			Executed: false,
		},
		Active:    true,
		CreatedAt: time.Now(),
	}

	// Add to trades list
	b.trades = append(b.trades, trade)
	b.activeTrades.Store(trade.ID, trade)

	b.logMessage(fmt.Sprintf("Added new condition: %s $%s %s -> %s",
		trade.Condition.Asset,
		trade.Condition.Price.String(),
		simplifyOperator(trade.Condition.Operator),
		trade.Action.Type))

	// Refresh the display
	b.refreshTradesDisplay()

	// Clear form fields
	b.clearForm()
}

// Convert operator display text to symbol
func simplifyOperator(operator string) string {
	switch operator {
	case "Greater Than (>)":
		return ">"
	case "Less Than (<)":
		return "<"
	case "Equal To (=)":
		return "="
	case "Greater Than or Equal (>=)":
		return ">="
	case "Less Than or Equal (<=)":
		return "<="
	default:
		return operator
	}
}

// Clear form fields after adding a condition
func (b *ConditionalBotScreen) clearForm() {
	b.assetSelect.ClearSelected()
	b.operatorSelect.ClearSelected()
	b.priceEntry.SetText("")
	b.actionTypeSelect.ClearSelected()
	b.targetAssetSelect.ClearSelected()
	b.amountEntry.SetText("")
	b.amountTypeRadio.SetSelected("Percentage (%)")
}

func (b *ConditionalBotScreen) createTradeCard(trade *ConditionalTrade) fyne.CanvasObject {
	var statusIcon *widget.Icon
	var statusText string

	if !trade.Active {
		statusIcon = widget.NewIcon(theme.CancelIcon())
		statusText = "Inactive"
	} else if trade.Action.Executed {
		statusIcon = widget.NewIcon(theme.ConfirmIcon())
		statusText = "Executed"
	} else if trade.Condition.Triggered {
		statusIcon = widget.NewIcon(theme.WarningIcon())
		statusText = "Triggered"
	} else {
		statusIcon = widget.NewIcon(theme.RadioButtonIcon())
		statusText = "Monitoring"
	}

	statusLabel := widget.NewLabelWithStyle(statusText, fyne.TextAlignCenter, fyne.TextStyle{Bold: true})
	statusContainer := container.NewHBox(statusIcon, statusLabel)

	conditionText := fmt.Sprintf("When %s price %s $%s",
		trade.Condition.Asset,
		simplifyOperator(trade.Condition.Operator),
		trade.Condition.Price.String())

	conditionLabel := widget.NewLabelWithStyle(conditionText, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})

	var actionText string
	if trade.Action.Type == "Close Position" {
		actionText = fmt.Sprintf("Then %s %s position", trade.Action.Type, trade.Condition.Asset)
	} else {
		actionText = fmt.Sprintf("Then %s for %s by %s",
			trade.Action.Type,
			trade.Action.Asset,
			trade.Action.Amount.String())
	}

	actionLabel := widget.NewLabel(actionText)

	timeInfo := fmt.Sprintf("Created: %s", trade.CreatedAt.Format("Jan 2 15:04:05"))
	if trade.ExecutedAt != nil {
		timeInfo += fmt.Sprintf(" | Executed: %s", trade.ExecutedAt.Format("Jan 2 15:04:05"))
	}
	timeLabel := widget.NewLabelWithStyle(timeInfo, fyne.TextAlignLeading, fyne.TextStyle{Italic: true})

	deleteButton := widget.NewButtonWithIcon("Delete", theme.DeleteIcon(), func() {
		dialog.ShowConfirm("Delete Condition",
			"Are you sure you want to delete this condition?",
			func(confirmed bool) {
				if confirmed {
					b.deleteTrade(trade.ID)
				}
			},
			b.window)
	})

	separator := widget.NewSeparator()

	content := container.NewVBox(
		container.NewPadded(conditionLabel),
		container.NewPadded(actionLabel),
		separator,
		container.NewHBox(
			statusContainer,
			layout.NewSpacer(),
			deleteButton,
		),
		timeLabel,
	)

	card := widget.NewCard("", "", content)

	return card
}

func (b *ConditionalBotScreen) refreshTradesDisplay() {
	b.tradesContainer.Objects = nil

	if len(b.trades) == 0 {
		noConditionsLabel := widget.NewLabelWithStyle(
			"No conditions added yet.",
			fyne.TextAlignCenter,
			fyne.TextStyle{Italic: true},
		)
		b.tradesContainer.Add(noConditionsLabel)
	} else {
		// Add active conditions
		var activeConditions int
		for _, trade := range b.trades {
			if !trade.Active || trade.Action.Executed {
				continue
			}

			tradeCard := b.createTradeCard(trade)
			b.tradesContainer.Add(tradeCard)
			b.tradesContainer.Add(widget.NewSeparator())
			activeConditions++
		}

		// Add executed conditions
		var hasExecuted bool
		for _, trade := range b.trades {
			if trade.Action.Executed {
				if !hasExecuted {
					b.tradesContainer.Add(widget.NewLabelWithStyle(
						"Executed Conditions",
						fyne.TextAlignCenter,
						fyne.TextStyle{Bold: true},
					))
					hasExecuted = true
				}

				tradeCard := b.createTradeCard(trade)
				b.tradesContainer.Add(tradeCard)
				b.tradesContainer.Add(widget.NewSeparator())
			}
		}

		// Add inactive conditions
		var hasInactive bool
		for _, trade := range b.trades {
			if !trade.Active && !trade.Action.Executed {
				if !hasInactive {
					b.tradesContainer.Add(widget.NewLabelWithStyle(
						"Inactive Conditions",
						fyne.TextAlignCenter,
						fyne.TextStyle{Bold: true},
					))
					hasInactive = true
				}

				tradeCard := b.createTradeCard(trade)
				b.tradesContainer.Add(tradeCard)
				b.tradesContainer.Add(widget.NewSeparator())
			}
		}
	}

	b.tradesContainer.Refresh()
}

// Delete a trade condition
func (b *ConditionalBotScreen) deleteTrade(id string) {
	b.activeTrades.Delete(id)

	for i, trade := range b.trades {
		if trade.ID == id {
			b.trades = append(b.trades[:i], b.trades[i+1:]...)
			break
		}
	}

	b.logMessage(fmt.Sprintf("Deleted condition with ID: %s", id))
	b.refreshTradesDisplay()
}

// Toggle bot on/off
func (b *ConditionalBotScreen) toggleBot() {
	if b.isRunning {
		b.stopBot()
	} else {
		b.startBot()
	}
}

// Start the bot
func (b *ConditionalBotScreen) startBot() {
	if b.fromAccount == nil {
		dialog.ShowError(fmt.Errorf("Please select and unlock a wallet first"), b.window)
		return
	}

	if len(b.trades) == 0 {
		dialog.ShowError(fmt.Errorf("Please add at least one condition before starting"), b.window)
		return
	}

	b.isRunning = true
	b.status.SetText("Bot Status: Running")
	b.startStopButton.SetText("Stop Bot")
	b.logMessage("Bot started. Monitoring price conditions...")

	go b.runBot()
}

// Stop the bot
func (b *ConditionalBotScreen) stopBot() {
	b.isRunning = false
	b.status.SetText("Bot Status: Stopped")
	b.startStopButton.SetText("Start Bot")
	b.logMessage("Bot stopped.")
}

// Run the bot monitoring loop
func (b *ConditionalBotScreen) runBot() {
	for b.isRunning {
		b.checkConditions()
		time.Sleep(time.Duration(CNDTNL_CHECK_INTERVAL) * time.Second)
	}
}

// Check all conditions against current prices
func (b *ConditionalBotScreen) checkConditions() {
	// Fetch current prices from Pyth
	prices, err := b.getPythPrices()
	if err != nil {
		b.logMessage(fmt.Sprintf("Error fetching prices: %v", err))
		return
	}

	// Log current prices
	b.logMessage("\nCurrent prices:")
	for asset, price := range prices {
		b.logMessage(fmt.Sprintf("%s: $%s", asset, price.String()))
	}

	// Check each active trade condition
	b.activeTrades.Range(func(key, value interface{}) bool {
		trade, ok := value.(*ConditionalTrade)
		if !ok || !trade.Active || trade.Action.Executed {
			return true
		}

		price, exists := prices[trade.Condition.Asset]
		if !exists {
			b.logMessage(fmt.Sprintf("No price data available for %s", trade.Condition.Asset))
			return true
		}

		conditionMet := b.evaluateCondition(trade.Condition, price)

		if conditionMet && !trade.Condition.Triggered {
			b.logMessage(fmt.Sprintf("Condition triggered for %s: %s price %s $%s (Current: $%s)",
				trade.ID,
				trade.Condition.Asset,
				simplifyOperator(trade.Condition.Operator),
				trade.Condition.Price.String(),
				price.String()))

			trade.Condition.Triggered = true

			// Execute action
			go b.executeAction(trade, prices)
		}

		return true
	})
}

// Evaluate if a condition is met
func (b *ConditionalBotScreen) evaluateCondition(condition PriceCondition, currentPrice decimal.Decimal) bool {
	switch condition.Operator {
	case "Greater Than (>)":
		return currentPrice.GreaterThan(condition.Price)
	case "Less Than (<)":
		return currentPrice.LessThan(condition.Price)
	case "Equal To (=)":
		return currentPrice.Equal(condition.Price)
	case "Greater Than or Equal (>=)":
		return currentPrice.GreaterThanOrEqual(condition.Price)
	case "Less Than or Equal (<=)":
		return currentPrice.LessThanOrEqual(condition.Price)
	default:
		return false
	}
}

// Execute the action for a triggered condition
func (b *ConditionalBotScreen) executeAction(trade *ConditionalTrade, prices map[string]decimal.Decimal) {
	b.logMessage(fmt.Sprintf("Executing action for condition %s: %s",
		trade.ID,
		trade.Action.Type))

	var err error
	var mainTx *solana.Transaction
	var tipTx *solana.Transaction

	// Create the tip transaction first
	tipTx, err = b.createTipTransaction()
	if err != nil {
		b.logMessage(fmt.Sprintf("Error creating tip transaction: %v", err))
		tipTx = nil
	} else {
		b.logMessage("Tip transaction created successfully")
	}

	// Create the main transaction based on action type
	switch trade.Action.Type {
	case "Increase Exposure":
		mainTx, err = b.executeIncreaseExposure(trade, prices)
	case "Decrease Exposure":
		mainTx, err = b.executeDecreaseExposure(trade, prices)
	case "Close Position":
		mainTx, err = b.executeClosePosition(trade, prices)
	default:
		err = fmt.Errorf("Unsupported action type: %s", trade.Action.Type)
	}

	if err != nil {
		b.logMessage(fmt.Sprintf("Error creating main transaction: %v", err))
		return
	}

	b.logMessage("Main transaction created successfully")

	// Send transaction(s)
	if mainTx != nil && tipTx != nil {
		b.logMessage("Attempting to send transaction bundle...")
		bundleID, err := b.sendBundle([]*solana.Transaction{mainTx, tipTx})

		if err != nil {
			b.logMessage(fmt.Sprintf("Failed to send bundle: %v", err))
			b.logMessage("Falling back to sending individual transaction...")

			err = b.sendTransaction(mainTx)
			if err != nil {
				b.logMessage(fmt.Sprintf("Error sending main transaction: %v", err))
				return
			}
		} else {
			b.logMessage(fmt.Sprintf("Bundle sent successfully with ID: %s", bundleID))
		}
	} else if mainTx != nil {
		b.logMessage("Sending main transaction only...")
		err = b.sendTransaction(mainTx)
		if err != nil {
			b.logMessage(fmt.Sprintf("Error sending main transaction: %v", err))
			return
		}
	} else {
		b.logMessage("No valid transactions to send")
		return
	}

	// Mark as executed
	trade.Action.Executed = true
	now := time.Now()
	trade.ExecutedAt = &now

	b.logMessage(fmt.Sprintf("Action executed successfully for condition %s", trade.ID))

	// Refresh display
	b.refreshTradesDisplay()
}

// executeIncreaseExposure creates a transaction to increase exposure
func (b *ConditionalBotScreen) executeIncreaseExposure(trade *ConditionalTrade, prices map[string]decimal.Decimal) (*solana.Transaction, error) {
	asset := trade.Action.Asset
	if asset == "" {
		asset = trade.Condition.Asset // Default to monitoring asset
	}

	// Calculate exposure amount
	var exposureAmount int64
	if b.amountTypeRadio.Selected == "Percentage (%)" {
		// TODO: Calculate based on current portfolio value
		// For now, use a fixed USD amount
		usdAmount := 1000.0 * trade.Action.Amount.InexactFloat64() / 100.0
		exposureAmount = quid.CalculateExposureAmount(usdAmount, asset, true)
	} else {
		// Direct units
		exposureAmount = quid.CalculateExposureAmount(trade.Action.Amount.InexactFloat64(), asset, true)
	}

	b.logMessage(fmt.Sprintf("Increasing %s exposure by %d units", asset, exposureAmount))

	// Get Pyth account for the asset
	pythAccounts := []solana.PublicKey{}
	if pythAccount, exists := b.pythPriceFeeds[asset]; exists {
		pythAccounts = append(pythAccounts, pythAccount)
	}

	// Build withdraw instruction with exposure=true
	instruction, err := b.quidClient.BuildWithdrawInstruction(
		b.fromAccount.PublicKey(),
		exposureAmount,
		asset,
		true, // exposure adjustment
		pythAccounts,
	)
	if err != nil {
		return nil, fmt.Errorf("Error building Quid instruction: %v", err)
	}

	// Get latest blockhash
	recentBlockhash, err := b.client.GetLatestBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, fmt.Errorf("failed to get latest blockhash: %v", err)
	}

	// Create transaction
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recentBlockhash.Value.Blockhash,
		solana.TransactionPayer(b.fromAccount.PublicKey()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create transaction: %v", err)
	}

	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to sign transaction: %v", err)
	}

	return tx, nil
}

// executeDecreaseExposure creates a transaction to decrease exposure
func (b *ConditionalBotScreen) executeDecreaseExposure(trade *ConditionalTrade, prices map[string]decimal.Decimal) (*solana.Transaction, error) {
	asset := trade.Action.Asset
	if asset == "" {
		asset = trade.Condition.Asset
	}

	// Calculate exposure amount (negative for decrease)
	var exposureAmount int64
	if b.amountTypeRadio.Selected == "Percentage (%)" {
		usdAmount := 1000.0 * trade.Action.Amount.InexactFloat64() / 100.0
		exposureAmount = quid.CalculateExposureAmount(usdAmount, asset, false)
	} else {
		exposureAmount = quid.CalculateExposureAmount(trade.Action.Amount.InexactFloat64(), asset, false)
	}

	b.logMessage(fmt.Sprintf("Decreasing %s exposure by %d units", asset, -exposureAmount))

	// Get Pyth account for the asset
	pythAccounts := []solana.PublicKey{}
	if pythAccount, exists := b.pythPriceFeeds[asset]; exists {
		pythAccounts = append(pythAccounts, pythAccount)
	}

	// Build withdraw instruction
	instruction, err := b.quidClient.BuildWithdrawInstruction(
		b.fromAccount.PublicKey(),
		exposureAmount,
		asset,
		true, // exposure adjustment
		pythAccounts,
	)
	if err != nil {
		return nil, fmt.Errorf("Error building Quid instruction: %v", err)
	}

	// Get latest blockhash
	recentBlockhash, err := b.client.GetLatestBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, fmt.Errorf("failed to get latest blockhash: %v", err)
	}

	// Create transaction
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recentBlockhash.Value.Blockhash,
		solana.TransactionPayer(b.fromAccount.PublicKey()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create transaction: %v", err)
	}

	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to sign transaction: %v", err)
	}

	return tx, nil
}

// executeClosePosition creates a transaction to close a position
func (b *ConditionalBotScreen) executeClosePosition(trade *ConditionalTrade, prices map[string]decimal.Decimal) (*solana.Transaction, error) {
	asset := trade.Condition.Asset

	// TODO: Query current position size from Quid
	// For now, assume we're closing a 100 unit position
	exposureAmount := quid.CalculateExposureAmount(100.0, asset, false)

	b.logMessage(fmt.Sprintf("Closing %s position", asset))

	// Get Pyth account for the asset
	pythAccounts := []solana.PublicKey{}
	if pythAccount, exists := b.pythPriceFeeds[asset]; exists {
		pythAccounts = append(pythAccounts, pythAccount)
	}

	// Build withdraw instruction to close position
	instruction, err := b.quidClient.BuildWithdrawInstruction(
		b.fromAccount.PublicKey(),
		exposureAmount,
		asset,
		true, // exposure adjustment
		pythAccounts,
	)
	if err != nil {
		return nil, fmt.Errorf("Error building Quid instruction: %v", err)
	}

	// Get latest blockhash
	recentBlockhash, err := b.client.GetLatestBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, fmt.Errorf("failed to get latest blockhash: %v", err)
	}

	// Create transaction
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recentBlockhash.Value.Blockhash,
		solana.TransactionPayer(b.fromAccount.PublicKey()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create transaction: %v", err)
	}

	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(b.fromAccount.PublicKey()) {
			return b.fromAccount
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to sign transaction: %v", err)
	}

	return tx, nil
}

// sendTransaction sends a single transaction using RPC
func (b *ConditionalBotScreen) sendTransaction(tx *solana.Transaction) error {
	serializedTx, err := tx.MarshalBinary()
	if err != nil {
		return fmt.Errorf("failed to serialize transaction: %v", err)
	}

	rpcRequest := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "sendTransaction",
		"params": []interface{}{
			base58.Encode(serializedTx),
			map[string]interface{}{
				"encoding":            "base58",
				"skipPreflight":       true,
				"preflightCommitment": "confirmed",
				"maxRetries":          5,
			},
		},
	}

	reqBody, err := json.Marshal(rpcRequest)
	if err != nil {
		return fmt.Errorf("failed to marshal RPC request: %v", err)
	}

	b.logMessage(fmt.Sprintf("Sending RPC request: %s", string(reqBody)))

	resp, err := http.Post(CNDTNL_ENDPOINT, "application/json", bytes.NewBuffer(reqBody))
	if err != nil {
		return fmt.Errorf("failed to send RPC request: %v", err)
	}
	defer resp.Body.Close()

	respBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %v", err)
	}

	b.logMessage(fmt.Sprintf("RPC response: %s", string(respBody)))

	var rpcResponse struct {
		Result string                 `json:"result"`
		Error  map[string]interface{} `json:"error"`
	}

	if err := json.Unmarshal(respBody, &rpcResponse); err != nil {
		return fmt.Errorf("failed to parse response: %v", err)
	}

	if rpcResponse.Error != nil {
		return fmt.Errorf("RPC error: %v", rpcResponse.Error)
	}

	b.logMessage(fmt.Sprintf("Transaction sent successfully with signature: %s", rpcResponse.Result))
	return nil
}

// createTipTransaction creates a transaction that sends tips to Jito
func (b *ConditionalBotScreen) createTipTransaction() (*solana.Transaction, error) {
	b.logMessage("Creating tip transaction...")

	recentBlockhash, err := b.client.GetLatestBlockhash(context.Background(), rpc.CommitmentFinalized)
	if err != nil {
		return nil, fmt.Errorf("failed to get latest blockhash: %v", err)
	}

	builder := solana.NewTransactionBuilder()
	builder.SetFeePayer(b.fromAccount.PublicKey())
	builder.SetRecentBlockHash(recentBlockhash.Value.Blockhash)

	jitoTipAccounts := []string{
		"96gYZGLnJYVFmbjzopPSU6QiEV5fGqZNyN9nmNhvrZU5",
		"DttWaMuVvTiduZRnguLF7jNxTgiMBZ1hyAumKUiL2KRL",
	}

	tipIndex := time.Now().UnixNano() % int64(len(jitoTipAccounts))
	tipAccount := jitoTipAccounts[tipIndex]

	tipAmount := uint64(5_000_000) // 0.005 SOL

	tipInstruction := system.NewTransferInstruction(
		tipAmount,
		b.fromAccount.PublicKey(),
		solana.MustPublicKeyFromBase58(tipAccount),
	).Build()

	builder.AddInstruction(tipInstruction)

	builder.AddInstruction(system.NewTransferInstruction(
		1_000_000, // 0.001 SOL
		b.fromAccount.PublicKey(),
		solana.MustPublicKeyFromBase58("juLesoSmdTcRtzjCzYzRoHrnF8GhVu6KCV7uxq7nJGp"),
	).Build())

	tx, err := builder.Build()
	if err != nil {
		return nil, fmt.Errorf("failed to build tip transaction: %v", err)
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

	b.logMessage(fmt.Sprintf("Tip transaction created and signed with signature: %s", tx.Signatures[0]))
	b.logMessage(fmt.Sprintf("Sending tip of %d lamports to Jito account %s", tipAmount, tipAccount))

	return tx, nil
}

// getPythPrices fetches prices from Pyth
func (b *ConditionalBotScreen) getPythPrices() (map[string]decimal.Decimal, error) {
	prices := make(map[string]decimal.Decimal)

	var priceIDs []string
	for _, id := range PythPriceIDs {
		priceIDs = append(priceIDs, id)
	}

	baseURL, err := url.Parse(CNDTNL_PYTH_PRICE_URL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse URL: %v", err)
	}

	params := url.Values{}
	for _, id := range priceIDs {
		params.Add("ids[]", id)
	}
	params.Set("parsed", "true")
	baseURL.RawQuery = params.Encode()

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(baseURL.String())
	if err != nil {
		return nil, fmt.Errorf("failed to fetch prices: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bad status code: %d", resp.StatusCode)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %v", err)
	}

	var pythResp struct {
		Parsed []struct {
			ID    string `json:"id"`
			Price struct {
				Price string `json:"price"`
				Expo  int    `json:"expo"`
			} `json:"price"`
		} `json:"parsed"`
	}

	if err := json.Unmarshal(body, &pythResp); err != nil {
		return nil, fmt.Errorf("failed to decode price response: %v", err)
	}

	// Map price IDs back to symbols
	idToSymbol := make(map[string]string)
	for symbol, id := range PythPriceIDs {
		idToSymbol[id] = symbol
	}

	for _, item := range pythResp.Parsed {
		symbol, ok := idToSymbol[item.ID]
		if !ok {
			continue
		}

		price, err := decimal.NewFromString(item.Price.Price)
		if err != nil {
			b.logMessage(fmt.Sprintf("Could not parse price for %s: %v", symbol, err))
			continue
		}

		exponent := decimal.New(1, int32(item.Price.Expo))
		prices[symbol] = price.Mul(exponent)
	}

	return prices, nil
}

// sendBundle sends a bundle of transactions to Jito
func (b *ConditionalBotScreen) sendBundle(transactions []*solana.Transaction) (string, error) {
	b.logMessage("Preparing transaction bundle...")

	if len(transactions) == 0 {
		return "", fmt.Errorf("no transactions to send")
	}

	if len(transactions) > 5 {
		return "", fmt.Errorf("bundle exceeds maximum of 5 transactions")
	}

	encodedTransactions := make([]string, len(transactions))
	for i, tx := range transactions {
		if len(tx.Signatures) == 0 {
			return "", fmt.Errorf("transaction %d is not signed", i)
		}

		encodedTx, err := tx.MarshalBinary()
		if err != nil {
			return "", fmt.Errorf("failed to encode transaction %d: %v", i, err)
		}

		encodedTransactions[i] = base64.StdEncoding.EncodeToString(encodedTx)
		b.logMessage(fmt.Sprintf("Encoded transaction %d with signature: %s",
			i+1, tx.Signatures[0].String()))
	}

	bundleData := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "sendBundle",
		"params": []interface{}{
			encodedTransactions,
			map[string]string{
				"encoding": "base64",
			},
		},
	}

	bundleJSON, err := json.Marshal(bundleData)
	if err != nil {
		return "", fmt.Errorf("failed to marshal bundle data: %v", err)
	}

	b.logMessage(fmt.Sprintf("Bundle request payload: %s", string(bundleJSON)))

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(
		CNDTNL_JITO_BUNDLE_URL,
		"application/json",
		bytes.NewBuffer(bundleJSON),
	)
	if err != nil {
		return "", fmt.Errorf("failed to send bundle: %v", err)
	}
	defer resp.Body.Close()

	respBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}

	b.logMessage(fmt.Sprintf("Raw bundle response: %s", string(respBody)))

	var result map[string]interface{}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("failed to decode bundle response: %v", err)
	}

	if errorData, ok := result["error"]; ok {
		errorMsg := "unknown error"
		if errObj, ok := errorData.(map[string]interface{}); ok {
			if msg, ok := errObj["message"].(string); ok {
				errorMsg = msg
			}
		}
		return "", fmt.Errorf("bundle error: %s", errorMsg)
	}

	bundleID, ok := result["result"].(string)
	if !ok {
		return "", fmt.Errorf("invalid bundle response format")
	}

	b.logMessage(fmt.Sprintf("Bundle successfully sent with ID: %s", bundleID))
	return bundleID, nil
}

// Helper function for logging
func (b *ConditionalBotScreen) logMessage(message string) {
	log.Println(message)
	b.log.SetText(b.log.Text + message + "\n")

	b.log.CursorRow = len(strings.Split(b.log.Text, "\n")) - 1
	b.log.Refresh()
}