> ⚠️ STATUS (2026-06-30, amended 2026-07-11): STILL-RELEVANT as a risk catalog (oracle/collateral-mark, keeper liveness, redemption non-atomicity, etc. all still apply to the leverage build), but PARTIALLY assumes the OVERRULED design: items framed around L=2 IL-cancellation, internal-CDP/band-overlay, and vETH collateral are stale — the canonical IL-protect is opt-in per-LP weETH/WETH collateral on external Euler/Morpho/Aave/Liquity, **bidirectional** (long above + short below entry, both delta-1), sized long = the band's MEASURED sold fraction (`1−1/√(entry/now)` is the fallback), short = `√(entry/now)−1`. **UPDATE (2026-07-11): the engine is now BUILT + live** — these risk items now map to shipped code (`LevManager`/`LevMath`, `ILevVenue` adapters, per-LP isolation, `quid-bridge/src/lev_keeper.rs`), so read each as "held against the live build," not a pre-build checklist. Also live: auto-protect (`protectFromQuid`, ETH+BTC), the BOLD depth-independent close, and the `√p`-collateral/vETH-market-unbuildable constraint is moot (collateral is weETH/WETH/WBTC, SOR-swapped). Canonical: docs/actionable/LEVERAGE-ENGINE-SPEC.md.

# Leverage risk surface — the checklist the YB/leverage build is held against

**Why this exists.** "YB is defensible because of three specifics (validated-band, locked-QUID, self-funded-vETH)"
was an **overfit reduction** — a 3-variable summary of a multi-dimensional safety question, and only one of the
three survives calculus. This doc replaces that story: the build is held against the **full surface** below, and
**no item is "done" until it has a wired mitigation AND a passing probe.** Don't let the three specifics stand in.

## What the calculus actually says about the "three specifics"
| claim | verdict | why |
|---|---|---|
| **#1 IL-cancellation** | **DEFINITIVE (calculus)** | `V*∝p^(L/2)`; `d²V*/dp²=0` **iff L=2** → the convexity (IL) term is *annihilated*, not reduced. Robust to any sim. *Caveat:* frictionless ideal; real value = `p·e^(−δt)`, δ = discrete-rebalance + slippage drag (the sim's −4%). |
| **#2 no-liquidation** | **NOT a guarantee — a tail bound** | preempted for gaps ≤ `g_max ≈ (LLTV−target) + buffer/position`; crypto returns are power-law `P(gap>g)~g^(−α) > 0`. "Possible" is the wrong word; it's `P(liq) ≤ tail(g_max)`. |
| **#3 self-funded carry** | **NOT a constant — a regime inequality** | `borrow·(L−1) − venue_yield·L − SP_yield ≤ 0` holds in some rate regimes (low Morpho utilization, high staking/SP), not others. |

## Hard build constraint (market reality, user 2026-06-28)
Use **markets that exist with liquidity**. There is **no vETH lending market** (permissionless ≠ liquid), so the
"vETH-collateral + external BOLD + SP" design is **unbuildable**. Realistic substrates only:
- **Liquity zap** (weETH→BOLD→SP) — exists (`SorExchange` + `LeverageWETHZapper`). Directional leveraged-weETH product.
- **Internal CDP** (basket lends stable against vETH) — no external market needed. The IL-offset (band-overlay) product.
- **weETH on Aave/Morpho** (deep, E-mode) — directional leveraged-weETH.

---

## The surface — each item: RISK → MITIGATION → PROBE (build is held to all)

### 1. Oracle / collateral mark
- **Risk:** LTV = `debt / (vETH × convertToAssets × getTWAPforAsset)`. Manipulate the band TWAP or the 4626 ratio → mis-stated LTV → forced/blocked rebalance, or borrow against an inflated mark.
- **Mitigation:** price off the **1800s TWAP** (not spot) + the existing **3%/30min manip guard** + the **50bps/swap cap**; `convertToAssets` (= vogueETH/lpShares) is protocol-internal and not externally pumpable; cross-check vs Chainlink WETH/USD and reject if divergent beyond a band.
- **Probe:** forge test — pump the band spot within one block, assert `getCurrentLtvBps` and `rebalance` act on the **TWAP**, not the manipulated spot (no borrow/withdraw on the pumped mark).

### 2. Keeper liveness
- **Risk:** the no-liquidation story assumes the keeper rebalances within its interval. Gap-down + stalled keeper (gas spike, RPC, MEV on the rebalance tx) → liquidation despite the buffer.
- **Mitigation:** size the buffer for the worst gap over the **max keeper-outage window**, not one interval; make `rebalance` **permissionless** (searchers keep it live for the fee); set target LTV conservatively far from LLTV; redundant keepers.
- **Probe:** sim — gap-down × keeper-latency grid → does the buffer cover? Report the max tolerable gap as a function of (buffer, latency). On-chain: a test that `rebalance` works from an arbitrary caller.

### 3. vETH redemption non-atomicity
- **Risk:** the de-lever path redeems vETH→WETH, which `Vogue._withdraw` can **defer** (`:385-420`); the de-lever can't repay what it can't redeem in time — exactly when needed.
- **Mitigation:** hold the **buffer as stable** (BOLD-in-SP, or a stable reserve) so the *preemptive* de-lever repays from the buffer **without** needing a vETH redemption; only the slower full-unwind touches redemption, which the buffer has already covered the gap for.
- **Probe:** forge test — force `Vogue` redemption to defer, assert the SP/stable buffer still de-levers LTV below LLTV (repay path independent of vETH redemption).

### 4. BOLD depeg
- **Risk:** the SP buffer **is** BOLD — the one feed-less basket stable. A BOLD depeg silently shrinks the buffer's real value precisely when it's drawn on.
- **Mitigation:** apply a **depeg haircut** when sizing the BOLD buffer; monitor BOLD/USD via a DEX TWAP; cap BOLD-buffer reliance (diversify the buffer with locked-QUID as the non-BOLD layer).
- **Probe:** stress test — de-lever under a −X% BOLD depeg, assert the haircut-sized buffer still clears the debt; report the depeg the buffer survives.

### 5. Reflexivity (collateral = the thing being bought)
- **Risk:** levering **buys vETH → moves the band price → moves the collateral mark → moves LTV** — a self-referential loop on the same asset.
- **Mitigation:** LTV off the **lagging TWAP** (doesn't see the buy immediately) + the manip guard + 50bps/swap cap bound per-swap impact; the open loop is bounded (`MAX_LOOPS`); cap position size vs band depth (item 6).
- **Probe:** sim — a large open, measure the band-TWAP move + the induced LTV change; assert the feedback **converges** (damped), not spirals.

### 6. Liquidity depth
- **Risk:** the 2× buy moves price against the position; a thin band gives bad fills and a worse-than-modeled entry.
- **Mitigation:** cap `position / band-depth`; `minOut` on every leg; route via the SOR (best path).
- **Probe:** measure realized slippage of the open's buy legs vs band depth across sizes; set the position/depth cap from it.

### 7. MEV / slippage on swap legs
- **Risk:** the stable↔WETH legs (open, rebalance, close) sandwiched or front-run.
- **Mitigation:** **off-chain-quoted `minOut`** (keeper/LP supplies, never 0); private mempool for keeper txs; the internal-TWAP Core band has no external arb (though the SOR buy touches real Uniswap — bounded by `minOut`).
- **Probe:** test that `minOut` is enforced (revert on shortfall) on every leg; a sandwich-attempt test showing bounded loss.

### 8. Buffer tail-adequacy
- **Risk:** `g_max` (#2) is sized to a chosen gap; a fatter tail blows through and the venue liquidates anyway.
- **Mitigation:** size the buffer to **historical worst-gap × multiplier**; accept the venue's own liquidation as the final, **per-LP-isolated** backstop (the LP bears its own tail, no socialization).
- **Probe:** fat-tail sim of the gap distribution vs the buffer → report `P(liquidation)` and the expected loss given liquidation; confirm it's isolated.

### 9. Isolation (no cross-LP cascade)
- **Risk:** a shared-venue account pools LPs → one liquidation cascades into the pile.
- **Mitigation:** **per-LP isolated** venue positions (LP is the venue account) — Liquity Troves are per-LP; Morpho positions are per-account; `ILevVenue` carries the isolation.
- **Probe:** test — liquidate one LP's position, assert another LP's collateral/debt is **untouched**.

### 10. Contract + protocol risk
- **Risk:** new `LevManager`/adapters/SP-integration bugs; Morpho/Liquity dependency risk; reentrancy across the swap↔venue↔band legs.
- **Mitigation:** **reuse** the deployed zapper/`SorExchange` (don't rebuild leverage); `nonReentrant` on every entrypoint; minimal new surface; the §10-style adversarial lifecycle audit before sign-off.
- **Probe:** full forge coverage incl. reentrancy + adversarial open/rebalance/close/liquidate sequences; fork-test against real Morpho/Liquity.

---

## Standing verdict (replaces the "three specifics")
- **IL-cancellation is calculus-definitive** (item-independent, #1).
- **Everything else is a *managed surface*, not a guarantee.** YB is **IL-canceling and favorable-in-expectation**,
  *conditional on* a regime-dependent carry (#3), a tail-bounded buffer (#2/#8), and the 10 surfaces above being
  engineered down — each to a wired mitigation + a green probe. **No item ships on assertion.**
