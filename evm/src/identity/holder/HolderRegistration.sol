// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {RegistrationSimple} from "../registration/RegistrationSimple.sol";
import {HolderStateKeeper} from "./HolderStateKeeper.sol";
import {INoirVerifier} from "../interfaces/verifiers/INoirVerifier.sol";
import {PoseidonSMT} from "../state/PoseidonSMT.sol";

/**
 * @title HolderRegistration
 * @notice Registration entry for the holder-rooted tree (SCOPE.md §7.8). Forks
 *         {RegistrationSimple}: reuses its signer set, signed-data format, and Noir proof
 *         verification, but writes to {HolderStateKeeper}'s document model instead of the
 *         upstream 1:1 `addBond`.
 *
 * THE LINK PROOF (renewal continuity) is implicit and cryptographic: both the original and
 * the renewed document carry a Noir proof binding their DG1 to the SAME `holderRoot_`
 * (the identity key lives inside the DG1 commitment — see RegistrationSimple._buildSignedData).
 * So a renewal can only attach a document the holder can actually prove control of, and the
 * holder root is preserved across the swap → scoped pseudonyms / nullifiers / card-state
 * carry over with no re-onboarding.
 *
 * CIRCUIT NOTE: presentation-side (prove "a CURRENT document under MY holder root satisfies a
 * predicate, and is non-revoked/non-superseded") is the forked `query_identity` Noir circuit,
 * not in this repo (§7.5/§7.8).
 */
contract HolderRegistration is RegistrationSimple {
    /// NOT `indexed` on `holderRoot` - see HolderStateKeeper's DocumentAdded (sec. 2.18bc).
    event DocumentRegistered(bytes32 holderRoot, bytes32 documentKey, bytes32 docType);
    event DocumentRenewedVia(bytes32 holderRoot, bytes32 oldDocumentKey, bytes32 newDocumentKey);

    /*
     * ── THE PERMISSIONLESS PATH (sec. 2.18g/2.18l/2.18n) ────────────────────────────────
     *
     * Every OTHER entry point on this contract requires a backend signer's signature, so enrolment
     * can be withheld from one person by whoever holds that key. `registerDocumentViaIcao` takes no
     * signature: it consumes a `register_identity` proof, which verifies the whole ICAO chain
     * in-circuit, and the only thing the caller must satisfy is arithmetic.
     */

    /// Public-input layout of `register_identity`, pinned by its `main` signature. A mismatch here
    /// reads the wrong field while the proof still verifies.
    uint256 internal constant _ICAO_SIGNALS_COUNT = 7;
    uint256 internal constant _ICAO_PUB_DG15_PK_HASH = 0;
    uint256 internal constant _ICAO_PUB_PASSPORT_HASH = 1;
    uint256 internal constant _ICAO_PUB_DG_COMMIT = 2;
    uint256 internal constant _ICAO_PUB_HOLDER_ROOT = 3;
    uint256 internal constant _ICAO_PUB_ICAO_ROOT = 4;
    uint256 internal constant _ICAO_PUB_DG1_HASH = 5;
    uint256 internal constant _ICAO_PUB_EXPIRY = 6;

    /**
     * @notice The ONE verifier accepted on the permissionless path. PINNED, never caller-supplied.
     *
     * THIS IS THE TRAP THAT REMOVING THE SIGNATURE CREATES, and it is easy to miss because the
     * signer path looks like it takes a caller-supplied verifier safely. It does:
     * `registerDocumentViaNoir` reads `passport_.verifier` from the caller, but the backend
     * signature covers the whole `Passport` struct including that field, so the signer is
     * attesting the verifier as much as the data.
     *
     * Delete the signature and that becomes a hole wide enough to drive anything through: a caller
     * would pass their own contract whose `verify` returns true unconditionally, and register any
     * identity they liked. So on this path the verifier is set once, by the owner, and the caller
     * has no say.
     *
     * ────────────────────────────────────────────────────────────────────────────────────────
     * ONE ADDRESS BECAME A MAPPING, AND THE PROPERTY ABOVE IS UNCHANGED (sec. 2.18gz-signer).
     *
     * The caller now supplies a `zkType` SELECTOR, never an address. It resolves only if the owner
     * registered it and reverts otherwise, so a caller still cannot introduce a verifier of their
     * own - which is the entire point of the paragraph above. This is how `Registration2` has always
     * worked: `passport_.zkType` indexes `passportVerifiers`, populated only by the owner.
     *
     * WHY IT HAD TO CHANGE: one address serves ONE document class. There are four live TD1 profiles,
     * and a holder whose ID card is signed with a different algorithm could not use this path at all
     * - they fell back to the signer-gated one, which is the trust root being removed. A
     * single-address ICAO path can only ever mean "signer-free for one algorithm".
     * ────────────────────────────────────────────────────────────────────────────────────────
     */
    mapping(bytes32 => address) public icaoRegistrationVerifiers;

    /**
     * @notice The document type each registered zkType produces. SET BY THE OWNER, never by the
     *         caller, for exactly the reason the verifier is.
     *
     * ⚠️ THIS EXISTS BECAUSE THE PATH WAS MISLABELLING EVERY DOCUMENT IT REGISTERED. `docType` was
     * hardcoded to `DOC_PASSPORT` on the reasoning that "`register_identity` IS the passport
     * circuit" - but the verifier on this path MUST be the TD1 one (see below), and TD1 is the
     * ID-card layout. So national IDs were being recorded as passports. The contradiction sat in
     * two comments in this same file, each correct on its own.
     *
     * A profile knows which it is: the circom name's third field is DOCUMENT_TYPE, 1 for TD1 and 3
     * for TD3, and it is recorded per profile in `passport-profiles.json`. Since the owner already
     * chooses which verifier a zkType resolves to, it records the document type in the same call -
     * the caller gains no say, which is the property the paragraph below protects.
     */
    mapping(bytes32 => bytes32) public icaoDocTypes;

    event IcaoRegistrationVerifierSet(bytes32 indexed zkType, address verifier, bytes32 docType);

    function setIcaoRegistrationVerifier(
        bytes32 zkType_,
        address verifier_,
        bytes32 docType_
    ) external {
        _onlyOwner();
        require(verifier_ != address(0), "HolderRegistration: zero verifier");
        require(docType_ != bytes32(0), "HolderRegistration: zero doc type");
        icaoRegistrationVerifiers[zkType_] = verifier_;
        icaoDocTypes[zkType_] = docType_;

        emit IcaoRegistrationVerifierSet(zkType_, verifier_, docType_);
    }

    /**
     * @notice Register a document with NO signature, against the ICAO chain proven in-circuit.
     * @param zkType_ selects an OWNER-REGISTERED verifier; it is not an address and cannot be one.
     * @param publicInputs_ `register_identity`'s six public outputs, in circuit order.
     * @param zkPoints_ the Honk proof.
     *
     * WHAT THE CALLER DOES NOT GET TO CHOOSE, and why each one matters:
     *
     * - **the verifier** - see `icaoRegistrationVerifiers`. The caller picks a zkType SELECTOR;
     *   an unregistered one reverts, so it can never introduce a verifier of its own.
     * - **`documentKey`** - taken from the proof's `passportHash`, not from an argument. The signer
     *   path uses `passport_.publicKey`, a caller-supplied field; here it is proof-bound, which is
     *   strictly better and costs nothing.
     * - **the anti-replay key** - `dg1Hash`, the same value `_replayKey` uses on the signer path.
     *   sec. 2.18i added that output to the circuit precisely so the two paths cannot key on
     *   different values and let one passport bind twice under two holder roots.
     * - **`docType`** - taken from `icaoDocTypes[zkType_]`, recorded by the OWNER when the verifier
     *   was registered. A caller-supplied type would let someone label a passport a national ID for
     *   free; a hardcoded one mislabelled every TD1 document as a passport, which is what it used
     *   to do.
     * - **`notAfter`** - DERIVED FROM THE PROOF, no longer fixed to 0 (sec. 2.18gz-nocontroller).
     *   The circuit emits the MRZ expiry, which the issuing state stated and signed into the SOD, so
     *   it is established rather than claimed. It used to be 0 because `register_identity` did not
     *   attest one - true of that circuit, false of the codebase, since `query.nr` had read the field
     *   all along. Every document that expires on its own terms is one fewer needing an authority to
     *   revoke it.
     *
     * ────────────────────────────────────────────────────────────────────────────────────────
     * THE VERIFIER MUST BE THE TD1 ONE (sec. 2.18j / 2.18z / 2.18ac).
     *
     * `register_identity` is TD3 - a passport booklet, DG1 of 93 bytes - while `escrow_envelope`
     * computes `dgCommit` over **95**, the TD1 / ID-card layout the live signer path and the
     * wallet's upstream circuits use. Pointing this function at the 93-byte circuit produces
     * `registrationSmt` leaves escrow can NEVER reproduce, so the documents it registers could
     * never obtain a pool identity - correct-looking and inert.
     *
     * `register_identity_td1` exists for that reason and is what every zkType registered in
     * `icaoRegistrationVerifiers` must point at. Its `dg1Hash` AND its `dgCommit` are proven to agree with `register_identity_light` at
     * 95 bytes, which is exactly the agreement escrow depends on.
     * ────────────────────────────────────────────────────────────────────────────────────────
     *
     * THE ROOT IS CHECKED BEFORE THE PROOF IS VERIFIED, deliberately (sec. 2.18k). Two reasons.
     * A Honk verification costs hundreds of thousands of gas and a root lookup is one call, so the
     * cheap check goes first. And more importantly it is what makes the guard TESTABLE AT ALL
     * before a real document exists: the negative test hands this function arbitrary bytes with a
     * wrong root and asserts it reverts on the root, never reaching the verifier.
     */
    function registerDocumentViaIcao(
        bytes32 zkType_,
        bytes32[] calldata publicInputs_,
        bytes calldata zkPoints_
    ) external virtual {
        require(
            publicInputs_.length == _ICAO_SIGNALS_COUNT,
            "HolderRegistration: wrong public input count"
        );

        /*
         * THE ENTIRE SECURITY OF THIS PATH IS THIS CHECK (sec. 2.18k).
         *
         * `register_identity` proves the document's signer key is in a tree with the root the
         * PROVER supplied. That is vacuous on its own - rarime's own witness generator builds a
         * ONE-LEAF tree holding the very key being registered, and the circuit accepts it by
         * construction. Anyone can generate a keypair, sign a fabricated SOD over a fabricated
         * MRZ, and produce a completely valid proof.
         *
         * What makes it mean something is that the root must be one `certificatesSmt` actually
         * holds - a tree whose every leaf arrived through `Registration2.registerCertificate`,
         * which proves a CSCA is in the ICAO master list and verifies that CSCA's signature over
         * the DSC. Without this line the proof shows only that the prover can sign their own
         * documents.
         *
         * NOTE THE TREE: `certificatesSmt`, NOT `icaoMasterTreeMerkleRoot`. The circuit parameter
         * is named `icao_root` and the master root is a DIFFERENT structure - a keccak tree of CSCA
         * keys, consumed only when admitting a DSC. Comparing against it would reject every genuine
         * proof while looking principled (sec. 2.18l).
         */
        require(
            PoseidonSMT(address(stateKeeper.certificatesSmt())).isRootValid(
                publicInputs_[_ICAO_PUB_ICAO_ROOT]
            ),
            "HolderRegistration: unknown certificates root"
        );

        // The caller CHOOSES among owner-registered verifiers; it cannot supply one. An unregistered
        // zkType resolves to zero and reverts here, so the selector widens which documents this path
        // accepts without widening who decides what verifies them.
        address verifier_ = icaoRegistrationVerifiers[zkType_];
        require(verifier_ != address(0), "HolderRegistration: icao verifier not set");
        require(
            INoirVerifier(verifier_).verify(zkPoints_, publicInputs_),
            "HolderRegistration: invalid icao zk proof"
        );

        bytes32 holderRoot_ = publicInputs_[_ICAO_PUB_HOLDER_ROOT];
        require(holderRoot_ != bytes32(0), "HolderRegistration: holder can not be zero");

        bytes32 dg1Hash_ = publicInputs_[_ICAO_PUB_DG1_HASH];
        require(dg1Hash_ != bytes32(0), "HolderRegistration: zero dg1 hash");

        bytes32 documentKey_ = publicInputs_[_ICAO_PUB_PASSPORT_HASH];

        // The OWNER's recorded type for this zkType, not a constant and not the caller's word. A TD1
        // profile registers a national ID; a TD3 profile registers a passport.
        bytes32 docType_ = icaoDocTypes[zkType_];
        uint64 notAfter_ = _mrzDateToTimestamp(uint256(publicInputs_[_ICAO_PUB_EXPIRY]));

        _holderStateKeeper().addDocument(
            documentKey_,
            dg1Hash_,
            holderRoot_,
            docType_,
            uint256(publicInputs_[_ICAO_PUB_DG_COMMIT]),
            notAfter_
        );

        emit DocumentRegistered(holderRoot_, documentKey_, docType_);
    }

    /**
     * @notice Register a NEW document under `holderRoot_` (= identity key). Unlike the
     *         upstream path, this does NOT require the holder to be unused — many documents
     *         may share one holder root.
     */
    function registerDocumentViaNoir(
        uint256 holderRoot_,
        Passport memory passport_,
        bytes32 docType_,
        uint64 notAfter_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) external virtual {
        require(holderRoot_ > 0, "HolderRegistration: holder can not be zero");

        _authenticateDocument(holderRoot_, passport_, signature_, zkPoints_);

        _holderStateKeeper().addDocument(
            passport_.publicKey,
            _replayKey(passport_),
            bytes32(holderRoot_),
            docType_,
            passport_.dgCommit,
            notAfter_
        );

        emit DocumentRegistered(bytes32(holderRoot_), passport_.publicKey, docType_);
    }

    /**
     * @notice Renew: supersede `oldDocumentKey_` and bind `newPassport_` under the SAME
     *         `holderRoot_`. The new document's Noir proof binding to `holderRoot_` IS the
     *         link proof that both documents belong to one holder.
     */
    function renewDocumentViaNoir(
        bytes32 oldDocumentKey_,
        uint256 holderRoot_,
        Passport memory newPassport_,
        bytes32 newDocType_,
        uint64 newNotAfter_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) external virtual {
        require(holderRoot_ > 0, "HolderRegistration: holder can not be zero");

        _authenticateDocument(holderRoot_, newPassport_, signature_, zkPoints_);

        _holderStateKeeper().renewDocument(
            oldDocumentKey_,
            newPassport_.publicKey,
            _replayKey(newPassport_),
            bytes32(holderRoot_),
            newDocType_,
            newPassport_.dgCommit,
            newNotAfter_
        );

        emit DocumentRenewedVia(bytes32(holderRoot_), oldDocumentKey_, newPassport_.publicKey);
    }

    /**
     * @notice Revoke a document the holder controls. Gated by a valid backend signer signature
     *         over the document (same trust assumption as registration).
     *
     * @dev Signs a REVOKE-specific message (`_buildRevokeSignedData`), deliberately NOT
     *      `_buildSignedData` (registration's message format). Reusing registration's exact
     *      message here would mean asking the backend signer to sign the SAME digest twice for
     *      the same document (once to register, once to revoke) — with a deterministic signer
     *      (RFC 6979, the common case), that produces byte-identical signature bytes, which
     *      `stateKeeper.useSignature`'s anti-replay check would then reject as already-used
     *      (consumed at registration time), making revocation of any normally-registered
     *      document permanently impossible. Domain-separating the message avoids depending on
     *      signer randomness for correctness.
     */
    /**
     * @param holderRoot_ the identity this document is bound to.
     *
     * REQUIRED SINCE sec. 2.18bi, and deliberately NOT part of the signed data. The state keeper
     * stores only `Poseidon(holderRoot)` - so that a seized passport cannot be resolved to its
     * owner - and therefore cannot hand the value back. Passing it unsigned is safe because the
     * keeper checks it against that commitment: a wrong holder reverts, so this parameter cannot
     * be used to revoke somebody else's document. What authorises the revocation remains the
     * signature over the PASSPORT, unchanged.
     */
    function revokeDocumentViaSigner(
        Passport memory passport_,
        bytes32 holderRoot_,
        bytes memory signature_
    ) external virtual {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildRevokeSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _holderStateKeeper().revokeDocument(passport_.publicKey, holderRoot_);
    }

    /**
     * @dev Revocation's signed-data format — same fields as `_buildSignedData`, distinguished by
     *      a different prefix, so a registration signature and a revocation signature for the
     *      SAME document are never the same message (see `revokeDocumentViaSigner`'s doc comment).
     */
    function _buildRevokeSignedData(Passport memory passport_) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "HolderRegistration revoke prefix",
                    address(this),
                    passport_.passportHash,
                    passport_.dgCommit,
                    passport_.publicKey,
                    passport_.verifier
                )
            );
    }

    /**
     * @dev Shared auth: verify the backend signer signature AND the Noir proof binding the
     *      document's DG1 to `holderRoot_`. Consumes the signature (anti-replay).
     */
    function _authenticateDocument(
        uint256 holderRoot_,
        Passport memory passport_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) internal {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _verifyNoirZKProof(
            passport_.verifier,
            passport_.dg1Hash,
            bytes32(passport_.dgCommit),
            bytes32(holderRoot_),
            zkPoints_
        );
    }

    /**
     * @dev The anti-replay key for a document binding: `dg1Hash`, NOT `passportHash`.
     *
     * WHY THIS MATTERS, AND WHAT WAS WRONG. `HolderStateKeeper` already refuses to bind the same
     * document twice (`_usedDocumentHash`), but it was being fed `passport_.passportHash` — a
     * caller-supplied struct field that the Noir proof DOES NOT CONSTRAIN. `_verifyNoirZKProof`
     * binds exactly three public signals: `dgCommit`, `dg1Hash` and `holderRoot`. `passportHash`
     * and `publicKey` are attested only by the backend signer's signature.
     *
     * So the uniqueness guard keyed on values the proof never checks, while a proof-bound value
     * sat unused. Anyone able to obtain a signature could present a FRESH `publicKey` and
     * `passportHash` for the SAME physical passport and bind it to a SECOND `holderRoot` — the
     * proof still verifies, because nothing links those fields to the document. That defeats any
     * identity-level blacklist by construction: get listed, re-register, withdraw as someone new.
     *
     * `dg1Hash` is computed IN-CIRCUIT as `passport_hash(dg1)` over the MRZ (see
     * noir_dl_lib/src/lite.nr::register_identity_light), so it is deterministic for a given
     * passport and unforgeable. Two different documents cannot collide on it — the MRZ carries the
     * document number — so renewal is unaffected: a renewed passport has a new MRZ, hence a new
     * key, and legitimately binds under the same holder root.
     *
     * ZERO IS REJECTED HERE rather than in `addDocument`, which treats a zero hash as "no
     * anti-replay wanted" and skips the check. That permissiveness is fine for the state keeper as
     * a general primitive, but on THIS path the guard is load-bearing, and silently skipping it is
     * exactly the shape of hole this function exists to close.
     */
    /**
     * @notice The MRZ expiry - six packed ASCII digits, YYMMDD - as epoch seconds.
     *
     * ⚠️ THE CENTURY WINDOW IS POLICY AND IS DECIDED HERE, DELIBERATELY. ICAO 9303 does not give a
     * century for a two-digit year, so somebody must choose. The circuit must NOT: baking a window
     * into a verifier would freeze it into an artifact that cannot be changed without regenerating
     * every proof. `YY < 70` maps to 20YY, which covers every document that can still be valid.
     *
     * Reverts on a malformed date rather than returning 0, because 0 means "no expiry" in
     * `HolderStateKeeper` - so a parse failure would silently promote an expiring document to a
     * permanent one, which is the failure direction that matters.
     */
    function _mrzDateToTimestamp(uint256 packed_) internal pure returns (uint64) {
        uint256 y_;
        uint256 m_;
        uint256 d_;

        // Big-endian ASCII: byte 5 is the most significant digit of YY.
        unchecked {
            for (uint256 i_ = 0; i_ < 6; ++i_) {
                uint256 c_ = (packed_ >> (8 * (5 - i_))) & 0xff;
                require(c_ >= 0x30 && c_ <= 0x39, "HolderRegistration: non-digit in expiry");
                uint256 v_ = c_ - 0x30;
                if (i_ < 2) y_ = y_ * 10 + v_;
                else if (i_ < 4) m_ = m_ * 10 + v_;
                else d_ = d_ * 10 + v_;
            }
        }

        require(m_ >= 1 && m_ <= 12, "HolderRegistration: bad expiry month");
        require(d_ >= 1 && d_ <= 31, "HolderRegistration: bad expiry day");

        y_ += y_ < 70 ? 2000 : 1900;

        // days_from_civil (Howard Hinnant), exact for any proleptic Gregorian date. The window above
        // keeps every year >= 1970, so unsigned arithmetic is safe here.
        unchecked {
            uint256 yy_ = m_ <= 2 ? y_ - 1 : y_;
            uint256 era_ = yy_ / 400;
            uint256 yoe_ = yy_ - era_ * 400;
            uint256 mp_ = m_ > 2 ? m_ - 3 : m_ + 9; // March-based month, 0..11
            uint256 doy_ = (153 * mp_ + 2) / 5 + d_ - 1;
            uint256 doe_ = yoe_ * 365 + yoe_ / 4 - yoe_ / 100 + doy_;
            uint256 days_ = era_ * 146097 + doe_ - 719468;
            return uint64(days_ * 86400);
        }
    }

    function _replayKey(Passport memory passport_) internal pure returns (bytes32) {
        require(passport_.dg1Hash != bytes32(0), "HolderRegistration: zero dg1 hash");
        return passport_.dg1Hash;
    }

    function _holderStateKeeper() internal view returns (HolderStateKeeper) {
        return HolderStateKeeper(address(stateKeeper));
    }

    function _isSigner(address account_) internal view returns (bool) {
        // `getSigners()` is external in RegistrationSimple and `_signers` is private, so reuse
        // it via an external view staticcall.
        address[] memory signers_ = this.getSigners();
        for (uint256 i = 0; i < signers_.length; ++i) {
            if (signers_[i] == account_) {
                return true;
            }
        }
        return false;
    }
}
