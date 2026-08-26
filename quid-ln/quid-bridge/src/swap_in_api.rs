//! Swap-in request INGRID — the authenticated HTTP endpoints the QU!D app calls to
//! initiate a swap-in. ONE module for BOTH rails:
//!
//! POST /swap-in           (Lightning rail) — returns a BOLT11 swap-in invoice.
//!   { "seller":"0x..", "token":"0x..", "sats":N,
//!     "price_per_btc":"<u256 decimal>", "slippage_bps":N, "description":"..." }
//!   → 200 { "invoice":"lnbc..", "payment_hash":"0x.." }
//!
//! POST /swap-in/onchain   (Design-A regular-BTC rail) — returns a per-swap taproot
//!   DEPOSIT ADDRESS the sender (a user, or an LP self-funding) pays with plain on-chain
//!   BTC. Serves both cases: the caller is the `seller` (USD recipient) either way.
//!   { "seller":"0x..", "token":"0x..", "sats":N, "price_per_btc":"<u256>",
//!     "slippage_bps":N, "user_refund_pubkey":"<32-byte x-only hex>" }
//!   → 200 { "deposit_address":"bcrt1p..", "swap_id":"0x..", "cltv_height":N }
//!   The hop watches the address; once the deposit buries it settles `settleSwapIn`
//!   (floor recomputed from the ACTUAL deposited sats) then claims by key path. If the
//!   hop never settles, the sender reclaims via the CLTV refund leaf after `cltv_height`.
//!   Enabled only when the on-chain rail is running (else 503).
//!
//! POST /lp/onboard        ((B) LP onboarding) — the QU!D app calls this to start an open.
//!   Allocates the vault-wallet DEPOSIT ADDRESS the LP funds its channel from and starts
//!   watching it (the open orchestrator opens once the deposit buries). Idempotent per lpEth.
//!   { "lp_eth":"0x..", "btc_recipient":"<32-byte x-only hex>", "desired_sats":N,
//!     "payout_mode":"invoice"|"raw_btc" }
//!   → 200 { "deposit_address":"bcrt1p.." }
//!
//!   ⚠️ **THIS USED TO DESCRIBE A GATE THAT NO LONGER EXISTS**, and the description outlived
//!   the code twice over. It said the LP must first "sign `registerDelegation` on-chain" and
//!   that the endpoint "refuses unless `delegationVersion[lpEth] > 0` (the anti-spam gate —
//!   the LP paid gas to delegate)". §E157 (`e0fed54`) folded delegation INTO the open, so
//!   `registerDelegation` and `delegationVersion` are both gone from `BTCChannels`; the
//!   `delegationVersion` read here was still being made against the deleted selector and
//!   returned `BAD_GATEWAY` on every call until it was removed.
//!
//!   🔴 **SO THE ANTI-SPAM PROPERTY IS GONE, NOT MOVED.** The gate's real job was to make an
//!   onboard cost gas, and nothing replaced it: `/lp/onboard` now allocates a watched deposit
//!   address for any authenticated caller. The bearer token is the only thing limiting it.
//!   Booked rather than papered over — a rate limit here would be a clamp; the question is
//!   whether consent-riding-with-the-open should also carry a cost, or whether the token is
//!   considered sufficient because the app is the only client.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use alloy_primitives::{keccak256, Address, U256};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use quid_hop::node::SwapInInvoicer;
use quid_hop::swap::swap_in_floor_usd;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::client::eth_call_raw;
use crate::daemon::DaemonRpc;
use crate::swap_in_onchain::{OnchainSwapIn, SwapInRegistry};
use crate::vault::{register_lp, LpFunding, PayoutMode, VaultNode};
use quid_hop::swap_in_onchain::deposit_for;
use quid_ln::esplora::Esplora;

/// The deps the on-chain registration endpoint needs, handed in by the daemon when the
/// on-chain rail is enabled. `None` ⇒ `/swap-in/onchain` returns 503.
pub struct OnchainIngrid {
    pub master: Arc<bitcoin::bip32::Xpriv>,
    pub registry: Arc<SwapInRegistry>,
    pub esplora: Arc<Esplora>,
    pub network: bitcoin::Network,
    /// Blocks of refund headroom baked into a new deposit's CLTV (`tip + this`). Must
    /// comfortably exceed the watcher's settle-time headroom gate.
    pub cltv_window_blocks: u32,
}

/// Live on-chain-ingrid state (holds the swap-index counter, so it can't be `Clone`d —
/// shared behind `Arc`).
struct OnchainState {
    master: Arc<bitcoin::bip32::Xpriv>,
    registry: Arc<SwapInRegistry>,
    esplora: Arc<Esplora>,
    network: bitcoin::Network,
    cltv_window_blocks: u32,
    next_index: AtomicU32,
}

/// (B) Deps the `/lp/onboard` endpoint needs. `None` ⇒ that route returns 503. Holds the
/// vault node (whose wallet allocates the deposit address + whose registry the open
/// orchestrator watches) and an RPC handle + BTCChannels address to enforce the on-chain
/// delegation gate.
pub struct OnboardIngrid {
    pub vault: Arc<VaultNode>,
    pub rpc: DaemonRpc,
    pub btc_channels: Address,
}

#[derive(Clone)]
struct ApiState {
    invoicer: SwapInInvoicer,
    auth_token: Arc<String>,
    onchain: Option<Arc<OnchainState>>,
    onboard: Option<Arc<OnboardIngrid>>,
    /// (§SPRINT-D2#18) The registry the LP's consent binds INTO. NOT an `Option`: the daemon always
    /// has one — vault-less it is a fresh `VaultRegistry::new()` that `drive_open` reads anyway — so
    /// an `Option` would make its `None` arm unreachable (rule 1).
    consent: Arc<crate::vault::VaultRegistry>,
    /// (§LP-LIVENESS) The routing gate the LP's heartbeats land in. `None` ⇒ this deployment does
    /// not collect them and `/lp/heartbeat` reports so, rather than accepting posts into nothing —
    /// which is the failure mode §SPRINT-D2#18 found on the consent path and is worth not
    /// repeating.
    gate: Option<Arc<quid_hop::liveness::RoutingGate>>,
}

/// (§SPRINT-D2#18) One rung of the pre-signed exit ladder, on the wire.
///
/// Hex because `ExitArming` carries raw `Vec<u8>`/`[u8; 32]` and the codec types deliberately derive
/// no `serde` — widening them for one endpoint would put a wire format on the ABI encoder, where a
/// rename becomes a protocol break.
#[derive(Deserialize)]
struct ExitArmingReq {
    prev_values: Vec<u64>,
    prev_scripts: Vec<String>,
    cltv_deadline: u64,
    checkpoint_sats: u64,
    signed_exit_tx: String,
}

/// (§SPRINT-D2#18) The LP's consent for ONE open, keyed by the funding outpoint it authorises.
#[derive(Deserialize)]
struct ConsentReq {
    funding_txid: String,
    funding_vout: u32,
    btc_recipient: String,
    btc_recipient_pop: String,
    exits: Vec<ExitArmingReq>,
}

fn unhex(s: &str) -> Result<Vec<u8>, (StatusCode, String)> {
    alloy_primitives::hex::decode(s.strip_prefix("0x").unwrap_or(s))
        .map_err(|_| (StatusCode::BAD_REQUEST, "bad hex".into()))
}

/// (§SPRINT-D2#18) **THE INTAKE THE FLEET SAID IT HAD AND DID NOT.**
///
/// `daemon.rs:202` states the design — *"the consent and the ladder require the LP half, which after
/// §E175 the fleet does not have, so the fleet RELAYS"* — but until this endpoint,
/// `VaultRegistry::bind_consent` had **zero production callers**: four test assertions and two prose
/// mentions. ibiza's producer was booked; this intake was booked nowhere, so the pipeline had a
/// middle and no ends.
///
/// ⚠️ **IT FAILED SILENTLY, WHICH IS WHY IT SURVIVED.** `consent_for_funding` returns `Option` and
/// absence means DORMANT, not error — correct, since "the LP has not signed yet" must not be a loud
/// failure every reconciler tick. So a fleet with no intake simply never opened a channel, forever,
/// with nothing in the logs saying why.
///
/// 🔑 **WHY A STORE-AND-RELAY REGISTRY IS RIGHT HERE, AND NOT PLUMBING FOR A NON-ABSENCE.** The
/// tempting simplification — the LP is live whenever it signs, so ask it in-session and delete the
/// registry — was checked and REFUTED. `drive_open` runs against a funding tx **already confirmed on
/// Bitcoin** (it carries the raw tx and its merkle proof) and is retried by the reconciler every
/// tick; the LP signs its ladder against that outpoint at some other moment. **Signing and opening
/// are separated in time, so consent has to live somewhere in between.** Under the pre-§M1#2 model
/// the fleet held both halves and the registry really was redundant — `99fda5e9` is what made it
/// load-bearing, by making the LP a genuinely separate party that can be offline at a tick.
///
/// 🔑 **WHAT THIS DOES NOT DO, DELIBERATELY.** It does not re-check ladder depth or signatures.
/// `_armLadder` already rejects `exits.length < 2` and a ladder sharing one deadline, and
/// `_armDeadManExit` verifies every rung's structure, sighash and BIP-340 signature against the
/// funding key. A bad ladder fails LOUDLY at `openChannel` with a named revert; duplicating those
/// here would clamp a failure that already announces itself, and leave a second copy to drift.
/// (§LP-LIVENESS) One heartbeat, on the wire.
///
/// The LP signs `(channel_id, height, seq)` with its CHANNEL key — the same secp256k1 key the
/// contract derives `lpEth` from — so this needs no new key material and no MuSig2. `seq` is what
/// makes a captured heartbeat useless later: the book accepts only a strictly greater one.
#[derive(serde::Deserialize)]
struct HeartbeatReq {
    /// OUR `channelId` (0x-hex, 32 bytes) — the id the contract and the phone agree on. LDK's
    /// internal id is deliberately not accepted: the LP has no way to learn it.
    channel_id: String,
    /// The Bitcoin height the LP believes the tip to be at, measured against the SPV gateway's.
    height: u32,
    /// Strictly-increasing per channel.
    seq: u64,
    /// 65-byte recoverable ECDSA signature (0x-hex) over the heartbeat digest.
    sig: String,
}

/// Post a heartbeat. Deliberately says as little as possible about WHY one was not accepted.
///
/// ⚠️ **A REJECTED HEARTBEAT IS `{"recorded": false}`, NOT AN ERROR CODE PER CAUSE.** Bad
/// signature, wrong signer, replayed sequence and unknown channel are one answer to the poster —
/// *this did not update your liveness* — and distinguishing them would let an unauthenticated
/// caller probe which channels this hop serves and what sequence each LP has reached. The book
/// makes the same choice for the same reason (`LivenessBook::record` returns a bare bool).
async fn lp_heartbeat(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<HeartbeatReq>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad token".into()));
    }
    let Some(gate) = st.gate.as_ref() else {
        // Not an error: a deployment that does not gate routing is a valid one, and the LP should
        // learn that its posts are pointless rather than believing they landed.
        return Ok(Json(serde_json::json!({ "recorded": false, "gate": "disabled" })));
    };
    let cid: [u8; 32] = unhex(&req.channel_id)?
        .try_into()
        .map_err(|_| (StatusCode::BAD_REQUEST, "channel_id must be 32 bytes".into()))?;
    let sig = unhex(&req.sig)?;
    if sig.len() != 65 {
        return Err((StatusCode::BAD_REQUEST, "sig must be 65 bytes (r‖s‖v)".into()));
    }
    let hb = quid_hop::liveness::Heartbeat {
        channel_id: alloy_primitives::B256::from(cid),
        height: req.height,
        seq: req.seq,
    };
    let recorded = gate.record_by_cid(hb.channel_id, hb, &sig);
    Ok(Json(serde_json::json!({ "recorded": recorded })))
}

async fn lp_consent(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<ConsentReq>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad token".into()));
    }
    let registry = st.consent.clone();
    let recipient = unhex(&req.btc_recipient)?;
    let btc_recipient: [u8; 32] = recipient
        .try_into()
        .map_err(|_| (StatusCode::BAD_REQUEST, "btc_recipient must be 32 bytes (x-only)".into()))?;
    let mut exits = Vec::with_capacity(req.exits.len());
    for e in &req.exits {
        let mut prev_scripts = Vec::with_capacity(e.prev_scripts.len());
        for h in &e.prev_scripts {
            prev_scripts.push(unhex(h)?);
        }
        // Prevout values and scripts are ONE table indexed by input; a length mismatch is a
        // malformed request, not a signature failure, and saying so here is cheaper than letting it
        // surface as an opaque sighash mismatch inside `verifyDeadManExit`.
        if prev_scripts.len() != e.prev_values.len() {
            return Err((StatusCode::BAD_REQUEST, "prev_values/prev_scripts length mismatch".into()));
        }
        exits.push(quid_hop::evm_codec::ExitArming {
            prev_values: e.prev_values.clone(),
            prev_scripts,
            cltv_deadline: e.cltv_deadline,
            checkpoint_sats: e.checkpoint_sats,
            signed_exit_tx: unhex(&e.signed_exit_tx)?,
        });
    }
    let consent = crate::vault::LpConsent {
        auth: quid_hop::evm_codec::OpenAuth {
            btc_recipient,
            btc_recipient_pop: unhex(&req.btc_recipient_pop)?,
        },
        exits,
    };
    let txid = req.funding_txid.strip_prefix("0x").unwrap_or(&req.funding_txid).to_string();
    // `bind_consent` is idempotent on an IDENTICAL re-bind and REFUSES a conflicting one — consent
    // authorises ONE open, so letting a re-bind overwrite it would let whatever relays it swap in a
    // different ladder. A refusal is 409, not 400: the request is well-formed and the STATE rejects it.
    if registry.bind_consent(&txid, req.funding_vout, consent) {
        info!(txid = %txid, vout = req.funding_vout, rungs = req.exits.len(), "lp consent bound");
        Ok(Json(serde_json::json!({ "bound": true })))
    } else {
        warn!(txid = %txid, vout = req.funding_vout, "lp consent CONFLICTS with the one already bound");
        Err((StatusCode::CONFLICT, "a different consent is already bound for this outpoint".into()))
    }
}

#[derive(Deserialize)]
struct SwapInReq {
    seller: String,
    token: String,
    sats: u64,
    /// u256 decimal — the output stable's smallest units per 1 BTC (e.g. USDC
    /// 6-dec at $50k/BTC = "50000000000").
    price_per_btc: String,
    slippage_bps: u16,
    description: String,
}

#[derive(Serialize)]
struct SwapInResp {
    invoice: String,
    payment_hash: String,
}

#[derive(Deserialize)]
struct OnchainSwapInReq {
    seller: String,
    token: String,
    sats: u64,
    price_per_btc: String,
    slippage_bps: u16,
    /// The sender's refund key: 32-byte BIP340 x-only pubkey (hex). Spends the CLTV leaf.
    user_refund_pubkey: String,
}

#[derive(Serialize)]
struct OnchainSwapInResp {
    deposit_address: String,
    swap_id: String,
    cltv_height: u32,
}

type ApiError = (StatusCode, String);
fn bad(msg: impl Into<String>) -> ApiError {
    (StatusCode::BAD_REQUEST, msg.into())
}

/// Parse the elective payout mode string (see [`PayoutMode`]). Empty ⇒ the default,
/// [`PayoutMode::Invoice`]; an unrecognised value is a client error (never silently
/// coerced to a mode the LP didn't ask for).
fn parse_payout_mode(s: &str) -> Result<PayoutMode, ApiError> {
    match s {
        "" | "invoice" => Ok(PayoutMode::Invoice),
        "raw_btc" | "rawbtc" | "raw" => Ok(PayoutMode::RawBtc),
        other => Err(bad(format!("payout_mode: unknown '{other}' (invoice|raw_btc)"))),
    }
}

/// Parse + VALIDATE an LP's committed x-only P2TR recipient: 32 bytes of hex, a valid
/// BIP340 point, and non-zero — so `0x5120||key` is always a spendable key-path output
/// (a bad/zero key would strand the coop-close / withdrawal payout).
fn parse_btc_recipient(hex_str: &str) -> Result<[u8; 32], ApiError> {
    let bytes = alloy_primitives::hex::decode(hex_str.trim_start_matches("0x"))
        .map_err(|_| bad("btc_recipient: bad hex"))?;
    let key: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| bad("btc_recipient: must be a 32-byte x-only key"))?;
    if key == [0u8; 32] {
        return Err(bad("btc_recipient: zero key"));
    }
    bitcoin::XOnlyPublicKey::from_slice(&key)
        .map_err(|_| bad("btc_recipient: not a valid 32-byte x-only key"))?;
    Ok(key)
}

/// Constant-time bearer-token compare (avoid leaking the secret via timing).
fn token_ok(headers: &HeaderMap, expected: &str) -> bool {
    let got = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let exp = format!("Bearer {expected}");
    let (a, b) = (got.as_bytes(), exp.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Shared request parse for both rails: `(seller, token, price)` from the string fields.
fn parse_common(seller: &str, token: &str, sats: u64, price_per_btc: &str) -> Result<(Address, Address, U256), ApiError> {
    let seller = seller.parse::<Address>().map_err(|_| bad("seller: bad address"))?;
    let token = token.parse::<Address>().map_err(|_| bad("token: bad address"))?;
    if sats == 0 {
        return Err(bad("sats must be > 0"));
    }
    let price = U256::from_str_radix(price_per_btc.trim_start_matches("0x"), 10)
        .or_else(|_| U256::from_str_radix(price_per_btc.trim_start_matches("0x"), 16))
        .map_err(|_| bad("price_per_btc: bad u256"))?;
    Ok((seller, token, price))
}

async fn swap_in(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<SwapInReq>,
) -> Result<Json<SwapInResp>, ApiError> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad or missing bearer token".into()));
    }
    let (seller, token, price) = parse_common(&req.seller, &req.token, req.sats, &req.price_per_btc)?;
    let min_usd = swap_in_floor_usd(req.sats, price, req.slippage_bps);

    let invoice = st
        .invoicer
        .issue(seller, token, req.sats, min_usd, &req.description)
        .map_err(|e| {
            warn!(error = %e, "swap-in: issue failed");
            (StatusCode::INTERNAL_SERVER_ERROR, format!("issue invoice: {e}"))
        })?;
    let ph: [u8; 32] = *invoice.payment_hash().as_ref();
    info!(%seller, sats = req.sats, "swap-in invoice issued");
    Ok(Json(SwapInResp {
        invoice: invoice.to_string(),
        payment_hash: format!("0x{}", alloy_primitives::hex::encode(ph)),
    }))
}

async fn swap_in_onchain(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<OnchainSwapInReq>,
) -> Result<Json<OnchainSwapInResp>, ApiError> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad or missing bearer token".into()));
    }
    let oc = st
        .onchain
        .as_ref()
        .ok_or((StatusCode::SERVICE_UNAVAILABLE, "on-chain swap-in ingrid disabled".to_string()))?;
    let (seller, token, price) = parse_common(&req.seller, &req.token, req.sats, &req.price_per_btc)?;
    let ur_bytes = alloy_primitives::hex::decode(req.user_refund_pubkey.trim_start_matches("0x"))
        .map_err(|_| bad("user_refund_pubkey: bad hex"))?;
    let user_refund = bitcoin::XOnlyPublicKey::from_slice(&ur_bytes)
        .map_err(|_| bad("user_refund_pubkey: not a valid 32-byte x-only key"))?;

    // Absolute CLTV = current BTC tip + the refund window.
    let tip = oc
        .esplora
        .client()
        .get_height()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("esplora tip: {e}")))?;
    let cltv = bitcoin::absolute::LockTime::from_height(tip + oc.cltv_window_blocks)
        .map_err(|_| bad("cltv height overflow"))?;

    // Per-swap index → deterministic swap_id (also the settleSwapIn payment-hash / on-chain
    // dedup key) → the per-swap deposit key + address.
    let idx = oc.next_index.fetch_add(1, Ordering::SeqCst);
    let swap_id = keccak256([b"quid-swapin-onchain-v1".as_slice(), &idx.to_be_bytes()].concat());
    let secp = bitcoin::secp256k1::Secp256k1::new();
    // (§T2) The address COMMITS the rate quoted here. Computed from the very values registered
    // below, so the address the seller is told and the terms the settle is made against are one
    // fact rather than two that can drift.
    let terms = quid_hop::swap_in_onchain::terms_commitment(
        seller.into(), token.into(), price.to_be_bytes(), req.slippage_bps,
    );
    let (addr, _si, _leaf) =
        deposit_for(&secp, &oc.master, user_refund, cltv, oc.network, terms)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("derive deposit: {e:?}")))?;

    oc.registry.register(OnchainSwapIn {
        swap_id,
        swap_index: idx,
        seller,
        token,
        price_per_btc: price,
        slippage_bps: req.slippage_bps,
        user_refund,
        cltv,
        deposit_address: addr.clone(),
    });
    info!(%seller, sats = req.sats, %addr, "on-chain swap-in registered");
    Ok(Json(OnchainSwapInResp {
        deposit_address: addr.to_string(),
        swap_id: format!("0x{}", alloy_primitives::hex::encode(swap_id)),
        cltv_height: cltv.to_consensus_u32(),
    }))
}

#[derive(Deserialize)]
struct OnboardReq {
    lp_eth: String,
    /// The LP's committed key-path P2TR payout: 32-byte BIP340 x-only OUTPUT key (hex).
    /// MUST equal the `btcRecipient` the LP pinned on chain via the BIP-340 `btcRecipientPoP`
    /// in `OpenAuth` — the fleet does not re-derive it, it is the LP's committed value.
    /// (⚠️ this named `registerDelegation`, which is deleted; the pin moved to the open itself.)
    btc_recipient: String,
    desired_sats: u64,
    /// "invoice" (default) or "raw_btc" — see [`PayoutMode`].
    #[serde(default)]
    payout_mode: String,
}

#[derive(Serialize)]
struct OnboardResp {
    deposit_address: String,
}

async fn lp_onboard(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<OnboardReq>,
) -> Result<Json<OnboardResp>, ApiError> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad or missing bearer token".into()));
    }
    let ob = st
        .onboard
        .as_ref()
        .ok_or((StatusCode::SERVICE_UNAVAILABLE, "LP onboarding disabled".to_string()))?;

    let lp_eth = req.lp_eth.parse::<Address>().map_err(|_| bad("lp_eth: bad address"))?;
    let btc_recipient = parse_btc_recipient(&req.btc_recipient)?;
    if req.desired_sats == 0 {
        return Err(bad("desired_sats must be > 0"));
    }
    let payout_mode = parse_payout_mode(&req.payout_mode)?;

    // Anti-spam gate: only ever watch a deposit address for an lpEth that PAID GAS to
    // register its delegation on-chain (`delegationVersion[lpEth] > 0`). One lying RPC
    // can't forge a false positive into a real open (the open still requires the LP's
    // funds + the on-chain `_authorizedHop` gate); a false negative just refuses a real
    // LP, who retries.
    // (E157) THE DELEGATION PRE-CHECK IS GONE ENTIRELY, IN TWO STEPS.
    //
    // First: this called `delegationVersion(address)`, which `e0fed54` deleted when it folded
    // delegation INTO the open ("the registration tx goes"). The eth_call therefore failed on a
    // deleted selector and this handler returned BAD_GATEWAY on every request — LP onboarding was
    // BROKEN, not merely stale, and only the Rust-side ORPHAN check surfaced it. It was replaced
    // with a constant `true`, on the reasoning quoted just above: post-E157 an LP that has opened
    // is delegated BY CONSTRUCTION, so the pre-check had nothing left to discriminate.
    //
    // Then the flag itself was removed from `register_lp`, which is the better end state: a
    // parameter that is always `true` is a lie about there being a choice.
    //
    // 🔴 WHAT WAS LOST WITH IT, STATED PLAINLY: the old gate ALSO made an onboard COST GAS, and
    // nothing replaced that. `register_lp` is still idempotent per `lpEth`, so one identity
    // cannot inflate the watch set — but identities are now free, where they used to cost a
    // delegation tx. The bearer token is the only remaining limit on how many distinct `lpEth`
    // values can each claim a watched deposit address. Recorded rather than patched: a rate limit
    // here would be a clamp on the symptom, and the real question is whether consent riding with
    // the open should carry a cost of its own, or whether the token suffices because the app is
    // the only client.
    let f = LpFunding { lp_eth, btc_recipient, desired_sats: req.desired_sats, payout_mode };
    let addr = register_lp(&ob.vault.registry, &ob.vault.node, f).await.map_err(|e| {
        warn!(%lp_eth, error = %e, "lp onboard refused");
        (StatusCode::FORBIDDEN, format!("{e}"))
    })?;
    info!(%lp_eth, %addr, ?payout_mode, sats = req.desired_sats, "LP onboarded: deposit address issued");
    Ok(Json(OnboardResp { deposit_address: addr.to_string() }))
}

#[derive(Deserialize)]
struct WithdrawReq {
    /// The LP's on-chain BTCChannels channel id (bytes32 hex).
    channel_id: String,
    /// How many sats to splice out to the LP's committed `btcRecipient`.
    sats: u64,
}

#[derive(Serialize)]
struct WithdrawResp {
    /// The splice-out has been initiated; the reconciler mirrors the SHRINK onto the EVM.
    initiated: bool,
}

async fn lp_withdraw(
    State(st): State<ApiState>,
    headers: HeaderMap,
    Json(req): Json<WithdrawReq>,
) -> Result<Json<WithdrawResp>, ApiError> {
    if !token_ok(&headers, &st.auth_token) {
        return Err((StatusCode::UNAUTHORIZED, "bad or missing bearer token".into()));
    }
    let ob = st
        .onboard
        .as_ref()
        .ok_or((StatusCode::SERVICE_UNAVAILABLE, "LP onboarding disabled".to_string()))?;

    let cid_bytes = alloy_primitives::hex::decode(req.channel_id.trim_start_matches("0x"))
        .map_err(|_| bad("channel_id: bad hex"))?;
    let cid: [u8; 32] = cid_bytes
        .as_slice()
        .try_into()
        .map_err(|_| bad("channel_id: must be 32 bytes"))?;
    if req.sats == 0 {
        return Err(bad("sats must be > 0"));
    }

    // Resolve the channel's LP + its ON-CHAIN-AUTHORITATIVE payout script. We read the
    // recipient from `btcRecipientOf(lpEth)` (not the transient `LpFunding`, which the open
    // consumed) so the splice pays EXACTLY what the EVM `_withdrawalPayout` will require —
    // the on-chain pin is the source of truth, and a raw-BTC withdrawal to it is safe for
    // ANY LP (the funds can only land at the LP's own committed address).
    let state = crate::channel_driver::read_channel_state(&ob.rpc, ob.btc_channels, cid)
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("channels({}) read: {e}", req.channel_id)))?;
    if state.amount_sats == 0 {
        return Err(bad("channel not open on-chain (amountSats == 0)"));
    }
    let mut arg = [0u8; 32];
    arg[12..].copy_from_slice(state.lp_eth.as_slice());
    let recip_word =
        eth_call_raw(&ob.rpc, ob.btc_channels, "btcRecipientOf(address)", Some(&arg))
            .map_err(|e| (StatusCode::BAD_GATEWAY, format!("btcRecipientOf read: {e}")))?;
    let btc_recipient: [u8; 32] = recip_word
        .as_slice()
        .try_into()
        .map_err(|_| (StatusCode::BAD_GATEWAY, "btcRecipientOf: short return".to_string()))?;
    if btc_recipient == [0u8; 32] {
        return Err(bad("LP has no committed btcRecipient on-chain"));
    }

    ob.vault
        .withdraw_raw_btc(cid, req.sats, btc_recipient)
        .map_err(|e| {
            warn!(cid = %req.channel_id, error = %e, "lp withdraw splice-out failed");
            (StatusCode::INTERNAL_SERVER_ERROR, format!("withdraw: {e}"))
        })?;
    info!(cid = %req.channel_id, lp_eth = %state.lp_eth, sats = req.sats, "LP raw-BTC withdrawal initiated");
    Ok(Json(WithdrawResp { initiated: true }))
}

/// Serve the fleet API on `listen` until the process ends. `onchain` enables the
/// `/swap-in/onchain` rail and `onboard` the `/lp/onboard` + `/lp/withdraw` (B) routes
/// (`None` ⇒ those return 503). Returns on bind / serve error (the daemon supervises this
/// as a task → its return tears the daemon down).
pub async fn serve(
    listen: String,
    invoicer: SwapInInvoicer,
    auth_token: String,
    onchain: Option<OnchainIngrid>,
    onboard: Option<OnboardIngrid>,
    consent: Arc<crate::vault::VaultRegistry>,
    gate: Option<Arc<quid_hop::liveness::RoutingGate>>,
) {
    let onchain = onchain.map(|o| {
        // Restart-safe: resume the per-swap index ABOVE any persisted registration, so a
        // reboot never reuses an index (⇒ never a reused deposit address / swap_id).
        let seed = o.registry.next_index_seed();
        Arc::new(OnchainState {
            master: o.master,
            registry: o.registry,
            esplora: o.esplora,
            network: o.network,
            cltv_window_blocks: o.cltv_window_blocks,
            next_index: AtomicU32::new(seed),
        })
    });
    let onboard = onboard.map(Arc::new);
    let state =
        ApiState { invoicer, auth_token: Arc::new(auth_token), onchain, onboard, consent, gate };
    let app = Router::new()
        .route("/swap-in", post(swap_in))
        .route("/swap-in/onchain", post(swap_in_onchain))
        .route("/lp/onboard", post(lp_onboard))
        .route("/lp/withdraw", post(lp_withdraw))
        // (§SPRINT-D2#18) The LP's half arrives here.
        .route("/lp/consent", post(lp_consent))
        // (§LP-LIVENESS) And the LP's heartbeats arrive here. `RoutingGate::record` had no caller
        // at all before this — the gate could be bound and read but never FED, so the book stayed
        // empty and, failing closed, made every channel unroutable.
        .route("/lp/heartbeat", post(lp_heartbeat))
        .with_state(state);
    let listener = match tokio::net::TcpListener::bind(&listen).await {
        Ok(l) => l,
        Err(e) => {
            warn!(error = %e, %listen, "swap-in API: bind failed");
            return;
        }
    };
    info!(%listen, "swap-in API: listening");
    if let Err(e) = axum::serve(listener, app).await {
        warn!(error = %e, "swap-in API: serve error");
    }
}

#[cfg(test)]
mod tests {
    use super::token_ok;
    use axum::http::{header::AUTHORIZATION, HeaderMap, HeaderValue};

    fn hdr(v: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(AUTHORIZATION, HeaderValue::from_str(v).unwrap());
        h
    }

    #[test]
    fn bearer_auth_accepts_only_exact_token() {
        assert!(token_ok(&hdr("Bearer s3cret"), "s3cret"), "exact match accepted");
        assert!(!token_ok(&hdr("Bearer s3cret"), "other"), "wrong token rejected");
        assert!(!token_ok(&hdr("Bearer s3cre"), "s3cret"), "prefix rejected (length)");
        assert!(!token_ok(&hdr("s3cret"), "s3cret"), "missing Bearer prefix rejected");
        assert!(!token_ok(&HeaderMap::new(), "s3cret"), "missing header rejected");
    }

    use super::{parse_btc_recipient, parse_payout_mode};
    use crate::vault::PayoutMode;

    // secp256k1 generator x-coordinate — a valid BIP340 x-only point, used as a stand-in
    // for an LP's committed key-path P2TR recipient.
    const VALID_XONLY: &str =
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    #[test]
    fn payout_mode_parses_election_or_rejects() {
        assert_eq!(parse_payout_mode("").unwrap(), PayoutMode::Invoice, "empty ⇒ default Invoice");
        assert_eq!(parse_payout_mode("invoice").unwrap(), PayoutMode::Invoice);
        assert_eq!(parse_payout_mode("raw_btc").unwrap(), PayoutMode::RawBtc);
        assert_eq!(parse_payout_mode("raw").unwrap(), PayoutMode::RawBtc);
        assert!(parse_payout_mode("nonsense").is_err(), "unknown mode never silently coerced");
    }

    #[test]
    fn btc_recipient_validates_key_path_p2tr_key() {
        // Valid 32-byte x-only key (with + without 0x) round-trips to its bytes.
        let got = parse_btc_recipient(VALID_XONLY).expect("valid x-only accepted");
        assert_eq!(&alloy_primitives::hex::encode(got), VALID_XONLY);
        assert!(parse_btc_recipient(&format!("0x{VALID_XONLY}")).is_ok(), "0x-prefixed accepted");
        // Rejections: zero key, wrong length, non-hex, and an off-curve 32-byte value.
        assert!(parse_btc_recipient(&"00".repeat(32)).is_err(), "zero key rejected (unspendable)");
        assert!(parse_btc_recipient(&"ab".repeat(31)).is_err(), "31 bytes rejected");
        assert!(parse_btc_recipient("zz").is_err(), "bad hex rejected");
        assert!(parse_btc_recipient(&"ff".repeat(32)).is_err(), "off-curve x-only rejected");
    }
}
