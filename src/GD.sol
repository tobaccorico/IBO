
// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4 <0.9.0;
import "lib/forge-std/src/console.sol"; // TODO delete logging before mainnet
import {MorphoBalancesLib} from "./imports/morpho/libraries/MorphoBalancesLib.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {AggregatorV3Interface} from "./imports/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "./imports/morpho/IMorpho.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {ERC6909} from "lib/solmate/src/tokens/ERC6909.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {FullMath} from "./imports/math/FullMath.sol";
import "./imports/SortedSet.sol";

interface IStakeToken is IERC20 { // StkGHO (safety module)
    function stake(address to, uint256 amount) external;
    // here the amount is in underlying, not in shares...
    function redeem(address to, uint256 amount) external;
    // the amount param is in shares, not underlying...
    function previewStake(uint256 assets) 
             external view returns (uint256);
    function previewRedeem(uint256 shares) 
             external view returns (uint256);
}

import {MO} from  "./Mindwill.sol"; 
contract Good is ERC6909, ReentrancyGuard { 
    address payable public Mindwill;
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;
    using SortedSetLib for SortedSetLib.Set;
    
    uint public ROI; uint public START;
    Pod[43][24] Piscine; // 24 batches
    
    uint constant PENNY = 1e16;
    bytes32 public immutable ID; // Morph
    
    uint constant public DAYS = 42 days;
    uint public START_PRICE = 50 * PENNY;
    
    struct Pod { uint credit; uint debit; }
    
    mapping(address => Pod) public perVault;
    mapping(address => address) public vaults;
    
    mapping(address => uint) public totalBalances;
    mapping(address => SortedSetLib.Set) private perBatch;
    
    mapping(uint256 id => uint256 amount) public totalSupplies;
    mapping(address account => mapping(// legacy ERC20 version
            address spender => uint256)) private _allowances;
    
    mapping(address => bool[24]) public hasVoted;
    // voted for enum as what was voted on, and
    // token-holders vote for deductibles, their
    // GD balances are applied to total weights
    // for voted % (weights are the balances)
    uint public deployed; uint internal K = 28;
    uint public SUM; uint[33] public WEIGHTS;
    mapping (address => uint) public feeVotes;
    
    address[][24] public voters; // by batch
    mapping (address => bool) public winners;
    // ^ the mapping prevents duplicates...

    address public immutable SCRVUSD;
    address public immutable CRVUSD;
   
    address public immutable SFRAX;
    address public immutable FRAX;

    address public immutable SUSDE;
    address public immutable USDE;

    address public immutable SUSDS;
    address public immutable USDS;
    
    address public immutable SGHO;
    address public immutable GHO;
    
    address public immutable SDAI;
    address public immutable DAI;
    
    address public immutable USDC;
    address public immutable USDT;
    
    uint constant WAD = 1e18;
    uint private _totalSupply;
    string private _name = "QU!D";
    string private _symbol = "GD";
    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == Mindwill ||
                sender == address(this), "!?"); _;
    }
    constructor(address _mo,  
        address _vaultUSDC, address _usdt,
        address _vaultUSDT, bytes32 _morpho,
        address _usde, address _susde, 
        address _frax, address _sfrax,
        address _sdai, address _dai,
        address _usds, address _susds,
        address _crv, address _scrv,
        address _gho, address _sgho) {
        ID = _morpho; Mindwill = payable(_mo); 
        START = block.timestamp; deployed = START;
        
        USDC = address(MO(Mindwill).token0()); vaults[USDC] = _vaultUSDC;
        ERC20(USDC).approve(_vaultUSDC, type(uint).max);
        
        USDT = _usdt;vaults[USDT] = _vaultUSDT;
        ERC20(USDT).approve(_vaultUSDT, type(uint).max);
        
        SGHO = _sgho; GHO = _gho; // vault isn't 4626
        ERC20(GHO).approve(SGHO, type(uint).max);
        
        SDAI = _sdai; DAI = _dai; vaults[DAI] = SDAI;
        ERC20(DAI).approve(MORPHO, type(uint).max);
        ERC20(DAI).approve(SDAI, type(uint).max);
        
        SUSDS = _susds; USDS = _usds; vaults[USDS] = SUSDS;
        ERC20(USDS).approve(SUSDS, type(uint).max);
        
        SFRAX = _sfrax; FRAX = _frax; vaults[FRAX] = SFRAX; 
        ERC20(FRAX).approve(SFRAX,  type(uint).max);
        
        SUSDE = _susde; USDE = _usde; vaults[USDE] = SUSDE;
        ERC4626(SUSDE).approve(MORPHO, type(uint).max);
        ERC20(USDE).approve(SUSDE, type(uint).max);
        
        SCRVUSD = _scrv; CRVUSD = _crv; vaults[CRVUSD] = SCRVUSD;
        ERC20(CRVUSD).approve(SCRVUSD, type(uint).max);
    } 
    uint constant GRIEVANCES = 113310303333333333333333;
    uint constant CUT = 4920121799152111; // over 3yr
    uint constant KICKBACK = 666666666666666666666666;
    uint constant public MAX_PER_DAY = 777_777 * WAD;
    
    function get_total_deposits
        (bool usdc) public view
        // this is only *part* of the captalisation()
        returns (uint total) { // handle USDC first
       
        total += usdc ? ERC4626(vaults[USDC]).maxWithdraw(
                                 address(this)) * 1e12 : 0;

        // includes collateral deployed in Morpho,
        // as Pod.credit, initially only for SUSDE;
        // can be multiple markets just in case...
        // TODO perhaps don't take .credit at face value
        // because while in custody by Morpho it does not
        // generate interest, thus shouldn't be valued as
        // interest bearing, the way that .debit held by
        // our contract is getting valued (covertToAssets)
       
        total += ERC4626(vaults[USDT]).maxWithdraw(
                        address(this)) * 1e12;
   
        total += IStakeToken(SGHO).previewRedeem(
        IStakeToken(SGHO).balanceOf(address(this)));
        address vault; uint shares;
        address[5] memory tokens = [
            DAI, USDS, USDE, CRVUSD, FRAX
        ];  
        for (uint i = 0; i < 5; i++) { 
            vault = vaults[tokens[i]]; // credit means the assets are 
            // encumbered as collateral in a Morpho market, or borrowed
            shares = perVault[vault].debit + perVault[vault].credit;
            if (shares > 0) {
                total += ERC4626(vault).convertToAssets(shares);
            }
        }
    }
    function _deposit(address from,
        address token, uint amount)
        internal returns (uint usd) {
        bool isDollar = false; 
        if (token == SCRVUSD || token == SFRAX || 
            token == SUSDS || token == SDAI || 
            token == SUSDE) { isDollar = true;
    
            amount = FullMath.min(
                ERC4626(token).allowance(from, address(this)),
                 ERC4626(token).convertToShares(amount));
            usd = ERC4626(token).convertToAssets(amount);
                   ERC4626(token).transferFrom(msg.sender,
                                    address(this), amount);
        
            perVault[token].debit += amount;
        }    
        else if (token == DAI  || token == USDS ||
                 token == USDC || token == FRAX ||
                 token == USDT || token == GHO  ||
                 token == USDE || token == SGHO ||
                 token == CRVUSD ) { isDollar = true; 
                 usd = FullMath.min(amount, 
                    ERC20(token).allowance(
                        from, address(this)));
                    
                    address vault = vaults[token];
                    ERC20(token).transferFrom(
                     from, address(this), usd);
     
                    if (token == GHO) {
                        amount = IStakeToken(SGHO).previewStake(usd);
                        IStakeToken(SGHO).stake(address(this), usd);
                    } else if (token != SGHO) { 
                        amount = ERC4626(vault).deposit(usd, 
                                            address(this));
                    } 
                    perVault[vault].debit += amount;
        } 
        require(isDollar && amount > 0, "$");
    }

    function approve(address spender, 
        uint256 value) public returns (bool) {
        require(spender != address(0), "invalid spender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    // takes $ amount input in units of 1e18...
    function withdrawUSDC(uint amount) public
        onlyUs returns (uint withdrawn) {
        if (amount > 0) { 
            address vault = vaults[USDC];
             withdrawn = FullMath.min(
                amount / 1e12, 
                ERC4626(vault).maxWithdraw(
                            address(this)));

            if (withdrawn > 0) {
                ERC4626(vault).withdraw(withdrawn, 
                    Mindwill, address(this)); 
            }
        } else { return 0; }
    }

    function gd_amt_to_dollar_amt(uint gd_amt) public
        view returns (uint amount) { uint in_days = (
            (block.timestamp - START) / 1 days
        );  amount = FullMath.mulDiv((in_days * 
            PENNY + START_PRICE), gd_amt, WAD);
    } // get the current ^^^^ to mint() GD...
    function get_total_supply_cap()
        public view returns (uint) {
        uint batch = currentBatch();
        uint in_days = ( // used in frontend...
            (block.timestamp - START) / 1 days
        ) + 1; return in_days * MAX_PER_DAY -
                 Piscine[batch][42].credit;
    }
   
    function reachUp()
        public nonReentrant {
        if (block.timestamp > // 45d
            START + DAYS + 3 days) {
            // uint keep = GRIEVANCES;
            // this.morph(QUID, keep);
            _reachUp(currentBatch(), 
                QUID, KICKBACK);
        } // 16M GD over 24... 
    } 
    function _reachUp(uint batch, 
        address to, uint cut) internal {
        batch = FullMath.min(1, batch);
        
        _mint(to, batch, cut);
        START = block.timestamp; // right now
        
        Pod memory day = Piscine[batch - 1][42];
        // ROI aggregates all batches' days...
        ROI += FullMath.mulDiv(WAD, day.credit - 
                         day.debit, day.debit);
        // ROI in MO is snapshot (avg. per day)
        MO(Mindwill).setMetrics(ROI / ((DAYS 
                     / 1 days) * batch)); 
    }
    
    /**
     * @dev Returns the current reading of our internal clock.
     */
    function currentBatch() public view returns
        (uint batch) { batch = (block.timestamp - 
                        deployed) / DAYS;
    } 
    /**
     * @dev Returns the name of our token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of our token.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Tokens usually opt for a value of 18, 
     * imitating the relationship between Ether and Wei. 
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {ERC20-totalSupply}.
     */
    function totalSupply() public 
        view returns (uint) {
        return _totalSupply;
    }

    function _til(uint when) 
        internal view returns (uint til) {
        uint current = currentBatch();
        if (when == 0) { 
            til = current + 1;
        } else { // cannot project 
            // into the past, or...
            til = FullMath.max(when,
                        current + 1);
            // any more than 4 years 
            // "into the future...
            til = FullMath.min(when, 
                        current + 33);
        } // time keeps on slippin'"
    }
    
    function matureBatches(uint[] memory batches)
        public view returns (uint i) { 
        for (i = batches.length; i > 0; --i) {
            if (batches[i] <= currentBatch()) 
                break;
        }
    } 

    // TODO revise
    function matureBatches() // 0 is 1yr...
        public view returns (uint) { // in 3
        uint batch = currentBatch(); // 1-33
        if (batch < 8) { return 0; } 
        else { return batch - 8; } 
    } 
    function matureBalanceOf(address account)
        public view returns (uint total) {
        uint batches = matureBatches();
        for (uint i = 0; i < batches; i++) 
            total += balanceOf[account][i]; 
    } // redeeming matured GD calls turn() from MO
   
    function turn(address from, // whose balance
        uint value) public 
        onlyUs returns (uint) {
        uint oldBalanceFrom = totalBalances[from];
        uint sent = _transferHelper(
        from, address(0), value);
        // carry.debit will be untouched here...
        return MO(Mindwill).transferHelper(from,
            address(0), sent, oldBalanceFrom);
    }

    // eventually a balance may be spread
    // over enough batches that this will
    // run out of gas, so there will be
    // no choice other than to use the 
    // more granular version of transfer
    function _transferHelper(address from, 
        address to, uint amount) 
        internal returns (uint sent) {
        // must be int or tx reverts when we go below 0 in loop
        uint[] memory batches = perBatch[from].getSortedSet();
        // if i = 0 then this will either give us one iteration,
        // or exit with index out of bounds, both make sense...
        bool toZero = to == address(0);
        bool burning = toZero || to == Mindwill;
        int i = toZero ? 
            int(matureBatches(batches)) :
            int(batches.length - 1);
            // if length is zero this
            // may cause error code 11
            // which is totally legal
        while (amount > 0 && i >= 0) { 
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) { 
                amt = FullMath.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!burning) {
                    perBatch[to].insert(k);
                    balanceOf[to][k] += amt;
                } else {
                    totalSupplies[k] -= sent;
                }
                if (balanceOf[from][k] == 0) {
                    perBatch[from].remove(k);
                }
                amount -= amt; 
                sent += amt;
            }   i -= 1; 
        } 
        totalBalances[from] -= sent;
        if (burning) {
            _totalSupply -= sent;
        } else {
            totalBalances[to] += sent;
        }
    }

    /**
     * @dev A transfer which doesn't specifying the 
     * batch will proceed backwards from most recent
     * to oldest batch until the transfer amount is 
     * fulfilled entirely. Tokenholders that desire 
     * a more granular result should use the other
     * transfer function (we do not override 6909)
     */
    function _transfer(address from, address to,
        uint amount) internal returns (bool) {
        uint senderVote = feeVotes[from];
        // ^ this variable allows us to only
        // read from storage once to save gas
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(
                from, to, amount);
        
        uint sent = MO(Mindwill).transferHelper(
             from, to, value, oldBalanceFrom);
        
        if (value != sent) { // this is only for
        // the situation where to == address(MO): 
        // burning debt, and in the case where we 
        // tried to burn more than was available
            value -= sent; // value is now excess
            // which is the amount we can't burn;
            // _transfeHelper displaced the entire 
            // value from various maturities, to 
            // undo this perfectly would be too much
            // work, so we just mint delta as current 
            _mint(from, currentBatch() + 2, value);
            value = sent; // mint increases supply
        } 
        _calculateMedian(oldBalanceFrom, senderVote, 
                 oldBalanceFrom - value, senderVote);
        // rebalace the median with updated stake...
        if (to != address(0)) {
            uint receiverVote = feeVotes[to];
            _calculateMedian(oldBalanceTo, receiverVote, 
                     oldBalanceTo + value, receiverVote);
        } return true;
    }

    function transfer(address to, // receiver
        uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, 
        address to, uint amount) public 
        returns (bool) {
        if (msg.sender != from 
            && !isOperator[from][msg.sender]) {
            if (to == Mindwill) {
                require(msg.sender == Mindwill, "403");
            }    
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount);
    }

    function vote(uint new_vote/*, caps*/) external {
        uint batch = currentBatch(); // 0-24
        if (batch < 24 && !hasVoted[msg.sender][batch]) {
            (uint carry,) = MO(Mindwill).get_info(msg.sender);
            if (carry > GRIEVANCES / 10) { 
                hasVoted[msg.sender][batch] = true;
                voters[batch].push(msg.sender); 
            }
        } uint old_vote = feeVotes[msg.sender];
        old_vote = old_vote == 0 ? 28 : old_vote;
        require(new_vote != old_vote &&
                new_vote < 33, "bad vote");
        uint stake = totalBalances[msg.sender];
        feeVotes[msg.sender] = new_vote;
        _calculateMedian(stake, old_vote,
                         stake, new_vote);
    }
    /** https://x.com/QuidMint/status/1833820062714601782
     *  Find value of k in range(0, len(Weights)) such that
     *  sum(Weights[0:k]) = sum(Weights[k:len(Weights)+1]) = sum(Weights) / 2
     *  If there is no such value of k, there must be a value of k
     *  in the same range range(0, len(Weights)) such that
     *  sum(Weights[0:k]) > sum(Weights) / 2
     */ 
    function _calculateMedian(// for fee
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
        } 
        MO(Mindwill).setFee(K);
    }
    
    function _mint(address receiver,
        uint256 id, uint256 amount
    ) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount; 
        perBatch[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;
        
        emit Transfer(msg.sender, 
            address(0), receiver,
            id, amount);
    }
    
    // systematic uncertainty + unsystematic = total
    // demand uncertainty. typically systematic will
    // dominate unsystematic. in my experience, the 
    // 2 tend to break according to pareto principle
    function mint(address pledge, uint amount, 
        address token, uint when) 
        public nonReentrant { 
        uint batch = _til(when);
        if (token == address(this)) {
            require(msg.sender == Mindwill, "403");
            _mint(pledge, batch, amount);
        }   else if (block.timestamp <= START + DAYS) { 
                uint in_days = ((block.timestamp - START) / 1 days);
                require(amount >= WAD * 10 && (in_days + 1)
                    * MAX_PER_DAY >= Piscine[batch][42].credit 
                    + amount, "cap"); uint price = in_days * 
                                        PENNY + START_PRICE;  
                uint cost = FullMath.mulDiv( // to mint GD
                        price, amount, WAD); _deposit(
                                pledge, token, cost);
                _mint(pledge,
                batch, amount);

                MO(Mindwill).mint(pledge, cost, amount);
                Piscine[batch][in_days].credit += amount;
                Piscine[batch][in_days].debit += cost;
                // 43rd row is the total for the batch
                Piscine[batch][42].credit += amount;
                Piscine[batch][42].debit += cost; 
            }
        }
        address public constant QUID = 0x42cc020Ef5e9681364ABB5aba26F39626F1874A4;
      address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
   
    function morph(address to, uint amount) 
        public onlyUs returns (uint sent) {
        bool l2 = MO(Mindwill).token1isWETH();
        uint total = get_total_deposits(false);
        // this total function accounts for both
        // perVault.debit and perVault.credit as
        // part of what makes up capitalisation,
        // but...credit cannot be withdrawn, so
        // we have to count twice; second time
        // being in the 1st for loop of morph() 
        // in order to get amounts debit-able
        if (msg.sender == address(this)) {    
            // get batch which just ended
            uint batch = currentBatch() - 1;
            uint raised = Piscine[batch][42].debit;
            uint cut = FullMath.mulDiv(raised, CUT, WAD); 
            amount = FullMath.min(amount, cut);
            Piscine[batch][42].debit -= amount;
        } require(amount > 0, "no thing");
        uint inDollars; address vault; uint i; // for loop
        uint[7] memory amounts; address[7] memory tokens; 
        uint sharesWithdrawn; address repay = SDAI; // <- tokens borrowed 
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(ID);
        (uint delta, uint cap) = MO(Mindwill).capitalisation(0, false);
        uint borrowed = MorphoBalancesLib.expectedBorrowAssets(
                        // on L2 this is USDC, on L1 it's DAI...
                        IMorpho(MORPHO), params, address(this));  
            tokens = [DAI, USDS, USDE, CRVUSD, USDT, FRAX, GHO];

        uint collat; // hardcoded ^^ to one, but it can be changed... 
        // because the following for loop is compatible with any token,
        // or even multiple, to pledge as collateral in morpho market
        for (i = 0; i < 6; i++) { vault = vaults[tokens[i]];
        // effectively, maxWithdraw() should give us the same as
        // ERC4626(vault).convertToAssets(perVault[vault].debit)
            amounts[i] = ERC4626(vault).maxWithdraw(address(this));
        }   amounts[6] = IStakeToken(SGHO).previewRedeem(
                IStakeToken(SGHO).balanceOf(address(this)));

        inDollars = FullMath.min(delta + delta / 9, amounts[2]);
        // ^ the most that we can pledge as collateral in Morpho
        collat = ERC4626(SUSDE).convertToShares(inDollars); 
        if (collat > 0 && delta > 0 && inDollars > delta) {
            IMorpho(MORPHO).supplyCollateral(
            params, collat, address(this), "");
            perVault[SUSDE].debit -= collat;
            perVault[SUSDE].credit += collat; 
            (borrowed,) = IMorpho(MORPHO).borrow(params, collat, 0,
                                    address(this), address(this));

            perVault[repay].credit += ERC4626(repay).deposit( 
                                     borrowed, address(this));
        }
        else if (borrowed > 0 && cap == 100) { 
            delta = delta > perVault[repay].credit ? 
                            perVault[repay].credit : delta;

            delta = FullMath.min(borrowed, delta);
            (sharesWithdrawn,) = IMorpho(MORPHO).repay(params, 
                ERC4626(repay).withdraw(delta, address(this), 
                address(this)), 0, address(this), "");

            perVault[repay].credit -= sharesWithdrawn;
            inDollars = ERC4626(repay).convertToAssets(
                                        sharesWithdrawn);

            collat = FullMath.min(collat,
            ERC4626(SUSDE).convertToShares(inDollars));

            IMorpho(MORPHO).withdrawCollateral(params, 
                collat, address(this), address(this));

            perVault[SUSDE].credit -= collat;
            perVault[SUSDE].debit += collat;
        }
        else if (borrowed == 0 && perVault[SUSDE].credit > 0) {
            IMorpho(MORPHO).withdrawCollateral(params,
            perVault[SUSDE].credit, address(this), address(this));
            perVault[SUSDE].debit += perVault[SUSDE].credit;
            perVault[SUSDE].credit = 0;
        }
        for (i = 0; i < 5; i++) { 
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                    WAD, amounts[i], total), WAD);
            if (tokens[i] == USDT) {
                amounts[i] /= 1e12;
            }
            if (amounts[i] > 0) { 
                vault = vaults[tokens[i]]; // functionally equivalent to maxWithdraw()
                sharesWithdrawn = FullMath.min(ERC4626(vault).balanceOf(address(this)),
                                        ERC4626(vault).convertToShares(amounts[i]));
                require(sharesWithdrawn == ERC4626(vault).withdraw(sharesWithdrawn, 
                                                        to, address(this)), "$m");
                                                        // ^ this sends tokens out
                perVault[vault].debit -= sharesWithdrawn;
                amounts[i] = ERC4626(vault).convertToAssets(
                                            sharesWithdrawn);
                sent += amounts[i];  
            } 
        } amounts[6] = FullMath.mulDiv(
            amount, FullMath.mulDiv(
                WAD, IStakeToken(SGHO).previewRedeem(
                        IStakeToken(SGHO).balanceOf(
                        address(this))), total), WAD);

        if (amounts[6] > 0) {
            amount = IStakeToken(SGHO).previewStake(amounts[6]);
            require(IStakeToken(SGHO).previewRedeem(amount) == amounts[6], "sgho");
            IStakeToken(SGHO).redeem(to, amount); sent += amounts[6];
        }
        // require(sent == amount, "morph");
        // this would be a nice invariant, but
        // in the case where we have borrowed
        // funds from Morpho, it won't pass
    }
}

