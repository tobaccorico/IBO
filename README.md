
# ~~Kleros~~ *claro que si*

Liquidity boostrapping (the cold  
start problem) is solved through  
bonds: dollar depositors are able  
to get their future yield upfront,  
as a weighted average of all the  
stable yields within the basket.  

Bridging the basket LP token to  
Solana is made possible by LZ...  
from there it's collateral in a  
synthetic stock trading protocol,  
combined with a prediction market    

that has unique tokenomics which   
allow the basket to price swaps   
in a way that is responsive to  
market sentiment on depeg risk.    

Mainnet deployment (currently) is    
`so` branch @ gitlab.com/quidmint    
(no stocks, no Solana, depeg hook).  

`Rover.sol` is the UniV3 contract,  
the name comes from "price range";  
Vogue is a type of Range Rover...    
the `Vogue.sol` version is UniV4:    
for it the `AUX` plugs into `AMP`     

There's zero-IL, single-sided provision;   
if a swap can't be fulfilled by internal  
liquidity alone, tx gets split b/w V3/V4.    
 
Sandwich protection is built-in as  
batching (App-Specific Sequence)...   
swaps on V4 are executed "abstractly"   
using “virtual balances”; as such wETH   
is deposited in Gauntlet's Morpho vault,   
not in the PoolManager, while stables in   
the basket are staked or in AAVE/Morpho.   

