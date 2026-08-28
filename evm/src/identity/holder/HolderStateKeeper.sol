// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoseidonUnit1L, PoseidonUnit2L, PoseidonUnit3L} from "../libraries/Poseidon.sol";

import {StateKeeper} from "../state/StateKeeper.sol";

/**
 * @title HolderStateKeeper
 * @notice The holder-rooted credential tree — the "1 key = 1 document" fix. See SCOPE.md §7.8.
 *
 * The upstream {StateKeeper} enforces a strict bijection: `addBond` requires
 * `_identityInfo.activePassport == 0`, so one identity key binds AT MOST one passport.
 * rarime supports identity *rotation* for one passport (`reissueBondIdentity`) but never
 * one holder with many documents, and never renewal-with-continuity.
 *
 * This fork inverts the model into a 2-level tree:
 *
 *     holder root (durable)  =  identityKey = Poseidon(pubkey(sk_identity))
 *          │                     ↑ continuity binds HERE: scoped pseudonyms, nullifiers,
 *          │                       one-person-ness, card-state — NOT the document.
 *          ├── document: passport      (docType, dgCommit, validity, status)
 *          ├── document: national ID
 *          ├── document: EUDI PID
 *          └── document: passport'      ← renewal supersedes the old passport
 *
 * Relation is many-documents-TO-one-holder (a given document still belongs to exactly one
 * holder; a holder may hold many documents). RENEWAL adds a new document and supersedes the
 * old under the SAME holder root, so identity/pseudonyms/card-state survive a passport swap.
 *
 * It REUSES StateKeeper's certificate / registration-set / owner / used-signature machinery
 * by inheritance, ADDS the document model, and DISABLES the old 1:1 `addBond` path so the two
 * binding models can't be mixed. The SMT (`registrationSmt`) is unchanged, and revocation/renewal
 * do NOT need true SMT exclusion (non-membership) proofs — the underlying solarity solidity-lib
 * SparseMerkleTree exposes `getProof`'s exclusion machinery (existence/auxExistence/auxKey/
 * auxValue), but that's for the ORTHOGONAL case of proving a key was never registered. Revocation
 * is different: the document key stays a tree MEMBER forever; only its VALUE changes to a sentinel
 * (Poseidon1(REVOKED) / Poseidon1(SUPERSEDED)). A query circuit reconstructs the CLAIMED-current
 * value — Poseidon3(dgCommit, seq, timestamp) — and does a plain SMT MEMBERSHIP check against the
 * current root; once revoked, that reconstruction can never again equal the real leaf value, so a
 * stale "I'm still current" claim provably fails without any exclusion proof. This membership-
 * with-value property is what actually needs to hold, and it's verified directly (not just
 * asserted) by test_leaf_value_matches_circuit_reconstruction in test/holder/HolderStateKeeper.t.sol.
 *
 * OPEN GAP (tracked in backend/circuits/PP-NOIR-FUSION.md): this property only rejects a stale
 * claim if the CONSUMING circuit actually performs the reconstruct-and-membership-check against
 * THIS tree's value convention. The forked `query_identity` circuit does not yet do so — see the
 * fusion doc's Noir migration TODOs.
 *
 * SCOPE NOTE: the matching ZK side (prove "a CURRENT document under MY holder root satisfies
 * the predicate") is the forked `query_identity` Noir circuit (passport-zk-circuits-noir) and
 * is NOT in this repo — see §7.5/§7.8. This contract defines the on-chain tree the circuit
 * proves against.
 */
contract HolderStateKeeper is StateKeeper {
    bytes32 public constant SUPERSEDED = keccak256("SUPERSEDED");

    // Canonical document types (mirror the SDK DocumentType enum in HolderTree.ts).
    bytes32 public constant DOC_PASSPORT = keccak256("PASSPORT");
    bytes32 public constant DOC_NATIONAL_ID = keccak256("NATIONAL_ID");
    bytes32 public constant DOC_MDL = keccak256("MDL");
    bytes32 public constant DOC_EUDI_PID = keccak256("EUDI_PID");
    // Notarized proof-of-title (property/vehicle/asset ownership) — notary/registrar signature
    // trust root, not a passport biometric chip. Tree/state support only; no query circuit yet
    // (see Eudi.ts TitleClaim for the honest built-vs-unbuilt split).
    bytes32 public constant DOC_NOTARIAL_TITLE = keccak256("NOTARIAL_TITLE");

    enum DocStatus {
        None,
        Current,
        Superseded,
        Revoked
    }

    struct DocumentBond {
        /**
         * `Poseidon(holderRoot)` - THE COMMITMENT, NEVER THE VALUE (sec. 2.18bi).
         *
         * `_documents` is keyed on `documentKey`, which IS derivable by anyone holding the physical
         * document (it is the passport public key, or the proof's `passportHash` - both readable
         * from the chip). Storing `holderRoot` in the clear therefore made a seized passport a
         * lookup to its owner's durable identity - the exact unit an identity-level blacklist acts
         * on (sec. 2.18be), and the handle that enumerates every other document they hold.
         *
         * A COMMITMENT CLOSES IT COMPLETELY, unlike hiding the getter. Solidity visibility is not a
         * privacy control - `eth_getStorageAt` reads any slot whose key you can compute - so the
         * only real fix is for the value not to be there. `holderRoot` is a high-entropy field
         * element derived from a public key, so this is not dictionary-attackable.
         *
         * EVERY CALLER THAT NEEDS THE IDENTITY ALREADY KNOWS IT and passes it in to be checked
         * against this commitment; nothing reads it back out.
         */
        bytes32 holderRootCommitment;
        bytes32 docType;
        uint64 issueTimestamp;
        uint64 notAfter; // validity window end (0 = none)
        uint64 seq; // supersession sequence under this holder
        DocStatus status;
    }

    // --- appended storage (after all StateKeeper storage — safe for the proxy layout) ---
    mapping(bytes32 => DocumentBond) internal _documents; // documentKey => bond
    mapping(bytes32 => bytes32[]) internal _holderDocuments; // holderRoot => documentKeys
    /**
     * @notice Whether a document hash has been consumed. THE ONLY REMAINING DOCUMENT-KEYED STATE.
     *
     * A BOOL, DELIBERATELY - it records THAT a document was used and never BY WHOM. `dg1Hash` is
     * computable by anyone who handles the document (BAC needs only the printed MRZ), so any value
     * stored under it is readable by that person via `eth_getStorageAt`, whatever Solidity
     * visibility claims. Keeping the value a bool bounds that leak to a single bit: *this document
     * is registered here*. It cannot yield the holder, the rest of their documents, or the size of
     * their set - which matters because blacklisting acts on the IDENTITY, so naming the identity
     * would name the unit sanctions apply to (sec. 2.18be).
     *
     * REMOVING EVEN THAT BIT needs the key itself to be uncomputable from the document - an OPRF
     * under a threshold key (sec. 2.18bc). Not built. Everything cheaper than that is already done.
     */
    mapping(bytes32 => bool) internal _usedDocumentHash;


    /**
     * @notice RESERVED - the slot formerly holding `_holderOfDocumentHash` (dg1Hash => holderRoot),
     *         deleted in sec. 2.18bg. **Do not remove and do not reuse.**
     *
     * WHY A PLACEHOLDER AND NOT A CLEAN DELETION. This contract is UUPS-upgradeable, and storage
     * slots are assigned by DECLARATION ORDER. Removing a variable from the middle shifts every
     * variable after it - here `lastDocumentInvalidationAt`, which `IdentityRegistry` reads to
     * enforce `RegistrationRootPredatesAnInvalidation`. A shifted read would return 0, the guard
     * would never fire, and **a revoked document could escrow against its pre-revocation root
     * forever** - the same class of silent hole as sec. 2.18b/e.
     *
     * No deployment of this contract exists in the repo, so a clean deletion would be safe TODAY.
     * The placeholder costs one unused slot and makes the change safe even if an instance exists
     * somewhere not recorded here - which is the cheaper side of that bet by a wide margin.
     */
    bytes32 private __deprecated_holderOfDocumentHash;

    /**
     * @notice When a document last STOPPED being current, by revocation or renewal. Appended after
     *         all prior storage, so the proxy layout is unaffected.
     *
     * WHY A CONSUMER NEEDS THIS. Invalidating a document overwrites its leaf VALUE, so every root
     * created afterwards excludes it - but roots created BEFORE still prove it current, and
     * `PoseidonSMT.isRootValid` keeps accepting those for the rest of ROOT_VALIDITY (one hour).
     * A cancelled passport could therefore still register a pool identity for up to an hour
     * (sec. 2.18b). A consumer that requires the root it was given to be at least as new as
     * this timestamp closes that, and nothing else on this contract exposes the information: the
     * SMT records WHEN each root appeared but not WHY, and `_documents` is keyed by a document key
     * a caller proving in zero knowledge deliberately never reveals.
     */
    uint64 public lastDocumentInvalidationAt;

    /**
     * DELIBERATELY NOT `indexed` ON `holderRoot` (sec. 2.18bc / 2.18be).
     *
     * An indexed topic exists to make lookup cheap, and that is exactly the capability an adversary
     * needs here. Anyone who handles a document for thirty seconds can read the chip with BAC (the
     * MRZ is printed on the page), compute `dg1Hash`, resolve it to a `holderRoot`, and then - if
     * this were indexed - recover THAT PERSON'S ENTIRE DOCUMENT SET in one `eth_getLogs` call: how
     * many documents, which types, when each was registered, every renewal and revocation.
     *
     * WHY THE SET MATTERS MORE THAN ANY ONE DOCUMENT. Blacklisting acts on the IDENTITY, not on a
     * document, so `holderRoot` names the exact unit sanctions apply to. And multi-citizenship is
     * the feature this design exists for: for someone whose second passport is the way out, the SIZE
     * and SHAPE of their document set is the sensitive fact, not any single entry.
     *
     * WHAT THIS DOES AND DOES NOT BUY. Un-indexing turns one targeted query into "fetch and decode
     * every event this contract ever emitted", which defeats casual and bulk lookup at real cost.
     * It does NOT defeat a determined adversary who scrapes the whole log. **The storage leak that
     * used to sit beside it is GONE**: `_holderOfDocumentHash` (dg1Hash => holderRoot) has been
     * deleted (sec. 2.18bg). What remains keyed on a document is `_usedDocumentHash`, a BOOL - so a
     * seized document reveals THAT it is registered somewhere in this system, and nothing about
     * which identity holds it, how many other documents that identity holds, or what they are.
     */
    event DocumentAdded(bytes32 holderRoot, bytes32 documentKey, bytes32 docType);
    event DocumentRenewed(
        bytes32 holderRoot,
        bytes32 oldDocumentKey,
        bytes32 newDocumentKey
    );
    event DocumentRevoked(bytes32 holderRoot, bytes32 documentKey);

    /**
     * @notice Disable the upstream 1:1 binding so it cannot be mixed with the holder tree.
     */
    function addBond(bytes32, bytes32, bytes32, uint256) external virtual override onlyRegistration {
        revert("HolderStateKeeper: use addDocument (holder tree)");
    }

    /**
     * @notice Bind a document under a holder root. Many documents may share one holder root;
     *         a document may belong to only one holder.
     * @param documentKey_  unique key of the document (e.g. passport public key hash)
     * @param documentHash_ the document hash variant (anti-replay), may be zero
     * @param holderRoot_   the durable identity (rarime `identityKey` / profileKey)
     * @param docType_      one of the DOC_* constants
     * @param dgCommit_     the document's attribute commitment
     * @param notAfter_     validity window end (epoch seconds), 0 if none
     */
    function addDocument(
        bytes32 documentKey_,
        bytes32 documentHash_,
        bytes32 holderRoot_,
        bytes32 docType_,
        uint256 dgCommit_,
        uint64 notAfter_
    ) external virtual onlyRegistration {
        require(documentKey_ != bytes32(0), "HolderStateKeeper: zero document");
        require(holderRoot_ != bytes32(0), "HolderStateKeeper: zero holder");
        require(_documents[documentKey_].status == DocStatus.None, "HolderStateKeeper: document bound");

        if (documentHash_ != bytes32(0)) {
            require(!_usedDocumentHash[documentHash_], "HolderStateKeeper: document hash used");
            _usedDocumentHash[documentHash_] = true;
        }

        _bindDocument(documentKey_, holderRoot_, docType_, dgCommit_, notAfter_, 0);

        emit DocumentAdded(holderRoot_, documentKey_, docType_);
    }

    /**
     * @notice Renew a document: supersede `oldDocumentKey_` and add `newDocumentKey_` under the
     *         SAME holder root, preserving identity continuity. The link is the holder root:
     *         registration verifies a ZK proof binding the new document's DG1 to `holderRoot_`,
     *         exactly as the original document was bound, so both provably belong to one holder.
     */
    function renewDocument(
        bytes32 oldDocumentKey_,
        bytes32 newDocumentKey_,
        bytes32 newDocumentHash_,
        bytes32 holderRoot_,
        bytes32 newDocType_,
        uint256 newDgCommit_,
        uint64 newNotAfter_
    ) external virtual onlyRegistration {
        DocumentBond storage old_ = _documents[oldDocumentKey_];

        require(old_.status == DocStatus.Current, "HolderStateKeeper: old not current");
        require(
            old_.holderRootCommitment == _holderCommitment(holderRoot_),
            "HolderStateKeeper: holder mismatch"
        );
        require(_documents[newDocumentKey_].status == DocStatus.None, "HolderStateKeeper: new bound");

        if (newDocumentHash_ != bytes32(0)) {
            require(!_usedDocumentHash[newDocumentHash_], "HolderStateKeeper: document hash used");
            _usedDocumentHash[newDocumentHash_] = true;
        }

        // Supersede the old leaf (keeps it provably non-current in the tree).
        old_.status = DocStatus.Superseded;
        lastDocumentInvalidationAt = uint64(block.timestamp);
        bytes32 oldIndex_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(oldDocumentKey_), uint256(holderRoot_)])
        );
        registrationSmt.update(
            oldIndex_,
            bytes32(PoseidonUnit1L.poseidon([uint256(SUPERSEDED) % SNARK_SCALAR_FIELD]))
        );

        // Add the renewed document under the same holder root, next sequence.
        _bindDocument(newDocumentKey_, holderRoot_, newDocType_, newDgCommit_, newNotAfter_, old_.seq + 1);

        emit DocumentRenewed(holderRoot_, oldDocumentKey_, newDocumentKey_);
    }

    /**
     * @notice Revoke a current document. The leaf stays a tree member (Poseidon2(documentKey,
     *         holderRoot) is never removed); its VALUE is overwritten to Poseidon1(REVOKED), which
     *         can never equal a query circuit's Poseidon3(dgCommit, seq, timestamp) reconstruction
     *         for "current" — see the class-level NatSpec for why this doesn't need an exclusion
     *         (non-membership) proof.
     */
    /**
     * @notice Revoke a document.
     * @param holderRoot_ the identity this document is bound to.
     *
     * TAKEN AS A PARAMETER RATHER THAN READ FROM STORAGE (sec. 2.18bi). The bond stores only
     * `Poseidon(holderRoot)`, so the value cannot be read back - which is the point: it is what
     * stops a seized document resolving to its owner. The caller (`HolderRegistration`) already
     * knows the holder, and the commitment check below makes passing the wrong one impossible, so
     * this costs a parameter and gives up no guarantee.
     */
    function revokeDocument(
        bytes32 documentKey_,
        bytes32 holderRoot_
    ) external virtual onlyRegistration {
        DocumentBond storage doc_ = _documents[documentKey_];

        require(doc_.status == DocStatus.Current, "HolderStateKeeper: not current");
        require(
            doc_.holderRootCommitment == _holderCommitment(holderRoot_),
            "HolderStateKeeper: holder mismatch"
        );

        doc_.status = DocStatus.Revoked;
        lastDocumentInvalidationAt = uint64(block.timestamp);

        bytes32 index_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(documentKey_), uint256(holderRoot_)])
        );
        registrationSmt.update(
            index_,
            bytes32(PoseidonUnit1L.poseidon([uint256(REVOKED) % SNARK_SCALAR_FIELD]))
        );

        emit DocumentRevoked(holderRoot_, documentKey_);
    }

    /**
     * @notice Get a document's bond.
     */
    function getDocument(bytes32 documentKey_) external view virtual returns (DocumentBond memory) {
        return _documents[documentKey_];
    }

    /**
     * @notice List all document keys ever bound under a holder root (any status).
     */
    function getHolderDocuments(
        bytes32 holderRoot_
    ) external view virtual returns (bytes32[] memory) {
        return _holderDocuments[holderRoot_];
    }

    /**
     * @notice Count the CURRENT (non-superseded, non-revoked) documents under a holder root.
     */
    function getActiveDocumentCount(
        bytes32 holderRoot_
    ) external view virtual returns (uint256 count_) {
        bytes32[] storage keys_ = _holderDocuments[holderRoot_];
        for (uint256 i = 0; i < keys_.length; ++i) {
            if (_documents[keys_[i]].status == DocStatus.Current) {
                ++count_;
            }
        }
    }


    /// @dev The stored form of an identity. One definition, so the bind/renew/revoke checks cannot
    ///      drift apart - the lesson of sec. 2.18o, where one rule written three times carried the
    ///      same defect in all three copies.
    function _holderCommitment(bytes32 holderRoot_) internal pure returns (bytes32) {
        return bytes32(PoseidonUnit1L.poseidon([uint256(holderRoot_) % SNARK_SCALAR_FIELD]));
    }

    function _bindDocument(
        bytes32 documentKey_,
        bytes32 holderRoot_,
        bytes32 docType_,
        uint256 dgCommit_,
        uint64 notAfter_,
        uint64 seq_
    ) internal {
        _documents[documentKey_] = DocumentBond({
            holderRootCommitment: _holderCommitment(holderRoot_),
            docType: docType_,
            issueTimestamp: uint64(block.timestamp),
            notAfter: notAfter_,
            seq: seq_,
            status: DocStatus.Current
        });

        _holderDocuments[holderRoot_].push(documentKey_);

        bytes32 index_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(documentKey_), uint256(holderRoot_)])
        );
        bytes32 value_ = bytes32(
            PoseidonUnit3L.poseidon([dgCommit_, uint256(seq_), uint256(uint64(block.timestamp))])
        );

        registrationSmt.add(index_, value_);
    }
}
