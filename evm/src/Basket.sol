// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from  "./Aux.sol";
import {Rover} from  "./Rover.sol";
import {BasketLib} from "./BasketLib.sol";
// import {Settlement} from "./Settlement.sol";
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
}
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
    // Settlement public SET;
    Aux public AUX; 
    
    Metrics public coreMetrics;
    string public constant name = "QU!D";
    string public constant symbol = "QD";
    uint8 public constant decimals = 18;
    address payable public V4;

    struct Metrics {
        uint total;
        uint last;
        uint yield;
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
    mapping (address => bool) public winners;
    
    // Track everyone who has been a juror
    address[] public everVotedInJury;
    mapping(address => bool) public hasBeenJuror;
    
    // OPTIMIZED: Use SortedSetLib for vote values, store weights separately
    // epoch => stableIndex => SortedSet of vote values
    mapping(uint => mapping(uint => SortedSetLib.Set)) private voteSets;
    
    // epoch => stableIndex => voteValue => cumulative weight
    mapping(uint => mapping(uint => mapping(uint => uint))) private voteWeights;
    
    // Store total weight per epoch for validation
    mapping(uint => uint) public epochTotalWeight;

    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 // TODO uncomment
             || sender == address(AUX) /*
             || sender == address(SET) */, "404"); _;
    }

    function currentMonth() public view returns (uint month) { 
        month = (block.timestamp - _deployed) / 2420000; // ~28 days
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
        return BasketLib.matureBatches(batches, block.timestamp, _deployed);
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

    /*
    function setSettlement(address _settlement) external onlyUs {
        require(address(SET) == address(0), "set"); 
        SET = Settlement(_settlement);
    } */

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
                // Update concentrations after withdrawal
                _recomputeConcentrations(currentMonth());
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
                } else { 
                    // Update concentrations after partial withdrawal
                    _recomputeConcentrations(block.timestamp / 1 weeks);
                    return sent; 
                }
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
        } 
        vault = vaults[stables[stables.length - 1]];

        amounts[ghoIndex] = FullMath.mulDiv(amount, FullMath.mulDiv(
                            WAD, amounts[ghoIndex], amounts[0]), WAD);

        if (amounts[ghoIndex] > 0) {
            amount = IStakeToken(vault).previewStake(amounts[ghoIndex]);
            require(IStakeToken(vault).previewRedeem(amount) == amounts[ghoIndex], "sgho");
            IStakeToken(vault).redeem(who, amount); sent += amounts[ghoIndex];
        }
        // Update concentrations after multi-vault withdrawal
        _recomputeConcentrations(block.timestamp / 1 weeks);
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
        // Update concentrations after deposit
        _recomputeConcentrations(block.timestamp / 1 weeks);
    }

    function _mint(address receiver, uint id, uint amount) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, address(0), receiver, id, amount);
    } 

    // Basket.take() is not guaranteed to always have more than
    // the quantity of totalSupply() in dollars, because the ETH
    // that is in the Uniswap pool may at any point crash in price
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
            
            uint depositing = scale > 0 ? amount / (10 ** scale) : amount;

            uint paid = deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            
            // Apply 0.01% withholding (1 basis point) for NFT solvency
            uint withholding = amount / 10000; // 0.01% = 1/10000
            amount = amount - withholding;
            
            // Add yield after withholding
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
        } 
        uint allowed = _allowances[from][msg.sender];
        _allowances[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount, true);
    }

    // TODO redeem at any time but % distance to maturity is the 
    // discount against present value if you do that, full value
    // only if post maturity. 
    function turn(address from, uint value) onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from, address(0), value);
    }

    function _transferHelper(address from, address to, uint amount) 
        internal returns (uint sent) {
        uint[] memory batches = perMonth[from].getSortedSet();
        bool toZero = to == address(0);
        bool burning = toZero || to == V4;
        int i = toZero ? BasketLib.matureBatches(batches,
        block.timestamp, _deployed) : int(batches.length - 1);

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
        return true;
    }

    function vote(uint[] calldata _targets) external {
        uint epoch = currentMonth();
        require(_targets.length == stables.length, "Wrong length");
        require(lastVoteEpoch[msg.sender] < epoch, "Already voted");
        
        uint sum;
        for (uint i = 0; i < _targets.length; i++) {
            sum += _targets[i];
        } 
        require(sum == WAD, "Must sum to 100%");
        
        uint voterWeight = totalBalances[msg.sender];
        require(voterWeight > 0, "No voting power");
        
        lastVoteEpoch[msg.sender] = epoch;
        
        for (uint i = 0; i < stables.length; i++) {
            voteSets[epoch][i].insert(_targets[i]);
            voteWeights[epoch][i][_targets[i]] += voterWeight;
        }
        
        epochTotalWeight[epoch] += voterWeight;
        _recomputeConcentrations(epoch);
    }

    function _recomputeConcentrations(uint epoch) internal {
        // Check if there are any votes for this epoch
        if (epochTotalWeight[epoch] == 0) return;
        
        for (uint i = 0; i < stables.length; i++) {
            uint newTarget = _computeWeightedMedian(epoch, i);
            targets[stables[i]] = newTarget;
            
            // Exponential moving average using library
            uint alpha = 2e17;
            currentConcentrations[stables[i]] = BasketLib.updateConcentrationEMA(
                currentConcentrations[stables[i]],
                newTarget,
                alpha
            );
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
        
        for (uint i = 0; i < sortedVotes.length; i++) {
            uint voteValue = sortedVotes[i];
            uint weight = voteWeights[epoch][stableIndex][voteValue];
            cumulativeWeight += weight;
            
            if (cumulativeWeight >= halfWeight) {
                if (cumulativeWeight == halfWeight && i + 1 < sortedVotes.length) {
                    return (voteValue + sortedVotes[i + 1]) / 2;
                }
                return voteValue;
            }
        }
        
        return sortedVotes[sortedVotes.length - 1];
    }

    function sigmoidFee(uint actual, uint target, uint multiplier) public pure returns (uint fee18) {
        return BasketLib.sigmoidFee(actual, target, multiplier);
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
        
        uint target = currentConcentrations[stable];
        if (target == 0) {
            target = WAD / stables.length;
        }
        
        return BasketLib.calculateFee(
            normalizedCash,
            totalValue,
            target,
            isMinting,
            4e14 // multiplier
        );
    }
    
    address public constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405; // foundation
    
    function onERC721Received(address,
        address from, // previous owner...
        uint tokenId, bytes calldata data)
        external override nonReentrant returns (bytes4) { 
        if (tokenId == LAMBO && ICollection(F8N).ownerOf(
            LAMBO) == address(this)) { address winner;
            uint cut = KICKBACK / 6; // $111110 clif: 
            _mint(Rover(V4).owner(), 24, cut); // 2yr
            
            uint kickback = KICKBACK - cut; cut /= 2;
            ICollection(F8N).transferFrom( 
            address(this), from, LAMBO); // Return NFT to sender
            
            // Only proceed with lottery if we have jurors to select from
            if (everVotedInJury.length >= 10 && data.length >= 32) {
                bytes32 _seed = abi.decode(data[:32], (bytes32));
                uint distributed = 0;
                
                for (uint i = 0; distributed < 10 && i < 30; i++) {
                    uint random = uint(keccak256(
                        abi.encodePacked(_seed,
                        block.prevrandao, i))) %
                        everVotedInJury.length;
                    winner = everVotedInJury[random];
                    
                    // Check if this address has sufficient balance to be eligible
                    if (!winners[winner] && totalBalances[winner] >= 100e18) {
                        winners[winner] = true;
                        _mint(winner, 24, cut); // 2yr maturity
                        kickback -= cut;
                        distributed++;
                    } 
                }
            }
            // Any remaining kickback goes to the NFT sender
            if (kickback > 0) {
                _mint(from, 24, kickback);
            }
        } return this.onERC721Received.selector; 
    } 
    uint constant KICKBACK = 666666666666666666666666;
}