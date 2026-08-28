// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BlacklistAnchorFixture} from './helpers/BlacklistAnchorFixture.sol';
import {BlacklistRootFixture} from './helpers/BlacklistRootFixture.sol';
import {PrivacyPoolSimple} from 'contracts/pool/implementations/PrivacyPoolSimple.sol';
import {PrivacyPool} from 'contracts/pool/PrivacyPool.sol';
import {IPrivacyPool} from 'contracts/pool/interfaces/IPrivacyPool.sol';
import {IState} from 'contracts/pool/interfaces/IState.sol';
import {BatchVerifierLib} from 'contracts/pool/lib/BatchVerifierLib.sol';
import {NoirVerifierMock} from '../mocks/verifiers/NoirVerifierMock.sol';
// MockEntrypoint is declared inside the Simple pool suite rather than its own file.
import {MockEntrypoint} from './PrivacyPoolSimple.t.sol';

/*
 * `withdrawBatch` IS FINALLY CALLED BY SOMETHING.
 *
 * WithdrawBatchGuardsTest states plainly that it "does NOT call withdrawBatch" and that the revert
 * paths are UNEXERCISED - it pins BatchCommitmentLib's properties instead. So until this file, the
 * entrypoint had no caller anywhere: not a test, not a contract. Every guard in it was unverified.
 *
 * AND THE FIRST THING CALLING IT FOUND: `BATCH_VERIFIER` was declared and read but NEVER
 * ASSIGNED - no constructor argument, no setter, no deploy script. It was permanently address(0),
 * so `withdrawBatch` could not succeed for any input. A call into an empty address returns empty
 * returndata, which fails to decode as `bool` and reverts bare, saying nothing about the cause.
 * It is now a constructor argument, immutable, with an explicit refusal when unset.
 *
 * WHAT THIS FILE STILL DOES NOT COVER, so its green is not over-read: the HAPPY PATH. Settling a
 * real batch needs a genuine N=16 aggregation proof (~27 GB to produce, TODO.md sec. 2.4a), so
 * every test below stops at or before verification. Double-spend across a batch is likewise
 * untested. **Do not deploy `withdrawBatch` on the strength of this suite either** - but the guards
 * it does reach are now known to fire, which is strictly more than was true before.
 *
 * The verifier double is the same `NoirVerifierMock` the other pool suites use. Every guard tested
 * here fires BEFORE verification except `InvalidBatchProof`, which needs a verifier that says no -
 * so the double is answering "what does the contract do when the proof is rejected", not standing
 * in for the cryptography.
 */
contract WithdrawBatchEntrypointTest is Test, BlacklistAnchorFixture {
  uint256 internal constant PUB_LEN = 8;
  uint256 internal constant CONTEXT_SLOT = 6;
  /// BN254 scalar field - the pool rejects a precommitment at or above it.
  uint256 internal constant FIELD =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  MockEntrypoint internal entrypoint;
  NoirVerifierMock internal batchVerifier;
  PrivacyPoolSimple internal pool;
  PrivacyPoolSimple internal poolWithoutAggregation;

  function setUp() public {
    _deployBlacklistAnchor(BlacklistRootFixture.read(vm));
    entrypoint = new MockEntrypoint();
    batchVerifier = new NoirVerifierMock();
    pool = new PrivacyPoolSimple(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      address(entrypoint),
      address(batchVerifier),
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );
    poolWithoutAggregation = new PrivacyPoolSimple(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      address(entrypoint),
      address(0),
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );

  }

  // ── helpers ───────────────────────────────────────────────────────────────────────────────

  /// The context the pool derives for a withdrawal. Mirrors `_contextFor`; if these ever disagree
  /// the ContextMismatch test below starts passing for the wrong reason, so it is derived rather
  /// than hardcoded.
  function _contextFor(IPrivacyPool.Withdrawal memory w_) internal view returns (uint256) {
    return uint256(keccak256(abi.encode(w_, pool.SCOPE()))) % 21888242871839275222246405745257275088548364400416034343698204186575808495617;
  }

  function _withdrawals(uint256 n_) internal view returns (IPrivacyPool.Withdrawal[] memory ws_) {
    ws_ = new IPrivacyPool.Withdrawal[](n_);
    for (uint256 i; i < n_; ++i) {
      ws_[i] = IPrivacyPool.Withdrawal({processooor: address(uint160(0xA0 + i)), data: ''});
    }
  }

  /// Signals whose context slot MATCHES each withdrawal, so the context loop passes and execution
  /// reaches whatever is being tested next.
  function _matchingSignals(IPrivacyPool.Withdrawal[] memory ws_)
    internal
    view
    returns (uint256[PUB_LEN][] memory s_)
  {
    s_ = new uint256[PUB_LEN][](ws_.length);
    for (uint256 i; i < ws_.length; ++i) {
      for (uint256 j; j < PUB_LEN; ++j) s_[i][j] = i * 100 + j + 1;
      s_[i][CONTEXT_SLOT] = _contextFor(ws_[i]);
    }
  }

  // ── the guard that did not exist until the entrypoint was first called ────────────────────

  function test_RefusesWhenNoAggregationVerifierIsConfigured() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(1);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    vm.expectRevert(PrivacyPool.BatchVerifierNotConfigured.selector);
    poolWithoutAggregation.withdrawBatch(ws, s, '');
  }

  // ── the guards, in the order withdrawBatch applies them ───────────────────────────────────

  function test_RejectsMismatchedLengths() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(3);
    uint256[PUB_LEN][] memory s = new uint256[PUB_LEN][](2);
    vm.expectRevert(abi.encodeWithSelector(PrivacyPool.BatchLengthMismatch.selector, 3, 2));
    pool.withdrawBatch(ws, s, '');
  }

  /// The comparison that stops a batcher pairing one user's proven withdrawal with another's
  /// payout address. Every position is checked, not just the first, because a loop that exits early
  /// or starts at 1 would pass a single-element test.
  function test_RejectsAnyWithdrawalWhoseContextDoesNotMatch() public {
    for (uint256 bad; bad < 3; ++bad) {
      IPrivacyPool.Withdrawal[] memory ws = _withdrawals(3);
      uint256[PUB_LEN][] memory s = _matchingSignals(ws);
      s[bad][CONTEXT_SLOT] ^= 1;
      vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
      pool.withdrawBatch(ws, s, '');
    }
  }

  /// Changing ANY field of a withdrawal must break the match, because `_contextFor` hashes the
  /// whole struct. Pins that the binding is to the struct rather than to the processooor alone.
  function test_AlteringTheWithdrawalBreaksTheContext() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(1);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    ws[0].data = hex'01'; // signals still carry the context of the ORIGINAL withdrawal
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    pool.withdrawBatch(ws, s, '');
  }

  function test_RejectsEmptyBatch() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(0);
    uint256[PUB_LEN][] memory s = new uint256[PUB_LEN][](0);
    vm.expectRevert(BatchVerifierLib.EmptyBatch.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// A batch longer than the circuit's compile-time BATCH_N cannot have been proved by it, and the
  /// commitment fold would absorb any length without complaint - so this is a separate check.
  function test_RejectsOverlongBatch() public {
    uint256 tooMany = pool.MAX_BATCH() + 1;
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(tooMany);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws); // contexts must pass to reach this guard
    vm.expectRevert(
      abi.encodeWithSelector(BatchVerifierLib.BatchTooLarge.selector, tooMany, pool.MAX_BATCH())
    );
    pool.withdrawBatch(ws, s, '');
  }

  function test_RejectsABatchWhoseProofDoesNotVerify() public {
    batchVerifier.setShouldVerify(false);
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    vm.expectRevert(BatchVerifierLib.InvalidBatchProof.selector);
    pool.withdrawBatch(ws, s, '');
  }

  // ── PAST verification, into settlement ────────────────────────────────────────────────────

  /// Deposit so the pool holds funds AND its root history contains a root the batch can prove
  /// against, then mark an identity root active. Everything after this reaches `_spend`.
  function _reachSettlement() internal returns (uint256 stateRoot_, uint256 identityRoot_) {
    vm.deal(address(entrypoint), 10 ether);
    vm.prank(address(entrypoint));
    pool.deposit{value: 10 ether}(address(0xD1), 10 ether, uint256(keccak256('precommitment')) % FIELD);
    stateRoot_ = pool.currentRoot();
    identityRoot_ = uint256(keccak256('identity-root'));
    entrypoint.setActiveRoot(identityRoot_);
  }

  function _settleableSignals(IPrivacyPool.Withdrawal[] memory ws_, uint256 stateRoot_, uint256 identityRoot_)
    internal
    view
    returns (uint256[PUB_LEN][] memory s_)
  {
    s_ = _matchingSignals(ws_);
    for (uint256 i; i < ws_.length; ++i) {
      s_[i][0] = uint256(keccak256(abi.encode('new-commitment', i))) % FIELD; // inserted as a leaf
      s_[i][1] = uint256(keccak256(abi.encode('nullifier', i))) % FIELD; // spent nullifier hash
      s_[i][2] = 1 ether;                                             // withdrawn value
      s_[i][3] = stateRoot_;
      s_[i][5] = identityRoot_;
      // [7] THE BLACKLIST ROOT, and a settleable signal set is not settleable without it. The batch
      // verifier takes one public input, so unlike `withdraw` there is nothing for the pool to
      // substitute into - the contract must COMPARE this against its own root, and does. Leaving it
      // at whatever `_matchingSignals` filled in makes every test in this file fail on a root
      // mismatch before reaching the behaviour it means to assert.
      // Read from the ANCHOR, the same source the pool reads. The pool deliberately exposes no
      // settable or readable root - that is the property - so a test must consult the source of
      // truth rather than the consumer, which is also what a real batcher has to do.
      s_[i][7] = uint256(blacklistAnchor.latestActiveSmtRoot(BLACKLIST_REGISTRY));
    }
  }

  /// DOUBLE-SPEND ACROSS A BATCH - the case TODO.md sec. 2.4 lists as unproven. Two withdrawals in
  /// ONE batch sharing a nullifier hash: the first settles, the second must hit `_spend`'s
  /// already-spent check. Nothing outside the settlement loop can catch this, because both entries
  /// are individually well-formed and the aggregation proof binds them both happily.
  function test_RejectsTwoWithdrawalsSharingANullifierInOneBatch() public {
    (uint256 stateRoot, uint256 identityRoot) = _reachSettlement();
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _settleableSignals(ws, stateRoot, identityRoot);
    s[1][1] = s[0][1]; // the SAME nullifier hash in both positions

    vm.expectRevert(IState.NullifierAlreadySpent.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// The same nullifier across SEPARATE batches must also fail - the first batch marks it spent and
  /// that state has to persist, which is a different code path from the within-batch case above.
  ///
  /// TWO WITHDRAWALS, NOT ONE, and that is now structural rather than stylistic: a recursion tree is
  /// built from PAIRS, so a batch of one is refused by `BatchTooSmall` before any policy check runs.
  /// These three tests used a batch of one for convenience and would otherwise fail on the wrong
  /// error, hiding the behaviour they exist to pin.
  function test_RejectsANullifierAlreadySpentByAnEarlierBatch() public {
    (uint256 stateRoot, uint256 identityRoot) = _reachSettlement();
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _settleableSignals(ws, stateRoot, identityRoot);
    pool.withdrawBatch(ws, s, ''); // settles

    vm.expectRevert(IState.NullifierAlreadySpent.selector);
    pool.withdrawBatch(ws, s, ''); // same nullifier again
  }

  /// A batch proving against a state root the pool never held must be refused, or the whole
  /// membership argument is decorative.
  function test_RejectsUnknownStateRoot() public {
    (, uint256 identityRoot) = _reachSettlement();
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _settleableSignals(ws, uint256(keccak256('never-held')), identityRoot);
    vm.expectRevert(IPrivacyPool.UnknownStateRoot.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// The identity root is checked against the registry, not merely carried. A stale or invented one
  /// is what a revoked identity would present.
  function test_RejectsInvalidIdentityRoot() public {
    (uint256 stateRoot,) = _reachSettlement();
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _settleableSignals(ws, stateRoot, uint256(keccak256('not-active')));
    vm.expectRevert(IPrivacyPool.InvalidIdentityRoot.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// MAX_BATCH must equal the batch size the DEPLOYED tree verifier settles. Pinned here because the
  /// two live in different languages and nothing else compares them - and since sec. 2.18el the
  /// depth is a deployment choice (`TreeRoot16` / `TreeRoot32`), so this is the value that says
  /// which verifier this pool is wired to.
  function test_MaxBatchMatchesTheDeployedTreeDepth() public view {
    assertEq(pool.MAX_BATCH(), 16, 'MAX_BATCH diverged from the deployed tree depth');
  }
}
