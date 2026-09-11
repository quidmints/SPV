# ~~The skew, the reserve, and why there is no refill to build~~ — 🪦 RETIRED 2026-09-11

⚠️ `docs/informational/` is prose and goes stale against the contracts. **This file went stale
wholesale**, and is kept as a stub rather than deleted because its second half was RIGHT and is worth
carrying.

## What replaced it

There is no skew. `wellSkew` and `sellSkew` both return a flat **420 ppm**
(`SwapLib.MIN_SWAP_SKEW_WAD`), and the scarcity kernel this file describes — *"as inventory falls
relative to expected flow, drawing more of it down costs more"* — is deleted, along with Γ, κ, ρ, σ²
and the flow EWMAs that fed it.

**Why, in one sentence:** the charge depended on MEASURED STATE THAT THE PRICED COUNTERPARTY COULD
STARVE. Two vectors were measured, not imagined — *patience* (stop trading, let the 48h flow EWMA
decay, and the target shrinks toward the inventory you mean to drain) and *clock-stretching* (space
one drain's slices four hours apart, σ² falls ~24× and the charge with it, for the same total size).
The owner's rule settles it: **"anything that can be gamed is useless."** A constant cannot be
starved, so both attacks become unconstructible rather than defended against.

⇒ Current state: `docs/actionable/TARGET-DESIGN.md`.

## ⭐ WHAT THIS FILE GOT RIGHT, AND IT OUTLIVED THE SKEW

> *"A recurring instinct is that the pool should buy its inventory back after a large withdrawal, and
> that the charge collected should pay for that. The pool does not do this, nothing in the contracts
> does it, and the design rejected it explicitly."*

**Still true, and now structural rather than a policy choice.** Restoration happens by ordinary
entry: a depleted pool is a more attractive pool to join, the entrant brings the asset, and balance
returns. Nobody is paid a bonus, no keeper is scheduled, no external venue is required, and the pool
never spends its own reserves to trade. A later measurement sharpened it — an unconditional bundled
refill **loses money for LPs more often than not** — so the instinct is not merely unbuilt, it is
refuted.

📌 The one piece of the old framing that survives as an OPEN question is the second job the file
names: the charge *"is meant to summon whoever will put inventory back"*, and it calls that step
unverified. It still is. Under a flat fee the summoning argument rests entirely on entry economics,
which is where §4's competitive ceiling and the sell-in capacity term live.
