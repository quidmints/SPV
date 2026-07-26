# Leverage collateral route — an adaptive borrow/hedge ROUTER (native ⇄ WBTC), condition-driven

Status: **WBTC mode BUILT; native mode + the adaptive router are still OPEN.** The BTC leverage engine's
collateral/borrow route. **Not a fixed choice — a router that picks per live conditions** between a *native* mode
(no bleed) and a *WBTC* mode (healthy workhorse + never-stuck floor). Nothing is removed; nothing is rigid. The
native delivery of a levered LP's *equity* is always the well (`BTC-MARKET-MAKING-SPEC.md`).

> **BUILT (do NOT re-spec):** WBTC mode is live — `BtcLevManager.rebalanceWbtc` (atomic fold-up /
> flash-repay-first de-lever on a real Morpho {USDC,WBTC} market), keeper-driven (`lev_keeper_btc.rs`, #90),
> fork-proven (`VBtcLevFeeLane.t.sol`). The native vBTC same-BTC overlay (`vogueBTC`/`syncLevBTC`/`levPooledBTC`,
> `vbtcExpose/Unexpose`) and venue pin-once are also built. **STILL OPEN:** the native-mode *borrow/hedge*
> sourcing legs (keeper `UnwiredNativeAcquirer` is a fail-safe stub = #59/#74), the **adaptive router** that
> picks native-vs-WBTC per live depth (today mode is fixed per-position by `venue.COLLATERAL()`), and the
> **bounded basket-seed** of the vBTC market. These are the remaining design/build work below.

> Guidance that pinned this: never mint vBTC against WBTC; swappers' capital efficiency first; **keep the vBTC/USDC
> market (it may populate); decide internalise-vs-market by conditions; UNbounded internalise is unhealthy
> (procyclical) — bounded/capped seed is fine.**

## The hard constraint (why a router, not a winner)
A leverage borrow needs a lender who bears the credit risk. **Healthy = an external market bears it.** BTC has two:
the deep **WBTC/USDC** market (always liquid) and the bespoke **vBTC/USDC** market (thin today, *may populate*).
Native collateral avoids the WBTC round-trip bleed but its only borrow venues are the thin vBTC market or the
basket. **Unbounded basket funding is procyclical (QD backing eats the leverage's gap-down tail — #67 only covers
*orderly* de-lever, not a gap).** So no single source wins in all conditions ⇒ **route adaptively.**

## The two modes
### Native mode — no bleed (used when depth allows)
Collateral **vBTC**; borrow **through the vBTC/USDC Morpho/Euler market** (kept — this interaction is *how external
lenders onboard*); hedge drawn **native from the well** (nets with swaps, #54). The market's USDC supply:
- **External lenders** — preferred; they bear the credit risk (healthy). Populate the market over time.
- **Bounded basket-seed** — the *safe* form of "internalise": the basket seeds the vBTC market **hard-capped at a
  small % of backing, high-collateral-only, low-vol-gated**, and its share **auto-shrinks as external fills in**.
  The cap is what makes it healthy — a gap-down dents only the seeded slice, never the whole backing. (This is NOT
  the rejected unbounded basket loan.)

Cost of native mode: it **draws the well's scarce native BTC at grow-time** (competes with swap-outs, priced by
skew) and carries the (capped) seed exposure. Chosen only when the vBTC market has real depth AND the well is flush.

### WBTC mode — healthy workhorse + never-stuck floor
Collateral/borrow/hedge all **WBTC**, deep external markets (Aave/Morpho/Euler + Uniswap SOR), byte-for-byte the
ETH `LevManager`. **Zero QD-backing exposure, does NOT compete for the well's native BTC** during the position;
touches the well only when the LP takes *profit* as native at exit (an ordinary swap-out, fair skew). Cost: a small
WBTC-close Uniswap slippage (the "bleed"). **Always available ⇒ no DoS.** The reliable default.

## The router (adaptive, per position × conditions)
1. vBTC market has **real external depth** + well **flush** → **native mode** (no bleed, no basket risk). Best.
2. vBTC thin but **safe-to-seed** (cap headroom + low vol + high collateral) → native mode with **capped
   basket-seed** (avoids the bleed at tiny bounded backing risk).
3. otherwise → **WBTC mode** (healthy, small bleed, zero backing risk). Default + never-stuck floor.
Reads live: vBTC-market depth, well native depth, volatility/gap-risk, backing-seed headroom. No hardcoded winner.

## Never-stuck (LOAD-BEARING)
- **WBTC mode is always reachable** (deep external) ⇒ a native-mode position that can't roll falls to WBTC (or a
  **WBTC short via SOR** to neutralize), the native leg parks; unwind when depth returns.
- **Ultimate backstop = slow on-chain unwind** (force-close channel → real BTC → sell anywhere → repay).
- **Invariant: thin-market / well absence costs YIELD EFFICIENCY (or the small WBTC bleed), never principal or
  solvency, and NEVER the QD backing beyond the capped seed.**

## Delivery vs borrow (the distinction that stops the oscillation)
- **Equity + delta-1 delivery → native BTC via the well.** Always. The "prefer native" is honored *here* — Phase 0
  gives it regardless of borrow mode.
- **The 2× borrow → the router** (native vBTC-market / WBTC-market). Different question, different answer.
Conflating them caused the flip-flops; separated, both are stable.

## Invariants / rules
- **Never mint vBTC against WBTC** — vBTC is the native equity/collateral (native mode); WBTC is WBTC mode; distinct.
- **Bounded** basket-seed only (capped % backing, gated) — never the unbounded procyclical loan.
- Fold `BtcLevManager` into the ETH `LevManager` shape (one lev lib, two token configs; `LevMath.runShort`
  already extracts the leg mechanics). WBTC mode IS that shape; native mode adds the vBTC-market + well-draw legs.

## Collateral ranking
- **BTC:** native **vBTC** (no bleed, native mode — when vBTC-market + well have depth) ⇄ **WBTC** (deep, healthy,
  workhorse/floor) ⇄ **tBTC/cbBTC** (decentralized-custody WBTC-alternative, thinner). Router picks.
- **ETH:** **weETH** (yield while pledged) / **WETH** — ETH has no native-channel analog, so ETH is WBTC-mode-equivalent
  throughout; the native mode is BTC-specific.

## Remaining build order (WBTC mode done)
The well (Phase 0, `BTC-MARKET-MAKING-SPEC.md`) → **native-mode sourcing legs** (real acquirer replacing the
`UnwiredNativeAcquirer` stub, #59/#74) → **adaptive router** (live depth/vol/seed-headroom reads → mode choice)
→ **bounded basket-seed** of the vBTC/USDC market (capped % backing, high-collateral-only, low-vol-gated,
auto-shrinks as external supply fills in).

## References
- `BTC-MARKET-MAKING-SPEC.md` (well + shared exchange), `old/evm/src/Solver.sol` (Bebop JAM RFQ),
  `LEVERAGE-BTC-M11-SPEC.md`, `LEVERAGE-ENGINE-SPEC.md`, `LEVERED-DELIVERABILITY-SPEC.md` (#67 de-lever safety).
- Memory: [[project-quid-btc-market-structure]], [[project-quid-btclev-deploy-keeper]],
  [[project-quid-yb-bidirectional-design]], [[reference-quid-procyclical-intermediary-caution]],
  [[project-quid-levered-deliverability]].
