//! (#114) DEAD-MAN EXIT — the fleet heartbeat that pre-signs + emits each vault
//! channel's CLTV-timelocked unilateral-exit tx (`BTCChannels.emitDeadManExit`).
//!
//! This is the daemon plumbing around the audited crypto in
//! [`quid_ln::deadman_exit`]: it NEVER touches key material.
//!
//! ⚠️ **THIS HEADER USED TO SAY "same process = the fleet holds both halves" FLATLY, AND
//! THAT IS NO LONGER TRUE — it describes only the FLEET-HOSTED vault deployment.** Since
//! §E175 the vault is an `Option` and its absence is the security split (see
//! [`run_deadman_exit_heartbeat`]): in the **LP-hosted** deployment the vault node runs on the
//! LP's own always-on box with the LP's own seed, this process has no vault node to pass, and
//! **the heartbeat does not run at all** — exits come from the §E165 ladder the LP pre-signed
//! at open. A stale comment is false evidence; this one was quoted into another repo's spec
//! before it was caught.
//!
//! Per open vault-owned channel, each heartbeat tick it
//! 1. re-derives BOTH funding-half signers (the hop node's + the vault node's) off their OWN
//!    `keys_manager`s — which is only reachable when a vault node IS in this process, i.e. the
//!    fleet-hosted deployment — and arms each with the channel's taproot context (counterparty
//!    funding pubkey + funding value); the funding secret key never leaves either signer;
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

use alloy_primitives::{hex, Address};
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
    // #114: the shard's freshness UTXO, resolved by the CALLER (the async heartbeat) and
    // passed in as a value — this fn is documented pure/sync and must stay that way, so it
    // never reaches into the wallet itself. `None` = pre-rotation channel (today's behaviour).
    freshness: Option<(bitcoin::OutPoint, bitcoin::TxOut)>,
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
        // #114: forwarded from the heartbeat. `Some` binds this exit to the shard's
        // freshness outpoint, so spending that one UTXO invalidates every previously
        // emitted exit at once — which is what stops a matured, superseded exit from
        // force-closing a live channel.
        freshness,
    )
    .ok()?;

    // (E178) `emitDeadManExit` now takes the channel's `OpenParams` + one `ExitArming`
    // instead of four flat arguments. ⚠️ ONLY THE PUBKEYS ARE READ on this path — the
    // contract calls `_requireChannelKeys(channelId, p)` (which hashes lpPubkey‖hopPubkey
    // against the pinned `keysHash`) and recomputes `Q`; the SPV block fields are NOT used,
    // because the funding was already proven at open. They are zeroed here deliberately
    // rather than fabricated, and this comment is the reason they may be.
    //
    // `hop_cp` is the HOP's counterparty = the vault/LP half; `vault_cp` is the VAULT's
    // counterparty = the hop half. Getting these the wrong way round hashes to a different
    // `keysHash` and the contract rejects — which is the correct failure, not a silent one.
    let params = quid_hop::evm_codec::OpenParams {
        funding_block_hash_be: [0u8; 32],
        funding_block_height: 0,
        funding_tx_index: 0,
        lp_pubkey: hop_cp.serialize(),
        hop_pubkey: vault_cp.serialize(),
        amount_sats,
        funding_taproot: quid_hop::funding::taproot_funding_aggregate_xonly(
            &hop_cp.serialize(),
            &vault_cp.serialize(),
        ),
    };
    let exit = quid_hop::evm_codec::ExitArming {
        // The contract OVERWRITES the funding entry with what it already knows, and only
        // the freshness input's entry is honoured — so a single placeholder pair is correct
        // for the base (non-freshness) shape and a wrong value simply fails verification.
        prev_values: vec![0u64],
        prev_scripts: vec![Vec::new()],
        cltv_deadline: cltv.to_consensus_u32() as u64,
        checkpoint_sats: amount_sats,
        signed_exit_tx: raw_tx.clone(),
    };
    let calldata = quid_hop::evm_codec::encode_emit_dead_man_exit(on_chain_cid, &params, &exit);
    Some((calldata, amount_sats))
}

/// The periodic dead-man-exit heartbeat. Spawn once at daemon boot (supervised in the
/// `daemon::run` JoinSet, alongside the other bridge loops). Runs forever; a per-channel
/// failure logs + continues (never tears the daemon down).
#[allow(clippy::too_many_arguments)]
/// ⚠️ (E175) `vault` IS `Option` BECAUSE THAT IS THE WHOLE SECURITY SPLIT.
///
/// This heartbeat is the ONE place the fleet derives BOTH funding halves — it arms the hop
/// signer AND the vault signer in a single process and calls `presign_deadman_exit` with
/// the pair. That is exactly the property that makes a compromised fleet able to spend an
/// LP's channel unilaterally.
///
/// In the **LP-hosted** deployment the vault node runs on the LP's own always-on box with
/// the LP's own seed, so the fleet's process HAS NO VAULT NODE TO PASS — and `None` here is
/// not a configuration choice the fleet can flip, it is the absence of a seed it never had.
/// The heartbeat then does not run at all, and a channel's exits come from the §E165 ladder
/// the LP pre-signed at open. **That is why §E165 and this split land together: remove the
/// heartbeat without the ladder and channels have no escape; keep the heartbeat and the
/// fleet still holds both halves.**
///
/// ⇒ **Do not "fix" a `None` vault by deriving the half locally.** Any code that can
/// reconstruct the vault signer inside the fleet process re-creates the exact capability
/// this removes, and every check in `validating_signer` becomes decoration again.
pub async fn run_deadman_exit_heartbeat(
    hop_keys: Arc<QuidKeysManager>,
    hop_monitors: Arc<HopChainMonitor>,
    vault: Option<Arc<VaultNode>>,
    evm: Arc<DaemonEvm>,
    btc_channels: Address,
    gas_limit: u64,
    interval_secs: u64,
    // #114: the hop's on-chain wallet, source of the shared FRESHNESS UTXO whose spend
    // invalidates every previously emitted exit at once. `Option` because a node without
    // fleet wallet duties still runs the heartbeat (it just emits `None`-bound exits, i.e.
    // exactly today's behaviour). Resolved HERE, in the async task, and passed DOWN as a
    // value — `build_exit_call` is documented pure/sync and must stay that way.
    hop_wallet: Option<quid_ln::wallet::OnchainWallet>,
    // #114: durable home for `shard -> freshness outpoint` (rotates) and
    // `channel -> shard` (stable). Both must survive a restart: losing them would mean
    // re-emitting against an outpoint we no longer recognise.
    store: Arc<crate::store::BridgeStore>,
) {
    use crate::client::eth_call_raw;
    use crate::channel_driver::{estimate_gas_and_send, read_channel_state};

    // (E175) NO VAULT IN THIS PROCESS ⇒ NO HEARTBEAT, AND NOTHING TO FALL BACK ON.
    //
    // This is the LP-hosted deployment: the vault node lives on the LP's own always-on box
    // with the LP's own seed, so the fleet cannot arm a vault signer — not because it
    // declines to, but because the key is not here. Exits for these channels come from the
    // §E165 ladder the LP pre-signed at open.
    //
    // Returning is the CORRECT behaviour and must stay loud: a fleet that silently
    // continued would be a fleet that found some other way to reach the vault half.
    let Some(vault) = vault else {
        info!(
            "dead-man-exit heartbeat: DISABLED — no vault node in this process (E175 \
             LP-hosted split). Exits come from the pre-signed ladder armed at openChannel; \
             the fleet cannot and must not derive the LP funding half here."
        );
        return;
    };
    let interval = Duration::from_secs(interval_secs.max(1));
    // Re-wrap the shared quorum transport as the read handle the blocking readers +
    // `estimate_gas_and_send` expect (`&Arc<DaemonRpc>`).
    let rpc = Arc::new(evm.rpc_handle());
    let secp = bitcoin::secp256k1::Secp256k1::new();
    // Monotonic per-tick refresh counter (nonce legibility; message binding is the
    // actual anti-reuse guard, so this need not be globally unique).
    let mut height_counter: u64 = 0;
    // (#114) Last CLTV we emitted per channel. Emitting EVERY tick would mint a new
    // still-valid exit every tick — each maturing later and each needing invalidating —
    // so we re-emit only as a deadline APPROACHES. In-memory on purpose: losing it to a
    // restart costs one extra refresh round, which is harmless, whereas persisting it
    // would add a durability burden for no safety gain.
    let mut last_cltv: std::collections::HashMap<[u8; 32], u32> = std::collections::HashMap::new();
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

        // ── (#114) Resolve this tick's FRESHNESS UTXO ────────────────────────────
        // Shipping K=1 (one shard). The UTXO is DESIGNATED, not minted: any wallet output
        // can serve as input 1, so we pick one rather than paying to create one. Rotation
        // is therefore just "spend it and designate another" — no bespoke send path, and
        // no standing balance beyond a single small output (which is what keeps a host
        // compromise uninteresting: the wallet holds flow, not a store of value).
        //
        // Self-healing by construction: we re-resolve every tick against the live UTXO
        // set, so if the designated output is ever spent (rotation, or an accidental
        // sweep) the next tick simply designates a fresh one — and the exits bound to the
        // old one are, correctly, already dead.
        const FRESHNESS_SHARD: u32 = 0;
        // Derived from the delta, NOT a second constant: the two can then never drift into
        // `margin >= delta`, which would refresh on every tick.
        const REFRESH_MARGIN_BLOCKS: u32 = DEAD_MAN_DELTA_BLOCKS / 2;

        // Is ANY channel due a refresh this tick? Purely in-memory, so it costs nothing.
        // A channel with no recorded CLTV (new, or post-restart) counts as due.
        let mut any_due = false;
        for ldk_id in vault.node.chain_monitor.list_monitors() {
            if let Some(cid) = vault.on_chain_cid(&ldk_id) {
                let fresh = last_cltv
                    .get(&cid)
                    .is_some_and(|d| d.saturating_sub(tip) > REFRESH_MARGIN_BLOCKS);
                if !fresh {
                    any_due = true;
                    break;
                }
            }
        }
        // Nothing to do: no refresh due ⇒ no emission ⇒ no rotation. This is the common
        // case for an idle fleet and is what keeps the on-chain cost bounded.
        if !any_due {
            continue;
        }

        // ROTATE: we are about to emit a new generation of exits, so bind them to a NEW
        // outpoint and retire the previous one AFTER they are all out (see below).
        let previous = store.freshness_of_shard(FRESHNESS_SHARD, bitcoin::ScriptBuf::new())
            .map(|(outpoint, _)| outpoint);
        let freshness = hop_wallet.as_ref().and_then(|w| {
            let utxos: Vec<_> =
                w.get_utxos().into_iter().filter(|u| u.chain_position.is_confirmed()).collect();
            // Never designate the wallet's ONLY output: it would be reserved away from fee
            // and splice funding, starving the very rotations that keep exits fresh.
            if utxos.len() < 2 {
                return None;
            }
            // Designate the SMALLEST confirmed output OTHER than the one we are retiring:
            // smallest because it is the least useful for funding a splice, so reserving it
            // costs the fee path least; other-than-previous because reusing it would rotate
            // nothing (the old exits would stay valid).
            let pick = utxos
                .iter()
                .filter(|u| Some(u.outpoint) != previous)
                .min_by_key(|u| u.txout.value.to_sat())?;
            store.set_freshness(
                FRESHNESS_SHARD,
                &pick.outpoint.txid,
                pick.outpoint.vout,
                pick.txout.value.to_sat(),
            );
            // Reserve it against ORDINARY spending. Without this a fee-flush or funding tx
            // could select it as an input and silently invalidate every emitted exit — the
            // failure mode has no error path, so the reservation is the only thing that
            // prevents it. Deliberate rotation names the outpoint explicitly and is
            // unaffected.
            w.reserve_outpoint(pick.outpoint);
            info!(
                txid = %pick.outpoint.txid, vout = pick.outpoint.vout,
                sats = pick.txout.value.to_sat(),
                "dead-man-exit: designated + reserved freshness UTXO (spending it invalidates all prior exits)"
            );
            Some((pick.outpoint, pick.txout.clone()))
        });

        // Any emission that does NOT land means at least one LP would be left with no
        // valid exit if we retired the old outpoint now. One failure vetoes the retirement.
        let mut all_emitted = true;

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

            // Skip channels whose current exit is still comfortably in the future — they
            // do not need a new one, and every avoided emission is one less stale exit.
            if last_cltv
                .get(&on_chain_cid)
                .is_some_and(|d| d.saturating_sub(tip) > REFRESH_MARGIN_BLOCKS)
            {
                continue;
            }

            // Derive + arm both halves, pre-sign IN-PLACE, encode calldata (sync;
            // no signer/monitor guard is held across the submit await below).
            let built = build_exit_call(
                // #114: resolved once per tick above. `None` (no wallet, or too few UTXOs
                // to spare one) emits the pre-#114 single-input exit — correct, just
                // without the invalidation property.
                freshness.clone(),
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
                Ok(true) => {
                    // Recorded ONLY on a confirmed send: an unrecorded channel is simply
                    // refreshed again next tick, whereas a wrongly-recorded one would be
                    // skipped until its (never-emitted) deadline lapsed.
                    last_cltv.insert(on_chain_cid, tip + DEAD_MAN_DELTA_BLOCKS);
                    // Assign the channel to this shard on first sight. Stable: never
                    // remapped by a change in shard count, only by a deliberate
                    // consolidation that re-emits first.
                    store.assign_shard(&on_chain_cid, FRESHNESS_SHARD);
                    info!(
                        cid = %hex::encode(on_chain_cid),
                        checkpoint_sats = checkpoint,
                        cltv = tip + DEAD_MAN_DELTA_BLOCKS,
                        "dead-man-exit: emitted fresh CLTV backstop",
                    );
                }
                Ok(false) => {
                    all_emitted = false;
                    warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: emitDeadManExit reverted");
                }
                Err(e) => {
                    all_emitted = false;
                    warn!(cid = %hex::encode(on_chain_cid), "dead-man-exit: submit failed ({e:#})");
                }
            }
        }

        // ── (#114) RETIRE the previous freshness outpoint ────────────────────────
        // 🚨 THIS ORDERING IS THE SAFETY PROPERTY. Every channel has now been re-emitted
        // against the NEW outpoint, so spending the OLD one invalidates exactly the stale
        // generation and nothing else. Doing it before the emissions would leave every LP
        // without a valid exit in the window between.
        //
        // Vetoed by ANY failed emission: better to leave the old generation valid for one
        // more period (a bounded griefing window) than to strip an LP of their backstop
        // entirely (an unbounded loss of recourse). The retry is automatic next tick.
        if let (Some(old), Some(w), true) = (previous, hop_wallet.as_ref(), all_emitted) {
            if freshness.as_ref().is_some_and(|(new, _)| *new != old) {
                match w.spend_outpoint_to_self(old, quid_common::ln::priority::ConfirmationPriority::Normal) {
                    Ok(tx) => match vault.node.esplora.client().broadcast(&tx).await {
                        Ok(()) => {
                            // Retired: it no longer needs protecting, and leaving it
                            // reserved would slowly starve coin selection.
                            w.release_outpoint(&old);
                            info!(
                                retired = %old, txid = %tx.compute_txid(),
                                "dead-man-exit: retired previous freshness UTXO — all superseded exits are now consensus-invalid",
                            );
                        }
                        Err(e) => warn!(retired = %old, "dead-man-exit: retirement broadcast failed ({e:#}); \
                            superseded exits stay valid until the next attempt"),
                    },
                    Err(e) => warn!(retired = %old, "dead-man-exit: could not build retirement tx ({e:#})"),
                }
            }
        }
    }
}

#[cfg(test)]
mod e175_split_tests {
    /// (E175) **THE FLEET MUST NOT BE ABLE TO ARM THE LP FUNDING HALF.**
    ///
    /// The property is enforced by the TYPE SYSTEM, not by a runtime flag a compromised
    /// fleet could flip: `build_exit_call` takes `&VaultNode` by value-reference, so no
    /// vault node means no exit can be constructed at all. What a runtime check *can*
    /// still get wrong is the heartbeat reaching a `vault.` use before its `None` guard —
    /// which would panic or, worse, be "fixed" later by deriving the half locally.
    ///
    /// ⚠️ **STRUCTURAL, AND DELIBERATELY NOT ABLE TO PASS VACUOUSLY.** Constructing a real
    /// heartbeat needs a keys manager, chain monitor and EVM client, so this asserts on
    /// this module's own source. The read is `expect`ed (a failed read must NOT pass), and
    /// each PREMISE is asserted before the property so a rename cannot silently green it.
    #[test]
    fn the_heartbeat_cannot_reach_the_vault_before_its_none_guard() {
        let src = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/deadman_exit.rs"
        ))
        .expect("must be able to read deadman_exit.rs; a failed read must NOT pass");

        // ⚠️ SCOPE THE SEARCH TO THE CODE, NOT THIS TEST. The module reads the very file it
        // lives in, and the assertions below quote the patterns they look for — so an
        // unscoped search matches THIS TEST'S OWN SOURCE and reports a violation that does
        // not exist in the code. (It did exactly that on the first run.) Truncating at the
        // test module makes the test observe only what it is testing.
        let marker = "mod e175_split_tests";
        let src = &src[..src.find(marker).expect("test module marker")];

        // PREMISE 1 — the dependency is optional at all. If this signature is ever changed
        // back to `Arc<VaultNode>`, the fleet co-hosts the vault half again by construction.
        let sig = "vault: Option<Arc<VaultNode>>";
        let at_sig = src.find(sig).unwrap_or_else(|| {
            panic!("PREMISE FAILED: the heartbeat no longer takes an OPTIONAL vault — the \
                   fleet can hold both funding halves again")
        });

        // PREMISE 2 — the guard exists.
        let guard = "let Some(vault) = vault else";
        let at_guard = src[at_sig..].find(guard).map(|i| i + at_sig).unwrap_or_else(|| {
            panic!("PREMISE FAILED: the `None` guard is gone")
        });

        // THE PROPERTY — no use of the vault occurs between the signature and the guard.
        let between = &src[at_sig + sig.len()..at_guard];
        assert!(
            !between.contains("vault."),
            "the heartbeat touches `vault.` BEFORE its None guard — it would panic on the \
             LP-hosted split, and the tempting fix is to derive the LP half in-process, \
             which is exactly the capability E175 removes"
        );

        // THE OTHER HALF OF THE PROPERTY — an exit cannot be BUILT without a vault node.
        //
        // ⚠️ An earlier version of this test compared SOURCE POSITIONS: it asserted the
        // `arm_signer` call appears after the guard. That was wrong and the test caught it
        // — `arm_signer` lives in `build_exit_call`, which is *defined earlier in the file*
        // than the heartbeat. **File order is not reachability.** What actually makes the
        // arming unreachable is the TYPE: `build_exit_call` demands `&VaultNode`, so
        // without one it cannot be called at all, wherever it sits.
        assert!(
            src.contains("    vault: &VaultNode,"),
            "PREMISE FAILED: `build_exit_call` no longer REQUIRES a &VaultNode — if it can \
             be called without one, the fleet can build an exit for a channel whose funding \
             half it should not hold"
        );
        assert!(
            !src.contains("vault: Option<&VaultNode>"),
            "an OPTIONAL vault in `build_exit_call` would mean an exit can be built without \
             the LP half — the exact capability E175 removes"
        );
    }
}
