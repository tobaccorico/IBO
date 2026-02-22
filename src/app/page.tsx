'use client'

import { useState, useCallback, useEffect, useMemo } from 'react'
import { ethers } from 'ethers'
import { CHAINS, CONTRACTS, STABLES, ENABLED_CHAINS, type StableToken } from '@/lib/chains'

declare global {
  interface Window {
    ethereum?: any
  }
}

const formatNumber = (n: number, decimals = 4) => {
  if (n === 0) return '0'
  if (n < 0.0001) return '<0.0001'
  return n.toLocaleString('en-US', { maximumFractionDigits: decimals })
}

const shortenAddress = (addr: string) => addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : ''

const formatUnits = (value: string, decimals: number) => {
  const str = value.padStart(decimals + 1, '0')
  const whole = str.slice(0, -decimals) || '0'
  const frac = str.slice(-decimals)
  return `${whole}.${frac}`
}

// ABI Interface
const iface = new ethers.Interface([
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function mint(address pledge, uint256 amount, address token, uint256 when) returns (uint256)',
  'function currentMonth() view returns (uint256)',
  'function deposit(uint256 amount) payable',
  'function withdraw(uint256 amount)',
  // Aux functions
  'function swap(address token, bool forETH, uint256 amount, uint256 waitable) payable returns (uint256)',
  'function getTWAP(uint32 period) view returns (uint256)',
  'function redeem(uint256 amount)',
  // Basket functions
  'function totalMatureBalanceOf(address owner) view returns (uint256)',
  // Aux leverage functions
  'function leverETH(uint256 amount) payable',
  'function leverUSD(uint256 amount, address token)',
  // Aux metrics - total USD in basket and accumulated yield
  'function get_metrics(bool force) returns (uint256, uint256)',
  'function getAverageYield() view returns (uint256)',
  'function get_deposits() returns (uint256[13])',
  'function getFee(address token) view returns (uint256)',
  // VogueCore - POOLED_ETH
  'function POOLED_ETH() view returns (uint256)',
  // Vogue metrics
  'function totalShares() view returns (uint256)',
  'function YIELD() view returns (uint256)',
  'function ETH_FEES() view returns (uint256)',
  'function USD_FEES() view returns (uint256)',
  // Vogue self-managed LP
  'function outOfRange(uint256 amount, address token, int24 distance, int24 range) payable returns (uint256)',
  'function pull(uint256 id, int256 percent, address token)',
  'function positions(address user, uint256 index) view returns (uint256)',
  'function selfManaged(uint256 id) view returns (uint256 created, address owner, int24 lower, int24 upper, int256 liq)',
  'function autoManaged(address user) view returns (uint256 pooled_eth, uint256 fees_eth, uint256 fees_usd, uint256 usd_owed)',
])

const encodeBalanceOf = (address: string) => iface.encodeFunctionData('balanceOf', [address])
const encodeAllowance = (owner: string, spender: string) => iface.encodeFunctionData('allowance', [owner, spender])
const encodeApprove = (spender: string, amount: bigint) => iface.encodeFunctionData('approve', [spender, amount])
const encodeCurrentMonth = () => iface.encodeFunctionData('currentMonth', [])
const encodeMint = (pledge: string, amount: bigint, token: string, when: number) =>
  iface.encodeFunctionData('mint', [pledge, amount, token, when])
const encodeDeposit = (amount: bigint) => iface.encodeFunctionData('deposit', [amount])
const encodeWithdraw = (amount: bigint) => iface.encodeFunctionData('withdraw', [amount])
const encodeSwap = (token: string, forETH: boolean, amount: bigint, waitable: number = 5) =>
  iface.encodeFunctionData('swap', [token, forETH, amount, waitable])
const encodeGetTWAP = (period: number) => iface.encodeFunctionData('getTWAP', [period])
const encodeRedeem = (amount: bigint) => iface.encodeFunctionData('redeem', [amount])
const encodeTotalMatureBalanceOf = (owner: string) => iface.encodeFunctionData('totalMatureBalanceOf', [owner])
const encodePooledETH = () => iface.encodeFunctionData('POOLED_ETH', [])
const encodeLeverETH = (amount: bigint) => iface.encodeFunctionData('leverETH', [amount])
const encodeLeverUSD = (amount: bigint, token: string) => iface.encodeFunctionData('leverUSD', [amount, token])
// Metrics functions
const encodeGetMetrics = (force: boolean) => iface.encodeFunctionData('get_metrics', [force])
const encodeGetAverageYield = () => iface.encodeFunctionData('getAverageYield', [])
const encodeGetDeposits = () => iface.encodeFunctionData('get_deposits', [])
const encodeGetFee = (token: string) => iface.encodeFunctionData('getFee', [token])
const encodeTotalShares = () => iface.encodeFunctionData('totalShares', [])
const encodeYield = () => iface.encodeFunctionData('YIELD', [])
const encodeETHFees = () => iface.encodeFunctionData('ETH_FEES', [])
const encodeUSDFees = () => iface.encodeFunctionData('USD_FEES', [])
// Vogue self-managed LP
const encodeOutOfRange = (amount: bigint, token: string, distance: number, range: number) =>
  iface.encodeFunctionData('outOfRange', [amount, token, distance, range])
const encodePull = (id: bigint, percent: number, token: string) =>
  iface.encodeFunctionData('pull', [id, percent, token])
const encodePositions = (user: string, index: number) =>
  iface.encodeFunctionData('positions', [user, index])
const encodeSelfManaged = (id: bigint) =>
  iface.encodeFunctionData('selfManaged', [id])
const encodeAutoManaged = (user: string) =>
  iface.encodeFunctionData('autoManaged', [user])

// ============== HOOK (Prediction Market) Interface ==============
// Keeper/delegate address — auto-set on every placeOrder so keeper can batchReveal on behalf of users
const HOOK_DELEGATE = '0x89CA5f6Af99A6106d0148a8839E153BB02010ef0'

const hookIface = new ethers.Interface([
  'function placeOrder(uint8 side, uint256 capital, bool autoRollover, bytes32 commitHash, address delegate)',
  'function sellPosition(uint8 side, uint256 tokensToSell)',
  'function batchReveal(address user, uint8 side, tuple(uint256 confidence, bytes32 salt)[] reveals)',
  'function recommit(uint8 side, bytes32 newCommitHash)',
  'function settleAssertion()',
  'function calculateWeights(address[] users, uint8[] sides)',
  'function pushPayouts(address[] users, uint8[] sides)',
  'function burnAccumulatedFees()',
  'function getMarket() view returns (tuple(uint256 marketId, uint8 numSides, uint256 startTime, uint256 roundStartTime, int128 b, uint32 roundNumber, bool resolved, uint8 winningSide, uint256 resolutionTimestamp, uint256 totalCapital, uint32 positionsTotal, uint32 positionsRevealed, uint32 positionsPaidOut, uint256 totalWinnerCapital, uint256 totalLoserCapital, uint256 totalWinnerWeight, uint256 totalLoserWeight, bool weightsComplete, bool payoutsComplete, bool assertionPending, int128[12] q, uint256[12] capitalPerSide))',
  'function getPosition(address user, uint8 side) view returns (tuple(address user, uint8 side, uint256 totalCapital, uint256 totalTokens, bytes32 commitmentHash, uint256 entryTimestamp, uint32 lastRound, bool revealed, uint256 revealedConfidence, uint256 weight, bool paidOut, bool autoRollover, address delegate))',
  'function getAllPrices() view returns (uint256[])',
  'function getCapitalPerSide() view returns (uint256[12])',
  'function getRoundStartTime() view returns (uint40)',
  'function getMarketCapital() view returns (uint256)',
  'function disputeFrozen() view returns (bool)',
  'function accumulatedFees() view returns (uint256)',
])
const encodeGetMarket = () => hookIface.encodeFunctionData('getMarket', [])
const encodeGetPosition = (user: string, side: number) => hookIface.encodeFunctionData('getPosition', [user, side])
const encodeGetAllPrices = () => hookIface.encodeFunctionData('getAllPrices', [])
const encodeGetCapitalPerSide = () => hookIface.encodeFunctionData('getCapitalPerSide', [])
const encodeHookPlaceOrder = (side: number, capital: bigint, autoRollover: boolean, commitHash: string) =>
  hookIface.encodeFunctionData('placeOrder', [side, capital, autoRollover, commitHash, HOOK_DELEGATE])
const encodeHookSell = (side: number, tokens: bigint) =>
  hookIface.encodeFunctionData('sellPosition', [side, tokens])
const encodeHookBatchReveal = (user: string, side: number, reveals: { confidence: number; salt: string }[]) =>
  hookIface.encodeFunctionData('batchReveal', [user, side, reveals.map(r => ({ confidence: r.confidence, salt: r.salt }))])
const encodeHookRecommit = (side: number, newCommitHash: string) =>
  hookIface.encodeFunctionData('recommit', [side, newCommitHash])
const encodeHookSettle = () =>
  hookIface.encodeFunctionData('settleAssertion', [])
const encodeDisputeFrozen = () => hookIface.encodeFunctionData('disputeFrozen', [])

// Generate commitment hash: keccak256(abi.encodePacked(confidence, salt))
const generateCommitHash = (confidence: number, salt: string): string => {
  const packed = ethers.solidityPacked(['uint256', 'bytes32'], [confidence, salt])
  return ethers.keccak256(packed)
}
const generateSalt = (): string => ethers.hexlify(ethers.randomBytes(32))

// Retrieve stored confidence entries from localStorage for a given position
const getStoredConfidences = (chainId: number, mktId: number, side: number, user: string): { confidence: number; salt: string; commitHash: string }[] => {
  try {
    const key = `hook-conf-${chainId}-${mktId}-${side}-${user}`
    const raw = localStorage.getItem(key)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) return parsed
    if (parsed.confidence && parsed.salt) return [parsed] // legacy single entry
    return []
  } catch { return [] }
}

// Compute capital-weighted average confidence from stored entries
// Since we don't store per-entry capital, we use a simple average
const getAverageStoredConfidence = (entries: { confidence: number }[]): number | null => {
  if (entries.length === 0) return null
  const sum = entries.reduce((acc, e) => acc + e.confidence, 0)
  return sum / entries.length
}

// Estimate expected payout if this side wins
// Formula: capital + (capital / capitalOnMySide) × capitalOnOtherSides
// Adjusted by confidence multiplier: (myConfidence / neutralConfidence)
// This is a proportional estimate assuming average confidence distribution
const estimateExpectedPayout = (
  myCapital: number, mySideCapital: number, totalMarketCapital: number,
  myConfidence: number | null, neutralConfidence: number = 5000
): { base: number; adjusted: number | null } => {
  if (mySideCapital <= 0 || totalMarketCapital <= 0) return { base: myCapital, adjusted: null }
  const otherSidesCapital = totalMarketCapital - mySideCapital
  const myShare = myCapital / mySideCapital
  const basePayout = myCapital + myShare * otherSidesCapital
  if (myConfidence === null || myConfidence <= 0) return { base: basePayout, adjusted: null }
  // Confidence multiplier: >50% = above average weight, <50% = below
  const confMultiplier = myConfidence / neutralConfidence
  const adjustedPayout = myCapital + myShare * otherSidesCapital * confMultiplier
  return { base: basePayout, adjusted: adjustedPayout }
}

// USDT addresses - requires allowance reset to 0 before setting new allowance
const USDT_ADDRESSES: Record<number, string> = {
  1: '0xdAC17F958D2ee523a2206206994597C13D831ec7',      // Ethereum
  137: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',    // Polygon
  8453: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2',   // Base
  42161: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', // Arbitrum
  130: '0x9151434b16b9763660705744891fA906F660EcC5',    // Unichain
}

// Helper to check if token is USDT
const isUSDT = (tokenAddress: string, chainId: number): boolean => {
  const usdtAddr = USDT_ADDRESSES[chainId]
  return usdtAddr ? tokenAddress.toLowerCase() === usdtAddr.toLowerCase() : false
}

// Helper for USDT-safe approval - USDT requires reset to 0 before new allowance
const doApproval = async (
  tokenAddress: string,
  spender: string,
  amount: bigint,
  ownerAddress: string,
  chainId: number,
  setStatus?: (s: string) => void
): Promise<boolean> => {
  const maxUint256 = BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')

  // Check current allowance
  const allowanceResult = await window.ethereum.request({
    method: 'eth_call',
    params: [{ to: tokenAddress, data: encodeAllowance(ownerAddress, spender) }, 'latest'],
  })
  const currentAllowance = BigInt(allowanceResult)

  // If allowance is sufficient, no need to approve
  if (currentAllowance >= amount) {
    return true
  }

  // USDT special case: must reset to 0 first if current allowance > 0
  if (isUSDT(tokenAddress, chainId) && currentAllowance > 0n) {
    setStatus?.('Resetting USDT allowance to 0...')
    const resetTx = await window.ethereum.request({
      method: 'eth_sendTransaction',
      params: [{
        from: ownerAddress,
        to: tokenAddress,
        data: encodeApprove(spender, 0n),
      }],
    })
    // Wait for reset tx
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 1000))
      const receipt = await window.ethereum.request({
        method: 'eth_getTransactionReceipt',
        params: [resetTx],
      })
      if (receipt?.status === '0x1') break
      if (receipt?.status === '0x0') throw new Error('USDT allowance reset failed')
    }
  }

  // Now set the new allowance
  setStatus?.('Approving token...')
  const approveTx = await window.ethereum.request({
    method: 'eth_sendTransaction',
    params: [{
      from: ownerAddress,
      to: tokenAddress,
      data: encodeApprove(spender, maxUint256),
    }],
  })

  // Wait for approval
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 1000))
    const receipt = await window.ethereum.request({
      method: 'eth_getTransactionReceipt',
      params: [approveTx],
    })
    if (receipt?.status === '0x1') return true
    if (receipt?.status === '0x0') throw new Error('Approval failed')
  }
  throw new Error('Approval timed out')
}

export default function QuidApp() {
  const [chainId, setChainId] = useState(42161) // Default to Arbitrum
  const [protocol, setProtocol] = useState<'v3' | 'v4'>('v4')
  const [activeTab, setActiveTab] = useState('mint')
  const [connected, setConnected] = useState(false)
  const [address, setAddress] = useState('')
  const [ethBalance, setEthBalance] = useState('0')
  const [wethBalance, setWethBalance] = useState('0')
  const [showChainMenu, setShowChainMenu] = useState(false)

  // Mint state
  const [mintAmount, setMintAmount] = useState('')
  const [selectedToken, setSelectedToken] = useState<StableToken | null>(null)
  const [maturityMonths, setMaturityMonths] = useState(12)
  const [currentMonth, setCurrentMonth] = useState(0)

  // Token balances and allowances
  const [tokenBalances, setTokenBalances] = useState<Record<string, string>>({})
  const [tokenAllowances, setTokenAllowances] = useState<Record<string, string>>({})
  const [loadingBalances, setLoadingBalances] = useState(false)

  // Transaction state
  const [isLoading, setIsLoading] = useState(false)
  const [txStatus, setTxStatus] = useState<string | null>(null)
  const [txHash, setTxHash] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [txMutex, setTxMutex] = useState(false)

  // Deposit/Withdraw state
  const [depositAmount, setDepositAmount] = useState('')
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const [depositSubTab, setDepositSubTab] = useState<'auto' | 'selfManaged'>('auto')

  // Self-managed LP state (Vogue.outOfRange)
  const [oorAmount, setOorAmount] = useState('')
  const [oorToken, setOorToken] = useState<'eth' | 'usd'>('eth')
  const [oorDistance, setOorDistance] = useState(5) // UI shows %, maps to distance * 100 ticks
  const [oorRange, setOorRange] = useState(2) // UI shows %, maps to range * 100 ticks
  const [oorStable, setOorStable] = useState<StableToken | null>(null) // selected stablecoin for USD side
  const [selfManagedPositions, setSelfManagedPositions] = useState<
    { id: bigint; lower: number; upper: number; liq: bigint }[]
  >([])
  const [pullPercent, setPullPercent] = useState(100)
  const [pullToken, setPullToken] = useState<string>('0x0000000000000000000000000000000000000000') // ETH default

  // Auto-managed LP info
  const [autoManagedInfo, setAutoManagedInfo] = useState<{
    pooled: number; feesEth: number; feesUsd: number; usdOwed: number
  } | null>(null)

  // QD token state
  const [qdBalance, setQdBalance] = useState('0')
  const [redeemAmount, setRedeemAmount] = useState('')
  const [matureQdBalance, setMatureQdBalance] = useState('0') // For future redeem gating
  // (haircut vote UI removed — vote still in contract for depeg pricing)

  // UI state
  const [showAboutModal, setShowAboutModal] = useState(false)
  const [showWaiver, setShowWaiver] = useState(false)
  const [waiverAccepted, setWaiverAccepted] = useState(false)
  const [waiverChecked, setWaiverChecked] = useState(false)

  // Hook (Prediction Market) state
  const MARKET_ID = 1 // canonical depeg market
  const [hookMarket, setHookMarket] = useState<any>(null)
  const [hookPrices, setHookPrices] = useState<number[]>([])
  const [hookCapitals, setHookCapitals] = useState<number[]>([])
  const [hookPositions, setHookPositions] = useState<Record<number, any>>({}) // side → position
  const [hookOrderSide, setHookOrderSide] = useState(0) // 0 = "none depegs"
  const [hookOrderAmount, setHookOrderAmount] = useState('')
  const [hookConfidence, setHookConfidence] = useState(5000) // 50% default
  const [hookAutoRollover, setHookAutoRollover] = useState(false)
  const [hookSalt, setHookSalt] = useState('')
  const [hookCommitHash, setHookCommitHash] = useState('')
  const [hookSellTokens, setHookSellTokens] = useState('')
  const [hookSubTab, setHookSubTab] = useState<'overview' | 'order' | 'position'>('overview')
  const [hookLoading, setHookLoading] = useState(false)
  const [hookFrozen, setHookFrozen] = useState(false)

  // Swap state
  const [swapDirection, setSwapDirection] = useState<'toETH' | 'toUSD'>('toETH')
  const [swapSpeed, setSwapSpeed] = useState<'instant' | 'wait'>('instant')
  const [swapAmount, setSwapAmount] = useState('')
  const [swapToken, setSwapToken] = useState<StableToken | null>(null)
  const [swapAllowances, setSwapAllowances] = useState<Record<string, string>>({})
  const [estimatedOutput, setEstimatedOutput] = useState('0')
  const [swapOutputMode, setSwapOutputMode] = useState<'quid' | 'token'>('quid') // ETH→USD output: QUID (free) or specific token (has fee)
  const [swapFee, setSwapFee] = useState(0) // Fee in basis points for specific token swaps

  // Protocol metrics (fetched from contracts)
  const [ethPrice, setEthPrice] = useState(0)
  const [basketMetrics, setBasketMetrics] = useState({ total: 0, yield: 0, avgYield: 0 }) // USD in basket
  const [ethMetrics, setEthMetrics] = useState({ totalShares: 0, ethFees: 0, usdFees: 0 }) // ETH LP metrics
  const [pooledETH, setPooledETH] = useState(0) // Total ETH deposited by LPs
  const [auxDeposits, setAuxDeposits] = useState<number[]>([]) // Per-stablecoin deposits from get_deposits
  const [showDepositsBreakdown, setShowDepositsBreakdown] = useState(false)

  const chain = CHAINS[chainId]
  const contracts = CONTRACTS[chainId]
  const stables = STABLES[chainId] || []

  // Reset swap speed to instant when switching to chain without leverage
  useEffect(() => {
    if (!chain.hasLeverage && swapSpeed === 'wait') {
      setSwapSpeed('instant')
    }
  }, [chainId, chain.hasLeverage, swapSpeed])

  // Reset swap output mode when direction changes
  useEffect(() => {
    if (swapDirection === 'toUSD') {
      setSwapOutputMode('quid') // Default to QUID (free) for ETH→USD
      setSwapFee(0)
    } else {
      setSwapOutputMode('token') // For USD→ETH, always token mode
    }
  }, [swapDirection])

  // Get tokens with non-zero balance
  const tokensWithBalance = useMemo(() => {
    return stables.filter((t) => {
      const bal = tokenBalances[t.address]
      return bal && BigInt(bal) > 0n
    })
  }, [stables, tokenBalances])

  // Combined ETH + WETH balance for deposits/swaps
  const combinedEthBalance = useMemo(() => {
    return (parseFloat(ethBalance) || 0) + (parseFloat(wethBalance) || 0)
  }, [ethBalance, wethBalance])

  // Fetch all token balances
  const fetchBalances = useCallback(async () => {
    if (!address || !window.ethereum) return
    setLoadingBalances(true)

    const balances: Record<string, string> = {}
    const allowances: Record<string, string> = {}

    // Fetch each token balance individually — one bad address must not kill everything
    for (const token of stables) {
      try {
        const balResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: token.address, data: encodeBalanceOf(address) }, 'latest'],
        })
        balances[token.address] = BigInt(balResult).toString()

        // Get allowance for AUX contract (not basket - Aux.deposit does the transferFrom)
        if (contracts.aux !== '0x0000000000000000000000000000000000000000') {
          const allowResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: token.address, data: encodeAllowance(address, contracts.aux) }, 'latest'],
          })
          allowances[token.address] = BigInt(allowResult).toString()
        }
      } catch (e) {
        console.log(`Could not fetch balance for ${token.symbol} (${token.address}):`, e)
        balances[token.address] = '0'
      }
    }

    setTokenBalances(balances)
    setTokenAllowances(allowances)

    // Auto-select first token with balance
    const firstWithBalance = stables.find((t) => BigInt(balances[t.address] || 0) > 0n)
    if (firstWithBalance && !selectedToken) {
      setSelectedToken(firstWithBalance)
    }

    // Fetch current month from basket
    if (contracts.basket !== '0x0000000000000000000000000000000000000000') {
      try {
        const monthResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: contracts.basket, data: encodeCurrentMonth() }, 'latest'],
        })
        setCurrentMonth(Number(BigInt(monthResult)))
      } catch {
        console.log('Could not fetch currentMonth')
      }

      // Fetch QD balance
      try {
        const qdResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: contracts.basket, data: encodeBalanceOf(address) }, 'latest'],
        })
        const qdBal = BigInt(qdResult)
        setQdBalance(qdBal.toString())
        console.log('QD Balance:', qdBal.toString())
      } catch (e) {
        console.log('Could not fetch QD balance:', e)
      }

      // Fetch mature QD balance (redeemable)
      try {
        const matureResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: contracts.basket, data: encodeTotalMatureBalanceOf(address) }, 'latest'],
        })
        setMatureQdBalance(BigInt(matureResult).toString())
      } catch (e) {
        console.log('Could not fetch mature QD balance:', e)
      }
    }

    // Fetch raw ETH balance
    try {
      const ethBal = await window.ethereum.request({
        method: 'eth_getBalance',
        params: [address, 'latest'],
      })
      setEthBalance((parseInt(ethBal, 16) / 1e18).toFixed(6))
    } catch (e) {
      console.log('Could not fetch ETH balance:', e)
    }

    // Fetch WETH balance
    if (contracts.weth && contracts.weth !== '0x0000000000000000000000000000000000000000') {
      try {
        const wethResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: contracts.weth, data: encodeBalanceOf(address) }, 'latest'],
        })
        const wethBal = BigInt(wethResult)
        setWethBalance((Number(wethBal) / 1e18).toFixed(6))
        console.log('WETH Balance:', Number(wethBal) / 1e18)
      } catch (e) {
        console.log('Could not fetch WETH balance:', e)
      }
    }

    setLoadingBalances(false)
  }, [address, stables, contracts.aux, contracts.basket, contracts.weth, selectedToken])

  // Fetch ETH price and TVL from contracts
  useEffect(() => {
    const fetchMetrics = async () => {
      if (!window.ethereum) return

      let price = 0

      // Fetch ETH price from Aux.getTWAP(1800) - returns price in WAD (1e18)
      if (contracts.aux && contracts.aux !== '0x0000000000000000000000000000000000000000') {
        try {
          const twapResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.aux, data: encodeGetTWAP(1800) }, 'latest'],
          })
          price = Number(BigInt(twapResult)) / 1e18
          setEthPrice(price)
        } catch (e) {
          console.log('Could not fetch TWAP price:', e)
        }

        // Fetch Basket metrics via get_metrics(false) → returns (total, yield)
        try {
          const metricsResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.aux, data: encodeGetMetrics(false) }, 'latest'],
          })
          const total = BigInt('0x' + metricsResult.slice(2, 66))
          const yieldVal = BigInt('0x' + metricsResult.slice(66, 130))
          const auxTvl = Number(total) / 1e18
          const yieldUsd = Number(yieldVal) / 1e18

          let avgYield = 0
          try {
            const yieldResult = await window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.aux, data: encodeGetAverageYield() }, 'latest'],
            })
            avgYield = Number(BigInt(yieldResult)) / 1e16 // WAD basis → %
          } catch (e) {
            console.log('Could not fetch average yield:', e)
          }

          setBasketMetrics({ total: auxTvl, yield: yieldUsd, avgYield })
        } catch (e) {
          console.log('Could not fetch Basket metrics:', e)
        }

        // Fetch per-stablecoin deposits breakdown
        try {
          const depositsResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.aux, data: encodeGetDeposits() }, 'latest'],
          })
          const decoded = iface.decodeFunctionResult('get_deposits', depositsResult)
          const arr = decoded[0] as bigint[]
          setAuxDeposits(arr.map((v: bigint) => Number(v) / 1e18))
        } catch (e) {
          console.log('Could not fetch deposits breakdown:', e)
        }
      }

      // Fetch Vogue pooled ETH (total deposited by LPs)
      if (contracts.vogueCore && contracts.vogueCore !== '0x0000000000000000000000000000000000000000') {
        try {
          const pooledResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.vogueCore, data: encodePooledETH() }, 'latest'],
          })
          setPooledETH(Number(BigInt(pooledResult)) / 1e18)
        } catch (e) {
          console.log('Could not fetch VogueCore POOLED_ETH:', e)
        }
      }

      // Fetch Vogue ETH and USD fees
      if (contracts.vogue && contracts.vogue !== '0x0000000000000000000000000000000000000000') {
        try {
          const [sharesResult, ethFeesResult, usdFeesResult] = await Promise.all([
            window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.vogue, data: encodeTotalShares() }, 'latest'],
            }),
            window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.vogue, data: encodeETHFees() }, 'latest'],
            }),
            window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.vogue, data: encodeUSDFees() }, 'latest'],
            }),
          ])
          setEthMetrics({
            totalShares: Number(BigInt(sharesResult)) / 1e18,
            ethFees: Number(BigInt(ethFeesResult)) / 1e18,
            usdFees: Number(BigInt(usdFeesResult)) / 1e18,
          })
        } catch (e) {
          console.log('Could not fetch Vogue fee metrics:', e)
        }
      }
    }
    fetchMetrics()
  }, [chainId, contracts.vogueCore, contracts.vogue, contracts.aux])

  // Connect wallet
  const connectWallet = useCallback(async () => {
    setIsLoading(true)
    setError(null)
    try {
      if (window.ethereum) {
        const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })
        if (accounts[0]) {
          setAddress(accounts[0])
          setConnected(true)

          const currentChainId = await window.ethereum.request({ method: 'eth_chainId' })
          const numericChainId = parseInt(currentChainId, 16)
          if (CHAINS[numericChainId]?.enabled) {
            setChainId(numericChainId)
          } else {
            // MetaMask is on a disabled chain — actually switch it to Arbitrum
            try {
              await window.ethereum.request({
                method: 'wallet_switchEthereumChain',
                params: [{ chainId: CHAINS[42161].hex }],
              })
            } catch (switchErr: any) {
              // If chain not added, try to add it
              if (switchErr.code === 4902) {
                try {
                  await window.ethereum.request({
                    method: 'wallet_addEthereumChain',
                    params: [{
                      chainId: CHAINS[42161].hex,
                      chainName: 'Arbitrum One',
                      nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
                      rpcUrls: ['https://arb1.arbitrum.io/rpc'],
                      blockExplorerUrls: ['https://arbiscan.io'],
                    }],
                  })
                } catch {
                  console.log('Could not add Arbitrum network')
                }
              }
            }
            setChainId(42161)
          }

          // Fetch ETH balance AFTER chain is settled
          const balance = await window.ethereum.request({
            method: 'eth_getBalance',
            params: [accounts[0], 'latest'],
          })
          setEthBalance((parseInt(balance, 16) / 1e18).toFixed(4))
        }
      } else {
        setError('Please install MetaMask or another Web3 wallet')
      }
    } catch (err: any) {
      setError(err.message || 'Failed to connect wallet')
    } finally {
      setIsLoading(false)
    }
  }, [])

  // Fetch balances when connected or chain changes
  useEffect(() => {
    if (connected && address) {
      fetchBalances()
    }
  }, [connected, address, chainId, fetchBalances])

  // Listen for account/chain changes
  useEffect(() => {
    if (window.ethereum) {
      const handleAccountsChanged = (accounts: string[]) => {
        if (accounts[0]) {
          setAddress(accounts[0])
          setConnected(true)
        } else {
          setAddress('')
          setConnected(false)
          setTokenBalances({})
          setTokenAllowances({})
        }
      }

      const handleChainChanged = async (newChainId: string) => {
        const numericChainId = parseInt(newChainId, 16)
        if (CHAINS[numericChainId]?.enabled) {
          setChainId(numericChainId)
          setSelectedToken(null)
          setTokenBalances({})
          setTokenAllowances({})
        } else {
          // User switched to a disabled chain — switch MetaMask back to Arbitrum
          try {
            await window.ethereum.request({
              method: 'wallet_switchEthereumChain',
              params: [{ chainId: CHAINS[42161].hex }],
            })
          } catch {
            console.log('Could not auto-switch back to Arbitrum')
          }
        }
      }

      window.ethereum.on('accountsChanged', handleAccountsChanged)
      window.ethereum.on('chainChanged', handleChainChanged)

      return () => {
        window.ethereum.removeListener('accountsChanged', handleAccountsChanged)
        window.ethereum.removeListener('chainChanged', handleChainChanged)
      }
    }
  }, [])

  // Switch chain
  const switchChain = useCallback(async (newChainId: number) => {
    try {
      if (window.ethereum) {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: CHAINS[newChainId].hex }],
        })
        setChainId(newChainId)
        setShowChainMenu(false)
        setSelectedToken(null)
      }
    } catch (err: any) {
      if (err.code === 4902) {
        setError('Please add this network to your wallet')
      }
    }
  }, [])

  // Mint QD tokens (with auto-approval to AUX contract)
  const mintTokens = useCallback(async () => {
    if (!selectedToken || !mintAmount || !contracts.basket) return
    if (txMutex) return

    // Require waiver acceptance before first mint
    if (!waiverAccepted) {
      setShowWaiver(true)
      return
    }

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus(null)

    const targetMonth = currentMonth + 1 + maturityMonths

    // === DEBUG LOGGING ===
    console.log('=== MINT DEBUG ===')
    console.log('Token:', selectedToken.symbol, selectedToken.address)
    console.log('Amount (display):', mintAmount)
    console.log('Token decimals:', selectedToken.decimals)
    console.log('Maturity month:', targetMonth, '(current:', currentMonth, '+ 1 +', maturityMonths, ')')
    console.log('User address:', address)
    console.log('Aux contract:', contracts.aux)
    console.log('Basket contract:', contracts.basket)

    try {
      const amount = ethers.parseUnits(mintAmount, selectedToken.decimals)
      console.log('Amount (raw BigInt):', amount.toString())

      // Check and do approval for AUX (not basket - Aux.deposit does the transferFrom)
      console.log('Checking/doing approval for Aux contract...')
      await doApproval(
        selectedToken.address,
        contracts.aux,
        amount,
        address,
        chainId,
        setTxStatus
      )
      console.log('Approval complete!')

      setTokenAllowances(prev => ({
        ...prev,
        [selectedToken.address]: 'max'
      }))

      // Now mint
      setTxStatus('Minting QD tokens...')
      const data = encodeMint(address, amount, selectedToken.address, targetMonth)

      console.log('=== MINT TX ===')
      console.log('To (Basket):', contracts.basket)
      console.log('Mint params:')
      console.log('  pledge:', address)
      console.log('  amount:', amount.toString())
      console.log('  token:', selectedToken.address)
      console.log('  when:', targetMonth)
      console.log('Encoded data:', data)

      const mintTx = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contracts.basket,
          data: data,
        }],
      })

      console.log('Mint tx hash:', mintTx)
      setTxHash(mintTx)
      setTxStatus('Transaction submitted!')
      setMintAmount('')

      // Refresh balances after a delay
      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('Mint error:', err)
      setError(err.message || 'Transaction failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [selectedToken, mintAmount, contracts.basket, contracts.aux, address, currentMonth, maturityMonths, chainId, fetchBalances, txMutex, waiverAccepted])

  // Deposit ETH to LP
  const depositETH = useCallback(async () => {
    if (!depositAmount || !connected) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Depositing ETH...')

    try {
      const contractAddr = protocol === 'v4' ? contracts.vogue : contracts.rover
      const totalWei = ethers.parseEther(depositAmount)
      const rawEthWei = ethers.parseEther(ethBalance)
      const wethWei = ethers.parseEther(wethBalance || '0')

      // Determine how much to send as msg.value vs WETH amount
      let msgValue: bigint
      let wethAmount: bigint

      if (totalWei <= rawEthWei) {
        // Can cover entirely with raw ETH
        msgValue = totalWei
        wethAmount = 0n
      } else if (totalWei <= rawEthWei + wethWei) {
        // Use all raw ETH + some WETH
        msgValue = rawEthWei
        wethAmount = totalWei - rawEthWei
      } else {
        throw new Error('Insufficient ETH + WETH balance')
      }

      console.log('=== DEPOSIT DEBUG ===')
      console.log('Protocol:', protocol)
      console.log('Contract:', contractAddr)
      console.log('Total amount:', depositAmount, 'ETH')
      console.log('Raw ETH (msg.value):', Number(msgValue) / 1e18)
      console.log('WETH amount:', Number(wethAmount) / 1e18)

      // If using WETH, need approval first
      if (wethAmount > 0n) {
        await doApproval(contracts.weth, contractAddr, wethAmount, address, chainId, setTxStatus)
        setTxStatus('Depositing ETH...')
      }

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contractAddr,
          value: '0x' + msgValue.toString(16),
          data: encodeDeposit(wethAmount),
        }],
      })

      console.log('Deposit tx hash:', hash)
      setTxHash(hash)
      setTxStatus('Transaction submitted!')
      setDepositAmount('')

      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('Deposit error:', err)
      setError(err.message || 'Deposit failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [depositAmount, connected, protocol, contracts.vogue, contracts.rover, contracts.weth, address, ethBalance, wethBalance, chainId, txMutex, fetchBalances])

  // Withdraw ETH from LP
  const withdrawETH = useCallback(async () => {
    if (!withdrawAmount || !connected) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Withdrawing ETH...')

    try {
      const contractAddr = protocol === 'v4' ? contracts.vogue : contracts.rover
      const amountWei = ethers.parseEther(withdrawAmount)

      console.log('=== WITHDRAW DEBUG ===')
      console.log('Protocol:', protocol)
      console.log('Contract:', contractAddr)
      console.log('Amount:', withdrawAmount, 'ETH')
      console.log('Amount (wei):', amountWei.toString())

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contractAddr,
          data: encodeWithdraw(amountWei),
        }],
      })

      console.log('Withdraw tx hash:', hash)
      setTxHash(hash)
      setTxStatus('Transaction submitted!')
      setWithdrawAmount('')

      setTimeout(async () => {
        try {
          const balance = await window.ethereum.request({
            method: 'eth_getBalance',
            params: [address, 'latest'],
          })
          setEthBalance((parseInt(balance, 16) / 1e18).toFixed(4))
        } catch {}
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('Withdraw error:', err)
      setError(err.message || 'Withdraw failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [withdrawAmount, connected, protocol, contracts.vogue, contracts.rover, address, txMutex])

  // Fetch self-managed positions from Vogue.positions(address, index)
  const fetchSelfManagedPositions = useCallback(async () => {
    if (!address || !window.ethereum || !contracts.vogue || contracts.vogue === '0x0000000000000000000000000000000000000000') return
    const contractAddr = protocol === 'v4' ? contracts.vogue : contracts.rover
    if (protocol !== 'v4') return // Self-managed only on Vogue (v4)

    const positions: { id: bigint; lower: number; upper: number; liq: bigint }[] = []
    try {
      for (let i = 0; i < 50; i++) { // safety cap
        try {
          const idResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contractAddr, data: encodePositions(address, i) }, 'latest'],
          })
          const posId = BigInt(idResult)
          if (posId === 0n) break

          // Fetch selfManaged struct
          const smResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contractAddr, data: encodeSelfManaged(posId) }, 'latest'],
          })
          const decoded = iface.decodeFunctionResult('selfManaged', smResult)
          const liq = BigInt(decoded[4].toString())
          if (liq > 0n) {
            positions.push({
              id: posId,
              lower: Number(decoded[2]),
              upper: Number(decoded[3]),
              liq,
            })
          }
        } catch { break } // Array out of bounds = no more positions
      }
    } catch (e) {
      console.log('Error fetching self-managed positions:', e)
    }
    setSelfManagedPositions(positions)
  }, [address, contracts.vogue, contracts.rover, protocol])

  // Fetch auto-managed LP info
  const fetchAutoManagedInfo = useCallback(async () => {
    if (!address || !window.ethereum || protocol !== 'v4') return
    const contractAddr = contracts.vogue
    if (!contractAddr || contractAddr === '0x0000000000000000000000000000000000000000') return
    try {
      const result = await window.ethereum.request({
        method: 'eth_call',
        params: [{ to: contractAddr, data: encodeAutoManaged(address) }, 'latest'],
      })
      const decoded = iface.decodeFunctionResult('autoManaged', result)
      setAutoManagedInfo({
        pooled: Number(BigInt(decoded[0].toString())) / 1e18,
        feesEth: Number(BigInt(decoded[1].toString())) / 1e18,
        feesUsd: Number(BigInt(decoded[2].toString())) / 1e18,
        usdOwed: Number(BigInt(decoded[3].toString())) / 1e18,
      })
    } catch (e) {
      console.log('Could not fetch autoManaged info:', e)
    }
  }, [address, contracts.vogue, protocol])

  // Fetch LP data when deposit/withdraw tabs are active
  useEffect(() => {
    if ((activeTab === 'deposit' || activeTab === 'withdraw') && connected && address) {
      fetchSelfManagedPositions()
      fetchAutoManagedInfo()
    }
  }, [activeTab, connected, address, fetchSelfManagedPositions, fetchAutoManagedInfo])

  // Open out-of-range self-managed position via Vogue.outOfRange
  const openOutOfRange = useCallback(async () => {
    if (!oorAmount || !connected || protocol !== 'v4') return
    if (txMutex) return
    const contractAddr = contracts.vogue
    if (!contractAddr || contractAddr === '0x0000000000000000000000000000000000000000') return

    setTxMutex(true); setIsLoading(true); setError(null); setTxHash(null)
    setTxStatus('Opening out-of-range position...')

    try {
      const distanceTicks = oorDistance * 100 // UI% → tick distance (e.g. 5% → 500)
      const rangeTicks = oorRange * 100       // UI% → tick range (e.g. 2% → 200)

      let msgValue = 0n
      let amount: bigint
      let tokenAddr: string

      if (oorToken === 'eth') {
        tokenAddr = '0x0000000000000000000000000000000000000000'
        const totalWei = ethers.parseEther(oorAmount)
        const rawEthWei = ethers.parseEther(ethBalance)
        const wethWei = ethers.parseEther(wethBalance || '0')

        if (totalWei <= rawEthWei) {
          msgValue = totalWei; amount = 0n
        } else if (totalWei <= rawEthWei + wethWei) {
          msgValue = rawEthWei; amount = totalWei - rawEthWei
        } else {
          throw new Error('Insufficient ETH + WETH balance')
        }
        // If using WETH portion, approve Vogue
        if (amount > 0n) {
          await doApproval(contracts.weth, contractAddr, amount, address, chainId, setTxStatus)
          setTxStatus('Opening out-of-range position...')
        }
        amount = amount // WETH param (Vogue handles ETH via msg.value + WETH via amount)
      } else {
        // USD side - use selected stablecoin
        if (!oorStable) throw new Error('Select a stablecoin')
        tokenAddr = oorStable.address
        amount = ethers.parseUnits(oorAmount, oorStable.decimals)
        await doApproval(oorStable.address, contracts.aux, amount, address, chainId, setTxStatus)
        setTxStatus('Opening out-of-range position...')
        msgValue = 0n
      }

      const data = encodeOutOfRange(amount, tokenAddr, distanceTicks, rangeTicks)
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address, to: contractAddr, data,
          ...(msgValue > 0n ? { value: '0x' + msgValue.toString(16) } : {}),
        }],
      })

      setTxHash(hash); setTxStatus('Position created!')
      setOorAmount('')
      setTimeout(() => { fetchSelfManagedPositions(); fetchBalances(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'OutOfRange failed'); setTxStatus(null)
    } finally { setIsLoading(false); setTxMutex(false) }
  }, [oorAmount, oorToken, oorStable, oorDistance, oorRange, connected, protocol, contracts.vogue, contracts.weth, contracts.aux, address, ethBalance, wethBalance, chainId, txMutex, fetchSelfManagedPositions, fetchBalances])

  // Pull (withdraw) self-managed position via Vogue.pull
  const pullSelfManaged = useCallback(async (posId: bigint) => {
    if (!connected || txMutex) return
    const contractAddr = contracts.vogue
    if (!contractAddr || contractAddr === '0x0000000000000000000000000000000000000000') return

    setTxMutex(true); setIsLoading(true); setError(null); setTxHash(null)
    setTxStatus(`Withdrawing position #${posId}...`)

    try {
      const data = encodePull(posId, pullPercent, pullToken)
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: address, to: contractAddr, data }],
      })
      setTxHash(hash); setTxStatus('Withdrawal submitted!')
      setTimeout(() => { fetchSelfManagedPositions(); fetchBalances(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'Pull failed'); setTxStatus(null)
    } finally { setIsLoading(false); setTxMutex(false) }
  }, [connected, contracts.vogue, address, pullPercent, pullToken, txMutex, fetchSelfManagedPositions, fetchBalances])

  // Redeem QD tokens for stablecoins
  const redeemQD = useCallback(async () => {
    if (!redeemAmount || !connected || !contracts.aux || !contracts.basket) return
    if (BigInt(matureQdBalance) <= 0n) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)

    try {
      const amount = ethers.parseUnits(redeemAmount, 18)

      // Redeem via Aux
      setTxStatus('Redeeming QD tokens...')
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contracts.aux,
          data: encodeRedeem(amount),
        }],
      })

      console.log('Redeem tx hash:', hash)
      setTxHash(hash)
      setTxStatus('Transaction submitted!')
      setRedeemAmount('')

      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('Redeem error:', err)
      setError(err.message || 'Redeem failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [redeemAmount, connected, contracts.aux, contracts.basket, address, txMutex, fetchBalances, matureQdBalance])

  // Swap tokens via Aux.swap
  // forETH = true: USD → ETH (sell stablecoin for ETH)
  // forETH = false: ETH → USD (sell ETH for stablecoin)
  const swapTokens = useCallback(async () => {
    if (!swapAmount || !connected || !contracts.aux) return
    if (txMutex) return

    // For USD→ETH, need a token selected
    if (swapDirection === 'toETH' && !swapToken) return
    // For ETH→USD with token mode, need a token selected
    if (swapDirection === 'toUSD' && swapOutputMode === 'token' && !swapToken) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Preparing swap...')

    try {
      const forETH = swapDirection === 'toETH'
      const waitable = 5 // blocks to wait

      // For ETH→USD, determine the output token (QUID or specific stablecoin)
      const outputToken = swapDirection === 'toUSD' && swapOutputMode === 'quid'
        ? contracts.basket  // QUID address
        : swapToken!.address

      console.log('=== SWAP DEBUG ===')
      console.log('Direction:', swapDirection, '(forETH:', forETH, ')')
      console.log('Token:', swapDirection === 'toUSD' && swapOutputMode === 'quid' ? 'QUID' : swapToken?.symbol, outputToken)
      console.log('Amount:', swapAmount)
      console.log('Output Mode:', swapOutputMode)

      if (forETH) {
        // USD → ETH: User sells stablecoin for ETH
        // amount is stablecoin amount, need to approve Aux first
        const decimals = swapToken!.decimals
        const amount = ethers.parseUnits(swapAmount, decimals)

        // Check/do approval for the stablecoin to Aux (handles USDT reset)
        await doApproval(swapToken!.address, contracts.aux, amount, address, chainId, setTxStatus)

        setTxStatus('Swapping USD → ETH...')
        const swapData = encodeSwap(swapToken!.address, true, amount, waitable)

        const hash = await window.ethereum.request({
          method: 'eth_sendTransaction',
          params: [{
            from: address,
            to: contracts.aux,
            data: swapData,
          }],
        })

        console.log('Swap tx hash:', hash)
        setTxHash(hash)
        setTxStatus('Transaction submitted!')

      } else {
        // ETH → USD: User sells ETH for stablecoin (or QUID)
        // _depositETH combines raw ETH (msg.value) + WETH (amount param)
        const totalWei = ethers.parseEther(swapAmount)
        const rawEthWei = ethers.parseEther(ethBalance)
        const wethWei = ethers.parseEther(wethBalance || '0')

        // Determine how much to send as msg.value vs WETH amount
        let msgValue: bigint
        let wethAmount: bigint

        if (totalWei <= rawEthWei) {
          // Can cover entirely with raw ETH
          msgValue = totalWei
          wethAmount = 0n
        } else if (totalWei <= rawEthWei + wethWei) {
          // Use all raw ETH + some WETH
          msgValue = rawEthWei
          wethAmount = totalWei - rawEthWei
        } else {
          throw new Error('Insufficient ETH + WETH balance')
        }

        console.log('Sending ETH:', Number(msgValue) / 1e18, 'WETH amount:', Number(wethAmount) / 1e18)

        // If using WETH, need approval
        if (wethAmount > 0n) {
          await doApproval(contracts.weth, contracts.aux, wethAmount, address, chainId, setTxStatus)
        }

        setTxStatus(swapOutputMode === 'quid' ? 'Swapping ETH → QUID...' : 'Swapping ETH → USD...')
        // swap(token, forETH=false, amount=wethAmount, waitable)
        const swapData = encodeSwap(outputToken, false, wethAmount, waitable)

        const hash = await window.ethereum.request({
          method: 'eth_sendTransaction',
          params: [{
            from: address,
            to: contracts.aux,
            data: swapData,
            value: '0x' + msgValue.toString(16),
          }],
        })

        console.log('Swap tx hash:', hash)
        setTxHash(hash)
        setTxStatus('Transaction submitted!')
      }

      setSwapAmount('')
      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)

    } catch (err: any) {
      console.error('Swap error:', err)
      setError(err.message || 'Swap failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [swapAmount, swapDirection, swapToken, swapOutputMode, connected, contracts.aux, contracts.weth, contracts.basket, address, ethBalance, wethBalance, chainId, txMutex, fetchBalances])

  // Leverage ETH (go long) via Aux.leverETH - used when swapping ETH with "wait"
  const leverETH = useCallback(async () => {
    if (!swapAmount || !connected || !contracts.aux) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Opening leveraged position...')

    try {
      const totalWei = ethers.parseEther(swapAmount)
      const rawEthWei = ethers.parseEther(ethBalance)
      const wethWei = ethers.parseEther(wethBalance || '0')

      let msgValue: bigint
      let wethAmount: bigint

      if (totalWei <= rawEthWei) {
        msgValue = totalWei
        wethAmount = 0n
      } else if (totalWei <= rawEthWei + wethWei) {
        msgValue = rawEthWei
        wethAmount = totalWei - rawEthWei
      } else {
        throw new Error('Insufficient ETH + WETH balance')
      }

      console.log('=== LEVER ETH DEBUG ===')
      console.log('Total amount:', swapAmount, 'ETH')
      console.log('Raw ETH (msg.value):', Number(msgValue) / 1e18)
      console.log('WETH amount:', Number(wethAmount) / 1e18)

      // If using WETH, need approval to Aux
      if (wethAmount > 0n) {
        await doApproval(contracts.weth, contracts.aux, wethAmount, address, chainId, setTxStatus)
        setTxStatus('Opening leveraged position...')
      }

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contracts.aux,
          value: '0x' + msgValue.toString(16),
          data: encodeLeverETH(wethAmount),
        }],
      })

      console.log('LeverETH tx hash:', hash)
      setTxHash(hash)
      setTxStatus('Transaction submitted!')
      setSwapAmount('')

      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('LeverETH error:', err)
      setError(err.message || 'Leverage ETH failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [swapAmount, connected, contracts.aux, contracts.weth, address, ethBalance, wethBalance, chainId, txMutex, fetchBalances])

  // Leverage USD (go short) via Aux.leverUSD - used when swapping USD with "wait"
  const leverUSD = useCallback(async () => {
    if (!swapAmount || !connected || !contracts.aux || !swapToken) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Opening leveraged position...')

    try {
      const decimals = swapToken.decimals
      const amount = ethers.parseUnits(swapAmount, decimals)

      console.log('=== LEVER USD DEBUG ===')
      console.log('Token:', swapToken.symbol)
      console.log('Amount:', swapAmount)

      // Check/do approval for the stablecoin to Aux (handles USDT reset)
      await doApproval(swapToken.address, contracts.aux, amount, address, chainId, setTxStatus)
      setTxStatus('Opening leveraged position...')

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: contracts.aux,
          data: encodeLeverUSD(amount, swapToken.address),
        }],
      })

      console.log('LeverUSD tx hash:', hash)
      setTxHash(hash)
      setTxStatus('Transaction submitted!')
      setSwapAmount('')

      setTimeout(() => {
        fetchBalances()
        setTxStatus(null)
      }, 5000)
    } catch (err: any) {
      console.error('LeverUSD error:', err)
      setError(err.message || 'Leverage USD failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [swapAmount, swapToken, connected, contracts.aux, address, chainId, txMutex, fetchBalances])

  // ============== HOOK (Prediction Market) Functions ==============

  // Get the non-vault stables for the current chain (these are the market sides)
  const marketStables = useMemo(() => stables.filter(s => !s.isVault), [stables])

  // Side labels: 0 = "No Depeg", 1..N = stablecoin symbols
  const sideLabels = useMemo(() => {
    const labels = ['No Depeg']
    for (const s of marketStables) labels.push(s.symbol)
    return labels
  }, [marketStables])

  // Fetch Hook market data
  const fetchHookData = useCallback(async () => {
    if (!window.ethereum || !contracts.hook || contracts.hook === '0x0000000000000000000000000000000000000000') return
    setHookLoading(true)
    try {
      // Fetch market state
      const marketResult = await window.ethereum.request({
        method: 'eth_call',
        params: [{ to: contracts.hook, data: encodeGetMarket() }, 'latest'],
      })
      const decoded = hookIface.decodeFunctionResult('getMarket', marketResult)
      const m = decoded[0]
      setHookMarket({
        numSides: Number(m.numSides),
        roundNumber: Number(m.roundNumber),
        totalCapital: Number(m.totalCapital) / 1e18,
        resolved: m.resolved,
        winningSide: Number(m.winningSide),
        assertionPending: m.assertionPending,
        weightsComplete: m.weightsComplete,
        payoutsComplete: m.payoutsComplete,
        positionsTotal: Number(m.positionsTotal),
        positionsRevealed: Number(m.positionsRevealed),
        roundStartTime: Number(m.roundStartTime),
        resolutionTimestamp: Number(m.resolutionTimestamp),
      })

      // Fetch LMSR prices
      if (Number(m.numSides) > 0) {
        try {
          const pricesResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.hook, data: encodeGetAllPrices() }, 'latest'],
          })
          const pricesDecoded = hookIface.decodeFunctionResult('getAllPrices', pricesResult)
          setHookPrices(pricesDecoded[0].map((p: bigint) => Number(p) / 1e18))
        } catch { setHookPrices([]) }

        try {
          const capsResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.hook, data: encodeGetCapitalPerSide() }, 'latest'],
          })
          const capsDecoded = hookIface.decodeFunctionResult('getCapitalPerSide', capsResult)
          setHookCapitals(capsDecoded[0].map((c: bigint) => Number(c) / 1e18))
        } catch { setHookCapitals([]) }
      }

      // Fetch dispute status
      try {
        const frozenResult = await window.ethereum.request({
          method: 'eth_call',
          params: [{ to: contracts.hook, data: encodeDisputeFrozen() }, 'latest'],
        })
        setHookFrozen(BigInt(frozenResult) !== 0n)
      } catch {}

      // Fetch user positions per side
      if (address && Number(m.numSides) > 0) {
        const positions: Record<number, any> = {}
        for (let side = 0; side < Number(m.numSides); side++) {
          try {
            const posResult = await window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.hook, data: encodeGetPosition(address, side) }, 'latest'],
            })
            const pos = hookIface.decodeFunctionResult('getPosition', posResult)[0]
            if (pos.user !== '0x0000000000000000000000000000000000000000') {
              positions[side] = {
                totalCapital: Number(pos.totalCapital) / 1e18,
                totalTokens: Number(pos.totalTokens) / 1e18,
                revealed: pos.revealed,
                revealedConfidence: Number(pos.revealedConfidence),
                weight: Number(pos.weight),
                paidOut: pos.paidOut,
                autoRollover: pos.autoRollover,
                lastRound: Number(pos.lastRound),
                commitmentHash: pos.commitmentHash,
              }
            }
          } catch {}
        }
        setHookPositions(positions)
      }
    } catch (e) {
      console.error('Hook data fetch error:', e)
    } finally {
      setHookLoading(false)
    }
  }, [contracts.hook, address, stables])

  // Refresh Hook data when predictions tab is active
  useEffect(() => {
    if (activeTab === 'predictions' && contracts.hook && contracts.hook !== '0x0000000000000000000000000000000000000000') {
      fetchHookData()
      const interval = setInterval(fetchHookData, 30000) // refresh every 30s
      return () => clearInterval(interval)
    }
  }, [activeTab, chainId, contracts.hook, fetchHookData])

  // Place order on Hook
  const placeHookOrder = useCallback(async () => {
    if (!hookOrderAmount || !connected || !contracts.hook || !contracts.basket) return
    if (contracts.hook === '0x0000000000000000000000000000000000000000') return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)

    try {
      const capital = ethers.parseUnits(hookOrderAmount, 18) // QD is 18 decimals
      if (capital < ethers.parseUnits('1', 18)) throw new Error('Minimum order is 1 QD')

      // Generate salt and commit hash
      const salt = generateSalt()
      const commitHash = generateCommitHash(hookConfidence, salt)

      // Approve QD (basket) to Hook
      setTxStatus('Approving QD to Hook...')
      await doApproval(contracts.basket, contracts.hook, capital, address, chainId, setTxStatus)

      setTxStatus('Placing order...')
      const data = encodeHookPlaceOrder(hookOrderSide, capital, hookAutoRollover, commitHash)

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: address, to: contracts.hook, data }],
      })

      setTxHash(hash)
      setTxStatus('Order submitted!')

      // Store confidence data — APPEND to array (each entry has its own commitHash)
      const confEntry = { confidence: hookConfidence, salt, commitHash }
      const storageKey = `hook-conf-${chainId}-${MARKET_ID}-${hookOrderSide}-${address}`
      try {
        const existing = JSON.parse(localStorage.getItem(storageKey) || '[]')
        existing.push(confEntry)
        localStorage.setItem(storageKey, JSON.stringify(existing))
      } catch { localStorage.setItem(storageKey, JSON.stringify([confEntry])) }
      // Post to backend API for keeper retrieval
      const confData = { user: address, mktId: MARKET_ID, side: hookOrderSide, confidence: hookConfidence, salt, chainId, commitHash }
      try {
        await fetch('/api/confidences', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(confData),
        })
      } catch (e) { console.warn('Could not store confidence to API:', e) }

      setHookSalt(salt)
      setHookCommitHash(commitHash)
      setHookOrderAmount('')

      setTimeout(() => { fetchHookData(); fetchBalances(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'Order failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [hookOrderAmount, hookOrderSide, hookConfidence, hookAutoRollover, connected, contracts.hook, contracts.basket, address, chainId, txMutex, fetchHookData, fetchBalances])

  // Sell Hook position
  const sellHookPosition = useCallback(async () => {
    if (!hookSellTokens || !connected || !contracts.hook) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Selling position...')

    try {
      const tokens = ethers.parseUnits(hookSellTokens, 18) // LMSR tokens are 18 decimals (WAD)
      const data = encodeHookSell(hookOrderSide, tokens)

      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: address, to: contracts.hook, data }],
      })

      setTxHash(hash)
      setTxStatus('Sell submitted!')
      setHookSellTokens('')
      setTimeout(() => { fetchHookData(); fetchBalances(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'Sell failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [hookSellTokens, hookOrderSide, connected, contracts.hook, address, txMutex, fetchHookData, fetchBalances])

  // Reveal confidence (batchReveal)
  const revealHookConfidence = useCallback(async () => {
    if (!connected || !contracts.hook) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Revealing confidence...')

    try {
      // Load ALL stored confidences for this position (each entry has its own commitHash)
      const storageKey = `hook-conf-${chainId}-${MARKET_ID}-${hookOrderSide}-${address}`
      const stored = localStorage.getItem(storageKey)
      let reveals: { confidence: number; salt: string }[]

      if (stored) {
        const entries = JSON.parse(stored)
        if (Array.isArray(entries) && entries.length > 0) {
          reveals = entries.map((e: any) => ({ confidence: e.confidence, salt: e.salt }))
        } else if (entries.confidence && entries.salt) {
          // Legacy single-entry format
          reveals = [{ confidence: entries.confidence, salt: entries.salt }]
        } else {
          throw new Error('No stored confidence found locally')
        }
      } else {
        // API fallback — returns all entries sorted by createdAt
        const resp = await fetch(`/api/confidences?user=${address}&mktId=${MARKET_ID}&side=${hookOrderSide}&chainId=${chainId}`)
        if (resp.ok) {
          const data = await resp.json()
          if (data.confidences?.length > 0) {
            reveals = data.confidences.map((c: any) => ({ confidence: c.confidence, salt: c.salt }))
          } else {
            throw new Error('No stored confidence found. You need the original salt to reveal.')
          }
        } else {
          throw new Error('No stored confidence found. You need the original salt to reveal.')
        }
      }

      const data = encodeHookBatchReveal(address, hookOrderSide, reveals)
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: address, to: contracts.hook, data }],
      })

      setTxHash(hash)
      setTxStatus('Reveal submitted!')
      setTimeout(() => { fetchHookData(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'Reveal failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [connected, contracts.hook, address, chainId, hookOrderSide, txMutex, fetchHookData])

  // Recommit rollover position
  const recommitHookPosition = useCallback(async () => {
    if (!connected || !contracts.hook) return
    if (txMutex) return

    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Recommitting...')

    try {
      const salt = generateSalt()
      const commitHash = generateCommitHash(hookConfidence, salt)

      const data = encodeHookRecommit(hookOrderSide, commitHash)
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: address, to: contracts.hook, data }],
      })

      // Recommit clears old entries — new round, fresh commitment
      const storageKey = `hook-conf-${chainId}-${MARKET_ID}-${hookOrderSide}-${address}`
      const confEntry = { confidence: hookConfidence, salt, commitHash }
      localStorage.setItem(storageKey, JSON.stringify([confEntry]))
      // Clear old entries in API and store new one
      const confData = { user: address, mktId: MARKET_ID, side: hookOrderSide, confidence: hookConfidence, salt, chainId, commitHash }
      try {
        await fetch(`/api/confidences?user=${address}&mktId=${MARKET_ID}&side=${hookOrderSide}&chainId=${chainId}`, { method: 'DELETE' })
        await fetch('/api/confidences', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(confData) })
      } catch {}

      setTxHash(hash)
      setTxStatus('Recommit submitted!')
      setTimeout(() => { fetchHookData(); setTxStatus(null) }, 5000)
    } catch (err: any) {
      setError(err.message || 'Recommit failed')
      setTxStatus(null)
    } finally {
      setIsLoading(false)
      setTxMutex(false)
    }
  }, [connected, contracts.hook, address, chainId, hookOrderSide, hookConfidence, txMutex, fetchHookData])

  // Format token balance for display
  const getTokenBalance = (token: StableToken) => {
    const bal = tokenBalances[token.address]
    if (!bal) return '0'
    return formatUnits(bal, token.decimals)
  }

  // Calculate maturity date
  const maturityDate = useMemo(() => {
    const date = new Date()
    date.setMonth(date.getMonth() + maturityMonths + 1)
    return date.toLocaleDateString('en-US', { month: 'short', year: 'numeric' })
  }, [maturityMonths])

  return (
    <div className="min-h-screen bg-[#0a0b0d] text-white">
      {/* Background */}
      <div className="fixed inset-0 bg-gradient-to-br from-[#0a0b0d] via-[#0d1117] to-[#0a0b0d] pointer-events-none" />
      <div
        className="fixed inset-0 opacity-30 pointer-events-none"
        style={{ backgroundImage: `radial-gradient(circle at 50% 0%, ${chain.color}22 0%, transparent 50%)` }}
      />

      <div className="relative z-10 max-w-4xl mx-auto px-4 py-8">
        {/* Header */}
        <header className="flex items-center justify-between mb-8">
          <a href="https://quid.io" className="flex items-center gap-3 hover:opacity-80 transition-opacity">
            <img src="/logo.png" alt="QU!D" className="w-10 h-10 rounded-lg" />
            <div>
              <h1 className="text-xl font-bold tracking-tight">QU!D</h1>
              <p className="text-xs text-gray-500">Stablecoin Protocol</p>
            </div>
          </a>

          <div className="flex items-center gap-3">
            {/* Chain Selector */}
            <div className="relative">
              <button
                onClick={() => setShowChainMenu(!showChainMenu)}
                className="flex items-center gap-2 px-4 py-2 rounded-lg bg-white/5 border border-white/10 hover:border-white/20 transition-all"
              >
                <span className="text-lg">{chain.icon}</span>
                <span className="text-sm">{chain.name}</span>
                <svg className="w-4 h-4 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                </svg>
              </button>

              {showChainMenu && (
                <div className="absolute right-0 mt-2 w-48 py-2 bg-[#161b22] border border-white/10 rounded-lg z-50">
                  {ENABLED_CHAINS.map((c) => (
                    <button
                      key={c.id}
                      onClick={() => switchChain(c.id)}
                      className={`w-full flex items-center gap-3 px-4 py-2 text-left hover:bg-white/5 transition-colors ${
                        c.id === chainId ? 'text-cyan-400' : 'text-gray-300'
                      }`}
                    >
                      <span className="text-lg">{c.icon}</span>
                      <span className="text-sm">{c.name}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>

            {/* Connect Button */}
            {connected ? (
              <button className="flex items-center gap-2 px-4 py-2 rounded-lg bg-cyan-500/10 border border-cyan-500/30 text-cyan-400">
                <div className="w-2 h-2 rounded-full bg-green-400 animate-pulse" />
                <span className="text-sm">{shortenAddress(address)}</span>
              </button>
            ) : (
              <button
                onClick={connectWallet}
                disabled={isLoading}
                className="px-6 py-2 rounded-lg bg-gradient-to-r from-cyan-500 to-blue-600 font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
              >
                {isLoading ? 'Connecting...' : 'Connect'}
              </button>
            )}
          </div>
        </header>

        {/* Protocol Toggle */}
        <div className="flex justify-center mb-8">
          <div className="inline-flex p-1 rounded-xl bg-white/5 border border-white/10">
            <button
              onClick={() => setProtocol('v3')}
              className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${
                protocol === 'v3' ? 'bg-gradient-to-r from-purple-500 to-pink-500 text-white' : 'text-gray-400 hover:text-white'
              }`}
            >
              UniswapV3 (Rover)
            </button>
            <button
              onClick={() => setProtocol('v4')}
              className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${
                protocol === 'v4' ? 'bg-gradient-to-r from-cyan-500 to-blue-500 text-white' : 'text-gray-400 hover:text-white'
              }`}
            >
              UniswapV4 (Vogue)
            </button>
          </div>
        </div>

        {/* Stats Cards - Only show when we have real data */}
        {(basketMetrics.total > 0 || pooledETH > 0 || ethPrice > 0) && (
        <div className="grid grid-cols-5 gap-3 mb-8">
          {/* Aux Total Deposits */}
          <div className="p-4 rounded-xl bg-white/5 border border-white/10 relative">
            <div className="flex items-center gap-1 mb-1">
              <p className="text-xs text-gray-500 uppercase tracking-wider">Aux Deposits</p>
              <button
                onClick={() => setShowDepositsBreakdown(!showDepositsBreakdown)}
                className="w-4 h-4 rounded-full bg-white/10 text-[9px] text-gray-400 hover:bg-white/20 flex items-center justify-center"
                title="Show breakdown"
              >
                i
              </button>
            </div>
            <p className="text-xl font-bold">
              {basketMetrics.total > 0 ? `$${formatNumber(basketMetrics.total, 0)}` : '—'}
            </p>
            {showDepositsBreakdown && auxDeposits.length > 0 && (
              <div className="absolute top-full left-0 mt-1 z-20 w-64 p-3 rounded-xl bg-[#111318] border border-white/10 shadow-xl">
                <p className="text-[10px] text-gray-500 mb-2 uppercase">Per-stablecoin deposits</p>
                {(() => {
                  const nonVault = stables.filter(s => !s.isVault)
                  const labels = [...nonVault.map(s => s.symbol), 'USYC']
                  return labels.map((label, idx) => {
                    const val = auxDeposits[idx + 1] || 0 // amounts[1..11]
                    if (val < 0.01) return null
                    return (
                      <div key={label} className="flex justify-between text-xs py-0.5">
                        <span className="text-gray-400">{label}</span>
                        <span className="text-white">${formatNumber(val, 2)}</span>
                      </div>
                    )
                  }).filter(Boolean)
                })()}
                {auxDeposits[12] > 0 && (
                  <div className="flex justify-between text-xs pt-1 mt-1 border-t border-white/10">
                    <span className="text-gray-400">Available</span>
                    <span className="text-cyan-400">${formatNumber(auxDeposits[12], 2)}</span>
                  </div>
                )}
              </div>
            )}
          </div>
          {/* Aux Yield */}
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Aux Yield</p>
            <p className="text-xl font-bold text-green-400">
              {basketMetrics.avgYield > 0 ? `${basketMetrics.avgYield.toFixed(2)}%` : '—'}
            </p>
          </div>
          {/* ETH Pool (total deposited by LPs) */}
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">ETH Pool</p>
            <p className="text-xl font-bold">
              {pooledETH > 0 ? `${formatNumber(pooledETH, 2)} ETH` : '—'}
            </p>
          </div>
          {/* Vogue Yield */}
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Vogue Yield</p>
            <p className="text-xl font-bold text-green-400">
              {ethMetrics.totalShares > 0
                ? `${((ethMetrics.ethFees / ethMetrics.totalShares) * 100).toFixed(2)}%`
                : '—'
              }
            </p>
          </div>
          {/* ETH Price */}
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">ETH Price</p>
            <p className="text-xl font-bold">
              {ethPrice > 0 ? `$${formatNumber(ethPrice, 0)}` : '—'}
            </p>
          </div>
        </div>
        )}

        {/* Tab Navigation */}
        <div className="flex gap-1 p-1 mb-6 rounded-lg bg-white/5 border border-white/10">
          {['mint', 'deposit', 'withdraw', 'swap', 'predictions'].map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`flex-1 py-2 rounded-md text-sm font-medium capitalize transition-all ${
                activeTab === tab ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
              }`}
            >
              {tab === 'mint' ? 'Mint QD' : tab === 'predictions' ? '📊 De-pegs' : tab}
            </button>
          ))}
        </div>

        {/* Main Content */}
        <div className="p-6 rounded-2xl bg-white/5 border border-white/10 backdrop-blur-sm glow">
          {/* Error */}
          {error && (
            <div className="mb-4 p-3 rounded-lg bg-red-500/10 border border-red-500/30 text-red-400 text-sm">
              {error}
              <button onClick={() => setError(null)} className="ml-2 text-red-300 hover:text-white">
                ×
              </button>
            </div>
          )}

          {/* Transaction Status */}
          {txStatus && !txHash && (
            <div className="mb-4 p-3 rounded-lg bg-blue-500/10 border border-blue-500/30 text-blue-400 text-sm flex items-center gap-2">
              <svg className="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
              <span>{txStatus}</span>
            </div>
          )}

          {/* Success */}
          {txHash && (
            <div className="mb-4 p-3 rounded-lg bg-green-500/10 border border-green-500/30 text-green-400 text-sm flex items-center justify-between">
              <span>Transaction submitted!</span>
              <a
                href={`${chain.explorer}/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="underline hover:text-green-300"
              >
                View →
              </a>
            </div>
          )}

          {/* MINT TAB */}
          {activeTab === 'mint' && (
            <div className="space-y-6">
              <div>
                <div className="flex justify-between items-center mb-3">
                  <label className="text-sm text-gray-400">Select Stablecoin</label>
                  {loadingBalances && <span className="text-xs text-gray-500">Loading balances...</span>}
                </div>

                {/* Token Grid */}
                <div className="token-grid">
                  {stables.map((token) => {
                    const balance = getTokenBalance(token)
                    const hasBalance = parseFloat(balance) > 0
                    const isSelected = selectedToken?.address === token.address

                    return (
                      <button
                        key={token.address}
                        onClick={() => hasBalance && setSelectedToken(token)}
                        disabled={!hasBalance}
                        className={`p-3 rounded-xl border transition-all text-left ${
                          isSelected
                            ? 'bg-cyan-500/20 border-cyan-500/50'
                            : hasBalance
                            ? 'bg-white/5 border-white/10 hover:border-white/20'
                            : 'bg-white/[0.02] border-white/5 opacity-40 cursor-not-allowed'
                        }`}
                      >
                        <div className="flex items-center justify-between mb-1">
                          <span className={`text-sm font-medium ${isSelected ? 'text-cyan-400' : ''}`}>
                            {token.symbol}
                          </span>
                          {token.isVault && <span className="text-[10px] text-purple-400">vault</span>}
                        </div>
                        <div className="text-xs text-gray-500 truncate">{formatNumber(parseFloat(balance), 2)}</div>
                      </button>
                    )
                  })}
                </div>

                {tokensWithBalance.length === 0 && !loadingBalances && connected && (
                  <p className="text-center text-gray-500 py-4 text-sm">No stablecoin balances found on {chain.name}</p>
                )}
              </div>

              {/* Amount Input */}
              {selectedToken && (
                <>
                  <div>
                    <label className="block text-sm text-gray-400 mb-2">Amount to Mint</label>
                    <div className="relative">
                      <input
                        type="number"
                        value={mintAmount}
                        onChange={(e) => setMintAmount(e.target.value)}
                        placeholder="0.0"
                        className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                      />
                      <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
                        <button
                          onClick={() => setMintAmount(getTokenBalance(selectedToken))}
                          className="px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                        >
                          MAX
                        </button>
                        <span className="text-sm text-gray-400">{selectedToken.symbol}</span>
                      </div>
                    </div>
                    <p className="mt-2 text-sm text-gray-500">
                      Balance: {formatNumber(parseFloat(getTokenBalance(selectedToken)), 4)} {selectedToken.symbol}
                    </p>
                  </div>

                  {/* Maturity Slider */}
                  <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                    <div className="flex justify-between items-center mb-2">
                      <label className="text-sm text-gray-400">Lock Period</label>
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => setMaturityMonths(Math.max(0, maturityMonths - 1))}
                          className="w-8 h-8 rounded-lg bg-white/10 hover:bg-white/20 flex items-center justify-center"
                        >
                          −
                        </button>
                        <div className="text-center min-w-[80px]">
                          <span className="text-2xl font-bold text-cyan-400">{maturityMonths}</span>
                          <span className="text-sm text-gray-400 ml-1">mo</span>
                        </div>
                        <button
                          onClick={() => setMaturityMonths(Math.min(13, maturityMonths + 1))}
                          className="w-8 h-8 rounded-lg bg-white/10 hover:bg-white/20 flex items-center justify-center"
                        >
                          +
                        </button>
                      </div>
                    </div>

                    <input
                      type="range"
                      min="0"
                      max="13"
                      value={maturityMonths}
                      onChange={(e) => setMaturityMonths(parseInt(e.target.value))}
                      className="w-full h-2 cursor-pointer mb-2"
                    />

                    {/* Month markers */}
                    <div className="flex justify-between text-[10px] text-gray-600 px-1">
                      {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].map((m) => (
                        <span key={m} className={maturityMonths === m ? 'text-cyan-400 font-bold' : ''}>
                          {m}
                        </span>
                      ))}
                    </div>

                    <div className="mt-4 pt-4 border-t border-white/5 grid grid-cols-3 gap-4">
                      <div>
                        <p className="text-xs text-gray-500 mb-1">Redeemable</p>
                        <p className="text-sm font-medium text-white">{maturityDate}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500 mb-1">Yield Bonus</p>
                        <p className="text-sm font-medium text-green-400">
                          {basketMetrics.avgYield > 0
                            ? `+${(basketMetrics.avgYield * (maturityMonths + 1) / 12).toFixed(2)}%`
                            : '—'
                          }
                        </p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500 mb-1">Multiplier</p>
                        <p className="text-sm font-medium text-cyan-400">
                          {basketMetrics.avgYield > 0
                            ? `${(1 + (basketMetrics.avgYield / 100) * (maturityMonths + 1) / 12).toFixed(3)}x`
                            : '—'
                          }
                        </p>
                      </div>
                    </div>

                    {maturityMonths === 0 && (
                      <p className="mt-3 text-xs text-yellow-400/80">
                        ⚡ Minimum lock = next month. Longer locks earn more yield.
                      </p>
                    )}
                    {maturityMonths === 12 && (
                      <p className="mt-3 text-xs text-green-400/80">🏆 Maximum yield bonus! Tokens locked for 1 year.</p>
                    )}
                    {maturityMonths === 13 && (
                      <p className="mt-3 text-xs text-purple-400/80">🌱 Seed round: 2× average yield premium, 13-month lock. Early believer bonus.</p>
                    )}
                  </div>

                  {/* Action Button */}
                  <button
                    onClick={mintTokens}
                    disabled={!connected || isLoading || !mintAmount || parseFloat(mintAmount) <= 0 || txMutex}
                    className="w-full py-4 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isLoading && activeTab === 'mint' ? (txStatus || 'Processing...') : 'Mint QD Tokens'}
                  </button>

                  {/* Info Box */}
                  <div className="p-4 rounded-xl bg-cyan-500/5 border border-cyan-500/20">
                    <p className="text-xs text-cyan-400/80">
                      <strong>How it works:</strong> Deposit stablecoins to mint QD tokens. Longer maturity periods earn
                      higher yield bonuses. Your tokens will be claimable after the selected maturity date.
                    </p>
                  </div>
                </>
              )}

              {/* Redeem Section - shows when user has mature QD balance */}
              {connected && BigInt(matureQdBalance) > 0n && (
                <div className="mt-6 pt-6 border-t border-white/10">
                  <div className="flex justify-between items-center mb-3">
                    <label className="text-sm text-gray-400">Redeem QD Tokens</label>
                    <span className="text-xs text-gray-500">
                      Mature Balance: {formatNumber(Number(matureQdBalance) / 1e18, 4)} QD
                    </span>
                  </div>
                  <div className="relative mb-4">
                    <input
                      type="number"
                      value={redeemAmount}
                      onChange={(e) => setRedeemAmount(e.target.value)}
                      placeholder="0.0"
                      className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-green-500/50 focus:outline-none text-xl"
                    />
                    <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
                      <button
                        onClick={() => setRedeemAmount((Number(matureQdBalance) / 1e18).toString())}
                        className="px-3 py-1 rounded-md bg-white/10 text-xs text-green-400 hover:bg-white/20"
                      >
                        MAX
                      </button>
                      <span className="text-sm text-gray-400">QD</span>
                    </div>
                  </div>

                  <button
                    onClick={redeemQD}
                    disabled={!connected || isLoading || !redeemAmount || parseFloat(redeemAmount) <= 0 || txMutex || BigInt(matureQdBalance) <= 0n}
                    className="w-full py-4 rounded-xl bg-gradient-to-r from-green-500 to-emerald-600 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isLoading && txStatus?.includes('Redeem') ? (txStatus || 'Processing...') : 'Redeem'}
                  </button>
                  <p className="mt-2 text-xs text-gray-500 text-center">
                    Only mature QD tokens can be redeemed.
                  </p>
                </div>
              )}

              {!connected && (
                <button
                  onClick={connectWallet}
                  className="w-full py-4 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 font-bold text-lg"
                >
                  Connect Wallet to Mint
                </button>
              )}
            </div>
          )}

          {/* DEPOSIT TAB */}
          {activeTab === 'deposit' && (
            <div className="space-y-6">
              {/* Sub-tab toggle: Auto LP / Self-Managed */}
              <div className="flex gap-1 p-1 rounded-lg bg-white/5">
                <button
                  onClick={() => setDepositSubTab('auto')}
                  className={`flex-1 py-2 rounded-md text-sm font-medium transition-all ${
                    depositSubTab === 'auto' ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
                  }`}
                >
                  Auto LP
                </button>
                <button
                  onClick={() => setDepositSubTab('selfManaged')}
                  className={`flex-1 py-2 rounded-md text-sm font-medium transition-all ${
                    depositSubTab === 'selfManaged' ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
                  }`}
                  disabled={protocol !== 'v4'}
                  title={protocol !== 'v4' ? 'Self-managed positions are only available on Vogue (V4)' : ''}
                >
                  Self-Managed LP {protocol !== 'v4' && '(V4 only)'}
                </button>
              </div>

              {/* AUTO LP sub-tab */}
              {depositSubTab === 'auto' && (
                <>
                  <div>
                    <label className="block text-sm text-gray-400 mb-2">Deposit ETH to LP</label>
                    <div className="relative">
                      <input
                        type="number"
                        value={depositAmount}
                        onChange={(e) => setDepositAmount(e.target.value)}
                        placeholder="0.0"
                        className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                      />
                      <button
                        onClick={() => setDepositAmount(combinedEthBalance.toFixed(6))}
                        className="absolute right-3 top-1/2 -translate-y-1/2 px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                      >
                        MAX
                      </button>
                    </div>
                    <p className="mt-2 text-sm text-gray-500">
                      Balance: {formatNumber(combinedEthBalance, 4)} ETH ({ethBalance} raw + {wethBalance} WETH)
                    </p>
                  </div>

                  <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                    <div className="flex justify-between text-sm mb-2">
                      <span className="text-gray-400">Protocol</span>
                      <span className="text-white">{protocol === 'v4' ? 'Vogue (UniV4)' : 'Rover (UniV3)'}</span>
                    </div>
                    <div className="flex justify-between text-sm">
                      <span className="text-gray-400">Est. Daily Yield</span>
                      <span className="text-green-400">
                        ~${formatNumber(parseFloat(depositAmount || '0') * ethPrice * ((ethMetrics.totalShares > 0 ? (ethMetrics.ethFees / ethMetrics.totalShares) * 100 : 10) / 365 / 100), 2)}
                        /day
                      </span>
                    </div>
                  </div>

                  <button
                    onClick={depositETH}
                    disabled={!connected || isLoading || !depositAmount || txMutex}
                    className="w-full py-4 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isLoading && activeTab === 'deposit' ? (txStatus || 'Processing...') : connected ? 'Deposit ETH' : 'Connect Wallet'}
                  </button>
                </>
              )}

              {/* SELF-MANAGED LP sub-tab (outOfRange) */}
              {depositSubTab === 'selfManaged' && protocol === 'v4' && (
                <>
                  {/* Token side toggle */}
                  <div>
                    <label className="block text-sm text-gray-400 mb-2">Deposit Side</label>
                    <div className="inline-flex p-1 rounded-lg bg-black/30 border border-white/10">
                      <button
                        onClick={() => setOorToken('eth')}
                        className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                          oorToken === 'eth' ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400 hover:text-white'
                        }`}
                      >
                        ETH
                      </button>
                      <button
                        onClick={() => setOorToken('usd')}
                        className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                          oorToken === 'usd' ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400 hover:text-white'
                        }`}
                      >
                        Stablecoin
                      </button>
                    </div>
                  </div>

                  {/* Stablecoin selector (only for USD side) */}
                  {oorToken === 'usd' && (
                    <div>
                      <label className="block text-xs text-gray-400 mb-2">Select Stablecoin</label>
                      <div className="grid grid-cols-5 gap-2">
                        {stables.filter(t => !t.isVault).map((token) => {
                          const balance = tokenBalances[token.address] ? formatUnits(tokenBalances[token.address], token.decimals) : '0'
                          const isSelected = oorStable?.address === token.address
                          return (
                            <button
                              key={token.address}
                              onClick={() => setOorStable(token)}
                              className={`p-2 rounded-lg text-xs font-medium border transition-all ${
                                isSelected
                                  ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                                  : 'bg-white/5 border-white/10 text-gray-400 hover:border-white/20'
                              }`}
                            >
                              {token.symbol}
                              <span className="block text-[10px] text-gray-500 mt-0.5">{formatNumber(parseFloat(balance), 2)}</span>
                            </button>
                          )
                        })}
                      </div>
                    </div>
                  )}

                  {/* Amount */}
                  <div>
                    <label className="block text-sm text-gray-400 mb-2">
                      Amount ({oorToken === 'eth' ? 'ETH' : oorStable?.symbol || 'USD'})
                    </label>
                    <div className="relative">
                      <input
                        type="number"
                        value={oorAmount}
                        onChange={(e) => setOorAmount(e.target.value)}
                        placeholder="0.0"
                        className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                      />
                      <button
                        onClick={() => {
                          if (oorToken === 'eth') {
                            setOorAmount(combinedEthBalance.toFixed(6))
                          } else if (oorStable) {
                            const bal = tokenBalances[oorStable.address]
                            if (bal) setOorAmount(formatUnits(bal, oorStable.decimals))
                          }
                        }}
                        className="absolute right-3 top-1/2 -translate-y-1/2 px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                      >
                        MAX
                      </button>
                    </div>
                  </div>

                  {/* Distance from current price */}
                  <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                    <div className="flex justify-between items-center mb-2">
                      <label className="text-sm text-gray-400">Distance from Current Price</label>
                      <span className="text-sm font-bold text-cyan-400">
                        {oorDistance > 0 ? '+' : ''}{oorDistance}%
                      </span>
                    </div>
                    <input
                      type="range"
                      min={-50}
                      max={50}
                      step={1}
                      value={oorDistance}
                      onChange={(e) => {
                        const v = Number(e.target.value)
                        if (v !== 0) setOorDistance(v)
                      }}
                      className="w-full"
                    />
                    <div className="flex justify-between text-[10px] text-gray-600 mt-1">
                      <span>-50% (below)</span>
                      <span>0%</span>
                      <span>+50% (above)</span>
                    </div>
                    <p className="text-[10px] text-gray-500 mt-2">
                      {oorDistance > 0
                        ? oorToken === 'eth'
                          ? 'Position above current price — provides ETH if price rises'
                          : 'Position above current price — provides USD if price drops'
                        : oorToken === 'eth'
                          ? 'Position below current price — provides ETH if price drops'
                          : 'Position below current price — provides USD if price rises'
                      }
                    </p>
                  </div>

                  {/* Range width */}
                  <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                    <div className="flex justify-between items-center mb-2">
                      <label className="text-sm text-gray-400">Range Width</label>
                      <span className="text-sm font-bold text-cyan-400">{oorRange}%</span>
                    </div>
                    <input
                      type="range"
                      min={1}
                      max={10}
                      step={0.5}
                      value={oorRange}
                      onChange={(e) => setOorRange(Number(e.target.value))}
                      className="w-full"
                    />
                    <div className="flex justify-between text-[10px] text-gray-600 mt-1">
                      <span>1% (tight)</span>
                      <span>10% (wide)</span>
                    </div>
                  </div>

                  <button
                    onClick={openOutOfRange}
                    disabled={
                      !connected || isLoading || !oorAmount || parseFloat(oorAmount) <= 0 || txMutex ||
                      oorDistance === 0 ||
                      (oorToken === 'usd' && !oorStable)
                    }
                    className="w-full py-4 rounded-xl bg-gradient-to-r from-purple-500 to-indigo-600 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isLoading && depositSubTab === 'selfManaged'
                      ? (txStatus || 'Processing...')
                      : connected ? 'Open Out-of-Range Position' : 'Connect Wallet'}
                  </button>

                  <div className="p-3 rounded-xl bg-purple-500/10 border border-purple-500/20">
                    <p className="text-xs text-purple-400">
                      Self-managed positions provide single-sided liquidity out of the current price range. Your position earns fees only if the price moves into your range. Use <strong>pull</strong> in the Withdraw tab to close.
                    </p>
                  </div>
                </>
              )}
            </div>
          )}

          {/* WITHDRAW TAB */}
          {activeTab === 'withdraw' && (
            <div className="space-y-6">
              {/* Auto-managed withdrawal */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">Withdraw Auto LP (ETH)</label>
                <div className="relative">
                  <input
                    type="number"
                    value={withdrawAmount}
                    onChange={(e) => setWithdrawAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                  />
                  <button
                    onClick={() => {
                      if (autoManagedInfo && autoManagedInfo.pooled > 0) {
                        setWithdrawAmount(autoManagedInfo.pooled.toFixed(6))
                      }
                    }}
                    className="absolute right-3 top-1/2 -translate-y-1/2 px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                  >
                    MAX
                  </button>
                </div>
                <p className="mt-2 text-sm text-gray-500">
                  Deposited: {autoManagedInfo ? formatNumber(autoManagedInfo.pooled, 4) : '0.00'} ETH
                </p>
              </div>

              <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Accrued ETH Fees</span>
                  <span className="text-green-400">
                    +{autoManagedInfo ? formatNumber(autoManagedInfo.feesEth, 6) : '0.00'} ETH
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">Accrued USD Fees</span>
                  <span className="text-green-400">
                    +${autoManagedInfo ? formatNumber(autoManagedInfo.feesUsd, 2) : '0.00'} (as QD)
                  </span>
                </div>
              </div>

              <button
                onClick={withdrawETH}
                disabled={!connected || isLoading || !withdrawAmount || txMutex}
                className="w-full py-4 rounded-xl bg-gradient-to-r from-orange-500 to-red-500 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50"
              >
                {isLoading && activeTab === 'withdraw' ? (txStatus || 'Processing...') : 'Withdraw Auto LP'}
              </button>

              {/* Self-managed positions — only shown when user has some */}
              {protocol === 'v4' && selfManagedPositions.length > 0 && (
                <div className="pt-6 border-t border-white/10">
                  <h3 className="text-sm font-medium text-gray-300 mb-3">Self-Managed Positions</h3>

                  {/* Pull settings */}
                  <div className="mb-4 p-3 rounded-xl bg-white/5 border border-white/10 space-y-3">
                    <div className="flex justify-between items-center">
                      <label className="text-xs text-gray-400">Withdraw %</label>
                      <span className="text-xs font-bold text-cyan-400">{pullPercent}%</span>
                    </div>
                    <input
                      type="range"
                      min={1} max={100} value={pullPercent}
                      onChange={(e) => setPullPercent(Number(e.target.value))}
                      className="w-full"
                    />
                    <div className="flex justify-between items-center">
                      <label className="text-xs text-gray-400">Receive as</label>
                      <div className="inline-flex p-0.5 rounded-lg bg-black/30 border border-white/10">
                        <button
                          onClick={() => setPullToken('0x0000000000000000000000000000000000000000')}
                          className={`px-3 py-1 rounded text-xs transition-all ${
                            pullToken === '0x0000000000000000000000000000000000000000'
                              ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400'
                          }`}
                        >
                          ETH
                        </button>
                        {stables.filter(s => !s.isVault).slice(0, 4).map(s => (
                          <button
                            key={s.address}
                            onClick={() => setPullToken(s.address)}
                            className={`px-3 py-1 rounded text-xs transition-all ${
                              pullToken === s.address ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400'
                            }`}
                          >
                            {s.symbol}
                          </button>
                        ))}
                      </div>
                    </div>
                  </div>

                  {/* Position cards */}
                  <div className="space-y-2">
                    {selfManagedPositions.map((pos) => (
                      <div
                        key={pos.id.toString()}
                        className="p-3 rounded-xl bg-white/5 border border-white/10 flex items-center justify-between"
                      >
                        <div>
                          <p className="text-sm font-medium text-white">Position #{pos.id.toString()}</p>
                          <p className="text-[10px] text-gray-500">
                            Ticks: [{pos.lower}, {pos.upper}] • Liq: {formatNumber(Number(pos.liq) / 1e18, 4)}
                          </p>
                        </div>
                        <button
                          onClick={() => pullSelfManaged(pos.id)}
                          disabled={isLoading || txMutex}
                          className="px-4 py-2 rounded-lg bg-gradient-to-r from-orange-500 to-red-500 text-xs font-bold hover:opacity-90 disabled:opacity-50"
                        >
                          Pull {pullPercent}%
                        </button>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          {/* SWAP TAB */}
          {activeTab === 'swap' && (
            <div className="space-y-6">
              {/* Direction Toggle */}
              <div className="flex justify-center">
                <div className="inline-flex p-1 rounded-lg bg-black/30 border border-white/10">
                  <button
                    onClick={() => setSwapDirection('toETH')}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      swapDirection === 'toETH' ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400 hover:text-white'
                    }`}
                  >
                    USD → ETH
                  </button>
                  <button
                    onClick={() => setSwapDirection('toUSD')}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      swapDirection === 'toUSD' ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400 hover:text-white'
                    }`}
                  >
                    ETH → USD
                  </button>
                </div>
              </div>

              {/* Speed Toggle */}
              <div className="flex justify-center">
                <div className="inline-flex p-1 rounded-lg bg-black/30 border border-white/10">
                  <button
                    onClick={() => setSwapSpeed('instant')}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      swapSpeed === 'instant' ? 'bg-green-500/20 text-green-400' : 'text-gray-400 hover:text-white'
                    }`}
                  >
                    ⚡ Instant
                  </button>
                  <button
                    onClick={() => chain.hasLeverage && setSwapSpeed('wait')}
                    disabled={!chain.hasLeverage}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      !chain.hasLeverage
                        ? 'text-gray-600 cursor-not-allowed'
                        : swapSpeed === 'wait' ? 'bg-purple-500/20 text-purple-400' : 'text-gray-400 hover:text-white'
                    }`}
                    title={!chain.hasLeverage ? 'Leverage not available on this chain' : ''}
                  >
                    ⏳ Wait {!chain.hasLeverage && '(N/A)'}
                  </button>
                </div>
              </div>

              {/* Token Selection - only for USD side */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">
                  {swapDirection === 'toETH' ? 'Stablecoin to Sell' : 'Output Token'}
                </label>

                {/* For ETH → USD, show QUID option first */}
                {swapDirection === 'toUSD' && (
                  <div className="mb-3">
                    <button
                      onClick={() => {
                        setSwapOutputMode('quid')
                        setSwapToken(null)
                        setSwapFee(0)
                      }}
                      className={`w-full p-3 rounded-lg border text-left transition-all ${
                        swapOutputMode === 'quid'
                          ? 'bg-green-500/20 border-green-500/50'
                          : 'bg-white/5 border-white/10 hover:border-white/20'
                      }`}
                    >
                      <div className="flex justify-between items-center">
                        <div>
                          <span className={`font-medium ${swapOutputMode === 'quid' ? 'text-green-400' : 'text-white'}`}>
                            QUID (QD)
                          </span>
                          <p className="text-xs text-gray-500 mt-0.5">Basket token - 0% fee</p>
                        </div>
                        {swapOutputMode === 'quid' && (
                          <span className="text-green-400 text-sm">✓ Free</span>
                        )}
                      </div>
                    </button>
                  </div>
                )}

                {/* Stablecoin selection */}
                {swapDirection === 'toUSD' && (
                  <p className="text-xs text-gray-500 mb-2">Or select a specific stablecoin (has fee):</p>
                )}
                <div className="grid grid-cols-5 gap-2">
                  {stables.filter(t => !t.isVault).map((token) => {
                    const isSelected = swapOutputMode === 'token' && swapToken?.address === token.address
                    const balance = swapDirection === 'toETH' ? getTokenBalance(token) : null
                    const hasBalance = balance ? parseFloat(balance) > 0 : true

                    return (
                      <button
                        key={token.address}
                        onClick={async () => {
                          setSwapToken(token)
                          if (swapDirection === 'toUSD') {
                            setSwapOutputMode('token')
                            // Fetch fee for this token
                            try {
                              const feeResult = await window.ethereum?.request({
                                method: 'eth_call',
                                params: [{ to: contracts.aux, data: encodeGetFee(token.address) }, 'latest'],
                              })
                              const fee = Number(BigInt(feeResult || '0'))
                              setSwapFee(fee) // fee in basis points (e.g., 4 = 0.04%)
                              console.log('Fee for', token.symbol, ':', fee, 'bps')
                            } catch (e) {
                              console.log('Could not fetch fee:', e)
                              setSwapFee(4) // default 4 bps
                            }
                          }
                        }}
                        disabled={swapDirection === 'toETH' && !hasBalance}
                        className={`p-2 rounded-lg border text-center transition-all ${
                          isSelected
                            ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                            : hasBalance
                            ? 'bg-white/5 border-white/10 hover:border-white/20'
                            : 'bg-white/[0.02] border-white/5 opacity-40 cursor-not-allowed'
                        }`}
                      >
                        <span className="text-sm font-medium">{token.symbol}</span>
                        {balance && <p className="text-[10px] text-gray-500 mt-1">{formatNumber(parseFloat(balance), 2)}</p>}
                      </button>
                    )
                  })}
                </div>

                {/* Show fee for specific token selection */}
                {swapDirection === 'toUSD' && swapOutputMode === 'token' && swapToken && (
                  <p className="mt-2 text-xs text-yellow-400/80">
                    💡 Fee: {(swapFee / 100).toFixed(2)}% ({swapFee} bps) for {swapToken.symbol}
                  </p>
                )}
              </div>

              {/* Amount Input */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">
                  {swapDirection === 'toETH' ? 'Amount to Swap' : 'ETH Amount'}
                </label>
                <div className="relative">
                  <input
                    type="number"
                    value={swapAmount}
                    onChange={(e) => setSwapAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                  />
                  <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
                    <button
                      onClick={() => {
                        if (swapDirection === 'toETH' && swapToken) {
                          setSwapAmount(getTokenBalance(swapToken))
                        } else {
                          setSwapAmount(combinedEthBalance.toFixed(6))
                        }
                      }}
                      className="px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                    >
                      MAX
                    </button>
                    <span className="text-sm text-gray-400">
                      {swapDirection === 'toETH' ? swapToken?.symbol || 'USD' : 'ETH'}
                    </span>
                  </div>
                </div>
                <p className="mt-2 text-sm text-gray-500">
                  {swapDirection === 'toETH'
                    ? `Balance: ${swapToken ? formatNumber(parseFloat(getTokenBalance(swapToken)), 4) : '0'} ${swapToken?.symbol || ''}`
                    : `Balance: ${formatNumber(combinedEthBalance, 4)} ETH (${ethBalance} raw + ${wethBalance} WETH)`
                  }
                </p>
              </div>

              {/* Info Box - changes based on speed */}
              {swapSpeed === 'instant' ? (
                <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Mode</span>
                    <span className="text-green-400">⚡ Instant Swap</span>
                  </div>
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Direction</span>
                    <span className="text-white">{swapDirection === 'toETH' ? 'Sell USD for ETH' : 'Sell ETH for USD'}</span>
                  </div>
                  {swapDirection === 'toUSD' && (
                    <div className="flex justify-between text-sm mb-2">
                      <span className="text-gray-400">Output</span>
                      <span className={swapOutputMode === 'quid' ? 'text-green-400' : 'text-cyan-400'}>
                        {swapOutputMode === 'quid' ? 'QUID (0% fee)' : `${swapToken?.symbol || 'Token'} (${(swapFee / 100).toFixed(2)}% fee)`}
                      </span>
                    </div>
                  )}
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-400">Est. Output</span>
                    <span className="text-green-400">
                      {swapAmount && parseFloat(swapAmount) > 0
                        ? swapDirection === 'toETH'
                          ? `~${formatNumber(parseFloat(swapAmount) / ethPrice, 6)} ETH`
                          : swapOutputMode === 'quid'
                            ? `~${formatNumber(parseFloat(swapAmount) * ethPrice, 2)} QUID`
                            : `~${formatNumber(parseFloat(swapAmount) * ethPrice * (1 - swapFee / 10000), 2)} ${swapToken?.symbol || 'USD'}`
                        : '—'
                      }
                    </span>
                  </div>
                </div>
              ) : (
                <div className="p-4 rounded-xl bg-purple-500/5 border border-purple-500/20">
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Mode</span>
                    <span className="text-purple-400">⏳ Wait (Leveraged)</span>
                  </div>
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Position</span>
                    <span className="text-white">{swapDirection === 'toUSD' ? '📈 Long ETH' : '📉 Short ETH'}</span>
                  </div>
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Effective Leverage</span>
                    <span className="text-purple-400">~1.7x</span>
                  </div>
                  <div className="flex justify-between text-sm mb-2">
                    <span className="text-gray-400">Pivot Trigger</span>
                    <span className="text-yellow-400">±2.5% price move</span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-400">Potential Return</span>
                    <span className="text-green-400">Higher than instant (always, but extent varies)</span>
                  </div>
                </div>
              )}

              {/* Swap Button */}
              <button
                onClick={() => {
                  if (swapSpeed === 'instant') {
                    swapTokens()
                  } else {
                    // Wait mode: use lever functions
                    if (swapDirection === 'toUSD') {
                      leverETH() // Selling ETH, go long
                    } else {
                      leverUSD() // Selling USD, go short
                    }
                  }
                }}
                disabled={
                  !connected ||
                  isLoading ||
                  !swapAmount ||
                  parseFloat(swapAmount) <= 0 ||
                  txMutex ||
                  // For USD→ETH, need a token selected
                  (swapDirection === 'toETH' && !swapToken) ||
                  // For ETH→USD instant, need either QUID mode or a token
                  (swapDirection === 'toUSD' && swapSpeed === 'instant' && swapOutputMode === 'token' && !swapToken)
                }
                className={`w-full py-4 rounded-xl font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed ${
                  swapSpeed === 'instant'
                    ? 'bg-gradient-to-r from-cyan-500 to-blue-600'
                    : 'bg-gradient-to-r from-purple-500 to-indigo-600'
                }`}
              >
                {isLoading && activeTab === 'swap'
                  ? (txStatus || 'Processing...')
                  : connected
                    ? swapSpeed === 'instant' ? 'Swap Now' : 'Open Position'
                    : 'Connect Wallet'}
              </button>

              <p className="text-xs text-gray-500 text-center">
                {swapSpeed === 'instant'
                  ? 'Instant swaps execute via Aux with ~5 block delay for sandwich protection'
                  : 'Wait positions use AAVE leverage. A keeper bot monitors and pivots at ±2.5% price moves.'
                }
              </p>
            </div>
          )}

          {/* PREDICTIONS TAB */}
          {activeTab === 'predictions' && (
            <div className="space-y-4">
              {/* Hook not deployed warning */}
              {(!contracts.hook || contracts.hook === '0x0000000000000000000000000000000000000000') ? (
                <div className="text-center py-12">
                  <div className="text-4xl mb-4">🔮</div>
                  <h3 className="text-xl font-bold mb-2">Depeg Prediction Market</h3>
                  <p className="text-gray-400 mb-4">Hook contract not yet deployed on {chain.name}.</p>
                  <div className="inline-block px-4 py-2 rounded-xl bg-yellow-500/10 border border-yellow-500/30">
                    <p className="text-yellow-400 text-sm">Awaiting deployment</p>
                  </div>
                </div>
              ) : (
                <>
                  {/* Market Header */}
                  <div className="flex items-center justify-between">
                    <div>
                      <h3 className="text-lg font-bold">Stablecoin Depeg Market</h3>
                      <p className="text-xs text-gray-500">
                        Round #{hookMarket?.roundNumber || '—'} • {hookMarket?.positionsTotal || 0} positions
                        {hookMarket?.resolved ? ' • ✅ Resolved' : hookMarket?.assertionPending ? ' • ⏳ Assertion Pending' : hookFrozen ? ' • 🔒 Disputed' : ' • 🟢 Trading'}
                      </p>
                    </div>
                    <div className="text-right">
                      <p className="text-sm font-bold">${formatNumber(hookMarket?.totalCapital || 0, 2)}</p>
                      <p className="text-xs text-gray-500">Total Capital</p>
                    </div>
                  </div>

                  {/* Sub-tabs */}
                  <div className="flex gap-1 p-1 rounded-lg bg-white/5">
                    {(['overview', 'order', 'position'] as const).map((tab) => (
                      <button
                        key={tab}
                        onClick={() => setHookSubTab(tab as any)}
                        className={`flex-1 py-1.5 rounded text-xs font-medium capitalize transition-all ${
                          hookSubTab === tab ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
                        }`}
                      >
                        {tab === 'overview' ? '📊 Prices' : tab === 'order' ? '📝 Order' : '💼 Position'}
                      </button>
                    ))}
                  </div>

                  {/* OVERVIEW — LMSR prices + capital per side */}
                  {hookSubTab === 'overview' && (
                    <div className="space-y-3">
                      {hookPrices.length > 0 ? (
                        <div className="space-y-2">
                          {hookPrices.map((price, i) => {
                            const label = sideLabels[i] || `Side ${i}`
                            const capital = hookCapitals[i] || 0
                            const pct = (price * 100)
                            const isWinner = hookMarket?.resolved && hookMarket?.winningSide === i
                            return (
                              <div key={i} className={`p-3 rounded-xl border transition-all ${
                                isWinner ? 'bg-green-500/10 border-green-500/30' : 'bg-white/5 border-white/10'
                              }`}>
                                <div className="flex items-center justify-between mb-1">
                                  <span className="text-sm font-medium">
                                    {i === 0 ? '🛡️' : '⚠️'} {label}
                                    {isWinner && ' ✅'}
                                  </span>
                                  <span className="text-sm font-bold" style={{ color: pct > 20 && i > 0 ? '#f59e0b' : '#06b6d4' }}>
                                    {pct.toFixed(1)}%
                                  </span>
                                </div>
                                <div className="w-full h-2 rounded-full bg-white/10 overflow-hidden">
                                  <div
                                    className="h-full rounded-full transition-all"
                                    style={{
                                      width: `${Math.min(pct, 100)}%`,
                                      background: i === 0 ? '#06b6d4' : pct > 20 ? '#f59e0b' : '#3b82f6'
                                    }}
                                  />
                                </div>
                                <p className="text-xs text-gray-500 mt-1">${formatNumber(capital, 2)} capital</p>
                              </div>
                            )
                          })}
                        </div>
                      ) : (
                        <div className="text-center py-6 text-gray-500 text-sm">
                          {hookLoading ? 'Loading market data...' : 'No market data available'}
                        </div>
                      )}

                      {hookMarket?.roundStartTime > 0 && (
                        <div className="p-3 rounded-xl bg-white/5 border border-white/10">
                          <p className="text-xs text-gray-500">
                            Round started: {new Date(hookMarket.roundStartTime * 1000).toLocaleString()}
                          </p>
                          {hookMarket.resolved && hookMarket.resolutionTimestamp > 0 && (
                            <p className="text-xs text-gray-500">
                              Resolved: {new Date(hookMarket.resolutionTimestamp * 1000).toLocaleString()}
                            </p>
                          )}
                        </div>
                      )}
                    </div>
                  )}

                  {/* ORDER — Place order */}
                  {hookSubTab === 'order' && (
                    <div className="space-y-4">
                      {/* Side selector */}
                      <div>
                        <label className="text-xs text-gray-400 mb-2 block">Predict which (if any) stablecoin depegs</label>
                        <div className="grid grid-cols-3 gap-2">
                          {sideLabels.slice(0, hookMarket?.numSides || sideLabels.length).map((label, i) => (
                            <button
                              key={i}
                              onClick={() => setHookOrderSide(i)}
                              className={`p-2 rounded-lg text-xs font-medium border transition-all ${
                                hookOrderSide === i
                                  ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                                  : 'bg-white/5 border-white/10 text-gray-400 hover:border-white/20'
                              }`}
                            >
                              {i === 0 ? '🛡️' : '⚠️'} {label}
                              {hookPrices[i] !== undefined && (
                                <span className="block text-[10px] text-gray-500 mt-0.5">{(hookPrices[i] * 100).toFixed(1)}%</span>
                              )}
                            </button>
                          ))}
                        </div>
                      </div>

                      {/* Amount */}
                      <div>
                        <label className="text-xs text-gray-400 mb-1 block">Amount (QD)</label>
                        <div className="flex gap-2">
                          <input
                            type="number"
                            value={hookOrderAmount}
                            onChange={(e) => setHookOrderAmount(e.target.value)}
                            placeholder="100"
                            min="1"
                            className="flex-1 px-4 py-3 rounded-xl bg-white/5 border border-white/10 text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
                          />
                          {parseFloat(qdBalance) > 0 && (
                            <button
                              onClick={() => setHookOrderAmount((Number(qdBalance) / 1e18).toFixed(2))}
                              className="px-3 py-1 text-xs text-cyan-400 border border-cyan-500/30 rounded-lg hover:bg-cyan-500/10"
                            >
                              MAX
                            </button>
                          )}
                        </div>
                        <p className="text-xs text-gray-500 mt-1">QD Balance: {formatNumber(Number(qdBalance) / 1e18, 2)} • 4% fee on entry</p>
                      </div>

                      {/* Confidence slider */}
                      <div>
                        <div className="flex justify-between items-center mb-1">
                          <label className="text-xs text-gray-400">Confidence</label>
                          <span className="text-xs font-bold text-cyan-400">{(hookConfidence / 100).toFixed(0)}%</span>
                        </div>
                        <input
                          type="range"
                          min={100}
                          max={10000}
                          step={100}
                          value={hookConfidence}
                          onChange={(e) => setHookConfidence(parseInt(e.target.value))}
                          className="w-full"
                        />
                        <p className="text-xs text-gray-500 mt-1">Higher confidence = more weight if correct, less if wrong. Commit-reveal: hidden until resolution.</p>
                      </div>

                      {/* Auto rollover toggle */}
                      <div className="flex items-center justify-between p-3 rounded-xl bg-white/5 border border-white/10">
                        <div>
                          <p className="text-sm">Auto-rollover</p>
                          <p className="text-xs text-gray-500">Automatically re-enter next round (2% fee vs 4%)</p>
                        </div>
                        <button
                          onClick={() => setHookAutoRollover(!hookAutoRollover)}
                          className={`w-12 h-6 rounded-full transition-all ${hookAutoRollover ? 'bg-cyan-500' : 'bg-white/20'}`}
                        >
                          <div className={`w-5 h-5 rounded-full bg-white shadow transition-transform ${hookAutoRollover ? 'translate-x-6' : 'translate-x-0.5'}`} />
                        </button>
                      </div>

                      <button
                        onClick={placeHookOrder}
                        disabled={!connected || isLoading || !hookOrderAmount || parseFloat(hookOrderAmount) < 1 || txMutex || hookMarket?.resolved || hookFrozen || hookMarket?.assertionPending}
                        className="w-full py-3 rounded-xl font-bold bg-gradient-to-r from-purple-500 to-pink-600 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        {isLoading && activeTab === 'predictions' ? (txStatus || 'Processing...') : connected ? 'Place Order' : 'Connect Wallet'}
                      </button>

                      {(hookMarket?.resolved || hookFrozen || hookMarket?.assertionPending) && (
                        <p className="text-xs text-yellow-400 text-center">
                          {hookMarket?.resolved ? 'Market resolved — new orders disabled' : hookFrozen ? 'Market frozen — dispute in progress' : 'Assertion pending — sell only'}
                        </p>
                      )}
                    </div>
                  )}

                  {/* POSITION — View and manage positions */}
                  {hookSubTab === 'position' && (
                    <div className="space-y-3">
                      {Object.keys(hookPositions).length > 0 ? (
                        Object.entries(hookPositions).map(([sideStr, pos]) => {
                          const side = parseInt(sideStr)
                          const label = sideLabels[side] || `Side ${side}`
                          const isStale = hookMarket && pos.lastRound < hookMarket.roundNumber

                          // Load stored confidence from localStorage (pre-reveal)
                          const storedEntries = address && chainId ? getStoredConfidences(chainId, MARKET_ID, side, address) : []
                          const avgStoredConf = getAverageStoredConfidence(storedEntries)

                          // Compute expected payout
                          const mySideCapital = hookCapitals[side] || 0
                          const totalCap = hookMarket?.totalCapital || 0
                          const displayConf = pos.revealed ? pos.revealedConfidence : avgStoredConf
                          const payout = estimateExpectedPayout(pos.totalCapital, mySideCapital, totalCap, displayConf)

                          return (
                            <div key={side} className={`p-4 rounded-xl border ${isStale ? 'bg-yellow-500/5 border-yellow-500/20' : 'bg-white/5 border-white/10'}`}>
                              <div className="flex items-center justify-between mb-2">
                                <span className="text-sm font-medium">{side === 0 ? '🛡️' : '⚠️'} {label}</span>
                                {isStale && <span className="text-xs text-yellow-400 px-2 py-0.5 rounded bg-yellow-500/10">Stale</span>}
                                {pos.revealed && <span className="text-xs text-green-400 px-2 py-0.5 rounded bg-green-500/10">Revealed</span>}
                                {pos.paidOut && <span className="text-xs text-cyan-400 px-2 py-0.5 rounded bg-cyan-500/10">Paid</span>}
                              </div>
                              <div className="grid grid-cols-2 gap-2 text-xs">
                                <div>
                                  <span className="text-gray-500">Capital:</span>
                                  <span className="ml-1 text-white">${formatNumber(pos.totalCapital, 2)}</span>
                                </div>
                                <div>
                                  <span className="text-gray-500">Tokens:</span>
                                  <span className="ml-1 text-white">{formatNumber(pos.totalTokens, 2)}</span>
                                </div>

                                {/* Confidence — revealed or from localStorage */}
                                {pos.revealed ? (
                                  <div>
                                    <span className="text-gray-500">Confidence:</span>
                                    <span className="ml-1 text-green-400">{(pos.revealedConfidence / 100).toFixed(0)}% ✓</span>
                                  </div>
                                ) : avgStoredConf !== null ? (
                                  <div>
                                    <span className="text-gray-500">Confidence:</span>
                                    <span className="ml-1 text-yellow-400" title={`${storedEntries.length} commit(s) stored locally`}>
                                      ~{(avgStoredConf / 100).toFixed(0)}% 🔒
                                    </span>
                                  </div>
                                ) : (
                                  <div>
                                    <span className="text-gray-500">Confidence:</span>
                                    <span className="ml-1 text-gray-600">hidden</span>
                                  </div>
                                )}

                                <div>
                                  <span className="text-gray-500">Rollover:</span>
                                  <span className="ml-1 text-white">{pos.autoRollover ? 'Yes' : 'No'}</span>
                                </div>
                              </div>

                              {/* Expected payout estimate */}
                              {!isStale && !pos.paidOut && totalCap > 0 && mySideCapital > 0 && (
                                <div className="mt-2 p-2 rounded-lg bg-white/[0.03] border border-white/5">
                                  <p className="text-[10px] text-gray-500 mb-1">If {label} wins:</p>
                                  <div className="flex items-baseline gap-2">
                                    <span className="text-sm font-bold text-emerald-400">
                                      ≈ ${formatNumber(payout.adjusted !== null ? payout.adjusted : payout.base, 2)}
                                    </span>
                                    <span className="text-[10px] text-gray-500">
                                      ({((payout.adjusted !== null ? payout.adjusted : payout.base) / pos.totalCapital * 100 - 100).toFixed(0)}% return)
                                    </span>
                                  </div>
                                  {payout.adjusted !== null && Math.abs(payout.adjusted - payout.base) > 0.01 && (
                                    <p className="text-[10px] text-gray-600 mt-0.5">
                                      Proportional: ${formatNumber(payout.base, 2)} • Conf-adjusted: ${formatNumber(payout.adjusted, 2)}
                                    </p>
                                  )}
                                  <p className="text-[10px] text-gray-600 mt-0.5">
                                    Pool: ${formatNumber(totalCap, 0)} total • ${formatNumber(mySideCapital, 0)} on {label}
                                  </p>
                                </div>
                              )}

                              {/* Sell controls (only if not stale and market not resolved) */}
                              {!isStale && !hookMarket?.resolved && (
                                <div className="mt-3 flex gap-2">
                                  <input
                                    type="number"
                                    value={hookOrderSide === side ? hookSellTokens : ''}
                                    onChange={(e) => { setHookOrderSide(side); setHookSellTokens(e.target.value) }}
                                    placeholder="Tokens to sell"
                                    className="flex-1 px-3 py-2 rounded-lg bg-white/5 border border-white/10 text-xs text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
                                  />
                                  <button
                                    onClick={() => { setHookOrderSide(side); sellHookPosition() }}
                                    disabled={!hookSellTokens || parseFloat(hookSellTokens) <= 0 || txMutex || hookFrozen}
                                    className="px-3 py-2 text-xs rounded-lg bg-red-500/20 text-red-400 border border-red-500/30 hover:bg-red-500/30 disabled:opacity-50"
                                  >
                                    Sell
                                  </button>
                                </div>
                              )}

                              {/* Stale actions */}
                              {isStale && (
                                <div className="mt-3">
                                  {pos.autoRollover ? (
                                    <button
                                      onClick={() => { setHookOrderSide(side); recommitHookPosition() }}
                                      disabled={txMutex || hookMarket?.resolved || hookMarket?.assertionPending}
                                      className="w-full px-3 py-2 text-xs rounded-lg bg-cyan-500/20 text-cyan-400 border border-cyan-500/30 hover:bg-cyan-500/30 disabled:opacity-50"
                                    >
                                      Recommit
                                    </button>
                                  ) : (
                                    <p className="text-xs text-yellow-400/70 text-center">
                                      ⏳ Capital will be returned automatically during next payout cycle
                                    </p>
                                  )}
                                </div>
                              )}
                            </div>
                          )
                        })
                      ) : (
                        <div className="text-center py-8 text-gray-500 text-sm">
                          {connected ? 'No positions found for this market' : 'Connect wallet to view positions'}
                        </div>
                      )}
                    </div>
                  )}


                </>
              )}
            </div>
          )}
        </div>

        {/* Contract Info */}
        <div className="mt-8 p-4 rounded-xl bg-white/5 border border-white/10">
          <p className="text-xs text-gray-500 mb-2">Contract Addresses ({chain.name})</p>
          <div className="grid grid-cols-2 gap-2 text-xs">
            {[
              { label: 'Basket (QD)', addr: contracts.basket },
              { label: protocol === 'v4' ? 'Vogue' : 'Rover', addr: protocol === 'v4' ? contracts.vogue : contracts.rover },
              { label: 'VogueCore', addr: contracts.vogueCore },
              { label: 'Aux', addr: contracts.aux },
              { label: 'Amp', addr: contracts.amp },
              { label: 'Hook', addr: contracts.hook },
              { label: 'UMA', addr: contracts.uma },
            ].filter(c => c.addr && c.addr !== '0x0000000000000000000000000000000000000000').map(({ label, addr }) => (
              <div key={label} className="flex justify-between">
                <span className="text-gray-400">{label}:</span>
                <a
                  href={`${chain.explorer}/address/${addr}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-cyan-400 hover:underline"
                >
                  {shortenAddress(addr)}
                </a>
              </div>
            ))}
          </div>
        </div>

        {/* Waiver Modal — must be signed before minting */}
        {showWaiver && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80" onClick={() => setShowWaiver(false)}>
            <div className="relative w-full max-w-2xl max-h-[90vh] bg-[#111318] border border-gray-700 rounded-xl overflow-hidden flex flex-col" onClick={(e) => e.stopPropagation()}>
              <div className="px-6 pt-5 pb-3 border-b border-gray-700 flex items-center justify-between">
                <h2 className="text-lg font-semibold text-white">Smart Contract Usage Waiver and Release</h2>
                <button onClick={() => { setShowWaiver(false); setWaiverChecked(false); }} className="text-gray-400 hover:text-white text-xl">×</button>
              </div>
              <div className="flex-1 overflow-y-auto px-6 py-4 text-sm text-gray-300 space-y-4 leading-relaxed">
                <p>By checking the box below, I acknowledge, represent, warrant, and agree to the following terms before using the smart contract (&quot;Contract&quot;) served through this website:</p>
                <p><strong className="text-white">No Liability for Providers.</strong> I release and hold harmless the authors, developers, deployers, operators, and affiliates of the Contract (the &quot;Providers&quot;) from all claims, losses, damages, or liabilities related to my use, including smart contract failures, financial losses, or blockchain risks. After funding its cost of doing business, there is no profit retainer for the creators—the Providers provide the Contract strictly at cost.</p>
                <p><strong className="text-white">Full Assumption of Risks.</strong> Blockchain and smart contracts carry high risks of total fund loss. I assume all such risks voluntarily. No warranties are made regarding security, performance, or results.</p>
                <div>
                  <p className="text-white font-medium mb-2">My Representations:</p>
                  <p className="ml-4">• I am at least 18 years old and legally competent.</p>
                  <p className="ml-4">• I am not on any OFAC sanctions lists, blocked persons lists, or equivalent.</p>
                  <p className="ml-4">• I am not in any OFAC-sanctioned country (e.g., Cuba, Iran, North Korea, Syria, Crimea).</p>
                  <p className="ml-4">• My use complies with all laws.</p>
                </div>
                <p><strong className="text-white">Indemnification.</strong> I will defend and indemnify the Providers against any claims from my use or breach.</p>
                <p>This is governed by Cayman law. Checking confirms I understand and agree.</p>
              </div>
              <div className="px-6 py-4 border-t border-gray-700 space-y-3">
                <label className="flex items-start gap-3 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={waiverChecked}
                    onChange={(e) => setWaiverChecked(e.target.checked)}
                    className="mt-0.5 w-5 h-5 rounded border-gray-600 bg-gray-800 text-cyan-500 focus:ring-cyan-500 focus:ring-offset-0 cursor-pointer accent-cyan-500"
                  />
                  <span className="text-sm text-gray-200">I agree to the above Waiver and Release of Liability</span>
                </label>
                <button
                  onClick={() => {
                    if (waiverChecked) {
                      setWaiverAccepted(true)
                      setShowWaiver(false)
                    }
                  }}
                  disabled={!waiverChecked}
                  className={`w-full py-3 rounded-lg font-semibold text-sm transition-all ${
                    waiverChecked
                      ? 'bg-gradient-to-r from-cyan-500 to-blue-500 text-white hover:shadow-lg hover:shadow-cyan-500/25'
                      : 'bg-gray-700 text-gray-500 cursor-not-allowed'
                  }`}
                >
                  Accept & Continue
                </button>
              </div>
            </div>
          </div>
        )}

        {/* About Us Modal */}
        {showAboutModal && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80" onClick={() => setShowAboutModal(false)}>
            <div className="relative max-w-4xl max-h-[90vh] overflow-auto" onClick={(e) => e.stopPropagation()}>
              <button
                onClick={() => setShowAboutModal(false)}
                className="absolute top-2 right-2 z-10 w-10 h-10 rounded-full bg-black/50 text-white hover:bg-black/70 flex items-center justify-center text-2xl"
              >
                ×
              </button>
              <img
                src="/how-it-works.png"
                alt="How QU!D Protocol Works"
                className="rounded-lg"
              />
            </div>
          </div>
        )}

        <footer className="mt-8 text-center text-xs text-gray-500 space-y-2">
          <p>QU!D Protocol • Stablecoin Infrastructure</p>
          <div className="flex justify-center gap-4">
            <a href="https://gitlab.com/quidmint/quid" target="_blank" rel="noopener noreferrer" className="text-cyan-400 hover:underline">GitLab</a>
            <span>•</span>
            <a href="https://x.com/QuidMint" target="_blank" rel="noopener noreferrer" className="text-cyan-400 hover:underline">𝕏 @QuidMint</a>
            <span>•</span>
            <button onClick={() => setShowAboutModal(true)} className="text-cyan-400 hover:underline cursor-pointer">About Us</button>
          </div>
          <p className="text-gray-600 mt-3">
            QuidMint Foundation<br />
            PO Box 144, 3119 9 Forum Lane, Camana Bay,<br />
            George Town, Grand Cayman, Cayman Islands KY1-9006
          </p>
        </footer>
      </div>
    </div>
  )
}
