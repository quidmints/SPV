// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CreReportMetadata} from '../registry/CreReportMetadata.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {TitleLedger} from '../../../src/identity/title/TitleLedger.sol';
import {RegistrySourceAnchor} from '../../../src/identity/registry/RegistrySourceAnchor.sol';
import {HolderStateKeeperMock} from '../mocks/holder/HolderStateKeeperMock.sol';
import {PoseidonSMTMock} from '../mocks/state/PoseidonSMTMock.sol';
import {NoirVerifierMock} from '../mocks/verifiers/NoirVerifierMock.sol';
import {TitleHolderHonkVerifier} from '../../../src/identity/generated/title/TitleHolderHonkVerifier.sol';

/// Same minimal in-test ERC-7812 registry pattern as RegistrySourceAnchor.t.sol / EntrypointAsp.t.sol.
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
  }

  function removeStatement(bytes32 key) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    delete statements[key];
  }

  function updateStatement(bytes32 key, bytes32 newValue) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    statements[key] = newValue;
  }

  function getRootTimestamp(bytes32) external view returns (uint256) {
    return block.timestamp;
  }

  function getIsolatedKey(address source, bytes32 key) external pure returns (bytes32) {
    return keccak256(abi.encodePacked(source, key));
  }
}

/// OZ 5.6.1 rejects an ERC1967Proxy built with EMPTY init data; the state-keeper and SMT mocks are
/// deploy-then-initialize, so they need a proxy that opts back into it. Same helper as the other
/// suites that drive HolderStateKeeper directly.
contract UnsafeTestProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

contract TitleLedgerTest is Test, CreReportMetadata {
  TitleLedger internal ledger;
  RegistrySourceAnchor internal registry;
  NoirVerifierMock internal titleHolderVerifier;
  /// Verifies notary_action proofs. A MOCK here on purpose: this suite tests the LEDGER's
  /// authorisation logic, while the real proof property is covered end-to-end by
  /// NotaryActionHonkVerifier.t.sol against a genuine bb proof. Same split as
  /// PrivacyPoolSimple.t.sol. Without it every action test would need its own regenerated
  /// fixture, since a fixture's action_context cannot match a contract-derived one.
  NoirVerifierMock internal notaryActionVerifier;

  /// The notary's leaf key: Poseidon(notary_secret) in production. Opaque to the contract.
  bytes32 internal constant NOTARY_COMMITMENT = keccak256('notary-jane-commitment');
  /// Stands in for a notary_action proof. Contents are irrelevant to the mock.
  bytes internal constant NOTARY_PROOF = hex'01';

  address internal admin = address(0xA011);
  address internal postman = address(0xB022);

  uint256 internal constant NOTARY_PK = 0xC0FFEE;
  address internal notary;
  uint256 internal constant OTHER_PK = 0xBEEF;
  address internal otherSigner;

  bytes32 internal constant REGISTRY_ID = keccak256('UA_NOTARY_REGISTRY');
  bytes32 internal notaryDataHash;
  bytes32 internal decoyLeaf;
  bytes32[] internal notaryProof; // sibling(s) needed to prove notaryDataHash against the active root

  HolderStateKeeperMock internal stateKeeper;

  /// The notary's identity. A notary is a passport holder in this system before they are a notary.
  bytes32 internal constant NOTARY_HOLDER_ROOT = keccak256('notary-jane-doe-holder-root');

  function setUp() public {
    notary = vm.addr(NOTARY_PK);
    otherSigner = vm.addr(OTHER_PK);

    registry = new RegistrySourceAnchor(address(new MockEvidenceRegistry()), admin);
    _activateWorkflow(registry, admin);
    // Read the role constant BEFORE vm.prank - it's itself an external call and would otherwise
    // consume the single-shot prank before grantRole executes (see RegistrySourceAnchor.t.sol).
    bytes32 registrarRole = registry.NOTARY_REGISTRAR();
    vm.prank(admin);
    registry.setForwarder(postman); // publication is an ADDRESS, not a grantable role

    vm.prank(admin);
    registry.grantRole(registrarRole, postman);

    // The notary is a REGISTERED IDENTITY, so the ledger needs the state keeper that holds
    // documents - a notary with no current document cannot act, which is what makes them revocable
    // like every other user.
    PoseidonSMTMock smt = PoseidonSMTMock(address(new UnsafeTestProxy(address(new PoseidonSMTMock()))));
    PoseidonSMTMock certs = PoseidonSMTMock(address(new UnsafeTestProxy(address(new PoseidonSMTMock()))));
    stateKeeper = HolderStateKeeperMock(address(new UnsafeTestProxy(address(new HolderStateKeeperMock()))));
    MockEvidenceRegistry ev = new MockEvidenceRegistry();
    smt.__PoseidonSMT_init(address(stateKeeper), address(ev), 80);
    certs.__PoseidonSMT_init(address(stateKeeper), address(ev), 80);
    stateKeeper.__StateKeeper_init(admin, address(smt), address(certs), bytes32(uint256(1)));

    string[] memory skKeys = new string[](1);
    skKeys[0] = 'title';
    address[] memory skVals = new address[](1);
    skVals[0] = address(this);
    stateKeeper.mockAddRegistrations(skKeys, skVals);
    stateKeeper.addDocument(
      bytes32(uint256(0xD0C)), keccak256('notary-dg1'), NOTARY_HOLDER_ROOT, stateKeeper.DOC_PASSPORT(), 1, 0
    );

    titleHolderVerifier = new NoirVerifierMock();
    notaryActionVerifier = new NoirVerifierMock();
    ledger = new TitleLedger(
      address(registry), address(titleHolderVerifier), address(stateKeeper), admin, address(notaryActionVerifier)
    );

    // A real 2-leaf snapshot: notaryDataHash + one decoy, strictly ascending as
    // RegistrySourceAnchor requires.
    bytes32 a = keccak256('notary-1: reg#123, Jane Doe, Kyiv, active');
    bytes32 b = keccak256('notary-2: reg#456, John Roe, Lviv, active');
    notaryDataHash = a;
    decoyLeaf = b;
    (bytes32 leaf0, bytes32 leaf1) = a < b ? (a, b) : (b, a);
    bytes32[] memory leaves = new bytes32[](2);
    leaves[0] = leaf0;
    leaves[1] = leaf1;

    vm.prank(postman);
    registry.onReport(_metadata(keccak256('notary_registry.wasm@test')), abi.encode(REGISTRY_ID, bytes32(0), leaves));
    vm.warp(block.timestamp + registry.ROOT_ACTIVATION_DELAY());

    notaryProof = new bytes32[](1);
    notaryProof[0] = (a == leaf0) ? leaf1 : leaf0; // the OTHER leaf is notaryDataHash's sibling

    vm.prank(postman);
    ledger.registerNotary(NOTARY_COMMITMENT, notaryDataHash, REGISTRY_ID, notaryProof);
  }

  /// Sibling proof for `decoyLeaf`, the snapshot's other entry - used to admit a SECOND notary,
  /// which is what makes "any active notary may endorse" testable at all.
  function _decoyProof() internal view returns (bytes32[] memory p_) {
    p_ = new bytes32[](1);
    p_[0] = notaryDataHash;
  }

  /// Pin a workflow and warp past its delay, so snapshots can be published (sec. 2.18bs).
  /// Every test that publishes needs this now - a snapshot with no auditable workflow behind it is
  /// exactly what the pin exists to refuse.
  function _activateWorkflow(RegistrySourceAnchor anchor_, address owner_) internal {
    vm.prank(owner_);
    anchor_.pinWorkflow(REGISTRY_ID, keccak256('notary_registry.wasm@test'));
    vm.warp(block.timestamp + anchor_.WORKFLOW_ACTIVATION_DELAY() + 1);
  }

  function _mintMessage(
    bytes32 legalDescriptionHash_,
    bytes32 jurisdiction_,
    uint256 priorTitleId_
  ) internal view returns (bytes32) {
    return keccak256(abi.encodePacked('TITLE_LEDGER_MINT', address(ledger), legalDescriptionHash_, jurisdiction_, priorTitleId_));
  }

  function _sign(uint256 pk, bytes32 messageHash_) internal pure returns (bytes memory) {
    bytes32 digest = MessageHashUtils.toEthSignedMessageHash(messageHash_);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  /// Replace the mock verifier's BYTECODE with the real one, in place.
  /// Keeps the existing registry/notary/signature wiring intact - standing up a second ledger just
  /// to change one immutable would have meant re-plumbing all of it, and the thing under test is
  /// the verifier, not the setup.
  function _useRealVerifier() internal {
    vm.etch(address(titleHolderVerifier), address(new TitleHolderHonkVerifier()).code);
  }

  /// The document is deliberately the kind of low-entropy, publicly-enumerable string that makes a
  /// BARE hash brute-forceable from county records - a street address. The stored value is a
  /// DETERMINISTIC KEYED PSEUDONYM of it, `PRF(registryKey, hash)`, computed off-chain by the
  /// notary. Deterministic so duplicates collide; opaque so the dictionary attack fails.
  bytes32 internal constant DESC_HASH = keccak256('42 Khreshchatyk St, Kyiv');
  /// Stands in for the registry's PRF key. The contract never sees it - the pseudonym arrives
  /// already computed - so a keccak stand-in is faithful to what the contract can observe.
  bytes32 internal constant REGISTRY_KEY = keccak256('notary-registry-prf-key');

  function _propertyKey(bytes32 hash_) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(REGISTRY_KEY, hash_));
  }

  function _mintValidTitle(bytes32 holderCommitment_) internal returns (uint256 titleId_) {
    return _mintTitleForProperty(DESC_HASH, holderCommitment_);
  }

  /// Mint over a NAMED property. Needed because one property may carry only one live title, so any
  /// test wanting two titles must use two properties - which is the invariant working, not a
  /// nuisance to route around.
  function _mintTitleForProperty(bytes32 documentHash_, bytes32 holderCommitment_)
    internal
    returns (uint256 titleId_)
  {
    bytes32 descHash = _propertyKey(documentHash_);
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    titleId_ = ledger.mintTitle(
      descHash, jurisdiction, 0, REGISTRY_ID, ledger.notaryRoot(), NOTARY_PROOF, holderCommitment_
    );
  }

  // ── initialization / upgradeability ─────────────────────────────────────────────────────

  function test_constructor_revertsOnZeroNotaryRegistry() public {
    vm.expectRevert(TitleLedger.ZeroAddress.selector);
    new TitleLedger(address(0), address(titleHolderVerifier), address(stateKeeper), admin, address(notaryActionVerifier));
  }

  function test_constructor_revertsOnZeroVerifier() public {
    vm.expectRevert(TitleLedger.ZeroAddress.selector);
    new TitleLedger(address(registry), address(0), address(stateKeeper), admin, address(notaryActionVerifier));
  }

  function test_constructor_revertsOnZeroStateKeeper() public {
    vm.expectRevert(TitleLedger.ZeroAddress.selector);
    new TitleLedger(address(registry), address(titleHolderVerifier), address(0), admin, address(notaryActionVerifier));
  }

  // ── sec. 2.13l: a notary is a REGISTERED IDENTITY, and therefore revocable ────────────────

  /// THE POINT OF THE CHANGE. An address has no passport to expire and no document to invalidate,
  /// so a notary bound to a bare keypair was the only participant in this system who could not be
  /// revoked. Keyed by holderRoot, revoking their document stops them acting - by exactly the
  /// mechanism that covers every other user.
  /// An unknown root is refused. THE REGRESSION CLAUSE (sec. 2.18o): an unrecorded root maps to 0,
  /// and `0 + validity > block.timestamp` is TRUE on any chain younger than the window - which is
  /// how three separate copies of this rule accepted every invented root.
  function test_anInventedNotaryRootIsRefused() public {
    assertFalse(ledger.isValidNotaryRoot(keccak256('never a root')), 'an invented root was accepted');
    assertFalse(ledger.isValidNotaryRoot(bytes32(0)), 'the zero root was accepted');

    bytes32 descHash = _propertyKey(DESC_HASH);
    vm.expectRevert(TitleLedger.UnknownNotaryRoot.selector);
    ledger.mintTitle(descHash, keccak256('UA'), 0, REGISTRY_ID, keccak256('never a root'), NOTARY_PROOF, keccak256('hc'));
  }

  /// Binding must refuse an identity that holds no current document - a notary is a passport holder
  /// in this system BEFORE they are a notary.
  /// A commitment can only be admitted against a register entry that is really in the snapshot.
  function test_registerNotary_refusesAnEntryNotInTheSnapshot() public {
    vm.prank(postman);
    vm.expectRevert(TitleLedger.NotaryNotActive.selector);
    ledger.registerNotary(keccak256('someone'), keccak256('not in any snapshot'), REGISTRY_ID, notaryProof);
  }

  /// THE BINDING IS PROOF-GATED. The postman can no longer fabricate a binding for an identity
  /// whose owner never consented - it needs a `pp::title_holder` proof of control over that
  /// holderRoot, bound to this exact signing key and register entry so it cannot be replayed.
  ///
  /// No new circuit was needed: title_holder already proves
  /// `holder_root == extract_pk_identity_hash(sk_identity)` and binds it to a second field, and
  /// that field is an arbitrary CONTEXT - named `title_id` only because that was its first use.
  /// The zero commitment is the empty-leaf sentinel and must never be admitted.
  function test_registerNotary_refusesTheZeroCommitment() public {
    vm.prank(postman);
    vm.expectRevert(TitleLedger.ZeroNotaryIdentity.selector);
    ledger.registerNotary(bytes32(0), notaryDataHash, REGISTRY_ID, notaryProof);
  }

  /// The context must bind BOTH the signing key and the register entry, or a proof obtained for one
  /// binding could be replayed to attach a different key - or the same key to a different notary.
  /// Registering moves the root, and the new root is immediately usable.
  function test_registeringANotaryMovesTheRoot() public {
    bytes32 before = ledger.notaryRoot();
    vm.prank(postman);
    ledger.registerNotary(keccak256('notary-2-commitment'), decoyLeaf, REGISTRY_ID, _decoyProof());
    assertTrue(ledger.notaryRoot() != before, 'admitting a notary did not change the root');
    assertTrue(ledger.isValidNotaryRoot(ledger.notaryRoot()), 'the new root is not usable');
  }

  /// Losing NOTARY status and losing IDENTITY status are DIFFERENT EVENTS, which is why they are
  /// checked separately. This identity's document is perfectly current - it is their registry entry
  /// that is not in the active snapshot, so they are a valid person and not a valid notary.
  /// THE FAULT MECHANISM, and the reason no custodian quorum exists (sec. 2.18am). Revoking writes a
  /// non-zero leaf value, which no STATUS_CLEAN inclusion proof can equal - so the notary silently
  /// stops being able to act and NOBODY LEARNS WHO THEY WERE. Exclusion, not exposure.
  function test_revokingANotaryMovesTheRootAndIsPostmanGated() public {
    bytes32 before = ledger.notaryRoot();

    vm.expectRevert(TitleLedger.OnlyNotaryRegistrar.selector);
    ledger.revokeNotary(NOTARY_COMMITMENT, bytes32(uint256(1)));

    vm.prank(postman);
    ledger.revokeNotary(NOTARY_COMMITMENT, bytes32(uint256(1)));
    assertTrue(ledger.notaryRoot() != before, 'revocation did not change the root');
  }

  /*
   * THE SPLIT IS REAL, NOT COSMETIC (sec. 2.18cn).
   *
   * The suite's `postman` holds BOTH roles for convenience, so every test above would pass just as
   * well if the two were still one role. This is the test that fails if they are.
   *
   * WHY IT MATTERS CONCRETELY: publication ends up held by a CRE Forwarder - a machine relaying DON
   * reports. While the roles were merged, granting it to that machine handed it `revokeNotary`,
   * which this contract calls THE ENTIRE FAULT MECHANISM. Publication is now an ADDRESS rather than
   * a role, so it cannot be granted to anyone at all - but the registrar role still can be, and this
   * test is what keeps the two from being conflated again.
   */
  function test_aPublicationOnlyHolderCannotTouchTheNotarySet() public {
    // A FRESH anchor, because the suite's `postman` deliberately holds both powers for convenience
    // and would make this test compare an address against itself. The forwarder is write-once, so
    // the only way to have a publication-only address is to set it on an anchor that has none yet -
    // which is also the real deployment shape.
    RegistrySourceAnchor freshRegistry =
      new RegistrySourceAnchor(address(new MockEvidenceRegistry()), admin);
    address publisher = address(0xD044);
    vm.prank(admin);
    freshRegistry.setForwarder(publisher);

    assertEq(freshRegistry.forwarder(), publisher, 'the forwarder is not the publisher');
    assertFalse(
      freshRegistry.hasRole(freshRegistry.NOTARY_REGISTRAR(), publisher),
      'a publication-only address must not be a registrar'
    );

    // And it cannot become one by being the forwarder - the two are different KINDS of authority
    // now, not two roles that happen to be held apart.
    vm.prank(publisher);
    vm.expectRevert(TitleLedger.OnlyNotaryRegistrar.selector);
    ledger.revokeNotary(NOTARY_COMMITMENT, bytes32(uint256(1)));

    vm.prank(publisher);
    vm.expectRevert(TitleLedger.OnlyNotaryRegistrar.selector);
    ledger.registerNotary(keccak256('someone-else'), notaryDataHash, REGISTRY_ID, notaryProof);
  }

  /// The converse, so neither role silently subsumes the other: a registrar cannot publish
  /// snapshots. Without this the split could be half-done and still look complete.
  function test_aNotaryRegistrarCannotPublishSnapshots() public {
    address registrar = address(0xD055);
    bytes32 registrarRole = registry.NOTARY_REGISTRAR(); // read BEFORE the prank - it is a call too
    vm.prank(admin);
    registry.grantRole(registrarRole, registrar);

    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = keccak256('a leaf a registrar should not be able to anchor');

    vm.prank(registrar);
    vm.expectRevert(); // NotForwarder - publication is an address, not a role
    registry.onReport(_metadata(keccak256('notary_registry.wasm@test')), abi.encode(REGISTRY_ID, bytes32(0), leaves));
  }

  /// Zero IS the clean status, so it can never be a revocation predicate - otherwise "revoking"
  /// would rewrite the leaf to exactly the value that proves the notary is in good standing.
  function test_revokingWithTheZeroPredicateIsRefused() public {
    vm.prank(postman);
    vm.expectRevert(TitleLedger.ZeroNotaryIdentity.selector);
    ledger.revokeNotary(NOTARY_COMMITMENT, bytes32(0));
  }

  /// ⭐ REPLACES `test_initialize_cannotBeCalledTwice` and `test_upgradeToAndCall_revertsForNonOwner`.
  /// Both are VACUOUS now rather than merely passing — there is no initializer and no upgrade
  /// entrypoint — so deleting them silently would drop the property they guarded. This asserts the
  /// stronger claim: neither selector exists, for anyone, owner included. A land-title ledger whose
  /// owner can swap the implementation is a ledger whose owner can redefine ownership.
  function test_thereIsNoUpgradePath() public {
    (bool ok_, ) = address(ledger).call(
      abi.encodeWithSignature('upgradeToAndCall(address,bytes)', address(this), '')
    );
    assertFalse(ok_, 'ledger must expose no upgrade entrypoint');
    (bool ok2_, ) = address(ledger).call(
      abi.encodeWithSignature(
        'initialize(address,address,address,address,address)',
        address(registry), address(titleHolderVerifier), address(stateKeeper), admin, address(notaryActionVerifier)
      )
    );
    assertFalse(ok2_, 'ledger must expose no initializer');
  }

  // ── bindNotaryIdentity ──────────────────────────────────────────────────────────────────

  function test_registerNotary_revertsForNonPostman() public {
    vm.expectRevert(TitleLedger.OnlyNotaryRegistrar.selector);
    ledger.registerNotary(keccak256('x'), notaryDataHash, REGISTRY_ID, notaryProof);
  }

  // ── mintTitle ───────────────────────────────────────────────────────────────────────────

  function test_mintTitle_succeeds() public {
    bytes32 holderCommitment = keccak256('holder-commitment-1');
    uint256 titleId = _mintValidTitle(holderCommitment);

    assertEq(titleId, 1);
    assertEq(ledger.holderCommitment(titleId), holderCommitment);
    TitleLedger.TitleEntry memory entry = ledger.getTitle(titleId);
    assertEq(entry.propertyKey, _propertyKey(DESC_HASH));
    assertEq(entry.jurisdiction, keccak256('UA'));
    assertEq(entry.priorTitleId, 0);
    assertEq(entry.notaryRegistryId, REGISTRY_ID);
    // No `notary` field to assert - that IS the fix (sec. 2.18am). What the entry records is that
    // an active notary acted, via notaryRegistryId; never which one.
    assertEq(entry.mintedAt, block.timestamp);
    assertFalse(entry.encumbered);
  }

  // ── sec. 2.14a: confidential AND unique ──────────────────────────────────────────────────

  /// THE DICTIONARY ATTACK. The stored value must NOT be derivable from the document alone, or
  /// anyone could pull candidate legal descriptions from public county records and learn which
  /// real-world property sits behind a titleId.
  function test_theStoredKeyIsNotDerivableFromTheDocumentAlone() public {
    uint256 titleId = _mintValidTitle(keccak256('holder'));
    TitleLedger.TitleEntry memory entry = ledger.getTitle(titleId);

    assertTrue(entry.propertyKey != DESC_HASH, 'the bare document hash is stored');
    assertTrue(
      entry.propertyKey != keccak256(abi.encodePacked(DESC_HASH)),
      'the stored key is a plain re-hash - still brute-forceable from public records'
    );
  }

  /// THE PROPERTY A SALT WOULD HAVE DESTROYED. A salted commitment hides the property but makes two
  /// titles over the same land look unrelated, so double-minting becomes undetectable. A
  /// DETERMINISTIC key collides, and the collision is what this rejects.
  function test_thesamePropertyCannotBeTitledTwice() public {
    _mintValidTitle(keccak256('holder'));

    bytes32 key = _propertyKey(DESC_HASH);
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(key, jurisdiction, 0));

    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(abi.encodeWithSelector(TitleLedger.PropertyAlreadyTitled.selector, key, uint256(1)));
    ledger.mintTitle(key, jurisdiction, 0, REGISTRY_ID, root_, NOTARY_PROOF, keccak256('someone else'));
  }

  /// ...but a genuine SUCCESSION must still work, or the uniqueness rule would block every reissue
  /// and transfer of title. It must cite the title it replaces.
  function test_aSuccessorTitleOverTheSamePropertyIsAllowedWhenItCitesThePrior() public {
    uint256 first = _mintValidTitle(keccak256('holder'));

    bytes32 key = _propertyKey(DESC_HASH);
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(key, jurisdiction, first));

    uint256 second =
      ledger.mintTitle(key, jurisdiction, first, REGISTRY_ID, ledger.notaryRoot(), NOTARY_PROOF, keccak256('new holder'));
    assertEq(ledger.titleOfProperty(key), second, 'the property should now point at the successor');
  }

  /// A successor may not cite a prior title over a DIFFERENT property - that would launder one
  /// property's chain of title into another's.
  function test_aSuccessorCannotCiteAPriorTitleForAnotherProperty() public {
    uint256 first = _mintValidTitle(keccak256('holder'));

    bytes32 otherKey = _propertyKey(keccak256('99 Some Other St'));
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(otherKey, jurisdiction, first));

    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(abi.encodeWithSelector(TitleLedger.PriorTitleIsForAnotherProperty.selector, first));
    ledger.mintTitle(otherKey, jurisdiction, first, REGISTRY_ID, root_, NOTARY_PROOF, keccak256('h'));
  }

  function test_mintTitle_revertsOnZeroCommitment() public {
    bytes32 descHash = keccak256('desc');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(TitleLedger.ZeroCommitment.selector);
    ledger.mintTitle(descHash, jurisdiction, 0, REGISTRY_ID, root_, NOTARY_PROOF, bytes32(0));
  }

  /// A proof the verifier rejects must not mint. With the address gone this is the ONLY thing
  /// standing between a stranger and a title, so it is the load-bearing check of the new model.
  function test_mintTitle_revertsWhenTheNotaryProofIsRejected() public {
    notaryActionVerifier.setShouldVerify(false);
    bytes32 descHash = _propertyKey(DESC_HASH);
    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(TitleLedger.NotaryNotActive.selector);
    ledger.mintTitle(descHash, keccak256('UA'), 0, REGISTRY_ID, root_, NOTARY_PROOF, keccak256('hc'));
  }

  /// The latest root never expires, so notary inaction cannot freeze the ledger.
  function test_theLatestNotaryRootNeverExpires() public {
    vm.warp(block.timestamp + 3650 days);
    assertTrue(ledger.isValidNotaryRoot(ledger.notaryRoot()), 'the latest root expired');
  }

  /// A SUPERSEDED root stays usable only briefly - this tree carries revocations, so honouring an
  /// old root indefinitely would let a revoked notary act forever.
  function test_aSupersededNotaryRootExpires() public {
    bytes32 old = ledger.notaryRoot();
    vm.prank(postman);
    ledger.registerNotary(keccak256('notary-2-commitment'), decoyLeaf, REGISTRY_ID, _decoyProof());

    assertTrue(ledger.isValidNotaryRoot(old), 'a just-superseded root should still be usable');
    vm.warp(block.timestamp + ledger.NOTARY_ROOT_VALIDITY() + 1);
    assertFalse(ledger.isValidNotaryRoot(old), 'a superseded root never expired');
  }

  // ── addLegend ───────────────────────────────────────────────────────────────────────────

  function test_addLegend_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc'));

    bytes32 legendMsg = keccak256(abi.encodePacked('TITLE_LEDGER_LEGEND', address(ledger), titleId, 'subject to mortgage'));
    bytes memory sig = _sign(NOTARY_PK, legendMsg);
    ledger.addLegend(titleId, 'subject to mortgage', ledger.notaryRoot(), NOTARY_PROOF);

    string[] memory legends = ledger.getRestrictionLegends(titleId);
    assertEq(legends.length, 1);
    assertEq(legends[0], 'subject to mortgage');
  }

  function test_addLegend_revertsOnTitleNotFound() public {
    bytes32 legendMsg = keccak256(abi.encodePacked('TITLE_LEDGER_LEGEND', address(ledger), uint256(999), 'x'));
    bytes memory sig = _sign(NOTARY_PK, legendMsg);

    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(TitleLedger.TitleDoesNotExist.selector);
    ledger.addLegend(999, 'x', root_, NOTARY_PROOF);
  }

  /// ANY ACTIVE NOTARY MAY ENDORSE, not only the one who minted (user decision, 2026-07-31).
  /// Binding to the minting notary would have meant storing a commitment to them - a persistent
  /// PSEUDONYM linking every title they touched - and would have left a title permanently
  /// unamendable if that notary were ever revoked.
  function test_anyActiveNotaryCanEndorseNotOnlyTheMinter() public {
    uint256 titleId = _mintValidTitle(keccak256('holder'));

    vm.prank(postman);
    ledger.registerNotary(keccak256('notary-2-commitment'), decoyLeaf, REGISTRY_ID, _decoyProof());

    ledger.addLegend(titleId, 'subject to mortgage', ledger.notaryRoot(), NOTARY_PROOF);
    assertEq(ledger.restrictionLegends(titleId, 0), 'subject to mortgage');
  }

  // ── setEncumbered ───────────────────────────────────────────────────────────────────────

  function test_setEncumbered_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc'));

    bytes32 msg_ = keccak256(abi.encodePacked('TITLE_LEDGER_ENCUMBER', address(ledger), titleId, true));
    bytes memory sig = _sign(NOTARY_PK, msg_);
    ledger.setEncumbered(titleId, true, ledger.notaryRoot(), NOTARY_PROOF);

    assertTrue(ledger.getTitle(titleId).encumbered);
  }

  /// An encumbrance without an accepted notary proof must not stick - a bare boolean with no
  /// authorisation would let anyone lock (or fraudulently clear) a lien on someone else's title.
  function test_setEncumbered_revertsWhenTheNotaryProofIsRejected() public {
    uint256 titleId = _mintValidTitle(keccak256('holder'));
    notaryActionVerifier.setShouldVerify(false);
    // Hoisted: `ledger.notaryRoot()` is an EXTERNAL call, and inline it would be made AFTER
    // vm.expectRevert arms - so the expectation would be consumed by a call that succeeds,
    // and the test would pass whatever the function under test did. Same lesson as reading
    // a role constant before vm.prank, noted in setUp.
    bytes32 root_ = ledger.notaryRoot();
    vm.expectRevert(TitleLedger.NotaryNotActive.selector);
    ledger.setEncumbered(titleId, true, root_, NOTARY_PROOF);
  }

  // ── transferTitle / verifyHolderProof ──────────────────────────────────────────────────

  /*
   * THE REAL VERIFIER, NOT THE MOCK.
   *
   * These two used to assert only that TitleLedger forwards to whatever verifier it holds - the
   * mock returns true, so `hex'ab'` "verified". That tests the plumbing and nothing about whether
   * a genuine holder proof is accepted, which is the claim that matters: a title's holder proof is
   * what links a title to an identity without revealing it.
   *
   * Now a real TitleHolderHonkVerifier and a real proof. The commitment is the circuit's own
   * expected_commitment for title_id = 1 (= Poseidon(holder_root(sk 1234), 1)), and titleId is 1
   * because TitleLedger's counter starts there - the public inputs TitleLedger builds
   * ([holderCommitment, titleId]) must be exactly the ones the circuit bound.
   */
  uint256 internal constant TITLE1_COMMITMENT =
    13133097628895757648741781760678152926284111620646563595865187894813129799232;

  function test_verifyHolderProof_acceptsARealProof() public {
    uint256 titleId = _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    assertEq(titleId, 1, 'fixture is bound to title_id = 1');
    _useRealVerifier();

    assertTrue(
      ledger.verifyHolderProof(titleId, vm.readFileBinary('test/fixtures/title_holder_id1.proof')),
      'a genuine holder proof was rejected'
    );
  }

  /// @notice The same proof against a DIFFERENT title must fail - otherwise one holder proof would
  /// unlock every title, which is the whole property `title_id` is a public input for.
  function test_verifyHolderProof_rejectsAProofBoundToAnotherTitle() public {
    _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    // A SECOND PROPERTY, not a second title over the first - one property carries one live title.
    uint256 second = _mintTitleForProperty(keccak256('7 Another St, Lviv'), bytes32(TITLE1_COMMITMENT));
    _useRealVerifier();

    // The Honk verifier REVERTS (SumcheckFailed) rather than returning false when the public
    // inputs do not match the proof - both are correct rejections, so accept either.
    try ledger.verifyHolderProof(second, vm.readFileBinary('test/fixtures/title_holder_id1.proof'))
    returns (bool ok) {
      assertFalse(ok, 'a proof for title 1 was accepted for a different title');
    } catch {
      assertTrue(true);
    }
  }

  function test_verifyHolderProof_rejectsGarbageAgainstTheRealVerifier() public {
    uint256 titleId = _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    _useRealVerifier();

    try ledger.verifyHolderProof(titleId, hex'ab') returns (bool ok) {
      assertFalse(ok, 'the real verifier accepted 2 bytes of garbage');
    } catch {
      assertTrue(true); // reverting on a malformed proof is equally correct
    }
  }

  function test_verifyHolderProof_revertsOnTitleNotFound() public {
    vm.expectRevert(TitleLedger.TitleDoesNotExist.selector);
    ledger.verifyHolderProof(999, hex'ab');
  }

  function test_transferTitle_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));
    bytes32 newCommitment = keccak256('hc-new');

    ledger.transferTitle(titleId, newCommitment, hex'ab');
    assertEq(ledger.holderCommitment(titleId), newCommitment);
  }

  function test_transferTitle_revertsOnInvalidProof() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));
    titleHolderVerifier.setShouldVerify(false);

    vm.expectRevert(TitleLedger.InvalidHolderProof.selector);
    ledger.transferTitle(titleId, keccak256('hc-new'), hex'ab');
  }

  function test_transferTitle_revertsOnZeroNewCommitment() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));

    vm.expectRevert(TitleLedger.ZeroCommitment.selector);
    ledger.transferTitle(titleId, bytes32(0), hex'ab');
  }
}
