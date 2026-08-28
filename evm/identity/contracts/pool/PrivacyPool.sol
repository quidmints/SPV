// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/*

Made with ♥ for 0xBow by

░██╗░░░░░░░██╗░█████╗░███╗░░██╗██████╗░███████╗██████╗░██╗░░░░░░█████╗░███╗░░██╗██████╗░
░██║░░██╗░░██║██╔══██╗████╗░██║██╔══██╗██╔════╝██╔══██╗██║░░░░░██╔══██╗████╗░██║██╔══██╗
░╚██╗████╗██╔╝██║░░██║██╔██╗██║██║░░██║█████╗░░██████╔╝██║░░░░░███████║██╔██╗██║██║░░██║
░░████╔═████║░██║░░██║██║╚████║██║░░██║██╔══╝░░██╔══██╗██║░░░░░██╔══██║██║╚████║██║░░██║
░░╚██╔╝░╚██╔╝░╚█████╔╝██║░╚███║██████╔╝███████╗██║░░██║███████╗██║░░██║██║░╚███║██████╔╝
░░░╚═╝░░░╚═╝░░░╚════╝░╚═╝░░╚══╝╚═════╝░╚══════╝╚═╝░░╚═╝╚══════╝╚═╝░░╚═╝╚═╝░░╚══╝╚═════╝░

https://defi.sucks/

*/

import {PoseidonT4} from 'poseidon/PoseidonT4.sol';

import {Constants} from './lib/Constants.sol';
import {INoirVerifier} from '../interfaces/verifiers/INoirVerifier.sol';
import {BatchVerifierLib} from './lib/BatchVerifierLib.sol';
import {ProofLib} from './lib/ProofLib.sol';
import {IIdentityRegistry} from '../interfaces/registry/IIdentityRegistry.sol';
import {IBlacklistAnchor} from '../interfaces/registry/IBlacklistAnchor.sol';

import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {State} from './State.sol';

/**
 * @title PrivacyPool
 * @notice Allows publicly depositing and privately withdrawing funds.
 * @dev Withdrawals require a valid proof of a REGISTERED, UNREVOKED IDENTITY - not ASP approval.
 *      Upstream's eighth public signal was `ASPRoot` and the leaf it proved membership of was the
 *      `label`, i.e. the DEPOSIT (0xbow `withdraw.circom`: `ASPRootChecker.leaf <== label`). Slot [5]
 *      now carries `identityRoot` and the leaf is the withdrawer's identity commitment, proven
 *      included with a CLEAN status (`ProofLib.sol` sec. 2.13k collapsed `ASPRoot` + `revocationRoot`
 *      into it).
 *
 *      SO THE SUBJECT OF THE PREDICATE CHANGED, from funds to people, and this line claimed the
 *      upstream one until 2026-08-07. **Nothing here screens fund provenance.** A holder with a clean
 *      identity may withdraw a deposit of any origin. `Entrypoint` has no admission path at all - see
 *      its ASSOCIATION SET METHODS block - so there is no second check elsewhere.
 *
 *      The `label` is still bound into both commitments (`pp/src/withdraw.nr:80,99` over
 *      `commitment_hasher`), exactly as upstream, so a provenance check remains expressible without
 *      touching the note format. TODO sec. 2.18fa records the gap, 2.18fe the design.
 * @dev Deposits can be irreversibly suspended by the Entrypoint, while withdrawals can't.
 */
abstract contract PrivacyPool is State, IPrivacyPool {

  /// @notice The batch verifier: `TreeRoot<MAX_BATCH>HonkVerifier`, generated from the recursion
  ///         tree that settles MAX_BATCH withdrawals.
  ///
  /// @dev ONE VERIFIER PER TREE DEPTH, and they are not interchangeable - a depth-5 root proof is
  ///      refused by the depth-4 verifier. So this address is what says which batch size this pool
  ///      settles, and MAX_BATCH must agree with it.
  /// @dev MAY be the zero address: a pool that does not offer batching is a legitimate deployment,
  ///      and PP upstream has no such verifier at all. `withdrawBatch` refuses explicitly in that
  ///      case rather than calling into an empty address - see BatchVerifierNotConfigured.
  ///      Immutable, like every other verifier here: a mutable one would let whoever can set it
  ///      swap in a verifier that accepts anything, which is the whole security of the batch path.
  INoirVerifier public immutable BATCH_VERIFIER;

  /// @notice The circuit's compile-time BATCH_N. A batch longer than this cannot have been proved
  ///         by it, and the commitment alone would not catch that since it folds any length.
  uint256 public constant MAX_BATCH = 16;

  /// @notice `_withdrawals` and `_signals` must line up one-to-one.
  error BatchLengthMismatch(uint256 withdrawals, uint256 signals);
  /// @notice This pool was deployed without an aggregation verifier, so batching is unavailable.
  ///         Without this, `withdrawBatch` would call into address(0) - which returns empty
  ///         returndata that fails to decode as `bool`, producing a bare revert that says nothing.
  error BatchVerifierNotConfigured();


  /// @notice One aggregated batch settled. Per-withdrawal `Withdrawn` events are emitted too, so
  ///         existing indexers keep working unchanged.
  event BatchWithdrawn(address indexed batcher, uint256 count);
  using ProofLib for ProofLib.WithdrawProof;
  using ProofLib for ProofLib.RagequitProof;

  /**
   * @notice Does a series of sanity checks on the proof public signals
   * @param _withdrawal The withdrawal data structure containing withdrawal details
   * @param _proof The withdrawal proof data structure containing proof details
   */
  modifier validWithdrawal(Withdrawal memory _withdrawal, ProofLib.WithdrawProof memory _proof) {
    // Check caller is the allowed processooor
    if (msg.sender != _withdrawal.processooor) revert InvalidProcessooor();

    // DIAGNOSTIC ONLY - the binding itself is enforced in `withdraw`, which feeds the derived
    // context straight into the verifier's public inputs (see ProofLib.publicInputsBytes32). This
    // check is kept because `ContextMismatch` tells a relayer exactly what is wrong with a proof it
    // was handed, where the `InvalidProof` it would otherwise get names nothing. Deleting it costs
    // a good error message and no security, which is the opposite of what was true before.
    if (_proof.context() != _contextFor(_withdrawal)) {
      revert ContextMismatch();
    }

    // Check the tree depth signals are less than the max tree depth
    if (_proof.stateTreeDepth() > MAX_TREE_DEPTH) revert InvalidTreeDepth();

    // Check the state root is known
    if (!_isKnownRoot(_proof.stateRoot())) revert UnknownStateRoot();

    // ONE identity check, where there used to be two (sec. 2.13k). The proof shows the
    // withdrawer's escrow commitment is present in the registry carrying the CLEAN status - which
    // is simultaneously "registered" and "not revoked", because a revoked leaf holds its predicate
    // as the value and can no longer prove 0.
    //
    // `isValidRoot`, NOT "is known", and NOT upstream's equality check.
    //
    // ⚠️ AN EARLIER VERSION OF THIS COMMENT SAID "the old ASP check deliberately accepted ANY
    // historical root". That was false, and it attributed OUR design to upstream. Upstream compared
    // against a SINGLE root: `if (_proof.ASPRoot() != ENTRYPOINT.latestActiveRoot()) revert
    // IncorrectASPRoot();` - the newest root past its activation delay, and nothing else. Accepting
    // every historical root forever was this fork's change (2026-08-07, TODO sec. 2.18fb).
    //
    // WHY IT MATTERS THAT THE REASONING IS OURS: accepting old roots is safe for a pure INCLUSION
    // tree, because an append-only tree's historical membership is a strict subset of the current
    // one, so an old root can only ever under-approve. THAT DOES NOT HOLD HERE. This tree also
    // carries revocations - `IdentityRegistry.revoke` UPDATES a leaf rather than appending - so an
    // old root has FEWER of them, and honouring one indefinitely would let a revoked identity prove
    // the clean state forever. The registry therefore expires superseded roots (`MAX_ROOT_AGE`)
    // while keeping the LATEST valid regardless of age, so controller inaction still cannot block a
    // withdrawal.
    //
    // Asked of the REGISTRY, not the Entrypoint. Routing this through the Entrypoint - even as a
    // pass-through - would preserve the exact hole that split closes: the Entrypoint is upgradeable
    // by OWNER_ROLE, so an upgraded one could simply lie about which roots are genuine. See
    // sec. 2.5a.
    if (!IDENTITY_REGISTRY.isValidRoot(bytes32(_proof.identityRoot()))) revert InvalidIdentityRoot();
    _;
  }

  /**
   * @notice The context a proof must have been made for, derived from the withdrawal data itself.
   * @param _withdrawal The withdrawal being processed
   * @return The value `withdraw_identity`'s seventh public signal is required to hold
   *
   * @dev ONE DEFINITION, because two would eventually disagree. The modifier uses it to produce a
   *      readable error and `withdraw` uses it as the value actually handed to the verifier; if
   *      those were written out separately, a change to `SCOPE` or to the encoding would only have
   *      to miss one of them for the diagnostic to start contradicting the check that matters.
   *      This is the same lesson as RootValidity (sec. 2.18o), where the rule was written
   *      three times and all three copies carried the same defect.
   */
  function _contextFor(Withdrawal memory _withdrawal) internal view returns (uint256) {
    return uint256(keccak256(abi.encode(_withdrawal, SCOPE))) % Constants.SNARK_SCALAR_FIELD;
  }

  /**
   * @notice Number of buckets `_precommitmentHash` is folded into for the indexed `Deposited`
   *         topic. Purely a DISCOVERY aid - it lets a recovering wallet fetch only the logs that
   *         could contain its own notes instead of every deposit ever made.
   * @dev This is a PRIVACY/SPEED DIAL, and the trade must be understood before changing it.
   *      Indexing `_precommitmentHash` itself would be the fastest option and the wrong one: a
   *      wallet querying its exact precommitments tells its RPC provider precisely which notes are
   *      its own, reintroducing off-chain the linkage the pool removes on-chain. Bucketing means a
   *      query returns roughly `totalDeposits / PRECOMMITMENT_BUCKETS` notes belonging to many
   *      unrelated users, so the provider learns only a coarse bucket.
   *      MORE buckets  = faster sync, SMALLER crowd to hide in.
   *      FEWER buckets = slower sync, LARGER crowd.
   *      256 keeps sync ~256x cheaper than a full scan while each query still covers a broad slice.
   *      Nothing new is revealed ON-CHAIN either way: the bucket is derived from
   *      `_precommitmentHash`, which the same log already publishes in the clear.
   */
  uint256 public constant PRECOMMITMENT_BUCKETS = 256;

  /**
   * @notice Initializes the contract state addresses
   * @param _entrypoint Address of the Entrypoint that operates this pool
   * @param _withdrawalVerifier Address of the Noir/Honk verifier for withdrawal proofs
   * @param _ragequitVerifier Address of the Noir/Honk verifier for ragequit proofs
   * @param _asset Address of the pool asset
   */
  /// @notice The single identity tree: registration AND revocation status in one place.
  ///         NON-UPGRADEABLE and referenced directly, so nothing upgradeable sits between this pool
  ///         and a set that can block a withdrawal.
  IIdentityRegistry public immutable IDENTITY_REGISTRY;

  constructor(
    address _entrypoint,
    address _withdrawalVerifier,
    address _ragequitVerifier,
    address _asset,
    address _identityRegistry,
    address _batchVerifier,
    address _blacklistAnchor,
    bytes32 _blacklistRegistryId
  ) State(_asset, _entrypoint, _withdrawalVerifier, _ragequitVerifier) {
    if (_identityRegistry == address(0)) revert ZeroIdentityRegistry();
    if (_blacklistAnchor == address(0)) revert ZeroBlacklistAnchor();
    BLACKLIST_ANCHOR = IBlacklistAnchor(_blacklistAnchor);
    BLACKLIST_REGISTRY_ID = _blacklistRegistryId;
    IDENTITY_REGISTRY = IIdentityRegistry(_identityRegistry);
    // Deliberately NOT rejected when zero - see BATCH_VERIFIER. It was previously never
    // assigned at all, which left `withdrawBatch` permanently unreachable.
    BATCH_VERIFIER = INoirVerifier(_batchVerifier);
  }

  /*///////////////////////////////////////////////////////////////
                             USER METHODS 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPrivacyPool
  function deposit(
    address _depositor,
    uint256 _value,
    uint256 _precommitmentHash
  ) external payable onlyEntrypoint returns (uint256 _commitment) {
    // Check deposits are enabled
    if (dead) revert PoolIsDead();

    if (_value >= type(uint128).max) revert InvalidDepositValue();
    // Every other input to the commitment Poseidon hash below is explicitly field-reduced
    // (`_label` via `% Constants.SNARK_SCALAR_FIELD`); `_precommitmentHash` is depositor-supplied
    // and was the one input with no such check. An out-of-field value doesn't corrupt anyone
    // else's funds, but it produces a commitment the Noir withdrawal circuit (which computes
    // Poseidon over an implicitly-reduced field element) can never reconstruct - i.e. a
    // self-locking deposit from a buggy or malicious client SDK. Reject it up front instead.
    if (_precommitmentHash >= Constants.SNARK_SCALAR_FIELD) revert InvalidPrecommitmentHash();

    // Compute label
    uint256 _label = uint256(keccak256(abi.encodePacked(SCOPE, ++nonce))) % Constants.SNARK_SCALAR_FIELD;
    // Store depositor
    depositors[_label] = _depositor;

    // Compute commitment hash
    _commitment = PoseidonT4.hash([_value, _label, _precommitmentHash]);

    // Insert commitment in state (revert if already present)
    _insert(_commitment);

    // Pull funds from caller
    _pull(msg.sender, _value);

    emit Deposited(
      _depositor, _precommitmentHash % PRECOMMITMENT_BUCKETS, _commitment, _label, _value, _precommitmentHash
    );
  }

  /// @inheritdoc IPrivacyPool
  /**
   * @notice Settle N withdrawals against ONE aggregation proof (TODO.md sec. 2.4).
   *
   * @dev WHAT AGGREGATION REPLACES, AND WHAT IT DOES NOT. The batch proof establishes only that N
   *      valid `withdraw_identity` proofs exist and that their public signals hash to the single
   *      field the aggregation verifier exposes. It says NOTHING about whether those signals are
   *      acceptable to this pool. So every policy check `validWithdrawal` makes is repeated below,
   *      per withdrawal, in the same order. Aggregation amortises the PROOF check; it must never
   *      amortise the POLICY checks, or a batch would settle withdrawals `withdraw` would reject.
   *
   *      WHY THERE IS NO `msg.sender == processooor` CHECK, and why that is SAFE. In the single
   *      path the submitter must be the processooor. Here the submitter is the BATCHER, who is by
   *      construction not the payee - requiring it would make batching impossible. Dropping it is
   *      safe because the payout target is not taken from `msg.sender`: `context` is derived from
   *      `_withdrawals[i]` and fed to the aggregation as a bound signal, so a batcher who alters any
   *      withdrawal changes its context, changes the commitment, and the batch fails to verify. The
   *      funds go to the processooor NAMED IN THE PROVEN WITHDRAWAL, whoever submits.
   *
   *      `PrivacyPool.withdraw` IS UNTOUCHED. A user censored by every batcher still self-submits at
   *      full gas, so batcher refusal costs money, never access (sec. 2.4, non-negotiable).
   *
   *      SIGNALS MUST BE IN THE PROVED ORDER. The fold is order-binding, so a permuted batch
   *      produces a different commitment and reverts - which is what stops a batcher pairing one
   *      user's recipient context with another's nullifier.
   */
  function withdrawBatch(
    Withdrawal[] calldata _withdrawals,
    uint256[8][] memory _signals,
    bytes calldata _batchProof
  ) external {
    // ✅ THE GAP THIS BLOCK DESCRIBED IS CLOSED. It read "THIS PATH DOES NOT CARRY THE TAINT PROOF"
    // and prescribed the remedy exactly: widen the leaf template to EIGHT signals, regenerate every
    // level and the TreeRoot{8,16,32} verifiers, and widen PUB_LEN in both batch libraries. Done -
    // the leaf pins `withdraw_identity` and folds 2 x EIGHT signals, and `s[7]` is the blacklist
    // root. A batched withdrawal now carries the predicate the single path always did.
    //
    // ⚠️ CARRYING IT IS ONLY HALF, AND THE SECOND HALF IS NOT IN THE PROOF. Widening the leaf makes
    // `s[7]` EXIST; it does not make it TRUE. The batch verifier takes one public input, so unlike
    // `withdraw` there is nothing to substitute the pool's root into - `s[7]` is whatever the prover
    // folded in, and an empty tree of their own would satisfy every exclusion term while verifying
    // perfectly. It is re-anchored to pool state in the settlement loop below, next to the state and
    // identity roots, for exactly the reason they are.
    // ⇒ A WIDER PROOF WITHOUT THAT CHECK WOULD HAVE BEEN WORSE THAN THE OPEN GAP: the gap was known
    //   and written down, where the unchecked signal looks like coverage.
    if (address(BATCH_VERIFIER) == address(0)) revert BatchVerifierNotConfigured();

    uint256 n = _withdrawals.length;
    if (n != _signals.length) revert BatchLengthMismatch(n, _signals.length);

    // The signals are what the batch proof binds; the withdrawals are what this contract settles.
    // Tying them together is the ONLY thing that makes the batch mean anything, so it is done first
    // and per withdrawal: each signal set must carry the context derived from ITS withdrawal.
    // ⚠️ THIS COMPARISON IS LOAD-BEARING - unlike the identically-shaped one in `validWithdrawal`,
    // which is labelled DIAGNOSTIC ONLY. Do not delete it by analogy.
    //
    // `withdraw` binds the recipient by SUBSTITUTION: it feeds the derived context straight into
    // the verifier's public inputs, so the comparison there is only for a better error message.
    // There is no substitution available here - the aggregation verifier takes ONE public input,
    // the commitment. The binding is instead: `_signals` are folded into that commitment, the proof
    // binds the commitment, so `_signals` cannot be lied about; and each signal set's context must
    // then equal the one derived from ITS withdrawal. Remove this loop and a batcher may pair any
    // proven withdrawal with any `_withdrawals[i]` they like, redirecting every payout.
    //
    // `_contextFor` hashes `abi.encode(_withdrawal, SCOPE)` - the WHOLE struct - so altering any
    // field of a withdrawal breaks the match. Checked BEFORE verification so a mismatched batch
    // fails on the cheap comparison rather than after paying for the proof.
    // PADDING SLOTS ARE SKIPPED, and `withdrawn_value == 0` is what marks one. A recursion tree
    // settles POWER-OF-TWO batches, so a batch of five is proved as a tree of eight with three
    // padding withdrawals - genuine proofs of zero-value spends, generated for this batch's state
    // root because every member must share it.
    //
    // ⚠️ THE SKIP MUST COME BEFORE `_spend`, WHICH IS WHY IT IS NOT MERELY AN OPTIMISATION. Padding
    // slots are generated from a dedicated note, so several in one batch carry the SAME nullifier;
    // settling them would revert `NullifierAlreadySpent` on the second and make any padded batch
    // unsettleable. It also comes before the context check, because a padding slot has no
    // withdrawal to be bound to.
    //
    // NOTHING IS LOST BY SKIPPING. A zero-value withdrawal pays nobody and frees no note - the
    // change commitment equals the spent one. It exists only to occupy a leaf. It IS still bound by
    // the batch commitment, so a batcher cannot swap padding for a real withdrawal after proving.
    //
    // A REAL WITHDRAWAL OF ZERO IS NOT A THING THIS DENIES ANYONE: it would pay out nothing while
    // burning the note's nullifier, so it is strictly worse than not withdrawing.
    for (uint256 i; i < n; ++i) {
      if (_signals[i][2] == 0) continue; // padding
      if (_signals[i][6] != _contextFor(_withdrawals[i])) revert ContextMismatch();
    }

    BatchVerifierLib.verifyBatch(
      BATCH_VERIFIER, _batchProof, _signals, MAX_BATCH
    );

    // ROOT MEMO. `_isKnownRoot` walks the root HISTORY and `isValidRoot` is an external call; both
    // are per-withdrawal in the single path, and naively repeating them N times is the one place
    // this function would waste real gas. Batched withdrawals are proved within a short window and
    // so overwhelmingly share roots, and a root is either known or not regardless of who asks - the
    // check is a pure function of pool state that cannot change mid-transaction. So verifying each
    // DISTINCT root once is exactly equivalent and collapses the common case to a single walk.
    // A one-slot memo, not a set: batches are near-uniform, so this catches almost everything
    // without the bookkeeping a full dedup would cost.
    uint256 lastStateRoot;
    uint256 lastIdentityRoot;

    uint256 settled;
    uint256 active_ = _activeBlacklistRoot();

    for (uint256 i; i < n; ++i) {
      uint256[8] memory s = _signals[i];
      if (s[2] == 0) continue; // padding - see the loop above
      ++settled;

      // NO `stateTreeDepth > MAX_TREE_DEPTH` CHECK HERE, and that is not an omission: the
      // AGGREGATION CIRCUIT already constrains it (`assert_depth_in_range`, applied to every
      // withdrawal inside the verification loop) and does so on the FULL field, which is strictly
      // stronger than the contract's uint256 compare. Re-checking would cost gas to re-establish
      // something the proof has already made unforgeable. The single-withdrawal path still needs
      // its own check, because `withdraw_identity` alone does NOT constrain it (sec. 2.4 trap 5).

      if (s[3] != lastStateRoot) {
        if (!_isKnownRoot(s[3])) revert UnknownStateRoot();
        lastStateRoot = s[3];
      }
      if (s[5] != lastIdentityRoot) {
        if (!IDENTITY_REGISTRY.isValidRoot(bytes32(s[5]))) revert InvalidIdentityRoot();
        lastIdentityRoot = s[5];
      }

      // ⚠️ THE BATCH MUST *CHECK* THE BLACKLIST ROOT BECAUSE IT CANNOT *SUBSTITUTE* IT.
      //
      // `withdraw` feeds the anchor's active root straight into the verifier's public inputs, so a
      // prover there has no say in it. The aggregation verifier takes ONE public input - the batch
      // commitment - so there is nothing to substitute into: `s[7]` is whatever the prover folded in.
      // Without this line a batcher proves non-membership against an EMPTY tree OF THEIR OWN and the
      // predicate is bypassed completely, on a path whose proof verifies perfectly.
      //
      // Same shape as the two checks above, and it is here for the same reason they are: every root
      // a batch signal carries has to be re-anchored to pool state, because the proof binds the
      // signals to each OTHER, never to this contract.
      if (s[7] != active_) revert BlacklistRootMismatch(s[7], active_);

      // ── settle, identically to withdraw() ────────────────────────────────────────────────────
      _spend(s[1]);            // existing nullifier hash - reverts if already spent
      _insert(s[0]);           // new commitment
      _push(_withdrawals[i].processooor, s[2]);

      emit Withdrawn(_withdrawals[i].processooor, s[2], s[1], s[0]);
    }

    // The count REALLY SETTLED, not the tree's size - a batch of five proved as a tree of eight
    // emits five. Otherwise the event would overstate activity by however much padding was used.
    emit BatchWithdrawn(msg.sender, settled);
  }

  function withdraw(
    Withdrawal memory _withdrawal,
    ProofLib.WithdrawProof memory _proof
  ) external validWithdrawal(_withdrawal, _proof) {
    // Verify proof with the Noir/Honk verifier (identity-based ASP withdrawal, see ProofLib.WithdrawProof).
    //
    // The context handed to the verifier is DERIVED HERE from `_withdrawal`, never read out of the
    // proof. That substitution IS the proof-to-recipient binding: `context` is the only public
    // signal naming who gets paid, and the circuit deliberately leaves it unconstrained because its
    // meaning lives in data only this contract holds. Making it an argument rather than a
    // comparison means the binding cannot be removed without the compiler objecting.
    if (
      !WITHDRAWAL_VERIFIER.verify(
        _proof.proof, _proof.publicInputsBytes32(_contextFor(_withdrawal), _activeBlacklistRoot())
      )
    ) {
      revert InvalidProof();
    }

    // Mark existing commitment nullifier as spent
    _spend(_proof.existingNullifierHash());

    // Insert new commitment in state
    _insert(_proof.newCommitmentHash());

    // Transfer out funds to procesooor
    _push(_withdrawal.processooor, _proof.withdrawnValue());

    emit Withdrawn(
      _withdrawal.processooor, _proof.withdrawnValue(), _proof.existingNullifierHash(), _proof.newCommitmentHash()
    );
  }

  /// @inheritdoc IPrivacyPool
  function ragequit(ProofLib.RagequitProof memory _proof) external {
    // Check if caller is original depositor
    uint256 _label = _proof.label();
    if (depositors[_label] != msg.sender) revert OnlyOriginalDepositor();

    // Verify proof with the Noir/Honk verifier. Ragequit was ported alongside withdrawal - there is
    // no Groth16 anywhere in this pool, and both verifiers are `INoirVerifier` (see State.sol).
    if (!RAGEQUIT_VERIFIER.verify(_proof.proof, _proof.ragequitPublicInputsBytes32())) revert InvalidProof();

    // Check commitment exists in state
    if (!_isInState(_proof.commitmentHash())) revert InvalidCommitment();

    // Mark existing commitment nullifier as spent
    _spend(_proof.nullifierHash());

    // Transfer out funds to ragequitter
    _push(msg.sender, _proof.value());

    emit Ragequit(msg.sender, _proof.commitmentHash(), _proof.label(), _proof.value());
  }

  /*///////////////////////////////////////////////////////////////
                             WIND DOWN
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPrivacyPool
  /**
   * @notice Where the blacklist root comes from, and the registry within it.
   *
   * IMMUTABLE ON PURPOSE. A settable source is the same lever as a settable root wearing one more
   * layer: whoever can re-point this can choose the value it returns. Changing either means
   * deploying a new pool, which is a decision with a diff rather than a transaction.
   */
  IBlacklistAnchor public immutable BLACKLIST_ANCHOR;
  bytes32 public immutable BLACKLIST_REGISTRY_ID;

  error ZeroBlacklistAnchor();
  error BlacklistRootUnset();
  error BlacklistRootMismatch(uint256 supplied, uint256 active);


  /**
   * @notice The blacklist root every withdrawal is proven against.
   *
   * ⛔ PULLED FROM THE ANCHOR, NEVER SET HERE, AND THAT IS THE WHOLE POINT OF THIS FUNCTION.
   *
   * It used to be a storage field written by `setBlacklistRoot(uint256)` under `onlyEntrypoint`.
   * Refusing a zero closed the fail-open hole and refusing to re-zero removed the cost-free halt,
   * but neither touched the real problem: ONE ADDRESS CHOSE THE VALUE. A hostile entrypoint could
   * publish a root nobody holds an exclusion witness against, and every withdrawal in the pool stops
   * - a pause flag in everything but name, on a contract whose central claim is that no such lever
   * exists (`test_NoGovernanceLeverCanBlockAWithdrawal`).
   *
   * The anchor is the same shape that already bounds `IncorrectASPRoot`: append-only, no owner, and
   * fed by a DON through a forwarder that is itself timelocked. Nobody can aim it at an individual,
   * and nobody can choose its value.
   *
   * ⚠️ THE REVERTS ARE LOAD-BEARING AND MUST NOT BE CAUGHT. The anchor reverts when no snapshot
   * exists or none has cleared its activation delay. For an EXCLUSION predicate that is correct:
   * an absent set proves non-membership for every key, so swallowing the revert and continuing with
   * zero would admit everyone - the exact hole this replaced. Withdrawals halt until a root is
   * published; deposits are unaffected.
   *
   * ⚠️ WHAT THIS DOES NOT BUY. Liveness now depends on the feed having published once and the
   * activation delay having elapsed. A stalled feed keeps the last ACTIVE root rather than emptying
   * it, so staleness admits a newly-listed key and never everyone. That is the residual, and it is
   * a property of gating on a rotating root at all - not of where the root comes from.
   *
   * A `private view` rather than a modifier: one routine and two call sites, instead of the body
   * inlined at each.
   */
  function _activeBlacklistRoot() private view returns (uint256 root_) {
    root_ = uint256(BLACKLIST_ANCHOR.latestActiveSmtRoot(BLACKLIST_REGISTRY_ID));
    // Belt-and-braces: the anchor documents that a snapshot may legally carry a zero SMT root, which
    // for an exclusion predicate means an empty set. It announces nothing when it happens, so the
    // failure would be silent and would admit everyone - which is what earns this check its place.
    if (root_ == 0) revert BlacklistRootUnset();
  }

  function windDown() external onlyEntrypoint {
    // Check pool is still alive
    if (dead) revert PoolIsDead();

    // Die
    dead = true;

    emit PoolDied();
  }

  /*///////////////////////////////////////////////////////////////
                          ASSET OVERRIDES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Handle receiving an asset
   * @dev To be implemented by an asset specific contract
   * @param _sender The address of the user sending funds
   * @param _value The amount of asset being received
   */
  function _pull(address _sender, uint256 _value) internal virtual;

  /**
   * @notice Handle sending an asset
   * @dev To be implemented by an asset specific contract
   * @param _recipient The address of the user receiving funds
   * @param _value The amount of asset being sent
   */
  function _push(address _recipient, uint256 _value) internal virtual;
}
