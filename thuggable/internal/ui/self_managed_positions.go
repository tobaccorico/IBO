package ui

import (
    "fmt"
    "strconv"
    
    "fyne.io/fyne/v2"
    "fyne.io/fyne/v2/container"
    "fyne.io/fyne/v2/dialog"
    "fyne.io/fyne/v2/widget"
    "fyne.io/fyne/v2/theme"
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
}

func NewSelfManagedPositionsScreen(window fyne.Window, app fyne.App) fyne.CanvasObject {
    s := &SelfManagedPositionsScreen{
        window: window,
        app:    app,
        positions: []SelfManagedPosition{}, // Would load from chain
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
                widget.NewButton("Edit", nil),
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
                    s.editPosition(pos)
                }
            }
        },
    )
    
    // Create new position button
    newPosButton := widget.NewButton("Create New Position", func() {
        s.createNewPosition()
    })
    newPosButton.Importance = widget.HighImportance
    
    s.container = container.NewBorder(
        container.NewVBox(
            widget.NewLabelWithStyle("Self-Managed Positions", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
            widget.NewCard("", "Manage your out-of-range liquidity positions", nil),
            newPosButton,
        ),
        nil, nil, nil,
        s.positionsList,
    )
    
    return s.container
}

func (s *SelfManagedPositionsScreen) editPosition(pos SelfManagedPosition) {
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
            percent, err := strconv.Atoi(percentEntry.Text)
            if err != nil || percent < 1 || percent > 100 {
                dialog.ShowError(fmt.Errorf("Invalid percentage"), s.window)
                return
            }
            // Call contract to reclaim position
            s.reclaimPosition(pos.ID, percent)
        }
    }, s.window)
}

func (s *SelfManagedPositionsScreen) createNewPosition() {
    tokenSelect := widget.NewSelect([]string{"ETH", "USDC"}, nil)
    amountEntry := widget.NewEntry()
    distanceEntry := widget.NewEntry()
    rangeEntry := widget.NewEntry()
    
    content := container.NewVBox(
        widget.NewLabel("Create Out-of-Range Position"),
        tokenSelect,
        amountEntry,
        distanceEntry,
        rangeEntry,
    )
    
    dialog.ShowCustomConfirm("New Position", "Create", "Cancel", content, func(create bool) {
        if create {
            // Validate and create position
        }
    }, s.window)
}

func (s *SelfManagedPositionsScreen) reclaimPosition(id uint64, percent int) {
    // Call Router contract reclaim function
    dialog.ShowInformation("Success", fmt.Sprintf("Reclaimed %d%% of position %d", percent, id), s.window)
}