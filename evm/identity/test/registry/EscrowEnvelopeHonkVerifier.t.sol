// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {EscrowEnvelopeHonkVerifier} from '../../contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';

/*
 * sec. 2.13d/2.13f - on-chain verification of a REAL escrow_envelope proof.
 *
 * WHY THIS EXISTS given no registry contract consumes this verifier yet. A generated verifier that
 * has never accepted a real proof is a liability, not an asset: when the registry lands and a proof
 * fails, there is no way to tell whether the cause is the new contract or the never-exercised
 * verifier underneath it. WithdrawalHonkVerifier spent a whole phase in exactly that state
 * (sec. 2.3), and this test exists so escrow_envelope never does.
 *
 * BOTH FIXTURES ARE READ FROM DISK, and the named constants are CHECKED AGAINST the public-inputs
 * fixture rather than being the source of truth. Hand-transcribing twelve 77-digit field elements is
 * the obvious place for this test to rot: a typo would make it fail for a reason having nothing to
 * do with the verifier. Reading `escrow_envelope.public` and asserting the constants match it keeps
 * the documentation value of names while making drift impossible.
 *
 * FIXTURE PROVENANCE. Both files are emitted by backend/circuits/codegen-verifiers.sh from the
 * committed backend/circuits/escrow_envelope/Prover.toml. Every value in that witness was produced
 * by @iden3/js-crypto and Node's sha256 - the same primitives the wallet uses - and then accepted by
 * the Noir circuit, so this is a genuine cross-implementation agreement rather than a
 * self-consistent loop. That matters most for `dg1_hash`, which must match registration's own
 * digest-packing convention exactly (skip digest[0], read the remaining 31 bytes big-endian); any
 * other packing yields a different field and would bind the sealed MRZ to a value nothing else
 * agrees with.
 *
 * THE WITNESS IS NOT DEGENERATE:
 *   - `ephemeral` is 55555, not 0. Zero collapses the shared secret to this ladder's (0,0) sentinel
 *     for EVERY controller key, making the mask a public constant and the sealed payload readable
 *     by anyone - see pp/src/envelope.nr::test_zero_ephemeral_would_have_leaked_the_payload.
 *   - `sk_identity` reuses pp/src/identity_asp.nr's published vector.
 *   - The DG1 is a full 95-byte TD1 layout carrying a real MRZ, not zeros. TD1, NOT TD3: 95 bytes
 *     is the ID-CARD layout (3 MRZ lines x 30 chars + a 5-byte header). A passport booklet is TD3,
 *     2 x 44 chars, and its DG1 is 93 bytes - a different circuit entirely. See sec. 2.18j;
 *     this fixture carries a passport-style MRZ inside a TD1-sized buffer, which is fine as a test
 *     vector because nothing here parses the MRZ, and misleading if read as a real document.
 *
 * EIP-170: 24,491 bytes with `optimizer_runs = 1` scoped to it in foundry.toml, leaving 85 bytes.
 * WITHOUT that scoping it compiled to 25,503 and was undeployable. Note the cause was the OPTIMIZER
 * SETTING, not the public-input count: this circuit has 11 public inputs and measures 24,491, while
 * TitleHolder has 2 and measures the same 24,491. Verifier size here is essentially flat in input
 * count, so `forge build --sizes` still needs checking after changes, but adding a public input is
 * not the thing to fear.
 */
contract EscrowEnvelopeHonkVerifierTest is Test {
  INoirVerifier internal verifier;

  /// WAS 12. `holder_root` (slot 2) and `dg1_hash` (slot 4) were removed in sec. 2.18:
  /// both were per-person identifiers, so registration calldata linked every user's identity to
  /// their pool handle. What replaced them is `registration_root`, which every user shares.
  /// Six fixed signals plus a ONE-field envelope. Was 11 while the envelope carried the packed MRZ;
  /// the fixture length assertion below is what catches a regeneration that disagrees.
  uint256 internal constant PUBLIC_INPUT_COUNT = 7;

  /// babyJub.mulPointEScalar(babyJub.Base8, 1234) - the controller's published sealing key. Pinned
  /// in pp/src/envelope.nr::test_controller_key_matches_babyjub.
  uint256 internal constant CONTROLLER_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  /// Poseidon(revocation_secret) - what the registered-identity leaf stores, and the key the
  /// controller would list this identity under.
  ///
  /// CHANGED WITH THE SECRET'S DERIVATION (sec. 2.18a). The secret used to be a chosen constant;
  /// it is now `Poseidon(sk_identity, "pp:revocation-secret:v1")`, so one identity yields exactly
  /// one commitment and a revoked user cannot come back under a fresh one.
  ///
  /// CHANGED AGAIN WHEN THE LEAF BOUND ITS DOCUMENT. It is now
  /// `Poseidon(revocation_secret, document_identifier(issuing_state, document_number))`, both MRZ
  /// fields read in-circuit at their TD1 offsets. Binding the document is what stops a withdrawal
  /// proving "some registered identity" and then naming any document for the sanctions check.
  uint256 internal constant COMMITMENT =
    1_033_954_587_113_401_687_578_337_807_612_992_032_577_078_892_099_597_077_696_246_758_189_239_049_656;
  /// The root of `registrationSmt` this witness proves inclusion against, READ FROM THE FILE the
  /// emitter writes rather than pinned as a constant.
  ///
  /// IT WAS A CONSTANT, AND THAT IS A DEFECT NOT A STYLE. The root depends on how many documents are
  /// bound, so growing the identity set from 3 to 16 made the pinned value stale - and a pinned value
  /// can only ever tell you that THIS side changed, never that the two sides disagree. That is the
  /// same shape that let `BatchCommitmentLib` diverge from its circuit unnoticed (2.18ec). Reading it
  /// means the proof and the emitter are compared to each other, which is the actual question.
  function _registrationRoot() internal view returns (uint256) {
    return uint256(
      vm.parseJsonBytes32(vm.readFile('test/fixtures/registration_witness.json'), '.root')
    );
  }

  /// First sealed slot. Moved 7 -> 6 with the two removed inputs; named so the distinctness test
  /// below cannot silently start comparing the wrong slots.
  uint256 internal constant SEALED_0 = 6;

  function setUp() public {
    verifier = INoirVerifier(address(new EscrowEnvelopeHonkVerifier()));
  }

  function _proof() internal view returns (bytes memory) {
    return vm.readFileBinary('test/fixtures/escrow_envelope.proof');
  }

  function _publicInputs() internal view returns (bytes32[] memory _inputs) {
    bytes memory _raw = vm.readFileBinary('test/fixtures/escrow_envelope.public');
    require(_raw.length == PUBLIC_INPUT_COUNT * 32, 'public-inputs fixture has the wrong length');

    _inputs = new bytes32[](PUBLIC_INPUT_COUNT);
    for (uint256 _i = 0; _i < PUBLIC_INPUT_COUNT; _i++) {
      bytes32 _word;
      assembly {
        _word := mload(add(_raw, add(32, mul(_i, 32))))
      }
      _inputs[_i] = _word;
    }
  }

  /// The baseline: a genuine escrow proof verifies on-chain.
  function test_VerifiesRealProof() public view {
    assertTrue(verifier.verify(_proof(), _publicInputs()));
  }

  /// The fixture must be the witness this test claims it is. Without this, the proof and the
  /// public inputs could both be regenerated from a DIFFERENT witness and everything would still
  /// pass while testing something else entirely.
  function test_FixtureIsTheDocumentedWitness() public view {
    bytes32[] memory _inputs = _publicInputs();
    assertEq(uint256(_inputs[0]), CONTROLLER_X, 'slot 0 is not the controller key');
    assertEq(uint256(_inputs[2]), COMMITMENT, 'slot 2 is not Poseidon(revocation_secret, document_id)');
    assertEq(uint256(_inputs[3]), _registrationRoot(), 'slot 3 is not the emitted registration root');
  }

  /// Every public input must be load-bearing. If any slot could be altered while the proof still
  /// verified, the registry could be handed a commitment or a ciphertext the proof does not cover -
  /// which is the entire guarantee escrow provides.
  function test_EveryPublicInputIsBinding() public view {
    bytes memory _p = _proof();

    for (uint256 _i = 0; _i < PUBLIC_INPUT_COUNT; _i++) {
      bytes32[] memory _tampered = _publicInputs();
      _tampered[_i] = bytes32(uint256(_tampered[_i]) + 1);

      // A tampered input makes this verifier REVERT (SumcheckFailed) rather than return false, so
      // both outcomes count as rejection. Asserting only `== false` fails against a verifier that
      // is behaving correctly - which is what the first run of this test did.
      (bool _ok, bytes memory _ret) =
        address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_p, _tampered)));
      bool _accepted = _ok && _ret.length == 32 && abi.decode(_ret, (bool));
      assertFalse(_accepted, 'a public input was not binding');
    }
  }

  /// The sealed MRZ words must actually differ from one another. Identical ciphertext across slots
  /// would mean the per-index mask is not being applied, so payload fields could be permuted
  /// undetectably - the property pp/src/envelope.nr's `mask` index exists to provide, asserted here
  /// against the REAL proof rather than only in-circuit.
  function test_SealedSlotsAreDistinct() public view {
    bytes32[] memory _inputs = _publicInputs();
    for (uint256 _i = SEALED_0; _i < PUBLIC_INPUT_COUNT; _i++) {
      for (uint256 _j = _i + 1; _j < PUBLIC_INPUT_COUNT; _j++) {
        assertTrue(_inputs[_i] != _inputs[_j], 'two sealed slots are identical');
      }
    }
  }

  /// A truncated proof must be rejected.
  function test_RejectsMalformedProof() public view {
    bytes memory _p = _proof();
    bytes memory _short = new bytes(_p.length - 32);
    for (uint256 _i = 0; _i < _short.length; _i++) {
      _short[_i] = _p[_i];
    }

    (bool _ok,) =
      address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_short, _publicInputs())));
    assertFalse(_ok, 'a truncated proof was accepted');
  }
}
