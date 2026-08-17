# SPRINT — what two sessions leave open

⚠️ **TWO SESSIONS WRITE HERE.** Part A is session `d669393d` (band-manager merge, bytecode).
Part B is session `391df7b6` (the Bitcoin/secp256k1 thread). Kept in ONE file deliberately:
two sprint files drift, and this repo has paid for that twice today.

---

## PART A — session `d669393d`

Written at `770749ca`. **Every item below is work this thread started, scoped, or measured but did
not finish.** Each carries its evidence and, where I got something wrong, what corrected me — because
the wrong turns are cheaper to inherit than to rediscover.

`QUEUE.md` remains the status list of record. This file is the *ordered* remainder for one thread to
pick up, with the blockers named. Where a row here duplicates a `§E…` id, the QUEUE row is canonical
and this is the summary.

---

## 0. Read this first — the two rules this session paid for

**MEASURE BYTECODE, NEVER ESTIMATE IT FROM LINE COUNTS.** I predicted library extraction would
*cost* bytes, from body sizes. Measured, it frees **~100 B per small body (2–5 lines) and ~514 B per
large one (10–13 lines)** — flat in length, because solc's output carries slot arithmetic, bounds
checks and stack shuffling that source does not reveal. This overturns `CLAUDE.md`'s standing note
that "neither abstract-base hoisting nor delegatecalled-library extraction removes meaningful
bytecode": hoisting into an **abstract base** genuinely does nothing (+41 B, measured — the bodies
are copied into every inheritor); moving into a **delegatecalled library** removes them from all
callers. Same code, opposite sign.

**A BASE CLASS IS NOT FREE — WEIGH WHAT IT CARRIES.** Standing rule 8 says don't hand-roll what a
library does. Applying it to `VBtc` cost **+1,195 bytes and three new signature-verifying
entrypoints** (`permit`/`nonces`/`DOMAIN_SEPARATOR`), because solmate's `ERC20` is ERC20 *plus*
EIP-2612 — on a token ibiza records as one "NOBODY EVER HOLDS". Reverted. Rule 8 still holds; it
just is not the only term.

---

## 1. 🔴 §E255 — ONE BAND MANAGER, TWO `Shares` INSTANCES

**The architecture this thread was driving toward** (owner, 2026-08-17): *"vogue must control two
shares contracts that each do their delever etc for each band, calling each lev library it needs."*

Today the share **face is implemented three times instead of instantiated twice** — inline in
`Vogue`, as `VBtc` for BTC, and in `Shares` (unwired). That is the duplication, and it is the same
`isBTC` argument one level up from `Core`, which already **is** one implementation with two instances.

**Already in place:**
- `BandState` (§E252) — 13 declarations shared, so both bands lay out **identically**. This was the
  precondition, and it is done.
- `LevBookLib` (§E246) — the four venue legs, parameterised by collateral token.
- `Core` — the working precedent for one implementation, two instances.

**🔴 THE BLOCKER IS SEMANTIC, NOT PLUMBING.** `Shares.totalSupply()` returns `lpShares + oorShares`
and spans both position kinds (*"disjoint by construction … the sum cannot double-count"*).
`Vogue.totalSupply()` returns `lpShares` alone, and **`oorShares` does not exist in `Vogue` at all**
— out-of-range positions are absent from the share supply. The owner's design says totalSupply
*includes* the out-of-range locked liquidity. Instantiating `Shares` twice **adopts its semantics and
changes what every ERC-20/4626 client reads.**

▶️ **Settle the `totalSupply` semantics first.** It is the same decision §E251 turns on.

---

## 2. 🔴 §E251 — vBTC MINT SCOPE

`VBtc.mintTo` has **exactly one call site** (`Vault:333`, inside `exposeBtcToLev`), so the entire
vBTC supply is the levered slice. `outOfRangeBtc` mints none. The design is broader: band BTC
*including* the out-of-range locked portion should be mintable and lendable on Morpho, subset-
accounted so it is not double counted.

⚠️ **DO NOT WIDEN THE MINT WITHOUT GENERALISING THE SUBSET MARKER.** `vbtcExposeBody` guards
`sats <= plainNet(pooled, levPooled)`. A second consumer minting against the same `pooled` with its
own counter would **pass that guard** while the two jointly over-mint — the double count arrives
*through* the guard, not around it.

**Three questions before any code:** which band BTC is eligible (in-range depth may have to stay
unmintable because it must remain deliverable to swappers); whether one marker or two (an LP could be
lev-exposed *and* lent-out, and `plainNet` assumes one); and what happens to lent-out vBTC when the
band needs that BTC for a swap or close — §V-R10's deliverability question in a new place.

✅ **Verified adjacent (§E250):** the levered slice is **not** double-counted today. All six
consumers use `plainNet(pooled, levPooled)`, which *subtracts*; none adds. Withdrawal is capped at
`plainNet`. The invariant is written down because nothing in the type system prevents a future
`pooled + levPooled`.

---

## 3. 🔴 §E244 — THE ATOMIC HEDGE'S REMAINING TESTS

`LevCascade`'s `NoVolatileRoute` failure is **gone** — the pinned pool restored the ETH hedge, and
`VBtcLevFeeLane` is back to its 19/2 baseline with `testReal_WbtcLev_FoldUp_Then_FlashDelever`
passing. What remains is the tests that assert on a *lever actually executing*.

▶️ Either wire a mock router, or assert `vm.expectRevert(NoVolatileRoute.selector)` so they state the
current truth. ⚠️ **The unacceptable resolution is a tolerance that makes them pass** (rule 4).

---

## 4. 🔴 §E247 — THE ALLOWLIST DETECTION GAP

`rebalanceWbtc` was **never** in `HOP_SIGNED_FN_SIGS`, and the enclave policy **fails closed** — so
every WBTC-mode atomic rebalance the keeper attempted was refused at the signing chokepoint. Fixed.

**The gap is not.** Nothing gates *"every selector the keepers BUILD is in `HOP_SIGNED_FN_SIGS`"*.
`check-client-abis.py` catches renamed/deleted selectors but **structurally cannot** catch one that
is correct on-chain and merely absent from a policy list. The check is mechanical: enumerate
`selector4("…")` literals across `quid-ln/`, diff against the allowlist.

⚠️ This is §E237 inverted — there the allowlist named a **dead** selector; here it **omitted a live**
one. Both are allowlist-and-builder drift, and neither is visible from either file alone.

---

## 5. 🔴 §E249 — AUDIT THE OPEN/CLOSE ASYMMETRY *CLASS*

`closeBtcLev` burned vBTC that was never minted and never returned the LP's WBTC, because
`openBtcLev` **branches** on venue collateral and the close did not. Fixed.

**The class is not audited.** Grep every other open/close pair for an **entry path that discriminates
on venue collateral while its exit path does not**.

⚠️ The reason it survived: the sole `closeBtcLev` test — added because that function *"had ZERO test
callers"* — opens a **vBTC** position. **The branch that was broken is the branch the test does not
take.** A function having "a test" is not coverage of its branches.

---

## 6. 🟡 THE MANAGER MERGE — REMAINING EXTRACTION

🔴 **CORRECTION, ADDED 2026-08-17 AFTER RE-MEASURING — THIS SECTION AS FIRST WRITTEN MADE THE MERGE
LOOK REACHABLE AND IT IS NOT.** `LevManager` **22,830** + `BtcLevManager` **17,278** = **40,108**
against the 24,576 limit: **the folded contract is 15,532 bytes OVER.** Extracting *every* body named
below is worth ~5,000, which leaves **~10,500 still over**. ⇒ **EXTRACTION ALONE CANNOT LAND THIS
FOLD**, and any plan that treats §6 as the remaining distance is wrong by a factor of three.

⚠️ **THE FIGURE MOVES, SO RE-MEASURE IT — DO NOT QUOTE THIS ONE EITHER.** The same gap read
**19,443** on 2026-08-16; the extractions that landed since closed ~3,900 of it. That is real
progress on a distance that is still not crossable this way, which is exactly the shape that makes
a stale number dangerous: it flatters the trend and hides the ceiling.

⇒ **THE FOLD IS BLOCKED ON MOVING STATE OUT, NOT ON MOVING BODIES OUT** — see §6b, and
`ONE-ENGINE-TWO-SHARE-TOKENS.md`, which is the measured state map for precisely that.

Measured rates make the extraction itself costable rather than aspirational.

| target | count | worth at measured rate |
|---|---|---|
| `LevManager`'s own bodies (`openLev` 20 lines, `deleverToVault` 19, `_rebalanceBody` 16, `_closeLev` 15) | 34 | **~5,000 B** |
| `LevBase` bodies still movable | ~7 | small (1–5 lines each) |
| `LevBase` bodies **structurally blocked** | 16 | — |

⚠️ **THE CEILING IS A PROPERTY OF DELEGATECALL, NOT A PREFERENCE.** A library body cannot read the
caller's **immutables** (they live in its *code*, not storage) nor call its **virtuals**. Values must
be computed by the wrapper and passed **by value**. `totalNetEquity` *loops* a virtual per LP and
cannot move at all. And `_syncBand`'s **ordering** is load-bearing — the band poke must follow the
venue state move — so it stays in the wrapper.

`LevManager` is the tightest of the pair at **1,746 bytes** of margin.

---

## 6b. ✅ `contract Shares` — DELETED 2026-08-17, ON THE OWNER'S RULE

**Owner, 2026-08-17, closing this thread: *"anything that is unwired and dead code either needs to be
wired all the way or deleted."*** Wiring it fully **is** §E255, which the owner is taking themselves,
so the prototype goes. **`BandState` — the shared base, and the half that is actually wired
(`Vault.sol:16`, `Vogue.sol:22`) — STAYS.** `Shares.sol` is now 88 lines of base and nothing else.

▶️ **TO RESURRECT IT: `git show 5ada37f4:evm/src/Shares.sol`** (or any commit before this deletion).
It was a written specification of the fold's target shape, not scratch work, and recovering it costs
one command — which is the whole reason deleting it is cheap and leaving it was not.

⚠️ **AND KEEP THE MEASUREMENT BELOW, BECAUSE IT IS THE PART THAT DOES NOT COME BACK FROM `git show`.**

**What it was:** `Shares.sol:90` declared `contract Shares is BandState` — **2,300 bytes of concrete
contract that nothing deploys, imports, or tests.** Only `BandState` was imported (`Vault.sol:16`,
`Vogue.sol:22`). `git grep` for `new Shares`, `Shares ` as a type, or `{Shares}` returned **nothing**.

⇒ **RIGHT NOW IT IS A STANDING-RULE-1 VIOLATION** — unreachable code kept "for later" — and it is
simultaneously the scaffold for moving `Vogue`'s 525-line share/position cluster out. Those are not
in tension by accident: **it is a marker for a gap that has not opened yet**, the same shape as
`create_sweep_tx` and the deleted `IBtcVault`, and this repo has twice deleted such a thing and twice
restored it. **Do not delete it as litter. Either wire it or record why it waits.**

✅ **THE QUESTION IS ANSWERED — owner, 2026-08-17: *"yes it's better to use that base."*** I had asked
whether `Shares` should exist at all or `BandState` should stand alone. It exists, it is the base, and
its `totalSupply() = lpShares + oorShares` is the semantics that survives (§E256). ⇒ **out-of-range
locked liquidity IS part of the share supply**, which is also what `ONE-ENGINE-TWO-SHARE-TOKENS.md`
recorded in the owner's own words on 2026-08-16 — *"the remaining totalSupply being outOfRange"*.

### The other two unwired things — CHECKED, AND NEITHER IS DELETABLE

The owner's rule is "wire it or delete it", so I swept `evm/src` for every declaration with zero real
references (excluding its own declaration line, import paths, and comments). **Exactly three came
back, and all three are now deleted** — `contract Shares`, `interface ISkewSink`
(`Interfaces.sol:540`, fully superseded: `Core.sol:367` calls `creditSkewPremium` through
`IBandManager`, and both managers implement it), and `library Interfaces {}` (a literal empty
no-op that existed only to produce an artifact).

**Two more libraries have NO production caller, and I did not touch either. Both have evidence saying
not to** — this repo has deleted a caller-less function as litter and had to restore it **twice**:

| | status | why it stays |
|---|---|---|
| `ExternalTwap` | tested (`OneInchObserverIsIndependent.t.sol`), **no production caller** — `Core.sol:1280` names it in a **comment only** | It **is** the §E222 fix: the oracle ring currently records its own output, booked 🔴🔴 and live on `main`. **Deleting it deletes a written security fix**, and wiring it is a money-path change in the other session's lane (Part B, §B1). |

⭐ **AND CHECKING IT OVERTURNED SOMETHING I WROTE EARLIER TODAY, IN §E222's FAVOUR.** I had recorded
that the reversal of the 1inch integration (§E248/§V-R1) orphaned E222's independent non-Chainlink
price source. **It did not, because those are two different 1inch contracts:**

- **AggregationRouterV6 `0x111111125421cA6dc452d289314280a0f8842A65`** — the **swap venue**. That is
  what was wired and withdrawn, and the one that would have needed an HTTP quote client.
- **OffchainOracle `0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8`** — a **read-only `getRate`
  staticcall**. That is what `ExternalTwap.oneInchRateWad` already calls, and **the router address
  appears nowhere in `ExternalTwap.sol`** (grep: 0 hits).

⇒ **§E222's price source needs nothing from the withdrawn work** — no aggregator, no API key, no
off-chain client, no `bytes route`.

⛔⛔ **AND THEN I GOT THE NEXT STEP WRONG TOO. I wrote that this makes it "one staticcall to a
contract that is live today". It does not — the call COSTS MORE THAN A BLOCK.** Another session had
already measured it: `OffchainOracle.getRate` iterates **all 14 registered DEX oracles and their
connectors**, so one read is a full multi-venue aggregation — **31,722,803 gas against a 30M block
limit**. They wired it, saw every ETH swap and repack exceed a whole block, and reverted
(`82662f19` → `df3c5e13`). **Their row never reached `main`; I found it as an unreachable commit
and landed it as `§E232-1inch-is-unusable-on-chain`.**

▶️ **THE VIABLE SOURCE IS `ExternalTwap.curvePriceWad`** — a Curve `price_oracle()` storage read at
~2–3k gas, and a genuinely different *mechanism* from Chainlink (an EMA over executed trades vs a
signed off-chain report). Its open questions are its own: which pool per instance, and a deviation
bound derived from Curve's EMA **half-life** rather than inherited from a 30-minute-window bound.

🔴 **THE LESSON IS SHARPER THAN THE FIRST ONE, BECAUSE IT IS THE SAME MISTAKE ONE LEVEL DOWN.** I
corrected "reasoned from the vendor's NAME instead of the ADDRESS" — and then reasoned from the
ADDRESS **without pricing the CALL**. Deployed, correct and unit-tested says nothing about whether
invoking it is affordable. ⚠️ **And the refutation was inside the passing test the whole time:** the
run that proved `getRate` works is the run that printed 31.7M gas. **A green test whose gas number
exceeds a block is not a pass — it is a design refutation wearing a green tick.**

⚠️ **The original error, kept because it is still worth avoiding — reasoning from the vendor's NAME
instead of the ADDRESS**:
"1inch was removed" is true of one of these and false of the other, and the two sit one letter apart
in prose. Same shape as this repo's rule about auditing by structure rather than by type name.
| `FixedRateFill` | tested (`FillAndBatch.t.sol`), **no production caller** | Its own landing commit says so on purpose — `5d710605`: *"the fixed-rate fill, **unbuilt and with no callers**"*. It is the settlement primitive meant to replace the v4 AMM (§28, Phase 3 step 1). **A marker for work not yet built, which is exactly the `create_sweep_tx` shape.** |

⇒ **"No caller" is not the test; "no caller AND no reason" is.** The three I deleted had neither a
caller nor a job. These two have a job that has not been wired yet, and the reason is written down in
a commit message or a queue row — one `git log -S "<symbol>"` away, both times.

▶️ **THE ORDER THIS FIXES.** §6's arithmetic says bodies cannot close a 15,532-byte gap. **State can:**
wiring `Shares` moves the share/position cluster **out of both managers at once**, and it is the only
lever measured to be large enough. So the sequence is **wire `Shares` → then fold**, not fold-then-tidy.

---

## 7. 🟡 §E242 — REMAINING DE-INLINING CANDIDATES

An **internal-only** library is copied into every consumer; making it `external` deploys it once.
`BitcoinTx` proved it: **−1,985 B across four consumers**, and `BTCChannels` went 144 → 815 bytes of
headroom, moving the binding constraint to `Vogue` (558).

⚠️ **Only pays with MULTIPLE consumers.** Measured: `ShareMath` 2 consumers but ONE function of 29
lines (marginal); `SortedSetLib` 1 consumer (converting would **add** a seam and save nothing);
`ExternalTwap`/`FixedRateFill` 0 consumers — see §E243/E222, they are *unwired*, not
inlining-expensive.

---

## 8. 🟡 RESIDUAL SLOP (compiler-enumerated)

Unreachable-code warnings are at **0** (were 12; −2,652 B on `LevMath`). Remaining in `src`:

- 8 unused function parameters
- 6 unused locals
- 7 shadowed declarations
- 7 duplicate-name declarations
- 3 unchecked low-level calls
- the stock `approve` body, **triplicated byte-for-byte** across `Shares`/`Vogue`/`VBtc` — the fix is
  a *minimal* shared base (no permit), **or nothing at all if §E255 lands**, which deletes the
  duplicate face outright. Do not build it twice.

---

## 9. 🟡 A CLEAN FULL-SUITE NUMBER

Per-suite runs on the **ANKR archive key** are clean (`VBtcLevFeeLane` 19/2 = session baseline). The
last *full* run was on the rate-limited public endpoint and **is not quotable**: six `setUp` failures
were HTTP 429, which knocked out three whole suites and 11 tests.

⚠️ **A CLI `ETH_RPC_URL=` OVERRIDE SILENTLY LOSES TO FORGE'S DOTENV LOADING.** Edit `evm/.env`
(gitignored) to point `ETH_RPC_URL` at `ANKR_RPC_URL`, then run. Attribution held all session:
**57 shared pre-existing failures, 0 introduced.**

---

## 10. 🟡 OTHER OPEN THREADS THIS SESSION TOUCHED

- **§V-R11** — untouched. An all-or-nothing swap **reverts** rather than partially filling.
  Aggregation makes tracking *deeper*; partial fill makes it *robust*. Both are needed, and a pinned
  pool does not close it.
- **§E235-spa** — `evm/deployments/l1.json` has no `btcCore` key. `DeployL1_s` now writes it, but
  that file is **regenerated by a deploy run** and must not be hand-edited (CREATE addresses are
  `f(deployer, nonce)`). Until a deploy rewrites it, `vogueCoreBtc` resolves to ZERO and the BTC
  panels are down **by construction** — loudly, which is the correct failure. Close only after: run
  the deploy, confirm `btcCore` ∈ `l1.json` and ≠ `core`, re-run the ABI gate.
- **§E238-scan** — `AttestedHopRegistry.sol` was deleted by `812e6822` ("Attestation is fully phased
  out") *after* another thread banked it for §E111. Settle whether that **supersedes** §E111 or
  merely removed an implementation of it. Cheap question, nobody has asked it.
- **§V-R1 / routing** — the aggregator path was **abandoned in favour of a pinned pool** (see §11).
  `ROUTING-AGGREGATION.md`'s "band first, then 1inch" describes **user** flow and must not be applied
  to lever flow: `BtcLevManager:36` — *"Acquisition is EXTERNAL (never the swap-out rail → the band
  is never traded → no encroachment on other LPs)."*

---

## 11. WHAT LANDED, SO NOBODY REDOES IT

**10,461+ bytes freed**, binding constraint moved from `BTCChannels` (144 → 815) to `Vogue` (558).

| change | effect |
|---|---|
| SOR deleted whole (unreachable: `onlyUs`, no protocol caller, `arbETH` already gone) | `Aux` −1,959 |
| TriCrypto out; volatile venue **pinned** to Uni V3 | `LevMath` −1,267 |
| unreachable code, 12 sites → 0 (two **pre-existing** rule-1 violations) | `LevMath` −2,652 |
| `BitcoinTx` de-inlined across 4 consumers | −1,985 |
| mock ERC20 deleted (inert since the v4 cut) | `OracleLib` −4,187, 2 fewer genesis deploys |
| 15 inlined duplicates + 4 venue legs → `LevBookLib` | `LevManager` −480, `BtcLevManager` −3,044 |
| `RING` 1024 → 256, raw slots 1030/1031 → 262/263 from `forge inspect` | layout |
| `BandState` — 26 declarations → 13 | **+11 B**; buys layout alignment, not size |
| clients repaired | 11 SPA signatures, 2 Rust selectors |

**The venue choice is measured, and the measurement is the reason it works:** Uni V3 USDC/WETH 0.05%
holds **32,497 WETH** and WBTC/USDC 0.30% holds **262.9 WBTC** — **46×** and **12.7×** TriCrypto's
698 WETH / 20.72 WBTC, which breached the 1% floor between $10k and $25k. **TriCrypto's failure was a
DEPTH problem; a deeper pool solves it and an aggregator was never required.** Re-check that depth
before trusting the pin again — a pinned pool *can* be thin at size, and that is the standing cost.

**The keeper's scope stayed minimal because of it:** it passes nothing, encodes nothing, fetches
nothing. No signature changed, so **ABI gate 0 Rust / 0 SPA**. The abandoned aggregator design would
have required an HTTP client, API credentials, an outage mode, a staleness window, `bytes route`
threaded through two managers and three structs, an ABI break on four entrypoints, and a nested
`bytes[]` encoder in Rust.

---

## 12. PROCESS NOTES WORTH INHERITING

- **Trace, do not theorise.** Three wrong diagnoses this session; one `-vvv` trace settled each in
  one run. `ERC20: transfer amount exceeds balance` inside Morpho's flash pull was **three frames**
  from its cause (a missing `_toUsd18` and a missing `10_000/(10_000-slip)` over-withdraw).
- **RESTORE FROM `git show`; DO NOT REWRITE FROM MEMORY.** I deleted three bodies writing *"restore
  from git history; it is not lost"*, then reconstructed one from the pattern. It dropped a unit
  conversion (1e12) and a slippage headroom factor.
- **Regex editing failed three times** — a 40-minute backtracking hang, a cross-line over-match
  (`[^;]*?` spans newlines), and a `count=1` replace against a file I had just modified, which
  emptied the base I had just inserted. Use `Edit` (errors when the anchor is missing) or line-based
  brace counting.
- **Grep the QUEUE before booking.** I re-booked an existing 🔴🔴 row at lower severity (§E243 vs
  E222) having greped only the code. And search **both** `§E111` and `E111` — trackers drop the sigil.
- **Four vacuous tests found.** Two compared an expression to itself; one asserted `selector4(s) ==
  keccak256(s)[..4]` for the same `s`; one asserted `assertEq(dust, 0)` on tokens nothing ever
  minted. All four passed for reasons unrelated to what their names claimed.


---

## 13. THE FIVE-DAY SWEEP — what I re-checked, and what closed itself

Added 2026-08-17 on the owner's question *"what else did this thread work on before but not finish"*.
I scanned 2026-08-13 → 08-17 of this session's own transcript for deferral statements with a concrete
anchor, then **re-measured each against today's `main` rather than trusting what I wrote at the time.**
That order matters: **five of the eight had already been closed by later work in this same session,
and I would have re-opened every one of them by reporting from my own notes.**

**STILL OPEN — and the first two were absent from this document entirely:**

- **`contract Shares` unwired, and the fold gap** — §6b and the §6 correction above. The big one.
- **14 v4 references remain in `evm/src` + `evm/script`, and every one is PROSE.** No `IPoolManager`,
  `SafeCallback` or `_unlockCallback` survives in code — the cut is complete and the comments are not.
  ⚠️ Per `CLAUDE.md`, **a comment describes past state**, and four wrong conclusions in this repo have
  come from trusting one. Fourteen comments still describe an architecture that was removed.
- **The ABI gate is RED on `main` itself, and it is not from this thread.** `openChannel` at
  `quid-ln/quid-hop/src/evm_codec.rs:78` still encodes `(bytes32,bytes)` where the contract now has
  `(address,bytes32,bytes,bytes)`. Committed on both sides — the Rust line is byte-identical in HEAD
  and in the working tree, so it is **not** the BTC thread's uncommitted edit; the contract change is
  `7d11fe22` ("E183 item 1 lands: the LP signs nothing on the EVM"). **Flagged, not touched — it is
  another thread's live lane.** But it means the gate cannot currently certify anyone's commit.

**CLOSED BY LATER WORK IN THIS SAME SESSION — verified on today's `main`, not assumed:**

| what I wrote, and when | state today |
|---|---|
| *"366 `isBTC` references, 182 in `Core.sol` alone — 53% in one file"* (08-15) | **36 total.** `SwapLib` 17, `Vogue` 8, `Vault` 3, `Interfaces` 2, `Shares` 1. **Core: zero.** |
| *"`Core` still carries BOTH bands' state — `obsBTC`/`obsETH`, `_flowBTC`/`_flowETH`. That's the unfinished half"* (08-16) | **Zero matches in `Core.sol`.** |
| *"the `LEV_MANAGER` duplication — one fact with two homes"* (08-14) | **Dissolved by `BandState`**: one declaration (`Shares.sol:62`), inherited by both. |
| *"`#32` — the per-LP `COLLATERAL()` STATICCALL inside two loops"* (08-13) | **Not in any loop.** Three single-shot branch sites remain. |
| *"`Alles` inherits `Fixtures` while using not one member of it"* (08-17) | v4 `Fixtures.sol` **gone**. ⚠️ `evm/test/SPVFixtures.sol` is a **different, live** file — Bitcoin header fixtures for `SPVGateway.t.sol`. **Similar name, unrelated thing: do not delete it on the strength of that note.** |

⇒ **THE LESSON, AND IT IS THE SAME ONE AS §12'S FIRST BULLET.** My own transcript is a record of what
was true when written, and it goes stale faster than anything else because *I* am the one invalidating
it. **Every item above that I could still see was one I re-measured; every item I "remembered" was
wrong in the direction of being more open than it is.** A hand-off document assembled from notes
rather than from the tree will re-open finished work and under-report the one gap that matters.

---

## 14. 🔴🔴 THE BRANCH CLEANUP LOST HALF A COMMIT — RESCUED, NOT YET RESOLVED

**Found 2026-08-17 while auditing every open `QUEUE.md` row. This is the one item in this document
that is a LIVE RISK created BY this thread rather than merely left open by it.**

This thread deleted every branch and backup after *"verifying the content landed"*. **That check was
run per BRANCH and the loss was per FILE-KIND.** `origin/worktree-rover-weeth-ship-decision` held
three hand-authored commits (`288b9f2`, `f6c3a9f`, `61b1fbc` — §E194). After deletion they were
reachable from **no branch and no remote**, and are **not ancestors of `origin/main`**: unreferenced
objects, one `git gc` from gone.

▶️ **RESCUED: pushed as the tag `rescue/E194-rover-open-14-18`**, verified on the remote, all three
reachable. **Do not delete that tag until the question below is answered.**

**Why the original check passed anyway:**

| half of `61b1fbc` | landed? |
|---|---|
| the **doc** half — `OPEN 14`…`OPEN 18` | ✅ all five present in `main`'s `QUEUE.md` |
| the **code** half — `evm/src/imports/SwapLib.sol` | ⛔ **never landed** |

The code half halved `BAND_FRAC_WAD`: *"IT IS HALF THE BAND WIDTH, NOT THE WIDTH … it credited twice
what the band can actually charge and made the skew **UNDER-collect by ~10bps on every trade above
the band**"* — carrying the derivation that average execution across a traversal is the **geometric
mean** of pre- and post-trade marginal price, `1 − (P_a/P_b)^(1/4) ≈ δ/2`, control-validated against
the v3 whitepaper's own 200× and 2000× capital-efficiency figures.

⚠️ **`BAND_FRAC_WAD` DOES NOT EXIST ON `main`.** `8dc68cf0` rebuilt the well skew, `29f0cb01`
reverted that rebuild to the known-green state, and the constant left with it. ⇒ **DO NOT RE-APPLY
THE DIFF** — it patches something that is gone.

🔴 **THE SURVIVING QUESTION IS A MONEY-PATH ONE:** does today's skew formula credit the swapper for
band slippage at all — and if it does, does it credit the **full width** (the ~10bps under-collection
this commit found) or the **half**? Re-derive against the current formula; do not assume the revert
carried the correction with it.

⇒ **THE TRANSFERABLE RULE: "the content landed" must be verified PER FILE-KIND, NOT PER COMMIT.** A
commit touching docs *and* code can have its docs arrive through somebody's later edit while its code
never does — and grepping for the prose finds precisely the half that survived, which is what makes
the check feel conclusive when it is not.

---

## 15. THE QUEUE AUDIT — 165 open rows, mechanically scored

Every row in `QUEUE.md` carrying 🔴 / 🔴🔴 / 🟡 / 🟢 / ⏸️ was extracted (**165 of 663 row-shaped
lines**), its backticked symbols and paths pulled out, and each tested against a set of **31,430
distinct identifiers** built from `evm/src`, `evm/script`, `evm/test`, `quid-ln`, `tools` and
`spa/src`. A row every one of whose cited symbols has vanished is a row about deleted code.

**Result: the queue is largely honest — only two rows were stale-open, and both for the same reason.**

- **§E109** and **§E116** → ⛔. Both are about `AttestedHopRegistry`; `812e6822` (*"Attestation is
  fully phased out"*) deleted the contract, and `setMrenclave`, `revokeHop`, `expectedMrenclave`,
  `hopMrenclave`, `setHopRegistry`, `onlyGovernance` now return **zero hits** repo-wide. ⚠️ **The
  governance question underneath them did not die with the contract** — if enclave identity is pinned
  anywhere today, *"can one compromised key change which code is trusted, in one tx, with no
  timelock?"* moved with it. Booked at §E238-scan, which is the open reconciliation with §E111.
- **§E194** → the rescue above.

### The same audit run over this thread's OWN transcript — one open hazard, closed by measurement

The 21+ commits and the whole pre-08-13 half of this session were swept the same way: deferral
statements paired with a symbol that **still exists in the tree** (a symbol that is gone means the
work was superseded). **70 survived that filter, and every one is already booked in `QUEUE.md`** —
`§A.55`, `§A.56` part 2 (row B8, `OorArgs` vs inline), `§A.57`, `§A.58`, `_take`, `SweepAuth`,
`JIT-DEPTH §2`, `deliverableETH`, `closeLevFor`/#109, `forceDeallocate`, `_reconcileLev`, `C10`. ⇒
**nothing this thread worked on is missing from both documents.**

🔴 **EXCEPT ONE, WHICH WAS A LIVE ACCESS-CONTROL HAZARD AND IS NOW CLOSED BY MEASUREMENT.** On
2026-08-12 I flagged, twice, that a stashed version of `supplyFromAux` **dropped its gate** —
`if (msg.sender != address(AUX)) revert NotAux();` — and warned that removing an access gate during
a cleanup is how a permissionless entrypoint ships. **Verified on `main` today: the gate is present,
`Vogue.sol:177`.** The stash version never landed. ⇒ **Closed — and closed the only acceptable way,
by reading the line rather than by reasoning that it was probably fine** (rule 13: a dismissal needs
the same evidence as a finding). ⚠️ Worth keeping the shape in mind: the hazard was never in a
commit, only in a stash, so **no diff review would ever have surfaced it** — it was visible only
because the flag was written down at the time.

### The two scans the owner asked for, run properly this time

**(1) EVERY UNREACHABLE COMMIT, not just §E194's.** `git fsck --unreachable --no-reflogs` returned
**449 commits**. Dropping stash triples, merges, and commits whose subject already appears on `main`
(rebase copies) left **22 hand-authored ones**. Each was checked by looking for its *content* on
`main`, not its SHA:

| | |
|---|---|
| landed under another SHA | **21** — E154's avgYield row, `LevBase`'s `totalDeliverableDollars`/`TWAP_WINDOW` lift, `DEPLETION_RATE_WAD`, the E182 rekey's 523-byte figure, `DeployL1_s`'s `btcCore`, the `USDC` declaration, E231's row |
| superseded by a later deliberate deletion | `VEth.sol` / `LevOracles.sol` restores — both later folded away on purpose |
| 8 × "WIP snapshot … NOT REVIEWED, NOT for merge" | backups by design |
| **LOST** | **1 — `§E232-1inch-is-unusable-on-chain`** |

⇒ **The branch cleanup was 21-for-22 on code and lost one 🔴🔴 row** — now landed, with
`rescue/E232-1inch-unusable` and `rescue/E222-revert` pushed as tags.

**(2) EVERY DELETION, to see whether §E109/§E116 were the only rows closable that way.** All **35
deleted `.sol` files** in `evm/src` were enumerated from history and each cross-referenced against
the open rows: `AaveV3Venue` `AaveV4Venue` `BandBacking` `BatchLedger` `EthVenue` `EulerEscrowVenue`
`SOR` `LevOracles` `LiquityTroveVenue` `MorphoEscrowVenue` `QuidLens` `Rover` `SorExchange` `VEth`
`mock` `AttestedHopRegistry`, plus the 13 v3 `TickMath`/`LiquidityAmounts`/`FullMath`/pool-interface
files.

**Answer: yes — `AttestedHopRegistry` was the only one.** Every other deleted name that still appears
in an open row appears there **incidentally**, not as the row's subject: §E155 is about
`BasketLib._valueStable:265` (alive), §E201 about the oracle posture, `VENUE-COLLAPSE-REFUTED` about
four branches. ⭐ **And every surviving mention of a deleted contract inside `evm/src` is a COMMENT
recording the deletion and why** — `Aux.sol:201` on `SorPath`, `Vogue.sol:1323` on the `VEth`
premise, `ExternalTwap.sol:27` on `TickMath`. That is the good case: prose that outlives the code
**on purpose**, and the exact opposite of the stale-comment failure this repo keeps paying for.

⚠️ **WHAT THIS METHOD CANNOT DO, stated so the number is not over-read.** Symbol-existence closes a
row only when the row is *about a symbol*. Rows about a **behaviour**, a **measurement**, or a
**decision** cite live code and score "still open" whether or not the work is done — so **165 minus
these is not "163 confirmed open"**, it is "163 not closable by this test". The false-positive
direction was checked too: most flagged tokens were commit SHAs, `file:line` fragments, `T/4`, and
gitignored paths like `evm/.env` — noise, not deletions.

---

# PART B — session `391df7b6` (the Bitcoin / secp256k1 thread)

**Ordered by what it protects, not by how nearly finished it is.** Item 1 is worth more than
everything below it combined, and I spent the session around it rather than on it — that is the
single most useful thing to inherit from here.

`QUEUE.md` stays canonical. Where a row below names a `§…` id, that row is the record and this is
the summary.

---

## B0. ✅ CLOSED — THE FLEET NO LONGER BOOTS A VAULT (`99fda5e9`)

**`quid-ln/quid-bridge/src/bin/quid-bridge-daemon.rs:339` still calls
`quid_bridge::vault::derive_vault_seed(&root_seed)`**, and `vault.rs` still says it in its own
words: *"one custodian, one secret"* and **"SO THE 2-of-2 IS NOMINAL IN THIS DEPLOYMENT, AND
NOTHING SHOULD CLAIM OTHERWISE."**

⇒ **A compromised fleet enclave can spend every channel's funding output.** No Solidity change
touches this; the Bitcoin UTXO does not care what the contract believes.

**What this session actually delivered here is the CAPABILITY, not the fix.** `bin/quid-lp-daemon.rs`
boots the same vault from a seed the fleet cannot derive, against a REMOTE hop — and the
`boot_vault` `LOCALHOST` hardcode that made a remote hop undialable is fixed, which was the real
blocker. So the split is now deployable. **It is not deployed.**

▶️ **The fix is one change: the vault's key stops coming from `derive_vault_seed`.** Everything else
in this sprint is around that, not it.

✅ **LANDED 2026-08-17 in `99fda5e9` — AND THE ONE-CHANGE FRAMING ABOVE WAS SLIGHTLY WRONG, IN A WAY
WORTH KEEPING.** The fix is not that the vault's key changes source. It is that **the fleet stops
booting a vault at all**: `derive_vault_seed` is still there and still correct for the deployment it
describes. The whole boot — `boot_vault`, `take_lifecycle_rx`, `Arc::new`, the delivery correlator
and the open orchestrator — now sits behind `QUID_FLEET_COHOSTS_VAULT`, **default OFF**, and
`daemon::run` receives the `None` it has accepted since phase 1a. Nothing in this sprint needed a new
key-derivation scheme; it needed a topology, which is what the code comment said all along.

⚠️ **A SECOND-ORDER EFFECT THAT IS NOT A REGRESSION, AND MUST NOT BE "FIXED" BY RE-ENABLING THE
VAULT.** Vault-less, `onchain_rail_enabled` is false, so **Rail B and `/swap-in/onchain` are both
DISABLED by default now.** That is correct and was built deliberately (the toggle and the
deposit-accepting endpoint disable *together*, so nothing accepts BTC it cannot service, and the
daemon warns loudly if the rail was requested). Those rails genuinely require an LP-side key; until
an LP actually runs `quid-lp-daemon`, the only way to serve them was one custodian holding both
halves. **Disabled is the honest state, not a capability loss.** Re-read `daemon.rs:405-425` before
touching this — the coupling is executable there, not asserted in prose.

📌 What remains is deployment, not code: an LP must run `quid-lp-daemon` with its own seed. The
`QUID_FLEET_COHOSTS_VAULT=true` escape hatch exists for a single-custodian deployment and **logs a
warning stating the multisig is nominal**, so the old posture is still reachable but can no longer be
occupied silently — which was the actual defect. Verified `cargo test -p quid-bridge`: 170 passed.

⚠️ Do NOT confuse this with §E183 item 1 (below). That closed an EVM *attribution* hole — a hop
naming itself as the LP. It protects the pool credit. **This protects the sats.**

---

## B1. ✅ CLOSED — §E222's RING NOW RECORDS AN INDEPENDENT SOURCE (`1e54a2fc`)

✅ **CLOSED 2026-08-17, BY ANOTHER THREAD, AND ALL THREE PARTS THIS ROW ASKED FOR ARE DONE.**
`1e54a2fc` wired the ETH ring to 1inch's OffchainOracle (`DeployLib.sol:170`), deleted the self-write,
and **answered the BTC question rather than deferring it**: the BTC ring is left UNSET on purpose,
because 1inch can only quote wrapped BTC and observing it would make a WBTC depeg indistinguishable
from bitcoin moving — so σ² stays unmeasured and §E213 prices at the ceiling, which is the honest
reading. Verified by enumerating the write path (`OracleLib.writeObservation` ← `_writeObservationPrice`
← `_observeIfSourced`, one chain, external `staticcall` only), not by grepping for a library name.
⚠️ **I re-confirmed this item OPEN earlier the same day on the strength of `ExternalTwap` having zero
references.** That measurement was correct and the inference was wrong: the fix deliberately avoids
`ExternalTwap`, whose `oneInchRateWad` reverts on a bad read and would turn an oracle outage into a
halted swap path. **`ExternalTwap` being unwired is a separate live observation, not this defect.**


`Core.sol:866` reads `px = AUX.getTWAPforAsset(ASSET, 1800)` — which reads the observation ring —
and `:878` writes that same value back via `_writeObservationPrice(px)`. The identical pair repeats
at `:987`/`:988`.

**§E222 predicted this and said main was safe ONLY because it still had the pool. I merged the v4
cut. The pool is gone, so the prediction is now the state.** Nothing reverts: the deviation test
compares a value against a smoothed copy of itself, so **a green suite is exactly what this
produces**. The guards did not break; they became vacuous.

`ExternalTwap` is the written, tested replacement and is wired to **nothing** — its only call sites
anywhere are in `test/OneInchObserverIsIndependent.t.sol`.

> **Note added by session `d669393d` (Part A), 2026-08-17 — two facts that belong on this item.**
> ① **`ExternalTwap` deliberately survived a dead-code sweep today.** The owner's rule is now
> *"anything that is unwired and dead code either needs to be wired all the way or deleted"*, and this
> is the likeliest casualty of a literal reading — zero production callers, one comment mention at
> `Core.sol:1280`. It was kept because the test is *"no caller **and no job**"*, not "no caller".
> **Wire it or it will keep looking deletable to whoever sweeps next.**
> ② **The source needs NOTHING from the withdrawn 1inch work** — those are two different contracts.
> The reversed integration was **AggregationRouterV6 `0x1111…2A65`** (a swap venue); this reads
> **OffchainOracle `0x0AdDd25a…F9B8`** (read-only `getRate`), and the router address appears nowhere
> in `ExternalTwap.sol`. This corrects a note I wrote earlier today claiming the source was orphaned.
> ⛔⛔ **BUT DO NOT WIRE THE RING TO `getRate`. I first wrote that step (1) was "one staticcall to a
> live contract"; another session had already measured it at 31,722,803 GAS against a 30M block
> limit** — it iterates all 14 registered DEX oracles — **and reverted after every ETH swap and
> repack exceeded a whole block** (`82662f19` → `df3c5e13`). Their row was lost off `main`; it is now
> landed as **`§E232-1inch-is-unusable-on-chain`**, and it should be read before step (1) is started.
> ▶️ **Use `ExternalTwap.curvePriceWad`** (Curve `price_oracle()`, ~2–3k gas, a different mechanism
> from Chainlink). ⚠️ **BTC gains nothing from that change of venue** — Curve quotes WBTC, so §E223's
> wrapper objection survives, and step (2)'s "record nothing, delete the BTC deviation guard" option
> stays on the table.

▶️ **Order:** (1) wire the ETH ring to an external observation; (2) DECIDE what the BTC ring
records, given §E223 proved there is **no wrapper-free BTC spot on-chain** and a WBTC cross would
undo §E221 — including the option that it records nothing and the BTC deviation guard is *removed*
rather than left looking live; (3) delete the self-write at `:878`/`:988` **in the same commit**,
because a real source beside a surviving self-write re-creates the circularity at the next refactor.

---

## B2. 🔴 §T2 — TERMS COMMITMENT: **I DESTROYED THE WORKING SOLIDITY HALF.** Design intact, code gone.

🔴 **READ THIS BEFORE BELIEVING THE PARAGRAPH BELOW: THE CODE NO LONGER EXISTS.** I built and
verified the Solidity half in a scratch worktree, **never committed it**, and then removed that
worktree with `git worktree remove --force`. It is not on `main`, not in the shared tree, not on
disk. That is a straight violation of the standing rule to commit every completed unit immediately —
the rule exists for exactly this, and I had a green 7/7 in hand when I broke it.

**What survives is the DESIGN and the CONSTANTS, which is most of the cost.** Redoing it is
mechanical; re-deriving the known-answer values would not be. They are recorded here so the next
attempt starts from a checkable fixture rather than a guess:

- leaf: `<termsCommitment> OP_DROP` prefixed to `<cltv> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG`
  — i.e. `0x20 ‖ terms ‖ 0x75` in front of the existing script (ONE leaf, no `tapBranch`).
- `termsCommitment = sha256(abi.encode(seller, token, minDeliveredUsd))`.
- For the existing `SwapInDeposit.t.sol` fixture (`INTERNAL` = G.x, `REFUND` =
  `0x2F8BDE4D…EFE4`, `CLTV` = 800001) and terms (seller `0xA1`, token `0xB2`, floor `1_500_000`):
  - `TERMS      = 0xa96ad576c2997494f5819848b392d6c312c02ee52ec7a0c3f3d5ae6d613a86fc`
  - `EXPECTED_Q = 0xcd5f8505d5404088c26ea8f237bc8479ff326a8dabd258e6b8672c9c76bf66c6`
- **The control that validates any re-derivation:** the same Python, run with NO terms prefix, must
  reproduce the currently-pinned `0xd0d16740ae143319f7883497b4b76efd9bb829725cf7e885c37dacff3be4e4ca`.
  It did. If a reimplementation cannot reproduce that, the reimplementation is wrong, not the pin.

**What it looked like when it worked (do not treat as present tense):** `ExitLib._cltvRefundLeaf` now prefixes
`<termsCommitment> OP_DROP` to the refund leaf; `swapInDepositKey` / `verifySwapInDeposit` /
`_provenDeposit` thread it; `settleSwapInProven` computes
`sha256(abi.encode(seller, token, minDeliveredUsd))`. `test/btc/SwapInDeposit.t.sol` is **7 passed /
0 failed**, including a NEW property test that a changed floor *or* a changed seller yields a
different deposit address, and a known-answer `EXPECTED_Q` computed in Python — which first
reproduced the OLD pinned `0xd0d16740…` for the no-terms leaf, which is what makes it a known
answer rather than a round-trip.

✅ **THE HALF-APPLIED RUST IS REVERTED.** It had cascaded to `E0061` across
`refund_leaf` → `deposit_spend_info` → `deposit_for` → `sign_claim` (4→5→6→7 arguments) and did not
compile. Discarded rather than left in a shared tree for someone else to inherit — and the shape was
wrong anyway, per the note below.

⚠️ **AND THE OWNER IS RIGHT THAT THE SHAPE IS WRONG.** Threading a raw `[u8; 32]` through five
signatures is *adding* parameter slop to fix a trust problem. The fix should REMOVE parameters:
fold `seller`/`token`/`minDeliveredUsd` into one `Terms` value, so
`settleSwapInProven(seller, token, minDeliveredUsd, proof, rawTx)` becomes
`settleSwapInProven(Terms, DepositProof, rawTx)` — **5 params → 3** — with the commitment derived
inside. Same for Rust: thread one `Terms`, not a bare hash. **Redo the Rust half in that shape
rather than patching arity errors.**

---

## B3. 🔴 §T3 — THE FIX IS INEXPRESSIBLE UNTIL FRESHNESS IS PER-CHANNEL

`deadman_exit.rs` defines the freshness input as *"an OPTIONAL second input spending a
**fleet-controlled UTXO SHARED BY EVERY CHANNEL**"*, and `Prevouts::All` means **spending it renders
every previously emitted exit invalid at once** — *"ONE small on-chain tx per period GLOBALLY rather
than one splice per channel."*

⇒ **T3's hazard is the flip side of that efficiency.** Shared + fleet-controlled is what makes
invalidation cheap AND what lets one transaction revoke every LP's exits.

🔴 **So "make it a 2-of-2 with the LP" cannot be built as written** — there is no single LP; the
counterparty set is every LP at once. **Per-channel freshness (phase 3) is the PRECONDITION**, and
it costs exactly what the shared design bought: one tx per period globally becomes one per channel
per period. **That is a cost decision, and it should be priced before anyone starts**, because the
deletion branch (below) makes the whole mechanism disappear.

✅ **The deletion branch is unblocked and is the cheaper outcome:** if the vault↔hop channel does
not forward, every LP-*claim* change is an on-chain splice, no rung can be stale, and the freshness
UTXO deletes itself along with the whole invalidation problem.

📌 **Two corrections banked here, both mine.** (1) I claimed the enumeration failed because *"every
swap-in moves the LP's balance off-chain"* — wrong: that is channel **capacity**, not **claim**.
`paidOutSinceCheckpoint` has exactly two writers (`:1349`, `:2151`), both on-chain splices, and no
sink for forwarding; if forwarding moved the claim, every honest close would trip `StaleClose`.
(2) There are **two different things called freshness** — the EVM **counter**
(`freshnessSeq`/`commitFreshness`, anti-rollback for the enclave's own monitor store, never read by
any exit path) and this Bitcoin **UTXO**. Conflating them makes T3 look either already-solved or
already-absent. I did both, in one turn.

---

## B4. 🟡 LADDER DEPTH — never started

Phase 2's second half. `§PHASE-ORDER` reads *"§T9/§M1#5 as an LP-SIDE SIGNER REFUSAL, **then ladder
depth**"*. I delivered the signer refusal (it needed no new code — `ValidatingChannelSigner` was
already wired) and reported the phase complete. **Ladder depth was never begun.** It is what bounds
the one thing that cannot be prevented: a hop declining to settle, emit or route.

## B5. 🟡 LAZY `openChannel` — never started, and my ✅ was conditional

Phase 4's second half. I closed §E166 arguing every open is LP-funded so there is nothing to defer.
**§E183 item 1 removes that premise**: with the LP signing nothing at open, the open no longer
carries LP consent *at the moment it happens*, which is exactly when deferring the CLAIM starts to
matter. Under rule 16 that closure should have been ⏸️, not ✅.

## B6. 🟡 REGIME — TWO CLASSIFIERS, ONE UNREACHABLE

`marketRegime(σ, φ)` is live (`market/route.ts:150`,`:152`). **Every function in
`spa/src/lib/regime.ts` has zero call sites** — including the ones I de-ticked earlier in the
session without checking for a caller. Only the `Regime` *type* is imported. **Not a deletion —
a decision**: on-chain TWAP or off-chain σ/φ as the source of truth. Then delete the loser.

## B7. 🟡 RATIFY THE SMART-WALLET NARROWING (§E183 item 1)

`lpEth` is now derived from the channel key, so **an LP is necessarily the EOA of that key and a
smart-wallet LP is no longer expressible**. This is a deliberate consequence, recorded in the commit
and in `Types.OpenAuth`, but it is a capability removal and should be ratified rather than inherited.
It also means the LP's Bitcoin channel key **is** its EVM signing key — one secret authorising both.

## B8. 🟡 THE 7540 FOLD — the slop and the trust hole are ONE change

`openChannel` 5 params, `splice` 5, `recordClose` 6, `deliverSwapOutOnchain` 6. **These are exactly
the signatures that wrap across lines — which is why the ABI gate could not see them** (§B9). The
underlying shape is already 7540: `openChannel` and a grow-`splice` are both **requestDeposit**; a
shrink-`splice` and `recordClose` are **requestRedeem** + claim; `requestSwapOutOnchain` /
`deliverSwapOutOnchain` are already request/fulfil. Only `emitDeadManExit` and
`recordForceClosePenalty` sit outside — escape paths, not vault operations; do not force them in.
**B2's `Terms` fold is the first instance of this, not a separate task.**

## B9. 🟡 STALE MARKER — `§OVERCOMMITTED-MEASURED` still reads 🔴

E230 fixed it and `POOLED_USD` funds again (`Alles` went 71/33 → 89/13, and the canary
`testSwapIn_QuidOrStrictStable` passes). The row needs updating, not work.

---

## B10. LANDED THIS SESSION — do not redo

| what | evidence |
|---|---|
| **§E182 rekey** | hop half rotates, LP half immutable, LP co-signs, `keysHash` re-pinned in the same tx; 4 tests |
| **§E183 item 1** | `lpEth` derived; `auth.lpSig` deleted; `OpenAuth` 4 fields → 2; **614 bytes spare**, no longer the tightest contract |
| **§E231 modLP direction** | `modLP` could not express a removal, so withdrawals GREW `POOLED`; signed now, verified by its own prediction |
| **ABI gate blindness** | the scanner walked `splitlines()`, so **every wrapped signature was invisible** — all nine are money-path entrypoints. 106 → 111 checked |
| **v4 cut completion** | `FullMath` → `SoladyMath.fullMulDiv` (124 sites) — and **11 Vogue calls had been NARROWED to 256-bit `mulDiv`**, silently reverting where `FullMath` absorbed |
| **41 lines of dead v4 commentary** | four had become false, incl. one citing the deleted `SOR.sol` |
| **closures** | §E166 (conditional — see B5), §VAULT-RENOUNCE (my own false gap), §SECOND-FUNDING-HALF, §HOP-PARTITION |

---

## B9b. ITEMS THIS THREAD TOUCHED THAT PART B FIRST OMITTED

Found by scanning the thread's five days rather than recalling it — the §HANDOFF-2026-08-15-BTC-THREAD
row named three unfinished items and I had only carried one forward.

### 🔴 B9b-i. ERC-7947 — the verdict was reached and NEVER WRITTEN DOWN WHERE IT BELONGS
`../ibiza/TODO.md` has **0 mentions of 7947**. The analysis is complete and sits only in a QUEUE row:
adopting it for `lpEth` would **reopen the attribution hole**, because `_lpPayoutScript(lpEth)`
derives the BTC payout FROM `lpEth` and `btcRecipientOf` is one source of truth for both
cooperative-close attribution and the splice path — so whoever compromises the recovery provider
redirects an LP's payouts. It is also a **trusted off-chain attester accepting a `proof`**, the
category ruled out wholesale, and the ERC's own security section concedes a malicious provider takes
full account control. ⇒ **Verdict: do NOT adopt for `lpEth`.**
▶️ **Write it into `ibiza/TODO.md` §3b, not here** — ibiza owns the mobile client and social recovery
belongs there. This is the one item on the list that is CROSS-REPO, which is exactly how it gets lost.
📌 And note what makes it redundant rather than merely risky: **Bitcoin and the EVM share secp256k1
and this repo already pays for on-chain EC.** After §E183 item 1, `lpEth` IS the channel key's
address — an LP can prove control of its own identity by signature, with no third party. A recovery
provider would be buying, at the cost of a trusted attester, a primitive already owned.

### ⚠️ B9b-ii. `quid-bridge-daemon` COMPILE — CLEAN, **but I ran the wrong control and the ✅ was premature**
The handoff recorded *"UNFINISHED 2 — `quid-bridge-daemon` DOES NOT COMPILE (31 × E0463)"* and named
a control that nobody executed. Executed now: `cargo check -p quid-bridge --bins` in the pinned
image → **exit 0, zero `E0463`.** The other session's sprint independently calls it *"a FLAKE. Two
sightings, both self-clearing"* — two threads agree, from different evidence, and that much stands.

🔴 **BUT `cargo check --bins` DOES NOT BUILD TEST TARGETS, AND `main` HAD A `quid-bridge` WHOSE TESTS
DID NOT COMPILE FOR THE WHOLE INTERVAL THIS ROW CALLED IT CLEAN.** §E183 item 1 deleted `lp_eth` and
`lp_sig` from `OpenAuth`; three uses survived in `vault.rs`'s `e166_consent_tests` and were never
compiled by any command I ran. `cargo test -p quid-bridge` found them in one run (`E0560` ×2,
`E0609`). Fixed in `26ea9097`; suite now **170 passed, 0 failed**.
⇒ **CLAUDE.md already carries this trap verbatim — "TEST THE CRATE YOU EDITED", from a green run that
had never compiled the crate.** This is the same failure with `check` standing in for the wrong `-p`.
**A ✅ is only as strong as the command behind it: name the command, and check it builds the code the
claim is about.** The row was not wrong about `E0463`; it was wrong about what "compiles" covers.

### 🔴 B9b-iii. §LN-SWAPIN-REMAINDER / §NO-REJECT — the owner calls this the biggest vulnerability
Absent from Part B entirely, and `BTC-CUSTODY-OPEN.md` §4b gives it its own section. `requireFull`
makes the LN swap-in rail **all-or-nothing** because, as `BTCChannels.sol` says, that rail *"cannot
refund"* — a Lightning payment is atomic and cannot be partially returned. The design agreed in this
thread: **do not reject the remainder — route it.** Band fills what it can, the remainder goes out
through 1inch, cleared as a **Khalani cross-chain intent against Perena**, with instantly-redeemable
QU!D forcing the swap-out through 1inch to take in several stables and pack them into one at the end.
⚠️ **The quote seam for this already exists** (§NO-REJECT records it), so the missing piece is intent
emission on shortfall, not a new pricing path. **Two QUEUE rows carry the detail; neither is scoped
to a task.**

### 🟡 B9b-iv. `BandEquityCollapseEchidna` now guards a term that no longer exists
The harness proved the `dust6` collapse safe (50,000 cases: `collapsed >= withDust`, identity when
`dust6 == 0`, floors saturate, monotonicity). **The collapse has since landed — `dust6`/`_dustOf` are
at 0 references in `Core`.** The harness is self-contained pure math, so it still runs and still
passes; it is now archival rather than protective. **Decide: keep as a regression guard against the
term returning, or delete under rule 1.** Do not leave it unexamined — a passing harness over deleted
code is the shape that makes the next reader think the term is still live.

### 📌 B9b-v. A suite-count discrepancy worth resolving before trusting either number
The other session's sprint records a clean baseline of **4,316 passed / 3 failed**, the three being
`testLeverage_LvrControlVsTreatment` in three suites, and calls it *"the ONLY failing test"*. I
measured `BtcLpMintStress` alone at **13 passed / 8 failed** on unmodified `main`, with mint-accounting
assertions failing (`deliver mints ~EXACTLY the swapper's USD`, etc.) — and confirmed them
pre-existing by control. **Both cannot describe the same tree.** Different commits, or one run
excluded a suite. ⇒ **Establish one baseline, on one commit, before either number is quoted as the
state.**

## B10b. 🔴 THE PROCESS FAILURE THAT COST THE MOST

**A scratch worktree is not storage.** I did verified work in one, removed it with `--force`, and
lost it. The standing rule — *commit every completed unit immediately* — is usually argued from
tool-timeouts; this is the other reason, and it is sharper: **`git worktree remove --force`
silently discards uncommitted work, and a green test run is exactly when you feel least like
stopping to commit.**

⇒ **Commit inside the worktree the moment a gate passes, before running the next thing.** A commit
on a detached HEAD is recoverable via reflog; a removed worktree is not.

## B11. THE PATTERN THIS SESSION KEPT PAYING FOR

**Every wrong conclusion came from reading a comment or a row; every correction came from running
something.** `channel.hop` "authority" — deleted, prose only. `Vault` "never renounced" — the
variable is named `ETH`. The T3 enumeration — read a module header, not the ledger. The gate
"compares tuples as opaque" — it expands them; it never *saw* the constant. `x=1` is off-curve — it
is not.

⇒ **Before acting on any claim in this file, run the check it names.** Each one is cheap, and each
of those five cost a wrong turn that a single command would have prevented.


---

## PART C — session `337ea6d3` (skew + refill). **Written at `7ac75692`.**

### 🔴 THE HEADLINE: **THE REFILL ON MAIN IS POTEMKIN. Its arithmetic is proven; its behaviour is not.**
**MEASURED: all four callable refill primitives have ZERO production call sites.**
| primitive | on main | call sites | proof it has |
|---|---|---|---|
| `refillPlacement` | ✅ | **0** | pure-arithmetic only |
| `refillNeeded` | ✅ | **0** | pure-arithmetic only |
| `proRataShortfall` | ✅ | **0** | pure-arithmetic only |
| `imbalanceFeeUsd6` | ✅ | **0** | pure-arithmetic only |
⇒ **NOT ONE OF THEM HAS EVER PRICED A REAL SWAP AGAINST A SEEDED POOL.** Owner named this exactly:
*"potemkin code that has never confirmed proper swap calculation amounts after seeding the pool."*
✅ **THE SKEW IS NOT IN THIS CATEGORY, AND THE DISTINCTION IS THE WHOLE POINT:** `DEPLETION_RATE_WAD`
lives INSIDE `skewWad`, which `_fillDelta` calls on **every swap** — so it is live, exercised, and
covered by the fixture suite. Skew = wired. Refill = not.

### ▶️ WHERE TO KICK OFF, IN ORDER
1. **RESTORE THE VOLATILE ROUTE — do this first, it blocks the rest.** `SOR` was deleted (`09fedf18`)
   BEFORE Aux's execution was re-pointed, so `NoVolatileRoute()` fires and **leverage debt is never
   taken on**. That is **73 of the 77 failures** in the last clean run (414 passed / 73 failed / 487
   total, archive endpoint, **0 environmental**) — every one a PREMISE like *"rally must lever the
   position (debt > 0): 0 <= 0"*. **One root, not 73 problems.** Destination already exists in-tree:
   `ICurvePool.exchange` (`LevMath:401` etherFi, `:464` TriCrypto USDC→WETH).
2. **Wire `refillPlacement` into repack.** `VogueLib.addLiq` ALREADY ends `targetUSD = deltaTok·price`
   — that IS `tok·px == usd`. The fold replaces an implicit step with the explicit one; it is not new
   behaviour. ✅ **UNBLOCKED: `POOLED_USD` is funded again** (`testSwapIn_QuidOrStrictStable` passes
   after §E230's `basketUsd`/`basketLeg` fix).
3. **Wire `refillNeeded`** into a daemon task over the EXISTING rail (`BTCChannels.creditSwapIn` →
   `Vault.creditSwapIn` → `SwapLib.creditSwapInBody`). `daemon.rs` spawns TEN tasks and **none reads
   band inventory**. Docker builds `quid-ln`; macOS cannot.
4. **Wire `proRataShortfall`** into the redeem path + the owner's **1inch conversion to destination
   token**. ⚠️ 1inch is currently a CONSUMER (`Core:1228` *"we feed 1inch / Khalani"*) and a price
   reader (`ExternalTwap:45`) — **never a liquidity source**. Sourcing is Morpho flash + Curve.
5. **THE ACCEPTANCE TEST THE OWNER SPECIFIED, and nothing above is done until it passes:** seed the
   pool → a swap of known size depletes as expected → the refill rebalances **immediately** → **zero
   skew at the end** → the charge reached LPs as a dynamic fee → priced **independently for BTC and
   ETH** → against **one pool of dollars**.

### 🟠 DELETION CANDIDATE, by my own rule-17 argument
**`imbalanceFeeUsd6` is probably redundant.** The depletion term charges the same event at the same
210 ppm — its docblock says it reuses that figure so the two "price the same thing at the same rate"
— but depletion is charged LIVE inside the swap price while `imbalanceFeeUsd6` was written for
separate refill accounting that may no longer need to exist. Different denominators (idle-created vs
drain-fraction), one economic event. **Decide before wiring it, or two charges bill one thing.**

### ⚠️ HAZARDS TO CARRY
- **`77cd3631`** — another thread's **14 autostashed files**, never safely reapplied. My rebase
  autostashed them; reapplying conflicts because origin moved. **`rebase.autoStash` is unsafe in a
  shared tree.**
- **`BTCChannels` margin was 138 bytes** at last measure — tightest in the tree.
- **`testBtcLp_swapInAccruesTheBtcLegFee`** still red: the BTC fee leg is not funded even though the
  ETH side is.
- **Reading `HEAD` for your own SHA is unsafe here** — another session committed between my `commit`
  and my `log`, and I pushed their commit by mistake. Capture the SHA from the commit itself.

---

# PART C — session `d213d167` (skew / oracle / basket-routing thread)

⚠️ **§E222 is ALREADY PART B's B1.** Do not open a second front on it — what follows is only what
THIS session added to it, and it is mostly a **refutation of the obvious fix**.

## C0. Two rules this session paid for
- **A green test whose gas number exceeds a block is not a pass.** `test_EthUsd_…(gas: 31,722,803)`
  printed hours before I used the source it measured, and I read only the `PASS`. It is a design
  refutation wearing a green tick (§E232).
- **Five of six full-suite runs were VOID** (endpoint noise). Screen **all five** strings — `403`,
  `429`, `database error`, `error sending request`, `could not instantiate forked` — and read the
  **exit code**: `exit=2` is forge refusing its arguments, so zero tests ran and every screen reads
  clean. `--match-path` cannot be passed twice.

## C1. 🔴 §E222 — 1inch IS RULED OUT; CURVE IS THE SOURCE, WITH A DERIVED BOUND
I wired the ring to 1inch's OffchainOracle, **committed it, and reverted it** (`82662f19` →
`df3c5e13`). `getRate` iterates **14 registered DEX oracles**: **31.7M gas, above the 30M block
limit** — every ETH swap and repack would have exceeded a whole block. WRONG, not incomplete.

**Kick off from `ExternalTwap.curvePriceWad`** (already written, ~one storage read):
- **ETH: `price_oracle(1)` on `CURVE_TRICRYPTO_USDC`.** 🔴 **k=1 is WETH, k=0 is WBTC** — the file's
  comment said the opposite and was corrected in `6e442a4c`. Verified on-chain against `coins()`:
  `price_oracle(0)` = **\$64,280.15**, `price_oracle(1)` = **\$1,906.53**. Wiring ETH from the old
  comment gives it BTC's price — a 34× error that reverts nothing.
- **Bound: DERIVED, 37–74 bps.** Measured `ma_time() = 600s` against our 1800s window ⇒ ~300s lag
  difference ⇒ **~18.5 bps at 1σ** (60% annualised vol). **Do NOT inherit
  `TWAP_MAX_DEVIATION_BPS = 500`** — that is **~27σ** here, so the check would be decorative.
  It is the POOL's parameter: restate the bound if `ma_time` changes.
- **BTC gets NOTHING, and the check is DELETED not stubbed.** Curve quotes WBTC, so the wrapper
  objection survives the change of venue. No source ⇒ no writes ⇒ `ringVariance` returns 0 ⇒ §E213's
  sentinel prices at the ceiling. **A wrong guard is worse than a vacuous one: the vacuous reports
  nothing you can act on, the wrong one reports something you WILL.**
- **The read must not halt the band:** raw `staticcall`, any failure skips the write. Degrade to
  unmeasured, never revert — the source sits on the swap path.

## C2. 🟠 `calcFeeL1` — TWO changes or neither (§E209, §E227)
Weight-blind numerator vs weight-aware baseline (a \$1k and a \$1M leg at the same rate score
identically) — **but it saturates at a 0.30pp spread**, so the dimensional fix alone returns the same
number on nearly every real input. Fix the dimension **and** recalibrate `MAX_FEE`/scaling together.
Related and never justified: **`swapFeePpm() = 420` is now OUR policy**, not v4's inherited tier.

## C3. 🟠 vBTC IS the 7540's asset — its 4626 face contradicts that (§E221/E223/E224)
`VBtc.asset()` returns **WBTC** while vBTC **is** the ERC-20 the async vault points at. `Vault` has
**no `asset()`**, and `VBtc`'s three 4626 accessors have **ZERO call sites**. Delete them; give the
band manager `asset() = vBTC`. The BTC anchor is already wrapper-free (Chainlink **"BTC / USD"**),
so the depeg exposure is narrower than §E221 first claimed. **The `WBTC/BTC` feed (`0xfdFD…BB23`,
**1.00039110** = 3.91 bps) is wired NOWHERE** — the basis is unmeasured, and that feed is the direct
instrument if a detector is wanted.

## C4. 🟢 `redeemVBtc` is cheap — but NOT with a script parameter (verified)
`VBtc.sol:18-28` claims swap-out *"proves the protocol can pay an arbitrary P2TR"*. **It does not.**
`requestSwapOutOnchain` takes **no destination argument** — it builds `_lpPayoutScript(msg.sender)`
from `btcRecipientOf`, which `setBtcRecipient` gates on a possession proof and locks for channel LPs.
So a redeem reusing `_lpPayoutScript` **adds no surface**; the `p2trScript` parameter is the entire
cost and is exactly what ibiza rejected as cross-LP theft. **Fix that header — it argues for the
rejected design.**

## C5. 🟢 BOLD: an unrouted basket leg and a fail-open depeg exemption (§E216)
BOLD is a **full basket member** (`stables[13]`), yet `_routableStable(BOLD) == false`, so
`consolidate` **skips and refunds** a real leg instead of routing it — against a pool holding
**~\$7.0M quoting at par** (`0xEFc65163…`, **BOLD idx 0 / USDC idx 1**, verified). Separately it is
the only stable with no depeg feed, and `getDepegSeverityBps` returns **0 = healthy** when unfeeded —
a fail-open. Decide: property of the instrument, or a feed nobody found?

## C6. 🟢 `Alles.t.sol` — two unclaimed clusters (§E230)
33 fail, **identical either side of the v4 cut** — pre-existing, not its residue. Three roots:
**24 × `OverCommitted()`** (owned by the `BackingGateSplit` thread — a silent `basketUsd` drift the
newly-armed gate exposed; **do not double-fix**), **6 × `priming funded POOLED_USD: 0 <= 0`**, and
**6 × arithmetic underflow**. The last two are **unclaimed**.

## C7. What this session LANDED, so nobody redoes it
14 stables (crvUSD + frxUSD on native-4626 rails, **14 is the `uint[15]` layout MAXIMUM**) with 13
Chainlink feeds all verified live; the SOR shed-rank **deleted** (wrong six ways, incl. that it
**sorted by token decimals** pre-§E155) and verified inert by an identical-failure-set A/B;
`ringVariance` one-pass (216 bytes, equivalent over 20,000 randomised rings); the TriCrypto→USDC
scrub; and the `USDC` declaration that **unbroke `main`** after its uses shipped without it.

## C8. Environment facts
- **The binding contract MOVES**: `BTCChannels` 24,438/138 → 23,760/816 while `Vogue` went
  21,925 → 24,018/558. **Never quote a margin from a document.**
- **`///` natspec on a file-level constant is a COMPILE ERROR**, not a lint warning.
- **A shared tree eats uncommitted work** — three sets of edits lost to other threads' `autostash`,
  once *between* a green build and reading its result. **Commit first, verify second.**

## C9. Items PART A/B do NOT cover — added after an audit found them missing

I wrote PART C, then grepped it against every open item this session produced. **Five were absent.**
Recording that because a sprint doc whose completeness is assumed is worth less than none.

### C9a. 🟡 §E207 — the ring is sized 65535, its sole reader asks for 9
`Observation[65535]`, and the only consumer is `ringVariance(..., 9)`. Storage is sparse so the unused
slots cost **nothing at deploy** — do not book this as a size win. The real, mechanical gain is that
**65535 is not a power of two**, so `% 65535` emits a full `MOD` on the swap hot path where a `[32]`
ring emits `AND`. ⚠️ **PART A line 308 records `RING 1024 → 256` — so this may already be partly done;
verify what actually landed before touching it.** Falsifiable: resizing changes **no** observable
value, since `9 ≤ 32`. If any variance-dependent test moves, the ring has a second consumer nobody
found.

### C9b. 🟡 §E219/§E231 — Core + Vogue, the numbers PART A's §6 does not carry
PART A §6 owns the manager merge. What this session measured and it lacks: `Core` **10,073** +
`Vogue` **21,925** = **31,998, over EIP-170 by 7,422** naively — but the EthVenue fold cost **1,984
against 3,836 standalone (~52%)**, because a separate contract carries dispatch + interface overhead
that vanishes. At that ratio ≈ **27,135, over by ~2,559**. ⚠️ **52% is NOT linear** — the saving is
mostly FIXED overhead, so it is optimistic for large contracts; only doing the fold gives an honest
number. ⚠️ **`LevManager` + `BtcLevManager`**: 23,753 + 20,617 = **44,370** naively, ≈ **34,416** at
52%. That sum **double-counts `LevBase`**, which is `abstract` and inlined into BOTH bytecodes.
Overlap: **16 shared function names, 33 ETH-only, 15 BTC-only**. `LevBase` and `LevVenueBase` are
**not** duplicates — manager-base vs venue-base, different layers.

### C9c. 🟡 v4-core dependency removal — backed out once as premature
**11 symbols across 7 files** still need it: `IPoolManager`×3, `PoolKey`×2, `Currency`×2,
`StateLibrary`, `SafeCallback`, `PoolIdLibrary`, `BalanceDelta`. Order: retire the last
**`SafeCallback`** user → relocate **`FullMath`** (pure 512-bit math with nothing v4 about it, and it
pins the whole library on its own) → the pool-shaped types go with the last interfaces. A deletion
attempt mid-session left the tree uncompilable and was correctly reverted.

### C9d. 🟠 §E196 — the cross-sectional rate filter and per-curator weight cap
Raised early in this session and **never executed**. The rate estimator became trustworthy only after
§E155 (dimensionless factor) and §E190 (tranche distortion); a cross-sectional filter over the
per-stable rates, and a cap on any single curator's weight, were both booked and neither was built.

### C9e. §E226 — `swapFeePpm() = 420` (tagged, since C2 mentions it only in passing)
It used to MIRROR `k.fee = 420` on the v4 pool key and be harvested by `_handleCollect`. **With v4
gone the FILL charges it**, so 420 is now a parameter we own and must justify rather than a reflection
of someone else's tier. It never has been. Belongs with §E227's recalibration, not separate from it.


---

## PART C2 — **THE VOLATILE ROUTE IS THE BLOCKER, AND REMOVING V3 LEAVES A HOLE (2026-08-17)**

### 🔴 C2.1 — **OWNER: "there should be no v3 in this code at all." Complying leaves the volatile leg with NO ROUTE.**
**14 live V3 references** (`V3_SWAP_ROUTER`, `IV3Router`, `V3_FEE_*`). `_poolSwap` (`LevMath:490`)
is a V3 `exactInputSingle`, and its `catch` is where **`NoVolatileRoute()`** comes from.
**MEASURED — what remains in `LevMath` once V3 goes:**
| leg | route left |
|---|---|
| weETH → WETH | ✅ `ETHERFI_CURVE_POOL` (`:417`) |
| stable ↔ USDC | ✅ `pool.exchange` (`:547`, `:565`) |
| **USDC ↔ WETH / WBTC** | 🔴 **NONE** |
⇒ **THE VOLATILE HOP HAS ONLY EVER HAD TWO CANDIDATES AND BOTH ARE NOW EXCLUDED:**
**TriCrypto** was deleted with §V-R1/§E232-tri on a MEASUREMENT — **698 WETH / 20.72 WBTC, both legs
breaching the 1% floor between $10k and $25k**; and **V3** is now banned by instruction.
⛔ **THIS IS WHY `e4f9c512` RE-PINNED V3 DAYS AFTER `9eef279a` CUT IT** (*"Curve already superseded
it"*). The reversal was not carelessness — it was the hole reasserting itself. **Deleting V3 without
naming a replacement re-opens it.**
▶️ **DECISION REQUIRED BEFORE ANY CODE MOVES** — the options are the whole space:
(a) a deeper Curve pool for USDC↔WETH/WBTC, sized against the same 1% floor TriCrypto failed;
(b) accept TriCrypto WITH a size cap below its measured breach point;
(c) source the volatile leg off-chain via the fleet (flash → serve → repay), which is already the
refill's own shape;
(d) keep V3 solely for this hop, which the instruction excludes.
📌 **DO NOT "fix" the 73 failures by deleting `_poolSwap`.** They are `PREMISE` assertions —
*"rally must lever the position (debt > 0): 0 <= 0"* — i.e. **the position never opens.** Removing the
route makes them fail earlier, not pass.
⚠️ **AND THE CAUSAL LINK IS NOT PROVEN:** `NoVolatileRoute` appeared **twice** in the last clean run
while ~73 failures were premise assertions. **The discriminator is one two-point run:** a single
leverage test at `9eef279a` (Curve) vs `e4f9c512` (V3). Passing on the former and failing on the
latter names the cause; failing on both clears the route and moves the hunt to the borrow path.

### 📋 C2.2 — DIGEST OF `QUEUE.md` (what a fresh session must know without reading 13k lines)
| area | state |
|---|---|
| **v4 removal** | ✅ COMPLETE — `IPoolManager`/`PoolKey`/`unlockCallback`/`SafeCallback`/`BalanceDelta`/`TickMath`/`sqrtPriceX96` **all 0**; `SOR.sol` deleted |
| **skew** | ✅ COMPLETE and LIVE — σ²=0 free drain, size-blind quote (a 90% drain filled **4.12×** worse), depletion σ²-free keyed on `inv0`, patience **93.3% → 1.37%**. `skewWad` is called by `_fillDelta` on every swap |
| **refill** | 🔴 **POTEMKIN** — 4 primitives on main, **0 call sites**, pure-arithmetic proof only |
| **UNIT rows** | ✅ all 27 red markers audited individually and flipped ⏹; none was open work |
| **`POOLED_USD`** | ✅ funded again (§E230's `basketUsd`/`basketLeg` fix); `testSwapIn_QuidOrStrictStable` passes |
| **BTC fee leg** | 🔴 `testBtcLp_swapInAccruesTheBtcLegFee` still 0 |
| **suite** | 414 / **73 failed** / 487, archive endpoint, **0 environmental** — one root (above), not 73 problems |
| **sizes** | `BTCChannels` **138 bytes** — tightest, near a deploy blocker |
| **split weights** | 🔴 owner's call; rate/who-pays/routing already settled, only proportions open |

### ₿ C2.3 — BITCOIN WORK THIS THREAD TOUCHED AND DID NOT FINISH
- **§E233-ladder (session `1a620c05`, RESTORED by me after I destroyed it with `reset --hard`)** —
  a delivery is the **FIFTH rotation site**; `evm_codec.rs` ABI gains
  `(uint64[],bytes[],uint64,uint256,bytes)[]`, `daemon.rs` threads `vault_registry` to the swap-out
  watcher, `swap_out_onchain.rs` sources the ladder and treats absent consent as **dormancy**.
  ⚠️ **RUN `tools/check-client-abis.py`** — this changes a contract ABI signature.
- 🔴 **`VaultRegistry` — THREE INDEPENDENT DOUBTS, none resolved:**
  ① **no production writer** — `bind_consent` has only TEST callers, so `consent_for_funding` can
  only return `None` and the dormancy branch is the only reachable one *(empty-grep caveat: confirm
  with `git log -S "bind_consent"` before acting)*;
  ② **its justification is false in the deployed model** — `vault.rs:244` says *"the fleet does not
  have the LP funding half"*, but `taproot_signer.rs:439` says *"the fleet holds BOTH funding
  halves"* **under Option B**, and `validating_signer.rs:22` says Option B is what is deployed;
  ③ **§SPRINT-B5** records that §E183 removed the premise (*"the LP signs nothing at open"*).
  ⇒ **If the signer is present at the delivery, the registry is plumbing for an absence that does
  not exist.** Simplification is likely DELETION, not refactor — but it is `1a620c05`'s file.
- **`testBtcLp_swapInAccruesTheBtcLegFee`** — the BTC fee leg is unfunded while the ETH side works.

## C10. Second sweep — items this thread STARTED and never finished, absent from every part above

A grep of this thread's work against the whole file found nine absences. Five were correct (§E197,
§E198 landed; §E202/§E203 are covered by C3 and dormant; the device lifecycle is not SPV's — it is
`../ibiza/TODO.md` §3b). **Four are real gaps, and the first is the thread's ORIGINAL ASK.**

### C10a. 🔴 THE EXCESS-STABLES REBALANCE — never built, and its stated objective was REFUTED
**The task this thread opened with:** route stables **above the total redeemable QU!D claim** out via
1inch to correct basket imbalance, *"which we can measure by seeing how the skew price changes —
double duty reuse of the same measurements."* **`grep` confirms nothing was implemented.**
🔴 **The measurement half is refuted (§E206): `skewWad` takes four band-side inputs — deliverable
volatile inventory, the flow EWMA, ring variance, this swap's size — so swapping USDC→PYUSD moves
NONE of them.** A loop keyed on skew would optimise against a signal that only moves for unrelated
reasons.
🔴 **And the objective half is undefined (§E218): the basket has NO TARGET RATIO**, so "imbalance" has
no referent to correct toward. `calcFeeL1` measures **yield-vs-average**, not concentration.
⇒ **Restate the objective before building anything.** Live candidates: shed the WEAKEST yielders to
protect `avgYield` (`SOR-SIGNIFICANCE-DESIGN.md:14-16`), or size the surplus against redeemable claim
and let EXECUTION pick the leg. Both need §C2's `calcFeeL1` fix first, since the ranking is currently
inverted, saturating and — pre-§E155 — sorted by token decimals.
⚠️ `ROUTING-AGGREGATION.md`'s §V-R1–R11 still specifies router pinning and the four call sites; that
spec is unaffected by the objective being wrong.

### C10b. 🟠 weETH ERC-6909 MINT, **ETH-denominated** — considered, never built
Owner asked for it to be **considered before building** (EIP-8363 context), and corrected the unit
explicitly: *"not usd denominated… **eth denominated**."* Nothing landed — `grep` finds no weETH 6909
path in `src`. **This never got past consideration and has no row anywhere else.** Note it interacts
with §C3: an ETH-denominated 6909 leg is the ETH-side mirror of the question vBTC answers on the BTC
side (what does the vault's `asset()` actually denominate?).

### C10c. 🟠 §E205 — zero the 420ppm tier at deploy (a DEPLOY-TIME decision, still unmade)
Distinct from §C9e's "justify 420": this is whether the tier is **set to zero at deployment**.
§E202 records the tension unmeasured — *"the tier and the skew base now both charge the same flow"* —
so leaving both live may double-charge. **Arguments both ways and neither measured.**

### C10d. 🟢 §E206's dissolved question — recorded so nobody re-opens it
E206 left *"does yield dispersion track over-weighting?"* as the discriminator. **§E218 dissolved it:
with no target ratio, over-weighting is undefined.** Do not re-derive it — the question cannot be
answered because one of its terms does not exist.

