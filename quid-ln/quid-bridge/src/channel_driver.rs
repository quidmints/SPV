//! BTC-channel lifecycle driver — mirrors LDK channel closes onto the EVM.
//!
//! The hop emits [`ChannelLifecycleEvent`]s (funding ready / closed); 
//! driver turns a `Closed` event into matching `BTCChannels` call so 
//! EVM retires the position. OPEN path (which needs the LP's `lpAuth` 
//! over a custom LN message) is wired separately.
//!
//! self-contained from Bitcoin — no `lpAuth`, no custom message, permissionless:
//!   1. the close tx is the spend of the funding outpoint (esplora `outspend`);
//!   2. its 2-of-2 witnessScript yields the sorted funding pubkeys → recompute
//!      the on-chain `channelId` ([`channel_id`]);
//!   3. idempotency: read `channels(channelId)` — skip if never opened or
//!      already `STATUS_CLOSED` (the chain IS the state; no local journal);
//!   4. confirmation-gate: wait until the `SPVGateway` has the close block with
//!      ≥ `SPV_MIN_CONFIRMATIONS` confirmations (the relayer keeps it current);
//!   5. classify by the close tx's actual `locktime` — `0` ⇒ cooperative
//!      (`recordClose` pays the LP its proceeds), non-zero ⇒ unilateral
//!      (`recordClose`'s non-coop branch, delivered=0) — matching the contract.
//!      Either way the single `recordClose` entrypoint is called.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy_primitives::{hex, Address, U256};
use anyhow::{ensure, Context};
use bitcoin::secp256k1::PublicKey;
use bitcoin::Txid;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use quid_hop::event_handler::ChannelLifecycleEvent;
use quid_hop::evm_codec::{
    build_open_params, build_splice_params, channel_id, encode_open_channel, encode_record_close,
    encode_record_force_close_permissionless, encode_splice, is_commitment_tx,
    sort_funding_pubkeys, tx_inclusion, txid_internal,
};
use quid_hop::node::{
    channel_funding_pubkeys, initiate_splice, HopChainMonitor, HopChannelManager,
};
use quid_hop::rebalancer::{
    RebalanceConfig, MIN_ECONOMIC_GROW_SATS, SPLICE_FUNDING_FEERATE_SAT_PER_KW,
};
use quid_ln::wallet::OnchainWallet;
use quid_common::constants::CHANNEL_MAX_FUNDING_SATS;
use quid_ln::esplora::Esplora;

use crate::client::JsonRpcEvmClient;
use crate::config::BridgeConfig;
use crate::relayer::{estimate_gas, read_gateway_height};
use crate::signer::LocalSigner;
use crate::store::BridgeStore;
use crate::transport::JsonRpc;

/// Mirrors `BTCChannels.MIN_CONFIRMATIONS`: the gateway's `checkTxInclusion`
/// requires the close block to have ≥ this many confirmations
/// (`mainchainHeight − blockHeight`), so we gate submission on it. Hard-coded to
/// match the contract rather than read a (mis)configurable value.
pub(crate) const SPV_MIN_CONFIRMATIONS: u64 = 6;

// `Types.BTCChannel.status` values (mirror Types.sol).
pub(crate) const STATUS_OPEN: u8 = 0;
const STATUS_CLOSED: u8 = 2;

/// Which `BTCChannels` entrypoint a close tx must use — decided by its locktime,
/// exactly as the contract discriminates (cooperative closes carry `locktime==0`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CloseKind {
    Cooperative,
    Force,
}

fn classify_close(locktime: u32) -> CloseKind {
    if locktime == 0 {
        CloseKind::Cooperative
    } else {
        CloseKind::Force
    }
}

/// RAII guard for a slot in the SHARED in-flight set (`active`), keyed by on-chain
/// cid. Held by both `run_channel_driver` and `run_channel_reconciler`; a drive is
/// skipped while a slot for its cid is live.
///
/// The slot MUST be released on BOTH normal completion AND panic-unwind of the
/// drive task, otherwise a panicking drive leaks the cid forever — that channel
/// would then be skipped by BOTH the event path and the reconciler (both check
/// `active.contains`) until a process restart, i.e. permanent liveness loss for
/// that channel. The previous `if let Err(e) = drive_*().await { … } ; remove()`
/// pattern only ran `remove` on a returned `Err`, NOT on a panic-unwind. Moving an
/// `ActiveSlot` INTO the spawned task makes its `Drop` release the slot on every
/// exit path (return, `?`-propagated error, or unwind).
struct ActiveSlot {
    set: Arc<Mutex<HashSet<[u8; 32]>>>,
    cid: [u8; 32],
}

impl ActiveSlot {
    /// Atomically check-and-insert the cid into the shared set. Returns
    /// `Some(guard)` if the slot was free (now claimed — the guard releases it on
    /// drop), or `None` if a drive for this cid is already in flight (caller skips,
    /// preserving the prior skip-if-present semantics).
    fn claim(set: &Arc<Mutex<HashSet<[u8; 32]>>>, cid: [u8; 32]) -> Option<ActiveSlot> {
        if set.lock().unwrap().insert(cid) {
            Some(ActiveSlot { set: set.clone(), cid })
        } else {
            None
        }
    }
}

impl Drop for ActiveSlot {
    fn drop(&mut self) {
        // Poison-recovery: if the lock was poisoned by a panic elsewhere we still
        // remove our slot (recover the inner guard) rather than re-panic in Drop —
        // a panic while unwinding would abort the process.
        self.set
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.cid);
    }
}

/// What the reconciler needs to do for a channel after comparing the authoritative
/// sources (LDK monitor + Bitcoin + the on-chain `channels()` record).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReconcileAction {
    Open,
    Close,
    /// G-1: the funding UTXO is provably spent by a BOLT #3 COMMITMENT (force-close)
    /// transaction, yet the on-chain `channels()` record still shows the channel
    /// OPEN. A force close means the hop is dead/offline (else it would coop-close)
    /// AND the LP — having recovered its BTC on-chain — is incentivized to LEAVE the
    /// position open (it keeps counting as QUI backing). The participant-gated
    /// `recordClose` may never be called by either party, so the reconciler drives
    /// the PERMISSIONLESS `recordForceClosePermissionless` to retire the position
    /// (delivered=0, mints nothing). Distinguished from `Close` by the spending tx
    /// being a genuine commitment tx (`is_commitment_tx`).
    ForceClose,
    /// An LDK splice changed the channel's funding on Bitcoin (grow OR shrink) but
    /// the on-chain mirror still shows the old `amountSats` (e.g. a restart between
    /// `SpliceLocked` and the live `Spliced` drive). Re-drive `splice` to catch up.
    Splice,
}

/// Decide what (if anything) the reconciler must do to bring a channel's on-chain
/// `BTCChannels` mirror in line with its Bitcoin/LDK state. Pure (no I/O) so the
/// classification — especially the splice-vs-close guard below — is unit-testable.
/// `None` means "already consistent / wait" (the reconciler loop `continue`s).
///
/// - `spent` / `close_txid`: whether the CURRENT funding outpoint
///   (`get_funding_txo`) is spent on Bitcoin, and by which tx.
/// - `status` / `amount_sats`: the on-chain `channels()` record (`STATUS_OPEN`,
///   funded total; `amount_sats == 0` ⇒ never opened on the EVM).
/// - `ldk_value`: the LDK channel's current funded total (changes after a splice).
/// - `pending_splice_txids`: the NEW funding outpoints' txids of any
///   confirmed-but-not-yet-locked splice (`ChannelMonitor::pending_funding_txos`).
///
/// GUARD (splice vs close): a CONFIRMED-but-not-yet-LOCKED splice tx spends the OLD
/// funding outpoint, but LDK has not yet rotated `get_funding_txo()` to the new
/// outpoint (rotation happens at `SpliceLocked` / confirmation depth). esplora
/// reports the old outpoint spent as soon as the splice broadcasts, so without this
/// guard the reconciler would classify the splice as a close and drive
/// `recordClose` on the splice tx — whose non-zero locktime hits the force-close
/// branch (delivered=0), force-retiring a LIVE channel and forfeiting the LP's
/// swap-out proceeds. After a restart only the reconciler runs (no live `Spliced`
/// drive holding the `ActiveSlot`), so it would be DETERMINISTIC, not just a race.
/// We return `None` while the spend is the pending splice tx; once LDK rotates, the
/// `!spent && ldk_value != amount_sats` arm drives the splice.
///
/// G-1 (force-close vs coop-close): when the funding UTXO is spent by a spend that
/// is NOT the pending splice, `close_is_commitment` discriminates a BOLT #3
/// COMMITMENT (unilateral/force) close from a cooperative close. A commitment-tx
/// spend ⇒ `ForceClose` (drive the PERMISSIONLESS `recordForceClosePermissionless`,
/// which is gated on-chain by the same `isCommitmentTx` check); any other spend ⇒
/// `Close` (the participant-gated `recordClose`, which the EVM branches by locktime).
/// The caller computes `close_is_commitment` from the fetched close tx via
/// [`is_commitment_tx`] — the exact mirror of the on-chain discriminator.
fn select_reconcile_action(
    spent: bool,
    close_txid: Option<bitcoin::Txid>,
    close_is_commitment: bool,
    status: u8,
    amount_sats: u128,
    ldk_value: u64,
    pending_splice_txids: &[bitcoin::Txid],
) -> Option<ReconcileAction> {
    if spent && status == STATUS_OPEN {
        if close_txid.is_some_and(|t| pending_splice_txids.contains(&t)) {
            return None; // confirmed-but-not-locked splice — not a close
        }
        // G-1: a genuine commitment (force-close) tx → the permissionless retire;
        // anything else (a cooperative close) → the participant-gated recordClose.
        if close_is_commitment {
            Some(ReconcileAction::ForceClose)
        } else {
            Some(ReconcileAction::Close)
        }
    } else if !spent && amount_sats == 0 {
        Some(ReconcileAction::Open)
    } else if !spent && status == STATUS_OPEN && (ldk_value as u128) != amount_sats {
        Some(ReconcileAction::Splice)
    } else {
        None
    }
}

/// The on-chain `channels(channelId)` view we need: `amountSats == 0` means the
/// channel was never opened on the EVM; `status` discriminates open vs closed.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ChannelState {
    pub(crate) amount_sats: u128,
    pub(crate) status: u8,
    /// The LP's EVM address (`channels().lpEth`) — the fee-owed key + the account
    /// requestDeposit credits. Needed hop-side to look up `btcFeesOwedSats`.
    pub(crate) lp_eth: Address,
}

/// Read `channels(bytes32)` via `eth_call`. The public mapping getter returns the
/// flat `BTCChannel` tuple `(uint amountSats, bytes32 fundingTxId, address lpEth,
/// uint32 fundingVout, uint8 status)` — 5 static words.
pub(crate) fn read_channel_state<R: JsonRpc>(
    rpc: &R,
    btc_channels: Address,
    cid: [u8; 32],
) -> anyhow::Result<ChannelState> {
    let bytes = crate::client::eth_call_raw(rpc, btc_channels, "channels(bytes32)", Some(&cid))?;
    if bytes.len() < 160 {
        anyhow::bail!("channels(bytes32): short return ({} bytes)", bytes.len());
    }
    // Do NOT silently cap an out-of-range amount to u128::MAX: amountSats feeds the
    // idempotency / splice-vs-open reconcile decisions (`amount_sats == 0` ⇒ never
    // opened; `amount_sats >= new_total` ⇒ splice already applied), so a fabricated
    // MAX from a garbage RPC response would corrupt those checks. A genuine on-chain
    // amountSats is far below u128::MAX, so an overflow is an adversarial response —
    // surface it as an error instead of inventing a value.
    let amount_sats: u128 = crate::client::word_to_uint(&bytes, "channels(bytes32): amountSats exceeds u128")?;
    let status = bytes[159]; // last byte of word[4] (uint8 status)
    let lp_eth = Address::from_slice(&bytes[76..96]); // word[2] = lpEth (last 20 bytes)
    Ok(ChannelState { amount_sats, status, lp_eth })
}

/// (§LAZY-OPEN-RETRY) Sats custodied by `openChannel` whose LP pool claim is still DEFERRED.
///
/// Non-zero means the channel is open and its ladder armed, but the LP is not yet earning: the
/// claim leg reverted on protocol-wide state (`checkBacking`/`repack`/`ZeroTwap`) when the open
/// landed, so `openChannel` booked it instead of crediting inline. Anyone may complete it via
/// `registerChannelClaim`; the reconciler is simply the party that always notices.
pub(crate) fn read_pending_claim<R: JsonRpc>(
    rpc: &R,
    btc_channels: Address,
    cid: [u8; 32],
) -> anyhow::Result<u128> {
    let bytes = crate::client::eth_call_raw(rpc, btc_channels, "pendingClaimSats(bytes32)", Some(&cid))?;
    if bytes.len() < 32 {
        anyhow::bail!("pendingClaimSats(bytes32): short return ({} bytes)", bytes.len());
    }
    // Same reasoning as `amountSats` above: do NOT cap a garbage value into range. This figure
    // only ever gates whether we submit a retry, so an adversarial MAX would cost a wasted tx
    // rather than corrupt accounting — but surfacing it is still cheaper than explaining it later.
    crate::client::word_to_uint(&bytes, "pendingClaimSats(bytes32): exceeds u128")
}

/// Best-effort revert-reason decode for a BTCChannels call that `send_tx`
/// reported reverted (it only yields a bool). Replays the calldata as a
/// read-only `eth_call` and surfaces what the node returns: many nodes put the
/// revert payload in the JSON-RPC error (so `call` errors with the hex in its
/// Display), others return the revert bytes as the result. We pass through the
/// raw revert data (the 4-byte custom-error selector is enough to identify e.g.
/// WrongHopPubkey) and additionally decode the standard `Error(string)` shape.
/// Without this the operator sees only "reverted" with no cause.
pub(crate) fn eth_call_revert_reason<R: JsonRpc>(
    rpc: &R,
    from: Address,
    to: Address,
    calldata: &[u8],
) -> String {
    let params = serde_json::json!([{
        "from": from.to_string(),
        "to": to.to_string(),
        "data": format!("0x{}", hex::encode(calldata)),
    }, "latest"]);
    let raw = match rpc.call("eth_call", params) {
        Ok(v) => v.as_str().unwrap_or_default().to_string(),
        Err(e) => e.to_string(),
    };
    // Standard `Error(string)`: selector 0x08c379a0 ‖ abi.encode(string). If the
    // raw text carries that, pull the human message out of the trailing UTF-8.
    if let Some(pos) = raw.find("08c379a0") {
        if let Ok(bytes) = hex::decode(raw[pos + 8..].trim_end_matches(|c: char| !c.is_ascii_hexdigit())) {
            if bytes.len() >= 64 {
                let len = U256::from_be_slice(&bytes[32..64]).try_into().unwrap_or(0usize);
                if let Some(s) = bytes.get(64..64 + len).and_then(|b| std::str::from_utf8(b).ok()) {
                    return format!("Error(\"{s}\")");
                }
            }
        }
    }
    if raw.is_empty() { "revert (no data returned)".to_string() } else { raw }
}

/// Gas limit for a single BTCChannels call (openChannel / recordClose): the
/// `eth_estimateGas` result + 25% headroom, floored at `floor` (cfg.gas_limit) —
/// so a call whose cost grows with merkle-proof depth or Quid state can't OOG.
/// On estimate failure (the call would revert) fall back to `floor` and let
/// `send_tx` surface the revert.
pub(crate) fn gas_limit_for<R: JsonRpc>(rpc: &R, to: Address, calldata: &[u8], floor: u64) -> u64 {
    // openChannel/recordClose are ~hundreds of k gas; an estimate far above this
    // is a bogus/lying RPC, not a real cost. Ignore an absurd estimate (use the
    // configured floor) so a malicious node can't inflate our gas_limit into an
    // un-includable or gas-wasting tx.
    const MAX_PLAUSIBLE_GAS: u64 = 15_000_000;
    match estimate_gas(rpc, to, calldata) {
        Ok(g) if g <= MAX_PLAUSIBLE_GAS => (g.saturating_mul(125) / 100).max(floor),
        _ => floor, // estimate failed OR absurd → configured floor
    }
}

/// Estimate gas for `calldata` (spawn_blocking [`gas_limit_for`], floored at
/// `floor`) then submit it via `evm.send_tx` (also spawn_blocking). Returns the
/// on-chain success flag. Shared by every `drive_*` path (close / force-close /
/// open / splice), whose gas-estimate + send prologue was byte-identical.
pub(crate) async fn estimate_gas_and_send<R: JsonRpc>(
    evm: &Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: &Arc<R>,
    to: Address,
    calldata: Vec<u8>,
    floor: u64,
) -> anyhow::Result<bool> {
    let gas = {
        let rpc2 = rpc.clone();
        let cd = calldata.clone();
        tokio::task::spawn_blocking(move || gas_limit_for(&*rpc2, to, &cd, floor))
            .await
            .context("gas estimate join")?
    };
    let evm = evm.clone();
    let ok = tokio::task::spawn_blocking(move || evm.send_tx(to, calldata, gas))
        .await
        .context("send_tx join")??;
    Ok(ok)
}

/// Poll the SPV gateway's mainchain height until it reaches `need_height` 
/// (the relayer feeds it). BOUNDED — a stuck/lagging relayer surfaces an error rather than
/// hanging driver forever (prior unbounded loop 429 when relayer couldn't advance gateway).
pub(crate) async fn wait_for_gateway_height<R: JsonRpc>(rpc: &Arc<R>,
    gateway: Address, need_height: u64, cfg: &BridgeConfig) -> anyhow::Result<()> {
    // Alert EARLY if the gateway stops advancing (relayer frozen/down) instead of
    // silently info-logging for ~2.5h before the terminal bail. We distinguish
    // "advancing but not there yet" (healthy, just wait) from "not advancing at
    // all" (relayer stuck → loud warn so the operator can restart the permissionless
    // relayer well before the timeout).
    const STUCK_WARN_AFTER: u32 = 20; 
    const MAX_ATTEMPTS: u32 = 300;
    // consecutive non-advancing polls → warn once
    let mut last_h: Option<u64> = None;
    let mut stuck = 0u32; let mut warned = false;
    for _ in 0..MAX_ATTEMPTS { let rpc2 = rpc.clone();
        let h = tokio::task::spawn_blocking(move || 
            read_gateway_height(&*rpc2, gateway)).await.context("read_gateway_height join")??;
        if h >= need_height {
            return Ok(());
        }
        match last_h {
            Some(prev) if h > prev => { stuck = 0; warned = false; } // advancing → healthy
            Some(_) => stuck += 1,                                   // frozen at the same height
            None => {}
        }
        last_h = Some(h);
        if stuck >= STUCK_WARN_AFTER && !warned {
            warned = true;
            warn!(
                gateway_height = h, need_height, non_advancing_polls = stuck,
                "SPV gateway NOT advancing — relayer appears stuck/down; close/splice is \
                 blocked until headers resume (the relayer is permissionless — restart it)"
            );
        } else {
            info!(gateway_height = h, need_height, "waiting for SPV gateway to advance");
        }
        tokio::time::sleep(Duration::from_secs(cfg.relay_poll_secs.max(1))).await;
    }
    anyhow::bail!(
        "gateway height never reached {need_height} after {MAX_ATTEMPTS} polls \
         (relayer stuck — check addBlockHeaderBatch gas / batch size)"
    )
}

/// Drive EVM close for a single channel. Idempotent (re-reads on-chain state)
/// and confirmation-gated. Returns `Ok(())` once the close is recorded (or was
/// already recorded / the channel was never opened); `Err` only on a terminal
/// problem after the internal retries/waits. Uncle block wrong call arches
pub async fn drive_close<R: JsonRpc>(cfg: Arc<BridgeConfig>,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>, rpc: Arc<R>, 
    esplora: Arc<Esplora>, funding_txid: Txid, funding_vout: u32,
    // keys a channel on its ORIGINAL funding outpoint and keeps that id across a
    // SPLICE (which rotates the live outpoint). The close tx spends the CURRENT
    // (post-splice) outpoint, so recomputing the id from the close tx would miss
    // a spliced channel's record. The live driver passes `Some(originalId)` from
    // its open-time map; `None` ⇒ recompute from the witness (correct for a
    // never-spliced channel).
    
    known_cid: Option<[u8; 32]>,
    // The channel's 2-of-2 funding pubkeys, read from LDK by the caller
    // (`channel_funding_pubkeys`). REQUIRED only when `known_cid` is `None`
    
    // SIMPLE-TAPROOT (key-path MuSig2) close carries an EMPTY witnessScript 
    // just 64-byte Schnorr sig — so the channelId can no longer be recovered 
    
    // by parsing close witness (pre-taproot path parsed the 2-of-2
    // witnessScript off a P2WSH spend; that parser is now removed). 
    // Instead the caller supplies the keys it already holds and the id is 
    // recomputed witness-free via `channel_id(..)`. Ignored when `known_cid` 
    // is `Some` (the splice/reconciler path knows it).
    funding_pubkeys: Option<([u8; 33], [u8; 33])>,

    // The reconciler already read `get_output_status` (to detect the spend) and
    // thus knows the close txid — it passes it here so we skip re-polling esplora
    // for a spend we've already observed. The live driver is LDK-event-triggered
    // (no txid in hand) → passes `None` and polls below as before.
    known_close_txid: Option<Txid>,
) -> anyhow::Result<()> {
    let client = esplora.client();
    // Locate the close tx, the spend of the funding outpoint. May lag LDK
    // event by a few esplora polls; wait for it. (Skipped when the caller
    // already observed the spend and handed us the txid.)
    let close_txid = if let Some(txid) = known_close_txid { 
            txid } else { let mut found = None;
        
        for _ in 0..cfg.receipt_poll_attempts.max(1) {
            let outspend = client.get_output_status(
                 &funding_txid, funding_vout as u64).await.context("get_output_status")?;
            if let Some(os) = outspend { if os.spent { if let Some(txid) = os.txid { 
                                                        found = Some(txid); break; }
                }
            } tokio::time::sleep(Duration::from_secs(
                        cfg.receipt_poll_secs.max(1))).await;

        } found.with_context(|| {
            format!("funding outpoint {funding_txid}:{funding_vout} not seen spent")
        })?
    }; // Close tx → sorted 2-of-2 funding pubkeys (witnessScript) + locktime.
    let close_tx = client.get_tx(&close_txid).await.context("get close tx")?
                .with_context(|| format!("close tx {close_txid} not found"))?;
                
    // STABLE id from the caller (handles spliced channels — see `known_cid`), or
    // recompute from the channel's STORED funding pubkeys + the original outpoint
    // (correct for a never-spliced channel). We do NOT parse the close witness: 
    // simple-taproot key-path close has an empty witnessScript, so the keys can
    // only come from what the channel already knows (`channel_funding_pubkeys`).
    let cid = match known_cid {
        Some(c) => c,
        None => {
            let (lp_pubkey, hop_pubkey) = funding_pubkeys.context(
                "drive_close: known_cid is None and no stored funding pubkeys supplied \
                 (a taproot key-path close has no witnessScript to recover them from)",
            )?;
            let (k0, k1) = sort_funding_pubkeys(lp_pubkey, hop_pubkey);
            channel_id(&k0, &k1, txid_internal(&funding_txid), funding_vout)
        }
    };
    let kind = classify_close(close_tx.lock_time.to_consensus_u32());

    // 3. Idempotency — the chain is the source of truth.
    let btc_channels = cfg.btc_channels;
    let state = {
        let rpc = rpc.clone();
        tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("read_channel_state join")??
    };
    if state.amount_sats == 0 {
        info!(%close_txid, cid = %hex::encode(cid), "channel never opened on EVM; nothing to close");
        return Ok(());
    }
    if state.status == STATUS_CLOSED {
        info!(%close_txid, cid = %hex::encode(cid), "channel already recorded closed; skip");
        return Ok(());
    }
    if state.status != STATUS_OPEN {
        warn!(status = state.status, cid = %hex::encode(cid), "unexpected channel status; proceeding");
    }

    // 4. Confirmation-gate — wait for the gateway to cover the close block deeply.
    let incl = tx_inclusion(&esplora, &close_txid)
        .await
        .context("close tx inclusion proof")?;
    let need_height = incl.height + SPV_MIN_CONFIRMATIONS;
    let gateway = cfg.spv_gateway;
    wait_for_gateway_height(&rpc, gateway, need_height, &cfg)
        .await
        .with_context(|| format!("gateway never reached close-block confs for {close_txid}"))?;

    // 5. Build + submit. ONE entrypoint — recordClose handles both close types; the
    // EVM reads the tx's locktime and branches (coop settles proceeds, non-coop
    // retires with delivered=0). `kind` is still used for the log label below.
    // (E178/E153) `recordClose` gained the channel's `OpenParams` so it can reconstruct the
    // 2-of-2 and tell a SPLICE from a CLOSE — which is what makes recording PERMISSIONLESS
    // rather than hop-only. Only the pubkeys are read (see `_requireChannelKeys`), so the
    // SPV fields are zeroed, as in the dead-man path.
    // ⚠️ THIS IS WHY `funding_pubkeys` IS NOW REQUIRED and not just "when `known_cid` is
    // None": without it there is nothing to reconstruct the 2-of-2 from, and a close cannot
    // be recorded at all. Failing here is correct — submitting without it would revert.
    let (lp_pk, hop_pk) = funding_pubkeys.context(
        "drive_close: recordClose needs the channel's funding pubkeys (E178) — a taproot \
         key-path close has no witnessScript to recover them from",
    )?;
    let close_params = quid_hop::evm_codec::OpenParams {
        funding_block_hash_be: [0u8; 32],
        funding_block_height: 0,
        funding_tx_index: 0,
        lp_pubkey: lp_pk,
        hop_pubkey: hop_pk,
        amount_sats: 0,
        funding_taproot: quid_hop::funding::taproot_funding_aggregate_xonly(&lp_pk, &hop_pk),
    };
    let calldata = encode_record_close(
        cid,
        &close_params,
        &incl.raw,
        incl.block_hash_be,
        &incl.merkle_proof,
        incl.tx_index,
    );
    let ok = estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, cfg.gas_limit).await?;
    if !ok {
        // Reverted — most likely a race (someone else recorded it, since close is
        // permissionless). Re-read: if now CLOSED it's benign, else surface it.
        let rpc = rpc.clone();
        let state = tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("post-revert read join")??;
        if state.status == STATUS_CLOSED {
            info!(%close_txid, "close reverted but channel is CLOSED (raced); ok");
            return Ok(());
        }
        // Both kinds call the single recordClose entrypoint; log the close KIND,
        // not a (now-nonexistent) per-kind function name.
        anyhow::bail!("recordClose ({}) reverted for {close_txid} (cid {})", match kind {
            CloseKind::Cooperative => "cooperative",
            CloseKind::Force => "non-coop",
        }, hex::encode(cid));
    }
    info!(%close_txid, cid = %hex::encode(cid), ?kind, "recorded channel close on EVM");
    Ok(())
}

/// G-1: drive the PERMISSIONLESS force-close retire for a channel whose funding
/// UTXO is provably spent by a BOLT #3 COMMITMENT (unilateral/force) close that the
/// EVM still shows OPEN. Mirrors [`drive_close`]'s structure (idempotency-gate +
/// confirmation-gate + SPV proof) but submits `recordForceClosePermissionless`,
/// which is gated on-chain by `isCommitmentTx` and settles `delivered=0` (retires to
/// on-chain reality, mints nothing).
///
/// WHY a distinct driver (vs `drive_close`): a force close is exactly when the hop
/// is dead/offline and the LP is incentivized to LEAVE the position open (it keeps
/// counting as QUI backing + earning V4 fees), so neither participant calls
/// `recordClose`. The permissionless entrypoint lets the bridge (any keeper) retire
/// the dead position without either participant's cooperation.
///
/// The reconciler is the only caller, so the STABLE on-chain `cid` (keyed on the
/// ORIGINAL outpoint, stable across splices) is always known and passed in — never
/// recomputed from the close tx. `known_close_txid` is the spend the reconciler
/// already observed (no esplora re-poll). Idempotent + confirmation-gated.
pub async fn drive_force_close<R: JsonRpc>(
    cfg: Arc<BridgeConfig>,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    cid: [u8; 32],
    close_txid: Txid,
) -> anyhow::Result<()> {
    let client = esplora.client();
    let btc_channels = cfg.btc_channels;

    // 1. Fetch the close tx; re-assert it is a genuine commitment tx (the same gate
    //    the contract enforces). The reconciler already classified it, but a fresh
    //    decode here keeps drive_force_close correct in isolation and avoids
    //    submitting a doomed (NotForceClose-reverting) tx if the input was wrong.
    let close_tx = client
        .get_tx(&close_txid)
        .await
        .context("get force-close tx")?
        .with_context(|| format!("force-close tx {close_txid} not found"))?;
    ensure!(
        is_commitment_tx(&close_tx),
        "drive_force_close: {close_txid} is not a BOLT#3 commitment tx \
         (recordForceClosePermissionless would revert NotForceClose) — use recordClose"
    );

    // 2. Idempotency — the chain is the source of truth.
    let state = {
        let rpc = rpc.clone();
        tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("read_channel_state join")??
    };
    if state.amount_sats == 0 {
        info!(%close_txid, cid = %hex::encode(cid), "channel never opened on EVM; nothing to force-close");
        return Ok(());
    }
    if state.status == STATUS_CLOSED {
        info!(%close_txid, cid = %hex::encode(cid), "channel already recorded closed; skip force-close");
        return Ok(());
    }

    // 3. Confirmation-gate — wait for the gateway to cover the close block deeply.
    let incl = tx_inclusion(&esplora, &close_txid)
        .await
        .context("force-close tx inclusion proof")?;
    let need_height = incl.height + SPV_MIN_CONFIRMATIONS;
    let gateway = cfg.spv_gateway;
    wait_for_gateway_height(&rpc, gateway, need_height, &cfg)
        .await
        .with_context(|| format!("gateway never reached force-close-block confs for {close_txid}"))?;

    // 4. Build + submit the PERMISSIONLESS retire (same SPV proof as recordClose).
    let calldata = encode_record_force_close_permissionless(
        cid,
        &incl.raw,
        incl.block_hash_be,
        &incl.merkle_proof,
        incl.tx_index,
    );
    let ok = estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, cfg.gas_limit).await?;
    if !ok {
        // Reverted — most likely a race (the entrypoint is permissionless, so a
        // keeper may have retired it first). Re-read: if now CLOSED it's benign.
        let rpc = rpc.clone();
        let state = tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("post-revert read join")??;
        if state.status == STATUS_CLOSED {
            info!(%close_txid, "force-close reverted but channel is CLOSED (raced); ok");
            return Ok(());
        }
        anyhow::bail!(
            "recordForceClosePermissionless reverted for {close_txid} (cid {})",
            hex::encode(cid)
        );
    }
    info!(%close_txid, cid = %hex::encode(cid), "recorded permissionless force-close on EVM");
    Ok(())
}

/// Drive the EVM open for a freshly-confirmed channel: read the channel's
/// 2-of-2 funding pubkeys from LDK, build + verify the canonical OpenParams,
/// obtain the LP's `lpAuth` over the custom LN message, and submit
/// `openChannel`. Idempotent (skips if already open on-chain) and
/// confirmation-gated, like the close path.
#[allow(clippy::too_many_arguments)]
pub async fn drive_open<R: JsonRpc + Send + Sync + 'static>(
    cfg: Arc<BridgeConfig>,
    #[allow(unused_variables)]
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    registry: Arc<crate::vault::VaultRegistry>,
    funding_txid: Txid,
    funding_vout: u32,
) -> anyhow::Result<()> {
    // 1. Read both 2-of-2 funding pubkeys from our own monitor (the QU!D LDK
    //    accessor); build_open_params sorts them into channelId order.
    let (pa, pb) = channel_funding_pubkeys(
        &chain_monitor,
        &channel_manager,
        funding_txid,
        funding_vout,
    )
    .with_context(|| {
        format!("funding pubkeys not available for {funding_txid}:{funding_vout} (channel not ready?)")
    })?;

    // 1b. Derive the LP's BTC payout hash from its LDK-committed upfront shutdown
    //     script (QU!D accessor; pinned at open by `commit_upfront_shutdown_pubkey`,
    //     enforced unchanged at close). This is recorded on-chain as the LP's
    //     btcRecipientOf AS PART OF THE OPEN — no separate registration tx — so the
    //     EVM attributes the LP's cooperative-close balance to exactly where LDK
    //     pays it. We require a clean P2WPKH (`0x00 0x14 || HASH160`, 22 bytes);
    //     anything else (or no upfront commitment) means we can't guarantee
    //     attribution, so we refuse to register the channel (openChannel is
    //     hop-gated → an unregistered channel can never feed recordClose).
    // (B) Retained as a defensive cross-check source (the LP's committed shutdown) but no
    // longer passed to openChannel. ⚠️ The clause here said `btcRecipientOf` *"is pinned at
    // registerDelegation"* — that function is deleted. It is pinned by the BIP-340
    // `btcRecipientPoP` inside `OpenAuth`, at the open itself.
    let _lp_btc_payout_hash = {
        let spk = quid_hop::node::channel_counterparty_shutdown_script(
            &channel_manager, funding_txid, funding_vout,
        )
        .with_context(|| format!(
            "LP committed no upfront shutdown script for {funding_txid}:{funding_vout}; \
             cannot attribute its cooperative-close payout — refusing to open"
        ))?;
        let b = spk.as_bytes();
        ensure!(
            b.len() == 34 && b[0] == 0x51 && b[1] == 0x20,
            "LP committed shutdown script is not key-path P2TR for {funding_txid}:{funding_vout}; \
             cannot attribute its cooperative-close payout — refusing to open"
        );
        // The 32-byte x-only key IS the whole bytes32 (matches the contract's
        // `btcRecipientOf` x-only key + `_lpPayoutScript`'s `0x5120||btcRecipientOf`).
        let mut h = [0u8; 32];
        h.copy_from_slice(&b[2..34]);
        h
    };

    // 2. Canonical OpenParams (also verifies the on-chain P2WSH) + channelId.
    let (params, raw, proof) =
        build_open_params(&esplora, &funding_txid, funding_vout, pa, pb).await?;
    let cid = channel_id(
        &params.lp_pubkey,
        &params.hop_pubkey,
        txid_internal(&funding_txid),
        funding_vout,
    );

    // 3. Idempotency — skip if already opened on-chain.
    let btc_channels = cfg.btc_channels;
    let state = {
        let rpc = rpc.clone();
        tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("read_channel_state join")??
    };
    if state.amount_sats != 0 {
        info!(cid = %hex::encode(cid), "channel already open on EVM; skip");
        return Ok(());
    }

    // 4. Confirmation-gate: the funding block needs >= MIN_CONFIRMATIONS confs in
    //    the gateway (the relayer keeps it current).
    let need_height = params.funding_block_height + SPV_MIN_CONFIRMATIONS;
    let gateway = cfg.spv_gateway;
    wait_for_gateway_height(&rpc, gateway, need_height, &cfg)
        .await
        .with_context(|| format!("gateway never reached funding-block confs for {funding_txid}"))?;

    // 5. (B) Resolve lpEth from the vault registry — the fleet opened this channel from
    //    THAT LP's on-chain BTC deposit (funding_outpoint → lpEth, bound at
    //    create_channel), so there is NO lpAuth round-trip: the LP runs nothing.
    //
    //    ⚠️ **THIS LOOKUP IS BOOKKEEPING, NOT AUTHORIZATION** — the two sentences that stood here
    //    said otherwise and named state that no longer exists. They read *"authorization is
    //    on-chain (`delegatedAuthority[lpEth] == msg.sender`), and `btcRecipientOf` was pinned at
    //    `registerDelegation`"*; §E157 deleted `registerDelegation` and §E183 deleted the whole
    //    delegation surface, so `delegatedHop`, `delegationVersion` and `delegatedAuthority` are at
    //    zero live references in `evm/src`. A comment describing a deleted gate as the live one is
    //    the failure mode this contract calls out elsewhere — a reader auditing who may open a
    //    channel would have audited nothing.
    //
    //    WHAT ACTUALLY AUTHORIZES AN OPEN, as of §E166-3/§E183:
    //      * WHO may submit — `openChannel` calls `_onlyHop()` like every other hop entrypoint.
    //      * WHOSE channel — the contract DERIVES `lpEth = ChannelLib.lpEthOf(p.lpPubkey)` rather
    //        than accepting it, so this side cannot name someone else's LP even if it wanted to.
    //      * THE LP's CONSENT — the BIP-340 `btcRecipientPoP` over that derived address, plus a
    //        mandatory pre-signed exit ladder. The LP signs NOTHING on the EVM.
    //    ⇒ so what we need `lp_eth` for here is to look up WHOSE consent to relay, and to log it.
    //    If the binding hasn't landed yet (or this isn't a vault-owned channel), skip — the
    //    reconciler retries.
    let Some(lp_eth) = registry.lp_for_funding(&funding_txid.to_string(), funding_vout) else {
        debug!(%funding_txid, "open: no vault funding→lpEth binding yet; skip (reconciler retries)");
        return Ok(());
    };
    debug!(%funding_txid, lp_eth = %lp_eth, "open: resolved lpEth from vault registry; submitting openChannel");

    // 7. (E166-3) RELAY the LP's consent — the fleet cannot manufacture it.
    //
    // `openChannel` needs an `OpenAuth` (the LP's signature over `openAuthDigest` plus the
    // §E138 proof-of-possession) and a non-empty §E165 `ExitArming` ladder. Both are spends
    // or signatures requiring the LP funding half, which after §E175 lives on the LP's own
    // box — so the fleet RELAYS consent and never synthesises it.
    //
    // ⚠️ ABSENT CONSENT IS DORMANCY, NOT FAILURE. This used to `bail!`, which turned an
    // ordinary "the LP has not signed yet" into a loud error on every reconciler tick. It
    // now skips exactly as the missing-lpEth binding above does: the open stays pending and
    // is retried, which is the same additive-state discipline the rest of this path uses.
    let Some(consent) = registry.consent_for_funding(&funding_txid.to_string(), funding_vout)
    else {
        debug!(%funding_txid, lp_eth = %lp_eth,
            "open: no LP consent (OpenAuth + ExitArming ladder) yet; skip (reconciler retries)");
        return Ok(());
    };
    let calldata =
        encode_open_channel(&params, &raw, &proof, &consent.auth, &consent.exits);
    let diag_calldata = calldata.clone();
    let ok = estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, cfg.gas_limit).await?;
    if !ok {
        let rpc_read = rpc.clone();
        let state = tokio::task::spawn_blocking(move || read_channel_state(&*rpc_read, btc_channels, cid))
            .await
            .context("post-revert read join")??;
        if state.amount_sats != 0 {
            info!(cid = %hex::encode(cid), "openChannel reverted but channel is open (raced); ok");
            return Ok(());
        }
        // Surface WHY it reverted: replay as eth_call (no state change) and decode
        // the returned revert reason. send_tx only yields a bool, so without this
        // the operator sees "reverted" with no selector — undebuggable in prod.
        let from = evm.address();
        let rpc_diag = rpc.clone();
        let reason = tokio::task::spawn_blocking(move || {
            eth_call_revert_reason(&*rpc_diag, from, btc_channels, &diag_calldata)
        })
        .await
        .unwrap_or_else(|e| format!("revert-reason probe join error: {e}"));
        anyhow::bail!(
            "openChannel reverted for {funding_txid}:{funding_vout} (cid {}): {reason}",
            hex::encode(cid)
        );
    }
    info!(cid = %hex::encode(cid), %funding_txid, "opened channel on EVM");
    // (§LAZY-OPEN) NO CLAIM CALL HERE, DELIBERATELY. `openChannel` credits the LP's pool position
    // INLINE whenever the basket is healthy, and only books `pendingClaimSats` + emits
    // `ChannelClaimDeferred` when the claim leg itself reverts. So an unconditional
    // `registerChannelClaim` right here would revert `NothingToClaim()` on every healthy open —
    // a warn line per channel that means nothing, which is how a log stops being read.
    // ⚠️ **AND THE RETRY WOULD BE WRONG HERE FOR A SECOND REASON, not just a noisy one:** at open
    // time the basket is BY DEFINITION the thing that just refused, so retrying in the same breath
    // retries into the same failure. It belongs on a periodic pass that waits for the condition to
    // clear. `run_channel_reconciler` does it (§LAZY-OPEN-RETRY) — it already resolves every
    // channel's `cid` each pass, so the retry costs one `pendingClaimSats` read that normally
    // returns zero.
    // (B) Prune the funding→lpEth binding now the open is mirrored — `by_funding` only
    // holds in-flight opens, so it can't grow unbounded over the daemon's lifetime.
    registry.clear_inflight(&funding_txid.to_string(), funding_vout);
    Ok(())
}

/// SPLICE driver — resize an already-open channel in place (grow = the capacity
/// knob given one-channel-per-LP; shrink = the LP's partial withdrawal). Mirrors
/// [`drive_open`] on the EVM side: build the canonical
/// [`OpenParams`](quid_hop::evm_codec::OpenParams) for the splice tx's new 2-of-2
/// output (which also verifies its on-chain P2WSH), idempotency-gate against the
/// live `channels(channelId)` state, wait for the splice block's confirmations in
/// the gateway, then submit `splice`. The on-chain `channelId` is STABLE across a
/// splice (keyed on the ORIGINAL funding outpoint), so it is passed in, never
/// recomputed from the splice outpoint.
///
/// (B) Authorization is on-chain (the channel's HOP GATE, `channel.hop`, fixed at
/// open to a delegated hop) — the retired lpAuth round-trip is gone, the LP runs
/// nothing. The 2-of-2 pubkeys are read from LDK ([`channel_funding_pubkeys`] at the
/// splice outpoint — the channel's `funding_txo` post-`SpliceLocked`), so this is
/// correctness-by-construction like [`drive_open`]: the hop re-derives + verifies
/// exactly what the LP signed. The ONE remaining upstream input is the confirmed
/// splice outpoint, produced by the LP-initiated LDK channel-splice (the vendored
/// LDK acceptor cannot contribute, so the LP — whose sats fund the grow —
/// initiates) and surfaced to the bridge via `Event::SplicePending`.
///
/// Idempotent (skips if the on-chain funded total already covers the new total)
/// and confirmation-gated, exactly like the open/close paths.
#[allow(clippy::too_many_arguments)]
pub async fn drive_splice<R: JsonRpc + Send + Sync + 'static>(
    cfg: Arc<BridgeConfig>,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    channel_id: [u8; 32],
    splice_txid: Txid,
    splice_vout: u32,
    // (§E233-ladder) Same registry `drive_open` reads, and keyed the same way — by FUNDING OUTPOINT.
    // A splice's new outpoint IS a funding outpoint, so the LP's ladder for it binds under
    // `bind_consent(splice_txid, splice_vout, ..)` with no new plumbing.
    registry: Arc<crate::vault::VaultRegistry>,
) -> anyhow::Result<()> {
    let btc_channels = cfg.btc_channels;
    let cid = channel_id;

    // 1. Read the channel's 2-of-2 funding pubkeys from LDK. Post-SpliceLocked the
    //    channel's funding_txo IS the splice outpoint, so we look them up there
    //    (the pubkeys are static across a splice); build_splice_params sorts them.
    let (pa, pb) = channel_funding_pubkeys(
        &chain_monitor,
        &channel_manager,
        splice_txid,
        splice_vout,
    )
    .with_context(|| {
        format!("funding pubkeys not available for splice {splice_txid}:{splice_vout} (channel not spliced/locked?)")
    })?;

    // 2. Canonical params for the splice tx's NEW 2-of-2 output (amount_sats = the
    //    new TOTAL). build_splice_params also verifies the on-chain P2WSH equals
    //    the reconstructed 2-of-2, so a wrong outpoint is rejected here.
    let (params, raw, proof) =
        build_splice_params(&esplora, &splice_txid, splice_vout, pa, pb).await?;

    // 2. Live channel state: must be OPEN. The splice may GROW or SHRINK the funded
    //    total. Idempotency — if the on-chain total already equals the new total,
    //    this splice already landed → skip (mirrors drive_open's already-open skip;
    //    the contract would revert SpliceUnchanged anyway).
    let state = {
        let rpc = rpc.clone();
        tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
            .await
            .context("read_channel_state join")??
    };
    if state.amount_sats == 0 {
        anyhow::bail!(
            "splice: channel {} not open on EVM (cannot splice an unopened channel)",
            hex::encode(cid)
        );
    }
    if state.status != STATUS_OPEN {
        anyhow::bail!(
            "splice: channel {} not STATUS_OPEN (status {})",
            hex::encode(cid),
            state.status
        );
    }
    let new_total = params.amount_sats as u128;
    if new_total == state.amount_sats {
        info!(
            cid = %hex::encode(cid),
            on_chain = state.amount_sats, new_total,
            "splice already applied on EVM (unchanged total); skip"
        );
        return Ok(());
    }

    // 3. Confirmation-gate the splice block, same as open/close.
    let need_height = params.funding_block_height + SPV_MIN_CONFIRMATIONS;
    let gateway = cfg.spv_gateway;
    wait_for_gateway_height(&rpc, gateway, need_height, &cfg)
        .await
        .with_context(|| format!("gateway never reached splice-block confs for {splice_txid}"))?;

    // (B) No lpAuth round-trip — the LP runs nothing. `splice` is authorized on-chain by
    // the channel's HOP GATE (channel.hop, fixed at open to a delegated hop), so we just
    // build + submit.
    //
    // (§E191 follow-on) The `let lp_eth = state.lp_eth;` binding that stood here is deleted: it
    // was read ONLY by the `fee_settle_sats` computation §E191 removed, so it had been dead
    // since — surfacing as a compiler warning that named the leftover exactly.

    // FEE-INTO-CHANNEL: on a GROW, opportunistically flush this LP's accrued
    // BTC-leg fees (`Vault.btcFeesOwedSats`) INTO the position instead of paying them out
    // via a separate settler tx. The hop funds `grew_by` real sats into the splice; up to
    // that much is marked `fee_settle_sats`, which the contract clamps to the real owed
    // (BtcLib) and clears — the fees COMPOUND into `LP.pooled` via requestDeposit
    // (which already grew pooled by the full delta), and a bigger POOLED share grows the
    // LP's coop-close payout to btcRecipientOf, so `delivered` stays invariant with NO
    // LN-balance leg (under B the LP has no LN node — the old keysend is obsolete). A
    // shrink grows nothing → settle 0.
    // ⛔ (E191) THE `fee_settle_sats` COMPUTATION IS DELETED — it was a per-splice RPC
    // round-trip to a function that no longer exists. It read `Vault.btcFeesOwedSats(address)`,
    // which §E145 DELETED (`Vault.sol:210`), swallowed the resulting revert with
    // `.unwrap_or(0)`, and passed the zero to a `splice` parameter the contract explicitly
    // ignored. Both halves failed quietly, so the waste was invisible from either side.
    // 6. Build + submit splice (channelId is the STABLE original). No lpAuth (B).
    //
    // (§E233-ladder) THE FRESH EXIT LADDER FOR THE ROTATED OUTPOINT, and it is MANDATORY on-chain. A
    // splice spends the funding UTXO, so every rung armed against the OLD one is unspendable; the
    // contract now arms the new set inside `splice` itself so there is no block in which the
    // channel has no escape. The rungs are spends of the 2-of-2, so only the LP half can produce
    // them — the fleet relays, exactly as at open.
    //
    // ⚠️ ABSENT LADDER IS DORMANCY, NOT FAILURE — the same shape `drive_open` uses. The LP signs
    // the splice tx itself, so it CAN produce these in the same session; a gap here means it has
    // not posted them yet, and the reconciler's next pass retries. Bailing would log an error on
    // every tick for an ordinary waiting state.
    let Some(consent) = registry.consent_for_funding(&splice_txid.to_string(), splice_vout) else {
        debug!(cid = %hex::encode(cid), %splice_txid, splice_vout,
            "splice: no LP ExitArming ladder for the rotated outpoint yet; skip (reconciler retries)");
        return Ok(());
    };
    let calldata = encode_splice(cid, &params, &raw, &proof, &consent.exits);
    let ok = estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, cfg.gas_limit).await?;
    if !ok {
        // A concurrent splice may have raced us in; re-read and treat the
        // already-applied total as success (idempotent), else surface the revert.
        let rpc = rpc.clone();
        let state =
            tokio::task::spawn_blocking(move || read_channel_state(&*rpc, btc_channels, cid))
                .await
                .context("post-revert read join")??;
        if state.amount_sats == new_total {
            info!(cid = %hex::encode(cid), "splice reverted but total already updated (raced); ok");
            return Ok(());
        }
        anyhow::bail!(
            "splice reverted for {splice_txid}:{splice_vout} (cid {})",
            hex::encode(cid)
        );
    }
    info!(
        cid = %hex::encode(cid), %splice_txid,
        new_total = params.amount_sats, "spliced channel on EVM"
    );
    // (§E233-ladder) The ladder is armed on-chain now, so drop the relayed copy — `consent` holds only
    // IN-FLIGHT consent, the same lifecycle bound `drive_open` keeps with `clear_inflight`.
    registry.clear_inflight(&splice_txid.to_string(), splice_vout);
    Ok(())
}

/// Consume channel-lifecycle events and mirror them on the EVM. Both arms run on
/// their own task so a long confirmation-wait / lpAuth round-trip can't
/// head-of-line block other events.
///
/// `Ready` → [`drive_open`] (`openChannel`, with the LP's lpAuth over the custom
/// LN message); `Closed` → [`drive_close`] (`recordClose`).
/// The hop reads the funding pubkeys from its own monitor
/// ([`channel_funding_pubkeys`]) so the open is correct-by-construction.
#[allow(clippy::too_many_arguments)]
pub async fn run_channel_driver<R: JsonRpc + Send + Sync + 'static>(
    cfg: BridgeConfig,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    vault_registry: Arc<crate::vault::VaultRegistry>,
    mut rx: mpsc::UnboundedReceiver<ChannelLifecycleEvent>,
    // L-1: the SHARED in-flight set (keyed by on-chain cid), also held by
    // `run_channel_reconciler`. A drive is skipped if a drive for that cid is
    // already running on EITHER path, so the event-driven drive and a reconciler
    // drive can't run concurrently for the same channel (idempotent but wastes a
    // reverting tx + nonce-lock pressure). A skipped drive still eventually runs:
    // the reconciler retries it next pass.
    active: Arc<Mutex<HashSet<[u8; 32]>>>,
    // P0: durable backstop for the splice CID map below. The in-memory map is the
    // hot path; this store persists every learned mapping so a splice whose open
    // `Ready` fired in a PRIOR run can still be mirrored after a restart.
    store: Arc<BridgeStore>,
) {
    let cfg = Arc::new(cfg);
    // LDK channel_id → the STABLE on-chain channelId (keyed on the ORIGINAL funding
    // outpoint), recorded on `Ready`. A later `Spliced`/`Closed` carries only the
    // LDK channel id + the new outpoint, so it recovers the on-chain id here.
    // RESTART-DURABLE: seeded from the store on boot and written through to the
    // store on `Ready`, so a splice whose open `Ready` fired in a PRIOR run is still
    // mapped after a restart (the in-memory map stays the hot path; the store is the
    // durable backstop). Pruned on close.
    let onchain_cid: Arc<Mutex<HashMap<[u8; 32], [u8; 32]>>> =
        Arc::new(Mutex::new(store.load_onchain_cids()));
    while let Some(ev) = rx.recv().await {
        match ev {
            ChannelLifecycleEvent::Ready {
                channel_id,
                counterparty_node_pk: _, // (B) lpAuth transport retired; open is delegation-gated on-chain
                funding_txid,
                funding_vout,
            } => {
                // Record LDK channel_id → on-chain channelId for a future splice
                // (the on-chain id is keyed on this ORIGINAL funding outpoint).
                let oc = channel_funding_pubkeys(
                    &chain_monitor, &channel_manager, funding_txid, funding_vout,
                )
                .map(|(pa, pb)| {
                    let (k0, k1) = sort_funding_pubkeys(pa, pb);
                    quid_hop::evm_codec::channel_id(
                        &k0,
                        &k1,
                        txid_internal(&funding_txid),
                        funding_vout,
                    )
                });
                // L-1: claim the in-flight slot (RAII — released on the drive
                // task's completion OR panic-unwind). Skip if a drive for this cid
                // is already in flight on either path (reconciler or a prior event).
                // The reconciler retries next pass, so a skip is never a dropped open.
                let slot = if let Some(oc) = oc {
                    onchain_cid.lock().expect("onchain_cid poisoned").insert(channel_id, oc);
                    // P0: persist the mapping durably so a splice/close whose open
                    // `Ready` fired in this run can still be mirrored after a crash
                    // (idempotent — re-recording the same pair is a no-op).
                    store.record_onchain_cid(channel_id, oc);
                    match ActiveSlot::claim(&active, oc) {
                        Some(s) => Some(s),
                        None => {
                            debug!(cid = %hex::encode(oc), "open: drive already in flight — skip");
                            continue;
                        }
                    }
                } else {
                    None
                };
                let cfg = cfg.clone();
                let evm = evm.clone();
                let rpc = rpc.clone();
                let esplora = esplora.clone();
                let chain_monitor = chain_monitor.clone();
                let channel_manager = channel_manager.clone();
                let registry = vault_registry.clone();
                tokio::spawn(async move {
                    // Hold the slot for the whole drive; its Drop frees it on every
                    // exit path (return, error, or panic-unwind).
                    let _slot = slot;
                    if let Err(e) = drive_open(
                        cfg,
                        evm,
                        rpc,
                        esplora,
                        chain_monitor,
                        channel_manager,
                        registry,
                        funding_txid,
                        funding_vout,
                    )
                    .await
                    {
                        error!(cid = %hex::encode(channel_id), "channel open driver failed: {e:#}");
                    }
                });
            }
            ChannelLifecycleEvent::Closed {
                channel_id,
                funding_txid,
                funding_vout,
            } => {
                // Resolve the STABLE on-chain channelId from the open-time map
                // (seeded from the durable store on boot, so a `Ready` from a PRIOR
                // run is still mapped). A SPLICED channel's close spends the rotated
                // outpoint, so the id canNOT be recomputed from the close tx — it
                // stays keyed on the ORIGINAL outpoint. `None` (never opened in this
                // deployment / map never learned it) falls back to recompute inside
                // drive_close: correct for a never-spliced channel; a spliced one is
                // caught by the reconciler (ldk_value vs amountSats).
                let known = onchain_cid.lock().expect("onchain_cid poisoned").get(&channel_id).copied();
                if known.is_none() {
                    warn!(cid = %hex::encode(channel_id),
                        "close: LDK channel not in splice CID map (durable + in-memory both miss); \
                         recomputing id from the close outpoint — correct unless this channel was \
                         spliced (then the reconciler reconciles it)");
                }
                // L-1: when we know the on-chain cid, skip if a drive for it is
                // already in flight on either path. When unknown (Ready in a prior
                // run), drive_close recomputes the cid internally so we can't pre-
                // guard here — but the reconciler (which always knows the cid) still
                // dedups against the same shared set.
                // L-1: claim the in-flight slot (RAII — freed on completion OR
                // panic-unwind). Only guard when there IS a cid to guard; an unknown
                // cid (Ready in a prior run) is recomputed inside drive_close, so we
                // can't pre-guard here — the reconciler (which always knows the cid)
                // still dedups against the same shared set.
                let slot = match known {
                    Some(oc) => match ActiveSlot::claim(&active, oc) {
                        Some(s) => Some(s),
                        None => {
                            debug!(cid = %hex::encode(oc), "close: drive already in flight — skip");
                            continue;
                        }
                    },
                    None => None,
                };
                // When the on-chain cid is unknown (a never-spliced channel whose
                // `Ready` we never mapped), `drive_close` recomputes it from the
                // channel's STORED funding pubkeys — a taproot key-path close has no
                // witnessScript to recover them from. Read them from LDK now (the
                // monitor still exists at close time). `None` lets drive_close error
                // out cleanly rather than parse a (nonexistent) witness.
                let funding_pubkeys = if known.is_none() {
                    channel_funding_pubkeys(&chain_monitor, &channel_manager, funding_txid, funding_vout)
                } else {
                    None
                };
                let cfg = cfg.clone();
                let evm = evm.clone();
                let rpc = rpc.clone();
                let esplora = esplora.clone();
                let store2 = store.clone();
                let onchain_cid2 = onchain_cid.clone();
                tokio::spawn(async move {
                    // Hold the slot for the whole drive; Drop frees it on every exit
                    // path (return, error, or panic-unwind).
                    let _slot = slot;
                    match drive_close(cfg, evm, rpc, esplora, funding_txid, funding_vout, known, funding_pubkeys, None).await
                    {
                        Ok(()) => {
                            // Channel retired on the EVM — prune its now-dead splice
                            // CID mapping from BOTH the in-memory map and the durable
                            // store. Only on SUCCESS, so a transient failure (which
                            // the reconciler retries) doesn't drop the mapping early.
                            onchain_cid2.lock().expect("onchain_cid poisoned").remove(&channel_id);
                            store2.forget_onchain_cid(&channel_id);
                        }
                        Err(e) => {
                            error!(cid = %hex::encode(channel_id), "channel close driver failed: {e:#}");
                        }
                    }
                });
            }
            ChannelLifecycleEvent::Spliced {
                channel_id,
                counterparty_node_pk: _, // (B) lpAuth transport retired; splice is hop-gated on-chain
                new_funding_txid,
                new_funding_vout,
            } => {
                // Recover the STABLE on-chain channelId (keyed on the ORIGINAL
                // outpoint) from the open-time map (seeded from the durable store on
                // boot, so a `Ready` from a PRIOR run is still mapped); the splice
                // rotated LDK's funding_txo to the new outpoint, so the LDK channel
                // id is the only stable handle the event carries.
                let oc = onchain_cid
                    .lock()
                    .expect("onchain_cid poisoned")
                    .get(&channel_id)
                    .copied();
                let Some(oc) = oc else {
                    warn!(
                        cid = %hex::encode(channel_id),
                        "Spliced for a channel whose open mapping is absent from BOTH the durable \
                         store and memory — cannot map to its on-chain channelId here; the \
                         reconciler will catch it up (ldk_value vs on-chain amountSats)"
                    );
                    continue;
                };
                // L-1: claim the in-flight slot (RAII — freed on completion OR
                // panic-unwind). Skip if a drive for this cid is already in flight
                // (either path).
                let slot = match ActiveSlot::claim(&active, oc) {
                    Some(s) => s,
                    None => {
                        debug!(cid = %hex::encode(oc), "splice: drive already in flight — skip");
                        continue;
                    }
                };
                let cfg = cfg.clone();
                let evm = evm.clone();
                let rpc = rpc.clone();
                let esplora = esplora.clone();
                let chain_monitor = chain_monitor.clone();
                let channel_manager = channel_manager.clone();
                // (§E233-ladder) The splice now carries the LP's fresh exit ladder, read from the same
                // registry the open path reads — keyed on the ROTATED outpoint.
                let registry = vault_registry.clone();
                tokio::spawn(async move {
                    // Hold the slot for the whole drive; Drop frees it on every exit
                    // path (return, error, or panic-unwind).
                    let _slot = slot;
                    if let Err(e) = drive_splice(
                        cfg,
                        evm,
                        rpc,
                        esplora,
                        chain_monitor,
                        channel_manager,
                        oc,
                        new_funding_txid,
                        new_funding_vout,
                        registry,
                    )
                    .await
                    {
                        error!(cid = %hex::encode(oc), "channel splice driver failed: {e:#}");
                    }
                });
            }
        }
    }
    warn!("channel driver: lifecycle stream ended");
}

/// Hop-side BTC-leg **fee flush**: when a channel is caught up (nothing to
/// mirror) and has accrued `Vault.btcFeesOwedSats` worth splicing, initiate a
/// HOP-FUNDED splice-in of exactly the owed sats. `requestDeposit` (in the splice
/// mirror) then grows the LP's `POOLED` by that delta — the fees COMPOUND into the
/// position. This is the fleet doing the keeping for every channel it serves;
/// nothing runs LP-side.
///
/// ⛔ **THERE IS NO KEYSEND, AND THIS DOCBLOCK USED TO SAY THERE WAS.** It read
/// "[`drive_splice`] keysends the same sats hop→LP and clears the owed ledger", which
/// contradicted line ~893 of this same file — *"under B the LP has no LN node — the old
/// keysend is obsolete"* — and that line is the correct one. **No
/// `send_spontaneous_payment` call exists anywhere in `quid-bridge`, `quid-hop` or
/// `quid-ln`;** the only `Spontaneous` symbols in the tree are LDK's INBOUND types for
/// RECEIVING one. The keysend belonged to the pre-§E145 settlement design, and §E145
/// deleted "the owed ledger and everything that existed to settle it" — the prose simply
/// outlived the code, as `fee_settle_sats` did until §E191 struck it out below.
///
/// 🔑 **SO NOTHING IS PAID OUT: the LP's SHARE COUNT grows and the value is realised at
/// resize or close** (`BtcLib.feeCompounded` → `Vault.sol:543`,
/// `lpSharesBTC += feeCompounded`). An LP needs no node, no action and no notification to
/// receive fees, which is the whole point under B — and it is why a keysend, which would
/// require the LP to be online to receive, could never have been the mechanism here.
///
/// Rate limit is structural, not a timer: at most ONE splice per channel is
/// outstanding (`no_pending_splice`), and once it locks the mirror settles the
/// owed so the next pass sees nothing to flush. The economic-grow floor
/// ([`MIN_ECONOMIC_GROW_SATS`]) batches small fees so the on-chain funding fee
/// never dominates. All bounds are physics/economics; a blocked-but-needed flush
/// is `warn!`ed loudly (fund the hop wallet / raise the cap), never a silent no-op.
#[allow(clippy::too_many_arguments)]
async fn maybe_flush_btc_fees<R: JsonRpc + Send + Sync + 'static>(
    cfg: &Arc<BridgeConfig>,
    rpc: &Arc<R>,
    esplora: &Arc<Esplora>,
    channel_manager: &Arc<HopChannelManager>,
    hop_wallet: &Option<OnchainWallet>,
    rebalance: &Option<RebalanceConfig>,
    active: &Arc<Mutex<HashSet<[u8; 32]>>>,
    cid: [u8; 32],
    ch_id: lightning::ln::types::ChannelId,
    cp: PublicKey,
    state: &ChannelState,
    usable: bool,
    no_pending_splice: bool,
    spent: bool,
) {
    // Enabled only when the fleet is doing the keeping (hop wallet + config present).
    let (Some(wallet), Some(rb)) = (hop_wallet.as_ref(), rebalance.as_ref()) else {
        return;
    };
    // Only a live, open, unspent channel with no splice already in flight.
    if spent || !usable || !no_pending_splice || state.status != STATUS_OPEN {
        return;
    }

    // Accrued BTC-leg fees owed to THIS channel's LP.
    let vault = cfg.btc_vault;
    let lp = state.lp_eth;
    let mut arg = [0u8; 32];
    arg[12..].copy_from_slice(lp.as_slice());
    // (E145/E191) THERE IS NO OWED LEDGER ANY MORE, so nothing is ever pending a flush.
    // `974b6d8` made the BTC fee leg COMPOUND INTO THE POSITION in sats; `a67e2d8` deleted the
    // owed ledger "and everything that existed to settle it"; `5e16492` deleted `feeSettleSats`.
    // This function used to read `btcFeesOwedSats(address)` — a selector no contract implements
    // since then, so the call ALWAYS failed and fell through `_ => return, // read blip → try
    // again next pass`. ⚠️ THAT COMMENT WAS THE BUG: it dressed a PERMANENT failure as a
    // TRANSIENT one, so a path that had not run since E191 looked healthy in every log.
    //
    // The path is DELIBERATELY KEPT rather than deleted. Routing fees do not reach it today —
    // they are never observed upstream (no `PaymentForwarded` handling anywhere in the tree) —
    // but if routing revenue is ever credited, THIS is its natural landing site: the
    // economic-grow floor and the funding-cap bound below are exactly what such a path needs and
    // are already written and reviewed. Deleting them would make "unobserved by design or by
    // omission?" more expensive to answer, and that question is still open.
    let owed: u64 = 0;
    // `rpc` and `vault` are RETAINED, not stale: they are precisely what a repointed read of
    // compounded sats would need, and dropping them from the signature is the edit that would
    // make reinstating this path expensive.
    let _ = (&rpc, &vault);
    // Batch small fees: only splice once the owed clears the economic-grow floor.
    if owed < MIN_ECONOMIC_GROW_SATS {
        return;
    }
    // Hard bound: the grow must fit under the channel funding cap.
    if state.amount_sats.saturating_add(owed as u128) > CHANNEL_MAX_FUNDING_SATS as u128 {
        warn!(
            cid = %hex::encode(cid), owed, amount_sats = state.amount_sats,
            cap = CHANNEL_MAX_FUNDING_SATS,
            "fee-flush: owed BTC-leg fees can't be spliced in — channel at the funding cap; \
             raise CHANNEL_MAX_FUNDING_SATS or the fees settle at close via the mirror"
        );
        return;
    }
    // Hard bound: the hop wallet must fund the grow above its force-close reserve.
    let confirmed = wallet.get_balance().confirmed.to_sat();
    let spendable = confirmed.saturating_sub(rb.wallet_reserve_sats);
    if spendable < owed {
        warn!(
            cid = %hex::encode(cid), owed, confirmed,
            wallet_reserve_sats = rb.wallet_reserve_sats,
            "fee-flush: hop wallet can't fund the fee splice above the force-close reserve — \
             FUND THE HOP WALLET (fees keep accruing safely until then)"
        );
        return;
    }

    // Claim the in-flight slot so neither the event path nor the next pass races a
    // second splice for this channel; held only across the (quick) broadcast.
    let _slot = match ActiveSlot::claim(active, cid) {
        Some(s) => s,
        None => return, // a drive is already in flight for this cid
    };
    info!(cid = %hex::encode(cid), owed, "fee-flush: splicing accrued BTC-leg fees into the channel");
    if let Err(e) = initiate_splice(
        channel_manager,
        wallet,
        esplora,
        &ch_id,
        &cp,
        owed,
        SPLICE_FUNDING_FEERATE_SAT_PER_KW,
    )
    .await
    {
        // Not fatal: the fees stay owed and the next pass retries (one attempt per
        // pass — no retry storm). The mirror still settles them on any later splice.
        warn!(cid = %hex::encode(cid), owed, "fee-flush: initiate_splice failed: {e:#}");
    }
}

/// Boot + periodic reconciler — the restart/failure safety net for the
/// event-driven drivers.
///
/// Lifecycle events arrive on an in-memory channel, so a crash between an event
/// and its EVM tx (or a transient submit failure) could otherwise strand a
/// channel. This re-derives the needed work from the AUTHORITATIVE sources —
/// LDK's monitor set (each monitor's funding outpoint + 2-of-2 pubkeys +
/// counterparty), esplora (is the funding spent → closed?), and the on-chain
/// `channels()` state — and reuses the idempotent [`drive_open`]/[`drive_close`].
/// There is NO local journal to desync: the chain and LDK ARE the state. Each
/// pass only acts on channels not already in their target on-chain state, so
/// steady-state cost is one `channels()` read + one esplora call per channel.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub async fn run_channel_reconciler<R: JsonRpc + Send + Sync + 'static>(
    cfg: BridgeConfig,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    vault_registry: Arc<crate::vault::VaultRegistry>,
    // the hop's on-chain wallet + rebalance config. When `Some`, this same
    // per-channel pass ALSO flushes each channel's accrued BTC-leg fees
    // (`Vault.btcFeesOwedSats`) INTO the position via a HOP-FUNDED splice-in — the
    // fleet/hop does the keeping for every channel it serves (a self-hosting
    // family-plan LP runs this same daemon), so nothing runs LP-side. `None` =
    // mirror-only (fees not flushed; e.g. tests / a read-only reconciler).
    hop_wallet: Option<quid_ln::wallet::OnchainWallet>,
    rebalance: Option<quid_hop::rebalancer::RebalanceConfig>,
    // (§LP-LIVENESS) The routing gate, if this deployment collects LP heartbeats. This pass
    // already resolves every channel's on-chain `cid` AND its `lpEth`, which is exactly the pair
    // the gate needs to map LDK's channel id to the one the heartbeat signs — so binding here
    // costs one call and keeps the map as fresh as the reconciler itself.
    // `None` = no gate: `invoicer` is then ungated and every channel keeps its route hint.
    gate: Option<Arc<quid_hop::liveness::RoutingGate>>,
    period_secs: u64,
    // The SHARED in-flight set (keyed by on-chain cid), also held by
    // `run_channel_driver`. Tracks channels with a drive ALREADY in flight on
    // EITHER path, so a slow drive (e.g. a lagging gateway in
    // wait_for_gateway_height) isn't re-spawned on every pass, AND the
    // reconciler never races the event path for the same channel. The drive is
    // idempotent; the in-flight slot frees on completion.
    active: Arc<Mutex<HashSet<[u8; 32]>>>,
) {
    let cfg = Arc::new(cfg);
    let btc_channels = cfg.btc_channels;
    loop {
        // Per-pass snapshot of each LDK channel's CURRENT value (post-splice =
        // grown). Compared against the on-chain `amountSats` to detect a splice the
        // EVM mirror hasn't caught up to (the durable backstop for a splice whose
        // live `Spliced` drive was missed, e.g. across a restart).
        // (value, is_usable) per channel — value drives the mirror-catch-up compare;
        // is_usable gates the hop-funded fee-splice (only a live channel).
        // (§LP-LIVENESS) Feed the gate the tip it measures staleness against. **Without this the
        // gate cannot be switched on at all**: the tip defaults to 0, every heartbeat looks like it
        // came from the future, `is_routable` answers false for every channel, and the only safe
        // deployment is the `None` this parameter has always been passed. `bind` was wired and this
        // was not, which is why the book could be filled and never read usefully.
        //
        // 🔑 THE TIP IS THE **GATEWAY'S**, NOT THE HOP'S OWN VIEW OF BITCOIN, AND THAT IS THE POINT.
        // Staleness decides whether an LP earns fees, so the hop must not be the sole author of the
        // number it is judged against. `getMainchainHeight()` is the height the CONTRACT believes,
        // advanced by SPV-proven headers anyone can submit — so a hop that wants to starve an LP of
        // routing cannot do it by claiming a tip the chain does not have. It can still simply
        // decline to route, which the gate has never claimed to prevent.
        //
        // A failed read leaves the previous tip in place rather than zeroing it: an RPC blip must
        // not mark every LP stale.
        if let Some(g) = gate.as_ref() {
            let rpc_tip = rpc.clone();
            let gw = cfg.spv_gateway;
            if let Ok(Ok(h)) =
                tokio::task::spawn_blocking(move || read_gateway_height(&*rpc_tip, gw)).await
            {
                // The gateway counts Bitcoin blocks, so `u32` is the right width for the next
                // ~80,000 years; saturate rather than wrap on a nonsense read.
                g.set_tip(u32::try_from(h).unwrap_or(u32::MAX));
            }
        }
        let ldk_state: HashMap<[u8; 32], (u64, bool)> = channel_manager
            .list_channels()
            .into_iter()
            .map(|c| (c.channel_id.0, (c.channel_value_satoshis, c.is_usable)))
            .collect();
        for ch_id in chain_monitor.list_monitors() {
            // Read everything off the monitor synchronously and DROP its lock
            // guard (not `Send`) before any `.await`.
            let extracted = match chain_monitor.get_monitor(ch_id) {
                Ok(m) => {
                    // CURRENT outpoint (rotates to the post-splice funding once a
                    // splice locks) — used for the spent-check + as the splice/close
                    // tx location. ORIGINAL outpoint (stable across splices) — used
                    // to key the on-chain channelId. Keying the id on the CURRENT
                    // outpoint would mis-key a spliced channel: it would read
                    // "not opened", drive a PHANTOM second openChannel, and miss the
                    // channel's close.
                    let txo = m.get_funding_txo();
                    let orig = m.original_funding_txo();
                    let cp = m.get_counterparty_node_id();
                    // Pending (renegotiated) splice funding txids. A splice tx that
                    // has CONFIRMED but not yet LOCKED has its NEW funding scope here
                    // while `get_funding_txo()` still returns the OLD (now-spent)
                    // outpoint (LDK rotates only at SpliceLocked / confirmation
                    // depth). The new outpoint's txid IS the splice tx — used below to
                    // avoid misreading that spend as a channel close.
                    let pending_splice_txids: Vec<bitcoin::Txid> =
                        m.pending_funding_txos().into_iter().map(|op| op.txid).collect();
                    // `funding_pubkeys` is None until counterparty params are set.
                    m.funding_pubkeys().map(|(h, c)| {
                        let (k0, k1) = sort_funding_pubkeys(h.serialize(), c.serialize());
                        let cid =
                            channel_id(&k0, &k1, txid_internal(&orig.txid), orig.index as u32);
                        (txo.txid, txo.index as u32, cp, cid, pending_splice_txids)
                    })
                }
                Err(_) => None,
            };
            let Some((funding_txid, funding_vout, cp, cid, pending_splice_txids)) = extracted
            else {
                continue;
            };
            let (ldk_value, ldk_usable) = ldk_state.get(&ch_id.0).copied().unwrap_or((0, false));

            // On-chain state (authoritative idempotency) — skip if already in the
            // target state.
            let state = {
                let rpc = rpc.clone();
                match tokio::task::spawn_blocking(move || {
                    read_channel_state(&*rpc, btc_channels, cid)
                })
                .await
                {
                    Ok(Ok(s)) => s,
                    _ => continue, // RPC blip → try again next pass
                }
            };
            // (§LP-LIVENESS) Bind this channel for the routing gate. Idempotent, and done on every
            // pass so a re-keyed or re-read `lpEth` cannot leave the gate pointing at a stale
            // signer. Until a channel is bound the gate treats it as unroutable, so this is what
            // lets an LP be routed at all — the gate fails closed by design.
            if let Some(g) = gate.as_ref() {
                g.bind(ch_id.0, alloy_primitives::B256::from(cid), state.lp_eth);
            }
            // (§LAZY-OPEN-RETRY) Complete a claim the open had to defer. `openChannel` credits the
            // LP inline whenever the basket is healthy and only books `pendingClaimSats` when the
            // claim leg itself reverted, so this is normally a single cheap read that finds zero.
            //
            // ⚠️ **THE RETRY BELONGS HERE AND NOT IN `drive_open`**, which is why the open path
            // deliberately does not call it: at open time the basket is by definition the thing
            // that just refused, so retrying in the same breath retries into the same failure. This
            // pass runs on a period, so it naturally waits for the condition to clear.
            // ⚠️ Not a liveness dependency: the claim is PERMISSIONLESS, so an LP whose fleet is
            // down is not stuck — it, or any observer, can send the same call. This only means
            // nobody has to.
            match tokio::task::spawn_blocking({
                let rpc = rpc.clone();
                move || read_pending_claim(&*rpc, btc_channels, cid)
            })
            .await
            {
                Ok(Ok(pending)) if pending > 0 => {
                    let calldata = quid_hop::evm_codec::encode_register_channel_claim(cid);
                    match estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, cfg.gas_limit).await {
                        Ok(true) => info!(
                            cid = %hex::encode(cid), pending,
                            "completed a deferred LP pool claim"
                        ),
                        // Still unhealthy, or someone beat us to it. Either way the next pass
                        // re-reads and decides again from chain state, so nothing accumulates.
                        Ok(false) => debug!(cid = %hex::encode(cid), "deferred claim still not creditable"),
                        Err(e) => warn!(cid = %hex::encode(cid), err = %e, "deferred claim retry failed to send"),
                    }
                }
                Ok(Ok(_)) => {}                 // zero: the common case, credited inline at open
                Ok(Err(e)) => debug!(cid = %hex::encode(cid), err = %e, "pendingClaimSats read failed"),
                Err(e) => debug!(cid = %hex::encode(cid), err = %e, "pendingClaimSats join failed"),
            }
            // Is the funding output already spent (channel closed on Bitcoin)?
            // Capture the FULL outspend so we can hand the close txid to
            // drive_close below (it would otherwise re-poll esplora for the same
            // spend we just observed).
            let outspend = esplora
                .client()
                .get_output_status(&funding_txid, funding_vout as u64)
                .await
                .ok()
                .flatten();
            let spent = matches!(&outspend, Some(os) if os.spent);
            let close_txid = outspend.and_then(|os| if os.spent { os.txid } else { None });

            // G-1: classify the spend — a BOLT #3 COMMITMENT (force-close) tx routes
            // to the PERMISSIONLESS retire (recordForceClosePermissionless), anything
            // else to the participant-gated recordClose. Only fetch the spending tx
            // when the channel is actually spent-while-open AND not a pending splice
            // (so steady state stays one channels() read + one outspend call). On a
            // fetch blip default to `false` (treat as a non-commitment close): the
            // participant-gated recordClose can still retire a force close when the
            // bridge IS a participant (the hop's signer), so we never strand the
            // channel — and the next pass re-classifies. is_commitment_tx mirrors the
            // exact on-chain discriminator.
            let close_is_commitment = if spent
                && state.status == STATUS_OPEN
                && !close_txid.is_some_and(|t| pending_splice_txids.contains(&t))
            {
                match close_txid {
                    Some(t) => match esplora.client().get_tx(&t).await {
                        Ok(Some(tx)) => is_commitment_tx(&tx),
                        _ => false, // fetch blip → default to recordClose, retry next pass
                    },
                    None => false,
                }
            } else {
                false
            };

            let action = match select_reconcile_action(
                spent,
                close_txid,
                close_is_commitment,
                state.status,
                state.amount_sats,
                ldk_value,
                &pending_splice_txids,
            ) {
                Some(a) => a,
                // Nothing to MIRROR — the channel is caught up. This is exactly when
                // the hop flushes any accrued BTC-leg fees INTO the position via
                // a hop-funded splice-in, so the fees compound instead of being paid
                // out by a separate settler. Gated on: fee-flush enabled (fleet does
                // the keeping), channel OPEN + live + no splice already pending (the
                // natural rate limit — reuses the monitor's pending set, no cooldown
                // timer), and the owed amount clearing the economic-grow floor so the
                // funding fee can't dominate. The splice mirror then grows the LP's POOLED
                // by the delta, so the fees COMPOUND into the position and settle at
                // resize/close. (This said drive_splice "keysends it hop→LP and clears the
                // ledger" — no keysend exists; see the docblock on maybe_flush_btc_fees.)
                None => {
                    maybe_flush_btc_fees(
                        &cfg, &rpc, &esplora, &channel_manager, &hop_wallet, &rebalance,
                        &active, cid, ch_id, cp, &state, ldk_usable,
                        pending_splice_txids.is_empty(), spent,
                    )
                    .await;
                    continue;
                }
            };

            // Skip if a drive for this channel is already running (e.g. it's
            // still blocked in wait_for_gateway_height). `claim` returns None if
            // already present → don't re-spawn. RAII — the slot frees on the drive
            // task's completion OR panic-unwind, so a panicking drive can't leak the
            // cid (which would skip this channel forever on both paths).
            let slot = match ActiveSlot::claim(&active, cid) {
                Some(s) => s,
                None => continue,
            };

            let cfg2 = cfg.clone();
            let evm2 = evm.clone();
            let rpc2 = rpc.clone();
            let esp2 = esplora.clone();
            let chm2 = chain_monitor.clone();
            let cm2 = channel_manager.clone();
            let reg2 = vault_registry.clone();
            tokio::spawn(async move {
                // Hold the slot for the whole drive; Drop frees it on every exit
                // path (return, error, or panic-unwind).
                let _slot = slot;
                let r = match action {
                    ReconcileAction::Open => {
                        drive_open(
                            cfg2, evm2, rpc2, esp2, chm2, cm2, reg2, funding_txid,
                            funding_vout,
                        )
                        .await
                    }
                    // `cid` is keyed on the ORIGINAL outpoint (stable across a
                    // splice), so a spliced channel's close/grow mirrors the correct
                    // on-chain record. `funding_txid/vout` is the CURRENT
                    // (post-splice) outpoint — the close tx spends it, and it IS the
                    // splice outpoint drive_splice needs.
                    ReconcileAction::Close => {
                        // The reconciler always knows the stable cid, so no
                        // witness-free pubkey recovery is needed (funding_pubkeys=None).
                        drive_close(cfg2, evm2, rpc2, esp2, funding_txid, funding_vout, Some(cid), None, close_txid)
                            .await
                    }
                    // G-1: a force-close commitment tx the EVM hasn't recorded → the
                    // PERMISSIONLESS retire. `close_txid` is the spend we observed
                    // above (Some, since spent-while-open got us here). `cid` is the
                    // stable original-outpoint id (correct across splices).
                    ReconcileAction::ForceClose => match close_txid {
                        Some(t) => drive_force_close(cfg2, evm2, rpc2, esp2, cid, t).await,
                        // Defensive: ForceClose is only chosen when close_txid is
                        // Some; if it somehow isn't, do nothing this pass.
                        None => Ok(()),
                    },
                    ReconcileAction::Splice => {
                        // (§E233-ladder) `reg2` is moved here as well as in the Open arm — match arms are
                        // exclusive, so exactly one move happens per pass.
                        drive_splice(
                            cfg2, evm2, rpc2, esp2, chm2, cm2, cid, funding_txid,
                            funding_vout, reg2,
                        )
                        .await
                    }
                };
                if let Err(e) = r {
                    // Best-effort: the next pass retries. Not error-level (the
                    // common cause is "funding not yet deeply confirmed").
                    debug!(cid = %hex::encode(cid), "reconcile drive failed: {e:#}");
                }
                // `_slot` drops here, freeing the in-flight slot so the next pass can
                // re-drive if needed (also runs on a panic-unwind of this task).
            });
        }
        tokio::time::sleep(Duration::from_secs(period_secs.max(60))).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    // ActiveSlot is the RAII in-flight guard. The slot MUST be released on BOTH
    // normal completion AND a panic-unwind of the drive task, otherwise a panicking
    // drive leaks the cid forever (the channel is then skipped by both the event
    // path and the reconciler until a process restart).
    #[test]
    fn active_slot_releases_on_normal_drop() {
        let set: Arc<Mutex<HashSet<[u8; 32]>>> = Arc::new(Mutex::new(HashSet::new()));
        let cid = [7u8; 32];
        {
            let g = ActiveSlot::claim(&set, cid).expect("free slot claims");
            assert!(set.lock().unwrap().contains(&cid), "claimed while held");
            // A second claim for the same cid must fail (skip-if-present preserved).
            assert!(ActiveSlot::claim(&set, cid).is_none(), "double-claim rejected");
            drop(g);
        }
        assert!(set.lock().unwrap().is_empty(), "slot freed on normal drop");
        // After release the cid can be claimed again.
        assert!(ActiveSlot::claim(&set, cid).is_some(), "re-claim after release");
    }

    #[test]
    fn active_slot_releases_on_panic_unwind() {
        let set: Arc<Mutex<HashSet<[u8; 32]>>> = Arc::new(Mutex::new(HashSet::new()));
        let cid = [9u8; 32];
        let set2 = set.clone();
        // Simulate a drive task body that claims the slot and then PANICS. The slot
        // is moved into the closure (mirrors moving it into the spawned task), so its
        // Drop must run during unwinding and remove the cid.
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _slot = ActiveSlot::claim(&set2, cid).expect("free slot claims");
            assert!(set2.lock().unwrap().contains(&cid), "claimed before panic");
            panic!("drive_* panicked mid-flight");
        }));
        assert!(r.is_err(), "closure panicked as intended");
        // The Mutex may now be poisoned by the panic; Drop uses poison-recovery, so
        // verify the slot was removed despite that.
        let freed = set
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty();
        assert!(freed, "slot freed on panic-unwind (no permanent leak)");
    }

    // End-to-end with a real spawned task that panics: join sees the panic, and the
    // slot is freed regardless (proves the production path — `let _slot = slot;` in a
    // `tokio::spawn` body — releases on unwind).
    #[tokio::test]
    async fn active_slot_releases_when_spawned_task_panics() {
        let set: Arc<Mutex<HashSet<[u8; 32]>>> = Arc::new(Mutex::new(HashSet::new()));
        let cid = [3u8; 32];
        let slot = ActiveSlot::claim(&set, cid).expect("free slot claims");
        let handle = tokio::spawn(async move {
            let _slot = slot; // moved in, dropped on unwind
            panic!("drive task panicked");
        });
        let joined = handle.await;
        assert!(joined.is_err(), "spawned task panicked");
        let freed = set
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty();
        assert!(freed, "slot freed after spawned task panic");
    }

    #[test]
    fn classify_by_locktime() {
        assert_eq!(classify_close(0), CloseKind::Cooperative);
        assert_eq!(classify_close(1), CloseKind::Force);
        assert_eq!(classify_close(800_000), CloseKind::Force);
    }

    #[test]
    fn reconcile_action_classification() {
        use bitcoin::hashes::Hash;
        let splice_txid = bitcoin::Txid::from_byte_array([0xAB; 32]);
        let close_txid = bitcoin::Txid::from_byte_array([0xCD; 32]);

        // (1) Funding spent by a NON-splice COOPERATIVE tx while on-chain OPEN →
        // Close (participant-gated recordClose). close_is_commitment=false.
        assert_eq!(
            select_reconcile_action(true, Some(close_txid), false, STATUS_OPEN, 1_000_000, 1_000_000, &[]),
            Some(ReconcileAction::Close),
        );

        // (1b) G-1: funding spent by a BOLT#3 COMMITMENT (force/unilateral) tx →
        // ForceClose (the permissionless recordForceClosePermissionless path).
        assert_eq!(
            select_reconcile_action(true, Some(close_txid), true, STATUS_OPEN, 1_000_000, 1_000_000, &[]),
            Some(ReconcileAction::ForceClose),
        );

        // (2) GUARD: funding spent by the PENDING (confirmed-but-not-locked)
        // SPLICE tx → None. Must NOT be classified as a close, or the reconciler
        // would force-retire a live channel via recordClose on the splice tx.
        assert_eq!(
            select_reconcile_action(
                true,
                Some(splice_txid),
                false,
                STATUS_OPEN,
                1_000_000,
                1_000_000,
                &[splice_txid],
            ),
            None,
        );

        // (2b) A spend by a DIFFERENT tx is still a close even while a splice is
        // pending (a genuine unilateral close racing an in-flight splice).
        assert_eq!(
            select_reconcile_action(
                true,
                Some(close_txid),
                false,
                STATUS_OPEN,
                1_000_000,
                1_000_000,
                &[splice_txid],
            ),
            Some(ReconcileAction::Close),
        );

        // (3) Unspent + never opened on the EVM (amount_sats == 0) → Open.
        assert_eq!(
            select_reconcile_action(false, None, false, STATUS_OPEN, 0, 1_000_000, &[]),
            Some(ReconcileAction::Open),
        );

        // (4) Unspent + OPEN + LDK total != on-chain total → Splice (post-lock
        // catch-up — this is the path the guarded splice eventually takes).
        assert_eq!(
            select_reconcile_action(false, None, false, STATUS_OPEN, 1_000_000, 1_500_000, &[]),
            Some(ReconcileAction::Splice),
        );

        // (5) Unspent + OPEN + totals match → None (already consistent).
        assert_eq!(
            select_reconcile_action(false, None, false, STATUS_OPEN, 1_000_000, 1_000_000, &[]),
            None,
        );
    }

    struct FixedRpc(String);
    impl JsonRpc for FixedRpc {
        fn call(&self, method: &str, _params: Value) -> anyhow::Result<Value> {
            assert_eq!(method, "eth_call");
            Ok(Value::String(self.0.clone()))
        }
    }

    fn word_hex(bytes: &[u8]) -> String {
        let mut w = [0u8; 32];
        w[32 - bytes.len()..].copy_from_slice(bytes);
        hex::encode(w)
    }

    #[test]
    fn parse_channel_state() {
        // 5 words: amountSats=1_000_000, fundingTxId, lpEth, fundingVout=0, status=2.
        let mut ret = String::from("0x");
        ret.push_str(&word_hex(&1_000_000u64.to_be_bytes())); // amountSats
        ret.push_str(&"11".repeat(32)); // fundingTxId
        ret.push_str(&word_hex(&[0xAB; 20])); // lpEth
        ret.push_str(&word_hex(&0u32.to_be_bytes())); // fundingVout
        ret.push_str(&word_hex(&[STATUS_CLOSED])); // status
        let st = read_channel_state(&FixedRpc(ret), Address::ZERO, [0u8; 32]).unwrap();
        assert_eq!(st.amount_sats, 1_000_000);
        assert_eq!(st.status, STATUS_CLOSED);
    }

    #[test]
    fn parse_channel_state_never_opened() {
        // All-zero return ⇒ amountSats 0 ⇒ never opened.
        let ret = format!("0x{}", "00".repeat(160));
        let st = read_channel_state(&FixedRpc(ret), Address::ZERO, [0u8; 32]).unwrap();
        assert_eq!(st.amount_sats, 0);
        assert_eq!(st.status, STATUS_OPEN);
    }

    // gas_limit_for: never under-gas a variable-cost openChannel/recordClose.
    struct GasRpc {
        estimate: Option<u64>, // None ⇒ estimateGas reverts
    }
    impl JsonRpc for GasRpc {
        fn call(&self, method: &str, _p: Value) -> anyhow::Result<Value> {
            assert_eq!(method, "eth_estimateGas");
            match self.estimate {
                Some(g) => Ok(Value::String(format!("0x{g:x}"))),
                None => anyhow::bail!("execution reverted"),
            }
        }
    }

    #[test]
    fn gas_limit_for_covers_estimate_with_headroom() {
        // Estimate above the floor → estimate + 25%, never below the estimate.
        let rpc = GasRpc { estimate: Some(900_000) };
        let g = gas_limit_for(&rpc, Address::ZERO, &[], 400_000);
        assert_eq!(g, 1_125_000, "estimate*1.25");
        assert!(g >= 900_000, "must cover the estimate");

        // Estimate below the floor → floor wins (don't shrink below configured).
        let rpc = GasRpc { estimate: Some(100_000) };
        assert_eq!(gas_limit_for(&rpc, Address::ZERO, &[], 400_000), 400_000);

        // Estimate reverts → fall back to the floor (send_tx surfaces the revert).
        let rpc = GasRpc { estimate: None };
        assert_eq!(gas_limit_for(&rpc, Address::ZERO, &[], 400_000), 400_000);

        // Absurd estimate (lying/buggy RPC) → ignored, use the floor (don't let it
        // inflate gas_limit into an un-includable tx).
        let rpc = GasRpc { estimate: Some(100_000_000) };
        assert_eq!(gas_limit_for(&rpc, Address::ZERO, &[], 400_000), 400_000);
        let rpc = GasRpc { estimate: Some(u64::MAX) };
        assert_eq!(gas_limit_for(&rpc, Address::ZERO, &[], 400_000), 400_000);
    }

    // Fault injection: malformed RPC responses / transport errors must never
    // panic — read_channel_state returns Err, gas_limit_for falls back to floor.
    struct Canned(Value);
    impl JsonRpc for Canned {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            Ok(self.0.clone())
        }
    }
    struct Erroring;
    impl JsonRpc for Erroring {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            anyhow::bail!("rpc down / timeout")
        }
    }

    #[test]
    fn driver_rpc_parse_never_panics() {
        use serde_json::json;
        let z = Address::ZERO;
        let bad = [
            json!(null),
            json!(1),
            json!(true),
            json!({}),
            json!("0x"),
            json!("0xZZ"),
            json!("0x12"), // short for the 160-byte channels() return
            json!(format!("0x{}", "00".repeat(80))), // 80 bytes — still short
        ];
        for v in &bad {
            let rpc = Canned(v.clone());
            let _ = read_channel_state(&rpc, z, [0u8; 32]); // must not panic
            // gas_limit_for must always yield a usable limit (≥ floor), never panic.
            assert!(gas_limit_for(&rpc, z, &[], 400_000) >= 400_000);
        }
        assert!(read_channel_state(&Erroring, z, [0u8; 32]).is_err());
        assert_eq!(gas_limit_for(&Erroring, z, &[], 400_000), 400_000);
    }
}

// ───────────────────────────── property-based fuzz ────────────────────────────
//
// `read_channel_state` + `gas_limit_for` decode UNTRUSTED `eth_call` /
// `eth_estimateGas` returns. They must never panic on garbage: read_channel_state
// returns Err on a short/garbage return; gas_limit_for always yields ≥ floor.
#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::Value;

    fn arb_json() -> impl Strategy<Value = Value> {
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(|n| serde_json::json!(n)),
            "[0-9a-fA-FxX]{0,200}".prop_map(Value::String),
            ".*{0,40}".prop_map(Value::String),
        ]
    }

    struct Canned(Value);
    impl JsonRpc for Canned {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            Ok(self.0.clone())
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        // (P1) Arbitrary eth_call return ⇒ read_channel_state never panics, and
        // gas_limit_for always returns at least the floor.
        #[test]
        fn channel_rpc_decoders_never_panic(ret in arb_json()) {
            let z = Address::ZERO;
            let rpc = Canned(ret);
            let _ = read_channel_state(&rpc, z, [0u8; 32]); // no panic (Ok/Err)
            prop_assert!(gas_limit_for(&rpc, z, &[], 400_000) >= 400_000);
        }

        // (P1b) A clean ≥160-byte return whose amountSats word fits u128 always
        // decodes (no panic); amount_sats is word0 (in-range), status is byte 159.
        // A word0 that OVERFLOWS u128 is now an error (not a silent cap) and is
        // covered by the arbitrary-garbage no-panic test above; here we zero the
        // high 16 bytes of word0 so we exercise the clean-decode path.
        #[test]
        fn channel_state_word_decodes(mut bytes in proptest::collection::vec(any::<u8>(), 160..256)) {
            use alloy_primitives::hex;
            for b in &mut bytes[0..16] { *b = 0; } // keep amountSats within u128
            let rpc = Canned(Value::String(format!("0x{}", hex::encode(&bytes))));
            let st = read_channel_state(&rpc, Address::ZERO, [0u8; 32]).unwrap();
            prop_assert_eq!(st.status, bytes[159]);
            let mut w = [0u8; 16];
            w.copy_from_slice(&bytes[16..32]);
            prop_assert_eq!(st.amount_sats, u128::from_be_bytes(w));
        }
    }
}
