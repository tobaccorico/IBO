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
  // Aux leverage functions
  'function leverETH(uint256 amount) payable',
  'function leverUSD(uint256 amount, address token)',
  // Aux metrics - total USD in basket and accumulated yield
  'function get_metrics(bool force) returns (uint256, uint256)',
  'function getAverageYield() view returns (uint256)',
  'function getFee(address token) view returns (uint256)',
  // VogueCore - POOLED_ETH
  'function POOLED_ETH() view returns (uint256)',
  // Vogue metrics
  'function totalShares() view returns (uint256)',
  'function YIELD() view returns (uint256)',
  'function ETH_FEES() view returns (uint256)',
  'function USD_FEES() view returns (uint256)',
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
const encodePooledETH = () => iface.encodeFunctionData('POOLED_ETH', [])
const encodeLeverETH = (amount: bigint) => iface.encodeFunctionData('leverETH', [amount])
const encodeLeverUSD = (amount: bigint, token: string) => iface.encodeFunctionData('leverUSD', [amount, token])
// Metrics functions
const encodeGetMetrics = (force: boolean) => iface.encodeFunctionData('get_metrics', [force])
const encodeGetAverageYield = () => iface.encodeFunctionData('getAverageYield', [])
const encodeGetFee = (token: string) => iface.encodeFunctionData('getFee', [token])
const encodeTotalShares = () => iface.encodeFunctionData('totalShares', [])
const encodeYield = () => iface.encodeFunctionData('YIELD', [])
const encodeETHFees = () => iface.encodeFunctionData('ETH_FEES', [])
const encodeUSDFees = () => iface.encodeFunctionData('USD_FEES', [])

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
  const [chainId, setChainId] = useState(1) // Default to Ethereum L1
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
  const [maturityMonths, setMaturityMonths] = useState(1)
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

  // QD token state
  const [qdBalance, setQdBalance] = useState('0')
  const [redeemAmount, setRedeemAmount] = useState('')
  const [matureQdBalance, setMatureQdBalance] = useState('0') // For future redeem gating
  
  // UI state
  const [showAboutModal, setShowAboutModal] = useState(false)
  const [aboutPage, setAboutPage] = useState(0) // 0 = first diagram, 1 = second

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
  const [ethPrice, setEthPrice] = useState(3500)
  const [basketMetrics, setBasketMetrics] = useState({ total: 0, yield: 0, avgYield: 0 }) // USD in basket
  const [ethMetrics, setEthMetrics] = useState({ totalShares: 0, ethFees: 0, usdFees: 0 }) // ETH LP metrics
  const [tvl, setTvl] = useState({ v3: 0, v4: 0 })

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

    try {
      for (const token of stables) {
        // Get balance
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
    } catch (e) {
      console.error('Error fetching balances:', e)
    } finally {
      setLoadingBalances(false)
    }
  }, [address, stables, contracts.aux, contracts.basket, contracts.weth, selectedToken])

  // Fetch ETH price and TVL from contracts
  useEffect(() => {
    const fetchMetrics = async () => {
      if (!window.ethereum) return
      
      let auxTvl = 0
      let vogueTvl = 0
      let price = 3500 // fallback
      
      // Fetch ETH price from Aux.getTWAP(1800) - returns price in WAD (1e18)
      if (contracts.aux && contracts.aux !== '0x0000000000000000000000000000000000000000') {
        try {
          const twapResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.aux, data: encodeGetTWAP(1800) }, 'latest'],
          })
          const priceWad = BigInt(twapResult)
          price = Number(priceWad) / 1e18
          console.log('ETH Price from TWAP:', price)
          setEthPrice(price)
        } catch (e) {
          console.log('Could not fetch TWAP price:', e)
        }
        
        // Fetch Basket metrics via get_metrics(false) → returns (total, yield)
        // Note: get_metrics is not a view function, so we use eth_call which simulates the transaction
        try {
          const metricsResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.aux, data: encodeGetMetrics(false) }, 'latest'],
          })
          // Decode tuple - first 32 bytes is total, next 32 is yield
          const total = BigInt('0x' + metricsResult.slice(2, 66))
          const yieldVal = BigInt('0x' + metricsResult.slice(66, 130))
          auxTvl = Number(total) / 1e18
          const yieldUsd = Number(yieldVal) / 1e18
          console.log('Basket Total (USD):', auxTvl, 'Yield:', yieldUsd)
          
          // Fetch average yield APY
          let avgYield = 0
          try {
            const yieldResult = await window.ethereum.request({
              method: 'eth_call',
              params: [{ to: contracts.aux, data: encodeGetAverageYield() }, 'latest'],
            })
            avgYield = Number(BigInt(yieldResult)) / 1e16 // Convert from WAD basis to %
            console.log('Basket Average Yield APY:', avgYield, '%')
          } catch (e) {
            console.log('Could not fetch average yield:', e)
          }
          
          setBasketMetrics({ total: auxTvl, yield: yieldUsd, avgYield })
        } catch (e) {
          console.log('Could not fetch Basket metrics:', e)
        }
      }
      
      // Fetch Vogue TVL and yield metrics
      if (contracts.vogueCore && contracts.vogueCore !== '0x0000000000000000000000000000000000000000') {
        try {
          const pooledResult = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: contracts.vogueCore, data: encodePooledETH() }, 'latest'],
          })
          const pooledEthWei = BigInt(pooledResult)
          const pooledEth = Number(pooledEthWei) / 1e18
          vogueTvl = pooledEth * price
          console.log('Vogue POOLED_ETH:', pooledEth, 'TVL (USD):', vogueTvl)
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
          const totalShares = Number(BigInt(sharesResult)) / 1e18
          const ethFees = Number(BigInt(ethFeesResult)) / 1e18
          const usdFees = Number(BigInt(usdFeesResult)) / 1e18
          console.log('Vogue totalShares:', totalShares, 'ETH_FEES:', ethFees, 'USD_FEES:', usdFees)
          setEthMetrics({ totalShares, ethFees, usdFees })
        } catch (e) {
          console.log('Could not fetch Vogue fee metrics:', e)
        }
      }
      
      // v3 shows Aux USD TVL, v4 shows Vogue ETH TVL (converted to USD)
      setTvl({ 
        v3: auxTvl > 0 ? auxTvl : 0, 
        v4: vogueTvl > 0 ? vogueTvl : 0 
      })
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

          const balance = await window.ethereum.request({
            method: 'eth_getBalance',
            params: [accounts[0], 'latest'],
          })
          setEthBalance((parseInt(balance, 16) / 1e18).toFixed(4))

          const currentChainId = await window.ethereum.request({ method: 'eth_chainId' })
          const numericChainId = parseInt(currentChainId, 16)
          if (CHAINS[numericChainId]?.enabled) {
            setChainId(numericChainId)
          } else {
            setChainId(8453) // Default to Base if current chain is disabled
          }
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

      const handleChainChanged = (newChainId: string) => {
        const numericChainId = parseInt(newChainId, 16)
        if (CHAINS[numericChainId]?.enabled) {
          setChainId(numericChainId)
          setSelectedToken(null)
          setTokenBalances({})
          setTokenAllowances({})
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
  }, [selectedToken, mintAmount, contracts.basket, contracts.aux, address, currentMonth, maturityMonths, chainId, fetchBalances, txMutex])

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

  /* REDEEM COMMENTED OUT - Waiting for totalMatureBalanceOf contract function
  // Redeem QD tokens for stablecoins
  const redeemQD = useCallback(async () => {
    if (!redeemAmount || !connected || !contracts.aux) return
    if (BigInt(matureQdBalance) <= 0n) return // Only allow if mature balance exists
    if (txMutex) return
    
    setTxMutex(true)
    setIsLoading(true)
    setError(null)
    setTxHash(null)
    setTxStatus('Redeeming QD tokens...')

    try {
      const amount = ethers.parseUnits(redeemAmount, 18) // QD is 18 decimals
      
      console.log('=== REDEEM DEBUG ===')
      console.log('Aux contract:', contracts.aux)
      console.log('Amount:', redeemAmount, 'QD')
      console.log('Amount (wei):', amount.toString())

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
      
      // Refresh balances after delay
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
  }, [redeemAmount, connected, contracts.aux, address, txMutex, fetchBalances, matureQdBalance])
  END REDEEM COMMENT */

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

        {/* Stats Cards - Only show when we have data */}
        {(tvl[protocol] > 0 || basketMetrics.avgYield > 0 || ethMetrics.totalShares > 0) && (
        <div className="grid grid-cols-4 gap-4 mb-8">
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">
              {protocol === 'v3' ? 'Basket TVL' : 'ETH Pool TVL'}
            </p>
            <p className="text-2xl font-bold">
              {tvl[protocol] >= 1000000 
                ? `$${formatNumber(tvl[protocol] / 1e6, 2)}M`
                : tvl[protocol] >= 1000
                  ? `$${formatNumber(tvl[protocol] / 1e3, 2)}K`
                  : `$${formatNumber(tvl[protocol], 2)}`
              }
            </p>
          </div>
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">
              {protocol === 'v3' ? 'USD Yield' : 'ETH Yield'}
            </p>
            <p className="text-2xl font-bold text-green-400">
              {protocol === 'v3' 
                ? `${basketMetrics.avgYield.toFixed(2)}%`
                : `${((ethMetrics.ethFees / ethMetrics.totalShares) * 100).toFixed(2)}%`
              }
            </p>
          </div>
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">
              {protocol === 'v3' ? 'Basket Yield' : 'Swap Fees'}
            </p>
            <p className="text-xl font-bold text-cyan-400">
              {protocol === 'v3' 
                ? `$${formatNumber(basketMetrics.yield, 2)}`
                : `$${formatNumber(ethMetrics.usdFees * ethPrice + ethMetrics.ethFees, 2)}`
              }
            </p>
          </div>
          <div className="p-4 rounded-xl bg-white/5 border border-white/10">
            <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">ETH Price</p>
            <p className="text-2xl font-bold">${formatNumber(ethPrice, 0)}</p>
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
              {tab === 'mint' ? 'Mint QD' : tab === 'predictions' ? '📊 Markets' : tab}
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

                    <div className="mt-4 pt-4 border-t border-white/5 grid grid-cols-2 gap-4">
                      <div>
                        <p className="text-xs text-gray-500 mb-1">Redeemable</p>
                        <p className="text-sm font-medium text-white">{maturityDate}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500 mb-1">Yield Bonus</p>
                        <p className="text-sm font-medium text-green-400">
                          +{(((maturityMonths + 1) / 12) * (basketMetrics.avgYield || 10)).toFixed(2)}%
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
                      <p className="mt-3 text-xs text-purple-400/80">🌱 For seed investors that receive a 3x ROI on their $</p>
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

              {/* REDEEM UI COMMENTED OUT - Waiting for totalMatureBalanceOf contract function
              Redeem Section - Only shows when user has mature QD balance
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
                    {isLoading && txStatus?.includes('Redeem') ? (txStatus || 'Processing...') : 'Redeem for Stablecoins'}
                  </button>
                  <p className="mt-2 text-xs text-gray-500 text-center">
                    Only mature QD tokens can be redeemed. Immature tokens will remain in your wallet.
                  </p>
                </div>
              )}
              END REDEEM UI COMMENT */}

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
            </div>
          )}

          {/* WITHDRAW TAB */}
          {activeTab === 'withdraw' && (
            <div className="space-y-6">
              <div>
                <label className="block text-sm text-gray-400 mb-2">Withdraw Amount (ETH)</label>
                <div className="relative">
                  <input
                    type="number"
                    value={withdrawAmount}
                    onChange={(e) => setWithdrawAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                  />
                  <button className="absolute right-3 top-1/2 -translate-y-1/2 px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20">
                    MAX
                  </button>
                </div>
                <p className="mt-2 text-sm text-gray-500">Deposited: 0.00 ETH</p>
              </div>

              <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Pending ETH Rewards</span>
                  <span className="text-green-400">+0.00 ETH</span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">Pending USD Rewards</span>
                  <span className="text-green-400">+$0.00 (as QD)</span>
                </div>
              </div>

              <button
                onClick={withdrawETH}
                disabled={!connected || isLoading || !withdrawAmount || txMutex}
                className="w-full py-4 rounded-xl bg-gradient-to-r from-orange-500 to-red-500 font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50"
              >
                {isLoading && activeTab === 'withdraw' ? (txStatus || 'Processing...') : 'Withdraw'}
              </button>
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
                <div className="grid grid-cols-4 gap-2">
                  {stables.filter(t => !t.isVault).slice(0, 8).map((token) => {
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
                    <span className="text-green-400">Higher than instant (if favorable)</span>
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
            <div className="space-y-6">
              <div className="text-center py-12">
                <div className="text-6xl mb-4">🚀</div>
                <h3 className="text-2xl font-bold mb-2">Prediction Markets</h3>
                <p className="text-gray-400 mb-6 max-w-md mx-auto">
                  Trade on outcomes of real-world events. Stocks, crypto, sports, elections, and more.
                </p>
                <div className="inline-block px-6 py-3 rounded-xl bg-gradient-to-r from-purple-500/20 to-pink-500/20 border border-purple-500/30">
                  <p className="text-purple-400 font-medium">Deploying Soon</p>
                </div>
              </div>
              
              <div className="grid grid-cols-2 gap-4">
                <div className="p-4 rounded-xl bg-white/5 border border-white/10">
                  <p className="text-sm text-gray-400 mb-2">📈 Stocks & Indices</p>
                  <p className="text-xs text-gray-500">Trade on price movements of major stocks and indices</p>
                </div>
                <div className="p-4 rounded-xl bg-white/5 border border-white/10">
                  <p className="text-sm text-gray-400 mb-2">🏆 Sports</p>
                  <p className="text-xs text-gray-500">Bet on game outcomes, player stats, and tournaments</p>
                </div>
                <div className="p-4 rounded-xl bg-white/5 border border-white/10">
                  <p className="text-sm text-gray-400 mb-2">🗳️ Politics</p>
                  <p className="text-xs text-gray-500">Trade on election results and policy decisions</p>
                </div>
                <div className="p-4 rounded-xl bg-white/5 border border-white/10">
                  <p className="text-sm text-gray-400 mb-2">🌐 World Events</p>
                  <p className="text-xs text-gray-500">Predict outcomes of major global events</p>
                </div>
              </div>
              
              <div className="p-4 rounded-xl bg-cyan-500/10 border border-cyan-500/20 text-center">
                <p className="text-sm text-cyan-400">
                  💡 Prediction markets will use QUID as the settlement currency with LMSR pricing
                </p>
              </div>
            </div>
          )}
        </div>

        {/* Contract Info */}
        <div className="mt-8 p-4 rounded-xl bg-white/5 border border-white/10">
          <p className="text-xs text-gray-500 mb-2">Contract Addresses ({chain.name})</p>
          <div className="grid grid-cols-2 gap-2 text-xs">
            <div className="flex justify-between">
              <span className="text-gray-400">Basket (QD):</span>
              <a
                href={`${chain.explorer}/address/${contracts.basket}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-cyan-400 hover:underline"
              >
                {shortenAddress(contracts.basket)}
              </a>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">{protocol === 'v4' ? 'Vogue' : 'Rover'}:</span>
              <a
                href={`${chain.explorer}/address/${protocol === 'v4' ? contracts.vogue : contracts.rover}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-cyan-400 hover:underline"
              >
                {shortenAddress(protocol === 'v4' ? contracts.vogue : contracts.rover)}
              </a>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Aux:</span>
              <a
                href={`${chain.explorer}/address/${contracts.aux}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-cyan-400 hover:underline"
              >
                {shortenAddress(contracts.aux)}
              </a>
            </div>
          </div>
        </div>

        {/* About Us Modal */}
        {showAboutModal && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80" onClick={() => { setShowAboutModal(false); setAboutPage(0); }}>
            <div className="relative max-w-4xl max-h-[90vh] overflow-auto" onClick={(e) => e.stopPropagation()}>
              <button 
                onClick={() => { setShowAboutModal(false); setAboutPage(0); }}
                className="absolute top-2 right-2 z-10 w-10 h-10 rounded-full bg-black/50 text-white hover:bg-black/70 flex items-center justify-center text-2xl"
              >
                ×
              </button>
              <img 
                src={aboutPage === 0 ? "/how-it-works.png" : "/how-it-works-2.png"} 
                alt="How QU!D Protocol Works" 
                className="rounded-lg" 
              />
              {/* Pagination Controls */}
              <div className="absolute bottom-4 left-1/2 -translate-x-1/2 flex items-center gap-4 bg-black/70 px-4 py-2 rounded-full">
                <button 
                  onClick={() => setAboutPage(0)}
                  disabled={aboutPage === 0}
                  className="w-8 h-8 rounded-full bg-white/10 hover:bg-white/20 disabled:opacity-30 disabled:cursor-not-allowed flex items-center justify-center"
                >
                  ←
                </button>
                <span className="text-white text-sm">{aboutPage + 1} / 2</span>
                <button 
                  onClick={() => setAboutPage(1)}
                  disabled={aboutPage === 1}
                  className="w-8 h-8 rounded-full bg-white/10 hover:bg-white/20 disabled:opacity-30 disabled:cursor-not-allowed flex items-center justify-center"
                >
                  →
                </button>
              </div>
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
