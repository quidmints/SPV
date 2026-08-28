// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {RegisterIdentityLightID256HonkVerifier} from
  '../../contracts/passport/verifiers/RegisterIdentityLightID256HonkVerifier.sol';

/*
 * THE FIRST PASSPORT-REGISTRATION VERIFIER THIS REPO CAN ACTUALLY PROVE AGAINST (task 24).
 *
 * WHAT WAS WRONG, AND IT WAS NOT WHAT THE TRACKER SAID. The debt was recorded as "76 passport
 * verifiers generated on beta.13, in no regeneration script". Those 76
 * `passport/verifiers2/noir/NoirRegisterIdentity_*.sol` arrived in the fork import 0762975, have
 * never been modified since, and are referenced by no contract, test or script in this repo - they
 * are rarimo's, generated from 76 parameterised circuit profiles WE DO NOT HAVE. There is no
 * generator here, so "regenerate them" is not an operation this repo can perform.
 *
 * The real gap sat behind them: the identity circuits we DO have had NO generated verifier at all,
 * and none was in `codegen-verifiers.sh`'s TARGETS. So the registration path had 76 verifiers it
 * cannot use and zero it can.
 *
 * WHY THIS CIRCUIT FIRST. Of the five identity circuits, `register_identity_light_td1` is the only
 * one with a committed witness, so it is the only one that can be PROVEN and therefore the only one
 * whose verifier can be tested rather than merely emitted. The other four (including
 * `register_identity_td1`, which the permissionless ICAO path needs) can have verifiers generated,
 * but nothing can produce a proof for them until a real document exists - that is task 6's block,
 * not a toolchain one. An untested verifier is exactly the artifact this project's rules refuse.
 *
 * FIXTURE PROVENANCE. `test/fixtures/register_identity_light_td1.proof` is a real `bb 6.0.0-nightly`
 * proof over
 * the circuit's committed `Prover.toml`, accepted by native `bb verify` before it was ever brought
 * here, generated on the LOCALLY PATCHED nargo (`1.0.0-beta.26+quid-icefix1`) - stock beta.26 ICEs
 * on this crate's dependency, which is the whole reason the patched compiler exists. The three
 * public inputs below are the circuit's own return tuple, copied from `bb`'s `public_inputs` output.
 * Regenerate both together via `codegen-verifiers.sh`; a proof and its inputs are one artifact.
 */
contract RegisterIdentityLightID256HonkVerifierTest is Test {
  RegisterIdentityLightID256HonkVerifier internal verifier;

  function setUp() public {
    verifier = new RegisterIdentityLightID256HonkVerifier();
  }

  function _proof() internal view returns (bytes memory) {
    return vm.readFileBinary('test/fixtures/register_identity_light_td1.proof');
  }

  function _publicInputs() internal pure returns (bytes32[] memory _inputs) {
    _inputs = new bytes32[](3);
    _inputs[0] = bytes32(0x1e81bf7f919dcd3cab681eb93bf6e45064af202e7c62084e9db282398cbe64ab);
    _inputs[1] = bytes32(0x000e466b6bb4940d7ea57859a294989862a6cd4d8e52809829c0333b527bc043);
    _inputs[2] = bytes32(0x041fac4b0e00e2c67d9052a4dfed6723512dae91d7c06f4b928a0132fe08bc9d);
  }

  /// THE BASELINE: a real proof from the real circuit is accepted by the generated verifier.
  function test_aGenuineProofVerifiesOnChain() public view {
    assertTrue(verifier.verify(_proof(), _publicInputs()), 'the generated verifier rejects its own circuit');
  }

  /// AND IT IS NOT VACUOUS, which is the half that catches a verifier accepting anything. Each
  /// public input is tampered in turn: the dg1 commitment, the identity key, and the third signal.
  /// Task 30 is why this matters here - a valid proof of a DIFFERENT statement is accepted by
  /// `bb verify` and must be rejected on-chain, and only pinned public inputs make that visible.
  function test_eachTamperedPublicInputIsRejected() public {
    for (uint256 i = 0; i < 3; ++i) {
      bytes32[] memory _inputs = _publicInputs();
      _inputs[i] = bytes32(uint256(_inputs[i]) ^ 1);
      _assertRejects(_inputs, 'a tampered public input was accepted');
    }
  }

  /// A truncated proof must revert rather than return false - the verifier reads fixed offsets.
  function test_aTruncatedProofIsRejected() public {
    bytes memory _p = _proof();
    bytes memory _short = new bytes(_p.length - 32);
    for (uint256 i = 0; i < _short.length; ++i) _short[i] = _p[i];

    vm.expectRevert();
    verifier.verify(_short, _publicInputs());
  }

  function _assertRejects(bytes32[] memory _inputs, string memory _why) internal {
    bytes memory _p = _proof();
    try verifier.verify(_p, _inputs) returns (bool _ok) {
      assertFalse(_ok, _why);
    } catch {
      // A revert is a rejection too - the generated verifier signals both ways.
    }
  }
}
