# *bet...oh, him*? `unwind` a curveball...*be met* with auctions  

*Auction.sol*, Belgian mechanism, MEV protected, participant jury lottery      
*Settlement.sol* (escalatable resolution system with 6909-juror slashing)  

price by confidence: bidders express their odds estimate as a discount  
they're willing to pay per share (0.01 - $1); descending share emission,  
each epoch has progressively fewer shares than previous (natural scarcity  
with pro-rata % allocation for same-price bids, no toxic MEV, good game).  
  
*Basket.sol*: sDAI, DAI, USDE, USDS, crvUSD, GHO, USDC, USDT incentives  
to stake long-term, increasing the stability of all the currencies by   
taking a mutual long term support strategy, incentivising bonds that  

backstop the price of being able to sell ETH in case there is a huge  
drop, because you know that most people will take the max duration  
bond to get the most yield upfront (to use it as a force multiplier  
in DeFi protocols while the delayed redeemability buffers solvency).  
 
*Modularity*: can swap out different resolution systems    
without changing market logic, which diversifies risk     
of holding ETH without requiring you to sell any of it    
while it's earning >10% on fees, cheaper swaps than V3    
with sandwich protection and yield optimisations on top.    

*Reusability*: settlement system can be used for EigenLayer;  
participant tracking in Auction enables fair jury selection    
from actual market participants (ETH or dollar depositors).  

## ERC6909 + ERC404  
& even ERC1497 בדיוק 🤯  
IMA means mom in Hebrew;  
forked IMO (emo version):    
IBO is the [**I** **B**et on **O**ne](http://hackmd.io/@quidmint/yc),    
with 2 virtual machines...    

equity baskets on svm, 
stable baskets on evm
in pooling ETH with $,  
Quid overloads Bunni    
with 6909 stardard:   
particularly apt in  
tracking for bonds;  
Bonds are useful for  
how way yield boosts  
Morpho`viaAAVE` et al 

### MEV Protection 404

including commit-reveal for large bids (>5 ETH)  
dynamic pricing demand curves with randomness,  
anti-sniping mechanisms with epoch extensions...   
Velocity tracking to penalize rapid-fire bidding  
a similar exponential moving average is used in   
basket's optionally enabled epoch governance...  
Batch processing through epoch-based clearing  
(epochs in two senses: one 404 & one in 6909)  

##### phased settlement: proposal with 2:1 support, jury if dispute
with slashing mechanism for jurors who vote against final verdict
force majeur option (with full refunds) for cancelled markets...  

Basket (6909): dollar ETH basket + rebalancing
Rover: UniV4 integration with batch clearing...

other projects have   
attempted to launch  
prediction markets   
as Uniswap, but in  
many ways (e.g. no  
hooks, aka vanilla)  
we set a precedent.  

## Why ERC404 auctions for prediction markets?  
  
Belgian auction mechanics are arguably fairer  
than most alternatives, especially when entry  
timing is a strategic play. The “why” comes down  
to how price discovery interacts with information  
asymmetry the closer a market gets to settlement.  

**Now there's no more incentive to wait till the**  
**last moment, unlike I did with all this code...**  

Late entrants cannot undercut early ones without  
actually offering a better bid, because everyone  
pays their own bid, not 1 uniform clearing price.  

This discourages "sniping" in final moments at  
artificially low risk-adjusted prices. It also  
means late entrants bear the full cost of their  
info edge / advantage (not getting subsidized  
by early bidders via uniform pricing instead).  

## Why we needed a custom settlement engine

Truth discovery territory, not price feeds:  
we're talking about long tail predictions...    
where a question may be too niche, local, or  
informal for a global oracle like UMA et. al. 

We implemented a robust, decentralized settlement  
mechanism that doesn't rely on any single entity  
or oracle, while maintaining economic incentives  
for honest participation and 2 escalation levels  
for dispute resolution (per judicial standards).  
We use evm-native randomness for jury selection.  

## How does the auction work, basically?

Shares in the prediction market  
must be redeemable for $1, but  
you can get $1 for a discount...  
think of it like a concert where:  

- People who REALLY want tickets pay $100 (no discount)  
- People who kind of want tickets pay $30 (30% off)  
- The $100 bidders get seats first, but they pay $100  
- The $30 bidders get leftover seats, but only pay $30   

You cannot change bids after placing them, but if you want  
different exposure, bid in the next epoch at a new price.  
Early epochs see rapid trading, late epochs see hoarding
as more of the shares have been allocated earlier in the 
epoch schedule if there were higher % confidence bettors
then, this explains why it doesn't make sense for them
to wait until the last minute to be most extractive as 
this has been seen with Polymarket, etc.

The current 404 price is set by scarcity  
= (Shares Allocated / Total Shares) × $1  

[Betting Window Opens]  
    ↓  
[Multiple 1-Hour Epochs]  
    ↓  
[Each Epoch: Bids → Clear → Allocate]  
    ↓  
[Betting Window Closes]  
    ↓  
[Wait for Resolution Time (secondary markets for 404s meanwhile)]  
    ↓  
[Settlement Process]  
    ↓  
[Payouts to Winners]  

Your return depends on THREE factors:

Your Confidence (entry price)
Total Pool Size (how much everyone bet)
Winning Share Distribution (YES vs NO shares)

Eventually over time, it appears:  
Overconfident bettors lose money   
Underconfident miss opportunities  

