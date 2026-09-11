# TARGET DESIGN — the model, what is built, and what is still owed

> **CONSOLIDATED 2026-09-11.** This file had grown to 941 lines in session order, with five
> retractions layered over the sections they retract — §8 cancelled, §10's fork replaced by §12, §11
> rewritten, §14's fix withdrawn, §15 replacing the IL terms. **A reader could no longer extract the
> design from it.** Restructured into MODEL → STATE → OPEN → APPENDIX. Nothing is dropped: every
> retraction survives in Part IV, one line each, pointing at the commit that holds the detail.
>
> ⚠️ **THE CODE IS NOT THE AUTHORITY HERE. THE MODEL IS.** Owner, 2026-09-11: *"there is no guarantee
> that what is currently in the code represents that version of the model, but all the final roles
> must be checked against the code."* So: decide what is right, then check the code against it — never
> read the code and call agreement a resolution.
>
> **CONFIDENCE MARKS:** ✅ measured or read from code, with the site given · 🧠 reasoned, never
> measured — treat as hypothesis · ⏸️ blocked on a named check or an owner ruling · 🔴 a defect or a
> retraction.

---
---

# PART I — THE MODEL

## 1. The invariant everything serves (owner, verbatim)
> **"the invariant is conservation principle. lp preserve upside, basket depositors preserve dollar
> value."**

Two constituencies, opposite preferences, and neither may fund the other:
- **LPs** deposit volatile, want volatile exposure back. Their upside is preserved.
- **Basket depositors** deposit dollars, want dollar value back. Their dollar value is preserved.
- ⛔ **Neither subsidises the other.** This single rule kills more designs than any other in this
  document — it is why the basket may not buy volatile back for an LP (Part III, decision 2), and why
  a pooled IL basis is forbidden (§App-2).

## 2. What the product is, stated honestly
| claim | grade |
|---|---|
| **No slippage** | ✅ **STRUCTURAL.** Settlement is at the oracle, bounded by inventory — one price for the whole size. A CFMM's slippage is an artifact of its curve; we deleted the curve, so there is nothing to price away. |
| **No LVR** | ✅ **STRUCTURAL.** LVR is arbitrageurs exercising a free option against a stale published price. We publish none. |
| **No IL for a passive LP** | 🔧 **PURCHASED, NOT STRUCTURAL.** It costs either carry (the lever) or time (deferral). What IS structural is that ours is *smaller* than an AMM's, because the adverse-selection half is already gone. ⛔ **Do not claim it as a property of the architecture.** |

## 3. What IL actually is here (owner's correction, 2026-09-11)
**It is three quantities, and conflating them is how the old design went wrong:**
1. **REALISED, per LP** — fixed only at EXIT, a function of BOTH endpoints. Two LPs leaving the same
   day with different entries realise different numbers.
2. **INSTANTANEOUS, per LP** — every open LP carries an unrealised gap against what it would have held
   since ITS OWN entry. A distribution across the book, never a scalar.
3. **PATH-DEPENDENT** — it round-trips. Which is why the down side is deliberately unhedged: it heals,
   and hedging it realises a loss while forfeiting the recovery.

⇒ **The pool does not have "an IL". It has one per LP per instant**, and only an exit collapses one
into a number.

## 4. Where our IL comes from — and it is not adverse selection
✅ `Quid._pricingBacking()`: an LP's claim is `rangeETH` **plus its USD leg converted back to ETH at
TODAY's oracle**. Deposit 100 ETH at $2,000; a drain sells 50 for $100,000; price doubles; the claim is
`50 + 100,000/4,000` = **75 ETH** against 100 held.

That gap is **pure inventory risk** — we sold at an honest price and the price moved after. No arb
picked us off. It is the residue that survives deleting the curve.

## 5. The charge — a flat 420 ppm
✅ `wellSkew`/`sellSkew` both return `MIN_SWAP_SKEW_WAD`. The scarcity kernel is deleted.

**§NO-GAMEABLE-BOUND, the rule that produced this** (owner: *"anything that can be gamed is
useless"*): no charge and no safety bound may derive from observed flow, because the counterparty
being priced sets observed flow. Two vectors were measured, not imagined:
- **patience** — stop trading, let the 48h flow EWMA decay, and the target shrinks toward the
  inventory you mean to drain;
- **clock-stretching** — space one drain's slices 4h apart, σ² falls ~24× and the charge with it, for
  the same total size.

A constant cannot be starved, so both become *unconstructible* rather than defended against.
⚠️ **The level is a calibration and must stay current:** it has to exceed adverse selection over the
settlement window and stay under the competing venue's all-in cost. If that band ever closes, this
stops being a constant question.

## 6. The deferral primitive — ONE mechanism, both directions
> **The pool owes you `X` of asset `A` and holds less than `X`. It issues a DATED CLAIM on `A`, and
> pays you what `A` EARNS while it is undelivered.**

The asset keeps working; its yield compensates the wait. Nothing forecast, nothing borrowed, and the
protocol's cost is zero — it pays out yield it would not otherwise have owed.

| | asset | dated? | paid for the wait? |
|---|---|---|---|
| ✅ QU!D vintages — `Basket.mint(…, when)` | dollars | `when` | `calcMintYield`: `yield × months` |
| ✅ the offramp's last rung — `waitNft` → ether.fi | volatile | the NFT's queue | eETH staking yield |
| 🔴 `usd_owed` — `Quid.sol:543/822/974` | dollars | **no** | **nothing** |

**`usd_owed` is the outlier** and the collapse is to fold it into the vintage ledger. Its own docblock
says *"strictly conservative, no mint"* — right about supply, wrong about the LP, who is lending the
protocol money for free.

⭐ **THE ORDERING, taken from the volatile side, which already had it right.** `offrampBody` tries
**Curve first** and falls to the dated claim only when that cannot serve. So:
> **Try to serve NOW. Defer only when serving now is worse FOR THE COUNTERPARTY than waiting.**

That makes deferral something the counterparty *wants*, not something the pool imposes — which is what
*"defer should be opt-in"* actually requires.

## 7. The hedge — drift, not price
🔴 **Both of the old design's IL terms are CFMM laws, and we deleted the CFMM:**
- ✅ `soldFractionWad` is **a constant, 0.507500313** (`LevMath.sol:170-187`). The range recentres on
  spot every repack, so the triple is always `(P(1−d), P, P(1+d))` and **P cancels**. Measured over a
  rally that DOUBLED the price it returned `0.500750000312500535` at every step, while real inventory
  fell 7.566 → 2.331 ETH. *"It reports a 50.075% hedge at open, at +100%, and the same on the way
  down."* **This is the 50:50 assumption, hardcoded by the algebra.**
- ✅ `ilTargetBps = 1 − √(entry/now)` is the constant-product composition law — a statement about a
  curve.

Both describe a pool whose composition is a function of **price**. Ours is a function of **flow**: we
sell volatile when someone buys it, not when the price moves.

### The replacement, which needs no price at all
```
drift_i  =  entryEquity_i  −  (shares_i / lpShares) · rangeETH        // volatile units, per LP
```
- ✅ `entryEquity_i` is already stored (`Types.Pos.entryEquity`, *"the IL base, FIXED at open"*).
- ✅ **Automatically correct for entry time.** At entry the two terms are equal by construction, so
  drift starts at 0 and accrues only from sales AFTER that LP joined — Part I §3's quantity 2, per LP,
  with no new state.
- ✅ **A round trip self-cancels.** Drain then equal sell-in returns `rangeETH`, drift returns to 0,
  no hedge and no carry. The old formula would have hedged on the price move alone.
- ✅ **The mechanism is verified:** `Quid.sol:526/529` moves `LP.pooled` and `lpShares` **together and
  only on deposit/withdraw**, so no swap touches a per-LP slot ⇒ `shares_i/lpShares` is constant
  across swaps while `rangeETH` falls when the pool sells. Drift tracks sales-since-entry exactly.

**KEPT from the old design:** up-side only (hedge `drift > 0` only — negative drift means the LP holds
MORE than it deposited, and selling that realises a loss that heals); the per-LP basis fixed at open;
the cap as a safety bound.

## 8. The two questions a swap raises, and their answers
**Serving is what CREATES the exposure**, so these are independent, not a chain.

| | question | answer |
|---|---|---|
| **Q1 — swapper-facing** | how do we pay them? | **Quote both and let them pick.** Serve-now is oracle + 420 ppm *plus any sourcing it forces*; deferred is oracle + 420 ppm *minus* the forward yield they earn. The protocol publishes two prices; it does not choose. Seam: `Aux.quoteSwapOut`. |
| **Q2 — LP-facing** | what restores the delta? | **Incoming flow first — free and self-cancelling.** The lever covers only the residue, sized off drift *at the moment of action*. Flow arriving between actions nets it down at no cost, and claiming that is not a forecast — nothing happened in between. |

⇒ **The lever is a RESIDUAL instrument**, and that falls out of drift-based sizing rather than being
imposed: if flow cleared the drift, `drift_i` is already 0 and there is nothing to lever.

## 9. When the keeper acts — a realised-cost accumulator
Owner, 2026-09-11: *"we should not be making forecasts at all."* A no-trade **band** assumes a size; a
**dwell** assumes a reversal. Both are forecasts.
> **Act when the carry ALREADY PAID on the excess debt exceeds the round trip it would cost to fix it.**

Backward-looking, no timer, no σ, no reversal assumption. The arithmetic that produced it:
`Δ·carry·T > roundtrip·Δ` ⇒ **`Δ` cancels** ⇒ a pure time condition, ~14 days at today's carry. That
figure is an OUTPUT of the rule, not a constant to set.
📌 Gas is the one cost that does NOT scale with `Δ`, which is why it yields a minimum SIZE instead —
`min_rebalance_usd`, which already exists. This is the owner's *"gas has nothing to do with lvr"*,
derived rather than asserted.

## 10. What hedging costs — corrected
✅ Carry is **NET**: gross 4.30%/yr minus the weETH ratchet the collateral earns while posted
(**+2.46%/yr**, `LevManager.sol:189`) = **183 bps/yr**. And the borrow is sized by the IL fraction,
not the book.

| price move since entry | hedge as % of equity | net carry / TVL | turnover to break even |
|---|---|---|---|
| ×1.10 | 4.7% | 0.086% | **2.0× / yr** |
| ×1.20 | 8.7% | 0.160% | **3.8× / yr** |
| ×1.50 | 18.4% | 0.338% | **8.0× / yr** |
| ×2.00 | 29.3% | 0.539% | **12.8× / yr** |

⚠️ **The SHAPE is the point: the cost rises with the rally** — cheapest when it matters least, dearest
exactly when the LP is most exposed. That is the argument for preferring deferral (zero carry, settles
in kind) whenever flow will clear it, and for leverage being the third choice.

## 11. Why leverage at all
Not my choice — the owner's, on market impact: *"why are we buying anything back … we would be
incurring huge slippage on external venues by moving our entire tvl. we should use leverage instead."*
That is a reason to reject BUY-BACK. The structural reason leverage is the right replacement:
> **After serving a drain the pool must be TWO things at once — holding dollars as inventory for the
> other direction, AND long volatile for the LP. One pot of capital cannot be both.**

⚠️ Limits stated with it: it REDUCES market impact rather than avoiding it (it still buys, at IL size);
it costs carry; and it is not the only instrument.

---
---

# PART II — STATE: WHAT IS BUILT, WHAT IS NOT

### ✅ Built and verified
| piece | evidence |
|---|---|
| Oracle settlement, no curve | §V4-CUT. One price for the whole size. |
| The flat 420 ppm, credited to LPs | `wellSkew`/`sellSkew`; `retainSkewPremium`; `SkewPremiumReachesLPs.t.sol` asserts the credit arrives. |
| No gameable bound on the charge | every EWMA, variance register and θ consumer greps to comments only. |
| One pooled venue position | `repayPool`/`withdrawPool`, `poolLtvBps`, `totalDeliverableDollars`. |
| Per-LP targeting inside it | `debtUnits[lp]`/`collUnits[lp]`, `repay(lp)`/`withdraw(lp)`, `debtDeltaToTarget(lp)` — O(1), exact, no aggregate needed. |
| The redeem-side de-lever | `BasketLib._deleverBookForRedeem` → `deleverBook` → `deleverToVault`. |
| The **drain**-side absorption | `QuidLib.sendEth` → `SwapLib.deleverEthOnDelivery` → repay pool debt → `withdrawPool` → deliver. A swap-out that exceeds inventory DOES de-lever to serve itself. |
| The deferral ledger | `Basket.mint(…, when)`, `calcMintYield`, `balanceOf[holder][when]`, `matureSupply()`. |

### 🔴 Not built
| piece | state |
|---|---|
| **Drift-based hedging** (Part I §7) | `_targetInputs` still calls `ilTargetBps(ilBasisPx, px)`. Needs a per-LP shares read reachable from `LevBase` — does not exist on the ETH side. |
| **`when` chosen from inventory** on the sell-in path | every swap-side mint passes a flat value. This is the whole of §12's feature. |
| **The tenor quoted** before the swapper commits | seam exists (`Aux.quoteSwapOut`); nothing populates it. |
| **`usd_owed` folded into the vintage ledger** | Part III decision 3. |
| **A keeper-callable pooled de-lever** | `deleverToVault` is RANGE-gated; the keeper holds the book position-by-position via `rebalance(lp)`. |
| **The competitive-ceiling assertion** | nothing falsifies *"our cost ≤ theirs at every size we serve"*. |
| **The multi-venue allocator** | owner-deferred; Part III decision 4. |

---
---

# PART III — OPEN DECISIONS (owner rulings)

1. **The observation source.** ✅ Measured: `setObservationSource` has zero non-test callers, so
   `_observeIfSourced` feeds the ring from the **Chainlink anchor** and `twapResolve` then checks it
   against **Chainlink**. It fires on staleness and cannot fire on manipulation. §E222's
   independent-source rule had two consumers and σ² was one; deleting σ² leaves the guard holding it
   alone. ⇒ Pin a genuinely independent source, or name Chainlink the trust root and delete the ring.
   ⛔ 1inch is not callable on chain — measured at **31.7M gas**, past a whole block.
2. **Who funds the drift when flow does not reverse.** The basket is forbidden (Part I §1). So: carry
   (the lever) or time (deferral). This is the §14 question and it is the design's central cost.
3. **`usd_owed` → a QU!D vintage.** ⚠️ It **mints** where today it deliberately does not, consuming
   supply-cap headroom. A silent unpaid IOU becomes a supply-capped yield-bearing one — better for the
   LP, more honest in the accounting, and not free.
4. **The borrow split.** ✅ Measured: $100M on USDC alone is **7.51%** (it crosses the kink);
   $50M+$50M across the two Aave venues blends to **~4.37%** — **−314 bps ≈ $3.1M/yr**. ⚠️ Splitting
   kills the CLIFF, not the FLOOR: the ~4.3% base is the market's price and no allocation moves it, so
   the benefit is zero until a leg nears its own kink. ⛔ Allocate by equalising MARGINAL rates, never
   by `borrowRateRay(0)` — RLUSD is the **cheapest of four at +$5k (394 bps)** and unfundable at $25M.
   🔴 Blocked by ONE deliberate line, `LevBase:384-385` `revert VenueNotPooled()` — and lifting it is
   not a one-line change, because four call sites resolve *the* venue via singular `poolVenue` and the
   right choice differs between a repay and a withdraw. **That routing decision is the allocator's
   real body; the rate maths is the easy half.**
5. **The competitive ceiling, unmeasured.** The ~17 bps round trip used in Part I §9 is quoted, not
   measured on our own rebalance path. One piece of work closes this and the ceiling assertion.
6. **Turnover.** Part I §10's break-even needs our actual volume-to-levered-notional ratio. Unmeasured,
   and it decides whether protocol-level hedging is self-funding or a subsidy.

---
---

# PART IV — APPENDIX: THE RETRACTION RECORD

Kept because the wrong turns are cheaper to inherit than to rediscover. One line each; the commit holds
the detail.

| # | I claimed | why it was wrong |
|---|---|---|
| 1 | **§8: a pooled delta target gates every removal** (`b958840a`, cancelled `75ad3c40`) | I invented the problem. Nothing sums targets — `grep totalTarget\|sumTarget\|aggregateTarget` = **0**. Per-LP units, per-LP actuation and an O(1) exact per-LP target all already exist inside the one pooled position. |
| 2 | **Bucket `ilBasisPx` into tiers — exact, no cross-subsidy** (retracted `7ed982af`) | Not exact. Both clamps split the book at thresholds that MOVE with price, so the boundary bucket is always partly in and partly out. |
| 3 | **The A/B/C sell-in fork** (retracted `46e72041`) | All three treat a sell-in as something that must be FUNDED NOW. `Basket.mint(…, when)` already exists. |
| 4 | **"Value the USD leg at the price it was created at"** (retracted `fde4ae77`) | A POOL-level basis belonging to no LP — option (b) again, four sections after I rejected it. |
| 5 | **"A swap does not touch the lever"** (corrected `fde4ae77`) | Grepped `SwapLib` and `Core.swap` only. The DRAIN half is wired through `QuidLib.sendEth`. |
| 6 | **Break-even ≈ 102×/yr, "twice a week"** (corrected `28dc7065`) | Wrong by ~25×: costed carry on 100% of equity instead of the IL fraction, and used the GROSS rate instead of netting the +2.46% ratchet. |
| 7 | **"The two Morpho venues are decorative — exclude them"** (retracted `6248d660`) | The ladder started at $1M and I concluded about every size below it. RLUSD is the **cheapest of four** for the first ~$30k. **A ladder's floor is a measurement boundary, not a starting point.** |
| 8 | **"Serve → defer → lever"** (corrected `2d769a6d`) | Wrong in shape. Serving is what CREATES the exposure; they are two independent questions, not a chain. |
| 9 | **A carry-derived band, then a dwell** (corrected `94a31819`, `46e72041`) | A dwell is itself a forecast — it waits because the move MIGHT reverse. |
| 10 | **`retainedEthPremium` is "a counter nothing reads"** (retracted `3e9e343d`) | Measured against `evm/src` only. `LevYbReal.t.sol:577` pins the conservation identity with it. |
| 11 | **Classifying SPRINT rows by symbol-count / topic-density** (owner, 2026-09-11) | **Shortcut inference twice over.** "7 of 10 symbols gone" says a row CITES dead code; it says nothing about whether what it ASKS FOR still matters — and those are the rows most likely to be load-bearing, because the code moved out from under a need that was never served. The method is: READ the rows, RECONCILE them against each other, test against the MODEL, then check the model against code. |
