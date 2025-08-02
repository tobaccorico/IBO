package ui

import (
	"fmt"
	"strconv"
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
)

// Pyth price feed addresses (mainnet-beta)
var PythPriceFeeds = map[string]solana.PublicKey{
	"SOL": solana.MustPublicKeyFromBase58("H6ARHf6YXhGYeQfUzQNGk6rDNnLBQKrenN712K4AQJEG"),
	"BTC": solana.MustPublicKeyFromBase58("GVXRSBjFk6e6J3NbVPXohDJetcTjaeeuykUpbQF8UoMU"),
	"JTO": solana.MustPublicKeyFromBase58("D8UUgr8a3aR3yUeHLu7v8FWK7E8Y5sSU7qrYBXUJXBQ5"),
	// Add more as needed
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
	
	// Position tracking
	currentPositions map[string]*PositionInfo
}

type PositionInfo struct {
	Ticker    string
	Pledged   float64
	Exposure  float64
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
	s.adjustmentSlider.Step = 5
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
	refreshButton := widget.NewButton("Refresh", s.refreshPositions)
	
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
			),
			s.collateralInfo,
			widget.NewSeparator(),
			container.NewGridWithColumns(2,
				s.executeButton,
				refreshButton,
			),
			s.statusLabel,
		)),
		
		// Position summary card
		s.createPositionSummaryCard(),
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
	
	if len(s.currentPositions) == 0 {
		positionsBox.Add(widget.NewLabel("No active positions"))
	} else {
		for ticker, pos := range s.currentPositions {
			healthColor := theme.SuccessIcon()
			if pos.Health < 20 {
				healthColor = theme.ErrorIcon()
			} else if pos.Health < 50 {
				healthColor = theme.WarningIcon()
			}
			
			posCard := container.NewBorder(
				nil, nil,
				widget.NewLabel(ticker),
				widget.NewIcon(healthColor),
				container.NewVBox(
					widget.NewLabel(fmt.Sprintf("Exposure: %.2f%%", pos.Exposure)),
					widget.NewLabel(fmt.Sprintf("Collateral: $%.2f", pos.Pledged)),
				),
			)
			positionsBox.Add(posCard)
		}
	}
	
	return widget.NewCard("Positions", "", container.NewPadded(positionsBox))
}

func (s *ExposureScreen) onAssetSelected(asset string) {
	if asset == "" {
		return
	}
	
	// Update current exposure display
	if pos, exists := s.currentPositions[asset]; exists {
		s.currentExposure.SetText(fmt.Sprintf("Current exposure: %.2f%%", pos.Exposure))
	} else {
		s.currentExposure.SetText("Current exposure: 0%")
	}
	
	// Reset slider
	s.adjustmentSlider.SetValue(0)
	s.validateForm()
}

func (s *ExposureScreen) onSliderChanged(value float64) {
	s.adjustmentLabel.SetText(fmt.Sprintf("Adjustment: %+.0f%%", value))
	s.validateForm()
}

func (s *ExposureScreen) validateForm() {
	// Enable execute button only if:
	// 1. Asset is selected
	// 2. Adjustment is non-zero
	// 3. Wallet is loaded
	if s.assetSelect.Selected != "" && 
	   s.adjustmentSlider.Value != 0 && 
	   s.selectedWalletID != "" {
		s.executeButton.Enable()
	} else {
		s.executeButton.Disable()
	}
}

func (s *ExposureScreen) refreshPositions() {
	s.statusLabel.SetText("Refreshing positions...")
	
	// In a real implementation, this would:
	// 1. Fetch depositor account data
	// 2. Parse all positions
	// 3. Calculate current values
	// 4. Update the UI
	
	// For now, mock data
	s.currentPositions = map[string]*PositionInfo{
		"SOL": {Ticker: "SOL", Pledged: 1000, Exposure: 25.5, Health: 75},
		"BTC": {Ticker: "BTC", Pledged: 500, Exposure: -10.2, Health: 90},
	}
	
	// Update collateral info
	totalCollateral := 0.0
	for _, pos := range s.currentPositions {
		totalCollateral += pos.Pledged
	}
	s.collateralInfo.SetText(fmt.Sprintf("Total collateral: $%.2f", totalCollateral))
	
	// Refresh the display
	if s.assetSelect.Selected != "" {
		s.onAssetSelected(s.assetSelect.Selected)
	}
	
	s.statusLabel.SetText("Positions refreshed")
}

func (s *ExposureScreen) handleAdjustExposure() {
	if s.selectedWalletID == "" {
		dialog.ShowError(fmt.Errorf("no wallet selected"), s.window)
		return
	}
	
	asset := s.assetSelect.Selected
	adjustment := s.adjustmentSlider.Value
	
	// Calculate the actual exposure change
	// This is simplified - real implementation would consider:
	// 1. Current collateral
	// 2. Position limits
	// 3. Available USD*
	
	confirmText := fmt.Sprintf("Adjust %s exposure by %+.0f%%?", asset, adjustment)
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
	
	// Calculate the amount based on percentage
	// This is simplified - real implementation would:
	// 1. Get current prices
	// 2. Calculate proper amounts
	// 3. Check collateral requirements
	
	// For now, assume $1000 base for percentage calculation
	baseAmount := 1000.0
	adjustmentAmount := baseAmount * (adjustmentPercent / 100.0)
	
	// Convert to exposure amount
	exposureAmount := quid.CalculateExposureAmount(adjustmentAmount, asset, adjustmentPercent > 0)
	
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
	// ... (similar to send.go implementation)
	
	s.statusLabel.SetText(fmt.Sprintf("Adjusted %s exposure by %+.0f%%", asset, adjustmentPercent))
	s.adjustmentSlider.SetValue(0)
	s.executeButton.Enable()
	
	// Refresh positions after a delay
	go func() {
		<-time.After(5 * time.Second)
		s.refreshPositions()
	}()
}