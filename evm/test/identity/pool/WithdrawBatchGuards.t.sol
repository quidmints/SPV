// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BatchCommitmentLib} from 'contracts/pool/lib/BatchCommitmentLib.sol';
import {BatchVerifierLib} from 'contracts/pool/lib/BatchVerifierLib.sol';
import {INoirVerifier} from 'contracts/interfaces/verifiers/INoirVerifier.sol';

/*
 * THE PROPERTIES `withdrawBatch`'s GUARDS REST ON.
 *
 * BE PRECISE ABOUT WHAT THIS FILE IS. It does NOT call `withdrawBatch`. It pins the properties of
 * `BatchCommitmentLib` that the guards ASSUME - that the commitment is order-binding, length-binding,
 * and sensitive to every context and root - because if any of those is false, guards written on top
 * of them are decorative no matter how they are tested.
 *
 * WHAT IS STILL UNTESTED, so this suite's green is not over-read:
 *   1. `withdrawBatch` itself - no test calls it. The revert paths (BatchLengthMismatch,
 *      ContextMismatch, EmptyBatch, BatchTooLarge) are UNEXERCISED.
 *   2. The HAPPY PATH. Settling a real batch needs a genuine N=16 aggregation proof, ~27 GB to
 *      produce, so it cannot be made on an ordinary dev machine (TODO.md sec. 2.4a).
 *   3. Double-spend ACROSS a batch - two withdrawals sharing a nullifier. `_spend` should reject the
 *      second, but nothing here proves it.
 * **Do not deploy `withdrawBatch` on the strength of this suite.**
 *
 * WHY NO MOCK VERIFIER. One returning `true` would let (1) and (3) be tested today, at the cost of
 * asserting that the only thing that really matters - does the proof bind? - is irrelevant. The
 * circuit's soundness is established separately and properly by the `rmin` harness (real proof
 * ACCEPTED, valid proof of a DIFFERENT statement REFUSED, garbage REFUSED). Standing rule: never mock.
 */
contract WithdrawBatchGuardsTest is Test {
  uint256 internal constant PUB_LEN = 8;
  uint256 internal constant MAX_BATCH = 16;

  function _signals(uint256 n) internal pure returns (uint256[PUB_LEN][] memory s) {
    s = new uint256[PUB_LEN][](n);
    for (uint256 i = 0; i < n; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        s[i][j] = i * 100 + j + 1;
      }
    }
  }

  // ── the two guards inside BatchVerifierLib, which run before the verifier is ever called ──────

  /// An empty batch is REFUSED, which is what the name has always claimed and what the body did not
  /// check. It previously asserted only that the empty fold was zero - true under the Poseidon chain
  /// this library used to be, false since it moved to keccak, and never the point either way: the
  /// commitment of an empty batch is a perfectly ordinary field element that a proof could in
  /// principle be made for, so the guard is what stops a batch settling nothing.
  ///
  /// THE VERIFIER IS address(0) ON PURPOSE, and this is not a mock. `EmptyBatch` is checked before
  /// any external call, so reverting with THAT error rather than a failed call to an empty address is
  /// itself the evidence that the guard short-circuits.
  function test_EmptyBatchIsRejected() public {
    uint256[PUB_LEN][] memory none = new uint256[PUB_LEN][](0);
    vm.expectRevert(BatchVerifierLib.EmptyBatch.selector);
    this.callVerifyBatch(hex'', none);
  }

  /// ...and an empty batch has no commitment AT ALL now: a tree is built from pairs, so zero
  /// withdrawals is not a shape the recomputation can express. Stronger than the old behaviour,
  /// where the empty batch produced an ordinary-looking field element a proof could be made for.
  function test_AnEmptyBatchHasNoCommitment() public {
    uint256[PUB_LEN][] memory none = new uint256[PUB_LEN][](0);
    vm.expectRevert(abi.encodeWithSelector(BatchCommitmentLib.BatchTooSmall.selector, 0));
    this.callTreeCommitment(none);
  }

  function callTreeCommitment(uint256[PUB_LEN][] memory s) external pure {
    BatchCommitmentLib.treeCommitment(s);
  }

  /// `external` so `vm.expectRevert` sees a call boundary - the library function is `internal` and
  /// would otherwise revert inside the test frame.
  function callVerifyBatch(bytes calldata proof, uint256[PUB_LEN][] memory signals) external view {
    BatchVerifierLib.verifyBatch(INoirVerifier(address(0)), proof, signals, MAX_BATCH);
  }

  /// Tree DEPTH is fixed by the deployed verifier, so a batch bigger than this one settles cannot
  /// have been proved by it. The commitment alone STILL cannot catch that: a batch of 32 is a
  /// perfectly well-formed tree, just a taller one - which is exactly why `BatchTooLarge` is a
  /// separate check against the depth this verifier was deployed for.
  function test_TheCommitmentAloneCannotCatchAnOverlongBatch() public pure {
    uint256[PUB_LEN][] memory big = _signals(MAX_BATCH * 2);
    // It commits without complaint; only the deployed depth knows this is the wrong batch.
    assertTrue(BatchCommitmentLib.treeCommitment(big) != 0);
  }

  // ── the properties the guards rest on ─────────────────────────────────────────────────────────

  /// ORDER. A permuted batch must produce a different commitment, or a batcher could pair one user's
  /// recipient context with another's nullifier while still satisfying the proof.
  function test_PermutingTheBatchChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory b = _signals(MAX_BATCH);
    (b[0], b[1]) = (b[1], b[0]);
    assertTrue(
      BatchCommitmentLib.treeCommitment(a) != BatchCommitmentLib.treeCommitment(b),
      'the fold is commutative - the batch can be permuted'
    );
  }

  /// CONTEXT IS SIGNAL 6, and altering it must change the commitment - that is what makes the
  /// per-withdrawal context comparison in `withdrawBatch` load-bearing rather than decorative.
  function test_ChangingAContextChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256 baseline = BatchCommitmentLib.treeCommitment(a);
    for (uint256 i = 0; i < MAX_BATCH; ++i) {
      uint256[PUB_LEN][] memory m = _signals(MAX_BATCH);
      m[i][6] ^= 1; // signal 6 is `context`
      assertTrue(
        BatchCommitmentLib.treeCommitment(m) != baseline,
        'a withdrawal context does not affect the commitment'
      );
    }
  }

  /// LENGTH. Truncating the batch must not collide - the cheapest attack is to drop a withdrawal.
  /// Halved rather than decremented, because a tree only exists at power-of-two sizes; dropping ONE
  /// withdrawal is now refused outright by `NotAPowerOfTwo`, which is a stronger answer than a
  /// different commitment.
  function test_TruncatingTheBatchChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory full = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory short = _signals(MAX_BATCH / 2);
    assertTrue(
      BatchCommitmentLib.treeCommitment(full) != BatchCommitmentLib.treeCommitment(short),
      'a truncated batch produced the same commitment'
    );
  }

  /// And dropping a single withdrawal is not merely different, it is unprovable.
  function test_DroppingOneWithdrawalIsRefused() public {
    vm.expectRevert(
      abi.encodeWithSelector(BatchCommitmentLib.NotAPowerOfTwo.selector, MAX_BATCH - 1)
    );
    this.callTreeCommitment(_signals(MAX_BATCH - 1));
  }

  /// THE ROOT MEMO MUST NOT WEAKEN ANYTHING. `withdrawBatch` checks each DISTINCT state/identity root
  /// once instead of per withdrawal. That is only equivalent if differing roots are still each
  /// checked - so a batch carrying two different roots must not let the second ride on the first.
  /// This pins the ASSUMPTION the memo rests on: the roots are part of the committed signals, so a
  /// batch with a different root set is a different batch.
  function test_RootsAreCommittedSoTheMemoCannotHideOne() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory b = _signals(MAX_BATCH);
    b[3][3] ^= 1; // signal 3 is `state_root`, on the 4th withdrawal
    assertTrue(
      BatchCommitmentLib.treeCommitment(a) != BatchCommitmentLib.treeCommitment(b),
      'a state root change is invisible to the commitment'
    );
    uint256[PUB_LEN][] memory c = _signals(MAX_BATCH);
    c[3][5] ^= 1; // signal 5 is `identity_root`
    assertTrue(
      BatchCommitmentLib.treeCommitment(a) != BatchCommitmentLib.treeCommitment(c),
      'an identity root change is invisible to the commitment'
    );
  }
}
