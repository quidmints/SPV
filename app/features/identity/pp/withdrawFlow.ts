// Assembling a withdrawal: pick a note, plan the legs, build the witnesses.
//
// WHAT THIS IS FOR. Every piece underneath is tested and pinned — derivation, discovery, the state
// tree, the witness, the context, the plan — but nothing joined them, so no screen could drive a
// withdrawal. This is the join, and it is deliberately SYNCHRONOUS AND PURE: everything network- or
// device-bound (the rebuilt state tree, the identity witness, the prover) is passed IN, already
// fetched. That is not indirection for its own sake — `prove.ts` cannot even be loaded outside React
// Native, so a flow that called it directly could never be tested at all, and the one part worth
// testing is exactly this: which note gets spent, and what each leg is handed.
//
// NOTE SELECTION IS A PRIVACY DECISION, not bookkeeping. The circuit spends ONE note per withdrawal
// and returns the remainder as a change note, so:
//   - An EXACT match is strictly best: it produces a change note worth zero, and there is no
//     remainder to track, re-derive or eventually reveal.
//   - Otherwise the SMALLEST note that covers the amount leaves the smallest remainder. Spending a
//     large note for a small withdrawal leaves a large change note whose value is a distinctive
//     number, and every later spend of it carries that shape.
//   - Notes cannot be combined. If no single note covers the amount, that is a refusal, not a
//     multi-note spend — the circuit has no such path, and pretending otherwise would produce a
//     witness that cannot be proven.

import type { RecoveredNote } from "./discovery.ts";
import {
  buildWithdrawalWitness,
  nextWithdrawalIndex,
  type BlacklistWitness,
  type WithdrawWitness,
} from "./withdrawWitness.ts";
import type { IdentityWitness } from "./identityProof.ts";
import type { MasterKeys } from "./notes.ts";
import type { StateTree } from "./stateTree.ts";
import { planWithdrawal, type PlanParams, type WithdrawPlan, type WithdrawalLeg } from "./withdrawPlan.ts";
import type { Recipient } from "./recipient.ts";

/** A leg with everything the prover needs. */
export interface PreparedLeg extends WithdrawalLeg {
  /** The note actually chosen to fund this leg. */
  selected: RecoveredNote;
  witness: WithdrawWitness;
}

export interface PreparedWithdrawal {
  recipient: Recipient;
  legs: PreparedLeg[];
}

/** Everything about one pool the flow needs, already fetched. */
export interface PoolContext {
  scope: bigint;
  /** Rebuilt AND root-verified — see loadStateTree. */
  stateTree: StateTree;
  /** Leaf index per commitment, tracked by discovery; resolving by commitment is unsafe when the
   *  same commitment appears twice (StateTree.leafIndexOf). */
  leafIndexOf: (note: RecoveredNote) => bigint;
  notes: RecoveredNote[];
  identity: IdentityWitness;
  /**
   * The blacklist root and the two exclusion witnesses proven against it.
   *
   * Carried on the pool alongside `identity` because it is the same kind of thing: state fetched
   * from chain that every leg of one withdrawal must agree on. A batch settles against ONE root, so
   * legs built from different snapshots could never be folded together.
   */
  blacklist: BlacklistWitness;
  /** The document this identity was escrowed against - see WithdrawWitnessParams.documentId. */
  documentId: bigint;
}

/**
 * The note to spend for `value`, or null if none can cover it.
 *
 * @dev Exact match first, then the smallest note that covers. Ties are broken by the note's own
 *      ordering in `notes`, which discovery already fixed to chain order, so the choice is
 *      deterministic — two wallets restored from one seed pick the same note.
 */
export function selectNoteFor(notes: readonly RecoveredNote[], value: bigint): RecoveredNote | null {
  if (value <= 0n) throw new Error("selectNoteFor: value must be > 0");
  const spendable = notes.filter((n) => !n.spent && n.value >= value);
  if (spendable.length === 0) return null;

  // The smallest covering note IS the exact match whenever one exists — an exact match is by
  // definition the minimum of the notes that cover. A separate exact-match branch was written here
  // first and removed: it could never change the result, and unreachable special cases are where
  // future divergence hides. `<` rather than `<=` keeps the FIRST note at the minimum, and discovery
  // already fixed `notes` to chain order, so the choice is stable across restores.
  return spendable.reduce((best, n) => (n.value < best.value ? n : best));
}

/** Sum of what could actually be withdrawn in ONE withdrawal — the largest single note, NOT the
 *  balance. Quoting the balance to the user is how "insufficient funds" appears on a wallet that
 *  visibly holds enough. */
export function largestSpendable(notes: readonly RecoveredNote[]): bigint {
  return notes.reduce((max, n) => (!n.spent && n.value > max ? n.value : max), 0n);
}

export interface PrepareParams
  extends Omit<PlanParams, "payoutNote" | "payoutScope" | "gasNote" | "gasScope"> {
  masterKeys: MasterKeys;
  /** The pool the user is withdrawing FROM. */
  payoutPool: PoolContext;
  /** The native pool, for the gas stipend. Omit for a native withdrawal. */
  gasPool?: PoolContext;
  revocationSecret: bigint;
}

/**
 * Select notes, plan the legs and build every witness.
 *
 * @throws when no single note covers the requested value, naming the largest that could — the
 *         alternative is a witness the prover rejects minutes later with nothing explaining why.
 */
export function prepareWithdrawal(params: PrepareParams): PreparedWithdrawal {
  const { masterKeys, payoutPool, gasPool, revocationSecret, payoutValue, gasStipend } = params;

  const payoutNote = selectNoteFor(payoutPool.notes, payoutValue);
  if (!payoutNote) {
    const largest = largestSpendable(payoutPool.notes);
    throw new Error(
      `prepareWithdrawal: no single note covers ${payoutValue}. The largest spendable note is ` +
        `${largest}. Notes cannot be combined in one withdrawal — withdraw at most ${largest}, or ` +
        `make several withdrawals.`,
    );
  }

  // Resolve the gas note BEFORE planning, so a missing one fails here rather than as a confusing
  // "no native note was supplied" from the planner when the real cause is an empty native pool.
  let gasNote: RecoveredNote | undefined;
  if (gasPool) {
    const stipend = gasStipend ?? undefined;
    const found = selectNoteFor(gasPool.notes, stipend ?? 1n);
    if (!found) {
      throw new Error(
        `prepareWithdrawal: the native pool holds no note covering the gas stipend, so the payout ` +
          `would arrive unspendable. Deposit ETH, or pass allowUnspendablePayout deliberately.`,
      );
    }
    gasNote = found;
  }

  const plan: WithdrawPlan = planWithdrawal({
    ...params,
    payoutNote,
    payoutScope: payoutPool.scope,
    ...(gasNote && gasPool ? { gasNote, gasScope: gasPool.scope } : {}),
  });

  const poolFor = (leg: WithdrawalLeg): PoolContext =>
    leg.purpose === "payout" ? payoutPool : gasPool!;
  const noteFor = (leg: WithdrawalLeg): RecoveredNote =>
    leg.purpose === "payout" ? payoutNote : gasNote!;

  const legs = plan.legs.map((leg): PreparedLeg => {
    const pool = poolFor(leg);
    const selected = noteFor(leg);
    return {
      ...leg,
      selected,
      witness: buildWithdrawalWitness({
        note: selected,
        stateLeafIndex: pool.leafIndexOf(selected),
        stateTree: pool.stateTree,
        masterKeys,
        withdrawnValue: leg.withdrawnValue,
        context: leg.context,
        identity: pool.identity,
        blacklist: pool.blacklist,
        documentId: pool.documentId,
        revocationSecret,
        // Must match what discovery will later count, or the change note is unrecoverable.
        withdrawalIndex: nextWithdrawalIndex(pool.notes, selected.label),
      }),
    };
  });

  return { recipient: plan.recipient, legs };
}
