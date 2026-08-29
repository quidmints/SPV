// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {TreeRoot16HonkVerifier} from '../../../src/identity/generated/pool/verifiers/TreeRoot16HonkVerifier.sol';
import {TreeRoot32HonkVerifier} from '../../../src/identity/generated/pool/verifiers/TreeRoot32HonkVerifier.sol';
import {INoirVerifier} from '../../../src/identity/interfaces/verifiers/INoirVerifier.sol';

/*
 * A SIXTEEN-WITHDRAWAL BATCH SETTLED FROM A RECURSION TREE, VERIFIED ON-CHAIN (2026-08-04).
 *
 * WHAT THIS EXISTS TO SHOW. `AggregationProofOnChain.t.sol` verifies the FLAT design: one circuit
 * that verifies all sixteen withdrawal proofs at once, 12,720,801 gates and ~21.7 GB to prove. That
 * cost is why the batcher has to be a server. This verifies the same batch produced by a TREE of
 * two-proof nodes - fifteen of them, none larger than ~1.54M gates, ~2.1 GB peak - and the point is
 * that the thing arriving on-chain is indistinguishable in kind: an ordinary UltraHonk proof with
 * ONE public input, checked by a generated Solidity verifier.
 *
 * SO THE TRADE IS NOT "cheap prover OR trustless settlement". Both designs settle trustlessly; they
 * differ only in what the batcher needs to own.
 *
 * WHAT THE FIXTURE IS. Sixteen GENUINELY DIFFERENT withdrawals - distinct notes, values, leaf
 * indices, change notes and contexts, one per GENUINE registered identity (sixteen of them, each a
 * real `register` with its own escrow proof) - all against ONE state root and ONE identity root,
 * from `tools/build-fold-witnesses.js`. This matters more than it sounds:
 * the older N=16 aggregation fixture was sixteen IDENTICAL copies of one withdrawal, and a fold over
 * sixteen copies of X cannot be told apart from one that keeps only the last X. Regenerate with:
 *
 *   cd frontend/identity-wallet && npm run build:pp
 *   node tools/build-fold-witnesses.js --build frontend/identity-wallet/build --count 16
 *   cd backend/circuits && python3 build-recursion-tree.py 16
 *
 * TWO DEPTHS ARE DEPLOYED, 16 and 32, because verification gas depends on which TREE settled a batch
 * and not on how full it was. A batch settles at the smallest tree that fits it, so a quiet period
 * costs a depth-4 verification instead of waiting to fill a depth-5.
 *
 * THE ROOT COMMITMENT IS A TREE HASH, not the flat keccak `BatchCommitmentLib` currently computes.
 * Each leaf commits to its two withdrawals' fourteen signals; each internal node commits to
 * `keccak(left ++ right)`. Nothing on-chain recomputes that yet - `BatchCommitmentLib` still folds
 * flat - so this file tests the VERIFIER, not settlement. That move is a money-path change and gets
 * its own run.
 */
contract RecursionTreeProofOnChainTest is Test {
  INoirVerifier internal verifier;
  INoirVerifier internal verifier32;
  string internal fixture;
  string internal fixture32;

  function setUp() public {
    fixture = vm.readFile('test/identity/fixtures/recursion_tree_n16.json');
    verifier = INoirVerifier(address(new TreeRoot16HonkVerifier()));
    fixture32 = vm.readFile('test/identity/fixtures/recursion_tree_n32.json');
    verifier32 = INoirVerifier(address(new TreeRoot32HonkVerifier()));
  }

  /*
   * ONE VERIFIER PER DEPTH, AND THEY ARE NOT INTERCHANGEABLE. A depth-5 root proof is refused by the
   * depth-4 verifier with `SumcheckFailed()` - measured, after a tree-of-32 run overwrote the
   * tree-of-16 verifier and broke this file. That is why the contract name carries N.
   *
   * It is also the shape the design wants. Verification gas does not depend on how FULL a batch is,
   * only on which tree settled it, so deploying several depths lets a batch settle at the smallest
   * tree that fits rather than waiting to fill a fixed one.
   */
  function test_aDepth5TreeSettlesThirtyTwo() public view {
    assertTrue(
      verifier32.verify(
        vm.parseJsonBytes(fixture32, '.proof'),
        vm.parseJsonBytes32Array(fixture32, '.publicInputs')
      ),
      'the tree-of-32 root proof was rejected by its own verifier'
    );
  }

  /// The root proof is the SAME SHAPE at every depth - 334 fields, one public input - which is why
  /// per-withdrawal gas halves each time the batch doubles at no extra verification cost.
  function test_theRootShapeDoesNotGrowWithDepth() public view {
    assertEq(
      vm.parseJsonBytes(fixture32, '.proof').length,
      vm.parseJsonBytes(fixture, '.proof').length,
      'a deeper tree produced a different-sized root proof'
    );
    assertEq(vm.parseJsonBytes32Array(fixture32, '.publicInputs').length, 1);
  }

  /// And a depth-5 proof must NOT verify against the depth-4 verifier. Without this the two could be
  /// swapped in deployment and the mistake would only surface as a rejected settlement.
  function test_aDepth5ProofIsRefusedByTheDepth4Verifier() public {
    vm.expectRevert();
    verifier.verify(
      vm.parseJsonBytes(fixture32, '.proof'),
      vm.parseJsonBytes32Array(fixture32, '.publicInputs')
    );
  }

  function _proof() internal view returns (bytes memory) {
    return vm.parseJsonBytes(fixture, '.proof');
  }

  function _publicInputs() internal view returns (bytes32[] memory) {
    return vm.parseJsonBytes32Array(fixture, '.publicInputs');
  }

  /// THE CLAIM: a batch of sixteen proven by a tree is accepted on-chain.
  function test_aTreeProvenBatchOfSixteenVerifiesOnChain() public view {
    assertTrue(
      verifier.verify(_proof(), _publicInputs()),
      'the recursion-tree root proof was rejected by its own generated verifier'
    );
  }

  /// The shape the tree's root declares. ONE public input is load-bearing for deployability, not
  /// style: the verifier's calldata handling scales with public inputs, and the flat aggregator's own
  /// header records that a design exposing 16 x 7 signals does not fit under EIP-170.
  function test_theRootExposesExactlyOneCommitment() public view {
    assertEq(_publicInputs().length, 1, 'the tree root must expose exactly one public input');
    assertGt(_proof().length, 0, 'empty proof');
    assertEq(_proof().length % 32, 0, 'proof is not a whole number of field elements');
  }

  /// What it costs, against the flat design's measured 2,980,094 for the same sixteen withdrawals.
  /// Gas was never the axis the tree improves - the batcher's memory is - so a number in the same
  /// range is the expected result, and a much larger one would mean something is wrong.
  function test_MeasureTreeRootVerificationGas() public view {
    bytes memory p = _proof();
    bytes32[] memory pubs = _publicInputs();

    uint256 g0 = gasleft();
    bool ok = verifier.verify(p, pubs);
    uint256 used = g0 - gasleft();

    assertTrue(ok);
    console.log('tree root verify() gas (batch of 16):', used);
    console.log('  per withdrawal:', used / 16);
    console.log('  flat aggregation, same batch size:  2980094 (186255 each)');
  }

  /*
   * NON-VACUITY. Without these a verifier that ignored its arguments would pass everything above.
   */
  function test_aTamperedProofIsRejected() public {
    bytes memory p = _proof();
    p[3000] = bytes1(uint8(p[3000]) ^ 0x01);
    vm.expectRevert();
    verifier.verify(p, _publicInputs());
  }

  /// THE ONE THAT MATTERS. The public input IS the root of the commitment tree, so changing it claims
  /// a DIFFERENT sixteen withdrawals. If this passed, a batcher could settle any batch with any
  /// proof and every guard downstream would be decoration.
  function test_aDifferentRootCommitmentIsRejected() public {
    bytes32[] memory pubs = _publicInputs();
    pubs[0] = bytes32(uint256(pubs[0]) ^ 1);
    vm.expectRevert();
    verifier.verify(_proof(), pubs);
  }
}
