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

