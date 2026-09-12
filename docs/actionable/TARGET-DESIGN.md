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

# PART 0 — THE ASSUMPTIONS AND GOALS, RESTATED — **AND A CORRECTION TO §7 THAT I GOT BACKWARDS** (2026-09-11)

Owner: *"per lp opt in drift hedge doesnt seem right. restate the assumptions and design goals based on
everything you know. how do you know we designed this right."*

## 🔴 0a. THE CORRECTION FIRST — **OPT-IN IS WRONG, AND THE WAY I REACHED IT IS WORSE THAN THE ANSWER**
I answered *"who funds the drift"* by reading `LevManager.openLev` (`external`, gated on `msg.sender`)
and reporting **what the code does** as **what the design says**. ⛔ **This document's own header forbids
exactly that:** *"THE CODE IS NOT THE AUTHORITY HERE. THE MODEL IS… there is no guarantee that what is
currently in the code represents that version of the model."* I broke the first rule in the file, in the
file, while answering a question about the file.

**And opt-in contradicts the product in three independent ways:**
| | |
|---|---|
| 1 | §2 claims **"no IL for a PASSIVE LP."** An opt-in hedge is precisely the one a passive LP does not get. **The claim fails for the exact population it names** |
| 2 | Opt-in requires the LP to understand drift, monitor it, and act. That is a position manager, not **"a yield-bearing market-making vault"** (§PLP-U). The product's own positioning rules it out |
| 3 | Opt-in + a pooled venue means **sophisticated LPs hedge and passive LPs carry their liquidation risk** — measured at 4,801 bps. **That is §1 violated**, and I wrote the measurement myself without noticing it refuted the mechanism I had just endorsed |

✅ **THE RESOLUTION, AND IT NEEDS NO NEW PRIMITIVE: THE HEDGE IS AUTOMATIC, SIZED PER LP, AND CHARGED PER
LP.** *Automatic* is what makes the passive claim true; *per-LP charged* is what keeps §1 intact. They are
not in tension — the thing that made them look mutually exclusive was treating "who pays" and "who acts"
as one question.
📌 **Buildable from what already exists**, measured: `positionOf(lp)` slices **debt** by `debtUnits[lp]`
(`LevVenueBase.sol:36-41`), so **carry is already attributed per-LP** — an LP's slice of pool interest
grows with its own units. And `rebalance(address lp, …)` (`LevManager.sol:94`) **already takes an LP
argument**: the keeper already acts *for* an LP rather than being called *by* it. ⇒ **the system is
already automatic after opening. Only the OPENING is opt-in**, and an LP's collateral is already weETH in
the venue, so there is nothing it must bring that it has not already deposited.

---

## 🔴🔴🔴 0a-bis. **THE ADVERSE-SELECTION MEASUREMENT — THE CHARGE IS ~10× TOO SMALL, AND IT REFUTES TWO CLAIMS IN THIS DOCUMENT** (2026-09-11)

Owner: *"measure the adverse selection."* **Run, on live mainnet data, not reasoned.**

**METHOD.** Our settlement price is `AUX.getTWAPforAsset(ASSET, TWAP_WINDOW_SECS)` with
**`TWAP_WINDOW_SECS = 1800`** (`Interfaces.sol:76`) — a **30-minute TWAP** — and the ring is fed from the
Chainlink anchor (`_observeIfSourced`), so the ring's cadence *is* Chainlink's. Pulled **150 consecutive
Chainlink ETH/USD rounds** (`0x5f4eC3Df…`, 8-dec) = **103.1 hours**, \$2,490.29 → \$2,544.80, and
reconstructed the 1800s TWAP at each observation to compare against spot.

| | median | mean | p90 | max |
|---|---:|---:|---:|---:|
| **gap between feed updates** | **55.0 min** | — | — | 61.0 min |
| **\|move\| between consecutive updates** (ppm) | **5,058** | 4,145 | 6,326 | 15,976 |
| 🔴 **\|spot − our 1800s TWAP\|** (ppm) | **4,209** | 5,611 | 10,452 | **43,402** |

### ⛔ AGAINST THE 420 ppm CHARGE
| | |
|---|---|
| deviations **exceeding** the charge | **135 of 149 — 90% of the time** |
| **median deviation ÷ charge** | 🔴 **10.0×** |
| worst observed | **103×** |

⇒ **THE FLOOR IS NOT CLEARED. IT IS MISSED BY AN ORDER OF MAGNITUDE**, and §5's own validity condition —
*"the charge must exceed adverse selection over the settlement window"* — is **false as the system is
configured today.** The update gap's median of 55 minutes says why: the **1-hour heartbeat dominates and
the 0.5% deviation trigger rarely fires**, so the feed is routinely ~0.5% stale before it moves at all,
and a 30-minute TWAP of a 55-minute-stale feed is staler still.

### 🔴 THIS REFUTES TWO CLAIMS THIS DOCUMENT MAKES — **the self-contradictions the owner asked for**
| § | the claim | why the measurement refutes it |
|---|---|---|
| **§2** | *"**No LVR** — ✅ **STRUCTURAL.** LVR is arbitrageurs exercising a free option against a stale published price. **We publish none.**"* | 🔴 **We publish one.** Settling at a 1800s TWAP of a public feed means **the counterparty can compute our settlement price exactly**, ahead of time, and compare it to the market. That is the free option, and it is worth a **median 4,209 ppm**. Not publishing a *quote* is not the same as not publishing a *price* |
| **§4** | *"Where our IL comes from — **and it is not adverse selection** … we sold at an **honest price** and the price moved after. **No arb picked us off.**"* | 🔴 The price was **0.42% stale at the median** when we sold. *"The price moved after"* describes the 10% of fills where the deviation was below the charge. For the other 90%, **the move had already happened and we had not seen it** |

⭐ **AND THE ONE THING THAT IS GENUINELY STRUCTURAL MAKES IT WORSE, NOT BETTER.** §2's *"no slippage —
one price for the whole size"* is true and is the product. **Against a stale price it is also an
unbounded-size free option**: a CFMM's curve at least prices an arb out of the trade as size grows;
ours does not. **Our defence is inventory alone.**

### ▶️ WHAT THIS DOES AND DOES NOT ESTABLISH — stated so nobody over-reads it
✅ **Established:** the settlement price is stale by ~10× the charge, ~90% of the time, on 103h of real
ETH data at the real window.
⛔ **NOT established:** that this loss is *realised*. A deviation is an **opportunity**, not a fill —
someone has to take it, and our inventory bounds the size. **The measurement is the upper bound of what
the charge must cover, not a P&L.**
⚠️ **But the asymmetry is the point, and it is not a modelling choice:** the deviation is symmetric,
**the counterparty's choice of side is not.** Informed flow takes the profitable side every time;
uninformed flow is a coin flip. ⇒ **we eat the tail and split the middle**, which is exactly why a
charge must exceed the deviation rather than average it.

### 🪦 0a-ter. **THE TWAP MACHINERY IS THE STALENESS. DELETE IT** (owner, 2026-09-11: *"we dont need twap machinery anymore? what for?"*)

**The right question, and the measurement above already answers it — I should have drawn the conclusion
myself instead of listing "shorten the window" as one remedy among four.**

🔴 **THE RING IS A TIME-SERIES OF CHAINLINK READS, VALIDATED AGAINST CHAINLINK.** Traced, not inferred:
`Core._observeIfSourced` (`:297`) branches on `observationSource`, **and nothing ever sets it** —
`setObservationSource` has **1 reference in `src` (its own declaration)** and **no deploy-script caller**.
So the live branch is `src == address(0)`, which calls
`SwapLib.twapResolve(AUX.assetPriceFeed(ASSET), 0, …)` — **a Chainlink read** — and writes it into the
ring. `getTWAPforAsset` then averages the ring over 1800s, and `twapResolve` checks that average against
**the same feed** with a 500 bps cap.
⇒ **INPUT = CHAINLINK. CHECK = CHAINLINK.** You cannot detect manipulation of a source by comparing a
time-average of it against itself. **The TWAP buys zero manipulation resistance**, which is the only
reason a TWAP ever exists.

### 📊 AND ITS COST IS MEASURED, NOT ESTIMATED — because in the dataset above "spot" IS the feed
| \|Chainlink(t) − TWAP₁₈₀₀(Chainlink)(t)\| | median | mean | p90 | max |
|---|---:|---:|---:|---:|
| ppm | **4,209** | 5,611 | 10,452 | 43,402 |
| **× the 420 ppm charge** | **10.0×** | | | |
| observations where the TWAP ALONE exceeds the charge | **135 / 149** | | | |
⇒ **nothing but the averaging contributes to that number.** It is not market staleness, not oracle lag,
not adverse selection from outside — **it is self-inflicted, it is a median 10× the charge, and reading
the anchor directly removes all of it.** The anchor read already exists and is already on this path.

### ✅ SO PART III DECISION 1 IS ANSWERED BY DELETION, AND THE OWNER JUST CHOSE IT
That decision read: *"Pin a genuinely independent source, **or name Chainlink the trust root and delete
the ring**."* ⇒ **the second.** And it is the §NO-GAMEABLE-BOUND move a fourth time: we do not tune the
window, we **delete the measurement that only ever added lag.**

▶️ **THE DELETION SURFACE, measured** — `getTWAPforAsset` 27 src / **102 test** · `RING` 10/7 ·
`obsState` 5/9 · `TWAP_WINDOW_SECS` 5/0 · `twapResolve` 3/12 · `_writeObservationPrice` 3/0 ·
`observationSource` 4/0 · `OBS_CALLDATA` 3/0 · `TWAP_MAX_DEVIATION_BPS` 2/0 · `twapBody` 2/0 ·
`setObservationSource` 1/1. **The 102 test references are the real cost of this change**, and
§THE-SUITE-DID-NOT-NOTICE says what they are worth: they were written against machinery that provably
cannot do the job its name claims.
⚠️ **WHAT SURVIVES: `twapResolve`'s FRESHNESS AND DEVIATION LOGIC, which is the only part that was ever
load-bearing.** It rejects a stale feed (`maxAge`) and a feed that disagrees with itself. Deleting the
ring keeps that check and drops the averaging — ⛔ **do not delete `twapResolve` with the ring; retarget
it at the direct read.**

🔴 **AND WHAT THIS DOES NOT FIX, SO THE HEADLINE NUMBER IS NOT MISREAD:** after the deletion the
settlement price is Chainlink's latest, and **Chainlink's own staleness against the true market remains
— bounded by its 0.5% deviation trigger and 1-hour heartbeat, and UNMEASURED here** because measuring it
needs an independent price source this repo does not have. ⇒ **deleting the TWAP removes the half that is
ours. The other half is the anchor's, and it is why the deviation guard and the faster anchor stay on the
list below.**

### ⏸️ REMEDIES — NAMED, NOT CHOSEN, because each needs its own measurement
1. **Shorten the window.** 1800s of a 55-minute-updating feed is mostly *lag on lag*. A shorter window
   cannot beat the feed's own cadence, so this is bounded by the anchor, not by us.
2. **Raise the charge** toward the measured deviation. ⛔ But 420 ppm was chosen to be **ungameable**, and
   ~4,200 ppm is a *different product* — 0.42% a side is not a competitive swap venue.
3. **A deviation guard** — refuse to fill when spot and the anchor disagree by more than X. This is
   Part III decision 1, and it is the only remedy that does not trade the charge against the window.
4. **A faster anchor.** The binding constraint is Chainlink's 1-hour heartbeat, not our TWAP.
🔴 **THIS OUTRANKS BUILDING THE HEDGE.** The hedge addresses inventory drift; **this is mispricing at the
moment of fill, and no hedge repairs it.** ⇒ it is the top open item in the file.

## 🔴 0a-quater. **IS THE DESIGN COMPLETE? NO — AND ONE GAP GOT HARDER TODAY, NOT EASIER** (owner, 2026-09-11)

**Measured against the code, not read off this document.**

### 1. THE MECHANISM IS SETTLED AND MOSTLY UNBUILT
| piece | in code today |
|---|---|
| ✅ the flat charge | `MIN_SWAP_SKEW_WAD` **4 refs**; `wellSkew`/`sellSkew` deleted |
| ✅ the TWAP is gone | `anchorPrice18` **2**, `assetPrice` **28**, ring **0** |
| ✅ deferral, 2 of 3 legs | `calcMintYield` **3**, `waitNft` **2** |
| 🔴 the third leg | `usd_owed` **13 refs** — still the unpaid IOU, not folded into the vintage ledger |
| 🔴🔴 **drift itself** | `drift_i` / `driftOf` = **ZERO**. `entryEquity` exists (**13**) but nothing computes drift from it |
| 🔴 the formula drift replaces | `_ilTargetLive` **3**, `ilTargetBps` **2** — still live |
| 🔴 §7c's deletion | `_shortfallLoadBalance` **3**, `onShortfall` **4**, `proRataShortfall` **1** |
| 🔴 the two-price seam (§8) | `quoteSwapOut` **1 ref** — a stub |
| 🔴 automatic per-LP hedging | `openLev` is still `msg.sender`-gated opt-in (Part 0a) |
⇒ **the charge and the oracle are built; the HEDGE is not, and it is the product.**

### 2. 🔴🔴 THE CENTRAL ECONOMIC QUESTION IS OPEN, AND TODAY ONLY REMOVED OUR HALF OF IT
Deleting the TWAP removed a **measured median 4,209 ppm** of self-inflicted staleness. **It did not fix
adverse selection.** Chainlink's own staleness survives and is measured: **median 55.0 min between
updates, median 5,058 ppm of price move across that gap.**
⇒ **an informed trader still captures up to ~0.5% against a 0.042% charge.** The floor §5 names as the
charge's only surviving validity condition is **still not cleared.**

### 3. ⛔ AND THE REMEDY GOT HARDER: **WE NOW HAVE EXACTLY ONE PRICE SOURCE**
Part III decision 1's deviation guard compared the ring-TWAP against Chainlink. **That comparison was
circular** — the ring was built FROM Chainlink — which is why the ring is gone and the deletion was
right. But measured just now: `curvePriceWad` and `oneInchRateWad` have **ZERO callers in `evm/src`**.
| source | state |
|---|---|
| Chainlink (`assetPriceFeed`, 8 refs) | ✅ the only live one |
| Curve `curvePriceWad` | declared, **0 callers** — booked UNWIRED-ON-PURPOSE |
| 1inch `oneInchRateWad` | declared, **0 callers** — and **31,722,803 gas, past a whole block** |
⇒ **a deviation guard is no longer a rewiring. It requires building a second source**, and the only
independent one in the tree is not callable on chain. **We have one number, no way to check it, and a
charge an order of magnitude under what it must cover.**

### ▶️ SO WHAT "COMPLETE" WOULD REQUIRE, IN ORDER
1. 🔴 **An answer to the pricing gap.** Not the hedge — the hedge addresses inventory drift, and this is
   mispricing at the moment of fill. Either a second source that is callable, a charge that clears the
   measured floor, or an explicit ruling that we accept the loss and size it.
2. Drift computed and the hedge automatic per-LP (§7 + Part 0a).
3. §7c and §7 landing as **one** change.
4. `usd_owed` folded into the vintage ledger (§6).
5. The two-price seam at `Aux.quoteSwapOut` (§8).
6. The realised-cost trigger (§9).
⚠️ **(1) IS NOT LAST AND IT IS NOT AN IMPLEMENTATION TASK.** Everything below it assumes a charge that
covers adverse selection. If that assumption is false the LP loses on every fill and no amount of
hedging repairs it — so this is the item that decides whether the rest is worth building.

## 🔑 0a-quinquies. **THE INFERENCE IS BACKWARDS — AND REDSTONE PULL IS THE FIRST REMEDY WE CONTROL** (owner, 2026-09-11)

### ⛔ FIRST, A CORRECTION: *"no serious on-chain trader will use this venue because of the 55 min gap"*
**The opposite. They will use it, and that is the problem.**
| who | what they see |
|---|---|
| **an UNINFORMED trader** (wants to move size, no view on price) | **0.042% flat, no slippage, any size, settled at an unbiased oracle.** Against a CFMM that charges the curve on size, this is an excellent venue. Staleness is symmetric noise to them — as often in their favour as against |
| 🔴 **an INFORMED trader** (sees the real market) | a **stale price, a 420 ppm toll, unbounded size, and no slippage.** That is the ideal arbitrage target |
⇒ **the venue is not unattractive. It is TOO attractive, and it selects for the wrong population.**
✅ **VERIFIED: nothing bounds a fill but inventory.** `Core._fillDelta` clamps `out` to `held` and does
nothing else — **no price band, no size cap, no per-block limit, no rate limit** — and `Core.swap` adds
no guard. One transaction can take the whole pooled side at the stale price.

⭐ **AND THE DEEPER POINT, WHICH IS NOT WRITTEN ANYWHERE ELSE: A CFMM'S CURVE DOES TWO JOBS AND WE ONLY
COUNTED ONE.** It prices, and it **rations** — an arb's profit shrinks as it takes size, so the curve is
an accidental defence against exactly this. We deleted the curve deliberately and correctly (it is what
buys "no slippage", the product's best property), **but the rationing went with it and nothing replaced
it.** ⇒ *"no slippage"* and *"exposed to informed flow at unbounded size"* are **the same fact**.
📌 **This is the ordinary market-maker problem, not a fatal flaw.** Every MM earns the spread from
uninformed flow and pays the informed. It survives iff `420 ppm × uninformed volume > staleness ×
informed volume` — ⇒ **decision 6 (turnover) is not a parameter, it is the other half of the viability
condition**, and it is unmeasured.

### ✅ REDSTONE — AND IT ANSWERS BOTH OPEN HALVES, WHICH NOTHING ELSE SO FAR HAS
📌 **Already in the tree, in the weakest mode:** `DeployL1_s.sol:788` pins a **Redstone
AggregatorV3** for cUSD/USD. So the integration pattern is present; it is simply not used for the asset
anchor.
| mode | what it gives us |
|---|---|
| **Redstone Classic (push)** — same `AggregatorV3` interface | a **SECOND independent source**, drop-in. ⇒ Part III decision 1's deviation guard stops being *"build a new source"* and becomes a rewiring. **This alone closes gap 3** |
| 🔑 **Redstone Core (pull)** — price signed by the oracle nodes, delivered **in the caller's calldata**, verified on-chain | **the counterparty brings a fresh price.** The 55-minute heartbeat gap is replaced by an **acceptance window we choose** |

⭐ **THE PULL MODEL'S PROPERTY IS EXACTLY THE ONE §NO-GAMEABLE-BOUND ASKS FOR.** The trader supplies the
input, and **cannot forge it** (node-signed) and **cannot stale it** (we bound the timestamp). What they
retain is the choice of *which* signed price inside the window — so adverse selection is not eliminated,
it is **compressed to the window's width, and the width is ours to set.**

| acceptance window | exposure | vs the 420 ppm charge |
|---|---:|---|
| today (Chainlink heartbeat, **MEASURED**) | **5,058 ppm** | 12× over |
| 3 min | ~1,181 ppm | over |
| 1 min | ~682 ppm | over |
| 30 s | ~482 ppm | marginal |
| **15 s** | **~341 ppm** | ✅ **under** |
⚠️ **ONLY THE FIRST ROW IS MEASURED. The rest assume √t scaling — a GBM assumption — and ETH at short
horizons is fatter-tailed than that.** Treat them as an order of magnitude, not a result.
▶️ **WHAT WOULD MEASURE THEM: a per-second ETH series, which Chainlink structurally cannot provide.**
That is the honest gap in the method, and it is the measurement to commission before choosing a window.

⛔ **THE COSTS, STATED RATHER THAN DISCOVERED:** a tight window reverts a trader whose transaction is
delayed by congestion — **liveness traded for staleness, and 15 s is roughly one block.** And pull
requires the CALLER to fetch and attach a signed payload, so it is a client change reaching the SPA and
the keeper, not a contract-only change.
⇒ **But it is the first remedy in this whole thread that is IN OUR CONTROL and does not change the
product.** Raising the charge to 4,200 ppm would be a different product; adding a venue we cannot call
on-chain is not an option; shortening a TWAP window we already deleted is not available. **Setting an
acceptance window is.**

## 🔑 0a-sexies. **WHY NO SLIPPAGE, AND WHAT MAKES IT SELF-CORRECTING** (owner, 2026-09-11)

> *"what is our reason for not needing slippage… how do we prevent this from being a source of unfair
> or extra expense. how is the mechanism self-correcting?"*

### 1. WHY WE DO NOT NEED SLIPPAGE — and the answer is only HALF of what slippage was doing
A CFMM's slippage is not a fee; **nobody receives it.** It is the geometry of walking `x·y = k`. And it
does **two** jobs:
| job | do we still need it? |
|---|---|
| **PRICE** the inventory risk of absorbing your order | ❌ **No.** We do not quote a curve — we sell from a book at an honest external price, and the risk is priced by the flat 420 ppm. This half is legitimately deleted, and it is what *"no slippage, one price for any size"* buys |
| 🔴 **RATION** — an arb's profit shrinks as it takes size, so no single trade can take everything | ✅ **YES, and nothing replaced it.** Verified: `Core._fillDelta` clamps to `held` and nothing else |
⇒ **the reason for not needing slippage covers the PRICING half only. We deleted both and accounted
for one.**

### 2. 🔴 HOW IS IT SELF-CORRECTING? **TODAY IT IS NOT, AND THAT IS THE HONEST ANSWER**
A CFMM is self-correcting by construction: drain it and the price it quotes **rises**, which
simultaneously compensates the pool, deters the next taker, and pays someone to replenish. **The price
signal IS the inventory signal.**
**Ours has no feedback at all.** We quote the oracle whether we hold 100% or 1% of the asset. Inventory
falls, nothing changes, and the next trader pays the same 420 ppm as the first. ⇒ **there is no
mechanism by which depletion makes replenishment attractive** — §PLP-T's *"not a mechanism, a hope."*
**That feedback is exactly what the skew was for, and we deleted it.**

### 3. ⭐ BUT IT CAN COME BACK, AND §NO-GAMEABLE-BOUND DOES NOT FORBID IT — THE DISCRIMINATOR IS SHARP
The rule is *"no charge may derive from OBSERVED FLOW, because the counterparty being priced sets
observed flow."* **The two attacks that produced it were both attacks on a TIME-AVERAGE:**
| attack | why it worked on the old kernel | does it work on INVENTORY LEVEL? |
|---|---|---|
| **patience** — stop trading, let the 48h EWMA decay | the target was a decaying average, so **waiting moved it for free** | ⛔ **No.** Waiting does not change what we hold. Only someone actually replenishing does — and if they do, **the mechanism worked** |
| **clock-stretching** — space the slices 4h apart, σ² falls ~24× | variance is measured per-interval, so **splitting shrank the input for free** | ⛔ **No.** Each slice lowers the level, so the next slice is charged more. **The total is the integral** — splitting buys nothing |
⇒ **THE REAL DISCRIMINATOR IS NOT "STATE vs FLOW". IT IS WHETHER THE COUNTERPARTY CAN MOVE THE INPUT
*WITHOUT PAYING*.** The flow EWMA and σ² were **free** to move — by waiting, or by spacing. **Inventory
level can only be moved by trading, and every unit of that trade pays the charge it is setting.**
**Gameable-only-by-paying is not gaming; it is the mechanism operating.**

### 4. ✅ AND THE OLD DOC'S "DEFECT" WAS THE RIGHT SHAPE, MISREAD
`SKEW-AND-REFILL.md` (deleted today) complained: *"the charge is close to nothing until the pool is
severely depleted — it behaves as a guard against being emptied rather than as a continuous incentive
to rebalance."* **That is not a defect. That is precisely the shape this design wants:**
- **flat and negligible across the normal band** ⇒ *"no slippage"* stays true for ordinary size, which
  is the product;
- **biting only as inventory approaches depletion** ⇒ rationing exactly where the free option lives.
⇒ **The SHAPE was right and the INPUT was wrong.** It keyed off *expected flow* — a gameable average —
when it should have keyed off *the level we actually hold*. **That is the whole correction**, and it is
why the fix is not "restore the kernel" but "re-key it."

### ▶️ SO THE ANSWER TO "UNFAIR OR EXTRA EXPENSE" IS A DESIGN CONSTRAINT, NOT A REASSURANCE
1. **Zero in the normal band.** An ordinary trade must pay 420 ppm and nothing else, or we have
   silently rebuilt an AMM and given up the one property that makes this venue worth using.
2. **Rising only near depletion**, so the cost falls on the trade that is *causing* the scarcity rather
   than on the one that follows it.
3. **A function of the level, never of a rate, an average, or a variance** — or patience and
   clock-stretching come back.
4. **Monotone in size within one transaction**, so splitting is never cheaper than not splitting.
⚠️ **AND THE FAIRNESS TEST IS THE INTEGRAL, NOT THE RATE:** a trader taking the pool from 90% to 10%
should pay materially more than eighty traders each taking 1% — ⛔ **no, the OPPOSITE: they should pay
the SAME**, because the integral is the same. If splitting is cheaper, clock-stretching is back; if
splitting is dearer, we are taxing ordinary flow to punish one trader. **Equality under splitting is
the property to test, and it is falsifiable.**
⏸️ **NOT DESIGNED, and deliberately not sketched further here** — the curve's form is a real piece of
work and the last one of these was wrong for two years. What is settled is the INPUT (level, not flow),
the SHAPE (flat then biting), and the TEST (equality under splitting).

## 🔴🔴 0a-septies. **BREAKING MY OWN ANSWER: THE INVENTORY SKEW DOES NOT FIX ADVERSE SELECTION** (2026-09-11)

Owner: *"keep asking sharp questions and trying to break the design you came up with."* **The first
thing to break is §0a-sexies, one section above, and it breaks cleanly.**

### ⛔ THE BREAK: I CONFLATED TWO DIFFERENT ATTACKS AND OFFERED ONE CURE
§0a-sexies proposes an inventory-keyed charge: **flat and negligible across the normal band, biting
only near depletion.** That shape is right *for depletion*. **It does nothing against the staleness
arb, and the staleness arb is the measured one.**

> ETH really moves +0.5%. Chainlink has not updated. Our inventory is at 50% — deep in the flat band,
> so the inventory charge is **≈0**. The arb buys at the stale price, pays **420 ppm**, and captures
> **~5,000 ppm.** They never approach depletion, so **nothing they do ever triggers the guard.**

⇒ **An arb does not need to drain us. They only need to take the size the mispricing justifies** — and
that size sits comfortably inside the band where I just argued the charge must be zero.

### 🔑 AND THAT EXPOSES WHAT A CFMM'S CURVE WAS ACTUALLY DEFENDING AGAINST
A CFMM's price is **stale between trades** — it is the last trade's price. Its curve is not primarily
a rationing device against depletion; **it is the defence against its own staleness.** The arb's
profit shrinks as they take size, so the mispricing is only partly extractable. **The curve and the
stale price are a matched pair.**
⇒ **WE REMOVED THE CURVE AND KEPT A STALE PRICE. That is the one combination that does not work**, and
it is the whole finding:

| price | curve | outcome |
|---|---|---|
| stale | curve | a CFMM. Works — the curve rations its own staleness |
| **fresh** | **no curve** | ✅ **our design, and it is coherent** — nothing to arb, so nothing to ration |
| stale | **no curve** | 🔴 **what is deployed today.** A free option at unbounded size |
| fresh | curve | over-charged; the curve prices a risk that is not there |

### ⭐ SO THE TWO REMEDIES ARE NOT ALTERNATIVES. BOTH ARE REQUIRED, AND THEY ADDRESS DIFFERENT ATTACKS
| remedy | kills | does NOT kill |
|---|---|---|
| **a fresh price** (Redstone pull, §0a-quinquies) | the staleness arb | depletion — you can still be emptied at a fair price |
| **an inventory-keyed skew** (§0a-sexies) | depletion; restores self-correction | the staleness arb — it is ≈0 exactly where the arb operates |
⇒ **Neither substitutes for the other, and I presented the second as if it were the answer. It is half.**

### 🔑 THE SENTENCE THIS ALL REDUCES TO, AND IT IS THE ONE TO CARRY
> **"No slippage" is a property that REQUIRES a fresh price. Against a stale price it is not a feature,
> it is a giveaway.**

⇒ **the freshness work is not one remedy among four. It is the PRECONDITION for the product's headline
claim.** Every argument in this document for deleting the curve is sound *only* in the fresh-price
column of that table. ⛔ **Do not ship "no slippage" on a 55-minute-old price.**

### ⚠️ AND A SECOND BREAK, SMALLER BUT REAL: DRIFT RETURNS TO ZERO WHILE VALUE IS DESTROYED
§7 claims *"a round trip self-cancels — drain then equal sell-in returns `rangeETH`, drift returns to 0,
no hedge and no carry."* **True, and it hides a loss.** Drain 50 ETH at \$2,000 (pool gains \$100k);
price doubles; a swapper sells 50 ETH back at \$4,000 (pool pays \$200k). `rangeETH` is restored, so
**drift is exactly 0 and the hedge correctly does nothing** — while the USD leg is down **\$100k.**
⇒ **drift measures the ASSET gap, never the VALUE gap.** That is §6b working as designed (exposure is
denominated in the asset), but it means **the LP's realised value loss on a round trip is invisible to
the instrument we chose to watch**, and no section currently says so.
📌 **Not necessarily a defect — it may be the correct division of labour** (the asset gap is the hedge's
job; the value gap is the charge's). ⛔ **But it is unstated, and "a round trip self-cancels" reads as
"nothing was lost," which is false.**

## 🔴 0a-octies. **TWO MORE BREAKS — §6's "cost is zero" is false, and the flat fee taxes the trade that helps us**

### 🔴 BREAK 3: **§6 CLAIMS DEFERRAL COSTS THE PROTOCOL NOTHING. IT DOES NOT COST *THE PROTOCOL* — IT COSTS THE LPs**
§6, verbatim: *"The asset keeps working; its yield compensates the wait. Nothing forecast, nothing
borrowed, **and the protocol's cost is zero — it pays out yield it would not otherwise have owed.**"*

**Follow the yield.** The pool owes you 10 ETH and cannot deliver. The 10 ETH is still in the pool,
still staked, still earning. We pay you that yield for the wait.
⇒ **but that yield was accruing to the LPs, whose asset it is.** Paying it to the waiter is a
**transfer from LP to counterparty**, not a free lunch. *"Yield it would not otherwise have owed"* is
true of the PROTOCOL as a legal entity and false of the people whose capital generates it.
📌 **It may still be the right trade** — the LP keeps the asset working for the book while the waiter
takes the carry, which is a defensible split. ⛔ **But §6 is the answer to "who funds the drift", and
answering it with "nobody, it is free" is exactly the shape this document keeps catching elsewhere.**
⇒ **the honest statement is: deferral moves the cost from the LP's PRINCIPAL to the LP's YIELD.** That
is a real improvement over selling inventory, and it is not zero.
⚠️ **And it composes badly with §1.** *"LPs preserve upside; neither constituency subsidises the
other."* A waiter being paid LP yield is the LP funding the counterparty's patience. Small, bounded,
probably acceptable — **but it is a subsidy, and §1 does not currently have an exception for it.**

### 🔴 BREAK 4: **A SYMMETRIC FLAT FEE TAXES THE TRADE THAT HEALS US AS HARD AS THE ONE THAT HURTS**
420 ppm is charged **in both directions**. But the pool's position is directional: when drift > 0 we
are short the asset, so **a buy makes it worse and a sell makes it better.** Charging both identically
means the flow we most want is priced exactly like the flow we least want.
📌 **This is not a new observation — it is `§A.64 step 2`'s requirement, already in `SPRINT.md` as
C2b:** *"a symmetric fee taxes the deposit that heals the basket as hard as the drain that hurts it."*
It was booked about the BASKET's redemption leg. **It applies to the SWAP identically and nobody
carried it across.**
⚠️ **AND IT IS THE SAME FIX AS §0a-sexies, WHICH IS WHY IT IS WORTH SAYING NOW:** a directional charge
keyed off **inventory level** is not flow-derived, so §NO-GAMEABLE-BOUND does not forbid it — the
discriminator established there is *can the counterparty move the input without paying*, and they
cannot move the level without trading.
⛔ **But per §0a-septies it still does not touch adverse selection**, so it is a third thing the design
wants and not a substitute for freshness. **Three separate jobs: freshness kills the arb, a level-keyed
charge rations depletion, and DIRECTION decides who pays it.**

### 🔴🔴 BREAK 5: **THE FEE ON THE VOLATILE LEG CREDITS USD THAT WAS NEVER RECEIVED — AND IT IS MONOTONE**
Traced through `retainFee` → `Core.recordFee`, both legs:
| leg | what the pool actually receives | what the ledger records |
|---|---|---|
| USD in (`nativeAmount = false`) | `premium` **USD** | `POOLED_USD += premium`. ✅ correct |
| 🔴 **volatile in** (`nativeAmount = true`) | `premium` of **VOLATILE** (`r.amount -= premium` on a volatile input) | `retainedNativeFee += premium` **and** `POOLED_USD += premium·px` |

⇒ **on the volatile leg the pool keeps VOLATILE and credits its USD ledger with the dollar equivalent.**
✅ **And the volatile it keeps is NOT in `POOLED`** — `LevYbReal.t.sol:577` states the invariant as
`POOLED + retainedNativeFee == rangeETH + levBuf`, i.e. you must ADD the counter back to balance.
⛔ **`retainedNativeFee` has ZERO consumers in `evm/src`** — a declaration, an increment, an interface
member, and tests. Nothing ever converts it, spends it, or nets it off.

**WHY IT MATTERS, and it is not the backing check:** `POOLED_USD` is an INVENTORY counter, not a claim
ledger — `_fillDelta` reads it as the bound on what we can pay out:
```
uint held = inputIsUsd ? (POOLED) : (POOLED_USD);
if (out > held) { out = held; … }
```
⇒ **the clamp that exists to stop us over-delivering USD is reading a number inflated by fees that
arrived as volatile**, and since the counter is described in its own test as *"a monotone wei counter"*,
**the overstatement accumulates and is never trued up.** Per swap it is 420 ppm; over the book's life it
is the integral of every volatile-in swap.

⚠️ **ONE HYPOTHESIS I HAD AND KILLED, recorded because a dismissal is a conclusion:** I expected this to
tighten `checkBacking` on every volatile-in swap, the mirror of §PARTIAL-TAKE. **It does not.**
`Core._rangeEquityUsd18` keys off **`basketUsd`**, and `recordFee` never touches `basketUsd` — only
`POOLED_USD`. So the committed figure is unaffected and the backing check is clean. **The defect is
confined to the delivery bound.**
⏸️ **NOT FULLY CLOSED:** whether the inflation is intended — `POOLED_USD` may be meant as "USD value
owed to LPs" rather than "USD held", in which case crediting the dollar value of a volatile fee is
coherent and the real defect is that `_fillDelta` uses a VALUE ledger as an INVENTORY bound. **Either
way one of the two readings is wrong, and the two sites disagree.** ▶️ Settle which by asking what
`drawPooledUsdBtc`'s `POOLED_USD -= usd6` means — it spends it like inventory.

### 🔴🔴 BREAK 6: **THE USD DEBIT IS CLAMPED TWICE, INDEPENDENTLY, AND THE SHORTFALL IS DISCARDED**
`Core._poolUsdInRange`, the debit branch:
```solidity
POOLED_USD -= Math.min(usdAmount, POOLED_USD);      // debits at most what we hold
uint b = basketUsd;
uint out_ = b < usdAmount ? b : usdAmount;          // clamped AGAIN, SEPARATELY
basketUsd = b - out_;
```
⇒ **the caller believes `usdAmount` left the range; the ledgers record whatever they happened to
hold.** If `usdAmount = 100` and `POOLED_USD = 60`, sixty is debited and **forty is silently
forgotten** — the range then looks forty richer than it is.
🔑 **AND THE TWO CLAMPS ARE INDEPENDENT, which is the part that is worse than a single truncation:**
`POOLED_USD` is bounded by itself and `basketUsd` by itself, so one can absorb the full amount while
the other truncates. **The two ledgers can diverge from each other as well as from the caller's intent.**

⚠️ **REACHABILITY, stated at the confidence I have:** on the SWAP path it cannot bind — `_fillDelta`
already clamps `out` to `held = POOLED_USD`. But `modLP` (`:151`) and `settleOor` (`:157`) reach
`_handleDelta` with a **caller-supplied `usdDelta` that no inventory bound has touched**. ⛔ I have not
proven either caller can exceed `POOLED_USD`, so this is *"unbounded by construction at that site"*,
not *"exploitable today"*.
📌 **Either way it is a finding, and rule 18④ is why:** what is the worst input that still satisfies
this guard? **If the clamp can never bind it is decorative and should assert instead; if it can bind it
is a silent loss.** A guard cannot be both live and never-firing — and today nobody knows which it is.
⭐ **This is §PARTIAL-TAKE's defect in mirror image, found the same day.** There the range was debited
in FULL while the recipient received less. Here the range is debited LESS than the amount claimed.
**Both are clamps that convert a divergence into silence**, and that is now the third instance of the
class (`take`'s discarded return, `anchorPrice18`'s `(0, true)`, and this).

### 🔴 AND A RETRACTION: **BREAK 5's DISMISSAL WAS WRONG. THE FEE INFLATION *DOES* REACH THE BACKING CHECK**
One section above I wrote: *"I expected this to tighten `checkBacking`… It does not. `_rangeEquityUsd18`
keys off `basketUsd`, and `recordFee` never touches `basketUsd`."* **That was checked one level too
shallow.**
`Core.absorbPaidUsd` (`:254`), live and called from `Quid.sol:328`:
```solidity
uint pooled = POOLED_USD;
basketUsd = pooled > lpOwned6 ? pooled - lpOwned6 : 0;   // basketUsd is OVERWRITTEN *FROM* POOLED_USD
```
⇒ **`basketUsd` is not independent of `POOLED_USD` — it is periodically re-derived from it.** So the
volatile-leg fee inflation in `POOLED_USD` propagates into `basketUsd` at the next `absorbPaidUsd`, and
`basketUsd` is exactly what feeds `_rangeEquityUsd18` → `_reportEquity` → `committedTotal`.
**The inflation reaches the backing figure. It just takes one hop.**
📌 **RECORDED AS A RETRACTION RATHER THAN EDITED AWAY**, because the failure is the instructive part:
*"recordFee never touches basketUsd"* was **true and irrelevant** — I checked who WRITES the variable
and not who DERIVES it. **Grep the assignments, not just the mentions**, and this repo has a rule for
it: *when two identities separate, grep the ASSIGNMENTS.*

### 🔴🔴🔴 BREAK 7: **ONE STALE ORACLE, THREE SURFACES — AND THE EXIT DOOR IS THE CHEAPEST TO ATTACK**
Every one of these reads the same `AUX.assetPrice(...)`:
| surface | site | what staleness does |
|---|---|---|
| **swap pricing** | `Core.swap:176` | the arb measured at §0a-bis. Needs a second venue to close the loop |
| 🔴 **LP EXIT valuation** | `Quid._pricingBacking:702` via `_wethTwap` | **needs no second venue at all** |
| **hedge sizing** | `LevBase:37/171/220/225/245` | the borrow is sized off a stale price, so the hedge is systematically mis-sized in the direction the market has already moved |

**THE EXIT ATTACK, and it is cheaper than the swap one.** An LP's claim is
`rangeETH + (usd6 − base6)·1e12 / px`. The USD surplus is converted to the asset **at `px`** — so a
**LOW** `px` hands the exiter **MORE** of the asset.
> ETH really rises. Chainlink has not updated, so `px` is stale-low. An LP exits: their USD leg
> converts at the stale-low price, they take more ETH than their share is worth, **and the remaining
> LPs fund it.**

⭐ **WHY IT IS WORSE THAN THE SWAP ARB DESPITE BEING SMALLER PER EVENT:** the swap arb must sell the
asset somewhere else to realise the gain — they carry execution risk and pay a second venue's costs.
**The exiting LP does not. They just leave.** No counter-leg, no slippage elsewhere, no inventory risk.
⚠️ **AND IT COMPOUNDS WITH §E313 AT THE SAME DOOR.** The first-out advantage (measured 15.2 bps) and
the stale-conversion advantage are **independent and additive**, and both are collected by being early.
⇒ **exit ordering is not one problem with two descriptions; it is two problems sharing a door.**

📌 **THE FRAMING THAT MATTERS MORE THAN ANY SINGLE BREAK:** the staleness is not "a swap-pricing
issue." **It is one defect reaching three surfaces**, and the remedies proposed so far only address the
first. A fresh price (§0a-quinquies) fixes **all three at once**, which is a second and independent
argument for it — it is the only remedy in this document with that property.

### 🔴 BREAK 8: **THE FEE ACCUMULATOR TRUNCATES TO ZERO, AND IT TRUNCATES EXACTLY THE RETAIL BAND**
`Core.recordFee` → `RANGE.creditFee(premium6)` → `SwapLib.feeIncrements`:
```solidity
usdInc = SoladyMath.fullMulDiv(usd_fees, WAD, totalShares);   // totalShares = lpShares + totalBuffer
```
`fullMulDiv` **floors**. `lpShares` is ETH in wei, `premium6` is 6-dec USD ⇒ `usdInc == 0` for every
fee below `(lpShares + totalBuffer) / 1e18`, and **the fee's whole contribution to the accumulator
vanishes** — not rounded down by a wei, gone.

| pool | fee that truncates to 0 | ⇒ at the flat 420 ppm, a trade under |
|---|---|---|
| 1,000 ETH | $0.001 | $2 |
| 10,000 ETH | $0.010 | $24 |
| 100,000 ETH | $0.100 | **$238** |
| 1,000,000 ETH | $1.000 | **$2,381** |

⭐ **THE PART THAT MAKES IT A DESIGN FINDING RATHER THAN A ROUNDING BUG: THE THRESHOLD SCALES WITH
THE POOL.** The bigger the venue gets, the wider the band of trades whose fee never reaches an LP
accumulator. **Success moves the cutoff up.**

⚠️ **AND IT INTERACTS WITH §FLAT-FEE IN THE DIRECTION NOBODY CHOSE.** §NO-GAMEABLE-BOUND made the
charge size-blind on purpose. **The ATTRIBUTION is size-sensitive anyway**, through the accumulator,
and nothing in the design says so. A small trader pays exactly the same 420 ppm and is the most likely
to have it truncate.

✅ **BUT PRICE IT HONESTLY — THIS IS A REDIRECTION, NOT A THEFT, AND THE DIFFERENCE IS THE WHOLE
CALIBRATION.** The dollars are **not destroyed**: `Core.recordFee` still does `POOLED_USD += premiumUsd`,
and (§BREAK-6) `absorbPaidUsd` derives `basketUsd` from `POOLED_USD`, so the money reaches LP claims
through **backing** instead of through `pendingFor`. The two routes differ in exactly one way:
> the accumulator pays **the LPs who were present when the trade happened** (that is what
> `refreshBookmarks` checkpointing buys). Backing pays **everyone holding at exit, including whoever
> joined afterwards.**
⇒ **the leak is the slice that flows to later joiners**, which is small for a stable membership and
grows with churn. ⛔ **Do not write this up as stolen fees.** It is the deposit-front-running windfall
that the checkpoint mechanism exists to prevent — arriving through **truncation**, past the defence,
because the defence guards the bookmark and not the increment.

📌 **AND IT HAS A SILENT SIBLING ONE LINE UP, SAME FUNCTION:** `if (totalShares == 0) return (0, 0)`.
A fee arriving at an empty pool is credited to `POOLED_USD` and `feesRetained` and recorded by **no**
accumulator at all, with no revert and no event. Rule 3's shape: the failure announces nothing.

### ⚠️ CORRECTION TO BREAK 8 — **BOTH SURFACES WERE ALREADY BOOKED, BY A TEST, AND I DID NOT LOOK FIRST**
`test/SkewPremiumReachesLPs.t.sol`'s own header names them, in order, as *"TWO LEAK SURFACES THIS IS
BUILT TO EXPOSE, both in `feeIncrements`"* — the zero-denominator branch (*"Charged, never paid"*) and
*"`usdInc = premium6 * WAD / totalShares` truncates, so a remainder can be stranded."* ⇒ **BREAK 8's
observation is not a discovery; its MAGNITUDE is.** Rule 13 in the other direction: I should have
grepped the symbol before writing the finding.

🔴 **AND WHAT THE MAGNITUDE ACTUALLY SHOWS IS WORSE THAN THE FINDING I THOUGHT I HAD — THE TEST'S
TOLERANCE IS EXACTLY THE SIZE OF THE DEFECT IT IS MEANT TO BOUND:**
```solidity
assertLe(shortfall, denomNow / 1e18 + 1, "LEAK: more than truncation dust failed to reach LPs");
```
`denomNow / 1e18` **is the truncation quantum**, the same number BREAK 8's table computes. So the
assertion permits a shortfall of one whole quantum — **$0.10 per fee event on a 100,000 ETH pool,
$1.00 on a 1,000,000 ETH pool** — and calls it *dust*. ⇒ **it cannot fail from truncation at any pool
size, because the bound grows with the pool at exactly the rate the defect does.** §VACUOUS-BOUNDS,
arriving through a tolerance rather than through a one-sided comparison.
⚠️ **The one guard that WOULD bite (`assertGt(credited, 0, …)`) is never exercised on a small trade**:
the test drains `40_000e18` twenty times, so `charged` is enormous and `credited` is comfortably
non-zero. **The whole retail band the table describes is outside what this test ever runs.**
✅ **AND THE TEST IS NOT BAD WORK — it is the honest kind.** It named the surface, asserted the
zero-denominator half as a pure unit test, and wrote down that its premise *is* the leak surface. The
defect is that a number nobody re-derived — `denomNow / 1e18` — was labelled *dust* and never priced.
**Price every tolerance; a tolerance is a constant a guard consumes, and rule 18 ④ applies to it.**

### 🔴🔴 BREAK 9: **`feesPerShare` — THE NATIVE FEE ACCUMULATOR — CAN NEVER BE NON-ZERO**
Not truncated. Not small. **Structurally zero, by a census of every writer in `src/`:**
| writer | what it contributes |
|---|---|
| `Quid.creditFee:587` / `Vault.creditFee:101` | `SwapLib.feeIncrements(**0**, premium6, …)` — the token leg is a LITERAL ZERO at both sites, and there is no third caller |
| `Quid.sol:620` / `Vault.sol:151` | `feesPerShare += o.feesPerShareInc` |
| `Quid.sol:416` / `Vault.sol:210` | `feesPerShare = 0` (reset) |

⭐ **AND `feesPerShareInc` IS ASSIGNED NOWHERE.** It is *declared* twice — `QuidLib.RebalOut:95`,
`BtcLib.RebalOut:233` — and `rebalanceBody` assigns `newBookmark`, `venueFeesPerShareInc`,
`setLastRepack`, `reseatBump`, `spotPrice`, `loPrice`, `upPrice`, `myLiquidity`, `anchorPrice`, **and no
fee field**; `SwapLib.Rebalanced` has no fee field to source one from. A memory struct zero-initialises
⇒ **both `+=` are provably `+= 0`.** (`usdFeesInc` is dead the same way; `USD_FEES` survives only
because `creditFee` feeds it separately.)

⇒ **EVERYTHING DOWNSTREAM IS DEAD ARITHMETIC:** `pendingFor`'s `tokOwed`/`tokReward`,
`refreshBookmarks`'s `LP.fees_tok` write, and `feeIncrements`'s entire `fees`/`tokInc` half. A whole
accumulator pipeline that can only ever produce zero — and nothing in the tree says so.

🔑 **THE DESIGN CONSEQUENCE, AND IT IS BREAK 8 AT 100% INSTEAD OF AT THE MARGIN.** The native premium is
**not** zero: `LevYbReal.t.sol:629` asserts its own premise, `assertGt(CORE.retainedNativeFee(), 0,
"CONTROL: sells must retain a native premium")`, and `:635` pins the conserved identity
`POOLED − rangeETH − levBuf + retainedNativeFee`. So the ETH is real, it moves into **`rangeETH`**, and
it reaches LPs **only through backing**.
> ⇒ **every dollar of NATIVE fee bypasses the checkpointed accumulator entirely.** BREAK 8's redirection
> to later joiners is a truncation remainder; this is the **whole leg, by construction**. An LP who
> deposits one block after a large sell shares in a premium earned before they arrived — which is
> precisely what `refreshBookmarks` exists to prevent, and the defence is bypassed rather than beaten.

📌 **REMOVAL (owner: *"removal is the policy"*) — booked, not done, because a suite is in flight and
rule 10 caps one money-path change per run:** `feesPerShareInc` ×2 declarations, `usdFeesInc` ×2, the
two `+=` statements, `feeIncrements`'s `fees` parameter and `tokInc` return, `pendingFor`'s
`tokOwed`/`tokReward`, `Types.Deposit.fees_tok`, and `refreshBookmarks`'s `tokAccum` argument.
⚠️ **`feesPerShare` itself is `public` on `Shares` and read by `BtcLib` ×3 — deleting it is a bytecode
change needing a build, a size measurement and its own run.** Do not fold it into anything else.
⛔ **AND DECIDE THE DESIGN QUESTION BEFORE DELETING:** if the native leg is *supposed* to be
checkpointed, the fix is to FEED this accumulator, not to remove it — the pipeline is the shape of an
intention nobody wired. **Deleting it resolves an open design question by deletion, which this repo has
ruled out before.**

### 🔴🔴🔴 BREAK 10: **THE VENUE-FEE BOOKMARK IS A ONE-WAY RATCHET, AND PRICE VOLATILITY ALONE DRIVES IT**
`QuidLib.rebalanceBody`, the venue-yield block:
```solidity
uint current = _venueBalanceLib(c.ev, c.aux);
if (plainDepth == 0) { o.newBookmark = current; }
else {
    if (c.bookmark > 0 && current > c.bookmark)                       // credit ONLY on a rise
        o.venueFeesPerShareInc = fullMulDiv(current - c.bookmark, WAD, plainDepth);
    o.newBookmark = current;                                          // ⬅ but ratchet ALWAYS
}
```
⭐ **THE CREDIT IS CONDITIONAL AND THE BOOKMARK IS NOT.** A fall writes the lower value down with no
debit; the next rise from that trough is then paid out **in full, as yield**. Over any round trip the
venue's real value is unchanged and `venueFeesPerShare` has ratcheted **up by the whole down-leg**.

🔑 **AND THE QUANTITY IS NOT A VENUE BALANCE — IT IS A VENUE BALANCE MINUS THE LEVERED BOOK, PRICED AT
THE ORACLE**, which is what turns a rare drawdown into a continuous pump:
```
_venueBalanceLib = IEthVenue.rangeOp(0,2)  −  ILevEquity.totalNetEquity()
LevBase.totalNetEquity → LevMath.netEquityBase(coll, debtUsd, AUX.assetPrice(ORACLE_KEY))
netEquityBase        → debtBase = debtUsd·WAD/price;  return collBase − debtBase
```
**Verified by reading the body, not inferred from the name** — the sign is the whole finding:
| ETH price | `debtBase` | `totalNetEquity` | `current` | what the block does |
|---|---|---|---|---|
| **↓** | ↑ | **↓** | **↑** | 🔴 **credits the whole move as venue YIELD** |
| **↑** | ↓ | ↑ | ↓ | ratchets the bookmark down, **silently, no debit** |

⇒ **EVERY DOWNWARD PRICE MOVE IS DISTRIBUTED TO PLAIN LPs AS YIELD; EVERY UPWARD MOVE IS ABSORBED.**
`venueFeesPerShare` is **monotone non-decreasing by construction** and rises with **volatility**, not
with earnings. A price that ends where it started has still paid out every down-tick along the way.
⚠️ **Opening or closing a levered position does it too**, without any price move: an open raises
`totalNetEquity` (bookmark ratchets down, silent), the matching close lowers it (**paid out as yield**).
⚠️ **And the `total > n ? total − n : 0` clamp sharpens it**: once the levered book exceeds the venue
balance, `current` pins at 0, and the entire recovery off that floor is credited.

💸 **WHO FUNDS IT — THE PAYOUT MINTS SHARES.** `_pendingFor` adds `venueOwed − venueBm[user]` to
`tokReward`; `_settlePending` does `_creditShares(LP, tokR)` ⇒ `LP.pooled += tokR; lpShares += tokR`.
**No asset arrives.** The claim is satisfied by dilution ⇒ **a transfer from every other LP to whoever
holds the oldest `venueBm` checkpoint.** Long-standing LPs extract from newer ones, funded by
oscillation rather than by yield.
⛔ **AND THE CHECKPOINT IS NOT THE DEFENCE HERE, THOUGH IT LOOKS LIKE ONE.** `venueBm` *is* set on
deposit and transfer (`QuidLib:142`, `Quid:250`), so a joiner cannot claim past accrual — I checked,
and that half is sound. **It does not help**, because the accumulator does not rise when the loss
happens; it rises on the recovery. A depositor who enters at the trough is checkpointed **below** the
credit they are about to receive for a drawdown they never bore. ⇒ **buy the dip, collect the rebound
as a fee, leave.** Constructible with no oracle staleness and no second venue.

📌 **THIS IS ALSO BREAK 7's FOURTH SURFACE.** `totalNetEquity` reads `AUX.assetPrice(ORACLE_KEY)`, so
the same stale anchor now reaches **swap pricing, LP exit valuation, hedge sizing, and the venue-fee
ratchet** — and here staleness does not merely mis-price, it **mis-times which side of the ratchet
fires.**

⚠️ **STATED AT THE CONFIDENCE I HAVE.** I verified the four bodies above by reading them and the sign of
`netEquityBase` explicitly, because the whole finding turns on it. **I have NOT measured the magnitude
in a fixture** — that is the next step, and it is a premise-asserting test: drive the price down and
back up with a levered book open, assert the venue balance returns to its start, and assert
`venueFeesPerShare` **did not move**. It will.

### 🔴🔴🔴 BREAK 11: **`_onExit` HAS TWO CALLERS. ONLY ONE PAYS `usd_owed`. THE OTHER DELETES IT.**
Not a redirection like BREAKS 8-10 — **a claim is destroyed.**

**The withdraw path (`Quid.sol:399`) pays first, then exits:**
```solidity
if (LP.pooled == 0 && LP.usd_owed > 0) { uint owed = LP.usd_owed; LP.usd_owed = 0; _mintQuid(recipient, owed); }
_onExit(LP, msg.sender);
```
**The reconcile path (`Quid._doReconcile:441-453`) has no such guard, and its ORDER is the defect:**
```solidity
_settlePending(LP, lp, address(0));     // :446  mintRecipient == 0  ⇒  LP.usd_owed += usdR   (:279)
… QuidLib.reconcileLegs(…)              // :447  burnedNet can take LP.pooled to ZERO
_onExit(LP, lp);                        // :453  pooled == 0  ⇒  delete autoManaged[lp]
```
`Types.Deposit` is `{ pooled, usd_owed, fees_tok, fees_usd }` (`Types.sol:50-54`), so **`delete` zeroes
`usd_owed` along with the rest.** ⇒ the accrual is booked at `:446` and erased at `:453`, seven lines
later, **with no revert, no event and no payout.**

⭐ **AND THE ORDER IS NOT INCIDENTAL — IT IS WHAT MAKES THE LOSS REACHABLE.** `_settlePending` opens
`if (LP.pooled == 0) return;`, so a position already at zero accrues nothing and loses nothing. **The
loss requires `pooled > 0` at `:446` and `pooled == 0` at `:453` — exactly what `reconcileLegs` does in
between.** A full delever or a liquidation that burns an LP's whole plain position is the trigger, which
is **precisely the moment the LP most needs the fees they had already earned.**

🔑 **THE CLASS IS THE ONE THIS TREE KEEPS PRODUCING: TWO CALLERS OF ONE EXIT, ONE GUARD.** §THE-MERGE
found four declaration/use splits the same way. The guard lives at the CALL SITE instead of inside
`_onExit`, so adding a second caller silently opts out of it — and nothing in the signature says a
caller owes a payout first.
▶️ **THE ROOT FIX, per rule 17 — and it makes the previous fix DELETABLE rather than adding a second
one:** move the settle-and-pay inside `_onExit`, so no call site can forget. The `:399` block then
deletes. ⛔ **Do NOT add the same guard to `_doReconcile`** — that is the clamp, it is the second patch
for one class, and rule 18's worked example is this exact shape.

⚠️ **WHAT I HAVE NOT ESTABLISHED:** whether `reconcileLegs` can in practice drive `pooled` to zero while
`usdR > 0` on the same call. The code permits it; I have not built the fixture. **Booked as the test
that settles it, and it is a premise-asserting one** — assert `usd_owed > 0` after `:446` and
`pooled == 0` after `:447` as the PREMISE, before asserting the balance is gone. Without those two the
test proves nothing, which is how §VACUOUS-BOUNDS is born.

### ✅ AND ONE SHARPENING OF BREAK 10, which BREAK 9 supplies for free
BREAK 9 establishes `feesPerShare` is structurally zero, so `pendingFor`'s `tokReward` is always 0.
`_pendingFor` then returns `tokReward = 0 + (venueOwed − venueBm[user])`. ⇒ **100% of every `tokReward`
payout in this system is the venue ratchet**, and every one of them mints shares against no asset. The
ratchet is not *a* source of the token-fee leg. **It is the only one.**

### 🔴🔴🔴 BREAK 12: **`syncLev` IS UNGATED — WHICH MAKES BREAKS 10 AND 11 PERMISSIONLESS, ON A VICTIM YOU PICK**
```solidity
function syncLev(address lp) external { _reconcileLev(lp); }      // Quid.sol:429 — no modifier at all
```
**No `onlyUs`, no `onlyKeeper`, no `msg.sender == lp`.** Anyone may force a reconcile on any LP whose
recorded legs have drifted from their live position (`_reconcileLev` returns early only when they
already agree). ⇒ **two findings that read as accounting defects become reachable attacks.**

**① BREAK 11 BECOMES A GRIEF WITH A NAMED TARGET.** `_doReconcile` accrues `usd_owed` at `:446` and
`_onExit` deletes it at `:453` when `reconcileLegs` takes `pooled` to zero. With `syncLev` open, **the
attacker chooses whose fees get erased, and chooses when.** They gain nothing — the claim is destroyed,
not transferred — so it is griefing rather than theft, **and that makes it cheap, not harmless.**

**② BREAK 10 BECOMES A PUMP YOU CAN RUN ON DEMAND, AND THE CONTRAST IS THE PROOF IT IS AN OVERSIGHT.**
`_depositImpl`'s **last line** is `bookmark = _venueBalance();` — deliberately, because a deposit raises
the venue balance and **must not be read as yield.** `_doReconcile` does the opposite:
```solidity
(p.spotPrice, …) = _rebalance();          // :445  sets bookmark to the PRE-reconcile value
_settlePending(LP, lp, address(0));       // :446
QuidLib.reconcileLegs(…);                 // :447  MOVES the levered book ⇒ moves totalNetEquity
lpShares = …; totalLevPooled = …;         // :450-452
_onExit(LP, lp);                          // :453  refreshes venueBm[user]; NEVER the global bookmark
```
⇒ **the reconcile changes `totalNetEquity` and leaves `bookmark` stale.** A delever lowers
`totalNetEquity`, so `current = venueBal − n` **rises**, and the next `_rebalance()` credits that rise as
**venue yield** — minting shares (BREAK 10) against no asset. **Open leverage, close it, call
`syncLev`: repeatable, no price move required, no waiting for volatility.**
⚠️ **And the extractor need not be the LP they sync.** They hold a plain position with an old `venueBm`,
run the open/close/`syncLev` cycle from a second address, and claim the pump as the plain LP.

🔑 **THE CLASS, AND IT IS NOW THREE-FOR-THREE: THE SECOND CALLER OF A SHARED PATH SKIPS THE DISCIPLINE
THE FIRST ONE CARRIES.**
| # | first caller, correct | second caller, missing it |
|---|---|---|
| **11** | `Quid:399` pays `usd_owed` before `_onExit` | `_doReconcile:453` does not |
| **12** | `_depositImpl`'s last line re-seats `bookmark` | `_doReconcile` never does |
| §MERGE | — | four declaration/use splits, same shape |
⇒ **THE FIX IS THE SAME ONE IN EVERY ROW AND IT IS RULE 17'S: MOVE THE DISCIPLINE INSIDE THE SHARED
CALLEE SO NO CALL SITE CAN FORGET.** Settle-and-pay belongs in `_onExit`; re-seating `bookmark` belongs
wherever the levered book is written. **Both then DELETE the call-site copy** rather than adding a
second one. ⛔ **Patching `_doReconcile` twice is the clamp, and it is rule 18's worked example verbatim.**
📌 **`syncLev`'s own gate is a separate question and probably should stay open** — a keeper needs it, and
§POOL-VENUE wants reconciliation permissionless. **The defect is not that it is callable; it is that
being callable is currently enough to erase someone's fees and mint yourself shares.** Fix the two
callees, and the open entrypoint becomes harmless.

### ✅ AND A SECOND HYPOTHESIS CLEARED — the deposit path does checkpoint in the right ORDER
I expected the classic: checkpoint before crediting, so a joiner's `venueBm` is computed on a stale
(zero) stake and they then claim the whole historical accumulator. **`_depositImpl` does it the right
way round:** `_creditShares(LP, deltaETH)` **then** `_refreshBookmarks(pledge, …)` (`Quid:483-485`, and
again at `:488-490` for the unpaired leg), so `venueBm[user] = plainNet(NEW pooled)·venueFeesPerShare`
and `venueOwed − venueBm == 0` immediately after joining. **A joiner is owed nothing retroactively on the
venue leg either.** ⇒ credit-then-checkpoint is correct and deliberate; the attack is unconstructible.

### 🔑 BREAKS 9-11 CHECKED AGAINST THE BTC MIRROR — **AND THE MIRROR SETTLES BREAK 11**
The two ranges are one implementation in two instances, so every finding on the ETH leg has an
obligation to be checked on the BTC leg. **All three, measured:**
| break | BTC leg | evidence |
|---|---|---|
| **9** — `feesPerShare` can never be non-zero | 🔴 **SAME DEFECT** | `BtcLib.rebalanceBody` assigns `spotPrice`, `loPrice`, `upPrice`, `myLiquidity`, `anchorPrice` — **and no fee field**, so `Vault.sol:151`'s `feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc;` is `+= 0` twice over. `Vault.creditFee:101` passes a literal `0` for the token leg, exactly as `Quid` does. ⇒ **`feesPerShare` is structurally zero on BOTH instances**; on BTC, `USD_FEES` is fed only by `creditFee` |
| **10** — the venue-fee ratchet | ✅ **DOES NOT EXIST THERE** | `venueFeesPerShare` and `venueBm` have **zero occurrences** in `Vault.sol` and `BtcLib.sol`. The ratchet is ETH-venue-only, so its blast radius is one instance |
| **11** — `usd_owed` deleted unpaid | ✅ **THE BTC LEG DOES IT RIGHT** | `resizeBtcLpTail:83` calls `settleBtcLp(LP, **a.lpEth**, quid, …)` — `payTo` is the LP, **non-zero** — *before* `delete autoManaged[a.lpEth]` at `:103`. So `settleBtcLp` takes the `payTo != address(0)` branch: `usdR += LP.usd_owed; LP.usd_owed = 0; IBasket(quid).mint(payTo, …)`. **The claim is PAID** |

⭐ **THAT LAST ROW IS THE STRONGEST EVIDENCE BREAK 11 IS A DEFECT AND NOT A DESIGN CHOICE.** The BTC
range, doing the same job through the same `Types.Deposit`, **settles-and-pays inside the shared callee,
before the delete — which is exactly the root fix rule 17 prescribes for the ETH side.** ⇒ **the two
instances disagree, and the BTC one is correct.** The fix is not a design decision anyone has to make;
it is **copying the shape that already exists one file over**, and it deletes `Quid:399`'s call-site
copy rather than adding a second.

⚠️ **AND I NEARLY BOOKED THE BTC LEG AS BROKEN TOO — the near-miss is the reusable part.** I read
`resizeBtcLpTail` from `:90`, saw `delete autoManaged[a.lpEth]` with no settle anywhere in view, and was
composing the finding. **The settle is at `:83`, seven lines above the window I had read.** ⇒ **READ THE
WHOLE FUNCTION, NOT THE WINDOW AROUND THE SYMBOL YOU GREPPED.** Same class as this repo's *"read the
docblock, not the diff"* — a grep centres you on the symbol, and the discipline that governs it is
usually **above** the centre. **A finding derived from a window is unverified until the window is the
function.**

### ✅ §7540-STYLE — **OWNER RULING, 2026-09-11: *"stylism is still nice."*** ⇒ **TAKE THE VOCABULARY,
### DO NOT CLAIM THE INTERFACE.** The analysis below stands on the ECONOMICS and is overruled on the
### AESTHETICS, which is the owner's call. **And the ruling is cheap to honour, because measured: the
### async physics already forced the two function names that matter.**
| 7540 name | state in `evm/src` | cost to adopt |
|---|---|---|
| `requestDeposit` | ✅ **ALREADY EXISTS** — `Vault.sol:156` (+ `BtcLib:142`, `Interfaces:404`) | **0** |
| `requestRedeem` | ✅ **ALREADY EXISTS** — `Vault.sol:184` (+ `Interfaces:405`) | **0** |
| the pending-request state | ✅ **ALREADY EXISTS** — `Core.pendingSwapOutUsd` (`Core.sol:48`), `BTCChannels.requestSwapOutOnchain:787` | **0** |
| `pendingRedeemRequest` / `claimableRedeemRequest` | ⬜ thin views over the state above | 2 views |
| `pendingDepositRequest` / `claimableDepositRequest` | ⬜ thin views over channel-funding state | 2 views |
| `setOperator` / `isOperator` | ⬜ **and independently worth having** — the keeper must claim for a user | 2, needed anyway |
| 🔴 `supportsInterface` | ⛔ **DO NOT ADD** | see below |

⇒ **THE STYLE IS ~60% FREE AND THE REST IS FOUR THIN VIEWS PLUS AN OPERATOR PAIR WE WANT REGARDLESS.**
That is a completely different price from the ~8-function conformance I costed against, and at that
price the owner's preference is simply correct: **a reader who knows 7540 reads our BTC leg without
learning our names, and it costs almost nothing.**

⛔ **THE ONE LINE NOT TO CROSS, AND IT IS THE SAME MISTAKE AS §PHANTOM-REDEEM ONE LAYER UP: DO NOT
DECLARE `supportsInterface` FOR 7540.** Looking like 7540 is free and honest. **Returning `true` for its
interface ID is a CLAIM**, and an integrator who reads that claim is entitled to full semantics we do
not have (the complete async 4626 base, exact two-phase claim behaviour). ⇒ **`redeemVBtc` emits an event
asserting a payout it cannot make; `supportsInterface` would assert an interface we do not implement.
Same class, ABI level, and the blast radius is every integrator instead of every indexer.**
📌 **THE DISCRIMINATOR, reusable: USE A STANDARD'S NAMES WHERE THE SEMANTICS GENUINELY MATCH; ADVERTISE
ITS INTERFACE ID ONLY WHEN ALL OF THEM DO.** Naming is documentation. `supportsInterface` is a promise.

### (the economic analysis, unchanged and still the reason not to go further than the above)
### 🔑 §NO-7540 — **DOES ERC-7540 BUY US ANYTHING BUT STYLISM? NO.** (owner's question, 2026-09-11)
**First, the state, because the question presumes a conformance we do not have: `7540` and `7575` have
ZERO occurrences in `evm/src`.** Every `IERC4626` in the tree is us **consuming someone else's** vault
(`FeeLib`, `ChannelLib`, `QuidLib` reading yield venues) plus `Quid`'s own `_deposit4626`/`_mint4626`.
**The BTC leg does not implement 7540 today.** It is an aspiration, not a fact to preserve.

⭐ **THE ONLY MATERIAL THING A TOKEN STANDARD CAN BUY IS THIRD-PARTY ACCEPTANCE — AND THE ACCEPTANCE WE
ACTUALLY WANT IS NOT GATED ON THE INTERFACE.** The prize would be a money market taking the share token
as collateral, because that is the one thing that would let a BTC depositor fund an IL hedge out of the
position itself (§NO-BTC-IL-HEDGE below). **It does not work that way:**
| venue | what it actually requires |
|---|---|
| **Morpho** | any **ERC-20** plus an **oracle**. It does not call `supportsInterface` |
| **Aave v4** (the owner's stated borrow venue) | a **governance decision on a specific asset**. Interface conformance is not an input to that vote |
⇒ the three real prerequisites are **an ERC-20 face** (`VBtc` already has one), **a price**, and **a
liquidation exit that actually pays**. **7540 supplies none of the three.**

💸 **AND THE COST IS THE BINDING CONSTRAINT IN THIS TREE, NOT AN ABSTRACTION.** Conformance means
`pendingDepositRequest`, `claimableDepositRequest`, `requestRedeem`, `pendingRedeemRequest`,
`claimableRedeemRequest`, `setOperator`, `isOperator`, `supportsInterface` — **~8 `external` functions,
each a dispatch-table entry AND bytecode**, on a contract in a fleet whose tightest member has run to
**102 bytes** of EIP-170 headroom. **Rule 23: do not create a function unless the job is impossible
without it.** A conformance function is by construction one the job does not need.

⛔ **AND THE DEEPEST OBJECTION IS THAT WE HAVE ALREADY REJECTED THE STANDARD'S CENTRAL ABSTRACTION.**
§VBTC-IS-THE-SHARES (owner, 2026-09-09): *"there really is no `asset()` and shares dichotomy in the 4626
sense. **the token is the shares.**"* 7540 is async **4626**; it is built on that dichotomy. ⇒ **adopting
it would mean conforming to a standard whose core abstraction our own design denies, which is the
definition of stylism.**

✅ **THE ONE PART WORTH TAKING, AND TAKE THE PATTERN NOT THE STANDARD:** 7540's **operator/controller**
idea — a keeper claiming on a user's behalf — is genuinely needed, because the BTC leg's settlement is
asynchronous by **physics** (a channel funding confirms on Bitcoin; an exit is delivered on Bitcoin).
**That is 1-2 functions we would write anyway, not 8.** The async SHAPE is forced on us; the async
STANDARD is not.

### 🔴🔴 §PHANTOM-REDEEM — **`redeemVBtc` CANNOT PAY ANYONE, AND IT EMITS AN EVENT SAYING IT DID**
The owner: *"there is no redeem really just swapout."* **Confirmed in code, and it is worse than unwired:**
```solidity
function redeemVBtc(uint sats, bytes32 p2trKey) external returns (bool) {      // VBtc.sol:61
    if (!BitcoinTx.isValidXOnlyKey(p2trKey)) revert BadPayoutKey();            // :62  validated…
    IVBtcRange(VAULT).redeemVBtc(msg.sender, sats);                            // :63  …and NOT passed
    emit Redeemed(msg.sender, sats, BitcoinTx.buildTaprootScriptPubKey(p2trKey));   // :65  only use
}
```
`Vault.redeemVBtc(address holder, uint sats)` **takes no script**, and its body is
`_resize(holder, sats, sats, false, 0)` — **a share burn and a range resize. No Bitcoin leaves.**
⇒ **`p2trKey` is validated, dropped, and then announced in an event as the payout destination.** **No
sats can ever reach that address through this function.** ⛔ **The event is the hazard: an indexer or a
client reading `Redeemed(holder, sats, script)` will conclude a payout occurred to that script.** Same
class as §VACUOUS-TEST — the NAME and the EVENT assert the property; the body does not have it.
▶️ **REMOVAL IS THE POLICY AND THIS IS THE CLEAN CASE: delete both faces** (`VBtc.redeemVBtc`,
`Vault.redeemVBtc`, the `IVBtcRange`/`Interfaces` member, `Redeemed`, `BadPayoutKey`) **and let swap-out
be the single BTC exit for everyone.** That also answers the collateral question honestly rather than
leaving a function whose name implies an exit that does not exist.

### ✅ §BTC-IL-VIA-VBTC — **BUILT, 2026-09-11. THE SECTION BELOW IS MY OWN STALE AND IS KEPT ONLY FOR THE
### REASONING THAT WAS WRONG.** Owner: *"do the identical thing with vbtc as you do for eth."*
⛔ **WHAT I GOT WRONG, AND IT WAS THE LOAD-BEARING CLAIM:** I argued the ETH structure could not mirror
to BTC because *"sats in a Lightning channel cannot be seized."* **The collateral is never the channel
sats.** On ETH it is **weETH** — a token the protocol produces from deposited ETH — and the mirror is
**vBTC**, a token the protocol produces from deposited BTC. **Both are ordinary EVM ERC-20s and both
seize atomically.** I compared the wrong pair of objects: the depositor's asset instead of the
collateral token.
⭐ **THE ONE REAL BLOCKER WAS NEITHER TOXICITY NOR LIQUIDATION — IT WAS THAT vBTC HAD NO LEDGER.**
`2d3141c7` made `VBtc.balanceOf` a **projection** of `Vault.sharesOf`, and `MorphoEscrowVenue.supply`
must *physically custody* what it posts (`approve(MORPHO)` then `supplyCollateral`). **A projection
cannot be custodied**, so `COLL.transfer(venue, …)` resolved to `transferShares(manager, venue, …)`,
the manager had no `pooled`, and every call reverted `InsufficientChannelBtc()` — measured by
`47759214`, not theorised.
▶️ **SO THE FIX WAS THREE PIECES, ALL FETCHED FROM GIT (owner: *"dont rebuild files that you can just
fetch out of history"*), AND IT BUILDS — `forge build` exit 0, 0 errors:**
| piece | source | what it does |
|---|---|---|
| `VBtc.sol` | `0783c95a` | the **LEDGER** back: real `balanceOf` mapping, `totalSupply`, `mintTo`/`burnFrom` `onlyVault` ⇒ **custodiable, exactly as weETH is** |
| the contract path | `git revert 47759214`, scoped so Euler stayed dead | `BtcLevManager`'s COLL branch, `Vault.exposeBtcToLev`/`unexposeBtcFromLev`, the `BtcLib` bodies, the `Interfaces` members |
| the market | `3440c742^`, through the existing `_mkMorphoVenue` helper | `{USDC, ETH.VBTC(), RealRateBtcMorphoOracle, ADAPTIVE_IRM, LLTV 86%}`, `vsB` = 1. The helper inherits the `MORPHO_ALLOW_CREATE` gate, so a typo'd constant fails loud instead of creating an empty twin |

🔑 **AND THE KEYSTONE WAS IN NO COMMIT — history had the ledger without the market, or the market
without the ledger, never the pair.** `vbtcExposeBody` only did `levPooled[lp] += sats`, so the manager
never held vBTC and had nothing to transfer. **`Vault.exposeBtcToLev` now `VBTC.mintTo(LEV_MANAGER,
sats)` and `unexposeBtcFromLev` `burnFrom`s it.** ⇒ the loop closes: channel sats are exposed, vBTC is
minted against them, the manager posts it to Morpho, **and the LP brings no external token** — which is
the whole point, since a BTC depositor holds no WBTC.
📌 **The 2026-09-07 "toxic loop" ruling is overruled by the owner, and its argument never separated the
legs anyway:** *borrow stables against the asset to buy more of the asset* is verbatim what `LevManager`
does with weETH. **It was never an asymmetry.** `openBtcLev`'s WBTC else-branch and the `#36a` test that
asserted vBTC is inadmissible are gone with it.

### 🔴 FOUR THINGS STILL OPEN ON THIS, none of them guesses
1. 🔴 **`totalSupply == Σ levPooled` IS NOW A LOAD-BEARING SOLVENCY INVARIANT AND NOTHING ASSERTS IT.**
   A real ledger means vBTC supply and exposed sats are **two pieces of state that can diverge**, where
   the projection made divergence unconstructible. **This is the mint-side bound §VBTC-IS-THE-SHARES
   already named** (*"`sats <= plainNet(pooled, levPooled)`… a MINT-side invariant"*) — now it has a
   second mirror to stay in step with. ▶️ **The test is a stress test, not a unit test:** random
   interleavings of expose / unexpose / resize / liquidation, asserting the equality after each.
2. **`loanToken` is USDC** while the ETH leg was deliberately moved off it for depth (*"dont even borrow
   usdc, too thin"*). One line; needs the owner's pick.
3. **Lever-up has no stables→vBTC route.** Collateral posts and the borrow works, but vBTC only mints
   against real deposits, so the *"buy more of the asset"* leg the ETH side closes with a DEX buy has no
   analogue. **The hedge can be OPENED but not LEVERED.**
4. **`openBtcLev`'s WBTC else-branch is unreachable** — no WBTC venue is deployed. Removal candidate.

### (superseded — the reasoning below was wrong, see above)
### 🔴🔴🔴 §BTC-IL-IS-NOT-CONSTRUCTIBLE — **THE DELETION REASON IS FOUND, IT IS THE OWNER'S OWN, AND IT
### COLLIDES HEAD-ON WITH THE REQUEST TO RESTORE THE MARKET**
⭐ **PRIMARY SOURCE, `3440c742` (2026-09-07) — not CLAUDE.md's account, the commit message itself:**
> *"Owner: **IL-protect by borrowing dollars against our Lightning BTC to buy more Lightning BTC is
> toxic.** The vBTC Morpho market is not created at all."*

⇒ **CLAUDE.md's story — *"a liquidator who seizes vBTC has no way to exit"* — was wrong, exactly as the
owner said.** The real reason is that **the MECHANISM is toxic**, which is a far stronger objection: it
is not a missing part, it is the part itself.

🔑 **AND THE OWNER IS RIGHT, FOR A REASON WORTH WRITING DOWN, BECAUSE IT ALSO EXPLAINS WHY THE ETH LEG
IS FINE.** The IL hedge for a range must be **LONG** the asset (the range sells the asset as it rises;
the hedge buys it back). Funding a long on BTC by **borrowing against that same BTC** is a **reflexive
leveraged long**: BTC falls ⇒ collateral falls ⇒ debt does not ⇒ you are liquidated *into* the fall,
holding more of the falling asset than you started with.
⛔ **`LevManager` does the identical thing on ETH — borrow stables against WETH, buy more WETH — so why
is that not toxic too?** Because of **one asymmetry, and it is the whole answer:**
| leg | collateral | can a liquidator seize it? |
|---|---|---|
| **ETH** | WETH on the EVM | ✅ **atomically, in the liquidating transaction** |
| **BTC** | sats in a **Lightning channel** | 🔴 **NO — not on Bitcoin's timeline, not without the counterparty** |
⇒ **the structure is identical and only ETH's is liquidatable.** A lender against channel sats cannot
close the position when it goes bad, so **the lender eats the gap** — which is both the toxicity and the
reason no real market will ever list it. **This is adjacent to CLAUDE.md's "liquidator exit" story and
sharper than it: the problem is not that the seizer cannot SELL, it is that the seizure cannot HAPPEN.**

⛔ **SO I HAVE NOT RESTORED THE MARKET, AND THIS IS THE ONE PLACE I AM NOT TREATING THE INSTRUCTION AS
SETTLED.** The instruction was *"IF SO bring that code back"*, conditioned on the `if`. **The `if`
resolves to a mechanism the same owner deleted on 2026-09-07 for a stated reason that still holds.**
⇒ **restoring it would re-create, on the owner's instruction, the exact thing the owner called toxic** —
and rule 13 says a reversal needs evidence, not a newer request. **Say the word and it goes back in one
commit** (`3440c742` removed: `DeployL1_s`'s vBTC block — `mvB`, `vbOracle`, `mpB`, `createMarket`,
`MorphoEscrowVenue` — with `vsB` 2→1, plus `47759214`'s `-2,378 bytes` of contract-side path). **But I
am not doing it silently on a conditional whose condition is a contradiction.**

### 🔑 WHAT THE HONEST OPTION SET ACTUALLY IS, now that "the LP deposits real BTC" closes the alternatives
**The LP deposits real BTC into a channel** (owner, 2026-09-11), so the hedge cannot be funded from the
depositor's own EVM assets — they have none.
| option | verdict |
|---|---|
| **(a)** borrow against pooled BTC (vBTC market) | 🔴 **the toxic one.** Ruled out above, by its own author |
| **(b)** collateralise with the ETH leg's assets | 🔴 **cross-subsidy** — ETH LPs would fund BTC LPs' hedges. `LeverageCrossSubsidyProbe` exists to forbid exactly this |
| **(c)** collateralise with basket stables | 🔴 the owner already asked and the answer is no: it puts QU!D backing behind an LP's directional bet |
| **(d)** perps / options | 🔴 breaks *"assume in the final design that we only borrow from aavev4"* |
| ⭐ **(e)** **fund the long from FEE INCOME, not debt** | ✅ **the only one that contradicts nothing.** The pool buys BTC exposure with revenue it already has ⇒ **no borrowing, so no liquidation, so no toxicity and no market to list.** It is **rate-limited** by fee income rather than unbounded, which is a real limitation and an honest one |
| **(f)** accept that BTC LPs bear IL | ⚠️ **honest, and it contradicts *"no IL for a passive LP"*** — so it is a DESIGN CHANGE, not a default to fall into silently |

⇒ 📌 **THE DECISION IS (e) OR (f), AND IT IS THE OWNER'S.** Every other row is already ruled out by a
standing ruling. ⛔ **And note what this means: *"no IL for a passive LP" is currently TRUE ON THE ETH LEG
AND FALSE ON THE BTC LEG*, and nothing in the tree says so.**

### ⛔ AND `openBtcLev` IS UNREACHABLE BY ITS OWN USER BASE — a removal candidate either way
```solidity
function openBtcLev(uint initialWbtc, ILevVenue venue) external nonReentrant {   // BtcLevManager.sol:49
    IERC20Min(WBTC).transferFrom(msg.sender, address(venue), initialWbtc);       // :57
```
**It requires the caller to already hold WBTC.** Owner, 2026-09-11: *"the lp will not deposit wbtc they
will deposit real btc."* ⇒ **no actual BTC depositor can call this function at all.** It is not
*"opt-in and externally funded"* as I first booked it — **it is dead on arrival for the entire intended
user base**, and it is the entrypoint the whole `BtcLevManager` hedge hangs off.

### 🔴🔴 §NO-BTC-IL-HEDGE — **BTC DEPOSITORS ARE NOT PROTECTED FROM IL, AND THE REASON IS THE COLLATERAL**
```solidity
function openBtcLev(uint initialWbtc, ILevVenue venue) external nonReentrant {   // BtcLevManager.sol:49
    …
    IERC20Min(WBTC).transferFrom(msg.sender, address(venue), initialWbtc);       // :57
```
**The LP must already own WBTC and hand it over.** `BtcLevManager` is constructed
`LevBase(aux, wbtc, gov, quid, wbtc, …)` — **collateral is WBTC**, and `leverUpBuyWbtc` borrows a stable
and **buys more WBTC**, which is the correct direction for an IL hedge (it restores the exposure the
range sold).
🔑 **BUT A BTC DEPOSITOR'S ONLY ASSET IS SATS IN A LIGHTNING CHANNEL.** They hold no WBTC. ⇒ **they
cannot fund their own hedge**, so the BTC hedge is **opt-in AND externally funded** — two independent
contradictions with *"no IL for a passive LP"*, where the ETH leg has only the first.
⇒ **YES: protecting BTC depositors automatically requires the protocol to post the pool's own BTC claim
as collateral**, because that is the only asset the depositor has. ⛔ **AND I HAVE RESTORED NOTHING.**
I began reasoning toward re-instating the vBTC market from CLAUDE.md's account of why it was deleted —
*"a liquidator who seizes vBTC has no way to exit"* — and **the owner says that was not the reason.**
⇒ **the real reason is not recorded anywhere I can read, so the decision is the owner's and it is
booked, not taken.** ⚠️ **And §PHANTOM-REDEEM makes the exit question sharper, not softer:** whatever
collateral rail is chosen, the liquidator's exit has to be **swap-out**, because there is no other one.

### ⛔ RETRACTION — **"IT WOULD MOVE OUR OWN PRICE AND SKEW" IS FALSE, AND I DELETED BOTH MECHANISMS MYSELF**
Owner caught it. Measured, in the tree, today:
| claim I made | what the code says |
|---|---|
| *"move our own skew"* | **§FLAT-FEE.** `MIN_SWAP_SKEW_WAD = 4.2e14` and `premium = fullMulDiv(r.amount, MIN_SWAP_SKEW_WAD, 1e18)` — **flat 420 ppm, size-blind, both directions.** The Avellaneda–Stoikov kernel that made skew move is **deleted**. There is no skew to move |
| *"move our own price"* | **`Core` reads `AUX.assetPrice(ASSET)`** (`:176`, `:190`, `:261`). **There is no curve.** The settlement price is the oracle, so a trade of any size moves it by **zero** |
⭐ **THE META-ERROR, AND IT IS THE ONE TO CARRY: I REASONED FROM GENERIC-AMM INTUITION ABOUT A DESIGN
WHOSE CURVE AND VARIANCE KERNEL I PERSONALLY DELETED.** Price impact and variable skew are what an AMM
has; this venue has neither. **Every "obviously" in this document is now suspect for the same reason** —
the deletions were recent and the intuitions are older than they are.

✅ **AND THE CONCLUSION SURVIVES ON A BETTER ARGUMENT — A CONSERVATION ONE, WITH NO PRICE IN IT.** Buying
vBTC through our own venue is wrong not because it moves anything, but because **it creates no exposure
at the system level.** The LP's hedge would gain exactly the BTC the pool loses ⇒ **net system BTC
exposure unchanged, the hedging LP long, and every other LP correspondingly shorter.** ⇒ **the hedge
would be funded by the other LPs**, which is the same defect as §BREAK-8-11 wearing a new costume.
**Buying WBTC externally brings NEW exposure in.** Right answer; the reason I gave for it was not.

### ⭐ §LOCKSTEP — **THE ONE INVARIANT THAT EXPLAINS WHY `unexpose` SHOULD NOT EXIST**
Owner: *"unexpose feels like a noun that shouldnt exist… dont double encumber."* **The algebra says
exactly that.** Every write to `levPooled` in the tree:
| site | what it does | lockstep? |
|---|---|---|
| `RangeLib.levAddNet:47` | `LP.pooled += netTok; levPooled[lp] += netTok;` | ✅ same amount, both |
| `RangeLib:31` (levRemove) | `LP.pooled -= netRem; levPooled[lp] -= netRem;` | ✅ same amount, both |
| `BtcLib:109` | `if (a.full) { levPooled = 0; levBuf = 0; }` | ✅ full exit zeroes both |
| 🔴 `BtcLib:225` `vbtcExposeBody` | **`levPooled[lp] += sats`** | ⛔ **`levPooled` ALONE** |
| 🔴 `BtcLib:233` `vbtcUnexposeBody` | **`levPooled[lp] = sats >= lev ? 0 : lev - sats`** | ⛔ **`levPooled` ALONE** |

🔑 **THE INVARIANT: `levPooled` MAY ONLY MOVE IN LOCKSTEP WITH `pooled`.** It has to, because
`plainNet(pooled, levPooled) = pooled − levPooled` is *the LP's own withdrawable sats*, and the lev book
growing or shrinking must not change what the LP personally deposited. `RangeLib` preserves that by
construction — **the lev book mints range shares and marks the same amount as not-yours, so the
difference is invariant.**
⇒ **THE EXPOSE/UNEXPOSE PAIR ARE THE ONLY TWO SITES THAT BREAK IT, AND BREAKING IT *IS* THE DOUBLE
ENCUMBRANCE:** `plainNet` falls while the LP's deposit has not moved. ⇒ **the owner's instinct located
the defect from the NAME**, before any of the arithmetic: a verb that encumbers without moving anything
is a verb with nothing to do.
✅ **AND UNDER SHARE-TRANSFER COLLATERAL THEY ARE NOT MERELY WRONG, THEY ARE UNNECESSARY.**
`openBtcLev` does `COLL.transferFrom(msg.sender, venue, initialVbtc)` ⇒ `transferShares` moves
`pooled[lp] → pooled[venue]` **and is itself bounded by `plainNet`**, so you can only post *free*
shares and the shares you posted are **gone from your balance**. **The movement IS the encumbrance.
Nothing needs marking.**
▶️ **DELETE: `Vault.exposeBtcToLev`, `Vault.unexposeBtcFromLev`, `BtcLib.vbtcExposeBody`,
`BtcLib.vbtcUnexposeBody`, both `IVaultExposeB` members (which empties the interface — delete it too),
and `BtcLevManager`'s import of it.** Four functions, one interface, two struct-free writes. **`levPooled`
itself SURVIVES** — `RangeLib` is its real mechanism and that is not redundant.
⛔ **NOT DONE IN THIS COMMIT: a peer is mid-flight deleting `feesPerShare` and holds uncommitted edits in
`Vault.sol`, `BtcLib.sol`, `Interfaces.sol`, `RangeLib.sol`, `Shares.sol`, `Quid.sol`, `QuidLib.sol`,
`SwapLib.sol` and `Types.sol`.** Editing into that is rule 14c with the roles reversed, and I did it to
them once today already. **Handed over instead.**

### ⛔ §7540-DOES-NOT-FIT — **I ARGUED FOR THE VOCABULARY AND I WAS WRONG. THE CONTROL DIRECTION IS INVERTED.**
Owner: *"im not sure anymore where 7540 fits (if at all)."* ⇒ **it does not, and the gating settles it:**
```solidity
function requestDeposit(address lpEth, uint sats) external nonReentrant onlyBTCChannels   // Vault:171
function requestRedeem(address lpEth, uint lpPayoutSats) external nonReentrant onlyBTCChannels // :199
```
**Both are hop-gated.** In ERC-7540 **the USER calls `requestDeposit`/`requestRedeem`** and the vault
fulfils later. Here **the PROTOCOL calls them**, after an external event — an SPV-proven Bitcoin deposit,
or a swap-out request. ⇒ **same words, opposite actor.** A 7540 integrator calling `requestDeposit`
gets `NotBTCChannels`.
⇒ 📌 **SO EVEN THE "FREE VOCABULARY" I ARGUED FOR IS WRONG, AND WORSE THAN NEUTRAL: the names imply a
PULL model we do not have**, so they mislead exactly the reader who knows the standard. **Retracting
§7540-STYLE's conclusion.** The earlier objections stand and now have company: no `asset()`/shares
dichotomy (the token *is* the shares), ~8 functions of EIP-170 cost for an interface nobody queries,
and now an inverted caller.
▶️ **The honest naming is a SETTLEMENT verb, not a request verb** — these functions record something
that already happened on Bitcoin. ⚠️ **Booked, not renamed: it is ABI, the peer is in `Vault.sol`, and
it is cosmetic against everything else open.**

### ⚠️ AND THE VARIABLE PASS IS PARTIAL — saying so, rather than implying a full sweep
**Covered:** `pooled`, `lpShares`, `levPooled`, `totalLevPooled`, `plainNet` (11 refs, stays — it is the
LP's own-sats accessor and is load-bearing), `feesPerShare` (write-never, peer deleting it now).
**NOT yet examined:** `levBuf` (51 refs), `levBufferUsd` (21), `totalBuffer` (17), `RANGE_ANCHOR` (9).
⚠️ **`levBuf` at 51 references with `levBufferUsd` and `totalBuffer` beside it is the next place to look
for the same shape** — three variables tracking one buffer in two units and a total is the profile of
something reducible, and `levBuf` appears in `refreshBookmarks` weights (`LP.pooled + levBuf[user]`)
where `levPooled` does not, which is either a real distinction or the drift that `plainNet` had.

### ⛔ §LIQUIDATOR-HAS-NO-EXIT AND §DELEVER-WITHDRAW-STRANDS-SATS ARE BOTH **RETRACTED** — THEY WERE
### ARTEFACTS OF MY OWN LEDGER MISTAKE, NOT PROPERTIES OF THE DESIGN
Owner: *"didnt we decide that any vbtc holder can swap out into dollars with any channel"* — **yes, and
it is true under the PROJECTION, which I replaced with a ledger this morning.** Reverted (`712999e2`).
```solidity
function transfer(address to, uint amt) external { IVBtcRange(VAULT).transferShares(msg.sender, to, amt); }
// Vault.transferShares -> BtcLib.transferSharesBody: autoManaged[from] -> autoManaged[to]
```
⇒ **a vBTC transfer moves the RANGE POSITION ITSELF.** A liquidator who seizes vBTC receives a real
`autoManaged` entry and exits by swap-out like any LP. ⇒ **§LIQUIDATOR-HAS-NO-EXIT described the ledger,
where a balance and a position are two objects and a seizer gets the first without the second. Under the
projection it is unconstructible.**
⇒ **§DELEVER-WITHDRAW-STRANDS-SATS goes the same way:** with shares as collateral there is no `levPooled`
marking to forget, so `deleverWithdraw` returning the collateral to the LP was **correct all along**. **I
"root-fixed" a bug that existed only in the model I had wrongly introduced.**

🔴 **AND THE LEDGER'S REAL DEFECT WAS WORSE THAN EITHER AND I DID NOT SEE IT WHEN THE OWNER FIRST STATED
THE RULE: A DOUBLE-COUNT.** `exposeBtcToLev` does `levPooled[lp] += sats` — **those sats are already
represented by the LP's `pooled`** — and I added `VBTC.mintTo(LEV_MANAGER, sats)` on top. **The same
channel sats then backed BOTH the LP's shares AND newly minted vBTC.** That is *"minting vBTC against
something that is not channel-locked BTC"* a second time, in a different place from the wrap, and it took
the owner restating the rule for me to find it.

✅ **WHAT THE COLLATERAL PATH IS NOW, AND IT MIRRORS THE ETH LEG EXACTLY:** ETH pulls the LP's own weETH
(`_supplyCollFrom(venue, msg.sender, collWeeth)`); BTC pulls the LP's own vBTC — **which IS their
shares** — via `COLL.transferFrom(msg.sender, address(venue), initialVbtc)`. **No mint. Nothing minted
against anything. Morpho custodies a real position.** 📌 **And that is the answer to `47759214`'s
measured failure — the manager had no shares to transfer because it was never meant to be the one
transferring them.**

⚠️ **ONE DECISION LEFT, AND IT IS THE OWNER'S BECAUSE GUESSING COSTS A THIRD REWRITE:**
`exposeBtcToLev` / `unexposeBtcFromLev` now have **ZERO callers**. Under share-transfer the **movement of
the shares IS the encumbrance**, so marking `levPooled` as well would **double-encumber** —
`plainNet(pooled, levPooled)` would fall twice for one position. **But `levPooled` has other consumers**
(backing via *rangeBTC counts the book*, `totalLevPooled`, and `plainNet` throughout), so whether
lev-exposed sats still need separate tracking is a **design** question. **Left in place, zero-caller,
flagged — not cleaned up.**

### (RETRACTED — kept only so the reasoning that was wrong is legible)
### 🔴🔴🔴 §LIQUIDATOR-HAS-NO-EXIT — **I CREATED THIS TODAY, AND 12 LIVE MARKETS MAKE IT BINDING**
**With `vsB` now 12 markets, liquidators are real participants.** A liquidation on any of them seizes
**vBTC** and hands it to someone who is **not an LP**. What can they do with it?
| exit | state |
|---|---|
| `redeemVBtc` | 🔴 **I DELETED IT TODAY** (it was a phantom — it never paid anyone) |
| `unwrapVbtcToWbtc` | 🔴 **I GATED IT TO `LEV_MANAGER` TODAY** |
| sell it | 🔴 **no market** — vBTC is ours and trades nowhere |
⇒ **A LIQUIDATOR SEIZES A TOKEN WITH NO EXIT.** ⛔ **And that makes every one of the 12 markets
uninvestable, because no liquidator will bid on collateral they cannot realise — which means the markets
do not get liquidated at all, which means the debt goes bad.** 📌 **CLAUDE.md attributed exactly this
concern to the original market deletion and the owner said that was not the reason. It was not true
then. It is true now, and I am the one who made it true**, by deleting the phantom and gating the wrap in
the same session I restored the markets. ▶️ **The fix is the unwrap: `unwrapVbtcToWbtc` must be callable
by any vBTC holder, not only the manager** — it burns vBTC and pays WBTC, which is exactly the
liquidator's exit, and it is already written. **Gating it was the mistake, not its absence.**

### ⛔ §NO-WRAP — **THE WRAP IS DELETED. vBTC MAY ONLY BE MINTED AGAINST CHANNEL-LOCKED BTC.**
Owner: *"but we dint mint vbtc against anythibg except channel locked btc."* **The two mint sites, side
by side, are the whole argument:**
```solidity
// BtcLib.vbtcExposeBody — the ONLY legitimate one, and it is BOUNDED
uint free = SwapLib.plainNet(pooled, levPooled[lp]);
if (sats == 0 || sats > free) revert InsufficientChannelBtc();

// what I added an hour ago — NO BOUND OF ANY KIND
function wrapWbtcToVbtc(uint sats) external {
    IERC20Min(address(AUX.WBTC())).transferFrom(msg.sender, address(this), sats);
    VBTC.mintTo(msg.sender, sats);          // <- no channel sats behind it
}
```
⇒ **an unbacked mint, against the very invariant §VBTC-IS-THE-SHARES names as protecting the leg**
(`sats <= plainNet(pooled, levPooled)`). ⚠️ **And it composed with the liquidator ungate into a live
drain:** wrap creates vBTC from WBTC, the ungated unwrap lets a **sats-backed** holder take that WBTC
out ⇒ a channel LP converts their claim to WBTC and leaves while their sats stay locked, with the WBTC
having come from **another LP's** lever-up.

⭐ **HOW THE REASONING FAILED, AND IT IS THE REUSABLE PART: I CITED §MIXED-SETTLEMENT, WHICH IS ABOUT
SETTLEMENT, TO AUTHORISE ISSUANCE.** *"Obligations settle in whatever the pool holds, WBTC included"*
says what the pool may **PAY WITH**. It says nothing about what the pool may **MINT AGAINST**. **Those
are different questions and only the first was ever ruled on.** ⇒ **before citing a ruling as
permission, check which side of the balance sheet it governs.**

🔑 **AND THE CONSEQUENCE IS THE ONE THE ORIGINAL DESIGN ALREADY RECORDED AND I READ PAST — the deleted
deploy comment said it in eight words: *"No swapper / no flash — BTC acquisition is external+async."***
**ATOMIC LEVER-UP ON THE BTC LEG IS NOT CONSTRUCTIBLE.** Collateral can only be sats **already in a
channel**; getting freshly-bought WBTC into a channel is an **async swap-in**. The ETH leg can do it in
one transaction only because **weETH is mintable on-chain**; native BTC is not. **This is a physics
asymmetry between the legs, not a gap in the code**, and every attempt to close it synchronously ends in
an unbacked mint — which is exactly the shape mine took.
▶️ **`leverUpBuyWbtc` now reverts `VbtcLeverNeedsChannelIn()`** for a vBTC venue rather than silently
transferring the wrong token. **Loud and honest beats a path that half-works.**

### ⛔ CORRECTION — **"AN ASYNC SWAP-IN" WAS WRONG. THERE IS NO WBTC-TO-CHANNEL ROUTE AT ALL.**
Owner: *"doesnt seem possible."* **Correct — I described a mechanism that does not exist.** Read the
rail: `BTCChannels.settleSwapInProven` requires `_provenDeposit(terms, proof, rawDepositTx)` — **an
actual Bitcoin-chain deposit, SPV-proven** — and then `creditSwapIn(seller, sats, token, …)` pays the
depositor **stables**.
⇒ 🔑 **THE SWAP-IN RAIL RUNS THE OTHER WAY: native BTC comes IN and stables go OUT, and it is initiated
by an EXTERNAL SELLER who chooses to sell us BTC.** The protocol cannot pull that trigger, and **nothing
anywhere converts WBTC into channel sats.** WBTC→native BTC is a BitGo merchant redemption or an
off-chain venue trade; **neither is in this tree, and neither can be.**
⇒ **SO "ASYNC" UNDERSTATED IT. BUYING WBTC DOES NOTHING FOR BTC COLLATERAL, EVER — not slowly, not
eventually.** The pool's channel sats grow **only** when an outside party deposits real BTC. ⭐ **That
makes BTC-leg collateral strictly a function of deposits, which is a design limit to state plainly, not
a gap to engineer around.** My two previous framings both implied a route existed; there is none.

### 🔑 AND WHY A LIQUIDATOR IS IN SCOPE AT ALL — the owner asked, and the answer is Morpho, not us
**Because we just created twelve Morpho markets, and Morpho liquidation is PERMISSIONLESS.** The chain
is short and every link is already built: an LP exposes sats ⇒ vBTC is posted as collateral ⇒
`leverBorrow` draws a stable ⇒ BTC falls ⇒ LTV breaches ⇒ **any stranger repays the debt and seizes the
collateral.** Nothing in our code can decline that; it is Morpho's, and it is the point of a lending
market.
🔴 **AND IT IS WORSE THAN ONE LP'S PROBLEM, BECAUSE THE POSITION IS POOLED.**
`MorphoEscrowVenue.supply` calls `MORPHO.supplyCollateral(_params(), collAmount, **address(this)**, "")`
— the Morpho position belongs to **the venue**, not the LP (§POOL-VENUE). ⇒ **a liquidation seizes from
the POOLED position, so one LP's bad loan takes collateral away from every other LP in that venue.**
📌 **That is the isolation problem, and the construction for it is already derived** (burn
`Δu = tot·S/bal` units from the causing LP, verified in exact rational arithmetic, with the honest limit
that a seizure exceeding that LP's own collateral is genuinely shared). **It is derived and NOT BUILT.**
⇒ **So the liquidator matters for two independent reasons: they have no exit (so they will not bid, and
the debt goes bad), and if they do bid, the loss lands on LPs who did nothing.** Both are consequences
of turning on twelve markets, and neither existed before today.

### 🔴 TWO THINGS RE-OPEN BECAUSE OF THIS, stated rather than papered over
1. **The BTC hedge can be OPENED against already-exposed sats but NOT LEVERED**, pending an async
   channel-in route. §BTC-IL-VIA-VBTC's collateral half stands; its leverage half does not.
2. **§LIQUIDATOR-HAS-NO-EXIT RETURNS.** The unwrap was the exit I proposed, and it was **the wrong
   exit** — it paid out an asset vBTC was never minted against. ⇒ **the real exit must be swap-out**
   (owner: *"there is no redeem really just swapout"*), which means a liquidator has to be able to reach
   the swap-out rail. **That is the open question, and it is the one that decides whether the 12 markets
   are investable.**

### ✅ AND ONE THING FROM THE DELETED SECTION SURVIVES, because it was never about the wrap
**The system prices WBTC as NATIVE BTC everywhere**, and that is measured, not inferred: the feed
registered for WBTC is `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` — **Chainlink BTC/USD**
(`DeployL1_s:291`/`:682`, `DriverE2E:110`, wired as `aFee[1] = cfg.btcFeed` in `DeployLib:189`). So
`assetPrice(WBTC)` returns the native price and **swap pricing, hedge sizing, `netEquityBase` and all
twelve market oracles inherit it.** ⇒ **the protocol already carries WBTC/BTC basis risk on every WBTC
it holds, and nothing says so.** **Undocumented, not wrong — but it should be stated as a premise**, and
it is unaffected by the wrap's removal because it was never the wrap's doing.

### (the two paragraphs below are MOOT — the wrap they describe no longer exists)
### ⚠️ §WRAP-ASSUMES-PARITY IS REFRAMED — **THE WHOLE SYSTEM ALREADY PRICES WBTC AS NATIVE BTC**
**Measured, and it changes the recommendation:** the feed registered for WBTC is
`0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` — **Chainlink BTC/USD**, not a WBTC feed
(`DeployL1_s:291`/`:682`, `DriverE2E:110`, wired as `aFee[1] = cfg.btcFeed` in `DeployLib:189`). So
`assetPrice(WBTC)` returns the **native BTC** price, and every consumer inherits it: swap pricing, hedge
sizing, `netEquityBase`, and all **twelve** market oracles.
⇒ 🔑 **THE "FIAT" IS NOT A CHOICE STILL TO BE MADE — IT IS ALREADY THE SYSTEM'S BEHAVIOUR EVERYWHERE, AND
NOBODY WROTE IT DOWN.** The wrap minting 1:1 is therefore **consistent** with the rest of the design, and
pricing *only the wrap* off the basis would be the **inconsistent** option — it would make one door
charge for a spread that every other door ignores.
⇒ **SO THE DECISION IS BIGGER AND SIMPLER THAN I FRAMED IT: it is not "how should the wrap price?" but
"does the protocol accept WBTC/BTC basis risk system-wide?"** ⚠️ **It already does. The only defect is
that this is undocumented**, so every reader has to rediscover that a WBTC balance is valued at native
price. ▶️ **State it as a design premise, and the wrap needs no change.** ⛔ **If the answer is instead
that the basis must be priced, the fix is NOT in `wrapWbtcToVbtc` — it is a WBTC/BTC feed behind
`assetPrice`, once, where all four surfaces read it.**
📌 **AND THE EXPOSURE IS LARGER THAN THE WRAP, WHICH IS WHY THE REFRAME MATTERS:** it is not the minting
step that carries the risk, it is **every WBTC the pool holds**, valued at native-BTC price on every
read. **My original write-up under-stated it by attributing it to one function.**

### (original, narrower framing — kept because the arb it describes is real, but see the reframe above)
### 🔴🔴 §WRAP-ASSUMES-PARITY — **`wrapWbtcToVbtc` MINTS 1:1, AND 1:1 IS AN ASSUMPTION, NOT A PRICE**
`wrapWbtcToVbtc(sats)` takes WBTC and mints **the same number** of vBTC. But **WBTC is a custodial
wrapper that trades at a discount to native BTC**, and vBTC is a claim on **native channel sats**. ⇒ when
WBTC < BTC, the lever path is an **arbitrage on the pool**: borrow stables → buy the *cheap* wrapper →
wrap at **1:1** → hold a claim on the *dear* asset. **The LP pockets the basis and the pool eats it**,
and nothing in the path checks a price. ⚠️ **It is reachable by any LP, because the lever path is the
trigger even though the wrap itself is manager-gated.**
▶️ **Two honest resolutions, and the choice is the owner's:** price the wrap off the WBTC/BTC basis, or
**declare by fiat that the pool treats WBTC and native sats as one asset** — which §MIXED-SETTLEMENT
already half-says (*"obligations settle in whatever the pool holds, WBTC included"*). ⛔ **The fiat is
defensible and must then be SAID, because it makes the basis a cost the pool has accepted rather than a
leak nobody priced.**

### ⚠️ AND IT BREAKS THE INVARIANT I STATED TWO COMMITS AGO — my own, within the hour
I booked `totalSupply == Σ levPooled` as the load-bearing solvency bound. **`wrapWbtcToVbtc` mints vBTC
without touching `levPooled`**, so the bound is already false by construction. ⇒ the real one is
**`VBtc.totalSupply == Σ levPooled + WBTC held by the Vault`**, and it now has **two** backing assets to
reconcile. **A stress test written against the version I wrote down would have passed while the system
was unbacked.**

### 🔴🔴 §DELEVER-WITHDRAW-STRANDS-SATS — **THREE SIBLING PATHS UNWIND A POSITION. ONE FORGETS TO UNEXPOSE.**
| path | where the vBTC goes | unexposes? |
|---|---|---|
| `_deleverSlice` (`BtcLevManager:163`) | `venue.withdraw` ⇒ **the MANAGER** | ✅ `unexposeBtcFromLev(lp, freedSats)` |
| `closeBtcLev` (`:178-184`) | `venue.withdraw` ⇒ **the MANAGER** | ✅ `unexposeBtcFromLev(lp, back)` |
| 🔴 `deleverWithdraw` (`BtcLib`) | `venue.withdraw` ⇒ manager, **then `IERC20Min(coll).transfer(lp, out)` ⇒ THE LP** | 🔴 **NO CALL AT ALL** |

⇒ **the LP walks away holding loose vBTC while `levPooled[lp]` still counts those sats as exposed.**
`exposeBtcToLev` incremented `levPooled` when the vBTC was minted; nothing decrements it here.
⛔ **THE COST IS BORNE BY THE LP AND IT IS PERMANENT: `plainNet(pooled, levPooled)` is what gates every
BTC withdrawal, so their own sats are locked in the range forever.** `closeBtcLev` will not rescue them —
by then `venue.collateralOf(lp)` is already 0, so `back == 0`, the `unexposeBtcFromLev` is skipped, and
the inflated `levPooled` is never unwound. **A silent, unrecoverable strand.**
✅ **AND WHAT IS *NOT* WRONG, because I checked it before writing this up:** the aggregate backing
survives. Supply and `wbtcHeld` fall together when the LP unwraps, so
`totalSupply == Σ levPooled + wbtcHeld` still balances, and the LP's sats stay in the pool backing the
WBTC they took. **This is a stranding, not a theft** — worth stating, because the first reading looked
like one and the difference decides the fix.
▶️ **ROOT FIX, not a fourth patch: the unexpose belongs where the collateral LEAVES the venue, so no
unwind path can forget it.** All three call `venue.withdraw`; that is the one place. **Rule 17 — and
`deleverWithdraw` also uniquely sends the collateral to the LP rather than keeping it at the manager,
which is the tell that it was written against a different model than its two siblings.**

### 🔴 §TWELVE-MARKETS-ONE-PEG-ASSUMPTION — **THE ORACLE PRICES EVERY STABLE AT EXACTLY $1**
`RealRateBtcMorphoOracle.price()` returns `assetPrice(WBTC) * SCALE`, where `SCALE` is `10**loanDec`.
**There is no stable price anywhere in it.** ⇒ across **12 markets** it asserts USDC = USDT = PYUSD =
RLUSD = DAI = USDS = USDE = AUSD = cUSD = crvUSD = frxUSD = BOLD = **exactly one dollar, always.**
| the stable trades | the borrower's debt is | consequence |
|---|---|---|
| **below** peg | worth **less** than modelled | over-collateralised — safe, LLTV merely wrong |
| 🔴 **above** peg | worth **more** than modelled | **under-collateralised ⇒ bad debt, and liquidation fires late or not at all** |
⚠️ **This is the §NO-GAMEABLE-BOUND question asked of a different input:** a 1.0 that nobody measured is
a constant a guard consumes, and rule 18 ④ applies — **what is the worst input that still satisfies it?**
**Any depeg, in the dangerous direction, silently.**
📌 **The ETH leg does not have this problem, and the contrast is the evidence:** it uses Morpho's own
`RLUSD_WEETH_ORACLE` and `PYUSD_WEETH_ORACLE` — **one oracle per pair, priced by someone who prices the
stable.** We wrote one oracle for twelve pairs and priced none of them. ⇒ **either read a stable feed, or
restrict the roster to stables whose depeg risk the owner has explicitly accepted.** Twelve is a lot of
pegs to assume.

### ✅ AND ONE BOUND THAT IS FINE, checked so the absence is not read as unexamined
`LevVenueBase._unitSlice(u, tot, bal) = fullMulDiv(u, bal + 1, tot + 1e6)` floors, and `_unitsFor` floors
on the way in — so **collateral rounds against the LP at both ends (conservative) and debt rounds in the
LP's favour at both ends (anti-conservative)**. The convention is applied by DIRECTION OF THE FUNCTION
rather than by WHO IT FAVOURS, which is the wrong rule. ⇒ **but the magnitude is ≤1 unit per operation
per LP**, the virtual-offset pair is self-consistent, and `debtOf` composes the floor with
`_sharesToAssetsUp`'s **ceil**, which cancels most of it. **Booked as a convention worth fixing when the
debt leg is next touched; not a value leak, and not worth a change on its own.**

### ✅ AND ONE ATTACK THAT FAILED, recorded because a clean result is evidence too
I expected the classic accumulator theft: deposit just before a fee event, withdraw after, capture
fees you did not earn. **Defended.** `feesPerShare`/`USD_FEES` are per-share accumulators and
`QuidLib._refreshBookmarks` → `SwapLib.refreshBookmarks(LP, weight, feesPerShare, usdFees)` checkpoints
the depositor at entry, with a separate `venueBm` bookmark for the venue leg. **A joiner is owed
nothing retroactively.** ⇒ the mechanism is correct and the attack is unconstructible.

### ⚠️ AND A NOTE ON WHAT I HAVE NOT BROKEN, so the absence is not read as endorsement
I have not been able to break: §7c's argument that a pro-rata claim cannot be short (it is arithmetic);
§12's finding that collateral is weETH/WBTC only (read from the deploy); §NO-GAMEABLE-BOUND's two
measured attacks; or the drift formula's entry-time correctness. ⛔ **That is four sections examined
and standing — it is not a claim that the rest is sound**, most of it has not been attacked yet.

## 0b. THE ASSUMPTIONS, EACH GRADED BY HOW WE KNOW IT
| # | assumption | grade |
|---|---|---|
| A1 | Settlement is at an oracle price against held inventory; there is no curve | ✅ **structural** — read from code |
| A2 | Two constituencies, opposite preferences, **neither funds the other** | 📜 **owner axiom**, verbatim |
| A3 | The pool sells volatile when someone buys it. **That is the service, not an accident** | ✅ structural |
| A4 | An LP's claim is **pro-rata on value** (`Quid._convert`) | ✅ measured |
| A5 | **LPs are PASSIVE.** A vault depositor does not manage a position | 📜 positioning (§PLP-U) — **and A5 is what kills opt-in** |
| A6 | No charge or bound may derive from observed flow | 📜 owner axiom (§NO-GAMEABLE-BOUND), with two measured attacks behind it |
| A7 | No forecasts — no timer, no dwell, no reversal assumption | 📜 owner axiom |

## 0c. THE GOALS, AND WHAT EACH ACTUALLY RESTS ON
| # | goal | rests on |
|---|---|---|
| G1 | LP preserves **upside** (the asset) | the hedge — **UNBUILT** |
| G2 | Basket depositor preserves **dollar value** | A4 + the mint-side invariant. ✅ holds today |
| G3 | **No slippage** | A1. ✅ structural — nothing to build |
| G4 | **No LVR** | we publish no price. ✅ structural |
| G5 | **No IL for a passive LP** | G1 **and** A5 ⇒ **automatic**, not opt-in |
| G6 | Nothing gameable | A6. ✅ achieved by deleting the measurement, not bounding it |

⇒ **G3 and G4 are free — they fall out of deleting the curve. G2 holds. G1/G5 are the entire remaining
product**, and they are unbuilt.

## 🔴 0d. HOW DO I KNOW WE DESIGNED THIS RIGHT? — **I DO NOT, AND HERE IS THE HONEST LEDGER**
There is no proof. What can be offered is **what would falsify each claim, and whether that check has
been run.** Anything in the bottom block is a belief, not a result.

| claim | what would falsify it | run? |
|---|---|---|
| no slippage | find a curve, or a fill that is not at the oracle | ✅ yes |
| no LVR | find a published price an arb can trade against | ✅ yes |
| the charge is ungameable | find an input to it that a counterparty sets | ✅ yes — that is *why* it is a constant |
| carry is 183 bps net | measure gross borrow minus the weETH ratchet | ✅ measured |
| the venues can fund us | post collateral and read the cap | ✅ measured — and it found v4 caps the book at ~\$369k |
| pooled liquidation is unfair | build the fixture and read the number | ✅ measured — 4,801 bps |
| 🔴 **the 420 ppm exceeds adverse selection over the settlement window** | **measure realised adverse selection at our oracle cadence** | ⛔ **NEVER RUN** |
| 🔴 the hedge actually cancels IL | build it and measure an LP's realised PnL across a round trip | ⛔ unbuilt |
| 🔴 LPs accept 183 bps/yr for it | ask one | ⛔ never |
| 🔴 counterparties accept a dated claim | ask one | ⛔ never |
| 🔴 turnover supports the break-even | measure volume ÷ levered notional | ⛔ D6, unmeasured |

⛔ **THE ONE THAT SHOULD WORRY US MOST IS THE FIRST RED, AND IT IS NOT THE HEDGE.** With the ceiling
struck (§5), the **floor is the only surviving condition on the charge** — and it has never been measured.
**If 420 ppm does not exceed adverse selection over our settlement window, the LP loses money on every
trade and no hedge repairs that**, because the hedge addresses inventory drift, not mispricing. ⇒ **that
measurement outranks building the hedge**, and it is the one thing in this document that could invalidate
the product rather than delay it.
⚠️ **AND THE SUITE CANNOT TELL US** — §THE-SUITE-DID-NOT-NOTICE: one test file references `wellSkew`, and
the entire pricing kernel was deleted with 997 tests still passing.

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

⭐ **AND THE POSITIONING THAT FOLLOWS, STATED RATHER THAN LEFT AS A SURPRISE** (§PLP-U, verbatim):
> *"This is a **yield-bearing market-making vault with deferred redemption**, not a better AMM. A fine
> product **stated**; a bad surprise **unstated**."*

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
✅ **AND THERE IS NO COMPETITIVE CEILING — RULED 2026-09-11** (owner: *"there should be no contradiction
or competetive ceiling"*). The earlier text made 420 ppm conditional on *"staying under the competing
venue's all-in cost"*, which quietly reintroduced everything §NO-GAMEABLE-BOUND had just removed: a bound
set by an outside quantity we do not control, cannot audit, and would have to keep re-measuring — and a
competitor can move its own all-in cost at will, so pricing against it is a charge a counterparty sets.
**That is the same defect as the flow EWMA, one level out.**
⇒ **THE FLOOR IS THE ONLY CONDITION, AND IT IS OURS:** the charge must exceed adverse selection over the
settlement window. That is a property of our own oracle cadence and our own inventory, measurable without
reference to anyone else. **If a competitor is cheaper, we are cheaper-or-not on the merits; we do not
re-price to chase them.**
📌 **This retires open decision 5 outright.** The *"~17 bps round trip, quoted not measured"* figure it
rested on is no longer load-bearing for the CHARGE — it survives only inside §9's realised-cost
accumulator, where it is a cost we actually pay and can therefore observe.

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

⭐ **IT IS THE RESTORING TERM.** §PLP-T's headline was *"nothing restores inventory, ever"*, and its
table dismissed organic counter-flow as **"not a mechanism — a hope."** A dated claim converts that hope
into a **priced instrument**: the pool does not need counter-flow by a deadline, because the waiter is
paid for the time. ⇒ the gap §PLP-T names is closed by §6, not by buying inventory back.

📌 **WHAT THE TENOR KEYS OFF: DELIVERABLE, NOT OWNED** (§PLP-U option B's surviving insight). weETH
means *owned* and *deliverable now* are different numbers — a liquidity risk a CLMM structurally does
not have. The term structure must read the deliverable quantity, never the owned one.
📌 **THE CLEANEST CASE FOR A DATED CLAIM IS §PLP-R2'S FIFTH SHORTFALL:** *stables LENT OUT at
utilisation, not withdrawable* — handled by none of the four shortfall paths. The stables exist; they
are simply not liquid **now**, which is exactly the condition a tenor prices.
🏷️ **ATTRIBUTION:** this mechanism was proposed in **§PLP-R2** (*"pay the swapper in QU!D rather than
deny service. No new primitive is needed — two already exist"*), which had already identified the
maturity tranche. What this model adds is the second half — **the waiter is PAID** — which is what
turns "rather than deny service" into something a counterparty may prefer.

⭐ **THE ORDERING, taken from the volatile side, which already had it right.** `offrampBody` tries
**Curve first** and falls to the dated claim only when that cannot serve. So:
> **Try to serve NOW. Defer only when serving now is worse FOR THE COUNTERPARTY than waiting.**

That makes deferral something the counterparty *wants*, not something the pool imposes — which is what
*"defer should be opt-in"* actually requires.

## 6b. 🔑 Why the hedge exists at all — two obligations, two denominations
Reconciled 2026-09-11 from two SPRINT rows that contradict each other and are **both right**:
- **§PLP-R3:** *"claims are pro-rata on **VALUE**, so the pool owes no particular asset"* ⇒ composition
  drift is eliminable by settling in whatever is abundant.
- **§PLP-A:** claims are **DENOMINATED** ⇒ *"the pool now **OWES ETH IT DOES NOT HAVE**"*.

| obligation | denominated in | consequence |
|---|---|---|
| **SOLVENCY** — what the pool must be able to PAY | **VALUE** | composition drift can never make us insolvent. It is a **business** problem, not a solvency one (§PLP-T). |
| **EXPOSURE** — what the LP must end up HOLDING | **THE ASSET** | *"preserve upside"* (§1) fails if an ETH depositor is handed value. |

> ⇒ **THE HEDGE EXISTS PRECISELY BECAUSE THOSE TWO DIFFER.** Settling in value is always SAFE and
> sometimes changes the LP's exposure; the hedge is what puts the exposure back.

⚠️ **Reading either obligation alone produces a wrong design** — value-only says *"settle in anything,
there is no problem"*; asset-only says *"we are structurally short and must always buy back"*. The
first loses the LP's upside; the second pays carry it does not owe.
⭐ **AND THIS IS WHY §PLP-T'S REFRAME IS THE DESIGN'S FRAMING:** *the fix does not have to restore a
RATIO, it has to restore the ABILITY TO QUOTE BOTH SIDES.* A much weaker requirement, and it is what
deferral satisfies without buying anything.

## 7. The hedge — drift, not price

### 🔑 WHAT DRIFT IS, IN ONE EXAMPLE, BECAUSE THE OWNER SHOULD NOT HAVE HAD TO ASK (2026-09-11)
Owner: *"idk what drift is or who should fund it and why."* **That is a failure of this document, not
of the reader.** Written plainly, with no formula:

> An LP deposits **100 ETH**. A swapper buys **50 ETH** out of the pool for dollars, at the oracle.
> The pool now holds **50 ETH + \$100k**. **Drift is that 50 ETH** — what the LP put in, minus its share
> of the volatile that is still there.

**Why anyone cares:** if ETH then doubles, the LP wanted 100 ETH of upside. It has 50 ETH plus \$100k,
which at the new price is 50 + 25 = **75 ETH worth**. The missing 25 is the impermanent loss, and drift
is what predicts it. ⇒ **drift is not an abstraction — it is "how much of your ETH did we sell while you
were in".**
✅ **And the pool can read it directly**, which is the whole reason it replaces a formula:
`entryEquity_i` is stored at open, `rangeETH` is the volatile still held, `shares_i/lpShares` is this
LP's fraction. **No price, no √, no variance, no forecast.**

### 🔴 WHO FUNDS IT — **AUTOMATIC, SIZED PER LP, CHARGED PER LP. (CORRECTED — see Part 0a)**
⛔ **THIS SECTION SAID "THE LP THAT WANTS IT HEDGED, OPT-IN" AND THAT WAS WRONG.** I read
`LevManager.openLev`'s `msg.sender` gate and reported the CODE's behaviour as the DESIGN's answer, which
this document's header forbids in its first paragraph. **Opt-in breaks §2's "no IL for a PASSIVE LP" for
exactly the population it names**, requires the LP to manage a position the positioning says it does not
manage, and — with a pooled venue — makes passive LPs carry the hedgers' liquidation risk, which is §1.
✅ **THE ANSWER: the hedge runs for every LP without being asked, sized off that LP's own `drift_i`, and
its carry is charged to that LP's own units.** *Automatic* makes the passive claim true; *per-LP charged*
keeps §1 intact. They only looked mutually exclusive while "who pays" and "who acts" were one question.

🔑 **SO THE THREE CANDIDATE ANSWERS COLLAPSE, AND §1 IS SATISFIED BY CONSTRUCTION RATHER THAN BY A RULING:**
| candidate | verdict |
|---|---|
| the basket funds it | ⛔ forbidden by §1, and never a real option |
| the protocol funds it out of carry | ⛔ **that IS the cross-subsidy**, just with the protocol as the intermediary — every LP would pay for the hedges of the LPs who wanted one |
| ✅ **the LP that wants it, out of its own carry** | **what the code already does.** Opt-in, per-LP, priced at the venue |

🔴 **AND THE ONE PLACE THAT PROMISE IS CURRENTLY BROKEN IS NOT THE FUNDING — IT IS THE POOLING.** The
venue holds **one** position (§POOL-VENUE), so a liquidation hits every LP pro-rata on units regardless
of who borrowed. **Measured: a late zero-debt LP went 5.000000 → 2.599165 ETH for an early LP's
liquidation — 4,801 bps of its own collateral** (`LeverageCrossSubsidyProbe`).
⇒ **"WHO FUNDS THE DRIFT" IS NOT AN OPEN PRODUCT QUESTION. IT IS `§CROSS-SUBSIDY-MEASURED` WEARING A
DIFFERENT HAT.**

### ✅ AND THAT ONE IS NOT AN OWNER DECISION EITHER — **ISOLATION IS CONSTRUCTIBLE, AND IT IS ARITHMETIC**
It was carried as *"isolate per-LP, or price and disclose the sharing."* **§1 already decides it** — an
LP with zero drift funding an LP with positive drift is the conservation principle broken one level
down — so the only real question was whether isolation is *possible* against a pooled venue. **It is.**

**The mechanism, from the code that already exists.** A per-LP slice is
`_unitSlice(u, tot, bal) = u × bal / tot` (`LevVenueBase.sol:45`). A seizure reduces `bal`, so today
**every** slice falls pro-rata and the causing LP's debt is irrelevant to who pays — that is the 4,801 bps.
⇒ **Burn `Δu = tot × S / bal` units from the LP whose position caused the seizure, and every other LP's
slice is preserved EXACTLY**, because `u_i × (bal−S) / (tot−Δu) = u_i × bal / tot` for that Δu.

**Verified in exact rational arithmetic, not reasoned:**
| | causing LP | innocent LP |
|---|---:|---:|
| before (2 LPs, 500 units each, pool 1000) | 500 | 500 |
| **today** — seizure of 240 | **380** | **380** ← the innocent LP pays 120 it did not cause |
| **with the unit burn** (`Δu = 240`) | **260** | **500** ← preserved exactly |
⇒ the causing LP absorbs **240 of a 240 seizure**. No approval, no Morpho change — Morpho still sees one
aggregate; the attribution is entirely protocol-side, which is what `LevVenueBase.sol:200` already claims
(*"isolation is PROTOCOL-ENFORCED rather than MORPHO-ENFORCED"*) and does not yet do.

⚠️ **AND THE HONEST LIMIT, WHICH IS THE PART THAT MUST NOT BE HIDDEN:** if the seizure exceeds the causing
LP's own collateral, the excess **cannot** be charged to it. Same arithmetic: a seizure of 700 against a
1000 pool needs `Δu = 700` and the causing LP has only 500, so **200 units of loss are genuinely shared.**
⇒ **That residue is BAD DEBT, and every lending protocol has it.** The difference is that today the
sharing starts at the FIRST wei of seizure; with the burn it starts only after the causing LP is wiped
out. **Isolation is not absolute, and claiming it would be the vacuous-bound error in a new costume.**

▶️ **SO THE REMAINING WORK IS ENGINEERING, NOT A RULING:** (1) attribute — per-LP LTV is computable from
`positionOf(lp)`, so the LPs above the threshold are identifiable; (2) burn `Δu` from them on seizure;
(3) socialise only the residue, and **say so in the product copy**. ⛔ **It is still gated on the hedge
existing at all** — measured 2026-09-11, the lever currently borrows nothing, so there is no liquidation
to isolate until §7 is built.

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

## 7b. 🔑 The shortfall IS the aggregate drift — and THREE mechanisms now aim at it
Traced 2026-09-11, because §E313's `proRataShortfall` could not be graded without it.

**What the shortfall is, in code:** `Core._shortfallLoadBalance` compares
`RANGE.sharesForShortfall()` (= `lpShares`) against `RANGE.realInventory()` (= `rangeETH`):
```
shortfall = totalShares − rangeETH
```
**And that is the same quantity §7 hedges.** `Σ drift_i = Σ entryEquity_i − rangeETH`, and shares equal
`entryEquity` at entry. ⇒ **the pool-level shortfall and the aggregate per-LP drift are one number
under two names.**

| mechanism | where it acts | what it does to the gap |
|---|---|---|
| **the hedge** (§7) | upstream, at the keeper's touch | **closes** it — borrows so the pool is not short |
| **paid deferral** (§6) | downstream, at exit | **compensates** whoever waits, out of what the asset earns |
| **`proRataShortfall`** (§E313) | at exit | **shares** it, so exiting first gains nothing |

### ⚠️ THE CONDITIONS `proRataShortfall` NEEDS, AND WHETHER THEY STILL HOLD
1. **claims > real inventory** — ✅ **holds, and the design CREATES it**: serving a drain sells LP ETH,
   which is precisely how drift becomes positive.
2. **exit is first-come** — ✅ holds, unchanged.
3. **an exiter can leave at FULL value while the gap is open** — ✅ holds. `onShortfall` is
   `function onShortfall(address, uint) external {}` on ETH — **a literal no-op** — and
   `_shortfallLoadBalance` only calls it at all once the gap reaches **1% of total shares.**
⇒ **All three conditions hold today. The measured 15.2 bps first-out advantage is still constructible.**

### 🔑 BUT THE THIRD MECHANISM MAY BE REDUNDANT, AND THAT IS THE REAL QUESTION
**Paid deferral already compensates the party who does not get served now.** If that compensation is
fair, being second costs nothing and **there is no first-out advantage to remove** — at which point
sharing the shortfall would CHARGE an exiter for a gap the protocol has already agreed to pay for.
⇒ **`proRataShortfall` is the right fix for an UNCOMPENSATED queue and the wrong one for a COMPENSATED
queue.** ⏸️ **The open question is therefore not "restore it or not" but: does the forward yield paid
under §6 actually cover the drift a waiter absorbs?** If yes, §E313's fix is superseded by §6. If no,
it is still needed and `onShortfall`'s no-op is a live hole.
⛔ **Do not wire it before answering that** — the two mechanisms would double-charge the same gap.

## 7c. ✅ **THE SHORTFALL SHOULD NOT EXIST — AND THE CODE ALREADY CONTRADICTS ITSELF ABOUT IT**
Owner, 2026-09-11: *"we should have a design where there is no shortfall and no one has to bear it.
just like we figured we can get rid of forecasts we can do the same here."* Followed through, and it
removes three mechanisms instead of choosing between them.

### 🔴 THE TREE HOLDS TWO INCOMPATIBLE DEFINITIONS OF AN LP CLAIM
| site | what a share is |
|---|---|
| `Quid._convert` (redemption, 4626) | **PRO-RATA:** `shares × _pricingBacking() / lpShares` |
| `Core._shortfallLoadBalance` | **DENOMINATED:** compares `lpShares` — a raw count — against `rangeETH`, an asset balance, as though **1 share = 1 ETH** |

**A pro-rata claim cannot be short.** `shares_i/lpShares × rangeETH` is deliverable by construction at
every ratio; that is what "pro-rata" means. ⇒ **the quantity `_shortfallLoadBalance` reports is not a
solvency fact. It is the share price in ETH terms having fallen below 1** — which is IL, measured in
the wrong unit and given an alarming name.

### ⇒ DELETE THE INTERPRETATION AND ITS CONSUMERS — **NOT THE ARITHMETIC** (corrected 2026-09-11)
⛔ **THIS SECTION USED TO SAY "REMOVES ALL FIVE" AND THAT CONTRADICTED §7, WHICH I ALSO WROTE.** Owner:
*"there should be no contradiction."* Here is the single rule, and it has no second reading:

| symbol | what it is | fate |
|---|---|---|
| `_shortfallLoadBalance` | the **denominated comparison** — `lpShares` (a count) against `rangeETH` (a balance) | 🪦 **DELETE.** This is the whole defect |
| `onShortfall` | the announcement. `function onShortfall(address, uint) external {}` — **a literal no-op** | 🪦 **DELETE** |
| `proRataShortfall` | shares a gap that does not exist | 🪦 **DELETE — but only once the comparison is gone**, and by an argument that NAMES it (§E313: three deletions-by-proximity so far) |
| `sharesForShortfall` | `Quid.sol:1562` — `return totalShares()` | ✅ **KEEP THE READ.** It *is* `lpShares`, and §7's `drift_i` needs it |
| `realInventory` | `Quid.sol:1567` — `return _auxRangeETH()` | ✅ **KEEP THE READ.** It *is* `rangeETH`, and §7's `drift_i` needs it |

⭐ **THE PRINCIPLE, STATED ONCE SO NEITHER SECTION HAS TO REPEAT IT:** `lpShares − rangeETH` is
**meaningless as a solvency alarm** (a pro-rata claim cannot be short) and **exactly right as an exposure
measure** (the pool holds less volatile than its LPs deposited). §6b is why: **solvency is denominated in
VALUE, exposure in THE ASSET.** Same arithmetic, two names, and only one of the names was wrong.
⇒ **We delete the alarm, the threshold, the remediation and the sharing. We keep the subtraction and read
it under its true name.** ▶️ **And both halves land in ONE change** — deleting the consumers while §7 is
unbuilt would strand the reads with no caller, and building §7 first would leave a live alarm firing on a
quantity the hedge is deliberately creating.
⚠️ **The two accessors should then be renamed or inlined** (rule 23: `lpShares` and `rangeETH` are already
public, so an accessor named for a deleted concept earns nothing) — but that is tidying AFTER the change,
not part of it.
⭐ **THIS IS THE SAME MOVE AS §NO-GAMEABLE-BOUND, WHICH IS WHY IT IS THE RIGHT ONE:** we did not bound
the gameable charge, we deleted the measurement it depended on. Here we do not share the shortfall or
compensate it — **we delete the comparison that manufactures it.**

### ⚠️ BUT ONE HALF OF THE MEASURED ATTACK IS REAL AND SURVIVES THIS
§E313's 15.2 bps was later partly reattributed to *"the offramp's weETH→WETH conversion (measured
floor ~25.6 bps)"*. That part is **not** an accounting artifact:
> **The first exiter gets the cheap rung (Curve) and later exiters hit the expensive ones.** Queue
> position changes your CONVERSION COST even when your pro-rata claim is exact.

⇒ **TWO DIFFERENT THINGS WERE CALLED "THE SHORTFALL":**
| | what it is | fix |
|---|---|---|
| **accounting shortfall** — `lpShares` vs `rangeETH` | ✅ **an artifact.** Delete the comparison. | nobody bears it because it does not exist |
| **liquidity-cost asymmetry** — cheap rung first, expensive rung later | 🔴 **REAL.** Pro-rata does not touch it. | each exiter bears **their own** conversion cost, or §6 pays whoever takes the expensive/late path |

⛔ **Do not let deleting the first convince anyone the second is gone.** The first is a naming error;
the second is a queue with a price on it, and §6's paid deferral is the mechanism that already
addresses it — **by paying the late exiter rather than by pretending the queue is free.**

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
⭐ **AND §PLP-13 GIVES THE SHARPEST REASON IT IS THE *THIRD* CHOICE:** the up-leg needs **four
dependencies — a borrow, a venue, an aggregator route and a keeper — "to undo something the range did
to itself."** Serving now needs none of them. Deferring needs none of them. That asymmetry, not the
carry alone, is why leverage is the residue.
🔴 **AND ONE INSTRUMENT IS BLOCKED, NOT MERELY UNBUILT:** §PLP-U's option G, *"borrow WETH against the
weETH instead of selling it"*, has **no market behind it** — `MorphoEscrowVenue.borrow` lends STABLE,
not WETH. When it was wired anyway, every exit reaching that rung delivered the withdrawer **nothing**
while taking their weETH (three tests, *"delivered ETH: 0"*). Its ECONOMIC point is right and already
used (the ratchet survives if you do not sell — §10's net carry); only the instrument is unavailable.

## 12. What the lever posts, and what it borrows — answered from code, 2026-09-11
Owner: *"do our borrowing needs require using lightning btc as collateral? for all purposes of
inventory management we should be able to not depend on that and still get the il protection and all
other properties we need. do we ever use the basket stables as collateral? assume in the final design
that we only borrow from aavev4."*

### ✅ 12a. LIGHTNING BTC IS NEVER COLLATERAL, AND NEVER WAS — the property is already free
**Measured, every venue the deploy actually constructs:**
| range | venue | **collateral** | debt |
|---|---|---|---|
| ETH | Morpho escrow | **weETH** | RLUSD |
| ETH | Morpho escrow | **weETH** | PYUSD |
| ETH | `AaveV3Venue` | **weETH** | USDT |
| BTC | `AaveV3Venue` | **WBTC** | USDC (`AAVE_V3_WBTC_DEBT`, env) |

`DeployL1_s.sol:591` builds the BTC array as `address[] memory vsB = new address[](1); vsB[0] = wbtcV;`
— *"WBTC only"* — and `BtcLevManager.sol:102` **enforces it at runtime**:
`if (ILevVenue(address(p.venue)).COLLATERAL() != WBTC) revert BadTarget();`
⇒ **the BTC hedge posts WBTC ERC-20 and nothing else. LN-custodied sats are posted nowhere.**

🔑 **AND THE WBTC IS *BOUGHT*, NOT DRAWN FROM CUSTODY** — `LevMath.leverUpBuyWbtc(venue, lp, stable,
usd, minOut, WbtcCfg(...))` (`BtcLevManager.sol:114`) borrows the dollar and buys WBTC through the
`_hop1B`/`_hop2B` stable→WBTC route. `Aux.sol:71` holds the resulting balance (*"accumulator of WBTC
ERC20 (BitGo) held by Aux"*), and `:565` bumps it into the `rangeBTC` accumulator — **there is no vault,
and no channel, in that path.**
✅ **`grep` for a vBTC collateral market returns ZERO** — §NO-VBTC-MORPHO-MARKET deleted it (`3440c742`),
so the one construct that would have coupled the hedge to channel custody does not exist.

⇒ **THE ANSWER IS THAT THE INDEPENDENCE THE OWNER WANTS IS ALREADY STRUCTURAL, NOT A THING TO BUILD.**
IL protection, inventory management and the drift hedge run entirely on two ERC-20s — **weETH and WBTC**
— either of which can be sourced, posted and liquidated with the Lightning side completely dark.
⚠️ **The one real coupling that remains is DELIVERY, not COLLATERAL**: a BTC swap-out is served from
channel capacity (§CLAUDE.md's *"redemption and swapouts do actually draw on the same sats"*). That is a
liquidity question the §6 tenor prices, and it never reaches the lever.

### ✅ 12b. BASKET STABLES ARE NEVER COLLATERAL — and the escrow makes it unconstructible
**In all four venues a stable is the LOAN token, never the `collateralToken`.** The lever's relationship
to stables is that it **owes** them.
🔑 **AND IT CANNOT HAPPEN BY ACCIDENT, WHICH IS THE PART WORTH KEEPING:** every Aave borrow runs inside a
**dedicated `AaveV3Escrow`, created per venue** (`LevVenueBase.sol:264-306`). Its constructor approves
exactly `coll` and `stable`; `supplyColl` calls `setUserUseReserveAsCollateral(COLLATERAL, true)` for
that one asset; and it is `onlyVenue`. **The basket's own supplies live at a different address entirely,
so they are not in the account the lever borrows against.** Rule 17's shape: the bad state is
unconstructible rather than merely avoided.

⚠️ **THE BASKET DOES SUPPLY — AND THAT IS A DIFFERENT VERB.** `BasketLib.sol:280`/`:737` do
`IERC4626(vault).deposit(...)` and `ChannelLib.sol:134` does `IAaveV4Spoke.supply(...)` for GHO/USDG.
That is **yield parking in the basket's own account**, not collateral for a protocol borrow.
🔴 **SO ONE INVARIANT MUST BE WRITTEN DOWN AND KEPT, BECAUSE AAVE'S ACCOUNT MODEL IS WHAT MAKES IT
FRAGILE: on Aave, an asset supplied into an account is collateral FOR THAT ACCOUNT.** The basket's v4
supply sits in `Aux`'s account. Nothing borrows from `Aux` today. ⛔ **THE INVARIANT: the account that
parks basket stables must never borrow.** The moment it does, basket depositors' dollars are backing an
LP's hedge — which is §1's *"neither subsidises the other"* violated in the sharpest possible way.

### ⏸️ 12c. "ONLY BORROW FROM AAVE v4" — buildable, and it caps the book at ~$369k until the cap moves
**Accepted as the direction. The one number that has to be stated with it, measured 2026-08-30 by
actually posting collateral on the live spoke rather than by reading liquidity:**
| | Aave v4 hub | Aave v3 |
|---|---:|---:|
| weETH supplied / cap | **3,832.5 / 4,000** | 1,211,945 / 1,350,000 |
| **collateral headroom** | **167 weETH ≈ \$461k** | 138,055 weETH ≈ \$381M |
| borrow capacity | ~\$369k (CF 8000) | ~\$295M (LTV 7750) |
⇒ **v4 is 0.12% of v3's collateral capacity — and the binding constraint is the SUPPLY CAP, not depth.**
⛔ **A 100 weETH supply REVERTS `0xde3fc6ae(0xfa0)`.** So "only v4" is not a routing preference; it is a
**hard ceiling on the whole lever book** until Aave raises the cap. **State it as a launch constraint or
the first real hedge reverts.**

✅ **THE INTEGRATION IS MOSTLY THERE, WHICH IS WHY THIS IS CHEAP DESPITE THE ABOVE.** v4 is already wired
on the **supply** side — `IAaveV4Spoke`/`IAaveV4Hub`, `getAssetId` → `getReserveId`
(`Aux.sol:365-372`), `getUserSuppliedShares`/`getUserSuppliedAssets` (`:1561`) — and the probe confirmed
**weETH IS collateral on v4 at CF 0.8e18**. What is missing is one `AaveV4Venue` + `AaveV4Escrow` pair
mirroring the v3 one.
⛔ **AND ONE TRAP THAT MUST NOT BE COPIED:** `Amp.sol`'s `UserAccountData` declares **3 fields** while the
live spoke returns **7 words**. Decoding 7 as 3 reads word[2] — `type(uint).max` on an empty account —
into `avgCollateralFactor`. **Copy the ladder, not the struct.**

### ⭐ 12d. AND SINGLE-VENUE BORROWING RETIRES *D4* — four of the ten rows it gates
`SPRINT.md` §COMPOSITION-ORDER books **D4 — the allocator's objective** as the decision gating ten core
rows. **"Only Aave v4" answers it by deletion: with one borrow venue there is nothing to allocate.**
| retired by the ruling | survives it |
|---|---|
| `§POOL-VENUE-IS-PINNED-BY-FIRST-CALLER` — *"a second venue is unreachable"* is the DESIGN now, not a defect | `§SESS-61` (which hub) |
| `§SESS-55` — add a USDT venue | `§SESS-75` / `§SESS-60` (1inch client) |
| `WHAT GENUINELY GETS HARDER` — the allocator objective | `§SESS-47` / `§SESS-49` (route planning) |
| `THE FIX, AND WHY IT IS NOT LANDED` — byte-blocked multi-venue | `C15` (1inch migration) |
⚠️ **THE SIX THAT SURVIVE ARE NOT BORROW-VENUE SELECTION — THEY ARE SWAP ROUTING**, and the lever still
has to buy weETH/WBTC with the borrowed stable however few venues it borrows from. **Collapsing the
borrow side does not collapse the aggregator side, and conflating them is how "we only use one venue"
would be read as "routing is solved."**

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
| The **drain**-side absorption ⚠️ **REAL BUT SMALL** | `QuidLib.sendEth` → `SwapLib.deleverEthOnDelivery` → repay pool debt → `withdrawPool` → deliver. A swap-out that exceeds inventory DOES de-lever to serve itself. 🔴 **BUT `§PLP-6-TRAIL` measured it and found the leg *"runs, skips on dust, and is **not what repays a material shortfall**"*.** ⇒ the drain half is weaker than "built" suggests: the open question is not *does it work* (it does) but **what serves a MATERIAL drain once free depth is gone** — which is the same question deferral answers on the sell-in side. |
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

## 🔴 IS THIS DESIGN FINAL AND READY TO BUILD? **NO — AND HERE IS EXACTLY HOW FAR IT IS** (asked by the owner, 2026-09-11)

The reorg's job was to finalize the design. **The MECHANISM is settled. The PARAMETERS and the
WHO-PAYS questions are not, and two of the unsettled ones are load-bearing rather than cosmetic.**

| | state |
|---|---|
| ✅ **SETTLED, and each replaced something gameable or forecast-based** | the flat 420 ppm (§5) · ONE deferral primitive in both directions (§6) · why the hedge exists at all (§6b) · drift instead of price (§7) · the shortfall is an artifact (§7c) · quote-both-and-let-them-pick (§8) · the realised-cost trigger (§9) · leverage as the THIRD choice (§11) · collateral is weETH/WBTC only (§12) |
| 🔴 **NOT BUILT — and this is the whole of the new design** | drift-based hedging · `when` chosen from inventory · the tenor quoted · the keeper-callable pooled de-lever |
| 🔴 **OPEN DECISIONS** | **5 of the 9** in `SPRINT.md` §COMPOSITION-ORDER. D4 closed by §12d; **D2 dissolved into D7, D5 struck, and the §7c/§7 contradiction removed — all 2026-09-11.** |

### ✅ THE THREE THAT BLOCKED BUILDING ARE ALL RESOLVED — 2026-09-11, NONE OF THEM BY MEASUREMENT
1. ✅ **Who funds drift — ANSWERED, and it was never three systems.** `LevManager.openLev` is `external`,
   gated on `msg.sender`, reverting `AlreadyOpen()` (`LevManager.sol:75-81`); `openBtcLev` is the same.
   **The lever is per-LP OPT-IN: the LP that wants its drift hedged opens its own position and pays its
   own 183 bps/yr.** The protocol funds nothing; no LP funds another's hedge; §1 holds by construction.
   ⇒ what remains is **not a funding question** — it is the POOLED LIQUIDATION (4,801 bps measured), so
   this decision dissolved into the one below it rather than needing its own ruling. See §7.
2. ✅ **The competitive ceiling — STRUCK, not measured** (owner: *"there should be no … competetive
   ceiling"*). It had made the flat 420 ppm conditional on staying under a competitor's all-in cost —
   **a bound a counterparty controls, which is §NO-GAMEABLE-BOUND's exact defect one level out.** Only
   the floor remains and the floor is ours: exceed adverse selection over our own settlement window.
3. ✅ **The §7c/§7 contradiction — REMOVED, not documented** (owner: *"there should be no
   contradiction"*). §7c now deletes `_shortfallLoadBalance`, `onShortfall` and `proRataShortfall` and
   **KEEPS the two reads** — `sharesForShortfall` IS `lpShares`, `realInventory` IS `rangeETH`, and
   §7's `drift_i` needs both. One rule, stated once: **delete the alarm, keep the subtraction.**
   ⚠️ Still true that both halves must land in ONE change; that is sequencing, not a contradiction.

⇒ **SO THE HONEST STATE CHANGED TODAY: nothing now blocks BUILDING the hedge.** What is left is one
owner ruling (pooled liquidation: isolate per-LP or price the sharing) plus the unbuilt work itself.

### ⚠️ AND ONE THING THE OWNER SHOULD SEE BEFORE THE v4 RULING IS FINAL
Decision 4 below is retired by *"only borrow from Aave v4"* (§12d) — **but its measurement is evidence
against the ruling, not for it.** $100M on USDC alone crosses the kink at **7.51%**; $50M+$50M across
two Aave venues blends to **~4.37%** — **−314 bps ≈ \$3.1M/yr.** With v4 capped at **~\$369k of borrow
capacity**, that saving is not merely forgone: **it is unreachable, because the entire lever book is
capped below the size at which allocation starts to matter at all.**
⇒ **The ruling is coherent and it is a launch-scale decision, not a routing one.** ⛔ Do not let §12d's
*"nothing to allocate"* be read as *"allocation was worth nothing"* — it was measured at \$3.1M/yr.

### ✅ WHAT "FINALIZED" CAN AND CANNOT MEAN FROM HERE
**Eight of the nine open items are OWNER RULINGS, not analysis.** They are enumerated, each with its
measurement or with an explicit note that the measurement is missing. ⇒ **the design is as final as it
can be without those rulings, and that is a different claim from "ready to build."**
▶️ **The two that are MINE and not the owner's, and therefore the honest remaining work:** measure
decision 5's ceiling, and land §7c+§7 as one change. **Everything else waits on a ruling.**


1. **The observation source.** ✅ Measured: `setObservationSource` has zero non-test callers, so
   `_observeIfSourced` feeds the ring from the **Chainlink anchor** and `twapResolve` then checks it
   against **Chainlink**. It fires on staleness and cannot fire on manipulation. §E222's
   independent-source rule had two consumers and σ² was one; deleting σ² leaves the guard holding it
   alone. ⇒ Pin a genuinely independent source, or name Chainlink the trust root and delete the ring.
   ⛔ 1inch is not callable on chain — measured at **31.7M gas**, past a whole block.
2. ✅ **ANSWERED — the LP that wants it, out of its own carry.** `openLev` is per-LP opt-in
   (`LevManager.sol:75-81`), so the protocol funds nothing and no LP funds another's hedge. What looked
   like the design's central cost was the POOLED LIQUIDATION in disguise — see §7 and decision 7.
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
5. 🪦 **STRUCK — there is no competitive ceiling** (owner, 2026-09-11). The **~17 bps round trip** is
   still owed, but as an input to §9's realised-cost accumulator — a cost we actually pay and can
   observe on our own rebalance path — never as a ceiling on the charge.
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
| 11 | 🔴 **DELETING `proRataShortfall` — A MISTAKE THE FILE HAD ALREADY RECORDED AND I REPEATED** (`c0b3b98f`, restored 2026-09-11) | §E301 deleted it as *"restoration sizing"*; **§E313 restored it** with the lesson written out: *"two functions in one file, deleted by one argument, and the argument only fitted one of them. Check each deletion against the thing's OWN stated purpose, not against its neighbour's."* I then deleted it a **third** time, bundled with `refillNeeded` in a refill-predicate sweep — **the identical proximity error, against a row that names it.** It is the rule-17 fix for the round-trip EXIT-ORDERING attack (measured: 15.2 bps of an incumbent's principal), not restoration anything. ⚠️ **And it matters MORE under this model**: claims are pro-rata on value (§6b) while the pool can be short the asset, so first-out is an advantage — and deferral sharpens it, because whoever waits eats more. |
| 12 | **Classifying SPRINT rows by symbol-count / topic-density** (owner, 2026-09-11) | **Shortcut inference twice over.** "7 of 10 symbols gone" says a row CITES dead code; it says nothing about whether what it ASKS FOR still matters — and those are the rows most likely to be load-bearing, because the code moved out from under a need that was never served. The method is: READ the rows, RECONCILE them against each other, test against the MODEL, then check the model against code. |
