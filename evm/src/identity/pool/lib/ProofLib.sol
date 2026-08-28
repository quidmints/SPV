// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title ProofLib
 * @notice Facilitates accessing the public signals of a Noir/Honk proof. BOTH pool proofs -
 *         withdrawal and ragequit - are Honk; the Groth16 stack this library was written for is
 *         gone, along with the `pA`/`pB`/`pC` points its structs used to carry.
 * @custom:semver 0.1.0
 */
library ProofLib {
  /*///////////////////////////////////////////////////////////////
                         WITHDRAWAL PROOF 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Struct containing a Noir/Honk proof and public signals for withdrawal verification
   * @dev Withdrawal is identity-based-ASP (backend/circuits/withdraw_identity), Noir/Honk-proved,
   * NOT Groth16 - see State.sol's WITHDRAWAL_VERIFIER (INoirVerifier). `proof` is the serialized
   * Honk proof (`bb prove_ultra_keccak_honk` output); `pubSignals` is EIGHT slots - seven, plus the
   * taint root carrying the Privacy Pools EXCLUSION predicate (sec. 2.18gz-unify). As of the single
   * identity tree (sec. 2.13k) - `ASPRoot` + `revocationRoot` collapsed into one
   * `identityRoot`, and `ASPTreeDepth` disappeared with the LeanIMT identity tree, since the SMT's
   * depth is fixed. Converted to `bytes32[]` only at the verifier-call boundary (`publicInputsBytes32`) since
   * INoirVerifier.verify expects `bytes32[] calldata`, matching every other Noir verifier call in
   * this fusion (see RegistrationSimple._verifyNoirZKProof for the same pattern).
   * @param proof The serialized Honk proof bytes
   * @param pubSignals Array of public inputs and outputs:
   *        - [0] newCommitmentHash: Hash of the new commitment being created
   *        - [1] existingNullifierHash: Hash of the nullifier being spent
   *        - [2] withdrawnValue: Amount being withdrawn
   *        - [3] stateRoot: Current state root of the privacy pool
   *        - [4] stateTreeDepth: Current depth of the state tree
   *        - [5] identityRoot: Root of the IdentityRegistry. The proof shows the withdrawer's
   *              escrow commitment is present there carrying the CLEAN status (value 0), which is
   *              simultaneously "registered" and "not revoked" - one proof, not two.
   *        - [6] context: Context value for the withdrawal operation
   */
  struct WithdrawProof {
    bytes proof;
    uint256[8] pubSignals;
  }

  /**
   * @notice Converts `pubSignals` to the `bytes32[]` shape INoirVerifier.verify expects, with
   * `context` supplied by the CALLER rather than taken from the proof. A fixed array can't be
   * implicitly cast to a dynamic one in Solidity, so this copies element-by-element - the same
   * thing RegistrationSimple._verifyNoirZKProof already does manually for its own
   * (differently-shaped) public inputs.
   *
   * WHY `context_` IS A PARAMETER AND NOT `_p.pubSignals[6]`.
   *
   * `context` is the only public signal that names WHO GETS PAID - it is
   * `keccak256(abi.encode(withdrawal, SCOPE)) % SNARK_SCALAR_FIELD`, covering the recipient, the
   * fee and the pool. Every other signal is equally true whoever receives the money, so if the
   * proof's own `context` were fed back to the verifier, verification would prove only that the
   * prover once chose SOME context - never that it describes THIS withdrawal. What ties the two
   * together has to come from outside the proof.
   *
   * That used to be a separate equality check in `PrivacyPool.validWithdrawal`, and it worked. The
   * problem was its SHAPE: a comparison is deletable. Remove those three lines and every test but
   * one still passes, the happy path still works, and the binding between a proof and its recipient
   * is gone with no symptom - the worst kind of regression, because the code that remains looks
   * complete. Passing the derived value as an ARGUMENT removes that failure mode by construction:
   * the verifier cannot be called without a context, so there is no line whose deletion silently
   * weakens anything. Delete the derivation and the contract does not compile.
   *
   * The admission set is unchanged. A proof made for this withdrawal has `pubSignals[6] ==
   * context_` and verifies exactly as before; one made for a different withdrawal now fails inside
   * the verifier instead of at a preceding `require`.
   *
   * @param _p The proof containing the public signals
   * @param context_ The context the CALLER derived from the withdrawal data it holds
   * @return _publicInputs The public signals as a dynamic bytes32 array, in the same order
   */
  function publicInputsBytes32(
    WithdrawProof memory _p,
    uint256 context_,
    uint256 blacklistRoot_
  ) internal pure returns (bytes32[] memory _publicInputs) {
    _publicInputs = new bytes32[](8);
    for (uint256 _i = 0; _i < 6; ++_i) {
      _publicInputs[_i] = bytes32(_p.pubSignals[_i]);
    }
    _publicInputs[6] = bytes32(context_);
    // ⚠️ SUBSTITUTED, NOT READ FROM THE PROOF - for the same reason as `context_` above, and it
    // matters more here. A prover-supplied taint root would let them prove exclusion from an EMPTY
    // tree of their own choosing, and the non-association predicate would be vacuous while looking
    // enforced. The caller passes the ANCHORED root; the proof is simply bound to whatever it was.
    _publicInputs[7] = bytes32(blacklistRoot_);
  }

  /**
   * @notice Retrieves the new commitment hash from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The hash of the new commitment being created
   */
  function newCommitmentHash(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[0];
  }

  /**
   * @notice Retrieves the existing nullifier hash from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The hash of the nullifier being spent in this withdrawal
   */
  function existingNullifierHash(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[1];
  }

  /**
   * @notice Retrieves the withdrawn value from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The amount being withdrawn from Privacy Pool
   */
  function withdrawnValue(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[2];
  }

  /**
   * @notice Retrieves the state root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The root of the state tree at time of proof generation
   */
  function stateRoot(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[3];
  }

  /**
   * @notice Retrieves the state tree depth from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The depth of the state tree at time of proof generation
   */
  function stateTreeDepth(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[4];
  }

  /**
   * @notice Retrieves the identity registry root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The latest root of the ASP tree at time of proof generation
   */
  function identityRoot(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[5];
  }


  /**
   * @notice Retrieves the context value from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The context value binding the proof to specific withdrawal data
   */
  function context(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[6];
  }


  /*///////////////////////////////////////////////////////////////
                          RAGEQUIT PROOF 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Honk proof + public signals for ragequit verification.
   * @dev PORTED FROM GROTH16 2026-07-27. Upstream shipped this as Groth16 with a CommitmentVerifier
   *      but no circuit source, so no proof could be produced at all (sec. 2.5b). Rebuilt as
   *      a Noir circuit so the fusion keeps ONE proving stack; the 4 public signals and their order
   *      are unchanged, so every accessor below still reads the same slot.
   * @dev The public signals array must match the order of public inputs/outputs in the circuit
   * @param proof The serialized Honk proof (`bb prove_ultra_keccak_honk` output)
   * @param pubSignals Array of public inputs and outputs:
   *        - [0] commitmentHash: Hash of the commitment being ragequit
   *        - [1] nullifierHash: Nullifier hash of commitment being ragequit
   *        - [2] value: Value of the commitment being ragequit
   *        - [3] label: Label of commitment
   */
  struct RagequitProof {
    bytes proof;
    uint256[4] pubSignals;
  }

  /// @notice Converts ragequit `pubSignals` to the `bytes32[]` INoirVerifier.verify expects.
  /// @dev Mirrors publicInputsBytes32 for withdrawals - see that function's note on why the
  ///      conversion lives here rather than at each call site.
  function ragequitPublicInputsBytes32(RagequitProof memory _p)
    internal
    pure
    returns (bytes32[] memory _publicInputs)
  {
    _publicInputs = new bytes32[](4);
    for (uint256 _i = 0; _i < 4; ++_i) {
      _publicInputs[_i] = bytes32(_p.pubSignals[_i]);
    }
  }

  /**
   * @notice Retrieves the new commitment hash from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The new commitment hash
   */
  function commitmentHash(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[0];
  }

  /**
   * @notice Retrieves the nullifier hash from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The nullifier hash
   */
  function nullifierHash(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[1];
  }

  /**
   * @notice Retrieves the commitment value from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The commitment value
   */
  function value(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[2];
  }

  /**
   * @notice Retrieves the commitment label from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The commitment label
   */
  function label(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[3];
  }
}
