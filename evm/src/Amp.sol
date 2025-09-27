// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rover} from "./Rover.sol";
import {Types} from "./imports/Types.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {stdMath} from "forge-std/StdMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IUiPoolDataProviderV3} from "aave-v3/helpers/interfaces/IUiPoolDataProviderV3.sol";
import {IPoolAddressesProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
// import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import "lib/forge-std/src/console.sol"; 

/// @notice Handles AAVE APR/APY
/// @dev Integrates V3 for swaps
contract Amp is Ownable { 
    IPoolAddressesProvider ADDR;
    IUiPoolDataProviderV3 DATA;
    uint USDCsharesSnapshot;
    uint wethSharesSnapshot;
    IERC20 USDC; WETH9 weth;
    bool token1isWETH;
    IUniswapV3Pool v3Pool;
    ISwapRouter v3Router; 
    Rover V3; IPool AAVE;

    // uint internal UNWIND_COST;
    uint constant WAD = 1e18;
    uint constant RAY = 1e27;

    mapping(address => Types.viaAAVE) pledgesOneForZero;
    mapping(address => Types.viaAAVE) pledgesZeroForOne;
    mapping(address => uint) totalBorrowed;

    modifier onlyUs {
        require(msg.sender == address(this) 
             || msg.sender == address(V3), "403"); _;
    }

    constructor(address _aave, address _data, 
        address _addr) Ownable(msg.sender) {
        DATA = IUiPoolDataProviderV3(_data);
        ADDR = IPoolAddressesProvider(_addr);
        AAVE = IPool(_aave); // UNWIND_COST = 3524821; 
    }                       // ^ recalculate TODO

    event LeveragedPositionOpened(
        address indexed user,
        bool indexed isLong,
        uint256 supplied,
        uint256 borrowed,
        uint256 buffer,
        int256 entryPrice,
        uint256 breakeven,
        uint256 blockNumber
    );

    event PositionUnwound(
        address indexed user,
        bool indexed isLong,
        int256 exitPrice,
        int256 priceDelta,
        uint256 blockNumber
    );

    function setup(address payable _rover, address) external onlyOwner { 
        require(address(Rover(_rover).AMP()) == address(this));
    
        renounceOwnership();
        V3 = Rover(_rover); 
        USDC = IERC20(V3.USDC());
        weth = WETH9(payable(
          address(V3.weth())));
        
        v3Pool = IUniswapV3Pool(V3.POOL());
        v3Router = ISwapRouter(V3.ROUTER());
        
        token1isWETH = v3Pool.token0() == address(USDC);
        
        USDC.approve(address(V3),
                    type(uint).max);

        USDC.approve(address(AAVE),
                    type(uint).max);

        USDC.approve(address(v3Router),
                    type(uint).max);
      
        weth.approve(address(v3Router),
                    type(uint).max);

        // ^ max approvals considered safe
        // to make as we fully control code
        weth.approve(address(AAVE),
                 type(uint).max);  
    }

    /// @notice Open leveraged long position (borrow weth against USDC)
    /// @dev 70% LTV, excess USDC locked as collateral
    /// @param amount weth amount to deposit
    function leverETH(address who, uint amount, 
        uint fromV4) payable external {
        uint160 sqrtPriceX96 = V3.repackNFT(0);
        uint price = V3.getPrice(sqrtPriceX96);
        if (fromV4 > 0) { // msg.sender is Aux...
            weth.transferFrom(msg.sender,
                    address(this), amount);
            
            USDC.transferFrom(msg.sender,
                    address(this), fromV4);
        }
        else { amount = _deposit(amount); }
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        // borrow full value of collateral to go long
        // selling the amount borrowed for USDC and 
        // depositing the USDC for a future step in
        // unwind which is a basketball crossover
        uint took = totalValue / 1e12 - fromV4;
        if (took > 0) // borrow dollars from UniV3...
            require(took - V3.withdrawUSDC(took) == 0);
        
        putUSDC(totalValue / 1e12); put(amount);
        totalBorrowed[address(weth)] += borrowing;
        // ^ there will always be enough to pay this
        // back because we are depositting ETH first
        AAVE.borrow(address(weth), borrowing,
              2, 0, address(this));
        
        amount = FullMath.mulDiv(borrowing, price, 1e12 * WAD);
        amount = _buyUSDC(borrowing, amount - amount / 200);
        // ^ selling borrowed WETH for adding leverage power
        
        putUSDC(amount);
        Types.viaAAVE memory order = Types.viaAAVE({
            breakeven: totalValue, // < "supplied" gets
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: took, borrowed: borrowing,
            buffer: buffer, price: int(price) });
        
        if (token1isWETH) { // check for pre-existing order
            require(pledgesOneForZero[who].breakeven == 0);
            pledgesOneForZero[who] = order;
        } 
        else { 
            require(pledgesZeroForOne[who].breakeven == 0);
            pledgesZeroForOne[who] = order; 
        }
        
        emit LeveragedPositionOpened(
            msg.sender, true, took, 
            borrowing, buffer, int(price), 
            totalValue,block.number);
    }

    /// @notice Open leveraged short position (USDC against weth)
    /// @dev 70% LTV on AAVE, deposited stablecoins as collateral
    /// @param amount Stablecoin amount to deposit
    function leverUSD(address who, uint amount, 
        uint fromV4) payable external {
        uint160 sqrtPriceX96 = V3.repackNFT(0);
        uint price = V3.getPrice(sqrtPriceX96);
        if (fromV4 > 0) 
            weth.transferFrom(msg.sender,
                    address(this), fromV4);
            
        USDC.transferFrom(msg.sender, 
            address(this), amount);

        uint deposited = amount; 
        putUSDC(amount);
        
        uint inWETH = FullMath.mulDiv(WAD,
                        amount, price);
        amount = inWETH;
        inWETH -= fromV4;
        if (inWETH > 0) 
            require(inWETH - V3.take(inWETH) == 0); 
        // borrow WETH from V3, use in AAVE
        // as collateral to borrow dollars
            
        put(amount); // deposit WETH as collat...
        amount = FullMath.mulDiv(inWETH * 7 / 10, 
                            price, WAD * 1e12);
        
        // borrow 70% of the WETH value in USDC
        AAVE.borrow(address(USDC), amount, 2, 0, 
           address(this)); putUSDC(amount);
        
        totalBorrowed[address(USDC)] += amount; 
        Types.viaAAVE memory order = Types.viaAAVE({
            breakeven: deposited, // < "supplied" gets
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: inWETH, borrowed: amount,
            buffer: 0, price: int(price) });

        if (token1isWETH) { // check for pre-existing order
            require(pledgesZeroForOne[who].breakeven == 0);
            pledgesZeroForOne[who] = order;
        }
        else { 
            require(pledgesOneForZero[who].breakeven == 0);
            pledgesOneForZero[who] = order; 
        }
        emit LeveragedPositionOpened(
            msg.sender, false, inWETH,
            amount, 0, int(price),
            deposited, block.number);
    }

    function putUSDC(uint amount) 
        public onlyUs { 
        AAVE.supply(address(USDC), 
        amount, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(
                       address(USDC), true);
    }
    function _getUSDC(uint howMuch) 
        internal returns (uint withdrawn) {
        uint amount = Math.min(USDCsharesSnapshot, howMuch);
        withdrawn = AAVE.withdraw(address(USDC),
                          amount, address(this));
    }

    function put(uint amount) public onlyUs {
        AAVE.supply(address(weth), amount, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(address(weth), true);
    } fallback() external payable {} 
    
    function get(uint howMuch) onlyUs 
        public returns (uint withdrawn) {
        uint amount = Math.min(wethSharesSnapshot, howMuch);
        withdrawn = AAVE.withdraw(address(weth),
                        amount, address(this));
        if (msg.sender != address(this))
            weth.transfer(msg.sender, withdrawn);
    }

    function _buyUSDC(uint howMuch,
        uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(weth), uint24(500), address(USDC)),
            address(this), /* block.timestamp, */ howMuch, minExpected));
    }

    function _buy(uint howMuch, 
        uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(USDC), uint24(500), address(weth)),
            address(this), /* block.timestamp, */ howMuch, minExpected));
    }
    
    function send(uint howMuch, address toWhom) 
        public onlyUs { _send(howMuch, toWhom); }
                   
    function _send(uint howMuch, address toWhom) internal {
        // any unused gas from clearSwaps() lands back in 
        // address(this) as residual ETH; re-appropriate:
        uint already = address(this).balance;
        howMuch -= already; howMuch = get(howMuch);
        (bool _success, ) = payable(toWhom).call{ value: howMuch + 
                                                  already }("");
                                                  assert(_success);
    }

    function _deposit(uint amount) internal returns (uint) {
        if (amount > 0) { weth.transferFrom(msg.sender,
                            address(this), amount);
        } if (msg.value > 0) {
            weth.deposit{value: msg.value}();
            amount += msg.value;
        }   return amount;  
    } 

    /// @notice Internal AAVE loan repayment
    /// @param repay Token to repay
    /// @param out Token to withdraw
    /// @param borrowed Amount borrowed
    /// @param supplied Amount supplied
    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        AAVE.repay(repay, borrowed, 2, address(this));
        if (supplied > 0 && out != address(0)) {
            totalBorrowed[repay] -= borrowed;
            require(supplied == AAVE.withdraw(out, 
                      supplied, address(this)));    
        }
    } 
    
    /// @notice Calculate APR on AAVE positions
    /// @return repay Interest owed weth borrows
    /// @return repayUSDC owed on USDC borrows
    function _howMuchInterest() internal 
        returns (uint repay, uint repayUSDC) {
        ( IUiPoolDataProviderV3.UserReserveData[] memory userData,
        ) = DATA.getUserReservesData(ADDR, address(this));

        ( IUiPoolDataProviderV3.AggregatedReserveData[] memory reserveData,
        ) = DATA.getReservesData(ADDR);

        { uint scaledDebt = userData[2].scaledVariableDebt;
          uint borrowIndex = reserveData[2].variableBorrowIndex;
          uint actualDebt = (scaledDebt * borrowIndex) / RAY;
          wethSharesSnapshot = IERC20( // index 0 on L1, and L2
            reserveData[2].aTokenAddress).balanceOf(address(this));
          repay = actualDebt - totalBorrowed[address(weth)]; }
        // extra APY from flipping debt in unwind against...
        // initial collateral which is only repaid once but
        // remains staked, not costing more APY, earning APY
        { uint scaledDebt = userData[1].scaledVariableDebt;
          uint borrowIndex = reserveData[1].variableBorrowIndex;
          uint actualDebt = (scaledDebt * borrowIndex) / RAY;
          USDCsharesSnapshot = IERC20( // index 3 on L1, 4 on Base
            reserveData[1].aTokenAddress).balanceOf(address(this));
          repayUSDC = actualDebt - totalBorrowed[address(USDC)]; }
    }
    
    function unwindZeroForOne(address[] calldata whose) 
        external { uint160 sqrtPriceX96 = V3.repackNFT(0);
        int price = int(V3.getPrice(sqrtPriceX96)); 
        // ^ 1 value yields outcome for all whose
        Types.viaAAVE memory pledge; uint i;
        uint buffer; uint pivot; uint touched;
        // ^ individual values for each whose
        (uint repay, // < in wrapped ETH... 
        uint repayUSDC) = _howMuchInterest();
        // take profits (fully exit) in USDC
        while (i < 30 && i < whose.length) {
            address who = whose[i]; 
            pledge = pledgesZeroForOne[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;

            if (delta <= -49 || delta >= 49) { 
                // touched += 1; // supplied is in USDC
                if (pledge.borrowed > 0) { pivot = get(pledge.borrowed);
                    require(stdMath.delta(pledge.borrowed, pivot) <= 5);
                    _unwind(address(weth), address(USDC), pivot, pledge.supplied);
                    
                    if (delta <= -49) { // use all of the dollars we possibly can to buy the dip
                        buffer = FullMath.mulDiv(pledge.borrowed, uint(pledge.price), WAD * 1e12);
                        // recover USDC that we got from selling the borrowed weth...
                        pivot = _getUSDC(buffer); 
                        require(stdMath.delta(pivot, buffer) <= 5); 
                        
                        buffer = pivot + pledge.supplied;
                        pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                        buffer = _buy(buffer, pivot - pivot / 200); put(buffer);

                        pledge.supplied = buffer; 
                        pledge.price = price; // < so we may know when to sell later
                    } else { // the buffer will be saved in USDC, used to pivot later
                        buffer = get(pledge.buffer); // 
                        require(stdMath.delta(buffer, pledge.buffer) <= 5);
                        pivot = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        pivot = _buyUSDC(buffer, pivot - pivot / 200) + pledge.supplied;
                        pledge.buffer = pivot + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                        pledge.supplied = 0;
                        putUSDC(pivot); 
                    }
                    pledge.borrowed = 0;
                    pledgesZeroForOne[who] = pledge;
                }
                // following condition is our initial pivot...
                else if (delta <= -49 && pledge.buffer > 0) { 
                    buffer = _getUSDC(pledge.buffer); // buy dip
                    require(stdMath.delta(buffer, pledge.buffer) <= 5);
                    pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = _buy(buffer, pivot - pivot / 200);
                    pledge.supplied = buffer; put(buffer);
                    pledge.price = price; // < so we know when to sell...
                    pledgesZeroForOne[who] = pledge; // later for profit
                }
                else if (delta >= 49 && pledge.supplied > 0) {
                    buffer = get(pledge.supplied); // supplied is weth
                    if (repay > 0) {
                        pivot = Math.min(buffer, repay);
                        buffer -= pivot; 
                        _unwind(address(weth), address(0), pivot, 0);
                        // ^ address "out" and "supplied" irrelevant
                    }
                    pivot = FullMath.mulDiv(uint(price), buffer, 1e12 * WAD);
                    pivot = _buyUSDC(buffer, pivot - pivot / 200);
                    uint breakeven = pledge.breakeven / 1e12;
                    if (repayUSDC > 0) {
                        buffer = Math.min(pivot - breakeven, repayUSDC);
                        pivot -= buffer;
                        _unwind(address(USDC), address(0), buffer, 0);
                        // ^ address "out" and "supplied" irrelevant
                    } 
                    pivot = (pivot - breakeven) / 2;
                    USDC.transfer(who, breakeven + pivot);
                    V3.depositUSDC(pivot, uint(price));   
                    delete pledgesZeroForOne[who]; 
                    // completed the cross-over... 
                } emit PositionUnwound(who, true,
                price, delta, block.number); i++;
            }
        }
        // _sendETH(touched * UNWIND_COST, msg.sender); 
    } // ^ gas compensation for service worker (caller)

    function unwindOneForZero(address[] calldata whose) 
        external { uint160 sqrtPriceX96 = V3.repackNFT(0);
        int price = int(V3.getPrice(sqrtPriceX96)); 
        // ^ 1 value yields outcome for all whose
        Types.viaAAVE memory pledge; uint i;
        uint buffer; uint pivot; uint touched;
        // ^ individual values for each whose
        (uint repay, // < in wrapped ETH... 
        uint repayUSDC) = _howMuchInterest();
        // take profits (fully exit) in USDC
        while (i < 30 && i < whose.length) {
            address who = whose[i]; 
            pledge = pledgesOneForZero[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            
            if (delta <= -49 || delta >= 49) {
                // touched += 1;
                if (pledge.borrowed > 0) {
                    pivot = _getUSDC(pledge.borrowed);
                    _unwind(address(USDC), address(weth),
                                 pivot, pledge.supplied); 

                    if (delta >= 49) { // after sell suppled weth, "supplied" will store $
                        pivot = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = _buyUSDC(pledge.supplied, pivot - pivot / 200);
                        putUSDC(pledge.supplied); pledge.price = price;
                    } else { // buffer is is now in weth
                        pledge.buffer = pledge.supplied;
                        put(pledge.supplied);
                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledgesOneForZero[who] = pledge;
                } // the following condition is our initial pivot
                else if (delta <= -49 && pledge.supplied > 0) {
                    pivot = _getUSDC(pledge.supplied);
                    require(stdMath.delta(pledge.supplied, pivot) <= 5); 
                    pivot = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer =_buy(pledge.supplied, pivot - pivot / 200);
                    
                    put(pledge.buffer);
                    pledge.supplied = 0;
                    pledge.price = price;
                    pledgesOneForZero[who] = pledge;
                }
                else if (delta >= 49 && pledge.buffer > 0) {
                    buffer = get(pledge.buffer);
                    if (repay > 0) {
                        pivot = Math.min(buffer, repay);
                        buffer -= pivot; 
                        _unwind(address(weth), address(0), pivot, 0);
                        // ^ address "out" and "supplied" irrelevant
                    } 
                    pivot = FullMath.mulDiv(uint(price), buffer, 1e12 * WAD);
                    pivot = _buyUSDC(buffer, pivot - pivot / 200);
                    uint breakeven = pledge.breakeven / 1e12;
                    if (repayUSDC > 0) {
                        buffer = Math.min(pivot - breakeven, repayUSDC);
                        pivot -= buffer;
                        _unwind(address(USDC), address(0), buffer, 0);   
                    } pivot = (pivot - breakeven) / 2; // half profit
                    USDC.transfer(who, breakeven + pivot);
                    V3.depositUSDC(pivot, uint(price));
                    delete pledgesOneForZero[who];
                    // completed the cross-over...
                } emit PositionUnwound(who, false,
                price, delta, block.number); i++;
            }
        }
        // _sendETH(touched * UNWIND_COST, msg.sender);
    } // ^ gas compensation for service worker (caller)
}
