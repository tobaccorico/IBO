
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Router} from  "./Router.sol";
import {Auxiliary} from  "./Auxiliary.sol";

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
} // these two Oracle contracts are only used on L2
import {IDSROracle} from "./imports/IDSROracle.sol";

contract BasketL2 is ERC6909 { // Base
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;

    uint private _deployed;
    uint private _totalSupply;
    address[] public STABLES;
    Auxiliary public AUX; 
    
    Metrics public coreMetrics;
    IDSROracle internal DSR;
    ISCRVOracle internal CRV;
    
    string private _name = "QU!D";
    string private _symbol = "QD";
    address payable public V4;
    uint constant WAD = 1e18;

    struct Metrics {
        uint last; uint total; uint yield;
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
    mapping(address => mapping( // legacy IERC20 version
            address => uint256)) private _allowances;

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
        return _transfer(msg.sender, to, amount);
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
        
        AUX = Auxiliary(payable(_aux));
        V4 = payable(_router);
        
        // the following oracles are needed on L2 in absence of 4626
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
    } // function used only on Base...

    // if force is false just return
    // the most recent known metrics 
    // without recalculating them...
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

    function take(address who, // on whose behalf
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
            if (max >= amount) {
                if (vault != address(0)) {
                    withdraw(who, vault, amount);
                }
                else {
                    IERC20(token).transfer(who, amount);
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
                } else return max;
            }
        } uint[9] memory amounts = get_deposits();
        
        sent += withdraw(who, USDCvault, FullMath.mulDiv(amount, 
            FullMath.mulDiv(WAD, amounts[1], amounts[0]), WAD));

        sent += withdraw(who, sUSDSvault, FullMath.mulDiv(amount, 
            FullMath.mulDiv(WAD, amounts[2], amounts[0]), WAD));

        for (uint i = 3; i < 9; i++) {
            amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                WAD, amounts[i], amounts[0]), WAD);
            IERC20(STABLES[i - 3]).transfer(who, amounts[i]);
            sent += amounts[i];
        }
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
            IERC20(token).transferFrom(
                from, address(this), usd);
            
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
        } return _transfer(from, to, amount);
    }

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
                    // ^ this does nothing if
                    // k is already in sorted
                    // set for this address
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
        uint amount) internal returns (bool) {
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(from, 
                          to, amount);
                          return true;
    }
}
