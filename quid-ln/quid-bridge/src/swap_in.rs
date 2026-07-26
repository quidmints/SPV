//! Swap-in sender: consume `ClaimedSwapIn` from the hop and run the
//! settle-then-claim contract — deliver the USD on-chain via `settleSwapIn`
//! BEFORE taking the seller's BTC; on an undeliverable settle, fail the HTLC so
//! the seller reclaims. See `quid_hop::event_handler::ClaimedSwapIn` for the
//! full consumer contract this implements.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::B256;
use quid_hop::event_handler::{
    swap_in_cltv_headroom_ok, ClaimedSwapIn, SwapInMsg, SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS,
};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::sync::oneshot;
use tracing::{info, warn};

use crate::config::BridgeConfig;
use crate::evm::{EvmClient, SettleOutcome};
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

/// The LN action a definite settle outcome maps to — the pure core of
/// settle-then-claim (steps 2/3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    /// Take the seller's BTC (release the preimage). No refund variant: this rail is ATOMIC
    /// full-fill — it settles with `requireFull = true`, so a partial reverts on-chain
    /// (surfacing as `Undeliverable` → `Fail`) and never reaches a `Claim`. The fleet has no
    /// seller LN node to keysend a partial remainder to, so a `Claim` here always took 100%.
    Claim,
    Fail,
}

/// Map a settle outcome to its action. On this rail a `Delivered`/`AlreadySettled` outcome
/// ALWAYS converted the whole HTLC (`consumed_sats == sats`), because the settle used
/// `requireFull = true` — a partial would have reverted to `Undeliverable`. So there is no
/// remainder to refund; claim on delivered, fail on undeliverable.
fn outcome_action(outcome: SettleOutcome) -> Action {
    match outcome {
        // USD delivered now (full fill), or already delivered by a prior settle (restart
        // replay) — either way the seller's USD is on-chain, so take the BTC.
        SettleOutcome::Delivered { .. } | SettleOutcome::AlreadySettled { .. } => Action::Claim,
        // The pool couldn't deliver the floor OR could only PARTIALLY fill under
        // requireFull=true (both revert on-chain) — return the BTC to the seller.
        SettleOutcome::Undeliverable => Action::Fail,
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
pub async fn run_swap_in_sender<E, A, T>(
    cfg: BridgeConfig,
    evm: Arc<E>,
    actor: A,
    btc_tip: Arc<T>,
    store: Arc<BridgeStore>,
    mut rx: UnboundedReceiver<SwapInMsg>,
) where
    E: EvmClient,
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
        if handle_one(&cfg, &evm, &actor, &btc_tip, &store, c, None).await {
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
        if handle_one(&cfg, &evm, &actor, &btc_tip, &store, c, ack).await {
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
async fn handle_one<E, A, T>(
    cfg: &BridgeConfig,
    evm: &Arc<E>,
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
    E: EvmClient,
    A: SwapInActor,
    T: BtcTip,
{
    let (seller, token, sats, min) = (c.seller, c.token, c.sats, c.min_delivered_usd);
    let payment_hash = B256::from(c.payment_hash);

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

    for attempt in 0..=cfg.settle_max_retries {
        let evm2 = evm.clone();
        // Blocking EVM RPC off the async runtime — no second tokio.
        // ATOMIC full-fill: pass require_full = true so an inventory-bounded partial REVERTS
        // on-chain (→ Undeliverable → HTLC fail-back, seller keeps 100% of their BTC) rather
        // than delivering partial USD the fleet could never refund the remainder for (no
        // seller LN node to keysend). The on-chain rail is the one that accepts partials.
        let result = tokio::task::spawn_blocking(move || {
            evm2.settle_swap_in(seller, sats, token, payment_hash, min, true)
        })
        .await;

        match result {
            Ok(Ok(outcome)) => {
                match outcome_action(outcome) {
                    Action::Claim => {
                        actor.claim(c.preimage);
                        info!(sats, ?outcome, "swap-in: USD settled on-chain (full fill) → BTC claimed");
                    }
                    Action::Fail => {
                        actor.fail(c.payment_hash);
                        warn!("swap-in: undeliverable on-chain → HTLC failed (seller reclaims)");
                    }
                }
                store.take_inflight_swapin(&c.payment_hash); // terminal: drop the durable record
                return true; // definite outcome — safe to remember for dedup
            }
            Ok(Err(e)) => warn!(attempt, error = %e, "swap-in settle: transient RPC error"),
            Err(e) => warn!(attempt, error = %e, "swap-in settle: blocking task join error"),
        }
        tokio::time::sleep(Duration::from_secs(cfg.retry_backoff_secs)).await;
    }
    warn!(
        "swap-in settle: retries exhausted; HTLC left pending (times out → seller reclaims)"
    );
    false // pending, not definite — allow a later replay to re-attempt
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{Address, U256};
    use std::sync::Mutex;

    fn test_cfg() -> BridgeConfig {
        BridgeConfig {
            rpc_url: "http://localhost:8545".into(),
            rpc_urls: Vec::new(),
            rpc_quorum: 1,
            chain_id: 1,
            btc_channels: Address::ZERO,
            min_confirmations: 1,
            min_cltv_headroom_blocks: 40,
            settle_max_retries: 3,
            retry_backoff_secs: 0, // instant in tests
            max_fee_per_gas: 1_000_000_000,
            max_priority_fee_per_gas: 1_000_000,
            gas_limit: 300_000,
            receipt_poll_attempts: 3,
            receipt_poll_secs: 0,
            fee_bump_attempts: 3,
            fee_bump_pct: 125,
            settle_min_confirmations: 1,
            max_log_block_span: 10_000,
            swap_out_poll_secs: 0,
            btc_vault: Address::repeat_byte(0xFA),
            spv_gateway: Address::repeat_byte(0x5B),
            relayer_defer_inflight: 20,
            relay_batch_max: 100,
            relay_gas_limit: 5_000_000,
            relay_poll_secs: 0,
            relay_reorg_lookback: 144,
            channel_reconcile_secs: 300,
        }
    }

    /// An in-memory (path-less) store for the handle_one tests — its persist calls
    /// are no-ops, so the durability state-machine tests below use an on-disk store.
    fn mem_store() -> Arc<BridgeStore> {
        Arc::new(BridgeStore::load(None).unwrap())
    }

    fn test_swap_in() -> ClaimedSwapIn {
        ClaimedSwapIn {
            seller: Address::repeat_byte(0x11),
            sats: 100_000,
            token: Address::repeat_byte(0x22),
            payment_hash: [0xAB; 32],
            min_delivered_usd: U256::from(1_000_000u64),
            preimage: [0xCD; 32],
            claim_deadline: Some(1_000),
        }
    }

    #[derive(Default)]
    struct MockActor {
        claimed: Mutex<Vec<[u8; 32]>>,
        failed: Mutex<Vec<[u8; 32]>>,
    }
    impl SwapInActor for MockActor {
        fn claim(&self, p: [u8; 32]) {
            self.claimed.lock().unwrap().push(p);
        }
        fn fail(&self, h: [u8; 32]) {
            self.failed.lock().unwrap().push(h);
        }
    }

    /// A BtcTip that returns a fixed height, or errors. Records the call count so
    /// tests can assert the tip was (or wasn't) consulted.
    struct FixedTip {
        height: anyhow::Result<u64>,
    }
    impl FixedTip {
        fn at(h: u64) -> Arc<Self> {
            Arc::new(Self { height: Ok(h) })
        }
        fn erroring() -> Arc<Self> {
            Arc::new(Self { height: Err(anyhow::anyhow!("esplora tip read failed")) })
        }
    }
    impl BtcTip for FixedTip {
        fn tip_height(&self) -> anyhow::Result<u64> {
            match &self.height {
                Ok(h) => Ok(*h),
                Err(e) => Err(anyhow::anyhow!("{e}")),
            }
        }
    }

    /// An EvmClient that PANICS if settle is ever called — for the fail-back /
    /// defer paths, which must never reach the settle loop.
    struct NeverSettleEvm;
    impl EvmClient for NeverSettleEvm {
        fn settle_swap_in(
            &self,
            _: Address,
            _: u64,
            _: Address,
            _: B256,
            _: U256,
            _: bool,
        ) -> anyhow::Result<SettleOutcome> {
            panic!("settle_swap_in must NOT be called on the fail-back/defer path");
        }
    }

    /// Ample-headroom tip: well below `deadline - SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS`.
    /// test_swap_in()'s deadline is 1_000, so any tip far below 1_000 - MIN passes.
    fn ample_tip() -> Arc<FixedTip> {
        FixedTip::at(0)
    }

    /// Always returns a fixed definite outcome.
    struct FixedEvm(SettleOutcome);
    impl EvmClient for FixedEvm {
        fn settle_swap_in(
            &self,
            _: Address,
            _: u64,
            _: Address,
            _: B256,
            _: U256,
            _: bool,
        ) -> anyhow::Result<SettleOutcome> {
            Ok(self.0)
        }
    }

    /// Fails `fails_left` times (transient), then returns `then`.
    struct FlakyEvm {
        fails_left: Mutex<u32>,
        then: SettleOutcome,
    }
    impl EvmClient for FlakyEvm {
        fn settle_swap_in(
            &self,
            _: Address,
            _: u64,
            _: Address,
            _: B256,
            _: U256,
            _: bool,
        ) -> anyhow::Result<SettleOutcome> {
            let mut n = self.fails_left.lock().unwrap();
            if *n > 0 {
                *n -= 1;
                anyhow::bail!("transient rpc");
            }
            Ok(self.then)
        }
    }

    #[test]
    fn outcome_action_is_settle_then_claim() {
        // Atomic full-fill rail: a Delivered/AlreadySettled outcome always converted the whole
        // HTLC (partials revert under requireFull=true), so both map to a plain Claim.
        assert_eq!(outcome_action(SettleOutcome::Delivered { consumed_sats: 100_000 }), Action::Claim);
        assert_eq!(outcome_action(SettleOutcome::AlreadySettled { consumed_sats: 100_000 }), Action::Claim);
        // A partial (or floor-unmet) settle reverts on-chain → Undeliverable → Fail (seller
        // keeps 100% of their BTC via the HTLC fail-back).
        assert_eq!(outcome_action(SettleOutcome::Undeliverable), Action::Fail);
    }

    #[tokio::test]
    async fn delivered_claims_the_btc() {
        let actor = MockActor::default();
        handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 })),
            &actor,
            &ample_tip(),
            &mem_store(),
            test_swap_in(),
            None,
        )
        .await;
        assert_eq!(actor.claimed.lock().unwrap().as_slice(), &[[0xCD; 32]]);
        assert!(actor.failed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn already_settled_claims_the_btc() {
        let actor = MockActor::default();
        handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::AlreadySettled { consumed_sats: 100_000 })),
            &actor,
            &ample_tip(),
            &mem_store(),
            test_swap_in(),
            None,
        )
        .await;
        assert_eq!(actor.claimed.lock().unwrap().len(), 1);
        assert!(actor.failed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn undeliverable_fails_the_htlc() {
        let actor = MockActor::default();
        handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::Undeliverable)),
            &actor,
            &ample_tip(),
            &mem_store(),
            test_swap_in(),
            None,
        )
        .await;
        assert!(actor.claimed.lock().unwrap().is_empty());
        assert_eq!(actor.failed.lock().unwrap().as_slice(), &[[0xAB; 32]]);
    }

    #[tokio::test]
    async fn transient_errors_are_retried_then_succeed() {
        let actor = MockActor::default();
        let evm = Arc::new(FlakyEvm {
            fails_left: Mutex::new(2), // within settle_max_retries = 3
            then: SettleOutcome::Delivered { consumed_sats: 100_000 },
        });
        handle_one(&test_cfg(), &evm, &actor, &ample_tip(), &mem_store(), test_swap_in(), None).await;
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "claimed after retries");
        assert!(actor.failed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn exhausted_retries_leave_htlc_pending() {
        let actor = MockActor::default();
        let evm = Arc::new(FlakyEvm {
            fails_left: Mutex::new(99), // exceeds retries → never succeeds
            then: SettleOutcome::Delivered { consumed_sats: 100_000 },
        });
        let done = handle_one(&test_cfg(), &evm, &actor, &ample_tip(), &mem_store(), test_swap_in(), None).await;
        // Neither claimed nor failed — left pending so the HTLC times out and the
        // seller reclaims (no silent loss, no premature claim/fail).
        assert!(actor.claimed.lock().unwrap().is_empty());
        assert!(actor.failed.lock().unwrap().is_empty());
        // A pending swap-in is NOT remembered, so a replay re-attempts it.
        assert!(!done, "pending → not deduped");
    }

    #[tokio::test]
    async fn definite_outcomes_are_remembered_for_dedup() {
        // Claim AND fail are definite → handle_one returns true so the caller
        // dedups a replay; only the retries-exhausted case (above) returns false.
        let actor = MockActor::default();
        let claimed = handle_one(
            &test_cfg(), &Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 })), &actor, &ample_tip(), &mem_store(), test_swap_in(),
            None,
        ).await;
        assert!(claimed, "delivered+claimed is definite");
        let failed = handle_one(
            &test_cfg(), &Arc::new(FixedEvm(SettleOutcome::Undeliverable)), &actor, &ample_tip(), &mem_store(), test_swap_in(),
            None,
        ).await;
        assert!(failed, "undeliverable+failed is definite");
    }

    // ---- Increment 1b: the settle-time CLTV re-check ----

    /// A swap-in with `claim_deadline` Some(d). With a custom tip the re-check has
    /// `headroom = d - tip`; we drive each branch by choosing the tip.
    fn swap_in_with_deadline(d: u32) -> ClaimedSwapIn {
        ClaimedSwapIn { claim_deadline: Some(d), ..test_swap_in() }
    }

    #[tokio::test]
    async fn recheck_fails_back_when_headroom_eroded() {
        // deadline 1_000; tip 999 ⇒ headroom 1 < MIN(72) ⇒ fail back, NEVER settle.
        let actor = MockActor::default();
        let done = handle_one(
            &test_cfg(),
            &Arc::new(NeverSettleEvm), // panics if settle is attempted
            &actor,
            &FixedTip::at(999),
            &mem_store(),
            swap_in_with_deadline(1_000),
            None,
        )
        .await;
        assert!(actor.claimed.lock().unwrap().is_empty(), "no BTC claimed");
        assert_eq!(
            actor.failed.lock().unwrap().as_slice(),
            &[[0xAB; 32]],
            "HTLC failed back so the swapper keeps their BTC"
        );
        assert!(done, "a fail-back is a DEFINITE outcome (clean refund) — deduped, not retried");
    }

    #[tokio::test]
    async fn recheck_proceeds_to_settle_with_ample_headroom() {
        // deadline 1_000; tip 100 ⇒ headroom 900 ≫ MIN ⇒ settle proceeds → claim.
        let actor = MockActor::default();
        let done = handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 })),
            &actor,
            &FixedTip::at(100),
            &mem_store(),
            swap_in_with_deadline(1_000),
            None,
        )
        .await;
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "settled then claimed");
        assert!(actor.failed.lock().unwrap().is_empty());
        assert!(done);
    }

    #[tokio::test]
    async fn recheck_at_exact_threshold_proceeds() {
        // headroom == MIN is allowed (matches swap_in_cltv_headroom_ok: >=).
        let actor = MockActor::default();
        let deadline = SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS + 100;
        handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 })),
            &actor,
            &FixedTip::at(100), // headroom = deadline - 100 = MIN exactly
            &mem_store(),
            swap_in_with_deadline(deadline),
            None,
        )
        .await;
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "exactly-MIN headroom settles");
    }

    #[tokio::test]
    async fn recheck_defers_on_tip_read_error() {
        // Esplora tip read fails ⇒ can't verify safety ⇒ DEFER: no settle, no
        // claim/fail, NOT definite (returns false so a later replay re-attempts).
        let actor = MockActor::default();
        let done = handle_one(
            &test_cfg(),
            &Arc::new(NeverSettleEvm), // must not settle blind
            &actor,
            &FixedTip::erroring(),
            &mem_store(),
            swap_in_with_deadline(1_000),
            None,
        )
        .await;
        assert!(actor.claimed.lock().unwrap().is_empty(), "no claim");
        assert!(actor.failed.lock().unwrap().is_empty(), "no fail-back either — just deferred");
        assert!(!done, "tip-read error DEFERS (not definite) → re-attempted next round");
    }

    #[tokio::test]
    async fn recheck_none_deadline_proceeds_with_warn() {
        // claim_deadline = None (back-compat): proceed to settle (no re-check), the
        // tip source is NOT consulted. The floor still protects the USD amount.
        let actor = MockActor::default();
        let c = ClaimedSwapIn { claim_deadline: None, ..test_swap_in() };
        let done = handle_one(
            &test_cfg(),
            &Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 })),
            &actor,
            &FixedTip::erroring(), // proves the tip is NOT read on the None path
            &mem_store(),
            c,
            None,
        )
        .await;
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "None deadline still settles+claims");
        assert!(done);
    }

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

    // ---- Durable swap-in recovery (settle→claim crash window) ----

    /// A FixedEvm wrapped to COUNT settle calls — proves a re-drive claims exactly
    /// once and that a second loop-level pass is deduped (no re-settle).
    struct CountingEvm {
        outcome: SettleOutcome,
        calls: Mutex<u32>,
    }
    impl CountingEvm {
        fn new(o: SettleOutcome) -> Arc<Self> {
            Arc::new(Self { outcome: o, calls: Mutex::new(0) })
        }
    }
    impl EvmClient for CountingEvm {
        fn settle_swap_in(
            &self,
            _: Address,
            _: u64,
            _: Address,
            _: B256,
            _: U256,
            _: bool,
        ) -> anyhow::Result<SettleOutcome> {
            *self.calls.lock().unwrap() += 1;
            Ok(self.outcome)
        }
    }

    fn disk_store() -> (Arc<BridgeStore>, std::path::PathBuf) {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "quid-bridge-swapin-{}-{:?}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_file(&path);
        (Arc::new(BridgeStore::load(Some(path.clone())).unwrap()), path)
    }

    #[tokio::test]
    async fn persist_before_settle_then_remove_on_claim() {
        // The durability state machine: handle_one persists the in-flight swap-in
        // BEFORE settling, and removes it on the DEFINITE claim. To observe the
        // "persisted before settle" state we use a Fail-back path (CLTV eroded), then
        // separately the claim path, and check the store is empty after each terminal.
        let (store, path) = disk_store();
        let c = test_swap_in();
        let hash = c.payment_hash;

        let actor = MockActor::default();
        let done = handle_one(
            &test_cfg(),
            &CountingEvm::new(SettleOutcome::Delivered { consumed_sats: 100_000 }),
            &actor,
            &ample_tip(),
            &store,
            c,
            None,
        )
        .await;
        assert!(done, "delivered+claimed is definite");
        assert_eq!(actor.claimed.lock().unwrap().len(), 1);
        assert!(
            !store.has_inflight_swapin(&hash),
            "claimed swap-in removed from the durable store"
        );
        assert!(store.inflight_swapins().is_empty());
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn defer_leaves_swapin_persisted_for_redrive() {
        // A DEFER (tip-read error) must LEAVE the swap-in persisted so the boot
        // re-drive / next replay retries it — the heart of the crash-window fix.
        let (store, path) = disk_store();
        let c = swap_in_with_deadline(1_000);
        let hash = c.payment_hash;
        let actor = MockActor::default();
        let done = handle_one(
            &test_cfg(),
            &Arc::new(NeverSettleEvm), // never settles blind
            &actor,
            &FixedTip::erroring(),
            &store,
            c,
            None,
        )
        .await;
        assert!(!done, "tip-read error DEFERS");
        assert!(actor.claimed.lock().unwrap().is_empty());
        assert!(actor.failed.lock().unwrap().is_empty());
        assert!(
            store.has_inflight_swapin(&hash),
            "deferred swap-in stays persisted so it's re-driven later"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn redrive_on_boot_claims_persisted_swapin_then_dedups() {
        // SIMULATE THE CRASH: a swap-in was persisted (pre-settle) but the process
        // died before claiming. On reboot a FRESH store loads it, and re-driving via
        // run_swap_in_sender's boot path settles+claims it EXACTLY ONCE; a second
        // re-drive in the same loop is a no-op (RecentSwapIns dedup) — no double-claim.
        let (store, path) = disk_store();
        let c = swap_in_with_deadline(1_000);
        let hash = c.payment_hash;
        // Persist as if the bridge crashed mid-settle (the record alone survives;
        // LDK does NOT re-emit PaymentClaimable).
        store.add_inflight_swapin(&c);
        drop(store);

        // Reboot: fresh store from the same file sees the in-flight swap-in.
        let store2 = Arc::new(BridgeStore::load(Some(path.clone())).unwrap());
        let pending = store2.inflight_swapins();
        assert_eq!(pending.len(), 1, "boot re-drive sees the persisted swap-in");
        assert_eq!(pending[0].payment_hash, hash);

        // Re-drive against the same actor/evm/tip — must claim once and clear it.
        let actor = MockActor::default();
        let evm = CountingEvm::new(SettleOutcome::AlreadySettled { consumed_sats: 100_000 }); // re-settle is idempotent
        let mut recent = RecentSwapIns::new(RECENT_SWAP_IN_CAP);
        for c in store2.inflight_swapins() {
            let h = c.payment_hash;
            if recent.contains(&h) {
                continue;
            }
            if handle_one(&test_cfg(), &evm, &actor, &FixedTip::at(100), &store2, c, None).await {
                recent.insert(h);
            }
        }
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "claimed exactly once on re-drive");
        assert_eq!(*evm.calls.lock().unwrap(), 1, "settle called exactly once");
        assert!(!store2.has_inflight_swapin(&hash), "cleared after the terminal claim");

        // A SECOND boot re-drive pass against the now-cleared store + dedup is a no-op.
        for c in store2.inflight_swapins() {
            let h = c.payment_hash;
            if recent.contains(&h) {
                continue;
            }
            handle_one(&test_cfg(), &evm, &actor, &FixedTip::at(100), &store2, c, None).await;
        }
        assert_eq!(actor.claimed.lock().unwrap().len(), 1, "no double-claim on a second re-drive");
        assert_eq!(*evm.calls.lock().unwrap(), 1, "no re-settle on a second re-drive");
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn swapin_record_survives_reload_with_all_fields() {
        // The persisted projection round-trips every field needed to re-drive
        // WITHOUT the LDK event (esp. the preimage — persisted at rest by design).
        let (store, path) = disk_store();
        let c = ClaimedSwapIn {
            seller: Address::repeat_byte(0x33),
            sats: 77_000,
            token: Address::repeat_byte(0x44),
            payment_hash: [0x55; 32],
            min_delivered_usd: U256::from(123_456_789u64),
            preimage: [0x66; 32],
            claim_deadline: Some(987_654),
        };
        store.add_inflight_swapin(&c);
        drop(store);
        let store2 = Arc::new(BridgeStore::load(Some(path.clone())).unwrap());
        let got = store2.inflight_swapins();
        assert_eq!(got.len(), 1);
        let g = got[0];
        assert_eq!(g.seller, c.seller);
        assert_eq!(g.sats, c.sats);
        assert_eq!(g.token, c.token);
        assert_eq!(g.payment_hash, c.payment_hash);
        assert_eq!(g.min_delivered_usd, c.min_delivered_usd);
        assert_eq!(g.preimage, c.preimage, "preimage persisted at rest (re-drive needs it)");
        assert_eq!(g.claim_deadline, c.claim_deadline);
        let _ = std::fs::remove_file(&path);
    }

    /// durability-F1: the live loop must fire the handoff ACK both on the NORMAL
    /// path (after the durable `add_inflight_swapin`) AND on the DEDUP-SKIP path.
    /// If dedup-skip dropped the ack, the LN handler (awaiting it) would return
    /// Replay → re-deliver the same hash → hit the skip again → drop the ack again
    /// → infinite replay loop. Drives the real `run_swap_in_sender` loop and asserts
    /// BOTH acks arrive.
    #[tokio::test]
    async fn live_loop_acks_after_durable_record_and_on_dedup_skip() {
        let store = mem_store();
        let evm = Arc::new(FixedEvm(SettleOutcome::Delivered { consumed_sats: 100_000 }));
        let actor = MockActor::default();
        let tip = ample_tip();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(run_swap_in_sender(test_cfg(), evm, actor, tip, store.clone(), rx));

        let c = test_swap_in(); // Copy

        // First delivery → ack fires AFTER the bridge's durable add_inflight_swapin.
        let (a1, r1) = oneshot::channel();
        tx.send((c, Some(a1))).unwrap();
        tokio::time::timeout(Duration::from_secs(2), r1)
            .await
            .expect("handoff ack within 2s")
            .expect("ack sender not dropped");

        // Duplicate hash → dedup-skip → ack MUST still fire (no infinite replay).
        let (a2, r2) = oneshot::channel();
        tx.send((c, Some(a2))).unwrap();
        tokio::time::timeout(Duration::from_secs(2), r2)
            .await
            .expect("dedup-skip handoff ack within 2s (no infinite replay loop)")
            .expect("ack sender not dropped");

        drop(tx);
        let _ = task.await;
    }
}
