// Privacy Pool STATE-tree mirror — the commitment-tree counterpart to postman/identityAsp.ts, and
// the missing half of sec. 2.1 (withdrawal witness assembly). Produces the `state_root` /
// `state_leaf_index` / `state_siblings` inputs that withdraw_identity's main() requires.
//
// Same construction as IdentityAspTree (LeanIMT via @zk-kit/lean-imt, Poseidon from @iden3/js-crypto
// injected as the pluggable node hash), because State.sol builds its tree with the same
// `lean-imt/InternalLeanIMT.sol` the ASP tree uses. Deliberately NOT a second copy of that class,
// though — three properties genuinely differ, and each one is a correctness trap if carried over:
//
//  1. DUPLICATE LEAVES ARE LEGAL HERE. IdentityAspTree rejects an already-admitted leaf as a LOCAL
//     rule. This comment used to say the chain enforced it, via `Entrypoint._admitIdentity` and
//     `aspAdmitted[_holderRoot]` — CORRECTED 2026-08-03: no such function, mapping or ASP tree
//     exists in Entrypoint, so NOTHING on-chain rejects a re-admission. State._insert enforces
//     NOTHING of the kind — it inserts whatever it is given. So this class must not reject
//     duplicates (that would make the mirror diverge from the chain it is mirroring), and
//     `LeanIMT.indexOf` — which returns the FIRST match — is not a safe way to locate a leaf.
//     Hence proofs here are taken BY INDEX, with `leafIndexOf` provided separately and made LOUD
//     about ambiguity rather than silently picking the first hit.
//  2. THE LEAF FEED IS `LeafInserted`, NOT `Deposited`/`Withdrawn`. Both PrivacyPool insert sites
//     (deposit at :140, withdrawal change note at :162) funnel through State._insert, which emits
//     exactly one LeafInserted per leaf, in tree order. Replaying the two user-facing events
//     instead would mean re-deriving the interleaving of deposits and withdrawals from block/log
//     order — reconstructible, but strictly worse: LeafInserted IS the authoritative order.
//  3. ROOT VERIFICATION IS EXACT, AND STRONGER THAN THE ASP TREE'S. State exposes currentRoot(),
//     currentTreeSize() AND currentTreeDepth(), so a rebuilt mirror can be checked on all three
//     rather than on a single isKnownRoot() predicate.
//
// `LeafInserted._index` is the TRUE 0-based leaf index. Upstream PP emitted `_merkleTree.size`
// (post-insert, i.e. index + 1) into a field named `_index`; State.sol:152 was corrected to
// `size - 1` on 2026-07-27, when this file became its first consumer. If you are reading this
// against an unpatched upstream deployment, that off-by-one is live and silent.

import { LeanIMT } from "@zk-kit/lean-imt";
import { Poseidon } from "@iden3/js-crypto";
import { Contract } from "ethers";
import type { ContractRunner, EventLog } from "ethers";

/** BN254 scalar field — leaves and internal nodes both live here. */
export const FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** MUST equal State.sol's MAX_TREE_DEPTH and withdraw_identity's `[Field; 32]` sibling arrays.
 *  A mismatch produces a witness the circuit cannot accept. */
export const MAX_TREE_DEPTH = 32;

export interface StateProof {
  leafIndex: bigint;
  /** Padded with 0 up to `maxDepth` — a correct no-op under the LeanIMT carry-up-on-empty rule. */
  siblings: bigint[];
  /** Actual tree depth (<= maxDepth) — what `state_tree_depth` carries, distinct from
   *  `siblings.length` (always `maxDepth` after padding). */
  depth: number;
  /** Root this path reconstructs to — what `state_root` carries. */
  root: bigint;
}

/** Poseidon2 as @zk-kit/lean-imt's pluggable node hash; the library supplies the LeanIMT
 *  carry-up-on-empty-sibling construction itself. */
const hash2 = (a: bigint, b: bigint): bigint => Poseidon.hash([a, b]);

/** Local mirror of PrivacyPool's commitment state tree. Thin wrapper over @zk-kit/lean-imt: adds
 *  field validation and the fixed-depth-padded proof shape the Noir circuit expects. */
export class StateTree {
  private tree: LeanIMT<bigint>;

  constructor(commitments: bigint[] = []) {
    this.tree = new LeanIMT<bigint>(hash2);
    for (const leaf of commitments) this.insert(leaf);
  }

  get size(): number {
    return this.tree.size;
  }

  get depth(): number {
    return this.tree.depth;
  }

  get leaves(): bigint[] {
    return this.tree.leaves;
  }

  get root(): bigint {
    return this.tree.size === 0 ? 0n : this.tree.root;
  }

  /** Append a commitment. NO duplicate check, by design — see this file's header, point 1.
   *  Zero is still rejected: LeanIMT reserves 0 as "empty sibling", so a zero leaf would corrupt
   *  inclusion proofs (the same reason Entrypoint._admitIdentity rejects it). */
  insert(commitmentHash: bigint): void {
    if (commitmentHash <= 0n || commitmentHash >= FIELD) {
      throw new Error("StateTree: leaf must be a nonzero BN254 field element");
    }
    this.tree.insert(commitmentHash);
  }

  /** Locate a commitment, refusing to guess when the answer is ambiguous.
   *
   *  Nothing on-chain prevents the same commitment appearing twice (header, point 1), and the two
   *  occurrences have DIFFERENT inclusion paths. Returning the first — which is what
   *  `LeanIMT.indexOf` does — would silently produce a witness for a leaf the caller did not mean.
   *  Callers that already know the index (discovery can track it) should skip this entirely. */
  leafIndexOf(commitmentHash: bigint): bigint {
    const hits: number[] = [];
    const leaves = this.tree.leaves;
    for (let i = 0; i < leaves.length; i++) if (leaves[i] === commitmentHash) hits.push(i);

    if (hits.length === 0) throw new Error("StateTree: commitment is not in the tree");
    if (hits.length > 1) {
      throw new Error(
        `StateTree: commitment appears at ${hits.length} indices (${hits.join(", ")}) — ambiguous. ` +
          "Pass the known leaf index to proof() instead of resolving by commitment.",
      );
    }
    return BigInt(hits[0]);
  }

  /** Inclusion path for the leaf AT `leafIndex`, shaped for withdraw_identity's
   *  state_leaf_index / state_siblings / state_tree_depth / state_root inputs. */
  proof(leafIndex: bigint, maxDepth: number = MAX_TREE_DEPTH): StateProof {
    if (leafIndex < 0n || leafIndex >= BigInt(this.tree.size)) {
      throw new Error(`StateTree: leaf index ${leafIndex} out of range (size ${this.tree.size})`);
    }
    if (this.tree.depth > maxDepth) {
      throw new Error(
        `StateTree: tree depth ${this.tree.depth} exceeds circuit maxDepth ${maxDepth}`,
      );
    }

    // NOT `LeanIMT.generateProof`. That returns a COMPRESSED sibling list — it omits the levels
    // where the node carries up — together with a RECOMPUTED index matching that compressed list
    // ("the index might be different from the original index of the leaf", its own comment). Pairing
    // those siblings with the caller's true `leafIndex`, which is what this method returned before,
    // misaligns the two for any leaf whose path contains a carry-up: the circuit then walks the
    // wrong pair order and reconstructs a root the pool never held.
    //
    // It went unnoticed because the two agree exactly when no carry-up occurs, i.e. on
    // power-of-two-sized trees — so it works in the tidiest case and fails on most real ones.
    //
    // The circuit (backend/circuits/pp/src/lean_imt.nr) walks ALL MAX_DEPTH levels from
    // `leaf_index.to_le_bits()` and carries up wherever the sibling is 0, so what it needs is a
    // LEVEL-ALIGNED array with an explicit 0 at each carry-up. Building the levels here, from the
    // public leaves, is what produces that alignment.
    const siblings: bigint[] = [];
    let level: bigint[] = this.tree.leaves;
    let index = Number(leafIndex);
    for (let d = 0; d < this.tree.depth; d++) {
      const siblingIndex = index % 2 === 0 ? index + 1 : index - 1;
      siblings.push(level[siblingIndex] ?? 0n); // absent sibling => 0 => carry up
      const next: bigint[] = [];
      for (let i = 0; i < level.length; i += 2) {
        next.push(i + 1 < level.length ? hash2(level[i]!, level[i + 1]!) : level[i]!);
      }
      level = next;
      index >>= 1;
    }

    // Rebuilding the levels duplicates the library's construction, and a silent divergence would
    // produce a well-formed proof of the wrong tree. Cheap to rule out, so ruled out.
    if (level.length !== 1 || level[0] !== this.root) {
      throw new Error("StateTree: rebuilt levels disagree with the tree root");
    }

    const padded = [...siblings, ...Array(maxDepth - siblings.length).fill(0n)];

    return { leafIndex, siblings: padded, depth: this.tree.depth, root: this.root };
  }
}

// @contract PrivacyPoolSimple
const POOL_STATE_ABI = [
  "event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)",
  "function currentRoot() external view returns (uint256)",
  "function currentTreeDepth() external view returns (uint256)",
  "function currentTreeSize() external view returns (uint256)",
] as const;

export interface LoadStateTreeOptions {
  fromBlock?: number | bigint;
  toBlock?: number | bigint | "latest";
  /**
   * Skip the post-rebuild check against the pool's own currentRoot/size/depth.
   *
   * Only sensible when deliberately rebuilding to a HISTORICAL `toBlock` (the chain has moved on,
   * so a mismatch is expected and meaningless). Never set it to silence a mismatch at head — that
   * mismatch means the mirror is wrong, and the resulting proof would be rejected on-chain with
   * nothing pointing back here.
   */
  skipVerification?: boolean;
}

/** Rebuild the state-tree mirror from chain state so a withdrawer can produce their inclusion path.
 *
 *  The pool stores only the tree's root and internal accumulator — membership paths cannot be read
 *  out of contract storage — so `LeafInserted` is the leaf feed, and replaying it in index order
 *  reconstructs exactly the tree the contract built (insertion order fully determines a LeanIMT).
 *
 *  VERIFY, DON'T TRUST: unless `skipVerification`, the rebuilt root, size and depth are checked
 *  against the pool. A truncated log range otherwise yields a valid-LOOKING tree whose root the
 *  contract has never held.
 *
 *  On staleness: PP keeps ROOT_HISTORY_SIZE = 64 past roots (State._isKnownRoot), so a proof built
 *  here stays valid while up to 63 further leaves land before it is submitted. Beyond that the
 *  witness must be rebuilt — this is a real race for a busy pool, not a theoretical one.
 */
export async function loadStateTree(
  poolAddress: string,
  runner: ContractRunner,
  opts: LoadStateTreeOptions = {},
): Promise<StateTree> {
  const fromBlock = opts.fromBlock ?? 0;
  const toBlock = opts.toBlock ?? "latest";
  const pool = new Contract(poolAddress, POOL_STATE_ABI, runner);

  const events = (await pool.queryFilter(
    pool.filters.LeafInserted(),
    fromBlock,
    toBlock,
  )) as EventLog[];

  // Sort by the contract's own leaf index, not by log order: eth_getLogs ordering is not guaranteed
  // ascending by every provider, and a LeanIMT replayed out of order yields a different, wrong root.
  const inserted = events
    .map((e) => ({
      index: BigInt(e.args._index as bigint),
      leaf: BigInt(e.args._leaf as bigint),
    }))
    .sort((a, b) => (a.index < b.index ? -1 : a.index > b.index ? 1 : 0));

  inserted.forEach((entry, i) => {
    if (entry.index !== BigInt(i)) {
      throw new Error(
        `loadStateTree: gap in LeafInserted log — expected leaf index ${i}, got ${entry.index}. ` +
          "Widen fromBlock/toBlock; a partial log range cannot reconstruct the tree.",
      );
    }
  });

  const tree = new StateTree(inserted.map((e) => e.leaf));

  if (!opts.skipVerification) {
    const [onchainRoot, onchainSize, onchainDepth] = await Promise.all([
      pool.currentRoot() as Promise<bigint>,
      pool.currentTreeSize() as Promise<bigint>,
      pool.currentTreeDepth() as Promise<bigint>,
    ]);
    if (BigInt(tree.size) !== BigInt(onchainSize)) {
      throw new Error(
        `loadStateTree: rebuilt ${tree.size} leaves but the pool reports ${onchainSize}. ` +
          "The log range is incomplete, or toBlock is not head.",
      );
    }
    if (tree.root !== BigInt(onchainRoot)) {
      throw new Error(
        `loadStateTree: rebuilt root ${tree.root} != on-chain root ${onchainRoot}. ` +
          "Do not prove against this tree.",
      );
    }
    if (BigInt(tree.depth) !== BigInt(onchainDepth)) {
      throw new Error(
        `loadStateTree: rebuilt depth ${tree.depth} != on-chain depth ${onchainDepth}.`,
      );
    }
  }

  return tree;
}
