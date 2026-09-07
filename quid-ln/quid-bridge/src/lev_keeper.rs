//! YB IL-protect **keeper** — the parallel daemon task whose entire job is to make
//! a liquidation engine never needed.
//!
//! It runs as one more `set.spawn(run_lev_keeper(...))` in the quid-bridge `JoinSet`
//! (parallel to swap-in / relayer / reconciler), polling each opt-in levered LP
//! position and holding its LTV inside a range around the IL-protect target
//! `L = 1/α`, while NEVER letting LTV reach the external venue's liquidation
//! threshold.
//!
//! # Why this means we build NO liquidation engine of our own
//! The collateral (weETH) lives on an EXTERNAL, isolated Euler/Morpho market that
//! already has its own liquidation engine. Our keeper's contract is to de-lever
//! PROACTIVELY — always a [`LevKeeperConfig::safety_margin_bps`] below the venue's
//! liquidation LTV. So the venue's engine is a *never-triggered backstop*; we never
//! write one. A position the keeper genuinely cannot save (collateral momentarily
//! un-redeemable — the redemption-non-atomicity edge) falls to the venue's own
//! liquidation, which still never touches the QU!D basket — the lender is external,
//! and that is the reason it must be.
//!
//! 🔴 **A SEIZURE IS NOT ISOLATED TO ONE LP.** Under §POOL-VENUE the venue runs ONE
//! Morpho position under `address(this)` and slices it by unit share
//! (`LevVenueBase.positionOf` / `_unitSlice`), so a seizure hits the pool and therefore
//! **every LP pro-rata**. Only the basket stays out of it.
//! ⇒ **THE CONSEQUENCE IS THAT THIS KEEPER MATTERS MORE, NOT LESS.** Were a liquidation
//! one LP's own problem, a keeper miss would cost that LP alone. Pooled, a miss is
//! socialised across the book, so "the venue's engine is a never-triggered backstop" is a
//! guarantee the keeper owes EVERY LP jointly. That is why the safety gate reads
//! [`PositionView::pool_ltv_bps`] — the aggregate Morpho actually liquidates on — and not
//! only the per-LP LTV.
//!
//! # The target is `L = 1/α`, never a pinned 2x
//! `α` = the realized range concavity (how √p-like the position is). Busy flow →
//! `α→0.5` → `L→2` (cancel the IL the flow created). Quiet → `α→1` → `L→1` (no leverage,
//! because there is no realized IL to cancel). Pinning `L=2` (ybamm's mistake) over-levers
//! in quiet regimes and drains the buffer; sizing to `α` is what bounds the tail. The LTV
//! form is `target_ltv = 1 − α`.
//!
//! ⚠️ **THE KEEPER DOES NOT MEASURE `α` — THE CONTRACT DOES.** `LevManager.ilTargetLtvBps`
//! publishes `1 − √(entry/now)` (i.e. `α = √(entry/now)`), which the loop reads into
//! [`PositionView::target_ltv_bps`] and treats as authoritative. [`il_target_ltv_bps`] is a
//! pure off-chain mirror of that same formula, for logging only, clamped at the 2× cap
//! (5000 bps).
//!
//! # OMNI triggers — the keeper is EVENT-DRIVEN, not just an LTV poller
//! A levered position must unwind on the right events, and — critically — an UNLEVERED LP's range
//! withdrawal can force a chained unwind of OTHER levered LPs (the same shape as the LN-LP chained
//! unwind). So the loop reacts to a UNION of triggers, not just "LTV crossed a range":
//!   1. **Levered LP withdraws / closes** (`Quid`/`LevManager` close events) → `closeLev` that LP: fully
//!      unwind its leverage (repay debt by selling collateral, return weETH) BEFORE the range withdrawal
//!      settles, so it never exits half-levered.
//!   2. **ANY LP withdraws from the range** (levered or not) → `rangeETH` drops → every OTHER levered LP's
//!      IL target (`1 − √(entry/now)`) and LTV shift; re-evaluate the whole open set and
//!      `rebalance`/`cascadeDelever` the ones pushed out of range. A big unlevered exit is exactly the
//!      "correlated" event the cascade was built for.
//!   3. **Price move** (Chainlink/range-TWAP update) → the IL target moved → rebalance toward it (subject to
//!      the lazy/dwell policy below — never chase noise).
//!   4. **Venue VaultStatus / LTV breach** → the safety de-lever (this module's `decide`).
//! Sources: subscribe to `LevManager` Opened/Closed + `Quid` Withdraw + the venue's status feed + a price
//! feed + a heartbeat; on any of them, recompute the open set and act. Idempotent toward target, so
//! overlapping triggers simply re-converge.
//!
//! # Lazy/dwell policy — do NOT realize IL on noise (conservation)
//! Continuously chasing `1 − √(entry/now)` LOSES on mean-reverting moves (buy-high/sell-low churn), proven
//! in evm/test/LevYbPnl.t.sol. The keeper only rebalances toward the IL target when the move is BOTH past
//! the range AND has persisted (a dwell window) — so chop doesn't trigger it. The SAFETY de-lever (trigger
//! 4) has NO dwell (a liquidation-imminent breach acts immediately); only the IL-TARGET up-leg is lazy.
//!
//! # Hard bounds are physics, never heuristics (mirrors `quid-hop::rebalancer`)
//!   * **Venue liquidation LTV** — the keeper de-levers before `venue_liq − margin`.
//!     This bound is the venue's, not ours; we only stay clear of it.
//!   * **Unlocked deliverable-buffer floor** — locked collateral can't be handed to
//!     a swapper, so the keeper RE-levers only while a floor of unlocked weETH
//!     remains ([`PositionView::deliverable_floor_ok`]). Never lever to 100%.
//!   * **Minimum economic rebalance** — skip a move smaller than
//!     [`LevKeeperConfig::min_rebalance_usd`] so gas doesn't dominate.
//! When a needed de-lever can't be sourced, the loop must `warn!` loudly (the
//! position is handed to the venue backstop), never a silent no-op.

/// Tuning for the keeper loop. Defaults are conservative; every field is a bound,
/// not a tuned trigger.
#[derive(Clone, Copy, Debug)]
pub struct LevKeeperConfig {
    /// Poll cadence. Not a cooldown — the on-chain `rebalance` is idempotent toward
    /// target, so re-polling a mid-flight state simply re-converges.
    pub poll_interval_secs: u64,
    /// Tolerance around the `L=1/α` target before we rebalance (avoids churn on noise).
    pub target_range_bps: u32,
    /// How far BELOW the venue's liquidation LTV we force an urgent de-lever. This is
    /// the margin that guarantees the venue's liquidation engine never fires.
    pub safety_margin_bps: u32,
    /// Skip rebalances whose notional is below this (gas-vs-benefit floor), 6-dec USD.
    pub min_rebalance_usd: u64,
}

impl Default for LevKeeperConfig {
    fn default() -> Self {
        // 5 min poll; ±3% range around target; force de-lever 15% LTV below venue liq;
        // skip <$50 moves.
        LevKeeperConfig {
            poll_interval_secs: 300,
            target_range_bps: 300,
            safety_margin_bps: 1500,
            min_rebalance_usd: 50_000_000, // $50 @ 6-dec
        }
    }
}

/// One position's on-chain snapshot, as the loop reads it (LevManager + the venue).
#[derive(Clone, Copy, Debug)]
pub struct PositionView {
    /// VENUE-SAFETY LTV in bps = debt / ACTUAL collateral (`LevManager.getCurrentLtvBps`). Used ONLY for the
    /// liquidation-avoidance track — it must track the venue's own health basis.
    pub current_ltv_bps: u32,
    /// IL-TARGET LTV in bps = debt / E0 (the FIXED range+buffer base) (`LevManager.ilLtvBps`). The IL-track
    /// compares THIS to `target_ltv_bps`, consistent with the on-chain debt=E0·t sizing — using the
    /// actual-collateral LTV here would re-settle at the 1/(1−t) over-hedge.
    pub il_ltv_bps: u32,
    /// The CONTRACT's IL target LTV in bps = `1 − √(entry/now)` (read from `LevManager.ilTargetLtvBps`).
    /// Authoritative — the keeper does NOT compute it; [`il_target_ltv_bps`] only mirrors it for logging.
    pub target_ltv_bps: u32,
    /// §POOL-VENUE — THE LTV THE VENUE ACTUALLY LIQUIDATES ON (`LevManager.poolLtvBps`): debt and
    /// collateral of the ONE pooled Morpho position, not of any single LP.
    ///
    /// 🔴 THIS FIELD EXISTS BECAUSE THE KEEPER'S SAFETY GATE WAS READING THE WRONG NUMBER. The venue
    /// holds a single position under `address(this)`, so Morpho's health check is on the AGGREGATE —
    /// an LP can be individually comfortable while the pool sits one tick from liquidation, and a
    /// keeper gated on `current_ltv_bps` alone HOLDS straight through it. That is the
    /// no-liquidation guarantee failing OPEN: nothing reverts and nothing logs until the pool is
    /// seized, and then it lands on EVERY LP pro-rata rather than on the one that caused it.
    ///
    /// ⚠️ It does not replace `current_ltv_bps`. This is the TRIGGER (is the book in danger); that
    /// is the TARGET (which LP is dragging it). `decide` takes the max, so neither can mask the
    /// other and the old per-LP behaviour is preserved rather than swapped out.
    pub pool_ltv_bps: u32,
    /// The EXTERNAL venue's liquidation LTV in bps (e.g. weETH E-mode ≈ 9000).
    pub venue_liq_ltv_bps: u32,
    /// `collateral − debt` notional, 6-dec USD — sizes the rebalance + the economic floor.
    pub collateral_usd: u64,
    /// True while a floor of UNLOCKED weETH remains. Re-lever only when set.
    pub deliverable_floor_ok: bool,
    /// DWELL: true once the position has sat out-of-range for the dwell window. Gates the NON-urgent
    /// IL-target rebalance so chop (mean-reverting moves) can't churn IL into permanent rebalancing loss
    /// (the conservation result proven in evm/test/LevYbPnl.t.sol). The URGENT safety de-lever ignores it.
    pub move_persisted: bool,
    /// The LP's REDEEMABLE (mature-only) QUID, valued 6-dec USD. When a position is near venue
    /// liquidation and the LP holds mature QUID, the keeper repays debt by redeeming that QUID FIRST —
    /// protecting the LP's collateral (their ETH/BTC exposure) instead of selling it. Redeem is mature-only
    /// on-chain, so UNMATURED QUID is never touched (no par-burn-for-debt abuse — audit 2026-07-03).
    pub mature_quid_usd: u64,
    /// TRUE when the position's collateral is WBTC (the `AaveV3Venue` WBTC-fallback route),
    /// FALSE for native channel-vBTC. WBTC-mode positions rebalance via ONE atomic on-chain `rebalanceWbtc`
    /// (flash-repay-first de-lever OR fold-up, decided on-chain) — no acquirer, no async vBTC legs — so the
    /// keeper routes them past the withdraw→sell→repay sequence. Always FALSE on the ETH keeper.
    pub wbtc_mode: bool,
}

/// What the keeper decides to do this tick. The loop maps each to a LevManager call:
/// `DeLever{urgent}` → `deleverOne` (or `cascadeDelever` for a batch); `ReLever` →
/// `rebalance` (up-leg); `Hold` → nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeeperAction {
    Hold,
    /// Move LTV DOWN to `to_ltv_bps`. `urgent` ⇒ approaching venue liquidation: this
    /// is the path that keeps the venue's engine from ever firing — it must win over
    /// every other consideration and never be skipped by the economic floor.
    DeLever { to_ltv_bps: u32, urgent: bool },
    /// Move LTV UP to `to_ltv_bps` (rebuild the buffer). Gated on `deliverable_floor_ok`.
    ReLever { to_ltv_bps: u32 },
    /// Near liquidation AND the LP holds mature QUID → repay `repay_usd` of debt by redeeming that QUID
    /// (mature-only), PRESERVING the LP's collateral. Safety-critical like an urgent de-lever; a next tick
    /// re-evaluates and falls back to `DeLever` (sell collateral) only for any residual QUID can't cover.
    ProtectFromQuid { repay_usd: u64 },
}

/// Mirror of the on-chain IL target `1 − √(entry/now)` in bps (clamped to the 2× cap = 5000), for the
/// keeper's logging/prediction only — the CONTRACT is authoritative. Flat/down ⇒ 0 (no IL accrued).
pub fn il_target_ltv_bps(entry_price: f64, now_price: f64) -> u32 {
    if !(entry_price > 0.0 && now_price > entry_price) {
        return 0;
    }
    let il = 1.0 - (entry_price / now_price).sqrt(); // 1 − 1/√r
    (((il * 10_000.0).round() as i64).clamp(0, 5000)) as u32
}

/// PURE decision: given a position snapshot + config, what to do. Priority order is the safety contract:
///   1. URGENT de-lever if LTV is within `safety_margin` of venue liquidation — the no-liquidation-engine
///      guarantee; it overrides the economic floor AND the dwell (a liquidation can't wait for a dwell).
///   2. NON-urgent rebalance (down toward target, or up to it) — only when the move has PERSISTED
///      (`move_persisted`); this is the lazy/anti-churn policy that stops chop realizing impermanent IL.
///   3. Otherwise hold.
pub fn decide(v: &PositionView, cfg: &LevKeeperConfig) -> KeeperAction {
    // (1) Safety first — immediate, ignores both the economic floor and the dwell.
    // §POOL-VENUE — GATED ON THE MAX OF THE POOL'S LTV AND THIS LP'S. The pool figure is the one
    // Morpho liquidates on, so it is what the no-liquidation guarantee is actually about; the per-LP
    // figure identifies the position dragging it and is what we then de-lever. Taking the MAX means
    // neither can mask the other: a systemic build-up fires even when this LP looks fine, and a
    // single blown-out LP still fires even when the pool average hides it. Strictly a superset of
    // the previous per-LP-only gate, so this cannot make the keeper act LESS often.
    let urgent_threshold = v.venue_liq_ltv_bps.saturating_sub(cfg.safety_margin_bps);
    if v.pool_ltv_bps.max(v.current_ltv_bps) >= urgent_threshold {
        // PROTECT the LP's collateral first — if they hold mature QUID, repay debt by redeeming it
        // (mature-only; unmatured is untouchable on-chain, so no par-burn abuse) instead of selling their
        // ETH/BTC. Repay up to what QUID covers; a next tick re-evaluates and de-levers only the residual.
        if v.mature_quid_usd > 0 {
            let repay = repay_to_target_usd(v).min(v.mature_quid_usd);
            if repay > 0 {
                return KeeperAction::ProtectFromQuid { repay_usd: repay };
            }
        }
        return KeeperAction::DeLever { to_ltv_bps: v.target_ltv_bps, urgent: true };
    }

    // (2) Everything below is the IL-TARGET track — LAZY: never act on a move that hasn't persisted, so
    // mean-reverting noise can't churn IL into permanent rebalancing loss (conservation, LevYbPnl.t.sol).
    if !v.move_persisted {
        return KeeperAction::Hold;
    }
    let upper = v.target_ltv_bps.saturating_add(cfg.target_range_bps);
    let lower = v.target_ltv_bps.saturating_sub(cfg.target_range_bps);

    if v.il_ltv_bps > upper {
        if !economic(v, cfg) {
            return KeeperAction::Hold;
        }
        return KeeperAction::DeLever { to_ltv_bps: v.target_ltv_bps, urgent: false };
    }
    if v.il_ltv_bps < lower && v.deliverable_floor_ok && economic(v, cfg) {
        return KeeperAction::ReLever { to_ltv_bps: v.target_ltv_bps };
    }
    KeeperAction::Hold
}

/// Debt (6-dec USD) to repay to move `debt/collateral` from `current_ltv` → `target_ltv`. `collateral_usd`
/// is net-equity (`collateral − debt` = `collateral·(1 − cur)`), so `collateral = net/(1 − cur)` and
/// `repay = collateral·(cur − tgt)`. Sizes the QUID protect; capped at the LP's mature QUID by the caller.
fn repay_to_target_usd(v: &PositionView) -> u64 {
    let cur = v.current_ltv_bps as u64;
    let tgt = v.target_ltv_bps as u64;
    if cur <= tgt || cur >= 10_000 { return 0; }
    let collateral = (v.collateral_usd.saturating_mul(10_000)) / (10_000 - cur);
    (collateral.saturating_mul(cur - tgt)) / 10_000
}

/// Does the LTV gap to target move at least `min_rebalance_usd` of debt? `gap_bps`
/// of `collateral_usd`. Urgent de-levers bypass this (safety > gas).
fn economic(v: &PositionView, cfg: &LevKeeperConfig) -> bool {
    let gap_bps = v.il_ltv_bps.abs_diff(v.target_ltv_bps) as u64;
    let move_usd = (v.collateral_usd.saturating_mul(gap_bps)) / 10_000;
    move_usd >= cfg.min_rebalance_usd
}

// ════════════════════════════ the loop (one set.spawn task) ════════════════════════════

/// Raw 20-byte EVM address of an LP position (the concrete EVM impl converts to/from its own type).
pub type LpAddr = [u8; 20];

/// The on-chain surface the loop needs. The concrete impl wraps `DaemonEvm`/`LevManager` eth_calls +
/// sends; mocked in tests so the loop LOGIC is verified without a live chain. `open_positions` is the
/// union the omni-triggers feed (it re-reads every pass, so a withdrawal/price-move/breach is caught on
/// the next tick — a poll covers all triggers; event subscriptions are a latency optimization on top).
#[allow(async_fn_in_trait)]
pub trait LevKeeperEvm {
    async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>>;
    async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView>;
    async fn rebalance(&self, lp: LpAddr) -> anyhow::Result<()>;
    /// §E357 — `routes[i]` is LP `i`'s volatile-leg router calldata, built OFF-CHAIN.
    /// ⚠️ An empty route is refused on chain, so a caller with none must not send the batch.
    async fn cascade_delever(&self, lps: &[LpAddr], routes: &[Vec<u8>]) -> anyhow::Result<()>;
    /// BATCH IL-target rebalance: hold every out-of-range LP in ONE tx (`rebalanceMany`). On-chain
    /// fault-tolerant + syncs each LP's range slice internally, so no per-LP sync follow-up is needed.
    async fn rebalance_many(&self, lps: &[LpAddr], routes: &[Vec<u8>]) -> anyhow::Result<()>;
    /// Reconcile `lp`'s LEVERED range slice to its live net-equity (`Quid.syncLev`). Called after ANY
    /// position change (rebalance/de-lever) so the fee lane (`levPooled`) tracks the equity promptly instead
    /// of waiting for the next external poke. Permissionless on-chain, so a failure is non-fatal — the slice
    /// just lags until the next tick re-syncs.
    async fn sync_lev(&self, lp: LpAddr) -> anyhow::Result<()>;
    /// Protect `lp` by repaying `repay_usd` (6-dec USD) of its debt from the LP's MATURE QUID. The impl
    /// composes EXISTING on-chain calls — redeem mature QUID → the venue stable → `venue.repay` — so no new
    /// contract path and (redeem being mature-only) unmatured QUID is NEVER burned at par for debt. Preserves
    /// the LP's collateral vs a de-lever sale.
    async fn protect_from_quid(&self, lp: LpAddr, repay_usd: u64) -> anyhow::Result<()>;
}

// ════════════════════════ compound crank — fees-on-fees for EVERY plain ETH LP ════════════════════════
//
// A passive ETH LP (never touches its position) doesn't compound its owed token-leg trading fees — those
// stay pending until the LP itself acts. `Quid.compound(lp)` folds them into the LP's `pooled` (more range
// depth → more earning) permissionlessly, so the keeper can do it FOR every LP. The crank is SELF-FUNDING:
// `Quid.compound` reimburses the caller's gas as a native-ETH tip skimmed from the LP's OWN harvested leg
// (grief-capped ≤ half the harvest), so the operator fronts NO gas — the exact "no operator subsidy"
// shape. We therefore crank an LP iff the tip will actually cover the gas: the contract caps the tip at
// `gasprice·COMPOUND_GAS` AND at half the harvest, so break-even is `pending/2 ≥ gasprice·COMPOUND_GAS`.
// Below that we skip (the fee stays pending and folds in later — a bigger crank, or when the LP acts).

/// Conservative gas a `compound(address)` crank burns on-chain — MIRRORS `Quid.COMPOUND_GAS` (the tip the
/// contract pays is capped at `gasprice · COMPOUND_GAS`). Keep in sync with the Solidity constant.
///
/// §E46/E51 (2026-08-04) — RAISED 140_000 → 200_000 IN LOCKSTEP WITH `Quid.sol:1504`. The Solidity
/// side was raised because the crank MEASURED 172,299 gas against a 140,000 basis, and this mirror was
/// left behind for one commit. That desync is not harmless and not symmetric: with the tip capped at
/// 200k·gasprice but the gate still asking 140k, every LP whose `pending/2` fell BETWEEN the two
/// thresholds passed the gate, got a tip of `pending/2` (< the ~172k the crank actually burns) and the
/// KEEPER ATE THE DIFFERENCE. `check-client-abis.py` cannot catch this — the ABI is unchanged; only a
/// hardcoded number in another language moved. Change one, change both.
pub const COMPOUND_GAS: u128 = 200_000;

/// The self-funding gate: does the on-chain tip cover this crank's gas? `Quid` caps the tip at BOTH
/// `gasprice · COMPOUND_GAS` and half the harvest, so the caller only breaks even when
/// `pending/2 ≥ gasprice · COMPOUND_GAS`. This is what makes the keeper subsidy-free — it cranks exactly
/// the LPs whose fees pay for the crank, and lets the rest keep accruing until they do.
pub fn compound_pays_for_itself(pending_wei: u128, gas_price_wei: u128) -> bool {
    pending_wei / 2 >= gas_price_wei.saturating_mul(COMPOUND_GAS)
}

/// The on-chain surface the compound sweep needs. Concrete impl = the same [`DaemonLevKeeper`] arm (it
/// already holds `range`); verified against a real mainnet fork, never a mock.
#[allow(async_fn_in_trait)]
pub trait CompoundEvm: Send + Sync + 'static {
    /// Every plain ETH LP address ever seen — deduped `Quid.Deposit(_, owner, …)` owners.
    async fn eth_lps(&self) -> anyhow::Result<Vec<LpAddr>>;
    /// `(pending token-leg WETH-wei owed to `lp`, current gas price wei)` — one round-trip keeps it lean.
    async fn pending_and_gas(&self, lp: LpAddr) -> anyhow::Result<(u128, u128)>;
    /// `Quid.compound(lp)` — folds the owed leg into `pooled`; the tip self-funds the caller's gas.
    async fn compound(&self, lp: LpAddr) -> anyhow::Result<()>;
}

/// One compound sweep: crank every plain ETH LP whose pending fees cover the crank's own gas. Fully
/// fault-tolerant (one LP's failing read/crank never aborts the sweep) and idempotent (a cranked LP's
/// pending rebaselines to ~0, so the next sweep skips it until it earns enough to clear the gate again).
pub async fn compound_tick<E: CompoundEvm>(evm: &E) -> anyhow::Result<()> {
    for lp in evm.eth_lps().await? {
        match evm.pending_and_gas(lp).await {
            Ok((pending, gas)) if compound_pays_for_itself(pending, gas) => {
                if let Err(e) = evm.compound(lp).await {
                    tracing::warn!(?lp, error = %e, "compound crank failed; retries next tick");
                }
            }
            Ok(_) => {} // below the self-funding floor — leave it pending (folds in on a later, bigger crank)
            Err(e) => tracing::warn!(?lp, error = %e, "compound pending/gas read failed; skipping this LP this tick"),
        }
    }
    Ok(())
}

/// Per-position dwell timer → the `move_persisted` flag (the lazy/anti-churn policy). Resets on
/// return-to-range so a reversal can't leave a stale "persisted" (don't realize impermanent IL).
#[derive(Default)]
pub struct DwellTracker {
    first_out: std::collections::HashMap<LpAddr, u64>,
}
impl DwellTracker {
    pub fn persisted(&mut self, lp: LpAddr, out_of_range: bool, now_secs: u64, dwell_secs: u64) -> bool {
        if !out_of_range {
            self.first_out.remove(&lp);
            return false;
        }
        let t0 = *self.first_out.entry(lp).or_insert(now_secs);
        now_secs.saturating_sub(t0) >= dwell_secs
    }
}

/// #9/#89: the ONE out-of-range predicate — shared by BOTH keeper loops (ETH `tick` + BTC `btc_tick`) so the
/// dwell/anti-churn basis can never drift between the two rails. `pub(crate)` so `lev_keeper_btc` reuses it
/// instead of its own byte-identical copy. Tracks the IL-target range, not venue-safety (the urgent leg keys off
/// safety separately in `decide`).
pub(crate) fn out_of_range(v: &PositionView, cfg: &LevKeeperConfig) -> bool {
    let upper = v.target_ltv_bps.saturating_add(cfg.target_range_bps);
    let lower = v.target_ltv_bps.saturating_sub(cfg.target_range_bps);
    v.il_ltv_bps > upper || v.il_ltv_bps < lower // dwell tracks the IL-target basis, not venue-safety
}

/// ONE pass — split out for deterministic testing (no sleep, explicit `now`). Reads every open position,
/// applies the dwell + `decide`, rebalances the lazy ones individually and BATCHES the urgent de-levers
/// into a single `cascadeDelever` (riskiest-first is the venue/keeper's ordering concern).
pub async fn tick<E: LevKeeperEvm>(
    evm: &E, cfg: &LevKeeperConfig, dwell: &mut DwellTracker, now_secs: u64, dwell_secs: u64,
) -> anyhow::Result<()> {
    let lps = evm.open_positions().await?;
    // Pass 1 — classify every position, FAULT-TOLERANT: one LP's failing read must NOT abort the tick, or a
    // near-liquidation elsewhere would wait a whole poll interval (and a persistently-reverting LP would stall
    // the keeper forever, defeating the no-venue-liquidation guarantee).
    let mut urgent: Vec<LpAddr> = Vec::new();
    let mut protect: Vec<(LpAddr, u64)> = Vec::new(); // (lp, repay_usd) — QUID-protect, collateral-preserving
    let mut rebal: Vec<LpAddr> = Vec::new();
    for lp in lps {
        let mut v = match evm.position_view(lp).await {
            Ok(v) => v,
            Err(e) => { tracing::warn!(?lp, error = %e, "position_view failed; skipping this LP this tick"); continue }
        };
        v.move_persisted = dwell.persisted(lp, out_of_range(&v, cfg), now_secs, dwell_secs);
        match decide(&v, cfg) {
            KeeperAction::ProtectFromQuid { repay_usd } => protect.push((lp, repay_usd)),
            KeeperAction::DeLever { urgent: true, .. } => { urgent.push(lp); }
            KeeperAction::DeLever { urgent: false, .. } => { rebal.push(lp); }
            KeeperAction::ReLever { .. } => rebal.push(lp),
            KeeperAction::Hold => {}
        }
    }
    // QUID-protect FIRST — it's the collateral-preserving safety action, so run it before selling any
    // collateral. Each independent + fault-tolerant; a failure just falls to the de-lever/backstop next tick.
    for (lp, repay) in &protect {
        if let Err(e) = evm.protect_from_quid(*lp, *repay).await {
            tracing::warn!(?lp, error = %e, "protect_from_quid failed; will de-lever/backstop next tick");
        } else if let Err(e) = evm.sync_lev(*lp).await {
            tracing::warn!(?lp, error = %e, "syncLev after protect failed; slice lags till next tick");
        }
    }
    // FLUSH URGENTS FIRST, unconditionally — the no-liquidation guarantee can't queue behind non-urgent work.
    if !urgent.is_empty() {
        // §C2.1 — **THE GAP THIS COMMENT DESCRIBED IS CLOSED, AND NOT BY BUILDING WHAT IT ASKED
        // FOR.** It read: *"ROUTES ARE NOT SOURCED YET. `oneinch.rs::fetch_swap` needs a key; the
        // keyless path is client-side discovery over multicall and is not built"* — so this batch
        // was N guaranteed `NoVolatileRoute` reverts and the urgent track could never fire. Route
        // discovery was never buildable: 1inch calldata embeds its own `amount` and every amount is
        // computed on-chain, so a fetched route is stale before it lands. `cascade_delever` now
        // sends a POOL WORD per LP, which has no amount in it and needs no API and no key.
        // §SESS-73 — `&[]` here means "the impl plans them"; it no longer means "no route".
        if let Err(e) = evm.cascade_delever(&urgent, &[]).await {
            tracing::warn!(error = %e, "cascade_delever failed; the un-saved positions fall to the venue backstop");
        }
        for lp in &urgent {
            if let Err(e) = evm.sync_lev(*lp).await {
                tracing::warn!(?lp, error = %e, "syncLev after cascade failed; slice lags till next tick");
            }
        }
    }
    // Then the non-urgent IL-target rebalances — the fleet holds the whole book at target in ONE `rebalanceMany`
    // tx, instead of N per-LP txs. On-chain it's fault-tolerant (a reverting LP is skipped) and syncs each
    // LP's range slice internally, so no per-LP syncLev follow-up is needed here.
    if !rebal.is_empty() {
        let rebal_routes: Vec<Vec<u8>> = Vec::new();
        if let Err(e) = evm.rebalance_many(&rebal, &rebal_routes).await {
            tracing::warn!(error = %e, "rebalance_many failed; retrying next interval");
        }
    }
    Ok(())
}

/// The keeper task — one `set.spawn(run_lev_keeper(...))` in the quid-bridge daemon `JoinSet`. Polls every
/// `poll_interval_secs`; a failed tick is logged, never fatal (the next tick re-converges — idempotent
/// toward target). `dwell_secs` is the lazy window for the IL-target track.
pub async fn run_lev_keeper<E: LevKeeperEvm + CompoundEvm>(evm: E, cfg: LevKeeperConfig, dwell_secs: u64) -> anyhow::Result<()> {
    let mut dwell = DwellTracker::default();
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(cfg.poll_interval_secs.max(1))).await;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Err(e) = tick(&evm, &cfg, &mut dwell, now, dwell_secs).await {
            tracing::warn!(error = %e, "lev_keeper tick failed; retrying next interval");
        }
        // Same cadence, same task: fold every passive ETH LP's owed fees into its depth (self-funding, so
        // no operator gas). Independent of the lev arm — a failure here never blocks the safety loop above.
        if let Err(e) = compound_tick(&evm).await {
            tracing::warn!(error = %e, "compound_tick failed; retrying next interval");
        }
    }
}

// ════════════════════════════ concrete EVM binding (the live keeper arm) ════════════════════════════
use crate::abi::{addr_word, selector4, u64_word, word_to_lpaddr, word_to_uint};
use crate::client::{eth_call_raw, JsonRpcEvmClient, TxSigner};
use crate::transport::JsonRpc;
use alloy_primitives::{Address, U256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Concrete [`LevKeeperEvm`] over the daemon's signing EVM client: reads `LevManager` views via `eth_read`,
/// writes `rebalance`/`cascadeDelever`/`syncLev` via `send_tx`. The client is blocking JSON-RPC, so each call
/// is wrapped in `spawn_blocking` (a 5-min poll makes that cost irrelevant). Runtime-provable only against a
/// deployed chain; the calldata encoding is unit-tested below.
pub struct DaemonLevKeeper<R: JsonRpc, S: TxSigner> {
    pub evm: Arc<JsonRpcEvmClient<R, S>>,
    pub lev_manager: Address,
    pub range: Address,
    /// Aux (redemption entry) + QUID/Basket (mature-balance reads). Together they enable QUID-protect:
    /// the mature-QUID read is GATED on `signer == lp`, so these matter only for a self-hosted LP keeper.
    pub quid: Address,
    /// The weETH market's liquidation LTV (bps) — a deployment constant; the safety margin comes off it.
    pub venue_liq_ltv_bps: u32,
    pub gas_limit: u64,
    /// Block to scan `Quid.Deposit` logs from when enumerating ETH LPs for the compound crank (the Quid
    /// deploy block). 0 = genesis (correct but wasteful over a long chain); set it to the deploy height.
    pub lp_scan_from: u64,
}

/// Chunk size for the `Quid.Deposit` log scan (L-4: a single huge range trips provider caps).
const LP_LOG_SPAN: u64 = 10_000;

// ABI-word helpers (`addr_word`, `u64_word`, `selector4`, `word_to_lpaddr`) now live
// in `crate::abi`; imported above and shared with `lev_keeper_btc`.

impl<R: JsonRpc + Send + Sync + 'static, S: TxSigner> LevKeeperEvm for DaemonLevKeeper<R, S> {
    async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>> {
        let (evm, lm) = (self.evm.clone(), self.lev_manager);
        tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<LpAddr>> {
            let n: u64 = word_to_uint(&evm.eth_read(lm, "openLevCount()", None)?, "openLevCount")?;
            let mut out = Vec::with_capacity(n as usize);
            for i in 0..n {
                out.push(word_to_lpaddr(&evm.eth_read(lm, "openLpAt(uint256)", Some(&u64_word(i)))?)?);
            }
            Ok(out)
        })
        .await?
    }

    async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView> {
        let (evm, lm, vliq_cfg, quid) = (self.evm.clone(), self.lev_manager, self.venue_liq_ltv_bps, self.quid);
        tokio::task::spawn_blocking(move || -> anyhow::Result<PositionView> {
            let a = addr_word(lp);
            let cur: u32 = word_to_uint(&evm.eth_read(lm, "getCurrentLtvBps(address)", Some(&a))?, "getCurrentLtvBps")?;
            let tgt: u32 = word_to_uint(&evm.eth_read(lm, "ilTargetLtvBps(address)", Some(&a))?, "ilTargetLtvBps")?;
            // IL-target LTV (debt/E0) — the basis the IL-track compares to `tgt`, consistent with the on-chain
            // debt=E0·t sizing (getCurrentLtvBps above is debt/actual-collateral, used only for venue safety).
            let il_ltv: u32 = word_to_uint(&evm.eth_read(lm, "ilLtvBps(address)", Some(&a))?, "ilLtvBps")?;
            let nraw = evm.eth_read(lm, "netEquityUsd(address)", Some(&a))?;
            let word = nraw.get(..32).ok_or_else(|| anyhow::anyhow!("netEquityUsd short return"))?;
            // USD 1e18 → 6-dec USD (the keeper's collateral_usd scale); saturate on absurd RPC values.
            let collateral_usd: u64 = (U256::from_be_slice(word) / U256::from(1_000_000_000_000u64))
                .try_into()
                .unwrap_or(u64::MAX);
            // PER-LP venue liquidation threshold (live) — pos(lp).venue → liqThresholdBps(), so it tracks an
            // Euler/Morpho LLTV ramp instead of going stale. Falls back to the configured constant on any read
            // failure (never widens the safety margin silently).
            let vliq: u32 = (|| -> Option<u32> {
                let pw = evm.eth_read(lm, "pos(address)", Some(&a)).ok()?;
                let venue = Address::from_slice(pw.get(12..32)?);
                let b = evm.eth_read(venue, "liqThresholdBps()", None).ok()?;
                word_to_uint::<u32>(&b, "liqThresholdBps").ok()
            })()
            .unwrap_or(vliq_cfg);
            // §POOL-VENUE — the aggregate the venue is liquidated on. A read failure falls back to
            // this LP's own LTV, which degrades to the OLD behaviour rather than to zero: zero would
            // silently disarm the systemic half of the safety gate, which is the failure this field
            // was added to close.
            // ⚠️ `.ok()` ON THE READ ITSELF, NOT ONLY ON THE DECODE. Written with `?` first, a
            // node that cannot serve `poolLtvBps()` (an older deployment, a reverting call)
            // would abort the WHOLE snapshot rather than degrade — turning a fail-safe into a
            // fail-stop. Caught by the anvil e2e, whose target had no such selector.
            let pool_ltv: u32 = evm.eth_read(lm, "poolLtvBps()", None).ok()
                .and_then(|w| word_to_uint::<u32>(&w, "poolLtvBps").ok())
                .unwrap_or(cur);
            Ok(PositionView {
                current_ltv_bps: cur,
                pool_ltv_bps: pool_ltv,
                il_ltv_bps: il_ltv,
                target_ltv_bps: tgt,
                venue_liq_ltv_bps: vliq,
                collateral_usd,
                // The on-chain rebalance enforces the anti-MEV floor + position caps, so re-lever is always
                // safe to attempt; the contract no-ops/clamps if there's nothing to do.
                deliverable_floor_ok: true,
                move_persisted: false, // set by the loop's DwellTracker, not read from chain
            wbtc_mode: false,      // the ETH keeper is never WBTC-collateral (weETH/WETH venues)
                // mature (redeemable) QUID for THIS lp -- but ONLY when the EVM signer IS this lp, i.e. the
                // enclave is currently keyed/signing FOR this lp (the fleet's existing per-LP enclave signer, same
                // as the hop fleet; or a self-provisioned LP). `redeem` burns msg.sender's QUID, so the signer
                // MUST be the lp; a node not keyed for this lp reads 0 and de-levers as before (fail-safe). Mature
                // = balanceOf − immatureBalanceOf (redeem is mature-only ⇒ unmatured untouchable ⇒ no par-burn).
                // 18-dec QUID (~1:1 USD) → 6-dec USD; any read failure ⇒ 0 (de-lever).
                mature_quid_usd: if evm.address().into_array() == lp {
                    (|| -> Option<u64> {
                        let bal = U256::from_be_slice(evm.eth_read(quid, "balanceOf(address)", Some(&a)).ok()?.get(..32)?);
                        let imm = U256::from_be_slice(evm.eth_read(quid, "immatureBalanceOf(address)", Some(&a)).ok()?.get(..32)?);
                        (bal.saturating_sub(imm) / U256::from(1_000_000_000_000u64)).try_into().ok()
                    })().unwrap_or(0)
                } else { 0 },
            })
        })
        .await?
    }

    async fn rebalance(&self, lp: LpAddr) -> anyhow::Result<()> {
        let (evm, lm, gas) = (self.evm.clone(), self.lev_manager, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            // minOut=0: the contract's oracle-derived MAX_SLIPPAGE floor protects every swap (anti-MEV).
            // §C2.1 — five STATIC head words (lp, minOut, dex, dex2, route-offset) followed by an
            // EMPTY `bytes route` tail, matching `rebalance(address,uint256,uint256,uint256,bytes)`
            // on `LevManager`. The venue words are real, so this call cannot revert
            // `NoVolatileRoute()` for want of a pool.
            let mut data = selector4("rebalance(address,uint256,uint256,uint256,bytes)");
            data.extend_from_slice(&addr_word(lp));
            data.extend_from_slice(&u64_word(0));
            // §SESS-47 — BOTH hops come from `plan_for_lp`, which resolves THIS LP's venue stable
            // and plans against it, so a USDT- or DAI-denominated venue gets a real hub word instead
            // of being pushed onto the contract's own Curve hub. A stable we cannot plan degrades to
            // `dex_word()` + a zero hub word, which is the contract's keyless `_hubHop` arm.
            let p = plan_for_lp(&evm, lm, lp, WETH_ADDR);
            data.extend_from_slice(&p.dex);
            data.extend_from_slice(&p.dex2);
            // §SESS-73 — and the ROUTE, which until now was a hand-written empty tail. `route_bytes`
            // emits the planned hops as `unoswap`/`unoswap2`/`unoswap3` calldata with ZEROS in the
            // token/amount/minReturn slots, because `_retarget` overwrites all three on-chain.
            let route = p.route_bytes();
            // `bytes route` — EMPTY, so the contract takes the keyless pool-word arm of the ladder.
            // A dynamic tail needs TWO words: the head offset (0xA0 = five 32-byte head slots) and
            // then a zero length. Supply a real 1inch `swap()` calldata here to take the full-venue
            // arm instead; the contract bounds either identically on the balance delta.
            data.extend_from_slice(&u64_word(0xA0));          // head offset: five 32-byte head slots
            data.extend_from_slice(&u64_word(route.len() as u64));
            let mut pad = route.clone();
            if pad.len() % 32 != 0 { pad.resize(pad.len() + (32 - pad.len() % 32), 0); }
            data.extend_from_slice(&pad);
            evm.send_tx(lm, data, gas)?;
            Ok(())
        })
        .await?
    }

    async fn cascade_delever(&self, lps: &[LpAddr], routes: &[Vec<u8>]) -> anyhow::Result<()> {
        // §SESS-19/§SESS-21 — the CLOSE leg carries `routes` all the way to `_deleverFlash`, so the
        // batch is widened to match. The hub word is planned PER-LP, because a batch spans venues and
        // one book-wide word would be wrong for most of it.
        let (evm, lm, gas, lps, routes) =
            (self.evm.clone(), self.lev_manager, self.gas_limit, lps.to_vec(), routes.to_vec());
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let plans: Vec<Plan> = lps.iter().map(|&lp| plan_for_lp(&evm, lm, lp, WETH_ADDR)).collect();
            // §SESS-73 — a route PER LP, from the same plan the words came from, so the two cannot
            // disagree about the venue. An empty one (a >3-hop plan has no encoding) simply leaves
            // that LP on the pool-word arm, which is the correct degrade rather than a truncation.
            // §SESS-73 — a CALLER-SUPPLIED route still wins; we only fill in what nobody supplied.
            // The parameter was previously dead (every caller passed empty), and silently ignoring it
            // now would be worse than leaving it dead: it would look like an override and not be one.
            let routes: Vec<Vec<u8>> = if routes.is_empty() {
                plans.iter().map(|p| p.route_bytes()).collect()
            } else { routes };
            let dexes: Vec<[u8; 32]> = plans.iter().map(|p| p.dex).collect();
            let dex2s: Vec<[u8; 32]> = plans.iter().map(|p| p.dex2).collect();
            evm.send_tx(lm, encode_batch5(CD_SIG, &lps, &dexes, &dex2s, &routes), batch_gas(gas, lps.len()))?;
            Ok(())
        })
        .await?
    }

    /// Hold the whole book at its IL target in ONE tx. Gas scales with the batch (each LP is a flash-repay
    /// or lever-up), capped below the block limit; the on-chain loop is fault-tolerant + syncs each LP internally.
    async fn rebalance_many(&self, lps: &[LpAddr], routes: &[Vec<u8>]) -> anyhow::Result<()> {
        // §S15/§SESS-47 — `dex2s` is planned PER-LP and sent non-empty. That matters twice over:
        //    a zero hub word sends a non-USDC venue down the contract's own `_hubHop` table arm, and
        //    on that arm `_stableToWethSor` bypasses `routedSwap` entirely — so an empty `dex2s`
        //    would disable the `bytes route` arm as well. (USDC is the exception by nature: it IS the
        //    hub, so `dex2 == 0` is correct for it and still reaches `route`.)
        let (evm, lm, gas, lps, routes) =
            (self.evm.clone(), self.lev_manager, self.gas_limit, lps.to_vec(), routes.to_vec());
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let plans: Vec<Plan> = lps.iter().map(|&lp| plan_for_lp(&evm, lm, lp, WETH_ADDR)).collect();
            // §SESS-73 — a route PER LP, from the same plan the words came from, so the two cannot
            // disagree about the venue. An empty one (a >3-hop plan has no encoding) simply leaves
            // that LP on the pool-word arm, which is the correct degrade rather than a truncation.
            // §SESS-73 — a CALLER-SUPPLIED route still wins; we only fill in what nobody supplied.
            // The parameter was previously dead (every caller passed empty), and silently ignoring it
            // now would be worse than leaving it dead: it would look like an override and not be one.
            let routes: Vec<Vec<u8>> = if routes.is_empty() {
                plans.iter().map(|p| p.route_bytes()).collect()
            } else { routes };
            let dexes: Vec<[u8; 32]> = plans.iter().map(|p| p.dex).collect();
            let dex2s: Vec<[u8; 32]> = plans.iter().map(|p| p.dex2).collect();
            evm.send_tx(lm, encode_batch5(RM_SIG, &lps, &dexes, &dex2s, &routes), batch_gas(gas, lps.len()))?;
            Ok(())
        })
        .await?
    }

    async fn sync_lev(&self, lp: LpAddr) -> anyhow::Result<()> {
        let (evm, range, gas) = (self.evm.clone(), self.range, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut data = selector4("syncLev(address)");
            data.extend_from_slice(&addr_word(lp));
            evm.send_tx(range, data, gas)?;
            Ok(())
        })
        .await?
    }

    async fn protect_from_quid(&self, lp: LpAddr, _repay_usd: u64) -> anyhow::Result<()> {
        // DELEGATED (autonomous layer): ONE constrained on-chain call. `LevManager.protectFromQuid(lp, minOut)`
        // redeems the LP's OWN opted-in QUID PRO-RATA (never force-drains a single basket stable — the *targeted*
        // redeem over-commits under leverage), consolidates the resulting mix into the venue's OWN loan token via
        // multi-route swaps (basket SOR, then UniV3 fallback so ANY borrowed stable has a route), repays the LP's
        // OWN Morpho debt, and refunds any excess / un-routable slice back to the LP. Funds can NEVER reach the
        // operator — by construction. The near-liq gate AND the amount (debt-derived, bounded by the LP's one-time
        // QUID allowance — the opt-in) live ON-CHAIN, so the fleet signer merely triggers it: no per-action quorum,
        // no cap. A revert is fail-safe ⇒ this tick falls back to the de-lever path. `minStableOut = 0`: the keeper
        // chooses WHEN, not the price; the consolidation rides deep stable pools (0.01% tiers) ⇒ negligible MEV.
        let (evm, lm, gas) = (self.evm.clone(), self.lev_manager, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut d = selector4("protectFromQuid(address,uint256)");
            d.extend_from_slice(&addr_word(lp));
            d.extend_from_slice(&U256::ZERO.to_be_bytes::<32>());   // minStableOut
            evm.send_tx(lm, d, gas)?;
            Ok(())
        })
        .await?
    }

}

impl<R: JsonRpc + Clone + Send + Sync + 'static, S: TxSigner> CompoundEvm for DaemonLevKeeper<R, S> {
    async fn eth_lps(&self) -> anyhow::Result<Vec<LpAddr>> {
        let (evm, range, from) = (self.evm.clone(), self.range, self.lp_scan_from);
        tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<LpAddr>> {
            let rpc = evm.rpc_handle();
            let tip = crate::eth_logs::eth_tip(&rpc)?;
            // topic0 = keccak256("Deposit(address,address,uint256,uint256)"); owner (the LP) is the 2nd
            // indexed arg → topics[2]. Chunked scan (L-4) so a long range can't trip provider log caps.
            let topic0 = format!(
                "0x{}",
                alloy_primitives::hex::encode(alloy_primitives::keccak256(
                    b"Deposit(address,address,uint256,uint256)"
                ))
            );
            let logs = crate::eth_logs::get_logs_chunked(&rpc, &range.to_string(), &topic0, from, tip, LP_LOG_SPAN)?;
            let mut seen = std::collections::HashSet::new();
            let mut out = Vec::new();
            for log in &logs {
                if let Some((topics, _, _)) = crate::eth_logs::log_fields(log) {
                    if topics.len() >= 3 {
                        let mut lp = [0u8; 20];
                        lp.copy_from_slice(&topics[2][12..32]); // 20-byte address, right-aligned in the word
                        if seen.insert(lp) {
                            out.push(lp);
                        }
                    }
                }
            }
            Ok(out)
        })
        .await?
    }

    async fn pending_and_gas(&self, lp: LpAddr) -> anyhow::Result<(u128, u128)> {
        let (evm, range) = (self.evm.clone(), self.range);
        tokio::task::spawn_blocking(move || -> anyhow::Result<(u128, u128)> {
            // pendingRewards(address) → (ethReward, usdReward); the token leg is the first 32-byte word.
            let ret = evm.eth_read(range, "pendingRewards(address)", Some(&addr_word(lp)))?;
            let word = ret.get(0..32).ok_or_else(|| anyhow::anyhow!("pendingRewards: short return"))?;
            let pending: u128 = word_to_uint(word, "pendingRewards.eth")?;
            let raw = evm.rpc_handle().call("eth_gasPrice", serde_json::json!([]))?;
            let gas: u128 = crate::hexutil::hex_u64(
                raw.as_str().ok_or_else(|| anyhow::anyhow!("eth_gasPrice: no result"))?,
            )
            .ok_or_else(|| anyhow::anyhow!("eth_gasPrice: bad hex"))? as u128;
            Ok((pending, gas))
        })
        .await?
    }

    async fn compound(&self, lp: LpAddr) -> anyhow::Result<()> {
        let (evm, range, gas) = (self.evm.clone(), self.range, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut data = selector4("compound(address)");
            data.extend_from_slice(&addr_word(lp));
            evm.send_tx(range, data, gas)?;
            Ok(())
        })
        .await?
    }

}

/// ABI-encode `cascadeDelever(address[] lps, uint256[] minOuts)` with `minOuts` all 0 (the contract's oracle
/// floor protects each swap). Two dynamic arrays: head = the two offsets, then each array (length + elements).
/// Per-tx gas for a batch = per-LP `gas` × count, capped below the block limit so a large book can't build an
/// unmineable tx (very large books should be chunked at the call site).
fn batch_gas(per_lp: u64, n: usize) -> u64 {
    ((per_lp as u128) * (n.max(1) as u128)).min(28_000_000) as u64
}

/// §C2.1 — **THE POOL WORD THE KEEPER SENDS.** 1inch AggregationRouterV6 `Address` encoding:
/// protocol in bits 253-255 (`1` = UniswapV3), pool in the low 160. The contract derives
/// `zeroForOne` from `tokenIn` itself, so ONE word serves the lever-up and the de-lever alike.
///
/// ⭐ **THIS IS THE GAP THAT JUST CLOSED.** While the entrypoints took `bytes route`, this keeper
/// encoded an EMPTY one and the code said so: *"the route is EMPTY here because nothing sources one
/// yet, and an empty route is refused on chain — so this call reverts until discovery lands."* Every
/// keeper tx reverted `NoVolatileRoute()`. Route DISCOVERY was the blocker because full calldata
/// embeds an `amount`, and the amounts are computed on-chain (a Curve output, a `borrow` return) —
/// unknowable off-chain to the wei. A POOL WORD has no amount in it, so there is nothing to
/// discover and nothing to go stale: the keeper names a venue and the contract sizes the trade.
///
/// Uniswap V3 WETH/USDC 0.05%, the deepest ETH/USDC pool on mainnet. Override with
/// `QUID_LEV_DEX_WORD` if a deeper venue appears; the contract validates the pool by executing
/// against it and bounds the result on its own balance delta either way.
/// The venue word, env-overridable. Returns the FULL 256-bit value as big-endian bytes because the
/// protocol bits live at 253-255 and cannot fit a u64.
pub fn dex_word() -> [u8; 32] {
    if let Ok(v) = std::env::var("QUID_LEV_DEX_WORD") {
        if let Ok(n) = v.parse::<u128>() {
            let mut w = [0u8; 32];
            w[16..].copy_from_slice(&n.to_be_bytes());
            return w;
        }
    }
    let mut w = [0u8; 32];
    // pool address in the low 160 bits
    w[12..].copy_from_slice(&hex_lit_pool());
    // protocol = UniswapV3 (1) at bits 253-255 => byte 0 gets 1 << 5
    w[0] |= 1 << 5;
    w
}

/// §C2.1 — the BTC keeper's venue. **A DIFFERENT POOL, AND IT MUST BE:** `_stableToWbtc` swaps
/// `USDC -> WBTC`, so pointing it at the WETH/USDC pool would send a token that pool does not hold.
/// Uniswap V3 WBTC/USDC 0.30% — `0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35`, whose `token0` is
/// WBTC (verified on-chain), which is why the contract deriving `zeroForOne` from `tokenIn` rather
/// than trusting a keeper bit matters here: the two pools have OPPOSITE orderings.
/// Override with `QUID_BTC_LEV_DEX_WORD`.
pub fn dex_word_wbtc() -> [u8; 32] {
    if let Ok(v) = std::env::var("QUID_BTC_LEV_DEX_WORD") {
        if let Ok(n) = v.parse::<u128>() {
            let mut w = [0u8; 32];
            w[16..].copy_from_slice(&n.to_be_bytes());
            return w;
        }
    }
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(&[0x99,0xac,0x8c,0xA7,0x08,0x7f,0xA4,0xA2,0xA1,0xFB,
                             0x63,0x57,0x26,0x99,0x65,0xA2,0x01,0x4A,0xBc,0x35]);
    w[0] |= 1 << 5;   // protocol = UniswapV3
    w
}

/// Uniswap V3 WETH/USDC 0.05% — `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`.
/// ═══════════════ §SESS-45 — JOINT VENUE SCORING (borrow cost + route cost) ═══════════════
///
/// ⭐ **THE TWO CHOICES INTERACT, SO THEY MUST BE SCORED TOGETHER.** The lever borrows a stable from a
///    venue and then swaps it to WETH. **The cheapest stable to borrow may carry the dearest swap
///    route**, so picking the venue on rate alone and the route on cost alone can lose to a pair that
///    is worse on both axes taken separately. §CHEAPEST-DOLLAR measured the spread at **33–414 bps**.
///
/// 🔑 **WHERE THIS IS LIVE, AND WHERE IT IS NOT — THIS IS NOT A PER-REBALANCE DECISION.**
///    `LevBase._openPos` **pins the venue on the FIRST open** and reverts `VenueNotPooled()` on any
///    second (`§POOL-VENUE`: *"One position means one venue"*). ⇒ for an EXISTING range the candidate
///    set is exactly one and there is nothing to score. **The decision point is the FIRST open of a
///    range**, where `allowedVenue` still holds many. Scoring per rebalance would be dead surface —
///    the same shape as `borrowRateRay` itself, which is implemented on every venue and has zero
///    callers.
///
/// ⚠️ **UNITS ARE THE TRAP THIS FUNCTION EXISTS TO NOT FALL INTO.** `ILevVenue.borrowRateRay` is
///    **RAY (1e27) PER YEAR** — Aave's unit — and the Morpho venue multiplies its WAD-per-second up to
///    match, with its own docblock warning that getting it wrong *"does not revert — it silently
///    reports a venue as ~3e7x cheaper."* A route cost is **one-off bps**. **A rate and a toll are not
///    comparable until a HORIZON is chosen**, which is why `horizon_days` is an explicit argument and
///    not a hidden constant.
/// ⛔ **AND IT LIVES OFF-CHAIN DELIBERATELY.** The on-chain guard is `allowedVenue[venue]`, enforced by
///    `requireOpenable` — a hacked keeper **cannot name a venue that is not allowlisted**. Choosing the
///    cheapest AMONG allowlisted venues is therefore free to be wrong, so it belongs here and needs no
///    new on-chain code.

/// One candidate: an allowlisted venue, its size-aware borrow rate, and the cost of routing the
/// stable it lends to the asset we actually want.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VenueQuote {
    pub venue: LpAddr,
    /// `borrowRateRay(extraBorrow)` at the size being borrowed. **RAY per YEAR.**
    pub borrow_rate_ray: u128,
    /// One-off cost of the swap this venue's stable implies, in bps of notional.
    pub route_cost_bps: u32,
    /// `false` when `borrowRateRay` reverted `VenueCannotFund()` — the venue cannot fund THIS size.
    /// ⚠️ **THE REVERT IS THE LIQUIDITY CHECK.** `borrowRateRay` refuses to price a draw it cannot
    ///    fund rather than returning *"a flattering number for a draw that cannot happen"*, so
    ///    fundability arrives for free with the rate and needs no separate depth call.
    pub fundable: bool,
}

/// Total expected cost in bps of notional over `horizon_days`: the one-off route toll plus the
/// borrow rate accrued over the holding period.
pub fn score_bps(q: &VenueQuote, horizon_days: u32) -> Option<u128> {
    if !q.fundable { return None; }
    // RAY/yr -> bps/yr: rate * 10_000 / 1e27, kept in u128 with the multiply first so a small rate
    // does not truncate to zero before it is scaled.
    let rate_bps_yr = q.borrow_rate_ray.checked_mul(10_000)? / 1_000_000_000_000_000_000_000_000_000u128;
    let carried = rate_bps_yr.checked_mul(horizon_days as u128)? / 365;
    Some(carried + q.route_cost_bps as u128)
}

/// The cheapest fundable venue over `horizon_days`, or `None` if none can fund the size.
/// Ties break on the LOWER route cost: a one-off toll is certain where a rate is a forecast.
pub fn pick_cheapest(qs: &[VenueQuote], horizon_days: u32) -> Option<(LpAddr, u128)> {
    let mut best: Option<(LpAddr, u128, u32)> = None;
    for q in qs {
        if let Some(s) = score_bps(q, horizon_days) {
            let better = match best {
                None => true,
                Some((_, bs, brc)) => s < bs || (s == bs && q.route_cost_bps < brc),
            };
            if better { best = Some((q.venue, s, q.route_cost_bps)); }
        }
    }
    best.map(|(v, s, _)| (v, s))
}

/// ═══════════════════════ §SESS-25 — THE ROUTE PLANNER ═══════════════════════
///
/// ⭐ **WHAT IT REPLACES.** `dex_word()` returns ONE hardcoded pool for EVERY pair. That is why
///    `dex_word_wbtc()` had to exist at all — its own note says pointing the WETH/USDC word at a
///    `USDC → WBTC` swap *"would send a token that pool does not hold."* Keying by PAIR removes the
///    need for per-asset twins and makes an unknown pair return **None** instead of a wrong pool.
///
/// 🔑 **THE PLANNER EMITS POOL WORDS, NEVER CALLDATA, AND THAT IS THE SECURITY PROPERTY.** A pool word
///    carries no amount, so it cannot go stale — *"our amounts are computed mid-transaction, so anything
///    that embeds its amount is stale by construction."* The contract owns `tokenIn`, `amountIn`, the
///    floor and the callee; the keeper owns only the venue choice, *"the one part it actually knows
///    better than we do."* ⇒ a compromised planner picks a worse VENUE and can do nothing else.
/// ⚠️ **NO DIRECTION BIT IS EMITTED, DELIBERATELY.** `_aggSwap` derives `zeroForOne` from `tokenIn` and
///    **discards whatever the keeper set** — *"the keeper names pools, never directions."* Emitting one
///    would be dead data that a reader could mistake for load-bearing.
/// ⚠️ **EVERY ROW WAS VERIFIED BY EXECUTION, NOT BY DOCUMENTATION** (`evm/test/PlannerVenues.t.sol`,
///    pinned fork). §SESS-22 measured 1inch's own bit table claiming Curve support while `proto=2` filled
///    **zero** on two real pools — so "the docs say it works" is not evidence here. **A row that does not
///    fill is not a row.**
pub const WETH_ADDR:   LpAddr = [0xC0,0x2a,0xaA,0x39,0xb2,0x23,0xFE,0x8D,0x0A,0x0e,0x5C,0x4F,0x27,0xeA,0xD9,0x08,0x3C,0x75,0x6C,0xc2];
pub const WBTC_ADDR:   LpAddr = [0x22,0x60,0xFA,0xC5,0xE5,0x54,0x2a,0x77,0x3A,0xa4,0x4f,0xBC,0xfe,0xDf,0x7C,0x19,0x3b,0xc2,0xC5,0x99];
pub const USDC_ADDR:   LpAddr = [0xA0,0xb8,0x69,0x91,0xc6,0x21,0x8b,0x36,0xc1,0xd1,0x9D,0x4a,0x2e,0x9E,0xb0,0xcE,0x36,0x06,0xeB,0x48];
pub const USDT_ADDR:   LpAddr = [0xdA,0xC1,0x7F,0x95,0x8D,0x2e,0xe5,0x23,0xa2,0x20,0x62,0x06,0x99,0x45,0x97,0xC1,0x3D,0x83,0x1e,0xc7];
pub const DAI_ADDR:    LpAddr = [0x6B,0x17,0x54,0x74,0xE8,0x90,0x94,0xC4,0x4D,0xa9,0x8b,0x95,0x4E,0xed,0xeA,0xC4,0x95,0x27,0x1d,0x0F];

// Uniswap V3 pools. `proto = 1` is the ONLY protocol id measured to fill.

/// A planned route. `dex2 == 0` means ONE hop.
/// ⚠️ **THE FIELD ORDER MIRRORS `SellCtx`, WHICH IS NOT THE HOP ORDER.** `_stableToWethSor` calls
///    `routedSwap(stable, weth, amt, floor, c.dex2, c.dex, route)` — *"hub hop FIRST"* — so **`dex2` is
///    the FIRST hop (stable→USDC) and `dex` is the SECOND (USDC→volatile)**. Naming them by position
///    would be clearer and would also silently disagree with the contract, so they are named to match it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub dex: [u8; 32],
    pub dex2: [u8; 32],
    /// §SESS-73 — the FULL ordered hop list, hop 1 first. `dex`/`dex2` stay for the legacy two-word
    /// entrypoints; this is what `route_bytes` encodes and it is not limited to two.
    pub hops: Vec<[u8; 32]>,
    /// §SESS-78 — pre-built calldata for a venue a pool word cannot spell, or empty. **PREFERRED
    /// over `hops` when present.** Reserved for the UniversalRouter/V4 path; NOT fetched from anyone.
    pub fetched: Vec<u8>,
}

/// 1inch unoswap-family selectors, by hop count. Kept here rather than imported so the keeper and the
/// contract can be diffed against each other by eye (`Interfaces.sol` holds the same three).
const SEL_UNOSWAP:  [u8; 4] = [0x83, 0x80, 0x0a, 0x8e];
const SEL_UNOSWAP2: [u8; 4] = [0x87, 0x70, 0xba, 0x91];
const SEL_UNOSWAP3: [u8; 4] = [0x19, 0x36, 0x74, 0x72];

impl Plan {
    /// ⭐ §SESS-73 — **THE ROUTE PRODUCER. THE THING THE WHOLE 1inch ARM WAS WAITING ON.**
    ///
    /// 🔴 §SESS-60 measured that the `bytes route` arm had **NO PRODUCER**: the keeper sent literal
    ///    empty routes at three sites and nothing in `quid-ln` fetched 1inch calldata at all. So every
    ///    byte of on-chain route-handling was reachable only by a human calling the entrypoint
    ///    directly. This closes that.
    ///
    /// ⭐ **AND IT NEEDS NO API KEY, NO NETWORK DEPENDENCY, AND CANNOT GO STALE — because the contract
    ///    overwrites the three fields that could.** `LevMath._retarget` rewrites `token`, `amount` and
    ///    `minReturn` with its own values before forwarding, so this emits **ZEROS** for all three.
    ///    ⇒ the calldata carries only VENUE CHOICE, which is the one thing an off-chain quote decides
    ///    better than the contract. **The staleness that justified pool words is not dodged here, it
    ///    is absent**: there is no amount in the bytes to be stale.
    /// ⚠️ **WHICH IS ALSO WHY THIS IS NOT MERELY POOL WORDS IN A LONGER COAT.** The two-word ABI can
    ///    express one or two hops and nothing else; this reaches `unoswap3`, so a third pool becomes
    ///    available without touching a single on-chain signature — the owner's *"no limit to how many
    ///    hops"*, delivered off-chain.
    /// ⛔ Returns EMPTY above 3 hops rather than truncating: `_retarget` whitelists exactly these three
    ///    selectors, so a 4-hop plan has no encoding and must fall back to the pool-word arm. **Silently
    ///    dropping a hop would route somewhere the planner did not price.**
    pub fn route_bytes(&self) -> Vec<u8> {
        // §SESS-78 — pre-built calldata wins when present. It is no more trusted than our own words:
        // the contract whitelists the selector and overwrites token/amount/receiver/floor either way.
        if !self.fetched.is_empty() { return self.fetched.clone(); }
        let sel = match self.hops.len() {
            1 => SEL_UNOSWAP,
            2 => SEL_UNOSWAP2,
            3 => SEL_UNOSWAP3,
            _ => return Vec::new(),
        };
        let mut d = Vec::with_capacity(4 + (3 + self.hops.len()) * 32);
        d.extend_from_slice(&sel);
        d.extend_from_slice(&[0u8; 32]);          // token     — overwritten by `_retarget`
        d.extend_from_slice(&[0u8; 32]);          // amount    — overwritten, computed on-chain
        d.extend_from_slice(&[0u8; 32]);          // minReturn — overwritten; the delta floor binds
        for w in &self.hops { d.extend_from_slice(w); }
        d
    }
}

/// The 256-bit word for a V3 pool: `proto=1` at bits 253-255, address in the low 160. No direction bit.
fn v3_word(pool: LpAddr) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(&pool);
    w[0] |= 1 << 5;                       // PROTO_UNIV3 = 1, at bits 253-255
    w
}

/// A pool holding exactly this unordered pair, or `None`.
/// Uniswap V3 factory and QuoterV2 — the two addresses that replace a hardcoded pool table.
const UNIV3_FACTORY: LpAddr = [0x1F,0x98,0x43,0x1c,0x8a,0xD9,0x85,0x23,0x63,0x1A,
                               0xE4,0xa5,0x9f,0x26,0x73,0x46,0xea,0x31,0xF9,0x84];
const QUOTER_V2:     LpAddr = [0x61,0xfF,0xE0,0x14,0xbA,0x17,0x98,0x9E,0x74,0x3c,
                               0x5F,0x6c,0xB2,0x1b,0xF9,0x69,0x75,0x30,0xB2,0x1e];
/// Every V3 fee tier. Which one is deepest is a fact about the pair AND THE SIZE, not a constant.
const FEE_TIERS: [u32; 4] = [100, 500, 3000, 10000];

/// Candidate intermediate tokens for a two-hop route. **A "hub" is only the middle token of a two-hop
/// route — it is not a protocol role.** USDC was the sole hub because `_hubRowOf`'s Curve rows are all
/// `<stable>/USDC`; USDT is here because it is the deepest dollar pair on V3 and, measured, the winner
/// alternates with the block. ⚠️ **Being a short list is fine BECAUSE IT IS PRICED, NOT TRUSTED** — an
/// unhelpful hub simply loses the comparison, where an unhelpful TABLE ROW used to be taken on faith.
const HUBS: [LpAddr; 2] = [USDC_ADDR, USDT_ADDR];

/// A 32-byte ABI word for a `uint256`.
fn u256_word(v: U256) -> [u8; 32] { v.to_be_bytes::<32>() }

/// ⭐ §SESS-49 — **ASK THE FACTORY. DO NOT KEEP A POOL TABLE.**
///
/// 🔴 **THIS REPLACES `direct_pool`, A FOUR-ENTRY HARDCODED TABLE, AND THE FOUR `P_*` POOL CONSTANTS
///    WITH IT.** The basket has **FOURTEEN** stables (`DeployL1_s:240-250`); that table could plan
///    exactly **two** of them (USDT, DAI). ⛔ **THREE TIMES IN ONE SESSION I "FIXED" ROUTING BY ADDING
///    A ROW TO A SMALL TABLE** — `_routeOf` +USDT/+DAI, then `Aux.hubHopOf`, then very nearly a
///    two-candidate quote over this one. The owner stopped each: *"we have 15 stables."*
/// ⇒ **The keeper HAS an RPC connection, so a pool is a QUESTION, not a constant.** `getPool` answers
///    it for any pair and any tier, including tokens nobody has thought about yet.
/// ✅ **AND IT COSTS NO NEW TRUST: the keeper still names only POOLS.** Whatever it discovers is
///    bounded on-chain by the oracle floor on a measured balance delta, so a wrong or hostile
///    discovery can make a leg FAIL and can never make it pay out short. **Widening discovery widens
///    liveness, never authority** — which is exactly why this belongs off-chain and nothing on-chain
///    had to change for it.
fn pool_for<R: JsonRpc>(rpc: &R, a: LpAddr, b: LpAddr, fee: u32) -> Option<LpAddr> {
    let mut arg = Vec::with_capacity(96);
    arg.extend_from_slice(&addr_word(a));
    arg.extend_from_slice(&addr_word(b));
    arg.extend_from_slice(&u64_word(fee as u64));
    let r = eth_call_raw(rpc, Address::from_slice(&UNIV3_FACTORY), "getPool(address,address,uint24)", Some(&arg)).ok()?;
    let p = word_to_lpaddr(&r).ok()?;
    if p == [0u8; 20] { None } else { Some(p) }
}

/// Simulate one hop through `pool`. `None` = the tier has no pool, or it cannot fill this size.
/// ⚠️ **`QuoterV2` is not `view` — it SIMULATES the swap and reverts internally to report.** That is
///    fine over `eth_call` and is the standard way to price a V3 hop; it also means the number
///    includes fee AND impact at the size asked, which is the whole reason a table cannot answer this.
fn quote_hop<R: JsonRpc>(rpc: &R, tin: LpAddr, tout: LpAddr, amt: U256, fee: u32) -> Option<U256> {
    let mut arg = Vec::with_capacity(160);
    arg.extend_from_slice(&addr_word(tin));
    arg.extend_from_slice(&addr_word(tout));
    arg.extend_from_slice(&u256_word(amt));
    arg.extend_from_slice(&u64_word(fee as u64));
    arg.extend_from_slice(&[0u8; 32]);                      // sqrtPriceLimitX96 = 0 (no limit)
    let r = eth_call_raw(rpc, Address::from_slice(&QUOTER_V2),
        "quoteExactInputSingle((address,address,uint256,uint24,uint160))", Some(&arg)).ok()?;
    if r.len() < 32 { return None; }
    let out = U256::from_be_slice(&r[..32]);
    if out.is_zero() { None } else { Some(out) }
}

/// ⭐ §SESS-67 — **DEPTH IS A GATE, NOT A TIEBREAK. AN ILLIQUID VENUE IS NEVER A CANDIDATE.**
///
/// Owner, 2026-09-07: *"you should only pick the most liquid venues."* Correct, and it fixes three
/// things at once that quoting-everything did not:
/// 1. **COST.** One `balanceOf` per candidate replaces 2-3 calls for a quote. `find_pools_for_coins`
///    returns **121 pools** for USDT/USDC — measured — so pruning before quoting is the difference
///    between viable and not. Quoting them all starved the endpoint badly enough that the *UniV3*
///    quotes on the same run started returning nothing.
/// 2. **SAFETY, and this is the half a price comparison cannot give you.** A thin pool quotes fine at
///    small size and is a trap at real size. `Interfaces.sol` records `0xEf3a1CaE…` answering `get_dy`
///    for four stables at **427 USDC per 10,000 in — a 95% loss with NO revert.** A "did not revert"
///    filter takes it; a "best quote at THIS size" filter mostly dodges it; **a depth gate never sees
///    it.** The tree's own note is blunt: *"Depth is the discriminator."*
/// 3. **IMPACT WE INFLICT ON OURSELVES.** Taking a large fraction of a pool moves the price against us
///    and the damage is not linear — the offramp measured fills tracking `~1.4 + 55·(dx/D)²` bps and
///    then **breaking by 70x** at exhaustion. `QuidLib` already answers this exact way: *"90% of the
///    pool's WETH: slippage steepens toward the edge, so leave headroom rather than sizing to the
///    exact boundary the quadratic stops describing."*
///
/// ⇒ **require the pool to hold at least `DEPTH_MULTIPLE x` of what we are SELLING**, so a trade is
///    never more than `1/DEPTH_MULTIPLE` of that side. ⚠️ Measured on the token we SELL, not the one we
///    buy: that side is what we are adding to, and it is the side whose balance we can read without
///    already knowing the answer.
/// ⚠️ **A FAILED READ IS NOT DEPTH.** `.ok()?` on a throttled endpoint would silently classify a deep
///    pool as thin and route around it — a rate limit wearing a routing decision's clothes. So a read
///    that fails REJECTS the candidate rather than passing it, and the caller falls back to venues that
///    did answer; being conservative under load is the safe direction here.
const DEPTH_MULTIPLE: u64 = 4;         // never sell more than 25% of a pool's holding of that token

fn deep_enough<R: JsonRpc>(rpc: &R, pool: LpAddr, token: LpAddr, amt: U256) -> bool {
    let Ok(b) = eth_call_raw(rpc, Address::from_slice(&token), "balanceOf(address)",
                             Some(&addr_word(pool))) else { return false };
    if b.len() < 32 { return false; }
    U256::from_be_slice(&b[..32]) >= amt.saturating_mul(U256::from(DEPTH_MULTIPLE))
}

/// A Curve hop word the contract can execute: `proto | j | i | pool` (see `Interfaces.sol`).
/// ⚠️ Deliberately NOT a 1inch pool word: `unoswap` was probed with six candidate Curve layouts
/// against the live router and **0 of 6 filled**. `LevMath._hubHop` calls `exchange` directly.
/// One word per venue KIND, or `None` when the venue cannot be expressed as one (v4 needs a PoolKey).
fn venue_word(v: Venue) -> Option<[u8; 32]> {
    match v {
        Venue::V3 { pool, .. } => Some(v3_word(pool)),
        Venue::Curve { pool, i, j } => Some(curve_word(pool, i, j)),
        Venue::V4 { .. } => None,   // §SESS-79 — a singleton pool has no address to put in a word
    }
}

fn curve_word(pool: LpAddr, i: u8, j: u8) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(&pool);
    w[31 - 20] = i;                       // bit 160
    w[31 - 21] = j;                       // bit 168
    w[0] |= 2 << 5;                       // proto = Curve (2) at bits 253-255
    w
}

/// ⭐ §SESS-66 — **CURVE CANDIDATES: A SHORTLIST, QUOTED LIVE. NOT AN ENUMERATION.**
///
/// 🔴 **MEASURED, AND IT KILLED THE OBVIOUS DESIGN: `find_pools_for_coins(USDT, USDC)` RETURNS 121
///    POOLS.** Quoting them needs `get_coin_indices` + `get_dy` each — **363 `eth_call`s for ONE leg**
///    — and doing it starved the endpoint badly enough that the *UniswapV3* quotes on the same run
///    began returning nothing. ⚠️ **That failure was silent**: `.ok()?` turns a throttled call into
///    "no route", so the planner would have quietly degraded to worse venues under load rather than
///    erroring. **A rate limit wearing a routing decision's clothes.**
/// ⛔ **AND "TAKE THE FIRST N" IS NOT AVAILABLE:** CLAUDE.md already records that registry order is
///    NOT depth — the singular `find_pool_for_coins` returns dead pools, and `0xEf3a1CaE…` answers
///    `get_dy` for four stables at **427 USDC per 10,000 in**, a 95% loss with no revert. A cap on an
///    unranked list is a coin flip.
///
/// ▶️ **SO THE ENUMERATION MOVES OFF THE HOT PATH.** This quotes a SHORTLIST — the pools this repo
///    already verified by depth-at-size against `coins()` — and **the shortlist is not trusted, it is
///    PRICED**: a pool that has since drained loses the comparison to UniV3 on the same quote. That is
///    the identical argument that justifies a short `HUBS` list, and it is what separates this from
///    the three compile-time tables deleted earlier: **config that competes, not bytecode that wins.**
/// ⚠️ **`is_underlying` METAPOOLS ARE STILL EXCLUDED** — `curveExchange` calls `exchange`, not
///    `exchange_underlying`, so a metapool quote prices a swap we cannot execute. The shortlist below
///    is metapool-free by construction (each row was verified against `coins(i)`/`coins(j)`).
/// 📌 **BOOKED, NOT BUILT: the offline enumerator that REFRESHES this shortlist** — walk
///    `find_pools_for_coins`, reject metapools, quote every survivor at three sizes, keep the winners.
///    That is exactly how the on-chain rows were built by hand; it belongs in a tool, run rarely.
const CURVE_SHORTLIST: [(LpAddr, LpAddr, LpAddr, u8, u8); 6] = [
    // (tokenA, tokenB, pool, indexA, indexB) — **THE SAME SIX ROWS `LevMath._hubRowOf` HOLDS.**
    // 🔴 §SESS-81 — this had TWO of them, and the coverage matrix caught it: crvUSD reported
    //    ** NONE ** to both volatiles while the CONTRACT has had a crvUSD Curve row all along.
    //    ⇒ **the keeper was blind to venues the contract can already execute** — the planner's search
    //    space was narrower than the executor's reach, which is the worst direction for that gap to
    //    run: unroutable-by-omission looks exactly like unroutable-by-market.
    // ⚠️ Indices are copied from `Interfaces.sol` per pool, NOT shared: the two USDC pairs are ordered
    //    OPPOSITELY on mainnet (RLUSD is coin 1, PYUSD is coin 0), and a shared constant would be a
    //    wrong-pair swap at size with no revert.
    (USDT_ADDR, USDC_ADDR, [0xbE,0xbc,0x44,0x78,0x2C,0x7d,0xB0,0xa1,0xA6,0x0C,
                            0xb6,0xfe,0x97,0xd0,0xb4,0x83,0x03,0x2F,0xF1,0xC7], 2, 1),   // 3pool
    (DAI_ADDR,  USDC_ADDR, [0xbE,0xbc,0x44,0x78,0x2C,0x7d,0xB0,0xa1,0xA6,0x0C,
                            0xb6,0xfe,0x97,0xd0,0xb4,0x83,0x03,0x2F,0xF1,0xC7], 0, 1),   // 3pool
    // RLUSD: coins(0)=USDC coins(1)=RLUSD
    ([0x82,0x92,0xBb,0x45,0xbf,0x1E,0xe4,0xd1,0x40,0x12,0x70,0x49,0x75,0x7C,0x2E,0x0f,0xF0,0x63,0x17,0xeD],
     USDC_ADDR, [0xD0,0x01,0xaE,0x43,0x3f,0x25,0x42,0x83,0xFe,0xCE,
                 0x51,0xd4,0xAC,0xcE,0x8c,0x53,0x26,0x3a,0xa1,0x86], 1, 0),
    // PYUSD: coins(0)=PYUSD coins(1)=USDC
    ([0x6c,0x3e,0xa9,0x03,0x64,0x06,0x85,0x20,0x06,0x29,0x07,0x70,0xBE,0xdF,0xcA,0xbA,0x0e,0x23,0xA0,0xe8],
     USDC_ADDR, [0x38,0x3E,0x6b,0x44,0x37,0xb5,0x9f,0xff,0x47,0xB6,
                 0x19,0xCB,0xA8,0x55,0xCA,0x29,0x34,0x2A,0x85,0x59], 0, 1),
    // USDG
    ([0xe3,0x43,0x16,0x76,0x31,0xd8,0x9B,0x6F,0xfc,0x58,0xB8,0x8d,0x6b,0x7f,0xB0,0x22,0x87,0x95,0x49,0x1D],
     USDC_ADDR, [0xc0,0x61,0xca,0xa0,0x73,0xf3,0xd9,0x5F,0x80,0xf8,
                 0xe5,0x42,0x8d,0x32,0xD2,0xd7,0x6F,0x5e,0x16,0x22], 0, 1),
    // crvUSD: coins(0)=USDC coins(1)=crvUSD
    ([0xf9,0x39,0xE0,0xA0,0x3F,0xB0,0x7F,0x59,0xA7,0x33,0x14,0xE7,0x37,0x94,0xBe,0x0E,0x57,0xac,0x1b,0x4E],
     USDC_ADDR, [0x4D,0xEc,0xE6,0x78,0xce,0xce,0xb2,0x74,0x46,0xb3,
                 0x5C,0x67,0x2d,0xC7,0xd6,0x1F,0x30,0xbA,0xD6,0x9E], 1, 0),
];


/// Quote the shortlist for `tin -> tout` and return the best `(hop word, out)`.
fn curve_best<R: JsonRpc>(rpc: &R, tin: LpAddr, tout: LpAddr, amt: U256) -> Option<([u8; 32], U256)> {
    let mut best: Option<([u8; 32], U256)> = None;
    for (a, b, pool, ia, ib) in CURVE_SHORTLIST {
        let (i, j) = if a == tin && b == tout { (ia, ib) }
                     else if b == tin && a == tout { (ib, ia) }
                     else { continue };
        if !deep_enough(rpc, pool, tin, amt) { continue; }   // §SESS-67 — depth BEFORE price
        let mut qa = Vec::with_capacity(96);
        qa.extend_from_slice(&{ let mut w = [0u8; 32]; w[31] = i; w });
        qa.extend_from_slice(&{ let mut w = [0u8; 32]; w[31] = j; w });
        qa.extend_from_slice(&u256_word(amt));
        let Ok(dy) = eth_call_raw(rpc, Address::from_slice(&pool),
            "get_dy(int128,int128,uint256)", Some(&qa)) else { continue };
        if dy.len() < 32 { continue; }
        let out = U256::from_be_slice(&dy[..32]);
        if out.is_zero() { continue; }
        if best.as_ref().is_none_or(|(_, b2)| out > *b2) { best = Some((curve_word(pool, i, j), out)); }
    }
    best
}

/// ⭐ §SESS-80 — **THE VENUE CACHE: DISCOVER RARELY, QUOTE EVERY TIME.**
///
/// 🔴 **ENUMERATION IS ALREADY THE BOTTLENECK AND IT HAS FAILED ONCE, SILENTLY.**
///    `find_pools_for_coins(USDT, USDC)` returns **121 pools**; quoting them is ~363 `eth_call`s for
///    ONE leg, and doing it **starved the endpoint badly enough that the UniswapV3 quotes on the same
///    run began returning nothing.** ⚠️ That failure was invisible: `.ok()?` turns a throttled call
///    into "no route", so the planner degrades to a worse venue rather than erroring. **A rate limit
///    wearing a routing decision's clothes.**
///
/// 🔑 **THE SPLIT IS THE DESIGN, AND THE TWO HALVES HAVE DIFFERENT SHELF LIVES:**
///   · **WHICH POOLS EXIST AND ARE DEEP** changes on the timescale of pool deployments — hours to
///     weeks. Discover it rarely and CACHE it.
///   · **WHICH OF THEM WINS** changes every block and with every SIZE. Measured this session: 3pool
///     beats the UniV3 0.01% tier above ~$500k and loses below it; the 2-hop beats direct on
///     USDT→WETH by ~28 bps and loses on USDC→WETH at $1M. **Never cache a winner — only a candidate.**
/// ⛔ **THE DEPTH GATE BELONGS IN THE DISCOVERY HALF, NOT THE QUOTING HALF.** A venue below threshold
///    never enters the cache, so it is never quoted and can never be selected. That is both cheaper
///    and what stops the keeper picking the pool this session measured at a **2,308 bps** shortfall.
/// ⚠️ **TTL, NOT PERMANENCE.** A cached pool can drain — `_hubRowOf`'s own rows were chosen by depth
///    and 3pool has fallen from ~$3B to $160M. The cache holds CANDIDACY; the live quote holds truth.
const VENUE_CACHE_TTL: Duration = Duration::from_secs(3600);

/// One executable venue for a pair. ⚠️ Deliberately not "a pool address": a v4 pool HAS no address.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Venue {
    V3 { pool: LpAddr, fee: u32 },
    Curve { pool: LpAddr, i: u8, j: u8 },
    /// §SESS-79 — `hooks` is absent BY CONSTRUCTION: the contract forces `address(0)`, so a hooked
    /// pool cannot be named here even by a compromised keeper.
    V4 { fee: u32, tick_spacing: i32 },
}

type CacheKey = (LpAddr, LpAddr);
static VENUE_CACHE: OnceLock<Mutex<HashMap<CacheKey, (Instant, Vec<Venue>)>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<CacheKey, (Instant, Vec<Venue>)>> {
    VENUE_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Candidates for `a -> b` at roughly `amt`, discovered once per TTL and depth-gated on entry.
/// ⚠️ **KEYED ON THE UNORDERED PAIR** — a venue that can serve `a→b` serves `b→a`, and the contract
///    derives direction itself, so caching both directions separately would double the RPC cost to
///    store the same fact twice.
fn venues_for<R: JsonRpc>(rpc: &R, a: LpAddr, b: LpAddr, amt: U256) -> Vec<Venue> {
    let key: CacheKey = if a <= b { (a, b) } else { (b, a) };
    if let Some((at, v)) = cache().lock().unwrap().get(&key) {
        if at.elapsed() < VENUE_CACHE_TTL { return v.clone(); }
    }
    let mut out: Vec<Venue> = Vec::new();
    for fee in FEE_TIERS {
        if let Some(pool) = pool_for(rpc, a, b, fee) {
            if deep_enough(rpc, pool, a, amt) { out.push(Venue::V3 { pool, fee }); }
        }
    }
    for (x, y, pool, ia, ib) in CURVE_SHORTLIST {
        let m = (x == a && y == b) || (x == b && y == a);
        if m && deep_enough(rpc, pool, a, amt) {
            let (i, j) = if x == a { (ia, ib) } else { (ib, ia) };
            out.push(Venue::Curve { pool, i, j });
        }
    }
    // §SESS-79 — v4 candidacy is checked through StateView, because the singleton holds EVERY pool's
    // tokens together and a `balanceOf` on it says nothing about the pool we would trade.
    for (fee, ts) in V4_TIERS {
        if v4_pool_has_liquidity(rpc, a, b, fee, ts) {
            out.push(Venue::V4 { fee, tick_spacing: ts });
        }
    }
    // 🔴 **NEVER CACHE AN EMPTY RESULT. THIS BUG BIT WITHIN AN HOUR OF THE CACHE LANDING.**
    //    `deep_enough` REJECTS on a failed read — conservative for value, because a throttled endpoint
    //    must not be read as depth. But combined with a one-hour TTL that turns a transient rate limit
    //    into **an hour of blindness to that pair**, silently.
    // ⚠️ **MEASURED, NOT FEARED:** the §SESS-81 coverage matrix reported USDe as `** NONE **` to both
    //    volatiles while its UniV3 0.01% pool holds **1,596,391 USDe against a 400,000 gate** — it
    //    passes comfortably. The venue was there; the read was not.
    // ⇒ an empty discovery is treated as UNKNOWN rather than as an answer: nothing is stored, so the
    //   next lookup retries. **A cache may remember what it learned; it must not remember what it
    //   failed to learn.**
    if !out.is_empty() {
        cache().lock().unwrap().insert(key, (Instant::now(), out.clone()));
    }
    out
}

/// Uniswap v4 fee/tickSpacing pairs, and the StateView that answers whether a HOOKLESS pool exists.
const V4_TIERS: [(u32, i32); 4] = [(100, 1), (500, 10), (3000, 60), (10000, 200)];
const V4_STATE_VIEW: LpAddr = [0x7f,0xFE,0x42,0xC4,0xa5,0xDE,0xeA,0x5b,0x0f,0xeC,
                               0x41,0xC9,0x4C,0x13,0x6C,0xf1,0x15,0x59,0x72,0x27];

/// `getLiquidity(poolId)` on the canonical HOOKLESS PoolKey. ⛔ Non-zero liquidity is CANDIDACY, not
/// depth — the fill is still quoted at size, because this session measured a v4 tier that existed,
/// held liquidity, and returned a **2,308 bps** shortfall on $50k.
fn v4_pool_has_liquidity<R: JsonRpc>(rpc: &R, a: LpAddr, b: LpAddr, fee: u32, ts: i32) -> bool {
    let (c0, c1) = if a <= b { (a, b) } else { (b, a) };
    let mut enc = Vec::with_capacity(160);
    enc.extend_from_slice(&addr_word(c0));
    enc.extend_from_slice(&addr_word(c1));
    enc.extend_from_slice(&u64_word(fee as u64));
    enc.extend_from_slice(&u64_word(ts as u64));
    enc.extend_from_slice(&[0u8; 32]);                     // hooks = address(0), always
    let id = alloy_primitives::keccak256(&enc);
    let Ok(r) = eth_call_raw(rpc, Address::from_slice(&V4_STATE_VIEW),
        "getLiquidity(bytes32)", Some(id.as_slice())) else { return false };
    r.len() >= 32 && U256::from_be_slice(&r[..32]) != U256::ZERO
}

/// Best direct hop for a pair: quote every CACHED candidate at the traded size, take the max.
/// ⭐ §SESS-80 — **DISCOVERY MOVED OUT; THIS IS NOW PURE QUOTING.** It used to walk the factory and
///    depth-gate on every call, which is the work the cache exists to stop repeating. What stays
///    per-call is the QUOTE, because the winner is size- and block-dependent and caching one would be
///    caching a fact with a one-block shelf life.
/// ⚠️ Returns the winning venue, not just its output, so the caller can encode the right hop kind —
///    a v4 venue has no pool address and cannot be represented by a pool word.
fn best_direct<R: JsonRpc>(rpc: &R, tin: LpAddr, tout: LpAddr, amt: U256) -> Option<(Venue, U256)> {
    let mut best: Option<(Venue, U256)> = None;
    for v in venues_for(rpc, tin, tout, amt) {
        let out = match v {
            Venue::V3 { fee, .. } => quote_hop(rpc, tin, tout, amt, fee),
            Venue::Curve { pool, i, j } => curve_quote(rpc, pool, i, j, tin, tout, amt),
            // ⛔ v4 is CANDIDATE-ONLY until a quoter is wired: `getLiquidity` says a pool exists, not
            //    what it fills at size, and this session measured an existing, liquid v4 tier
            //    returning a **2,308 bps** shortfall on $50k. Selecting it unquoted would be exactly
            //    the mistake the depth gate was added to prevent, one venue class over.
            Venue::V4 { .. } => None,
        };
        let Some(out) = out else { continue };
        if best.is_none_or(|(_, b)| out > b) { best = Some((v, out)); }
    }
    best
}

/// `get_dy` on a cached Curve candidate, oriented for the direction we are actually trading.
fn curve_quote<R: JsonRpc>(rpc: &R, pool: LpAddr, i: u8, j: u8, tin: LpAddr, _tout: LpAddr,
                           amt: U256) -> Option<U256> {
    let (i, j) = if tin <= _tout { (i, j) } else { (j, i) };
    let mut qa = Vec::with_capacity(96);
    qa.extend_from_slice(&{ let mut w = [0u8; 32]; w[31] = i; w });
    qa.extend_from_slice(&{ let mut w = [0u8; 32]; w[31] = j; w });
    qa.extend_from_slice(&u256_word(amt));
    let r = eth_call_raw(rpc, Address::from_slice(&pool), "get_dy(int128,int128,uint256)", Some(&qa)).ok()?;
    if r.len() < 32 { return None; }
    let out = U256::from_be_slice(&r[..32]);
    if out.is_zero() { None } else { Some(out) }
}

/// ⭐ **THE PLANNER: quote every shape we can execute, take the best.** Direct across all tiers, and
///    two hops through the USDC hub across all tier pairs.
/// 🔴 **A DIRECT POOL NO LONGER SHORT-CIRCUITS, AND THAT WAS A REAL COST.** `plan_route` returned the
///    direct pool whenever one existed and never priced the alternative. **Measured at block 25919955,
///    USDC→WETH at $1M: direct best `399.365` vs hub 2-hop `400.282` — ~23 bps left on the table**, on
///    the exact pair a USDC-denominated venue uses. At $50k direct wins, so this is SIZE-DEPENDENT and
///    cannot be fixed by reordering a table; it needs a quote.
/// @return `None` when nothing quotes — the caller then leaves `dex2 = 0` and the contract uses its
///         own `_hubRowOf` row, which is a correct default rather than a guess.
fn best_plan<R: JsonRpc>(rpc: &R, tin: LpAddr, tout: LpAddr, amt: U256) -> Option<Plan> {
    best_plan_quoted(rpc, tin, tout, amt).map(|(p, _)| p)
}

/// The same search, keeping the winning QUOTE. ⭐ Not a second implementation: `best_plan` is one
/// `.map` over this. The quote already existed inside the search and was being discarded, so a caller
/// that wants to check "is the chosen route at least as good as the direct one" needs no new work
/// (standing rule 23 — the declaration returns something already computed).
fn best_plan_quoted<R: JsonRpc>(rpc: &R, tin: LpAddr, tout: LpAddr, amt: U256) -> Option<(Plan, U256)> {
    let mut best: Option<(Plan, U256)> = None;
    if let Some((v, out)) = best_direct(rpc, tin, tout, amt) {
        if let Some(w) = venue_word(v) {
            best = Some((Plan { dex: w, dex2: [0u8; 32], hops: vec![w], fetched: Vec::new() }, out));
        }
    }
    // ⭐ §SESS-58 — **EVERY CANDIDATE HUB, INCLUDING WHEN THE INPUT IS ITSELF A HUB.**
    // 🔴 This read `if tin != USDC_ADDR` with USDC as the only hub, so **a USDC-denominated venue —
    //    the most common one — never had a two-hop priced at all.** Measured at block 25919955,
    //    `USDC→USDT→WETH` at $1M beat direct by ~23 bps and was UNREACHABLE. ⚠️ And measured again at
    //    25924xxx the sign had FLIPPED (direct 400.206 vs via-USDT 399.944), which is the point: the
    //    winner is market state, so the planner must PRICE both rather than encode either.
    // ⚠️ A hub equal to `tin` or `tout` is skipped — that is the direct case, already priced above.
    for hub in HUBS {
        if hub == tin || hub == tout { continue; }
        // ⭐ §SESS-66 — **CURVE COMPETES FOR THE FIRST LEG, AND ONLY THE FIRST LEG.**
        // ⛔ **THE RESTRICTION IS THE CONTRACT'S, NOT A PREFERENCE:** `LevMath._hubHop` converts
        //    stable↔USDC and that is the ONLY position a Curve word is dispatched at. A Curve pool
        //    found for the VOLATILE leg would be unexecutable, and planning one would be the
        //    built-but-unwired shape a fourth time. **Plan only what can be executed.**
        // ⚠️ Measured this session: 3pool beats the UniV3 0.01% tier for USDT→USDC above ~$500k
        //    (−0.42 vs −0.72 bps at $1M, −0.68 vs −2.16 at $5M) and LOSES below it. So neither venue
        //    wins by class — which is exactly why both are quoted rather than one being preferred.
        let v3_first = best_direct(rpc, tin, hub, amt).and_then(|(v, o)| venue_word(v).map(|w| (w, o)));
        let cv_first: Option<([u8; 32], U256)> = None;   // §SESS-80 — Curve is a cached candidate now
        let first_leg = match (v3_first, cv_first) {
            (Some(a), Some(b)) => Some(if b.1 > a.1 { b } else { a }),
            (x, None) => x,
            (None, y) => y,
        };
        let Some((w1, mid)) = first_leg else { continue };
        let Some((second_v, out)) = best_direct(rpc, hub, tout, mid) else { continue };
        let Some(second) = venue_word(second_v) else { continue };
        if best.as_ref().is_none_or(|(_, b)| out > *b) {
            // `dex2` is hop 1 (see `Plan`) — the crossing is deliberate and load-bearing.
            best = Some((Plan { dex: second, dex2: w1, hops: vec![w1, second], fetched: Vec::new() }, out));
        }
    }
    best
}


/// §SESS-47 — **THIS LP'S VENUE STABLE. The one read that was missing.**
///
/// `pos(lp)` already yields the venue address (`position_view` reads it for `liqThresholdBps`), and
/// `ILevVenue` declares `stable()`. So the keeper could always have known which dollar each position
/// borrows; nothing consumed it.
fn venue_stable_of<R: JsonRpc, S: TxSigner>(
    evm: &JsonRpcEvmClient<R, S>, lm: Address, lp: LpAddr,
) -> Option<LpAddr> {
    let pw = evm.eth_read(lm, "pos(address)", Some(&addr_word(lp))).ok()?;
    let venue = Address::from_slice(pw.get(12..32)?);
    let s = evm.eth_read(venue, "stable()", None).ok()?;
    let mut out = [0u8; 20];
    out.copy_from_slice(s.get(12..32)?);
    Some(out)
}

/// §SESS-47 — 🔑 **THE KEEPER SUPPLIES THE HUB HOP, SO THE CONTRACT NEVER HAS TO GUESS ONE.**
///
/// Resolve THIS LP's venue stable, plan `stable → volatile` against it, and send BOTH pool words.
/// `planner_two_hop_puts_the_hub_leg_in_dex2` pins the shape: USDT→WETH yields
/// `dex2 = USDT/USDC 0.01%` (hop 1) and `dex = USDC/WETH 0.05%` (hop 2). A non-zero `dex2` is what
/// keeps `_stableToWethSor` / `_stableToWbtc` on `routedSwap` — their `hubDex == 0` arm calls
/// `_aggSwap` directly and never looks at `route` — so sending the plan is also what makes the
/// full-venue `bytes route` arm reachable.
///
/// ⭐ **FAIL-SAFE BY CONSTRUCTION.** A failed read, an unknown venue, or a stable `direct_pool`
///    cannot express all degrade to `dex_word()` with a ZERO hub word, which is the contract's own
///    keyless arm (`_hubHop` → `_hubRowOf`, six stables, `NoStableRoute()` only for a stable that is
///    on none of them). It never guesses a pool.
/// ⚠️ **AND NOTE WHAT DOES NOT CHANGE: USDC.** `plan_route(USDC, WETH)` finds a DIRECT pool, so it
///    returns `dex2 = 0` on its own merits. USDC IS the hub — `_hubHop` returns `amt` unchanged for
///    it — which is why `_stableToWethSor` excludes it from the `dex2 == 0` guard, and why adding
///    `&& stable != USDC` to that guard broke 17 tests.
/// 📌 Costs two `eth_read`s per LP per cycle against a 5-minute poll. `position_view` already reads
///    `pos(lp)`; threading the stable through it would save one read at the price of widening the
///    `LevKeeperEvm` trait and its mock, so the duplicate read is the smaller change.
fn plan_for_lp<R: JsonRpc, S: TxSigner>(
    evm: &JsonRpcEvmClient<R, S>, lm: Address, lp: LpAddr, volatile: LpAddr,
) -> Plan {
    let planned = venue_stable_of(evm, lm, lp).and_then(|stable| {
        let amt = ranking_size(evm, lm, lp, stable)?;
        best_plan(evm.rpc(), stable, volatile, amt)
    });
    planned.unwrap_or(Plan { dex: dex_word(), dex2: [0u8; 32], hops: vec![dex_word()], fetched: Vec::new() })
}

/// §SESS-49 — **THE SIZE TO RANK AT, IN THE STABLE'S OWN UNITS.**
///
/// ⭐ **THE AMOUNT IS NEEDED FOR THE DECISION, NOT FOR THE CALLDATA — WHICH IS WHY THIS IS SAFE TO
///    APPROXIMATE AND WHY IT DOES NOT REOPEN THE STALENESS PROBLEM.** A pool WORD carries no amount;
///    the contract sizes the trade itself from a borrow return it computes on-chain. So this number
///    only has to be close enough to RANK two routes, and the ranking is flat over a wide band —
///    measured, direct wins at $50k and the 2-hop wins at $1M, so an estimate anywhere inside an
///    order of magnitude picks the same winner. **That is the whole reason route choice can be
///    off-chain while route EXECUTION stays bounded on-chain.**
/// ⚠️ `netEquityUsd` is 1e18-USD and stables are 6- or 18-dec, so the conversion is per-stable and
///    read from the token — never inferred from a slot index, which is this repo's oldest decimal bug.
fn ranking_size<R: JsonRpc, S: TxSigner>(
    evm: &JsonRpcEvmClient<R, S>, lm: Address, lp: LpAddr, stable: LpAddr,
) -> Option<U256> {
    let eq = evm.eth_read(lm, "netEquityUsd(address)", Some(&addr_word(lp))).ok()?;
    if eq.len() < 32 { return None; }
    let usd18 = U256::from_be_slice(&eq[..32]);
    if usd18.is_zero() { return None; }                 // nothing to size ⇒ nothing to rank
    let d = evm.eth_read(Address::from_slice(&stable), "decimals()", None).ok()?;
    if d.len() < 32 { return None; }
    let dec: u32 = word_to_uint::<u64>(&d, "decimals").ok()?.try_into().ok()?;
    if dec > 18 { return None; }
    Some(usd18 / U256::from(10u64).pow(U256::from(18u32 - dec)))
}

fn hex_lit_pool() -> [u8; 20] {
    [0x88,0xe6,0xA0,0xc2,0xdD,0xD2,0x6F,0xEE,0xb6,0x4F,
     0x03,0x9a,0x2c,0x41,0x29,0x6F,0xcB,0x3f,0x56,0x40]
}


/// §S15 — the FIVE-array `rebalanceMany(address[],uint256[],uint256[],uint256[],bytes[])`.
///
/// ⭐ **ONE ENCODER, TWO SELECTORS — WHICH IS WHY IT TAKES `sig`.** `cascadeDelever` has the SAME
/// five-array shape, and since §SESS-19/§SESS-21 `deleverOne` carries `dex2`/`route` through to
/// `_deleverFlash` rather than dropping them, so the extra arrays are consumed on both paths.
///
/// ⚠️ **`dex2s` and `routes` may each be EMPTY, which is the contract's compat shape** (`length 0`
///    ⇒ every LP takes the legacy single-hop hub route). Any OTHER length must equal `lps.len()`,
///    or `rebalanceMany` reverts `LenMismatch()` — a short array would silently give some LPs a
///    route and others the legacy hop, which is why the contract checks rather than clamps.
/// The two batch selectors, named once so the allowlist, the encoders and the tests cannot drift.
const RM_SIG: &str = "rebalanceMany(address[],uint256[],uint256[],uint256[],bytes[])";
const CD_SIG: &str = "cascadeDelever(address[],uint256[],uint256[],uint256[],bytes[])";

fn encode_batch5(sig: &str, lps: &[LpAddr], dexes: &[[u8; 32]],
                 dex2s: &[[u8; 32]], routes: &[Vec<u8>]) -> Vec<u8> {
    debug_assert!(dex2s.is_empty()  || dex2s.len()  == lps.len(), "dex2s must be per-LP or empty");
    debug_assert!(routes.is_empty() || routes.len() == lps.len(), "routes must be per-LP or empty");
    let n = lps.len() as u64;
    let n2 = dex2s.len() as u64;
    let nr = routes.len() as u64;
    let mut d = selector4(sig);

    // Five head words, then each dynamic array laid out in order.
    let lps_at   = 0xa0u64;
    let mins_at  = lps_at   + 32 * (1 + n);
    let dexes_at = mins_at  + 32 * (1 + n);
    let dex2_at  = dexes_at + 32 * (1 + n);
    let routes_at = dex2_at + 32 * (1 + n2);
    for off in [lps_at, mins_at, dexes_at, dex2_at, routes_at] { d.extend_from_slice(&u64_word(off)); }

    d.extend_from_slice(&u64_word(n));
    for lp in lps { d.extend_from_slice(&addr_word(*lp)); }
    d.extend_from_slice(&u64_word(n));
    for _ in 0..n { d.extend_from_slice(&u64_word(0)); }   // minOuts: the on-chain TWAP floor bounds each swap
    d.extend_from_slice(&u64_word(n));
    for i in 0..n as usize { d.extend_from_slice(&dexes.get(i).copied().unwrap_or([0u8; 32])); }
    d.extend_from_slice(&u64_word(n2));
    for w in dex2s { d.extend_from_slice(w); }

    // `bytes[]`: a length word, then n RELATIVE offsets, then each element as (len, padded data).
    d.extend_from_slice(&u64_word(nr));
    let mut rel = 32 * nr;                                  // past the offset table
    let mut tail: Vec<u8> = Vec::new();
    for r in routes {
        d.extend_from_slice(&u64_word(rel));
        let pad = (32 - (r.len() % 32)) % 32;
        tail.extend_from_slice(&u64_word(r.len() as u64));
        tail.extend_from_slice(r);
        tail.extend(std::iter::repeat(0u8).take(pad));
        rel += 32 + r.len() as u64 + pad as u64;
    }
    d.extend_from_slice(&tail);
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

    /// §S15 — **THE `bytes[]` OFFSET TABLE IS THE PART THAT FAILS SILENTLY**, so it is decoded back
    /// rather than merely length-checked. A wrong relative offset does not panic here — it produces
    /// calldata the contract decodes into a DIFFERENT route, which on-chain becomes a failed leg and
    /// a `RebalanceFailed` event, i.e. an encoder bug wearing a venue bug's clothes.
    #[test]
    fn encode_rebalance_many_lays_out_bytes_array_correctly() {
        let lps = vec![LpAddr::from([0x11u8; 20]), LpAddr::from([0x22u8; 20])];
        let dexes = vec![[0xAAu8; 32], [0xBBu8; 32]];
        let dex2s = vec![[0xCCu8; 32], [0xDDu8; 32]];
        // Deliberately NOT multiples of 32: padding is where hand-rolled encoders go wrong.
        let routes = vec![vec![0xDEu8; 4], vec![0xEFu8; 33]];
        let d = encode_batch5(RM_SIG, &lps, &dexes, &dex2s, &routes);

        let word = |i: usize| -> u64 {
            let b = &d[4 + i * 32..4 + (i + 1) * 32];
            u64::from_be_bytes(b[24..32].try_into().unwrap())
        };
        // Head: five offsets. lps(2) mins(2) dexes(2) dex2s(2) each cost 32*(1+2)=96.
        assert_eq!(word(0), 0xa0);
        assert_eq!(word(1), 0xa0 + 96);
        assert_eq!(word(2), 0xa0 + 192);
        assert_eq!(word(3), 0xa0 + 288);
        let routes_at = word(4) as usize;
        assert_eq!(routes_at, 0xa0 + 384);

        // The routes block: len, then two RELATIVE offsets, then the elements.
        let at = |off: usize| -> u64 {
            let b = &d[4 + off..4 + off + 32];
            u64::from_be_bytes(b[24..32].try_into().unwrap())
        };
        assert_eq!(at(routes_at), 2, "routes length");
        let o0 = at(routes_at + 32) as usize;
        let o1 = at(routes_at + 64) as usize;
        assert_eq!(o0, 64, "first element starts past the 2-entry offset table");
        // element 0 = 32 (len) + 4 bytes padded to 32 => 64 bytes total.
        assert_eq!(o1, 64 + 64, "second offset must clear element 0 INCLUDING its padding");

        let base = routes_at + 32;                       // offsets are relative to here
        assert_eq!(at(base + o0), 4,  "element 0 declares its true length");
        assert_eq!(at(base + o1), 33, "element 1 declares its true length");
        assert_eq!(&d[4 + base + o0 + 32..4 + base + o0 + 36], &[0xDEu8; 4][..]);
        assert_eq!(&d[4 + base + o1 + 32..4 + base + o1 + 65], &[0xEFu8; 33][..]);
        // 33 bytes pads to 64, so the whole payload ends on a word boundary.
        assert_eq!((d.len() - 4) % 32, 0, "calldata is not word-aligned");
    }

    /// The compat shape the contract accepts: empty `dex2s`/`routes` ⇒ legacy single-hop for all.
    #[test]
    fn encode_rebalance_many_accepts_the_empty_compat_shape() {
        let lps = vec![LpAddr::from([0x11u8; 20])];
        let d = encode_batch5(RM_SIG, &lps, &[[0xAAu8; 32]], &[], &[]);
        let word = |i: usize| -> u64 {
            let b = &d[4 + i * 32..4 + (i + 1) * 32];
            u64::from_be_bytes(b[24..32].try_into().unwrap())
        };
        assert_eq!(word(3), 0xa0 + 64 * 3, "dex2s offset with n=1");
        let r = word(4) as usize;
        let at = |off: usize| -> u64 {
            let b = &d[4 + off..4 + off + 32];
            u64::from_be_bytes(b[24..32].try_into().unwrap())
        };
        assert_eq!(at(word(3) as usize), 0, "dex2s must encode as a ZERO-length array");
        assert_eq!(at(r), 0, "routes must encode as a ZERO-length array");
        assert_eq!(4 + r + 32, d.len(), "nothing may trail an empty routes array");
    }

    fn vq(v: u8, ray: u128, bps: u32, fundable: bool) -> VenueQuote {
        VenueQuote { venue: [v; 20], borrow_rate_ray: ray, route_cost_bps: bps, fundable }
    }
    /// 4% APR expressed in RAY per year.
    const RAY_4PCT: u128 = 40_000_000_000_000_000_000_000_000;      // 0.04 * 1e27
    const RAY_6PCT: u128 = 60_000_000_000_000_000_000_000_000;      // 0.06 * 1e27

    /// §SESS-45 — the RAY/year -> bps conversion, pinned. The Morpho venue's own docblock warns that
    /// getting this lift wrong "does not revert -- it silently reports a venue as ~3e7x cheaper", so
    /// the unit is asserted rather than assumed.
    #[test]
    fn score_converts_ray_per_year_to_bps_correctly() {
        // 4% for a full year, no route cost => 400 bps.
        let s = score_bps(&vq(1, RAY_4PCT, 0, true), 365).unwrap();
        assert_eq!(s, 400, "4% APR over a year must be 400 bps");
        // half a year => half the carry.
        assert_eq!(score_bps(&vq(1, RAY_4PCT, 0, true), 182).unwrap(), 199);
        // route cost is one-off and adds on top, undiscounted by horizon.
        assert_eq!(score_bps(&vq(1, RAY_4PCT, 25, true), 365).unwrap(), 425);
    }

    /// ⭐ §SESS-45 — **THE POINT OF SCORING JOINTLY.** A venue that is CHEAPER TO BORROW but DEARER TO
    /// ROUTE must lose to the opposite pair once the horizon is short enough that the one-off toll
    /// dominates. Scoring the two axes separately picks the wrong venue here, which is the failure
    /// this function exists to prevent.
    #[test]
    fn joint_scoring_beats_scoring_either_axis_alone() {
        let cheap_borrow_dear_route = vq(1, RAY_4PCT, 300, true);   // 4% + 300 bps toll
        let dear_borrow_cheap_route = vq(2, RAY_6PCT, 2, true);     // 6% + 2 bps toll
        // Rate alone would pick venue 1; route alone would pick venue 2.
        assert!(cheap_borrow_dear_route.borrow_rate_ray < dear_borrow_cheap_route.borrow_rate_ray);
        assert!(dear_borrow_cheap_route.route_cost_bps < cheap_borrow_dear_route.route_cost_bps);
        // Over 30 days the toll dominates: venue 2 wins.
        let (v30, _) = pick_cheapest(&[cheap_borrow_dear_route, dear_borrow_cheap_route], 30).unwrap();
        assert_eq!(v30, [2u8; 20], "over a SHORT horizon the one-off route toll must dominate");
        // Over 3 years the rate dominates: venue 1 wins. Same inputs, opposite answer.
        let (v3y, _) = pick_cheapest(&[cheap_borrow_dear_route, dear_borrow_cheap_route], 1095).unwrap();
        assert_eq!(v3y, [1u8; 20], "over a LONG horizon the borrow rate must dominate");
    }

    /// 🔴 §SESS-45 — an UNFUNDABLE venue is excluded, never merely ranked last. `borrowRateRay` reverts
    /// `VenueCannotFund()` rather than returning "a flattering number for a draw that cannot happen",
    /// so the liquidity-at-size check arrives with the rate and must not be discarded here.
    #[test]
    fn unfundable_venues_are_excluded_not_ranked() {
        let unfundable_but_free = vq(1, 0, 0, false);               // would score 0 = best, if counted
        let fundable_but_dear   = vq(2, RAY_6PCT, 300, true);
        assert!(score_bps(&unfundable_but_free, 30).is_none(), "an unfundable venue has no score");
        let (v, _) = pick_cheapest(&[unfundable_but_free, fundable_but_dear], 30).unwrap();
        assert_eq!(v, [2u8; 20], "a venue that cannot fund the size was selected");
        assert!(pick_cheapest(&[unfundable_but_free], 30).is_none(), "no fundable venue must be None");
        assert!(pick_cheapest(&[], 30).is_none(), "an empty candidate set must be None");
    }

    /// §SESS-45 — ties break on the LOWER route cost: a one-off toll is certain where a rate is a
    /// forecast. Without this the winner depends on candidate ORDER, which is not a decision.
    #[test]
    fn ties_break_toward_the_certain_cost() {
        // 6% over 365d = 600 bps; pair each with tolls that make the totals equal.
        let a = vq(1, RAY_6PCT, 10, true);                          // 600 + 10 = 610
        let b = vq(2, RAY_4PCT, 210, true);                         // 400 + 210 = 610
        assert_eq!(score_bps(&a, 365), score_bps(&b, 365), "premise: the scores must actually tie");
        assert_eq!(pick_cheapest(&[a, b], 365).unwrap().0, [1u8; 20], "tie must go to the lower toll");
        assert_eq!(pick_cheapest(&[b, a], 365).unwrap().0, [1u8; 20], "and must not depend on order");
    }

    /// §SESS-25 — the planner emits a word whose PROTOCOL bits and ADDRESS are where the contract
    /// looks for them. `_aggSwap` reads `dex >> 253` and `uint160(dex)`; a word that packs either
    /// The word layout the contract decodes: pool in the low 160 bits, protocol = UniswapV3 at
    /// bits 253-255. §SESS-49 deleted the pool TABLE, so this now tests `v3_word` directly — the
    /// encoding survived; only where the pool comes from changed.
    #[test]
    fn word_layout_matches_what_the_contract_decodes() {
        let pool: LpAddr = [0x88,0xe6,0xA0,0xc2,0xdD,0xD2,0x6F,0xEE,0xb6,0x4F,
                            0x03,0x9a,0x2c,0x41,0x29,0x6F,0xcB,0x3f,0x56,0x40];
        let w = v3_word(pool);
        assert_eq!(&w[12..], &pool[..], "pool must sit in the low 160 bits");
        assert_eq!(w[0] >> 5, 1, "protocol nibble must be UniswapV3 (1) at bits 253-255");
    }

    /// 🔴 **THE KEEPER NAMES POOLS, NEVER DIRECTIONS.** `_aggSwap` derives `ZERO_FOR_ONE` from
    /// `tokenIn`/`tokenOut` and DISCARDS whatever the keeper set, so one word must serve a lever-up
    /// and the de-lever that unwinds it. A word that carried a direction would let the two disagree.
    #[test]
    fn planner_never_sets_the_direction_bit() {
        let pool: LpAddr = [0x11; 20];
        let w = v3_word(pool);
        assert_eq!(w[1] & 0x80, 0, "bit 247 (ZERO_FOR_ONE) must be left clear for the contract");
    }

    /// ⭐ §SESS-49 — **AGAINST MAINNET, NOT A MOCK.** CLAUDE.md standing rule 5 is *"don't mock, use
    ///    real addresses"*, and a mocked quoter would assert only that my own canned numbers compare
    ///    correctly — it could not catch a wrong factory address, a wrong `getPool` signature, a wrong
    ///    tuple encoding, or a QuoterV2 that reverts on the tier we ask for. **Every one of those is a
    ///    way this feature fails in production, and none of them is reachable from a fixture.**
    /// ⚠️ Skips (loudly) when no endpoint is configured, so the suite still runs offline. A skip is
    ///    announced rather than silent, because a quiet skip is indistinguishable from a pass.
    fn live_rpc() -> Option<crate::transport::HttpJsonRpc> {
        let url = std::env::var("ETH_RPC_URL").or_else(|_| std::env::var("ANKR_RPC_URL")).ok()?;
        if url.is_empty() { return None; }
        Some(crate::transport::HttpJsonRpc::new(url))
    }

    /// 🔴 **THE CLAIM THE DELETED TABLE COULD NOT MAKE: FOURTEEN STABLES, NOT TWO.**
    ///
    /// `direct_pool` was a four-entry table and could plan exactly **USDT and DAI** of the basket's
    /// **fourteen** (`DeployL1_s:240-250`). Asking the factory covers whatever exists, including
    /// tokens nobody has written down. ⚠️ **This asserts COVERAGE, not a price** — how many bps a
    /// ⭐ §SESS-81 — **THE COVERAGE MATRIX: ALL FOURTEEN BASKET STABLES x {WETH, WBTC}.**
    ///
    /// 🔴 **EVERY EARLIER TEST IN THIS FILE CHECKED A SAMPLE** — USDT, DAI, GHO, USDe — and a sample
    ///    cannot answer the question the lane actually has, which is *"can the protocol convert ANY
    ///    stable it holds into the two volatiles it hedges with?"* The basket is fourteen stables
    ///    (`DeployL1_s:240-250`) and the lever needs WETH and WBTC. **This is that grid.**
    /// ⚠️ It ASSERTS a floor and REPORTS the rest, because coverage is market state: a pair with no
    ///    venue today may have one next month and vice versa. Asserting the exact set would be the
    ///    §POINT-IN-TIME mistake this session has already made three times.
    /// ⛔ **A HUB ROUTE COUNTS.** `stable -> USDC -> volatile` is what the planner actually emits, so
    ///    a stable with no DIRECT pool is still covered. Reporting only direct pairs would understate
    ///    coverage badly — and reporting only hub routes would hide that some stables have neither.
    #[test]
    fn coverage_every_basket_stable_to_both_volatiles() {
        let Some(rpc) = live_rpc() else { println!("SKIP coverage: no RPC"); return };
        // 🔴 **ADDRESSES ARE PARSED FROM HEX, NOT HAND-TYPED AS BYTES — AND THIS IS WHY.**
        //    The first version wrote each address as a 20-element byte literal and I got USDe wrong:
        //    `…086C759E` **8BC98B325b866Df3** against the real **8383e09bff1E68B3**. The RPC answered
        //    correctly, `getPool` returned zero for an address that does not exist, and the coverage
        //    matrix reported **USDe as unroutable to both volatiles** — a fabricated tail wearing a
        //    market finding's clothes. ⚠️ It would have propagated: I was about to publish 11/14.
        //    ⇒ **hex strings are diffable against `DeployL1_s` by eye; byte arrays are not.**
        fn a(h: &str) -> LpAddr {
            let b = alloy_primitives::hex::decode(h.trim_start_matches("0x")).expect("bad address hex");
            let mut o = [0u8; 20]; o.copy_from_slice(&b); o
        }
        let stables: [(&str, LpAddr, u32); 14] = [
            ("USDC",   a("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), 6),
            ("USDT",   a("0xdAC17F958D2ee523a2206206994597C13D831ec7"), 6),
            ("DAI",    a("0x6B175474E89094C44Da98b954EedeAC495271d0F"), 18),
            ("PYUSD",  a("0x6c3ea9036406852006290770BEdFcAbA0e23A0e8"), 6),
            ("GHO",    a("0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f"), 18),
            ("RLUSD",  a("0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD"), 18),
            ("USDG",   a("0xe343167631d89B6Ffc58B88d6b7fB0228795491D"), 6),
            ("USDS",   a("0xdC035D45d973E3EC169d2276DDab16f1e407384F"), 18),
            ("USDE",   a("0x4c9EDD5852cd905f086C759E8383e09bff1E68B3"), 18),
            ("AUSD",   a("0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a"), 6),
            ("CUSD",   a("0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC"), 18),
            ("CRVUSD", a("0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E"), 18),
            ("FRXUSD", a("0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29"), 18),
            ("BOLD",   a("0x6440f144b7e50D6a8439336510312d2F54beB01D"), 18),
        ];
        let wbtc = a("0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599");
        println!("{:<8} {:>26} {:>26}", "stable", "-> WETH", "-> WBTC");
        let mut both = 0usize;
        for (name, addr, dec) in stables {
            let amt = U256::from(100_000u64) * U256::from(10u64).pow(U256::from(dec));
            let mut cells = Vec::new();
            for vol in [WETH_ADDR, wbtc] {
                let direct = !venues_for(&rpc, addr, vol, amt).is_empty();
                let hub = addr != USDC_ADDR
                    && !venues_for(&rpc, addr, USDC_ADDR, amt).is_empty()
                    && !venues_for(&rpc, USDC_ADDR, vol, amt).is_empty();
                cells.push(match (direct, hub) {
                    (true, _) => "direct".to_string(),
                    (false, true) => "via USDC".to_string(),
                    _ => "** NONE **".to_string(),
                });
            }
            if cells.iter().all(|c| c != "** NONE **") { both += 1; }
            println!("{name:<8} {:>26} {:>26}", cells[0], cells[1]);
        }
        println!("\n{both}/14 stables reach BOTH volatiles at $100k");
        // A floor, not the exact set: the hub itself plus the deep majors must always route.
        assert!(both >= 4, "only {both}/14 stables reach both volatiles - that is below anything the \
                            lever could operate on, so it is a broken search or a dead endpoint");
    }

    /// ⭐ §SESS-80 — **THE CACHE'S ACCEPTANCE TEST: THE SECOND LOOKUP MUST NOT RE-DISCOVER.**
    ///
    /// 🔑 The point is that discovery is rare and quoting is per-plan, so the property to assert is
    ///    that a warm call does no discovery — NOT that it returns the same winner, which it need not:
    ///    the winner is size- and block-dependent by design.
    /// ⚠️ Measured by wall time, which CLAUDE.md rightly calls a weak instrument (*"seconds measure
    ///    the machine's load"*). It earns its place only because the gap is an order of magnitude: a
    ///    cold call makes ~20 RPC round trips and a warm one makes ZERO. **A 5x margin survives
    ///    contention that a 20% one would not.**
    #[test]
    fn the_venue_cache_stops_rediscovery_on_the_second_lookup() {
        let Some(rpc) = live_rpc() else { println!("SKIP venue cache: no RPC"); return };
        let amt = U256::from(100_000u64) * U256::from(1_000_000u64);
        let t0 = std::time::Instant::now();
        let cold = venues_for(&rpc, USDC_ADDR, WETH_ADDR, amt);
        let cold_ms = t0.elapsed().as_millis().max(1);
        let t1 = std::time::Instant::now();
        let warm = venues_for(&rpc, USDC_ADDR, WETH_ADDR, amt);
        let warm_ms = t1.elapsed().as_millis();
        println!("cold {cold_ms}ms -> warm {warm_ms}ms   candidates: {}", cold.len());
        for v in &cold { println!("   {v:?}"); }
        assert!(!cold.is_empty(), "no candidates for USDC/WETH - discovery or the endpoint is broken");
        assert_eq!(cold, warm, "the warm lookup returned a different candidate SET");
        assert!(warm_ms * 5 < cold_ms, "warm lookup was not far faster ({warm_ms}ms vs {cold_ms}ms)");
        // ⛔ **THE REVERSE PAIR MUST HIT THE SAME ENTRY.** A venue serving a->b serves b->a and the
        //    contract derives direction itself, so keying per-direction would store one fact twice.
        let t2 = std::time::Instant::now();
        let rev = venues_for(&rpc, WETH_ADDR, USDC_ADDR, amt);
        assert_eq!(rev, cold, "the reversed pair discovered separately - the key is not unordered");
        assert!(t2.elapsed().as_millis() * 5 < cold_ms, "reversed pair re-discovered");
    }

    /// route costs is market state and belongs in a log, per §POINT-IN-TIME-IS-NOT-AN-INVARIANT.
    #[test]
    fn best_plan_finds_routes_the_deleted_table_never_could() {
        let Some(rpc) = live_rpc() else {
            println!("SKIP best_plan_finds_routes: no ETH_RPC_URL/ANKR_RPC_URL"); return;
        };
        // Stables the old table had NO entry for. USDC is the hub and is excluded by construction.
        // ⚠️ **DECIMALS PER TOKEN, NOT A SHARED CONSTANT.** A first version passed $100k as 6-dec for
        //    every case, so DAI/GHO/USDe were quoted for 1e-13 of a token and returned nothing — which
        //    the test reported as "no route", i.e. **a units bug wearing a routing failure's clothes.**
        //    This repo's oldest documented bug class is exactly this (`BasketLib:282`: never infer a
        //    stable's decimals, read them).
        let cases: [(&str, LpAddr, u32); 4] = [
            ("USDT",   USDT_ADDR, 6),
            ("DAI",    DAI_ADDR, 18),
            ("GHO",    [0x40,0xD1,0x6F,0xC0,0x24,0x6a,0xD3,0x16,0x0C,0xcc,
                        0x09,0xB8,0xD0,0xD3,0xA2,0xcD,0x28,0xaE,0x6C,0x2f], 18),
            ("USDe",   [0x4c,0x9E,0xDD,0x58,0x52,0xcd,0x90,0x5f,0x08,0x6C,
                        0x75,0x9E,0x8B,0xC9,0x8B,0x32,0x5b,0x86,0x6D,0xf3], 18),
        ];
        let mut planned = 0;
        for (name, stable, dec) in cases {
            let amt = U256::from(100_000u64) * U256::from(10u64).pow(U256::from(dec));   // $100k
            match best_plan(&rpc, stable, WETH_ADDR, amt) {
                Some(p) => {
                    planned += 1;
                    assert_ne!(p.dex, [0u8; 32], "{name}: planned a ZERO volatile hop");
                    println!("{name} -> WETH planned, two-hop={}", p.dex2 != [0u8; 32]);
                }
                None => println!("{name} -> WETH: no route quoted at this block"),
            }
        }
        // ⚠️ **NOT "how many planned" — THAT BAR FIGHTS THE DEPTH GATE.** §SESS-67 rejects a venue
        //    that is too thin for the size, and MEASURED, GHO deserves rejecting: its UniV3 pools hold
        //    **211 and 8,179 GHO**, and GHO/WETH holds **0 across all four tiers.** Before the gate
        //    this planner named the 8,179-GHO pool for a $100k trade. **A planner that plans MORE
        //    routes is not better; one that plans only fillable ones is.**
        assert!(planned >= 1, "nothing planned at all - that is not a depth gate, that is a broken \
                               search or a dead endpoint");
    }

    /// 🔴 ⭐ §SESS-67 — **THE DEPTH GATE'S KNOWN POSITIVE.** A gate is unverified code like any other,
    ///    and CLAUDE.md is explicit that *"the acceptance test for a detector is the KNOWN POSITIVE,
    ///    not a clean run"*. So this asserts it REJECTS a pool measured to be too thin, and ACCEPTS one
    ///    measured to be deep — against mainnet, at a size where the answer differs.
    /// ⚠️ Both halves matter: a gate that rejects everything would pass a rejection-only test while
    ///    silently disabling routing.
    #[test]
    fn the_depth_gate_rejects_a_thin_pool_and_accepts_a_deep_one() {
        let Some(rpc) = live_rpc() else { println!("SKIP depth gate: no RPC"); return };
        const GHO: LpAddr = [0x40,0xD1,0x6F,0xC0,0x24,0x6a,0xD3,0x16,0x0C,0xcc,
                             0x09,0xB8,0xD0,0xD3,0xA2,0xcD,0x28,0xaE,0x6C,0x2f];
        let hundred_k_18 = U256::from(100_000u64) * U256::from(10u64).pow(U256::from(18u32));
        let one_m_6      = U256::from(1_000_000u64) * U256::from(1_000_000u64);

        // THIN: the GHO/USDC 0.01% pool holds ~211 GHO (measured 2026-09-07).
        if let Some(thin) = pool_for(&rpc, GHO, USDC_ADDR, 100) {
            assert!(!deep_enough(&rpc, thin, GHO, hundred_k_18),
                "a pool holding ~211 GHO was accepted for a $100k trade");
        }
        // DEEP: USDC/WETH 0.05% holds ~77.2M USDC.
        let deep = pool_for(&rpc, USDC_ADDR, WETH_ADDR, 500).expect("USDC/WETH 0.05% must exist");
        assert!(deep_enough(&rpc, deep, USDC_ADDR, one_m_6),
            "a pool holding ~77M USDC was rejected for a $1m trade - the gate is not merely strict, \
             it is broken, and a gate that rejects everything disables routing while passing a \
             rejection-only test");
    }

    /// ⭐ **THE §SESS-49 PROPERTY ITSELF: the chosen plan must never quote worse than the best DIRECT
    ///    pool.** That is exactly the regression the old planner had — it returned the direct pool
    ///    whenever one existed and never priced the hub route, leaving ~23 bps at $1M on USDC→WETH.
    /// ⚠️ **NOT "the two-hop always wins" — that is false and block-dependent** (at $50k direct wins).
    ///    The invariant is that taking the max cannot be worse than one of its arguments, which is a
    ///    SHAPE and holds at every block. A planner that preferred the 2-hop unconditionally, or one
    ///    that short-circuited on direct, both fail this.
    #[test]
    fn best_plan_is_never_worse_than_the_best_direct_pool() {
        let Some(rpc) = live_rpc() else {
            println!("SKIP best_plan_is_never_worse: no ETH_RPC_URL/ANKR_RPC_URL"); return;
        };
        let amt = U256::from(1_000_000u64) * U256::from(1_000_000u64);  // $1m, 6-dec — where it bit
        let Some((_, direct_out)) = best_direct(&rpc, USDC_ADDR, WETH_ADDR, amt) else {
            println!("SKIP: no direct USDC/WETH quote at this block"); return;
        };
        let p = best_plan(&rpc, USDC_ADDR, WETH_ADDR, amt).expect("a route must exist for USDC/WETH");
        let (p2, chosen) = best_plan_quoted(&rpc, USDC_ADDR, WETH_ADDR, amt)
            .expect("the chosen plan must re-quote");
        assert_eq!(p2.dex, p.dex, "the two entrypoints must agree on the plan");

        // Price the hub route independently, so the assertion can tell "priced and lost" from
        // "never priced". USDC is the INPUT here — the case that used to be skipped outright.
        let via_hub = best_direct(&rpc, USDC_ADDR, USDT_ADDR, amt)
            .and_then(|(_, mid)| best_direct(&rpc, USDT_ADDR, WETH_ADDR, mid))
            .map(|(_, out)| out)
            .unwrap_or(U256::ZERO);
        println!("direct {direct_out} · via-USDT {via_hub} · chosen {chosen} (two-hop={})",
                 p.dex2 != [0u8; 32]);

        assert!(chosen >= direct_out,
            "the planner chose a route quoting WORSE than the best direct pool: {chosen} < {direct_out}");
        // 🔴 **THE ONE THAT CATCHES A SKIPPED HUB.** §SESS-58 fixed a planner that never priced a
        //    two-hop when the INPUT was USDC. ⚠️ It cannot fail on a day when direct happens to win —
        //    and that is correct, not vacuous: it fires exactly on the days when skipping would cost
        //    us, which is the only time the bug has a consequence. Measured at 25919955 the hub route
        //    beat direct by ~23 bps; at 25924xxx the sign had flipped. A test pinned to either
        //    reading would be asserting the market (§POINT-IN-TIME-IS-NOT-AN-INVARIANT).
        assert!(chosen >= via_hub,
            "the planner ignored a BETTER two-hop through USDT: chosen {chosen} < via-hub {via_hub}");
    }

    /// §SESS-21 — the SAME encoder now serves `cascadeDelever`, so its selector gets its own pin.
    /// A shared encoder is only safe if both call sites are asserted; otherwise one drifts silently.
    #[test]
    fn encode_batch5_pins_the_cascade_delever_selector() {
        let d = encode_batch5(CD_SIG, &[LpAddr::from([2u8; 20])], &[[0u8; 32]], &[], &[]);
        assert_eq!(&d[..4], &keccak256(CD_SIG.as_bytes())[..4]);
        assert_ne!(&d[..4], &keccak256(RM_SIG.as_bytes())[..4],
            "the two batch selectors must not collide - one encoder, two distinct heads");
    }

    /// The selector MUST be the five-array one, or the validating signer refuses every batch.
    #[test]
    fn encode_rebalance_many_uses_the_allowlisted_selector() {
        let d = encode_batch5(RM_SIG, &[LpAddr::from([1u8; 20])], &[[0u8; 32]], &[], &[]);
        assert_eq!(&d[..4],
            &keccak256(RM_SIG.as_bytes())[..4]);
    }

    /// §POOL-VENUE — **THE POOL IS IN DANGER WHILE THIS LP LOOKS FINE, AND THE KEEPER MUST STILL ACT.**
    /// This is the case the old per-LP-only gate held straight through, and it is the whole reason
    /// `pool_ltv_bps` exists: the venue runs ONE Morpho position, so Morpho's health check reads the
    /// aggregate. A keeper that waits for THIS LP to look unhealthy is waiting for a signal that may
    /// never come before the pool is seized — and a pooled seizure hits every LP pro-rata.
    #[test]
    fn pooled_risk_triggers_urgent_delever_even_when_this_lp_is_healthy() {
        let mut v = base();
        v.current_ltv_bps = 3000;                 // this LP is comfortable
        v.pool_ltv_bps = 8600;                    // the BOOK is one tick from liquidation
        v.venue_liq_ltv_bps = 8600;
        v.mature_quid_usd = 0;                    // no QUID to protect with => straight to de-lever
        let cfg = LevKeeperConfig::default();
        assert!(
            matches!(decide(&v, &cfg), KeeperAction::DeLever { urgent: true, .. }),
            "a pool at the liquidation threshold must fire an URGENT de-lever regardless of \
             how healthy the individual LP looks"
        );
    }

    /// The CONTROL, and it is what makes the test above mean anything: with the pool figure at the
    /// LP's own level, the decision is byte-identical to the old per-LP gate. `max(pool, lp)` is a
    /// SUPERSET of the previous behaviour, never a replacement — so this cannot make the keeper act
    /// less often, only more.
    #[test]
    fn pooled_gate_is_a_superset_never_a_substitute() {
        let mut healthy = base();
        healthy.current_ltv_bps = 3000;
        healthy.pool_ltv_bps = 3000;
        healthy.venue_liq_ltv_bps = 8600;
        let cfg = LevKeeperConfig::default();
        assert!(!matches!(decide(&healthy, &cfg), KeeperAction::DeLever { urgent: true, .. }),
            "a healthy pool AND a healthy LP must not fire the urgent track");

        // And the mirror: this LP blown out while the pool average hides it still fires.
        let mut blown = base();
        blown.current_ltv_bps = 8600;
        blown.pool_ltv_bps = 2000;
        blown.venue_liq_ltv_bps = 8600;
        blown.mature_quid_usd = 0;
        assert!(matches!(decide(&blown, &cfg), KeeperAction::DeLever { urgent: true, .. }),
            "a single blown-out LP must still fire even when the pool average hides it");
    }

    fn base() -> PositionView {
        PositionView {
            current_ltv_bps: 5000,
            // Fixtures mirror the per-LP LTV into the pool figure, so every PRE-EXISTING case
            // keeps its old meaning: `max(pool, lp)` reduces to the per-LP gate it replaced.
            // The pooled-risk cases set them APART deliberately.
            pool_ltv_bps: 5000,
            il_ltv_bps: 5000,
            target_ltv_bps: 5000,
            venue_liq_ltv_bps: 9000,
            collateral_usd: 100_000_000_000, // $100k
            deliverable_floor_ok: true,
            move_persisted: true, // default: the move has settled (most tests exercise the IL track)
            mature_quid_usd: 0,   // default no mature QUID (protect off ⇒ safety = de-lever)
            wbtc_mode: false,
        }
    }

    #[test]
    fn protect_from_quid_preferred_when_urgent_and_quid_held() {
        // Near venue liquidation AND the LP holds mature QUID ⇒ repay from QUID (protect collateral),
        // NOT sell it. collateral_usd is net-equity; at cur=7600 the repay-to-target is bounded by the QUID.
        let mut v = base();
        v.current_ltv_bps = 7600;      // urgent (venue_liq 9000 − 1500 margin = 7500)
        v.mature_quid_usd = 10_000_000_000; // $10k mature QUID
        match decide(&v, &LevKeeperConfig::default()) {
            KeeperAction::ProtectFromQuid { repay_usd } => {
                assert!(repay_usd > 0 && repay_usd <= v.mature_quid_usd, "repay bounded by held mature QUID");
            }
            other => panic!("urgent + mature QUID must protect from QUID first, got {other:?}"),
        }
        // ...but with NO mature QUID, it must fall to the collateral-selling de-lever (safety unchanged).
        v.mature_quid_usd = 0;
        match decide(&v, &LevKeeperConfig::default()) {
            KeeperAction::DeLever { urgent, .. } => assert!(urgent),
            other => panic!("no QUID ⇒ urgent de-lever, got {other:?}"),
        }
    }

    #[test]
    fn il_target_matches_1_minus_inv_sqrt_r() {
        assert_eq!(il_target_ltv_bps(1.0, 1.0), 0); // flat → no IL → no leverage
        assert_eq!(il_target_ltv_bps(1.0, 0.8), 0); // DOWN → no IL accrued
        assert_eq!(il_target_ltv_bps(1.0, 2.0), 2929); // 2× → 1 − 1/√2 = 29.3%
        assert_eq!(il_target_ltv_bps(1.0, 4.0), 5000); // 4× → 50%, hits the 2× cap
    }

    #[test]
    fn dwell_gates_noise_but_not_safety() {
        // A move that hasn't persisted must NOT trigger the IL-target rebalance (anti-churn).
        let mut v = base();
        v.move_persisted = false;
        v.il_ltv_bps = 5500; // above range, but un-persisted ⇒ hold (don't realize IL on noise)
        assert_eq!(decide(&v, &LevKeeperConfig::default()), KeeperAction::Hold);
        // ...but an URGENT (near venue-liq) breach must still fire even un-persisted.
        v.current_ltv_bps = 7600;
        match decide(&v, &LevKeeperConfig::default()) {
            KeeperAction::DeLever { urgent, .. } => assert!(urgent),
            other => panic!("safety must override the dwell, got {other:?}"),
        }
    }

    #[test]
    fn holds_inside_range() {
        let mut v = base();
        v.il_ltv_bps = 5200; // within ±300 of 5000
        assert_eq!(decide(&v, &LevKeeperConfig::default()), KeeperAction::Hold);
    }

    #[test]
    fn delevers_above_range() {
        let mut v = base();
        v.il_ltv_bps = 5500; // > 5000 + 300
        assert_eq!(
            decide(&v, &LevKeeperConfig::default()),
            KeeperAction::DeLever { to_ltv_bps: 5000, urgent: false }
        );
    }

    #[test]
    fn urgent_delever_overrides_everything_near_venue_liq() {
        let mut v = base();
        // target is high but a gap pushed LTV within safety_margin of venue liq (9000−1500=7500)
        v.target_ltv_bps = 5000;
        v.current_ltv_bps = 7600;
        let a = decide(&v, &LevKeeperConfig::default());
        assert_eq!(a, KeeperAction::DeLever { to_ltv_bps: 5000, urgent: true });
    }

    #[test]
    fn urgent_bypasses_economic_floor() {
        // tiny collateral so the move is below the $50 floor, but urgent must still fire
        let mut v = base();
        v.collateral_usd = 1_000_000; // $1
        v.current_ltv_bps = 7600;
        match decide(&v, &LevKeeperConfig::default()) {
            KeeperAction::DeLever { urgent, .. } => assert!(urgent),
            other => panic!("expected urgent de-lever, got {other:?}"),
        }
    }

    #[test]
    fn relever_gated_on_deliverable_floor() {
        let mut v = base();
        v.il_ltv_bps = 4000; // below 5000 − 300 → wants to re-lever
        assert_eq!(
            decide(&v, &LevKeeperConfig::default()),
            KeeperAction::ReLever { to_ltv_bps: 5000 }
        );
        // but if the unlocked deliverable floor is exhausted, do NOT re-lever
        v.deliverable_floor_ok = false;
        assert_eq!(decide(&v, &LevKeeperConfig::default()), KeeperAction::Hold);
    }

    #[test]
    fn skips_uneconomic_nonurgent_move() {
        let mut v = base();
        v.collateral_usd = 1_000_000; // $1 → a 500bps move is $0.05, below $50 floor
        v.il_ltv_bps = 5500;
        assert_eq!(decide(&v, &LevKeeperConfig::default()), KeeperAction::Hold);
    }


    #[test]
    fn protect_from_quid_calldata_and_scaling() {
        // DELEGATED executor: ONE constrained call to the LevManager entrypoint — the redeem (pro-rata) →
        // multi-route consolidation → repay all happen ON-CHAIN, so the keeper only encodes protectFromQuid(lp, 0).
        assert_eq!(selector4("protectFromQuid(address,uint256)"), keccak256(b"protectFromQuid(address,uint256)")[..4].to_vec());
        // The mature-QUID read that GATES the decision (position_view): 18-dec QUID → 6-dec USD is /1e12.
        let mature_18 = U256::from(5_000_000_000_000_000_000u128); // 5 QUID
        let mature_usd: u64 = (mature_18 / U256::from(1_000_000_000_000u64)).try_into().unwrap();
        assert_eq!(mature_usd, 5_000_000); // $5.000000
    }

    use std::cell::RefCell;
    struct MockEvm {
        views: Vec<(LpAddr, PositionView)>,
        rebalanced: RefCell<Vec<LpAddr>>,
        cascaded: RefCell<Vec<LpAddr>>,
        synced: RefCell<Vec<LpAddr>>,
        protected: RefCell<Vec<(LpAddr, u64)>>,
    }
    impl LevKeeperEvm for MockEvm {
        async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>> {
            Ok(self.views.iter().map(|(a, _)| *a).collect())
        }
        async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView> {
            Ok(self.views.iter().find(|(a, _)| *a == lp).unwrap().1)
        }
        async fn rebalance(&self, lp: LpAddr) -> anyhow::Result<()> {
            self.rebalanced.borrow_mut().push(lp);
            Ok(())
        }
        async fn cascade_delever(&self, lps: &[LpAddr], _routes: &[Vec<u8>]) -> anyhow::Result<()> {
            self.cascaded.borrow_mut().extend_from_slice(lps);
            Ok(())
        }
        async fn rebalance_many(&self, lps: &[LpAddr], _routes: &[Vec<u8>]) -> anyhow::Result<()> {
            self.rebalanced.borrow_mut().extend_from_slice(lps);   // same sink as rebalance ⇒ existing assertions hold
            Ok(())
        }
        async fn sync_lev(&self, lp: LpAddr) -> anyhow::Result<()> {
            self.synced.borrow_mut().push(lp);
            Ok(())
        }
        async fn protect_from_quid(&self, lp: LpAddr, repay_usd: u64) -> anyhow::Result<()> {
            self.protected.borrow_mut().push((lp, repay_usd));
            Ok(())
        }
    }

    #[tokio::test]
    async fn loop_urgent_cascades_now_lazy_waits_for_dwell() {
        let urgent_lp = [1u8; 20];
        let noisy_lp = [2u8; 20];
        let mut uv = base();
        uv.current_ltv_bps = 7600; // near venue liq ⇒ urgent (ignores the dwell)
        let mut nv = base();
        nv.il_ltv_bps = 5500; // out of range but mean-reverting
        let evm = MockEvm {
            views: vec![(urgent_lp, uv), (noisy_lp, nv)],
            rebalanced: RefCell::new(vec![]),
            cascaded: RefCell::new(vec![]),
            synced: RefCell::new(vec![]),
            protected: RefCell::new(vec![]),
        };
        let mut dwell = DwellTracker::default();
        let cfg = LevKeeperConfig::default();
        // t=0: urgent cascades immediately; noisy just went out of range ⇒ NOT persisted ⇒ no churn.
        tick(&evm, &cfg, &mut dwell, 0, 600).await.unwrap();
        assert_eq!(*evm.cascaded.borrow(), vec![urgent_lp]);
        assert!(evm.rebalanced.borrow().is_empty(), "un-persisted noise must not churn");
        // t=700 (> 600s dwell) and still out of range ⇒ now persisted ⇒ the lazy rebalance fires.
        tick(&evm, &cfg, &mut dwell, 700, 600).await.unwrap();
        assert!(evm.rebalanced.borrow().contains(&noisy_lp), "persisted move must rebalance");
    }

    // Pure arithmetic — the self-funding gate that keeps the compound crank operator-subsidy-free. No mock
    // chain: the on-chain behaviour (the tip actually paid) is proven by the Solidity mainnet-fork test
    // `testCompound_SelfFundingTip`; here we only pin the keeper's crank/skip decision.
    #[test]
    fn compound_gate_cranks_only_when_the_tip_covers_the_gas() {
        let gas_price = 20_000_000_000u128; // 20 gwei
        let gas_cost = gas_price * COMPOUND_GAS; // what the on-chain tip is capped at
        // pending/2 must clear the gas cost: break-even is pending == 2*gas_cost.
        assert!(!compound_pays_for_itself(0, gas_price), "no fees ⇒ never crank");
        assert!(!compound_pays_for_itself(2 * gas_cost - 2, gas_price), "just under break-even ⇒ skip");
        assert!(compound_pays_for_itself(2 * gas_cost, gas_price), "exactly break-even ⇒ crank");
        assert!(compound_pays_for_itself(10 * gas_cost, gas_price), "fat fees ⇒ crank");
        // Higher gas raises the bar: the same pending that cranked at 20 gwei is skipped at 200 gwei.
        assert!(!compound_pays_for_itself(2 * gas_cost, gas_price * 10), "10x gas ⇒ same fees no longer cover it");
    }
}
