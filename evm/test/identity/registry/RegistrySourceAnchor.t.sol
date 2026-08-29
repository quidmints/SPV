// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {RegistrySourceAnchor} from '../../../src/identity/registry/RegistrySourceAnchor.sol';
import {CreReportMetadata} from './CreReportMetadata.sol';
import {IReceiver} from '../../../src/identity/interfaces/registry/IReceiver.sol';
import {IERC165} from '@oz/utils/introspection/IERC165.sol';

/// Minimal in-test ERC-7812 registry - same pattern as EntrypointAsp.t.sol's MockEvidenceRegistry
/// (keccak-isolated, sidesteps the real registry's Poseidon-under-Forge linking issue).
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;
  uint256 public count;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
    count++;
  }

  function removeStatement(bytes32 key) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    delete statements[key];
    count--;
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

contract RegistrySourceAnchorTest is Test, CreReportMetadata {
  RegistrySourceAnchor internal anchor;
  MockEvidenceRegistry internal registry;

  address internal admin = address(0xA011);
  address internal postman = address(0xB022);
  address internal stranger = address(0xC033);

  bytes32 internal constant NOTARY_REGISTRY = keccak256('UA_NOTARY_REGISTRY');
  bytes32 internal constant OTHER_REGISTRY = keccak256('SOME_OTHER_LIST');

  uint256 internal constant SNARK_SCALAR_FIELD =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  function setUp() public {
    registry = new MockEvidenceRegistry();

    // No proxy: the anchor is not upgradeable, so config is constructor-set and permanent.
    anchor = new RegistrySourceAnchor(address(registry), admin);
    _activateWorkflow(anchor, admin);

    // The publication gate is an ADDRESS now, not a role: `postman` is simply the Forwarder this
    // anchor accepts. It is replaceable by OWNER_ROLE - see the re-point tests below.

    vm.prank(admin);
    anchor.setForwarder(postman);
    // The FIRST set is immediate (no incumbent to protect); every later one is a timelocked
    // proposal — see the sec. 2.18gz-fwd block at the end of this file.
  }

  function _expectedKey(bytes32 registryId_, uint256 index_) internal view returns (bytes32) {
    return
      bytes32(
        uint256(keccak256(abi.encodePacked('REGISTRY_SOURCE_ROOT', registryId_, address(anchor), index_))) %
          SNARK_SCALAR_FIELD
      );
  }

  /// Two-leaf sorted set + the OpenZeppelin-MerkleProof-compatible root for it (sorted-pair
  /// keccak, matching RegistrySourceAnchor._computeRoot and MerkleProof.verify's convention).
  function _twoLeafSet(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory leaves, bytes32 root) {
    (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
    leaves = new bytes32[](2);
    leaves[0] = lo;
    leaves[1] = hi;
    root = lo < hi ? keccak256(abi.encodePacked(lo, hi)) : keccak256(abi.encodePacked(hi, lo));
  }

  function _oneLeafSet(bytes32 a) internal pure returns (bytes32[] memory leaves) {
    leaves = new bytes32[](1);
    leaves[0] = a;
  }

  /// The workflow `_activateWorkflow` pins - reports must name THIS to be accepted.
  bytes32 internal constant TEST_WORKFLOW = keccak256('notary_registry.wasm@test');

  // ── initialization / upgradeability ─────────────────────────────────────────────────────

  /// Pin a workflow and warp past its delay, so snapshots can be published (sec. 2.18bs).
  /// Every test that publishes needs this now - a snapshot with no auditable workflow behind it is
  /// exactly what the pin exists to refuse.
  function _activateWorkflow(RegistrySourceAnchor anchor_, address owner_) internal {
    // 🔴 PINNED PER REGISTRY SINCE sec. 2.18gz-wf. When the pin was global, one call armed every
    // registry — which is exactly the defect: pinning for one list silently governed the others.
    // Tests that publish to a second registry must now arm it too, and three of them failed on
    // this change for precisely that reason.
    vm.startPrank(owner_);
    anchor_.pinWorkflow(NOTARY_REGISTRY, keccak256('notary_registry.wasm@test'));
    anchor_.pinWorkflow(OTHER_REGISTRY, keccak256('notary_registry.wasm@test'));
    vm.stopPrank();
    vm.warp(block.timestamp + anchor_.WORKFLOW_ACTIVATION_DELAY() + 1);
  }

  function test_constructor_revertsOnZeroEvidenceRegistry() public {
    vm.expectRevert(RegistrySourceAnchor.ZeroAddress.selector);
    new RegistrySourceAnchor(address(0), admin);
  }

  function test_constructor_revertsOnZeroAdmin() public {
    vm.expectRevert(RegistrySourceAnchor.ZeroAddress.selector);
    new RegistrySourceAnchor(address(registry), address(0));
  }

  /// ⭐ REPLACES `test_initialize_cannotBeCalledTwice` AND `test_upgradeToAndCall_revertsForNonOwner`,
  /// which are both VACUOUS now rather than merely passing: there is no initializer to call twice
  /// and no upgrade entrypoint to gate. Deleting them without a successor would quietly drop the
  /// property they were protecting, so this asserts the STRONGER thing they were approximating —
  /// the upgrade path does not exist at all, for anyone, not even the owner.
  function test_thereIsNoUpgradePath() public {
    (bool ok_, ) = address(anchor).call(
      abi.encodeWithSignature('upgradeToAndCall(address,bytes)', address(this), '')
    );
    assertFalse(ok_, 'anchor must expose no upgrade entrypoint');
    (bool ok2_, ) = address(anchor).call(
      abi.encodeWithSignature('initialize(address,address)', address(registry), admin)
    );
    assertFalse(ok2_, 'anchor must expose no initializer');
  }

  // ── access control ──────────────────────────────────────────────────────────────────────

  function test_onReport_revertsForNonPostmanWithValidMetadata() public {
    vm.prank(stranger);
    vm.expectRevert();
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('leaf'))));
  }

  function test_onReport_revertsForNonPostman() public {
    bytes memory report = abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('leaf')));
    vm.prank(stranger);
    vm.expectRevert();
    anchor.onReport('', report);
  }

  /**
   * Publish through `onReport` and read the result BACK FROM STATE.
   *
   * `onReport` returns nothing as of sec. 2.18fg - Chainlink's `IReceiver` declares
   * `function onReport(bytes,bytes) external;` with no return value, and the Forwarder ERC-165-probes
   * for that interface before it will deliver anything at all.
   *
   * THIS IS A STRONGER ASSERTION THAN THE ONE IT REPLACES, not a workaround for a lost convenience.
   * These tests previously read `(index, root)` straight out of the call under test - a number
   * produced BY the code being verified. `snapshots[registryId][index]` is what a real consumer
   * reads, on-chain or off, so a publication that returned the right values while persisting the
   * wrong ones would now be caught, and before it would not have been.
   */
  function _report(bytes32 registryId_, bytes32[] memory leaves_)
    internal
    returns (uint256 index_, bytes32 root_)
  {
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(registryId_, bytes32(0), leaves_));
    index_ = anchor.snapshotCount(registryId_) - 1;
    (root_, , ) = anchor.snapshots(registryId_, index_);
  }

  // ── snapshot publication (via onReport, the only entrypoint) ────────────────────────────

  function test_snapshot_singleLeaf_rootIsTheLeafItself() public {
    bytes32 leaf = keccak256('only-notary');
    vm.prank(postman);
    (uint256 index, bytes32 root) = _report(NOTARY_REGISTRY, _oneLeafSet(leaf));

    assertEq(index, 0);
    assertEq(root, leaf); // a 1-leaf tree's root IS the leaf - matches MerkleProof.verify(empty proof)
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), root);
    assertEq(registry.count(), 1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), root);
  }

  function test_snapshot_twoLeaves_computesSortedPairRoot() public {
    (bytes32[] memory leaves, bytes32 expectedRoot) = _twoLeafSet(keccak256('a'), keccak256('b'));

    vm.prank(postman);
    (, bytes32 root) = _report(NOTARY_REGISTRY, leaves);

    assertEq(root, expectedRoot);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), expectedRoot);
  }

  function test_snapshot_revertsOnEmptyLeafSet() public {
    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.EmptyLeafSet.selector);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), new bytes32[](0)));
  }

  function test_snapshot_revertsOnUnsortedLeaves() public {
    bytes32 a = keccak256('a');
    bytes32 b = keccak256('b');
    (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
    bytes32[] memory badOrder = new bytes32[](2);
    badOrder[0] = hi; // descending - must revert
    badOrder[1] = lo;

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.LeavesNotStrictlySorted.selector);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), badOrder));
  }

  function test_snapshot_revertsOnDuplicateLeaves() public {
    bytes32 leaf = keccak256('dup');
    bytes32[] memory duplicated = new bytes32[](2);
    duplicated[0] = leaf;
    duplicated[1] = leaf; // strictly ascending required - equal adjacent values must revert

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.LeavesNotStrictlySorted.selector);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), duplicated));
  }

  function test_snapshot_emitsFullLeafSet() public {
    (bytes32[] memory leaves, ) = _twoLeafSet(keccak256('a'), keccak256('b'));

    vm.expectEmit(true, true, false, true);
    emit RegistrySourceAnchor.SnapshotLeaves(NOTARY_REGISTRY, 0, leaves);
    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), leaves));
  }

  function test_snapshot_neverOverwritesPriorSnapshot() public {
    vm.startPrank(postman);
    (, bytes32 root0) = _report(NOTARY_REGISTRY, _oneLeafSet(keccak256('a')));
    (, bytes32 root1) = _report(NOTARY_REGISTRY, _oneLeafSet(keccak256('b')));
    vm.stopPrank();

    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 2);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), root0);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 1)), root1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), root1);
  }

  function test_snapshot_distinctRegistriesDoNotCollide() public {
    vm.startPrank(postman);
    (, bytes32 rootA) = _report(NOTARY_REGISTRY, _oneLeafSet(keccak256('a')));
    (, bytes32 rootB) = _report(OTHER_REGISTRY, _oneLeafSet(keccak256('b')));
    vm.stopPrank();

    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 1);
    assertEq(anchor.snapshotCount(OTHER_REGISTRY), 1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), rootA);
    assertEq(anchor.latestRoot(OTHER_REGISTRY), rootB);
  }

  // ── onReport ────────────────────────────────────────────────────────────────────────────

  function test_onReport_decodesAndPublishes() public {
    bytes32 leaf = keccak256('c');
    bytes memory report = abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(leaf));

    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), report);
    uint256 index = anchor.snapshotCount(NOTARY_REGISTRY) - 1;
    (bytes32 root, , ) = anchor.snapshots(NOTARY_REGISTRY, index);

    assertEq(index, 0);
    assertEq(root, leaf);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), leaf);
  }

  /*
   * THE SWAP THAT USED TO SUCCEED.
   *
   * `onReport` discarded `metadata`, on the reasoning that `onlyRole(REGISTRY_POSTMAN)` already
   * gated the caller. But the Forwarder relays whatever the DON ran, so a rogue workflow's report
   * arrives from the SAME authorised address as an honest one, and the only workflow check in the
   * publish path asked whether ANY pin was active - never whether THIS report came from it. Before
   * the fix this test published happily; the old `onReport('some-metadata', ...)` above is the
   * evidence, since arbitrary bytes were an acceptable provenance.
   */
  function test_onReport_revertsForAWorkflowThatIsNotThePinnedOne() public {
    bytes32 rogue = keccak256('notary_registry.wasm@attacker');
    bytes memory report = abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('c')));

    vm.prank(postman);
    vm.expectRevert(
      abi.encodeWithSelector(RegistrySourceAnchor.UnpinnedWorkflow.selector, rogue, TEST_WORKFLOW)
    );
    anchor.onReport(_metadata(rogue), report);
  }

  /*
   * AND THE CONTRACT READS OFFSET 45, NOT "SOMEWHERE IN THE HEADER".
   *
   * Non-vacuity for the offset itself: this metadata CONTAINS the pinned workflow ID, but one byte
   * off from where the layout puts it. A `contains`-style check - or an off-by-one shared by test
   * and contract - would accept it. Getting this wrong rejects VALID production reports, which is
   * the failure that looks like a healthy rejection, so it is worth pinning explicitly.
   */
  function test_onReport_readsTheWorkflowIdAtTheDocumentedOffset() public {
    bytes memory shifted = abi.encodePacked(
      uint8(1),
      keccak256('execution-id'),
      uint32(1_700_000_000),
      uint32(7),
      uint32(2),
      bytes1(0x00), // one byte of padding: the ID now starts at 46, not 45
      TEST_WORKFLOW,
      bytes10('wf-notary'),
      bytes20(uint160(0xBEEF)),
      bytes1(0xAB)
    );
    assertEq(shifted.length, anchor.REPORT_METADATA_LENGTH(), 'header must stay 109 bytes');

    vm.prank(postman);
    vm.expectRevert(); // UnpinnedWorkflow - the window at 45 is not the pinned ID
    anchor.onReport(shifted, abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('c'))));
  }

  /*
   * WHAT THE WORKFLOW PIN DOES **NOT** BUY, PROVEN RATHER THAN CAVEATED.
   *
   * `metadata` is CALLER-SUPPLIED CALLDATA. A postman that is an ordinary key does not need to run
   * the pinned workflow to satisfy the identity check - it writes the pinned ID into the header
   * itself and publishes whatever leaves it likes. This test passes, and it is SUPPOSED to: it is
   * the postman vulnerability of sec. 2.18bn stated executably.
   *
   * So the pin defends against a ROGUE WORKFLOW GIVEN AN HONEST RELAY. It is worth exactly as much
   * as the Forwarder holding REGISTRY_POSTMAN, because the Forwarder builds this header from an
   * OCR-verified report instead of accepting it as an argument. Granted to an EOA, the check below
   * is bypassed by writing 32 bytes. Delete this test the day the role is Forwarder-only - until
   * then it is the honest statement of what is guarded.
   */
  function test_anEoaPostmanForgesTheHeaderAndPublishesFabricatedLeaves() public {
    bytes32 fabricated = keccak256('a designation no register ever contained');

    vm.prank(postman); // an ordinary key: it never ran the pinned workflow
    (, bytes32 root) = _report(NOTARY_REGISTRY, _oneLeafSet(fabricated)); // ...and simply asserts that it did

    assertEq(root, fabricated, 'the pin does not constrain a postman that can write its own metadata');
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), fabricated);
  }

  /// A truncated header must be REFUSED, not sliced - reading past it would compare whatever
  /// follows in calldata and fail in a way indistinguishable from an honest rejection.
  function test_onReport_revertsOnTruncatedMetadata() public {
    uint256 truncated = anchor.REPORT_METADATA_LENGTH() - 1;
    bytes memory short = new bytes(truncated);

    vm.prank(postman);
    vm.expectRevert(
      abi.encodeWithSelector(RegistrySourceAnchor.MalformedReportMetadata.selector, truncated)
    );
    anchor.onReport(short, abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('c'))));
  }

  // ── latestRoot / latestActiveRoot / snapshotCount ──────────────────────────────────────

  function test_latestRoot_revertsWhenNoSnapshots() public {
    vm.expectRevert(RegistrySourceAnchor.NoSnapshotsAvailable.selector);
    anchor.latestRoot(NOTARY_REGISTRY);
  }

  function test_latestActiveRoot_respectsActivationDelay() public {
    bytes32 leaf = keccak256('a');
    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(leaf)));

    vm.expectRevert(RegistrySourceAnchor.NoActiveSnapshot.selector);
    anchor.latestActiveRoot(NOTARY_REGISTRY);

    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leaf);
  }

  function test_latestActiveRoot_keepsPreviousRootDuringWindow() public {
    bytes32 leafA = keccak256('a');
    bytes32 leafB = keccak256('b');
    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(leafA)));
    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());

    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(leafB)));
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leafA); // leafB's snapshot still pending

    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leafB);
  }
  // ---- workflow pinning (sec. 2.18bs) --------------------------------------------------------

  /*
   * THE PIN IS ENFORCED, NOT DECORATIVE. `ConsensusIdenticalAggregation` proves the DON nodes AGREE,
   * never that they are RIGHT (sec. 2.18ao) - verifying the register's TLS session inside the
   * workflow fixes that, but only if the workflow that ran is the one that does the verifying.
   * Consensus protects against a rogue NODE, never a rogue WORKFLOW (sec. 2.15a).
   *
   * So publishing must be impossible with no active version. Written against a FRESH anchor rather
   * than the pinned one from setUp, because a test that could not fail is the thing this suite is
   * least allowed to contain.
   */
  /*
   * THE FORWARDER IS REPLACEABLE BY THE OWNER, AND IT WAS WRITE-ONCE UNTIL sec. 2.18fg.
   *
   * The two tests here previously asserted the OPPOSITE - that not even the owner could re-point it -
   * and called that "the whole security argument". It was not one. Chainlink's own guidance is that
   * the forwarder address DIFFERS BETWEEN ENVIRONMENTS (MockForwarder to simulate, KeystoneForwarder
   * in production) and their `ReceiverTemplate` exposes `setForwarderAddress()` precisely to move
   * between them without redeploying. Write-once turned the documented lifecycle into a UUPS upgrade.
   *
   * It also never bought what it claimed: `OWNER_ROLE` holds the upgrade key, so the same key-holder
   * could always re-point the address by upgrading. Write-once removed the cheap path and left the
   * expensive one open.
   */
  function test_theOwnerCanRepointTheForwarder() public {
    assertTrue(anchor.hasRole(anchor.OWNER_ROLE(), admin), 'admin should be the owner');

    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));

    // 🔴 THE RE-POINT DOES NOT TAKE EFFECT IN THIS BLOCK, AND THAT IS THE FIX. Same-block was the
    // total bypass: re-point at an EOA and publish from it in one transaction.
    assertEq(anchor.activeForwarder(), postman, 'the re-point took effect immediately');
    assertEq(anchor.pendingForwarder(), address(0xBEEF), 'the proposal was not recorded');

    vm.warp(block.timestamp + anchor.FORWARDER_ACTIVATION_DELAY());
    assertEq(anchor.activeForwarder(), address(0xBEEF), 'the delay elapsed and it is still not live');

    // The stored slot settles on first use, not on a separate call — see
    // test_publishingFoldsAnElapsedRepointIntoStorage.
    vm.prank(address(0xBEEF));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('r'))));
    assertEq(anchor.forwarder(), address(0xBEEF), 'the forwarder was not re-pointed');
    assertEq(anchor.pendingForwarder(), address(0), 'the pending slot was not cleared');
  }

  /// The re-point must actually MOVE the authority, not merely record a new address - the old
  /// forwarder has to stop being accepted. Without this a re-point could pass while leaving a
  /// compromised address able to publish, which is the failure the rotation exists to fix.
  function test_repointingRevokesTheOldForwarder() public {
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));
    vm.warp(block.timestamp + anchor.FORWARDER_ACTIVATION_DELAY());

    vm.prank(postman); // the ADDRESS THAT USED TO BE the forwarder
    vm.expectRevert(abi.encodeWithSelector(RegistrySourceAnchor.NotForwarder.selector, postman));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('x'))));

    vm.prank(address(0xBEEF)); // ...and the new one is accepted
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('x'))));
    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 1, 'the new forwarder could not publish');
  }

  /// Still refused for a non-owner, and still refused for the zero address - the latter because
  /// `onReport` compares unconditionally, so a zero forwarder would accept NOBODY and silently brick
  /// publication rather than opening it.
  function test_theForwarderCannotBeRepointedByAStranger() public {
    vm.prank(stranger);
    vm.expectRevert();
    anchor.setForwarder(address(0xBEEF));
  }

  function test_theForwarderCannotBeSetToZero() public {
    vm.prank(admin);
    vm.expectRevert(RegistrySourceAnchor.ZeroAddress.selector);
    anchor.setForwarder(address(0));
  }

  /*
   * ERC-165, AND THIS IS THE ONE THAT WAS SILENTLY BROKEN (sec. 2.18fg).
   *
   * Chainlink: "The KeystoneForwarder uses ERC165 to check if your contract supports the IReceiver
   * interface before sending a report." This contract declared `onReport` but never advertised the
   * interface, so the probe answered FALSE and no report would ever have been delivered.
   *
   * NOTHING WOULD HAVE FAILED. No revert, no event, no failing test - the ingestion path would simply
   * have stayed silent forever, and every test in this file would have kept passing, because they all
   * call `onReport` DIRECTLY and skip the probe the real Forwarder performs first. That is exactly the
   * failure shape a guard earns its place against.
   */
  function test_theAnchorAdvertisesIReceiverToTheForwardersProbe() public view {
    assertTrue(
      anchor.supportsInterface(type(IReceiver).interfaceId),
      'the Forwarder ERC-165 probe would answer false and never deliver a report'
    );
  }

  /// The interface id must be the selector of `onReport` ALONE - Solidity excludes inherited
  /// functions from `interfaceId`, which is why ours matches Chainlink's despite the IERC165 base.
  /// Pinned as a value so a signature change cannot move it silently.
  function test_theReceiverInterfaceIdIsTheOnReportSelector() public pure {
    assertEq(
      type(IReceiver).interfaceId,
      bytes4(keccak256('onReport(bytes,bytes)')),
      'IReceiver.interfaceId is not the onReport selector'
    );
  }

  /// Adding IReceiver must not shadow what AccessControl already advertised, and an unknown id must
  /// still be false - without this a `supportsInterface` that returned true unconditionally would
  /// pass the test above.
  function test_supportsInterfaceKeepsAccessControlAndRejectsUnknown() public view {
    assertTrue(anchor.supportsInterface(type(IERC165).interfaceId), 'the ERC165 id was lost');
    assertFalse(anchor.supportsInterface(bytes4(0xdeadbeef)), 'an unknown interface answered true');
  }

  /// Nobody else may deliver a report - and the rejection names the caller rather than failing as a
  /// generic access-control error, so a misconfigured Forwarder address is diagnosable.
  function test_onlyTheForwarderMayDeliverAReport() public {
    address stranger = address(0xDEAD);
    bytes32[] memory leaves_ = new bytes32[](1);
    leaves_[0] = keccak256('a');

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(RegistrySourceAnchor.NotForwarder.selector, stranger));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), leaves_));
  }

  function test_publishingIsImpossibleWithNoActiveWorkflow() public {
    RegistrySourceAnchor fresh_ = new RegistrySourceAnchor(address(registry), admin);
    vm.prank(admin);
    fresh_.setForwarder(postman);
    // The forwarder gate runs BEFORE the workflow gate, so the forwarder has to be genuinely in
    // force or this test proves the wrong refusal — it would pass on `NotForwarder` while claiming
    // to be about `NoActiveWorkflow`.
    vm.warp(block.timestamp + fresh_.FORWARDER_ACTIVATION_DELAY());

    bytes32[] memory leaves_ = new bytes32[](1);
    leaves_[0] = keccak256('a');

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.NoActiveWorkflow.selector);
    fresh_.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), leaves_));
  }

  /// A pinned version is NOT usable until its delay elapses - the interval in which a malicious
  /// swap is visible and contestable before anything relies on it.
  function test_aPinnedWorkflowIsNotActiveUntilItsDelayElapses() public {
    RegistrySourceAnchor fresh_ = new RegistrySourceAnchor(address(registry), admin);
    vm.prank(admin);
    fresh_.pinWorkflow(NOTARY_REGISTRY, keccak256('v1'));

    assertEq(fresh_.activeWorkflowId(NOTARY_REGISTRY), bytes32(0), 'active before its delay elapsed');
    vm.warp(block.timestamp + fresh_.WORKFLOW_ACTIVATION_DELAY() + 1);
    assertEq(fresh_.activeWorkflowId(NOTARY_REGISTRY), keccak256('v1'), 'never became active');
  }

  /*
   * FAILS OPEN TO THE LAST GOOD VERSION. A newly pinned version must not displace its predecessor
   * during its own delay, or pinning would be a same-block censorship lever: publish a version
   * nobody has reviewed and the registry stops working until it activates.
   */
  function test_aNewPinDoesNotSilenceThePreviousVersionDuringItsDelay() public {
    vm.prank(admin);
    anchor.pinWorkflow(NOTARY_REGISTRY, keccak256('v2'));

    assertEq(
      anchor.activeWorkflowId(NOTARY_REGISTRY),
      keccak256('notary_registry.wasm@test'),
      'the previous version stopped working the moment a new one was pinned'
    );
  }

  /// Append-only in both senses: nothing is removed, and an already-named version cannot be
  /// re-pinned - which would reset its timelock and quietly re-arm a contested version.
  function test_theSameWorkflowCannotBeRepinnedToResetItsTimelock() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(
        RegistrySourceAnchor.WorkflowAlreadyPinned.selector, keccak256('notary_registry.wasm@test')
      )
    );
    anchor.pinWorkflow(NOTARY_REGISTRY, keccak256('notary_registry.wasm@test'));
  }

  /// NO NEW AUTHORITY: pinning reuses OWNER_ROLE. A postman - who may publish snapshots - must not
  /// be able to choose the code those snapshots are attributed to.
  function test_pinningIsOwnerOnlyAndNotAvailableToThePostman() public {
    vm.prank(postman);
    vm.expectRevert();
    anchor.pinWorkflow(NOTARY_REGISTRY, keccak256('v3'));
  }

  function test_theZeroWorkflowIdIsRefused() public {
    vm.prank(admin);
    vm.expectRevert(RegistrySourceAnchor.ZeroWorkflowId.selector);
    anchor.pinWorkflow(NOTARY_REGISTRY, bytes32(0));
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  //  THE GO WORKFLOW AND THIS CONTRACT MUST AGREE, AND EVERY TEST ABOVE IS BLIND TO WHETHER THEY DO
  //
  //  Every leaf set above is built in Solidity, so this suite proves the contract is consistent
  //  with itself. `backend/cre/sanctions_lists` builds the real one in Go, and the two conventions
  //  have to line up exactly: strictly ascending leaves, sorted pairs at each internal node, an odd
  //  node PROMOTED unchanged rather than hashed with itself.
  //
  //  THE FAILURE IS SILENT ON THE GO SIDE. That workflow shipped sorting its ENTRIES by uid and
  //  then mapping them to leaf HASHES, which are in no order at all - so every publish would have
  //  reverted `LeavesNotStrictlySorted`, and neither side said so, because neither had ever seen
  //  the other's output. That is what this pair of tests closes.
  //
  //  FIXTURE PROVENANCE: written by the REAL Go builder from a verbatim excerpt of the OFAC SDN
  //  export - SEVEN designations spanning all four types OFAC publishes. Regenerate with:
  //    cd backend/cre/sanctions_lists && go test -run EmitSolidity ./...
  //
  //  THE COUNT IS LOAD-BEARING AND WAS ORIGINALLY FOUR, WHICH PROVED NOTHING. Ascending leaves make
  //  the sorted-pair rule a no-op at the first level, and a power-of-two count never produces an odd
  //  level, so nothing was ever promoted - deleting the pair sorting from the Go builder left this
  //  suite green. The generator now refuses to write a fixture whose tree fails to exercise both
  //  rules, so the shape this test depends on is enforced on the side that produces it.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _sanctionsFixture()
    internal
    view
    returns (bytes32 registryId_, bytes32 root_, bytes32[] memory leaves_)
  {
    string memory raw = vm.readFile('test/identity/fixtures/sanctions_snapshot.txt');
    string[] memory lines = vm.split(raw, '\n');

    uint256 count_;
    for (uint256 i = 0; i < lines.length; ++i) {
      if (bytes(lines[i]).length == 0) continue;
      string[] memory parts = vm.split(lines[i], ' ');
      bytes32 value = vm.parseBytes32(string.concat('0x', parts[1]));
      if (keccak256(bytes(parts[0])) == keccak256('registryId')) registryId_ = value;
      else if (keccak256(bytes(parts[0])) == keccak256('root')) root_ = value;
      else ++count_;
    }

    leaves_ = new bytes32[](count_);
    uint256 j;
    for (uint256 i = 0; i < lines.length; ++i) {
      if (bytes(lines[i]).length == 0) continue;
      string[] memory parts = vm.split(lines[i], ' ');
      if (keccak256(bytes(parts[0])) == keccak256('leaf')) {
        leaves_[j++] = vm.parseBytes32(string.concat('0x', parts[1]));
      }
    }
  }

  /// THE BASELINE: the leaf set the Go workflow would actually submit is accepted, and the root
  /// this contract recomputes from it is the one Go computed. Note what is NOT submitted - the root
  /// is never passed in; `_computeRoot` derives it, and the fixture's value is only the expectation.
  function test_theGoSnapshotPublishesAndYieldsTheSameRoot() public {
    (bytes32 registryId, bytes32 goRoot, bytes32[] memory leaves) = _sanctionsFixture();
    // The sanctions fixture publishes to its OWN registryId, which needs its own pin now that the
    // gate is per-registry — the point of the change.
    vm.prank(admin);
    anchor.pinWorkflow(registryId, keccak256('notary_registry.wasm@test'));
    vm.warp(block.timestamp + anchor.WORKFLOW_ACTIVATION_DELAY() + 1);
    assertEq(leaves.length, 7, 'fixture did not carry the expected leaf count');

    vm.prank(postman);
    (uint256 index, bytes32 onChainRoot) = _report(registryId, leaves);

    assertEq(index, 0, 'first snapshot should be index 0');
    assertEq(onChainRoot, goRoot, 'Go and Solidity disagree about the Merkle root of one leaf set');
    assertEq(anchor.latestRoot(registryId), goRoot, 'the anchored root is not the computed one');
  }

  /// AND IT IS NOT VACUOUS. Swapping two adjacent leaves - exactly the difference between the Go
  /// builder's output and the ordering bug it shipped with - must revert. Without this, a
  /// `publishSnapshot` that ignored ordering entirely would pass the test above.
  function test_theGoOrderingIsWhatMakesItPublishable() public {
    (bytes32 registryId, , bytes32[] memory leaves) = _sanctionsFixture();
    // The sanctions fixture publishes to its OWN registryId, which needs its own pin now that the
    // gate is per-registry — the point of the change.
    vm.prank(admin);
    anchor.pinWorkflow(registryId, keccak256('notary_registry.wasm@test'));
    vm.warp(block.timestamp + anchor.WORKFLOW_ACTIVATION_DELAY() + 1);

    (leaves[0], leaves[1]) = (leaves[1], leaves[0]);

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.LeavesNotStrictlySorted.selector);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(registryId, bytes32(0), leaves));
  }

  /*
   * ════════════════════════════════════════════════════════════════════════════════════════
   *   sec. 2.18gz-fwd — THE FORWARDER TIMELOCK. `setForwarder` WAS THE TOTAL BYPASS.
   *
   *   Every mitigation §2.15a landed went on the WORKFLOW axis; `setForwarder` got none of them,
   *   and the surviving attack was one transaction: re-point at an EOA, then publish from it
   *   citing the genuinely pinned workflow id. The contract could not see it, because what it
   *   checks is which ADDRESS called and that address had just been chosen.
   * ════════════════════════════════════════════════════════════════════════════════════════
   */

  /// 🔴 THE TEST THIS WHOLE CHANGE EXISTS FOR. One transaction re-points, the next publishes — and
  /// it must now fail. If this ever passes, the anchor is back to one owner key with no delay, and
  /// `notary_registry/main.go`'s "no single operator can substitute a tampered snapshot" is false
  /// again regardless of how many DON nodes fetch.
  function test_theOneTransactionBypassIsClosed() public {
    address evilEoa_ = address(0xE0A);

    vm.prank(admin);
    anchor.setForwarder(evilEoa_);

    // Same block: the EOA holds a genuine pin and a well-formed header, and is still refused.
    vm.prank(evilEoa_);
    vm.expectRevert(abi.encodeWithSelector(RegistrySourceAnchor.NotForwarder.selector, evilEoa_));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('fabricated'))));

    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 0, 'a fabricated snapshot landed');
  }

  /// ⚠️ AND THE WINDOW IS NOT A BLACKOUT. `activeWorkflowId` fails open to its predecessor and this
  /// must too, or a re-point becomes a same-block CENSORSHIP lever instead of a takeover one.
  function test_theOldForwarderKeepsPublishingDuringTheWindow() public {
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));

    vm.prank(postman);
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('y'))));
    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 1, 'the incumbent was silenced by a proposal');
  }

  /// The delay is the whole instrument, so the boundary is asserted rather than assumed — and
  /// asserted one second SHORT of it, which is where an off-by-one would live.
  function test_theSwitchHappensExactlyOnTheBoundary() public {
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));
    uint64 activeFrom_ = anchor.pendingForwarderActiveFrom();

    vm.warp(activeFrom_ - 1);
    assertEq(anchor.activeForwarder(), postman, 'it went live a second early');

    vm.warp(activeFrom_);
    assertEq(anchor.activeForwarder(), address(0xBEEF), 'it did not go live on the boundary');
  }

  /// 🔑 THE STORED SLOT SETTLES ITSELF. `forwarder` folds forward the first time the new address
  /// publishes, so it never spends long naming an address that is no longer the gate — the stale
  /// reading that would otherwise get quoted as current. No promotion call, nothing to forget.
  function test_publishingFoldsAnElapsedRepointIntoStorage() public {
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));
    vm.warp(block.timestamp + anchor.FORWARDER_ACTIVATION_DELAY());
    assertEq(anchor.forwarder(), postman, 'it settled before anyone used it');

    vm.prank(address(0xBEEF));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('s'))));

    assertEq(anchor.forwarder(), address(0xBEEF), 'the stored slot did not settle');
    assertEq(anchor.pendingForwarder(), address(0), 'the pending slot was not cleared');
    assertEq(anchor.pendingForwarderActiveFrom(), 0, 'the pending timestamp was not cleared');
  }

  /// 🔑 AND A FORGOTTEN PROMOTION CANNOT STALL PUBLICATION. `activeForwarder` resolves the pending
  /// value on its own, so the new forwarder works on its first publication with no prior step.
  /// Without this the housekeeping call would be a liveness dependency dressed as a convenience.
  function test_anUnpromotedForwarderStillWorksOnceItsDelayPassed() public {
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));
    vm.warp(block.timestamp + anchor.FORWARDER_ACTIVATION_DELAY());

    assertEq(anchor.forwarder(), postman, 'the stored slot should still name the predecessor');

    vm.prank(address(0xBEEF));
    anchor.onReport(_metadata(TEST_WORKFLOW), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('z'))));
    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 1, 'an unpromoted forwarder could not publish');
  }

  /// Re-proposing the address already in force is refused — it would be a no-op that emits a
  /// `ForwarderProposed` a watcher has to investigate, and re-proposing a PENDING one would restart
  /// its clock, which is the quiet re-arm `pinWorkflow` refuses for the same reason.
  function test_reproposingTheActiveForwarderIsRefused() public {
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(RegistrySourceAnchor.ForwarderUnchanged.selector, postman));
    anchor.setForwarder(postman);
  }

  /// The proposal is ANNOUNCED with both addresses and the moment it becomes effective — the whole
  /// value of the window is that a watcher sees the re-point coming rather than finding it done.
  function test_aProposalIsAnnouncedWithItsActivationTime() public {
    vm.expectEmit(true, true, false, true, address(anchor));
    emit RegistrySourceAnchor.ForwarderProposed(
      postman, address(0xBEEF), uint64(block.timestamp + anchor.FORWARDER_ACTIVATION_DELAY())
    );
    vm.prank(admin);
    anchor.setForwarder(address(0xBEEF));
  }

  /*
   * ════════════════════════════════════════════════════════════════════════════════════════
   *   sec. 2.18gz-wf — THE PIN IS PER `registryId`. IT USED TO BE GLOBAL, AND THAT SILENTLY
   *   DISABLED EVERY REGISTRY BUT ONE.
   *
   *   `cre/notary_registry` and `cre/sanctions_lists` both write on-chain as separate binaries
   *   with separate workflow ids. With one global pin, arming either made every report from the
   *   other revert `UnpinnedWorkflow` — days later, presenting as "the sanctions root stopped
   *   updating", with a revert naming an id nobody recognised.
   * ════════════════════════════════════════════════════════════════════════════════════════
   */

  /// 🔴 THE TEST THE CHANGE EXISTS FOR: two registries, two workflows, both publishing. Under the
  /// old global pin the second `pinWorkflow` displaced the first and one of these reverted.
  function test_twoRegistriesWithDifferentWorkflowsBothPublish() public {
    RegistrySourceAnchor fresh_ = _freshAnchor();
    bytes32 wfA_ = keccak256('notary_registry.wasm@v1');
    bytes32 wfB_ = keccak256('sanctions_lists.wasm@v1');

    vm.startPrank(admin);
    fresh_.pinWorkflow(NOTARY_REGISTRY, wfA_);
    fresh_.pinWorkflow(OTHER_REGISTRY, wfB_);
    vm.stopPrank();
    vm.warp(block.timestamp + fresh_.WORKFLOW_ACTIVATION_DELAY() + 1);

    vm.startPrank(postman);
    fresh_.onReport(_metadata(wfA_), abi.encode(NOTARY_REGISTRY, bytes32(0), _oneLeafSet(keccak256('a'))));
    fresh_.onReport(_metadata(wfB_), abi.encode(OTHER_REGISTRY, bytes32(0), _oneLeafSet(keccak256('b'))));
    vm.stopPrank();

    assertEq(fresh_.snapshotCount(NOTARY_REGISTRY), 1, 'registry A could not publish');
    assertEq(fresh_.snapshotCount(OTHER_REGISTRY), 1, 'registry B could not publish');
  }

  /// ...and the gate still BITES per registry: A's workflow cannot publish B's list.
  function test_aWorkflowCannotPublishAnotherRegistrysList() public {
    RegistrySourceAnchor fresh_ = _freshAnchor();
    bytes32 wfA_ = keccak256('notary_registry.wasm@v1');
    bytes32 wfB_ = keccak256('sanctions_lists.wasm@v1');

    vm.startPrank(admin);
    fresh_.pinWorkflow(NOTARY_REGISTRY, wfA_);
    fresh_.pinWorkflow(OTHER_REGISTRY, wfB_);
    vm.stopPrank();
    vm.warp(block.timestamp + fresh_.WORKFLOW_ACTIVATION_DELAY() + 1);

    vm.prank(postman);
    vm.expectRevert(abi.encodeWithSelector(RegistrySourceAnchor.UnpinnedWorkflow.selector, wfA_, wfB_));
    fresh_.onReport(_metadata(wfA_), abi.encode(OTHER_REGISTRY, bytes32(0), _oneLeafSet(keccak256('x'))));
  }

  /// An unpinned registry publishes NOTHING, rather than inheriting some other registry's pin.
  /// Fail-closed per list is the whole point of moving the gate.
  function test_anUnpinnedRegistryIsRefused() public {
    RegistrySourceAnchor fresh_ = _freshAnchor();
    bytes32 wfA_ = keccak256('notary_registry.wasm@v1');

    vm.prank(admin);
    fresh_.pinWorkflow(NOTARY_REGISTRY, wfA_);
    vm.warp(block.timestamp + fresh_.WORKFLOW_ACTIVATION_DELAY() + 1);

    assertEq(fresh_.activeWorkflowId(OTHER_REGISTRY), bytes32(0), 'an unpinned registry looks armed');

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.NoActiveWorkflow.selector);
    fresh_.onReport(_metadata(wfA_), abi.encode(OTHER_REGISTRY, bytes32(0), _oneLeafSet(keccak256('x'))));
  }

  /// A fresh anchor with its forwarder live and NO workflow pinned anywhere.
  function _freshAnchor() internal returns (RegistrySourceAnchor fresh_) {
    fresh_ = new RegistrySourceAnchor(address(registry), admin);
    vm.prank(admin);
    fresh_.setForwarder(postman); // first set is immediate — see the forwarder block above
  }
}
