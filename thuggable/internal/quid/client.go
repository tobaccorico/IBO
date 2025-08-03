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
    endpoint  string
    rpcClient *rpc.Client
    wallet    string
    programID solana.PublicKey
}

func NewClient(rpcURL string) *Client {
	return &Client{
		rpc:       rpc.New(rpcURL),
		programID: QuidProgramID,
	}
}

// Helper to convert uint64 to bytes
func (id uint64) Bytes() []byte {
    b := make([]byte, 8)
    binary.LittleEndian.PutUint64(b, id)
    return b
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

func (c *Client) FinalizeBattleWithMPC(
    ctx context.Context,
    battleID uint64,
    winnerIsChallenger bool,
    challengerSig []byte,
    defenderSig []byte,
    judgeSig []byte,
) (*solana.Transaction, error) {
    // Get the battle account PDA
    battleAccount, _, err := solana.FindProgramAddress(
        [][]byte{
            []byte("battle"),
            battleID.Bytes(),
        },
        c.programID,
    )
    if err != nil {
        return nil, err
    }

    // Get other required accounts
    // You'll need to fetch these from the battle account
    // For now, using placeholders
    var challengerDepositor solana.PublicKey
    var defenderDepositor solana.PublicKey
    var depository solana.PublicKey
    var config solana.PublicKey
    
    // Build instruction data
    data := []byte{10} // Instruction discriminator for finalize_battle_mpc
    if winnerIsChallenger {
        data = append(data, 1)
    } else {
        data = append(data, 0)
    }
    data = append(data, challengerSig...)
    data = append(data, defenderSig...)
    data = append(data, judgeSig...)
    
    instruction := &solana.Instruction{
        ProgramID: c.programID,
        Accounts: []solana.AccountMeta{
            {PublicKey: battleAccount, IsSigner: false, IsWritable: true},
            {PublicKey: challengerDepositor, IsSigner: false, IsWritable: true},
            {PublicKey: defenderDepositor, IsSigner: false, IsWritable: true},
            {PublicKey: depository, IsSigner: false, IsWritable: true},
            {PublicKey: config, IsSigner: false, IsWritable: false},
            {PublicKey: solana.SystemProgramID, IsSigner: false, IsWritable: false},
        },
        Data: data,
    }
    
    // Get recent blockhash
    recent, err := c.rpcClient.GetLatestBlockhash(ctx, rpc.CommitmentFinalized)
    if err != nil {
        return nil, err
    }
    
    // Build transaction
    tx, err := solana.NewTransaction(
        []solana.Instruction{instruction},
        recent.Value.Blockhash,
        solana.TransactionPayer(c.wallet),
    )
    
    return tx, nil
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