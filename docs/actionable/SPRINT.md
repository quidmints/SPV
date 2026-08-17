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

Measured rates make this costable rather than aspirational.

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

# PART B — session `391df7b6` (the Bitcoin / secp256k1 thread)

**Ordered by what it protects, not by how nearly finished it is.** Item 1 is worth more than
everything below it combined, and I spent the session around it rather than on it — that is the
single most useful thing to inherit from here.

`QUEUE.md` stays canonical. Where a row below names a `§…` id, that row is the record and this is
the summary.

---

## B0. 🔴🔴 THE BIGGEST HOLE IS STILL OPEN — `derive_vault_seed`

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

⚠️ Do NOT confuse this with §E183 item 1 (below). That closed an EVM *attribution* hole — a hop
naming itself as the LP. It protects the pool credit. **This protects the sats.**

---

## B1. 🔴🔴 §E222 — THE ORACLE RING RECORDS ITS OWN OUTPUT, LIVE ON `main`

`Core.sol:866` reads `px = AUX.getTWAPforAsset(ASSET, 1800)` — which reads the observation ring —
and `:878` writes that same value back via `_writeObservationPrice(px)`. The identical pair repeats
at `:987`/`:988`.

**§E222 predicted this and said main was safe ONLY because it still had the pool. I merged the v4
cut. The pool is gone, so the prediction is now the state.** Nothing reverts: the deviation test
compares a value against a smoothed copy of itself, so **a green suite is exactly what this
produces**. The guards did not break; they became vacuous.

`ExternalTwap` is the written, tested replacement and is wired to **nothing** — its only call sites
anywhere are in `test/OneInchObserverIsIndependent.t.sol`.

▶️ **Order:** (1) wire the ETH ring to an external observation; (2) DECIDE what the BTC ring
records, given §E223 proved there is **no wrapper-free BTC spot on-chain** and a WBTC cross would
undo §E221 — including the option that it records nothing and the BTC deviation guard is *removed*
rather than left looking live; (3) delete the self-write at `:878`/`:988` **in the same commit**,
because a real source beside a surviving self-write re-creates the circularity at the next refactor.

---

## B2. 🔴 §T2 — TERMS COMMITMENT: SOLIDITY DONE, **RUST LEFT BROKEN**, AND THE SHAPE IS WRONG

**Solidity half is done and verified.** `ExitLib._cltvRefundLeaf` now prefixes
`<termsCommitment> OP_DROP` to the refund leaf; `swapInDepositKey` / `verifySwapInDeposit` /
`_provenDeposit` thread it; `settleSwapInProven` computes
`sha256(abi.encode(seller, token, minDeliveredUsd))`. `test/btc/SwapInDeposit.t.sol` is **7 passed /
0 failed**, including a NEW property test that a changed floor *or* a changed seller yields a
different deposit address, and a known-answer `EXPECTED_Q` computed in Python — which first
reproduced the OLD pinned `0xd0d16740…` for the no-terms leaf, which is what makes it a known
answer rather than a round-trip.

🔴 **THE RUST HALF IS MID-MIGRATION AND DOES NOT COMPILE.** `quid-hop` fails with cascading
`E0061`: `refund_leaf` → `deposit_spend_info` → `deposit_for` → `sign_claim` went 4→5→6→7
arguments. **That work is IN THE WORKING TREE ONLY — it is not committed and not pushed.** Either
finish it or discard it; do not leave it half-applied.

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

## B11. THE PATTERN THIS SESSION KEPT PAYING FOR

**Every wrong conclusion came from reading a comment or a row; every correction came from running
something.** `channel.hop` "authority" — deleted, prose only. `Vault` "never renounced" — the
variable is named `ETH`. The T3 enumeration — read a module header, not the ledger. The gate
"compares tuples as opaque" — it expands them; it never *saw* the constant. `x=1` is off-curve — it
is not.

⇒ **Before acting on any claim in this file, run the check it names.** Each one is cheap, and each
of those five cost a wrong turn that a single command would have prevented.
