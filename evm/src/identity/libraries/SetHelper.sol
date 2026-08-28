// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Local replacement for @solarity/solidity-lib's libs/arrays/SetHelper.sol, which was
/// removed entirely (not renamed - no equivalent found anywhere in the package) between
/// solidity-lib 3.1.0 and 3.3.3 during the 2026-07-25 dependency freshness pass. Vendoring the
/// exact two functions this codebase actually uses (RegistrationSimple.sol,
/// RegistrationSMTReplicator.sol - both only ever call the batch add/remove on AddressSet, never
/// UintSet/Bytes32Set/DynamicSet's Bytes/StringSet, and never strictAdd/strictRemove) rather than
/// reproducing the original's full multi-type surface speculatively.
library SetHelper {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Insert an array of elements into the address set.
    function add(EnumerableSet.AddressSet storage set, address[] memory array_) internal {
        for (uint256 i = 0; i < array_.length; i++) {
            set.add(array_[i]);
        }
    }

    /// @notice Remove an array of elements from the address set.
    function remove(EnumerableSet.AddressSet storage set, address[] memory array_) internal {
        for (uint256 i = 0; i < array_.length; i++) {
            set.remove(array_[i]);
        }
    }
}
