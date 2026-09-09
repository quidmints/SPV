# READ THIS BEFORE TOUCHING THE SKEW OR THE REFILL

A month of commits and three concurrent threads have covered this. **77 distinct `§SKEW`/`§REFILL`
section tags are scattered across SPRINT.md's 1,424 headings** — this file exists so you do not have to
find them. Every row cites the commit that settled it. **If you are about to measure something here,
check this list first: three separate threads have re-derived the same result.**

## 1. ⛔ THE ONE THING THAT MAKES MOST REFILL WORK MOOT
**Nothing in `evm/src` executes a buy-back, and that is deliberate.** `refillNeeded` and
`proRataShortfall` have ZERO non-declaration references. `SwapLib`'s reservoir docblock states that
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
| **a. What does the skew charge across the operating range?** | **~0 bps to 75% depletion**; a wipeout guard, not a rebalancing incentive | **§M0 `4c9083a2`** ⚠️ re-derived by 3 threads |
| b. Would a pool-funded buy-back pay for itself? | **No — negative in 56% of 18 guarded samples**, median −8 bps vs a 4.2 bps charge | §REFILL-G2-VERDICT `005d6553` |
| c. Is the refill-direction exemption farmable? | **No** — a round-tripper loses ~45 bps/cycle over 5 cycles | §REFILL-FARM `37d752b4` |
| d. Does deficit manipulation pay? | **No** — victim $0.131, attacker $0.0006; gas-swamped | `c0a791ea` |
| e. Does the premium reach LPs? | **Yes**, shortfall 0 — except an untested `totalShares == 0` path | §E5, `040c452f` |
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
1. **A minimum charge (420 ppm) binds below ~55% depletion.** Sweep trade size in that region and you
   get a flat number; it is the floor, not the scarcity price. **Cost: 18 samples, one whole verdict.**
2. **An "unmeasured variance" sentinel returns a flat 3%.** Fork at a block without warming variance and
   rows look *favourable*. **Cost: a sweep that reported +297 bps of coverage.** Guard: assert σ² > 0
   *and* reject a charge of exactly 3%.
3. **The charge is NOT proportional to volatility** — it contains a term that does not scale with it
   (exactly 210 per unit of drain). Doubling σ² gives a ratio of 1.57–1.86, never 2.00.
   §SIGMA-COUNT-BROKEN `eb0788c4`
4. **`q` is inventory scarcity `(target−inv)/target`, NOT drain size.** Sizing a drain as a fraction of
   target does not control `q`: a pool holding more than its target charges the floor at any size.

## 5. ✅ THE ACTUAL OPEN QUESTION
The design says: price scarcity, and LP entry restores. **Only the first link is verified.** Nothing
shows an entrant's expected return rises enough with scarcity to pull them into a pool that is short the
asset, nor how fast.
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
`docs/informational/SKEW-AND-REFILL.md` — the same picture without symbols or line numbers, for reading
rather than for acting.
