import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import {
  FACTORY_ABI,
  HELPERS_ABI,
  SETTLEMENT_ABI,
  AUCTION_ABI,
  BASKET_ABI,
} from './contracts/abis';
import { 
  FACTORY_ADDRESS, 
  HELPERS_ADDRESS, 
  SETTLEMENT_ADDRESS,
  BASKET_ADDRESS,
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
  currentPrice: number;
  timeRemaining: number;
  totalYesShares: number;
  totalNoShares: number;
  totalPoolUSD: number;
  impliedProbability: number;
  isActive: boolean;
  isResolved: boolean;
  outcome: boolean;
  epochSharesRemaining: number;
  minimumPriceFor10Percent: number;
}

interface UserPosition {
  yesShares: number;
  noShares: number;
  claimable: number;
}

function App() {
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  const [account, setAccount] = useState<string>('');
  const [markets, setMarkets] = useState<Market[]>([]);
  const [selectedMarket, setSelectedMarket] = useState<Market | null>(null);
  const [betAmount, setBetAmount] = useState<string>('');
  const [evidenceLink, setEvidenceLink] = useState<string>('');
  const [activeTab, setActiveTab] = useState<'markets' | 'create' | 'settle'>('markets');
  const [newMarketQuestion, setNewMarketQuestion] = useState<string>('');
  const [newMarketDuration, setNewMarketDuration] = useState<string>('24');
  const [userPosition, setUserPosition] = useState<UserPosition | null>(null);
  const [quidBalance, setQuidBalance] = useState<string>('0');
  const [loading, setLoading] = useState<boolean>(false);
  const [txStatus, setTxStatus] = useState<string>('');

  // Contract instances
  const [factoryContract, setFactoryContract] = useState<ethers.Contract | null>(null);
  const [helpersContract, setHelpersContract] = useState<ethers.Contract | null>(null);
  const [settlementContract, setSettlementContract] = useState<ethers.Contract | null>(null);
  const [quidContract, setQuidContract] = useState<ethers.Contract | null>(null);

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
      const helpers = new ethers.Contract(HELPERS_ADDRESS, HELPERS_ABI, signer);
      const settlement = new ethers.Contract(SETTLEMENT_ADDRESS, SETTLEMENT_ABI, signer);
      const quid = new ethers.Contract(BASKET_ADDRESS, BASKET_ABI, signer);

      setFactoryContract(factory);
      setHelpersContract(helpers);
      setSettlementContract(settlement);
      setQuidContract(quid);

      // Auto-faucet check
      const balance = await quid.balanceOf(address);
      setQuidBalance(ethers.formatEther(balance));
      
      if (balance === 0n) {
        setTxStatus('Getting your free QUID tokens...');
        try {
          const tx = await quid.faucet();
          await tx.wait();
          const newBalance = await quid.balanceOf(address);
          setQuidBalance(ethers.formatEther(newBalance));
          setTxStatus('✅ Received 1000 QUID tokens!');
        } catch (err) {
          console.error('Faucet error:', err);
        }
      }

    } catch (error) {
      console.error('Connection error:', error);
      alert('Failed to connect wallet');
    }
  };

  // Load markets
  const loadMarkets = async () => {
    if (!helpersContract || !factoryContract) return;
    
    setLoading(true);
    try {
      // Get all markets from factory
      const marketCount = await factoryContract.marketCount();
      const marketPromises = [];
      
      for (let i = 0; i < marketCount; i++) {
        marketPromises.push(factoryContract.markets(i));
      }
      
      const marketAddresses = await Promise.all(marketPromises);
      
      // Get detailed info for each market
      const marketInfoPromises = marketAddresses.map(async (address: string) => {
        try {
          const info = await helpersContract.getMarketInfo(address);
          return {
            address,
            question: info.question,
            currentPrice: Number(ethers.formatEther(info.currentPrice)),
            timeRemaining: Number(info.timeRemaining),
            totalYesShares: Number(ethers.formatEther(info.totalYesShares)),
            totalNoShares: Number(ethers.formatEther(info.totalNoShares)),
            totalPoolUSD: Number(ethers.formatEther(info.totalPoolUSD)),
            impliedProbability: Number(info.impliedProbability) / 100,
            isActive: info.isActive,
            isResolved: info.isResolved,
            outcome: info.outcome,
            epochSharesRemaining: Number(ethers.formatEther(info.epochSharesRemaining)),
            minimumPriceFor10Percent: Number(ethers.formatEther(info.minimumPriceFor10Percent))
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
      const auctionContract = new ethers.Contract(marketAddress, AUCTION_ABI, signer);
      
      // Get user shares
      const yesShares = await auctionContract.userYesShares(account);
      const noShares = await auctionContract.userNoShares(account);
      
      setUserPosition({
        yesShares: Number(ethers.formatEther(yesShares)),
        noShares: Number(ethers.formatEther(noShares)),
        claimable: 0 // Will be calculated after resolution
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
      const durationHours = parseInt(newMarketDuration);
      const tx = await factoryContract.createMarket(
        newMarketQuestion,
        durationHours * 3600 // Convert to seconds
      );
      
      setTxStatus('⏳ Transaction pending...');
      const receipt = await tx.wait();
      
      setTxStatus('✅ Market created successfully!');
      setNewMarketQuestion('');
      setNewMarketDuration('24');
      
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

  // Place bet
  const placeBet = async (isYes: boolean) => {
    if (!selectedMarket || !betAmount || !signer) return;
    
    setLoading(true);
    setTxStatus(`Placing ${isYes ? 'YES' : 'NO'} bet...`);
    
    try {
      const auctionContract = new ethers.Contract(selectedMarket.address, AUCTION_ABI, signer);
      const ethAmount = ethers.parseEther(betAmount);
      
      // Calculate price per share (confidence level)
      const pricePerShare = isYes 
        ? ethers.parseEther(String(selectedMarket.impliedProbability))
        : ethers.parseEther(String(1 - selectedMarket.impliedProbability));
      
      // Place bet with optional evidence link
      let tx;
      if (evidenceLink) {
        tx = await auctionContract.placePredictionBidWithContent(
          pricePerShare,
          isYes,
          evidenceLink,
          { value: ethAmount }
        );
      } else {
        tx = await auctionContract.placePredictionBid(
          pricePerShare,
          isYes,
          { value: ethAmount }
        );
      }
      
      setTxStatus('⏳ Transaction pending...');
      await tx.wait();
      
      // Try to clear the epoch if possible
      try {
        const epochInfo = await auctionContract.getCurrentEpochInfo();
        if (epochInfo.bidCount >= 10 || !epochInfo.isActive) {
          setTxStatus('🔄 Clearing epoch...');
          const clearTx = await auctionContract.clearEpoch(epochInfo.index);
          await clearTx.wait();
        }
      } catch (err) {
        console.log('Epoch clearing not needed or failed:', err);
      }
      
      setTxStatus(`✅ ${isYes ? 'YES' : 'NO'} bet placed successfully!`);
      setBetAmount('');
      setEvidenceLink('');
      
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
    if (!selectedMarket || !settlementContract || !quidContract) return;
    
    setLoading(true);
    setTxStatus(`Proposing ${outcome ? 'YES' : 'NO'} outcome...`);
    
    try {
      // First approve QUID spending
      const stakeAmount = ethers.parseEther('100'); // 100 QUID stake
      const allowance = await quidContract.allowance(account, SETTLEMENT_ADDRESS);
      
      if (allowance < stakeAmount) {
        setTxStatus('Approving QUID spending...');
        const approveTx = await quidContract.approve(SETTLEMENT_ADDRESS, stakeAmount);
        await approveTx.wait();
      }
      
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
      const auctionContract = new ethers.Contract(selectedMarket.address, AUCTION_ABI, signer);
      const tx = await auctionContract.claimPayout();
      
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
    if (factoryContract && helpersContract) {
      loadMarkets();
      const interval = setInterval(loadMarkets, 30000); // Refresh every 30 seconds
      return () => clearInterval(interval);
    }
  }, [factoryContract, helpersContract]);

  // Load user position when market is selected
  useEffect(() => {
    if (selectedMarket && account) {
      loadUserPosition(selectedMarket.address);
    }
  }, [selectedMarket, account]);

  // Format time remaining
  const formatTime = (seconds: number) => {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-purple-900 via-blue-900 to-indigo-900">
      {/* Header */}
      <header className="bg-black/30 backdrop-blur-md border-b border-white/10">
        <div className="max-w-7xl mx-auto px-4 py-4">
          <div className="flex justify-between items-center">
            <h1 className="text-3xl font-bold text-white">
              🎭 Truth or Dare Markets
            </h1>
            <div className="flex items-center gap-4">
              {account && (
                <div className="text-white/80 text-sm">
                  💰 {parseFloat(quidBalance).toFixed(2)} QUID
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
                          ⏱️ {formatTime(market.timeRemaining)}
                        </span>
                      )}
                    </div>
                    
                    <div className="grid grid-cols-2 gap-4 mb-4">
                      <div className="bg-green-500/10 rounded-lg p-3">
                        <div className="text-green-400 text-sm">YES</div>
                        <div className="text-white font-semibold">
                          {(market.impliedProbability * 100).toFixed(1)}%
                        </div>
                        <div className="text-white/60 text-xs">
                          {market.totalYesShares.toFixed(2)} shares
                        </div>
                      </div>
                      <div className="bg-red-500/10 rounded-lg p-3">
                        <div className="text-red-400 text-sm">NO</div>
                        <div className="text-white font-semibold">
                          {((1 - market.impliedProbability) * 100).toFixed(1)}%
                        </div>
                        <div className="text-white/60 text-xs">
                          {market.totalNoShares.toFixed(2)} shares
                        </div>
                      </div>
                    </div>
                    
                    <div className="flex justify-between text-white/60 text-sm">
                      <span>💰 Pool: ${market.totalPoolUSD.toFixed(2)}</span>
                      <span>📊 Min for 10%: ${market.minimumPriceFor10Percent.toFixed(2)}</span>
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
                        <div className="flex justify-between text-white">
                          <span>YES: {userPosition.yesShares.toFixed(2)}</span>
                          <span>NO: {userPosition.noShares.toFixed(2)}</span>
                        </div>
                      </div>
                    )}
                    
                    <input
                      type="number"
                      placeholder="ETH amount"
                      value={betAmount}
                      onChange={(e) => setBetAmount(e.target.value)}
                      className="w-full px-4 py-2 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                      step="0.01"
                    />
                    
                    <input
                      type="text"
                      placeholder="Evidence link (optional)"
                      value={evidenceLink}
                      onChange={(e) => setEvidenceLink(e.target.value)}
                      className="w-full mt-3 px-4 py-2 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                    />
                    
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
                    
                    {selectedMarket.isResolved && userPosition && (userPosition.yesShares > 0 || userPosition.noShares > 0) && (
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
                    <h3 className="text-lg font-bold text-white mb-3">Market Stats</h3>
                    <div className="space-y-2 text-white/80 text-sm">
                      <div className="flex justify-between">
                        <span>Current Price:</span>
                        <span>${selectedMarket.currentPrice.toFixed(4)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span>Epoch Shares:</span>
                        <span>{selectedMarket.epochSharesRemaining.toFixed(2)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span>Status:</span>
                        <span>{selectedMarket.isActive ? '🟢 Active' : '🔴 Inactive'}</span>
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
                
                <div>
                  <label className="block text-white/80 text-sm mb-2">
                    Duration (hours)
                  </label>
                  <input
                    type="number"
                    value={newMarketDuration}
                    onChange={(e) => setNewMarketDuration(e.target.value)}
                    min="1"
                    max="168"
                    className="w-full px-4 py-3 rounded-lg bg-white/10 text-white placeholder-white/50 border border-white/20 focus:border-purple-400 focus:outline-none"
                  />
                  <p className="text-white/60 text-xs mt-1">
                    Market will be open for {newMarketDuration} hours
                  </p>
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
              {markets.filter(m => !m.isResolved && m.timeRemaining === 0).length === 0 ? (
                <div className="bg-black/30 backdrop-blur-md rounded-lg p-8 text-center text-white/60">
                  No markets ready for settlement yet.
                </div>
              ) : (
                markets
                  .filter(m => !m.isResolved && m.timeRemaining === 0)
                  .map((market) => (
                    <div key={market.address} className="bg-black/30 backdrop-blur-md rounded-lg p-6">
                      <h3 className="text-lg font-semibold text-white mb-4">
                        {market.question}
                      </h3>
                      
                      <div className="grid grid-cols-2 gap-4 mb-4">
                        <div className="bg-white/5 rounded-lg p-4 text-center">
                          <div className="text-white/60 text-sm mb-2">YES Shares</div>
                          <div className="text-2xl font-bold text-green-400">
                            {market.totalYesShares.toFixed(2)}
                          </div>
                        </div>
                        <div className="bg-white/5 rounded-lg p-4 text-center">
                          <div className="text-white/60 text-sm mb-2">NO Shares</div>
                          <div className="text-2xl font-bold text-red-400">
                            {market.totalNoShares.toFixed(2)}
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
                        Requires 100 QUID stake • 2:1 support threshold
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