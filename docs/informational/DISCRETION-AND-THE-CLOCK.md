# Discretion and the clock — what the pool may decide, and when

⚠️ `docs/informational/` is prose and goes stale against the contracts. Symbols
cited here (`rate_bps`, `crowding_bps`, `sol_star_haircut_bps`, `registered_mints`)
were live in `svm/programs/quid/src` when written; check the code before quoting.

The pool holds depositors' dollars and SOL while carrying the other side of every
borrower's position. That creates a standing temptation with a respectable name:
*wait for a better price*. This document draws the line between the version of
that which is a treasury policy and the version which is an unpriced option
depositors wrote and were never paid for.

## The edge is netting, not skill

State the thesis as **structural**, never as forecasting ability.

The pool is short the **net** per ticker, not the gross. Alice long 100 and Bob
short 100 leaves it flat — instantly, at zero cost, on a weekend, with no venue
open. No individual trader can net across a book they do not have. And on the
netted portion the pool **has no liquidation price at all**, which is the entire
reason it can wait where a levered trader cannot.

That claim needs no forecast, survives being wrong about direction, and can be
explained to a depositor. "We trade better than individual traders" is a skill
claim that has to keep being true, funded by people who did not opt into it.
Only the first one is defensible, so only the first one is the thesis.

⚠️ **Liquidation levels here are on-chain and deterministic.** Anyone can compute
them from public state. Acting ahead of a liquidation the whole world can see is
market-making; acting on non-public knowledge of when customers must transact is
front-running. The distinction survives only while the levels stay computable
from published state — do not introduce a private trigger.

## Overpaying is a PRICING problem, and the program already solves it correctly

If the pool cannot realise the mark, **the mark is wrong**, and the fix belongs in
the mark.

The worked example is already in `ProgramConfig`: parked SOL is credited at
`sol_star_haircut_bps` because the unpark round trip costs ~40 bps. The pool does
not pay out full value and reconcile later — it marks at what is realisable,
ex ante, visibly, with no discretion at the moment of payout. That IS "protect
depositors from overpaying," expressed as a price.

Deferring settlement to catch up later is the same economics in disguise:
unpriced, invisible, and exercised at the operator's convenience.

## Why deferral is not merely inelegant here — it breaks the invariant silently

`D ≥ S + L` (backing ≥ supply + claims) **has no on-chain check.** It holds
*implicitly, by conservation*: every operation moves `D` and `S + L` together, so
a non-negative start stays non-negative. The only thing actually asserted is
`POOLED_USD ≤ TVL`.

A discretionary timing gap is **not conservation-neutral**. The borrower's claim
settles at one price; the hedge unwinds at another; `D` moves while `S + L` does
not. Nothing catches it, and it accumulates across every position that took
profit early. The breach is silent by construction — which is exactly what makes
the invariant's implicit-ness dangerous rather than elegant.

The prior audit reached the same place from the other side: **`LP.pooled`
deferral is legitimate ONLY for operational illiquidity (venue thaw), never to
defer a gap** — and the removed `arbETH` cluster carried its own confession,
*"first-out LPs are made whole at the expense of remaining-LP backing share."*

## "Good for everyone involved" names the wrong set

Once a borrower has taken profit and been paid, they are no longer involved. The
only parties still carrying the position are depositors. So "wait until the price
is good for everyone" collapses to "good for depositors" — a fine goal, and the
one to write down, because the longer phrase conceals who is waiting.

## THE LINE

> Discretion over **whether and when to hedge our own balance sheet** — permitted.
> That is the pool's own risk, already priced by `rate_bps()`.
>
> Discretion over **when a customer is paid** — not permitted. That is their
> money, and it converts depositors into involuntary unsecured creditors of a
> directional bet they cannot see.

## THE POLICY IS ITSELF INFORMATION — the problem that decides the design

Everything the pool does is on-chain, so **a decision not to hedge is observable**,
and an observable decision is a signal.

The failure is not "a borrower sees no hedge and closes." That case is harmless:
short duration, fee earned, no risk carried. The failure is SYSTEMATIC. If
borrowers close whenever the pool does not follow them, the only positions that
persist are the ones the pool already hedged, or the ones running against it. The
book becomes selected against the pool. That is Glosten–Milgrom adverse
selection, and it degrades slowly enough to be mistaken for bad luck.

⭐ **THE RESOLUTION IS THE SAME ONE THE REST OF THIS DOCUMENT ARGUES FOR, REACHED
FROM A COMPLETELY DIFFERENT DIRECTION — WHICH IS THE STRONGEST EVIDENCE IT IS
RIGHT.**

- A **discretionary** policy emits a signal. Not-hedging is then a CHOICE, choices
  carry information, and borrowers correctly infer a view. Operating that safely
  needs ambiguity as cover ("maybe we are waiting to net") — and the opacity that
  provides cover is precisely what creates the inference.
- A **derived, published** policy emits none. If the trigger is
  `net > f(reserve, spread, σ)` with `f` computable from published state, then "no
  hedge" tells a borrower EXACTLY ONE THING: the net has not crossed yet. Nothing
  about direction, nothing about a view — because there is no view. There is
  nothing to infer, so there is nothing to trade against.

⇒ **The pool does not need an excuse. It needs the rule to be public enough that
nobody has to guess.**

## TIMING THE CLOCK — the canon exists, and it is already implemented once

This is the **impulse-control problem with fixed transaction costs**: inventory
following a stochastic process, a lumpy cost to adjust it, a running cost to carry
it (Constantinides; Janeček–Shreve). It is the same problem solved on the EVM side
as `LevMath.noTradeBandBps`, and the same cube root ports:

```
h³ = g / (C · K)
```

| term | EVM meaning | meaning here |
|---|---|---|
| `g` | gas cost of one rebalance | cost of one hedge ticket: spread + impact + the **$100k lumpiness**, which is a genuine fixed cost and exactly the assumption the model wants |
| `C` | position collateral | net notional in that ticker |
| `K` | concentrated-liquidity LVR coefficient | risk coefficient, taken from the GPD/EVT tail machinery already in `etc.rs` (ξ, β, ES_α) rather than invented |

Same properties: wide band on a small net, tight on a large one, scaling as the
CUBE ROOT of size — so a stepped or linear rule is distinguishable from it by
measurement. And decisively: **derived means publishable, and publishable means
signal-free.**

⚠️ **WHERE THE CANON DOES NOT REACH, AND WHAT COVERS IT.** Classical impulse
control assumes the state is EXOGENOUS. Here it is not — the pool's behaviour
changes borrower behaviour. Two mechanisms close that gap and both already exist:

1. **Publish the rule.** Flow then responds to a fixed, computable rule rather
   than to individual acts. The rule is a fixed point anyone can solve, and there
   is no edge in solving it.
2. **Price the imbalance so netting is BOUGHT, not hoped for.** `crowding_bps`
   already charges a one-sided book more — an Avellaneda–Stoikov inventory skew.
   As the long side crowds, the short side gets cheaper and the marginal borrower
   is PAID to take the other side. That is the real answer to "wait and see if
   anyone shorts": **do not wait, make it worth their while**, continuously, at a
   published price.

## WHICH BUSINESS THIS IS — the calculus really does change, and only one survives

| | funding-rate business | trading business |
|---|---|---|
| revenue | `rate_bps()` × AUM × duration, plus the crowding premium on imbalance | timing P&L |
| wants a directional position? | **never** — every unit of net is risk to carry or pay to remove | necessarily |
| does it have a view? | no | yes |
| do its actions inform borrowers? | **no — nothing to read** | yes, and they will read it |
| adverse selection | priced: persistent positions pay more, via a continuously published duration-dependent rate | absorbed, funded by depositors when the view is wrong |

"We can trade better than individual traders" quietly commits to the right-hand
column. Everything already built — `rate_bps()` published BEFORE any position
opens, `crowding_bps`, the collar, the reserve — is shaped for the left.

⇒ **A pool with no view emits no signal, and that is not a limitation. It is the
property that keeps the flow stable.** The edge was never forecasting; it is that
the pool is short the NET and has no liquidation price on the netted part.

## THE CHALLENGE, and the shape of its answer

> How do you capture the value of patience without creating an unbounded
> discretionary option that depositors wrote and were never paid for?

**Derive the threshold; do not judge it.** This was solved once already on the
EVM side. `RANGE_BPS = 300` was a plausible number encoding somebody's judgement
about when to act; it was replaced by `h³ = g/(C·K)` — a threshold computed from
measurable quantities, at which point the same patience became *policy* rather
than *discretion*, auditable by anyone, and impossible to exercise selectively.

The same move applies here. The wait threshold should be a function of the
reserve, the net per ticker, and the realisable spread — not a call someone makes
on the day. When it is derived, "we do not sell until the price is good" stops
requiring anyone's trust, and the option stops existing because there is nothing
left to exercise.

⚠️ Until that threshold is derived, the honest default is the one already in
force: **persistence, not panic** — never hedge on a calendar or on a bad day,
only when a single ticker's net has persisted above what the reserve covers, in
calm conditions, as principal, for the largest few concentrations.

## Delivery, and why none of the above authorises minting for users

Backed's primary market is permissioned: Qualified Professional Investors,
onboarded, KYC/AML'd, **wallet-whitelisted**, **$100,000 minimum per issuance
ticket** ($5,000 to redeem), and rejectable at the issuer's sole discretion. Its
terms exclude U.S. Persons **"or for the account or benefit of U.S. Persons"**,
plus Canada, the UK and others.

Two consequences, and neither depends on a legal opinion:

1. **The $100k ticket alone forecloses per-pledge ordering.** A single pledge is
   nowhere near it, so "place an order as soon as someone pledges" is impossible
   on size before it is anything else. Which points at the same rule as
   everything above.
2. **Minting for users is agency, and batching does not dilute it.** Minting once
   for four hundred people is still minting for four hundred people. Effecting
   securities transactions for the account of others, for compensation, is the
   definition of a broker in every regime that has one. Screening customers does
   not cure this — it supplies the "identified clients" element, so it is
   evidence *for* the characterisation, not against.

⇒ Delivery, if it ever happens, is **as principal, for the pool's own book**, to
hedge the pool's own residual net. Nobody is our customer in that transaction; we
are Backed's customer. That is a treasury operation and needs no program-level
key, which is why `ProgramConfig` deliberately carries none.

🔴 **App-layer screening is not a protocol property.** `deposit` takes a bare
`Signer` and constrains only the *mint* (`registered_mints`), never the
depositor. A front-end restriction is disproved by one `anchor` call, so it
cannot support a claim about who can hold exposure. If that claim ever needs to
be true, it has to be enforced in the program — and the field that would require
is an *attestation* authority, not an xStocks one.

---

# WHAT THE INSTRUMENT ACTUALLY IS — and why "mispriced in four ways" is one defect

The owner's objection is the right one: *"currently mispriced in four known ways??
SOLVE IT. what even is it? start with a correct definition?"* The four are not
four. They are one thing, and naming the instrument correctly is what shows it.

## THE DEFINITION

> **A perpetual, double-barrier, PARISIAN knock-out with gradual knockout,
> written by the pool and paid for as a hazard rate.**

Every word is load-bearing and every one is checkable in the code:

| term | where it lives |
|---|---|
| **perpetual** | no maturity anywhere; `T` never appears. Vigor prices `T = 1.0` and charges the premium as a running rate; we never convert |
| **double-barrier** | `upper = pledged + collar`, `lower = pledged − collar` (`stay.rs:938`, `:971`) |
| **PARISIAN** | `breached_at` starts on first breach, accumulates elapsed time, and **RESETS TO 0 on return inside the band** (`stay.rs:505, 605, 993, 1193`). Consecutive-time-beyond-barrier with reset is exactly the Parisian condition — cumulative-without-reset would be Parasian |
| **gradual knock-out** | not one extinction event: `MAX_TRANCHE_BPS = 185` per window over `N = 7d/LIQ_GRACE_SECS = 168` windows |
| **hazard rate** | `r = carry + hazard(m, σ, jump) × E[loss|breach]`, units of 1/time natively — no maturity to invent, no premium→rate fudge, no clamps |

⚠️ **I had been calling this a "perpetual two-sided knock-out", which is true and
insufficient.** A plain knock-out dies AT the barrier. This one requires the
barrier to be held for a grace period, forgives an excursion that comes back, and
then dies *slowly*. Those three properties are the entire difference between what
we priced and what we wrote.

## THE FOUR MISPRICINGS ARE ONE MISPRICING

**We price the barrier as if the knock-out were instantaneous, one-sided and
symmetric. It is Parisian, two-sided and gradual.** Each measured defect is a
Parisian feature that is not in the price:

| measured | which unpriced feature it is |
|---|---|
| collar over-collateralised **~6×** its 1% target | the barrier is set from a **one-observation** tail |
| collar **flat above 2× leverage** (σ floor binds) | moneyness `m` saturates, so the barrier stops moving with the thing it barriers |
| `downside_vol_bps` **fitted and discarded** | a DOUBLE barrier priced off ONE symmetric σ. GJR already says the tails differ |
| one-step tail vs **168-step** unwind | the **gradual** knockout and the **grace window** are not in the price at all |

⇒ Fixing them separately is four patches. Fixing the definition is one change:
price the barrier over the CLOSE-OUT HORIZON, per side, from the tail each side
actually has.

## COMPARE: ISDA SIMM

SIMM is the industry's answer to the same question — how much collateral does a
position need, given that closing it out takes time — so it is the right thing to
measure ourselves against, not because we should adopt it but because it makes
our gap legible.

| | ISDA SIMM | here |
|---|---|---|
| basis | **sensitivity**-based: Delta, Vega, **Curvature** per risk class | **exposure**-based: notional × collar |
| horizon | **10-day MPOR** — margin period of risk, i.e. the close-out window, BUILT IN | **one observation**, while close-out takes 168 |
| confidence | 99% VaR | 1% breach (`COLLAR_BREACH_BPS`) — same order |
| aggregation | buckets with **correlations** `√(Σx² + 2Σρxy)` | `max_liability = Σ(exposure × collar)` — fully-correlated worst case |
| convexity | explicit **Curvature margin** | none |
| calibration | recalibrated **annually** by committee, stress period included | **continuously refitted** from live observations (POT/GPD) |
| nature | a mutually-agreed **schedule**, deliberately model-light so counterparties can agree | a unilateral **model**, priced per position |

**WHERE SIMM IS PLAINLY BETTER, AND IT IS THE SAME GAP WE MEASURED:**
- **The MPOR is the whole point of SIMM.** It sizes margin for the period it takes
  to close out, because that is the exposure. Our collar sizes for one hour while
  our ladder takes seven days. **SIMM solved by construction the exact defect we
  found by measurement**, and it is the biggest of the four.
- **Curvature margin** is the convexity term we lack — and the objective (earn the
  premium, do not lose principal) is convex, as the ruin measurement showed.

**WHERE OURS IS BETTER, AND IT IS NOT A SMALL THING:**
- **Continuous refitting.** SIMM's parameters are recalibrated ANNUALLY by a
  committee; ours are refitted from the last 500 observations on every price
  update. A regime change reaches our collar in hours and SIMM's in a year.
- **No premium→rate conversion.** A hazard rate has units of 1/time, so a position
  closed in a day pays for a day. SIMM is a margin AMOUNT, not a price; Vigor
  priced a one-year option and charged it as a rate, and needed four corrections
  and two clamps to hide the mismatch.
- **Conservative aggregation.** Summing collars assumes everything breaches
  together. SIMM's correlations are calibrated and therefore lower — better
  capital efficiency, worse tail behaviour. Ours is the safer error.

**WHERE THEY ARE NOT COMPARABLE:** SIMM exists so two counterparties who disagree
about models can still agree on a number. It is deliberately not the best model —
it is the most agreeable one. We have no counterparty to agree with; the pool
prices its own book. Adopting SIMM wholesale would import a committee's
compromises to solve a problem we do not have.

⇒ **TAKE THE MPOR, LEAVE THE SCHEDULE.** The single highest-value change is to
size the barrier over the close-out horizon rather than one step — which is
SIMM's central idea and our largest measured error, and it subsumes the "6×
over-collateralised" finding because the two errors point in opposite directions
and have never been netted against each other.
