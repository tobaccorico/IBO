
# ERC6909 + ERC404
& even ERC1497 בדיוק 🤯  

IMA means mom in Hebrew;  
forked IMO (emo version):    
IBO is the **I** **B**et on **O**ne,    
with 2 virtual machines...    

equity baskets on svm, and  
stable baskets on evm with  
prediciton markets rebuilt  
[in a very hybrid, fresh way](http://hackmd.io/@quid/yc);    
we rewrote the Gnosis Dutch  
auction and made it Belgian.  
  
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

Auctions concentrate liquidity and decision-making  
into tight windows of time. Instead of weeks, thin  
trading; all bidders show up in the heat of the  
moment, making it harder for MEV actors to skew  
the result with toxic flow, disrupting everyone...  
  
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
`forge test --match-path test/Rover.t.sol`  
