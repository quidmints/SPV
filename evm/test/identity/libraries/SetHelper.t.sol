// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {EnumerableSet} from '@oz/utils/structs/EnumerableSet.sol';
import {SetHelper} from '../../../src/identity/libraries/SetHelper.sol';

/*
 * SetHelper is two batch wrappers over EnumerableSet, used by RegistrationSimple and
 * RegistrationSMTReplicator to manage their signer/replicator sets. Small, but the failure mode is
 * quiet: a batch add that silently drops a duplicate, or a batch remove that stops at the first
 * absent entry, leaves the set in a state the caller believes it is not in.
 */
contract SetHelperTest is Test {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SetHelper for EnumerableSet.AddressSet;

  EnumerableSet.AddressSet internal set;

  function _addrs(uint256 n, uint256 offset) internal pure returns (address[] memory out) {
    out = new address[](n);
    for (uint256 i = 0; i < n; i++) out[i] = address(uint160(offset + i + 1));
  }

  function test_addsEveryElement() public {
    set.add(_addrs(3, 0));
    assertEq(set.length(), 3);
    for (uint256 i = 1; i <= 3; i++) assertTrue(set.contains(address(uint160(i))));
  }

  /// @notice Duplicates inside one batch must not double-count - EnumerableSet dedups, and the
  /// wrapper must not defeat that by tracking its own length.
  function test_duplicatesWithinABatchAreDeduped() public {
    address[] memory dup = new address[](3);
    dup[0] = address(0x1);
    dup[1] = address(0x1);
    dup[2] = address(0x2);

    set.add(dup);
    assertEq(set.length(), 2, 'duplicate was counted twice');
  }

  /// @notice Re-adding an existing element is a no-op, not an error - callers batch-add supersets.
  function test_addingAnExistingElementIsANoOp() public {
    set.add(_addrs(2, 0));
    set.add(_addrs(3, 0)); // superset of the first
    assertEq(set.length(), 3);
  }

  function test_removesEveryElement() public {
    set.add(_addrs(4, 0));
    set.remove(_addrs(2, 0));

    assertEq(set.length(), 2);
    assertFalse(set.contains(address(0x1)));
    assertFalse(set.contains(address(0x2)));
    assertTrue(set.contains(address(0x3)));
    assertTrue(set.contains(address(0x4)));
  }

  /// @notice Removing an absent element must not abort the rest of the batch - otherwise one stale
  /// address in a revocation list would silently leave the others in place.
  function test_removingAnAbsentElementDoesNotAbortTheBatch() public {
    set.add(_addrs(2, 0));

    address[] memory mixed = new address[](3);
    mixed[0] = address(0xDEAD); // never added
    mixed[1] = address(0x1);
    mixed[2] = address(0x2);

    set.remove(mixed);
    assertEq(set.length(), 0, 'a missing entry stopped the batch');
  }

  function test_emptyBatchesAreNoOps() public {
    set.add(_addrs(2, 0));
    set.add(new address[](0));
    set.remove(new address[](0));
    assertEq(set.length(), 2);
  }
}
