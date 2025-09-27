// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from "./Aux.sol";
// import {Basket} from "./Basket.sol";
import {BasketL2 as Basket} from "./BasketL2.sol";
import {BasketLib} from "./BasketLib.sol";
import {mockToken} from "./mockToken.sol";
import {Types} from "./imports/Types.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {stdMath} from "forge-std/StdMath.sol";
import "lib/forge-std/src/console.sol"; // TODO

contract Vogue is SafeCallback, Ownable {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    Basket QUID; Aux AUX; WETH9 WETH;

    mapping(uint => Types.Batch) BTCswapsZeroForOne;
    mapping(uint => Types.Batch) BTCswapsOneForZero;
    mapping(uint => Types.Batch) ETHswapsZeroForOne;
    mapping(uint => Types.Batch) ETHswapsOneForZero;
    mapping(address => Types.Deposit) autoManaged;
    // ^ price range is managed by our contracts

    mapping(address => uint[]) positions;    
    // ^ allows several selfManaged positions
    mapping(uint => Types.SelfManaged) selfManaged;
    // ^ key is tokenId of ID++ for that position
    uint internal ID; 
    // ^ always grows

    IERC4626 public wethVault;
    mockToken internal mockETH; 
    mockToken internal mockBTC;
    mockToken internal mockUSD;
    mockToken internal USDmock;
    
    uint constant WAD = 1e18;
    bool public token1isETH;
    bool public token1isBTC;
    PoolKey VANILLA_ETH; 
    PoolKey VANILLA_BTC; 
    
    enum Action { 
        Swap, BatchSwap, 
        Repack, ModLP,
        OutsideRange
    }
    // currently "in-range"...
    // which is distinct from 
    // its mockToken.totalSupply()
    uint public ETH_POOLED;
    uint public ETH_POOLED_USD;
    uint public BTC_POOLED;
    uint public BTC_POOLED_USD;

    uint public LAST_REPACK_ETH;
    uint public LAST_REPACK_BTC;
    // range = between the ticks
    int24 public UPPER_TICK_BTC;
    int24 public LOWER_TICK_BTC;
    int24 public UPPER_TICK_ETH;
    int24 public LOWER_TICK_ETH;
    
    // ^ timestamp allows us
    // to measure APY% for...
    uint public USD_FEES_ETH;
    uint public USD_FEES_BTC;
    uint public ETH_FEES;
    uint public BTC_FEES;
    uint public YIELD_BTC;
    uint public YIELD_ETH; 
    
    bytes internal constant ZERO_BYTES = bytes("");
    modifier onlyAux {
        require(msg.sender == address(AUX), "403"); _;
    }
    constructor(IPoolManager _manager, address _vault) 
        SafeCallback(_manager) 
        Ownable(msg.sender) { 
            wethVault = IERC4626(_vault);
        }   fallback() external payable {}
    
    function setup(address _quid, address _aux, // < auxiliary 
        address _poolETH, address _poolBTC) external payable
        onlyOwner { require(address(QUID) == address(0), "!");
        QUID = Basket(_quid); AUX = Aux(payable(_aux));
        // virtual balances represent assets in curve
        mockETH = new mockToken(address(this), 18);
        mockBTC = new mockToken(address(this), 8);
        USDmock = new mockToken(address(this), 6);
        mockUSD = new mockToken(address(this), 6);
        address token0_eth; address token1_eth; 
        if (address(mockETH) > address(mockUSD)) { 
            token1isETH = true;
            token0_eth = address(mockUSD); 
            token1_eth = address(mockETH);
        } else {
            token0_eth = address(mockETH); 
            token1_eth = address(mockUSD);
        } 
        address token0_btc; address token1_btc; 
        if (address(mockBTC) > address(USDmock)) { 
            token1isBTC = true;
            token0_btc = address(USDmock);
            token1_btc = address(mockBTC);
        } else { 
            token0_btc = address(mockBTC); 
            token1_btc = address(USDmock); 
        }
        mockUSD.approve(address(poolManager), type(uint).max);
        mockETH.approve(address(poolManager), type(uint).max);
        mockBTC.approve(address(poolManager), type(uint).max);
        USDmock.approve(address(poolManager), type(uint).max);
        
        WETH = WETH9(payable(address(AUX.WETH())));
        WETH.approve(address(AUX), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
        require(QUID.V4() == address(this), "?");

        VANILLA_ETH = PoolKey({
            currency0: Currency.wrap(
                 address(token0_eth)),
            currency1: Currency.wrap(
                 address(token1_eth)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))}); 

        VANILLA_BTC = PoolKey({
            currency0: Currency.wrap(
                 address(token0_btc)),
            currency1: Currency.wrap(
                 address(token1_btc)),
            fee: 420, tickSpacing: 60,
            hooks: IHooks(address(0))}); 

        (,int24 tickETH,,,,,) = IUniswapV3Pool(_poolETH).slot0();
        (,int24 tickBTC,,,,,) = IUniswapV3Pool(_poolBTC).slot0();

        if (token1isETH)
            tickETH *= AUX.token1isWETH() ? int24(1) : int24(-1);
        else 
            tickETH *= AUX.token1isWETH() ? int24(-1) : int24(1);

        if (token1isBTC)
            tickBTC *= AUX.token1isWBTC() ? int24(1) : int24(-1);
        else 
            tickBTC *= AUX.token1isWBTC() ? int24(-1) : int24(1);
        
        poolManager.initialize(VANILLA_ETH, 
        TickMath.getSqrtPriceAtTick(tickETH));

        poolManager.initialize(VANILLA_BTC, 
        TickMath.getSqrtPriceAtTick(tickBTC));

        // renounceOwnership(); TODO
    }

    // withdrawal by LP of ETH specifically, depositor may
    // not know exactly how much they have accumulated in 
    // fees, so it's alright to pass in a huge number...
    function withdraw(uint amount, bool btc) external { 
        (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = _repack(btc); 
        Types.Deposit memory LP = autoManaged[msg.sender]; 

        uint eth_fees = ETH_FEES; uint usd_fees = USD_FEES_ETH;
        // ^ above snapshots will always be bigger than LP's

        uint pooled_eth = ETH_POOLED;
        uint fees_eth = FullMath.mulDiv((eth_fees - LP.fees_eth),
                                      LP.pooled_eth, pooled_eth);

        uint fees_usd = FullMath.mulDiv((usd_fees - LP.fees_usd),
                                      LP.pooled_eth, pooled_eth);
        LP.pooled_eth += fees_eth;       
        fees_usd += LP.usd_owed;
        if (fees_usd > 0) { LP.usd_owed = 0; 
            QUID.mint(msg.sender, fees_usd, // TODO bypass AUX.deposit for this 
                        address(QUID), 0); 
        }
        amount = Math.min(amount, 
                    LP.pooled_eth);

        if (amount > 0) { uint pulled;
            LP.pooled_eth -= amount;
            pulled = Math.min(amount, pooled_eth);
            if (pulled > 0) { amount -= pulled;
                abi.decode(poolManager.unlock(abi.encode(
                    Action.ModLP, sqrtPriceX96, pulled, 0, 
                    tickLower, tickUpper, msg.sender)), (BalanceDelta)); 
            } 
            if (amount > 0)
                require(amount == _sendETH(amount, msg.sender)); 
        }
        if (LP.pooled_eth == 0) delete autoManaged[msg.sender]; 
        else LP.fees_eth = eth_fees; LP.fees_usd = usd_fees; 
    }
   
    function takeETH(uint howMuch) 
        external onlyAux returns (uint) {
        return _sendETH(howMuch, msg.sender);
    }

     function _takeWETH(uint howMuch) internal returns (uint withdrawn) {
        uint amount = Math.min(wethVault.balanceOf(address(this)),
                               wethVault.convertToShares(howMuch));
        withdrawn = wethVault.redeem(amount, address(this), address(this));
    }   

    function _sendBTC(uint howMuch,
        address toWhom) internal returns (uint sent) {
        
    }

    function _sendETH(uint howMuch,
        address toWhom) internal returns (uint sent) {
        // unused gas from clearSwaps() lands back in 
        // address(this) as residual ETH; re-appropriate:
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) {
            // Already have enough ETH
            sent = howMuch;
        } else {
            // Need to withdraw more WETH
            uint needed = howMuch - alreadyInETH;
            uint withdrawn = _takeWETH(needed);
            WETH.withdraw(withdrawn);
            sent = withdrawn + alreadyInETH;
        }
        (bool _success, ) = payable(toWhom).call{ value: sent }("");
        assert(_success);
    }

    function _depositETH(uint amount) internal returns (uint) {
       if (amount > 0) { 
            WETH.transferFrom(msg.sender, address(this), amount);
        } 
        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            amount += msg.value;
        }
        wethVault.deposit(amount, address(this));
        return amount;  // Return the total amount
    }
    // this is for single-sided liquidity (ETH deposit)
    // if you want to deposit dollars, mint with Basket
    function deposit(uint amount, bool btc) 
        external payable { amount = _depositETH(amount); 
        Types.Deposit memory LP = autoManaged[msg.sender];
        uint pooled_eth = ETH_POOLED;
        uint pooled_usd = ETH_POOLED_USD;
        uint deltaETH; uint deltaUSD; 
        LP.pooled_eth += amount;
        (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = _repack(btc); 
        uint price = AUX.getPrice(sqrtPriceX96, false, btc);
        uint eth_fees = ETH_FEES; uint usd_fees = USD_FEES_ETH;
        if (LP.fees_eth > 0 || LP.fees_usd > 0) {
            LP.usd_owed += FullMath.mulDiv((usd_fees - LP.fees_usd),
                                          LP.pooled_eth, pooled_eth);

            LP.pooled_eth += FullMath.mulDiv((eth_fees - LP.fees_eth),
                                            LP.pooled_eth, pooled_eth);
        }
        LP.fees_eth = eth_fees; LP.fees_usd = usd_fees;
        (deltaUSD, deltaETH) = _addLiquidityHelper(
                         pooled_usd, amount, price);

        if (deltaUSD > 0) { require(deltaETH > 0, "+");
            abi.decode(poolManager.unlock(abi.encode(
                Action.ModLP, sqrtPriceX96, deltaETH, deltaUSD, 
                tickLower, tickUpper, msg.sender)), (BalanceDelta));
        }                 autoManaged[msg.sender] = LP; 
    }

    function _addLiquidityHelper(
        uint deltaUSD, uint deltaETH, 
        uint price) internal returns (uint, uint) {
        
        (uint total, ) = AUX.get_metrics(false);
        deltaUSD *= 1e12; // covert to units of 1e18
        // because the total is normalized to 1e18...

        uint surplus = total > deltaUSD ? 
                       total - deltaUSD : 0;

        // TODO do we need to mockUSD.burn() if deltaUSD > total
        // this is an edge that will probably not happen but it can
        // if there is huge withdrawal??

        deltaETH = Math.min(
            wethVault.maxWithdraw(address(this)),
            FullMath.mulDiv(surplus, WAD, price));

        if (deltaETH > 0) 
            deltaUSD = FullMath.mulDiv(deltaETH,
                              price, WAD * 1e12);
        
        return (deltaUSD, deltaETH);
    }

    /// @notice Create a single-sided liquidity position outside the current price range
    /// @dev Automatically adjusts for token ordering to ensure valid positions
    /// @param amount Amount of tokens to deposit (0 if sending ETH as msg.value)
    /// @param token Token address (address(0) for ETH, or stablecoin address for USD)
    /// @param distance Distance from current price in ticks  
    /// positive = subtract (below), negative = add (above)
    /// @param range Width of the position in ticks 
    /// @param btc if it's for BTC pool (false for ETH)
    /// @return next The ID of the newly created position
    function outOfRange(uint amount, address token, 
        int24 distance, int24 range, bool btc) 
        public payable returns (uint next) {
        int24 width = btc ? int24(60) : int24(10);
        require(range >= 100 && range <= 1000 && range % 50 == 0, 
            "Range must be 100-1000 in increments of 50");
        require(distance % 100 == 0 && distance != 0 && 
            distance >= -5000 && distance <= 5000, 
            "Distance must be -5000 to 5000 in increments of 100");

        (uint160 currentSqrtPrice, int24 currentLowerTick, 
        int24 currentUpperTick,) = _repack(btc);
        int24 targetTick = TickMath.getTickAtSqrtPrice(
                           currentSqrtPrice) - distance;
        
        // Create range starting from target...
        int24 newLowerTick; int24 newUpperTick;
        if (distance < 0) { // above the current price...
            newLowerTick = _alignTick(targetTick, width);
            newUpperTick = _alignTick(targetTick + range, width);
        } else { 
            newUpperTick = _alignTick(targetTick, width);
            newLowerTick = _alignTick(targetTick - range, width);
        }
        uint160 lowerSqrtPrice = TickMath.getSqrtPriceAtTick(newLowerTick);
        uint160 upperSqrtPrice = TickMath.getSqrtPriceAtTick(newUpperTick);
        
        // Verify position is truly outside current range...
        bool aboveCurrent = newLowerTick > currentUpperTick;
        bool belowCurrent = newUpperTick < currentLowerTick;
        require(aboveCurrent || belowCurrent, 
            "Position overlaps with current range");
    
        uint128 liquidity;
        if (token == address(0)) { 
            amount = _depositETH(amount);
            require(belowCurrent);
            if (token1isETH)
                // Below current = sell ETH for USD (provide ETH)
                // Above current = buy ETH with USD (provide $)
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                             lowerSqrtPrice, upperSqrtPrice, amount);
            else // Below current = buy USD with ETH (provide ETH)
                // Above current = sell USD for ETH (provide $)
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                             lowerSqrtPrice, upperSqrtPrice, amount);
        } else {
            uint deposited = AUX.deposit(msg.sender, token, amount);
            uint decimals = IERC20(token).decimals();
            if (decimals > 6) deposited /= 10 ** (decimals - 6);
            require(aboveCurrent);
            if (token1isETH)
                // Above current = buy ETH with USD (provide $)
                // Below current = sell ETH for USD (provide ETH)
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                          lowerSqrtPrice, upperSqrtPrice, deposited);
            else
                // Above current = sell ETH for USD (provide ETH)
                // Below current = buy ETH with USD (provide $)
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                          lowerSqrtPrice, upperSqrtPrice, deposited);
        }
        Types.SelfManaged memory newPosition = Types.SelfManaged({owner: msg.sender, 
            lower: newLowerTick, upper: newUpperTick, liq: int(uint(liquidity))});

        next = ++ID;
        selfManaged[next] = newPosition;
        positions[msg.sender].push(next);
        abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, msg.sender, 
            int(uint(liquidity)), newLowerTick, 
            newUpperTick)), (BalanceDelta));
    }

    // pull liquidity from self-managed position
    function pull(uint id, int percent) external {
        Types.SelfManaged memory position = selfManaged[id];
        require(position.owner == msg.sender, "403");
        require(percent > 0 && percent < 101, "%");
        int liquidity = position.liq * percent / 100;
        uint[] storage myIds = positions[msg.sender];
        uint lastIndex = myIds.length - 1;
        if (percent == 100) { delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) {
                        myIds[i] = myIds[lastIndex];
                    }   myIds.pop(); break;
                }
            }
        } else {    position.liq -= liquidity;
            require(position.liq > 0, "pull");
            selfManaged[id] = position;
        }
        abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, msg.sender, -liquidity,
            position.lower, position.upper)), (BalanceDelta));
    }

    // this is for batched swaps, which clear through simple ASS...
    function pushSwap(bool zeroForOne, // < direction of this swap
        Types.Trade calldata trade, uint waitable, bool btc) onlyAux public 
        returns (uint currentBlock) { currentBlock = block.number;
        Types.Batch storage forOne; Types.Batch storage forZero;
        if (btc) {
            forOne = BTCswapsZeroForOne[currentBlock];
            forZero = BTCswapsOneForZero[currentBlock];
            while (forOne.swaps.length + forZero.swaps.length > 30) {
                currentBlock += 1;
                forOne = BTCswapsZeroForOne[currentBlock];
                forZero = BTCswapsOneForZero[currentBlock];
            }
        } else {
            forOne = ETHswapsZeroForOne[currentBlock];
            forZero = ETHswapsOneForZero[currentBlock];
            while (forOne.swaps.length + forZero.swaps.length > 30) {
                currentBlock += 1;
                forOne = ETHswapsZeroForOne[currentBlock];
                forZero = ETHswapsOneForZero[currentBlock];
            }
        }
        Types.Batch storage ourBatch; // < will be writing to this
        require(waitable >= currentBlock - block.number, "time");
        ourBatch = zeroForOne ? forOne : forZero;
        ourBatch.swaps.push(trade); 
        ourBatch.total += trade.amount;
    } 

    function getSwapsETH(uint blockNumber) public view returns 
        (Types.Batch memory, Types.Batch memory) {
        if (token1isETH)
            return (ETHswapsOneForZero[blockNumber], 
                    ETHswapsZeroForOne[blockNumber]);
        else
            return (ETHswapsZeroForOne[blockNumber], 
                    ETHswapsOneForZero[blockNumber]);
    }

    function getSwapsBTC(uint blockNumber) public view returns 
        (Types.Batch memory, Types.Batch memory) {
        if (token1isBTC)
            return (BTCswapsOneForZero[blockNumber], 
                    BTCswapsZeroForOne[blockNumber]);
        else
            return (BTCswapsZeroForOne[blockNumber], 
                    BTCswapsOneForZero[blockNumber]);
    }
    // TODO add btc as callback parameter
    function swap(uint160 sqrtPriceX96, address sender, 
        bool forOne, address token, uint amount, bool btc) 
        onlyAux public returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(Action.Swap, 
            sqrtPriceX96, sender, forOne, token, amount)), (BalanceDelta));
    }
    // TODO add btc as callback parameter
    
    function batchSwap(uint160 sqrtPriceX96, uint blockNumber, 
        uint splitForUSD, uint splitForETH, uint gotForETH, 
        uint gotForUSD, bool btc) onlyAux public returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(Action.BatchSwap, 
                    sqrtPriceX96, blockNumber, splitForUSD, splitForETH, 
                    gotForETH, gotForUSD)), (BalanceDelta));
    }

    // what does it take for her to call me back
    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte; BalanceDelta delta;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminator = Action(firstByte);
        // ^ similar to Solana program entrypoint
        if (discriminator == Action.Swap) {
             (uint160 sqrtPriceX96, address sender, bool forOne,
                address token, uint amount) = abi.decode(data[32:], 
                 (uint160, address, bool, address, uint));
            
            delta = poolManager.swap(VANILLA_ETH, IPoolManager.SwapParams({
                    zeroForOne: forOne, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                          !forOne, 3000) }), ZERO_BYTES);
            if (token1isETH)
                _handleDelta0isUSD(delta, true, false, 
                                 sender, token, false);
            else
                _handleDelta1isUSD(delta, true, false,
                                 sender, token, false); // TODO btc
        } 
        else if (discriminator == Action.BatchSwap) {
            // NOTE: order is crucial (first buy ETH)
            (uint160 sqrtPriceX96, uint lastBlock,
             uint splitForUSD, uint splitForETH,
             uint gotForETH, uint gotForUSD) = abi.decode(
                data[32:], (uint160, uint, uint, uint, uint, uint));

            uint swapped; uint i;
            (Types.Batch memory forUSD, // TODO getSwapsBTC
            Types.Batch memory forETH) = getSwapsETH(lastBlock);
            
            uint amount = forETH.total - splitForETH;
            // we substract split because that amount
            // was already covered by V3, only needs
            // to be distributed (not swapped by V4) 
            if (amount > 0) { 
                delta = poolManager.swap(VANILLA_ETH, 
                    IPoolManager.SwapParams({ zeroForOne: token1isETH, 
                    amountSpecified: -int(amount), sqrtPriceLimitX96: 
                        _paddedSqrtPrice(sqrtPriceX96, false, 3000) }), ZERO_BYTES);
                
                if (token1isETH)
                    (, swapped) = _handleDelta0isUSD(delta, true, false, 
                                        address(0), address(QUID), false);
                else
                    (swapped, ) = _handleDelta1isUSD(delta, true, false, 
                                        address(0), address(QUID), false);
                
                // must obtain a new price in light of the above swaps...
                swapped += gotForUSD; (sqrtPriceX96,,,) = poolManager.getSlot0(
                                                            VANILLA_ETH.toId()); 
               
                require(stdMath.delta(swapped, FullMath.mulDiv(forETH.total * 1e12, WAD, 
                        AUX.getPrice(sqrtPriceX96, false, false))) <= swapped / 50);

                for (i = 0; i < forETH.swaps.length; i++) {
                    // we get the ETH amount to send by...
                    amount = FullMath.mulDiv(swapped, // % given from
                    // dollars being sold by sender over total dollars 
                              forETH.swaps[i].amount, forETH.total);
                           _sendETH(amount, forETH.swaps[i].sender);
                }
            }   
            amount = forUSD.total - splitForUSD;
            // we substract split because that amount
            // was already covered by V3, only needs
            // to be distributed (not swapped by V4) 
            if (amount > 0) {
                delta = poolManager.swap(VANILLA_ETH, IPoolManager.SwapParams({
                    zeroForOne: !token1isETH, amountSpecified: -int(amount),
                    sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                                        true, 3000) }), ZERO_BYTES);
                if (token1isETH)
                    (swapped,) = _handleDelta0isUSD(delta, true, false, 
                                      address(0), address(QUID), false);
                else 
                    (, swapped) = _handleDelta1isUSD(delta, true, false, 
                                       address(0), address(QUID), false);
           
                address out; uint scale; swapped += gotForETH;
                (sqrtPriceX96,,,) = poolManager.getSlot0(
                                      VANILLA_ETH.toId());

                require(stdMath.delta(swapped, FullMath.mulDiv(forUSD.total, 
                    AUX.getPrice(sqrtPriceX96, false, false), WAD * 1e12)) <= swapped / 50);

                for (i = 0; i < forUSD.swaps.length; i++) {
                    out = forUSD.swaps[i].token;
                    amount = FullMath.mulDiv(swapped, 
                        forUSD.swaps[i].amount, forUSD.total);

                    scale = IERC20(out).decimals() - 6; 
                    amount *= scale > 0 ? (10 ** scale) : 1;
                    uint actualReceived = AUX.take(forUSD.swaps[i].sender, 
                                                    amount, out, false);
                }
            } delete ETHswapsOneForZero[lastBlock];
              delete ETHswapsZeroForOne[lastBlock];
        } 
        else if (discriminator == Action.Repack) {
            // remove all liquidity, then add it back
            (uint128 myLiquidity, uint160 sqrtPriceX96,
            int24 tickLower, int24 tickUpper, bool btc) = abi.decode(
                    data[32:], (uint128, uint160, int24, int24, bool));
                    uint price = AUX.getPrice(sqrtPriceX96, false, btc);
                    
            uint volatile_fees; uint stable_fees;
            // ^ these 2 are accounting our gains
            // collected since last repack event
            uint delta0; uint delta1; bool flip;
            if (btc) { flip = token1isBTC;
                BTC_POOLED_USD = 0;
                BTC_POOLED = 0;
            } else { flip = token1isETH;
                ETH_POOLED_USD = 0;
                ETH_POOLED = 0;
            }
            BalanceDelta fees; 
            (delta, fees) = _modifyLiquidity(-int(uint(myLiquidity)), 
                                        tickLower, tickUpper, btc);
            if (flip) { // flip is true, token1 is volatile
                (delta0, // who is irrelevant (address(0))
                 delta1) = _handleDelta0isUSD(delta, false, true, 
                                address(0), address(QUID), btc);
             
                stable_fees = uint(int(fees.amount0()));
                volatile_fees = uint(int(fees.amount1()));
                
                _calculateYield(volatile_fees, stable_fees,
                                delta1, delta0, price, btc);
            } else { // token0 is the volatile token...
                (delta0, // who is irrelevant (address(0))
                 delta1) = _handleDelta1isUSD(delta, false, true, 
                                address(0), address(QUID), btc);

                stable_fees = uint(int(fees.amount1()));
                volatile_fees = uint(int(fees.amount0()));

                _calculateYield(volatile_fees, stable_fees, 
                                delta0, delta1, price, btc);
            }
            (tickLower,, 
             tickUpper,) = updateTicks(
                sqrtPriceX96, 200, btc);
            if (btc) {
                UPPER_TICK_BTC = tickUpper;
                LOWER_TICK_BTC = tickLower;
                USD_FEES_BTC += stable_fees;
                BTC_FEES += volatile_fees;
            } else {
                UPPER_TICK_ETH = tickUpper;
                LOWER_TICK_ETH = tickLower;
                USD_FEES_ETH += stable_fees;
                ETH_FEES += volatile_fees;
            }
            if (flip) {
                (delta0, delta1) = _addLiquidityHelper(
                                      0, delta1, price);

                delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96, btc);

                _handleDelta0isUSD(delta, true, false,
                        address(0), address(QUID), btc);
            } else {
                (delta1, delta0) = _addLiquidityHelper(
                                      0, delta0, price);

                delta = _modLP(delta1, delta0, tickLower,
                            tickUpper, sqrtPriceX96, btc);
                
                _handleDelta1isUSD(delta, true, false,
                        address(0), address(QUID), btc);
            }
        } else if (discriminator == Action.OutsideRange) {
            (address sender, int liquidity, 
            int24 tickLower, int24 tickUpper) = abi.decode(
                    data[32:], (address, int, int24, int24));

            (delta, ) = _modifyLiquidity(liquidity,
                            tickLower, tickUpper, false); // TODO BTC

            if (token1isETH)
                _handleDelta0isUSD(delta, false, false,
                          sender, address(QUID), false);
            else
                _handleDelta1isUSD(delta, false, false,
                         sender, address(QUID), false);
        }
        else if (discriminator == Action.ModLP) {
            (uint160 sqrtPriceX96, uint deltaETH, uint deltaUSD,
            int24 tickLower, int24 tickUpper, address sender) = abi.decode(
                    data[32:], (uint160, uint, uint, int24, int24, address));
            
            delta = _modLP(deltaUSD, deltaETH, tickLower,
                                tickUpper, sqrtPriceX96, false); // TODO 
                                bool keep = deltaUSD == 0;
                                
            if (token1isETH)
                _handleDelta0isUSD(delta, true, keep, 
                         sender, address(QUID), false);
            else
                _handleDelta1isUSD(delta, true, keep, 
                         sender, address(QUID), false);
        }   
        return abi.encode(delta);
    } 

    // if who = address(0), keep & token are
    // irrelevant (for repack and batch swaps)
    function _handleDelta0isUSD(BalanceDelta delta, bool inRange, 
        bool keep, address who, address token, bool btc) internal 
        returns (uint delta0, uint delta1) { PoolKey storage pool;
        uint POOLED_TOKEN0; uint POOLED_TOKEN1;
        address volatile; address stable; 
        if (btc) { pool = VANILLA_BTC;
            stable = address(USDmock);
            volatile = address(mockBTC);
            POOLED_TOKEN1 = BTC_POOLED;
            POOLED_TOKEN0 = BTC_POOLED_USD;
        } 
        else { pool = VANILLA_ETH;
            stable = address(mockUSD);
            volatile = address(mockETH);
            POOLED_TOKEN1 = ETH_POOLED;
            POOLED_TOKEN0 = ETH_POOLED_USD;
        }
        if (delta.amount0() > 0) {
            delta0 = uint(int(delta.amount0()));
            pool.currency0.take(poolManager,
                address(this), delta0, false);
            
            mockToken(stable).burn(delta0); 
            if (inRange) POOLED_TOKEN0 -= delta0;
            if (!keep && who != address(0)) {
                uint scale = IERC20(token).decimals() - 6;
                if (scale > 0) // upscale
                    delta0 *= 10 ** scale;
    
                // Increase tolerance for fees - allow up to 2% difference
                uint actualReceived = AUX.take(who, delta0, token, false);
                require(stdMath.delta(delta0, actualReceived) <= delta0 / 50, "fee");
            } // keep is for preventing disbursal of $ 
            // when single-sided LPs withdraw their ETH 
        }
        else if (delta.amount0() < 0) {
            delta0 = uint(int(-delta.amount0())); 
            mockToken(stable).mint(delta0);
            pool.currency0.settle(poolManager, 
                address(this), delta0, false);
            if (inRange) POOLED_TOKEN0 += delta0;
        } 
        if (delta.amount1() > 0) { 
            delta1 = uint(int(delta.amount1()));
            pool.currency1.take(poolManager, 
                address(this), delta1, false);
            mockToken(volatile).burn(delta1); 
            if (inRange) POOLED_TOKEN1 -= delta1;
            if (who != address(0)) btc ? _sendBTC(delta1, who): 
                                         _sendETH(delta1, who);
        } 
        else if (delta.amount1() < 0) {
            delta1 = uint(int(-delta.amount1())); 
            mockToken(volatile).mint(delta1);
            pool.currency1.settle(poolManager, 
                address(this), delta1, false);
            if (inRange) POOLED_TOKEN1 += delta1;
        }
        if (btc) {
            BTC_POOLED = POOLED_TOKEN1;
            BTC_POOLED_USD = POOLED_TOKEN0;
        } else {
            ETH_POOLED = POOLED_TOKEN1;
            ETH_POOLED_USD = POOLED_TOKEN0;
        }
    }

    function _handleDelta1isUSD(BalanceDelta delta, bool inRange, 
        bool keep, address who, address token, bool btc) internal 
        returns (uint delta0, uint delta1) { PoolKey storage pool;
        uint POOLED_TOKEN0; uint POOLED_TOKEN1;
        address volatile; address stable; 
        if (btc) { pool = VANILLA_BTC;
            stable = address(USDmock);
            volatile = address(mockBTC);
            POOLED_TOKEN1 = BTC_POOLED_USD;
            POOLED_TOKEN0 = BTC_POOLED;
        } 
        else { pool = VANILLA_ETH;
            stable = address(mockUSD);
            volatile = address(mockETH);
            POOLED_TOKEN1 = ETH_POOLED_USD;
            POOLED_TOKEN0 = ETH_POOLED;
        }
        if (delta.amount0() > 0) {
            pool.currency0.take(poolManager, 
                address(this), delta0, false);
            mockToken(volatile).burn(delta0);
            if (inRange) POOLED_TOKEN0 -= delta0;
            if (who != address(0)) btc ? _sendBTC(delta0, who): 
                                         _sendETH(delta0, who);          
        } // liquidity pool received ETH
        else if (delta.amount0() < 0) { 
            delta0 = uint(int(-delta.amount0())); 
            mockToken(volatile).mint(delta0);
            pool.currency0.settle(poolManager, 
                address(this), delta0, false);
            if (inRange) POOLED_TOKEN0 += delta0;
        } 
        if (delta.amount1() > 0) { 
            delta1 = uint(int(delta.amount1()));
            pool.currency1.take(poolManager,
                address(this), delta1, false);
            
            mockToken(stable).burn(delta1); 
            if (inRange) POOLED_TOKEN1 -= delta1;
            if (!keep && who != address(0)) {
                uint scale = IERC20(token).decimals() - 6;
                if (scale > 0) // upscale
                    delta1 *= 10 ** scale;
                
                // Increase tolerance for fees - allow up to 2% difference
                uint actualReceived = AUX.take(who, delta1, token, false);
                require(stdMath.delta(delta1, actualReceived) <= delta1 / 50, "fee");
            } // keep is for preventing disbursal of $ 
            // when single-sided LPs withdraw their ETH 
        } 
        else if (delta.amount1() < 0) {
            delta1 = uint(int(-delta.amount1())); 
            mockToken(stable).mint(delta1);
            pool.currency1.settle(poolManager, 
                address(this), delta1, false);
            if (inRange) POOLED_TOKEN1 += delta1;
        }
        if (btc) {
            BTC_POOLED = POOLED_TOKEN0;
            BTC_POOLED_USD = POOLED_TOKEN1;
        } else {
            ETH_POOLED = POOLED_TOKEN0;
            ETH_POOLED_USD = POOLED_TOKEN1;
        }
    }

    function _modifyLiquidity(int delta, // liquidity delta
        int24 lowerTick, int24 upperTick, bool btc) internal returns 
        (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        PoolKey storage pool = btc ? VANILLA_BTC : VANILLA_ETH;
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            pool, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }
    
    // TODO rename from deltaETH to delta other side
    function _modLP(uint deltaUSD, uint deltaETH, int24 tickLower, 
        int24 tickUpper, uint160 sqrtPriceX96, bool btc) internal returns (BalanceDelta) { 
        uint128 liquidity = token1isETH ? LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, deltaETH) : 
                    LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, 
                        TickMath.getSqrtPriceAtTick(tickUpper), deltaETH);
                               int flip = deltaUSD > 0 ? int(1) : int(-1);
        (BalanceDelta totalDelta, 
         BalanceDelta feesAccrued) = _modifyLiquidity(flip * 
            int(uint(liquidity)), tickLower, tickUpper, btc);
        return totalDelta; // if we called _modify with (-) liquidity
        // then funds left the pool, so totalDelta should be positive
    }
    
    function _alignTick(int24 tick, int24 width)
        internal pure returns (int24) {
        if (tick < 0 && tick % width != 0) {
            return ((tick - width + 1) / width) * width;
        }   return (tick / width) * width;
    }

    function updateTicks(uint160 sqrtPriceX96, uint delta, 
        bool btc) public pure returns (int24 tickLower, 
        uint160 lower, int24 tickUpper, uint160 upper) {
        
        lower = _paddedSqrtPrice(sqrtPriceX96, false, delta);
        upper = _paddedSqrtPrice(sqrtPriceX96, true, delta);

        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minPrice");
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxPrice");

        int24 width = btc ? int24(60) : int24(10); 

        tickLower = _alignTick(TickMath.getTickAtSqrtPrice(lower), width);        
        tickUpper = _alignTick(TickMath.getTickAtSqrtPrice(upper), width);
    }

    function _calculateYield(uint fees, uint usd_fees, uint delta, 
        uint deltaUSD, uint price, bool btc) internal returns (uint yield) {
        uint last_repack = btc ? LAST_REPACK_BTC : LAST_REPACK_ETH;
        if (last_repack > 0) { // extrapolate (guestimate) an annual % yield... 
            // based on the % fee yield of the last period (in between repacks)
            yield = FullMath.mulDiv(365 days / (block.timestamp - last_repack),
                           usd_fees * 1e12 + FullMath.mulDiv(price, fees, WAD), 
                          deltaUSD * 1e12 + FullMath.mulDiv(price, delta, WAD));
            
            if (btc) LAST_REPACK_BTC = block.timestamp; 
            else LAST_REPACK_ETH = block.timestamp; 
        } 
    }

    function _paddedSqrtPrice(uint160 sqrtPriceX96, 
        bool up, uint delta) internal pure returns (uint160) { 

        uint x = up ? FixedPointMathLib.sqrt(1e18 + delta * 1e14):
                      FixedPointMathLib.sqrt(1e18 - delta * 1e14);
                      
        return uint160(FixedPointMathLib.mulDivDown(x, uint(sqrtPriceX96),
                       FixedPointMathLib.sqrt(1e18)));
    }

    function _repack(bool btc) internal // auto-trigger
        returns (uint160 sqrtPriceX96, int24 tickLower, 
        int24 tickUpper, uint128 myLiquidity) { 
        int24 currentTick; PoolId pool; 
        if (btc) {
            pool = VANILLA_BTC.toId();
            tickUpper = UPPER_TICK_BTC;
            tickLower = LOWER_TICK_BTC;
        } else {
            pool = VANILLA_ETH.toId();
            tickUpper = UPPER_TICK_ETH;
            tickLower = LOWER_TICK_ETH;
        }
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(pool);
        if (currentTick > tickUpper || currentTick < tickLower) { 
            myLiquidity = poolManager.getLiquidity(pool);
            if (myLiquidity > 0) { // rm, then add liquidity
                poolManager.unlock(abi.encode(Action.Repack,
                                  myLiquidity, sqrtPriceX96, 
                                tickLower, tickUpper, btc));
            } else { // we only go in here once (first time)
                (tickLower,, 
                 tickUpper,) = updateTicks(sqrtPriceX96, 200, btc);
                // 1% delta up, 1% down from ^^^^^^ (2% wide)
                if (btc) {
                    UPPER_TICK_BTC = tickUpper; 
                    LOWER_TICK_BTC = tickLower;
                } else {
                    UPPER_TICK_ETH = tickUpper; 
                    LOWER_TICK_ETH = tickLower;
                }
            }            
        }
    }

    function repack(bool btc) public onlyAux returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        (sqrtPriceX96, tickLower, tickUpper, myLiquidity) = _repack(btc);
        return (sqrtPriceX96, tickLower, tickUpper, myLiquidity);
    }
}