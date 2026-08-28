// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from '../libraries/Poseidon.sol';
import {INoirVerifier} from '../interfaces/verifiers/INoirVerifier.sol';
import {HolderStateKeeper} from '../holder/HolderStateKeeper.sol';
import {PoseidonSMT} from '../state/PoseidonSMT.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';
import {Constants} from '../pool/lib/Constants.sol';

/**
 * @title IdentityRegistry
 * @notice The SINGLE identity tree (sec. 2.13k). Key is the escrow commitment; the VALUE
 *         carries status: `0` = registered and clean, non-zero = the revocation predicate.
 *
 * WHY ONE TREE AND NOT TWO. A withdrawal used to prove ASP inclusion of `holder_root` AND
 * non-inclusion of the same value in a separate revocation tree. Encoding status in the value lets a
 * SINGLE INCLUSION PROOF of `commitment -> 0` do both jobs, which removes 43% of the withdrawal
 * circuit (43,772 -> 24,812 ACIR opcodes, measured). It also removes `sk_identity` from the
 * withdrawal entirely: identity is proven ONCE, at escrow.
 *
 * ONE CONTROLLER for this list and the label list alike - a single party decides both, so splitting
 * the authority across contracts would have been a fiction.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * THE TRAPS THIS DESIGN CREATES, AND WHERE EACH IS CLOSED. Merging two trees with OPPOSITE
 * semantics surrenders structural protections the split gave for free, so each is now an explicit
 * guard with a test rather than a property of the shape.
 *
 * 1. ROOT EXPIRY IS MANDATORY HERE, where an inclusion-only tree would need none.
 *    An inclusion tree is safe to prove against forever - an old root has FEWER members, so a
 *    stale root can only ever under-approve. This tree also carries REVOCATIONS, and an old root
 *    has fewer of THOSE, so a revoked identity could prove `commitment -> 0` against a
 *    pre-revocation root FOREVER. `isValidRoot` therefore enforces MAX_ROOT_AGE, with the latest
 *    root always valid so inaction stays harmless.
 *
 * 2. A ZERO PREDICATE WOULD REVOKE SOMEONE INTO CLEANLINESS.
 *    Zero IS the clean sentinel. `revoke` rejects a zero predicate outright.
 *
 * 3. `remove` MUST NEVER BE REACHABLE.
 *    The solarity Bytes32SMT offers `add`, `update` AND `remove`. Removing a registration is
 *    censorship by erasure - the "postman can drop an existing member" failure the append-only
 *    design exists to prevent. Only `add` and `update` are called anywhere in this file.
 *
 * 4. TWO WRITERS ON ONE TREE.
 *    `register` is PERMISSIONLESS (gated by a proof, not a role); `revoke` is controller-only.
 *    Both paths are single-purpose and neither can perform the other's write.
 *
 * 5. AN ESCROW PROOF DOES NOT PROVE THE PASSPORT IS REAL - and this is the subtlest of them.
 *    `escrow_envelope` proves knowledge of an MRZ and of the `sk_identity` it belongs to. It CANNOT
 *    prove the document is genuine - that is registration's job.
 *
 *    AND ON OUR PATH REGISTRATION DOES NOT DO IT ON-CHAIN EITHER (sec. 2.18g).
 *    `RegistrationSimple`, which `HolderRegistration` follows, verifies a backend signer's
 *    signature and a Noir proof over DG1 - not the ICAO certificate chain. The trust root for "this
 *    is a genuine passport" is therefore OUR SIGNER KEY, not the issuing state's signature.
 *    `Registration2` does verify the chain on-chain, and is not the path we are on. Taken alone, a caller could invent an MRZ, escrow against it and land a
 *    commitment backed by nothing - making the tree's scarcity guarantee, and therefore the whole
 *    blacklist, worthless.
 *
 *    CLOSED IN-CIRCUIT SINCE sec. 2.18, NOT HERE. The circuit proves SMT inclusion of the document's
 *    own leaf in `StateKeeper.registrationSmt`; this contract's only remaining job is to confirm the
 *    root that inclusion was proven against is one the SMT actually recognises. See `register`.
 *
 * 6. A REVOKED IDENTITY COULD SIMPLY REGISTER AGAIN (sec. 2.18a).
 *    There is no per-holder guard on this contract and there cannot easily be one: `holderRoot` is
 *    no longer published, by design. The guard is that `commitment` is a FUNCTION of `sk_identity`,
 *    fixed in-circuit, so one identity has exactly one commitment and `registered[commitment]`
 *    rejects the second attempt. While the escrowed secret was freely chosen, anyone revoked could
 *    escrow a fresh secret against the same passport and come back clean.
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 *
 * NON-UPGRADEABLE and UNOWNED, for the reasons the RevocationRegistry it replaces was: an upgradeable identity
 * gate is a mutable one with extra steps.
 */
contract IdentityRegistry {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  /// Public-input layout of `escrow_envelope`. Order is pinned by the circuit's `main` signature;
  /// a mismatch here reads the wrong field while the proof still verifies.
  /// `holder_root` AND `dg1_hash` USED TO SIT AT 2 AND 4 (sec. 2.18). Both were per-person
  /// identifiers, so registration calldata linked every user's identity to their pool handle -
  /// their activity stayed private, their PARTICIPATION did not. They are gone, replaced by
  /// `registration_root`, which every user of the system shares.
  uint256 internal constant PUB_CONTROLLER_X = 0;
  uint256 internal constant PUB_CONTROLLER_Y = 1;
  uint256 internal constant PUB_COMMITMENT = 2;
  uint256 internal constant PUB_REGISTRATION_ROOT = 3;
  uint256 internal constant PUB_C1_X = 4;
  uint256 internal constant PUB_C1_Y = 5;
  uint256 internal constant PUB_SEALED_0 = 6;
  /// Fields in the escrow envelope: `document_id`, and nothing else. Must equal the circuit's
  /// `PAYLOAD_LEN` - a mismatch reads sealed slots past the end of the envelope, or drops one.
  ///
  /// 🔴 IT WAS 5 (secret + packed MRZ), THEN 2, NOW 1. The secret went because `revoke` below takes
  /// only the commitment - which is already public here - while `withdraw.nr` uses that same secret
  /// as its identity witness, so sealing it gave the controller key a credential for no purpose.
  uint256 internal constant SEALED_LEN = 1;
  /// Six fixed signals plus the envelope: 6 + SEALED_LEN. Was 11 when the envelope carried the
  /// packed MRZ; the verifier's own NUMBER_OF_PUBLIC_INPUTS moves with it (that figure adds the
  /// pairing-point object, so it is this plus 8).
  uint256 internal constant PUBLIC_INPUT_COUNT = PUB_SEALED_0 + SEALED_LEN;

  INoirVerifier public immutable ESCROW_VERIFIER;
  HolderStateKeeper public immutable STATE_KEEPER;

  /// The only party that may revoke. Also controls the label list - see the header.
  address public immutable CONTROLLER;

  /// The controller's Baby Jubjub sealing key. Pinned so an envelope cannot be sealed to a key the
  /// controller does not hold, which would produce a registration nobody could ever revoke.
  uint256 public immutable CONTROLLER_KEY_X;
  uint256 public immutable CONTROLLER_KEY_Y;

  uint256 public immutable MAX_ROOT_AGE;

  /// ERC-7812 evidence registry. EVERY root is anchored here as a statement, exactly as the
  /// IdentityAspRegistry this replaces did.
  ///
  /// RESTORED, NOT NEW. The merge dropped this by omission rather than by decision - a regression
  /// found only by mapping the deleted suite's coverage test by test. Anchoring is what makes a
  /// root externally attestable rather than merely stored: another contract, or another chain, can
  /// verify a root existed at a point in time without trusting this contract's own getters. It is
  /// how every other root in this fusion is published, so silently exempting the identity tree
  /// would have made it the odd one out with nothing recording why.
  IEvidenceRegistry public immutable EVIDENCE_REGISTRY;

  /// Monotone counter keying each anchored statement. Not the tree size: revocations change the
  /// root WITHOUT adding a leaf, and they must be anchored too, so a size-derived key would collide.
  uint256 public rootSequence;

  SparseMerkleTree.Bytes32SMT private _tree;

  mapping(bytes32 _root => uint256 _createdAt) public rootCreatedAt;
  mapping(bytes32 _commitment => bool _registered) public registered;
  mapping(bytes32 _commitment => bytes32 _predicate) public statusOf;
  mapping(bytes32 _predicate => bool _allowed) public isPredicate;

  bytes32[] private _predicates;
  uint256 public registeredCount;
  uint256 public revokedCount;

  /**
   * @notice A registration, with its escrow envelope.
   *
   * 🔴 `sealedPayload` WAS `uint256[5]` AND CARRIED THE HOLDER'S PACKED MRZ - name, date of birth,
   * nationality, sex, expiry and document number - encrypted to the single immutable controller key
   * and emitted here, which made it permanently indexable by anyone. It is now ONE field: the
   * document identifier, which is the minimum that makes targeted revocation possible at all.
   *
   * The escrow's purpose is unchanged - a controller can still map a sanctioned document to the
   * envelope that holds it, because `document_id` is recomputable from a published designation. What
   * is gone is everything that only served matching a designation BY NAME.
   */
  event IdentityRegistered(bytes32 indexed commitment, bytes32 root, uint256 c1x, uint256 c1y, uint256[1] sealedPayload);
  event IdentityRevoked(bytes32 indexed commitment, bytes32 indexed predicate, bytes32 root);

  error AlreadyRegistered(bytes32 commitment);
  error NotRegistered(bytes32 commitment);
  error AlreadyRevoked(bytes32 commitment);
  error BadProof();
  error WrongPublicInputCount(uint256 got);
  error WrongControllerKey();
  /// The proof cites a `registrationSmt` root the state keeper does not recognise, or one that has
  /// aged out. Replaces `DocumentNotRegistered`/`DocumentBoundToAnotherHolder`, which named a
  /// `dg1Hash` this contract deliberately no longer sees.
  error UnknownRegistrationRoot(bytes32 registrationRoot);
  /// The cited root predates the most recent document revocation or renewal, so it would still
  /// prove a cancelled document current. See `register`.
  error RegistrationRootPredatesAnInvalidation(bytes32 registrationRoot);
  error NotTheController(address caller);
  error ZeroPredicate();
  error UnknownPredicate(bytes32 predicate);
  error NoPredicates();
  error DuplicatePredicate(bytes32 predicate);
  error ZeroAddress();
  error CommitmentOutOfField(bytes32 commitment);
  error ZeroCommitment();

  constructor(
    address escrowVerifier_,
    address stateKeeper_,
    address controller_,
    address evidenceRegistry_,
    uint256 controllerKeyX_,
    uint256 controllerKeyY_,
    uint32 treeHeight_,
    uint256 maxRootAge_,
    bytes32[] memory predicates_
  ) {
    if (
      escrowVerifier_ == address(0) || stateKeeper_ == address(0) || controller_ == address(0)
        || evidenceRegistry_ == address(0)
    ) revert ZeroAddress();
    if (predicates_.length == 0) revert NoPredicates();

    ESCROW_VERIFIER = INoirVerifier(escrowVerifier_);
    STATE_KEEPER = HolderStateKeeper(stateKeeper_);
    CONTROLLER = controller_;
    CONTROLLER_KEY_X = controllerKeyX_;
    CONTROLLER_KEY_Y = controllerKeyY_;
    MAX_ROOT_AGE = maxRootAge_;
    EVIDENCE_REGISTRY = IEvidenceRegistry(evidenceRegistry_);

    for (uint256 i = 0; i < predicates_.length; i++) {
      // Trap 2: zero is the CLEAN sentinel, so admitting it as a predicate would let a revocation
      // write the clean state. Rejected at deploy rather than only at call time.
      if (predicates_[i] == bytes32(0)) revert ZeroPredicate();
      // A duplicate would pass silently - `isPredicate` is idempotent - while pushing the same
      // value twice into `_predicates`, so the published set would misreport itself forever. It is
      // deploy-time-only and immutable, so there is no way to correct it afterwards.
      if (isPredicate[predicates_[i]]) revert DuplicatePredicate(predicates_[i]);
      isPredicate[predicates_[i]] = true;
      _predicates.push(predicates_[i]);
    }

    _tree.initialize(treeHeight_);
    _tree.setHashers(_h2, _h3);

    rootCreatedAt[_tree.getRoot()] = block.timestamp;
  }

  /**
   * @notice Register an identity by posting its sealed escrow envelope. PERMISSIONLESS.
   * @dev Gated by a proof, never by a role - an approval step would hand back the
   *      censorship-by-inaction lever this whole design removes.
   *
   * THE HONEST SCOPE OF THAT CLAIM (sec. 2.18g). It is true of THIS function and false of
   * the system as it currently stands. Registering here requires the document to already sit in
   * `registrationSmt`, and the only contract that writes it - `HolderRegistration` - requires a
   * BACKEND SIGNER'S SIGNATURE on every entry point. So the approval step still exists; it is one
   * layer upstream of here. A key we hold can be ordered to withhold, and the person is blocked.
   *
   * The permissionless replacement is already in this repo, unused: `Registration2.registerViaNoir`
   * takes no signature and is gated only by a proof against a certificates root built by verifying
   * ICAO signatures ON-CHAIN. Until a path like that writes into the holder tree, this contract's
   * permissionlessness is a property of one link in a chain that has a gate earlier on.
   */
  function register(bytes calldata proof_, bytes32[] calldata publicInputs_) external returns (bytes32 root_) {
    if (publicInputs_.length != PUBLIC_INPUT_COUNT) revert WrongPublicInputCount(publicInputs_.length);

    // Trap 5: the envelope must be sealed to THIS controller's key, or it is unreadable by the only
    // party that could ever act on it - a registration nobody can revoke.
    if (
      uint256(publicInputs_[PUB_CONTROLLER_X]) != CONTROLLER_KEY_X
        || uint256(publicInputs_[PUB_CONTROLLER_Y]) != CONTROLLER_KEY_Y
    ) revert WrongControllerKey();

    // Trap 5, the substantive half. The escrow proof shows the prover knows an MRZ and the
    // `sk_identity` it belongs to, NOT that the passport is genuine - the ICAO chain is checked at
    // registration. The circuit now proves that registration happened by INCLUDING the document's
    // own leaf from `registrationSmt`, so all that is left here is to confirm the root it proved
    // against is real. WITHOUT THIS CHECK THE INCLUSION PROOF IS WORTHLESS: a prover would invent a
    // tree containing whatever leaf they liked and prove inclusion in that.
    //
    // CHECKED BEFORE THE PROOF, deliberately. A Honk verification costs hundreds of thousands of
    // gas; this is one external view call. Ordering it after meant a caller citing an unknown root
    // paid for a full verification before being told the root was the problem - and got
    // `SumcheckFailed()` rather than a useful error, because tampering with a public input makes
    // the generated verifier revert on its own. Neither is a security difference; both are the
    // difference between a diagnosable failure and a confusing one.
    //
    // TWO CONDITIONS, AND THE SECOND IS NOT REDUNDANT.
    //
    // `PoseidonSMT.isRootValid` = latest OR within ROOT_VALIDITY (1 hour). That alone left a real
    // hole: revoking a document overwrites its leaf VALUE, so roots created BEFORE the revocation
    // still prove it CURRENT - and stay valid for the rest of the hour. A cancelled passport could
    // register a pool identity for up to an hour after being cancelled (sec. 2.18b).
    //
    // So the root must ALSO be no older than the last time any document stopped being current. A
    // pre-invalidation root is now rejected outright instead of lingering.
    //
    // THE TIMESTAMP MEANS "WHEN THIS ROOT WAS SUPERSEDED", NOT "WHEN IT WAS CREATED" -
    // `PoseidonSMT.withRootUpdate` stamps the OUTGOING root before mutating. I had this backwards
    // first time and the test caught it: a root superseded BY the invalidation carries exactly
    // `lastDocumentInvalidationAt`, so the comparison must be `<=`. With `<` that root - the very
    // one that still shows the cancelled document as current - would sail through.
    //
    // The LATEST root skips the test entirely, and must: the current root has NO entry in `_roots`
    // (it has not been superseded), so it would read as 0 and be rejected forever. It is also
    // always safe, because any invalidation moves the root - whatever is latest already reflects it.
    //
    // Same-block conservatism, in the safe direction: a root superseded by an unrelated binding in
    // the same block as an invalidation is also rejected. It costs that prover a re-proof; it
    // cannot let a cancelled document through.
    //
    // WHY ASK THE STATE KEEPER RATHER THAN STORE A ROOT HERE. `registrationSmt` moves on every
    // document bound anywhere in the system; mirroring it would need a feed, and a feed that stalls
    // is a registration freeze - exactly the censorship-by-inaction this design removes.
    bytes32 registrationRoot_ = publicInputs_[PUB_REGISTRATION_ROOT];
    PoseidonSMT registrationSmt_ = STATE_KEEPER.registrationSmt();
    if (!registrationSmt_.isRootValid(registrationRoot_)) {
      revert UnknownRegistrationRoot(registrationRoot_);
    }
    if (
      !registrationSmt_.isRootLatest(registrationRoot_)
        && registrationSmt_.getRootTimestamp(registrationRoot_)
          <= STATE_KEEPER.lastDocumentInvalidationAt()
    ) revert RegistrationRootPredatesAnInvalidation(registrationRoot_);

    if (!ESCROW_VERIFIER.verify(proof_, publicInputs_)) revert BadProof();

    bytes32 commitment_ = publicInputs_[PUB_COMMITMENT];

    // Defence in depth, carried over from the registry this replaces. The commitment comes from a
    // VERIFIED proof binding it to `Poseidon(revocation_secret)`, so a Poseidon output is already a
    // field element and zero is negligible - but the previous registry checked its leaves and
    // dropping the check silently would leave the reasoning implicit in a contract that cannot be
    // upgraded to add it back.
    if (commitment_ == bytes32(0)) revert ZeroCommitment();
    if (uint256(commitment_) >= Constants.SNARK_SCALAR_FIELD) revert CommitmentOutOfField(commitment_);
    // `_tree.add` would revert with KeyAlreadyExists anyway; this gives the real reason, and stops a
    // re-add from being attempted against a REVOKED commitment.
    if (registered[commitment_]) revert AlreadyRegistered(commitment_);

    registered[commitment_] = true;
    registeredCount++;

    // Value 0: registered and clean. Verified end-to-end - the on-chain root for a zero-valued leaf
    // matches what the Noir gadget computes (test/registry/SmtCompat.t.sol).
    _tree.add(commitment_, bytes32(0));

    root_ = _anchorRoot();

    uint256[SEALED_LEN] memory sealed_;
    for (uint256 i = 0; i < SEALED_LEN; i++) {
      sealed_[i] = uint256(publicInputs_[PUB_SEALED_0 + i]);
    }
    emit IdentityRegistered(
      commitment_, root_, uint256(publicInputs_[PUB_C1_X]), uint256(publicInputs_[PUB_C1_Y]), sealed_
    );
  }

  /**
   * @notice Revoke a registered identity, citing a predicate. Controller only.
   * @dev Monotone: `statusOf` moves 0 -> predicate once and never back. There is deliberately no
   *      un-revoke; correcting a mistaken revocation is a governance problem, not a setter.
   */
  function revoke(bytes32 commitment_, bytes32 predicate_) external returns (bytes32 root_) {
    if (msg.sender != CONTROLLER) revert NotTheController(msg.sender);
    if (predicate_ == bytes32(0)) revert ZeroPredicate();
    if (!isPredicate[predicate_]) revert UnknownPredicate(predicate_);
    if (!registered[commitment_]) revert NotRegistered(commitment_);
    if (statusOf[commitment_] != bytes32(0)) revert AlreadyRevoked(commitment_);

    statusOf[commitment_] = predicate_;
    revokedCount++;

    // UPDATE, not add - and never `remove` (trap 3). The predicate becomes the leaf value, so the
    // tree records WHY, not merely that, an identity was revoked.
    _tree.update(commitment_, predicate_);

    root_ = _anchorRoot();

    emit IdentityRevoked(commitment_, predicate_, root_);
  }

  /// Record the new root and anchor it as ERC-7812 evidence. Called by BOTH writers - a revocation
  /// moves the root just as a registration does, and an unanchored root would be invisible to
  /// anything verifying against the evidence registry.
  function _anchorRoot() internal returns (bytes32 root_) {
    root_ = _tree.getRoot();
    rootCreatedAt[root_] = block.timestamp;
    EVIDENCE_REGISTRY.addStatement(_statementKey(rootSequence++), root_);
  }

  function _statementKey(uint256 sequence_) internal view returns (bytes32) {
    return bytes32(
      uint256(keccak256(abi.encodePacked('PP_IDENTITY_ROOT', address(this), sequence_)))
        % Constants.SNARK_SCALAR_FIELD
    );
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
  }

  /**
   * @notice Is `root_` acceptable to prove `commitment -> 0` against?
   *
   * THE LATEST ROOT IS ALWAYS VALID however old it is, so a controller that never acts again blocks
   * nobody - inaction stays harmless. Superseded roots stay valid for MAX_ROOT_AGE so an in-flight
   * proof is not invalidated by someone else's registration landing first.
   *
   * EXPIRY IS REQUIRED HERE (trap 1). This tree carries revocations, so an unbounded-age root would
   * let a revoked identity prove the clean state against a pre-revocation root forever. Note this
   * tree changes on EVERY registration, not only on revocations, so roots churn far faster than
   * the revocation-only registry this replaces - MAX_ROOT_AGE is time-based, so that is a matter of more stored roots,
   * not of correctness.
   */
  function isValidRoot(bytes32 root_) public view returns (bool) {
    // The EMPTY tree's root is literally zero, and the constructor records it, so without this the
    // zero root reads as valid. Nothing can actually be proven against an empty root - an inclusion
    // path always ends at a non-zero leaf hash - so this is defence in depth rather than a live
    // hole, but State.sol's `_isKnownRoot` already rejects zero and the two should not disagree
    // about what a zero root means.
    if (root_ == bytes32(0)) return false;

    uint256 created_ = rootCreatedAt[root_];
    if (created_ == 0) return false;
    if (root_ == _tree.getRoot()) return true;
    return block.timestamp <= created_ + MAX_ROOT_AGE;
  }

  function getProof(bytes32 commitment_) external view returns (SparseMerkleTree.Proof memory) {
    return _tree.getProof(commitment_);
  }

  function predicates() external view returns (bytes32[] memory) {
    return _predicates;
  }

  function _h2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a), uint256(b)]));
  }

  function _h3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a), uint256(b), uint256(c)]));
  }
}
