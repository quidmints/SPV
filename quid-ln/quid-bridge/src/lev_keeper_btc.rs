//! BTC YB IL-protect **keeper** — the vBTC-collateral analogue of [`crate::lev_keeper`] (ETH weETH).
//!
//! It reuses the ETH keeper's PURE decision core verbatim ([`crate::lev_keeper::decide`],
//! [`crate::lev_keeper::DwellTracker`], [`PositionView`]): same LTV band, same `L = 1/α` IL target, same
//! safety-margin-below-venue-liquidation contract, same lazy/anti-churn dwell. What differs is the
//! **actuation**, because BTC acquisition crosses Bitcoin confirmation and therefore cannot be a single
//! atomic swap the way ETH's `rebalance` is (spec `LEVERAGE-BTC-M11-SPEC.md`):
//!
//!   * **Lever-up** is SPLIT: `leverBorrow(stableUsd)` (stable → keeper) → source BTC externally + mint
//!     vBTC against the attested channel UTXO → `leverSupply(vbtc)`.
//!   * **De-lever** is SPLIT: `deleverWithdraw(vbtc)` (vBTC → keeper) → burn + enclave-spend the UTXO + sell
//!     BTC → `repay(stableUsd)`.
//!
//! The native async BTC↔stable acquirer was REMOVED (#8): that rail (#59/#74) was never wired, and WBTC-mode
//! positions rebalance fully on-chain via `rebalance_wbtc` (atomic). A native position (should one exist) now
//! fails SAFE inline in do_delever/do_relever — a loud no-op → the venue's ISOLATED liquidation. The on-chain
//! legs live behind [`BtcLevKeeperEvm`], mocked in the unit tests.
//!
//! Fault-tolerance mirrors the ETH tick: one LP's failing read/leg must never abort the pass (a persistently
//! reverting LP can't stall the no-venue-liquidation guarantee for the rest of the book), and every un-sourced
//! de-lever `warn!`s loudly (the position falls to the venue's OWN isolated liquidation — that LP only, never
//! the basket).

use crate::abi::{addr_word, selector4, u64_word, word_to_lpaddr};
use crate::lev_keeper::{
    decide, out_of_band, DwellTracker, KeeperAction, LevKeeperConfig, LpAddr, PositionView,
};
use tokio::time::{timeout, Duration};

/// Per-leg RPC ceiling: a hung read/tx must never stall the SERIAL pass — the urgent de-levers run
/// first, so a single hang there would otherwise block the no-liquidation guarantee for every other LP.
/// On timeout we log and move on (the blocking JSON-RPC thread is abandoned; a 5-min poll makes that cheap).
const LEG_TIMEOUT: Duration = Duration::from_secs(45);

/// The BTC on-chain surface the loop needs (`BtcLevManager` reads + async legs). Every leg is `async`
/// because it maps to a signed tx (or an external round-trip), unlike ETH's atomic `rebalance`.
#[allow(async_fn_in_trait)]
pub trait BtcLevKeeperEvm {
    /// The open levered-LP set (`openLevCount` + `openLpAt`), re-read every pass (the omni-trigger union).
    async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>>;
    /// One position snapshot (`getCurrentLtvBps`/`ilTargetLtvBps`/`netEquityBtc` + the venue liq LTV).
    async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView>;
    /// `BtcLevManager.debtDeltaToTarget(lp)` → `(levUp, amountUsd_1e18)`: the stable move + direction to
    /// re-hit the IL target. Sizes both legs.
    async fn debt_delta(&self, lp: LpAddr) -> anyhow::Result<(bool, u128)>;
    /// USD(1e18) value of ONE BTC (`vBtcValueUsd(1e8)`) — the live oracle price, for USD↔sats sizing.
    async fn price_usd_per_btc(&self, lp: LpAddr) -> anyhow::Result<u128>;
    /// `leverBorrow(stableUsd)` — borrow toward the target; stable is sent to the keeper (for external BTC
    /// sourcing). Contract-clamped to the debt-delta room, so an over-ask can only reach the target.
    async fn lever_borrow(&self, lp: LpAddr, stable_usd: u128) -> anyhow::Result<()>;
    /// `leverSupply(vbtc)` — supply the newly-minted vBTC as additional collateral (second half of a lever-up).
    async fn lever_supply(&self, lp: LpAddr, vbtc_sats: u64) -> anyhow::Result<()>;
    /// `deleverWithdraw(vbtc)` — pull vBTC collateral to the keeper (to burn + sell → repay).
    async fn delever_withdraw(&self, lp: LpAddr, vbtc_sats: u64) -> anyhow::Result<()>;
    /// `repay(stableUsd)` — repay debt (the keeper must have approved the manager to pull the stable).
    async fn repay(&self, lp: LpAddr, stable_usd: u128) -> anyhow::Result<()>;
    /// Reconcile the LEVERED band slice to live net-equity (`Vault.syncLev`) after any position change,
    /// so the fee lane (`levPooledBTC`) tracks the equity promptly. Permissionless ⇒ non-fatal on failure.
    async fn sync_lev_btc(&self, lp: LpAddr) -> anyhow::Result<()>;
    /// Protect `lp` by repaying `repay_usd` (6-dec USD) from the LP's MATURE QUID — redeem mature QUID →
    /// venue stable → `repay`, PRESERVING the vBTC collateral. Redeem is mature-only, so no par-burn abuse.
    async fn protect_from_quid(&self, lp: LpAddr, repay_usd: u64) -> anyhow::Result<()>;
    /// `BtcLevManager.rebalanceWbtc(lp, minStableOut)` — the ATOMIC WBTC-mode rebalance: one permissionless,
    /// self-flooring on-chain call that fold-ups OR flash-repay-first de-levers to the IL target in a single
    /// tx (no acquirer, no async vBTC legs — the WBTC-fallback route holds real WBTC on Aave/Morpho/Euler).
    /// The contract enforces the anti-MEV oracle floor internally, so the keeper passes `minStableOut = 0`
    /// (it picks WHEN, not the price). Permissionless ⇒ any fleet signer triggers it; a revert is fail-safe.
    async fn rebalance_wbtc(&self, lp: LpAddr) -> anyhow::Result<()>;
}

// The external async BTC↔stable acquirer (BtcLevAcquirer trait + UnwiredNativeAcquirer stub) was REMOVED
// (2026-07-22, #8): the native channel-vBTC rail (#59/#74) was never wired and WBTC-mode positions rebalance
// fully on-chain via `rebalance_wbtc` (atomic, no async legs), so the acquirer indirection was dead. A native
// position (should one exist) now fails SAFE INLINE in do_delever/do_relever — a loud no-op that lets it fall
// to the venue's ISOLATED liquidation — instead of routing through a bailing stub.

#[allow(dead_code)] // reserved for the #59/#74 native rail
/// USD(1e18) → vBTC sats(8-dec), given `px` = USD(1e18) per 1 BTC. `sats = usd · 1e8 / px`. Saturates to 0
/// on a zero/absurd price (the caller then no-ops that leg rather than sizing off a bad oracle read).
fn usd_to_vbtc_sats(usd_1e18: u128, px_usd_per_btc_1e18: u128) -> u64 {
    if px_usd_per_btc_1e18 == 0 {
        return 0;
    }
    let sats = usd_1e18.saturating_mul(100_000_000) / px_usd_per_btc_1e18;
    sats.try_into().unwrap_or(u64::MAX)
}

/// ONE pass — split out for deterministic testing (no sleep, explicit `now`). Reads every open BTC-lev
/// position, applies the shared dwell + [`decide`], and routes each to its actuator (WBTC → atomic
/// `rebalance_wbtc`; native → the unwired-rail fail-safe no-op).
/// Fault-tolerant per-LP (a failing read/leg is warned and skipped, never aborting the pass); urgent
/// de-levers are handled first so the no-liquidation guarantee never queues behind non-urgent work.
pub async fn btc_tick<E: BtcLevKeeperEvm>(
    evm: &E,
    cfg: &LevKeeperConfig,
    dwell: &mut DwellTracker,
    now_secs: u64,
    dwell_secs: u64,
) -> anyhow::Result<()> {
    let lps = evm.open_positions().await?;

    // Pass 1 — classify (fault-tolerant): a failing view skips only that LP this tick.
    let mut urgent: Vec<LpAddr> = Vec::new();
    let mut protect: Vec<(LpAddr, u64)> = Vec::new(); // QUID-protect (collateral-preserving), before urgents
    let mut delever: Vec<LpAddr> = Vec::new();
    let mut relever: Vec<LpAddr> = Vec::new();
    let mut wbtc: Vec<LpAddr> = Vec::new(); // WBTC-mode: one atomic rebalanceWbtc handles either direction
    for lp in lps {
        let mut v = match timeout(LEG_TIMEOUT, evm.position_view(lp)).await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => {
                tracing::warn!(?lp, error = %e, "btc position_view failed; skipping this LP this tick");
                continue;
            }
            Err(_) => {
                tracing::warn!(?lp, timeout_s = LEG_TIMEOUT.as_secs(), "btc position_view timed out; skipping this LP this tick");
                continue;
            }
        };
        v.move_persisted = dwell.persisted(lp, out_of_band(&v, cfg), now_secs, dwell_secs);
        let action = decide(&v, cfg);
        // WBTC-fallback collateral (real WBTC on Aave/Morpho/Euler) rebalances via ONE atomic on-chain call
        // that handles BOTH directions itself — no acquirer, no async withdraw→sell / borrow→mint→supply legs.
        // QUID-protect stays mode-agnostic (redeem→repay preserves collateral regardless of venue); Hold no-ops.
        if v.wbtc_mode {
            match action {
                KeeperAction::ProtectFromQuid { repay_usd } => protect.push((lp, repay_usd)),
                KeeperAction::Hold => {}
                _ => wbtc.push(lp), // DeLever (urgent or lazy) OR ReLever ⇒ rebalanceWbtc decides direction on-chain
            }
            continue;
        }
        match action {
            KeeperAction::ProtectFromQuid { repay_usd } => protect.push((lp, repay_usd)),
            KeeperAction::DeLever { urgent: true, .. } => urgent.push(lp),
            KeeperAction::DeLever { urgent: false, .. } => delever.push(lp),
            KeeperAction::ReLever { .. } => relever.push(lp),
            KeeperAction::Hold => {}
        }
    }

    // QUID-protect first — repay from the LP's mature QUID before selling any vBTC collateral.
    for (lp, repay) in &protect {
        match timeout(LEG_TIMEOUT, evm.protect_from_quid(*lp, *repay)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(?lp, error = %e, "btc protect_from_quid failed; will de-lever/backstop next tick"),
            Err(_) => tracing::warn!(?lp, timeout_s = LEG_TIMEOUT.as_secs(), "btc protect_from_quid timed out; moving on"),
        }
    }
    // WBTC-mode positions: ONE atomic `rebalanceWbtc` each — flash-repay-first de-lever (always health-safe,
    // so no urgent/lazy split is needed) OR fold-up, decided on-chain from `debtDeltaToTarget`. minStableOut=0
    // (the contract floors it against the oracle). No acquirer, no async legs, so a hung external rail can't
    // stall it. Permissionless ⇒ the fleet signer just triggers it. Runs before the native legs so a near-liq
    // WBTC position de-levers promptly.
    for lp in &wbtc {
        match timeout(LEG_TIMEOUT, evm.rebalance_wbtc(*lp)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(?lp, error = %e, "WBTC-mode rebalance failed; retries next tick"),
            Err(_) => tracing::warn!(?lp, timeout_s = LEG_TIMEOUT.as_secs(), "WBTC-mode rebalance timed out; continuing"),
        }
    }
    // Pass 2 — URGENT de-levers first, unconditionally (the no-liquidation guarantee can't wait).
    for lp in &urgent {
        match timeout(LEG_TIMEOUT, do_delever(evm, *lp, true)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(?lp, error = %e,
                "URGENT btc de-lever could not be sourced; position falls to the venue's ISOLATED liquidation"),
            Err(_) => tracing::error!(?lp, timeout_s = LEG_TIMEOUT.as_secs(),
                "URGENT btc de-lever TIMED OUT; moving on so a hung RPC can't stall the rest of the safety pass"),
        }
    }
    // Then the lazy (persisted) IL-target de-levers.
    for lp in &delever {
        match timeout(LEG_TIMEOUT, do_delever(evm, *lp, false)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(?lp, error = %e, "btc de-lever failed; continuing"),
            Err(_) => tracing::warn!(?lp, timeout_s = LEG_TIMEOUT.as_secs(), "btc de-lever timed out; continuing"),
        }
    }
    // Then the re-levers (buffer rebuild).
    for lp in &relever {
        match timeout(LEG_TIMEOUT, do_relever(evm, *lp)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!(?lp, error = %e, "btc re-lever failed; continuing"),
            Err(_) => tracing::warn!(?lp, timeout_s = LEG_TIMEOUT.as_secs(), "btc re-lever timed out; continuing"),
        }
    }
    Ok(())
}

/// NATIVE de-lever — needs the async BTC↔stable rail (#59/#74), which is NOT wired (WBTC-mode positions never
/// reach here; they de-lever atomically via `rebalance_wbtc`). So this is the INLINED fail-safe: a native
/// position can't be sourced, so it's a LOUD no-op (leave full collateral on the venue) and lets a near-liq
/// position fall to the venue's ISOLATED liquidation — the same outcome the removed acquirer stub produced,
/// without the indirection. `debt_delta` is still read so the log distinguishes "at target" from "unsourceable".
async fn do_delever<E: BtcLevKeeperEvm>(evm: &E, lp: LpAddr, urgent: bool) -> anyhow::Result<()> {
    let (lev_up, amount_usd) = evm.debt_delta(lp).await?;
    if lev_up || amount_usd == 0 {
        return Ok(()); // at/under target — nothing to de-lever
    }
    if urgent {
        tracing::error!(?lp, "URGENT native btc de-lever needs the #59/#74 async rail (unwired); \
            position falls to the venue's ISOLATED liquidation");
    } else {
        tracing::warn!(?lp, "native btc de-lever needs the #59/#74 async rail (unwired); skipping this tick");
    }
    Ok(())
}

/// NATIVE re-lever — same unwired-rail fail-safe as do_delever: a loud no-op (never over-borrow ahead of a
/// BTC source that doesn't exist). WBTC-mode re-levers on-chain via `rebalance_wbtc`.
async fn do_relever<E: BtcLevKeeperEvm>(evm: &E, lp: LpAddr) -> anyhow::Result<()> {
    let (lev_up, amount_usd) = evm.debt_delta(lp).await?;
    if !lev_up || amount_usd == 0 {
        return Ok(());
    }
    tracing::warn!(?lp, "native btc re-lever needs the #59/#74 async rail (unwired); skipping this tick");
    Ok(())
}

// #9/#89: out_of_band DEDUP'd → now imported from lev_keeper (the ONE shared predicate). Local copy removed.

/// The BTC keeper task — one `set.spawn(run_btc_lev_keeper(...))` in the quid-bridge `JoinSet`, parallel to
/// the ETH keeper. Polls every `poll_interval_secs`; a failed tick is logged, never fatal (idempotent toward
/// target). `dwell_secs` is the lazy window for the IL-target track (the urgent safety leg ignores it).
pub async fn run_btc_lev_keeper<E: BtcLevKeeperEvm>(
    evm: E,
    cfg: LevKeeperConfig,
    dwell_secs: u64,
) -> anyhow::Result<()> {
    let mut dwell = DwellTracker::default();
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(cfg.poll_interval_secs.max(1))).await;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Err(e) = btc_tick(&evm, &cfg, &mut dwell, now, dwell_secs).await {
            tracing::warn!(error = %e, "btc_lev_keeper tick failed; retrying next interval");
        }
    }
}

// ════════════════════════════ concrete EVM binding (the live BTC keeper arm) ════════════════════════════
use crate::abi::word_to_uint;
use crate::client::{JsonRpcEvmClient, TxSigner};
use crate::transport::JsonRpc;
use alloy_primitives::{Address, U256};
use std::sync::Arc;

// `addr_word`, `u64_word`, `selector4`, `word_to_lpaddr` are shared with the ETH-lev
// keeper — imported from `crate::abi` above. `u128_word` is BTC-lev-only.
fn u128_word(n: u128) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[16..].copy_from_slice(&n.to_be_bytes());
    w
}

/// Concrete [`BtcLevKeeperEvm`] over the daemon's signing EVM client: reads `BtcLevManager` views via
/// `eth_read`, writes the async legs via `send_tx`. The client is blocking JSON-RPC, so each call is wrapped
/// in `spawn_blocking` (a 5-min poll makes that cost irrelevant). Runtime-provable only against a deployed
/// chain; the calldata encoding is unit-tested below.
pub struct DaemonBtcLevKeeper<R: JsonRpc, S: TxSigner> {
    pub evm: Arc<JsonRpcEvmClient<R, S>>,
    pub btc_lev_manager: Address,
    /// `Vault.syncLev` target (the merged Vault == the vBTC token == the sync hook).
    pub vault: Address,
    /// The vBTC market's liquidation LTV (bps) — a deployment constant; the safety margin comes off it. The
    /// per-LP `pos(lp).venue.liqThresholdBps()` live read overrides it when available.
    pub venue_liq_ltv_bps: u32,
    /// The WBTC underlying address. When a position's `pos(lp).venue.COLLATERAL()` equals this, the position is
    /// WBTC-mode and rebalances via the atomic on-chain `rebalanceWbtc` (vs the native channel-vBTC async legs).
    pub wbtc: Address,
    pub gas_limit: u64,
}

impl<R: JsonRpc + Send + Sync + 'static, S: TxSigner> BtcLevKeeperEvm for DaemonBtcLevKeeper<R, S> {
    async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>> {
        let (evm, bm) = (self.evm.clone(), self.btc_lev_manager);
        tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<LpAddr>> {
            let n: u64 = word_to_uint(&evm.eth_read(bm, "openLevCount()", None)?, "openLevCount")?;
            let mut out = Vec::with_capacity(n as usize);
            for i in 0..n {
                out.push(word_to_lpaddr(&evm.eth_read(bm, "openLpAt(uint256)", Some(&u64_word(i)))?)?);
            }
            Ok(out)
        })
        .await?
    }

    async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView> {
        let (evm, bm, vliq_cfg, wbtc) =
            (self.evm.clone(), self.btc_lev_manager, self.venue_liq_ltv_bps, self.wbtc);
        tokio::task::spawn_blocking(move || -> anyhow::Result<PositionView> {
            let a = addr_word(lp);
            let cur: u32 = word_to_uint(&evm.eth_read(bm, "getCurrentLtvBps(address)", Some(&a))?, "getCurrentLtvBps")?;
            let tgt: u32 = word_to_uint(&evm.eth_read(bm, "ilTargetLtvBps(address)", Some(&a))?, "ilTargetLtvBps")?;
            // netEquityBtc is 8-dec sats; value it in 6-dec USD for the economic floor via the live px.
            let ne_raw = evm.eth_read(bm, "netEquity(address)", Some(&a))?;
            let ne_word = ne_raw.get(..32).ok_or_else(|| anyhow::anyhow!("netEquityBtc short return"))?;
            let ne_sats = U256::from_be_slice(ne_word);
            let px_raw = evm.eth_read(bm, "vBtcValueUsd(uint256)", Some(&u64_word(100_000_000)))?; // USD18 per BTC
            let px_word = px_raw.get(..32).ok_or_else(|| anyhow::anyhow!("vBtcValueUsd short return"))?;
            let px = U256::from_be_slice(px_word);
            // net-equity USD(1e18) = sats · px / 1e8  →  6-dec USD.
            let ne_usd6: u64 = (ne_sats.saturating_mul(px) / U256::from(100_000_000u64)
                / U256::from(1_000_000_000_000u64))
            .try_into()
            .unwrap_or(u64::MAX);
            // One resolve of `pos(lp).venue` → its liq threshold AND its COLLATERAL() (WBTC-mode detection).
            let (vliq, wbtc_mode): (u32, bool) = (|| -> Option<(u32, bool)> {
                let pw = evm.eth_read(bm, "pos(address)", Some(&a)).ok()?;
                let venue = Address::from_slice(pw.get(12..32)?);
                let b = evm.eth_read(venue, "liqThresholdBps()", None).ok()?;
                let vliq = word_to_uint::<u32>(&b, "liqThresholdBps").ok()?;
                // COLLATERAL() == WBTC ⇒ this position rebalances via the atomic on-chain rebalanceWbtc route.
                let cw = evm.eth_read(venue, "COLLATERAL()", None).ok()?;
                let coll = Address::from_slice(cw.get(12..32)?);
                Some((vliq, coll == wbtc))
            })()
            .unwrap_or((vliq_cfg, false)); // read failure ⇒ treat as native (fail-safe to the proven vBTC legs)
            let il_ltv: u32 = word_to_uint(&evm.eth_read(bm, "ilLtvBps(address)", Some(&a))?, "ilLtvBps")?;
            Ok(PositionView {
                current_ltv_bps: cur,
                il_ltv_bps: il_ltv, // debt/E0 (BtcLevManager.ilLtvBps) — IL-track basis, distinct from cur (venue safety)

                target_ltv_bps: tgt,
                venue_liq_ltv_bps: vliq,
                collateral_usd: ne_usd6,
                deliverable_floor_ok: true, // contract clamps the supply leg; safe to attempt
                move_persisted: false,       // set by the loop's DwellTracker
                mature_quid_usd: 0,          // 0 until the mature-QUID read is wired (fails SAFE to de-lever)
                wbtc_mode,                   // COLLATERAL()==WBTC ⇒ route to the atomic rebalanceWbtc leg
            })
        })
        .await?
    }

    async fn debt_delta(&self, lp: LpAddr) -> anyhow::Result<(bool, u128)> {
        let (evm, bm) = (self.evm.clone(), self.btc_lev_manager);
        tokio::task::spawn_blocking(move || -> anyhow::Result<(bool, u128)> {
            let r = evm.eth_read(bm, "debtDeltaToTarget(address)", Some(&addr_word(lp)))?;
            let up_word = r.get(..32).ok_or_else(|| anyhow::anyhow!("debtDelta short return (levUp)"))?;
            let amt_word = r.get(32..64).ok_or_else(|| anyhow::anyhow!("debtDelta short return (amount)"))?;
            let lev_up = U256::from_be_slice(up_word) != U256::ZERO;
            let amount: u128 = U256::from_be_slice(amt_word).try_into().unwrap_or(u128::MAX);
            Ok((lev_up, amount))
        })
        .await?
    }

    async fn price_usd_per_btc(&self, _lp: LpAddr) -> anyhow::Result<u128> {
        let (evm, bm) = (self.evm.clone(), self.btc_lev_manager);
        tokio::task::spawn_blocking(move || -> anyhow::Result<u128> {
            let r = evm.eth_read(bm, "vBtcValueUsd(uint256)", Some(&u64_word(100_000_000)))?;
            let w = r.get(..32).ok_or_else(|| anyhow::anyhow!("vBtcValueUsd short return"))?;
            Ok(U256::from_be_slice(w).try_into().unwrap_or(u128::MAX))
        })
        .await?
    }

    async fn lever_borrow(&self, lp: LpAddr, stable_usd: u128) -> anyhow::Result<()> {
        self.send_leg(lp, "leverBorrow(uint256)", Some(u128_word(stable_usd))).await
    }
    async fn lever_supply(&self, lp: LpAddr, vbtc_sats: u64) -> anyhow::Result<()> {
        self.send_leg(lp, "leverSupply(uint256)", Some(u64_word(vbtc_sats))).await
    }
    async fn delever_withdraw(&self, lp: LpAddr, vbtc_sats: u64) -> anyhow::Result<()> {
        self.send_leg(lp, "deleverWithdraw(uint256)", Some(u64_word(vbtc_sats))).await
    }
    async fn repay(&self, lp: LpAddr, stable_usd: u128) -> anyhow::Result<()> {
        self.send_leg(lp, "repay(uint256)", Some(u128_word(stable_usd))).await
    }

    async fn sync_lev_btc(&self, lp: LpAddr) -> anyhow::Result<()> {
        let (evm, vault, gas) = (self.evm.clone(), self.vault, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut data = selector4("syncLev(address)");
            data.extend_from_slice(&addr_word(lp));
            evm.send_tx(vault, data, gas)?;
            Ok(())
        })
        .await?
    }

    async fn protect_from_quid(&self, lp: LpAddr, _repay_usd: u64) -> anyhow::Result<()> {
        // DELEGATED (autonomous layer) — the BTC counterpart of the ETH path, now live. ONE constrained on-chain
        // call `BtcLevManager.protectFromQuid(lp, minOut)` redeems the LP's OWN opted-in QUID PRO-RATA, consolidates
        // the mix into the venue's OWN loan token (basket SOR → UniV3 fallback), repays the LP's OWN BTC-lev debt,
        // and refunds any excess to the LP — all via the SAME asset-agnostic `LevMath.protectExec` the ETH side uses,
        // so funds can NEVER reach the operator (by construction). The near-liq gate AND the amount (debt-derived,
        // bounded by the LP's one-time QUID allowance = the opt-in) live ON-CHAIN, so the fleet signer merely
        // triggers it: no per-action quorum, no cap. A revert is fail-safe ⇒ this tick falls back to de-lever.
        // `minStableOut = 0`: the keeper picks WHEN, not the price; consolidation rides deep stable tiers ⇒ low MEV.
        let (evm, bm, gas) = (self.evm.clone(), self.btc_lev_manager, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut d = selector4("protectFromQuid(address,uint256)");
            d.extend_from_slice(&addr_word(lp));
            d.extend_from_slice(&[0u8; 32]);   // minStableOut = 0
            evm.send_tx(bm, d, gas)?;
            Ok(())
        })
        .await?
    }

    async fn rebalance_wbtc(&self, lp: LpAddr) -> anyhow::Result<()> {
        // ONE atomic on-chain call: `rebalanceWbtc(lp, minStableOut=0)`. Permissionless (any fleet signer),
        // and the contract enforces the anti-MEV oracle floor internally, so `minStableOut=0` is safe — the
        // keeper decides only WHEN. Direction (fold-up vs flash-repay-first de-lever) is chosen on-chain from
        // `debtDeltaToTarget`; a revert is fail-safe (retried next tick).
        let (evm, bm, gas) = (self.evm.clone(), self.btc_lev_manager, self.gas_limit);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut d = selector4("rebalanceWbtc(address,uint256)");
            d.extend_from_slice(&addr_word(lp));
            d.extend_from_slice(&[0u8; 32]);   // minStableOut = 0 (contract floors against the oracle)
            evm.send_tx(bm, d, gas)?;
            Ok(())
        })
        .await?
    }
}

impl<R: JsonRpc + Send + Sync + 'static, S: TxSigner> DaemonBtcLevKeeper<R, S> {
    /// Send one `BtcLevManager` leg. The legs are LP-gated (`msg.sender == lp`), so the keeper's signer IS the
    /// LP key (the fleet self-host model). `arg` is the single uint256 param (already a 32-byte word).
    async fn send_leg(&self, _lp: LpAddr, sig: &str, arg: Option<[u8; 32]>) -> anyhow::Result<()> {
        let (evm, bm, gas, sig) = (self.evm.clone(), self.btc_lev_manager, self.gas_limit, sig.to_string());
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let mut data = selector4(&sig);
            if let Some(a) = arg {
                data.extend_from_slice(&a);
            }
            evm.send_tx(bm, data, gas)?;
            Ok(())
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // §E237-rust — `keccak256` import DROPPED: its only uses were the three self-referential
    // selector assertions, which are now pinned to literal bytes. Keeping it would be an unused
    // import, and the reason it is gone is the point — nothing here recomputes what it is testing.
    use std::cell::RefCell;

    fn base() -> PositionView {
        PositionView {
            current_ltv_bps: 3000,
            il_ltv_bps: 3000,
            target_ltv_bps: 3000,
            venue_liq_ltv_bps: 8000,
            collateral_usd: 100_000_000_000, // $100k
            deliverable_floor_ok: true,
            move_persisted: true,
            mature_quid_usd: 0,
            wbtc_mode: false,
        }
    }

    #[test]
    fn usd_to_sats_scales_by_price() {
        // px = $60k/BTC (1e18) → $30k debt delta → 0.5 BTC = 50_000_000 sats.
        let px = 60_000u128 * 1_000_000_000_000_000_000u128;
        let usd = 30_000u128 * 1_000_000_000_000_000_000u128;
        assert_eq!(usd_to_vbtc_sats(usd, px), 50_000_000);
        // zero/absurd price → 0 (no sizing off a bad oracle read)
        assert_eq!(usd_to_vbtc_sats(usd, 0), 0);
    }

    #[test]
    fn calldata_selectors_and_words() {
        // §E237-rust — THESE THREE USED TO ASSERT `selector4(s) == keccak256(s)[..4]` FOR THE SAME
        // `s`, WHICH IS A TEST OF `selector4` AND OF NOTHING ELSE. It passes for ANY string,
        // including a selector no contract declares — which is exactly what happened: it went on
        // passing while `syncLevBTC` was renamed out of existence on-chain, so the one test named
        // after calldata correctness could not observe the calldata becoming unroutable.
        //   Pinned to LITERAL BYTES instead. Now the assertion is about the CHAIN's identity for
        // these functions, so a rename on either side fails here — which is the property the test
        // was named for. Values from `cast sig`.
        assert_eq!(selector4("syncLev(address)"),        vec![0x94, 0x57, 0xdc, 0xbf]);
        assert_eq!(selector4("leverBorrow(uint256)"),    vec![0xdc, 0x2e, 0xcd, 0x34]);
        assert_eq!(selector4("deleverWithdraw(uint256)"), vec![0x8b, 0x22, 0x46, 0x17]);
        // ⚠️ NO ASSERTION HERE ABOUT THE RETIRED BTC-SUFFIXED NAME. I wrote one and deleted it:
        // pinning `selector4` of a literal string to its own keccak can never fail, so it would
        // have been the same empty gesture this comment is about. Whether a name still EXISTS
        // on-chain is not knowable from this crate — that is `check-client-abis.py`'s job, and it
        // is the tool that caught this defect.
        //   ⚠️ AND THE RETIRED SIGNATURE IS DELIBERATELY NOT WRITTEN AS A DOUBLE-QUOTED STRING
        // ANYWHERE. MEASURED, not assumed: the checker matches Rust STRING LITERALS, and it does so
        // wherever they appear — INCLUDING INSIDE A COMMENT. My first version of this note quoted
        // `selector4("<the dead name>")` verbatim and the gate reported it as live drift at this
        // line; the backtick-quoted mentions above and in `evm_validating_signer.rs` do NOT trip
        // it. That is the right sensitivity, not a false positive to suppress: a commented-out call
        // is still a call someone will uncomment. ⇒ Describe retired selectors in backticks; never
        // in double quotes, not even in a comment explaining that they are dead.
        // uint128/uint64 words are right-aligned in the 32-byte slot
        assert_eq!(u64_word(50_000_000)[24..], 50_000_000u64.to_be_bytes());
        assert_eq!(u128_word(30_000)[16..], 30_000u128.to_be_bytes());
        let lp: LpAddr = [0x22; 20];
        assert_eq!(&addr_word(lp)[..12], &[0u8; 12]);
        assert_eq!(&addr_word(lp)[12..], &lp[..]);
    }

    /// Records the exact leg sequence so the tick's ordering (withdraw→sell→repay / borrow→mint→supply) is
    /// asserted (WBTC-mode atomic rebalance + the dwell gating).
    #[derive(Default)]
    struct Rec {
        borrowed: RefCell<Vec<(LpAddr, u128)>>,
        supplied: RefCell<Vec<(LpAddr, u64)>>,
        withdrawn: RefCell<Vec<(LpAddr, u64)>>,
        repaid: RefCell<Vec<(LpAddr, u128)>>,
        synced: RefCell<Vec<LpAddr>>,
        rebalanced: RefCell<Vec<LpAddr>>, // WBTC-mode atomic rebalanceWbtc calls
        order: RefCell<Vec<&'static str>>,
    }
    struct MockEvm {
        views: Vec<(LpAddr, PositionView)>,
        delta: (bool, u128),
        px: u128,
        rec: Rec,
    }
    impl BtcLevKeeperEvm for MockEvm {
        async fn open_positions(&self) -> anyhow::Result<Vec<LpAddr>> {
            Ok(self.views.iter().map(|(a, _)| *a).collect())
        }
        async fn position_view(&self, lp: LpAddr) -> anyhow::Result<PositionView> {
            Ok(self.views.iter().find(|(a, _)| *a == lp).unwrap().1)
        }
        async fn debt_delta(&self, _lp: LpAddr) -> anyhow::Result<(bool, u128)> {
            Ok(self.delta)
        }
        async fn price_usd_per_btc(&self, _lp: LpAddr) -> anyhow::Result<u128> {
            Ok(self.px)
        }
        async fn lever_borrow(&self, lp: LpAddr, u: u128) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("borrow");
            self.rec.borrowed.borrow_mut().push((lp, u));
            Ok(())
        }
        async fn lever_supply(&self, lp: LpAddr, v: u64) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("supply");
            self.rec.supplied.borrow_mut().push((lp, v));
            Ok(())
        }
        async fn delever_withdraw(&self, lp: LpAddr, v: u64) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("withdraw");
            self.rec.withdrawn.borrow_mut().push((lp, v));
            Ok(())
        }
        async fn repay(&self, lp: LpAddr, u: u128) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("repay");
            self.rec.repaid.borrow_mut().push((lp, u));
            Ok(())
        }
        async fn sync_lev_btc(&self, lp: LpAddr) -> anyhow::Result<()> {
            self.rec.synced.borrow_mut().push(lp);
            Ok(())
        }
        async fn protect_from_quid(&self, _lp: LpAddr, _repay_usd: u64) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("protect");
            Ok(())
        }
        async fn rebalance_wbtc(&self, lp: LpAddr) -> anyhow::Result<()> {
            self.rec.order.borrow_mut().push("rebalanceWbtc");
            self.rec.rebalanced.borrow_mut().push(lp);
            Ok(())
        }
    }


    #[tokio::test]
    async fn wbtc_mode_routes_to_atomic_rebalance_not_async_legs() {
        // A WBTC-mode position that's out of band must go through ONE `rebalanceWbtc` — never the
        // withdraw→sell→repay (or borrow→mint→supply) sequence.
        let lp = [7u8; 20];
        let mut v = base();
        v.wbtc_mode = true;
        v.current_ltv_bps = 7000; // out of band (would be an urgent de-lever in native mode)
        let px = 60_000u128 * 1_000_000_000_000_000_000u128;
        let usd = 30_000u128 * 1_000_000_000_000_000_000u128;
        let evm = MockEvm { views: vec![(lp, v)], delta: (false, usd), px, rec: Rec::default() };
        let mut dwell = DwellTracker::default();
        btc_tick(&evm, &LevKeeperConfig::default(), &mut dwell, 0, 600).await.unwrap();
        assert_eq!(*evm.rec.rebalanced.borrow(), vec![lp], "one atomic rebalanceWbtc");
        assert_eq!(*evm.rec.order.borrow(), vec!["rebalanceWbtc"], "no async legs");
        assert!(evm.rec.withdrawn.borrow().is_empty(), "no vBTC withdraw in WBTC mode");
        assert!(evm.rec.repaid.borrow().is_empty(), "no separate repay in WBTC mode");
    }


    #[tokio::test]
    async fn lazy_delever_waits_for_dwell() {
        let lp = [3u8; 20];
        let mut v = base();
        v.wbtc_mode = true; // WBTC-mode: the dwell gates the atomic rebalance (native de-lever is a no-op now)
        v.il_ltv_bps = 4000; // above band but mean-reverting (not near venue-liq)
        let px = 60_000u128 * 1_000_000_000_000_000_000u128;
        let usd = 10_000u128 * 1_000_000_000_000_000_000u128;
        let evm = MockEvm { views: vec![(lp, v)], delta: (false, usd), px, rec: Rec::default() };
        let mut dwell = DwellTracker::default();
        // t=0: just went out of band ⇒ NOT persisted ⇒ no rebalance (anti-churn).
        btc_tick(&evm, &LevKeeperConfig::default(), &mut dwell, 0, 600).await.unwrap();
        assert!(evm.rec.rebalanced.borrow().is_empty(), "un-persisted move must not rebalance");
        // t=700 (> 600 dwell), still out of band ⇒ persisted ⇒ the lazy rebalance fires.
        btc_tick(&evm, &LevKeeperConfig::default(), &mut dwell, 700, 600).await.unwrap();
        assert!(!evm.rec.rebalanced.borrow().is_empty(), "persisted move must rebalance");
    }
}
