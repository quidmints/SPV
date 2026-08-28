// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {PoseidonUnit1L} from '../../contracts/libraries/Poseidon.sol';

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// OZ 5.6.1 hardened ERC1967Proxy to revert on empty init data (front-run/MITM protection for
/// real deployments). This suite deploys-then-initializes in two separate calls (matching
/// StateKeeper/PoseidonSMT/RegistrationSimple's own __xxx_init(...) external initializer
/// pattern) — safe in a single-threaded test, so this test-only proxy opts back into that
/// behavior.
contract UnsafeTestProxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

import {HolderRegistration} from "../../contracts/holder/HolderRegistration.sol";
import {HolderStateKeeper} from "../../contracts/holder/HolderStateKeeper.sol";
import {HolderStateKeeperMock} from "../../contracts/mock/holder/HolderStateKeeperMock.sol";
import {PoseidonSMTMock} from "../../contracts/mock/state/PoseidonSMTMock.sol";
import {NoirVerifierMock} from "../../contracts/mock/verifiers/NoirVerifierMock.sol";
import {RegistrationSimple} from "../../contracts/registration/RegistrationSimple.sol";

/// HolderRegistration's real entry points (registerDocumentViaNoir / renewDocumentViaNoir /
/// revokeDocumentViaSigner) - previously zero coverage. HolderStateKeeper.t.sol exercises
/// HolderStateKeeper directly (bypassing signature/proof verification entirely, with the state
/// keeper's registration gate opened to a plain EOA); this file drives the SAME state keeper
/// through the real registration contract, so the signature-recovery, replay-protection, and
/// Noir-proof-gating logic actually gets exercised, not just the state-transition logic.
contract HolderRegistrationTest is Test {
  /// A REAL profile's key, not an arbitrary bytes32: `registerDocumentViaIcao` now takes a zkType
  /// SELECTOR, and using the genuine one keeps these tests honest about what the caller supplies.
  bytes32 internal constant ZK_TYPE_TD1 = keccak256("Z_NOIR_PASSPORT_25_384_1_3_336_256_NA");

  /// Read ONCE, never inside a test that pranks. `DOC_NATIONAL_ID` is an external call and
  /// would consume a single-shot `vm.prank` before the call under test ever runs - the same trap
  /// TitleLedger.t.sol documents for role constants. Two tests failed with "did not revert as
  /// expected" for exactly this reason before it was hoisted.
  bytes32 internal DOC_NATIONAL_ID;

    bytes32 internal constant ICAO = 0x2c50ce3aa92bc3dd0351a89970b02630415547ea83c487befbc8b1795ea90c45;
    uint256 internal constant TREE = 80;

    address internal OWNER = address(0xA11CE);

    uint256 internal SIGNER_PK = 0xBEEF01;
    address internal SIGNER;

    uint256 internal OTHER_PK = 0xBEEF02; // a real key, but NOT registered as a signer
    address internal OTHER;

    HolderRegistration internal reg;
    HolderStateKeeperMock internal sk;
    NoirVerifierMock internal verifier;

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        OTHER = vm.addr(OTHER_PK);

        PoseidonSMTMock smt = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        PoseidonSMTMock certs = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        sk = HolderStateKeeperMock(_proxy(address(new HolderStateKeeperMock())));

        TestEvidenceRegistry evidenceRegistry = new TestEvidenceRegistry();
        smt.__PoseidonSMT_init(address(sk), address(evidenceRegistry), TREE);
        certs.__PoseidonSMT_init(address(sk), address(evidenceRegistry), TREE);
        sk.__StateKeeper_init(OWNER, address(smt), address(certs), ICAO);
        DOC_NATIONAL_ID = sk.DOC_NATIONAL_ID();

        reg = HolderRegistration(_proxy(address(new HolderRegistration())));
        address[] memory signers = new address[](1);
        signers[0] = SIGNER;
        reg.__RegistrationSimple_init(address(sk), signers);

        string[] memory keys = new string[](1);
        keys[0] = "holder-reg";
        address[] memory vals = new address[](1);
        vals[0] = address(reg);
        sk.mockAddRegistrations(keys, vals);

        verifier = new NoirVerifierMock();
    }

    function _proxy(address impl) internal returns (address) {
        return address(new UnsafeTestProxy(impl));
    }

    function _passport(
        uint256 dgCommit,
        bytes32 dg1Hash,
        bytes32 publicKey,
        bytes32 passportHash
    ) internal view returns (RegistrationSimple.Passport memory) {
        return
            RegistrationSimple.Passport({
                dgCommit: dgCommit,
                dg1Hash: dg1Hash,
                publicKey: publicKey,
                passportHash: passportHash,
                verifier: address(verifier)
            });
    }

    function _signedData(RegistrationSimple.Passport memory p) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    reg.REGISTRATION_SIMPLE_PREFIX(),
                    address(reg),
                    p.passportHash,
                    p.dgCommit,
                    p.publicKey,
                    p.verifier
                )
            );
    }

    function _sign(uint256 pk, RegistrationSimple.Passport memory p) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(_signedData(p));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Revocation's domain-separated message (HolderRegistration._buildRevokeSignedData) - MUST
    // differ from _signedData's registration message, or a deterministic signer would produce the
    // same signature for both, which useSignature's anti-replay check would then reject as
    // already-used (see HolderRegistration.revokeDocumentViaSigner's own doc comment).
    function _revokeSignedData(RegistrationSimple.Passport memory p) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "HolderRegistration revoke prefix",
                    address(reg),
                    p.passportHash,
                    p.dgCommit,
                    p.publicKey,
                    p.verifier
                )
            );
    }

    function _signRevoke(uint256 pk, RegistrationSimple.Passport memory p) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(_revokeSignedData(p));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /*
     * ── THE ENROLMENT GATE, PINNED (sec. 2.18g) ──────────────────────────────────────
     *
     * EVERY path into the holder tree on this contract requires a BACKEND SIGNER'S SIGNATURE, so
     * enrolment can be withheld by whoever holds that key. That contradicts the property the
     * identity registry downstream is built to provide - `IdentityRegistry.register` is
     * permissionless, but it is unreachable for anyone who cannot first get a document bound here.
     *
     * THIS TEST EXISTS TO STOP THAT BEING FORGOTTEN. It asserts the CURRENT behaviour, which is the
     * defect, so the gate is visible in the suite rather than only in a design note. When the
     * permissionless path lands (an ICAO-verifying registration writing via `addDocument`, the
     * machinery `Registration2` already has), this test should FAIL for the renamed reason and be
     * rewritten to assert that a user with NO signature can still enrol. A green suite must not be
     * able to coexist with both states.
     *
     * The proof is genuine in every case below; only the signature is absent or wrong.
     */
    function test_EnrolmentIsGatedByABackendSigner() public {
        RegistrationSimple.Passport memory p =
            _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));

        // A signature from a key that is not a registered signer - i.e. any user acting alone.
        uint256 strangerPk = 0xDEAD01;
        assertTrue(vm.addr(strangerPk) != SIGNER, 'the stranger must not be the signer');
        bytes memory strangerSig = _sign(strangerPk, p);
        bytes32 docType = sk.DOC_PASSPORT();

        vm.expectRevert(bytes('HolderRegistration: caller is not a signer'));
        reg.registerDocumentViaNoir(1, p, docType, 0, strangerSig, '');

        // And the document is not bound, so nothing downstream can proceed: escrow requires an
        // inclusion proof of this leaf, and IdentityRegistry.register requires that escrow.
        assertEq(uint8(sk.getDocument(p.publicKey).status), 0, 'DocStatus.None expected');
    }

    /// The same gate on renewal, so a holder cannot refresh an expiring document unaided either.
    function test_RenewalIsGatedByTheSameSigner() public {
        RegistrationSimple.Passport memory p1 =
            _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes32 docType = sk.DOC_PASSPORT();
        reg.registerDocumentViaNoir(1, p1, docType, 0, _sign(SIGNER_PK, p1), '');

        RegistrationSimple.Passport memory p2 =
            _passport(222, bytes32(uint256(2)), bytes32(uint256(0xB0B0)), bytes32(0));
        bytes memory strangerSig = _sign(0xDEAD01, p2);

        vm.expectRevert(bytes('HolderRegistration: caller is not a signer'));
        reg.renewDocumentViaNoir(p1.publicKey, 1, p2, docType, 0, strangerSig, '');
    }

    /*
     * ── THE PERMISSIONLESS PATH (sec. 2.18n) ──────────────────────────────────────────
     *
     * WHY EVERY TEST HERE IS A NEGATIVE ONE, and why that is the right way round.
     *
     * The happy path needs a `register_identity` proof, which needs a SOD signed by a DSC whose key
     * is genuinely in the ICAO chain. We hold no such key and never will, and we do NOT fake the
     * root - a fake root is one setter call from production and the failure it causes (forged
     * documents admitted as genuine) is silent and total. So the positive case waits for a real
     * document, in milestone 3.
     *
     * The GUARDS, however, are testable today, and they are the half that protects users. That is
     * only true because `registerDocumentViaIcao` checks the certificates root BEFORE verifying the
     * proof: these tests hand it arbitrary bytes and assert it reverts on the root, never reaching
     * the verifier. Order those two the other way and none of this could be written until a real
     * passport existed.
     */
    function _icaoInputs() internal pure returns (bytes32[] memory inputs_) {
        inputs_ = new bytes32[](7);
        inputs_[0] = bytes32(uint256(0xD6C5)); // dg15PkHash
        inputs_[1] = bytes32(uint256(0xDEED)); // passportHash -> documentKey
        inputs_[2] = bytes32(uint256(0xC0)); // dgCommit
        inputs_[3] = bytes32(uint256(0xA11CE)); // holderRoot
        inputs_[4] = bytes32(uint256(0xBAD0)); // icaoRoot - not a root the keeper knows
        inputs_[5] = bytes32(uint256(0xD61)); // dg1Hash
        // expiry: six packed ASCII digits, "300101" = 2030-01-01. A well-formed date, because these
        // tests assert the ROOT is rejected first - a malformed one would revert in the date parse
        // and hide the ordering this file exists to pin.
        inputs_[6] = bytes32(uint256(0x333030313031));
    }

    /// THE property test. A root `certificatesSmt` never held must be refused, and refused BEFORE
    /// the proof is looked at - which is what lets this run with no valid proof in existence.
    function test_icao_revertsOnACertificatesRootTheKeeperNeverHeld() public {
        reg.setIcaoRegistrationVerifier(ZK_TYPE_TD1, address(0xBEEF), DOC_NATIONAL_ID);
        bytes32[] memory inputs = _icaoInputs();

        vm.expectRevert(bytes("HolderRegistration: unknown certificates root"));
        reg.registerDocumentViaIcao(ZK_TYPE_TD1, inputs, hex"1234");
    }

    /// It reverts on the root even when the verifier is unset, proving the ordering directly: an
    /// unset verifier would revert too, and this shows which check fires first.
    function test_icao_theRootIsCheckedBeforeTheVerifier() public {
        bytes32[] memory inputs = _icaoInputs();
        assertEq(reg.icaoRegistrationVerifiers(ZK_TYPE_TD1), address(0), "precondition: verifier unset");

        vm.expectRevert(bytes("HolderRegistration: unknown certificates root"));
        reg.registerDocumentViaIcao(ZK_TYPE_TD1, inputs, hex"1234");
    }

    function test_icao_revertsOnWrongPublicInputCount() public {
        bytes32[] memory short_ = new bytes32[](5);

        vm.expectRevert(bytes("HolderRegistration: wrong public input count"));
        reg.registerDocumentViaIcao(ZK_TYPE_TD1, short_, hex"1234");
    }

    /*
     * THE VERIFIER IS PINNED, NOT CALLER-SUPPLIED - the hole that removing the signature creates.
     *
     * `registerDocumentViaNoir` reads `passport_.verifier` from its caller, which is safe ONLY
     * because the backend signature covers the whole struct including that field. With no signature
     * a caller-supplied verifier would let anyone pass a contract whose `verify` returns true and
     * register any identity at all. So the address lives in storage, owner-set.
     */
    function test_icao_theVerifierCannotBeChosenByTheCaller() public view {
        // There is no argument for it and no setter reachable by a stranger; the only way in is
        // `setIcaoRegistrationVerifier`, which is owner-gated. Asserting the shape of the ABI is the
        // point: a `verifier` parameter appearing here later would be the regression.
        assertEq(reg.icaoRegistrationVerifiers(ZK_TYPE_TD1), address(0));
    }

    function test_icao_onlyTheOwnerCanSetTheVerifier() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        reg.setIcaoRegistrationVerifier(ZK_TYPE_TD1, address(0xBEEF), DOC_NATIONAL_ID);
    }

    /// THE POINT OF THE MAPPING: more than one document class on the signer-free path.
  ///
  /// Four TD1 profiles are live. With a single `icaoRegistrationVerifier` address only one of them
  /// could ever use this path; every other holder fell back to the signer-gated one, which is the
  /// trust root being removed. "Signer-free for one algorithm" is not signer-free.
  function test_icao_distinctProfilesBindDistinctVerifiers() public {
    bytes32 other = keccak256("Z_NOIR_PASSPORT_1_256_1_5_2376_336_1_2120_4_512");

    vm.prank(OWNER);
    reg.setIcaoRegistrationVerifier(ZK_TYPE_TD1, address(0xBEEF), DOC_NATIONAL_ID);
    vm.prank(OWNER);
    reg.setIcaoRegistrationVerifier(other, address(0xCAFE), DOC_NATIONAL_ID);

    assertEq(reg.icaoRegistrationVerifiers(ZK_TYPE_TD1), address(0xBEEF), "first profile");
    assertEq(reg.icaoRegistrationVerifiers(other), address(0xCAFE), "second profile");

    // An unregistered selector still resolves to zero, so widening WHICH documents are accepted
    // does not widen WHO decides what verifies them.
    assertEq(
      reg.icaoRegistrationVerifiers(keccak256("Z_NOIR_PASSPORT_not_a_profile")),
      address(0),
      "an unregistered zkType must not resolve"
    );
  }

  function test_icao_theVerifierCannotBeSetToZero() public {
        vm.expectRevert(bytes("HolderRegistration: zero verifier"));
        reg.setIcaoRegistrationVerifier(ZK_TYPE_TD1, address(0), DOC_NATIONAL_ID);
    }

    // ── registerDocumentViaNoir ────────────────────────────────────────────────────────────

    function test_registerDocumentViaNoir_succeeds() public {
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes memory sig = _sign(SIGNER_PK, p);

        reg.registerDocumentViaNoir(uint256(uint160(address(0xF00D))), p, sk.DOC_PASSPORT(), 0, sig, "");

        HolderStateKeeper.DocumentBond memory bond = sk.getDocument(p.publicKey);
        // The bond stores Poseidon(holderRoot), never the value (sec. 2.18bi) - so a seized
        // passport, whose documentKey anyone holding it can compute, cannot be resolved to its
        // owner's identity. Asserting the COMMITMENT is what pins that.
        assertEq(
            bond.holderRootCommitment,
            bytes32(PoseidonUnit1L.poseidon([uint256(uint160(address(0xF00D)))]))
        );
        assertEq(bond.docType, sk.DOC_PASSPORT());
        assertEq(uint8(bond.status), 1); // Current
    }

    function test_registerDocumentViaNoir_revertsOnZeroHolderRoot() public {
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes memory sig = _sign(SIGNER_PK, p);
        // sk.DOC_PASSPORT() is itself an external call - reading it inline as an argument below
        // would consume the single-shot vm.expectRevert before registerDocumentViaNoir executes.
        bytes32 docPassport = sk.DOC_PASSPORT();

        vm.expectRevert("HolderRegistration: holder can not be zero");
        reg.registerDocumentViaNoir(0, p, docPassport, 0, sig, "");
    }

    function test_registerDocumentViaNoir_revertsOnWrongSigner() public {
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes memory sig = _sign(OTHER_PK, p); // OTHER is not a registered signer
        bytes32 docPassport = sk.DOC_PASSPORT();

        vm.expectRevert("HolderRegistration: caller is not a signer");
        reg.registerDocumentViaNoir(1, p, docPassport, 0, sig, "");
    }

    function test_registerDocumentViaNoir_revertsOnReplayedSignature() public {
        RegistrationSimple.Passport memory p1 = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes memory sig = _sign(SIGNER_PK, p1);
        bytes32 docPassport = sk.DOC_PASSPORT();
        reg.registerDocumentViaNoir(1, p1, docPassport, 0, sig, "");

        // Same exact (passport, signature) replayed for a second registration attempt.
        RegistrationSimple.Passport memory p2 = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xB0B0)), bytes32(0));
        vm.expectRevert("StateKeeper: signature used");
        reg.registerDocumentViaNoir(1, p1, docPassport, 0, sig, "");
        // sanity: a genuinely different passport+signature still works fine afterwards
        reg.registerDocumentViaNoir(1, p2, docPassport, 0, _sign(SIGNER_PK, p2), "");
    }

    function test_registerDocumentViaNoir_revertsOnInvalidZkProof() public {
        verifier.setShouldVerify(false);
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        bytes memory sig = _sign(SIGNER_PK, p);
        bytes32 docPassport = sk.DOC_PASSPORT();

        vm.expectRevert("RegistrationSimple: invalid noir zk proof");
        reg.registerDocumentViaNoir(1, p, docPassport, 0, sig, "");
    }

    function test_multiCitizenship_twoDocumentsOneHolder() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        RegistrationSimple.Passport memory p1 = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        RegistrationSimple.Passport memory p2 = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xB0B0)), bytes32(0));

        reg.registerDocumentViaNoir(holderRoot, p1, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p1), "");
        reg.registerDocumentViaNoir(holderRoot, p2, DOC_NATIONAL_ID, 0, _sign(SIGNER_PK, p2), "");

        assertEq(sk.getActiveDocumentCount(bytes32(holderRoot)), 2);
    }

    // ── document re-homing: one passport may bind to exactly ONE holder root ────────────────
    //
    // THE ATTACK these cover. The Noir proof binds only `dgCommit`, `dg1Hash` and `holderRoot`
    // (RegistrationSimple._verifyNoirZKProof's three public signals). `publicKey` and
    // `passportHash` are caller-supplied struct fields attested ONLY by the backend signer, so a
    // caller able to obtain a signature could present a fresh pair for the SAME physical passport
    // and bind it under a SECOND identity. That defeats ANY identity-level blacklist by
    // construction: get listed, re-register, withdraw as someone new.
    //
    // The guard that stops it is the state keeper's `_usedDocumentHash`, which was being fed
    // `passportHash` (unconstrained) instead of `dg1Hash` (proof-bound, computed in-circuit over
    // the MRZ, so deterministic for a given passport).

    function test_sameDg1CannotBindToASecondHolderRoot() public {
        bytes32 dg1 = bytes32(uint256(0xDEADBEEF)); // the one value the proof actually pins

        RegistrationSimple.Passport memory p1 = _passport(111, dg1, bytes32(uint256(0xA0A0)), bytes32(uint256(0xAA)));
        reg.registerDocumentViaNoir(uint256(uint160(address(0xF00D))), p1, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p1), "");

        // Same passport, but EVERY field the proof does not constrain is changed: fresh document
        // key, fresh passport hash, fresh dgCommit, different holder root. Without the fix this
        // succeeds and the attacker holds two unlinked identities backed by one passport.
        RegistrationSimple.Passport memory p2 = _passport(999, dg1, bytes32(uint256(0xC0C0)), bytes32(uint256(0xCC)));
        bytes32 docPassport = sk.DOC_PASSPORT();
        bytes memory sig2 = _sign(SIGNER_PK, p2);

        vm.expectRevert("HolderStateKeeper: document hash used");
        reg.registerDocumentViaNoir(uint256(uint160(address(0xBEEF))), p2, docPassport, 0, sig2, "");
    }

    function test_sameDg1CannotRebindEvenToTheSameHolderRoot() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        bytes32 dg1 = bytes32(uint256(0xDEADBEEF));

        RegistrationSimple.Passport memory p1 = _passport(111, dg1, bytes32(uint256(0xA0A0)), bytes32(uint256(0xAA)));
        reg.registerDocumentViaNoir(holderRoot, p1, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p1), "");

        RegistrationSimple.Passport memory p2 = _passport(222, dg1, bytes32(uint256(0xB0B0)), bytes32(uint256(0xBB)));
        bytes32 docPassport = sk.DOC_PASSPORT();
        bytes memory sig2 = _sign(SIGNER_PK, p2);

        vm.expectRevert("HolderStateKeeper: document hash used");
        reg.registerDocumentViaNoir(holderRoot, p2, docPassport, 0, sig2, "");
    }

    /// The complement, and the one that proves the guard actually MOVED rather than merely being
    /// present: a colliding `passportHash` — the field the check used to key on — must no longer
    /// block anything, because it is not what identifies a document.
    function test_collidingPassportHashNoLongerBlocks() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        bytes32 shared = bytes32(uint256(0x5A5A));

        RegistrationSimple.Passport memory p1 = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), shared);
        RegistrationSimple.Passport memory p2 = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xB0B0)), shared);

        reg.registerDocumentViaNoir(holderRoot, p1, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p1), "");
        reg.registerDocumentViaNoir(holderRoot, p2, DOC_NATIONAL_ID, 0, _sign(SIGNER_PK, p2), "");

        assertEq(sk.getActiveDocumentCount(bytes32(holderRoot)), 2);
    }

    /// A zero `dg1Hash` must be refused outright. `addDocument` treats a zero hash as "no
    /// anti-replay wanted" and SKIPS the check, so without this the guard is bypassed by passing
    /// zero.
    function test_zeroDg1HashIsRejected() public {
        RegistrationSimple.Passport memory p = _passport(111, bytes32(0), bytes32(uint256(0xA0A0)), bytes32(uint256(0xAA)));

        bytes32 docPassport = sk.DOC_PASSPORT();
        bytes memory sig = _sign(SIGNER_PK, p);

        vm.expectRevert("HolderRegistration: zero dg1 hash");
        reg.registerDocumentViaNoir(uint256(uint160(address(0xF00D))), p, docPassport, 0, sig, "");
    }

    /// Renewal must stay possible: a renewed passport has a NEW MRZ, hence a new `dg1Hash`, so the
    /// guard does not catch it. If this broke, the fix would have closed the hole by breaking a
    /// legitimate flow.
    function test_renewalStillWorksUnderTheDg1Guard() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));

        RegistrationSimple.Passport memory oldP = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(uint256(0xAA)));
        reg.registerDocumentViaNoir(holderRoot, oldP, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, oldP), "");

        RegistrationSimple.Passport memory newP = _passport(333, bytes32(uint256(3)), bytes32(uint256(0xD0D0)), bytes32(uint256(0xDD)));
        reg.renewDocumentViaNoir(oldP.publicKey, holderRoot, newP, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, newP), "");

        assertEq(
            sk.getDocument(newP.publicKey).holderRootCommitment,
            bytes32(PoseidonUnit1L.poseidon([holderRoot]))
        );
    }

    /// Renewal must ALSO be covered, or the re-homing attack simply moves to renewDocumentViaNoir.
    function test_renewalCannotRebindAnAlreadyUsedDg1() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        bytes32 dg1 = bytes32(uint256(0xDEADBEEF));

        RegistrationSimple.Passport memory p1 = _passport(111, dg1, bytes32(uint256(0xA0A0)), bytes32(uint256(0xAA)));
        reg.registerDocumentViaNoir(holderRoot, p1, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p1), "");

        RegistrationSimple.Passport memory anchor = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xB0B0)), bytes32(uint256(0xBB)));
        reg.registerDocumentViaNoir(holderRoot, anchor, DOC_NATIONAL_ID, 0, _sign(SIGNER_PK, anchor), "");

        RegistrationSimple.Passport memory replay = _passport(444, dg1, bytes32(uint256(0xE0E0)), bytes32(uint256(0xEE)));
        bytes32 docPassport = sk.DOC_PASSPORT();
        bytes memory sigR = _sign(SIGNER_PK, replay);
        bytes32 anchorKey = anchor.publicKey;

        vm.expectRevert("HolderStateKeeper: document hash used");
        reg.renewDocumentViaNoir(anchorKey, holderRoot, replay, docPassport, 0, sigR, "");
    }

    // ── renewDocumentViaNoir ────────────────────────────────────────────────────────────────

    function test_renewDocumentViaNoir_succeeds() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        RegistrationSimple.Passport memory oldP = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        reg.registerDocumentViaNoir(holderRoot, oldP, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, oldP), "");

        RegistrationSimple.Passport memory newP = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xC0C0)), bytes32(0));
        reg.renewDocumentViaNoir(oldP.publicKey, holderRoot, newP, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, newP), "");

        assertEq(uint8(sk.getDocument(oldP.publicKey).status), 2); // Superseded
        HolderStateKeeper.DocumentBond memory freshBond = sk.getDocument(newP.publicKey);
        assertEq(uint8(freshBond.status), 1); // Current
        assertEq(
            freshBond.holderRootCommitment,
            bytes32(PoseidonUnit1L.poseidon([holderRoot])),
            "continuity: same holder root"
        );
    }

    function test_renewDocumentViaNoir_revertsOnZeroHolderRoot() public {
        bytes32 docPassport = sk.DOC_PASSPORT();
        RegistrationSimple.Passport memory oldP = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        reg.registerDocumentViaNoir(1, oldP, docPassport, 0, _sign(SIGNER_PK, oldP), "");

        RegistrationSimple.Passport memory newP = _passport(222, bytes32(uint256(2)), bytes32(uint256(0xC0C0)), bytes32(0));
        // _sign() itself calls reg.REGISTRATION_SIMPLE_PREFIX() internally - another external
        // call that would consume the single-shot expectRevert if evaluated inline as an argument.
        bytes memory newSig = _sign(SIGNER_PK, newP);
        vm.expectRevert("HolderRegistration: holder can not be zero");
        reg.renewDocumentViaNoir(oldP.publicKey, 0, newP, docPassport, 0, newSig, "");
    }

    // ── revokeDocumentViaSigner ─────────────────────────────────────────────────────────────

    function test_revokeDocumentViaSigner_succeeds() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        reg.registerDocumentViaNoir(holderRoot, p, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p), "");

        // revokeDocumentViaSigner needs no ZK proof - just a signer signature over the
        // REVOKE-domain-separated message (_revokeSignedData), distinct from registration's, so
        // this doesn't collide with the signature already consumed at registration time.
        bytes memory revokeSig = _signRevoke(SIGNER_PK, p);
        reg.revokeDocumentViaSigner(p, bytes32(uint256(uint160(address(0xF00D)))), revokeSig);

        assertEq(uint8(sk.getDocument(p.publicKey).status), 3); // Revoked
        assertEq(sk.getActiveDocumentCount(bytes32(holderRoot)), 0);
    }

    function test_revokeDocumentViaSigner_revertsOnWrongSigner() public {
        uint256 holderRoot = uint256(uint160(address(0xF00D)));
        RegistrationSimple.Passport memory p = _passport(111, bytes32(uint256(1)), bytes32(uint256(0xA0A0)), bytes32(0));
        reg.registerDocumentViaNoir(holderRoot, p, sk.DOC_PASSPORT(), 0, _sign(SIGNER_PK, p), "");

        vm.expectRevert("HolderRegistration: caller is not a signer");
        reg.revokeDocumentViaSigner(p, bytes32(uint256(uint160(address(0xF00D)))), _signRevoke(OTHER_PK, p));
    }
}

/// Minimal, real evidence registry (same pattern as HolderStateKeeper.t.sol's) - keccak-isolated
/// per-(sender,key) dedup, sidesteps the real Poseidon-isolated registry's Forge auto-linker
/// issue. Contracts UNDER TEST are unmodified.
contract TestEvidenceRegistry {
    mapping(bytes32 => bytes32) public statements;

    error KeyAlreadyExists(bytes32 key);

    function addStatement(bytes32 key_, bytes32 value_) external {
        bytes32 isolated = keccak256(abi.encodePacked(msg.sender, key_));
        if (statements[isolated] != bytes32(0)) revert KeyAlreadyExists(key_);
        statements[isolated] = value_;
    }
}
