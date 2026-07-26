//! (#114) DEAD-MAN EXIT — the fleet heartbeat that pre-signs + emits each vault
//! channel's CLTV-timelocked unilateral-exit tx (`BTCChannels.emitDeadManExit`).
//!
//! This is the daemon plumbing around the audited crypto in
//! [`quid_ln::deadman_exit`]: it NEVER touches key material. Per open vault-owned
//! channel, each heartbeat tick it
//! 1. re-derives BOTH funding-half signers (the hop node's + the vault node's,
//!    same process = "the fleet holds both halves") off their OWN `keys_manager`s
//!    and arms each with the channel's taproot context (counterparty funding pubkey
//!    + funding value) — the funding secret key never leaves either signer;
//! 2. reads the on-chain `channels()` record (funded `amountSats` = the LP's
//!    custody balance) + the LP's committed `btcRecipientOf` payout key;
//! 3. calls [`quid_ln::deadman_exit::presign_deadman_exit`] to produce the FULLY-
//!    signed exit tx with `nLockTime = tip + DEAD_MAN_DELTA_BLOCKS` (always future
//!    while the fleet is alive ⇒ NOT broadcastable ⇒ no griefing);
//! 4. submits `emitDeadManExit(channelId, cltvDeadline, checkpointSats, signedExitTx)`.
//!
//! A freshly-opened or freshly-spliced channel is picked up on the next tick (the
//! loop re-enumerates every open channel), so the periodic task IS the open/splice
//! hook — the same poll-based coverage the vault open-orchestrator uses. Fleet
//! vanishes ⇒ heartbeat stops ⇒ the last emission's CLTV matures ⇒ ANYONE broadcasts
//! the already-public bytes (see [`crate::recovery_broadcast`]). No LP action, no key.
//!
//! ## FLAGS (money-path fork per docs §N — fork-verify on the big box, don't merge blind)
//! * **Splice scope: WIRED (2026-07-24).** We now read the CURRENT funding scope's
//!   `splice_parent_funding_txid` from the monitor (`ChannelMonitor::splice_parent_funding_txid`,
//!   the SAME `self.funding.channel_parameters` scope as `get_funding_txo`) and arm both
//!   signers with it — so a spliced channel derives the ROTATED holder key + `Q'` that match
//!   the on-chain funding the exit spends, and gets a live backstop like a base channel. A
//!   never-spliced channel reads `None` (base scope), unchanged. Still fork-verify the
//!   spliced-channel exit end-to-end on the big box (no regtest broadcast locally).
//! * **Fee / feerate:** a fixed [`DEAD_MAN_FEE_SATS`] is deducted. Because the exit
//!   is re-signed every heartbeat, a live feerate could be substituted; the fixed
//!   value is a conservative placeholder. Flagged.
//! * **`DEAD_MAN_DELTA_BLOCKS`:** the broadcast delay Δ after fleet death is a policy
//!   parameter (LP-recovery latency vs. heartbeat-lag griefing margin). Tune on hw.

use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, Address, U256};
use lightning::sign::SignerProvider;
use tracing::{info, warn};

use quid_hop::node::HopChainMonitor;
use quid_ln::keys_manager::QuidKeysManager;
use quid_ln::validating_signer::{TaprootSignerContext, ValidatingChannelSigner};

use crate::daemon::DaemonEvm;
use crate::vault::VaultNode;

/// Absolute-CLTV lead the heartbeat sets on each emission (`nLockTime = tip + Δ`).
/// While the fleet re-emits every [`DEFAULT_HEARTBEAT_SECS`] this stays in the future
/// ⇒ the exit is never broadcastable; once the fleet dies it is the delay before the
/// last exit matures. ~1 day of blocks. POLICY PARAMETER — tune on hardware.
pub const DEAD_MAN_DELTA_BLOCKS: u32 = 144;

/// Fixed miner fee deducted from the checkpoint balance for the exit tx. Placeholder
/// (the exit is re-signed each heartbeat, so a live feerate could replace this).
pub const DEAD_MAN_FEE_SATS: u64 = 2_000;

/// Default heartbeat cadence. MUST be « `DEAD_MAN_DELTA_BLOCKS`×~600s so the CLTV
/// stays comfortably future between emissions.
pub const DEFAULT_HEARTBEAT_SECS: u64 = 300;

const STATUS_OPEN: u8 = 0;

/// Derive + arm one funding-half signer for a channel. Returns a fresh
/// [`ValidatingChannelSigner`] whose taproot context is bound to `counterparty_pk`
/// (the OTHER half's funding pubkey, from THIS node's monitor) + `funding_value_sat`.
/// The funding secret key stays inside the signer (in-place signing only).
fn arm_signer(
    keys: &QuidKeysManager,
    channel_keys_id: [u8; 32],
    counterparty_pk: bitcoin::secp256k1::PublicKey,
    funding_value_sat: u64,
    splice_parent_funding_txid: Option<bitcoin::Txid>,
) -> ValidatingChannelSigner {
    let signer = keys.derive_taproot_channel_signer(channel_keys_id);
    signer.provide_taproot_context(TaprootSignerContext {
        counterparty_funding_pubkey: counterparty_pk,
        funding_value_sat,
        // Dead-man exit is OUTSIDE the cooperative-close flow — no close nonce/round.
        counterparty_closing_nonce: None,
        closing_round: 0,
        // #114 splice-scope: the CURRENT funding scope's splice parent (from the monitor;
        // `None` = base/never-spliced), so `taproot_holder_funding_key`/`taproot_key_agg`
        // derive the ROTATED key + `Q'` that match the on-chain funding the exit spends.
        splice_parent_funding_txid,
    });
    signer
}

/// Build the fully-signed exit tx + `emitDeadManExit` calldata for one channel, given
/// its on-chain record. Pure/sync (no I/O, no `.await`): derives + arms both signers,
/// pre-signs in-place, and encodes. Returns `(calldata, checkpoint_sats)` or `None` if
/// a monitor is missing / counterparty params aren't populated / arithmetic underflows.
#[allow(clippy::too_many_arguments)]
fn build_exit_call(
    hop_keys: &QuidKeysManager,
    hop_monitors: &HopChainMonitor,
    vault: &VaultNode,
    ldk_id: lightning::ln::types::ChannelId,
    on_chain_cid: [u8; 32],
    amount_sats: u64,
    recipient_xonly: [u8; 32],
    tip_height: u32,
    height_counter: u64,
    secp: &bitcoin::secp256k1::Secp256k1<bitcoin::secp256k1::All>,
) -> Option<(Vec<u8>, u64)> {
    // Both nodes' monitors for the SAME channel (LDK channel_id is funding-derived, so
    // it is identical on both sides). Each yields ITS OWN funding-half's keys.
    let vault_mon = vault.node.chain_monitor.get_monitor(ldk_id).ok()?;
    let hop_mon = hop_monitors.get_monitor(ldk_id).ok()?;

    // The current funding UTXO the exit spends (worth amount_sats) + each half's
    // channel_keys_id + the counterparty funding pubkey (`.1`) from its own scope.
    // `get_funding_txo()` is LDK's `lightning::chain::transaction::OutPoint`; convert
    // to `bitcoin::OutPoint` (txid + vout) for the rust-bitcoin exit builder.
    let ldk_txo = vault_mon.get_funding_txo();
    let funding_txo = bitcoin::OutPoint::new(ldk_txo.txid, ldk_txo.index as u32);
    let (_vault_holder, vault_cp) = vault_mon.funding_pubkeys()?;
    let (_hop_holder, hop_cp) = hop_mon.funding_pubkeys()?;
    let vault_ckid = vault_mon.channel_keys_id();
    let hop_ckid = hop_mon.channel_keys_id();
    // #114 splice-scope: the parent of the CURRENT funding (same scope as `get_funding_txo`
    // above; `None` for a base/never-spliced channel). Both halves share the channel's funding
    // scope, so one read arms both — a spliced channel now signs the ROTATED key → valid on Q'.
    let splice_parent = vault_mon.splice_parent_funding_txid();

    // Arm both halves (funding key never exported).
    let vault_signer = arm_signer(&vault.node.keys_manager, vault_ckid, vault_cp, amount_sats, splice_parent);
    let hop_signer = arm_signer(hop_keys, hop_ckid, hop_cp, amount_sats, splice_parent);

    // Absolute CLTV dead-man deadline = tip + Δ (always future while alive).
    let cltv = bitcoin::absolute::LockTime::from_height(tip_height + DEAD_MAN_DELTA_BLOCKS).ok()?;
    let recipient = bitcoin::key::XOnlyPublicKey::from_slice(&recipient_xonly).ok()?;

    // Drop the monitor guards before signing (they hold a read lock; keep the crypto
    // section lock-free and short). funding_txo/keys/pubkeys are all owned copies now.
    drop(vault_mon);
    drop(hop_mon);

    let raw_tx = quid_ln::deadman_exit::presign_deadman_exit(
        &hop_signer,
        &vault_signer,
        funding_txo,
        amount_sats,
        DEAD_MAN_FEE_SATS,
        recipient,
        cltv,
        height_counter,
        secp,
    )
    .ok()?;

    let calldata = quid_hop::evm_codec::encode_emit_dead_man_exit(
        on_chain_cid,
        cltv.to_consensus_u32() as u64,
        U256::from(amount_sats),
        &raw_tx,
    );
    Some((calldata, amount_sats))
}

/// The periodic dead-man-exit heartbeat. Spawn once at daemon boot (supervised in the
/// `daemon::run` JoinSet, alongside the other bridge loops). Runs forever; a per-channel
/// failure logs + continues (never tears the daemon down).
#[allow(clippy::too_many_arguments)]
pub async fn run_deadman_exit_heartbeat(
    hop_keys: Arc<QuidKeysManager>,
    hop_monitors: Arc<HopChainMonitor>,
    vault: Arc<VaultNode>,
    evm: Arc<DaemonEvm>,
    btc_channels: Address,
    gas_limit: u64,
    interval_secs: u64,
) {
    use crate::client::eth_call_raw;
    use crate::channel_driver::{estimate_gas_and_send, read_channel_state};

    let interval = Duration::from_secs(interval_secs.max(1));
    // Re-wrap the shared quorum transport as the read handle the blocking readers +
    // `estimate_gas_and_send` expect (`&Arc<DaemonRpc>`).
    let rpc = Arc::new(evm.rpc_handle());
    let secp = bitcoin::secp256k1::Secp256k1::new();
    // Monotonic per-tick refresh counter (nonce legibility; message binding is the
    // actual anti-reuse guard, so this need not be globally unique).
    let mut height_counter: u64 = 0;
    info!(interval_secs = interval_secs.max(1), delta_blocks = DEAD_MAN_DELTA_BLOCKS,
        "dead-man-exit heartbeat: started");

    loop {
        tokio::time::sleep(interval).await;
        height_counter = height_counter.wrapping_add(1);

        let tip = match vault.node.esplora.client().get_height().await {
            Ok(h) => h,
            Err(e) => {
                warn!("dead-man-exit: esplora height failed ({e:#}); retry next pass");
                continue;
            }
        };

        for ldk_id in vault.node.chain_monitor.list_monitors() {
            // Stable on-chain channelId (keyed on the ORIGINAL funding outpoint).
            let on_chain_cid = match vault.on_chain_cid(&ldk_id) {
                Some(c) => c,
                None => continue, // counterparty params not populated yet
            };

            // Read the on-chain record: only OPEN channels get an exit; `amountSats`
            // is the funded custody balance (= funding UTXO value = checkpoint).
            let (amount_sats, lp_eth) = {
                let rpc2 = rpc.clone();
                match tokio::task::spawn_blocking(move || {
                    read_channel_state(&*rpc2, btc_channels, on_chain_cid)
                })
                .await
                {
                    Ok(Ok(st)) if st.status == STATUS_OPEN => (st.amount_sats, st.lp_eth),
                    Ok(Ok(_)) => continue, // not open (closed / unknown)
                    Ok(Err(e)) => {
                        warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: channels() read failed ({e:#})");
                        continue;
                    }
                    Err(e) => {
                        warn!("dead-man-exit: read join failed ({e:#})");
                        continue;
                    }
                }
            };
            let amount_sats = match u64::try_from(amount_sats) {
                Ok(v) if v > DEAD_MAN_FEE_SATS => v,
                _ => continue, // dust / overflow — nothing safe to back
            };

            // The LP's committed `btcRecipientOf` x-only payout key (source of truth).
            let recipient_xonly: [u8; 32] = {
                let mut arg = [0u8; 32];
                arg[12..].copy_from_slice(lp_eth.as_slice());
                let rpc2 = rpc.clone();
                match tokio::task::spawn_blocking(move || {
                    eth_call_raw(&*rpc2, btc_channels, "btcRecipientOf(address)", Some(&arg))
                })
                .await
                {
                    Ok(Ok(word)) => match word.as_slice().try_into() {
                        Ok(k) => k,
                        Err(_) => continue,
                    },
                    _ => continue,
                }
            };
            if recipient_xonly == [0u8; 32] {
                continue; // no committed payout key ⇒ nothing to back
            }

            // Derive + arm both halves, pre-sign IN-PLACE, encode calldata (sync;
            // no signer/monitor guard is held across the submit await below).
            let built = build_exit_call(
                &hop_keys,
                &hop_monitors,
                &vault,
                ldk_id,
                on_chain_cid,
                amount_sats,
                recipient_xonly,
                tip,
                height_counter,
                &secp,
            );
            let (calldata, checkpoint) = match built {
                Some(x) => x,
                None => {
                    warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: presign skipped (monitor/params/splice-scope)");
                    continue;
                }
            };

            match estimate_gas_and_send(&evm, &rpc, btc_channels, calldata, gas_limit).await {
                Ok(true) => info!(
                    cid = %hex::encode(on_chain_cid),
                    checkpoint_sats = checkpoint,
                    cltv = tip + DEAD_MAN_DELTA_BLOCKS,
                    "dead-man-exit: emitted fresh CLTV backstop",
                ),
                Ok(false) => warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: emitDeadManExit reverted"),
                Err(e) => warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: submit failed ({e:#})"),
            }
        }
    }
}
