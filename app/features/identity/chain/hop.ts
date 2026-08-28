
// Hop API client — the off-chain endpoint that mediates BTC↔USD swaps the EVM
// can't initiate alone. Two swap-IN rails, both invoice-/wallet-optional for the user:
//   • on-chain  (POST /swap-in-onchain)  → a Bitcoin ADDRESS to send to + exact sats.
//                The hop watches the deposit, SPV-proves it, calls settleSwapInOnchain.
//   • lightning (POST /swap-in)           → a BOLT11 invoice to pay (LN-capable users).
//
// The hop URL + bearer token are deployment config (see chains.ts HOP_API). Until
// they're set the client returns null and the UI shows "swap-in coming online".

import { HOP_API } from './chains.ts'

export interface OnchainSwapInQuote {
  depositAddress: string   // send BTC here
  exactSats: number        // send EXACTLY this (the low-order nonce is how the hop matches it)
  minDeliveredUsd: string  // output-token smallest units, net of the amortized fee
  swapId: string           // 0x… correlation id
  expiresAt: number        // unix seconds — quote/address validity
}

export type SwapInStatus = 'awaiting_deposit' | 'confirming' | 'settled' | 'expired' | 'failed'

const headers = () => ({
  'content-type': 'application/json',
  ...(HOP_API.token ? { authorization: `Bearer ${HOP_API.token}` } : {}),
})

function ready(): boolean { return !!HOP_API.url }

/** Request an on-chain swap-in: returns a Bitcoin address + exact amount to send. */
export async function requestOnchainSwapIn(seller: string, token: string, sats: number):
  Promise<OnchainSwapInQuote | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/swap-in-onchain`, {
      method: 'POST', headers: headers(), body: JSON.stringify({ seller, token, sats }),
    })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

/** Poll the hop for a swap-in's progress (deposit seen → confirming → settled). */
export async function pollSwapIn(swapId: string): Promise<SwapInStatus | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/swap-in-onchain/${swapId}`, { headers: headers(), cache: 'no-store' })
    if (!r.ok) return null
    const j = await r.json()
    return (j?.status as SwapInStatus) ?? null
  } catch { return null }
}

// ── LP onboarding: BTC channel open ──────────────────────────────────────
// REAL MODEL (Option B, live): the LP runs NOTHING. It deposits BTC to a
// fleet-derived address and signs ONE cold on-chain delegation (registerDelegation)
// that pins (a) the authority it trusts to operate its channels and (b) its
// `btcRecipientOf` payout script. The fleet enclave (which holds BOTH MuSig2 key
// halves) then opens + operates the 2-of-2 channel on the LP's behalf; every payout
// (coop-close, splice-out, and the #114 dead-man exit) is pinned on-chain to that
// `btcRecipientOf`, so the fleet can never redirect funds. There is no per-open
// `lpAuth` round-trip and no LP-side funding-tx / SPV tooling in the live path.
//
// CUSTODY BACKSTOP (#114 dead-man exit): the fleet pre-signs a fully-signed,
// CLTV-timelocked unilateral-exit tx paying the LP's checkpoint balance →
// `btcRecipientOf`, emits its raw bytes on-chain (a `DeadManExitEmitted` event), and
// refreshes it on a heartbeat (each refresh pushes the CLTV forward). An alive fleet
// keeps the CLTV in the future ⇒ the exit is not broadcastable (no griefing). If the
// fleet vanishes the heartbeat stops, the last CLTV matures, and ANYONE — a keeper, a
// watchtower, or the LP via a stateless page hitting a public mempool API — broadcasts
// the already-public bytes. No key, no signing, no LP tool: Bitcoin's CLTV enforces it.
// The reference recovery client is the keyless `quid-recover-exit` bin (Rust module
// `quid_bridge::recovery_broadcast`): given a channelId it reads the latest
// `DeadManExitEmitted` log via `eth_getLogs` and, once the CLTV has matured, POSTs the
// raw exit tx to a public Esplora `/tx` endpoint — runnable by the LP, a keeper, or a watchtower.
//
// The request shape below is the LEGACY self-host / operator-direct open path, kept for
// operator tooling; the live delegated flow needs none of it (no `lpAuth`).
export interface OpenChannelRequest {
  params: unknown    // OpenParams { fundingBlockHash, fundingBlockHeight, fundingTxIndex, lpPubkey, hopPubkey, amountSats }
  rawTx: string      // funding tx, raw hex
  proof: string[]    // SPV merkle proof (block inclusion)
  lpAuth: string     // LEGACY: LP node signature over the raw openChannelDigest (live path uses on-chain delegatedAuthority)
  lpBtcPayout: string // LEGACY: LP payout commitment (bytes32) — live path pins btcRecipientOf at registerDelegation
}

export type OpenChannelStatus = 'submitted' | 'confirming' | 'opened' | 'rejected'
export interface OpenChannelResult {
  channelId?: string   // 0x… (keccak of the funding outpoint), once known
  txHash?: string      // the on-chain openChannel tx the hop relayed
  status: OpenChannelStatus
  reason?: string      // populated when status = rejected
}

/** Hand the channel-open artifacts to the hop for on-chain relay (§9b). */
export async function submitOpenChannel(req: OpenChannelRequest): Promise<OpenChannelResult | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/open-channel`, {
      method: 'POST', headers: headers(), body: JSON.stringify(req),
    })
    if (!r.ok) return { status: 'rejected', reason: `hop ${r.status}` }
    return await r.json()
  } catch { return null }
}

/** Poll the hop for an in-flight channel open (submitted → confirming → opened). */
export async function pollOpenChannel(channelId: string): Promise<OpenChannelResult | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/open-channel/${channelId}`, { headers: headers(), cache: 'no-store' })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

export const hopApiConfigured = ready
