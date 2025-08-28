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

import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStakeToken is IERC20 { // StkGHO (safety module)
    function stake(address to, uint amount) external;
    function redeem(address to, uint amount) external;
    function claimRewards(address to, uint amount) external;
    function previewStake(uint assets) external view returns (uint);
    function previewRedeem(uint shares) external view returns (uint);
}

interface ICollection is IERC721 {
    function latestTokenId()
    external view returns (uint);
} // in the windmills of my mind
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
} 

contract Basket is ERC6909, 
    IERC721Receiver, ReentrancyGuard  {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;
    uint constant LAMBO = 16508; 
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
    mapping(address => mapping(address => uint)) private _allowances;
    
    mapping(address => uint) public currentConcentrations;
    mapping(address => uint) public targets;
    
    mapping(address => uint) public lastVoteEpoch;
    mapping(address => bool) public hasBeenJuror;
    mapping (address => bool) public winners;
    // ^ the mapping prevents duplicates...
    address[] public everVotedInJury;
    
    // Use SortedSetLib for vote values to eliminate sorting
    // epoch => stableIndex => sorted set of vote values  
    mapping(uint => mapping(uint => SortedSetLib.Set)) private voteSets;
    
    // Map vote values to their total weights
    // epoch => stableIndex => voteValue => totalWeight
    mapping(uint => mapping(uint => mapping(uint => uint))) public voteWeights;
    
    // Total weight per epoch
    mapping(uint => uint) public epochTotalWeight;

    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 
             || sender == address(AUX) 
             || sender == address(SET), "404"); _;
    }

    function currentMonth() public view returns (uint month) { 
        month = (block.timestamp - _deployed) / 2420000; // ~28 days
    }
 
    function name() public view virtual returns (string memory) {
        return _name;
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint) {
        return _totalSupply;
    }

    function transfer(address to, uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount, true);
    }

    function approve(address spender, uint value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function matureBatches(uint[] memory batches) public view returns (int i) {
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

    function setSettlement(address _settlement) external onlyUs {
        require(address(SET) == address(0), "set"); 
        SET = Settlement(_settlement);
    }

    function get_metrics(bool force) public returns (uint, uint) {
        Metrics memory stats = coreMetrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            uint[10] memory amounts = get_deposits();
            stats.last = block.timestamp;
            stats.total = amounts[0];
            stats.yield = FullMath.mulDiv(WAD,
               amounts[9], amounts[0] - amounts[8]) - WAD;
            coreMetrics = stats;
        } return (stats.total, stats.yield);
    }

    function collect() external {
        address vault = vaults[stables[stables.length-1]];
        IStakeToken(vault).claimRewards(Rover(V4).owner(), type(uint).max);
    }

    function get_deposits() public view returns (uint[10] memory amounts) {
        address vault; uint shares;
        uint ghoIndex = stables.length - 1;
        for (uint i = 0; i < ghoIndex; i++) { 
            uint multiplier = i > 1 ? 1 : 1e12;
            vault = vaults[stables[i]];
            shares = perVault[vault].shares;
            
            if (shares > 0) {
                uint assets = IERC4626(vault).convertToAssets(shares);
                if (i == 0) {
                    uint noTouching = AUX.untouchable();
                    if (noTouching > assets) {
                        assets = 0;
                    } else {
                        assets -= noTouching;
                    }
                }
                shares = assets * multiplier;
                amounts[i + 1] = shares; 
                amounts[0] += shares;
                
                if (IERC4626(vault).totalSupply() > 0) {
                    amounts[9] += FullMath.mulDiv(shares,
                        IERC4626(vault).totalAssets() * multiplier,
                        IERC4626(vault).totalSupply());
                }
            }
        } 
        vault = vaults[stables[stables.length - 1]];
        if (IStakeToken(vault).balanceOf(address(this)) > 0) {
            shares = IStakeToken(vault).previewRedeem(
                     IStakeToken(vault).balanceOf(address(this)));
            amounts[stables.length] = shares;
            amounts[0] += shares;
        }
    }

    function take(address who, uint amount, address token, bool strict) 
        public onlyUs returns (uint sent) { address vault;
        if (token != address(this)) { vault = vaults[token];
            uint max = perVault[vault].cash;
            require(max > 0, "No liquidity");
            if (token == stables[0] && !strict) {
                uint reserved = AUX.untouchable();
                if (reserved >= max) {
                    revert("Insufficient unreserved funds");
                }   max -= reserved;
            }
            uint fee = getFee(token, false, amount);
            if (fee > WAD / 10) fee = WAD / 10;
            
            uint amountNeeded;
            if (fee > 0) {
                amountNeeded = FullMath.mulDiv(amount, WAD + fee, WAD);
            } else {
                amountNeeded = amount;
            }
            if (max >= amountNeeded) {
                uint withdrawn = withdraw(who, vault, amountNeeded);
                if (fee > 0) {
                    return FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                } else {
                    return withdrawn;
                }
            } 
            else { 
                uint withdrawn = withdraw(who, vault, max);
                if (fee > 0) {
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

    function deposit(address from, address token, 
        uint amount) public returns (uint usd) {
        address GHO = stables[stables.length - 1];
        address SGHO = vaults[GHO]; address vault;
        if (isVault[token] && token != SGHO) {
            uint allowed = IERC4626(token).allowance(from, address(this));
            amount = Math.min(allowed, IERC4626(token).convertToShares(amount));
            usd = IERC4626(token).convertToAssets(amount);
            
            uint fee = getFee(token, true, usd);
            uint totalNeeded = amount;
            if (fee > 0 && fee < WAD / 10) {
                uint feeInShares = FullMath.mulDiv(amount, fee, WAD);
                totalNeeded = amount + feeInShares;
            }
            require(totalNeeded <= allowed, "allowance");
            
            IERC4626(token).transferFrom(msg.sender, address(this), totalNeeded);
            require(usd >= 50 * (10 ** IERC20(IERC4626(token).asset()).decimals()), "grant");
            perVault[token].shares += amount;
            perVault[token].cash += usd;
        }    
        else if (isStable[token] || token == SGHO) {
            uint allowed = IERC20(token).allowance(from, address(this));
            usd = Math.min(amount, allowed);
            
            uint fee = getFee(token, true, usd);
            uint totalNeeded = usd;
            if (fee > 0 && fee < WAD / 10) {
                totalNeeded = FullMath.mulDiv(usd, WAD + fee, WAD);
            }
            require(totalNeeded <= allowed, "insufficient allowance for fee");
            
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

    function _mint(address receiver, uint id, uint amount) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, address(0), receiver, id, amount);
    } 

    function mint(address pledge, uint amount, address token, uint when) public {
        uint month = Math.max(when, currentMonth() + 1);
            
        if (token == address(this)) {
            require(msg.sender == address(AUX), "403");
            _mint(pledge, month, amount);
        } else {
            uint id = holder_to_id[msg.sender]; 
            if (id == 0) {
                holders[latest_holder] = msg.sender;
                holder_to_id[msg.sender] = ++latest_holder;
            }   
            uint scale = 18 - IERC20(token).decimals();
            // TODO charge 0.1% 
            uint depositing = scale > 0 ? amount / (10 ** scale) : amount;

            uint paid = deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            amount += FullMath.mulDiv(amount * yield,
                    month - currentMonth(), WAD * 12);

            _mint(pledge, month, amount);
        } 
    } 

    function transferFrom(address from, address to, uint amount) public returns (bool) {
        if (msg.sender != from && !isOperator[from][msg.sender]) {
            if (to == V4) {
                require(msg.sender == V4, "403");
            }
            uint allowed = _allowances[from][msg.sender];
            if (allowed != type(uint).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount, true);
    }

    function turn(address from, uint value) onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from, address(0), value);
    }

    function burn(address from, uint256 amount) external onlyUs {
        _burn(from, uint256(uint160(address(this))), amount);
    }


    function recordJuror(address juror) external {
        require(msg.sender == address(SET), "set");
        if (!hasBeenJuror[juror]) {
            hasBeenJuror[juror] = true;
            everVotedInJury.push(juror);
        }
    }

    function _transferHelper(address from, address to, uint amount) 
        internal returns (uint sent) {
        uint[] memory batches = perMonth[from].getSortedSet();
        bool toZero = to == address(0);
        bool burning = toZero || to == V4;
        int i = toZero ? matureBatches(batches) : int(batches.length - 1);

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

    function _transfer(address from, address to,
        uint amount, bool update) internal returns (bool) {
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(from, to, amount); 
        if (update) {
            _recomputeConcentrations(block.timestamp / 1 weeks);
        }
        return true;
    }

    function vote(uint[] calldata _targets) external {
        uint epoch = block.timestamp / 1 weeks;
        require(_targets.length == stables.length 
            && lastVoteEpoch[msg.sender] < epoch, "mismatch");
        
        uint sum;
        for (uint i = 0; i < _targets.length; i++) {
            sum += _targets[i];
        } 
        require(sum == WAD, "Targets must sum to 100%");
        
        lastVoteEpoch[msg.sender] = epoch;
        uint weight = totalBalances[msg.sender];
        require(weight > 0, "No voting power");
        
        // Record votes using SortedSetLib
        for (uint i = 0; i < stables.length; i++) {
            // Insert vote value (automatically sorted)
            voteSets[epoch][i].insert(_targets[i]);
            // Track weight for this vote value
            voteWeights[epoch][i][_targets[i]] += weight;
        }   
        epochTotalWeight[epoch] += weight;
        _recomputeConcentrations(epoch);
    }

    function _recomputeConcentrations(uint epoch) internal {
        if (epochTotalWeight[epoch] == 0) return;
        
        for (uint i = 0; i < stables.length; i++) {
            uint newTarget = _computeWeightedMedian(epoch, i);
            targets[stables[i]] = newTarget;
            
            // Exponential moving average
            uint alpha = 2e17;
            currentConcentrations[stables[i]] = (newTarget * alpha + 
                currentConcentrations[stables[i]] * (WAD - alpha)) / WAD;
        }
    }

    function _computeWeightedMedian(uint epoch, 
        uint stableIndex) internal view returns (uint) {
        uint[] memory sortedVotes = voteSets[epoch][stableIndex].getSortedSet();
        
        if (sortedVotes.length == 0) {
            return WAD / stables.length;
        }
        
        uint totalWeight = epochTotalWeight[epoch];
        uint halfWeight = totalWeight / 2;
        uint cumulativeWeight = 0;
        
        // Iterate through already-sorted votes from SortedSetLib
        for (uint i = 0; i < sortedVotes.length; i++) {
            uint voteValue = sortedVotes[i];
            uint weight = voteWeights[epoch][stableIndex][voteValue];
            cumulativeWeight += weight;
            
            if (cumulativeWeight >= halfWeight) {
                // Check if exactly at midpoint
                if (cumulativeWeight == halfWeight && i + 1 < sortedVotes.length) {
                    return (voteValue + sortedVotes[i + 1]) / 2;
                }
                return voteValue;
            }
        } 
        return sortedVotes[sortedVotes.length - 1]; 
    }

    function sigmoidFee(uint actual, uint target, uint multiplier) public pure returns (uint fee18) {
        uint deviation;
        if (actual > target) {
            deviation = ((actual - target) * WAD) / target;
        } else {
            deviation = ((target - actual) * WAD) / target;
        }
        
        deviation = deviation / 2;
        uint sigmoidOutput = (deviation * WAD) / (WAD + deviation);
        fee18 = (sigmoidOutput * multiplier) / WAD;
        
        if (fee18 > 2e15) {
            fee18 = 2e15;
        }
    }

    function getFee(address stable, bool isMinting, uint amount) 
        public view returns (uint fee18) {
        address vault = vaults[stable];
        uint vaultCash = perVault[vault].cash;
        
        if (vaultCash == 0) return 0;
        
        uint[10] memory deposits = get_deposits();
        uint totalValue = deposits[0];
        
        if (totalValue == 0) return 0;
        
        uint normalizedCash = vaultCash;
        if (stable == stables[0] || stable == stables[1]) {
            normalizedCash = vaultCash * 1e12;
        }
        
        uint actual = (normalizedCash * WAD) / totalValue;
        uint target = currentConcentrations[stable];
        
        if (target == 0) {
            target = WAD / stables.length;
        }
        
        if (actual >= WAD * 99 / 100) return 0;
        
        uint deviation = actual > target ? actual - target : target - actual;
        if (deviation < WAD / 20) return 0;
        
        uint multiplier = 4e14;
        
        if (isMinting) {
            if (actual > target) {
                fee18 = sigmoidFee(actual, target, multiplier);
                return fee18;
            }
            return 0;
        } else {
            if (actual < target) {
                fee18 = sigmoidFee(target, actual, multiplier);
                return fee18;
            }
            return 0;
        }
    } address public constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405; // foundation
    /** Whenever an {IERC721} `tokenId` token is transferred to this ERC20: ratcheting batch
     * @dev Safe transfer `tokenId` token from `from` to `address(this)`, checking that the
     recipient prevent tokens from being forever locked. An NFT is used as the _delegate is 
     an attribution of character, 
     * - `tokenId` token must exist and be owned by `from`
     * - If the caller is not `from`, it must have been allowed
     *   to move this token by either {approve} or {setApprovalForAll}.
     * - {onERC721Received} is called after a safeTransferFrom...
     * - It must return its Solidity selector to confirm the token transfer.
     *   If any other value is returned or the interface is not implemented
     *   but when a prince briskly declares himself in favour of one side, 
     *   if the side you choose is the winner then you have a good friend
     */
    // QuidMint...foundation.app/@quid
    function onERC721Received(address,
        address from, // previous owner...
        uint tokenId, bytes calldata data)
        external override nonReentrant returns (bytes4) { 
        if (tokenId == LAMBO && ICollection(F8N).ownerOf(
            LAMBO) == address(this)) { address winner;
            uint cut = KICKBACK / 12; 
            _mint(from, 24, cut); 
            _mint(Rover(V4).owner(), 24, cut);
            // my mind spits with an enormous kickback,
            // open fire...open mind...this time is a 
            // promise sounding like an oath...I wanna 
            // know true feeling, but you can't decide
            // if you're hooked on...only the kick...
            uint kickback = KICKBACK - cut;
            ICollection(F8N).transferFrom( 
            address(this), from, LAMBO); // return NFT to sender
            // only proceed with lottery if enough jurors chooseable
            if (everVotedInJury.length >= 10 && data.length >= 32) {
                bytes32 _seed = abi.decode(data[:32], (bytes32));
                uint distributed = 0;
                
                for (uint i = 0; distributed < 10 && i < 30; i++) {
                    uint random = uint(keccak256(
                        abi.encodePacked(_seed,
                        block.prevrandao, i))) %
                        everVotedInJury.length;
                    winner = everVotedInJury[random];
                    if (!winners[winner]) {
                        winners[winner] = true;
                        _mint(winner, 24, cut); // 2yr maturity
                        kickback -= cut;
                        distributed++;
                    } 
                } // new level, same rebel, hold the Base never trebble,
                // I hop out the price drop, and the system be trembling
            }
            if (kickback > 0) {
                _mint(Rover(V4).owner(), 24, kickback);
            }   // "I put my key, you put your key in"
        } return this.onERC721Received.selector; 
    } 
    uint constant KICKBACK = 666666666666666666666666;
     // https://www.law.cornell.edu/wex/consideration
    // of legally sufficient value, bargained-for in 
    // an exchange agreement, for the breach of which
    // Mindwill gives an equitable remedy, and whose 
    // performance is recognised as reasonable duty
    // or tender (an unconditional offer to perform)
}