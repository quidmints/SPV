// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// OZ 5.6.1 hardened ERC1967Proxy to revert on empty init data (front-run/MITM protection for
/// real deployments). This suite deploys-then-initializes in two separate calls (matching
/// StateKeeper/PoseidonSMT's own __xxx_init(...) external initializer pattern) — safe in a
/// single-threaded test, so this test-only proxy opts back into that behavior.
contract UnsafeTestProxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";

import {HolderStateKeeper} from "../../contracts/holder/HolderStateKeeper.sol";
import {HolderStateKeeperMock} from "../../contracts/mock/holder/HolderStateKeeperMock.sol";
import {PoseidonSMTMock} from "../../contracts/mock/state/PoseidonSMTMock.sol";
import {PoseidonUnit1L, PoseidonUnit2L, PoseidonUnit3L} from "../../contracts/libraries/Poseidon.sol";

/// Holder-rooted credential tree — one key, many documents (SCOPE.md §7.8). Forge port.
contract HolderStateKeeperTest is Test {
    uint256 internal constant TREE = 80;
    bytes32 internal constant ICAO = 0x2c50ce3aa92bc3dd0351a89970b02630415547ea83c487befbc8b1795ea90c45;

    bytes32 internal constant HOLDER = bytes32(uint256(0x1111));
    bytes32 internal constant HOLDER2 = bytes32(uint256(0x2222));
    bytes32 internal constant DOC_A = bytes32(uint256(0x0a0a));
    bytes32 internal constant DOC_B = bytes32(uint256(0x0b0b));
    bytes32 internal constant DOC_C = bytes32(uint256(0x0c0c));
    uint256 internal constant DG_A = 111;
    uint256 internal constant DG_B = 222;
    uint256 internal constant DG_C = 333;

    // DocStatus
    uint8 internal constant CURRENT = 1;
    uint8 internal constant SUPERSEDED = 2;
    uint8 internal constant REVOKED = 3;

    address internal OWNER = address(0xA11CE);
    address internal REG = address(0xBEEF); // acts as the registration contract

    HolderStateKeeperMock internal sk;
    PoseidonSMTMock internal smt;
    bytes32 internal DOC_PASSPORT;
    bytes32 internal DOC_NATIONAL_ID;

    function setUp() public {
        smt = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        PoseidonSMTMock certs = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        sk = HolderStateKeeperMock(_proxy(address(new HolderStateKeeperMock())));

        // Real minimal evidence registry (the PoseidonSMT only calls addStatement on root
        // commits). Rarimo's EvidenceRegistry uses a Poseidon-isolated key that Forge's
        // auto-linker leaves unlinked → 0 → false collisions; this keccak-isolated registry has
        // identical per-(sender,root) dedup semantics. Contracts UNDER TEST are unmodified.
        TestEvidenceRegistry reg = new TestEvidenceRegistry();

        smt.__PoseidonSMT_init(address(sk), address(reg), TREE);
        certs.__PoseidonSMT_init(address(sk), address(reg), TREE);

        sk.__StateKeeper_init(OWNER, address(smt), address(certs), ICAO);

        string[] memory keys = new string[](1);
        keys[0] = "holder-reg";
        address[] memory vals = new address[](1);
        vals[0] = REG;
        sk.mockAddRegistrations(keys, vals);

        DOC_PASSPORT = sk.DOC_PASSPORT();
        DOC_NATIONAL_ID = sk.DOC_NATIONAL_ID();
    }

    function _proxy(address impl) internal returns (address) {
        return address(new UnsafeTestProxy(impl));
    }

    function _leafIndex(bytes32 documentKey, bytes32 holderRoot) internal pure returns (bytes32) {
        return bytes32(PoseidonUnit2L.poseidon([uint256(documentKey), uint256(holderRoot)]));
    }

    // ── the old 1:1 binding is disabled ────────────────────────────────────────────────────

    function test_addBond_disabled() public {
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: use addDocument (holder tree)");
        sk.addBond(DOC_A, bytes32(0), HOLDER, 0);
    }

    function test_writes_gated_to_registrations() public {
        vm.expectRevert("StateKeeper: not a registration");
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
    }

    // ── many documents, one holder ─────────────────────────────────────────────────────────

    function test_many_documents_one_holder() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.addDocument(DOC_B, bytes32(0), HOLDER, DOC_NATIONAL_ID, DG_B, 0);
        vm.stopPrank();

        assertEq(sk.getActiveDocumentCount(HOLDER), 2, "two current docs under one holder");

        bytes32[] memory docs = sk.getHolderDocuments(HOLDER);
        assertEq(docs.length, 2);
        assertEq(docs[0], DOC_A);
        assertEq(docs[1], DOC_B);

        HolderStateKeeper.DocumentBond memory a = sk.getDocument(DOC_A);
        // The bond stores Poseidon(holderRoot), never the value (sec. 2.18bi).
        assertEq(a.holderRootCommitment, bytes32(PoseidonUnit1L.poseidon([uint256(HOLDER)])));
        assertEq(a.docType, DOC_PASSPORT);
        assertEq(uint8(a.status), CURRENT);

        assertTrue(smt.getProof(_leafIndex(DOC_A, HOLDER)).existence);
        assertTrue(smt.getProof(_leafIndex(DOC_B, HOLDER)).existence);
    }

    function test_no_double_bind() public {
        vm.prank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: document bound");
        sk.addDocument(DOC_A, bytes32(0), HOLDER2, DOC_PASSPORT, DG_A, 0);
    }

    function test_document_hash_anti_replay() public {
        bytes32 h = bytes32(uint256(0xeeee));
        vm.prank(REG);
        sk.addDocument(DOC_A, h, HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: document hash used");
        sk.addDocument(DOC_B, h, HOLDER, DOC_PASSPORT, DG_B, 0);
    }

    // ── renewal preserves the holder root ──────────────────────────────────────────────────

    function test_renewal_supersedes_and_preserves_root() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.addDocument(DOC_B, bytes32(0), HOLDER, DOC_NATIONAL_ID, DG_B, 0);

        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER, DOC_PASSPORT, DG_C, 0);
        vm.stopPrank();

        assertEq(uint8(sk.getDocument(DOC_A).status), SUPERSEDED);
        HolderStateKeeper.DocumentBond memory c = sk.getDocument(DOC_C);
        assertEq(uint8(c.status), CURRENT);
        assertEq(
            c.holderRootCommitment,
            bytes32(PoseidonUnit1L.poseidon([uint256(HOLDER)])),
            "continuity: same root"
        );
        assertEq(c.seq, 1, "next sequence");
        assertEq(sk.getActiveDocumentCount(HOLDER), 2); // B + C
    }

    function test_renew_rejects_non_current() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER, DOC_PASSPORT, DG_C, 0);
        vm.expectRevert("HolderStateKeeper: old not current");
        sk.renewDocument(DOC_A, DOC_B, bytes32(0), HOLDER, DOC_PASSPORT, DG_B, 0);
        vm.stopPrank();
    }

    function test_renew_rejects_wrong_holder() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.expectRevert("HolderStateKeeper: holder mismatch");
        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER2, DOC_PASSPORT, DG_C, 0);
        vm.stopPrank();
    }

    // ── revocation ─────────────────────────────────────────────────────────────────────────

    function test_revoke() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.revokeDocument(DOC_A, HOLDER);
        vm.stopPrank();

        assertEq(uint8(sk.getDocument(DOC_A).status), REVOKED);
        assertEq(sk.getActiveDocumentCount(HOLDER), 0);
    }

    function test_cannot_revoke_twice() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.revokeDocument(DOC_A, HOLDER);
        vm.expectRevert("HolderStateKeeper: not current");
        sk.revokeDocument(DOC_A, HOLDER);
        vm.stopPrank();
    }

    function test_non_membership_of_unregistered() public {
        assertFalse(smt.getProof(_leafIndex(DOC_C, HOLDER)).existence);
    }

    // ── EXECUTABLE circuit-compat proof: leaf value == Poseidon3(dgCommit, seq, timestamp) ──
    // This is what query_identity reconstructs; a revoked leaf's value is a marker → the
    // circuit's membership check fails for it (revocation enforced by value-mismatch).

    function test_leaf_value_matches_circuit_reconstruction() public {
        vm.prank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        uint64 ts = uint64(block.timestamp);

        SparseMerkleTree.Proof memory p = smt.getProof(_leafIndex(DOC_A, HOLDER));
        // exactly the value query_identity rebuilds: Poseidon3(dgCommit, seq=0, timestamp)
        bytes32 expected = bytes32(PoseidonUnit3L.poseidon([DG_A, uint256(0), uint256(ts)]));
        assertEq(p.value, expected, "current leaf == Poseidon3(dgCommit, seq, ts)");

        // revoke → leaf value becomes Poseidon1(REVOKED) marker, which can NEVER equal the
        // Poseidon3 reconstruction → the query circuit auto-rejects a revoked document.
        vm.prank(REG);
        sk.revokeDocument(DOC_A, HOLDER);
        SparseMerkleTree.Proof memory p2 = smt.getProof(_leafIndex(DOC_A, HOLDER));
        // Field-reduced (StateKeeper.SNARK_SCALAR_FIELD): keccak256("REVOKED") is > the BN254
        // scalar field order (confirmed: ~5.1x F), so the contract reduces it before hashing -
        // this expected value must match, or a Noir query circuit's own Poseidon(REVOKED as
        // Field) (always implicitly reduced - a Noir Field literal can't represent an
        // out-of-field value) would silently disagree with an unreduced marker here.
        bytes32 revokedMarker = bytes32(
            PoseidonUnit1L.poseidon([
                uint256(keccak256("REVOKED")) %
                    21888242871839275222246405745257275088548364400416034343698204186575808495617
            ])
        );
        assertEq(p2.value, revokedMarker, "revoked leaf == Poseidon1(REVOKED mod F) marker");
        assertTrue(p2.value != expected, "marker can't match circuit reconstruction");
    }

  /*
   * A SEIZED DOCUMENT CANNOT BE RESOLVED TO ITS OWNER (sec. 2.18bi).
   *
   * `documentKey` IS computable by anyone holding the physical document - it is the passport public
   * key, or the proof's `passportHash`, both readable from the chip. So `_documents[documentKey]` is
   * readable by that person via `eth_getStorageAt` no matter what Solidity visibility claims, and
   * hiding the getter would be theatre. The fix is that the VALUE IS NOT THERE: the bond stores
   * `Poseidon(holderRoot)`.
   *
   * WHY THIS MATTERS MORE THAN ONE DOCUMENT. Blacklisting acts on the IDENTITY (sec. 2.18be), so
   * `holderRoot` names the unit sanctions apply to - and it is the handle that enumerates every
   * OTHER document the same person holds. For a multi-citizenship holder, whose second passport is
   * the way out, that is the whole secret.
   *
   * This test is written so it would FAIL against the old plaintext field: it asserts the stored
   * value is NOT the holder root, and IS the commitment.
   */
  function test_aSeizedDocumentDoesNotRevealItsHoldersIdentity() public {
    vm.prank(REG);
    sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);

    HolderStateKeeper.DocumentBond memory bond = sk.getDocument(DOC_A);

    assertTrue(
      bond.holderRootCommitment != HOLDER,
      'the bond still exposes the holder root in plaintext'
    );
    assertEq(
      bond.holderRootCommitment,
      bytes32(PoseidonUnit1L.poseidon([uint256(HOLDER)])),
      'the bond does not store the expected commitment'
    );
  }

  /// And the commitment is BINDING, not decorative: revoking with the wrong holder must revert, or
  /// passing the identity as a parameter would be an unchecked assertion by the caller.
  function test_revokingWithTheWrongHolderIsRejected() public {
    vm.prank(REG);
    sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);

    vm.prank(REG);
    vm.expectRevert(bytes('HolderStateKeeper: holder mismatch'));
    sk.revokeDocument(DOC_A, bytes32(uint256(0xBAD)));
  }

  /*
   * THE DOCUMENT-KEYED LEAK IS BOUNDED TO ONE BIT (sec. 2.18bg).
   *
   * `dg1Hash` is computable by anyone who handles the document - BAC needs only the MRZ printed on
   * the page - so ANY value stored under it is readable by that person via `eth_getStorageAt`,
   * regardless of Solidity visibility. There used to be a `_holderOfDocumentHash` mapping to
   * `holderRoot`, which made a seized passport a one-call lookup to its owner's ENTIRE document set;
   * it was already vestigial (the soundness moved into the registrationSmt leaf value) and is now
   * deleted.
   *
   * This test pins the property so it cannot come back by accident: the state keeper must expose NO
   * function that maps a document hash to a holder. It is written against the ABI rather than the
   * source, because a future getter with a different name would defeat a grep.
   */
  function test_noPublicFunctionMapsADocumentHashToItsHolder() public view {
    // Any such getter takes a bytes32 and returns a bytes32. Probe the two names that existed or
    // would be natural, and require both to be absent from the deployed contract.
    string[2] memory gone = ['holderOfDocumentHash(bytes32)', 'holderOf(bytes32)'];

    for (uint256 i = 0; i < gone.length; ++i) {
      (bool ok,) = address(sk).staticcall(
        abi.encodeWithSelector(bytes4(keccak256(bytes(gone[i]))), bytes32(uint256(0xD0C)))
      );
      assertFalse(ok, string.concat('a document-hash-to-holder getter is reachable: ', gone[i]));
    }
  }

  /// And the anti-replay bool still WORKS - privacy must not have been bought by dropping the guard
  /// that stops one physical passport binding to two identities, which is what defeats an
  /// identity-level blacklist by construction.
  function test_theAntiReplayGuardStillRejectsAReusedDocumentHash() public {
    bytes32 dg1 = keccak256('a-real-document');

    // `documentHash_` is the SECOND parameter - the dg1Hash the guard keys on. Existing tests pass
    // bytes32(0) there, which SKIPS the anti-replay path entirely, so a test that copied them would
    // have asserted nothing.
    vm.prank(REG);
    sk.addDocument(keccak256('doc-1'), dg1, HOLDER, DOC_PASSPORT, DG_A, 0);

    vm.prank(REG);
    vm.expectRevert(bytes('HolderStateKeeper: document hash used'));
    sk.addDocument(keccak256('doc-2'), dg1, keccak256('other-holder'), DOC_PASSPORT, DG_B, 0);
  }

}

/// Minimal, real evidence registry: records each (sender, root) statement once. Same dedup
/// semantics as Rarimo's, keccak-isolated (Poseidon-free) so it links cleanly under Forge.
contract TestEvidenceRegistry {
    mapping(bytes32 => bytes32) public statements;

    error KeyAlreadyExists(bytes32 key);

    function addStatement(bytes32 key_, bytes32 value_) external {
        bytes32 isolated = keccak256(abi.encodePacked(msg.sender, key_));
        if (statements[isolated] != bytes32(0)) revert KeyAlreadyExists(key_);
        statements[isolated] = value_;
    }
}
