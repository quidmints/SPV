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

// `ContractRunner` and `BytesLike` are TYPE-only exports of ethers v6, so both must be imported as
// types. Node's TypeScript stripping erases `import type` but leaves a plain named import in place,
// and the runtime then fails to resolve it — so with `ContractRunner` imported as a value this
// module could not be loaded by `node --test` at all, which is why nothing here had tests.
import { AbiCoder, Contract, keccak256 } from "ethers";
import type { BytesLike, ContractRunner } from "ethers";

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

// @contract Entrypoint
const ENTRYPOINT_ABI = [
  "function relay((address processooor,bytes data) _withdrawal, (bytes proof,uint256[8] pubSignals) _proof, uint256 _scope) external",
  "event WithdrawalRelayed(address indexed _relayer, address indexed _recipient, address indexed _asset, uint256 _amount, uint256 _feeAmount)",
] as const;

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
 * Generate the withdrawal proof with the returned `context` as public input [7], then hand the
 * withdrawal + proof to any relayer. The relayer needs no trust beyond submitting it.
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
 * Submit a relayed withdrawal. Called by the RELAYER (it pays gas), not by the withdrawing user.
 *
 * Fails fast on a context mismatch rather than burning gas on a revert: a relayer that has been
 * handed a proof built for different RelayData would otherwise pay for a guaranteed failure.
 */
export async function submitRelayedWithdrawal(
  entrypointAddress: string,
  runner: ContractRunner,
  withdrawal: Withdrawal,
  proof: WithdrawProof,
  scope: bigint,
): Promise<string> {
  const expected = withdrawalContext(withdrawal, scope);
  if (proof.pubSignals[7] !== expected) {
    throw new Error(
      `submitRelayedWithdrawal: context mismatch — proof carries ${proof.pubSignals[7]}, ` +
        `withdrawal implies ${expected}. The proof was built for different RelayData; ` +
        "submitting it would revert with ContextMismatch.",
    );
  }

  const entrypoint = new Contract(entrypointAddress, ENTRYPOINT_ABI, runner);
  const tx = await entrypoint.relay(
    [withdrawal.processooor, withdrawal.data],
    [proof.proof, proof.pubSignals],
    scope,
  );
  const receipt = await tx.wait();
  return receipt?.hash ?? tx.hash;
}
