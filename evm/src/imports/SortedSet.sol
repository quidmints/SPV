// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice §E258 — a band's resting-order book: the trigger-price index PLUS the watermark saying
///         how far it has been swept. They are ONE struct because they are one thing — a set swept
///         from a price nobody recorded is not a book, it is two variables that can disagree — and
///         because a single storage pointer is what lets the whole sweep live in a delegatecalled
///         library instead of billing the band manager's EIP-170 margin for it.
struct OorBook {
    SortedSetLib.Set index;
    /// The price this band last swept for crossed orders. Zero means NEVER SWEPT and seeds itself
    /// without filling: otherwise the first swap after a deploy reads every resting bid as crossed.
    uint lastSweptPx;
}

library SortedSetLib {
    struct Set {
        uint[] sortedArray;
        mapping(uint => bool) exists;
    }

    /// @notice Inserts a value while maintaining sorting order.
    function insert(Set storage self, uint value) internal {
        if (self.exists[value]) return; // Ignore duplicates

        self.exists[value] = true;
        (uint index, ) = binarySearch(self, value);

        self.sortedArray.push(0); // Expand array

        // Shift elements right to insert in the correct position
        for (uint i = self.sortedArray.length - 1; i > index; i--) {
            self.sortedArray[i] = self.sortedArray[i - 1];
        }
        self.sortedArray[index] = value;
    }

    /// @notice Removes a value and triggers automatic cleanup.
    function remove(Set storage self, uint value) internal {
        require(self.exists[value], "Value does not exist");

        (uint index, ) = binarySearch(self, value);
        require(index < self.sortedArray.length
         && self.sortedArray[index] == value, "Value not found");

        self.sortedArray[index] = type(uint).max; // Mark as deleted
        delete self.exists[value]; // ^ max is just a sentinel value

        compactArray(self); // Cleanup on every removal
    }

    /// @notice Binary search to find index for insertion or lookup.
    function binarySearch(Set storage self,
        uint value) internal view returns (uint, bool) {
        uint left = 0; uint right = self.sortedArray.length;

        while (left < right) {
            uint mid = left + (right - left) / 2;
            if (self.sortedArray[mid] == value) {
                return (mid, true); // Value found
            }
            else if (self.sortedArray[mid] < value) {
                left = mid + 1;
            }
            else {
                right = mid;
            }
        }
        return (left, false); // Value not found, return insertion index
    }

    /// @notice Performs automatic cleanup by removing all `0`s.
    function compactArray(Set storage self)
        internal { uint newLength = 0;

        uint[] memory newArray = new uint[](self.sortedArray.length);
        for (uint i = 0; i < self.sortedArray.length; i++) {
            if (self.sortedArray[i] != type(uint).max) {
                newArray[newLength] = self.sortedArray[i];
                newLength++;
            }
        }
        // Resize the array
        self.sortedArray = new uint[](newLength);
        for (uint i = 0; i < newLength; i++) {
            self.sortedArray[i] = newArray[i];
        }
    }

    /// @notice Returns the sorted set.
    function getSortedSet(Set storage self)
        internal view returns (uint[] memory) {
        return self.sortedArray;
    }
}
