# GAS + CORRECTNESS AUDIT (2026-07-29) — pre-Echidna

Full read of `BasketLib`, `FeeLib`, `SwapLib`, `ShareMath`, `Basket`, `BtcVaultLib`, `LevMath`,
`ChannelLib.{depositBody,supplyBody}`, plus targeted reads of `Core`, `Aux`, `Vault`, `Vogue`,
`VogueLib`, `LevOracles`, `VaultLib`. Legacy benchmark: `quid/evm/src/Aux.sol`.

**MEASURED** = one `forge test --match-path test/Alles.t.sol --gas-report` (110 passed / 1 failed / 2
skipped). That failure (`testCompound_SelfFundingTip`) is unrelated and other agents were editing
`test/` during the run. Everything else is **INFERRED** from code with the trace shown.

## ROOT CAUSE — not "missing conversions". THREE functions define DIFFERENT unit contracts at one seam
| producer | actually returns | what callers assume |
|---|---|---|
| `Aux.deposit` (`Aux.sol:1127`→`ChannelLib.depositBody`→`supplyBody`) | **token-native** | "normalized 6-dec USD" (`SwapLib.sol:1004-1006`) |
| `Core._settleUsdSide` USD leg (`Core.sol:982-984`) | **6-dec mockUSD** | `AUX.take` wants **token-native** |
| `BasketLib.convert(…, volScale=1e8)` (`BasketLib.sol:408-413`) | **1e10 off both ways** | "WAD-scaled USD-per-asset" per its own docblock |

`scaleTokenAmount`/`scaleTo6` are CORRECT and called at *some* seams. The OOR paths
(`VogueLib.sol:662`, `BtcVaultLib.sol:296`) call `scaleTo6`; the swap paths do not. **That asymmetry is
the bug generator.**

# CORRECTNESS (ranked by blast radius)

## C1 🔴 CRITICAL — `Aux.deposit` returns NATIVE; three money-path sites treat it as 6-dec USD
Sites omitting the conversion: `SwapLib.sol:1006` (`_swapOutPrep` — comment even claims *"normalized
6-dec USD"*; flows to the V4 buy AND the LP's owed `usd6`) · `SwapLib.sol:529` (`_consumeVolInput`) ·
`SwapLib.sol:508` (`_refundExcess`, whose `* 1e12` only makes sense if `excess` were 6-dec).

Proof the return is native, three ways: (1) `ChannelLib.supplyBody` returns native on ALL branches
(Aave `deposited`, BOLD `return amount`, 4626 `convertToAssets`); (2) `Basket.sol:241-246` passes
`deposited` WITH `decimals()` into `calcMintYield`, scaled at `BasketLib.sol:490-491`; (3)
`VogueLib.sol:662` and `BtcVaultLib.sol:296` wrap the identical call in `SwapLib.scaleTo6(...)` —
**the correct treatment exists ten lines away in a sibling path.**

**7 of 12 basket stables are 18-dec** (GHO/RLUSD/BOLD confirmed on mainnet via `cast`, plus
DAI/USDS/USDe/cUSD). Only USDC/USDT/PYUSD/USDG/AUSD are 6-dec — **and those are the only ones the tests
use**. Reachable: `Aux.swapTo` is public payable, `BTCChannels.requestSwapOutOnchain` external, neither
restricts `token` beyond `_requireStable`. A GHO `creditSwapOut` records `usd6` 1e12x high →
`BTCChannels.sol:1200-1215` → `BtcVaultLib.sol:74` mints `exactUsd * 1e12`. The `uint96` guard at
`BTCChannels.sol:1203` does NOT catch it ($1000 → 1e21 ≪ 2^96).

## C2 🔴 CRITICAL — `Core.sol:989`, the mirror-image omission on the way OUT
`if (!keep && token != address(0)) AUX.take(who, usdAmount, token, 0);` — `usdAmount` is **6-dec
mockUSD** (`Core.sol:982-984`; mock decimals pinned `OracleLib.sol:149-150`), but `AUX.take` wants
**native** (stated at `BasketLib.sol:620-628`; the two callers that DO convert are `SwapLib.sol:1170`
and `:1222`). Reached from `Aux.swapTo(DAI,false)` and from `Vogue.pull`→`Core.outOfRange`.
**The create side of the same position scales correctly (`VogueLib.sol:662`) — the round trip is
provably asymmetric.** An 18-dec redeemer is paid 1e12x too little. `minOut` does NOT catch it:
`Core.swap` returns the 6-dec delta, a different basis than delivery.

## C3 🟠 HIGH — `BasketLib.convert` off by 1e10 for `volScale=1e8`; two BTC sites don't compensate
`BasketLib.sol:408-413`. With `px_wbtc = 6e32` at $60k: `toVol` is **1e10 under**, `!toVol` **1e10
over**. The repo already knows — `SwapLib.sol:926-929` writes the authoritative `/1e30` and names this
exact bug; `SwapLib.sol:736` compensates with `* 1e10`. **Uncompensated:** `SwapLib.sol:1013`
(`_swapOutPrep`, `rp.pooled = POOLED_BTC()`) and `SwapLib.sol:444`+`:455` (`swapToBody` forVolatile+
isBTC). Both are the `!toVol` case since `POOLED_BTC` is raw sats. ⇒ `consumed = min(p.amount, cap)`
ALWAYS picks `p.amount` ⇒ the BTC inventory bound never binds ⇒ `SwapLib.sol:1037` can never fire (LP
over-owed on an inventory-bounded partial) and `refundUnfilled`/`_refundExcess` are **DEAD CODE on every
BTC path**.

⚠️ **FIX C1+C2+C3 AS ONE CHANGE.** `Core.refundUnfilled` (`Core.sol:298-300`) gets `amount - consumed`
where `amount` is native (C1) and `consumed` is 6-dec. The mismatch is currently MASKED because C3 makes
the branch unreachable. **Fixing C3 alone ARMS it** — for an 18-dec stable it refunds the swapper's
entire deposit *after* the swap executed.

## C4 🟠 HIGH — a **wei** premium written into a 6-dec register silently kills the θ risk budget
`SwapLib.sol:416` `r.amount` is raw WEI → `:442` `retainSkewPremium` → `:1323` `premium =
mulDiv(amount, skew, 1e18)` (WEI) → `Core.sol:277-284` `recordSkewPremium(uint premiumUsd)` whose
docblock says *"Units = … (6-dec)"* → `_bumpEwma` → `VogueLib.sol:334-339` `mulDiv(prem6 * 127, 1e18,
pooled6)` (pooled6 genuinely 6-dec) → `derivedThetaWad` → `applyTheta` returns `available` unthrottled
when `>= 1e18`. One 1 ETH sell at 1% skew writes `1e16` into a register read as "$10,000,000,000"
(~3.3e8x at $3000/ETH). The clamp was deliberately deleted (`VogueLib.sol:376-381`), so it stays blown
for the EWMA's life. **The #107/D3 Merton band-size throttle is DEAD on the ETH side after the first
volatile sell-in.** Fail-open; `clampByBacking`'s physical headroom still binds, so not a direct drain —
but the control is gone and `Core.skewPremiumETH` is meaningless.

## C5 🟡 MEDIUM — a **THIRD** instance of the §A.57 mint bug, `Vogue.sol:658`
`QUID.mint(recipient, owed, address(QUID), 0);` — missing `* 1e12`. `LP.usd_owed` is 6-dec. The sibling
220 lines up (`Vogue.sol:439-440`) HAS the fix, as does `BtcVaultLib.sol:57`. Line 658 was introduced by
the §4.1 defer-to-full-exit refactor and missed. `_withdraw` settles with `mintRecipient == address(0)`
(`Vogue.sol:548`), so **on a FULL EXIT an LP's entire accrued USD fee leg is paid at 1e-12 of value.**
Under-pays (safe direction) but a total loss of that leg.

## C6 🟡 `BasketLib.seedFee:319-321` clamps a NATIVE fee against an 18-dec headroom (`Basket.seeded`) — 1e12x too loose for 6-dec stables, never binds. Second clamp (`:322-323`) is correct.
## C7 🔵 LOW/latent — `SwapLib.twapBody:123` `isETH = asset == weth`; everything else falls to the BTC ring (×1e10 basis). `Aux.swapTo` guards it, but `getTWAPforAsset`/`resolvedTwap`/`wellSkew` are public+ungated, and if the `WBTC` immutable is unset (`Aux.sol:296` makes it conditional) `asset == address(0)` satisfies `asset == address(WBTC)`. View-only today.
## C8 🟡 NON-DECIMAL — `Vogue.sol:978-989` reads `usd6 = POOLED_USD_ETH()` BEFORE `_rebalance()`, which can repack and ZERO it (`Core.sol:778`). The ratio at `:987` and the delta at `:989` then mix pre- and post-repack state. Decimals right, ordering wrong.
## C9 🔵 SUSPECTED — `scaleTo6(x, token)` reads the WRAPPER's decimals for a 4626 share while `depositBody` returned `convertToAssets` (the UNDERLYING's). 18-dec MetaMorpho shares over USDC would `/1e12` → 0 → `revert Dust()`. Not confirmed any wired vault differs. DoS, not silent loss.

## VERIFIED CORRECT — do not re-derive
`getTWAPforAsset(WBTC)`'s ×1e10 lift is applied EXACTLY ONCE on both paths (internal
`BasketLib.getPrice` `WAD*1e12` over the 6/8-dec mock pair; Chainlink `SwapLib.twapResolve:181-182` then
`*= 1e10`; both = `6e32` at $60k, ETH = `3e21`). · `Core.sol:112,225,237` · `LevMath.sol:175,192,195,
220-221,262` · `BtcLevManager.sol:153,159,174` · `LevOracles.sol:40,56,74` · `VogueLib.sol:461,98,423` ·
`Vogue.sol:987,989` · `BtcVaultLib.sol:57,74,96` · `Basket.sol:245`+`BasketLib.sol:490-491` ·
`Core._modLP` passes raw decimals into `LiquidityAmounts` **by design** (`sqrtPriceX96` already encodes
the ratio) — no `scaleTokenAmount` belongs there.

# GAS (ranked)

MEASURED headline: `Vogue.deposit` **2,078,191** (558 calls) · `Vogue.withdraw` **1,854,040** (291) ·
`Aux.swap` **1,630,753** (max 3.26M) · `Aux.redeem` **1,493,217** (max 2.08M) · `Basket.mint`
**1,003,885** (267) · `Aux.redeemableAmount` **540,770** *for a view*.

**G1 — biggest win: the same basket scan runs 2–3x per money-path tx.** `get_deposits` 145,553 cold ·
`checkBacking` 172,635 · `get_metrics` 154,442 · `depegLoss` 30,937 warm. `checkBacking` is ~85% one
redundant scan: `BasketLib.backingCoreBody:912-913` calls `get_deposits()` only to derive
`totalLiquid = deposits[14]` — **the value `_takeCore` already holds** in `amounts[14]`
(`BasketLib.sol:603-613`). Add `checkBackingWith(uint totalLiquid)`, mirroring the existing
`takeBodyWith`/`get_metricsWith` plumbing (`BasketLib.sol:559`, `Aux.sol:560`). Repeat sites:
`Basket.sol:206,207,215` · `BasketLib.redeemableBody:954,955,959` (three scans in one view = the 540k) ·
`SwapLib.swapToBody:407`+`_consumeQdIn:549` · `redeemAsBody:836`+`takeBody:548`+`backingCoreBody:912`.
Model to copy: `takeBody:543-547`'s WETH short-circuit.

**G2 — `decimals()` as an external STATICCALL at every seam. THIS is the legacy regression.** Legacy
`quid/evm/src/Aux.sol:519` did the pro-rata loop with `uint divisor = (i < 4 || i == 11) ? 1e12 : 1;` —
**zero external calls**. Ours: `BasketLib.sol:670` `try IERC20(token).decimals()` **per slot, 12 per
redeem**. (The hardcode had to go — USDG broke it, `BasketLib.sol:289-291` — but the replacement pays a
CALL where a cached byte would do.) Same at `BasketLib.sol:292,384,788` · `SwapLib.sol:1416` ·
`LevMath.sol:854,858` — **33 call sites**, several 2–3x in one function (`LevMath.sol:195,220,221`).
⇒ **`mapping(address => uint8) decOf` populated at registration (or 12 packed into one word) restores
legacy cost AND makes the conversion non-optional — it is the SAME edit that closes C1/C2.**

**G3** `FeeLib.multiVaultWithdrawBody` — up to 3x `balanceOf` per vault (`FeeLib.sol:297-309`, then
`_shareCap:350-354`, then the pass-2 sweep `:321-326`); `bals[j]` already carries the assets figure.
**G4** `BasketLib.sol:771-783` `_illiquidLoss` re-reads what it just read — `VaultLib._withdrawableOf`
repeats `balanceOf`+`convertToAssets` on the Morpho-V2 branch (6 of 8 vaults), and it runs on every
redeem quote AND every protocol mint (`Basket.sol:215`).
**G5** 13-iteration SLOAD loops in the redeem hot path: `matureSupply` 36,403 · `immatureBalanceOf`
33,628 (`Basket.sol:136-146`), called 4x per redeem (`_settleRedeem:855-856`, `_redeemQuote:824`,
`_consumeQdIn:552`) ⇒ **~70–105k per redeem**. Mint/burn already touch `totalSupplies[k]`, so a running
`immatureSupply` counter is nearly free.
**G6** TWAP is the hottest call: `twapBody` 2,057 × 20,551 ≈ **42M gas** suite-wide; `resolvedTwap`
1,389 × 23,535; `getTWAPforAsset` 668 × 28,994. `_priceOr` dedups within a swap only.
`VogueLib.realizedVarianceWad` 49,114 avg — `derivedThetaWad` walks the observation ring twice
(`VogueLib.sol:369-372`).
**G7** `get_deposits` returns `uint[15] × 2` over an external self-CALL (`BasketLib.sol:115-116`,
`Aux.sol:1133`); worst case `SwapLib._heldUsd18:1181-1186` does a full scan + 30-word decode to read
**one** slot, inside the de-lever path.
**G8** `getDepegSeverityBps` **8,674 calls @ 1,336 ≈ 11.6M gas**. `_takeProRata:660` → `FeeLib.allocate`
(external DELEGATECALL) per slot → fresh `latestRoundData`+`decimals()` — but `get_deposits` **already
computed `sev` for every stable in the same tx** (`BasketLib.sol:175`) and discarded it.
**G9** `BasketLib.sol:117-119` documents avoiding an `IAux(aux)` self-call via a storage-ref param, then
`:175` does exactly that round-trip 12x per scan from a body already delegatecalled in Aux's context.
**G10** Struct copies: `Vogue.autoManaged` 9,067 × 285 (public getter returning the whole
`Types.Deposit` to one-field callers); `BasketLib.computeMetrics:71-111` passes a 5-word struct by value.

# ECHIDNA TARGETS (all unreachable by today's 6-dec-only fixtures)
1. **Mixed-decimal round trip** — `swapTo`/`creditSwapOut`/`pull` with `token ∈ {GHO, RLUSD, DAI, USDS,
   USDe, cUSD, BOLD}`. Asserts C1+C2 together. Highest yield: **every existing test uses USDC.**
2. `consumed <= true USD value of POOLED_BTC` at `routeSwap` — asserts C3, catches the dead refund path.
3. `premiumEwmaUsd` same order of magnitude as `POOLED_USD_*` — asserts C4.
4. `Σ(QU!D minted for fees) == Σ(usd_owed accrued) × 1e12` — asserts C5, would have caught all three
   §A.57 sites.

# ═══ C4 CONFIRMED (2026-07-30) — full trace, and the BTC side has the MIRROR defect ═══

**CONFIRMED at every step**, each with file:line. The Merton band throttle IS dead on the ETH side.
1. `SwapLib.sol:416` `r.amount = aux._depositVol(...)` → `Aux.sol:704-707` → `:1251-1256`
   `SwapLib.depositBody` returns `sent` **UNSCALED ⇒ raw NATIVE (wei)**. Corroborated in-file by
   `SwapLib.sol:500-503`'s own docblock — *"volatile-in is NATIVE (r.amount from _depositVol; no
   conversion); stable-in is 6-dec USD"* — and by `_refundExcess:508-511`, whose volatile branch passes
   `excess` RAW while the stable branch does `excess * 1e12`.
2. `:442` `retainSkewPremium(core, isBTC, r.amount, skew)` — no conversion between :416 and :442;
   `:1326-1331` `mulDiv(amount, skew, 1e18)` is unit-preserving ⇒ **premium is WEI**.
   `Core.sol:277` `recordSkewPremium(bool, uint premiumUsd)`, docblock `:272`: *"Units = … (6-dec)."*
   ⇒ **1 ETH sell at 1% skew records `1e16` into a 6-dec register = "\$10,000,000,000". 1e12 inflation.**
   🔑 **THE OTHER TWO RETAIN SITES ARE CORRECT** — `:464` is fed by `_consumeVolInput`'s `scaleTo6`
     (`:530`) and `:1025` by `scaleTo6(deposit(...))` (`:1012`). So **:442 is an OUTLIER, not a
     convention** — which is exactly why it reads as fine.
3. `Core.sol:284` `_bumpEwma` (saturates only at uint128 ≈ 3.4e38) → `:215` `premiumEwmaUsd` →
   `VogueLib.sol:333-340` `mulDiv(prem6 * 127, 1e18, pooled6)` — inflated numerator over an HONEST
   6-dec `POOLED_USD_ETH` denominator ⇒ yield inflated ~1.27e14x → `:395-396` unbounded above.
4. `SwapLib.sol:1292-1299` `if (thetaEff >= 1e18) return available;` — **unconditional pass-through.**
5. **No clamp pulls it back — it was DELETED.** `VogueLib.sol:376-381` states verbatim that the
   `theta > 1e18 ? 1e18 : theta` clamp *"is DELETED — it adds no safety"*, justified as "1e18 and 12e18
   are byte-identical no-ops". True for BEHAVIOUR — and precisely why the corruption is **SILENT**: the
   cap was the only thing that would have made the anomaly visible through `Vogue.derivedThetaWad`
   (`Vogue.sol:883`). The one remaining guard is one-sided: `VogueLib.sol:470` `t == 0 ? 1e18 : t`
   FLOORS, never caps. And `derivedThetaWad`'s docblock (`VogueLib.sol:353`) STILL claims
   *"clamped to <=1"* — stale, contradicts the code.

🔴 **NEW — THE BTC SIDE HAS THE MIRROR DEFECT, OPPOSITE SIGN.** Sats are 8-dec, so a 1 BTC sell at 1%
records `1e6` = "\$1.00" against a true ~\$1,000 — a ~1e3 **UNDER**-report ⇒ BTC θ is too SMALL ⇒ the BTC
band **OVER-throttles**. Only ETH goes dead; BTC is needlessly starved. Both are the same root cause.

PERSISTENCE: `FLOW_DECAY` has a 48h half-life, so once blown it stays blown **for weeks**.
BLAST RADIUS: the risk BUDGET, not solvency — the physical `backing − pooled` bound (`clampByBacking`,
`:1335-1336`) still binds. Also corrupts `Core.skewPremiumETH` (`Core.sol:274`) and
`event SkewPremiumRetained`, i.e. the documented "auditable LP P&L" figure.
✅ **MINIMAL FIX**: convert at `SwapLib.sol:441-442` before retaining — **the price is already in hand on
that exact line** (`v4p`/TWAP), and the native→6-dec idiom `mulDiv(x, base, 1e30)` is already used two
frames away at `:969`.

# ═══ C5 CONFIRMED + EXPLAINED (D1) ═══
`Vogue.sol:656-659` mints `LP.usd_owed` (6-dec, `Types.sol:19`) as 18-dec QU!D with **no `* 1e12`**,
while `Vogue.sol:434-440` does. **3 of the 4 sibling sites are correct** (`:439`,
`BtcVaultLib.sol:57`, `:74`); `:658` is the only unscaled one. Reachable: an LP whose USD fees were
deferred to `usd_owed` by a partial exit (`Vogue.sol:543`, `:730`) and who then FULLY exits is
**under-paid 1e12x**. 📌 The comment at `:655` claims *"identical to the prior per-withdraw mint, just
deferred"* — **it is NOT identical; the scale was dropped in the move.** A byte-identical dedup scan
cannot see this: same call, same field, one arithmetic term apart.

# ═══ NEAR-MATCH DEDUP FINDINGS (the exact-match scan could not see these) ═══
**D2 `Vogue._settlePending` (`:424-445`) ≈ `BtcVaultLib.settleBtcLp` (`:41-63`) — MERGEABLE (USD half).**
Same five steps in the same order, both carrying the SAME §A.57 comment. Real divergence is only the tok
leg (ETH compounds into `LP.pooled + lpShares`; BTC accrues to `btcFeesOwedSats`) and how the weight
arrives. 🔑 **Extracting the shared USD-leg half would have made D1/C5 STRUCTURALLY IMPOSSIBLE** — the
strongest argument yet that dedup is bug-prevention, not tidiness.
**D3 `_priceOr` (`:339-340`) is open-coded verbatim at `:441` and `:463`** (both tagged *"inline
(swapToBody stack-tight)"*), while `_priceOr`'s own docblock (`:338`) claims it replaced those copies to
reclaim EIP-170 bytecode. Both copies are in `swapToBody`, whose tail calls `_priceOr` anyway at `:480`
with identical args ⇒ **the price is resolved TWICE per swap in one logical frame.** Verdict:
LOAD-BEARING (no-`via_ir` stack budget) but the docblock is WRONG and the double resolution is waste.
**D4 `_swapInPrep` (~:722-756) ≈ `_swapOutPrep` (~:1005-1029)** — same 8-step skeleton; intentional
inverses. Could share a `_btcRouteBase(...)` builder for the six common assignments. NOTE the asymmetry
that is NOT a mirror: OUT applies `wellSkew`+`retainSkewPremium` (`:1024-1025`), IN applies none
(documented `:740-748`) — but the SELL-IN leg at `:441-442` DOES skew, so "swap-in never skews" is not a
global invariant, and that is exactly the site carrying the C4 bug.

NOT EXAMINED (time-bounded): `VogueLib` band-geometry `:1477-1610`; `wellSkew`/`sellSkew`/`skewWad`
internals; `Vogue._withdraw` vs `unregisterBtcLp` (flagged intentionally distinct at `Vogue.sol:461-467`).

# ═══ §A.15 VERIFIED-OPEN (2026-07-30) — MY "inverted" SUSPICION WAS WRONG ═══
The mint happens strictly AFTER the read, so `total` and `totalSupply()` do NOT move together:
 1. `Basket.sol:241-244` `AUX.deposit(...)` runs FIRST → 2. `ChannelLib.sol:383-385` transfer+`supplySelf`
 ⇒ dollars IN BACKING → 3. `ChannelLib.sol:400` `refreshAllHoldingsSelf()` ⇒ cache includes D →
 4. `Basket.sol:254` `get_metrics(true)` ⇒ `total` INCLUDES D → 5. `Basket.sol:279-280`
 `bufBps = (total - totalSupply())*10_000/total` with `totalSupply()` still EXCLUDING this mint →
 6. `Basket.sol:344` `_mint(...)` (sole supply-increasing path, `:174-182`).
⇒ gate sees `(T+D−S)/(T+D)` > `(T−S)/T` for any D>0 ⇒ **a deposit MONOTONICALLY RAISES ITS OWN `bufBps`**
  and can lift itself across the 150/300/500bps tiers (`Basket.sol:281-284`). §A.15 STANDS AS WRITTEN.
📌 Cleanest evidence: the PROTOCOL-mint headroom check (`Basket.sol:206-217`) reads the same metrics but
  has NO preceding deposit ⇒ NOT self-inflated. Only the depositor path is.

# ═══ NEAR-MATCH DEDUP — Aux/Basket/BasketLib/ChannelLib (13 findings) ═══
**MERGEABLE:** (1) Aave supply leg duplicated INSIDE `supplyBody` — `ChannelLib.sol:205-208` vs
`:236-240`; `rid` sources provably equal (`Aux.sol:1211-1214`). Branch load-bearing, body a dup.
(4) 🔑 **BIGGEST: `_valueStable` (`BasketLib.sol:243-297`) vs `_illiquidLoss` (`:752-806`)** — same
`getVaults` loop, same `aaveSpoke` sentinel, same `try balanceOf → if(sh==0) continue → try
convertToAssets → catch` ladder, same 18-dec tail, same `stables.length-1 // skip BOLD` header. Differs
ONLY in accumulator. `_illiquidLoss` also re-derives the reserve id inline (`:766-771`) instead of
`aux.reserveIdOf` (`Aux.sol:1311`) — **5 self-calls where 1 would do.**
(6) hand-rolled `10 ** (18 - dec)` at `BasketLib.sol:290-296` and `:801-804` IS `scaleTokenAmount(...,true)`
(`:393-399`) ⇒ feeds §A.61. (7) `isEthVenue` triple-OR duplicated VERBATIM `:1049-1051` vs `:1093-1095`.
(8) **`SPWithdrawResult` ⊃ `SPState`** (`ChannelLib.sol:64-69` vs `:72-82`) — 4 `new`-prefixed copies,
copied back at `:277-280`; embed `SPState next;`. **This is the ≤1-field-apart case the exact scan missed.**
(10) `get_metrics(true)` (`Aux.sol:540-550`) vs `get_metricsWith` (`:560-566`). (9) `_withdrawAaveUnsafe`
(`Aux.sol:1147-1153`) vs `withdrawAaveLeg` (`:1164-1170`) — inverse maps, stable-keyed generalises (SUSPECTED).
**NEEDS-DECISION:** (3) `supplyBody:199-218` vs `withdrawBody:262-289` — same classifier, but supply
REVERTS where withdraw RETURNS 0 (deliberate fail-soft on drain). (5) third 4626 ladder
`ChannelLib.sol:222-235` (cross-file). (11) `sorSelfFunded` vs `…Reverse` (`Aux.sol:777-785`/`:794-804`).
🔴 **(12) CORRECTNESS:** `initVaultsBody` (`ChannelLib.sol:470-476`) vs `setVaultBody` (`:441-448`) — the
CONSTRUCTOR path OMITS `IERC4626(vault).asset() != stable` (`:441`), the duplicate scan (`:442-443`) and
the `vaults[stable]==0` guard. **Constructor wiring may silently skip the asset-mismatch check. VERIFY.**
📌 (2) `supplyBody`'s 3 branches — only the aave leg is extractable; WETH/BOLD use four incompatible
mechanisms. ⚠️ **Only BOLD TRUSTS the requested amount rather than measuring it; only 2 of 4 refresh the
holdings cache.** (13) stale doc `ChannelLib.sol:316` references a `depositToSP` that no longer exists.
**METHOD:** effect-based searches (call-sequence shapes), each confirmed against a KNOWN instance first.
`_withdrawableOf` checked and ALREADY correctly shared — a negative that validates the search.

