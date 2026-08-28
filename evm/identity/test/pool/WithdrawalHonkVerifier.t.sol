// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {WithdrawalHonkVerifier} from '../../contracts/pool/verifiers/WithdrawalHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';
import {ProofLib} from '../../contracts/pool/lib/ProofLib.sol';

/*
 * §2A Phase 0 - the baseline this project had been missing.
 *
 * Before this, `withdraw_identity`'s verifier was generated and compiled but had NEVER verified a
 * real proof (§2.12 said so explicitly). That made it impossible to attribute a future failure:
 * change the circuit, watch a proof fail, and you cannot tell whether the cause is your change or
 * the never-exercised path underneath it. This test establishes the known-good baseline that
 * §2A Phase 4 will regress against once the circuit gains `revocation_root`.
 *
 * It deliberately routes the public inputs through `ProofLib.publicInputsBytes32` - the SAME
 * conversion `PrivacyPool.withdraw` uses at line 122 - rather than hand-building a bytes32[]. A
 * hand-built array would test the verifier but not the production plumbing that feeds it, and an
 * ordering bug in ProofLib is exactly the kind of thing that survives a verifier-only test.
 *
 * FIXTURE PROVENANCE. Regenerate BOTH fixtures with `tools/build-withdrawal-fixture.js` - see that
 * file's header for the exact tsc / nargo / bb commands. It is deterministic (sk_identity pinned to
 * 1234, fixed mnemonic) and it writes the committed `Prover.baseline.toml` / `Prover.wallet.toml`,
 * so both fixtures are reproducible from the repo.
 *
 * The witness is a genuine satisfying assignment, not a weakened one:
 *   - Note values (10, 20, 30, 40) reuse pp/src/commitment.nr's differential-tested vector, whose
 *     commitment/nullifier_hash were cross-checked against poseidon-solidity. That independence
 *     from the wallet's own derivation is why this fixture is kept alongside the wallet one.
 *   - sk_identity = 1234 reuses pp/src/identity_asp.nr's published vector.
 *   - Withdraws 4 of 10, carrying 6 into a change note under the same label.
 *
 * REGENERATED 2026-07-27 TO REMOVE A DEGENERATE CASE. This fixture previously used size-1 trees:
 * pp::lean_imt carries a node up unchanged when its sibling is 0, so with a single leaf and
 * all-zero siblings the root simply IS the leaf, both depths were 0, and NO SIBLING WAS EVER
 * HASHED. That verified, but never exercised the Merkle path a withdrawal depends on. Both fixtures
 * now use state depth 3 / ASP depth 2 over trees with unrelated filler leaves; the generator
 * refuses to emit a depth-0 witness, and test_FixturesAreNotDegenerate below pins it here too.
 *
 * ON bb 1.2.0 THERE IS NOTHING TO STRIP. `bb prove` writes `target/proof` and `target/public_inputs`
 * as separate files and `target/proof` IS the fixture format. Earlier revisions of this comment
 * described stripping a 4-byte field count and 8 leading public-input fields - that was a 0.82.2-era
 * instruction from when the two were concatenated into one file.
 */
contract WithdrawalHonkVerifierTest is Test {
  using ProofLib for ProofLib.WithdrawProof;

  INoirVerifier internal verifier;

  /* ────────────────────────────────────────────────────────────────────────────────────────────
   * THE FIXTURE'S PUBLIC SIGNALS, READ FROM THE FIXTURE.
   *
   * These were pinned constants, and pinning is what made them dangerous rather than merely
   * inconvenient. A stale public input does not fail as "this number moved" - it fails as
   * `SumcheckFailed()`, which names nothing and sends the reader to the circuit and the verifier
   * first. Two of them moved in one change here (the identity root, when leaves began binding their
   * document) and a third appeared (the blacklist root, an eighth signal), and the only symptom was
   * a sumcheck failure on three tests.
   *
   * `tools/build-withdrawal-fixture.js` writes them beside the proof it generated them with, so the
   * pair cannot drift. Same argument as the registration root in IdentityRegistry's tests.
   * ──────────────────────────────────────────────────────────────────────────────────────────── */
  uint256 internal NEW_COMMITMENT;
  uint256 internal EXISTING_NULLIFIER_HASH;
  uint256 internal WITHDRAWN_VALUE;
  uint256 internal STATE_ROOT;
  uint256 internal STATE_TREE_DEPTH;
  uint256 internal IDENTITY_ROOT;
  uint256 internal CONTEXT;

  /// The blacklist root the fixture proves against. It was `BLACKLIST_ROOT = 0` and named honestly for
  /// what it then was; the tree is now populated, so a zero here would be a lie AND unsettleable -
  /// the pool refuses a zero root.
  uint256 internal BLACKLIST_ROOT;

  function _loadSignals(string memory profile_) internal view returns (uint256[8] memory out_) {
    bytes32[] memory raw_ = vm.parseJsonBytes32Array(
      vm.readFile('test/fixtures/withdraw_identity_pubsignals.json'), string.concat('.', profile_)
    );
    require(raw_.length == 8, 'fixture does not carry eight public signals');
    for (uint256 i = 0; i < 8; i++) out_[i] = uint256(raw_[i]);
  }

  function setUp() public {
    verifier = INoirVerifier(address(new WithdrawalHonkVerifier()));

    uint256[8] memory sig_ = _loadSignals('baseline');
    NEW_COMMITMENT = sig_[0];
    EXISTING_NULLIFIER_HASH = sig_[1];
    WITHDRAWN_VALUE = sig_[2];
    STATE_ROOT = sig_[3];
    STATE_TREE_DEPTH = sig_[4];
    IDENTITY_ROOT = sig_[5];
    CONTEXT = sig_[6];
    BLACKLIST_ROOT = sig_[7];

    uint256[8] memory wal_ = _loadSignals('wallet');
    W_NEW_COMMITMENT = wal_[0];
    W_EXISTING_NULLIFIER_HASH = wal_[1];
    W_WITHDRAWN_VALUE = wal_[2];
    W_STATE_ROOT = wal_[3];
    W_STATE_TREE_DEPTH = wal_[4];
    W_IDENTITY_ROOT = wal_[5];
    W_CONTEXT = wal_[6];

    // Both profiles prove against ONE tree, so one root serves both. Asserted rather than assumed:
    // if they ever diverged, only one could match the pool and the other's tests would fail as a
    // sumcheck error naming nothing.
    require(wal_[7] == BLACKLIST_ROOT, 'the two fixtures disagree on the blacklist root');
  }

  function _withdrawProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity.proof');
    _p.pubSignals = [
      NEW_COMMITMENT,
      EXISTING_NULLIFIER_HASH,
      WITHDRAWN_VALUE,
      STATE_ROOT,
      STATE_TREE_DEPTH,
      IDENTITY_ROOT,
      CONTEXT,
      BLACKLIST_ROOT // [7] the populated blacklist this fixture proves exclusion against
    ];
  }

  /// @notice The baseline: a genuine proof verifies on-chain through the production plumbing.
  function test_VerifiesRealProof() public view {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    assertTrue(verifier.verify(_p.proof, _p.publicInputsBytes32(_p.context(), BLACKLIST_ROOT)));

    // ISOLATED GAS, for the aggregation comparison (sec. 2.4). Measures ONLY the verify call, so it
    // is directly comparable to AggregationProofOnChain's per-withdrawal figure.
    {
      bytes32[] memory _pubs = _p.publicInputsBytes32(_p.context(), BLACKLIST_ROOT);
      uint256 _g0 = gasleft();
      verifier.verify(_p.proof, _pubs);
      console.log('single withdrawal verify() gas:', _g0 - gasleft());
    }
  }

  /// @notice ProofLib's accessors must agree with the fixture's slot ordering. If an accessor were
  /// mis-indexed, `PrivacyPool.withdraw` would read the wrong field while the proof still verified
  /// - a bug a verifier-only test cannot see.
  function test_ProofLibAccessorsMatchSlotOrder() public view {
    ProofLib.WithdrawProof memory _p;
    _p.pubSignals = [
      NEW_COMMITMENT,
      EXISTING_NULLIFIER_HASH,
      WITHDRAWN_VALUE,
      STATE_ROOT,
      STATE_TREE_DEPTH,
      IDENTITY_ROOT,
      CONTEXT,
      BLACKLIST_ROOT
    ];
    assertEq(_p.newCommitmentHash(), NEW_COMMITMENT);
    assertEq(_p.existingNullifierHash(), EXISTING_NULLIFIER_HASH);
    assertEq(_p.withdrawnValue(), WITHDRAWN_VALUE);
    assertEq(_p.stateRoot(), STATE_ROOT);
    assertEq(_p.stateTreeDepth(), STATE_TREE_DEPTH);
    assertEq(_p.identityRoot(), IDENTITY_ROOT);
    assertEq(_p.context(), CONTEXT);
  }

  /*
   * THE SECURITY-CRITICAL CASE. `context` is declared `pub` in the circuit but its body never
   * reads it - nargo emits "unused variable context" for exactly this. withdraw_identity's header
   * argues that `pub` binds it as a public input regardless, and the whole proof-to-recipient
   * binding depends on that being true: `PrivacyPool.withdraw` hands the verifier a context DERIVED
   * from the withdrawal data, so if the value were not bound into the transcript, that substitution
   * would prove nothing and any proof could be presented against any recipient.
   *
   * §2.12 inferred this from the verification key's publicInputsSize == 8. This proves it.
   */
  function test_RejectsTamperedContext() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[6] = CONTEXT + 1;
    _assertRejects(_p);
  }

  /*
   * THE SUBSTITUTION ITSELF, which is what actually enforces the binding (sec. 2.18ah).
   *
   * The test above tampers the proof struct - it shows the transcript is bound, but a caller does
   * not get to hand `PrivacyPool` a struct and have its context believed. `withdraw` ignores
   * `pubSignals[6]` entirely and passes `_contextFor(_withdrawal)` in its place. So the property
   * that matters is this one: an OTHERWISE-PERFECT proof, untouched, must fail when the context the
   * CONTRACT derives is not the one it was made for. That is precisely the replay attempt - the
   * same proof, a different recipient.
   *
   * This is what stops the binding vanishing silently. Before the substitution, the only thing
   * holding it up was an equality check three lines long in a modifier; delete it and nothing here
   * would have noticed, because every test still fed the prover's own context to the verifier and
   * so agreed with itself. Now the derived value is an argument, and this asserts the argument is
   * load-bearing rather than decorative.
   */
  function test_RejectsAContextTheContractDerivedDifferently() public view {
    ProofLib.WithdrawProof memory _p = _withdrawProof();

    // The proof is untouched and genuine - only the context the caller supplies differs, exactly as
    // it would if this proof were lifted and re-submitted against another processooor.
    bytes32[] memory _inputs = _p.publicInputsBytes32(CONTEXT + 1, BLACKLIST_ROOT);
    try verifier.verify(_p.proof, _inputs) returns (bool _ok) {
      assertFalse(_ok, 'a genuine proof verified under a context it was not made for');
    } catch {
      assertTrue(true);
    }

    // ...and the same call with the correct derivation still passes, so the rejection above is the
    // binding doing its job and not the substitution being broken outright.
    assertTrue(
      verifier.verify(_p.proof, _p.publicInputsBytes32(CONTEXT, BLACKLIST_ROOT)), 'the correct context stopped verifying'
    );
  }

  function test_RejectsTamperedWithdrawnValue() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[2] = WITHDRAWN_VALUE + 1;
    _assertRejects(_p);
  }

  /// @notice An attacker substituting a different ASP root - the exact move §2.13's lever analysis
  /// turns on - must not produce a passing proof.
  function test_RejectsTamperedAspRoot() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[5] = IDENTITY_ROOT ^ 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedNullifierHash() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[1] = EXISTING_NULLIFIER_HASH ^ 1;
    _assertRejects(_p);
  }

  /*
   * ─────────────────────────────────────────────────────────────────────────────────────────────
   * WALLET-PRODUCED WITNESS (sec. 2.1, landed 2026-07-27).
   *
   * Everything above proves the VERIFIER works. This proves the WALLET works: the witness below
   * was assembled by frontend/identity-wallet/src/pp/withdrawWitness.ts from a note discovered
   * through the wallet's own derivation, an inclusion path from src/pp/stateTree.ts, and an ASP
   * path from src/postman/identityAsp.ts - not hand-built. It is the first end-to-end evidence
   * that the client can produce a withdrawal the chain accepts.
   *
   * WHAT IT ADDS OVER THE BASELINE is provenance, not tree shape - both fixtures now use state
   * depth 3 / ASP depth 2 (see the file header; the baseline's former size-1 degeneracy was
   * removed in the same change). The baseline's spent note is an independent hand vector, so it
   * still catches a wallet that is self-consistently wrong; this one proves the wallet's real
   * derivation path produces something the chain accepts. Neither subsumes the other.
   *
   * Regenerate with tools/build-withdrawal-fixture.js - it emits both fixtures' Prover.*.toml.
   */
  /// The wallet profile's signals, read from the same emitted fixture for the same reason - see
  /// the note on the baseline block above.
  uint256 internal W_NEW_COMMITMENT;
  uint256 internal W_EXISTING_NULLIFIER_HASH;
  uint256 internal W_WITHDRAWN_VALUE;
  uint256 internal W_STATE_ROOT;
  uint256 internal W_STATE_TREE_DEPTH;
  uint256 internal W_IDENTITY_ROOT;
  uint256 internal W_CONTEXT;

  function _walletProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity_wallet.proof');
    _p.pubSignals = [
      W_NEW_COMMITMENT,
      W_EXISTING_NULLIFIER_HASH,
      W_WITHDRAWN_VALUE,
      W_STATE_ROOT,
      W_STATE_TREE_DEPTH,
      W_IDENTITY_ROOT,
      W_CONTEXT,
      BLACKLIST_ROOT
    ];
  }

  /// @notice The end-to-end case: a proof over a WALLET-ASSEMBLED witness verifies on-chain.
  function test_VerifiesWalletAssembledWitness() public view {
    ProofLib.WithdrawProof memory _p = _walletProof();
    assertTrue(verifier.verify(_p.proof, _p.publicInputsBytes32(_p.context(), BLACKLIST_ROOT)));
  }

  /// @notice Guards BOTH fixtures against silently regressing to the degenerate size-1 shape this
  /// suite used to have. A depth-0 witness still verifies - the proof is valid - so nothing else
  /// here would fail; the suite would simply stop covering multi-level sibling hashing. That is
  /// the failure mode worth pinning: a green test that has quietly stopped testing anything.
  /// tools/build-withdrawal-fixture.js refuses to emit depth 0; this is the second line.
  ///
  /// COVERAGE MOVED, NOT DROPPED. The ASP tree's depth used to be a PUBLIC signal, so its
  /// degeneracy could be asserted right here. The identity witness is now an SMT inclusion path
  /// carried entirely in PRIVATE inputs (sec. 2.13k), so nothing about it is visible from
  /// `pubSignals` and this test physically cannot see it. That check now lives at the two places
  /// that CAN see it: WithdrawEndToEnd asserts the live registry returns a non-empty sibling path
  /// for the fixture's commitment, and IdentityRegistry.t.sol's emitter asserts the same before
  /// writing the witness at all. Recorded explicitly because a silently narrower degeneracy check
  /// is exactly the "green test that stopped testing anything" this function exists to prevent.
  function test_FixturesAreNotDegenerate() public view {
    assertGt(STATE_TREE_DEPTH, 0, 'baseline state tree is degenerate - no siblings hashed');
    assertGt(W_STATE_TREE_DEPTH, 0, 'wallet state tree is degenerate - no siblings hashed');
  }

  /// @notice The wallet path must be no weaker than the baseline against public-input tampering.
  function test_RejectsTamperedWalletStateRoot() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[3] = W_STATE_ROOT ^ 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedWalletContext() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[6] = W_CONTEXT + 1;
    _assertRejects(_p);
  }

  /// @notice Cross-fixture guard: the baseline proof must NOT verify against the wallet witness's
  /// public inputs. Both are valid proofs of the same circuit, so nothing but the transcript
  /// binding stops one being presented with the other's signals.
  function test_BaselineProofDoesNotVerifyWalletSignals() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity.proof');
    _assertRejects(_p);
  }

  /// @dev A rejection is either `false` or a revert (SumcheckFailed etc.) - both are correct.
  function _assertRejects(ProofLib.WithdrawProof memory _p) internal view {
    bytes32[] memory _inputs = _p.publicInputsBytes32(_p.context(), BLACKLIST_ROOT);
    try verifier.verify(_p.proof, _inputs) returns (bool _ok) {
      assertFalse(_ok);
    } catch {
      assertTrue(true);
    }
  }
}
