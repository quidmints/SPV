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

# 🔴 OPEN — money path (do these first)

| id | what | state |
|---|---|---|
| **C1** | `Aux.deposit` returns NATIVE; `SwapLib._swapOutPrep`/`_consumeVolInput` treat it as 6-dec | RE-APPLIED ALONE, suite verifying. Prediction: unchanged at 3,558/2, since `scaleTo6` is a no-op for 6-dec and every test uses USDC |
| **C2** | `Core.sol:989` hands `AUX.take` a 6-dec value where NATIVE is required | REVERTED (§A.72). The audit's patch was WRONG — `scaleTokenAmount` converts native↔18-dec, but this value is 6-dec. **Needs a `from6(amount6, token)` helper that DOES NOT EXIST** |
| **C3** | `BasketLib.convert` 1e10 off for `volScale=1e8`; 2 uncompensated BTC sites (`SwapLib:1013`, `:444/455`) | open. Apply ONLY after C1 verifies — fixing C3 first ARMS a latent `Core.refundUnfilled` mismatch |
| **C4** | a WEI premium written into a 6-dec register ⇒ `derivedThetaWad` blows past 1e18 permanently ⇒ **the Merton band throttle is DEAD on the ETH side** after the first volatile sell-in | open |
| **C5** | `Vogue.sol:658` missing `* 1e12` — a THIRD §A.57 site. On a FULL EXIT an LP's whole USD fee leg pays at 1e-12 | open. One token; mirrors `Vogue.sol:439-440` |
| **F2** | BOLD paid by leverage opens does not reach the Stability Pool (0 vs ~1.584e18) | open, cause untraced |
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
