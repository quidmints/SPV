// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IdentityRegistry} from '../../../src/identity/registry/IdentityRegistry.sol';
import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {EscrowEnvelopeHonkVerifier} from '../../../src/identity/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {EscrowFixtureBase} from './EscrowFixtureBase.sol';

/*
 * sec. 2.13k/2.13m - the SINGLE identity tree, and every trap the merge creates.
 *
 * This suite drives the REAL escrow proof through the REAL verifier into the REAL state keeper.
 * Nothing here is mocked except the state keeper's registration gate, which is opened to this test
 * so a document can be planted without going through a passport proof.
 *
 * WHY EACH TRAP IS TESTED RATHER THAN ARGUED. Merging an inclusion tree and an exclusion tree gives
 * up protections the split provided structurally - most importantly the root-expiry asymmetry, which
 * I have already got WRONG once on RevocationRegistry (marking every root valid forever, safe for
 * inclusion, fatal for exclusion). Each guard below is therefore pinned by a test that fails if the
 * guard is removed, not by a comment asserting it holds.
 */
contract IdentityRegistryTest is EscrowFixtureBase {
  IdentityRegistry internal registry;

  uint256 internal constant MAX_ROOT_AGE = 1 days;

  /// escrow_envelope's public-input layout, mirroring IdentityRegistry's own constants. `holder_root`
  /// and `dg1_hash` used to sit at 2 and 4 and are GONE (sec. 2.18) - they linked every
  /// user's identity to their pool handle in registration calldata.
  /// Six fixed signals plus a ONE-field escrow envelope: `revocation_secret` and `document_id`.
  ///
  /// 🔴 IT WAS 11. The envelope carried the packed MRZ - name, date of birth, nationality - sealed to
  /// one controller key and emitted as an event, so it was permanently indexable. Shrinking the
  /// payload to what revocation actually needs moved this count with it.
  uint256 internal constant PUBLIC_INPUT_COUNT = 7;
  uint256 internal constant PUB_CONTROLLER_X = 0;
  uint256 internal constant PUB_COMMITMENT = 2;
  uint256 internal constant PUB_REGISTRATION_ROOT = 3;

  /// MUST equal withdraw_identity's IDENTITY_TREE_DEPTH and identityProof.ts's IDENTITY_TREE_DEPTH.
  /// Solarity's maxDepth is a CAP, so the ROOT is the same at any height - but a shallower registry
  /// would reject a deep insert the circuit accepts, and an emitted witness longer than the
  /// circuit's fixed sibling array cannot be padded into one.
  uint32 internal constant IDENTITY_TREE_DEPTH = 32;

  address internal CONTROLLER = address(0xC0FFEE);
  bytes32 internal constant PREDICATE_SANCTIONS = keccak256('OFAC_SDN');
  bytes32 internal constant PREDICATE_DOC_INVALID = keccak256('DOC_INVALID');

  /// From the committed escrow_envelope fixture - see EscrowEnvelopeHonkVerifier.t.sol.
  uint256 internal constant CONTROLLER_KEY_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  uint256 internal constant CONTROLLER_KEY_Y =
    6_509_666_988_291_764_283_313_685_078_036_329_297_907_336_602_650_572_952_945_826_675_203_643_401_307;

  function setUp() public {
    _setUpStateKeeper();

    bytes32[] memory preds = new bytes32[](2);
    preds[0] = PREDICATE_SANCTIONS;
    preds[1] = PREDICATE_DOC_INVALID;

    registry = new IdentityRegistry(
      address(new EscrowEnvelopeHonkVerifier()),
      address(sk),
      CONTROLLER,
      address(evidence),
      CONTROLLER_KEY_X,
      CONTROLLER_KEY_Y,
      IDENTITY_TREE_DEPTH,
      MAX_ROOT_AGE,
      preds
    );
  }

  function _proof() internal view returns (bytes memory) {
    return _proofAt(0);
  }

  function _proofAt(uint256 _i) internal view returns (bytes memory) {
    return vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_i), '.proof'));
  }

  function _publicInputs() internal view returns (bytes32[] memory) {
    return _publicInputsAt(0);
  }

  function _publicInputsAt(uint256 _n) internal view returns (bytes32[] memory _inputs) {
    bytes memory _raw =
      vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_n), '.public'));
    _inputs = new bytes32[](PUBLIC_INPUT_COUNT);
    for (uint256 _i = 0; _i < PUBLIC_INPUT_COUNT; _i++) {
      bytes32 _w;
      assembly {
        _w := mload(add(_raw, add(32, mul(_i, 32))))
      }
      _inputs[_i] = _w;
    }
  }

  /*
   * Rebuild the EXACT registration tree every escrow proof was built against.
   *
   * This replaces `_plantDocument`, which bound one document with `dgCommit = 111` and a documentKey
   * of its own invention. That worked while the contract only checked `holderOfDocumentHash`; since
   * sec. 2.18 the proof carries an SMT INCLUSION of the document's leaf, so a placeholder
   * commitment - or binding the documents in a different order, or at a different timestamp -
   * yields a different root and the proof no longer verifies. All three are bound because all three
   * are in the tree the witness was emitted from.
   */
  function _bindDocuments() internal {
    _bindDocumentsFromFixture();
  }

  /// The document key of fixture entry `_i`, read from the same JSON the witness was built from.
  function _documentKeyAt(uint256 _i) internal view returns (bytes32) {
    return vm.parseJsonBytes32(
      vm.readFile('test/fixtures/escrow_documents.json'),
      string.concat('.documents[', vm.toString(_i), '].documentKey')
    );
  }

  /// The holder root of fixture entry `_i`, from the same JSON - required by `revokeDocument` since
  /// sec. 2.18bi, because the keeper stores only `Poseidon(holderRoot)` and cannot hand it back.
  function _holderRootAt(uint256 _i) internal view returns (bytes32) {
    return vm.parseJsonBytes32(
      vm.readFile('test/fixtures/escrow_documents.json'),
      string.concat('.documents[', vm.toString(_i), '].holderRoot')
    );
  }

  /*
   * EMITS the identity inclusion witness the withdrawal fixture is built from.
   *
   * WHY THE TEST SUITE GENERATES IT. The wallet never rebuilds this tree - it asks the contract,
   * because a second implementation of a sparse trie is a permanent byte-compatibility liability
   * (see pp/identityProof.ts). The FIXTURE has to come from the same place for the same reason: a
   * witness built off-chain would only ever prove that two of our own implementations agree.
   * Regenerating it inside the suite means it cannot go stale against the contract.
   *
   * EVERY REGISTRATION IN THE FIXTURE, NOT THREE. The count comes from escrow_documents.json, so
   * growing the identity set is a generator argument rather than an edit here - and the withdrawal
   * batch stops having to CYCLE a handful of identities across sixteen members.
   *
   * SEVERAL REGISTRATIONS, NOT ONE. A single-leaf SMT has an EMPTY inclusion path, so a withdrawal
   * built on it would hash no siblings and prove nothing about the Merkle path - the same
   * degeneracy tools/build-withdrawal-fixture.js already refuses to emit for the state tree. Each
   * one goes through the real `register` with its own genuine escrow proof; there is deliberately
   * no privileged insert to shortcut with.
   *
   * ALL THREE WITNESSES ARE EMITTED, not just identity 0's. A folded batch is several DIFFERENT
   * people withdrawing against ONE registry root, and with a single witness on disk every withdrawal
   * in a batch would be the same person - which would let a fold that only ever works for
   * self-identical members pass as if it worked for a real batch. The three share `root` by
   * construction, because they are read out of the same tree at the same moment.
   *
   * THE SHAPE IS FLAT ON PURPOSE: one shared `root`, one `commitments` array, and `siblings`
   * concatenated at a fixed stride of `siblings.length / commitments.length`. Nesting objects
   * through `vm.serializeString` re-escapes them, and a reader that has to unescape JSON out of a
   * JSON string is a reader that will eventually be wrong about which layer it is on.
   */
  function test_EmitIdentityWitnessFixture() public {
    // The count comes from the BINDER's own return, which is the list of documents actually planted
    // in the keeper. Reading it from the JSON separately would let the two drift, and a registration
    // for an unbound document fails as an inclusion error naming neither.
    uint256 n = _bindDocumentsFromFixture().length;
    for (uint256 i = 0; i < n; i++) {
      registry.register(_proofAt(i), _publicInputsAt(i));
    }
    assertEq(registry.registeredCount(), n, 'a genuine registration was lost');

    bytes32[] memory commitments = new bytes32[](n);
    bytes32[] memory siblings;
    bytes32 root;

    for (uint256 i = 0; i < n; i++) {
      commitments[i] = _publicInputsAt(i)[PUB_COMMITMENT];
      SparseMerkleTree.Proof memory p = registry.getProof(commitments[i]);

      assertTrue(p.existence, 'a registered identity is not in the tree');
      assertEq(p.value, bytes32(0), 'a freshly registered identity is not CLEAN');
      assertGt(p.siblings.length, 0, 'DEGENERATE witness - no sibling would ever be hashed');

      if (i == 0) {
        root = p.root;
        siblings = new bytes32[](n * p.siblings.length);
      } else {
        // The whole point of emitting them together. Three witnesses against three different roots
        // would each verify alone and could never appear in one batch.
        assertEq(p.root, root, 'the three witnesses disagree on the registry root');
      }
      for (uint256 j = 0; j < p.siblings.length; j++) {
        siblings[i * (siblings.length / n) + j] = p.siblings[j];
      }
    }

    string memory json = 'identityWitness';
    vm.serializeBytes32(json, 'root', root);
    vm.serializeBytes32(json, 'commitments', commitments);
    string memory out = vm.serializeBytes32(json, 'siblings', siblings);
    vm.writeJson(out, 'test/fixtures/identity_witness.json');
  }

  // ── the happy path ──────────────────────────────────────────────────────────────────────

  function test_RegisterWithRealProof() public {
    _bindDocuments();
    bytes32 before = registry.root();

    registry.register(_proof(), _publicInputs());

    bytes32[] memory p = _publicInputs();
    assertTrue(registry.registered(p[PUB_COMMITMENT]), 'commitment not marked registered');
    assertEq(registry.statusOf(p[PUB_COMMITMENT]), bytes32(0), 'a fresh registration must be CLEAN (value 0)');
    assertEq(registry.registeredCount(), 1);
    assertTrue(registry.root() != before, 'root did not change on registration');
    assertTrue(registry.isValidRoot(registry.root()), 'the new root is not valid');
  }

  // ── TRAP 5: an escrow proof does NOT prove the passport is real ──────────────────────────

  function test_RegisterRevertsWhenNoDocumentWasEverBound() public {
    // No _bindDocuments(). The proof is perfectly valid and its inclusion argument is internally
    // sound - it simply cites a registration root that this state keeper has never held, because
    // nothing has been registered through the ICAO-verified path. Without this check the inclusion
    // proof asserts NOTHING: a prover would invent a tree containing whatever leaf they liked.
    bytes32[] memory p = _publicInputs();
    bytes memory pf = _proof();

    vm.expectRevert(
      abi.encodeWithSelector(IdentityRegistry.UnknownRegistrationRoot.selector, p[PUB_REGISTRATION_ROOT])
    );
    registry.register(pf, p);
  }

  /*
   * A CANCELLED PASSPORT CANNOT REGISTER AN IDENTITY (sec. 2.18b).
   *
   * Revoking a document overwrites its leaf VALUE, so roots created afterwards exclude it - but the
   * PRE-revocation root still proves it current, and `PoseidonSMT.isRootValid` kept accepting that
   * root for the rest of ROOT_VALIDITY. For up to an HOUR after a passport was cancelled, its
   * holder could still land a pool identity.
   *
   * The escrow proof here is completely genuine; only the root it cites is older than the
   * revocation. That is the whole attack, and it is what `RegistrationRootPredatesAnInvalidation`
   * now rejects.
   */
  function test_RegisterRevertsOnARootOlderThanTheLastRevocation() public {
    _bindDocuments();
    bytes32[] memory p = _publicInputs();
    bytes32 rootTheProofCites = p[PUB_REGISTRATION_ROOT];

    // The proof would be accepted right now - establish that, or the assertion below could pass
    // for some unrelated reason.
    assertTrue(
      _registrationSmt().isRootValid(rootTheProofCites), 'precondition: the cited root is valid'
    );

    // Cancel a DIFFERENT document, one second later. The cited root is now stale in the way that
    // matters: it predates an invalidation, while still being inside the one-hour window.
    vm.warp(block.timestamp + 1);
    sk.revokeDocument(_documentKeyAt(2), _holderRootAt(2));

    assertTrue(
      _registrationSmt().isRootValid(rootTheProofCites),
      'the old root is still inside ROOT_VALIDITY - which is exactly why the extra check is needed'
    );

    // The cited root was superseded BY the revocation, so it carries exactly
    // `lastDocumentInvalidationAt` - the boundary case, and the one a `<` comparison would let
    // through. Pinned here because that is the mistake I actually made.
    assertEq(
      _registrationSmt().getRootTimestamp(rootTheProofCites),
      sk.lastDocumentInvalidationAt(),
      'expected the cited root to sit exactly on the invalidation boundary'
    );

    bytes memory pf = _proof();
    vm.expectRevert(
      abi.encodeWithSelector(
        IdentityRegistry.RegistrationRootPredatesAnInvalidation.selector, rootTheProofCites
      )
    );
    registry.register(pf, p);
  }

  /// The root is real but not THIS registry's - the same failure an attacker's invented tree gives.
  function test_RegisterRevertsOnATamperedRegistrationRoot() public {
    _bindDocuments();
    bytes32[] memory p = _publicInputs();
    p[PUB_REGISTRATION_ROOT] = bytes32(uint256(p[PUB_REGISTRATION_ROOT]) ^ 1);
    bytes memory pf = _proof();

    // Reverts on the ROOT before the proof is verified. That ordering is what makes this test
    // possible at all: tampering with a public input also makes the generated verifier revert, so
    // checking the root second surfaces `SumcheckFailed()` and hides which input was wrong.
    vm.expectRevert(
      abi.encodeWithSelector(IdentityRegistry.UnknownRegistrationRoot.selector, p[PUB_REGISTRATION_ROOT])
    );
    registry.register(pf, p);
  }

  /*
   * TRAP 6: A REVOKED IDENTITY CANNOT COME BACK (sec. 2.18a).
   *
   * This is the test the old design could not have passed. While the escrowed secret was freely
   * chosen, anyone revoked could escrow a FRESH secret against the same passport, land a DIFFERENT
   * commitment, and register clean - the blacklist was evadable by exactly the people it was
   * applied to. `commitment` is now a function of `sk_identity`, fixed in-circuit, so the second
   * attempt collides with the first and `registered[commitment]` rejects it.
   */
  function test_ARevokedIdentityCannotRegisterAgain() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);
    assertEq(registry.statusOf(c), PREDICATE_SANCTIONS, 'revocation did not take');

    // The SAME passport, the SAME identity key: the circuit can only ever produce this commitment.
    bytes32[] memory p = _publicInputs();
    bytes memory pf = _proof();
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRegistered.selector, c));
    registry.register(pf, p);

    assertEq(registry.statusOf(c), PREDICATE_SANCTIONS, 'the revocation was cleared by a re-register');
  }

  // ── envelope must be readable by the controller ──────────────────────────────────────────

  function test_RegisterRevertsOnAForeignControllerKey() public {
    _bindDocuments();
    bytes32[] memory p = _publicInputs();
    p[PUB_CONTROLLER_X] = bytes32(uint256(p[PUB_CONTROLLER_X]) + 1); // sealed to a key the controller does not hold
    bytes memory pf = _proof();

    vm.expectRevert(IdentityRegistry.WrongControllerKey.selector);
    registry.register(pf, p);
  }

  function test_RegisterRevertsOnWrongInputCount() public {
    bytes32[] memory short_ = new bytes32[](PUBLIC_INPUT_COUNT - 1);
    bytes memory pf = _proof();

    vm.expectRevert(
      abi.encodeWithSelector(IdentityRegistry.WrongPublicInputCount.selector, PUBLIC_INPUT_COUNT - 1)
    );
    registry.register(pf, short_);
  }

  function test_RegisterRevertsOnDuplicate() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());

    bytes32[] memory p = _publicInputs();
    bytes memory pf = _proof();
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRegistered.selector, p[PUB_COMMITMENT]));
    registry.register(pf, p);
  }

  // ── TRAP 4: only the controller revokes ─────────────────────────────────────────────────

  function test_RevokeRevertsForNonController() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotTheController.selector, address(this)));
    registry.revoke(c, PREDICATE_SANCTIONS);
  }

  // ── TRAP 2: zero is the CLEAN sentinel ──────────────────────────────────────────────────

  function test_RevokeRejectsAZeroPredicate() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    // A zero predicate would write the CLEAN value and "revoke" the identity into good standing.
    vm.prank(CONTROLLER);
    vm.expectRevert(IdentityRegistry.ZeroPredicate.selector);
    registry.revoke(c, bytes32(0));
  }

  function test_ConstructorRejectsAZeroPredicate() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = bytes32(0);

    // vm.expectRevert does NOT reliably match a revert raised inside CREATE, so this asserts the
    // deployment failed via try/catch instead. Using expectRevert here reports "did not revert"
    // even when the guard is working - a false failure that hides a working guard.
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a zero predicate was accepted at deploy - revocation could write the CLEAN state');
    } catch {}
  }

  function test_RevokeRejectsAnUnknownPredicate() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnknownPredicate.selector, keccak256('MADE_UP')));
    registry.revoke(c, keccak256('MADE_UP'));
  }

  function test_RevokeRevertsForAnUnregisteredCommitment() public {
    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, bytes32(uint256(0xAB))));
    registry.revoke(bytes32(uint256(0xAB)), PREDICATE_SANCTIONS);
  }

  function test_RevokeIsMonotone() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);
    assertEq(registry.statusOf(c), PREDICATE_SANCTIONS, 'predicate not recorded as the leaf status');

    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRevoked.selector, c));
    registry.revoke(c, PREDICATE_DOC_INVALID);
  }

  // ── TRAP 1: root expiry, the asymmetry I already got wrong once ─────────────────────────

  function test_LatestRootIsAlwaysValidHoweverOld() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 latest = registry.root();

    // Inaction must stay harmless: a controller that never acts again blocks nobody.
    vm.warp(block.timestamp + 365 days);
    assertTrue(registry.isValidRoot(latest), 'the latest root expired - inaction became censorship');
  }

  function test_ASupersededCleanRootExpires() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 cleanRoot = registry.root();
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);

    // THE WHOLE POINT. The pre-revocation root still proves `commitment -> 0`. It stays valid only
    // long enough not to invalidate in-flight proofs; if it NEVER expired, a revoked identity could
    // withdraw forever by proving against it. That is precisely the bug shipped once on
    // RevocationRegistry by reasoning from the ASP's inclusion semantics.
    assertTrue(registry.isValidRoot(cleanRoot), 'a just-superseded root should still be usable');

    vm.warp(block.timestamp + MAX_ROOT_AGE + 1);
    assertFalse(registry.isValidRoot(cleanRoot), 'the pre-revocation root NEVER EXPIRED - revocation is escapable');
    assertTrue(registry.isValidRoot(registry.root()), 'the post-revocation root should be valid');
  }

  function test_UnknownRootIsRejected() public view {
    assertFalse(registry.isValidRoot(bytes32(uint256(0xDEAD))), 'an invented root was accepted');
    assertFalse(registry.isValidRoot(bytes32(0)), 'the zero root was accepted');
  }

  // ── coverage PORTED from RevocationRegistry.t.sol, which this registry supersedes ───────────
  //
  // Mapped case by case rather than assumed. Most of that suite already has an equivalent above
  // (CannotRevokeTwice -> RevokeIsMonotone, StrangerCannotRevoke -> RevokeRevertsForNonController,
  // StaleRootStopsBeingValid -> ASupersededCleanRootExpires, RootThatNeverExisted ->
  // UnknownRootIsRejected, UnknownPredicateIsUncitable -> RevokeRejectsAnUnknownPredicate). These
  // are the ones that did NOT, and deleting that file without them would have silently narrowed
  // coverage - the exact failure mode this project keeps finding.
  //
  // One case is deliberately NOT ported. `test_AttesterCannotCiteAnotherPredicate` covered
  // per-predicate attesters, which are gone BY DESIGN: one controller writes this list and the
  // label list alike. That is a removed behaviour, not lost coverage.

  /// A duplicate passes silently otherwise - `isPredicate` is idempotent - while pushing the same
  /// value twice into `_predicates`, so the published set misreports itself. Deploy-time only and
  /// immutable, so there is no correcting it afterwards. This guard did NOT exist until the port
  /// found RevocationRegistry had it and IdentityRegistry did not.
  function test_ConstructorRejectsDuplicatePredicates() public {
    bytes32[] memory preds = new bytes32[](2);
    preds[0] = PREDICATE_SANCTIONS;
    preds[1] = PREDICATE_SANCTIONS;

    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a duplicate predicate was accepted - the published set would misreport itself forever');
    } catch {}
  }

  function test_ConstructorRejectsAnEmptyPredicateSet() public {
    bytes32[] memory preds = new bytes32[](0);
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a registry with NO predicates was accepted - no revocation could ever cite a reason');
    } catch {}
  }

  function test_ConstructorRejectsZeroAddresses() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = PREDICATE_SANCTIONS;
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());

    try new IdentityRegistry(
      address(0), address(sk), CONTROLLER, address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero verifier was accepted'); } catch {}

    try new IdentityRegistry(
      verifier_, address(0), CONTROLLER, address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero state keeper was accepted'); } catch {}

    try new IdentityRegistry(
      verifier_, address(sk), address(0), address(evidence), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero controller was accepted - nobody could ever revoke'); } catch {}
  }

  /// The predicate must land in the TREE as the leaf value, not merely in a mapping. That is what
  /// makes a revocation auditable from committed state rather than from the event log, and what a
  /// future proof-of-correct-listing would prove against.
  function test_TheLeafValueRecordsThePredicate() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);

    SparseMerkleTree.Proof memory p = registry.getProof(c);
    assertTrue(p.existence, 'the revoked identity left the tree');
    assertEq(p.value, PREDICATE_SANCTIONS, 'the leaf value is not the cited predicate');
  }

  function test_RevokingMovesTheRoot() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 before = registry.root();

    vm.prank(CONTROLLER);
    registry.revoke(_publicInputs()[PUB_COMMITMENT], PREDICATE_SANCTIONS);

    assertTrue(registry.root() != before, 'revoking did not move the root, so it would not take effect');
    assertEq(registry.revokedCount(), 1);
  }

  /// No owner, no upgrade path, no role administration. The value of this registry is that NOBODY
  /// can rewrite it, including us - an upgradeable identity gate is a mutable one with extra steps.
  function test_ThereIsNoGovernanceSurface() public view {
    string[4] memory forbidden =
      ['owner()', 'upgradeToAndCall(address,bytes)', 'grantRole(bytes32,address)', 'transferOwnership(address)'];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok,) = address(registry).staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
      assertFalse(ok, string.concat('the registry answers a governance selector: ', forbidden[i]));
    }
  }

  // ── ERC-7812 anchoring: RESTORED after the merge dropped it ─────────────────────────────
  //
  // IdentityAspRegistry anchored every root as an evidence statement. The merge lost that by
  // OMISSION - not by decision - and it was found only by mapping the deleted suite's coverage test
  // by test after the file was already gone. These are the tests that would have caught it.
  //
  // Anchoring is what makes a root externally attestable rather than merely stored: another
  // contract, or another chain, can verify a root existed without trusting this contract's getters.

  function _statementFor(uint256 sequence_) internal view returns (bytes32) {
    bytes32 key = bytes32(
      uint256(keccak256(abi.encodePacked('PP_IDENTITY_ROOT', address(registry), sequence_)))
        % 21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617
    );
    return evidence.statements(keccak256(abi.encodePacked(address(registry), key)));
  }

  function test_RegistrationAnchorsItsRoot() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());

    assertEq(_statementFor(0), registry.root(), 'the registration root was not anchored as evidence');
    assertEq(registry.rootSequence(), 1);
  }

  /// A REVOCATION moves the root without adding a leaf, so it must be anchored too. Keying the
  /// statement on tree SIZE - the obvious choice, and what the old registry used - would collide
  /// here, because size does not change on a revocation.
  function test_RevocationAlsoAnchorsItsRoot() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 afterRegister = registry.root();

    vm.prank(CONTROLLER);
    registry.revoke(_publicInputs()[PUB_COMMITMENT], PREDICATE_SANCTIONS);

    assertEq(_statementFor(1), registry.root(), 'the revocation root was not anchored');
    assertTrue(registry.root() != afterRegister, 'revocation did not move the root');
    assertEq(registry.rootSequence(), 2);
  }

  /// Distinct keys per root. TestEvidenceRegistry reverts on a duplicate key, so a colliding
  /// derivation would make the SECOND anchor revert and take the whole transaction with it.
  function test_EachRootGetsADistinctStatementKey() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());

    vm.prank(CONTROLLER);
    registry.revoke(_publicInputs()[PUB_COMMITMENT], PREDICATE_SANCTIONS);

    assertTrue(_statementFor(0) != _statementFor(1), 'two roots share one statement key');
    assertTrue(_statementFor(0) != bytes32(0) && _statementFor(1) != bytes32(0), 'a root went unanchored');
  }

  function test_ConstructorRejectsAZeroEvidenceRegistry() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = PREDICATE_SANCTIONS;
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());

    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, address(0), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero evidence registry was accepted - no root would ever be attestable'); } catch {}
  }

  // ── TRAP 3: removal must not exist ──────────────────────────────────────────────────────

  function test_ThereIsNoRemovalPath() public {
    _bindDocuments();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[PUB_COMMITMENT];

    // The solarity SMT provides `remove`, and exposing it would let a controller ERASE a
    // registration - censorship by deletion. Assert no such selector is callable: any of the
    // obvious spellings must hit the fallback and fail.
    string[3] memory sigs = ['remove(bytes32)', 'unregister(bytes32)', 'deregister(bytes32)'];
    for (uint256 i = 0; i < sigs.length; i++) {
      (bool ok,) = address(registry).call(abi.encodeWithSignature(sigs[i], c));
      assertFalse(ok, 'a removal path exists on the registry');
    }
    assertTrue(registry.registered(c), 'the registration is gone');
  }
}
