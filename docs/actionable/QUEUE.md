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

