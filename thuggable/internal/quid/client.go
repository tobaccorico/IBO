package quid

import (
	"context"
	"fmt"
	"math"

	"github.com/gagliardetto/binary"
	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/programs/system"
	"github.com/gagliardetto/solana-go/rpc"
)

// Program addresses from the Rust code
var (
	QuidProgramID = solana.MustPublicKeyFromBase58("QgV3iN5rSkBU8jaZy8AszQt5eoYwKLmBgXEK5cehAKX") // devnet
	USDStarMint   = solana.MustPublicKeyFromBase58("5qj9FAj2jdZr4FfveDtKyWYCnd73YQfmJGkAgRxjwbq6") // mock on devnet
	
	// Supported assets from etc.rs
	SupportedAssets = map[string]AssetInfo{
		"XAU": {Symbol: "XAU", Decimals: 6},
		"BTC": {Symbol: "BTC", Decimals: 8},
		"SOL": {Symbol: "SOL", Decimals: 9},
		"JUP": {Symbol: "JUP", Decimals: 6},
		"JTO": {Symbol: "JTO", Decimals: 9},
	}
)

type AssetInfo struct {
	Symbol   string
	Decimals int
}

type Client struct {
	rpc       *rpc.Client
	programID solana.PublicKey
}

func NewClient(rpcURL string) *Client {
	return &Client{
		rpc:       rpc.New(rpcURL),
		programID: QuidProgramID,
	}
}

// GetDepositorAccount derives the PDA for a user's depositor account
func (c *Client) GetDepositorAccount(owner solana.PublicKey) (solana.PublicKey, uint8) {
	addr, bump, _ := solana.FindProgramAddress(
		[][]byte{owner.Bytes()},
		c.programID,
	)
	return addr, bump
}

// GetDepositoryAccount derives the PDA for the depository
func (c *Client) GetDepositoryAccount(mint solana.PublicKey) (solana.PublicKey, uint8) {
	addr, bump, _ := solana.FindProgramAddress(
		[][]byte{mint.Bytes()},
		c.programID,
	)
	return addr, bump
}

// GetVaultAccount derives the PDA for the token vault
func (c *Client) GetVaultAccount(mint solana.PublicKey) (solana.PublicKey, uint8) {
	addr, bump, _ := solana.FindProgramAddress(
		[][]byte{[]byte("vault"), mint.Bytes()},
		c.programID,
	)
	return addr, bump
}

// BuildDepositInstruction creates a deposit instruction
func (c *Client) BuildDepositInstruction(
	user solana.PublicKey,
	amount uint64,
	ticker string, // empty string for USD* deposit
) (solana.Instruction, error) {
	depositor, _ := c.GetDepositorAccount(user)
	depository, _ := c.GetDepositoryAccount(USDStarMint)
	vault, _ := c.GetVaultAccount(USDStarMint)
	
	// Get user's USD* token account
	userTokenAccount, _, _ := solana.FindAssociatedTokenAddress(user, USDStarMint)
	
	data, err := encodeDepositData(amount, ticker)
	if err != nil {
		return nil, err
	}
	
	accounts := []*solana.AccountMeta{
		{PublicKey: user, IsSigner: true, IsWritable: true},
		{PublicKey: USDStarMint, IsSigner: false, IsWritable: false},
		{PublicKey: depository, IsSigner: false, IsWritable: true},
		{PublicKey: vault, IsSigner: false, IsWritable: true},
		{PublicKey: depositor, IsSigner: false, IsWritable: true},
		{PublicKey: userTokenAccount, IsSigner: false, IsWritable: true},
		{PublicKey: solana.TokenProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SPLAssociatedTokenAccountProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SystemProgramID, IsSigner: false, IsWritable: false},
	}
	
	return solana.NewInstruction(c.programID, accounts, data), nil
}

// BuildWithdrawInstruction creates a withdraw instruction
func (c *Client) BuildWithdrawInstruction(
	user solana.PublicKey,
	amount int64, // negative for withdrawals
	ticker string,
	exposure bool,
	pythAccounts []solana.PublicKey, // Pyth price accounts
) (solana.Instruction, error) {
	depositor, _ := c.GetDepositorAccount(user)
	depository, _ := c.GetDepositoryAccount(USDStarMint)
	vault, _ := c.GetVaultAccount(USDStarMint)
	
	// Get user's USD* token account
	userTokenAccount, _, _ := solana.FindAssociatedTokenAddress(user, USDStarMint)
	
	data, err := encodeWithdrawData(amount, ticker, exposure)
	if err != nil {
		return nil, err
	}
	
	accounts := []*solana.AccountMeta{
		{PublicKey: user, IsSigner: true, IsWritable: true},
		{PublicKey: USDStarMint, IsSigner: false, IsWritable: false},
		{PublicKey: depository, IsSigner: false, IsWritable: true},
		{PublicKey: vault, IsSigner: false, IsWritable: true},
		{PublicKey: depositor, IsSigner: false, IsWritable: true},
		{PublicKey: userTokenAccount, IsSigner: false, IsWritable: true},
		{PublicKey: solana.TokenProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SPLAssociatedTokenAccountProgramID, IsSigner: false, IsWritable: false},
		{PublicKey: solana.SystemProgramID, IsSigner: false, IsWritable: false},
	}
	
	// Add Pyth accounts to remaining_accounts
	for _, pythAccount := range pythAccounts {
		accounts = append(accounts, &solana.AccountMeta{
			PublicKey: pythAccount,
			IsSigner: false,
			IsWritable: false,
		})
	}
	
	return solana.NewInstruction(c.programID, accounts, data), nil
}

// Helper to encode instruction data
func encodeDepositData(amount uint64, ticker string) ([]byte, error) {
	buf := new(binary.Encoder)
	
	// Instruction discriminator for deposit (simplified - you'll need the actual discriminator)
	buf.WriteUint8(0) // deposit instruction
	buf.WriteUint64(amount, binary.LE)
	
	// Encode ticker as string
	buf.WriteUint32(uint32(len(ticker)), binary.LE)
	buf.WriteBytes([]byte(ticker))
	
	return buf.Bytes(), nil
}

func encodeWithdrawData(amount int64, ticker string, exposure bool) ([]byte, error) {
	buf := new(binary.Encoder)
	
	// Instruction discriminator for withdraw
	buf.WriteUint8(1) // withdraw instruction
	buf.WriteInt64(amount, binary.LE)
	
	// Encode ticker
	buf.WriteUint32(uint32(len(ticker)), binary.LE)
	buf.WriteBytes([]byte(ticker))
	
	// Encode exposure flag
	if exposure {
		buf.WriteUint8(1)
	} else {
		buf.WriteUint8(0)
	}
	
	return buf.Bytes(), nil
}

// CalculateExposureAmount converts a USD amount to the exposure amount for a given asset
func CalculateExposureAmount(usdAmount float64, ticker string, increase bool) int64 {
	asset, exists := SupportedAssets[ticker]
	if !exists {
		return 0
	}
	
	// Convert to smallest units based on decimals
	smallestUnits := usdAmount * math.Pow10(asset.Decimals)
	
	if increase {
		return int64(smallestUnits)
	}
	return -int64(smallestUnits)
}