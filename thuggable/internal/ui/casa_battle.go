package ui

import (
    "context"
    "fmt"
    "strings"
    "time"
    
    "fyne.io/fyne/v2"
    "fyne.io/fyne/v2/container"
    "fyne.io/fyne/v2/dialog"
    "fyne.io/fyne/v2/widget"
    "fyne.io/fyne/v2/theme"
    
    "thuggable-go/internal/quid"
    "thuggable-go/internal/twitter"
    "thuggable-go/internal/transcription"
    
    "github.com/gagliardetto/solana-go"
)

type CasaBattleScreen struct {
    container          *fyne.Container
    battlesList        *widget.List
    activeBattles      []quid.Battle
    window             fyne.Window
    app                fyne.App
    quidClient         *quid.Client
    twitterClient      *twitter.Client
    transcriber        *transcription.RealtimeTranscriber
    selectedWallet     string
}

func NewCasaBattleScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
    c := &CasaBattleScreen{
        window:         window,
        app:            app,
        activeBattles:  []quid.Battle{},
        selectedWallet: GetGlobalState().GetSelectedWallet(),
    }
    
    // Initialize clients
    c.initializeClients()
    
    // Create battles list
    c.battlesList = widget.NewList(
        func() int { return len(c.activeBattles) },
        func() fyne.CanvasObject {
            return container.NewVBox(
                widget.NewCard("", "", container.NewVBox(
                    widget.NewLabel("Battle ID: "),
                    widget.NewLabel("Challenger: "),
                    widget.NewLabel("Stake: "),
                    widget.NewLabel("Status: "),
                    container.NewHBox(
                        widget.NewButton("View", nil),
                        widget.NewButton("Accept", nil),
                    ),
                )),
            )
        },
        func(id widget.ListItemID, item fyne.CanvasObject) {
            if id < len(c.activeBattles) {
                battle := c.activeBattles[id]
                card := item.(*fyne.Container).Objects[0].(*widget.Card)
                vbox := card.Content.(*fyne.Container)
                
                vbox.Objects[0].(*widget.Label).SetText(fmt.Sprintf("Battle ID: %d", battle.ID))
                vbox.Objects[1].(*widget.Label).SetText(fmt.Sprintf("Challenger: %s", shortenAddress(battle.Challenger)))
                vbox.Objects[2].(*widget.Label).SetText(fmt.Sprintf("Stake: %.2f USD*", float64(battle.StakeAmount)/1e6))
                vbox.Objects[3].(*widget.Label).SetText(fmt.Sprintf("Status: %s", battle.Phase))
                
                buttons := vbox.Objects[4].(*fyne.Container)
                buttons.Objects[0].(*widget.Button).OnTapped = func() {
                    c.viewBattle(battle)
                }
                buttons.Objects[1].(*widget.Button).OnTapped = func() {
                    c.acceptBattle(battle)
                }
                
                // Disable accept button if not open or user is challenger
                if battle.Phase != "Open" || battle.Challenger == c.selectedWallet {
                    buttons.Objects[1].(*widget.Button).Disable()
                }
            }
        },
    )
    
    // Create new battle button
    newBattleBtn := widget.NewButtonWithIcon("Create Battle", theme.ContentAddIcon(), func() {
        c.createNewBattle()
    })
    newBattleBtn.Importance = widget.HighImportance
    
    // Refresh button
    refreshBtn := widget.NewButtonWithIcon("Refresh", theme.ViewRefreshIcon(), func() {
        c.refreshBattles()
    })
    
    // Battle controls
    controls := container.NewHBox(
        newBattleBtn,
        refreshBtn,
    )
    
    // Instructions card
    instructions := widget.NewCard("Casa Battle Rules", "", container.NewVBox(
        widget.NewLabel("1. Challenge with your exposure position as stake"),
        widget.NewLabel("2. Defender must match stake with their position"),
        widget.NewLabel("3. Battle through Twitter rap verses"),
        widget.NewLabel("4. Community votes determine winner"),
        widget.NewLabel("5. Winner takes both stakes"),
        widget.NewLabel("6. Active battles grant 4-day liquidation grace"),
    ))
    
    c.container = container.NewBorder(
        container.NewVBox(
            widget.NewLabelWithStyle("Casa Battles", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
            instructions,
            controls,
        ),
        nil, nil, nil,
        container.NewVScroll(c.battlesList),
    )
    
    // Initial load
    c.refreshBattles()
    
    // Start monitoring for new battles
    go c.monitorBattles()
    
    return c.container
}

func (c *CasaBattleScreen) initializeClients() {
    // Initialize Quid client
    endpoint := "https://api.devnet.solana.com"
    c.quidClient = quid.NewClient(endpoint)
    
    // Initialize EVM connection
    c.quidClient.InitializeEVM(
        "https://mainnet.infura.io/v3/YOUR_KEY",
        "0xRouterAddress",
        "0xAuxiliaryAddress",
    )
    
    // Initialize Twitter client for battle verification
    c.twitterClient = twitter.NewClient()
    
    // Initialize transcription for battle judging
    config := transcription.TranscriptionConfig{
        ModelPath:      "models/ggml-base.en.bin",
        SampleRate:     16000,
        BufferDuration: 2 * time.Second,
    }
    c.transcriber, _ = transcription.NewRealtimeTranscriber(config)
}

func (c *CasaBattleScreen) createNewBattle() {
    // Get user's positions
    positions := c.quidClient.GetUserPositions()
    if len(positions) == 0 {
        dialog.ShowError(fmt.Errorf("No positions available for staking"), c.window)
        return
    }
    
    // Create form
    tickerSelect := widget.NewSelect(positions, nil)
    stakeEntry := widget.NewEntry()
    stakeEntry.SetPlaceHolder("Stake amount (USD*)")
    tweetEntry := widget.NewEntry()
    tweetEntry.SetPlaceHolder("Initial tweet URL (x.com/...)")
    
    content := container.NewVBox(
        widget.NewLabel("Create New Battle"),
        widget.NewLabel("Select position to stake:"),
        tickerSelect,
        widget.NewLabel("Stake amount:"),
        stakeEntry,
        widget.NewLabel("Initial battle tweet:"),
        tweetEntry,
    )
    
    dialog.ShowCustomConfirm("Create Battle", "Create", "Cancel", content, func(create bool) {
        if create {
            if tickerSelect.Selected == "" || stakeEntry.Text == "" || tweetEntry.Text == "" {
                dialog.ShowError(fmt.Errorf("All fields required"), c.window)
                return
            }
            
            // Validate tweet URL
            if !strings.Contains(tweetEntry.Text, "x.com/") && !strings.Contains(tweetEntry.Text, "twitter.com/") {
                dialog.ShowError(fmt.Errorf("Invalid tweet URL"), c.window)
                return
            }
            
            // Parse stake amount
            var stakeAmount float64
            fmt.Sscanf(stakeEntry.Text, "%f", &stakeAmount)
            if stakeAmount < 100 {
                dialog.ShowError(fmt.Errorf("Minimum stake is 100 USD*"), c.window)
                return
            }
            
            // Create battle transaction
            go c.submitCreateBattle(tickerSelect.Selected, uint64(stakeAmount*1e6), tweetEntry.Text)
        }
    }, c.window)
}

func (c *CasaBattleScreen) acceptBattle(battle quid.Battle) {
    // Get user's positions
    positions := c.quidClient.GetUserPositions()
    if len(positions) == 0 {
        dialog.ShowError(fmt.Errorf("No positions available for staking"), c.window)
        return
    }
    
    // Create form
    tickerSelect := widget.NewSelect(positions, nil)
    tweetEntry := widget.NewEntry()
    tweetEntry.SetPlaceHolder("Reply tweet URL (must be reply to challenger's tweet)")
    
    content := container.NewVBox(
        widget.NewLabel(fmt.Sprintf("Accept Battle #%d", battle.ID)),
        widget.NewLabel(fmt.Sprintf("Required stake: %.2f USD*", float64(battle.StakeAmount)/1e6)),
        widget.NewLabel("Select position to stake:"),
        tickerSelect,
        widget.NewLabel("Battle reply tweet:"),
        tweetEntry,
    )
    
    dialog.ShowCustomConfirm("Accept Battle", "Accept", "Cancel", content, func(accept bool) {
        if accept {
            if tickerSelect.Selected == "" || tweetEntry.Text == "" {
                dialog.ShowError(fmt.Errorf("All fields required"), c.window)
                return
            }
            
            // Validate tweet is a reply
            if !c.validateReplyTweet(tweetEntry.Text, battle.ChallengerTweetURI) {
                dialog.ShowError(fmt.Errorf("Tweet must be a reply to challenger's tweet"), c.window)
                return
            }
            
            // Accept battle transaction
            go c.submitAcceptBattle(battle.ID, tickerSelect.Selected, tweetEntry.Text)
        }
    }, c.window)
}

func (c *CasaBattleScreen) viewBattle(battle quid.Battle) {
    content := container.NewVBox(
        widget.NewLabelWithStyle(fmt.Sprintf("Battle #%d", battle.ID), 
            fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
        widget.NewSeparator(),
        widget.NewLabel(fmt.Sprintf("Challenger: %s", battle.Challenger)),
        widget.NewLabel(fmt.Sprintf("Defender: %s", battle.Defender)),
        widget.NewLabel(fmt.Sprintf("Stake: %.2f USD*", float64(battle.StakeAmount)/1e6)),
        widget.NewLabel(fmt.Sprintf("Status: %s", battle.Phase)),
        widget.NewLabel(fmt.Sprintf("Created: %s", battle.CreatedAt.Format("Jan 2 15:04"))),
    )
    
    if battle.ChallengerTweetURI != "" {
        challengerLink := widget.NewHyperlink("View Challenger Tweet", 
            parseURL("https://"+battle.ChallengerTweetURI))
        content.Add(challengerLink)
    }
    
    if battle.DefenderTweetURI != "" {
        defenderLink := widget.NewHyperlink("View Defender Tweet", 
            parseURL("https://"+battle.DefenderTweetURI))
        content.Add(defenderLink)
    }
    
    if battle.Winner != nil {
        content.Add(widget.NewSeparator())
        content.Add(widget.NewLabelWithStyle(
            fmt.Sprintf("Winner: %s", *battle.Winner),
            fyne.TextAlignCenter, fyne.TextStyle{Bold: true}))
    }
    
    // If battle is active and user is authority, show finalize button
    if battle.Phase == "Active" && c.isAuthority() {
        finalizeBtn := widget.NewButton("Finalize Battle", func() {
            c.finalizeBattle(battle)
        })
        finalizeBtn.Importance = widget.HighImportance
        content.Add(finalizeBtn)
    }
    
    dialog.ShowCustom(fmt.Sprintf("Battle #%d Details", battle.ID), "Close", content, c.window)
}

func (c *CasaBattleScreen) submitCreateBattle(ticker string, stakeAmount uint64, tweetURI string) {
    ctx := context.Background()
    
    // Show loading
    progress := dialog.NewProgressInfinite("Creating battle...", "Please wait", c.window)
    progress.Show()
    defer progress.Hide()
    
    // Create battle instruction
    tx, err := c.quidClient.CreateBattle(ctx, stakeAmount, ticker, tweetURI)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to create battle: %v", err), c.window)
        return
    }
    
    // Send transaction
    sig, err := c.quidClient.SendTransaction(ctx, tx)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to send transaction: %v", err), c.window)
        return
    }
    
    dialog.ShowInformation("Success", 
        fmt.Sprintf("Battle created!\nSignature: %s", shortenHash(sig.String())), 
        c.window)
    
    // Refresh battles
    c.refreshBattles()
}

func (c *CasaBattleScreen) submitAcceptBattle(battleID uint64, ticker, tweetURI string) {
    ctx := context.Background()
    
    // Show loading
    progress := dialog.NewProgressInfinite("Accepting battle...", "Please wait", c.window)
    progress.Show()
    defer progress.Hide()
    
    // Accept battle instruction
    tx, err := c.quidClient.AcceptBattle(ctx, battleID, ticker, tweetURI)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to accept battle: %v", err), c.window)
        return
    }
    
    // Send transaction
    sig, err := c.quidClient.SendTransaction(ctx, tx)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to send transaction: %v", err), c.window)
        return
    }
    
    dialog.ShowInformation("Success", 
        fmt.Sprintf("Battle accepted!\nSignature: %s", shortenHash(sig.String())), 
        c.window)
    
    // Refresh battles
    c.refreshBattles()
}

func (c *CasaBattleScreen) finalizeBattle(battle quid.Battle) {
    // Show dialog to determine winner based on verse quality
    content := container.NewVBox(
        widget.NewLabel("Judge battle outcome:"),
        widget.NewRadioGroup([]string{
            "Challenger broke defender's streak",
            "Defender broke challenger's streak", 
            "Both maintained streak (coin flip)",
        }, nil),
    )
    
    dialog.ShowCustomConfirm("Judge Battle", "Sign Decision", "Cancel", content, func(submit bool) {
        if submit {
            radio := content.Objects[1].(*widget.RadioGroup)
            var result quid.OracleResult
            
            switch radio.Selected {
            case "Challenger broke defender's streak":
                result.ChallengerBrokeStreak = true
                result.DefenderBrokeStreak = false
            case "Defender broke challenger's streak":
                result.ChallengerBrokeStreak = false
                result.DefenderBrokeStreak = true
            default:
                result.ChallengerBrokeStreak = false
                result.DefenderBrokeStreak = false
            }
            
            // Start MPC signing process
            c.coordinateMPCSettlement(battle, result)
        }
    }, c.window)
}

func (c *CasaBattleScreen) coordinateMPCSettlement(battle quid.Battle, result quid.OracleResult) {
    // In a real implementation, this would coordinate MPC signing
    // For now, we'll simulate the process
    dialog.ShowInformation("MPC Signing", 
        "Battle settlement requires signatures from challenger, defender, and judge.\n" +
        "This would trigger the MPC signing process in production.", 
        c.window)
}

func (c *CasaBattleScreen) refreshBattles() {
    // Fetch battles from chain
    ctx := context.Background()
    battles, err := c.quidClient.GetBattles(ctx)
    if err != nil {
        // Log error but don't show dialog
        return
    }
    
    c.activeBattles = battles
    c.battlesList.Refresh()
}

func (c *CasaBattleScreen) monitorBattles() {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for range ticker.C {
        c.refreshBattles()
    }
}

func (c *CasaBattleScreen) validateReplyTweet(replyURL, originalURL string) bool {
    // Extract tweet IDs and verify reply relationship
    // This would use Twitter API in production
    return strings.Contains(replyURL, "x.com/") || strings.Contains(replyURL, "twitter.com/")
}

func (c *CasaBattleScreen) isAuthority() bool {
    // Check if current wallet is the battle authority
    // In production, this would check against the program's authority
    return false
}

func (c *CasaBattleScreen) isJudge() bool {
    // Check if current wallet is an authorized judge
    return false
}

func parseURL(urlStr string) *url.URL {
    u, _ := url.Parse(urlStr)
    return u
}

func shortenHash(hash string) string {
    if len(hash) <= 12 {
        return hash
    }
    return fmt.Sprintf("%s...%s", hash[:6], hash[len(hash)-6:])
}