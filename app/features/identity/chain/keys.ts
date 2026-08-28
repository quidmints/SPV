// ONE secp256k1 KEY, TWO IDENTITIES — the BIP-340 y-parity rule, in one place.
//
// This exists so SPV can DELETE `seller` from `settleSwapInProven` (§T2). The swap-in deposit
// address is a taproot output committing to the payer's x-only refund key, and the contract
// already recomputes and verifies it — so if the seller's EVM address is DERIVABLE from that same
// key, the hop never has to assert who is being credited, and a parameter comes off a money-path
// signature instead of an EIP-712 domain going on.
//
// 🔴 **THE TRAP THIS FILE EXISTS TO CLOSE, AND IT FAILS FOR EXACTLY HALF OF USERS.**
// An x-only key is the x-coordinate ONLY. BIP-340 resolves the ambiguity by defining the key as
// the point with **even y**. An EVM address is `keccak(x ‖ y)[12:]` over the FULL point. So for
// any private key whose public point has ODD y, the even-y point is the NEGATION — a different
// `y`, a different keccak, and therefore **a different address**.
//
// ⇒ Half of all randomly generated keys hit this. Get it wrong and the contract credits an
// address the user does not control, **with the deposit, the proof and the contract all
// correct** — there is no on-chain check that can catch it, because the derived address is
// perfectly well-formed either way. It presents as "my money went somewhere else", months later,
// for half of everyone.
//
// ⇒ **THE RULE: normalise FIRST, then derive both identities from the normalised key.** The EVM
// address is the address of the even-y point, and EVM transactions are signed with `d' = n − d`
// whenever the raw key is odd-y. That is the same normalisation BIP-340 already requires to sign
// the refund leaf, so the wallet does it once and both sides agree by construction.
//
// ⚠️ The Rust side derives the EVM key separately (`RootSeed::derive_eth_wallet_key`). **Both
// must apply this rule or one seed yields two different addresses on the two sides** — which is
// the same failure wearing a different hat. See `docs/actionable/HOP-TRUST-AUDIT.md`.

import { ethers } from 'ethers'

/// The order of the secp256k1 group (SEC 2, §2.4.1). A published curve parameter, not a tuning
/// constant — it is written out rather than imported so the negation below is auditable in place.
export const SECP256K1_N =
  0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n

/// One private key, presented as the two identities it maps to.
export interface NormalisedKey {
  /// The BIP-340-normalised private key: `d` if the public point has even y, else `n − d`.
  /// **Sign EVM transactions with THIS**, or the sender will not match `evmAddress`.
  privateKey: string
  /// 32-byte x-only public key for the taproot refund leaf, `0x`-prefixed.
  xOnly: string
  /// The EVM address of the NORMALISED point — the one the contract can derive from `xOnly`.
  evmAddress: string
  /// Whether normalisation actually negated. Exposed for tests and diagnostics; a wallet that
  /// stores the raw key and signs with it will be wrong for exactly the keys where this is true.
  negated: boolean
}

/// Apply the parity rule to a 32-byte private key.
///
/// Throws on an out-of-range key rather than clamping: a key outside `[1, n)` is a generation bug,
/// and silently mapping it into range would produce an address the caller cannot reproduce.
export function normaliseKey(privateKey: string): NormalisedKey {
  const d0 = BigInt(privateKey.startsWith('0x') ? privateKey : `0x${privateKey}`)
  if (d0 <= 0n || d0 >= SECP256K1_N) {
    throw new Error('normaliseKey: private key out of range [1, n)')
  }

  const hex = (v: bigint) => `0x${v.toString(16).padStart(64, '0')}`

  // Uncompressed public point: 0x04 ‖ x(32) ‖ y(32). The y parity is the last byte's low bit.
  const uncompressed = ethers.SigningKey.computePublicKey(hex(d0), false)
  const yIsOdd = (BigInt(`0x${uncompressed.slice(-2)}`) & 1n) === 1n

  const d = yIsOdd ? SECP256K1_N - d0 : d0
  const pub = yIsOdd ? ethers.SigningKey.computePublicKey(hex(d), false) : uncompressed

  return {
    privateKey: hex(d),
    // Strip the `04` prefix and take x; y is implied even, which is what makes this a valid
    // BIP-340 key rather than merely half a point.
    xOnly: `0x${pub.slice(4, 68)}`,
    evmAddress: ethers.computeAddress(pub),
    negated: yIsOdd,
  }
}

/// The inverse the CONTRACT performs: recover the EVM address from an x-only key alone.
///
/// This is the check that makes §T2's deletion sound — if this does not agree with
/// `normaliseKey(...).evmAddress` for every key, the contract would credit the wrong address.
/// Kept here, next to the rule it verifies, so the two cannot drift apart unnoticed.
export function evmAddressFromXOnly(xOnly: string): string {
  const x = xOnly.startsWith('0x') ? xOnly.slice(2) : xOnly
  if (x.length !== 64) throw new Error('evmAddressFromXOnly: expected a 32-byte x-only key')
  // `02` is the compressed prefix for EVEN y — the BIP-340 convention, and the whole point.
  return ethers.computeAddress(`0x02${x}`)
}
