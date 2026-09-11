// Relayed withdrawals — the path that lets a user withdraw to a FRESH address holding no ETH.
//
// WHY THIS IS NOT OPTIONAL. `Entrypoint.relay()` has existed on-chain since the fork, but nothing
// client-side ever used it, so the only reachable withdrawal path was "be the processooor
// yourself". That path requires the recipient address to already hold ETH for gas — and funding a
// fresh address is exactly the linking transaction the pool exists to prevent. Without a relayer
// the privacy model does not close end-to-end: you either withdraw to an address you funded
// (linked), or you cannot withdraw at all. See sec. 2.20.
//
// WHAT STOPS A RELAYER STEALING. `PrivacyPool.validWithdrawal` requires
//   proof.context == keccak256(abi.encode(withdrawal, SCOPE)) % SNARK_SCALAR_FIELD
// and `withdrawal.data` is the ABI-encoded RelayData — so `recipient`, `feeRecipient` and
// `relayFeeBPS` are all committed inside the proof. A relayer that alters ANY of them produces a
// context mismatch and the withdrawal reverts. The relayer is therefore trusted for LIVENESS ONLY
// (it can refuse to submit), never for custody or for honouring the fee it agreed to.
//
// The escape hatch survives: a user who is being censored can still set `processooor` to their own
// address and submit directly, paying full gas themselves. That is `buildSelfWithdrawal` below.

// `BytesLike` is a TYPE-only export of ethers v6, so it must be imported as a type. Node's
// TypeScript stripping erases `import type` but leaves a plain named import in place, and the
// runtime then fails to resolve it — a value import here made this module unloadable by
// `node --test`, which is why nothing here had tests.
import { AbiCoder, keccak256 } from "ethers";
import type { BytesLike } from "ethers";

/** BN254 scalar field — `context` is reduced into it because it is a circuit public input. */
export const SNARK_SCALAR_FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Mirrors IEntrypoint.RelayData. */
export interface RelayData {
  /** Where the withdrawn funds land. A fresh address is the whole point. */
  recipient: string;
  /** Who receives the relayer fee. */
  feeRecipient: string;
  /** Relayer fee in basis points. Rejected on-chain if above assetConfig[asset].maxRelayFeeBPS. */
  relayFeeBPS: bigint;
}

/** Mirrors IPrivacyPool.Withdrawal. */
export interface Withdrawal {
  /** The ONLY address allowed to submit this withdrawal (PrivacyPool.sol:45). */
  processooor: string;
  /** ABI-encoded RelayData when relaying; empty when self-withdrawing. */
  data: BytesLike;
}

const RELAY_DATA_TUPLE = "(address recipient,address feeRecipient,uint256 relayFeeBPS)";
const WITHDRAWAL_TUPLE = "(address processooor,bytes data)";

/** ABI-encode RelayData for `Withdrawal.data`. */
export function encodeRelayData(data: RelayData): string {
  return AbiCoder.defaultAbiCoder().encode(
    [RELAY_DATA_TUPLE],
    [[data.recipient, data.feeRecipient, data.relayFeeBPS]],
  );
}

/**
 * Compute the `context` public input the circuit must carry.
 *
 * MUST match PrivacyPool.validWithdrawal exactly:
 *   keccak256(abi.encode(_withdrawal, SCOPE)) % SNARK_SCALAR_FIELD
 * Any divergence here produces proofs that revert with ContextMismatch, so this is deliberately a
 * direct transcription rather than a convenience wrapper.
 */
export function withdrawalContext(withdrawal: Withdrawal, scope: bigint): bigint {
  const encoded = AbiCoder.defaultAbiCoder().encode(
    [WITHDRAWAL_TUPLE, "uint256"],
    [[withdrawal.processooor, withdrawal.data], scope],
  );
  return BigInt(keccak256(encoded)) % SNARK_SCALAR_FIELD;
}

/**
 * Build a RELAYED withdrawal plus the `context` its proof must commit to.
 *
 * `processooor` is the Entrypoint itself — `Entrypoint.relay` rejects anything else
 * (`InvalidProcessooor`), because it is the Entrypoint that calls `PrivacyPool.withdraw` and then
 * splits the proceeds between recipient and fee recipient.
 *
 * Generate the withdrawal proof with the returned `context` as public input [6], then hand the
 * withdrawal + proof to the relayer (`requestRelay`). It needs no trust beyond submitting it.
 */
export function buildRelayedWithdrawal(
  entrypointAddress: string,
  scope: bigint,
  relay: RelayData,
): { withdrawal: Withdrawal; context: bigint } {
  if (relay.relayFeeBPS < 0n || relay.relayFeeBPS > 10_000n) {
    throw new Error("buildRelayedWithdrawal: relayFeeBPS must be within 0..10000");
  }
  const withdrawal: Withdrawal = {
    processooor: entrypointAddress,
    data: encodeRelayData(relay),
  };
  return { withdrawal, context: withdrawalContext(withdrawal, scope) };
}

/**
 * Build a SELF-submitted withdrawal — the censorship escape hatch.
 *
 * Requires `self` to already hold ETH for gas, which is linkable; use this only when no relayer
 * will serve you. Goes to `PrivacyPool.withdraw` directly, not through `Entrypoint.relay`, so no
 * RelayData is attached and no fee is deducted.
 */
export function buildSelfWithdrawal(
  self: string,
  scope: bigint,
): { withdrawal: Withdrawal; context: bigint } {
  const withdrawal: Withdrawal = { processooor: self, data: "0x" };
  return { withdrawal, context: withdrawalContext(withdrawal, scope) };
}

/** The proof shape `Entrypoint.relay` expects (ProofLib.WithdrawProof). */
export interface WithdrawProof {
  proof: BytesLike;
  pubSignals: readonly bigint[];
}

/**
 * The relayer is the fleet hop's enclave (`quid-bridge/src/pp_relay.rs`), reached at the same base
 * URL as the swap-in API. Routes and field names below are TRANSCRIBED from that file — there is no
 * shared schema, see `chain/hop.ts` for why casing must not be tidied.
 */
const RELAY_ROUTE = "/pp/relay";

/**
 * The address a proof must name as `RelayData.feeRecipient`. Asked of the relayer rather than read
 * as `MAIN_HOP` from chain, because the relayer is whichever hop serves the API: a proof naming any
 * other address is refused (it would pay gas for someone else's fee). `null` when the relayer is
 * not deployed, so the caller falls back to `buildSelfWithdrawal`.
 */
export async function relayerFeeRecipient(hopUrl: string): Promise<string | null> {
  try {
    const r = await fetch(`${hopUrl}${RELAY_ROUTE}`);
    if (!r.ok) return null;
    const body = (await r.json()) as { fee_recipient?: string };
    return body.fee_recipient ?? null;
  } catch {
    return null;
  }
}

/** What `requestRelay` answers — the status is what the UI branches on. */
export type RelayOutcome =
  | { status: "relayed" }
  /** 402 — the fee does not cover the gas; `detail` carries the numbers. Raise `relayFeeBPS` and re-prove. */
  | { status: "fee_too_low"; detail: string }
  /** 400 — refused before any tx (binding, shape, or a simulated revert named in `detail`). */
  | { status: "refused"; detail: string }
  /** 409 — mined but reverted: the state moved under the proof. Re-prove against current state. */
  | { status: "stale"; detail: string }
  /** 503 / network — no relayer; the escape hatch is `buildSelfWithdrawal`. */
  | { status: "unavailable"; detail: string };

/**
 * Hand a relayed withdrawal to the relayer. Fails fast on a context mismatch rather than round-
 * tripping a request the relayer will refuse for the same reason.
 */
export async function requestRelay(
  hopUrl: string,
  withdrawal: Withdrawal,
  proof: WithdrawProof,
  scope: bigint,
): Promise<RelayOutcome> {
  const expected = withdrawalContext(withdrawal, scope);
  // ProofLib.context is pubSignals[6]; [7] is the blacklist root.
  if (proof.pubSignals[6] !== expected) {
    throw new Error(
      `requestRelay: context mismatch — proof carries ${proof.pubSignals[6]}, ` +
        `withdrawal implies ${expected}. The proof was built for different RelayData; ` +
        "submitting it would revert with ContextMismatch.",
    );
  }
  const body = JSON.stringify({
    withdrawal: { processooor: withdrawal.processooor, data: withdrawal.data },
    proof: { proof: proof.proof, pubSignals: proof.pubSignals.map((s) => s.toString(10)) },
    scope: scope.toString(10),
  });
  let r: Response;
  try {
    r = await fetch(`${hopUrl}${RELAY_ROUTE}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
  } catch (e) {
    return { status: "unavailable", detail: String(e) };
  }
  if (r.ok) return { status: "relayed" };
  const detail = await r.text();
  switch (r.status) {
    case 402:
      return { status: "fee_too_low", detail };
    case 400:
      return { status: "refused", detail };
    case 409:
      return { status: "stale", detail };
    default:
      return { status: "unavailable", detail: `${r.status}: ${detail}` };
  }
}
