// BIP-340 Schnorr signing with the app's OWN key — so the refund path needs no hardware wallet.
//
// 🔑 **WHY THIS EXISTS: NOT DEPENDING ON LEDGER TO DO IT FOR US.** The swap-in deposit's refund
// leaf is `<cltv> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG` — a BIP-340 signature is the only
// thing that spends it. A cold-storage device can produce one, but requiring one would mean a
// user cannot reclaim their own deposit without plugging in hardware, and it makes the ordinary
// path depend on the exceptional one. `@noble/curves` is already a dependency and ships audited
// BIP-340, so the in-app key can sign its own refund. Ledger stays an OPTION for custody, never a
// prerequisite for recovery.
//
// ⚠️ **`@noble/curves` HAS SCHNORR BUT NOT MuSig2** (its README: MuSig2 lives in
// `@scure/btc-signer`). So this covers the refund path — one key, one signature — and NOT the
// LP's pre-signed exit ladder, which needs an interactive two-round MuSig2 nonce protocol. Do not
// read this file as evidence the ladder is unblocked.

import { schnorr } from '@noble/curves/secp256k1.js'
import { ethers } from 'ethers'

import { normaliseKey } from './keys.ts'

const b = (hex: string) => ethers.getBytes(hex.startsWith('0x') ? hex : `0x${hex}`)

/// The x-only public key an audited BIP-340 implementation derives for this private key.
///
/// 🔑 **THIS IS THE INDEPENDENT CHECK ON `normaliseKey`.** `keys.ts` derives the x-only key by
/// normalising to even-y itself; noble does BIP-340's own thing internally. If the two ever
/// disagree, the wallet commits to a refund key it cannot sign for — and the deposit becomes
/// unreclaimable with every other part correct. The test pins them equal across many keys.
export function xOnlyPublicKey(privateKey: string): string {
  return ethers.hexlify(schnorr.getPublicKey(b(privateKey)))
}

/// Sign a 32-byte sighash for the refund leaf's `OP_CHECKSIG`.
///
/// ⚠️ `auxRand` defaults to BIP-340's optional randomness being ABSENT (32 zero bytes), which
/// makes signatures deterministic. That is the right default here: a taproot script-path spend is
/// reconstructed by a wallet that may retry, and two different signatures over one sighash are
/// harmless on Bitcoin but make a test suite unreproducible. Pass real randomness where the extra
/// side-channel hardening matters more than reproducibility.
export function signRefund(
  privateKey: string,
  sighash: string,
  auxRand: Uint8Array = new Uint8Array(32),
): string {
  const m = b(sighash)
  if (m.length !== 32) throw new Error('signRefund: sighash must be 32 bytes')
  return ethers.hexlify(schnorr.sign(m, b(privateKey), auxRand))
}

/// Verify a BIP-340 signature against an x-only key — the same check `OP_CHECKSIG` performs.
export function verifyRefund(sig: string, sighash: string, xOnly: string): boolean {
  return schnorr.verify(b(sig), b(sighash), b(xOnly))
}

/// Sign with the key the wallet actually installs, i.e. after `normaliseKey`.
///
/// Returns the signature AND the x-only key it verifies under, so a caller building a witness
/// cannot pair a signature with the wrong key — the two come from one call or not at all.
export function signRefundWithNormalisedKey(
  rawPrivateKey: string,
  sighash: string,
): { signature: string; xOnly: string } {
  const k = normaliseKey(rawPrivateKey)
  return { signature: signRefund(k.privateKey, sighash), xOnly: k.xOnly }
}
