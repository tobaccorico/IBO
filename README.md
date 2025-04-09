# BO: Bunni Over-loaded 

In order to save gas, rather than writing a hook  
we decided to build functionality into a router.  
It supports depositing liquidity out-of-range, as  
well as letting the range be managed for you:  

this provides optimal returns for LPs, except,  
unlike the canonical USDC<>WETH pool, the  
dollar side is split between **multiple stables**.  

There is no IL for **single-sided provision**,  
by virtue of a "queue" (`PENDING_ETH`).  
If a swap can't be fulfilled by internal  
liquidity entirely, it gets split between  

our router and the legacy V3 router...  
sandwich protection is embedded in  
a simple app-specific sequence that  
uses batching and gas compensation.  

Depositors of dollars are able to get  
their yield tokenised upfront; there's  
a minimum 1-month lockup (12 mon.  
gives them the entire APY upfront)...  

This way we ensure that ETH always  
has dollars to be paired with in V4...  
In being abstract, swaps are executed  
using “virtual balances”; because ETH  

is deposited in Gauntlet's **Morpho vault**,  
and not in the PoolManager, while various  
dollars are either in Morpho vaults or their  
native staking (e.g. GHO’s safety module).  

“**levered swaps**” take extra time, but are  
**guaranteed to be profitable** for both the  
protocol, and the originators of the swaps  
(for them, in annualised terms, ~30% yield)

with almost negligible liquidation risk,  
providing an incentivised way to move   
liquidity from UniV3 to V4 `viaAAVE`  
The protocol is **100% FAIR LAUNCH**,    
except for retained AAVE rewards ;) 
