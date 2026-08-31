//! Swap-in sender: consume `ClaimedSwapIn` from the hop and run the
//! settle-then-claim contract — deliver the USD on-chain via `settleSwapIn`
//! BEFORE taking the seller's BTC; on an undeliverable settle, fail the HTLC so
//! the seller reclaims. See `quid_hop::event_handler::ClaimedSwapIn` for the
//! full consumer contract this implements.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use quid_hop::event_handler::{
    swap_in_cltv_headroom_ok, ClaimedSwapIn, SwapInMsg, SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS,
};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::sync::oneshot;
use tracing::{info, warn};

use crate::store::BridgeStore;

/// A Bitcoin best-tip-height source for the settle-time CLTV re-check (Increment
/// 1b). The production impl is the daemon's [`crate::header_source::EsploraHeaderSource`]
/// (which already implements [`crate::relayer::BtcHeaderSource::tip_height`] via the
/// hop's shared Esplora client); a tiny dedicated trait keeps the swap-in loop
/// unit-testable without standing up the full header source. `tip_height` is a
/// BLOCKING esplora read, so callers run it on `spawn_blocking`.
pub trait BtcTip: Send + Sync + 'static {
    /// The current Bitcoin best-chain tip height.
    fn tip_height(&self) -> anyhow::Result<u64>;
}

impl<S: crate::relayer::BtcHeaderSource> BtcTip for S {
    fn tip_height(&self) -> anyhow::Result<u64> {
        crate::relayer::BtcHeaderSource::tip_height(self)
    }
}

/// Drives the LN side once the EVM settle outcome is known. Abstracted so the
/// loop is unit-testable without LDK; `quid_hop::node::SwapInClaimer` is the
/// production impl (orphan rule: our trait, their type).
pub trait SwapInActor: Send + Sync + 'static {
    /// Step 2 — settle succeeded (or already-settled): take the seller's BTC.
    fn claim(&self, preimage: [u8; 32]);
    /// Step 3 — undeliverable: fail the inbound HTLC so the seller reclaims.
    fn fail(&self, payment_hash: [u8; 32]);
}

impl SwapInActor for quid_hop::node::SwapInClaimer {
    fn claim(&self, preimage: [u8; 32]) {
        quid_hop::node::SwapInClaimer::claim(self, preimage)
    }
    fn fail(&self, payment_hash: [u8; 32]) {
        quid_hop::node::SwapInClaimer::fail(self, payment_hash)
    }
}

/// Bounded FIFO set of recently DEFINITELY-handled swap-in hashes. LDK can
/// re-emit a `PaymentClaimable` after a restart / transient channel-receiver gap,
/// re-delivering the same `ClaimedSwapIn`; without this a replay re-runs a full
/// `settle_swap_in` — SAFE (the on-chain `swapInUsed` guard returns AlreadySettled)
/// but a wasted nonce-lock-held submit. Bounded so it can't leak like an unbounded
/// dedup; the realistic replay window is narrow (post-claim LDK stops re-emitting).
struct RecentSwapIns {
    order: VecDeque<[u8; 32]>,
    set: HashSet<[u8; 32]>,
    cap: usize,
}
impl RecentSwapIns {
    fn new(cap: usize) -> Self {
        Self { order: VecDeque::new(), set: HashSet::new(), cap }
    }
    fn contains(&self, h: &[u8; 32]) -> bool {
        self.set.contains(h)
    }
    fn insert(&mut self, h: [u8; 32]) {
        if self.set.insert(h) {
            self.order.push_back(h);
            if self.order.len() > self.cap {
                if let Some(old) = self.order.pop_front() {
                    self.set.remove(&old);
                }
            }
        }
    }
}

/// Cap on the in-memory swap-in replay-dedup. ~128 KB of hashes — far more than
/// any realistic replay window, and FIFO-evicted so memory is bounded.
const RECENT_SWAP_IN_CAP: usize = 4096;

/// Run the swap-in sender loop until the hop closes the channel.
///
/// `btc_tip` feeds the settle-time CLTV re-check (Increment 1b): the inbound
/// HTLC's claim deadline is re-evaluated against the LIVE Bitcoin tip right before
/// settling, catching headroom that eroded between the hop's emit-time gate and
/// the settle landing (slow nonce/hot-key, queue/restart backlog).
pub async fn run_swap_in_sender<A, T>(
    actor: A,
    btc_tip: Arc<T>,
    store: Arc<BridgeStore>,
    mut rx: UnboundedReceiver<SwapInMsg>,
) where
    A: SwapInActor,
    T: BtcTip,
{
    info!("swap-in sender: started");
    let mut recent = RecentSwapIns::new(RECENT_SWAP_IN_CAP);

    // BOOT RE-DRIVE: this LDK does NOT re-emit `PaymentClaimable` on restart, so a
    // swap-in that was in-flight (received → settle → claim) when the process died
    // is re-driven HERE from its persisted record — the only thing that finishes it.
    // Done BEFORE the live receiver, against the SAME actor/evm/tip, so it actually
    // claims. Re-settle is idempotent (AlreadySettled → claim) and the settle-time
    // CLTV re-check still fails back a deadline that lapsed during downtime.
    let pending = store.inflight_swapins();
    if !pending.is_empty() {
        info!(count = pending.len(), "swap-in: re-driving persisted in-flight swap-ins on boot");
    }
    for c in pending {
        let hash = c.payment_hash;
        if recent.contains(&hash) {
            continue;
        }
        // Boot re-drive: no LN event is waiting on an ack (the durable record is
        // already what we're re-driving from), so pass `None`.
        if handle_one(&actor, &btc_tip, &store, c, None).await {
            recent.insert(hash);
        }
    }

    while let Some((c, ack)) = rx.recv().await {
        let hash = c.payment_hash;
        // Short-circuit a replayed ClaimedSwapIn for a hash we already drove
        // to a DEFINITE outcome — avoids a wasteful re-settle (the loop is
        // sequential, so a replay always arrives after the prior completed).
        if recent.contains(&hash) {
            info!(?hash, "swap-in: duplicate ClaimedSwapIn (replay) — already handled, skipping");
            // CRITICAL (durability-F1): ack even on the dedup-skip. This hash is
            // already durably handled, so the held LN event MUST be released —
            // otherwise the handler (awaiting this ack) returns Replay, re-delivers
            // the same hash, hits this skip again, drops the ack again → an INFINITE
            // replay loop.
            let _ = ack.map(|a| a.send(()));
            continue;
        }
        if handle_one(&actor, &btc_tip, &store, c, ack).await {
            recent.insert(hash);
        }
    }
    info!("swap-in sender: channel closed, exiting");
}

/// Settle one swap-in, then claim or fail per the outcome. Transient RPC errors
/// are retried; if they're exhausted the HTLC is LEFT PENDING — it then times
/// out and the seller reclaims their BTC, so a stuck RPC is never a silent loss.
///
/// Returns `true` iff it reached a DEFINITE outcome (claimed or failed) — only
/// then may the caller remember the hash for replay-dedup. A pending
/// (retries-exhausted) swap-in returns `false` so a later replay RE-attempts it.
async fn handle_one<A, T>(
    actor: &A,
    btc_tip: &Arc<T>,
    store: &Arc<BridgeStore>,
    c: ClaimedSwapIn,
    // durability-F1: fired AFTER the first durable write (`add_inflight_swapin`) so
    // the LN event handler can release the persisted `PaymentClaimable` only once
    // the bridge owns a durable record. `None` on the boot re-drive (no waiter).
    ack: Option<oneshot::Sender<()>>,
) -> bool
where
    A: SwapInActor,
    T: BtcTip,
{
    let sats = c.sats;

    // DURABILITY (settle→claim crash window): persist the in-flight swap-in BEFORE
    // anything moves on-chain. If we crash after delivering USD but before claiming
    // the BTC, the boot re-drive reconstructs the claim from this record (LDK does
    // NOT re-emit PaymentClaimable). It is removed ONLY on a DEFINITE terminal
    // outcome below (claimed / failed-back); a DEFER leaves it persisted to retry.
    // Idempotent on the hash, so a boot re-drive / replay just re-writes the same
    // record. (No-op when the store is in-memory / path-less.)
    store.add_inflight_swapin(&c);

    // durability-F1: the bridge now owns a DURABLE record (add_inflight_swapin
    // persists via save_critical, which aborts the process on failure — so once it
    // returns, the record is on disk). Release the LN event handler that is holding
    // the persisted PaymentClaimable: from here the boot re-drive can finish this
    // swap-in even across a crash, so removing the LN event is safe. Fire BEFORE the
    // CLTV re-check / settle, since a DEFER below still leaves the durable record.
    if let Some(ack) = ack {
        let _ = ack.send(());
    }

    // Increment 1b — SETTLE-TIME CLTV RE-CHECK (step 0, re-evaluated). The hop's
    // event handler gated headroom at PaymentClaimable emit, but settle-then-claim
    // delivers USD on-chain BEFORE taking the BTC, and the settle can land much
    // later than the emit (the H-4 hot-key nonce head-of-line block, a queue/restart
    // backlog). If the deadline eroded below SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS in that
    // gap, settling would deliver USD for a BTC HTLC we can no longer claim in time
    // = direct loss. So we re-read the LIVE Bitcoin tip and re-apply the SAME
    // headroom property right before settling:
    //   • insufficient headroom → FAIL the HTLC back NOW (no USD delivered): turns a
    //     would-be loss into a clean swapper refund; a DEFINITE outcome (return true).
    //   • tip read fails → cannot verify safety → DEFER (leave HTLC pending, retry
    //     next replay): fail SAFE, never settle blind. Not definite (return false).
    //   • None deadline → shouldn't happen (the event handler populates the real
    //     PaymentClaimable.claim_deadline and itself fails back a missing one), but
    //     for back-compat we proceed-with-WARN rather than break a swap on a missing
    //     field. The on-chain floor still protects the USD AMOUNT.
    match c.claim_deadline {
        Some(deadline) => {
            let tip = btc_tip.clone();
            let tip_h = tokio::task::spawn_blocking(move || tip.tip_height()).await;
            match tip_h {
                Ok(Ok(h)) => {
                    let h = h as u32;
                    if !swap_in_cltv_headroom_ok(Some(deadline), h) {
                        warn!(
                            best = h, claim_deadline = deadline,
                            "swap-in: CLTV headroom < {SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS} blocks \
                             at SETTLE time (eroded since emit) → failing HTLC back, NO USD \
                             delivered (swapper keeps BTC)"
                        );
                        actor.fail(c.payment_hash);
                        store.take_inflight_swapin(&c.payment_hash); // terminal: drop the durable record
                        return true; // definite: resolved as a clean refund, do not retry
                    }
                }
                Ok(Err(e)) => {
                    warn!(error = %e, "swap-in: BTC tip read failed — cannot verify CLTV safety; \
                         DEFERRING settle (HTLC left pending, retried next round)");
                    return false; // not definite — re-attempt later (fail safe)
                }
                Err(e) => {
                    warn!(error = %e, "swap-in: BTC tip-read task join error — DEFERRING settle");
                    return false;
                }
            }
        }
        None => warn!(
            "swap-in: claim_deadline missing on ClaimedSwapIn (unexpected) — proceeding to settle \
             with no settle-time CLTV re-check (the floor still protects the USD amount)"
        ),
    }

    // ⛔ (§FLEET-FRONTS-THE-WINDOW) THE POOL-BACKED LN CREDIT IS DELETED, SO THIS RAIL FAILS
    // CLOSED. It used to settle USD on-chain out of `POOLED_USD` and then claim the seller's BTC,
    // which exposed the pool to an off-chain payment it could never verify — no on-chain proof of
    // an off-chain payment exists, so the bound around it could only ever be stale (it was:
    // `§RESERVE-HAS-NO-RETURN-PATH`).
    //
    // 🔑 THE REPLACEMENT SPLITS THE TRADE: the Lightning leg becomes seller ⇄ FLEET, an ordinary
    // payment the fleet fronts from its own balance, and the fleet then sells the sats to the pool
    // on-chain through `settleSwapInProven` naming ITSELF — where every dollar is paid against an
    // SPV-proven deposit. The pool's exposure is zero by construction.
    //
    // ⚠️ **FAILING THE HTLC IS THE ONLY SAFE STATE UNTIL THE FLEET'S OWN PAYOUT PATH EXISTS.**
    // Claiming without paying would take the seller's BTC for nothing; crediting the pool is what
    // was just removed. So the HTLC is failed back and **the seller keeps 100% of their BTC** —
    // the same terminal state this rail already used for an undeliverable settle. Nobody is short.
    // ▶️ To turn the rail back on, build the fleet-side payout (`§FLEET-FRONTS-THE-WINDOW`); the
    // on-chain reconcile leg needs no new code.
    actor.fail(c.payment_hash);
    warn!(sats, "swap-in: pool-backed LN credit is deleted (fleet-principal model) — HTLC failed \
                 back, seller keeps their BTC; re-enable with the fleet-side payout");
    store.take_inflight_swapin(&c.payment_hash);
    true // a definite outcome: the seller has their BTC back
}

#[cfg(test)]
mod tests {
    use super::*;

    // ⛔ (§FLEET-FRONTS-THE-WINDOW) THE SETTLE-OUTCOME SUITE IS DELETED WITH THE PATH IT TESTED.
    // It asserted delivered / already-settled / undeliverable / retry-exhausted behaviour of an
    // on-chain settle that no longer happens: the pool-backed LN credit is gone, and this rail
    // now fails every HTLC back until the fleet-side payout exists. Those tests would have kept
    // passing against mocks while testing a path production cannot take — the exact shape of
    // `§SETTLE-PROVEN-UNTESTED`, where coverage sat on the unreachable half of a pair.
    // ▶️ REBUILD THEM WITH THE FLEET-PRINCIPAL FLOW: the assertions worth restoring are that a
    // paid seller is claimed exactly once, that a crash between paying and claiming re-drives to
    // exactly one claim, and that an unpaid seller is always failed back.

    /// Still meaningful and independent of the rail: the replay-dedup ring is pure bookkeeping.
    #[test]
    fn recent_swap_ins_dedups_and_evicts_fifo() {
        let mut r = RecentSwapIns::new(2);
        r.insert([1; 32]);
        r.insert([2; 32]);
        assert!(r.contains(&[1; 32]) && r.contains(&[2; 32]));
        // Re-inserting an existing hash doesn't grow / double-evict.
        r.insert([2; 32]);
        assert!(r.contains(&[1; 32]), "no spurious eviction on duplicate insert");
        // Past the cap, the OLDEST is evicted (FIFO) — bounded memory.
        r.insert([3; 32]);
        assert!(!r.contains(&[1; 32]), "oldest evicted at cap");
        assert!(r.contains(&[2; 32]) && r.contains(&[3; 32]));
    }
}
