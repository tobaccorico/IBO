
# ~~Kleros~~ *claro que si*

Liquidity boostrapping (the cold  
start problem) is solved through  
bonds: dollar depositors are able  
to get their future yield upfront,  
as a weighted average of all the  
stable yields within our basket  

that has unique tokenomics which   
allow the basket to price swaps   
in a way that is responsive to  
market sentiment on depeg risk.    

`Rover.sol` is the UniV3 contract,  
the name comes from "price range";  
Vogue is a type of Range Rover...    
the `Vogue.sol` version is UniV4:    
for it the `AUX` plugs into `AMP`   

There's zero-IL, single-sided provision;   
if a swap can't be fulfilled by internal  
liquidity alone, tx gets split b/w V3/V4.    

swaps on V4 are executed "abstractly"   
using “virtual balances”; as such wETH   
isn't in PoolManager, nor are stables...  

## natural participants, not external speculators.
QU!D (QD) holder already has stablecoin exposure.  
They're already implicitly betting that none of   
their underlying stablecoins will depeg. `HOOK`  
lets them make that implicit bet explicit —   
and get paid for it. Placing on side 0 with  
high confidence costs 400bps, but you win  

95%+ of rounds and collect from the losers'  
pool. The net cost after winnings is much  
less than 400bps, and the fee burn from    
your entry improves QD tokenomics,  
 which benefits you as a holder.  

worried depositors about any  
specific stablecoin can hedge  
without revealing the extent  
of the position's conviction.  

$50k of DAI exposure, place $500     
on the DAI depeg side. You lose    
$500 in 19 out of 20 rounds —  
that's your insurance premium.  

But the one time DAI depegs,   
you capture asymmetric payout    
from the much larger pool,   
depending on your conviction   
partially offsetting you loss.  

The critical point: participants...     
don't need to be "prediction traders"   
looking for edge. Managing own risk,  
the way LiquityV2 and Carbon practice     

The side-0 bettor is saying "my portfolio    
is safe this round, and I want to earn    
for being right." The depeg bettor is     
saying "I'm exposed to DAI and want    
insurance." Both are rational...   
given their existing positions.  

## Why confidence isn't a gimmick.

the combination of confidence + time-limited rounds + rollover costs produces a continuously refreshed, manipulation-resistant probability estimate for depeg risk per stablecoin. That's actually a novel oracle design — not a prediction market people trade for profit, but a paid signaling mechanism where the cost of participation is what makes the signal trustworthy. confidence drives capital allocation, which drives fee calculation.

Rollover cost as signal freshness: If positions are free to hold, you get a stale orderbook where everyone placed bets 6 months ago and forgot. The 200bps is a heartbeat — every round, participants either actively re-commit (signaling they still believe their position) or their capital exits. The market's aggregate signal always reflects current sentiment, not historical positioning. Without this, it's not a market, it's a poll that people filled out once.

payouts are purely capital-weighted, a whale drops $10M on side 0 and dominates every round. Confidence adds a second axis that's committed before resolution — so the whale can't see the outcome and then claim they were "very confident." It becomes a proper scoring rule: you're rewarded for accurate calibration, not just size. The Brier-scoring flavor (confidence × time decay = weight) means someone with $1k at 10000 confidence who entered early can outweigh someone with $100k at 5000 confidence who entered late. That's genuinely harder to game.

The commit-reveal structure prevents gaming. You can't see the outcome and then claim high confidence. You commit before resolution, and your confidence score becomes your scoring weight. This is a proper scoring rule — it rewards honest probability assessment, not just capital.

## Why rollover cost is signal freshness, not a tax.
Without it, someone places on side 0 in January and forgets about it. By July, their bet is still in the market, saying "things were safe six months ago." That's noise, not signal. The 200bps rollover forces a heartbeat: every round, you either actively recommit (expressing a current opinion) or your capital exits. The aggregate signal always reflects what participants believe right now. The cost is what makes the information valuable — free information is worth what you pay for it.

## Why the market bootstraps itself.
The concern about who participates answers itself once you recognize the users are Basket holders. The protocol doesn't need external speculators. It needs its own depositors to express the risk opinions they already implicitly hold. The cold-start is real, but the mechanism is designed so that even modest participation (once past the $100k/$500k trust ramp) produces useful signal — and the signal improves the Basket, which attracts more deposits, which creates more natural participants. Fee burns from market activity make QD deflationary, increasing the value of everyone's position, which attracts more capital. The loop is self-reinforcing.

## What would break the thesis.
If Basket TVL stays below $1M, there aren't enough natural participants to generate meaningful signal. The trust ramp handles this gracefully (the signal has zero effect below $100k and partial effect below $500k), so the protocol doesn't hurt itself during bootstrap — it just defaults to neutral fees. The mechanism is dormant until it has enough data to be useful, and active once it does. That's the right failure mode: harmless when insufficient, valuable when sufficient.
