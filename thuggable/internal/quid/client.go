package quid

import (
	"context"
    "encoding/binary"
    "fmt"
    "math/big"

	"github.com/gagliardetto/binary"
	"github.com/gagliardetto/solana-go"
	
	"github.com/gagliardetto/solana-go/rpc"
	"github.com/gagliardetto/solana-go/rpc/jsonrpc"
	"github.com/gagliardetto/solana-go/programs/system"
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
)

type BattleID uint64

func (b BattleID) Bytes() []byte {
    buf := make([]byte, 8)
    binary.LittleEndian.PutUint64(buf, uint64(b))
    return buf
}

type AssetInfo struct {
	Symbol   string
	Decimals int
}

type Client struct {
    rpcClient *rpc.Client
    wallet    solana.PrivateKey
    programID solana.PublicKey
}

type BattleState struct {
    ID          uint64
    Creator     solana.PublicKey
    Opponent    solana.PublicKey
    Status      uint8
    Winner      solana.PublicKey
}

func DeserializeBattleState(data []byte, state *BattleState) error {
    if len(data) < 105 { // 8 + 32 + 32 + 1 + 32
        return fmt.Errorf("insufficient data for battle state")
    }
    
    state.ID = binary.LittleEndian.Uint64(data[0:8])
    copy(state.Creator[:], data[8:40])
    copy(state.Opponent[:], data[40:72])
    state.Status = data[72]
    copy(state.Winner[:], data[73:105])
    
    return nil
}


func (c *Client) JoinBattle(ctx context.Context, battleID uint64) (*solana.Signature, error) {
    // Instruction discriminator for join_battle
    discriminator := []byte{2} // Assuming 2 is the join_battle instruction
    
    // Create battle ID bytes
    battleIDBytes := make([]byte, 8)
    binary.LittleEndian.PutUint64(battleIDBytes, battleID)
    
    // Combine discriminator and battle ID
    data := append(discriminator, battleIDBytes...)
    
    // Derive battle PDA
    seeds := [][]byte{
        []byte("battle"),
        battleIDBytes,
    }
    battlePDA, _, err := solana.FindProgramAddress(seeds, c.programID)
    if err != nil {
        return nil, fmt.Errorf("failed to derive battle PDA: %w", err)
    }
    
    // Build instruction
    instruction := &solana.GenericInstruction{
        ProgID: c.programID,
        AccountValues: solana.AccountMetaSlice{
            {PublicKey: c.wallet.PublicKey(), IsSigner: true, IsWritable: true},
            {PublicKey: battlePDA, IsSigner: false, IsWritable: true},
        },
        DataBytes: data,
    }
    
    // Get recent blockhash
    recent, err := c.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
    if err != nil {
        return nil, fmt.Errorf("failed to get recent blockhash: %w", err)
    }
    
    // Build and sign transaction
    tx, err := solana.NewTransaction(
        []solana.Instruction{instruction},
        recent.Value.Blockhash,
        solana.TransactionPayer(c.wallet.PublicKey()),
    )
    if err != nil {
        return nil, fmt.Errorf("failed to create transaction: %w", err)
    }
    
    _, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
        if key.Equals(c.wallet.PublicKey()) {
            return &c.wallet
        }
        return nil
    })
    if err != nil {
        return nil, fmt.Errorf("failed to sign transaction: %w", err)
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
        return nil, fmt.Errorf("failed to send transaction: %w", err)
    }
    
    return &sig, nil
}

func (c *Client) CreateBattle(ctx context.Context, battleID BattleID) (*solana.Signature, error) {
    // Get recent blockhash
    recent, err := c.rpcClient.GetRecentBlockhash(ctx, rpc.CommitmentFinalized)
    if err != nil {
        return nil, fmt.Errorf("failed to get recent blockhash: %w", err)
    }
    
    // Build instruction
    instruction := solana.NewInstruction(
        c.programID,
        solana.AccountMetaSlice{
            {PublicKey: c.wallet.PublicKey(), IsSigner: true, IsWritable: true},
        },
        battleID.Bytes(),
    )
    
    // Build transaction
    tx, err := solana.NewTransaction(
        []solana.Instruction{instruction},
        recent.Value.Blockhash,
        solana.TransactionPayer(c.wallet.PublicKey()),
    )
    if err != nil {
        return nil, fmt.Errorf("failed to create transaction: %w", err)
    }
    
    // Sign transaction
    _, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
        if key.Equals(c.wallet.PublicKey()) {
            return &c.wallet
        }
        return nil
    })
    if err != nil {
        return nil, fmt.Errorf("failed to sign transaction: %w", err)
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
        return nil, fmt.Errorf("failed to send transaction: %w", err)
    }
    
    return &sig, nil
}

func (c *Client) GetBattleState(ctx context.Context,
	battleID BattleID) (*BattleState, error) {
   
    seeds := [][]byte{
        []byte("battle"),
        battleID.Bytes(),
    }
    
    battlePDA, _, err := solana.FindProgramAddress(seeds, c.programID)
    if err != nil {
        return nil, fmt.Errorf("failed to derive battle PDA: %w", err)
    }
    
    account, err := c.rpcClient.GetAccountInfo(ctx, battlePDA)
    if err != nil {
        return nil, fmt.Errorf("failed to get battle account: %w", err)
    }
    
    var state BattleState
    if err := DeserializeBattleState(account.Value.Data.GetBinary(), &state); err != nil {
        return nil, fmt.Errorf("failed to deserialize battle state: %w", err)
    }
    
    return &state, nil
}

func NewClient(rpcURL string,
	walletKey string, programID string) (*Client, error) {
    wallet, err := solana.PrivateKeyFromBase58(walletKey)
    if err != nil {
        return nil, fmt.Errorf("invalid wallet key: %w", err)
    }
 
    program, err := solana.PublicKeyFromBase58(programID)
    if err != nil {
        return nil, fmt.Errorf("invalid program ID: %w", err)
    }
    
    return &Client{
        rpcClient: rpc.New(rpcURL),
        wallet:    wallet,
        programID: program,
    }, nil
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