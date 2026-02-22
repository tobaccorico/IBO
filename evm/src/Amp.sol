
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rover} from "./Rover.sol";
import {Types} from "./imports/Types.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {stdMath} from "forge-std/StdMath.sol";
import {BasketLib, AAVEv4, IHub, IAaveOracle} from "./imports/BasketLib.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IUiPoolDataProviderV3} from "aave-v3/helpers/interfaces/IUiPoolDataProviderV3.sol";
import {IPoolAddressesProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IAux {
    function deposit(address from, address token,
         uint amount) external returns (uint usd);

    function getTWAP(uint32 secondsAgo)
        external view returns (uint);
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

    AAVEv4 internal SPOKE;
    IHub internal HUB;

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
        USDC.approve(AUX, type(uint).max);

        USDC.approve(address(AAVE), type(uint).max);
        USDC.approve(address(v3Router), type(uint).max);
        token1isWETH = v3Pool.token0() == address(USDC);
        weth.approve(address(v3Router), type(uint).max);
        weth.approve(address(AAVE), type(uint).max);
    }

    function setV4(address _hub,
        address _spoke) external {
        require(msg.sender == AUX
            && address(SPOKE) == address(0));

        (,, uint wethCollat,
            uint usdcCollat) = _readV3Positions();

        if (wethCollat > 0) AAVE.withdraw(address(weth),
                            wethCollat, address(this));

        if (usdcCollat > 0) AAVE.withdraw(address(USDC),
                            usdcCollat, address(this));

        _setupV4(_hub, _spoke);
        uint wethBal = weth.balanceOf(address(this));
        uint usdcBal = USDC.balanceOf(address(this));

        if (wethBal > 0) SPOKE.supply(
             _reserveId(address(weth)),
               wethBal, address(this));

        if (usdcBal > 0) SPOKE.supply(
             _reserveId(address(USDC)),
               usdcBal, address(this));
    }

    function hasOpenDebt() external view returns (bool) {
        (uint wethDebt, uint usdcDebt,,) = _readV3Positions();
        return wethDebt > 0 || usdcDebt > 0;
    }

    function _setupV4(address _hub,
        address _spoke) internal {
        SPOKE = AAVEv4(_spoke); HUB = IHub(_hub);
        weth.approve(_hub, type(uint).max);
        USDC.approve(_hub, type(uint).max);
    }

    /// @dev Read actual v3 debt and collateral
    function _readV3Positions() internal view
        returns (uint wethDebt, uint usdcDebt,
                 uint wethCollat, uint usdcCollat) {

        (IUiPoolDataProviderV3.UserReserveData[]
          memory ud,) = DATA.getUserReservesData(
                             ADDR, address(this));

        (IUiPoolDataProviderV3.AggregatedReserveData[]
          memory rd,) = DATA.getReservesData(ADDR);

        if (ud.length > 0 && rd.length > 0) {
            wethDebt = (ud[0].scaledVariableDebt
                      * rd[0].variableBorrowIndex) / RAY;

            wethCollat = IERC20(rd[0].aTokenAddress).balanceOf(address(this));
        }
        if (ud.length > 3 && rd.length > 3) {
            usdcDebt = (ud[3].scaledVariableDebt
                      * rd[3].variableBorrowIndex) / RAY;
            usdcCollat = IERC20(rd[3].aTokenAddress).balanceOf(address(this));
        }
    }

    function _reserveId(address asset)
        internal returns (uint) {
        return SPOKE.getReserveId(address(HUB),
                    HUB.getAssetId(asset));
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
        } else amount = _deposit(amount);
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        require(totalValue >= 50e18); // min $50...
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

        if (borrowing > 0) {
            totalBorrowed[address(weth)] += borrowing;
            // ^ there will always be enough to pay this
            // back because we are depositting ETH first
            if (address(SPOKE) != address(0))
                SPOKE.borrow(_reserveId(address(weth)),
                             borrowing, address(this));

            else AAVE.borrow(address(weth), borrowing,
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
        require(deposited * 1e12 + FullMath.mulDiv(
                    fromV4, price, WAD) >= 50e18);

        _putUSDC(amount);
        uint inWETH = FullMath.mulDiv(WAD,
                    amount * 1e12, price);
        // ^ convert USDC to 18 decimals

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
        if (amount > 0) {
            if (address(SPOKE) != address(0))
                SPOKE.borrow(_reserveId(address(USDC)),
                                    amount, address(this));
            else AAVE.borrow(address(USDC), amount, 2, 0,
                                             address(this));
            _putUSDC(amount);

            totalBorrowed[address(USDC)] += amount;
            Types.viaAAVE memory order = Types.viaAAVE({
                breakeven: deposited * 1e12, // supplied\
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
    }

    function _getUSDC(uint howMuch) internal
        returns (uint withdrawn) {
        uint amount = Math.min(
        USDCsharesSnapshot, howMuch);
        if (amount == 0) return 0;
        if (address(SPOKE) != address(0))
            (, withdrawn) = SPOKE.withdraw(
                  _reserveId(address(USDC)),
                     amount, address(this));

        else withdrawn = AAVE.withdraw(address(USDC),
                              amount, address(this));
    }

    function _get(uint howMuch) internal
        returns (uint withdrawn) {
        uint amount = Math.min(
        wethSharesSnapshot, howMuch);
        if (amount == 0) return 0;
        if (address(SPOKE) != address(0))
            (, withdrawn) = SPOKE.withdraw(
                  _reserveId(address(weth)),
                     amount, address(this));

        else withdrawn = AAVE.withdraw(address(weth),
                              amount, address(this));
    }

    function _put(uint amount) internal {
        if (amount == 0) return;
        if (address(SPOKE) != address(0))
            SPOKE.supply(_reserveId(address(weth)),
                                amount, address(this));
        else { AAVE.supply(address(weth), amount, address(this), 0);
               AAVE.setUserUseReserveAsCollateral(address(weth), true); }
    }
    function _putUSDC(uint amount) internal {
        if (amount == 0) return;
        if (address(SPOKE) != address(0))
            SPOKE.supply(_reserveId(address(USDC)),
                                amount, address(this));
        else { AAVE.supply(address(USDC), amount, address(this), 0);
               AAVE.setUserUseReserveAsCollateral(address(USDC), true); }
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
    } /// @param out token to withdraw
    /// @param borrowed Amount borrowed
    /// @param supplied Amount supplied
    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        if (borrowed > 0) {
            if (address(SPOKE) != address(0))
                SPOKE.repay(_reserveId(repay),
                        borrowed, address(this));
            else AAVE.repay(repay, borrowed,
                          2, address(this));
        }
        if (out != address(0)) {
            uint tracked = totalBorrowed[repay];
            totalBorrowed[repay] = borrowed >
            tracked ? 0 : tracked - borrowed;
        }
        if (supplied > 0 && out != address(0)) {
            uint withdrawn;
            if (address(SPOKE) != address(0))
                (, withdrawn) = SPOKE.withdraw(
                    _reserveId(out), supplied,
                                  address(this));
            else withdrawn = AAVE.withdraw(out,
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
        if (address(SPOKE) != address(0)) {
            // V4: snapshot collateral via getUserSuppliedAssets
            uint id = _reserveId(address(weth));
            wethSharesSnapshot = SPOKE.getUserSuppliedAssets(
                                            id, address(this));
            id = _reserveId(address(USDC));
            USDCsharesSnapshot = SPOKE.getUserSuppliedAssets(
                                            id, address(this));

            AAVEv4.UserAccountData memory acct =
                SPOKE.getUserAccountData(address(this));
            if (acct.totalDebtValue == 0) return (0, 0);

            IAaveOracle oracle = IAaveOracle(SPOKE.ORACLE());
            // repay/repayUSDC reused as price, then unit, then prinVal
            repay = oracle.getReservePrice(
                  _reserveId(address(weth)));

            repayUSDC = oracle.getReservePrice(
                      _reserveId(address(USDC)));

            // wethPrinVal in `id`, usdcPrinVal in `acct.totalCollateralValue` (reuse)
            { uint wethUnit = 10 ** SPOKE.getReserve(
                            _reserveId(address(weth))).decimals;

              uint usdcUnit = 10 ** SPOKE.getReserve(
                            _reserveId(address(USDC))).decimals;

              uint wethPrinVal = repay > 0
                  ? (totalBorrowed[address(weth)] * repay)
                                              / wethUnit : 0;

              uint usdcPrinVal = repayUSDC > 0
                  ? (totalBorrowed[address(USDC)] * repayUSDC)
                                              / usdcUnit : 0;

              id = wethPrinVal + usdcPrinVal; // totalPrinVal
              if (acct.totalDebtValue > id && id > 0) {
                  uint interest = acct.totalDebtValue - id;
                  wethPrinVal = (interest * wethPrinVal) / id;
                  usdcPrinVal = interest - wethPrinVal;

                  // Convert back: repay still holds wethPrice
                  repay = repay > 0
                      ? (wethPrinVal * wethUnit) / repay : 0;
                  repayUSDC = repayUSDC > 0
                      ? (usdcPrinVal * usdcUnit) / repayUSDC : 0;

              } else { repay = 0; repayUSDC = 0; }
            }
        } else {
            // V3: index-based debt calculation
            ( IUiPoolDataProviderV3.UserReserveData[] memory userData,
            ) = DATA.getUserReservesData(ADDR, address(this)); uint actualDebt;
            ( IUiPoolDataProviderV3.AggregatedReserveData[] memory reserveData,
            ) = DATA.getReservesData(ADDR); uint scaledDebt; uint borrowIndex;
            if (userData.length > 0 && reserveData.length > 0) {
                borrowIndex = reserveData[4].variableBorrowIndex;
                scaledDebt = userData[4].scaledVariableDebt;
                actualDebt = (scaledDebt * borrowIndex) / RAY;
                // index 4 on Arbi and Poly, 0 on L1 and Base,
                wethSharesSnapshot = IERC20(reserveData[4].aTokenAddress).balanceOf(address(this));
                repay = actualDebt > totalBorrowed[address(weth)]
                    ? actualDebt - totalBorrowed[address(weth)] : 0;

                borrowIndex = reserveData[12].variableBorrowIndex;
                scaledDebt = userData[12].scaledVariableDebt;
                actualDebt = (scaledDebt * borrowIndex) / RAY;
                // index 3 on L1, 4 on Base, 12 on Arb, 22 on Polygon
                USDCsharesSnapshot = IERC20(reserveData[12].aTokenAddress).balanceOf(address(this));
                repayUSDC = actualDebt > totalBorrowed[address(USDC)]
                          ? actualDebt - totalBorrowed[address(USDC)] : 0;
            }
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
                    } else { // Price up...
                        // sell buffer WETH for USDC
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
                } else if (delta <= -25 && pledge.buffer > 0) {
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
                    // Final exit: supplied is WETH, sell for $
                    buffer = _get(pledge.supplied);

                    // Pay  global
                    // WETH interest
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
                        IAux(AUX).deposit(address(this),
                             address(USDC), profit / 2);
                    }
                    if (token1isWETH)
                         delete pledgesOneForZero[who];
                    else delete pledgesZeroForOne[who];
                } emit PositionUnwound(who, true, price,
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
                    } else { // Price down (good for short)
                        pledge.buffer = pledge.supplied;
                        _put(pledge.supplied);
                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledge.price = price;

                    if (token1isWETH) pledgesZeroForOne[who] = pledge;
                    else pledgesOneForZero[who] = pledge;
                } else if (delta <= -25 && pledge.supplied > 0) {
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
                } else if (delta >= 25 && pledge.buffer > 0) {
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
                        IAux(AUX).deposit(address(this),
                             address(USDC), profit / 2);
                    } // TODO Aux.deposit and we mint more upfront
                    // in leverETH there, maturing in one month !
                    if (token1isWETH)
                         delete pledgesZeroForOne[who];
                    else delete pledgesOneForZero[who];
                } emit PositionUnwound(who, false, price,
                                    delta, block.number);
            } i++;
        }
    }
}
