# READ THIS BEFORE TOUCHING THE SKEW OR THE REFILL

A month of commits and three concurrent threads have covered this. **77 distinct `§SKEW`/`§REFILL`
section tags are scattered across SPRINT.md's 1,424 headings** — this file exists so you do not have to
find them. Every row cites the commit that settled it. **If you are about to measure something here,
check this list first: three separate threads have re-derived the same result.**

## 1. ⛔ THE ONE THING THAT MAKES MOST REFILL WORK MOOT
**Nothing in `evm/src` executes a buy-back, and that is deliberate.** `refillNeeded` and
`proRataShortfall` had ZERO non-declaration references and were **DELETED 2026-09-09**, with
`RefillTriggerAndProRata.t.sol`, on the owner's direction that the target design has no refill
mechanism at all (`docs/actionable/TARGET-DESIGN.md`). `SwapLib`'s reservoir docblock states that
**LP entry is the ONLY refill path**, and `payRefillBonus` — which paid a trader to restore balance —
was **deleted 2026-07-22 with an explicit instruction not to rebuild it.**
⇒ **The pool never buys its own inventory back.** Any analysis of "can the premium fund the buy-back"
is about a mechanism that does not exist. It has been done anyway (see 2b) and the answer argues
*against* building one.

**AND IT IS NOT NEEDED — VERIFIED FROM THE CODE, not from the docblock (§BUYBACK-NEEDED?):** a swap
against short inventory takes a **PARTIAL FILL** and refunds the rest, it does not fail; a **redeemer is
paid in dollars from the basket and never touches range inventory**; settlement is at oracle so solvency
never depends on the balance. **Nothing breaks.** What a short range costs is *service capacity* (partial
fills) and *LP exposure* (LPs silently become dollar-holders) — real, but not an emergency.
**How it is funded:** the capital is already resident (a drain leaves the dollars behind), so only the
SPREAD costs anything — and **that spread exists under both options; the design only chooses who bears
it.** A pool buy-back makes existing LPs bear it involuntarily (measured: negative 56% of the time). An
entering LP bears the same spread **voluntarily as their cost of entry and receives shares for it**.
⚠️ **The strongest refutation, which is real and unmeasured:** scarcity is meant to attract entry via fee
capture, but scarcity also causes partial fills ⇒ less flow ⇒ *less* fee capture. **A named mechanism by
which the self-correction could invert.** See §5.

## 2. 🚫 DO NOT RE-MEASURE — settled, with the commit
| question | answer | where |
|---|---|---|
| **a. What does the skew charge across the operating range?** | **the floor, out to the crossing**; a wipeout guard, not a rebalancing incentive | **§M0 `4c9083a2`** ⚠️ re-derived by 3 threads. 🔴 **§M0's *"~0 bps to 75%"* is ONE SAMPLE** — the crossing moves 0.63→0.04 across 30–200% vol, see trap 1 |
| b. Would a pool-funded buy-back pay for itself? | **No — negative in 56% of 18 guarded samples**, median −8 bps vs a 4.2 bps charge | §REFILL-G2-VERDICT `005d6553` |
| c. Is the refill-direction exemption farmable? | **No** — a round-tripper loses ~45 bps/cycle over 5 cycles | §REFILL-FARM `37d752b4` |
| d. Does deficit manipulation pay? | **No** — victim $0.131, attacker $0.0006; gas-swamped | `c0a791ea` |
| e. Does the premium reach LPs? | **Yes**, shortfall 0. ✅ **The `totalShares == 0` path is now TESTED** — credit is 0 and the BACKING is asset-dependent: ETH stays QU!D backing, **BTC is netted out of redeemable one-for-one**, so with no shares it backs nobody | §E5 `040c452f` · §NO-LP-PREMIUM |
| f. Are we cheaper than Uniswap? | **Yes, by 17–26 bps** at every size we can serve | `844dd359` |
| g. Does inflating flow via wash trading cheapen a drain? | **No — it makes the attacker's own drain DEARER.** Self-defeating. The real vector is patience | `b560f57c` |

## 3. 🚫 DO NOT RE-ATTEMPT — built, measured, reverted
· **Raise Γ** → Γ is a *derivation* (`FLOW_HALFLIFE·WAD/365d`), not a dial. Raising it re-opens the
  circularity its derivation removed. §GAMMA-IS-NOT-A-DIAL `c8fe166a`
· **Make κ scale with σ²** → BUILT, MEASURED, REVERTED: re-introduces a ceiling, +403 bytes on a
  contract with little headroom. `99aaf2d6`
· **Make the exponent ρ scale with σ²** → same test failure by a different mechanism. `320fc415`
· **Pay the restoring side (A–S's mid-shift)** → that *is* `payRefillBonus`. See 1. §REFILL-OPTION-F
· **Recover `refillPlacement`** → it is *placement, not acquisition*; it cannot conjure inventory. It
  gives a re-ranger, not a restoration mechanism.

## 4. ⚠️ THE FOUR TRAPS — each has produced a confident, published, WRONG conclusion
1. **A minimum charge (420 ppm) binds below the crossing.** Sweep trade size in that region and you
   get a flat number; it is the floor, not the scarcity price. **Cost: 18 samples, one whole verdict.**
   🔴 **AND "~55%" — WHICH THIS LINE USED TO STATE AS THE CROSSING — IS ONE SAMPLE, NOT A CONSTANT.
   MEASURED out of the real `skewWad`: q < 0.6324 at 30% vol · q < 0.1891 at 80% · q < 0.0367 at
   200%. A 17× spread, so the trap's own figure walked into the trap.** §SESS-A1-SKEW-SWEEP,
   `evm/test/SkewFloorAndSigmaFreeShare.t.sol`
2. **An "unmeasured variance" sentinel returns a flat 3%.** Fork at a block without warming variance and
   rows look *favourable*. **Cost: a sweep that reported +297 bps of coverage.** Guard: assert σ² > 0
   *and* reject a charge of exactly 3%.
3. **The charge is NOT proportional to volatility** — it contains a term that does not scale with it
   (exactly 210 per unit of drain). Doubling σ² gives a ratio below 2.00.
   §SIGMA-COUNT-BROKEN `eb0788c4`
   🔴 **BUT "1.57–1.86" IS THAT ROW'S FIXTURE, NOT THE KERNEL'S PROPERTY.** It starts at `q0 = 0.5`; from a
   flush start the σ²-free share is **2.6%–10%**, i.e. ratios of **1.90–1.97**. The share falls as
   scarcity rises. §SESS-A1-SKEW-SWEEP
4. **`q` is inventory scarcity `(target−inv)/target`, NOT drain size.** Sizing a drain as a fraction of
   target does not control `q`: a pool holding more than its target charges the floor at any size.

## 5. ✅ THE ACTUAL OPEN QUESTION — **LINK 2 IS NOW MEASURED. IT HOLDS ABOVE THE CROSSING AND IS
ABSENT BELOW IT.**
The design says: price scarcity, and LP entry restores. **Link 1 was verified; link 2 now is too, and
the answer is conditional.** `sims/refill_incentive.js` (controls reproduce the Solidity readings):
an entrant is **not paid the yield they see on arrival** — entry lowers q *and* raises the
`feeIncrements` denominator, so it is doubly dilutive. Post-entry yield, 10% of target, 80% vol:
**q=0.05 → 3.818 bps · q=0.15 → 3.818 · q=0.25 → 3.818 · q=0.55 → 11.333 · q=0.95 → 40.897 (10.71×).**
⇒ ✅ **a real 10.71× gradient above the crossing**, and 🔴 **EXACTLY FLAT below it** — three arrival
scarcities, one identical yield, because entry pushes the rate back onto the floor every time.
**Over the floor band the mechanism meant to summon the refill is not weak, it is ABSENT** — and on a
calm tape that band is 63% of the range. **This is the same finding as trap 1, seen from the other
side.** ⚠️ **Link 3 (does a given yield actually attract capital?) is still unmeasured and needs a
supply elasticity this system has no data for.**
**The partial-fill inversion is real and splits in two:** REGION 1, the floor band — unconditional,
but the fall is only ~0.3%, so the finding is *no gradient*, not a strong inversion; REGION 2, beyond
the revenue peak (q = 0.93 / 0.86 / 0.78 for mean sizes 5% / 15% / 40% of target) — a genuine
inversion, **but conditional on a size distribution this system does not observe.**
**And the likely cause is identified:** the target the charge measures against is **gross flow**, so a
steady one-way drain and balanced churn are indistinguishable to it (`Core.sol` says this outright).
Volatility is the right input for *how costly* being short is; it is the wrong one for *how fast*
inventory is leaving. Today's target has no safety margin at all.
▶️ **The target-side route is VERIFIED to be invisible to the linearity test that killed κ(σ) and ρ(σ)**
— the target is a *parameter* to the pricing function, not derived inside it.
🔴 **Blocked on:** the signed flow measure is cumulative and undecayed while gross is a decayed average
(an incoherent ratio, and no decayed signed register exists), and its own declaration forbids money-path
reads until the relationship is derived on this system's balance sheet. **That gate is correct.**
⇒ **Next MEASUREMENT, not next commit.**

## 6. Where the prose version lives
⛔ `docs/informational/SKEW-AND-REFILL.md` is DELETED (2026-09-11). It described the scarcity kernel and an
expected-flow reserve target as LIVE, and both are gone — `wellSkew`/`sellSkew` return a flat 420 ppm. Its
central claim, *"restoration happens by ordinary entry"*, is the one the model explicitly rejected: §PLP-T
calls organic counter-flow *"not a mechanism — a hope"*, and §6 replaces it with a PAID dated claim
rather than for acting.
