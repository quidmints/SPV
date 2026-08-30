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
//! 🔴 **BUT IT IS NO LONGER ISOLATED TO ONE LP, AND THIS PARAGRAPH SAID IT WAS.** It
//! read *"it hits that one LP, never the basket"*. Under §POOL-VENUE the venue runs
//! ONE Morpho position under `address(this)`, so a seizure hits the pool and
//! therefore **every LP pro-rata** — `LevVenueBase:117` states exactly that. The
//! basket half of the claim survives; the per-LP half does not.
//! ⇒ **THE CONSEQUENCE IS THAT THIS KEEPER MATTERS MORE, NOT LESS.** When a
//! liquidation was one LP's own problem, a keeper miss cost that LP. Pooled, a miss
//! is socialised across the book, so "the venue's engine is a never-triggered
//! backstop" is now a guarantee the keeper owes EVERY LP jointly. That is why the
//! safety gate reads [`PositionView::pool_ltv_bps`] — the aggregate Morpho actually
//! liquidates on — and not only the per-LP LTV it used to read.
//!
//! # The target is `L = 1/α`, never a pinned 2x
//! `α` = the realized range concavity (how √p-like the position is), measured from
//! flow via [`realized_alpha`]. Busy flow → `α→0.5` → `L→2` (cancel the IL the flow
//! created). Quiet → `α→1` → `L→1` (no leverage, because there is no realized IL to
//! cancel). Pinning `L=2` (ybamm's mistake) over-levers in quiet regimes and drains
//! the buffer; sizing to `α` is what bounds the tail. The LTV form is
//! `target_ltv = 1 − α` ([`target_ltv_bps_from_alpha`]).
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
    /// TRUE when the position's collateral is WBTC (the `AaveV3Venue`/`AaveV4Venue`/… WBTC-fallback route),
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
use crate::client::{JsonRpcEvmClient, TxSigner};
use crate::transport::JsonRpc;
use alloy_primitives::{Address, U256};
use std::sync::Arc;

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
            // §C2.1 — three STATIC words now: (lp, minOut, dex). The `bytes route` tail is gone,
            // and with it the offset word that made this the only hand-rolled dynamic head in the
            // keeper. The venue word is real, so this call no longer reverts `NoVolatileRoute()`.
            let mut data = selector4("rebalance(address,uint256,uint256,uint256)");
            data.extend_from_slice(&addr_word(lp));
            data.extend_from_slice(&u64_word(0));
            data.extend_from_slice(&dex_word());
            // hub pool word (stable->USDC). ZERO ⇒ the contract falls back to its legacy Curve
            // hub hop, which is exactly today's behaviour. Supply a real pool word here to let
            // the lever borrow a stable the old on-chain table never covered.
            data.extend_from_slice(&[0u8; 32]);
            evm.send_tx(lm, data, gas)?;
            Ok(())
        })
        .await?
    }

    async fn cascade_delever(&self, lps: &[LpAddr], _routes: &[Vec<u8>]) -> anyhow::Result<()> {
        let (evm, lm, gas, lps) =
            (self.evm.clone(), self.lev_manager, self.gas_limit, lps.to_vec());
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let dexes = vec![dex_word(); lps.len()];
            evm.send_tx(lm, encode_batch("cascadeDelever(address[],uint256[],uint256[])", &lps, &dexes), batch_gas(gas, lps.len()))?;
            Ok(())
        })
        .await?
    }

    /// Hold the whole book at its IL target in ONE tx. Gas scales with the batch (each LP is a flash-repay
    /// or lever-up), capped below the block limit; the on-chain loop is fault-tolerant + syncs each LP internally.
    async fn rebalance_many(&self, lps: &[LpAddr], _routes: &[Vec<u8>]) -> anyhow::Result<()> {
        let (evm, lm, gas, lps) =
            (self.evm.clone(), self.lev_manager, self.gas_limit, lps.to_vec());
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let dexes = vec![dex_word(); lps.len()];
            evm.send_tx(lm, encode_batch("rebalanceMany(address[],uint256[],uint256[])", &lps, &dexes), batch_gas(gas, lps.len()))?;
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
fn hex_lit_pool() -> [u8; 20] {
    [0x88,0xe6,0xA0,0xc2,0xdD,0xD2,0x6F,0xEE,0xb6,0x4F,
     0x03,0x9a,0x2c,0x41,0x29,0x6F,0xcB,0x3f,0x56,0x40]
}

/// ABI-encode `f(address[], uint256[], uint256[])` — the batch keeper entrypoints
/// (`rebalanceMany`, `cascadeDelever`).
///
/// ⭐ §C2.1 — **THIS USED TO ENCODE A `bytes[]` AND THAT SHAPE IS GONE.** The third argument was a
/// per-LP 1inch ROUTE, so this function had to lay out a dynamic array of dynamic elements: a
/// length, an offsets table, then each element as `(len, data)` padded to 32. It is now a per-LP
/// POOL WORD (`uint256`), because 1inch calldata embeds its own `amount` and every amount the
/// contract swaps is computed on-chain — a pre-built route could never match. See `_aggSwap`.
/// ⇒ The offsets table, the running `off` accumulator and the per-element padding all DELETE: three
/// static arrays, one layout, and no way to get an offset wrong. `dexes` is the same length as
/// `lps` because `_batch` requires it (`LenMismatch()`), which is asserted here rather than assumed.
fn encode_batch(sig: &str, lps: &[LpAddr], dexes: &[[u8; 32]]) -> Vec<u8> {
    debug_assert!(dexes.is_empty() || dexes.len() == lps.len(),
        "dexes must be per-LP or empty: `_batch` reverts LenMismatch() otherwise");
    let n = lps.len() as u64;
    let mut d = selector4(sig);
    let lps_at = 0x60u64;                       // after the 3 head words
    let mins_at = lps_at + 32 * (1 + n);        // after lps: len + n elems
    let dexes_at = mins_at + 32 * (1 + n);      // after minOuts: len + n elems
    d.extend_from_slice(&u64_word(lps_at));
    d.extend_from_slice(&u64_word(mins_at));
    d.extend_from_slice(&u64_word(dexes_at));
    d.extend_from_slice(&u64_word(n));
    for lp in lps { d.extend_from_slice(&addr_word(*lp)); }
    d.extend_from_slice(&u64_word(n));
    for _ in 0..n { d.extend_from_slice(&u64_word(0)); }   // minOuts: the oracle floor bounds each swap
    d.extend_from_slice(&u64_word(n));
    for i in 0..n as usize { d.extend_from_slice(&dexes.get(i).copied().unwrap_or([0u8; 32])); }
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

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
    fn calldata_encoding_is_abi_correct() {
        // selectors match keccak256(sig)[..4]
        assert_eq!(selector4("syncLev(address)"), keccak256(b"syncLev(address)")[..4].to_vec());
        assert_eq!(selector4("rebalance(address,uint256,uint256,uint256)"),
                   keccak256(b"rebalance(address,uint256,uint256,uint256)")[..4].to_vec());
        // address word = 12 zero bytes + 20-byte address (right-aligned)
        let lp: LpAddr = [0x11; 20];
        let w = addr_word(lp);
        assert_eq!(&w[..12], &[0u8; 12]);
        assert_eq!(&w[12..], &lp[..]);

        // §C2.1 — THREE STATIC ARRAYS. Was `bytes[]`, which needed an offsets table and per-element
        // (len, padded data); a pool word is one 32-byte value, so the tail is `len + n` like the
        // other two. 4 sel + head(3) + 3 * (len + 2 elems) = 4 + 32*12.
        const SIG: &str = "cascadeDelever(address[],uint256[],uint256[])";
        let dexes = vec![dex_word(); 2];
        let enc = encode_batch(SIG, &[[0xAA; 20], [0xBB; 20]], &dexes);
        assert_eq!(enc.len(), 4 + 32 * 12);
        assert_eq!(&enc[..4], &selector4(SIG)[..]);
        assert_eq!(&enc[4..36], &u64_word(0x60));            // offset to lps (3 head words)
        assert_eq!(&enc[36..68], &u64_word(0x60 + 32 * 3));  // offset to minOuts
        assert_eq!(&enc[68..100], &u64_word(0x60 + 32 * 6)); // offset to dexes
        assert_eq!(&enc[100..132], &u64_word(2));            // lps.length
        assert_eq!(&enc[132..164][12..], &[0xAAu8; 20]);     // lps[0], right-aligned
        assert_eq!(&enc[196..228], &u64_word(2));            // minOuts.length
        assert_eq!(&enc[292..324], &u64_word(2));            // dexes.length
        assert_eq!(&enc[324..356], &dex_word()[..]);         // dexes[0] IS the venue word
        assert_eq!(&enc[356..388], &dex_word()[..]);         // dexes[1] — one venue per LP

        // 🔴 THE ONE THAT MATTERS: the word is NON-ZERO. `_aggSwap` refuses `dex == 0` with
        // `NoVolatileRoute()`, and for the whole life of the `bytes route` interface this keeper
        // sent an empty tail and every tx reverted. A zero here is that outage, silently restored.
        assert_ne!(dex_word(), [0u8; 32], "the keeper must name a venue or every swap reverts");
        // Layout: UniswapV3 (protocol 1 at bits 253-255) in the top byte, pool in the low 160.
        assert_eq!(dex_word()[0], 1 << 5, "protocol bits must encode UniswapV3");
        assert_eq!(&dex_word()[12..], &hex_lit_pool()[..], "low 160 bits must be the pool");

        // 🔴 THE BTC KEEPER MUST NOT SEND THE ETH POOL. `_stableToWbtc` swaps USDC -> WBTC, so the
        // WETH/USDC pool would be handed a token it does not hold. Two venues, two words.
        assert_ne!(dex_word_wbtc(), dex_word(), "the WBTC keeper needs its own pool, not the WETH one");
        assert_eq!(dex_word_wbtc()[0], 1 << 5, "WBTC venue must also encode UniswapV3");
        assert_ne!(dex_word_wbtc(), [0u8; 32], "a zero word reverts NoVolatileRoute on arrival");
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
