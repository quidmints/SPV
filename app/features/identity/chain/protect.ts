// ════════════════════════════════════════════════════════════════════════
//   FRONTRUNNING PROTECTION — route every state-changing tx through a private,
//   MEV-protected relay so it skips the PUBLIC mempool (where searchers can
//   sandwich / frontrun it) and goes straight to block builders.
//
//   🔴 PORTED, NOT DISSOLVED (2026-08-16, corrected). My first pass at this file DELETED
//   `enableProtection` and renamed `PROTECT`, on the argument that the SPA's caveat — a browser
//   wallet signs AND broadcasts, so a dApp cannot force the path — stops applying once the app
//   holds the key. The premise is true and the conclusion was wrong twice over:
//
//     1. `page.tsx` IMPORTS BOTH. `:292` does `setProtect(await enableProtection())` to drive the
//        UI badge and `:1002` reads `PROTECT.name` for its tooltip. Dropping them does not
//        simplify the port, it breaks ~20 call sites' module the moment the view layer lands.
//     2. "The app picks the endpoint" is NOT the same as "the endpoint is private". Pointing at a
//        general-purpose RPC and signing locally gets you a PUBLIC mempool broadcast with extra
//        steps. What buys privacy is the endpoint being a protected one — so the question
//        `enableProtection` answers is still real, it just has a better answer available.
//
//   ⇒ The API is unchanged. What changed is that `enableProtection` now MEASURES instead of
//   ASKING. In the browser it fired `wallet_addEthereumChain` and returned whether the user
//   accepted a prompt — a proxy for the thing we care about. Here it probes the configured
//   endpoint and reports whether it will actually take a private send.
//
//   🔑 **THE RELAY IS FLASHBOTS PROTECT / SUAVE, AND NOTHING ELSE** (owner, 2026-08-16: "we
//   must use the existing mev protect suave"). An earlier pass added an `alchemy-private` mode
//   calling `eth_sendPrivateTransaction`; it is DELETED. Two reasons, and the second is the
//   durable one:
//     * its parameter shape was never verified — Alchemy's reference 404s at both documented
//       URLs — so it was speculative code on the write path, which is the worst place for it;
//     * **Alchemy's standard endpoint is a general RPC: privacy there is a property of the
//       METHOD.** Flashbots Protect is the opposite — privacy is a property of the URL, so a
//       plain `eth_sendRawTransaction` is already private and there is no vendor call to get
//       wrong. One endpoint, one send path, nothing to probe for but reachability.
//   ⇒ Do not reintroduce a per-vendor send method. If the relay ever changes, change the URL.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'

/// The active relay, exported under its original name because `page.tsx` reads `PROTECT.name`.
/// Mutated by `configureProtection` rather than replaced, so an imported reference stays live.
export const PROTECT: { url: string; name: string } = {
  url: 'https://rpc.flashbots.net',
  name: 'Ethereum (Flashbots Protect)',
}

/// A wallet that signs AND broadcasts on its own — Phantom's `eth_sendTransaction` shape. We
/// hand it a request and get a hash; where it goes is its decision.
/// Structural rather than importing `@phantom/react-native-wallet-sdk`, so this module does not
/// depend on the SDK and a second external wallet needs no change here.
export interface ExternalWallet {
  request(args: { method: string; params?: unknown[] }): Promise<any>
}

type Backend =
  | { kind: 'local'; signer: ethers.Signer }
  | { kind: 'external'; wallet: ExternalWallet }

let provider: ethers.JsonRpcProvider | null = null
let backend: Backend | null = null
let enabled = false
let probed = false

/// Point protection at a different protected endpoint — another Flashbots Protect URL (its
/// hint/builder query parameters are set here), a SUAVE endpoint, or MEV Blocker. ⚠️ It must be
/// an endpoint whose URL IS the protection; a general-purpose RPC here silently makes every send
/// public, and nothing downstream can tell the difference.
///
/// Must be called BEFORE `setSigner`: the signer is bound to the endpoint at install time, so
/// reconfiguring afterwards would leave it broadcasting to the previous one. That throws rather
/// than rebinding silently, because a signer still pointed at the old URL is exactly the failure
/// this file exists to prevent and it would not show up anywhere.
export function configureProtection(opts: Partial<typeof PROTECT>): void {
  if (backend?.kind === 'local') {
    throw new Error(
      'protect: configureProtection after setSigner would leave the signer bound to the OLD ' +
      'endpoint — configure first, then install the signer',
    )
  }
  Object.assign(PROTECT, opts)
  provider = null
  enabled = false
  probed = false
}

function relayProvider(): ethers.JsonRpcProvider {
  if (!provider) provider = new ethers.JsonRpcProvider(PROTECT.url)
  return provider
}

/// Install the app's signer. Its provider is REPLACED with the relay's.
///
/// ⚠️ By construction, not by a check: whatever provider the caller's signer carried is
/// discarded, so a signer wired to a public RPC cannot be installed here. There is no code path
/// that keeps it — the bad state is unconstructible rather than detectable.
export function setSigner(s: ethers.Signer | null): void {
  backend = s ? { kind: 'local', signer: s.connect(relayProvider()) } : null
  probed = false
  enabled = false
}

/// Install an EXTERNAL wallet (Phantom) as the signer instead.
///
/// ⚠️ **THIS IS A DELIBERATE DOWNGRADE AND THE UI MUST SAY SO.** Phantom signs and broadcasts in
/// one call, so we cannot route its transaction through the relay — `protectionEnabled()` goes
/// false for the session and stays false. Offering it anyway is the right call (a user with
/// funds already in Phantom should not be forced to move them to use the app), but it must be a
/// visible trade rather than a silent one.
/// 📌 If Phantom ever exposes an endpoint-selection call the way browser wallets did with
/// `wallet_addEthereumChain`, this is where a best-effort upgrade would go — and it would still
/// be best-effort, so `protectionEnabled` would need a third state rather than flipping true.
export function setExternalWallet(w: ExternalWallet | null): void {
  backend = w ? { kind: 'external', wallet: w } : null
  probed = false
  enabled = false
}

/// Which custody the session is using, for the UI to label honestly.
export function signerKind(): 'local' | 'external' | null {
  return backend?.kind ?? null
}

/// Whether the last probe found a working private path. Same meaning to the UI as the SPA's
/// version — "is this session protected" — with a measurement behind it instead of a prompt.
export function protectionEnabled(): boolean {
  return enabled
}

/// Establish whether the configured endpoint will take a private send. Idempotent; re-probes
/// only when `force`.
///
/// 🔑 REACHABILITY IS THE WHOLE PROBE, and that is a consequence of using Protect/SUAVE rather
/// than a vendor method: the endpoint's URL IS the protection, so a node that answers IS the
/// protected path. There is no capability to interrogate and nothing to get wrong.
/// ⚠️ What it CANNOT tell you is whether `PROTECT.url` is genuinely a protected endpoint — point
/// it at a public RPC and this returns true. That check is `configureProtection`'s caller's job.
export async function enableProtection(force = false): Promise<boolean> {
  if (probed && !force) return enabled
  probed = true
  // An external wallet owns its own broadcast, so there is nothing here to enable and no probe
  // that could make the claim true. Report the truth rather than the relay's reachability.
  if (backend?.kind === 'external') { enabled = false; return false }
  try {
    await relayProvider().send('eth_chainId', [])
    enabled = true
  } catch { enabled = false }
  return enabled
}

export interface Tx { from?: string; to: string; data?: string; value?: string; gas?: string }

/// THE single chokepoint for every state-changing tx. All writes route through here so the
/// protection cannot be bypassed by an un-wrapped call site.
///
/// Takes the SAME hex-string `Tx` the SPA used, so the ~20 ported call sites need no edit; the
/// conversion to ethers' bigint fields happens here rather than at each of them.
///
/// 🔴 **WHICH GUARANTEE YOU GET DEPENDS ENTIRELY ON WHICH BACKEND IS INSTALLED, and conflating
/// the two is the mistake this comment exists to stop.** I previously wrote here that "a write
/// either takes the protected path or does not happen". That is TRUE of `Local` and FALSE of
/// `External`, and shipping it unqualified would have put a false guarantee next to the code
/// that breaks it.
///
/// * **`Local`** (in-app key) — we sign and we choose the endpoint, so the signer is bound to
///   the relay and nothing else. An unreachable relay THROWS. Privacy is structural, and no
///   caller has to remember to check a flag. **Do not add a "fallback" branch to this path** —
///   that reintroduces exactly the silent downgrade the shape removes.
/// * **`External`** (Phantom) — the wallet signs AND broadcasts (`eth_sendTransaction`), so the
///   endpoint is ITS choice, not ours. This is the SPA's original constraint returning verbatim:
///   *"the dApp can't force the broadcast path per-call"*. It was never a browser problem; it is
///   a **custody** problem, and it follows the key wherever the key lives.
///
/// ⇒ `protectionEnabled()` reports FALSE for `External` for that reason — not because something
/// failed, but because we cannot honestly claim what we do not control.
export async function sendTx(tx: Tx): Promise<string> {
  if (!backend) throw new Error('protect: no signer installed (setSigner or setExternalWallet)')
  await enableProtection()

  if (backend.kind === 'external') {
    // Passed through as the SAME hex-string shape the wallet expects — no bigint conversion,
    // because this object is Phantom's `eth_sendTransaction` param, not ethers'.
    return backend.wallet.request({ method: 'eth_sendTransaction', params: [tx] })
  }

  const sent = await backend.signer.sendTransaction({
    to: tx.to,
    data: tx.data,
    value: tx.value ? BigInt(tx.value) : undefined,
    gasLimit: tx.gas ? BigInt(tx.gas) : undefined,
  })
  return sent.hash
}
