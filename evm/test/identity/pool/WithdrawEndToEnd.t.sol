// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BlacklistAnchorFixture} from './helpers/BlacklistAnchorFixture.sol';
import {BlacklistRootFixture} from './helpers/BlacklistRootFixture.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {Entrypoint} from '../../../src/identity/pool/Entrypoint.sol';
import {IdentityRegistry} from '../../../src/identity/registry/IdentityRegistry.sol';
import {EscrowEnvelopeHonkVerifier} from '../../../src/identity/generated/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {HolderStateKeeperMock} from '../../../src/identity/mock/holder/HolderStateKeeperMock.sol';
import {PoseidonSMTMock} from '../../../src/identity/mock/state/PoseidonSMTMock.sol';
import {PrivacyPoolSimple} from '../../../src/identity/pool/implementations/PrivacyPoolSimple.sol';
import {WithdrawalHonkVerifier} from '../../../src/identity/generated/pool/verifiers/WithdrawalHonkVerifier.sol';
import {RagequitHonkVerifier} from '../../../src/identity/generated/pool/verifiers/RagequitHonkVerifier.sol';
import {IPrivacyPool} from '../../../src/identity/pool/interfaces/IPrivacyPool.sol';
import {ProofLib} from '../../../src/identity/pool/lib/ProofLib.sol';
import {Constants} from '../../../src/identity/pool/lib/Constants.sol';
import {EscrowFixtureBase} from '../registry/EscrowFixtureBase.sol';

/// OZ 5.6.1 rejects an ERC1967Proxy constructed with EMPTY init data (front-run protection for real
/// deployments). The state-keeper and SMT mocks below are deploy-then-initialize, matching their own
/// external `__xxx_init` pattern, so they need a proxy that opts back into that - safe in a
/// single-threaded test. Same helper as HolderRegistration.t.sol and IdentityRegistry.t.sol.
contract UnsafeTestProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

/// Minimal ERC-7812 registry — same pattern as EntrypointAsp.t.sol (the real one has a
/// Poseidon-under-Forge linking issue); nothing here depends on its behaviour beyond storing.
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
  }

  function removeStatement(bytes32 key) external {
    delete statements[key];
  }

  function updateStatement(bytes32 key, bytes32 newValue) external {
    statements[key] = newValue;
  }

  function getRootTimestamp(bytes32) external view returns (uint256) {
    return block.timestamp;
  }

  function getIsolatedKey(address source, bytes32 key) external pure returns (bytes32) {
    return keccak256(abi.encodePacked(source, key));
  }
}

/*
 * THE INTEGRATION GAP THIS CLOSES.
 *
 * Before this file, the two halves of the withdrawal path had NEVER MET:
 *   - WithdrawalHonkVerifier.t.sol feeds a REAL proof to `verifier.verify()` directly, with no pool.
 *   - PrivacyPoolSimple.t.sol exercises the real `withdraw()` path against a NoirVerifierMock and a
 *     MockEntrypoint, i.e. a fake proof.
 * So everything PrivacyPool itself enforces was untested against a genuine proof: the `context`
 * recomputation in validWithdrawal, `_isKnownRoot` over the 64-deep root history,
 * `ENTRYPOINT.isKnownAspRoot`, nullifier spending, the change-note insert, and the payout.
 *
 * It is also the ONLY test that validates the WALLET'S TREE MIRRORS against the chain. The proof
 * below commits to a `state_root` and an `asp_root` that the wallet's src/pp/stateTree.ts and
 * src/postman/identityAsp.ts computed OFF-CHAIN, and the pool independently rejects anything whose
 * roots it does not itself hold. A LeanIMT ordering bug, an off-by-one leaf index, or a
 * LeafInserted misread would fail here and nowhere else.
 *
 * FIXTURE PROVENANCE: tools/build-e2e-fixture.js — it reads the values logged by
 * test_LogFixtureInputs below, derives the note with the wallet's own code, builds both trees,
 * assembles the witness, and proves with bb 1.2.0. Regenerate with that script if the pool's SCOPE
 * changes (it is derived from the deployed address, so ANY change to deployment order in setUp
 * invalidates the fixture — test_ScopeMatchesFixture pins that).
 */
contract WithdrawEndToEndTest is EscrowFixtureBase, BlacklistAnchorFixture {
  Entrypoint internal entrypoint;
  IdentityRegistry internal identityRegistry;
  HolderStateKeeperMock internal stateKeeper;
  PrivacyPoolSimple internal pool;
  WithdrawalHonkVerifier internal withdrawalVerifier;
  MockEvidenceRegistry internal registry;

  address internal owner = address(0xA011);
  address internal postman = address(0xB022);
  address internal depositor = address(0xD0D0);
  address internal recipient = address(0xF00D);

  uint256 internal constant FIELD = Constants.SNARK_SCALAR_FIELD;
  uint256 internal constant DEPOSIT_VALUE = 1 ether;
  /// What the e2e fixture withdraws. A literal because the generator is told it BEFORE any proof
  /// exists; `WITHDRAWN` is the same number read back OUT of the emitted signals, and
  /// `test_WalletMirrorsMatchTheChain` is where the two are required to agree.
  uint256 internal constant E2E_WITHDRAWN_PLAN = 0.3 ether;

  /// holderRoot for sk_identity = 1234 (pp/src/identity_asp.nr's published vector), as the wallet's
  /// RarimeUtils.getProfileKey derives it: Poseidon(babyJub.mulPointEScalar(Base8, 1234)).
  uint256 internal constant HOLDER_ROOT =
    0x19bba1d1ede002b61a36d0665bbda703edcf937d846a50864eef80fa7887bded;

  /*
   * Wallet-derived precommitments for THIS pool's SCOPE, from the standard Foundry test mnemonic:
   * Poseidon(nullifier, secret) where the pair is depositSecrets(masterKeys, SCOPE, i). Four of
   * them, and three ASP members, ON PURPOSE - a single deposit gives a size-1 LeanIMT whose root
   * simply IS the leaf, so depth would be 0 and NO SIBLING WOULD EVER BE HASHED. That is the exact
   * degeneracy removed from the verifier fixtures; re-introducing it here would make this test
   * verify a Merkle path it never actually walks.
   */
  /**
   * The four deposits this suite makes, READ FROM THE FIXTURE the generator wrote them into.
   *
   * ⚠️ THEY ARE A FUNCTION OF `SCOPE`, WHICH IS A FUNCTION OF THE POOL'S ADDRESS - so ANY change to
   * the constructor moves them. Pinned here as literals they went stale silently, and the symptom
   * appeared three steps downstream in the generator as `state_root disagrees with the chain`, which
   * points at the tree rather than at the deposits that built it.
   *
   * Wallet-derived (seed + scope), so Solidity cannot compute them; reading them is the only option
   * that does not require someone to notice and re-paste.
   */
  uint256[4] internal PRECOMMITMENTS;

  /// True once the emitted precommitments were found - see the bootstrap note on `_loadE2ESignals`.
  bool internal precommitmentsLoaded;

  /**
   * ⚠️ TOLERATES ABSENCE FOR THE SAME REASON `_loadE2ESignals` does, and there is a second reason
   * here: the file is generated FOR a scope, and the scope is only knowable once the pool exists.
   * The first pass of a regeneration therefore deposits placeholders, learns SCOPE, and the second
   * pass deposits the real ones. Requiring the file would make that first pass impossible.
   *
   * ⛔ THE SCOPE IS CHECKED, not assumed. A file generated for a DIFFERENT pool is worse than a
   * missing one: it deposits successfully and produces leaves nothing can reconstruct.
   */
  function _loadPrecommitments(uint256 scope_) internal {
    if (!vm.isFile('test/fixtures/e2e_precommitments.json')) {
      // Placeholder deposits: enough to build a tree, not expected to reconstruct. REDUCED mod the
      // scalar field, because the pool rejects anything at or above it and a raw keccak clears that
      // bound about half the time - an unreduced placeholder fails as `InvalidPrecommitmentHash`,
      // which reads as a broken deposit rather than as the bootstrap value it is.
      for (uint256 i = 0; i < 4; i++) PRECOMMITMENTS[i] = uint256(keccak256(abi.encode('bootstrap', i))) % FIELD;
      return;
    }
    string memory raw_ = vm.readFile('test/fixtures/e2e_precommitments.json');
    if (uint256(vm.parseJsonBytes32(raw_, '.scope')) != scope_) {
      for (uint256 i = 0; i < 4; i++) PRECOMMITMENTS[i] = uint256(keccak256(abi.encode('bootstrap', i))) % FIELD;
      return; // generated for another pool; regenerate rather than silently mismatching
    }
    bytes32[] memory pre_ = vm.parseJsonBytes32Array(raw_, '.precommitments');
    require(pre_.length == 4, 'e2e_precommitments.json must carry four values');
    for (uint256 i = 0; i < 4; i++) PRECOMMITMENTS[i] = uint256(pre_[i]);
    precommitmentsLoaded = true;
  }

  /// Ours is index 1 - deliberately not first or last, so its inclusion path has siblings on both
  /// sides rather than riding the LeanIMT's carry-up-on-empty edge case.
  uint256 internal constant OUR_NOTE_INDEX = 1;


  uint256 internal ourCommitment;
  uint256 internal ourLabel;
  uint256 internal identityRoot;

  /// The controller's Baby Jubjub sealing key, pinned in pp/src/envelope.nr's tests and used by the
  /// committed escrow fixtures. MUST match, or `register` rejects every envelope as sealed to a key
  /// the controller does not hold.
  uint256 internal constant CONTROLLER_KEY_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  uint256 internal constant CONTROLLER_KEY_Y =
    6_509_666_988_291_764_283_313_685_078_036_329_297_907_336_602_650_572_952_945_826_675_203_643_401_307;
  uint32 internal constant IDENTITY_TREE_DEPTH = 32;

  function _escrowProof(uint256 _i) internal view returns (bytes memory) {
    return vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_i), '.proof'));
  }

  /// escrow_envelope's public-input layout. `holder_root` (2) and `dg1_hash` (4) are GONE since
  /// sec. 2.18 - both were per-person identifiers published in registration calldata.
  /// Six fixed signals plus a ONE-field escrow envelope: `revocation_secret` and `document_id`.
  ///
  /// 🔴 IT WAS 11. The envelope carried the packed MRZ - name, date of birth, nationality - sealed to
  /// one controller key and emitted as an event, so it was permanently indexable. Shrinking the
  /// payload to what revocation actually needs moved this count with it.
  uint256 internal constant ESCROW_PUBLIC_INPUT_COUNT = 7;
  uint256 internal constant ESCROW_PUB_COMMITMENT = 2;

  function _escrowPublicInputs(uint256 _n) internal view returns (bytes32[] memory _inputs) {
    bytes memory _raw =
      vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_n), '.public'));
    _inputs = new bytes32[](ESCROW_PUBLIC_INPUT_COUNT);
    for (uint256 _i = 0; _i < ESCROW_PUBLIC_INPUT_COUNT; _i++) {
      bytes32 _w;
      assembly {
        _w := mload(add(_raw, add(32, mul(_i, 32))))
      }
      _inputs[_i] = _w;
    }
  }

  /* ────────────────────────────────────────────────────────────────────────────────────────────
   * THE PROVED WITHDRAWAL'S PUBLIC SIGNALS (test/fixtures/withdraw_e2e.proof).
   *
   * READ FROM THE FIXTURE the generator wrote them into, not pinned. The old comment here claimed
   * pinning made a change "show up as a STALE FIXTURE rather than as an unexplained proof
   * rejection" - and the opposite happened. When the identity leaves began binding their document,
   * every leaf key moved and these constants became the unexplained rejection: `InvalidIdentityRoot`
   * on three tests, `SumcheckFailed` elsewhere, and a revocation test failing with "grace window
   * closed immediately" because it asked the registry about a root that no longer existed.
   *
   * A pinned number only announces staleness if something compares it to the source. Nothing did.
   * `test_WalletMirrorsMatchTheChain` still performs exactly that comparison, and now it is the
   * ONLY place the pairing is asserted rather than assumed.
   * ──────────────────────────────────────────────────────────────────────────────────────────── */
  uint256 internal WALLET_STATE_ROOT;
  uint256 internal E2E_IDENTITY_ROOT;
  uint256 internal WITHDRAWN;
  uint256 internal E2E_NEW_COMMITMENT;
  uint256 internal E2E_NULLIFIER_HASH;
  uint256 internal E2E_CONTEXT;
  uint256 internal E2E_BLACKLIST_ROOT;

  /// True once the emitted signals were found. See the bootstrap note below.
  bool internal e2eSignalsLoaded;

  /**
   * ⚠️ TOLERATES ITS OWN ABSENCE, AND THAT IS NOT DEFENSIVENESS - IT BREAKS A CYCLE.
   *
   * `test_EmitE2EFixtureParams` exists so the e2e fixture can be rebuilt, and the rebuild writes
   * this file. But that test runs AFTER `setUp`, so on a clean regeneration `setUp` would be
   * reading a file that the run it is part of has not written yet, and the emitter could never
   * execute. Requiring the file here would make the fixture permanently unrebuildable - the exact
   * property this whole exercise was undertaken to fix.
   *
   * A missing file is therefore a legitimate state, and only the tests that CONSUME the signals may
   * insist on it. They do, in `_e2eProof`, with a message naming the generator - rather than failing
   * as `InvalidProof` against eight zeros, which names nothing.
   */
  function _loadE2ESignals() internal {
    if (!vm.isFile('test/fixtures/withdraw_e2e_pubsignals.json')) return;
    bytes32[] memory sig_ = vm.parseJsonBytes32Array(
      vm.readFile('test/fixtures/withdraw_e2e_pubsignals.json'), '$'
    );
    require(sig_.length == 8, 'e2e fixture does not carry eight public signals');
    E2E_NEW_COMMITMENT = uint256(sig_[0]);
    E2E_NULLIFIER_HASH = uint256(sig_[1]);
    WITHDRAWN = uint256(sig_[2]);
    WALLET_STATE_ROOT = uint256(sig_[3]);
    E2E_IDENTITY_ROOT = uint256(sig_[5]);
    E2E_CONTEXT = uint256(sig_[6]);
    E2E_BLACKLIST_ROOT = uint256(sig_[7]);
    e2eSignalsLoaded = true;
  }

  function setUp() public {
    _loadE2ESignals();

    // ⚠️ THE ROOT IS PUBLISHED THROUGH A REAL ANCHOR, BECAUSE THE POOL NO LONGER ACCEPTS ONE.
    // It pulls from `RegistrySourceAnchor` precisely so nobody can choose the value - a test
    // included. This suite verifies REAL proofs, so the published root must be the one the fixture's
    // exclusion witnesses were built against: `withdraw` substitutes it into the verifier's public
    // inputs, and any other value - including a perfectly valid root from a different snapshot -
    // yields `InvalidProof`, which reads as a broken circuit rather than a mismatched number.
    //
    // During a regeneration the emitted signals do not exist yet, so fall back to the shared tree's
    // root. That fallback is a REAL root from the same tree, never a placeholder.
    _deployBlacklistAnchor(e2eSignalsLoaded ? E2E_BLACKLIST_ROOT : BlacklistRootFixture.read(vm));

    // ⚠️ DEPLOYED FIRST, AND THE ORDER IS LOAD-BEARING. Publishing a snapshot warps time twice to
    // clear the workflow and root activation delays, and `EscrowFixtureBase` requires
    // `block.timestamp == FIXTURE_TIMESTAMP` exactly when it binds documents - its leaf values
    // include the timestamp. Doing this afterwards moves the clock out from under that binding and
    // fails with a message about leaf values, which points nowhere near the cause. Running first is
    // safe because the later warp to FIXTURE_TIMESTAMP is far FORWARD of these, so the snapshot
    // stays active.

    registry = new MockEvidenceRegistry();

    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, address(registry)));
    entrypoint = Entrypoint(payable(address(new ERC1967Proxy(address(impl), init))));

    // ONE identity tree now (sec. 2.13k): registration AND revocation status live together, with
    // status carried in the leaf value. NON-UPGRADEABLE, and the pool holds a direct reference, so
    // nothing upgradeable sits between it and a set that can block a withdrawal (sec. 2.5a).
    //
    // The registry needs a state keeper because `register` REFUSES an escrow citing a registration
    // root it has never held - the escrow proof includes the document's own leaf from that tree, and
    // without checking the root that inclusion argument asserts nothing (sec. 2.13n trap 5, 2.18).
    PoseidonSMTMock smt = PoseidonSMTMock(address(new UnsafeTestProxy(address(new PoseidonSMTMock()))));
    PoseidonSMTMock certs = PoseidonSMTMock(address(new UnsafeTestProxy(address(new PoseidonSMTMock()))));
    stateKeeper = HolderStateKeeperMock(address(new UnsafeTestProxy(address(new HolderStateKeeperMock()))));
    smt.__PoseidonSMT_init(address(stateKeeper), address(registry), REGISTRATION_TREE_DEPTH);
    certs.__PoseidonSMT_init(address(stateKeeper), address(registry), REGISTRATION_TREE_DEPTH);
    stateKeeper.__StateKeeper_init(owner, address(smt), address(certs), bytes32(uint256(1)));

    // The escrow proofs were built against a tree bound at this exact time - the timestamp is part
    // of every leaf value. `_bindDocumentsInto` refuses to run at any other, rather than letting the
    // root silently differ.
    vm.warp(FIXTURE_TIMESTAMP);

    string[] memory skKeys = new string[](1);
    skKeys[0] = 'e2e';
    address[] memory skVals = new address[](1);
    skVals[0] = address(this);
    stateKeeper.mockAddRegistrations(skKeys, skVals);

    bytes32[] memory preds = new bytes32[](1);
    preds[0] = keccak256('predicate.document.not-current');
    identityRegistry = new IdentityRegistry(
      address(new EscrowEnvelopeHonkVerifier()), address(stateKeeper), postman, address(registry),
      CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, 1 hours, preds
    );

    withdrawalVerifier = new WithdrawalHonkVerifier();

    pool = new PrivacyPoolSimple(
      address(entrypoint), address(withdrawalVerifier), address(new RagequitHonkVerifier()),
      address(identityRegistry),
      address(0), // no aggregation verifier: this suite does not exercise withdrawBatch
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );

    // Four real deposits through the real pool, so the state tree has genuine depth.
    _loadPrecommitments(pool.SCOPE());
    _loadRagequitSignals(pool.SCOPE());
    for (uint256 i = 0; i < PRECOMMITMENTS.length; i++) {
      uint256 label = uint256(keccak256(abi.encodePacked(pool.SCOPE(), pool.nonce() + 1))) % FIELD;
      vm.deal(address(entrypoint), DEPOSIT_VALUE);
      vm.prank(address(entrypoint));
      uint256 c = pool.deposit{value: DEPOSIT_VALUE}(depositor, DEPOSIT_VALUE, PRECOMMITMENTS[i]);
      if (i == OUR_NOTE_INDEX) {
        ourCommitment = c;
        ourLabel = label;
      }
    }

    // Three GENUINE registrations, each with its own real escrow proof. Three rather than one
    // because a single-leaf SMT has an EMPTY inclusion path, so the withdrawal would hash no
    // siblings and prove nothing about the Merkle path.
    //
    // THE DOCUMENTS COME FROM THE SHARED FIXTURE, not from the proofs' own public inputs - those no
    // longer carry `dg1Hash` or `holderRoot` to read back. Each proof includes its document's leaf,
    // so the tree here must be byte-identical to the one the witness was emitted from.
    _bindDocumentsInto(stateKeeper);
    for (uint256 i = 0; i < 3; i++) {
      identityRoot = uint256(identityRegistry.register(_escrowProof(i), _escrowPublicInputs(i)));
    }
  }

  /*
   * PASS 1 of fixture generation. The proof must commit to values that do not exist until the
   * contracts are deployed and deposited into - SCOPE is derived from the pool's address, and
   * `label` from SCOPE - so they cannot be chosen in advance. Run this, feed the output to
   * tools/build-e2e-fixture.js, then fill in the constants above.
   *
   *   forge test --match-test test_LogFixtureInputs -vv
   */
  function test_LogFixtureInputs() public {
    emit log_named_uint('SCOPE', pool.SCOPE());
    emit log_named_uint('our label', ourLabel);
    emit log_named_uint('our commitment', ourCommitment);
    emit log_named_uint('our leaf index', OUR_NOTE_INDEX);
    emit log_named_uint('state root', pool.currentRoot());
    emit log_named_uint('state depth', pool.currentTreeDepth());
    emit log_named_uint('state size', pool.currentTreeSize());
    emit log_named_uint('identity root', identityRoot);
    emit log_named_uint('deposit value', DEPOSIT_VALUE);

    // The context the proof must carry for a SELF-withdrawal to `recipient`. Transcribed from
    // PrivacyPool.validWithdrawal, which recomputes and compares this independently.
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});
    emit log_named_uint('context', uint256(keccak256(abi.encode(w, pool.SCOPE()))) % FIELD);

    /*
     * FIXTURE-DRIFT GUARD. This function used to only LOG, which made it one of two tests in the
     * suite that could not fail - it looked like coverage and was not.
     *
     * It matters here more than most: SCOPE is derived from the pool's ADDRESS, so adding or
     * reordering a single deployment in setUp silently invalidates the committed proof. Without
     * this the symptom is a bare ContextMismatch from the withdrawal test, which says nothing about
     * the cause. These assertions name it.
     */
    assertEq(
      pool.currentRoot(), WALLET_STATE_ROOT, 'fixture is STALE: state root moved (SCOPE changed?)'
    );
    assertEq(
      uint256(keccak256(abi.encode(w, pool.SCOPE()))) % FIELD,
      E2E_CONTEXT,
      'fixture is STALE: context moved - regenerate with tools/build-e2e-fixture.js'
    );
    assertEq(identityRegistry.registeredCount(), 3, 'registration count changed - fixture invalid');
    assertEq(pool.currentTreeSize(), 4, 'deposit count changed - fixture invalid');
  }

  /*
   * THE MIRROR CROSS-CHECK, and the reason this file earns its place.
   *
   * These two roots were computed OFF-CHAIN by the wallet's src/pp/stateTree.ts and
   * src/postman/identityAsp.ts from the same leaves, in the same order. The chain computed its own
   * with lean-imt/InternalLeanIMT.sol + PoseidonT3. If the wallet's LeanIMT disagreed with the
   * contract's in ANY respect - node ordering, the carry-up-on-empty rule, Poseidon parameters,
   * insertion order - these would differ, and every proof the wallet ever produced would be
   * rejected on-chain with no indication that the mirror was the cause.
   *
   * Nothing else in the suite tests this. The verifier tests use trees the wallet built alone.
   */
  function test_WalletMirrorsMatchTheChain() public view {
    assertEq(pool.currentRoot(), WALLET_STATE_ROOT, 'wallet stateTree.ts disagrees with the pool');
    assertEq(pool.currentTreeDepth(), 2, 'state tree is not multi-level - fixture would be degenerate');

    // The identity tree is NOT mirrored off-chain any more - the wallet asks the registry via
    // getProof (sec. 2.13o), so there is no second implementation to disagree with. What still
    // needs pinning is that the fixture was proved against THIS registry's root.
    assertEq(uint256(identityRegistry.root()), E2E_IDENTITY_ROOT, 'fixture proved against a different identity root');
    assertGt(identityRegistry.getProof(_escrowPublicInputs(0)[ESCROW_PUB_COMMITMENT]).siblings.length, 0, 'identity witness is degenerate');
  }

  /**
   * Emit the parameters `tools/build-e2e-fixture.js` needs, so `withdraw_e2e.proof` can be rebuilt.
   *
   * ⚠️ THIS EXISTS BECAUSE THE FIXTURE WAS NOT REPRODUCIBLE, WHICH IS THE COMPLAINT ITS OWN
   * GENERATOR'S HEADER ALREADY MAKES ABOUT THE FIXTURE IT REPLACED. The generator takes --scope,
   * --label, --leaf-index and --state-root with no defaults, and nothing recorded the values used.
   * So the file could only be regenerated by someone who still had the deployment that produced it,
   * and when the circuit changed under it there was no way back. The second time is the tell.
   *
   * Every value here is READ FROM THE LIVE FIXTURE, not restated: the pool is deployed
   * deterministically in setUp, so its scope, our label and the post-deposit root are all functions
   * of this file. Pinning them as constants is what created the problem in the first place.
   *
   * Not an assertion - it is a generator that happens to run as a test, the same shape as
   * `test_EmitIdentityWitnessFixture`.
   */
  function test_EmitE2EFixtureParams() public {
    string memory json = 'e2eParams';
    vm.serializeUint(json, 'scope', pool.SCOPE());
    vm.serializeUint(json, 'label', ourLabel);
    vm.serializeUint(json, 'leafIndex', OUR_NOTE_INDEX);
    vm.serializeUint(json, 'stateRoot', pool.currentRoot());
    vm.serializeUint(json, 'stateTreeDepth', pool.currentTreeDepth());
    vm.serializeUint(json, 'identityRoot', uint256(identityRegistry.root()));

    // The three the generator needs that are PLANNED here rather than observed: what the note holds,
    // what this withdrawal takes, and the context binding it to its recipient. The context is
    // derived by the pool's own rule over the exact struct the withdrawal will be settled with -
    // computing it any other way is how a fixture ends up bound to a recipient nobody uses.
    vm.serializeUint(json, 'value', DEPOSIT_VALUE);
    vm.serializeUint(json, 'withdrawn', E2E_WITHDRAWN_PLAN);
    string memory out = vm.serializeUint(
      json, 'context',
      uint256(keccak256(abi.encode(IPrivacyPool.Withdrawal({processooor: recipient, data: ''}), pool.SCOPE()))) % FIELD
    );
    vm.writeJson(out, 'test/fixtures/e2e_params.json');
  }

  function _e2eProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    require(
      e2eSignalsLoaded,
      'no withdraw_e2e_pubsignals.json - regenerate with tools/build-e2e-fixture.js (see '
      'test_EmitE2EFixtureParams for its arguments)'
    );
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_e2e.proof');
    _p.pubSignals = [
      E2E_NEW_COMMITMENT,
      E2E_NULLIFIER_HASH,
      WITHDRAWN,
      WALLET_STATE_ROOT,
      uint256(2), // state_tree_depth
      E2E_IDENTITY_ROOT,
      E2E_CONTEXT,
      E2E_BLACKLIST_ROOT // [7] the populated blacklist this fixture proves exclusion against
    ];
  }

  /*
   * THE WHOLE POINT: a genuine proof, built by the wallet against THIS pool's real state, driven
   * through the real `withdraw()` - the real verifier, the real Entrypoint, the real root history,
   * the real nullifier set, and a real payout. Never done before this file.
   */
  function test_WithdrawWithRealProof() public {
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});

    uint256 balanceBefore = recipient.balance;
    uint256 sizeBefore = pool.currentTreeSize();

    vm.prank(recipient); // processooor must be the caller (PrivacyPool.sol:45)
    pool.withdraw(w, _e2eProof());

    assertEq(recipient.balance - balanceBefore, WITHDRAWN, 'recipient was not paid the withdrawn value');
    assertTrue(pool.nullifierHashes(E2E_NULLIFIER_HASH), 'nullifier was not marked spent');
    assertEq(pool.currentTreeSize(), sizeBefore + 1, 'change note was not inserted');
  }

  /// The nullifier set must actually prevent a replay - the property the whole spend model rests on.
  function test_ReplayIsRejected() public {
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});

    vm.prank(recipient);
    pool.withdraw(w, _e2eProof());

    vm.prank(recipient);
    vm.expectRevert();
    pool.withdraw(w, _e2eProof());
  }

  /*
   * `context` binds the proof to THESE withdrawal parameters. Submitting the same proof with a
   * different processooor must fail, or a relayer could redirect anyone's funds to itself - the
   * exact attack the context check exists to stop. Proving it with a REAL proof is what makes this
   * meaningful; against a mock verifier it would pass no matter what.
   */
  function test_ProofIsBoundToItsWithdrawalParameters() public {
    IPrivacyPool.Withdrawal memory tampered =
      IPrivacyPool.Withdrawal({processooor: address(0xBAD), data: ''});

    vm.prank(address(0xBAD));
    vm.expectRevert();
    pool.withdraw(tampered, _e2eProof());
  }

  /*
   * ═══ THE NEGATIVE INVARIANT (sec. 2.5) ═══
   *
   * "A revocation is valid only if it cites a provable predicate from a closed set, AND THAT IS THE
   * ONLY WAY TO BLOCK A WITHDRAWAL." The second clause is a claim about the WHOLE withdrawal path,
   * not a feature, so it is asserted here by enumerating every way withdraw() can revert and
   * showing each is either the caller's own doing or the rule-bound membership check.
   *
   * withdraw() reverts on exactly NINE conditions. The list was FIRST WRITTEN AS SEVEN, derived by
   * reading PrivacyPool.sol alone - which missed the two that come from INHERITED calls the
   * function makes (_spend/_insert live in State, _push in PrivacyPoolSimple). Enumerating a
   * "closed set" from one file is exactly the kind of blind spot this invariant exists to rule out,
   * so the provenance of each entry is given:
   *
   *   PrivacyPool.validWithdrawal / withdraw:
   *     InvalidProcessooor       caller is not the address the proof commits to    -> caller's own
   *     ContextMismatch          proof does not match these withdrawal parameters  -> caller's own
   *     InvalidTreeDepth         declared depth exceeds MAX_TREE_DEPTH             -> caller's own
   *     UnknownStateRoot         state root outside the 64-root history            -> caller's own
   *                              (staleness only - rebuild the witness and retry)
   *     InvalidProof             the proof does not verify                         -> caller's own
   *     IncorrectASPRoot         ASP root is not one the registry computed         -> RULE-BOUND
   *   State (inherited, via _spend/_insert):
   *     NullifierAlreadySpent    the note is already spent                         -> caller's own
   *     MaxTreeDepthReached      the state tree is FULL (2^32 leaves)              -> CAPACITY
   *   PrivacyPoolSimple (inherited, via _push):
   *     FailedToSendNativeAsset  the recipient contract rejected the ETH           -> caller's own
   *                              (the caller chose the recipient)
   *
   *     BlacklistRootUnset       no blacklist root has ever been published          -> RULE-BOUND
   *     BlacklistRootMismatch    batch signal disagrees with the pool's root        -> caller's own
   *
   * So TWO reverts are a third party's decision, and this count was wrong before the fail-closed
   * read existed - it went stale the day `setBlacklistRoot` landed and nobody updated it. Gating a
   * withdrawal on a mutable third-party root IS a lever, whichever way the zero case is decided:
   * fail-open let a stalled feed admit everyone, fail-closed lets an unset one halt everyone. The
   * lever is the gate, not the direction.
   *
   * WHAT BOUNDS IT TODAY, stated as exposure rather than as reassurance:
   *   - the root cannot be ZEROED once set, so the cost-free halt is unavailable and a stalled feed
   *     keeps the last good root instead of emptying it;
   *   - a hostile entrypoint CAN still publish a root nobody can prove against, which halts
   *     withdrawals. That is not closed. Closing it means sourcing the root from the CRE anchor -
   *     append-only, no owner, the same shape that bounds IncorrectASPRoot - rather than from an
   *     entrypoint setter. Booked.
   *
   * IncorrectASPRoot is bounded by a non-upgradeable, append-only registry with no owner.
   * MaxTreeDepthReached is not a lever either: it is a global capacity limit that no one can aim at
   * an individual, and it blocks deposits before withdrawals. Beyond the blacklist root, nothing in
   * the path consults a role, an owner, a pause flag or an upgrade.
   */
  function test_NoGovernanceLeverCanBlockAWithdrawal() public {
    // The ONLY governance action reachable on a live pool is windDown, via the Entrypoint.
    vm.prank(address(entrypoint));
    pool.windDown();
    assertTrue(pool.dead(), 'windDown did not take effect - the test proves nothing');

    // A dead pool must still pay out. Wind-down stops DEPOSITS; it must never trap funds already
    // inside, or "wind the pool down" would be a censorship lever over every existing depositor.
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});
    uint256 before = recipient.balance;

    vm.prank(recipient);
    pool.withdraw(w, _e2eProof());

    assertEq(recipient.balance - before, WITHDRAWN, 'a wound-down pool blocked a valid withdrawal');
  }

  /// @notice The ASP membership check is the ONLY third-party-controlled revert in the path, and it
  /// is served by a contract with no owner and no upgrade path. If a future change routes it back
  /// through anything upgradeable, this pins the address the pool actually trusts.
  function test_TheOnlyThirdPartyGateIsTheNonUpgradeableRegistry() public view {
    assertEq(address(pool.IDENTITY_REGISTRY()), address(identityRegistry), 'pool trusts an unexpected contract');

    string[4] memory forbidden =
      ['owner()', 'upgradeToAndCall(address,bytes)', 'grantRole(bytes32,address)', 'remove(uint256)'];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok,) =
        address(identityRegistry).staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
      assertFalse(ok, string.concat('the ASP gate answers a governance selector: ', forbidden[i]));
    }
  }

  /*
   * REVOCATION ACTUALLY BITES. The proof commits to E2E_IDENTITY_ROOT - the root after setUp's
   * three registrations - and PrivacyPool checks it with isValidRoot. Once ANY revocation lands
   * that root is superseded, and after MAX_ROOT_AGE it stops being accepted, so this exact proof
   * dies.
   *
   * ROOT EXPIRY IS WHY. On a pure INCLUSION tree an old root could be honoured forever, since an
   * append-only tree's historical membership is a strict subset of the current one. This tree also
   * carries REVOCATIONS, so an old root has FEWER of them - honouring one indefinitely would let a
   * revoked identity prove the clean status forever and revocation would be decorative. See
   * sec. 2.13m, trap 1.
   *
   * STRONGER THAN THE VERSION THIS REPLACES, which revoked a placeholder key against an EMPTY
   * registry. The identity revoked here is one of the three GENUINELY REGISTERED in setUp, so the
   * root moves because a real identity was excluded.
   */
  function test_RevocationEventuallyInvalidatesAnOldProof() public {
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});

    // A DIFFERENT registered identity is revoked - not ours - superseding the root our proof used.
    vm.prank(postman);
    identityRegistry.revoke(_escrowPublicInputs(1)[ESCROW_PUB_COMMITMENT], keccak256('predicate.document.not-current'));

    // Inside the grace window the in-flight proof still works - deliberate, so an unrelated
    // revocation cannot be used to kill everyone's pending withdrawals.
    assertTrue(identityRegistry.isValidRoot(bytes32(E2E_IDENTITY_ROOT)), 'grace window closed immediately');

    vm.warp(block.timestamp + 1 hours + 1);

    assertFalse(identityRegistry.isValidRoot(bytes32(E2E_IDENTITY_ROOT)), 'superseded root never expired');
    vm.prank(recipient);
    vm.expectRevert();
    pool.withdraw(w, _e2eProof());
  }

  /// @notice ...and the CURRENT root still works after that same delay, so expiry is not a
  /// liveness failure. Rebuild the witness against the new root and the withdrawal proceeds.
  function test_CurrentIdentityRootSurvivesTheSameDelay() public {
    vm.prank(postman);
    identityRegistry.revoke(_escrowPublicInputs(1)[ESCROW_PUB_COMMITMENT], keccak256('predicate.document.not-current'));
    bytes32 current = identityRegistry.root();

    vm.warp(block.timestamp + 3650 days);

    assertTrue(
      identityRegistry.isValidRoot(current),
      'the CURRENT root expired - inaction would block withdrawals'
    );
  }

  /*
   * ═══ RAGEQUIT, END TO END, WITH NO MOCK ANYWHERE IN THE PATH ═══
   *
   * sec. 2.5b restored the ragequit CIRCUIT, and RagequitHonkVerifier.t.sol proves the verifier
   * accepts a real proof — but that test has no pool in it. The pool's own ragequit path was still
   * only exercised against NoirVerifierMock, i.e. against a verifier that returns true.
   *
   * This closes that: a real proof, the real RagequitHonkVerifier, the real pool, and the real
   * depositor check. It matters because ragequit is the escape hatch — the exit for someone the ASP
   * declines to admit — and "the verifier accepts the proof" is not the same claim as "the pool
   * pays out".
   *
   * The note is deposit index 0, deliberately NOT the one the withdrawal spends (index 1), so the
   * two end-to-end paths cannot mask each other.
   */
  /**
   * The ragequit fixture's public signals, READ FROM THE FIXTURE like every other one here.
   *
   * ⚠️ ALL THREE ARE FUNCTIONS OF `SCOPE`. Pinned as literals they went stale when the constructor
   * changed, and surfaced as `OnlyOriginalDepositor` - which points at AUTHORISATION rather than at
   * a stale number, because a label from the old scope names a deposit this depositor never made.
   */
  uint256 internal RQ_COMMITMENT;
  uint256 internal RQ_NULLIFIER_HASH;
  uint256 internal RQ_VALUE;
  uint256 internal RQ_LABEL;
  bool internal ragequitSignalsLoaded;

  /// Tolerates absence for the bootstrap reason given on `_loadE2ESignals`, and checks the scope for
  /// the reason given on `_loadPrecommitments`: a fixture built for another pool is worse than none.
  function _loadRagequitSignals(uint256 scope_) internal {
    if (!vm.isFile('test/fixtures/ragequit_e2e_pubsignals.json')) return;
    string memory raw_ = vm.readFile('test/fixtures/ragequit_e2e_pubsignals.json');
    if (uint256(vm.parseJsonBytes32(raw_, '.scope')) != scope_) return;
    RQ_COMMITMENT = uint256(vm.parseJsonBytes32(raw_, '.commitment'));
    RQ_NULLIFIER_HASH = uint256(vm.parseJsonBytes32(raw_, '.nullifierHash'));
    RQ_VALUE = uint256(vm.parseJsonBytes32(raw_, '.value'));
    RQ_LABEL = uint256(vm.parseJsonBytes32(raw_, '.label'));
    ragequitSignalsLoaded = true;
  }

  function _ragequitProof() internal view returns (ProofLib.RagequitProof memory _p) {
    require(
      ragequitSignalsLoaded,
      'no ragequit_e2e_pubsignals.json for this SCOPE - regenerate with '
      'tools/regenerate-fixtures.sh e2e'
    );
    _p.proof = vm.readFileBinary('test/fixtures/ragequit_e2e.proof');
    _p.pubSignals = [RQ_COMMITMENT, RQ_NULLIFIER_HASH, RQ_VALUE, RQ_LABEL];
  }

  function test_RagequitWithRealProofThroughTheRealPool() public {
    uint256 before = depositor.balance;

    // The pool pays the ORIGINAL DEPOSITOR, which is what makes ragequit an unlinkability
    // sacrifice rather than a theft primitive.
    vm.prank(depositor);
    pool.ragequit(_ragequitProof());

    assertEq(depositor.balance - before, RQ_VALUE, 'ragequit did not pay the depositor');
    assertTrue(pool.nullifierHashes(RQ_NULLIFIER_HASH), 'ragequit did not spend the nullifier');
  }

  /// @notice Only the original depositor may reclaim. Without this the escape hatch would be a
  /// way to steal any note whose secrets leaked.
  function test_RagequitRejectsAnyoneButTheDepositor() public {
    vm.prank(recipient);
    vm.expectRevert();
    pool.ragequit(_ragequitProof());
  }

  /// @notice The escape hatch must survive wind-down for the same reason withdrawal does - a
  /// retired pool that traps unadmitted depositors is exactly the censorship lever sec. 2.13 rules
  /// out, and they have no other exit.
  function test_RagequitSurvivesWindDown() public {
    vm.prank(address(entrypoint));
    pool.windDown();

    uint256 before = depositor.balance;
    vm.prank(depositor);
    pool.ragequit(_ragequitProof());
    assertEq(depositor.balance - before, RQ_VALUE, 'a wound-down pool blocked the escape hatch');
  }

  function test_RagequitCannotBeReplayed() public {
    vm.prank(depositor);
    pool.ragequit(_ragequitProof());

    vm.prank(depositor);
    vm.expectRevert();
    pool.ragequit(_ragequitProof());
  }
}
