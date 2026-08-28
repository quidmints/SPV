// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from '../../../src/identity/libraries/Poseidon.sol';

// Drives solarity's SMT directly with the same hashers IdentityRegistry uses.
contract SolaritySmtHarness {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  SparseMerkleTree.Bytes32SMT internal _tree;

  constructor(uint32 depth_) {
    _tree.initialize(depth_);
    _tree.setHashers(_h2, _h3);
  }

  function add(bytes32 k, bytes32 v) external {
    _tree.add(k, v);
  }

  function update(bytes32 k, bytes32 v) external {
    _tree.update(k, v);
  }

  function getProof(bytes32 k) external view returns (SparseMerkleTree.Proof memory) {
    return _tree.getProof(k);
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
  }

  function _h2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a), uint256(b)]));
  }

  function _h3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a), uint256(b), uint256(c)]));
  }
}

/*
 * THE COMPATIBILITY QUESTION THAT GATES THE revocation_root WIRING.
 *
 * The Noir exclusion gadget (noir_dl_lib/src/smt.nr) is differential-tested against CIRCOMLIBJS.
 * The on-chain registry uses @solarity's SparseMerkleTree. Both hash leaves as Poseidon(key,value,1)
 * and nodes as Poseidon(L,R) - confirmed by reading the source.
 *
 * IDENTICAL HASHING DOES NOT IMPLY AN IDENTICAL TREE. Bit order, sparse-subtree collapsing and
 * single-leaf short-circuiting are free choices that change the ROOT for the same key set. If
 * solarity places nodes differently the circuit could never verify against the registry root, and
 * the gadget would have to be re-derived against solarity. Reading the hash functions is NOT enough
 * to answer this - only building the same key set in both is.
 */
contract SmtCompatTest is Test {
  /// Root circomlibjs produces for {1:11, 2:22, 7:77, 9:99}.
  bytes32 internal constant CIRCOMLIBJS_ROOT =
    bytes32(uint256(518494836555806875742446376098343000486175381741467406929375446995815951571));

  function test_SolarityMatchesCircomlibjsRoot() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(1)), bytes32(uint256(11)));
    t.add(bytes32(uint256(2)), bytes32(uint256(22)));
    t.add(bytes32(uint256(7)), bytes32(uint256(77)));
    t.add(bytes32(uint256(9)), bytes32(uint256(99)));

    emit log_named_uint('solarity  ', uint256(t.root()));
    emit log_named_uint('circomlibjs', uint256(CIRCOMLIBJS_ROOT));

    assertEq(
      t.root(),
      CIRCOMLIBJS_ROOT,
      'solarity and circomlib build DIFFERENT trees - the Noir gadget cannot verify against the registry'
    );
  }
}

/*
 * MERGED-TREE INTEGRATION (sec. 2.13k/2.13m).
 *
 * The single identity tree encodes STATUS IN THE VALUE: `commitment -> 0` is registered-and-clean,
 * `commitment -> predicate` is revoked, and a withdrawal proves INCLUSION WITH VALUE 0.
 *
 * pp/src/smt.nr already proves the CIRCUIT handles value 0 soundly - an absent key cannot be
 * claimed present, and a revoked leaf cannot claim 0. That says nothing about whether the ON-CHAIN
 * tree builds the same shape for a zero value. `add(key, 0)` is a case no caller had ever exercised
 * here: the revocation-only registry this replaced only ever added a NON-ZERO predicate. If solarity special-cased a zero
 * value - skipping the write, or collapsing the leaf toward an empty node - the registry root and
 * the circuit's root would silently diverge and EVERY withdrawal would fail with no diagnostic
 * pointing at the cause.
 *
 * These tests are the end-to-end pin: the same key/value the Noir tests use, built on-chain, must
 * produce the identical root.
 */
contract SmtMergedTreeCompatTest is Test {
  /// Poseidon([5, 0, 1]) - the leaf, and therefore the root, of a one-entry tree holding key 5 with
  /// value 0. Identical to pp/src/smt.nr::ZERO_VALUE_ROOT.
  bytes32 internal constant ZERO_VALUE_ROOT =
    bytes32(uint256(15_739_329_723_942_587_145_467_652_550_645_860_604_592_570_947_603_611_249_889_485_952_228_479_492_237));
  /// Poseidon([5, 77, 1]) - the same key carrying a non-zero status.
  bytes32 internal constant NONZERO_VALUE_ROOT =
    bytes32(uint256(14_129_927_926_970_119_856_674_073_289_737_812_168_216_833_984_581_917_537_350_058_345_827_753_032_716));

  /// THE INTEGRATION TRAP: a zero value must be stored as a real leaf, not silently dropped.
  function test_ZeroValueLeafMatchesTheCircuitRoot() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(5)), bytes32(0));

    assertEq(
      t.root(),
      ZERO_VALUE_ROOT,
      'solarity builds a DIFFERENT root for a zero value - the merged tree cannot verify in-circuit'
    );
  }

  /// A zero value must NOT leave the tree looking empty. If it did, "registered and clean" would be
  /// indistinguishable on-chain from "never registered".
  function test_ZeroValueIsNotAnEmptyTree() public {
    SolaritySmtHarness empty = new SolaritySmtHarness(20);
    SolaritySmtHarness withZero = new SolaritySmtHarness(20);
    withZero.add(bytes32(uint256(5)), bytes32(0));

    assertTrue(withZero.root() != empty.root(), 'a zero-valued leaf left the tree indistinguishable from empty');
    assertTrue(withZero.root() != bytes32(0), 'a zero-valued leaf produced the empty root');
  }

  /// Revocation is an UPDATE (0 -> predicate), not an add. This pins that the transition produces
  /// exactly the root the circuit computes for the new value, so a revocation actually takes effect.
  function test_RevocationUpdatesZeroToPredicate() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(5)), bytes32(0));
    assertEq(t.root(), ZERO_VALUE_ROOT, 'clean root wrong before revocation');

    t.update(bytes32(uint256(5)), bytes32(uint256(77)));
    assertEq(t.root(), NONZERO_VALUE_ROOT, 'revoked root does not match the circuit leaf hash');
  }

  /// A second escrow of the SAME commitment must revert. `s` is secret and random so a collision is
  /// not expected, but if it were permitted an attacker who learned a victim's `s` before they
  /// escrowed could seize their slot - or a re-add could reset a REVOKED entry back to clean.
  function test_DuplicateCommitmentIsRejected() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(5)), bytes32(0));

    vm.expectRevert(abi.encodeWithSelector(SparseMerkleTree.KeyAlreadyExists.selector, bytes32(uint256(5))));
    t.add(bytes32(uint256(5)), bytes32(0));
  }

  /// Re-adding a REVOKED key must also fail. This is the same guard as above, stated against the
  /// case that actually matters: if it were allowed, revocation could be undone by re-registering.
  function test_RevokedCommitmentCannotBeReAdded() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(5)), bytes32(0));
    t.update(bytes32(uint256(5)), bytes32(uint256(77)));

    vm.expectRevert(abi.encodeWithSelector(SparseMerkleTree.KeyAlreadyExists.selector, bytes32(uint256(5))));
    t.add(bytes32(uint256(5)), bytes32(0));
  }
}
