// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rover} from  "./Rover.sol";
import {Aux} from  "./Aux.sol";
import {BasketLib} from "./BasketLib.sol";

import "lib/forge-std/src/console.sol";
// TODO delete logging before mainnet...

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {AggregatorV3Interface} from "./imports/AggregatorV3Interface.sol";

interface ISCRVOracle { 
    function pricePerShare(uint ts) 
    external view returns (uint);
}
import {IDSROracle} from "./imports/IDSROracle.sol";

contract BasketL2 is ERC6909 { // Base
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;

    uint private _deployed;
    uint private _totalSupply;
    address[] public STABLES;
    Aux public AUX; 
    
    Metrics public coreMetrics;
    IDSROracle internal DSR;
    ISCRVOracle internal CRV;
    
    string public constant name = "QU!D";
    string public constant symbol = "QD";
    uint8 public constant decimals = 18;
    address payable public V4;
    uint constant WAD = 1e18;

    struct Metrics {
        uint total;
        uint last;
        uint yield;
    }
    
    address immutable USDC;
    address immutable DAI;
    
    address immutable USDS;
    address immutable SUSDS;
    
    address immutable USDE; 
    address immutable SUSDE;
    
    address immutable CRVUSD;
    address immutable SCRVUSD;
    
    address immutable USDCvault;
    address immutable sUSDSvault;

    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    
    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping(
            address => uint)) private _allowances;

    // Voting and rebalancing features
    uint public latest_holder = 0;
    mapping(uint => address) public holders;
    mapping(address => uint) public holder_to_id;
    
    mapping(address => uint) public currentConcentrations;
    mapping(address => uint) public targets;
    
    mapping(address => uint) public lastVoteEpoch;
    
    // OPTIMIZED: Use SortedSetLib for vote values, store weights separately
    mapping(uint => mapping(uint => SortedSetLib.Set)) private voteSets;
    mapping(uint => mapping(uint => mapping(uint => uint))) private voteWeights;
    mapping(uint => uint) public epochTotalWeight;

    modifier onlyUs {
        address sender = msg.sender;
        require(sender == V4 ||
                sender == address(AUX), "403"); _;
    }

    function currentMonth() public view returns
        (uint month) { month = (block.timestamp -
                      _deployed) / 2420000; // ~28 days
    }

    function totalSupply() public 
        view returns (uint) {
        return _totalSupply;
    }

    function transfer(address to,
        uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, 
        uint value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function matureBatches(uint[] memory batches)
        public view returns (int i) {
        return BasketLib.matureBatches(batches, block.timestamp, _deployed);
    }

    constructor(address _router, address _aux, 
        address vaultUSDC, address vaultSUSDS,
        address usdc, address dai,
        address usds, address susds,
        address usde, address susde, 
        address crvusd, address srcvusd) { 
        _deployed = block.timestamp;

        USDCvault = vaultUSDC; 
        sUSDSvault = vaultSUSDS;
    
        USDC = usdc; DAI = dai;
        STABLES.push(dai);
        STABLES.push(usds);
        USDS = usds; SUSDS = susds;
        
        USDE = usde; SUSDE = susde;
        STABLES.push(usde);
        STABLES.push(susde);
        
        CRVUSD = crvusd; SCRVUSD = srcvusd;
        STABLES.push(crvusd);
        STABLES.push(srcvusd);
        
        AUX = Aux(payable(_aux));
        V4 = payable(_router);
        
        // Initialize equal weight concentrations
        uint equalWeight = WAD / 6; // 6 stables in L2
        currentConcentrations[DAI] = equalWeight;
        currentConcentrations[USDS] = equalWeight;
        currentConcentrations[USDE] = equalWeight;
        currentConcentrations[SUSDE] = equalWeight;
        currentConcentrations[CRVUSD] = equalWeight;
        currentConcentrations[SCRVUSD] = equalWeight;
        targets[DAI] = equalWeight;
        targets[USDS] = equalWeight;
        targets[USDE] = equalWeight;
        targets[SUSDE] = equalWeight;
        targets[CRVUSD] = equalWeight;
        targets[SCRVUSD] = equalWeight;
        
        DSR = IDSROracle(0x65d946e533748A998B1f0E430803e39A6388f7a1); 
        // 0xEE2816c1E1eed14d444552654Ed3027abC033A36 // <----- Arbitrum
        CRV = ISCRVOracle(0x3d8EADb739D1Ef95dd53D718e4810721837c69c1);
        // 0x3195A313F409714e1f173ca095Dba7BfBb5767F7 // <----- Arbitrum
    }
    
    function _getPrice(address token) internal 
        view returns (uint price) { // L2 only
        if (token == SUSDE) { 
            (, int answer,, uint ts,) = AggregatorV3Interface(
                    0xdEd37FC1400B8022968441356f771639ad1B23aA).latestRoundData();
                 // 0x605EA726F0259a30db5b7c9ef39Df9fE78665C44 // ARB
            price = uint(answer); require(ts > 0 
                && ts <= block.timestamp, "link");
            
        } else if (token == SCRVUSD) { 
            price = CRV.pricePerShare(block.timestamp);
        } 
        else if (token == SUSDS) {
            price = DSR.getConversionRateBinomialApprox() / 1e9;
        }
        require(price >= WAD, "price");
    }

    function get_metrics(bool force)
        public returns (uint, uint) {
        Metrics memory stats = coreMetrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            uint[9] memory amounts = get_deposits();
            
            uint raw = IERC4626(USDCvault).balanceOf(address(this)) 
                     + IERC4626(sUSDSvault).balanceOf(address(this)) 
                     + IERC20(DAI).balanceOf(address(this))
                     + IERC20(USDS).balanceOf(address(this))
                     + IERC20(USDE).balanceOf(address(this))
                     + IERC20(SUSDE).balanceOf(address(this))
                     + IERC20(CRVUSD).balanceOf(address(this))
                     + IERC20(SCRVUSD).balanceOf(address(this));

            stats.last = block.timestamp;
            stats.total = amounts[0];
            stats.yield = FullMath.mulDiv(WAD,
                          amounts[0], raw) - WAD;
            coreMetrics = stats; 
        } 
        return (stats.total, stats.yield);
    }

    function get_deposits() public view
        returns (uint[9] memory amounts) {
        
        amounts[1] = FullMath.mulDiv(_getPrice(SUSDS), 
            IERC4626(sUSDSvault).maxWithdraw(
                                address(this)), WAD);
                    
        amounts[2] = IERC4626(USDCvault).maxWithdraw(
                                        address(this)) * 1e12;   
        amounts[3] = IERC20(DAI).balanceOf(address(this));
        amounts[4] = IERC20(USDS).balanceOf(address(this));

        amounts[5] = IERC20(USDE).balanceOf(address(this));
        amounts[6] = FullMath.mulDiv(_getPrice(SUSDE),
        IERC20(SUSDE).balanceOf(address(this)), WAD);

        amounts[7] = IERC20(CRVUSD).balanceOf(address(this));
        amounts[8] = FullMath.mulDiv(_getPrice(SCRVUSD),
        IERC20(SCRVUSD).balanceOf(address(this)), WAD);

        for (uint i = 1; i < 9; i++) {
            amounts[0] += amounts[i];
        }
    } 

    function take(address who,
        uint amount, address token, bool strict) 
        public onlyUs returns (uint sent) { 
        if (token != address(this)) { 
            uint max; address vault = address(0);
            if (token == USDC) { vault = USDCvault;
                max = IERC4626(USDCvault).maxWithdraw(
                                        address(this));
                max -= !strict ? AUX.untouchable() : 0;
            } 
            else if (token == SUSDS) { vault = sUSDSvault;
                max = IERC4626(sUSDSvault).maxWithdraw(
                                         address(this));
            }
            else {
                max = IERC20(token).balanceOf(address(this));
            }
            
            uint fee = getFee(token, false, amount);
            uint amountNeeded = amount;
            if (fee > 0 && fee < WAD / 10) {
                amountNeeded = FullMath.mulDiv(amount, WAD + fee, WAD);
            }
            
            if (max >= amountNeeded) {
                if (vault != address(0)) {
                    uint withdrawn = withdraw(who, vault, amountNeeded);
                    _recomputeConcentrations(block.timestamp / 1 weeks);
                    if (fee > 0) {
                        return FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                    }
                    return withdrawn;
                }
                else {
                    IERC20(token).transfer(who, amountNeeded);
                    _recomputeConcentrations(block.timestamp / 1 weeks);
                    if (fee > 0) {
                        return FullMath.mulDiv(amountNeeded, WAD - fee, WAD);
                    }
                    return amountNeeded;
                }
            } else {
                if (vault != address(0)) {
                    max = withdraw(who, vault, max);
                }
                amount -= max; 
                if (!strict) {
                    uint scale = 18 - IERC20(token).decimals();
                    if (scale > 0) {
                        amount *= 10 ** scale;
                        max *= 10 ** scale;
                    }   sent = max;
                } else {
                    _recomputeConcentrations(block.timestamp / 1 weeks);
                    return max;
                }
            }
        } uint[9] memory amounts = get_deposits();
        
        sent += withdraw(who, USDCvault, FullMath.mulDiv(amount, 
            FullMath.mulDiv(WAD, amounts[2], amounts[0]), WAD));

        sent += withdraw(who, sUSDSvault, FullMath.mulDiv(amount, 
            FullMath.mulDiv(WAD, amounts[1], amounts[0]), WAD));

        for (uint i = 3; i < 9; i++) {
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                WAD, amounts[i], amounts[0]), WAD);
            IERC20(STABLES[i - 3]).transfer(who, amounts[i]);
            sent += amounts[i];
        }
        _recomputeConcentrations(block.timestamp / 1 weeks);
    }

    function withdraw(address to, address vault, uint amount) internal returns (uint sent) {
        uint sharesWithdrawn = Math.min(IERC4626(vault).balanceOf(address(this)),
                                        IERC4626(vault).convertToShares(amount));

        sent = IERC4626(vault).convertToAssets(sharesWithdrawn);
        require(sent == IERC4626(vault).redeem(sharesWithdrawn, to,
                                            address(this)), "draw");
    }

    function isStable(address token) 
        public view returns (bool) {
        return token == USDC ||  token == DAI ||
               token == USDS || token == SUSDS || 
               token == USDE || token == SUSDE ||
               token == CRVUSD || token == SCRVUSD;
    }

    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        if (isStable(token)) {
            usd = Math.min(amount, 
            IERC20(token).allowance(
                from, address(this)));
            
            uint fee = getFee(token, true, usd);
            uint totalNeeded = usd;
            if (fee > 0 && fee < WAD / 10) {
                totalNeeded = FullMath.mulDiv(usd, WAD + fee, WAD);
                require(totalNeeded <= IERC20(token).allowance(from, address(this)), 
                    "insufficient allowance for fee");
            }
            
            IERC20(token).transferFrom(
                from, address(this), totalNeeded);
            
            require(usd >= 50 * (10 ** 
            IERC20(token).decimals()), "grant");
        } else {
            require(false, "unsupported token");
        }
        if (token == USDC) {
            IERC20(USDC).approve(USDCvault, usd);
            IERC4626(USDCvault).deposit(usd, 
                          address(this));
        } 
        else if (token == SUSDS) {
            IERC20(SUSDS).approve(sUSDSvault, usd);
            IERC4626(sUSDSvault).deposit(usd, 
                           address(this));
        }
        _recomputeConcentrations(block.timestamp / 1 weeks);
    }

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
            id, amount);
    }

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
            }
            
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
            uint allowed = _allowances[from][msg.sender];
            if (allowed != type(uint).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount);
    }

    function turn(address from,
        uint value) onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from,
                address(0), value);
    }

    function _transferHelper(address from, 
        address to, uint amount) 
        internal returns (uint sent) {
        uint[] memory batches = perMonth[from].getSortedSet();
        bool toZero = to == address(0);
        bool burning = toZero || to == V4;
        int i = toZero ?
            BasketLib.matureBatches(batches, block.timestamp, _deployed) :
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

    function _transfer(address from, address to,
        uint amount) internal returns (bool) {
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(from, 
                          to, amount);
        return true;
    }

    function vote(uint[] calldata _targets) external {
        uint epoch = currentMonth();
        require(_targets.length == STABLES.length, "Wrong length");
        require(lastVoteEpoch[msg.sender] < epoch, "Already voted");
        
        uint sum;
        for (uint i = 0; i < _targets.length; i++) {
            sum += _targets[i];
        } 
        require(sum == WAD, "Must sum to 100%");
        
        uint voterWeight = totalBalances[msg.sender];
        require(voterWeight > 0, "No voting power");
        
        lastVoteEpoch[msg.sender] = epoch;
        
        for (uint i = 0; i < STABLES.length; i++) {
            voteSets[epoch][i].insert(_targets[i]);
            voteWeights[epoch][i][_targets[i]] += voterWeight;
        }
        
        epochTotalWeight[epoch] += voterWeight;
        _recomputeConcentrations(epoch);
    }

    function _recomputeConcentrations(uint epoch) internal {
        if (epochTotalWeight[epoch] == 0) return;
        
        for (uint i = 0; i < STABLES.length; i++) {
            uint newTarget = _computeWeightedMedian(epoch, i);
            targets[STABLES[i]] = newTarget;
            
            uint alpha = 2e17;
            currentConcentrations[STABLES[i]] = BasketLib.updateConcentrationEMA(
                currentConcentrations[STABLES[i]],
                newTarget,
                alpha
            );
        }
    }

    function _computeWeightedMedian(uint epoch, uint stableIndex) internal view returns (uint) {
        uint[] memory sortedVotes = voteSets[epoch][stableIndex].getSortedSet();
        
        if (sortedVotes.length == 0) {
            return WAD / STABLES.length; 
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

    function sigmoidFee(uint actual, 
        uint target, uint multiplier) public pure returns (uint fee18) {
        return BasketLib.sigmoidFee(actual, target, multiplier);
    }

    function getFee(address token, 
        bool isMinting, uint amount) 
        public view returns (uint fee18) {
        uint tokenBalance;
        if (token == USDC) {
            tokenBalance = IERC4626(USDCvault).maxWithdraw(address(this)) * 1e12;
        } else if (token == SUSDS) {
            tokenBalance = FullMath.mulDiv(_getPrice(SUSDS),
                IERC4626(sUSDSvault).maxWithdraw(address(this)), WAD);
        } else if (token == SUSDE) {
            tokenBalance = FullMath.mulDiv(_getPrice(SUSDE),
                IERC20(SUSDE).balanceOf(address(this)), WAD);
        } else if (token == SCRVUSD) {
            tokenBalance = FullMath.mulDiv(_getPrice(SCRVUSD),
                IERC20(SCRVUSD).balanceOf(address(this)), WAD);
        } else {
            tokenBalance = IERC20(token).balanceOf(address(this));
        }
        
        uint[9] memory deposits = get_deposits();
        uint totalValue = deposits[0];
        
        uint target = currentConcentrations[token];
        if (target == 0) {
            target = WAD / STABLES.length;
        }
        
        return BasketLib.calculateFee(
            tokenBalance,
            totalValue,
            target,
            isMinting,
            4e14 // multiplier: 0.04% (4 basis points)
        );
    }
}