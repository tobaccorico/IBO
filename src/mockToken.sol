// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.4 <0.9.0;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

contract mockToken is ERC20 {

    uint public WAD;

    constructor(uint8 decimals) ERC20("mock", "mock", decimals) {
        WAD = 10 ** decimals;
    }

    function mint() external {
        _mint(msg.sender, WAD * 10000);
    }

    function mint(address who, uint much) external {
        _mint(who, much);
    }

}

