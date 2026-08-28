// Fresh withdrawal recipients — the address the pool pays out to, derived from the SAME root seed.
//
// WHY THIS FILE EXISTS. Until now the wallet created no recipient address at all: `relay.ts` took
// `recipient: string` from its caller and nothing produced one. That left the user to answer
// "where should the money go?", and every ordinary answer is wrong — their existing wallet is the
// address the pool exists to unlink them from, and an exchange deposit address is KYC'd. The
// relayer (sec. 2.20) made it POSSIBLE to withdraw to an address holding no ETH; this makes it
// possible to HAVE one.
//
// DETERMINISM IS THE WHOLE DESIGN, not an optimisation. A fresh address per withdrawal would
// normally mean a new key to back up, and a wallet that hands the user a private key to store has
// made privacy a chore that most people will skip. Deriving it from the root mnemonic instead means
// the address is reconstructible from the words the user already wrote down — "fresh" never means
// "another thing to lose".
//
// WHICH INDEX, AND WHY NOT A COUNTER. A stored "next recipient index" is state, and state is the
// thing that does not survive a reinstall: restore from seed with the counter gone and you re-derive
// index 0, which you already used — paying two withdrawals to one address, which is precisely the
// linkage this file prevents, appearing at exactly the moment the user is most likely to be
// recovering under stress. So the index is derived from the WITHDRAWAL ITSELF (its nullifier hash,
// already unique per spend and already recoverable from chain data). Recovery needs no saved
// counter: `discovery.ts` re-finds the notes, and each spent note re-derives the address that
// received its payout.
//
// WHY THE PATH IS DEEP, WHICH IS THE POINT OF THIS FILE'S SHAPE. A single hardened level holds 31
// bits, so squeezing a field element into one account index makes two of a user's own withdrawals
// collide with probability around 1e-4 over a thousand spends — rare, silent, and the failure IS the
// linkage. The obvious repair (probe to the next free index) does not survive contact: it needs to
// know which accounts earlier withdrawals took, which makes an assignment depend on the SET of notes
// rather than on the note, and inserting a newly-spent note that sorts earlier can then shift an
// ALREADY-PAID note onto a different address — recovery pointing somewhere the money never went.
// BIP32 limits each LEVEL to 31 bits, not the path, so three levels carry 93 bits and the collision
// disappears instead of being managed: ~5e-17 over a million withdrawals. No probe, no ordering, no
// stored set — each withdrawal derives independently, which is what makes recovery unconditional.
//
// DOMAIN SEPARATION (checked against the reservations in notes.ts). PP's master keys are BIP44
// accounts 0 and 1; `sk_identity` is account 100. Recipients live under account 1000 and are the
// only three-level-deeper paths in the wallet, so the spaces cannot overlap. Every segment is
// HARDENED (the ' on each), so a recipient key — which unlike the others is used to SIGN, and
// therefore exposes its public key the moment it spends — cannot be walked back to a sibling or a
// parent. Compromising a recipient does not reach the identity or the notes.

import { HDNodeWallet } from "ethers";
import { nullifierHash } from "./notes.ts";
import { buildRelayedWithdrawal, type Withdrawal } from "./relay.ts";

/** BIP44 account reserved for recipients. Below it: 0 and 1 (PP master keys, notes.ts), 100
 *  (`sk_identity`, root.ts). The gap is deliberate headroom for future reservations. */
export const RECIPIENT_ACCOUNT = 1000;

/** BIP32 hardened indices are 31-bit. */
export const LEVEL_SPAN = 2n ** 31n;

/** Hardened levels below the account that carry the withdrawal's identity. Three gives 93 bits. */
export const RECIPIENT_LEVELS = 3;

export interface Recipient {
  /** Full derivation path — recorded so a recovering wallet can show its work. */
  path: string;
  /** The payout address. This is what goes into `RelayData.recipient`. */
  address: string;
}

/**
 * The derivation path carrying `id` across `RECIPIENT_LEVELS` hardened levels.
 *
 * @dev Least-significant level first. The direction is arbitrary but must never change: it is part
 *      of the derivation, so flipping it silently re-points every historical recipient.
 */
export function recipientPath(id: bigint): string {
  if (id < 0n) throw new Error("recipientPath: id must be non-negative");
  let rest = id;
  const levels: bigint[] = [];
  for (let i = 0; i < RECIPIENT_LEVELS; i++) {
    levels.push(rest % LEVEL_SPAN);
    rest /= LEVEL_SPAN;
  }
  return `m/44'/60'/${RECIPIENT_ACCOUNT}'/` + levels.map((l) => `${l}'`).join("/");
}

/** Derive the recipient for an explicit id. Prefer `recipientForNote` — this is the primitive. */
export function deriveRecipient(mnemonic: string, id: bigint): Recipient {
  const path = recipientPath(id);
  return { path, address: HDNodeWallet.fromPhrase(mnemonic, "", path).address };
}

/**
 * The signer for a recipient — needed only to SPEND what was withdrawn, never to receive it.
 *
 * Kept separate from `deriveRecipient` so the ordinary withdrawal flow, which needs nothing but an
 * address, never has a private key in hand to leak or log.
 */
export function recipientSigner(mnemonic: string, id: bigint): HDNodeWallet {
  return HDNodeWallet.fromPhrase(mnemonic, "", recipientPath(id));
}

/** The subset of `RecoveredNote` (discovery.ts) this module needs — kept structural so a caller
 *  holding a list of notes does not have to drag in discovery's provider-bound types. */
export interface SpendableNote {
  nullifier: bigint;
}

/**
 * The payout address for a note being spent.
 *
 * This is the call the withdrawal flow makes, and the call a RECOVERING wallet makes for each note
 * `discovery.ts` reports as spent. It depends on nothing but the seed and the note, which is why
 * both produce the same answer without coordinating.
 */
export function recipientForNote(mnemonic: string, note: SpendableNote): Recipient {
  return deriveRecipient(mnemonic, nullifierHash(note.nullifier));
}

/**
 * The whole withdrawal-addressing step in one call: derive a fresh payout address for the note
 * being spent and build the relayed withdrawal that pays it.
 *
 * THIS IS THE ENTRY POINT THE UI SHOULD USE, and the reason is that the alternative is asking the
 * user for an address. Every answer they can give is linkable — their funding wallet is the thing
 * the pool exists to unlink them from, and an exchange address is KYC'd — so the only safe design
 * is one where the question is never asked. One call, no prompt, nothing to back up.
 *
 * @returns The withdrawal and the `context` its proof must commit to (see `relay.ts`), plus the
 *          recipient, so a caller can show the user where the money is going.
 */
export function buildFreshRelayedWithdrawal(
  mnemonic: string,
  note: SpendableNote,
  entrypointAddress: string,
  scope: bigint,
  fee: { feeRecipient: string; relayFeeBPS: bigint },
): { withdrawal: Withdrawal; context: bigint; recipient: Recipient } {
  const recipient = recipientForNote(mnemonic, note);
  const built = buildRelayedWithdrawal(entrypointAddress, scope, {
    recipient: recipient.address,
    feeRecipient: fee.feeRecipient,
    relayFeeBPS: fee.relayFeeBPS,
  });
  return { ...built, recipient };
}
