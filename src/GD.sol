
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25; // EVM: london
import "lib/forge-std/src/console.sol"; // TODO delete logging before mainnet
import {MorphoBalancesLib} from "./imports/morpho/libraries/MorphoBalancesLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {AggregatorV3Interface} from "./imports/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {IMorpho, MarketParams} from "./imports/morpho/IMorpho.sol";
// import {OFTOwnable2Step} from "./imports/OFTOwnable2Step.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {FullMath} from "./imports/math/FullMath.sol";
import {IDSROracle} from "./imports/IDSROracle.sol";
interface ISCRVOracle { // these two only used on L2
    function pricePerShare(uint ts) 
    external view returns (uint);
}
interface ICollection is IERC721 {
    function latestTokenId()
    external view returns (uint);
} // only used on Ethereum L1
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
} // in the windmills of my mind
import "./Mindwill.sol";
// he's bad, and she's
contract Good is ERC20, // OFTOwnable2Step, 
    IERC721Receiver, ReentrancyGuard { 
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;
    uint public ROI; uint public START;
    // "Walked in the kitchen, found a
    // [Pod] to [Piscine]" ~ 2 tune chi
    Pod[43][24] Piscine; // 24 batches
    uint constant PENNY = 1e16; // in
    // for a penny...in for a pound...
    uint constant LAMBO = 16508; // NFT
    bytes32 public immutable ID; // Morph
    uint constant public DAYS = 42 days;
    uint public START_PRICE = 50 * PENNY;
    struct Pod { uint credit; uint debit; }
    mapping(address => Pod) internal perVault;
    mapping(address => address) internal vaults;
    mapping (address => bool[24]) public hasVoted;
    // token-holders vote for deductibles, their
    // GD balances are applied to total weights
    // for voted % (weights are the balances)
    uint public deployed; uint internal K = 28;
    uint public SUM; uint[33] public WEIGHTS;
    mapping (address => uint) public feeVotes;
    address[][24] public voters; // by batch
    mapping (address => bool) public winners;
    // ^ the mapping prevents duplicates...
    address payable public Mindwill; 
    address public immutable SCRVUSD;
    address public immutable CRVUSD;
    address public immutable SFRAX;
    address public immutable SUSDS;
    address public immutable USDS;
    address public immutable SDAI;
    address public immutable DAI;
    address public immutable USDC;
    address public immutable USDE;
    address public immutable FRAX;
    address public immutable SUSDE;
    address public immutable VAULT;
    // ^ Morpho curated USDC vault
    IDSROracle internal DSR;
    ISCRVOracle internal CRV;
    uint constant WAD = 1e18;
    modifier onlyUs { // the good
        // and the batter Mindwill
        address sender = msg.sender;
        require(sender == Mindwill ||
                sender == address(this), "!?"); _;
    } constructor(address _mo, address _usdc, 
        address _vault, bytes32 _morpho,
        address _usde, address _susde, 
        address _frax, address _sfrax,
        address _sdai, address _dai,
        address _usds, address _susds,
        address _crv, address _scrv)
        /* OFTOwnable2Step("QU!D", "QZ", 
        LZ, QUID) { VAULT = _vault; */
        ERC20("QU!D", "GD", 18) { // $
        START = block.timestamp; // now
        VAULT = _vault; ID = _morpho;
        deployed = START; USDC = _usdc; 
        SDAI = _sdai; DAI = _dai;
        SUSDE = _susde; USDS = _usds; 
        USDE = _usde; SUSDS = _susds;
        CRVUSD = _crv; SCRVUSD = _scrv; 
        FRAX = _frax; SFRAX = _sfrax; 
        vaults[DAI] = SDAI;
        vaults[USDC] = VAULT; 
        vaults[USDE] = SUSDE; 
        vaults[USDS] = SUSDS; 
        vaults[CRVUSD] = SCRVUSD;
        Mindwill = payable(_mo);
        ERC20(USDC).approve(VAULT, type(uint).max);
        if (address(MO(Mindwill).token0()) == USDC) {
            require(address(MO(Mindwill).token1())
            == address(MO(Mindwill).WETH9()), "42");
            vaults[FRAX] = SFRAX; // TODO fip-420...
            ERC20(USDS).approve(SUSDS, type(uint).max);
            ERC20(CRVUSD).approve(SCRVUSD, type(uint).max);
            ERC20(USDE).approve(SUSDE, type(uint).max);
            ERC20(DAI).approve(SDAI, type(uint).max);
            ERC20(FRAX).approve(SFRAX,  type(uint).max);
            ERC4626(SUSDE).approve(MORPHO, type(uint).max);
            ERC20(DAI).approve(MORPHO, type(uint).max);
        } else { require(address(MO(Mindwill).token1())
            == USDC && address(MO(Mindwill).token0())
            == address(MO(Mindwill).WETH9()), "42"); 
            ERC20(SUSDE).approve(MORPHO, type(uint).max); // deployed 
            ERC20(USDC).approve(MORPHO, type(uint).max); // on Base...
            DSR = IDSROracle(0x65d946e533748A998B1f0E430803e39A6388f7a1); // only Base
            CRV = ISCRVOracle(0x3d8EADb739D1Ef95dd53D718e4810721837c69c1);
            // ^ 0x3d8EADb739D1Ef95dd53D718e4810721837c69c1 // <----- Base
            //  0x3195A313F409714e1f173ca095Dba7BfBb5767F7 // <----- Arbitrum
        } // but when a prince briskly declares himself in favour of one side, 
        // if the side you choose is the winner then you have a good friend
        // who is indebted to you; it’s true that the winner may be powerful 
        // enough to have
    } uint constant GRIEVANCES = 113310303333333333333333;
    uint constant CUT = 4920121799152111; // over 3 years
    uint constant KICKBACK = 666666666666666666666666;
    mapping(address => uint[24]) public consideration;
    // https://www.law.cornell.edu/wex/consideration
    // of legally sufficient value, bargained-for in 
    // an exchange agreement, for the breach of which
    // Mindwill gives an equitable remedy, and whose 
    // performance is recognised as reasonable duty
    // or tender (an unconditional offer to perform)
    uint constant public MAX_PER_DAY = 777_777 * WAD;
    
    function get_total_deposits
        (bool usdc) public view
        // this is only *part* of the captalisation()
        returns (uint total) { // handle USDC first
        // TODO on Arbitrum there is no vault yet...
        total += usdc ? ERC4626(VAULT).maxWithdraw(
                          address(this)) * 1e12 : 0;
        if (!MO(Mindwill).token1isWETH()) { // L2
            // total += perVault[FRAX].debit; // ARB only
            total += perVault[USDE].debit;
            total += FullMath.mulDiv(_getPrice(SUSDE),
                        perVault[SUSDE].debit, WAD);
            total += FullMath.mulDiv(_getPrice(SUSDS),
                        perVault[SUSDS].debit, WAD);
            total += perVault[USDS].debit;
            total += perVault[DAI].debit;
            total += perVault[CRVUSD].debit;
            total += FullMath.mulDiv(_getPrice(SCRVUSD),
                        perVault[SCRVUSD].debit, WAD); 
        } /* TODO uncomment for Ethereum L1 mainnet */
        else { // includes collateral deployed in ID,
            // as Pod.credit, initially only for SUSDE,
            // maxWithdraw represents the minimum value
            total += FullMath.max(ERC4626(SUSDE).convertToAssets(
                perVault[SUSDE].debit + perVault[SUSDE].credit), 
                     ERC4626(SUSDE).maxWithdraw(address(this)));
            total += FullMath.max(ERC4626(SUSDS).convertToAssets(
                perVault[SUSDS].debit + perVault[SUSDS].credit), 
                     ERC4626(SUSDS).maxWithdraw(address(this)));
            total += FullMath.max(ERC4626(SDAI).convertToAssets(
                perVault[SDAI].debit + perVault[SDAI].credit), 
                     ERC4626(SDAI).maxWithdraw(address(this)));
            total += FullMath.max(ERC4626(SFRAX).convertToAssets(
                perVault[SFRAX].debit + perVault[SFRAX].credit), 
                     ERC4626(SFRAX).maxWithdraw(address(this)));
            total += FullMath.max(ERC4626(SCRVUSD).convertToAssets(
                perVault[SCRVUSD].debit + perVault[SUSDS].credit), 
                     ERC4626(SCRVUSD).maxWithdraw(address(this)));    
        } // commented out for compilation purposes (less bytecode)
    } // TODO figure out which one of these causing issues
    function _deposit(address from,
        address token, uint amount)
        internal returns (uint usd) {
        bool l1 = MO(Mindwill).token1isWETH();
        bool isDollar = false; // $ is ^ on l2
        if (token == SCRVUSD || // token == SFRAX || TODO 
            token == SUSDS || // token == SDAI || L1...
            token == SUSDE) { isDollar = true;
            if (l1) { amount = FullMath.min(
                    ERC4626(token).allowance(
                        from, address(this)),
                    ERC4626(token).convertToShares(amount));
                usd = ERC4626(token).convertToAssets(amount);
                      ERC4626(token).transferFrom(msg.sender,
                                      address(this), amount);
            } else { uint price = _getPrice(token); amount = 
                FullMath.min(ERC20(token).balanceOf(from),
                FullMath.mulDiv(amount, WAD, price)); usd = 
                FullMath.mulDiv(amount, price, WAD);
            }   perVault[token].debit += amount;
        } else if (token == DAI  || token == USDS ||
                   token == USDC || // token == FRAX || 
                   token == USDE || token == CRVUSD) {
                   isDollar = true; usd = FullMath.min(
                   amount, ERC20(token).allowance(
                                from, address(this)));
                   ERC20(token).transferFrom(from,
                                address(this), usd);
                   if (l1 || token == USDC) {
                        address vault = vaults[token];
                        amount = ERC4626(vault).deposit(
                                    usd, address(this));
                        perVault[vault].debit += amount;
                    } else { perVault[token].debit += usd; }
        }            require(isDollar && amount > 0, "$");
    }

    // takes $ amount input in units of 1e18...
    function withdrawUSDC(uint amount) public
        onlyUs returns (uint withdrawn) {
        if (amount > 0) {
             withdrawn = FullMath.min(amount / 1e12, 
                ERC4626(VAULT).maxWithdraw(
                            address(this)));
            if (withdrawn > 0) {
                ERC4626(VAULT).withdraw(withdrawn, 
                    Mindwill, address(this)); 
            }
        } else { return 0; }
    } // TODO deploy Morpho 
    // vault on Arbitrum...

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
            uint keep = GRIEVANCES;
            this.morph(QUID, keep);
            _reachUp(currentBatch(), 
                QUID, KICKBACK);
        } // 16M GD over 24... 
    } 
    function _reachUp(uint batch, 
        address to, uint cut) internal {
        batch = FullMath.min(1, batch);
        require(batch < 25, "!"); // 25 to
        _mint(to, cut);  // lifetime value
        START = block.timestamp; // right now
        consideration[to][batch] += cut;
        Pod memory day = Piscine[batch - 1][42];
        // ROI aggregates all batches' days...
        ROI += FullMath.mulDiv(WAD, day.credit - 
                         day.debit, day.debit);
        // ROI in MO is a snapshot (avg per day)
        MO(Mindwill).setMetrics(ROI / ((DAYS 
                     / 1 days) * batch)); 
    } function currentBatch() public view returns 
        (uint batch) { batch = (block.timestamp - 
                        deployed) / DAYS;
    } 
    
    // uint less discount sooner maturing
    function matureBatches() // 0 is 1yr...
        public view returns (uint) { // in 3
        uint batch = currentBatch(); // 1-33
        if (batch < 8) { return 0; } // TODO
        else if (batch < 33) {
            return batch - 8;
        } else { return 24; }
    } 
    function matureBalanceOf(address account)
        public view returns (uint total) {
        uint batches = matureBatches();
        for (uint i = 0; i < batches; i++) {
        total += consideration[account][i]; }
    } // redeeming matured GD calls turn from MO
    function turn(address from, uint value)
        public onlyUs returns (uint) {
        uint balance_from = this.balanceOf(from);
        _burn(from, value); _transferHelper(from, 
                                address(0), value);
        // carry.debit will be untouched here...
        return MO(Mindwill).transferHelper(from,
                address(0), value, balance_from);
    }
    function transfer(address to, // `to` is receiver
        uint amount) public override returns (bool) {
        uint balance_from = this.balanceOf(msg.sender);
        uint value = FullMath.min(amount, balance_from);
        uint from_vote = feeVotes[msg.sender];
        bool result = true; 
        if (to == Mindwill) {
            _burn(msg.sender, value);
        } else if (to != address(0)) {
            uint to_vote = feeVotes[to];
            uint balance_to = this.balanceOf(to);
            result = super.transfer(to, value);
            _calculateMedian(this.balanceOf(to),
                    to_vote, balance_to, to_vote);
        } _transferHelper(msg.sender, to, value);
        uint sent = MO(Mindwill).transferHelper(
            msg.sender, to, value, balance_from);
        if (value != sent) { value = amount - sent;
            _mint(msg.sender, value);
            consideration[msg.sender][currentBatch()] += value;
        } else { _calculateMedian(this.balanceOf(msg.sender),
                         from_vote, balance_from, from_vote);
        } return result;
    }
    function _transferHelper(address from,
        address to, uint amount) internal {
        require(amount > WAD, "minimum 1 GD");
        // int or tx reverts when we go below 0 in loop...
        int i = to == address(0) ? int(matureBatches()) :
                                      int(currentBatch());
        while (amount > 0 && i >= 0) { uint k = uint(i);
            uint amt = consideration[from][k]; // GD...
            if (amt > 0) { amt = FullMath.min(amount, amt);
                consideration[from][k] -= amt;
                if (to != address(0)) {
                    consideration[to][k] += amt;
                }                 amount -= amt;
            }   i -= 1;
        }   require(amount == 0, "transfer");
    }
    function transferFrom(address from, address to,
        uint amount) public override returns (bool) {
        uint balance_from = this.balanceOf(from);
        uint value = FullMath.min(amount, balance_from);
        uint from_vote = feeVotes[to]; bool result = true;
        if (to == Mindwill) {
            require(msg.sender == Mindwill, 
            "403"); _burn(from, amount);
        } if (msg.sender != Mindwill) {
            uint to_vote = feeVotes[to];
            uint balance_to = this.balanceOf(to);
            result = super.transferFrom(from, to, value);
            _calculateMedian(this.balanceOf(to), to_vote,
                                    balance_to, to_vote);
        } MO(Mindwill).transferHelper(
        from, to, value, balance_from);
        _transferHelper(from, to, value);
        _calculateMedian(this.balanceOf(from),
            from_vote, balance_from, from_vote); return result;
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
        uint stake = this.balanceOf(msg.sender);
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
     */ // TODO debug and generalise
    function _calculateMedian( // for fee
        uint old_stake, uint old_vote,
        uint new_stake, uint new_vote) internal {
        if (old_vote != 28 && old_stake != 0) {
            WEIGHTS[old_vote] -= FullMath.min(
                WEIGHTS[old_vote], old_stake);
            if (old_vote <= K) { SUM -= FullMath.min(
                                      SUM, old_stake); }
        }   if (new_stake != 0) { if (new_vote <= K) {
                                     SUM += new_stake; }
                      WEIGHTS[new_vote] += new_stake; }
        uint mid = SUM / 2; if (mid != 0) {
            if (K > new_vote) {
                while (K >= 1 && (
                    (SUM - WEIGHTS[K]) >= mid
                )) { SUM -= WEIGHTS[K]; K -= 1; }
            } else { while (SUM < mid) { K += 1;
                            SUM += WEIGHTS[K]; }
            } MO(Mindwill).setFee(K);
        } else { 
            SUM = 0; 
        } // TODO fix
    }
    function _getPrice(address token) internal 
        view returns (uint price) { // L2 only
        if (token == SUSDE) { // in absence of ERC4626 locally
            (, int answer,, uint ts,) = AggregatorV3Interface(
            0xdEd37FC1400B8022968441356f771639ad1B23aA).latestRoundData();
            // 0xdEd37FC1400B8022968441356f771639ad1B23aA // Base
            // 0x605EA726F0259a30db5b7c9ef39Df9fE78665C44 // ARB
            price = uint(answer); require(ts > 0 
                && ts <= block.timestamp, "link");
        } else if (token == SCRVUSD) { 
            price = CRV.pricePerShare(block.timestamp);
        } else if (token == SUSDS) {
            price = DSR.getConversionRateBinomialApprox() / 1e9;
        }
        require(price >= WAD, "price");
    } // function used only on Base...
    
    // systematic uncertainty + unsystematic = total
    // demand uncertainty. typically systematic will
    // dominate unsystematic. in my experience, the 
    // 2 tend to break according to pareto principle
    function mint(address pledge, uint amount, 
        address token /*, uint when */) public 
        nonReentrant { uint batch;
        if (token == address(this)) {
            batch = currentBatch(); _mint(pledge, amount); // GD
            consideration[pledge][batch] += amount; // redeem ^
            require(msg.sender == Mindwill, "authorisation");
        }   else if (block.timestamp <= START + DAYS 
            && batch < 24) { batch = currentBatch(/*when*/); // 0 - 24
                
                uint in_days = ((block.timestamp - START) / 1 days);
                require(amount >= WAD * 10 && (in_days + 1) 
                    * MAX_PER_DAY >= Piscine[batch][42].credit 
                    + amount, "cap"); uint price = in_days * 
                                        PENNY + START_PRICE;
                uint cost = FullMath.mulDiv( // to mint GD
                        price, amount, WAD); _deposit(
                                pledge, token, cost);
                consideration[pledge][batch] += amount;
                _mint(pledge, amount); // totalSupply++
                MO(Mindwill).mint(pledge, cost, amount);
                Piscine[batch][in_days].credit += amount;
                Piscine[batch][in_days].debit += cost;
                // 43rd row is the total for the batch
                Piscine[batch][42].credit += amount;
                Piscine[batch][42].debit += cost; 
            }
        } address public constant LZ = 0x1a44076050125825900e736c501f859c50fE728c;
         address public constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
        address public constant QUID = 0x42cc020Ef5e9681364ABB5aba26F39626F1874A4;
      address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    // basescan.org/tx/0xdad5990d8164f9908d25fce906cb8863e458471a1d645e5215f3a39eb42f006d
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
     *   by the recipient, the transfer will be reverted.
     */
    // QuidMint...foundation.app/@quid
    function onERC721Received(address,
        address from, // previous owner...
        uint tokenId, bytes calldata data)
        external override returns (bytes4) { 
        uint batch = currentBatch(); // 1 - 25 (3 years)
        require(block.timestamp > START + DAYS, "early");
        if (tokenId == LAMBO && ICollection(F8N).ownerOf(
            LAMBO) == address(this)) { address winner;
            uint cut = GRIEVANCES / 2; uint count = 0;
            // my mind spits with an enormous kickback,
            // open fire...open mind...this time is a 
            // promise sounding like an oath...I wanna 
            // know true feeling, but you can't decide
            // if you're hooked on...only the kick...
            this.morph(QUID, cut); this.morph(from, cut);
            ICollection(F8N).transferFrom( // return
                address(this), QUID, LAMBO); // NFT...
                // "I put my key, you put your key in"
            uint kickback = KICKBACK; cut = KICKBACK / 12;
            if (voters[batch - 1].length >= 10 && data.length >= 32) {
                bytes32 _seed = abi.decode(data[:32], (bytes32));
                for (uint i = 0; count < 10 && i < 30; i++) {
                    uint random = uint(keccak256(
                        abi.encodePacked(_seed,
                        block.prevrandao, i))) %
                        voters[batch - 1].length;
                        winner = voters[batch - 1][random];
                    if (!winners[winner]) {
                        count += 1; winners[winner] == true;
                        kickback -= cut; _mint(winner, cut);
                        consideration[winner][batch] += cut;
                    } // "they want their grievances aired on the assumption
                    // that all right-thinking persons would be persuaded
                    // that problems of the world can be solved," by true 
                    // dough, Pierre, not your usual money, version mint
                } // new level, same rebel, hold the Base never trebble,
                // I hop out the price drop, and the system be trembling
            } _reachUp(batch, from, kickback); 
        } return this.onERC721Received.selector;
        // they don't think that we're in a cent?
        // GD floating like he got a pill in him,
        // tear the roof off this бомба расклад
    } // lottery for L1 to incentivise governance

    // when the weather turns fair and the river calms 
    // men can prepare for the next time by building 
    // dykes and dams so when the river next floods
    // it will stay within its banks, at least not
    // uncontrolled and damaging: how it is with 
    
    // internal Morpho optimiser, highly customisable
    function morph(address to, uint amount) // 4
        public onlyUs returns (uint sent) {
        bool l2 = MO(Mindwill).token1isWETH();
        uint total = get_total_deposits(false);
        if (msg.sender == address(this)) {    
            // get batch which just ended...
            uint batch = currentBatch() - 1;
            uint raised = Piscine[batch][42].debit;
            uint cut = FullMath.mulDiv(raised, CUT, WAD); 
            amount = FullMath.min(amount, cut);
            Piscine[batch][42].debit -= amount;
        } require(amount > 0, "no thing");
        uint inDollars; address vault; uint i; // for loop
        uint[5] memory amounts; address[5] memory tokens; 
        uint sharesWithdrawn; address repay = l2 ? VAULT : SDAI; 
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(ID);
        (uint delta, uint cap) = MO(Mindwill).capitalisation(0, false);
        uint borrowed = MorphoBalancesLib.expectedBorrowAssets(
                        // on L2 this is USDC, on L1 it's DAI...
                        IMorpho(MORPHO), params, address(this));  
                        tokens = [DAI, USDS, USDE, CRVUSD, FRAX]; 
        uint collat; // hardcoded to one, but ^^^ can be changed to any
        if (!l2) { for (i = 0; i < 5; i++) { vault = vaults[tokens[i]];
            amounts[i] = FullMath.min(ERC4626(vault).maxWithdraw(
                      address(this)), ERC4626(vault).convertToAssets(
                                            perVault[vault].debit - 
                                            perVault[vault].credit));
            } inDollars = FullMath.min(delta + delta / 9, amounts[2]);
             collat = ERC4626(SUSDE).convertToShares(inDollars); 
        } // TODO uncomment for L1, commented here to save bytecode
        else { amounts[0] = perVault[DAI].debit;
            // amounts[5] = perVault[FRAX].debit; // TODO Arbitrum
            for (i = 1; i < 4; i++) { vault = vaults[tokens[i]];
                amounts[i] = perVault[tokens[i]].debit +
                FullMath.mulDiv(_getPrice(vault), // TODO cache the
                    perVault[vault].debit, WAD); // results for gas
            }   inDollars = FullMath.mulDiv(_getPrice(SUSDE), 
                                 perVault[SUSDE].debit, WAD);
            collat = FullMath.min(delta + delta / 9, inDollars);
            collat = FullMath.mulDiv(WAD, collat, _getPrice(SUSDE));
        }   if (collat > 0 && delta > 0 && inDollars > delta) {
                IMorpho(MORPHO).supplyCollateral(
                params, collat, address(this), "");
                perVault[SUSDE].credit += collat; 
                perVault[SUSDE].debit -= collat;
                (borrowed,) = IMorpho(MORPHO).borrow(params, collat, 0,
                                        address(this), address(this));
                perVault[repay].credit += ERC4626(repay).deposit( 
                                        borrowed, address(this));
        } else if (borrowed > 0 && cap == 100) { 
                delta = delta > perVault[repay].credit ? 
                                perVault[repay].credit : delta;
                delta = FullMath.min(borrowed, delta);
                (sharesWithdrawn,) = IMorpho(MORPHO).repay(params, 
                    ERC4626(repay).withdraw(delta, address(this), 
                    address(this)), 0, address(this), "");
                perVault[repay].credit -= sharesWithdrawn;
                inDollars = ERC4626(repay).convertToAssets(
                                            sharesWithdrawn);
                if (!l2) { collat = FullMath.min(collat, 
                                    FullMath.mulDiv(WAD, 
                                    inDollars, _getPrice(SUSDE)));
                } else { collat = FullMath.min(collat, 
                    ERC4626(SUSDE).convertToShares(inDollars));
                }   IMorpho(MORPHO).withdrawCollateral(params, 
                        collat, address(this), address(this));
                        perVault[SUSDE].credit -= collat;
                        perVault[SUSDE].debit += collat;
        } else if (borrowed == 0 && perVault[SUSDE].credit > 0) {
                IMorpho(MORPHO).withdrawCollateral(params, 
                perVault[SUSDE].credit, address(this), address(this));
                perVault[SUSDE].debit += perVault[SUSDE].credit;
                perVault[SUSDE].credit = 0;
        }       if (!l2) { // no USDC here
                    for (i = 0; i < 5; i++) { 
                        amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                                WAD, amounts[i], total), WAD);
                        if (amounts[i] > 0) { 
                            vault = vaults[tokens[i]]; // functionally equivalent to maxWithdraw()
                            sharesWithdrawn = FullMath.min(ERC4626(vault).balanceOf(address(this)),
                                                    ERC4626(vault).convertToShares(amounts[i]));
                            require(sharesWithdrawn == ERC4626(vault).withdraw(sharesWithdrawn, 
                                                                    to, address(this)), "$m");
                            perVault[vault].debit -= sharesWithdrawn;
                            amounts[i] = ERC4626(vault).convertToAssets(
                                 sharesWithdrawn); sent += amounts[i];
                        } 
                    }
        } else { // TODO uncomment L1, commented to save bytecode
            if (amounts[0] > 0) { sent = FullMath.min(amounts[0],
                    ERC20(tokens[0]).balanceOf(address(this)));
                    ERC20(tokens[0]).transfer(to, amounts[0]);
            }       for (i = 1; i < 4; i++) {
                        inDollars = FullMath.min(amounts[i],
                                ERC20(tokens[i]).balanceOf(
                                        address(this)));
                        ERC20(tokens[i]).transfer(to, 
                                    inDollars);
                        amounts[i] -= inDollars;
                            sent += inDollars;
                        if (amounts[i] > 0) {
                            // reuse inDollars...
                            // represents "shares"
                            vault = vaults[tokens[i]];
                            inDollars = FullMath.min(
                            ERC20(vault).balanceOf(
                                address(this)), FullMath.mulDiv(
                                                amounts[i], WAD, 
                                                _getPrice(vault)));
                            ERC20(vault).transfer(to, inDollars);
                            sent += FullMath.mulDiv(inDollars,
                                        _getPrice(vault), WAD);
                        }   
                    } /* TODO uncomment
            if (amounts[4] > 0) { sent = FullMath.min(amounts[4],
                ERC20(tokens[4]).balanceOf(address(this)));
                ERC20(tokens[4]).transfer(to, amounts[4]);
            } // ^ above only for Arbitrum, no FRAX on Base
            */
        }
    }
}
