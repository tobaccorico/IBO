
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rover} from "./Rover.sol";
import {Types} from "./imports/Types.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BasketLib} from "./imports/BasketLib.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IUiPoolDataProviderV3} from "aave-v3/helpers/interfaces/IUiPoolDataProviderV3.sol";
import {IPoolAddressesProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IAux {
    function getTWAP(uint32 secondsAgo) external view returns (uint);
}

/// @notice Handles AAVE APR/APY
/// @dev Integrates V3 for swaps
contract Amp is Ownable {
    IPoolAddressesProvider ADDR;
    IUiPoolDataProviderV3 DATA;
    uint constant WAD = 1e18;
    uint constant RAY = 1e27;
    uint USDCsharesSnapshot;
    uint wethSharesSnapshot;

    IERC20 USDC; WETH9 weth;
    IUniswapV3Pool v3Pool;
    ISwapRouter v3Router;
    Rover V3; IPool AAVE;
    address public AUX;
    bool token1isWETH;

    mapping(address => Types.viaAAVE) pledgesOneForZero;
    mapping(address => Types.viaAAVE) pledgesZeroForOne;
    mapping(address => uint) totalBorrowed;

    modifier onlyUs {
        require(msg.sender == address(this)
             || msg.sender == address(V3)
             || msg.sender == AUX, "403"); _;
    }

    constructor(address _aave, address _data,
        address _addr) Ownable(msg.sender) {
        DATA = IUiPoolDataProviderV3(_data);
        ADDR = IPoolAddressesProvider(_addr);
        AAVE = IPool(_aave);
    }

    event LeveragedPositionOpened(
        address indexed user,
        bool indexed isLong,
        uint supplied,
        uint borrowed,
        uint buffer,
        int256 entryPrice,
        uint breakeven,
        uint blockNumber
    );

    event PositionUnwound(
        address indexed user,
        bool indexed isLong,
        int256 exitPrice,
        int256 priceDelta,
        uint blockNumber
    );

    function setup(address payable _rover,
        address _aux) external onlyOwner {
        require(address(Rover(_rover).AMP())
             == address(this)); AUX = _aux;

        renounceOwnership();
        V3 = Rover(_rover);

        USDC = IERC20(V3.USDC());
        weth = WETH9(payable(
          address(V3.weth())));

        v3Pool = IUniswapV3Pool(V3.POOL());
        v3Router = ISwapRouter(V3.ROUTER());

        token1isWETH = v3Pool.token0() == address(USDC);
        USDC.approve(address(V3), type(uint).max);
        USDC.approve(address(AAVE), type(uint).max);
        USDC.approve(address(v3Router), type(uint).max);
        weth.approve(address(v3Router), type(uint).max);
        weth.approve(address(AAVE), type(uint).max);
    }

    /// @notice leveraged long (borrow weth against USDC)
    /// @dev 70% LTV, excess USDC locked as collateral
    /// @param amount weth amount to deposit
    function leverETH(address who, uint amount,
        uint fromV4) payable external onlyUs {
        uint price =  IAux(AUX).getTWAP(0);
        if (fromV4 > 0) {
            weth.transferFrom(msg.sender,
                address(this), amount);
            USDC.transferFrom(msg.sender,
                address(this), fromV4);
        }
        else amount = _deposit(amount);
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        // borrow full value of collateral to go long
        // selling the amount borrowed for USDC and
        // depositing the USDC for a future step in
        // unwind which is a basketball crossover
        uint usdcNeeded = totalValue / 1e12;
        uint took = 0;
        if (fromV4 < usdcNeeded) {
            took = usdcNeeded - fromV4;
            if (took > 0) {
                uint got = V3.withdrawUSDC(took);
                require(stdMath.delta(took, got) <= 1e6,
                                        "withdrawUSDC");
                took = got;
            }
        } _putUSDC(fromV4 + took); _put(amount);
        totalBorrowed[address(weth)] += borrowing;
        // ^ there will always be enough to pay this
        // back because we are depositting ETH first
        AAVE.borrow(address(weth), borrowing,
              2, 0, address(this));

        amount = FullMath.mulDiv(borrowing,
                        price, 1e12 * WAD);
        amount = _buyUSDC(borrowing, price);
        // ^ sell borrowed WETH to ad lever

        _putUSDC(amount);
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
        uint fromV4) payable external onlyUs {
        uint price = IAux(AUX).getTWAP(0);
        if (fromV4 > 0)
            weth.transferFrom(msg.sender,
                    address(this), fromV4);

        USDC.transferFrom(msg.sender,
            address(this), amount);

        uint deposited = amount;
        _putUSDC(amount);

        uint inWETH = FullMath.mulDiv(WAD,
                    amount * 1e12, price);
        // ^ convert USDC to 18 decimals first

        uint neededFromV3 = 0;
        if (inWETH > fromV4)
            neededFromV3 = V3.take(inWETH - fromV4);
        // borrow WETH from V3, use in AAVE
        // as collateral to borrow dollars
        _put(fromV4 + neededFromV3); // collat
        uint totalWETH = fromV4 + neededFromV3;
        amount = FullMath.mulDiv(totalWETH * 7 / 10,
                                 price, WAD * 1e12);

        // borrow 70% of the WETH value in USDC
        AAVE.borrow(address(USDC), amount, 2, 0,
            address(this)); _putUSDC(amount);
        totalBorrowed[address(USDC)] += amount;
        Types.viaAAVE memory order = Types.viaAAVE({
            breakeven: deposited * 1e12, // supplied gets reset
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: neededFromV3, borrowed: amount,
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
            msg.sender, false, neededFromV3,
            amount, 0, int(price),
            deposited, block.number);
    }

    function _getUSDC(uint howMuch)
        internal returns (uint withdrawn) {
        uint amount = Math.min(USDCsharesSnapshot, howMuch);
        withdrawn = AAVE.withdraw(address(USDC),
                          amount, address(this));
    }
    function _put(uint amount) internal {
        AAVE.supply(address(weth), amount, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(address(weth), true);
    }
    function _putUSDC(uint amount) internal {
        AAVE.supply(address(USDC), amount, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(address(USDC), true);
    }
    function _get(uint howMuch)
        internal returns (uint withdrawn) {
        uint amount = Math.min(wethSharesSnapshot, howMuch);
        withdrawn = AAVE.withdraw(address(weth),
                        amount, address(this));

        if (msg.sender != address(this))
            weth.transfer(msg.sender, withdrawn);
    }

    function _buyUSDC(uint howMuch,
        uint price) internal returns (uint) {
        Types.AuxContext memory ctx;
        ctx.v3Pool = address(v3Pool);
        ctx.v3Router = address(v3Router);
        ctx.weth = address(weth);
        ctx.usdc = address(USDC);
        ctx.v3Fee = V3.POOL_FEE();

        return BasketLib.swapWETHtoUSDC(
                    ctx, howMuch, price);
    }

    function _buy(uint howMuch,
        uint price) internal returns (uint) {
        Types.AuxContext memory ctx;
        ctx.v3Pool = address(v3Pool);
        ctx.v3Router = address(v3Router);
        ctx.weth = address(weth);
        ctx.usdc = address(USDC);
        ctx.v3Fee = V3.POOL_FEE();

        return BasketLib.swapUSDCtoWETH(
                    ctx, howMuch, price);
    }

    function _deposit(uint amount) internal returns (uint) {
        if (amount > 0) { weth.transferFrom(msg.sender,
                            address(this), amount);
        } if (msg.value > 0) { weth.deposit{
                            value: msg.value}();
                         amount += msg.value;
        }         return amount;
    }

    /// @param out Token to withdraw
    /// @param borrowed Amount borrowed
    /// @param supplied Amount supplied
    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        if (borrowed > 0) AAVE.repay(repay,
                borrowed, 2, address(this));

        if (supplied > 0 && out != address(0)) {
            uint tracked = totalBorrowed[repay];
            totalBorrowed[repay] = borrowed >
            tracked ? 0 : tracked - borrowed;
            uint withdrawn = AAVE.withdraw(out,
                    supplied, address(this));
            require(withdrawn >= supplied - 5,
                    "withdraw slippage");
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
        uint scaledDebt; uint borrowIndex; uint actualDebt;
        if (userData.length > 0 && reserveData.length > 0) {
            borrowIndex = reserveData[0].variableBorrowIndex;
            scaledDebt = userData[0].scaledVariableDebt;

            actualDebt = (scaledDebt * borrowIndex) / RAY;
            // index 4 on Arbi and Poly, 0 on L1 and Base,
            wethSharesSnapshot = IERC20(reserveData[0].aTokenAddress).balanceOf(address(this));
            // Safe subtraction - if tracking drifted, just return 0
            repay = actualDebt > totalBorrowed[address(weth)]
                ? actualDebt - totalBorrowed[address(weth)] : 0;

            borrowIndex = reserveData[3].variableBorrowIndex;
            scaledDebt = userData[3].scaledVariableDebt;
            actualDebt = (scaledDebt * borrowIndex) / RAY;
            // index 3 on L1, 4 on Base, 12 on Arb, 22 on Polygon
            USDCsharesSnapshot = IERC20(reserveData[3].aTokenAddress).balanceOf(address(this));

            repayUSDC = actualDebt > totalBorrowed[address(USDC)]
                      ? actualDebt - totalBorrowed[address(USDC)] : 0;
        }
    }

    function unwindZeroForOne(
        address[] calldata whose) external {
        int price = int(IAux(AUX).getTWAP(1800));
        Types.viaAAVE memory pledge;

        uint i; uint buffer;
        uint pivot; uint touched;
        (uint repay, uint repayUSDC) = _howMuchInterest();

        while (i < 30 && i < whose.length) {
            address who = whose[i];
            pledge = token1isWETH ? pledgesOneForZero[who] :
                                    pledgesZeroForOne[who];
            if (pledge.price == 0) { i++; continue; }

            int delta = (price - pledge.price) * 1000 / pledge.price;
            if (delta <= -25 || delta >= 25) { touched += 1;
                if (pledge.borrowed > 0) {
                    pivot = _get(pledge.borrowed);
                    require(stdMath.delta(
                    pledge.borrowed, pivot) <= 5);
                    _unwind(address(weth), address(USDC),
                                 pivot, pledge.supplied);

                    if (delta <= -25) {
                        // buy the dip - convert all USDC to WETH
                        buffer = FullMath.mulDiv(pledge.borrowed,
                                uint(pledge.price), WAD * 1e12);

                        pivot = _getUSDC(buffer);
                        require(stdMath.delta(pivot, buffer) <= 5);

                        buffer = pivot + pledge.supplied;
                        pivot = FullMath.mulDiv(WAD,
                            buffer * 1e12, uint(price));
                        buffer = _buy(buffer, uint(price)); // buy ETH
                        buffer += _get(pledge.buffer); _put(buffer);

                        pledge.supplied = buffer;
                        pledge.price = price;
                        pledge.buffer = 0;
                    } else {
                        // Price up - sell buffer WETH for USDC
                        buffer = _get(pledge.buffer);
                        require(stdMath.delta(buffer, pledge.buffer) <= 5);
                        pivot = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        pivot = _buyUSDC(buffer, uint(price)) + pledge.supplied;
                        pledge.buffer = pivot + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                        pledge.supplied = 0;
                        _putUSDC(pivot);
                    }   pledge.borrowed = 0;

                    if (token1isWETH) pledgesOneForZero[who] = pledge;
                    else pledgesZeroForOne[who] = pledge;
                }
                else if (delta <= -25 && pledge.buffer > 0) {
                    // Second pivot down - buffer is USDC, buy WETH
                    buffer = _getUSDC(pledge.buffer);
                    require(stdMath.delta(buffer, pledge.buffer) <= 5);
                    pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = _buy(buffer, uint(price)); // buy ETH
                    pledge.supplied = buffer; _put(buffer);
                    pledge.buffer = 0; pledge.price = price;

                    if (token1isWETH) pledgesOneForZero[who] = pledge;
                    else pledgesZeroForOne[who] = pledge;
                }
                else if (delta >= 25 && pledge.supplied > 0) {
                    // Final exit - supplied is WETH, sell for USDC
                    buffer = _get(pledge.supplied);

                    // Pay down global WETH interest first
                    if (repay > 0) {
                        pivot = Math.min(
                            buffer, repay);
                        buffer -= pivot;
                        repay -= pivot;
                        _unwind(address(weth),
                        address(0), pivot, 0);
                    }
                    pivot = FullMath.mulDiv(uint(price), buffer, 1e12 * WAD);
                    pivot = _buyUSDC(buffer, uint(price));
                    uint breakeven = pledge.breakeven / 1e12;
                    // Handle underwater positions gracefully
                    if (pivot <= breakeven) {
                        // At a loss - return whatever we have
                        USDC.transfer(who, pivot);
                    } else {
                        uint profit = pivot - breakeven;
                        if (repayUSDC > 0) {
                            buffer = Math.min(
                            profit, repayUSDC);
                            profit -= buffer;
                            repayUSDC -= buffer;
                            _unwind(address(USDC),
                            address(0), buffer, 0);
                        }
                        USDC.transfer(who, breakeven + profit / 2);
                        V3.depositUSDC(profit / 2, uint(price));
                    }
                    if (token1isWETH)
                         delete pledgesOneForZero[who];
                    else delete pledgesZeroForOne[who];
                }
                emit PositionUnwound(who, true, price,
                                    delta, block.number);
            } i++;
        }
    }

    function unwindOneForZero(
        address[] calldata whose) external {
        int price = int(IAux(AUX).getTWAP(1800));
        Types.viaAAVE memory pledge;

        uint i; uint buffer;
        uint pivot; uint touched;
        (uint repay, uint repayUSDC) = _howMuchInterest();

        while (i < 30 && i < whose.length) {
            address who = whose[i];
            pledge = token1isWETH ? pledgesZeroForOne[who] :
                                    pledgesOneForZero[who];

            if (pledge.price == 0) { i++; continue; }
            int delta = (price - pledge.price) * 1000 / pledge.price;
            if (delta <= -25 || delta >= 25) { touched += 1;
                if (pledge.borrowed > 0) {
                    pivot = _getUSDC(pledge.borrowed);
                    _unwind(address(USDC), address(weth), pivot, pledge.supplied);
                    if (delta >= 25) { // Price up (bad for short) - sell WETH for USDC
                        pivot = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = _buyUSDC(pledge.supplied, uint(price));
                        _putUSDC(pledge.supplied);
                    } else {
                        // Price down (good for short) - hold WETH in buffer
                        pledge.buffer = pledge.supplied;
                        _put(pledge.supplied);
                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledge.price = price;

                    if (token1isWETH) pledgesZeroForOne[who] = pledge;
                    else pledgesOneForZero[who] = pledge;
                }
                else if (delta <= -25 && pledge.supplied > 0) {
                    // Second pivot - supplied is USDC, buy WETH
                    pivot = _getUSDC(pledge.supplied);
                    require(stdMath.delta(pledge.supplied, pivot) <= 5);
                    pivot = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer = _buy(pledge.supplied, uint(price));

                    _put(pledge.buffer);
                    pledge.supplied = 0;
                    pledge.price = price;

                    if (token1isWETH) pledgesZeroForOne[who] = pledge;
                    else pledgesOneForZero[who] = pledge;
                }
                else if (delta >= 25 && pledge.buffer > 0) {
                    // Final exit - buffer is WETH, sell for USDC
                    buffer = _get(pledge.buffer);

                    // Pay down global WETH interest first
                    if (repay > 0) {
                        pivot = Math.min(buffer, repay);
                        buffer -= pivot; repay -= pivot;
                        _unwind(address(weth),
                        address(0), pivot, 0);
                    }
                    pivot = FullMath.mulDiv(uint(price),
                                    buffer, 1e12 * WAD);
                    pivot = _buyUSDC(buffer, uint(price));
                    // longs and shorts store breakeven in 18 dec
                    uint breakeven = pledge.breakeven / 1e12;

                    // Handle underwater positions
                    if (pivot <= breakeven) {
                        USDC.transfer(who, pivot);
                    } else {
                        uint profit = pivot - breakeven;
                        if (repayUSDC > 0) {
                            buffer = Math.min(
                            profit, repayUSDC);
                            profit -= buffer;
                            repayUSDC -= buffer;
                            _unwind(address(USDC),
                            address(0), buffer, 0);
                        }
                        USDC.transfer(who, breakeven + profit / 2);
                        V3.depositUSDC(profit / 2, uint(price));
                    }
                    if (token1isWETH)
                         delete pledgesZeroForOne[who];
                    else delete pledgesOneForZero[who];
                }
                emit PositionUnwound(who, false, price,
                                    delta, block.number);
            } i++;
        }
    }
}
