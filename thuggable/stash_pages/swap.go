package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

// SwapScreen now redirects to exposure management
func NewSwapScreen() fyne.CanvasObject {
	infoCard := widget.NewCard(
		"Swap → Exposure Management",
		"Traditional token swaps have been replaced with synthetic exposure management through Quid protocol",
		container.NewVBox(
			widget.NewLabel("Benefits of Quid Exposure:"),
			widget.NewLabel("• Capital efficiency with up to 10x leverage"),
			widget.NewLabel("• No DEX fees or slippage"),
			widget.NewLabel("• Earn yield on dollars"),
			widget.NewLabel("• Built-in risk management"),
			widget.NewLabel("• Support for short positions"),
		),
	)
	
	redirectButton := widget.NewButton("Go to Exposure Management", func() {
		// This would navigate to the exposure screen (TODO)
		// Implementation depends on your navigation system
	})
	redirectButton.Importance = widget.HighImportance
	
	return container.NewVBox(
		infoCard,
		container.NewCenter(redirectButton),
	)
}