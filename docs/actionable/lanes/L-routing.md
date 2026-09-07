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

---

## ✅ §SESS-52 — **`hubHopOf` DELETED. `_quoteOf` (now `_hubRowOf`) ALREADY HELD EVERY ROW IT DID.**

Owner, 2026-09-07: *"hubhopof feels like a variable that should not exist and there are many such
variables."* Correct, and the check was one grep I never ran. **Promoted to CLAUDE.md standing rule 23.**

§SESS-51 deleted `_routeOf` (2 rows) and created `Aux.hubHopOf` to hold them — **while `_quoteOf`,
twenty lines below in the same file, already held both of those rows and four more.** Two tables became
two tables, plus a mapping, a setter, an event, an interface member, two offset constants, deploy
seeding, and an `aux` parameter threaded through three functions. **Nothing was deleted.**

| | `LevMath` | margin |
|---|---|---|
| before any of this | 23,846 | 730 |
| §SESS-51 first attempt | 24,301 | **275** |
| §SESS-51 lean | 23,936 | 640 |
| **§SESS-52, one table** | **23,726** | **850** |

⭐ **AND THE ARGUMENT I USED TO JUSTIFY THE SPLIT SURVIVES, POINTING THE OTHER WAY.** *"A floor whose
reference is settable by the same key that sets the route is not a floor"* is an argument for the table
being **COMPILE-TIME** — which it is, for both readers now. It was never an argument for a second,
settable execution table; I used it as one.

### 🔴 AND §SESS-24's JUSTIFICATION FOR THE SPLIT NO LONGER HOLDS — MEASURED, NOT ASSUMED
With one table the four quote-only stables (USDT/DAI/USDG/crvUSD) become **executable**, which §SESS-24
recorded as breaking `test_ProtectFromQuid_HostileOperatorNetsZero`. **That test now PASSES** — verified
it actually ran (`[PASS]`, gas 12,356,436), as does its BTC counterpart, per standing rule 20. The four
rows measure **4 / 1 / -1 / 0 bps flat to $1M**, each verified against `coins()`, so a slice that swaps
at a measured-flat venue serves the LP better than one refunded mid-protect.
⚠️ **The behaviour change is asserted head-on in `HubHopRoster.t.sol`, not hidden behind a second
table.** If that assertion ever has to be weakened, the second table is being re-invented.

### 📌 DESTALES THIS FORCED (rule 19, fixed in the same pass)
- **`_quoteOf` → `_hubRowOf`.** The old name was quote-only when a second table held the executable
  rows; it is now the ONE table, so the name had become a lie. **A stale name is worse than a stale
  comment — it is what a grep returns.**
- ⛔ **ONE LEFT, DELIBERATELY NOT FIXED: `lev_keeper.rs:965` still says `_hubHop` → `_quoteOf`.** That
  file is **dirty with another thread's uncommitted work**, and editing it would mix my one-word change
  into their diff — rule 14's failure mode. **Fix it when that lands, not before.**

## 🔴 §SESS-53 — `test_E2_IncumbentLossDoesNotScaleWithTheMint` IS BLOCK-SENSITIVE, NOT CODE-CAUSED

**Attributed by control, not by argument.** Same commit (`adf6a694`), same binary, two pins:
| pin | result |
|---|---|
| 25919850 | **PASS** |
| 25920058 | **FAIL** — `667916670000 >= 419039500000` |
Gas is **identical (16,888,417)** at `adf6a694` and at my `HEAD`, so no execution path moved: it is not
§SESS-46/47/50/51/52. **208 blocks changed the verdict.**

⇒ **SAME CLASS AS §SESS-48's SLIP TEST**, and it should get the same treatment: it asserts a
market-dependent quantity against a bound that only holds at some blocks. ⚠️ **Do NOT re-base the
bound** (standing rule 4) — the message itself says the sibling bound *"is now hiding it"*, so the
question is which dilution property is actually being claimed, expressed so it is falsifiable at ANY
pin. ▶️ **NOT BUILT.** Booked with the measurement so it is not re-derived.
📌 It also means **the tree has at least two market-sensitive assertions**, so a red suite must be
attributed by pin before it is attributed to a change. That is now twice in two days.

---

## 🔴 §SESS-55 — **"USDT IS BORROWABLE" OVERSTATES WHAT §SESS-47 PROVED. THE PARTS ARE VERIFIED; THE WHOLE IS NOT.**

Owner, 2026-09-07: *"how do you know you got their design right?"* — for the routing, by execution. For
this claim, **I don't, and the honest answer is that it cannot be tested in this tree at all.**

### WHAT IS ACTUALLY VERIFIED, AND BY WHAT
| claim | evidence | strength |
|---|---|---|
| `curveExchange` returns the measured delta | real 3pool swap fills (`test_Curve_ExchangeActuallyFills`) | ⭐ execution |
| `_hubHop` crosses the right pair, both ways | real RLUSD round-trip, <10% loss ⇒ indices not crossed | ⭐ execution |
| `_aggSwap` compacts a zero hop | 110/110 targeted; a USDC venue now reaches `route` | ⭐ execution |
| the encoder emits four tokens | exact length 132 | ⭐ execution |
| the keeper plans USDT→WETH as a 2-hop | unit test pins `dex2` = the hub leg | ⚠️ unit only |
| **a USDT-denominated venue can open a lever** | **NOTHING** | 🔴 **untested** |

### 🔴 AND IT IS NOT AN OVERSIGHT — IT IS UNTESTABLE HERE, WHICH IS THE MORE USEFUL FACT
**No deployed venue borrows USDT.** `_ethLevVenues` wires RLUSD/PYUSD Morpho weETH markets; the BTC
venue defaults to USDC. `VenueBorrowRate.t.sol` constructs an `AaveV3Venue(USDT)` but only READS its
rate. ⛔ **And a test cannot add one: `LevManager.init` sets `venuesFrozen = true` (`:128-129`,
measured, not inferred), so the allowlist is pin-once at deploy.** ⇒ proving the end-to-end claim needs
a **new deploy**, not a new test.

⭐ **THE DESIGN INTENT IS WRITTEN AT THE DEPLOY SITE AND IT ANSWERS THE QUESTION** (`DeployL1_s:40-60`):
*"THE DEBT ASSET IS A DEPLOY-SITE CHOICE, NOT A CONTRACT LIMIT… Default stays USDC because an Aave v3
RLUSD/PYUSD borrow market has NOT been verified to exist with real idle depth."*
⇒ **The correct statement of what §SESS-47 did: it removed a KEEPER-SIDE blocker that made a non-USDC
venue unroutable. Whether USDT is ever borrowed is a deploy decision nobody has made.** §SESS-45's
"the reachable cheap dollar (USDT, 4.08%) is unborrowable" was therefore true for TWO independent
reasons, and I fixed one and reported the row closed. **The remaining one is the deploy.**
▶️ **BOOKED, NOT BUILT:** add a USDT `AaveV3Venue` to `_ethLevVenues` behind an env override (the file
already does this for `AAVE_V3_WBTC_DEBT`), then an end-to-end open/close. **That is the only thing
that would make the headline claim true.**

## 📌 §SESS-56 — THE THREE "BLOCK-SENSITIVE TESTS" ARE AN ALREADY-NAMED HOUSE CLASS

`VenueBorrowRate.t.sol` carries **§POINT-IN-TIME-IS-NOT-AN-INVARIANT** with two worked examples of its
own: an `assertEq` on a live Aave rate that passed once and failed by 1.3e-9 the next run, and an
`assertGt(r25 - r0, 10e23)` written from *"~37bps on 2026-08-30"* that measured **3.4 bps two days
later — a 10x swing.** Its verdict is exactly the one §SESS-48 re-derived: *"NEITHER number is wrong;
the ASSERTION was… what is invariant is the SHAPE."*
⇒ **§SESS-48 (slip), §SESS-53 (E2) and `test_TwoHopExecutesAndBeatsTheDirectPool` are the same class,
and the tree already had a name and a remedy for it.** I found it three times without checking whether
it was known — the grep was one command (`POINT-IN-TIME-IS-NOT-AN-INVARIANT`, 1 file).
✅ **The reassuring half: the fix §SESS-48 landed — assert the SHAPE, log the magnitude — is verbatim
the remedy that file already prescribes.** Independent arrival at the house rule is evidence the shape
is right; not having looked first is still the cheaper lesson.

---

## ✅ §SESS-58 — **WHEN DOES A TWO-HOP HAPPEN? MEASURED — AND THE ANSWER FOUND A GAP I HAD LEFT.**

Owner, 2026-09-07: *"when do two hops happen if at all"* and *"what is a hub?"*

**A hub is only the middle token of a two-hop route** (`USDT → USDC → WETH` ⇒ USDC is the hub). It is
not a protocol role. USDC held it here because it is `stables[0]` and every `_hubRowOf` Curve row is a
`<stable>/USDC` pool.

### 📊 MEASURED LIVE, WETH OUT (block ~25924xxx)
| route | $100k | $1M |
|---|---|---|
| USDC→WETH direct | **40.161** | **400.206** |
| USDC→WETH via USDT | 40.037 | 399.944 |
| USDT→WETH direct | 40.042 | 400.012 |
| USDT→WETH **via USDC** | **40.155** | **400.125** |
| DAI→WETH direct | 39.321 | **339.395** |
| DAI→WETH **via USDC** | **40.154** | 264.215 |

⇒ **Two hops DO happen, and mostly for USDT: ~28 bps at both sizes.** DAI's hub route wins at $100k and
loses catastrophically at $1M. **So the winner is a function of BOTH the pair and the size**, which is
the whole argument for pricing it instead of tabling it.

### 🔴 THE GAP THE QUESTION EXPOSED
`best_plan` read `if tin != USDC_ADDR && tout != USDC_ADDR` with USDC as the ONLY hub, so **a
USDC-denominated venue — the most common one — never had a two-hop priced at all.** At block 25919955
`USDC→USDT→WETH` beat direct by ~23 bps and was unreachable.
⚠️ **AND MY OWN 23-bps CLAIM HAS SINCE REVERSED** (direct 400.206 vs via-USDT 399.944), which is
§POINT-IN-TIME landing on my own commit message. **The gap is real; its SIGN is market state.** That is
the argument for pricing both, and against encoding either.
▶️ **FIXED:** `HUBS = [USDC, USDT]`, and a hub equal to `tin` or `tout` is skipped as the direct case.
✅ **A SHORT HUB LIST IS FINE *BECAUSE IT IS PRICED, NOT TRUSTED*** — an unhelpful hub loses the
comparison, where an unhelpful TABLE ROW used to be taken on faith. That is the difference between this
and the three tables deleted earlier today.

### 🔑 AND A TESTABILITY PROBLEM WORTH THE NOTE
`chosen >= best_direct` **cannot distinguish "priced and lost" from "never priced"** on a day when
direct wins. The test now prices the hub route independently and asserts `chosen >= via_hub`.
⚠️ **It cannot fail today, and that is correct rather than vacuous: it fires exactly on the days when
skipping would cost us**, which is the only time the bug has a consequence. The run log carries the
proof it was evaluated — `direct 400.114 · via-USDT 399.944 · chosen 400.114`.

### ⛔ SEPARATE FINDING, NOT A ROUTING ONE: DAI HAS A LIQUIDITY CLIFF AT SIZE
$1M DAI→WETH returns **339.4** against the ~400 USDC and USDT both get — **~15% down on EVERY route**,
direct and both hubs. The oracle floor would reject such a fill (correct), but it means **DAI is not
usable at $1M** and a venue denominated in it would stall rather than trade. **Booked, not diagnosed.**

---

## 🔴🔴 §SESS-59 — **A SECOND UNAUTHENTICATED WITHDRAWAL, FOUND BY SWEEPING FOR THE FIRST ONE'S SHAPE**

`project-a1` found `Quid.rangeOp` ungated (an `external` library body, delegatecalled, ending in
`weth.transfer(msg.sender, …)` behind a wrapper with no modifier). **Confirmed independently before
acting on it** — the mechanism is exactly as reported and their wrapper-level `NotSelf` gate is the
right fix, because a delegatecalled library cannot distinguish an internal re-entry from an external
call.

▶️ **THE SWEEP THAT MATTERED: `external`/`public` library functions that read `msg.sender`, reached
through an ungated wrapper.** Six candidates, four clean, **one second live defect.**

### `Quid.offrampEtherFi(uint amount, address recipient) public` — NO GATE
`QuidLib.offrampBody` ends `IERC20(c.weth).transfer(recipient, got);` and **`recipient` is caller-
supplied.** So: sell the contract's weETH on Curve and deliver the WETH wherever the caller says,
bounded only by the contract's weETH balance and 90% of the Curve pool — **nothing about the caller.**
⛔ **ARGUABLY WORSE THAN `rangeOp`.** The legitimate path (`Quid.sol:795`) bounds the amount by the
caller's OWN position (`Math.min(amount, SwapLib.plainNet(LP.pooled, levPooled[msg.sender]))`) and then
BURNS what was served. **Calling the public entrypoint directly skips both** — no position check, no
burn. The WETH leaves and the accounting never moves.

⚠️ **`NotSelf` WOULD BREAK IT, AND THIS IS THE TRAP.** `Quid.sol:795` is a PLAIN INTERNAL call, so
`msg.sender` there is the original external redeemer, not `address(this)`. `rangeOp`'s gate is correct
only because BOTH its callers re-enter through `address(this)`. **The same fix applied twice would
have broken the redemption path** — the shapes look identical and the remedies are not.
▶️ **THE FIX IS VISIBILITY, NOT A GATE — unconstructible beats detectable (rule 17): `public` →
`internal`.** Measured before proposing: declared in **no interface**, **zero** external call sites
(`grep -rn "\.offrampEtherFi(" src/ test/ script/` is empty), **zero** references in `quid-ln`, and
exactly **one** caller in the tree — the internal one. The external surface is used by nothing.
📌 Handed to `project-a1` to land with the `rangeOp` gate: they are mid-edit in `Quid.sol` and it is
their lane. **Not fixed by me.**

### ✅ THE FOUR THAT ARE CLEAN, so nobody re-checks them
`SwapLib.sweepBody` (every `msg.sender` is inside `///`, no code use) · `SwapLib.auxSwapBody`
(`allowance`/`safeTransferFrom` **from** the caller — you can only take from someone who approved) ·
`SwapLib.swapToBody` (credits the caller's own deposit) · `ChannelLib.depositBody` (`msg.sender ==
quid` as an authorisation, and only Quid can be msg.sender there).

### 🔑 THE METHOD LESSON, WHICH IS THE REUSABLE PART
**Neither defect was findable by a test, and both were findable by a grep for a SHAPE.** `rangeOpBody`'s
docblock asserted *"Wrapper enforces `msg.sender == V4` BEFORE delegating"* and **no such wrapper ever
existed** — auditors read a gate that was never there (standing rule 20, arriving as a security bug).
⇒ **When one instance of a class is found, sweep for the class before fixing the instance.** Fixing
`rangeOp` alone would have left the larger hole open, and its docblock would have made the file look
audited.
⚠️ **AND THE SWEEP'S OWN FALSE-POSITIVE CLASS IS NAMED ABOVE (4 of 6)**, per the sweep rule: `msg.sender`
in a delegatecalled library is only a defect when it is a PAYOUT TARGET or an AUTHORISATION. Pulling
from it, or crediting it, is correct.

---

## 🔴 §SESS-60 — **"HOW DO YOU KNOW 1inch WAS BUILT RIGHT?" MEASURED: TWO SELECTORS OF SIX, AND THE FLEXIBLE ARM HAS NO PRODUCER**

Answered by grep, not by recollection.

### WHAT `evm/src` ACTUALLY EMITS
**`UNOSWAP_SELECTOR` and `UNOSWAP2_SELECTOR`. That is all.** Zero occurrences of `unoswap3`
(`0x19367472`), the generic `swap()` descriptor (`0x07ed2379`), `ethUnoswap`, `unoswapTo`, or
`fillContractOrderArgs` (`0x56a75868`) anywhere in `src`.
⇒ **the pool-word arm is capped at TWO HOPS by construction.** The owner's ask was *"not just unoswap3
but all the venues we might need and no limit to how many hops"* — **neither half is built.** §SESS-58
prices multi-hub candidates, but every candidate it can EXPRESS is still ≤ 2 hops.

### 🔴 AND THE ARM THAT WOULD LIFT THAT LIMIT IS UNREACHABLE IN PRACTICE
`bytes route` can carry ANY 1inch calldata, and `convertTo` bounds it safely (pinned callee, per-leg
gas cap, `spent>0 ⇒ delivered>0`, floor on the measured delta). **Nothing produces one:**
· `lev_keeper.rs:417` `cascade_delever(&urgent, &[])` — literal empty
· `lev_keeper.rs:430` `let rebal_routes: Vec<Vec<u8>> = Vec::new();`
· `rebalance` writes a zero-length `bytes` tail by hand
· **`grep -rn "fetch_route|oneinch_api|api\.1inch" quid-ln --include=*.rs` → ZERO.** Nothing anywhere
  fetches 1inch calldata.
⇒ **The full-venue arm is plumbing with no producer.** It is reachable only by a human calling the
permissionless entrypoint directly. **This is the built-but-unwired shape for the THIRD time this
session** (§SESS-47's discarded plan, `quoteFill`'s zero callers, now this).
⚠️ **DO NOT READ THE `convertTo` TESTS AS COVERAGE OF IT.** They prove the EXECUTOR is safe given
calldata; they say nothing about a system that never produces any.
▶️ **NOT BUILT:** either a keeper-side 1inch API client (with the amount problem re-examined — §SESS-40
concluded a posted order cannot serve a flash-bound path, which is a different question from calldata),
or `unoswap3` support to reach 3 hops with pool words and no amount at all. **The second is smaller and
needs no off-chain dependency; it is probably the right next move.**

## 🔴 §SESS-61 — **WHY IS USDC THE HUB? I NEVER DECIDED, AND NEVER MEASURED.**

Owner: *"why did you decide that usdc is the best hub? when is it ever necessary."* **I did not decide
it — I inherited it and only half-questioned it.** Every row of `_hubRowOf` is a `<stable>/USDC` Curve
pool, so USDC is the hub BY CONSTRUCTION OF A TABLE, and §SESS-58 added USDT as a second *quoted*
candidate without ever asking whether USDC is the best one.

**The answer splits by path, and only one half is defensible:**
| path | is USDC necessary? | evidence |
|---|---|---|
| **off-chain planner** | **No — it is a CANDIDATE that gets priced.** Measured: USDT→WETH via USDC wins by ~28 bps; USDC→WETH via USDT loses. A hub is used when it wins. | ⭐ measured |
| **on-chain `_hubHop` / `_consolidateTo`** | **Structural and UNTESTED.** `_hubHop(stable, amt, toUsdc)` converts only to/from USDC and `_consolidateTo` runs `s → USDC → target`, so **every consolidate slice funnels through USDC whether or not that is the best pair.** | 🔴 assumed |
⇒ **If a `<stable>/USDT` pool were deeper than the `<stable>/USDC` one, `consolidate` would eat the
difference silently** — no revert, just a worse fill inside the flat 100 bps `CONSOL_SLIP_BPS`, which
is itself 4x wider than `_slipBps` at small size. **The two weaknesses compound.**
▶️ **NOT BUILT.** The measurement is cheap (`get_dy` on both hubs per basket stable at 2-3 sizes) and
would either justify the assumption or name the rows that should be re-pointed. Doing it BEFORE
tightening `CONSOL_SLIP_BPS`, since a tighter floor on a worse hub is how you turn a bleed into a stall.

---

## 🔴 §SESS-62 — **`Quid`'s PAYABLE FALLBACK TURNS A DELETED ENTRYPOINT INTO A SILENT SUCCESS. OWNER'S CALL.**

`project-a1` asked whether `Quid.sol:415` `fallback() external payable {}` is deliberate. **Measured,
it is not needed for the job it appears to do:**
1. `Quid` has **no `receive()` at all** — one `fallback`, zero `receive`. The fallback is doing double
   duty: bare-ETH receipt AND swallowing unknown selectors.
2. The bare-ETH need is real and its source is `QuidLib.sol:438` `IWETH9(weth).withdraw(inWETH)` —
   `WETH9.withdraw` returns ETH with **empty calldata**, and QuidLib is delegatecalled, so it lands on
   Quid. That is the one legitimate inflow.
3. **Empty calldata routes to `receive()` when one exists**, so `receive() external payable {}` covers
   the unwrap exactly and lets unknown selectors revert. Nothing legitimate is lost.
4. It is physically easy to miss: `:415` reads `}   fallback() external payable {}` — on the SAME LINE
   as the constructor's closing brace.

⭐ **THE ARGUMENT THAT SETTLES IT IS ALREADY IN CLAUDE.md, ABOUT THIS EXACT CONTRACT.** Line 735: the
SPA was encoding a call to a **removed `Quid.exitInstant`**, and `check-client-abis.py` exists because
`tsc` cannot run here (`spa/` has no `node_modules`). **With a payable fallback that call SUCCEEDS
SILENTLY** — on an EXIT path, so a user could believe they had exited when nothing happened, and any
ETH sent is swallowed. ⇒ **the fallback converts a loud failure into a silent one on a money path, in
the one contract with a documented instance of a client calling a deleted entrypoint.**
📌 It is also why `assertFalse(ok)` is worthless as a selector-removal test here (a1's finding): any
unknown selector returns SUCCESS, so such a test must assert on VALUE MOVED. Swapping to `receive()`
makes `assertFalse(ok)` correct again.

⚠️ **NOT LANDED, AND DELIBERATELY SO — IT IS A BEHAVIOUR CHANGE AND THE OWNER'S DECISION.** Anything
currently calling a Quid selector that does not exist flips from silent success to revert. That is the
correct behaviour and exactly the class we want surfaced, but "correct" and "safe to change unasked"
are different questions.
▶️ **THE DECISIVE TEST IS CHEAP:** swap it, run the FULL suite with `--force`; anything that breaks is
by definition something that was calling a non-existent selector and getting away with it. Green is the
evidence, red is a finding either way.

---

## ⭐ §SESS-64 — **"WHY IS unoswap1/2 HARDCODED?" IT SHOULD NOT BE — AND THE FIX NEEDS *NO NEW PARAMETER*.**

Owner, 2026-09-07: *"im not sure why unoswap one or two has to be hardcoded or passed as a distinct
word if we are going with the most flexible design of our 1inch feature."* **Correct. The two-word
shape is an artifact of encoder convenience, not a design.**

### WHY IT IS AN ARTIFACT
`dex2` was added as a SECOND WORD rather than an array because the keeper's shared batch encoder could
not carry a fourth array at the time. **The batch path is ALREADY parallel arrays** (`dexes`, `dex2s`
at `LevManager:322`), so the two-word single path is the odd one out. ⇒ *"one or two hops"* is baked
into the ABI by history.

### ⛔ THE OBVIOUS FIX DOES NOT FIT — MEASURED
`(uint256 dex, uint256 dex2)` → `uint256[] calldata hops` (selector by LENGTH: 1⇒`unoswap`,
2⇒`unoswap2`, 3⇒`unoswap3`) touches **8 signatures in `LevManager`** (`:282 :321 :368 :393 :402 :410
:432 :436`). **`LevManager` has 133 BYTES.** A `uint256[] calldata` costs offset load + length load +
bounds check per entrypoint — well past the budget eight times over.
🔑 **SO `LevManager`'s 133 BYTES IS NOT A NUISANCE, IT IS THE THING STANDING BETWEEN US AND THE
FLEXIBLE DESIGN.** Every "no limit to how many hops" conversation ends here.

### ✅ THE SHAPE THAT COSTS ALMOST NOTHING — PATCH THE AMOUNT, DO NOT PASS THE HOPS
**`bytes route` ALREADY EXISTS ON ALL EIGHT SIGNATURES.** The only reason it cannot carry
`unoswap3` today is the reason pool words exist at all: **1inch calldata embeds an AMOUNT the keeper
cannot know**, because it is a borrow return computed on-chain.
⭐ **BUT THE UNOSWAP FAMILY PUTS THE AMOUNT AT A FIXED OFFSET — WORD 1 — AND THE CONTRACT ALREADY
KNOWS THE AMOUNT.** `_aggSwap` writes exactly that word today when it encodes `unoswap`/`unoswap2`
itself. ⇒ **accept keeper calldata, OVERWRITE word 1 with the on-chain amount and word 2 with our own
floor, and forward it.** Then:
· any unoswap-family selector works — **1, 2 or 3 hops, and any venue 1inch's unoswap reaches**
· **no ABI change, no new parameter, ~zero `LevManager` cost**
· **no staleness** — the contract writes the amount, so nothing embedded can go stale
· `dex`/`dex2` become legacy and can be deleted later, along with §SESS-50's zero-hop compaction and
  the crossed-argument trap
⚠️ **THE GUARD THAT MAKES IT SAFE, and it must be exact:** whitelist the selector
(`unoswap`/`unoswap2`/`unoswap3` ONLY), require the EXACT calldata length for that selector
(4+4*32 / 4+5*32 / 4+6*32), and only then patch words 1 and 2. **A selector we do not recognise, or a
length that does not match, is refused** — never patched-and-hoped. ⛔ The generic `swap()` descriptor
is DELIBERATELY excluded: it carries a `dstReceiver` and a nested struct, so its amount is not at a
fixed offset and patching it is not checkable.
✅ **SAFETY IS OTHERWISE UNCHANGED:** `convertTo` still pins the callee, caps gas per leg, enforces
`spent>0 ⇒ delivered>0`, and bounds the result on a MEASURED balance delta against an oracle floor. A
hostile keeper picks a worse venue and the floor refuses it — it never gains authority.
▶️ **NOT BUILT.** This is the concrete answer to §SESS-60's "no producer" and to the owner's
"no limit to how many hops", and it is the smallest change that reaches both.
