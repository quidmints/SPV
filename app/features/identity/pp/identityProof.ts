// Inclusion witness for the identity registry - the `identity_*` inputs a withdrawal proof needs to
// show "this identity is registered AND not revoked" (sec. 2.13k).
//
// REPLACES revocation.ts. That file fetched a NON-inclusion witness from a separate revocation
// registry, alongside a LeanIMT ASP membership path from identityAsp.ts. Both collapse into ONE
// inclusion proof once status lives in the leaf VALUE:
//
//     commitment -> 0          registered and clean
//     commitment -> predicate  revoked, and the value says WHY
//
// So a single INCLUSION of `commitment -> 0` is simultaneously "registered" and "not revoked".
// There is no state a revoked identity can prove.
//
// NO LOCAL TREE MIRROR, DELIBERATELY - the same rule revocation.ts already established and the
// reason it existed. stateTree.ts and identityAsp.ts rebuild their trees off-chain because those
// are LeanIMTs whose contracts expose only a root, so the wallet has no choice. The identity
// registry is a `@solarity` SparseMerkleTree, and `getProof(key)` is a VIEW FUNCTION returning the
// whole witness. Rebuilding it locally would mean writing a second implementation of a sparse trie
// and keeping it byte-compatible forever, for no benefit. Asking the contract is both less code and
// IMPOSSIBLE TO DRIFT.
//
// (A JS mirror was briefly added here and removed: it needed a three-way validation against
// circomlibjs, solarity and the Noir gadget purely to manage divergence risk that asking the
// contract does not have. The validation passing did not make the mirror worth keeping.)
//
// COMPATIBILITY IS PROVEN, NOT ASSUMED. The circuit gadget (pp/src/smt.nr) is a circomlib
// SMTVerifier port, while the registry is solarity. `test/registry/SmtCompat.t.sol` builds the same
// key set through both and asserts byte-identical roots - including the ZERO-VALUE case this design
// introduced, which nothing had exercised before, since the old revocation registry only ever
// stored non-zero predicates.

import { Contract } from "ethers";
import type { ContractRunner } from "ethers";

/** MUST equal the circuit's IDENTITY_TREE_DEPTH AND the registry's constructor `treeHeight_`.
 *  A mismatch makes every inclusion proof fail with no useful diagnostic. */
export const IDENTITY_TREE_DEPTH = 32;

/** The leaf value of a clean identity. Non-zero means revoked, and the value IS the predicate. */
export const STATUS_CLEAN = 0n;

// @contract IdentityRegistry
const IDENTITY_REGISTRY_ABI = [
  "function root() external view returns (bytes32)",
  "function isValidRoot(bytes32 root_) external view returns (bool)",
  "function registered(bytes32 _commitment) external view returns (bool)",
  "function statusOf(bytes32 _commitment) external view returns (bytes32)",
  "function getProof(bytes32 commitment_) external view returns (tuple(bytes32 root, bytes32[] siblings, bool existence, bytes32 key, bytes32 value, bool auxExistence, bytes32 auxKey, bytes32 auxValue))",
] as const;

export interface IdentityWitness {
  identityRoot: bigint;
  siblings: bigint[];
}

/**
 * Fetch the inclusion witness proving `commitment` is registered and clean.
 *
 * THROWS RATHER THAN RETURNING AN UNUSABLE WITNESS. A proof of the wrong shape fails in-circuit
 * with no indication that the real problem is the identity's status, so each failure mode is
 * distinguished here where the diagnostic still exists.
 */
export async function fetchIdentityWitness(
  registryAddress: string,
  runner: ContractRunner,
  commitment: bigint,
): Promise<IdentityWitness> {
  const registry = new Contract(registryAddress, IDENTITY_REGISTRY_ABI, runner);
  const key = "0x" + commitment.toString(16).padStart(64, "0");

  if (!(await registry.registered(key))) {
    throw new Error(
      "fetchIdentityWitness: this commitment is NOT registered. Post the escrow envelope " +
        "(escrow_envelope) before attempting to withdraw - registration is what puts the identity " +
        "in the tree at all.",
    );
  }

  const status: string = await registry.statusOf(key);
  if (BigInt(status) !== STATUS_CLEAN) {
    throw new Error(
      `fetchIdentityWitness: this identity is REVOKED under predicate ${status}. No withdrawal ` +
        "proof exists for a revoked identity - the leaf carries the predicate as its value, so it " +
        "can no longer prove the clean status.",
    );
  }

  const p = await registry.getProof(key);

  if (!p.existence) {
    // Unreachable given the `registered` check above; if it fires, the registry's tree and its
    // `registered` mapping disagree, which is a contract bug worth surfacing loudly.
    throw new Error(
      "fetchIdentityWitness: registry reports the key as ABSENT while registered() said yes",
    );
  }
  if (BigInt(p.value) !== STATUS_CLEAN) {
    // Same class: the tree's leaf value and `statusOf` disagree.
    throw new Error(
      `fetchIdentityWitness: leaf value is ${p.value} while statusOf() reported clean`,
    );
  }

  const siblings: bigint[] = (p.siblings as string[]).map((s) => BigInt(s));
  if (siblings.length > IDENTITY_TREE_DEPTH) {
    throw new Error(
      `fetchIdentityWitness: registry depth ${siblings.length} exceeds the circuit's ` +
        `${IDENTITY_TREE_DEPTH}. The tree has outgrown the circuit; both must be regenerated together.`,
    );
  }
  while (siblings.length < IDENTITY_TREE_DEPTH) siblings.push(0n);

  return { identityRoot: BigInt(p.root), siblings };
}

/**
 * Check a root is still acceptable before proving against it.
 *
 * The registry expires superseded roots after MAX_ROOT_AGE while the LATEST root never expires.
 * EXPIRY IS REQUIRED on this tree in a way it would not be on a pure inclusion tree: an old root
 * has fewer REVOCATIONS, so honouring one indefinitely would let a revoked identity prove the clean
 * status forever. Keeping the latest root permanently valid is what stops that from becoming
 * censorship by inaction.
 *
 * Worth checking BEFORE proving: a proof built against a root that has since expired is rejected
 * on-chain by IdentityRegistry.isValidRoot, after the prover has already paid for it.
 */
export async function isIdentityRootStillValid(
  registryAddress: string,
  runner: ContractRunner,
  root: bigint,
): Promise<boolean> {
  const registry = new Contract(registryAddress, IDENTITY_REGISTRY_ABI, runner);
  return registry.isValidRoot("0x" + root.toString(16).padStart(64, "0"));
}
