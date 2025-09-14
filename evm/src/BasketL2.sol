// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from  "./Aux.sol";
import {Vogue} from  "./Vogue.sol";
import {BasketLib} from "./BasketLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {AggregatorV3Interface} from "./imports/AggregatorV3Interface.sol";

interface ISCRVOracle { 
    function pricePerShare(uint ts) external view returns (uint);
}
interface IDSROracle {
    /**
     * @notice Get the binomial approximated conversion rate at a specified timestamp.
     * @dev    Timestamp must be greater than or equal to the current timestamp.
     * @param  timestamp The timestamp at which to retrieve the binomial approximated conversion rate.
     * @return The binomial approximated conversion rate.
     */
    function getConversionRateBinomialApprox(uint timestamp) external view returns (uint);

}

contract BasketL2 is ERC6909 {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;

    uint private _deployed;
    uint private _totalSupply;
    uint constant WAD = 1e18;
 
    IPool AAVE;
    Aux public AUX;
    struct Metrics {
        uint total;
        uint last;
        uint yield;
    }
    
    Metrics public metrics;
    IDSROracle internal DSR;
    ISCRVOracle internal CRV;
    
    address[] public stables;
    address payable public V4;
    
    string public constant name = "QU!D";
    string public constant symbol = "QD";
    uint8 public constant decimals = 18;
    
    mapping(address => uint) public deposits;
    mapping(address => uint) internal toIndex;
    mapping(address => address) public vaults;
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;

    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping(address => uint)) private _allowances;
    
    modifier onlyUs { require(msg.sender == V4 
             || msg.sender == address(AUX), "403");
        _;
    }

    constructor(address _aave, address _rover, address _aux,
        address[] memory _stables, address[] memory _vaults) { 
        _deployed = block.timestamp; AUX = Aux(payable(_aux));
    
        uint i = 0;
        for (i = 0; i < 5; i++) {
            vaults[_stables[i]] = _vaults[i];
            toIndex[_stables[i]] = i + 1;
        }
        for (i = 5; i < _stables.length; i++) { 
            toIndex[_stables[i]] = i + 1;
        } stables = _stables;
        V4 = payable(_rover);
        AAVE = IPool(_aave);

        DSR = IDSROracle(0x73750DbD85753074e452B2C27fB9e3B0E75Ff3B8);
        // Base: 0x65d946e533748A998B1f0E430803e39A6388f7a1
        CRV = ISCRVOracle(0x3195A313F409714e1f173ca095Dba7BfBb5767F7);
        // Base: 0x3d8EADb739D1Ef95dd53D718e4810721837c69c1    
    }
    
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }
    
    function currentWeek() public view returns (uint week) {
        week = (block.timestamp - _deployed) / BasketLib.WEEK + 1;
    }

    function totalSupply() 
        public view returns (uint) { return _totalSupply; }

    function transfer(address to, uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function matureBatches(uint[] memory batches) public view returns (int) {
        return BasketLib.matureBatches(batches, block.timestamp, _deployed);
    }
    
    function _getPrice(uint index) internal view returns (uint price) { 
        if (index == 10) { (, int answer,, uint ts,) = AggregatorV3Interface(
            // 0xdEd37FC1400B8022968441356f771639ad1B23aA // < Base (SUSDE)
            0x605EA726F0259a30db5b7c9ef39Df9fE78665C44).latestRoundData();
                                                     price = uint(answer);
            require(ts > 0 && ts <= block.timestamp, "link");
        } else if (index == 11) { // SCRVUSD
            price = CRV.pricePerShare(
                      block.timestamp);
        } else if (index == 9) { // SUSDS
            price = DSR.getConversionRateBinomialApprox(block.timestamp) / 1e9;
        }
        require(price >= WAD, "price");
    }

    function get_metrics(bool force) 
        public returns (uint, uint) {
        Metrics memory stats = metrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            uint[14] memory amounts = get_deposits(); 
            uint raw = amounts[0];
            stats.total = amounts[1];
            stats.last = block.timestamp; 
            stats.yield = raw > 0 ? FullMath.mulDiv(WAD, 
                                    stats.total, raw) - WAD : 0; 
            metrics = stats;
        } return (stats.total, 
                  stats.yield);
    } 

    // amounts[1] represents the total in terms of final $ worth (melt value)
    // amounts[0] represents the raw token units (so 1 sUSDS or 1 sUSDE = $1)
    function get_deposits() public view 
        returns (uint[14] memory amounts) { uint balance; uint i;
        amounts[2] = IERC4626(vaults[stables[0]]).maxWithdraw(
                                                address(this)) * 1e12;
        // FullMath.mulDiv(_getPrice(9), // special sUSDS vault on Base
        //    IERC4626(sUSDSvault).maxWithdraw(address(this)), WAD);
        amounts[3] = IERC4626(vaults[stables[1]]).maxWithdraw(
                                                address(this)) * 1e12;
        // first we aggregate raw amounts (pre-gains accounting)
        amounts[0] += deposits[stables[0]] + deposits[stables[1]];
        amounts[1] += amounts[2] + amounts[3]; // < gains accounted
        for (i = 2; i < 5; i++) { // DAI, FRAX, and GHO are aTokens
            balance = IERC20(vaults[stables[i]]).balanceOf(address(this));
            amounts[0] += deposits[stables[i]]; // raw token units
            amounts[1] += balance; // aTokens (principal + yield)
        }
        for (i = 5; i < 9; i++) { // USDE, USDS, CRVUSD, SFRAX... 
            balance = IERC20(stables[i]).balanceOf(address(this));
            amounts[i + 2] = balance; // the balance for given token
            amounts[0] += balance; // these tokens aren't deposited 
            amounts[1] += balance; // anywhere to earn extra yield
        } 
        for (i = 9; i < stables.length; i++) { 
            balance = IERC20(stables[i]).balanceOf(
                                     address(this)); 
            amounts[0] += balance;
            balance = FullMath.mulDiv(
            _getPrice(i), balance, WAD);
            
            amounts[1] += balance;
            amounts[i + 2] = balance;
        }
        // amounts[1] should be higher than
    } // amounts[0] so their ratio gives us 
    // the total APY % of the whole basket

    // instead of unwrapping locally, give 
    // preferentially to the basket tokens
    // from the Arb, Base, Polygon baskets
    function take(address who, uint amount,
        address token, bool strict) public
        onlyUs returns (uint sent) { // TODO
        if (token != address(this)) { // on L1
            uint index = toIndex[token];
            uint max; address vault;
            if (index < 3) { vault = vaults[token];
                max = IERC4626(vault).maxWithdraw(
                                    address(this));
            
                if (token == stables[0] && !strict) 
                    max -= AUX.untouchable();
            } 
            else if (index < 6) { vault = vaults[token];
                max = IERC20(vault).balanceOf(address(this));
            }
             
            uint fee = 0;
            // uint fee = getFee(token, false, amount); // NOTE: must implement 
            (uint needed, uint received) = BasketLib.processWithdrawalWithFee(
                                                             amount, max, fee);
            deposits[token] -= Math.min(
                deposits[token], needed);

            if (max >= needed) {
                if (index < 3) {
                    sent = _withdraw(who,
                       vault, needed);
                } else {
                    if (index < 6) {
                        needed = AAVE.withdraw(token, needed,
                                               address(this));
                    } IERC20(token).transfer(
                                 who, needed);
                                sent = needed;
                } // _recomputeConcentrations(currentWeek());
                // NOTE: must implement
                return fee > 0 ? FullMath.mulDiv(
                            sent, WAD - fee, WAD) : sent;
            } else {
                if (index < 3) { sent = _withdraw(who, 
                                        vault, max);
                } else {
                    if (index < 6) {
                        AAVE.withdraw(token, max,
                                    address(this));
                    }
                    IERC20(token).transfer(who, max);
                    sent = max;
                }
                if (strict) { // _recomputeConcentrations(currentWeek());
                    return fee > 0 ? FullMath.mulDiv(sent, WAD - fee, WAD) : sent;
                }   amount -= sent;
                
                sent = fee > 0 ? FullMath.mulDiv(sent, WAD - fee, WAD) : sent;

            }
            sent = BasketLib.scaleTokenAmount(sent, token, true);
        } 
        uint mid = stables.length / 2 - 1; uint i;
        uint[14] memory amounts = get_deposits();
        
        // NOTE: we don't need to _recomputeConcentrations(currentWeek());
        // because the amounts will be decreased proportionally after this,
        // meaning that their relative concentrations will not change at all

        /* sent += withdraw(who, valuts[stables[9]], FullMath.mulDiv(amount, 
            FullMath.mulDiv(WAD, amounts[11], amounts[1]), WAD)); */ // Base
        
        for (i = 0; i < 2; i++) {
            amounts[i + 2] = FullMath.mulDiv(amount, FullMath.mulDiv(WAD, 
            amounts[i + 2], amounts[1]), WAD) / 1e12; // 1e6 precision...
            sent += _withdraw(who, vaults[stables[i]], amounts[i + 2]) * 1e12;
            // ^ normalised to be 1e18 despite two 1e6 precisions (USDC & USDT)
        }    
        for (i = 2; i < mid; i++) {
            amounts[i + 2] = AAVE.withdraw(address(stables[i]), 
                                amounts[i + 2], address(this));

            sent += amounts[i + 2];
            IERC20(stables[i]).transfer(
                    who, amounts[i + 2]);
        }
        for (i = mid; i < stables.length; i++) {
            amounts[i + 2] = FullMath.mulDiv(amount, FullMath.mulDiv(
                               WAD, amounts[i + 2], amounts[1]), WAD);
            
            sent += amounts[i + 2];
            IERC20(stables[i]).transfer(
                    who, amounts[i + 2]);
        }
    } 

    function _withdraw(address to,
        address vault, uint amount) 
        internal returns (uint sent) { // sent is 1e16 for USDC and USDT
        (uint shares, uint assets) = BasketLib.calculateVaultWithdrawal(
                                                          vault, amount);
        require(assets == IERC4626(vault).redeem(shares, 
                to, address(this)), "$!"); return assets;
    }

    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        uint index = toIndex[token];
        require(index > 0, "$?");        
        usd = Math.min(amount, 
        IERC20(token).allowance(
            from, address(this)));
        IERC20(token).transferFrom(
            from, address(this), usd);
        
        deposits[token] += BasketLib.scaleTokenAmount(
                                     usd, token, true);
        if (index < 3) { // for Base add || index == 10
            IERC20(token).approve(vaults[token], usd);
            IERC4626(vaults[token]).deposit(usd, 
                              address(this));
        } 
        else if (index < 6) { // DAI, FRAX, GHO in AAVE
            AAVE.supply(token, usd, address(this), 0);
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
        emit Transfer(msg.sender, address(0),
                       receiver, id, amount);
    }

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
            
            deposit(pledge, token, depositing);
            (uint total, uint yield) = get_metrics(false);
            
            amount += FullMath.mulDiv(amount * yield,
                month - currentMonth(), WAD * 12);
                     _mint(pledge, month, amount);
        }
    }

    function transferFrom(address from,
        address to, uint amount)
        public returns (bool) {
        if (msg.sender != from && !isOperator[from][msg.sender]) {
            require(to != V4 || msg.sender == V4, "403");
            uint allowed = _allowances[from][msg.sender];
            if (allowed != type(uint).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount);
    }

    function turn(address from, 
        uint value) onlyUs public returns (uint) {
        return _transferHelper(from, address(0), value);
    }
    
    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        uint[] memory batches = perMonth[from].getSortedSet();
        bool burning = to == address(0) || to == V4;
        int i = to == address(0) ?
            BasketLib.matureBatches(batches,
                block.timestamp, _deployed) :
                    int(batches.length - 1);
        
        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = Math.min(amount,
             balanceOf[from][k]);
            if (amt > 0) {
                balanceOf[from][k] -= amt;
                if (!burning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else {
                    totalSupplies[k] -= amt;
                }
                if (balanceOf[from][k] == 0) {
                    perMonth[from].remove(k);
                }   amount -= amt;
                    sent += amt;
            } i--;
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

    function _transfer(address from, 
        address to, uint amount)
        internal returns (bool) {
        _transferHelper(from,
            to, amount);
            return true;
    }
} 
