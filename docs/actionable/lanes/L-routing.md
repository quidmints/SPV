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

---

## §SESS-65 — **THE 1inch REBUILD: ONE THIRD LANDED, THREE CONSTRAINTS SPECIFIED AND NOT BUILT**

Owner, 2026-09-07: *"rebuild the 1inch feature properly. dont forget that il protect plugs into it
also… there is no notion of a partial fill and partial refund (or shouldnt be, if and only if the
swapper agrees to load balance with 1inch) for either in range or out of range swaps."*

### ✅ LANDED — RETARGETING (`a320683f`)
`convertTo` rewrites every supplied route's `token`, `amount` and `minReturn` with its own values.
**The caller chooses the VENUE and nothing else.** That dissolves the staleness pool words existed to
dodge, so `unoswap3` is reachable through the existing `bytes route` with no new argument and no
`LevManager` cost. Whitelisted by selector AND exact arity length. 106/106 green.

### ✅ §SESS-118 CLOSED — 1. **THE TWO HALVES NO LONGER DISAGREE, AND THE MEASURED WIN WAS NEVER
### THE KEEPER'S TO CHOOSE.** This row's whole premise was *"the two halves disagree about what
### venues exist"* — planner blind to Curve, contract knowing six pools. Both halves moved since:
### §SESS-113 deleted `Venue::Curve` (`venue_word` could not encode it) and §SESS-115 deleted
### `quote_venues` outright, so the planner no longer discovers Curve either. **The disagreement is
### gone by SUBTRACTION, and the row's proposed fix — add Curve to `best_direct` — would recreate it.**
### 🔑 **AND THE MEASUREMENT THAT MOTIVATED THE ROW IS ALREADY SERVED WITHOUT A KEEPER.** The number
### quoted below is USDT→USDC, where 3pool beats the UniV3 0.01% tier above ~$500k. `LevMath.
### _hubRowOf` row 3 is `USDT_TOKEN => (CURVE_3POOL, …)` and row 4 is DAI, **unconditionally, with no
### keeper in the loop** — so the exact trade that was measured to want Curve already executes on
### Curve. Verified this session by reading the table, not inferred.
### ⭐ **ON THE CONSOLIDATE PATH CURVE IS BOTH EXECUTOR AND PRICE REFERENCE**, which is stronger than
### keeper choice: `_consolidateTo` floors at `max(oracle swapFloor, _selfServableQuote·(1−CONSOL_SLIP_BPS))`
### and `_selfServableQuote` walks the SAME `_hubRowOf` rows `_hubHop` executes. A keeper cannot
### propose a venue here at all, so it cannot propose a worse one.
### ⇒ **WHAT WOULD BE LEFT IS NOT WORTH ITS BYTES.** Re-admitting keeper-chosen Curve means restoring
###   an on-chain `PROTO_CURVE` arm (§SESS-91 deleted it with the pool-word plumbing) on a library
###   with ~436 B of EIP-170 margin, to capture a gap §SESS-101 measured at SINGLE-DIGIT bps on pairs
###   the fixed table already routes. ⛔ Do not reopen without a NEW measurement on a pair `_hubRowOf`
###   does NOT cover — that, and not the USDT number below, is what would justify the arm.
### ORIGINAL §SESS-107 DESTALE — **CURVE IS IN THE SEARCH NOW, AND IS NO LONGER EXECUTABLE.** Both halves
### of this row moved and in opposite directions. `venues_for` DOES discover Curve (`CURVE_SHORTLIST`)
### and `curve_quote` prices it — so the planner is no longer blind. But §SESS-91 deleted `_hubHop`'s
### `PROTO_CURVE` arm with the pool-word plumbing, so `venue_word(Venue::Curve) => None` and a
### keeper-chosen Curve pool has NO EXECUTOR. ⛔ The sentence below — *"a Curve pool word is already
### executable through `_hubHop`"* — was true when written and is FALSE now.
### ⇒ what remains open is narrower: Curve executes only through `_hubRowOf`'s six fixed rows, for
###   `consolidate` and for `_startsAt`'s table hop. Re-admitting keeper-chosen Curve means restoring
###   an on-chain arm, and §SESS-101 measured the execution gap it would close as single-digit bps.
### ORIGINAL ROW:
`best_direct` asks the **UniV3 factory** and quotes **QuoterV2**. ⛔ **Curve pools are invisible to the
planner**, and the owner is right that many pairs are best served by a direct Curve pool: **measured
this session, 3pool beats the UniV3 0.01% tier for USDT→USDC above ~$500k (−0.42 vs −0.72 bps at $1M,
−0.68 vs −2.16 at $5M).** The on-chain `_hubRowOf` knows six Curve pools; the planner knows none.
⇒ **the two halves disagree about what venues exist.** ▶️ Add Curve to `best_direct` via the
MetaRegistry's PLURAL `find_pools_for_coins` (the singular one returns dead pools — CLAUDE.md) plus
`get_dy`, and let it compete on the same quote. **No on-chain change: a Curve pool word is already
executable through `_hubHop`, and 1inch's own Curve encoding stays irrelevant.**

### 🔴 STILL NOT BUILT — 2. **IL-PROTECT: BORROW THE CHEAPEST DOLLAR, THEN HOP TO THE ONE WE NEED**
### ⚠️ §SESS-107 — **AND I MAY HAVE MISREAD THE OWNER'S INSTRUCTION ABOUT THE `immutable` HERE.**
### Pre-compaction the owner said *"do the deploy change and kill the immutable"*. §SESS-93 read that
### as killing the `public` on `MANAGER`/`STABLE` — measured, `.STABLE()` and `.MANAGER()` had ZERO
### callers against 25 uses of `stable()`, so two dead getters per venue went. That was a real saving
### and it is NOT what this row is blocked on. **This row names `LevVenueBase.STABLE` being
### `immutable` as the blocker**: a position cannot change which dollar it borrows without a new
### venue, so "pick the stable by TOTAL cost including the extra hop" has nowhere to land.
### ⇒ if the instruction meant making `STABLE` MUTABLE, it is unbuilt and this row says why. Flagged
###   rather than decided: mutability here is a money-path change, and the owner has separately ruled
###   that this system has no governance knobs — a per-position stable is arguably not one, but that
###   is the owner's call and not mine to infer from a four-word instruction.
The owner's point: *"usdc might be overborrowed so not the most cost effective borrow, better to borrow
something else then do an extra hop through 1inch."* §SESS-45 built joint venue scoring (borrow rate +
route cost) and §SESS-49 built route quoting — **but nothing composes them into "pick the stable by
TOTAL cost including the extra hop".** The scorer's decision point is FIRST-OPEN, and
`LevVenueBase.STABLE` is `immutable`, so **a position cannot change which dollar it borrows without a
new venue.** ⇒ this is blocked on the same thing §SESS-45 blocker #3 named, and the extra hop is now
EXPRESSIBLE (unoswap2/3 via retargeting) where it was not before. **The hop is ready; the choice is not.**

### ⚠️ **TAG NOTE — THIS WORK WAS COMMITTED AS `§SESS-116` (`a96856c3`) AND THE CODE NOW SAYS
### `§SESS-118`.** A peer lane independently took `§SESS-116` for an unrelated SPRINT block
### (`87baf039`, *"book the thread's loose ends in one block, deduped"*) — two threads, one number,
### which is the navigation trap this file's own header warns about. **The COMMIT MESSAGE cannot be
### changed (it is pushed), so the mismatch is recorded here rather than left to be discovered.**
### Grep `§SESS-118` for this work; `§SESS-116` in `SPRINT.md` is the peer's and is a different thing.

### ✅ §SESS-118 BUILT — 3. **THE CONSENT WAS ALREADY IN THE SIGNATURE; THE FILL FRAME NEVER ASKED.**
### This row proposed threading `loadBalance` down into the conversion path. It needed no threading:
### `loadBalance` is a field of `OorIntent` and sits INSIDE the EIP-712 typehash (`SwapLib:1193`), so
### the MAKER signs it and a filler cannot forge it — `Quid.sol:1255` was already handing it to
### `CORE.settleOor`. **`fillIntent` simply never read it before routing that maker's draw through
### `ONEINCH_ROUTER`.**
### 🔴 **SO THIS WAS A CONSENT DEFECT, NOT ONLY AN UNBUILT FEATURE.** A maker who signed
### `loadBalance = false` had DECLINED aggregator routing, and the conversion fired whenever the
### FILLER passed `routes` — the party bearing the routing risk had opted out, the party electing to
### take it was someone else.
### ▶️ **BUILT:** `Quid.fillIntent` now reverts `PartialFillNotConsented()` when `proceeds6 < ask6`
### and the maker did not consent; with consent, today's behaviour is unchanged. A distinct error
### from `IntentUnpayable` on purpose — that means nothing could be paid, this means the fill would
### have been partial — so a filler is not told to abandon an intent that is merely too big for the
### basket right now. Reverting also leaves the intent LIVE and its nonce unspent, so the maker can
### be filled whole later or re-sign smaller: the maker's call, not the filler's.
### ⚠️ **STILL PERMITTED, AND CORRECTLY:** a CONSENTED fill may land short (`convertTo`'s `if (!ok)
### continue`, or `routes.length == 0`). That is the behaviour the signature bought.
### ⛔ **THE OTHER TWO SITES ARE NOT SWAPS AND ARE DELIBERATELY UNTOUCHED.** `_consolidateTo:1556`
### refunds an unroutable slice to the LP mid-protect — the LP's OWN value returned, not a
### counterparty served short; `QuidLib:699`'s shrink is a REDEMPTION, argued below. The owner's
### constraint names swaps, and the OOR fill was the swap among the three.
### ORIGINAL ROW (§SESS-107: re-checked,
### unchanged. `loadBalance` still gates the shortfall arb rather than partial fills, and
### `convertTo`'s `if (!ok) continue` is now MORE load-bearing than when this was written — §SESS-99
### showed it is what turned `ZeroMinReturn()` into an anonymous zero for a day.)
Partial fill and partial refund exist today in three places, none gated by consent:
· `convertTo:702` `if (!ok) continue;` — one leg fails, the rest proceed, the aggregate floor decides
· `_consolidateTo:1556` — an unroutable slice is **refunded to the LP** mid-protect
· `QuidLib:699` *"NEVER GATE — shrink"* — the offramp serves part and defers the rest
⚠️ **`loadBalance` ALREADY EXISTS AS A USER-SUPPLIED CONSENT BOOL** (`Aux.swapTo:885`,
`Core.settleOor:944`; §E347 calls it *"the consent gate"*) — **but it gates the SHORTFALL ARB, not
partial fills.** So the consent primitive is there and wired to the wrong question.
▶️ **THE SHAPE:** thread the existing `loadBalance` into the conversion path; `false` ⇒ any leg that
cannot fill reverts the whole swap, `true` ⇒ today's behaviour. ⛔ **DO NOT default it on**: the owner's
wording is *"if and only if the swapper agrees"*, so absent consent the answer is revert.
⚠️ **AND THE OFFRAMP IS A DELIBERATE EXCEPTION TO ARGUE, NOT ASSUME** — its shrink exists because a
2,000 weETH exit asks more than the pool holds, and gating it would defer the whole exit instead of
serving most of it. That is a redemption, not a swap; the owner's constraint names swaps.

### 🔴 ALSO OPEN — the generic `swap()` descriptor
Excluded by the whitelist. **Forcing `dstReceiver = address(this)` would be strictly stronger than
`RouteTookAndGaveNothing` detecting a diversion after the fact**, and its descriptor is a STATIC struct
so its fields are at fixed offsets. ▶️ Needs the exact v6 layout verified against the deployed router
before patching — not guessed.

---

## ⭐ §SESS-68 — **THE SYNTHESIS. THE CLUES ADD UP TO ONE DESIGN AND I HAVE BEEN BUILDING PAST IT.**

Owner: *"didnt you get many clues about how to redesign the feature so it does exactly what we want."*
**Yes — twelve of them, and I answered each one incrementally instead of building the shape they
describe.** Written down as one design so the next change is to it, not beside it.

### 📊 THE MEASUREMENT THAT FORCED THE ISSUE — **4 OF 13 STABLES HAVE NO USABLE HUB ROUTE**
Deepest pool to USDC, UniV3 (4 tiers) + Curve registry, stable-side holdings:
| deep enough | thin / absent |
|---|---|
| USDT 47.9M · DAI 56.4M · RLUSD 27.9M · AUSD 17.5M · PYUSD 15.0M · crvUSD 13.7M · USDG 8.5M · BOLD 5.7M · USDe 1.25M | **USDS 10,928 · GHO 8,179 · CUSD NONE · FRXUSD NONE** |

🔴 **CORRECTED 2026-09-07 (§SESS-72) — THE PARAGRAPH BELOW PROPOSES MACHINERY THAT ALREADY EXISTS,
WHICH IS STANDING RULE 23's FAILURE FOR THE SECOND TIME IN ONE DAY.** Owner: *"you can redeem from the
4626 vault before converting. there is no need to convert the staked tokens."*
**Measured: `Aux._withdraw` → `ChannelLib.withdrawBody(token, amount, to, _supplyCfg(), vaults,
vaultsOf, sp)` ALREADY unwinds the 4626 venues**, and `protectExec` calls `IAux(aux).redeem(pull)`
BEFORE `_consolidateTo`, which then reads `IERC20Min(s).balanceOf(address(this))`. ⇒ **by the time
anything is converted, the manager holds BASE tokens; the staked share was already redeemed.**
⛔ **SO "ADD A 4626 ROUTE KIND TO THE SWAP TABLE" WAS INVENTING A SECOND REDEMPTION LAYER.** Redemption
is not a ROUTE — it is a separate, already-built step that runs first. I asked "what kind of route is
missing" when the question was "which layer is this?", and the answer was "a layer we already have".
⭐ **AND IT SHRINKS THE GAP RATHER THAN RESHAPING IT.** What is left for cUSD/frxUSD is only the
question of whether the BASE dollar can be swapped to the venue's loan token — and when it cannot,
`_consolidateTo` already REFUNDS the slice to the LP rather than stranding it. **That is fail-safe and
deliberate, not a hole.** So of the "4 of 13", the redemption half was never missing and the conversion
half is bounded by an existing refund path. ⇒ **the honest residual is: an LP whose slice is in an
unconvertible dollar gets that dollar back instead of debt repayment. Worth knowing; not a gap.**
📌 The GHO/USDS half of the row still stands on its own terms — those DO have thin AMM pools rather
than no market — but the conclusion drawn from all four was overstated.

(original, kept for the record:) 🔑 **AND THE GAP IS NOT A MISSING ROW — IT IS A MISSING *KIND OF ROUTE*.** Those four are not
AMM-routed assets: `DeployL1_s` already says so in its own comments — *"cUSD — Cap USD (**native
stcUSD 4626 vault**)"*, *"frxUSD — **native sfrxUSD 4626 vault**"*, and GHO's depth lives on
**Balancer**, USDS behind Sky's **1:1 DAI converter**. ⇒ **a table of POOLS cannot be gapless, because
some dollars do not have pools.** The table must be a table of ROUTES, where a route is an AMM pool
**or** a 4626 mint/redeem **or** a par converter. **That is the redesign the gap measurement points at,
and no amount of better pool-picking reaches it.**

### 🔒 MEV — ALREADY TWO LAYERS, AND THE RESIDUAL IS THE FLOOR'S SLACK
1. **The keeper does NOT use the public mempool.** `daemon.rs:84-88` sends through a **private relay**,
   Flashbots Protect by default, `QUID_PROTECT_RPC_URLS` to override. So keeper txs are not front-runnable.
2. **The oracle floor bounds the fill on a MEASURED balance delta**, so even a sandwiched fill cannot
   pay short — it fails instead.
⚠️ **THE RESIDUAL IS EXACTLY THE FLOOR'S SLACK, AND IT IS THE §SESS-23 BLEED WEARING A DIFFERENT
HAT:** whatever gap sits between the oracle price and the floor is takeable by anyone who can land
beside us. `CONSOL_SLIP_BPS` is a flat **100 bps** ⇒ **1% is takeable on every consolidation slice.**
⇒ **tightening the floor IS the MEV work**; there is no separate MEV feature to build.
⚠️ And note the permissionless entrypoints (`rebalance`, `protectFromQuid`) are called by third parties
through the PUBLIC mempool — the private relay protects the keeper's own sends, not those.

### 🦄 UNISWAP V4 — UNREACHABLE BY CONSTRUCTION, AND IT NAMES THE PIECE I DEFERRED
**A v4 pool has no address.** v4 is a SINGLETON: pools live inside the `PoolManager` and are keyed by a
`PoolKey`, so **a 160-bit pool word cannot name one** — the entire pool-word mechanism is v3/v2/Curve
only, by construction and not by omission. §V4-CUT removed every v4 surface from `evm/src` (no
`PoolManager`, no `PoolKey` outside comments).
⇒ **v4 depth is reachable ONLY through 1inch's generic `swap()` executor**, which is precisely what
`_retarget`'s whitelist excludes today. **So "there are plenty of deep v4 pools" and "the `swap()`
descriptor is deferred" are the same item.**
▶️ `swap()`'s descriptor is a STATIC struct, so `srcToken`/`dstToken`/`dstReceiver`/`amount`/
`minReturnAmount` sit at fixed offsets and are patchable exactly like the unoswap family — and
**forcing `dstReceiver = address(this)` is strictly stronger than `RouteTookAndGaveNothing` catching a
diversion after the money moved.** Needs the exact v6 layout verified against the deployed router
before patching, not guessed.

### 🧭 THE DESIGN THE CLUES DESCRIBE, IN ONE PLACE
1. **On-chain: a COMPLETE route table (pool | 4626 | converter), curated by depth, no quoting** — the
   owner's *"dont quote, just hardcode the most liquid pools, no gaps."*
2. **`_retarget` widened to `swap()`** so any venue 1inch reaches — v4, Balancer, anything — is
   admissible, with `dstReceiver` forced to us. Covers *"any 1inch venue should be possible without
   making it a vulnerability"* and *"no limit to how many hops"*.
3. **The floor is the ONLY trust boundary**, on a measured delta. Tightening it is the MEV work.
4. **All-or-nothing unless the swapper consents** (`loadBalance`, which exists and gates the wrong thing).
5. **The keeper picks among table venues and may supply richer calldata; it submits privately.**
6. **IL-protect borrows the cheapest dollar and hops** — blocked on `LevVenueBase.STABLE` being immutable.
⇒ **Items 1, 2 and 4 are the build. 3 is a number to derive. 6 is a venue-shape change.**

---

## 🔒 §SESS-69 — **THE HACKED-KEEPER ANALYSIS FOR THE WIDENED `_retarget`. THE WIDENING *IS* THE MITIGATION.**

Owner: *"did you widen _retarget? how do we make sure it cant be abused, even with hacked keeper?"*

### 🔑 THE FRAMING THAT MATTERS FIRST: `route` WAS PREVIOUSLY FORWARDED **VERBATIM**
Measured at `a320683f~1` — `convertTo` did `ONEINCH_ROUTER.call{gas: ROUTE_GAS_CAP}(routes[k])` with
**no selector check, no length check, no patching.** ⇒ **a hacked keeper could ALREADY send a `swap()`
descriptor naming ITSELF as `dstReceiver`**, and the only thing standing in its way was
`RouteTookAndGaveNothing` catching the theft *after* the tokens moved — a per-leg check satisfied by
delivering **one wei**. **So widening `_retarget` did not open the generic executor; the generic
executor was always open. What changed is that it is now the only one, and it is patched.**

### WHAT A FULLY HACKED KEEPER CAN AND CANNOT DO NOW
| it controls | it CANNOT control |
|---|---|
| the selector — but only 4 whitelisted | **what we sell** (`srcToken` overwritten) |
| `executor` (w0) and `srcReceiver` (w3) | **what we want** (`dstToken` overwritten) |
| `flags` (w7) — booked gap | **where it goes** (`dstReceiver` = `address(this)`) |
| the `data` tail | **how much** (`amount` = this frame's computed number) |
| which pools/venues | **the floor** (`minReturn` zeroed; the delta floor binds) |
| | **the callee** — `ONEINCH_ROUTER` is pinned, not a parameter |
| | **the allowance** — exactly `amt`, re-zeroed on BOTH paths |
| | **the gas** — `ROUTE_GAS_CAP` per leg (an uncapped call measured **931,857,691 gas**) |

### ⇒ THE RESIDUAL IS EXACTLY ONE NUMBER: **THE FLOOR'S SLACK**
The worst a hacked keeper achieves is routing through an executor it controls and returning **just
enough to clear the floor**, pocketing the difference between the oracle price and the floor.
⚠️ **AND THE PER-LEG `spent>0 ⇒ delivered>0` GUARD DOES NOT BOUND THAT — one wei satisfies it**, which
`convertTo`'s own docblock states deliberately (*"not proportional… a per-leg SIZE bound is what
§SESS-20 rules out"*). So the aggregate floor is the ONLY size bound, and it is the whole exposure.
📌 **THEREFORE: tightening the floor IS the anti-abuse work, and it is the SAME number as the MEV
work** (§SESS-68). `_slipBps` is 25–100 bps; `CONSOL_SLIP_BPS` is a flat **100 bps**. **1% per
consolidation slice is what a hacked keeper can take, and what a sandwicher can take, and they are one
figure — not two problems.**
⛔ **`srcReceiver` IS DELIBERATELY NOT FORCED, AND FORCING IT WOULD BE THEATRE.** Measured on two live
mainnet transactions, `srcReceiver == executor` — 1inch sends the source tokens to the executor so it
can trade them. Pinning `srcReceiver` to the executor changes nothing, because the executor is
attacker-chosen by design; pinning it to `address(this)` would break every honest route. **The
executor being arbitrary is how 1inch works, and the floor is what makes that survivable.**

### ⚠️ WHAT IS *NOT* CLOSED, STATED PLAINLY
1. **Cross-contract re-entrancy.** The executor is attacker code running mid-conversion. `nonReentrant`
   exists on 47 functions across `Quid`/`LevManager`/`Aux` — **but each contract has its OWN `_lock`
   slot** (CLAUDE.md records this), so a lock held in one does not stop a call into another. ⚠️ **This
   is PRE-EXISTING and unchanged by the widening** — arbitrary executor code was always reachable — but
   it is not bounded by anything I added, and I have not traced whether a cross-contract re-entry can
   profit. **Booked, not cleared.**
2. **`flags` (w7).** 1inch's flag word carries a partial-fill bit. Clearing it would implement the
   owner's *"no partial fill unless the swapper agrees"* for this arm at the cost of one line — but
   **I have not verified which bit it is**, and asserting an unmeasured bit position is the exact
   failure this exercise exists to avoid. 📌 Evidence toward it: `flags` was **0 in both live
   transactions** sampled, so the bit is not routinely set.

---

## 🔴 §SESS-75 — **"IS A THREE-HOP EVER NECESSARY?" NO CASE FOUND. "DO WE REACH THE BEST VENUES?" NO — AND IT IS ONE GAP, NOT MANY.**

### THREE HOPS: BUILT, AND I CANNOT FIND A NEED FOR IT
Our actual conversions are `stable↔WETH`, `stable↔WBTC` and `stable→stable`. Every one is covered by
**two** hops through a hub, because a stable with a USDC pool reaches WETH/WBTC in one more.
⇒ **a third hop only helps a stable that has NO USDC pool but DOES have one to another stable that
does.** Measured, the stables that fail do not fail that way:
· **GHO** — UniV3 GHO/USDC holds **8,179**, GHO/WETH holds **0 across all four tiers.** Its depth is on
  **Balancer**. A third hop does not reach Balancer; a different VENUE CLASS does.
· **USDS** — 10,928 on UniV3, and a **1:1 Sky converter** that is not an AMM at all.
· **cUSD / frxUSD** — no pool, and none needed: they redeem through their 4626 vaults (§SESS-72).
⇒ **`unoswap3` support is built and currently answers no question we have.** Keeping it costs one
constant and one arm in `route_bytes`; ⚠️ **it should not be cited as coverage.** The honest statement
is *"hop count is no longer a limit"*, not *"we needed three hops"*.

### VENUE ACCESS: WHAT WE REACH AND WHAT WE DO NOT
| venue | reachable? | why |
|---|---|---|
| Uniswap V3 | ✅ | factory discovery, all four fee tiers, depth-gated |
| Curve | ⚠️ shortlist | `find_pools_for_coins` returns **121 pools** for USDT/USDC; enumerating is 363 calls/leg and starved the endpoint. Priced shortlist instead |
| **Uniswap V4** | 🔴 **NO** | a v4 pool **has no address** — a singleton keyed by `PoolKey`, so no pool word can name one |
| **Balancer** | 🔴 **NO** | same: reachable only through 1inch's own executor |
| **1inch split routing** | 🔴 **NO** | nothing calls their API |

🔑 **AND ALL THREE MISSES ARE ONE GAP: THE KEEPER EMITS ONLY UNOSWAP-FAMILY CALLDATA.** The CONTRACT
already admits the generic `swap()` descriptor (§SESS-69, `dstReceiver` forced, offsets verified on two
live transactions). What is missing is a producer for it — and **`swap()` calldata cannot be
constructed by us**, because it names 1inch's own executor and carries an opaque `data` tail. **Only
their API produces it.**
▶️ **SO THE REMAINING WORK IS EXACTLY ONE THING: a 1inch API client in the keeper.** ⭐ **And the
objection that used to block it is already answered** — §SESS-40 rejected fetched routes because
*"full calldata embeds an amount … unknowable off-chain to the wei"*. **`_retarget` overwrites the
amount, the token, the receiver and the floor**, so a fetched route can be stale in every field we
care about and it does not matter. **The blocker was removed by work that was not done for that
reason.**
⚠️ It is a NEW EXTERNAL DEPENDENCY (key, rate limit, availability) on a path that currently has none,
and it must degrade to the self-planned route rather than to no route.

## ✅ §SESS-76 — THE `_aggSwap` DELETION: **LANDED IN §SESS-91.** Measured 24,161 → 22,720 B, margin
## 415 → 1,856. The analysis below is the record of why; the "NOT LANDED" it carried was stale from
## the moment §SESS-91 committed, and stayed stale through §SESS-102's own booking pass.

Owner sanctioned deleting the pool-word encoder to pay for direction derivation on the route arm.
**Built and measured:** deleting `_aggSwap` frees **~810 bytes**; the derivation costs **~386**; net
**+424**, `LevMath` 24,354 → 23,930 (222 → 646 free), **and the acceptance test passed** —
`test_ADeliberatelyWrongDirectionBitIsIgnored` is green through `_retarget` instead of `_aggSwap`.
🔴 **BUT IT TOOK 26 TESTS RED AND I DID NOT DIAGNOSE THEM.** All `NoVolatileRoute()` /
`EvmError: Revert` on paths that call the lever without a route. ⚠️ **A `--force` rebuild of 486 files
reproduced them identically, so it is NOT the stale-bytecode trap** — the failures are real and mine.
⇒ **REVERTED.** Standing rule 8d asks whether the change is WRONG or INCOMPLETE: it is incomplete —
the call sites need route/`dex` threading I got wrong twice — but incomplete-and-red is not landable,
and I had begun guessing rather than tracing. ▶️ **Re-do it with a trace of ONE failure first**, not a
fourth speculative fix. The measurement above is the reason to come back.

---

## 🔴 §SESS-78 — **UNIVERSAL ROUTER FOR V4: THE TARGET IS RIGHT, PATCHING IS NOT VIABLE, AND BUILD-DON'T-PATCH IS THE DESIGN**

Owner chose **UniversalRouter, no API key**. Measured first, and one measurement changed the plan.

### 📊 WHY V4 AT ALL — THE NUMBERS, NOT THE PRINCIPLE
Balances held by the venues we cannot reach:
| token | **UniV4 singleton** | Balancer V2 vault | what we reach on UniV3 |
|---|---|---|---|
| USDC | 65,453,785 | 285,292 | — |
| USDT | 59,357,292 | 61,443 | — |
| **USDS** | **76,178,513** | 0 | **10,928** |
| **GHO** | **2,270,133** | 46,759 | **8,179** |
⇒ **V4 is where BOTH of our unroutable stables actually live** — USDS ~7,000x deeper there, GHO ~277x.
⛔ **Balancer is NOT worth an integration**: 285k USDC total. The earlier framing that lumped them
together was wrong; only V4 carries the value.
✅ **AND SPLITTING NEEDS NEITHER.** `convertTo` already takes ARRAYS and approves per leg, so the keeper
can split one trade across venues we already reach by emitting multiple legs. I had bundled splitting
into the API case; that was wrong.

### ✅ THE ROUTER IS LIVE AND ITS HEAD IS PINNED — READ FROM CHAIN
`UniversalRouter 0x66a9893c…`, `execute(bytes,bytes[],uint256)` = **0x3593564c**. Three live
transactions decoded: `w0` commands offset **96**, `w1` inputs offset **160**, `w2` deadline. Commands
seen: **`0x10`** (a PURE single V4_SWAP — exactly the shape we would emit), `0x0a10`, `0x0a0004`.

### 🔴 AND THE PATCHING APPROACH DIES HERE — MY OWN FAILED DECODE IS THE EVIDENCE
I walked a real `0x10` transaction expecting `SWAP_EXACT_IN_SINGLE`'s fixed 9-word struct and got
**nonsense**: `currency0 = 0x20`, `tickSpacing` a 22-digit number. The reason is the finding:
**actions were `0x070c0e` — `SWAP_EXACT_IN` (the MULTI-HOP variant, carrying a path ARRAY) — and
`params[0]` was 896 bytes, not 288.**
⇒ **UniversalRouter calldata is THREE levels of dynamic nesting** (`execute` → `inputs[0]` →
`actions`/`params` → `params[0]` → struct) **and the action sequence VARIES in real traffic.** There is
no fixed offset for `amountIn` the way there is for 1inch's flat, static descriptor.
⚠️ **THAT IS THE WHOLE DIFFERENCE FROM §SESS-69, AND IT IS WHY THE SAME TECHNIQUE DOES NOT CARRY.**
1inch's `SwapDescription` is a STATIC struct — every field at a computable offset, verified on two live
transactions. Nothing here is. **Patching at an offset I could not decode correctly on the first real
sample would be the phantom-fifth-token defect with a bigger blast radius.**

### ▶️ THE DESIGN: **THE CONTRACT BUILDS THE CALL; THE KEEPER NAMES ONLY THE POOL**
Encode ONE canonical shape on-chain — commands `0x10`, actions `060c0f`
(`SWAP_EXACT_IN_SINGLE`/`SETTLE_ALL`/`TAKE_ALL`), a single-swap struct — from a `PoolKey`
(`currency0, currency1, fee, tickSpacing, hooks`) plus `zeroForOne` supplied by the keeper.
✅ **No parsing, no offsets, no variance, and the SAME safety statement as every other arm:** the caller
names a VENUE, this frame owns the amount and the floor, and the result is bounded on a measured
balance delta. A `PoolKey` is simply the v4 spelling of a pool word — five fields instead of one word,
because a singleton has no address.
⚠️ **BYTE HOME IS THE REAL CONSTRAINT AND IT IS NOT `LevMath`.** Nested `abi.encode` is not free and
`LevMath` has ~222 bytes. Candidates with room: `SwapLib` 1,194 · `Aux` 2,828 · `QuidLib` 8,635 ·
`Core` 13,266. ⇒ **a small dedicated helper reached from `convertTo`**, not more code in `LevMath`.
⛔ **AND IT ADDS A SECOND PINNED CALLEE** (`UNIVERSAL_ROUTER` beside `ONEINCH_ROUTER`) — sanctioned by
the owner, and worth stating plainly because "the callee is pinned, not a parameter" is load-bearing in
every safety argument this lane has made.
⛔ **SUPERSEDED — DO NOT BUILD THIS.** §SESS-86 deleted `V4Lib` as unreachable and §SESS-99 then made
the 1inch generic descriptor actually fill, so v4 is reached through `swap()` with the key rather than
through an on-chain UniversalRouter arm. Kept as the record of what was measured, not as a plan.
📌 The original note read: The hard part is de-risked: the router, the selector, the head layout and the reason
patching fails are all measured. **Do not start it in `LevMath`.**

---

## §SESS-86 — **`V4Lib` DELETED. IT WAS UNREACHABLE, AND THE NUMBER THAT JUSTIFIED IT WAS WRONG.**

The design above was BUILT in §SESS-83 and it never ran. `_hubHop`'s `PROTO_V4` arm cannot be entered:
every caller reaches `_hubHop` only under `hub == 0 || hub >> 253 == PROTO_CURVE`
(`LevMath:1178, 1356, 1380`) and `consolidate` passes a literal `0`, so a v4 word is excluded by the
guard before `_hubHop` looks at it. The keeper cannot send one either — `venue_word(Venue::V4) => None`,
because a singleton has no address to put in a word.
🔴 **AND THE ONLY TEST CALLED THE LIBRARY DIRECTLY**, so a green suite said *"the v4 encoding executes
against the real router"* — true about `V4Lib`, false about the protocol. Deleting it returned **196
bytes** (LevMath 24,357 → 24,161, 415 free).

### ▶️ WHAT IS ACTUALLY MISSING, AND IT IS NOT ON-CHAIN
`Plan.fetched` — *"pre-built calldata for a venue a pool word cannot spell"* — is `Vec::new()` at all
three construction sites. **Nothing populates it.** Neither does anything build a generic `swap()`
descriptor, and `hops` is only ever `vec![w]` or `vec![w1, second]`, so **`unoswap3` is accepted
on-chain and never produced.** ⇒ the contract accepts far more than the keeper can emit: v4, Fluid's
11.36M GHO, Balancer, splits, and the `dai-usds` 0.000% par converter are all reachable in principle
and unreached in fact. **The unfinished half is the producer, not the executor.**

### 📊 COVERAGE, CORRECTED: **10/14, NOT 12/14**
The matrix counted `!venues_for(..).is_empty()`, and `venues_for` returns v4 candidates. GHO and
FRXUSD reach both volatiles ONLY on v4 → `v4 only (UNTRADEABLE)` is now its own cell. USDS and CUSD
have no venue at all. ⚠️ The distinction is load-bearing: *"there is no liquidity"* sends you to find
some; *"there is liquidity we cannot address"* sends you to write an encoder.

### 🔴 A LIVE DEFECT FOUND WHILE TRACING IT
`best_plan_quoted` read `if let Some(w) = venue_word(v)`, so a v4 venue that WON the ranking was
dropped **silently and the direct arm produced NOTHING** — not the second-best V3, nothing. Fixed in
`best_direct`, where the ranking happens: a venue we cannot encode no longer competes.

### ✅ CLOSED IN §SESS-91 — **THE HUB ARM NO LONGER DISCARDS THE SUPPLIED ROUTE.** The branch is gone;
### one `routedSwap` call carries whatever shape the route describes, and `_startsAt` (§SESS-92) hops
### `_hubRowOf` when the route does not begin at the token we are selling. Retained below as the
### statement of the defect, NOT as an open item.
`LevMath:1178, 1356, 1380` pass `""` as the route: when the keeper has no 1inch-reachable hub word, the
stable↔USDC leg takes the on-chain Curve table and **the volatile leg falls back to a single pool
word**, throwing away whatever route the keeper computed. So for every NON-HUB stable a two-hop or
split volatile route is unusable. Not previously written down as a gap.

---

## §SESS-99 — 🔴 **`ZeroMinReturn()`: THE GENERIC ARM HAD NEVER FILLED ONCE**

`LevMath._retarget` wrote `minReturnAmount = 0` into 1inch's generic `swap()` descriptor, deliberately
— *"the aggregate delta floor is the bound"* — and `AggregationRouterV6` **reverts `ZeroMinReturn()`
on exactly that**. The right security design and an impossible call. Every generic-descriptor route
reverted at the router; `convertTo` skipped the leg as an ordinary failure; the conversion returned 0
four frames later. ⇒ **`1`**: satisfies the router's sanity check, leaves the real bound on the
MEASURED balance delta across the whole conversion, which a per-leg `minReturn` cannot express anyway.
📊 It fills now, first time ever: **250,000 USDC → 100.112677 WETH**, and 250k USDC + 250k USDT →
**200.208348 WETH** in one call.

⛔ **WHAT THIS VOIDS.** The generic arm is the ONLY door to v4, Balancer, Fluid and split routing, so
every claim resting on it was untested: §SESS-88's A/B measured QUOTES against a route that could not
execute; §SESS-90 wired `plan_for_lp` to PREFER it, which in production would have sent a reverting
route and degraded silently to a skipped leg; GHO and FRXUSD were never reachable even with the key.

⚠️ **WHY IT SURVIVED A DAY AND THREE WRONG DIAGNOSES** (stale fork pin → dead API key → bad `from`):
**an error path that CONTINUES converts a self-describing failure into an anonymous zero.**
`convertTo` skips a failed leg BY DESIGN so one bad leg cannot void a multi-leg conversion — correct,
and it means a named revert never reaches the assertion. Compounded by `vm.skip(true)` without
`return`, which made an EMPTY route and a REVERTING router produce identical output.

## §SESS-94 — ⭐ **`proto = 0` FILLS: THE UNISWAP-V2 FAMILY WAS ALWAYS REACHABLE**

Executed at FORK_BLOCK 25927822, 25,000 USDC in: **UniV2 9.983 WETH · Sushi 8.480 · V3 control 10.019
under proto 1 · Curve (2) and 3 filled ZERO on every pool, both direction bits.**
🔴 §SESS-22 concluded *"proto = 1 is the ONLY protocol id measured to fill"* — but it only ever tested
CURVE, and the conclusion was generalised to every non-V3 venue. One untested generalisation capped
keyless discovery at UniswapV3 for months.
⚠️ V2 filled only with bit 247 set, and `_deriveBit` skipped every non-V3 word — so that `zeroForOne`
arrived CALLER-SUPPLIED. Deriving it for `proto = 0` is what makes the family safe to admit rather
than merely reachable.

## §SESS-101 — 📊 **THE A/B ON FILLS RETRACTS THE NUMBER THAT DROVE THREE SESSIONS**

    USDC → WETH  $1M    ours 399.007948  ·  1inch 399.653594  ·  +5 to +16 bps
    USDC → WBTC  $100k  ours   1.2677861 ·  1inch   1.2672785 ·  **-4 bps — OURS WINS**

**"+57 to +68 bps to 1inch on WBTC at $1M" does not survive execution.** It was a quote comparison
against an arm that had never filled. Their verifiable edge is single-digit bps.
⇒ this retroactively settles backing out the split executor (§SESS-97/98): framed as a reluctant trade
against 111 bytes of margin, it was simply correct.
⛔ **WE CANNOT FORK-TEST A 1inch ROUTE CONTAINING MAKER ORDERS.** The WBTC routes carry maker
signatures and expiry timestamps (limit-order/RFQ legs) signed against live state; they return zero on
a fork while the pure-AMM WETH route replays fine. Ruled out first: the gas cap (zero at 12M too) and
the EVM version (`prague` made it worse). Any future claim about 1inch execution at size needs a
simulation against live state, not a pinned fork.

## 📌 STILL OPEN IN THIS LANE
· `plan_for_lp` prefers a fetched route on QUOTE; with maker-order routes unverifiable on a fork, that
  preference is unproven at size. Re-measure against live state before trusting it.
· A keeper entrypoint that forgets its route now fails SILENTLY — §SESS-92 replaced the revert with a
  default venue for the RANGE's sake, and one executor cannot tell a range from a forgetful keeper.
  The guard belongs per keeper entrypoint, not in `routedSwap`.
· Coverage is **11/14** (basket is 14, `STABLECOINS`, BOLD last). Holes: GHO, FRXUSD (v4-only) and
  cUSD (no liquidity anywhere — 1inch's own best is −96.8% at $100k, saturating near $3.2k of depth).

---

## §SESS-108 — TWO OWNER QUESTIONS, ANSWERED BY READING THE TREE RATHER THAN BY DEFENDING IT

### ✅ "REDEEM FROM THE 4626 BEFORE CONVERTING" — **ALREADY THE ARCHITECTURE. NOTHING TO BUILD.**
Verified, not assumed: **`LevMath` never reads `vaults`.** `convertShortfall` takes `getStables()` and
`IERC20Min(st[k]).balanceOf(...)`; `_consolidateTo` reads `IERC20Min(s).balanceOf(...)`. Both are the
UNDERLYING. The only `IERC4626.redeem` sites are `FeeLib:316/372` (fee payout) and `BasketLib:1361`
(a BLOCKED vault being drained and re-spread across healthy ones) — none of them hand shares to a
route. ⇒ the routing layer cannot see a staked token, so there is no staked token to find liquidity
for. cUSD/crvUSD/frxUSD are quoted and routed as the underlying throughout, which is why the coverage
matrix tests `0xf939E0A0…` (crvUSD) and not scrvUSD.
📌 The instruction was right and the tree already implements it; recorded so it is not re-opened.

### 🔑 "DELETE THE TABLE" — **AND THE ELEGANCE TEST SAYS KEEP IT, FOR A REASON I HAD NOT GIVEN**
The owner asked for `_hubRowOf` to go once consolidate had hop words. I have twice defended it on the
narrow ground that `protectFromQuid` is permissionless. That is true and it is the WEAKER half.
⭐ **THE TABLE IS THREE THINGS AT ONCE, AND ONLY ONE OF THEM IS AN EXECUTOR:**
  1. the keyless stable↔USDC **executor** for `consolidate` and for `_startsAt`'s hop (§SESS-92);
  2. the keyless **quote** — `_curveQuote` → `_selfServableQuote`;
  3. 🔴 **the FLOOR's only keeper-independent price reference.** `_selfServableQuote` is *"what this
     contract could get for itself, without a keeper"*, and `_consolidateTo` takes
     `max(swapFloor, _selfServableQuote·(1−20bps))`. Delete the table and the floor collapses to a
     pure TWAP read with no second opinion — on the one path an anonymous caller can invoke per slice.
⇒ six compile-time rows serving all three is the ELEGANT shape; deleting them needs three
  replacements, one of which is a price source the contract can vouch for itself. **A single constant
  doing three jobs is not duplication — it is the absence of it.**
⚠️ And the owner's caution was right: the pool word went because it was a SECOND, CALLER-SUPPLIED
venue channel that duplicated `Plan::route_bytes`. The table is neither caller-supplied nor
duplicated. Removing the word and keeping the table is one decision, not two in tension.
