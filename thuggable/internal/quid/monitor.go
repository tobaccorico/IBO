package quid

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"
)

const (
	MAX_AGE = 300 // 5 minutes in seconds, from etc.rs
)

// PositionHealth represents the health status of a position
type PositionHealth struct {
	Depositor       solana.PublicKey
	Ticker          string
	IsHealthy       bool
	TimeSinceUpdate int64
	CurrentValue    float64
	PledgedValue    float64
	ExposureValue   float64
	NeedsLiquidation bool
}

// LiquidationMonitor continuously monitors positions for liquidation opportunities
type LiquidationMonitor struct {
	client          *Client
	rpcClient       *rpc.Client
	programID       solana.PublicKey
	liquidator      *solana.PrivateKey
	isRunning       bool
	mu              sync.Mutex
	checkInterval   time.Duration
	pythPriceFeeds  map[string]solana.PublicKey
	onLiquidation   func(string) // Callback for UI updates
}

func NewLiquidationMonitor(
	client *Client,
	liquidator *solana.PrivateKey,
	pythFeeds map[string]solana.PublicKey,
) *LiquidationMonitor {
	return &LiquidationMonitor{
		client:         client,
		rpcClient:      client.rpc,
		programID:      client.programID,
		liquidator:     liquidator,
		checkInterval:  30 * time.Second, // Check every 30 seconds
		pythPriceFeeds: pythFeeds,
	}
}

// Start begins monitoring for liquidation opportunities
func (m *LiquidationMonitor) Start(ctx context.Context) error {
	m.mu.Lock()
	if m.isRunning {
		m.mu.Unlock()
		return fmt.Errorf("monitor already running")
	}
	m.isRunning = true
	m.mu.Unlock()

	go m.monitorLoop(ctx)
	return nil
}

// Stop halts the monitoring
func (m *LiquidationMonitor) Stop() {
	m.mu.Lock()
	m.isRunning = false
	m.mu.Unlock()
}

// monitorLoop is the main monitoring loop
func (m *LiquidationMonitor) monitorLoop(ctx context.Context) {
	ticker := time.NewTicker(m.checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			m.Stop()
			return
		case <-ticker.C:
			m.checkAllPositions(ctx)
		}
	}
}

// checkAllPositions scans all depositor accounts for liquidation opportunities
func (m *LiquidationMonitor) checkAllPositions(ctx context.Context) {
	// Get all program accounts that are depositor accounts
	// This is a simplified version - in production you'd want pagination
	
	depositors, err := m.findAllDepositors(ctx)
	if err != nil {
		log.Printf("Error finding depositors: %v", err)
		return
	}

	log.Printf("Checking %d depositors for liquidation opportunities", len(depositors))

	for _, depositor := range depositors {
		positions := m.checkDepositorHealth(ctx, depositor)
		
		for _, pos := range positions {
			if pos.NeedsLiquidation {
				log.Printf("Found liquidation opportunity: %s position for depositor %s", 
					pos.Ticker, pos.Depositor.String())
				
				// Execute liquidation
				if err := m.executeLiquidation(ctx, pos); err != nil {
					log.Printf("Failed to liquidate: %v", err)
				} else {
					if m.onLiquidation != nil {
						m.onLiquidation(fmt.Sprintf("Liquidated %s position for %s", 
							pos.Ticker, shortenAddress(pos.Depositor.String())))
					}
				}
			}
		}
	}
}

// findAllDepositors queries for all depositor accounts
func (m *LiquidationMonitor) findAllDepositors(ctx context.Context) ([]solana.PublicKey, error) {
	// In production, you'd use getProgramAccounts with proper filters
	// For now, return empty slice to avoid errors
	return []solana.PublicKey{}, nil
}

// checkDepositorHealth evaluates all positions for a depositor
func (m *LiquidationMonitor) checkDepositorHealth(ctx context.Context, depositor solana.PublicKey) []PositionHealth {
	// This would:
	// 1. Fetch the depositor account data
	// 2. Parse all positions
	// 3. Get current prices from Pyth
	// 4. Calculate position health
	// 5. Check if liquidation conditions are met
	
	// Placeholder implementation
	return []PositionHealth{}
}

// executeLiquidation builds and sends a liquidation transaction
func (m *LiquidationMonitor) executeLiquidation(ctx context.Context, position PositionHealth) error {
	// Build liquidation instruction
	instruction, err := m.buildLiquidateInstruction(position)
	if err != nil {
		return fmt.Errorf("failed to build liquidation instruction: %v", err)
	}

	// Get recent blockhash
	recent, err := m.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
	if err != nil {
		return fmt.Errorf("failed to get recent blockhash: %v", err)
	}

	// Build transaction
	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(m.liquidator.PublicKey()),
	)
	if err != nil {
		return fmt.Errorf("failed to create transaction: %v", err)
	}

	// Sign transaction
	_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(m.liquidator.PublicKey()) {
			return m.liquidator
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to sign transaction: %v", err)
	}

	// Send transaction
	sig, err := m.rpcClient.SendTransaction(ctx, tx)
	if err != nil {
		return fmt.Errorf("failed to send transaction: %v", err)
	}

	log.Printf("Liquidation transaction sent: %s", sig.String())
	return nil
}

// buildLiquidateInstruction creates a liquidate instruction
func (m *LiquidationMonitor) buildLiquidateInstruction(position PositionHealth) (solana.Instruction, error) {
	// Get necessary accounts
	depositor, _ := m.client.GetDepositorAccount(position.Depositor)
	depository, _ := m.client.GetDepositoryAccount(USDStarMint)
	vault, _ := m.client.GetVaultAccount(USDStarMint)
	
	// Get liquidator's token account
	liquidatorTokenAccount, _, _ := solana.FindAssociatedTokenAddress(m.liquidator.PublicKey(), USDStarMint)
	
	// Build instruction data
	buf := new(solana.BinaryEncoder)
	buf.WriteUint8(2) // liquidate instruction discriminator
	buf.WriteUint32(uint32(len(position.Ticker)))
	buf.WriteBytes([]byte(position.Ticker))
	
	accounts := []*solana.AccountMeta{
		{PublicKey: position.Depositor, IsSigner: false, IsWritable: false}, // liquidating account
		{PublicKey: m.liquidator.PublicKey(), IsSigner: true, IsWritable: true},
		{PublicKey: USDStarMint, IsSigner: false, IsWritable: false},
		{PublicKey: depository, IsSigner: false, IsWritable: true},
		{PublicKey: vault, IsSigner: false, IsWritable: true},
		{PublicKey: depositor, IsSigner: false, IsWritable: true},
		{PublicKey: liquidatorTokenAccount, IsSigner: false, IsWritable: true},
		{PublicKey: solana.TokenProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SPLAssociatedTokenAccountProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SystemProgramID, IsSigner: false, IsWritable: false},
	}
	
	// Add Pyth account for the position's ticker
	if pythAccount, exists := m.pythPriceFeeds[position.Ticker]; exists {
		accounts = append(accounts, &solana.AccountMeta{
			PublicKey: pythAccount,
			IsSigner: false,
			IsWritable: false,
		})
	}
	
	return solana.NewInstruction(m.programID, accounts, buf.Bytes()), nil
}

// Helper function (should be in common.go)
func shortenAddress(address string) string {
	if len(address) <= 8 {
		return address
	}
	return address[:4] + "..." + address[len(address)-4:]
}