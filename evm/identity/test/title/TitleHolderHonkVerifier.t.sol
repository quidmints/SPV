// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {TitleHolderHonkVerifier} from '../../contracts/title/TitleHolderHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';

/*
 * End-to-end check that `bb`-generated Solidity actually verifies a REAL `bb`-produced proof
 * on-chain. This is the step PP-NOIR-FUSION.md's P0 spike only ever ran against a trivial
 * throwaway circuit - here it runs against a real circuit in this tree (`pp::title_holder`), so
 * the keccak-transcript prove/write_vk/write_solidity_verifier pairing is confirmed for a
 * production circuit, not just in principle.
 *
 * Fixture provenance (regenerate with `backend/circuits/codegen-verifiers.sh`):
 *   nargo execute       Prover.toml = the gadget's own published test vector
 *                       (sk_identity=1234, title_id=777)
 *   bb prove    --scheme ultra_honk --oracle_hash keccak
 *   bb write_vk --scheme ultra_honk --oracle_hash keccak   -> baked into the verifier contract
 *
 * `test/fixtures/title_holder.proof` is the raw `bb` proof with its 4-byte field count and its 2
 * leading public-input fields stripped, because INoirVerifier.verify takes those separately.
 */
contract TitleHolderHonkVerifierTest is Test {
  INoirVerifier internal verifier;

  /*
   * Poseidon2(holder_root(sk_identity=1234), 777) - the value pp/src/title_holder.nr's own test
   * vector pins, independently cross-checked against the wallet's iden3 js-crypto primitives per
   * that file's header.
   */
  bytes32 internal constant EXPECTED_COMMITMENT =
    0x218e902a5e98543a8a34f2a2a09d0226a6dc5b2d835d16f16e99850b2b6bf441;
  bytes32 internal constant TITLE_ID = bytes32(uint256(777));

  function setUp() public {
    verifier = INoirVerifier(address(new TitleHolderHonkVerifier()));
  }

  function _proof() internal view returns (bytes memory) {
    return vm.readFileBinary('test/fixtures/title_holder.proof');
  }

  function _publicInputs() internal pure returns (bytes32[] memory _inputs) {
    _inputs = new bytes32[](2);
    _inputs[0] = EXPECTED_COMMITMENT;
    _inputs[1] = TITLE_ID;
  }

  /// @notice The positive case: a genuine proof verifies against the generated verifier on-chain.
  function test_VerifiesRealProof() public view {
    assertTrue(verifier.verify(_proof(), _publicInputs()));
  }

  /// @notice Same valid proof, tampered public input. If this passed, the public inputs would not
  /// be bound into the transcript and the verifier would be worthless.
  function test_RejectsTamperedCommitment() public {
    bytes32[] memory _inputs = _publicInputs();
    _inputs[0] = bytes32(uint256(EXPECTED_COMMITMENT) ^ 1);
    _assertRejects(_inputs);
  }

  /// @notice Second public input tampered, same reasoning - covers position 1 as well as 0.
  function test_RejectsTamperedTitleId() public {
    bytes32[] memory _inputs = _publicInputs();
    _inputs[1] = bytes32(uint256(778));
    _assertRejects(_inputs);
  }

  /// @dev A rejection is either `false` or a revert (SumcheckFailed etc.) - both are correct.
  function _assertRejects(bytes32[] memory _inputs) internal {
    bytes memory _p = _proof();
    try verifier.verify(_p, _inputs) returns (bool _ok) {
      assertFalse(_ok);
    } catch {
      assertTrue(true);
    }
  }
}
