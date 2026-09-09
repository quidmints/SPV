// Hop API client — the off-chain endpoint that mediates BTC↔USD swaps the EVM can't initiate alone.
//
// 🔑 **EVERY ROUTE, FIELD NAME AND CASING BELOW IS TRANSCRIBED FROM
// `quid-ln/quid-bridge/src/swap_in_api.rs`. THERE IS NO SHARED SCHEMA AND NO GATE**, so anything here
// that was not transcribed is invented, and an invented route fails as a 404 that the UI renders as
// "still working". `tools/check-client-abis.py` covers Solidity ABIs only — and only under `spa/` —
// so nothing at all checks this file against the server. Re-read the router in `serve()` before
// adding a call.
// ⚠️ **THE SERVER'S WIRE FORMAT IS `serde` DEFAULT snake_case.** camelCase field names deserialize
// as ABSENT; on a struct with no `#[serde(default)]` that is a 4xx, and on a response it is
// `undefined` at every read site. Do not "tidy" these names into the app's convention.
//
// ⚠️ **THE SPA'S COPY (`spa/src/lib/hop.ts`) STILL CALLS THE OLD, WRONG CONTRACT** — route
// `/swap-in-onchain`, three of six request fields missing, five camelCase response fields against
// three snake_case ones, and two poll routes that do not exist. It is not fixed here because the
// SPA cannot supply `user_refund_pubkey`: a browser session signing through Phantom/Ledger has no
// x-only BTC refund key and no custody story for one. See `docs/actionable/TODO.md`.
//
// The hop URL + bearer token are deployment config (see chains.ts HOP_API). Until they're set every
// call returns null and the UI shows "coming online".

import { HDNodeWallet } from 'ethers'

import { CONTRACTS, HOP_API } from './chains.ts'
import { readOne } from './eth.ts'
import { normaliseKey } from './keys.ts'
import { verifyQuotedDepositAddress } from './taproot.ts'

const headers = () => ({
  'content-type': 'application/json',
  ...(HOP_API.token ? { authorization: `Bearer ${HOP_API.token}` } : {}),
})

function ready(): boolean { return !!HOP_API.url }

export const hopApiConfigured = ready

// ── swap-in, on-chain rail ───────────────────────────────────────────────────────────────
//
// The seller is handed a Bitcoin ADDRESS to pay. The hop watches the deposit, SPV-proves it, and
// calls `settleSwapInProven`.

/// Exactly `OnchainSwapInReq` (`swap_in_api.rs:314`). All six fields are REQUIRED — `serde` has no
/// defaults on this struct, so an omitted field is a 4xx, not a defaulted value.
export interface OnchainSwapInRequest {
  /// 0x EVM address credited at settle.
  seller: string
  /// 0x EVM address of the output stable.
  token: string
  sats: number
  /// ⚠️ A DECIMAL (or 0x-hex) STRING, not a number: it is a u256 — the output stable's smallest
  /// units per 1 BTC (USDC 6-dec at $50k/BTC = "50000000000"). A JS number loses this silently.
  price_per_btc: string
  slippage_bps: number
  /// 🔑 **THE FIELD THE OLD CLIENT DID NOT SEND, AND THE REASON THE SWAP-IN RAIL COULD NEVER HAVE
  /// WORKED FROM THIS APP.** The sender's own 32-byte x-only BIP-340 refund key, which spends the
  /// deposit's CLTV leaf. It is the wallet's, never the hop's — `useLocalKey(...).xOnly` from
  /// `boot.ts` is exactly this value.
  /// ⛔ **AN EXTERNAL-WALLET SESSION HAS NO SUCH KEY.** `useExternalWallet` returns nothing
  /// precisely because Phantom/Ledger will not surrender the private key needed to derive one. Do
  /// not fabricate one: a refund key the user cannot sign for makes the deposit unreclaimable.
  user_refund_pubkey: string
}

/// Exactly `OnchainSwapInResp` (`swap_in_api.rs:325`). THREE fields, snake_case.
///
/// ⛔ **DO NOT ADD `exactSats`, `minDeliveredUsd` OR `expiresAt`.** `minDeliveredUsd` above all: §T2 moved the floor to being DERIVED on-chain from the committed RATE and
/// the SPV-proven sats (`BitcoinTx.settleFloorUsd`), so a hop-quoted floor is a second source of
/// truth for a number the chain computes.
export interface OnchainSwapInQuote {
  deposit_address: string
  swap_id: string
  /// The absolute BTC height the refund leaf unlocks at — the hop's tip plus its refund window.
  /// 🔑 Needed to VERIFY the address: it is committed in the deposit leaf, so
  /// `verifyQuotedDepositAddress` cannot run without it. Show it to the user as the refund
  /// deadline they are accepting, and sanity-bound it against a tip you did not get from the hop.
  cltv_height: number
}

/// Request an on-chain swap-in: returns a Bitcoin address to send to.
///
/// ⚠️ **VERIFY THE RETURNED ADDRESS BEFORE SHOWING IT.**
/// `taproot.ts::verifyQuotedDepositAddress` recomputes it from the wallet's own values plus the
/// chain's `BTC_DEPOSIT_KEY`, and a quote that fails that check must not be rendered as payable.
export async function requestOnchainSwapIn(req: OnchainSwapInRequest):
  Promise<OnchainSwapInQuote | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/swap-in/onchain`, {
      method: 'POST', headers: headers(), body: JSON.stringify(req),
    })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

/// (§QR-VERIFIER-UNASSEMBLED) **THE JOIN — request a quote and REFUSE one whose address the terms
/// do not imply.** Returns the quote only if it verifies; `null` for every other outcome.
///
/// 🔑 **`verifyQuotedDepositAddress` HAS BEEN BUILT AND TESTED SINCE 2026-08-31 AND HAD NO CALLER,
/// AND ITS STATED BLOCKER DOES NOT HOLD IN THIS TREE.** The blocker was an `internalX` the client
/// could not obtain without asking the hop — which would prove only that the hop is self-consistent.
/// **`BTCChannels.BTC_DEPOSIT_KEY` is a `public immutable` holding exactly that key**
/// (`BTCChannels.sol:820`), and it is the same value `_provenDeposit` derives every settle's address
/// from. So the one input the wallet cannot own comes from the CHAIN, and every other input is the
/// wallet's or the user's. A hop running unknown code cannot quote an address that survives this.
///
/// ⚠️ **`cltv_height` IS THE HOP'S, AND IT IS AN INPUT TO THE ADDRESS.** Verification cannot
/// falsify it — any height yields a derivable address — so it is returned rather than swallowed:
/// **the caller MUST show it as the refund deadline the user is accepting.** A UI that hides it lets
/// the hop pick a refund window nobody agreed to while every check still passes.
///
/// ⛔ **A NULL `BTC_DEPOSIT_KEY` READ IS A REFUSAL, NOT A SKIP.** `readOne` answers `null` for an
/// unconfigured address, an undeployed contract and a dead RPC alike; verifying against a key we
/// could not read is not verification.
export async function requestVerifiedOnchainSwapIn(req: OnchainSwapInRequest):
  Promise<OnchainSwapInQuote | null> {
  const q = await requestOnchainSwapIn(req)
  if (!q) return null
  const internalX: string | null = await readOne(CONTRACTS.btcChannels, 'BTC_DEPOSIT_KEY')
  if (!internalX) return null
  const ok = verifyQuotedDepositAddress({
    quotedAddress: q.deposit_address,
    internalX,
    userRefund: req.user_refund_pubkey,
    cltvHeight: q.cltv_height,
    seller: req.seller,
    token: req.token,
    pricePerBtc: BigInt(req.price_per_btc),
    slippageBps: req.slippage_bps,
  })
  return ok ? q : null
}

// ⛔ **THERE IS NO SWAP-IN POLL ROUTE. DO NOT ADD A CLIENT FOR ONE.**
// `serve()`'s router is exactly
// `/swap-in`, `/swap-in/onchain`, `/lp/onboard`, `/lp/withdraw`, `/lp/consent`, `/lp/heartbeat`.
// A `pollSwapIn` that 404s forever reads to the UI as "still confirming", which is worse than not
// polling. Progress is observable WITHOUT the hop: `settleSwapInProven` emits
// `SwapInSettled(seller, txid, sats, consumed, token)`, so watch the chain — the same reason the
// dead-man exit needs no hop tool. Do not restore a client for a route until it exists server-side.

// ── LP onboarding ────────────────────────────────────────────────────────────────────────
//
// REAL MODEL (Option B, live): the LP runs NOTHING. It deposits BTC to a fleet-derived address; the
// fleet enclave opens and operates the 2-of-2 on its behalf, and every payout (coop-close,
// splice-out, and the dead-man exit) is pinned on-chain to `btcRecipientOf`, so the fleet can never
// redirect funds.
//
// CUSTODY BACKSTOP (dead-man exit): the fleet pre-signs a CLTV-timelocked unilateral exit paying
// the LP's checkpoint balance to `btcRecipientOf`, emits its raw bytes on-chain
// (`DeadManExitEmitted`) and refreshes it on a heartbeat, each refresh pushing the CLTV forward. An
// alive fleet keeps the CLTV in the future ⇒ not broadcastable. If the fleet vanishes the last CLTV
// matures and ANYONE broadcasts the already-public bytes. No key, no signing, no LP tool — the
// reference client is the keyless `quid-recover-exit` bin.
//
// ⛔ **DO NOT ADD `POST /open-channel` OR A POLL FOR IT** — neither is in the router, and the
// artifacts such a call would carry (`lpAuth`, `lpBtcPayout`) do not exist: §E183 deleted `lp_eth`
// and `lp_sig` from `OpenAuth`, and `lpEth` is DERIVED on-chain from `lpPubkey` via
// `ChannelLib.lpEthOf`, because Bitcoin and the EVM share secp256k1. The LP signs NOTHING on the
// EVM side. What replaced them is `/lp/consent` below.

/// `OnboardReq` (`swap_in_api.rs:485`).
export interface LpOnboardRequest {
  lp_eth: string
  /// The LP's committed key-path P2TR payout: 32-byte x-only OUTPUT key (hex). MUST equal the
  /// `btcRecipient` the LP pinned on-chain via the BIP-340 PoP in `OpenAuth` — the fleet does not
  /// re-derive it.
  btc_recipient: string
  desired_sats: number
  /// "invoice" (default) or "raw_btc". An unrecognised value is a 400, never silently coerced.
  payout_mode?: 'invoice' | 'raw_btc'
}

/// Claim a watched deposit address for this LP. Returns the address to fund.
export async function lpOnboard(req: LpOnboardRequest): Promise<{ deposit_address: string } | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/lp/onboard`, {
      method: 'POST', headers: headers(), body: JSON.stringify(req),
    })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

/// `WithdrawReq` (`swap_in_api.rs:544`). Splice out to the LP's ON-CHAIN-pinned `btcRecipientOf` —
/// the destination is never a request field, which is what makes a withdrawal safe to expose.
export async function lpWithdraw(channel_id: string, sats: number):
  Promise<{ initiated: boolean } | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/lp/withdraw`, {
      method: 'POST', headers: headers(), body: JSON.stringify({ channel_id, sats }),
    })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

// ── The LP's consent for ONE open ────────────────────────────────────────────────────────

/// (§BTC-2.4d) HD path for the LP's Lightning PAYMENT BASEPOINT — the key `openChannel` turns into
/// `channel.lpToRemoteKey`, and therefore the key a force-close commitment's LP output is measured
/// against (`ChannelLib.lpToRemoteOutputKey`, `BTCChannels.sol:1012`).
///
/// 🔑 **A THIRD, DISTINCT SCALAR OFF THE SAME MNEMONIC — the property `§E182-b` demands.** It is the
/// same BIP-86 purpose and coin type as `root.ts`'s `FUNDING_PATH` (`m/86'/0'/0'/0/0`) and differs in
/// the hardened ACCOUNT, so it cannot collide with the funding half and no BIP-86 wallet restored
/// from these words will ever scan it as a receiving address (which an adjacent `.../0/1` WOULD be).
/// ⛔ **DO NOT REUSE THE FUNDING KEY.** A splice rotates the funding pubkey
/// (`new_funding_pubkey(prev_funding_txid)`); nothing rotates a basepoint, and the contract pins
/// this one for the channel's whole life. ⛔ **DO NOT REUSE `btcRecipientOf`** — §E182-b: one key as
/// both payout destination and channel key converts a degraded-service event into fund loss.
const LP_PAYMENT_BASEPOINT_PATH = "m/86'/0'/1'/0/0"

/// (§BTC-2.4d) Derive the LP's 33-byte COMPRESSED payment basepoint from the enclave-held mnemonic.
///
/// 🔴 **THIS EXISTS BECAUSE THE APP COULD NOT SUPPLY WHAT IT DID NOT DERIVE, AND THE ALTERNATIVE IS
/// A SILENTLY DISARMED CHECK.** The fleet could read a payment point off its own monitor — but the
/// fleet SUBMITS the open, so a compromised one would then be choosing the key the force-close
/// check keys on: pin a point that matches no output and every force close measures zero while the
/// check still appears to run. The point has to come from the LP, and the LP is this wallet.
///
/// ⚠️ **BIP-340-NORMALISED, AND THAT IS NOT COSMETIC.** `lpToRemoteOutputKey` drops the compressed
/// parity prefix and builds the `to_remote` leaf from the X-ONLY key, so the chain cannot tell
/// `02‖x` from `03‖x` — but the SCALAR that can spend that output differs by a negation. Deriving
/// through `normaliseKey` (see `keys.ts` for the half-of-all-users trap this closes) makes the
/// returned point always even-y and its matching secret always `normaliseKey(...).privateKey`, so
/// the identity the fleet pins and the key the LP can sign with cannot disagree.
///
/// ⚠️ The caller must already hold an unlocked mnemonic from `getOrCreateRootMnemonic()`. The
/// mnemonic is NOT taken by `postLpConsent` below on purpose: this module also does `fetch`, and
/// seed material has no business inside a request builder.
export function deriveLpPaymentPoint(mnemonic: string): string {
  const node = HDNodeWallet.fromPhrase(mnemonic, '', LP_PAYMENT_BASEPOINT_PATH)
  // `normaliseKey` returns the x-only form; the wire and the contract want the 33-byte COMPRESSED
  // point, and `02` is the compressed prefix for the even-y point normalisation guarantees.
  return `0x02${normaliseKey(node.privateKey).xOnly.slice(2)}`
}

/// One rung of the pre-signed exit ladder (`ExitArmingReq`, `swap_in_api.rs:114`). Hex strings,
/// because the codec types deliberately derive no `serde`.
export interface ExitArmingWire {
  prev_values: number[]
  /// Same length as `prev_values` — prevout values and scripts are ONE table indexed by input, and
  /// a length mismatch is refused as malformed rather than surfacing as an opaque sighash failure.
  prev_scripts: string[]
  cltv_deadline: number
  checkpoint_sats: number
  signed_exit_tx: string
}

/// `ConsentReq` (`swap_in_api.rs:124`) — keyed by the funding outpoint it authorises.
export interface LpConsentRequest {
  funding_txid: string
  funding_vout: number
  /// 32-byte x-only payout key.
  btc_recipient: string
  /// The LP's BIP-340 Schnorr proof-of-possession over `btcRecipientPoPDigest(lpEth)`. **A BITCOIN
  /// signature, not an EVM one** — the LP signs nothing on the EVM side.
  btc_recipient_pop: string
  /// The LP's 33-byte COMPRESSED Lightning payment basepoint.
  /// 🔑 It comes from the LP and not the fleet BECAUSE the fleet submits the open: a compromised
  /// fleet reading it off its own monitor would be choosing the key the force-close check keys on.
  /// ⚠️ It is an IDENTITY, not consent — it carries no signature of its own, and its integrity
  /// comes entirely from the PoP beside it, which commits to `keccak256(lp_payment_point)`.
  /// ⛔ **THE ONLY LEGITIMATE PRODUCER IS `deriveLpPaymentPoint(mnemonic)` ABOVE.** Any other value
  /// here — a hop-quoted one above all — reintroduces exactly the substitution the field exists to
  /// prevent, and nothing downstream can detect it: the PoP commits to whatever is passed.
  lp_payment_point: string
  /// One pre-signed spend of the 2-of-2 per rung. `_armLadder` rejects fewer than two rungs and a
  /// ladder sharing one deadline.
  exits: ExitArmingWire[]
}

export type LpConsentResult =
  | { bound: true }
  /// 🔑 **A CONFLICTING RE-BIND IS REFUSED, NOT OVERWRITTEN** (409). Consent authorises ONE open, so
  /// letting a re-bind replace it would let whatever relays it swap in a different ladder. An
  /// IDENTICAL re-bind is idempotent and returns `bound`. Surface this to the user as a refusal to
  /// be understood, never as a retryable network error.
  | { bound: false; conflict: true }

/// Post the LP's consent for one open.
///
/// ⛔ **NOT WIRED TO A SIGNER YET, AND MUST NOT BE FAKED.** Every `signed_exit_tx` is a MuSig2
/// partial over a spend of a live 2-of-2, which needs an interactive BIP-327 session
/// (`@scure/btc-signer`'s `musig2.js`, absent from this wallet's `node_modules`). Producing a
/// ladder with anything hand-rolled is where nonce reuse silently leaks the LP's funding key. This
/// function is the transport for a ladder built elsewhere; it does not build one.
///
/// ⚠️ **AND `channelTruth.check` MUST HAVE PASSED FIRST.** These rungs ARE the spends §T9 bounds.
export async function postLpConsent(req: LpConsentRequest): Promise<LpConsentResult | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/lp/consent`, {
      method: 'POST', headers: headers(), body: JSON.stringify(req),
    })
    if (r.status === 409) return { bound: false, conflict: true }
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

/// `HeartbeatReq` (`swap_in_api.rs:184`). The LP signs `(channel_id, height, seq)` with its CHANNEL
/// key — the same secp256k1 key the contract derives `lpEth` from — so this needs no new key
/// material and no MuSig2. `seq` is what makes a captured heartbeat useless later: the book accepts
/// only a strictly greater one.
///
/// ⚠️ **A REJECTED HEARTBEAT IS `{recorded: false}`, NOT AN ERROR PER CAUSE** — bad signature, wrong
/// signer, replayed sequence and unknown channel are deliberately one answer, so an unauthenticated
/// caller cannot probe which channels this hop serves. `{recorded: false, gate: "disabled"}` means
/// the deployment does not gate routing and the posts are pointless, which is worth telling the user
/// rather than letting them believe the beats landed.
export async function postLpHeartbeat(req: {
  channel_id: string; height: number; seq: number; sig: string
}): Promise<{ recorded: boolean; gate?: string } | null> {
  if (!ready()) return null
  try {
    const r = await fetch(`${HOP_API.url}/lp/heartbeat`, {
      method: 'POST', headers: headers(), body: JSON.stringify(req),
    })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}
