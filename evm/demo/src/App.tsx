import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { MetaMaskInpageProvider } from "@metamask/providers";

declare global {
  interface Window {
    ethereum?: MetaMaskInpageProvider;
  }
}
// You'll need to update these with deployed addresses
const ROUTER_ADDRESS = "0x7bAe2554ED287380941B1706DC8cFf665137ca58"; // Update after deploy
const AUX_ADDRESS = "0x2Ce5CfbA940b8e8791864307413bA1334BBd0CD1"; // Update after deploy

// Minimal ABIs
const ROUTER_ABI = [
  "function depositS(uint256 amount) payable",
  "function withdraw(uint256 amount) payable",
  "function fetch(address beneficiary) view returns (tuple(uint256 fees_S, uint256 fees_usd, uint128 liq), uint256, uint160)",
  "function getPrice(uint160 sqrtRatioX96) view returns (uint256)",
  "function wS() view returns (address)",
  "function USDC() view returns (address)",
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
  "function allowance(address owner, address spender) view returns (uint256)"
];

const WETH_ABI = [
  ...ERC20_ABI,
  "function deposit() payable",
  "function withdraw(uint256 amount)"
];

function App() {
  
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.JsonRpcSigner | null>(null);
  const [account, setAccount] = useState<string>('');
  const [chainId, setChainId] = useState<number>(0);
  
  // Contracts 
  const [routerContract, setRouterContract] = useState<ethers.Contract | null>(null);
  const [auxContract, setAuxContract] = useState<ethers.Contract | null>(null);
  const [wSContract, setWSContract] = useState<ethers.Contract | null>(null);
  const [usdcContract, setUsdcContract] = useState<ethers.Contract | null>(null);
  
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

      const provider = new ethers.BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      const signer = await provider.getSigner();
      const address = await signer.getAddress();
      const network = await provider.getNetwork();

      setProvider(provider);
      setSigner(signer);
      setAccount(address);
      setChainId(Number(network.chainId));

      // Initialize contracts
      const router = new ethers.Contract(ROUTER_ADDRESS, ROUTER_ABI, signer);
      const aux = new ethers.Contract(AUX_ADDRESS, AUX_ABI, signer);
      
      setRouterContract(router);
      setAuxContract(aux);
      
      // Get token addresses and initialize token contracts
      const wSAddress = await router.wS();
      const usdcAddress = await router.USDC();
      
      const wS = new ethers.Contract(wSAddress, WETH_ABI, signer);
      const usdc = new ethers.Contract(usdcAddress, ERC20_ABI, signer);
      
      setWSContract(wS);
      setUsdcContract(usdc);
      
      // Load balances
      await loadBalances(address, provider, wS, usdc, router);
      
      // Listen for position events
      setupEventListeners(aux);
      
    } catch (error) {
      console.error('Connection error:', error);
      setTxStatus('Failed to connect wallet');
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
      // ETH balance
      const ethBal = await provider.getBalance(address);
      setEthBalance(ethers.formatEther(ethBal));
      
      // wS balance
      const wSBal = await wS.balanceOf(address);
      setWSBalance(ethers.formatEther(wSBal));
      
      // USDC balance
      const usdcBal = await usdc.balanceOf(address);
      setUsdcBalance(ethers.formatUnits(usdcBal, 6));
      
      // Deposit info
      const [deposit, price, sqrtPrice] = await router.fetch(address);
      if (deposit.liq > 0) {
        setDepositInfo({
          liquidity: deposit.liq.toString(),
          feesS: ethers.formatEther(deposit.fees_S),
          feesUsd: ethers.formatUnits(deposit.fees_usd, 18),
          price: ethers.formatUnits(price, 18)
        });
      }
    } catch (error) {
      console.error('Error loading balances:', error);
    }
};

  const setupEventListeners = (aux: ethers.Contract) => {
    // Listen for leverage positions
    aux.on('LeveragedPositionOpened', (user, isLong, supplied, borrowed, buffer, entryPrice, breakeven, blockNumber) => {
      if (user.toLowerCase() === account.toLowerCase()) {
        const position = {
          isLong,
          supplied: ethers.formatEther(supplied),
          borrowed: ethers.formatEther(borrowed),
          entryPrice: ethers.formatUnits(entryPrice, 18),
          breakeven: ethers.formatUnits(breakeven, 18),
          block: blockNumber.toString()
        };
        setPositions(prev => [...prev, position]);
        setTxStatus(`${isLong ? 'Long' : 'Short'} position opened at $${position.entryPrice}`);
      }
    });
    
    aux.on('PositionUnwound', (user, isLong, exitPrice, priceDelta, blockNumber) => {
      if (user.toLowerCase() === account.toLowerCase()) {
        setTxStatus(`Position unwound at $${ethers.formatUnits(exitPrice, 18)} (${Number(priceDelta) / 10}% change)`);
        // Remove position from list
        setPositions(prev => prev.filter(p => p.isLong !== isLong));
      }
    });
  };

  // Deposit ETH to Router
  const handleDeposit = async () => {
    if (!routerContract || !provider || !wSContract || !usdcContract) {
      setTxStatus('Please connect wallet first');
      return;
    }
    
    if (!depositAmount || parseFloat(depositAmount) <= 0) {
      setTxStatus('Please enter a valid amount');
      return;
    }
    
    setLoading(true);
    setTxStatus('Depositing ETH...');
    
    try {
      const amount = ethers.parseEther(depositAmount);
      const tx = await routerContract.depositS(0, { value: amount });
      
      setTxStatus('Transaction submitted...');
      await tx.wait();
      
      setTxStatus('Deposit successful!');
      setDepositAmount('');
      await loadBalances(account, provider, wSContract, usdcContract, routerContract);
      
    } catch (error: any) {
      console.error('Deposit error:', error);
      setTxStatus(`Error: ${error.message}`);
    } finally {
      setLoading(false);
    }
  };

  // Complete handleWithdraw function
  const handleWithdraw = async () => {
    if (!routerContract || !provider || !wSContract || !usdcContract) {
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
      const percent = parseInt(withdrawPercent) * 10; // Contract expects per-mille (0-1000)
      const tx = await routerContract.withdraw(percent);
      
      setTxStatus('Transaction submitted...');
      await tx.wait();
      
      setTxStatus('Withdrawal successful!');
      await loadBalances(account, provider, wSContract, usdcContract, routerContract);
      
    } catch (error: any) {
      console.error('Withdraw error:', error);
      setTxStatus(`Error: ${error.message}`);
    } finally {
      setLoading(false);
    }
  };

  // Complete handleLeverage function
  const handleLeverage = async () => {
    if (!auxContract || !wSContract || !usdcContract || !provider || !routerContract) {
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
        // Long position (leverZeroForOne) - deposit wS
        setTxStatus('Opening long position...');
        const amount = ethers.parseEther(leverageAmount);
        
        // Check wS allowance
        const allowance = await wSContract.allowance(account, AUX_ADDRESS);
        if (allowance < amount) {
          setTxStatus('Approving wS...');
          const approveTx = await wSContract.approve(AUX_ADDRESS, ethers.MaxUint256);
          await approveTx.wait();
        }
        
        const tx = await auxContract.leverZeroForOne(amount);
        setTxStatus('Transaction submitted...');
        await tx.wait();
        
      } else {
        // Short position (leverOneForZero) - deposit USDC
        setTxStatus('Opening short position...');
        const amount = ethers.parseUnits(leverageAmount, 6);
        
        // Check USDC allowance
        const allowance = await usdcContract.allowance(account, AUX_ADDRESS);
        if (allowance < amount) {
          setTxStatus('Approving USDC...');
          const approveTx = await usdcContract.approve(AUX_ADDRESS, ethers.MaxUint256);
          await approveTx.wait();
        }
        
        const tx = await auxContract.leverOneForZero(amount);
        setTxStatus('Transaction submitted...');
        await tx.wait();
      }
      
      setTxStatus(`${leverageType === 'long' ? 'Long' : 'Short'} position opened!`);
      setLeverageAmount('');
      await loadBalances(account, provider, wSContract, usdcContract, routerContract);
      
    } catch (error: any) {
      console.error('Leverage error:', error);
      setTxStatus(`Error: ${error.message}`);
    } finally {
      setLoading(false);
    }
  };

  // Refresh balances periodically
  useEffect(() => {
  if (account && provider && wSContract && usdcContract && routerContract) {
    const interval = setInterval(() => {
      loadBalances(account, provider, wSContract, usdcContract, routerContract);
    }, 10000); // Every 10 seconds
    
    return () => clearInterval(interval);
  }
}, [account, provider, wSContract, usdcContract, routerContract]);

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
                <div>ETH: {parseFloat(ethBalance).toFixed(4)}</div>
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
          <div className="mb-4 p-3 bg-black/50 backdrop-blur-md rounded-lg border border-gray-800">
            {txStatus}
          </div>
        )}

        {/* Deposit Tab */}
        {activeTab === 'deposit' && (
          <div className="bg-black/30 backdrop-blur-md rounded-xl p-6 border border-gray-800">
            <h2 className="text-xl font-bold mb-4">Deposit ETH to Liquidity Pool</h2>
            
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-gray-400 mb-2">Amount (ETH)</label>
                <input
                  type="number"
                  value={depositAmount}
                  onChange={(e) => setDepositAmount(e.target.value)}
                  placeholder="0.0"
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 focus:border-purple-500 focus:outline-none"
                />
              </div>
              
              <button
                onClick={handleDeposit}
                disabled={loading || !account || !routerContract}
                className="w-full bg-gradient-to-r from-blue-500 to-purple-600 py-3 rounded-lg font-semibold disabled:opacity-50 hover:from-blue-600 hover:to-purple-700 transition-all"
              >
                {loading ? 'Processing...' : 'Deposit ETH'}
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
                disabled={loading || !account || !routerContract || !depositInfo}
                className="w-full bg-gradient-to-r from-red-500 to-orange-600 py-3 rounded-lg font-semibold disabled:opacity-50 hover:from-red-600 hover:to-orange-700 transition-all"
              >
                {loading ? 'Processing...' : 'Withdraw'}
              </button>
            </div>
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
                        : 'bg-gray-800 text-gray-400'
                    }`}
                  >
                    Long (Deposit wS)
                  </button>
                  <button
                    onClick={() => setLeverageType('short')}
                    className={`flex-1 py-2 rounded-lg transition-all ${
                      leverageType === 'short' 
                        ? 'bg-red-600 text-white' 
                        : 'bg-gray-800 text-gray-400'
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
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 focus:border-purple-500 focus:outline-none"
                />
                <div className="text-xs text-gray-500 mt-1">
                  Available: {leverageType === 'long' ? wSBalance : usdcBalance}
                </div>
              </div>
              
              <div className="p-3 bg-gray-900 rounded-lg text-sm text-gray-400">
                <p>• 70% LTV on AAVE</p>
                <p>• Auto-unwinds at ±4.9% price movement</p>
                <p>• Profits from volatility through rebalancing</p>
              </div>
              
              <button
                onClick={handleLeverage}
                disabled={loading || !account || !auxContract}
                className={`w-full py-3 rounded-lg font-semibold disabled:opacity-50 transition-all ${
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
                  <div key={idx} className="bg-gray-900 rounded-lg p-4 border border-gray-700">
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