
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Router} from  "./Router.sol";
import {Auxiliary} from  "./Auxiliary.sol";

import "lib/forge-std/src/console.sol";
// TODO delete logging before mainnet...

import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

interface IStakeToken is IERC20 { // StkGHO (safety module)
    function stake(address to, uint256 amount) external;
    // here the amount is in underlying, not in shares...
    function redeem(address to, uint256 amount) external;
    // the amount param is in shares, not underlying...
    function claimRewards(address to, uint256 amount) external;
    function previewStake(uint256 assets)
             external view returns (uint256);
    function previewRedeem(uint256 shares)
             external view returns (uint256);
}


contract Basket is ERC6909 { // extended
// for full ERC20 compatibility, batch
// transferring through helper function
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;

    uint private _deployed;
    uint private _totalSupply;
    uint constant WAD = 1e18;
    address[] public stables;
    Auxiliary public AUX; 
    
    Metrics public coreMetrics;
    string private _name = "QU!D";
    string private _symbol = "QD";
    address payable public V4;

    struct Metrics {
        uint last; uint total; uint yield;
    }
    struct Pod { uint shares; uint cash; }
    mapping(address => Pod) public perVault;
    
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStable;
    mapping(address => address) public vaults;
   
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    
    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping( // legacy IERC20 version
            address => uint256)) private _allowances;
    
    mapping(address => uint256) public currentConcentrations;
    mapping(address => uint256) public targetConcentrations;
    
    // included to avoid building propeller indexer 
    mapping(address => uint256) public lastVoteEpoch;
    mapping(uint256 => mapping(uint256 => uint256[])) public epochVotes; 
    // epoch => stableIndex => array of vote values
    mapping(uint256 => uint256[]) public epochVoteWeights; 
    // epoch => array of weights
    mapping(uint256 => uint256) public epochTotalWeight;
    
    mapping(uint256 => mapping(uint256 => uint256)) public medianSum; 
    // epoch => stableIndex => running sum
    mapping(uint256 => mapping(uint256 => uint256)) public medianK; 
    // epoch => stableIndex => current median position

    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 || 
                sender == address(AUX), "403"); _;
    }

    /**
     * @dev Returns the current reading of our internal clock.
     */
    function currentMonth() public view returns
        (uint month) { month = (block.timestamp -
                      _deployed) / 2420000; // ~28 days
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
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public 
        view returns (uint) {
        return _totalSupply;
    }

    function transfer(address to, // receiver
        uint amount) public returns (bool) {
        // TODO compute true based on some timer?
        return _transfer(msg.sender, to, amount, true);
    }

    function approve(address spender, 
        uint256 value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function matureBatches(uint[] memory batches)
        public view returns (int i) {
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--) {
            if (batches[uint(i)] <= currentMonth()) {
                return i;
            }
        }
    }

    constructor(address _router, address _aux,
        address[] memory _stables,
        address[] memory _vaults) { 
        _deployed = block.timestamp;
        AUX = Auxiliary(payable(_aux));
        require(_stables.length == _vaults.length, "align"); 
        address stable; address vault; stables = _stables;
        for (uint i = 0; i < _vaults.length; i++) {
            stable = _stables[i]; vault = _vaults[i];
            isVault[vault] = true; vaults[stable] = vault;
            isStable[stable] = true;
        }   V4 = payable(_router);
    }

    // if force is false we just return
    // the most recent known metrics 
    // without recalculating them...
    function get_metrics(bool force)
        public returns (uint, uint) {
        Metrics memory stats = coreMetrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            // give credit to this calculation often, lest stale
            uint[10] memory amounts = get_deposits();
            stats.last = block.timestamp;
            stats.total = amounts[0];
            stats.yield = FullMath.mulDiv(WAD,
               amounts[9], amounts[0] - amounts[8]) - WAD;
            coreMetrics = stats; // exclude ^ sGHO "yield" as it goes
        } return (stats.total, stats.yield); // to the Router's owner
    }

    // deployer's take-home...
    function collect() external {
        address vault = vaults[
        stables[stables.length-1]];
        IStakeToken(vault).claimRewards(
                    Router(V4).owner(),
                    type(uint256).max);
    }

    function get_deposits() public view
        returns (uint[10] memory amounts) {
        address vault; uint shares; // 4626
        uint ghoIndex = stables.length - 1;
        for (uint i = 0; i < ghoIndex; i++) { 
            uint multiplier = i > 1 ? 1 : 1e12;
            uint noTouching = i == 0 ? 
               AUX.untouchable() : 0;
            // ^ scale precision for USDC/USDT
            // because the rest are all 1e18
            vault = vaults[stables[i]];
            shares = perVault[vault].shares;
            if (shares > 0) {
                shares = (IERC4626(vault).convertToAssets(shares) - noTouching) * multiplier;
                amounts[i + 1] = shares; amounts[0] += shares; // track total;
                amounts[9] += FullMath.mulDiv(shares, // < weighted sum of
                    IERC4626(vault).totalAssets() * multiplier, // APY 
                    IERC4626(vault).totalSupply()); // for staking...
            }
        } vault = vaults[stables[ghoIndex]];
        shares = IStakeToken(vault).previewRedeem(
                 IStakeToken(vault).balanceOf(
                                address(this)));
        amounts[stables.length] = shares;
        amounts[0] += shares; // our total
    }

    function take(address who, // on whose behalf
        uint amount, address token, bool strict) 
        public onlyUs returns (uint sent) { 
        address vault;
        if (token != address(this)) {
            vault = vaults[token];
            uint max = perVault[vault].cash;
            // if strict is true, we don't care about
            // AAVE obligations; we want USDC strictly 
            max -= (token == stables[0] && !strict) ? 
                 AUX.untouchable() : 0;

            if (max >= amount) { // can be covered
                // wholly in the desired token...
                return withdraw(who, vault, amount);
            } else { // < must split the output...
                max = withdraw(who, vault, max);
                amount -= max; 
                if (!strict) {
                    uint scale = 18 - IERC20(token).decimals();
                    if (scale > 0) {
                        amount *= 10 ** scale;
                        max *= 10 ** scale;
                    }   sent = max;
                } else return max;
            }
        } uint ghoIndex = stables.length;
        uint[10] memory amounts = get_deposits();  
        for (uint i = 1; i < ghoIndex; i++) {
            uint divisor = (i - 1) > 1 ? 1 : 1e12;
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                WAD, amounts[i], amounts[0]), WAD);
            amounts[i] /= divisor;
            if (amounts[i] > 0) { vault = vaults[stables[i - 1]];
                amounts[i] = withdraw(who, vault, amounts[i]);
                sent += amounts[i] * divisor;
            }
        } vault = vaults[stables[stables.length - 1]];

        amounts[ghoIndex] = FullMath.mulDiv(amount, FullMath.mulDiv(
                            WAD, amounts[ghoIndex], amounts[0]), WAD);

        if (amounts[ghoIndex] > 0) {
            // exchange rate is 1:1, but just to be safe we calculate
            amount = IStakeToken(vault).previewStake(amounts[ghoIndex]);
            require(IStakeToken(vault).previewRedeem(amount) == amounts[ghoIndex], "sgho");
            IStakeToken(vault).redeem(who, amount); sent += amounts[ghoIndex];
        }
    }  

    function withdraw(address to, address vault, uint amount) internal returns (uint sent) {
        uint sharesWithdrawn = Math.min(IERC4626(vault).balanceOf(address(this)),
                                        IERC4626(vault).convertToShares(amount));

        sent = IERC4626(vault).convertToAssets(sharesWithdrawn);
        require(sent == IERC4626(vault).redeem(sharesWithdrawn, to,
                                            address(this)), "draw");
        perVault[vault].cash -= sent;
        perVault[vault].shares -= sharesWithdrawn;
    }

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
            require(usd >= 50 * 
            (10 ** IERC20(IERC4626(token).asset()).decimals()), "grant");
            perVault[token].shares += amount; 
            perVault[token].cash += usd;
        }    
        else if (isStable[token] || token == SGHO) {
            usd = Math.min(amount, 
            IERC20(token).allowance(
                from, address(this)));
            IERC20(token).transferFrom(
                from, address(this), usd);
            require(usd >= 50 * (10 ** 
                IERC20(token).decimals()), "grant");
            
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
        }
    }

    // overriding standard 6909 code
    function _mint(address receiver,
        uint256 id, uint256 amount
    ) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender,
            address(0), receiver,
            id, amount);
    }

    /**
     * @param pledge is on whose behalf...
     * @param amount is the amount to mint
     * @param token is what will be bonded
     * @param when is when amount matures
     */
    function mint(address pledge, uint amount, 
        address token, uint when) public {
        uint month = Math.max(when,
            currentMonth() + 1);
            
        if (token == address(this)) {
            require(msg.sender == address(AUX), "403");
            _mint(pledge, month, amount);
        } else {
            uint scale = 18 - IERC20(token).decimals();
            uint depositing = scale > 0 ? amount /
                            (10 ** scale) : amount;

            uint paid = deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            amount += FullMath.mulDiv(amount * yield,
                    month - currentMonth(), WAD * 12);

            _mint(pledge, month, amount);
        }
    } 

    function transferFrom(address from, 
        address to, uint amount) public
        returns (bool) {
        if (msg.sender != from
            && !isOperator[from][msg.sender]) {
            if (to == V4) {
                require(msg.sender == V4, "403");
            }
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount, true);
        // TODO compute true based on some timer?
    }

    // utility function for redemption (i.e. burn)
    function turn(address from, // whose balance
        uint value) onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from,
                address(0), value);
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
        uint[] memory batches = perMonth[from].getSortedSet();
        // if i = 0 then this will either give us one iteration,
        // or exit with index out of bounds, both make sense...
        bool toZero = to == address(0);
        bool burning = toZero || to == V4;
        int i = toZero ?
            // this may return -1
            matureBatches(batches) :
            int(batches.length - 1);

        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) {
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!burning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else {
                    totalSupplies[k] -= amt;
                }
                if (balanceOf[from][k] == 0) {
                    perMonth[from].remove(k);
                } 
                amount -= amt;
                sent += amt;
            }   i -= 1;
        }
        if (sent > 0) {
            totalBalances[from] -= sent;
            if (burning) {
                _totalSupply -= sent;
            } else {
                totalBalances[to] += sent;
            }
        }
    }

    /**
     * @dev A transfer that doesn't specify which
     * batch will proceed backwards from most recent
     * to oldest batch until the transfer amount is 
     * fulfilled entirely. Tokenholders that desire
     * a more granular result should use the other
     * transfer function (we do not override 6909)
     */
    function _transfer(address from, address to,
        uint amount, bool update) internal returns (bool) {
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(from, 
                          to, amount); 
                          return true;
        if (update) {
            _recomputeConcentrations(block.timestamp / 1 weeks);
        }
    }

    // Voting with weighted median computation
    function vote(uint256[] calldata targets) external {
        require(targets.length == stables.length, "Target mismatch");
        uint256 epoch = block.timestamp / 1 weeks;
        require(lastVoteEpoch[msg.sender] < epoch, "Already voted this epoch");
        
        // Verify targets sum to 100%
        uint256 sum;
        for (uint256 i = 0; i < targets.length; i++) {
            sum += targets[i];
        }
        require(sum == WAD, "Targets must sum to 100%");
        
        lastVoteEpoch[msg.sender] = epoch;
        uint256 weight = totalBalances[msg.sender];
        require(weight > 0, "No voting power");
        // Record vote and update weighted median 
        for (uint256 i = 0; i < stables.length; i++) {
            _insertSortedVote(epoch, i, targets[i], weight);
        }   epochTotalWeight[epoch] += weight;
            _recomputeConcentrations(epoch);
    }

    function _insertSortedVote(uint256 epoch, uint256 stableIndex, uint256 voteValue, uint256 weight) internal {
        uint256[] storage votes = epochVotes[epoch][stableIndex];
        uint256[] storage weights = epochVoteWeights[epoch];
        
        // Find insertion position (keep sorted by vote value)
        uint256 insertPos = votes.length;
        for (uint256 i = 0; i < votes.length; i++) {
            if (voteValue <= votes[i]) {
                insertPos = i;
                break;
            }
        }
        
        // Insert vote maintaining sorted order
        votes.push();
        weights.push();
        
        // Shift elements
        for (uint256 i = votes.length - 1; i > insertPos; i--) {
            votes[i] = votes[i - 1];
            weights[i] = weights[i - 1];
        }
        
        votes[insertPos] = voteValue;
        weights[insertPos] = weight;
    }

     function _recomputeConcentrations(uint256 epoch) internal {
        uint256[] memory newConcentrations = new uint256[](stables.length);
        
        for (uint256 i = 0; i < stables.length; i++) {
            newConcentrations[i] = _computeWeightedMedian(epoch, i);
            targetConcentrations[stables[i]] = newConcentrations[i];
        }
        
        // (exponential moving average)
        for (uint256 i = 0; i < stables.length; i++) {
            uint256 alpha = 2e17; // 0.2 smoothing factor
            currentConcentrations[stables[i]] = 
                (targetConcentrations[stables[i]] * alpha + 
                 currentConcentrations[stables[i]] * (WAD - alpha)) / WAD;
        }
    }

    function _computeWeightedMedian(uint256 epoch, uint256 stableIndex) internal view returns (uint256) {
        uint256[] storage votes = epochVotes[epoch][stableIndex];
        uint256[] storage weights = epochVoteWeights[epoch];
        
        if (votes.length == 0) {
            return WAD / stables.length; 
        } // Default to equal distribution
        
        uint256 totalWeight = epochTotalWeight[epoch];
        uint256 halfWeight = totalWeight / 2;
        uint256 cumulativeWeight = 0;
        
        // Find weighted median
        for (uint256 i = 0; i < votes.length; i++) {
            cumulativeWeight += weights[i];
            if (cumulativeWeight >= halfWeight) {
                // Check if we're exactly at the midpoint
                if (cumulativeWeight == halfWeight && i + 1 < votes.length) {
                    // Average of current and next value
                    return (votes[i] + votes[i + 1]) / 2;
                }
                return votes[i];
            }
        }
        
        return votes[votes.length - 1]; // Fallback
    }

    function sigmoidFee(uint256 actual, uint256 target, uint256 multiplier) public pure returns (uint256 fee18) {
        if (target == 0 || actual == 0) return 0;

        // Manhattan distance approach for multi-dimensional optimization
        int256 deviation = int256(actual) - int256(target);
        int256 rel = (deviation * int256(WAD)) / int256(target);

        // Sigmoid-like curve with sharper penalty further from target
        int256 expTerm = rel * 5e17; // Slope parameter
        if (expTerm > 100e18) expTerm = 100e18;
        if (expTerm < -100e18) expTerm = -100e18;

        // Using approximation for exp function
        uint256 penalty;
        if (expTerm >= 0) {
            penalty = uint256(1e18 + expTerm + (expTerm * expTerm) / (2 * 1e18));
        } else {
            uint256 absExp = uint256(-expTerm);
            uint256 denominator = 1e18 + absExp + (absExp * absExp) / (2 * 1e18);
            penalty = (1e36) / denominator;
        }
        // Remove baseline 1.0,
        // multiply by multiplier
        if (penalty > 1e18) {
            fee18 = ((penalty - 1e18) *
                 multiplier) / 1e18;
        } else {
            fee18 = 0;
        }
    }

    function getFee(address stable, 
        bool isMinting, uint256 amount) 
        public view returns (uint256 fee18) {
        address vault = vaults[stable];
        uint256 actual = perVault[vault].cash;
        uint256 target = (targetConcentrations[stable] * 
                            get_deposits()[0]) / WAD;
        uint256 multiplier = isMinting ? 2e16 : 1e16; 
        // 2% mint, 1% redeem baseline
        return sigmoidFee(actual, 
            target, multiplier);
    }

    function priceIn(address stable,
        uint256 notional) external
        view returns (uint256 sharesIn) {
        address vault = vaults[stable];
        uint256 pps = perVault[vault].shares > 0 ? 
            (perVault[vault].cash * WAD) / 
           perVault[vault].shares : WAD;
        
        uint256 fee = getFee(stable, 
                    true, notional);
        
        sharesIn = FullMath.mulDiv(notional *
                     (1e18 + fee), 1e18, pps);
    }

    function priceOut(address stable,
        uint256 notional) external
        view returns (uint256 sharesOut) {
        address vault = vaults[stable];
        uint256 pps = perVault[vault].shares > 0 ? 
            (perVault[vault].cash * WAD) / 
           perVault[vault].shares : WAD;
        
        uint256 fee = getFee(stable, 
                    false, notional);
        
        sharesOut = FullMath.mulDiv(notional * 
                    (1e18 - fee), 1e18, pps);
    }
} // TODO call priceOut and priceIn with take, _turn, _deposit
