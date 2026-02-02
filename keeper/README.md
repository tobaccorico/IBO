# QU!D Protocol Keeper Bot

Automated keeper bot for the QU!D Protocol that:
1. Monitors leveraged positions and calls `unwind` when price moves ±2.5%
2. Monitors pending batch swaps and calls `clearSwaps` when needed

## Setup

```bash
cd keeper
npm install
```

## Configuration

Set environment variables:

```bash
# RPC endpoints (optional - uses public RPCs by default)
export ETH_RPC="https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY"
export POLYGON_RPC="https://polygon-mainnet.alchemyapi.io/v2/YOUR_KEY"

# Keeper wallet private key (required for transactions)
export KEEPER_PRIVATE_KEY="0x..."
```

## Running

### Development (read-only mode)
```bash
npm start
```

### Production
```bash
# Build first
npm run build

# Run compiled version
node keeper.js
```

### Using PM2 (recommended for production)
```bash
pm2 start keeper.js --name "quid-keeper"
pm2 save
pm2 startup
```

## How It Works

### Position Monitoring

The keeper tracks `LeveragedPositionOpened` events from the Amp contract and maintains a list of active positions. Every 15 seconds, it:

1. Fetches current ETH price from `Aux.getTWAP(1800)`
2. Calculates price delta for each position: `(currentPrice - entryPrice) / entryPrice`
3. If delta is ≤ -2.5% or ≥ +2.5%, calls the appropriate unwind function:
   - `unwindZeroForOne()` for long positions
   - `unwindOneForZero()` for short positions

### Swap Clearing

The keeper also monitors the `lastBlock` state in Aux and:

1. Compares `lastBlock` to current block number
2. Checks `Vogue.getSwapsETH()` for blocks between `lastBlock + 1` and `currentBlock - 1`
3. If pending swaps exist, calls `Aux.clearSwaps()`

## Contract Addresses

### Base (Chain ID: 8453)
- Aux: `0xB3Ab6732580D9b75E8f6eb3ea8204500E9872D75`
- Amp: `0x48AE204e2e2dd73C6ab6B20A040902511E48f552`
- Vogue: `0x64830Cc6682C36dE6EAA1Afc771FBfc16322D092`

### Arbitrum (Chain ID: 42161)
- Aux: `0xBb7BB6C91BDeA9502f2591B4AA71dBa3A70FF851`
- Amp: `0x24896a2e1BA25903af0bBA86bE4752aDEC09bDC1`
- Vogue: `0x09a0519D00fc98A1a055B5FB38d35C7668d1789F`

### Unichain (Chain ID: 130)
- **No Amp contract** - leverage not available on this chain

### Ethereum L1 & Polygon (Currently Disabled)
- Contracts exist but not yet deployed with latest version

## Gas Considerations

The keeper needs ETH/MATIC to pay for transactions:
- `unwindZeroForOne` / `unwindOneForZero`: ~200k-500k gas per batch
- `clearSwaps`: ~100k-300k gas

Ensure your keeper wallet is funded on all active chains.
