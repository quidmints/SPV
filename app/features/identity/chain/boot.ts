// Wiring the chain layer into the running app — the one place a transport or a signer is installed.
//
// Until this file existed the chain layer was INERT: `eth.ts` had no transport, `protect.ts` had no
// signer, and every read returned null while every write threw. Everything below is glue, and the
// glue is where two rules stop being documentation and become unbypassable.
//
// 🔑 **RULE ONE — ORDER.** `configureProtection` must precede `setSigner`, because the signer is
// bound to the relay at install time; reconfiguring afterwards would leave it broadcasting to the
// previous endpoint. `protect.ts` throws on that ordering, and `bootChain` simply does it in the
// right order so no caller has to know.
//
// 🔑 **RULE TWO — BIP-340 PARITY.** A local key is installed ONLY through `normaliseKey`, so the
// EVM address the app shows and the x-only key its taproot refund leaf commits to are two views of
// ONE normalised point. That rule fails for exactly half of keys if skipped, silently, months
// later — so the only path that installs a key applies it, rather than a comment asking callers to.
//
// ⚠️ **CUSTODY IS A CHOICE WITH A VISIBLE COST, NOT A FALLBACK.** `useLocalKey` gives structural
// MEV protection (we sign, we pick the endpoint). `useExternalWallet` cannot — Phantom and Ledger
// sign AND broadcast, so `protectionEnabled()` stays false for that session. Both are supported;
// the UI must render `signerKind()` rather than a static badge.

import { ethers } from 'ethers'

import { setRpcTransport } from './eth.ts'
import { setContracts, type Contracts } from './chains.ts'
import { configureProtection, setSigner, setExternalWallet, type ExternalWallet } from './protect.ts'
import { normaliseKey, type NormalisedKey } from './keys.ts'

export interface ChainConfig {
  /// Read transport. Any RPC — it serves `eth_call` / `eth_getLogs` and never broadcasts.
  rpcUrl: string
  /// Write endpoint. ⚠️ MUST be one whose URL *is* the protection (Flashbots Protect / SUAVE /
  /// MEV Blocker). A general-purpose RPC here silently makes every send public and nothing
  /// downstream can tell. Omit to keep `protect.ts`'s default.
  relayUrl?: string
  relayName?: string
  /// Deployed contract addresses. Absent until SPV's deploy record is wired back in — every
  /// unset entry stays the zero address, which the read path renders as "not deployed" rather
  /// than dialling something wrong.
  contracts?: Partial<Contracts>
}

/// Install the read transport and point protection at its relay. Idempotent, and safe to call
/// before any signer exists — which is the normal case, since the app renders read-only until the
/// user chooses a custody path.
export function bootChain(cfg: ChainConfig): void {
  setRpcTransport(new ethers.JsonRpcProvider(cfg.rpcUrl))
  if (cfg.contracts) setContracts(cfg.contracts)
  // BEFORE any signer — see rule one.
  if (cfg.relayUrl || cfg.relayName) {
    configureProtection({
      ...(cfg.relayUrl ? { url: cfg.relayUrl } : {}),
      ...(cfg.relayName ? { name: cfg.relayName } : {}),
    })
  }
}

/// Install the app's own key as the signer, normalised.
///
/// Returns the normalised identity so the caller can display the address and hand the x-only key
/// to a swap-in request — **the two are guaranteed to be the same point**, which is the whole
/// reason this returns a value instead of nothing.
export function useLocalKey(privateKey: string): NormalisedKey {
  const k = normaliseKey(privateKey)
  setSigner(new ethers.Wallet(k.privateKey))
  return k
}

/// Install an external wallet (Phantom, or a Ledger transport exposing the same shape).
///
/// ⚠️ Returns nothing on purpose: there is no x-only refund key to hand back, because the wallet
/// will not surrender the private key needed to derive one. A swap-in from an external-wallet
/// session therefore needs a SEPARATE Bitcoin refund key, which is exactly why §T2 commits
/// `seller` into the deposit leaf rather than deriving it. See `SPV/docs/actionable/HOP-TRUST-AUDIT.md`.
export function useExternalWallet(wallet: ExternalWallet): void {
  setExternalWallet(wallet)
}

/// Tear the session down — used on sign-out and when switching custody.
export function clearSigner(): void {
  setSigner(null)
  setExternalWallet(null)
}
