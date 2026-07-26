# Interface dedup + consolidation + security — findings & potential fixes

> **Mode: findings only.** This file RECORDS what to change; it does not change source.
> Verified against `main` @ `025bfe4` (read via `git show main:`), findings-only per the standing
> instruction. Every claim is anchored to a file:line on `main` — re-verify at the mutation site
> before applying (the working tree has WIP on Aux/Core/BtcVaultLib/VogueLib/ChannelLib/DeployL1_s).

## 0. The view/non-view "deliberate" twins are NOT forced — collapse them (user ask)

**Claim under test:** `IAuxTWAP_B` (non-view) vs `IAuxTWAP_BView` (view), and `ILevSyncHookM`'s
non-view `boughtFractionWad`/`reseatEpoch`/`bandSqrtP` vs its view siblings, are *deliberate* and must
stay split.

**Empirical verdict: FALSE. Nothing forces the split. Collapse each to a single `view` interface.**

Evidence on `main`:
- `Aux.getTWAPforAsset(address,uint32)` is **`public view`** (`Aux.sol:625`) — body only calls view
  `SwapLib.twapBody` + `SwapLib.twapResolve`. No state write. (It *used* to lazily reseat the TWAP
  anchor — the twap-anchor-deadlock era — which is why a non-view twin was ever introduced. That write
  is gone; the twin is legacy cruft.)
- Vogue hook impls are all view: `soldFractionWad` `public view` (`Vogue.sol:760`),
  `boughtFractionWad` `public view` (`:769`), `bandSqrtP` `external view` (`:776`), `reseatEpoch` is a
  `public uint64` state var (`:175`) → auto view getter.
- **Self-refuting comment:** `ILevSyncHookM.soldFractionWad` is *already declared `view`*
  (`LevMath.sol:39`) and is *already consumed inside a `try/catch`* (`LevMath.sol:182`). So the
  sibling justification "Non-view (called via CALL under try/catch)" (`LevMath.sol:37`) is false in its
  own file: `try`/`catch` works on `view`/STATICCALL external calls in Solidity 0.8.

**Solidity rule that makes this safe:** a `view` external function is callable from BOTH view and
non-view callers; only the reverse (non-view called from a view function) is a compile error. So a
single `view` declaration is strictly the most flexible — it compiles at every existing call site
(all of which are in non-view manager/library functions) and additionally enables STATICCALL, which a
genuine view impl satisfies.

**Fix:**
1. `BtcLevManager.sol:7-8` — delete `IAuxTWAP_B` (non-view); keep only the `view` one, rename to
   `IAuxTwapView`. Update its call sites to the view name.
2. `libraries/LevMath.sol:40-42` — mark `boughtFractionWad`/`reseatEpoch`/`bandSqrtP` **`view`**
   (match `soldFractionWad` on line 39). Delete the "Non-view … try/catch" comment (`:35-37`).
3. `LevManager.sol:10` (`ISwapAux.getTWAPforAsset` non-view) and `LevMath.sol:14`
   (`IAuxM.getTWAPforAsset` non-view): mark `view`. (Aux is view; the managers' own inline reads are in
   non-view fns, so this only tightens correctly.)
4. Then the whole Aux-TWAP surface has ONE mutability everywhere → folds into the single canonical
   `getTWAPforAsset(address,uint32) view` in `imports/ISwap.sol` (which already declares it view).

_Falsifier checked:_ would `view` break any caller? Only if a caller relied on the non-view twin to
permit a state write — impossible, the impl is view (STATICCALL-safe). Compile-verify after the change.

---

## 1. Interface consolidation map (byte-identical / subset dups → one canonical home)

Recommend a new `src/imports/Interfaces.sol` as the shared home (mirrors the existing
`imports/ILevVenue.sol` convention that already collapsed 3 ERC20 slices into one `IERC20Min`, and
`imports/ISwap.sol` = the canonical Aux swap surface).

### Clean merges (all byte-identical or strict subset — safe mechanical dedup)

| Cluster | Declarations (file:line) | Canonical |
|---|---|---|
| **Aave v4 Hub** `getAssetId(address) view` | `IAaveV4Hub` Aux:43, Vault:53; `IAaveV4HubCL` ChannelLib:49; `IAaveHub` AaveV4Venue:10 | one `IAaveV4Hub` → Interfaces.sol |
| **Aave v4 Spoke** (user-supply reads) | `IAaveV4Spoke` Aux:30 (superset, 5 fn); Vault:44, `IAaveV4SpokeCL` ChannelLib:41, `IAaveV4Spoke_V` VaultLib:11 are strict subsets | one `IAaveV4Spoke` (Aux superset) → Interfaces.sol |
| **weETH rate** `getEETHByWeETH` etc | `IWeETH` Vault:64 (superset: +getWeETHByeETH,unwrap); `IWeEth_L` SwapLib:23, `IWeETH` LevManager:28, `IWeETHM` LevMath:23, `IWeETH_V` VaultLib:18, `IWeETHRate` Rover:22 | one `IWeETH` (3 fn) → Interfaces.sol |
| **ether.fi deposit adapter** | `IDepositAdapter` Vault:60 (superset +weETH()); Rover:21, `IDepositAdapter_V` VaultLib:21, `IDepositAdapterM` LevMath:27 subsets | one `IDepositAdapter` → Interfaces.sol |
| **Morpho flash** `flashLoan(address,uint256,bytes)` | `IMorphoFlash` LevManager:74; `IMorphoFlashB` BtcLevManager:22 (identical) | one `IMorphoFlash` → ILevVenue.sol |
| **Lev venue collateral** `COLLATERAL()` | `ILevVenueColl` LevManager:35; `ILevVenueCollB` BtcLevManager:21 (identical); `ILevVenueVet` LevMath:28 superset (+stable()) | one `ILevVenueColl` → ILevVenue.sol |
| **Chainlink** `IAggregatorV3` | FeeLib:20; SwapLib:30 (identical) | one → Interfaces.sol |
| **WETH9** | `IWETH9` ILevVenue:14 (deposit+withdraw); `IWETH_VG` VogueLib:61 (deposit+ERC20); `IWethDeposit` SwapLib:41 (deposit only, subset) | union `IWETH9` → ILevVenue.sol; delete the other two |
| **EthVenue** (two subset merges) | `IEthVenueCL` ChannelLib:52 ⊂ `IEthVenue` Aux:66; `IEthVenue_VG` VogueLib:54 ⊂ `IEthVenueV` Vogue:22 | fold each subset into its superset |
| **Aux SOR surface** | `IAuxSwap` SOR:47 (3 fn) ⊂ `IAuxSwap` SwapLib:42 (big) | move big one → Interfaces.sol; SOR imports it |

### Keep separate — GENUINE divergence (do NOT merge)

- **`AaveV4Venue.IAaveSpoke`** (AaveV4Venue:13): adds borrow/repay/setUsingAsCollateral and declares
  `getReserveId` **non-view** (vs view elsewhere) — the venue drives an escrow that borrows. Real.
- **`BasketLib.IAaveV4Spoke`** (BasketLib:76): reserve-level reads
  `getReserveSuppliedAssets`/`getReserveTotalDebt` — a different surface. Rename → `IAaveV4SpokeReserves`.
- **`ILevSyncHook` / `ILevSyncHookB`** (LevManager:51 / BtcLevManager:9): different method *names*
  (`syncLev`/`bandEthOf` vs `syncLevBTC`/`bandBtcOf`) — ETH vs BTC bands, not dups. (But their shared
  view fns and `ILevSyncHookM` DO unify on mutability per §0.)
- **`repack` variants** (`IVogueRepack` BasketLib:89 void; `IBtcVault.repack` Aux:56 4-tuple;
  `IVogueRepack2` SwapLib:101 5-tuple; `IV4.repack` SwapLib:1548 7-arg): different selectors/arities.
- The broader `IAux*` per-caller slices (`IAux`, `IAuxOps`, `IAuxDep`, `IAuxFee`, `IAux_VG`, `IAuxM`,
  `IAuxLens`, `IAuxBtc_V`, `IAuxDeposits_V`, `IAuxView_V`, `ISwapAux`) are deliberately-minimized and
  mostly non-overlapping — NOT worth one giant merge. Only clean incremental win: the
  `get_deposits(...) returns(uint[15],uint[15],uint,uint)` read repeated verbatim in ~8 of them → one
  shared `IAuxDeposits` fragment.

### Dead interfaces — declared, never referenced (delete)

| Interface | file:line | Superseded by |
|---|---|---|
| `IAuxView` | Vault.sol:81 | `IAuxView_V` in VaultLib.sol |
| `IRoverAbsorb` | LevManager.sol:24 | `IRoverAbsorbM.absorb` in LevMath.sol |
| `IVaultRover` | LevManager.sol:23 | `IVaultRoverM` in LevMath.sol |
| `IVogueLP` | BasketLib.sol:72 | `lpShares()` never cast through it |

---

## 2. Constant / logic dedup (verified at mutation sites)

Ranked by drift risk. Two prior candidates were found **already consolidated** — see bottom.

| # | Quantity | Occurrences | Safe? | Helper home | Risk if left |
|---|---|---|---|---|---|
| 1 | **QD per-share** `min(par, solvent/mature)` hand-rolled vs canonical `ShareMath.qdShareValue` | hand-rolled `BasketLib.sol:864-865`; canonical `ShareMath.sol:21-27` (already used by swap `SwapLib.sol:544`) | **YES** | route BasketLib:864 through `ShareMath.qdShareValue` | **HIGH** — ShareMath is documented as THE one QU!D valuation; the anti-drain invariant (swap-out ≤ redeem) depends on both quotes agreeing. A drifting copy re-opens the drain vector. Comments at BasketLib:851 + SwapLib:527 explicitly demand identical. |
| 2 | **Skew-premium retain+record** `premium=mulDiv(amt,skew,1e18); amt-=premium; recordSkewPremium(isBTC,premium)` | `SwapLib.sol:426-430, 451-456, 1001-1005` (tail byte-identical; only skew SOURCE differs) | **YES** | private `_applySkewPremium(core,amount,skew,isBTC)` in SwapLib | **HIGH** — withheld premium is retained backing AND the RFQ-drawable audit ledger. A copy dropping `recordSkewPremium` or changing `1e18` silently diverges backing + ledger. |
| 3 | **`TARGET_LTV_CAP_BPS = 7500`** literal ×2 | `LevManager.sol:108` (internal), `BtcLevManager.sol:54` (public); comment BtcLevManager:53 "Tunable. (ETH parity.)" | **PARTIAL** (judgment: is parity a hard invariant?) | shared const in `LevMath` if hard-invariant; else document | **MED-HIGH** — safety LTV cap (~11% under 86% LLTV). Tune one book, forget the other → silent divergence, no compiler/test signal. |
| 4 | **Zero-floored free balance** `pooled>lev ? pooled-lev : 0` (withdraw cap excl. levered slice) | ETH `Vogue.sol:326,363,446`, `VogueLib.sol:448,476`; BTC `BtcVaultLib.sol:588`, `Vault.sol:631`; agg variant `VogueLib.sol:409`. View wrappers exist: `Vogue.bandEthOf:188`, `Vault.bandBtcOf:629` | **PARTIAL** (split ETH/BTC + contract/lib storage plumbing) | pure `freeBal(pooled,lev)` in shared math lib for the arithmetic core | **MED** — real safety quantity (blocks draining the unwind-only levered slice). 7 open copies; a `>` vs `>=` or dropped floor makes the slice drainable on that path. |
| 5 | **`_refreshBookmarks` fee-bookmark replica** (trading gross weight + venue-yield plain weight) | `Vogue.sol:321-328` vs `VogueLib.sol:440-450` (`_refreshBookmarksLib`); comment VogueLib:437 "Byte-identical … replica" | **PARTIAL** (EIP-170 split; Vogue copy has many callers) | Vogue forwards to `VogueLib._refreshBookmarksLib` | **MED** — fee-accounting weighting; two hand-kept copies = classic drift trap. |
| 6 | **Depeg gross-up** `sev>0&&sev<10000 ? x*10000/(10000-sev)` | `FeeLib.sol:197-200, 212-215, 233-236` (3× byte-identical, same file) | **YES** | private `_grossUpForDepeg(...)` in FeeLib | **MED-LOW** — the `sev<10000` div-by-zero guard is what must not drift. |
| 7 | **`resolveV4Price` fallback** `v4p!=0 ? v4p : getTWAPforAsset(asset,1800)` | `SwapLib.sol:425,451,472,740,994` (5×; embeds magic `1800`) | **YES** | private `_resolveV4Price(v4p,aux,asset)` in SwapLib | **LOW** — cosmetic; risk is the 30-min window literal drifting. |

**Already consolidated (no action — prior premises were stale):**
- `committedUsd18()` exists at `Core.sol:100-102` and is **debt-adjusted equity**
  (`_bandEquityUsd18(false)+_bandEquityUsd18(true)`), NOT a raw `(POOLED_ETH+POOLED_BTC)*1e12` sum.
  Already called from BasketLib:867/931/936/939, BtcVaultLib:113, VogueLib:339, SwapLib:392, Core:990.
  The remaining `POOLED_USD_BTC()*1e12` sites are legit single-side conversions, not the committed sum.
- `addLiq`/`_addLiqChannel` surplus sizing already centralized in `SwapLib.sizeBySurplus:1197` +
  `SwapLib.clampByBacking:1243` + `SwapLib.btcCapClamp:1180`; only thin orchestration wrappers differ.

**Intentional divergence — do NOT merge:** mint-par vs redeem-basket-share (senior/junior asymmetry,
`Basket.sol:326-329,401-403` + ShareMath header). The `_refreshBookmarks`/`addLiq` replicas' *duplication*
is deliberate (EIP-170 bytecode split) even though #5's arithmetic is still a drift surface worth a delegation.

## 3. Dead code / unused symbols (verified whole-tree; vendored v3 excluded)

**Confirmed dead — safe to delete:**

| symbol | file:line | kind | evidence |
|---|---|---|---|
| `IAuxView` | Vault.sol:81 | interface | 0 instantiations; live one is `IAuxView_V` in VaultLib |
| `IRoverAbsorb` | LevManager.sol:24 | interface | 0 instantiations; live is `IRoverAbsorbM` (LevMath:438,473) |
| `IVaultRover` | LevManager.sol:23 | interface | 0 instantiations; live is `IVaultRoverM` (LevMath:435,470) |
| `IVogueLP` | BasketLib.sol:72 | interface | decl only |
| `VENUE_GALAXY` | Vogue.sol:71 | const uint8=3 | never read |
| `gauntletWeth` | DeployL1_s.sol:75 | const address | never read (sibling `gauntletUsdc` IS used :344) |
| `hash160` | BitcoinTx.sol:291 | internal pure fn | no callers (⚠ generic BTC lib surface — may be intentional) |
| `countEpochCumulativeWork` | spv/libs/TargetsHelper.sol:114 | internal pure fn | no callers (⚠ SPV lib surface) |
| `targetToBits` | spv/libs/TargetsHelper.sol:159 | internal pure fn | no callers (inverse `bitsToTarget` IS used) |

**Dead in-tree but ABI-exposed views (⚠ confirm no keeper/UI consumer before deleting):**
`deliverableDollars`/`totalDeliverableDollars` — `LevManager.sol:368,382` + `BtcLevManager.sol:256,270`.
No in-tree callers; NatSpec claims they feed `sizeBySurplus` but `SwapLib.sizeBySurplus:1197` never
calls them. Their private helper `_deliverableDollarsAt` is reachable only from these dead views →
removing all four also orphans it. **Do NOT touch `LevMath.deliverableDollars` (LevMath:84)** — it's the
genuinely-used core math (LevManager:378, BtcLevManager:266). Matches `BUILD-QUEUE-AND-107` finding #20.

**Rejected (NOT dead — earlier candidates were wrong):**
- `Basket.target` — auto-getter READ externally via `IQuidTarget(quid).target()` at `ChannelLib.sol:404`.
  Removing it breaks ChannelLib. (So finding #18's "delete target" needs care — it's a live selector.)
- `Basket._deployed` — written :147, read :232 & :457.
- `soldFractionActive`, `_pathEncodings`, `ID`, `ID_BTC`, `K_btc`, `tranche`, `perMonth`, `_lpIdx` — all read.

**Already gone from main (0 hits — stale backlog items, drop from AUDIT-TODO cleanup list):**
`Aux.ghoBalance()`, `Aux.pathCount()`, `Aux.getPathEncoded()`, `Aux.SOURCE_MIN_OUT_BPS`, `Aux.BPS_DENOM`,
`Vogue.RAY`, `BTCChannels.SELF_REFUND_MIN_SECS`, `BTCChannels.RefundTimelockNotElapsed`, `lamboHeld`, `ICourt`.

**Systematic coverage:** every `error` referenced ≥2×, every `event` emitted ≥1×, 177 consts/immutables
checked (only the 2 above dead), 182 internal fns checked (only the 3 above dead), all state vars read.

## 4. Security findings

### HIGH-1 — `settleSwapIn` can drain the whole `POOLED_USD_BTC`; per-call cap was removed and the attestation gate is inert (escalates §A#22, which is rated LOW/deferred)

**Files:** `BTCChannels.sol:1011-1063` (`settleSwapIn`), gate `:1020` `if (openChannelsOf[msg.sender]==0) revert NotChannelHop`; `_requireAttested` `:495-498`; `imports/SwapLib.sol:701-702` ("the old **BtcInflowCap is gone**") + `:728` (`rp.pooled = POOLED_USD_BTC()*1e10` — whole pool is the only bound). Stale invariant claims still asserting a cap: `BTCChannels.sol:256`, `AttestedHopRegistry.sol:30-38`.

**VERIFIED against main** (spot-checked, not taken on faith):
- `_requireAttested` is a **no-op when `hopRegistry==address(0)`** (`:497` `if (reg != address(0)) require(...)`); `hopRegistry` is unset by default, one-way pin (`:491`). So the on-chain attestation gate is **not live today**.
- Becoming a hop = open ONE SPV-proven channel → `openChannelsOf[msg.sender] += 1` (`:671`). That single (possibly tiny) BTC lock is the entire authority to call `settleSwapIn`.
- Payout bounded only by `POOLED_USD_BTC` curve depth; the `sats` "received over Lightning" is a pure attestation (no BTC arrives) → `netDeliveredBtc` books a phantom inflow while real basket stablecoin is delivered to `seller`.

**Exploit:** self-delegate + open one small channel → call `settleSwapIn(seller=self, sats=huge, token=basket stable, requireFull=false)` repeatedly → drain the shared BTC-USD pool, collateralized only by the attacker's tiny locked channel.

**Fix (money-path fork — SURFACE, don't silently pick):** either (a) re-introduce a per-hop inflow cap in `creditSwapInBody`/`settleSwapIn` bounded by `msg.sender`'s own summed `channel.amountSats` (the §22 "cap per-hop draw" fix — but note the `BtcInflowCap` it assumed existed is gone), OR (b) accept "any attested hop is fully trusted with the whole pool" as the trust model and make that safe by pinning `hopRegistry` live BEFORE any real BTC LP funds + blocking renounce until pinned. Also fix the two stale `BtcInflowCap` comments. **Decision needed:** is full-pool-trust-per-attested-hop the intended model, or is a per-hop cap required?

_Falsifier that would downgrade to defence-in-depth-only:_ `hopRegistry` pinned live pre-mainnet AND trust model accepts full-pool trust per attested SGX hop. Live-today path is unguarded beyond "lock one small channel."

### MED-2 — Oracle deviation guard is opt-in per asset; unset WETH/WBTC feed ⇒ every `getTWAPforAsset` consumer trusts raw internal V4 TWAP with no Chainlink anchor

**Files:** `Aux.sol:211-216` (`assetPriceFeed`, pin-once owner-only `setAssetFeed`), `Aux.sol:625-633` (`getTWAPforAsset`→`twapResolve`), `SwapLib.sol:172-190` (`twapResolve` returns `(price,false)` unchanged when `feed==0`).

`twapResolve` short-circuits to the raw internal TWAP whenever `assetPriceFeed[asset]==0` (`SwapLib.sol:174`). All lev valuation reads `AUX.getTWAPforAsset(WETH,…)` (LevManager:317,346,549,687,806,834,898) and BTC swap-in prices off `getTWAPforAsset(WBTC,…)` (SwapLib:740). If the WETH/WBTC feeds are never set (or finalize/renounce precedes `setAssetFeed`, which is pin-once), the documented 5% Chainlink cross-check never engages, and a multi-block V4 TWAP grind (which moves spot AND its own TWAP together — a spot-vs-own-TWAP guard can't see it, per `Aux.sol:205-208`) mis-values collateral/debt for opens, de-levers, and swap-in payouts.

**Fix:** make the anchor mandatory for price-critical assets — revert `getTWAPforAsset(WETH/WBTC,…)` if the feed is unset, or block finalize/renounce until both feeds are pinned.
_Falsifier:_ if `DeployL1_s`/`DeployLib` always `setAssetFeed(WETH)`+`setAssetFeed(WBTC)` before renounce, this is only a deploy-ordering caveat. Deploy ordering NOT yet traced — verify it.

### LOW-3 — `Vogue._venueBalance` try/catch fallback biases plain-venue backing UPWARD (unsafe direction) if the lev net-equity view reverts

**File:** `Vogue.sol:705-712`. Intent `plainVenueETH = vogueETH − levNetEquity`. On a revert of `ILevEquityV(lm).totalNetEquityEth()` the `catch` leaves `total` at full `vogueETH` (incl. levered net-equity backed externally on Euler/Morpho). That inflated total feeds `_syncYield` + the withdraw `vaultShare` denominator (`Vogue.sol:509-512`) → can over-deliver ETH to an exiting plain LP or book a lev open/close as fake venue yield. Requires the `view` to revert while `lm!=0` (unlikely) but the error direction is the unsafe one.
**Fix:** on catch, revert rather than silently over-count (or only skip the subtraction if provably 0).
_Falsifier:_ if `totalNetEquityEth()` is a non-revertable pure summation, the catch is dead-defense.

### INFORMATIONAL
- Stale `BtcInflowCap` comments (`BTCChannels.sol:256`, `AttestedHopRegistry.sol` docblock) assert a per-call bound that `SwapLib.sol:702` removed — sync them (part of HIGH-1).
- `Basket.onlyUs` (`Basket.sol:45-51`) carries a design TODO but the actual gate `auth()` (`:52-59`) is correct/closed — reads as WIP, not a bug.

### Checked and NOT issues (falsifiers held)
- **`rebalanceMany`/`cascadeDelever` batch DoS:** each element runs `try this.rebalanceOne/deleverOne(){}catch{}` (LevManager:620,732) — one reverting LP is skipped, not the batch.
- **Lev flash-callback reentrancy:** `onMorphoFlashLoan` gated `msg.sender==flashProvider` (LevManager:848); `rebalanceOne`/`deleverOne` gated `==this||lp`; token legs use balance deltas; `Vogue._withdraw` debits `pooled`/`lpShares` before ETH leaves (CEI, :497).
- **First-deposit 4626 inflation:** Vogue mints `pooled`/`lpShares` 1:1 with ETH `amount` (`_depositImpl`, :674-688), not via `convertToShares`; ratio views are read-only. `Vault.venuePosition` uses `convertToAssets` only for a health read.
- **weETH LST rate:** `getEETHByWeETH` is a protocol staking rate (not AMM), not flash-manipulable; `Rover._nearFair` also rejects a pool spot deviating >50bps.

---

## Verification / next steps
- **Build gate:** re-run `forge build` after any interface merge — the compiler is the proof that a `view`-unification (§0) and each canonical-home swap (§1) compiled at every call site. A `view`-tightening that broke a caller would fail to compile.
- **Un-traced residuals:** (a) `DeployL1_s`/`DeployLib` feed-set-before-renounce ordering (MED-2 live status); (b) whether `settleSwapIn` full-pool-trust is the intended model (HIGH-1 fork) — needs the user's call; (c) confirm no keeper/UI consumer of the ABI-exposed `deliverableDollars` views before deleting (§3).
