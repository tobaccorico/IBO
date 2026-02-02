
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Court} from "./Court.sol";
import {Jury} from "./Jury.sol";
import {Aux} from  "./Aux.sol";

// import {AuxBase as Aux} from "./L2/AuxBase.sol";
// import {AuxPoly as Aux} from "./L2/AuxPoly.sol";
// import {AuxArb as Aux} from "./L2/AuxArb.sol";
// import {AuxUni as Aux} from "./L2/AuxUni.sol";

import {OFT} from "./imports/OFT.sol";
import {BasketLib} from "./BasketLib.sol";
import {Origin} from "./imports/oapp/OApp.sol";
import {MessageCodec} from "./imports/MessageCodec.sol";

import {SendParam} from "./imports/oapp/interfaces/IOFT.sol";
import {OFTMsgCodec} from "./imports/oapp/libs/OFTMsgCodec.sol";
import {MessagingReceipt, MessagingFee} from "./imports/oapp/OAppSender.sol";
import {OFTComposeMsgCodec} from "./imports/oapp/libs/OFTComposeMsgCodec.sol";

import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

contract Basket is OFT, ERC6909, ReentrancyGuard {
    using SortedSetLib for SortedSetLib.Set;
    using OFTMsgCodec for bytes32;
    using OFTMsgCodec for bytes;
    address internal _deployer;
    uint internal _deployed;

    uint constant WAD = 1e18; // dollar
    uint constant PoV = WAD * 500000;
    uint constant tranche = PoV / 5;
    address payable public court;
    
    uint public seeded; // fundraised
    uint public multiplier; // <= 200%
    address payable public V4; // hook
    address public jury; Aux public AUX;

    uint32 public constant SOL_MAINNET_EID = 30168;
    mapping(bytes32 => bool) public processedGuids;
    // ^ this is just for safety (replay protection)

    mapping(bytes32 => bool) public processedMessages;
    uint public latest_holder; address[] public holders;

    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public juryLocked;

    mapping(address => uint) public holderIndex;
    mapping(address => bool) private untouchables;

    // Unichain differs: 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B
    address constant LZ = 0x1a44076050125825900e736c501f859c50fE728c;

    event SentToSolana(bytes32 indexed guid,
                uint8 msgType, uint length);

    modifier onlyUs {
        require(auth(msg.sender), "403"); _;
    }

    function auth(address who) public view returns (bool) {
        return who == address(AUX) || who == jury ||
                      who == court || who == V4;
    }

    constructor(address _rover, address _aux)
        OFT("QU!D", "QD", LZ, msg.sender)
        Ownable(msg.sender) {
        _deployer = msg.sender;
        _deployed = block.timestamp;
        AUX = Aux(payable(_aux));
        V4 = payable(_rover);
    } // ^ where it's at...

    mapping(address => SortedSetLib.Set) private perMonth;
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function setup(address _court, address _jury)
        external onlyUs { court = payable(_court);
        jury = _jury;
    }

    function lockForJury(address juror,
        uint amount) external onlyUs {
        juryLocked[juror] += amount;
    }

    function unlockFromJury(address juror,
        uint amount) external onlyUs {
        juryLocked[juror] -= Math.min(
            juryLocked[juror], amount);
    }

    function totalMatureBalanceOf(address owner)
        public view returns (uint total) {
        uint[] memory batches = perMonth[owner].getSortedSet();
        int idx = BasketLib.matureBatches(batches,
                        block.timestamp, _deployed);

        if (idx < 0) return 0;
        for (int i = idx; i >= 0; i--)
            total += balanceOf[owner][batches[uint(i)]];
    }

    function _debit(uint _amountLD, uint _minAmountLD,
        uint32 _dstEid) internal override returns
        (uint amountSentLD, uint amountReceivedLD) {
        // keep OFT safety math (fees, min amount)
        (amountSentLD, amountReceivedLD) = _debitView(
                     _amountLD, _minAmountLD, _dstEid);
        // pull basket payload from send(...) calldata
        bytes memory payload = BasketLib.extract(msg.data);
        require(payload.length > 0, "LZ: no data");

        (uint[] memory ids,
         uint[] memory amounts) = abi.decode(
                    payload, (uint[], uint[]));

        require(ids.length == amounts.length
             && ids.length > 0, "LZ: bad data");

        for (uint i = 0; i < ids.length; ++i)
            _burn(msg.sender, ids[i], amounts[i]);
    }

    function _lzReceive(Origin calldata _origin,
        bytes32 _guid, bytes calldata _message,
        address, bytes calldata) internal override {
        require(_origin.srcEid == SOL_MAINNET_EID, "sol");
        require(_origin.sender == peers[_origin.srcEid], "403");
        require(!processedGuids[_guid], "409");
        processedGuids[_guid] = true;

        uint64 amountSD = _message.amountSD();
        uint amountReceivedLD = _toLD(amountSD);
        bytes memory composeMsg = _message.composeMsg();
        address to = _message.sendTo().bytes32ToAddress();
        uint8 msgType = MessageCodec.getMessageType(composeMsg);
        if (msgType == MessageCodec.RESOLUTION_REQUEST) {
            Court(court).receiveResolutionRequest(composeMsg);
            emit OFTReceived(_guid, _origin.srcEid, court, 0);
        } else if (msgType == MessageCodec.JURY_COMPENSATION) {
            _handleJuryCompensation(_guid, _origin.srcEid, composeMsg);
        } else {
            _handleBasketTransfer(_origin, _guid, _message,
                          composeMsg, to, amountReceivedLD);
        }
    }

    function _handleJuryCompensation(bytes32 _guid,
        uint32 srcEid, bytes memory composeMsg) internal {
        (uint64 marketId, uint64 amountSolana) =
            MessageCodec.decodeJuryCompensation(composeMsg);

        uint amount = MessageCodec.toEthereumAmount(amountSolana);
        _mint(jury, currentMonth() + 1, amount);

        // Pass raw message (Jury can extract depeg stats if present)
        Jury(jury).receiveJuryFunds(marketId, amount, composeMsg);
        emit OFTReceived(_guid, srcEid, jury, amount);
    }

    function _handleBasketTransfer(Origin calldata _origin,
        bytes32 _guid, bytes calldata _message,
        bytes memory composeMsg, address to,
        uint amountReceivedLD) internal {
        (uint[] memory ids,
         uint[] memory amounts) = abi.decode(
                 composeMsg, (uint[], uint[]));

        require(ids.length == amounts.length
             && ids.length > 0, "LZ: data");
        for (uint i = 0; i < ids.length; ++i)
            _mint(to, ids[i], amounts[i]);

        if (_message.isComposed()) {
            bytes memory wrappedCompose = OFTComposeMsgCodec.encode(
            _origin.nonce, _origin.srcEid, amountReceivedLD, composeMsg);
            endpoint.sendCompose(to, _guid, 0, wrappedCompose);
        }
    }

    function sendToSolana(bytes memory composeMsg)
        external payable onlyUs returns (bytes32) {
        require(composeMsg.length > 0, "empty message");

        require(address(endpoint) != address(0), "endpoint");
        uint8 msgType = MessageCodec.getMessageType(composeMsg);
        require(msgType == MessageCodec.FINAL_RULING, "invalid");
        // little train, wait for me; once was blind but now I see

        uint32 dstEid = SOL_MAINNET_EID;
        bytes memory options = BasketLib.buildOptions(msgType);
        MessagingFee memory fee = _quote(dstEid, composeMsg,
                                          options, false);

        require(msg.value >= fee.nativeFee, "Insufficient fee");
        // Watched it pour as I touched your face
        MessagingReceipt memory receipt = _lzSend(dstEid,
             composeMsg, options, fee, msg.sender);

        processedMessages[receipt.guid] = true;
        emit SentToSolana(receipt.guid,
              msgType, block.timestamp);

        if (msg.value > fee.nativeFee)
            payable(msg.sender).transfer(
               msg.value - fee.nativeFee);

        return receipt.guid;
    }

    function turn(address from, uint value)
        external returns (uint sent) {
        bool isUntouchable = !auth(msg.sender);
        if (isUntouchable)
            require(from == msg.sender
                && untouchables[from], "403");

        // allows slashed tokens to be redistributed to correct jurors
        address destination = (msg.sender == jury) ? jury : address(0);
        sent = _transferHelper(from, destination, value);
        if (isUntouchable)
            AUX.take(msg.sender, sent,
                address(this), true);
    }

    function _mint(address receiver,
        uint when, uint amount)
        internal override {
        totalSupplies[when] += amount;
        perMonth[receiver].insert(when);
        super._update(address(0),
                receiver, amount);
        balanceOf[receiver][when] += amount;
        uint bal = super.balanceOf(receiver);
        if (holderIndex[receiver] == 0 && bal
            > tranche / 10000 && bal < tranche) {
            // You so down to еarth like I am...
            // You wanna be me or my friеnd?
            holderIndex[receiver] = holders.length + 1;
            // Pour more, feel less, told you I was sinless
            // even if we're at the first index (0) we...
            // have to do a +1 trick since == 0 check
            holders.push(receiver);
            latest_holder = holders.length;
        }
        emit Transfer(msg.sender, address(0),
                    receiver, when, amount);
    } function mint(address pledge,
        uint amount, address token,
        uint when) external
        nonReentrant returns (uint) {
        uint nextMonth = currentMonth() + 1;
        // this is used by Vogue.withdraw()
        if (msg.sender == V4) { _mint(pledge,
                    nextMonth, amount);
                         return amount;
        } uint deposited = AUX.deposit(
                 pledge, token, amount);

        uint decimals = IERC20(token).decimals();
        uint normalized = decimals < 18 ? deposited
              * (10 ** (18 - decimals)) : deposited;

        uint month = Math.max(when, // at least 1 mo.
                    nextMonth); require(month < 23);
        if (month - nextMonth > 12 && seeded < PoV) {
            _mint(_deployer, nextMonth - 1, normalized);
            multiplier = multiplier == 0 ? block.timestamp:
                         multiplier; seeded += normalized;
            // "we all wanna be big special, but
            // I'll start small with potential...""
            normalized = FullMath.mulDiv(normalized,
            BasketLib.getEffectiveMultiplier(seeded,
                AUX.untouchable(), multiplier), WAD);
            // track address needed for redemption...
            untouchables[pledge] = true;
        } else { uint yield = AUX.getAverageYield();
            normalized += FullMath.mulDiv(normalized * yield,
                            month - currentMonth(), WAD * 12);
        } _mint(pledge, month, normalized); return normalized;
    }

    function transfer(address to, uint value)
        public override returns (bool) {
        require(value == _transferHelper(
                  msg.sender, to, value));
        return true;
    }

    function transferFrom(address from,
        address to, uint value) public
        override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferHelper(from, to, value); return true;
    }

    // times flies...make a statement; take a stand
    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        require(super.balanceOf(from) - juryLocked[from] >= amount);
        uint[] memory batches = perMonth[from].getSortedSet();

        bool burning = to == address(0);
        int i = burning ? BasketLib.matureBatches(
             batches, block.timestamp, _deployed):
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
                amount -= amt; sent += amt;
            } i -= 1; // liable to be -1
        } // -1 means "no mature batches"
        if (sent > 0) {
            super._update(from, to, sent);
            // ^ should burn from totalSupply
            // if necessary (to = address(0))
            amount = super.balanceOf(from);
            uint index = holderIndex[from];
            if ((amount < tranche / 10000
             || amount > tranche) && index != 0) {
                uint lastIndex = latest_holder - 1;
                if (index - 1 != lastIndex) { // equal when we
                    // initialise the holders array, and if
                    // coincidentally it's the lastHolder...
                    address lastHolder = holders[lastIndex];
                    holderIndex[lastHolder] = index;
                    holders[index] = lastHolder;
                } holderIndex[from] = 0; holders.pop();
                latest_holder = holders.length;
            }   amount = super.balanceOf(to);
            if (to != address(0) && holderIndex[to] == 0 &&
                amount > tranche / 10000 && amount < tranche) {
                holderIndex[to] = holders.length; holders.push(to);
                latest_holder = holders.length;
            }
        }
    }
}
