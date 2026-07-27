//! Hop event handler — the swap product core.
//!
//! Minimal `EventHandlerMethods` impl: the hop only needs the payment
//! events (swaps) + basic channel-lifecycle logging, so we do NOT mirror quid's
//! 900-line product dispatch. Network-graph/scorer updates reuse quid-ln's free
//! helpers.
//!
//! Swap-IN (SETTLE-THEN-CLAIM): a seller pays the BTC invoice the hop issued →
//! `PaymentClaimable`. We do NOT take the BTC here. We recover the
//! `(seller, token, min_delivered_usd)` binding from the invoice's
//! `payment_metadata` (echoed into `onion_fields`) and emit a [`ClaimedSwapIn`] —
//! carrying the preimage — on `swap_in_tx`. An injected EVM-sender delivers the
//! USD on-chain via `settleSwapIn` and ONLY THEN claims the BTC (or fails the
//! HTLC, returning the BTC to the seller). Delivering before taking is what makes
//! the floor coherent: an undeliverable swap-in costs the seller nothing,
//! instead of stranding a seller whose BTC we'd already claimed.

use std::{
    future::Future,
    sync::{Arc, Mutex},
};

use alloy_primitives::{Address, U256};
use bitcoin::secp256k1::PublicKey;
use bitcoin::Txid;
use lightning::events::{Event, ReplayEvent};
use tokio::sync::mpsc;
use tracing::{info, warn};

use quid_ln::{
    alias::{NetworkGraphType, ProbabilisticScorerType},
    esplora::FeeEstimates,
    event::{self, EventHandleError, EventId},
    keys_manager::QuidKeysManager,
    test_event::TestEventSender,
    tx_broadcaster::TxBroadcaster,
    traits::QuidPersister,
    wallet::OnchainWallet,
};
use quid_common::ln::channel::LxChannelId;
use quid_async_util::notify_once::NotifyOnce;

use quid_common::api::user::NodePk;

use crate::node::{HopChannelManager, HopPst};

/// Bitcoin-block headroom a swap-in HTLC must retain before the hop will START
/// the EVM settle (settle-then-claim step 0). If `claim_deadline - best_height`
/// is below this, the HTLC is failed back IMMEDIATELY rather than risk delivering
/// USD we can't get the BTC-claim confirmed for before the HTLC times out (H-2).
/// Sized to cover worst-case EVM settle latency + the HTLC-success confirmation
/// budget + a fee-spike/pinning margin. Paired with `issue_swap_in_invoice`'s
/// `SWAP_IN_FINAL_CLTV_DELTA`, which gives a fresh HTLC enough budget to clear it.
pub const SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS: u32 = 72; // ~12h at 10-min blocks

/// COMPILE-TIME coupling invariant between the two halves of the settle-then-claim
/// timelock (T_evm < T_ln):
///   • [`crate::node::SWAP_IN_FINAL_CLTV_DELTA`] is the block budget a FRESH swap-in
///     invoice grants an inbound HTLC (set at invoice issuance);
///   • `SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS` is the budget the hop INSISTS still
///     remain (above tip) before it will deliver USD (the settle gate).
/// A fresh HTLC must be able to PASS that gate with room to spare for the inbound
/// forwarding hop's own CLTV expiry and block-propagation slack — otherwise every
/// swap-in would be failed back the instant it arrives. So the headroom must be
/// STRICTLY less than the granted delta. This assertion fails the build if a future
/// edit to either const breaks the relationship (e.g. raising the headroom past the
/// delta, or shrinking the delta below the headroom). Keep the two in sync via THIS
/// invariant, not by eyeball.
const _: () =
    assert!((SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS as u32) < crate::node::SWAP_IN_FINAL_CLTV_DELTA as u32);

/// The settle-then-claim timelock invariant (T_evm > T_ln): an inbound swap-in
/// HTLC may only be settled (USD delivered) if its claim deadline (CLTV) is at
/// least [`SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS`] above the current tip — else we
/// could deliver USD and then lose the BTC to the HTLC timeout (a timelock /
/// time-dilation manipulation). A missing/at-or-below-tip deadline ⇒ `false`
/// (conservative). `saturating_sub` makes a deadline already past the tip return
/// 0 < threshold ⇒ refuse.
pub fn swap_in_cltv_headroom_ok(claim_deadline: Option<u32>, best_height: u32) -> bool {
    claim_deadline
        .map(|d| d.saturating_sub(best_height) >= SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS)
        .unwrap_or(false)
}

/// The swap-in binding `(seller, token)` rides in the BOLT11 invoice's
/// `payment_metadata` (40 bytes: `seller ‖ token`). The payer echoes it (BOLT11
/// mandates echoing the `m` field), LDK surfaces it in
/// `PaymentClaimed.onion_fields.payment_metadata`, and that event is persisted
/// with the claimable HTLC — so the binding is durable across restarts for free,
/// with NO hop-side map or bespoke persistence. See
/// [`crate::node::HopNode::issue_swap_in_invoice`].
pub fn encode_swap_in_metadata(seller: Address, token: Address, min_delivered_usd: U256) -> Vec<u8> {
    // 72 bytes: seller(20) || token(20) || minDeliveredUsd(32). NOTE (audit LOW-4):
    // BOLT11 payment_metadata is PAYER-CONTROLLED and unauthenticated — the payer can
    // alter these before paying, so this is NOT a hop attestation. It is safe anyway:
    // `sats` is pinned by the invoice amount, and `minDeliveredUsd` is used on-chain
    // ONLY as a revert-FLOOR (settleSwapIn: `require(deliveredUsd >= minDeliveredUsd)`);
    // the credited USD is the contract's own oracle math on `sats`. So a payer raising
    // the floor only self-DoSes (HTLC fails back, BTC returned) and lowering it removes
    // only their own protection — never mints extra USD. (Verified: SwapLib.creditSwapInBody.)
    let mut m = Vec::with_capacity(72);
    m.extend_from_slice(seller.as_slice());
    m.extend_from_slice(token.as_slice());
    m.extend_from_slice(&min_delivered_usd.to_be_bytes::<32>());
    m
}

fn decode_swap_in_metadata(m: &[u8]) -> Option<(Address, Address, U256)> {
    if m.len() != 72 {
        return None;
    }
    Some((
        Address::from_slice(&m[0..20]),
        Address::from_slice(&m[20..40]),
        U256::from_be_slice(&m[40..72]),
    ))
}

/// A claimable swap-in, ready to drive `BTCChannels.settleSwapIn` on the EVM.
///
/// SETTLE-THEN-CLAIM consumer contract (the injected EVM-sender):
///   0. CLTV-HEADROOM GATE (before settling): holding this inbound HTLC while the
///      EVM settle lands is a cross-chain CLTV race — the HTLC's remaining expiry
///      bounds how long settle+claim may take. If there isn't enough headroom to
///      land `settleSwapIn` AND get the HTLC-success CONFIRMED (with margin for an
///      on-chain fee spike / pinning), `fail_htlc_backwards` NOW. Never start a
///      settle you can't claim in time, or you deliver USD and lose the BTC to the
///      HTLC timeout. (The swap-in invoice's `min_final_cltv_expiry` must be sized
///      for worst-case EVM settle latency + this confirmation budget, not the
///      18-block LDK floor.)
///   1. Call `settleSwapIn(seller, sats, token, payment_hash, min_delivered_usd)`.
///   2. On SUCCESS → `channel_manager.claim_funds(PaymentPreimage(preimage))`.
///   3. On REVERT → read `swapInUsed(payment_hash)`:
///        • true  → a prior settle already delivered the USD (e.g. a restart
///                  re-emitted this `PaymentClaimable`): just claim the BTC.
///        • false → genuinely undeliverable (floor unmet / pool dry):
///                  `channel_manager.fail_htlc_backwards(&payment_hash)` so the
///                  seller's node reclaims the BTC. NEVER claim un-settled BTC.
#[derive(Clone, Copy, Debug)]
pub struct ClaimedSwapIn {
    pub seller: Address,
    pub sats: u64,
    pub token: Address,
    pub payment_hash: [u8; 32],
    /// The hop's attested floor (the seller's expected USD, in the
    /// output stable's decimals); the EVM-sender passes it to settleSwapIn.
    pub min_delivered_usd: U256,
    /// The LN preimage (`sha256(preimage) == payment_hash`). The EVM-sender uses
    /// it to `claim_funds` AFTER a successful on-chain settle.
    pub preimage: [u8; 32],
    /// The Bitcoin block height by which the inbound HTLC must be claimed (LDK's
    /// `PaymentClaimable.claim_deadline`). The event handler already enforces the
    /// CLTV-headroom gate at emit (failing back if too tight), but this is carried
    /// for the EVM-sender's observability/logging and any future re-check.
    pub claim_deadline: Option<u32>,
}

/// What is actually sent over `swap_in_tx`: the persistable [`ClaimedSwapIn`]
/// PLUS an out-of-band durable-record ACK channel. The ack lives OUTSIDE
/// `ClaimedSwapIn` deliberately — that struct is serde-projected into
/// [`BridgeStore`] and RECONSTRUCTED on boot, so it must stay a plain data
/// record with no live handles. The event handler holds the LN event (returning
/// `Replay`) until the bridge fires this ack after its FIRST durable write
/// (`add_inflight_swapin`), making the LN-event→bridge handoff exactly-once: a
/// crash before the ack leaves the event persisted and re-delivered. The boot
/// re-drive sends `None` (no event to ack).
pub type SwapInMsg = (ClaimedSwapIn, Option<tokio::sync::oneshot::Sender<()>>);

/// A BTC-channel lifecycle transition the EVM-sender must mirror on-chain.
/// Emitted on `channel_lifecycle_tx`; the bridge's channel driver builds the
/// `openChannel` / `recordClose` / `splice` calldata (via
/// [`crate::evm_codec`]) and submits it. Carries only what LDK readily exposes;
/// the driver derives the rest (raw tx, SPV proof, 2-of-2 pubkeys, `channelId`)
/// from Bitcoin via esplora.
#[derive(Clone, Copy, Debug)]
pub enum ChannelLifecycleEvent {
    /// Funding tx confirmed + channel usable → drive `openChannel`. The driver
    /// fetches the funding tx (`funding_txid:funding_vout`), proves inclusion,
    /// obtains `lpAuth` from `counterparty_node_pk` (the LP) over the custom LN
    /// message, and submits.
    Ready {
        /// LDK channel id (logging / dedup).
        channel_id: [u8; 32],
        /// The LP's LN node key — the peer the driver asks to sign `lpAuth`.
        counterparty_node_pk: PublicKey,
        /// Bitcoin funding outpoint.
        funding_txid: Txid,
        funding_vout: u32,
    },
    /// Channel closed on Bitcoin → drive `recordClose` (the single entrypoint;
    /// it branches on the close tx's locktime: 0 = cooperative, non-zero =
    /// unilateral non-coop). The driver locates the close tx as the spend of
    /// `funding_txid:funding_vout`; the locktime is authoritative (matches the contract).
    Closed {
        channel_id: [u8; 32],
        funding_txid: Txid,
        funding_vout: u32,
    },
    /// A splice (grow OR shrink) of an open channel had its funding tx constructed →
    /// drive `splice` on the EVM once it confirms. Emitted on `Event::SplicePending`
    /// (which carries the new funding outpoint). The LDK `channel_id` is STABLE
    /// across a splice; the bridge maps it to the on-chain BTCChannels channelId
    /// recorded at open, then `drive_splice` confirmation-gates + submits.
    Spliced {
        /// LDK channel id (stable across the splice).
        channel_id: [u8; 32],
        /// The LP's LN node key — the peer the driver asks to sign the splice lpAuth.
        counterparty_node_pk: PublicKey,
        /// The splice tx's NEW funding outpoint.
        new_funding_txid: Txid,
        new_funding_vout: u32,
    },
}

/// Shared context for the hop event handler.
pub struct EventCtx {
    pub channel_manager: Arc<HopChannelManager>,
    pub persister: HopPst,
    pub shutdown: NotifyOnce,
    pub network_graph: Arc<NetworkGraphType>,
    pub scorer: Arc<Mutex<ProbabilisticScorerType>>,
    /// Settled swap-ins are emitted here for the EVM-sender task.
    pub swap_in_tx: mpsc::UnboundedSender<SwapInMsg>,
    /// BTC-channel lifecycle transitions (funding ready / closed) for the
    /// bridge's channel driver to mirror on the EVM (`openChannel` / close).
    pub channel_lifecycle_tx: mpsc::UnboundedSender<ChannelLifecycleEvent>,
    /// The hop's single LP counterparty. Inbound channel opens are accepted ONLY
    /// from this node id: the whole hop design assumes one channel to the
    /// LP, and stranger channels would pollute swap-in route hints + the BTC-leg
    /// P&L accounting and let anyone force monitor/chain-watch churn on the hop.
    pub lsp_node_pk: NodePk,
    /// Anchor CPFP handler — funds commitment/HTLC-claim fee bumps.
    pub bump_handler: Arc<crate::node::HopBumpHandler>,
    // --- Deps needed to REUSE quid-ln's event helpers (not reimplement) --- //
    pub keys_manager: Arc<QuidKeysManager>,
    pub fee_estimates: Arc<FeeEstimates>,
    pub tx_broadcaster: TxBroadcaster,
    pub wallet: OnchainWallet,
    pub test_event_tx: TestEventSender,
}

#[derive(Clone)]
pub struct HopEventHandler {
    pub ctx: Arc<EventCtx>,
}

impl quid_ln::event::EventHandlerMethods for HopEventHandler {
    fn get_ldk_handler_future(
        &self,
        event: Event,
    ) -> impl Future<Output = Result<(), ReplayEvent>> + Send {
        // Replay-prone events (the helpers can return `Replay` on transient
        // broadcast/persist failure) are PERSISTED + spawned so the event
        // replayer retries them — NOT handled inline, where a `Replay` would
        // shut the node down and (without restore) strand force-close funds.
        // Mirrors quid. The rest handle inline.
        async move {
            match &event {
                Event::PaymentClaimable { .. }
                | Event::PaymentClaimed { .. }
                | Event::PaymentSent { .. }
                | Event::PaymentFailed { .. }
                | Event::SpendableOutputs { .. } => {
                    self.persist_and_spawn_handler(event).await
                }
                _ => self.handle_inline(event).await,
            }
        }
    }

    fn handle_event(
        &self,
        event_id: &EventId,
        event: Event,
    ) -> impl Future<Output = Result<(), EventHandleError>> + Send {
        let ctx = self.ctx.clone();
        let event_id = event_id.clone();
        async move { do_handle_event(&ctx, &event_id, event).await }
    }

    fn persister(&self) -> &impl QuidPersister {
        &self.ctx.persister
    }

    fn shutdown(&self) -> &NotifyOnce {
        &self.ctx.shutdown
    }
}

async fn do_handle_event(
    ctx: &Arc<EventCtx>,
    event_id: &EventId,
    event: Event,
) -> Result<(), EventHandleError> {
    event::handle_network_graph_update(&ctx.network_graph, &event);
    event::handle_scorer_update(&ctx.scorer, &event);

    match event {
        // Fund a channel we're opening — reuse quid-ln's helper.
        Event::FundingGenerationReady {
            temporary_channel_id,
            counterparty_node_id,
            channel_value_satoshis,
            output_script,
            ..
        } => {
            event::handle_funding_generation_ready(
                &ctx.wallet,
                &ctx.channel_manager,
                &ctx.test_event_tx,
                temporary_channel_id,
                counterparty_node_id,
                channel_value_satoshis,
                output_script,
            )?;
        }

        // Sweep force-closed funds — CRITICAL (else BTC is stranded). Reuse
        // quid-ln's tested sweeping helper, not a hand-rolled one.
        Event::SpendableOutputs {
            outputs,
            channel_id,
        } => {
            // Mirror quid: SpendableOutputs always carries a channel_id post
            // LDK v0.0.107.
            let channel_id = LxChannelId::from(
                channel_id.expect("SpendableOutputs always carries a channel_id"),
            );
            event::handle_spendable_outputs(
                ctx.channel_manager.clone(),
                ctx.persister.clone(),
                &ctx.fee_estimates,
                &ctx.keys_manager,
                &ctx.test_event_tx,
                &ctx.tx_broadcaster,
                &ctx.wallet,
                None,
                event_id,
                outputs,
                channel_id,
            )
            .await?;
        }
        // Seller paid the invoice. SETTLE-THEN-CLAIM: do NOT take the BTC yet.
        // Recover the binding + preimage and emit for the EVM-sender, which
        // delivers the USD on-chain FIRST, then claims (or fails the HTLC). The
        // `(seller, token, min_delivered_usd)` binding rides in `onion_fields`
        // here exactly as it does in `PaymentClaimed`, so we can gate the claim on
        // deliverability without ever holding un-settled BTC.
        Event::PaymentClaimable {
            payment_hash,
            amount_msat,
            onion_fields,
            purpose,
            claim_deadline,
            ..
        } => {
            let ph = payment_hash.0;
            let sats = amount_msat / 1000;
            let preimage = purpose.preimage().map(|p| p.0);
            let binding = onion_fields
                .as_ref()
                .and_then(|f| f.payment_metadata.as_deref())
                .and_then(decode_swap_in_metadata);
            match (binding, preimage) {
                (Some((seller, token, min_delivered_usd)), Some(preimage)) => {
                    // CLTV-HEADROOM GATE (settle-then-claim step 0, H-2): never
                    // start a settle we can't claim in time. A swap-in with too
                    // little remaining CLTV is failed back NOW — costing the seller
                    // nothing — instead of delivering USD and then losing the BTC
                    // to the HTLC timeout. A missing deadline is treated as
                    // insufficient (conservative): we never run an old quid-hop, so
                    // `claim_deadline` is always populated in practice.
                    let best = ctx.channel_manager.current_best_block().height;
                    let headroom_ok = swap_in_cltv_headroom_ok(claim_deadline, best);
                    if !headroom_ok {
                        warn!(
                            best, ?claim_deadline,
                            "swap-in CLTV headroom < {SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS} blocks; \
                             failing HTLC back (no USD delivered)"
                        );
                        ctx.channel_manager.fail_htlc_backwards(&payment_hash);
                        return Ok(());
                    }
                    let claimed = ClaimedSwapIn {
                        seller,
                        sats,
                        token,
                        payment_hash: ph,
                        min_delivered_usd,
                        preimage,
                        claim_deadline,
                    };
                    // ACK-BASED HANDOFF (durability-F1). We do NOT treat a successful
                    // `send` as "the bridge owns durability" — the mpsc handoff is
                    // not itself durable, and the bridge's first durable write
                    // (`add_inflight_swapin`) only runs LATER when it dequeues. A
                    // crash in that gap would strand the swap-in (no durable record
                    // on either side; no loss, but not exactly-once). So we attach a
                    // oneshot ACK and HOLD this LN event (return Replay) until the
                    // bridge fires it AFTER its first durable write. Awaiting here is
                    // safe: each event runs in its own spawned task, and holding the
                    // LN event longer is ALWAYS safe (the headroom gate above stands;
                    // if the bridge stays down past the deadline LDK fails the HTLC
                    // back automatically — seller reclaims, no loss).
                    let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
                    if ctx.swap_in_tx.send((claimed, Some(ack_tx))).is_err() {
                        // The EVM-sender is down. Do NOT silently drop: returning
                        // Replay keeps THIS event persisted so the quid-ln replayer
                        // re-delivers it while the process stays up. This vendored
                        // LDK does NOT enqueue a fresh PaymentClaimable on reload
                        // (it only reconstructs the claimable HTLC into
                        // `claimable_payments`), so the persisted event is the only
                        // thing that carries this across the receiver being down.
                        warn!("swap-in receiver dropped; HTLC {payment_hash} — will replay");
                        return Err(EventHandleError::Replay(anyhow::anyhow!(
                            "swap-in EVM-sender unavailable; replay {payment_hash}"
                        )));
                    }
                    // WAIT for the bridge's durable-record ack before letting the LN
                    // event be removed. The ack means EITHER the bridge persisted an
                    // in-flight record (`add_inflight_swapin` ran) OR the swap-in was
                    // already handled (dedup) — both mean it's safe to remove the LN
                    // event. If the ack sender is dropped (bridge crashed before its
                    // durable write), we hold the event: return Replay so it survives
                    // and is re-delivered.
                    match ack_rx.await {
                        Ok(()) => {}
                        Err(_) => {
                            warn!(
                                "swap-in not durably recorded by bridge (ack dropped); \
                                 HTLC {payment_hash} — will replay"
                            );
                            return Err(EventHandleError::Replay(anyhow::anyhow!(
                                "swap-in not durably recorded by bridge; replay {payment_hash}"
                            )));
                        }
                    }
                    info!(sats, "swap-in pending → emitted + bridge-acked for settle-then-claim");
                }
                // No binding or no preimage → we cannot settle this payment. Fail
                // the HTLC so the seller's node reclaims the BTC; never claim BTC
                // we have no way to settle the USD side for.
                _ => {
                    warn!(
                        "PaymentClaimable {payment_hash} without swap-in \
                         binding/preimage; failing HTLC"
                    );
                    ctx.channel_manager.fail_htlc_backwards(&payment_hash);
                }
            }
        }

        // The BTC is ours now — but only because the EVM-sender already delivered
        // the USD on-chain and THEN claimed (settle-then-claim, handled at
        // `PaymentClaimable` above). Nothing left to do; re-emitting here would
        // double-drive settleSwapIn (the EVM dedups via swapInUsed, but we don't
        // rely on that).
        Event::PaymentClaimed {
            payment_hash,
            amount_msat,
            ..
        } => {
            info!(
                sats = amount_msat / 1000,
                "swap-in BTC claimed post-settle for {payment_hash}"
            );
        }

        // Anchor channels require manually accepting inbound channels. Accept ONLY
        // from the configured LP: a pure hop has exactly one channel, to its
        // LP. Channels from strangers would leak into swap-in route hints, distort
        // the BTC-leg P&L model, and let anyone force monitor/chain-watch churn.
        Event::OpenChannelRequest {
            temporary_channel_id,
            counterparty_node_id,
            ..
        } => {
            // DoS cap: a pure hop keeps ONE channel to its LP (capacity
            // grows via SPLICE, not new channels), so bound how many the LP can open.
            // Each channel is a persisted, AES-sealed monitor + a chain-watch + an
            // on-chain freshness-anchor slot, so an unbounded open loop from a
            // compromised LP is attacker-driven storage/watch/on-chain-commit growth.
            // A small cap leaves headroom for a close→reopen overlap while bounding it.
            const MAX_LP_CHANNELS: usize = 4;
            let lp_channels = ctx
                .channel_manager
                .list_channels()
                .iter()
                .filter(|c| c.counterparty.node_id == counterparty_node_id)
                .count();
            if counterparty_node_id != ctx.lsp_node_pk.0 {
                warn!(
                    peer = %counterparty_node_id,
                    "rejecting inbound channel from non-LP peer"
                );
                // The channel is only a temporary (pre-funding) request, so there
                // is no commitment tx to broadcast — this just rejects it and tells
                // the peer why.
                let _ = ctx.channel_manager.force_close_broadcasting_latest_txn(
                    &temporary_channel_id,
                    &counterparty_node_id,
                    "inbound channels accepted only from the configured LP".to_string(),
                );
            } else if lp_channels >= MAX_LP_CHANNELS {
                warn!(
                    peer = %counterparty_node_id, count = lp_channels,
                    "rejecting inbound channel: LP already at the channel cap (capacity grows via splice)"
                );
                let _ = ctx.channel_manager.force_close_broadcasting_latest_txn(
                    &temporary_channel_id,
                    &counterparty_node_id,
                    "LP channel cap reached; grow capacity via splice".to_string(),
                );
            } else if let Err(e) = ctx.channel_manager.accept_inbound_channel(
                &temporary_channel_id,
                &counterparty_node_id,
                0,
                None,
            ) {
                warn!("accept_inbound_channel failed: {e:?}");
            }
        }

        // Anchor CPFP — fund the commitment / HTLC-claim fee bump (the
        // replacement-cycling + flood-and-loot defense).
        Event::BumpTransaction(bte) => ctx.bump_handler.handle_event(&bte),

        // Outbound LN payments: a pure hop makes none in the current build (the
        // off-chain LN swap-out rail was removed; USD→BTC delivery is on-chain via
        // splice-out). Log for observability; there is no swap-out result to emit.
        // (M11 re-adds the LN swap-out rail + its PaymentSent/Failed → result routing.)
        Event::PaymentSent { payment_hash, .. } => {
            info!(%payment_hash, "PaymentSent on a pure hop (no LN swap-out rail); ignored");
        }
        Event::PaymentFailed { payment_hash, .. } => {
            warn!(?payment_hash, "PaymentFailed on a pure hop (no LN swap-out rail); ignored");
        }
        // Funding confirmed + channel usable → tell the bridge to register the
        // BTC position on the EVM (openChannel). Needs the funding outpoint; LDK
        // only omits it for 0-conf paths the hop never uses, so skip+warn if absent.
        Event::ChannelReady {
            channel_id,
            counterparty_node_id,
            funding_txo,
            ..
        } => {
            let Some(txo) = funding_txo else {
                warn!(%channel_id, "ChannelReady without funding_txo; cannot drive openChannel");
                return Ok(());
            };
            info!(%channel_id, funding = %txo.txid, "channel ready → emit Open");
            let _ = ctx.channel_lifecycle_tx.send(ChannelLifecycleEvent::Ready {
                channel_id: channel_id.0,
                counterparty_node_pk: counterparty_node_id,
                funding_txid: txo.txid,
                funding_vout: txo.vout,
            });
        }
        Event::ChannelPending { .. } => info!("channel pending"),
        // Channel closed on Bitcoin → tell the bridge to retire the EVM position
        // (recordClose). The driver locates + classifies the
        // close tx itself, so we only need the funding outpoint to find it.
        Event::ChannelClosed {
            channel_id,
            channel_funding_txo,
            reason,
            ..
        } => {
            let Some(txo) = channel_funding_txo else {
                warn!(%channel_id, "ChannelClosed without funding_txo; cannot drive close");
                return Ok(());
            };
            warn!(%channel_id, %reason, "channel closed → emit Close");
            let _ = ctx.channel_lifecycle_tx.send(ChannelLifecycleEvent::Closed {
                channel_id: channel_id.0,
                funding_txid: txo.txid,
                funding_vout: txo.index as u32,
            });
        }
        // Splice/dual-funding interactive tx is ready for our signatures → sign the
        // wallet's CONTRIBUTED inputs and hand the tx back. LDK adds the shared
        // 2-of-2 channel signature separately (commitment / tx_signatures flow); we
        // only sign inputs we own — the splicing ACCEPTOR owns none (vendored LDK
        // sets its contribution to 0), so it's a no-op there; the INITIATOR (the LP,
        // whose sats fund the grow) signs its splice-in input(s). BDK needs each
        // owned input's `witness_utxo` populated, so we set it from the wallet's
        // UTXO set before signing (the event hands us a bare unsigned tx).
        Event::FundingTransactionReadyForSigning {
            channel_id,
            counterparty_node_id,
            unsigned_transaction,
            ..
        } => match ctx.wallet.sign_interactive_funding(unsigned_transaction) {
            Ok(signed) => match ctx.channel_manager.funding_transaction_signed(
                &channel_id,
                &counterparty_node_id,
                signed,
            ) {
                Ok(()) => info!(%channel_id, "co-signed splice funding tx"),
                Err(e) => warn!(%channel_id, "funding_transaction_signed failed: {e:?}"),
            },
            Err(e) => warn!(%channel_id, "splice co-sign failed: {e:#}"),
        },
        // A splice's funding tx was constructed → tell the bridge to mirror it
        // (grow OR shrink) on the EVM (`splice`) once it confirms. Carries the NEW
        // funding outpoint; the driver maps the LDK channel id → the on-chain
        // channelId and confirmation-gates before submitting.
        Event::SplicePending {
            channel_id,
            counterparty_node_id,
            new_funding_txo,
            ..
        } => {
            info!(%channel_id, funding = %new_funding_txo.txid, "splice pending → emit Spliced");
            let _ = ctx.channel_lifecycle_tx.send(ChannelLifecycleEvent::Spliced {
                channel_id: channel_id.0,
                counterparty_node_pk: counterparty_node_id,
                new_funding_txid: new_funding_txo.txid,
                new_funding_vout: new_funding_txo.vout,
            });
        }
        other => info!("unhandled event: {}", core::any::type_name_of_val(&other)),
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{swap_in_cltv_headroom_ok, SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS as MIN};

    // The settle-then-claim timelock invariant (T_evm > T_ln): we only deliver
    // USD when the inbound HTLC has enough CLTV left to claim the BTC in time.
    #[test]
    fn swap_in_cltv_headroom_invariant() {
        let best = 1_000u32;
        // Missing deadline → refuse (conservative).
        assert!(!swap_in_cltv_headroom_ok(None, best));
        // Deadline already past / at the tip → refuse (saturating_sub → 0).
        assert!(!swap_in_cltv_headroom_ok(Some(best), best));
        assert!(!swap_in_cltv_headroom_ok(Some(best - 500), best));
        // Just under the threshold → refuse.
        assert!(!swap_in_cltv_headroom_ok(Some(best + MIN - 1), best));
        // Exactly the threshold → allow.
        assert!(swap_in_cltv_headroom_ok(Some(best + MIN), best));
        // Comfortable headroom → allow.
        assert!(swap_in_cltv_headroom_ok(Some(best + MIN + 1000), best));
        // Never panics across the full range (incl. overflow-prone values).
        for d in [0u32, 1, best, u32::MAX, u32::MAX - 1] {
            let _ = swap_in_cltv_headroom_ok(Some(d), best);
        }
        // Sanity: the invariant is monotone in the deadline.
        assert!(swap_in_cltv_headroom_ok(Some(best + MIN), best));
        assert!(!swap_in_cltv_headroom_ok(Some(best + MIN - 1), best));
    }
}
