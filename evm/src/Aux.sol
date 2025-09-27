// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BasketLib} from "./BasketLib.sol";
import {Types} from "./imports/Types.sol";
import {Basket} from "./Basket.sol";
import {Vogue} from "./Vogue.sol";
import {Rover} from "./Rover.sol";
import {Amp} from "./Amp.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {stdMath} from "forge-std/StdMath.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

interface IStakeToken is IERC20 { // (safety module)
    function stake(address to, uint amount) external;
    function redeem(address to, uint amount) external;
    function claimRewards(address to, uint amount) external;
    function previewStake(uint assets) external view returns (uint);
    function previewRedeem(uint shares) external view returns (uint);
}

/// @title  Auxiliary System for Vogue specifically, vanilla V4
/// @notice Handles ETH/USD conversions, and batch swap clearing
/// @dev Integrates UniV3 for swaps, AAVEv3 for leverage, makes
/// incentives for migrating away from WBTC to our restaked BTC
/// as well as V3 to V4...
contract Aux is Ownable { 
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    
    // these two refer to the
    // UniswapV3 pool versions
    bool public token1isWETH;
    bool public token1isWBTC;
    // there are also two of
    // these for the V4 pools
    address[] public stables;
    Metrics public metrics;
    IERC20 USDC; Basket QUID; 
    WETH9 public WETH;
    Vogue V4; Rover V3;
    struct Metrics {
        uint total;
        uint last;
        uint yield;
    }
    struct Pod { uint shares; uint cash; }
    mapping(address => Pod) public perVault;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStable;
    mapping(address => address) public vaults;
    mapping(address => address) public underlying;
    IERC4626 public wethVault;
    IUniswapV3Pool v3PoolWETH;
    ISwapRouter v3Router; 

    uint internal _ETH_PRICE; // TODO remove
    uint internal _BTC_PRICE; // TODO remove

    // QD balances are applied to total weights
    // for voted % (weights are the balances)
    uint public deployed; uint internal K = 28; // TODO values
    uint public SUM; uint[33] public WEIGHTS;
    mapping (address => uint) public feeVotes;

    bytes4 immutable SWAP_SELECTOR;
    // ^ just for calling the Vogue

    uint internal SWAP_COST; 
    uint internal UNWIND_COST;
    uint constant WAD = 1e18;
    
    Amp public AMP;
    uint lastBlock; 
    uint deploymentBlock;
    // ^ for ASS...
    modifier onlyVogue { 
        require(msg.sender == address(V4) , "403"); _;
    }    

    /// @notice init (plug) Aux with addresses
    /// @dev optional: V3 rover & AAVE amp...
    /// @param _vogue UniV4 rover  address...
    /// @param _vault Morpho for WETH deposits 
    /// @param _v3poolWETH V3 pool 
    /// @param _v3poolWBTC V3 pool 
    /// @param _v3router V3 router for swaps
    /// @param _v3 our wrapper around UniV3
    /// @param _amp AAVE yield-amplifier...
    constructor(/// 
        address _vogue, address _vault, 
        address _amp, address _v3poolWETH, 
        address _v3poolWBTC, address _v3router, 
        address _v3, address[] memory _stables, 
        address[] memory _vaults) Ownable(msg.sender) {
        lastBlock = block.number - 1;
        deploymentBlock = lastBlock;
        v3Router = ISwapRouter(_v3router);
        v3PoolWETH = IUniswapV3Pool(_v3poolWETH);
        // v3PoolWBTC = IUniswapV3Pool(_v3poolWBTC); // TODO
        address token0 = v3PoolWETH.token0();
        address token1 = v3PoolWETH.token1();
        wethVault = IERC4626(_vault);
        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true; 
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        } V4 = Vogue(payable(_vogue)); 
        /* token0 = v3PoolWBTC.token0();
        token1 = v3PoolWBTC.token1();
        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WBTC = ;
            token1isWBTC = true; 
        } else { token1isWBTC = false;
            WBTC = WETH9(payable(token0));
        } */
        require(_stables.length == _vaults.length, "align"); 
        address stable; address vault; stables = _stables;
        for (uint i = 0; i < _vaults.length; i++) {
            stable = _stables[i]; vault = _vaults[i];
            isVault[vault] = true; vaults[stable] = vault;
            underlying[vault] = stable;
            isStable[stable] = true;
        }
        
        if (_amp != address(0))   
            AMP = Amp(payable(_amp));
        if (_v3 != address(0))   
            V3 = Rover(payable(_v3));
            
        SWAP_COST = 637000 * 2; // TODO recalculate
        // ^ gas for 1 loop iteration in V4.swap()
        UNWIND_COST = 3524821; // TODO recalculate
        // ^ gas for unwind()
        SWAP_SELECTOR = bytes4(
            keccak256("batchSwap(uint160,uint256,uint256,uint256,uint256,uint256,bool)")
        );
    } fallback() external payable {}

    /// @notice Get ETH price from sqrtPriceX96
    /// @dev Converts V3/V4 sqrt price format 
    /// @param sqrtPriceX96 Square root price 
    /// @param v3 Whether this is a V3 pool 
    /// @return price ETH price in USD 1e18
    function getPrice(uint160 sqrtPriceX96, bool v3, bool btc)
        public /*view*/ returns (uint price) {
        if (_ETH_PRICE > 0) { // TODO pure
            return _ETH_PRICE; // remove
        }
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);
        
        if (V4.token1isETH()) {
            price = FullMath.mulDiv(1 << 128,
                WAD * 1e12, ratioX128);
        } else {
            price = FullMath.mulDiv(ratioX128, 
                WAD * 1e12, 1 << 128);
        }
        _ETH_PRICE = price;
    }

    /// @notice connect QUID basket, renounce
    /// @param _quid Basket contract address
    /// @dev onlyOwner so no one can hijack 
    // the call in deployment transaction...
    function setQuid(address _quid) external onlyOwner {    
        require(address(QUID) == address(0), "QUID");
        QUID = Basket(_quid); renounceOwnership();
      
        USDC.approve(address(v3Router),
                    type(uint).max);
        WETH.approve(address(wethVault),
                    type(uint).max);
        WETH.approve(address(v3Router),
                    type(uint).max);

        if (address(AMP) != address(0)) {
            WETH.approve(address(AMP), type(uint).max);
            USDC.approve(address(AMP), type(uint).max);
        }
        if (address(V3) != address(0)) {
            WETH.approve(address(V3), type(uint).max);
            USDC.approve(address(V3), type(uint).max);
        }
    } // In order to prevent sandwich attacks, implemented 
    // simple form of ASS: process buys first, then sells!
    // Minimum trade size is a form of DoS/spam protection.
    // It's not possible to go through each swap one by one
    // and execute them in sequence, because it would cause
    // race conditons within the lock mechanism; therefore,
    // we clear the entire batch as 1 swap, looping only to
    // distribute the output pro rata (as a % of the total).
    /// @dev Routes small swaps directly, large swaps through 
    /// @param token either token we are paying or want to get
    /// @param forETH ^ for $ --> ETH, opposite for ETH --> $
    /// @param amount Amount to swap 
    /// @param waitable Max blocks to wait for clearing
    /// @return blockNumber Block when trade will clear
    function swap(address token, bool forETH, uint amount, 
        uint waitable) public payable returns (uint blockNumber) { 
        (uint160 sqrtPriceX96,,,) = V4.repack(false); bool sensitive; 
        uint price = getPrice(sqrtPriceX96, false, false); // TODO btc bool
        
        bool stable = isStable[token];
        // ^ if this is true user cares
        // about their output being all
        // in 1 specific token, so they
        // won't get multiple tokens...
        bool zeroForOne;
        if (!forETH) { // < trying to sell ETH for dollars...
            require(token == address(QUID) || stable, "$!");
            zeroForOne = V4.token1isETH() ? false : true;
            amount = _depositETH(amount);
            wethVault.deposit(amount, address(V4)); 
            sensitive = FullMath.mulDiv(amount,
                             price, WAD) >= 5000 * WAD;
            if (sensitive) 
                amount -= SWAP_COST;
        } else {
            zeroForOne = V4.token1isETH() ? true : false;
            amount = deposit(msg.sender, token, amount);
            uint scale = IERC20(token).decimals() - 6; // normalize
            amount /= scale > 0 ? 10 ** scale : 1;
            sensitive = amount >= 500 * 1e6; 
            if (sensitive) // < park the ETH for gas comp...
                wethVault.deposit(_depositETH(0), address(V4)); 
        } 
        if (sensitive) { // subsidise gas cost...
            require(msg.value >= SWAP_COST, "gas");
            // entering into protected clearing
            // pipeline: no sandwiches, slower
            Types.Trade memory current;
            current.sender = msg.sender;
            current.token = token;        
            current.amount = amount;
            blockNumber = V4.pushSwap(zeroForOne, // TODO btc
                                current, waitable, false);
        } else { blockNumber = block.number;
            // Executes instantly, no batching, 
            // no sandwich protection...cheaper, 
            // reliably scalable...suitable for: 
            // small trades, routine flow, etc.
            V4.swap(sqrtPriceX96, msg.sender, // TODO btc
                    zeroForOne, token, amount, false);
        } 
    }

    /// @notice Public function to trigger batch clearing
    /// @dev Anyone can call to process pending swaps 
    function clearSwaps(/* uint nft */) external { 
        // TODO clear against a specific segment 
        // in total liquidity, priority fee cut
        (uint160 sqrtPriceX96, int24 tickLower, 
        int24 tickUpper, uint128 myLiquidity) = V4.repack(false);
        uint price = getPrice(sqrtPriceX96, false, false);
        _clearSwaps(sqrtPriceX96, price);
    }

    /// @notice Internal ASS clearing logic 
    /// @dev Processes buys first, then sells 
    /// @param sqrtPriceX96 Current pool price
    /// @param price ETH price from UniswapV3...
    function _clearSwaps( // process recent batch
    // TODO BTC to USD as distinct from ETH to USD
    // add v4.takeBTC and attach v3pool for WBTC...
        uint160 sqrtPriceX96, uint price) internal {
        uint currentBlock = block.number;
        uint startBlock = lastBlock + 1;
        if (startBlock >= currentBlock)
            return;
        
        uint endBlock = currentBlock - 1;
        if (endBlock > startBlock + 9) 
            endBlock = startBlock + 9;
        
        uint gotForETH; uint gotForUSD;
        uint swaps; uint value; uint remains; 
        bool v3 = address(V3) != address(0);
        // ^ optional (depends on deployment
        uint splitForUSD; uint splitForETH;
        for (uint blockToProcess = startBlock;
            blockToProcess <= endBlock; blockToProcess++) {
            (Types.Batch memory forUSD, 
            Types.Batch memory forETH) = V4.getSwapsETH(blockToProcess);
            uint pooled_usd = V4.ETH_POOLED_USD();
            uint pooled_eth = V4.ETH_POOLED();
            pooled_usd *= 1e12;
            if (forUSD.total > 0) { // selling ETH for USD
            // ^ amount in ETH 1e18
                swaps += SWAP_COST * forUSD.swaps.length;
                // dollar value of total ETH to sell...
                value = FullMath.mulDiv(
                forUSD.total, price, WAD);
                if (value > pooled_usd) { // V4 alone
                // can't handle batch's entire value
                    remains = value - pooled_usd;
                    splitForUSD = FullMath.mulDiv(
                            remains, WAD, price);
                    // since the ETH for the swap was
                    // entered into the wethVault via
                    // swap() in this contract, the 
                    // amount should be available...
                    value = V4.takeETH(splitForUSD);
                    // this amount gets placed in
                    // V3 in exchange for drawing $
                    if (v3) { // slippage is double
                    // compared to a direct swap of
                    // WETH for USDC (one step)...
                    // but slippage is absorbed by
                    // the V3 LPs rather than the 
                    // originators of the V4 batch
                        gotForETH = V3.withdrawUSDC(remains / 1e12);
                        remains -= gotForETH * 1e12;
                        uint eth = FullMath.mulDiv(WAD * 1e12, 
                                            gotForETH, price);
                        V3.deposit(eth);
                        value -= eth;
                    } 
                    if (!v3 || remains > 0) {
                        WETH.deposit{value: value}();
                        gotForETH += _getUSDC(value, 
                        (remains - (remains / 100)) / 1e12);
                    }
                    if (gotForETH > 0) {
                        address vault = vaults[address(USDC)];
                        USDC.approve(vault, gotForETH);
                        uint shares = IERC4626(vault).deposit(gotForETH, address(this));
                        perVault[vault].shares += shares;
                        perVault[vault].cash += gotForETH;
                    }
                } 
            } // buying ETH for $...
            if (forETH.total > 0) { // total in $ (1e6)
                swaps += SWAP_COST * forETH.swaps.length;
                // total ETH this batch is trying to buy
                value = FullMath.mulDiv(forETH.total, 
                                WAD * 1e12, price);
                if (value > pooled_eth) { // V4 alone
                // can't handle the whole swap batch
                    value -= pooled_eth;
                    remains = forETH.total - FullMath.mulDiv(
                            pooled_eth, price, WAD * 1e12);
                    // dollars for swaps were placed
                    // into the basket through swap()
                    // but USDC may not necessarily
                    // be available to fully cover
                    splitForETH = _take(address(this), 
                        remains, address(USDC), true);
                    if (v3) {
                        uint eth = V3.take(value);
                        uint usd = FullMath.mulDiv(
                            eth, price, WAD * 1e12);
                        V3.depositUSDC(usd, price);
                        splitForETH -= usd;
                        gotForUSD += eth; 
                        value -= eth;
                    }
                    if (!v3 || splitForETH > 0)
                        gotForUSD += _getWETH(splitForETH, 
                                    value - value / 100);
                    
                    wethVault.deposit(gotForUSD, address(V4));
                }
            } if (swaps > 0) {    
                bytes memory payload = abi.encodeWithSelector(
                    SWAP_SELECTOR, sqrtPriceX96, blockToProcess,
                    splitForUSD, splitForETH, 
                    gotForETH, gotForUSD, false); // TODO btc
                    // NOTE our order here

                uint forGas = V4.takeETH(swaps); 
                // because the way we do this low-level call, our swap 
                // has to be AUX (not rover, would otherwise make sense)
                (bool success,) = address(V4).call
                {gas: forGas + gasleft()}(payload);
            } 
        }
        lastBlock = endBlock;
    } 
    
    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable external {
        require(address(AMP) != address(0) 
            && msg.value >= UNWIND_COST);
            amount = _depositETH(amount); 
            amount -= UNWIND_COST;
        
        (uint160 sqrtPriceX96,,,,,,) = v3PoolWETH.slot0();
        uint price = getPrice(sqrtPriceX96, true, false);
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        uint took = _take(address(this),
            totalValue / 1e12, address(USDC), false); 
      
        if (totalValue / 1e12 > took + 1) {
            uint needed = totalValue / 1e12 - took;
            uint selling = FullMath.mulDiv(needed, 
                                WAD * 1e12, price);
           // require(V4.unpend(selling) == selling); // TODO
            selling = V4.takeETH(selling);
            WETH.deposit{value: selling}();
            took += _getUSDC(selling, 
                needed - needed / 200);
                     amount -= selling;
        } 
        AMP.leverETH(msg.sender, amount, took);
    } // swap originator gets paid eventually...

    /// @notice leveraged short (borrow USDC against WETH)
    /// @param amount Stablecoin amount to deposit
    /// @param token Stablecoin token address
    function leverUSD(uint amount, 
        address token) payable external {
        require(address(AMP) != address(0) 
            && msg.value >= UNWIND_COST);
    
        wethVault.deposit(_depositETH(0), address(V4));
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        (uint160 sqrtPriceX96,,,,,,) = v3PoolWETH.slot0();
        uint price = getPrice(sqrtPriceX96, true, false); // TODO btc dynamic
        uint scaled = 18 - IERC20(token).decimals();
        scaled = scaled > 0 ? amount * (10 ** scaled) : amount;
        uint inETH = FullMath.mulDiv(WAD,
                        scaled, price);

        inETH = V4.takeETH(inETH);
        WETH.deposit{value: inETH}();
        AMP.leverUSD(msg.sender,
                 amount, inETH);
    } 
    
    // function future yield of dollars on ETH trading
    // from people taking profits is guaranteed to backstop
    // any possible downfall of BTC in the EigenLayer pool
    // making re-staking using bonds the best way to make
    // economic security a bootstrapped game theoretically

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount) external {
    // when it comes to the AUX plug, life is
        amount = QUID.turn(msg.sender, amount);
        // all about waiting for your turn...
        if (amount > 0) {
            (uint total, ) = get_metrics(false);
            // uint pooled_usd = V4.ETH_POOLED_USD();
            // if (amount > total - pooled_usd) 
                // TODO shrink the liquidity pool
            amount -= _take(msg.sender, amount, 
                        address(QUID), false);
        }        
    } 

    function get_metrics(bool force) 
        public returns (uint, uint) {
        Metrics memory stats = metrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            uint[10] memory amounts = get_deposits();
            stats.last = block.timestamp;
            stats.total = amounts[0];
            if (stats.total > 0)
                stats.yield = FullMath.mulDiv(WAD,
                amounts[9], amounts[0] - amounts[8]) - WAD;
            metrics = stats;
        } return (stats.total, stats.yield);
    }

    function collect() external { // just pack a bag'n'GHO
        address vault = vaults[stables[stables.length-1]];
        IStakeToken(vault).claimRewards(
            Vogue(V4).owner(), type(uint).max);
    }

    function get_deposits() public view
        returns (uint[10] memory amounts) {
        address vault; uint shares;
        uint ghoIndex = stables.length - 1;
        for (uint i = 0; i < ghoIndex; i++) { 
            uint multiplier = i < 2 ? 1e12 : 1;
            vault = vaults[stables[i]];
            shares = perVault[vault].shares;
            if (shares > 0) {
                uint assets = IERC4626(vault).convertToAssets(shares);
                shares = assets * multiplier; amounts[i + 1] = shares; 
                amounts[0] += shares; 
                if (IERC4626(vault).totalSupply() > 0) {
                    amounts[9] += FullMath.mulDiv(shares,
                        IERC4626(vault).totalAssets() * multiplier,
                        IERC4626(vault).totalSupply());
                }
            }
        } vault = vaults[stables[stables.length - 1]];
        if (IStakeToken(vault).balanceOf(address(this)) > 0) {
            shares = IStakeToken(vault).previewRedeem(
                     IStakeToken(vault).balanceOf(address(this)));
            amounts[stables.length] = shares;
            amounts[0] += shares;
        }
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination: whatever's in there, yours to take
    function _take(address who, uint amount, address token, 
        bool strict) internal returns (uint sent) { address vault;
        if (token != address(QUID)) { vault = vaults[token];
            uint max = perVault[vault].cash;
            require(max > 0, "No liquidity");
            
            uint fee = 0;
            // uint fee = getFee(token, false, amount); NOTE
            if (fee > WAD / 10) fee = WAD / 10; // TODO some cap
            
            uint amountNeeded;
            if (fee > 0)
                amountNeeded = FullMath.mulDiv(
                          amount, WAD + 0, WAD);
            else amountNeeded = amount; 
            if (max >= amount) {
                uint withdrawn = _withdraw(who, vault, amount);
                if (fee > 0) return FullMath.mulDiv(
                          withdrawn, WAD - fee, WAD);
                else return withdrawn;
            } else { uint withdrawn = _withdraw(who, vault, max);
                if (fee > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - fee, WAD);
                else sent = withdrawn;
                amount -= withdrawn;
                if (!strict) {
                    sent = BasketLib.scaleTokenAmount(sent, token, true);
                    amount = BasketLib.scaleTokenAmount(amount, token, true);
                } else return sent; 
            }
        } uint[10] memory amounts = get_deposits(); 
        uint ghoIndex = stables.length; sent = 0;
        for (uint i = 1; i < ghoIndex; i++) {
            uint divisor = (i - 1) > 1 ? 1 : 1e12;
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                WAD, amounts[i], amounts[0]), WAD);
        
            amounts[i] /= divisor;
            if (amounts[i] > 0) { vault = vaults[stables[i - 1]];
                amounts[i] = _withdraw(who, vault, amounts[i]);
                sent += amounts[i] * divisor;
            }
        } vault = vaults[stables[stables.length - 1]];
        amounts[ghoIndex] = FullMath.mulDiv(amount, FullMath.mulDiv(
                            WAD, amounts[ghoIndex], amounts[0]), WAD);
                            
        if (amounts[ghoIndex] > 0) {
            amount = IStakeToken(vault).previewStake(amounts[ghoIndex]);
            require(IStakeToken(vault).previewRedeem(amount) == amounts[ghoIndex], "sgho");
            IStakeToken(vault).redeem(who, amount); sent += amounts[ghoIndex];
        }
    }

    function take(address who, uint amount, address token, bool strict) 
        public onlyVogue returns (uint) { return _take(
                            who, amount, token, strict);
    }

    function _withdraw(address to, // sent is 1e16 for USDC & USDT
        address vault, uint amount) internal returns (uint sent) {
        (uint shares, uint assets) = BasketLib.calculateVaultWithdrawal(
                                                          vault, amount);
        require(assets == IERC4626(vault).redeem(shares, 
                to, address(this)), "$"); return assets;
    }

    // there's never an incentive
    // for EOAs to call this since
    // mint() is the only way to
    // get yield for a deposit...
    // so it's assumed only our 
    // contracts will call this
    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        address GHO = stables[stables.length - 1];
        address SGHO = vaults[GHO]; address vault;
        if (isVault[token] && token != SGHO) { 
            amount = Math.min(
                IERC4626(token).allowance(from, address(this)),
                 IERC4626(token).convertToShares(amount));
            usd = IERC4626(token).convertToAssets(amount);
                   IERC4626(token).transferFrom(msg.sender,
                                    address(this), amount);
            
            perVault[token].shares += amount; 
            perVault[token].cash += usd;
        }    
        else if (isStable[token] || token == SGHO) {
            usd = Math.min(amount, 
            IERC20(token).allowance(
                from, address(this)));
            IERC20(token).transferFrom(
                from, address(this), usd);
            if (token == GHO) { vault = SGHO;
                IERC20(token).approve(vault, usd);
                amount = IStakeToken(vault).previewStake(usd);
                IStakeToken(vault).stake(address(this), usd);
            } 
            else if (token != SGHO) { 
                vault = vaults[token];
                IERC20(token).approve(vault, usd);
                amount = IERC4626(vault).deposit(usd, 
                                    address(this));
            } 
            perVault[vault].shares += amount;
            perVault[vault].cash += usd;
        } else {
            require(false, "unsupported token");
        } require(usd > 0, "deposited nothing");
    }

    /*
    function vote(uint new_vote) external {
        uint old_vote = feeVotes[msg.sender];
        old_vote = old_vote == 0 ? 28 : old_vote;
        require(new_vote != old_vote &&
                new_vote < 33, "bad vote");
        uint stake = totalBalances[msg.sender];
        feeVotes[msg.sender] = new_vote;
        _calculateMedian(stake, old_vote,
                         stake, new_vote);
    } */

    /** https://x.com/QuidMint/status/1833820062714601782
     *  Find value of k in range(0, len(Weights)) such that
     *  sum(Weights[0:k]) = sum(Weights[k:len(Weights)+1]) = sum(Weights) / 2
     *  If there is no such value of k, there must be a value of k
     *  in the same range range(0, len(Weights)) such that
     *  sum(Weights[0:k]) > sum(Weights) / 2
     */ 
    /* function _calculateMedian( // for fee
        uint old_stake, uint old_vote,
        uint new_stake, uint new_vote) internal {
        if (old_vote != 28 && old_stake != 0) {
            WEIGHTS[old_vote] -= FullMath.min(
                WEIGHTS[old_vote], old_stake);
            if (old_vote <= K) { 
                SUM -= FullMath.min(SUM, old_stake); 
            }
        }   
        if (new_stake != 0) { 
            if (new_vote <= K) {
                SUM += new_stake; 
            }
            WEIGHTS[new_vote] += new_stake; 
        }
        uint mid = SUM / 2; 
        if (mid != 0) {
            if (K > new_vote) {
                while (K >= 1 && 
                    ((SUM - WEIGHTS[K]) >= mid)) { 
                        SUM -= WEIGHTS[K]; 
                        K -= 1;
                    }
            } else { 
                while (SUM < mid) { 
                    K += 1;
                    SUM += WEIGHTS[K]; 
                }
            } 
        } else { 
            K = new_vote;
            SUM = new_stake;
        } // TODO
        // set the allocation
    } */

    /// @notice Test function to manually set ETH price
    /// @dev TODO: Remove for production
    /// @param up True to increase price, false to decrease
    // TODO remove (for testing purposes only)
    function set_price_eth(bool up) external {
        uint _price = getPrice(0, true, false);
        uint delta = _price / 20;
        _ETH_PRICE = up ? _price + delta:
                          _price - delta;
    } 

    /// @notice Swap WETH for USDC via V3
    /// @param howMuch WETH amount to swap
    /// @param minExpected Minimum USDC expected (slippage protection)
    /// @return Amount of USDC received
    function _getUSDC(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(WETH), uint24(500), address(USDC)),
            address(this), block.timestamp, howMuch, minExpected));
    }

    /// @notice Swap USDC for WETH via V3
    /// @param howMuch USDC amount to swap
    /// @param minExpected Minimum WETH expected (slippage protection)
    /// @return Amount of WETH received
    function _getWETH(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(USDC), uint24(500), address(WETH)),
            address(this), block.timestamp, howMuch, minExpected));
    }   
    
    /// @notice Deposit ETH/WETH from user
    /// @param amount WETH amount to transfer
    /// @return Total amount including msg.value
    function _depositETH(uint amount) internal returns (uint) {
        if (amount > 0) { WETH.transferFrom(msg.sender,
                            address(this), amount);
        } if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            amount += msg.value;
        }   return amount;  
    } 
}
