// main.go - Updated with all integrations
package main

import (
	"fmt"
	"log"
	"os"
	"thuggable-go/internal/ui"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

func main() {
	// Create app
	myApp := app.NewWithID("com.thuggable.wallet")
	myApp.Settings().SetTheme(theme.DarkTheme())

	// Create main window
	myWindow := myApp.NewWindow("Thuggable Protocol")
	myWindow.Resize(fyne.NewSize(1200, 800))

	// Initialize wallet tabs
	walletTabs := ui.NewWalletTabs(nil)
	walletTabs.SetWindow(myWindow)
	walletTabs.SetApp(myApp)

	// Create wallet manager
	walletManager := ui.NewWalletManager(myWindow, walletTabs, myApp)

	// Create main content container
	mainContent := container.NewMax()
	walletTabs.SetMainContent(mainContent)

	// Create sidebar with all navigation options
	sidebar := ui.NewSidebar()
	
	// Navigation handlers
	sidebar.OnHomeClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewHomeScreen())
		ui.GetGlobalState().SetCurrentView("home")
	}
	
	sidebar.OnSendClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewSendScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("send")
	}
	
	sidebar.OnWalletClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(walletManager.NewWalletScreen())
		ui.GetGlobalState().SetCurrentView("wallet")
	}
	
	sidebar.OnExposureClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewExposureScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("exposure")
	}
	
	sidebar.OnCalypsoClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewCalypsoScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("calypso")
	}
	
	sidebar.OnConditionalBotClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewConditionalBotScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("conditionalbot")
	}
	
	sidebar.OnHardwareSignClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewSignScreen())
		ui.GetGlobalState().SetCurrentView("hardwaresign")
	}
	
	sidebar.OnTxInspectorClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewTransactionInspectorScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("txinspector")
	}
	
	sidebar.OnMultisigCreateClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewMultisigCreateScreen(myWindow))
		ui.GetGlobalState().SetCurrentView("multisigcreate")
	}
	
	sidebar.OnMultisigInfoClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewMultisigInfoScreen(myWindow))
		ui.GetGlobalState().SetCurrentView("multisiginfo")
	}
	
	// Add new navigation handlers
	sidebar.OnCasaBattleClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewCasaBattleScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("casabattle")
	}
	
	sidebar.OnVotingClicked = func() {
		mainContent.RemoveAll()
		mainContent.Add(ui.NewVotingScreen(myWindow, myApp))
		ui.GetGlobalState().SetCurrentView("voting")
	}

	// Create split container with sidebar and main content
	split := container.NewHSplit(
		sidebar,
		container.NewBorder(
			walletTabs.Container(), // Wallet tabs at top
			nil,                    // No bottom
			nil,                    // No left
			nil,                    // No right
			mainContent,            // Main content in center
		),
	)
	split.SetOffset(0.15) // Sidebar takes 15% of width

	// Set window content
	myWindow.SetContent(split)

	// Create system tray if supported
	if desk, ok := myApp.(desktop.App); ok {
		menu := fyne.NewMenu("Thuggable",
			fyne.NewMenuItem("Show", func() {
				myWindow.Show()
			}),
			fyne.NewMenuItem("Quit", func() {
				myApp.Quit()
			}),
		)
		desk.SetSystemTrayMenu(menu)
	}

	// Handle window close
	myWindow.SetCloseIntercept(func() {
		myWindow.Hide()
	})

	// Set initial view to home
	sidebar.OnHomeClicked()

	// Initialize background services
	go initializeServices(myApp, myWindow)

	// Show window and run
	myWindow.ShowAndRun()
}

func initializeServices(app fyne.App, window fyne.Window) {
	// Initialize Ethereum monitoring
	go func() {
		ethClient, err := ethereum.NewEthereumClient(
			"https://mainnet.infura.io/v3/YOUR_KEY",
			"0xRouterAddress",
			"0xAuxAddress",
			"0xBasketAddress",
		)
		if err != nil {
			log.Printf("Failed to initialize Ethereum client: %v", err)
			return
		}

		// Monitor for liquidation opportunities
		ctx := context.Background()
		ethClient.MonitorLiquidations(ctx, func(event *ethereum.LiquidationEvent) {
			// Handle liquidation event
			log.Printf("Liquidation opportunity: %v", event)
			
			// Show notification
			app.SendNotification(&fyne.Notification{
				Title:   "Liquidation Opportunity",
				Content: fmt.Sprintf("User %s can be liquidated", event.User.Hex()),
			})
		})
	}()

	// Initialize transcription service
	go func() {
		transConfig := transcription.TranscriptionConfig{
			ModelPath:      "models/ggml-base.en.bin",
			DatabasePath:   "battles.db",
			SampleRate:     16000,
			BufferDuration: 2 * time.Second,
		}
		
		_, err := transcription.NewRealtimeTranscriber(transConfig)
		if err != nil {
			log.Printf("Failed to initialize transcriber: %v", err)
		}
	}()

	// Initialize pre-signed clearing automation
	go func() {
		// Check for pending pre-signed calls every block
		ticker := time.NewTicker(15 * time.Second) // ~1 block on Ethereum
		defer ticker.Stop()

		for range ticker.C {
			// Check if any pre-signed clearSwaps calls should be executed
			// This would be handled by a keeper service in production
		}
	}()
}

// Update sidebar to include new screens
func updateSidebar() *ui.Sidebar {
	s := ui.NewSidebar()
	
	// Add Casa Battle button
	s.OnCasaBattleClicked = func() {
		// Navigation logic
	}
	
	// Add Voting button  
	s.OnVotingClicked = func() {
		// Navigation logic
	}
	
	return s
}