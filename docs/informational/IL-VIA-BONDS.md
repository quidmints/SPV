> ⚠️ STATUS (2026-08-01, re-verified line-by-line against the contracts): OVERRULED. The bond-funded / "IL without leverage" framing (ETH LP bears no IL because the basket's θ-bounded surplus absorbs the LVR; the dollar bond is just unexposed) is a disproven hypothesis. The IL-protect is opt-in, per-LP, ISOLATED collateral leverage on external Euler/Morpho/Aave/Liquity, and it is **UP-SIDE ONLY**.
>
> **Three corrections to the previous banner, which was itself stale:**
> 1. **NOT bidirectional.** The below-entry SHORT leg was REMOVED 2026-07-24 (`LevManager.sol:580-584`): it realizes the down-side LVR and forfeits the recovery, so for a long-biased LP holding strictly dominates over any round trip. Target LTV is `1 − √(entry/now)` and returns ZERO at or below entry (`LevMath.ilTargetBps`, `imports/LevMath.sol:109-125`). The keeper sizes to realized band concavity (`L = 1/α`), never a pinned 2× (`quid-ln/quid-bridge/src/lev_keeper.rs`).
> 2. **The ±2% band is stale throughout this file.** `SwapLib.BAND_DELTA = 20` is **±0.2%** (`imports/SwapLib.sol:831-838`). Every θ, K and LVR figure below is keyed to the old ±2% basis and is off-basis as written.
> 3. **`docs/actionable/LEVERAGE-ENGINE-SPEC.md` does not exist.** The contracts are canonical.
>
> arbETH/refillETH and the surplus-funded make-whole are REMOVED (R1: the LP bears its own IL via the share price). §11's off-chain CRE depeg watcher is also gone; the pinned Chainlink feeds ARE the signal (`Aux.sol:140`, `:202`, `FeeLib.sol:219`). See memory `spv-informational-docs-diverge-from-code`.

# Impermanent loss without leverage — borne on the ETH leg, absent on the dollar leg

How QU!D handles impermanent loss without the leverage machinery that
protocols like YieldBasis require. Working dir is `SPV/`.

> **⚠️ CORRECTION (2026-06, from code + backtest — see `IL-CERTIFICATION.md`).**
> *(This 2026-06 correction is itself now superseded by the 2026-06-30 banner
> above: the `arbETH`/`arbBody` basket buy-back it cites was **removed** (R1 — the
> ETH LP bears its own IL via the share price; IL-protect is now opt-in leverage).
> Retained for the capital-structure intuition only.)*
> The original framing below — "the ETH LP **bears** the IL" and "**fees ≈ IL**" —
> is **superseded**. Reading the code: the ETH LP holds an **ETH-denominated claim
> returned ~1:1** (`LP.pooled` in ETH; `_withdraw` sources ETH pool→venue→`arbETH`,
> the paired USD un-commits to the basket), so the LP has **linear ETH exposure +
> venue yield + fees, IL-free in the normal regime.** The LVR is borne by the
> **basket's free surplus** (`arbBody` buys the shortfall ETH at the basket's
> expense), buffered by whole-backing yield and **bounded by θ** (the in-range
> fraction). Only in the stress tail — surplus exhausted — do last-out LPs take a
> haircut (buffer-conditional, not absolute). And **"fees ≈ IL" is false** once
> concentrated: the COVID-crash backtest measured LVR ≈ 200%/yr at the ±2% band
> (K=0.71) vs single-digit fees — **yield on the (1−θ) majority is the load-bearer,
> fees are margin.** Solvent for **θ ≈ 0.25–0.40** (±2% band). No crvUSD/leverage
> needed. Treat the prose below as the original capital-structure intuition; the
> quantified truth is in `IL-CERTIFICATION.md`.

**Up front, honestly: QU!D does not *eliminate* IL — but the ETH LP does not
*bear* it in the normal regime; the basket's θ-bounded surplus does.** IL/LVR is a
real economic cost on the **volatile leg**, and a bond is a capital-structure
instrument, not a hedge. QU!D does two separate things on two separate legs. On the
**ETH leg**, the LP holds an ETH claim returned ~1:1 (linear exposure + venue yield
+ fees), with the **basket's surplus** absorbing the θ-bounded LVR — no leverage,
no hedge. On the **dollar leg**, the QUI bondholder simply **has no IL
exposure**: they hold a senior, fixed-term claim on the *stable* side, redeemed at
face at maturity — there is no √p position for them to be "underwater" on in the
first place, so the bond neither hedges nor "terms out" any IL; it just isn't
exposed. The basket-surplus side is solvent so long as whole-backing yield covers
the θ-bounded LVR (certified empirically at θ≈0.25–0.40); the dollar bond's safety
is a separate matter (full backing + the issuance cap). This doc is precise about
both boundaries.

---

## 1. What IL actually is, and what leverage does about it

A normal AMM LP position is **concave in price**: its value grows with
**√p**. Holding the underlying is **linear in price** (**p**). The gap between
the concave LP curve and the linear hold curve **is** impermanent loss — the
LP underperforms simply holding, because the position's mark-to-market lags
spot in both directions.

**YieldBasis's fix is to bend the curve.** It pairs BTC with **borrowed
crvUSD** and holds the position at a constant **2× leverage, debt pinned at
50% of LP value**. That leverage is not a directional bet — it's a
mathematical device that converts the payoff from **√p to p**, so the
leveraged LP tracks BTC **1:1** while still collecting trading fees. Keeping
the 50/50 ratio pinned requires a **Rebalancing-AMM + VirtualPool**: whenever
the ratio drifts, a tiny arbitrage opens and arbitrageurs restore it with a
single swap.

It works, but look at everything it drags in:

- borrowed crvUSD (a debt position),
- a **maintained leverage ratio** (debt = 50% of value, continuously),
- **liquidation risk** if debt/value drifts past the band,
- a Rebalancing-AMM + VirtualPool to expose the restoring arb,
- the arb flow itself as an ongoing dependency.

All of that exists to do one thing: **straighten √p into p.**

---

## 2. QU!D's approach — don't bend the curve, separate the two legs

The protocol's own auto-managed `Vogue` position **is a 50/50 in-range book** — it
**does** carry the √p IL (it gets `_repack`'d back into range as price moves). QU!D
does **not** avoid IL by changing the LP placement, and it never tries to make the
LP track spot 1:1, so it never needs the leverage device. Instead it **separates
the two legs of that book into two products**: the **dollar** leg is sold as a
fixed-term senior **bond** that has no √p exposure (§2.1), and the **ETH** leg is
held by unleveraged **LPs who bear the IL**, paid in venue yield + fees (§2.2). The
bond does not move the IL anywhere — it is simply the *other side* of the pool.

### 2.1 The dollar depositor holds a bond, not an LP position

A QU!D depositor deposits into the basket and receives **QUI with a deferred
maturity** (ERC-6909 maturity buckets) — a **fixed-term bond**, redeemable at
its **face value at maturity**, not a claim on a marked-to-market LP position.

Impermanent loss is a **mark-to-market** phenomenon: it only hurts a holder
who is exposed to the **√p** position value *right now*. A **hold-to-maturity
bond holder is not.** Their payoff is the fixed redemption amount at the
maturity month; the √p curve never touches their claim. So for the depositor,
**IL is not reduced — it is structurally absent**, because they were never
holding the concave position in the first place.

During the term, the **stablecoin basket's** diversified venue yield
(Morpho / Aave-v4 / sDAI / Liquity SP, etc.) accrues to back the bond's
promised return. The bond's projected rate is `avgYield` — the time-weighted
**stablecoin venue yield** (`yieldWeighted/raw − 1` in `get_deposits`). Be
clear about what this is *not*: `avgYield` carries **no Vogue fee or IL term**.
The bond rate is priced off the stablecoin side; the ETH/BTC LP's √p IL is a
**separate** P&L that lands on the residual, not netted into the coupon. The
issuance cap is what bounds the claim — `calcMintYield`/`calculateAverageYield`
size issuance so projected-future-redeemable ≤ projected-future-deliverable —
whether minted at a **premium** (extra QUI now, as `basket.mint` does) or at a
**discount** (zero-coupon: pay less now, face at maturity); same structure,
opposite polarity. The cap limits how much senior claim is written against
projected deliverable; it does **not** price IL.

### 2.2 The ETH LP bears the IL — unleveraged, paid in venue yield + fees

IL is a property of the **volatile leg**, and in QU!D that leg is held by the
**ETH depositors** — who are **LPs, not bondholders**. They provide the ETH side
of the 50/50 Vogue position, earn its V4 trading fees plus their chosen venue's
yield (Galaxy / Aave-v4 / ether.fi), and **bear the √p IL directly** (it lands on
their `lpShares` claim). Two honest points:

- **Our book is repacked, so IL is *realized*, not left impermanent.** Vogue is
  auto-managed: it gets `_repack`'d back into range as price moves. Re-centering
  a concentrated position **sells the underperformer and buys the outperformer
  at each rebalance**, which *crystallizes* the divergence loss instead of
  leaving it unrealized and reversible. The honest trade is **fee capture vs
  realized IL**: concentration earns more fees but realizes more IL on each
  repack. Reversion does not bail us out the way it would a passive full-range
  LP — it can't, because we already booked the move.

- **The dollar bond is the OTHER leg, not a shield.** As §2.1 notes, `avgYield`
  is the stablecoin venue yield with no IL term, and the QUI holder sits on the
  **stable** leg — so for them IL is structurally absent. That is *not* because
  the bond "absorbs" or is "senior to" the ETH LP's IL; it's because the
  bondholder was never in the volatile position. The two depositor classes sit on
  opposite sides of the same pool, and **neither subsidizes the other's IL** —
  there is exactly one IL and it lands on the LP holding the volatile leg.

So the mechanism is **not "subordinate IL below the bond"** — it is **separate the
two exposures by leg**: the dollar depositor gets IL-free senior term yield; the
ETH depositor gets an unleveraged LP that eats IL. The ETH LP's P&L is **venue
yield + V4 fees − realized IL**, and whether that's positive is the genuine open
question (§4) — the same fee-vs-IL bet every LP makes, here cushioned by the
venue yield the ETH earns *simultaneously*, because the real ETH never leaves its
yield venue (the V4 position is virtual; §9).

### 2.3 Net

YieldBasis keeps the 50/50 in-range position and **pays leverage to eliminate its
IL** (linearize √p → p). QU!D keeps the **same** 50/50 in-range position but
**unleveraged**: the **ETH LP bears the IL**, paid in venue yield + V4 fees. No
leverage, no debt, no liquidation, no external-stablecoin reflexivity. The IL
doesn't vanish and isn't hedged away — the LP that holds the volatile leg eats it,
exactly as an honest LP does; the only difference from YieldBasis is that we
refuse the leverage machinery and instead stack the ETH's native venue yield on
top of fees as the cushion. Separately — and on a *different leg* — the **dollar
depositor never touches IL at all**, because the QUI bond is a senior claim on the
**stable** side. Two products from one pool: an IL-free senior dollar bond, and an
unleveraged yield-stacked ETH LP.

### 2.4 Making the ETH LP viable — bound the footprint, floor it with yield

The problem with LPing in general is IL: most LPs get rekt, and YieldBasis's fix
is deeply flawed. So this section is precise about what actually makes QU!D's ETH
LP viable, grounded in the code — not edge-nibbling tweaks.

**Why LPs actually get rekt (the precise mechanism).** An in-range AMM LP is
**short gamma**: it continuously sells the asset that's rising and buys the one
that's falling, so its payoff vs price is concave (√p). IL is the gap between that
concave curve and HODL. Economically the LP is **selling optionality** to traders
and fees are the premium — and by no-arbitrage, in an efficient market **fees ≈ IL
on average**. LPs only profit where fees *structurally* exceed realized IL, which
competition erodes; in a trend IL ≫ fees and they're rekt. Concentration amplifies
both sides and **repacking realizes the IL** (you book the divergence each
re-center). There is no passive escape: you're short an option you're
systematically underpaid for.

**Why YieldBasis is flawed (precisely).** It hedges the short-gamma with 2×
leverage (borrow crvUSD) to linearize √p→p. By the *same* no-arb identity, hedging
the curvature costs ≈ the IL itself — paid as borrow + half the fees. So it doesn't
remove the cost; it converts a holding-loss into a flow-cost **and bolts on
liquidation risk, borrow drag, crvUSD-depeg reflexivity, and regime-dependence.**
You've added tail risk to defer a cost you still pay.

**The design space (no leverage).** Since you can't hedge gamma for free and fees ≈
IL, the only non-leverage moves are exactly three:
- **(a) Earn yield on the capital a normal LP forgoes** → raise the floor.
- **(b) Minimize the capital actually exposed to the short-gamma position** →
  shrink the IL footprint.
- **(c) Get paid above-fair for the gamma** (vol-aware fees) → hard, competitive.

**What QU!D already does — and it's (a)+(b), structurally (verified in code).**
Because the V4 position is **virtual** (mockETH/mockUSD), the ETH never has to sit
*in* the pool. `Vogue.addLiq` commits to the in-range position **only as much ETH
as can be paired against free USD backing** — `deltaTok` capped by `surplus =
basketTVL − committedUSD` and by `available = vogueETH − POOLED_ETH`
(Vogue.sol:558-584). Everything that can't be paired is **retained at the yield
venue** — the explicit "Universal retention" at Vogue.sol:519-533 ("unpaired ETH
stays on deposit at the venue earning Morpho yield"), and the LP still owns it
(`lpShares += unpaired`), earns fees on it, and withdraws it. So, verified:
- **(a)** the *full* ETH principal earns venue yield (Galaxy / Aave-v4 / ether.fi)
  — the paired slice's real ETH is in the venue too (virtual position), the
  unpaired explicitly so.
- **(b)** only the **paired slice** (`POOLED_ETH`) is short-gamma; the IL footprint
  is bounded by free USD backing, **not the whole stack**.

This is the **inverse of YieldBasis**: YB levers the whole stake *up* (maximize
exposure, then pay to hedge it); QU!D commits a thin slice and reserves the rest
(minimize exposure so it needs no hedge).

**The correct product framing (the viability key).** QU!D's ETH side is **not "an
LP that gets rekt." It's a yield-bearing ETH reserve (the dollar's backing) with a
thin LP overlay.** The depositor's excess return over simply *staking* their ETH is
exactly:

```
excess = fees(slice) − IL(slice)
```

— the LP bet, but **confined to the committed slice**, with the bulk earning the
same yield they'd get staking. The downside can't "rekt" the whole position; it's
bounded to the slice. *That* is the difference between "most LPs get rekt" (the
whole stake is the LP) and QU!D (the LP is a bounded overlay on a yield reserve).

**Where we're genuinely not doing enough (leverage-free, NEW work).** The retention
above is **emergent** (capped by free USD backing), not a deliberate risk control.
The real unlocks:

1. **Make the slice an explicit IL budget, not an accident (the θ-budget).** Add a
   cap so at most a small target fraction θ of `vogueETH` is ever in-range, sized
   so worst-case IL on θ ≤ venue-yield + fees on the whole stack. Converts the
   accidental retention into a *provable* bound: "the ETH depositor cannot lose
   more than X% to IL, because only X% is ever exposed." Small build (one cap in
   `addLiq`). **This is the single highest-leverage change.** Spec in §2.4.1.
2. **Quote USD-heavy / asymmetric — exploit that the USD side is free-minted.** A
   normal ETH/USD LP must fund both legs with real capital, so it's stuck 50/50.
   QU!D *mints* the USD side (mockUSD, backed by the basket). It can place the band
   skewed so the position holds mostly virtual USD and **minimal real ETH
   inventory** — quoting depth and earning fees with a smaller ETH-at-IL footprint.
   Today the band is symmetric (`_updateTicks(…, 200)`); asymmetric placement is the
   unlock the virtual-USD architecture *uniquely* enables and nobody else can copy.
   Medium build.
3. **Not pursuing a fee mechanism — option (c) is off the table.** A V4 dynamic-fee
   hook could in principle charge toxic flow more, but **we are not building a
   hook**: we can't classify flow cleanly at quote time, and the depth-vs-fee
   tradeoff makes it more liability than edge here. Noted only to mark the road not
   taken — viability does **not** rest on it. (We also do not try to *time* the
   slice on a fees-vs-IL signal: since `fees ≈ IL`, that's circular; "pick θ
   conservatively" already lives in #1.)

**The honest limit.** On whatever slice *is* committed, IL is unhedgeable without
leverage or options — full stop. QU!D doesn't eliminate it; it **floors the whole
stack with yield, bounds the short-gamma footprint to a small budgeted slice, and
can quote USD-heavy to shrink the ETH-at-risk further.** That makes the ETH product
"staking yield + a bounded, sized LP overlay" — viable — instead of "naked LP,"
which gets rekt. The leverage YieldBasis adds is exactly what the virtual-LP
architecture lets us refuse.

#### 2.4.1 The θ-budget cap — precise spec

**Definition.** θ ∈ (0,1] is the maximum fraction of `vogueETH` (the full ETH
reserve, yield-venue value) permitted in-range at any time:

```
POOLED_ETH ≤ θ · vogueETH
```

**Where it's enforced.** In `Vogue.addLiq`, which today caps the ETH commit at
`available = vogueETH − POOLED_ETH` (Vogue.sol:571). Tighten that one line to the
θ-bounded headroom:

```
uint cap = (theta * vogueAvail) / 1e18;            // θ·vogueETH, θ in WAD
uint available = cap > pooled ? cap - pooled : 0;  // was: vogueAvail - pooled
```

Nothing else changes: the existing `surplus` (free USD backing) and `deltaTok`
clamps still apply; θ only *lowers* the ceiling. Excess deposit ETH falls through
to the existing "Universal retention" path (Vogue.sol:519-533) → pure venue yield,
zero IL. The cap is read-only against live `vogueETH`, so it self-adjusts as the
reserve grows/shrinks.

**How θ is chosen vs the yield floor.** The depositor's excess over just-staking is
`fees(slice) − IL(slice)`. We want the *worst-case* slice IL bounded by the
yield+fees earned on the whole stack over the holding window, so the depositor is
never worse than staking even in a large move. Passive √p IL for a price ratio
k = p₁/p₀ is `|IL|(k) = 1 − 2√k/(1+k)` (e.g. **k=2 → 5.7%**, **k=3 → 13.4%**,
**k=4 → 20%**). With venue yield `Y` and fee rate `f` over the window, the
no-worse-than-staking condition is:

```
θ · |IL|(k_worst)  ≤  Y  +  θ · f
   ⇒   θ  ≤  Y / ( |IL|(k_worst) − f )
```

Worked example: `Y = 4%`, `f = 1%` over ~1yr, tolerate a **3× move** (k=3,
|IL|=13.4%) → `θ ≤ 4% / (13.4% − 1%) ≈ 0.32`. So **θ ≈ 30%** keeps the depositor
whole-vs-staking through a 3× swing; the other ~70% of the ETH sits in pure venue
yield. Tolerate only 2× → θ can be larger; demand 4×-proofing → θ shrinks toward
~0.20.

**Safety margin.** This uses the *passive* √p IL. Vogue is concentrated and
**repacks**, which realizes *more* than passive IL, so θ should carry a haircut
(pick θ from a `k_worst` one notch beyond your real tolerance, or scale |IL| up by
the concentration factor). The cap is a ceiling, not a target — the `surplus`/fee
gates (improvement #3) can keep the realized slice *below* θ when fees don't
justify it.

#### 2.4.2 Whose flow — the honest TAM, and why "cheapest venue" is a trap

The θ math above takes the fee rate `f` as a given, but `f` is **not** uniform
across the flow that hits the pool — and the part of the flow that pays `f` is
often the *same* part that inflicts the IL. Getting this right is the difference
between an honest pitch and a self-defeating one.

**"Guaranteed order flow because we're the cheapest ETH venue" is false, and it
contradicts §2.4's own `fees ≈ IL` identity.** Cutting the fee doesn't win you
clean volume; it makes you the venue that CEX–DEX arbitrageurs correct **first and
hardest** when the off-chain mid moves. That flow *is* the realized divergence loss
(LVR) the ETH LP eats, and by no-arbitrage the incremental fees it pays ≈ the
incremental IL it causes. Racing the fee tier down grows **both** sides of
`fees − IL`; it does not raise the difference. The headline pool volume is the
wrong TAM. The honest addressable number is the **uninformed, markout-neutral
fee-paying volume** — not the through-volume, most of which is arb you'd lose money
being the counterparty to.

**The flow is ~five populations; only some are net-positive to be counterparty to:**

1. **CEX–DEX arbitrage — the dominant toxic flow.** Bots correcting the pool
   against Binance/Coinbase/OKX on every stale quote. Unbounded in size (capped
   only by the whole pool, unlike cyclic arb), highly concentrated (the
   CrocSwap/0xfbifemboy ETH/USDC study: a handful of wallets, mostly one MEV
   complex, originate most swaps), and **markout-negative** — this is the LVR the
   Vogue residual + bondholders' senior claim are structurally exposed to.
2. **Cyclic / atomic on-chain arb.** Triangular arb that takes whatever ETH/USDC
   price is there as an insensitive leg — *mildly positive* markout (the non-toxic
   wallet in that study averaged ~+5.6 bps), single-tx, gas-sensitive.
3. **Aggregator / intent-routed flow** (UniswapX, 1inch Fusion, CoW, 0x/Matcha
   RFQ). Where retail now lives — but solvers CoW-match and internalize the easy
   uninformed flow **off-pool**, so the residue that reaches v4 directly skews
   *more* toxic over time, and not all intent flow is equal (CoW consistently
   improves user welfare vs the raw pool; UniswapX has shown a negative Binance
   markout trend). The on-chain `msg.sender` is a router, so attribution must
   decode to the *recipient*, not the sender.
4. **Direct retail / wallet swaps.** The genuinely uninformed, markout-neutral
   flow — pure fee revenue — but a shrinking share, because most of it is now
   wrapped in (3).
5. **Liquidations & protocol flow** (Aave/Morpho liquidators, LST/LRT redemption
   rebalances, treasury). Lumpy, vol-correlated, semi-informed. (Sandwich MEV is
   not demand — it's parasitic on (3)/(4).)

**How to actually separate them (so we position with knowledge of the ebb/flow).**
Pull the pool's `Swap` events with the enclosing tx (origin, builder, block
position, priority fee, mempool visibility) and classify by: **markout to CEX**
(post-swap pool price vs Binance mid at t+Δ — the single strongest signal, the
0xfbifemboy method); **block position + private orderflow** (top-of-block via a
builder/MEV-Share, high priority fee → searcher); **atomicity** (multi-venue in one
tx → on-chain arb, usually benign per (2)); **sender labels** (Universal Router,
1inch, 0x Settler, CoW GPv2Settlement, UniswapX Reactor, Paraswap → intermediated;
known bot complexes / MM addresses → toxic); and **per-address concentration**
(volume is power-law — a few entities are most of the toxic notional).

**What this does and doesn't license us to claim.** We are **not building a V4 fee
hook**, and at the pool you **cannot pick your counterparty** — you choose how much
liquidity to post and where to place the band, not who trades against it. So we
take the *blended* flow and `fees ≈ IL` holds on it; there is no "we only capture
the clean flow" mechanism to claim. The taxonomy's job is narrower and honest:
(i) kill the "cheapest ⇒ flow" pitch; (ii) set the TAM to uninformed fee-paying
volume; and (iii) feed a **realistic, toxicity-discounted** fee rate `f` into the θ
math above — headline `f` overstates the net premium, because much of the volume
that pays it is the same arb that inflicts the IL. The levers that actually make
the ETH LP viable are the ones that **don't require winning the flow game**: the
**yield floor (a)**, the **θ-bounded slice (b)**, and **USD-heavy asymmetric
quoting (improvement #2)** — which shrinks the real ETH inventory exposed to
short-gamma *regardless* of how toxic the flow is. Bounding the exposure beats
trying to select flow we can't select.

---

## 3. Why this is simpler

| | YieldBasis (leverage) | QU!D (bonds) |
|---|---|---|
| Linearizes √p → p via | 2× leverage, debt = 50% of value | n/a — depositor holds a bond, not the LP curve |
| Borrowing | borrowed crvUSD (a debt position) | **none** |
| Ratio maintenance | continuous 50/50 pin | **none** |
| Liquidation risk | yes (debt/value band) | **none** — no debt to liquidate |
| Rebalancing-AMM / VirtualPool / restoring arb | required | **none** |
| Volatile-leg depositor | linearized LP, tracks BTC 1:1 | unleveraged ETH LP — bears √p IL, paid venue yield + fees |

No borrow → **no liquidation, no leverage ratio to maintain, no
Rebalancing-AMM, no VirtualPool, no restoring-arb dependency.** The moving
parts that make a leveraged-LP design fragile simply don't exist.

---

## 4. The honest trade-off

This is not a free lunch — it's a **different product**:

- **YieldBasis** gives a **liquid** position that **tracks the volatile asset
  1:1** plus fees. You can exit anytime at the linearized value, and you keep
  full directional exposure.
- **QU!D bonds** give **fixed, term yield with no √p mark-to-market** for the
  holder, but the holder is **locked to maturity** (early redemption is clamped
  to what has matured / `redeemableAmount()`), and the bond is
  **stable-denominated** — the holder is **not tracking the volatile asset**.
  They traded directional exposure + liquidity for senior, term yield, carrying
  **credit risk on the backing** instead of √p IL.

So "no leverage" cuts two ways, by leg. The **dollar** depositor escapes √p IL
entirely — not via any hedge, but because they hold a senior bond on the **stable**
leg and were never in the volatile position. The **ETH** depositor *does* bear the
IL (realized, because Vogue repacks) — unleveraged, as a plain LP, paid in venue
yield + Vogue fees. The leverage YieldBasis needs is the price of making *its*
volatile LP liquid and spot-tracking; QU!D's ETH LP forgoes that promise (and its
cost), and QU!D's dollar product sidesteps √p exposure by being a different
instrument on the other leg.

### Residual risk each leg *does* carry

- **ETH LP:** the genuine open risk is **fee-vs-IL** — does venue yield + Vogue
  fees cover realized IL over the holding period? If not, the LP's `lpShares`
  claim shrinks. Because it is unleveraged, the downside is bounded by principal —
  no liquidation, no debt spiral.
- **Dollar bondholder:** no √p exposure at all; their risk is **credit/backing** —
  will the bond be redeemable at maturity? That is bounded by the issuance cap
  (`calculateAverageYield`), the redeem clamp (`redeemableAmount()`), the
  single-sided LP backing, and the basket's stablecoin diversification — and is
  the subject of the `_take` redemption-fee weighting (cheap to withdraw an
  over-concentrated/depegged stable = heals the basket; expensive to drain the
  good collateral). The ETH LP's IL does **not** flow onto the bondholder as
  credit risk except in the tail where total backing would fall below senior
  claims — which the cap exists to prevent (and per-LP venue attribution, §11,
  keeps a venue's loss with that venue's LPs). That is a different, and we argue
  more tractable, risk than a leverage band that can liquidate.

---

## 5. Cold start — bump-starting the protocol off its own momentum

The same bond instrument also solves the **liquidity-bootstrapping** problem,
and the cleanest way to see it is the **mechanically-injected diesel** analogy.

A mechanical diesel needs no spark and no battery to *ignite* — it's
**compression-ignition**, self-contained. The only hard part of a cold start is
**turning the engine over**. With a dead starter you don't need an external
battery: you **engage the drivetrain** (roll the vehicle in gear, drop the
clutch) and the car's **own momentum** cranks the engine through the drivetrain
until compression fires. Energy to start comes from *inside the system*, not a
jump pack.

QU!D bootstraps the same way:

- **Ignition is self-contained.** QU!D doesn't need an external token subsidy to
  be *economically viable* — the basket earns **real venue yield** (Morpho /
  Aave-v4 / sDAI / Liquity SP) plus LP fees. There's a real "fuel + compression"
  already; nothing external has to make it *worth* running.
- **The only hard part is turning it over** — the chicken-and-egg of needing
  liquidity to make yield and yield to attract liquidity. That's the cold
  crank.
- **Bonds engage the drivetrain.** Minting QUI at a **premium / seed bonus**
  (`calcMintYield`, deferred to maturity) pays early depositors out of the
  protocol's **own projected future yield** — monetized up front as the bond's
  premium — rather than out of an external emissions battery. The system cranks
  itself over using its **own forthcoming output**, exactly like the car
  cranking the engine with its own momentum.
- **Once it fires, it self-sustains.** Initial bonded liquidity generates the
  yield that the bond promised, which attracts the next deposits — the engine
  idles on its own and you let the clutch out.

So the contrast with the usual cold-start is the contrast between a **jump
pack** (external liquidity-mining emissions / VC subsidy — energy injected from
outside) and a **bump-start** (bonds — the protocol turns itself over on its own
deferred yield, no external energy). The bond does double duty: it routes the
depositor around IL (§2) **and** it's the drivetrain that bump-starts the engine
from cold. `calculateAverageYield` is what bounds how hard you can crank — you
can only borrow against future yield you can credibly project, so the issuance
cap is the clutch that stops you from over-revving a cold engine.

### 5.1 The projection horizon shrinks after the bootstrap year

How far forward `_finishMint` mints the yield premium is itself a crank length,
and it is **only long during the bootstrap**:

- **Bootstrap (currentMonth < 12):** up to a **full year** forward
  (`when ≤ nextMonth + 12`), with the 1:1 supply cap *skipped*. This is the only
  way to offer real term before any yield has been *observed* — there are no
  snapshots yet, so we project. It deliberately mints QUI against not-yet-earned
  yield; that's the cold crank.
- **After year 1:** snapshots exist, so projecting a year out no longer makes
  sense — it just mints **excess QUI against optimistic forward yield**, which the
  1:1 cap then claws back while leaving a fat immature cohort. So the horizon
  collapses to **~1 month** (`when ≤ nextMonth + 1`): bonds go short-term, the
  premium is naturally tiny, and supply stops being stretched. The engine is
  warm; you stop flooring the throttle.

The bootstrap's far projection is a *one-time* ignition cost, not a permanent
policy — exactly because it's gated on `currentMonth < 12`.

---

## 6. Why a depeg prediction market can't offset the over-issuance (rejected)

A tempting idea: run a per-stable/per-vault **depeg prediction market** as
depeg *insurance*, **dual-encumbered 1:1** (total incident-side stake == total
no-incident-side liquidity). The no-incident side is represented **exactly the
way `POOLED_USD` is in Vogue** — actual depositor dollars held by Aux in external
venues, accounted virtually and paired against the incident side. *Separately*,
the QUI **over-issuance** from optimistic forward yield projection
(`calcMintYield`) would be **counterbalanced by burning** the QUI collected as
fees from placing orders / taking sides in the market. It appears to solve
the classic chicken-and-egg ("no inside info ⇒ no bettors ⇒ no insurers") by
standing the no-incident side up from basket capital. **It does not work.
Recorded here so it isn't re-litigated.**

**1. The no-incident dollars ARE the dollars backing QUI.** Because the
no-incident side is POOLED_USD-style basket capital — the depositors' actual
dollars in venues — it is the *same* capital that must redeem QUI 1:1 at maturity.

**2. So an incident payout double-spends that backing.** When an incident
resolves and the incident side recovers funds *from* the no-incident side, those
dollars leave the basket — they are "no longer there" to redeem QUI at maturity.
The same dollar can't both back QUI redemption and settle an insurance claim.

**3. It's pro-cyclical.** The payout fires *during* a depeg — when the basket is
already impaired — draining backing exactly when QUI is most under-backed. It
amplifies the crisis instead of absorbing it.

**4. It un-socializes a loss that's already fairly socialized.** The basket's
**fair-value redemption (gate C) already *is* the depeg-loss absorption**, and
every QUI holder eats the same proportional haircut. A market payout makes
*bettors* whole while everyone else absorbs the loss, funded by draining shared
backing — strictly worse than gate C, which does it for free. (This is what the
port `Link.sol` note meant by "the basket IS the absorption mechanism.")

**On the fee-sink (orthogonal):** burning QUI via order-placement fees IS a
legitimate way to counter the yield-projection over-issuance — but it does
nothing for the payout problem above (it doesn't put spent backing back), and
the same burn could be sourced from ordinary protocol fees without standing up a
market at all. So it isn't a reason to build one.

**The only non-broken insurance variant** needs **external, segregated
reinsurance capital** that flows *into the basket* on an incident (making *all*
holders whole), basket paying premiums in calm. That's a legitimate product, but
it's external capital paired against the incident side — *not* basket dollars
that are simultaneously backing QUI — so it doesn't double-spend. It is a separate
product, not the construction above.

**What survives:** the depeg-risk *signal* layer is independent of any market —
a self-normalized aggregator of CRE price-velocity + on-chain flow-velocity
(net-flow + concentration drift), each weighted only to the extent it's
anomalous vs its own time-weighted baseline ("none over-weighed unless the
signal explicitly suggests itself"). That needs no bettors and no no-incident
side. Keep the signals; the prediction-market / dual-encumbrance / burn-loop and
the court-jury resolution layer stay dropped (the latter also because voter
latency outruns relevance).

---

## 7. The numismatic principle — pairing two unique assets so the dollars are *already there*

Everything above is one design instinct applied twice. State it plainly,
because the BTC-side work (standard-LDK channels, the per-channel close, the
single always-present dollar leg) was a months-long *simplification toward* it,
not away from it.

**The right way to pair two unique assets is to make one of them the proof and
the other the guarantee — and to hold the guarantee yourself.** QU!D pairs a
**volatile, sovereign, work-secured asset** (ETH; and, on the BTC side, native
sats in self-custodied Lightning channels) against a **stable dollar leg that
the protocol itself manages**. The pairing is not "two tokens in an external
AMM and hope the other side is liquid when you need it." It's: the protocol
*owns and arbs* the dollar leg as part of the LP position, so it is **present by
construction**, not by market grace.

### 7.1 Proof of work, expressed through proof of stake taken to its limit

ETH is proof-of-work in spirit even post-Merge: it is the asset whose value is
*earned*, exogenous, not mintable by the system. But raw PoW value can't, by
itself, promise you a dollar exit. What lets it **express** that promise is
proof-of-stake pushed to the absolute limit of its definition — **virtual
accounting + multi-venue lending of ETH and stables** (`POOLED_USD` /
`POOLED_USD_BTC` as the in-range dollar slice, the basket's capital working
across Morpho / Aave-v4 / sDAI / Liquity SP, the single-sided book repacked and
arbed to track value). The staking isn't a consensus detail here; it's the
*accounting discipline* that takes idle paired capital and makes it a standing,
yield-bearing, always-redeemable dollar reserve. PoW supplies the thing worth
holding; PoS-as-accounting supplies the certainty that you can leave.

### 7.2 All your eggs in one basket — so make the basket absolutely, trustlessly safe

The honest shape of QU!D is a *concentration*: one basket holds the backing.
The classic warning is "don't put all your eggs in one basket." The answer is
not to scatter — it's to make the **one** basket as safe as it is possible to
be, and to reach that safety **trustlessly** (SPV-proven BTC custody, virtual
accounting that never lets the system represent value it doesn't hold, the
runtime `POOLED_USD ≤ TVL` invariant, conservation rather than promises). The
safety is the kind you don't *feel* — like people don't really feel the presence
of good; it isn't loud, it's just *there*. A well-built backing layer is
invisible precisely when it's working.

### 7.3 The guarantee, concretely: panic cannot remove the dollars

This is the operational payoff and the thing the BTC refinement was *for*:

> In an LP position, **regardless of the scale of panic at any given moment**,
> you are guaranteed to be able to swap out to dollars automatically — because
> the dollars are **already** part of the protocol-managed LP position, always
> arbed back to match the value of the asset.

Why this holds, mechanically, and where it's bounded:

- The dollar leg (`POOLED_USD`, `POOLED_USD_BTC`) is **real basket capital the
  protocol custodies**, not a counterparty's liquidity that can flee. A bank run
  *is* the swap-out — and the dollars it draws on were posted the moment the
  position was formed.
- Its price stays matched to the asset's real value by **external
  arbitrageurs** — the ordinary AMM mechanism: when the virtual pool's price
  drifts from real BTC, outside arbers trade against the pool and correct it.
  The protocol does **not** arb against itself (its counterparty would be its
  own book — pointless and self-draining). `repack` is a *separate*, internal
  op: it **re-centers the concentrated liquidity range** — burns the position
  at the stale ticks and re-mints it around the current price so the LP's
  liquidity stays in-range and productive. It moves no value by swapping; it
  only relocates the range. So "the dollars correspond to what the asset is
  worth" is upheld by external arb on price + repack keeping the band live —
  not by any self-trade.
- On the BTC side this is exactly what the **per-channel close** enforces: the
  dollars a swap-out put into `POOLED_USD_BTC` are conserved 1:1 against
  `netDeliveredBtc`, so every LP's exit draws against dollars that are provably
  already in the pool (`Σ claims == POOLED_USD_BTC`, no mint from nothing). The
  earlier close-spot valuation was rejected precisely because it could promise a
  dollar that wasn't there.
- **Bounded honestly:** "the dollars are there" is an invariant the arb must
  keep holding (`POOLED_USD ≤ TVL`, fees ≥ realized IL over time — §4). The
  guarantee is automatic liquidity *at the arbed value*, which already includes
  the LP's borne IL (§2.2). It is not a promise that the value didn't move; it's
  a promise that whatever it's worth, the dollars to pay it are in custody now.

That is the whole design in one line: **don't promise the exit — pre-stage it.**
Pair the work-asset with a protocol-owned, arbed dollar leg, and the swap to
safety is not a hope you act on during the panic, it's a fact that was already
true before it started.


Make it concrete, because the principle is not a metaphor about sentiment — it
names *real, locked, redeemable holdings*:

- the **BTC is locked in self-custodied Lightning channels** (SPV-proven, 2-of-2,
  the LP holds their own key) — present and withdrawable, not an IOU;
- the **ETH is multi-venued** — never one basket — the depositor *chooses* among
  Galaxy(Morpho), Aave-v4, and ether.fi (no primary), with a protocol-owned
  Uniswap v3 weETH/WETH pool as the cheap, fee-capturing offramp, so no single
  venue's failure can sever the holder from their exit;
- the **dollar leg** sits in the diversified basket (Morpho / Aave-v4 / sDAI /
  Liquity SP), watched so its reported value is its *real* value.

This is the same instinct on both assets: **multi-venue, self-custody, verify
rather than trust** — the spread itself is the safety, the decentralization is
nearly free (§ the BTC channels), and the goodness of the backing is the kind
that is *there whether or not you feel it*. It is also the kind that must be
**held** — the invariants, the watchers, the fallbacks, the try/catch around
every venue exist precisely because a present good is something defended, not
something assumed. The protocol's whole job is to keep that presence true under
any amount of force against it: the dollars, and the asset, are already there.

## 8. What this does for Lightning — and why that matters

### 8.1 Why Lightning was Bitcoin's saving grace

Bitcoin's base layer settles ~7 transactions per second, with finality measured
in blocks and fees that spike under load. That is enough to be *settlement* — a
trust-minimized ledger of record, "digital gold" — but it cannot be **money you
spend**. Without a payment layer, Bitcoin's monetary thesis stalls at "store of
value": you cannot buy coffee on an L1 that costs dollars and minutes per send.

Lightning is the answer that *keeps Bitcoin Bitcoin*. Payments move off-chain
across 2-of-2 channels, instantly and nearly for free, while every channel is
ultimately anchored to — and enforced by — Bitcoin L1: the funding UTXO, the
penalty/justice transactions, the unilateral close. It inherits L1 security
without paying L1's throughput tax. That is the saving grace: it lets Bitcoin be
a *medium of exchange* without a new chain, a new consensus, or a new trust
assumption. It is the only scaling path that does not dilute what Bitcoin is.

### 8.2 Lightning's own viability problem: dead capital

Lightning's hardest, most persistent adoption barrier is not cryptographic — it
is **economic**. To route payments you must lock BTC into channels, and that BTC
earns *nothing*. Inbound liquidity is chronically scarce precisely because the
capital that provides it sits idle. Every honest analysis of "why isn't Lightning
bigger" lands here: liquidity provision is a cost center, so there is too little
of it, so routing is shallow, so the network underdelivers its own promise. The
locked BTC is present and safe — but unproductive, and unproductive capital is
under-supplied capital.

### 8.3 What this thread builds, and how it lifts that barrier

QU!D makes the BTC **locked in a Lightning channel simultaneously back a
yield-earning position** — without taking it out of the channel and without
weakening the channel:

- **Standard LDK, no fork (§ BTCChannels).** Channels are ordinary BOLT/LDK
  channels; revocation, HTLC resolution, and justice stay Bitcoin-native. We add
  nothing to Lightning's security surface — we *reuse* the battle-tested one.
- **The EVM only SPV-bridges funding and close.** `openChannel` proves the
  2-of-2 funding UTXO exists (and `recordClose`/`forceCloseByLP` that it was
  spent) via a Bitcoin merkle proof against a header chain — *now validated
  end-to-end against a live regtest node*, real tx → real proof → the real
  on-chain verifier accepts it. The bridge is not a diagram; it runs.
- **The funded channel becomes an LP position** (`registerBtcLp`): that same
  self-custodied BTC now backs the dollar leg and earns — USD-leg fees minted as
  QUI, the BTC-leg fees accrued in **native sats** and settled by the hop at
  close. Per-channel, true to Lightning (`delivered = funded − finalBalance`,
  paid its share of realized swap proceeds — not a pooled abstraction).

So the BTC keeps doing its Lightning job — routing, instant payments, self-
custodied, L1-enforced — *while* it stops being dead capital. The "real presence
of good" of §7 is exactly this: the dollars are already there because the BTC
that anchors them is real, locked, and now also **productive**.

### 8.4 The significance

This attacks Lightning's core disincentive at its root. If providing channel
liquidity *pays* — if the BTC you commit to the network earns yield instead of
sitting idle — then the supply curve for Lightning liquidity moves. Deeper
liquidity means better routing and larger capacity for *everyone* on the network,
not just QU!D's LPs; the externality is positive. And it is bought without
custodial wrapping (no wBTC-style IOU), without a Lightning fork, and without
asking Bitcoin to be anything other than Bitcoin. Turning locked-but-idle channel
BTC into locked-and-earning backing is a small lever on a large hinge: it makes
the economics of being a Lightning liquidity provider *positive-sum*, which is
the one thing the network has structurally lacked — and it does so while
strengthening, never diluting, the self-custody and L1-security that made
Lightning Bitcoin's saving grace in the first place.

## 9. Compared to YieldBasis — hedging IL vs bearing it unleveraged

YieldBasis (Michael Egorov / Curve) targets "zero IL" on a BTC LP. Mechanism:
deposit BTC, the protocol **borrows an equal value of crvUSD against it** and
runs a Curve BTC/crvUSD LP at a **constant 2× leverage** (50% debt / 50% equity).
A 2× leveraged AMM position's value moves ~linearly (1:1) with BTC instead of the
LP's natural √-concave payoff — so the *holding* IL is cancelled while the
position still earns trading fees.

**But IL is not eliminated — it is PAID FOR.** Maintaining the constant 2×
leverage as price moves requires continuous rebalancing, and YieldBasis funds
that from a "rebalancing budget" filled by **(a) the crvUSD borrow fees and (b)
half of all trading fees**. That is the cost, made explicit: the LP keeps only
~half the gross fees, plus pays the borrow, and in exchange the curvature is
hedged out. This is exactly what theory forces — by no-arbitrage the cost of
hedging the concave payoff ≈ the IL itself; you can move IL from a *holding loss*
to a *flow cost*, but you cannot make it vanish. The compromises that buys:

1. **Leverage + debt** → liquidation risk, a borrow-rate drag, and **reflexivity
   on crvUSD** (a crvUSD depeg or Curve-lending stress cascades into every LP).
2. **Half the trading fees** are consumed by the rebalancing budget — the "zero
   IL" is literally half your fee income.
3. **Regime-dependence:** it only nets positive when (remaining fees + asset
   yield) > (borrow + rebalancing cost). A low-fee / high-vol regime bleeds.
4. **Dependence on arbitrageurs + the rebalancing-AMM** to hold the 2× peg under
   stress — the linearity is a *maintained* property, not a guaranteed one.

**QU!D makes the opposite choice on the volatile leg, and needs none of these.**
This comparison is *volatile-LP vs volatile-LP* — the dollar QUI bond is a separate
stable-side instrument and plays no part in it (§2.1). On the ETH side QU!D runs
the **same** 50/50 in-range position but **unleveraged**: the ETH LP **bears the
√p IL** rather than paying to hedge it. We do not eliminate IL and do not pretend
to — by the very no-arbitrage argument YieldBasis concedes, cancelling curvature
costs roughly the IL itself, and *that payment* is what drags in leverage,
liquidation, crvUSD reflexivity, and the half-fee tax. We decline all of it.

Be precise about what actually helps the ETH LP's IL, because most of our
plumbing is *solvency*, not IL reduction. There is **one real cushion and one real
protection that exist today**:

1. **Yield-stacking via the virtual LP (the cushion — exists).** Vogue's V4
   position is virtual (mockETH/mockUSD), so the depositor's real ETH never idles
   in the AMM — it stays in its chosen venue (Galaxy / Aave-v4 / ether.fi)
   **earning yield while the virtual position earns V4 fees**. A plain unlevered LP
   forgoes native yield to sit in the pool; YieldBasis borrows to compensate; QU!D
   simply collects both. That venue yield is our analogue of YieldBasis's
   "rebalancing budget" — except it is *real external yield*, carries *no debt*,
   and taxes *none* of the trading fees. The ETH LP's P&L is **venue yield + V4
   fees − realized IL**. Note this does not *reduce* IL — it *out-earns* it.
2. **Don't realize IL at a manipulated price (the protection — exists).** `_repack`
   is what *realizes* IL (it sells the underperformer to re-center), so the one
   thing that can make IL worse than the price move itself is repacking at an
   off-fair print. `_rebalance` already guards this: it **skips the repack when
   spot deviates from the asset's TWAP** (`BasketLib.isManipulated(…, 3)`), so we
   never crystallize IL into a manipulated price.

**The one genuine improvement on the table — regime-adaptive repack width — was
weighed and declined.** Today the in-range band is a *fixed* width (the hardcoded
`200` in `_updateTicks(sqrtPriceX96, 200)`), repacked when price exits it. Width is
the real fee-vs-IL dial: wider realizes less IL (fewer, gentler re-centers) at the
cost of fewer concentrated fees; tighter harvests more fees and more IL. Making the
width track realized volatility would be leverage-free and legitimate — but it is
net-new machinery (a vol estimator + an adaptive-width path, plus the test
surface), and the marginal IL it would save over the fixed band does not justify
that added complexity. Decision: **keep the fixed band**; rely on the yield-stack
to out-earn IL and the TWAP guard to keep it from being crystallized at a bad
price. The lever is documented here in case the calculus changes at scale.

**What is NOT an IL improvement (and we should stop dressing it up as one):**
the BTC-leg `btcShortfall` fires on a ≥1% delivery *shortfall* — that is
**solvency**, covering a gap so withdrawals settle; it does nothing for the ETH LP's
fee-vs-IL. (The ETH-side `arbETH`/`arbBody` make-whole was **removed** — R1: the ETH
LP bears its own IL via the share price, per the banner.) The issuance cap
+ per-LP venue attribution (§11) protect the **dollar bond's backing** and
**contain** one venue's loss to its own LPs — **containment**, not IL reduction.
Both matter enormously, but for different risks; folding them into an "IL
improvement" list is the same dollar-side/ETH-side conflation §2 just removed.

**Is there anything to adopt from YieldBasis? No — not without importing its
compromises.** Leverage-hedging the ETH LP the YieldBasis way re-introduces the
exact liquidation + crvUSD-reflexivity it took on, and violates the no-leverage
backing invariant. The honest accounting: IL on the ETH leg cannot be *reduced*
without leverage — only **out-earned** (the yield-stack), kept from being
**worsened** (the TWAP guard), or **traded against fees** (repack width, once it's
made adaptive). (We also do *not* run an extra protocol-owned LP — the ether.fi
offramp is a fallback ladder, not a position; §10.) Different products: YieldBasis
= IL-free *leveraged* BTC-LP yield; QU!D = a fully-backed dollar bond with **no**
IL exposure, *plus* an unleveraged, yield-stacked ETH LP that bears IL the honest
way.

*Sources: [YieldBasis docs — How it works](https://docs.yieldbasis.com/user/how-it-works);
[Mirador — IL and how YieldBasis makes it "zero" (constant 2× leverage)](https://www.mirador.finance/p/impermanent-loss-and-how-yieldbasis-b10);
[Sentora/Medium — Yield Basis reimagines Curve's pools](https://medium.com/sentora/impermanent-loss-no-more-how-yield-basis-reimagines-curves-crypto-pools-1b50b8aa5c6b).*

## 10. The ether.fi strategy — a fair-capped offramp ladder, backstopped by the un-pullable queue

> **UPDATE:** the "no protocol-owned LP" stance below was **reversed** — the
> ⚠️ **ROVER CONTENT SUPERSEDED 2026-08-03 → `docs/actionable/ROVER-WEETH.md`.** The claims below
> (exit fills "~0.12%", "both pools deep on the WETH side") were MEASURED TRUE but are a SNAPSHOT of
> freshly-stranded liquidity that decays at 0.67 bps/day and crosses the 0.3% redeem rate in ~9-21
> days. Do not cite them as venue properties. Kept for provenance only.
> protocol-owned **Rover** weETH/WETH Uniswap-v3 LP is now a live venue
> (`VENUE_ROVER`) and one of the offramp routes; it captures swap fees and
> rebalances the pool (fair-anchored, no cap/window). See `ETH-VENUES.md`. The
> load-bearing *guarantee* of redeemability is still the un-pullable ether.fi
> queue (rung 3), not any pool position — Rover is a fee-earning convenience
> route, not the safety floor.

ether.fi is one of the depositor-chosen ETH venues: deposit ETH, receive weETH
(restaking yield), held as the venue's backing. The only friction is the *exit* —
converting weETH→WETH — where ether.fi's own instant-redeem charges ~0.3%. We do
it with a **fallback ladder**:

1. **Swap capped at fair** — through the protocol-owned **Rover** weETH/WETH v3 LP
   and/or the public v3 pools. Both weETH/WETH pools are deep on the WETH side, so
   an exit swap fills at ~0.12% (well under 0.3%, verified). We cap `minOut` at
   ~0.3% of fair and try **both** pools (0.05%, 0.01%), so a drained/manipulated
   pool reverts and we never sell below that floor to arbers.
2. **Instant-redeem (~0.3%)** for an `instant`-chooser if the pools can't fill at
   fair — self-contained, no pool dependency ("instant costs itself").
3. **Withdrawal-NFT (free) — the guarantee.** ether.fi's own queue
   (`requestWithdraw` → an NFT the LP claims after finalization): no fee, no pool,
   **un-pullable.**

**The guarantee of redeemability is un-pullable — rung 3, not a position.** Pool
liquidity (ours or third parties') is not *false security* against the one real
risk — third-party WETH LPs pulling out — because any WETH in the pool converts/arbs
away exactly when stressed. That is why the *floor* is the ether.fi queue, which no
one can pull. Rover earns fees on the offramp flow (and rebalances the pool) but is
not relied on for the redemption guarantee; a net one-directional offramp (we are
structurally weETH sellers) carries directional inventory risk, which is why it is a
convenience route on top of the queue, never the backstop.

**The cost is borne by the exiting LP, never socialized.** `offrampEtherFi`
returns the *requested* amount while the recipient receives the swap output
(fair − fee), so the exiting ether.fi LP eats their own conversion cost (≤0.3% for
`instant`, **0** for `wait` — the NFT pays full value). It is never drawn from
other reserves. (Load-bearing invariant: it returns the requested amount, not the
realized output — `AUDIT-TODO §7b`.)

This is §7 on the ETH side: an ether.fi LP's redemption is *always there* —
guaranteed by the un-pullable queue — unfelt but present. Hard wall + mutual
backstop: §11.

## 11. Multi-vault is the security response — to what the watchers detect

Backing is spread across many venues, never one basket — on both assets (ETH:
Galaxy/Morpho, AAVE-v4, ether.fi; the dollar leg: Morpho / AAVE-v4 / sDAI /
Liquity SP across several vaults). Multi-vault is **not merely depositor choice.**
It is the mechanism that lets the protocol *act* on a detected threat.

Detection is split by question:

- **Depeg watcher (per token)** — a harder-to-forge signal, so it lives off-chain
  in the Chainlink-Runtime (Go) workflow, quorum-attested: multi-vendor prices → a
  severity + velocity scalar (`getDepegSeverityBps`) that drives the on-chain
  fee/haircut/gates. Non-manipulable because it is the *agreement of a node quorum*,
  not any on-chain TWAP a whale could push. (`FeeLib.riskFactor` also cross-checks a
  live per-stable Chainlink feed, taking the worse of the two — see `FEES-OUTFLOWS-TWAP.md`.)
- **Vault health (per venue)** — "can this vault still *return* the assets?" — is
  now **100% on-chain and permissionless** via `Aux.pokeVaultHealth`, which reads
  only ERC4626 ground truth (`convertToAssets`/`maxWithdraw`). The former off-chain
  CRE vault-health path and the graded haircut lever were **removed**. See
  `VAULT-WATCHER.md`.

Detection is worthless without somewhere to go — and that is exactly what
multi-vault provides. On an incident the protocol **evacuates** the deteriorating
vault (pulls what is withdrawable and **spreads it equally across the healthy
vaults** — maximal diversification of the recovery) and **blocks** new deposits to
it (re-admitted only once it is liquid again). A blocked vault is **valued at
`maxWithdraw`** (its deliverable value) in `get_deposits`/`vogueETH` — there is no
separate graded haircut lever (removed): illiquidity is never mistaken for
insolvency, a solvent-but-locked vault is evacuated and blocked but its present-but-
locked dollars are not written off (the dollars are there — §7), and realized loss
is already booked automatically because backing reads `convertToAssets`.

The wall and the backstop are **both** true, at different layers — not either/or:

- **Normal operation — the hard wall.** Each LP's exit is served from the venue
  *they chose*: an ether.fi LP via the offramp ladder (§10), a Galaxy LP from
  Morpho, an AAVE LP from AAVE-v4. No one routinely subsidizes anyone — a depositor
  who never chose ether.fi never has their deposit pulled into it, and conversely.
- **Under stress — mutual backstop.** When a venue cannot serve (drained, or an
  evacuation in flight), the *other* venues' liquidity covers the shortfall — in
  **either direction**. That bidirectional rescue is the whole security dividend
  of holding backing in many places: spread the good, isolate the bad, and let any
  healthy venue stand in for a stricken one.

A single-vault protocol can only *detect* a problem and then suffer it.
Multi-vault lets the protocol **respond** — which is why the spread itself, not
any one venue's strength, is the safety. (Implementation detail:
`ETH-VENUES.md`, `VAULT-WATCHER.md`.)
