
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
} // http://42.fr Piscine
import "./MOulinette.sol";
contract Quid is ERC20, // OFTOwnable2Step, 
    // LayerZero commented out save gas on deployment
    IERC721Receiver, ReentrancyGuard { 
    using SafeTransferLib for ERC4626;
    using SafeTransferLib for ERC20;
    uint public AVG_ROI; 
    uint public START;
    // "Walked in the
    // kitchen, found a
    // [Pod] to [Piscine]" ~ 2 tune chi
    Pod[43][24] Piscine; // 24 batches
    uint constant PENNY = 1e16; // 0.01
    // in for a penny, in for a pound...
    uint constant LAMBO = 16508; // NFT
    bytes32 public immutable ID; // Morph
    uint constant public DAYS = 42 days;
    uint public START_PRICE = 50 * PENNY;
    struct Pod { uint credit; uint debit; }
    mapping(address => Pod) internal perVault;
    mapping(address => address) internal vaults;
    mapping (address => bool[24]) public hasVoted;
    mapping (address => uint) internal lastRedeemed;
    // token-holders vote for deductibles, and their
    // QD balances are applied to the total weights
    // for the voted % (weights are the balances)
    // index 0 is the largest possible vote = 9%
    // index 89 represents the smallest one = 1%
    uint public deployed; uint internal K = 17;
    uint public SUM; uint[90] public WEIGHTS;
    mapping (address => uint) public feeVotes;
    address[][24] public voters; // by batch
    mapping (address => bool) public winners;
    // ^the mapping prevents duplicates
    address payable public Moulinette; 
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
    modifier onlyGenerators {
        address sender = msg.sender;
        require(sender == Moulinette ||
                sender == address(this), "!?");
        _;
    } // en.wiktionary.org/wiki/moulinette
    constructor(address _mo, address _usdc, 
        address _vault, bytes32 _morpho,
        address _usde, address _susde,
        /* address _frax, address _sfrax,
         address _sdai, */ address _dai,
        address _usds, address _susds,
        address _crv, address _scrv)
        /* OFTOwnable2Step("QU!D", "QD", 
        LZ, QUID) { VAULT = _vault; */
        ERC20("QU!D", "QD", 18) {
            VAULT = _vault;

        ID = _morpho; START = block.timestamp; 
        /* SDAI = _sdai; */ deployed = START; 
        USDC = _usdc; USDE = _usde; 
        DAI = _dai; SUSDE = _susde; 
        USDS = _usds; SUSDS = _susds; 
        CRVUSD = _crv; SCRVUSD = _scrv;
        vaults[CRVUSD] = SCRVUSD;
        vaults[USDC] = VAULT; 
        vaults[USDE] = SUSDE;
        vaults[USDS] = SUSDS;
        Moulinette = payable(_mo);
        _mint(address(this), BACKEND * 24);
        // ^ used for special withdrawals in MO...
        ERC20(USDC).approve(VAULT, type(uint).max);
        if (address(MO(Moulinette).token0()) == USDC) { // L1
            require(address(MO(Moulinette).token1())
            == address(MO(Moulinette).WETH9()), "42");
            // FRAX = _frax; SFRAX = _sfrax; TODO uncomment
            // vaults[FRAX] = SFRAX; vaults[DAI] = SDAI 
            ERC20(USDS).approve(SUSDS, type(uint).max);
            ERC20(CRVUSD).approve(SCRVUSD, type(uint).max);
            ERC20(USDE).approve(SUSDE, type(uint).max);
            // ERC20(DAI).approve(SDAI, type(uint).max);
            // ERC20(FRAX).approve(SFRAX,  type(uint).max); 
            ERC4626(SUSDE).approve(MORPHO, type(uint).max);
            ERC20(DAI).approve(MORPHO, type(uint).max);
        } else { require(address(MO(Moulinette).token1())
              == USDC && address(MO(Moulinette).token0())
              == address(MO(Moulinette).WETH9()), "42"); vaults[DAI] = DAI;
                ERC20(SUSDE).approve(MORPHO, type(uint).max); // deployed 
                ERC20(USDC).approve(MORPHO, type(uint).max); // on Base...
                DSR = IDSROracle(0x65d946e533748A998B1f0E430803e39A6388f7a1);
                CRV = ISCRVOracle(0x3d8EADb739D1Ef95dd53D718e4810721837c69c1);
        }
    } uint constant GRIEVANCES = 113310303333333333333333;
    uint constant CUT = 4920121799152111; // over 3 years
    uint constant BACKEND = 666666666666666666666666; 
    uint constant QD = 41666666666666664; // ~4.2% ^
    mapping(address => uint[24]) public consideration;
    // https://www.law.cornell.edu/wex/consideration
    uint constant public MAX_PER_DAY = 777_777 * WAD;
    
    function get_total_deposits
        (bool usdc) public view
        // this is only *part* of the captalisation()
        returns (uint total) { // handle USDC first
        total += usdc ? ERC4626(VAULT).maxWithdraw(
                        address(this)) * 1e12 : 0;
        if (!MO(Moulinette).token1isWETH()) { // L2
            total += FullMath.mulDiv(
                    _getPrice(SUSDE),
                     perVault[SUSDE].debit, WAD);
            total += perVault[USDE].debit;
            total += FullMath.mulDiv(
                    _getPrice(SUSDS),
                     perVault[SUSDS].debit, WAD);
            total += perVault[USDS].debit;
            total += perVault[DAI].debit;
            total += FullMath.mulDiv(
                    _getPrice(SCRVUSD),
                     perVault[SCRVUSD].debit, WAD);
                     total += perVault[CRVUSD].debit;
        } /* 
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
        */
    }
    function _minAmount(address from,
        address token, uint amount)
        internal returns (uint usd) {
        bool l2 = !MO(Moulinette).token1isWETH();
        bool isDollar = false; // $ is ^ on l2
        if (token == SCRVUSD ||
          // token == SFRAX ||
          // token == SDAI ||
            token == SUSDE ||
            token == SUSDS) { 
            isDollar = true;
            // commented out for compilation purposes (less bytecode)
            /* if (!l2) { // L1
                amount = FullMath.min(
                      ERC4626(token).balanceOf(from),
                      ERC4626(token).convertToShares(amount));
                usd = ERC4626(token).convertToAssets(amount);
                // TODO make sure frontend approves transfer
                ERC4626(token).transferFrom(msg.sender,
                                address(this), amount);
            } else { */
                uint price = _getPrice(token);
                amount = FullMath.min(
                  ERC20(token).balanceOf(from),
                      FullMath.mulDiv(amount, WAD, price));
                usd = FullMath.mulDiv(amount, price, WAD);
            // } 
            perVault[token].debit += amount;
        } else if (token == DAI  ||
                   token == USDS ||
                   token == USDC ||
                // token == FRAX ||
                   token == USDE ||
                   token == CRVUSD) {
                   isDollar = true;
                   usd = FullMath.min(amount,
                   ERC20(token).balanceOf(from));
                   ERC20(token).transferFrom(from,
                                address(this), usd);
                   if (!l2 || token == USDC) {
                        address vault = vaults[token];
                        amount = ERC4626(vault).deposit(
                                    usd, address(this));
                        perVault[vault].debit += amount;
                    } else { perVault[token].debit += usd; }
        }             require(isDollar && amount > 0, "$");
    }

    // used in MO _swap();
    // to mirror, there's
    // mint function in MO
    function withdrawUSDC(uint amount) public
        onlyGenerators returns (uint withdrawn) {
        withdrawn = FullMath.min(amount, 
            ERC4626(VAULT).maxWithdraw(
                         address(this)));
        ERC4626(VAULT).withdraw(
        ERC4626(VAULT).convertToShares(withdrawn),
                        Moulinette, address(this)); 
    }
    function lastRedeem(address who) public view
        returns (uint) { return lastRedeemed[who]; }
    function qd_amt_to_dollar_amt(uint qd_amt) public
        view returns (uint amount) { uint in_days = (
            (block.timestamp - START) / 1 days
        );  amount = (in_days * PENNY
            + START_PRICE) * qd_amt / WAD;
    } // the current ^^^^ to mint()
    function get_total_supply_cap()
        public view returns (uint) {
        uint batch = currentBatch();
        uint in_days = ( // used in frontend...
            (block.timestamp - START) / 1 days
        ) + 1; return in_days * MAX_PER_DAY -
                Piscine[batch][42].credit;
    }
    function batchUp()
        public nonReentrant {
        if (block.timestamp >
            START + DAYS + 3 days) {
            _batchUp(currentBatch());
        }
    } 
    function _batchUp(uint batch) internal {
        batch = FullMath.min(1, batch);
        require(batch < 25, "!");
        Pod memory day = Piscine[batch - 1][42];
        AVG_ROI += FullMath.mulDiv(WAD,
        day.credit - day.debit, day.debit);
        MO(Moulinette).setMetrics(AVG_ROI / 
            ((DAYS / 1 days) * batch));
                 START = block.timestamp;
    }
    function currentBatch()
        public view returns (uint batch) {
        batch = (block.timestamp - deployed) / DAYS;
        // for the last 8 batches to be
        // redeemable, batch reaches 32,
        // for 24 mature batches total
        // require(batch < 33, "3 years");
    }
    function matureBatches()
        public view returns (uint) {
        uint batch = currentBatch();
        if (batch < 8) { return 0; }
        else if (batch < 33) {
            return batch - 8;
        } else { return 24; }
    }
    function matureBalanceOf(address account)
        public view returns (uint total) {
        uint batches = matureBatches();
        for (uint i = 0; i < batches; i++) {
            total += consideration[account][i];
        }
    }
    // turning a generator is what redeems it
    function turn(address from, uint value)
        public onlyGenerators returns (uint) {
        uint balance_from = this.balanceOf(from);
        lastRedeemed[from] = currentBatch();
        _transferHelper(from, address(0), value);
        // carry.debit will be untouched here...
        return MO(Moulinette).transferHelper(from,
                address(0), value, balance_from);
    }
    function transfer(address to, // `to` is receiver
        uint amount) public override returns (bool) {
        uint balance_from = this.balanceOf(msg.sender);
        uint value = FullMath.min(amount, balance_from);
        uint from_vote = feeVotes[msg.sender];
        bool result = true;
        if (to == Moulinette) {
            _burn(msg.sender, value);
        } else if (to != address(0)) {
            uint to_vote = feeVotes[to];
            uint balance_to = this.balanceOf(to);
            result = super.transfer(to, value);
            _calculateMedian(this.balanceOf(to),
                to_vote, balance_to, to_vote);
        } _transferHelper(msg.sender, to, value);
        uint sent = MO(Moulinette).transferHelper(
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
        require(amount > WAD, "min. 1 QD");
        int i; // must be int or tx reverts
        // when we go below 0 in the loop
        if (to == address(0)) {
            i = int(matureBatches());
            _burn(from, amount);
        }  
        else { i = int(currentBatch()); }
        while (amount > 0 && i >= 0) { uint k = uint(i);
            uint amt = consideration[from][k]; // QD...
            if (amt > 0) { amt = FullMath.min(amount, amt);
                consideration[from][k] -= amt;
                if (to != address(0)) {
                    consideration[to][k] += amt;
                }   amount -= amt;
            }   i -= 1;
        }   require(amount == 0, "transfer");
    }
    function transferFrom(address from, address to,
        uint amount) public override returns (bool) {
        uint balance_from = this.balanceOf(from);
        uint value = FullMath.min(amount, balance_from);
        uint from_vote = feeVotes[to]; bool result = true;
        if (from == address(this)) {
            require(msg.sender ==
             Moulinette, "403");
            _burn(from, amount);
        } else {
            if (msg.sender != Moulinette) {
                uint to_vote = feeVotes[to];
                uint balance_to = this.balanceOf(to);
                result = super.transferFrom(from, to, value);
                _calculateMedian(this.balanceOf(to), to_vote,
                                      balance_to, to_vote);
            } MO(Moulinette).transferHelper(
              from, to, value, balance_from);
            _transferHelper(from, to, value);
            _calculateMedian(this.balanceOf(from),
                from_vote, balance_from, from_vote);
        }
        return result;
    }

    function vote(uint new_vote) external {
        uint batch = currentBatch(); // 0-24
        if (batch < 24
        && !hasVoted[msg.sender][batch]) {
            (uint carry,) = MO(Moulinette).get_info(msg.sender);
            if (carry > GRIEVANCES / 10) { 
                hasVoted[msg.sender][batch] = true;
                voters[batch].push(msg.sender); 
            }
        } uint old_vote = feeVotes[msg.sender];
        old_vote = old_vote == 0 ? 17 : old_vote;
        require(new_vote != old_vote &&
                new_vote <= 89, "bad vote");
        // +11 max vote = 9.0% deductible...
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
     */ // TODO debug
    function _calculateMedian(uint old_stake, uint old_vote,
        uint new_stake, uint new_vote) internal {
        if (old_vote != 17 && old_stake != 0) {
            WEIGHTS[old_vote] -= FullMath.min(
                WEIGHTS[old_vote], old_stake
            );
            if (old_vote <= K) {
                SUM -= FullMath.min(SUM, old_stake);
            }
        }   if (new_stake != 0) {
                if (new_vote <= K) {
                    SUM += new_stake;
                }
                WEIGHTS[new_vote] += new_stake;
        } uint mid = this.totalSupply() / 2;
        if (mid != 0) {
            if (K > new_vote) {
                while (K >= 1 && (
                    (SUM - WEIGHTS[K]) >= mid
                )) { SUM -= WEIGHTS[K]; K -= 1; }
            } else {
                while (SUM < mid) {
                    K += 1; SUM += WEIGHTS[K];
                }
            } MO(Moulinette).setFee(K);
        }  else { SUM = 0; } // reset
    }
    function _getPrice(address token) internal 
        view returns (uint price) { // L2 only
        if (token == SUSDE) { // in absence of ERC4626 locally
            (, int answer,, uint ts,) = AggregatorV3Interface(
            0xdEd37FC1400B8022968441356f771639ad1B23aA).latestRoundData();
            price = uint(answer); require(ts > 0 
                && ts <= block.timestamp, "link");
        } else if (token == SCRVUSD) { 
            price = CRV.pricePerShare(block.timestamp);
        } else if (token == SUSDS) {
            price = DSR.getConversionRateBinomialApprox() / 1e9;
        }   
        require(price >= WAD, "price");
    } // function used only on Base...
    
    function mint(address pledge, uint amount, address token)
        public nonReentrant { uint batch = currentBatch(); // 0 - 24
        if (token == address(this)) { _mint(pledge, amount); // QD
            consideration[pledge][batch] += amount; // redeem...^
            require(msg.sender == Moulinette, "authorisation");
        }   else if (block.timestamp <= START + DAYS && batch < 24) {
                uint in_days = ((block.timestamp - START) / 1 days);
                require(amount > WAD * 10 && 
                       (in_days + 1) * MAX_PER_DAY > 
                Piscine[batch][42].credit + amount, "cap"); 
                uint price = in_days * PENNY + START_PRICE;
                uint cost = _minAmount(pledge, token,
                    FullMath.mulDiv(price, amount, WAD));
                // _minAmount may return less being paid,
                // so we must calculate amount twice here:
                amount = FullMath.mulDiv(WAD, cost, price);
                consideration[pledge][batch] += amount;
                _mint(pledge, amount); // totalSupply++
                MO(Moulinette).mint(pledge, cost, amount);
                Piscine[batch][in_days].credit += amount;
                Piscine[batch][in_days].debit += cost;
                // 44th row is the total for the batch
                Piscine[batch][42].credit += amount + 
                FullMath.mulDiv(QD, amount, WAD); 
                Piscine[batch][42].debit += cost - 
                FullMath.mulDiv(CUT, cost, WAD);  
            }
        } address constant LZ = 0x1a44076050125825900e736c501f859c50fE728c;
         address constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
        address constant QUID = 0x42cc020Ef5e9681364ABB5aba26F39626F1874A4;
      address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
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
        // pay if batch raised 70% only, otherwise if all TODO
        // refunds were paid out (this piece is gas comp.)
        // doing it discretely as one taxable event is best
        if (tokenId == LAMBO && ICollection(F8N).ownerOf(
            LAMBO) == address(this)) { address winner;
            uint cut = GRIEVANCES / 2; uint count = 0;
            // "I put my key, you put your key in..."
            this.morph(QUID, cut); this.morph(from, cut);
            ICollection(F8N).transferFrom( // return
                address(this), QUID, LAMBO); // NFT...

            // TODO do the following allocation in ETH, 
            // instead of splitting the BACKEND in QD...
            // (BACKEND - this.balanceOf(address(this)))
            // worth of ETH is withdrawn from MO, deposit 
            // as collat to winners, borrow max against:
            // re-deposit QD back into address(this)...

            /* uint backend = BACKEND; cut = backend / 12;
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
                        backend -= cut; _mint(winner, cut);
                        consideration[winner][batch] += cut;
                    }
                }
            } cut = backend; _mint(from, cut);
            consideration[from][batch] += cut; */
            _batchUp(batch); // "same level, same rebel"
        } return this.onERC721Received.selector;
    }
    
    function morph(address to, uint amount)
        public onlyGenerators returns (uint sent) {
        bool l2 = !MO(Moulinette).token1isWETH();
        uint total = get_total_deposits(false);
        if (msg.sender == address(this)) {    
            amount = FullMath.min(amount,
                     FullMath.mulDiv(total,
                                CUT, WAD));
        } // total does not include USDC as
        // we never transfer it out, we only
        // keep it in curation, or (per need):
        // use it for the Uniswap LP position
        // converting to WETH in MO.withdraw
        uint dai; uint usde; uint inDollars; 
        uint usds; uint crvusd; // uint usdc;
        address repay = l2 ? VAULT : SDAI; 
        require(amount > 0, "no thing");
        uint frax; uint sharesWithdrawn;
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(ID);
        (uint delta, uint cap) = MO(Moulinette).capitalisation(0, false);
        uint borrowed = MorphoBalancesLib.expectedBorrowAssets(
                        // on L2 this is USDC, on L1 it's DAI...
                        IMorpho(MORPHO), params, address(this));  
        
        // we over-collateralise a
        // bit beyond what's needed...
        uint collat = delta + delta / 9;
        /* if (!l2) { // ^ may be zero, in that case ignore
            dai =  FullMath.min(ERC4626(SDAI).maxWithdraw(
                address(this)), ERC4626(SDAI).convertToAssets(
                                perVault[SDAI].debit - 
                                perVault[SDAI].credit));
            frax = FullMath.min(ERC4626(SFRAX).maxWithdraw(
                address(this)), ERC4626(SFRAX).convertToAssets(
                                         perVault[SFRAX].debit));      
            usds = FullMath.min(ERC4626(SUSDS).maxWithdraw(
                address(this)), ERC4626(SUSDS).convertToAssets(
                                         perVault[SUSDS].debit));
            crvusd = FullMath.min(ERC4626(SCRVUSD).maxWithdraw(
                  address(this)), ERC4626(SCRVUSD).convertToAssets(
                                           perVault[SCRVUSD].debit));
            inDollars = FullMath.min(ERC4626(SUSDE).maxWithdraw(
                     address(this)), ERC4626(SUSDE).convertToAssets(
                                              perVault[SUSDE].debit));
            inDollars = FullMath.min(collat, inDollars);
            collat = ERC4626(SUSDE).convertToShares(
                                          inDollars);
        } else { */
            usds = perVault[USDS].debit +
            FullMath.mulDiv(_getPrice(SUSDS),
                perVault[SUSDS].debit, WAD);
                dai = perVault[DAI].debit;
            crvusd = perVault[CRVUSD].debit +
            FullMath.mulDiv(_getPrice(SCRVUSD),
                perVault[SCRVUSD].debit, WAD);
            uint price = _getPrice(SUSDE);
            inDollars = FullMath.mulDiv(
            price, perVault[SUSDE].debit, WAD);
            collat = FullMath.min(collat, inDollars);
            collat = FullMath.mulDiv(WAD, collat, price);
        // }
        if (delta == 0 && borrowed > 0) {
        // there is no shortfall, but we 
        // owe debt from a previous state
            sharesWithdrawn = ERC4626(repay).withdraw(
                borrowed, address(this), address(this));
            // USDC shares in that vault were borrowed    
            perVault[repay].credit -= sharesWithdrawn;
            IMorpho(MORPHO).repay(params,
                sharesWithdrawn, 0, 
                address(this), ""
            );
            // SUSDE shares that were pledged to borrow
            uint collateral = perVault[SUSDE].credit;
            IMorpho(MORPHO).withdrawCollateral(params, 
                collateral, address(this), address(this));
            
            perVault[SUSDE].credit -= collateral;
            perVault[SUSDE].debit += collateral;
        } 
        // TODO use to Public Allocator to retrieve market liquidity
        // as well as available liquidity for a market, using multiple
        // markets (assuming we have deployed several) if we need to
        else if (collat > 0 && delta > 0 
                && inDollars > delta) {
            IMorpho(MORPHO).supplyCollateral(
            params, collat, address(this), "");
            perVault[SUSDE].debit -= collat;
            perVault[SUSDE].credit += collat; 
            delta = inDollars - inDollars / 9;
            (borrowed, ) = IMorpho(MORPHO).borrow(params, delta, 0,
                                     address(this), address(this));
            perVault[repay].credit += borrowed;
            ERC4626(repay).deposit( // curated
            // vault on Base, sDAI on Ethereum
                dai, address(this));
        }
        /*
        if (!l2) { // this code is good, commented out to compile
            dai = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                               dai, total), WAD);
            usds = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                               usds, total), WAD);
            usde = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                          inDollars, total), WAD);
            frax = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                               frax, total), WAD);
            crvusd = FullMath.mulDiv(amount, FullMath.mulDiv(WAD,
                                               crvusd, total), WAD);
            if (dai > 0) {
                sharesWithdrawn = FullMath.min(ERC4626(SDAI).balanceOf(address(this)),
                                               ERC4626(SDAI).convertToShares(dai));
                require(sharesWithdrawn == ERC4626(SDAI).withdraw(sharesWithdrawn, 
                                                         to, address(this)), "$a");
                perVault[SDAI].debit -= sharesWithdrawn;
                dai = ERC4626(SDAI).convertToAssets(
                                    sharesWithdrawn);
            } if (usds > 0) {
                sharesWithdrawn = FullMath.min(ERC4626(SUSDS).balanceOf(address(this)),
                                               ERC4626(SUSDS).convertToShares(usds));
                require(sharesWithdrawn == ERC4626(SUSDS).withdraw(sharesWithdrawn,
                                                          to, address(this)), "$b");
                perVault[SUSDS].debit -= sharesWithdrawn;
                usds = ERC4626(SUSDS).convertToAssets(
                                      sharesWithdrawn);
            } if (usde > 0) {
                sharesWithdrawn = FullMath.min(ERC4626(SUSDE).balanceOf(address(this)),
                                               ERC4626(SUSDE).convertToShares(usde));
                require(sharesWithdrawn == ERC4626(SUSDE).withdraw(sharesWithdrawn,
                                                          to, address(this)), "$c");
                perVault[SUSDE].debit -= sharesWithdrawn;
                usde = ERC4626(SUSDE).convertToAssets(
                                      sharesWithdrawn);
            } if (frax > 0) {
                sharesWithdrawn = FullMath.min(ERC4626(SFRAX).balanceOf(address(this)),
                                               ERC4626(SFRAX).convertToShares(frax));
                require(sharesWithdrawn == ERC4626(SFRAX).withdraw(sharesWithdrawn, 
                                                          to, address(this)), "$d");
                perVault[SFRAX].debit -= sharesWithdrawn;
                frax = ERC4626(SFRAX).convertToAssets(
                                     sharesWithdrawn);
            } if (crvusd > 0) {
                sharesWithdrawn = FullMath.min(ERC4626(SCRVUSD).balanceOf(address(this)),
                                               ERC4626(SCRVUSD).convertToShares(crvusd));
                
                require(sharesWithdrawn == ERC4626(SCRVUSD).withdraw(sharesWithdrawn, 
                                                            to, address(this)), "$e");
                perVault[SCRVUSD].debit -= sharesWithdrawn;
                crvusd = ERC4626(SCRVUSD).convertToAssets(
                                          sharesWithdrawn);
            }   return (dai + usds + usde + frax + crvusd);
        } else { // all of the above except ^^^^
        */  uint sending; // ^
            if (dai > 0) {
                sending = FullMath.min(dai,
                ERC20(DAI).balanceOf(address(this)));
                ERC20(DAI).transfer(to, dai);
            }
            if (usds > 0) {
                inDollars = FullMath.min(usds,
                        ERC20(USDS).balanceOf(
                                address(this)));
                sending += inDollars;
                ERC20(USDS).transfer(to, 
                            inDollars);
                    usds -= inDollars;
                if (usds > 0) {
                    // reuse inDollars 
                    // although this
                    // represents "shares"
                    inDollars = FullMath.min(
                        // perVault[SUSDS].debit
                        ERC20(SUSDS).balanceOf(
                                 address(this)),
                        FullMath.mulDiv(usds, WAD, 
                                _getPrice(SUSDS)));
                    ERC20(SUSDS).transfer(to,
                                inDollars); // not dollars
                    sending += FullMath.mulDiv(inDollars,
                         _getPrice(SUSDS), WAD);
                }   
            }
            if (usde > 0) {
                inDollars = FullMath.min(usde,
                        ERC20(USDE).balanceOf(
                                address(this)));
                sending += inDollars;
                ERC20(USDE).transfer(to, 
                            inDollars);
                    usde -= inDollars;
                if (usde > 0) {
                    inDollars = FullMath.min(
                        // perVault[SUSDE].debit
                        ERC20(SUSDE).balanceOf(
                                 address(this)),
                        FullMath.mulDiv(usde, WAD, 
                                _getPrice(SUSDE)));
                    ERC20(SUSDE).transfer(to,
                                inDollars); // not dollars
                    sending += FullMath.mulDiv(inDollars,
                         _getPrice(SUSDE), WAD);
                }
            }
            if (crvusd > 0) {
                inDollars = FullMath.min(crvusd,
                        ERC20(CRVUSD).balanceOf(
                                  address(this)));
                ERC20(CRVUSD).transfer(to, 
                              inDollars);
                    crvusd -= inDollars;
                if (crvusd > 0) {
                    inDollars = FullMath.min(
                        // perVault[SCRVUSD].debit
                        ERC20(SCRVUSD).balanceOf(
                                   address(this)),
                        FullMath.mulDiv(crvusd, WAD, 
                                _getPrice(SCRVUSD)));
                    ERC20(SCRVUSD).transfer(to,
                                  inDollars); // not dollars
                    sending += FullMath.mulDiv(inDollars,
                       _getPrice(SCRVUSD), WAD);
                }    
            } return sending;
        // } 
    } 
}
