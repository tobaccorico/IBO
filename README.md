    
equity baskets on svm,  
inspired by Ostium, &  
an alternative lvlUSD,  
stable baskets on evm  
by pooling ETH with $  
with 2 types of bonds:  
[snowball derivative](https://github.com/tobaccorico/IBO/blob/main/evm/src/Basket.sol#L473);  

zero coupon bonds for prediction markets:  
current ERC404 price is set by scarcity  
= (Shares Allocated / Total Shares) × $1  

[Betting Window Opens]  
    ↓  
[Multiple 1-Hour Epochs]  
    ↓  
[Each Epoch: Bids → Clear → Allocate]  
    ↓  
[Betting Window Closes]  
    ↓  
[Wait for Resolution]  
    ↓  
[Settlement Process]  
    ↓  
[Payouts to Winners]  

