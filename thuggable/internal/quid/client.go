package quid

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"time"

	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/programs/system"
	"github.com/gagliardetto/solana-go/rpc"
)

// Program addresses from the svm/programs/quid/src/lib.rs
var (
	QuidProgramID = solana.MustPublicKeyFromBase58("QgV3iN5rSkBU8jaZy8AszQt5eoYwKLmBgXEK5cehAKX") // devnet
	USDStarMint   = solana.MustPublicKeyFromBase58("5qj9FAj2jdZr4FfveDtKyWYCnd73YQfmJGkAgRxjwbq6") // mock on devnet
	
	// Supported assets from svm/programs/quid/src/etc.rs
	SupportedAssets = map[string]AssetInfo{
		"XAU": {Symbol: "XAU", Decimals: 6},
		"BTC": {Symbol: "BTC", Decimals: 8},
		"SOL": {Symbol: "SOL", Decimals: 9},
	}

	// Pyth price feed addresses from etc.rs
	PythPriceFeeds = map[string]solana.PublicKey{
		"XAU": solana.MustPublicKeyFromBase58("2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW"),
		"BTC": solana.MustPublicKeyFromBase58("4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo"),
	}
)

type AssetInfo struct {
	Symbol   string
	Decimals int
}

type Client struct {
	rpcClient    *rpc.Client
	wallet       solana.PrivateKey
	programID    solana.PublicKey
}

// NewClient creates a new Quid client with optional wallet
func NewClient(rpcURL string, walletKey ...string) *Client {
	client := &Client{
		rpcClient: rpc.New(rpcURL),
		programID: QuidProgramID,
	}
	
	// If wallet key provided, set it
	if len(walletKey) > 0 && walletKey[0] != "" {
		if privKey, err := solana.PrivateKeyFromBase58(walletKey[0]); err == nil {
			client.wallet = privKey
		}
	}
	
	return client
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
	
	return &solana.GenericInstruction{
		ProgID: c.programID,
		AccountValues: accounts,
		DataBytes: data,
	}, nil
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
	
	return &solana.GenericInstruction{
		ProgID: c.programID,
		AccountValues: accounts,
		DataBytes: data,
	}, nil
}

// Casa Battle instructions
func (c *Client) CreateBattle(ctx context.Context, stakeAmount uint64, ticker, tweetURI string) (*solana.Transaction, error) {
	battleAccount, bump, err := solana.FindProgramAddress(
		[][]byte{[]byte("battle"), c.wallet.PublicKey().Bytes()},
		c.programID,
	)
	if err != nil {
		return nil, err
	}

	challengerDepositor, _ := c.GetDepositorAccount(c.wallet.PublicKey())
	depository, _ := c.GetDepositoryAccount(USDStarMint)
	
	// Get config PDA
	config, _, _ := solana.FindProgramAddress([][]byte{[]byte("config")}, c.programID)

	data := []byte{3} // create_battle instruction discriminator
	data = append(data, encodeU64(stakeAmount)...)
	data = append(data, encodeString(ticker)...)
	data = append(data, encodeString(tweetURI)...)

	instruction := &solana.GenericInstruction{
		ProgID: c.programID,
		AccountValues: []*solana.AccountMeta{
			{PublicKey: c.wallet.PublicKey(), IsSigner: true, IsWritable: true},
			{PublicKey: battleAccount, IsSigner: false, IsWritable: true},
			{PublicKey: challengerDepositor, IsSigner: false, IsWritable: true},
			{PublicKey: depository, IsSigner: false, IsWritable: true},
			{PublicKey: config, IsSigner: false, IsWritable: false},
			{PublicKey: solana.SystemProgramID, IsSigner: false, IsWritable: false},
		},
		DataBytes: data,
	}

	recent, err := c.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
	if err != nil {
		return nil, err
	}

	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(c.wallet.PublicKey()),
	)
	if err != nil {
		return nil, err
	}

	return tx, nil
}

func (c *Client) AcceptBattle(ctx context.Context, battleID uint64, ticker, tweetURI string) (*solana.Transaction, error) {
	// Derive battle PDA
	battleSeeds := [][]byte{
		[]byte("battle"),
		make([]byte, 8),
	}
	binary.LittleEndian.PutUint64(battleSeeds[1], battleID)
	
	battleAccount, _, err := solana.FindProgramAddress(battleSeeds, c.programID)
	if err != nil {
		return nil, err
	}

	defenderDepositor, _ := c.GetDepositorAccount(c.wallet.PublicKey())
	depository, _ := c.GetDepositoryAccount(USDStarMint)

	data := []byte{4} // accept_battle instruction discriminator
	data = append(data, encodeString(ticker)...)
	data = append(data, encodeString(tweetURI)...)

	instruction := &solana.GenericInstruction{
		ProgID: c.programID,
		AccountValues: []*solana.AccountMeta{
			{PublicKey: c.wallet.PublicKey(), IsSigner: true, IsWritable: true},
			{PublicKey: battleAccount, IsSigner: false, IsWritable: true},
			{PublicKey: defenderDepositor, IsSigner: false, IsWritable: true},
			{PublicKey: depository, IsSigner: false, IsWritable: true},
		},
		DataBytes: data,
	}

	recent, err := c.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
	if err != nil {
		return nil, err
	}

	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(c.wallet.PublicKey()),
	)
	if err != nil {
		return nil, err
	}

	return tx, nil
}

// Helper functions for encoding
func encodeDepositData(amount uint64, ticker string) ([]byte, error) {
	data := []byte{0} // deposit instruction discriminator
	data = append(data, encodeU64(amount)...)
	data = append(data, encodeString(ticker)...)
	return data, nil
}

func encodeWithdrawData(amount int64, ticker string, exposure bool) ([]byte, error) {
	data := []byte{1} // withdraw instruction discriminator
	data = append(data, encodeI64(amount)...)
	data = append(data, encodeString(ticker)...)
	if exposure {
		data = append(data, 1)
	} else {
		data = append(data, 0)
	}
	return data, nil
}

func encodeU64(val uint64) []byte {
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint64(buf, val)
	return buf
}

func encodeI64(val int64) []byte {
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint64(buf, uint64(val))
	return buf
}

func encodeString(s string) []byte {
	lenBytes := encodeU32(uint32(len(s)))
	return append(lenBytes, []byte(s)...)
}

func encodeU32(val uint32) []byte {
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, val)
	return buf
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

// GetBattles fetches all battles (placeholder - needs actual implementation)
func (c *Client) GetBattles(ctx context.Context) ([]Battle, error) {
	// This would use getProgramAccounts with proper filters
	return []Battle{}, nil
}

// Battle struct for UI
type Battle struct {
	ID                 uint64
	Challenger         string
	Defender           string
	StakeAmount        uint64
	ChallengerTicker   string
	DefenderTicker     string
	ChallengerTweetURI string
	DefenderTweetURI   string
	Phase              string
	CreatedAt          time.Time
	Winner             *string
}

// SendTransaction helper
func (c *Client) SendTransaction(ctx context.Context, tx *solana.Transaction) (*solana.Signature, error) {
	// Sign transaction
	_, err := tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
		if key.Equals(c.wallet.PublicKey()) {
			return &c.wallet
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	
	// Send transaction
	sig, err := c.rpcClient.SendTransactionWithOpts(
		ctx,
		tx,
		rpc.TransactionOpts{
			SkipPreflight: false,
			PreflightCommitment: rpc.CommitmentFinalized,
		},
	)
	if err != nil {
		return nil, err
	}
	
	return &sig, nil
}

// GetUserPositions returns user's positions (mock for now)
func (c *Client) GetUserPositions() []string {
	return []string{"SOL", "BTC", "XAU"}
}



// FinalizeBattleWithMPC submits battle settlement with all three signatures
func (c *Client) FinalizeBattleWithMPC(
	ctx context.Context,
	battleID uint64,
	winnerIsChallenger bool,
	challengerSig []byte,
	defenderSig []byte,
	judgeSig []byte,
) (*solana.Transaction, error) {
	// Derive battle PDA
	battleSeeds := [][]byte{
		[]byte("battle"),
		make([]byte, 8),
	}
	binary.LittleEndian.PutUint64(battleSeeds[1], battleID)
	
	battleAccount, _, err := solana.FindProgramAddress(battleSeeds, c.programID)
	if err != nil {
		return nil, err
	}

	// Get depositor accounts for both parties
	// Note: This requires knowing the challenger and defender addresses
	// In practice, these would be passed in or fetched from the battle account
	
	data := []byte{5} // finalize_battle_mpc instruction discriminator
	if winnerIsChallenger {
		data = append(data, 1)
	} else {
		data = append(data, 0)
	}
	data = append(data, challengerSig...)
	data = append(data, defenderSig...)
	data = append(data, judgeSig...)

	// This is a simplified version - actual implementation would need
	// all the proper accounts including depositors and depository
	instruction := &solana.GenericInstruction{
		ProgID: c.programID,
		AccountValues: []*solana.AccountMeta{
			{PublicKey: c.wallet.PublicKey(), IsSigner: true, IsWritable: false},
			{PublicKey: battleAccount, IsSigner: false, IsWritable: true},
			// Additional accounts would be added here
		},
		DataBytes: data,
	}

	recent, err := c.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
	if err != nil {
		return nil, err
	}

	tx, err := solana.NewTransaction(
		[]solana.Instruction{instruction},
		recent.Value.Blockhash,
		solana.TransactionPayer(c.wallet.PublicKey()),
	)
	if err != nil {
		return nil, err
	}

	return tx, nil
}