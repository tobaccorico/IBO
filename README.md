
# ERC6909 + ERC404
& even ERC1497 בדיוק 🤯  

IMA means mom in Hebrew;  
forked IMO (emo version):    
IBO is the **I** **B**et on **O**ne,    
with 2 virtual machines...    

equity baskets on svm, and  
stable baskets on evm with  
[Belgian prediciton markets](http://hackmd.io/@quid/yc).     
  
For pooling ETH with $,  
Quid outperforms Bunni  
while being much simpler.  

The 6909 stardard is   
particularly apt for    
this basket because   
it solves maturity  
tracking for bonds.  

Bonds are necessary  
for the way we boost  
yield `viaAAVE`, and  
allow upfront gains.  

Other projects have   
attempted to launch  
prediction markets   
on Uniswap, but in  
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
Early epochs see rapid trading, late epochs see hoarding.  

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

