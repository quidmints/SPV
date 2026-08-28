// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title IIdentityRegistry
 * @notice The single identity tree a withdrawal proves clearance against (sec. 2.13k).
 * @dev Only the root check is needed by the pool. Deliberately narrow: the pool must not be able to
 *      write to the registry, and a wider interface would invite it.
 */
interface IIdentityRegistry {
  /**
   * @notice Whether `root_` may be proven against.
   * @dev `isValidRoot`, NOT "is known". This tree carries REVOCATIONS as leaf values, so honouring
   *      an old root indefinitely would let a revoked identity prove the clean state forever. The
   *      registry expires superseded roots while keeping the LATEST valid regardless of age, so
   *      controller inaction can never block a withdrawal.
   */
  function isValidRoot(bytes32 root_) external view returns (bool);
}
