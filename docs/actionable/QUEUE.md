# QUEUE — the single current-state list (2026-07-29)

**This file supersedes `BUILD-QUEUE-AND-107.md`**, which is now an ARCHIVE: 5,106 lines, append-only,
73 `A.x` items, several re-framed two or three times (§A.50 and §A.58 each). Reading it chronologically
is the only way to know what is true there, which is a tax every session was paying. Detail and evidence
still live there and in `GAS-AND-CORRECTNESS-AUDIT.md`; **status lives HERE and is updated IN PLACE.**

# ▶️ START HERE (new thread, 2026-08-02) — read this block, then the RANKED list below

1. **`CLAUDE.md` at the repo root is the rules + environment file.** Standing rules, the decimal bases,
   `via_ir = false`, EIP-170 (`forge build --sizes` is the ONLY enforcer), and the fork-test env vars.
   Read it before touching Solidity. It exists because those facts previously lived only in one
   machine's agent-memory directory.
2. **HOW TO EDIT THIS FILE: update status IN PLACE, in the RANKED + OPEN sections below. Do NOT append.**
   Appending is what turned `BUILD-QUEUE-AND-107.md` into a 5,143-line archive whose own status markers
   became untrustworthy. *(I appended five sections on 2026-08-02 before catching this; the DETAIL now
   lives at the bottom of this file and the top points at it. That is the intended shape: **status at
   the top, derivations at the bottom.**)*
3. **Suite: 3,561 pass · 1 fail · 1 SKIP** (was 3,560/1/60). Both remaining items are known and
   named: the fail is #12 (rank 1, correct — do not weaken it); the skip is `testCrossChain_FullE2E`,
   which needs a Linux toolchain for `quid-hop`. **The 60→1 skip collapse was not a fix to those
   tests** — both ffi tests lived in `Alles.t.sol`, which 25 contracts inherit, so each ran ~30×
   CONCURRENTLY against one regtest bitcoind and raced itself into SKIP. Defined once each now.
4. ⚠️ **THE TABLES AT THE TOP ARE THE ONLY STATUS. The sections below the ranked lists are a
   HISTORICAL JOURNAL** — they record each fix's journey (`APPLIED` → `REVERTED` → `re-derived` →
   `LANDED`), so a single item legitimately reads "applied", "reverted" and "done" in three different
   places. **That is narrative, not contradiction.** Swept 2026-08-02: every mixed-verdict item
   (C1–C5, C10) resolves this way, with ONE real conflict found and annotated in place — a line
   claiming *"C1 and C2 are both in and confirmed"* when C2 was later reverted. If you find another,
   annotate it inline **and** fix the top table; never leave the two disagreeing.
4b. *(superseded by item 3 above)* **Suite** — historical: 3,560/1. The single failure is `testLeverage_LvrControlVsTreatment`, and it is
   **CORRECT — do not weaken it.** It is #12's symptom; the fix is defined at rank 1 below.
   Run: `cd evm && forge test` (now keyless — a bare run forks with no env var set).
6. **OPENING COMMAND for a fresh thread** — paste this:
   > *Read `docs/actionable/QUEUE.md` — start at the START HERE block, then the ranked list. Read
   > `CLAUDE.md` first for the standing rules and environment. Suite is 3,562 pass / 1 fail / 0 skip;
   > the one failure (`testLeverage_LvrControlVsTreatment`) is CORRECT — it is #12's symptom, do not
   > weaken it. Fix #12 per the "#12 IMPLEMENTATION SPEC": credit the LP the DELTA of
   > `POOLED_USD_ETH` since deposit (NOT the level). State the falsifiable prediction before running.*
   To work without money-path exposure instead, swap the last sentence for: *"Start at rank 4b —
   wire the splice fixtures, kill MockSPV, delete the 23 fabricated params, per its WIRING SEQUENCE."*

7. **PARALLEL THREADS — the lanes barely share files, but three constraints bind:**
   | lane | work | files | money path |
   |---|---|---|---|
   | **A** | splice wiring · kill `MockSPV` · 23 fabricated params | `evm/test/*`, `regtest/`, generator | no |
   | **B** | #12 | `Vogue.sol` | yes |
   | **C** | §A.65 → 6909 steps 2–4 | `FeeLib.sol`, `SOR.sol` | yes |
   | **D** | C1r trace · C6–C9 diagnosis · §A.15 | none (read-only) | n/a |
   • **B and C must NOT share a verification run** (rule 10) — develop concurrently, merge
     sequentially with a full suite between, or a failure cannot be attributed.
   • **Lane A is ONE thread, not several** — `Alles.t.sol` is inherited by 25 suites, so two editors
     conflict constantly AND misread each other's test-count changes.
   • **Use `git worktree`, not branches in one checkout** — `forge` writes `out/`/`cache/`, so two
     threads in one tree fight over build artifacts and produce stale-bytecode results. That exact
     class (§A.41) already put one verdict in doubt.

8. **Two things need YOU, not code:** rotate the Ankr token (it is in git history), and pick the #12
   call at rank 1. Both are flagged where they belong below.
9. **The archive is adjudicated.** Every one of its 73 `§A.x` sections and its own 10-item open list have
   been cross-checked into this file (see the three ADJUDICATION passes at the bottom). Treat it as
   evidence-only — with ONE exception now tracked as **C1r** below.

## Scale, honestly
`A.1`–`A.45` predate 2026-07-29. `A.46`–`A.73` were added ON 2026-07-29 — 28 new items, of which 19 came
from one audit. **The queue GREW today.** That is the expected result of looking properly, not a
regression, but it is the opposite of "most of it is finished".

---

# 🎯 NEXT ACTION, RANKED (rewritten IN PLACE 2026-08-02 — the 07-29 ranking below was stale)

**1. #12 — make the call, then build the USD delivery leg.**
   📍 `Vogue.sol:1227` `_pricingBacking` (the missing term) · `VaultLib.sol:121` `_vogueETH` (ETH-only sum) ·
   `Core.sol:1022` the `committedUsd18() <= haircutTvl` gate · `Vogue.sol:962` `unwindForRedeem` (how QU!D
   holders claim the same USD). **Credit the DELTA of `POOLED_USD_ETH` since deposit, NOT the level** —
   level over-pays 246,564 on a 739,324 deposit; delta leaves the LP **+33.56** vs control and flips the
   assertion. Test: `LeveragePnLProbe.t.sol::testLeverage_LvrControlVsTreatment`. The ONLY failing test in the suite
   (`testLeverage_LvrControlVsTreatment`) and the fix is now *defined*, not just diagnosed: credit the
   **DELTA** of `POOLED_USD_ETH` since deposit to LP share price — NOT the level (the level over-pays by
   246,564 on a 739,324 deposit; that base is basket-supplied quoting depth). Measured: crediting the
   delta leaves the LP **+33.56** vs control, flipping the assertion to a pass with the small fee gain
   the test itself predicts. ⚠️ Pricing it is HALF the job — `_withdraw` must also DELIVER the USD; the
   redeemed QUID leg measures **0 in both arms** today, and a claim that prices but cannot be redeemed
   is worse than the status quo. Multi-LP needs per-share apportionment of the increment.
   *(Full derivation at the "#12 RESOLVED BY MEASUREMENT" section near the end of this file.)*

**2. §A.65 — the DIRECTION term on the basket fee.**
   📍 `FeeLib.sol:109` `calcFeeL1` (compute the sign here) · `SOR.sol:356` (the SOR already ranks on this
   exact signal, so pricing off it is consistent by construction) · `FeeLib.sol:167`/`:181` (`calcNeeded`,
   `applyFeeAndHaircut` — today both DISCARD their fee inputs; that is where a charge would land). Recovered 2026-08-02; it had NEVER been in this
   file. It BLOCKS the 6909 work below, and **its failure mode is silent** — a symmetric concentration
   fee charges arbers most exactly when their rebalancing flow is needed most, and nothing reverts, no
   test fails, the basket just stops correcting. Silent + real invariant ⇒ this earns a test, not a
   comment.

**3. 6909 stable→stable fee, steps 2–4.** Step 1 is now CONFIRMED BY STRUCTURE: stable→stable charges
   NOTHING today (`FeeLib.calcNeeded`/`applyFeeAndHaircut` discard their fee inputs as no-ops;
   `scaledFeeL1`'s only caller is a read-only lens). Remaining: re-wire `calcFeeL1` onto the stable leg,
   route to `feesPerShare`/`USD_FEES` (`Vogue.sol:1055`, `Vault.sol:732`) **not** `tranche`, price it off
   the SOR's own signal. Gated on (2), and read §A.51's truncated `baseRate` rationale first.

**4. 🔴 MAKE `_openHopChannel` USE THE REAL SPV — the machinery already exists** (user, 2026-08-02:
   *"why is there anything like this being mocked at all… this might catch hidden issues"* — correct).
   ✅ A genuine end-to-end SPV path IS built and PASSES: `test/btc/OpenChannelE2E.t.sol`
   (`test_openChannel_realRegtestFundingTx`) feeds a REAL regtest funding tx + REAL merkle proof +
   REAL header chain, produced by `regtest/gen-fixture.sh` → `gen_open_channel_fixture.py`, into the
   **real `SPVGateway` + `BTCChannels`**. So this is not a "can't be done" — it is done, for ONE case.
   🔴 **Every other BTC test bypasses it.** `Alles.t.sol:178 _openHopChannel` — used by **25 suites** —
   fabricates the entire open: `fundingBlockHash = bytes32(0x5000 + seed)`, `fundingBlockHeight =
   800000`, a hand-assembled `fundingTx`, and `lpPubkey = 0x02 ‖ keccak256(...)` which is **not
   necessarily a valid curve point**. `MockSPV.checkTxInclusion(...)` then `return true`
   UNCONDITIONALLY (`Alles.t.sol:48`). Nothing is verified.
   ⇒ **A bug in SPV inclusion checking, header-chain/reorg handling, or taproot Q construction on the
     open path is invisible to 25 suites.** It is also why the newly-unskipped LN swap-in test proves
     the *Lightning* half with a genuine HTLC while the *channel-open* half stays synthetic.
   ▶️ **Shape:** generalise `gen_open_channel_fixture.py` to emit a funding fixture PER SEED (fund a
     real P2TR to the derived Q, confirm, emit tx + proof + headers), then have `_openHopChannel`
     drive the real `SPVGateway`. Mechanical — the one-case version already works end to end.
     ⚠️ Cost to weigh: this makes 25 suites depend on a live bitcoind, so it likely wants a
     regenerate-and-commit fixture set rather than live generation at test time.

**4b. 🔴 REAL SPV — opens DONE, splices FIXTURED, wiring REMAINS (2026-08-02).**
   📍 **Fabricated params to delete, exhaustively:** `VBtcLevFeeLane.t.sol:117,118,153,154,187,214,685`
   and `BtcLpMintStress.t.sol:64,307,351,378,509,777`. **Fixture keys:** `.bySeed.s<seed>_<sats>.` for
   opens, `+ "splice."` for splices (`spliceRawTx`, `spliceMerkleBranch`, `spliceBlockHashBE`,
   `spliceHeight`, `spliceTxIndex`, `newAmountSats`, `withdrawSats`, `payoutScript`).
   ⚠️ **Convert a file's OPENS AND SPLICES IN ONE CHANGE** — the splice reuses the open's taproot Q, so
   half-converting turns the suite red (measured: 3 × `BadSPV()`). Regenerate with `regtest/gen-fixture.sh`.
   ✅ **Done and green:** `MockSPV` is GONE from every hop-channel open. `gen_open_channel_fixture.py`
   now funds **19 real key-path P2TR outputs (19.9 BTC)** against one shared header chain, keyed
   `s<seed>_<sats>` (the contract checks the funding output's VALUE, so the amount is part of the key).
   `_realOpen(seed, sats)` in `Alles.t.sol` returns real params + real raw tx + **real merkle branch**,
   and the five `_openHopChannel` sites build `BTCChannels` on a real `SPVGateway`. An unknown pair
   REVERTS telling you to add it to `PAIRS` — it never falls back to a synthetic open.
   📈 **Proof it is really verifying:** the LN swap-in test went **4.95M → 47.65M gas**, and the suite
   went 3,560→**3,561 pass / 1 fail / 30 skip** (skips halved from 60).
   🔴 **THE SPLICE PATH IS STILL UNPROVEN — and this is a NEW finding, not a known gap.** Converting
   `VBtcLevFeeLane` surfaced 3 `BadSPV()` failures; fixing its opens moved one to
   `BadSPV() != ForeignSpliceOutput()`, which localises the remaining failure to **`splice()`**, not
   the open. `_buildShrink` fabricates `fundingBlockHash = 0x5217CE + seed`, height 800001, and an
   empty proof — so **`splice()`'s SPV verification has never been exercised either.**
   ⚠️ `VBtcLevFeeLane` is REVERTED to `MockSPV` for now so the tree stays green — deliberately, and
   recorded here rather than left as a red suite or a masked assertion.
   ✅ **BOTH FEASIBILITY BLOCKERS ARE NOW SOLVED — this is no longer research, it is typing:**
   1. **Are the funding outputs spendable?** YES — measured: `listunspent` shows 60 `tr(` UTXOs with
      `spendable: true, solvable: true`. bitcoind owns the key-path P2TR, so it can sign a splice.
   2. **The zero-fee problem, which is the non-obvious one.** The shapes the tests need are
      *exact*: seed 77 splits 20e6 → 15e6 + 5e6, leaving **no fee**, and a 0-fee tx is rejected by
      mempool POLICY (it is perfectly valid by consensus). ⇒ Do **not** invent a fee and change the
      amounts the tests assert on. Use **`generateblock <addr> [rawtx…]`**, which submits txs
      straight into a block and bypasses mempool policy entirely.
   ⚠️ One gotcha: `createrawtransaction` cannot emit an ARBITRARY `scriptPubKey` (it takes addresses
     or `data`), and the payout leg is a raw script the test chooses. Serialise the splice tx by hand
     — the generator already has `varint`/`build_legacy`/`merkle_branch`, so nothing new is needed —
     then `signrawtransactionwithwallet` → `generateblock`.
   📐 **Only 4 call sites, 3 distinct shapes:** `(77, 20e6) → 15e6 + 5e6`, `(1, 2e7) → 15e6`,
     `(7, 1e6) → 1e6`. Add a `SPLICES` list beside `PAIRS`, emit `spliceRawTx`/`spliceMerkleBranch`/
     `spliceBlockHash`/`spliceHeight`/`spliceTxIndex` per entry, and have `_buildShrink` read them.
   ✅ **GENERATOR HALF DONE 2026-08-02 — 3 REAL splice txs now in the fixture** (`build_splice`).
     Signed by the wallet, included via `generateblock`, each with a merkle branch the generator
     ASSERTS folds to its block's merkleroot. seeds 1/7/77. **Remaining: the Solidity half** —
     point `_buildShrink`/`_spliceOut` at `opens[i].splice.*` and delete `MockSPV`.

## 🔴 BOOKED — THE ZERO-FEE SPLICE QUESTION (a real product question the fixture work exposed)
Writing real splices forced an exact-arithmetic choice, and the choice is load-bearing:
**every splice shape the tests assert sums EXACTLY to the funding** — `20e6 → 15e6 + 5e6`,
`1e6 → 600k + 400k`. Nothing is left over, so **the tests model a splice that pays ZERO miner fee.**

⚠️ **Why that is a trap and not a detail.** A 0-fee tx is valid by CONSENSUS but rejected by mempool
POLICY. The tempting fix — subtract a fee so `sendrawtransaction` accepts it — would silently change
the amounts the tests assert on, making them pass for a different scenario than the one they name.
That is the masking pattern. `generateblock` is the correct escape: it bypasses policy without
touching the numbers. **Do not "fix" a future 0-fee rejection by inventing a fee.**

🔴 **THE REAL QUESTION IT EXPOSES — unanswered, needs verifying against `BTCChannels.splice`:**
on mainnet a splice **must** pay a fee, so `newAmountSats + withdrawSats < fundingSats` ALWAYS.
If `splice()` requires exact conservation of the funding amount, **every real mainnet splice
reverts** and the tests would never have caught it, because they only ever exercise the exact-sum
case. Conversely if it tolerates a shortfall, the tests never exercise the fee-bearing path at all.
✅ **ANSWERED 2026-08-02 — NOT a mainnet bug. Read the arithmetic:**
  • `ChannelLib:565` — `if (outputSats != p.amountSats) revert AmountMismatch()` — checks ONLY that
    the **new funding output's value** equals the declared new amount.
  • **There is NO input-vs-output conservation check anywhere** in the splice path.
  • `BTCChannels:496` — `sumOutputValuesExcept(rawSpliceTx, fundingVout, p2tr) != 0` reverts — so the
    splice may carry ONLY the new funding + the LP payout. **A fee satisfies this**, because a fee is
    implicit (inputs − outputs), not an output.
  ⇒ **Fee-bearing splices are accepted.** The exact-sum shapes were an artefact of how the fixtures
    were written, not a constraint the contract imposes.
  ✅ **And it is now EMPIRICAL, not just a reading:** a 4th fixture shape `(9, 50e6) → 30e6 + 19.9e6`
    leaves **100,000 sat to fee** — a real signed, confirmed tx whose merkle branch the generator
    asserts folds to its block's merkleroot. Wiring it is the test; if it ever fails, every real
    mainnet splice is broken.

   ▶️ **Then:** teach the generator to build REAL splice txs — spend each funding outpoint into the
   2-output shrink shape (new funding spk + payout script), confirm, emit tx + branch. bitcoind owns
   the key-path P2TR so it can sign; the blocker is that `newAmountSats`/`withdrawSats`/`payoutScript`
   are chosen by the TEST, so those must move into `PAIRS` too. Then convert `VBtcLevFeeLane`,
   `BtcLpMintStress`, and the 3 direct opens in `Alles.t.sol`, and delete `MockSPV`.

**4c. 🔴 SCANNER OUTPUT — BOOKED 2026-08-02 (I ran `tools/scan-loose-ends.py`, reported counts, and
   did NOT book them; the user caught it. That is exactly the failure the tool exists to prevent —
   a finding stated in a reply is recorded somewhere and actionable nowhere.)**
| probe | n | verdict |
|---|---|---|
| **FABRICATED CONSENSUS PARAMS** | **23** | 🔴 **REAL — all in 2 files.** `VBtcLevFeeLane.t.sol` (`:117 :118 :153 :154 :187 :214 :685`) and `BtcLpMintStress.t.sol` (`:64 :307 :351 :378 :509 :777`). `bytes32(uint(0x100 + seed))` as a Bitcoin block hash, height `800000`. Rejected by the real gateway; only ever passed against `MockSPV`. **Fixtures now exist for every one of them** (19 opens + 3 splices). |
| **MOCK ON A REAL PATH** | 97 | 🟠 **MIXED — do not treat as one number.** The `new MockSPV()` hits (5 files) are the real target. The rest are `vm.mockCall` on PRICE/depeg views (`getTWAPforAsset`, `getDepegSeverityBps`) — those substitute an ORACLE READING, not a verification path, and several are load-bearing (a fork has no CRE). **Triage by what is being replaced: a proof ⇒ kill it; a reading ⇒ justify it inline.** |
| **SILENT SKIP** | 2 | ✅ **BOTH NOW SAFE** — `BtcSelfManaged.t.sol:97` and `:239`. Each is now reachable ONLY by an absent harness/image; a present-but-broken one emits `BROKEN` and the test asserts. |
| **SWALLOWED FAILURE** | 67 | ⚠️ **UNTRIAGED — the biggest unexamined surface left.** `catch {}` / `\|\| echo SKIP`. Most are deliberate degrade-to-conservative paths, but `_lpValueUsd`'s `try/catch` returning 0 is exactly how a zero-delivery redeem hid in `testDD`, so the pattern has bitten here before. **Each needs: can a REAL failure reach this, and would it be silent?** |
| **OUR markers** | 24 | 🟡 mostly prose/`@notice` references, but `quid-hop/src/migration.rs:58,63,73,77` are **4 `PLACEHOLDER (dev)` constants — operator Safe address and chain id — explicitly "replace before mainnet".** Not tracked anywhere else. |
| vendored markers | 229 | ✅ upstream LDK/lexe (`TODO(phlip9)`/`TODO(max)`). Not ours. |
## 🔴 R1 — ROVER's weETH/WETH LP IS A ONE-WAY RATCHET, NOT IMPERMANENT LOSS (user, 2026-08-03)
**MEASURED LIVE** (pool `0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3`, 0.05%, tick spacing 10):
| | |
|---|---|
| spot | 1 weETH = **1.099342** WETH · fair (`weETH.getRate()`) = **1.100658** ⇒ **12.0 bps** discount |
| **in-range** `liquidity()` | **6.6e17** ⇒ ~**0.0003 weETH** per tick-spacing. **No entry depth at all.** |
| gross balances | **4,840.2 WETH : 1.0358 weETH** (~4,700:1) — mostly PARKED, not quotable |
| QuoterV2 sell-side | 1 / 10 / 100 weETH clear at **−24.1 / −24.1 / −24.6 bps** vs fair (0.5 bps slip over 100×) |

### 🧭 WHY: `getRate()` is MONOTONIC, so the price process has NO return path
weETH accrues staking rewards ⇒ fair weETH/ETH **only rises** ⇒ `P = weETH per WETH` **only falls** ⇒
in v3 a falling `P` converts every position from weETH into WETH. **The 4,700:1 inventory IS the
fossil record of that drift.** Restoring it needs weETH to CHEAPEN vs ETH, i.e. `getRate()` to FALL —
which happens only on a slashing event.
⇒ ⚠️ **THE POSITION NEVER RETURNS TO ITS STARTING COMPOSITION. Not slowly — never.** "Impermanent"
  loss assumes a mean-reverting price; a yield accrual has no return path. **This is permanent LVR.**
⇒ **NO arber incentive to restore in-range balance.** Arbers CAUSED it and profit again on every
  accrual tick. **Waiting is not a remedy — waiting is the mechanism.**

### 💰 THE ONLY COMPENSATION IS FEES ⇒ RECENTER FREQUENCY IS THE WHOLE ECONOMICS
Per cycle: mint weETH at fair → place in range → accrual makes the in-range price stale-cheap → an
arber lifts the weETH → Rover holds WETH again. **Rover concedes the accrual since the last recenter
and books 5 bps.** Profitable **iff** `5bps × volume > accrual conceded between recenters`.
▶️ **MEASURE, do not assume:** (1) weETH accrual APR ⇒ drift/day in bps; (2) Rover's real recenter
  cadence (`repackNFT`); (3) realised fee income per cycle. **If drift/cycle > 5bps × turns, the LP
  leg is structurally negative and should not exist** — the offramp is already served by the −24 bps
  sell-side quote WITHOUT providing liquidity.
📌 Ties to §L.1 (*"Levered-ETH earns in TWO places"*) — same yield-bearing-vs-base asymmetry.


### 📏 EMPIRICALLY MEASURED 2026-08-03 — the drift is REAL but SMALL, and that changes the verdict
`weETH.getRate()` sampled backwards from tip 25,674,317 — **monotonic at every sample**:
| lookback | rate | drift |
|---|---|---|
| now | 1.100658406 | — |
| −1d | 1.100594483 | **0.58 bps/day** |
| −7d | 1.100152632 | **0.66 bps/day** |
| −30d | 1.098451976 | **0.67 bps/day ⇒ ~2.4% APR** |

⇒ ⭐ **BREAK-EVEN RECENTER CADENCE ≈ 5 bps fee ÷ 0.67 bps/day ≈ 8 DAYS.**
  Recenter **faster than weekly ⇒ the fee covers the conceded drift and the position is POSITIVE.**
  Monthly ⇒ concedes ~20 bps against a 5 bps fee ⇒ clearly negative.

### ⛔ TWO OF MY OWN CLAIMS WERE WRONG — corrected here
1. **"May never fill" — FALSE.** If the ask sits above fair and fair rises MONOTONICALLY, the market
   rises INTO the ask. **The drift GUARANTEES the fill; it only sets the DATE.** At 0.67 bps/day a
   premium of 5 / 12 / 24 bps fills in ≈ **7 / 18 / 36 days**. Single-sided asks are a scheduled
   liquidation, not a hope.
2. **"Structurally negative / should not exist" — OVERSTATED.** That assumed the drift dominated the
   fee. Measured, it does not: 0.67 bps/day vs a 5 bps fee. **Rover justifies itself provided it
   recentres faster than ~8 days.** The question is cadence, NOT existence.
📌 Also: **weETH keeps accruing while it sits in the NFT.** The yield is not forfeited by LPing — it is
  forfeited only on the slice already CONVERTED to WETH. So the cost is "time spent holding WETH",
  which is again a cadence variable.


### 🧪 ASSUMPTIONS TESTED (the direction error would have inverted everything)
| assumption | test | verdict |
|---|---|---|
| `getRate()` monotonic ↑ | wrapper accrues staking rewards; falls only on slashing | ✅ holds |
| `P` (weETH/WETH) drifts ↓ | pool `P`=0.9095 vs fair `P`=1/1.100658=**0.9085** ⇒ pool above fair ⇒ weETH cheaper in pool ⇒ matches the measured **12 bps discount**; accrual pushes fair `P` lower and arbers follow | ✅ holds, and is self-consistent with the observed sign |
| falling `P` ⇒ position → WETH | v3: position is all token0 below its range | ✅ holds — and 4,840 : 1.03 is the terminal state |
| this is a LOSS vs holding | sold weETH at ~mid while fair kept rising ⇒ classic LVR | ✅ holds |
| "no arber restores it" | restoring needs `getRate()` to FALL | ✅ holds |

### ⛔ R3 — I ANALYSED A PHANTOM ±7% BAND. The code is a **ONE-TICK** band. (user caught it)
`Rover.sol:207` says *"total range is ~7% below and above tick"*. **That comment is STALE.**
`_adjustTicks` (`:435-446`) is a **TRUE ONE-TICK band**: `lower = floor(tick, TICK_SPACING)`,
`upper = lower + TICK_SPACING` ⇒ with spacing 10, **≈10 bps wide**, and its own docstring says so
(*"TRUE ONE-TICK band … a single tick-spacing captures ~all the fee"*). **Two comments in one file
contradict each other and I quoted the wrong one.** ⇒ 🔧 **Delete the `:207` text — it is false and it
actively misled this analysis.**

### 🔴 R4 — TIGHT BAND × REFUSAL GATE = STRANDED OUT-OF-RANGE (the real defect)
With a ~10 bps band and 0.67 bps/day drift, the price **exits the band every ~15 days** under pure
accrual, so `:205`'s recenter is a ROUTINE event, not a rare one. But:
> **`_nearFair` REFUSES to recenter when spot is >50 bps from fair — and ~$5 puts it there (R2).**
> A shove large enough to knock a 10 bps band out of range is ALSO large enough to trip the 50 bps
> gate. ⇒ **The position goes out-of-range and the recenter that would fix it is refused.**
⇒ ⚠️ **The gate blocks the remedy at exactly the moment the remedy is needed.** Stranded out-of-range
  = fully converted to one token, earning ZERO fees, until someone restores spot. And per R1 **no
  arber has an incentive to restore it** — the restoring trade is the unprofitable direction.
📌 This is a **liveness** bug, not a pricing one, and it is cheap to trigger and self-sustaining.

### 💵 R5 — FEE DATA MEASURED. The two-sided position is NEGATIVE vs holding. (2026-08-03)
`feeGrowthGlobal{0,1}X128` on the pool, 30-day window (blocks 25,458,437 → 25,674,437), applied to
current in-range `L = 6.6e17`:
| | |
|---|---|
| realised fee yield | **0.24 bps/day ≈ 0.9% APR** |
| drift / LVR (one-directional ⇒ **every** move is adverse) | **0.67 bps/day ≈ 2.4% APR** |
| **NET vs simply holding weETH** | **≈ −0.43 bps/day ≈ −1.6% APR** |
⇒ **The fee covers about ONE THIRD of the drift.** Holding weETH yields +2.4%; LPing it two-sided
  yields ≈ +0.8%. **The position is structurally negative in opportunity terms — measured, not argued.**
⚠️ *Caveat:* derived from a 30-day window at TODAY's `L`; if `L` or volume were materially different
  across the window the ratio shifts. **Re-run over two windows before acting.** The sign is not
  marginal (3:1), so it is unlikely to flip — but the magnitude is soft.

### ⚖️ SO: IS THE GATE FIX ENOUGH? **NO — it is NECESSARY BUT NOT SUFFICIENT.**
| fix | fixes stranding/DoS (R2, R4) | fixes economics (R5) |
|---|---|---|
| recenter-off-fair + delete stale comment | ✅ **yes** | ❌ **no** — still quotes two-sided into a one-way drift |
| single-sided, off fair | ✅ yes (prices off `getRate`, never spot) | ✅ **yes** — only fills at a premium you chose |
⇒ **Do BOTH.** The gate fix is a LIVENESS fix; single-sided is the ECONOMICS fix. Neither substitutes.

### ✅ R9 — EXPERIMENT RUN. **Rover's LP leg is a LIABILITY at realistic turnover.** (2026-08-03)
**The thing I had missed for four turns:** for the straddle, the drift loss and the offramp are the
SAME EVENT. Converting weETH→WETH **is** the sale. So A is not "paying LVR *and* providing an
offramp" — **its LVR IS a pre-paid, involuntary offramp.** That reframes the comparison entirely.

**Calibrated with the measured inputs** (fee 0.24 bps/day from `feeGrowthGlobal` over 30d; drift 0.67
bps/day from `getRate` over 30d; band = 1 tick-spacing ≈ 10 bps; swap cost −24 bps flat from QuoterV2):
| | |
|---|---|
| band traversal | full weETH→WETH conversion every **14.9 days** ⇒ **24.5× per YEAR** |
| **A** (straddle) net carry vs holding | **−157 bps/yr** |
| **C** (hold + swap on demand) | −24 bps × turnover `T` |
| ⭐ **BREAK-EVEN** | **A beats C only if `T` > 6.5 full turns/yr** (an offramp every **56 days**) |

⇒ 🔴 **VERDICT: at any realistic venue turnover (1–2×/yr from Vogue LP withdrawals), A LOSES BADLY.**
  The straddle **self-liquidates 24.5×/yr whether or not anyone asked**, then re-mints — paying
  ~157 bps/yr to sell inventory nobody requested. **It is not an on-demand offramp; it is a
  continuous forced seller that happens to be available when you need it.**
⇒ ⚠️ **Rover's LP leg is a LIABILITY unless `T` > 6.5.** `T` is the ONE number that flips this, and it
  is knowable from deployment: Rover-serviced offramp volume ÷ Rover weETH position, annualised.
  **Measure `T` before removing anything** — but 6.5 turns/yr is very high for a yield venue.

**What this experiment IS and IS NOT:** it is a closed-form model **calibrated entirely with real
mainnet measurements** (four independent on-chain reads), not a fitted guess. It is **NOT** a
swap-by-swap fork replay — that would refine the ±, not the sign. **The margin is ~4× (24.5 vs 6.5),
so a replay is unlikely to reverse it.**

### ⛔ R12 — **R9 IS INVALIDATED.** I sampled the one window in which the pool DIED. (2026-08-03)
Tested R11's assumption against history — `liquidity()` and `feeGrowthGlobal0X128` at 30-day steps:
| window | avg in-range `L` | total fees (WETH/30d) |
|---|---|---|
| **last 30d — THE WINDOW R9 USED** | 1.16e24 | **0.6** |
| −30…−60d | 1.71e24 | **193.2** |
| −60…−90d | 1.12e24 | **302.6** |
| −90…−120d | 8.42e23 | **26.7** |

🔴 **In-range `L` collapsed from 2.310e24 → 6.605e17 in the last 30 days — a factor of ~3,497,000.**
  Fees fell ~300× alongside it. **R9's 0.24 bps/day was measured on a pool that was dying, and I
  projected it forward as the steady state.** Every downstream number inherits that error.
⇒ ⚠️ **RETRACT R9's verdict** ("liability below 6.5 turns/yr"). The −157 bps/yr carry, the 6.5×
  break-even and R10 step 4 are all **built on the collapse window** and must not be acted on.
⇒ 📌 **"In-range depth is nil" is TRUE TODAY and NOT the historical norm.** The pool carried ~1e24
  through the prior three months. My framing of a permanently-dead pool was wrong — it is a
  RECENTLY-dead pool, which is a different claim with different implications.

### ⭐ R15 — BREAKTHROUGH: **VOGUE ALREADY SOLVED R4, AND ROVER INHERITED THE PRE-FIX VERSION.**
`SwapLib.sol:119-136` (`_priceOr`, Vogue's price resolution) documents the SAME bug, its blast radius,
and the shipped fix — **verbatim**:
> *"**NEVER reverts** … (The previous version **REVERTED on divergence**, which **bricked QUI
> redemption and froze swaps/deposits on every fast >maxDevBps move** — the internal TWAP can only be
> moved by a swap/repack, which also route through here, so the **read-revert DEADLOCKED the protocol
> until the price mean-reverted**.) **Proven by `test/TwapAnchorDeadlock.t.sol`**"*

⇒ 🎯 **That is R4's stranding, word for word, in a different contract.** Vogue's answer: **WITHIN the
  deviation bound use the DEX price; BEYOND it fall back to the ANCHOR — never refuse.**
⇒ 🔴 **`Rover._nearFair` is the pattern Vogue ABANDONED.** It refuses (no mint/recenter/compound)
  exactly when divergence is largest — and R1 shows **nothing here incentivises the mean-reversion**
  that eventually un-deadlocked Vogue. **Rover's deadlock has no natural exit.**
⇒ ✅ **This makes the R4 fix LOW-RISK, not speculative:** it is a proven, in-repo, production pattern
  with a named test. Mirror `_priceOr`'s shape — `_nearFair` gates EXECUTION-against-spot, while the
  recenter falls back to `getEETHByWeETH` instead of refusing.
▶️ **Write the Rover analogue of `TwapAnchorDeadlock.t.sol`** — shove spot >50 bps, assert the recenter
  still lands off fair. That test is the falsifiable prediction R4 needs (rule 10).

### ✅ APPLIED THIS SESSION (everything else in R1–R15 is BOOKED, NOT BUILT)
| item | state |
|---|---|
| **R3** stale `~7%` comment in `Rover.sol` | ✅ **DELETED** — replaced with the true one-tick description + why it was removed. `forge build` clean. |
| **R4/R15** `_nearFair` degrade-not-refuse | 🔴 **NOT APPLIED** — money-path; needs the deadlock test + a suite run first (rule 10). Precedent + shape are above. |
| everything else (R1,R2,R5–R14) | 🔴 analysis only |

### 🕳️ GAPS & VULNERABILITIES STILL OPEN AFTER ALL OF THIS
1. 🔴 **R2 $5 DoS — LIVE.** Any party can freeze Rover's mint/recenter/compound for ~$5. **Unfixed.**
2. 🔴 **R4 stranding — LIVE**, and unlike Vogue's version it has **no natural exit** (R1).
3. 🔴 **R12: why did `L` collapse 3.5M×?** Unknown. **No Rover decision is safe until answered.**
4. 🟠 **R14#1: the carry numbers are BIASED** — drift counted, mean-reverting deviation ignored.
5. 🟠 **R14#3: JIT never evaluated**, and it may dominate every option considered.
6. 🟠 **R14#5: lending weETH never priced** as the alternative to LPing.
7. 🟠 **Is Rover even deployed?** Unchecked — it decides whether R12's history already includes it.


### 🕳️ R14 — MY BLIND SPOTS ON ROVER (asked 2026-08-03). Written down BEFORE anything is landed.
**1. 🔴 I CONFLATED RATE MONOTONICITY WITH PRICE MONOTONICITY — an analytical error, not a gap.**
   `getRate()` is monotonic. **The market price is NOT.** Today's 12 bps discount IS a deviation from
   fair, and deviations OSCILLATE (weETH trades cheap under stress, recovers after). That component
   **mean-reverts, and an LP is PAID to absorb it.** R1's *"no return path"* is true of FAIR VALUE and
   **false of market price**. ⇒ My LVR figure counted the drift and **ignored the oscillation an LP
   earns on**, which biases every carry number DOWNWARD. **Decompose the price into drift + deviation
   before re-running any economics.**

**2. WRONG-VENUE BLINDNESS.** I analysed the 0.05% pool AS GIVEN. If `L` fled it (R12), it likely went
   somewhere — another fee tier (0.01%/0.3%), Curve, Balancer, a v4 pool. **The fix might be "follow
   the liquidity", not "fix our position in a pool nobody uses."** Check where weETH/WETH volume
   actually lives before optimising here.

**3. JIT — the standard answer to LVR, and this repo ALREADY HAS THE MACHINERY.** Standing liquidity
   is what gets picked off. **Provide depth only in the block it is needed, then withdraw.**
   `docs/actionable/JIT-DEPTH-GUARANTEE.md` + Vogue's JIT-defense exist; Rover reuses none of it.
   ⇒ **This may dominate every option in R8's table** — zero standing exposure, zero DoS surface, and
   the offramp is served exactly when asked. **I never considered it, and it should have been first.**

**4. FEE TIER NEVER QUESTIONED.** 0.05% on a pair drifting 2.4%/yr is a choice, not a given. A 0.01%
   tier attracts more volume; 0.3% compensates LVR better. **The tier is a free lever I never examined.**

**5. THE ALTERNATIVE IS NOT ONLY "HOLD".** The user raised LENDING. weETH as Morpho/Euler collateral
   earns a supply rate ON TOP of the staking rate, with no LVR and no DoS. **R8's option table is
   incomplete without it** — and BtcLevManager already proves the venue plumbing exists (§A.36).

**6. ⚠️ DO NOT GENERALISE R1–R13 TO VOGUE.** All of it rests on a MONOTONIC pair. **Vogue's ETH/USD is
   not monotonic**, so the ratchet, the fill-guarantee and the LVR framing **do not transfer**. Anyone
   reading this section for band intuition will draw the wrong conclusion.

📌 **Pattern across 1, 3 and 5:** each is an option I never put on the table, and each could dominate
  what I did analyse. **My failure mode all session was optimising WITHIN a frame instead of testing
  the frame.** R9 optimised a position that maybe should not exist; R8 compared two designs while
  ignoring JIT and lending entirely.


### 🔍 R13 — WHAT THIS OPENS (the questions that now matter more than the LP economics)
1. 🔴 **WHY did `L` collapse 3.5M× in 30 days?** A single LP withdrawing, a migration to another
   venue/fee-tier, or a response to something. **Until this is known, no Rover decision is safe** —
   if the venue is being abandoned by everyone else, that is a far larger signal than the carry.
2. **Elasticity is now PLAUSIBLE but UNPROVEN.** Fees tracked `L` across the collapse, which is
   consistent with volume following depth (Rover's thesis) — **but causality is unresolved**: liquidity
   may have left BECAUSE volume left. **Correlation only.** The fork replay with an injected position
   is still the only thing that separates them.
3. **Does Rover's own position appear in these numbers?** If Rover is deployed and its `L` is part of
   the historical 1e24, the "with Rover" case is already measured. **Check deployment first — it may
   make the replay unnecessary.**
📌 **Method lesson, and it is the session's recurring one in a new costume:** I measured ONE window
  and called it the steady state. **A single window is a point, not a trend — sample several before
  extrapolating.** The control here was trivially cheap (four extra `--block` reads) and would have
  caught it immediately.


### ⚠️ R11 — R9's LOAD-BEARING ASSUMPTION, WHICH I NEVER STATED: **VOLUME IS FIXED**
> *"did your backtest test the situation now, or what you are hoping for it to be?"* — **Only NOW.**
R9's 0.24 bps/day came from `feeGrowthGlobal` ÷ **today's** `L = 6.6e17`. `feeGrowthGlobal` is fees
**PER UNIT OF LIQUIDITY**, so that yield is **inversely proportional to total `L`**. R9 therefore
measured *a pool with almost no depth and almost no volume* and projected it forward unchanged.
**That is the current state, NOT the state Rover exists to create.**

| if… | effect on A | does R9 hold? |
|---|---|---|
| **volume FIXED** (R9's silent assumption) | adding Rover's depth DILUTES per-unit yield ⇒ A is **worse** than −157 bps | ✅ holds, **a fortiori** |
| **volume ELASTIC** (Rover's own thesis) | depth ⇒ tighter prices ⇒ routers send MORE flow ⇒ total fees rise, possibly super-linearly | ❌ **R9 cannot see this and may be badly wrong** |

⇒ 🔴 **R9 measures the pool WITHOUT Rover. It cannot measure the pool WITH Rover.** A static read of a
  near-empty pool is structurally blind to the counterfactual, and **the counterfactual is the entire
  premise of the contract.**
⇒ **So R10's step 4 ("retire the NFT if `T`<6.5") is NOT SAFE TO ACT ON YET.** It is conditional on an
  untested elasticity assumption.

▶️ **THE TEST THAT WOULD SETTLE IT — and it is the fork replay I never ran:**
 1. Fork at N blocks; **INJECT** a Rover-sized position into the pool at the one-tick band.
 2. **Replay the window's REAL swaps** through the modified pool — with more depth, each historical
    swap executes at a better price and **larger swaps that historically routed ELSEWHERE would now
    route HERE.** Step 2 is the whole experiment; without it you are still measuring the empty pool.
 3. Compare terminal ETH-equiv for A-with-depth vs C.
⚠️ Requires a router-level counterfactual (which trades WOULD have routed here), so it is
  genuinely harder than a naive replay — that is why it must be *run*, not reasoned.
📌 **Honest confidence:** the *mechanism* findings (R2 $5 DoS, R3 stale comment, R4 stranding, R6
  non-enforceability, R8 out-of-range earns nothing) are **measurements and code reads — solid**. The
  *verdict* (R9) is a model resting on one unstated assumption — **treat as a hypothesis, not a result.**


### 🧭 R10 — WHAT ROVER SHOULD BE, given all of R1–R9
1. **KEEP** Rover's `_swap` fair-rate inventory conversion and `valueWeth` — those are sound and
   unrelated to the NFT.
2. **FIX** `_nearFair` to gate execution-against-spot, NOT re-centring (R4 stranding + R2 $5 DoS).
   **Do this regardless of the LP decision** — it is a liveness bug on its own.
3. **DELETE** the stale `:207` "~7%" comment (R3).
4. 🔴 **MEASURE `T`.** If `T < 6.5`/yr — the likely case — **retire the NFT leg** and serve the offramp
   from held weETH via the direct swap. That is strictly cheaper AND removes R2/R4 entirely.
5. Do **NOT** pursue single-sided (R8: out-of-range earns nothing and is a worse offramp).


### ⛔ R8 — SINGLE-SIDED IS DEAD. The user's constraint kills it. (2026-08-03)
> *"why would we do those out-of-range orders if they do not allow us to pull liquidity out during a
> regular vogue swap-out or LP withdrawal — which is why we are using the rover at all (to maximise
> yield for our vogue LPs)"*

**Decisive, and it kills the proposal.** An OUT-OF-RANGE v3 position **earns ZERO fees**. So
single-sided gives: the same weETH yield as simply HOLDING, **no** fee income, and a **WORSE** offramp —
pulling it returns 100% weETH, all of which must then be sold. It adds machinery and subtracts value.
⇒ **If the answer is "out of range", the real answer is "do not LP at all."**

### 📐 THE HONEST OPTION SET — single-sided is not on it
| | fees | drift / LVR | net vs holding | offramp on demand |
|---|---|---|---|---|
| **A. in-range straddle (TODAY)** | +0.9% | −2.4% | **−1.6%** | pull returns a MIX (best) |
| **B. out-of-range single-sided** | **0** | 0 | **0** | worst — 100% weETH still to sell |
| **C. hold weETH + direct swap** | 0 | 0 | **0** | flat **−24 bps**, on demand, no NFT |
⇒ **C strictly dominates B** (same economics, far less machinery) ⇒ **B is eliminated.**
⇒ **C beats A by ≈1.6%/yr** on the R5 measurement.
⇒ 🎯 **THE BACKTEST THAT MATTERS IS A vs C.** Not A vs single-sided. I had been scoping the wrong
  experiment for three turns.

### 🔬 THE EXPERIMENT — scoped, NOT RUN (do not mistake the design for a result)
**Question:** over a real window, does the in-range straddle out-earn `hold + swap-when-needed`, once
the offramp requirement is priced in?
 1. `ForkPin`/`FORK_BLOCK` at N blocks across ≥90 days (the harness already supports this).
 2. **A:** replay the pool's real swaps against the one-tick straddle; track fees AND inventory drift.
 3. **C:** hold the same weETH; each time A would have serviced an offramp, charge C the measured
    −24 bps swap instead.
 4. Compare **terminal ETH-equivalent**, not fee income — A's fees are earned on trades that convert
    its inventory, so fees alone flatter it.
⚠️ **The offramp leg is what decides it, and it is the part R5 ignored.** A's advantage is that a pull
  returns a MIX (less to sell); C pays −24 bps on the whole amount. **If offramp volume is high, A can
  win despite the −1.6%.** That is a real possibility and it is why the replay is required rather than
  optional.
⚠️ **NOT RUN — I did not have the context budget to execute it, and a half-run replay is worse than
  none.** Everything above is a design, not evidence.


### ⛔ R6 — "SINGLE-SIDED" IS NOT ENFORCEABLE IN v3. I OVERSOLD IT. (user, 2026-08-03)
> *"is there really a way to enforce this if the liquidity is on the v3 pool which is where routers
> move swaps through and it in itself will not block two-sided flow?"* — **Correct. There is not.**
A v3 range order is single-sided **only while UNTOUCHED**. Once the drift walks price INTO the range,
the position is an ordinary **two-sided** AMM position inside that band and any router trades both
directions against it. **v3 has no directional flag; you cannot refuse a side.**
⇒ ⚠️ **So single-sided RELOCATES the exposure, it does not remove it.** Correct claim: all fills occur
  at prices CHOSEN in advance (the band starts above fair), and the exposure window is the traversal
  of one narrow band rather than a permanent straddle.
🟢 **What genuinely survives (and is still worth having):**
 • Fills execute at a premium selected in advance, not at a stale mid.
 • **Monotonic drift ⇒ no adverse round-tripping.** Price does not come back, so you are not re-crossed.
 • Oscillation INSIDE the band is benign — a router pushing price back up leaves you in weETH again,
   having collected fees in both directions.
 • Placement prices off `getRate()` ⇒ still immune to the R2 spot-shove DoS.
🔴 **What does NOT survive:** LVR during traversal. It is smaller (one narrow band, starting above
  fair) but **not zero**, and R5's −1.6%/yr was computed for a permanent straddle, so it **cannot be
  read across** to this design.

### 🧪 R7 — WHAT I ACTUALLY DID vs WHAT IS NEEDED (do not mistake one for the other)
**I did NOT backtest.** I read `feeGrowthGlobal{0,1}X128` at two blocks and applied the delta to
TODAY's in-range `L`. That is a point measurement EXTRAPOLATED over 30 days — no fork, no swap replay,
no accounting for how `L` moved across the window. **It establishes the SIGN (fees ≈ ⅓ of drift), not
the magnitude, and it says nothing about the single-sided design at all.**
▶️ **The real test, and it is cheap because the harness already exists:** fork mainnet at N blocks
  across a window (`ForkPin` + `FORK_BLOCK` already do this), replay the pool's actual swaps against
  (a) today's straddle and (b) a one-tick ask above fair, and compare realised fees + inventory. **Only
  that settles whether the relocated exposure is better than the current one.**
⚠️ **Until that runs, treat R5's −1.6% as evidence the CURRENT design is negative — NOT as evidence
  that single-sided is positive.** Those are different claims and I conflated them.


### 📊 SINGLE-SIDED — WHAT WE GAIN AND LOSE (the honest ledger)
**GAIN**
 • **No adverse selection.** An ask above fair fills only at a premium chosen in advance.
 • **No LVR.** You stop quoting a two-sided market against a price process with only one direction.
 • **DoS-immune.** Placement prices off `getEETHByWeETH`; a shoved spot cannot strand or freeze it.
 • **Yield while waiting.** weETH accrues ~2.4% in the NFT; idle is the BEST state, not a cost.
 • **Fill is scheduled, not hoped for.** Monotonic drift reaches the ask: 5/12/24 bps ⇒ ≈7/18/36 days.
**LOSE**
 • **Fee income falls.** ⚠️ But measured that is **+0.9% forgone to avoid −2.4%** ⇒ **losing it is a GAIN.**
 • **No two-way quote from the NFT.** Mitigated: on-demand offramp already runs through the direct
   swap at a flat **−24 bps to 100 weETH**, which never touches the NFT.
 • **Cannot buy weETH cheap on a dislocation.** ⚠️ **Illusory** — Rover NEVER buys from this pool; it
   MINTS at fair (`Rover.sol:22-23`). The bid side serves no Rover function today.
 • **More passive.** Capital waits for the drift to reach the ask. Acceptable for an offramp; NOT
   acceptable if guaranteed instant two-way depth is a requirement — which the direct swap covers.
⇒ 📌 **Every "loss" is either measured-positive or already served by another path.** That is what
  makes single-sided the right call rather than merely a defensible one.


### ⭐ REMEDY — REVISED AGAIN, and it is SMALLER than going single-sided
Directionality was aimed at adverse selection. But with a one-tick band the per-cycle pick-off is
already small (≈half the band ≈5 bps vs a 5 bps fee — marginal, not ruinous). **The dominant problem
is R4's stranding, and it has a much less invasive fix:**
 1. ⭐ **Let the recenter price off FAIR when spot is manipulated, instead of REFUSING.** `_nearFair`
    should gate *execution against spot* (mint/compound/swap), **not** the act of re-centring. Placing
    the band at `getEETHByWeETH` needs no honest spot at all — so the stranding disappears **and** the
    $5 DoS loses its teeth. **This is the elegant fix: it changes a refusal into a fallback.**
 2. Delete the stale `:207` comment (R3).
 3. Only then ask whether directionality is still worth it — with 1 and 2 done, the residual is the
    marginal fee-vs-drift question, which needs REALISED fee data, not more reasoning.
⚠️ **What I considered and rejected:** *wider band* (fewer recenters but larger pick-off per cycle,
  and it does NOT fix stranding); *shorter recenter interval* (does not help — the block is the gate,
  not the cadence); *removing `_nearFair`* (unsafe: it is the only thing stopping execution against a
  shoved spot); *single-sided* (fixes adverse selection but is a re-architecture, and R4 stranding
  would still bite the remaining side).


### 🔴 R2 — `_nearFair` IS A ~$5 DoS VECTOR (user, 2026-08-03: *"liveness shortage when it shouldn't"*)
The gate is a **REFUSAL** (no mint / no recenter / no compound beyond 50 bps from fair) and the pool is
**thin enough that the refusal is trivially cheap to trigger**. With in-range `L = 6.6e17`:
| spot move | weETH needed | ≈ cost |
|---|---|---|
| **50 bps (trips the gate)** | **0.001575 weETH** | **≈ $5.20** |
| 100 bps | 0.003150 weETH | ≈ $10.39 |
⇒ **≈$5 freezes Rover's mint/recenter/compound**, repeatably, and the shover can immediately unwind
  most of it. Valuation stays safe (`valueWeth` holds fair), but **OPERATION halts** — so an offramp
  demanded during that window is a **liveness shortage caused by the safety gate itself**.
⚠️ **Misfire conditions (no attacker required):** any organic trade of a few dollars; a swap routed
  through this pool by an aggregator; or Rover's OWN `take()` execution moving spot past the line.
  **The thinner the pool gets, the cheaper the DoS** — and R1 shows the pool only gets thinner.

### ⭐ REMEDY — REVISED. Single-sided is FIRST, not third. (My earlier ranking was wrong.)
I had ranked "recentre on fair" first. **That was inconsistent with my own R1 finding** — the user
caught it. Recentring on fair fixes the PLACEMENT error but leaves both real problems:
 • **It still reads spot** to decide, so the **$5 DoS survives untouched.**
 • **There is NO organic two-way flow** (R1). The only trades are arbers lifting Rover's stale weETH,
   so **every fee Rover books is a 5 bps rebate on a trade that just harmed it.** Faster recentring
   reduces the bleed per cycle; it never makes the flow benign, because the flow IS the bleed.
⇒ **Single-sided, strictly off fair, is the only option that removes BOTH:**
  1. **Nothing to pick off** — an ask ABOVE fair fills only at a premium you chose. R1's drift
     (0.67 bps/day, monotonic) **guarantees the fill**; 5/12/24 bps premia fill in ≈7/18/36 days.
  2. **Nothing to freeze** — placement is priced off `getRate()`, not spot, so a shoved pool cannot
     halt it. The DoS vector disappears rather than being tightened.
  3. weETH keeps accruing at ~2.4% while it waits, so the idle state is the *best* state, not a cost.
▶️ Recentring-on-fair and a tighter gate are **mitigations to keep if the NFT stays two-sided** — not
  the fix. **For guaranteed on-demand offramp, keep the direct swap** (measured flat −24 bps to
  100 weETH): that path never touches the NFT and is immune to both failure modes.


### ✅ THE DECIDING READ — DONE 2026-08-03. It centres on SPOT, but the straddle is BOUNDED.
`_refreshAndRepack` (`Rover.sol:78-83`) reads `_slot0()` and repacks on `getPrice(sqrtPriceX96)` —
**pool SPOT, not `getRate()` fair.** So yes, it straddles fair, exactly as the failure mode requires.
🟢 **BUT the damage is capped:** `_nearFair()` (`:175`) is a **REFUSAL** — no mint, no recenter, no
compound unless spot sits within **50 bps** of the unmanipulable ether.fi rate; tokens simply idle
(still fair-valued in `valueWeth`) until the pool is honest. **So a recenter can be at most 50 bps
stale at placement, and today spot is only 12 bps off** — well inside the gate.
⇒ **VERDICT: this is a TUNING problem, not a design one.** Worst-case placement error 50 bps + drift
  at 0.67 bps/day, against a 5 bps fee ⇒ **cadence is the whole lever**, and the existing gate already
  prevents the catastrophic case. **Rover justifies its existence.**
▶️ **Cheapest real improvement, in order of effort:**
  1. **Recentre on FAIR instead of spot** — `_refreshAndRepack` already has the rate available via
     `_nearFair`; centring on `getEETHByWeETH` removes the placement error entirely and leaves only
     drift-since-recenter. **One-line-ish, and it is the elegant fix.**
  2. Tighten `_nearFair` from 50 bps toward the observed 12 bps regime (bounds the worst case).
  3. Only if 1+2 are insufficient: the single-sided off-fair placement described below.
⚠️ **NOT IMPLEMENTED — booked only.** `Rover.sol` is UNTOUCHED as of `6c77e5e`. Any thread picking
  this up: it is a money-path change ⇒ own suite run + falsifiable prediction first (rule 10).


### ⭐ THE REMEDY — DON'T STRADDLE FAIR. Let the monotonic drift FILL you, not pick you off.
**The defect is not "LPing". It is placing weETH in a range that CONTAINS fair**, which guarantees the
quote goes stale-cheap and the weETH is lifted. But the drift has a KNOWN, FIXED direction — so orient
the range and it works **for** you:
> **Place weETH strictly BELOW current `P`** — i.e. **ask a HIGHER weETH price than today's fair.**
> The downward drift then walks the market INTO your ask and fills you **at a premium you chose**.
> While you wait, the weETH keeps accruing. **There is no adverse-selection branch:** you either
> fill above fair, or you hold the yield-bearing asset. Both outcomes beat the status quo.

- **Symmetrically:** WETH belongs strictly ABOVE current `P` (a bid to buy weETH BELOW fair). It fills
  only on a dislocation — exactly when buying is right.
- ⇒ **Two single-sided ranges that never touch fair.** No two-sided position, so nothing can be
  picked off stale. This converts the monotonicity from the thing that drains you into the thing that
  executes you.
- ⚠️ **Cost, stated honestly:** you may NEVER fill. For an offramp that is acceptable — unfilled means
  holding weETH at full staking yield, which is the best case anyway. It is NOT acceptable if Rover
  needs *guaranteed* liquidation on demand; that path must stay the direct swap.

### 🥈 ALTERNATIVES WEIGHED (why the above wins)
| option | verdict |
|---|---|
| **recenter faster** | band-aid. Shrinks the window but never closes it, and pays gas per recenter forever. Treats the symptom (staleness) not the cause (straddling fair). |
| **don't LP at all; swap when needed** | ✅ *strictly better than the status quo* — the measured sell-side is a flat **−24 bps to 100 weETH (0.5 bps slip)**, so the offramp already works WITHOUT providing liquidity. This is the FALLBACK if single-sided is judged too passive. |
| **ether.fi redemption instead** | fair rate, no spread — but QUEUED, so it cannot serve an on-demand offramp. Complements, not replaces. |
| **single-sided, off-fair (above)** | ⭐ dominates: fills only at a premium, earns yield while waiting, no adverse selection. |

▶️ **ONE READ DECIDES WHICH IS LIVE TODAY:** does `repackNFT`/`_alignTick` centre the range on **pool
  spot** or on **`getRate()` fair**? **Centred on spot ⇒ it straddles fair ⇒ the leak is structural and
  no cadence fixes it.** That single question separates "tuning problem" from "design problem", and it
  is a short read of the recenter path.

## ✅ A0 DONE — the audit was RE-RUN properly, and it found real stranded items
**Method that worked** (the naive one over-matched line numbers and was unusable): extract IDs only
from **DECLARATION positions** — a `#`-header or a leading `**bold**`/table cell — which is what
separates an ITEM from a MENTION. ⇒ **152 IDs declared in the archive, 59 absent from `QUEUE.md`.**
Most are subsections of one design discussion (`G.0–G.11`, `H.1–H.5`, `I.1–I.3`, `J.1/5/6`, `L.1/2`,
`O.1–O.3`, `P.1–P.3`, `Q1/Q2`, `V.1–V.9`) — prose, not work. **Three are genuine open work, stranded
since the migration:**

| id | archive header | why it is open |
|---|---|---|
| ~~**A.38**~~ | *"§A.5e FIXED — ⚠️ but NOT pinned by a test"* | ✅ **STRUCK — MY FINDING WAS FALSE (2026-08-03).** There IS a dedicated test: **`evm/test/A5eStaleCache.t.sol`**, which warps 3 hours *"past HOLDINGS_MAX_STALE"* (`:36`) and drives the redeem. I grepped `evm/test/` for the IDENTIFIER `_requireFreshHoldings`; the test exercises the BEHAVIOUR. **Same error as A.36, made one entry later** — and I had just written the caveat warning about it. Also mis-described the mechanism: `_requireFreshHoldings` (`Aux.sol:403`) does **not revert**, it lazily calls `_refreshAllHoldings()` when stale. ⛔ ~~CONFIRMED AGAINST CODE~~ |
| ~~**A.36**~~ | *"BTC lev MARKET rail IS built; only ACQUISITION is not"* | ✅ **STRUCK — MY FINDING WAS WRONG, twice** (user, 2026-08-03). (1) Acquisition **IS** built: `leverBorrow` (`:370`) + `leverSupply` (`:386`) are the SPLIT async legs; `:362` describes them as split because BTC spans confirmations, **not as missing**. I grepped `acquire`/`openLev` and concluded from an empty result — the rule I keep quoting says an empty grep proves nothing. (2) More importantly the manager is **venue-agnostic on collateral**: `:338-343` branches on `COLLATERAL() == address(VBTC)`, `:443` gates a **WBTC-ONLY** mode, and `:93` states *"a WBTC venue can sit beside the vBTC one"*. ⇒ **The 2× YB lever runs on WBTC collateral, so IL protection does NOT depend on a Morpho/Euler vBTC market existing.** |
| **A.13b** | *"`RebalIn` cannot be shrunk safely (asked 2026-07-26)"* | 🟠 **STILL LIVE.** `RebalIn` exists at `VogueLib.sol:473`, consumed at `Vogue.sol:1049`. The struct is the `via_ir=false` stack workaround, so "shrink it" trades bytecode against stack depth — the question was never answered. |

🔴 **AND THE REAL LESSON FROM A.36 BEING WRONG:** it came straight out of the archive, and I
  "code-verified" it with a grep for the wrong identifiers. **An archive claim is a HYPOTHESIS, and
  an empty grep is not a verification.** ⇒ For every remaining archive item, find the mechanism and
  read it — do not confirm the archive's wording by searching for the archive's wording.
  ⚠️ **This means the other two are ALSO only as good as my greps.** A.38 rests on `grep -r
  _requireFreshHoldings evm/test/` returning empty; a test could pin that path under a different
  name. **Re-verify by reading the redeem tests, not by re-running my grep.**

## 🛑 SCORECARD OF MY OWN "CODE-VERIFIED" FINDINGS — 2 of 3 were FALSE
| id | my claim | reality |
|---|---|---|
| A.36 | acquisition unbuilt | ❌ **false** — `leverBorrow`/`leverSupply` are the split legs, and the lever is venue-agnostic (WBTC mode ⇒ no vBTC market needed) |
| A.38 | not pinned by a test | ❌ **false** — `A5eStaleCache.t.sol` exists and warps past `HOLDINGS_MAX_STALE` |
| A.13b | `RebalIn` shrink unanswered | 🟠 **holds** — but it is a POSITIVE claim (`VogueLib.sol:473` exists), which is why it survived |

📌 **THE PATTERN, and it is the whole lesson:** both false findings were **ABSENCE claims proven by an
empty grep for a name I chose**. The surviving one is a PRESENCE claim. ⇒ **You cannot verify an
absence by searching for an identifier — a test that exercises a behaviour never names the internal
it covers.** To check "is X tested", find X's OBSERVABLE EFFECT and grep for that, or read the tests
that touch the path. **Treat every remaining archive item as unverified until read this way.**

⚠️ **Also re-check `V.1–V.5`** — those are CATEGORY headers (`Security/money-path`,
`Risk-reduction/correctness`, `Design decisions to make`, `Dedup/simplification`,
`Test-coverage gaps`). Category headers absent from QUEUE means their CONTENTS were never
individually migrated. `V.6` claims a spot-verification of the confirmed-open subset — read it
before trusting any of them.

📌 **The lesson, and it is the session's recurring one:** every completeness claim I made was measured
by a check I had not audited — weak keyword matching, then text-only blocks, then the archive counting
as its own booking file, then the wrong ID granularity. **Four times.** The claim was always sincere
and the instrument was always wrong. ⇒ **Audit the instrument before reporting the measurement.**

### (superseded) the original A0 framing My "fully adjudicated" was measured wrong.
**Retracted 2026-08-03.** I claimed `BUILD-QUEUE-AND-107.md` was fully adjudicated — all 73 `§A.x`
sections cross-checked, its own 10-item list transferred. **That audit was circular**: the scanner's
`booked()` listed the ARCHIVE ITSELF in `BOOKING_FILES`, so any item mentioned there scored as
tracked. Auditing the archive with a check that treats archive-presence as proof-of-tracking cannot
find items stranded in the archive. Removing it moved unbooked **6 → 16**.
🔎 **Proof it is not complete: 13c** (below). The user recalled it from memory; it appears **0× in
  this file, 1× in the archive**, and I had said "booked as 13c". If one survived, others did.
⚠️ **My §A.x sweep also had the WRONG GRANULARITY.** It enumerated `§A.<n>` sections. `13c` is a
  SUB-LETTERED item inside a section — a whole ID shape the sweep never looked for. Same for `J.2c`,
  `A.8d`, `S39`, `D6`, `P.2a`, `U0`.

▶️ **HOW TO DO IT PROPERLY (do not repeat my shortcut):**
 1. `BOOKING_FILES` must be **`QUEUE.md` + `CLAUDE.md` ONLY** — already fixed in
    `tools/scan-loose-ends.py`, keep it that way.
 2. Enumerate **every ID SHAPE**, not just `§A.<n>`: `§A.\d+[a-z]?`, `#\d+[a-z]?`, `[A-Z]\.\d+[a-z]?`
    (`P.2a`, `J.2c`), bare `[A-Z]\d+` (`S39`, `D6`, `U0`, `T1`). ⚠️ A naive numeric regex **over-matches
    line numbers and gas figures** — I tried it and the output was unusable. Anchor on the `§`/`#`
    sigil or a known letter prefix.
 3. For each ID absent from `QUEUE.md`, read its archive line **and check the CODE** — the archive's
    status markers are non-authoritative, so "DONE" there proves nothing either way.
 4. Candidates spotted but NOT verified (my regex was too noisy to trust — **re-derive, don't inherit
    this list**): the `abi.ts` venue-enum D3 staleness, ETH/BTC byte-identical dedup
    (`debtUsd`/`swapOutDeleverAmt` across `LevManager`/`BtcLevManager`), the single `FLOW_DECAY`
    constant serving both ETH and BTC despite very different refill latencies, whether the plain
    ether.fi/weETH venue is per-LP isolated, and a `lev px=0` tick-underflow test class.
📌 **This is a REAL open task, not bookkeeping.** Until it is done, "nothing is hanging" is unproven.

## 🟠 13c — `registerBtcLp` IS THE WRONG VERB (recovered 2026-08-03; I claimed it was "booked as 13c"
##       and it was NOT — `13c` appears **0×** in this file and 1× in the archive)
`registerBtcLp` is called at OPEN **and again by `_applySplice` on every GROW**, while the shrink half
calls `resizeBtcLp`. **Two halves of one operation, two verbs, and the one that runs twice is the
misleading one** — "register" reads as a one-time enrolment when it is the repeated credit path.
📍 `Vault.sol:776` (`registerBtcLp`) · `Vault.sol:855` (`resizeBtcLp`) · `BtcVaultLib.sol:345`/`:202`
  · declared at `BTCChannels.sol:97`/`:102`.
▶️ **`creditBtcLp` or `addBtcLiquidity`** matches what it does. Rename both halves together so the
  pair reads as one operation.
⚠️ **NOT a cosmetic edit — it is an ABI change** consumed by `quid-hop/src/evm_codec.rs`. Needs
  `tools/check-client-abis.py` **and** a suite run, which is why it was never dropped into a
  conversation as a quick fix.

## ⚠️ TWO CONCERNS I HELD AND NEVER WROTE DOWN — surfaced by introspection, 2026-08-03
I claimed the only residual was "a concern never written anywhere, unreachable by scanning." The
user pushed. **It IS reachable — by asking myself rather than grepping.** Both of these were live in
my head and in no file:

**(a) The splice fixture SCHEMA IS UNCONSUMED — nothing has ever compiled against it.**
`build_splice` emits `newAmountSats · withdrawSats · payoutScript · spliceRawTx ·
spliceMerkleBranch · spliceBlockHashBE · spliceHeight · spliceTxIndex · spliceTxidDisplay`, and the
generator's own asserts prove the TXS are valid (txid reconstructs, branch folds to the merkleroot).
**But no Solidity has ever read these keys.** I wrote a `_realSplice` accessor, deleted it as dead
code, and never compiled a caller. ⇒ **Treat the key names and types as UNVERIFIED**: the first
wiring attempt may hit a `parseJson` type mismatch (notably `spliceMerkleBranch` as
`bytes32[]`). Cheap to settle — paste the accessor below into `Alles.t.sol` next to `_realOpen`,
give it ONE caller, and `forge build` **before** converting anything. It lives here rather than in
the tree only because an uncalled helper is dead code; it is otherwise ready.

```solidity
    /// @dev The REAL splice for (seed, sats): a CONFIRMED tx that spends the funding outpoint into
    ///      [new funding Q, payout script], with its real merkle branch. `splice()` SPV-proves the
    ///      tx spends the funding UTXO, so fabricated params are rejected by the real gateway.
    struct RealSplice {
        uint newAmountSats; uint withdrawSats; bytes payoutScript;
        bytes rawTx; bytes32[] branch; bytes32 blockHash; uint64 height; uint txIndex;
    }

    function _realSplice(uint seed, uint sats) internal view returns (RealSplice memory s) {
        string memory j = _spvFixture();
        string memory b = string.concat(_fixtureKey(seed, sats), "splice.");
        s.newAmountSats = vm.parseJsonUint(j, string.concat(b, "newAmountSats"));
        s.withdrawSats  = vm.parseJsonUint(j, string.concat(b, "withdrawSats"));
        s.payoutScript  = vm.parseJsonBytes(j, string.concat(b, "payoutScript"));
        s.rawTx         = vm.parseJsonBytes(j, string.concat(b, "spliceRawTx"));
        s.branch        = vm.parseJsonBytes32Array(j, string.concat(b, "spliceMerkleBranch"));
        s.blockHash     = vm.parseJsonBytes32(j, string.concat(b, "spliceBlockHashBE"));
        s.height        = uint64(vm.parseJsonUint(j, string.concat(b, "spliceHeight")));
        s.txIndex       = vm.parseJsonUint(j, string.concat(b, "spliceTxIndex"));
    }
```
### ▶️ WIRING SEQUENCE — this order avoids debugging two things at once
 1. Paste `_realSplice` above into `Alles.t.sol` next to `_realOpen`.
 2. Give it **ONE** caller and `forge build`. **This step exists solely to validate the nine key
    names/types** (esp. `spliceMerkleBranch` as `bytes32[]`) while nothing else is in flight.
 3. Only then convert `VBtcLevFeeLane` + `BtcLpMintStress` — each file's **opens AND splices in the
    SAME change**; the splice reuses the open's taproot Q, and half-converting turns the suite red
    (measured: 3 × `BadSPV()`).
 4. Delete `MockSPV` and the 23 fabricated params. Re-run `regtest/gen-fixture.sh` if seeds change.

⚠️ It depends on `_spvFixture()` and `_fixtureKey(seed, sats)`, which ARE in the tree
(`Alles.t.sol`, committed and exercised by `_realOpen`). Only this accessor is missing.

**(b) THE FEE-BEARING SPLICE AMOUNTS ARE MINE, NOT A TEST'S — and that is the same sin I spent the
day removing.** Every other `SPLICES` entry was extracted mechanically from a real `_open*` call
site. **Seed 9's `50e6 → 30e6 + 19.9e6` I chose myself** to leave a 100,000-sat fee. It proves a
fee-bearing splice is CONSTRUCTIBLE and accepted by consensus, which was the point — but **no test
asserts those numbers**, so it is a fixture in search of a caller. ⇒ Either write the test that
consumes it, or re-derive the amounts from a real call site when one exists. **Do not let it become
the next fabricated constant.**

## 🔴 M1 — `migration.rs` MUST READ THE SAFE ON-CHAIN, not carry a constant (user, 2026-08-02)
I had booked this as "blocked on the user for the real operator Safe address". **Wrong framing.**
Per the user: *"we don't have a Safe address right now, it gets created as part of the Solidity
deployment and `migration.rs` should just read the on-chain one."*
⇒ The four `PLACEHOLDER (dev)` constants at `quid-hop/src/migration.rs:58,63,73,77` (operator Safe +
chain id) are **the wrong SHAPE**, not merely unfilled. A constant baked at compile time cannot track
an address minted by a later deploy, and "replace before mainnet" is a manual step that WILL be
missed — the failure is silent (it signs against a dead address).
▶️ **Fix:** read the Safe from the deployed `BTCChannels`/registry at runtime, so the daemon has no
  compile-time address at all. Then the constants can be DELETED rather than maintained.
⚠️ Nothing here is blocked on the user. It is engineering work I mis-scoped.

## 🛠️ #12 IMPLEMENTATION SPEC — written 2026-08-02 so the next thread codes it in ONE pass
🔑 **THE REQUIREMENT IN ONE SENTENCE (user, 2026-08-02):** *crediting "the delta since deposit" needs
NEW STORAGE that does not exist today, maintained across every deposit and withdrawal, per-LP for
multi-LP correctness, plus a USD delivery leg in `_withdraw`, plus reconciliation with
`committedUsd18` so the backing gate doesn't double-count the same dollars.*
⇒ Four coupled changes, not one. Any of them missing ships a wrong share price silently.

**Verified blocker: NO baseline exists.** `grep` for `MAX_POOLED_USD`/`pooledUsdAtDeposit`/
`usdBaseline` in `src/` returns nothing. "Credit the delta since deposit" therefore needs NEW STATE,
which is why this is not a one-liner and must not be attempted as a drive-by.

**What the fix must do, in order:**
 1. **Introduce the baseline.** `POOLED_USD_ETH` at the moment the band commits depth for a deposit.
    Per-LP if multi-LP is in scope; a single aggregate is only correct while one LP holds all shares.
 2. **Maintain it** on deposit (baseline += the depth committed for that deposit) and on withdraw
    (baseline -= the pro-rata share). Getting this wrong silently mis-prices EVERY share, so it wants
    an invariant test, not just a happy-path one.
 3. **Credit the delta in `_pricingBacking()`** (`Vogue.sol:1227`): add
    `(POOLED_USD_ETH − baseline)` converted to ETH at the current price. **NOT the level** — the level
    over-pays by 246,564 on a 739,324 deposit, because that base is basket-supplied quoting depth.
 4. **Build the delivery leg in `_withdraw`.** Pricing alone is HALF the job: the redeemed QUID leg
    measures **0 in both arms** today, so a credited claim would price and then fail to deliver —
    strictly worse than the status quo.
 5. **Reconcile with the backing gate.** `Core.sol:1022` gates on `committedUsd18() <= haircutTvl`,
    and today a sale RAISES committed by the proceeds. If the LP now owns that increment, committed
    must stop growing by it or the same dollars are counted twice. **This is the actual "split
    quoted depth from committed dollars" that #12 is named for.**
 6. ⚠️ **Then re-check `Core.sol:48`'s comment** — it documents the `POOLED_USD_ETH + POOLED_USD_BTC
    ≤ TVL` invariant and is CORRECT today; step 5 is exactly what makes it stale.

**Falsifiable prediction to state before the run:** `testLeverage_LvrControlVsTreatment` flips to PASS
with `tFlat − cFlat ≈ +33.56` (the spread the LP earned), and NOTHING else moves. If other tests move,
the baseline maintenance in step 2 is wrong — suspect that before suspecting step 3.

## 🔵 #12 — THE AXIS NOBODY HAS PRICED: who is paid for supplying the QUOTE DEPTH?
Asked to look at it from all sides. Measured facts are settled (the band books +60,000.000000, basket
TVL +60,000.996591, and `vogueETH` never reads it). The *economic* question underneath is not:

**At rest, the band's USD leg is BASKET capital** — 246,564 against a 739,324 ETH deposit. The LP did
not supply it. So a band trade is two parties: the LP supplies the ETH inventory that gets sold, the
basket supplies the USD depth that quotes it.

⚠️ **CORRECTED 2026-08-03 — I framed this as a three-way DESIGN FORK. It is not one.** The user:
*"isn't the basket supplying the depth anyway — why is this even a decision vs what we had before?"*
**Correct on both counts.** The basket supplies the depth in EVERY option, so that was a constant
dressed up as a variable, and nothing changed versus before — the behaviour has always been this.
What changed is that it was finally MEASURED.

**Only one thing actually varies: who owns the dollars that arrive when the band sells the LP's ETH.**
The accounting settles it — the basket **spent nothing** on this trade:
| | change |
|---|---|
| basket | **+60,000.996591 real BOLD**, commitment **+60,000.000000** to match ⇒ free surplus UNCHANGED, simply holds more assets |
| LP | **−32.444522 ETH, +0** |

⇒ The basket was not *compensated for a service*; it gave nothing up. **The LP's ETH became basket
  assets — a transfer, not a fee.** And the LP is ALREADY paid the trading fee separately
  (`feesPerShare` via `_distributeV4Fees`), so today it collects the spread and loses the inventory,
  which is not a coherent position for any market maker.

⇒ ⇒ **So "credit the LP" is the FIX and "status quo" is the BUG.** The only real question is HOW to
  credit without double-counting — the four coupled changes specced above.
  📌 A **depth fee** (paying the basket for quoting capital) is a SEPARATE, LATER question that
  belongs with §A.65's directional pricing. Not a prerequisite; bundling it was my error.

## 🔴 B1 — THE FRESHNESS BACKSTOP HAS NO ECONOMIC BOUND (prose-only loose end, found 2026-08-02)
Stated once in a reply and never booked, because it names no file: *"worth checking the on-chain cost
per idle channel per period against that channel's own fee accrual, so the backstop can't cost more
than the position earns."*
⚠️ **This is the axis the #114 work never priced.** The freshness-UTXO design was costed on
CORRECTNESS (proven at consensus by `regtest/deadman-freshness-e2e.sh`) and on BLAST RADIUS (sharded),
but **never on FREQUENCY × FEE vs the channel's own revenue.** An earlier variant died on exactly this
axis — splice-on-refresh was correct and got killed by one on-chain splice per idle channel per DAY.
⇒ **The measurement:** rotation cost per channel per period vs that channel's fee accrual over the
same period. If cost > accrual for an idle channel, the backstop is a net drain and the rotation
period (or the sharding factor) is the lever. **An idle channel is the worst case and the common one.**
📌 Recorded as the standing lesson too: *price every fix on every axis; the regression is always on
the axis nobody measured.*

### ✅ B1 MEASURED 2026-08-02 — bounded, and **K is the lever**
Rotation = a 1-in/1-out P2TR **key-path** spend, **~111 vbytes**. `REFRESH_MARGIN_BLOCKS =
DEAD_MAN_DELTA_BLOCKS / 2 = 72` ⇒ **2 rotations/day PER SHARD** (`deadman_exit.rs:56,244`) — per
SHARD, not per channel, which is the entire point of the sharding.

| sat/vB | sat/day/**shard** | K=10 | K=100 | K=1000 |
|---|---|---|---|---|
| 5 | 1,108 | 110.8 | **11.1** | 1.1 |
| 20 | 4,430 | 443.0 | **44.3** | 4.4 |
| 50 | 11,075 | 1,107.5 | **110.8** | 11.1 |
| 100 | 22,150 | 2,215.0 | 221.5 | 22.1 |

⇒ **vs the design this REPLACED** (splice-on-refresh: ~154 vB, one **per channel** per day):
  **69× cheaper at every fee rate** — the ratio is constant because both scale linearly in feerate,
  so this is a structural win, not a fee-regime accident.

### 📐 THE RULE: safe operating region is a function of **K × feerate**, not of the mechanism
- At **K=100, 20 sat/vB → 44 sat/day/channel.** A channel earning even ~1,000 sat/day covers itself
  up to roughly **450 sat/vB**. Comfortable.
- It only inverts at **small K AND high fees**: **K=10 @ 100 sat/vB = 2,215 sat/day/channel**, which
  an IDLE channel does not cover. That is the corner to avoid.
- ⇒ **Set K on BLAST-RADIUS grounds, not cost grounds** — cost is already comfortable at K=100.

### ⚖️ THE TRADE THIS EXPOSES — cost and blast radius pull in OPPOSITE directions
Sharding divides cost by K **and multiplies correlated failure by K**: spending ONE freshness
outpoint invalidates **every** exit in that shard at once (that is precisely the property
`regtest/deadman-freshness-e2e.sh` proves at consensus). So:
  • **K↑** ⇒ cheaper per channel, **wider** simultaneous invalidation.
  • **K↓** ⇒ narrower failure, and below ~K=10 at high fees the backstop **costs more than an idle
    channel earns** — the exact axis that killed splice-on-refresh.
⇒ **K is not a tuning knob, it is the risk/cost frontier.**

### 🎯 K SET ON BLAST-RADIUS GROUNDS (2026-08-02) — as a TVL FRACTION, not a count
**Cost does not bind.** At K=100/20 sat/vB it is 44 sat/day/channel; cost permits K≥100 comfortably,
so K is free to be chosen on risk. **Throughput does not bind either:** re-signing has ~72 blocks
(~12h) of slack before the next rotation, which is ample for any plausible fleet.

**What DOES bind is correlated exposure.** Spending a shard's outpoint invalidates every exit signed
against it, so between rotation and re-signing, **all K channels in that shard hold no valid dead-man
exit at once.** A fleet fault inside that window exposes the whole shard together.
⇒ **Therefore: size a shard by the VALUE it can expose, not by a channel count.**

> **RULE: each shard ≤ 5% of total channel BTC ⇒ a minimum of 20 shards, always.**
> `K = ceil(total_channels / max(20, ceil(total_channels / K_cost_max)))`.
> A count-based K silently breaks this as the fleet grows: 100 channels/shard is 5% at 2,000
> channels and **50%** at 200. **The invariant is the fraction; K is derived from it, never fixed.**

### 📌 FEE REGIME THIS ASSUMES — re-derive if it breaks
- **Measured band: 2–50 sat/vB.** At K=100 that is **11–111 sat/day/channel**.
- **Break-even for a channel earning ~1,000 sat/day at K=100: ≈450 sat/vB.** Sustained fees above
  that invert the economics for idle channels and **force K up** — which then collides with the ≤5%
  rule above. **That collision is the real alarm**, not the fee number itself.
- **Do not re-use these numbers under a different `DEAD_MAN_DELTA_BLOCKS`.** Everything here scales
  off `REFRESH_MARGIN_BLOCKS = DELTA/2 = 72` ⇒ 2 rotations/day. Halving DELTA doubles the cost.

✅ **PROSE-ONLY SWEEP (no code token required) — the gap I had left open.** 27 distinct promised
  checks; 21 not covered by a distinctive token. Triaged: **2 resolved in code with reasons** —
  `forceDeallocate` was REMOVED after probing real Galaxy (`VaultLib.sol:23`), and the θ numerator's
  additive-vs-replace ambiguity resolved as REPLACE with its rationale at `VogueLib.sol:335-338`
  (reserve yield accrues whether or not the dollar leg is banded, so it is not the marginal return).
  The rest are meta/conversational. **B1 above is the one real survivor.**

✅ **THE 839 "BOOKED" PASSAGES WERE VERIFIED AGAINST CODE, not taken on the heuristic's word.**
  Reading 839 passages is neither feasible nor reliable, so the CHECKABLE subset was extracted
  instead: every passage carrying BOTH an unimplemented-claim marker (*should be / NOT APPLIED /
  missing / no test*) AND a concrete code token (`file.sol:line` or an identifier). **22 of them.**
  Each was then tested against the current tree:
  • **20 are narrative of work already done** — C5's `*1e12`, C1/C2's unit fixes, #113's
    `DeleverEthBackingProbe`, the `VEth` projection face, the §J.2c transfer gate.
  • `Core.sol:48` *"still claims the sum-cap is enforced"* → **comment is CORRECT as written.** The
    `POOLED_USD_ETH + POOLED_USD_BTC ≤ TVL` invariant IS enforced (measured this session as
    `committedUsd18() <= haircutTvl`). It only becomes stale IF #12 unifies — a coupling, not a bug.
  • `EconAttackProbe` *"proving nothing"* → **28 asserts/expectReverts present**; the log-only state
    was addressed. Consistent with §A.46's "3 assertion-free remain (of 7)".
  • `Vault.sol:638` *"blunt LP-never-receives-loose-vBTC rule"* → **replaced** by SAME-BTC leverage
    (`LP.pooled` UNCHANGED, no double-count).
  ⇒ **Exactly ONE genuinely unimplemented item hid in the booked set: T1**, and it was found by the
    weakest-match control below, not by reading.

🔴 **SCANNER WEAKNESS — IT PRODUCED A FALSE NEGATIVE, and that is the dangerous direction.**
  `booked()` marks a passage as tracked when ≥2 of its first 12 extracted words appear in a booking
  file. Running the CONTROL — sampling passages judged BOOKED and ranking by how weak the match was —
  surfaced **T1 above, a live money-path off-by-one, passed on 2/5 keyword overlap.** Counting only
  the *unbooked* list would have missed it entirely.
  ▶️ **Fix the heuristic** (require a distinctive token — a `file.sol:line`, an identifier, a §ref —
  not just any two words), and **always sample the BOOKED side**, weakest-match first. An unbooked
  list is a to-do; the booked list is where a real finding hides.

## 🧭 STANDING LESSON FROM T1 — how a one-character money-path bug survived every review
It was derived correctly in the archive, marked *"NOT APPLIED"*, and then sat unfixed while three
separate sweeps walked past it. What let it hide, and the rule each failure earns:

 1. **A boundary bug is invisible to tests that never sit on the boundary.** T1 only bites at exactly
    `tick == tickUpper`; no fixture is built to land there, which is why the suite was UNCHANGED by
    the fix. ⇒ **A green suite is not evidence about a boundary. Test the `==` case explicitly, or
    accept that you have no coverage of it.**
 2. **Asymmetry inside one expression is a defect smell.** `currentTick > tickUpper || currentTick <
    tickLower` mixes a CLOSED upper bound with an OPEN lower bound. A half-open range needs `>=`/`<`.
    ⇒ **When two halves of one predicate use different strictness, one of them is wrong** — read the
    interval convention (`[lower, upper)`) and make both agree with it.
 3. **"Already derived" is not "already fixed".** The archive had the analysis AND the words
    "NOT APPLIED", and it still shipped. ⇒ **A derivation with no diff is an open bug**; treat
    `NOT APPLIED` in any doc as a P1 grep, not as a record.
 4. **A COMPARISON WITH A CONSTANT COLUMN IS NOT A COMPARISON.** I offered #12 as a three-way fork
    whose "who supplies USD depth" column read `basket` in every row — a constant dressed as a
    variable, which turned a measured defect into a decision the user did not need to make.
    ⇒ **Before presenting options, check that they actually differ.** Same failure shape as booking
    `migration.rs` as "blocked on an address" when the address is minted at deploy time.
 5. **It surfaced from the scanner's CONFIDENCE, not its text** — ranking BOOKED passages by weakest
    keyword match. ⇒ **Audit the side you believe is safe**, weakest-evidence first. The unbooked list
    is a to-do list; the booked list is where a real bug hides.

📌 **Scanner caveat, learned by running it:** on a multi-compaction JSONL the TRANSCRIPT half reports
  500+ passages that are overwhelmingly resolved history. **I did NOT read all of them** — I read the
  first five per family. Treat that half as a prompt to look, never as a defect list; the CODE half is
  where the signal is.

**5. Two USER DECISIONS recovered 2026-08-02** — neither is engineering work:
   • **delta-1-both-ways product** (`IMPAIRMENT-DERISK-TRIGGER.md`) — only up-lever+hold-down is built,
     and `script/DeployL1_s.sol:566` defers to that doc by name as an OPEN product decision.
   • **venue concentration cap** (`LST-PEG-MONITOR.md`) — *"a config/judgment decision, not a build"*.

**6. C1r + C6–C9** — the only money-path items left. **C1r first**: it is a ONE-LINE trace
   (`SwapLib.sol:498` — is `r.amount` 6-dec or native on the `forVolatile` leg?) guarding a 1e12 refund
   error on 18-dec stables, and it only became REACHABLE when C3 landed. C6–C9 have no commits. **6. 18-dec fixture** — still Echidna
   target #1 (§A.70), but its old #1 ranking rested on C1–C5 being unverifiable, and C1/C3/C4/C5/C10 are
   now resolved. **7. §A.69** anvil E2E + deploy gas — one `forge script` closes both.

⚠️ NOT next: §A.56 part 2 is tidiness; §A.71b near-match dedup is real but sits behind a money path.

# 🧭 TWO LIVE TRACKS — CAVEAT REGISTER (opened 2026-08-03, user: *"keep track of all the caveats for both to make sure the designs we end up choosing do not neglect anything or fix one thing at the expense of something else"*)
**Update IN PLACE. A caveat leaves this register only when it is MEASURED false, never when it is argued false.**

## Track A — THE BOND BLEED (E2): mint prices at par, redeem prices at the mark
| # | caveat | status |
|---|---|---|
| A1 | **Entry at the mark is self-cancelling.** A bonus paid in units the bonus itself dilutes nets to zero — it does not fix the bug, it nullifies the product. | ❌ REJECTED by owner |
| A2 | **Bounding the bonus by realised surplus** shrinks the headline rate ⇒ sacrifices the upfront yield to close the vulnerability. | ❌ REJECTED by owner |
| A3 | **Principal/bonus separation**, per-position OR per-vintage. | ❌ REJECTED by owner |
| A4 | **Queue / pay-last** removes the haircut but reintroduces first-out advantage and a run incentive — collides head-on with `_depegLoss`'s explicit *"no first-out-at-par"*. | ⚠️ live conflict |
| A5 | **Per-vintage marking** closes it exactly but breaks cross-vintage fungibility of mature QU!D, which the code assumes everywhere. | ⚠️ unpriced |
| A6 | **NAV-principal + par-bonus: UNVERIFIED MANIPULATION SURFACE.** Minting at `p` makes mint price depend on `solvent`. `redeemableBody:957` subtracts `_illiquidLoss`, driven by venue `maxWithdraw` — utilisation IS pushable by borrowing hard in-block ⇒ depress `p`, mint `D/p` cheap, let it recover. **Must trace which `solvent` the mint path would use BEFORE building.** | 🔴 BLOCKING |
| A7 | NAV-principal adds a 13-iteration `matureSupply` loop at mint (`_finishMint` computes `total` but not `matureSupply`). Real gas. | 🟡 measure |
| A8 | 🔗 **CROSS-TRACK — THE BIG ONE.** #12 and E5 both REMOVE subsidies silently flowing to QU!D holders today (the LP's sale proceeds; the retained skew premium). Both make `perShare` run **lower** than today. ⇒ **Track B makes Track A's bleed WORSE.** Any E2 fix must be sized against POST-#12 `perShare`, never today's, or it will be calibrated to a number that is about to move. | 🔴 must not be neglected |

## Track B — POOLED_USD CAPITAL EFFICIENCY (#12 · E3 · E5 · E6)
| # | caveat | status |
|---|---|---|
| B1 | **The increment is NOT a stable claim — MEASURED.** `POOLED_USD_ETH` went base+60,000 → **25.20** with NO repack, purely from flow reversing. Delta-since-deposit would credit an LP share price with value that then vanishes. May force booking at the MOMENT OF SALE rather than inferring from a counter. | 🔴 measured, unresolved |
| B2 | **Conservation UNMEASURED.** That run did not capture `POOLED_ETH` after, so whether the value returned as ETH inventory or was lost is unknown. B1 is suggestive, not conclusive, until this is measured. | 🔴 gap in my own test |
| B3 | **The baseline is CROSS-BAND coupled.** `VogueLib.addLiq:430` sizes the re-add via `sizeBySurplus(deposits[14], committedBoth, …)`, `committedBoth = committedUsd18()` = BOTH bands. A per-band baseline is not self-contained. (I argued the opposite on 2026-08-03 and was wrong.) | 🔴 confirmed |
| B4 | **Reseat never fires when it is most needed — MEASURED.** Tick driven to **887271** (MAX_TICK 887272) with the USD leg at $25; six explicit `reseat()` pokes, `reseatEpoch` stayed **0**. E6 is worse than booked: it fails to fix the RANGE, not just the composition. | 🔴 measured |
| B5 | `Core` is already **139 B over EIP-170** (E1). The unification must SHRINK Core, not grow it — and `--sizes` will not tell you either way. | 🔴 hard constraint |
| B6 | `_bandEquityUsd18` floors **per band** so ETH debt never eats BTC equity. Naive unification LOOSENS that solvency gate. Floor against PLACEMENT, not the unified total. | ⚠️ must preserve |
| B7 | **Per-band P&L accumulators (user, 2026-08-03).** Mechanically safe — `Vogue` and `Vault` hold separate storage, `feeIncrements` numerator is per-pool (V4 `isBTC` dispatch) and denominator is per-band. **But economically exposed:** movable placement moves FEE-EARNING CAPACITY between LP populations — BTC LPs' share of the shared pool can end up earning fees credited to ETH LPs, with no accumulator mis-wired. ▶️ **Control to run BEFORE any change:** snapshot both bands' accumulators, drive activity on ONE band, assert the other's are bit-unchanged. | 🔴 open |
| B8 | The USD leg is **basket**-supplied depth, yet its trading fees already flow to that band's LPs via `USD_FEES`. Unification makes *which* LPs receive that transfer contingent on placement. | ⚠️ unpriced |
| B9 | **A flash re-arranges value, it never creates the missing asset.** E3's fix only works while SOME curve has spare dollars; if both are starved, unification changes nothing. | ⚠️ bound on the claim |
| B10 | 🔗 **CROSS-TRACK — see A8.** Landing #12/E5 without Track A's fix moves the bleed onto QU!D holders faster than today. Do not ship B without knowing A's direction. | 🔴 must not be neglected |

# 🔴 OPEN — money path (do these first)

| id | what | state |
|---|---|---|
| **C1** | `Aux.deposit` returns NATIVE; `SwapLib` treated it as 6-dec | ✅ **DONE & CONFIRMED** |
| **C2** | `Core.sol:989` unit mismatch | ✅ **RESOLVED — REVERTED deliberately** (§A.72): the audit's patch was WRONG. Do not re-apply. |
| **C3** | `BasketLib.convert` 1e10 off for `volScale=1e8` | ✅ **DONE** — paired fix; the compensating ×1e10 pre-scale is deleted (`SwapLib:748` records it in past tense) |
| **C4** | WEI premium into a 6-dec register ⇒ Merton band throttle dead | ✅ **DONE** — one site (`2688eca`); `:474` was already correct and an earlier 2-site fix BROKE it |
| **C5** | `Vogue.sol:658` missing `* 1e12` | ✅ **PROVEN NEUTRAL** (`26ac6a8`) — not a defect |
| **C10** | ether.fi rung vs redeemable capacity | ✅ **DONE** — parts 1+2 (`2e34b6e`) |
| ~~F2~~ | BOLD not reaching the Stability Pool | ✅ **CLOSED by C1** |
| **C6–C9** | seedFee clamp basis · ungated TWAP seam · stale read across repack (`Vogue:978-989`) · `scaleTo6` on 4626 share decimals | 🔴 **OPEN — no commit touches any of them.** The only C-items left. |
| **C1r** | 🔴 **C1 RESIDUAL, NEVER VERIFIED.** `SwapLib.sol:498` (`_refundExcess`) does `scaleTokenAmount(excess * 1e12, r.inToken, false)` on the `forVolatile` leg. That `* 1e12` **presumes `excess` is 6-dec** — but C1's whole change was making `Aux.deposit` return **NATIVE**. If `r.amount` now arrives native, this over-scales an 18-dec stable's refund by 1e12. The archive flagged it *"verify, do not assume"* and it was never done; its cited line (`:508`) has since DRIFTED to `:498`. **Trace where `r.amount` is set on the `forVolatile` path before deciding.** Reachable on BTC paths only since C3 landed (previously dead code). | 🔴 open |
| ~~**T1**~~ | ✅ **FIXED 2026-08-02, prediction HELD** (3,562/1/**0 skip**; the +1 pass is the cross-chain test un-skipping, NOT T1 — T1 itself moved nothing, exactly as predicted). ⛔ **OFF-BY-ONE AT THE RANGE BOUNDARY — `SwapLib.sol:1613`.** `if (currentTick > tickUpper \|\| currentTick < tickLower)`. **Uniswap ranges are HALF-OPEN `[tickLower, tickUpper)`** — a position is in-range iff `tickLower <= tick < tickUpper` — so out-of-range is `>=`, not `>`. At exactly `tick == tickUpper` this code believes the band is IN range when the AMM says it is OUT. One character, on the money path. The archive already derived this (`BUILD-QUEUE:3930`) and marked it *"⚠️ NOT APPLIED"* — **and it is still not applied.** ⚠️ Money-path: needs its OWN run + a falsifiable prediction (rule 10). | 🔴 open |
| **T2** | 🟡 **`PREMIUM_ANNUALIZE = 127`** (`VogueLib.sol:322`). Its own docstring says *"the ONE number here worth reviewing"*, and a session note recorded it as 126 — so it HAS moved and the review never happened. Not a bug; an unreviewed constant on the premium path. | 🟡 open |
| **F1** | control-LP redeem delivers 0 | 🔴 open. Likely a FIXTURE warp — **verify before fixing** |
| **#12** | LP share price reads only the ETH leg of a two-legged claim | 🔴 **OPEN — the suite's only failure.** Fix defined; see rank 1. |
| **E1** | 🔴 **`Core` IS 139 BYTES OVER EIP-170 — AND `forge build --sizes` DOES NOT REPORT IT.** Measured from the linked artifact at HEAD (`forge build` reported *"No files changed"*, so the artifact IS HEAD): `out/Core.sol/Core.json` `deployedBytecode.object` = **24,715 B** vs the 24,576 limit. Placeholder-safe: each `__$…$__` link ref is exactly 40 hex chars == the 20 bytes it becomes, so `len/2` is exact. **The blind spot is the real finding:** `forge build --sizes` prints 140 contracts and silently OMITS `Core`, `Vogue` and `Vault` — the three biggest first-party contracts. Library linking is NOT the discriminator (`Aux` 5 libs, `Vault` 3 libs, `LevManager` 1 lib all link, and `Aux`/`LevManager` DO print). ⇒ **CLAUDE.md's *"`forge build --sizes` is the ONLY enforcer"* is false for exactly the contracts that need enforcing**, which is how 139 bytes of overflow got past every size check. **Headroom at HEAD, from artifacts:** `Core` −139 · `Vogue` 649 · `Vault` 3,506 · `LevManager` 70 · `SwapLib` 148 · `VogueLib` 3,897. ▶️ **Two steps, in order:** (1) CONTROL FIRST — `new Core(...)` on anvil (which enforces EIP-170 unless `--disable-code-size-limit`) to convert an artifact reading into an observed deploy failure; a passing `forge test` proves nothing here, since it does not enforce the limit. (2) then shrink `Core` (the `isBTC`-dispatched `_add/_subPooled*` mutators and `_settleUsdSide`/`_settleTokSide` are the obvious lift-to-library candidates) and replace the size check with one that reads artifacts directly instead of trusting `--sizes`. ⚠️ **Consequence for #12:** the fix must add **NO** code to `Core` — the `POOLED_USD_ETH` baseline has to be maintained from `Vogue`/`VogueLib`. | 🔴 open |
| **E2** | 🔴 **MINT PRICES AT PAR, REDEEM PRICES AT THE MARK — a short-tenor depositor subsidises long-dated holders (user, 2026-08-03).** Entry: `BasketLib.calcMintYield:510` mints `deposited × (1 + avgYield × tenor/12)`; the shortest tenor (`month == nextMonth`) gets 1 month of yield, i.e. ≈1:1. Exit: `BasketLib:829` `perShare = min(par, solvent/matureSupply)`. `Basket.sol:~258` states the asymmetry as intent — *"Mint over-mints at 1:1 by design; the over-mint is absorbed at REDEEM … the two sides do NOT value backing identically, and should not."* ⇒ **Someone who books a near-immediate maturity hands over dollars at par and redeems at a share price below par**, eating a haircut created by OTHER cohorts' forward-yield bonuses vesting into `matureSupply`. They are diversifying, not term-lending, and they pay for term they never took. ⚠️ **The `mature`/`immature` split does NOT cover this** — it protects mature holders from *unvested* bonus, but once a bonus vintage matures it dilutes `perShare` for everyone equally, including a depositor who arrived after it was minted. **Precondition for the bite:** `avgYield` is a PROJECTION and the mint is irrevocable, so any period where realised yield < projected leaves `matureSupply > solvent`. ▶️ **Three fixes, and NONE is new tranching:** (1) **entry at the mark** — mint `deposited/perShare`, not `deposited`; algebraically neutral (`perShare` is a fixed point under it) and kills the cross-subsidy exactly; (2) **defer, don't dilute** — cap what a maturing vintage contributes to `matureSupply` at solvent backing and roll the remainder to the next month, REUSING the deferral primitive that already exists on the protocol-mint path (`Basket.sol:222-226`), which converts a price haircut into a time deferral and makes the "mature redeems at PAR" docstring true by construction; (3) **vest the bonus against REALISED yield** instead of projecting it — removes the risk at source but forfeits rate-certainty-at-booking, which is the product. ⚠️ **THE FIX IS NOT SETTLED — the repo owner (2026-08-03) does not think any of these is the best fix, and did not say which axis they fail on. The three above are MY menu, not a decision; treat them as one thread's opinion and re-derive before building.** (My reasoning was: (1)+(2) compose, (3) is a product change. Recorded so the next thread can attack it, not inherit it.) ⚠️ Under (2), NEVER defer principal — only the bonus slice; a depositor must always be able to get their own dollars back, and `tranche[]`/`seeded` already tracks bonus separately. ⚠️ Second-order to price: minting at par into an impaired pool is currently a donation from new depositors that HEALS the impairment; fix (1) removes that healing, so the buffer must recover from yield alone (slower). Measure before shipping. | 🔴 open |
| **E3** | 🔴 **THE vBTC IMBALANCE IS A *DOLLAR* SCARCITY, AND THE TWO-COUNTER SPLIT IS WHAT MAKES IT UNFIXABLE (user, 2026-08-03: *"we have a mechanism that will always fix an ETH imbalance in the band with flash and it works always, the same cannot be said for vBTC"*).** ETH side, BUILT: `SwapLib.deleverEthOnDelivery:1243`, wired at `Vogue._sendETH:1012` — when the WETH venue base is exhausted but `POOLED_ETH` priced the swap against the levered slice, flash-de-lever each LP's OWN debt into real deliverable WETH. Value-neutral per LP. BTC side, **NOT BUILT**: `SwapLib:768-770` names it — *"the still-unbuilt ACTIVE flash-serve (#100 / J.3) — flash the scarce asset, serve the opposite flow, repay, premium stays with LPs."* `BtcLevManager._flashDeleverWbtc:494` exists but serves LIQUIDATION, not swap-flow imbalance. **Why the ETH mechanism cannot simply be ported:** the ETH LP's collateral sits in same-chain 4626/Morpho venues and is flash-reachable inside one EVM tx; the vBTC LP's sats sit in **Lightning channels on Bitcoin** and are not reachable at all from an EVM tx. So no flash can conjure sats. ✅ **BUT THE THING THAT ACTUALLY DENIES SERVICE IS NOT SATS — IT IS DOLLARS**, and dollars ARE same-chain: `_swapInSettle` caps a seller's conversion at the `POOLED_USD_BTC` USD inventory (partial fill), and reverts `SwapInDrainsProceeds()` when `POOLED_USD_BTC < pendingSwapOutUsd` (`SwapLib:794`); the free reserve is `POOLED_USD_BTC − pendingSwapOutUsd` (`Core:147`). Today those dollars are WALLED OFF from the ETH curve's dollars by the two-counter split, so the BTC curve can starve while the ETH curve is flush. ⇒ **Unifying `POOLED_USD` (#12) lets the BTC curve draw on the shared, same-chain, flash-accessible dollar pool — which IS the root fix for the asymmetry, with no clamp, cap, or new WBTC reserve.** ⚠️ **Residual that unification does NOT fix, and should not:** delivering actual SATS to a vBTC redeemer is cross-chain and inherently async (cooperative close / splice). That is bounded by Bitcoin confirmation, not by protocol inventory — a latency, not a DoS. Do not build a same-chain BTC reserve to paper over it. | 🔴 open |
| **E4** | 🟠 **`depegLoss` HAS THREE JOBS; the user's rule is it should have ONE (2026-08-03: *"depegLoss should have no dual use scenarios — it's only relevant in an actual depeg"*).** ✅ **The SOURCE is clean** — verified, not assumed: `FeeLib.liveDepegBps:238` returns 0 on every non-depeg condition (no feed, stale feed → *"defer to CRE"*, answer ≤ 0, at/above peg, and within `DEPEG_DEADBAND_BPS`), and `Aux.getDepegSeverityBps:205` returns 0 when `stableFeed[token] == address(0)`. So the number itself only moves in an actual depeg. 🔴 **The dual use is at the CONSUMERS — one number doing three unrelated jobs, each justified by its own paragraph of prose:** (1) **redemption pricing** — `BasketLib._redeemQuote:825`, `redeemableBody:957` (the real job); (2) **mint headroom** — `Basket.sol:207`, `:258`; (3) **the BAND COMMITMENT gate** — `Core.sol:1020` `haircutTvl = _d[14] − depegLoss`, feeding `require(committedUsd18() <= haircutTvl)`. Job (3) is not redemption at all, and the long comment at `Core.sol:1013-1019` arguing why depeg-but-not-illiquid belongs there is itself the tell. ▶️ **Fix at the root, with #12:** the unified `POOLED_USD` gate gets its OWN named solvency figure instead of borrowing the redemption haircut. ⚠️ **Separate, and NOT this item:** a stable with no feed contributes ZERO depeg loss SILENTLY — BOLD has no feed today, so a BOLD depeg is invisible to all three jobs. That is §A.49's pinned-feed prerequisite, and it is the dangerous direction (silent under-haircut). | 🟠 open |
| **E5** | 🔴 **THE RETAINED SKEW PREMIUM NEVER REACHES LPs — it is #12's defect in a SECOND place (found 2026-08-03 under the user's "reseat + refill JIT" instruction).** `Core:270-271` `skewPremiumETH`/`skewPremiumBTC` are incremented by `recordSkewPremium` and, per `Core:290-291`, are *"a pure LP-retained-profit record, never decremented"*; `SwapLib:937` confirms *"`skewPremium*` has NO consumer beyond the counters + theta EWMA."* The withheld input *"stays as basket backing"*. 🔴 **But basket backing prices QU!D, not LP shares.** An LP's claim is `vogueETH()`/`pooled`; growing basket TVL does NOT raise `vogueETH()`. ⇒ **The premium charged for the LP's inventory risk accrues to QU!D holders.** Every comment in the path says it *"accrues to LPs as backing"* — structurally it does not. Same shape as #12: LP supplies inventory, value lands in the basket, LP share price never reads it. ▶️ **Fix:** route it through `feesPerShare`/`USD_FEES` (the accumulators that actually attribute to LPs), NOT the counters. ⚠️ **Requires #12's reconciliation, so do it WITH the unification, not before:** those dollars currently support the ≤TVL gate and QU!D redemption, so an LP claim against them must stop them being counted twice — the identical count-once problem #12 exists to solve. | 🔴 open |
| **E6** | 🟠 **RESEAT AND REFILL SHOULD FIRE TOGETHER (user, 2026-08-03).** Today `_rebalance()` (repack-first on every swap/deposit/withdraw, plus the permissionless `Vogue.reseat()` poke) **re-centres the RANGE but does not correct the INVENTORY** — it burns and re-adds at new ticks with whatever composition the pool has, sized by `sizeBySurplus` and throttled by `clampByBacking`. The refill that WOULD correct composition is the **unbuilt** active flash-serve (`SwapLib:768`, #100/J.3). ⇒ Separately, you can re-centre a skewed book (right ticks, wrong composition) or refill into a stale range. Firing them in one pass gets both right, and the JIT flash makes it self-funding. ⚠️ **ECONOMICS CHECK — the answer to *"unless this contradicts the economics"*, and it CUTS BOTH WAYS:** booking the ALREADY-RETAINED premium to LPs via the accumulators is correct and currently missing (see E5). Booking a **refill PROFIT** to LPs would be incoherent — any profit a refiller makes comes from the pool paying above-oracle for the scarce asset, i.e. **extracted from the LP's own curve**, so "gain to LPs" would be the LPs paying themselves and losing the spread. `_swapInSettle` already settles the refill at the honest `v4Price` for exactly this reason, and `payRefillBonus` was REMOVED (2026-07-22) on the same principle. ⇒ **The refill must stay profit-neutral at the honest oracle; the LP gain is the RETAINED PREMIUM, attributed via E5. Do not build a refill that earns a spread.** | 🟠 open |

**Why these survived a green suite:** 7 of 12 basket stables are 18-decimal and **every existing test uses
USDC**. That gap is narrower now (C1/C3/C4/C5/C10 closed on other evidence) but it is still real for C6–C9.

# 🟠 OPEN — structural / dedup
- ✅ **§D5 DONE** (2026-08-02) — the two `_takePreferred` branches collapsed to one; `decimals()` KEPT
  (legacy's positional divisor already broke in production). BasketLib 21,643 → 21,520.
- ✅ **§A.66b LEGACY COMPARISON — CLOSED** (2026-08-02). `Core.sol` 62 fns vs legacy `VogueCore.sol` 19,
  named one by one: 17 map 1:1, 26 are features legacy never had, 14 are `isBTC` duality accessors that
  REPLACE mirrored branches, 5 are `via_ir=false` stack splits. **Zero gratuitous decomposition**, and we
  are ahead by two (legacy's observation interpolation lives in `OracleLib` here). Measured NEGATIVE —
  do not re-open.
- ✅ **§A.52 interface dedup DONE** — 7→0 underscore interfaces, Aux 6→1, Core 4→1.
- 🟠 **§A.71b NEAR-MATCH dedup — STILL OPEN and still correct.** The scan matches EXACT signatures, so
  `{a,b,c}` vs `{a,b,c,d}` reads as unrelated. NEEDED: subset/±1-field structs; same CALL-SEQUENCE
  SKELETON with identifiers normalised; ETH/BTC twins compared BODY-BY-BODY. Start at
  `ChannelLib.supplyBody`'s three branches (Aave / BOLD / 4626).
- 🟠 **§A.56 part 2** — out-of-range ARGS; a responsibility-boundary move, not a signature change.
- 🟠 **§A.61** boundary definition — 6/8↔18; §A.72 proved a needed helper is missing. (task #7)
- 🟠 **G1–G10** gas (tracked as **B11**): basket scan 2–3× per tx; `decimals()` STATICCALL at 33 seams;
  13-iter SLOAD loops 4× per redeem; TWAP ≈ 42M gas suite-wide.

# 🟡 OPEN — capability / infra
- **§A.19b** `redeemVBtc` — rail exists, entrypoint does not. 3 contracts move together.
- **§A.43** attestation binding — EVM key IS enclave-born/sealed; only the quote binding is missing.
- **§A.5f** per-action auth (the timelocked recipient pin shipped as a SUBSET).
- **§J.8** weETH-on-Aave-v4 · **§A.15** VERIFY the possibly-inverted claim first · **§A.49** FRAX/sFRAX
  (a pinned Chainlink feed is a PREREQUISITE, not a follow-up — see §A.65).
- **§A.69** anvil E2E + real deploy gas — never run; ONE `forge script` closes both.
- **#18 Puppeteer E2E matrix** — pre-scoped, GATED on the contracts landing (recovered 2026-08-02).
- ✅ **THE 60 "SKIPPED" TESTS ARE 2 TESTS × ~30 INHERITING SUITES — and one is now UNSKIPPED.**
  There are exactly two `vm.skip` sites (`Alles.t.sol:2198`, `:4481`), both harness-gated, NEITHER
  RPC-gated — an archival endpoint does not unlock them.
  • ✅ **`testSwapIn_RealLightningHTLC` — FIXED and PASSING** (2026-08-02, `regtest/start-ln.sh`).
    It had silently skipped in EVERY suite run. Nothing was wrong with LND, ZMQ or bitcoind: **LND
    reports `synced_to_chain: false` while the chain tip's TIMESTAMP is stale, even when its
    `block_height` already equals bitcoind's.** An idle regtest chain is thus permanently "unsynced",
    so `start_node` burned its 120s wait and `swapin-e2e.sh` returned SKIP. Measured: alice at height
    187 == bitcoind with `synced_to_chain: false`; **mining ONE block flipped it true in 5s.**
    Now verified end-to-end — channel opens at 500,000 sat, a 50,000 sat swap settles with the
    preimage captured, and the forge test PASSES.
    ⚠️ **Known caveat:** the test is inherited by ~30 suites, so a WHOLE-SUITE run fires the harness
    script 30× concurrently and they race into SKIP. It passes against a single suite. Fix is either
    an idempotency lock in the script or confining the test to one suite — a harness design call.
  • 🔴 **The cross-chain `e2e_ffi` test stays skipped — Docker-blocked, not fixable here.**
    `cargo run -p quid-hop --features harness --bin e2e_ffi` fails on macOS: `quid-cvm` is Linux-only
    and transitive (`E0432`, confirmed 2026-08-02). Same blocker as the **51 quid-ln Rust tests that
    have never run.** Needs Docker `rust:1.90` up. **This is the largest untested surface left.**
- 🔴 **RPC — HALF DONE.** The plaintext Ankr token is REMOVED from `foundry.toml` (both sites now keyless
  `https://ethereum-rpc.publicnode.com`; a bare `forge test` forks with no env var). **THE TOKEN STILL
  NEEDS ROTATING AT ANKR — it is in git history and this repo has a public-snapshot commit (`0af7f6d`).**
  ✅ **UPDATE 2026-08-02: `foundry.toml` now carries NO endpoint at all.** The RPC lives in
  `evm/.env` (gitignored, untracked); `git grep` finds no key in any tracked file. Note **Foundry does
  NOT interpolate `${VAR}` in `eth_rpc_url`** — it passes the literal through and the fork dies with
  *"could not instantiate forked environment"*. It reads `ETH_RPC_URL` natively and auto-loads
  `evm/.env`, so the key is simply REMOVED, not parameterised. `rpc_endpoints` DOES interpolate.
  Full suite re-verified on the archival key: **3,560 pass / 1 fail / 60 skip** — unchanged, and the
  #12 failure reproduces at a third block with the same ≈$59,966.
- **§A.46** 3 assertion-free tests remain (of 7).
- **JIT-DEPTH §2** — genuinely deferred, blocker LIFTED (`Basket.turn` exists, `Basket.sol:167`).

# ✅ CLOSED 2026-07-29
§A.50 preferred redemption paid ~8x par · §A.55 de-lever drained the basket · §A.57 LP fees under-paid
1e12x (both settle paths) · §J.2 (VBtc + VEth) · §J.7 · §A.54 (`tl`/`tu`, `OorTicks`) · §A.56 part 1
(22 lines of copied sizing → one definition) · §A.62 (tree layout; **0 dual definitions tree-wide**) ·
§A.63 (dead test) · §A.5f subset (timelocked recipient pin) · #12 (both senses).
**Premises WITHDRAWN after code verification** — §A.5c, §A.35, §A.19b-as-written, §A.43, and two of four
tolerance findings. Four queue items rested on claims that dissolved on contact with the code.

# ⚠️ PROVENANCE OF THE "OPEN" STATUSES ABOVE — read before trusting them

User (2026-07-29): *"are you sure all those open items are still open … i'm not sure you were diligent
in keeping track of your work in the doc, and we have been starting new tasks on the fly without
finishing previous ones."* **A fair challenge, and the gap is real:** when this file was written, TODAY'S
items (C1–C9, F1/F2, §A.46–§A.73) were verified against the code, but the INHERITED items were carried
forward from a conversation summary and **NOT re-checked**. That is exactly the failure that already
recurred three times today — §A.35, §A.43 and #109 were all "open" items that turned out to be BUILT.

SPOT-CHECKED SINCE (verified against code):
  ✅ **§J.8** genuinely OPEN — 0 hits for a weETH/Aave supply pairing in `Vault.sol`.
  ✅ **§A.19b** genuinely OPEN — no `redeemVBtc` in `VBtc.sol`.
  ✅ **§A.5f** genuinely OPEN — no `perActionAuth`/`actionScope` anywhere in `src/`.
  ⚠️ **§A.43** — 2 files in `quid-bridge/src` match `eth_wallet`/`evm_address`. Consistent with the
     earlier correction (the EVM key IS enclave-born/sealed; only the QUOTE BINDING is missing) but the
     precise remaining delta is UNCONFIRMED. Read the quote-construction path before starting work.

### VERIFIED EXPLICITLY (2026-07-29, user: *"verify everything explicitly"*)
  ✅ **§A.49 FRAX/sFRAX — genuinely OPEN.** `FRAX`/`SFRAX` appear **0 times** in `src/` or `script/`.
     Not listed. (Reminder: a pinned Chainlink feed is a PREREQUISITE for listing, not a follow-up.)
  ✅ **JIT-DEPTH §2 — genuinely DEFERRED.** The `depth-guarantee core … DEFERRED` marker is still the
     only hit in `Vogue.sol`; the core was never built. Blocker IS lifted (`Basket.turn` exists).
  ⚠️ **§A.15 — MECHANISM PRESENT, CLAIM STILL UNVERIFIED.** `bufBps` occurs 4x in `Basket.sol`, so the
     tiered buffer→tenor gate is real. What remains unproven is the item's CLAIM that a deposit INFLATES
     that buffer — a par mint raises `total` and `totalSupply` together, which moves `bufBps` DOWN.
     **Read the update-vs-mint ORDERING before writing any fix; the claim may be inverted.**
  ✅ **§A.46 — CORRECTED: only ONE assertion-free test remains, not three.** The committed agent work
     (`ce3969d`) covered more than credited. The sole survivor is
     **`ZZBoldProbe.t.sol:test_probe`** — the agent's own new file, which is the F2 reproduction
     (BOLD not reaching the Stability Pool). It should get assertions or be renamed out of `test*`
     once F2 is traced.

❌ **STILL UNVERIFIED — the honest count.** User asked *"are you sure you looked exhaustively?"* — **NO.**
   Measured: the archive holds **109 distinct items** (`A.x` + `J.x` + `MISS`), of which **40 carry an
   open-ish marker** (🔴/🟠/TODO/OPEN). **I have verified 7 of those 40.** So **33 open-marked items are
   UNVERIFIED**, and on today's hit rate a meaningful share are probably ALREADY DONE:
   §A.35, §A.43 and #109 were each marked open and turned out to be BUILT, and four more items' premises
   dissolved entirely when checked (§A.5c, §A.35, §A.19b-as-written, §A.43).
   ⇒ **DO NOT plan capacity off the open-marker count.** The real backlog is smaller than 40 but nobody
     knows by how much. The single highest-value next action on this file is a SWEEP: for each of the 33,
     grep the code BY EFFECT and record verified-open / already-done / premise-withdrawn. That is cheap
     (minutes per item) and it is the only way this list becomes trustworthy. **Before
   starting ANY of them, grep the code for the mechanism BY EFFECT** (not by name — #109 was a numbered
   issue whose fix was a cap change, invisible to a name search). Assume a listed item may already be
   done until shown otherwise.

# ⚠️ STANDING TRAPS (each cost real time today)
1. **An empty grep proves nothing** — verify the search finds a case you know exists.
2. **Verify from the SAME run** — never enumerate one test run's failures with a second invocation.
3. **`forge build --force`** before any test; stale bytecode silently invalidated checks 3x.
4. **Failures are findings** — but a test asserting surprising behaviour may be a SPECIFICATION
   (`testRedeem`'s immature-drain assertion nearly got "fixed" into a regression).
5. **Check the fixture RUNS** — 7 tests were inert because the fixture never seeded backing.
6. **Some splits are load-bearing** — `POOLED_USD_ETH`/`_BTC` must stay separate.
7. **An audit's `file:line` findings ≠ its fix snippets.** The C2 patch was wrong; applying it cost 333
   failing tests.

# ═══ NEW (2026-07-31, user) — banked before anything is started ═══

## 🔴 D5 — STREAMLINE TARGETED REDEMPTION onto the preferred INDEX (the strong dedup candidate)
User: *"can't it be streamlined if the token is the preferred token matching the preferred index?
(didn't you see how the legacy codebase did it streamlined)"* — **yes, and the legacy is the proof.**
`BasketLib.sol:530-532` comments the branch *"Targeted redemption (token==quid + preferred!=0): the
stable to shed"*, then `:579-591` dispatches to `_takePreferred`. But the basket ALREADY indexes stables
(`toIndex[preferred] > 0` is the validity check at `Aux.sol:914`), so the branch RECONSTRUCTS what the
index encodes. Legacy `_take` had no per-token dispatch at all — one positional loop with
`uint divisor = (i < 4 || i == 11) ? 1e12 : 1;`.
⇒ SHAPE: drive the pro-rata loop by INDEX and let "preferred" be a weight/skip on that same loop, rather
  than a separate code path. **This is the SAME function the C1/C2 unit seam runs through** — do it
  WITH §A.61's boundary work, not separately, or the two will conflict.

## 🟠 LAYOUT PASS additions (§A.62)
  • `src/mock.sol` → `src/imports/` — it is a helper, not a deployed contract.
  • **Fold `QuidLens`** — a separate contract for what could be internal views. User: *"we can be more
    elegant than requiring a separate QuidLens contract to exist"*. Check EIP-170 impact first; it may
    exist BECAUSE Aux/Core are near the limit, in which case it stays and the reason gets documented.
  • 🔴 **`Vogue`'s ERC-20 + ERC-4626 WRAPPER BLOCK IS LEFTOVER §J.2.** Its own header still says it
    *"adds standard ERC-20 transfer/approve plus the ERC-4626 view + deposit/redeem entry points"* —
    exactly what `VEth`/`VBtc` now own. §J.2 moved the IDENTITY but left this block. **This is an
    INCOMPLETE §J.2, not a design choice.** Removing it is the rest of "Vogue is not a 4626".

## 🔴 CLAMP POLICY (user, standing): *"minimise clamps that give a false sense of safety … rather than
treating a symptom attack issues at their core."* **C4 is the proof case:** the `θ > 1e18 ? 1e18` cap was
deleted at `VogueLib.sol:376-381` as *"adds no safety"* — behaviourally true, but it was the ONLY thing
that would have made a 1e12 corruption OBSERVABLE (via `Vogue.derivedThetaWad`). Meanwhile `:470` FLOORS
θ and never caps. ⇒ The fix is the unit conversion at `SwapLib.sol:441-442`, NOT a new clamp. Apply this
lens to every existing clamp: does it prevent a bad state, or merely hide one?

## 🔵 INVESTIGATE — none started, all need real data
  • **DISCOVERABILITY (asked twice, still unanswered):** we trade via mockTokens inside PoolManager, so
    can external routers/aggregators DISCOVER us for e.g. an ETH swap the way they discover other v4
    hooks? Known: `Aux.swap` is `public payable` and ungated (verified earlier). UNKNOWN: whether the
    mock-token pools are enumerable/routable by third parties, and whether we WANT them to be. This
    determines whether external order flow is reachable at all.
  • **UNISWAP V4 PROTOCOL FEE — recently activated. RESEARCH ONLINE.** User: *"since we use mock tokens
    we could go around the fee intelligently."* Needs: what the fee is, how it is set/collected per pool,
    and whether a mock-token pool is subject to it. ⚠️ Judge the ETHICS/RISK too — deliberately routing
    around a protocol fee is a governance-relations question, not just a technical one.
  • **ETHER.FI v3 POOL IMBALANCE (Rover's pool) — get ON-CHAIN data.** Why is it imbalanced and why do
    arbers not close it? HYPOTHESIS (untested): weETH→ETH exit costs ~0.3% instant OR a multi-day wait
    NFT, so arb only pays above that threshold, leaving a PERSISTENT uncaptured band. Check pool
    reserves/ticks + recent swaps to confirm or kill.
  • **LEGACY DIFF — never ran** (agent died on a weekly API limit). Re-run when quota resets. Prompt is
    written: compare `SPV/evm/src/` vs `quid/evm/src/`, ranked missing-guards → dropped-gas-techniques →
    lost-capability, excluding the prediction-market and Chainlink files.

## 🔴 §J.2c — THE ERC-20 TRANSFER FACE IS AMBIGUOUS ON A TWO-ASSET MANAGER (user, 2026-07-31)

User: *"it still has transferFrom which makes it awkward that you dont know which shares you are
transferring."* **Correct, and verified — the problem is worse than ambiguity, it is ASYMMETRY:**
  • `Vogue.balanceOf(user)` (`Vogue.sol:1168-1170`) returns `autoManaged[user].pooled` — the **ETH band
    ONLY**.
  • BTC band shares live in **a different contract**: `Vault.autoManagedBTC[user].pooled`
    (`Vault.sol:158-162`).
  • So `Vogue.transferFrom` (`:1188`) silently moves ETH shares while Vogue is the manager for BOTH
    assets, **nothing in the signature says which**, and **BTC band shares have NO transfer face at all.**
⇒ An ERC-20 face on a two-asset manager is ILL-DEFINED BY CONSTRUCTION. This is the same defect §J.2b
  fixed for the 4626 VIEWS (`asset()` cannot name one asset when the contract manages two) — the
  TRANSFER half was simply never moved. **§J.2 is therefore NOT complete**; correcting the header
  (`f490b18`) fixed the documentation, not this.

### THE FIX — move the token SURFACE, keep the STATE
`VEth` is unambiguously the vETH token, so `transfer`/`transferFrom`/`approve`/`allowance`/`balanceOf`/
`totalSupply` belong THERE, forwarding into Vogue's existing internal `_transferShares`
(`Vogue.sol:1209`, which already settles BOTH parties' pending rewards before principal moves — that
invariant is preserved unchanged). Vogue keeps the STATE and stays the authority; `VEth` stops being a
read-only projection and becomes the full token face. Vogue's public ERC-20 methods then go away, so
"which shares?" cannot be asked.
⚠️ CONSTRAINTS: (a) `_transferShares` must become callable ONLY by `VEth` (add the gate, mirroring
`VBtc.onlyVault`); (b) `Vogue.balanceOf` is read by tests and possibly the SPA — run
`tools/check-client-abis.py`; (c) EIP-170 — Vogue SHRINKS, `VEth` grows; (d) full suite, since this
touches the withdraw/lev paths that read `autoManaged[].pooled`.
### AND THE SYMMETRIC GAP
BTC band shares (`Vault.autoManagedBTC`) have **no ERC-20 face whatsoever** — they are not transferable.
DECIDE DELIBERATELY: is that intentional (channel-bound BTC should not be freely transferable) or an
omission? If intentional, DOCUMENT it; if not, it is `VBtc`'s job — note `VBtc` currently faces the
LEVERAGE collateral, not band shares, so the two must not be conflated.

### §J.2c CORRECTION — I conflated the vBTC TOKEN with the BTC BAND SHARES (user, 2026-07-31)

User: *"but vBTC needs those functions too, why arent they transferable? we discussed this before
related to anonymity."* **`VBtc` ALREADY HAS them** — `transfer` (`VBtc.sol:61`), `transferFrom` (`:70`),
`approve` (`:84`), full ERC-20. My §J.2c note above wrongly implied otherwise by mixing two things:
  • **`VBtc` — the TOKEN (leverage collateral face).** Transferable TODAY. ✓
  • **`Vault.autoManagedBTC[].pooled` — the BTC BAND SHARES.** A separate quantity in a separate
    contract, with no token face. That is the asymmetry §J.2c actually identified, and it stands.

### 🔒 WHY TRANSFERABILITY ALONE IS INERT — the anonymity thread
`VBtc.sol:19-22` records the blocking rule verbatim: *"the LP never receives loose vBTC (that would
double-claim the same channel BTC)"*, and that single rule *"blocks BOTH an open Morpho/Euler market (a
liquidator who seizes vBTC has no way to exit) AND the privacy story (no bearer instrument)."*
⇒ So vBTC is transferable but **nobody except the pinned LevManager ever HOLDS it** — the transfer
  functions are reachable and unused. For vBTC to be the privacy instrument that was discussed, THREE
  things must all hold, and only the first exists:
  1. ✅ TRANSFERABLE — done (`VBtc.sol:61,70,84`).
  2. ❌ **LPs able to RECEIVE it** — blocked by the "never loose vBTC" rule, asserted in THREE places
     that must move together: `Vault.sol:638`, `BtcLevManager.sol:578`, `VBtc.sol:19`.
  3. ❌ **BEARER REDEMPTION (`redeemVBtc(sats, p2trScript)`)** — §A.19b, not built. Without it a
     transferee holds a claim they cannot exit, so transferability is worthless to them.
⇒ **§A.19b IS the anonymity work.** It is not a separate nice-to-have: 2 and 3 are the same change, and
  the aggregate invariant `Σ outstanding vBTC <= Σ free channel capacity` is what must REPLACE the blunt
  rule so that 2 becomes safe. The payment rail already exists (swap-out pays an arbitrary P2TR whose
  owner has no channel), so this is wiring plus an invariant swap, not new capability.
📌 DECISION STILL NEEDED on the BTC BAND SHARES (distinct from the above): channel-bound band depth may
  be deliberately non-transferable. If so, DOCUMENT it; if not, it needs its own face — and it must NOT
  be folded into `VBtc`, which is the leverage-collateral token, not band shares.

### ✅ BTC BAND SHARES ARE NON-TRANSFERABLE **BY NECESSITY** — question CLOSED (user, 2026-07-31)

User's hypothesis — *"because of what a channel is hardwired to empty out into? channels can grow by
splicing to accrue fees but cannot change their original LP?"* — **CONFIRMED IN CODE. Do not make them
transferable; doing so would break the bridge's trustlessness.**

EVIDENCE:
 1. **The payout script is fixed and un-redirectable.** `BTCChannels.sol:719`: the close pays the
    balance *"to outputs paying that script; **a hop can never redirect the payout**."* That property IS
    the trust-minimisation — the hop cannot steal because it cannot change where BTC lands.
 2. **One channel per LP address, structurally.** `BTCChannels.sol:245-252`: `autoManagedBTC[lpEth]` is
    keyed per-address, and *"a SECOND open for an lpEth that already has one would let the aggregate
    `pooled` span channels while close attributes per-channel — mis-attributing the others' notional as
    delivered (over-mint) and wiping their positions."*
 3. **Splice is the capacity knob, not re-assignment.** Same block: *"Splice … (resize one channel in
    place), so an LP never needs two channels; an entity wanting more positions uses more addresses."*
    ⇒ A channel GROWS with fees but its LP binding is FIXED — exactly as the user described.

⇒ **The EVM band share and the Bitcoin channel are ONE UNIT.** An EVM-side transfer would decouple
  them: the transferee would hold a claim whose BTC payout still pays the ORIGINAL LP's script, i.e. a
  claim they cannot enforce. Real transfer would require moving the Bitcoin-side channel too (a BTC
  transaction / splice-out-splice-in), which is not an EVM operation.
⇒ **This is a DESIGN INVARIANT, not a gap.** It is now documented rather than implicit — that was the
  open decision in §J.2c, and it is CLOSED: **do not build a transfer face for `autoManagedBTC`.**

📌 CONTRAST — this is exactly why **vBTC (the leverage-collateral TOKEN) CAN be transferable** while band
  shares cannot: vBTC is minted against ALREADY-BANKED channel depth and is redeemable (once §A.19b
  lands) against `Σ free channel capacity` in AGGREGATE — it is not bound to one channel's payout
  script. The two must never be conflated, and §A.19b's aggregate invariant is precisely what keeps
  vBTC's fungibility from double-claiming a specific channel's BTC.
📌 SWAPS still work because they do NOT move band shares: a swap-out pays an arbitrary P2TR from
  protocol-side BTC (with `creditSwapOut` recording the obligation), leaving `autoManagedBTC[lpEth]` and
  its channel binding untouched. That is why swap-out could be built without breaching this invariant.

## 🔴 §A.19b RE-FRAMED — vBTC **IS** TOKENIZED BAND DEPTH. My distinction was incoherent (user, 2026-07-31)

User: *"if it's a 4626 then the token balance is the shares. you cant say vBTC is transferrable then say
the shares are not… vBTC represents a deposit in the band."* **Correct. Struck my §J.2c framing.**
 • `VBtc` carries a 4626 face — `asset() → WBTC`, `convertToAssets(shares) => shares` (a pure identity,
   vBTC IS sats). So **the token balance IS the share.**
 • `Vault.exposeBtcToLev` mints it by RECLASSIFYING already-banked channel depth:
   `levPooledBTC[lp] += sats` with **`LP.pooled` UNCHANGED** (single-count). ⇒ vBTC is not a separate
   asset; it is a TOKENIZED SLICE OF THE LP'S OWN BAND DEPTH.
⇒ Saying "vBTC transferable, band shares not" was incoherent — they are the SAME CLAIM at two layers.

### 🔑 THE ACTUAL DESIGN QUESTION §A.19b MUST ANSWER
**If a bearer redeems vBTC, WHOSE band depth shrinks?** Today the question cannot arise: vBTC only ever
reaches the pinned LevManager, and `unexposeBtcFromLev` burns it back to the SAME LP (`lev → funded`,
`LP.pooled` untouched). A CIRCULATING bearer breaks that 1:1 return path — the redeemer is not the LP
whose depth backed the mint.
⇒ That is what `Σ outstanding vBTC <= Σ free channel capacity` must actually enforce: redemption draws
  from AGGREGATE free capacity, not from the minting LP specifically — which is only sound if the
  aggregate bound holds at every instant, and if some rule decides WHICH LP's depth is consumed (pro
  rata? the LP with most free capacity? the one whose channel can pay out cheapest?). **That choice is
  the open design decision, and it is NOT yet made.**
⚠️ AND IT INTERACTS WITH THE NON-TRANSFERABILITY RESULT ABOVE: band shares are bound to ONE channel with
  a FIXED payout script (`BTCChannels.sol:719`). So a bearer redemption must be paid from a channel
  whose script pays the REDEEMER — i.e. it is the swap-out rail, not a channel close. Good news: that
  rail exists and already pays arbitrary P2TR.

### ❌ CORRECTION — I claimed "swaps leave band shares untouched". WRONG.
Swap-out DOES reach band depth via delivery-side de-lever — there is a test named
`testReal_DeliverSideDelever_SwapOutTapsLeveredSlice`. So the mechanism for "a third party's redemption
consumes an LP's levered slice" ALREADY EXISTS and is exercised. **§A.19b should be modelled on that
path, not invented** — the question is only what authorises it for a bearer rather than a swapper.

## 📌 LAYOUT PASS (§A.62) — additions banked
  • `src/mock.sol` → `src/imports/`; fold `QuidLens` (check EIP-170 first — it may exist BECAUSE
    Aux/Core are near the limit).
  • **§J.2c (ETH side only):** move Vogue's ambiguous ERC-20 face to `VEth`, forwarding into
    `_transferShares`, gated to `VEth`. BTC side is CLOSED — do NOT build a face for `autoManagedBTC`.
  • **The LEGACY DIFF is part of this pass** (agent died on a weekly API limit; prompt is written).
  • **CLAMP LENS, apply throughout:** *"does this clamp prevent a bad state, or merely hide one?"*
    C4 is the proof case — the θ cap was deleted as "adds no safety", which was true behaviourally and
    is exactly why a 1e12 corruption became invisible.

### TWO CORRECTIONS (user, 2026-07-31)

**1. De-lever on swap-out is CONTINGENT, not the normal path. My claim was overstated.**
User: *"swapout might not need de-lever, it's contingent on need (case per case)."* Correct.
`SwapLib.sol:1195` documents `deleverEthOnDelivery` as firing *"when the venue base (`deliverableETH`)
can't cover a swap-out delivery"*, and `Vogue.sol:1026` calls it inside a conditional with
`needed - inWETH` — a SHORTFALL amount. ⇒ A swap-out normally settles from the free venue base and never
touches the levered slice. Only a shortfall reaches band depth.
⇒ CONSEQUENCE FOR §A.19b: the "third party consumes an LP's levered slice" precedent is a FALLBACK path,
  not a routine one. It is still the right MODEL, but bearer redemption would invoke it far more often
  than swap-out does — so its cost/fairness profile must be judged on its own, not inherited from a
  rarely-taken branch.

**2. 🟠 IS THE RECLASSIFICATION DUPLICATION? — a real consistency risk, worth its own item.**
User asked directly. `exposeBtcToLev` writes the SAME sats into THREE places:
  • `LP.pooled` — UNCHANGED (deliberate: single-count of band depth)
  • `levPooledBTC[lp] += sats` — a SUBSET MARKER (free depth = `pooled - levPooled`)
  • `VBtc.balanceOf[manager] += sats` — the external token representation
These are three VIEWS of ONE economic claim, so it is not double-counting BY DESIGN. **But they are
three independently-mutated storage locations that must stay in lockstep**, and nothing enforces that
mechanically — if `levPooledBTC` and `VBtc.totalSupply` ever drift, the drift IS a double-spend
(depth counted as free while its token is still outstanding).
⇒ ACTION: state and TEST the invariant explicitly —
  **`Σ_lp levPooledBTC[lp] == VBtc.totalSupply()`** at all times. That is a one-line property, it is
  exactly the kind of thing Echidna is for, and it is currently UNASSERTED anywhere.
⇒ It is also the natural precondition for §A.19b's aggregate rule: you cannot safely enforce
  `Σ outstanding vBTC <= Σ free channel capacity` without first knowing the supply and the marker agree.

# ═══════════ COMPLETE OPEN-ITEM REGISTER (2026-07-31) — nothing omitted ═══════════
Every open item, each with the exact next action. No item appears only in conversation.

## A. MONEY PATH — fix, then verify
| # | item | exact next action |
|---|---|---|
| A1 | **C2** `Core.sol:989` 6-dec→native | APPLIED with `BasketLib.from6`. **Suite running.** If green, done |
| A2 | **C5** `Vogue.sol:658` missing `*1e12` | APPLIED (`owed * 1e12`). Same suite run |
| A3 | **C3** `BasketLib.convert` 1e10 off, `volScale=1e8` | 2 sites: `SwapLib.sol:1013`, `:444`/`:455`. Authoritative form `SwapLib.sol:926-929` (`/1e30`). **ONLY after C1+C2 confirmed** — else it arms `Core.refundUnfilled` |
| A4 | **C4** wei premium → 6-dec register; θ throttle DEAD on ETH | Convert at `SwapLib.sol:441-442` — price already in hand; idiom `mulDiv(x, base, 1e30)` at `:969`. **Also fix the BTC mirror** (8-dec ⇒ ~1e3 UNDER-report ⇒ over-throttle) |
| A5 | **C6** `seedFee:319-321` native fee vs 18-dec headroom | clamp never binds for 6-dec; second clamp `:322-323` is correct |
| A6 | **C7** `twapBody:123` ungated BTC-ring fallthrough | `getTWAPforAsset`/`resolvedTwap`/`wellSkew` public+ungated; view-only today |
| A7 | **C8** `Vogue.sol:978-989` stale read across repack | reads `POOLED_USD_ETH` BEFORE `_rebalance()` which can zero it (`Core.sol:778`) |
| A8 | **C9** `scaleTo6` on 4626 SHARE decimals | SUSPECTED; DoS not loss. Confirm whether any wired vault has share≠underlying decimals |
| A9 | **F1** control-LP redeem delivers 0 | likely a FIXTURE warp (immature QU!D = intended). VERIFY before touching protocol |
| A10 | 🔴 **INVARIANT: `Σ levPooledBTC[lp] == VBtc.totalSupply()`** | **UNASSERTED ANYWHERE.** One line. Drift = double-spend (depth free while token outstanding). Echidna target; PRECONDITION for §A.19b's `Σ outstanding <= Σ free capacity` |

## B. REFACTOR / DEDUP
| # | item | exact next action |
|---|---|---|
| B1 | **§J.2c** Vogue's ambiguous ERC-20 face | move `transfer`/`transferFrom`/`approve`/`balanceOf`/`totalSupply` to `VEth`, forward into `_transferShares` (`Vogue.sol:1209`), gate that internal to `VEth` (mirror `VBtc.onlyVault`). Run `check-client-abis.py`; EIP-170 both ways. **BTC side CLOSED — build no face for `autoManagedBTC`** |
| B2 | **D5** targeted-redemption streamline | drive the pro-rata loop by INDEX; make "preferred" a weight/skip on that loop, not a branch (`BasketLib.sol:530-532`, `:579-591`). Legacy did it with one positional loop. **Do WITH §A.61** — same function as the C1/C2 seam |
| B3 | **§A.61** define the 6/8↔18 BOUNDARY | name the functions where conversion happens; convert ONLY there; put the basis in parameter NAMES (`amountUsd18`/`amountNative`/`sats8`). `from6` now exists; `scaleTo6` is its inverse |
| B4 | **§A.71** `LevManager.Pos` == `BtcLevManager.Pos` | same name+shape, different files. Merge into `Types.sol`; check EIP-170 (25,164 / 21,843 initcode) |
| B5 | **13 near-match dedup findings** | see `GAS-AND-CORRECTNESS-AUDIT.md`. Biggest: `_valueStable` vs `_illiquidLoss` share a whole 4626 ladder; `SPWithdrawResult ⊃ SPState`; `isEthVenue` verbatim twice; hand-rolled decimal scaling ×2 |
| B6 | 🔴 **`initVaultsBody` omits validation** | `ChannelLib.sol:470-476` vs `setVaultBody:441-448` — constructor path skips the `asset() != stable` check, duplicate scan, and primary guard. **Deliberate or bug? VERIFY** |
| B7 | **§A.52** interface dedup | 95 locals, ZERO name-duplicates ⇒ semantic. Group by target contract (`IAux*`/`ILev*`/`ICore*`), diff member sets. Minimal shims are EIP-170 optimisations — do not blindly fold |
| B8 | **§A.56 part 2** out-of-range ARGS | responsibility-boundary move, not a signature change. Partial at `/tmp/A56-partial.patch` |
| B9 | **Layout**: `mock.sol` → `imports/` | it is a helper, not a deployed contract |
| B10 | **Layout**: fold `QuidLens` | check EIP-170 FIRST — it may exist BECAUSE Aux/Core are near the limit; if so, document why it stays |
| B11 | **G1–G10 gas** | same basket scan 2–3× per tx; `decimals()` staticcall at 33 seams (legacy used a zero-call divisor); 13-iter SLOAD loops 4× per redeem; TWAP ≈42M gas suite-wide |

## C. INVESTIGATE — no data yet, do not guess
| # | item | exact next action |
|---|---|---|
| C-1 | **Router DISCOVERABILITY** (asked 3×, unanswered) | we trade mockTokens inside PoolManager — can external routers/aggregators FIND us for an ETH swap the way they find other v4 hooks? `Aux.swap` is public+ungated (verified). Unknown: are the mock pools enumerable/routable, and do we WANT that? |
| C-2 | **Uniswap v4 PROTOCOL FEE** (recently activated) | research online: what it is, how set/collected per pool, whether a mock-token pool is subject. ⚠️ Routing around it is a GOVERNANCE question, not only technical |
| C-3 | **ether.fi v3 pool imbalance** | get ON-CHAIN data. Hypothesis: weETH exit costs ~0.3% instant or a multi-day NFT ⇒ arb only pays above that ⇒ a PERSISTENT uncaptured band. Check reserves/ticks + recent swaps |
| C-4 | **LEGACY DIFF** — never ran (agent hit weekly API limit) | `SPV/evm/src/` vs `quid/evm/src/`, ranked missing-guards → dropped-gas → lost-capability. Exclude Court/Jury/Solver/Amp/Link. Prompt written |
| C-5 | **Verify the 33 unverified open-marked items** | 109 items, 40 open-marked, 7 verified. Grep BY EFFECT. Several are likely ALREADY DONE (§A.35, §A.43, #109 all were) |
| C-6 | **§A.19b: WHOSE depth shrinks on bearer redemption?** | the open DESIGN decision. Pro rata? Most free capacity? Cheapest payout? Must pay via the SWAP-OUT rail (arbitrary P2TR), not a channel close. Model on delivery-side de-lever — but note that is a FALLBACK path, so judge cost/fairness independently |
| C-7 | **§A.46** last assertion-free test | `ZZBoldProbe.t.sol:test_probe` — assert it or rename out of `test*` once F2's cause is settled |
| C-8 | **anvil E2E + real deploy gas** | ONE `forge script script/DeployL1_s.sol --fork-url <anvil>` closes both (§A.35 debt + §A.69) |
| C-9 | **RPC**: `foundry.toml:34` | hardcoded rate-limited Ankr key, **committed in plaintext** in a repo with a public-snapshot commit ⇒ ROTATE. Use `${MAINNET_RPC}`. Working: `ethereum-rpc.publicnode.com` |
| C-10 | **JIT-DEPTH §2** | genuinely deferred; blocker LIFTED (`Basket.turn` exists, `Basket.sol:167`). Re-derive `D >= S + L` against `turn` — do NOT copy the doc's math, which is what proved wrong |
| C-11 | **§A.5f** per-action auth | timelocked recipient pin shipped as a SUBSET. Ranks behind §A.43 attestation |
| C-12 | **§A.43** attestation binding | EVM key IS enclave-born/sealed; only the QUOTE BINDING missing. 2 files in `quid-bridge/src` match — read the quote-construction path |
| C-13 | **§J.8** weETH-on-Aave-v4 · **§A.49** FRAX/sFRAX | both VERIFIED-OPEN. FRAX needs a PINNED CHAINLINK FEED as a PREREQUISITE, not a follow-up |
| C-14 | **§A.15** self-gating buffer | VERIFIED-OPEN, claim stands (a deposit raises its own `bufBps`). Fix not designed |

## 🔴 C2 + C5 REVERTED AGAIN — 31 failing vs a 3,559/1 baseline (2026-07-31)

Applied C2 (`Core.sol:989` → `BasketLib.from6`) and C5 (`Vogue.sol:658` → `owed * 1e12`) TOGETHER, ran
the suite: **3,531 passed / 31 failed.** Both reverted; tree restored. C1 stays (it is confirmed).

NEW failure mode, not seen before:
```
[FAIL: rung 3 paid native ETH via the real RedemptionManager: 0 <= 4900000000000000000]
       testEthVenue_EtherFi_Ins…
```
plus F1 (pre-existing). So ~30 regressions concentrated somewhere near the ETH withdraw/ether.fi ladder.

### ⚠️ METHOD FAILURE — I APPLIED TWO CHANGES AT ONCE, AGAIN
This is the SECOND time this session (§A.72 was the first) that two money-path edits landed together and
the failures could not be attributed. **The rule I keep breaking: ONE money-path change per suite run.**
C1's success came precisely from applying it ALONE against a falsifiable prediction.

### ISOLATION PLAN — do this before re-attempting either
 1. Apply **C5 alone** (`Vogue.sol:658`, `owed * 1e12`). Predict: FEW or NO failures — it mirrors
    `_settlePending:439`/`BtcVaultLib:57`/`:74`, all of which scale and all of which pass.
    ⚠️ IF IT FAILS: the hypothesis that `usd_owed` is 6-dec is WRONG, or minting the CORRECT (larger)
    amount breaches a backing check that was tuned to the under-payment. Either would be a bigger
    finding than C5 itself — a backing invariant calibrated against a bug.
 2. Apply **C2 alone** (`from6` at `Core.sol:989`). Predict: no change for 6-dec stables (from6 is
    identity there) and every test uses USDC — so a failure means `token` at that site is NOT always a
    6-dec stable. **CHECK WHAT `token` CAN BE at `Core.sol:989` FIRST** — if WETH or an 18-dec asset can
    reach it, `from6` multiplies by 1e12 and that is the regression.
 3. Only then consider C3, which must follow both.

📌 The ether.fi rung failure is the clue: `testEthVenue_EtherFi_*` exercises the ETH WITHDRAW LADDER.
   Neither C2 nor C5 is obviously on that path, so the mechanism is INDIRECT — most likely a mint or
   take amount feeding a backing/solvency check that then blocks delivery. Trace THAT rather than
   re-applying blind.

### C5 UNIT VERIFICATION — `usd_owed` IS consistently 6-dec, so `* 1e12` is arithmetically RIGHT

Traced every write to `LP.usd_owed` (there are TWO accrual sites, not one — the second was easy to miss):
  • `Vogue.sol:443` — `LP.usd_owed += usdR` inside `_settlePending`'s defer branch.
  • `Vogue.sol:1456` — `if (usdR > 0) LP.usd_owed += usdR` in the crank/harvest path.
**BOTH draw `usdR` from the same `_pendingFor(lp)`**, and `_settlePending:439` mints THAT SAME VALUE as
`usdR * 1e12`. ⇒ the field is 6-dec on every write, and C5's scale-up at `:658` is CORRECT ARITHMETIC.

⇒ **THEREFORE, IF C5-ALONE STILL FAILS, THE DEFECT IS NOT C5.** The remaining explanation is that
  minting the CORRECT (1e12 larger) amount breaches a BACKING/SOLVENCY CHECK — i.e. **an invariant
  calibrated against the under-payment.** That would be strictly more serious than the fee loss:
  a solvency check tuned to a bug will also reject the correct behaviour once the bug is fixed, and it
  silently blocked the ETH withdraw ladder (`testEthVenue_EtherFi_*`) rather than failing loudly at the
  mint.
  ⇒ NEXT IF SO: find which check rejects it — `Basket.mint`'s `auth` branch, `AUX.checkBacking`, or the
    `D >= S + L` requirement — and determine whether its threshold was derived from measured behaviour
    (in which case the measurement encoded the bug) or from first principles (in which case C5's
    premise is wrong after all).
📌 This is exactly the §A.46 lesson at protocol scale: a check that passes because the system is broken
  will FAIL when the system is fixed. Same shape as the tolerances tuned around a ~zero fee.

## 🔴🔴 C5 ISOLATED — **C5 ALONE causes all 31 failures. C2 is EXONERATED.** (2026-07-31)

C5 alone (`Vogue.sol:658`, `owed * 1e12`): **3,536 / 31 failed** vs a 3,559/1 baseline — SAME signature
as the combined run ⇒ **C2 caused none of it and is cleared.** C5 reverted; tree back to 3,559/1.

### THE ARITHMETIC IS RIGHT, SO SOMETHING ELSE REJECTS IT
`LP.usd_owed` is 6-dec on EVERY write — `Vogue.sol:443` (`_settlePending` defer branch) and `:1456`
(crank), both from the same `_pendingFor(lp)` — and `_settlePending:439` mints that SAME value as
`usdR * 1e12`. So `* 1e12` at `:658` is correct arithmetic.
⇒ **The identical scaling WORKS at `:439` and FAILS at `:658`. That difference IS the finding.**

### THE DISTINGUISHING CONDITION — `:658` fires ONLY when `LP.pooled == 0`
`:656` guards `if (LP.pooled == 0 && LP.usd_owed > 0)` — FULL EXIT, when the LP has NO remaining pooled
depth. `_settlePending:439` mints while the position is still open and still backing the system.
HYPOTHESES, ranked — **TEST BEFORE FIXING:**
 (a) **A solvency check rejects a mint against a position with no remaining pooled.** The correct
     (1e12 larger) QU!D breaches `D >= S + L` / `checkBacking` exactly when the LP's own contribution has
     gone to zero. ⇒ the defect would be the ORDERING (settle the fee BEFORE `pooled` hits zero), NOT
     the scale.
 (b) **Supply-inflation cascade:** 1e12x more QU!D moves `totalSupply()`, which moves `bufBps`
     (`Basket.sol:279-280`) and the backing/redeemable views, tripping unrelated gates — consistent with
     31 failures SPREAD ACROSS the suite rather than one.
 (c) My premise is wrong somewhere I have not found: a path scales `usd_owed` before it reaches `:658`.
📌 SYMPTOM FITS (a)/(b): the loudest new failure is `testEthVenue_EtherFi_*` — *"rung 3 paid native ETH
   via the real RedemptionManager: 0"* — the ETH WITHDRAW LADDER delivering NOTHING. **C5 is not on that
   path**, so the mechanism is INDIRECT: a mint amount feeding a solvency gate that then BLOCKS DELIVERY.
### NEXT STEP (do not re-apply C5 first)
Identify WHICH check rejects it — `Basket.mint`'s `auth` branch, `AUX.checkBacking`, or the `D >= S + L`
requirement — by running ONE ether.fi test with `-vvv` under C5 and reading the revert. Then decide
between (a) re-order the settle, or (b) a threshold calibrated against the under-payment.
⚠️ If (b): **a check that passes because the system is broken will FAIL when the system is fixed** —
  the §A.46 lesson at protocol scale, and materially more serious than the fee loss itself.

### C5 DIAGNOSIS — the reverting error is EXTERNAL, not one of ours. Hypothesis (a)/(b) NOT supported.

Ran `testEthVenue_EtherFi*` with `-vvv` under C5. The caught revert is **custom error `0xdc9cb0e2`**,
and it matches **NONE** of our errors: scanned all **130 zero-arg errors** in `src/`, then every
parameterised error across `src/` AND `lib/`. **No match.** ⇒ It originates from a LIVE MAINNET CONTRACT
on the fork — this test exercises the REAL ether.fi RedemptionManager (the assertion is literally
*"rung 3 paid native ETH via the real RedemptionManager"*).

⇒ **This WEAKENS hypotheses (a) and (b)**: it is NOT our `checkBacking` / `D >= S + L` / `Basket.mint`
  rejecting the larger mint. Something reaches ether.fi with different arguments and ether.fi refuses.
⇒ **REVISED HYPOTHESIS (d):** the extra QU!D changes a BACKING-DERIVED QUANTITY that sizes the offramp
  request — e.g. `deliverableETH` or a rung amount — so the ladder asks ether.fi for an amount it will
  not serve (their redemption has minimums/caps and a wait-NFT path). The mint is upstream; the refusal
  is downstream and EXTERNAL.
⇒ NEXT (cheap, and it settles it): decode `0xdc9cb0e2` against the ether.fi RedemptionManager ABI
  (Etherscan, or `cast 4byte`), and log the rung-3 request amount WITH and WITHOUT C5. If the amount
  differs, (d) is confirmed and the fix is in how the ladder sizes that rung — not in C5's scale and not
  in a solvency threshold.
📌 METHOD NOTE: 130 + all lib errors scanned and no match is a STRONG negative — I verified the scan
  works by construction (it enumerates declarations, not guesses). This is the good case of an empty
  search: exhaustive over a known set, so absence IS evidence here.
C5 REVERTED. Tree at 3,559/1.

## 🔴 C10 — **THE WITHDRAW LADDER DOES NOT CAP ITS ETHER.FI REQUEST.** `0xdc9cb0e2 == ExceededRedeemable()`

`cast 4byte 0xdc9cb0e2` → **`ExceededRedeemable()`** — ether.fi's OWN error, from the real mainnet
RedemptionManager. Hypotheses (a)/(b) are DEAD: it is not our solvency accounting rejecting anything.

### WHAT THIS ACTUALLY MEANS — and it is bigger than C5
The ETH withdraw ladder asks the ether.fi RedemptionManager for MORE THAN IT WILL REDEEM, and ether.fi
refuses. **C5 does not CREATE that condition — it merely makes it REACHABLE in tests** by shifting a
backing-derived quantity that sizes the rung-3 request.
⇒ **The latent defect is that the ladder does not clamp its request to ether.fi's redeemable capacity.**
  Any condition that inflates the request hits it: a large exit, a shifted backing figure, or simply
  ether.fi's own redeemable pool being small at that moment (it is EXTERNAL state we do not control and
  do not currently read).
⇒ Consequence today: **rung 3 reverts and delivers 0** instead of delivering what IS redeemable and
  deferring the rest — exactly the "partial fill then defer" behaviour the rest of the ladder is built
  around. A reverting rung wastes the whole rung.

### THE FIX (not applied — needs its own verification)
Read ether.fi's redeemable capacity and `min()` the request against it before calling, so rung 3 delivers
`min(want, redeemable)` and the remainder falls through to the next rung / deferral. Locate the rung-3
call site in the ETH ladder (`VaultLib` withdraw path), and check whether the RedemptionManager exposes a
public redeemable/cap view — if it does, this is a one-line clamp; if not, a `try/catch` that treats
`ExceededRedeemable()` as "deliver less, defer the rest" rather than as a hard failure.
⚠️ **This is a CLAMP THAT PREVENTS A BAD STATE, not one that hides one** (cf. the standing clamp policy):
  it converts an external refusal into a correct partial fill. Distinguish it from the θ cap that was
  rightly deleted for hiding a corruption.

### CONSEQUENCE FOR C5
C5's arithmetic remains correct (`usd_owed` is 6-dec on every write; the sibling at `:439` scales the
same value). **C5 is BLOCKED BY C10, not wrong.** Fix C10 first, then re-apply C5 ALONE and re-run —
prediction: C5 then passes, because the rung will clamp instead of reverting.

### C10 CORRECTED — it is an ALL-OR-NOTHING FALLTHROUGH, not a revert. Read the code, not my summary.

I wrote *"rung 3 reverts and delivers 0"*. **Wrong.** `SwapLib.sol:622-625`:
```solidity
if (weethIn > 0 && instant && c.redeemer != address(0)) {
    try IRedeem_L(c.redeemer).redeemWeEth(weethIn, recipient, ETHFI_NATIVE_ETH) { return covered; }
    catch {}
}
// Rung 4 — last-resort no-fee withdrawal NFT.
return waitNft(covered, recipient, c);
```
`ExceededRedeemable()` IS caught; the withdraw does not revert. It **silently degrades to rung 4**, the
multi-day wait-NFT.

⇒ **THE REAL DEFECT IS ALL-OR-NOTHING SIZING.** Rung 3 requests the FULL `weethIn`. If ether.fi can serve
  even 99% of it, the whole rung is abandoned and the LP is pushed onto a MULTI-DAY NFT instead of
  getting ~99% instantly. The `catch {}` makes that degradation INVISIBLE — no event, no partial fill.
⇒ SEVERITY revised DOWN from "delivers 0 / wastes the rung" to "**needlessly forces the slow path**" —
  a UX and capital-efficiency defect, not a solvency one. Still real: the whole point of rung 3 is to
  avoid the wait, and it is skipped whenever ether.fi's redeemable pool is momentarily smaller than the
  ask — EXTERNAL state we neither read nor control.

### THE FIX — clamp, then partial-fill
`redeemWeEth(weethIn, …)` should be `redeemWeEth(min(weethIn, redeemable), …)`, with the remainder
falling to rung 4. REQUIRED FIRST: confirm whether `EtherFiRedemptionManager` (impl `0x6bD1…91F7`)
exposes a public redeemable/capacity view. If YES → a one-line `min()`. If NO → binary-search the
amount, or catch `ExceededRedeemable()` specifically and retry at a fraction. ⚠️ Do NOT bare-`catch`
the retry — catching everything is what hid this.
📌 ALSO: replace `catch {}` with a catch that EMITS — a silent fallthrough from the instant rung to a
  multi-day NFT is exactly the class of thing that should be observable. (Cf. the standing clamp policy:
  this one PREVENTS a bad state — an unnecessary multi-day wait — rather than hiding one.)
📌 AND C5's status is unchanged: still correct arithmetic, still blocked behind this, since the test
  asserting rung-3 delivery is what fails.

## 🔴 C10 FIX BLOCKED BY EIP-170 — MEASURED, not guessed (2026-07-31)

User pushed back on my calling the observability fix "probably safe": *"not good enough. verify and look
at it from all angles."* **They were right, and the measurement proves it.**

APPLIED the fix (specific `catch (bytes memory)` + `emit InstantRedeemSkipped(weethRequested, reason)`
+ the event declaration + docblock) and measured:
```
SwapLib runtime  24,435 → 24,641    margin  +141 → −65      cost: +206 bytes
```
**⇒ OVER the 24,576 EIP-170 limit. UNDEPLOYABLE. Reverted; back to 24,435 / +141.**

📌 ALSO: a first, UNFORCED `forge build --sizes` reported 24,625 / −65 for the UNMODIFIED file and I
  briefly believed SwapLib was already over the limit. It was stale artifacts — a forced rebuild gave
  24,435 / +141. **Fourth stale-bytecode incident today**, and the first that nearly caused a false
  alarm rather than a false pass. `--force` before ANY size or gas reading, not just before tests.

### OPTIONS FOR C10, cheapest first
 1. **Emit from the CALLER, not the library.** `SwapLib` is delegatecall'd and has 141 bytes; `Vogue`
    and `Aux` have far more (Aux margin 1,757). Return a status/selector from the rung instead of
    emitting inside the lib, and let the caller emit. Costs a return value, not an event + string tables.
 2. **Shrink `SwapLib` first.** It is the largest lib (24,435 runtime) and the near-match scan already
    found slack in it: `_priceOr` is open-coded VERBATIM at `:441` and `:463` while its own docblock
    claims it removed those copies (D3), and `_swapInPrep`/`_swapOutPrep` share a six-assignment
    skeleton (D4). Reclaiming that buys room for this AND for the C3/C4 fixes, which also live here.
 3. **Do the PARTIAL FILL instead** — that is the actual defect; observability was only half. If the
    clamp replaces the all-or-nothing call it may be size-neutral. Still blocked on verifying
    `canRedeem(uint256)` on `0xDadEf1fF…7Ae0`.
⚠️ **NOTE THE COUPLING:** C3 and C4's fixes are BOTH in `SwapLib` (`:444`/`:455`/`:1013` and
  `:441-442`). With 141 bytes of headroom, **the size budget is now a shared constraint across three
  open fixes.** Sequence the shrink (option 2) BEFORE attempting them, or they will collide.

### D3 TESTED — the duplication is REQUIRED. `_priceOr` cannot be folded back in. (2026-07-31)

User asked whether the dedup tasks could free bytecode for C10. Tried the cheapest one first —
`_priceOr` is open-coded VERBATIM at `SwapLib.sol:441` and `:463`, and its own docblock claims it
replaced exactly those copies. **Folding both back into `_priceOr(v4p, address(aux), r.asset)` FAILS:**
```
Error: Compiler error (LValue.cpp:54): Stack too deep.  --> src/imports/SwapLib.sol:441:74
```
⇒ **The inlining is LOAD-BEARING**, precisely as its own comment says (*"inline (swapToBody
  stack-tight)"*). This repo sets `via_ir = false` deliberately, so `swapToBody` is at the stack limit
  and a function CALL there costs more stack slots than the inlined expression. REVERTED.
⇒ **This is a real answer, not a failed attempt:** D3 is now CONFIRMED load-bearing and should not be
  re-attempted. What IS wrong is `_priceOr`'s docblock (`:338`), which claims it removed inline copies
  that demonstrably must stay — fix the COMMENT, not the code.
⇒ It also means **the near-match dedup findings are not a bytecode bank.** Several will be load-bearing
  for the same reason. Each must be TESTED for size/stack effect, not assumed to free space.

### SO WHERE DOES C10's SPACE COME FROM? — revised, cheapest first
 1. 🥇 **Emit from the CALLER.** `SwapLib` is DELEGATECALL'd with 141 bytes free; `Aux` has **1,757**.
    Have the rung RETURN a status/selector and let the caller emit. Sidesteps the budget entirely and
    does not touch `swapToBody`'s stack.
 2. **D4** (`_swapInPrep`/`_swapOutPrep` share a six-assignment skeleton) — but they live in the SAME
    stack-tight region, so expect the same failure. Test before planning around it.
 3. Move a whole function OUT of `SwapLib` into a new lib — the only reliably large win, but it changes
    the delegatecall surface and needs its own verification.
⚠️ RESTATED, now with evidence: C3, C4 and C10 all need space in `SwapLib` (141 bytes). Option 1 is the
  only one shown to work so far, and it applies to all three.

## ✅ D3 DONE — "duplication is required" was WRONG. 197 BYTES FREED. (2026-07-31)

User: *"there is no such thing as duplication is required. if it's duplicated that means by definition
it's a drag. you can get around stack too deep elegantly."* **Correct on both counts. My previous entry
(§6745f59) is STRUCK.**

I had folded the two verbatim `_priceOr` copies into direct calls, hit `Stack too deep`, and recorded the
duplication as LOAD-BEARING. **That was accepting the compiler's complaint as a verdict instead of
restructuring around it.**

### WHAT ACTUALLY WORKED
The stack blew on a **NESTED CALL IN ARGUMENT POSITION** —
`sellSkew(c.core, _priceOr(...), isBTC, r.amount)`. Two changes removed it:
 1. Added `uint px;` to `SwapReq` — a **STRUCT FIELD, not a local**, so no new stack slot. Follows the
    existing precedent of `inToken`, already documented as *"set inside swapToBody"*.
 2. **Sequenced** the call instead of nesting it:
    `r.px = _priceOr(v4p, address(aux), r.asset);` then `sellSkew(c.core, r.px, …)`.
Caller updated (`Aux.sol:692`, one site, `px` seeded 0).

### RESULT — MEASURED
```
SwapLib runtime  24,435 → 24,238     margin  +141 → +338      197 BYTES FREED
Aux              22,841 / +1,735 (unchanged)          build: 0 errors
```
⇒ **338 bytes now available — MORE than the 206 that C10's observability fix needs.** C10 is unblocked
  WITHOUT moving the emit to the caller.
⇒ Also frees room for C3 and C4, which are both in `SwapLib` and were sharing the same 141-byte budget.

### THE LESSON — worth more than the bytes
**`Stack too deep` is a solvable code-shape problem, never a licence to duplicate.** Standard escapes:
put the value in an existing struct/memory object; SEQUENCE nested calls into statements; scope locals
in `{ }` blocks; split the function. **Duplication is always a drag — bytecode, and a correctness risk
when the copies drift** (exactly how §A.57/C5 produced FOUR sibling mint sites with one unscaled).
📌 CORRECT `_priceOr`'s docblock (`:338`) — it now genuinely IS the single definition, as it always
  claimed to be.
📌 AND RE-EXAMINE D4 (`_swapInPrep`/`_swapOutPrep`): I dismissed it as "same stack-tight region, expect
  the same failure". That reasoning is now discredited — TEST it with the same struct-field/sequencing
  technique.

### D4 PREMISE IS FALSE — there is no `_swapInPrep`. Re-scope before acting. (2026-07-31)

The dedup agent reported *"`SwapLib._swapInPrep` (~:722-756) vs `SwapLib._swapOutPrep` (~:1005-1029) —
mirrored pair, same 8-step skeleton"*. **Checked: only ONE such function exists.**
`grep -nE "function .*Prep\("` in `SwapLib.sol` returns exactly `:1006 function _swapOutPrep(...)`.
There is no `_swapInPrep` under that name.
⇒ The BODY the agent described at ~:722-756 is real (the `rp.sqrtPriceX96 / rp.zeroForOne / rp.token /
  rp.amount` assignment block IS there) — but it is INLINE or under a different name, so the claimed
  "mirrored pair of functions" does not exist as stated.
⇒ **RE-SCOPE D4 BEFORE ACTING:** identify what actually occupies ~:722-756, then judge whether it and
  `_swapOutPrep` share a skeleton worth extracting. The underlying observation may still hold; the
  framing does not.
📌 **METHOD NOTE — verify agent claims against the code, exactly as with my own.** This agent was
  otherwise excellent (its C4 trace was confirmed step-by-step and its `_valueStable`/`_illiquidLoss`
  finding is real), which is precisely why a wrong function name is dangerous: the surrounding accuracy
  lends it credibility. Every `file:line` in an agent report is a claim to check, not a fact to inherit.

# 🔴🔴🔴 THE 31 FAILURES ARE ENVIRONMENTAL. I REVERTED THREE CORRECT CHANGES. (2026-07-31)

**CLEAN TREE, no changes applied: 3,529 passed / 31 failed — IDENTICAL to C5's run, D3's run, and
C2+C5's run**, down to the same two signatures:
```
[FAIL: PREMISE: the CONTROL LP redeem must deliver …: 0 <= 0]   testLeverage_LvrControlVsTreatment
[FAIL: rung 3 paid native ETH via the real RedemptionManager: 0 <= 4900000000000000000]
```
⇒ **`ExceededRedeemable()` fires because ether.fi's LIVE redeemable pool was smaller than our ask.**
  That pool is MAINNET STATE on an UNPINNED fork — it differs run to run. The earlier "3,559 / 1"
  baseline was simply a run where their pool happened to be deep enough.

### WHAT THIS INVALIDATES — three correct changes were reverted on false evidence
| change | I concluded | TRUTH |
|---|---|---|
| **C5** (`Vogue.sol:658` `owed * 1e12`) | *"C5 ALONE causes all 31 failures"* | **CAUSED NOTHING.** Arithmetic was already verified correct |
| **D3** (`_priceOr` dedup, **197 bytes freed**) | *"broke 30 tests"* | **BROKE NOTHING.** Also freed the space C10/C3/C4 all need |
| **C2** (`from6` version) | reverted alongside C5 | **CAUSED NOTHING** — the C2+C5 run was also 31 |
⚠️ **ONE conclusion SURVIVES:** C1+C2 → **333** failures was REAL — a different magnitude entirely, and
  that C2 used `scaleTokenAmount(…, false)`, which genuinely divides 6-dec USDC by 1e12. The REWRITTEN
  C2 (`from6`) is fine. So the original C2 diagnosis stands and only its FIRST patch was wrong.

### ROOT CAUSE — §A.18 was right and I treated it as a nuisance
The queue already said: *"THE FORK IS NOT PINNED — the whole fork suite is NON-REPRODUCIBLE."* I read
that as flakiness to tolerate. **It is not: it silently corrupts ATTRIBUTION.** Every "X broke N tests"
conclusion compares two runs against DIFFERENT external chain state. `verify-from-the-same-run` is not
enough — **the runs must also be against the SAME CHAIN STATE.**
⇒ 🔴 **PIN THE FORK. This is now a BLOCKER, not a nice-to-have** — for every remaining fix, and
  absolutely for Echidna, which would fuzz against a moving baseline.

### AND IT RE-RATES C10 UPWARD
C10 is not a latent defect I induced with C5 — **it FIRES IN THE WILD, intermittently, right now.**
Whenever ether.fi's pool is momentarily thinner than the ask, rung 3 is skipped and the LP is pushed
onto the multi-day wait-NFT. Silently (bare `catch {}`). That is a live UX/capital-efficiency defect,
not a theoretical one.

### RESTORE (all three were correct)
 1. **D3** — re-apply; 197 bytes, and it unblocks C10/C3/C4's shared budget.
 2. **C5** — re-apply; `usd_owed` is 6-dec on every write and three siblings scale identically.
 3. **C2 (`from6`)** — re-apply; the helper is the missing 6-dec→native conversion.
 ⚠️ Do it AFTER pinning the fork, so the confirming run is actually reproducible.

## ✅ §A.18 ROOT CAUSE FIXED — `ForkPin`. Live state AND reproducible attribution, no trade-off.

User: *"there shouldnt be a compromise here. find a better fix."* Right — the trade-off was in my
framing, not the problem. **Pin the CURRENT block per comparison, not a historical one.**

NEW `test/utils/ForkPin.sol`; all **7** fork-creating contracts now inherit it and call `_forkMainnet()`
instead of `vm.createFork(vm.rpcUrl("mainnet"))` / `vm.createSelectFork(...)`. Build clean.
```solidity
uint pinned = vm.envOr("FORK_BLOCK", uint(0));
return pinned == 0 ? vm.createFork(vm.rpcUrl("mainnet"))
                   : vm.createFork(vm.rpcUrl("mainnet"), pinned);
```
  • **`FORK_BLOCK` UNSET (default, CI): LATEST block — behaviour UNCHANGED.** The suite still runs
    against live mainnet, so real drift and integration breakage are still caught, and expectations stay
    derived from live state (§A.22). Nothing is given up.
  • **`FORK_BLOCK` SET: every fork uses that block ⇒ N runs are byte-identical.**

### THE WORKFLOW THAT MAKES ATTRIBUTION SOUND — use it for every remaining fix
```sh
export FORK_BLOCK=$(cast block-number --rpc-url https://ethereum-rpc.publicnode.com)
forge test                 # baseline
<apply ONE change>
forge test                 # SAME chain state ⇒ any delta IS the change
```
The block is CURRENT at capture time, so this is live state — just held still long enough to measure
against. That is why there is no compromise.

### WHAT IT WOULD HAVE PREVENTED
C5, D3 and C2-via-`from6` were each blamed for 31 failures that a clean tree reproduced exactly. All
three were correct and were reverted on false evidence. With `FORK_BLOCK` set, the baseline and the
post-change run would have matched and the 31 would have been visible as pre-existing.
📌 **UPGRADE THE STANDING RULE:** `verify-from-the-same-run` is NOT sufficient for fork tests — the runs
must also be against the SAME CHAIN STATE. Set `FORK_BLOCK` before any attribution work.
📌 **AND IT IS AN ECHIDNA PREREQUISITE:** fuzzing against a moving baseline cannot distinguish a
  counterexample from chain drift.
⬜ STILL OPEN: C10's partial fill (the reason those 31 fire at all) — blocked on confirming ether.fi's
  capacity view; `cast` calls to `0xDadEf1fF…7Ae0` are currently failing at the RPC.

## 📌 PINNED BASELINE — block 25,653,624 → **3,529 passed / 31 failed**

First reproducible baseline of the session, via `ForkPin`. **Use this block for every attribution run
until the tree changes materially:**
```sh
FORK_BLOCK=25653624 FOUNDRY_ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test
```
The 31 are PRE-EXISTING and environmental in origin (ether.fi's redeemable pool at this block is thinner
than rung 3's ask — that is C10). **They are NOT caused by any pending change**, which is exactly the
fact that three wrongly-reverted fixes needed and nobody had.

### Tree state at this baseline
  • **C1** — applied, previously confirmed (it closed the `ZZBoldProbe` failure).
  • **D3** — restored: `_priceOr` deduped via a `SwapReq.px` struct field. `SwapLib` 24,238 / **+338**.
  • **C5** — restored: `Vogue.sol:658` `owed * 1e12`.
  • **C2** — restored with `BasketLib.from6` (6-dec → native). `BasketLib` 21,428 / +3,148. Build clean.
    **Measuring against the pinned baseline now** — the first genuinely attributable run today.

### Byte budget after D3 (all three remaining SwapLib fixes now fit)
`SwapLib` **+338** — C10's observability fix measured at **206**, so it fits; C3 (`:444`/`:455`/`:1013`)
and C4 (`:441-442`) also live here and were previously blocked behind the old 141.
⬜ C10's PARTIAL FILL still blocked on one external fact: does `EtherFiRedemptionManager`
  (`0xDadEf1fF…7Ae0`) expose a redeemable-capacity view? Three routes failed — `cast` (RPC errors),
  Etherscan (403 to WebFetch), GitHub code search (no index hit). **Get it from a reachable source
  before writing a clamp; do not guess an external ABI.**

## ✅ C2 CONFIRMED CLEAN — the first properly attributable run of the session

```
baseline  @25653624 : 3,529 passed / 31 failed
with C2   @25653624 : 3,529 passed / 31 failed     ⇒ ZERO delta
```
Same code path, same block, one variable. **C2 (`BasketLib.from6` at `Core.sol:989`) causes nothing**,
and the `from6` rewrite of the audit's wrong `scaleTokenAmount` patch is validated.

### MONEY-PATH STATUS — four fixes now in the tree, all verified or confirmed-clean
| fix | what it corrects | status |
|---|---|---|
| **C1** | `Aux.deposit` returns NATIVE, treated as 6-dec at 2 `SwapLib` sites | ✅ CONFIRMED — it CLOSED `ZZBoldProbe` (BOLD is 18-dec: the accidental first 18-dec test) |
| **C2** | `Core.sol:989` hands `AUX.take` 6-dec where NATIVE is required | ✅ CONFIRMED CLEAN at pinned block |
| **C5** | `Vogue.sol:658` missing `* 1e12` — 4th sibling, only one unscaled | ✅ restored; clean at pinned block |
| **D3** | `_priceOr` duplicated verbatim ×2 | ✅ restored; **197 bytes freed**, `SwapLib` +338 |

⚠️ **RE-VERIFY C1 AND C5 AT THE PINNED BLOCK.** Both were judged pre-`ForkPin`, so their evidence is
from unpinned runs. C1's confirmation is still strong (it flipped a SPECIFIC test from fail→pass, a
signal that survives baseline drift), but C5's "clean" rests on a comparison that is now known unsound.
Cheap: `FORK_BLOCK=25653624 forge test` with each toggled.

### THE 31 ARE C10, AND THEY FIRE IN THE WILD
At this block ether.fi's redeemable pool is thinner than rung 3's ask ⇒ `ExceededRedeemable()` ⇒ the
bare `catch {}` silently drops the LP onto rung 4's multi-day wait-NFT. **Not a test artifact — this is
production behaviour whenever their pool is thin.** Fixing C10 should take the suite to ~3,559/1.

## ✅ C10 PART 1 LANDED — the silent fallthrough is now observable

`SwapLib.sol` rung 3: bare `catch {}` → `catch (bytes memory err)` + `emit InstantRedeemSkipped(
weethRequested, reason)`. Verified at the pinned block: **3,529 / 31 — ZERO DELTA from baseline.**
Size: `SwapLib` 24,238 → **24,444 / +132** — it fits ONLY because D3 freed 197 bytes first.
`reason` carries the selector: `0xdc9cb0e2` = ether.fi's `ExceededRedeemable()`; `0x00000000` = no
reason given (empty returndata guarded by `err.length >= 4`).

⬜ **PART 2 — THE ACTUAL FIX — still owed:** request `min(weethIn, redeemable)` so the remainder falls
to rung 4 instead of losing the whole rung. Blocked on ONE external fact (capacity view on
`0xDadEf1fF…7Ae0`); three routes failed — `cast` (RPC), Etherscan (403), GitHub code search (no hit).

# ═══ ITEMS NOT IN THE A/B/C REGISTER — surfaced today, easy to lose ═══
| # | item | note |
|---|---|---|
| 1 | **`Σ levPooledBTC[lp] == VBtc.totalSupply()`** | UNASSERTED. Drift = double-spend. One line; Echidna-ready; PRECONDITION for §A.19b's aggregate rule |
| 2 | **Re-verify C1 and C5 at the pinned block** | both judged PRE-`ForkPin`. C1's evidence survives drift (it flipped a SPECIFIC test fail→pass); **C5's "clean" rests on a comparison now known unsound** |
| 3 | **C10 part 2** (partial fill) | above |
| 4 | **§A.19b: WHOSE depth shrinks on bearer redemption?** | the open DESIGN decision — pro rata / most-free-capacity / cheapest-payout. Nobody has chosen |
| 5 | **Re-scope D4** | the agent's "mirrored pair" does not exist — there is no `_swapInPrep`. The observation may survive; the framing does not |
| 6 | **`_priceOr` docblock** | after D3 it is now genuinely the single definition, as it always claimed. Correct the text |
| 7 | 🔴 **EVERY PRE-`ForkPin` ATTRIBUTION IS UNSOUND** | all "X broke N tests" verdicts before block 25,653,624, EXCEPT C1+C2's 333 (survives on magnitude + a named mechanism). ⚠️ This does NOT invalidate the FINDINGS — C3/C4/C6–C9 are code-read diagnoses with `file:line` — only the verdicts reached by comparing runs |

⇒ **Honest total ≈ 42 open items**, not 35. And the register's own caveat stands: **33 of 40
  open-marked items are still UNVERIFIED**, several probably already done.

### ✅ Item 5 — D4 IS DEAD. Confirmed: no `_swapInPrep` exists anywhere.
`awk 'NR>=700 && NR<=760 && /^\s*function /'` over `SwapLib.sol` returns **NOTHING** — there is no
function declaration in the range the agent cited (~722-756); that code is INSIDE a larger function.
Combined with `grep "function .*Prep("` returning only `_swapOutPrep:1006`, **the claimed "mirrored pair"
does not exist.** D4 STRUCK — do not re-scope, do not re-investigate. The `rp.*` assignment block the
agent saw is real but is not a separate function, so there is no pair to merge.
📌 Second agent claim today that did not survive checking (the first: `IAuxBtc_V` "still declared", which
  existed only in its own obituary). **Agent `file:line` citations are claims, not facts.**

### ✅ Item 6 — `_priceOr`'s docblock corrected
It claimed *"ONE shared body … not 5 inlined copies"* while TWO verbatim copies survived in `swapToBody`.
That claim is now TRUE (D3), and the docblock records WHY it was false and how it was fixed — struct
field + sequencing, 197 bytes — so the next reader does not re-add an "unavoidable" inline copy.

### ✅ Item 2 — C5 PROVEN NEUTRAL (and my earlier verdict definitively refuted)
```
with C5    @25653624 : 3,529 / 31
WITHOUT C5 @25653624 : 3,529 / 31     ⇒ C5 changes NOTHING
```
Toggled at the SAME block, so this is proof rather than inference. **My earlier "C5 ALONE causes all 31
failures" was wrong**, and C5 — the missing `* 1e12` at `Vogue.sol:658`, the fourth sibling mint and the
only unscaled one — is CORRECT and stays. Restored.
📌 C1 does NOT need the same re-run: its evidence was a SPECIFIC test flipping fail→pass
  (`ZZBoldProbe`, the accidental first 18-dec test), which is a signal that survives baseline drift in a
  way that aggregate counts do not. **Prefer per-test signals over suite totals when the baseline moves.**

### 7-ITEM SWEEP — 4 of 7 done
  ✅ 2 C5 re-verified (neutral) · ✅ 5 D4 struck (no `_swapInPrep` exists) · ✅ 6 `_priceOr` docblock
     corrected · ✅ 7 recorded (pre-`ForkPin` attributions unsound; findings survive, verdicts do not)
  ⬜ 1 `Σ levPooledBTC == VBtc.totalSupply()` — needs a test written
  ⬜ 3 C10 part 2 — blocked on ether.fi's capacity view
  ⬜ 4 §A.19b whose-depth-shrinks — a DESIGN decision, needs the user

### ✅ Item 1 — `Σ levPooledBTC == VBtc.totalSupply()` IS NOW ASSERTED (the invariant you asked me to bank)

Added `_assertVBtcSupplyMatchesLevMarker()` and called it from the SHARED `_openLev` helper in
`test/VBtcLevFeeLane.t.sol`, so **no test can exercise BTC leverage without checking it.** `levPooledBTC`
is a mapping with no running total, so `_openLev` now records each LP into `_levLps` (dedup'd via
`_levLpSeen`) and the assertion sums that set.

RESULT: **124 passed / 1 failed** — the single failure is the pre-existing ether.fi rung (C10), and the
invariant held on every leverage path in the file.

WHY IT MATTERS (recorded at the assertion): `exposeBtcToLev` writes the same sats into THREE places —
`LP.pooled` (UNCHANGED, single-count), `levPooledBTC[lp]` (a SUBSET marker, so free = `pooled −
levPooled`), and `VBtc.balanceOf[manager]` (the token). Three views of ONE claim, correct by design, but
three INDEPENDENTLY-MUTATED locations with nothing keeping them in lockstep. **If the marker and the
supply diverge, the divergence IS a double-spend** — depth counted as free while its token is still
outstanding. Nothing asserted this anywhere before.
⇒ It is also the PRECONDITION for §A.19b: `Σ outstanding vBTC <= Σ free channel capacity` is meaningless
  unless supply and marker agree first.
⇒ And it is Echidna target #5 — a one-line property over state the fuzzer already reaches.

### 7-ITEM SWEEP — 5 of 7 done
  ✅ 1 invariant asserted · ✅ 2 C5 proven neutral · ✅ 5 D4 struck · ✅ 6 docblock corrected ·
  ✅ 7 recorded
  ⬜ 3 C10 part 2 — blocked on ether.fi's capacity view (external fact, 3 routes failed)
  ⬜ 4 §A.19b whose-depth-shrinks — a DESIGN decision, needs the user's call

## ✅ C10 PART 2 UNBLOCKED — the capacity view EXISTS. Found in source, not guessed.

Source: `etherfi-protocol/smart-contracts` → `src/withdrawals/EtherFiRedemptionManager.sol`
(found via the GitHub contents API after Etherscan 403'd and `cast interface` had no API key).

### THE API — **both take a `token` PARAMETER**, which is why every probe failed
```solidity
function totalRedeemableAmount(address token)          external view returns (uint256);
function canRedeem(uint256 amount, address token)      public  view returns (bool);
function getInstantLiquidityAmount(address token)      public  view returns (uint256);
function lowWatermarkInETH(address token)              public  view returns (uint256);
function previewRedeem(uint256 shares, address token)  public  view returns (uint256);
```
📌 **MY PROBES WERE WRONG-ARITY, NOT ABSENT-FUNCTION.** I called `canRedeem(uint256)` and
`totalRedeemableAmount()` and got `execution reverted, data: "0x"` — which I read as "does not exist".
It means "wrong selector". ⚠️ **A bare revert with empty data does NOT distinguish "no such function"
from "wrong signature".** Same trap family as the empty grep.

### THE REVERT CONDITION — verbatim
```solidity
if (!canRedeem(eEthAmount, outputToken)) revert ExceededRedeemable();
```
in BOTH `_redeemEEth` and `_redeemWeEth`. `canRedeem` is false when: liquid < low watermark, OR amount >
(liquid − watermark), OR the RATE-LIMIT BUCKET cannot consume it. ⇒ capacity is **time-varying** (a
leaky bucket), not just a pool balance — so a clamp must be read fresh at call time, never cached.

### 🔑 THE UNIT TRAP — clamping `weethIn` DIRECTLY WOULD BE WRONG
The check is on **`eEthAmount`**, but we pass **`weEthAmount`**. weETH is the WRAPPED, appreciating
share; eETH is the rebasing unit. So the fix must:
 1. convert our `weethIn` → eETH (`getEETHByWeETH`, already used elsewhere in this repo),
 2. clamp THAT against `totalRedeemableAmount(ETHFI_NATIVE_ETH)`,
 3. convert the clamped eETH back → weETH for the `redeemWeEth` call,
 4. let the remainder fall through to rung 4.
⚠️ Getting this wrong is a 1:1-vs-rate confusion of exactly the §A.50 family. Do it deliberately.

### SIZE
`SwapLib` is at **24,444 / +132** after C10 part 1. The clamp adds a view call + two conversions + a
`min` — likely MORE than 132. **Expect to need another dedup first** (D3's technique freed 197 once
already), or to compute the clamp in the CALLER where `Aux` has ~1,735 bytes free.

## 📌 STANDING DEDUP INSTRUCTIONS EXISTED AND I WAS WORKING WITHOUT THEM (user, 2026-07-31)

User: *"there were specific contextual instructions about it on one of the markdown documents?"* **Yes —
`BUILD-QUEUE-AND-107.md:44-48` and `:819`. I never read them; they are not in `QUEUE.md`. Now they are.**

### RULE 1 — ONE DECLARATION PER INTERFACE, IN A SHARED FILE (user, 2026-07-26)
With a concrete warning: *"the 5 `IAaveV4Spoke` declarations have already DRIFTED into disjoint subsets
of one ABI"* — `Vault:44` {supply, withdraw, getReserveId} vs `VaultLib:11` {…}.
✅ **VERIFIED FIXED (today):** exactly ONE declaration remains, in `imports/Interfaces.sol:23`, carrying
the UNION — supply · withdraw · getReserveId · getUserSuppliedAssets · getUserSuppliedShares ·
getReserveSuppliedAssets · getReserveTotalDebt. The five disjoint copies are gone.
📌 **This is the canonical case for §A.52:** the danger of duplicated interfaces is not bytecode, it is
  SILENT DRIFT INTO DISJOINT SUBSETS — each call site compiles against a different partial view of the
  same contract. Use it as the worked example when doing the remaining 95.

### RULE 2 🔴 — "DO NOT JUMP TO CONCLUSIONS; CHALLENGE YOURSELF UNTIL THE SOLUTION IS ELEGANT"
*"applies to EVERY task."* The bar for "done deciding": the approach either **(a) REUSES an existing
primitive/signal**, or **(b) DELETES a big chunk while giving better guarantees**.
**"Enumerate ≥2 approaches explicitly before writing code for anything non-obvious, and write down why
the loser lost. A single plausible design is a sign [of insufficient thought]."**
⚠️ **I HAVE BEEN VIOLATING THIS ALL SESSION.** Every fix today was a single plausible design written
straight to code — C2's first patch (wrong helper, 333 failures), C10's observability (didn't measure
size until challenged), D3 (recorded "duplication is required" after ONE failed attempt). **The two
times I was forced to enumerate alternatives — by the user — both produced strictly better answers**
(`ForkPin` instead of pin-vs-live; struct-field+sequencing instead of "unavoidable duplication").

### RULE 3 — §A.56 part 2 WAS ALREADY DIAGNOSED, at `:819`
*"`Core.outOfRange(bool isBTC, …)` is ALREADY fused (Action enum ETH vs BTC). The DUPLICATION is one
level up: `Vogue._outOfRange` …"* — **I re-derived this from scratch today and reported it as a
finding.** Cost: one 90-minute agent that died on it.
⇒ **BEFORE investigating anything, grep the ARCHIVE for it.** 5,100 lines of prior analysis are sitting
  there, and `QUEUE.md`'s consolidation deliberately dropped the DETAIL, which is exactly what was
  needed here.

## C3 APPLIED — `volScale` DELETED. First fix done under the "≥2 approaches" standing rule.

### THE ENUMERATION (rule 2: *"write down why the loser lost"*)
| # | approach | verdict |
|---|---|---|
| A | Fix the arithmetic, KEEP the `volScale` parameter | ❌ leaves a parameter whose ONLY correct value is `1e18` — an invitation to reintroduce the same bug |
| B | Correct at the two `SwapLib` call sites instead | ❌ `convert` stays wrong for any future caller, and the defect is INSIDE it, not at the callers |
| C | **DELETE `volScale` entirely** | ✅ **the parameter WAS the bug** — satisfies the rule's bar (b): deletes a chunk AND gives a better guarantee |

### THE INSIGHT THAT MADE (C) POSSIBLE
`getTWAPforAsset` ALREADY lifts the WBTC anchor ×1e10 to close the 8↔18-dec gap (`SwapLib.twapResolve`;
authoritative note at `SwapLib:951-955`). So passing `volScale = 1e8` for BTC **DOUBLE-COUNTED that
correction**:
```
old !toVol, BTC:  mulDiv(sats, px, 1e8) / 1e12  = sats·px / 1e20     ← 1e10 TOO LARGE
authoritative:                                    sats·px / 1e30
old !toVol, ETH:  mulDiv(wei,  px, 1e18)/ 1e12  = wei·px  / 1e30     ← already CORRECT
```
⇒ **Only BTC was ever wrong, and deleting the parameter fixes BTC while leaving ETH BYTE-IDENTICAL.**
Now matches `SwapLib`'s authoritative `mulDiv(poolVol, base, 1e30)` exactly (1e18 · 1e12).

### WHAT TO WATCH IN THE VERIFY RUN
The BTC inventory cap `min(p.amount, convert(...))` was 1e10 too large ⇒ it **could never bind**.
With C3 it CAN, so on BTC paths: partial fills become possible, and `refundUnfilled` / `_refundExcess`
— previously **DEAD CODE on every BTC path** — become REACHABLE for the first time.
⚠️ The audit warned that fixing C3 while `amount` (native) and `consumed` (6-dec) were on different
bases would ARM a latent `Core.refundUnfilled` mismatch. **That ordering constraint is satisfied**: C1
and C2 are both in and confirmed, so the two are on the same basis now. This is why C3 had to come last
of the three.
> ⚠️ **STALE AS WRITTEN (corrected 2026-08-02):** C2 was later **REVERTED** (§A.72) — the audit's patch
> was wrong. The ordering argument still holds because **C1 alone** puts `amount` and `consumed` on the
> same basis; C2 was never the load-bearing half. See the C-table at the top, which is authoritative.
> ⚠️ And the `_refundExcess` watch-item below was NEVER verified — it is now tracked as **C1r**.

## 🔴 C3 REVERTED — 91 vs 31 at the pinned block. My direction analysis was WRONG.

`FORK_BLOCK=25653624`: **3,469 passed / 91 failed** vs a 3,529/31 baseline ⇒ **C3 caused 60 failures.**
Attribution is SOUND this time (same block), unlike the earlier environmental confusion. Reverted.

### THE DIAGNOSTIC FAILURE — it says the opposite of what I predicted
```
[FAIL: consumed < sats on an inventory-bounded partial (the signal to refund): 171059972 >= 171059972]
```
A test that EXPECTS a partial fill now sees `consumed == sats`. **I predicted the cap would START
binding; instead it stopped.** So the cap got BIGGER, not smaller — my sign analysis was wrong for the
branch this test exercises.

### WHY — I fixed BOTH directions, and they were wrong in OPPOSITE directions
The audit said `toVol` is **1e10 UNDER** and `!toVol` is **1e10 OVER**. My edit replaced `volScale` with
`1e18` in BOTH:
```
!toVol BTC:  sats·px/1e20  →  sats·px/1e30      (÷1e10 — cap SHRINKS, binds more)
 toVol BTC:  amt·1e12·1e8/px → amt·1e12·1e18/px (×1e10 — cap GROWS,  binds LESS)  ← this test
```
⇒ The failing test rides the **`toVol`** branch, where the correction makes the cap 1e10 LARGER, so a
  partial that used to occur no longer does.

### 🔑 THE REAL QUESTION, AND IT IS NOT "WHICH ARITHMETIC IS RIGHT"
That test asserts a partial fill **that may only ever have happened BECAUSE of the under-scaled cap.**
Two readings, and they need different fixes:
 (a) The corrected `toVol` cap is right, and the test was calibrated against the bug — same class as the
     tolerances tuned around a ~zero fee (§A.46) and the θ clamp deleted for "adding no safety" (C4).
     Then the TEST must change, not the code.
 (b) `toVol` was already correct (the ×1e10 WBTC price-lift may be applied on only ONE side of the
     conversion), and only `!toVol` needed fixing. Then the fix is HALF of what I applied.
⚠️ **DO NOT re-apply C3 until this is settled.** Work it out from the price-lift: `getTWAPforAsset(WBTC)`
  returns `usd_per_btc · 1e28` (verified earlier: `6e32` at \$60k). Derive BOTH directions from that
  ONE fact and see which of the two branches the ×1e10 lift already cancels. **60 failing tests is the
  system telling us the model is wrong — not noise to tune away.**
📌 METHOD: this is the FIRST attributable regression of the session (pinned block), and it worked exactly
  as intended — the number is trustworthy and the failure message is diagnostic. `ForkPin` is earning
  its keep.

## 🔑 C3 DERIVED FROM FIRST PRINCIPLES — MY ARITHMETIC WAS RIGHT. THE TESTS ARE CALIBRATED TO THE BUG.

Done properly this time: derive BOTH directions from the ONE verified fact, instead of reasoning about
the code and guessing signs.

### THE FACT (measured earlier, both paths agree)
`getTWAPforAsset(WBTC)` = `usd_per_btc · 1e28` (`6e32` at \$60k). `getTWAPforAsset(WETH)` =
`usd_per_eth · 1e18` (`3e21` at \$3k). ⇒ **WBTC's price carries a ×1e10 LIFT** over WETH's WAD form.

### THE DERIVATION — pure unit algebra
```
!toVol (vol → USD6):
  BTC:  sats/1e8  · (price/1e28) · 1e6  =  sats · price / 1e30
  ETH:  wei /1e18 · (price/1e18) · 1e6  =  wei  · price / 1e30
 toVol (USD6 → vol):
  BTC:  usd6/1e6 ÷ (price/1e28) · 1e8   =  usd6 · 1e30 / price
  ETH:  usd6/1e6 ÷ (price/1e18) · 1e18  =  usd6 · 1e30 / price
```
⇒ **BOTH directions are ASSET-INDEPENDENT: `1e30` either way.** The ×1e10 lift exactly cancels the
  1e10 sats-vs-wei gap — which is WHY the lift exists. `volScale` was never needed.

### VERDICT — reading (a), not (b)
```
toVol  = mulDiv(amount * 1e12, 1e18, price)   ⇔ amount · 1e30 / price   ✅ what I wrote
!toVol = mulDiv(amount, price, 1e18) / 1e12   ⇔ amount · price / 1e30   ✅ what I wrote
```
**The reverted C3 was ARITHMETICALLY CORRECT in both branches.** The old code was right for ETH
(`volScale == 1e18` IS the identity) and wrong for BTC in BOTH directions — over on `!toVol`, under on
`toVol`. Exactly as the audit said, and my patch fixed both.

⇒ **THEREFORE THE 60 FAILURES ARE TESTS CALIBRATED AGAINST THE BUG.** The BTC `toVol` cap was 1e10 TOO
  SMALL, so BTC swaps were partial-filling ARTIFICIALLY. Tests then asserted those partials as expected
  behaviour — e.g. *"consumed < sats on an inventory-bounded partial (the signal to refund)"*. With the
  cap correct, the partial does not occur and the assertion fails. **The tests encode the defect.**
📌 Same class as: tolerances tuned around a ~zero fee (§A.46), the θ clamp deleted for "adding no
  safety" (C4), and `testRedeem`'s immature no-op. **A check calibrated while the system is broken will
  reject the system once it is fixed.** Fourth instance this session.

### HOW TO LAND C3 (do NOT just re-apply)
 1. Re-apply the `volScale` deletion — the arithmetic is now DERIVED, not guessed.
 2. Triage the ~60 failures **individually**: for each, does it assert a partial fill / refund path that
    can ONLY occur under an under-scaled cap? If yes the TEST is wrong and must be re-derived from the
    corrected cap. If any failure is NOT of that shape, the derivation is incomplete — STOP and re-check.
 3. ⚠️ `refundUnfilled` / `_refundExcess` were DEAD CODE on BTC paths. Post-C3 they are reachable, so
    some failures may be those paths executing for the FIRST TIME — genuinely new behaviour needing real
    verification, not test edits.

## 🛑 C3 HALTED BY ITS OWN STOP CONDITION — a SECOND mechanism exists. Reverted.

Re-applied the DERIVED C3 and triaged. The 60× counts are inheritance amplification; there are exactly
**TWO distinct new failures** (plus the two pre-existing, C10's rung-3 and F1):
 1. `consumed < sats on an inventory-bounded partial` — **FITS** the one mechanism. `Alles.t.sol:1936`
    builds `hugeSats = 10× capacity` from `POOLED_USD_BTC`, so it is calibrated to the cap; correcting
    the cap changes where the bound lands. Test expectation would need re-deriving.
 2. `testStrand4_SwapInFloor_RevertsShort_UnwindsUsed` — **DOES NOT FIT.** 🛑
    ```solidity
    ch.settleSwapIn(seller, sats, address(USDC), hash, type(uint).max, false);  // floor = MAX
    vm.expectRevert(abi.encodeWithSignature("SwapInShort()"));
    ```
    **The floor is `type(uint).max` — UNCONDITIONALLY unreachable, whatever the cap arithmetic does.**
    `SwapInShort()` must fire regardless. Under C3 the call **does not revert at all**.

⇒ **That cannot be "the test was calibrated against the bug".** A max-uint floor is not a calibrated
  number. So C3 changes something OTHER than the cap magnitude — most likely the call now takes a
  DIFFERENT PATH and never reaches the floor check (e.g. an early return when `consumed`/`pooled`
  computes to 0, or a branch keyed on the converted value). **A second mechanism ⇒ the derivation is
  INCOMPLETE.**
🛑 **HALTED AND REVERTED per the pre-committed stop condition.** Editing test 1 while test 2 is
  unexplained is exactly the loop the user warned about: the code would end up wrong and the tests would
  encode it.

### NEXT — settle the SECOND mechanism first, then C3 lands in one go
Run `testStrand4_SwapInFloor_RevertsShort_UnwindsUsed` with `-vvvv` under C3 and find WHERE the floor
check is skipped. Specifically: does `convert`'s corrected `toVol` value make `consumed` (or a
downstream branch) take a path that returns BEFORE `SwapInShort` is evaluated? That is a REAL behavioural
change from C3 and may itself be a defect worth having found — the floor check being SKIPPABLE at all is
suspicious.
📌 The unit derivation stands (both directions are `1e30`, asset-independent). What is NOT established is
  that changing the cap has no OTHER side effects. Those are different claims and I conflated them.

## C3 TRACE — the test CONFIRMS C3's arithmetic. One branch still unexplained.
Traced the floor check statically (no suite run needed).
`SwapLib:798` — `if (deliveredUsd < minDeliveredUsd) revert SwapInShort();` is UNCONDITIONAL. With
`minDeliveredUsd = type(uint).max` the comparison is always true, so **the revert MUST fire if the line
is reached.** "did not revert" therefore means `_swapInSettle` was NEVER ENTERED, or its revert was caught.

### 🔑 The finding that INVERTS my earlier assumption
`Alles.t.sol:2128` computes the test's input as:
```solidity
uint sats = ((CORE.POOLED_USD_BTC() * 1e12) / 4 * 1e18) / price;   // == amount6 * 1e12 * 1e18 / price
```
**That is EXACTLY C3's CORRECTED `convert(..., toVol=true)`** — a hand-inlined copy. The test author
independently derived the same arithmetic C3 derives from units. ⇒ **The fixture is calibrated against the
FIXED formula, not the broken one.** My "the tests were calibrated against the bug" reading was BACKWARDS.
⇒ This is INDEPENDENT third-party confirmation that **C3's derivation is correct** — the strongest evidence
  yet, because it predates and is unaware of C3.
⇒ It also explains failure #1 exactly: pre-C3 production and test disagreed by 1e10, so `sats` hugely
  overshot the under-scaled cap and the swap ALWAYS partial-filled. C3 removes the overshoot.

### ⛔ STILL UNEXPLAINED — do this next
Why a max-uint floor does not revert. Only two possibilities, both cheap to check:
 1. `creditSwapInBody`'s `if (sats == 0) return 0;` (SwapLib:~722) early-returns past the floor check.
    Hand-computed `sats` ≈ POOLED_USD_BTC·100/usd_per_btc ≈ 1.25e6 — **NOT zero**, so this looks ruled out,
    but confirm with an actual value rather than my arithmetic.
 2. **`BTCChannels.settleSwapIn` CATCHES the revert** (try/catch) — the test's own comment says the floor
    revert "unwinds the swapInUsed mark", implying deliberate unwind machinery that could swallow it.
    ⭐ This is the likely one. READ `settleSwapIn` for a try/catch around the credit call.
📌 If it IS a catch: a floor breach being SWALLOWED rather than propagated is a REAL DEFECT independent of
  C3 — the seller's minimum-out guarantee would be unenforceable. C3 merely made it observable.
🛑 C3 stays REVERTED until this is settled. Do NOT re-derive fixture #1 first — #1 is already explained and
  needs no edit; the ONLY open question is this branch.

## C3 — hypothesis 2 DEAD; the failing revert is a DIFFERENT, calibrated one. C3 likely CORRECT.
**`BTCChannels.settleSwapIn` (BTCChannels:1085-1137) has NO try/catch** — it calls `btcVault.creditSwapIn`
directly and lets reverts propagate. Hypothesis 2 (swallowed floor breach) is REFUTED. No hidden defect there.

### 🔑 The real error: I attributed the failure to the WRONG expectRevert
`testStrand4` contains **TWO** `vm.expectRevert`s, and forge's "next call did not revert as expected" does
NOT say which. I assumed part (1). The other is part (3) at `Alles.t.sol:2151-2155`:
```solidity
uint bigSats = ((CORE.POOLED_USD_BTC() * 1e12 * 4) * 1e18) / price; // "4x the remaining reserve => partial"
vm.expectRevert(abi.encodeWithSignature("SwapInPartialRejected()"));
ch.settleSwapIn(seller, bigSats, address(USDC), hash2, 0, true);   // requireFull=true
```
⇒ Part (1)'s floor is `type(uint).max` — NOT calibrated, cannot be moved by C3.
⇒ Part (3)'s `bigSats` IS calibrated ("4× the remaining reserve"), and part (2) SPENDS reserve first, so the
  margin depends on exactly how much part (2) consumed — which C3 changes. **This is the same single
  mechanism as failure #1, not a second one.**
⇒ **The stop condition was tripped by MY MISATTRIBUTION, not by a real second mechanism.** With hypothesis 2
  refuted and part (3) identified as calibrated, C3's "one mechanism" story is INTACT.

### ▶️ NEXT — one cheap run settles it (do NOT re-run the whole suite)
Re-apply C3, then attribute the revert precisely:
```
FORK_BLOCK=25653624 forge test --match-test testStrand4_SwapInFloor_RevertsShort_UnwindsUsed -vvv
```
Read the trace for WHICH call didn't revert. If it is part (3) (expected), re-derive `bigSats` and
`hugeSats` (`:1936`) against the corrected cap and land C3. If it is part (1) — the max-uint floor — then a
genuine second mechanism DOES exist and the halt stands.
📌 LESSON: forge's "did not revert as expected" names no line. In a test with multiple `expectRevert`s,
  ATTRIBUTE THE FAILURE BEFORE THEORISING — I built two hypotheses on an unverified assumption about which
  call failed, and one of them (a swallowed floor breach) was alarming and wrong.

## ✅ C3 ATTRIBUTION CONFIRMED BY TRACE — single mechanism. But a NEW question the fixture edit would hide.
`FORK_BLOCK=25653624 forge test --match-test testStrand4... -vvv` (one test, 2.35s):
 • line 2659 `← [Revert] SwapInShort()` — **part (1) DOES revert correctly.** The max-uint floor is fine.
 • line 3354 `← [Revert] next call did not revert as expected` — AFTER it ⇒ **the failure is PART (3)**, the
   calibrated `bigSats` / `SwapInPartialRejected` case, exactly as predicted.
⇒ **No second mechanism. No swallowed revert. My earlier halt was on a misattribution; C3's story is intact.**

### ⚠️ DO NOT just re-derive `bigSats` — first answer WHY it now fully fills
`bigSats` is "4× the remaining reserve". Under C3 it NO LONGER partial-fills, i.e. the pool converted an
input 4× its own stated reserve **in full**. Two readings, and they are NOT equivalent:
 (a) BENIGN — the test's notion of "remaining reserve" (`POOLED_USD_BTC` after part (2)) was itself computed
     with the OLD 1e10-off conversion, so "4×" was never really 4×. Re-deriving the fixture is then correct.
 (b) **DEFECT — C3's cap is now 1e10 too LARGE and the swap-in can draw BEYOND POOLED_USD_BTC.** That is a
     drain: swap-in delivers USD the reservoir does not have. The `SwapInDrainsProceeds` gate only compares
     `POOLED_USD_BTC < pendingSwapOutUsd`; it does NOT bound a single fill to the reserve.
🛑 **Editing the fixture to green would HIDE (b) completely.** Settle it by asserting the pool's USD
  reserve is not overdrawn across the part-(3) call, NOT by adjusting `bigSats` until the revert returns.
▶️ Next: instrument part (3) — read `POOLED_USD_BTC` before/after and assert delivery ≤ reserve. If delivery
  exceeds it, C3 has overshot and the correct scale is between the two, not at either end.
📌 C3 REVERTED again pending (a)-vs-(b). The unit derivation and the `:2128` independent confirmation both
  still stand — what is NOT established is that the corrected cap is still BOUNDED BY the reserve.

## ✅ OVERDRAW SETTLED — reading (b) REFUTED structurally. C3 is CORRECT; fixture re-derivation legitimate.
`BasketLib:437` — the cap is a `Math.min` against the reserve:
```solidity
consumed = Math.min(p.amount, convert(p.pooled, p.v4Price, p.token != address(0), ctx.volScale));
```
⇒ `consumed` can NEVER exceed `convert(p.pooled, ...)`, i.e. the reservoir expressed in asset units.
  **A swap-in cannot draw beyond POOLED_USD_BTC whatever scale `convert` uses.** Reading (b) — C3 enabling
  a drain — is **REFUTED BY STRUCTURE**, not by a test. No delivery-vs-reserve assertion is needed.
  (The concern was still worth raising: it was refuted by reading the bound, not assumed away.)

### The arithmetic, which independently re-confirms C3
`convert`'s doc says `volScale = 10**decimals(asset)` — 1e18 WETH, **1e8 WBTC**. But the WBTC price carries
the ×1e10 lift (`usd·1e28`, vs WETH's `usd·1e18`):
 • OLD BTC cap = `pooled·1e12·1e8 / (usd·1e28)` = `pooled / (usd·1e8)` → at pooled=3000e6, usd=60000 this is
   **0.0005 ⇒ TRUNCATES TO 0.** The BTC swap-in cap was effectively ZERO — every BTC swap-in partial-filled.
 • NEW (C3) = `pooled·1e12·1e18 / (usd·1e28)` = `pooled·100/usd` = **5e6 sats = 0.05 BTC** ✓ — exactly the
   value `Alles.t.sol:2128` derives by hand.
 • WETH is UNCHANGED (`volScale` was already 1e18): `pooled·1e12/usd` ✓.
⇒ **`volScale` was DOUBLE-COUNTING the decimals gap that the WBTC price lift already cancels.** The constant
  is asset-independent 1e18 because the lift is baked into `price`. This is the root cause, stated in units.
⇒ ⚠️ **`volScale` is now DEAD in `convert` — remove the parameter** (4th arg) and update call sites, per the
  no-unreachable-code rule. Check whether `ctx.volScale` has other consumers before deleting the field.

### ▶️ TO LAND C3 (all blockers cleared)
 1. Apply C3 (`volScale` → `1e18`, both directions) and drop the now-dead 4th parameter.
 2. Re-derive the two calibrated fixtures — `hugeSats` (`Alles.t.sol:1936`) and `bigSats` (`:2151`) — against
    the corrected cap. **This is now legitimate, not masking:** the derivation is independent of the tests,
    `:2128` confirms it, and the drain reading is refuted.
 3. Full suite at `FORK_BLOCK=25653624`; expect 3529/31 ± the two re-derived fixtures.

## ❗CORRECTION — my "refuted by structure" was WRONG. Reading (b) IS REAL. C3 as formulated is a DOUBLE-FIX.
`SwapLib:752-754` (swap-IN path, `creditSwapInBody`):
> "POOLED_USD_BTC **pre-scaled ×1e10**: convert(toVol) under-scales the 8-dec WBTC cap by 1e18/1e8,
>  ×1e10 cancels it → the true sats-equivalent of the USD reserve to pay out. (BTC-local; ETH untouched.)"
⇒ **The swap-in path ALREADY COMPENSATES for the volScale bug at the call site.** On THIS path the old code
  was CORRECT. Applying C3 (volScale→1e18) on top ⇒ pre-scale ×1e10 AND corrected scale ⇒ **cap 1e10 TOO
  LARGE.** That is precisely why `bigSats` = "4× the reserve" fully filled: the cap really was inflated.
⇒ 🔴 **MY REFUTATION OF (b) WAS INVALID.** I verified `consumed ≤ convert(p.pooled, ...)` and concluded the
  reserve bounds the fill — but never checked whether **`p.pooled` IS the true reserve. It is NOT** (pre-scaled
  ×1e10). A `Math.min` against an INFLATED bound bounds nothing. **The overdraw reading (b) stands.**
📌 LESSON (third time this pattern): I keep verifying the LOCAL form of an expression and declaring the
  question closed without checking what the INPUTS mean. Same error as the `scaleTo6` C2 patch and the
  cap-vs-side-effects conflation. **A bound is only as sound as the units of the value fed into it.**

### The ACTUAL fix — C3 must be paired, not applied alone
`SwapLib:950-954` states the authoritative rule: *"the WBTC ×1e10 price-lift already closes the 8↔18-dec gap,
so a flat /1e30 is correct for BOTH pools"* — i.e. `volScale` is genuinely wrong IN GENERAL, but the swap-in
call site hides it with a second wrong thing. Two wrongs that cancel ⇒ **remove BOTH, together:**
 1. `convert`: drop the `volScale` param, use a flat `1e18` (asset-independent — the price lift closes the gap).
 2. `SwapLib` swap-IN: **DELETE the compensating ×1e10 pre-scale of POOLED_USD_BTC** (and its comment).
 ⇒ Net effect on the swap-in path: **ZERO** (both cancellations removed) — so `hugeSats`/`bigSats` should
   need NO re-derivation, and their unchanged passing becomes the PROOF the pairing is unit-neutral.
 ⇒ Any OTHER `convert` caller lacking the pre-scale is fixed by step 1. Audit every call site for its own
   private compensation before landing — there may be more paired hacks like this one.
🛑 **Do NOT re-derive the fixtures.** Under the paired fix they are correct as written; if they still fail,
  the pairing is wrong. They are now the ORACLE, not the thing to adjust. (Had I "landed C3 + re-derived the
  fixtures" as planned one step ago, I would have shipped a 1e10-inflated BTC swap-in cap AND rewritten the
  two tests that were correctly detecting it.)

## ✅✅ C3 LANDED — paired fix, 3529/31 = EXACT baseline, ZERO fixtures touched.
**Applied together (two wrongs that cancelled on one path):**
 1. `BasketLib.convert` — dropped the `volScale` param; flat **1e18** for BOTH assets. The WBTC price
    carries a ×1e10 lift (`usd·1e28` vs WETH's `usd·1e18`) that ALREADY closes the 8↔18-dec gap, so a
    per-asset `10**decimals` scale double-counted it. Same rule `SwapLib:950-954` already stated for
    `poolVolUsd` (flat `/1e30`) — so this makes the two agree instead of contradicting.
 2. `SwapLib:761` — deleted the compensating `POOLED_USD_BTC() * 1e10` pre-scale; the reserve is passed RAW.

**RESULT: 3529 passed / 31 failed — IDENTICAL to baseline.** Only 2 distinct failures remain, both
PRE-EXISTING and unrelated: `testEthVenue_EtherFi_InstantRedeem_Rung3` (C10's open rung) and
`testLeverage_LvrControlVsTreatment` (F1). The 31 is inheritance amplification of those two.
⇒ **`hugeSats` (`:1936`) and `bigSats` (`:2151`) pass UNCHANGED.** They were the ORACLE, and they confirm
  the pairing is unit-neutral on the swap-in path — the prediction made before the run, and it held.
⇒ **NO test was edited to reach green.** The two failures that triggered the whole investigation resolved
  by fixing the CODE.

### Why this mattered — the near-miss
Landing C3 ALONE (as planned twice) would have shipped a **1e10-inflated BTC swap-in cap** — a real overdraw,
since `Math.min` was taken against a pre-inflated `p.pooled` — AND rewritten the two tests that were correctly
detecting it. The saving catch was reading the CALL SITE's units, not the expression's local form.
📌 STANDING LESSON: **a bound is only as sound as the units of the value fed into it.** Three times this
  session I verified an expression's local form and declared a question closed without checking its inputs
  (the `scaleTo6` C2 patch; cap-vs-side-effects; this `Math.min`). Check the call site, every time.

### Remaining cleanup (small, non-blocking)
`ctx.volScale` (`Types.sol:106`) and its two assignments (`SwapLib:750`, `:1036`) are now DEAD — `convert`
was their only consumer. Remove the field + both assignments per the no-unreachable-code rule, rebuild,
re-run. Low risk, but it is a separate change from the money-path fix above.

## ✅ C3 CLEANUP DONE — `volScale` fully removed, +86 bytes of EIP-170 headroom.
Removed the now-dead `ctx.volScale`: the `Types.AuxContext` field (`Types.sol:106`), its struct-literal
initialiser (`SwapLib:405`) and both assignments (`SwapLib:750`, `:1037`). Verified by grep that NOTHING
READ it — `convert` was its only consumer — before deleting. Also corrected 4 comments that documented the
deleted per-asset scale (`:402`, `:712`, `:743`, `:953`) so no stale comment survives to mislead later
(the `stale-comments-are-false-evidence` rule).

**Suite: 3529 / 31 — unchanged.** Same 2 distinct pre-existing failures (rung 3, LvrControl). Behaviour-neutral.
**EIP-170: SwapLib 24,358 (margin 218, was 132) — +86 bytes freed.** Directly useful: **C4 lands in SwapLib**
and was previously blocked on headroom.

### ▶️ NEXT (ranked)
 1. **C4** — wei premium → 6-dec register kills the θ throttle (`SwapLib:441-442`) **+ the BTC mirror**
    (8-dec ⇒ ~1e3 under-report ⇒ over-throttle). 218 bytes now available. ⚠️ **Apply the C3 lesson: check the
    CALL SITE's units before trusting the local expression** — C4 is the same class of bug and may likewise
    have a compensating hack at its call site. Search for one BEFORE editing.
 2. **C10 part 2** — clamp the ether.fi rung to `totalRedeemableAmount(address)`; owns 1 of the 2 remaining
    failures. Unit trap: the check is on `eEthAmount`, we pass `weEthAmount`.
 3. **Graphify**, then the 33 unverified open items + the deeper dedup pass.
 4. ⏳ **STILL OWED TO THE USER — router/solver/filler DISCOVERABILITY**: can they find/trade our Vogue pool
    given the PoolManager holds only mock tokens, not real ones? Asked as part of the Uniswap-v4-protocol-fee
    research; **never investigated.** Also open from that same ask: v4 protocol fee activation, ether.fi v3
    pool imbalance.

## C4 DIAGNOSED — unit mismatch CONFIRMED, and the C3 call-site check came back CLEAN (no paired hack).
**The bug:** `SwapLib:1352-1357`
```solidity
uint premium = FullMath.mulDiv(amount, skew, 1e18);   // `amount` is NATIVE (wei for ETH, sats for BTC)
ICoreObs(core).recordSkewPremium(isBTC, premium);     // ...passed straight through
```
**The sink:** `Core.sol:277` — `function recordSkewPremium(bool isBTC, uint256 premiumUsd)`. The parameter
is NAMED `premiumUsd`, but receives NATIVE units. Core does **NOT** rescale: it just does
`skewPremium{BTC,ETH} += premiumUsd` and `_bumpEwma(_prem{BTC,ETH}, premiumUsd)`.
✅ **C3 LESSON APPLIED — I checked the SINK's units BEFORE editing** (the step that nearly shipped an
  inflated cap in C3). Result: **NO compensating hack exists.** Unlike C3 this is a PLAIN one-sided
  mismatch, so a one-site fix is correct here — but the check was mandatory, not optional.

**Impact — the EWMA feeds θ, so both directions misprice the throttle:**
 • **ETH:** wei (1e18-scale) into a 6-dec USD register ⇒ **massive OVER-report** ⇒ θ sees a huge premium
   rate ⇒ **throttle effectively never binds.**
 • **BTC:** sats (1e8-scale) ⇒ **UNDER-report (~1e3)** ⇒ θ sees ~no premium ⇒ **over-throttle.**
 ⇒ The two assets are wrong in OPPOSITE directions, which is why no single test caught it — and why the
   BTC-only and ETH-only suites would each look internally consistent.

### ▶️ THE FIX (not yet applied — money-path, needs its own verified run)
Convert native → 6-dec USD at the `retainSkewPremium` site using the SAME flat-1e30 rule C3 established
(`SwapLib:950-954`, now the single authority for native→USD6):
```solidity
uint premiumUsd = FullMath.mulDiv(premium, price, 1e30);   // flat /1e30 — correct for BOTH assets
```
`retainSkewPremium` must therefore take `price` (already resolved as `r.px` at the call site — pass it in
rather than re-reading, per the D3 reuse pattern). It still RETURNS the native `amount - premium` (the
input scale-down is native and stays native) — **only the RECORDED value converts.** Do not convert the
return value; that is a separate quantity.
⚠️ Verify `skewPremium*`'s OTHER consumer first: `SwapLib:941` describes something "CLAMPED to the retained
  drain premium" — if that clamp compares against a NATIVE-scaled quantity it must move to USD6 in the SAME
  commit, or the fix will break it. **Check it before applying** (this is exactly the C3 shape).

## ✅ THE "CLAMP" DOES NOT EXIST — it was a STALE DOC. C4 prerequisite dissolved (doc fixed).
`SwapLib:938-942` claimed the swap-IN skew bonus was *"funded by and CLAMPED to the retained drain
premium ({Core-skewPremiumBTC})"*. **There is no such clamp.** That bonus was REJECTED and `payRefillBonus`
DELETED on 2026-07-22 — stated 200 lines away in `creditSwapInBody` itself (`SwapLib:764-770`). Confirmed
by grep: `skewPremium*` has **NO consumer** beyond the two counters and the theta EWMA.
⇒ Nothing to reform or remove in code — the clamp was **false evidence**, the `stale-comments-are-false-
  evidence` pattern for the 5th time. **Doc corrected in place** with an explicit do-NOT-rebuild note so the
  rejected design cannot be resurrected from its own obituary.
⇒ **C4's prerequisite is cleared.**

## 🛑 C4 BLOCKED ON A REAL FINDING — `retainSkewPremium` has a CALLER-DEPENDENT UNIT CONTRACT
Three call sites, and they do NOT agree on what `amount` is:
| site | `amount` unit | price available |
|---|---|---|
| `SwapLib:451` (sell skew) | **NATIVE** volatile (wei/sats) | `r.px` |
| `SwapLib:474` (well skew) | **NATIVE** volatile (wei/sats) | `r.px` |
| `SwapLib:1051` (drain leg) | **USD** — *"scale the buy-driving USD DOWN"* | `basePrice` |
⇒ **A blanket native→USD6 conversion INSIDE `retainSkewPremium` would CORRUPT site 3**, which already
  passes USD. This is the `_takePreferred` shape (unit contract set by the caller) — the exact trap that
  made the C2 `scaleTo6` patch break 333 tests.
⇒ 🛑 **DO NOT apply the one-line fix from the previous entry.** It assumed all callers pass native. Wrong.

### ▶️ RESOLVE FIRST, THEN FIX
 1. Determine site 3's exact USD scale (6-dec or 18-dec) — read what feeds `amount` into `creditSwapOutBody`.
 2. Choose the elegant framing (≥2 options, per BUILD-QUEUE:44-48):
    (a) **Convert at each CALL SITE** — record USD6 always; helper stays unit-agnostic on the return.
        Costs 2 conversions; makes the contract explicit at every site. **Likely winner.**
    (b) Add a `bool isNative` param — cheaper bytecode but PERPETUATES the ambiguous contract, and a
        wrong flag is silent. Loses on the "no false-sense-of-safety" rule.
 3. Only the RECORDED value converts; the returned `amount - premium` stays in the caller's own unit.

## C4 SCOPED — site 3 was ALWAYS CORRECT. Only the 2 native sites are buggy.
`_swapOutPrep` (`SwapLib:~1020`): `uint amount = scaleTo6(IAuxSwap(aux).deposit(swapper, token, usdAmount), token);`
⇒ site `:1051`'s `amount` is **6-dec USD**, so `premium = mulDiv(amount, skew, 1e18)` is **already USD6** —
  it matches `recordSkewPremium`'s `premiumUsd` contract exactly. **No fix needed there; do not touch it.**
  (Nice consequence: the drain leg's theta signal has been RIGHT all along — only the two native legs lie.)
⇒ **C4 = sites `:451` + `:474` ONLY** (both native volatile, both have `r.px` in scope).

### Framing decision (≥2 enumerated, per BUILD-QUEUE:44-48)
 (a) ⭐ **WINNER — `price` param, 0 = "already USD6"**: `retainSkewPremium(core, isBTC, amount, skew, price)`;
     inside, `uint premiumUsd = price == 0 ? premium : FullMath.mulDiv(premium, price, 1e30);`
     Sites 451/474 pass `r.px`; site 1051 passes `0`. ONE declaration, ONE recording path, the unit contract
     becomes EXPLICIT at every call site instead of implicit. Reuses the flat-/1e30 primitive C3 established.
 (b) ✗ Convert+record at each call site, helper returns premium — **LOSES**: triplicates the
     `recordSkewPremium` call, and the swapToBody sites are stack-tight (the very constraint that forced D3).
 (c) ✗ `bool isNative` flag — **LOSES**: a wrong bool is SILENT and reads as safe; the `price`/0 sentinel at
     least fails loudly (a 0 price where one is needed zeroes the premium, and a stray price where USD6 is
     passed produces an absurd magnitude). Also fails the no-false-sense-of-safety rule.

### ▶️ NEXT: apply (a), then FULL SUITE at FORK_BLOCK=25653624. Expect movement in theta-throttle tests —
   **investigate any change before accepting it**: ETH's throttle currently never binds, so tests written
   against the broken behaviour may now correctly start throttling (the 4-instance
   "calibrated-while-broken" pattern — do NOT edit them to green without deriving the right value).

## 📌 DEDUP PASS — HARD REQUIREMENT ADDED (user, 2026-07-31)
> "the dedup path should make sure that no outrageous `IAuxBTC_V` interfaces exist, only the MINIMUM
>  quantity of interfaces we need"
⇒ §A.52 (95 interface declarations) is now a **REQUIRED** dedup deliverable, not optional. Rules:
 • **ONE declaration per interface, in a SHARED file** (BUILD-QUEUE:44). No per-consumer `IFoo_A`/`IFoo_V`
   variants carrying a 2-function slice of the same contract.
 • Collapse to the MINIMUM SET: if two interfaces name the same contract, they merge — differing method
   subsets are NOT a justification for a second declaration.
 • ⚠️ **Audit by STRUCTURE (`^interface`), never by type name** — `IAuxBtc_V` matched only its OWN obituary
   comment when I grepped for it, which is why I wrongly reported it as live. Grep the declarations.
 • Naming: `IAuxBtc_V`-style suffixes are exactly the cryptic-2/3-letter-name violation; the merged
   interface takes the plain name.

## C4 ATTEMPT 1 — framing (a) does NOT FIT THE STACK. Reverted; next framing identified.
Applied (a) (5th `price` param, `0` = already-USD6). The helper compiles, but **`swapToBody` overflows**:
```
Error: Stack too deep. --> src/imports/SwapLib.sol:453:38
    sellSkew(c.core, r.px, isBTC, r.amount), r.px);
```
Then tried the D3 sequencing trick (drop the `uint skew` local, inline the call) — **it made things WORSE**:
the nested call's args are all live simultaneously, so inlining ADDS pressure rather than freeing a slot.
Reverted; tree is green.
⚠️ **CORRECTION to my own D3 note: "sequence nested calls" is NOT a general stack remedy.** It helps only
  when the inner call's result replaces MORE live values than its args consume. Here it consumed 4 to
  replace 1. D3 worked because the replaced expression was itself large — a different situation.

### ▶️ NEXT FRAMING (d) — pass the STRUCT, not the values ⭐
Both native sites already carry `amount` AND `price` inside `r` (`Types.SwapReq`). Passing the struct is
**ONE memory pointer instead of TWO stack values**, so it should drop pressure BELOW today's baseline:
```solidity
function retainSkewPremium(address core, bool isBTC, Types.SwapReq memory r, uint skew) internal
// reads r.amount + r.px, records USD6 via the flat /1e30, writes r.amount back
```
⚠️ **Blocker to solve first:** site `:1051` (drain leg) has NO `SwapReq` — a bare `amount`, already USD6.
  Options: (i) give that leg the struct too — **CHECK whether it already builds a `RouteParams`/`SwapReq`
  nearby**; if so this UNIFIES both legs and counts as real dedup; (ii) a thin USD6-only path there.
  Prefer (i): it DELETES a divergence instead of adding a branch.
📌 Do NOT reach for `via_ir` — disabled deliberately, and the user's rule is that stack-too-deep is always
  solvable by restructuring. Framing (d) attacks the actual cause (too many live scalars) rather than
  shuffling them around.
⏱️ OPERATIONAL: `forge build --force` + a chained commit exceeded the 2-min tool timeout and the commit was
  LOST (the revert had already applied). **Never chain a `--force` rebuild with the commit that records its
  result** — run the build alone, then commit separately.

## C4 ATTEMPT 2 — framing (d) COMPILES. (Suite pending at time of writing.)
`retainSkewPremium(address core, bool isBTC, SwapReq memory r, uint skew)` — takes the struct (ONE memory
pointer) instead of `amount`+`price` (TWO live stack values), MUTATES `r.amount` in place, no return.
**`forge build --force`: Compiler run successful.** The stack overflow that killed framing (a) is gone —
confirming the diagnosis that the cause was live-scalar COUNT, not the extra argument as such.
 • `:451` / `:474` (native): `retainSkewPremium(c.core, isBTC, r, skew);` — `r.px` is set, declaring NATIVE.
 • `:1051` (drain, already USD6): builds a local `SwapReq` with `sr.px = 0` ⇒ "record verbatim, no
   conversion", preserving the leg that was ALWAYS correct. One declaration, ONE recording path, no branchy
   duplicate helper.
**`r.px` doubles as the unit DECLARATION** — the value needed for the conversion IS the thing that proves a
conversion is needed, so the two cannot drift apart (the failure mode a `bool isNative` would have had).
⏳ NEXT: full suite at `FORK_BLOCK=25653624`. Baseline 3529/31, 2 distinct pre-existing failures
  (`testEthVenue_EtherFi_InstantRedeem_Rung3`, `testLeverage_LvrControlVsTreatment`).
⚠️ **EXPECT theta-throttle movement and INVESTIGATE rather than accept**: ETH's throttle currently NEVER
  binds (wei into a USD6 register), so tests written against that broken behaviour may now correctly begin
  throttling. That is the 4-instance "calibrated-while-broken" pattern — DERIVE the right value; do not
  edit a fixture to green. If BTC tests move too, that is the mirror (~1e3 under-report ⇒ over-throttle).
📌 Committed BEFORE the suite run per the new standing rule (a chained build+commit already lost one
  commit to the 2-min timeout). If the run is killed, this reasoning survives.

## C4 ATTEMPT 2 RESULT — compiles, but ONE new failure: the premium now records ZERO. Reverted.
**Suite: 3499 / 61** (baseline 3529 / 31). Exactly **ONE new distinct failure**:
```
[FAIL: draining paid a retained skew premium: 0 <= 0] testGrindRemoval_DrainPaysRetainedSkewPremium()
```
⇒ The conversion drove the recorded premium to **0**. Not a calibration drift — a magnitude COLLAPSE.

### Leading hypothesis — the flat /1e30 UNDERFLOWS for realistic premium sizes
`recorded = mulDiv(premium_native, px, 1e30)`. The premium is a SMALL FRACTION of an already-modest swap:
 • ETH: `px ≈ 3e21`. Need `premium_wei ≳ 1e30/3e21 ≈ 3.3e8 wei` (~3.3e-10 ETH) for even ONE 6-dec unit —
   plausible to clear, so a 0 suggests the failing leg is BTC, or the premium is far smaller than assumed.
 • BTC: `px ≈ 6e32`. Need `premium_sats ≳ 1e30/6e32` — clears trivially. So BTC should NOT round to 0.
⇒ The arithmetic does not obviously underflow, so **verify the actual values before theorising further**:
  trace the test and print `premium`, `r.px`, and the recorded result at each of the 3 sites.
⚠️ **A REAL possibility to rule out FIRST:** the drain path may reach `retainSkewPremium` via the site-1051
  (`sr.px = 0`) branch, where the premium is recorded VERBATIM and should be UNCHANGED from baseline. If
  that leg now yields 0, the bug is in MY local-struct construction (`SwapReq memory sr;` — are `amount`/`px`
  the only fields that matter? does the leg read a field I left zero?), NOT in the unit conversion.
  **CHECK WHICH SITE THE TEST ACTUALLY HITS BEFORE CHANGING ANY ARITHMETIC** — this is the same
  attribution error as the two-`expectRevert` mistake; do not theorise about a site the test never reaches.

### ▶️ NEXT
 1. `forge test --match-test testGrindRemoval_DrainPaysRetainedSkewPremium -vvv` and read WHICH call site
    fires and what `premium`/`px` actually are. One test, fast.
 2. Only then decide: fix the conversion, fix the struct construction, or (if the premium is genuinely
    sub-1e-6 USD) recognise that the OLD behaviour recorded a meaningless native number that merely LOOKED
    non-zero — in which case the TEST's premise needs re-deriving, not the code. **Do not assume this.**
📌 Tree REVERTED to green (3529/31). The C4 diagnosis, scoping and framing all still stand — only the
  recorded-value magnitude is unresolved.

## ❗C4 RE-SCOPED AGAIN — it is a **ONE-SITE** bug. Site `:474` was ALREADY CORRECT; I broke it.
`testGrindRemoval_DrainPaysRetainedSkewPremium` does `AUX.swap(USDC → WETH)` (BUYING weth = draining the ETH
reservoir) and asserts on `CORE.skewPremiumETH()`. That is `swapToBody`'s **`else` branch at `:452`** — the
**USD-side** leg, structurally identical to `:1051` whose comment reads *"scale the buy-driving USD DOWN"*.
⇒ **`:474`'s `r.amount` is USD, NOT native.** My conversion mangled a value that was already in the right
  unit — hence the recorded premium collapsing to 0. The failing test was RIGHT.

### Corrected unit table (verified against the branch structure, not assumed)
| site | branch | `amount` unit | needs conversion? |
|---|---|---|---|
| `:451` | sell leg — *"Scale the volatile input DOWN"* | **NATIVE** (wei/sats) | ✅ **YES — the ONLY real bug** |
| `:474` | `else` (USD→vol drain), `wellSkew` | **USD** | ❌ no — already correct |
| `:1051` | drain leg, `scaleTo6` input | **USD6** | ❌ no — already correct |
⇒ **C4 = site `:451` ALONE.** Two of the three sites were always right.
⇒ Impact shrinks accordingly: only the SELL leg mis-records (native into a USD6 register). The ETH
  "throttle never binds" claim holds ONLY for sell-side flow; buy/drain flow was always metered correctly.
  **Re-derive the impact statement before quoting it** — the earlier "both legs lie" wording is now WRONG.

📌 **THIRD instance this session of the same root error**: I assumed a helper's callers share a unit
  contract instead of verifying each one. C2's `scaleTo6` (333 tests), C4 attempt 1 (`:1051`), C4 attempt 2
  (`:474`). **Each call site's units must be read from its OWN branch, every time.** The `r.`/`amount` name
  is identical across all three — the NAME carries no unit information whatsoever.
✅ The suite caught it in ONE test, and the fixture was the oracle again — not something to adjust.

### ▶️ NEXT — the fix is now SMALL and low-risk
Apply the struct framing (d) but pass `r.px` as the unit declaration ONLY at `:451`; leave `:474` on the
verbatim path (`px = 0` semantics) and `:1051` untouched. Then one suite run.

## ✅✅ C4 LANDED — one-site fix, 3529/31 = EXACT baseline, no fixture touched.
`retainSkewPremium(core, isBTC, SwapReq memory r, uint skew, bool nativeAmount)`:
 • **`:451` SELL leg — `true`**: native (wei/sats) ⇒ `mulDiv(premium, r.px, 1e30)`, the flat scale correct
   for BOTH assets (WBTC's x1e10 price lift makes it asset-independent — same rule as C3 and `poolVolUsd`).
 • **`:474` / `:1051` DRAIN legs — `false`**: buy-driving USD, already 6-dec ⇒ recorded VERBATIM, unchanged.
 • Struct passed as ONE memory pointer (not `amount`+`price`) so `swapToBody` stays within the stack.
 • `r.px` REJECTED as the discriminator — it is non-zero on BOTH `swapToBody` legs, so it cannot tell them
   apart. The caller states the unit explicitly; the branch is a compile-time constant per site.
**Suite 3529 / 31 — identical to baseline**, only the 2 known pre-existing failures. **No test edited.**
⇒ Sell-side skew premium now records 6-dec USD into the 6-dec register, so the theta EWMA finally sees a
  true rate on that leg (it previously saw wei ⇒ absurdly large ⇒ **the sell-side throttle never bound**).

### ⚠️ PROCESS FAILURE THIS TURN — a revert that did not revert
`git checkout -- SwapLib.sol` restored the file to **commit 666bf80, which had already STAGED attempt 2**.
So the tree kept the broken conversion while I reported it as reverted-and-green. Caught only because the
next edit's anchor text failed to match.
📌 **RULE: `git checkout --` reverts to HEAD, NOT to "before my change" — if the change was already
  committed, checkout RESTORES it.** Never commit an unverified experiment and then rely on `checkout` to
  undo it. Either (a) verify BEFORE committing, or (b) undo with an explicit `git revert`/counter-edit.
  This directly contradicts the commit-early habit, so the resolution is: commit the *reasoning doc* early,
  commit *unverified code* never.
✅ Verify a revert by GREPPING the code, not by trusting the command's exit status.

## 🔬 ROUTER / SOLVER DISCOVERABILITY — ANSWERED WITH SOURCE PROOF (finally; long-owed)
**QUESTION:** can routers/solvers/fillers find and trade our Vogue pool, given the PoolManager holds only
mock tokens? **ANSWER: NO — provably not.** Two facts from the VENDORED v4-core source (not from docs):

**(1) Pool identity IS a hash over the currency ADDRESSES.** `lib/v4-core/src/types/PoolId.sol:11-16`:
```solidity
function toId(PoolKey memory poolKey) internal pure returns (PoolId poolId) {
    assembly ("memory-safe") { poolId := keccak256(poolKey, 0xa0) }   // 0xa0 = all 5 slots
}
```
`lib/v4-core/src/types/PoolKey.sol` — slots are `{currency0, currency1, fee, tickSpacing, hooks}`.
⇒ `PoolId == keccak256(currency0, currency1, fee, tickSpacing, hooks)`. The token ADDRESSES are part of the
  preimage, so a different currency pair is a DIFFERENT pool, unreachable by any other key.

**(2) Our currencies ARE the mocks.** `evm/src/Core.sol:479-484`:
```solidity
if (token1isVol) { token0 = usdMock; token1 = volMock; }
else             { token0 = volMock; token1 = usdMock; }
PoolKey memory k = PoolKey({ currency0: Currency.wrap(token0), currency1: Currency.wrap(token1),
    fee: 420, tickSpacing: 10, hooks: IHooks(address(0)) }); PoolId id = k.toId();
```
⇒ A router routing real WETH/USDC builds its key from the REAL addresses ⇒ a different keccak preimage ⇒
  **a different PoolId ⇒ it never touches our pool.** No indexer, SOR, or solver can path into it, because
  there is no key they would ever construct that maps to it. **This is by construction, not by obscurity.**
📌 Also note `hooks: IHooks(address(0))` — our vanilla pools declare NO hook, so hook-scanning indexers
  find nothing either.
⇒ **Consequence to decide (NOT yet decided):** this is a deliberate isolation property (no external flow can
  hit our curve) but it also means **ZERO external order flow / fee revenue** from routers. If external
  flow is WANTED, mocks are the blocker — the currency addresses themselves must be real.

### ⏳ STILL OPEN — the dual-pool hook comparison (needs ITS source, which I do NOT have here)
The user asks how a "dual-pool hook" keeps REAL tokens in the PoolManager while earning double fees, and
whether that makes it MORE discoverable. From (1) the mechanism is forced: if its PoolKey names REAL
currencies then it IS discoverable by every router, and its hook earns a fee ON TOP of the LP fee via the
`beforeSwap`/`afterSwap` return delta. **I have NOT read that hook's code and must not assert its design.**
▶️ NEXT: obtain the dual-pool hook source (repo/address), then verify against `IHooks.sol` +
  `getHookFee`/return-delta handling in `lib/v4-core/src/PoolManager.sol` before claiming anything.
⚠️ Do NOT answer the "double fees" half from memory — the user explicitly demanded source proof.

## C10 PART 2 — ABI CONFIRMED ON MAINNET (my earlier "absent" claim RETRACTED). Semantics still unverified.
Probed the REAL `EtherFiRedemptionManager` `0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0` (live `cast call`):
| signature | result | verdict |
|---|---|---|
| `canRedeem(uint256,address)` | returns **`false`** | ✅ **EXISTS** (a clean bool, not a revert) |
| `totalRedeemableAmount(address)` | returns **`0`** | ✅ **EXISTS** |
| `totalRedeemableAmount()` (0-arg) | reverts | ❌ absent |
| `getTotalRedeemableAmount(address)` | reverts | ❌ absent |
🔴 **RETRACTION:** I previously recorded `canRedeem` as "function absent" from a bare revert. **WRONG** — it
  exists; I had probed it with the wrong ARITY (`canRedeem(uint256)`). This is the recorded lesson
  "a bare revert with empty data does not distinguish no-such-function from wrong-signature" — and I made
  the error anyway. The two `Error: encode length mismatch` lines in this run were likewise MY OWN cast
  mistake (args passed to 0-arg sigs), **not** contract evidence. Read the error's SOURCE before using it.

### 🛑 STILL CANNOT LAND — semantics unknown, and the failure mode is SILENT DISABLEMENT
Both views returned **0 / false** for every argument tried (incl. the weETH token address). I do NOT know
whether the `address` param means the USER, the OUTPUT TOKEN, or something else — so I cannot tell a genuine
"no capacity right now" from "wrong argument, always 0".
⚠️ **Clamping `weethIn` to a view that returns 0 for the wrong arg would DISABLE rung 3 permanently** — and
  it would look like healthy fall-through to rung 4, i.e. exactly the SILENT failure §C10 part 1 was written
  to eliminate. That is strictly worse than today's observable `InstantRedeemSkipped`.
▶️ **NEXT (cheap, decisive):** call both views with an address KNOWN to hold weETH (find one from a recent
  `Transfer` on the weETH token, or use the Rover/Aux position address on the fork). A non-zero return
  identifies the parameter's meaning; only then clamp with `min(weethIn, redeemable)`.
📌 Part 1 (observability) IS landed and is the safe state. Part 2 stays open by CHOICE, not oversight.

## 🔗 DUAL-POOL HOOK — the banked comparison (A.26/A.27, BUILD-QUEUE-AND-107.md:2104+)
It IS banked, from 2026-07-27, including the user's own corrections:
 • `DualPoolStableHook` is **STABLE-to-STABLE**, so its near-zero IL is a property of the PAIR, not of its
   design. Our band is ETH/USD where IL is real ⇒ our IL-protect stack is a REQUIREMENT, not overhead.
 • It **shuttles real assets vault↔pool on every swap**; we hold one capital base that earns venue yield AND
   provides band depth simultaneously. (Its "double fee" = swap fee + vault yield on REAL reserves.)
 • It needs `emergencyRevokeVault` / vault-vetting / native-ETH-rejection because its pool holds VALUE.
   Ours holds mock tokens (worthless outside the system) ⇒ not a value-bearing attack surface.
 • It caps quotes at `_effectiveAssets`; we MATERIALISE instead of capping (A.27, the §M phantom depth).
🔴 **CORRECTION to what I said last turn** ("zero external order flow"): **too strong, and already retracted
  by the user at A.26.** `Aux.swap` is `public payable` with NO caller gate and pays `msg.sender`, so any
  router/searcher CAN trade us today. What the mock currencies block is **V4-NATIVE ROUTING discoverability**
  — an INTEGRATION gap (adapter/aggregator listing closes it), not a capability gap. The `PoolId` proof
  stands; its scope is v4 routing only.
⚠️ Gas vs their implementation remains UNMEASURED — do not claim it (standing note from A.26).

## 🔬 DISCOVERABILITY, PRECISELY SCOPED — it is LOG-FILTERING, not an API gate. Workaround EXISTS.
**What "mocks block V4-native routing" actually means, with source:**
**(1) ON-CHAIN: NOTHING is blocked.** `lib/v4-core/src/PoolManager.sol:185`
```solidity
function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
```
The key arrives **FROM CALLDATA**. No registry, no whitelist, no permission lookup. **Anyone holding our
key can swap our pool right now.** The PoolManager never consults a list of "real" tokens.
**(2) OFF-CHAIN: discovery is TOPIC FILTERING.** `lib/v4-core/src/interfaces/IPoolManager.sol:59-67`
```solidity
event Initialize(PoolId indexed id, Currency indexed currency0, Currency indexed currency1, ...)
```
`currency0`/`currency1` are **`indexed`** ⇒ they are LOG TOPICS. An indexer/solver enumerating pools for a
pair filters `Initialize` on those two topics. Our pool emits MOCK addresses there ⇒ **never matches a
WETH/USDC filter ⇒ never enters the route graph.**
⇒ **So it is not "Uniswap's API refusing us" and not automatic detection magic — it is that nobody's filter
  asks for our currencies.** Mechanism fully explained, no hand-waving.

### ⇒ YES, A WORKAROUND EXISTS — and mocks can stay
Because (1) is ungated and `Aux.swap` is `public payable` with no caller gate (A.26), external flow needs
only a *route-graph entry*, not a redesign:
 (a) **Adapter contract holding REAL tokens** that presents a real-token pair and internally trades our
     mock pool. It emits/【registers as】a venue aggregators CAN filter for. Mocks keep their efficiency and
     their not-a-value-bearing-attack-surface property; the adapter is the only value-holding surface.
 (b) **Aggregator listing** (1inch/CoW/Odos-style adapter) — they route by their OWN adapter registry, NOT
     by v4 `Initialize` topics, so this bypasses the filter question entirely.
 (c) Real-currency v4 pool — REJECTED: forfeits the mock-token safety property for the same flow (a)/(b) get.
⚠️ UNVERIFIED: whether (a)/(b) are WANTED (external flow = external arb pressure on our band). **Design
  decision for the user, not a code gap.** Also unmeasured: whether the flow would exceed adapter gas cost.

## 🔴 NOT DONE THIS TURN — stated plainly rather than half-answered
 1. **C10 part 2 ("no shortcuts")** — still blocked on identifying the `address` param of
    `totalRedeemableAmount(address)` / `canRedeem(uint256,address)`. NEXT: probe with an address KNOWN to
    hold weETH (pull a recent `Transfer` sender from the weETH token on the fork), get a NON-ZERO return,
    THEN clamp `min(weethIn, redeemable)`. Not landed = deliberate; a wrong clamp silently kills rung 3.
 2. **Rover / ether.fi v3 imbalance — WHY it exists and why arbers do not close it.** NEVER investigated.
    The user notes we EXPLOIT it but nobody has explained its persistence. Hypotheses to TEST (do not
    assert): v3 position is concentrated/one-sided so closing it needs weETH inventory + an unwind path;
    arb profit may be < the ether.fi redeem fee (~0.3%) + gas; or the pool is thin enough that the arb is
    not worth a searcher's slot. **Get on-chain data: pool reserves, tick range, recent swap history.**
 3. **Uniswap v4 PROTOCOL FEE switch — NEVER researched.** Ask: is it active, what rate, who sets it, does
    it apply to OUR pool. `lib/v4-core/src/ProtocolFees.sol` + `setProtocolFee` are vendored HERE — this is
    answerable from source, no web needed. Check `protocolFeesAccrued` / the fee-controller address.

## ⚠️ HONESTY CORRECTION — my "indexers filter by topic" claim is INFERENCE, not proof
The vendored source proves **`Initialize` declares `currency0`/`currency1` as `indexed`** (they ARE topics)
and that **`PoolManager.swap` takes the key from calldata with no gate**. Those are FACTS.
🔴 It does **NOT** prove how Uniswap's (or any solver's) OFF-CHAIN indexer actually selects pools — I do not
  have that code here. I stated an inference as established. **Retracted to: "consistent with, but unproven."**
▶️ To actually PROVE it: query the public Uniswap subgraph/API for a known pool and inspect whether the
  filter is by currency topic, OR read an open-source solver's v4 adapter. Until then it is a hypothesis.

### 🎯 ON "we can craft the events" — the decisive constraint (this IS provable)
**An EVM log is keyed by EMITTING ADDRESS + topics.** An indexer subscribing to Uniswap's canonical
`PoolManager` (`0x0000...4444c5dc75cB358380D2e3dE08A90`) filters on THAT ADDRESS first. We can emit a
byte-identical `Initialize` from OUR contract, but it carries OUR address ⇒ **a PoolManager-scoped indexer
will never see it. Uniswap's own logs cannot be forged.**
⇒ Crafting events only reaches an indexer that watches OUR address — which is exactly the
  **aggregator/adapter listing** path (workaround (b)), NOT a way into Uniswap-native routing.
⇒ So event-crafting is NOT a shortcut around the mock-currency issue. The adapter remains the real answer.

## ✅ UNISWAP V4 PROTOCOL FEE — RESEARCHED (source + live mainnet read)
| fact | value | source |
|---|---|---|
| Cap | **0.1%** (`MAX_PROTOCOL_FEE = 1000` pips, `PIPS_DENOMINATOR = 1_000_000`) | `ProtocolFeeLibrary.sol:6-15` |
| Who sets it | **`protocolFeeController` ONLY** (`if (msg.sender != protocolFeeController) revert`) | `ProtocolFees.sol:35-36` |
| Granularity | **PER POOL** — `setProtocolFee(PoolKey memory key, uint24 newProtocolFee)` | `ProtocolFees.sol:35` |
| Controller set by | `setProtocolFeeController(address) external onlyOwner` | `ProtocolFees.sol:29` |
| LIVE controller | **`0x89A5D5bF00a27D55c02951E49078a5C5771051dB`** (read from mainnet PoolManager) | `cast call` |
| Direction | taken OFF THE TOP: `swapFee = self + lpFee - (self*lpFee)/PIPS_DENOMINATOR` | `ProtocolFeeLibrary.sol:44` |
⇒ **IMPACT ON US: currently NONE, and structurally hard to impose.** The fee is **per-pool and opt-in by the
  controller** — it is NOT a global switch that flips on every pool. A controller would have to target OUR
  PoolKey specifically. Combined with the discoverability finding (our key names mock currencies), our pools
  are not plausible targets.
⚠️ NOT YET CHECKED: the actual `protocolFee` value currently stored for our PoolKeys (we have no mainnet
  deployment, so this is only meaningful at deploy time). **Add a deploy-time assertion** that our pools'
  protocol fee is 0, and a monitor — the controller CAN set it later without our consent, up to 0.1%.

## 🔴 STILL NOT DONE (2 of 3) — not attempted this turn, stated plainly
 1. **C10 part 2** — needs a weETH-holding address to disambiguate the view's `address` param.
 2. **Rover / ether.fi v3 imbalance** — WHY it persists / why arbers don't close it. Needs on-chain data.

## ✅ PROOF — GRAPHIFY CANNOT PARSE SOLIDITY. The 33 + deep dedup are OURS to do by hand.
Enumerated EVERY quoted extension across the whole installed `graphify` package (positive enumeration, NOT
an empty grep — the `never-assert-absence-from-a-grep` rule):
```
recognised code/doc extensions: ['.go', '.java', '.js', '.md', '.pdf', '.py', '.rb', '.rs', '.ts']
.sol anywhere in package: False
```
⇒ `.sol` appears in NO file of the package. Its AST path (`extract.py`/`detect.py`) has no Solidity parser,
  so our contracts would be skipped by `detect` or fall to the LLM text path — **no call graph, no
  structural edges, which is exactly the capability we wanted it for.**
⇒ **CONSEQUENCE: the 33 unverified items and the super-deep dedup must be done MANUALLY.** They cannot wait
  on a graph. Plan by hand, using STRUCTURAL greps (`^function`, `^interface`, `^contract`) — never type
  names (they match their own obituaries) and never bare absence (an empty result proves nothing).

## 🔬 C10 PART 2 — ON-CHAIN DATA OBTAINED. The view is REAL and reads **0 GLOBALLY**.
Pulled REAL weETH holders from live `Transfer` logs (head `25655536`, weETH `0xCd5f…b7ee`) and probed the
RedemptionManager `0xDadEf1fF…7Ae0`:
| holder | `totalRedeemableAmount(address)` |
|---|---|
| `0xbdfa7b78…` | **0** |
| `0xcd2eb13d…` | **0** |
| `0xce8a3b66…` | **0** |
⇒ It returns 0 for GENUINE holders, not just for my earlier junk arguments ⇒ **this is NOT a
  wrong-parameter artifact.** The most consistent reading: **ether.fi's instant-redeem pool is EMPTY at this
  block**, so nothing is instantly redeemable for anyone.
⇒ 🎯 **This likely EXPLAINS the standing rung-3 failure** `rung 3 paid native ETH: 0 <= 4900000000000000000`
  — the rung correctly finds no capacity and falls through. That would make it an ENVIRONMENTAL failure
  (live external state at the pinned block), **NOT a code defect** — and it is exactly why C10 part 1's
  `InstantRedeemSkipped` observability was the right first move.
⚠️ **DO NOT conclude this yet — one check remains.** A globally-0 view is also what a WRONG-SEMANTICS view
  returns. Distinguish by checking whether the value is EVER non-zero: sample `totalRedeemableAmount` for the
  same holder across several HISTORICAL blocks (e.g. -50k, -200k). **Non-zero at any block ⇒ semantics
  confirmed AND the emptiness is real ⇒ then clamp `min(weethIn, redeemable)` safely.** Always-zero ⇒ the
  parameter still means something else and the clamp stays unsafe.
📌 Part 1 (observability) remains the safe landed state; part 2 is ONE historical-block probe from resolving.

## 💰 WHY OPT IN TO THE V4 PROTOCOL FEE — the benefit is NOT to the pool
`setProtocolFee` is controller-only and per-pool, and the fee is taken OFF THE TOP of the LP fee
(`ProtocolFeeLibrary:44`) — it does NOT add a surcharge to swappers. So it is a **SPLIT of existing LP
revenue, not new revenue**: the pool/LPs are strictly WORSE off, and the beneficiary is the protocol
treasury via the controller. **There is no benefit to US in opting in** — and we cannot opt in anyway
(controller-only). The only actionable item is DEFENSIVE: assert 0 at deploy + monitor, since the
controller can impose up to 0.1% later without our consent.

## 🔴 RETRACTION — "ether.fi's pool is empty" was WRONG. The user doubted it; the data agrees with the user.
Probed `totalRedeemableAmount(0xcd2eb13d…)` (a REAL weETH holder) across history:
| block | 25655536 | 25600000 | 25400000 | 25000000 | 24000000 |
|---|---|---|---|---|---|
| value | 0 | 0 | 0 | 0 | 0 |
⇒ **Zero at EVERY block back ~1.6M blocks (months).** An instant-redeem pool does not sit empty for months.
⇒ **The SEMANTICS are wrong, not the pool.** My "environmental / pool is empty" reading is RETRACTED. The
  `address` parameter does not mean "holder whose weETH could be redeemed".
📌 This is the 4th time a hypothesis of mine survived one probe and died on the SECOND. The historical
  sample cost one command and overturned the conclusion — **sample across TIME before calling external
  state "empty"; a single-block read cannot distinguish empty from wrong-question.**

### ▶️ C10 PART 2 — NEXT (still not landed; do NOT clamp on a view that is always 0)
The right move is to stop guessing the ABI and READ IT:
 1. `cast implementation`/EIP-1967 slot on `0xDadEf1fF…7Ae0` (it is very likely a PROXY — that would also
    explain 0-arg `totalRedeemableAmount()` reverting while the `(address)` overload does not).
 2. Fetch the IMPLEMENTATION's verified ABI and read the REAL capacity view + its params.
 3. Only then clamp `min(weethIn, redeemable)`.
⚠️ Rung 3's standing test failure is therefore **still UNEXPLAINED** — do not attribute it to environment.

## 💡 USER'S PROTOCOL-FEE IDEA (2026-08-01) — "inflate mockTokens so the fee deduction nets to true balances"
**Premise check first:** the v4 protocol fee is taken OFF THE TOP OF THE LP FEE
(`ProtocolFeeLibrary:44` — `swapFee = self + lpFee - (self*lpFee)/PIPS_DENOMINATOR`), **NOT off the swap
principal or the pool's token balances.** So it reduces FEE ACCRUAL, not reserves.
⇒ The idea is SOUND IN SHAPE — because our currencies are mocks we mint ourselves, an offsetting inflation
  is available to us in a way it is not to a real-token pool (this IS a genuine structural advantage of the
  mock design, and worth recording as such).
⇒ But the compensation must be applied to the **fee-accrual path**, not to reserve balances — inflating
  balances would mis-price the curve (the tick math reads reserves).
⚠️ **NOT YET NEEDED:** the fee is per-pool + controller-set, and we have NO mainnet pool, so nothing is
  imposed today. Build the DEFENSIVE assert-0 + monitor first; implement compensation only if a controller
  ever targets our key. **Do not build against a hypothetical.**

## 🎯🎯 C10 SOLVED — rung 3 asks for the ONE output token with ZERO capacity. The user was right twice.
**Method (no guessing left):** `0xDadEf1fF…7Ae0` is an EIP-1967 PROXY ⇒ impl `0x5d53b303d62a7861f88650045b8d5deb59dfb3dc`.
Pulled the impl bytecode and extracted all 50 `PUSH4 <sel> EQ` selectors, then matched candidates:
| signature | selector | in bytecode |
|---|---|---|
| `totalRedeemableAmount(address)` | `cf52e9f6` | ✅ |
| `canRedeem(uint256,address)` | `5d943e1d` | ✅ |
| `redeemWeEth(uint256,address,address)` | `50cd3742` | ✅ |
| `redeemEEth(uint256,address,address)` | `6dcc078e` | ✅ |
⇒ The ABI is REAL; my ARGUMENT was wrong. The `address` param is the **outputToken** (same role as
  `redeemWeEth`'s 3rd arg) — NOT a holder.

### 🔴 THE FINDING (live mainnet)
| `totalRedeemableAmount(outputToken)` | value |
|---|---|
| native-ETH sentinel `0xEeee…EEeE` | **0** |
| stETH `0xae7ab965…fE84` | **5_000e18 — FIVE THOUSAND stETH** |
⇒ **Our rung 3 calls `redeemWeEth(weethIn, recipient, ETHFI_NATIVE_ETH)` — requesting the output token whose
  redeemable capacity is ZERO, while 5,000 stETH of capacity sits available.**
⇒ **This FULLY explains the standing failure** `rung 3 paid native ETH via the real RedemptionManager:
  0 <= 4900000000000000000`. It is a **CODE DEFECT, not environment** — and my "the pool is empty"
  retraction was itself only half-right: the NATIVE pool is empty, the stETH pool is not.
📌 The earlier comment "(The old code passed WETH here, so this rung SILENTLY FAILED on every call.)" was a
  fix in the RIGHT place that picked the WRONG one of the two valid sentinels. The comment even says
  *"MUST be the 0xEeee… native-ETH sentinel **or stETH**"* — the working option was documented all along.

### ▶️ THE FIX (money-path — its own run)
Switch rung 3 to `outputToken = stETH` and handle stETH proceeds (it is a rebasing ERC-20; we receive stETH
not native ETH, so the delivery path must swap/wrap it or credit it as a venue asset).
 ⚠️ **Do NOT blindly flip the sentinel** — the recipient currently expects NATIVE ETH. Enumerate: (a) request
   stETH then swap stETH→ETH in the same tx; (b) request stETH and credit it directly as an ETH-venue asset
   (no swap, but the caller's unit contract changes); (c) query BOTH capacities and pick the one with room.
 ⭐ (c) is likely best — it is the general form, uses `totalRedeemableAmount` as the clamp source C10 part 2
   always wanted, and degrades correctly when either pool refills.
 ⇒ **C10 part 2's clamp now has a REAL, VERIFIED source: `totalRedeemableAmount(outputToken)`.**
📌 LESSON: I probed this view with holder addresses 3× and got 0 every time, then concluded "empty". The
  parameter's MEANING was never verified. **Verify what an argument MEANS before trusting what a call
  RETURNS** — same family as the unit-contract errors (C2/C4), 4th instance.

## 🔴 CORRECTION — the v4 PROTOCOL FEE **IS LIVE AND ACCRUING**. My "nothing is imposed" was wrong.
Read `protocolFeesAccrued(currency)` on the mainnet PoolManager `0x0000…4444c5dc75cB358380D2e3dE08A90`:
| currency | accrued |
|---|---|
| native ETH | **85695303316507359** (0.0857 ETH) |
| USDC | **84564825** ($84.56) |
| USDT | **37911052** ($37.91) |
⇒ **The switch is ON in production** — the `protocolFeeController` (`0x89A5D5bF…51dB`) is actively setting
  fees on live pools and the singleton is collecting. Non-zero accrual is PROOF of imposition, not inference.
🔴 **My earlier claim ("currently NONE, structurally hard to impose") was an ASSERTION from our lack of a
  mainnet deployment — not research.** The user challenged it twice and was right both times. What remains
  true: it is PER-POOL and controller-only, so a NEW pool starts at 0. What is FALSE: treating imposition as
  hypothetical. **The controller demonstrably does impose it.**

### ⇒ THE USER'S MOCK-INFLATION IDEA IS A REAL MITIGATION, NOT A HYPOTHETICAL
Since the controller can set up to **0.1%** on our PoolKey at any time WITHOUT our consent, and our
currencies are mocks WE mint, the compensation route is genuinely available to us and unavailable to a
real-token pool. **Record as a first-class advantage of the mock design.**
▶️ BUILD (ranked): (1) a deploy-time assert that our pools read protocolFee == 0; (2) a MONITOR on our
  PoolKeys' `slot0.protocolFee`; (3) the fee-accrual-path compensation, armed only if (2) ever fires.
  Compensation belongs on the FEE-ACCRUAL path — NOT on reserve balances (the tick math reads reserves).
📌 LESSON (recurring): I twice answered a factual question about EXTERNAL state from local reasoning instead
  of reading the chain. Both times one `cast call` overturned it (ether.fi outputToken; this). **If the
  question is about live external state, READ THE CHAIN FIRST — local inference is not evidence.**

## 📌 #12 POOLED_USD — NEW SUB-ITEM: protocol-fee compensation via mock inflation (user, 2026-08-01)
**Filed under #12 because it is a COUNT-ONCE question, not a fee question.** #12's invariant is
*"POOLED_USD counts the shared pool ONCE, no double-spend"*; a protocol-fee skim changes what the pool
actually holds versus what `POOLED_USD_*` asserts it holds, so any compensation MUST preserve that identity
or it silently breaks the same invariant #12 exists to protect.

**Context (all VERIFIED this session, not assumed):**
 • The v4 protocol fee **IS live and accruing** on mainnet (`protocolFeesAccrued`: ETH 8.569e16, USDC $84.56,
   USDT $37.91) — the controller `0x89A5D5bF…51dB` actively imposes it.
 • It is **per-pool, controller-only**, capped at **0.1%** (`MAX_PROTOCOL_FEE = 1000` pips), and taken **OFF
   THE TOP OF THE LP FEE** (`ProtocolFeeLibrary:44`), NOT off the swap principal or reserves.
 • Our currencies are **mocks WE mint** ⇒ we can offset a skim in a way a real-token pool cannot.

**THE IDEA (user):** inflate the mock tokens just enough that the fee deduction nets back to the TRUE
balances. Sound in shape — and a genuine structural advantage of the mock design.

**⚠️ CONSTRAINTS that decide the implementation (do NOT skip):**
 1. **Compensate on the FEE-ACCRUAL path, NEVER on reserve balances.** The V4 tick math prices off reserves;
    inflating reserves would mis-price the curve — a far worse defect than the 0.1% it offsets.
 2. **`POOLED_USD_*` must still count the pool ONCE.** If minted mock offsets are counted as backing, the
    count-once invariant breaks and #12's whole point is lost. The offset must be RECOGNISED as replacing
    skimmed fee value, not as NEW value. **This is the crux — get it wrong and it is a mint-from-nothing.**
 3. Only fires if a controller ever targets OUR PoolKey. **Do not build it armed.**

**▶️ BUILD ORDER (defensive first — the fee is NOT on our pools today):**
 (a) Deploy-time ASSERT our pools read `protocolFee == 0`.
 (b) MONITOR `slot0.protocolFee` on both PoolKeys (the controller can set it later WITHOUT our consent).
 (c) Compensation logic — armed ONLY if (b) fires. Derive the offset from the ACTUAL skim
     (`swapFee = self + lpFee - (self*lpFee)/PIPS_DENOMINATOR`), never from the 0.1% cap.
 ⚠️ Add an Echidna invariant alongside #12: **compensation must be value-NEUTRAL** — total backing after
   (skim + offset) equals backing before. That is the check that proves it is "not cheating".

## ✅ C10 PART 2 LANDED (capacity skip) — 3529/31 baseline. The REAL fix (stETH) is now the only piece left.
Rung 3 reads `totalRedeemableAmount(ETHFI_NATIVE_ETH)` and falls through to the wait-NFT when it is 0,
instead of burning gas on a call that MUST revert. Suite **3529 / 31 = baseline**, behaviour-neutral.
The partial `min(weethIn, capacity)` clamp is deliberately NOT done: capacity is in the OUTPUT token,
`weethIn` is weETH, and weETH:eETH is not 1:1 — a naive `min()` would mix units (the trap flagged long ago).

### 🔴 `testEthVenue_EtherFi_InstantRedeem_Rung3` — the TEST'S PREMISE IS INVALID
```
[FAIL: rung 3 paid native ETH via the real RedemptionManager: 0 <= 4900000000000000000]
```
It asserts rung 3 PAYS NATIVE ETH. But native-sentinel capacity reads **0 at every block sampled back
~1.6M blocks**, so **this test cannot pass at any recent block, with or without our code.** It was written
assuming native redemption works — it never did.
⚠️ **This is NOT the "calibrated-while-broken" pattern** (where a fixture must be re-derived): the premise
  is contradicted by live external state, so the fix is in the CODE (use an output token that HAS capacity),
  and the test then follows. **Do not weaken the assertion to make it pass** — that would hide a rung that
  never pays.

### ▶️ THE REMAINING FIX — switch rung 3 to stETH (capacity ~5_000e18)
 (a) request stETH, then swap stETH→ETH in the same tx — preserves the caller's native-ETH contract; costs a
     swap leg + slippage.
 (b) request stETH and credit it as an ETH-venue asset — no swap, but CHANGES the caller's unit contract
     (⚠️ exactly the class of error that cost C2/C4 three attempts — the caller expects native ETH).
 (c) ⭐ query BOTH capacities and pick whichever has room, falling back to the wait-NFT if neither does —
     the general form; uses the verified `totalRedeemableAmount` as its source; self-heals if either pool
     refills. Still needs (a)'s swap leg for the stETH branch.
 ⚠️ stETH is REBASING — balances move between the receive and the swap. Read the balance AFTER receipt; do
   not assume the requested amount arrives exactly.
 ⚠️ Then re-derive the weETH→eETH ratio for the partial clamp (`getEEthShares`-style view), which unlocks
   the min() that part 2 could not safely do.

## ✅✅ C10 RESOLVED — ether.fi + NATIVE ETH is CORRECT. No stETH switch. My recommendation was WRONG.
**The flaw in my own evidence:** I sampled history using a HOLDER address, never the NATIVE SENTINEL, then
concluded native capacity is "always 0". Sampling the sentinel itself:
| block | 25655536 | 25653624 (our pin) | 25650000 | **25600000** | 25400000 | 25000000 |
|---|---|---|---|---|---|---|
| native capacity | 0 | **0** | 0 | **2000e18 (2,000 ETH)** | 0 | 0 |
⇒ **Native-ETH instant redemption WORKS.** The buffer DRAINS AND REFILLS; it is not structurally empty.
⇒ **Our pinned block `25653624` simply sits in an EMPTY window.** The rung, the venue and the output token
  were all correct the whole time.
🔴 **RETRACTED: "switch rung 3 to stETH".** Wrong conclusion drawn from a sample that never tested the thing
  it claimed to test. Ether.fi stays; native ETH stays. (The 5000e18 stETH read is a real but IRRELEVANT
  second capacity pool — a distraction I chased instead of testing my actual claim.)

### ⇒ WHAT THIS MAKES OF THE PIECES
 • **The capacity skip (part 2, landed) is EXACTLY RIGHT** — it is what makes an empty-buffer window a clean
   fall-through instead of a wasted guaranteed-revert call. Keep it. It now has a proven rationale.
 • **`testEthVenue_EtherFi_InstantRedeem_Rung3` is a FORK-BLOCK problem, not a code or premise problem.**
   The assertion is CORRECT and must NOT be weakened. It fails only because the pin lands in an empty window.
 ▶️ **FIX: pin THAT test to a block with capacity** (`25600000` reads 2000e18 — verified). `ForkPin` already
   exists for exactly this; give the test its own block override rather than moving the global pin.
 ⚠️ Re-verify capacity at whatever block is chosen before pinning — the buffer moves, and a future refill
   could empty that window too. Assert capacity > 0 in the test setup so a silent re-emptying shows up as a
   clear setup failure rather than a confusing assertion failure.
📌 **LESSON (5th of this family, and the sharpest): my historical sample tested a DIFFERENT ARGUMENT than the
  claim it was used to support.** "Always 0 across 1.6M blocks" sounded decisive and was measuring the wrong
  thing entirely. **State exactly what an experiment varied, and check it matches the claim.**

## 🎯 C10 — THE ACTUAL MECHANISM: a REFILLING RATE-LIMIT BUCKET. No block-pinning, no stETH, no wrong address.
**Address CONFIRMED correct (not the problem):**
```
LiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216).etherFiRedemptionManager()
  -> 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0   // exactly the address our code uses
```
**The decisive numbers (live, head block):**
| what | value |
|---|---|
| LiquidityPool ETH balance | **14_404 ETH** (14404118053582601594825 wei) |
| RedemptionManager ETH balance | **0** |
| `totalRedeemableAmount(native)` @head | 0 |
| `totalRedeemableAmount(native)` @25600000 | 2_000e18 |
⇒ **ether.fi is NOT short of ETH — 14.4k ETH sits in the LiquidityPool.** The manager holds none and mints
  capacity from a **WATERMARK/RATE-LIMIT BUCKET that DRAINS ON USE and REFILLS OVER TIME.** That is the only
  reading consistent with: LP flush + manager empty + capacity oscillating 2000e18 → 0 → 0.
🔴 **This kills BOTH of my previous answers:** it is not "switch to stETH" (retracted earlier) AND it is not
  "pin a weird block" (the user rejected it, correctly — a pinned block would just freeze the bucket at one
  arbitrary fill level, and would ROT as soon as that block ages out of the RPC's state window).

### ▶️ THE RIGHT FIX — refill the bucket in-test, on CURRENT state
The rung-3 test forks CURRENT mainnet. Instead of hunting a block where the bucket happens to be full:
 ⭐ **`vm.warp` forward far enough for the bucket to refill, then assert.** This tests the REAL mechanism on
   CURRENT state, needs no magic block, and cannot rot. Requires the refill RATE — derive it from the
   `lowWatermark`/bucket parameters on the impl (the getters are in the 50-selector list; decode the
   remaining ones) or empirically: sample `totalRedeemableAmount(native)` at N increasing blocks and fit.
 • Fallback if warping cannot refill it (e.g. refill is driven by an admin/keeper tx rather than by time):
   the test asserts the FALL-THROUGH path instead, and a separate test covers the paid path with the bucket
   force-funded via `vm.store`/`deal` on the manager's watermark slot. **Only if time-warp genuinely fails.**
▶️ IMMEDIATE NEXT: decode the remaining selectors on impl `0x5d53b303…b3dc` to find the bucket's refill
  parameters (a `lowWatermarkInETH`-style getter did NOT match; the real name is among the other 39).
📌 The landed capacity skip stays — it is exactly what a drained bucket requires at runtime.
📌 LESSON: I proposed a fixture workaround (pin a block) for what turned out to be a MECHANISM I had not yet
  understood. The user rejected it on principle — "we must be working with current stuff" — and that
  instinct was RIGHT: understanding the bucket dissolves the need for the workaround entirely.

## 🔬 C10 — IMPLEMENTATION STATE DECODED (impl `0x5d53b303…b3dc`, raw selector calls, no guessing)
Called each 0-arg selector raw and decoded the returns — the contract's real configuration:
| selector | raw | decoded |
|---|---|---|
| `04fc532a` | `0x35fA164735182de50811E8e2E824cFb9B6118ac2` | **eETH** |
| `2f2e4bee` | `0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee` | **weETH** |
| `23509a2d` | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` | **stETH** — configured, confirming the dual output-token design |
| `08c73259` | `0x62247d29b4b9becf4bb73e0c722cf6445cfc7ce9` | (contract — role/admin/liquifier, UNIDENTIFIED) |
| `3190480e` | `0x86392dc19c0b719886221c78ab11eb8cf5c52812` | (contract — UNIDENTIFIED) |
| `2799657d` | `0x278d00` = **2_592_000** | **30 DAYS in seconds** ⭐ |
| `3cbb3a12` | `0x2386f26fc10000` = **1e16** | **0.01 ETH** — a MINIMUM (redemption floor) |
| `527d8459` | `0x2710` = **10_000** | BPS denominator |
| `66242858` | `0x1f4` = **500** | 500 bps (5%, or 0.05% depending on the denominator used) |
⇒ **Our integration addresses are CONFIRMED CORRECT against the contract's own config** (it names exactly
  the eETH/weETH we use). The address doubt is fully closed.
⇒ The **2_592_000 (30d)** and **1e16 floor** are the first hard evidence of the metering policy.

### ⚠️ WHAT IS STILL NOT PROVEN — do not build on this yet
I have NOT yet identified the getter that returns the bucket's REFILL RATE or its current fill, so I
**cannot yet compute how long to `vm.warp`.** 19 of the 50 selectors returned data; the rest take args or
are state-changing, and 2 returned addresses I have not identified.
▶️ NEXT: (1) probe the remaining ~31 selectors WITH plausible args (they are the view+setter pairs — a
  `setX(uint64)` implies a matching `x()` getter, so pair them); (2) identify `08c73259` / `3190480e` by
  calling THEM for names/symbols; (3) empirically fit the refill: sample `totalRedeemableAmount(native)`
  across a dense block range spanning a refill and measure delta/second. **(3) is decisive on its own and
  needs no ABI at all** — prefer it if selector decoding stalls.
📌 Discipline note: every conclusion above is a DECODED RETURN VALUE, not a name guess. The two
  UNIDENTIFIED addresses are marked as such rather than assigned plausible-sounding roles.

## 🔴 "REFILLING BUCKET" HYPOTHESIS — **REFUTED BY MY OWN EXPERIMENT.** The warp plan does NOT work.
Asked to prove it, I sampled `totalRedeemableAmount(native)` densely. The data CONTRADICTS the hypothesis:
| block range | value |
|---|---|
| 25596000 · 25598000 · 25599000 · 25599500 · 25600000 · 25600500 · 25601000 · 25602000 · 25604000 | **2000e18 — IDENTICAL at every sample** |
| 25610000 · 25620000 · 25630000 · 25640000 · 25645000 | **2000e18 — still identical (~7 DAYS flat)** |
| **25648000** · 25652000 · 25654000 · 25655500 | **0 — and NO recovery over ~25 HOURS** |
⇒ A rate-limited bucket refills GRADUALLY ⇒ we would see intermediate values. **We see NONE.** It is a
  **STEP FUNCTION: flat 2000e18 for ~7 days, then flat 0 for the last ~25 hours.**
⇒ 🔴 **THEREFORE: `vm.warp` will NOT refill it, and my proposed fix is INVALID.** Retracted before being
  built. (Third C10 answer of mine to die on contact with data — stETH, block-pinning, now time-warp.)

### What the step function actually implies (transition is between 25645000 and 25648000)
Flat-then-zero is the signature of a **CONFIGURED VALUE or a BINDING GUARD**, not of usage draining a meter:
 (a) **Admin set the capacity to 0** (paused/retuned) — flat 2000 for a week is a CONFIG constant, not an
     organically-varying balance.
 (b) **A low-watermark guard began binding** — e.g. redeemable is `min(cap, TVL-related headroom)` and the
     headroom term crossed below zero. The decoded `500` bps + `10_000` denominator + `1e16` floor are
     plausible inputs to exactly such a formula.
 (c) A single redemption ≥ 2000 ETH drained it AND refill is slow/keeper-driven (⇒ 25h of 0 is consistent).
▶️ **DECISIVE NEXT STEP (cheap, ends the guessing): bisect to the EXACT transition block between 25645000
  and 25648000, then read that block's transactions to the manager.** A config `set*` tx ⇒ (a). A large
  `redeemWeEth` ⇒ (c). Neither ⇒ (b), and the guard formula must be derived.
⚠️ **DO NOT build the rung-3 test fix until this is settled.** Three plausible mechanisms remain and they
  imply DIFFERENT tests: (a)/(b) mean capacity may be 0 indefinitely ⇒ the test must assert the
  FALL-THROUGH; (c) means it recovers ⇒ a paid-path test is meaningful.
📌 The landed runtime capacity SKIP is correct under ALL THREE readings — it is the one piece that needed no
  mechanism knowledge, which is why it was right to land it first.

## ✅✅✅ C10 MECHANISM **PROVEN** — capacity is a LOW-WATERMARK function of LiquidityPool TVL.
**Bisected the exact transition:** last non-zero `25647330`, first zero `25647331`.
**No logs from the manager in that block** ⇒ NOTHING called it ⇒ rules out BOTH an admin `set*` (reading a)
and a large `redeemWeEth` (reading c). The value is **COMPUTED, not stored.**
**The cause, one block apart:**
| block | LiquidityPool ETH | `totalRedeemableAmount(native)` |
|---|---|---|
| 25647330 | **24_727** ETH | 2000e18 |
| 25647331 | **14_727** ETH | **0** |
⇒ **Exactly 10_000 ETH left the LiquidityPool and capacity went to zero in the same block.** ⇒ **READING (b)
  CONFIRMED: redeemable = f(LiquidityPool TVL, low watermark).** Above the watermark it reads a flat
  configured cap (2000e18 — hence 7 days of an identical value); crossing below it reads 0.
⇒ This explains EVERY observation coherently: the flatness (a cap, not a meter), the instant step (a guard
  crossing), the 25h of 0 (TVL has stayed below), and the absence of any refill (nothing to refill — it is
  not a bucket). **All three of my earlier mechanisms were wrong; this one is measured, not hypothesised.**

### ▶️ THE TEST FIX — works on CURRENT state, no pinned block, no warp
Capacity is a pure function of the LiquidityPool's ETH balance ⇒ **`vm.deal` the LiquidityPool above the
watermark on the CURRENT fork, then assert rung 3 pays.** That is the user's requirement ("we must be
working with current stuff") satisfied exactly: current block, real contracts, real code path, and the
ONLY manipulation is topping up an external pool's balance — which is legitimate test setup, not a mock.
 ⚠️ Derive the watermark before choosing the deal amount — do NOT guess. Binary-search `vm.deal` amounts on
   the fork until `totalRedeemableAmount(native) > 0`; that empirically locates the threshold. The decoded
   `500` bps / `10_000` denominator / `1e16` floor are the likely inputs to the formula — verify, do not assume.
 ⚠️ Also assert `totalRedeemableAmount(native) > 0` in the test SETUP so that a future ether.fi change
   surfaces as a clear setup failure rather than a confusing assertion failure.
📌 The landed runtime capacity SKIP is now PROVEN correct: production genuinely sees capacity 0 whenever
  ether.fi's TVL is under the watermark — which is the live state RIGHT NOW, and has been for over a day.
📌 METHOD NOTE: the decisive evidence was ABSENCE of logs (ruling out two readings at once) plus a two-block
  balance diff. Neither required the ABI. **When a value changes with no transaction touching the contract,
  it is COMPUTED FROM EXTERNAL STATE — that alone identified the mechanism.**

## ⚠️ C10 — MY "PROVEN" MECHANISM IS **INCOMPLETE**. Raw LP balance is NOT sufficient.
**Test:** raised the existing `vm.deal(LiquidityPool, …)` from `60_000` to **`400_000 ether`** — 16× the
24_727 ETH balance that DID have capacity — and rung 3 **still pays 0**. Reverted.
⇒ 🔴 **`totalRedeemableAmount` is NOT a function of the LiquidityPool's raw ETH balance alone.** My
  two-block correlation (24_727→14_727 ETH coinciding with 2000e18→0) was **ONE coincident block, and I
  inferred CAUSATION from it.** The 10_000 ETH exit almost certainly ALSO moved a second quantity (locked-
  for-withdrawal bookkeeping / TVL share accounting), and that other quantity may be the real gate.
📌 **I called this "PROVEN" on the strength of a single paired observation.** A correlation at one block is
  not a mechanism — the falsification test (raise the balance, see if capacity returns) is what a proof
  required, and it FAILED. Do not label something proven until the intervention has been run.

### 🔑 THE MECHANISM WAS ALREADY DOCUMENTED — in the test I was trying to fix
`Alles.t.sol:1487-1493` already states it, from earlier work:
> *"At this fork snapshot ether.fi's INSTANT capacity is exhausted: free pool ETH (~18k) sits under the
>  low-watermark (bps of the 1.86M-ETH TVL) → totalRedeemableAmount == 0 — live proof of why rung 4 exists.
>  Give the LiquidityPool surplus ETH balance …, zero the locked-ETH bookkeeping reads, and refill the
>  time-based rate bucket so the REAL redemption flow runs."*
⇒ The comment names **THREE** gates — (1) low-watermark vs TVL, (2) locked-ETH bookkeeping, (3) a
  **time-based RATE BUCKET** — and the test already addresses all three (`vm.deal`, two `vm.mockCall`s,
  `vm.warp(+2h)`). **My "bucket" hypothesis was NOT wrong — it was already known and already handled.**
⇒ I spent this investigation re-deriving documented knowledge and then contradicting it. **READ THE TEST
  BEFORE INVESTIGATING WHAT THE TEST IS TESTING.**

### ▶️ REAL NEXT STEP — find which of the three gates is FAILING now
The test's setup was correct WHEN WRITTEN; something in it has since stopped biting. Check in order:
 1. **Do the two `vm.mockCall`s still match?** `ethAmountLockedForWithdrawal()` on the LiquidityPool and
    `ethAmountLockedForPriorityWithdrawal()` on `0x35e7D6fe…45FA`. **A mockCall whose signature no longer
    exists is a SILENT no-op** — the exact failure class already recorded for `canRedeem`'s wrong arity.
 2. Instrument: inside the test, call `totalRedeemableAmount(native)` AFTER all setup and assert > 0. That
    isolates "setup failed to restore capacity" from "redemption path failed" — currently indistinguishable.
 3. Only then adjust the setup.
📌 The landed runtime capacity skip remains correct and unaffected — it is about PRODUCTION seeing 0, which
  is independently confirmed by the live reads.

## 🎯 C10 — LIKELY ROOT CAUSE FOUND: one of the test's two `vm.mockCall`s targets a MISSING signature.
Probed both mocked functions against the LIVE contracts:
| mocked call | target | live result |
|---|---|---|
| `ethAmountLockedForPriorityWithdrawal()` | `0x35e7D6fe…45FA` | ✅ returns **0** — exists |
| `ethAmountLockedForWithdrawal()` | LiquidityPool `0x308861A4…F216` | 🔴 **REVERTS** |
⇒ **A `vm.mockCall` on a signature the target does not have is a SILENT NO-OP** — foundry installs the mock,
  nothing ever calls it, and the test proceeds as if the gate were neutralised. **That gate has been live
  the whole time**, which is consistent with capacity staying 0 no matter how much ETH we `vm.deal`
  (400_000 ETH changed nothing — because the BLOCKER was never the balance).
⚠️ **CAVEAT (my own recorded lesson, applied):** a bare revert does NOT by itself prove "no such function" —
  it could be a wrong RETURN-TYPE decode or a wrong arity, exactly the mistake made with `canRedeem(uint256)`
  earlier this session. **Confirm by selector before editing:** pull the LiquidityPool's implementation
  bytecode and check whether `ethAmountLockedForWithdrawal()`'s selector is present, and find the real
  accessor if it is not (the value may have moved to the same `0x35e7D6fe…` contract that holds the
  priority variant, or been renamed).

### ▶️ NEXT (ordered — do NOT skip the instrumentation step)
 1. Confirm by SELECTOR whether `ethAmountLockedForWithdrawal()` exists on the LiquidityPool impl.
 2. Find the real accessor for locked-ETH, and re-point the mock at it.
 3. **Add the diagnostic assertion FIRST regardless:** after all setup, assert
    `IRedeem_L(redeemer).totalRedeemableAmount(NATIVE) > 0`. Today "setup failed to restore capacity" and
    "redemption path failed" are INDISTINGUISHABLE — that ambiguity is what made this take so many passes.
 4. Only then re-run and adjust.
📌 **This also explains the `60_000` → `400_000` null result cleanly** — evidence that the raw-balance
  mechanism I mislabelled "proven" was never the operative gate. The retraction stands.
📌 The landed runtime capacity SKIP is unaffected — production really does read 0 (confirmed by live reads,
  independent of any test setup).


---

# ═══ NEW (2026-08-01) — RUST / TEE ENCLAVE STACK. First session that could build it at all ═══

## 🔑 THE ENABLING FACT — `cargo test --workspace` HAS NEVER RUN ON macOS
`quid-cvm` imports `sev::firmware::guest::Firmware`, Linux-gated (AMD SEV-SNP), and `quid-bridge` +
`quid-hop` depend on it, so `--exclude quid-cvm` does **not** help — the failure is transitive. Use
Docker (Docker Desktop is installed but usually not running: `open -a Docker`):
```
export DOCKER_CONTEXT=desktop-linux
docker run --rm -v $PWD/quid-ln:/w:delegated -v quidcvm-target:/tmp/target \
  -w /w -e CARGO_TARGET_DIR=/tmp/target rust:1.90 bash -c "cargo test --workspace"
```
**523 pass on Linux.** Traps: 6 `p2p::test::test_echo_*` failures under Docker are ENVIRONMENTAL (they
pass 6/6 on the host — do not "fix" them); `cargo test -p quid-crypto` alone fails (proptest gets no-std,
only builds via workspace feature unification); a SHARED cargo target volume replays stale builds when
bind-mounted files share an mtime — use a fresh `CARGO_TARGET_DIR` when a result must be trusted.

**This blind spot is why untested code accumulated**: `quid-api-core`'s test binary never compiled
(`sealed_seed.rs` imported `enclave::{MachineId,…}` — the ITEMS — while its test module called
`enclave::measurement()`, the MODULE), so **51 tests had never run once**. One import line; all pass.

## 🟢 CLOSED 2026-08-01
- **`quid-cvm` had 135 lines and ZERO tests** → 19 tests. Both entry points need `/dev/sev-guest`, so
  the AEAD core was split from the firmware fetch (`seal_with_key`/`unseal_with_key` take the key as a
  parameter); the trait impl still fetches and FAILS CLOSED. Non-vacuity PROVEN BY MUTATION: dropping
  the label from HKDF kills only `a_different_label_cannot_unseal`; dropping the firmware key kills only
  `a_different_firmware_key_cannot_unseal`.
- **8 failing pinned fixtures across `quid-common` + `quid-crypto`** — one root cause: the domain
  separators are `QUID-REALM::*`, renamed from a 4-letter predecessor, which changes every HKDF-derived
  key. Cause PROVEN, not inferred: hand-computing HKDF-SHA256 reproduced the OLD vector from the OLD salt
  and the NEW one from `QUID-REALM::RootSeed` bit-for-bit (2^-64 by chance). Blast radius is exactly the
  HKDF keys — of 11 values in `derive_snapshots` only 4 moved; `node_pk`/`ldk_seed`/xprvs are identical
  because BIP32/BIP39 never touch the salt. **User standing instruction: never restore the old prefix.**
  The signup wire blobs had to be RE-SIGNED (they carry a signature that must verify), not repinned.

## 🔴 TASK — WIRE THE TDX + NITRO SEALS (the incomplete enclave backends)
`Backend` = `Sgx | SevSnp | Tdx | Nitro | None`, detected at runtime by device node (`/dev/sev-guest`,
`/dev/tdx_guest` or `/sys/kernel/config/tsm/report`, `/dev/nsm`). **TDX and Nitro are real, detected and
attestation-capable — only their SEALING is missing** (TDX vTPM, Nitro NSM/KMS), so `pick_sealer()`
falls them back to the mock.

This is **already fail-closed and correctly so** — do not "fix" it by loosening:
`custody_ready()` is true only for `Sgx | SevSnp`; `quid-hop/src/seed.rs:278` calls
`require_backend_for_role(role, detect())` AT BOOT, defaulting to the STRICT `Fleet` role in
staging/prod so a forgotten `QUID_HOSTING_ROLE` fails closed. A detected-but-unwired CVM is REFUSED for
serving others rather than silently mock-sealed. 5 tests in `backend.rs` cover this.

**The task:** implement each seal, then flip `custody_ready()` in the SAME change that lands and verifies
it — never on the mere presence of hardware. Each needs its own `quid-cvm`-style split so the logic is
testable off the hardware.

## 🔴 TASK — VERIFYING THE SEV-SNP HARDWARE TAIL IN CI (user asked 2026-08-01: *"ci actions can verify that?"*)
`Firmware::open()`'s happy path is unverifiable on the dev machine: **the host is an Intel i9**, SEV-SNP
is AMD EPYC only, and VirtualBox does not emulate it. No VM on this laptop can ever produce a real
attestation. Three tiers, cheapest first:

1. **Ordinary CI, no special hardware (do this now).** Runs the 19 tests' fail-closed side + proves the
   crate compiles for Linux at all. Catches the regression that matters most — a seal that stops
   refusing when no firmware is present.
2. **Captured-report fixture (cheap, most of the value).** Take ONE real report on a confidential VM,
   commit it, and in normal CI verify: typed `AttestationReport` parse, `report_data` binding, the
   measurement accessor, and the AMD VCEK/cert-chain signature. Verification does NOT need SEV hardware —
   only generation does. This is the same trick as the Go↔Solidity Merkle fixture.
3. **Self-hosted runner on a confidential VM (full tail).** GitHub-HOSTED runners cannot do this — they
   expose no `/dev/sev-guest`. Point a self-hosted runner at: Azure DCasv5/ECasv5 (SEV-SNP) or
   DCesv5/ECesv5 (TDX); GCP N2D/C3D Confidential VM (SEV-SNP) or C3 (TDX); AWS EC2 SEV-SNP-capable
   instances (Nitro Enclaves are a DIFFERENT mechanism, not SEV). ⚠️ Instance families change — confirm
   against current cloud docs before quoting these.

**The suite is already shaped for tier 3 with no code change**: tests branch on
`sev_derived_key().is_ok()` and assert something real on BOTH sides.
`the_report_helpers_match_the_hardware` (renamed 2026-08-01 from `..._fail_closed_too`, which SKIPPED on
hardware and would have gone vacuous exactly where it finally mattered) asserts on a real guest that the
report carries the `identity_report_data` binding, the measurement parses, and the derived key round-trips.

## 🔴 TASK — `create_sweep_tx` NEEDS AN OPERATOR AUTH, NOT AN ENDPOINT
> **"a security feature, not a wire-up, and it deserves its own run."**

`quid-ln/src/wallet.rs::create_sweep_tx` drains the entire on-chain BDK balance to a caller-supplied
address (BDK `drain_wallet` + `drain_to`, one output, no change; NOT LN channels). It is good, actively
maintained code — the test was updated for the BIP86 P2TR migration and covers conservation
(`swept + fee == inputs`), dust rejection, and no-double-sweep-after-broadcast.

**NOTHING TRIGGERS IT.** No API request type, no command variant, no migration hook, no event handler —
so its purpose (decommission / migration / emergency evacuation) is recorded nowhere. I deleted it on
2026-08-01 and **restored it** on the user's instruction (*"dont delete it if it's necessary good code"*);
the `dead_code` warning is therefore back and is now ACCURATE — it marks a missing authorized trigger.

**Do NOT wire it to an ordinary endpoint.** "Send the entire balance to address X" is the same severity
as a seed export, and this repo already has the control for that: `quid-hop/src/migration.rs` guards
seed export with an EIP-712 `MigrationAuth` bound to the operator **Gnosis Safe** as `verifyingContract`,
≥`MIGRATION_THRESHOLD` owner signatures verified in-enclave by `ecrecover`, plus
`guard_prod_trust_anchors` refusing prod while the dev placeholder keys (secp256k1 sk 1/2/3) are compiled
in. A drain wants a `SweepAuth` mirroring that. Until then it stays unwired ON PURPOSE.

## ⚠️ CORRECTION BANKED — I claimed "TDX and Nitro do not exist"
Wrong. I had grepped for `impl Sealer` + Cargo deps and asserted absence without reading
`quid-enclave/src/backend.rs`, where both are full variants with detection and tests. Same failure mode
as the standing trap *"never assert absence from a grep"*. The accurate statement is narrower: their
**sealers** are unimplemented.

## 🔴 #114 DEAD-MAN EXIT × CIRCULATING vBTC — A REAL CONFLICT (user, 2026-08-01). Must be resolved before either ships.
**The mechanism (read from code):** `emitDeadManExit(channelId, cltvDeadline, checkpointSats, signedExitTx)`
emits RAW pre-signed Bitcoin bytes; the event records `ch.lpEth`. **The BTC payout address is BAKED INTO
`signedExitTx` at emission time** — Bitcoin cannot read EVM state, so the recipient is fixed per emission.

### THE CONFLICT
 • The dead-man exit pays the channel's checkpoint balance to **`btcRecipientOf[lpEth]`** — the LP who
   FUNDED the channel.
 • vBTC (an ERC-4626 face on banked band depth) is meant to CIRCULATE and redeem swap-out-style.
 ⇒ If the funding LP SELLS their vBTC and the fleet then vanishes, **the original LP receives the physical
   BTC while the current vBTC holder holds a claim on a dead system.** That is a **DOUBLE CLAIM / unjust
   enrichment**, and it lands exactly where the user already pushed back: *"you can't say vBTC is
   transferable then say the shares are not."*
 ⇒ Worse for FUNGIBILITY: one channel maps to one `lpEth` (BTCChannels:245-252), but fungible vBTC can be
   split across many holders. **A Bitcoin payout script pays ONE address** — it cannot fan out pro-rata
   without a covenant Bitcoin does not have.

### RESOLUTIONS (enumerated; ≥2 as required)
 (a) ⭐ **RE-TARGET ON HEARTBEAT — the payout follows the token.** The exit is ALREADY re-emitted every
     heartbeat with a fresh CLTV; re-sign it to the CURRENT holder-of-record at the same time. Cost: a vBTC
     transfer must also update `btcRecipientOf` for that channel, so a transfer is only valid if the
     recipient has registered a BTC address. **Reuses the existing heartbeat — no new machinery.** Residual
     risk: a stale window of ONE heartbeat interval if the fleet dies between transfer and re-emission.
     ⇒ Implies vBTC transfers move a WHOLE channel (channel-granular, not arbitrary fractions).
 (b) **Keep vBTC fungible; declare the dead-man exit a CHANNEL-level backstop only** — it returns BTC to the
     funding LP, and circulating holders explicitly have NO dead-man recourse. Honest and simple, but it
     WEAKENS the guarantee precisely for the holders most likely to need it. Must be disclosed, loudly.
 (c) ✗ Pay to an escrow that redistributes pro-rata — **REJECTED: requires a Bitcoin covenant** (no
     OP_CTV/CAT on mainnet). Not buildable today; recording it so it is not re-proposed.
▶️ **DECISION NEEDED FROM THE USER: (a) or (b).** They imply different vBTC semantics — (a) makes vBTC
  channel-granular; (b) keeps it freely fungible but caps the backstop's reach. **Do not build either until
  chosen** — this is the same "two designs, pick one" fork as §A.19b.

### ▶️ THE VERIFICATION GAP (the original ask) — plan, unblocked by the above
`#114` is BUILT + security-reviewed but **forge-UNTESTED and never BTC-broadcast-verified**. Reviewed-as-
correct ≠ verified-to-work — the SAME class as the `mockCall`-on-a-missing-signature just found in C10.
 1. Forge test: `emitDeadManExit` reverts for a non-attested caller, reverts for a non-delegated hop
    (`_authorizedHop`), stores `deadManDeadline`, and emits `DeadManExitEmitted` with the exact bytes.
 2. Heartbeat test: a later emission with a LARGER `cltvDeadline` overwrites; assert a stale (smaller)
    deadline cannot regress it — **if that check is missing in the code, that is a real bug** (a griefing
    hop could pin the deadline in the past and make the exit immediately broadcastable). **CHECK THIS FIRST.**
 3. Regtest broadcast: feed `signedExitTx` to the existing `regtest/` harness and prove bitcoind ACCEPTS it
    after the CLTV matures and REJECTS it before. That is the only proof the bytes are truly broadcastable.

## ⭐ (a+) IMPROVED DEAD-MAN × vBTC DESIGN — removes BOTH of (a)'s costs, using primitives that ALREADY EXIST
(a) had two residual costs: a ONE-HEARTBEAT stale window, and vBTC forced to CHANNEL granularity. Both are
removable, and neither fix needs new machinery.

### 1. **SETTLE-ON-EMISSION** — the stale window becomes ZERO BY CONSTRUCTION
Make a vBTC transfer **PENDING until the fleet has emitted a fresh `emitDeadManExit` naming the RECIPIENT.**
The token moves only when a matching pre-signed exit already exists on-chain.
⇒ **There is never a moment where someone holds vBTC without a pre-signed BTC exit that pays THEM.** The
  window is not shortened — it is eliminated, because the emission is the settlement TRIGGER rather than a
  later catch-up. (a) raced the heartbeat; (a+) makes the heartbeat the thing that completes the transfer.
⇒ **Liveness failure is SAFE, not lossy:** if the fleet never re-emits, the transfer simply expires and the
  SENDER keeps both the vBTC and their still-valid old exit. **No one is ever left holding an unbacked
  claim** — the worst case is a transfer that does not happen, which is exactly the right failure direction
  for a custody backstop.

### 2. **SPLICE-ON-FRACTIONAL-TRANSFER** — restores full fungibility
`BTCChannels` ALREADY has the splice primitive (`splice` — SPV-proves the funding UTXO was spent into a NEW
2-of-2; drives open/close/splice on the LP position). A PARTIAL vBTC transfer therefore splices the channel
into TWO channels — one per holder — each with its OWN `btcRecipientOf` and its OWN pre-signed exit.
⇒ **vBTC stops being channel-granular and becomes properly fungible**, which was (a)'s main concession and
  the user's original objection. **Reuses an existing, SPV-verified primitive instead of adding one** — this
  meets the BUILD-QUEUE:44-48 bar: *reuses an existing primitive* AND *gives a better guarantee*.
⇒ Bonus: it dissolves the "one Bitcoin script pays ONE address" limit WITHOUT needing a covenant — the
  fan-out happens on the EVM side as channel splits, not in the Bitcoin script.

### ⇒ NET RESULT
vBTC circulates and redeems swap-out-style, AND every holder — original or downstream, whole or fractional —
holds a live pre-signed BTC exit paying THEM. **The double-claim disappears** rather than being disclosed
away as in (b). ⇒ **(b) is now dominated; (a+) should be the choice unless splice-per-transfer proves too
expensive in gas or in SPV proof frequency.**
⚠️ **VERIFY BEFORE COMMITTING TO IT (do not assume):** (i) splice cost per transfer — it needs an SPV proof
  and an on-chain BTC tx, so frequent small transfers could be uneconomic ⇒ possibly gate splicing on a
  minimum size and keep sub-minimum transfers channel-granular; (ii) whether `splice` can run WITHOUT the
  LP's cooperation (the fleet holds both key halves, so it should — CONFIRM); (iii) the deadline-regression
  check flagged earlier is a PREREQUISITE for all of this — if a stale CLTV can overwrite a fresh one, every
  guarantee above collapses. **Fix that first.**

## 🚨 #114 SECURITY FINDING — "supersedes" HOLDS ON THE EVM BUT **NOT ON BITCOIN**. Premature force-close looks possible.
**The claim** (`BTCChannels.sol:376-379` + §N): re-emission *"supersedes the prior emission"*, and *"CLTV
always future ⇒ NOT broadcastable ⇒ no griefing/premature [close]"*.
**The problem:** superseding is an EVM-side notion. A previously emitted `signedExitTx` is a COMPLETE,
FULLY-SIGNED Bitcoin transaction spending the SAME funding UTXO. Emitting a newer one **does not invalidate
it** — Bitcoin has no concept of "replaced by a later log entry". Both are valid; they merely conflict, and
whichever is MINED FIRST wins.
⇒ Emission E1 carries CLTV `T1` (future at emission). The heartbeat emits E2 with `T2 > T1`. **Time then
  advances past `T1`.** E1's raw bytes are PUBLIC IN THE LOG FOREVER (an explicit design property).
  ⇒ **ANYONE can broadcast E1 the moment `T1` matures — while the fleet is perfectly alive.**
  ⇒ **Premature unilateral force-close by REPLAY of a stale emission.** The "CLTV always future" invariant
    holds only for the LATEST emission; every SUPERSEDED one matures on schedule and stays broadcastable.
⇒ This also means the earlier `deadManDeadline` monotonicity concern was the RIGHT INSTINCT but the WRONG
  TARGET: the mapping is only bookkeeping. **The real enforcement lives in the signed Bitcoin bytes, and
  nothing on the EVM can retract them.**

### ⚠️ WHAT WOULD MAKE IT SAFE — and what must be checked before calling this a bug
The ONLY way to invalidate an old pre-signed tx is to make it UNSPENDABLE — i.e. **change the UTXO it
spends**. So the design is sound IF AND ONLY IF every heartbeat also SPLICES (new funding UTXO ⇒ all prior
exits die). ▶️ **VERIFY: does the heartbeat splice each time?** A splice costs an on-chain BTC tx + an SPV
proof, so a per-heartbeat splice seems economically implausible — **but CONFIRM before concluding**, in the
Rust daemon (`deadman_exit.rs`) and the splice path, not by reasoning.
 • If heartbeats DO splice ⇒ no bug; document the dependency LOUDLY, because the safety rests entirely on it.
 • If they do NOT ⇒ **real vulnerability**, and the fix must make superseded exits unspendable. Options to
   enumerate then: (i) splice on each heartbeat (costly); (ii) a revocation-key construction (Lightning's
   own answer to exactly this problem — old states are punishable/revocable rather than merely superseded);
   (iii) accept + bound it (short channel lifetimes so a stale exit's blast radius is one heartbeat).
   ⭐ (ii) is the standard, and this IS a Lightning channel — the primitive is native to the setting.
📌 This vindicates the earlier instinct that "BUILT + security-reviewed" ≠ verified: the review approved the
  EVM gating (attested caller, authorized hop), which is CORRECT — the gap is a BITCOIN-side lifetime
  property that EVM-side review would not surface. **Same shape as the mockCall no-op: the check that was
  run was sound; the check that mattered was never run.**
🛑 **This BLOCKS (a+)** — settle-on-emission and splice-on-transfer both assume a superseded exit is dead.

## ✅ #114 FINDING **CONFIRMED AND BOUNDED** — exposure = time since the channel's LAST SPLICE.
Verified in `quid-ln/quid-bridge/src/deadman_exit.rs`:
 • The exit is a **BIP341 key-path spend with `nLockTime` = the CLTV** and a NON-FINAL `nSequence`
   (`ENABLE_LOCKTIME_NO_RBF`) so consensus enforces the timelock. There is NO `OP_CHECKLOCKTIMEVERIFY`
   script — *"the timelock lives entirely in nLockTime + the non-final input"* (`:12-23`).
 • **`Splice scope: WIRED (2026-07-24)`** (`:25-28`) — the daemon reads the CURRENT funding outpoint and
   `splice_parent_funding_txid` from `ChannelMonitor`, so a spliced channel derives the ROTATED holder key.
⇒ **A SPLICE DOES kill all prior exits** (they spend a now-spent UTXO). ✅ That is the invalidation mechanism.
⇒ **BUT splices happen on CHANNEL EVENTS (open / close / swap-out / LP splice-in-out), NOT on the heartbeat.**
  Between two splices the funding UTXO is CONSTANT, so **every emission made since the last splice remains
  spendable**, and each becomes broadcastable as its own CLTV matures.
⇒ 🎯 **THE PRECISE STATEMENT: the premature-force-close window is bounded by SPLICE frequency, not by
  heartbeat frequency.** An ACTIVE channel (frequent swaps ⇒ frequent splices) is barely exposed. An **IDLE
  channel is fully exposed** — no splices, so stale emissions accumulate and mature one after another while
  the fleet is alive and healthy. **Idle BTC-LP channels are exactly the long-lived, passive positions this
  backstop exists to protect.**

### ▶️ WHAT TO DO — in order
 1. **Quantify:** what is the real splice cadence for an idle channel? If a channel can sit unspliced for
    weeks, the exposure is weeks. **Measure before choosing a fix** (do not assume it is rare).
 2. **Fix options (enumerated):**
    (i) ⭐ **Revocation-key construction** — Lightning's native answer: each new state REVOKES the prior, so
        broadcasting a stale exit is PUNISHABLE rather than merely conflicting. Correct-by-construction and
        native to this setting (this IS a Lightning channel), but the largest build.
    (ii) **Emit ONE exit far in the future and refresh only near maturity** — fewer live stale exits
        (exposure shrinks to the refresh window), but a longer recovery delay if the fleet actually dies.
        **A direct trade of griefing risk against recovery latency — the user should pick the point.**
    (iii) **Splice on a slow timer for idle channels** — reuses the wired splice path, costs an on-chain BTC
        tx per idle channel per period. Simple; the cost is real but bounded and predictable.
 3. Only then resume (a+), which assumes superseded exits are dead — TRUE only immediately after a splice.
📌 The design is NOT broken — the invalidation mechanism EXISTS and is wired. The gap is that its trigger
  (splice) is decoupled from the refresh cadence (heartbeat). **That is a tractable parameter problem, not a
  redesign** — and it was invisible to an EVM-side review because it lives in the Bitcoin tx lifetime.

## 🚨 #114 EXPOSURE MEASURED — an IDLE channel **NEVER** splices ⇒ exposure is UNBOUNDED, not "weeks".
`quid-ln/quid-bridge/src/channel_driver.rs:188-204` — the ONLY producer of `ReconcileAction::Splice`:
```rust
} else if !spent && status == STATUS_OPEN && (ldk_value as u128) != amount_sats {
    Some(ReconcileAction::Splice)
}
```
⇒ A splice fires **ONLY when the channel's VALUE CHANGES** (`ldk_value != amount_sats` — deposit, withdraw,
  swap-out, fee settlement). **There is NO timer, NO periodic splice, NO idle path.**
⇒ An IDLE channel satisfies `ldk_value == amount_sats` ⇒ falls to `None` ⇒ **NEVER SPLICES.**
⇒ 🔴 **Therefore its funding UTXO NEVER ROTATES, and EVERY dead-man exit ever emitted for it stays
  spendable FOREVER.** Each heartbeat adds one more stale-but-valid exit, and each becomes broadcastable as
  its own CLTV matures. **Exposure is not bounded by anything.**
⇒ **Worst case is the intended use case:** a passive BTC LP who deposits once and holds. They never trigger
  a splice, so after the first heartbeat interval ANY party can force-close their channel at will, and can
  keep doing so from an ever-growing set of matured exits — **while the fleet is alive and healthy.**
📌 Combined with the earlier finding, the full chain is: EVM "supersede" ≠ Bitcoin invalidation → only a
  splice invalidates → splices are value-change-triggered → **idle ⇒ never ⇒ unbounded**. Each link was
  verified in code, not inferred.

### ▶️ THIS PROMOTES THE FIX FROM "PARAMETER TUNING" TO **REQUIRED**
Option (ii) (refresh only near maturity) is now **INSUFFICIENT ALONE** — it shrinks the count of stale exits
but never reaches zero for an idle channel, so force-close-at-will persists.
 ⭐ **(i) REVOCATION-KEY CONSTRUCTION** is the correct fix: each new state REVOKES the prior, so a stale
   broadcast is PUNISHABLE, independent of splices entirely. Lightning-native; this IS a Lightning channel.
 ⭐ **(iii) IDLE-TIMER SPLICE** is the cheap stopgap and is a SMALL change — the reconcile already has the
   splice path wired; it needs one extra arm: splice when `now - last_splice > IDLE_SPLICE_PERIOD`, even
   when the value is unchanged. **Bounds exposure to that period immediately.**
 ▶️ RECOMMEND: ship (iii) as the bound, then (i) as the real fix. **(iii) is a few lines against an
   already-wired path**, which is the elegance bar this queue demands.
⚠️ Cost check before shipping (iii): one on-chain BTC tx per idle channel per period — quantify against the
  channel's own fee accrual so the backstop cannot cost more than the position earns.

## ⭐ #114 — THE ELEGANT FIX, FROM ALL SIDES. Severity re-graded; no new crypto needed.
### SIDE 1 — WHO PROFITS? **NOBODY.** (verified, `BTCChannels.sol:214-232`)
`btcRecipientOf` is **LOCKED at registration** (*"Once an address registers via a channel open, its
btcRecipientOf is LOCKED"*) and every payout pins to `P2WPKH(btcRecipientOf)`.
⇒ A stale exit pays **the LP's own BTC to the LP**. The attacker pays the mining fee and receives **NOTHING**.
⇒ 🔽 **RE-GRADE: this is UNPROFITABLE GRIEFING, not theft.** The loss is LIVENESS/YIELD (a channel closed
  early, capital out of the band), not principal. My earlier "force-close at will" framing was accurate
  mechanically but overstated the stakes — **the attacker burns fees to hand an LP their own money.**
  (Still worth fixing: a rival or a bored actor can degrade the whole BTC-LP book for the cost of fees.)

### SIDE 2 — WHY DOES AN IDLE CHANNEL EVEN NEED RE-EMISSION?
For an idle channel NOTHING changes: same funding UTXO, same `checkpointSats`, same locked recipient. The
**ONLY** reason to re-emit is to push the CLTV forward — **so the heartbeat is the sole PRODUCER of the
stale set it is trying to outrun.** Fewer emissions ⇒ strictly smaller attack surface, at zero cost.
⇒ **FIX A (free, few lines): EMIT ONLY NEAR MATURITY.** Re-emit when `cltv - now < REFRESH_MARGIN`, not
  every tick. An idle channel then carries ~1-2 live exits instead of one per heartbeat forever. Reuses the
  existing tick loop; it is a CONDITION, not new machinery. **Strictly dominates today's behaviour.**

### SIDE 3 — WHEN THE ATTACK ACTUALLY HAPPENS, WHO WINS THE RACE?
The fleet **holds BOTH MuSig2 key halves** and can spend the funding UTXO at any time; the splice path is
already wired (`drive_splice`), and the daemon already watches chain state (`ChannelMonitor` + esplora).
⇒ **FIX B (reuses splice + monitor): REACTIVE OUTSPEND — a watchtower response.** On seeing a stale exit in
  the mempool, the fleet spends the same UTXO (a no-op splice) at a higher fee. The stale exit dies because
  its input is gone.
⇒ 🎯 **Cost is paid ONLY UNDER ATTACK** — unlike the idle-timer splice (FIX C), which pays an on-chain BTC
  tx per idle channel per period FOREVER, in the overwhelmingly common case where nobody is attacking.
⇒ And the fleet is ALIVE by assumption in this scenario — if it were dead, the exit maturing is the FEATURE.
  **The defense is only ever needed exactly when the defender exists.** That is why it composes so cleanly.

### ⇒ RECOMMENDATION: **A + B.** Drop C (idle-timer splice) and defer revocation-keys.
 • **A** shrinks the stale set to ~1-2 with a conditional — free, and it reduces how often B can be needed.
 • **B** neutralises the residual using splice + monitor + existing key custody — **no new crypto, no
   protocol change, no periodic on-chain cost.**
 • **C (idle-timer splice) is now DOMINATED** — it pays continuously to prevent an unprofitable attack.
 • **(i) revocation-keys is DEFERRED, not rejected** — it gives a CRYPTOGRAPHIC guarantee where A+B give an
   ECONOMIC + REACTIVE one. Revisit if BTC-LP TVL makes griefing worth someone's budget, or if we ever want
   the backstop to hold with the fleet degraded-but-not-dead.
⚠️ VERIFY BEFORE BUILDING: (1) does the daemon watch the MEMPOOL or only confirmed blocks? B needs mempool
  visibility — if esplora is poll-only, quantify the reaction window vs one block. (2) Confirm a no-op
  splice is cheaper than the griefer's fee in the worst case (fee-bidding race). (3) A needs
  `REFRESH_MARGIN` > worst-case fleet-restart time, or a restart could miss the refresh window entirely.

## 🏁 #114 FINAL DESIGN — SAFEST, and it kills the liveness/yield loss outright. (user: best+safest, 2026-08-01)
### 🔴 FIRST, A CORRECTION: **revocation-keys DO NOT WORK HERE.** (I recommended deferring them; they are
   actually INAPPLICABLE, which is worse than deferred — good that it surfaced before anyone built it.)
Lightning's revocation punishes the COUNTERPARTY for broadcasting an old state — it works because the old
commitment tx is **PRIVATE to that one party**, who has a channel balance to seize.
⇒ **Here the exit bytes are DELIBERATELY PUBLISHED on-chain** (that is the whole point — no key, no tool,
  anyone can broadcast). The broadcaster is an arbitrary third party with **NOTHING AT STAKE TO PUNISH.**
⇒ **Publishing the bytes breaks the revocation threat model.** Deterrence-by-punishment cannot work when
  the broadcaster has no deposit. ⇒ Option (i) is REJECTED on mechanism, not on cost.

### ⇒ THE ONLY WAY TO INVALIDATE A SIGNED BITCOIN TX IS TO **SPEND ITS INPUT**
There is no Bitcoin construct that retracts a valid signed tx. So eliminating (not merely deterring)
premature close REQUIRES rotating the funding UTXO. That is `splice` — **already wired**.

### ✅ THE DESIGN: **SPLICE ON REFRESH** (+ A, + B as defense-in-depth)
 1. **A — refresh only near maturity** (`cltv - now < REFRESH_MARGIN`). Makes refreshes RARE for an idle
    channel, which is what makes step 2 affordable. A condition on the existing tick loop.
 2. ⭐ **SPLICE ON EVERY REFRESH** — the refresh IS a splice, not a bare re-emission. The new funding UTXO
    invalidates **every prior exit at once**, so **AT MOST ONE VALID EXIT EXISTS AT ANY TIME**, and while
    the fleet lives that one always has a FUTURE CLTV.
    ⇒ **Premature force-close becomes IMPOSSIBLE, not merely unprofitable.** The liveness/yield loss is
      ELIMINATED — which is exactly what the user asked for and what A+B alone did NOT achieve.
    ⇒ Reuses `drive_splice` + `ReconcileAction::Splice` + the rotated-holder-key derivation ALREADY wired
      for splices (`deadman_exit.rs:25-28`). **The new code is a TRIGGER, not a mechanism.**
 3. **B — mempool watch + reactive outspend** as defense-in-depth for the residual (a refresh that fails, a
    fleet restart mid-window). User approved EXTENDING the daemon to watch the mempool if needed.
⇒ **Cost is now honest and small:** one on-chain splice per REFRESH_MARGIN per idle channel — and A makes
  that period long (set it from the CLTV horizon, e.g. one splice/month, not one per heartbeat). This is the
  price of eliminating the attack outright, and it is bounded, predictable, and quantifiable per channel.
⇒ **Ties the two triggers together:** splice already fires on value-change; this adds "or the exit needs
  refreshing". ONE splice path, TWO reasons to call it — no second mechanism, no divergent code path.

### ⚠️ BUILD ORDER + WHAT TO VERIFY
 1. `REFRESH_MARGIN` must exceed worst-case fleet downtime, else a restart misses the window. Derive it from
    the CLTV horizon; assert `REFRESH_MARGIN < CLTV_HORIZON` at startup.
 2. Confirm a splice can be driven with NO value change (the reconcile arm keys off `ldk_value != amount_sats`
    — a no-op splice must be representable). **CHECK: if the splice path ASSUMES a value delta, this needs a
    real change, not just a trigger.** ⇐ the one place this could stop being "a few lines".
 3. Fee policy for the splice: it must not exceed the channel's fee accrual over the period.
 4. Then B: extend the daemon to mempool-watch; quantify the reaction window against one block.

## ✅ #114 BUILD PATH VERIFIED — `initiate_splice` EXISTS and there is a FLEET-INITIATED precedent.
**Correction to my own "trigger, not mechanism" claim — half right, and the half that was wrong matters:**
 • `drive_splice` (`channel_driver.rs:766`) is a **RECORDER**, not an initiator: it takes `splice_txid` /
   `splice_vout` and reads pubkeys *"post-SpliceLocked"*, mirroring an ALREADY-EXECUTED splice onto the EVM.
   Doc at `:759-761` confirms it consumes an outpoint *"surfaced to the bridge via `Event::SplicePending`"*.
   ⇒ Calling `drive_splice` alone would NOT rotate the UTXO. Building on that assumption would have
     produced a no-op "fix" that looked wired and changed nothing.
 • ⭐ **BUT `initiate_splice` EXISTS** (imported `:39`, used `:1242`) — and the **FEE-FLUSH** path already
   uses it for a **FLEET-INITIATED, non-LP-driven** splice: *"fee-flush: splicing accrued BTC-leg fees into
   the channel"*. It even claims an `ActiveSlot` first so *"neither the event path nor the next pass races a
   second splice for this channel"*.
⇒ 🎯 **The precedent we need already exists in production code.** Splice-on-refresh is the SAME SHAPE as
  fee-flush: a periodic, fleet-decided condition ⇒ `ActiveSlot::claim` ⇒ `initiate_splice` ⇒ the existing
  `Event::SplicePending` → `drive_splice` → EVM mirror chain completes itself.
⇒ The earlier worry ("does the splice path ASSUME a value delta?") is **RESOLVED**: fee-flush splices for a
  reason unrelated to an LP position change, so a fleet-decided splice is already a supported shape.
  ⚠️ Residual: fee-flush splices a NON-ZERO amount (accrued fees). **CONFIRM a truly ZERO-delta splice is
    representable in LDK**, or — better — **piggyback**: make the refresh splice CARRY any accrued fees, so
    it is never zero-delta AND it replaces a fee-flush that would have happened anyway. ⭐ That folds two
    on-chain events into one and makes the refresh nearly FREE in marginal cost.

### ▶️ THE BUILD (now concrete, and small)
 1. Extend the fee-flush-style periodic check with a SECOND condition: `cltv - now < REFRESH_MARGIN`.
 2. On firing: `ActiveSlot::claim` → `initiate_splice` (carrying accrued fees if any) → on `SpliceLocked`,
    emit the NEW dead-man exit against the ROTATED outpoint (`deadman_exit.rs` already derives the rotated
    holder key — `:25-28`).
 3. All prior exits die with the old UTXO ⇒ **exactly one live exit, always CLTV-future while the fleet lives.**
 4. Then B (mempool watch + reactive outspend) as defense-in-depth.
📌 LESSON REINFORCED: I called this "a trigger, not a mechanism" BEFORE reading `drive_splice`. It is a
  trigger — but on `initiate_splice`, NOT on `drive_splice`. **Naming the right function is not the same as
  reading it.** (Same family as the C10 argument-meaning error.)

## 🎯 #114 — THE EXACT EDIT FOUND. It is a ONE-CONDITION change on the fee-flush gate.
`channel_driver.rs:1208-1211` is the fee-flush's economic floor:
```rust
// Batch small fees: only splice once the owed clears the economic-grow floor.
if owed < MIN_ECONOMIC_GROW_SATS {
    return;
}
```
⇒ **THE FIX:** let a due dead-man refresh ALSO clear this gate:
```rust
// Batch small fees: only splice once the owed clears the economic-grow floor —
// UNLESS the dead-man exit needs refreshing, in which case the splice is required
// anyway (rotating the funding UTXO is the ONLY thing that invalidates prior
// pre-signed exits) and any owed fees simply ride along.
if owed < MIN_ECONOMIC_GROW_SATS && !deadman_refresh_due {
    return;
}
```
⇒ 🏆 **Everything else is REUSED, unmodified:** the `ActiveSlot` race guard, the funding-cap bound, the
  hop-wallet reserve check, `initiate_splice`, `Event::SplicePending` → `drive_splice` → the EVM mirror, and
  `deadman_exit.rs`'s rotated-holder-key derivation. **The fee PIGGYBACK is automatic** — if fees are owed
  they ride the same splice; if not, the splice happens for the refresh alone. Two on-chain events collapse
  into one whenever both are due.
⇒ This is the elegance bar the queue demands: **REUSES an existing primitive** (the whole fee-flush splice
  pipeline) and **gives a strictly better guarantee** (premature force-close becomes IMPOSSIBLE, not merely
  unprofitable) — for ONE boolean in ONE condition.

### ▶️ TO IMPLEMENT (remaining, small)
 1. Compute `deadman_refresh_due`: read the channel's current `deadManDeadline` (EVM mapping, already
    written by `emitDeadManExit`) and test `deadline - now < REFRESH_MARGIN`. The reconcile pass already
    makes EVM reads here (`btcFeesOwedSats` immediately above) — **add it to that same batched read**, do
    NOT open a second round-trip.
 2. `REFRESH_MARGIN` const: MUST exceed worst-case fleet downtime; assert `REFRESH_MARGIN < CLTV_HORIZON`
    at startup so a misconfiguration fails loudly rather than silently skipping refreshes.
 3. The funding-cap and wallet-reserve guards below the gate assume a GROW. With `owed == 0` the grow is
    zero — **verify a zero-grow splice passes those bounds** (it should: `amount + 0 <= cap`, and
    `spendable >= 0`), and that `initiate_splice` accepts a zero-value grow. ⇐ the ONE remaining unknown.
 4. Then: forge test for `emitDeadManExit` gating + the regtest broadcast proof (the ORIGINAL #114 gap),
    now testable end-to-end because the refresh path will produce a fresh exit on demand.

## ⚠️ #114 — THE LAST UNKNOWN IS REAL: does LDK accept a ZERO-grow splice?
`quid-ln/quid-hop/src/node.rs:241` — `initiate_splice(..., grow_sats: u64, funding_feerate_per_kw: u32)`
builds a `lightning::ln::funding::SpliceContribution` from confirmed hop-wallet UTXOs (sorted
most-confirmed-first to dodge coinbase immaturity) and lets LDK enforce the real fee.
⇒ For a REFRESH-ONLY splice on an idle channel with no accrued fees, `grow_sats == 0`. **Whether LDK's
  `SpliceContribution` accepts a zero contribution is version-dependent and MUST BE TESTED, NOT ASSUMED** —
  a splice-in of 0 may well be rejected as a no-op. (Fees still come from the hop wallet's contributed
  UTXOs, so the tx itself is fundable and the funding outpoint DOES rotate — the question is purely whether
  LDK permits the zero-value contribution.)
📌 Deliberately NOT assumed either way. Assuming a permissive API is the same error class as assuming
  `canRedeem`'s arity and `totalRedeemableAmount`'s parameter earlier today.

### ▶️ OPTIONS IF ZERO-GROW IS REJECTED (enumerate before coding — do not pick blind)
 (a) ⭐ **Fee-piggyback ONLY: refresh-splice only when `owed > 0`.** Costs nothing extra and is always valid.
     ⚠️ **BUT an idle channel may NEVER accrue fees** — which is precisely the exposed case — so this alone
     REINTRODUCES the hole. **Viable only combined with (b) or (c).**
 (b) **Minimal hop-funded grow** (e.g. dust+1) attributed to the HOP, not the LP. Always valid, tiny cost.
     ⚠️ Must NOT credit the LP's `checkpointSats` or it silently inflates their balance — check how the EVM
     mirror derives the LP amount from the splice before choosing this.
 (c) **Splice-OUT dust to the hop wallet** — `initiate_splice_out` / `initiate_splice_out_to` ALREADY EXIST
     (`node.rs:330`/`:367`). A tiny splice-out rotates the outpoint with no LP-balance inflation, and it is
     the MIRROR of (b) using a primitive that is already built.
     ⚠️ Shrinks the LP position by dust each refresh — bound it, or return the dust in the next fee-flush.
 ⭐ LIKELY BEST: **test zero-grow first; if rejected, (c)** — it reuses an existing splice-out primitive and
   avoids the balance-inflation trap of (b). Decide only after the LDK behaviour is KNOWN.

### ▶️ IMMEDIATE NEXT ACTION (cheap, decisive)
Write a single regtest/unit exercise calling `initiate_splice` with `grow_sats = 0` on an open channel and
observe whether LDK produces a `SpliceContribution` / `Event::SplicePending`. **That one result selects the
implementation** — and the `regtest/` harness already exists (`regtest/setup.sh`, `setup-ln.sh`) and is
already used by `testSwapIn_RealLightningHTLC`, so the fixture cost is near zero.

## ❗STATUS CORRECTION (user asked directly, 2026-08-01) — the vBTC statement is **NOT** a statement of fact.
> *"vBTC circulates and redeems swap-out-style, and every holder — original or downstream, whole or
>  fractional — holds a live exit paying them. The double claim disappears…"*
🔴 **That describes the (a+) DESIGN. It is NOT current status and will NOT be true when the dead-man refresh
  fix lands.** Being precise about what each piece does:
| piece | status | what it actually gives |
|---|---|---|
| Runtime capacity skip (C10 pt2) | ✅ LANDED, suite-verified | unrelated to vBTC |
| Dead-man REFRESH-SPLICE (#114) | 🔨 designed, edit located, **UNBUILT** | makes a superseded exit DEAD ⇒ premature force-close impossible |
| **(a+) vBTC settle-on-emission + splice-on-transfer** | 📐 **DESIGN ONLY — NOT STARTED** | **the payout FOLLOWS the token** — this is the ONLY piece that makes the quoted statement true |
⇒ The refresh fix is a **PREREQUISITE** for (a+), not a substitute: it guarantees "at most one live exit",
  but that exit still pays the **ORIGINAL** `btcRecipientOf`. **A downstream vBTC holder still gets NOTHING.**
⇒ ⚠️ **`btcRecipientOf` is LOCKED at registration** (`BTCChannels.sol:216`) — so (a+) additionally requires
  RELAXING that lock (or re-keying per splice). That is a **security-sensitive change to an intentional
  immutability**, not a small addition. **(a+) is materially bigger than "the fix".**
⇒ **Correct current status: the double claim is DOCUMENTED AND UNRESOLVED.** Option (b) (fungible + no
  downstream recourse) is NOT yet dominated in FACT — it is dominated only in the design that has not been built.

## ⚠️ CAN a/b/c ALL BE INSUFFICIENT? — YES. One COMMON-MODE failure defeats all three.
The user's instinct is right. (a)/(b)/(c) are complementary on their own axes:
 • funding cap reached ⇒ (a)/(b) (grows) FAIL, **(c) splice-OUT still works** ✅
 • no accrued fees ⇒ (a) FAILS, (b)/(c) still work ✅
 • LP-balance inflation risk ⇒ (b) constrained, (a)/(c) unaffected ✅
🔴 **BUT ALL THREE REQUIRE A SPLICE, AND EVERY SPLICE NEEDS HOP-WALLET FUNDS TO PAY THE ON-CHAIN FEE.**
`channel_driver.rs:1224-1231` already warns exactly this: *"hop wallet can't fund the fee splice above the
force-close reserve — **FUND THE HOP WALLET** (fees keep accruing safely until then)"*.
⇒ **Hop-wallet exhaustion ⇒ NO splice of ANY kind ⇒ no refresh ⇒ stale exits accumulate ⇒ the vulnerability
  returns in full.** It is an OPERATIONAL single point of failure that no choice among a/b/c can remove.
⇒ ▶️ **REQUIRED ALONGSIDE THE FIX:** (1) hop-wallet balance as a FIRST-CLASS alarm, escalating on
  `wallet_reserve_sats` proximity — the existing `warn!` is not enough, since the failure is silent to LPs;
  (2) size the reserve for `N_idle_channels × refresh_cost_per_period`, not just force-close reserve;
  (3) fall back to (B) reactive mempool outspend when a refresh CANNOT be funded — it needs a fee too, but
  only under attack, so it survives longer on a thin wallet.
📌 So the honest ceiling: **a/b/c + B reduce this to an OPERATIONAL liveness requirement (keep the hop
  wallet funded), not a cryptographic guarantee.** Only rotating-by-splice invalidates exits, and splices
  cost sats. **State that limit plainly rather than claiming the attack is eliminated unconditionally.**

## ✅ ZERO-GROW SPLICE IS **ACCEPTED BY LDK** — read from the VENDORED source this build compiles against.
`quid-ln/lib/rust-lightning/lightning/src/ln/channel.rs:7043-7062` (the contribution validator):
```rust
let contribution_amount = contribution.value();
if contribution_amount < SignedAmount::ZERO {   // splice-OUT path (negative)
    ...estimate fee, subtract...
} else {                                        // ZERO lands HERE, with SpliceIn
    check_v2_funding_inputs_sufficient(contribution_amount.to_sat(), ...)
```
⇒ **NO `> 0` guard anywhere.** A zero `SpliceIn` is non-negative ⇒ takes the `else` branch ⇒ validated ONLY
  for whether the contributed inputs cover `0 + fees` — which the hop wallet's UTXOs do (that is what they
  are contributed for). `SpliceContribution::SpliceIn { value: Amount, inputs, change_script }` accepts
  `Amount::ZERO`; excess input goes to the change output.
⇒ 🎯 **Option (a)/zero-grow WORKS. (b) hop-funded dust grow and (c) dust splice-out are NOT NEEDED in the
  common case** — they stay as documented fallbacks for the funding-cap edge only. **The design SIMPLIFIES:
  one refresh path, zero LP-balance impact, no dust accounting, no balance-inflation trap.**
📌 Chosen over the regtest for THIS question deliberately: `bitcoind` is not installed (the harness downloads
  a pinned build — a long fetch), and the vendored source answers it EXACTLY and non-probabilistically. A
  regtest run would confirm empirically; the source shows there is no rejection to confirm against.
⚠️ RESIDUAL (do not skip at build time): the interactive-tx (V2) protocol may still require at least one
  input/output from the initiator — **our splice contributes hop-wallet UTXOs for fees regardless, so this
  should hold**, but assert it in the first regtest run rather than assuming.

## ✅ RE-READ OF THE WHOLE #114 THREAD — **splice-on-refresh remains the best design.** One alternative tested and rejected:
 • ❌ **Native CLTV script-path recovery** (fund to a script with a CLTV clause the LP spends with their OWN
   key ⇒ NO pre-signed tx, NO publishing, NO staleness, NO splicing — strictly better if possible).
   **REJECTED on two independent grounds:** (1) §N established the LP's MetaMask key CANNOT produce a
   taproot Schnorr/MuSig2 signature — that constraint is WHY the pre-signed design exists; (2) the funding
   output script is dictated by LDK's channel format, so adding a dead-man leaf means forking channel
   construction and losing LN compatibility. **Not available.**
 • ❌ Revocation-keys — rejected earlier on MECHANISM (public bytes, no attacker stake).
 • ❌ Long-CLTV-no-refresh — eliminates the stale set but trades it for months of recovery latency; and
   splice-on-refresh gets a SHORT CLTV *and* no stale set, so it strictly dominates.
 ⇒ ⭐ **CONFIRMED FINAL: fee-flush-gate condition + zero-grow refresh splice + mempool reactive outspend,**
   with the honest ceiling already recorded (hop-wallet funding is an OPERATIONAL single point of failure
   that no variant removes).

## 🔴 #114 IMPLEMENTATION ATTEMPT — REVERTED. I invented 3 symbols. Real ones now identified.
Wrote the gate edit and it referenced **three things that DO NOT EXIST**:
`state.dead_man_deadline`, `DEAD_MAN_REFRESH_MARGIN_BLOCKS`, `esplora.get_height()`.
🔴 **This is EXACTLY the error class I criticised all session** (an agent citing a non-existent
  `_swapInPrep`; my own `lowWatermarkInETH()` guess). **I designed against an imagined API instead of
  reading the one that exists.** Reverted immediately — tree is clean, nothing uncompilable was left.

### ✅ THE REAL SYMBOLS (grep-verified, use THESE)
| needed | ❌ invented | ✅ actual |
|---|---|---|
| channel state struct | — | `ChannelState` — `channel_driver.rs:211` (**check its fields; it likely has NO deadline field ⇒ one must be ADDED or the deadline read from the EVM inline**) |
| bitcoin tip height | `esplora.get_height()` | `bitcoin_tip_height(esplora_url: &str)` — `recovery_broadcast.rs:157` (`GET /blocks/tip/height`), **or** `HeaderSource::tip_height(&self) -> Result<u64>` — `header_source.rs:41` ⭐ prefer this if a `HeaderSource` is already in scope |
| refresh margin const | `DEAD_MAN_REFRESH_MARGIN_BLOCKS` | **does not exist — must be DEFINED**, next to `DEAD_MAN_DELTA` in `deadman_exit.rs` so the pair is read together |
| CLTV unit | (wall clock) | **BLOCK HEIGHT** — `LockTime::from_height(tip_height + DEAD_MAN_DELTA)` (`deadman_exit.rs:135-136`). ⚠️ A time-based comparison would be a SILENT bug. |

### ⭐ LEAD WORTH FOLLOWING FIRST — `recovery_broadcast.rs` ALREADY tracks `(tip_height, cltv_deadline)`
`recovery_broadcast.rs:59`: *"carries `(tip_height, cltv_deadline)`"*. **Something already compares a stored
deadline against the tip.** ▶️ **READ `recovery_broadcast.rs` BEFORE writing anything** — the refresh
predicate may ALREADY EXIST there, in which case the fix is wiring an existing helper into
`maybe_flush_btc_fees`, not building a new one. **Do not rebuild what is already there** (I have now
re-derived documented knowledge twice on #114 — the test comment, and possibly this).

### ▶️ CORRECTED BUILD ORDER
 1. Read `recovery_broadcast.rs` fully; reuse its deadline/tip predicate if present.
 2. Read `ChannelState` (`:211`) — decide: add a `dead_man_deadline` field populated by the existing
    reconcile EVM batch, or read `deadManDeadline(bytes32)` inline next to the `btcFeesOwedSats` call.
 3. Define the margin const beside `DEAD_MAN_DELTA`; assert `MARGIN < DELTA` at startup.
 4. Apply the one-line gate change at the `MIN_ECONOMIC_GROW_SATS` early-return.
 5. `cargo check -p quid-bridge`, then the regtest (which also settles the V2 initiator-input residual).
📌 Everything ELSE about the design survived this: zero-grow is valid, the gate is the right site, the
  splice pipeline is reused. **Only my API assumptions were wrong — the design was not.**

## ✅ #114 — THE PREDICATE **ALREADY EXISTS**. Reading `recovery_broadcast.rs` first was the right call.
It is the LP/keeper-side recovery tool, and it ALREADY does every piece the refresh needs:
| existing public fn | line | what it gives us |
|---|---|---|
| `latest_exit(...)` | `:125` | the LATEST `DeadManExitEmitted` for a channel — **including its `cltv_deadline`** (log scan + ABI decode already written) |
| `bitcoin_tip_height(esplora_url) -> Result<u32>` | `:157` | the tip height (`GET /blocks/tip/height`) |
| `recover_and_broadcast(...)` | `:179` | full recovery path |
| **`watchtower_tick(...)`** | `:240` | ⭐ **A WATCHTOWER LOOP ALREADY EXISTS** |
| `all_channels_with_exits(...)` | `:217` | enumerate channels that have exits |
And `RecoverOutcome::NotMatured(u32, u64)` **already carries `(tip_height, cltv_deadline)`** — i.e. **the
exact comparison the refresh predicate needs is already computed and already returned.**
⇒ 🎯 **`refresh_due` = `latest_exit(...).cltv_deadline - bitcoin_tip_height(...) < MARGIN`.** No new log
  scanning, no new ABI decode, no new HTTP call to write. **Wiring, not building** — as suspected.
⇒ ⭐ **`watchtower_tick` is ALSO the natural home for Fix B (reactive mempool outspend)** — the loop that
  would detect a stale broadcast already exists. **B is likely far cheaper than estimated.** ▶️ READ IT
  before designing B (I have now been wrong twice on this item by not reading first).
📌 **THIRD time on #114 that the thing I was about to build already existed** (the test comment spelled out
  the mechanism; `initiate_splice` existed; now the whole predicate + a watchtower). **STANDING CORRECTION
  FOR THIS CODEBASE: search for the capability BEFORE designing it.** The repo is far more complete than my
  priors keep assuming, and every one of these was findable with a single grep.

### ▶️ THE BUILD IS NOW SMALL AND FULLY SPECIFIED
 1. In `maybe_flush_btc_fees` (`channel_driver.rs:1166`), compute `refresh_due` from `latest_exit` +
    `bitcoin_tip_height` (both `pub`, same crate — import from `crate::recovery_broadcast`).
    ⚠️ Both are BLOCKING (`reqwest`-style sync) — the surrounding fn is `async`, and the existing EVM read
    there already uses `tokio::task::spawn_blocking`. **Wrap these the same way** — do not block the runtime.
 2. Define the margin const beside `DEAD_MAN_DELTA` in `deadman_exit.rs`; assert `MARGIN < DELTA` at startup.
 3. One-line gate change: `if owed < MIN_ECONOMIC_GROW_SATS && !refresh_due { return; }`.
 4. `cargo check -p quid-bridge` → regtest (settles the V2 initiator-input residual).
 5. Then read `watchtower_tick` and wire Fix B into it.

## ⚖️ #114 REFINEMENT — reuse `latest_exit`? **NO.** Cheaper primitive already exists. (Reuse is not always right.)
`recovery_broadcast.rs:125` — `latest_exit(rpc_url, btc_channels, channel_id) -> Result<Option<RecoveredExit>>`
issues `eth_getLogs` with **`"fromBlock": "0x0"`** — a FULL-HISTORY log scan, then takes `arr.last()`.
⇒ Correct and cheap for its own use (a ONE-OFF LP/keeper recovery). **Wrong for the refresh predicate**,
  which runs **per channel, per reconcile tick** — that would be a full log scan per channel forever.
⇒ ⭐ **USE `deadManDeadline(bytes32)` INSTEAD — an O(1) `eth_call`.** The mapping already exists
  (`BTCChannels.sol:271`, written by `emitDeadManExit`) and is *precisely* the cheap accessor for this.
  It also drops into the EXISTING pattern in `maybe_flush_btc_fees` — the same `eth_call_raw` +
  `spawn_blocking` shape already used two lines above for `btcFeesOwedSats(address)`, with `cid` as the
  32-byte arg (no left-padding needed, unlike the `address` case).
📌 **Nuance worth keeping:** "reuse what exists" is the right default, but **reuse the RIGHT primitive** —
  `latest_exit` and `deadManDeadline` return the same number at wildly different costs. The three earlier
  #114 lessons said *search before building*; this one adds *and check the cost model of what you find*.
⇒ `bitcoin_tip_height(esplora_url) -> Result<u32>` (`:157`) IS the right reuse — a single
  `GET /blocks/tip/height`, and it is the SAME source `deadman_exit.rs` uses to SET the CLTV, so the two
  heights are guaranteed commensurate. **Reuse that one.**

### ▶️ FINAL SPEC (every symbol grep-verified; nothing invented)
```rust
// in maybe_flush_btc_fees (channel_driver.rs:1166), beside the btcFeesOwedSats read:
//   deadline: eth_call_raw(rpc, cfg.btc_channels, "deadManDeadline(bytes32)", Some(&cid)) -> u64
//   tip:      crate::recovery_broadcast::bitcoin_tip_height(&esplora_url)?          -> u32
//   both are BLOCKING -> wrap in tokio::task::spawn_blocking (same as the owed read)
let refresh_due = deadline != 0 && deadline.saturating_sub(tip as u64) < DEAD_MAN_REFRESH_MARGIN_BLOCKS;
if owed < MIN_ECONOMIC_GROW_SATS && !refresh_due { return; }
```
⚠️ `deadline == 0` ⇒ no exit ever emitted ⇒ **do NOT treat as "due"** (`0.saturating_sub(tip) == 0 < MARGIN`
  would be TRUE and force a splice on every channel that never had an exit). **That guard is load-bearing.**
⚠️ Define `DEAD_MAN_REFRESH_MARGIN_BLOCKS` beside `DEAD_MAN_DELTA` (`deadman_exit.rs`); assert
  `MARGIN < DELTA` at startup or refreshes fire every tick.

## 🔴 #114 COST BLOCKER FOUND — `DEAD_MAN_DELTA_BLOCKS = 144` (~1 DAY) ⇒ refresh-splice would be ~DAILY per channel.
`deadman_exit.rs:56`: `pub const DEAD_MAN_DELTA_BLOCKS: u32 = 144;` — the exit's CLTV is set to
`tip + 144` blocks ≈ **24 hours**. The doc at `:35` calls Δ *"a policy"* (i.e. TUNABLE).
⇒ With splice-on-refresh, a refresh must occur before each CLTV matures ⇒ **~ONE ON-CHAIN SPLICE PER IDLE
  CHANNEL PER DAY.** At any realistic BTC-LP count that is **almost certainly uneconomic** — and it would
  consume the hop wallet (the common-mode failure already identified) far faster than fees accrue.
🔴 **My earlier "one splice/month, nearly free at the margin" estimate was WRONG** — it assumed a long Δ
  without reading the constant. **Cost was the one axis I never checked**, and it is the axis that decides
  whether the design ships.

### ⚖️ THE REAL TRADE-OFF (this is a USER DECISION — it is a policy, not a bug)
Δ sets BOTH the post-death recovery latency AND the refresh (⇒ splice) frequency. They are the SAME knob:
| Δ | LP recovery after fleet death | refresh-splice cost per idle channel |
|---|---|---|
| **144 (~1 day, TODAY)** | ⭐ fast — LP recovers in ~1 day | 🔴 ~1 on-chain splice/DAY — likely prohibitive |
| 1008 (~1 week) | ~1 week | ~1 splice/week |
| **4320 (~30 days)** | 🔴 slow — LP waits a month | ⭐ ~1 splice/month — affordable, and fee-flush often covers it |
⇒ **Today's Δ was chosen for FAST RECOVERY, when refreshes were FREE (bare event emissions).** Making the
  refresh a SPLICE changes the economics of that choice completely — **Δ must be re-decided alongside it.**

### ▶️ OPTIONS (do NOT pick unilaterally — this trades user funds-access latency against operating cost)
 (a) **Raise Δ to ~30 days + splice-on-refresh.** Attack eliminated; cost ~monthly. **Cost: LPs wait up to a
     month to recover if the fleet dies.** ⚠️ That is the LP's own capital — the delay must be disclosed.
 (b) **Keep Δ = 144, DROP splice-on-refresh, rely on (B) reactive mempool outspend alone.** No periodic
     cost; keeps fast recovery. **Weaker: griefing is only DEFEATED REACTIVELY, not made impossible** —
     back to an economic/liveness guarantee. The existing `watchtower_tick` makes this the CHEAPEST path.
 (c) **Hybrid ⭐: Δ = 144 normally; splice-refresh ONLY when a splice is happening anyway** (fee-flush) —
     i.e. free rides only. Between them, rely on (B). **Strictly better than (b) at ZERO extra cost**, since
     every fee-flush already rotates the UTXO and kills all stale exits for free.
 ⇒ **RECOMMEND (c) + (B) now** (zero new on-chain cost, real reduction in stale-exit lifetime), and put (a)
   to the user as a separate, explicit policy question about recovery latency.
📌 LESSON: I validated the mechanism (zero-grow OK), the call site, the symbols, and the reuse — but never
  the FREQUENCY. **A per-tick predicate's cost is set by the constant that drives it; read that constant
  BEFORE estimating cost.**

## ⭐⭐ #114 — A MATERIALLY BETTER DESIGN: the **SHARED FRESHNESS UTXO**. O(1) global, not O(n) per channel.
**First, the hybrid (c) is WEAKER than I presented — retracting the recommendation.** It refreshes only when
a fee-flush already splices. **An IDLE channel accrues no fees ⇒ never fee-flushes ⇒ never refreshes.** That
is EXACTLY the exposed population, so (c) barely improves the case it exists to fix. I recommended it one
turn after correctly identifying that idle channels are the whole problem.

### THE INSIGHT
Cost was high because invalidation was tied to the CHANNEL's funding UTXO ⇒ one splice PER CHANNEL. But a
Bitcoin tx is invalidated if **ANY** of its inputs is spent. So:
⇒ **Give every pre-signed exit a SECOND, tiny input: a fleet-controlled "FRESHNESS" UTXO, SHARED across all
  channels.** Signed with SIGHASH_ALL (already the case), so the exit is valid only while BOTH inputs live.
⇒ **To invalidate EVERY stale exit for EVERY channel at once, the fleet spends that ONE freshness UTXO** —
  a single small self-send — then creates the next one and re-emits exits against it.
⇒ 🎯 **Cost collapses from O(n_channels) SPLICES PER PERIOD to ONE SMALL TX PER PERIOD, GLOBALLY.** Re-emitting
  the per-channel bytes stays EVM-side (event gas), which is cheap and already how the heartbeat works.
⇒ **Recovery still works:** if the fleet DIES, it never spends the freshness UTXO ⇒ the last exits stay valid
  ⇒ they mature at their CLTV ⇒ anyone broadcasts. **The dead-man property is preserved exactly.**
⇒ **Griefing dies:** a stale exit references a SPENT freshness UTXO ⇒ **consensus-invalid, unbroadcastable.**
  Not deterred — IMPOSSIBLE, the same strength splice-on-refresh gave, at ~1/n the cost.
⇒ **Δ = 144 (~1 day) can STAY**, so fast LP recovery is preserved. **The policy trade-off I was about to put
  to the user DISSOLVES** — we no longer pay per-channel for a short Δ.

### ⚠️ VERIFY BEFORE BUILDING (do not repeat this turn's error — check the cost/mechanism BOTH)
 1. **Does adding a 2nd input break anything?** The exit is a fleet-crafted BIP341 key-path spend
    (`deadman_exit.rs:12-23`), NOT an LDK commitment tx — so extra inputs should be fine. **CONFIRM** the
    signer signs multi-input (`taproot_signer.rs`) and that the sighash covers BOTH inputs.
 2. **Fee/dust:** the freshness UTXO must exceed dust and fund its own share; it comes from the hop wallet
    ⇒ the wallet-funding single-point-of-failure REMAINS (but now costs ~1 tx/period TOTAL, not per channel —
    a far weaker demand, which materially de-risks that failure mode too).
 3. **Blast radius:** one shared UTXO invalidates ALL channels' exits simultaneously — that is the FEATURE,
    but it means a BOTCHED rotation (spend without re-emitting) leaves EVERY LP with no valid exit until the
    next emission. **Re-emit FIRST, then spend the old freshness UTXO** — ordering is load-bearing.
 4. Per-channel exits must be re-signed each rotation (they reference the new UTXO). That is signing work,
    not on-chain cost — confirm the enclave can sign N exits per period at acceptable latency.
📌 **This is the answer to "are you sure it's the best cost/benefit?" — I was NOT. The right question was
  "must invalidation be per-channel?" and the answer is NO.**

## 🗺️ GRAPH USED (it DOES cover Rust) — files to touch for the FRESHNESS-UTXO design.
**Correcting my own graph reads (twice wrong before it worked):** edges live under **`links`** (not
`edges`), and the path field is **`source_file`** (not `file`). With the right keys: **57,511 links,
12,953 `.rs` nodes** — the graph is fully usable for Rust.
📌 And it independently CONFIRMS the earlier proof: **`.sol` nodes = 0.** Solidity is absent from a graph
  built over this very repo — the Solidity work stays manual, as established.

**Coupling query — neighbours of `deadman_exit` + `taproot_signer` (excluding vendored `lib/`):**
| links | file |
|---|---|
| **268** | `quid-ln/src/taproot_signer.rs` ⭐ structural centre |
| 46 | `quid-ln/src/deadman_exit.rs` |
| 2 | `quid-ln/src/validating_signer.rs` |
⇒ The change is **concentrated**, not spread — `taproot_signer.rs` is where a 2nd input must be handled.

### ▶️ FILES TO TOUCH (graph-informed + grep-verified; NOTE the two crates)
⚠️ `deadman_exit.rs` and `taproot_signer.rs` EXIST IN **BOTH** `quid-ln/quid-ln/src/` **AND**
  `quid-ln/quid-bridge/src/` (confirmed by `find`). **Determine which is live before editing** — editing the
  wrong copy is a silent no-op, the same failure class as the `mockCall` on a missing signature.
 1. **`taproot_signer.rs`** — sign a 2-input tx; the sighash MUST commit to BOTH inputs (SIGHASH_ALL over
    all prevouts — BIP341 taproot key-path already commits to all prevouts, **verify this**). Highest
    coupling ⇒ highest regression risk ⇒ test first.
 2. **`deadman_exit.rs`** — build the exit with the freshness input; carry its outpoint alongside `cltv`;
    re-sign on rotation. (`DEAD_MAN_DELTA_BLOCKS = 144` can STAY.)
 3. **`recovery_broadcast.rs`** — a broadcaster must know the exit needs the freshness UTXO unspent;
    `RecoverOutcome` likely needs a `FreshnessSpent` variant so a stale exit fails LOUDLY, not confusingly.
 4. **hop wallet / UTXO management** — create + rotate the freshness UTXO (ONE per period, globally).
 5. **`validating_signer.rs` / `evm_validating_signer.rs`** — the signing-policy gate may reject an unknown
    2nd input; check its prevout validation.
 6. ✅ **`channel_driver.rs` NEEDS NO CHANGE** — the freshness design REPLACES splice-on-refresh entirely,
    so the fee-flush gate edit is **DROPPED**. **The simpler design touches FEWER files.**

### ▶️ TEST PLAN (in order, cheapest first)
 1. Unit: build + sign a 2-input exit; assert the signature verifies and that **mutating either prevout
    invalidates it** — that single assertion IS the security property.
 2. Unit: assert a rotation makes prior exits fail validation.
 3. `cargo check` / `cargo test -p` the live crate.
 4. Regtest: broadcast a fresh exit after CLTV (accepted) and a stale one (rejected as missing-input) —
    the end-to-end proof, and it settles the ORIGINAL #114 broadcast gap too.

## ✅ "WHICH COPY IS LIVE?" — **BOTH.** They are COMPLEMENTARY HALVES, not duplicates.
Both `deadman_exit.rs` files are exactly **293 lines** — a coincidence that nearly read as copy-paste. They
differ on **536 of 586 lines**, i.e. they are almost entirely DIFFERENT code:
| crate | imports | role |
|---|---|---|
| `quid-ln/quid-ln/src/deadman_exit.rs` | `bitcoin::{LockTime, Prevouts, SighashCache, TapSighashType, TxIn, TxOut, Witness…}` | ⭐ **the TX BUILDER + 2-signer pre-sign orchestrator** — constructs and signs the exit |
| `quid-ln/quid-bridge/src/deadman_exit.rs` | `std::sync::Arc`, `std::time::Duration`, tokio | ⭐ **the DAEMON** — the periodic task that drives emission/heartbeat |
⇒ `taproot_signer.rs` lives in `quid-ln/quid-ln` only, alongside the BUILDER — consistent with the graph's
  268-link coupling between them.
⇒ **No silent-no-op risk after all, but the split DOES divide the work cleanly** — and had I edited by
  filename alone I would have put builder changes in the daemon crate.
📌 Two same-sized files with the same name in one repo is exactly the "near-identical names make finished
  and unfinished work indistinguishable" trap. **Line count is not identity — diff before concluding.**

### ▶️ WORK SPLIT FOR THE FRESHNESS-UTXO CHANGE (now unambiguous)
 **`quid-ln/quid-ln/` (builder crate) — the CRYPTO half:**
  1. `deadman_exit.rs` — add the freshness `TxIn`; extend `Prevouts` to BOTH inputs (it already imports
     `Prevouts`/`SighashCache`/`TapSighashType`, so the multi-input sighash machinery is ALREADY THERE —
     ⚠️ confirm whether `Prevouts::All` vs `Prevouts::One` is used; **`All` is required** for the property).
  2. `taproot_signer.rs` — sign input #1 as well as #0 (268-link coupling ⇒ test first).
 **`quid-ln/quid-bridge/` (daemon crate) — the ORCHESTRATION half:**
  3. `deadman_exit.rs` — hold the current freshness outpoint; on rotation **re-emit ALL channels FIRST, then
     spend the old UTXO** (ordering is load-bearing).
  4. `recovery_broadcast.rs` — a `FreshnessSpent` outcome so a stale exit fails loudly.
  5. hop-wallet UTXO management — create/rotate ONE freshness UTXO per period, globally.
 ✅ `channel_driver.rs` — **UNCHANGED** (splice-on-refresh is dropped entirely).

### ▶️ IMMEDIATE NEXT: the single decisive check
Read `Prevouts::` usage in `quid-ln/quid-ln/src/deadman_exit.rs`. **BIP341 key-path signing with
`Prevouts::All` commits to EVERY input's prevout** ⇒ spending the freshness UTXO invalidates the signature
**with no signer change at all**. If it is already `All`, step 2 shrinks to nearly nothing and the whole
design may need only the builder + daemon halves.

## 🏆 #114 FRESHNESS-UTXO — **THE SECURITY PROPERTY IS FREE.** BIP341 already gives it.
`quid-ln/quid-ln/src/deadman_exit.rs:95-109`:
```rust
let sh = SighashCache::new(exit_tx).taproot_key_spend_signature_hash(
    0,
    &Prevouts::All(std::slice::from_ref(&funding_prevout)),   // ALL — but TODAY only ONE prevout
    TapSighashType::Default,
)?;
```
⇒ **`Prevouts::All` + `TapSighashType::Default` (SIGHASH_DEFAULT ≈ ALL) commits the signature to EVERY
  input's prevout** — BIP341 hashes `sha_prevouts`/`sha_amounts`/`sha_scriptpubkeys` across ALL inputs.
⇒ 🎯 **So the moment the exit carries a 2nd (freshness) input, the signature ALREADY depends on it.
  Spending that UTXO makes every stale exit CONSENSUS-INVALID — automatically. No crypto change, no new
  signing scheme, no revocation protocol.** The property this entire investigation chased is a FREE
  consequence of the sighash mode the code ALREADY uses.
⇒ ✅ **`taproot_signer.rs` needs NO change** — it signs a 32-byte digest that now simply commits to two
  prevouts. **The 268-link, highest-regression-risk file is UNTOUCHED** — the elegant framing removes that
  risk rather than testing around it.

### ⇒ THE WHOLE CHANGE (smallest correct form — no compromises)
 1. `quid-ln/quid-ln/deadman_exit.rs` (BUILDER): add the freshness `TxIn`; pass **BOTH** prevouts to
    `Prevouts::All` (today a 1-element slice via `from_ref`). ⚠️ **Prevout ORDER must match input order** —
    a mismatch yields a signature that commits to the wrong thing while still looking valid.
 2. `quid-ln/quid-bridge/deadman_exit.rs` (DAEMON): hold + rotate the freshness outpoint; **re-emit ALL
    channels BEFORE spending the old UTXO** (ordering is load-bearing).
 3. `recovery_broadcast.rs`: add a `FreshnessSpent` outcome so a stale exit fails LOUDLY.
 4. hop wallet: create/rotate ONE freshness UTXO per period, GLOBALLY.
 5. `channel_driver.rs`, `taproot_signer.rs`, `validating_signer.rs`: **UNCHANGED.**
⇒ **Final: ONE small on-chain tx per period globally · Δ=144 fast recovery PRESERVED · griefing IMPOSSIBLE
  (not deterred) · highest-risk file untouched.** Strictly dominates splice-on-refresh (O(n) daily splices),
  the hybrid (never fires on idle channels — the exposed case), and revocation-keys (inapplicable).

### ▶️ NEXT: the test that IS the security property
Builder-crate unit test: build a 2-input exit, sign, assert it verifies; then mutate the freshness prevout
(outpoint / value / spk) and assert **the sighash CHANGES**. That one assertion proves spending the
freshness UTXO invalidates every stale exit — the whole fix, provable WITHOUT a regtest. Then regtest for
end-to-end broadcast (fresh accepted / stale rejected), closing the ORIGINAL #114 verification gap.

## ✅✅ #114 — THE FRESHNESS-UTXO PREMISE IS **PROVEN BY A PASSING TEST**, not by reasoning.
Added `sighash_commits_to_every_prevout_not_just_input_zero` to
`quid-ln/quid-ln/src/deadman_exit.rs`'s existing `mod tests`, and it **PASSES**:
```
test deadman_exit::tests::sighash_commits_to_every_prevout_not_just_input_zero ... ok
test result: ok. 1 passed; 0 failed  (cargo test -p quid-ln --lib)
```
**What it asserts:** build a 2-input exit (input 0 = channel funding, input 1 = freshness UTXO) via the
REAL `build_deadman_exit_tx`, then take the BIP341 key-path sighash for **input 0** twice, changing ONLY
the **second** prevout's value. **The digests differ** ⇒ `Prevouts::All` + `SIGHASH_DEFAULT` commits to
EVERY prevout ⇒ **spending the freshness UTXO invalidates an exit signed over input 0.**
⇒ 🎯 **That IS the security property of the whole design**, and it is now executable and regression-guarded.
  The test names #114 and says explicitly that if it ever fails the design is void — so a future
  rust-bitcoin/sighash change cannot silently erode the guarantee.
⇒ Written to FAIL LOUDLY rather than to pass: it isolates a SINGLE variable (only the freshness prevout's
  value changes; input 0 is byte-identical), so a pass cannot be an artifact of some other difference.
📌 Proven BEFORE touching production code — the design assumption was verified against the real API, so the
  builder change can now be made knowing its foundation holds. (Contrast with my earlier attempt, which
  wrote production code against three imagined symbols.)

### ▶️ REMAINING (unchanged, now de-risked)
 1. Builder: add the freshness `TxIn` + pass BOTH prevouts (⚠️ order must match input order).
 2. Daemon: hold/rotate the outpoint; **re-emit ALL channels BEFORE spending the old UTXO**.
 3. `recovery_broadcast.rs`: `FreshnessSpent` outcome so a stale exit fails loudly.
 4. Hop wallet: one freshness UTXO per period, globally.
 5. Regtest end-to-end (fresh accepted / stale rejected) — closes the ORIGINAL #114 broadcast gap.

## 🎯 #114 — THE PLUMBING IS **ONE SIGNATURE, ONE CALLER.** Call graph verified.
| symbol | visibility | callers OUTSIDE the builder file |
|---|---|---|
| `build_deadman_exit_tx` | pub | **none** (internal to the builder) |
| `deadman_exit_sighash` | pub | **none** (internal to the builder) |
| `finalize_exit_tx` | pub | **none** |
| ⭐ `presign_deadman_exit` | pub | **exactly ONE**: `quid-ln/quid-bridge/src/deadman_exit.rs:144` |
⇒ The other three are effectively private-by-use, so **the freshness input can be threaded through them
  freely without touching any other crate.** Only `presign_deadman_exit`'s signature is a cross-crate
  surface, and it has a SINGLE call site.
⇒ (`quid-hop/src/evm_codec.rs:615` is a doc-comment REFERENCE only — not a call. Verified, not assumed.)

### ▶️ THE STAGED BUILD (each stage independently compilable + testable — not a compromise, a sequence)
 **Stage 1 — plumbing (builder crate only):** add `freshness: Option<(OutPoint, TxOut)>` to
   `build_deadman_exit_tx` / `deadman_exit_sighash` / `presign_deadman_exit`; when `Some`, push the 2nd
   `TxIn` and pass BOTH prevouts to `Prevouts::All` **in input order**. Daemon passes `None` ⇒ **behaviour
   byte-identical to today** ⇒ the existing `exit_tx_shape_is_cltv_keypath` test still passes unchanged,
   proving the stage is inert.
 **Stage 2 — the freshness UTXO is REAL:** hop wallet creates/rotates one globally; daemon passes `Some`.
 **Stage 3 — rotation ordering:** re-emit ALL channels, THEN spend the old UTXO (load-bearing).
 **Stage 4 — `FreshnessSpent`** outcome in `recovery_broadcast.rs` so a stale exit fails loudly.
 **Stage 5 — regtest:** fresh accepted / stale rejected ⇒ closes the ORIGINAL #114 broadcast gap.
⚠️ `Option` here is the HONEST type, not a hedge: a channel opened before the first rotation genuinely has
  no freshness UTXO, and stage 2 must not pretend otherwise. It also keeps every stage green.
📌 The security property is ALREADY PROVEN (`sighash_commits_to_every_prevout_not_just_input_zero`, passing),
  so stages 1-5 are plumbing against a verified foundation — the reverse of my earlier attempt, which wrote
  plumbing first against imagined symbols and had to be reverted.

## ✅ #114 STAGE 1 LANDED — freshness input plumbed through the builder. 10/10 dead-man tests green.
`build_deadman_exit_tx(..., freshness: Option<OutPoint>)`: input 0 is ALWAYS the funding outpoint; the
freshness input is APPENDED as input 1. Comment records that the order is **load-bearing** — the sighash's
`Prevouts::All` slice must be built in the SAME order or the signature commits to the wrong prevout while
still looking well-formed.
```
test deadman_exit::tests::sighash_commits_to_every_prevout_not_just_input_zero ... ok
test deadman_exit::tests::exit_tx_shape_is_cltv_keypath ... ok
test deadman_exit::tests::sighash_changes_with_cltv ... ok
test deadman_exit::tests::finalize_assembles_64byte_witness ... ok
test result: ok. 10 passed; 0 failed
```
⇒ **`None` reproduces the original single-input tx byte-for-byte** — proven by `exit_tx_shape_is_cltv_keypath`
  passing UNCHANGED (it asserts `tx.input.len() == 1`). **Stage 1 is inert**, exactly as designed.
⇒ The premise test now builds through the **REAL** freshness param (not a hand-pushed `TxIn`), so it covers
  the builder wiring AND the sighash property, and additionally asserts input 0 is still the funding
  outpoint — catching an ordering regression directly.
⇒ 5 call sites updated (1 in `presign_deadman_exit`, 4 in tests). **The compiler found every one** — the
  value of changing an arity rather than adding an overload or a defaulted field.

### ▶️ REMAINING STAGES (2-5) then the ROADMAP
 2. Hop wallet creates/rotates ONE freshness UTXO globally; daemon passes `Some`.
 3. Rotation ordering: re-emit ALL channels BEFORE spending the old UTXO.
 4. `FreshnessSpent` outcome in `recovery_broadcast.rs` (fail loudly).
 5. Regtest: fresh accepted / stale rejected ⇒ closes the ORIGINAL #114 broadcast-verification gap.

## 📍 ROADMAP AFTER #114 (user asked — confirming the order)
 1. **#114 stages 2-5** (in flight).
 2. ⭐ **VERIFY THE 33 open-marked items** — 7 of 40 verified; **33 outstanding**. Now confirmed MANUAL
    (graphify has no Solidity parser — proven, and re-confirmed by the graph containing 0 `.sol` nodes).
    Audit by STRUCTURE (`^function`, `^interface`, `^contract`), never by type name.
 3. **Deep dedup + necessity pass** — incl. §A.52 interface minimisation (user: *"only the minimum quantity
    of interfaces we need"*), one declaration per interface in a shared file.
 4. Then Echidna.
📌 The Rust graph IS usable (57,511 links) and already paid off on #114 — **use it for the Rust half of the
  dedup pass**, and fall back to structural greps for Solidity.

## ✅ #114 STAGE 1 COMPLETE — sighash plumbed too, with the ordering invariant GUARDED IN CODE. 10/10 green.
`deadman_exit_sighash(..., freshness_prevout: Option<TxOut>)` builds the `Prevouts::All` slice in the SAME
order the builder appends inputs (funding = 0, freshness = 1), and now **enforces the invariant instead of
documenting it**:
```rust
if prevouts.len() != exit_tx.input.len() {
    return Err(DeadManExitError::Sighash);
}
```
⇒ The failure this guards is the nastiest one available here: a prevout/input MISMATCH produces a signature
  that **verifies against itself but commits to the wrong prevout** — silent, and unrecoverable once the
  bytes are emitted on-chain. **A comment would not have caught it; the check does.** This is the
  "minimise clamps that give false safety" rule inverted — the guard is on a REAL invariant with a silent
  failure mode, which is exactly where a check earns its place.
⇒ All 5 sighash/builder call sites updated; `cargo test -p quid-ln --lib deadman`: **10 passed, 0 failed.**
⇒ `exit_tx_shape_is_cltv_keypath` STILL passes unchanged ⇒ the `None` path is byte-identical to before ⇒
  **the whole of stage 1 remains inert in production.**

### ▶️ STAGE 1 REMAINDER + NEXT
 • `presign_deadman_exit` (the ONE cross-crate surface) still needs the `Option<(OutPoint, TxOut)>` param
   threaded to the builder + sighash — its single caller (`quid-bridge/deadman_exit.rs:144`) passes `None`.
 2. Hop wallet: create/rotate ONE freshness UTXO globally; daemon passes `Some`.
 3. Rotation ordering: re-emit ALL channels BEFORE spending the old UTXO.
 4. `FreshnessSpent` in `recovery_broadcast.rs` (fail loudly).
 5. Regtest end-to-end ⇒ closes the ORIGINAL #114 broadcast gap.

## 📌 RULE NUANCE BANKED (user-confirmed, 2026-08-01) — when a check EARNS its place
The standing rule *"minimise clamps that give a false sense of safety"* has an inverse, now saved as memory
`guard-real-invariants-with-silent-failures`:
 • ❌ DELETE a tolerance/clamp/skip that makes a SYMPTOM vanish while the defect survives.
 • ✅ KEEP a check on a REAL invariant whose violation would be **SILENT and plausible-looking**.
**The discriminator is whether the failure ANNOUNCES ITSELF.** The #114 sighash guard qualifies: a
prevout/input mismatch produces a signature that verifies against itself but commits to the wrong prevout —
nothing errors, the bytes look valid, and it is unrecoverable once emitted on-chain.
**Corollary:** prefer a CHECK over a COMMENT whenever the invariant is machine-checkable — a comment
describes past intent and cannot fail (this session had FIVE stale comments mislead conclusions).

## ✅ #114 STAGE 1 FULLY LANDED — cross-crate surface threaded. Builder crate 10/10 green.
`presign_deadman_exit(..., freshness: Option<(OutPoint, TxOut)>)` now forwards the outpoint to the builder
and the prevout to the sighash, in matching order. Its ONE caller
(`quid-ln/quid-bridge/src/deadman_exit.rs:144`) passes `None` with a comment explaining that stage 2 flips
it to `Some`. **`cargo test -p quid-ln --lib deadman`: 10 passed, 0 failed.**
⚠️ **Rust gotcha hit and fixed:** `///` doc comments **cannot** be applied to function parameters
  (`error: documentation comments cannot be applied to function parameters`) — used `//` instead.

### 🔴 ENVIRONMENTAL BLOCKER (pre-existing, NOT caused by this change)
`cargo check -p quid-bridge` fails BEFORE reaching our code:
```
error[E0432]: unresolved import `sev::firmware::guest::Firmware`  --> quid-cvm/src/lib.rs:11:59
error: could not compile `quid-cvm` (lib)
```
⇒ `quid-cvm` depends on **AMD SEV, which is Linux-only** — it cannot build on this macOS machine at all.
⇒ **The DAEMON crate therefore cannot be compile-verified here.** The builder crate (`quid-ln`) — where all
  the crypto and all the tests live — builds and tests fine, so stage 1's substance IS verified.
⇒ ⚠️ **The daemon-side `None` edit is UNVERIFIED BY COMPILER.** It is a single added argument at a call
  site whose signature I changed, so it is low-risk, but **say so rather than implying it is green.**
▶️ **Verify `quid-bridge` on Linux** (or with the `quid-cvm` dependency stubbed/feature-gated) before
  treating stage 1 as complete end-to-end. **This ALSO blocks stages 2-4**, which are all daemon-side —
  worth resolving FIRST, since the remaining #114 work cannot be compiled on this machine otherwise.
📌 Candidate fix worth checking: feature-gate `quid-cvm`'s SEV import behind `#[cfg(target_os = "linux")]`
  so the workspace at least CHECKS on macOS. That would unblock all remaining daemon work locally.

## ✅✅ BLOCKER SOLVED — Linux builds via DOCKER. `quid-bridge` COMPILES CLEAN with the stage-1 change.
The macOS/SEV blocker is gone: `rust:1.90` is already cached locally, so no download is needed.
```
docker run --rm -v "$PWD":/w -w /w/quid-ln -e CARGO_TARGET_DIR=/tmp/t rust:1.90 cargo check -p quid-bridge
  Checking quid-ln v0.0.0 ... Checking quid-hop ... Checking quid-bridge v0.1.0
  Finished `dev` profile [unoptimized + debuginfo] target(s) in 2m 05s
```
⇒ **The daemon-side `None` argument is now COMPILER-VERIFIED, not assumed.** Stage 1 is complete
  end-to-end: builder crate 10/10 tests green (native) + daemon crate clean (Linux container).
⇒ 🔓 **This UNBLOCKS stages 2-4**, which are all daemon-side and were otherwise unwritable-and-unverifiable
  on this machine. **Use this command for every remaining #114 daemon change.**
📌 `CARGO_TARGET_DIR=/tmp/t` keeps container artifacts OUT of the macOS `target/` — avoids clobbering the
  native build and avoids a slow rebuild dance between the two toolchains.
📌 The user had Docker + VirtualBox available the whole time; I had written the blocker up as a hard
  environmental limit. **ASK / CHECK WHAT TOOLING EXISTS before declaring something unverifiable.**

## 🧹 DEAD CODE FOUND BY THE LINUX BUILD (feeds the DEDUP pass)
```
warning: method `create_sweep_tx` is never used  --> quid-ln/src/wallet.rs:1182:19
```
⇒ `OnchainWallet::create_sweep_tx` is `pub(crate)` and **has NO callers** — dead by the compiler's own
  reachability analysis, not by my grep. Violates the standing *"no code should be unreachable"* rule.
⚠️ **Do NOT delete blind:** check first whether stage 2 (freshness-UTXO create/rotate) actually WANTS a
  sweep primitive — this may be a half-built piece of exactly the wallet plumbing #114 stage 2 needs. If so
  it gets USED, not removed. **Decide when stage 2 is designed, not before.**
📌 The compiler is a FREE dead-code oracle for Rust and it is authoritative where my greps were not. Run the
  Linux check with warnings surfaced as part of the dedup pass — **for the Rust half, `cargo check` +
  `#[warn(dead_code)]` beats any manual sweep.**

## 🔍 `create_sweep_tx` VERDICT — genuinely dead, and NOT the stage-2 plumbing. (Checked before deleting.)
`wallet.rs:1178-1195`: *"Create a sweep transaction that **drains all funds** from the wallet to
`dest_address`"* — BDK `drain_wallet` + `drain_to`.
⇒ **That is an EVACUATION utility, not what stage 2 needs.** Stage 2 needs the opposite shape: create ONE
  SMALL self-send UTXO, then later spend THAT SPECIFIC OUTPOINT. A drain-everything primitive is unusable
  for it.
⇒ ✅ **So it stays dead** — but it is a plausible deliberate feature (emergency wallet evacuation) that was
  built and never wired. **USER DECISION for the dedup pass: wire it to an evacuation path, or delete it.**
  ⚠️ Do NOT auto-delete: "no callers" + "obviously an emergency tool" is exactly the shape of something
  removed and then missed when it is needed. Flag, do not sweep.

### ▶️ STAGE 2 — the REAL wallet APIs to use (grep-verified, nothing invented)
| need | API | line |
|---|---|---|
| create the freshness UTXO (small self-send) | `create_onchain_send(...)` | `wallet.rs:1134` |
| find / track it afterwards | `get_utxos() -> Vec<bdk_wallet::LocalOutput>` | `:873` |
| (already used by `initiate_splice` for fee inputs) | `get_utxos()` filtered on `chain_position.is_confirmed()` | `node.rs` |
⇒ `get_utxos()` returning `LocalOutput` gives the outpoint AND value ⇒ **exactly the `(OutPoint, TxOut)`
  pair `presign_deadman_exit` now takes.** The stage-1 signature already matches the wallet's own shape —
  no adapter needed.
⇒ **Rotation = `create_onchain_send` to our own address (new UTXO) → re-emit ALL exits against it → THEN
  spend the previous one.** Ordering load-bearing, as recorded.
⚠️ Freshness UTXO must be (a) above dust, (b) EXCLUDED from splice/fee coin-selection, or `initiate_splice`
  could consume it as a fee input and silently invalidate every emitted exit. **That is a REAL hazard**
  created by this design — the wallet has one UTXO pool shared with `initiate_splice`'s
  `wallet.get_utxos()`. **Needs an explicit reservation/exclusion, and a test that asserts it.**

## ❗CORRECTION — `create_sweep_tx` ALREADY HAS A TASK ENTRY (`QUEUE.md:2251`). I re-raised a settled question.
The user asked whether a TODO existed — **it does**, and it is far more specific than my re-derivation:
> **`create_sweep_tx` NEEDS AN OPERATOR AUTH, NOT AN ENDPOINT** — *"a security feature, not a wire-up, and
> it deserves its own run."*
Key content I duplicated or MISSED:
 • It is **good, actively maintained code** — the test was updated for the BIP86 P2TR migration and covers
   conservation (`swept + fee == inputs`), dust rejection, and no-double-sweep-after-broadcast.
 • **I DELETED IT on 2026-08-01 and RESTORED it on the user's instruction** (*"dont delete it if it's
   necessary good code"*). ⇒ My "flag, do not sweep" instinct was right — **because I had already made
   exactly that mistake and been corrected.**
 • The `dead_code` warning is **ACCURATE AND EXPECTED**: it marks a **missing authorized trigger**, not
   dead weight. ⇒ 🔴 **My framing of it as a dedup-pass candidate was WRONG** — it is a KNOWN, DELIBERATE
   state, not a discovery.
 • The design is already decided: **do NOT wire it to an ordinary endpoint.** A drain is the same severity
   as a seed export, and the repo already has that control — `quid-hop/src/migration.rs` guards seed export
   with an EIP-712 `MigrationAuth` bound to the operator **Gnosis Safe** as `verifyingContract`,
   ≥`MIGRATION_THRESHOLD` owner sigs verified in-enclave by `ecrecover`, plus `guard_prod_trust_anchors`.
   **A drain wants a `SweepAuth` mirroring that. Until then it stays unwired ON PURPOSE.**
📌 **LESSON (4th time on this pattern): I re-derived a documented decision AND re-proposed an action the
  user had already reversed.** The `#114` mechanism was in a test comment; `initiate_splice` existed; the
  refresh predicate existed; now this. **Before flagging anything as a finding, GREP THE QUEUE FOR IT** —
  `docs/actionable/*.md` is ~3,200 lines and holds most of what I keep rediscovering.
⇒ ✅ NET: no new action. `create_sweep_tx` remains **intentionally unwired pending `SweepAuth`**, and the
  dead-code warning stays as its marker. **Stage 2 correctly does not use it** (that part of my analysis
  stands — it drains everything; stage 2 needs one small self-send).

## 📍 #114 STAGE 2 — SCOPED AND BLOCKED ON ONE THING: the heartbeat has NO WALLET ACCESS.
Traced the daemon call chain for the freshness UTXO:
```
run_deadman_exit_heartbeat(hop_keys, hop_monitors, vault, evm, btc_channels, gas_limit, interval_secs)
   -> build_exit_call(...)        // :99 — documented "Pure/sync (no I/O, no `.await`)"
        -> quid_ln::deadman_exit::presign_deadman_exit(..., freshness)   // stage 1: takes it, gets None
```
⇒ 🔴 **`run_deadman_exit_heartbeat` (`:177`) takes NO `OnchainWallet`** — so the freshness UTXO cannot be
  read or created anywhere in the current chain. **That is the whole of what blocks stage 2.**
⇒ ⚠️ **`build_exit_call` is deliberately PURE/SYNC** (*"no I/O, no `.await`"*). **Do NOT reach into the
  wallet from inside it** — that would break a documented property for convenience. **Resolve the UTXO in
  the heartbeat (async, I/O-capable) and PASS IT DOWN as a value.** Stage 1's
  `Option<(OutPoint, TxOut)>` is already exactly that shape, so the pure/sync boundary is preserved.

### ▶️ STAGE 2 BUILD (ordered; each step compiles via the Docker Linux check)
 1. Add `hop_wallet: Option<Arc<OnchainWallet>>` to `run_deadman_exit_heartbeat`; wire at its call site
    (find with `grep -rn run_deadman_exit_heartbeat`). `Option` because the heartbeat must still run for a
    node without fleet wallet duties — same honesty as stage 1's `None`.
 2. Add `freshness: Option<(OutPoint, TxOut)>` to `build_exit_call`; forward to `presign_deadman_exit`.
 3. In the heartbeat: resolve the current freshness UTXO via `wallet.get_utxos()` (`wallet.rs:873` →
    `LocalOutput` carries outpoint + value = the exact pair needed); create it via `create_onchain_send`
    (`:1134`) if absent.
 4. **Rotation:** create the NEW UTXO → re-emit ALL channels against it → THEN spend the OLD one. Ordering
    load-bearing (a botched rotation leaves every LP with no valid exit).
 5. 🚨 **RESERVE the freshness UTXO from coin selection.** `initiate_splice` calls `wallet.get_utxos()` and
    filters only on `is_confirmed()` — it would happily consume the freshness UTXO as a FEE INPUT and
    **silently invalidate every emitted exit.** This is a REAL hazard created by this design, in a code path
    that already exists. **Needs an explicit exclusion + a test asserting a splice never spends it.**
 6. Verify: `docker run --rm -v "$PWD":/w -w /w/quid-ln -e CARGO_TARGET_DIR=/tmp/t rust:1.90 cargo check -p quid-bridge`

### ✅ WHAT IS DONE AND VERIFIED (stage 1, complete)
 • `build_deadman_exit_tx` / `deadman_exit_sighash` / `presign_deadman_exit` all take the freshness input;
   prevout order matches input order and a count-mismatch now ERRORS rather than silently mis-committing.
 • Security property proven by a passing test (`sighash_commits_to_every_prevout_not_just_input_zero`).
 • Builder crate **10/10 green** natively; daemon crate **compiles clean** in the Linux container.
 • `None` path is byte-identical to pre-#114 ⇒ **zero production behaviour change so far.**

## ⭐ #114 STAGE 2 — REVIEWED WHAT EXISTS FIRST (user, 2026-08-01). There IS a BDK chokepoint. Use it.
Rather than write new reservation code, reviewed the wallet's own BDK usage:
```rust
/// Get a [`TxBuilder`] which has some defaults prepopulated.
fn default_tx_builder(wallet: &mut Wallet, coin_selector: CoinSelector, feerate: FeeRate)
    -> TxBuilder<'_, CoinSelector> {
    let mut tx_builder = wallet.build_tx().coin_selection(coin_selector);
    tx_builder.fee_rate(feerate);       // RBF already enabled by default
    tx_builder
}
```
⇒ **`default_tx_builder` is a CENTRAL FACTORY with 6 call sites in `wallet.rs`** — every wallet-built tx
  already flows through ONE place that configures coin selection.
⇒ 🎯 **The freshness-UTXO exclusion belongs HERE, as `tx_builder.unspendable(...)`** — BDK's own mechanism.
  One edit at one chokepoint ⇒ **every existing and FUTURE wallet tx inherits the exclusion automatically**,
  including any path nobody remembers to update. **No new reservation subsystem, no per-call-site
  discipline, no bookkeeping to drift.**
⇒ The repo ALSO already has the reservation CONCEPT: `wallet.cancel_tx(&psbt.unsigned_tx)` with the comment
  *"will eventually free up any UTXOs that were 'reserved' by the preflight tx"* — so preflight-vs-real
  reservation is already understood here; I would have reinvented a worse version.

### ⚠️ ONE GAP THE CHOKEPOINT DOES NOT COVER — verify, do not assume
`initiate_splice` (`quid-hop/src/node.rs`) does **NOT** go through `wallet.rs`'s builder — it calls
`wallet.get_utxos()` directly, filters on `is_confirmed()`, and hands them to LDK's `SpliceContribution`.
⇒ **The `unspendable()` chokepoint will NOT protect the splice path.** That one needs its own filter
  (exclude the freshness outpoint from the `utxos` vec it builds).
⇒ ⇒ **TWO sites total, both identified by reading existing code rather than designing new:**
   (1) `default_tx_builder` → `.unspendable(freshness)` — covers all 6 wallet paths;
   (2) `initiate_splice`'s `get_utxos()` filter — covers the splice fee-input path.
   Plus a test asserting a splice never spends the freshness outpoint (the silent-invalidation hazard).
📌 **This is the 5th time reviewing-before-writing changed the answer on #114.** The pattern is now
  unambiguous: **the capability almost always exists — find it, then decide.**

## ⚠️ #114 — THE SHARED FRESHNESS UTXO **IS A CHOKEPOINT**. Resolve before stage 2 writes it. (user, 2026-08-01)
**Terminology check:** I used "chokepoint" APPROVINGLY for `default_tx_builder` (one place to make a
change — that is GOOD, a single edit that all paths inherit). The user means the OTHER sense: **a single
point of failure.** And the design has one:
🔴 **ONE freshness UTXO shared by ALL channels ⇒ its blast radius is EVERY channel at once.** Failure modes:
 (a) spent by another path ⇒ **every LP's exit invalidated simultaneously** (mitigated by the 2 exclusions);
 (b) rotation crash between spend and re-emit ⇒ same (mitigated by re-emit-BEFORE-spend ordering);
 (c) **hop wallet empty ⇒ cannot create the next one ⇒ rotation stops fleet-wide** (NOT mitigated);
 (d) a bug in the single rotation path ⇒ fleet-wide, not per-channel.
⇒ The design traded **O(n) cost** for **O(1) cost + O(n) blast radius.** That trade was correct on COST but
  I never priced the RISK concentration. **A backstop whose failure mode is "all LPs lose recourse at once"
  deserves a harder look than one that degrades per channel.**

### ▶️ IMPROVEMENT — SHARD, and make the count a POLICY DIAL
**One freshness UTXO per SHARD of channels** (shard = `channel_id % K`), not one globally:
 • **Blast radius drops from N channels to N/K.** A botched rotation, an accidental spend, or a bug in one
   shard's path leaves the other K−1 shards fully protected.
 • **Cost rises only to K small txs per period — still O(1) in the CHANNEL COUNT**, which was the whole
   point. K is a dial: K=1 is today's design, K=N degenerates to per-channel (the rejected O(n) splice).
 • ⭐ **K can start at 1 and rise without a protocol change** — the exit already binds to whichever outpoint
   it was signed against, so sharding is an OPERATIONAL parameter, not a format change. **Ship K=1, raise it
   when LP count justifies it.** That keeps stage 2 simple AND leaves the risk dial available.
 • Residual (c) — wallet exhaustion — is NOT fixed by sharding (shared wallet). It stays the **operational
   liveness requirement already recorded**: fund the hop wallet, alarm on reserve proximity.
📌 Recording the improvement WITHOUT expanding stage 2's scope: **stage 2 implements K=1**, with the shard
  index as a parameter so raising K later is config, not a rewrite. **This is the "no compromises" form that
  does NOT delay the original work.**

## 🎯 FOCUS RESTATED (user: finish the original work, do not get sidetracked)
**ORIGINAL TASK = #114 stages 2-5, then THE 33, then the deep dedup pass.** Everything since has been
genuine dependencies (BDK review, chokepoint risk) — but the NEXT ACTION is unchanged and concrete:
 ▶️ **STAGE 2 STEP 1: add `hop_wallet` to `run_deadman_exit_heartbeat` and wire its call site.** That is the
   single blocker; everything else in stage 2 follows from it.

## 🔴 APPLYING THE NEW RULE TO MY OWN SHARDING FIX — it HAS unintended consequences. Two of them.
Standing rule banked as memory `measure-a-fix-from-all-sides`. Pricing the shard proposal on every axis:
 1. ✅ **Blast radius** — drops from N channels to N/K. The stated goal, achieved.
 2. 🔴 **SECOND-ORDER — wallet drain rises K×.** Each shard needs its OWN rotation tx per period ⇒ K txs
    instead of 1. **That worsens failure mode (c) — hop-wallet exhaustion — which sharding does NOT fix and
    which is the ONLY unmitigated mode left.** ⇒ **Sharding trades a mitigated risk for an unmitigated one.**
    At K large enough, the wallet empties faster, rotation stops FLEET-WIDE, and the blast radius is N again
    — **the very thing sharding was bought to prevent.** There is an optimum K, and it is NOT "as high as
    affordable".
 3. 🔴 **REVERSIBILITY — my "K is just config, raise it later" claim was WRONG.** Shard assignment
    (`channel_id % K`) REMAPS when K changes: a channel moving from shard A to shard B still has exits bound
    to **A's** outpoint. Until it is re-emitted against B, spending B's UTXO does NOT invalidate its stale
    exits — **the invalidation guarantee silently lapses for remapped channels during a K change.**
    ⇒ Changing K requires a **full re-emission cycle before any old shard UTXO is spent** — a MIGRATION, not
    a config edit. **Exactly the "signed/committed against the old value" trap in the rule I just wrote.**
 4. ✅ Correctness/cost/other-callers — unchanged from the K=1 analysis.
⇒ **REVISED RECOMMENDATION: ship K=1** (today's design), keep the shard index as a parameter for structure,
  and treat any K change as a **planned migration with a documented re-emission cycle** — NOT a dial.
  **Sharding is not free, and it is not reversible in the way I claimed.**
📌 The rule caught a real error in the very fix that prompted it, within one turn — and BOTH problems were on
  axes I had not measured (second-order, reversibility). **That is the pattern: the regression is never on
  the axis you were optimising.**

## 🔑 HARD CONSTRAINT (user, 2026-08-01): **NO OPERATOR EXISTS TO SET PARAMETERS.** Everything must self-tune.
This **invalidates the "K is a policy dial" framing** — there is nobody to turn it. A parameter with no
setter is either a hardcoded guess or a latent failure. **Every knob must be DERIVED from observable state,
or not exist.** Re-deriving the two open parameters under that constraint:

### 1. SHARD COUNT K — DERIVE from the wallet, and let it DEGRADE SAFELY
```
K = clamp(1, n_channels, floor(spendable_sats / (rotation_cost_sats * SAFETY_FACTOR)))
```
⇒ **Self-limiting in the right direction:** a THIN wallet drives K→1 (cheapest possible rotation, liveness
  preserved); a FUNDED wallet raises K (smaller blast radius). ⇒ It **degrades blast-radius protection
  rather than stopping rotation** — the correct sacrifice, because a stopped rotation is the fleet-wide
  failure and a bigger blast radius is only a risk concentration.
⇒ **Self-healing:** wallet refills ⇒ K rises automatically. No human in the loop, ever.
⇒ It also DISSOLVES the second-order problem I found last turn: K can no longer be set higher than the
  wallet can sustain, because the wallet balance IS the formula. **The unintended consequence is designed
  out, not documented around.**

### 2. SHARD ASSIGNMENT — **STABLE, NOT MODULO.** (this kills the migration problem outright)
🔴 `channel_id % K` REMAPS every channel whenever K changes ⇒ silent lapse of the invalidation guarantee.
⇒ ✅ **Assign each channel a shard ID ONCE, at first emission, and PERSIST it.** K changing only affects
  where NEW channels land; existing channels never move.
⇒ **No remap ⇒ no migration ⇒ no re-emission cycle ⇒ K becomes freely automatic** — exactly the property I
  wrongly claimed for the modulo version. **Stable assignment is what makes the derived K safe.**
⇒ Shrinking K (wallet drained) does NOT strand channels: their shard UTXO still exists and still rotates;
  only NEW assignments concentrate. Rotation cost falls immediately, which is the point.

### 3. REFRESH MARGIN — derive from Δ, do not hardcode a second constant
`REFRESH_MARGIN = DEAD_MAN_DELTA_BLOCKS / 2` (currently 144/2 = 72 blocks ≈ 12h). One constant instead of
two ⇒ they can never drift into `MARGIN >= Δ` (which would refresh every tick). The startup assertion I
planned becomes UNNECESSARY — the relationship is structural, not checked.
📌 **This is the "no cryptic knobs" instinct applied to operations:** a parameter nobody can set is worse
  than no parameter. **Derive it, bound it by the resource that constrains it, and let it self-heal.**

## ❗CLARIFICATION + CORRECTION — TWO persisted things, TWO lifetimes. And my "cost falls immediately" was WRONG.
The user asked: *"persist it but it changes, correct?"* — right to ask; I had conflated two records.
| persisted | lifetime | changes when |
|---|---|---|
| `channel_id -> shard_id` | **STABLE** — assigned once at first emission | only on a DELIBERATE consolidation (below) |
| `shard_id -> current_freshness_outpoint` | **CHANGES EVERY ROTATION** | every refresh period, by design |
⇒ The ASSIGNMENT is stable; the OUTPOINT it points at rotates constantly. **That split is what makes a
  derived K safe** — K changing never rewrites assignments, and rotation never rewrites the mapping.

### 🔴 THE ERROR THE QUESTION SURFACED
I wrote *"Shrinking K … Rotation cost falls immediately, which is the point."* **FALSE.**
⇒ With STABLE assignment, the number of shards that must KEEP ROTATING is set by **existing assignments**,
  not by K. Lowering K only affects where NEW channels land. ⇒ **A drained wallet would NOT get relief** —
  every already-assigned shard still needs its rotation tx, so cost stays high exactly when the wallet
  cannot pay. **The self-limiting property I claimed does not hold on the way DOWN.**
⇒ ⇒ K is therefore not one number: it is **`K_new` (where new channels are assigned)** and **`K_active`
  (shards with live channels, which drives COST)**. I had silently assumed they were the same.

### ✅ THE FIX — CONSOLIDATION, using the machinery that already exists
Re-emission is what the heartbeat ALREADY does every period. So a thin wallet triggers **consolidation**:
 1. Pick the least-populated active shard.
 2. **Re-emit its channels against a SURVIVING shard's outpoint** (this is an ordinary re-emission — the
    exit binds to whatever outpoint it was signed against, so the channel is simply re-bound).
 3. **THEN** spend the drained shard's old outpoint (kills its stale exits) and stop rotating it.
 ⇒ `K_active` genuinely falls ⇒ cost falls ⇒ **the wallet recovers.** Self-healing in BOTH directions.
 ⇒ Assignment is *stable by default, migratable on purpose* — and the migration is one re-emission, the
   exact operation the heartbeat performs anyway. **No new mechanism.**
 ⚠️ ORDERING (same rule as rotation, and load-bearing): **re-emit onto the surviving shard BEFORE spending
   the drained shard's outpoint** — reversed, every channel on that shard loses its valid exit.
📌 **The rule caught its own violation again:** I priced K on the way UP (blast radius) and never on the way
  DOWN (recovery under a thin wallet). **A self-tuning parameter must be measured in BOTH directions** —
  adding that to the standing rule's checklist.

## ✅ #114 STAGE 2 STEP 1 LANDED — wallet reaches the heartbeat. Linux-verified.
`run_deadman_exit_heartbeat(..., hop_wallet: Option<quid_ln::wallet::OnchainWallet>)`, wired in
`daemon.rs:293` with `Some(node.wallet.clone())` — the SAME wallet the reconciler already clones at
`daemon.rs:222` (`let reconcile_wallet = node.wallet.clone();`). **No new wallet, no new plumbing** — the
hop has ONE on-chain pool and this joins the existing consumer list.
```
docker run --rm -v "$PWD":/w -w /w/quid-ln -e CARGO_TARGET_DIR=/tmp/t rust:1.90 cargo check -p quid-bridge
  Finished `dev` profile in 1m 47s     # only: unused `hop_wallet` (not consumed yet) + pre-existing sweep
```
⇒ `Option` is again the HONEST type: a node without fleet wallet duties still runs the heartbeat and emits
  `None`-bound exits — **i.e. exactly today's behaviour**, so this step is inert like stage 1.
⇒ The wallet is resolved **in the async task** and will be passed DOWN as a value; `build_exit_call` stays
  **pure/sync** as documented. The design boundary held under implementation.
⇒ 📌 That single wallet being shared is EXACTLY why the two exclusions matter (`default_tx_builder`
  `.unspendable(...)` + the `initiate_splice` `get_utxos()` filter) — the comment at the call site says so,
  so the hazard is recorded where someone will actually meet it.

### ▶️ STAGE 2 REMAINING
 2. `build_exit_call(..., freshness: Option<(OutPoint, TxOut)>)` → forward to `presign_deadman_exit`.
 3. Heartbeat: resolve/create the shard's freshness UTXO (`get_utxos` `:873` / `create_onchain_send` `:1134`);
    persist `channel_id -> shard_id` (STABLE) and `shard_id -> outpoint` (ROTATES).
 4. Rotation + consolidation, both **re-emit BEFORE spending the old outpoint**.
 5. The two coin-selection exclusions + a test asserting a splice never spends a freshness outpoint.
 6. Regtest end-to-end ⇒ closes the ORIGINAL #114 broadcast-verification gap.

## 🔐 SECURITY REVIEW OF THE STAGE-2 WIRING — "can a Rust-host hack drain it?" (user, 2026-08-01)
**Answer: my change adds NO new authority — but the honest picture is more nuanced than "safe", and one
part needs confirming rather than asserting.**

### 1. The hop wallet signs LOCALLY — this is PRE-EXISTING, not introduced here
`wallet.rs:441 sign_psbt(...)` uses `bdk_wallet::SignOptions` — the on-chain wallet builds and signs PSBTs
**in-process**. The in-enclave policy signers are for OTHER surfaces:
 • `evm_validating_signer.rs` — **EVM** txs, gated by contract+selector policy (`with_policy`).
 • `validating_signer.rs` — **LN channel** signing, routed through explicit policy checks.
⇒ **Neither guards arbitrary BDK on-chain sends.** A host with code execution can already build a PSBT and
  sign it. ⇒ **The hop wallet is a HOT FEE WALLET, and it was already host-spendable before my change** —
  `maybe_flush_btc_fees` builds and broadcasts splices from it today.
⇒ ✅ **My change adds a CONSUMER, not a capability.** `Some(node.wallet.clone())` hands the heartbeat the
  same handle the reconciler already holds. **No new drain path, no new liability.**

### 2. The architecture's "a host hack cannot lose funds" invariant — WHAT it actually covers
It must be read as covering **LP / protocol funds**, NOT the hop's fee float:
 • **LP channel BTC** — 2-of-2, and every payout script pins to `btcRecipientOf`, which is **LOCKED at
   registration** (`BTCChannels.sol:216`). A compromised host **cannot redirect an LP's BTC to itself.**
 • **Band / vault capital** — EVM-side, behind the EVM policy signer.
 • **Hop fee float** — a HOT wallet by design; its loss is an operational cost, not user funds.
⚠️ **That distinction should be stated explicitly somewhere in the docs.** "No loss of funds on host
  compromise" is TRUE for user funds and FALSE for the fee float, and conflating them hides a real (if
  bounded) exposure. **Size the float accordingly** — it should hold what rotations need, not a treasury.

### 3. Does the freshness UTXO give an attacker a NEW lever? **NO.**
A compromised host could spend the freshness outpoint ⇒ invalidate every emitted exit ⇒ LPs lose their
backstop. **But the same host could simply REFUSE to emit or rotate exits at all** — an identical outcome,
already available pre-#114. ⇒ **No new attacker capability; the failure mode is unchanged.**
⇒ And it does NOT enable theft: invalidating an exit removes RECOURSE, it does not redirect funds — the
  payout script is still pinned to the LP.

### ▶️ TO CONFIRM (do NOT treat as settled — this is the part I have not verified)
 1. Does ANY in-enclave policy gate BDK sends (a hook I did not find)? I searched `validating_signer` and
    `evm_validating_signer`; **absence from my grep is not proof** — confirm against the enclave design.
 2. Stage 2 MUST create the freshness UTXO to an INTERNAL address (`get_internal_address`, already used at
    `daemon.rs:320`) — **never a caller-supplied one.** That keeps the new code path incapable of
    exfiltrating even if reached, and matches why `create_sweep_tx` stays unwired pending `SweepAuth`.

## ✅ USER IS RIGHT — the fee float is TRANSIENT AND SMALL. Now QUANTIFIED from the real constants.
| constant | value | source | meaning |
|---|---|---|---|
| `MIN_ECONOMIC_GROW_SATS` | **250_000 sats** (~0.0025 BTC) | `rebalancer.rs:82` | max fees ACCRUED per channel before a splice flushes them TO THE LP |
| `wallet_reserve_sats` | **10_000 sats** (~0.0001 BTC) | `rebalancer.rs:117` = `FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS * 10` | the PERSISTENT floor the wallet never spends below |
| `FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS` | 1_000 sats | `constants.rs:102` | force-close fee unit |
⇒ **The PERSISTENT component is ~10_000 sats — a few dollars.** Everything above it is working capital that
  exists only to be **spliced INTO channels, i.e. paid to LPs** (`maybe_flush_btc_fees` → `initiate_splice`).
⇒ **So a host compromise captures a MOMENT of float, not a balance** — exactly the user's point, and the
  batching threshold BOUNDS it: fees sit unflushed only until they clear 250k sats per channel, then leave.
⇒ ⇒ **REVISION to my previous entry:** I wrote that the float exposure "should be stated explicitly" as if
  it were a meaningful liability. **It is structurally near-zero by design** — the architecture already
  drains it continuously to LPs. The correct statement is not a warning but a PROPERTY:
  > *"The hop wallet is a transient fee conduit, not a treasury. Its standing balance is ~10k sats plus
  >  in-flight fee batches (≤250k sats/channel) that are continuously spliced out to LPs. A host compromise
  >  therefore captures a moment of flow, not a store of value — and CANNOT touch LP channel BTC, whose
  >  payout is pinned to a `btcRecipientOf` locked at registration."*
⇒ ✅ **The "a Rust-host hack cannot lose funds" invariant holds in the sense that matters.** Not because the
  wallet is unspendable, but because **there is nothing meaningful sitting in it** — the design routes gains
  to LPs continuously rather than accumulating them. **That is an architectural property, not a mitigation.**
⇒ 📌 **My freshness UTXO fits this cleanly:** it is ONE dust-sized output per shard per period. It does NOT
  create a standing balance, so it does NOT weaken the property. **Keep it dust-sized + internal-address
  only** — then stage 2 preserves the invariant by construction.
⚠️ The ONE thing that would break this: letting the wallet accumulate (large top-ups, or a shard count high
  enough to demand a big buffer). **The derived K must be bounded by rotation need, NOT by "fund it more"** —
  which is exactly how it was derived. The pieces are consistent.

## ⭐ GUARD ARBITRARY BDK SENDS — the RIGHT chokepoint is `sign_psbt`, NOT `default_tx_builder`. And SweepAuth rides it.
**Correcting my earlier pick:** I proposed the exclusion at `default_tx_builder` (`wallet.rs:1308`). That
covers only txs BUILT through it — **a compromised host can construct a PSBT by hand and never touch the
builder.** ⇒ 🎯 **The true chokepoint is `sign_psbt` (`wallet.rs:441`)** — nothing spends without a
signature, so **a policy there is unbypassable**, regardless of how the PSBT was assembled. (Same reasoning
as the EVM side: the policy lives in `evm_validating_signer`'s `sign_eip1559`, not in a tx-builder.)

### THE POLICY — mirror the EVM signer, which already exists and is already trusted
`evm_validating_signer.rs` gates EVM txs on **which contracts + selectors** the hop may touch. The BDK
mirror gates on **which DESTINATIONS a spend may pay**:
| destination | allowed | why |
|---|---|---|
| wallet-INTERNAL address (`get_internal_address`) | ✅ | freshness UTXO, change, self-consolidation |
| the channel FUNDING outpoint (splice-in) | ✅ | fee-flush + splices — pays LPs, the whole point |
| anything else | ❌ **DENY** | there is no legitimate arbitrary payee for a fee conduit |
⇒ **This is enforceable precisely BECAUSE the wallet is a fee conduit, not a treasury** — it has no
  legitimate need to pay an arbitrary address, so an allowlist costs nothing in functionality.
⇒ **Result: a host with full code execution can no longer exfiltrate the float at all** — it can only move
  sats to our own addresses or into LP channels. That upgrades the property from *"captures a moment of
  flow"* to **"cannot send anywhere it does not already belong."**

### ⇒ WHAT THE CURRENT FEATURE GAINS (the user's question)
 1. **Stage 2's freshness UTXO becomes PROVABLY non-exfiltrating** — it pays an internal address, which is
    the allowlist's first case. The hazard I flagged ("must never be caller-supplied") stops being a
    DISCIPLINE and becomes an ENFORCED INVARIANT. **The guard I was going to write as a comment becomes code.**
 2. **The two coin-selection exclusions get a home.** Rather than patching `default_tx_builder` AND
    `initiate_splice` separately, the signer refuses to sign anything spending a reserved freshness outpoint
    — **one rule, both paths, including any future path nobody remembers.**
 3. **`create_sweep_tx` unblocks.** Its task (`QUEUE.md:2251`) says it needs *"an operator auth, not an
    endpoint"* and should mirror `migration.rs`'s EIP-712 `MigrationAuth` (Gnosis Safe as
    `verifyingContract`, ≥`MIGRATION_THRESHOLD` owner sigs, `ecrecover` in-enclave).
    ⇒ **With a BDK signing policy in place, `SweepAuth` is just an EXEMPTION to the destination allowlist,
      carried by that same EIP-712 proof** — not a separate subsystem. The drain becomes "the one signed
      exception to a deny-by-default rule", which is exactly the shape that task asked for.
 4. **One mechanism serves three open items** (#114 stage 2 exclusions, the sweep auth, and the general
    host-compromise posture) — the ≥2-approaches bar's "REUSES a primitive AND gives a better guarantee".
⚠️ VERIFY FIRST: `sign_psbt` must be the ONLY signing path (`sign_interactive_funding` at `:472` also
  signs — check whether it can move non-channel funds, and whether LDK signs any wallet-owned input
  elsewhere). **A policy at one of two signing paths is worse than none, because it reads as covered.**

## 🔴 VERIFIED — `sign_psbt` IS **NOT** THE CHOKEPOINT EITHER. There are **FIVE** signing paths.
Enumerated every `wallet.sign(...)` in the crate (the actual BDK signing call, not the wrappers):
| # | site | reached via | goes through the shared helper? |
|---|---|---|---|
| 1 | `wallet.rs:453` | `pub fn sign_psbt` (`:441`) | ❌ direct `.sign()` |
| 2 | `wallet.rs:490` | `pub fn sign_interactive_funding` (`:472`) | ❌ direct `.sign()` |
| 3 | `wallet.rs:1125` | `create_and_sign_funding_tx` (`:1103`) | ✅ `default_sign_psbt` |
| 4 | `wallet.rs:1167` | `create_onchain_send` (`:1134`) | ✅ `default_sign_psbt` |
| 5 | `wallet.rs:1210` | `create_sweep_tx` (`:1182`) | ❌ direct `.sign()` |
| — | `wallet.rs:1326` | `default_sign_psbt` (`:1321`) — the shared helper itself | (is the helper) |
⇒ 🔴 **A policy on `sign_psbt` would cover 1 of 5 paths** — and would read as "signing is guarded" while
  `create_sweep_tx`, `sign_interactive_funding`, and both `default_sign_psbt` users spent freely. **That is
  the precise failure I warned about one turn earlier, in my own proposal.**
⇒ **THIRD chokepoint guess, third time wrong:** `default_tx_builder` (misses hand-built PSBTs) → `sign_psbt`
  (misses 4 of 5) → the real answer below. **Each guess sounded authoritative and was checked only because
  the user said "verify first."**

### ✅ THE ACTUAL FIX — funnel all five through ONE helper, then police THAT
`default_sign_psbt` (`:1321`) **already exists and already serves 2 of the 5.** So:
 1. **Route sites 1, 2, 5 through `default_sign_psbt`** — they each hand-roll what it does
    (`SignOptions` + `wallet.sign` + a finalized check). ⇒ **This is a genuine DEDUP win in its own right:
    5 signing implementations collapse to 1**, which is the standing "one declaration" rule applied to
    behaviour rather than to types.
 2. **Put the destination allowlist INSIDE `default_sign_psbt`.** One rule, all paths, and any FUTURE
    signing site inherits it by construction (or fails review for bypassing the helper).
 3. `SweepAuth` then becomes the single documented EXEMPTION carried through that helper.
⚠️ **Sites 1 and 2 may legitimately differ** — `sign_interactive_funding` is documented as *"differs from
  sign_psbt in..."* and site 1 serves LDK's anchor `BumpTransactionEventHandler` via
  `WalletSource::sign_psbt`. **Read both fully before merging** — the goal is ONE policy point, not
  flattening a real behavioural difference. If they must stay separate, the policy call goes in each, and
  a test asserts every signing path enforces it.
📌 **LESSON (now 3× on this one question): "where is the chokepoint?" cannot be answered by reading ONE
  function — it requires enumerating ALL callers of the underlying primitive.** Applying the
  `never-assert-absence-from-a-grep` discipline in reverse: I must enumerate the SINKS, not spot-check one.

## ⭐ DON'T HAND-ROLL — the destination-pinning policy ALREADY EXISTS. Mirror it. (user, 2026-08-01)
Graph query (`validating_signer.rs`: 99 nodes, 488 internal links, linked to LDK `sign/mod.rs` +
`chan_utils.rs`) pointed straight at the existing implementation, and it is **the exact policy I was about
to write from scratch**:
```
//! ValidatingChannelSigner { inner: InMemorySigner, policy: PolicyState }
//! * a cooperative close that *pays the holder (LP)* MUST pay the exact committed P2WPKH shutdown
//!   script that QU!D pins via `commit_upfront_shutdown_pubkey` … A close paying the holder output
//!   to any other destination is REJECTED. If the holder output is *absent* … that is valid.
//! All other ChannelSigner / EcdsaChannelSigner methods delegate straight to `inner`.
```
⇒ 🎯 **A DESTINATION ALLOWLIST enforced at SIGNING, with a delegate-everything-else wrapper — already
  built, already reviewed, already trusted in production.** The BDK guard should be the SAME SHAPE, not a
  new invention: `ValidatingWallet { inner: <bdk wallet>, policy }`, reject non-allowlisted destinations,
  delegate the rest.
⇒ **Reuse extends to the REASONING, not just the code:** note the nuance it already encodes — *"if the
  holder output is absent, that is valid: there is nothing to redirect"*. The BDK policy needs the same
  care (change outputs, zero-value cases) and can copy a pattern that already got this right.
⇒ ✅ Prefer library mechanisms over custom checks wherever they exist: BDK's own `SignOptions` /
  `TxBuilder::unspendable` / descriptor policy for what they cover, and the wrapper only for what they do
  not. **Check BDK's API surface BEFORE writing any predicate** — the same "the capability probably exists"
  pattern that has now been right 6× on this feature.
📌 The graph earned its place again: it located the pattern by COUPLING (99 nodes / 488 links), which no
  keyword search for "policy" or "allowlist" would have surfaced — `validating_signer.rs` never uses either
  word.

### ▶️ REVISED PLAN FOR THE BDK GUARD (no hand-rolling)
 1. **Read BDK's `SignOptions` + descriptor-policy surface** for anything that already expresses "only sign
    spends paying these destinations". Use it if it exists.
 2. For the remainder, **mirror `ValidatingChannelSigner`**: wrapper + `policy` field + reject-then-delegate.
 3. Funnel the 5 signing paths through the shared helper (the dedup win) so the wrapper has ONE seat.
 4. `SweepAuth` = the documented exemption, carried by the EIP-712 proof `migration.rs` already implements.

## ✅ #114 STAGE 2 STEP 2 LANDED — `build_exit_call` forwards freshness. Linux-verified (1m 29s, clean).
`build_exit_call(freshness: Option<(bitcoin::OutPoint, bitcoin::TxOut)>, ...)` → forwards to
`presign_deadman_exit`. The param is FIRST in the list with a comment stating the constraint it protects:
**the caller (the async heartbeat) resolves it; this fn stays pure/sync and never touches the wallet.**
Call site passes `None` with a pointer to step 3. ⇒ **Still byte-identical to pre-#114 ⇒ inert.**
⇒ Full chain is now wired end-to-end: `heartbeat(hop_wallet)` → `build_exit_call(freshness)` →
  `presign_deadman_exit(freshness)` → `build_deadman_exit_tx` + `deadman_exit_sighash`. **Only the VALUE is
  missing** — every signature it must travel through is in place and compiling.

### ▶️ REMAINING TO FINISH #114 (steps 3-6)
 3. Heartbeat resolves/creates the shard freshness UTXO (`get_utxos` `:873`, `create_onchain_send` `:1134`,
    **internal address only**); persist `channel_id→shard_id` (STABLE) + `shard_id→outpoint` (ROTATES).
 4. Rotation + consolidation — **re-emit BEFORE spending the old outpoint** (load-bearing, both paths).
 5. The BDK signing guard: funnel 5 signing paths through `default_sign_psbt` (dedup win), mirror
    `ValidatingChannelSigner`'s wrapper+policy shape, reuse BDK's own `SignOptions`/`unspendable` where they
    cover it. Test: a splice never spends a freshness outpoint.
 6. Regtest end-to-end (fresh accepted / stale rejected) ⇒ closes the ORIGINAL #114 verification gap.

## 📌 NEW TODO (user, 2026-08-01) — **AUDIT THE CODEBASE FOR HAND-ROLLING WHERE A LIBRARY EXISTS**
This feature alone found **6 cases** where the capability already existed and I nearly rebuilt it:
the mechanism in a test comment · `initiate_splice` · the refresh predicate · the `create_sweep_tx` task ·
BDK's `default_tx_builder` chokepoint · `ValidatingChannelSigner`'s destination policy.
⇒ **Systematic sweep, to run WITH the deep dedup pass** (same reading, different lens):
 • **Rust**: for each hand-written helper, ask whether `bitcoin`/`bdk_wallet`/`lightning`/`secp256k1` already
   provides it. **The graph is the tool** — it found `ValidatingChannelSigner` by COUPLING when no keyword
   search would have (that file never says "policy" or "allowlist").
 • **Solidity**: same question against OpenZeppelin / Solady / `FullMath` / v4-core libs — ⚠️ manual, since
   graphify has no Solidity parser (proven).
 • **Also flag the INVERSE**: places we depend on a library where a 3-line local would be clearer/cheaper.
 • ⚠️ Do NOT auto-replace. Hand-rolled code sometimes encodes a REQUIREMENT the library misses (as
   `validating_signer` encodes the absent-holder-output nuance). **Report candidates + rationale; the user
   decides.**

## 📋 #114 STEPS 3-6 — COMPLETE EXECUTION SPEC (every symbol grep-verified; ready to run without re-derivation)
**STATE: steps 1-2 landed, inert, and verified.** Full chain compiles; only the VALUE is missing.

### STEP 3 — resolve/create the shard freshness UTXO (daemon crate)
**Persistence** mirrors the store's existing shape (`store.rs:172-176`: `HashMap<String, Rec>` fields inside
the sealed store, with `add_*` / `take_*` / `has_*` accessors — copy that pattern exactly):
 • `freshness_shards: HashMap<String, FreshnessRec>` — `shard_id -> {txid, vout, value_sats}` (**ROTATES**)
 • `channel_shard: HashMap<String, u32>` — `channel_id -> shard_id` (**STABLE**; assigned once, never
   remapped except by deliberate consolidation — see step 4)
**Resolution in `run_deadman_exit_heartbeat`** (the ONLY place allowed to touch the wallet):
 1. `wallet.get_utxos()` (`wallet.rs:873` → `LocalOutput` carries outpoint + value = the exact
    `(OutPoint, TxOut)` the chain already takes).
 2. Missing/spent ⇒ `create_onchain_send` (`:1134`) to `wallet.get_internal_address()` (already used at
    `daemon.rs:320`). ⚠️ **INTERNAL ADDRESS ONLY** — never caller-supplied (this is what makes the path
    non-exfiltrating even before step 5's guard lands).
 3. Size: **dust+ε only.** A standing balance here would break the "wallet holds nothing meaningful"
    property that makes a host compromise harmless (quantified: persistent float ~10k sats).
 4. `K = clamp(1, n_channels, floor(spendable / (rotation_cost * SAFETY_FACTOR)))` — derived, never set.
    **Ship K=1**; the formula matters only when LP count grows.

### STEP 4 — rotation + consolidation (both share ONE ordering rule)
🚨 **RE-EMIT ALL AFFECTED CHANNELS AGAINST THE NEW OUTPOINT *BEFORE* SPENDING THE OLD ONE.** Reversed, every
LP on that shard loses their valid exit until the next tick. **This single ordering IS the safety property.**
 • **Rotation** (periodic): new UTXO → re-emit shard's channels → spend old.
 • **Consolidation** (wallet thin): re-emit least-populated shard's channels onto a SURVIVING shard → spend
   the drained outpoint → stop rotating it. **This is what makes `K_active` fall** (the correction: stable
   assignment alone does NOT lower cost).
 • Refresh trigger: `deadline - tip < DEAD_MAN_DELTA_BLOCKS / 2` (derived from the existing 144, NOT a new
   constant — they cannot drift into refresh-every-tick).

### STEP 5 — the BDK signing guard (do NOT hand-roll)
 1. **Funnel all 5 signing paths through `default_sign_psbt`** (`wallet.rs:1321`) — sites `:453`, `:490`,
    `:1210` currently hand-roll it; `:1125`/`:1167` already use it. **Dedup win: 5 implementations → 1.**
    ⚠️ Read `sign_interactive_funding` (`:472`, documented as differing) + the LDK anchor path at `:433`
    FIRST — if they must stay separate, the policy goes in each + a test asserts every path enforces it.
 2. **Mirror `ValidatingChannelSigner`** (`validating_signer.rs`): `{ inner, policy }`, reject-then-delegate.
    It already implements destination-pinning ("*any other destination is rejected*") INCLUDING the
    absent-output nuance — copy the reasoning, not just the shape.
 3. Check BDK's own `SignOptions` / `TxBuilder::unspendable` / descriptor policy FIRST; wrapper only for
    what they do not cover.
 4. Allowlist: internal addresses ✅ · channel funding outpoints ✅ · everything else ❌.
 5. `SweepAuth` = the one documented EXEMPTION, carried by the EIP-712 proof `migration.rs` already
    implements (Gnosis Safe `verifyingContract`, ≥`MIGRATION_THRESHOLD` sigs, `ecrecover` in-enclave).
 6. **Test: a splice never spends a freshness outpoint** (the silent-invalidation hazard).

### STEP 6 — regtest end-to-end (closes the ORIGINAL #114 verification gap)
Harness exists (`regtest/setup.sh`, `setup-ln.sh`, `driver-e2e.sh`; `bitcoind` NOT installed — setup.sh
downloads a pinned build). Prove: (a) a FRESH exit broadcasts and is ACCEPTED after CLTV; (b) a STALE exit
(freshness spent) is REJECTED as missing-input; (c) `emitDeadManExit` gating rejects a non-attested caller
and a non-delegated hop. **(b) is the one that proves the whole design.**

### 🔧 BUILD/VERIFY COMMANDS (both needed — neither alone is sufficient)
```
cargo test -p quid-ln --lib deadman            # builder crate, native (10/10 today)
docker run --rm -v "$PWD":/w -w /w/quid-ln -e CARGO_TARGET_DIR=/tmp/t rust:1.90 cargo check -p quid-bridge
```
`quid-bridge` CANNOT build natively (`quid-cvm` → AMD SEV → Linux-only). Docker is mandatory for daemon work.

## ⚖️ STEP 5 — SIGNING DEDUP DONE (partly); the DESTINATION ALLOWLIST needs its OWN run. Here is why.
**Read all 5 signing sites before merging them — and they do NOT all share semantics:**
| site | `SignOptions` | expects finalized | mergeable? |
|---|---|---|---|
| `sign_psbt` | **custom** (`trust_witness_utxo`: the channel input carries only a `witness_utxo`) | **false** (only our inputs are ours) | ❌ genuinely different |
| `sign_interactive_funding` | **custom** | **false** (multi-party tx) | ❌ genuinely different |
| `create_sweep_tx` | `default()` | **true** | ✅ **MERGED** |
| `create_and_sign_funding_tx` / `create_onchain_send` | via `default_sign_psbt` | true | ✅ already shared |
⇒ ✅ **`create_sweep_tx` now uses `default_sign_psbt`** — 3 hand-rolled signing bodies → 2, and the two that
  remain are documented multi-party partial-signing, not duplication. **110/110 tests still pass.**
⇒ 📌 **This is why "collapse 5 → 1" was the wrong instruction to follow blindly.** Merging sites 1-2 would
  have flattened `trust_witness_utxo` and a `finalized=false` expectation into a `default()`+`ensure!`
  path — breaking channel funding in a way the type system would NOT catch. **The user's "don't hand-roll"
  and my "one declaration" rule both had to yield to reading what the code actually does.**

### 🛑 THE DESTINATION ALLOWLIST IS **NOT** SHIPPABLE AS A ONE-LINER — deferred WITH REASONS
I proposed "internal addresses ✅ · channel funding ✅ · everything else ❌". Reading the paths, that is
under-specified in a way that would BREAK things:
 • **Channel funding pays a 2-of-2 multisig script that is NOT ours** — an "our addresses only" rule kills
   channel opens outright.
 • **Splices pay the new channel output**, likewise foreign-by-design.
 • **The sweep pays an OPERATOR-SUPPLIED address** — that is its entire purpose, and it is exactly what
   `SweepAuth` is meant to authorise.
 ⇒ So the allowlist is not "our scripts"; it is **"scripts this specific operation is entitled to pay"**,
   which differs PER SIGNING PATH. That is a real design, not a predicate — it needs its own run.
⇒ ✅ **What IS shipped covers the concrete #114 hazard**: the freshness outpoint cannot be consumed by
  ordinary selection (enforced at the builder chokepoint AND the splice path, with a test that proves it
  BINDS). The broader anti-exfiltration posture is unchanged from before this feature — **not weakened by
  it**, which was the actual question asked.
▶️ NEXT RUN (its own): per-path destination policy + `SweepAuth` as its authorised exemption, mirroring
  `ValidatingChannelSigner`'s wrapper and `migration.rs`'s EIP-712 proof.

## ✅✅✅ #114 STEP 6 — **THE DESIGN IS PROVEN ON REAL BITCOIND.** `regtest/deadman-freshness-e2e.sh`
```
READY: freshness-UTXO invalidation holds at consensus
  (1) matured 2-input exit accepted while freshness unspent
  (2) freshness input spent (rotation)
  (3) same signed exit now rejected: missing-inputs
```
This settles the ONE claim no unit test could: **a fully-signed, locktime-matured exit becomes
UNBROADCASTABLE the instant its freshness input is spent** — the property the entire design rests on, and
the reason a superseded exit can no longer force-close a live channel.
⇒ **Built as a CONTROL + treatment, not a bare assertion.** Step (1) proves the exit IS acceptable while
  both inputs are unspent, so step (3)'s rejection is attributable to the spend and not to a malformed tx.
  Without the control, a permanently-broken tx would have produced the same "pass".
⇒ Also asserts the rejection REASON (`missing-inputs`), not merely that it failed — a tx rejected for the
  wrong reason would otherwise read as proof.
⇒ `bitcoind` v30.2.0 was ALREADY installed under `regtest/.bitcoin-core/` — my earlier "not installed"
  came from `which bitcoind`, which misses it because the harness deliberately keeps it off PATH.
  **A negative from the wrong probe, again.**

### 🐛 TWO REAL BUGS THE HARNESS FOUND IN MY OWN TEST (both silent-pass shapes)
 1. **`gettransaction` details include the CHANGE output of a self-send**, so matching on amount picked the
    wrong vout and the exit referenced a nonexistent outpoint. Symptom: the CONTROL failed with exactly the
    `missing-inputs` the test was designed to look for at the END — **it would have "passed" for entirely
    the wrong reason had I not asserted the control separately.**
 2. **Two sequential `sendtoaddress` calls: the second selected the first's output as its input**, so the
    0.5 BTC UTXO no longer existed. Fixed with a single `sendmany` — both outputs in one tx.
📌 Both are the same family as the money-path unit errors: **a test that fails for the reason you expected
  is not the same as a test that fails for the reason you intended.** The control step is what separates them.

## 🏁 #114 STATUS — STEPS 1-6 COMPLETE (destination allowlist deferred with reasons)
| step | state |
|---|---|
| 1 · freshness threaded through builder/sighash/presign + order guard | ✅ landed, 10/10 |
| 2 · wallet + store reach the heartbeat; `build_exit_call` forwards | ✅ landed, Linux-verified |
| 3 · designate (not mint) the shard UTXO; persist stable + rotating records | ✅ landed |
| 4 · refresh-when-due, rotate, retire AFTER re-emission (veto on failure) | ✅ landed |
| 5 · reservation at BOTH selection paths + test it BINDS; sweep signing deduped | ✅ landed, 110/110 |
| 6 · consensus proof on real bitcoind | ✅ **READY** |
| — · per-path destination allowlist + `SweepAuth` | ⏸️ deferred, own run, reasons recorded |

# ═══ THE 33-ITEM SWEEP — verifying open markers BY EFFECT (started 2026-08-01) ═══
Method per the register's own instruction: grep the code for the MECHANISM, not the name, and record
verified-open / already-done / premise-withdrawn. Measured the real list first: **66 open-marked headers**
in the archive (not 40 — the earlier count excluded some section headers, and some headers are sections
rather than items). Working list at `scratchpad/open33.txt`.

## BATCH 1 RESULTS
### ✅ §A.5e — **ALREADY DONE.** Marker is STALE.
Claim: *"redeem values off `storedHoldings`, refreshes AFTER"*. Code says otherwise — `Aux.sol:927-928`:
```solidity
// §A.5e: value against a bounded-fresh cache. MUST precede redeemAsBody — that is the whole bug.
_requireFreshHoldings();
BasketLib.redeemAsBody(...);
```
`_requireFreshHoldings` (`:403`) refreshes when older than `HOLDINGS_MAX_STALE` and **does not revert**, so
there is no liveness cliff — *"the redeem heals its own staleness"*. The fix even cites §A.5e by name.
⇒ **CLOSE IT.** (4th open-marked item found already built — §A.35, §A.43, #109, now this.)

### 🔴 §A.5g — **GENUINELY OPEN, and worse than recorded.**
`connect_peer_if_necessary` (`p2p.rs:154`) retries a few times **at call time** (bounded, `retries` param).
**No long-lived reconnector task is spawned anywhere in the daemon** — `grep spawn … | grep -ci 'p2p|peer|
connect'` in `daemon.rs` = **0**.
⚠️ **TWO comments assert a reconnector that does not exist:** `vault.rs:534` *"the reconnect path will
  retry"* and `p2p.rs:193` *"a race between the reconnector and open_channel"*. Both read as evidence of a
  component that is not wired — almost certainly inherited from the upstream node this code came from.
⇒ Impact: if the vault↔hop link drops after startup, **nothing re-dials**. Every channel op then fails
  until a restart. **This is a liveness bug, not just a missing feature.**

### 🔴 §J.8b (`outOfRange` dedup) — **GENUINELY OPEN + a confirmed DEDUP target.**
SIX declarations, split by asset rather than parameterised:
`Core.sol:551` · `Vogue.sol:350` · `Vault.sol:939 (outOfRangeBtc)` · `Interfaces.sol:194` ·
`BtcVaultLib.sol:285 (outOfRangeBtc)` · `SwapLib.sol:1702` — 27 references tree-wide.
⇒ The `outOfRange` / `outOfRangeBtc` pair is the SAME logic forked on asset — exactly the shape the deep
  dedup pass exists to collapse. **Feed it there rather than fixing in isolation.**

### 🐛 NUMBERING COLLISION — **two different items are both "§J.8"**
`BUILD-QUEUE-AND-107.md:760` = weETH-on-Aave-v4 yield leg · `:818` = `outOfRange` dedup.
⇒ Referring to "§J.8" is ambiguous, and a status set on one silently reads as the other. Disambiguated here
  as **§J.8a** (weETH/Aave) and **§J.8b** (outOfRange). This is the `commit-often-and-name-precisely` trap
  in the tracking doc itself.


---

# 📋 NEW ITEMS FROM THE FUNDRAISING/FAQ SESSION (2026-08-01)

These surfaced while writing `docs/FAQ.md` and auditing its claims against source. They were
initially recorded in that FAQ's Part 8, which was the **wrong place** — the FAQ is a fundraising
document and this file is the single status list. Restated here. **The FAQ carries no pointer back** —
it states permanent facts only, and it now ASSERTS the post-fix state for E1 (see the warning in E1
itself), so these items are invisible from there by design.

## E1. Close the three `Vault` owner setters, or record why they survive launch
`Vault.sol:355` `setRover`, `:362` `setLevManager`, `:372` `setLevManagerBTC`. No renounce found on
`Vault`, while `Aux.finalize()` and `Vogue.setup()` both renounce and `LevManager`'s venue allowlist is
pin-once-then-frozen. `docs/FAQ.md` Part 6 argues to counsel that after launch **no function any person
can call changes where depositor assets are deployed**; these three contradict that claim in code.
**Highest-value item in this batch: cheap, unilateral, and it closes a legal argument.**

> ⚠️ **THE FAQ ALREADY ASSERTS THIS IS DONE.** `docs/FAQ.md` Part 6 tells counsel that after launch no
> function any person can call changes where depositor assets are deployed, and Part 7 no longer carries
> the contradiction as a caveat (the user's instruction was that the FAQ state permanent facts and assume
> this queue is finished). **Until E1 lands, that document overstates by three setters.** Either close
> them or re-insert the caveat before the FAQ is shown to anyone.

## E2. `feeSettleSats` has no Forge test
`BTCChannels.splice` takes `feeSettleSats`, guarded by `require(feeSettleSats <= grewBy)` and clamped
vault-side in `settleBtcFeesOwed`. Driven from `quid-bridge/channel_driver.rs:844-870`. **Nothing in
`evm/test/` references it.** A live money path with two guards and no on-chain test on either.

## E3. Decide the θ question — θ prices a cost this pool does not have
θ ≤ `yield/(K·σ²−f)` is an **LVR-sizing** inequality, introduced to bound how much shared surplus
`arbETH` could drain. `arbETH` is removed and the LP bears its own IL via the share price. And swaps
execute at the internal TWAP over Core-only mock tokens under `onlyUs`, so **there is no public-LP LVR
here at all** (`IL-FINDINGS-2026-06.md` §1) — the real cost is composition divergence on reseat plus a
≤50 bps execution lag.

Symptoms both directions: it **thins the band in a vol spike**, when swap demand and fees peak and a
venue most needs depth; and it stays **wide in the low-σ grind**, which our own sim
(`find_makewhole_window.js`) flags as the one real exposure (~10% upper-bound gap).

Options: drop θ and bound depth only by `surplus = TVL − committed` plus the physical deposit, or
re-derive a clamp from the execution lag. Counter-argument to weigh: the band's dollar leg is **basket
capital**, so deeper depth converts more basket dollars into the falling asset; `surplus` bounds the
level of that but not the rate. **Live money-path parameter — needs its own run with a falsifiable
prediction stated first.**

## E4. Rename `registerBtcLp`
Called at open (`BTCChannels.sol:727`) **and again on every GROW splice** (`_applySplice`, `:813`),
while the SHRINK half calls `resizeBtcLp`. Two halves of one operation under two verbs, one implying a
once-per-channel registration. `creditBtcLp` / `addBtcLiquidity` would match its sibling. **ABI change**
consumed by `quid-hop/src/evm_codec.rs` — needs `tools/check-client-abis.py` and a test run.

## E5. Finish the stale-comment sweep
A semantic scan on 2026-08-01 found ~10 sites naming deleted machinery as if live. **Fixed this
session:** `Vault.btcFeesOwedSats` NatSpec (said fees are "NOT compounded into `pooled`" — false since
the fee-splice landed, and it caused a downstream doc error); two short-subsystem comments in
`LevManager._rebalanceBody`; both keysend legs (obsolete under delegation, the LP runs no LN node);
`BTCChannels` header calling the bridge `Vogue.registerBtcLp`; `QuidLens` baseRate NatSpec;
`spa/src/lib/quant.ts` "leverage overlay not built yet".

**Still outstanding:** `Aux.sol:52` advertises an `arbETH` forwarder the same file records as removed ·
`Aux.sol:735` "used by internal arbETH/arbBTC" · `Aux.sol:888`, `:1008`, `:1015` describe `baseRate` as
live where the same file records its removal · `Vault.sol:43` justifies the `onlyUs` set by arbETH ·
`Core.sol:568` points at `refillETH`/`ETHRefillRequest` · `DeployLib.sol:236` and `:252` describe SOR
path arrays as "arbETH/arbBTC iterates these" · `Basket.sol:50` names `onReport`.

## E6. Review the built-but-gated surface as a set
Each is off for a stated reason; the point is to decide them together rather than rediscover them one at
a time. `soldFractionActive` (default off in both leverage managers, so the `1−√(entry/now)` estimate
stays active) · `AttestedHopRegistry` (no-op until governance pins it; falls back to an
owns-an-open-channel gate) · on-chain swap-out rail B (`QUID_SWAPOUT_ONCHAIN`, off, explicitly wants a
real bitcoind e2e first) · ibiza's `SpvTreasuryAdapter` and `AaveCreditLine` (built and tested, not
called by PP core).

## E7. Documentation corrections applied this session (record, not a task)
Retraction banners rewritten against source in `IL-VIA-BONDS.md`, `IL-CERTIFICATION.md`,
`IL-FINDINGS-2026-06.md` (all three announced a bidirectional short removed 2026-07-24, and all three
cite a canonical `LEVERAGE-ENGINE-SPEC.md` that does not exist). `FEES-OUTFLOWS-TWAP.md` baseRate
update retracted. `ETH-VENUES.md` venue table corrected (no id 1; Gauntlet added).
`quid-ln/OFFCHAIN-STRATEGIES.md` corrected on delegation and on per-obligation proceeds. Band width is
**±0.2%** (`BAND_DELTA = 20`), not the ±2% every θ/K figure in `IL-CERTIFICATION.md` is keyed to.

## BATCH 2 RESULTS — 3 more markers are STALE. Running tally: 4 DONE · 2 GENUINELY OPEN.
### ✅ §A.18 (*"THE FORK IS NOT PINNED — the whole fork suite is NON-REPRODUCIBLE"*) — **DONE.**
`test/utils/ForkPin.sol` exists and **7 test contracts inherit it**. Fixed THIS SESSION (the root-cause fix
for the reverts-on-environmental-failure problem: pin the CURRENT block, not a historical one).
⇒ Note the marker was still 🔴 while the fix was landed and in use — **the archive lags the code.**

### ✅ §A.13 (*"band restoration DISABLED BY THE CONDITION IT EXISTS TO FIX"*) — **DONE.**
`SwapLib.sol:165` carries the fix AND cites the item: *"`price == 0` MUST fall through to the anchor, not
short-circuit past it (fixed 2026-07-26, BUILD-QUEUE §A.13)"*, and the comment then restates the exact
self-reinforcing deadlock the archive describes (drain → `MAX_SQRT_RATIO` → `ticksToPrice` 0 → `twap == 0`
→ `didRepack == false` → `addLiq` never called).
⇒ This is the item my `never-mask-the-question` memory came from — the user rejected a test-side depth
  guard that would have hidden it. **The real fix is in place and self-documenting.**

### ✅ §A.8e (*"θ FAIL-OPEN — fix landed, but NOT PINNED BY A TEST"*) — **DONE.**
The missing test now exists: `test/BtcBandTheta.t.sol::test_BtcBand_ThetaThrottlesInRangePairing`, which
asserts BOTH sides — the fail-open baseline pairs (`assertGt(d1, 0, "baseline: fail-open theta pairs …")`)
and the throttled case does not. **A control-and-treatment test, which is exactly what "pinned" requires.**

## 📊 SWEEP TALLY SO FAR (6 of 66 headers checked)
| verdict | items |
|---|---|
| ✅ already done, marker stale | §A.5e · §A.18 · §A.13 · §A.8e |
| 🔴 genuinely open | §A.5g (no reconnector task — a LIVENESS bug) · §J.8b (`outOfRange` ×6 — dedup target) |
⇒ **4 of 6 checked were already built.** The register's own warning is holding: *"a meaningful share are
  probably ALREADY DONE"*. ⇒ **The real backlog is much smaller than the marker count**, and the sweep is
  worth finishing before any of these are planned as work.
⇒ 📌 Emerging pattern: **the fixes are self-documenting — three of four cite their own item number in a
  code comment.** So `grep -rn "§A\.\|BUILD-QUEUE §" src/` is a fast first pass for "is this already
  done?" before any mechanism reasoning. **Use that to accelerate the remaining 60.**

## BATCH 3 — citation sweep across 31 code-referenced items. **Confidence is stated, not implied.**
Bulk-extracted every item reference in `src/`+`test/`: **31 distinct items are cited in code**
(A.11 A.13 A.14 A.15 A.16b A.16d A.18 A.19b A.20 A.22 A.24 A.25 A.29 A.45 A.46 A.48 A.50 A.52 A.54
A.55 A.56 A.57 A.5c A.5e A.5f A.70 A.72 A.9 J.2 J.2b J.3 J.4).
⚠️ **A citation is NOT proof of completion** — it can equally mark a TODO. So each is classified by what
the citing line SAYS, and anything short of an explicit repair is marked as needing a deeper check.

| item | citing line | verdict | confidence |
|---|---|---|---|
| **§A.16b** | `VEth.sol:29` *"the same-clock invariant **repaired in** §A.16b"* | ✅ DONE | **HIGH** — says repaired |
| **§A.25** | `LevOracles.sol:19` (with §A.13); header itself reads *"CLASS **CLOSED** AT THE MORPHO ORACLES"* | ✅ DONE | **HIGH** |
| **§A.5c** | `VaultLib.sol:182` *"READ THE NAME NARROWLY (§A.5c, **re-derived** 2026-07-27)"* | ✅ premise WITHDRAWN (already recorded) | **HIGH** |
| **§A.24** | `Core.sol:809` *"TRUSTED-ARG CHECK (audit residual, §A.24)"* — a check IS implemented | ✅ likely DONE | 🟡 MED — item says **TWO** residuals; only one located |
| **§A.9** | `test/EthExitConservation.t.sol:36` — a conservation test exists | ✅ likely DONE (item claims the shortfall was a MEASUREMENT ARTIFACT) | 🟡 MED |
| **§A.15** | `test/ForwardMintHeadroom.t.sol:112` — test exists and reasons about the buffer | ✅ likely DONE | 🟡 MED — earlier note said *"mechanism present, claim still unverified"* |
| **§A.5f** | `Vogue.sol:225` *"§A.5f (**subset**): TIMELOCKED WITHDRAWAL-RECIPIENT PIN"* | ⚠️ **PARTIAL** | **HIGH** — subset landed; the MAIN item (per-action auth) verified absent earlier |
| **§A.19b** | `VBtc.sol:18` — cited as CONTEXT for segregation, not as a fix | 🔴 **OPEN** | **HIGH** — `redeemVBtc` verified absent; it is a DESIGN DECISION for the user |

## 📊 RUNNING TALLY (14 of 66 headers now assessed)
✅ **DONE (high confidence):** §A.5e · §A.18 · §A.13 · §A.8e · §A.16b · §A.25 · §A.5c — **7**
✅ **DONE (medium — verify before closing):** §A.24 · §A.9 · §A.15 — **3**
⚠️ **PARTIAL:** §A.5f (subset only) — **1**
🔴 **GENUINELY OPEN:** §A.5g (liveness bug) · §J.8b (dedup target) · §A.19b (user design decision) — **3**
⇒ **10 of 14 assessed are done or effectively done.** The backlog is dramatically smaller than 66 markers
  implied — consistent with the register's own warning, now measured rather than suspected.
▶️ NEXT: the ~35 headers with NO code citation. Absence of a citation is NOT evidence of open (my own
  rule) — those need the mechanism grep, which is slower. Prioritise any that are 🔴🔴 (money-path).

## 🔑 BATCH 4 — **STRUCTURAL FINDING: the marker count is inflated by the doc's own format.**
Split the 66 headers into cited (31) vs uncited (22 open-marked items) and read the uncited ones. The
decisive discovery is not about any single item:
🎯 **The archive records resolutions as SEPARATE LATER SECTIONS while the ORIGINAL header keeps its 🔴.**
So a resolved item appears TWICE — once as an open header, once as its resolution — and any count of
🔴 headers **double-counts every item that was ever revisited.** Verified instances:
| item | original header | later section that RESOLVES it |
|---|---|---|
| **§A.58** | `:3852` 🔴 *"`reseat()` CANNOT HEAL THE DEADLOCK"* | `:3953` **STRUCK** (*"NOT an off-by-one; the legacy stress-tested repo uses the IDENTICAL condition"*) + `:3981` **DOWNGRADED** (*"the JIT refill covers this — KEEPER work, not a defect"*) |
| **§A.59** | `:4014` 🔴 *"STALE-COMMENT CONTRADICTION"* | `:4041` **RESOLVED** (*"no contradiction"*), then `:4066` **CORRECTED AGAIN** — *"#109's AUTO-TRIGGER was restored"*, evidenced at `Vogue.sol:36` + `:483` (*"✅ DONE (#109). INLINE WIRING IS LIVE"*) |
⇒ **Both are CLOSED, and both still present as 🔴 headers.** ⇒ **The "40 open items" figure was never a
  backlog — it was a count of section headings.**
⇒ 📌 **This is the same defect class as a stale comment**, applied to the tracking document: the marker
  describes a past state and cannot fail. **Trust the LATEST section about an item, never the first.**

### Also assessed in this batch
| item | verdict |
|---|---|
| **§A.41** (*stale bytecode invalidates mutation checks*) | ✅ NOT a build item — a METHOD lesson, already promoted to the STANDING TRAPS list (*"`forge build --force` before any test"*). **Close as a lesson.** |
| **§A.16** (*levered LP expenses passive LP ~7.5%*) | ✅ likely resolved by **§A.16b's** repair (`VEth.sol:29` *"the same-clock invariant repaired in §A.16b"*) — A.16 is the FINDING, A.16b the MECHANISM+FIX. 🟡 MED: confirm the 7.5% is gone with a test before closing. |
| **§A.23** (*actionable-folder triage*) | ✅ process/bookkeeping, not code. Superseded by QUEUE.md replacing the archive. |
| **§A.71** (*codebase-wide dedup, "every struct, everything"*) | 🔴 **GENUINELY OPEN** — this IS the deep dedup pass now queued next. |
| **§A.51** (*`preferred` fee exists but deliberately DISCONNECTED*) | 🔴 open QUESTION for the user, not a bug: reconnect it or document why not. |

## 📊 TALLY (20 of 66 assessed)
✅ DONE / closed / not-a-build-item: §A.5e §A.18 §A.13 §A.8e §A.16b §A.25 §A.5c §A.58 §A.59 §A.41 §A.23 — **11**
🟡 likely done, confirm before closing: §A.24 §A.9 §A.15 §A.16 — **4**
⚠️ PARTIAL: §A.5f — **1**
🔴 genuinely open: §A.5g (liveness) · §J.8b (dedup) · §A.19b (design) · §A.71 (the dedup pass) · §A.51 (user question) — **5**
⇒ **Of 20 assessed, only 5 are real open work — and 2 of those are the dedup pass and a user decision.**

## 🤖 BATCH 5 — automated triage of all open IDs, and **why it must not be trusted alone**
Classified every open item by whether a LATER section resolves it (the format defect found in batch 4):
**13 have a resolving later section** — `A.19b A.35 A.41 A.43 A.54 A.55 A.57 A.58 A.5e A.61 A.62 A.8e J.7`
**30 do not** — `A.13 A.15 A.16 A.16b A.18 A.23 A.24 A.25 A.31 A.45 A.46 A.48 A.49 A.5 A.50 A.51 A.56
A.59 A.5b A.5c A.5f A.5g A.71 A.72 A.8 A.8b A.8c A.9 J.2 J.8`

### 🔴 THE CLASSIFIER IS WRONG IN **BOTH** DIRECTIONS — proven, not suspected
 • **FALSE POSITIVE** — it marked **§A.19b resolved** at `:2848`. That line reads *"§A.19b — **SCOPED**
   2026-07-27. It is a **WIRING JOB** over a proven rail, not a new capability."* **Scoped is not done.**
   And I verified independently from CODE that `redeemVBtc` does not exist ⇒ **genuinely open.**
 • **FALSE NEGATIVE** — §A.13, §A.18, §A.25 all landed in "no resolving section", yet I verified each from
   CODE as **done** (`SwapLib.sol:165` *"fixed … §A.13"*, `ForkPin.sol` in use by 7 contracts, the §A.25
   header itself says CLOSED). **Their fixes were never written back to the archive at all.**
⇒ 📌 **CONCLUSION: the document cannot classify itself.** Doc-derived status is triage ONLY; **the CODE is
  the authority.** That is the same rule already learned for comments (`stale-comments-are-false-evidence`)
  and for greps (`never-assert-absence-from-a-grep`) — now confirmed for the tracking doc as well.

## 🏁 SWEEP CONCLUSION — the 33/40 backlog figure is NOT REAL
Of the items assessed against CODE this session:
| verdict | count | items |
|---|---|---|
| ✅ done / closed / not-a-build-item | **11** | §A.5e §A.18 §A.13 §A.8e §A.16b §A.25 §A.5c §A.58 §A.59 §A.41 §A.23 |
| 🟡 likely done — confirm before closing | **4** | §A.24 §A.9 §A.15 §A.16 |
| ⚠️ MISLABELLED (see §A.5f entry below) | **1** | §A.5f — the landed piece is a SEPARATE control; the real item is a NEW SUBSYSTEM |
| 🔴 genuinely open | **6** | §A.5g (LIVENESS bug) · §J.8b (dedup) · §A.19b (design decision) · §A.71 (the dedup pass) · §A.51 (user question) · §J.2c (Vogue ERC-20 face) |
⇒ **The real open set is ~6 items, not 33** — and of those, §A.71 IS the dedup pass, §A.19b and §A.51 are
  USER DECISIONS, and §J.8b folds into the dedup. **That leaves §A.5g (the reconnector liveness bug) and
  §J.2c (the Vogue refactor) as the only genuine engineering work outstanding from the register.**
▶️ **RECOMMENDATION: stop sweeping.** The remaining unassessed headers are overwhelmingly resolutions,
  method notes, and section headings — the sweep has already answered the question it existed to answer
  (*"how big is the backlog?"* → small). **Go to §A.5g + §J.2c, then the dedup pass (§A.71).**

## ✅ MARKED OFF — 11 archive headers updated to `✅ VERIFIED-DONE 2026-08-01`, each with its CODE evidence
The four 🟡 "likely" items are now CONFIRMED against code, not inferred:
| item | confirming evidence |
|---|---|
| **§A.24** | `Core.sol:815` — `require(StateLibrary.getPositionLiquidity(...) == 0, "repack:stale")`. Residual 1 (the `myLiquidity` trusted-arg) is CLOSED by a real assertion that reasons about the ASYMMETRIC failure (too-high already reverts; too-low silently strands). Residual 2 (RISK-2 bootstrap over-mint) is explicitly *"by-design, watch"* — accepted, not a bug. |
| **§A.9** | `test/EthExitConservation.t.sol:79` — `assertApproxEqRel(ethGained + usdClaimInEth, pooledDrop, 0.02e18)`. Conservation HOLDS ⇒ the "~20% shortfall" WAS the measurement artifact the item concluded. |
| **§A.15** | `test/ForwardMintHeadroom.t.sol` — pins steady state incl. *"cap floors credit at ~principal"* and one maturity cohort per mint. |
| **§A.16** | `test/LeverageCrossSubsidyProbe.t.sol` — a REAL-stack regression asserting the exact finding: *"A PASSIVE regular band LP is NOT expensed by a LEVERED LP's full lifecycle"*, measured at a MATCHED price to strip the lever's own rally. |
**Headers updated:** §A.5c (×2 — original + its own resolution section) · §A.5e · §A.8e · §A.9 · §A.13 ·
§A.15 · §A.16 · §A.18 · §A.24 · §A.41.
⚠️ Marking was done by exact header match with a guard against double-marking, and each edit was
  re-read afterwards — `A.16` did NOT match `A.16b` (word boundary), and both `A.5c` hits were verified to
  be genuine A.5c sections before accepting.

### ▶️ REMAINING REAL WORK (unchanged by the mark-off)
 1. ⚠️ **§A.5f** — NOT a partial (see the scoping entry). A NEW authorisation SUBSYSTEM; needs a design run, NOT a quick finish.
 2. 🔴 **§A.5g** — no reconnector task (liveness).
 3. 🔴 **§J.2c** — the Vogue ERC-20 face refactor.
 4. 🔴 **§A.71 / §J.8b** — the dedup pass (+ the hand-rolling audit).
 5. ❓ **§A.19b · §A.51** — user decisions, not engineering.

## ✅ §A.5g FIXED — the reconnector that was documented but never built. **144/144 bridge tests pass.**
**The bug:** LDK's `PeerManager` owns sockets but **never re-dials**, and the vault's startup dial is
one-shot. The only caller of `connect_peer_if_necessary` outside the fix was the **TEST harness**. So in
production a dropped vault↔hop link **stayed dropped**, and every channel op failed until a restart.
**The fix (small, reuses the existing primitive):**
 • `VaultNode::ensure_hop_connected()` — carries the hop's dial address (previously discarded after the
   one-shot dial) and calls the existing `connect_peer_if_necessary`, which is a **no-op while connected**.
 • A task in the daemon `JoinSet` re-checks every 30s. `MissedTickBehavior::Delay` so a stalled tick cannot
   fire a BACKLOG of dials. **Warns only on a FAILED re-dial** — a healthy link stays silent, or the log
   stops being read.
**Verification:** `cargo check -p quid-bridge` clean; `cargo test -p quid-bridge --lib` → **144 passed,
0 failed** (no regression from this or from #114).
🔴 **The false evidence that hid it:** `OFFCHAIN-STRATEGIES.md:99-105` claimed *"Persistent hop reconnector
  — LIVE, `quid-hop/src/reconnect.rs`"*. **That file never existed.** Doc corrected in place with an
  explicit CORRECTED note, so the next reader learns the failure mode rather than re-trusting it.

## 🛑 §A.5f — NOT a "finish the partial". It is a NEW SECURITY SUBSYSTEM. Scoping before building.
My earlier "PARTIAL" label was misleading, and acting on it would have been the mistake:
 • **Landed:** the *timelocked withdrawal-recipient pin* (`Vogue.sol:225`) — a genuinely separate, small
   control that happens to share the section number.
 • **Missing:** *on-chain per-action delegation* — EIP-712 typed permissions, **scoped + capped + revocable**,
   for the delegated strategy layer. Today the on-chain gates are only COARSE (`onlyUs`, `vogueSyncHook`,
   `msg.sender == V4`), which say *"this exact contract"* — never *"this action, up to this size, until this
   time, revocable"*.
⇒ **That is a new authorisation surface on the money path, not a finishing touch.** Shipping it hastily is
  precisely how a bug gets created.
### ▶️ DO NOT HAND-ROLL — the EIP-712 machinery ALREADY EXISTS here
`quid-hop/src/migration.rs` implements EIP-712 `MigrationAuth`: **Gnosis Safe as `verifyingContract`,
≥`MIGRATION_THRESHOLD` owner signatures, `ecrecover` verified IN-ENCLAVE**, plus `guard_prod_trust_anchors`
refusing prod while dev placeholder keys are compiled in. **§A.5f's `ActionAuth` should mirror that exact
shape** — same domain-separator discipline, same threshold model, same anchor guard.
⇒ It ALSO shares the shape `SweepAuth` needs (the deferred `create_sweep_tx` trigger). ⭐ **One typed-auth
  primitive would serve §A.5f, `SweepAuth`, AND the destination allowlist's exemption** — three open items,
  one mechanism. **Design it once, deliberately.**
⚠️ Explicitly OUT of scope (by design, per the item): the optimal-entry ALPHA logic stays off-chain /
  LP-discretionary, and the BTC path needs nothing — `lpAuth` is already `ecrecover` over
  `BTCChannels.openChannelDigest`.


## 📌 §A.5f — BANKED AS A STANDALONE TASK (user asked for this explicitly, 2026-08-01)
**Recording this so it cannot be lost or re-misread as a small finish.**

### 🔴 THE MISLABEL — and why acting on it would have been the bug
I called §A.5f "PARTIAL", which implies a finishing touch. It is not:
 • **Landed:** the *timelocked withdrawal-recipient pin* (`Vogue.sol:225`) — a genuinely SEPARATE, small
   control that merely **shares the section number**. It is done and closes nothing of the real item.
 • **Missing:** *on-chain per-action delegation.* Today's on-chain gates are only COARSE — `onlyUs`,
   `vogueSyncHook`, `msg.sender == V4`. They say **"this exact contract"**. They NEVER say
   **"this action, up to this size, until this time, and revocable."**
⇒ **That is a NEW AUTHORISATION SURFACE ON THE MONEY PATH**, not a finishing touch. Rushing it is exactly
  how a bug gets created — the thing the user asked to avoid. **It needs its own design run.**

### ✅ DO NOT HAND-ROLL — the primitive already exists in this repo
`quid-hop/src/migration.rs` implements EIP-712 **`MigrationAuth`**:
 • Gnosis **Safe** as `verifyingContract` (domain separator bound to the operator multisig),
 • **≥`MIGRATION_THRESHOLD`** owner signatures,
 • `ecrecover` verified **IN-ENCLAVE**,
 • `guard_prod_trust_anchors` **refusing prod** while dev placeholder keys are compiled in.
⇒ **§A.5f's `ActionAuth` should mirror that exact shape** — same domain-separator discipline, same
  threshold model, same anchor guard. Copy the REASONING, not just the structure.

### ⭐ ONE PRIMITIVE SERVES THREE OPEN ITEMS — design it once
| open item | what it needs |
|---|---|
| **§A.5f** | scoped + capped + revocable per-action delegation for the strategy layer |
| **`SweepAuth`** (`create_sweep_tx`, QUEUE:2251 — deliberately unwired) | a Safe-authorised trigger for a full drain |
| **destination-allowlist exemption** (deferred in #114 step 5) | the one signed exception to deny-by-default |
⇒ All three are *"a Safe-signed, typed, scoped authorisation"*. **Building them separately would triplicate
  a security-critical mechanism** — the exact hand-rolling the user flagged. **Design ONE `TypedAuth`
  primitive and give each item a scope type.**

### ⚠️ EXPLICITLY OUT OF SCOPE (per the item itself — do not widen it)
 • The optimal-entry **ALPHA logic stays OFF-CHAIN / LP-discretionary** — by design, not a gap.
 • The **BTC path needs nothing**: `lpAuth` is already `ecrecover` over `BTCChannels.openChannelDigest`.
 • The off-chain half is **BUILT**: `quid-common/src/api/revocable_clients.rs` (ed25519 keys, per-client
   scopes, revocable). The gap is ON-CHAIN only.

# 🚨🚨 REGRESSION I INTRODUCED — **SwapLib is OVER EIP-170. The library is UNDEPLOYABLE.**
```
| SwapLib | 24,672 |
Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)
```
**96 bytes over.** Verified it predates today's §J.2c edit (stashed `Vogue.sol`, rebuilt, still 24,672), so
it came from **C4 and/or C10 part 2** — both landed in `SwapLib` earlier today.
🔴 **HOW IT SLIPPED THROUGH — and this is the important part:**
 • I measured SwapLib at **24,358 (margin 218)** after the `volScale` cleanup and **explicitly noted the
   margin mattered because C4 lands in SwapLib**. Then I landed C4, and **never re-measured.**
 • **`forge test` DOES NOT ENFORCE EIP-170** — all 3,529 tests passed against a library that cannot be
   deployed to mainnet. **A green suite is not a deployability check.** Only `forge build --sizes` is.
 • This is a textbook `measure-a-fix-from-all-sides` failure: I verified C4's CORRECTNESS (tests, units,
   call sites) and never its SIZE — on the one library I already knew was the tightest in the repo.
📌 **NEW STANDING CHECK: `forge build --sizes` after ANY `SwapLib`/`Core`/`Vogue` change, in the SAME run
  that reports the tests.** Green tests + over-limit bytecode is a silent, deploy-time-only failure.

## ▶️ FIX (in progress) — reclaim ≥96 bytes in SwapLib before continuing §J.2c
§J.2c is PAUSED (step 1 is additive and compiles; it does not affect SwapLib). The size regression is
higher priority: it makes the money-path library undeployable, which no test would ever surface.

## ✅ SIZE REGRESSION FIXED — SwapLib **24,223** (was 24,672, limit 24,576). Margin **353**. Suite 3529/31.
Three changes, in increasing order of how much they mattered:
| change | bytes | note |
|---|---|---|
| C10 tail dedup — the capacity skip duplicated `waitNft(...)`; both paths now fall through to ONE tail | **24** | also removes a duplicated exit path |
| `sellSkew` `public` → `internal` — **zero external callers** (verified across `src/` + `test/`) | **83** | dead EXTERNAL surface; satisfies the no-unreachable-code rule as well as the size problem |
| ⭐ **`_skewBasis` — the shared prologue of `wellSkew`/`sellSkew`** (user's suggestion) | **342** | the real lever |

### 🔑 On "could wellSkew and sellSkew be unified?" (user) — PARTIALLY, and the distinction matters
 • **Shared (now extracted):** both convert pool inventory AND gross levered collateral to 6-dec USD with
   the IDENTICAL `mulDiv(·, base, 1e30)`, then call `skewWad`. That prologue was duplicated VERBATIM.
 • **Genuinely different (NOT flattened):** `wellSkew` feeds `skewWad` DIRECTLY; `sellSkew` computes
   `inv`, **mirrors it about target** (`2·target − inv`), and passes a reconstruction
   (`committed + mirror, committed, committed`). That mirror IS the A-S inventory-sign flip that makes a
   REFILLING sell exempt (skew 0) while an inventory-INCREASING sell is priced.
 ⇒ A `bool isSell` flag would have unified the signatures while hiding that semantic fork behind a
   parameter. **Extracting the prologue captures the duplication; keeping the divergence keeps the
   meaning** — the same judgement applied to the five signing paths in #114.
⇒ `addedTok` (0 for a drain, the unsettled input for a sell) is the one parameter the shared half needs.

### 📌 THE LESSON THAT MATTERS MORE THAN THE BYTES
**`forge test` does NOT enforce EIP-170.** 3,529 tests passed against a library that could not be deployed.
The regression existed from the moment C4 landed and was invisible to every check I was running.
⇒ **NEW STANDING RULE (added to the traps list): after ANY change to `SwapLib`/`Core`/`Vogue`/`Aux`, run
  `forge build --sizes` IN THE SAME RUN as the tests.** Green tests + over-limit bytecode is a
  deploy-time-only failure, and it is silent until then.
⇒ I had even WRITTEN that the 218-byte margin mattered "because C4 lands in SwapLib" — then landed C4 and
  never re-measured. **Writing down a risk is not the same as checking it.**

# 🔴 THE "31 ENVIRONMENTAL FAILURES" VERDICT WAS **WRONG**. Both were REAL BUGS. (2026-08-01)
`QUEUE.md:720` concluded *"THE 31 FAILURES ARE ENVIRONMENTAL"* — ether.fi's live pool depth on an unpinned
fork. **That was wrong for BOTH tests, and it cost three correct changes (C5/D3/C2) which were reverted on
that false evidence.** Root-caused properly today:

## ✅ FAILURE 1 — `testEthVenue_EtherFi_InstantRedeem_Rung3`: a **SILENT NO-OP MOCK**. **NOW PASSES.**
The test mocked `ethAmountLockedForWithdrawal()` on the LiquidityPool. **That function DOES NOT EXIST** on
the implementation (`0x17a1…4a45`; selector-matched its bytecode — its real accessors are
`getTotalPooledEther` / `totalValueInLp` / `totalValueOutOfLp`). **A `vm.mockCall` on an absent signature is
a silent no-op**, so the gate it was meant to neutralise stayed live for the test's whole life.
⇒ The capacity is a **low-watermark function of ether.fi's TVL** (verified on mainnet: 2000e18 at block
  25600000, 0 at 25647331 — the block a 10k-ETH exit dropped the pool under the mark; dealing balance alone
  does nothing, 400_000 ether was tried). Mocking `getTotalPooledEther()` — the TVL the watermark is bps of
  — makes it **PASS**.

## ✅ FAILURE 2 — `testLeverage_LvrControlVsTreatment`: **THE CONTROL WAS NOT A CONTROL.**
The three CONTROL redeems reverted `"too soon"` (`Vogue.sol:540`, the JIT `block.number > lastDepositBlock`
guard). `vm.revertToState(snap0)` rewinds the block too, while the TREATMENT rolls a block per `_open` — so
the treatment cleared the guard and the control could not. `_lpValueUsd`'s try/catch turned that revert into
**0**, which is exactly what its own PREMISE assertion exists to catch. **It caught it. For weeks nobody read
it as a test bug.**
⇒ Fixed by restoring the treatment's final block/timestamp after the revert, so **opens are the only
  variable**. Un-matched, it compared an AGED pool against a BRAND-NEW one and called the difference a
  leverage externality.

### 🔴🔴 AND THE FIX REVEALED A REAL FINDING — which CONTRADICTS my own mark-off today
With a valid control, the test now measures:
| scenario | control USD18 | treatment USD18 |
|---|---|---|
| ETH +20% | 893,020 | — |
| **ETH flat** | **744,183** | **684,216** |
| ETH −20% | 595,346 | — |
⇒ **Treatment is 8.06% BELOW control at an unchanged price** — i.e. *"leverage flow leaves the passive LP
  worse off than no flow"*, the assertion's own words. **That reproduces §A.16 (*"a levered LP's lifecycle
  EXPENSES the passive LP by ~7.5%"*) at 8.06%.**
🔴 **I marked §A.16 `✅ VERIFIED-DONE` EARLIER TODAY** on the strength of `LeverageCrossSubsidyProbe.t.sol`
  existing and asserting the invariant. **That mark is now in doubt and must be re-opened**: two probes
  disagree, and a passing probe does not outrank a measured 8% gap.
⚠️ **DO NOT "fix" the assertion.** Either (a) the externality is real and §A.16 is NOT closed, or (b) my
  time-matching credits the control with yield the treatment paid for. **Resolve which — the two probes
  measure the same claim and must agree.** ⇐ **NEXT ACTION.**
📌 LESSON: my mark-off used *"a test exists that asserts it"* as evidence of correctness. **A test's
  EXISTENCE is not its VERDICT** — and here a second test, once repaired, says the opposite.

## ✅✅ SUITE: **3559 passed / 1 failed** (was 3529/31). EIP-170 clean (0 exceedances).
| | before | after |
|---|---|---|
| passing | 3,529 | **3,559** |
| failing | 31 | **1** |
| over-size contracts | 1 (SwapLib) | **0** |
**+30 tests recovered** — all from the rung-3 silent-no-op mock (the 30 were inheritance amplification of
that one test). The ONE remaining failure is `testLeverage_LvrControlVsTreatment`, which now measures a
REAL 8.06% gap rather than reverting vacuously.
🔑 **This retro-explains the archive's "3,559 / 1" baseline** (`QUEUE.md:728`), which I had dismissed as
  *"simply a run where their pool happened to be deep enough"*. **It was not luck — 3559/1 was ALWAYS the
  true baseline.** The extra 30 were the broken mock, present the whole time and misattributed to fork
  state. **A number that "only appears sometimes" deserved a root cause, not an explanation.**

### Changes in this run (all three verified together by the full suite)
 1. `test/Alles.t.sol` — rung 3 mocks `getTotalPooledEther()` (the TVL the watermark is bps of) instead of
    a NON-EXISTENT `ethAmountLockedForWithdrawal()`. **+30 tests.**
 2. `test/LeveragePnLProbe.t.sol` — the control is TIME-MATCHED to the treatment (restore block/timestamp
    after `revertToState`), so its redeems clear the JIT guard and opens are the only variable.
 3. `src/imports/VaultLib.sol` — `_withdrawableOf` falls back to `convertToAssets(balanceOf)` when
    `maxWithdraw` REVERTS (Euler does, with no controller enabled; its `liquidityAdapter()` is also absent
    on the current impl, so both probes miss). Previously a real, liquid position valued at **0**.
    ⇒ Extends the SAME principle already landed for Morpho-V2 (*"the max-views are conservative,
      `withdraw()` self-deallocates"*, BUILD-QUEUE:275) to the REVERTING case. No regression in 3,559 tests.

### ▶️ THE ONE REMAINING FAILURE — a real question, not a broken test
`684,216` (treatment) vs `744,183` (control) at unchanged price = **−8.06% for the passive LP**.
**Resolve before closing §A.16** (whose ✅ mark I set today and now doubt):
 (a) the externality is REAL ⇒ §A.16 re-opens, and `LeverageCrossSubsidyProbe` (which passes) is measuring
     something narrower than it claims; or
 (b) the time-match credits the control with venue yield the treatment's opens paid for ⇒ the comparison
     needs the treatment's COSTS attributed, not just its clock.
⚠️ Do NOT adjust the assertion to make it pass. **Two probes of the same claim disagree; that is the finding.**

## 🔴🔴 §A.16 IS **NOT CLOSED** — the 8.06% externality is REAL. My ✅ mark today is RETRACTED.
**Discriminating experiment** (the two hypotheses were: (a) real externality, (b) my time-match credits the
control with venue yield the treatment paid for):
| control @ ETH flat | value |
|---|---|
| WITH `vm.warp` (time-matched) | 744,183,388,520,784,002,862,450 |
| WITHOUT the warp (roll only, clears the guard but no time) | 744,181,157,138,838,756,846,681 |
| **difference** | **~2,231 — 0.0003%** |
⇒ **The warp contributes essentially NOTHING.** Hypothesis (b) is **REFUTED**: the gap is not time-yield.
⇒ ⇒ **Hypothesis (a) stands: leverage flow really does leave the passive LP ~8% worse off** at an unchanged
  ETH price, which is §A.16's finding (*"~7.5%"*) reproduced at **8.06%** on the repaired control.
🔴 **RETRACTING my `✅ VERIFIED-DONE` on §A.16** (set earlier today). The evidence I used was
  *"`LeverageCrossSubsidyProbe.t.sol` exists and asserts the invariant"* — **a test's EXISTENCE is not its
  VERDICT**, and I never checked whether it covers the same scenario.

### 🔑 WHY BOTH PROBES CAN BE RIGHT — they measure DIFFERENT scenarios
| probe | scenario | result |
|---|---|---|
| `LeverageCrossSubsidyProbe` | open → lever → **venue LIQUIDATION** (full lifecycle), at a MATCHED price | ✅ passes — **liquidation socialises nothing** |
| `LeveragePnLProbe::LvrControlVsTreatment` | **20 guard-safe opens, NO liquidation**, valued at 3 prices | 🔴 **−8.06%** |
⇒ ⇒ **The LIQUIDATION cross-subsidy is genuinely fixed (§A.16b's repair). The cost of LIVE OPEN positions is
  NOT.** They are different claims and the passing probe never covered the failing one.
⇒ **§A.16 must be re-opened with THAT scope**: not *"does a liquidation socialise?"* (answered, no) but
  *"does an OPEN levered position drag the passive LP's redeemable value?"* (measured, yes, ~8%).
▶️ NEXT: identify the mechanism. Candidates to check BY EFFECT (do not assume): `deliverableETH` excludes
  the levered slice while `lpShares` does not shrink correspondingly; band depth consumed by opens; BOLD
  spent on opens leaving the basket while the passive LP's share count is unchanged.
📌 The control repair is KEPT (`vm.warp(tTime)` restored) — it is the correct control, and the diagnostic
  above shows it neither creates nor masks the gap.

## ✅ §J.2c — THE ERC-20 TRANSFER FACE MOVED TO `VEth`. Vogue is no longer a token.
**The defect** (user: *"it still has transferFrom which makes it awkward that you dont know which shares
you are transferring"*): `Vogue.transferFrom` moved ETH-band shares while nothing in the signature said
WHICH, Vogue manages BOTH asset classes, and BTC band shares (`Vault.autoManagedBTC`) have no transfer face
at all. An ERC-20 face on a two-asset manager is ill-defined BY CONSTRUCTION.

**What moved / what stayed** — the split is the whole point:
| | where it lives now |
|---|---|
| `transfer` · `transferFrom` · `approve` · `allowance` storage · `Transfer`/`Approval` events | **`VEth`** — unambiguously the vETH token |
| band STATE (`autoManaged[].pooled`, `lpShares`), `_transferShares`, the settle-both-sides invariant | **Vogue** (unchanged) |
| `balanceOf` · `totalSupply` | **Vogue**, as plain ACCESSORS — 59 test sites read them and `VEth` re-exposes both. Without the mutators they are no longer an ERC-20 surface. |
⇒ `Vogue.transferSharesFor(from,to,amount)` is the ONE external door to `_transferShares`, gated
  `require(msg.sender == VETH)`. **"Which asset's shares?" is now UNASKABLE of Vogue**, not merely discouraged.
⇒ Vogue's own `emit Transfer` REMOVED — `VEth` is the token, so it emits, and an indexer sees exactly one
  event from the right address.

### Why the scope is smaller than the original entry proposed — MEASURED, not assumed
The entry said move all six members. Measured first:
| surface | test sites |
|---|---|
| `balanceOf` (read) | **59** |
| mutators (`transfer`/`transferFrom`/`approve`/`allowance`) | **0** (my earlier "1" was `WETH.approve` — the pattern matched `WETH` because it ends in `ETH`) |
⇒ Moving the mutators costs **nothing** and fixes the whole ambiguity; moving the reads would have churned
  59 sites for no safety gain, since `VEth` already re-exposes them.

### 🔴 THE GAP I FOUND AND CLOSED — the moved surface had ZERO coverage
No test transferred vETH at all (`VEthIdentity.t.sol` builds a `VEth` but never moves anything). Moving a
money-path surface with no test is how a bug ships. Added
`test_VEth_OwnsTheTransferFace_AndVogueGatesItToVEthAlone` — **PASSES** — asserting:
 1. a `VEth.transfer` moves **Vogue's** band shares (state stayed, face moved);
 2. `VEth` emits its OWN `Transfer` (⚠️ `expectEmit` matches on topic0 = keccak of the SIGNATURE, so a
    differently-named local event silently never matches — hit and fixed);
 3. `Vogue.transferSharesFor` reverts `403` for any caller but `VEth` — the authority half;
 4. allowance lives on the TOKEN and `transferFrom` decrements it.
⚠️ **Deploy wiring is NOT optional:** `DeployL1_s.sol` now calls `setVEth` right after constructing `VEth` —
  without the pin every vETH transfer reverts.

## ✅ §J.2c VERIFIED — suite **3569 passed / 1 failed** (the +10 vs 3559 is the new test's instances).
Only `testLeverage_LvrControlVsTreatment` fails, and that is the REAL §A.16 measurement, not a regression.

# ═══ §A.71 / §A.52 DEDUP PASS — MEASURED SCAN (started 2026-08-01) ═══
## Scan 1 — identical function signatures defined in >1 place: **165**
⚠️ **Most are NOT duplication and must not be "fixed":** `supply`/`borrow`/`repay`/`withdraw`/`debtOf`/
  `collateralOf`/`liqThresholdBps` appear 6× each across `AaveV3Venue` / `AaveV4Venue` /
  `MorphoEscrowVenue` — that is **POLYMORPHISM**: three implementations of one venue interface. Collapsing
  them would delete the abstraction. **A signature count is not a duplication count.**

## Scan 2 — §A.52 interface fragmentation: **the real, actionable finding**
| metric | value |
|---|---|
| total `interface` declarations in `src/` | **110** (the entry said 95 — remeasured) |
| interfaces declared under the SAME NAME in >1 file | **0** ✅ (the "one declaration" rule already HOLDS for names) |
| **functions declared across >2 DIFFERENT interfaces** | **16** ⇐ **the violation** |
| **6×** | `getTWAPforAsset` — `IAux`, `IAuxDep`, `IAuxSwap`, `IAuxTwap`, `ISwap` |
| **4×** | `get_deposits` — `IAux`, `IAuxLens`, `IAuxOps`, `IAuxSwap` |
| **4×** | `POOLED_ETH` / `POOLED_BTC` / `POOLED_USD_BTC` — `ICore`, `ICoreObs`, `IV4`, `IVogueCore` |
| **3×** | `subPendingSwapOut` — `IBtcVaultBridge`, `ICore`, `ICoreObs` |
⇒ 🎯 **The defect is NOT duplicate interface NAMES — it is ONE CONTRACT described by MANY NARROW
  INTERFACES.** `Aux` is viewed through ≥5 (`IAux`/`IAuxDep`/`IAuxSwap`/`IAuxTwap`/`ISwap`); `Core` through
  ≥4 (`ICore`/`ICoreObs`/`IV4`/`IVogueCore`). Each restates the same signatures, so a signature change must
  be made in 4-6 places and **any missed one still compiles** — the silent-drift failure mode.
⇒ **THIS is what "ONE DECLARATION PER INTERFACE, IN A SHARED FILE" (BUILD-QUEUE:44) actually asks for**, and
  it is measurably violated 16 times.

### ▶️ DEDUP PLAN (ordered by risk, lowest first)
 1. **Consolidate the `Aux` views** → one `IAux` in the shared `Interfaces.sol`; delete `IAuxDep`,
    `IAuxTwap`, and the `ISwap`/`IAuxSwap` overlap. ⚠️ Check each consumer still compiles — a narrow
    interface is sometimes chosen to keep a LIBRARY's bytecode small, so measure sizes after (SwapLib's
    margin is 353 bytes).
 2. **Consolidate the `Core` views** (`ICore`/`ICoreObs`/`IV4`/`IVogueCore`).
 3. **§J.8b `outOfRange` ×6** — the ETH/BTC fork (`outOfRange`/`outOfRangeBtc`) across Core, Vogue, Vault,
    Interfaces, BtcVaultLib, SwapLib.
 4. **Rust half** — use the graph (57,511 links) + `cargo check` dead-code warnings, which are authoritative
    where greps are not.
⚠️ **Apply the `_skewBasis` judgement throughout: extract what is genuinely SHARED, keep what genuinely
  DIVERGES.** The venue trio above is the counter-example — identical signatures, different semantics.

## ✅ §A.52 DEDUP — round 1: the underscore-suffixed LOCAL interfaces. **7 → 5.**
The `_L` / `_VG` / `_BView` suffixes are the visible symptom of the fragmentation: a file declaring its own
narrow view of a contract that a SHARED interface already describes.
| local | replaced with | why it was safe |
|---|---|---|
| `IAuxTWAP_BView` (`BtcLevManager.sol`) | **`IAuxTwap`** (`Interfaces.sol:114`) | IDENTICAL signature `getTWAPforAsset(address,uint32)`; the file already imported `Interfaces.sol`. 11 refs. |
| `IWETH_VG` (`VogueLib.sol`) — deposit + allowance + balanceOf + transferFrom + approve | **`IWETH9`** | see below |
| `IWethDeposit` (`SwapLib.sol`) — `deposit()` only | **`IWETH9`** | see below |
⇒ **THREE WETH views existed.** `IWETH9` (shared, `ILevVenue.sol`) had the deposit half; `IERC20Min` (same
  file) had the ERC-20 half. Making **`interface IWETH9 is IERC20Min`** collapses all three into ONE — no
  new interface invented, just the two existing halves joined.
⇒ **Sizes UNCHANGED** (SwapLib 24,223 / margin 353; VogueLib 20,678; 0 exceedances). Interfaces cost no
  runtime bytecode, so this consolidation is free — which answers the worry that a narrow interface might
  have been chosen to keep a library small. **It was not; measured, not assumed.**
⚠️ Gotcha hit: a single-line `interface X { ... }  ` with TRAILING WHITESPACE defeated a `\}\n` regex, so
  the declaration survived the rename and produced *"Identifier already declared"*. **Verify a removal
  happened; do not trust the edit reported success.**

### ▶️ REMAINING (5): `IWeEth_L`, `IRedeem_L`, `ILiq_L` (SwapLib, ether.fi-specific — check for a shared
  equivalent before inventing one) · `IVogue_VG`, `IVogueView_VG` (VogueLib — likely collapsible into the
  `Vogue` views already in `Interfaces.sol`).
### ▶️ THEN: the big ones — `Aux` seen through ≥5 interfaces, `Core` through ≥4 (16 functions restated).



---

# ═══ RUST SCAN — FINISHED 2026-08-01. CONCLUSION: THERE IS NO CROSS-CRATE DUPLICATION TO REMOVE ═══

The scan that began with graphify (17,624 nodes) and stalled on the `Strategy` false positive is now
complete, and the answer generalises that false positive rather than contradicting it.

**METHOD.** Enumerated every `fn` name defined in the non-vendored `quid-*` crates and counted how
many crates define each. Anything in 3+ crates is a dedup candidate on the graph's logic.

**RESULT — every single repeated name is a TRAIT OBLIGATION, not duplicated logic:**
`new` (14 crates), `fmt` (14), `default` (10), `serialize`/`deserialize` (6/5), `from` (6),
`try_from` (5), `from_str` (5), `as_str` (5), `arbitrary_with` (5), `from_rng` (6), `main` (5,
binaries). Deduping any of them is impossible by construction - `Display` requires `fmt`, `Serialize`
requires `serialize`, `Arbitrary` requires `arbitrary_with`.

**SO THE ORIGINAL FINDING WAS A MEASUREMENT ARTEFACT, TWICE OVER.** The graph counts symbol
CO-OCCURRENCE across crates and cannot distinguish "our duplicated helper" from "a method the
compiler forces every implementor to write". `Strategy` was the first instance found by hand; this
sweep shows it was the whole category. **A name-frequency graph over Rust will always surface the
trait vocabulary and essentially nothing else** - worth knowing before commissioning another one.

**ALSO ABANDONED, and why:** the `quid-common` prelude for bitcoin re-exports. Measured against real
imports it fully covered 13 files, but 10 of those had a SINGLE import line, so it saved 4 lines
total while 16 other files would have needed the prelude PLUS a `bitcoin` line. Reverted.

**WHAT THE SCAN DID PRODUCE, all landed:** `quid-cvm` went from 135 lines and ZERO tests to 19
mutation-verified tests; `quid-api-core`'s test binary was fixed (a module-vs-items import bug meant
**51 tests had never run once**); and the workspace's Linux-only build constraint was documented with
a working Docker recipe.

**STILL UNRUN:** a dead-code sweep over the whole workspace. It needs Linux (`quid-cvm` is
Linux-only and transitive, so `cargo check --workspace` bails on darwin before emitting warnings) and
therefore Docker Desktop running. Command is in [[quid-ln-needs-linux-to-build]].

## ✅ §A.52 — **ZERO underscore-suffixed interfaces.** 7 → 0. Sizes unchanged, bytecode-verified inert.
| local (deleted) | canonical home | what it was |
|---|---|---|
| `IAuxTWAP_BView` | **`IAuxTwap`** (existing) | identical `getTWAPforAsset` restatement (11 refs) |
| `IWETH_VG` · `IWethDeposit` | **`IWETH9 is IERC20Min`** | THREE WETH views → one; the two existing halves joined, nothing invented |
| `IWeEth_L` · `IWeETHRate` (Rover) | **`IWeETH`** (existing, complete) | two SUBSETS of a shared interface that already had every member |
| `IRedeem_L` | **`IEtherFiRedemption`** (new, canonical) | + carries the verified note that its param is the OUTPUT TOKEN, not a holder |
| `ILiq_L` | **`IEtherFiLiquidityPool`** (new, canonical) | |
| `IVogue_VG` · `IVogueView_VG` | **`IVogue`** (new, canonical) | ONE contract's surface was split across TWO declarations |
⇒ Followed the file's own precedent — *"Canonical IRover — union of the former per-file variants"* — so the
  new entries match a pattern already established here rather than introducing a convention.
⇒ **PROOF OF INERTNESS:** before/after `deployedBytecode` hashes are IDENTICAL for `SwapLib`
  (`2b9e1b56a6d8`), `VogueLib` (`a4fbf02537f8`) and `BtcLevManager` (`e2415859bf41`). Sizes unchanged
  (SwapLib 24,223 · VogueLib 20,678 · Rover 16,373), 0 exceedances. **Interfaces cost no runtime bytecode —
  measured, so the remaining consolidation is free too.**
📌 A suite run showed 9 fewer passes / 18 more skips with IDENTICAL test names and no new failures. The
  bytecode-hash check above settles it: **not attributable to this change** — it is fork/RPC-dependent
  conditional skipping. **Byte-identical output is a stronger proof than a matching test count.**

### ▶️ NEXT (unchanged plan): `Aux` views (≥5 interfaces) → `Core` views (≥4) → `outOfRange`×6 → Rust half.

## 💡 #12 SUB-ITEM REFINED BY THE USER (2026-08-02) — pay the v4 protocol fee AT WITHDRAWAL, not per-swap
> *"you have a TODO for the mocktoken inflation to bypass the fee? i was counting on this to allow compound
>  interest to work better… just to make uniswap happy we can still donate the fee from an LP withdrawal to
>  the same location that their coercive automatic deduction was trying to bill every fee. my theory is that
>  hampering compound interest shouldnt happen, would it genuinely lead to different results the way i
>  propose it? this must be tested later, after we finish all our other todos"*

### ⇒ ANSWER: **YES, it genuinely differs — and the difference is the whole point, not a rounding artifact.**
 • A fee skimmed **PER SWAP** shrinks the LP's principal at every swap, so the LP earns yield on a smaller
   base for the rest of the period. The loss is not the fee — it is **the fee PLUS all the yield that fee
   would have earned**, compounding for the remaining holding time.
 • A fee paid **ONCE AT WITHDRAWAL** leaves the full principal compounding and deducts the amount at the end.
 ⇒ The gap between the two is exactly *"yield on the fee amount over the holding period"* — **larger the
   longer the LP stays and the higher the yield.** For a long-duration LP this is a real, compounding number,
   which is precisely why the user says hampering compounding *"shouldn't happen"*. **Their theory is right.**

### 🔑 AND THERE IS A SHARPER ARGUMENT THAT MAKES IT HONEST, NOT A DODGE
Our pool's currencies are **MOCK tokens** (verified: `Core.sol:479-484` keys the PoolKey on `usdMock`/
`volMock`). ⇒ **A protocol fee skimmed from our pool is collected IN MOCKS, which are worthless outside the
system.** So the coercive per-swap deduction does not actually pay Uniswap anything of value — it only
damages our LPs' compounding.
⇒ **The user's proposal is therefore strictly BETTER FOR BOTH SIDES:** stop the worthless-mock skim from
  compounding against LPs, and **donate the equivalent in REAL value at withdrawal to the same destination
  the protocol fee would have gone to.** Uniswap ends up with something worth having; the LP keeps their
  compounding. **That is not "cheating the fee" — it is paying it in a currency that is actually worth
  something, at a time that does not compound against the payer.**

### ▶️ TO TEST (user: *"after we finish all our other todos"*) — the falsifiable version
 1. Simulate an LP over N periods with (a) per-swap skim vs (b) at-exit payment, same nominal fee. **Assert
    (b) − (a) equals the compounded yield on the fee** — if it does not, one of the two models is wrong.
 2. Confirm the destination: where does `ProtocolFees` credit accrue, and can we pay it directly? (Fee is
    per-pool + controller-set; `protocolFeesAccrued` is the sink — VERIFIED live, non-zero for ETH/USDC/USDT.)
 3. ⚠️ Only arm ANY of this if a controller actually sets a fee on OUR PoolKey. **Deploy-time assert 0 +
    monitor first** — do not build against a hypothetical (recorded earlier under #12).
📌 Kept under **#12 (POOLED_USD count-once)** because the compensation must not create backing from nothing —
  the same invariant that governs the mock-inflation half.

## ✅ §J.8b `outOfRange` — RESOLVED. Half was already done; the other half was a REAL find.
**Already done (by §A.56), discovered by reading before editing:** `VogueLib.sizeOutOfRange` ALREADY calls
`SwapLib.sizeOorUsd` — the same helper the BTC path uses — with its own comment recording *"both branches
were an INLINE COPY … Verified byte-identical … One definition now sizes every out-of-range order."*
Both paths also already shared 7 SwapLib helpers (`burnInRange`, `Oor`, `pendingFor`, `plainNet`,
`rebalanceCore`, `refreshBookmarks`, `validateOorParams`). **So the SIZING half was not a target.**

**The GEOMETRY half WAS duplicated — and is now fixed:**
| | before | after |
|---|---|---|
| BTC (`BtcVaultLib.outOfRangeBtc`) | `SwapLib.oorTicks(...)` | unchanged |
| ETH (`Vogue._outOfRange`) | inline block + local `_outOfRangeTicks` — **identical branch structure, identical alignment, same width 10** | `SwapLib.oorTicks(...)` |
⇒ **Two dead functions removed:** `Vogue._outOfRangeTicks` (replaced) and `Vogue._alignTick` (used ONLY by
  it ⇒ became unreachable ⇒ deleted per the no-unreachable-code rule).
⇒ ONE definition now computes out-of-range geometry for BOTH assets, matching what §A.56 did for sizing.

### ⚠️ THE TRAP THIS CHANGE CONTAINED — documented at the call site
`SwapLib.oorTicks` negates `distance` **INTERNALLY** from `token1is`; `Vogue` negated it **BEFORE** the call.
Keeping both would negate TWICE and place every ETH out-of-range order on the **WRONG SIDE OF SPOT** — a
silent money-path bug with no revert and no failing type. **The caller must NOT pre-negate**, and that is now
a comment where someone will meet it.
📌 A dedup that merges two call sequences must reconcile what each one did BEFORE and AFTER the shared part,
  not just confirm the shared part matches. **This is the second time today a "same skeleton" merge hid an
  inverted-sign hazard** (the other: `retainSkewPremium`'s caller-dependent units).
**Verification:** builds clean · 0 size exceedances · suite shows ONE distinct failure, the known §A.16 one.

### ▶️ DEDUP PLAN — remaining: the RUST half (graph + `cargo` dead-code warnings) + the hand-rolling audit.

## ✅ RUST DEDUP HALF — **COMPLETE. The workspace is clean.**
The parallel session's scan (`ef2bbdb`) already established **no cross-cratedup duplication exists**: every fn
name appearing in ≥3 crates is a TRAIT OBLIGATION (`new` in 14 crates, `fmt` in 14, `default` in 10,
`serialize`/`deserialize`, `from`, `try_from`, `from_str`, `as_str`, `arbitrary_with`, `from_rng`, `main`).
Deduping any is impossible by construction — `Display` REQUIRES `fmt`, `Arbitrary` REQUIRES `arbitrary_with`.
⇒ 📌 **The original graphify "duplication" signal was a MEASUREMENT ARTEFACT across the whole category**: a
  name-frequency graph over Rust surfaces the trait vocabulary and essentially nothing else. Worth knowing
  before commissioning another.

### The ONE item it left unrun — now done
*"Still unrun is a dead-code sweep, which needs Docker running since `cargo check --workspace` bails on
darwin at quid-cvm."* **Ran it.** `docker run … rust:1.90 cargo check --workspace` → **exit 0**.
| finding | verdict |
|---|---|
| `create_sweep_tx` never used (`wallet.rs:1251`) | ✅ **KNOWN + DELIBERATE** — `QUEUE.md:2251`: needs an operator auth, not an endpoint; *"stays unwired ON PURPOSE"* pending `SweepAuth`. The warning is its MARKER, not a defect. |
| `dcap-ql` patch warning | vendored SGX dependency, not our code |
⇒ **ZERO new dead code in the entire Rust workspace.** The Rust half of §A.71 is closed.
⚠️ `--all-targets` CANNOT run in the container: `bitcoind`/`electrsd` dev-deps DOWNLOAD binaries in their
  build scripts and the container has no DNS (*"failed to lookup address information"*). Lib-only check is
  the right scope anyway — dead code in test-only targets is not shipped. **Recorded so the next attempt
  does not re-hit it.**

## 📊 §A.71 DEDUP PASS — STATUS
| target | outcome |
|---|---|
| underscore-suffixed interfaces | ✅ **7 → 0** |
| `Aux` views | ✅ **6 → 1** (49-member union) |
| `Core` views | ✅ **4 → 1** (29-member union) |
| `outOfRange` | ✅ geometry deduped; 2 dead Vogue helpers deleted (sizing was already done by §A.56) |
| Rust duplication | ✅ none exists (trait obligations only) |
| Rust dead code | ✅ none new (one known-deliberate marker) |
| **remaining** | the HAND-ROLLING audit (library-vs-local), and the `_V`/`_M`/`2`-suffixed interface pairs the surfacer found (`IEthVenue`/`IEthVenueV`, `IAaveSpoke`/`IAaveV4Spoke`, `ILevSyncHook`/`ILevSyncHookM`, `IBasketTurn`/`IBasketTurn2`) |

## ✅ §A.52 ROUND 3 — the suffixed pairs. Fragmentation **59 fns/41 groups → 30/29** (halved).
| variant (deleted) | canonical | members | note |
|---|---|---|---|
| `AaveV4Venue::IAaveSpoke` | **`IAaveV4Spoke`** | 11 | see the mutability finding below |
| `Vogue::IEthVenueV` | **`IEthVenue`** | 23 | |
| `LevMath::ILevSyncHookM` | **`ILevSyncHook`** | 5 | |
| `SwapLib::IBasketTurn2` | **`IBasketTurn`** | 3 | `IBasketTurn2` was a strict SUBSET |

### 🔴 A REAL DEFECT THE MERGE EXPOSED — the two Aave-v4 declarations DISAGREED ON MUTABILITY
| declaration | `getReserveId` |
|---|---|
| `AaveV4Venue::IAaveSpoke` | `external **returns**` — NON-view |
| `Interfaces::IAaveV4Spoke` | `external **view** returns` |
⇒ **`view` is CORRECT**, proven by usage rather than assumption: FOUR live call sites (`Aux.sol:313/319`,
  `Vault.sol:311`, `ChannelLib.sol:415`) already STATICCALL it in production. A `view` declaration over a
  state-changing function would revert at runtime — it does not, so the function is genuinely a view.
⇒ **This is exactly the silent drift the one-declaration rule exists to prevent:** two views of one contract
  disagreeing about mutability, both compiling, neither failing. **Merging them forced the question.**

### ⚠️ AAVE v3 DELIBERATELY NOT TOUCHED (user: *"be careful with aavev4 and aavev3 (which is only for wbtc)"*)
Checked before merging: `AaveV3Venue` uses **entirely separate** interfaces — `IAaveV3Pool` +
`IAaveV3DataProvider`, its own ABI, WBTC-only. **A different protocol, not a variant.** Despite the name,
`IAaveSpoke` lives INSIDE `AaveV4Venue.sol` and uses v4's `reserveId`/`onBehalfOf` shape — so the merge was
v4↔v4, never v4↔v3. **The user's caution was warranted and is recorded at the interface.**

### ▶️ REMAINING FRAGMENTATION (30 fns) — mostly LEGITIMATE vocabulary, one real target
 • `IERC20Min`/`ILevERC20`/`IEVault`/`IVogueShares` sharing `balanceOf` — **ERC-20 vocabulary**, the
   Solidity analogue of the Rust trait obligations. **NOT a dedup target.**
 • ⚠️ **`IAux(107)` vs `IAuxM(21)` vs `IAuxFee(5)` vs `ISwapAux(2)`** — MORE Aux variants that were not in
   the original six. **Real targets for a round 4.**

## 🔧 RPC ROTATION — SOLVED (this was an open investigation item; the outage forced it)
`rpc.ankr.com` began **refusing connections** (*"Connection reset by peer (os error 54)"*), and the failure
mode is nastier than an outage: **forge does not stop — it SHRINKS THE TEST SET.** One run reported
*"1 failing, 3448 succeeded"*, which LOOKS BETTER than the usual 1 failure, but
`testLeverage_LvrControlVsTreatment` **NEVER RAN** and ~112 tests were silently absent. **Reading only the
summary line would have produced two false claims at once: that the round verified clean, AND that the
§A.16 failure had disappeared.**
📌 **NEW STANDING CHECK: every suite result must be read with its DENOMINATOR, not just its failure count.**
  Assert a known-state canary actually RAN (`grep -c testLeverage_LvrControlVsTreatment`) before trusting
  any number. A shrinking test set is invisible in the pass/fail line.
📌 This also retro-explains the earlier unattributed *"9 fewer passes / 18 more skips"* — same provider
  flakiness. **The bytecode-hash comparison was the right call there: byte-identical output proved inertness
  when the test counts could not.**

### ✅ THE WORKAROUND (verified working)
```
FOUNDRY_RPC_ENDPOINTS_MAINNET=https://ethereum-rpc.publicnode.com FORK_BLOCK=<recent> forge test
```
 • `FOUNDRY_RPC_ENDPOINTS_MAINNET` **overrides the hardcoded `foundry.toml` alias with NO file edit** — so
   there is nothing to revert and a crash cannot leave the repo mis-pointed.
 • ⚠️ **The old pin CANNOT be reused.** Public nodes are NOT archive: `25653624` is ~9,500 blocks back and
   is refused. Probed: `ethereum-rpc.publicnode.com` ✅ and `rpc.flashbots.net` ✅ (head 25663176);
   `eth.llamarpc.com` and `cloudflare-eth.com` unreachable. **Pin to a RECENT block instead** (25663100).
 • Cost: noticeably slower (~117s for a single fork test vs seconds on the paid endpoint).
⇒ Determinism is preserved WITHIN a run by pinning; it just cannot be the SAME historical block. Any test
  asserting fork-state at 25653624 must be re-pinned or made state-independent (the rung-3 fix already is —
  it mocks TVL rather than depending on the live watermark).

## 🔬 §A.16 MECHANISM IDENTIFIED — it is **LVR on levered-entry flow**, measured NET of fees.
### What the "treatment" actually does — NOT what the name says
`_open()` (`LeveragePnLProbe.t.sol:56`) is **not a leverage open**. It is a SWAP:
```solidity
deal(bold, trader, boldAmt);
AUX.swap(bold, address(WETH), true, boldAmt, 0);      // BOLD -> WETH, by `trader`
```
⇒ The treatment is **20 rounds of buying WETH out of the band** — the market-impact half of a levered
  entry (a levered LP borrows stables and buys ETH). The control does none.
⇒ So the measured gap is **LVR / impermanent loss**: the band sold WETH into a rising price, and both arms
  are then valued at the ORIGINAL `px0`. **That is an inherent AMM effect, not a coding error** — which is
  why the previous "is it a bug?" framing never resolved.

### 🔑 THE DECISIVE CHECK — is the shortfall NET OF FEES? **YES.**
If the redeem did not pay the LP's accrued fees, the 8% would be a measurement artifact. It does:
`Vogue._withdraw` (`:502`) calls **`_settlePending(LP, msg.sender, address(0))` at `:530`** — fees settle
into the exit proceeds, and `_lpValueUsd` measures the proceeds.
⇒ **So the 8% is what remains AFTER the LP was paid every fee those 20 swaps generated** — and after the
  skew premium, since a BOLD→WETH buy is the drain leg that `wellSkew` prices (confirmed during C4).
⇒ ⇒ **Restated precisely: the swap fee + the scarcity skew together did NOT cover the LVR that
  inventory-depleting flow imposed on the passive LP, by ~8.06% over 20 rounds of 3,000 BOLD.**

### ⚖️ THIS IS NOW A DESIGN QUESTION, NOT A BUG HUNT — and it is the user's call
 (a) **The assertion encodes a goal the system does not currently meet.** The skew mechanism
     (`sellSkew`/`wellSkew` → `recordSkewPremium`) exists PRECISELY to charge inventory-depleting flow. If
     it is not covering LVR, the skew is priced too low for this flow size. ⇒ §A.16 stands as a real gap,
     and the fix is a PARAMETER/pricing question, not a correctness one.
 (b) **Or the scenario is adversarial** — 20 consecutive ONE-DIRECTIONAL 3,000-BOLD buys with no return
     flow is close to a worst case, and no AMM is LVR-neutral against it. ⇒ then the ASSERTION is too
     strong and should be re-scoped (e.g. bounded LVR rather than zero).
⚠️ **Do NOT weaken the assertion to make the suite green.** It is currently the only failing test and it is
  measuring something real; silencing it would delete the one signal that this cost exists.
▶️ **NEXT (cheap, decisive):** log `CORE.skewPremiumETH()` before/after the 20 rounds and compare it to the
  59,967 USD18 gap. If the premium collected is ≪ the gap, (a) is confirmed and the skew is underpriced —
  a number, not an opinion. **That single measurement decides between (a) and (b).**

## ❌ DEDUP NON-TARGET (asked + answered) — `SorExchange` is NOT a duplicate of `AUX.swap`
User asked whether the 20-round swap loop implies `AUX.swap` duplicates the zap/`SorExchange` machinery.
**It does not, and the reason was ALREADY documented** (`LevVenueBase.sol:18-21`):
> *"`SorExchange` is NOT unified in: it's the adapter for a SEPARATE, live product — the optional
>  Liquity-V2 ~10x directional long (BOLD into the Stability Pool, or WETH into the venues), still wired in
>  the UI. Different protocol + BOLD/WETH collateral, so it can't be a weETH `ILevVenue` — a distinct
>  product, NOT a deprecated path."*
| question | answer |
|---|---|
| why 20 rounds? | **TEST-ONLY.** `_open` is called nowhere but `LeveragePnLProbe`; the loop accumulates flow until LVR is measurable. |
| same as `AUX.swap`? | **No — it WRAPS it.** `SorExchange.sol:43`: `ISwap public immutable AUX; // Aux implements ISwap`. It re-exposes our swap in **Liquity's** `IExchange` shape for their zapper's flash-loan callback. |
| who uses it? | Liquity V2's leverage zapper, via `LiquityTroveVenue`. |
| can it be simplified/removed? | **No.** Different protocol + BOLD/WETH collateral ⇒ structurally cannot be a weETH `ILevVenue`. |
| needed by a venue? | **Yes — exactly one:** `LiquityTroveVenue`. |
⇒ 📌 **This is the shape a dedup pass must NOT collapse:** two things that both "do a swap" but sit on
  opposite sides of a PROTOCOL BOUNDARY. Same category as the venue trio (`AaveV3`/`AaveV4`/`MorphoEscrow`
  implementing one interface) and the Rust trait obligations. **Recorded as a NON-TARGET so a later pass
  does not re-raise it.**
⇒ 📌 And again the answer pre-existed in a comment — **grep the code for the question before analysing it.**

## 🎯🎯 §A.16 — THE 8% IS A **MEASUREMENT ARTIFACT**. The value changed FORM, it did not vanish.
Instrumented the probe. Three numbers settle it:
| quantity | value |
|---|---|
| measured gap (control − treatment, ETH-flat) | **59,967 USD** |
| **BOLD deposited in the Liquity Stability Pool** | **60,000.9** |
| `skewPremiumETH` collected over the 20 rounds | **0** |
⇒ The gap is **within 0.06% of the total swapped volume** (20 × 3,000 = 60,000 BOLD) — and equals the BOLD
  now sitting in the SP. **LVR does not equal the notional; a bookkeeping omission does.**
⇒ `_lpValueUsd` measures ONLY `ETH + WETH + QUID` received on redeem (`LeveragePnLProbe.t.sol:77-86`).
  **It cannot see BOLD.** The band sold WETH, the basket took the BOLD, the BOLD went to the SP — and the
  probe counts the WETH leaving but not the value arriving.
⇒ 📌 **Reproduced across TWO different fork blocks** (25653624 and 25663100) at the SAME 59,967 — a real
  loss would vary with fork state; an accounting identity does not. **That invariance is the tell.**

### 🔴 THIS RETRACTS MY OWN "LVR" CONCLUSION FROM ONE STEP EARLIER
I wrote that the shortfall was *"LVR net of fees… the fee + skew did not cover it."* **Wrong.**
 • `skewPremiumETH == 0` ⇒ the skew charged NOTHING, so "the skew failed to cover LVR" was never the story.
   (The skew prices SCARCITY; 20 buys never made ETH scarce. It is working as designed, not underpriced.)
 • And the gap ≈ the notional, which LVR never is.
**I reasoned from a plausible mechanism instead of measuring the flow.** The measurement took one run.

### ⚖️ SO: is the CROSS-SUBSIDY PROBE right after all? **Very likely YES** — §A.16 is probably CLOSED.
`LeverageCrossSubsidyProbe` (passing) asserts the passive LP is not expensed. `LeveragePnLProbe` (failing)
disagreed — and its disagreement is now explained by what it fails to count. **Two probes of one claim, and
the passing one is the better-instrumented.**
### ⚠️ ONE QUESTION REMAINS BEFORE CLOSING — do NOT close on this evidence alone
`LP QUID balance == 0` after the redeem: the LP received **WETH only**, not the USD side of their position.
So the value is demonstrably IN the system (SP BOLD, and `AUX TVL = 1,212,001`), but this run does not show
the LP **RECOVERING** it. Two readings:
 (a) the redeem was PARTIAL (400e18 shares) and the USD leg settles on a full exit ⇒ pure probe artifact;
 (b) the band's USD claim is not delivered on redeem ⇒ a REAL delivery gap, and the probe found it by luck.
▶️ **NEXT:** redeem the FULL position and re-measure. If the LP then recovers ~60,000 in stables/QUID,
  (a) holds and §A.16 closes with the probe fixed to value all assets. **Fix the MEASUREMENT, not the
  assertion** — the assertion was right to fire.

## 🔍 §A.16 — DELIVERY IS FINE. The LP's **CLAIM** shrank by the swapped volume. This is #12 territory.
Measured owed-vs-received on the full exit:
| quantity | value |
|---|---|
| `redeem` OWED (assets) | **367.482 e18** |
| actually received (ETH+WETH) | **367.370 e18** — **99.97% delivered** |
| received QUID | 0 |
⇒ ✅ **Reading (b) is REFUTED — there is NO delivery gap.** The exit ladder pays essentially everything it
  says it owes. (The "47.67 WETH" I cited from the trace was ONE transfer among several in the ladder —
  another reason not to read a single trace line as a total.)
⇒ 🎯 **But the OWED figure itself is the finding:** the LP deposited **400 ETH** and is owed **367.48** —
  short by **~32.5 ETH ≈ $60,500**, which is the **60,000 BOLD** the 20 swaps put into the basket.
  **The CLAIM shrank, not the payment.**

### ⇒ THE REAL QUESTION (and it is a #12 POOLED_USD question, not an §A.16 one)
`AUX.swap(BOLD → WETH)` takes WETH **out of the band** and puts BOLD **into the basket**. The band's LPs
are the ones who supplied that WETH. So either:
 (a) the band SHOULD be credited a USD claim for the inventory it sold (`POOLED_USD_ETH` ↑), and the LP's
     redeemable value should be ~400 ETH-equivalent ⇒ **the credit is missing or not reaching `vogueETH()`**;
 (b) band LPs and QUID holders share ONE balance sheet BY DESIGN, and selling band inventory to the basket
     legitimately transfers value from LPs to QUID backing ⇒ **working as intended, and both probes plus the
     assertion need re-scoping to say so.**
⚠️ **I cannot settle (a) vs (b) from the measurement alone — it is a design intent question.** What IS
  established: the value is intact system-wide (`AUX TVL = 1,212,001`; SP BOLD = 60,000.9), delivery works,
  and the transfer is exactly the swapped notional.
▶️ **NEXT:** check whether `POOLED_USD_ETH` rises by ~60,000 across the 20 swaps. **If it rises and
  `vogueETH()` does not reflect it, that is a concrete accounting bug (#12's count-once invariant). If it
  does not rise at all, the design is (b) and the probes must be re-scoped.** One measurement, decisive.
📌 Reclassifying: this is **#12 (POOLED_USD count-once / no-double-spend)**, not §A.16 (levered-LP
  cross-subsidy). The probe's NAME sent me down the leverage path for two rounds; the flow is a plain swap.

# 📋 #12 — THE SPEC WAS NEVER WRITTEN. Writing it, because that is what blocked the investigation.
**User: *"is the context for the task not clear in the .md doc?"* — CORRECT, it is not.** All that exists:
 • `BUILD-QUEUE:434` — an ECHIDNA INVARIANT row referencing *"after **the #12 unify**"*, never describing it.
 • `QUEUE:102` — *"#12 (both senses)"* listed as open, **the two senses never named anywhere**.
 • `BUILD-QUEUE:21` — a **DIFFERENT** `#12 drop-voting`, marked DONE. **Two unrelated items share "#12".**
⇒ I spent three rounds trying to decide (a) vs (b) **against a specification that does not exist.** That is
  the actual blocker, not the measurement. **Same numbering collision as §J.8a/§J.8b, and the same cost.**

## THE MEASURED FACTS (all confirmed, fork block 25663100)
| fact | value |
|---|---|
| LP deposits | **400 ETH** |
| `redeem` says OWED | **367.482** |
| actually received (ETH+WETH) | **367.370** — 99.97% of owed |
| received QUID | **0** |
| received STABLES (delta-measured) | **0 — none, of any of the 12** |
| BOLD in the Stability Pool | **60,000.9** |
| `skewPremiumETH` | **0** |
⇒ **There is NO third asset.** The LP's CLAIM shrank from 400 → 367.48; the missing ~32.5 ETH ≈ $60,500
  IS the 60,000 BOLD, now basket-owned. **Value moved from band LPs to QUID backing, and the LP was not
  credited for it.**

### ⇒ ON (a) vs (b) — the user's *"it's probably both?"* is the right reading
They are not competing explanations; they answer **different questions**:
 • **(b) describes what HAPPENS** — band and basket share one balance sheet, so selling band inventory to
   the basket transfers value to QUID backing. **Measured, true.**
 • **(a) describes what arguably SHOULD happen** — the band gave up real inventory and should hold a USD
   claim for it, so an LP's total value survives the composition change. **Not measured, because no such
   credit reaches `vogueETH()`.**
⇒ **The gap between them IS #12.** "Count once" cannot be evaluated without stating which pool owns the
  proceeds of a band→basket sale. **That is the sentence the doc is missing.**

### ▶️ THE SPEC #12 NEEDS (write this first; it is one decision, then everything else follows)
> **When `AUX.swap` sources the volatile leg from the BAND, who owns the stable proceeds?**
> 1. **Basket owns them, band LPs bear it** (current behaviour) ⇒ document it, and re-scope BOTH probes +
>    `LeveragePnLProbe`'s assertion, which currently asserts the opposite.
> 2. **Band is credited a USD claim** (`POOLED_USD_ETH` ↑ and `vogueETH()` reflects it) ⇒ current behaviour
>    is a **count-once BUG**: the basket counts the BOLD and the band counts nothing, so one side of a real
>    asset transfer is unrecorded.
⚠️ Until that sentence exists, `testLeverage_LvrControlVsTreatment` cannot be correctly fixed — **any change
  either encodes an undecided policy or silences a real signal.** Leave it FAILING; it is the marker.

### ❓ THE 0.112 ETH (0.03%) OWED-vs-RECEIVED GAP — user asked; measured, not guessed
`367.482 − 367.370 = 0.1118 ETH ≈ $208` on a 367-ETH exit. Small and NOT the same phenomenon as the 32.5 ETH
above. Most likely the exit ladder's own cost (the ether.fi instant rung charges ~0.3%, which on a ~37-ETH
slice is ~0.11 ETH — the magnitude fits). **NOT yet confirmed** — to settle it, log which rungs the ladder
used and their fees. Filed as a minor open question, distinct from #12.

## 🔑 #12 — THE ACTUAL SPEC, SUPPLIED BY THE USER (2026-08-02). My (a)/(b) framing was the wrong question.
> *"who owns it? they both do. it's just that now there is one pooled_usd variable, so the only way that
>  reducing how much btc is poolable wont affect how much eth is poolable is if the refill works instantly,
>  but how can it if there is nowhere to buy btc except our own band (and we can't use wbtc to fill the gap,
>  wbtc is only used in opt in SOR or in opt in levered lp for btc)."*

### ⇒ VERIFIED IN CODE — the coupling is real, and it is enforced on the DRAIN side
| fact | where |
|---|---|
| `POOLED_USD_ETH` and `POOLED_USD_BTC` are still SEPARATE variables | `Core.sol:91/93` |
| the old hard sum-cap is **GONE** — `POOLED_USD_ETH + POOLED_USD_BTC` appears ONLY in a comment, no code | `Core.sol:48` (comment only) — matches #12's *"sum-cap dropped"* |
| but they DO compete, via ONE gate: `committedUsd18() = ETH band equity + BTC band equity` | `Core.sol:106` |
| enforced: **`if (committedSum > totalLiquid) revert OverCommitted();`** | `Aux._checkBacking:1085` |
| STRICT on DRAIN paths — **redemption, arb, and LP WITHDRAW**; ADD paths use non-reverting `tryCheckBacking` | `Aux.sol:1078-1084` |
⇒ 🎯 **So BTC-side commitment consumes the SAME backing budget an ETH LP needs to WITHDRAW against.** The
  per-band floor (*"ETH debt never eats BTC equity"*, `Core.sol:105`) decouples the **debt** side only —
  **it does NOT decouple the POOLED_USD side, which is what the user is pointing at.**

### ⚠️ AND THE ASYMMETRY THAT MAKES IT BITE — the user's real point
Decoupling would be harmless IF a band could refill instantly. **The BTC band cannot:**
 • There is **nowhere to buy BTC** except our own band — no external venue fills it.
 • **WBTC cannot substitute**: it is used ONLY in opt-in SOR and the opt-in levered BTC LP, deliberately
   (`BtcLevManager`), so it is not a refill source for band inventory.
 • Refill is therefore **LP-arrival-paced** (`Vault.registerBtcLp`) or swap-in-paced — NOT market-paced.
⇒ ⇒ **BTC commitments are STICKY while ETH's are not.** A BTC-side draw reduces ETH's usable headroom for
  as long as the BTC band stays un-refilled, and the ETH LP feels it as a *reverting withdraw*, not as a
  price. **That is the #12 problem, stated properly.**

### ⇒ WHY MY EARLIER FRAMING WAS WRONG
I asked *"who OWNS the stable proceeds?"* — the user: **"they both do."** Ownership was never the question;
the question is **whether one band's commitment can strand the other's exits, given that one of them cannot
refill on demand.** ⇒ The measured 400→367.48 claim shrink is that same shared-budget mechanic seen from the
ETH LP's side, **not** a missing credit and **not** LVR. Both of my previous readings are superseded.

### ▶️ WHAT THIS MAKES ACTIONABLE (concrete, no longer blocked on a missing spec)
 1. **Quantify the crowding:** at what BTC commitment does `committedSum > totalLiquid` start reverting ETH
    LP withdraws? That number is the real risk parameter, and nobody has measured it.
 2. **Asymmetric headroom reserve:** since only BTC is refill-constrained, consider reserving ETH-side
    withdrawal headroom rather than treating the budget as fungible — the constraint is not symmetric, so a
    symmetric gate misprices it.
 3. `Core.sol:48`'s comment describes the OLD hard cap; **restate it as the `committedUsd18 ≤ totalLiquid`
    gate** so the next reader does not look for an enforcement that no longer exists.

# ⚖️ #12 UNIFY vs STATUS QUO — the comparison the user asked for. **VERDICT: the refill DOES NOT EXIST YET.**
User: *"a substantial increase to capital efficiency… if the refill fires as expected this wont be a denial
of service to one side of the pool… we have to compare what we have now to this and consider the likelihood
of the refill not firing as we expect."*

## 🔴 THE DECISIVE FACT — P(refill fires today) = **ZERO**, because it is UNBUILT
`BUILD-QUEUE:402`: **"#100 — the ACTIVE WBTC flash-serve. UNBUILT either way; only the TRIGGER is
undecided… STATUS: UNBUILT — there is no flash-serve function."**
 • **0 matches** for `function *refill` in `src/` (Solidity).
 • **0 matches** for flash-serve / JIT-refill in the entire Rust fleet.
 • What IS built and must not be mistaken for it: the **LP-entry pump** (`Vault.registerBtcLp`) and
   **premium retention** (`retainSkewPremium`). Neither is a refill — one is exogenous LP arrival, the
   other is accounting.
⇒ **Today the BTC band refills ONLY when an LP chooses to arrive.** That is not a mechanism, it is a hope.

## THE COMPARISON
| | **NOW (split vars, shared backing gate)** | **PROPOSED (unified pooled_usd)** |
|---|---|---|
| capital efficiency | LOWER — each band's commitment eats shared headroom, so slack must be carried | **HIGHER** — the user's goal, and it is a real gain |
| DoS between sides | **bounded** — commitments are independently sized; crowding degrades gradually | **unbounded without refill** — one side can consume the whole budget |
| what an ETH LP feels when it bites | a reverting `withdraw` (`OverCommitted`) | the same, but reachable from a single BTC draw |
| dependency for CORRECTNESS | none | **the refill, critically** |
⇒ ✅ **The proposal's LOGIC is sound** — and note the refill genuinely FIXES the crowding, not just masks
  it: flash WBTC → `creditSwapIn` → SOR → repay puts BTC **into** the band and takes USD **out**, which
  LOWERS `POOLED_USD_BTC` and hands the freed headroom straight to the ETH side. **The mechanism is
  correctly aimed.**
⇒ 🔴 **But shipping the unify BEFORE #100 converts a BOUNDED inefficiency into an UNBOUNDED liveness risk,
  with a 100% refill-failure rate on day one.** That is the wrong order, not the wrong idea.

## LIKELIHOOD OF THE REFILL NOT FIRING — even AFTER it is built (ranked)
 1. 🔴 **UNBUILT** — today, certain. Everything below only matters once #100 lands.
 2. 🟠 **Fleet liveness.** The described op is a *"self-funding FLEET op"*. **This is the same fleet whose
    possible disappearance motivated the #114 dead-man exit.** A refill that depends on fleet uptime
    inherits every fleet-outage mode — and the ETH LP's withdraw reverts exactly when the fleet is down.
 3. 🟠 **External flash liquidity.** Needs Morpho WBTC flash depth at the moment of need — an outside
    dependency, correlated with the stress that caused the drawdown.
 4. 🟡 **Trigger choice — and this one is a DESIGN LEVER, not a risk to accept.** `#100` leaves it open:
    **(A) PROACTIVE permissionless** (anyone may call a depletion-check entrypoint) vs **(B) REACTIVE JIT**
    (fires inside a swap-out). ⭐ **(A) is strictly safer HERE**: it does NOT depend on fleet liveness, so it
    removes risk #2 — which is otherwise the dominant one. **Given #114 exists precisely because the fleet
    may vanish, betting ETH-LP withdrawals on fleet uptime is the contradiction to avoid.**

## ▶️ RECOMMENDED ORDER (keeps the capital-efficiency gain, removes the day-one DoS)
 1. **Build #100 with trigger (A)** — permissionless, so no fleet dependency.
 2. **MEASURE it**: refill latency under stress, and the failure rate when flash liquidity is thin. Until
    those two numbers exist, *"if the refill fires as expected"* is an assumption, not a premise.
 3. **THEN unify** `POOLED_USD`, sized so the worst measured refill latency still cannot strand an ETH exit.
 4. Interim, cheap, and useful either way: **quantify TODAY's crowding** — at what BTC commitment does
    `committedSum > totalLiquid` start reverting ETH withdraws? That number is the baseline the unify must
    beat, and it is measurable right now.

# 🚨 #100's PREMISE IS BROKEN — WBTC CANNOT REFILL THE BAND. (user, 2026-08-02) VERIFIED IN CODE.
> *"i dont believe we can use WBTC to refill the band because the band represents distinctly lightning
>  deposits"*

## ⇒ CONFIRMED. The band's BTC is LIGHTNING-CUSTODIED, and the credit path is gated on an LN attestation
`BTCChannels.settleSwapIn` (`:1094-1107`) requires ALL of:
 1. `openChannelsOf[msg.sender] != 0` — the caller must own an **OPEN LIGHTNING CHANNEL**;
 2. `_requireAttested(msg.sender)` — and be an **ATTESTED HOP**;
 3. a **`paymentHash`** — the **LN HTLC hashlock**, deduped (`swapInUsed`) one credit per swap-in, ever.
⇒ **`creditSwapIn` is Lightning-bound BY CONSTRUCTION.** A flash-borrowed WBTC position has **no LN payment
  hash and no channel**, so it cannot drive the credit. **WBTC cannot become band inventory.**
⇒ 🔴 **Therefore #100 as written — *"flash WBTC → `creditSwapIn` → repay"* — CANNOT WORK.** The two halves
  are incompatible: the flash leg is an EVM-atomic WBTC operation; the credit leg demands a settled
  Lightning payment. **This is not a build gap, it is a design error in the recorded plan.**
⚠️ And it cannot be patched by "flash WBTC, buy real BTC, route it over LN, then attest": **Lightning
  settlement is not EVM-atomic**, so it cannot complete inside the flash-loan callback. **The word "flash"
  is doing work the rail cannot support.**

## ⇒ WHAT THIS MEANS FOR THE UNIFY PROPOSAL — the constraint is STRUCTURAL, not a missing feature
The band's BTC can only arrive by an actual Lightning payment:
| path | exists? | paced by |
|---|---|---|
| `Vault.registerBtcLp` (LP stakes BTC) | ✅ built | **LP arrival** — exogenous |
| genuine swap-in (a user sells BTC over LN) | ✅ built | **user flow** — exogenous |
| fleet acquires BTC and routes it over LN | possible, unbuilt | **inventory + LN routing time** — NOT atomic |
⇒ ⇒ **NO refill path for the BTC band can be instant, because every one of them terminates in a Lightning
  settlement.** The earlier framing — *"the only way this isn't a DoS is if the refill works instantly"* —
  is exactly right, and **"instantly" is unreachable for Lightning-custodied inventory.**
⇒ 🔴 **So the unify's safety premise cannot be satisfied by ANY buildable refill**, not merely by an unbuilt
  one. That is a much stronger objection than my previous "wrong order" verdict, and it **supersedes it**.

## ▶️ WHERE THAT LEAVES THE CAPITAL-EFFICIENCY GOAL (the goal is still good — the route must change)
 1. **Bound the exposure instead of removing it:** keep the split, but reserve ETH-side EXIT headroom so a
    BTC commitment can never revert an ETH withdraw. Capital efficiency rises everywhere EXCEPT the
    reserved slice — a smaller gain than the full unify, with no liveness cliff.
 2. **Make BTC-side commitment self-limiting:** cap `POOLED_USD_BTC` growth by the band's *observed* refill
    RATE (LP arrivals + swap-ins over a window), so the system can only commit as fast as it can be resupplied.
    ⭐ This is the honest version of *"if the refill fires as expected"* — it makes the assumption MEASURED
    rather than assumed, and it degrades gracefully when flow dries up.
 3. **Re-scope #100** to what the rail actually permits: NOT a flash-serve, but a fleet BTC-inventory
    operation (hold BTC, route over LN on depletion). Its latency is minutes-to-hours, not one block —
    **size any unify against THAT number, not against zero.**
📌 This is the second time today a recorded plan was incompatible with the rail it targets (the first:
  #114's "supersede" assuming EVM semantics for a Bitcoin tx). **Both were found by asking what the RAIL
  permits, not what the code says.**

## ⇒ HOW IT WORKS FOR **ETH** (user asked) — the asymmetry is EXPLICIT IN THE CODE, one line apart
`Core._settleTokSide` (`:1038-1047`) handles the volatile side of every band swap, for BOTH assets:
```solidity
_mockTok(isBTC).burn(tokAmount);
if (inRange) _subPooledTok(isBTC, tokAmount);
// ETH-only: the burned mockETH is matched by real ETH paid out.
if (!isBTC && who != address(0)) VOGUE.takeETH(tokAmount, who);   // <-- NO BTC EQUIVALENT
```
⇒ 🎯 **The mock token is the SAME for both assets; only ETH has an ATOMIC path to the real thing.**
  `takeETH` → `_sendETH` → the **4-rung offramp ladder** (`SwapLib.offrampBody:566`), which sources real
  ETH from the yield venues IN THE SAME TRANSACTION. **BTC has no `takeBTC` — and cannot, because its real
  asset sits in Lightning channels.**

### The two rails, side by side
| | **ETH** | **BTC** |
|---|---|---|
| real asset custody | ERC-20 / native, held across venues (Galaxy, Aave, ether.fi, Rover) | **Lightning channels** (`BTCChannels`) |
| sourcing on a swap | **`takeETH` — ATOMIC, same tx**, via the 4-rung ladder | **none** — no atomic path exists |
| refill pacing | **market-paced** — anyone can buy ETH and deposit | **LN-arrival-paced** — `registerBtcLp` or a genuine swap-in |
| worst case | ladder degrades to **rung 4, the multi-day wait NFT** | no bound — depends on LP/user arrival |
⇒ ⇒ **So ETH is "usually atomic, degrades to days"; BTC is "never atomic, unbounded".** The user's original
  instinct — that the band *"represents distinctly lightning deposits"* — is precisely why one side has a
  `take*` and the other does not.
⚠️ **AND NOTE THE ETH SIDE IS NOT RISK-FREE EITHER:** rung 4 is the **multi-day withdrawal NFT**, and C10
  showed rung 3 silently never paid for its whole life because the capacity view was mis-parameterised. So
  *"ETH refills instantly"* is true on the happy path and **false when venue liquidity is thin** — which is
  exactly when a unified pool would be drawn down. **Any sizing must use the LADDER's worst rung, not its
  best.**
📌 This makes the earlier recommendation concrete: **cap commitment by OBSERVED resupply rate per side** —
  the two sides have genuinely different distributions, so one shared budget with one shared assumption
  misprices both.

# 📐 LEGACY vs NOW — THE COMPARISON WE NEVER FINISHED (user, 2026-08-02). Legacy: `quidmint/quid/evm/src`.
User: *"why are there so many new internal functions and helpers… see how simple and clean that vogue.sol
was. we never finished our comparison between now and then."*

## THE MEASUREMENT — and it does NOT say what the line count says
| metric | legacy (ETH-only) | current (ETH+BTC) | ratio |
|---|---|---|---|
| `Vogue.sol` total lines | 531 | 1,447 | 2.7× |
| — of which COMMENT | 62 (**12%**) | 728 (**50%**) | 11.7× |
| — **actual CODE** | **469** | **719** | **1.53×** ⇐ the real number |
| functions | 18 | 64 | 3.6× |
| external/public | 2 | 28 | 14× |
| `Vogue` + companion (`VogueCore` / `VogueLib`) | 1,025 | 2,102 | 2.05× |
| whole `src/` | 6,108 | 10,784 | 1.77× |
⇒ 🎯 **The file did NOT triple in code — it grew 1.53× while its COMMENT volume grew 11.7×.** Half of
  today's `Vogue.sol` is prose. The *"simple and clean"* impression of the legacy file is partly that it was
  **barely documented**.

## WHERE THE 49 NEW FUNCTIONS ACTUALLY CAME FROM (categorised, not hand-waved)
| category | functions | is it accidental? |
|---|---|---|
| **4626 / token identity** | `_deposit4626` `_mint4626` `convertToAssets` `convertToShares` `mint` `redeem` `totalSupply` `totalShares` `balanceOf` `_transferShares` `transferSharesFor` `setVEth` | **NO** — a product decision (vETH is a 4626) |
| **leverage overlay** | `_reconcileLev` `syncLev` `debtUsd` `grossCollateralEth` `netEquityEth` `totalNetEquityEth` `kLvrWad` `realizedAlphaWad` `realizedVarianceWad` `soldFractionWad` `derivedThetaWad` `derivedThetaWadAt` | **NO** — a whole feature legacy lacked |
| **yield venues** | `_venueBalance` `_deliverVenueShortfall` `setEthVenueContract` `compound` `exitInstant` | **NO** — legacy had no venue layer |
| **band mechanics** | `addLiq` `_rebalance` `reseat` `collectFees` `_outOfRange` `_burnInRange` `bandSqrtP` `bandEthOf` `_modLpEth` `unwindForRedeem` | partly — legacy did this inside fewer, larger fns |
| **reward accounting** | `_settlePending` `_pendingFor` `_refreshBookmarks` | **NO** — per-LP fee accrual is new |
| **recipient pinning** | `pinRecipient` `applyPinnedRecipient` `_requirePinnedRecipient` | **NO** — §A.5f security subset |
⇒ ⇒ **~40 of the 49 are FEATURE-DRIVEN** (4626 identity, leverage, venues, reward accrual, a second asset).
  **~9 are DECOMPOSITION** of what legacy did in bigger functions — and that decomposition is largely forced:
  `via_ir = false` + EIP-170 mean big bodies must be split or moved to a `*Lib` (`VogueLib`, `SwapLib`).
  **The `*Body` naming across the libs is that pressure, made visible.**

## ⇒ THE HONEST VERDICT
 • The user's instinct is **half right**: the current file IS harder to read — but mostly because it is
   **50% prose**, not because the logic tripled.
 • **The genuine simplification target is not the function count — it is the COMMENT-TO-CODE RATIO and the
   14× external surface.** 28 external/public functions on one contract is a real API-surface smell, and it
   is the thing the §J.2c token-face move already started shrinking.
 • ⚠️ **But this session repeatedly DEPENDED on those comments** (§A.56's dedup note, §A.13's fix citation,
   the `create_sweep_tx` rationale, the `IWETH9` union precedent) **and was repeatedly MISLED by stale ones**
   (the reconnector, the "supersede" claim, the sum-cap at `Core:48`). ⇒ **The fix is not fewer comments —
   it is comments that cannot go stale**, i.e. converting the load-bearing ones into checks/tests (the
   `guard-real-invariants` rule).
▶️ **NEXT for this comparison:** the same measurement for `Aux.sol` vs legacy `Basket.sol`/`Aux.sol`, and a
  diff of the band-mechanics functions specifically — that is the ONE category where legacy may genuinely be
  simpler for the SAME job, and therefore the only place a real simplification is hiding.

## ✅ §C10 PART 2 COMPLETE — the PARTIAL FILL now lands. Rung 3 passes; 0 size exceedances.
The rung was ALL-OR-NOTHING: asking for the full `weethIn` when ether.fi's pool is thinner reverts
`ExceededRedeemable()` and abandons the WHOLE rung, dropping the LP onto rung 4's multi-day wait-NFT even
when most of it could be served instantly. Now:
```solidity
uint capEth   = IEtherFiRedemption(c.redeemer).totalRedeemableAmount(ETHFI_NATIVE_ETH);
uint capWeeth = IWeETH(c.weeth).getWeETHByeETH(capEth);      // OUTPUT-token units -> weETH
uint ask      = weethIn < capWeeth ? weethIn : capWeeth;
try ... redeemWeEth(ask, recipient, ETHFI_NATIVE_ETH) {
    if (ask >= weethIn) return covered;                       // served in full
    uint served = FullMath.mulDiv(amount, ask, weethFull);     // ETH-equiv of the partial
    return served + waitNft(covered - served, recipient, c);   // remainder -> rung 4
}
```
### 🔑 THE UNIT TRAP THAT BLOCKED THIS FOR THE WHOLE SESSION — resolved, not worked around
Capacity is denominated in the **OUTPUT TOKEN** (native ETH, 1:1 with eETH); the ask is **weETH**, and
weETH:eETH is **not** 1:1. A naive `min(weethIn, capacity)` mixes units and mis-asks by the weETH premium.
⇒ Converted with **`getWeETHByeETH`** — the SAME conversion `offrampBody:574` already uses to size this very
  call, so the clamp and the sizing now share one basis instead of two.
⇒ `served` is computed on the SAME basis as `covered` (`amount × ask / weethFull`), so the partial and the
  rung-4 remainder cannot double-count or drop ETH between them.
⚠️ **SIZE: SwapLib 24,224 → 24,428 (margin 353 → 148).** The clamp cost 204 bytes. Still under EIP-170 with
  0 exceedances, but **the margin is now tight enough that the next SwapLib change must be size-checked in
  the same run** (the C4 regression happened at exactly this margin).
📌 Also removed the stale block that said *"Blocked on confirming a capacity view… semantics UNVERIFIED. Do
  not clamp against a guessed ABI."* — that blocker was resolved earlier today (selector-matched against
  impl `0x5d53b303…b3dc`), and leaving it would have told the next reader not to do what is now done.

# 💰 COSTING: "QUOTE THE SAME DOLLARS IN BOTH BANDS" (user's #12 proposal). Priced on all six axes.
**Corrected premise (user was right, I was wrong):** today the dollars are **SPLIT**, not shared —
`Core.sol:1021-22` does `_addPooledUsd(isBTC, …)` then `require(committedUsd18() <= haircutTvl)`, and
`committedUsd18() = ETH equity + BTC equity`. **The SUM is gated, so each dollar backs exactly one band.**

## 1. CORRECTNESS — is double-quoting SOLVENT? ✅ **YES, and the enforcement already exists**
Real dollars leave at exactly one place: `_settleUsdSide`, `usdDelta > 0` ⇒ `AUX.take(who, …, token, 0)`
(`Core.sol:989`). That is a REAL ERC-20 transfer from the basket. **If the first band already took them, the
second `AUX.take` simply fails.** ⇒ **Double-spend is impossible by construction** — settlement, not the
gate, is what enforces spend-once. **The user's model is sound at the solvency layer.**
⇒ Failure mode is a **REVERTED TRADE**, not bad debt. That is a UX/liveness cost, materially cheaper than
  the "DoS" framing I used earlier, which was wrong.

## 2. 🔴 THE REAL BLOCKER — `committedUsd18` is ALSO the REDEMPTION solvency gate
`BasketLib.backingCoreBody:915-926`: `committedSum = ICore(core).committedUsd18()` vs
`totalLiquid = deposits[14]`; over-commit triggers a repack, then `_checkBacking` reverts `OverCommitted`.
**That gate guards redemptions, arb, and LP withdraw — not just band sizing.**
⇒ ⇒ **If both bands quote the same dollars, `committedUsd18` EXCEEDS TVL BY DESIGN — so EVERY redemption
  and EVERY LP withdrawal would revert**, after a futile repack. **The proposal is therefore NOT a one-line
  gate change from `sum ≤ TVL` to `each ≤ TVL`.** That edit alone would brick the drain side.
⇒ **What it actually requires: SPLIT ONE CONCEPT INTO TWO.**
  | today (conflated in `POOLED_USD_*`) | needed |
  |---|---|
  | **quoted depth** — mock USD placed in the V4 position | may exceed TVL (that IS the efficiency gain) |
  | **committed dollars** — real backing owed | must stay ≤ TVL (this is what `checkBacking` must read) |
  **This is literally what #12's "count once" names.** The invariant is not a check to add — it is the
  DISTINCTION the accounting currently lacks.

## 3. COST / FREQUENCY — how often would a trade revert?
Only when BOTH bands draw the same dollars before a repack. Repack already runs on the over-commit path
(`_repackPool` on the smaller pool), so there IS a healing mechanism. **Unmeasured:** collision rate under
real flow. ⇒ **Measure before building** — it decides whether this is a rare revert or a constant one.

## 4. BLAST RADIUS — ⚠️ asymmetric, and this is where it bites
A reverted TRADE is cheap. A reverted **LP WITHDRAWAL** is not. Since both share `checkBacking`, mis-sizing
the distinction converts an efficiency gain into stuck exits — **the same asymmetry as the BTC refill
problem: the ETH LP feels it as a revert, not a price.**

## 5. SECOND-ORDER — ✅ this actually IMPROVES the BTC crowding
Under double-quoting, a BTC commitment no longer consumes ETH's *quoted* headroom — only actual settlement
does. ⇒ **It directly attacks the crowding this whole thread started from**, and it does so WITHOUT needing
the (unbuildable) instant BTC refill. **That is the strongest argument for the proposal.**

## 6. REVERSIBILITY — ✅ good. The change is an accounting split plus a gate read; no signed/committed state
depends on it (unlike the #114 shard-count trap). Revertible by pointing `checkBacking` back at the sum.

## ▶️ VERDICT — **worth building, but it is a 2-accumulator change, not a 1-line gate flip**
 1. Add the distinction: keep `POOLED_USD_*` as QUOTED depth; introduce (or derive) SETTLED/committed USD.
 2. Point `committedUsd18` — and therefore `checkBacking` — at the **committed** figure only.
 3. Keep the band gate at `each ≤ TVL` (quoted), which is the user's efficiency gain.
 4. **Measure the collision rate first** (axis 3) — it is the one number that decides if this is worth it.
⇒ 📌 And it makes the earlier "don't unify" verdict WRONG in its reasoning: the risk is not insolvency (the
  transfer prevents that) — it is that ONE VARIABLE is doing TWO JOBS.

# 📐 LEGACY vs NOW, PART 2 — `Aux` and band mechanics. **The growth is EXTERNAL SURFACE, not logic.**
| file | legacy | current | code ratio | ext/pub ratio |
|---|---|---|---|---|
| `Vogue.sol` | 469 code · 2 ext/pub | 719 code · 28 ext/pub | **1.53×** | **14×** |
| `Aux.sol` (+ legacy `Basket.sol`) | **1,037 code** · 12 ext/pub | **691 code** · 43 ext/pub | **0.67× — SMALLER** | **3.6×** |
| band core (`VogueCore` → `Core`) | 457 code · 2 ext/pub | 696 code · 18 ext/pub | 1.52× | **9×** |
| **whole `src/` external surface** | **93** | **343** | — | **3.7×** |

## 🎯 THE FINDING — and it is not the one the line counts suggested
 • **`Aux` today contains LESS CODE than legacy `Aux` + `Basket` COMBINED** (691 vs 1,037) while doing
   strictly more (12 stables, depeg haircuts, venue supply, channels). ⇒ **The bodies moved to libraries**
   (`BasketLib`, `ChannelLib`) — that is real factoring, not bloat.
 • **But the EXTERNAL SURFACE went 93 → 343 across `src/` (3.7×)**, and per-contract it is worse: Vogue
   **14×**, band core **9×**. ⇒ ⇒ **Every `*Body` extraction to a library ADDS a public entrypoint**, because
   a delegatecalled library body must be `external`/`public`. **The factoring that shrank the code
   INFLATED the API.**
 • That is the mechanical explanation the user was reaching for with *"why are there so many new internal
   functions and helpers"*: they are not gratuitous — they are the **visible cost of `via_ir = false` +
   EIP-170**. Bodies must live somewhere callable.

## ⇒ SO WHERE A REAL SIMPLIFICATION HIDES (measured, not guessed)
 1. ⭐ **The 343-function external surface is the target, not the function count.** Much of it is
    `*Body`/`*Self` plumbing that exists ONLY to be delegatecalled — it is API by accident, not by design.
    A library body that is only ever called by its own contract could take an auth gate (`onlyUs`) or be
    consolidated; **each one removed is genuine attack surface removed**, not cosmetics.
 2. **`Core.sol` at 62 functions / 18 external for what legacy did in 19 / 2** is the densest ratio and the
    best place to look for band mechanics that legacy did more simply for the SAME job.
 3. **NOT a target:** `Aux`'s function count. Its code SHRANK; counting its functions punishes the very
    factoring that made it smaller.
📌 **Method note:** line counts said "2.7× bloat", code counts said "1.53×", and the external-surface count
  said "14×". **Three metrics, three different stories — and only the third points at anything actionable.**
  Counting the wrong thing would have produced a large, pointless refactor.

## ⚠️ §D5 PARTIALLY STRUCK — legacy's "simpler" take loop was simpler because it was WRONG.
D5's premise: *"legacy `_take` had no per-token dispatch — one positional loop with
`uint divisor = (i < 4 || i == 11) ? 1e12 : 1;`"*. Compared them directly:
| | legacy `Aux._take:486-522` | current |
|---|---|---|
| preferred token | `skip = token`, withdraw it directly, one pro-rata loop skips it | separate `_takePreferred` dispatch |
| decimals | **`(i < 4 || i == 11) ? 1e12 : 1` — POSITIONAL SLOT HARDCODE** | `IERC20(stable).decimals()` |
🔴 **That hardcode ALREADY BROKE IN PRODUCTION.** Our own code records it (`BasketLib:282-284`):
  *"Avoids the prior `i < 3 ? 1e12 : 1` slot-hardcode **which broke when USDG (6-dec) joined at slot 5**."*
⇒ **Legacy was shorter because it assumed a fixed stable ORDER.** We now carry 12 stables, 7 of them 18-dec —
  the exact fixture gap that hid C1/C2/C3/C4 all session. **Adopting legacy's loop would re-open it.**
⇒ ⇒ **STRIKE the decimals half of D5.** The current `decimals()` lookup is not complexity, it is the fix.

### ✅ D5 SURVIVING HALF — **DONE** (`BasketLib.sol:578-603`)
Legacy needed **no dispatch at all** for the preferred token: withdraw it, set `skip`, let ONE loop handle
the rest. That simplification is **independent of the decimals question**, and it is now applied.

The two branches (`token != quid` and `token == quid && preferred != 0 && seed == 0`) did the SAME job —
name the stable to serve first, then skip it pro-rata. They differed on only two axes, both now expressed
as ternaries inside ONE branch: **which index to validate** (`a.index` vs `a.prefIndex`) and **whether the
amount needs converting** to native units (swap arrives native; redeem arrives USD-1e18 and must be scaled,
which is the §A.50/C2 fix — KEPT, and now on a single line instead of duplicated prose).

| | before | after |
|---|---|---|
| branches | 2 (`if` / `else if`), 32 lines | 1, 26 lines |
| `_takePreferred` callsites | 2 | **1** |
| `decimals()`-based scaling | kept | **kept** (positional divisor NOT restored) |
| `BasketLib` bytecode | 21,643 | **21,520** (−123 B) |
| suite | — | **3,560 passed / 1 failed** — the failure is the pre-existing §A.16 `testLeverage_LvrControlVsTreatment`, unchanged. D5 regressed nothing. |

## ✅ COMPARISON ITEM 2 CLOSED — `Core.sol` 62 fns vs legacy `VogueCore.sol` 19. **Nothing to take.**
This was flagged as *"the densest ratio and the best place to look for band mechanics that legacy did more
simply for the SAME job."* Measured, name by name — every one of the 62 is accounted for:

| category | n | verdict |
|---|---|---|
| **1:1 with legacy** — `setup` `modLP` `outOfRange` `swap` `repack` `_unlockCallback` `_handleSwap` `_handleRepack` `_handleOutsideRange` `_handleMod` `_handleDelta` `_modifyLiquidity` `_modLP` `poolStats` `poolTicks` `_writeObservation` `observe` | **17** | same job, same shape — no legacy win available |
| **features legacy LACKED** — flow/EWMA + skew premium (9), leverage claim/equity (5), BTC vault + pooled-USD draw (6), `reseat`/JIT refill (3), `collectFees` (2), consent (1) | **26** | cannot be taken from a codebase that never had them |
| **`isBTC` duality** — `_t1` `_poolId` `_mockUsd` `_mockTok` `_key` `_obs` `_obsState` `_add/_subPooledUsd` `_add/_subPooledTok` `token1is` `observeBTC` `_initPool` | **14** | legacy needed 0 because it had ONE pool. These REPLACE mirrored ETH/BTC branches at every callsite — deleting them re-expands the bodies and costs bytecode, it does not save it |
| **stack-forced splits** of one legacy frame — `_repackBurn`/`_repackAdd` (from `_handleRepack`), `_settleUsdSide`/`_poolUsdInRange`/`_settleTokSide` (from `_handleDelta`) | **5** | forced by `via_ir = false`; legacy's single frame had 6 locals, ours adds `isBTC` + a `PoolKey` memory struct |
| **gratuitous decomposition** | **0** | — |

🟢 **And we are SIMPLER than legacy in one place:** legacy's `_getOldestObservation` and `_interpolate` live
in `OracleLib` here — 2 of its 19 functions are gone from the band contract entirely.

🔴 **The one addressable sub-category is the 14 duality accessors, and it is PRICED OUT.** The 6 scalar
selectors (`_t1` `_poolId` `_mockUsd` `_mockTok` + the 4 POOLED mutators) could collapse into fixed-size
`[2]` arrays indexed by `isBTC`, deleting ~6 internal functions. **Cost: an ABI break.** `POOLED_USD_ETH`,
`POOLED_BTC`, `token1isETH` etc. are public state vars whose auto-getters tests and the TS clients read
(`tools/check-client-abis.py`). Trading a real client migration for ~6 one-line internals is a bad deal.
**Not doing it** — recorded so it is not re-proposed.

📌 ⇒ **The `Core` growth is 26 features + 14 duality + 5 stack. The "62 vs 19" headline had no simplification
  hiding inside it.** Item 2 of the legacy comparison is now closed with a measured NEGATIVE result, which is
  worth as much as a positive one: it stops the next session from re-opening it.

📌 **The comparison that matters is not size — it is WHICH legacy simplicity was load-bearing and which was
  a latent bug.** Here: the `skip` pattern was load-bearing; the positional divisor was a bug that shipped,
  broke, and was fixed. **A "restore the simpler legacy version" instinct would have reintroduced it.**

## 🔴 THE LAST FAILING TEST IS A REAL FINDING, NOT A BROKEN TEST — and it IS #12
`testLeverage_LvrControlVsTreatment` is the only failure in the suite (3,560 pass). It has now been
measured to the mechanism. **Do not weaken the assertion** — it is asserting a true thing.

### What the numbers say
| | control (no flow) | treatment (20 swaps) |
|---|---|---|
| ETH leg returned | **399.814** | **367.370** |
| QUID leg returned | **0** | **0** |
| valued at px0 = 1,848.31 | 738,980 | 679,014 |
| externality | — | **−811 bps** |

🔎 **The externality is −811 bps at +20%, at flat, AND at −20% — the SAME number three times.** A real
LVR/inventory effect cannot be price-independent. An identical ratio at three prices forces
`tEth = 0.91885·cEth` **and** `tQuid = 0.91885·cQuid` algebraically: the bundle did not change
COMPOSITION, it was uniformly scaled. Measured directly, the QUID leg is **0 in both arms** — so this is
not an LP that sold ETH for USD, it is an LP that sold ETH for **nothing it can redeem**.

⇒ ETH sold = 399.814 − 367.370 = **32.444 ETH = $59,966** at px0.
⇒ BOLD that arrived = **$60,001**. The two match to **0.06%**. Every dollar the traders paid landed
  somewhere the LP has no claim on.

### The mechanism (proven, not inferred)
1. `Vogue.redeem` → `convertToAssets(shares)` → `_pricingBacking()` (`Vogue.sol:1227`).
2. `_pricingBacking()` = `AUX.vogueETH()` ± the leverage term.
3. `vogueETH` (`VaultLib._vogueETH:121`) sums **ETH-side assets only**: the three WETH-4626 curators,
   weETH, eETH, Aave ETH, idle WETH at Vault and Aux, Rover's WETH-equiv, lev net-equity.
   **There is no term for `POOLED_USD_ETH`.**
4. A stable→ETH band swap REMOVES ETH from `vogueETH` and ADDS USD to `POOLED_USD_ETH` + the basket.

⇒ **The LP's claim falls by the full ETH sold and rises by nothing.** The band's USD side is claimable —
  but by **QU!D holders**, through `Vogue.unwindForRedeem` (`Vogue.sol:962`, called from
  `BasketLib.sol:863` on the redemption path). It is claimable by the LP through **no path at all**.
  The asymmetry is one-directional and permanent: flat-price round trips move LP principal into basket
  backing and it never comes back.

### ✅ THE PRE-REGISTERED CHECK (`QUEUE:4723`) HAS NOW BEEN RUN — and it says **concrete accounting bug**
The doc asked for exactly one measurement and I had skipped it: *"check whether `POOLED_USD_ETH` rises by
~60,000 across the 20 swaps. **If it rises and `vogueETH()` does not reflect it, that is a concrete
accounting bug (#12's count-once invariant).**"* Instrumented and run:

| | before | after | Δ |
|---|---|---|---|
| `POOLED_USD_ETH` (6-dec) | 246,564.450070 | 306,564.450070 | **+60,000.000000 — exact** |
| `POOLED_ETH` | 400.000000 | 367.555478 | −32.444522 |
| `vogueETH()` | 400.000000 | 367.482117 | −32.517883 |

⇒ **It rises, by exactly the BOLD paid in, and `vogueETH()` does not reflect it.** The archive's own
  criterion is met. This resolves the (a)/(b) fork at `QUEUE:4715` in favour of **(a)**: the band IS
  credited a USD claim for the inventory it sold — the credit is recorded on-chain, in the right amount,
  at the right moment. **The only thing missing is that the LP's share price never reads it.**

📌 **This narrows the fix and corrects an earlier over-claim in this file.** The prior entry said the LP
  "sold ETH for nothing it can redeem", implying no claim existed. Wrong: the claim exists and is exact.
  The defect is confined to `_pricingBacking()` (`Vogue.sol:1227`) omitting a term, NOT to the band
  failing to book the sale.

### Why it is STILL not a one-line fix
The obvious patch — add `POOLED_USD_ETH` (converted at spot) to `_pricingBacking()` — is exactly the
trap #12 already named. `POOLED_USD_*` does **two jobs**: it is the band's QUOTABLE DEPTH *and* it is
the committed-dollars figure that `Core._poolUsdInRange` gates with
`require(committedUsd18() <= haircutTvl, "backing")` (`Core.sol:1022`). Crediting it to the LP as an
asset while it is simultaneously counted as a basket commitment double-counts the same dollars — the
same error the leverage fold already fixed once by switching gross → net equity.

▶️ **This is not a test to fix; it is #12's headline symptom, now quantified and localised to one term.** The prerequisite is
  still #12's accounting split: separate *quoted depth* from *committed dollars* so the LP's share of
  band USD can be credited without inflating the backing gate. Until that lands, the correct state of
  this test is **RED**, because the thing it asserts is genuinely false.
📌 **`_open` is a PLAIN `AUX.swap(bold, WETH, true, ...)`** — despite the file's name there is no
  leverage in this path. The leak is a property of ordinary band swap flow, which makes it broader
  than the `LeveragePnLProbe` filename suggests. Its comments claiming a leverage mechanism are stale.

# ✅ ARCHIVE ADJUDICATED — "is everything in `BUILD-QUEUE-AND-107.md` done?" answered item by item
**Short answer: no, but only ONE thing was genuinely lost.** The question was previously unanswerable,
which is the real problem this closes.

### First, do the two docs overlap? MEASURED, not asserted from their headers
| metric | result |
|---|---|
| substantive lines (>40 chars) | QUEUE 4,121 · ARCHIVE 3,953 |
| **byte-identical substantive lines** | **0** |
| identical `##` headers (444 vs 318) | **0** |
| item IDs appearing in BOTH | **93** |
| item IDs only in the ARCHIVE | **206** (mostly `#NNN` issue refs) |
⇒ **No textual duplication at all.** They overlap by SUBJECT (93 shared IDs) and diverge completely by
  CONTENT — which is what "archive holds evidence, QUEUE holds status" is supposed to look like. The
  header claim is now verified rather than trusted.

### Then: the 25 archive `§A.x` sections with NO QUEUE row — all 25 adjudicated
| verdict | items |
|---|---|
| **self-closed in the archive itself** (it records its own resolution) | A.10 (*"closes §A.10's open question"*), A.12 (*"rejected change… now removed"*), A.17 (DONE), A.21 (FIXED), A.28 (*"now fixed"*), A.32 (*"now fixed"*), A.40 (proof exists), A.42 (CONFIRM), A.47 (live in code at `:3645/:4565/:4589`) |
| **struck / corrected by a later section** | A.8d (*"the 19.4% figure IS STALE"*), A.16c (reverted in `2e5a0fa`), A.19 (superseded by A.19b), A.64 (*"STRIKE §A.64's central claim"*), A.66 (*"BOTH of my earlier framings are STRUCK"*) |
| **superseded by THIS session's work** | A.67 (3558/2 → now 3560/1), A.68 (*"C1 APPLIED, C2/C3 NOT"* → C1–C4 + C10 all done and suite-verified), A.73b (C1 re-applied alone) |
| **method/finding writeups, never actions** | A.2, A.3, A.7, A.33, A.39, A.53 (parallelisation map), A.60 (deferral audit) |
| 🔴 **GENUINELY MISSING FROM QUEUE.md** | **§A.65** — see below |

📌 **§A.60 is the load-bearing one and it VINDICATES the archive.** It is a deferral audit that already
  enumerated every genuinely-unbuilt item. Cross-checked all six against QUEUE.md: JIT-DEPTH §2, §A.55,
  §A.57, §A.5f, §A.19b, §A.43 — **all six are tracked here.** Nothing was dropped in that transfer.

## 🔴 §A.65 — THE ONE ITEM LOST IN THE ARCHIVE→QUEUE TRANSFER (0 prior mentions here)
Two standing requirements and one security action, none of which had a row.

**1. The basket fee MUST be DIRECTIONAL before `calcFeeL1` is re-wired (§A.64 step 2).**
An arber restoring composition toward target is doing the basket a favour. A fee priced on
CONCENTRATION ALONE charges them MOST exactly when the flow is needed MOST — it taxes the action that
fixes the thing the fee measures.
  • moves composition TOWARD target → ~0 · • moves it AWAY → charge.
⚠️ **This failure mode is SILENT** — no revert, no failing test, just an imbalance that quietly stops
  correcting. That is precisely the class that earns a guard rather than a comment.
**Ceiling is set by the market, not by policy:** an arber's profit ≈ the mispricing corrected, so a fee
above that spread means the trade does not happen — we collect nothing AND keep the imbalance. Rule:
fee ≪ typical stable-stable dislocation (single-digit bps), ZERO on the restoring direction.

**2. A pinned Chainlink feed is a PREREQUISITE for listing any new stable** (USDS included), not a
follow-up. §A.49's FRAX lesson: a listed stable with no pinned feed defers to a ZERO haircut, so a
depegged unit redeems at FULL FACE and cherry-pickers drain the sound stables against it.
*Unlisted = uncapturable but also undrainable* — declining to list is a real option, not a failure.

**3. ✅ DONE NOW — the committed RPC token.** `evm/foundry.toml:34` and `:62` both carried an Ankr URL
with the **API token in plaintext**, in a repo that has a `SPV public snapshot` commit (`0af7f6d`).
Replaced both with keyless `https://ethereum-rpc.publicnode.com` — the endpoint that actually completed
the full 3,560-test suite, where the rate-limited Ankr key degraded to a 9m50s timeout. Verified: a bare
`forge test` now forks with no env var set.
🔴 **STILL REQUIRED AND CANNOT BE DONE FROM HERE: ROTATE THAT TOKEN AT ANKR.** It is in git history;
  deleting it from HEAD does not un-leak it.

# ✅ SECOND PASS — the `#NNN` axis, the archive's OWN open list, and a self-check that caught me
My first adjudication covered only the `§A.x` axis (25 of 73 sections). It did **not** cover the 206
IDs that appear only in the archive, nor its 59 `OPEN` / 43 `TODO` / 14 `UNVERIFIED` markers. Doing that.

## 🔑 THE STRUCTURAL FACT THAT MAKES THIS TRACTABLE — `BUILD-QUEUE-AND-107.md:4501`
The archive contains its own divider: `CURRENT STATE — supersedes every earlier "OPEN" marker above`,
followed by *"this file is APPEND-ONLY, so earlier sections still say OPEN/UNVERIFIED for items resolved
later… Trust THIS section over any earlier marker."*
⇒ **Of 103 unresolved-looking markers, 97 sit ABOVE that line and are explicitly superseded by it.** The
  archive was never as ambiguous as its raw marker count suggested — it self-supersedes, and the only
  thing missing was anyone saying so out loud. Saying it here.

## ✅ THE ARCHIVE'S OWN 10-ITEM OPEN LIST (`:4520`), CROSS-CHECKED AGAINST THIS FILE
| # | archive item | status here |
|---|---|---|
| 1 | **6909 stable→stable fee path** | 🔴 **WAS THE ONE GAP — 0 mentions. Answered below.** |
| 2 | legacy `_take` comparison | ✅ DONE this session (§D5 + the `Core` 62-vs-19 close-out) |
| 3 | §A.61 6↔18 helper | ✅ tracked (task #7) |
| 4 | §A.52 interface dedup | ✅ done this session (7→0 underscore interfaces, Aux 6→1, Core 4→1) |
| 5 | §A.56 out-of-range PATH | ✅ tracked (12 mentions) |
| 6 | §A.46 assertion-free tests | ✅ tracked (11 mentions) |
| 7 | which `src/` files belong in `imports/` | ✅ tracked (`QuidLens`/`DeployLib` named) |
| 8 | JIT-DEPTH §2 | ✅ tracked |
| 9 | §A.19b · §A.43 · §A.5f · §J.8 | ✅ all four tracked |
| 10 | §A.15 inverted claim | ✅ tracked (11 mentions) |

⚠️ **A SELF-CHECK CAUGHT A CONTAMINATED VERIFICATION.** Re-running the "absent from QUEUE.md" test
  against the LIVE file reported all 25 items present — because **I had just written them into it
  myself** in the adjudication table above. Re-run against `d251952~1` (pre-edit): **all 25 genuinely
  absent.** The finding stands, but the method was circular for one turn. *Grepping a file you just
  edited proves only that you edited it — diff against the pre-change revision.*

# ✅ #1 ANSWERED — the 6909 stable→stable fee path (the user's ORIGINAL question)
§A.64 posed four steps and step 1 was *"CONFIRM stable→stable charges nothing today — VERIFY rather than
trust the comment."* Verified **by structure**, which is the right standard here because the claim is
about an ABSENCE and the comments asserting it are exactly what could be stale:

| function | on the money path? | what it actually does |
|---|---|---|
| `FeeLib.calcNeeded` (`:167`) | ✅ yes (redeem/outflow) | body is `deps; yields;` — **the inputs are discarded as no-ops** — then `return grossUpForDepeg(amount, calcRisk(token, c.hook))` |
| `FeeLib.applyFeeAndHaircut` (`:181`) | ✅ yes (payout) | `idx; deps; yields;` discarded; same haircut-only return |
| `FeeLib.scaledFeeL1` (`:134`) | ❌ no | **only caller is `QuidLens.sol:40`, a read-only lens** |
| `FeeLib.calcFeeL1` (`:109`) | ❌ no | survives only as a SOR ROUTING input (`SOR.sol:356`) |

⇒ ✅ **CONFIRMED: stable→stable charges NO fee today.** The sole outflow cost is the depeg haircut, and
  only during an actual depeg. The two functions that could charge one discard their fee inputs outright
  — that is structural evidence, not a comment.
⇒ **So there is nothing to route.** The user's *"it should feed into the existing accumulator"* describes
  the TARGET state. The accumulator itself is real and verified on both sides:
  `Vogue.sol:1055` (`feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc`) and
  `Vault.sol:732` (`feesPerShareBTC` / `USD_FEES_BTC`) — both fed by **V4 pool trading fees only**.
  (Archive cited `Vogue.sol:1069` and `BtcVaultLib:560,564`; both have drifted — normal for an archive,
  and the reason line cites there are re-verified rather than quoted.)
▶️ **REMAINING (steps 2–4, now unblocked):** re-wire `calcFeeL1` onto the stable leg → route to
  `feesPerShare`/`USD_FEES` **not** `tranche` → price it off the SAME signal the SOR routes on.
  ⚠️ **Gated on §A.65's DIRECTION term** (a symmetric fee taxes the arb flow that rebalances the basket,
  and fails silently) and on reading §A.51's truncated `baseRate` rationale first — if `baseRate` already
  priced this, re-adding a user-facing fee double-charges.

# 📌 #12 — THE MISSING SENTENCE, AS THE USER STATED IT (2026-08-02). This is the decision, not a question.
**(a) and (b) are not competing — they answer different questions.**
 • **(b) is what HAPPENS** — band and basket share one balance sheet, so selling band inventory transfers
   value to QU!D backing. **Measured, true** (POOLED_USD_ETH +60,000.000000 exactly; `vogueETH` −32.518).
 • **(a) is what SHOULD happen** — the band gave up real inventory and should hold a USD claim for it.
   **Absent: no such credit reaches `vogueETH()`.**
⇒ **The gap between them IS #12.** *"Count once" cannot be evaluated without stating WHO OWNS THE
  PROCEEDS of a band→basket sale.* That is the sentence that was never written. Writing the fork it needs:

| if… | then… |
|---|---|
| **the BASKET owns them** and band LPs bear it | this is a DESIGN CHOICE and must be documented as one — and both probes plus `testLeverage_LvrControlVsTreatment` must be **re-scoped**, because the assertion currently asserts the OPPOSITE |
| **the BAND is credited** | current behaviour is a **genuine count-once bug**: the basket counts the BOLD, the band counts nothing, and **one side of a real transfer goes unrecorded** |

📌 Either branch is defensible; **what is NOT defensible is leaving it unstated**, because the probes and
  the code currently encode DIFFERENT answers, and that is why the test has looked like a flaky
  measurement rather than an unmade decision. **This is now the top of #12 — the decision precedes the
  accounting split, not the other way round.**

# 🔴 THIRD PASS — "the other doc" was SEVEN other docs. Two carried untracked open items.
The question was *"no open items in the other doc?"* — but `docs/actionable/` holds **nine** files, and I
had only audited the archive. Auditing the rest. **QUEUE.md did NOT have everything.**

| doc | tracked in QUEUE? | verdict |
|---|---|---|
| `BUILD-QUEUE-AND-107.md` | ✅ | adjudicated in the two passes above |
| `GAS-AND-CORRECTNESS-AUDIT.md` | ✅ cited ×2 | G1–G10 tracked as **B11** |
| `TAPROOT-CHANNELS-BUILD-SPEC.md` | ✅ 13 mentions | 34 markers, but it is a **build spec** — its "TODO"s are implementation steps, not queue items |
| `SOR-SIGNIFICANCE-DESIGN.md` | ✅ 8 mentions | covered |
| `JIT-DEPTH-GUARANTEE.md` | ✅ 5 mentions | §2 deferral tracked |
| `LST-PEG-MONITOR.md` | ⚠️ 0 mentions | **self-closing** — *"the reactive de-risk monitor is over-engineering — don't build it"*, plus an explicit *"NOT open (don't re-raise)"* list. One residual below. |
| `IMPAIRMENT-DERISK-TRIGGER.md` | 🔴 **0 mentions** | **carries a live open product decision** |
| `PUPPETEER-E2E-MATRIX.md` | 🔴 **0 mentions** | **carries a gated open task (#18)** |

## 🔴 RECOVERED — the delta-1-both-ways product decision (`IMPAIRMENT-DERISK-TRIGGER.md`)
Two products are contrasted; **only one is built**:
 • **Up-lever + hold-down — BUILT.** Delta-1 / IL-free / levered fees on the up side; holds down on the
   down side. The doc's own title is the warning: *"hold-down is negative-skew, not safe"*.
 • **Delta-1 both ways, internal — NOT BUILT.** The true yield-bearing-competitor: stay levered THROUGH
   the down side, maintain delta-1 in both directions, rebalance internally.
✅ **This is not a stale doc — the code points AT it.** `script/DeployL1_s.sol:566`:
  *"OPEN product decision, spec'd in `docs/actionable/IMPAIRMENT-DERISK-TRIGGER.md`."*
  (The archive cited `:553`; it has drifted to `:566` — re-verified, not quoted.)
⇒ A **product decision for the user**, not an engineering defect. It belongs in the queue precisely
  because a live deploy script defers to it.

## 🔴 RECOVERED — Puppeteer E2E matrix (#18), GATED not forgotten
Exhaustive front-end fuzz over every integrated SPA path × happy/sad against the anvil mainnet fork,
sequenced BEFORE slither/echidna as the final gate. Its own header: *"Do NOT run until the other thread's
contracts land. This is the pre-scoped plan; execution waits."* ⇒ Correctly deferred, wrongly invisible.

## 🟡 LST-PEG-MONITOR residual — a NUMBER, not a build
The reactive monitor is explicitly rejected as over-engineering (do not re-raise). What survives is *"a
config/judgment decision, not a build — a number, plus enforcing it at the venue-selection/deposit path"*:
the **venue concentration cap**. Small, but it is a decision nobody has made.

📌 **METHOD NOTE — the lesson of this third pass.** I answered "is everything tracked?" twice and was
  wrong both times for the SAME reason: I audited the surface I had been LOOKING at (first `§A.x`, then
  `#NNN`) instead of first enumerating the surfaces that exist. `ls docs/actionable/` is one command and
  it was the whole answer. **Enumerate the containers before auditing the contents.**

# ⭐ #12 RESOLVED BY MEASUREMENT — the fork is a FALSE BINARY. Neither branch as stated.
The decision was posed as: *basket owns the proceeds (document it, re-scope the probes)* **or** *band gets
credited (a genuine count-once bug: the basket counts the BOLD, the band counts nothing, one side of a
real transfer unrecorded)*. Measured the second branch's premise directly. **It is false.**

| | before | after | Δ |
|---|---|---|---|
| `POOLED_USD_ETH` (6d) | 246,564.450070 | 306,564.450070 | **+60,000.000000** |
| `POOLED_ETH` | 400.000000 | 367.555478 | −32.444522 |
| `vogueETH()` | 400.000000 | 367.482117 | −32.517883 |
| **basket TVL** (18d) | 1,152,000.111314 | 1,212,001.107906 | **+60,000.996591** |
| **`committedUsd18()`** (18d) | 246,564.450070 | 306,564.450070 | **+60,000.000000** |

### 1️⃣ THE BAND *DOES* COUNT IT — so "one side unrecorded" is not what is happening
`committedUsd18()` rises by **exactly +60,000.000000**. Both sides of the transfer ARE recorded: the
basket books +60,000.996591 of real BOLD, the band books a +60,000.000000 claim against it. **There is
no count-once bug at the band/basket boundary**, and the ≤TVL gate keeps *more* headroom than before
(TVL Δ − committed Δ = **+0.9966**), so the two move together rather than one outrunning the other.

### 2️⃣ THE SALE ITSELF IS PRICED CORRECTLY — the LP earned a spread on it
ETH sold **32.444522**, worth **59,967.51** at px0. Credit received: **60,000.000000**.
⇒ **+32.49 USD spread** — the LP sold at slightly better than mid and was paid for it. That is a healthy
AMM sale, not extraction. The mechanism is working; only its *readout* is wrong.

### 3️⃣ ⇒ THE REAL DEFECT IS NARROWER THAN EITHER BRANCH
`_pricingBacking()` (`Vogue.sol:1227`) reads `vogueETH()` — the **ETH half of a two-legged claim** — for a
band whose position is ETH + USD. Nothing is unrecorded and nothing is double-counted; the share price
simply reads one leg of two.

### 4️⃣ AND THE FIX IS THE *DELTA*, NOT THE LEVEL — which is exactly #12's split, now with a definition
| credit… | result |
|---|---|
| the **LEVEL** (`POOLED_USD_ETH` = 306,564) | ❌ **over-pays by 246,564.45** on a 739,324 deposit — that base is BASKET-supplied quoting depth the LP never contributed. This is the trap that made "just add it to `_pricingBacking`" look wrong, and it IS wrong. |
| the **DELTA since deposit** (+60,000) | ✅ LP shortfall measured 59,966.44 ⇒ credit − shortfall = **+33.56**, turning the failing `tFlat >= cFlat` into a PASS with a small fee gain — **exactly what the test's own comment predicts**: *"flat ⇒ ~fees"*. |

⇒ ✅ **#12's "quoted depth vs committed dollars" split now has a concrete definition:**
  **BASE = basket-owned quoted depth · INCREMENT = LP-owned sale proceeds.**
  The variable's two jobs are separable along the deposit boundary, which is why one variable could do
  both without the accounting ever diverging — and why the LP's claim is the only thing that broke.

⚠️ **WHAT IS NOT YET SETTLED — do not read this as a finished fix:**
 1. **Single-LP scenario.** With multiple LPs the increment must be apportioned per-share, and base
    attribution needs care when LPs enter/exit at different times and at different band compositions.
 2. **Delivery leg.** Crediting USD into the LP's claim means `_withdraw` must actually DELIVER it — the
    measured QUID leg is currently **0 in both arms**. A claim that prices but cannot be redeemed is
    worse than the present state.
 3. The **+0.9966** TVL/committed gap is BOLD accrual/rounding, not material here, but it should not be
    assumed to stay small under many rounds.
📌 **Still a user decision — but a much smaller one than posed.** Not *"who owns the proceeds"* (measured:
  the band books them, correctly) but *"do we credit the delta to LP share price, and build the USD
  delivery leg to match?"*
