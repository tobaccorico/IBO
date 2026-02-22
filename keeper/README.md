# QU!D Protocol Keeper Bot

Automated keeper bot for the QU!D Protocol that:
1. Monitors leveraged positions and calls `unwind` when price moves ±2.5%

## Setup

```bash
# CRE CLI
curl -sSL https://docs.chain.link/cre/install | sh
cre login

# Go (wasip1 target must be supported)
go version  # >= 1.23
```

# Resolve dependencies (creates go.sum)
go mod tidy

```
### 3. Generate UMA Bindings (Recommended)
```bash
# This creates type-safe Go bindings from UMA.sol ABI
# which gives you WriteReportFromOnReport() instead of raw WriteReport()

cre generate-bindings --abi ../out/UMA.sol/UMA.json --pkg uma --out my-workflow/uma/
```

### 4. Configure
```bash
# Copy .env template
cp .env.example .env
# Edit with your keys:
#   CRE_ETH_PRIVATE_KEY=0x... (any funded Sepolia key)
#   GEMINI_API_KEY_VAR=...    (optional, falls back to deterministic)
#   CMC_API_KEY_VAR=...       (optional)

# Update contract addresses in config files:
#   my-workflow/config.staging.json  → umaContractAddress, auxContractAddress
#   my-workflow/config.production.json → same
```

### 5. Test
```bash
# Dry-run simulation (no broadcast)
cd safta-cre
cre workflow simulate my-workflow --target staging-settings

# With HTTP trigger (like forge vm.ffi does):
cre workflow simulate my-workflow \
  --non-interactive \
  --trigger-index 2 \
  --http-payload '{"assertionId":"0xabc...","claimedSide":2,"bond":"1000000000000000000","mode":"watchdog"}' \
  --target staging-settings

# Forge integration test:
cd ..  # back to repo root
forge test --match-test test_CRE -vvv --ffi
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


The keeper needs ETH/MATIC to pay for transactions:
- `unwindZeroForOne` / `unwindOneForZero`: ~200k-500k gas per batch

Ensure your keeper wallet is funded on all active chains.
