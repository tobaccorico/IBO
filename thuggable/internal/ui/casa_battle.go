package ui

import (
    "context"
    "fmt"
    "strings"
    "time"
    "net/url"
    
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
    
    // If battle is active and user is participant, show MPC signing UI
    if battle.Phase == "Active" && (c.selectedWallet == battle.Challenger || c.selectedWallet == battle.Defender || c.isJudge()) {
        finalizeBtn := widget.NewButton("Sign Battle Result", func() {
            c.signBattleResult(battle)
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

func (c *CasaBattleScreen) signBattleResult(battle quid.Battle) {
    // Show dialog to determine winner
    content := container.NewVBox(
        widget.NewLabel("Sign your decision on the battle outcome:"),
        widget.NewRadioGroup([]string{
            "Challenger won",
            "Defender won", 
        }, nil),
    )
    
    dialog.ShowCustomConfirm("Sign Battle Result", "Sign", "Cancel", content, func(submit bool) {
        if submit {
            radio := content.Objects[1].(*widget.RadioGroup)
            if radio.Selected == "" {
                dialog.ShowError(fmt.Errorf("Please select a winner"), c.window)
                return
            }
            
            winnerIsChallenger := radio.Selected == "Challenger won"
            
            // In production, this would:
            // 1. Create the message to sign (battleID + winner)
            // 2. Sign with local wallet
            // 3. Store signature locally
            // 4. Wait for other signatures or submit if all collected
            c.coordinateMPCSignature(battle, winnerIsChallenger)
        }
    }, c.window)
}

func (c *CasaBattleScreen) coordinateMPCSignature(battle quid.Battle, winnerIsChallenger bool) {
    // Determine user's role in the battle
    var role string
    if c.selectedWallet == battle.Challenger {
        role = "challenger"
    } else if c.selectedWallet == battle.Defender {
        role = "defender"
    } else if c.isJudge() {
        role = "judge"
    } else {
        dialog.ShowError(fmt.Errorf("You are not a participant in this battle"), c.window)
        return
    }
    
    // Initialize MPC client
    mpcClient := NewBattleMPCClient()
    
    // Start or join signing session
    progress := dialog.NewProgressInfinite("Coordinating signatures...", "Please wait", c.window)
    progress.Show()
    
    go func() {
        defer progress.Hide()
        
        // Try to initiate a new session
        sessionID, err := mpcClient.InitiateBattleSigning(battle.ID, winnerIsChallenger, role, c.selectedWallet)
        if err != nil {
            // Session might already exist, try to get existing session ID
            // In production, this would be coordinated through a shared service
            sessionID = fmt.Sprintf("battle-%d", battle.ID)
            
            // Try to join existing session
            err = mpcClient.JoinBattleSigning(sessionID, role, c.selectedWallet)
            if err != nil {
                dialog.ShowError(fmt.Errorf("Failed to join signing session: %v", err), c.window)
                return
            }
        }
        
        // Create and sign the message locally
        message := CreateBattleMessage(battle.ID, winnerIsChallenger)
        
        // In production, this would use the actual MPC signing process
        // For now, create a mock signature
        signature := make([]byte, 64)
        copy(signature, []byte("mock_signature_for_"+role))
        
        // Submit signature
        err = mpcClient.SubmitSignature(sessionID, role, signature)
        if err != nil {
            dialog.ShowError(fmt.Errorf("Failed to submit signature: %v", err), c.window)
            return
        }
        
        // Wait for all signatures
        dialog.ShowInformation("Signature Submitted", 
            "Your signature has been submitted. Waiting for other parties...", 
            c.window)
        
        // Poll for completion
        signatures, err := mpcClient.WaitForCompletion(sessionID, 5*time.Minute)
        if err != nil {
            dialog.ShowError(fmt.Errorf("Failed to collect all signatures: %v", err), c.window)
            return
        }
        
        // Submit final transaction with all signatures
        c.submitFinalizedBattle(signatures)
    }()
}

func (c *CasaBattleScreen) submitFinalizedBattle(sigs *BattleSignatures) {
    ctx := context.Background()
    
    // Create finalize transaction with all signatures
    tx, err := c.quidClient.FinalizeBattleWithMPC(
        ctx,
        sigs.BattleID,
        sigs.WinnerIsChallenger,
        sigs.ChallengerSig,
        sigs.DefenderSig,
        sigs.JudgeSig,
    )
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to create finalize transaction: %v", err), c.window)
        return
    }
    
    // Send transaction
    sig, err := c.quidClient.SendTransaction(ctx, tx)
    if err != nil {
        dialog.ShowError(fmt.Errorf("Failed to send transaction: %v", err), c.window)
        return
    }
    
    dialog.ShowInformation("Battle Settled", 
        fmt.Sprintf("Battle has been settled!\nTransaction: %s", sig.String()), 
        c.window)
    
    // Refresh battles
    c.refreshBattles()
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

func (c *CasaBattleScreen) isJudge() bool {
    // Check if current wallet is an authorized judge
    // This would check against a list of authorized judges
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

func shortenAddress(addr string) string {
    if len(addr) <= 12 {
        return addr
    }
    return fmt.Sprintf("%s...%s", addr[:6], addr[len(addr)-4:])
}