// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9.0;

contract SortedSet {
    address private quid;
    uint[] private sortedArray;
    mapping(uint => bool) private exists;

    constructor(address _quid) {
        quid = _quid;
    }

    modifier onlyQuid {
        require(msg.sender == quid, "!?"); _;
    }

    /// @notice Inserts a value while maintaining sorting order.
    function insert(uint value) external onlyQuid {
        if (exists[value]) return; // Ignore duplicates

        exists[value] = true;
        (uint index, ) = binarySearch(value);

        sortedArray.push(0); // Expand array

        // Shift elements right to insert in the correct position
        for (uint i = sortedArray.length - 1; i > index; i--) {
            sortedArray[i] = sortedArray[i - 1];
        }

        sortedArray[index] = value;
    }

    /// @notice Removes a value and triggers automatic cleanup.
    function remove(uint value) external onlyQuid {
        require(exists[value], "Value does not exist");

        (uint index, ) = binarySearch(value);
        require(index < sortedArray.length && sortedArray[index] == value, "Value not found");

        sortedArray[index] = 0; // Mark as deleted
        delete exists[value];

        compactArray(); // Cleanup on every removal
    }

    /// @notice Binary search to find index for insertion or lookup.
    function binarySearch(uint value) internal view returns (uint, bool) {
        uint left = 0;
        uint right = sortedArray.length;

        while (left < right) {
            uint mid = left + (right - left) / 2;
            if (sortedArray[mid] == value) {
                return (mid, true); // Value found
            } else if (sortedArray[mid] < value) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return (left, false); // Value not found, return insertion index
    }

    /// @notice Performs automatic cleanup by removing all `0`s.
    function compactArray() internal {
        uint newLength = 0;

        // Create a new array to hold the non-zero elements
        uint[] memory newArray = new uint[](sortedArray.length);

        // Copy non-zero elements to the new array
        for (uint i = 0; i < sortedArray.length; i++) {
            if (sortedArray[i] != 0) {
                newArray[newLength] = sortedArray[i];
                newLength++;
            }
        }

        // Resize the sortedArray to the new length
        sortedArray = new uint[](newLength);
        for (uint i = 0; i < newLength; i++) {
            sortedArray[i] = newArray[i];
        }
    }

    /// @notice Returns the sorted set.
    function getSortedSet() external view returns (uint[] memory) {
        return sortedArray;
    }
}
