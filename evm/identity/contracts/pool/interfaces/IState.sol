// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IEntrypoint} from 'interfaces/IEntrypoint.sol';

import {INoirVerifier} from '../../interfaces/verifiers/INoirVerifier.sol';

/**
 * @title IState
 * @notice Interface for the State contract
 */
interface IState {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when inserting a leaf into the Merkle Tree
   * @param _index The index of the leaf in the tree
   * @param _leaf The leaf value
   * @param _root The updated root
   */
  event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root);

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when trying to call a method only available to the Entrypoint
   */
  error OnlyEntrypoint();

  /**
   * @notice Thrown when trying to deposit into a dead pool
   */
  error PoolIsDead();

  /**
   * @notice Thrown when trying to spend a nullifier that has already been spent
   */
  error NullifierAlreadySpent();

  /**
   * @notice Thrown when trying to initiate the ragequitting process of a commitment before the waiting period
   */
  error NotYetRagequitteable();

  /**
   * @notice Thrown when the max tree depth is reached and no more commitments can be inserted
   */
  error MaxTreeDepthReached();

  /**
   * @notice Thrown when trying to set a state variable as address zero
   */
  error ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                              VIEWS 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the pool unique identifier
   * @return _scope The scope id
   */
  function SCOPE() external view returns (uint256 _scope);

  /**
   * @notice Returns the pool asset
   * @return _asset The asset address
   */
  function ASSET() external view returns (address _asset);

  /**
   * @notice Returns the root history size for root caching
   * @return _size The amount of valid roots to store
   */
  function ROOT_HISTORY_SIZE() external view returns (uint32 _size);

  /**
   * @notice Returns the maximum depth of the state tree
   * @dev Merkle tree depth must be capped at a fixed maximum because zero-knowledge circuits
   * compile to R1CS (Rank-1 Constraint System) constraints that must be determined at compile time.
   * R1CS cannot handle dynamic loops or recursion - all computation paths must be fully "unrolled"
   * into a fixed number of constraints. Since each level of the Merkle tree requires its own set
   * of constraints for hashing and path verification, we need to set a maximum depth that determines
   * the total constraint size of the circuit.
   * @return _maxDepth The max depth
   */
  function MAX_TREE_DEPTH() external view returns (uint32 _maxDepth);

  /**
   * @notice Returns the configured Entrypoint contract
   * @return _entrypoint The Entrypoint contract
   */
  function ENTRYPOINT() external view returns (IEntrypoint _entrypoint);

  /**
   * @notice Returns the configured Noir/Honk verifier contract for withdrawals - identity-based
   * ASP withdrawals (withdraw_identity circuit) are Noir-proved. SO IS RAGEQUIT: both verifiers are
   * `INoirVerifier` and no Groth16 path remains in this pool. An earlier note here said
   * `RAGEQUIT_VERIFIER` stayed Groth16, which was true only in the window between the two ports.
   * @return _verifier The Verifier contract
   */
  function WITHDRAWAL_VERIFIER() external view returns (INoirVerifier _verifier);

  /**
   * @notice Returns the configured Noir/Honk verifier for ragequits
   * @dev Honk since 2026-07-27. Upstream shipped a Groth16 CommitmentVerifier with no circuit
   *      source, so no ragequit proof could be produced at all - see sec. 2.5b.
   * @return _verifier The verifier contract
   */
  function RAGEQUIT_VERIFIER() external view returns (INoirVerifier _verifier);

  /**
   * @notice Returns the current root index
   * @return _index The current index
   */
  function currentRootIndex() external view returns (uint32 _index);

  /**
   * @notice Returns the current state root
   * @return _root The current state root
   */
  function currentRoot() external view returns (uint256 _root);

  /**
   * @notice Returns the current state tree depth
   * @return _depth The current state tree depth
   */
  function currentTreeDepth() external view returns (uint256 _depth);

  /**
   * @notice Returns the current state tree size
   * @return _size The current state tree size
   */
  function currentTreeSize() external view returns (uint256 _size);

  /**
   * @notice Returns the current label nonce
   * @return _nonce The current nonce
   */
  function nonce() external view returns (uint256 _nonce);

  /**
   * @notice Returns the boolean indicating if the pool is dead
   * @return _dead The dead boolean
   */
  function dead() external view returns (bool _dead);

  /**
   * @notice Returns the root stored at an index
   * @param _index The root index
   * @return _root The root value
   */
  function roots(uint256 _index) external view returns (uint256 _root);

  /**
   * @notice Returns the spending status of a nullifier hash
   * @param _nullifierHash The nullifier hash
   * @return _spent The boolean indicating if it is spent
   */
  function nullifierHashes(uint256 _nullifierHash) external view returns (bool _spent);

  /**
   * @notice Returns the original depositor that generated a label
   * @param _label The label
   * @return _depositor The original depositor
   */
  function depositors(uint256 _label) external view returns (address _depositor);
}
