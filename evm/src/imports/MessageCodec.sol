
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library MessageCodec { // why they plead the 5th?
    uint8 public constant RESOLUTION_REQUEST = 5;
    // 5 reprents arm leg leg arm head, the one
    // that we keep asking for resolutions...

    uint8 public constant FINAL_RULING = 6;
    // "A life is like a book. A book is like
    // a box. A box has six sides. Inside and
    // outside, so, how do you get to what's
    // inside? do you get what's inside, out?"

    uint8 public constant JURY_COMPENSATION = 7;
    // always call the hotline for the stop signs
    uint8 public constant EXTENSION_MARKER = 101;

    error InvalidMessageType();
    error InvalidMessageLength();
    error InvalidMarketId();
    error InvalidSideCount();
    error InvalidAmount();
    error ResolutionTimeInPast();
    error InvalidWinnerCount();
    error InvalidSplits();
    error TooManySlashingAddresses();

    /// @notice Depeg stats from Solana prediction market
    /// (optioally appended to JURY_COMPENSATION)
    struct DepegStats {
        uint64 avgConfPeg;      // Capital-weighted avg confidence for peg side
        uint64 avgConfDepeg;    // Capital-weighted avg confidence for depeg side
        uint64 capPeg;          // Total capital betting peg (from total_capital_per_side[0])
        uint64 capDepeg;        // Total capital betting depeg (from total_capital_per_side[1])
        uint40 timestamp;       // When cached (set by Court on ETH)
        bool depegged;          // Market resolved as depegged
    }

    /// @notice Resolution request data from Solana
    /// @dev Using struct to avoid stack too deep errors
    struct ResolutionRequestData { uint64 marketId;
        uint8 numSides; uint8 numWinners; bytes32 merkleRoot;
        bool requiresUnanimous; bool requiresSignature;
        bool isDepegMarket; bool allowsExtensions;
        uint256 appealCost; bytes32 requester;
    }

    function encodeUint64LE(uint64 value) internal pure returns (bytes memory) {
        bytes memory result = new bytes(8);
        result[0] = bytes1(uint8(value));
        result[1] = bytes1(uint8(value >> 8));
        result[2] = bytes1(uint8(value >> 16));
        result[3] = bytes1(uint8(value >> 24));
        result[4] = bytes1(uint8(value >> 32));
        result[5] = bytes1(uint8(value >> 40));
        result[6] = bytes1(uint8(value >> 48));
        result[7] = bytes1(uint8(value >> 56));
        return result;
    }

    function decodeUint64LE(bytes memory data, uint256 offset)
        internal pure returns (uint64 result) {
        require(data.length >= offset + 8, "Insufficient data for uint64");

        result = uint64(uint8(data[offset]))
            | (uint64(uint8(data[offset + 1])) << 8)
            | (uint64(uint8(data[offset + 2])) << 16)
            | (uint64(uint8(data[offset + 3])) << 24)
            | (uint64(uint8(data[offset + 4])) << 32)
            | (uint64(uint8(data[offset + 5])) << 40)
            | (uint64(uint8(data[offset + 6])) << 48)
            | (uint64(uint8(data[offset + 7])) << 56);
    }

    function decodeUint64LECalldata(bytes calldata data, uint256 offset)
        internal pure returns (uint64) {
        require(data.length >= offset + 8, "Insufficient data for uint64");

        return uint64(uint8(data[offset]))
            | (uint64(uint8(data[offset + 1])) << 8)
            | (uint64(uint8(data[offset + 2])) << 16)
            | (uint64(uint8(data[offset + 3])) << 24)
            | (uint64(uint8(data[offset + 4])) << 32)
            | (uint64(uint8(data[offset + 5])) << 40)
            | (uint64(uint8(data[offset + 6])) << 48)
            | (uint64(uint8(data[offset + 7])) << 56);
    }

    // ============================================================================
    // ENCODING FUNCTIONS - Ethereum → Better call Sol...ana
    // ============================================================================

    /**
     * @notice Encode final ruling message with multi-winner support
     * @dev Message format (variable length):
     *      [0] = FINAL_RULING
     *      [1-8] = marketId (LE)
     *      [9] = numWinners (0 = force majeure, 1 = extension if marker, 2+ = multi-winner)
     *      For each winner:
     *        [offset] = winningSide (1 byte)
     *      Then slashing addresses:
     *      [offset] = numSlashingAddresses
     *      For each slashing address:
     *        [offset..offset+31] = solana public key (32 bytes)
     *        [offset+32] = side (1 byte)
     *
     *      INTERPRETATION:
     *      - Empty winners (length=0) = Force majeure (market cancelled)
     *      - Single winner with EXTENSION_MARKER = Extension granted
     *      - Otherwise = Normal resolution, Solana calculates equal splits
     */
     function encodeFinalRuling(uint64 marketId, uint8[] memory winningSides,
         bytes32[] memory slashingAddresses,
         uint8[] memory slashingSides) internal pure returns (bytes memory) {
         if (marketId == 0) revert InvalidMarketId();
         require(slashingAddresses.length == slashingSides.length, "slash length mismatch");

         bytes memory message = abi.encodePacked(FINAL_RULING,
             encodeUint64LE(marketId), uint8(winningSides.length));

         for (uint i = 0; i < winningSides.length; i++) {
             message = abi.encodePacked(message, winningSides[i]);
         }
         message = abi.encodePacked(message,
            uint8(slashingAddresses.length));

         // 33 bytes per entry: address (32) + side (1)
         for (uint i = 0; i < slashingAddresses.length; i++) {
             message = abi.encodePacked(message,
                slashingAddresses[i], slashingSides[i]);
         }
         return message;
    }

   /**
    * @notice Decode resolution request from Solana
    * @dev Message format:
    *      [0] = RESOLUTION_REQUEST (5)
    *      [1-8] = marketId (uint64, little-endian)
    *      [9] = numSides (uint8)
    *      [10] = numWinners (uint8)
    *      [11-42] = merkleRoot (32 bytes)
    *      [43] = requiresUnanimous (0 or 1)
    *      [44] = requiresSignature (0 or 1)
    *      [45] = isDepegMarket (0 or 1)
    *      [46] = allowsExtensions (0 or 1)
    *      [47-54] = appealCost (uint64, little-endian)
    *      [55-86] = requester (32 bytes, Solana pubkey)
    *
    * @param message The encoded message bytes
    * @return data The decoded resolution request data struct
    */
    function decodeResolutionRequest(bytes calldata message) internal pure
        returns (ResolutionRequestData memory data) {
        uint256 offset = 1;
        data.marketId = decodeUint64LECalldata(message, offset);

        offset += 8;
        data.numSides = uint8(message[offset]);
        offset += 1;

        data.numWinners = uint8(message[offset]);
        offset += 1;

        data.merkleRoot = bytes32(message[offset:offset+32]);
        offset += 32;

        data.requiresUnanimous = uint8(message[offset]) == 1;
        offset += 1;

        data.requiresSignature = uint8(message[offset]) == 1;
        offset += 1;

        data.isDepegMarket = uint8(message[offset]) == 1;
        offset += 1;

        data.allowsExtensions = uint8(message[offset]) == 1;
        offset += 1;

        data.appealCost = uint256(decodeUint64LECalldata(message, offset));
        offset += 8;

        data.requester = bytes32(message[offset:offset+32]);
    }

    /**
     * @notice Decode jury compensation from Solana (with optional depeg stats tail)
     * @dev Base format (17 bytes):
     *      [0] = JURY_COMPENSATION (7)
     *      [1-8] = marketId (LE)
     *      [9-16] = amount (LE, in Solana decimals - 6)
     *
     *      Extended format for depeg markets (+33 bytes = 50 total):
     *      [17-24] = avgConfPeg (LE, u64)
     *      [25-32] = avgConfDepeg (LE, u64)
     *      [33-40] = capPeg (LE, u64)
     *      [41-48] = capDepeg (LE, u64)
     *      [49] = depegged (bool as u8)
     */
    function decodeJuryCompensation(bytes memory data)
        internal pure returns (uint64 marketId, uint64 amount) {
        if (data.length < 17) revert InvalidMessageLength();
        if (uint8(data[0]) != JURY_COMPENSATION) revert InvalidMessageType();

        marketId = decodeUint64LE(data, 1);
        amount = decodeUint64LE(data, 9);

        if (marketId == 0) revert InvalidMarketId();
        if (amount == 0) revert InvalidAmount();
        require(amount <= 1_000_000 * 1e6,
          "Compensation exceeds maximum");
    }

    /**
     * @notice Check if jury compensation message has depeg stats appended
     */
    function hasDepegStats(bytes memory data) internal pure returns (bool) {
        return data.length >= 50; // 17 base + 33 stats
    }

    /**
     * @notice Parse depeg stats from JURY_COMPENSATION message tail
     * @dev Only call after verifying hasDepegStats() returns true
     */
    function parseDepegStats(bytes memory data)
        internal pure returns (DepegStats memory s) {
        if (data.length < 50) return s; // No stats present

        s.avgConfPeg = decodeUint64LE(data, 17);
        s.avgConfDepeg = decodeUint64LE(data, 25);
        s.capPeg = decodeUint64LE(data, 33);
        s.capDepeg = decodeUint64LE(data, 41);
        s.depegged = uint8(data[49]) == 1;
        // timestamp set by Court when caching
    }

    function getMessageType(bytes memory data) internal pure returns (uint8) {
        if (data.length == 0) revert InvalidMessageLength();
        return uint8(data[0]);
    }

    function toEthereumAmount(uint64 solanaAmount) internal pure returns (uint256) {
        return uint256(solanaAmount) * 1e12;
    }

    function isForceMajeure(uint8[] memory verdict) internal pure returns (bool) {
        return verdict.length == 0;
    }

    function isExtension(uint8[] memory verdict) internal pure returns (bool) {
        return verdict.length == 1 && verdict[0] == EXTENSION_MARKER;
    } // this extension marker was chosen specifically because VoIP
    // office phone systems start extensions at 100, with the first
} // human extension being 101, and humans have to vote for this...
