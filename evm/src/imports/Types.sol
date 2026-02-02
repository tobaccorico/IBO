// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
        uint usd_owed;
        // Masterchef-style
        // snapshots of fees:
        uint fees_eth;
        uint fees_usd;
    }
    struct AuxContext {
        address v3Pool;
        address v3Router;
        address weth;
        address usdc;
        address vault;
        address v4;
        uint24 v3Fee;
        bool isAAVE;
    }
      struct JamOrder {
        address taker;
        address receiver;
        uint256 expiry;
        uint256 nonce;
        address executor;
        uint16 minFillPercent;
        bytes32 hooksHash;
        address[] sellTokens;
        address[] buyTokens;
        uint256[] sellAmounts;
        uint256[] buyAmounts;
        uint256[] sellNFTIds;
        uint256[] buyNFTIds;
        bytes sellTokenTransfers;
        bytes buyTokenTransfers;
    }
    struct Signature {
        bytes signatureBytes;
        uint8 signatureType;
    }
    struct JamIntent {
        bool result;
        address to;
        uint256 value;
        bytes data;
    }
    struct JamHooks {
        address target;
        bytes preHooksData;
        bytes postHooksData;
    }
}
