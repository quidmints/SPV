//! On-chain swap-out (delivery rail B) — the hop driver. This is the ONLY swap-out
//! rail under the proceeds collapse; the Lightning rail (rail A) is deferred to M11
//! (off-chain LN delivery has no on-chain exact-settlement point).
//!
//! Rail B serves a user with only a Bitcoin ADDRESS: the swapper
//! commits USD on the curve via `requestSwapOutOnchain` (emitting
//! `SwapOutRequestedOnchain`), and the hop delivers the BTC ON-CHAIN by driving a
//! swapper-directed splice-out of an LP channel, then settling `deliverSwapOutOnchain`.
//!
//! Flow per request (after the EVM burn-finality gate):
//!   1. SELECT an LP channel with funded ≥ `sats` (its LP delivers + earns the QUI).
//!   2. TRIGGER the LP (`request_swap_out_delivery` over the lpAuth transport): the LP
//!      initiates the SpliceOut paying the swapper, and — once it locks — returns the
//!      delivery lpAuth (over `swapOutDeliverDigest`) + the new params/outpoint.
//!   3. REBUILD the splice params + raw tx + SPV proof from the LP's reported outpoint
//!      (own esplora view) and CROSS-CHECK they equal what the LP signed (never trust
//!      the LP's params blindly — same discipline as `drive_splice`).
//!   4. Confirmation-gate the splice block, then submit `deliverSwapOutOnchain`.
//!   On any failure (no channel / LP declines / timeout / revert) → REVERSE via
//!   `settleSwapIn` (USD back to the swapper in their token), keyed by `swapId` — the
//!   same unhappy path as the LN rail. The on-chain `pendingOnchainSwapOut` obligation
//!   makes a stuck delivery always reversible.
//!
//! NOTE: written to mirror `channel_driver::drive_splice`;
//! the LN/p2p seams (LP-initiated SpliceOut to the swapper, co-sign, lpAuth round-trip)
//! are verified on the regtest harness, exactly as the splice-in seam was.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, Address, B256, U256};
use anyhow::Context as _;
use serde_json::Value;
use tracing::{debug, info, warn};

use quid_hop::evm_codec::{
    build_splice_params, channel_id, encode_deliver_swap_out_onchain, sort_funding_pubkeys,
    txid_internal,
};
use quid_hop::node::{channel_funding_pubkeys, HopChainMonitor, HopChannelManager};
use quid_hop::swap::{
    decode_swap_out_requested_onchain, evm_final, swap_out_requested_onchain_topic,
    OnchainSwapOutRequest,
};

use crate::channel_driver::{gas_limit_for, read_channel_state};
use crate::client::JsonRpcEvmClient;
use crate::config::BridgeConfig;
use crate::evm::{EvmClient, SettleOutcome};
use crate::signer::LocalSigner;
use crate::transport::JsonRpc;
use quid_ln::esplora::Esplora;

/// Decode one `eth_getLogs` JSON log into an [`OnchainSwapOutRequest`].
pub fn parse_swap_out_onchain_log(log: &Value) -> Option<OnchainSwapOutRequest> {
    let (topics, data, block) = crate::eth_logs::log_fields(log)?;
    decode_swap_out_requested_onchain(&topics, &data, block)
}

/// One `eth_getLogs` poll over `[from, latest]` for `SwapOutRequestedOnchain`.
/// Returns the decoded requests + the current EVM tip (for the finality gate).
pub fn poll_swap_out_onchain_logs<R: JsonRpc>(
    rpc: &R,
    cfg: &BridgeConfig,
    from: u64,
) -> anyhow::Result<(Vec<OnchainSwapOutRequest>, u64)> {
    let tip = crate::eth_logs::eth_tip(rpc)?;
    let addr = cfg.btc_channels.to_string();
    let topic0 = format!("0x{}", hex::encode(swap_out_requested_onchain_topic()));
    let logs = crate::eth_logs::get_logs_chunked(rpc, &addr, &topic0, from, tip, cfg.max_log_block_span)?;
    let reqs = logs.iter().filter_map(parse_swap_out_onchain_log).collect();
    Ok((reqs, tip))
}

/// All open LP channels whose on-chain funded total is ≥ `sats` AND whose LP is
/// currently connected (so a splice-out can actually be co-signed). Returns
/// `(channelId, counterparty)` for each, so the caller can TRY the next one if a
/// delivery round-trip fails — only reversing if every candidate fails. Mirrors
/// the reconciler's monitor→cid derivation (keyed on the ORIGINAL funding outpoint).
fn select_delivery_channels<R: JsonRpc>(
    rpc: &R,
    chain_monitor: &HopChainMonitor,
    channel_manager: &HopChannelManager,
    btc_channels: Address,
    sats: u64,
) -> Vec<([u8; 32], bitcoin::secp256k1::PublicKey)> {
    // Only deliver via an LP whose node is currently CONNECTED. A delivery is an
    // interactive splice-out (the LP must co-sign), so an offline LP cannot
    // source it — picking one would just stall until the round-trip times out and
    // the swap reverses. LDK's `list_usable_channels()` is connectivity-aware (the
    // channel is ready AND the peer is connected), so filtering on it routes the
    // hop AROUND offline/maliciously-idle LPs to an online one — closing the
    // capacity-poisoning DoS where an idle well-funded LP would black out swap-outs.
    let online: std::collections::HashSet<bitcoin::secp256k1::PublicKey> =
        channel_manager
            .list_usable_channels()
            .into_iter()
            .map(|c| c.counterparty.node_id)
            .collect();

    // Snapshot (cid, counterparty) per monitor synchronously (the monitor guard is
    // not Send; drop it before any RPC).
    let mut candidates: Vec<([u8; 32], bitcoin::secp256k1::PublicKey)> = Vec::new();
    for ch_id in chain_monitor.list_monitors() {
        if let Ok(m) = chain_monitor.get_monitor(ch_id) {
            let orig = m.original_funding_txo();
            let cp = m.get_counterparty_node_id();
            if let Some((h, c)) = m.funding_pubkeys() {
                let (k0, k1) = sort_funding_pubkeys(h.serialize(), c.serialize());
                let cid = channel_id(&k0, &k1, txid_internal(&orig.txid), orig.index as u32);
                candidates.push((cid, cp));
            }
        }
    }
    // Collect every ONLINE LP's open channel with enough funded sats (read
    // on-chain). Offline LPs are skipped so they can't block delivery; the caller
    // tries each in turn and only reverses if all fail.
    let mut out = Vec::new();
    for (cid, cp) in candidates {
        if !online.contains(&cp) {
            continue;
        }
        if let Ok(state) = read_channel_state(rpc, btc_channels, cid) {
            if state.status == crate::channel_driver::STATUS_OPEN
                && state.amount_sats >= sats as u128
            {
                out.push((cid, cp));
            }
        }
    }
    out
}

/// On-chain resolution state: a swap-out is RESOLVED once it is either DELIVERED
/// (`pendingOnchainSwapOut` cleared → its swapper word is 0) or REVERSED
/// (`swapInUsed[swapId]` set by the reversal's `settleSwapIn`). The driver must NOT
/// (re-)deliver a resolved swap — this is what makes a watcher restart / re-scan
/// idempotent WITHOUT a durable cursor: the on-chain state is the source of truth.
fn swap_out_resolved<R: JsonRpc>(
    rpc: &R,
    btc_channels: Address,
    swap_id: [u8; 32],
    request_block: u64,
) -> anyhow::Result<bool> {
    // pendingOnchainSwapOut(bytes32) → (address swapper, uint96 sats, bytes32 hash);
    // swapper (word 0, low 20 bytes) == 0 ⇒ cleared (the delivery landed).
    // AGREEMENT reads (audit F3): this gate decides whether to SKIP delivery / REVERSE.
    // A first-healthy `"latest"` read let one lying endpoint fake resolved=true (strand
    // the swapper's USD, delivery never fires) or resolved=false after a real delivery
    // (re-drive → a second LP splice-out = LP BTC loss). Both views are read at the SAME
    // buried block so a majority of endpoints must agree.
    let at = crate::client::agreed_read_block(rpc)?;
    // If that buried height predates the request, the obligation didn't exist there yet,
    // so it CANNOT have been resolved — short-circuit false (never false-skip a live
    // delivery). Once the request buries, the agreed read sees the real resolution state.
    if at < request_block {
        return Ok(false);
    }
    let tag = format!("0x{at:x}");
    let pending = crate::client::eth_call_raw_at_block(
        rpc, btc_channels, "pendingOnchainSwapOut(bytes32)", Some(&swap_id), &tag)?;
    let delivered = pending.len() >= 32 && pending[12..32].iter().all(|b| *b == 0);
    if delivered {
        return Ok(true);
    }
    // swapInUsed(bytes32) set ⇒ this swap-out's USD was already returned (reversed),
    // so delivering BTC too would be a double-spend (the contract also guards this).
    Ok(crate::client::eth_call_raw_at_block(
        rpc, btc_channels, "swapInUsed(bytes32)", Some(&swap_id), &tag)?
        .iter()
        .any(|b| *b != 0))
}

/// Drive ONE on-chain swap-out delivery to completion (or reverse it). Mirrors
/// `drive_splice` for the EVM submit + the LP cross-check.
#[allow(clippy::too_many_arguments)]
pub async fn drive_swap_out_onchain<R: JsonRpc + Send + Sync + 'static>(
    cfg: Arc<BridgeConfig>,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    vault: Arc<crate::vault::VaultNode>,
    req: OnchainSwapOutRequest,
) -> anyhow::Result<()> {
    let btc_channels = cfg.btc_channels;
    let swap_id = req.swap_id;
    let request_block = req.request_block;

    // 0. Skip if already resolved on-chain (delivered or reversed) — idempotent
    //    re-scan / restart safety, and never deliver after a reversal.
    let rpc_chk = rpc.clone();
    let resolved = tokio::task::spawn_blocking(move || swap_out_resolved(&*rpc_chk, btc_channels, swap_id, request_block))
        .await
        .context("swap_out_resolved join")??;
    if resolved {
        debug!(swap_id = %hex::encode(swap_id), "on-chain swap-out already resolved; skip");
        return Ok(());
    }

    // 1. Select ALL online channels that can source the delivery; if none, reverse.
    let cm = chain_monitor.clone();
    let chm = channel_manager.clone();
    let rpc_sel = rpc.clone();
    let sats = req.sats;
    let candidates = tokio::task::spawn_blocking(move || {
        select_delivery_channels(&*rpc_sel, &cm, &chm, btc_channels, sats)
    })
    .await
    .context("select_delivery_channels join")?;
    if candidates.is_empty() {
        warn!(swap_id = %hex::encode(swap_id), "no online channel can source the on-chain swap-out; reversing");
        return reverse_swap_out_onchain(&evm, &req).await;
    }

    // 2. (B) Initiate the swapper-directed SpliceOut on the VAULT node (it holds the
    //    LP-side channel keys, co-signed in-process by the hop) and await its lock. Try
    //    each online candidate in turn — reverse only if ALL fail. Retry is safe: each
    //    attempt is BEFORE its splice locks, so no double-deliver. There is NO LP
    //    round-trip and NO per-call lpAuth under B — the fleet splices directly and
    //    submits `deliverSwapOutOnchain` as the channel's hop.
    let timeout = Duration::from_secs((cfg.receipt_poll_secs * cfg.receipt_poll_attempts as u64).max(60));
    let (cid, splice_txid, splice_vout) = 'deliver: {
        for (cid, _lp_node_pk) in candidates {
            match vault
                .deliver_swap_out(cid, sats, req.swapper_script.clone(), timeout)
                .await
            {
                Ok((txid, vout)) => break 'deliver (cid, txid, vout),
                Err(e) => warn!(
                    swap_id = %hex::encode(swap_id), cid = %hex::encode(cid),
                    "vault delivery splice failed ({e:#}); trying next candidate",
                ),
            }
        }
        warn!(swap_id = %hex::encode(swap_id), "all candidate channels failed delivery; reversing");
        return reverse_swap_out_onchain(&evm, &req).await;
    };

    // 3. Rebuild params + raw tx + proof from the LOCKED splice outpoint (own chain
    //    view). We initiated the splice ourselves, so there is no counterparty signature
    //    to cross-check — the contract SPV-verifies the splice and pins the delivered
    //    slice to the swapper's on-chain-proven payment (`sumOutputValuesToScript`).
    let (pa, pb) = channel_funding_pubkeys(&chain_monitor, &channel_manager, splice_txid, splice_vout)
        .ok_or_else(|| anyhow::anyhow!("funding pubkeys not available for delivery splice {splice_txid}:{splice_vout}"))?;
    let (params, raw, proof) =
        build_splice_params(&esplora, &splice_txid, splice_vout, pa, pb).await?;

    // 4. Confirmation-gate the splice block (same as drive_splice), then submit as the hop.
    let need_height = params.funding_block_height + crate::channel_driver::SPV_MIN_CONFIRMATIONS;
    crate::channel_driver::wait_for_gateway_height(&rpc, cfg.spv_gateway, need_height, &cfg)
        .await
        .with_context(|| format!("gateway never reached delivery-block confs for {splice_txid}"))?;

    let calldata =
        encode_deliver_swap_out_onchain(swap_id, cid, &params, &raw, &proof, &req.swapper_script);
    let gas = {
        let rpc2 = rpc.clone();
        let cd = calldata.clone();
        let floor = cfg.gas_limit;
        tokio::task::spawn_blocking(move || gas_limit_for(&*rpc2, btc_channels, &cd, floor))
            .await
            .context("gas estimate join")?
    };
    let ok = {
        let evm = evm.clone();
        tokio::task::spawn_blocking(move || evm.send_tx(btc_channels, calldata, gas))
            .await
            .context("send_tx join")??
    };
    if !ok {
        // The LP has already spliced (BTC en route to the swapper), so we must NOT
        // reverse here. Re-read on-chain: if the delivery actually landed (a race) or
        // the swap is otherwise resolved, ok; else surface for a retry next scan.
        let rpc_chk = rpc.clone();
        let request_block = req.request_block;
        let resolved = tokio::task::spawn_blocking(move || swap_out_resolved(&*rpc_chk, btc_channels, swap_id, request_block))
            .await
            .context("post-revert resolved read join")??;
        if resolved {
            info!(swap_id = %hex::encode(swap_id), "deliverSwapOutOnchain reverted but already resolved on-chain (raced); ok");
            return Ok(());
        }
        anyhow::bail!(
            "deliverSwapOutOnchain reverted for swap {} (cid {})",
            hex::encode(swap_id),
            hex::encode(cid)
        );
    }
    info!(swap_id = %hex::encode(swap_id), splice = %splice_txid, "on-chain swap-out delivered");
    Ok(())
}

/// Reverse an undeliverable on-chain swap-out: `settleSwapIn` returns the swapper's
/// USD (in their token), keyed by `swapId` (the on-chain dedup `swapInUsed` makes it
/// idempotent). Same authority + path as the LN rail's reversal.
async fn reverse_swap_out_onchain<R: JsonRpc + Send + Sync + 'static>(
    evm: &Arc<JsonRpcEvmClient<R, LocalSigner>>,
    req: &OnchainSwapOutRequest,
) -> anyhow::Result<()> {
    let (swapper, sats, token, swap_id) = (req.swapper, req.sats, req.token, req.swap_id);
    let evm = evm.clone();
    // A reversal returns the swapper's OWN committed USD (the freed swap-out reserve), so it
    // must be all-or-nothing: require_full = true → a can't-fully-return reverts to
    // Undeliverable and is retried, never a partial return.
    let outcome = tokio::task::spawn_blocking(move || {
        evm.settle_swap_in(swapper, sats, token, B256::from(swap_id), U256::ZERO, true)
    })
    .await
    .context("reverse settle_swap_in join")??;
    match outcome {
        SettleOutcome::Delivered { .. } | SettleOutcome::AlreadySettled { .. } => {
            info!(swap_id = %hex::encode(req.swap_id), "on-chain swap-out reversed (USD returned)");
            Ok(())
        }
        other => anyhow::bail!("on-chain swap-out reversal did not land: {other:?}"),
    }
}

/// Watch `SwapOutRequestedOnchain` and drive each delivery after burn-finality.
/// Polls `SwapOutRequestedOnchain` → finality-gate → handle → advance cursor.
/// No durable cursor: `drive_swap_out_onchain` skips swaps already resolved on-chain
/// (delivered or reversed), so a restart that re-scans from `start_block` is
/// idempotent — the on-chain state is the source of truth, not a persisted cursor.
#[allow(clippy::too_many_arguments)]
pub async fn run_swap_out_onchain_watcher<R: JsonRpc + Send + Sync + 'static>(
    cfg: BridgeConfig,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    rpc: Arc<R>,
    esplora: Arc<Esplora>,
    chain_monitor: Arc<HopChainMonitor>,
    channel_manager: Arc<HopChannelManager>,
    vault: Arc<crate::vault::VaultNode>,
    // Unified on-chain rail: this one task/timer/esplora-client also services the
    // registered on-chain SWAP-IN deposits each pass (settle-then-claim), so there is no
    // second polling loop. See `swap_in_onchain::drive_swap_in_pass`.
    master: Arc<bitcoin::bip32::Xpriv>,
    swap_in_registry: Arc<crate::swap_in_onchain::SwapInRegistry>,
    swap_in_claim_dest: bitcoin::ScriptBuf,
    start_block: u64,
) {
    info!("on-chain watcher: started (swap-out deliveries + swap-in deposits)");
    let cfg = Arc::new(cfg);
    // Session dedup of handled swapIds (delivered OR reversed) so the maturing-window
    // re-scan doesn't re-drive; `swap_out_resolved` is the durable backstop (it skips
    // anything already settled on-chain, incl. across a restart with no cursor).
    let mut handled: HashMap<[u8; 32], u64> = HashMap::new();
    let mut cursor = start_block;
    loop {
        let rpc2 = rpc.clone();
        let cfg2 = cfg.clone();
        let polled = tokio::task::spawn_blocking(move || {
            poll_swap_out_onchain_logs(&*rpc2, &cfg2, cursor)
        })
        .await;
        match polled {
            Ok(Ok((reqs, tip))) => {
                let mut all_resolved = true;
                for req in reqs {
                    if handled.contains_key(&req.swap_id) {
                        continue;
                    }
                    // Burn-finality gate: the swapper's USD must be final before we
                    // deliver irreversible BTC (same as the LN rail).
                    if !evm_final(req.request_block, tip, cfg.min_confirmations) {
                        all_resolved = false;
                        continue;
                    }
                    let swap_id = req.swap_id;
                    match drive_swap_out_onchain(
                        cfg.clone(), evm.clone(), rpc.clone(), esplora.clone(),
                        chain_monitor.clone(), channel_manager.clone(), vault.clone(), req,
                    )
                    .await
                    {
                        Ok(()) => {
                            handled.insert(swap_id, tip);
                        }
                        Err(e) => {
                            all_resolved = false;
                            warn!(swap_id = %hex::encode(swap_id), "on-chain swap-out drive failed (retry next pass): {e:#}");
                        }
                    }
                }
                if all_resolved {
                    cursor = tip.saturating_sub(cfg.min_confirmations);
                    handled.retain(|_, blk| *blk >= cursor);
                }
            }
            Ok(Err(e)) => warn!(error = %e, "on-chain swap-out watcher: poll error"),
            Err(e) => warn!(error = %e, "on-chain swap-out watcher: poll task join error"),
        }
        // Second rail, same pass: service registered on-chain swap-in deposits
        // (settle-then-claim). Shares this task's timer + esplora client.
        crate::swap_in_onchain::drive_swap_in_pass(
            &cfg, &evm, &esplora, &master, &swap_in_registry, &swap_in_claim_dest,
        )
        .await;
        tokio::time::sleep(Duration::from_secs(cfg.swap_out_poll_secs)).await;
    }
}


