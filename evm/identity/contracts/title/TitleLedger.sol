// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PoseidonUnit2L} from "../libraries/Poseidon.sol";
import {HolderStateKeeper} from "../holder/HolderStateKeeper.sol";
import {INoirVerifier} from "../interfaces/verifiers/INoirVerifier.sol";
import {RegistrySourceAnchor} from "../registry/RegistrySourceAnchor.sol";
import {Constants} from "../pool/lib/Constants.sol";

/// @notice Public, inspectable title/property ledger - informed by (NOT copying) MetaLeX's
/// CyberCorps design (see backend/circuits/pp/src/title_holder.nr's header and the 2026-07-24
/// design discussion). Takes CyberCorps' structural properties that don't touch identity - rich,
/// self-describing, non-fungible per-entry records; "the ledger IS the record, not a pointer to
/// one"; possession alone never implies a change of registered holder - and deliberately REJECTS
/// the one CyberCorps property that's at odds with this system's goal: identifiable, inspectable
/// ownership (CyberCorps exists specifically to satisfy DGCL SS219-220's stockholder-list
/// inspection rights, which requires a knowable holder). Here, the holder is NEVER a public
/// identity - only a title-specific Poseidon commitment, provable in zero-knowledge.
///
/// WHY NOT the raw holder_root (Poseidon(pubkey(sk_identity))) used elsewhere in this fusion
/// (HolderStateKeeper, the PP identity ASP)? Because holder_root is one fixed, durable value per
/// identity - storing it directly as a title's public "holder" field would let anyone compare
/// that field across every title entry and correlate every title the same person holds. Instead
/// each title stores `Poseidon2(holder_root, titleId)` - see pp/src/title_holder.nr - so
/// commitments for the same identity on different titles are unrelated field elements.
///
/// LOAN-COLLATERAL FLOW this is built for: a borrower calls `verifyHolderProof` (or a lender
/// contract does, off the borrower's proof) to confirm "the presenter controls this title,"
/// without ever learning who they are. The loan itself should be disbursed via a Privacy Pool
/// deposit using a precommitment the borrower generated locally (frontend/identity-wallet/src/
/// pp/notes.ts, already built) - not a direct transfer to an address that could be linked to the
/// borrower by timing/IP/counterparty analysis. That disbursement-side wiring lives in whatever
/// lending contract integrates this ledger; it is not part of this contract.
///
/// OPEN GAP, not silently assumed solved: binding a real-world notary's identity to an on-chain
/// signing address. `bindNotaryAddress` is gated by NOTARY_REGISTRY's own NOTARY_REGISTRAR role
/// (the SAME trust boundary the notary registry itself already rests on, not a separate,
/// independently-scrutinized admin key) - but the underlying claim "this address really is that
/// notary" still isn't cryptographically proven. A real binding needs an out-of-band process
/// (e.g. reusing rarime's own passport-verification flow, cross-checked against the government
/// registry by name/ID) that isn't built yet. Everything downstream of that binding (the
/// Merkle-proof check against RegistrySourceAnchor's CRE-fed root) is real and
/// unmodified from how the notary registry mechanism already works.
///
/// @dev UUPS-upgradeable behind a proxy - matches RegistrySourceAnchor.sol and this codebase's
/// convention for record-holding registry contracts (see RegistrySourceAnchor.sol's own doc
/// comment for the non-upgradeable-vault-vs-upgradeable-registry distinction this follows).
contract TitleLedger is AccessControlUpgradeable, UUPSUpgradeable {
    using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    struct TitleEntry {
        // Public, self-describing legal metadata - NEVER identity.
        /**
         * DETERMINISTIC KEYED PSEUDONYM for the property: `PRF(registryKey, legalDescriptionHash)`.
         * Opaque here; this contract never sees the document.
         *
         * WHO COMPUTES IT IS UNRESOLVED - see sec. 2.16b. An earlier revision said "computed
         * off-chain by the notary"; that is WRONG and has been removed rather than left to mislead.
         * A notary holds no protocol key and performs no protocol computation - their status is
         * attested, not trusted. No party in the current design holds `registryKey`, which means the
         * mint path is not yet implementable as specified, and a property owner cannot check whether
         * their own property has been titled here. Do not read this field as settled.
         *
         * WHY NOT A SALTED COMMITMENT, which was the obvious fix and was briefly built. Legal
         * descriptions - street address, parcel/APN, plat description - are low-entropy and
         * publicly enumerable from county records, so a BARE hash is brute-forceable and reveals
         * which real-world property sits behind a titleId. A per-holder SALT fixes that, and breaks
         * something a title registry cannot do without: with a random salt, two titles over the SAME
         * property produce two unrelated values, so DOUBLE-MINTING BECOMES UNDETECTABLE. A bare hash
         * at least collides. The salt bought confidentiality by destroying uniqueness.
         *
         * A keyed pseudonym gives both. DETERMINISTIC in the document, so a second title over the
         * same property collides and is rejected below. OPAQUE without the key, so the public cannot
         * run a dictionary against county records. And it adds NO new trust: the notary already
         * knows the document - they attest to it - so holding the key grants them nothing they did
         * not have.
         *
         * SAME PRIMITIVE AS THE IDENTITY REGISTRY'S revocation pseudonyms (sec. 2.13e), for
         * the same reason and with the same trade: a public set of opaque, deterministic values.
         *
         * It also removes the salt's custody failure. A lost salt makes a commitment permanently
         * unopenable - for a real property title that is unrecoverable. There is no per-title secret
         * here to lose.
         *
         * BINDING comes from the notary's signature over this value at mint, not from an on-chain
         * opening: whoever holds the document and the registry key can recompute it and check.
         */
        bytes32 propertyKey;
        // NOTE: there is deliberately NO legalDescriptionURI. It existed to point at the document
        // (e.g. `ipfs://...`) and was PUBLIC, which defeated the whole point of hiding the property:
        // an observer would skip any attack on `propertyKey` and simply fetch the document. Under
        // this design the document is never opened on-chain at all - binding is the notary's
        // signature over `propertyKey` - so a public pointer buys nothing and costs everything.
        // Whoever needs the document gets it out of band, from the notary or the holder.
        bytes32 jurisdiction; // e.g. keccak256("UA") - which registry/law this title is under
        uint256 priorTitleId; // 0 if this is a root entry; otherwise a chain-of-title link
        bytes32 notaryRegistryId; // which RegistrySourceAnchor registryId attested this entry
        // NO `address notary`. Storing it named the acting notary for anyone who read the public
        // `titles` mapping (sec. 2.18am), and it is not needed: authorisation is now a proof of
        // membership in `_notaryTree`, which says an ACTIVE notary acted without saying which.
        uint256 mintedAt;
        bool encumbered;
    }

    // Regular state, not immutable - see RegistrySourceAnchor.EVIDENCE_REGISTRY's comment for why
    // (one implementation can serve many proxies; deployment-specific config is initializer-set).
    RegistrySourceAnchor public NOTARY_REGISTRY;
    INoirVerifier public TITLE_HOLDER_VERIFIER; // verifies pp::title_holder proofs
    HolderStateKeeper public STATE_KEEPER; // holder documents, for the title-holder path

    // 0 is reserved for "no prior title" in priorTitleId. NOT given an inline default here: for a
    // UUPS-upgradeable contract, an inline state-variable initializer only runs in the
    // IMPLEMENTATION contract's own (never-used) constructor-time storage, not the proxy's - the
    // proxy's slot would silently stay at the EVM default of 0 forever. Set explicitly in
    // initialize() instead (caught by a real assertEq(titleId, 1) test failure, not by inspection).
    uint256 public nextTitleId;
    mapping(uint256 => TitleEntry) public titles;
    mapping(uint256 => string[]) public restrictionLegends; // titleId => legends, separately mutable
    mapping(uint256 => bytes32) public holderCommitment; // titleId => Poseidon2(holder_root, titleId)

    /// propertyKey => the title currently covering that property. THE UNIQUENESS INVARIANT: one
    /// property, one live title. Nothing enforced this before - two titles could be minted over the
    /// same land with nothing to detect it.
    mapping(bytes32 => uint256) public titleOfProperty;

    // See the OPEN GAP note above - placeholder trust bootstrap, not a solved binding. Gated by
    // NOTARY_REGISTRY's OWN NOTARY_REGISTRAR role (checked live via hasRole, not copied into a
    // separate admin key here) - deliberately the SAME trust boundary the notary registry itself
    // already rests on, not an additional, independently-scrutinized authority. This doesn't
    // solve "how do we know the binding claim is true" (that needs the out-of-band identity
    // process described above), but it does mean there is exactly ONE trust assumption in this
    // whole mechanism (whoever the registry's postman is), not two.
    /**
     * A NOTARY IS A COMMITMENT, not an address (sec. 2.13l / sec. 2.15 / sec. 2.18am).
     *
     * WHAT THIS REPLACED. Two public mappings used to live here - `notaryDataHashOf` (holderRoot
     * to keccak(regNumber, fullName, region, status)) and `notaryIdentityOf` (signing key to
     * holderRoot). Both are gone. The first was ENUMERABLE: every preimage component comes from the
     * official register, which is public by construction because a decentralised oracle network
     * scrapes it, so anyone could compute the hash for every notary and match. The second published
     * the link between a signing key and an identity outright.
     *
     * WHAT STANDS IN THEIR PLACE. A commitment in `_notaryTree`, admitted by `registerNotary` only
     * against a register entry proven in the CRE-anchored snapshot - so notary-ness still comes from
     * the official register and the postman still cannot invent a notary. What changed is that
     * ACTING no longer names anyone: `notary_action` proves membership in that tree in zero
     * knowledge.
     *
     * WHY A COMMITMENT AND NOT AN ADDRESS. Unchanged in substance from the original reasoning, and
     * now enforced rather than argued: a bare keypair made the notary the ONLY participant who could
     * not be revoked - an address has no passport to expire, no document to invalidate, no status to
     * lose. A leaf has all three, because revocation writes a non-zero value that no clean-status
     * proof can equal.
     *
     * DELIBERATELY NOT the pool commitment, even though that is this system's other identity
     * handle. That value is a notary's PRIVATE key into the shielded pool; reusing it here would
     * link their public professional role to their private financial identity - buying convenience
     * by destroying the privacy the pool exists to provide. `notary_secret` is its own value.
     */
    /**
     * THE ANONYMITY SET (sec. 2.18am). Notary commitments, one leaf each, value 0 while active.
     *
     * REGISTRATION IS PUBLIC AND VERIFIED; ACTIONS ARE ANONYMOUS. Those are separable, and keeping
     * them separate is what lets this be private WITHOUT weakening who may act. `registerNotary`
     * still proves the register entry against the CRE-anchored root, exactly as the old
     * address-based path did - so the postman cannot invent a notary. What changed is action time:
     * `notary_action` proves membership in this tree in zero knowledge, so a title records THAT an
     * active notary authorised it and never WHICH one.
     *
     * REVOCATION IS THE FAULT MECHANISM, which is why no custodian quorum exists here. Writing a
     * non-zero leaf value makes every STATUS_CLEAN proof for that leaf impossible, so a revoked
     * notary silently loses the ability to act and nobody learns who they were. Identical to the
     * identity registry, deliberately - see backend/circuits/notary_action/src/main.nr.
     */
    SparseMerkleTree.Bytes32SMT private _notaryTree;
    mapping(bytes32 _root => uint256 _createdAt) public notaryRootCreatedAt;

    INoirVerifier public NOTARY_ACTION_VERIFIER; // verifies notary_action proofs

    /// How long a SUPERSEDED notary root stays usable, so a proof built moments before another
    /// notary was registered or revoked is not wasted. Matches the identity registry's window.
    uint256 public constant NOTARY_ROOT_VALIDITY = 1 hours;

    /// NO `address notary` ON ANY OF THESE. It used to be an `indexed` topic on three of them,
    /// which made "every title this notary touched" a single log query - the worst of the four
    /// exposures sec. 2.18am found, because indexing exists precisely to make lookup cheap.
    event TitleMinted(uint256 indexed titleId, bytes32 jurisdiction, bytes32 holderCommitment);
    event TitleTransferred(uint256 indexed titleId, bytes32 oldHolderCommitment, bytes32 newHolderCommitment);
    event LegendAdded(uint256 indexed titleId, string legend);
    event EncumbranceSet(uint256 indexed titleId, bool encumbered);
    event NotaryRegistered(bytes32 indexed notaryCommitment, bytes32 indexed registryId);
    event NotaryRevoked(bytes32 indexed notaryCommitment, bytes32 predicate);

    error TitleDoesNotExist();
    error NotaryNotActive();
    error ZeroNotaryIdentity();
    error NotaryIdentityHasNoCurrentDocument();
    error InvalidNotaryIdentityProof();
    error UnknownNotaryRoot();
    error InvalidHolderProof();
    error ZeroCommitment();
    error ZeroPropertyKey();
    error PropertyAlreadyTitled(bytes32 propertyKey, uint256 existingTitleId);
    error PriorTitleIsForAnotherProperty(uint256 priorTitleId);
    /// Notary enrolment and revocation are gated by NOTARY_REGISTRAR, NOT by the publication
    /// role - see RegistrySourceAnchor (sec. 2.18cn) for why the two were separated.
    error OnlyNotaryRegistrar();
    error ZeroAddress();

    /// @notice Disables initializers on the implementation contract. Using the UUPS
    /// upgradeability pattern - matches Entrypoint.sol's own constructor exactly.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address notaryRegistry_,
        address titleHolderVerifier_,
        address stateKeeper_,
        address owner_,
        address notaryActionVerifier_
    ) external initializer {
        if (
            notaryRegistry_ == address(0) || titleHolderVerifier_ == address(0)
                || stateKeeper_ == address(0) || owner_ == address(0)
                || notaryActionVerifier_ == address(0)
        ) revert ZeroAddress();
        __AccessControl_init();
        // UUPSUpgradeable has no storage/init step in OZ 5.6.1 (it's a thin, stateless wrapper).

        NOTARY_REGISTRY = RegistrySourceAnchor(notaryRegistry_);
        TITLE_HOLDER_VERIFIER = INoirVerifier(titleHolderVerifier_);
        STATE_KEEPER = HolderStateKeeper(stateKeeper_);
        NOTARY_ACTION_VERIFIER = INoirVerifier(notaryActionVerifier_);
        // MUST equal notary_action's NOTARY_TREE_DEPTH. A mismatch fails every proof with no useful
        // diagnostic, which is why it is stated here next to the verifier it must agree with.
        _notaryTree.initialize(32);
        nextTitleId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(OWNER_ROLE, owner_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}

    /// @dev Placeholder trust bootstrap - see the contract-level OPEN GAP note and the
    /// `notaryDataHash` field comment for why this is gated by NOTARY_REGISTRY's role instead of
    /// a bespoke admin key.
    /**
     * @notice Bind a REGISTERED IDENTITY to its notary-registry entry and its signing key.
     * @dev The identity must already hold at least one current document - a notary is a passport
     *      holder in this system before they are a notary, which is what makes them revocable.
     *
     *      THE NOTARY MUST PROVE CONTROL OF `holderRoot_`. This needed no new circuit:
     *      `pp::title_holder` already proves `holder_root == extract_pk_identity_hash(sk_identity)`
     *      and binds it to a second field, and that field is an arbitrary CONTEXT - it is named
     *      `title_id` only because that was its first use. Passing a bind context instead gives
     *      exactly "I control this identity, and I am committing to THIS binding".
     *
     *      WHAT THAT CLOSES: the postman can no longer fabricate a binding for an identity whose
     *      owner never consented. Previously it could name any holderRoot at all.
     *
     *      WHAT REMAINS, stated rather than implied: the postman still chooses WHICH register entry
     *      is attached. Proving the entry is genuinely THIS person's needs the register's name and
     *      office number matched against the passport's own DG1 name field - a comparison no circuit
     *      here performs. So the residual trust is "the postman attached the right entry", not
     *      "the postman invented a notary", which is a materially smaller claim.
     */
    /**
     * @notice Admit a notary to the anonymity set.
     * @param notaryCommitment_ `Poseidon(notary_secret)` - the leaf key `notary_action` derives
     *        from the secret it proves knowledge of. The secret NEVER appears on-chain.
     * @param notaryDataHash_ the register entry's leaf, as backend/cre/notary_registry builds it:
     *        keccak(keccak(regNumber), keccak(fullName), keccak(region), keccak(status)). Each field
     *        is hashed FIRST so every part is fixed-width - a bare concatenation let reg "12" with
     *        name "3X" collide with reg "123" with name "X" (sec. 2.18ao).
     * @param registryId_ which RegistrySourceAnchor snapshot to prove against
     * @param registryProof_ Merkle proof of `notaryDataHash_` in that snapshot's active root
     *
     * REGISTRATION STAYS PUBLIC AND VERIFIED, DELIBERATELY. It would have been easy to let the
     * postman simply assert a commitment and call the result private - and that would have QUIETLY
     * WEAKENED the system, because the old address-based path proved the register entry against the
     * CRE-anchored root and so could not invent a notary. That check is kept here, unchanged. The
     * privacy is bought at ACTION time instead, where `notary_action` proves membership in this
     * tree in zero knowledge. Public admission plus anonymous action is the standard ASP shape, and
     * it is strictly stronger than trusting the postman not to lie.
     *
     * The postman gate is retained on top for the reason it always existed: the Merkle proof shows
     * the REGISTER ENTRY is genuine, not that this commitment belongs to that notary. Binding those
     * two remains the out-of-band step the contract-level OPEN GAP note describes - unchanged in
     * kind by this work, and unchanged in trust boundary (still exactly one assumption, whoever the
     * registry's postman is).
     */
    function registerNotary(
        bytes32 notaryCommitment_,
        bytes32 notaryDataHash_,
        bytes32 registryId_,
        bytes32[] calldata registryProof_
    ) external {
        if (!NOTARY_REGISTRY.hasRole(NOTARY_REGISTRY.NOTARY_REGISTRAR(), msg.sender)) revert OnlyNotaryRegistrar();
        if (notaryCommitment_ == bytes32(0) || notaryDataHash_ == bytes32(0)) revert ZeroNotaryIdentity();
        // TRAP FOR WHOEVER IMPLEMENTS ANONYMOUS ENROLMENT (sec. 2.18bm, task #16): this entire check
        // MOVES INTO THE CIRCUIT, and `notaryDataHash_` and `registryProof_` leave the ABI with it.
        // They cannot merely be hidden - `notaryDataHash_` is `keccak(regNumber, fullName, region,
        // status)` over a PUBLIC register, so anyone can compute it for every notary in the country
        // and match. Its presence in CALLDATA is the leak, so the parameter has to go, not the
        // getter. Leaving this verify here "as well, for safety" would reinstate the disclosure the
        // circuit was built to remove.
        if (!MerkleProof.verify(registryProof_, NOTARY_REGISTRY.latestActiveRoot(registryId_), notaryDataHash_)) {
            revert NotaryNotActive();
        }

        // Value 0 == STATUS_CLEAN, the value notary_action proves inclusion at.
        _notaryTree.add(notaryCommitment_, bytes32(0));
        notaryRootCreatedAt[_notaryTree.getRoot()] = block.timestamp;
        emit NotaryRegistered(notaryCommitment_, registryId_);
    }

    /**
     * @notice Revoke a notary. THIS IS THE ENTIRE FAULT MECHANISM - see sec. 2.18am.
     * @param predicate_ non-zero reason code written into the leaf
     *
     * No identity is opened, because nothing needs opening. Writing a non-zero value makes every
     * STATUS_CLEAN inclusion proof for that leaf impossible, so the notary silently stops being able
     * to act. That is what Privacy Pools does to a bad actor - exclusion, not exposure - and it is
     * why the "quorum of custodians" this design once contemplated turned out to be answering a
     * question the architecture does not ask.
     */
    function revokeNotary(bytes32 notaryCommitment_, bytes32 predicate_) external {
        if (!NOTARY_REGISTRY.hasRole(NOTARY_REGISTRY.NOTARY_REGISTRAR(), msg.sender)) revert OnlyNotaryRegistrar();
        if (predicate_ == bytes32(0)) revert ZeroNotaryIdentity(); // zero IS the clean status

        _notaryTree.update(notaryCommitment_, predicate_);
        notaryRootCreatedAt[_notaryTree.getRoot()] = block.timestamp;
        emit NotaryRevoked(notaryCommitment_, predicate_);
    }

    /// @notice Current root of the notary anonymity set - what a prover builds a witness against.
    function notaryRoot() external view returns (bytes32) {
        return _notaryTree.getRoot();
    }

    /// @notice Inclusion witness for a notary commitment, for building a `notary_action` witness.
    /// @dev Taken from the REAL tree rather than rebuilt off-chain - the rule identityProof.ts and
    ///      withdrawWitness.ts already follow, so a client can never prove against a tree of its own
    ///      imagining.
    function notaryProof(bytes32 notaryCommitment_)
        external
        view
        returns (SparseMerkleTree.Proof memory)
    {
        return _notaryTree.getProof(notaryCommitment_);
    }

    /// @notice Mint a new title entry. `notarySignature_` must be from `notary_` over the entry's
    /// legal metadata; `notary_` must currently be bound (see bindNotaryAddress) to a leaf that is
    /// a member of the CURRENTLY ACTIVE snapshot for `notaryRegistryId_` (proven by
    /// `notaryMerkleProof_` against RegistrySourceAnchor.latestActiveRoot - the same
    /// keccak/MerkleProof-compatible tree backend/cre/notary_registry builds).
    function mintTitle(
        bytes32 propertyKey_,
        bytes32 jurisdiction_,
        uint256 priorTitleId_,
        bytes32 notaryRegistryId_,
        bytes32 notaryRoot_,
        bytes calldata notaryProof_,
        bytes32 initialHolderCommitment_
    ) external returns (uint256 titleId_) {
        if (initialHolderCommitment_ == bytes32(0)) revert ZeroCommitment();
        if (propertyKey_ == bytes32(0)) revert ZeroPropertyKey();

        _requireActiveNotary(
            notaryRoot_,
            notaryProof_,
            keccak256(
                abi.encodePacked(
                    "TITLE_LEDGER_MINT", address(this), propertyKey_, jurisdiction_, priorTitleId_
                )
            )
        );

        _requireUntitledOrValidSuccession(propertyKey_, priorTitleId_);

        titleId_ = nextTitleId++;
        titles[titleId_] = TitleEntry({
            propertyKey: propertyKey_,
            jurisdiction: jurisdiction_,
            priorTitleId: priorTitleId_,
            notaryRegistryId: notaryRegistryId_,
            mintedAt: block.timestamp,
            encumbered: false
        });
        holderCommitment[titleId_] = initialHolderCommitment_;
        titleOfProperty[propertyKey_] = titleId_;

        emit TitleMinted(titleId_, jurisdiction_, initialHolderCommitment_);
    }

    /// @notice Add a restriction legend to an existing title (e.g. "subject to mortgage", "life
    /// estate") - mutable and per-entry, unlike a fungible balance which can't distinguish
    /// restricted from unrestricted units. Requires the SAME currently-active-notary check as
    /// minting; does not require the holder's proof (a lien can be recorded against a title the
    /// notary is attesting to independent of who currently holds it, mirroring how a real
    /// county recorder files an encumbrance).
    function addLegend(
        uint256 titleId_,
        string calldata legend_,
        bytes32 notaryRoot_,
        bytes calldata notaryProof_
    ) external {
        TitleEntry storage entry = titles[titleId_];
        if (entry.mintedAt == 0) revert TitleDoesNotExist();

        // ANY ACTIVE NOTARY, NOT THE ONE WHO MINTED (sec. 2.18am, user decision 2026-07-31).
        // Requiring the original would have meant storing a commitment to them, which is a
        // PERSISTENT PSEUDONYM: every title one notary touched becomes linkable, so a single
        // deanonymisation exposes their whole history - and the threat model here is notaries being
        // punished. It also removed a liveness trap, where a revoked or unavailable minting notary
        // left a title permanently unamendable. This matches the county-recorder analogy the
        // function already used: a different clerk can file an encumbrance.
        //
        // Domain-separated from mintTitle's context (different prefix, different fields) - one
        // operation's authorisation must never be replayable as another's. See
        // HolderRegistration.revokeDocumentViaSigner for the same lesson, found the hard way in
        // this fusion's own registration flow.
        _requireActiveNotary(
            notaryRoot_,
            notaryProof_,
            keccak256(abi.encodePacked("TITLE_LEDGER_LEGEND", address(this), titleId_, legend_))
        );

        restrictionLegends[titleId_].push(legend_);
        emit LegendAdded(titleId_, legend_);
    }

    /// @notice Mark/clear a title as encumbered (e.g. a lending protocol placing/releasing a
    /// lien). Gated exactly like addLegend - a bare boolean with no authorization check would let
    /// anyone lock (or fraudulently clear) an encumbrance on someone else's title.
    function setEncumbered(
        uint256 titleId_,
        bool encumbered_,
        bytes32 notaryRoot_,
        bytes calldata notaryProof_
    ) external {
        TitleEntry storage entry = titles[titleId_];
        if (entry.mintedAt == 0) revert TitleDoesNotExist();

        // Any active notary - see addLegend for why binding to the minting notary was rejected.
        _requireActiveNotary(
            notaryRoot_,
            notaryProof_,
            keccak256(abi.encodePacked("TITLE_LEDGER_ENCUMBER", address(this), titleId_, encumbered_))
        );

        entry.encumbered = encumbered_;
        emit EncumbranceSet(titleId_, encumbered_);
    }

    /// @notice Transfer registered holdership. Requires a ZK proof (pp::title_holder) that the
    /// caller knows an sk_identity whose title-specific commitment matches the CURRENTLY recorded
    /// one - possession of the title's metadata/knowledge of its ID alone never suffices, mirroring
    /// CyberCorps' "no change in record ownership shall be deemed to occur solely by virtue of any
    /// transfer... among addresses" principle, implemented here via a proof instead of an
    /// admin-authorized metadata edit.
    function transferTitle(uint256 titleId_, bytes32 newHolderCommitment_, bytes calldata proof_) external {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        if (newHolderCommitment_ == bytes32(0)) revert ZeroCommitment();
        if (!_verifyHolderProof(titleId_, proof_)) revert InvalidHolderProof();

        bytes32 old = holderCommitment[titleId_];
        holderCommitment[titleId_] = newHolderCommitment_;
        emit TitleTransferred(titleId_, old, newHolderCommitment_);
    }

    /// @notice Read-only collateral-eligibility check: does `proof_` demonstrate control of
    /// `titleId_`'s CURRENT holder commitment, without transferring anything? This is the hook a
    /// lending protocol calls (or has the borrower call and relays) before disbursing a loan -
    /// disbursement itself should go through a Privacy Pool deposit using a borrower-supplied
    /// precommitment, kept entirely outside this contract, so the loan is never linkable to
    /// whoever produced this proof.
    function verifyHolderProof(uint256 titleId_, bytes calldata proof_) external view returns (bool) {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        return _verifyHolderProof(titleId_, proof_);
    }

    function getRestrictionLegends(uint256 titleId_) external view returns (string[] memory) {
        return restrictionLegends[titleId_];
    }

    /// @notice Explicit getter for the full entry - not relying on the auto-generated `titles(id)`
    /// tuple getter's exact field ordering/inclusion rules for a struct containing a `string`
    /// member, which is easy to get subtly wrong at a call site without a compiler to check it.
    function getTitle(uint256 titleId_) external view returns (TitleEntry memory) {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        return titles[titleId_];
    }

    function _verifyHolderProof(uint256 titleId_, bytes calldata proof_) internal view returns (bool) {
        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = holderCommitment[titleId_];
        publicInputs[1] = bytes32(titleId_);
        return TITLE_HOLDER_VERIFIER.verify(proof_, publicInputs);
    }

    /**
     * ONE PROPERTY, ONE TITLE - unless this is a genuine succession, in which case it must cite the
     * title it replaces.
     *
     * Its own function because `mintTitle` already carries nine parameters and adding a local here
     * overflowed the stack. Keeping it separate also puts the invariant somewhere nameable.
     *
     * Without the succession branch this would block every legitimate reissue and transfer of
     * title. Without the check itself, the same land could be titled twice over with nothing able
     * to detect it - which is precisely what a per-holder SALT on the description would have caused,
     * since two salted commitments over one property look unrelated.
     */
    function _requireUntitledOrValidSuccession(bytes32 propertyKey_, uint256 priorTitleId_) internal view {
        uint256 existing_ = titleOfProperty[propertyKey_];
        if (existing_ != 0 && priorTitleId_ != existing_) {
            revert PropertyAlreadyTitled(propertyKey_, existing_);
        }
        // A successor may not cite a prior title over a DIFFERENT property - that would launder one
        // property's chain of title into another's.
        if (priorTitleId_ != 0 && titles[priorTitleId_].propertyKey != propertyKey_) {
            revert PriorTitleIsForAnotherProperty(priorTitleId_);
        }
    }

    /**
     * THREE things must hold, and they fail independently on purpose:
     *   1. the signing key is bound to an identity;
     *   2. that identity STILL HOLDS A CURRENT DOCUMENT - a notary whose passport was revoked or
     *      expired stops being able to act, which is the whole point of making them an identity;
     *   3. the identity's registry entry is in the CURRENTLY ACTIVE scraped snapshot.
     * Losing notary status and losing identity status are different events, so they are checked
     * separately rather than collapsed into one flag somebody has to remember to clear.
     */
    /**
     * @notice The context a notary's identity proof must commit to. Exposed so the notary can build
     *         the proof off-chain against the exact value this contract will check.
     * @dev Reduced modulo the field because it is a circuit input, not a keccak digest.
     */
    function notaryBindContext(bytes32 notaryDataHash_, address signingKey_) public pure returns (bytes32) {
        return bytes32(
            uint256(keccak256(abi.encodePacked("TITLE_LEDGER_NOTARY_BIND", notaryDataHash_, signingKey_)))
                % 21888242871839275222246405745257275088548364400416034343698204186575808495617
        );
    }

    /**
     * @dev Require that SOME active notary authorised `actionMessage_`, without learning which.
     *
     * THE ACTION CONTEXT IS SUBSTITUTED, NOT COMPARED (sec. 2.18ah). `notary_action` leaves
     * `action_context` unconstrained - there is nothing to check in-circuit, because its meaning
     * lives entirely in data only this contract holds. So the value handed to the verifier is
     * DERIVED HERE from the action, and the prover's own is never read. That is what binds a proof
     * to one operation on one title.
     *
     * The shape matters as much as the arithmetic. Comparing would have worked identically today
     * and been DELETABLE: remove the check and every test but one still passes while proofs become
     * replayable across actions. Passing the derived value as an argument means there is no line
     * whose removal silently weakens anything - delete the derivation and this does not compile.
     *
     * @param actionMessage_ a caller-built, already domain-separated keccak hash. Each call site
     *        builds its own with its own prefix; this function never fabricates one, so two
     *        different operations can never resolve to the same context.
     */
    function _requireActiveNotary(bytes32 notaryRoot_, bytes calldata proof_, bytes32 actionMessage_)
        internal
        view
    {
        if (!isValidNotaryRoot(notaryRoot_)) revert UnknownNotaryRoot();

        bytes32[] memory publicInputs_ = new bytes32[](2);
        publicInputs_[0] = notaryRoot_;
        // Reduced into the field the circuit works over; a raw keccak output can exceed it, and
        // silently wrapping would make two different actions share a context.
        publicInputs_[1] = bytes32(uint256(actionMessage_) % Constants.SNARK_SCALAR_FIELD);

        if (!NOTARY_ACTION_VERIFIER.verify(proof_, publicInputs_)) revert NotaryNotActive();
    }

    /**
     * @notice Whether `root_` may still be proven against.
     * @dev The identity registry's rule, for the identical reason (sec. 2.18o): the LATEST root is
     *      always valid however old, so operator inaction cannot freeze notaries out; a SUPERSEDED
     *      root is valid only briefly, because this tree carries revocations and honouring an old
     *      root indefinitely would let a revoked notary act forever. An unrecorded root maps to 0
     *      and must be REJECTED - the clause whose absence made every invented root valid in three
     *      separate copies of this rule.
     */
    function isValidNotaryRoot(bytes32 root_) public view returns (bool) {
        if (root_ == bytes32(0)) return false;
        if (root_ == _notaryTree.getRoot()) return true;

        uint256 createdAt_ = notaryRootCreatedAt[root_];
        return createdAt_ != 0 && createdAt_ + NOTARY_ROOT_VALIDITY > block.timestamp;
    }
}
