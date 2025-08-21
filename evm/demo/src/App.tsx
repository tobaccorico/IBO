import React, { useState, useEffect } from 'react';
import { ethers, Contract } from 'ethers';
import { MetaMaskSDK } from '@metamask/sdk';
import {
  FACTORY_ABI,
  HELPERS_ABI,
  SETTLEMENT_ABI,
  AUCTION_ABI
} from './contracts/abis';
import {
  FACTORY_ADDRESS,
  HELPERS_ADDRESS,
  SETTLEMENT_ADDRESS
} from './contracts/addresses';

// Initialize MetaMask SDK
const MMSDK = new MetaMaskSDK({
  dappMetadata: {
    name: "Truth or Dare Markets",
    url: window.location.host,
  }
});

const ethereum = MMSDK.getProvider();

interface Market {
  address: string;
  question: string;
  challenger: string;
  challenged: string;
  responseDeadline: number;
  resolutionTime: number;
  totalYesShares: string;
  totalNoShares: string;
  totalPoolUSD: string;
  impliedProbability: number;
  resolved: boolean;
  outcome?: boolean;
  isActive: boolean;
  currentPrice: string;
  timeRemaining: number;
}

interface UserPosition {
  yesShares: string;
  noShares: string;
  total404Tokens: string;
  estimatedPayout: string;
  canClaimPayout: boolean;
  canClaimRefund: boolean;
}

interface Proposal {
  id: number;
  proposer: string;
  outcome: boolean;
  supportStake: string;
  opposeStake: string;
  status: string;
  canExecute: boolean;
}

const App: React.FC = () => {
  const [account, setAccount] = useState<string>('');
  const [provider, setProvider] = useState<ethers.Provider | null>(null);
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  
  // Contract instances
  const [factory, setFactory] = useState<Contract | null>(null);
  const [helpers, setHelpers] = useState<Contract | null>(null);
  const [settlement, setSettlement] = useState<Contract | null>(null);
  
  // UI State
  const [activeView, setActiveView] = useState<'create' | 'market' | 'settle'>('create');
  const [markets, setMarkets] = useState<Market[]>([]);
  const [selectedMarket, setSelectedMarket] = useState<Market | null>(null);
  const [userPosition, setUserPosition] = useState<UserPosition | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  // Initialize contracts and connect wallet
  useEffect(() => {
    connectWallet();
  }, []);

  const connectWallet = async () => {
    try {
      if (!ethereum) throw new Error('MetaMask not installed');
      
      const accounts = await ethereum.request({ 
        method: 'eth_requestAccounts' 
      }) as string[];
      
      if (!accounts || accounts.length === 0) throw new Error('No accounts found');
      
      const provider = new ethers.BrowserProvider(ethereum);
      const signer = await provider.getSigner();
      
      setAccount(accounts[0]);
      setProvider(provider);
      setSigner(signer);
      
      // Initialize contracts
      const factoryContract: Contract = new ethers.Contract(
        FACTORY_ADDRESS,
        FACTORY_ABI,
        signer
      );
      
      const helpersContract: Contract = new ethers.Contract(
        HELPERS_ADDRESS,
        HELPERS_ABI,
        signer
      );
      
      const settlementContract: Contract = new ethers.Contract(
        SETTLEMENT_ADDRESS,
        SETTLEMENT_ABI,
        signer
      );
      
      setFactory(factoryContract);
      setHelpers(helpersContract);
      setSettlement(settlementContract);
      
      // Load existing markets
      await loadMarkets(factoryContract, helpersContract);
      
    } catch (err) {
      console.error('Failed to connect wallet:', err);
      setError('Failed to connect wallet');
    }
  };

  const loadMarkets = async (
    factoryContract: Contract, 
    helpersContract: Contract
  ) => {
    try {
      const marketAddresses = await factoryContract.getAuctions();
      const marketData: Market[] = [];
      
      for (const address of marketAddresses) {
        const overview = await helpersContract.getMarketOverview(address);
        
        if (!signer) continue;
        
        const auctionContract: Contract = new ethers.Contract(
          address,
          AUCTION_ABI,
          signer
        );
        
        const config = await auctionContract.getPredictionConfig();
        
        // Extract challenger/challenged from question
        const match = config.question.match(/Dare: (.+) dares (.+) to .+/) || 
                     config.question.match(/Dare: (.+) vs (.+)/) ||
                     config.question.match(/Q: (.+)/);
        
        const challenger = match?.[1] || 'Unknown';
        const challenged = match?.[2] || 'Unknown';
        
        marketData.push({
          address,
          question: config.question,
          challenger,
          challenged,
          responseDeadline: Number(config.contentDeadline),
          resolutionTime: Number(config.resolutionTime),
          totalYesShares: ethers.formatEther(overview.totalYesShares),
          totalNoShares: ethers.formatEther(overview.totalNoShares),
          totalPoolUSD: ethers.formatEther(overview.totalPoolUSD),
          impliedProbability: Number(overview.impliedProbability),
          resolved: overview.isResolved,
          outcome: overview.outcome,
          isActive: overview.isActive,
          currentPrice: ethers.formatEther(overview.currentPrice),
          timeRemaining: Number(overview.timeRemaining)
        });
      }
      
      setMarkets(marketData);
    } catch (err) {
      console.error('Failed to load markets:', err);
    }
  };

  // Load user position for selected market
  const loadUserPosition = async (marketAddress: string) => {
    if (!helpers || !account) return;
    
    try {
      const position = await helpers.getUserPosition(marketAddress, account);
      
      setUserPosition({
        yesShares: ethers.formatEther(position.yesShares),
        noShares: ethers.formatEther(position.noShares),
        total404Tokens: ethers.formatEther(position.total404Tokens),
        estimatedPayout: ethers.formatEther(position.estimatedPayout),
        canClaimPayout: position.canClaimPayout,
        canClaimRefund: position.canClaimRefund
      });
    } catch (err) {
      console.error('Failed to load user position:', err);
    }
  };

  // Create Truth or Dare market
  const createDareMarket = async (
    challenger: string,
    challenged: string,
    dareDescription: string,
    responseHours: number
  ) => {
    if (!helpers) return;
    
    setLoading(true);
    setError('');
    
    try {
      // Use the rap battle function which is designed for dare markets
      const tx = await helpers.createRapBattle(
        challenger,
        challenged,
        responseHours
      );
      
      await tx.wait();
      
      // Reload markets
      if (factory && helpers) {
        await loadMarkets(factory, helpers);
      }
      
      alert('Dare market created successfully!');
      
    } catch (err: any) {
      console.error('Failed to create market:', err);
      setError(err.message || 'Failed to create market');
    } finally {
      setLoading(false);
    }
  };

  // Place a bet using velocity-based MEV protection (no commit-reveal)
  const placeBet = async (
    marketAddress: string,
    isYes: boolean,
    amountETH: string,
    confidenceLevel: number = 100
  ) => {
    if (!helpers) return;
    
    setLoading(true);
    setError('');
    
    try {
      const value = ethers.parseEther(amountETH);
      const pricePerShare = ethers.parseEther((confidenceLevel / 100).toString());
      
      // Get current MEV protection info
      const mevInfo = await helpers.getMEVProtectionInfo(
        marketAddress,
        account,
        ethers.parseEther((parseFloat(amountETH) * 3000).toString()) // Assume $3000/ETH
      );
      
      if (mevInfo.wouldTriggerPenalty) {
        const proceed = window.confirm(
          `MEV Protection Warning: You have high velocity (${mevInfo.userVelocity}/1000). ` +
          `This will incur a ${mevInfo.dynamicFeeBps} basis point fee. Continue?`
        );
        if (!proceed) {
          setLoading(false);
          return;
        }
      }
      
      // Place bet with confidence level
      const tx = isYes 
        ? await helpers.betYesWithSlippage(marketAddress, pricePerShare, { value })
        : await helpers.betNoWithSlippage(marketAddress, pricePerShare, { value });
      
      await tx.wait();
      
      alert(`Successfully placed ${isYes ? 'YES' : 'NO'} bet with ${confidenceLevel}% confidence!`);
      
      // Reload market data and user position
      if (factory && helpers) {
        await loadMarkets(factory, helpers);
        await loadUserPosition(marketAddress);
      }
      
    } catch (err: any) {
      console.error('Failed to place bet:', err);
      setError(err.message || 'Failed to place bet');
    } finally {
      setLoading(false);
    }
  };

  // Submit evidence (for dare completion)
  const submitEvidence = async (
    marketAddress: string,
    evidenceURI: string,
    confidenceLevel: number = 90
  ) => {
    if (!signer) return;
    
    setLoading(true);
    setError('');
    
    try {
      const auctionContract: Contract = new ethers.Contract(
        marketAddress,
        AUCTION_ABI,
        signer
      );
      
      const pricePerShare = ethers.parseEther((confidenceLevel / 100).toString());
      
      // Submit content/evidence with bet
      const tx = await auctionContract.placePredictionBidWithContent(
        pricePerShare,
        true, // isYes (completed dare)
        evidenceURI,
        { value: ethers.parseEther("0.01") } // Small bet with evidence
      );
      
      await tx.wait();
      
      alert('Evidence submitted successfully!');
      
      // Reload data
      if (factory && helpers) {
        await loadMarkets(factory, helpers);
        await loadUserPosition(marketAddress);
      }
      
    } catch (err: any) {
      console.error('Failed to submit evidence:', err);
      setError(err.message || 'Failed to submit evidence');
    } finally {
      setLoading(false);
    }
  };

  // Propose settlement
  const proposeSettlement = async (
    marketAddress: string,
    outcome: boolean,
    stakeAmount: string
  ) => {
    if (!settlement) return;
    
    setLoading(true);
    setError('');
    
    try {
      const stake = ethers.parseEther(stakeAmount);
      
      const tx = await settlement.proposeSettlement(
        marketAddress,
        outcome,
        stake
      );
      
      await tx.wait();
      
      alert('Settlement proposed successfully!');
      
    } catch (err: any) {
      console.error('Failed to propose settlement:', err);
      setError(err.message || 'Failed to propose settlement');
    } finally {
      setLoading(false);
    }
  };

  // Execute proposal (for 2-person scenario)
  const executeProposal = async (
    marketAddress: string,
    proposalId: number
  ) => {
    if (!settlement) return;
    
    setLoading(true);
    setError('');
    
    try {
      const tx = await settlement.executeProposal(marketAddress, proposalId);
      await tx.wait();
      
      alert('Proposal executed successfully!');
      
      // Reload markets
      if (factory && helpers) {
        await loadMarkets(factory, helpers);
      }
      
    } catch (err: any) {
      console.error('Failed to execute proposal:', err);
      setError(err.message || 'Failed to execute proposal');
    } finally {
      setLoading(false);
    }
  };

  // Force resolution for 2-person edge case
  const forceResolution = async (marketAddress: string) => {
    if (!settlement) return;
    
    setLoading(true);
    setError('');
    
    try {
      // Check if we can use timeout resolution
      const canSettle = await settlement.canSettle(marketAddress);
      
      if (canSettle.canSettleResult) {
        // Try timeout resolution
        const disputeId = await settlement.marketDispute(marketAddress);
        if (disputeId > 0) {
          const tx = await settlement.forceTimeoutResolution(disputeId);
          await tx.wait();
          alert('Market resolved via timeout!');
        }
      } else {
        alert(`Cannot settle: ${canSettle.reason}`);
      }
      
    } catch (err: any) {
      console.error('Failed to force resolution:', err);
      setError(err.message || 'Failed to force resolution');
    } finally {
      setLoading(false);
    }
  };

  // Claim payout
  const claimPayout = async (marketAddress: string) => {
    if (!helpers) return;
    
    setLoading(true);
    setError('');
    
    try {
      const tx = await helpers.claimAll(marketAddress);
      await tx.wait();
      
      alert('Payout claimed successfully!');
      
      // Reload user position
      await loadUserPosition(marketAddress);
      
    } catch (err: any) {
      console.error('Failed to claim payout:', err);
      setError(err.message || 'Failed to claim payout');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="app">
      <header>
        <h1>Truth or Dare Markets</h1>
        <div className="wallet-info">
          {account ? (
            <span>Connected: {account.slice(0, 6)}...{account.slice(-4)}</span>
          ) : (
            <button onClick={connectWallet}>Connect Wallet</button>
          )}
        </div>
      </header>

      <nav>
        <button 
          className={activeView === 'create' ? 'active' : ''}
          onClick={() => setActiveView('create')}
        >
          Create Dare
        </button>
        <button 
          className={activeView === 'market' ? 'active' : ''}
          onClick={() => setActiveView('market')}
        >
          Active Markets
        </button>
        <button 
          className={activeView === 'settle' ? 'active' : ''}
          onClick={() => setActiveView('settle')}
        >
          Settlement
        </button>
      </nav>

      {error && <div className="error">{error}</div>}

      <main>
        {activeView === 'create' && <CreateDareView onCreateDare={createDareMarket} loading={loading} />}
        {activeView === 'market' && (
          <MarketView 
            markets={markets}
            selectedMarket={selectedMarket}
            userPosition={userPosition}
            onSelectMarket={(market) => {
              setSelectedMarket(market);
              loadUserPosition(market.address);
            }}
            onPlaceBet={placeBet}
            onSubmitEvidence={submitEvidence}
            loading={loading}
          />
        )}
        {activeView === 'settle' && (
          <SettlementView
            markets={markets.filter(m => !m.resolved)}
            onProposeSettlement={proposeSettlement}
            onExecuteProposal={executeProposal}
            onForceResolution={forceResolution}
            onClaimPayout={claimPayout}
            loading={loading}
          />
        )}
      </main>
    </div>
  );
};

// Component for creating dares
const CreateDareView: React.FC<{
  onCreateDare: (challenger: string, challenged: string, dare: string, hours: number) => Promise<void>;
  loading: boolean;
}> = ({ onCreateDare, loading }) => {
  const [challenger, setChallenger] = useState('');
  const [challenged, setChallenged] = useState('');
  const [dare, setDare] = useState('');
  const [hours, setHours] = useState(48);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    await onCreateDare(challenger, challenged, dare, hours);
  };

  return (
    <div className="create-dare">
      <h2>Create a Dare Challenge</h2>
      <form onSubmit={handleSubmit}>
        <input
          type="text"
          placeholder="Challenger name"
          value={challenger}
          onChange={(e) => setChallenger(e.target.value)}
          required
        />
        <input
          type="text"
          placeholder="Challenged person name"
          value={challenged}
          onChange={(e) => setChallenged(e.target.value)}
          required
        />
        <textarea
          placeholder="Describe the dare... (e.g., 'Post a video doing 50 pushups', 'Share an Instagram story singing karaoke', 'Tweet a confession')"
          value={dare}
          onChange={(e) => setDare(e.target.value)}
          required
        />
        <label>
          Response deadline (hours):
          <input
            type="number"
            min={24}
            max={168}
            value={hours}
            onChange={(e) => setHours(Number(e.target.value))}
          />
        </label>
        <button type="submit" disabled={loading}>
          {loading ? 'Creating...' : 'Create Dare Market'}
        </button>
      </form>
      <div className="mev-info">
        <h3>Enhanced MEV Protection</h3>
        <p>✅ Velocity-based dynamic fees</p>
        <p>✅ Randomized epoch timing</p>
        <p>✅ Fair price allocation curves</p>
        <p>✅ Anti-sniping extensions</p>
        <p>❌ No commit-reveal needed</p>
      </div>
    </div>
  );
};

// Component for market interaction
const MarketView: React.FC<{
  markets: Market[];
  selectedMarket: Market | null;
  userPosition: UserPosition | null;
  onSelectMarket: (market: Market) => void;
  onPlaceBet: (market: string, isYes: boolean, amount: string, confidence: number) => Promise<void>;
  onSubmitEvidence: (market: string, evidence: string, confidence: number) => Promise<void>;
  loading: boolean;
}> = ({ markets, selectedMarket, userPosition, onSelectMarket, onPlaceBet, onSubmitEvidence, loading }) => {
  const [betAmount, setBetAmount] = useState('0.1');
  const [confidenceLevel, setConfidenceLevel] = useState(80);
  const [evidenceURI, setEvidenceURI] = useState('');

  return (
    <div className="market-view">
      <h2>Active Dare Markets</h2>
      {markets.map((market) => (
        <div 
          key={market.address} 
          className={`market-card ${selectedMarket?.address === market.address ? 'selected' : ''}`}
          onClick={() => onSelectMarket(market)}
        >
          <h3>{market.question}</h3>
          <div className="market-stats">
            <div className="stat-row">
              <span>YES: {market.totalYesShares} shares</span>
              <span>NO: {market.totalNoShares} shares</span>
            </div>
            <div className="stat-row">
              <span>Pool: ${market.totalPoolUSD}</span>
              <span>Probability: {market.impliedProbability}%</span>
            </div>
            <div className="stat-row">
              <span>Current Price: ${market.currentPrice}</span>
              <span>Time Left: {Math.floor(market.timeRemaining / 3600)}h</span>
            </div>
            <p>Response deadline: {new Date(market.responseDeadline * 1000).toLocaleString()}</p>
          </div>
          
          {selectedMarket?.address === market.address && (
            <>
              {userPosition && (
                <div className="user-position">
                  <h4>Your Position</h4>
                  <p>YES: {userPosition.yesShares} | NO: {userPosition.noShares}</p>
                  <p>Total Tokens: {userPosition.total404Tokens}</p>
                  {userPosition.estimatedPayout !== '0' && (
                    <p>Estimated Payout: ${userPosition.estimatedPayout}</p>
                  )}
                  {(userPosition.canClaimPayout || userPosition.canClaimRefund) && (
                    <p style={{ color: 'green' }}>✅ You can claim rewards!</p>
                  )}
                </div>
              )}
              
              <div className="market-actions">
                <input
                  type="number"
                  step="0.01"
                  value={betAmount}
                  onChange={(e) => setBetAmount(e.target.value)}
                  placeholder="ETH amount"
                />
                <label>
                  Confidence Level: {confidenceLevel}%
                  <input
                    type="range"
                    min="1"
                    max="100"
                    value={confidenceLevel}
                    onChange={(e) => setConfidenceLevel(Number(e.target.value))}
                  />
                </label>
                <button 
                  onClick={() => onPlaceBet(market.address, true, betAmount, confidenceLevel)}
                  disabled={loading}
                >
                  Bet YES (Completed) - {confidenceLevel}%
                </button>
                <button 
                  onClick={() => onPlaceBet(market.address, false, betAmount, confidenceLevel)}
                  disabled={loading}
                >
                  Bet NO (Failed) - {confidenceLevel}%
                </button>
              </div>
              
              <div className="evidence-submission">
                <input
                  type="text"
                  value={evidenceURI}
                  onChange={(e) => setEvidenceURI(e.target.value)}
                  placeholder="Evidence URL (Instagram, YouTube, Twitter, etc.)"
                />
                <button 
                  onClick={() => onSubmitEvidence(market.address, evidenceURI, 90)}
                  disabled={loading || !evidenceURI}
                >
                  Submit Evidence (90% confidence)
                </button>
                <small>Any URL or text proof: Instagram posts, YouTube videos, tweets, etc.</small>
              </div>
            </>
          )}
        </div>
      ))}
    </div>
  );
};

// Component for settlement
const SettlementView: React.FC<{
  markets: Market[];
  onProposeSettlement: (market: string, outcome: boolean, stake: string) => Promise<void>;
  onExecuteProposal: (market: string, proposalId: number) => Promise<void>;
  onForceResolution: (market: string) => Promise<void>;
  onClaimPayout: (market: string) => Promise<void>;
  loading: boolean;
}> = ({ markets, onProposeSettlement, onExecuteProposal, onForceResolution, onClaimPayout, loading }) => {
  const [stakeAmount, setStakeAmount] = useState('100');
  const [proposalId, setProposalId] = useState(1);

  return (
    <div className="settlement-view">
      <h2>Market Settlement</h2>
      {markets.map((market) => (
        <div key={market.address} className="settlement-card">
          <h3>{market.question}</h3>
          
          <div className="settlement-actions">
            <h4>Propose Settlement</h4>
            <input
              type="number"
              value={stakeAmount}
              onChange={(e) => setStakeAmount(e.target.value)}
              placeholder="Stake amount (QUID)"
            />
            <button 
              onClick={() => onProposeSettlement(market.address, true, stakeAmount)}
              disabled={loading}
            >
              Propose YES (Dare Completed)
            </button>
            <button 
              onClick={() => onProposeSettlement(market.address, false, stakeAmount)}
              disabled={loading}
            >
              Propose NO (Dare Failed)
            </button>
          </div>
          
          <div className="execution-actions">
            <h4>Execute Proposal</h4>
            <input
              type="number"
              value={proposalId}
              onChange={(e) => setProposalId(Number(e.target.value))}
              placeholder="Proposal ID"
            />
            <button 
              onClick={() => onExecuteProposal(market.address, proposalId)}
              disabled={loading}
            >
              Execute Proposal
            </button>
          </div>
          
          <div className="emergency-actions">
            <button 
              onClick={() => onForceResolution(market.address)}
              disabled={loading}
            >
              Force Timeout Resolution
            </button>
            <button 
              onClick={() => onClaimPayout(market.address)}
              disabled={loading}
            >
              Claim Payout
            </button>
          </div>
        </div>
      ))}
    </div>
  );
};

export default App;