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

---

## ✅ §SESS-50 — **`hubDex` IS NOT A CONCEPT. IT IS HOP 1. AND THE CROSSING COST US A WHOLE ROUTE ARM.**

Owner, 2026-09-06: *"no awkward fallbacks. maybe we dont need hubdex at all. use the most elegant
design possible."* Following it produced a concrete defect, not just a tidy-up.

### 🔴 THE DEFECT: A USDC-DENOMINATED VENUE COULD NEVER USE THE 1inch CALLDATA ARM
`_stableToWethSor` / `_stableToWbtc` pass `(hubHop, volHop)` into `_aggSwap`'s `(dex, dex2)` — the
**crossed** order their own docblocks flag as a trap. A USDC venue has **no hub hop by nature**, so it
arrived with `dex == 0` and reverted `NoVolatileRoute()`. To dodge that, those sites took a compat
branch — **and that branch DISCARDS `route` entirely** (`:1085-1086`, measured: `c.route` appears on
the routed line and nowhere in the branch).
⇒ **the most flexible route in the system was unreachable for the most common venue in the system**,
and nothing failed, because the legacy arm works.
⭐ **It also explains a note this tree had recorded as a mystery.** The `_stableToWbtc` docblock says
adding `&& stable != USDC` *"BROKE 17 TESTS WITH `NoVolatileRoute()`"* and reads it as a property of
USDC. **It is an artifact of the crossing** — `dex2 == 0` lands in the `dex` slot, which `_aggSwap`
rejects. Standing rule 20: the docblock described the symptom correctly and the cause wrongly.

### ▶️ THE FIX — TREAT THE HOPS AS AN ORDERED LIST WITH AN ELIDED SLOT
`_aggSwap` now compacts: `if (dex == 0) { dex = dex2; dex2 = 0; }`. `(0, w)` and `(w, 0)` both mean
*one hop through `w`*. Two lines.
✅ **DIRECTION SURVIVES THE COMPACTION, and the argument is worth keeping:** hop 2's direction is
derived from `tokenOut`, hop 1's from `tokenIn`. A SOLE hop holds both ends, so `tokenIn == token0`
and `tokenOut != token0` are the SAME predicate. The two rules diverge only for a genuine intermediate
token, which a compacted route no longer has.
⇒ the three compat guards narrow from `hubDex == 0` to `stable != USDC && hubDex == 0`, which is what
they were always for: **a non-hub stable the keeper could not plan.** A USDC venue now takes the routed
path and **reaches `route` for the first time**.
⭐ On `_volToStable` the routed path is STRICTLY BETTER: the compat arm swapped to USDC with
`minOut = 0` and checked the floor a frame later; `_aggSwap` enforces it on the measured delta of the
final token, in one place.

📊 **`LevMath` 23,846 → 23,839 (737 spare) — it got SMALLER while gaining a capability.** `LevManager`
unchanged at 133. Targeted: 110 passed / 0 failed across 22 suites, 0 `setUp` failures, 0 env errors.

### ⛔ WHAT IS STILL NOT DELETABLE, AND THE MEASUREMENT THAT SAYS SO
`hubDex` cannot go to zero uses yet, because RLUSD and PYUSD venues **are deployed**
(`DeployL1_s.sol:110-117`, Morpho weETH markets) and `LevManager:322` measures that **4 of 8 candidate
dollars (GHO, USDG, RLUSD, USDE) have no direct v3 pool to USDC**. So a UniV3 pool word cannot express
their hub hop, and the Curve table is their only route.

▶️ **PROBED, AND THE RESULT IS DELIBERATELY RECORDED AS WEAK.** Six candidate layouts for a **Curve**
pool word through 1inch's `unoswap` (protocol field at bit 253 and at 254, coin indices at the two
offsets 1inch uses, both index orders) were executed against the real router at a live pin:
**0 of 6 filled.** ⚠️ **THAT IS NOT "1inch CANNOT ROUTE CURVE VIA `unoswap`"** — it is six guesses at
an encoding this tree has never written down (`PROTO_UNIV3 = 1` is the only protocol constant
declared). CLAUDE.md's most-repeated wrong conclusion is exactly this shape. **Enumerate the router's
actual `ProtocolLib` layout before concluding anything**; the probe was deleted rather than committed,
because a test that asserts nothing is noise in the suite.

### ⭐ THE DESIGN THAT FINISHES IT — ONE HOP WORD, TWO EXECUTORS, NO TABLE
The elegant end state does **not** need 1inch to speak Curve at all, because **we already speak it**:
`curveExchange` calls `exchange` directly and — since §SESS-46 — bounds the result on a measured
balance delta. What makes `_routeOf` awkward is not Curve, it is that **the pool is looked up in a
hardcoded on-chain table instead of being named by the caller.**
⇒ **let a hop word carry `proto | pool | i | j` and dispatch on `proto`:** UniV3 → 1inch `unoswap`,
Curve → our own `curveExchange`. **Same safety argument as today** — the keeper names a venue, never a
direction, an amount or a floor; `convertTo`/`curveExchange` bound the delta; a hostile pool can only
make the leg FAIL. That deletes `_routeOf`, `_hubSwap`, `_routableStable`, `NoStableRoute`, every
`CRV_*_IDX` constant and the compat branch, and it admits **any Curve pool**, not six rows.
⚠️ **ONE BLOCKER TO SETTLE FIRST: `consolidate` (`LevMath:1558`) reads `_routableStable`/`_hubSwap` and
takes NO keeper input**, so the table cannot be deleted until `consolidate` either receives hop words
or derives them. **That is the next question, and it is a design question, not a coding one.**

---

## ✅ §SESS-51 — **THE TABLE IS DELETED. AND THE FIRST VERSION OF THIS WAS 4.7× TOO BIG.**

Owner, mid-implementation: *"are you sure all this code is actually needed?"* — **no, and the
measurement said so before the question did.** Recording both versions, because the delta is the lesson.

| | `LevMath` | margin |
|---|---|---|
| §SESS-50 only | 23,839 | 737 |
| §SESS-51, **first attempt** | 24,301 | **275** |
| §SESS-51, **landed** | 23,936 | 640 |

🔴 **THE FIRST ATTEMPT SPENT 462 BYTES ON THE SECOND-TIGHTEST CONTRACT TO RELOCATE A TWO-ROW
`if`-CHAIN**, and seeded it with exactly the old two rows so nothing behaved differently. Standing
rule 18: *"best means the smallest change that removes the CAUSE, not the largest change that touches
the most code"* — and the cost was sitting in the size table the whole time, unread.

▶️ **WHAT WAS UNNECESSARY, PRECISELY: a `PROTO_CURVE` dispatch**, added so a roster word could be
either protocol. **A UniV3 hub hop already has a path — the keeper's `dex2`** — so the roster only ever
needs to express what the deleted table expressed: Curve. Dropping the dispatch returned **365 bytes**,
and the protocol tag then had no reader at all and went too (standing rule 1). **Final cost: 97 bytes.**
⇒ the generality I was buying was already in the system, one parameter over. **That is the shape to
look for: not "is this code good", but "is this capability already reachable another way".**

### 📌 THE FIX THAT LANDED
`Aux.hubHopOf` (owner-set, `j | i | pool`) replaces `LevMath._routeOf`. `_routeOf` was never a routing
table — it was **metadata about the stable roster shadowed into the wrong contract**; `Aux` already
owns `stables`, `stableFeed` and `vaultOf`. `_hubHop` also carries `minOut`, which `_hubSwap` did not
(it called `exchange(i, j, amt, 0)`, a `min_dy` of zero this file's own docblock flags as a hazard).
⚠️ **OWNER-SET, NOT CALLER-SUPPLIED, AND THAT IS THE SECURITY HALF.** `protectFromQuid` is
permissionless and consolidation runs at a flat 100 bps `CONSOL_SLIP_BPS`. Caller-named pools would
hand an arbitrary address the **SELECTION** of every venue — the floor bounds the loss, never the
choice, and the choice is the takeable part.
⚠️ **`_quoteOf` STAYS COMPILE-TIME:** a floor whose reference is settable by the same key that sets the
route is not a floor. Governance may re-point where we TRADE and still cannot re-point what we ACCEPT.

### 🔴 AND THE FIXTURE TRAP FIRED, EXACTLY AS RULE 21 DESCRIBES
Seeding went into `DeployL1_s` first. **The fixture does not run it — and 107 tests passed while RLUSD
and PYUSD silently lost their routes.** Only the five new tests written for this change caught it. The
seeding now lives in `DeployLib`, shared VERBATIM by production and `AllesFixture`, so the fixture
models the tree **by construction** instead of by remembering to.
📌 Two more traps hit on the way, both already in CLAUDE.md and both re-earned: **naming a natspec
parameter tag inside a comment MAKES it one** (the note explaining solc 6546 reproduced solc 6546), and
**`vm.expectRevert` cannot bind to an inlined `internal` library call** — the test needed a real
external frame.

### ⛔ STILL OWED
1. **`test_E2_IncumbentLossDoesNotScaleWithTheMint`** failed in the §SESS-50 full run (1091/1) and was
   NOT in the prior baseline. **Unattributed** — two control attempts were wasted on build errors. It
   must be run at HEAD before this is called clean.
2. **A clean full-suite number.** The §SESS-51 targeted run compiled another thread's uncommitted
   `Core`/`Quid`/`FeeLib` work, so 112/0 is not a measurement of this change alone.
3. **§SESS-49** (planner never quotes the 2-hop when a direct pool exists, ~23 bps at $1M) — still unbuilt.
