
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// import {AuxBase as Aux} from "./L2/AuxBase.sol";
// import {AuxPoly as Aux} from "./L2/AuxPoly.sol";
// import {AuxArb as Aux} from "./L2/AuxArb.sol";
// import {AuxUni as Aux} from "./L2/AuxUni.sol";

import {Aux} from  "./Aux.sol";
import {Hook} from "./Hook.sol";
import {UMA} from  "./UMA.sol";

import {Types} from "./imports/Types.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";
import {BasketLib} from "./imports/BasketLib.sol";

import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

contract Basket is ERC6909, ReentrancyGuard {
    using SortedSetLib for SortedSetLib.Set;
    uint constant WAD = 1e18; // dollarito
    address internal _deployer; // ricardo
    uint internal _deployed; // quidmint
    uint constant CAP = 500_000 * 1e18;
    uint public seeded; // seed round
    uint public target; // ^ backing

    bool public marketCreated;
    address payable public V4;
    uint public totalSupply;
    UMA public UMA_ORACLE;
    IERC20 public USDC;
    Hook public HOOK;
    Aux public AUX;

    // ERC20 compatibility events
    event ERC20Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    function name() external pure returns (string memory) { return "QU!D"; }
    function symbol() external pure returns (string memory) { return "QD"; }
    function decimals() external pure returns (uint8) { return 18; }
    mapping(address => mapping(address => uint)) public allowances;

    mapping(address => uint) public balances;
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public untouchables;

    // ─── wMedian: Haircut (1–9%, 25bps steps) ───
    // Prices depegged tokens below par in redemption.
    // TVL captures spread → stayers profit on re-peg.
    // index 0 = 9% haircut, index 32 = 1% haircut
    uint internal K = 28; // default 2% (200 bps)
    uint public SUM; uint[33] public WEIGHTS;

    uint internal TOTAL_WEIGHT; // incremental
    mapping(address => uint) public feeVotes;
    bool internal _medianDirty; // lazy recalc

    // stored as vote + 1 as done in Aux
    function _adjustWeight(address who,
        uint amount, bool adding) internal {
        uint v = feeVotes[who];
        if (v == 0) return;
        _medianDirty = true; uint idx = v - 1;
        if (adding) { WEIGHTS[idx] += amount;
            TOTAL_WEIGHT += amount;
            if (idx <= K) SUM += amount;
        } else { uint w = Math.min(
                     WEIGHTS[idx], amount);
            WEIGHTS[idx] -= w;
            TOTAL_WEIGHT -= w;
            if (idx <= K)
              SUM -= Math.min(SUM, w);
        }
    } function _calculateMedian()
        internal { uint mid = TOTAL_WEIGHT / 2;
        if (mid == 0) { SUM = 0; return; }
        while (K >= 1 && (SUM - WEIGHTS[K]) >= mid) {
                         SUM -= WEIGHTS[K]; K -= 1; }
        while (K < 32 && SUM < mid) { K += 1;
                         SUM += WEIGHTS[K]; }
    }

    function _update(address from,
        address to, uint amount) internal {
        if (from == address(0))
            totalSupply += amount;
        else { _adjustWeight(from,
                    amount, false);
        balances[from] -= amount; }
        if (to == address(0))
            totalSupply -= amount;
        else { balances[to] += amount;
               _adjustWeight(to,
                   amount, true);
        } if (_medianDirty) {
            _calculateMedian();
            _medianDirty = false;
        } emit ERC20Transfer(from, to, amount);
    }

    function _spendAllowance(address owner,
        address spender, uint value) internal {
        uint a = allowances[owner][spender];
        if (a != type(uint).max) //
            allowances[owner][spender] = a - value;
    }

    function approve(address spender,
        uint value) public returns (bool) {
        allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function auth(address who) public view returns (bool) {
        return who == address(AUX) || who == V4 // AAVEv3
            || who == address(HOOK); // vanilla horizons
    }

    function vote(uint voteIndex) external {
        require(voteIndex <= 32, "out of range");
        uint stake = balances[msg.sender];
        require(stake > 0, "no balance");
        _adjustWeight(msg.sender, stake, false);
        feeVotes[msg.sender] = voteIndex + 1;
        _adjustWeight(msg.sender, stake, true);
        _calculateMedian(); // x.com/QuidMint
        _medianDirty = false;
    }

    /// @notice in bps [100..900]
    function getHaircut() // 0.8.26
        external view returns // '26
        (uint) { return 900 - K * 25; }

    constructor(address _vogue, address _aux,
        address _uma, address _usdc) {
        _deployed = block.timestamp;
        AUX = Aux(payable(_aux));
        UMA_ORACLE = UMA(_uma);
        _deployer = msg.sender;
        V4 = payable(_vogue);
        USDC = IERC20(_usdc);
    }

    function setHook(address _hook)
      external { require(msg.sender == _deployer
              && address(HOOK) == address(0));
                  HOOK = Hook(payable(_hook));
    }

    mapping(address => SortedSetLib.Set) private perMonth;
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function totalMatureBalanceOf(address owner) // matured
        public view returns (uint total) { // redeemable quid
        uint[] memory batches = perMonth[owner].getSortedSet();
        int idx = BasketLib.matureBatches(batches,
                        block.timestamp, _deployed);

        if (idx < 0) return 0;
        for (int i = idx; i >= 0; i--)
            total += balanceOf[owner][batches[uint(i)]];
    }

    function turn(address from, uint value) external
        returns (uint sent, uint seedBurned) {
        require(auth(msg.sender));
        uint seedBefore = untouchables[from];
        sent = _transferHelper(from, address(0), value);
        seedBurned = seedBefore - untouchables[from];
    }

    function _mint(address receiver,
        uint when, uint amount)
        internal override {
        totalSupplies[when] += amount;
        perMonth[receiver].insert(when);
        _update(address(0), receiver, amount);
        balanceOf[receiver][when] += amount;
        emit Transfer(msg.sender, address(0),
                    receiver, when, amount);
    }

    function mint(address pledge,
        uint amount, address token,
        uint when) external nonReentrant
        returns (uint) { uint yield; // ибо
        uint nextMonth = currentMonth() + 1;
        // this is used by Vogue.withdraw()
        if (auth(msg.sender)) { _mint(pledge,
                    nextMonth, amount);
                         return amount;
        } uint deposited = AUX.deposit(
                 pledge, token, amount);

        if (!marketCreated && token == address(USDC)) {
            uint[13] memory deposits = AUX.get_deposits();
            // amounts[2] = USDC in AAVE, amounts[11] = USYC
            if (deposits[2] + deposits[11] >= 1_515e18) {
                address[] memory stables = AUX.getStables();
                uint bond = 1_515e6; bond = AUX.take(// $1515
                address(this), bond, address(USDC), 0);
                USDC.transfer(address(UMA_ORACLE), bond / 1e12);
                UMA_ORACLE.registerMarket(stables);
                HOOK.createMarket(stables);
                marketCreated = true;
            }
        } uint decimals = IERC20(token).decimals();
          uint normalized = decimals < 18 ? deposited
                * (10 ** (18 - decimals)) : deposited;

          uint month = Math.max(when, nextMonth);
          bool isSeed = month - nextMonth > 12 &&
                        month < 24 && seeded < CAP;
          if (isSeed) {
              yield = AUX.getAverageYield() * 2;
              month -= 1; seeded += normalized;
          } else { yield = AUX.getAverageYield();
          } normalized += FullMath.mulDiv(normalized * yield,
                           month - currentMonth(), WAD * 12);
          if (isSeed) { untouchables[pledge] += normalized;
                        target += normalized; }
          _mint(pledge, month, normalized); return normalized;

    }

    function transfer(address to,
        uint value) public returns (bool) {
        require(value == _transferHelper(msg.sender,
                          to, value)); return true;
    }

    function transferFrom(address from, address to,
                uint value) public returns (bool) {
             _spendAllowance(from, msg.sender, value);
        require(value == _transferHelper(from, to, value));
        return true;
    } // times flies...make a statement; take a stand
    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        uint[] memory batches = perMonth[from].getSortedSet();
        bool turning = to == address(0); int i = turning &&
            from != address(HOOK) ? BasketLib.matureBatches(
                batches, block.timestamp, _deployed):
                             int(batches.length - 1);

        require(balances[from] >= amount);
        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) {
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!turning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else
                    totalSupplies[k] -= amt;
                if (balanceOf[from][k] == 0)
                    perMonth[from].remove(k);
                amount -= amt; sent += amt;
            } i -= 1; // liable to be -1
        } // -1 means "no mature batches"
        if (sent > 0) { _update(from, to, sent);
            // ^ should burn from totalSupply
            // if necessary (to = address(0))
            if (untouchables[from] > 0) {
                uint seed = Math.min(sent,
                  untouchables[from]);

                untouchables[from] -= seed;
                if (to == address(0))
                    target -= Math.min(
                          target, seed);
                else
                    untouchables[to] += seed;
            }
        }
    }
}
