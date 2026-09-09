# L5 — §KAPPA-SIGMA: the σ-scaled pole was BUILT, MEASURED, and REVERTED. The finding is a design fork, not a patch.

*(Booked here rather than in `SPRINT.md` because the Bitcoin thread has uncommitted `§SEQ-AUDIT` edits
in that file and rule 14c makes staging it by name a sweep of their work. Fold at the next merge pass.)*

## WHAT WAS BUILT
`SwapLib.KAPPA_WAD` (a constant) → `_kappaWad(sigmaSqWad)`, per A–S §2.3's `q* = √(2ω)/(γσ)`:
`κ(σ) = KAPPA_REF·√(σ²_ref/σ²)`, clamped at `KAPPA_REF = 1e18` so κ never RISES (the §E289 gate —
raising κ needs a restoration mechanism, lowering it does not). The kernel's `kMinusQ1 == 0` guard
became `q1 >= kappa`, because a σ-scaled κ can sit BELOW `q1` and the subtraction would underflow.

▶️ **IT COMPILES AND IT IS NOT FREE: `SwapLib` 23,999 → 24,402, +403 bytes, 174 to spare.** On the
contract this file's own table calls the binding one. That alone is an argument against landing it
speculatively.

## 🔴 WHY IT WAS REVERTED — the two reds are CORRECT and they were written for this
`SkewLearningsAreLive.t.sol`, 2 failed / 181 passed. Both are the sentinel firing where the tests
expect finite values, and **`test_E287_SkewIsNotPinnedToAConstant`'s docblock anticipated this exact
change and states the condition for accepting it:**

> ⇒ **IF THIS FAILS, SOMETHING RE-INTRODUCED A CEILING.** That may be right! But re-derive it:
> measure the premium against the integral at q=0.6..0.95 and show the clamp does not void §E68.

**I cannot discharge that condition.** Measured against the fixture (`TARGET` 2e6, `POOL` 1e6), the
test doubles σ² to check linearity, and at 2σ² κ = 0.7071:

| probe | q | κ at σ²=1e18 | κ at σ²=2e18 | result at 2σ² |
|---|---|---|---|---|
| a (`inv = POOL·0.30`) | 0.8500 | 1.0 finite | 0.7071 | 🔴 **SENTINEL — past the pole** |
| b (`inv = POOL·0.60`) | 0.7000 | 1.0 finite | 0.7071 | finite (barely) |
| c (`inv = POOL·0.90`) | 0.5500 | 1.0 finite | 0.7071 | finite |

⇒ **above q ≈ 0.71 the whole q=0.60–0.95 band goes to the sentinel.** That is a ceiling over most of
the exact band §E274/§E286 measured a ceiling discarding **51.4%** of §E68's integral. The change
re-introduces, at high vol, the thing that work removed.

## ⛔ AND NO CALIBRATION FIXES IT — THIS IS THE MECHANISM, NOT THE LEVEL
My first instinct was that `σ_ref` was set too low (I picked 100% vol because it made the no-op
boundary land exactly on today's behaviour — **a convenience calibration, which is the same species of
move I had just criticised Γ for**). It is not the level. **A linearity test DOUBLES σ², so it crosses
whatever reference you pick**, and above that reference the integral is voided by construction.
⇒ **A σ-scaled pole and an unclamped premium integral are INCOMPATIBLE above the reference vol.**

## ⏸️ THE OWNER FORK (rule 16 — a design decision is not a closure)
| | keep | give up |
|---|---|---|
| **(A) σ-scaled κ** | the reserve tightens when restoration is dearest; drains stop at q=0.16 at 200% vol | §E68's integral above σ_ref; the range refuses depth it advertises |
| **(B) constant κ (today)** | the unclamped integral, §E274/§E286 intact | the reserve stays LOOSEST exactly when the refill can least afford to be called |

## ⭐ AND THE BETTER VERSION, WHICH IS WHAT RULE 18 ASKS FOR AND IS UNMEASURED
**Scale the barrier EXPONENT, not the pole's location.** `skew = Γσ²·q/(κ−q)^ρ(σ)` with κ pinned at
1e18. That steepens superlinearly in σ — which is A–S §2.3's actual content — **without moving the
pole, without a new sentinel branch, and without a ceiling**: it is still unbounded at q→1, so §E68's
integral survives at every σ². ρ is `STABLENESS`, deleted as dead code when it was 1 (`for (i=1; i<1;)`
never executed), so reviving it is a known shape.
🔴 **DO NOT LAND IT UNMEASURED.** `∫ q/(κ−q)^ρ dq` has no closed form as cheap as the current `ln`
one, and `SwapLib` has **174 bytes**. Measure the integral's cost first; if it does not fit, that is
the answer and not a detail.

▶️ **NEXT:** (1) owner rules on (A) vs (B); (2) if the answer is "neither, steepen instead", price the
ρ(σ) integral in bytes BEFORE writing it. The A–S derivation, the elastic-demand measurement and the
controls are `sims/kernel_shape.js` + `§GAMMA-FIRST-PRINCIPLES-2026-09-09`.

---

# §IL-BASIS-ON-A-SECOND-ENTRY — answered from code, 2026-09-09

**There is no averaging and no overwrite, because there is no second entry.** `RangeLib.openPos:214`
is `pos[lp] = p` — a WHOLESALE OVERWRITE — and it is unreachable for an existing LP because
`LevManager.openLev` reverts `AlreadyOpen`. §E339's note at that line already prescribes the fix for
the day a top-up path exists: **blend `ilBasisPx` SIZE-WEIGHTED, in the SAME commit that opens the
path** — *"the defect is this assignment, not its caller"*. Both directions are wrong today and the
second is an attack: top up after a rise and the LP destroys its own protection (the target is 0 at or
below entry); **dust top-up at a low re-anchors the basis of the WHOLE position downward and the
protocol pays protection nobody bought.** Size-weighting is what kills the dust version.
📌 Close-and-reopen is NOT that attack — it realises the position and the new basis is the live price,
so an LP can never set a basis lower than where they actually re-entered.
⚠️ `RangeLib.reanchorIfReseated` carries the mirror hazard and is already guarded: §C19,
**DO NOT write `q.ilBasisPx` on a reseat** — it would cap accumulable IL at one half-range (98.5 bps
at `RANGE_DELTA = 200`) and make `venue.borrow` unreachable by construction, silently.

---

# §RHO-AND-THE-LINEARITY-WALL — 2026-09-09. **I was wrong about the integral. And the wall is neither κ nor ρ.**

## ⛔ CORRECTION TO `99aaf2d6`'s COMMIT MESSAGE, MADE BY ITS AUTHOR
That message says *"the integral has no cheap closed form"*. **FALSE.** `∫ q/(κ−q)^ρ dq` is exact and
cheap. With `u = κ−q`:
```
F(q) = u^(1−ρ) · [ u/(2−ρ) − 1/(1−ρ) ]        qBar = (F(q1) − F(q0)) / Δ
```
**ONE `powWad` per endpoint** (because `u^(2−ρ) = u^(1−ρ)·u`), i.e. two per swap — not four, and not
a series approximation. Verified against numeric integration at ρ ∈ {1.2, 1.5, 2.5, 3.0} over
q ∈ {[0.1,0.5], [0.6,0.9], [0.8,0.95]}: **relative error ≤ 6.7e-11 in all twelve cells.**
⚠️ ρ = 1 is a genuine pole in the formula (`1/(1−ρ)`), so the existing `ln` branch stays as the ρ=1
case. That is a branch, not an obstacle.

## 🔴 AND IT DOES NOT MATTER, BECAUSE ρ(σ) HITS THE SAME WALL κ(σ) DID — MEASURED
`test_E287_SkewIsNotPinnedToAConstant` asserts **skew is LINEAR in σ²** (doubling σ² doubles the
reading, 2% tolerance). A σ-dependent ρ is not linear in σ²:
| probe | q | ρ 1.000 → 1.500 | ratio TODAY | ratio with ρ(σ) |
|---|---|---|---|---|
| a | 0.850 | | 2.0000 ✅ | **3.7027 🔴** |
| b | 0.700 | | 2.0000 ✅ | **2.9642 🔴** |
| c | 0.550 | | 2.0000 ✅ | **2.6000 🔴** |

⇒ **THE BLOCKER IS NOT THE POLE'S LOCATION AND NOT THE BARRIER'S EXPONENT. IT IS THAT ONE TEST
FORECLOSES EVERY VOL-SENSITIVE SHAPE.** κ(σ) fails it by re-introducing a ceiling; ρ(σ) fails it by
breaking linearity. **Different mechanisms, same assertion, and the test cannot tell them apart** —
it uses linearity as a scale-free PROXY for "no ceiling", and its false-positive class (a DELIBERATE
σ-dependent shape) is unnamed. Per the standing sweep rule, a guard whose false-positive class is
unnamed is not yet a finding about the code.

## ⭐ AND THE TEST IS DEFENSIBLE, WHICH IS WHY THIS IS A FORK AND NOT A BUG
**A–S §2.2 IS linear in σ²** (`r = s − qγσ²(T−t)`), so the test encodes §2.2 faithfully. **A–S §2.3 is
NOT** — its pole at `2ω − γ²q²σ²` moves with σ. The tree cites BOTH sections in different places
(`SwapLib:766-770` is §2.2's finite-horizon form, `:1030-1031` is §2.3's stationary one, per
`0505a993`). ⇒ **"should the reserve be vol-sensitive at all?" is a question about WHICH SECTION WE
ARE IMPLEMENTING, and it has never been asked.** Everything else here is downstream of it.
⛔ **DO NOT "FIX" THE TEST TO LAND A SHAPE.** Its docblock names the discharge: measure the premium
against §E68's integral at q=0.6–0.95 and show the clamp does not void it. Any change to it must
carry that measurement.

---

# ⛔ §WASH-INFLATES-THE-TARGET IS **RETRACTED BY ITS AUTHOR, ONE COMMIT LATER — THE SIGN IS BACKWARDS**

I wrote *"higher `target` ⇒ lower q ⇒ CHEAPER drain"* in `320fc415`. **It is the opposite, and
`Core.sol:240` said so in plain words while I was reading the same file:** *"higher `target` ⇒ lower
`inv/target` ⇒ scarcity actually prices."* Measured from `SwapLib:1519`'s own expression
`q1 = (target − inv1)·1e18/target`, inventory fixed at 50:

| target | q | qBar | skew |
|---|---|---|---|
| 60 | 0.1667 | 0.200 | 7.01 bps |
| 100 | 0.5000 | 1.000 | 35.07 bps |
| 200 | 0.7500 | 3.000 | 105.21 bps |
| 400 | 0.8750 | 7.000 | 245.48 bps |

⇒ **HIGHER TARGET ⇒ HIGHER q ⇒ DEARER DRAIN.** So a wash trade that inflates gross flow makes the
attacker's own drain MORE expensive. **It is self-defeating, and the row as written was wrong.**
⭐ **THE REAL VECTOR IS THE MIRROR IMAGE: PATIENCE.** Stop trading, let the 48h EWMA decay, drain
against a small `target`. Same shape as §UNIT-B-PATIENCE, which the tree already booked for σ².
📌 **AND THAT VINDICATES THE 48h CONSTANT I CRITICISED.** `Core.sol:181` picks a *"wide,
manipulation-resistant memory"* — and WIDE is exactly what makes the wait expensive. Since
`Γ = γ·T_flow`, a wider window also raises Γ, so manipulation-resistance and the risk horizon pull the
SAME direction. **The 48h reuse is better justified than §GAMMA-FIRST-PRINCIPLES gave it credit for**;
what stands from that row is only that γ = 1 is log utility presented as a normalisation.

## (the retracted row follows, kept because the mechanism half is still true)
# ~~§WASH-INFLATES-THE-TARGET~~ — the discriminator is BUILT BUT UNREAD

`skewWad`'s `q = (target − inv)/target` where **`target = Core.skewTargetUsd() = flowEwmaUsd() +
redeemEwmaUsd()` — GROSS flow only** (`Core.sol:272-276`). A higher `target` gives a LOWER `q`, which
gives a **CHEAPER DRAIN**. `Core.sol:246-251` states the vector and the fix in one breath:

> *"`flowEwmaUsd` (GROSS) and `netFlowUsd` (SIGNED) are a **matched pair, and the pair IS the
> wash-trading discriminator** — §E326 measured it: over a round trip `flowEwmaUsd` went
> `0 → 49,999,999,999 → 99,994,054,053` while the position netted to ~$6, so a one-directional drain
> and a balanced round trip look identical to gross alone."*

⇒ **A ROUND TRIP NEARLY DOUBLES `target` WHILE NETTING ~$6.** ⛔ **AND `netFlowUsd` IS NEVER READ BY
THE SKEW.** The same docblock says the check is *"before it is built"* — so the counter exists, the
measurement exists, and nothing consumes it. `skewTargetUsd` is by its own docblock *"the ONE place
the two flow sources are composed"*, which makes it the one place a fix lands.
⛔ **AND `netFlowUsd` CANNOT BE WIRED AS I IMPLIED — TWO BLOCKERS, BOTH IN ITS OWN DECLARATION.**
1. **IT IS CUMULATIVE, NOT DECAYED.** One write site (`Core.sol:1091`, `netFlowUsd += usdLeg`) and no
   decay anywhere. The gross leg is a 48h EWMA. **A ratio of a lifetime total to a decayed window is
   unit-incoherent** — there is no existing decayed SIGNED register to pair with.
2. **ITS DOCBLOCK FORBIDS THE USE:** *"THIS IS AN INSTRUMENT, NOT A PRICE. Nothing reads it on the
   money path and nothing should until the mapping is derived on OUR balance sheet — their risky asset
   sits OUTSIDE the reserve and ours sits INSIDE it, so travel changes the basket's COMPOSITION rather
   than its size and their eq. (15) cannot be lifted."*
✅ **WHAT SURVIVES, AND IT IS THE USEFUL HALF — the same docblock names the real gap outright:**
*"the failure it exposes is SILENT: a basket draining steadily in one direction reads, today, exactly
like a balanced one."* ⇒ **`target` cannot tell CHURN from DRAIN.** Heavy two-sided flow inflates gross
and makes drains dearer although inventory never moved; a steady one-directional drain looks the same.
**That is the mispricing the κ/ρ work was groping at from the wrong end.**

## 📌 CONSEQUENCE FOR "REMOVE THE 48h CONSTANT" — IT CANNOT BE REMOVED, AND HERE IS WHY
`τ = I/F`. `I` is observable (`target − inv`). **`F` is NOT**: the register holds a decayed VOLUME,
and `T_flow` is the units bridge that turns that stock into a rate (`F ≈ flowEwma/T_flow`). Substituting
gives `τ = q·T_flow` — **`T_flow` does not cancel.** ⇒ 48h is not a free parameter standing in for an
observation; it is the DIMENSION that makes the observation a rate. It can be made honest, not deleted.
⭐ **What IS removable is the second-guessing: it is already ONE window** (`FLOW_HALFLIFE` =
`Core.FLOW_DECAY`'s half-life = Γ's horizon), so there is no drift to fix — only the §WASH row above,
which is about the window's CONTENTS rather than its width.

---

# ✅ §REFILL-NEEDS-NO-FUNDING — answered from the code's own design statement, `SwapLib:1697-1718`

**The question "how do we fund the refill" may not have a referent.** The shipped design says there is
no funded refill:

> *"RESERVOIR REFILL DESIGN (the pump) — how the reservoir refills, and **why the skew is all that is
> needed**: 1. PRIMARY REFILL — LPs stake, pulled in when the pool is scarce because scarcity ⇒ more fee
> capture. **This mechanism already exists; the reservoir self-refills through ordinary LP entry — no
> bespoke machinery, no keeper, no RFQ, no external-MM solicitation.** 2. FAST TOP-UP — LP entry is the
> ONLY refill path. … So the skew's whole job is to PRICE the scarcity. **The refill is a PERMISSIONLESS
> response to a public on-chain price**: the skew is our reservation price, captured by whoever refills
> first (a gas race), never an operator-tuned or bid mechanism."*

⛔ **AND IT NAMES THE ANTI-PATTERN EXPLICITLY:** `payRefillBonus` was DELETED 2026-07-22 and the
docblock says *"Paying a swapper a bonus is precisely what the removal stopped — do NOT rebuild it."*
⇒ **An imbalanced range is a PRICED STATE, not an emergency.** Nothing is insolvent: the drainer paid
a premium that reached LPs (`ISkewSink.creditSkewPremium` → `USD_FEES`, §E5/§E132), the range settles
at oracle, and scarcity raises the reward for the next entrant. The protocol does not buy inventory
back, so it has no cost to fund.
🔴 **THIS CONTRADICTS THE ACTIVE REFILL WORK AND THE CONTRADICTION IS THE ITEM.** §REFILL-G2-VERDICT
concludes *"the premium is not sized to fund the refill"* — a true statement about a mechanism this
docblock says should not exist. **One of the two is stale and they are in the same tree.** ▶️ Settle
WHICH before either thread builds further: is the refill (a) LP entry responding to a public price
(shipped design, needs no funding), or (b) a protocol-executed buy-back (needs funding, and §E276's
*"the refill direction is exempt rather than paid"* is the gap)? **Do not answer it from either
docblock — both are prose. Ask what executes the buy-back today and who pays its gas.**

---

# ⭐ §THE-THIRD-OPTION — **put the vol-sensitivity in the TARGET, not the kernel. And the deeper point: σ² was never the reserve's driver.**

## WHY EVERY SHAPE ATTEMPT COLLIDED WITH ONE TEST
κ(σ) and ρ(σ) both fail `test_E287_SkewIsNotPinnedToAConstant`. I read that as the test over-reaching.
**It is not.** `skew = Γ·σ²·qBar(q)` already carries σ² **once, linearly** — which is A–S §2.2 exactly.
Every attempt to make the SHAPE vol-sensitive was a **SECOND appearance of the same σ²**, and the
linearity assertion is precisely what detects a double-count. ⇒ **The test was right to reject all of
them, and for a better reason than the one it states** (it says "a ceiling"; the general case is "σ²
used twice").

## AND THE REAL DRIVER IS NOT PRICE VARIANCE AT ALL
**What empties a range is DIRECTIONAL FLOW, not price variance.** Price variance is already priced,
linearly, in `Γσ²`. Reaching for it again to size a reserve is reaching for the signal we have because
the one we need is unmeasured. `netFlowUsd`'s docblock names the missing quantity exactly: *"a basket
draining steadily in one direction reads, today, exactly like a balanced one."*

## THE SHAPE, AND WHY IT DODGES EVERY WALL THE OTHER TWO HIT
`skewWad(poolVolUsd, **flowUsd**, sigmaSqWad, rk, drainUsd6)` — **`target` is a PARAMETER**, and the
linearity test supplies it directly (`TARGET = 2_000_000e6`). So changing how `Core.skewTargetUsd()`
COMPUTES it is invisible to that test, and the kernel stays exactly linear in σ² for a fixed target.
| wall | κ(σ) | ρ(σ) | target-side |
|---|---|---|---|
| linearity test | 🔴 ceiling | 🔴 non-linear | ✅ invisible — target is an argument |
| §E68's integral | 🔴 voided above σ_ref | ✅ | ✅ untouched |
| new sentinel branch | 🔴 required | ✅ | ✅ none |
| `SwapLib` bytes (577 left) | 🔴 +403 measured | 🔴 2 `powWad`/swap | ✅ **zero — SwapLib untouched** |
| §E289's κ gate | 🔴 engages | ✅ | ✅ κ stays 1e18 |
⭐ And it lands in `skewTargetUsd()`, which its OWN docblock calls *"the ONE place the two flow sources
are composed … so if the two sources are ever to be weighted differently that is a change to one
function rather than to two money-path call sites that could drift apart."* **Purpose-built for this.**
✅ **THE SIGN IS RIGHT, which is what the retraction above establishes:** higher `target` ⇒ dearer
drain. So "more reserve when the world is riskier" means **`target` RISES with risk** — the newsvendor
safety-stock shape, and the current target is pure mean flow with **no safety term at all**.

## ⏸️ WHAT BLOCKS IT — one derivation and one register, both named
1. **A DECAYED SIGNED REGISTER.** `netFlowUsd` is cumulative; gross is a 48h EWMA; the ratio is
   incoherent. ⚠️ **This is a rule-23 declaration and must answer rule 23's third question — what does
   it let me DELETE? Answer: the entire vol-sensitive-SHAPE line of work** (κ(σ), ρ(σ), the σ-scaled
   sentinel branch, and the +403 bytes), because the reserve then comes from the quantity that actually
   drives it. That is a real deletion, not a nicety.
2. **THE MAPPING `netFlowUsd`'s DOCBLOCK DEMANDS** — *"their risky asset sits OUTSIDE the reserve and
   ours sits INSIDE it … their eq. (15) cannot be lifted."* Until that is derived on our own balance
   sheet, nothing may read it on the money path. **That gate is correct and I am not arguing with it.**
▶️ **SO THIS IS THE NEXT MEASUREMENT, NOT THE NEXT COMMIT.** It is also the FIRST framing in which the
reserve question and the "does the refill exist" question are the same question: if `target` priced
directional drain, scarcity would price itself correctly and LP entry — the only refill path the
shipped design has — would be pulled in at the right moment by construction.
