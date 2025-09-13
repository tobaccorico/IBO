// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from  "./Aux.sol";
import {Vogue} from  "./Vogue.sol";
import {BasketLib} from "./BasketLib.sol";

import "lib/forge-std/src/console.sol";
// TODO delete logging before mainnet...

import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
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

contract Basket is ERC6909 {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;
    
    uint private _deployed;
    uint private _totalSupply;
    uint constant WAD = 1e18;
    address[] public stables;
    Metrics public metrics;
    
    string public constant name = "QU!D";
    string public constant symbol = "QD";
    uint8 public constant decimals = 18;
    address payable public V4;
    
    Aux public AUX; 
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
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    
    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping(address => uint)) private _allowances;

    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 
             || sender == address(AUX), "404"); _;
    }

     function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }
    
    function currentWeek() public view returns (uint week) {
        week = (block.timestamp - _deployed) / BasketLib.WEEK + 1;
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

    constructor(address _rover, address _aux,
        address[] memory _stables, address[] memory _vaults) { 
        _deployed = block.timestamp; AUX = Aux(payable(_aux));
        require(_stables.length == _vaults.length, "align"); 
        address stable; address vault; stables = _stables;
        for (uint i = 0; i < _vaults.length; i++) {
            stable = _stables[i]; vault = _vaults[i];
            isVault[vault] = true; vaults[stable] = vault;
            isStable[stable] = true;
        }   V4 = payable(_rover);
    }

    function get_metrics(bool force) public returns (uint, uint) {
        Metrics memory stats = metrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            uint[10] memory amounts = get_deposits();
            stats.last = block.timestamp;
            stats.total = amounts[0];
            stats.yield = FullMath.mulDiv(WAD,
               amounts[9], amounts[0] - amounts[8]) - WAD;
            metrics = stats;
        } return (stats.total, stats.yield);
    }

    function collect() external {
        address vault = vaults[stables[stables.length-1]];
        IStakeToken(vault).claimRewards(
            Vogue(V4).owner(), type(uint).max);
    }

    function get_deposits() public view
        returns (uint[10] memory amounts) {
        address vault; uint shares;
        uint ghoIndex = stables.length - 1;
        for (uint i = 0; i < ghoIndex; i++) { 
            uint multiplier = i > 1 ? 1 : 1e12;
            vault = vaults[stables[i]];
            shares = perVault[vault].shares;
            
            if (shares > 0) {
                uint assets = IERC4626(vault).convertToAssets(shares);
                if (i == 0) {
                    uint untouchable = AUX.untouchable();
                    if (untouchable > assets) {
                        assets = 0;
                    } else {
                        assets -= untouchable;
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
            uint fee = 0;
            // uint fee = getFee(token, false, amount); NOTE
            if (fee > WAD / 10) fee = WAD / 10;
            
            uint amountNeeded;
            if (fee > 0) {
                amountNeeded = FullMath.mulDiv(
                        amount, WAD + fee, WAD);
            } else {    amountNeeded = amount; }
            if (max >= amountNeeded) {
                uint withdrawn = _withdraw(who, vault, amountNeeded);
                // Update concentrations after withdrawal
                // _recomputeConcentrations(currentWeek()); // NOTE
                if (fee > 0) {
                    return FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                } else {
                    return withdrawn;
                }
            } else { 
                uint withdrawn = _withdraw(who, vault, max);
                if (fee > 0) {
                    sent = FullMath.mulDiv(withdrawn, WAD - fee, WAD);
                } else {
                    sent = withdrawn;
                } amount -= withdrawn;
                if (!strict) {
                    sent = BasketLib.scaleTokenAmount(sent, token, true);
                    amount = BasketLib.scaleTokenAmount(amount, token, true);
                } else { 
                    // Update after partial withdrawal...
                    // _recomputeConcentrations(currentWeek()); // NOTE
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
                amounts[i] = _withdraw(who, vault, amounts[i]);
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
        // _recomputeConcentrations(currentWeek()); // NOTE 
    }  
   
   function _withdraw(address to,
        address vault, uint amount) 
        internal returns (uint sent) {
        (uint shares, uint assets) = BasketLib.calculateVaultWithdrawal(
                                                          vault, amount);
        require(assets == IERC4626(vault).redeem(shares, 
                to, address(this)), "$"); return assets;
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

    function _mint(address receiver,
        uint id, uint amount)
        internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, 
            address(0), receiver, 
            id, amount);
    } 

    // Basket.take() is not guaranteed to always have more than
    // the quantity of totalSupply() in dollars, because the ETH
    // that is in the Uniswap pool may at any point crash in price
    function mint(address pledge, uint amount, 
        address token, uint when) public {
        uint month = Math.max(when, 
                currentMonth() + 1);

        if (token == address(this)) {
            require(msg.sender == address(AUX), "403");
            _mint(pledge, month, amount);
        } else {
            uint depositing = BasketLib.scaleTokenAmount(
                                    amount, token, false);

            uint paid = deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            amount += FullMath.mulDiv(amount * yield,
                    month - currentMonth(), WAD * 12);
                         _mint(pledge, month, amount);
        } 
    } 

    function transferFrom(address from,
        address to, uint amount) public returns (bool) {
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
    function turn(address from, uint value) 
        onlyUs public returns (uint sent) {
        uint oldBalanceFrom = totalBalances[from];
        sent = _transferHelper(from, address(0), value);
    }

    function _transferHelper(address from,
        address to, uint amount) internal returns (uint sent) {
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
        uint value = _transferHelper(from,
                          to, amount); 
                          return true;
    }
}
