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
    struct Trade { // total 96 bytes
        // 20 bytes
        address sender;
        // anoter 20 bytes
        address token; // receiving
        // 32 bytes
        uint amount; // selling
    }
    struct Batch { // total 64 bytes
        uint total; // 32 bytes
        Trade[] swaps; // length pointer 32 bytes
    } // since we're submitting 2 batches to
    // the router on every block that we can,
    // given that max. calldata size for a tx
    // is ~128 KB = 131072 bytes, there can
    // only be a theoretical max. of ~1400
    // swaps split between the two batches
    // however, given the max. gas limit
    // for a tx, practical limit is ~30
}
