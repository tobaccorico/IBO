

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./imports/Types.sol";
import {Basket} from "./Basket.sol";
import {Router} from "./Router.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {stdMath} from "forge-std/StdMath.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IUiPoolDataProviderV3} from "aave-v3/helpers/interfaces/IUiPoolDataProviderV3.sol";
import {IPoolAddressesProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract Auxiliary is Ownable { 
    bool public token1isWETH;
    IERC20 USDC; WETH9 public WETH;
    IUniswapV3Pool v3Pool;
    Router V4; IPool AAVE;
    IUiPoolDataProviderV3 DATA;
    IPoolAddressesProvider ADDR;
    ISwapRouter v3Router; 
    IERC4626 public wethVault;
    Basket QUID; // $QD

    uint internal _ETH_PRICE; // TODO remove

    uint internal LEVER_YIELD;
    // ^ in raw dollar terms,
    // units are 1e18 to match
    // the precision of Basket's
    // internal token (ERC6909)

    // uint public LEVER_MARGIN;
    // ^ TODO measure the rate
    // of change of LEVER_YIELD

    bytes4 immutable SWAP_SELECTOR;
    // ^ just for calling the Router

    mapping(address => Types.viaAAVE) pledgesOneForZero;
    mapping(address => Types.viaAAVE) pledgesZeroForOne;
    mapping(address => uint) totalBorrowed;
    
    uint internal SWAP_COST; 
    uint internal UNWIND_COST;
    uint constant WAD = 1e18;
    uint public untouchable; 
    // ^ USDC saved for AAVE
    uint lastBlock; 
    // ^ for ASS...

    modifier onlyRouter {
        require(msg.sender == address(V4), "403"); _;
    }

    constructor(address _router, address _v3pool, 
        address _v3router, address _wethVault, 
        // these next 3 are all AAVE-specific
        address _aave, address _data, 
        address _addr) Ownable(msg.sender) {
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
        }   V4 = Router(_router);    
            AAVE = IPool(_aave);
            
        DATA = IUiPoolDataProviderV3(_data);
        ADDR = IPoolAddressesProvider(_addr);
        SWAP_COST = 637000 * 2; // TODO recalculate
        // ^ gas for 1 loop iteration in V4.swap()
        UNWIND_COST = 3524821; // TODO recalculate
        // ^ gas for unwind()
        SWAP_SELECTOR = bytes4(
            keccak256("batchSwap(uint160,uint256,uint256,uint256,uint256,uint256)")
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
    // a simple form of ASS: process buys first, then sells!
    // Minimum trade size is a form of DoS/spam protection.
    // It's not possible to go through each swap one by one
    // and execute them in sequence, because it would cause
    // race conditons within the lock mechanism; therefore,
    // we clear the entire batch as 1 swap, looping only to
    // distribute the output pro rata (as a % of the total).

    // `amount` specifies only how much to sell,
    // `token` specifies what you want to buy,
    // returns which block trade will clear in
    function swap(address token, bool zeroForOne, uint amount, 
        uint waitable) public payable returns (uint blockNumber) { 
        (uint160 sqrtPriceX96,,,) = V4.repack();
        uint price = getPrice(sqrtPriceX96, false);
        bool isStable = QUID.isStable(token);
        // ^ if this is true user cares
        // about their output being all
        // in 1 specific token, so they
        // won't get multiple tokens...
        bool sensitive; 
        if (!zeroForOne) { // < trying to sell ETH for dollars 
            require(token == address(QUID) || isStable, "$!");
            amount = _depositETH(amount);
            wethVault.deposit(amount, address(this));
            sensitive = FullMath.mulDiv(amount, 
                             price, WAD) >= 5000 * WAD;
            if (sensitive) 
                amount -= SWAP_COST;
        } else {
            amount = QUID.deposit(msg.sender, token, amount);
            uint scale = IERC20(token).decimals() - 6; // normalize
            amount /= scale > 0 ? 10 ** scale : 1;
            sensitive = amount >= 5000000; // $5,000
            if (sensitive) { // < park the ETH for gas comp...
                wethVault.deposit(_depositETH(0), address(this)); 
            }
        } if (sensitive) { // must subsidise gas cost
            require(msg.value >= SWAP_COST, "gas");
            // entering into protected clearing
            // pipeline: no sandwiches, slower
            Types.Trade memory current;
            current.sender = msg.sender;
            current.token = token;        
            current.amount = amount;
            blockNumber = V4.pushSwap(zeroForOne, 
                            current, waitable);
        } else { blockNumber = block.number;
            // Executes instantly, no batching, 
            // no sandwich protection...cheaper, 
            // reliably scalable...suitable for: 
            // small trades, routine flow, etc.
            V4.swap(sqrtPriceX96, msg.sender, 
                zeroForOne, token, amount);
        }
        _clearSwaps(sqrtPriceX96, price);
        return blockNumber;
    }

    function clearSwaps() external {
        (uint160 sqrtPriceX96,,,) = V4.repack();
        uint price = getPrice(sqrtPriceX96, false);
        _clearSwaps(sqrtPriceX96, price);
    }

    function _clearSwaps(uint160 sqrtPriceX96, uint price) internal { 
        if (lastBlock == block.number) return;
        (Types.Batch memory forZero, 
         Types.Batch memory forOne) = V4.getSwaps(lastBlock);
        
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
                forOne.total - remains, address(USDC), true);
                
                gotForOne = _getWETH(splitForOne, 
                              value - value / 20);
                
                wethVault.deposit(gotForOne, 
                              address(this));
            }
        } if (swapping > 0) {
            bytes memory payload = abi.encodeWithSelector(
                SWAP_SELECTOR, sqrtPriceX96, lastBlock,
                splitForZero, splitForOne, 
                gotForZero, gotForOne);

            uint forGas = _takeWETH(swapping); WETH.withdraw(forGas);
            // because the way we do this low-level call, our swap entrypoint
            // has to be AUX (not the router, which would otherwise make sense)
            (bool success,) = address(V4).call{ gas: forGas + gasleft()}(payload);
        }
        lastBlock = block.number;
    } 

    function leverOneForZero(uint amount) payable external {
        require(msg.value >= UNWIND_COST);
        amount = _depositETH(amount);
        amount -= UNWIND_COST;
        
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        require(totalValue > 500 * WAD, "$500");
        uint took = QUID.take(address(this),
            totalValue / 1e12, address(USDC), false); 
      
        if (totalValue / 1e12 > took + 1) {
            uint needed = totalValue / 1e12 - took;
            uint selling = FullMath.mulDiv(needed, 
                                WAD * 1e12, price);
            require(V4.unpend(selling) == selling);
            took += _getUSDC(_takeWETH(selling), 
                        needed - needed / 200);
            amount -= selling;
        } 
        USDC.approve(address(AAVE), took);
        wethVault.deposit(amount + UNWIND_COST, address(this));
        AAVE.supply(address(USDC), took, address(this), 0);
        AAVE.borrow(address(WETH), borrowing, 2, 0, address(this));
        totalBorrowed[address(WETH)] += borrowing;
        
        amount = FullMath.mulDiv(borrowing, price, 1e12 * WAD);
        amount = _getUSDC(borrowing, amount - amount / 200);
        QUID.deposit(address(this), address(USDC), amount);
        untouchable += amount; // can't sell this USDC in 
        // swaps because it's needed for unwind strategy

        uint withProfit = totalValue + totalValue / 42;
        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesOneForZero[msg.sender] = Types.viaAAVE({
            breakeven: totalValue, // < "supplied" gets
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
        require(scaled >= 500 * WAD, "$500");
        uint withProfit = scaled + scaled / 42;
        uint inETH = FullMath.mulDiv(WAD,
                        scaled, price);

        inETH = _takeWETH(inETH);
        WETH.approve(address(AAVE), inETH);
        AAVE.supply(address(WETH), inETH, address(this), 0);
        amount = FullMath.mulDiv(inETH * 7 / 10, price, WAD * 1e12);
        AAVE.borrow(address(USDC), amount, 2, 0, address(this));
        untouchable += amount; totalBorrowed[address(USDC)] += amount;
        QUID.deposit(address(this), address(USDC), amount); 

        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesZeroForOne[msg.sender] = Types.viaAAVE({
            breakeven: scaled, // < "supplied" will get
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
            QUID.take(msg.sender, amount, address(QUID), false);
        } // TODO extremely unlikely edge case, distribute ETH if
    } // there is not suffcient dollars in the basket to cover...
    
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

    function putETH(uint howMuch) public onlyRouter returns (uint) {
        WETH.transferFrom(address(V4), address(this), howMuch);
        return wethVault.deposit(howMuch, address(this));
    }

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
        }   return amount;  
    } 

    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        IERC20(repay).approve(address(AAVE), borrowed);
        AAVE.repay(repay, borrowed, 2, address(this));
        if (supplied > 0) {
            totalBorrowed[repay] -= borrowed;
            AAVE.withdraw(out, supplied, address(this));    
        }
    } 
    
    function _howMuchInterest() internal returns 
        (uint repayWETH, uint repayUSDC) {
        (IUiPoolDataProviderV3.UserReserveData[] memory data, ) = DATA.getUserReservesData(
                                                                        ADDR, address(this));
        
        repayWETH = data[0].scaledVariableDebt - totalBorrowed[address(WETH)];
        repayUSDC = data[3].scaledVariableDebt - totalBorrowed[address(USDC)];
    }

    // untouchable helps track how much USDC must not 
    // leave the contract, to make sure ^^^^ debt is
    // always repaid in full (form of outflow capping)
    function unwind(address[] calldata whose, 
        bool[] calldata oneForZero) external { 
        require(oneForZero.length == whose.length, "len");
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true)); 
        Types.viaAAVE memory pledge; // < iterator
        uint buffer; uint pivot; uint touched;
        for (uint i = 0; i < whose.length; i++) {
            address who = whose[i]; 
            pledge = pledgesOneForZero[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) { 
                touched += 1;
                buffer = oneForZero[i] ? pledge.buffer : pledge.supplied;

                if (pledge.borrowed > 0) {
                    if (oneForZero[i]) {
                        pivot = _takeWETH(pledge.borrowed);
                        require(stdMath.delta(pledge.borrowed, pivot) <= 5);
                        _unwind(address(WETH), address(USDC), pivot, pledge.supplied);
                        require(stdMath.delta(USDC.balanceOf(address(this)),
                                                    pledge.supplied) <= 5);
                        if (delta <= -49) { // use all of the dollars we possibly can to buy the dip
                            buffer = FullMath.mulDiv(pledge.borrowed, uint(pledge.price), WAD * 1e12);
                            // recover USDC that we got from selling the borrowed ETH...
                            pivot = QUID.take(address(this), buffer, address(USDC), true);
                            untouchable -= pivot; require(stdMath.delta(pivot, buffer) <= 5); 
                            
                            buffer = pivot + pledge.supplied;
                            pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                            buffer = _getWETH(buffer, pivot - pivot / 200);
                            pledge.supplied = buffer; wethVault.deposit(buffer,
                                                                address(this));
                            pledge.price = price; // < so we may know when to sell later
                        } else { // the buffer will be saved in USDC, used to pivot later
                            buffer = _takeWETH(pledge.buffer); 
                            require(stdMath.delta(buffer, pledge.buffer) <= 5);
                            pivot = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                            // TODO uncomment, commented out for testing purposes only
                            pivot = _getUSDC(buffer, 0/*pivot - pivot / 200*/) + pledge.supplied;
                            QUID.deposit(address(this), address(USDC), pivot); untouchable += pivot;
                            pledge.buffer = pivot + FullMath.mulDiv(pledge.borrowed,
                                                    uint(pledge.price), WAD * 1e12);
                            pledge.supplied = 0;
                        }
                        pledgesOneForZero[who] = pledge;
                    } else {
                        pivot = QUID.take(address(this), 
                        pledge.borrowed, address(USDC), true);
                        _unwind(address(USDC), address(WETH), pivot, 
                            pledge.supplied); untouchable -= pivot;
                        require(stdMath.delta(WETH.balanceOf(address(this)),
                                                pledge.supplied) <= 5);
                    
                        if (delta >= 49) { // after sell suppled WETH, "supplied" will store $
                            pivot = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                            pledge.supplied = _getUSDC(pledge.supplied, pivot - pivot / 200);
                            QUID.deposit(address(this), address(USDC), pledge.supplied);
                            untouchable += pledge.supplied; pledge.price = price;
                        } else { // buffer is is now in ETH
                            pledge.buffer = pledge.supplied;
                            wethVault.deposit(pledge.buffer,
                                            address(this));

                            pledge.supplied = 0;
                            pledgesZeroForOne[who] = pledge;
                        }
                    }
                    pledge.borrowed = 0;   
                } // our initial pivot...
                else if (delta <= -49) { 
                    if (buffer > 0) {
                        buffer = QUID.take(address(this), 
                            buffer, address(USDC), true); 
                                   untouchable -= buffer;

                        pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                        buffer = _getWETH(buffer, pivot - pivot / 200);
                        wethVault.deposit(buffer, address(this));
                        
                        if (oneForZero[i]) {
                            pledge.supplied = buffer;
                            pledgesOneForZero[who] = pledge;
                        } else {
                            pledge.supplied = 0;
                            pledge.buffer = buffer;
                            pledgesZeroForOne[who] = pledge;
                        }
                        pledge.price = price; 
                    }
                } else if (delta >= 49) { 
                // ETH (supplied or buffer)
                    if (buffer > 0) {
                        buffer = _takeWETH(buffer); 
                        (uint repayWETH, 
                        uint repayUSDC) = _howMuchInterest();
                        if (repayWETH > 0) {
                            pivot = Math.min(buffer, repayWETH);
                            buffer -= pivot; 
                            _unwind(address(WETH), address(0), pivot, 0);
                            // ^ address "out" and "supplied" irrelevant
                        }
                        pivot = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        // pivot = FullMath.mulDiv(uint(price), buffer, 1e12 * WAD); // TODO ?
                        pivot = _getUSDC(buffer, pivot - pivot / 200);
                        if (repayUSDC > 0) {
                            buffer = Math.min(pivot, repayUSDC);
                            pivot -= buffer;
                            _unwind(address(USDC), address(0), buffer, 0);
                            // ^ address "out" and "supplied" irrelevant
                        }
                        QUID.deposit(address(this), address(USDC), pivot);
                        oneForZero[i] ? delete pledgesOneForZero[who] : 
                                        delete pledgesZeroForOne[who];
                        LEVER_YIELD += (pivot - pledge.breakeven / 1e12) * 1e12;
                    }
                }
            }
        } _sendETH(touched * UNWIND_COST, msg.sender); // caller's gas compensation
    } // could repay, for instance, a contract's flash loan used to pay for gas... 
}
