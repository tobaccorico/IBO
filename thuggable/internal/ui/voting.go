package ui

import (
    "fmt"
    "strconv"
    "strings"
    
    "fyne.io/fyne/v2"
    "fyne.io/fyne/v2/container"
    "fyne.io/fyne/v2/dialog"
    "fyne.io/fyne/v2/widget"
    "fyne.io/fyne/v2/data/binding"
    
    "thuggable-go/internal/ethereum"
    "github.com/shopspring/decimal"
)

type VotingScreen struct {
    container       *fyne.Container
    window          fyne.Window
    app             fyne.App
    ethClient       *ethereum.EthereumClient
    currentTargets  map[string]float64
    sliders         map[string]*widget.Slider
    labels          map[string]*widget.Label
    totalLabel      *widget.Label
    voteButton      *widget.Button
}

func NewVotingScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
    v := &VotingScreen{
        window:         window,
        app:            app,
        currentTargets: make(map[string]float64),
        sliders:        make(map[string]*widget.Slider),
        labels:         make(map[string]*widget.Label),
    }
    
    // Initialize Ethereum client
    v.initializeEthClient()
    
    // Stablecoins to vote on (from Basket.sol)
    stables := []string{"USDC", "USDT", "DAI", "FRAX", "GHO"}
    
    // Create voting interface
    votingContent := container.NewVBox(
        widget.NewLabelWithStyle("Vote on Basket Allocations", 
            fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
        widget.NewLabel("Adjust target allocations for basket stablecoins:"),
        widget.NewSeparator(),
    )
    
    // Create slider for each stablecoin
    for _, stable := range stables {
        stableName := stable
        
        // Initialize with equal distribution
        v.currentTargets[stableName] = 100.0 / float64(len(stables))
        
        label := widget.NewLabel(fmt.Sprintf("%s: %.1f%%", stableName, v.currentTargets[stableName]))
        v.labels[stableName] = label
        
        slider := widget.NewSlider(0, 100)
        slider.Value = v.currentTargets[stableName]
        slider.Step = 0.1
        slider.OnChanged = func(value float64) {
            v.onSliderChanged(stableName, value)
        }
        v.sliders[stableName] = slider
        
        row := container.NewBorder(nil, nil, label, nil, slider)
        votingContent.Add(row)
    }
    
    // Total allocation display
    v.totalLabel = widget.NewLabelWithStyle("Total: 100.0%", 
        fyne.TextAlignCenter, fyne.TextStyle{Bold: true})
    votingContent.Add(widget.NewSeparator())
    votingContent.Add(v.totalLabel)
    
    // Vote button
    v.voteButton = widget.NewButton("Submit Vote", v.submitVote)
    v.voteButton.Importance = widget.HighImportance
    votingContent.Add(v.voteButton)
    
    // Instructions
    instructions := widget.NewCard("Voting Instructions", "", container.NewVBox(
        widget.NewLabel("• Adjust sliders to set target allocations"),
        widget.NewLabel("• Total must equal 100%"),
        widget.NewLabel("• Votes are weighted by your QD balance"),
        widget.NewLabel("• New targets apply via weighted median"),
        widget.NewLabel("• Voting power refreshes weekly"),
    ))
    
    // Current allocations display
    currentCard := widget.NewCard("Current Allocations", "", v.createCurrentAllocationsDisplay())
    
    // Layout
    v.container = container.NewVBox(
        instructions,
        widget.NewSeparator(),
        votingContent,
        widget.NewSeparator(),
        currentCard,
    )
    
    return container.NewScroll(v.container)
}

func (v *VotingScreen) initializeEthClient() {
    // Initialize connection to Basket.sol
    v.ethClient, _ = ethereum.NewEthereumClient(
        "https://mainnet.infura.io/v3/YOUR_KEY",
        "", // Router not needed for voting
        "", // Aux not needed for voting
        "0xBasketAddress",
    )
}

func (v *VotingScreen) onSliderChanged(stable string, value float64) {
    v.currentTargets[stable] = value
    v.labels[stable].SetText(fmt.Sprintf("%s: %.1f%%", stable, value))
    
    // Calculate total
    total := 0.0
    for _, target := range v.currentTargets {
        total += target
    }
    
    v.totalLabel.SetText(fmt.Sprintf("Total: %.1f%%", total))
    
    // Enable/disable vote button based on total
    if total >= 99.9 && total <= 100.1 {
        v.voteButton.Enable()
        v.totalLabel.TextStyle.Bold = true
    } else {
        v.voteButton.Disable()
        v.totalLabel.TextStyle.Bold = false
    }
    v.totalLabel.Refresh()
}

func (v *VotingScreen) submitVote() {
    // Verify total is 100%
    total := 0.0
    for _, target := range v.currentTargets {
        total += target
    }
    
    if total < 99.9 || total > 100.1 {
        dialog.ShowError(fmt.Errorf("Total allocation must equal 100%%"), v.window)
        return
    }
    
    // Normalize to exactly 100%
    var targets []uint64
    for _, stable := range []string{"USDC", "USDT", "DAI", "FRAX", "GHO"} {
        normalizedTarget := v.currentTargets[stable] * 1e16 // Convert to WAD basis points
        targets = append(targets, uint64(normalizedTarget))
    }
    
    // Show confirmation
    confirmText := strings.Builder{}
    confirmText.WriteString("Submit vote with allocations:\n\n")
    for stable, target := range v.currentTargets {
        confirmText.WriteString(fmt.Sprintf("%s: %.1f%%\n", stable, target))
    }
    
    dialog.ShowConfirm("Confirm Vote", confirmText.String(), func(confirmed bool) {
        if !confirmed {
            return
        }
        
        // In production, this would:
        // 1. Connect to MetaMask
        // 2. Call vote() function on Basket.sol
        // 3. Sign and submit transaction
        dialog.ShowInformation("Vote Submitted", 
            "Your vote has been recorded and will be included in the next epoch's weighted median calculation.", 
            v.window)
    }, v.window)
}

func (v *VotingScreen) createCurrentAllocationsDisplay() fyne.CanvasObject {
    // In production, this would fetch from Basket.sol
    currentAllocations := map[string]float64{
        "USDC": 25.0,
        "USDT": 20.0,
        "DAI":  20.0,
        "FRAX": 20.0,
        "GHO":  15.0,
    }
    
    display := container.NewVBox()
    for stable, allocation := range currentAllocations {
        bar := widget.NewProgressBar()
        bar.SetValue(allocation / 100.0)
        
        row := container.NewBorder(
            nil, nil,
            widget.NewLabel(fmt.Sprintf("%s: %.1f%%", stable, allocation)),
            nil,
            bar,
        )
        display.Add(row)
    }
    
    return display
}