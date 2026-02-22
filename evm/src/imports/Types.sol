
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library Types {
    /// @notice Vogue
    /// self-managed LP
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

    /// @notice Vogue LP deposit...
    /// MasterChef-style fee tracking
    struct Deposit { uint pooled_eth;
        uint usd_owed;
        uint fees_eth;
        uint fees_usd;
    }

    /// @notice routing
    struct AuxContext {
        address v3Pool;
        address v3Router;
        address weth;
        address usdc;
        address vault;
        address v4;
        address core;
        address rover;
        uint24 v3Fee;
        address hub;
        bool isAAVE;
    }

    struct PositionEntry {
        uint    capital;
        uint    tokens;
        bytes32 commitmentHash;
        uint    timestamp;
        uint    revealedConfidence; // max 10000 bps, 0 = not yet revealed
    }

    struct Position {
        address user;
        uint8   side;
        uint    totalCapital;
        uint    totalTokens;
        bytes32 commitmentHash;
        bool    revealed;
        uint    revealedConfidence;  // max 10000 bps
        bool    autoRollover;
        uint    weight;              // final weight (confidence × time decay)
        bool    paidOut;
        uint    entryTimestamp;      // when capital entered this round
        uint    lastRound;           // round this position is active in
        address delegate; // our keeper so user doesnt need to manually reveal their commit
    }

    /// @dev Forensic evidence submitted by CRE workflow.
    /// Advisory only — DVM vote is sole source of truth.
    struct ForensicEvidence {
        uint8 claimedSide;
        uint8 recommendedSide;
        int maxDeviationBps;
        uint8 confidence; // 0-100
        bytes32 evidenceHash;
        // keccak256 of data
        uint timestamp;
    }

    enum Phase { Trading, Asserting, Disputed, Resolved }

    struct Market {
        uint8   numSides;       // stables.length + 1
        uint    startTime;      // initial creation
        uint    roundStartTime; // beginning of current round
        int128  b;              // LSMR liquidity parameter
        Phase   phase;
        bool    resolved;

        uint    resolutionTimestamp;
        uint8    claimedSide;  // what the asserter claims
        uint8    winningSide;  // confirmed outcome
        uint8    consecutiveRejections; // escalates bond after griefing
        bytes32  assertionId;
        address  asserter;
        uint     revealDeadline;
        uint     requestTimestamp; // when requestResolution was called

        int128[12] q;
        // LSMR quantities per side
        uint[12] capitalPerSide;
        uint    totalCapital;
        uint    positionsTotal;
        uint    positionsRevealed;

        uint    totalWinnerCapital;
        uint    totalLoserCapital;
        uint    totalWinnerWeight;
        uint    totalLoserWeight;
        bool    weightsComplete;
        bool    payoutsComplete;
        bool    assertionPending;   // blocks new buys during OOV3 liveness
        uint    positionsPaidOut;   // tracks payout progress for safe restart
        uint    positionsWeighed;   // tracks weight computation for safe weightsComplete
        uint    roundNumber;
    }

    struct RouteParams {
        uint160 sqrtPriceX96;
        bool    zeroForOne;
        address token;
        uint    amount;
        uint    pooled;
        uint    v4Price;
        uint    v3Price;
        address recipient;
    }

    struct DepegStats {
        uint   capOnSide;
        uint   capNone;
        uint   capTotal;
        bool   depegged;
        uint8  side;
        uint   avgConf;      // Bayesian prior: last round's avg confidence on this side
    }

    /// @dev Every field must be present for ABI compatibility with the
    ///      on-chain JamSettlement contract, even if our solver doesn't
    ///      use all of them.
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
        uint16    minFillPercent;     // 10000 = 100%, minimum acceptable fill (Bebop ABI)
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
    /// @dev Matches Bebop's JamInteraction.Data exactly.
    /// Used for settlement interactions (executed by JamSettlement)
    /// and for repay swaps (executed directly by the Solver contract).
    struct Interaction {
        bool result; // if true, runInteractions checks call returns true
        address to; // target contract to call
        uint256 value; // ETH value to forward
        bytes data; // calldata for the external call
    }
}
