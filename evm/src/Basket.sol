
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Aux} from  "./Aux.sol";
import {Vogue} from  "./Vogue.sol";
import {BasketLib} from "./BasketLib.sol";
import "lib/forge-std/src/console.sol";
// TODO delete logging before mainnet...

import {OFT} from "./imports/OFT.sol";
import {Origin} from "./imports/oapp/OApp.sol";
import {OFTMsgCodec} from "./imports/oapp/libs/OFTMsgCodec.sol";
import {OFTComposeMsgCodec} from "./imports/oapp/libs/OFTComposeMsgCodec.sol";

import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface ICollection is IERC721 {
    function latestTokenId()
    external view returns (uint);
} // for TVL-ratcheted vesting...
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
} 

contract Basket is OFT, // QD
    IERC721Receiver, ERC6909 {
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;
    using SortedSetLib for SortedSetLib.Set;
    Aux public AUX; uint private _deployed;
    
    // uint internal _supply; // override
    uint constant WAD = 1e18; // a dollar
    uint constant LAMBO = 16508; // NFT
    address payable public V4; // Uni...

    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    mapping(address => SortedSetLib.Set) private perMonth;
   
    address constant LZ = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
    address constant QUID = 0x42cc020Ef5e9681364ABB5aba26F39626F1874A4;
    // ^ LZ delegate 
    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == V4 // only address no ops 
             || sender == address(AUX), "404"); _;
    }        // AUX does all the ops for V4 via QD

    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function matureBatches(uint[] memory batches) public view returns (int i) {
        return BasketLib.matureBatches(batches, block.timestamp, _deployed);
    }

    constructor(address _rover, address _aux) 
        OFT("QU!D", "QD", LZ, QUID) Ownable(QUID) { 
        _deployed = block.timestamp; 
        AUX = Aux(payable(_aux));
        V4 = payable(_rover);    
    }
    
   /* ---------------------------------------------------------------*
    * extracts SendParam.composeMsg from calldata...
    * assumes send(SendParam, MessagingFee, address)
    * [0] = dstEid(uint32), [1] = to(bytes32), [2] = amountLD(uint256),
    * [3] = minAmountLD(uint256), [4] = extraOptions(bytes),
    * [5] = composeMsg(bytes),    [6] = oftCmd(bytes)
    * ---------------------------------------------------------------*/
    function _extractComposeMsgFromCalldata() internal 
        pure returns (bytes memory payload) { assembly {
            let off0 := calldataload(4) // head[0] → offset to SendParam 
            let structStart := add(off0, 4) // absolute start of SendParam
            // composeMsg is field index 5 → head at structStart + 5*32
            let composeHeadPos := add(structStart, 0xA0) // 5 * 0x20
            let composeOffset := calldataload(composeHeadPos) 
            // ^ offset is contextual: relative to structStart
            // absolute position of the bytes (length-prefixed)
            let composePos := add(structStart, composeOffset)
            let len := calldataload(composePos)
            // allocate & copy...
            let ptr := mload(0x40)
            mstore(ptr, len)
            calldatacopy(add(ptr, 0x20),
                         add(composePos, 0x20), len)
            // bump free memory pointer (32 for length + padded data)
            let size := add(0x20, and(add(len, 0x1f), not(0x1f)))
            mstore(0x40, add(ptr, size)) 
            payload := ptr
        }
    }
 
    function _debit(uint _amountLD, uint _minAmountLD, 
        uint32 _dstEid) internal override returns 
        (uint amountSentLD, uint amountReceivedLD) {
        // keep OFT’s safety math (fees, min amount)
        (amountSentLD, amountReceivedLD) = _debitView(
                     _amountLD, _minAmountLD, _dstEid);
        // pull basket payload from send(...) calldata
        bytes memory payload = _extractComposeMsgFromCalldata();
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
        uint64 amountSD = _message.amountSD();
        uint amountReceivedLD = _toLD(amountSD);
        bytes memory composeMsg = _message.composeMsg();
        address to = _message.sendTo().bytes32ToAddress();
        require(composeMsg.length > 0, "LZ: empty compose");
        (uint[] memory ids, uint[] memory amounts) = abi.decode(
                                    composeMsg, (uint[], uint[]));
        
        require(ids.length == amounts.length
             && ids.length > 0, "LZ: bad data");

        for (uint i = 0; i < ids.length; ++i) 
            _mint(to, ids[i], amounts[i]);

        if (_message.isComposed()) {
            bytes memory wrappedCompose = OFTComposeMsgCodec.encode(
                _origin.nonce, _origin.srcEid, amountReceivedLD, 
                composeMsg); endpoint.sendCompose(to, _guid, 0, 
                                    wrappedCompose);
        } emit OFTReceived(_guid, _origin.srcEid, 
                            to, amountReceivedLD);
    }

    // extended standard ERC6909 mint
    function _mint(address receiver,
        uint id, uint amount)
        internal override {
        totalSupplies[id] += amount;
        perMonth[receiver].insert(id);
        super._update(address(0), 
                receiver, amount);
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, address(0), receiver, id, amount);
    } // Basket.take() is not guaranteed to always have more than
    // the quantity of totalSupply() in dollars, because the ETH
    // that is in Uniswap PM may at any point crash in price...
    // to workaround for it involves PSM logic
    function mint(address pledge, uint amount, 
        address token, uint when) external {
        // delayed maturity ^^^^
        AUX.deposit(pledge, token, amount);
        uint month = Math.max(when, 
            currentMonth() + 1);
     
        (, uint yield) = AUX.get_metrics(false);
        amount += FullMath.mulDiv(amount * yield,
                month - currentMonth(), WAD * 12);
                     _mint(pledge, month, amount);
    } // same function in BasketL2.sol and here...

    function transferFrom(address from,
        address to, uint value) public 
        override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferHelper(from, to, value); return true;
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
        uint oldBalanceFrom = totalBalances[from]; // TODO 
        uint oldBalanceTo = totalBalances[to];
        super._update(from, to, amount);
        bool toZero = to == address(0);
        bool burning = toZero || to == V4;
        int i = toZero ? BasketLib.matureBatches(
            batches, block.timestamp, _deployed) : 
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
    }
    function transfer(address to, uint value) 
        public override returns (bool) {
        require(value == _transferHelper(
                    msg.sender, to, value)); 
        return true;
    } 
    function onERC721Received(address,
        address from, // previous owner...
        uint tokenId, bytes calldata data)
        external override returns (bytes4) { 
        if (tokenId == LAMBO && ICollection(F8N).ownerOf(
            LAMBO) == address(this)) { address winner;
            uint cut = KICKBACK / 6; // $111110 clif: 
            _mint(Vogue(V4).owner(), 24, cut); // 2yr
            uint kickback = KICKBACK - cut; cut /= 2;
            ICollection(F8N).transferFrom( 
            address(this), from, LAMBO); // Return NFT to sender
            
            
            // Any remaining kickback goes to the NFT sender
            if (kickback > 0) {
                _mint(from, 24, kickback);
            }
        } return this.onERC721Received.selector; 
    } uint constant KICKBACK = 666666666666666666666666; 
}
