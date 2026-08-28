// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * The blacklist root source, as the pool needs to see it.
 *
 * ⚠️ DELIBERATELY ONE FUNCTION. `RegistrySourceAnchor` is large and owns several concerns; the pool
 * needs exactly one of them, and a narrow interface is what keeps a future change to the anchor's
 * other surfaces from silently becoming a change to the money path.
 *
 * ⛔ THE REVERTS ARE PART OF THE CONTRACT, NOT AN EDGE CASE. `latestActiveSmtRoot` reverts with
 * `NoSnapshotsAvailable` when nothing has ever been published and `NoActiveSnapshot` when nothing has
 * cleared the activation delay. For an EXCLUSION predicate that is the correct direction: an empty
 * or absent set proves non-membership for every key, so a source that returned zero on silence would
 * admit everyone. The pool must not catch these.
 */
interface IBlacklistAnchor {
  /// @notice The Poseidon SMT root the blacklist predicate proves NON-MEMBERSHIP against.
  /// @dev Reverts if no snapshot exists or none has cleared the activation delay.
  function latestActiveSmtRoot(bytes32 registryId) external view returns (bytes32);
}
