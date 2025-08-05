package ui

import (
    "fmt"
    "strconv"
    "math/big"
    "log"
    
    "fyne.io/fyne/v2"
    "fyne.io/fyne/v2/container"
    "fyne.io/fyne/v2/dialog"
    "fyne.io/fyne/v2/widget"
    "fyne.io/fyne/v2/theme"
    
    "github.com/ethereum/go-ethereum/common"
    "thuggable-go/internal/ethereum"
)

type SelfManagedPosition struct {
    ID       uint64
    Token    string
    Amount   float64
    Distance int24
    Range    uint
    Status   string
}

type SelfManagedPositionsScreen struct {
    container     *fyne.Container
    positionsList *widget.List
    positions     []SelfManagedPosition
    window        fyne.Window
    app           fyne.App
    evmClient     *ethereum.EthereumClient // Use the actual ethereum client
}

func NewSelfManagedPositionsScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
    s := &SelfManagedPositionsScreen{
        window: window,
        app:    app,
        positions: []SelfManagedPosition{}, // Would load from chain
    }
    
    // Initialize EVM client for Router/Auxiliary interaction
    evmClient, err := ethereum.NewEthereumClient(
        "https://mainnet.infura.io/v3/YOUR_KEY",
        "0xRouterAddress",
        "0xAuxiliaryAddress",
        "", // Private key if needed
    )
    if err != nil {
        log_error("Failed to initialize EVM client: %v", err)
    } else {
        s.evmClient = evmClient
    }
    
    // Create position list
    s.positionsList = widget.NewList(
        func() int { return len(s.positions) },
        func() fyne.CanvasObject {
            return container.NewHBox(
                widget.NewLabel("ID: "),
                widget.NewLabel("Token: "),
                widget.NewLabel("Amount: "),
                widget.NewLabel("Status: "),
                widget.NewButton("Reclaim", nil),
            )
        },
        func(id widget.ListItemID, item fyne.CanvasObject) {
            if id < len(s.positions) {
                pos := s.positions[id]
                cont := item.(*fyne.Container)
                cont.Objects[0].(*widget.Label).SetText(fmt.Sprintf("ID: %d", pos.ID))
                cont.Objects[1].(*widget.Label).SetText(fmt.Sprintf("Token: %s", pos.Token))
                cont.Objects[2].(*widget.Label).SetText(fmt.Sprintf("Amount: %.4f", pos.Amount))
                cont.Objects[3].(*widget.Label).SetText(fmt.Sprintf("Status: %s", pos.Status))
                cont.Objects[4].(*widget.Button).OnTapped = func() {
                    s.reclaimPosition(pos)
                }
            }
        },
    )
    
    // Create new position button
    newPosButton := widget.NewButton("Create New Position", func() {
        s.createNewPosition()
    })
    newPosButton.Importance = widget.HighImportance
    
    // Add ETH liquidity button
    addLiquidityButton := widget.NewButton("Add ETH Liquidity", func() {
        s.addETHLiquidity()
    })
    
    s.container = container.NewBorder(
        container.NewVBox(
            widget.NewLabelWithStyle("Self-Managed Positions", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
            widget.NewCard("", "Manage your out-of-range liquidity positions", nil),
            container.NewHBox(newPosButton, addLiquidityButton),
        ),
        nil, nil, nil,
        s.positionsList,
    )
    
    return s.container
}

func (s *SelfManagedPositionsScreen) createNewPosition() {
    tokenSelect := widget.NewSelect([]string{"ETH", "USDC", "USDT", "DAI"}, nil)
    amountEntry := widget.NewEntry()
    amountEntry.SetPlaceHolder("Amount")
    
    // Distance from current price in percentage points (100 = 1%)
    distanceEntry := widget.NewEntry()
    distanceEntry.SetPlaceHolder("Distance from price (%, negative for below)")
    
    // Range width in percentage points
    rangeEntry := widget.NewEntry()
    rangeEntry.SetPlaceHolder("Range width (%)")
    
    content := container.NewVBox(
        widget.NewLabel("Create Out-of-Range Position"),
        widget.NewLabel("Token:"),
        tokenSelect,
        widget.NewLabel("Amount:"),
        amountEntry,
        widget.NewLabel("Distance from current price:"),
        distanceEntry,
        widget.NewLabel("Range width:"),
        rangeEntry,
    )
    
    dialog.ShowCustomConfirm("New Position", "Create", "Cancel", content, func(create bool) {
        if create {
            if tokenSelect.Selected == "" || amountEntry.Text == "" || 
               distanceEntry.Text == "" || rangeEntry.Text == "" {
                dialog.ShowError(fmt.Errorf("All fields required"), s.window)
                return
            }
            
            amount, err := strconv.ParseFloat(amountEntry.Text, 64)
            if err != nil {
                dialog.ShowError(fmt.Errorf("Invalid amount"), s.window)
                return
            }
            
            distance, err := strconv.ParseInt(distanceEntry.Text, 10, 32)
            if err != nil {
                dialog.ShowError(fmt.Errorf("Invalid distance"), s.window)
                return
            }
            
            rangeWidth, err := strconv.ParseUint(rangeEntry.Text, 10, 32)
            if err != nil || rangeWidth < 1 || rangeWidth > 10 {
                dialog.ShowError(fmt.Errorf("Range width must be 1-10%"), s.window)
                return
            }
            
            // Convert percentage to ticks (100 = 1%)
            distanceTicks := int32(distance * 100)
            rangeWidthBps := uint32(rangeWidth * 100)
            
            // Convert amount to wei/smallest unit
            amountBig := new(big.Int)
            if tokenSelect.Selected == "ETH" {
                amountBig.SetString(fmt.Sprintf("%.0f", amount*1e18), 10)
            } else {
                amountBig.SetString(fmt.Sprintf("%.0f", amount*1e6), 10)
            }
            
            // Get token address (0x0 for ETH)
            var tokenAddr common.Address
            if tokenSelect.Selected != "ETH" {
                // In production, map token symbols to addresses
                tokenAddr = common.HexToAddress("0x0") // placeholder
            }
            
            go s.submitCreatePosition(tokenAddr, amountBig, distanceTicks, rangeWidthBps)
        }
    }, s.window)
}

func (s *SelfManagedPositionsScreen) addETHLiquidity() {
    amountEntry := widget.NewEntry()
    amountEntry.SetPlaceHolder("ETH Amount")
    
    content := container.NewVBox(
        widget.NewLabel("Add ETH Liquidity to Auto-Managed Pool"),
        widget.NewLabel("This will be managed by the protocol for optimal returns"),
        amountEntry,
    )
    
    dialog.ShowCustomConfirm("Add Liquidity", "Deposit", "Cancel", content, func(deposit bool) {
        if deposit {
            amount, err := strconv.ParseFloat(amountEntry.Text, 64)
            if err != nil || amount <= 0 {
                dialog.ShowError(fmt.Errorf("Invalid amount"), s.window)
                return
            }
            
            amountWei := new(big.Int)
            amountWei.SetString(fmt.Sprintf("%.0f", amount*1e18), 10)
            
            go s.submitETHDeposit(amountWei)
        }
    }, s.window)
}

func (s *SelfManagedPositionsScreen) reclaimPosition(pos SelfManagedPosition) {
    percentEntry := widget.NewEntry()
    percentEntry.SetPlaceHolder("Percentage to reclaim (1-100)")
    
    content := container.NewVBox(
        widget.NewLabel(fmt.Sprintf("Position ID: %d", pos.ID)),
        widget.NewLabel(fmt.Sprintf("Token: %s", pos.Token)),
        widget.NewLabel(fmt.Sprintf("Current Amount: %.4f", pos.Amount)),
        percentEntry,
    )
    
    dialog.ShowCustomConfirm("Reclaim Position", "Reclaim", "Cancel", content, func(reclaim bool) {
        if reclaim {
            percent, err := strconv.ParseInt(percentEntry.Text, 10, 32)
            if err != nil || percent < 1 || percent > 100 {
                dialog.ShowError(fmt.Errorf("Invalid percentage"), s.window)
                return
            }
            
            go s.submitReclaimPosition(pos.ID, int32(percent))
        }
    }, s.window)
}

func (s *SelfManagedPositionsScreen) submitCreatePosition(token common.Address, amount *big.Int, distance int32, rangeWidth uint32) {
    progress := dialog.NewProgressInfinite("Creating position...", "Please wait", s.window)
    progress.Show()
    defer progress.Hide()
    
    // Call Router.outOfRange through ethereum client
    positionID, err := s.evmClient.CreateOutOfRangePosition(amount, token, distance, rangeWidth)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to create position: %v", err), s.window)
        return
    }
    
    dialog.ShowInformation("Success", 
        fmt.Sprintf("Position created with ID: %d", positionID), 
        s.window)
    
    // Refresh positions list
    s.refreshPositions()
}

func (s *SelfManagedPositionsScreen) submitETHDeposit(amount *big.Int) {
    progress := dialog.NewProgressInfinite("Depositing ETH...", "Please wait", s.window)
    progress.Show()
    defer progress.Hide()
    
    // Call Router.deposit through ethereum client
    err := s.evmClient.DepositETH(amount)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to deposit: %v", err), s.window)
        return
    }
    
    dialog.ShowInformation("Success", "ETH deposited successfully", s.window)
}

func (s *SelfManagedPositionsScreen) submitReclaimPosition(id uint64, percent int32) {
    progress := dialog.NewProgressInfinite("Reclaiming position...", "Please wait", s.window)
    progress.Show()
    defer progress.Hide()
    
    // Call Router.reclaim through ethereum client
    err := s.evmClient.ReclaimPosition(id, percent)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to reclaim: %v", err), s.window)
        return
    }
    
    dialog.ShowInformation("Success", 
        fmt.Sprintf("Reclaimed %d%% of position %d", percent, id), 
        s.window)
    
    // Refresh positions list
    s.refreshPositions()
}

func (s *SelfManagedPositionsScreen) refreshPositions() {
    // In production, this would query the blockchain for user's positions
    // For now, just refresh the UI
    s.positionsList.Refresh()
}