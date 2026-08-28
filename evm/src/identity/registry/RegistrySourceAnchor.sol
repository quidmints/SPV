// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

// 🔴 NOT UPGRADEABLE, AND THAT IS THE POINT OF THIS CONTRACT. Every bound below — append-only
//    publication, no re-pin, the 24-hour forwarder timelock, `onReport`'s fail-closed comparison —
//    lived inside an implementation that `OWNER_ROLE` could REPLACE IN ONE TRANSACTION via
//    `_authorizeUpgrade`. A timelock enforced by code the timelock-holder can swap is not a
//    timelock; it is a delay they may choose to observe. The blacklist root this anchors decides
//    who may withdraw from the pool, so an upgradeable anchor made the whole ownerless-root
//    argument circular.
// ⚠️ `AccessControl` (not `...Upgradeable`) and a real constructor: there is no proxy, so there is
//    no initialiser to front-run and nothing to `_disableInitializers` against.
import {AccessControl} from "@oz/access/AccessControl.sol";
import {IEvidenceRegistry} from "@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol";
import {IReceiver} from "../interfaces/registry/IReceiver.sol";
import {IERC165} from "@oz/utils/introspection/IERC165.sol";

/// @notice Anchors periodically-refreshed roots of external authoritative-source lists (e.g.
/// Ukraine's notary registry bulk XML/zip export from ern.minjust.gov.ua / data.gov.ua) into the
/// SAME ERC-7812 evidence registry rarime's identity state roots and PP's ASP root already anchor
/// into - one anchoring mechanism for every "public, authoritative government source" this fusion
/// consumes (the notary registry is the first; more are expected, hence keyed by `registryId`
/// rather than hardwired to one list). Mirrors Entrypoint.sol's updateRoot/latestActiveRoot
/// pattern deliberately (proven design in this codebase): an activation delay against
/// front-run/equivocation, and a write-once-per-index anchor into the evidence registry.
///
/// @dev Trust model: the LEAF SET is produced OFF-CHAIN by a Chainlink CRE workflow using
/// DON-consensus HTTP fetches - multiple independent CRE nodes fetch the SAME bulk export
/// independently and must agree bit-for-bit (cre.ConsensusIdenticalAggregation) before a report
/// is generated and written here (see backend/cre/notary_registry/main.go). But unlike an
/// earlier version of this contract, the ROOT is never trusted as a bare off-chain claim: the
/// full leaf set is submitted as calldata and the root is COMPUTED ON-CHAIN from it
/// (`_computeRoot`), so there is no way to publish a root that doesn't correspond to a real,
/// fully-available leaf set. Data availability is the transaction's own calldata/event log -
/// permanently replayable by any full node - not an external pinning service (an earlier design
/// used an IPFS CID for this; dropped as an unnecessary and less reliable dependency for data
/// that's cheap enough to just put on-chain). This is deliberately the SAME shape as an
/// OFAC-list oracle: a periodically-refreshed, cross-verified, fully self-contained snapshot of a
/// bulk export, not a live query endpoint.
///
/// @dev 🔴 NOT UPGRADEABLE — AND THIS PARAGRAPH USED TO ARGUE THE OPPOSITE, SO READ WHY IT WAS
/// WRONG BEFORE RESTORING THE PATTERN. It said UUPS "matches this codebase's convention for
/// registry/orchestration contracts that hold evolving records rather than custody funds directly
/// (Entrypoint, StateKeeper, RegistrationSimple all follow the same pattern; only PP's fund-custody
/// contracts - PrivacyPool/State - are deliberately immutable … not something a registry anchor
/// needs)."
///
/// The custody/registry split is a real distinction and it puts this contract on the WRONG side of
/// itself. This anchor does not hold funds; it decides WHOSE FUNDS MOVE. `PrivacyPool` substitutes
/// the blacklist root from here rather than reading it from a proof — deliberately, so a prover
/// cannot supply their own — which makes the root this publishes a precondition of every
/// withdrawal. A mutable anchor under an immutable pool is a trust-minimised vault reading from a
/// contract one key could rewrite, and the argument for the vault's immutability applies here with
/// the same force.
/// ⇒ The cost is real and accepted: a Chainlink forwarder rotation or a workflow change now needs a
/// redeploy, and since `PrivacyPool.BLACKLIST_ANCHOR` is `immutable`, that means redeploying the
/// pool too. That is the price of the root being ownerless in fact rather than by policy.
contract RegistrySourceAnchor is AccessControl, IReceiver {
    /**
     * THERE IS NO PUBLICATION ROLE. The gate is `forwarder` - an ADDRESS, set once - and this note
     * records what it replaced, because the history is the argument for it.
     *
     * `REGISTRY_POSTMAN` ONCE DID THREE JOBS. `TitleLedger.registerNotary` and `revokeNotary`
     * checked it too, on the sound-sounding reasoning that one auditable trust boundary beats two.
     * The effect was that a snapshot-submission role also decided **who is a notary** - which
     * `revokeNotary`'s own comment calls "THE ENTIRE FAULT MECHANISM". That was split out into
     * `NOTARY_REGISTRAR` below (sec. 2.18cn).
     *
     * SPLITTING IT WAS NOT ENOUGH. Even alone, the role was still GRANTABLE by any admin, to anyone,
     * at any time. Fixing publication to a single address chosen once narrows that to one decision
     * made once - see `forwarder` for what this does and does not buy, because it is less than it
     * first appears.
     */

    /**
     * NOTARY ADMINISTRATION ONLY - enrolment and revocation in `TitleLedger`.
     *
     * Declared HERE rather than in `TitleLedger` because that contract already reads its authority
     * from this registry (`NOTARY_REGISTRY.hasRole(...)`), so the role list stays in one place and
     * one admin governs both. It is a ROLE where publication is an ADDRESS because the two powers
     * differ in kind: publication is a machine relaying consensus, while revoking a notary is a
     * human decision that ends with somebody losing their ability to act.
     */
    bytes32 public constant NOTARY_REGISTRAR = keccak256("NOTARY_REGISTRAR");

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /**
     * The pinned CRE workflow, append-only (sec. 2.18bs).
     *
     * WHY THIS EXISTS. `ConsensusIdenticalAggregation` proves the DON nodes AGREE; it cannot prove
     * they are RIGHT (sec. 2.18ao). Verifying the register's TLS session INSIDE the workflow fixes
     * that - agreement becomes agreement on *"the register's own server served these bytes"* - but
     * only if the workflow that ran is the one that does the verifying. **Consensus protects against
     * a rogue NODE, never against a rogue WORKFLOW** (sec. 2.15a).
     *
     * NO NEW AUTHORITY, DELIBERATELY. Pinning is gated by the EXISTING `OWNER_ROLE`, not a bespoke
     * publisher role - the same reasoning `TitleLedger` used when it reused `REGISTRY_POSTMAN`
     * rather than minting an admin key: one trust boundary is auditable, two are a surface. What
     * makes this SAFE where that was not is that the power differs in kind - an owner here can only
     * name a hash-identified, publicly auditable artifact on an append-only list after a delay,
     * never publish data directly.
     *
     * APPEND-ONLY is the load-bearing property: a swap is permanently visible rather than a silent
     * substitution, so "which code produced this snapshot" is answerable for every past root.
     */
    struct WorkflowVersion {
        bytes32 workflowId; // deterministic wasm artifact hash
        uint64 pinnedAt;
        uint64 activeFrom;
    }

    /**
     * PINNED PER `registryId`, NOT GLOBALLY (sec. 2.18gz-wf).
     *
     * 🔴 IT WAS ONE LIST FOR THE WHOLE CONTRACT, AND THAT SILENTLY DISABLED EVERY REGISTRY BUT ONE.
     * `activeWorkflowId()` returned a single id — the newest activated — and `onReport` demanded
     * equality, so exactly one workflow could ever publish. But `cre/notary_registry` and
     * `cre/sanctions_lists` BOTH write on-chain, as separate binaries with separate ids. Pinning
     * one made every report from the other revert `UnpinnedWorkflow`, days later, as "the sanctions
     * root stopped updating".
     * ⇒ It also contradicted this contract's own header, which says snapshots are keyed by
     * `registryId` *"rather than hardwired to one list"* because *"more are expected"*. The data
     * model was many registries; the workflow gate was one. Now both are per-registry.
     */
    mapping(bytes32 => WorkflowVersion[]) public workflowVersions;

    event WorkflowPinned(bytes32 indexed registryId, bytes32 indexed workflowId, uint256 index, uint64 activeFrom);
    /// @notice Carries the PREVIOUS address too, so a re-point is visible as a re-point rather than
    ///         having to be inferred from a second identical-looking event.
    event ForwarderSet(address indexed previousForwarder, address indexed forwarder);
    /// Emitted when a change is PROPOSED. The window between this and `ForwarderSet` is the whole
    /// point: a watcher sees the re-point coming instead of finding it already done.
    event ForwarderProposed(address indexed activeForwarder, address indexed proposed, uint64 activeFrom);

    error ZeroWorkflowId();
    error WorkflowAlreadyPinned(bytes32 workflowId);
    error NoActiveWorkflow();
    error UnpinnedWorkflow(bytes32 reported, bytes32 active);
    error MalformedReportMetadata(uint256 length);
    /// @notice Only the Forwarder may deliver reports.
    error NotForwarder(address caller);
    error ForwarderUnchanged(address forwarder);

    /**
     * Where the workflow ID sits in the metadata header CRE prepends to every report.
     *
     * NOT A GUESSED OFFSET. This is `chainlink-common pkg/capabilities/consensus/ocr3/types.Metadata`
     * as documented in the SDK this repo actually depends on
     * (cre-sdk-go v1.15.0, `cre/report_fields.go`): version 1 || executionId 32 || timestamp 4 ||
     * donId 4 || donConfigVersion 4 || **workflowId 32** || workflowName 10 || workflowOwner 20 ||
     * reportId 2 = 109. Decoding this wrong would reject VALID reports, so the length is CHECKED
     * rather than assumed and its failure is named rather than silent.
     */
    uint256 public constant REPORT_METADATA_LENGTH = 109;
    uint256 public constant REPORT_WORKFLOW_ID_OFFSET = 45;

    /// Same window Entrypoint.sol uses for ASP roots - gives verifiers/watchers a chance to catch
    /// a bad snapshot before anything can be proven against it.
    uint256 public constant ROOT_ACTIVATION_DELAY = 1 hours;

    /**
     * How long a newly pinned workflow waits before snapshots may cite it (sec. 2.18bs).
     *
     * THE ONE THING A TIMELOCK IS ACTUALLY FOR HERE. Once each DON node verifies the register's TLS
     * session inside the workflow, fabricated DATA becomes impossible rather than merely detectable -
     * so the snapshot path needs no contest window.
     *
     * AND A SWAP IS NOT WHAT THIS DEFENDS AGAINST - an earlier version of this comment claimed "a
     * workflow SWAP cannot be prevented cryptographically, only seen", which was true only because
     * `onReport` DISCARDED the metadata naming the workflow. It no longer does: a report is now
     * checked against the active pin, so a swapped workflow is REJECTED rather than watched. What is
     * left for a delay is the only thing it was ever suited to - the AUTHORISED RE-PIN. Changing
     * which code the anchor believes is a governance act, and this is the interval in which that act
     * is visible and contestable before anything relies on it. Without it the update mechanism is a
     * same-block censorship lever.
     */
    uint256 public constant WORKFLOW_ACTIVATION_DELAY = 24 hours;

    /**
     * How long a newly proposed Forwarder waits before `onReport` will accept it (sec. 2.18gz-fwd).
     *
     * 🔴 WHY THIS EXISTS: `setForwarder` WAS THE UNGUARDED TWIN OF `pinWorkflow`, AND IT WAS THE
     * TOTAL BYPASS. Every mitigation §2.15a landed went on the workflow axis - append-only, no
     * re-pin, a 24-hour delay, fail-open to the predecessor - and this path got none of them. The
     * surviving attack was ONE transaction: re-point `forwarder` at an EOA, then have it call
     * `onReport` citing the genuinely pinned workflow id, with any root. The contract could not see
     * it, because what it checks is which ADDRESS called, and that address had just been chosen.
     *
     * ⚠️ AND IT CAPPED THE WHOLE DON STORY AT ONE KEY. `notary_registry/main.go` claims *"no single
     * operator can substitute a tampered registry snapshot"*; what the code enforced was "not
     * without emitting an event and waiting an hour" - detection where prevention is claimed, no
     * matter how many nodes fetch.
     *
     * ⛔ THE STRONGER FIX IS NOT AVAILABLE, AND THE REASON IS IN THIS FILE. §2.18cp preferred
     * verifying DON signatures here; `forwarder`'s own docblock explains why that cannot be built -
     * THE SIGNATURES NEVER ARRIVE. `onReport(bytes,bytes)` is the entire surface and the metadata is
     * a fixed 109-byte header with no room for a signature set. Write-once is also ruled out: it was
     * tried, and it broke Chainlink's documented simulation-to-production migration (sec. 2.18fg).
     * ⇒ A TIMELOCK IS WHAT IS LEFT, and it is the same instrument `pinWorkflow` already uses for the
     * same kind of act - changing which code, or which address, this anchor believes.
     */
    uint256 public constant FORWARDER_ACTIVATION_DELAY = 24 hours;

    // Same BN254/SNARK scalar field every other statement key in this fusion is reduced into
    // (Entrypoint._aspStatementKey, EvidenceRegistry.BABY_JUB_JUB_PRIME_FIELD) - duplicated
    // locally rather than imported cross-module, matching this codebase's existing convention.
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct RegistrySnapshot {
        /// keccak sorted-pair root, COMPUTED here from the submitted leaves (`_computeRoot`).
        bytes32 root;
        /**
         * Poseidon SMT root over the same leaves — **CLAIMED, not computed** (sec. 2.18db, decided
         * by measurement 2026-08-24).
         *
         * 🔴 WHY IT CANNOT BE COMPUTED, AND WHY THAT IS NOT A TRUST CONCESSION.
         * `test/registry/SanctionsRootHashCost.t.sol` measures a Poseidon pair hash at **29,113
         * gas** against keccak's **239** — **121×**. A tree over N leaves is N−1 pair hashes, so the
         * OFAC SDN at ~17,000 entries would cost **494,891,887 gas**: roughly **16.5 whole Ethereum
         * blocks**. Even 1,000 leaves is a full block. There is no version of computing this on
         * chain.
         * ⇒ **SO IT IS ANCHORED AND CHECKED, RATHER THAN DERIVED.** The full leaf set is in this
         * transaction's calldata and its event, so anyone can rebuild the SMT off-chain and show a
         * wrong root, and `ROOT_ACTIVATION_DELAY` is the window in which to do it. **Not-computed is
         * not the same as not-verified**, and conflating those is how this gets reopened as a
         * trust regression.
         * ⚠️ It exists because a keccak sorted-pair tree **cannot support non-membership proofs**:
         * `_hashSortedPair` is commutative, so a path never reveals whether a sibling sat left or
         * right, and adjacency — the whole content of a sorted-tree absence proof — is unprovable.
         * The blacklist predicate is EXCLUSION, so it needs a structure that can prove absence.
         * ⚠️ **ZERO IS LEGAL AND MEANS EMPTY**, matching `blacklistRoot`'s polarity: an empty exclusion
         * set admits everyone, so a publisher who goes quiet cannot censor. It is also the bootstrap
         * state and the fail-open failure mode in one, which is why it is emitted rather than
         * silently defaulted.
         */
        bytes32 smtRoot;
        uint256 timestamp;
    }

    // ⭐ `immutable` NOW, AND THE OLD COMMENT HERE ARGUED THE OPPOSITE FOR A REASON THAT NO LONGER
    // HOLDS. It said config belongs in initializer-set state because "one implementation contract
    // can serve many proxy instances", and conceded the address is "set once at initialize() and
    // never changed again in practice, even though the language doesn't enforce that the way
    // `immutable` would". There are no proxy instances any more, so the language enforces it.
    IEvidenceRegistry public immutable EVIDENCE_REGISTRY;

    mapping(bytes32 => RegistrySnapshot[]) public snapshots;

    /**
     * @notice The CRE Forwarder, and the ONLY address `onReport` accepts.
     *
     * @dev THIS REPLACES A GRANTABLE ROLE. `REGISTRY_POSTMAN` was meant to end up held by a
     *      Forwarder, but nothing STOPPED it being granted to a person, or to several. An address
     *      narrows that to exactly one holder at a time. It is NOT write-once - see `setForwarder`
     *      for why that was wrong.
     *
     *      WHY NOT VERIFY DON SIGNATURES HERE INSTEAD, which sec. 2.18cp called the stronger option:
     *      THE SIGNATURES NEVER ARRIVE. `onReport(bytes metadata, bytes report)` is the entire
     *      surface, and the metadata is a fixed 109-byte header - version, executionId, timestamp,
     *      donId, donConfigVersion, workflowId, workflowName, workflowOwner, reportId - with no room
     *      for a signature set. A contract cannot check what it is not given, so 2.18cp preferred
     *      something this interface does not offer.
     *
     *      ⚠️ AN EARLIER VERSION OF THIS COMMENT SAID "no Forwarder contract, interface or ABI
     *      exists anywhere in this repository, so that is unverified here" - and drew the conclusion
     *      that the Forwarder might be a plain EOA. **That was a repo-scoped search standing in for a
     *      fact about Chainlink.** `KeystoneForwarder` is a Chainlink-operated CONTRACT, and per
     *      their documentation it VALIDATES THE REPORT'S DON SIGNATURES and only then calls
     *      `onReport` on the receiver. Absence from this tree said nothing about its existence.
     *      (Corrected 2026-08-07 after the same mistake was repeated in conversation; sec. 2.18fg.)
     *
     *      SO THE HONEST CLAIM, RESTATED: if this address is the real `KeystoneForwarder`, DON
     *      consensus IS checked - upstream of here, by it, not by us. What this contract still cannot
     *      tell is WHICH address it was given, so the guarantee is conditional on `setForwarder`
     *      having been pointed at the genuine deployment. Verify it against Chainlink's Forwarder
     *      Directory for the target chain before calling.
     *
     *      APPENDED, NOT INSERTED — and the REASON changed even though the rule did not. This used
     *      to say "UUPS-upgradeable and has no storage gap", i.e. a new variable at the front would
     *      shift every slot a successor implementation reads. There is no successor now. What still
     *      forbids inserting is simpler: state layout is fixed at deployment, and reordering it
     *      means a DIFFERENT contract, so any insert has to be a redeploy and a migration rather
     *      than an edit.
     */
    address public forwarder;

    /**
     * The proposed Forwarder and the moment it becomes acceptable - APPENDED, per the storage note
     * on `forwarder` above (UUPS, no gap, so new variables may only go at the end).
     *
     * `forwarder` keeps its meaning: the address `onReport` accepts. These two are the pending
     * change; `activeForwarder()` resolves between them, and `onReport` folds an elapsed change
     * into `forwarder` on first use so the stored slot settles without anyone calling anything.
     */
    address public pendingForwarder;
    uint64 public pendingForwarderActiveFrom;

    /// Full leaf set for every published snapshot - the on-chain data-availability layer
    /// `_computeRoot`'s output is checked against. Anyone can rebuild and independently re-verify
    /// a Merkle proof against `snapshots[registryId][index].root` using this array directly, with
    /// no external fetch of any kind.
    event SnapshotLeaves(bytes32 indexed registryId, uint256 indexed index, bytes32[] leaves);
    event SnapshotAnchored(
        bytes32 indexed registryId, bytes32 root, bytes32 smtRoot, uint256 index, bytes32 statementKey
    );

    error EmptyLeafSet();
    error LeavesNotStrictlySorted();
    error NoSnapshotsAvailable();
    error NoActiveSnapshot();
    error ZeroAddress();

    /// @notice Deployment-time config, permanently. Was `initialize(...)` behind a UUPS proxy.
    /// @dev ⛔ `_authorizeUpgrade` IS DELETED WITH THE PROXY — do not reintroduce either. What it
    ///      gated was not "which implementation runs" in the abstract; it was every guarantee this
    ///      contract makes about how a blacklist root may be published.
    constructor(address evidenceRegistry_, address admin_) {
        if (evidenceRegistry_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        EVIDENCE_REGISTRY = IEvidenceRegistry(evidenceRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OWNER_ROLE, admin_);
    }

    /// @notice Publish a fresh snapshot for `registryId_` (e.g. keccak256("UA_NOTARY_REGISTRY")).
    /// `leaves_` MUST be strictly ascending (matches backend/cre/notary_registry/main.go's own
    /// `sort.Slice` before computing its root) - cheaper to verify on-chain (O(n) comparisons)
    /// than to sort on-chain, and rejects duplicate leaves as a side effect. The root is computed
    /// here, not trusted from the caller - see the contract-level trust-model note. Never
    /// overwrites a prior snapshot - each publish appends, so history (and what was active at any
    /// past timestamp) is preserved, same as Entrypoint's association sets.
    /**
     * @notice Pin the CRE workflow whose output this anchor accepts.
     * @dev Append-only and timelocked; reuses OWNER_ROLE rather than adding a publisher authority.
     */
    function pinWorkflow(bytes32 registryId_, bytes32 workflowId_)
        external onlyRole(OWNER_ROLE) returns (uint256 index_)
    {
        if (workflowId_ == bytes32(0)) revert ZeroWorkflowId();
        WorkflowVersion[] storage versions_ = workflowVersions[registryId_];

        // Re-pinning the SAME id would reset its timelock, which is how a contested version gets
        // quietly re-armed. The list is append-only in both senses: nothing is removed, and nothing
        // already named can be renamed.
        for (uint256 i = 0; i < versions_.length; ++i) {
            if (versions_[i].workflowId == workflowId_) revert WorkflowAlreadyPinned(workflowId_);
        }

        index_ = versions_.length;
        uint64 activeFrom_ = uint64(block.timestamp + WORKFLOW_ACTIVATION_DELAY);
        versions_.push(
            WorkflowVersion({workflowId: workflowId_, pinnedAt: uint64(block.timestamp), activeFrom: activeFrom_})
        );
        emit WorkflowPinned(registryId_, workflowId_, index_, activeFrom_);
    }

    /**
     * @notice The workflow currently entitled to produce snapshots, or zero before the first one
     *         becomes active.
     * @dev FAILS OPEN TO THE LAST GOOD VERSION: a newly pinned version does not displace its
     *      predecessor until its delay elapses, so a swap cannot silence the registry in the
     *      meantime - inaction and a contested update both leave the previous version working.
     */
    /**
     * @notice Set or replace the CRE Forwarder address.
     *
     * @dev ⚠️ THIS WAS WRITE-ONCE UNTIL 2026-08-07, AND THAT WAS WRONG - not a trade-off that went
     *      the other way, but a misreading of how the Forwarder is deployed. Chainlink's own
     *      guidance is that **the forwarder address differs between environments**: deploy against
     *      the MockForwarder to simulate, then point at the real `KeystoneForwarder` for production,
     *      and their `ReceiverTemplate` exposes `setForwarderAddress()` precisely "to enable
     *      updating between environments without redeploying the consumer contract".
     *
     *      Write-once made the normal, documented lifecycle require a UUPS UPGRADE, and made a
     *      mistaken or rotated address unfixable by any lighter means. The previous comment argued
     *      write-once "removes the human key BY CONSTRUCTION"; it does not - `OWNER_ROLE` still
     *      holds the upgrade key, so the same human could always re-point this by upgrading. It only
     *      made the cheap path unavailable while leaving the expensive one open. See sec. 2.18fg.
     *
     *      WHAT STILL BOUNDS THIS: `OWNER_ROLE`, and the fact that a changed forwarder is announced
     *      by `ForwarderSet` with BOTH addresses, so a watcher sees a re-point rather than having to
     *      infer it.
     *
     *      THE ZERO CHECK STAYS, AND IS DELIBERATELY STRICTER THAN CHAINLINK'S TEMPLATE. Theirs
     *      reads `if (s_forwarderAddress != address(0) && msg.sender != s_forwarderAddress)`, i.e. an
     *      unset forwarder accepts EVERY caller. `onReport` here compares unconditionally, so an
     *      unset forwarder accepts NOBODY. Fail-closed is the right direction for a publication path
     *      and the template's default is not worth copying.
     */
    function setForwarder(address forwarder_) external onlyRole(OWNER_ROLE) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        // Re-proposing the CURRENT forwarder would reset nothing and mean nothing, but re-proposing
        // a PENDING one would restart its clock - the same quiet-re-arm `pinWorkflow` refuses. Both
        // are rejected by comparing against the address that is actually in force.
        if (forwarder_ == activeForwarder()) revert ForwarderUnchanged(forwarder_);

        // THE FIRST ONE IS IMMEDIATE, AND THAT IS NOT A HOLE. The timelock protects an INCUMBENT:
        // it exists so a re-point cannot take over publication in the same block. Before any
        // forwarder exists there is no incumbent, nothing has been anchored, and an OWNER_ROLE
        // holder at that moment owns a contract with nothing in it. `forwarder` only ever moves
        // from zero once, so this branch is unreachable after deployment.
        if (forwarder == address(0)) {
            emit ForwarderSet(address(0), forwarder_);
            forwarder = forwarder_;
            return;
        }

        pendingForwarder = forwarder_;
        pendingForwarderActiveFrom = uint64(block.timestamp + FORWARDER_ACTIVATION_DELAY);
        emit ForwarderProposed(activeForwarder(), forwarder_, pendingForwarderActiveFrom);
    }

    /**
     * @notice The address `onReport` accepts right now.
     *
     * @dev FAILS OPEN TO THE PREDECESSOR, exactly as `activeWorkflowId` does: a proposed forwarder
     *      does not displace the working one until its delay elapses, so a re-point cannot silence
     *      the registry in the meantime. Inaction and a contested change both leave publication
     *      running on the previous address.
     *
     * @dev THE STORED SLOT SETTLES ITSELF, so there is no promotion call and nothing to forget.
     *      `onReport` folds an elapsed change into `forwarder` the first time the new address
     *      publishes - the gas falls on the party that benefits. An earlier version had a separate
     *      permissionless `promoteForwarder` with two error types of its own, for a job the
     *      publication path already passes through.
     *
     * @dev ⚠️ ZERO UNTIL THE FIRST `setForwarder`, and `onReport` compares unconditionally, so an
     *      unset forwarder accepts NOBODY - fail-closed, and stricter than Chainlink's template,
     *      which accepts EVERY caller while unset. The first set takes effect immediately (see
     *      `setForwarder`); every one after it is timelocked.
     */
    function activeForwarder() public view returns (address) {
        if (pendingForwarder != address(0) && block.timestamp >= pendingForwarderActiveFrom) {
            return pendingForwarder;
        }
        return forwarder;
    }

    /**
     * @notice ERC-165, and it is what makes the CRE path work AT ALL.
     *
     * @dev The Forwarder probes this before delivering: "The KeystoneForwarder uses ERC165 to check
     *      if your contract supports the IReceiver interface before sending a report." Without it the
     *      probe answers false and no report is ever delivered - silently, with nothing reverting.
     *      That is why this is not cosmetic conformance. See sec. 2.18fg.
     */
    function supportsInterface(bytes4 interfaceId_)
        public
        view
        override(AccessControl, IERC165)
        returns (bool)
    {
        return interfaceId_ == type(IReceiver).interfaceId || super.supportsInterface(interfaceId_);
    }

    function activeWorkflowId(bytes32 registryId_) public view returns (bytes32) {
        WorkflowVersion[] storage versions_ = workflowVersions[registryId_];
        for (uint256 i = versions_.length; i > 0; --i) {
            WorkflowVersion storage v_ = versions_[i - 1];
            if (v_.activeFrom <= block.timestamp) return v_.workflowId;
        }
        return bytes32(0);
    }

    function workflowVersionCount(bytes32 registryId_) external view returns (uint256) {
        return workflowVersions[registryId_].length;
    }

    /// @notice CRE report-callback entrypoint: decodes a (bytes32 registryId, bytes32[] leaves)
    /// payload and publishes it - but ONLY if the report says it came from the pinned workflow.
    ///
    /// @dev THE PIN IS ENFORCED HERE, AND UNTIL IT WAS, IT WAS NOT ENFORCED ANYWHERE. `metadata`
    /// carries the workflow ID, and this function used to discard it with the note "intentionally
    /// unused; `onlyRole(REGISTRY_POSTMAN)` already gates who may call this". That reasoning gates
    /// the CALLER and says nothing about the CODE: the Forwarder relays whatever the DON ran, so
    /// every report from every workflow arrived from the same authorised address, and
    /// `_publishSnapshot`'s check that SOME workflow is active is a LIVENESS test, not an IDENTITY
    /// one. A swapped workflow would have published successfully. Comparing the reported ID to the
    /// active pin is what makes `pinWorkflow` load-bearing rather than - in this contract's own
    /// words - decoration.
    ///
    /// AND IT IS NOW THE ONLY ENTRYPOINT. `publishSnapshot` was deleted (sec. 2.18ct): it did the
    /// same job MINUS this check, so it was simultaneously a duplicate mechanism and the one path no
    /// pin constrained. Removing it deletes a moving part and closes the bypass in one act - which is
    /// why it was the right answer rather than gating it harder.
    ///
    /// @dev THE CALLING CONVENTION IS NOW CONFIRMED, and this comment used to say it was not - it
    /// advised granting `REGISTRY_POSTMAN` to the Forwarder "once that is verified, or to an operator
    /// key as a manual bootstrap in the meantime". That role no longer exists, and the convention is
    /// documented by Chainlink: the Forwarder ERC-165-probes the receiver for `IReceiver`, then calls
    /// `onReport(bytes metadata, bytes report)` with no return value. Both are now implemented -
    /// `supportsInterface` and this signature - so the bootstrap advice is obsolete AND the probe it
    /// never mentioned was the thing actually blocking delivery. See sec. 2.18fg.
    ///
    /// The metadata LAYOUT is confirmed separately (see REPORT_METADATA_LENGTH) against the CRE SDK
    /// this repo depends on, rather than assumed.
    /// @dev RETURNS NOTHING, because `IReceiver` declares `function onReport(bytes,bytes) external;`
    /// with no return values and this contract now implements that interface. It previously returned
    /// `(index_, root_)`, which was invisible to the Forwarder anyway - a report arrives by
    /// transaction, so there is no caller in a position to read a return value. Callers that want
    /// the result read `snapshots[registryId]` or the `SnapshotAnchored` event, both of which are
    /// what an off-chain consumer has to use regardless.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        address activeFwd_ = activeForwarder();
        if (msg.sender != activeFwd_) revert NotForwarder(msg.sender);
        // Fold an elapsed re-point into storage on first use, so `forwarder` and the effective gate
        // do not drift apart. Costs the new forwarder one write, once.
        if (activeFwd_ != forwarder) {
            emit ForwarderSet(forwarder, activeFwd_);
            forwarder = activeFwd_;
            pendingForwarder = address(0);
            pendingForwarderActiveFrom = 0;
        }

        // Length-checked before slicing: a short header would otherwise read whatever follows it,
        // and an identity check that compares the WRONG 32 bytes fails in exactly the direction
        // that looks like a healthy rejection.
        if (metadata.length < REPORT_METADATA_LENGTH) revert MalformedReportMetadata(metadata.length);

        // DECODED BEFORE THE WORKFLOW CHECK, because the pin is per-`registryId` and the registry is
        // in the report rather than the header. Decoding is not a trust step - the authorization is
        // the forwarder comparison above, and the workflow check is still what gates publication.
        (bytes32 registryId_, bytes32 smtRoot_, bytes32[] memory leavesMem_) =
            abi.decode(report, (bytes32, bytes32, bytes32[]));

        bytes32 reported_ = bytes32(metadata[REPORT_WORKFLOW_ID_OFFSET:REPORT_WORKFLOW_ID_OFFSET + 32]);
        bytes32 active_ = activeWorkflowId(registryId_);
        if (active_ == bytes32(0)) revert NoActiveWorkflow();
        if (reported_ != active_) revert UnpinnedWorkflow(reported_, active_);

        _publishSnapshot(registryId_, smtRoot_, leavesMem_);
    }

    /// @dev Kept separate from `onReport` so the authorization and the publication read as distinct
    /// steps. Takes `memory` because `onReport`'s array is already decoded.
    function _publishSnapshot(
        bytes32 registryId_,
        bytes32 smtRoot_,
        bytes32[] memory leaves_
    ) internal returns (uint256 index_, bytes32 root_) {
        // A PIN NOTHING CHECKS IS DECORATION. The whole point of naming the workflow is that
        // snapshots are attributable to auditable code, so publishing must be impossible until a
        // version is active. Without this line `pinWorkflow` would be a public statement of intent
        // with no bearing on what the anchor accepts - the shape sec. 2.18bg calls theatre.
        if (activeWorkflowId(registryId_) == bytes32(0)) revert NoActiveWorkflow();

        root_ = _computeRoot(leaves_);

        snapshots[registryId_].push(RegistrySnapshot(root_, smtRoot_, block.timestamp));
        index_ = snapshots[registryId_].length - 1;

        bytes32 statementKey_ = _statementKey(registryId_, index_);
        EVIDENCE_REGISTRY.addStatement(statementKey_, root_);

        emit SnapshotLeaves(registryId_, index_, leaves_);
        emit SnapshotAnchored(registryId_, root_, smtRoot_, index_, statementKey_);
    }

    /// @notice Newest snapshot root for `registryId_`, regardless of activation delay
    /// (informational / dashboards only - verifiers must use `latestActiveRoot`).
    function latestRoot(bytes32 registryId_) external view returns (bytes32) {
        uint256 length_ = snapshots[registryId_].length;
        if (length_ == 0) revert NoSnapshotsAvailable();
        return snapshots[registryId_][length_ - 1].root;
    }

    /// @notice The newest snapshot whose activation delay has elapsed - what a verifier should
    /// check membership against. Mirrors Entrypoint.latestActiveRoot exactly.
    /**
     * @notice The Poseidon SMT root the blacklist predicate proves NON-MEMBERSHIP against.
     *
     * @dev Same activation rule as `latestActiveRoot` deliberately: one window, one staleness story.
     *      A snapshot's two roots activate together because they describe the SAME leaf set, and
     *      letting them diverge would mean a proof could be valid against one and not the other.
     * @dev ⚠️ Returns zero when the active snapshot carries no SMT root — legal, and it means an
     *      EMPTY exclusion set, which admits everyone. Callers must treat that as fail-open by
     *      design rather than as an error; see `RegistrySnapshot.smtRoot`.
     */
    function latestActiveSmtRoot(bytes32 registryId_) external view returns (bytes32) {
        RegistrySnapshot[] storage list_ = snapshots[registryId_];
        uint256 length_ = list_.length;
        if (length_ == 0) revert NoSnapshotsAvailable();
        for (uint256 i_ = length_; i_ > 0; --i_) {
            RegistrySnapshot storage snap_ = list_[i_ - 1];
            if (snap_.timestamp + ROOT_ACTIVATION_DELAY <= block.timestamp) return snap_.smtRoot;
        }
        revert NoActiveSnapshot();
    }

    function latestActiveRoot(bytes32 registryId_) external view returns (bytes32) {
        RegistrySnapshot[] storage list_ = snapshots[registryId_];
        uint256 length_ = list_.length;
        if (length_ == 0) revert NoSnapshotsAvailable();
        for (uint256 i_ = length_; i_ > 0; --i_) {
            RegistrySnapshot storage snap_ = list_[i_ - 1];
            if (snap_.timestamp + ROOT_ACTIVATION_DELAY <= block.timestamp) return snap_.root;
        }
        revert NoActiveSnapshot();
    }

    function snapshotCount(bytes32 registryId_) external view returns (uint256) {
        return snapshots[registryId_].length;
    }

    /// @dev Keccak Merkle root over `leaves_`, OpenZeppelin-MerkleProof-compatible (each internal
    /// node hashes its children in sorted order, so proofs carry no left/right direction bits) -
    /// the exact algorithm backend/cre/notary_registry/main.go's `merkleRoot()` implements and
    /// TitleLedger.sol's `MerkleProof.verify` calls assume.
    function _computeRoot(bytes32[] memory leaves_) internal pure returns (bytes32) {
        uint256 n_ = leaves_.length;
        if (n_ == 0) revert EmptyLeafSet();

        bytes32[] memory level_ = new bytes32[](n_);
        for (uint256 i_ = 0; i_ < n_; ++i_) {
            if (i_ > 0 && leaves_[i_] <= leaves_[i_ - 1]) revert LeavesNotStrictlySorted();
            level_[i_] = leaves_[i_];
        }

        while (level_.length > 1) {
            uint256 len_ = level_.length;
            bytes32[] memory next_ = new bytes32[]((len_ + 1) / 2);
            for (uint256 i_ = 0; i_ < len_; i_ += 2) {
                next_[i_ / 2] = i_ + 1 < len_ ? _hashSortedPair(level_[i_], level_[i_ + 1]) : level_[i_];
            }
            level_ = next_;
        }
        return level_[0];
    }

    function _hashSortedPair(bytes32 a_, bytes32 b_) internal pure returns (bytes32) {
        return a_ < b_ ? keccak256(abi.encodePacked(a_, b_)) : keccak256(abi.encodePacked(b_, a_));
    }

    function _statementKey(bytes32 registryId_, uint256 index_) internal view returns (bytes32) {
        return
            bytes32(
                uint256(
                    keccak256(abi.encodePacked("REGISTRY_SOURCE_ROOT", registryId_, address(this), index_))
                ) % SNARK_SCALAR_FIELD
            );
    }
}
