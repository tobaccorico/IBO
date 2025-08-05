package ethereum

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Contract interfaces (these would be generated from ABIs)
type RouterContract interface {
	Deposit(opts *bind.TransactOpts) (*types.Transaction, error)
	Withdraw(opts *bind.TransactOpts, amount *big.Int) (*types.Transaction, error)
	OutOfRange(opts *bind.TransactOpts, amount *big.Int, token common.Address, distance *big.Int, rangeWidth *big.Int) (*types.Transaction, error)
	Reclaim(opts *bind.TransactOpts, id *big.Int, percent *big.Int) (*types.Transaction, error)
}

type AuxiliaryContract interface {
	Swap(opts *bind.TransactOpts, token common.Address, zeroForOne bool, amount *big.Int, waitable *big.Int) (*types.Transaction, error)
	LeverOneForZero(opts *bind.TransactOpts, amount *big.Int) (*types.Transaction, error)
	LeverZeroForOne(opts *bind.TransactOpts, amount *big.Int, token common.Address) (*types.Transaction, error)
	Redeem(opts *bind.TransactOpts, amount *big.Int) (*types.Transaction, error)
	Unwind(opts *bind.TransactOpts, whose []common.Address, oneForZero []bool) (*types.Transaction, error)
}

type BasketContract interface {
	// Note: Users should NEVER call take() directly
	Deposit(opts *bind.TransactOpts, from common.Address, token common.Address, amount *big.Int) (*types.Transaction, error)
	Mint(opts *bind.TransactOpts, pledge common.Address, amount *big.Int, token common.Address, when *big.Int) (*types.Transaction, error)
}

type EthereumClient struct {
	client      *ethclient.Client
	chainID     *big.Int
	privateKey  *ecdsa.PrivateKey
	publicKey   common.Address
	
	// Contract instances
	router      RouterContract
	auxiliary   AuxiliaryContract
	basket      BasketContract
	
	// Contract addresses
	routerAddr    common.Address
	auxiliaryAddr common.Address
	basketAddr    common.Address
	
	// Constants from contracts
	swapCost    *big.Int
	unwindCost  *big.Int
}

// NewEthereumClient creates a new Ethereum client
func NewEthereumClient(rpcURL, routerAddr, auxiliaryAddr, privateKeyHex string) (*EthereumClient, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to Ethereum node: %w", err)
	}
	
	chainID, err := client.NetworkID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to get network ID: %w", err)
	}
	
	ec := &EthereumClient{
		client:        client,
		chainID:       chainID,
		routerAddr:    common.HexToAddress(routerAddr),
		auxiliaryAddr: common.HexToAddress(auxiliaryAddr),
		swapCost:      big.NewInt(637000 * 2), // From Auxiliary.sol
		unwindCost:    big.NewInt(3524821),    // From Auxiliary.sol
	}
	
	// Setup private key if provided
	if privateKeyHex != "" {
		privateKey, err := crypto.HexToECDSA(privateKeyHex)
		if err != nil {
			return nil, fmt.Errorf("invalid private key: %w", err)
		}
		ec.privateKey = privateKey
		ec.publicKey = crypto.PubkeyToAddress(privateKey.PublicKey)
	}
	
	// TODO: Initialize contract instances from ABIs
	// ec.router = NewRouter(routerAddr, client)
	// ec.auxiliary = NewAuxiliary(auxiliaryAddr, client)
	// ec.basket = NewBasket(basketAddr, client)
	
	return ec, nil
}

// Router Functions

// DepositETH deposits ETH into the Router for auto-managed liquidity
func (c *EthereumClient) DepositETH(amount *big.Int) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	auth.Value = amount // Send ETH with the transaction
	
	tx, err := c.router.Deposit(auth)
	if err != nil {
		return fmt.Errorf("failed to deposit: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// WithdrawETH withdraws liquidity from the Router
func (c *EthereumClient) WithdrawETH(amount *big.Int) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	tx, err := c.router.Withdraw(auth, amount)
	if err != nil {
		return fmt.Errorf("failed to withdraw: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// CreateOutOfRangePosition creates a self-managed liquidity position
func (c *EthereumClient) CreateOutOfRangePosition(amount *big.Int, token common.Address, distance int32, rangeWidth uint32) (uint64, error) {
	if c.privateKey == nil {
		return 0, fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return 0, fmt.Errorf("failed to create transactor: %w", err)
	}
	
	// If token is zero address, we're depositing ETH
	if token == (common.Address{}) {
		auth.Value = amount
	}
	
	tx, err := c.router.OutOfRange(auth, amount, token, big.NewInt(int64(distance)), big.NewInt(int64(rangeWidth)))
	if err != nil {
		return 0, fmt.Errorf("failed to create position: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return 0, fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return 0, fmt.Errorf("transaction failed")
	}
	
	// TODO: Extract position ID from logs
	// For now, return a mock ID
	return 1, nil
}

// ReclaimPosition reclaims liquidity from a self-managed position
func (c *EthereumClient) ReclaimPosition(id uint64, percent int32) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	tx, err := c.router.Reclaim(auth, big.NewInt(int64(id)), big.NewInt(int64(percent)))
	if err != nil {
		return fmt.Errorf("failed to reclaim: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// Auxiliary Functions

// Swap performs a swap through the Auxiliary contract
func (c *EthereumClient) Swap(token common.Address, zeroForOne bool, amount *big.Int, waitable uint64) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	// For swaps over $5000, need to pay gas compensation
	// This is handled in the contract based on msg.value
	sensitive := false
	if amount.Cmp(big.NewInt(5000000000)) >= 0 { // $5000 in 6 decimals
		sensitive = true
		auth.Value = c.swapCost
	}
	
	tx, err := c.auxiliary.Swap(auth, token, zeroForOne, amount, big.NewInt(int64(waitable)))
	if err != nil {
		return fmt.Errorf("failed to swap: %w", err)
	}
	
	if sensitive {
		// Large swaps are batched and may not execute immediately
		fmt.Printf("Swap queued for batch execution in block %s\n", tx.Hash().Hex())
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// LeverageETH creates a leveraged ETH position (borrow USDC against ETH)
func (c *EthereumClient) LeverageETH(amount *big.Int) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	// Must send ETH amount + unwind cost
	totalValue := new(big.Int).Add(amount, c.unwindCost)
	auth.Value = totalValue
	
	tx, err := c.auxiliary.LeverOneForZero(auth, amount)
	if err != nil {
		return fmt.Errorf("failed to leverage: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// LeverageUSD creates a leveraged USD position (borrow ETH against stables)
func (c *EthereumClient) LeverageUSD(amount *big.Int, token common.Address) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	// Must send unwind cost in ETH
	auth.Value = c.unwindCost
	
	tx, err := c.auxiliary.LeverZeroForOne(auth, amount, token)
	if err != nil {
		return fmt.Errorf("failed to leverage: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// Redeem redeems QD tokens for underlying assets
func (c *EthereumClient) Redeem(amount *big.Int) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	tx, err := c.auxiliary.Redeem(auth, amount)
	if err != nil {
		return fmt.Errorf("failed to redeem: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// UnwindPositions unwinds leveraged positions when price moves significantly
func (c *EthereumClient) UnwindPositions(addresses []common.Address, oneForZero []bool) error {
	if c.privateKey == nil {
		return fmt.Errorf("no private key configured")
	}
	
	if len(addresses) != len(oneForZero) {
		return fmt.Errorf("addresses and oneForZero arrays must have same length")
	}
	
	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}
	
	tx, err := c.auxiliary.Unwind(auth, addresses, oneForZero)
	if err != nil {
		return fmt.Errorf("failed to unwind: %w", err)
	}
	
	receipt, err := bind.WaitMined(context.Background(), c.client, tx)
	if err != nil {
		return fmt.Errorf("failed to wait for transaction: %w", err)
	}
	
	if receipt.Status != 1 {
		return fmt.Errorf("transaction failed")
	}
	
	return nil
}

// Utility Functions

// GetBalance returns the ETH balance of an address
func (c *EthereumClient) GetBalance(address common.Address) (*big.Int, error) {
	return c.client.BalanceAt(context.Background(), address, nil)
}

// GetGasPrice returns the current gas price
func (c *EthereumClient) GetGasPrice() (*big.Int, error) {
	return c.client.SuggestGasPrice(context.Background())
}

// WaitForTransaction waits for a transaction to be mined
func (c *EthereumClient) WaitForTransaction(txHash common.Hash) (*types.Receipt, error) {
	return bind.WaitMined(context.Background(), c.client, &types.Transaction{})
}