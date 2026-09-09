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
