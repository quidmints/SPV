// Withdrawal witness assembler — the second half of sec. 2.1, and the step that makes withdrawing
// possible at all. Turns a discovered note + the two tree mirrors into the exact 20-input witness
// `backend/circuits/withdraw_identity/src/main.nr` expects, plus the 8 public signals
// PrivacyPool.sol reads out of ProofLib.WithdrawProof.pubSignals.
//
// SCOPE, deliberately: this builds and self-checks the witness. It does NOT call the prover.
// Proving is `NoirCircuitParams.fromName('withdraw_identity').proveHonk(...)` from
// @rarimo/rarime-rn-sdk, with the circuit registered by src/sdk/circuits.ts. That path is
// ANDROID-ONLY: the SDK's Android native module implements proveHonk (RnNoirModule.kt,
// proofType = "honk") but iOS hardcodes proof_type: "plonk". See sec. 2.1a.
//
// Keeping assembly separate from proving is not a workaround, it is the right seam anyway: the
// witness is backend-agnostic, so it is testable TODAY against a Forge fixture with no device, no
// prover and no toolchain dependency, and it stays valid if the proving backend moves.
//
// PUBLIC SIGNAL ORDER IS PINNED by ProofLib and must not be reordered:
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] identity_root
//   [2] withdrawn_value         [6] context
//   [3] state_root              [7] context

import {
  commitment as commitmentHash,
  nullifierHash,
  withdrawalSecrets,
} from "./notes.ts";
import type { MasterKeys, NoteSecrets } from "./notes.ts";
import type { RecoveredNote } from "./discovery.ts";
import { StateTree, MAX_TREE_DEPTH, FIELD } from "./stateTree.ts";
import { IDENTITY_TREE_DEPTH } from "./identityProof.ts";
import type { IdentityWitness } from "./identityProof.ts";
import { babyJub, Poseidon } from "@iden3/js-crypto";

/** The circuit range-checks `value`, `withdrawn_value` and `value - withdrawn_value` to 128 bits
 *  (main.nr step 2, via to_le_bits). Exceeding this yields a witness that cannot be proven, so it
 *  is rejected here with a real explanation instead. */
const MAX_VALUE = 1n << 128n;

/**
 * One SMT non-membership witness: the path proving a key is ABSENT from the blacklist.
 *
 * `oldKey`/`oldValue` describe the leaf that occupies the position the queried key would take -
 * proving absence by showing what IS there instead. `isOld0` says that position is empty, which is
 * the whole witness when the subtree is unoccupied.
 */
export interface ExclusionWitness {
  siblings: bigint[];
  oldKey: bigint;
  oldValue: bigint;
  isOld0: boolean;
}

/**
 * The blacklist root and the two exclusions proven against it.
 *
 * ONE ROOT, TWO KEYS, and that is the design rather than an economy. Provenance taint and a
 * sanctions listing are not two systems with two roots and two activation windows: they are
 * domain-separated keys in a single tree, so a new country's register joins by being inserted
 * rather than by being coded for.
 */
export interface BlacklistWitness {
  root: bigint;
  /** Exclusion of the deposit's label - `blacklist_key(DOMAIN_LABEL, label)`. */
  label: ExclusionWitness;
  /** Exclusion of the escrowed document - `blacklist_key(DOMAIN_DOCUMENT, documentId)`. */
  document: ExclusionWitness;
}

export interface WithdrawWitnessParams {
  /** The unspent note being spent. Must come from discoverNotes(), not be hand-built. */
  note: RecoveredNote;
  /** Its leaf index in the state tree. Authoritative — see StateTree.leafIndexOf on why resolving
   *  by commitment is unsafe when the same commitment appears twice. */
  stateLeafIndex: bigint;
  /** Rebuilt + root-verified via loadStateTree(). */
  stateTree: StateTree;

  /** Seed-derived master keys — the change note MUST be derived from these to stay recoverable. */
  masterKeys: MasterKeys;
  /** The withdrawer's identity scalar, from the enclave-rooted seed. */
  /** How much to withdraw. The remainder carries into the change note. */
  withdrawnValue: bigint;
  /**
   * Permit `withdrawnValue === 0`, which is otherwise refused.
   *
   * FOR TREE PADDING ONLY. A recursion tree settles power-of-two batches, so a batch of five is
   * proved as a tree of eight and the spare leaves need GENUINE proofs - a tree cannot hold an empty
   * slot. A zero-value spend is the cheapest valid one: the circuit permits it (`withdrawn_value` is
   * only range-checked) and the change note comes out equal to the spent one.
   *
   * IT IS AN OPT-IN RATHER THAN A RELAXED CHECK because for a real user a zero withdrawal is
   * strictly harmful - it pays out nothing while burning the note's nullifier - so the guard stays
   * on for every path that is not deliberately building padding.
   */
  allowZeroForPadding?: boolean;
  /** From buildRelayedWithdrawal()/buildSelfWithdrawal() in ./relay. */
  context: bigint;
  /**
   * Inclusion witness for the identity registry, from fetchIdentityWitness() in ./identityProof.
   * REQUIRED - unlike the old revocation witness there is no meaningful empty-tree default, because
   * an unregistered identity has nothing to include and simply cannot withdraw.
   */
  identity: IdentityWitness;

  /** The escrowed revocation secret. Hashed WITH the document id to give the registry key. */
  revocationSecret: bigint;
  /**
   * `document_identifier(issuing_state, document_number)` for the document this identity was
   * escrowed against.
   *
   * ⚠️ NOT A FREE CHOICE, even though it is a private witness. It is hashed into the identity leaf,
   * so naming a different document produces a leaf that is not in `identityRoot` and the proof fails
   * at the inclusion step. Supplying the WRONG one is therefore an unprovable witness, not a
   * successful lie - but it fails with an identity error rather than a document one, which is worth
   * knowing when debugging.
   */
  documentId: bigint;
  /**
   * The blacklist root and the two exclusion witnesses proven against it - one for the deposit's
   * LABEL, one for the escrowed DOCUMENT. One tree, two domain-separated keys.
   *
   * REQUIRED. There is deliberately no empty-tree default here: the pool refuses a zero root, so a
   * witness built against one could never settle, and defaulting would turn that into a proving-time
   * surprise instead of a compile-time one.
   */
  blacklist: BlacklistWitness;
  /**
   * Which withdrawal this is FOR THIS LABEL, in the wallet's derivation convention.
   *
   * LOAD-BEARING, and the single most dangerous input here. discovery.ts re-derives change notes as
   * `withdrawalSecrets(keys, label, k)` where k counts withdrawals on that label in on-chain order.
   * Passing a k that does not match what discovery will later count produces a change note whose
   * secrets the wallet can never re-derive — the remainder becomes unspendable. Use
   * nextWithdrawalIndex() rather than supplying this by hand.
   */
  withdrawalIndex: bigint;
}

export interface WithdrawWitness {
  /** Noir input map, keyed by main()'s parameter names. Decimal strings — Noir accepts decimal or
   *  0x-hex for Field; decimal avoids any ambiguity about leading-zero padding. */
  /** Noir prover inputs. Booleans stay booleans - see fixture-common: toml must not quote them. */
  inputs: Record<string, string | string[] | boolean>;
  /** ProofLib.WithdrawProof.pubSignals, in pinned order. */
  pubSignals: bigint[];
  /** The change note's secrets — persist/re-derive these; they own the remainder. */
  changeNote: NoteSecrets;
  /** The change note's commitment (public signal [0]). */
  newCommitment: bigint;
}

/**
 * The next withdrawal index for `label` under the wallet's convention, counted from notes that
 * discoverNotes() already returned. This is the SAME quantity discovery re-derives, computed the
 * same way, which is the point — hand-supplying it is how the remainder gets lost.
 */
export function nextWithdrawalIndex(notes: readonly RecoveredNote[], label: bigint): bigint {
  let k = 0n;
  for (const n of notes) if (n.kind === "withdrawal-change" && n.label === label) k += 1n;
  return k;
}

/**
 * holderRoot for a given identity scalar: Poseidon(babyJub.mulPointEScalar(Base8, sk)).
 *
 * Exported because the ASP tree is keyed by this value, so anything BUILDING a tree (the wallet,
 * the postman tooling, tools/build-withdrawal-fixture.js) needs the identical derivation. Having
 * one exported function rather than three re-implementations is what keeps them from drifting -
 * and it is the same value pp/src/holder_root.nr::extract_pk_identity_hash computes in-circuit.
 */
export function holderRootFromSk(skIdentity: bigint): bigint {
  return Poseidon.hash(babyJub.mulPointEScalar(babyJub.Base8, skIdentity));
}

/** Assemble (and self-check) the withdraw_identity witness. */
export function buildWithdrawalWitness(params: WithdrawWitnessParams): WithdrawWitness {
  const {
    note,
    stateLeafIndex,
    stateTree,
    masterKeys,
    identity,
    revocationSecret,
    documentId,
    blacklist,
    withdrawnValue,
    context,
    withdrawalIndex,
    allowZeroForPadding = false,
  } = params;

  if (identity.siblings.length !== IDENTITY_TREE_DEPTH) {
    throw new Error(
      `buildWithdrawalWitness: identity witness has ${identity.siblings.length} siblings, ` +
        `but the circuit is fixed at ${IDENTITY_TREE_DEPTH}. Pad or regenerate both together.`,
    );
  }


  // ── Value conservation, checked before anything expensive ──────────────────────────────────
  if (note.spent) throw new Error("buildWithdrawalWitness: note is already spent");
  if (withdrawnValue < 0n || (withdrawnValue === 0n && !allowZeroForPadding)) {
    throw new Error("buildWithdrawalWitness: withdrawnValue must be > 0 (see allowZeroForPadding)");
  }
  if (withdrawnValue > note.value) {
    throw new Error(
      `buildWithdrawalWitness: withdrawing ${withdrawnValue} from a note worth ${note.value}`,
    );
  }
  if (note.value >= MAX_VALUE) {
    throw new Error("buildWithdrawalWitness: note value exceeds the circuit's 128-bit range check");
  }
  if (context <= 0n || context >= FIELD) {
    throw new Error("buildWithdrawalWitness: context must be a nonzero BN254 field element");
  }

  // ── Identity: derive the registry key from the escrowed secret AND its document ─────────────
  // The key is Poseidon(revocation_secret, document_id) - the SAME value escrow_envelope committed
  // to and IdentityRegistry stored. sk_identity is NOT used here at all any more: identity is proven
  // ONCE, at escrow. See sec. 2.13k.
  //
  // ⚠️ THE SECOND FIELD IS WHAT MAKES THE SANCTIONS TERM MEAN ANYTHING. Committing to the secret
  // alone let a withdrawal prove "some registered identity" and then name any document at all for
  // the blacklist check. Binding it here is what forces the document checked to be the one escrowed.
  const commitment = Poseidon.hash([revocationSecret, documentId]);

  // ── State-tree membership ───────────────────────────────────────────────────────────────────
  const stateProof = stateTree.proof(stateLeafIndex, MAX_TREE_DEPTH);
  const leafAtIndex = stateTree.leaves[Number(stateLeafIndex)];
  if (leafAtIndex !== note.commitment) {
    throw new Error(
      `buildWithdrawalWitness: state leaf ${stateLeafIndex} holds ${leafAtIndex}, ` +
        `but the note's commitment is ${note.commitment}. Wrong index, or a stale tree.`,
    );
  }


  // ── Change note ─────────────────────────────────────────────────────────────────────────────
  const newValue = note.value - withdrawnValue;
  const changeNote = withdrawalSecrets(masterKeys, note.label, withdrawalIndex);
  const newCommitment = commitmentHash(newValue, note.label, changeNote);

  // Reconstruct the SPENT note's commitment exactly as the circuit does (main.nr step 1) rather
  // than trusting discovery's stored value — the circuit asserts this, so a mismatch is a witness
  // that cannot be proven, and it is far cheaper to find it here.
  const existingNote: NoteSecrets = { nullifier: note.nullifier, secret: note.secret };
  const recomputed = commitmentHash(note.value, note.label, existingNote);
  if (recomputed !== note.commitment) {
    throw new Error(
      `buildWithdrawalWitness: recomputed commitment ${recomputed} != recorded ${note.commitment}. ` +
        "The note's value/label/secrets disagree with the on-chain commitment.",
    );
  }

  const existingNullifierHash = nullifierHash(note.nullifier);

  const pubSignals = [
    newCommitment,
    existingNullifierHash,
    withdrawnValue,
    stateProof.root,
    BigInt(stateProof.depth),
    identity.identityRoot,
    context,
    blacklist.root,
  ];

  const dec = (v: bigint) => v.toString(10);

  const inputs: Record<string, string | string[] | boolean> = {
    // public
    new_commitment: dec(newCommitment),
    existing_nullifier_hash: dec(existingNullifierHash),
    withdrawn_value: dec(withdrawnValue),
    state_root: dec(stateProof.root),
    state_tree_depth: dec(BigInt(stateProof.depth)),
    identity_root: dec(identity.identityRoot),
    context: dec(context),
    // private — existing note
    value: dec(note.value),
    label: dec(note.label),
    nullifier: dec(note.nullifier),
    secret: dec(note.secret),
    state_leaf_index: dec(stateProof.leafIndex),
    state_siblings: stateProof.siblings.map(dec),
    // private — change note
    out_nullifier: dec(changeNote.nullifier),
    out_secret: dec(changeNote.secret),
    // private - identity clearance. ONE witness where there were two: the escrowed secret and an
    // inclusion path proving its commitment sits in the registry carrying the CLEAN status.
    revocation_secret: dec(revocationSecret),
    identity_siblings: identity.siblings.map(dec),
    // public - the one blacklist root both exclusion terms are proven against
    blacklist_root: dec(blacklist.root),
    // private - exclusion of the deposit's LABEL
    blacklist_siblings: blacklist.label.siblings.map(dec),
    blacklist_old_key: dec(blacklist.label.oldKey),
    blacklist_old_value: dec(blacklist.label.oldValue),
    blacklist_is_old0: blacklist.label.isOld0,
    // private - exclusion of the escrowed DOCUMENT, same root, different domain
    document_id: dec(documentId),
    document_siblings: blacklist.document.siblings.map(dec),
    document_old_key: dec(blacklist.document.oldKey),
    document_old_value: dec(blacklist.document.oldValue),
    document_is_old0: blacklist.document.isOld0,
  };

  return { inputs, pubSignals, changeNote, newCommitment };
}

/** Poseidon re-export so callers can verify a commitment without reaching into ./notes. */
export { Poseidon };
