// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Types {
    struct SelfManaged {
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }
    struct viaAAVE {
        uint breakeven;
        uint supplied;
        uint borrowed;
        uint buffer;
        int price;
    }    
    struct Deposit {
        uint pooled_eth;
        uint eth_shares;
        uint usd_owed;
        // Masterchef-style
        // snapshots of fees:
        uint fees_eth;
        uint fees_usd;
    }
    struct Trade {
        address sender;
        address token; // receiving
        uint amount; // selling
    }
    struct Batch { 
        uint total; 
        Trade[] swaps; 
    } 
}
