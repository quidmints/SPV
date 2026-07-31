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

