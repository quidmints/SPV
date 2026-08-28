// BIP-341 hashing for the swap-in deposit address — the part of the QR verifier that decides
// whether the hop is bound to the terms it showed you.
//
// 🔑 **THE ADDRESS IS THE OUTPUT, NEVER AN INPUT.** A verifier that recomputes a hop-supplied
// address from hop-supplied values proves only that the hop is self-consistent, which was never
// in doubt. Everything here is fed from what the WALLET owns (`userRefund`, `seller`) or what the
// USER WAS SHOWN AND ACCEPTED (`token`, `minDeliveredUsd`, `cltvHeight`) — and the quoted address
// is compared against the result, never mixed into it.
//
// ⚠️ **THIS FILE IS THE HASH LAYER ONLY, AND THAT IS DELIBERATE.** Turning a leaf hash into a
// `bc1p…` address additionally needs (a) the BIP-341 TapTweak, which is an EC point add over
// secp256k1, and (b) bech32m. Neither is here, because neither should be hand-rolled —
// `@scure/btc-signer` (same maintainer as the `@noble/*` packages already in this wallet) is the
// intended source and is not yet a dependency. **Landing the hashing separately is what lets it
// be pinned against the Solidity and Rust suites today** rather than waiting on that decision.
//
// 🔑 **A LEAF HASH, NOT A MERKLE ROOT — the tree is ONE leaf.** The terms are committed by a
// dropped push inside the refund leaf (`depositLeafScript`), so there is no branch to compute and
// no `tapBranch` here. An earlier version had one; it survived the redesign as dead code for a
// day, which standing rule 1 forbids — if a second leaf is ever wanted, BIP-341's TapBranch is
// five lines and should be added deliberately rather than found lying around.
//
// ✅ `refundLeafScript` IS now here, TRANSCRIBED from `ExitLib._cltvRefundLeaf` rather than
// re-derived — including `_scriptNum`, whose minimal little-endian encoding with a sign pad is
// exactly where a re-derivation goes wrong. Its own comment is the warning: *"a wrong encoding
// changes the leaf hash and therefore the ADDRESS, silently deriving somewhere no deposit will
// ever land."*
// ⚠️ **STILL OWED: a fixture shared with the Solidity and Rust builders.** The tests below pin
// the opcode sequence and every `scriptNum` edge case from Bitcoin's rule, which is where
// transcription errors live — but three implementations agreeing is only demonstrated for
// `tapBranch` so far. Do the same for a full leaf before trusting an address end to end.

import { secp256k1 } from '@noble/curves/secp256k1.js'
import { ethers } from 'ethers'

import { SECP256K1_N } from './keys.ts'

const Point = secp256k1.Point

const bytes = (hex: string) => ethers.getBytes(hex.startsWith('0x') ? hex : `0x${hex}`)

/// BIP-340 tagged hash: `sha256(sha256(tag) ‖ sha256(tag) ‖ msg)`.
///
/// The doubled tag hash is not decoration — it is what domain-separates a leaf from a branch, so
/// a leaf cannot be presented as an internal node and a merkle proof cannot admit a script that
/// was never committed.
export function taggedHash(tag: string, msg: Uint8Array): string {
  const t = ethers.sha256(ethers.toUtf8Bytes(tag))
  return ethers.sha256(ethers.concat([t, t, msg]))
}

/// BIP-341 TapLeaf hash for one script leaf, at the only leaf version taproot defines (`0xc0`).
///
/// ⚠️ Scripts of 253 bytes or more are refused rather than given a wrong compact-size prefix: a
/// mis-encoded length hashes to a plausible leaf that is not the one on chain, which is precisely
/// the silent failure this verifier exists to catch. Mirrors `MuSig2Agg.tapLeafHash`'s guard.
export function tapLeafHash(scriptHex: string): string {
  const script = bytes(scriptHex)
  if (script.length >= 0xfd) throw new Error('tapLeafHash: leaf script too long')
  return taggedHash(
    'TapLeaf',
    ethers.getBytes(ethers.concat([new Uint8Array([0xc0, script.length]), script])),
  )
}

/// The 32-byte commitment to a swap's TERMS — who is credited, in what token, at WHAT RATE.
/// §T2, implemented in `SPV/evm/src/imports/ExitLib.sol::termsCommitment`.
///
/// ⛔ **THIS COMMITTED `minDeliveredUsd` UNTIL 2026-08-21 AND COULD NOT HAVE WORKED.** The floor is
/// `swap_in_floor_usd(sats, pricePerBtc, slippageBps)` — it SCALES WITH THE SATS ACTUALLY
/// DEPOSITED, which nobody knows when this address is derived, because **the address must exist
/// before the seller can pay it**. Committing it made the address underivable and every settle
/// would have reverted. SPV hit the same wall and changed sides: what is fixed at registration is
/// the RATE, so that is what the address commits, and the contract DERIVES the floor from it and
/// the SPV-proven sats (`ExitLib.settleFloorUsd`). **Strictly stronger** — the hop no longer
/// SUPPLIES a floor at all, so there is nothing left for it to substitute between quote and settle.
///
/// ⚠️ `abi.encode`, never `encodePacked`: packed encoding is ambiguous and two different quotes
/// could collide onto one commitment. Must match the Solidity side exactly — four 32-byte words,
/// with `slippageBps` widened to `uint256` as Solidity's `abi.encode(uint16)` does.
export function termsCommitment(
  seller: string,
  token: string,
  pricePerBtc: bigint,
  slippageBps: number,
): string {
  return ethers.sha256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'uint256', 'uint256'],
      [seller, token, pricePerBtc, BigInt(slippageBps)],
    ),
  )
}

/// Bitcoin script number: little-endian, minimal width, with a `0x00` pad when the high bit of the
/// top byte is set (otherwise it reads as negative).
///
/// ⚠️ **TRANSCRIBED BYTE FOR BYTE FROM `ExitLib._scriptNum`, NOT RE-DERIVED.** Its own comment:
/// *"a wrong encoding changes the leaf hash and therefore the ADDRESS, silently deriving somewhere
/// no deposit will ever land."* Note `v == 0` yields a single `0x00` byte rather than the empty
/// push Bitcoin would canonically use — **match the counterpart, do not 'fix' it**, because the
/// only property that matters is agreeing with the code that computes the address on chain.
export function scriptNum(v: number): string {
  if (!Number.isInteger(v) || v < 0 || v > 0xffffffff) {
    throw new Error('scriptNum: expected a uint32')
  }
  if (v === 0) return '0x00'
  let n = 0
  for (let t = v; t !== 0; t >>>= 8) n++
  const pad = ((v >>> (8 * (n - 1))) & 0x80) !== 0
  const out = new Uint8Array(pad ? n + 1 : n) // the pad byte stays 0x00
  for (let i = 0; i < n; i++) out[i] = (v >>> (8 * i)) & 0xff
  return ethers.hexlify(out)
}

/// The spendable CLTV refund leaf: `<cltvHeight> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG`.
///
/// ⚠️ Transcribed from `ExitLib._cltvRefundLeaf`, which is itself byte-identical to the Rust
/// builder. Three implementations must agree on these bytes or the wallet computes an address the
/// contract does not.
export function refundLeafScript(userRefund: string, cltvHeight: number): string {
  const n = ethers.getBytes(scriptNum(cltvHeight))
  const key = bytes(userRefund)
  if (key.length !== 32) throw new Error('refundLeafScript: userRefund must be 32 bytes x-only')
  return ethers.hexlify(
    ethers.concat([
      new Uint8Array([n.length]), n, // PUSH<len> <height, little-endian, minimal>
      '0xb1',                        // OP_CHECKLOCKTIMEVERIFY
      '0x75',                        // OP_DROP
      '0x20', key,                   // PUSH32 <x-only refund key>
      '0xac',                        // OP_CHECKSIG
    ]),
  )
}

/// The deposit leaf: the CLTV refund path with the swap's terms committed in front of it.
///
/// `<termsCommitment> OP_DROP <cltvHeight> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG`
///
/// 🔑 **ONE LEAF, NOT TWO — THIS REPLACES THE `tapBranch` DESIGN, and the challenge that produced
/// it was right.** My first version put the terms in a SECOND, unspendable `OP_RETURN` leaf and
/// combined the two with a merkle branch. That works and is more machinery than the job needs: a
/// second leaf means a `tapBranch` on every derivation, a 32-byte sibling in the control block of
/// every refund spend, and a new primitive maintained in three languages. Pushing the commitment
/// into the leaf that ALREADY EXISTS costs 34 bytes of witness on the refund path only — the rare
/// path — and needs no new primitive at all.
/// ⇒ `taprootOutputKeyWithLeaf(internalX, tapLeafHash(depositLeafScript(...)))` is exactly what
/// SPV already has. Nothing in the tweak, the control block or the key path moves.
///
/// The push is executed and immediately dropped, so spendability is untouched: the refund path is
/// still "after `cltvHeight`, the holder of `userRefund` may reclaim".
export function depositLeafScript(
  userRefund: string,
  cltvHeight: number,
  seller: string,
  token: string,
  pricePerBtc: bigint,
  slippageBps: number,
): string {
  const n = ethers.getBytes(scriptNum(cltvHeight))
  const key = bytes(userRefund)
  if (key.length !== 32) throw new Error('depositLeafScript: userRefund must be 32 bytes x-only')
  return ethers.hexlify(
    ethers.concat([
      '0x20', termsCommitment(seller, token, pricePerBtc, slippageBps), // PUSH32 <terms>
      '0x75',                        // OP_DROP — committed, not consumed
      new Uint8Array([n.length]), n, // PUSH<len> <height, little-endian, minimal>
      '0xb1',                        // OP_CHECKLOCKTIMEVERIFY
      '0x75',                        // OP_DROP
      '0x20', key,                   // PUSH32 <x-only refund key>
      '0xac',                        // OP_CHECKSIG
    ]),
  )
}

/// BIP-341 output key: `Q = lift_x_even(internalX) + H_TapTweak(internalX ‖ leafHash)·G`.
///
/// 🔑 **THIS IS THE LAST CRYPTOGRAPHIC STEP OF THE QR VERIFIER** — everything after it is
/// presentation (bech32m over `OP_1 <32-byte Q>`). It is the value the contract computes in
/// `MuSig2Agg.taprootOutputKeyWithLeaf` and the value the hop's `deposit_for` derives, so a wallet
/// that computes it independently can tell whether a quoted address is the one the terms imply.
///
/// ⚠️ `lift_x` takes the EVEN-y point, per BIP-341 — the same convention `keys.ts` normalises to,
/// and the reason the `02` prefix below is not a choice.
/// ⚠️ No new dependency: `@noble/curves` was already here for `schnorr`. `@scure/btc-signer` is
/// still wanted for bech32m, but the security-relevant number is this one, not its encoding.
export function taprootOutputKey(internalX: string, leafHash: string): string {
  const t = BigInt(taggedHash('TapTweak', ethers.getBytes(ethers.concat([internalX, leafHash]))))
    % SECP256K1_N
  if (t === 0n) throw new Error('taprootOutputKey: degenerate tweak') // negligible, never silent
  const P = Point.fromHex(`02${internalX.replace(/^0x/, '')}`)
  const Q = P.add(Point.BASE.multiply(t))
  return `0x${Q.toHex(true).slice(2)}` // drop the parity byte: taproot commits x only
}
