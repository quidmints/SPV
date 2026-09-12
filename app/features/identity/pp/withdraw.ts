// A withdrawal, start to finish: quote the relayer, pick the note, build the witnesses, prove each
// leg, hand each proof to the relayer. The screen calls this once and gets an outcome; the relay is
// not a step it sees, because there is no version of a private withdrawal where the user submits
// the transaction themselves and stays private (see relay.ts).
//
// The prover is passed in for the reason withdrawFlow.ts gives: `prove.ts` only loads inside React
// Native, and everything here up to the proof is worth testing outside it.

import { prepareWithdrawal, type PrepareParams, type PreparedLeg } from "./withdrawFlow.ts";
import { DEFAULT_GAS_STIPEND } from "./withdrawPlan.ts";
import type { WithdrawWitness } from "./withdrawWitness.ts";
import type { Recipient } from "./recipient.ts";
import { relayerQuote, requestRelay, type RelayOutcome } from "./relay.ts";

export interface WithdrawParams extends Omit<PrepareParams, "fee"> {
  /** The hop's API base URL (`HOP_API.url`). */
  hopUrl: string;
  /** `proveWithdrawal` from ./prove. */
  prove: (witness: WithdrawWitness) => Promise<string>;
}

export type WithdrawOutcome =
  | { status: "done"; recipient: Recipient; legs: number }
  /** No relayer answered. The censorship escape hatch is `buildSelfWithdrawal`, and it is the
   *  screen's decision, because it costs the recipient's privacy. */
  | { status: "no_relayer" }
  /** A leg was refused after `relayed` earlier legs landed. A stipend that landed is not lost: the
   *  next attempt discovers its note spent and the payout address already funded. */
  | { status: "failed"; recipient: Recipient; relayed: number; leg: PreparedLeg["purpose"]; outcome: RelayOutcome };

/** One attempt: prepare at the given fee, then prove and relay leg by leg. */
async function attempt(
  p: WithdrawParams,
  feeRecipient: string,
  bpsFor: (withdrawnValue: bigint) => bigint,
): Promise<WithdrawOutcome> {
  const prepared = prepareWithdrawal({ ...p, fee: { feeRecipient, relayFeeBPS: bpsFor } });
  for (let i = 0; i < prepared.legs.length; i++) {
    const leg = prepared.legs[i]!;
    const proof = await p.prove(leg.witness);
    const outcome = await requestRelay(
      p.hopUrl,
      leg.withdrawal,
      { proof, pubSignals: leg.witness.pubSignals },
      leg.scope,
    );
    if (outcome.status !== "relayed") {
      return { status: "failed", recipient: prepared.recipient, relayed: i, leg: leg.purpose, outcome };
    }
  }
  return { status: "done", recipient: prepared.recipient, legs: prepared.legs.length };
}

export async function withdraw(p: WithdrawParams): Promise<WithdrawOutcome> {
  // One quote per leg value: the fee is a share of the leg, the cost is the same gas either way.
  const stipend = p.gasStipend ?? DEFAULT_GAS_STIPEND;
  const values = [p.payoutValue, ...(p.gasPool ? [stipend] : [])];
  const quoteAll = async (): Promise<{ feeRecipient: string; bps: Map<bigint, bigint> } | null> => {
    const bps = new Map<bigint, bigint>();
    let feeRecipient = "";
    for (const v of values) {
      const q = await relayerQuote(p.hopUrl, v);
      if (!q) return null;
      feeRecipient = q.feeRecipient;
      bps.set(v, q.minFeeBps);
    }
    return { feeRecipient, bps };
  };
  const bpsFor = (bps: Map<bigint, bigint>) => (v: bigint) => {
    const b = bps.get(v);
    if (b === undefined) throw new Error(`withdraw: no quote for a leg of ${v}`);
    return b;
  };

  const q1 = await quoteAll();
  if (!q1) return { status: "no_relayer" };
  const first = await attempt(p, q1.feeRecipient, bpsFor(q1.bps));

  // Gas moved past the quote's margin while the first leg was proving: re-quote and go again, once,
  // holding the refused leg at least at the fee the 402 named. Only when nothing has landed — after
  // a leg is spent, re-planning would plan it a second time.
  if (first.status === "failed" && first.relayed === 0 && first.outcome.status === "fee_too_low") {
    const bump = first.outcome.minFeeBps;
    const refused = first.leg === "payout" ? p.payoutValue : stipend;
    const q2 = await quoteAll();
    if (!q2) return first;
    const quoted = bpsFor(q2.bps);
    return attempt(p, q2.feeRecipient, (v) => (v === refused && quoted(v) < bump ? bump : quoted(v)));
  }
  return first;
}
