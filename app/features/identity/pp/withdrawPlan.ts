// Planning a withdrawal so the money that arrives can actually be MOVED.
//
// THE PROBLEM THIS SOLVES. `recipient.ts` derives a fresh payout address and the relayer pays the
// gas to deliver funds to it, which closes the withdrawal. It does NOT close the FIRST SPEND:
//   - A NATIVE payout lands as ETH, so the address can pay its own gas. Nothing to do.
//   - An ERC-20 payout lands as tokens at an address holding ZERO ETH. To move them it needs gas,
//     and sending gas from any address the user controls RE-LINKS the fresh address to them — the
//     exact linking transaction the relayer existed to avoid, moved one hop downstream.
// So for token pools the naive flow produces funds that are private and unspendable, which is worse
// than not withdrawing: the user cannot even undo it without linking.
//
// WHAT THIS DOES INSTEAD, AND WHY IT NEEDS NO CONTRACT CHANGE. If the user also holds a note in the
// NATIVE pool, both withdrawals are sent to the SAME derived address. The token arrives with enough
// ETH beside it to be spent, and neither withdrawal touches an address the user funded from outside.
//
// THE PRIVACY COST IS ZERO, which is the point. The two withdrawals are linked TO EACH OTHER — one
// address received both — but that link already exists the moment the user spends the tokens from
// that address, and neither is linked to the depositor, because both emerge from pools. What is NOT
// revealed is the thing that matters: which deposit either came from.
//
// WHEN THERE IS NO NATIVE NOTE, this REFUSES by default rather than stranding the funds. A wallet
// that silently withdraws tokens to an address that can never move them has handed the user a
// permanent loss dressed as a privacy win. ERC-4337 with a paymaster taking its fee in the withdrawn
// token is the real fix for that case — it removes the need for ETH at the address entirely — and it
// is the only case that still needs it.
//
// NOTE ON URGENCY: no ERC-20 pool is deployed today. `PrivacyPoolComplex` exists in the contracts
// and `Entrypoint` supports any asset, but nothing instantiates one (its salt is declared in
// DeployLib and never used, and there are no deployment scripts). This is therefore a guard placed
// BEFORE the failure can happen, not a repair after it.

import { buildRelayedWithdrawal, type Withdrawal } from "./relay.ts";
import { recipientForNote, type Recipient, type SpendableNote } from "./recipient.ts";

/** The `IERC20` sentinel `Constants.NATIVE_ASSET` uses for ETH. */
export const NATIVE_ASSET = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

export const isNativeAsset = (asset: string): boolean =>
  asset.toLowerCase() === NATIVE_ASSET.toLowerCase();

export interface WithdrawalLeg {
  /** What this leg is for: the funds the user asked for, or the gas to spend them. */
  purpose: "payout" | "gas-stipend";
  /** Pool scope this leg is drawn from. */
  scope: bigint;
  /** The note being spent. */
  note: SpendableNote;
  /** How much to withdraw from it. */
  withdrawnValue: bigint;
  /** Ready for `buildWithdrawalWitness` + the prover. */
  withdrawal: Withdrawal;
  /** The `context` this leg's proof must commit to. */
  context: bigint;
}

export interface WithdrawPlan {
  /** Where every leg pays. ONE address for the whole plan — that is what makes the funds spendable. */
  recipient: Recipient;
  /** In submission order: the stipend first, so gas is present before the tokens are. */
  legs: WithdrawalLeg[];
}

export interface PlanParams {
  mnemonic: string;
  entrypointAddress: string;
  fee: { feeRecipient: string; relayFeeBPS: bigint };

  /** The asset of the pool being withdrawn from. Use `NATIVE_ASSET` for ETH. */
  asset: string;
  payoutScope: bigint;
  payoutNote: SpendableNote;
  payoutValue: bigint;

  /**
   * A note in the NATIVE pool, used to deliver gas to the same address. Required for a token
   * withdrawal unless `allowUnspendablePayout` is set.
   */
  gasNote?: SpendableNote;
  gasScope?: bigint;
  /** How much ETH to send alongside. Enough for a handful of transfers, not a round trip. */
  gasStipend?: bigint;

  /**
   * Proceed with a token withdrawal that has no gas beside it.
   *
   * The funds arrive at an address that cannot move them without being linked to the user. Only set
   * this when the caller has another way to fund the address that does not defeat the point.
   */
  allowUnspendablePayout?: boolean;
}

/** A stipend big enough for several ERC-20 transfers at a normal gas price, and small enough that
 *  it is not itself worth withdrawing for. Callers holding a live gas oracle should override it. */
export const DEFAULT_GAS_STIPEND = 3_000_000_000_000_000n; // 0.003 ETH

/**
 * Build the set of withdrawals that leaves the user with SPENDABLE funds at one fresh address.
 *
 * @dev Every leg pays the recipient derived from the PAYOUT note, including the stipend. Deriving a
 *      separate address per leg would be the obvious symmetry and is exactly wrong: the gas would
 *      land somewhere the tokens are not, and neither address could move anything.
 */
export function planWithdrawal(params: PlanParams): WithdrawPlan {
  const {
    mnemonic,
    entrypointAddress,
    fee,
    asset,
    payoutScope,
    payoutNote,
    payoutValue,
    gasNote,
    gasScope,
    gasStipend = DEFAULT_GAS_STIPEND,
    allowUnspendablePayout = false,
  } = params;

  if (payoutValue <= 0n) throw new Error("planWithdrawal: payoutValue must be > 0");

  const recipient = recipientForNote(mnemonic, payoutNote);

  const legFor = (
    purpose: WithdrawalLeg["purpose"],
    scope: bigint,
    note: SpendableNote,
    withdrawnValue: bigint,
  ): WithdrawalLeg => {
    const { withdrawal, context } = buildRelayedWithdrawal(entrypointAddress, scope, {
      recipient: recipient.address,
      feeRecipient: fee.feeRecipient,
      relayFeeBPS: fee.relayFeeBPS,
    });
    return { purpose, scope, note, withdrawnValue, withdrawal, context };
  };

  const payout = legFor("payout", payoutScope, payoutNote, payoutValue);

  // A native payout arrives as gas. Adding a stipend would be a second withdrawal buying nothing.
  if (isNativeAsset(asset)) return { recipient, legs: [payout] };

  if (!gasNote) {
    if (!allowUnspendablePayout) {
      throw new Error(
        "planWithdrawal: this is a token withdrawal and no native note was supplied, so the funds " +
          "would arrive at an address holding no ETH and could not be moved without funding it " +
          "from an address you control — which links it to you, defeating the withdrawal. Supply " +
          "gasNote/gasScope from the native pool, or pass allowUnspendablePayout if you have " +
          "another way to fund it.",
      );
    }
    return { recipient, legs: [payout] };
  }

  if (gasScope === undefined) {
    throw new Error("planWithdrawal: gasNote was supplied without gasScope");
  }
  if (gasStipend <= 0n) throw new Error("planWithdrawal: gasStipend must be > 0");

  // Stipend first: gas has to be there before there is any reason to spend from the address.
  return {
    recipient,
    legs: [legFor("gas-stipend", gasScope, gasNote, gasStipend), payout],
  };
}
