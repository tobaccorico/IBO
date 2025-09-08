import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { MetaMaskInpageProvider } from "@metamask/providers";

declare global {
  interface Window {
    ethereum?: MetaMaskInpageProvider;
  }
}

// Contract addresses
const ROUTER_ADDRESS = "0x7bAe2554ED287380941B1706DC8cFf665137ca58";
const AUX_ADDRESS = "0x2Ce5CfbA940b8e8791864307413bA1334BBd0CD1";

// ABIs
const ROUTER_ABI = [
  "function depositS(uint256 amount) payable",
  "function withdraw(uint256 amount) payable",
  "function fetch(address beneficiary) view returns (tuple(uint256 fees_S, uint256 fees_usd, uint128 liq), uint256, uint160)",
  "function getPrice(uint160 sqrtRatioX96) view returns (uint256)",
  "function wS() view returns (address)",
  "function USDC() view returns (address)",
  "function setupAux(address _aux)",
  "function repackNFT() returns (uint160)"
];

const AUX_ABI = [
  "function leverZeroForOne(uint256 amount) payable",
  "function leverOneForZero(uint256 amount) payable",
  "event LeveragedPositionOpened(address indexed user, bool indexed isLong, uint256 supplied, uint256 borrowed, uint256 buffer, int256 entryPrice, uint256 breakeven, uint256 blockNumber)",
  "event PositionUnwound(address indexed user, bool indexed isLong, int256 exitPrice, int256 priceDelta, uint256 blockNumber)"
];

const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function transferFrom(address from, address to, uint256 amount) returns (bool)"
];

const WETH_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function transferFrom(address from, address to, uint256 amount) returns (bool)",
  "function deposit() payable",
  "function withdraw(uint256 amount)"
];

// Combined contracts state interface
interface ContractsState {
  router: ethers.Contract | null;
  aux: ethers.Contract | null;
  wS: ethers.Contract | null;
  usdc: ethers.Contract | null;
}

function App() {
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.JsonRpcSigner | null>(null);
  const [account, setAccount] = useState<string>('');
  const [chainId, setChainId] = useState<number>(0);
  
  // Single state for all contracts to ensure atomic updates
  const [contracts, setContracts] = useState<ContractsState>({
    router: null,
    aux: null,
    wS: null,
    usdc: null
  });
  
  // Balances
  const [ethBalance, setEthBalance] = useState<string>('0');
  const [wSBalance, setWSBalance] = useState<string>('0');
  const [usdcBalance, setUsdcBalance] = useState<string>('0');
  const [depositInfo, setDepositInfo] = useState<any>(null);
  
  // UI State
  const [loading, setLoading] = useState<boolean>(false);
  const [txStatus, setTxStatus] = useState<string>('');
  const [activeTab, setActiveTab] = useState<string>('deposit');
  
  // Form values
  const [depositAmount, setDepositAmount] = useState<string>('');
  const [withdrawPercent, setWithdrawPercent] = useState<string>('100');
  const [leverageAmount, setLeverageAmount] = useState<string>('');
  const [leverageType, setLeverageType] = useState<string>('long');
  
  // Leverage positions
  const [positions, setPositions] = useState<any[]>([]);

  // Connect wallet
  const connectWallet = async () => {
    try {
      if (!window.ethereum) {
        alert('Please install MetaMask!');
        return;
      }

      const newProvider = new ethers.BrowserProvider(window.ethereum);
      await newProvider.send("eth_requestAccounts", []);
      const newSigner = await newProvider.getSigner();
      const address = await newSigner.getAddress();
      const network = await newProvider.getNetwork();
      
      console.log('Wallet connected:', address);
      console.log('Network:', network.chainId, network.name);
      
      // Check if on Sonic network (chain ID 146)
      if (Number(network.chainId) !== 146) {
        setTxStatus('Please switch to Sonic network (Chain ID: 146)');
        
        // Try to switch to Sonic
        try {
          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: '0x92' }], // 146 in hex
          });
        } catch (switchError: any) {
          // This error code indicates that the chain has not been added to MetaMask
          if (switchError.code === 4902) {
            try {
              await window.ethereum.request({
                method: 'wallet_addEthereumChain',
                params: [{
                  chainId: '0x92',
                  chainName: 'Sonic',
                  nativeCurrency: {
                    name: 'Sonic',
                    symbol: 'S',
                    decimals: 18
                  },
                  rpcUrls: ['https://rpc.soniclabs.com'],
                  blockExplorerUrls: ['https://sonicscan.org']
                }],
              });
            } catch (addError) {
              console.error('Error adding Sonic network:', addError);
              setTxStatus('Failed to add Sonic network. Please add it manually.');
              return;
            }
          } else {
            console.error('Error switching network:', switchError);
            return;
          }
        }
        
        // Re-fetch network after switch
        const updatedNetwork = await newProvider.getNetwork();
        setChainId(Number(updatedNetwork.chainId));
      } else {
        setChainId(Number(network.chainId));
      }

      setProvider(newProvider);
      setSigner(newSigner);
      setAccount(address);

      // Initialize contracts
      const router = new ethers.Contract(ROUTER_ADDRESS, ROUTER_ABI, newSigner);
      const aux = new ethers.Contract(AUX_ADDRESS, AUX_ABI, newSigner);
      
      try {
        // Get token addresses from router
        const wSAddress = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
        const usdcAddress = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
        
        console.log('Router address:', ROUTER_ADDRESS);
        console.log('AUX address:', AUX_ADDRESS);
        console.log('wS address:', wSAddress);
        console.log('USDC address:', usdcAddress);
        
        // Check if we can call router functions
        try {
          const price = await router.getPrice("0x" + "0".repeat(38) + "1");
          console.log('Router getPrice test successful, price:', price.toString());
        } catch (e) {
          console.error('Router getPrice test failed:', e);
        }
        
        // Try to get router's state variables
        try {
          const routerWSAddress = await router.wS();
          const routerUSDCAddress = await router.USDC();
          console.log('Router wS address from contract:', routerWSAddress);
          console.log('Router USDC address from contract:', routerUSDCAddress);
          
          // Use addresses from router if they exist
          const finalWSAddress = routerWSAddress || wSAddress;
          const finalUSDCAddress = routerUSDCAddress || usdcAddress;
          
          // Initialize token contracts with proper ABIs
          const wS = new ethers.Contract(finalWSAddress, WETH_ABI, newSigner);
          const usdc = new ethers.Contract(finalUSDCAddress, ERC20_ABI, newSigner);
          
          // Set all contracts at once
          setContracts({
            router,
            aux,
            wS,
            usdc
          });
          
          // Load balances
          await loadBalances(address, newProvider, wS, usdc, router);
          
          // Listen for position events
          setupEventListeners(aux, address);
          
          setTxStatus('Connected successfully!');
          
        } catch (routerError: any) {
          console.error('Router state check failed:', routerError);
          
          // Router might not be initialized, use default addresses
          const wS = new ethers.Contract(wSAddress, WETH_ABI, newSigner);
          const usdc = new ethers.Contract(usdcAddress, ERC20_ABI, newSigner);
          
          setContracts({
            router,
            aux,
            wS,
            usdc
          });
          
          await loadBalances(address, newProvider, wS, usdc, router);
          setupEventListeners(aux, address);
          
          setTxStatus('Connected (Router may need initialization)');
        }
        
      } catch (error: any) {
        console.error('Error initializing contracts:', error);
        setTxStatus(`Contract initialization error: ${error.message}`);
      }
      
    } catch (error: any) {
      console.error('Connection error:', error);
      setTxStatus(`Failed to connect: ${error.message}`);
    }
  };

  const loadBalances = async (
    address: string,
    provider: ethers.BrowserProvider,
    wS: ethers.Contract,
    usdc: ethers.Contract,
    router: ethers.Contract
  ) => {
    try {
      // Native S (ETH) balance
      const ethBal = await provider.getBalance(address);
      setEthBalance(ethers.formatEther(ethBal));
      
      // wS balance (wrapped S)
      try {
        const wSBal = await wS.balanceOf(address);
        setWSBalance(ethers.formatEther(wSBal));
      } catch (e) {
        console.log('wS balance error, setting to 0');
        setWSBalance('0');
      }
      
      // USDC balance
      try {
        const usdcBal = await usdc.balanceOf(address);
        setUsdcBalance(ethers.formatUnits(usdcBal, 6));
      } catch (e) {
        console.log('USDC balance error, setting to 0');
        setUsdcBalance('0');
      }
      
      // Deposit info from router
      try {
        const fetchResult = await router.fetch(address);
        // The result is a tuple: [Deposit struct, price, sqrtPrice]
        const deposit = fetchResult[0];
        const price = fetchResult[1];
        
        if (deposit && deposit.liq && deposit.liq > 0n) {
          setDepositInfo({
            liquidity: deposit.liq.toString(),
            feesS: ethers.formatEther(deposit.fees_S || 0n),
            feesUsd: ethers.formatUnits(deposit.fees_usd || 0n, 18),
            price: ethers.formatUnits(price || 0n, 18)
          });
        } else {
          setDepositInfo(null);
        }
      } catch (e) {
        console.log('No existing deposit found');
        setDepositInfo(null);
      }
    } catch (error) {
      console.error('Error loading balances:', error);
    }
  };

  const setupEventListeners = (aux: ethers.Contract, userAddress: string) => {
    // Remove old listeners first
    aux.removeAllListeners();
    
    // Listen for leverage positions
    aux.on('LeveragedPositionOpened', (user, isLong, supplied, borrowed, buffer, entryPrice, breakeven, blockNumber) => {
      if (user.toLowerCase() === userAddress.toLowerCase()) {
        const position = {
          isLong,
          supplied: ethers.formatEther(supplied),
          borrowed: ethers.formatEther(borrowed),
          entryPrice: ethers.formatUnits(entryPrice, 18),
          breakeven: ethers.formatUnits(breakeven, 18),
          block: blockNumber.toString(),
          timestamp: Date.now()
        };
        setPositions(prev => [...prev, position]);
        setTxStatus(`${isLong ? 'Long' : 'Short'} position opened at $${position.entryPrice}`);
      }
    });
    
    aux.on('PositionUnwound', (user, isLong, exitPrice, priceDelta, blockNumber) => {
      if (user.toLowerCase() === userAddress.toLowerCase()) {
        const delta = Number(priceDelta) / 10;
        setTxStatus(`Position unwound at $${ethers.formatUnits(exitPrice, 18)} (${delta > 0 ? '+' : ''}${delta.toFixed(1)}% change)`);
        setPositions(prev => prev.filter(p => p.isLong !== isLong));
      }
    });
  };

  // Deposit ETH to Router
  const handleDeposit = async () => {
    if (!contracts.router || !provider || !contracts.wS || !contracts.usdc) {
      setTxStatus('Please connect wallet first');
      return;
    }
    
    if (!depositAmount || parseFloat(depositAmount) <= 0) {
      setTxStatus('Please enter a valid amount');
      return;
    }
    
    setLoading(true);
    setTxStatus('Depositing S...');
    
    try {
      const amount = ethers.parseEther(depositAmount);
      
      // Check native balance
      const balance = await provider.getBalance(account);
      if (balance < amount) {
        throw new Error(`Insufficient S balance. Have: ${ethers.formatEther(balance)}, Need: ${depositAmount}`);
      }
      
      // The depositS function expects amount parameter and ETH in msg.value
      const tx = await contracts.router.depositS(0, { 
        value: amount,
        gasLimit: 500000 // Set explicit gas limit
      });
      
      setTxStatus('Transaction submitted...');
      const receipt = await tx.wait();
      
      if (receipt.status === 1) {
        setTxStatus('Deposit successful!');
        setDepositAmount('');
        
        // Reload balances
        await loadBalances(account, provider, contracts.wS, contracts.usdc, contracts.router);
      } else {
        throw new Error('Transaction failed');
      }
      
    } catch (error: any) {
      console.error('Deposit error:', error);
      if (error.code === 'INSUFFICIENT_FUNDS') {
        setTxStatus('Insufficient S balance for transaction');
      } else if (error.message?.includes('user rejected')) {
        setTxStatus('Transaction cancelled');
      } else {
        setTxStatus(`Error: ${error.message || 'Unknown error'}`);
      }
    } finally {
      setLoading(false);
    }
  };

  // Withdraw from Router
  const handleWithdraw = async () => {
    if (!contracts.router || !provider || !contracts.wS || !contracts.usdc) {
      setTxStatus('Please connect wallet first');
      return;
    }
    
    if (!withdrawPercent || !depositInfo) {
      setTxStatus('No deposit to withdraw');
      return;
    }
    
    setLoading(true);
    setTxStatus('Withdrawing...');
    
    try {
      // Convert percentage to basis points (multiply by 10)
      const percent = parseInt(withdrawPercent) * 10;
      
      const tx = await contracts.router.withdraw(percent, {
        gasLimit: 500000
      });
      
      setTxStatus('Transaction submitted...');
      const receipt = await tx.wait();
      
      if (receipt.status === 1) {
        setTxStatus('Withdrawal successful!');
        
        // Reload balances
        await loadBalances(account, provider, contracts.wS, contracts.usdc, contracts.router);
      } else {
        throw new Error('Transaction failed');
      }
      
    } catch (error: any) {
      console.error('Withdraw error:', error);
      setTxStatus(`Error: ${error.message || 'Unknown error'}`);
    } finally {
      setLoading(false);
    }
  };

  // Open leveraged position
  const handleLeverage = async () => {
    if (!contracts.aux || !contracts.wS || !contracts.usdc || !provider || !contracts.router) {
      setTxStatus('Please connect wallet first');
      return;
    }
    
    if (!leverageAmount || parseFloat(leverageAmount) <= 0) {
      setTxStatus('Please enter a valid amount');
      return;
    }
    
    setLoading(true);
    
    try {
      if (leverageType === 'long') {
        setTxStatus('Opening long position...');
        const amount = ethers.parseEther(leverageAmount);
        
        // Check wS balance
        const wSBalance = await contracts.wS.balanceOf(account);
        if (wSBalance < amount) {
          throw new Error(`Insufficient wS balance. Have: ${ethers.formatEther(wSBalance)}, Need: ${leverageAmount}`);
        }
        
        // Check and set approval
        const allowance = await contracts.wS.allowance(account, AUX_ADDRESS);
        if (allowance < amount) {
          setTxStatus('Approving wS...');
          const approveTx = await contracts.wS.approve(AUX_ADDRESS, ethers.MaxUint256);
          await approveTx.wait();
        }
        
        const tx = await contracts.aux.leverZeroForOne(amount, {
          gasLimit: 800000
        });
        setTxStatus('Transaction submitted...');
        await tx.wait();
        
      } else {
        setTxStatus('Opening short position...');
        const amount = ethers.parseUnits(leverageAmount, 6);
        
        // Check USDC balance
        const usdcBalance = await contracts.usdc.balanceOf(account);
        if (usdcBalance < amount) {
          throw new Error(`Insufficient USDC balance. Have: ${ethers.formatUnits(usdcBalance, 6)}, Need: ${leverageAmount}`);
        }
        
        // Check and set approval
        const allowance = await contracts.usdc.allowance(account, AUX_ADDRESS);
        if (allowance < amount) {
          setTxStatus('Approving USDC...');
          const approveTx = await contracts.usdc.approve(AUX_ADDRESS, ethers.MaxUint256);
          await approveTx.wait();
        }
        
        const tx = await contracts.aux.leverOneForZero(amount, {
          gasLimit: 800000
        });
        setTxStatus('Transaction submitted...');
        await tx.wait();
      }
      
      setTxStatus(`${leverageType === 'long' ? 'Long' : 'Short'} position opened!`);
      setLeverageAmount('');
      
      // Reload balances
      await loadBalances(account, provider, contracts.wS, contracts.usdc, contracts.router);
      
    } catch (error: any) {
      console.error('Leverage error:', error);
      if (error.message?.includes('Insufficient')) {
        setTxStatus(error.message);
      } else if (error.message?.includes('user rejected')) {
        setTxStatus('Transaction cancelled');
      } else {
        setTxStatus(`Error: ${error.message || 'Unknown error'}`);
      }
    } finally {
      setLoading(false);
    }
  };

  // Refresh balances periodically
  useEffect(() => {
    if (!account || !provider || !contracts.wS || !contracts.usdc || !contracts.router) {
      return;
    }
    
    const wS = contracts.wS;
    const usdc = contracts.usdc;
    const router = contracts.router;
    
    const interval = setInterval(() => {
      loadBalances(account, provider, wS, usdc, router);
    }, 15000); // Update every 15 seconds
    
    return () => clearInterval(interval);
  }, [account, provider, contracts]);

  // Auto-connect if previously connected
  useEffect(() => {
    if (window.ethereum) {
      window.ethereum.request({ method: 'eth_accounts' }).then((accounts: any) => {
        if (accounts.length > 0) {
          connectWallet();
        }
      });
      
      // Listen for network changes
      const handleChainChanged = (...args: unknown[]) => {
        const chainId = args[0] as string;
        console.log('Network changed to:', chainId);
        // Reload the page to reset the app state with new network
        window.location.reload();
      };
      
      const handleAccountsChanged = (...args: unknown[]) => {
        const accounts = args[0] as string[];
        console.log('Accounts changed:', accounts);
        if (accounts.length === 0) {
          // User disconnected wallet
          setAccount('');
          setContracts({
            router: null,
            aux: null,
            wS: null,
            usdc: null
          });
        } else if (accounts[0] !== account) {
          // User switched accounts
          window.location.reload();
        }
      };
      
      window.ethereum.on('chainChanged', handleChainChanged);
      window.ethereum.on('accountsChanged', handleAccountsChanged);
      
      // Cleanup
      return () => {
        if (window.ethereum && window.ethereum.removeListener) {
          window.ethereum.removeListener('chainChanged', handleChainChanged);
          window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
        }
      };
    }
  }, []);

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-900 via-black to-gray-900 text-white">
      {/* Header */}
      <header className="border-b border-gray-800 bg-black/50 backdrop-blur-md">
        <div className="max-w-7xl mx-auto px-4 py-4 flex justify-between items-center">
          <h1 className="text-2xl font-bold bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent">
            Sonic Leverage Trading
          </h1>
          
          {account ? (
            <div className="flex items-center gap-4">
              <div className="text-sm">
                <div>S: {parseFloat(ethBalance).toFixed(4)}</div>
                <div>wS: {parseFloat(wSBalance).toFixed(4)}</div>
                <div>USDC: {parseFloat(usdcBalance).toFixed(2)}</div>
              </div>
              <div className="bg-gray-800 px-4 py-2 rounded-lg font-mono text-sm">
                {account.slice(0, 6)}...{account.slice(-4)}
              </div>
            </div>
          ) : (
            <button 
              onClick={connectWallet}
              className="bg-gradient-to-r from-blue-500 to-purple-600 px-6 py-2 rounded-lg font-semibold hover:from-blue-600 hover:to-purple-700 transition-all"
            >
              Connect Wallet
            </button>
          )}
        </div>
      </header>

      {/* Navigation */}
      <nav className="border-b border-gray-800 bg-black/30">
        <div className="max-w-7xl mx-auto px-4 flex gap-1">
          {['deposit', 'withdraw', 'leverage', 'positions'].map(tab => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`px-6 py-3 capitalize transition-all ${
                activeTab === tab 
                  ? 'text-white border-b-2 border-purple-500' 
                  : 'text-gray-400 hover:text-white'
              }`}
            >
              {tab}
            </button>
          ))}
        </div>
      </nav>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 py-8">
        {/* Status Message */}
        {txStatus && (
          <div className={`mb-4 p-3 rounded-lg border ${
            txStatus.includes('Error') || txStatus.includes('Insufficient') 
              ? 'bg-red-900/20 border-red-800 text-red-200'
              : txStatus.includes('successful') 
                ? 'bg-green-900/20 border-green-800 text-green-200'
                : 'bg-black/50 border-gray-800 text-gray-200'
          }`}>
            {txStatus}
          </div>
        )}

        {/* Deposit Tab */}
        {activeTab === 'deposit' && (
          <div className="bg-black/30 backdrop-blur-md rounded-xl p-6 border border-gray-800">
            <h2 className="text-xl font-bold mb-4">Deposit S to Liquidity Pool</h2>
            
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-gray-400 mb-2">Amount (S)</label>
                <input
                  type="number"
                  value={depositAmount}
                  onChange={(e) => setDepositAmount(e.target.value)}
                  placeholder="0.0"
                  step="0.01"
                  min="0"
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 focus:border-purple-500 focus:outline-none"
                />
                <div className="text-xs text-gray-500 mt-1">
                  Available: {parseFloat(ethBalance).toFixed(4)} S
                </div>
              </div>
              
              <button
                onClick={handleDeposit}
                disabled={loading || !account || !contracts.router || parseFloat(depositAmount) <= 0}
                className="w-full bg-gradient-to-r from-blue-500 to-purple-600 py-3 rounded-lg font-semibold disabled:opacity-50 hover:from-blue-600 hover:to-purple-700 transition-all disabled:cursor-not-allowed"
              >
                {loading ? 'Processing...' : 'Deposit S'}
              </button>
            </div>
            
            {depositInfo && (
              <div className="mt-6 p-4 bg-gray-900 rounded-lg">
                <h3 className="font-semibold mb-2">Your Position</h3>
                <div className="text-sm space-y-1 text-gray-300">
                  <div>Liquidity: {depositInfo.liquidity}</div>
                  <div>Earned S Fees: {depositInfo.feesS}</div>
                  <div>Earned USD Fees: {depositInfo.feesUsd}</div>
                  <div>Current Price: ${parseFloat(depositInfo.price).toFixed(2)}</div>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Withdraw Tab */}
        {activeTab === 'withdraw' && (
          <div className="bg-black/30 backdrop-blur-md rounded-xl p-6 border border-gray-800">
            <h2 className="text-xl font-bold mb-4">Withdraw from Pool</h2>
            
            {depositInfo ? (
              <div className="space-y-4">
                <div>
                  <label className="block text-sm text-gray-400 mb-2">Withdraw Percentage</label>
                  <select
                    value={withdrawPercent}
                    onChange={(e) => setWithdrawPercent(e.target.value)}
                    className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 focus:border-purple-500 focus:outline-none"
                  >
                    <option value="10">10%</option>
                    <option value="25">25%</option>
                    <option value="50">50%</option>
                    <option value="75">75%</option>
                    <option value="100">100%</option>
                  </select>
                </div>
                
                <button
                  onClick={handleWithdraw}
                  disabled={loading || !account || !contracts.router}
                  className="w-full bg-gradient-to-r from-red-500 to-orange-600 py-3 rounded-lg font-semibold disabled:opacity-50 hover:from-red-600 hover:to-orange-700 transition-all disabled:cursor-not-allowed"
                >
                  {loading ? 'Processing...' : 'Withdraw'}
                </button>
              </div>
            ) : (
              <div className="text-center py-8 text-gray-500">
                No deposit to withdraw. Please deposit first.
              </div>
            )}
          </div>
        )}

        {/* Leverage Tab */}
        {activeTab === 'leverage' && (
          <div className="bg-black/30 backdrop-blur-md rounded-xl p-6 border border-gray-800">
            <h2 className="text-xl font-bold mb-4">Open Leveraged Position</h2>
            
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-gray-400 mb-2">Position Type</label>
                <div className="flex gap-2">
                  <button
                    onClick={() => setLeverageType('long')}
                    className={`flex-1 py-2 rounded-lg transition-all ${
                      leverageType === 'long' 
                        ? 'bg-green-600 text-white' 
                        : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
                    }`}
                  >
                    Long (Deposit wS)
                  </button>
                  <button
                    onClick={() => setLeverageType('short')}
                    className={`flex-1 py-2 rounded-lg transition-all ${
                      leverageType === 'short' 
                        ? 'bg-red-600 text-white' 
                        : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
                    }`}
                  >
                    Short (Deposit USDC)
                  </button>
                </div>
              </div>
              
              <div>
                <label className="block text-sm text-gray-400 mb-2">
                  Amount ({leverageType === 'long' ? 'wS' : 'USDC'})
                </label>
                <input
                  type="number"
                  value={leverageAmount}
                  onChange={(e) => setLeverageAmount(e.target.value)}
                  placeholder="0.0"
                  step={leverageType === 'long' ? '0.01' : '1'}
                  min="0"
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 focus:border-purple-500 focus:outline-none"
                />
                <div className="text-xs text-gray-500 mt-1">
                  Available: {leverageType === 'long' ? `${parseFloat(wSBalance).toFixed(4)} wS` : `${parseFloat(usdcBalance).toFixed(2)} USDC`}
                </div>
              </div>
              
              <div className="p-3 bg-gray-900 rounded-lg text-sm text-gray-400">
                <p>• 70% LTV on AAVE</p>
                <p>• Auto-unwinds at ±4.9% price movement</p>
                <p>• Profits from volatility through rebalancing</p>
              </div>
              
              <button
                onClick={handleLeverage}
                disabled={loading || !account || !contracts.aux || parseFloat(leverageAmount) <= 0}
                className={`w-full py-3 rounded-lg font-semibold disabled:opacity-50 transition-all disabled:cursor-not-allowed ${
                  leverageType === 'long'
                    ? 'bg-gradient-to-r from-green-500 to-emerald-600 hover:from-green-600 hover:to-emerald-700'
                    : 'bg-gradient-to-r from-red-500 to-pink-600 hover:from-red-600 hover:to-pink-700'
                }`}
              >
                {loading ? 'Processing...' : `Open ${leverageType === 'long' ? 'Long' : 'Short'} Position`}
              </button>
            </div>
          </div>
        )}

        {/* Positions Tab */}
        {activeTab === 'positions' && (
          <div className="bg-black/30 backdrop-blur-md rounded-xl p-6 border border-gray-800">
            <h2 className="text-xl font-bold mb-4">Your Leveraged Positions</h2>
            
            {positions.length > 0 ? (
              <div className="space-y-3">
                {positions.map((pos, idx) => (
                  <div key={`${idx}-${pos.timestamp}`} className="bg-gray-900 rounded-lg p-4 border border-gray-700">
                    <div className="flex justify-between items-start">
                      <div>
                        <span className={`inline-block px-2 py-1 rounded text-xs font-semibold ${
                          pos.isLong ? 'bg-green-600' : 'bg-red-600'
                        }`}>
                          {pos.isLong ? 'LONG' : 'SHORT'}
                        </span>
                        <div className="mt-2 text-sm space-y-1">
                          <div>Entry: ${parseFloat(pos.entryPrice).toFixed(2)}</div>
                          <div>Supplied: {pos.supplied}</div>
                          <div>Borrowed: {pos.borrowed}</div>
                        </div>
                      </div>
                      <div className="text-right text-sm">
                        <div>Breakeven: ${parseFloat(pos.breakeven).toFixed(2)}</div>
                        <div className="text-gray-500">Block: {pos.block}</div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center py-8 text-gray-500">
                No active leveraged positions
              </div>
            )}
          </div>
        )}
      </main>
    </div>
  );
}

export default App;