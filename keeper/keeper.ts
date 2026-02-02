/**
 * QU!D Protocol Keeper Bot
 *
 * Responsibilities:
 * 1. Monitor leveraged positions and call unwind when price moves ±2.5%
 *
 * Run: npx ts-node keeper.ts
 * Or compile: npx tsc keeper.ts && node keeper.js
 */

import { ethers } from 'ethers'

// ============== CONFIGURATION ==============
const CONFIG = {
  // RPC endpoints (use your own or Infura/Alchemy)
  RPC: {
    8453: process.env.BASE_RPC || 'https://mainnet.base.org',
    42161: process.env.ARBITRUM_RPC || 'https://arb1.arbitrum.io/rpc',
    // Unichain has no Amp - no keeper needed
  } as Record<number, string>,
  // Contract addresses
  CONTRACTS: {
    8453: { // Base
      aux: '0xB3Ab6732580D9b75E8f6eb3ea8204500E9872D75',
      amp: '0x48AE204e2e2dd73C6ab6B20A040902511E48f552',
      vogue: '0x64830Cc6682C36dE6EAA1Afc771FBfc16322D092',
    },
    42161: { // Arbitrum
      aux: '0xBb7BB6C91BDeA9502f2591B4AA71dBa3A70FF851',
      amp: '0x24896a2e1BA25903af0bBA86bE4752aDEC09bDC1',
      vogue: '0x09a0519D00fc98A1a055B5FB38d35C7668d1789F',
    },
    // L1 and Polygon - disabled for now
    1: {
      aux: '0x692fE0104706d772D51236418C7d1A2264b15031',
      amp: '0x2eA8Ef6585f544Bc57e149Ac4EC09854aEf00c71',
      vogue: '0x8e846FD5f828425a2F4Df7EAc2aC2a84524f2256',
    },
    137: {
      aux: '0xcEB26F3898F84C90a1FbFE7e305126327df5eEDa',
      amp: '0x184b1D1cfD9De5D8BF70BCE2d7960741b5D0876E',
      vogue: '0x9743dE2355d3840D52529503d496bf33fF7a9793',
    },
  } as Record<number, { aux: string; amp: string; vogue: string }>,
  // Keeper wallet private key (set via environment variable)
  PRIVATE_KEY: process.env.KEEPER_PRIVATE_KEY || '',
  // Check interval in milliseconds
  CHECK_INTERVAL: 15000, // 15 seconds
  // Price delta threshold for unwinding (2.5% = 25 in contract terms)
  PRICE_DELTA_THRESHOLD: 25,
  // Chains to monitor (only chains with Amp)
  ACTIVE_CHAINS: [8453, 42161] as const,
}

// ============== ABIs ==============
const AUX_ABI = [
  'function getTWAP(uint32 period) view returns (uint256)',
  'function leverETH(uint256 amount) payable external',
  'function leverUSD(uint256 amount, address token) external',
]

const AMP_ABI = [
  'function unwindZeroForOne(address[] calldata whose) external',
  'function unwindOneForZero(address[] calldata whose) external',
  'event LeveragedPositionOpened(address indexed user, bool indexed isLong, uint256 supplied, uint256 borrowed, uint256 buffer, int256 entryPrice, uint256 breakeven, uint256 blockNumber)',
  'event PositionUnwound(address indexed user, bool indexed isLong, int256 exitPrice, int256 priceDelta, uint256 blockNumber)',
]

const VOGUE_ABI = [
  'function getSwapsETH(uint256 blockNumber) view returns (tuple(uint256 total, address[] depositors, uint256[] amounts), tuple(uint256 total, address[] depositors, uint256[] amounts))',
]

// ============== TYPES ==============
interface Position {
  user: string
  isLong: boolean
  entryPrice: bigint
  breakeven: bigint
  supplied: bigint
  borrowed: bigint
  buffer: bigint
  blockNumber: number
  chainId: number
}

interface ChainState {
  provider: ethers.JsonRpcProvider
  wallet: ethers.Wallet | null
  aux: ethers.Contract
  amp: ethers.Contract
  vogue: ethers.Contract
  positions: Map<string, Position>
  lastProcessedBlock: number
}

// ============== KEEPER CLASS ==============
class QuidKeeper {
  private chains: Map<number, ChainState> = new Map()
  private isRunning = false

  constructor() {
    console.log('🤖 QU!D Keeper Bot Initializing...')
  }

  async initialize(): Promise<void> {
    for (const chainId of CONFIG.ACTIVE_CHAINS) {
      const rpc = CONFIG.RPC[chainId]
      if (!rpc) {
        console.warn(`⚠️ No RPC configured for chain ${chainId}`)
        continue
      }

      const provider = new ethers.JsonRpcProvider(rpc)
      const contracts = CONFIG.CONTRACTS[chainId]

      let wallet: ethers.Wallet | null = null
      if (CONFIG.PRIVATE_KEY) {
        wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider)
        console.log(`💰 Keeper wallet: ${wallet.address}`)
      } else {
        console.warn('⚠️ No KEEPER_PRIVATE_KEY set - running in read-only mode')
      }

      const aux = new ethers.Contract(contracts.aux, AUX_ABI, wallet || provider)
      const amp = new ethers.Contract(contracts.amp, AMP_ABI, wallet || provider)
      const vogue = new ethers.Contract(contracts.vogue, VOGUE_ABI, provider)

      const currentBlock = await provider.getBlockNumber()

      this.chains.set(chainId, {
        provider,
        wallet,
        aux,
        amp,
        vogue,
        positions: new Map(),
        lastProcessedBlock: currentBlock - 1000, // Start from ~1000 blocks ago
      })

      console.log(`✅ Chain ${chainId} initialized at block ${currentBlock}`)
    }
  }

  async loadHistoricalPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state) return

    console.log(`📜 Loading historical positions for chain ${chainId}...`)

    const currentBlock = await state.provider.getBlockNumber()
    const fromBlock = Math.max(0, currentBlock - 50000) // Last ~50k blocks

    try {
      // Query LeveragedPositionOpened events
      const openFilter = state.amp.filters.LeveragedPositionOpened()
      const openEvents = await state.amp.queryFilter(openFilter, fromBlock, currentBlock)

      // Query PositionUnwound events to remove closed positions
      const closeFilter = state.amp.filters.PositionUnwound()
      const closeEvents = await state.amp.queryFilter(closeFilter, fromBlock, currentBlock)

      const closedUsers = new Set(closeEvents.map((e: any) => e.args.user.toLowerCase()))

      for (const event of openEvents) {
        const args = (event as any).args
        const user = args.user.toLowerCase()

        // Skip if already unwound
        if (closedUsers.has(user)) continue

        const position: Position = {
          user: args.user,
          isLong: args.isLong,
          entryPrice: args.entryPrice,
          breakeven: args.breakeven,
          supplied: args.supplied,
          borrowed: args.borrowed,
          buffer: args.buffer,
          blockNumber: Number(args.blockNumber),
          chainId,
        }

        const key = `${chainId}-${user}-${args.isLong}`
        state.positions.set(key, position)
      }

      console.log(`📊 Loaded ${state.positions.size} active positions on chain ${chainId}`)
    } catch (error) {
      console.error(`❌ Error loading positions for chain ${chainId}:`, error)
    }
  }

  async checkAndUnwindPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state || !state.wallet) return
    if (state.positions.size === 0) return

    try {
      // Get current price from TWAP
      const currentPrice = await state.aux.getTWAP(1800)
      console.log(`💹 Chain ${chainId} ETH Price: $${Number(currentPrice) / 1e18}`)

      const toUnwindLong: string[] = []
      const toUnwindShort: string[] = []

      for (const [key, position] of state.positions) {
        if (position.chainId !== chainId) continue

        const entryPrice = position.entryPrice
        const delta = ((currentPrice - entryPrice) * 1000n) / entryPrice

        const deltaNum = Number(delta)
        if (deltaNum <= -CONFIG.PRICE_DELTA_THRESHOLD || deltaNum >= CONFIG.PRICE_DELTA_THRESHOLD) {
          console.log(`⚡ Position ${position.user} needs unwinding: delta=${deltaNum / 10}%`)

          if (position.isLong) {
            toUnwindLong.push(position.user)
          } else {
            toUnwindShort.push(position.user)
          }
        }
      }

      // Batch unwind calls (max 30 per call as per contract)
      if (toUnwindLong.length > 0) {
        const batch = toUnwindLong.slice(0, 30)
        console.log(`🔄 Unwinding ${batch.length} long positions...`)
        try {
          const tx = await state.amp.unwindZeroForOne(batch)
          console.log(`📤 Unwind long tx: ${tx.hash}`)
          await tx.wait()
          console.log(`✅ Unwind long confirmed`)

          // Remove unwound positions
          for (const user of batch) {
            state.positions.delete(`${chainId}-${user.toLowerCase()}-true`)
          }
        } catch (error: any) {
          console.error(`❌ Unwind long failed:`, error.message)
        }
      }

      if (toUnwindShort.length > 0) {
        const batch = toUnwindShort.slice(0, 30)
        console.log(`🔄 Unwinding ${batch.length} short positions...`)
        try {
          const tx = await state.amp.unwindOneForZero(batch)
          console.log(`📤 Unwind short tx: ${tx.hash}`)
          await tx.wait()
          console.log(`✅ Unwind short confirmed`)

          // Remove unwound positions
          for (const user of batch) {
            state.positions.delete(`${chainId}-${user.toLowerCase()}-false`)
          }
        } catch (error: any) {
          console.error(`❌ Unwind short failed:`, error.message)
        }
      }
    } catch (error) {
      console.error(`❌ Error checking positions on chain ${chainId}:`, error)
    }
  }

  async listenForNewPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state) return

    // Listen for new position opens
    state.amp.on('LeveragedPositionOpened', (user, isLong, supplied, borrowed, buffer, entryPrice, breakeven, blockNumber) => {
      console.log(`🆕 New position opened: ${user} ${isLong ? 'LONG' : 'SHORT'} at $${Number(entryPrice) / 1e18}`)

      const position: Position = {
        user,
        isLong,
        entryPrice,
        breakeven,
        supplied,
        borrowed,
        buffer,
        blockNumber: Number(blockNumber),
        chainId,
      }

      const key = `${chainId}-${user.toLowerCase()}-${isLong}`
      state.positions.set(key, position)
    })

    // Listen for position closes
    state.amp.on('PositionUnwound', (user, isLong, exitPrice, priceDelta, blockNumber) => {
      console.log(`🏁 Position unwound: ${user} ${isLong ? 'LONG' : 'SHORT'} delta=${Number(priceDelta) / 10}%`)

      const key = `${chainId}-${user.toLowerCase()}-${isLong}`
      state.positions.delete(key)
    })

    console.log(`👂 Listening for events on chain ${chainId}`)
  }

  async runLoop(): Promise<void> {
    this.isRunning = true
    console.log(`\n🚀 Keeper bot started - checking every ${CONFIG.CHECK_INTERVAL / 1000}s\n`)

    while (this.isRunning) {
      for (const chainId of CONFIG.ACTIVE_CHAINS) {
        await this.checkAndUnwindPositions(chainId)
      }

      await new Promise(resolve => setTimeout(resolve, CONFIG.CHECK_INTERVAL))
    }
  }

  stop(): void {
    this.isRunning = false
    console.log('🛑 Keeper bot stopping...')
  }

  async start(): Promise<void> {
    await this.initialize()

    for (const chainId of CONFIG.ACTIVE_CHAINS) {
      await this.loadHistoricalPositions(chainId)
      await this.listenForNewPositions(chainId)
    }

    await this.runLoop()
  }
}

// ============== MAIN ==============
const keeper = new QuidKeeper()

// Handle graceful shutdown
process.on('SIGINT', () => {
  keeper.stop()
  process.exit(0)
})

process.on('SIGTERM', () => {
  keeper.stop()
  process.exit(0)
})

// Start the keeper
keeper.start().catch(console.error)
