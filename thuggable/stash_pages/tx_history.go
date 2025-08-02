package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"
)

const (
	TX_HISTORY_RPC = "https://special-blue-fog.solana-mainnet.quiknode.pro/d009d548b4b9dd9f062a8124a868fb915937976c/"
	MAX_TX_FETCH   = 50
)

type Transaction struct {
	Time        string `json:"time"`
	Description string `json:"description"`
	Type        string `json:"type"`
	Signature   string `json:"signature"`
}

var (
	transactionCache      = make(map[string][]Transaction)
	transactionCacheMutex sync.RWMutex
	transactionCacheTime  = make(map[string]time.Time)
	cacheDuration         = 5 * time.Minute
)

// QuidProgramID for identifying quid transactions
var QuidProgramID = solana.MustPublicKeyFromBase58("QgV3iN5rSkBU8jaZy8AszQt5eoYwKLmBgXEK5cehAKX")

func fetchTransactionHistory(walletAddress string) ([]Transaction, error) {
	// Check cache first
	transactionCacheMutex.RLock()
	if cachedTransactions, found := transactionCache[walletAddress]; found {
		if time.Since(transactionCacheTime[walletAddress]) < cacheDuration {
			transactionCacheMutex.RUnlock()
			return cachedTransactions, nil
		}
	}
	transactionCacheMutex.RUnlock()

	// Create RPC client
	client := rpc.New(TX_HISTORY_RPC)
	ctx := context.Background()
	
	// Convert address to public key
	pubKey, err := solana.PublicKeyFromBase58(walletAddress)
	if err != nil {
		return nil, fmt.Errorf("invalid wallet address: %v", err)
	}
	
	// Fetch signatures for the address
	signatures, err := client.GetSignaturesForAddress(
		ctx,
		pubKey,
		&rpc.GetSignaturesForAddressOpts{
			Limit: &MAX_TX_FETCH,
		},
	)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch signatures: %v", err)
	}
	
	// Parse transactions
	var transactions []Transaction
	for _, sigInfo := range signatures {
		// Skip failed transactions
		if sigInfo.Err != nil {
			continue
		}
		
		// Create transaction entry
		tx := Transaction{
			Time:      time.Unix(sigInfo.BlockTime, 0).Format("Jan 2 15:04:05"),
			Signature: sigInfo.Signature.String(),
			Type:      "transfer", // Default type
		}
		
		// Try to get more details about the transaction
		if sigInfo.Memo != nil {
			tx.Description = *sigInfo.Memo
		} else {
			// Try to fetch full transaction for better parsing
			txDetails, err := client.GetTransaction(
				ctx,
				sigInfo.Signature,
				&rpc.GetTransactionOpts{
					Encoding: solana.EncodingBase64,
				},
			)
			if err == nil && txDetails != nil {
				tx.Description = parseTransactionDescription(txDetails, pubKey)
				tx.Type = identifyTransactionType(txDetails)
			} else {
				// Fallback description
				tx.Description = fmt.Sprintf("Transaction on Solana")
			}
		}
		
		transactions = append(transactions, tx)
	}
	
	// Update cache
	transactionCacheMutex.Lock()
	transactionCache[walletAddress] = transactions
	transactionCacheTime[walletAddress] = time.Now()
	transactionCacheMutex.Unlock()

	return transactions, nil
}

// parseTransactionDescription attempts to create a human-readable description
func parseTransactionDescription(tx *rpc.GetTransactionResult, userPubKey solana.PublicKey) string {
	if tx == nil || tx.Meta == nil {
		return "Transaction on Solana"
	}
	
	// Check if it's a quid transaction
	if tx.Transaction != nil {
		// This is simplified - you'd need to properly decode the transaction
		// to check if it involves the quid program
		for _, key := range tx.Transaction.Message.AccountKeys {
			if key.Equals(QuidProgramID) {
				return parseQuidTransaction(tx, userPubKey)
			}
		}
	}
	
	// Check for SOL transfers
	preBalance := tx.Meta.PreBalances[0]
	postBalance := tx.Meta.PostBalances[0]
	
	if preBalance != postBalance {
		diff := int64(postBalance) - int64(preBalance)
		if diff > 0 {
			return fmt.Sprintf("Received %.6f SOL", float64(diff)/1e9)
		} else {
			return fmt.Sprintf("Sent %.6f SOL", float64(-diff)/1e9)
		}
	}
	
	// Check for token transfers
	if len(tx.Meta.PreTokenBalances) > 0 || len(tx.Meta.PostTokenBalances) > 0 {
		return "Token transfer"
	}
	
	return "Transaction on Solana"
}

// parseQuidTransaction creates descriptions for quid protocol transactions (TODO)
func parseQuidTransaction(tx *rpc.GetTransactionResult, userPubKey solana.PublicKey) string {
	// This would parse the instruction data to determine:
	// - Deposit
	// - Withdraw (collateral or exposure adjustment)
	// - Liquidation
	
	// For now, return a generic quid description
	return "Quid Protocol interaction"
}

// identifyTransactionType categorizes the transaction
func identifyTransactionType(tx *rpc.GetTransactionResult) string {
	if tx == nil || tx.Transaction == nil {
		return "unknown"
	}
	
	// Check for quid program
	for _, key := range tx.Transaction.Message.AccountKeys {
		if key.Equals(QuidProgramID) {
			return "quid"
		}
	}
	
	// Check for system program (SOL transfers)
	if len(tx.Transaction.Message.AccountKeys) > 0 {
		if tx.Transaction.Message.AccountKeys[0].Equals(solana.SystemProgramID) {
			return "transfer"
		}
	}
	
	// Check for token program
	for _, key := range tx.Transaction.Message.AccountKeys {
		if key.Equals(solana.TokenProgramID) {
			return "token"
		}
	}
	
	return "contract"
}

func shortenHash(hash string) string {
	if len(hash) <= 12 {
		return hash
	}
	return fmt.Sprintf("%s...%s", hash[:6], hash[len(hash)-6:])
}

func NewTxHistoryScreen() fyne.CanvasObject {
	state := GetGlobalState()
	walletAddress := state.GetSelectedWallet()

	walletLabel := widget.NewLabel("No wallet selected")
	if walletAddress != "" {
		walletLabel.SetText(fmt.Sprintf("Wallet: %s", shortenHash(walletAddress)))
	}

	txContainer := container.NewVBox()
	
	// Add a loading indicator
	loadingBar := widget.NewProgressBarInfinite()
	loadingBar.Hide()

	// Function to update transactions
	updateTransactions := func() {
		if walletAddress == "" {
			txContainer.Objects = []fyne.CanvasObject{widget.NewLabel("No wallet selected")}
			txContainer.Refresh()
			return
		}

		// Show loading
		loadingBar.Show()
		txContainer.Objects = nil
		txContainer.Refresh()

		// Fetch in background
		go func() {
			transactions, err := fetchTransactionHistory(walletAddress)
			
			// Update UI on main thread
			loadingBar.Hide()
			txContainer.Objects = nil
			
			if err != nil {
				txContainer.Add(widget.NewLabel(fmt.Sprintf("Error: %v", err)))
			} else if len(transactions) == 0 {
				txContainer.Add(widget.NewLabel("No transactions found"))
			} else {
				for _, tx := range transactions {
					// Transaction time
					txTime := widget.NewLabelWithStyle(tx.Time, fyne.TextAlignLeading, fyne.TextStyle{Italic: true})
					
					// Type badge
					typeLabel := widget.NewLabel(fmt.Sprintf("[%s]", tx.Type))
					if tx.Type == "quid" {
						typeLabel = widget.NewLabelWithStyle("[QUID]", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
					}
					
					// Description
					txDescription := widget.NewLabel(tx.Description)
					
					// Signature (clickable)
					txSignature := widget.NewHyperlink(
						fmt.Sprintf("Signature: %s", shortenHash(tx.Signature)),
						fmt.Sprintf("https://explorer.solana.com/tx/%s", tx.Signature),
					)
					
					// Create card for transaction
					txCard := widget.NewCard("", "", container.NewVBox(
						container.NewHBox(txTime, typeLabel),
						txDescription,
						txSignature,
					))
					
					txContainer.Add(txCard)
				}
			}
			txContainer.Refresh()
		}()
	}

	// Refresh button
	refreshButton := widget.NewButton("Refresh", updateTransactions)
	refreshButton.Importance = widget.HighImportance

	// Scroll container
	scrollContainer := container.NewVScroll(txContainer)
	scrollContainer.SetMinSize(fyne.NewSize(400, 500))

	// Main layout
	content := container.NewVBox(
		widget.NewLabelWithStyle("Transaction History", fyne.TextAlignCenter, fyne.TextStyle{Bold: true}),
		walletLabel,
		refreshButton,
		loadingBar,
		scrollContainer,
	)

	// Initial load
	updateTransactions()

	return content
}