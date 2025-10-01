
# alte liebe rostet nicht?

A stablecoin basket to compete  
with lvlUSD (plugs into Eigen).   
Liquidity boostrapping (the cold  
start problem) is solved through  
bonds: dollar depositors are able  
to get their future yield upfront,  
as a weighted average of all the  
stable yields within the basket.  

Bridging the basket LP token to  
Solana is made possibly by LZ...  
from there it's collateral in a  
synthetic stock trading protocol.  

The stables in the basket are  
always trading against ETH/BTC.  

`Rover.sol` is the UniV3 contract,  
the name comes from "price range";  
Vogue is a type of Range Rover...    
the `Vogue.sol` version is UniV4.  

The two contracts work together to  
power a delta-neutral AAVE trading   
strategy profitting off volatility:  
for this the `AUX` plugs into `AMP`.    

There's zero-IL, single-sided provision;   
if a swap can't be fulfilled by internal  
liquidity alone, tx gets split b/w V3/V4.    
 
Sandwich protection is built-in as  
batching (App-Specific Sequence)...  
swaps on V4 are executed "abstractly"  
using “virtual balances”; as such wETH  
is deposited in Gauntlet's Morpho vault,  
not in the PoolManager, while the basket  
dollars are either in Morpho, AAVE or their  
native staking (e.g. GHO’s safety module).  
