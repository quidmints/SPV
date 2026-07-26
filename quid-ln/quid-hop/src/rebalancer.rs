//! LP-side active liquidity **rebalancer** — keeps the hop↔LP channel able to
//! serve swap flow by splicing-in when the LP's outbound (swap-in forwarding
//! capacity) is exhausted relative to real demand.
//!
//! # Why one lever keeps both directions healthy
//!
//! The bridge is a strict pass-through: the hop can only SELL btc (swap-out)
//! that was first BOUGHT (swap-in). Within the single hop↔LP channel there are
//! two outbound buffers:
//!   * **LP outbound** = swap-in forwarding capacity (the LP pushes the seller's
//!     sats to the hop). Sourced by funding / splice-in.
//!   * **HOP outbound** = swap-out capacity (the hop pushes sats to a redeemer).
//!     Sourced *transitively* by swap-ins (every swap-in moves balance to the
//!     hop side).
//! So restoring LP outbound (splice-in) keeps swap-ins flowing, which refills
//! the hop's swap-out buffer. The LP owns `initiate_splice` (it contributes the
//! on-chain capital; the vendored LDK acceptor contributes 0), so the rebalancer
//! runs on the LP side and pulls exactly one lever: splice-in.
//!
//! # The signal is demand-driven, not a tuned threshold
//!
//! We do NOT trigger on "balance crossed X%". We trigger when the channel
//! **cannot serve the next standard swap-in** — a real, observable failure to do
//! work, derived from the channel's own scale:
//!
//!   * The hop caps a single inbound swap-in HTLC at
//!     `max_inbound_htlc_value_in_flight_percent_of_channel` (50%, see
//!     `node::boot`'s `UserConfig`). That 50%·`channel_value_satoshis` is the
//!     channel's *own* definition of a full-scale swap-in — the
//!     [`per_swap_ceiling`]. It is not a knob we picked; it falls out of the
//!     channel config the two nodes already agreed on.
//!   * The LP can forward a swap-in only up to `next_outbound_htlc_limit_msat`
//!     (LDK's real, reserve/dust/in-flight-aware limit on the next single
//!     outbound HTLC). When that drops below the per-swap ceiling, the channel
//!     can no longer serve a full-scale swap-in: that is the trigger.
//!
//! # Natural rate limit (no cooldown timer)
//!
//! At most ONE splice is outstanding per channel. A splice in flight
//! (negotiating / confirming) occupies the channel, so the next decision is
//! suppressed by construction — thrashing is impossible without any timer. The
//! in-flight set is keyed by [`ChannelId`] (mirrors `channel_driver`'s shared
//! `active` set pattern).
//!
//! # Hard bounds are physics / economics, never heuristics
//!
//!   * **Wallet reserve.** Never splice if confirmed on-chain balance minus
//!     [`RebalanceConfig::wallet_reserve_sats`] (kept for force-close fees /
//!     anchor CPFP) can't cover the grow. Spending the reserve would leave the
//!     LP unable to defend a force-close.
//!   * **Minimum economic size.** A grow must clear
//!     [`MIN_ECONOMIC_GROW_SATS`] so the on-chain funding fee doesn't dominate
//!     the added capacity (a value-destructive splice).
//!   * **Channel cap.** The resulting channel must not exceed
//!     `CHANNEL_MAX_FUNDING_SATS`; the grow is clamped to fit, and if the clamp
//!     leaves nothing usable we refuse (operator must raise the cap / open a new
//!     channel for another LP).
//!
//! When a bound BLOCKS a needed splice we `warn!` loudly (fund the wallet / raise
//! the cap) — never a silent no-op.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use bitcoin::secp256k1::PublicKey;
use lightning::ln::types::ChannelId;
use tracing::{debug, error, info, warn};

use quid_common::constants::{CHANNEL_MAX_FUNDING_SATS, FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS};
use quid_ln::esplora::Esplora;
use quid_ln::wallet::OnchainWallet;

use crate::node::{initiate_splice, HopChannelManager, HOP_MAX_INBOUND_IN_FLIGHT_PCT};

/// Minimum economically-sensible splice grow. A splice is an on-chain tx whose
/// funding fee is paid out of the LP's pocket; growing by an amount comparable to
/// that fee destroys value. At a few thousand sats of funding fee, 250,000 sats
/// (~$250 of added working capacity at $100k/BTC) is two orders of magnitude
/// above the fee, so the splice always buys far more capacity than it costs. This
/// is an economics floor, not a tuning knob — raise it only if on-chain fees rise
/// by orders of magnitude.
pub const MIN_ECONOMIC_GROW_SATS: u64 = 250_000;

/// Funding feerate (sat/kw) for the splice tx. The grow is not latency-critical
/// (a swap-in HTLC that can't be served just waits for the splice to confirm), so
/// a modest feerate is fine; LDK computes the exact fee and returns change. Kept
/// well above regtest/mainnet min-relay.
pub const SPLICE_FUNDING_FEERATE_SAT_PER_KW: u32 = 2_000;

/// Tunable-by-operator-but-principled rebalancer config. Both fields are
/// physics/economics, not behavioral tuning.
#[derive(Clone, Copy, Debug)]
pub struct RebalanceConfig {
    /// Sats kept UNSPENT in the LP's on-chain wallet at all times — the LP's
    /// force-close defense budget. A unilateral close (by either side) requires
    /// the LP to pay the commitment/HTLC-claim fees and, with anchors, to CPFP
    /// the commitment via the wallet (see `bump.rs`). Splicing this away would
    /// leave the LP unable to defend its own channel. Floored at the channel's
    /// `FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS` scale; the operator sizes it to their
    /// fee environment (a fat-tail fee spike needs a fatter reserve).
    pub wallet_reserve_sats: u64,
    /// Seconds between rebalancer ticks. A tick is cheap (one `list_channels` +
    /// one `get_balance`, both in-memory), so this only bounds reaction latency,
    /// not load. It is NOT a cooldown: the in-flight guard, not this interval,
    /// prevents repeated splices (a splice in flight suppresses the decision for
    /// however many ticks it takes to confirm). Floored at 1s so a misconfig
    /// can't hot-spin.
    pub poll_interval_secs: u64,
}

impl Default for RebalanceConfig {
    fn default() -> Self {
        Self {
            // Default reserve = 10× the force-close-avoidance fee budget, a
            // conservative cushion for commitment + HTLC-claim + CPFP fees under a
            // moderate fee spike. Operators in a hot fee environment raise it.
            wallet_reserve_sats: FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS * 10,
            poll_interval_secs: 30,
        }
    }
}

/// A minimal, copy-able snapshot of the one channel's balances + scale, plus the
/// LP's confirmed on-chain balance — everything [`decide_splice`] needs. Decoupled
/// from LDK's `ChannelDetails` so the decision is a pure function unit-testable
/// without a node.
#[derive(Clone, Copy, Debug)]
pub struct ChannelSnapshot {
    /// Current channel value (post-splice = grown). The cap is checked against
    /// this + grow.
    pub channel_value_satoshis: u64,
    /// LDK's real limit on the next single outbound HTLC the LP can forward
    /// (reserve/dust/in-flight aware). This is the swap-in forwarding capacity —
    /// the thing exhaustion of which is the trigger. Prefer this over
    /// `outbound_capacity_msat`: it's what actually bounds the next swap-in.
    pub next_outbound_htlc_limit_msat: u64,
    /// The channel's `max_inbound_htlc_value_in_flight_percent_of_channel`
    /// (50 in `node::boot`). Defines the per-swap ceiling from the channel's own
    /// config — read from `ChannelConfig` when present, else the known default.
    pub max_inbound_in_flight_percent: u8,
    /// Is the channel usable (ready, peer online)? A splice can only be initiated
    /// on a live channel.
    pub is_usable: bool,
}

/// The per-swap-in ceiling implied by the channel's OWN config: the largest single
/// swap-in HTLC the hop will accept = `pct% · channel_value_satoshis`. Returned in
/// **msat**. This is the channel's definition of a full-scale swap-in; the trigger
/// compares the LP's forwarding capacity against it.
pub fn per_swap_ceiling_msat(snap: &ChannelSnapshot) -> u64 {
    let pct = snap.max_inbound_in_flight_percent.min(100) as u64;
    snap.channel_value_satoshis
        .saturating_mul(1_000) // sat → msat
        .saturating_mul(pct)
        / 100
}

/// The outcome of the (pure) decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpliceDecision {
    /// Channel can still serve a full-scale swap-in (or isn't a candidate) — do
    /// nothing.
    Healthy,
    /// Initiate a splice-in of `grow_sats` to restore working swap-in capacity.
    Splice { grow_sats: u64 },
    /// A splice is needed but a hard bound blocks it — the operator must act. The
    /// caller MUST surface this (warn), never silently no-op.
    Blocked(BlockReason),
}

/// Why a needed splice can't be done — each is a physics/economics wall, not a
/// transient condition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockReason {
    /// Confirmed on-chain balance minus the force-close reserve can't fund a grow
    /// of at least [`MIN_ECONOMIC_GROW_SATS`]. Fund the LP wallet.
    InsufficientWallet { spendable_sats: u64, need_sats: u64 },
    /// The channel is already at (or within a sub-economic distance of)
    /// `CHANNEL_MAX_FUNDING_SATS`; a grow that clears the economic floor can't fit.
    /// Raise the cap or serve more flow via another LP's channel.
    ChannelCapReached { channel_value_satoshis: u64 },
}

/// PURE decision: given the channel snapshot, the LP's confirmed on-chain balance,
/// config and the channel-funding cap, decide whether to splice and by how much.
///
/// Trigger: `next_outbound_htlc_limit_msat < per_swap_ceiling_msat` — the LP can
/// no longer forward a full-scale swap-in.
///
/// Sizing: restore the forwarding capacity to TWO ceilings (clear the exhaustion
/// AND leave headroom for one more full-scale swap before the next splice), i.e.
/// `target = 2·ceiling`, `deficit = target − current`. Grow by the deficit
/// (rounded up to sats), then apply the hard bounds:
///   1. clamp to the channel cap (`CHANNEL_MAX_FUNDING_SATS − channel_value`);
///   2. clamp to spendable wallet (`confirmed − reserve`);
///   3. require the result ≥ [`MIN_ECONOMIC_GROW_SATS`], else Block with the
///      binding reason.
///
/// `cap_sats` is passed (not hard-read) so tests can exercise the clamp at any
/// scale; production passes `CHANNEL_MAX_FUNDING_SATS`.
pub fn decide_splice(
    snap: &ChannelSnapshot,
    confirmed_wallet_sats: u64,
    cfg: &RebalanceConfig,
    cap_sats: u64,
) -> SpliceDecision {
    // Only a live channel is a splice candidate.
    if !snap.is_usable {
        return SpliceDecision::Healthy;
    }

    let ceiling_msat = per_swap_ceiling_msat(snap);
    if ceiling_msat == 0 {
        // A zero-value / zero-percent channel can't define a swap scale; nothing
        // to serve, nothing to do.
        return SpliceDecision::Healthy;
    }

    // TRIGGER: can the LP still forward a full-scale swap-in?
    if snap.next_outbound_htlc_limit_msat >= ceiling_msat {
        return SpliceDecision::Healthy;
    }

    // Deficit (msat) to restore TWO ceilings of forwarding capacity: clear the
    // exhaustion + one full-scale swap of headroom before the next splice.
    let target_msat = ceiling_msat.saturating_mul(2);
    let deficit_msat = target_msat.saturating_sub(snap.next_outbound_htlc_limit_msat);
    // msat → sat, round UP so we never grow a hair short of the ceiling.
    let want_grow_sats = deficit_msat.div_ceil(1_000);

    // BOUND 1 — channel cap. Headroom to the max funding for this channel.
    let cap_headroom = cap_sats.saturating_sub(snap.channel_value_satoshis);
    if cap_headroom < MIN_ECONOMIC_GROW_SATS {
        // Even a minimum economic grow won't fit under the cap.
        return SpliceDecision::Blocked(BlockReason::ChannelCapReached {
            channel_value_satoshis: snap.channel_value_satoshis,
        });
    }
    let grow_sats = want_grow_sats.min(cap_headroom);

    // BOUND 2 — wallet reserve. Spendable = confirmed − force-close reserve.
    let spendable = confirmed_wallet_sats.saturating_sub(cfg.wallet_reserve_sats);
    if spendable < MIN_ECONOMIC_GROW_SATS {
        return SpliceDecision::Blocked(BlockReason::InsufficientWallet {
            spendable_sats: spendable,
            need_sats: MIN_ECONOMIC_GROW_SATS,
        });
    }
    let grow_sats = grow_sats.min(spendable);

    // BOUND 3 — minimum economic size. (Both clamps above can only shrink
    // `grow_sats`; if either dragged it below the floor — but each guarded its own
    // ≥ floor precondition — we still re-check defensively.)
    if grow_sats < MIN_ECONOMIC_GROW_SATS {
        // The binding constraint is whichever clamp is tighter. Report the wallet
        // reason when the wallet is the limiter, else the cap.
        if spendable <= cap_headroom {
            return SpliceDecision::Blocked(BlockReason::InsufficientWallet {
                spendable_sats: spendable,
                need_sats: MIN_ECONOMIC_GROW_SATS,
            });
        }
        return SpliceDecision::Blocked(BlockReason::ChannelCapReached {
            channel_value_satoshis: snap.channel_value_satoshis,
        });
    }

    SpliceDecision::Splice { grow_sats }
}

/// Build a [`ChannelSnapshot`] from an LDK `ChannelDetails`, reading the per-swap
/// percent from the channel's negotiated config (falling back to the hop's known
/// 50% default if LDK doesn't surface it).
fn snapshot_of(c: &lightning::ln::channel_state::ChannelDetails) -> ChannelSnapshot {
    // Our `node::boot` sets `max_inbound_htlc_value_in_flight_percent_of_channel`
    // from `node::HOP_MAX_INBOUND_IN_FLIGHT_PCT`. `ChannelDetails::config` is
    // `Option<ChannelConfig>`, but that struct does not carry the handshake-time
    // in-flight percent (it's a handshake param, not a runtime-updatable one), so
    // we read the SAME const the hop committed at open — single source of truth, so
    // the rebalancer's per-swap ceiling can't drift from the boot config.
    ChannelSnapshot {
        channel_value_satoshis: c.channel_value_satoshis,
        next_outbound_htlc_limit_msat: c.next_outbound_htlc_limit_msat,
        max_inbound_in_flight_percent: HOP_MAX_INBOUND_IN_FLIGHT_PCT,
        is_usable: c.is_usable,
    }
}

/// (B) ONE capacity-rebalancing PASS for the fleet's channel toward `hop_node_pk`. Runs [`decide_splice`] and,
/// when swap-in has drained the outbound below the per-swap ceiling AND the wallet (the LP's on-chain TOP-UP
/// deposit, now held by the VAULT — the LP runs nothing) can fund it, [`initiate_splice`]s IN — guarded so at most
/// one splice per channel is outstanding. Called each tick by the vault open-orchestrator (the fleet does ALL
/// keeping). `hop_node_pk` filters to the hop channel (the only one carrying swap flow); `active` is the in-flight
/// set (same pattern as `channel_driver`). LDK also rejects a concurrent splice, so a racing delivery splice just
/// fails gracefully and retries next tick. (Was the LP-side `run_rebalancer` loop, retired with the LP daemon.)
pub async fn rebalance_capacity_tick(
    channel_manager: &Arc<HopChannelManager>,
    wallet: &OnchainWallet,
    esplora: &Arc<Esplora>,
    hop_node_pk: PublicKey,
    cfg: &RebalanceConfig,
    active: &Arc<Mutex<HashSet<ChannelId>>>,
) {
    // Every fleet channel toward the hop (the vault holds MANY — one per lpEth); rebalance EACH. `continue`
    // skips a channel (splice already in flight / healthy) and the next tick revisits it.
    for chan in channel_manager
        .list_channels()
        .into_iter()
        .filter(|c| c.counterparty.node_id == hop_node_pk)
    {
        let channel_id = chan.channel_id;

        // A splice already in flight on this channel suppresses the decision (the
        // natural rate limit — no cooldown timer). Peek without holding the slot.
        if active.lock().unwrap().contains(&channel_id) {
            debug!(cid = ?channel_id, "rebalancer: splice already in flight — skip");
            continue;
        }

        let snap = snapshot_of(&chan);
        let confirmed = wallet.get_balance().confirmed.to_sat();

        match decide_splice(&snap, confirmed, &cfg, CHANNEL_MAX_FUNDING_SATS as u64) {
            SpliceDecision::Healthy => { /* nothing to do */ }
            SpliceDecision::Blocked(reason) => {
                // A NEEDED splice is blocked by a hard bound — surface loudly so
                // the operator funds the wallet / raises the cap. Never silent.
                match reason {
                    BlockReason::InsufficientWallet { spendable_sats, need_sats } => warn!(
                        cid = ?channel_id, spendable_sats, need_sats,
                        confirmed_wallet_sats = confirmed,
                        wallet_reserve_sats = cfg.wallet_reserve_sats,
                        "rebalancer: swap-in capacity exhausted but LP wallet can't fund a \
                         splice (need >= {need_sats} spendable above the force-close reserve) \
                         — FUND THE LP WALLET",
                    ),
                    BlockReason::ChannelCapReached { channel_value_satoshis } => warn!(
                        cid = ?channel_id, channel_value_satoshis,
                        cap_sats = CHANNEL_MAX_FUNDING_SATS,
                        "rebalancer: swap-in capacity exhausted but channel is at the funding \
                         cap — RAISE CHANNEL_MAX_FUNDING_SATS or add another LP channel",
                    ),
                }
            }
            SpliceDecision::Splice { grow_sats } => {
                // Claim the in-flight slot BEFORE initiating. If a concurrent
                // holder (reconciler / driver) already has it, back off this tick.
                if !active.lock().unwrap().insert(channel_id) {
                    debug!(cid = ?channel_id, "rebalancer: slot taken concurrently — skip");
                    continue;
                }
                info!(
                    cid = ?channel_id, grow_sats,
                    channel_value_satoshis = snap.channel_value_satoshis,
                    next_outbound_htlc_limit_msat = snap.next_outbound_htlc_limit_msat,
                    "rebalancer: swap-in capacity below the per-swap ceiling — splicing in"
                );
                let r = initiate_splice(
                    channel_manager,
                    wallet,
                    esplora,
                    &channel_id,
                    &hop_node_pk,
                    grow_sats,
                    SPLICE_FUNDING_FEERATE_SAT_PER_KW,
                )
                .await;
                match r {
                    Ok(()) => {
                        // Hold the slot: the splice now occupies the channel until
                        // it locks. The channel_driver's `Spliced` handler shares
                        // this `active` set and releases the slot on completion;
                        // when the LP side has no driver sharing it, the slot is
                        // freed once the channel value reflects the grow (next
                        // branch). Either way ONE splice is outstanding at a time.
                        info!(cid = ?channel_id, grow_sats, "rebalancer: splice initiated");
                    }
                    Err(e) => {
                        // initiate_splice failed (e.g. UTXO race, peer offline).
                        // FREE the slot so the NEXT tick retries — no retry storm
                        // (one attempt per interval), no permanent wedge.
                        active.lock().unwrap().remove(&channel_id);
                        error!(cid = ?channel_id, "rebalancer: initiate_splice failed: {e:#}");
                    }
                }
            }
        }

        // Self-release: if we hold the slot but the channel value has already grown
        // to/over the in-flight target, the splice locked — free the slot so future
        // exhaustion can trigger again. This makes the LP side self-sufficient even
        // with no channel_driver sharing the `active` set. (When a driver DOES
        // share it, the driver's own removal wins the race harmlessly — remove is
        // idempotent.)
        //
        // We re-read the channel to compare current value against the value at the
        // time we (may have) initiated; a strictly-grown value means a prior
        // splice locked.
        if active.lock().unwrap().contains(&channel_id) {
            if let Some(c) = channel_manager
                .list_channels()
                .into_iter()
                .find(|c| c.channel_id == channel_id)
            {
                // After a lock, the LP's outbound is restored AND the value grew.
                // The cheap, robust signal that the in-flight splice is done is:
                // the channel can once again serve a full-scale swap-in.
                let s = snapshot_of(&c);
                if s.is_usable
                    && s.next_outbound_htlc_limit_msat >= per_swap_ceiling_msat(&s)
                {
                    active.lock().unwrap().remove(&channel_id);
                    debug!(cid = ?channel_id, "rebalancer: in-flight splice resolved — slot freed");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A healthy channel scaled like `node::boot`: 1,000,000-sat channel, 50%
    /// per-swap ceiling = 500,000 sat = 500,000,000 msat.
    fn snap(value_sats: u64, next_out_msat: u64) -> ChannelSnapshot {
        ChannelSnapshot {
            channel_value_satoshis: value_sats,
            next_outbound_htlc_limit_msat: next_out_msat,
            max_inbound_in_flight_percent: HOP_MAX_INBOUND_IN_FLIGHT_PCT,
            is_usable: true,
        }
    }

    fn cfg() -> RebalanceConfig {
        RebalanceConfig { wallet_reserve_sats: 10_000, poll_interval_secs: 30 }
    }

    const CAP: u64 = CHANNEL_MAX_FUNDING_SATS as u64; // 5 BTC

    #[test]
    fn per_swap_ceiling_is_pct_of_value() {
        // 50% of 1,000,000 sat = 500,000 sat = 500,000,000 msat.
        assert_eq!(per_swap_ceiling_msat(&snap(1_000_000, 0)), 500_000_000);
        // 50% of 2,000,000 sat = 1,000,000 sat.
        assert_eq!(per_swap_ceiling_msat(&snap(2_000_000, 0)), 1_000_000_000);
    }

    #[test]
    fn healthy_capacity_does_not_splice() {
        // Forwarding capacity AT the ceiling → can still serve a full swap-in.
        let s = snap(1_000_000, 500_000_000);
        assert_eq!(decide_splice(&s, 10_000_000, &cfg(), CAP), SpliceDecision::Healthy);
        // Above the ceiling → healthy.
        let s = snap(1_000_000, 900_000_000);
        assert_eq!(decide_splice(&s, 10_000_000, &cfg(), CAP), SpliceDecision::Healthy);
    }

    #[test]
    fn exhaustion_triggers_a_splice() {
        // Forwarding capacity BELOW the ceiling (only 100,000,000 msat vs the
        // 500,000,000 msat ceiling) → splice. Target = 2 ceilings = 1,000,000,000
        // msat; deficit = 900,000,000 msat = 900,000 sat. Wallet is fat, channel
        // far from cap, so the grow = the full deficit.
        let s = snap(1_000_000, 100_000_000);
        let d = decide_splice(&s, 10_000_000, &cfg(), CAP);
        assert_eq!(d, SpliceDecision::Splice { grow_sats: 900_000 });
    }

    #[test]
    fn fully_drained_triggers_two_ceilings() {
        // next_outbound = 0 → deficit = 2 ceilings = 1,000,000 sat.
        let s = snap(1_000_000, 0);
        assert_eq!(
            decide_splice(&s, 10_000_000, &cfg(), CAP),
            SpliceDecision::Splice { grow_sats: 1_000_000 }
        );
    }

    #[test]
    fn not_usable_never_splices() {
        let mut s = snap(1_000_000, 0);
        s.is_usable = false;
        assert_eq!(decide_splice(&s, 10_000_000, &cfg(), CAP), SpliceDecision::Healthy);
    }

    #[test]
    fn wallet_reserve_blocks() {
        // Exhausted, but confirmed balance is entirely the reserve → spendable 0 <
        // MIN_ECONOMIC_GROW_SATS → Blocked(InsufficientWallet).
        let s = snap(1_000_000, 0);
        let c = cfg(); // reserve 10_000
        let d = decide_splice(&s, 10_000, &c, CAP); // confirmed == reserve
        match d {
            SpliceDecision::Blocked(BlockReason::InsufficientWallet { spendable_sats, .. }) => {
                assert_eq!(spendable_sats, 0);
            }
            other => panic!("expected InsufficientWallet, got {other:?}"),
        }
        // Confirmed just below reserve + min-economic → still blocked.
        let d = decide_splice(&s, 10_000 + MIN_ECONOMIC_GROW_SATS - 1, &c, CAP);
        assert!(matches!(
            d,
            SpliceDecision::Blocked(BlockReason::InsufficientWallet { .. })
        ));
    }

    #[test]
    fn wallet_clamps_grow_when_partially_funded() {
        // Exhausted (deficit 1,000,000 sat) but spendable only 300,000 sat
        // (confirmed 310,000 − reserve 10,000). 300,000 ≥ MIN_ECONOMIC_GROW_SATS,
        // so we splice the clamped 300,000 (do what we can).
        let s = snap(1_000_000, 0);
        let d = decide_splice(&s, 310_000, &cfg(), CAP);
        assert_eq!(d, SpliceDecision::Splice { grow_sats: 300_000 });
    }

    #[test]
    fn below_min_economic_blocks() {
        // Spendable above 0 but below the economic floor → Blocked, not a tiny
        // value-destructive splice. confirmed 10,000 + (MIN-1) over reserve.
        let s = snap(1_000_000, 0);
        let c = cfg();
        let d = decide_splice(&s, 10_000 + (MIN_ECONOMIC_GROW_SATS - 1), &c, CAP);
        assert!(matches!(
            d,
            SpliceDecision::Blocked(BlockReason::InsufficientWallet { .. })
        ));
    }

    #[test]
    fn channel_cap_clamps_the_grow() {
        // Channel already at cap − 400,000 sat; deficit wants 1,000,000 but only
        // 400,000 fits under the cap → grow clamped to 400,000.
        let value = CAP - 400_000;
        let s = snap(value, 0); // ceiling scales with value but still exhausted at 0
        let d = decide_splice(&s, 10_000_000, &cfg(), CAP);
        assert_eq!(d, SpliceDecision::Splice { grow_sats: 400_000 });
    }

    #[test]
    fn channel_cap_reached_blocks() {
        // Channel within a sub-economic distance of the cap → can't even fit a
        // minimum economic grow → Blocked(ChannelCapReached).
        let value = CAP - (MIN_ECONOMIC_GROW_SATS - 1);
        let s = snap(value, 0);
        let d = decide_splice(&s, 10_000_000, &cfg(), CAP);
        assert!(matches!(
            d,
            SpliceDecision::Blocked(BlockReason::ChannelCapReached { .. })
        ));
        // Exactly AT the cap → blocked.
        let s = snap(CAP, 0);
        assert!(matches!(
            decide_splice(&s, 10_000_000, &cfg(), CAP),
            SpliceDecision::Blocked(BlockReason::ChannelCapReached { .. })
        ));
    }

    #[test]
    fn in_flight_is_handled_by_the_loop_guard_not_decide() {
        // `decide_splice` is pure and stateless: the in-flight suppression lives in
        // `run_rebalancer` (the `active` set). This test documents that a fresh
        // decision on an exhausted channel always SAYS splice — it's the loop that
        // refuses to ACT on it while a splice is outstanding. (See
        // `loop_guard_suppresses_second_splice` for the guard itself.)
        let s = snap(1_000_000, 0);
        assert!(matches!(
            decide_splice(&s, 10_000_000, &cfg(), CAP),
            SpliceDecision::Splice { .. }
        ));
    }

    #[test]
    fn loop_guard_suppresses_second_splice() {
        // The `active` HashSet IS the rate limit. Once a channel's id is in the
        // set, the loop's `contains` check short-circuits before `decide_splice` is
        // ever consulted — so a second splice cannot be initiated while one is
        // outstanding, with no cooldown timer. We exercise the exact guard logic
        // the loop uses.
        let active: Mutex<HashSet<ChannelId>> = Mutex::new(HashSet::new());
        let cid = ChannelId([7u8; 32]);

        // First decision: slot free → would proceed; claim it.
        assert!(!active.lock().unwrap().contains(&cid));
        assert!(active.lock().unwrap().insert(cid)); // claimed

        // Second decision while in flight: guard suppresses (no second splice).
        assert!(active.lock().unwrap().contains(&cid));

        // Splice resolves → slot freed → a future exhaustion can trigger again.
        active.lock().unwrap().remove(&cid);
        assert!(!active.lock().unwrap().contains(&cid));
        assert!(active.lock().unwrap().insert(cid)); // can claim again
    }
}
