
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library Types {

    /// @notice Vogue
    /// self-managed LP position
    struct SelfManaged {
        uint created;
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }

    /// @notice Amp AAVE
    /// leveraged position
    struct viaAAVE {
        uint breakeven;
        uint supplied;
        uint borrowed;
        uint buffer;
        int price;
    }

    /// @notice Vogue LP deposit
    /// MasterChef-style fee tracking
    struct Deposit {
        uint pooled_eth;
        uint usd_owed;
        uint fees_eth;
        uint fees_usd;
    }

    /// @notice Aux internal swap routing context
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

    /// @notice Full Bebop JAM order.
    /// @dev Every field must be present for ABI compatibility with the
    ///      on-chain JamSettlement contract, even if our solver doesn't
    ///      use all of them.
    ///
    ///      For ERC20-only arb, pass:
    ///        sellNFTIds:         new uint256[](0)
    ///        buyNFTIds:          new uint256[](0)
    ///        sellTokenTransfers: ""  (0x)
    ///        buyTokenTransfers:  ""  (0x)
    struct JamOrder {
        address   taker;              // order creator (EOA that signed)
        address   receiver;           // where buy tokens are sent
        uint256   expiry;             // block.timestamp deadline
        uint256   nonce;              // unique per taker, prevents replay
        address   executor;           // solver address, or address(0) for open
        uint16    minFillPercent;     // 10000 = 100%, minimum acceptable fill
        bytes32   hooksHash;          // keccak256 of hooks, or EMPTY_HOOKS_HASH
        address[] sellTokens;         // tokens taker is selling
        address[] buyTokens;          // tokens taker wants to receive
        uint256[] sellAmounts;        // amounts of each sell token
        uint256[] buyAmounts;         // minimum amounts of each buy token
        uint256[] sellNFTIds;         // NFT token IDs to sell  (empty for ERC20)
        uint256[] buyNFTIds;          // NFT token IDs to buy   (empty for ERC20)
        bytes     sellTokenTransfers; // per-token transfer cmds (empty for ERC20)
        bytes     buyTokenTransfers;  // per-token transfer cmds (empty for ERC20)
        bool      usingPermit2;       // true if taker approved via Permit2
        uint256   partnerInfo;        // encoded partner + fee data (0 = none)
    }

    /// @notice A single external call for JamSettlement to execute.
    /// @dev Matches Bebop's JamInteraction.Data exactly: {to, value, data}.
    ///      These are how the solver routes through DEXs, AMMs, etc.
    struct Interaction {
        address to;     // target contract to call
        uint256 value;  // ETH value to forward
        bytes   data;   // calldata for the external call
    }
}
