import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import {
  FACTORY_ABI,
  DOPPLER404_ABI,
  SETTLEMENT_ABI,
  BASKET_ABI,
  AUX_ABI,
} from './contracts/abis';
import { 
  FACTORY_ADDRESS, 
  SETTLEMENT_ADDRESS,
  BASKET_ADDRESS,
  AUX_ADDRESS,
} from './contracts/addresses';

import { MetaMaskInpageProvider } from "@metamask/providers";

declare global {
  interface Window {
    ethereum?: MetaMaskInpageProvider;
  }
}

interface Market {
  address: string;
  question: string;
  resolutionTime: number;
  totalYesShares: number;
  totalNoShares: number;
  weightedYesShares: number;
  weightedNoShares: number;
  currentEpoch: number;
  currentPrice: number;
  timeUntilNextEpoch: number;
  isResolved: boolean;
  outcome: boolean;
}

interface UserPosition {
  yesShares: number;
  noShares: number;
  deposited: number;
  avgConfidence: number;
  hasClaimed: boolean;
}

function App() {
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  const [account, setAccount] = useState<string>('');
  const [markets, setMarkets] = useState<Market[]>([]);
  const [selectedMarket, setSelectedMarket] = useState<Market | null>(null);
  const [betAmount, setBetAmount] = useState<string>('');
  const [confidence, setConfidence] = useState<string>('50');
  const [activeTab, setActiveTab] = useState<'markets' | 'create' | 'settle'>('markets');
  const [newMarketQuestion, setNewMarketQuestion] = useState<string>('');
  const [newMarketDuration, setNewMarketDuration] = useState<string>('7');
  const [newMarketEpochLength, setNewMarketEpochLength] = useState<string>('1');
  const [userPosition, setUserPosition] = useState<UserPosition | null>(null);
  const [quidBalance, setQuidBalance] = useState<string>('0');
  const [loading, setLoading] = useState<boolean>(false);
  const [txStatus, setTxStatus] = useState<string>('');
  const [currentEpochBatch, setCurrentEpochBatch] = useState<number>(0);

  // Contract instances
  const [factoryContract, setFactoryContract] = useState<ethers.Contract | null>(null);
  const [settlementContract, setSettlementContract] = useState<ethers.Contract | null>(null);
  const [basketContract, setBasketContract] = useState<ethers.Contract | null>(null);
  const [auxContract, setAuxContract] = useState<ethers.Contract | null>(null);

  // Connect wallet
  const connectWallet = async () => {
    try {
      if (typeof window.ethereum === 'undefined') {
        alert('Please install MetaMask!');
        return;
      }

      const provider = new ethers.BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      const signer = await provider.getSigner();
      const address = await signer.getAddress();

      setProvider(provider);
      setSigner(signer);
      setAccount(address);

      // Initialize contracts
      const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);
      const settlement = new ethers.Contract(SETTLEMENT_ADDRESS, SETTLEMENT_ABI, signer);
      const basket = new ethers.Contract(BASKET_ADDRESS, BASKET_ABI, signer);
      const aux = new ethers.Contract(AUX_ADDRESS, AUX_ABI, signer);

      setFactoryContract(factory);
      setSettlementContract(settlement);
      setBasketContract(basket);
      setAuxContract(aux);

      // Get 6909 balance
      const balance = await basket.balanceOf(address, ethers.toBigInt(BASKET_ADDRESS));
      setQuidBalance(ethers.formatEther(balance));

    } catch (error) {
      console.error('Connection error:', error);
      alert('Failed to connect wallet');
    }
  };

  // Load markets
  const loadMarkets = async () => {
    if (!factoryContract) return;
    
    setLoading(true);
    try {
      // Get all markets from factory
      const marketCount = await factoryContract.getMarketCount();
      const marketPromises = [];
      
      for (let i = 0; i < marketCount; i++) {
        marketPromises.push(factoryContract.getMarket(i));
      }
      
      const marketAddresses = await Promise.all(marketPromises);
      
      // Get detailed info for each market
      const marketInfoPromises = marketAddresses.map(async (address: string) => {
        try {
          const marketContract = new ethers.Contract(address, DOPPLER404_ABI, signer);
          const info = await marketContract.getMarketInfo();
          const epochInfo = await marketContract.getCurrentEpochInfo();
          const marketData = await marketContract.market();
          
          return {
            address,
            question: info.question,
            resolutionTime: Number(info.resolutionTime),
            totalYesShares: Number(ethers.formatEther(info.totalYes)),
            totalNoShares: Number(ethers.formatEther(info.totalNo)),
            weightedYesShares: Number(ethers.formatEther(info.weightedYes)),
            weightedNoShares: Number(ethers.formatEther(info.weightedNo)),
            currentEpoch: Number(epochInfo.epochId),
            currentPrice: Number(ethers.formatEther(epochInfo.currentPrice)),
            timeUntilNextEpoch: Number(epochInfo.timeUntilNext),
            isResolved: marketData.resolved,
            outcome: marketData.binaryOutcome
          };
        } catch (err) {
          console.error(`Error loading market ${address}:`, err);
          return null;
        }
      });
      
      const marketInfos = await Promise.all(marketInfoPromises);
      setMarkets(marketInfos.filter(m => m !== null) as Market[]);
    } catch (error) {
      console.error('Error loading markets:', error);
    } finally {
      setLoading(false);
    }
  };

  // Load user position for selected market
  const loadUserPosition = async (marketAddress: string) => {
    if (!signer || !account) return;
    
    try {
      const marketContract = new ethers.Contract(marketAddress, DOPPLER404_ABI, signer);
      const position = await marketContract.getPosition(account);
      
      setUserPosition({
        yesShares: Number(ethers.formatEther(position.yesShares)),
        noShares: Number(ethers.formatEther(position.noShares)),
        deposited: Number(ethers.formatEther(position.deposited)),
        avgConfidence: Number(position.avgConfidence),
        hasClaimed: position.hasClaimed
      });
    } catch (error) {
      console.error('Error loading user position:', error);
    }
  };

  // Create new market
  const createMarket = async () => {
    if (!factoryContract || !newMarketQuestion) return;
    
    setLoading(true);
    setTxStatus('Creating market...');
    
    try {
      const durationDays = parseInt(newMarketDuration);
      const epochHours = parseInt(newMarketEpochLength);
      
      const tx = await factoryContract.deployMarket(
        newMarketQuestion,
        Math.floor(Date.now() / 1000) + (durationDays * 86400), // Resolution time
        false, // Binary market (not scalar)
        `DARE${Date.now()}`, // Name
        `D${Date.now()}`, // Symbol
        epochHours * 3600 // Epoch length in seconds
      );
      
      setTxStatus('⏳ Transaction pending...');
      const receipt = await tx.wait();
      
      setTxStatus('✅ Market created successfully!');
      setNewMarketQuestion('');
      setNewMarketDuration('7');
      setNewMarketEpochLength('1');
      
      // Reload markets
      await loadMarkets();
      setActiveTab('markets');
    } catch (error) {
      console.error('Error creating market:', error);
      setTxStatus('❌ Failed to create market');
    } finally {
      setLoading(false);
    }
  };

  // Place bet (queue bid)
  const placeBet = async (isYes: boolean) => {
    if (!selectedMarket || !betAmount || !signer || !basketContract || !auxContract) return;
    
    setLoading(true);
    setTxStatus(`Placing ${isYes ? 'YES' : 'NO'} bet with ${confidence}% confidence...`);
    
    try {
      const marketContract = new ethers.Contract(selectedMarket.address, DOPPLER404_ABI, signer);
      
      // First, convert ETH to 6909 tokens
      if (parseFloat(betAmount) > 0) {
        // Check if betting with ETH
        const ethAmount = ethers.parseEther(betAmount);
        
        // Deposit ETH to Aux, get USD, then deposit to Basket for 6909
        setTxStatus('Converting ETH to 6909 tokens...');
        
        // 1. Send ETH to Aux
        const auxTx = await auxContract.swap(
          ethers.ZeroAddress, // from ETH
          false, // not for one (getting USD)
          0, // amount (0 means use msg.value)
          { value: ethAmount }
        );
        await auxTx.wait();
        
        // 2. The USD goes to Basket automatically, now we have 6909 tokens
      }
      
      // Get current 6909 balance
      const balance6909 = await basketContract.balanceOf(account, ethers.toBigInt(BASKET_ADDRESS));
      
      // Approve market to spend 6909 tokens
      setTxStatus('Approving 6909 spending...');
      const approveTx = await basketContract.setApprovalForAll(selectedMarket.address, true);
      await approveTx.wait();
      
      // Queue bid with confidence
      setTxStatus('Queueing bid...');
      const bidAmount = ethers.parseEther(betAmount); // Amount in 6909
      const tx = await marketContract.queueBid(
        bidAmount,
        isYes,
        parseInt(confidence)
      );
      
      setTxStatus('⏳ Transaction pending...');
      await tx.wait();
      
      // Check if we should process the batch
      const epochInfo = await marketContract.getCurrentEpochInfo();
      if (epochInfo.epochId > currentEpochBatch && !epochInfo.processed) {
        setTxStatus('Processing batch...');
        try {
          const processTx = await marketContract.processBatch(currentEpochBatch);
          await processTx.wait();
          setCurrentEpochBatch(Number(epochInfo.epochId));
        } catch (err) {
          console.log('Batch processing not ready yet');
        }
      }
      
      setTxStatus(`✅ ${isYes ? 'YES' : 'NO'} bet placed with ${confidence}% confidence!`);
      setBetAmount('');
      setConfidence('50');
      
      // Reload market data and user position
      await loadMarkets();
      await loadUserPosition(selectedMarket.address);
    } catch (error) {
      console.error('Error placing bet:', error);
      setTxStatus('❌ Failed to place bet');
    } finally {
      setLoading(false);
    }
  };

  // Propose settlement
  const proposeSettlement = async (outcome: boolean) => {
    if (!selectedMarket || !settlementContract || !basketContract) return;
    
    setLoading(true);
    setTxStatus(`Proposing ${outcome ? 'YES' : 'NO'} outcome...`);
    
    try {
      // First approve 6909 spending
      const stakeAmount = ethers.parseEther('100'); // 100 QUID stake
      const basketId = ethers.toBigInt(BASKET_ADDRESS);
      
      setTxStatus('Approving 6909 spending...');
      const approveTx = await basketContract.setApprovalForAll(SETTLEMENT_ADDRESS, true);
      await approveTx.wait();
      
      // Propose settlement
      const tx = await settlementContract.proposeSettlement(
        selectedMarket.address,
        outcome,
        stakeAmount
      );
      
      setTxStatus('⏳ Transaction pending...');
      await tx.wait();
      
      setTxStatus('✅ Settlement proposed successfully!');
      
      // Reload market data
      await loadMarkets();
    } catch (error) {
      console.error('Error proposing settlement:', error);
      setTxStatus('❌ Failed to propose settlement');
    } finally {
      setLoading(false);
    }
  };

  // Claim winnings
  const claimWinnings = async () => {
    if (!selectedMarket || !signer) return;
    
    setLoading(true);
    setTxStatus('Claiming winnings...');
    
    try {
      const marketContract = new ethers.Contract(selectedMarket.address, DOPPLER404_ABI, signer);
      const tx = await marketContract.claimWinnings();
      
      setTxStatus('⏳ Transaction pending...');
      await tx.wait();
      
      setTxStatus('✅ Winnings claimed successfully!');
      
      // Reload user position
      await loadUserPosition(selectedMarket.address);
    } catch (error) {
      console.error('Error claiming winnings:', error);
      setTxStatus('❌ Failed to claim winnings');
    } finally {
      setLoading(false);
    }
  };

  // Auto-refresh markets
  useEffect(() => {
    if (factoryContract) {
      loadMarkets();
      const interval = setInterval(loadMarkets, 30000); // Refresh every 30 seconds
      return () => clearInterval(interval);
    }
  }, [factoryContract]);

  // Load user position when market is selected
  useEffect(() => {
    if (selectedMarket && account) {
      loadUserPosition(selectedMarket.address);
    }
  }, [selectedMarket, account]);

  // Format time
  const formatTime = (seconds: number) => {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  };

  // Calculate implied probability
  const getImpliedProbability = (market: Market) => {
    const total = market.weightedYesShares + market.weightedNoShares;
    if (total === 0) return 50;
    return (market.weightedYesShares / total) * 100;
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-purple-900 via-blue-900 to-indigo-900">
      {/* Header */}
      <header className="bg-black/30 backdrop-blur-md border-b border-white/10">
        <div className="max-w-7xl mx-auto px-4 py-4">
          <div className="flex justify-between items-center">
            <h1 className="text-3xl font-bold text-white">
              🎭 Truth or Dare Markets (Belgian Auction)
            </h1>
            <div className="flex items-center gap-4">
              {account && (
                <div className="text-white/80 text-sm">
                  💰 {parseFloat(quidBalance).toFixed(2)} QUID (6909)
                </div>
              )}
              <button
                onClick={connectWallet}
                className="bg-gradient-to-r from-purple-500 to-pink-500 text-white px-6 py-2 rounded-lg font-semibold hover:opacity-90 transition"
              >
                {account ? `${account.slice(0, 6)}...${account.slice(-4)}` : 'Connect Wallet'}
              </button>
            </div>
          </div>
        </div>
      </header>

      {/* Navigation Tabs */}
      <div className="max-w-7xl mx-auto px-4 mt-6">
        <div className="flex space-x-1 bg-black/20 backdrop-blur-md p-1 rounded-lg">
          <button
            onClick={() => setActiveTab('markets')}
            className={`flex-1 py-2 px-4 rounded-md font-semibold transition ${
              activeTab === 'markets'
                ? 'bg-white text-purple-900'
                : 'text-white/70 hover:text-white'
            }`}
          >
            📊 Active Markets
          </button>
          <button
            onClick={() => setActiveTab('create')}
            className={`flex-1 py-2 px-4 rounded-md font-semibold transition ${
              activeTab === 'create'
                ? 'bg-white text-purple-900'
                : 'text-white/70 hover:text-white'
            }`}
          >
            ✨ Create Market
          </button>
          <button
            onClick={() => setActiveTab('settle')}
            className={`flex-1 py-2 px-4 rounded-md font-semibold transition ${
              activeTab === 'settle'
                ? 'bg-white text-purple-900'
                : 'text-white/70 hover:text-white'
            }`}
          >
            ⚖️ Settlement
          </button>
        </div>
      </div>

      {/* Status Message */}
      {txStatus && (
        <div className="max-w-7xl mx-auto px-4 mt-4">
          <div className="bg-black/30 backdrop-blur-md rounded-lg p-3 text-white">
            {txStatus}
          </div>
        </div>
      )}

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 mt-6 pb-12">
        {/* Markets Tab */}
        {activeTab === 'markets' && (
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            {/* Markets List */}
            <div className="lg:col-span-2 space-y-4">
              <h2 className="text-2xl font-bold text-white mb-4">Active Markets</h2>
              {loading ? (
                <div className="text-white/60 text-center py-8">Loading markets...</div>
              ) : markets.length === 0 ? (
                <div className="bg-black/30 backdrop-blur-md rounded-lg p-8 text-center">
                  <p className="text-white/60">No active markets yet.</p>
                  <button
                    onClick={() => setActiveTab('create')}
                    className="mt-4 bg-gradient-to-r from-purple-500 to-pink-500 text-white px-6 py-2 rounded-lg font-semibold"
                  >
                    Create First Market
                  </button>
                </div>
              ) : (
                markets.map((market) => (
                  <div
                    key={market.address}
                    onClick={() => setSelectedMarket(market)}
                    className={`bg-black/30 backdrop-blur-md rounded-lg p-6 cursor-pointer transition hover:bg-black/40 ${
                      selectedMarket?.address === market.address ? 'ring-2 ring-purple-500' : ''
                    }`}
                  >
                    <div className="flex justify-between items-start mb-4">
                      <h3 className="text-lg font-semibold text-white flex-1">
                        {market.question}
                      </h3>
                      {market.isResolved ? (
                        <span className="bg-green-500/20 text-green-400 px-3 py-1 rounded-full text-sm">
                          Resolved: {market.outcome ? 'YES' : 'NO'}
                        </span>
                      ) : (
                        <span className="text-white/60 text-sm">
                          Epoch {market.currentEpoch} • {formatTime(market.timeUntilNextEpoch)}
                        </span>
                      )}
                    </div>
                    
                    <div className="grid grid-cols-2 gap-4 mb-4">
                      <div className="bg-green-500/10 rounded-lg p-3">
                        <div className="text-green-400 text-sm">YES</div>
                        <div className="text-white font-semibold">
                          {getImpliedProbability(market).toFixed(1)}%
                        </div>
                        <div className="text-white/60 text-xs">
                          {market.totalYesShares.toFixed(2)} shares
                        </div>
                      </div>
                      <div className="bg-red-500/10 rounded-lg p-3">
                        <div className="text-red-400 text-sm">NO</div>
                        <div className="text-white font-semibold">
                          {(100 - getImpliedProbability(market)).toFixed(1)}%
                        </div>
                        <div className="text-white/60 text-xs">
                          {market.totalNoShares.toFixed(2)} shares
                        </div>
                      </div>
                    </div>
                    
                    <div className="flex justify-between text-white/60 text-sm">
                      <span>💵 Current Price: ${market.currentPrice.toFixed(4)}</span>
                      <span>⏰ Resolution: {new Date(market.resolutionTime * 1000).toLocaleDateString()}</span>
                    </div>
                  </div>
                ))
              )}
            </div>

            {/* Selected Market Details */}
            <div className="space-y-4">
              {selectedMarket ? (
                <>
                  <div className="bg-black/30 backdrop-blur-md rounded-lg p-6">
                    <h3 className="text-xl font-bold text-white mb-4">Place Prediction</h3>
                    
                    {userPosition && (
                      <div className="mb-4 p-3 bg-white/5 rounded-lg">
                        <div className="text-white/60 text-sm mb-1">Your Position</div>
                        <div className="grid grid-cols-2 gap-2 text-white text-sm">
                          <div>YES: {userPosition.yesShares.toFixed(2)}</div>
                          <div>NO: {userPosition.noShares.toFixed(2)}</div>
                          <div>Deposited: ${userPosition.deposited.toFixed(2)}</div>
                          <div>Avg Conf: {userPosition.avgConfidence}%</div>
                        </div>
                      </div>
                    )}
                    
                    <div className="space-y-3">
                      <input
                        type="number"
                        placeholder="ETH amount"
                        value={betAmount}
                        onChange={(e) => setBetAmount(e.target.value)}
                        className="w-full px-4 py-2 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                        step="0.01"
                      />
                      
                      <div>
                        <label className="text-white/60 text-sm">Confidence Level: {confidence}%</label>
                        <input
                          type="range"
                          min="1"
                          max="100"
                          value={confidence}
                          onChange={(e) => setConfidence(e.target.value)}
                          className="w-full mt-1"
                        />
                        <div className="text-white/40 text-xs mt-1">
                          Higher confidence = more shares but higher risk
                        </div>
                      </div>
                    </div>
                    
                    <div className="grid grid-cols-2 gap-3 mt-4">
                      <button
                        onClick={() => placeBet(true)}
                        disabled={loading || !betAmount || selectedMarket.isResolved}
                        className="bg-green-500 text-white py-2 rounded-lg font-semibold hover:bg-green-600 transition disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        Bet YES
                      </button>
                      <button
                        onClick={() => placeBet(false)}
                        disabled={loading || !betAmount || selectedMarket.isResolved}
                        className="bg-red-500 text-white py-2 rounded-lg font-semibold hover:bg-red-600 transition disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        Bet NO
                      </button>
                    </div>
                    
                    {selectedMarket.isResolved && userPosition && !userPosition.hasClaimed && 
                     (userPosition.yesShares > 0 || userPosition.noShares > 0) && (
                      <button
                        onClick={claimWinnings}
                        disabled={loading}
                        className="w-full mt-3 bg-gradient-to-r from-purple-500 to-pink-500 text-white py-2 rounded-lg font-semibold hover:opacity-90 transition disabled:opacity-50"
                      >
                        🎉 Claim Winnings
                      </button>
                    )}
                  </div>
                  
                  <div className="bg-black/30 backdrop-blur-md rounded-lg p-6">
                    <h3 className="text-lg font-bold text-white mb-3">Belgian Auction Info</h3>
                    <div className="space-y-2 text-white/80 text-sm">
                      <div className="flex justify-between">
                        <span>Current Epoch:</span>
                        <span>#{selectedMarket.currentEpoch}</span>
                      </div>
                      <div className="flex justify-between">
                        <span>Epoch Price:</span>
                        <span>${selectedMarket.currentPrice.toFixed(4)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span>Next Epoch:</span>
                        <span>{formatTime(selectedMarket.timeUntilNextEpoch)}</span>
                      </div>
                      <div className="text-white/60 text-xs mt-2">
                        ⬆️ Prices increase over time (Belgian auction)
                      </div>
                    </div>
                  </div>
                </>
              ) : (
                <div className="bg-black/30 backdrop-blur-md rounded-lg p-6 text-center text-white/60">
                  Select a market to place bets
                </div>
              )}
            </div>
          </div>
        )}

        {/* Create Market Tab */}
        {activeTab === 'create' && (
          <div className="max-w-2xl mx-auto">
            <div className="bg-black/30 backdrop-blur-md rounded-lg p-8">
              <h2 className="text-2xl font-bold text-white mb-6">Create New Market</h2>
              
              <div className="space-y-4">
                <div>
                  <label className="block text-white/80 text-sm mb-2">
                    Question / Dare Challenge
                  </label>
                  <textarea
                    value={newMarketQuestion}
                    onChange={(e) => setNewMarketQuestion(e.target.value)}
                    placeholder="Will someone complete the ice bucket challenge by Friday?"
                    className="w-full px-4 py-3 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none resize-none"
                    rows={3}
                  />
                </div>
                
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-white/80 text-sm mb-2">
                      Duration (days)
                    </label>
                    <input
                      type="number"
                      value={newMarketDuration}
                      onChange={(e) => setNewMarketDuration(e.target.value)}
                      min="1"
                      max="30"
                      className="w-full px-4 py-3 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                    />
                  </div>
                  
                  <div>
                    <label className="block text-white/80 text-sm mb-2">
                      Epoch Length (hours)
                    </label>
                    <input
                      type="number"
                      value={newMarketEpochLength}
                      onChange={(e) => setNewMarketEpochLength(e.target.value)}
                      min="1"
                      max="24"
                      className="w-full px-4 py-3 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                    />
                  </div>
                </div>
                
                <div className="text-white/60 text-sm">
                  • Market will be open for {newMarketDuration} days<br/>
                  • Prices will increase every {newMarketEpochLength} hour(s) (Belgian auction)<br/>
                  • Early participants get better prices
                </div>
                
                <button
                  onClick={createMarket}
                  disabled={loading || !newMarketQuestion || !account}
                  className="w-full bg-gradient-to-r from-purple-500 to-pink-500 text-white py-3 rounded-lg font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {loading ? 'Creating...' : '🚀 Create Market'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Settlement Tab */}
        {activeTab === 'settle' && (
          <div className="max-w-4xl mx-auto">
            <h2 className="text-2xl font-bold text-white mb-6">Market Settlement</h2>
            
            <div className="space-y-4">
              {markets.filter(m => !m.isResolved && new Date(m.resolutionTime * 1000) < new Date()).length === 0 ? (
                <div className="bg-black/30 backdrop-blur-md rounded-lg p-8 text-center text-white/60">
                  No markets ready for settlement yet.
                </div>
              ) : (
                markets
                  .filter(m => !m.isResolved && new Date(m.resolutionTime * 1000) < new Date())
                  .map((market) => (
                    <div key={market.address} className="bg-black/30 backdrop-blur-md rounded-lg p-6">
                      <h3 className="text-lg font-semibold text-white mb-4">
                        {market.question}
                      </h3>
                      
                      <div className="grid grid-cols-2 gap-4 mb-4">
                        <div className="bg-white/5 rounded-lg p-4 text-center">
                          <div className="text-white/60 text-sm mb-2">Weighted YES</div>
                          <div className="text-2xl font-bold text-green-400">
                            {getImpliedProbability(market).toFixed(1)}%
                          </div>
                          <div className="text-white/60 text-xs">
                            {market.totalYesShares.toFixed(0)} shares
                          </div>
                        </div>
                        <div className="bg-white/5 rounded-lg p-4 text-center">
                          <div className="text-white/60 text-sm mb-2">Weighted NO</div>
                          <div className="text-2xl font-bold text-red-400">
                            {(100 - getImpliedProbability(market)).toFixed(1)}%
                          </div>
                          <div className="text-white/60 text-xs">
                            {market.totalNoShares.toFixed(0)} shares
                          </div>
                        </div>
                      </div>
                      
                      <div className="flex gap-3">
                        <button
                          onClick={() => {
                            setSelectedMarket(market);
                            proposeSettlement(true);
                          }}
                          disabled={loading}
                          className="flex-1 bg-green-500 text-white py-2 rounded-lg font-semibold hover:bg-green-600 transition disabled:opacity-50"
                        >
                          Propose YES
                        </button>
                        <button
                          onClick={() => {
                            setSelectedMarket(market);
                            proposeSettlement(false);
                          }}
                          disabled={loading}
                          className="flex-1 bg-red-500 text-white py-2 rounded-lg font-semibold hover:bg-red-600 transition disabled:opacity-50"
                        >
                          Propose NO
                        </button>
                      </div>
                      
                      <p className="text-white/60 text-xs mt-3 text-center">
                        Requires 100 QUID (6909) stake • 2:1 support threshold • Confidence-weighted outcomes
                      </p>
                    </div>
                  ))
              )}
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

export default App;