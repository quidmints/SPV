// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {BatchCommitmentLib} from 'contracts/pool/lib/BatchCommitmentLib.sol';

/*
 * THE CIRCUITS AND THE CONTRACT MUST AGREE ABOUT THE BATCH COMMITMENT (TODO.md sec. 2.4 / 2.18el).
 *
 * The tree's root verifier exposes ONE public input - the root - so this recomputation is the only
 * thing tying that field back to the individual withdrawals a batch settles. If the two
 * implementations diverge, nothing says so: the circuits prove happily, the contract recomputes
 * happily, and they produce different field elements.
 *
 * THIS TEST ONCE HELD A FROZEN CONSTANT AND SLEPT THROUGH A REAL DIVERGENCE (2.18ec). The circuit
 * moved to keccak while the library stayed on chained Poseidon v1, and this file kept passing,
 * because a pinned number only asks whether SOLIDITY changed. The question is whether the two SIDES
 * agree.
 *
 * SO THE ANCHOR IS A REAL PROOF. `recursion_tree_n16.json` carries the sixteen withdrawals' signals
 * AND the root its genuine proof exposes on-chain. Recomputing the tree from those signals and
 * requiring the real root back is the strongest form of this check available: it compares the
 * contract against what the CIRCUITS ACTUALLY PRODUCED, not against a number typed in beside them.
 * Regenerate with `python3 build-recursion-tree.py 16`.
 */
contract BatchCommitmentTest is Test {
  uint256 internal constant PUB_LEN = 8;
  uint256 internal constant FIELD_MODULUS =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  string internal fixture;

  function setUp() public {
    fixture = vm.readFile('test/fixtures/recursion_tree_n16.json');
  }

  /// The sixteen withdrawals the committed proof actually settled.
  function _fixtureSignals() internal view returns (uint256[PUB_LEN][] memory s) {
    uint256 n = vm.parseJsonUint(fixture, '.batchSize');
    s = new uint256[PUB_LEN][](n);
    for (uint256 i = 0; i < n; ++i) {
      bytes32[] memory row =
        vm.parseJsonBytes32Array(fixture, string.concat('.signals[', vm.toString(i), ']'));
      for (uint256 j = 0; j < PUB_LEN; ++j) s[i][j] = uint256(row[j]);
    }
  }

  /// The root that proof exposes - the value the on-chain verifier accepted.
  function _fixtureRoot() internal view returns (uint256) {
    return uint256(vm.parseJsonBytes32Array(fixture, '.publicInputs')[0]);
  }

  /*
   * `build-recursion-tree.py`'s two templates, transcribed from the CIRCUITS and deliberately
   * INDEPENDENT of BatchCommitmentLib. A second implementation on purpose: if the library is edited
   * to match a wrong idea of the circuits, this does not follow it.
   */
  function _circuitTree(uint256[PUB_LEN][] memory signals) internal pure returns (uint256) {
    uint256[] memory level = new uint256[](signals.length / 2);
    for (uint256 i = 0; i < level.length; ++i) {
      bytes memory pre;
      for (uint256 j = 0; j < PUB_LEN; ++j) pre = bytes.concat(pre, bytes32(signals[2 * i][j]));
      for (uint256 j = 0; j < PUB_LEN; ++j) pre = bytes.concat(pre, bytes32(signals[2 * i + 1][j]));
      level[i] = uint256(keccak256(pre)) % FIELD_MODULUS;
    }
    while (level.length > 1) {
      uint256[] memory next = new uint256[](level.length / 2);
      for (uint256 i = 0; i < next.length; ++i) {
        next[i] = uint256(
          keccak256(bytes.concat(bytes32(level[2 * i]), bytes32(level[2 * i + 1])))
        ) % FIELD_MODULUS;
      }
      level = next;
    }
    return level[0];
  }

  /// THE ANCHOR: the transcription reproduces the root a REAL proof exposed. If this fails, the
  /// transcription has drifted from the circuits - do not "fix" it by pasting in whatever it now
  /// produces without first establishing which side moved.
  function test_TheTranscriptionReproducesARealProofsRoot() public view {
    assertEq(_circuitTree(_fixtureSignals()), _fixtureRoot(), 'the transcription is not the circuit');
  }

  /// THE BASELINE: the library agrees with the circuits, via the same real proof.
  function test_MatchesTheCircuit() public view {
    assertEq(
      BatchCommitmentLib.treeCommitment(_fixtureSignals()),
      _fixtureRoot(),
      'the circuits and the contract disagree about the batch commitment'
    );
  }

  /// ...and it is not vacuous: changing any single signal must change the root. Without this, a
  /// commitment that ignored its inputs entirely would pass everything above.
  function test_EverySignalIsBound() public view {
    uint256 baseline = BatchCommitmentLib.treeCommitment(_fixtureSignals());
    uint256[PUB_LEN][] memory s = _fixtureSignals();
    for (uint256 i = 0; i < s.length; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        uint256[PUB_LEN][] memory m = _fixtureSignals();
        m[i][j] ^= 1;
        assertTrue(
          BatchCommitmentLib.treeCommitment(m) != baseline,
          'a signal position does not affect the root'
        );
      }
    }
  }

  /// ORDER-BINDING. Swapping two withdrawals must change the root, or a batcher could permute the
  /// batch relative to the calldata the contract walks - moving one user's recipient context onto
  /// another's nullifier while still matching.
  function test_OrderIsBound() public view {
    uint256[PUB_LEN][] memory a = _fixtureSignals();
    uint256[PUB_LEN][] memory b = _fixtureSignals();
    (b[0], b[1]) = (b[1], b[0]);
    assertTrue(
      BatchCommitmentLib.treeCommitment(a) != BatchCommitmentLib.treeCommitment(b),
      'the tree is commutative - withdrawals can be permuted'
    );
  }

  /// SWAPPING ACROSS SUBTREES too, not only within a leaf. A tree hash could in principle bind
  /// position within a pair while leaving whole subtrees interchangeable.
  function test_OrderIsBoundAcrossSubtrees() public view {
    uint256[PUB_LEN][] memory a = _fixtureSignals();
    uint256[PUB_LEN][] memory b = _fixtureSignals();
    (b[0], b[8]) = (b[8], b[0]);
    assertTrue(
      BatchCommitmentLib.treeCommitment(a) != BatchCommitmentLib.treeCommitment(b),
      'whole subtrees are interchangeable'
    );
  }

  /// A batch of a different SIZE settles at a different tree DEPTH, which is a different deployed
  /// verifier entirely - but the roots must differ regardless, so a truncated batch cannot reuse a
  /// root it did not produce.
  function test_LengthIsBound() public view {
    uint256[PUB_LEN][] memory full = _fixtureSignals();
    uint256[PUB_LEN][] memory half = new uint256[PUB_LEN][](full.length / 2);
    for (uint256 i = 0; i < half.length; ++i) half[i] = full[i];
    assertTrue(
      BatchCommitmentLib.treeCommitment(half) != BatchCommitmentLib.treeCommitment(full),
      'a shorter batch produced the same root'
    );
  }

  /// A tree is built from PAIRS, so a batch that is not a power of two could not have been proved by
  /// one. The flat fold absorbed any length silently; this cannot, and that is a gain.
  function test_ANonPowerOfTwoBatchIsRefused() public {
    uint256[PUB_LEN][] memory odd = new uint256[PUB_LEN][](6);
    vm.expectRevert(abi.encodeWithSelector(BatchCommitmentLib.NotAPowerOfTwo.selector, 6));
    this.callTreeCommitment(odd);
  }

  /// And a batch too small to make a single leaf.
  function test_ASingleWithdrawalIsRefused() public {
    uint256[PUB_LEN][] memory one = new uint256[PUB_LEN][](1);
    vm.expectRevert(abi.encodeWithSelector(BatchCommitmentLib.BatchTooSmall.selector, 1));
    this.callTreeCommitment(one);
  }

  /// `external` so `vm.expectRevert` sees a call boundary - the library function is `internal` and
  /// would otherwise revert inside the test frame.
  function callTreeCommitment(uint256[PUB_LEN][] memory s) external pure {
    BatchCommitmentLib.treeCommitment(s);
  }

  /*
   * A PADDED BATCH COMMITS EXACTLY AS A FULL ONE DOES. Five real withdrawals settle as a tree of
   * eight, and the three spare leaves are genuine zero-value spends the contract skips. The
   * commitment must still reproduce the root that padded tree's REAL proof exposed - otherwise
   * "settle with whoever is here" does not work and everyone waits for a full batch.
   */
  function test_APaddedBatchReproducesItsRoot() public view {
    string memory f = vm.readFile('test/fixtures/recursion_tree_n8.json');
    uint256 n = vm.parseJsonUint(f, '.batchSize');
    uint256[PUB_LEN][] memory sig = new uint256[PUB_LEN][](n);
    for (uint256 i = 0; i < n; ++i) {
      bytes32[] memory row = vm.parseJsonBytes32Array(f, string.concat('.signals[', vm.toString(i), ']'));
      for (uint256 j = 0; j < PUB_LEN; ++j) sig[i][j] = uint256(row[j]);
    }
    assertEq(n, 8, 'the padded tree should hold eight leaves');
    assertEq(vm.parseJsonUint(f, '.realWithdrawals'), 5, 'five of them should be real');

    uint256 padded;
    for (uint256 i = 0; i < n; ++i) if (sig[i][2] == 0) ++padded;
    assertEq(padded, 3, 'three leaves should be zero-value padding');

    assertEq(
      BatchCommitmentLib.treeCommitment(sig),
      uint256(vm.parseJsonBytes32Array(f, '.publicInputs')[0]),
      'a padded batch does not reproduce its own root'
    );
  }

  /// GAS: what the on-chain recompute costs per withdrawal.
  function test_GasOfTheTree() public view {
    uint256[PUB_LEN][] memory s = _fixtureSignals();
    uint256 g0 = gasleft();
    BatchCommitmentLib.treeCommitment(s);
    uint256 used = g0 - gasleft();
    console.log('tree recompute gas total', used);
    console.log('per withdrawal          ', used / s.length);
  }
}
