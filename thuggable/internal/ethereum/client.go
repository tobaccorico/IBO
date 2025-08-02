// internal/ethereum/client.go
package ethereum

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

// MetaMaskSigner handles MetaMask-style message signing
type MetaMaskSigner struct {
	client     *ethclient.Client
	chainID    *big.Int
	address    common.Address
	privateKey *ecdsa.PrivateKey // Optional for local signing
}

// EthereumClient wraps ethereum operations
type EthereumClient struct {
	client        *ethclient.Client
	rpcClient     *rpc.Client
	signer        *MetaMaskSigner
	routerAddress common.Address
	auxAddress    common.Address
	basketAddress common.Address
	chainID       *big.Int
}

// PreSignedCall represents a pre-signed function call
type PreSignedCall struct {
	Target       common.Address
	FunctionSig  string
	Params       []interface{}
	Nonce        *big.Int
	ValidUntil   *big.Int
	Signature    []byte
}

// NewEthereumClient creates a new Ethereum client
func NewEthereumClient(rpcURL string, routerAddr, auxAddr, basketAddr string) (*EthereumClient, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to ethereum node: %v", err)
	}

	rpcClient, err := rpc.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to RPC: %v", err)
	}

	chainID, err := client.NetworkID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to get network ID: %v", err)
	}

	return &EthereumClient{
		client:        client,
		rpcClient:     rpcClient,
		routerAddress: common.HexToAddress(routerAddr),
		auxAddress:    common.HexToAddress(auxAddr),
		basketAddress: common.HexToAddress(basketAddr),
		chainID:       chainID,
	}, nil
}

// ConnectMetaMask simulates MetaMask connection (in real app, this would use web3 provider)
func (ec *EthereumClient) ConnectMetaMask(address string) error {
	ec.signer = &MetaMaskSigner{
		client:  ec.client,
		chainID: ec.chainID,
		address: common.HexToAddress(address),
	}
	return nil
}

// SignMessage signs a message using EIP-712 typed data
func (ms *MetaMaskSigner) SignMessage(message []byte) ([]byte, error) {
	// EIP-712 domain separator
	domainSeparator := crypto.Keccak256(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
		[]byte("QUID Protocol"),
		[]byte("1"),
		ms.chainID.Bytes(),
		ms.address.Bytes(),
	)

	// Message hash
	messageHash := crypto.Keccak256(
		[]byte("\x19\x01"),
		domainSeparator,
		crypto.Keccak256(message),
	)

	// In production, this would request signature from MetaMask
	// For now, we'll simulate with local key if available
	if ms.privateKey != nil {
		return crypto.Sign(messageHash, ms.privateKey)
	}

	// Simulate MetaMask signing request
	return nil, fmt.Errorf("MetaMask signing not implemented in CLI mode")
}

// CreatePreSignedClearSwaps creates a pre-signed clearSwaps call
func (ec *EthereumClient) CreatePreSignedClearSwaps(validForBlocks uint64) (*PreSignedCall, error) {
	if ec.signer == nil {
		return nil, fmt.Errorf("no signer connected")
	}

	// Get current block number
	blockNumber, err := ec.client.BlockNumber(context.Background())
	if err != nil {
		return nil, err
	}

	// Get nonce
	nonce, err := ec.client.PendingNonceAt(context.Background(), ec.signer.address)
	if err != nil {
		return nil, err
	}

	preSignedCall := &PreSignedCall{
		Target:       ec.auxAddress,
		FunctionSig:  "clearSwaps()",
		Params:       []interface{}{},
		Nonce:        big.NewInt(int64(nonce)),
		ValidUntil:   big.NewInt(int64(blockNumber + validForBlocks)),
	}

	// Create message to sign
	message := ec.encodePreSignedCall(preSignedCall)
	
	// Sign the message
	signature, err := ec.signer.SignMessage(message)
	if err != nil {
		return nil, err
	}

	preSignedCall.Signature = signature
	return preSignedCall, nil
}

// ExecutePreSignedCall executes a pre-signed function call
func (ec *EthereumClient) ExecutePreSignedCall(call *PreSignedCall) (*types.Transaction, error) {
	// Verify signature is still valid
	blockNumber, err := ec.client.BlockNumber(context.Background())
	if err != nil {
		return nil, err
	}

	if big.NewInt(int64(blockNumber)).Cmp(call.ValidUntil) > 0 {
		return nil, fmt.Errorf("pre-signed call has expired")
	}

	// Build transaction data
	data, err := ec.encodeFunctionCall(call.FunctionSig, call.Params...)
	if err != nil {
		return nil, err
	}

	// Execute via meta-transaction pattern
	// This would call a forwarder contract that verifies the signature
	// and executes the call on behalf of the signer
	return ec.sendMetaTransaction(call, data)
}

// ClearSwapsWithRepack calls clearSwaps which triggers _repack in the background
func (ec *EthereumClient) ClearSwapsWithRepack() (*types.Transaction, error) {
	// Load contract ABI
	auxABI, err := abi.JSON(strings.NewReader(AuxiliaryABI))
	if err != nil {
		return nil, err
	}

	// Pack the clearSwaps call
	data, err := auxABI.Pack("clearSwaps")
	if err != nil {
		return nil, err
	}

	// Get gas price
	gasPrice, err := ec.client.SuggestGasPrice(context.Background())
	if err != nil {
		return nil, err
	}

	// Create transaction
	tx := types.NewTransaction(
		0, // nonce will be set by signer
		ec.auxAddress,
		big.NewInt(0), // no ETH value
		300000,        // gas limit
		gasPrice,
		data,
	)

	// Send transaction
	return ec.sendTransaction(tx)
}

// MonitorLiquidations monitors for liquidation opportunities
func (ec *EthereumClient) MonitorLiquidations(ctx context.Context, callback func(event *LiquidationEvent)) error {
	// Set up event filter
	query := ethereum.FilterQuery{
		Addresses: []common.Address{ec.basketAddress, ec.auxAddress},
		Topics:    [][]common.Hash{{LiquidationEventHash}},
	}

	logs := make(chan types.Log)
	sub, err := ec.client.SubscribeFilterLogs(ctx, query, logs)
	if err != nil {
		return err
	}

	go func() {
		for {
			select {
			case err := <-sub.Err():
				fmt.Printf("Subscription error: %v\n", err)
				return
			case vLog := <-logs:
				event, err := parseLiquidationEvent(vLog)
				if err != nil {
					fmt.Printf("Failed to parse event: %v\n", err)
					continue
				}
				callback(event)
			case <-ctx.Done():
				return
			}
		}
	}()

	return nil
}

// Helper functions

func (ec *EthereumClient) encodePreSignedCall(call *PreSignedCall) []byte {
	// EIP-712 structured data encoding
	return crypto.Keccak256(
		[]byte("PreSignedCall(address target,string functionSig,uint256 nonce,uint256 validUntil)"),
		call.Target.Bytes(),
		[]byte(call.FunctionSig),
		call.Nonce.Bytes(),
		call.ValidUntil.Bytes(),
	)
}

func (ec *EthereumClient) encodeFunctionCall(functionSig string, params ...interface{}) ([]byte, error) {
	// Parse function signature
	method, err := abi.NewMethod(functionSig, functionSig, abi.Function, "", false, false, nil, nil)
	if err != nil {
		return nil, err
	}

	// Pack arguments
	return method.Inputs.Pack(params...)
}

func (ec *EthereumClient) sendTransaction(tx *types.Transaction) (*types.Transaction, error) {
	// In production, this would use MetaMask provider
	// For now, simulate sending
	return tx, nil
}

func (ec *EthereumClient) sendMetaTransaction(call *PreSignedCall, data []byte) (*types.Transaction, error) {
	// Meta-transaction would be sent to a forwarder contract
	// that verifies the signature and executes on behalf of signer
	return nil, fmt.Errorf("meta-transaction forwarding not yet implemented")
}

// Event definitions

var (
	LiquidationEventHash = crypto.Keccak256Hash([]byte("Liquidation(address,address,uint256)"))
)

type LiquidationEvent struct {
	User   common.Address
	Asset  common.Address
	Amount *big.Int
}

func parseLiquidationEvent(log types.Log) (*LiquidationEvent, error) {
	// Parse event data
	event := &LiquidationEvent{
		User:   common.HexToAddress(hex.EncodeToString(log.Topics[1].Bytes())),
		Asset:  common.HexToAddress(hex.EncodeToString(log.Topics[2].Bytes())),
		Amount: new(big.Int).SetBytes(log.Data),
	}
	return event, nil
}

// Contract ABIs (simplified)
const AuxiliaryABI = `[
	{
		"inputs": [],
		"name": "clearSwaps",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"internalType": "uint256", "name": "howMuch", "type": "uint256"},
			{"internalType": "address", "name": "toWhom", "type": "address"}
		],
		"name": "sendETH",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`