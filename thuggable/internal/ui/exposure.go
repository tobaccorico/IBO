package ui

import (
	"context"
	"fmt"
	"strconv"
	"time"
	"thuggable-go/internal/quid"
	"thuggable-go/internal/storage"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/data/validation"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"
	"github.com/shopspring/decimal"
)

// Pyth price feed addresses (mainnet-beta)
var PythPriceFeeds = map[string]solana.PublicKey{
	"SOL": solana.MustPublicKeyFromBase58("H6ARHf6YXhGYeQfUzQNGk6rDNnLBQKrenN712K4AQJEG"),
	"BTC": solana.MustPublicKeyFromBase58("GVXRSBjFk6e6J3NbVPXohDJetcTjaeeuykUpbQF8UoMU"),
	"JTO": solana.MustPublicKeyFromBase58("D8UUgr8a3aR3yUeHLu7v8FWK7E8Y5sSU7qrYBXUJXBQ5"),
	"JUP": solana.MustPublicKeyFromBase58("g6eRCbboSwK4tSWngn773RCMexr1APQr4uA9bGZBYfo"),
	"XAU": solana.MustPublicKeyFromBase58("GZXW7j9C8UvWDtgTMqhXbHpbcaKdT1eKqnHHNBHHjqzC"),
}

type ExposureScreen struct {
	container       *fyne.Container
	window          fyne.Window
	app             fyne.App
	client          *rpc.Client
	quidClient      *quid.Client
	fromAccount     *solana.PrivateKey
	selectedWalletID string
	
	// UI elements
	assetSelect     *widget.Select
	currentExposure *widget.Label
	adjustmentSlider *widget.Slider
	adjustmentLabel *widget.Label
	collateralInfo  *widget.Label
	executeButton   *widget.Button
	statusLabel     *widget.Label
	refreshButton   *widget.Button
	
	// Position tracking
	currentPositions map[string]*PositionInfo
	totalCollateral  decimal.Decimal
	availableUSD     decimal.Decimal
}

type PositionInfo struct {
	Ticker    string
	Pledged   decimal.Decimal
	Exposure  decimal.Decimal
	Value     decimal.Decimal
	PnL       decimal.Decimal
	Health    float64 // percentage 0-100
}

func NewExposureScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
	s := &ExposureScreen{
		window:           window,
		app:              app,
		client:           rpc.New(CALYPSO_ENDPOINT),
		quidClient:      quid.NewClient(CALYPSO_ENDPOINT),
		currentPositions: make(map[string]*PositionInfo),
		statusLabel:     widget.NewLabel(""),
	}

	// Get selected wallet
	selectedWallet := GetGlobalState().GetSelectedWallet()
	if selectedWallet != "" {
		s.selectedWalletID = selectedWallet
		s.statusLabel.SetText(fmt.Sprintf("Wallet: %s", shortenAddress(selectedWallet)))
	} else {
		s.statusLabel.SetText("No wallet selected")
	}

	// Asset selection
	s.assetSelect = widget.NewSelect([]string{"SOL", "BTC", "JTO", "JUP", "XAU"}, s.onAssetSelected)
	s.assetSelect.PlaceHolder = "Select asset"

	// Current exposure display
	s.currentExposure = widget.NewLabel("Current exposure: --")
	
	// Adjustment slider (-100% to +100%)
	s.adjustmentSlider = widget.NewSlider(-100, 100)
	s.adjustmentSlider.Step = 1
	s.adjustmentSlider.Value = 0
	s.adjustmentSlider.OnChanged = s.onSliderChanged
	s.adjustmentLabel = widget.NewLabel("Adjustment: 0%")
	
	// Collateral info
	s.collateralInfo = widget.NewLabel("Available collateral: --")
	
	// Execute button
	s.executeButton = widget.NewButton("Adjust Exposure", s.handleAdjustExposure)
	s.executeButton.Importance = widget.HighImportance
	s.executeButton.Disable()
	
	// Refresh button
	s.refreshButton = widget.NewButton("Refresh", s.refreshPositions)
	
	// Quick adjustment buttons
	quickButtons := container.NewGridWithColumns(4,
		widget.NewButton("+10%", func() { s.adjustmentSlider.SetValue(10) }),
		widget.NewButton("+25%", func() { s.adjustmentSlider.SetValue(25) }),
		widget.NewButton("-25%", func() { s.adjustmentSlider.SetValue(-25) }),
		widget.NewButton("Close", func() { s.adjustmentSlider.SetValue(-100) }),
	)
	
	// Layout
	form := container.NewVBox(
		widget.NewCard("Exposure Management", "", container.NewVBox(
			container.NewGridWithColumns(2,
				widget.NewLabel("Asset:"),
				s.assetSelect,
			),
			s.currentExposure,
			widget.NewSeparator(),
			container.NewVBox(
				s.adjustmentLabel,
				s.adjustmentSlider,
				quickButtons,
			),
			s.collateralInfo,
			widget.NewSeparator(),
			container.NewGridWithColumns(2,
				s.executeButton,
				s.refreshButton,
			),
			s.statusLabel,
		)),
		
		// Position summary card
		s.createPositionSummaryCard(),
		
		// Risk metrics card
		s.createRiskMetricsCard(),
	)
	
	// Initial refresh if wallet is selected
	if selectedWallet != "" {
		go s.refreshPositions()
	}
	
	return container.NewScroll(form)
}

func (s *ExposureScreen) createPositionSummaryCard() fyne.CanvasObject {
	// This would show all current positions
	positionsBox := container.NewVBox(
		widget.NewLabelWithStyle("Active Positions", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
	)
	
	// We'll update this in refreshPositions
	return widget.NewCard("Positions", "", container.NewPadded(positionsBox))
}

func (s *ExposureScreen) createRiskMetricsCard() fyne.CanvasObject {
	metricsBox := container.NewVBox(
		widget.NewLabelWithStyle("Risk Metrics", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel("Total Exposure: --"),
		widget.NewLabel("Available Margin: --"),
		widget.NewLabel("Utilization Rate: --"),
		widget.NewLabel("Liquidation Risk: Low"),
	)
	
	return widget.NewCard("Risk Overview", "", container.NewPadded(metricsBox))
}

func (s *ExposureScreen) onAssetSelected(asset string) {
	if asset == "" {
		return
	}
	
	// Update current exposure display
	if pos, exists := s.currentPositions[asset]; exists {
		s.currentExposure.SetText(fmt.Sprintf("Current exposure: %.2f units (Value: $%.2f, PnL: $%.2f)",
			pos.Exposure.InexactFloat64(),
			pos.Value.InexactFloat64(),
			pos.PnL.InexactFloat64()))
	} else {
		s.currentExposure.SetText("Current exposure: 0 units")
	}
	
	// Reset slider
	s.adjustmentSlider.SetValue(0)
	s.validateForm()
}

func (s *ExposureScreen) onSliderChanged(value float64) {
	s.adjustmentLabel.SetText(fmt.Sprintf("Adjustment: %+.0f%%", value))
	
	// Calculate and display the USD impact
	if s.assetSelect.Selected != "" && s.currentPositions[s.assetSelect.Selected] != nil {
		pos := s.currentPositions[s.assetSelect.Selected]
		currentValue := pos.Value
		adjustmentUSD := currentValue.Mul(decimal.NewFromFloat(value / 100))
		
		s.adjustmentLabel.SetText(fmt.Sprintf("Adjustment: %+.0f%% ($%.2f)", 
			value, adjustmentUSD.InexactFloat64()))
	}
	
	s.validateForm()
}

func (s *ExposureScreen) validateForm() {
	// Enable execute button only if:
	// 1. Asset is selected
	// 2. Adjustment is non-zero  
	// 3. Wallet is loaded
	// 4. Sufficient collateral available
	if s.assetSelect.Selected != "" && 
	   s.adjustmentSlider.Value != 0 && 
	   s.selectedWalletID != "" {
		// Check collateral requirements
		if s.adjustmentSlider.Value > 0 {
			// Check if we have enough USD* for increasing exposure
			requiredCollateral := s.calculateRequiredCollateral()
			if s.availableUSD.GreaterThanOrEqual(requiredCollateral) {
				s.executeButton.Enable()
			} else {
				s.executeButton.Disable()
				s.statusLabel.SetText(fmt.Sprintf("Insufficient collateral: need $%.2f", 
					requiredCollateral.InexactFloat64()))
			}
		} else {
			// Decreasing exposure is always allowed
			s.executeButton.Enable()
		}
	} else {
		s.executeButton.Disable()
	}
}

func (s *ExposureScreen) calculateRequiredCollateral() decimal.Decimal {
	if s.assetSelect.Selected == "" || s.currentPositions[s.assetSelect.Selected] == nil {
		return decimal.Zero
	}
	
	pos := s.currentPositions[s.assetSelect.Selected]
	adjustmentPercent := decimal.NewFromFloat(s.adjustmentSlider.Value / 100)
	
	// Calculate new exposure amount
	newExposure := pos.Value.Mul(decimal.NewFromFloat(1).Add(adjustmentPercent))
	
	// Required collateral is 30% of exposure (allowing up to 3.33x leverage)
	return newExposure.Mul(decimal.NewFromFloat(0.3))
}

func (s *ExposureScreen) refreshPositions() {
	s.statusLabel.SetText("Refreshing positions...")
	
	// Query Quid positions from chain
	// This would fetch actual depositor account data
	
	// Mock data for now
	s.currentPositions = map[string]*PositionInfo{
		"SOL": {
			Ticker:   "SOL",
			Pledged:  decimal.NewFromFloat(1000),
			Exposure: decimal.NewFromFloat(2500), // 2.5x leverage
			Value:    decimal.NewFromFloat(2500),
			PnL:      decimal.NewFromFloat(150),
			Health:   75,
		},
		"BTC": {
			Ticker:   "BTC", 
			Pledged:  decimal.NewFromFloat(500),
			Exposure: decimal.NewFromFloat(-1000), // Short position
			Value:    decimal.NewFromFloat(1000),
			PnL:      decimal.NewFromFloat(-50),
			Health:   90,
		},
	}
	
	// Calculate total collateral
	s.totalCollateral = decimal.Zero
	for _, pos := range s.currentPositions {
		s.totalCollateral = s.totalCollateral.Add(pos.Pledged)
	}
	
	// Mock available USD*
	s.availableUSD = decimal.NewFromFloat(5000)
	
	// Update UI
	s.collateralInfo.SetText(fmt.Sprintf("Total collateral: $%.2f | Available USD*: $%.2f",
		s.totalCollateral.InexactFloat64(),
		s.availableUSD.InexactFloat64()))
	
	// Update position cards
	s.updatePositionCards()
	
	// Update risk metrics
	s.updateRiskMetrics()
	
	// Refresh the display
	if s.assetSelect.Selected != "" {
		s.onAssetSelected(s.assetSelect.Selected)
	}
	
	s.statusLabel.SetText("Positions refreshed")
}

func (s *ExposureScreen) updatePositionCards() {
	// Find the positions container in our UI
	for _, obj := range s.container.Objects {
		if scroll, ok := obj.(*container.Scroll); ok {
			if vbox, ok := scroll.Content.(*fyne.Container); ok {
				for _, card := range vbox.Objects {
					if c, ok := card.(*widget.Card); ok && c.Title == "Positions" {
						// Update the card content
						s.updatePositionContent(c)
						return
					}
				}
			}
		}
	}
}

func (s *ExposureScreen) updatePositionContent(card *widget.Card) {
	positionsBox := container.NewVBox(
		widget.NewLabelWithStyle("Active Positions", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
	)
	
	if len(s.currentPositions) == 0 {
		positionsBox.Add(widget.NewLabel("No active positions"))
	} else {
		// Sort positions by value
		var sortedTickers []string
		for ticker := range s.currentPositions {
			sortedTickers = append(sortedTickers, ticker)
		}
		
		for _, ticker := range sortedTickers {
			pos := s.currentPositions[ticker]
			
			// Determine health icon
			var healthIcon fyne.Resource
			if pos.Health < 20 {
				healthIcon = theme.ErrorIcon()
			} else if pos.Health < 50 {
				healthIcon = theme.WarningIcon()
			} else {
				healthIcon = theme.ConfirmIcon()
			}
			
			// Format exposure with leverage
			leverage := pos.Exposure.Div(pos.Pledged).Abs()
			exposureText := fmt.Sprintf("%.2fx", leverage.InexactFloat64())
			if pos.Exposure.IsNegative() {
				exposureText = "SHORT " + exposureText
			}
			
			// PnL color
			pnlStyle := fyne.TextStyle{}
			if pos.PnL.IsPositive() {
				pnlStyle.Bold = true
			}
			
			posCard := container.NewBorder(
				nil, nil,
				container.NewHBox(
					widget.NewLabelWithStyle(ticker, fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
					widget.NewLabel(exposureText),
				),
				widget.NewIcon(healthIcon),
				container.NewVBox(
					widget.NewLabel(fmt.Sprintf("Value: $%.2f", pos.Value.InexactFloat64())),
					widget.NewLabel(fmt.Sprintf("Collateral: $%.2f", pos.Pledged.InexactFloat64())),
					widget.NewLabelWithStyle(
						fmt.Sprintf("PnL: %+.2f", pos.PnL.InexactFloat64()),
						fyne.TextAlignLeading, pnlStyle,
					),
					widget.NewProgressBar().Binding(binding.BindFloat(&pos.Health)),
				),
			)
			
			positionsBox.Add(posCard)
			positionsBox.Add(widget.NewSeparator())
		}
	}
	
	card.Content = container.NewPadded(positionsBox)
	card.Refresh()
}

func (s *ExposureScreen) updateRiskMetrics() {
	// Calculate aggregate metrics
	totalExposure := decimal.Zero
	totalPnL := decimal.Zero
	maxLeverage := decimal.Zero
	
	for _, pos := range s.currentPositions {
		totalExposure = totalExposure.Add(pos.Value.Abs())
		totalPnL = totalPnL.Add(pos.PnL)
		
		leverage := pos.Exposure.Div(pos.Pledged).Abs()
		if leverage.GreaterThan(maxLeverage) {
			maxLeverage = leverage
		}
	}
	
	// Calculate utilization
	utilization := decimal.Zero
	if s.totalCollateral.IsPositive() {
		utilization = totalExposure.Div(s.totalCollateral.Add(s.availableUSD))
	}
	
	// Determine liquidation risk
	liquidationRisk := "Low"
	if utilization.GreaterThan(decimal.NewFromFloat(0.8)) {
		liquidationRisk = "High"
	} else if utilization.GreaterThan(decimal.NewFromFloat(0.6)) {
		liquidationRisk = "Medium"
	}
	
	// Update risk metrics card
	for _, obj := range s.container.Objects {
		if scroll, ok := obj.(*container.Scroll); ok {
			if vbox, ok := scroll.Content.(*fyne.Container); ok {
				for _, card := range vbox.Objects {
					if c, ok := card.(*widget.Card); ok && c.Title == "Risk Overview" {
						metricsBox := container.NewVBox(
							widget.NewLabelWithStyle("Risk Metrics", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
							widget.NewLabel(fmt.Sprintf("Total Exposure: $%.2f", totalExposure.InexactFloat64())),
							widget.NewLabel(fmt.Sprintf("Total PnL: %+.2f", totalPnL.InexactFloat64())),
							widget.NewLabel(fmt.Sprintf("Max Leverage: %.2fx", maxLeverage.InexactFloat64())),
							widget.NewLabel(fmt.Sprintf("Available Margin: $%.2f", s.availableUSD.InexactFloat64())),
							widget.NewLabel(fmt.Sprintf("Utilization Rate: %.1f%%", utilization.Mul(decimal.NewFromInt(100)).InexactFloat64())),
							widget.NewLabel(fmt.Sprintf("Liquidation Risk: %s", liquidationRisk)),
						)
						c.Content = container.NewPadded(metricsBox)
						c.Refresh()
						break
					}
				}
			}
		}
	}
}

func (s *ExposureScreen) handleAdjustExposure() {
	if s.selectedWalletID == "" {
		dialog.ShowError(fmt.Errorf("no wallet selected"), s.window)
		return
	}
	
	asset := s.assetSelect.Selected
	adjustment := s.adjustmentSlider.Value
	
	// Calculate the actual exposure change
	var exposureChange decimal.Decimal
	if pos, exists := s.currentPositions[asset]; exists {
		exposureChange = pos.Value.Mul(decimal.NewFromFloat(adjustment / 100))
	} else {
		// New position
		exposureChange = s.availableUSD.Mul(decimal.NewFromFloat(adjustment / 100))
	}
	
	confirmText := fmt.Sprintf("Adjust %s exposure by %+.0f%% ($%.2f)?",
		asset, adjustment, exposureChange.InexactFloat64())
		
	dialog.ShowConfirm("Confirm Adjustment", confirmText, func(confirmed bool) {
		if !confirmed {
			return
		}
		
		// Show password dialog
		passwordEntry := widget.NewPasswordEntry()
		passwordEntry.SetPlaceHolder("Enter wallet password")
		
		dialog.ShowCustomConfirm("Decrypt Wallet", "Execute", "Cancel", passwordEntry, func(confirm bool) {
			if !confirm {
				return
			}
			
			// Decrypt wallet
			if err := s.decryptAndPrepareWallet(passwordEntry.Text); err != nil {
				dialog.ShowError(err, s.window)
				return
			}
			
			// Execute the exposure adjustment
			go s.executeAdjustment(asset, adjustment)
		}, s.window)
	}, s.window)
}

func (s *ExposureScreen) decryptAndPrepareWallet(password string) error {
	walletStorage := storage.NewWalletStorage(s.app)
	walletMap, err := walletStorage.LoadWallets()
	if err != nil {
		return fmt.Errorf("error loading wallets: %v", err)
	}
	
	encryptedData, ok := walletMap[s.selectedWalletID]
	if !ok {
		return fmt.Errorf("wallet not found")
	}
	
	decryptedKey, err := decrypt(encryptedData, password)
	if err != nil {
		return fmt.Errorf("failed to decrypt wallet: %v", err)
	}
	
	privateKey := solana.MustPrivateKeyFromBase58(string(decryptedKey))
	s.fromAccount = &privateKey
	return nil
}

func (s *ExposureScreen) executeAdjustment(asset string, adjustmentPercent float64) {
	s.statusLabel.SetText("Building transaction...")
	s.executeButton.Disable()
	
	// Calculate the exposure amount
	var exposureAmount int64
	if pos, exists := s.currentPositions[asset]; exists {
		// Adjust existing position
		changeAmount := pos.Value.Mul(decimal.NewFromFloat(adjustmentPercent / 100))
		exposureAmount = quid.CalculateExposureAmount(
			changeAmount.InexactFloat64(),
			asset,
			adjustmentPercent > 0,
		)
	} else {
		// New position
		newAmount := s.availableUSD.Mul(decimal.NewFromFloat(adjustmentPercent / 100))
		exposureAmount = quid.CalculateExposureAmount(
			newAmount.InexactFloat64(),
			asset,
			true,
		)
	}
	
	// Get Pyth account for the asset
	pythAccounts := []solana.PublicKey{}
	if pythAccount, exists := PythPriceFeeds[asset]; exists {
		pythAccounts = append(pythAccounts, pythAccount)
	}
	
	// Build withdraw instruction with exposure=true
	instruction, err := s.quidClient.BuildWithdrawInstruction(
		s.fromAccount.PublicKey(),
		exposureAmount,
		asset,
		true, // exposure adjustment
		pythAccounts,
	)
	if err != nil {
		dialog.ShowError(fmt.Errorf("failed to build instruction: %v", err), s.window)
		s.executeButton.Enable()
		return
	}
	
	// Build and send transaction
	ctx := context.Background()
	recent, err := s.client.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
	if err != nil {
		dialog.ShowError(fmt.Errorf("failed to get blockhash: %v", err), s.window)
		s.executeButton.Enable()
		return
	}
	
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(s.fromAccount.PublicKey()),
	)
	if err != nil {
		dialog.ShowError(fmt.Errorf("failed to create transaction: %v", err), s.window)
		s.executeButton.Enable()
		return
	}
	
	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(s.fromAccount.PublicKey()) {
			return s.fromAccount
		}
		return nil
	})
	if err != nil {
		dialog.ShowError(fmt.Errorf("failed to sign transaction: %v", err), s.window)
		s.executeButton.Enable()
		return
	}
	
	// Send transaction
	sig, err := s.client.SendTransaction(ctx, tx)
	if err != nil {
		dialog.ShowError(fmt.Errorf("failed to send transaction: %v", err), s.window)
		s.executeButton.Enable()
		return
	}
	
	s.statusLabel.SetText(fmt.Sprintf("Transaction sent: %s", sig.String()))
	s.adjustmentSlider.SetValue(0)
	s.executeButton.Enable()
	
	// Refresh positions after a delay
	go func() {
		time.Sleep(5 * time.Second)
		s.refreshPositions()
	}()
}