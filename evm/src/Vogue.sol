
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Basket} from "./Basket.sol";
// import {BasketL2 as Basket} from "./BasketL2.sol";

import "lib/forge-std/src/console.sol"; // TODO
import {stdMath} from "forge-std/StdMath.sol";
import {Types} from "./imports/Types.sol";
import {VogueCore} from "./VogueCore.sol";
import {Aux} from "./Aux.sol";

contract Vogue is Ownable {
    IERC4626 public wethVault;
    uint constant WAD = 1e18;
    VogueCore V4; WETH9 WETH; 
    bool public token1isETH;
    Basket QUID; Aux AUX; 

    uint public LAST_REPACK;
    // range = between ticks
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    
    // ^ timestamp allows us
    // to measure APY% for...
    uint public USD_FEES;
    uint public ETH_FEES;
    uint public YIELD;
    
    mapping(uint => Types.Batch) swapsZeroForOne;
    mapping(uint => Types.Batch) swapsOneForZero;
    mapping(address => Types.Deposit) autoManaged;
    // ^ price range is managed by our contracts
    mapping(address => uint[]) positions;    
    // ^ allows several selfManaged positions
    mapping(uint => Types.SelfManaged) selfManaged;
    // ^ key is tokenId of ID++ for that position
    uint internal ID; 
    // ^ always grows
    
    constructor(address _vault) Ownable(msg.sender) { 
        wethVault = IERC4626(_vault);
    }   fallback() external payable {}

     modifier onlyAux {
        require(msg.sender == address(AUX)
             || msg.sender == address(V4), "403"); _;
    }
    
    function setup(address _quid, // < Basket...
        address _aux, address _core) external { 
        require(address(AUX) == address(0), "!");

        V4 = VogueCore(_core);
        QUID = Basket(_quid);
        AUX = Aux(payable(_aux));

        token1isETH = V4.token1isETH();
        require(QUID.V4() == address(this), "?");
        WETH = WETH9(payable(address(AUX.WETH())));
        WETH.approve(address(AUX), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
    }

    // this is for batched swaps, which clear through simple ASS...
    function pushSwap(bool zeroForOne, // < direction of this swap
        Types.Trade calldata trade, uint waitable) onlyAux public 
        returns (uint currentBlock) { currentBlock = block.number;
        Types.Batch storage forOne; Types.Batch storage forZero;
       
        forOne = swapsZeroForOne[currentBlock];
        forZero = swapsOneForZero[currentBlock];
        while (forOne.swaps.length + forZero.swaps.length > 30) {
            currentBlock += 1;
            forOne = swapsZeroForOne[currentBlock];
            forZero = swapsOneForZero[currentBlock];
        }
        Types.Batch storage ourBatch; // < will be writing to this
        require(waitable >= currentBlock - block.number, "time");
        ourBatch = zeroForOne ? forOne : forZero;
        ourBatch.swaps.push(trade); 
        ourBatch.total += trade.amount;
    } 

    function getSwapsETH(uint blockNumber) public view 
        returns (Types.Batch memory, Types.Batch memory) {
        if (token1isETH)
            return (swapsOneForZero[blockNumber], 
                    swapsZeroForOne[blockNumber]);
        else
            return (swapsZeroForOne[blockNumber], 
                    swapsOneForZero[blockNumber]);
    }

    function _outOfRangeTicks(uint160 currentSqrtPrice, 
        int24 width, int24 range, int24 distance) internal 
        returns (int24 newLowerTick, int24 newUpperTick) {
        int24 targetTick = TickMath.getTickAtSqrtPrice(
                           currentSqrtPrice) - distance;
      
        if (distance < 0) { // above the current price
            newLowerTick = _alignTick(targetTick, width);
            newUpperTick = _alignTick(targetTick + range, width);
        } else { 
            newUpperTick = _alignTick(targetTick, width);
            newLowerTick = _alignTick(targetTick - range, width);
        }
    }

    /// @notice Create a single-sided liquidity position outside the current price range
    /// @dev Automatically adjusts for token ordering to ensure valid positions
    /// @param amount Amount of tokens to deposit (0 if sending ETH as msg.value)
    /// @param token Token address (address(0) for ETH, or stablecoin address for USD)
    /// @param distance Distance from current price in ticks  
    /// positive = subtract (below), negative = add (above)
    /// @param range Width of the position in ticks 
    /// @return next The ID of the newly created position
     function outOfRange(uint amount, address token, 
        int24 distance, int24 range) public 
        payable returns (uint next) { int24 width = int24(10);
        require(range >= 100 && range <= 1000 && range % 50 == 0, 
            "Range must be 100-1000 in increments of 50");
        require(distance % 100 == 0 && distance != 0 && 
            distance >= -5000 && distance <= 5000, 
            "Distance must be -5000 to 5000 in increments of 100");

        if (!token1isETH) distance = -distance; 

        (uint160 currentSqrtPrice, 
        int24 currentLowerTick, 
        int24 currentUpperTick,) = _repack();
        
        (int24 newLowerTick, int24 newUpperTick) = _outOfRangeTicks(
                            currentSqrtPrice, width, range, distance);
        uint128 liquidity;
        if (token == address(0)) { amount = _depositETH(amount);
            if (token1isETH) {
                require(newLowerTick > currentUpperTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                             TickMath.getSqrtPriceAtTick(newLowerTick), 
                             TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            } else {
                require(newUpperTick < currentLowerTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                             TickMath.getSqrtPriceAtTick(newLowerTick), 
                             TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            }
        } else { amount = AUX.deposit(msg.sender, token, amount);
            if (IERC20(token).decimals() > 6) 
                amount /= 10 ** (IERC20(token).decimals() - 6);
            if (token1isETH) {
                require(newUpperTick < currentLowerTick);
                // Above current = buy ETH with USD (provide $)
                // Below current = sell ETH for USD (provide ETH)
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                          TickMath.getSqrtPriceAtTick(newLowerTick), 
                          TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            } else {
                require(newLowerTick > currentUpperTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                          TickMath.getSqrtPriceAtTick(newLowerTick), 
                          TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            }
        } Types.SelfManaged memory newPosition = Types.SelfManaged({ owner: msg.sender, 
                lower: newLowerTick, upper: newUpperTick, liq: int(uint(liquidity)) });

        next = ++ID;
        selfManaged[next] = newPosition;
        positions[msg.sender].push(next);
        V4.outOfRange(msg.sender, int(uint(liquidity)), 
                newLowerTick, newUpperTick, address(0));
    }

    function distributeBatchSwaps(uint lastBlock, uint160 sqrtPriceX96, 
        uint swappedForUSD, uint swappedForETH) external onlyAux { 
        (Types.Batch memory forUSD,
        Types.Batch memory forETH) = getSwapsETH(lastBlock);
        if (swappedForUSD > 0) {
            require(stdMath.delta(swappedForUSD, FullMath.mulDiv(
                forETH.total * 1e12, WAD, AUX.getPrice(sqrtPriceX96))) <= swappedForUSD / 50);
            
            for (uint i = 0; i < forETH.swaps.length; i++) {
                uint amount = FullMath.mulDiv(swappedForUSD, 
                    forETH.swaps[i].amount, forETH.total);
                _sendETH(amount, forETH.swaps[i].sender);
            }
        } if (swappedForETH > 0) {
            require(stdMath.delta(swappedForETH, FullMath.mulDiv(forUSD.total, 
                AUX.getPrice(sqrtPriceX96), WAD * 1e12)) <= swappedForETH / 50);
            
            for (uint i = 0; i < forUSD.swaps.length; i++) {
                address out = forUSD.swaps[i].token;
                uint amount = FullMath.mulDiv(swappedForETH, 
                    forUSD.swaps[i].amount, forUSD.total);
                
                uint scale = IERC20(out).decimals() - 6;
                amount *= scale > 0 ? (10 ** scale) : 1;
                AUX.take(forUSD.swaps[i].sender, amount, out, false);
            }
        } delete swapsOneForZero[lastBlock];
          delete swapsZeroForOne[lastBlock];
    }

    // withdrawal by LP of ETH specifically, depositor may
    // not know exactly how much they have accumulated in 
    // fees, so it's alright to pass in a huge number...
    function withdraw(uint amount) external { 
        (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = _repack(); 
        Types.Deposit memory LP = autoManaged[msg.sender]; 

        uint eth_fees = ETH_FEES; uint usd_fees = USD_FEES;
        // ^ above snapshots will always be bigger than LP's

        uint pooled_eth = V4.POOLED_ETH();
        uint fees_eth = FullMath.mulDiv((eth_fees - LP.fees_eth),
                                      LP.pooled_eth, pooled_eth);

        uint fees_usd = FullMath.mulDiv((usd_fees - LP.fees_usd),
                                      LP.pooled_eth, pooled_eth);
        LP.pooled_eth += fees_eth;       
        fees_usd += LP.usd_owed;
        if (fees_usd > 0) { LP.usd_owed = 0; 
            QUID.mint(msg.sender, fees_usd, 
                        address(QUID), 0); 
        }
        amount = Math.min(amount, LP.pooled_eth);
        if (amount > 0) { uint pulled;
            LP.pooled_eth -= amount;
            pulled = Math.min(amount, pooled_eth);
            if (pulled > 0) { amount -= pulled;
                V4.modLP(sqrtPriceX96, pulled, 0, 
                tickLower, tickUpper, msg.sender); 
            } 
            if (amount > 0)
                require(amount == _sendETH(amount, msg.sender)); 
        }
        if (LP.pooled_eth == 0) delete autoManaged[msg.sender]; 
        else LP.fees_eth = eth_fees; LP.fees_usd = usd_fees; 
    }

    // this is for single-sided liquidity (ETH deposit)
    // if you want to deposit dollars, mint with Basket
    function deposit(uint amount) 
        external payable { amount = _depositETH(amount); 
        Types.Deposit memory LP = autoManaged[msg.sender];
        uint pooled_eth = V4.POOLED_ETH();
        uint pooled_usd = V4.POOLED_USD();
        uint deltaETH; uint deltaUSD; 
        LP.pooled_eth += amount;
        (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = _repack(); 
        
        uint eth_fees = ETH_FEES; 
        uint usd_fees = USD_FEES;
        uint price = AUX.getPrice(sqrtPriceX96);
        console.log("price", price);
        if (LP.fees_eth > 0 || LP.fees_usd > 0) {
            LP.usd_owed += FullMath.mulDiv((usd_fees - LP.fees_usd),
                                          LP.pooled_eth, pooled_eth);

            LP.pooled_eth += FullMath.mulDiv((eth_fees - LP.fees_eth),
                                            LP.pooled_eth, pooled_eth);
        }
        LP.fees_eth = eth_fees; LP.fees_usd = usd_fees;
        (deltaUSD, deltaETH) = addLiquidityHelper(
                         pooled_usd, amount, price);

        autoManaged[msg.sender] = LP; 
        if (deltaUSD > 0) { require(deltaETH > 0, "+");
            V4.modLP(sqrtPriceX96, deltaETH, deltaUSD, 
                    tickLower, tickUpper, msg.sender);
        }
    }

    function addLiquidityHelper(
        uint deltaUSD, uint deltaETH, 
        uint price) public returns (uint, uint) {
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

     // pull liquidity from self-managed position
    function pull(uint id, int percent, address token) external {
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
        V4.outOfRange(msg.sender, -liquidity,
        position.lower, position.upper, token);
    }

    function takeETH(uint howMuch, address recipient) 
        external onlyAux returns (uint) {
        return _sendETH(howMuch, recipient);
    }

     function _takeWETH(uint howMuch) internal returns (uint withdrawn) {
        uint amount = Math.min(wethVault.balanceOf(address(this)),
                               wethVault.convertToShares(howMuch));
        withdrawn = wethVault.redeem(amount, address(this), address(this));
    }

    function _sendETH(uint howMuch,
        address toWhom) internal returns (uint sent) {
        // any unused gas from clearSwaps() lands back in 
        // address(this) as residual ETH; re-appropriate:
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) {
            // Already have enough 
            sent = howMuch;
        } else {
            uint needed = howMuch - alreadyInETH;
            uint withdrawn = _takeWETH(needed);
            WETH.withdraw(withdrawn);
            sent = withdrawn + alreadyInETH;
        }
        (bool _success, ) = payable(toWhom).call{ value: sent }("");
        assert(_success);
    }

    function _depositETH(uint amount) 
        internal returns (uint) {
        if (amount > 0) 
            WETH.transferFrom(msg.sender, 
                    address(this), amount);
        
        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            amount += msg.value;
        }
        wethVault.deposit(amount, address(this));
        return amount; // return the total amount
    }

    function _repack() internal returns 
        (uint160 sqrtPriceX96, int24 tickLower, 
        int24 tickUpper, uint128 myLiquidity) { int24 currentTick; 
        (sqrtPriceX96, currentTick, myLiquidity) = V4.poolStats();

        tickUpper = UPPER_TICK; tickLower = LOWER_TICK;
        if (currentTick > tickUpper || currentTick < tickLower) { 
            if (myLiquidity > 0) { // rm, then add 
                   (uint price, uint fees0, uint fees1,
                 uint delta0, uint delta1) = V4.repack(myLiquidity, sqrtPriceX96, 
                                            tickLower, tickUpper);
             
                YIELD = _calculateYield(fees0, fees1, 
                                delta0, delta1, price);
            } (tickLower,, 
               tickUpper,) = _updateTicks(sqrtPriceX96, 200);
            // 1% delta up, 1% down from ^^^^^^^^^^^^ (2% wide)
            UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
        }
    }

    function repack() public onlyAux returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        (sqrtPriceX96, tickLower, tickUpper, myLiquidity) = _repack();
    }

    function _alignTick(int24 tick, int24 width)
        internal pure returns (int24) {
        if (tick < 0 && tick % width != 0) {
            return ((tick - width + 1) / width) * width;
        }   return (tick / width) * width;
    }

    function _updateTicks(uint160 sqrtPriceX96, uint delta) 
        internal view returns (int24 tickLower, uint160 lower, 
                             int24 tickUpper, uint160 upper) {
        
        lower = paddedSqrtPrice(sqrtPriceX96, false, delta);
        upper = paddedSqrtPrice(sqrtPriceX96, true, delta);

        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minPrice");
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxPrice");

        tickLower = _alignTick(TickMath.getTickAtSqrtPrice(lower), int24(10));        
        tickUpper = _alignTick(TickMath.getTickAtSqrtPrice(upper), int24(10));
    }

    function _calculateYield(uint fees0, uint fees1, uint delta0, 
        uint delta1, uint price) internal returns (uint yield) {
        uint last_repack = LAST_REPACK; 
        uint deltaUSD; uint delta;
        uint usd_fees; uint fees;
        if (token1isETH) { 
            (delta, deltaUSD) = (delta1, delta0);
            (fees, usd_fees) = (fees1, fees0);
        } else {
            (delta, deltaUSD) = (delta0, delta1);
            (fees, usd_fees) = (fees0, fees1);
        }
        USD_FEES += usd_fees; ETH_FEES += fees;
        if (last_repack > 0) { // extrapolate (guestimate) an annual % yield... 
            // based on the % fee yield of the last period (in between repacks)
            yield = FullMath.mulDiv(365 days / (block.timestamp - last_repack),
                           usd_fees * 1e12 + FullMath.mulDiv(price, fees, WAD), 
                          deltaUSD * 1e12 + FullMath.mulDiv(price, delta, WAD));

            LAST_REPACK = block.timestamp; 
        } 
    }

    function paddedSqrtPrice(uint160 sqrtPriceX96, 
        bool up, uint delta) public view returns (uint160) {
        uint factor = up ? FixedPointMathLib.sqrt((10000 + delta) * 1e18 / 10000) 
                         : FixedPointMathLib.sqrt((10000 - delta) * 1e18 / 10000);
        return uint160(FixedPointMathLib.mulDivDown(sqrtPriceX96, factor, 1e9));
    }
}