# Lane: routing / floors (§SESS-46 … §SESS-49)

Booked here rather than in `SPRINT.md` per CLAUDE.md — a parallel thread is crossing rows off
`SPRINT.md` in place and it is the one file every lane wants to append to.

---

## ✅ §SESS-48 — THE SLIP TEST NOW ASSERTS THE BUDGET INVARIANT, AND THE DEFECT IT WAS BOOKED FOR DOES NOT EXIST

**`test_TheGuessedSlipIsTooTightAtSmallSizeAndLooseAtLarge` → `test_TheSlipBudgetMustCoverWhatTheBestVenueActuallyCosts`.**

The old test pinned two WETH amounts read at `FORK_BLOCK=25800000` and asserted the floor could not be
met. WETH is priced in dollars, so both constants went stale the moment ETH moved: it had to fail
whenever the basis moved **in either direction**, and at `25919850` it went red for being right.

▶️ **THE INVARIANT, ENTIRELY LIVE — nothing frozen, falsifiable at any pin:**
```
need   = (parity - bestReachableRoute) * 10_000 / parity   // basis + fee + impact, as one number
budget = _slipBps(usdSize)
invariant: budget >= need
```
`parity` is the oracle read this block (split out of `floorOracle`, ONE formula two readers), and
`bestReachableRoute` is a live `QuoterV2` simulation.

### 🔴 AND THE FIRST VERSION OF IT MANUFACTURED A FALSE DEFECT — TWICE, AT TWO PINS
Searching **direct pools only** put `need` at 51–52 bps against a 50 bps budget and reported a liveness
failure. ⭐ **The 2-hop through the USDT hub returns ~23 bps more**, which is a route the protocol can
actually take. Measured at `25919955`: direct best `399.365`, hub 2-hop `400.282`, parity `401.497`.

⚠️ **I wrote the warning against this in the helper's own docblock and then shipped the version that
did it** — *"a `need` measured against a venue we could have beaten is not the market's cost, it is our
own search's cost."* Standing rule 13: the dismissal needed the same evidence as the finding.
⇒ `_quoteBestVenue` now mirrors `plan_route`'s shape — best direct tier, else two hops via a hub — so
the number is a route the protocol can reach rather than an abstract market best.

### 📊 MEASURED AT `FORK_BLOCK=25919966`, 6/6 GREEN
| size | need (basis+fee+impact) | budget `_slipBps` | headroom |
|---|---|---|---|
| $50k | **14 bps** | 25 bps | 11 bps |
| $1M | **30 bps** | 50 bps | 20 bps |

⇒ **§SESS-41/43's "liveness defect" was an artifact of the instrument, not a property of `_slipBps`.**
The budget covers the best reachable route at both sizes. ⛔ **DO NOT read that as "the floor is
solved":** the headroom column IS the bleed — 11 and 20 bps a filler can take — which is §SESS-23's
question, untouched. **Liveness resolved; the leak is still open.** Per rule 16 the §SESS-23 row stays
OPEN, and the §SESS-43 liveness bullet should be marked resolved-by-measurement with these numbers.
📌 The bleed is deliberately **logged, not asserted**: a ceiling assertion here would re-freeze a market
reading through the back door, which is the exact defect being removed.

---

## 🔴 §SESS-49 — THE KEEPER'S PLANNER TAKES A DIRECT POOL WHENEVER ONE EXISTS AND NEVER COMPARES

Found by the measurement above, and it is the same question the owner asked of the route arm: *is the
provided route optimal among all possible routes?*

`plan_route` (`lev_keeper.rs`): `if let Some(p) = direct_pool(token_in, token_out) { return … }` —
**a direct pool short-circuits, so the 2-hop is never quoted when a direct pool exists.**
📉 **Measured cost at `25919955`, USDC→WETH $1M: direct `399.365` vs hub 2-hop `400.282` — ~23 bps left
on the table**, on the exact pair a USDC-denominated venue uses. At $50k direct wins, so this is
**size-dependent and cannot be fixed by reordering the table**; it needs a quote.

⇒ **This is §SESS-45's joint-scoring argument one level down.** That work scores *which venue to borrow
from*; this is *which route to take once borrowed*, and the machinery (`score_bps`, `pick_cheapest`) is
already there. The planner has RPC access, so quoting both shapes and taking the better one is an
off-chain change with **no on-chain surface and no new trust**: the contract still bounds whatever
comes back on its own balance delta.
▶️ **NOT YET BUILT.** Booked with the measurement so it is not re-derived.
