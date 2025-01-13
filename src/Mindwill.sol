
// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4 <0.9.0;
import {Good} from "./GD.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";

import {TickMath} from "./imports/math/TickMath.sol";
import {FullMath} from "./imports/math/FullMath.sol";
import {ISwapRouter} from "./imports/ISwapRouter.sol"; // on L1 and Arbitrum
import {IUniswapV3Pool} from "./imports/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./imports/math/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "./imports/INonfungiblePositionManager.sol";
// import {IV3SwapRouter as ISwapRouter} from "./imports/IV3SwapRouter.sol"; // base
import "lib/forge-std/src/console.sol"; // TODO 

contract MO is ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    address public immutable USDC;
    ERC20 public immutable token1;
    ERC20 public immutable token0;
    WETH public immutable WETH9;
    uint public ID; // V3 NFT...
    uint public FEE = WAD / 28;
    bool public token1isWETH;
    int24 internal UPPER_TICK;
    int24 internal LOWER_TICK;
    int24 internal LAST_TICK;
    uint internal _ETH_PRICE; // TODO 
    uint constant WAD = 1e18;
    uint24 constant POOL_FEE = 500;
    int24 constant MAX_TICK = 887220;
    int24 constant TICK_SPACING = 10;
    INonfungiblePositionManager NFPM;
    IUniswapV3Pool POOL; ISwapRouter ROUTER;
    uint128 liquidityUnderManagement; // UniV3
    mapping(address => uint) flashLoanProtect;
    struct FoldState { uint delta; // for fold()
        uint average_price; uint average_value;
        uint deductible; uint cap; uint minting;
        bool liquidate; uint repay; uint collat;
    } Good GD; // hooked 25 to life MO contract
    function get_info(address who) view
        external returns (uint, uint) { // you good
        Offer memory pledge = pledges[who]; // bro?
        return (pledge.carry.debit, GD.balanceOf(who));
        // this is more of an internal tracking variable
    }   function get_more_info(address who) view
        external returns (uint, uint, uint, uint) {
            Offer memory pledge = pledges[who];
        // work is pledged as a CDP, weth as insurance
        return (pledge.work.debit, pledge.work.credit,
                pledge.weth.debit, pledge.weth.credit);
        // for address(this), this ^^^^^^^^^^^^^^^^^^
        // is ETH amount (that we're hedging), and
        // for depositors it's the $ value hedged
    } // continuous payment from Uniswap LP fees
     // with a fixed charge (deductible) payable
     // upfront (half upon deposit, half in fold()
    struct Pod { // for pledge.weth this amounts to
        uint credit; // sum[amt x price at deposit]
        uint debit; // quantity of tokens pledged
    } /* carry.credit = contribution to weighted
     SUM of [(GD / total GD) x (ROI / avg ROI)] */
    uint public SUM = 1; uint public AVG_ROI = 1;
    struct Offer { Pod weth; Pod carry; Pod work;
    // work is force times distance (leverage) ^
    Pod last; } // timestamp of last liquidation,
    // for address(this) it's time since NFPM.burn
    // work is like a checking account (credit can
    // be drawn against it) while weth is savings,
    // they pay interest to the contract itself;
    // savings can serve as brakes for credit,
    // carry is relevant in redemption
    // recall the 3rd Delphic maxim...
    mapping (address => Offer) pledges;
    function fetch(address beneficiary) public 
        returns (Offer memory, uint, uint160) { 
        Offer memory pledge = pledges[beneficiary];
        (uint160 sqrtPrice, int24 tick,,,,,) = POOL.slot0();
        LAST_TICK = tick; uint price = getPrice(sqrtPrice);
        return (pledge, price, sqrtPrice);
    } 
    function setQuid(address _quid) 
        external { require(address(GD) == 
            address(0), "set"); GD = Good(_quid);
        require(GD.Mindwill() == address(this), "42");
    }
    modifier onlyQuid {
        require(msg.sender
            == address(GD),
            "unauthorised"); _;
    }
    receive() external payable {}
    function setFee(uint index)
        public onlyQuid { require(
            index < 33, "out of bounds");
        FEE = WAD * (36 - index) / 400;
    }   
    function setMetrics(uint avg_roi) 
        public onlyQuid { AVG_ROI = avg_roi;
    } // TODO add more informative metrics...
    function dollar_amt_to_gd_amt(uint cap, 
        uint amt) public view returns (uint) {
            if (cap == 0) { 
                (, cap) = capitalisation(0, false);
            }
            return FullMath.mulDiv(amt,
              100 + (100 - cap), 100);
    }
    // not same as eponymous function in GD
    function gd_amt_to_dollar_amt(uint cap,
        uint amt) public view returns (uint) {
        if (cap == 0) {
            (, cap) = capitalisation(0, false);
        }
        return FullMath.mulDiv(amt, cap, 100);
    }

    function set_price_eth(bool up,
        bool refresh) external {
        (uint160 sqrtPriceX96
          ,,,,,,) = POOL.slot0();
        if (refresh) { _ETH_PRICE = 0;
          _ETH_PRICE = getPrice(sqrtPriceX96);
        } else { uint delta = _ETH_PRICE / 5;
            _ETH_PRICE = up ? _ETH_PRICE + delta
                              : _ETH_PRICE - delta;
        } // TODO remove this testing function...
    }

    constructor(address _weth, address _usdc,
        address _nfpm, address _pool, 
        address _router) { USDC = _usdc;
        WETH9 = WETH(payable(_weth));
        POOL = IUniswapV3Pool(_pool);
        ROUTER = ISwapRouter(_router);
        NFPM = INonfungiblePositionManager(_nfpm);
        token0 = ERC20(POOL.token0());
        token1 = ERC20(POOL.token1());
        token1isWETH = address(token0) == USDC;
        token0.approve(_router, 
            type(uint256).max);
        token1.approve(_router,
            type(uint256).max);
        token0.approve(_nfpm,
            type(uint256).max);
        token1.approve(_nfpm,
            type(uint256).max);
        
    } // present value of the expected cash flows
    function capitalisation(uint quid, bool burn)
        public view returns (uint, uint) { // ^ in GD
        (uint160 sqrtPriceX96,,,,,,) = POOL.slot0();
        uint price = getPrice(sqrtPriceX96); // in $
        Offer memory pledge = pledges[address(this)];
        // collateral may be sold or claimed in fold
        uint collateral = FullMath.mulDiv(price,
            pledge.work.credit, WAD // in $ for
        ); // ETH pledged as to borrow GD;
        // collected in deposit and fold...
        uint deductibles = FullMath.mulDiv(
            price, pledge.weth.debit, WAD // $
        ); // weth.debit is ETH owned by contract
        // which also includes LP fees collected;
        // total composition of solvency capital:
        uint assets = collateral + deductibles +
        pledge.work.debit; uint eth; uint usdc; 
        // business float: working capital (LP)
        (int24 tick_lower, 
         int24 tick_upper) = _adjustTicks(LAST_TICK);
        if (token1isWETH) { // make sure LAST_TICK is not zero...
            (usdc, eth) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtPriceAtTick(LAST_TICK),
                TickMath.getSqrtPriceAtTick(tick_lower),
                TickMath.getSqrtPriceAtTick(tick_upper),
                liquidityUnderManagement);
        } else {
            (eth, usdc) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtPriceAtTick(LAST_TICK),
                TickMath.getSqrtPriceAtTick(tick_lower),
                TickMath.getSqrtPriceAtTick(tick_upper),
                liquidityUnderManagement);
        }
        require(FullMath.mulDiv(eth, price, 
            WAD) + usdc * 1e12 >= assets + 
            FullMath.mulDiv(pledge.weth.credit, 
                 price, WAD)); // ^ hedged ETH
        assets += GD.get_total_deposits(true);
        uint total = GD.totalSupply(); 
        if (quid > 0) { 
            total = (burn) ? 
            total - quid : total + quid;
        }   if (assets >= total) 
            { return (assets - total, 100); }
            else { return ((total - assets),
            FullMath.mulDiv(100, assets, total));
        } // returns delta from being 100% backed
    }

    // helpers allow treating GD balances
    // uniquely without needing ERC721...
    function transferHelper(address from,
        address to, uint amount, // GD
        uint priorBalance) onlyQuid // ^
        public returns (uint) {
        // repay work.credit debt by GD
        if (to == address(this)) { // transfer to MO
            uint credit = pledges[from].work.credit;
            (, uint cap) = capitalisation(
                            amount, true);
            uint burn = FullMath.min(
                gd_amt_to_dollar_amt(
                cap, amount), credit);

            pledges[from].work.credit -= burn; return burn;
        } else if (to != address(0)) { // % of carry.debit 
            // gets transferred over pro rata to amount's % 
            // of total balance, from it % for ROI transfer
            // for purposes of "tokenising NFT into ERC20"
            uint ratio = FullMath.mulDiv(WAD,
                    amount, priorBalance);
            require(ratio <= WAD, "not enough");
            // proportionally transfer debit...
            uint debit = FullMath.mulDiv(ratio,
            pledges[from].carry.debit, WAD);
            pledges[to].carry.debit += debit;
            pledges[from].carry.debit -= debit;
            _creditHelper(to);
        }   _creditHelper(from);
            return amount;
    }
    function _creditHelper(address who) internal {
        uint credit = pledges[who].carry.credit;
        SUM -= FullMath.min(SUM, credit); // old--
        // may be zero if this is the first time
        // _creditHelper is called for `who`...
        uint balance = GD.balanceOf(who);
        uint debit = pledges[who].carry.debit;
        uint share = FullMath.mulDiv(WAD,
            balance, GD.totalSupply());
        credit = share; // workaround from using NFT
        if (debit > 0 && GD.currentBatch() > 0) {
            // projected ROI if GD is $1...
            uint roi = FullMath.mulDiv(WAD,
                    balance - debit, debit);
            // calculate individual ROI over total
            roi = FullMath.mulDiv(1, roi, AVG_ROI);
            // console.log("....ROI....", roi);
            // TODO WAD instead of 1 maybe? 
            credit = FullMath.mulDiv(roi, share, WAD);
            // credit is the product (composite) of
            // two separate share (ratio) quantities
            // and the sum of products is what we use
            // in determining pro rata in redeem()
        }   pledges[who].carry.credit = credit;
        SUM += credit; // update sum with new share
    }

    function _repackNFT(uint amount0, uint amount1,
        uint price) internal { uint128 liquidity;
        uint last = flashLoanProtect[address(this)];
        flashLoanProtect[address(this)] = block.number;
        (LOWER_TICK, UPPER_TICK) = _adjustTicks(LAST_TICK);
        if (pledges[address(this)].last.credit != 0) { 
            // not the first time _repackNFT is called
            if ((LAST_TICK > UPPER_TICK || LAST_TICK < LOWER_TICK) &&
            // "to improve is to change, to perfect is to change often"
            block.timestamp - pledges[address(this)].last.credit >= 10 minutes) {
                // && last != block.number) { // TODO comment out for local testing 
                // we want to make sure that all of the WETH deposited to this
                // contract is always in range (collecting), and range is ~7%
                // below and above tick, as voltage regulators watch currents
                // and control a relay (which turns on & off the alternator,
                // if below or above 12 volts, (re-charging battery as such)
                (,,,,,,, liquidity,,,,) = NFPM.positions(ID);
                (uint collected0,
                 uint collected1) = _withdrawAndCollect(liquidity);
                amount0 += collected0; amount1 += collected1;
                NFPM.burn(ID); 
            }
        } if (liquidity > 0 || ID == 0) {
            if (ID != 0) {
                if (token1isWETH) { (amount1, amount0) = _swap(
                                     amount1, amount0, price);
                } else { (amount0, amount1) = _swap(
                          amount0, amount1, price); 
                } 
            }   (ID, liquidityUnderManagement,,) = NFPM.mint(
                    INonfungiblePositionManager.MintParams({ token0: address(token0),
                        token1: address(token1), fee: POOL_FEE, tickLower: LOWER_TICK,
                            tickUpper: UPPER_TICK, amount0Desired: amount0,
                    amount1Desired: amount1, amount0Min: 0, amount1Min: 0,
                    recipient: address(this), deadline: block.timestamp }));
                    pledges[address(this)].last.credit = block.timestamp;
        } // metrics at the expense of sometimes doing 1 extra swap:
        else { (uint collected0, uint collected1) = _collect(price);
            amount0 += collected0; amount1 += collected1;
            (liquidity,,) = NFPM.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    ID, amount0, amount1, 0, 0, block.timestamp));
                    liquidityUnderManagement += liquidity;
        } 
    }
    function repackNFT() public nonReentrant {
        (uint160 sqrtPriceX96,,,,,,) = POOL.slot0();
        _repackNFT(0, 0, getPrice(sqrtPriceX96));
        // TODO test ID before and after, after
        // set_price_eth in mainnetFork
    }
    // from v3-periphery/OracleLibrary...
    function getPrice(uint160 sqrtRatioX96)
        public view returns (uint price) {
        if (_ETH_PRICE > 0) { // TODO
            return _ETH_PRICE; // remove
        } 
        uint casted = uint(sqrtRatioX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);

        if (token1isWETH) {
            price = FullMath.mulDiv(
                1 << 128, WAD * 1e12, 
                ratioX128);
        } else { // token1 is not WETH
            price = FullMath.mulDiv(
                ratioX128, WAD * 1e12, 
                1 << 128
            );
        }
    }
    function _collect(uint price) internal 
        returns (uint amount0, uint amount1) {
        (amount0, amount1) = NFPM.collect(
            INonfungiblePositionManager.CollectParams(ID,
                address(this), type(uint128).max, type(uint128).max
            )); // "collect calls to the tip sayin' how ya changed"
        if (price > 0) { // we also collect metrics about earnings...
            // in swap fees. eventually, these will be different (they
            // vary from moment to moment based on the pool ratio) so
            // our approximation is for informational purposes only
             if (token1isWETH) { (amount1, amount0) = _swap(
                                  amount1, amount0, price);
                pledges[address(this)].weth.debit += amount1;
                pledges[address(this)].work.debit += amount0 * 1e12;
            } else { (amount0, amount1) = _swap(
                      amount0, amount1, price);
                pledges[address(this)].weth.debit += amount0;
                pledges[address(this)].work.debit += amount1 * 1e12;
            }
        }
    }
    function _withdrawAndCollect(uint128 liquidity)
        internal returns (uint amount0, uint amount1) {
        require(liquidity > 0, "nothing to decrease");
        if (liquidity > liquidityUnderManagement) {
            liquidity = liquidityUnderManagement;
            liquidityUnderManagement = 0;
        } else {
            liquidityUnderManagement -= liquidity;
        }
        NFPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                ID, liquidity, 0, 0, block.timestamp));  
                        (amount0, amount1) = _collect(0);
    }
    function _adjustToNearestIncrement(int24 input)
        internal pure returns (int24) {
        int24 remainder = input % TICK_SPACING;
        if (remainder == 0) return input;
        
        int24 result = remainder >= TICK_SPACING / 2
            ? input + (TICK_SPACING - remainder)
            : input - remainder;
        
        // Clamp to valid tick range
        return result > MAX_TICK ? MAX_TICK :
            result < -MAX_TICK ? -MAX_TICK :
            result;
    }
    function _adjustTicks(int24 currentTick) internal 
        pure returns (int24 lower, int24 upper) {
        // Minding stairs, leading to the mid-chamber,
        // consisted of three, five, and seven steps.
        int256 tickDelta = (int256(currentTick) * 357) / 10000;
        tickDelta = tickDelta == 0 ? TICK_SPACING : tickDelta;
    
        upper = _adjustToNearestIncrement(
            currentTick + int24(tickDelta));
        lower = _adjustToNearestIncrement(
            currentTick - int24(tickDelta));
        // Ensure minimum 
        // spacing between 
        if (upper == lower) { 
            upper += TICK_SPACING;
        }   return (lower, upper);
    }
    function _swap(uint eth, uint usdc, 
        uint price) internal returns (uint, uint) {
        console.log("###########      USDC      ###########", usdc);
        console.log("###########      eth      ###########", eth);
        uint usd = FullMath.mulDiv(eth, price, WAD);
        console.log("###########      usd      ###########", usd);
        // if we assumed a 1:1 ratio of eth value
        // to usdc, then this is how'd we balance:
        // int delta = (int(usd) - int(scaled))
        //            / int(2 * price / 1e18);
        // if (delta < 0) { // sell $
        //     selling = uint(delta * -1);
        //     selling = FullMath.mulDiv(
        //         selling, price, 1e30);
        //     usdc -= selling;
        //     eth += ROUTER.exactInput(
        //         ISwapRouter.ExactInputParams(abi.encodePacked(
        //             USDC, POOL_FEE, address(WETH9)), address(this),
        //             block.timestamp, selling, 0));
        // }
        (int24 tick_lower, int24 tick_upper) = _adjustTicks(LAST_TICK);
        uint160 lower = TickMath.getSqrtPriceAtTick(tick_lower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tick_upper);
        uint160 current = TickMath.getSqrtPriceAtTick(LAST_TICK); 
        uint128 liquidity; uint scaled = usdc * 1e12; // precision
        uint targetETH; uint targetUSDC;
        if (token1isWETH) {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                                            current, upper, eth);
            (targetUSDC, targetETH) = LiquidityAmounts.getAmountsForLiquidity(
                                             current, lower, upper, liquidity);
        } else { liquidity = LiquidityAmounts.getLiquidityForAmount0(
                                                current, upper, eth);
            (targetETH, targetUSDC) = LiquidityAmounts.getAmountsForLiquidity(
                                             current, lower, upper, liquidity);
        } targetUSDC *= 1e12; // must also divide at the end for precision...
        address vault = GD.VAULT();
        // TODO in mainnet fork test
        console.log("targetUSDC", targetUSDC);
        console.log("targetETH", targetETH);
        if (scaled > targetUSDC) { // use
            scaled -= targetUSDC; // prank 
            console.log("m8 !", scaled); // USDC
            ERC4626(vault).deposit(
                scaled / 1e12, 
                address(GD));
            scaled = targetUSDC;
        } else { 
            scaled += ERC4626(vault).convertToAssets(
                GD.withdrawUSDC(targetUSDC - scaled)) * 1e12;
        } 
        if (targetUSDC > scaled) {
            uint k = FullMath.mulDiv(
            targetETH, WAD, targetUSDC);
            uint denom = WAD + FullMath.mulDiv(
                                k, price, WAD);
        
            uint ky = k * (scaled + 1);
            // assume eth is X and usdc is Y...
            // our formula is (x - ky)/(1 + kp);
            // we are selling X to buy Y, where
            // p is the price of eth, and the
            // derivation steps: assume n
            // is amount being swapped...
            // (x - n)/(y + np) = k target
            // x - n = ky + knp
            // x - ky = n + knp
            // x - ky = n(1 + kp)
            uint selling = FullMath.mulDiv(
                    WAD, eth - ky,  denom);
            // console.log("selling...", selling);
            // TODO maybe divide by WAD again
            eth -= selling; 
            scaled += ROUTER.exactInput(
                ISwapRouter.ExactInputParams(abi.encodePacked(
                    address(WETH9), POOL_FEE, USDC), address(this),
                    block.timestamp, selling, 0)) * 1e12;
            
            ky = FullMath.mulDiv(
                eth, WAD, scaled);
            require(FullMath.mulDiv(
                1000, ky - k, k) < 68, 
                "margin of error"); 
                // (($10m x (0.0725 x 3/12)
                // - 11000 / $10m)) x 4
        } return (eth, scaled / 1e12);
    }

    function mint(address to, uint cost, 
        uint minted) public onlyQuid {
        pledges[to].carry.debit += cost; 
        pledges[address(this)].carry.credit += 
        minted - cost; _creditHelper(to); 
        // affects ROI, thus redemption
    } // ты что-то варишь, тот товарищ?

    // this function will take deposits of ETH only...
    function deposit(address beneficiary, uint amount, 
        bool long) external nonReentrant payable { 
        uint in_dollars; (Offer memory pledge, 
         uint price, ) = fetch(beneficiary);
        if (amount > 0) { WETH9.transferFrom(
            msg.sender, address(this), amount);
        } else { require(msg.value > 0, "ETH!"); }
        if (msg.value > 0) { amount += msg.value;
            WETH9.deposit{ value: msg.value }();
        }   if (long) { pledge.work.debit += amount;
            pledges[address(this)].work.credit += amount;
        } // ^ tracks total ETH pledged as collateral to borrow... 
        else { in_dollars = FullMath.mulDiv(price, amount, WAD);
            uint deductible = FullMath.mulDiv(in_dollars, FEE, WAD);
            // change deductible to be in units of ETH instead...
            deductible = FullMath.mulDiv(WAD, deductible, price);
            uint hedged = amount - deductible; // in ETH
            pledge.weth.debit += hedged; // withdrawable
            // by folding balance into pledge.work.debit...
            pledges[address(this)].weth.debit += deductible;
            pledge.weth.credit += in_dollars - deductible;
            // ^ the average dollar value of hedged ETH...
            pledges[address(this)].weth.credit += hedged;
            require(GD.get_total_deposits(true) > FullMath.mulDiv(
                pledges[address(this)].weth.credit, price, WAD), 
                "over-encumbered"); // ^ ETH hedged 
        }       pledges[beneficiary] = pledge;
                (amount, in_dollars) = _swap(amount, 0, price);
                token1isWETH ? _repackNFT(in_dollars, amount, price) 
                             : _repackNFT(amount, in_dollars, price);
    } // call in GD's worth (обнал sans liabilities)
    // calculates the coverage absorption for each
    // insurer by first determining their share %
    // and then adjusting based on average ROI...
    // (insurers with higher ROI absorb more)...
    // "you never count your money while you're
    // sittin' at the table...there'll be time
    function redeem(uint amount) // into $
        external nonReentrant { // TODO param
        // which allows to facilitate mint 
        // GHO instead of dispersing stables
        amount = FullMath.min(
            GD.matureBalanceOf(
                    msg.sender), amount);
        require(amount > 0, "let it steep");
        // can be said of tea or a t-bill...
        (uint delta, 
        uint cap) = capitalisation(amount, true);
        uint share = FullMath.mulDiv(WAD, amount,
                GD.matureBalanceOf(msg.sender));
   
        uint absorb = FullMath.mulDiv(WAD, 
            pledges[msg.sender].carry.credit, SUM);
       
        absorb = FullMath.mulDiv(absorb,
            pledges[address(this)].carry.credit, WAD); 
    
        /* carry.credit = contribution to weighted
         SUM of [(GD / total GD) x (ROI / avg ROI)] */
        // see _creditHelper to see how SUM is handled
        if (WAD > share) { // redeeming less than 100%
        // so we recalculate, previous value of absorb
        // is max $ pledge would absorb if redeemed 100%
            absorb = FullMath.mulDiv(absorb, share, WAD);
        } GD.turn(msg.sender, amount); // creditHelper, 
        // in turn, will handle decrementing carry.credit
        absorb = FullMath.min(absorb, amount / 3); // cap loss
        amount -= absorb; // this is how liabilities get absorbed
        amount -= GD.morph(msg.sender, amount); // L1 & Base
        if (amount > 0) { (, uint price,) = fetch(msg.sender); 
            uint amount0; uint amount1; uint128 liquidity;
            if (token1isWETH) {
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                            TickMath.getSqrtPriceAtTick(LAST_TICK),
                            TickMath.getSqrtPriceAtTick(UPPER_TICK), 
                            amount / 1e12); // scale down precision
                (amount0, amount1) = _withdrawAndCollect(liquidity);
                delta = amount / 1e12 - amount0; amount = amount0;
                (amount1, amount0) = _swap(amount1, 0, price);
            } else { 
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                            TickMath.getSqrtPriceAtTick(LOWER_TICK),  
                            TickMath.getSqrtPriceAtTick(LAST_TICK),
                            amount / 1e12); // scale down precision
                (amount0, amount1) = _withdrawAndCollect(liquidity);
                delta = amount / 1e12 - amount1; amount = amount1;
                (amount0, amount1) = _swap(amount0, 0, price);
            }
            if (delta > 0) { delta = GD.withdrawUSDC(delta * 1e12); }
            ERC20(USDC).transfer(msg.sender, amount + delta);
            // amount + delta is the liquid USDC in contract
            pledges[address(this)].carry.credit -= absorb;
            _repackNFT(amount0, amount1, price);
        } 
    }

    // bool quid says if amount is GD
    // ETH can only be withdrawn from
    // pledge.work.debit; if ETH was
    // deposited pledge.weth.debit,
    // call fold() before withdraw()
    function withdraw(uint amount,
        bool quid) external nonReentrant 
        payable { uint amount0; uint amount1;
        require(flashLoanProtect[msg.sender] 
            != block.number, "non-flashable");
        (Offer memory pledge, uint price, 
        uint160 sqrtPrice) = fetch(msg.sender);
        if (quid) { // amount param in units of GD
            if (msg.value > 0) { 
                WETH9.deposit{ value: msg.value }();
                pledges[address(this)].work.credit +=
                msg.value; pledge.work.debit += msg.value;
            } 
            uint debit = FullMath.mulDiv(
            price, pledge.work.debit, WAD);
            uint haircut = debit - (debit / 10);
            require(haircut >= pledge.work.credit && haircut > 0, "CR"); 
            amount = FullMath.min(amount, 
            haircut - pledge.work.credit);
            if (amount > 0) { pledge.work.credit += amount;
                (, uint cap) = capitalisation(amount, false);
                amount = dollar_amt_to_gd_amt(cap, amount);
                GD.mint(msg.sender, amount, address(GD));
                pledges[address(this)].carry.credit += amount;
            } // ^ we only add to total supply in this function
        } else { uint withdrawable; // of ETH collateral (work.debit)
            if (pledge.work.credit > 0) { // see if we owe debt on it
                uint debit = FullMath.mulDiv( // dollar value of ETH
                price, pledge.work.debit, WAD);
                uint haircut = debit - debit / 10;
                require(haircut >= pledge.work.credit, "CR!");
                withdrawable = FullMath.mulDiv(haircut - 
                pledge.work.credit, WAD, price); // in ETH
            } // effectively, the protocol can buy ^^^^^^^
            // whenever, at a 10% marukup to current value
            uint transfer = amount; // input parameter
            if (transfer > withdrawable) {
                // clear remaining debt; no burn
                // from totalSupply yet, and this 
                // is fine considering protocol is
                // buying ETH on behalf of all...
                // (equal and opposite reaction)
                withdrawable = FullMath.mulDiv(
                WAD, pledge.work.credit, price); 
                if (pledge.work.debit >= withdrawable) { 
                    pledge.work.debit -= withdrawable;
                    pledges[address(this)].weth.debit += withdrawable; 
                    transfer = FullMath.min(amount, pledge.work.debit);
                    pledges[address(this)].carry.credit -= pledge.work.credit;
                    pledge.work.debit -= transfer; pledge.work.credit = 0;
                }
            } require(transfer > 0, "nothing to withdraw");
            pledges[address(this)].work.credit -= transfer;
            // for unwrapping from Uniswap to transfer ETH at the end...
            uint usdc = FullMath.mulDiv(price, transfer / 2, WAD * 1e12);
            if (token1isWETH) { amount1 = transfer / 2; amount0 = usdc; } 
            else { amount1 = usdc; amount0 = transfer / 2; } 
            (amount0, amount1) = _withdrawAndCollect(
                LiquidityAmounts.getLiquidityForAmounts(sqrtPrice,
                    TickMath.getSqrtPriceAtTick(LOWER_TICK),
                    TickMath.getSqrtPriceAtTick(UPPER_TICK),
                    amount0, amount1));      
            if (!token1isWETH) { // increase amount0 (eth) by amount1 sold
                amount0 += ROUTER.exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(token1), POOL_FEE, address(token0)),
                    address(this), block.timestamp, amount1, 0));
                    transfer = FullMath.min(transfer, amount0);
            } else { // increase amount1 by selling amount0 (usdc) for eth
                amount1 += ROUTER.exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(token0), POOL_FEE, address(token1)),
                    address(this), block.timestamp, amount0, 0)); 
                    transfer = FullMath.min(transfer, amount1);
            }   WETH9.withdraw(transfer);
            (bool success, ) = msg.sender.call{ 
                value: transfer }(""); 
                require(success, "$");
        }   pledges[msg.sender] = pledge; 
    }

    // underneath the halo of a street-lamp, I turn my straddle to
    // the cold and damp...know when to hold 'em...know when to...
    function fold(address beneficiary, uint amount, bool sell)
        external payable nonReentrant { FoldState memory state;
        (Offer memory pledge, uint price, ) = fetch(beneficiary); 
        // call in collateral that's hedged, or liquidate;
        // if there is a covered event, GD may be minted,
        // or simply clear the debt of a long position...
        // "teardrops on the fire of a confession", how
        // "we can serve our [wick nest] or we can serve
        // our purpose, but not both" ~ Mother Cabrini
        // "menace ou prière, l'un parle bien, l'autre 
        // se tait; et c'est l'autre que je préfère"
        flashLoanProtect[beneficiary] = block.number;
        // amount is irrelevant if it's a liquidation
        amount = FullMath.min(amount, 
              pledge.weth.debit);
        (, state.cap) = capitalisation(0, false); 
        // gzip у джинсы, зупинившись
        if (pledge.work.credit > 0) {
            state.collat = FullMath.mulDiv(
                price, pledge.work.debit, WAD
            ); // lookin' too hot...simmer down, бомба клад...
            if (pledge.work.credit > state.collat) { // or soon
                state.repay = pledge.work.credit - state.collat;
                state.repay += state.collat / 10; // you'll get
                state.liquidate = true; // dropped (reversible)
            } else { // repay is $ needed to reach healthy CR
                // the necessity of this feature is from the 
                // invariant that eventually all work.credit 
                // must reduce to 0, no matter how good CR
                // even if a depositor never comes back to 
                // pledge.work.credit += 
                state.delta = state.collat - pledge.work.credit;
                if (state.collat / 10 > state.delta) { // must get
                // back to minimum CR of 1.1 (safety invariant)...
                    state.repay = (state.collat / 10) - state.delta;
                } // ^ for using GD minted in order to payoff debt
            } // delta becomes remaining value after...^^^^^^^^^^^
        } if (amount > 0) { // TODO the script which calls fold()
        // must pass in a sufficient amount param (with sell = true)
        // in such a situation where this would remedy a liquidation;
        // we could optimise that here, but function is already huge
            state.collat = FullMath.mulDiv(amount, price, WAD);
            // we reuse the collat variable for secondary purpose
            state.average_price = FullMath.mulDiv(WAD,
                pledge.weth.credit, pledge.weth.debit
            ); // ^^^^^^^^^^^^^^^^ must be in dollars
            state.average_value = FullMath.mulDiv(
                amount, state.average_price, WAD
            ); 
            pledges[address(this)].work.credit += amount; pledge.work.debit += amount;
            // if price drop over 10% (average_value > 10% more than current value)...
            if (state.average_price >= FullMath.mulDiv(110, price, 100)) { // TODO guage
                state.delta = state.average_value - state.collat; // collat is amount...
                if (!sell) { state.minting = state.delta;
                    state.deductible = FullMath.mulDiv(WAD,
                        FullMath.mulDiv(state.collat,
                                FEE, WAD), price
                    ); // the sell method ensures that
                    // ETH will always be bought at dips
                    // so it's practical for the protocol
                    // to hold on to it (prices will rise)
                } else if (!state.liquidate) { // sell true
                // a form of protection against liquidation
                    // if liquidate = true it
                    // will be a sale regardless
                    state.deductible = amount;
                    state.minting = state.collat -
                        FullMath.mulDiv( // deducted
                            state.collat, FEE, WAD);
                } if (state.repay > 0) { // capitalise into work credit
                    state.cap = FullMath.min(state.minting, state.repay);
                    // ^^^^^^ variable re-used to conserve stack space...
                    pledge.work.credit -= state.cap; // enough to recap?
                    state.minting -= state.cap; // for GD amount to mint
                    state.repay -= state.cap; // remainder for liquidate
                }   (, state.cap) = capitalisation(state.delta, false);
                // new capitalisation including delta of minted supply
                if (state.minting > state.delta || state.cap > 64) { // TODO guage
                // minting will equal delta unless it's a sell, and 
                // if not, can't mint delta if under-capitalised...
                    state.minting = dollar_amt_to_gd_amt(
                                state.cap, state.minting);
                    GD.mint(beneficiary, state.minting, address(GD));
                    pledges[address(this)].carry.credit += state.minting;
                }   else { state.deductible = 0; } 
            }   
            pledges[address(this)].weth.credit -= amount;
            // amount is no longer hedged by the protocol
            pledge.weth.debit -= amount; // deduct amount
            pledge.weth.credit -= FullMath.min(
                pledge.weth.credit, state.collat);
            
            pledge.work.debit += amount - state.deductible; 
            // if it was a sale, then subtraction cancels out to 0
            pledges[address(this)].work.credit -= state.deductible;
            // because we'd just appended the amount a bit earlier 
            pledges[address(this)].weth.debit += state.deductible;

            state.collat = FullMath.mulDiv(pledge.work.debit, price, WAD); 
            if (state.collat > pledge.work.credit) { state.liquidate = false; }
        }   // things have gotten closer to the sun, and I've done things
        // in small doses, so don't think that I'm pushing you away, when
        if (state.liquidate) { // ⚡️ strikes and the 🏀 court lights get
            (, state.cap) = capitalisation(state.repay, true); // dim
            amount = FullMath.min(dollar_amt_to_gd_amt(state.cap, 
                state.repay), GD.balanceOf(beneficiary));
            GD.transferFrom(beneficiary, address(this), amount);
            amount = gd_amt_to_dollar_amt(state.cap, amount);
            pledge.work.credit -= amount; // subtract $ value
            state.delta = block.timestamp - pledge.last.credit;
            if (pledge.work.credit > state.collat // ^ time
                && state.delta >= 10 minutes) { // on the... 
                if (pledge.work.credit > WAD * 10) { // dime
                    // liquidation bot doesn't
                    // skip a chance to fold()
                    state.delta /= 10 minutes;
                    amount = FullMath.min(
                        pledge.work.debit, FullMath.max(
                        // each deduction non-linearly larger than last
                            pledge.last.debit + pledge.last.debit / 28,
                                FullMath.mulDiv(state.delta,
                                    pledge.work.debit, 6048)));
                                    // 1008 hours is 42 days...
                                    // 6048 = 6 x 10min per hour
                    // protocol just bought this amount of ETH...
                    pledges[address(this)].weth.debit += amount;
                                    pledge.work.debit -= amount;
                    amount = FullMath.min(pledge.work.credit,
                        FullMath.mulDiv(price, amount, WAD));
                    // "It's like inch by inch, and step by
                    // step, I'm closin' in on your position"
                    pledge.last.debit = amount; // in $...
                    pledge.work.credit -= amount; // reduction of debt
                    pledge.last.credit = block.timestamp; // snapshot sale
                } else { // truncate to prevent infinite reduction cycles
                    pledges[address(this)].work.credit -= pledge.work.debit;
                    pledges[address(this)].weth.debit += pledge.work.debit;
                    pledge.work.credit = 0; pledge.work.debit = 0; // reset
                    pledge.last.credit = 0; pledge.last.debit = 0; // storage
                } // "thinkin' about them licks I hit, I had to..." ~ future
            } // app-specific sequence hitter
        } else if (pledge.last.credit != 0) {
            // whenever there's a gap between 
            // liquidations, we reset metrics 
            // pro rata to the gap duration
            pledges[address(this)].carry.credit += pledge.last.credit;
            pledge.last.credit = 0;
            pledge.last.debit = 0;
        }   pledges[beneficiary] = pledge;
    } // save ^^^^^^^^^^^^^^^^^^ to storage
}
