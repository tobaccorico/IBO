

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./imports/Types.sol";
import {Basket} from "./Basket.sol";
import {Router} from "./Router.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract Auxiliary is Ownable { 
    bool public token1isWETH;
    IERC20 USDC; WETH9 WETH;
    IUniswapV3Pool v3Pool;
    Router V4; IPool AAVE;
    ISwapRouter v3Router; 
    IERC4626 wethVault;
    Basket QUID; // $QD

    uint internal _ETH_PRICE; // TODO remove

    uint internal LEVER_YIELD;
    // ^ in raw dollar terms,
    // units are 1e18 to match
    // the precision of Basket's
    // internal token (6909)

    // uint public LEVER_MARGIN;
    // ^ TODO measure the rate
    // of change of LEVER_YIELD

    uint internal PENDING_ETH;
    // ^ single-sided liqudity
    // that is waiting for $
    // before it's deposited
    // into the VANILLA pool

    bytes4 immutable SWAP_SELECTOR;
    // ^ just for calling the Router

    mapping(address => Types.Deposit) autoManaged;
    // ^ price range is managed by our contracts

    mapping(address => Types.viaAAVE) pledgesOneForZero;
    mapping(address => Types.viaAAVE) pledgesZeroForOne;
    
    uint internal SWAP_COST; 
    uint internal UNWIND_COST;
    uint constant WAD = 1e18;
    uint lastBlock; 
    // ^ for our ASS

    modifier onlyRouter {
        require(msg.sender == address(V4), "403"); _;
    }

    constructor(address _router, address _v3pool, 
        address _v3router, address _wethVault, 
        address _aave) Ownable(msg.sender) {
        V4 = Router(_router); 
        v3Pool = IUniswapV3Pool(_v3pool);
        v3Router = ISwapRouter(_v3router);
        wethVault = IERC4626(_wethVault);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true; 
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        }   AAVE = IPool(_aave);
        SWAP_COST = 637000; // TODO recalculate
        // ^ gas for 1 swap()
        UNWIND_COST = 3524821; // TODO recalculate
        // ^ gas for unwind()
        SWAP_SELECTOR = bytes4(
            keccak256("swap(uint160,uint256,uint256,uint256,uint256,uint256)")
        );
    }

    function getPrice(uint160 sqrtPriceX96, bool v3)
        public /*view*/ returns (uint price) {
        if (_ETH_PRICE > 0) { // TODO pure
            return _ETH_PRICE; // remove
        }
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);
        
        if (!v3 || (v3 && token1isWETH)) {
            price = FullMath.mulDiv(1 << 128,
                WAD * 1e12, ratioX128);
        } else {
            price = FullMath.mulDiv(ratioX128, 
                WAD * 1e12, 1 << 128);
        }
        _ETH_PRICE = price;
    }

    // must send $1 USDC to address(this) & attach msg.value 1 wei
    function setQuid(address _quid) external payable onlyOwner {    
        require(address(QUID) == address(0), "QUID");
        QUID = Basket(_quid); renounceOwnership();
        
        USDC.approve(address(QUID), 
                type(uint256).max);                    
        USDC.approve(address(v3Router),
                    type(uint256).max);
        WETH.approve(address(wethVault),
                    type(uint256).max);
        WETH.approve(address(v3Router),
                    type(uint256).max);

        // ^ max approvals considered safe
        // to make as we fully control code
        WETH.approve(address(AAVE), 1 wei);
        WETH.deposit{value: 1 wei}();
        AAVE.supply(address(WETH),
             1 wei, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(
                        address(WETH), true);

        USDC.approve(address(AAVE), 1e6);
        AAVE.supply(address(USDC),
           1000000, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(
                        address(USDC), true);
    }

    // In order to prevent sandwich attacks, we implemented 
    // a simple form of ASS: process buys first, then sells
    // It's not possible to go through each swap one by one
    // and execute them in sequence, because it would cause
    // race conditons within the lock mechanism; therefore,
    // we clear the entire batch as 1 swap, looping only to
    // distribute the output pro rata (as a % of the total)

    // amount specifies only how much to sell...
    function swap(address token, bool zeroForOne, 
        uint amount) public payable { 
        require(msg.value >= SWAP_COST, "gas");
        (uint160 sqrtPriceX96,,,) = V4.repack();
        bool isStable = QUID.isStable(token);
        // if this is true ^ user cares
        // about their output being all
        // in 1 specific token, so they
        // won't get multiple tokens...
        Types.Trade memory current;
        current.sender = msg.sender;
        current.token = token;        
        if (!zeroForOne) { 
            require(token == address(QUID) || isStable, "$!");
            amount = _depositETH(amount);
            wethVault.deposit(amount, address(this));
            amount -= SWAP_COST; current.amount = amount;
            V4.pushSwapOneForZero(current);
        }
        else { wethVault.deposit(_depositETH(0), address(this));
            amount = QUID.deposit(msg.sender, token, amount);
            uint scale = IERC20(token).decimals() - 6; // normalize
            amount /= scale > 0 ? 10 ** scale : 1;
            current.amount = amount;
            V4.pushSwapZeroForOne(current);
        }
        _clearSwaps(sqrtPriceX96);
    }

    function clearSwaps() external {
        (uint160 sqrtPriceX96,,,) = V4.repack();
        _clearSwaps(sqrtPriceX96);
    }

    function _clearSwaps(uint160 sqrtPriceX96) internal {
        if (lastBlock == block.number) return;
        (Types.Batch memory forZero, 
         Types.Batch memory forOne) = V4.getSwaps(lastBlock);
        uint price = getPrice(sqrtPriceX96, false);
        uint swapping; uint value; uint remains; 
        uint splitForZero; uint splitForOne;
        uint gotForOne; uint gotForZero;
        if (forZero.total > 0) { 
            swapping = SWAP_COST * forZero.swaps.length;
            // dollar value of total ETH to sell
            value = FullMath.mulDiv(forZero.total, 
                                     price, WAD);

            uint pooled_usd = V4.POOLED_USD() * 1e12;
            if (value > pooled_usd) {
                remains = value - pooled_usd;
                
                splitForZero = FullMath.mulDiv(WAD,
                                    remains, price);
                            
                value = _takeWETH(splitForZero);
                gotForZero = _getUSDC(value, 
                (remains - (remains / 20)) / 1e12);
                    
                // throw it in the basket
                QUID.deposit(address(this),
                address(USDC), gotForZero);     
            }
        }
        if (forOne.total > 0) { 
            swapping = SWAP_COST * forOne.swaps.length;
            // ETH value of total dollars to sell
            value = FullMath.mulDiv(forOne.total, 
                              WAD * 1e12, price);
            
            uint pooled_eth = V4.POOLED_ETH();
            if (value > pooled_eth) {
                value -= pooled_eth;
                remains = FullMath.mulDiv(pooled_eth,
                                   price, WAD * 1e12);

                splitForOne = QUID.take(address(this), 
                forOne.total - remains, address(USDC));
                
                gotForOne = _getWETH(splitForOne, 
                              value - value / 20);
                
                wethVault.deposit(gotForOne, 
                              address(this));
            }
        }  
        if (swapping > 0) {
            bytes memory payload = abi.encodeWithSelector(
             SWAP_SELECTOR, sqrtPriceX96, lastBlock,
             splitForZero, splitForOne, 
             gotForZero, gotForOne);

            uint forGas = _takeWETH(swapping); 
            WETH.withdraw(forGas);
            
            (bool success,) = address(V4).call{ gas: forGas + gasleft()}(payload);
        }
        lastBlock = block.number;
    } 

    function leverOneForZero(uint amount) payable external {
        require(msg.value > UNWIND_COST);
        amount = _depositETH(amount);
        wethVault.deposit(amount, address(this));
        amount -= UNWIND_COST;
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);
        
        uint totalValue = FullMath.mulDiv(amount, price, WAD);
        require(totalValue > 50 * WAD);
        
        uint took = QUID.take(address(this),
            totalValue / 1e12, address(USDC)); // TODO if we don't have USDC
                                                // we need to literally sell ETH

        require(stdMath.delta(totalValue / 1e12, took) <= 5);
        USDC.approve(address(AAVE), took);
        AAVE.supply(address(USDC), took, address(this), 0);
        AAVE.borrow(address(WETH), borrowing, 2, 0, address(this));
        amount = FullMath.mulDiv(borrowing, price, 1e12 * WAD);
        amount = _getUSDC(borrowing, amount - amount / 200);
        require(amount == QUID.deposit(address(this),
                            address(USDC), amount));

        uint withProfit = totalValue + totalValue / 42;
        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesOneForZero[msg.sender] = Types.viaAAVE({
            breakeven: totalValue, // < supplied gets
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: took, borrowed: borrowing,
            buffer: buffer, price: int(price) });
    }

    function leverZeroForOne(uint amount, 
        address token) payable external {
        require(msg.value >= UNWIND_COST);
    
        wethVault.deposit(_depositETH(0), address(this));
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);

        amount = QUID.deposit(msg.sender, token, amount);
        uint scaled = 18 - IERC20(token).decimals();
        scaled = scaled > 0 ? amount * (10 ** scaled) : amount;

        uint withProfit = scaled + scaled / 42;
        uint inETH = FullMath.mulDiv(WAD,
                        scaled, price);

        inETH = _takeWETH(inETH);
        WETH.approve(address(AAVE), inETH);
        AAVE.supply(address(WETH), inETH, address(this), 0);
        amount = FullMath.mulDiv(inETH * 7 / 10, price, WAD * 1e12);
        AAVE.borrow(address(USDC), amount, 2, 0, address(this));
        require(amount == QUID.deposit(address(this),
                 address(USDC), amount)); // TODO make this untouchable

        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesZeroForOne[msg.sender] = Types.viaAAVE({
            breakeven: scaled, // < supplied will get
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: inETH, borrowed: amount,
            buffer: 0, price: int(price) });
    }

    function redeem(uint amount) external {
        require(amount >= WAD, "$1"); 
        amount = QUID.turn(msg.sender, amount);
        (uint total, ) = QUID.get_metrics(false);
        if (amount > 0) {
            uint gains = FullMath.mulDiv(LEVER_YIELD,
                                        amount, total);
            LEVER_YIELD -= gains; amount += gains;
            QUID.take(msg.sender, amount, address(QUID));
        }
    }

    function outOfRange(uint amount, address token,
        int24 distance, uint range) public
        payable returns (uint next) {
        if (token == address(0)) {
            amount = _depositETH(amount);
            wethVault.deposit(amount, address(this));  
        }
        return V4.outOfRange(msg.sender, amount, 
                        token, distance, range);
    }
    
    function withdraw(uint amount) external { 
        Types.Deposit memory LP = autoManaged[msg.sender]; 
        // the following snapshots will always be bigger than LP's
        uint eth_fees = V4.ETH_FEES(); uint usd_fees = V4.USD_FEES();
        // swap fee yield, which uses ^^^^^^^^^^ to buy into unwind
        // instead of V3, which doesn't get more than half, future
        uint pending = PENDING_ETH; uint pooled_eth = V4.POOLED_ETH();
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
        pooled_eth = Math.min(amount, 
                      LP.pooled_eth);

        if (pooled_eth > 0) {
            uint pulled; uint pulling;
            LP.pooled_eth -= pooled_eth;
    
            amount = LP.pooled_eth == 0 ? LP.eth_shares:
                     wethVault.convertToShares(amount);
            
            LP.eth_shares -= amount;
    
            // +1 is needed to because convertToAssets gets rounded down
            pulled = (wethVault.convertToAssets(amount) + 1) - pooled_eth;
            if (pending > 0) { pulling = Math.min(pending, pooled_eth);
                PENDING_ETH = pending - pulling;
                pooled_eth -= pulling;
                pulled += pulling;
            }
            if (pooled_eth > 0) {
                (uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper,) = V4.repack();
                V4.modLP(sqrtPriceX96, pooled_eth, 0, tickLower, tickUpper, msg.sender);
            } 
            _sendETH(pulled, msg.sender); // from PENDING_ETH (not in the pool)
        }
        if (LP.eth_shares == 0) { delete autoManaged[msg.sender]; }
        else { LP.fees_eth = eth_fees; LP.fees_usd = usd_fees; }
    }

    function deposit(uint amount) external payable {
        Types.Deposit memory LP = autoManaged[msg.sender];
        uint pooled_eth = V4.POOLED_ETH();
        uint eth_fees = V4.ETH_FEES(); 
        uint usd_fees = V4.USD_FEES();
        amount = _depositETH(amount);
        if (LP.fees_eth > 0 || LP.fees_usd > 0) {
            LP.usd_owed += FullMath.mulDiv((usd_fees - LP.fees_usd),
                                          LP.pooled_eth, pooled_eth);

            LP.pooled_eth += FullMath.mulDiv((eth_fees - LP.fees_eth),
                                           LP.pooled_eth, pooled_eth);
        }
        LP.fees_eth = eth_fees; LP.fees_usd = usd_fees;
        LP.eth_shares += wethVault.deposit(amount,
                                    address(this));
        LP.pooled_eth += amount;
        _addLiquidity(V4.POOLED_USD(), amount);
        autoManaged[msg.sender] = LP;
    }

    function _addLiquidity(uint delta0, 
        uint delta1) internal { (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = V4.repack();
        uint price = getPrice(sqrtPriceX96, false);
        (delta0, delta1) = _addLiquidityHelper(
                         delta0, delta1, price);
        if (delta0 > 0) { require(delta1 > 0, "+");
            V4.modLP(sqrtPriceX96, delta1, delta0, 
                tickLower, tickUpper, msg.sender);
        }
    }

    function addLiquidityHelper(uint delta0, uint delta1, uint price) public 
        onlyRouter returns (uint, uint) { return _addLiquidityHelper(
                                               delta0, delta1, price); }

    function _addLiquidityHelper(uint delta0, uint delta1, 
        uint price) internal returns (uint, uint) {
        uint pending = PENDING_ETH + delta1;
      
        (uint total, ) = QUID.get_metrics(false);
        uint surplus = (total / 1e12) - delta0;
       
        delta1 = Math.min(pending,
            FullMath.mulDiv(surplus *
                    1e12, WAD, price));
      
        if (delta1 > 0) { pending -= delta1; 
            delta0 = FullMath.mulDiv(delta1,
                        price, WAD * 1e12);
        } PENDING_ETH = pending;
        return (delta0, delta1);
    }

    // TODO remove (for testing purposes only)
    function set_price_eth(bool up) external {
        uint _price = getPrice(0, true);
        uint delta = _price / 20;
        _ETH_PRICE = up ? _price + delta:
                          _price - delta;
    } 

    function _getUSDC(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(WETH), uint24(500), address(USDC)),
            address(this), block.timestamp, howMuch, minExpected));
    }

    function _getWETH(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(USDC), uint24(500), address(WETH)),
            address(this), block.timestamp, howMuch, minExpected));
    }

    function _takeWETH(uint howMuch) internal returns (uint withdrawn) {
        uint amount = Math.min(wethVault.balanceOf(address(this)),
                               wethVault.convertToShares(howMuch));
        withdrawn = wethVault.redeem(amount, address(this), address(this));
    }   fallback() external payable {} // weth.withdraw() triggers this...

    function sendETH(uint howMuch, address toWhom) 
        public onlyRouter { _sendETH(howMuch, toWhom); }

    function _sendETH(uint howMuch, address toWhom) internal {
        // any unused gas from clearSwaps() lands back in 
        // address(this) as residual ETH; re-appropriate:
        uint alreadyInETH = address(this).balance;
        howMuch -= alreadyInETH;
        howMuch = _takeWETH(howMuch); WETH.withdraw(howMuch);
        (bool _success, ) = payable(toWhom).call{ value: howMuch + 
                                                  alreadyInETH }("");
        assert(_success);
    }
    
    function _depositETH(uint amount) internal returns (uint) {
        if (amount > 0) { WETH.transferFrom(msg.sender,
                            address(this), amount);
        } if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            amount += msg.value;
        }
        return amount;  
    } 

    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        IERC20(repay).approve(address(AAVE), borrowed);
        AAVE.repay(repay, borrowed, 2, address(this));
        AAVE.withdraw(out, supplied, address(this));
        // (,uint totalDebtBase,,,,) = AAVE.getUserAccountData(address(this));
    } // TODO as time goes on borrowed will grow a bit beyond what it was initially
    // we currently have no way of seeing how much one borrower owes in interest...
    // only what the entire contract owes. should be fine as long as we periodically
    // clear out this aggregated interest (on behalf of all) so that doesn't pile up

    function unwindOneForZero(address[] calldata whose) 
        external { Types.viaAAVE memory pledge; 
        uint buffer; uint layup; uint touched;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true)); 
        // we always take profits (fully exit) in USDC
        for (uint i = 0; i < whose.length; i++) {
            address who = whose[i]; 
            pledge = pledgesOneForZero[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                touched += 1;
                if (pledge.borrowed > 0) { // supplied is in USDC
                    _unwind(address(WETH), address(USDC), 
                    _takeWETH(pledge.borrowed), pledge.supplied);
                        
                    require(stdMath.delta(
                        USDC.balanceOf(address(this)),
                                      pledge.supplied) <= 5);

                    if (delta <= -49) { // use all of the dollars we possibly can to buy the dip
                        buffer = FullMath.mulDiv(pledge.borrowed, uint(pledge.price), WAD * 1e12);
                        // recovered USDC we got from selling the borrowed ETH
                        layup = QUID.take(address(this), buffer, address(USDC));

                        require(stdMath.delta(layup, buffer) <= 5); 
                        buffer = layup + pledge.supplied;
                        layup = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                        buffer = _getWETH(buffer, layup - layup / 200);
                        pledge.supplied = buffer; wethVault.deposit(buffer,
                                                            address(this));
                        pledge.price = price; // < so we may know when to sell later
                    } else { // the buffer will be saved in USDC, used to pivot later
                        buffer = _takeWETH(pledge.buffer);
                        layup = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        layup = _getUSDC(buffer, 0 /* layup - layup / 200 */) + pledge.supplied;
                        require(layup == QUID.deposit(address(this), address(USDC), layup));
                        pledge.buffer = layup + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                        pledge.supplied = 0;
                    }
                    pledge.borrowed = 0;
                    pledgesOneForZero[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.buffer > 0) { // try to buy the dip
                    buffer = QUID.take(address(this), pledge.buffer, address(USDC));
                    require(stdMath.delta(buffer, pledge.buffer) <= 5);

                    layup = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = _getWETH(buffer, layup - layup / 200);
                    pledge.supplied = buffer; wethVault.deposit(buffer,
                                                         address(this));
                    pledge.price = price; // < so we know when to sell
                    pledgesOneForZero[who] = pledge; // later for profit
                }
                else if (delta >= 49 && pledge.supplied > 0) {
                    buffer = _takeWETH(pledge.supplied); // supplied is ETH
                    layup = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                    layup = _getUSDC(buffer, layup - layup / 200);

                    require(layup == QUID.deposit(address(this), address(USDC), layup));
                    delete pledgesOneForZero[who]; // we completed the cross-over 🏀
                    LEVER_YIELD += (layup - pledge.breakeven / 1e12) * 1e12;
                }
            }
        }
        _sendETH(touched * UNWIND_COST, msg.sender);
    }

    function unwindZeroForOne(address[] calldata whose) 
        external { Types.viaAAVE memory pledge; 
        uint buffer; uint layup; uint touched;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true));
        // we always take profits (fully exit) in USDC
        for (uint i = 0; i < whose.length; i++) {
            address who = whose[i]; 
            pledge = pledgesZeroForOne[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                touched += 1;
                if (pledge.borrowed > 0) {
                    _unwind(address(USDC), address(WETH),
                        QUID.take(address(this), pledge.borrowed,
                                  address(USDC)), pledge.supplied);

                    if (delta >= 49) { // after this, supplied will be stored in USDC...
                        layup = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = _getUSDC(pledge.supplied, layup - layup / 200);

                        require(pledge.supplied == QUID.deposit(address(this), 
                                 address(USDC), pledge.supplied));

                        pledge.price = price;
                    } else { // buffer is in ETH
                        pledge.buffer = pledge.supplied;
                        wethVault.deposit(pledge.supplied,
                                          address(this));

                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledgesZeroForOne[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.supplied > 0) {
                    require(stdMath.delta(pledge.supplied, QUID.take(
                        address(this), pledge.supplied, address(USDC))) <= 5);
                    layup = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer =_getWETH(pledge.supplied, layup - layup / 200);

                    wethVault.deposit(pledge.buffer,
                                      address(this));

                    pledge.supplied = 0;
                    pledge.price = price;
                    pledgesZeroForOne[who] = pledge;
                }
                else if (delta >= 49 && pledge.buffer > 0) {
                    buffer = _takeWETH(pledge.buffer);
                    layup = FullMath.mulDiv(uint(price),
                                    buffer, 1e12 * WAD);

                    layup = _getUSDC(buffer, layup - layup / 200);
                    require(layup == QUID.deposit(address(this),
                                        address(USDC), layup));

                    LEVER_YIELD += (layup - pledge.breakeven / 1e12) * 1e12;
                    delete pledgesZeroForOne[who];
                }
            }
        }
        _sendETH(touched * UNWIND_COST, msg.sender);
    }
}
