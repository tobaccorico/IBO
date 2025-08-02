package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

type Sidebar struct {
	widget.BaseWidget
	OnHomeClicked           func()
	OnSendClicked           func()
	OnWalletClicked         func()
	OnExposureClicked       func()
	OnCalypsoClicked        func()
	OnConditionalBotClicked func()
	OnHardwareSignClicked   func()
	OnTxInspectorClicked    func()
	OnMultisigCreateClicked func()
	OnMultisigInfoClicked   func()
	OnCasaBattleClicked     func() 
	OnVotingClicked         func() 
	OnSelfManagedClicked    func()
}

func NewSidebar() *Sidebar {
	s := &Sidebar{}
	s.ExtendBaseWidget(s)
	return s
}

func (s *Sidebar) CreateRenderer() fyne.WidgetRenderer {
	// Core features
	homeBtn := widget.NewButton("🏠 Home", func() {
		if s.OnHomeClicked != nil {
			s.OnHomeClicked()
		}
	})
	
	sendBtn := widget.NewButton("💸 Send", func() {
		if s.OnSendClicked != nil {
			s.OnSendClicked()
		}
	})
	
	walletBtn := widget.NewButton("👛 Wallet", func() {
		if s.OnWalletClicked != nil {
			s.OnWalletClicked()
		}
	})
	
	// Quid Protocol features
	exposureBtn := widget.NewButton("📊 Exposure", func() {
		if s.OnExposureClicked != nil {
			s.OnExposureClicked()
		}
	})
	exposureBtn.Importance = widget.HighImportance
	
	// Trading bots
	calypsoBtn := widget.NewButton("🤖 Calypso", func() {
		if s.OnCalypsoClicked != nil {
			s.OnCalypsoClicked()
		}
	})
	
	conditionalBotBtn := widget.NewButton("⚡ Conditional Bot", func() {
		if s.OnConditionalBotClicked != nil {
			s.OnConditionalBotClicked()
		}
	})
	
	// Casa Battle (NEW)
	casaBattleBtn := widget.NewButton("🎤 Casa Battle", func() {
		if s.OnCasaBattleClicked != nil {
			s.OnCasaBattleClicked()
		}
	})
	casaBattleBtn.Importance = widget.HighImportance
	
	// Governance (NEW)
	votingBtn := widget.NewButton("🗳️ Voting", func() {
		if s.OnVotingClicked != nil {
			s.OnVotingClicked()
		}
	})
	
	// Tools
	hardwareSignBtn := widget.NewButton("🔐 Hardware Sign", func() {
		if s.OnHardwareSignClicked != nil {
			s.OnHardwareSignClicked()
		}
	})
	
	txInspectorBtn := widget.NewButton("🔍 Tx Inspector", func() {
		if s.OnTxInspectorClicked != nil {
			s.OnTxInspectorClicked()
		}
	})
	
	// Multisig
	multisigCreateBtn := widget.NewButton("➕ Create Multisig", func() {
		if s.OnMultisigCreateClicked != nil {
			s.OnMultisigCreateClicked()
		}
	})
	
	multisigInfoBtn := widget.NewButton("ℹ️ Multisig Info", func() {
		if s.OnMultisigInfoClicked != nil {
			s.OnMultisigInfoClicked()
		}
	})

	selfManagedBtn := widget.NewButtonWithIcon("Self-Managed", theme.DocumentIcon(), func() {
		if s.OnSelfManagedClicked != nil {
			s.OnSelfManagedClicked()
		}
	})

	// Group buttons by category
	coreSection := container.NewVBox(
		widget.NewLabelWithStyle("Core", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		homeBtn,
		sendBtn,
		walletBtn,
		widget.NewSeparator(),
	)
	
	quidSection := container.NewVBox(
		widget.NewLabelWithStyle("Quid Protocol", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		exposureBtn,
		votingBtn,
		widget.NewSeparator(),
	)
	
	tradingSection := container.NewVBox(
		widget.NewLabelWithStyle("Trading", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		calypsoBtn,
		conditionalBotBtn,
		widget.NewSeparator(),
	)
	
	socialSection := container.NewVBox(
		widget.NewLabelWithStyle("Social", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		casaBattleBtn,
		widget.NewSeparator(),
	)
	
	toolsSection := container.NewVBox(
		widget.NewLabelWithStyle("Tools", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		hardwareSignBtn,
		txInspectorBtn,
		widget.NewSeparator(),
	)
	
	multisigSection := container.NewVBox(
		widget.NewLabelWithStyle("Multisig", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		multisigCreateBtn,
		multisigInfoBtn,
	)

	// Combine all sections
	content := container.NewVBox(
		coreSection,
		quidSection,
		tradingSection,
		socialSection,
		toolsSection,
		multisigSection,
	)

	// Wrap in scroll container for smaller screens
	scroll := container.NewVScroll(content)
	
	return widget.NewSimpleRenderer(scroll)
}
