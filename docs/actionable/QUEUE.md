# QUEUE — the single current-state list (2026-07-29)

**This file supersedes `BUILD-QUEUE-AND-107.md`**, which is now an ARCHIVE: 5,106 lines, append-only,
73 `A.x` items, several re-framed two or three times (§A.50 and §A.58 each). Reading it chronologically
is the only way to know what is true there, which is a tax every session was paying. Detail and evidence
still live there and in `GAS-AND-CORRECTNESS-AUDIT.md`; **status lives HERE and is updated IN PLACE.**

## Scale, honestly
`A.1`–`A.45` predate 2026-07-29. `A.46`–`A.73` were added ON 2026-07-29 — 28 new items, of which 19 came
from one audit. **The queue GREW today.** That is the expected result of looking properly, not a
regression, but it is the opposite of "most of it is finished".

---

# 🎯 NEXT ACTION, RANKED (user asked 2026-07-29: *"what is the next highest value item?"*)

**1. CLOSE THE 18-DEC FIXTURE GAP — this gates everything else on the money path.**
   The decisive argument: **C1 is currently UNVERIFIABLE.** `scaleTo6` is a NO-OP for USDC, every test
   uses USDC, so the honest prediction for C1-alone is *"the suite will not change"* — i.e. **the suite
   CANNOT tell us whether C1 is correct.** Same for C2, C3, C5. Fixing them without an 18-dec fixture is
   patching BLIND, and today showed the price: C2 looked right, was wrong, cost 333 failing tests.
   ⇒ ONE fixture that runs the EXISTING money-path tests with GHO/DAI/BOLD instead of USDC converts C1,
     C2, C3 and C5 from *argued* to *tested*. Nothing else on this list has that leverage.
   ⇒ It is also Echidna target #1 (§A.70), so the work is not duplicated — the fixture IS the fuzz seed.

**2. C4 — the dead θ throttle.** DECIMAL-INDEPENDENT, so it is verifiable TODAY with no new fixture, and
   it is a live risk control that is silently off after the first volatile sell-in.

**3. Verify the remaining 33 open-marked items.** Cheap (minutes each) and it fixes the planning picture —
   several are probably already done. But it is PLANNING work: it tells you what to do, it does not fix
   anything. Do it when a code task is blocked, not instead of one.

**4. C3 / C5 / F1 / F2** — once (1) makes them observable.

⚠️ NOT next: §A.56 part 2 and §A.52 are tidiness; §A.71's struct merge is one candidate. All are behind
  a money path with five open defects.

# 🔴 OPEN — money path (do these first)

| id | what | state |
|---|---|---|
| **C1** | `Aux.deposit` returns NATIVE; `SwapLib._swapOutPrep`/`_consumeVolInput` treat it as 6-dec | ✅ **APPLIED & CONFIRMED — it FIXED F2.** 3,559/1 vs a 3,558/2 baseline. My prediction (unchanged) was WRONG in the best way: `ZZBoldProbe` now PASSES because **BOLD is 18-dec** — see §A.74 |
| **C2** | `Core.sol:989` hands `AUX.take` a 6-dec value where NATIVE is required | REVERTED (§A.72). The audit's patch was WRONG — `scaleTokenAmount` converts native↔18-dec, but this value is 6-dec. **Needs a `from6(amount6, token)` helper that DOES NOT EXIST** |
| **C3** | `BasketLib.convert` 1e10 off for `volScale=1e8`; 2 uncompensated BTC sites (`SwapLib:1013`, `:444/455`) | open. Apply ONLY after C1 verifies — fixing C3 first ARMS a latent `Core.refundUnfilled` mismatch |
| **C4** | a WEI premium written into a 6-dec register ⇒ `derivedThetaWad` blows past 1e18 permanently ⇒ **the Merton band throttle is DEAD on the ETH side** after the first volatile sell-in | open |
| **C5** | `Vogue.sol:658` missing `* 1e12` — a THIRD §A.57 site. On a FULL EXIT an LP's whole USD fee leg pays at 1e-12 | open. One token; mirrors `Vogue.sol:439-440` |
| ~~F2~~ | BOLD not reaching the Stability Pool | ✅ **CLOSED by C1** — cause was the 18-dec seam, not a Liquity leak |
| C6–C9 | seedFee clamp basis · ungated TWAP seam · stale read across repack (`Vogue:978-989`) · `scaleTo6` on 4626 share decimals | open, lower severity |
| **F1** | control-LP redeem delivers 0 | open. Probably a FIXTURE warp (immature QU!D = the audit's intended behaviour) — **verify before touching the protocol** |

**Why all of these survived a green 3,558-test suite:** 7 of 12 basket stables are 18-decimal
(GHO, RLUSD, BOLD, DAI, USDS, USDe, cUSD) and **every existing test uses USDC.** Closing that fixture gap
is the highest-leverage single action available.

# 🟠 OPEN — structural / dedup
- **§A.71** codebase-wide dedup. Structs SCANNED (71 total, 7 shared shapes); one live candidate:
  `LevManager.Pos` == `BtcLevManager.Pos`. Remaining sub-passes: ETH/BTC twins, inlined helper bodies,
  interfaces, constants. **Method: hunt duplicated LOGIC, not names** — `sizeOorUsd` already existed and
  the ETH path had copied its body.
- **§A.71b 🔴 NEAR-MATCH DEDUP — the method used so far CANNOT find what the user describes.**
  User: *"i am certain that there is more dedup work to do that is not getting picked up as a dedup
  opportunity because of small semantic differences."* **Correct, and it is a flaw in my scan, not a
  hunch.** The struct sweep matched EXACT field signatures, so `{a,b,c}` vs `{a,b,c,d}` read as
  unrelated; likewise two functions differing by one guard or one param. `sizeOorUsd` was only found
  because the ETH copy was BYTE-IDENTICAL — had it differed by a line, the scan would have missed it.
  ⇒ NEEDED: NEAR-match detection. (a) structs whose field sets are SUBSETS or differ by ≤1 field;
    (b) function pairs with the same CALL-SEQUENCE SKELETON (normalise identifiers, diff the sequence of
    calls/branches) — catches "same job, one extra guard"; (c) ETH/BTC twins compared BODY-BY-BODY,
    asking of each difference whether it is REAL asset semantics or incidental.
    **Concrete starting point: `ChannelLib.supplyBody`'s three branches (Aave / BOLD / 4626)** — all
    return native and differ mainly in HOW they source, which is exactly the shape that hides behind
    "small semantic differences".
- **§A.66b 🟠 THE LEGACY COMPARISON WAS NOT COMPREHENSIVE.** Only `Aux.sol`'s `_take` and `Vogue.sol`'s
  structure were read, yielding exactly two findings: the native-units convention (C1 rests on it) and
  G2 (`decimals()` at 33 seams vs the legacy's zero-call divisor). **A file-by-file diff of
  `Basket`/`Core`/`VogueCore`/`Rover`/`imports/` against `~/Documents/quidmint/quid/evm/src/` has NEVER
  been done** — and both findings it did produce were high-value, so expected yield is good.
- **§A.52** interface dedup — 95 locals, ZERO name-duplicates ⇒ semantic. Group by target contract.
- **§A.56 part 2** — out-of-range ARGS: a responsibility-boundary move (VogueLib sizes only; BtcVaultLib
  does everything), not a signature change. Partial at `/tmp/A56-partial.patch`.
- **§A.61** boundary definition — name where 6/8↔18 happens; **§A.72 proved a needed helper is missing.**
- **G1–G10** gas: same basket scan 2–3x per tx; `decimals()` as an external STATICCALL at 33 seams
  (the legacy used a zero-call divisor); 13-iteration SLOAD loops 4x per redeem; TWAP ≈ 42M gas suite-wide.

# 🟡 OPEN — capability / infra
- **§A.19b** `redeemVBtc` — rail exists, entrypoint does not. 3 contracts move together.
- **§A.43** attestation binding — EVM key IS enclave-born/sealed; only the quote binding is missing.
- **§A.5f** per-action auth (the timelocked recipient pin shipped as a SUBSET).
- **§J.8** weETH-on-Aave-v4 · **§A.15** VERIFY the possibly-inverted claim first · **§A.49** FRAX/sFRAX
  (a pinned Chainlink feed is a PREREQUISITE, not a follow-up).
- **§A.69** anvil E2E + real deploy gas — never run; ONE `forge script` closes both.
- **RPC**: `foundry.toml:34` hardcodes a rate-limited Ankr key **committed in plaintext** in a repo with
  a public-snapshot commit ⇒ rotate. Use `${MAINNET_RPC}`. Working alternative:
  `https://ethereum-rpc.publicnode.com`.
- **§A.46** 3 assertion-free tests remain (of 7; 4 addressed).
- **JIT-DEPTH §2** — genuinely deferred, but the blocker is LIFTED (`Basket.turn` exists).

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

