// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Settlement} from "./Settlement.sol";
import {Rover} from  "./Rover.sol";
import {Aux} from  "./Aux.sol";

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
    function stake(address to, uint amount) external;
    // here the amount is in underlying, not in shares...
    function redeem(address to, uint amount) external;
    // the amount param is in shares, not underlying...
    function claimRewards(address to, uint amount) external;
    function previewStake(uint assets)
             external view returns (uint);
    function previewRedeem(uint shares)
             external view returns (uint);
}

/// @title Basket - Multi-Asset Stablecoin Basket with Time-Locked Maturity
/// @notice Implements ERC6909 for multi-asset positions with time-based maturity
/// @dev Core component that manages USD deposits across multiple yield sources
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
    Settlement public SET;
    Aux public AUX; 
    
    Metrics public coreMetrics;
    string private _name = "QU!D";
    string private _symbol = "QD";
    address payable public V4;

    struct Metrics {
        uint last; uint total; uint yield;
    }
    struct Pod { uint shares; uint cash; }
    mapping(address => Pod) public perVault;
    
    uint public latest_holder = 0;
    mapping(uint => address) public holders;
    mapping(address => uint) public holder_to_id;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStable;
    mapping(address => address) public vaults;
   
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    
    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping( // legacy IERC20 version
            address => uint)) private _allowances;
    
    mapping(address => uint) public currentConcentrations;
    mapping(address => uint) public targets;
    
    mapping(address => uint) public lastVoteEpoch;
    mapping(uint => mapping(uint => uint[])) public epochVotes; 
    // epoch => stableIndex => array of vote values
    mapping(uint => uint[]) public epochVoteWeights; 
    mapping(uint => uint) public epochTotalWeight;
    
    mapping(uint => mapping(uint => uint)) public medianSum; 
    // epoch => stableIndex => running sum
    mapping(uint => mapping(uint => uint)) public medianK; 
    // epoch => stableIndex => current median position

    // Add fee toggle for testing
    bool public feesEnabled = false;

    /// @notice Restricts access to core system contracts
    /// @dev Only Rover (V4), Aux, or Settlement can call restricted functions
    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 
             || sender == address(AUX) 
             || sender == address(SET), "404"); _;
    }

    /// @notice Calculate current month since deployment
    /// @dev Used for time-based token maturity (28-day months)
    /// @return month Current month number since deployment
    function currentMonth() public view returns
        (uint month) { month = (block.timestamp -
                      _deployed) / 2420000; // ~28 days
    }
 
    /// @notice Get token name
    /// @return Token name "QU!D"
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /// @notice Get token symbol
    /// @return Token symbol "QD"
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /// @notice Get token decimals
    /// @return Always 18 decimals
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @notice Get total supply across all batches
    /// @return Total 6909 tokens in circulation
    function totalSupply() public 
        view returns (uint) {
        return _totalSupply;
    }

    /// @notice Transfer tokens (ERC20 compatible)
    /// @dev Transfers from most recent batches first
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return Always true if successful
    function transfer(address to, // receiver
        uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount, true);
    }

    /// @notice Approve spender (ERC20 compatible)
    /// @param spender Address to approve
    /// @param value Amount to approve
    /// @return Always true
    function approve(address spender, 
        uint value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    /// @notice Find most recent mature batch for withdrawal
    /// @dev Scans from newest to oldest to find withdrawable batches
    /// @param batches Array of batch IDs sorted by time
    /// @return i Index of most recent mature batch (-1 if none)
    function matureBatches(uint[] memory batches)
        public view returns (int i) {
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--) {
            if (batches[uint(i)] <= currentMonth()) {
                return i;
            }
        }
    }

    /// @notice Constructor initializes the basket with stablecoins and vaults
    /// @dev Sets up equal weighting across all stablecoins initially
    /// @param _router Rover (V4) contract address
    /// @param _aux Aux contract address
    /// @param _stables Array of stablecoin addresses
    /// @param _vaults Array of corresponding vault addresses
    constructor(address _router, address _aux,
        address[] memory _stables,
        address[] memory _vaults) { 
        _deployed = block.timestamp;
        AUX = Aux(payable(_aux));
        require(_stables.length == _vaults.length, "align"); 
        address stable; address vault; stables = _stables;
        uint equalWeight = WAD / _stables.length;
        for (uint i = 0; i < _vaults.length; i++) {
            stable = _stables[i]; vault = _vaults[i];
            isVault[vault] = true; vaults[stable] = vault;
            currentConcentrations[stable] = equalWeight;
            targets[stable] = equalWeight;
            isStable[stable] = true;
        }   V4 = payable(_router);
    }

    /// @notice Enable/disable rebalancing fees (for testing)
    /// @dev Only callable by system contracts
    /// @param _enabled Whether fees are enabled
    function setFeesEnabled(bool _enabled) external onlyUs {
        feesEnabled = _enabled;
    }

    /// @notice Set the Settlement contract address
    /// @dev Can only be set once during initialization
    /// @param _settlement Settlement contract address
    function setSettlement(address _settlement) external onlyUs {
        require(address(SET) == address(0), "set"); 
        SET = Settlement(_settlement);
    }

    /// @notice Get current metrics with optional force refresh
    /// @dev Calculates total value and yield across all vaults
    /// @param force Whether to force recalculation
    /// @return Total value and yield (in WAD)
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
        } return (stats.total, stats.yield); // to Rover's a lien, uh?
    }

    /// @notice Collect GHO staking rewards
    /// @dev Sends rewards to Rover owner as protocol fee
    // deployer's take-home...
    function collect() external {
        address vault = vaults[
        stables[stables.length-1]];
        IStakeToken(vault).claimRewards(
                    Rover(V4).owner(),
                    type(uint).max);
    }

    /// @notice Get current deposits across all vaults
    /// @dev Returns array with total and per-vault values
    /// @return amounts [0]=total, [1-n]=per vault, [9]=weighted APY sum
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

    /// @notice Withdraw tokens from basket to recipient
    /// @dev Complex logic handling multi-vault withdrawals with rebalancing
    /// @param who Recipient address
    /// @param amount Amount to withdraw (in 6909 tokens)
    /// @param token Specific token requested (or basket address for pro-rata)
    /// @param strict If true, only withdraw from specified token vault
    /// @return sent Amount actually sent after fees
    function take(address who, uint amount, 
        address token, bool strict) public
        onlyUs returns (uint sent) { 
        address vault; // ERC4626...
        if (token != address(this)) {
            vault = vaults[token];
            uint max = perVault[vault].cash;
            // if strict is true, we don't care about
            // AAVE obligations; we want USDC strictly 
            max -= (token == stables[0] && !strict) ? 
                 AUX.untouchable() : 0; // bonded...

            if (feesEnabled) {
                uint fee = getFee(token, false, amount);
                amount = FullMath.mulDiv(amount, WAD + fee, WAD); 
            } // Increase amount to account for fee

            if (max >= amount) { // can be covered wholly...
                uint withdrawn = withdraw(who, vault, amount);
                if (feesEnabled) {
                    uint fee = getFee(token, false, withdrawn);
                    return FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                }
                return withdrawn;
            } 
            else { uint withdrawn = withdraw(who, vault, max);
                if (feesEnabled) {
                    uint fee = getFee(token, false, max);
                    sent = FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                } else {
                    sent = withdrawn;
                }
                amount -= withdrawn;
                if (!strict) {
                    uint scale = 18 - IERC20(token).decimals();
                    if (scale > 0) {
                        amount *= 10 ** scale;
                        sent *= 10 ** scale;
                    }  
                } else { return sent; }
            }
        } 
        uint[10] memory amounts = get_deposits(); 
        uint ghoIndex = stables.length; sent = 0;
        
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
   
    /// @notice Internal vault withdrawal logic
    /// @dev Handles share conversion and updates tracking
    /// @param to Recipient address
    /// @param vault Vault to withdraw from
    /// @param amount Amount to withdraw in assets
    /// @return sent Actual amount withdrawn
    function withdraw(address to, address vault, uint amount) internal returns (uint sent) {
        uint sharesWithdrawn = Math.min(IERC4626(vault).balanceOf(address(this)),
                                        IERC4626(vault).convertToShares(amount));

        sent = IERC4626(vault).convertToAssets(sharesWithdrawn);
        require(sent == IERC4626(vault).redeem(sharesWithdrawn, to,
                                            address(this)), "draw");
        perVault[vault].cash -= sent;
        perVault[vault].shares -= sharesWithdrawn;
    }

    /// @notice Deposit tokens into basket
    /// @dev Handles stablecoins, vault shares, and GHO staking
    /// @param from Depositor address
    /// @param token Token being deposited
    /// @param amount Amount to deposit
    /// @return usd USD value of deposit
    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        address GHO = stables[stables.length - 1];
        address SGHO = vaults[GHO]; address vault;
        if (isVault[token] && token != SGHO) {
            uint allowed = IERC4626(token).allowance(from, address(this));
            amount = Math.min(allowed, IERC4626(token).convertToShares(amount));
            usd = IERC4626(token).convertToAssets(amount);
            
            uint totalNeeded = amount;
            if (feesEnabled) {
                uint fee = getFee(token, true, usd);
                uint feeInShares = FullMath.mulDiv(amount, fee, WAD);
                totalNeeded = amount + feeInShares;
                require(totalNeeded <= allowed, "allowance");
            }
            IERC4626(token).transferFrom(msg.sender, address(this), totalNeeded);
            require(usd >= 50 * (10 ** IERC20(IERC4626(token).asset()).decimals()), "grant");
            perVault[token].shares += amount; // Not totalNeeded!
            perVault[token].cash += usd;
        }    
        else if (isStable[token] || token == SGHO) {
            uint allowed = IERC20(token).allowance(from, address(this));
            usd = Math.min(amount, allowed);
            
            uint totalNeeded = usd;
            if (feesEnabled) {
                uint fee = getFee(token, true, usd);
                totalNeeded = FullMath.mulDiv(usd, WAD + fee, WAD);
                require(totalNeeded <= allowed, "insufficient allowance for fee");
            }
            IERC20(token).transferFrom(from, address(this), totalNeeded);                
            require(usd >= 50 * (10 ** IERC20(token).decimals()), "grant");

            if (token == GHO) { vault = SGHO;
                IERC20(token).approve(vault, usd);
                amount = IStakeToken(vault).previewStake(usd);
                IStakeToken(vault).stake(address(this), usd);
            } 
            else if (token != SGHO) { 
                vault = vaults[token];
                IERC20(token).approve(vault, usd);
                amount = IERC4626(vault).deposit(usd, address(this));
            } 
            perVault[vault].shares += amount;
            perVault[vault].cash += usd;
        } else {
            require(false, "unsupported token");
        }  
    }

    /// @notice Internal mint function for 6909 tokens
    /// @dev Overrides standard to add holder tracking and time-based batches
    /// @param receiver Address to mint to
    /// @param id Batch ID (month)
    /// @param amount Amount to mint
    // overriding standard 6909 code
    function _mint(address receiver,
        uint id, uint amount
    ) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender,
            address(0), receiver,
            id, amount); // TODO 404
    } // what they're for SIC
    // WAD therefore, Y
    // series sony vaio
    // pink sheets music
    // cyan samsung a16z

    /// @notice Mint new 6909 tokens with time-based maturity
    /// @dev Creates tokens that mature after specified time period
    /// @param pledge Beneficiary address
    /// @param amount Amount to mint
    /// @param token Backing token (if not self-minting)
    /// @param when Maturity month (0 for immediate)
    /** TODO can reutrn new total 
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
            uint id = holder_to_id[msg.sender]; 
            if (id == 0) {
                holders[latest_holder] = msg.sender;
                holder_to_id[msg.sender] = ++latest_holder;
            }   uint scale = 18 - IERC20(token).decimals();
            
            uint depositing = scale > 0 ? amount /
                            (10 ** scale) : amount;

            uint paid = deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            amount += FullMath.mulDiv(amount * yield,
                    month - currentMonth(), WAD * 12);

            _mint(pledge, month, amount);
        } 
    } 

    /// @notice Transfer from with allowance check
    /// @dev ERC20 compatible transferFrom
    /// @param from Source address
    /// @param to Destination address
    /// @param amount Amount to transfer
    /// @return Always true if successful
    function transferFrom(address from, 
        address to, uint amount) public
        returns (bool) {
        if (msg.sender != from
            && !isOperator[from][msg.sender]) {
            if (to == V4) {
                require(msg.sender == V4, "403");
            }
            uint allowed = _allowances[from][msg.sender];
            if (allowed != type(uint).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount, true);
    }

    /// @notice Burn tokens (restricted to system contracts)
    /// @dev Used for redemptions and settlements
    /// @param from Address to burn from
    /// @param value Amount to burn
    /// @return sent Amount actually burned
    // utility function for redemption (i.e. burn)
    function turn(address from, // whose balance
        uint value) onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from,
                address(0), value);
    }

    /// @notice Internal transfer helper handling batch logic
    /// @dev Transfers from newest to oldest batches
    /// @param from Source address
    /// @param to Destination address (0 for burn)
    /// @param amount Amount to transfer
    /// @return sent Amount actually transferred
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

    /// @notice Main transfer function with rebalancing
    /// @dev Updates concentrations after transfers if fees enabled
    /// @param from Source address
    /// @param to Destination address
    /// @param amount Amount to transfer
    /// @param update Whether to update concentrations
    /// @return Always true if successful
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
        if (update && feesEnabled) {
            _recomputeConcentrations(block.timestamp / 1 weeks);
        }
        return true;
    }

    /// @notice Vote on target allocations for rebalancing
    /// @dev Weighted by 6909 balance, updates weekly epoch
    /// @param _targets Array of target percentages (must sum to WAD)
    function vote(uint[] calldata _targets) external {
        uint epoch = block.timestamp / 1 weeks;
        require(_targets.length == stables.length 
        && lastVoteEpoch[msg.sender] < epoch, "mismatch");
        uint sum; // Verify targets sum to 100%
        for (uint i = 0; i < _targets.length; i++) {
            sum += _targets[i];
        } require(sum == WAD, 
        "Targets must sum to 100%");
        lastVoteEpoch[msg.sender] = epoch;
        uint weight = totalBalances[msg.sender];
        require(weight > 0, "No voting power");
        // Record vote and update weighted median 
        for (uint i = 0; i < stables.length; i++) {
            _insertSortedVote(epoch, i, _targets[i], weight);
        }   epochTotalWeight[epoch] += weight;
            _recomputeConcentrations(epoch);
    }

    /// @notice Insert vote maintaining sorted order
    /// @dev Enables efficient weighted median calculation
    /// @param epoch Voting epoch
    /// @param stableIndex Which stablecoin
    /// @param voteValue Target percentage
    /// @param weight Voter's weight
    function _insertSortedVote(uint epoch, uint stableIndex, 
        uint voteValue, uint weight) internal {
        uint[] storage votes = epochVotes[epoch][stableIndex];
        uint[] storage weights = epochVoteWeights[epoch];
        
        uint insertPos = votes.length;
        for (uint i = 0; i < votes.length; i++) {
            if (voteValue <= votes[i]) {
                insertPos = i;
                break;
            }
        }
        votes.push();
        weights.push();  
        // Shift elements
        for (uint i = votes.length - 1; i > insertPos; i--) {
            votes[i] = votes[i - 1];
            weights[i] = weights[i - 1];
        }
        votes[insertPos] = voteValue;
        weights[insertPos] = weight;
    }

    /// @notice Recompute target concentrations from votes
    /// @dev Uses exponential moving average for smooth rebalancing
    /// @param epoch Current voting epoch
    function _recomputeConcentrations(uint epoch) internal {
        uint[] memory newConcentrations = new uint[](stables.length);
        // Only recompute if there are votes for this epoch
        if (epochTotalWeight[epoch] == 0) {
            return; // Skip if no votes
        }
        for (uint i = 0; i < stables.length; i++) {
            newConcentrations[i] = _computeWeightedMedian(epoch, i);
            targets[stables[i]] = newConcentrations[i];
        }
        for (uint i = 0; i < stables.length; i++) {
            uint alpha = 2e17; // Exponential moving average smoothing factor
            currentConcentrations[stables[i]] = (targets[stables[i]] * alpha + 
            currentConcentrations[stables[i]] * (WAD - alpha)) / WAD;
        }
    }

    /// @notice Compute weighted median of votes
    /// @dev More robust than simple average, resistant to manipulation
    /// @param epoch Voting epoch
    /// @param stableIndex Which stablecoin
    /// @return Weighted median target percentage
    function _computeWeightedMedian(uint epoch,
        uint stableIndex) internal view returns (uint) {
        uint[] storage votes = epochVotes[epoch][stableIndex];
        uint[] storage weights = epochVoteWeights[epoch];
        
        if (votes.length == 0) {
            return WAD / stables.length; 
        } // Default to equal distribution
        
        uint totalWeight = epochTotalWeight[epoch];
        uint halfWeight = totalWeight / 2;
        uint cumulativeWeight = 0;
        
        for (uint i = 0; i < votes.length; i++) {
            cumulativeWeight += weights[i];
            if (cumulativeWeight >= halfWeight) {
                // Check if we're exactly at the midpoint
                if (cumulativeWeight == halfWeight && i + 1 < votes.length) {
                    // Average of current and next value
                    return (votes[i] + votes[i + 1]) / 2;
                }
                return votes[i];
            }
        } return votes[votes.length - 1]; 
    }

    /// @notice Calculate rebalancing fee using sigmoid curve
    /// @dev Penalizes deposits/withdrawals that move away from target
    /// @param actual Current concentration
    /// @param target Target concentration
    /// @param multiplier Fee multiplier (higher for deposits)
    /// @return fee18 Fee in WAD units
    function sigmoidFee(uint actual, 
        uint target, uint multiplier) public pure returns (uint fee18) {
        // Manhattan distance approach for multi-dimensional optimization
        int deviation = int(actual) - int(target);
        int rel = (deviation * int(WAD)) / int(target);
        // Sigmoid-like, more off-target is sharper penalty 
        int expTerm = rel * 5e17; // Slope parameter
        if (expTerm > 100e18) expTerm = 100e18;
        if (expTerm < -100e18) expTerm = -100e18;
        // Using approximation for exp function
        uint penalty;
        if (expTerm >= 0) {
            penalty = uint(1e18 + expTerm + 
            (expTerm * expTerm) / (2 * 1e18));
        } else {
            uint absExp = uint(-expTerm);
            uint denominator = 1e18 + absExp + 
            (absExp * absExp) / (2 * 1e18);
            penalty = (1e36) / denominator;
        } // Remove baseline 1.0,
        // multiply by multiplier
        if (penalty > 1e18) {
            fee18 = ((penalty - 1e18) *
                 multiplier) / 1e18;
        } else { fee18 = 0; }
    }

    /// @notice Get rebalancing fee for a stablecoin operation
    /// @dev Incentivizes deposits to underweight assets, withdrawals from overweight
    /// @param stable Stablecoin address
    /// @param isMinting True for deposits, false for withdrawals
    /// @param amount Operation amount (unused but kept for future)
    /// @return fee18 Fee percentage in WAD units
    function getFee(address stable, 
        bool isMinting, uint amount) 
        public view returns (uint fee18) {
        if (!feesEnabled) return 0; // Fees disabled
        
        uint totalValue = get_deposits()[0];
        if (totalValue == 0) return 0;
        address vault = vaults[stable];
        uint actual = (perVault[vault].cash * WAD) / totalValue;
        uint target = currentConcentrations[stable]; // smoothed 
        
        // For minting: higher fee if overweight
        // For redeeming: lower fee if overweight
        uint multiplier = isMinting ? 2e16 : 1e16; 
        if (isMinting) {
            return sigmoidFee(actual,
                 target, multiplier);
        } else {
            if (actual > target) {
                uint baseFee = sigmoidFee(target, actual, multiplier);
                return baseFee > multiplier ? 0 : multiplier - baseFee;
            } else { return sigmoidFee(target, actual, multiplier); }
        }
    }
}