# The skew, the reserve, and why there is no refill to build

⚠️ `docs/informational/` is prose and goes stale against the contracts. Every claim below was
measured or read from the tree on 2026-09-09; check the code before quoting a number.

## What the skew is for

The pool quotes against its own inventory at an oracle price. Nothing pairs two legs against a
curve, so there is no reserve *ratio* to defend — "balanced" here means the pool holds enough of the
volatile asset to serve the flow it expects, not that two quantities stand in a fixed relation. The
skew is the price of scarcity: as inventory falls relative to expected flow, drawing more of it down
costs more.

That price is doing two different jobs at once, and separating them explains most of what follows.
It **charges** the trader who takes inventory, and the charge is meant to **summon** whoever will
put inventory back. The first job works. The second is where the design rests on an unverified step.

## There is nothing to fund, and that is deliberate

A recurring instinct is that the pool should buy its inventory back after a large withdrawal, and
that the charge collected should pay for that. **The pool does not do this, nothing in the contracts
does it, and the design rejected it explicitly** — an earlier mechanism that paid a trader to
restore balance was removed, with a note not to rebuild it.

Restoration happens by ordinary entry instead. A depleted pool is a more attractive pool to join,
because scarcity raises what an entrant earns; the entrant brings the asset, and balance returns.
Nobody is paid a bonus, no keeper is scheduled, no external venue is required, and the pool never
spends its own reserves to trade.

**This matters because it changes what "can we afford it?" means.** A great deal of analysis has
been spent on whether the charge covers the cost of a buy-back. It does not — measured across many
market conditions, a buy-back would lose money more often than not. That is not a problem to solve;
it is a reason the design does not do it. The question that matters is not whether the pool can
afford to restore itself, but **whether the price signal is strong enough to bring someone else in.**

## Where the design is actually thin

The entry mechanism depends on a chain: scarcity raises the charge, the charge raises what an
entrant earns, and that pulls entry. Only the first link is verified. Nothing establishes that an
entrant's expected return rises enough to attract them into a pool that is short the asset in a
market that just moved against it, nor how quickly that happens. Restoration by entry is
asynchronous and unbounded in time.

And the signal itself is weak across most of the range. Measured, the charge is close to nothing
until the pool is severely depleted — it behaves as a guard against being emptied rather than as a
continuous incentive to rebalance.

## The reason the signal is weak, and it is not the price curve

The charge compares inventory against **expected flow**, and expected flow is measured **gross**. A
pool being steadily drained in one direction and a pool churning both ways in equal measure look
identical to it. So the quantity that is supposed to detect depletion cannot distinguish depletion
from ordinary two-way business.

That is the defect. It is not the shape of the price curve, and it is not the coefficient that
scales it — considerable effort went into both before this became clear. Volatility is the right
input for *how costly* it is to be short inventory; it is the wrong input for *how fast* inventory
is leaving. Those are different questions and only the first is currently asked.

The natural correction is a reserve target that carries a safety margin above expected flow, sized
by how one-directional recent flow has been. Today's target is a plain average of flow with no
safety term at all. The signed measure needed for this exists in the contracts but is not in a form
the price may read yet, and the code carries an explicit instruction not to wire it until the
relationship is derived on this system's own balance sheet rather than borrowed from the literature.

## Two cautions for anyone re-deriving this

**A floor sits under the charge.** Below moderate depletion, every trade pays the same small minimum
regardless of size or conditions. Measurements that sweep trade size in that region will report a
flat number and read it as the scarcity price; it is not, and this has now caused three separate
false conclusions.

**The charge is not simply proportional to volatility.** It contains a term that does not scale with
volatility at all. Any test that assumes proportionality holds only in the configuration it happens
to sample, and will silently mislead outside it — including tests written specifically to detect
that error.
