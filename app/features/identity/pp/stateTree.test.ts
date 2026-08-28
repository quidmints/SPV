// Run: node --test src/pp/stateTree.test.ts
//
// THE MIRROR OF THE POOL'S COMMITMENT TREE, and the source of the inclusion path a withdrawal
// proves against. Everything here fails silently: a wrong root, a mis-shaped sibling array or a
// padding that is not the no-op it is documented to be all produce a witness that LOOKS valid, is
// accepted by the prover, and is then rejected on-chain with nothing pointing back to this file.
//
// THE CENTRAL TEST IS `rootFromPath`. `proof()` pads siblings with zeros up to `MAX_TREE_DEPTH` and
// claims that is "a correct no-op under the LeanIMT carry-up-on-empty rule". Asserting that with
// the library's own verifier would prove nothing — it would be the library agreeing with itself,
// the same trap as Go testing Go in NotaryRegistryProofTest. So the path is walked here by an
// INDEPENDENT reimplementation of the rule the Noir circuit applies, and the claim is that it
// reconstructs the root for every leaf of every tree size below.
import test from "node:test";
import assert from "node:assert";
import { Poseidon } from "@iden3/js-crypto";
import { FIELD, MAX_TREE_DEPTH, StateTree } from "./stateTree.ts";

/** Distinct, valid leaves. Values are arbitrary but must be nonzero and in-field. */
const leaf = (i: number): bigint => BigInt(i + 1) * 1_000_003n;

/**
 * Walk an inclusion path the way the circuit does, and return the root it reconstructs.
 *
 * Deliberately NOT `LeanIMT.verifyProof`: the point is to check the shape `proof()` hands the
 * circuit against a separate implementation of the same rule. A zero sibling means "no sibling at
 * this level", which carries the node up unchanged — that is what makes zero-padding above the
 * tree's real depth harmless.
 */
function rootFromPath(leafValue: bigint, leafIndex: bigint, siblings: readonly bigint[]): bigint {
  let node = leafValue;
  let index = leafIndex;
  for (const sibling of siblings) {
    if (sibling !== 0n) {
      node = index % 2n === 0n ? Poseidon.hash([node, sibling]) : Poseidon.hash([sibling, node]);
    }
    index /= 2n;
  }
  return node;
}

const treeOf = (n: number) => new StateTree(Array.from({ length: n }, (_, i) => leaf(i)));

// ── the central property ──────────────────────────────────────────────────────────────────────

test("every leaf's padded path reconstructs the root, at every tree size", () => {
  // Sizes chosen to straddle every depth boundary (1, 2, 4, 8, 16) and the odd sizes between them,
  // because the carry-up rule only fires on incomplete levels — a test at powers of two alone would
  // never exercise it.
  for (const size of [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17]) {
    const tree = treeOf(size);
    for (let i = 0; i < size; i++) {
      const p = tree.proof(BigInt(i));
      assert.strictEqual(
        rootFromPath(leaf(i), p.leafIndex, p.siblings),
        p.root,
        `size ${size}, leaf ${i}: the padded path does not reconstruct the root`,
      );
    }
  }
});

test("the zero padding is genuinely a no-op, not merely tolerated", () => {
  // If padding changed the result, the test above would still pass whenever real and padded lengths
  // happened to coincide. Compare the two directly.
  const tree = treeOf(5);
  const p = tree.proof(3n);
  const unpadded = p.siblings.filter((_, i) => i < tree.depth);
  assert.strictEqual(rootFromPath(leaf(3), 3n, unpadded), p.root);
  assert.strictEqual(rootFromPath(leaf(3), 3n, p.siblings), p.root);
});

// ── the shape the circuit requires ────────────────────────────────────────────────────────────

test("siblings are always exactly maxDepth long, whatever the tree size", () => {
  // withdraw_identity declares `[Field; 32]`. A short array is not a smaller proof — it is a witness
  // the circuit cannot accept.
  for (const size of [1, 3, 16, 17]) {
    assert.strictEqual(treeOf(size).proof(0n).siblings.length, MAX_TREE_DEPTH);
  }
  assert.strictEqual(treeOf(4).proof(0n, 8).siblings.length, 8);
});

test("depth is the TREE's depth, not the padded sibling count", () => {
  // These are separate circuit inputs (`state_tree_depth` vs the array length) and conflating them
  // is invisible until the proof is rejected.
  const tree = treeOf(5);
  const p = tree.proof(0n);
  assert.strictEqual(p.depth, tree.depth);
  assert.notStrictEqual(p.depth, p.siblings.length);
});

// ── refusals ──────────────────────────────────────────────────────────────────────────────────

test("a zero or out-of-field leaf is refused", () => {
  // LeanIMT reserves 0 for "empty sibling", so a zero leaf would corrupt every inclusion proof that
  // passes through it — silently, since the tree would still build.
  const tree = new StateTree();
  for (const bad of [0n, -1n, FIELD, FIELD + 1n]) {
    assert.throws(() => tree.insert(bad), /nonzero BN254 field element/);
  }
  assert.strictEqual(tree.size, 0, "a rejected leaf was still inserted");
});

test("an empty tree has root zero, and cannot be proved against", () => {
  const tree = new StateTree();
  assert.strictEqual(tree.root, 0n);
  assert.throws(() => tree.proof(0n), /out of range/);
});

test("an out-of-range leaf index is refused", () => {
  const tree = treeOf(4);
  assert.throws(() => tree.proof(4n), /out of range/);
  assert.throws(() => tree.proof(-1n), /out of range/);
});

test("a duplicate commitment is refused rather than resolved to the first", () => {
  // Nothing on-chain prevents the same commitment twice, and the two occurrences have DIFFERENT
  // paths. Returning the first would hand back a witness for a leaf the caller did not mean.
  const tree = new StateTree([leaf(0), leaf(1), leaf(0)]);
  assert.throws(() => tree.leafIndexOf(leaf(0)), /ambiguous/);
  assert.strictEqual(tree.leafIndexOf(leaf(1)), 1n);
  assert.throws(() => tree.leafIndexOf(leaf(99)), /not in the tree/);
});

test("a tree deeper than the circuit allows is refused", () => {
  const tree = treeOf(5); // depth 3
  assert.throws(() => tree.proof(0n, 2), /exceeds circuit maxDepth/);
});

// ── order dependence ──────────────────────────────────────────────────────────────────────────

test("insertion order determines the root, so replay order is load-bearing", () => {
  // `loadStateTree` replays LeafInserted in index order and claims that reproduces the contract's
  // tree. That claim only has content if order matters.
  const forwards = new StateTree([leaf(0), leaf(1), leaf(2)]);
  const backwards = new StateTree([leaf(2), leaf(1), leaf(0)]);
  assert.notStrictEqual(forwards.root, backwards.root);
  assert.strictEqual(forwards.size, backwards.size);
});

test("appending changes the root, and old paths no longer reconstruct it", () => {
  // The reason a withdrawal must prove against a root the pool still recognises, rather than
  // whatever the mirror holds now.
  const tree = treeOf(4);
  const before = tree.proof(1n);
  tree.insert(leaf(4));
  const after = tree.proof(1n);
  assert.notStrictEqual(after.root, before.root);
  assert.strictEqual(rootFromPath(leaf(1), before.leafIndex, before.siblings), before.root);
});

// ── the cross-language fixture ────────────────────────────────────────────────────────────────

test("the mirror reproduces the root the CIRCUIT and lean-imt.sol agreed on", () => {
  // Everything above is TypeScript checking TypeScript, which cannot catch a shared misunderstanding
  // of the LeanIMT rule — the same trap as Go testing Go in NotaryRegistryProofTest. This value is
  // not ours: it is `test_matches_lean_imt_sol_three_leaves` in backend/circuits/pp/src/lean_imt.nr,
  // whose comment records that LeanIMT.sol's own `root()` was asserted equal to it ON-CHAIN before
  // the number was taken. Tree: insert(1), insert(2), insert(3).
  const EXPECTED_ROOT =
    13816780880028945690020260331303642730075999758909899334839547418969502592169n;

  const tree = new StateTree([1n, 2n, 3n]);
  assert.strictEqual(tree.root, EXPECTED_ROOT, "the wallet's tree disagrees with the circuit's");
  assert.strictEqual(tree.depth, 2);

  // ...and the proof shape matches the one the circuit's vector feeds to `lean_imt_inclusion`:
  // leaf 1 at index 0, siblings [2, 3] — level-aligned, then zero-padded.
  const p = tree.proof(0n);
  assert.deepStrictEqual(p.siblings.slice(0, 2), [2n, 3n]);
  assert.ok(p.siblings.slice(2).every((s) => s === 0n));
  assert.strictEqual(p.root, EXPECTED_ROOT);

  // The carried-up leaf is the case the old code got wrong: leaf 3 sits at index 2, carries up at
  // level 0, and its sibling array must therefore START with an explicit zero.
  const carried = tree.proof(2n);
  assert.strictEqual(carried.siblings[0], 0n, "the carry-up level was omitted instead of zeroed");
  assert.strictEqual(rootFromPath(3n, 2n, carried.siblings), EXPECTED_ROOT);
});
