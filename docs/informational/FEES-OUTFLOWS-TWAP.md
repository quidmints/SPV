# Stable outflow fee — the Aux basket fee, the yield "TWAP", and concentration

How QU!D fees a **stablecoin outflow** (a QUI redemption that drains stables out
of the dollar basket), and *why* that fee is computed by reusing two existing
primitives: the basket's **time-weighted yield machinery** (the yield analog of a
price TWAP) and the per-stable **concentration** (each stable's share of the
basket). This is the **Aux/basket fee** (`FeeLib.calcFeeL1` + `riskFactor`) — *not*
the 4.2-bps Vogue PoolKey/AMM fee, which is a separate plane.

> ⚠️ **RETRACTED (2026-08-01, verified against the contracts). The `baseRate` described in the
> 2026-06 update below was REMOVED.** There is no Liquity-style decaying directional redemption toll
> in the code: `_br`, `_touchBaseRate`, `BR_DECAY` and `BR_MAX_MIN` are gone from Aux
> (`Aux.sol:1019`, `:1058-59`) and from `FeeLib` (`imports/FeeLib.sol:59`), with the reason recorded
> at `Core.sol:168` (QU!D has no peg-arb loop, so the toll had nothing to price). `QuidLens.sol:22`
> still mentions it and is also stale. Anywhere below that says "+ baseRate", read it as absent.
>
> **What survives and is still accurate:** `BASE = 3` (0.03%) and `MAX_FEE = 30` (0.3%)
> (`FeeLib.sol:66-67`), the yield-vs-baseline drain tax (`calcFeeL1`), its convex draw-magnitude
> scaling (`scaledFeeL1`), and the depeg haircut as a SEPARATE uncapped axis. So the composite is now
> TWO terms, not three.
>
> **Also stale below:** §3b's "worse of the CRE-reported severity and a live feed" is now just the
> live pinned feed. The off-chain CRE was removed (`Aux.sol:140`, `:202`, `FeeLib.sol:219`), and the
> dark-CRE redemption gate at §4 step 1 went with it. And the per-stable arrays are `uint[15]` with
> the TOTAL at index 14; `deps[12]` below is the old indexing.
>
> ~~UPDATE (2026-06): directional `baseRate` added; bounds tightened to [0.03%, 0.3%]. The outflow
> fee now has a THIRD component beyond yield-weighted concentration: a Liquity-style decaying
> `baseRate` (Aux state, 12h half-life, incremented by `redeemed/(2·total)` per redemption) that
> rises with directional redemption flow and decays when it stops. Threaded into
> `calcNeeded`/`allocate` as `baseRateBps`, applied ONLY on the redemption path.~~

> **The analogy in one line.** The ETH/BTC AMM side prices and fills exits
> against a *price* TWAP and a *concentrated-liquidity* band. Pegged stables have
> no floating price to TWAP and no v4 band — so the stable side reuses the
> *same shapes* in its own register: a **time-weighted yield** (smooths blips like
> a TWAP) and the basket **concentration** (each stable's weight). The outflow fee
> is a function of both.

---

## 1. What the fee is (THREE terms)

A stable redemption pays the worse of nothing and three stacked terms, all in
`FeeLib`/Aux:

1. **Drain-tax — `calcFeeL1`** (`FeeLib.sol:69`). Taxes draining a stable whose
   yield-factor sits **above the basket's weighted-average** baseline, because
   pulling it out *lowers* the basket's average yield:

   ```
   baseline = deps[0] / deps[12]          // basket yield-weighted average
   mine     = yieldW[idx] / deps[idx]     // this stable's yield-factor
   feeBps   = mine > baseline ? (mine − baseline)·1e4   // then + baseRate, clamped
                              : BASE                      // BASE = 3 bps (0.03%)
   ```

   - **At/below average → `BASE` (3 bps, 0.03%).** Draining a low-yield stable
     heals or is neutral to basket yield, so it's cheap.
   - **A depegged stable is already yield-discounted upstream** (`get_deposits`
     drags `yieldW[idx]` down, §3), so `mine ≤ baseline` and it *also* lands at
     `BASE` — "cheap to shed bad collateral."

2. **Directional `baseRate` — Aux state (`_touchBaseRate`)**. A Liquity-style
   decaying rate (12h half-life, `+= redeemed/(2·total)` per redemption) added to
   the drain-tax `feeBps`, so the fee rises with sustained redemption flow and
   decays when it stops. Applied ONLY on the redemption path (`token==QUID`);
   swaps/swap-out-as-stable get 0. NOT spoofable (integrates real QUI burns, not a
   pool reserve).

   - **The composite `drain-tax + baseRate` is clamped to `MAX_FEE = 30` (0.3%)** —
     the ether.fi-redeem-equivalent ceiling. This is a FEE cap, distinct from the
     depeg haircut below, which is a separate **uncapped** axis (fee ≠ loss).

3. **Depeg haircut — `riskFactor` / `calcRisk`** (`FeeLib.sol:170`/`:36`). A
   multiplicative haircut for a stable that is *currently* off-peg, so a redeemer
   can't pull a $1-booked-but-$0.95-worth stable at par. Applied as a gross-up
   (`calcNeeded`) or a reduction (`applyFeeAndHaircut`/`allocate`).

The redemption **outflow** consumes these via `BasketLib.redeemAsBody` /
the withdraw body (`BasketLib.sol:664`, `:689`).

---

## 2. The "concentration" reuse

"Concentration" = each stable's **share of the basket**, `deps[idx]/deps[12]`. It
enters the outflow in two places:

- **Pro-rata allocation.** When a redemption isn't satisfiable from one named
  stable (or names none), it's spread **proportional to each stable's
  concentration** (`FeeLib.allocate`, `BasketLib.sol:689`):

  ```
  slice_i = totalAmount · (deps[i] / deps[12])     // ∝ concentration
            then − feeBps_i, then ÷ (1 − sev_i)     // per-slot fee + haircut
  ```

  So a redeemer draws from the basket *in the proportions it is actually held* —
  draining can't silently concentrate the basket into one name.

- **Two distinct concentration signals, weighed case-by-case — not equally.** We
  consider BOTH (a) raw **held-proportion concentration** — the pro-rata draw
  above (`slice_i ∝ deps[i]/deps[12]`), which forces a redeemer to take each name
  in the proportion it's actually held, and (b) **how much removing this stable
  shifts the yield-weighted concentration** of the basket — `calcFeeL1`'s
  `mine − baseline` drain-tax. These are *different* measures at *different*
  levels of significance, and how much each matters is case-by-case: in some
  circumstances the held-proportion draw dominates (a name held heavily but at
  baseline yield), in others the yield-weighted shift dominates (a small name
  that is the basket's yield engine, or conversely its dead weight). The earlier
  model collapsed this to a single literal `Σ shareᵢ × riskᵢ` risk-weighted term;
  the current model keeps both signals separate so the fee can tax draining the
  yield engine and subsidize shedding dead weight WITHOUT forcing them onto one
  equally-weighted axis. (We continue to test varied circumstances where the two
  approaches diverge — they are deliberately not normalized to equal weight.)

---

## 3. The "TWAP machinery" reuse (the time-aware register)

Pegged stables have no floating spot to take a price-TWAP of. The time-aware
machinery the stable fee reuses is twofold:

### 3a. Time-weighted average yield (the literal TWAP analog)
`Metrics` accumulates yield over time exactly like a TWAP accumulates price
(`BasketLib.computeMetrics`, `:95`):

```
yieldAccum += yield · elapsed                 // ∫ yield dt   (cf. ∫ price dt)
avgYield    = yieldAccum / (now − trackingStart)   // time-weighted average
```

- When spot `yield` is non-positive it is **floored at 0**, and the time-average
  then decays toward zero *in proportion to how long that lasts* (`:111-121`).
  This is just the ordinary behavior of a time-weighted average accruing 0 — NOT
  a special "depression" regime, and there is no extra mechanism. So a momentary
  yield/depeg blip doesn't swing the fee, exactly as a 30-min price TWAP ignores a
  one-block spot wick. This `avgYield` is the basket's smoothed
  yield signal (it also sets the bond coupon), and the per-stable `yieldW[]`/`deps[]`
  arrays it's built from are the very inputs `calcFeeL1` reads — **no vault is
  re-read in the fee path** (`get_deposits` exposes them per-stable for this
  reason, `BasketLib.sol` get_deposits header).

### 3b. The depeg price feed + CRE (the price-oracle analog)
The haircut's "price" is the depeg signal, read manipulation-resistantly:
`riskFactor` takes the **worse of** the CRE-reported severity and a **live
per-stable price feed** (`FeeLib.liveDepegBps` + `Aux.stableFeed`,
`STABLE_FEED_MAX_AGE`). The live feed closes the CRE *cadence* gap — a depeg
between two CRE reports is caught at redemption time, and a **stale feed → max
severity** (the redemption haircuts hard rather than trusting a frozen price).
This is the stable-side counterpart of "price exits off the TWAP, not slot0."

---

## 4. The outflow path, end to end

`Aux._redeemAs` (`Aux.sol:956`) → `BasketLib.redeemAsBody` / withdraw body:

1. `creStale` gate first — a fully *dark* CRE blocks redemption (`Aux.sol:946`);
   the live feed (§3b) covers the in-between cadence.
2. **WETH leg** (if any) is withdrawn directly (priced on the *price* TWAP — that's
   the AMM plane, see `FEES`/ETHERFI docs); the **stable legs** run the fee:
3. **Named stable:** `calcNeeded(token, amount, deps, yieldW, …)` grosses the
   amount up by drain-tax + haircut so the redeemer nets `amount` only if the
   stable is at par and at/below baseline (`BasketLib.sol:664`); withdraw that
   stable; on a paused venue, fall through to —
4. **Pro-rata fallback:** for each stable, `allocate(…)` takes its
   concentration-weighted slice, applies that slice's fee + haircut, withdraws it;
   per-slot `try/catch` so one halted venue doesn't brick the whole redemption
   (`:687-704`).
5. `checkBacking()` closes every branch — the outflow can't break `D ≥ S + L`.

The burned-vs-released coupling (immature vintages burn nothing / release
nothing; `turn` scales payout by `burned/reserved`) is the conservation guard on
top of the fee — see `project-quid-audit-pass` (immature-QUI drain fix).

---

## 5. Why this shape

- **Single set of numbers.** The fee, the bond coupon, and the basket valuation
  all read the *same* `deps[]`/`yieldW[]`/`avgYield` — the outflow fee adds no new
  oracle and re-reads no vault.
- **Drain toward health, free to shed rot.** Taxing above-average-yield drains
  (and pricing depeg at par-minus-haircut) makes the cheap exit the *healthy* one:
  draining the basket's yield engine costs, shedding a depegged/low-yield name is
  `BASE`.
- **Time-smoothing = manipulation resistance.** Because the baseline is a
  time-weighted yield and the haircut takes the worse of CRE + live-feed with a
  staleness floor, a one-block yield wick or a single stale print can't move the
  fee — the same property a price TWAP gives the AMM exits.
- **Concentration-proportional — *unless* the redeemer opts into `strict`.** The
  default `redeem` path (`redeemAsBody`) draws the basket pro-rata, so a default
  exit can't *covertly* concentrate risk into one collateral. A redeemer MAY
  still deliberately take a single name (the `strict` single-stable path that old
  `_take(…token…)` operated from) — but then it pays the **accelerating
  singular-outflow fee** for concentrating in one direction. That separate,
  preemptive tax is the price of explicit concentration; the depeg haircut
  applies identically whether the draw is pro-rata or strict. (STATUS: the
  size-convex term IS wired — `FeeLib.scaledFeeL1` scales the *above-BASE* excess of
  `calcFeeL1` by the drained fraction `amount/depᵢ` (convex in draw size: a small
  cherry-pick ≈ BASE, draining the whole stable → full `calcFeeL1`, capped at
  `MAX_FEE`), and it feeds BOTH the named-redeem gross-up (`calcNeeded`) and the
  pro-rata slice fee (`allocate`). How steeply the singular-direction tax should
  accelerate beyond this linear-in-fraction shape is deliberately left un-normalized
  so it doesn't become an artificial chokepoint that itself becomes a vulnerability —
  see open design note.)

---

## 6. Code map

| concern | location |
|---|---|
| drain-tax (yield-vs-baseline) | `FeeLib.calcFeeL1` |
| draw-magnitude convex scaling of the drain-tax | `FeeLib.scaledFeeL1` (fed into `calcNeeded` + `allocate`) |
| gross-up for a named redeem | `FeeLib.calcNeeded` (`:100`) |
| concentration-weighted slice + fee | `FeeLib.allocate` (`:148`) |
| depeg haircut (CRE ∨ live feed) | `FeeLib.riskFactor`/`liveDepegBps` (`:170`/`:204`); `Aux.stableFeed`/`STABLE_FEED_MAX_AGE` |
| upstream depeg discount of yield | `Aux.get_deposits` (`:994-1016`) |
| time-weighted average yield | `BasketLib.computeMetrics` (`:95`), `avgYield` (`:259`) |
| per-stable deps/yield arrays (no re-read) | `BasketLib.get_deposits` |
| redemption outflow | `Aux._redeemAs` (`:956`) → `BasketLib.redeemAsBody`/withdraw body (`:664/:689`) |
| dark-CRE gate | `Aux.sol:946` (`creStale`) |
| backing invariant on every branch | `aux.checkBacking()` |
