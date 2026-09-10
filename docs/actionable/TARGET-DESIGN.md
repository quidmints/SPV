# TARGET DESIGN — where the swap/LP/lever system is going, and what comes out to get there

> **Written 2026-09-09 in one long owner session. This file exists so the design survives a context
> compaction.** It is SELF-CONTAINED on purpose: every premise is restated rather than cited, because
> the reader may have none of the conversation that produced it.
>
> ⛔ **READ §0 BEFORE ACTING ON ANYTHING HERE.** Roughly a third of this is MEASURED and a third is
> REASONED, and the session that wrote it produced **five retracted proposals in two hours**. The
> split is marked at every claim. Do not promote a 🧠 to a ✅ without doing the work.

---

## §0 — CONFIDENCE KEY, AND THE RETRACTION RECORD

| mark | meaning |
|---|---|
| ✅ | measured, or read directly out of the code, with the file:symbol given |
| 🧠 | REASONED in-session, never measured. **Treat as a hypothesis.** |
| ⏸️ | blocked on a named check or an owner ruling |

**Proposals THIS SESSION made and then retracted, so nobody re-walks them:**
1. *"Bound the skew result"* — a clamp. The owner's own §UNIT-A-ROOT already has the root fix.
2. *"Hedge every swap atomically in the market"* — we quote at MID and would hedge at the ASK, so
   every round trip loses the spread. Dead.
3. *"A drain is exactly funded, so buy back"* — only at the instant of the drain. Price moves; the
   dollars are nominal. Dead.
4. *"Fund the lever internally from the basket float"* — **toxic**: circular backing of a dollar
   claim with volatile exposure, removes the exogenous depth/rate signal, and the "non-callable
   float" premise fails precisely under the stress it is meant to survive. Dead.
5. *"The signed flow measure decides hedge-now-vs-wait"* — still spot thinking. Under balance-sheet
   absorption there is no spread to save by waiting, so deferral is a GAS decision, not a risk one.

---

## §1 — THE INVARIANT EVERYTHING SERVES (owner, verbatim)

> **CONSERVATION PRINCIPLE — LPs preserve UPSIDE; basket depositors preserve DOLLAR VALUE.**

Two constituencies, two different things preserved, from one balance sheet. Every mechanism below
exists to hold both at once. Supporting requirements the owner stated in the same session:

- an imbalance in pool quantities must **not deter swappers**;
- charge **fairly and less arbitrarily than AMM slippage**, while **maximising LP value capture**;
- **no LVR, no MEV**;
- **no state of the pool may make Uniswap more attractive** (given we have inventory);
- **liquidation prevented** — by RESPONSIVENESS (the owner clarified this is what was meant, not an
  exotic no-margin instrument);
- **the dollar pool must cover demand for BOTH ETH and BTC** — ETH in ether.fi, BTC on Lightning;
- **deferral is OPT-IN**; being **paid in volatile is an allowed election**, mirrored for a volatile LP.

---

## §2 — WHAT THE SYSTEM ALREADY IS ✅ (the premises, all read from code)

- **Settlement is at ORACLE, with NO price impact.** `Core.sol:1022` — *"§V4-CUT — SETTLE AT ORACLE,
  BOUNDED BY INVENTORY. No unlock, no callback, no curve traversal, no price discovery. **ONE price
  for the whole size.**"* ⇒ a CFMM's slippage is an artifact of its curve; **we do not have it.**
- **There is NO second leg and NO paired-reserve invariant.** `skewWad`'s `q` is
  `(target − inv)/target` where `target = flowEwmaUsd + redeemEwmaUsd` — inventory against **expected
  flow**, never volatile-vs-dollars. There is nothing to be "50:50".
- **A short range still serves**: partial fill + refund, **or** load-balance through 1inch at the
  swapper's election (`loadBalance` is a real field, carried into `RouteParams` and signed into
  `OorIntent`).
- **Redeem pays dollars only** — `Aux.sol:1154`: *"dollars (`Quid.unwindForRedeem`) — no volatile leg,
  no LP ETH sold."* `deliverVolatile` has exactly ONE caller, `Core:1227`, on the SWAP path.
  Under stable illiquidity redeem **defers**. ⚠️ The owner wants that deferral to become **opt-in**,
  with pay-in-volatile as the alternative election.
- **ONE pooled venue position, not per-LP** (§POOL-VENUE). `repayPool` is O(1) and *"burning pool
  shares lowers EVERY LP's debt pro-rata by construction"*.
- **Two ranges, one basket.** §E53: both draw on one backing, `committedUsd18() <= haircutTvl`, and
  *"neither skew can see the other — and ETH/BTC correlate hardest on exactly the days that matter."*
- **Settlement latency is asymmetric**: `ETH_CONF_FRAC_WAD` ≈ 12s vs `CONF_FRAC_WAD` ≈ 1hr (~300×).
- **The lever borrows STABLES, never the volatile**, and posts the volatile as collateral
  (`LevManager._leverUpBuy:952`: `venue.borrow(...)` → `stableToColl` → `venue.supply`). Deployed:
  BTC = `AaveV3Venue`, WBTC collateral, **USDC** debt, LT 7800, allowlist of ONE;
  ETH = two `MorphoEscrowVenue` (RLUSD, PYUSD) + one `AaveV3Venue` (USDT, LT 7300), all weETH.

---

## §3 — THE MECHANISM 🧠 — the balance sheet absorbs, nothing goes to market

**The direction is counter-intuitive and is the thing to understand first: BORROW fires when we
RECEIVE volatile; REPAY fires when we LOSE it.**

| swap direction | what happens to us | balance-sheet action | LTV | capacity limit |
|---|---|---|---|---|
| **drain** — swapper takes volatile | volatile ↓ by ΔE, dollars ↑ by ΔE·px | **REPAY** debt with the proceeds | **falls** (safer) | none — self-funding |
| **sell-in** — swapper gives volatile | volatile ↑ by ΔE, dollars ↓ by ΔE·px | supply as collateral, **BORROW** | **rises** | **HARD** — see below |

**Why the drain restores LP upside exactly.** Lever net long is `C − D/px`. Repaying `ΔE·px`:
```
C − (D − ΔE·px)/px  =  (C − D/px) + ΔE
```
Delta restored **exactly, with no market trade**. And it is not extra directional risk: holding `E₀`
unlevered gives P&L `E₀·Δpx`; holding `E₁` spot plus `(E₀−E₁)` levered against dollar-fixed debt gives
delta `E₀`, so P&L is **identical**. The debt reconstructs the position, it does not amplify it.

**Why the sell-in is the constrained side.** Borrowing `ΔE·px` against `ΔE` of new collateral drives
LTV toward 100%. At an LTV cap `L` a sell-in only re-dollarises `L·ΔE·px`, so:
> 🔑 **`(1 − L)` of every sell-in is volatile that permanently backs a dollar claim.** A sell-in
> **structurally cannot be fully re-dollarised**, and that residual is the depeg exposure.

⇒ **THAT is what "target" means now: maximum volatile inventory = what borrow capacity plus the
non-callable float can re-dollarise.** A BALANCE-SHEET number. Not a demand forecast.

**Delivery needs no flash** 🧠. The flash exists to dissolve a circular ordering (*"repay FIRST ⇒ the
withdraw is ALWAYS health-safe"*, `LevMath:382`; §E357 forbids the direct path). **The buyer's dollars
arrive before the withdrawal**, so the order is linear: `receive D → repay D → LTV falls → withdraw →
convert → deliver`. Repaying `D` frees up to `D/L` of collateral, and `L < 1`, so withdrawing only
`D`-worth **lowers** LTV. No moment is worse than the start.

**LP exit is a SHARE REDEMPTION, not an unwind** 🧠 — there is one position, so there are no per-LP
slices. Pay the exiting LP from basket dollars at oracle; ownership moves, the position does not.
Bounded by the same re-dollarisation capacity as a sell-in.

---

## §4 — THE CHARGE 🧠 — a flat fee, plus a sell-in capacity term

Only ONE of today's skew terms defends itself, and it is the smallest:
- **Adverse selection** (`_maxWellSkew` = σ²·T_settle/8). We quote a fixed price that can sit up to
  `TWAP_MAX_DEVIATION_BPS = 500` from Chainlink; anyone with fresher information picks us off. **You
  cannot HAVE zero LVR while quoting a stale price — you can only CHARGE for it.** The spread is the
  mechanism by which "no LVR" is true rather than aspirational.
- **Gas.**

⭐ **AND σ² SHOULD STOP BEING MEASURED ON-CHAIN.** The term is orders of magnitude below any sane
floor — ETH **0.000233 bps at 70% vol** (measured, in-tree), **0.0019 at 200%**; BTC ~300× that
(~0.07 / ~0.57 bps), and even at ~400% vol BTC is ~2.3 bps against a 4.2 bps floor. ⇒ σ² becomes a
**calibration input used once, offline, with a written derivation** — not a runtime measurement.
🔑 **AND THAT IS WHAT KILLS BOTH MEASURED MANIPULATION VECTORS**: *patience* (let the 48h EWMA decay,
then drain a small target) and *clock-stretching* (space slices 4h → σ² 24× down → charge 93.3% down)
both work because the charge depends on **starvable measured state**. **A constant cannot be starved**
— unconstructible, not defended against.

**What survives:** `flat fee (gas + adverse selection)` **+** `a sell-in term rising as
re-dollarisation capacity is consumed`.
⇒ **The asymmetry INVERTS from today**: today the DRAIN carries the pole and the sell leg is linear
(§E68b). Under this design the **drain is flat and cheap** and the **sell-in is the constrained side**.
So `sellSkew`'s shape survives with a balance-sheet target; the drain kernel is what dies.

**Bounds on the fee, both market facts, not policy:**
- **floor** = gas + adverse selection (else swaps are negative);
- **ceiling** = the competitor's all-in cost (else we lose the flow).
⚠️ **DO NOT SWEEP THE CEILING — MEASURE IT** (owner). And the right measurement is not a single
"all-in cost": v3/v4 liquidity is not uniform, so the competitor curve has a **kink** — fee-only
inside the active tick, then it steps. What matters is (a) where the active tick sits **relative to
the Chainlink price we settle at**, (b) how much notional fits before the kink, (c) the realised
curve beyond it. `SkewVsUniswapV3.t.sol` already wires the real `QuoterV2` (`0x61fFE014…`).

**LP economics ✅ (arithmetic, this session):** volume needed to pay 10% APY — at 0.042% (today's
floor) **0.65× TVL/day**; at 0.005% **5.48× TVL/day**, which no pool achieves. At 1× TVL/day, 0.042%
pays **15.33%** and 0.005% pays **1.83%**. ⇒ the flat floor ALONE clears the 10% benchmark; the
scarcity premium is not needed for LP revenue either. **And the real edge is that we keep more of the
same fees: a Uniswap LP's 10% is gross MINUS LVR; ours is gross ≈ net.**

---

## §5 — REMOVALS

### 5a. Safe now ✅ — no replacement needed, zero/​view-only consumers
| what | evidence |
|---|---|
| `refillNeeded`, `proRataShortfall` (+ `RefillTriggerAndProRata.t.sol`) | 0 src callers; `internal` ⇒ 0 bytes, but dead source |
| `swapOutDeliverUnlevered` + `…Body` (~850 B) | 0 Solidity callers, 0 tests; held open only by an unwritten §M.1 fork test |
| ~~`retainedEthPremium`~~ **RETRACTED 2026-09-10** | 🔴 *"a counter nothing reads"* was measured against `evm/src` ONLY and is FALSE about the tests. `LevYbReal.t.sol:577` pins `POOLED + retainedEthPremium == rangeETH + levBuf` — the CONSERVATION statement of §1. Now in `orphans-allow.txt` CLASS 4 with that reason. |
| `_applySkew`, `OracleLib.curvePriceWad` | booked unwired |
| `openLevCount`, `openLpAt` | the ONLY on-chain readers of `_openLps`, and both are `external view` |
| tick/curve tombstones | ~185 `tick` matches in `evm/src`, **every one a comment** |

### 5b. Gated on the replacement ⏸️ — these have live callers
- **The drain kernel**: the `kMinusQ1`/`qBar` log integral (`SwapLib:1602–1625`), `KAPPA_WAD` (9 refs,
  **0 test refs**), `SKEW_UNFILLABLE` (12), `_boundToFullHaircut` (11), the `type(uint).max` sentinel,
  both producers' decline paths, `lnWad` off the money path (3). Replace with the **midpoint
  `(q₀+q₁)/2`** the sell leg already uses — no new import, no Δ=0 branch.
- **Variance**: `realizedVarianceWad` (7), `ringVariance` (2), `anchorVarianceWad` (2),
  `_sampleAnchorVariance` (2), `UNKNOWN_VARIANCE_SKEW` (3) + the ring's variance role.
- **Forecast/EWMA**: `flowEwmaUsd` (3), `redeemEwmaUsd` (3), `FLOW_DECAY` (3), `skewTargetUsd` (4),
  `Flow{vol,ts}` / `_decayed`.
- **`DEPLETION_RATE_WAD`** — priced "inventory that was there and left"; that is carry, not a toll.
- **Flash**: `IMorphoFlash`, `flashProvider` + its `address(0)` disable switch, `onMorphoFlashLoan`,
  `_deleverFlash`, `flashDeleverWbtcSettle`, `_extractSettle` mode 2. ⚠️ **Venue migration still needs
  a flash** — deferred with the allocator. Removing this also dissolves the ETH/BTC asymmetry where
  `BtcLevManager.init` refuses a zero flash and `LevManager.init` accepts it.
- **The per-LP position model** 🧠 (the largest cut). ⛔ **AND IT IS A *REPLACE*, NOT A *REMOVE* —
  the same shape as the flash.** `cascadeDelever` + the no-trade band ARE the liquidation defence
  (*"must keep the AGGREGATE away from the liquidation threshold, because Morpho no longer does it
  for us"*), so deleting the per-LP walk before a POOLED rebalance exists removes the defence rather
  than the machinery. The flat fee had a two-line replacement; this does not.
  ✅ **The removable subset TODAY is the enrolment book** — `_openLps`, `_lpIdx`, `openLevCount`,
  `openLpAt` — because `deleverBook`'s own docblock records it as *"the LAST walk of `_openLps` on a
  state-changing path … the book is read only to find the venue"*, and `poolVenue` already holds the
  venue. Everything else in this list waits for the pooled target: `Types.Pos{ilBasisPx, entryEquity, syncKeyPx}`,
  `_openLps`/`_lpIdx`, `RangeLib.openPos`/`untrackOpen`/`reanchorIfReseated`, `debtUnits`/`collUnits`
  + `_mintUnits`/`_burnUnits`/`_unitSlice`, `_batch`/`cascadeDelever`/`rebalanceMany`/`rebalanceOne`,
  `debtDeltaToTarget(lp)`/`_targetInputs(lp)`/`_bandFor(lp)`/`deleverRepayUsd(lp)`,
  `_repayCreditingLp`/`repayFor`, `closeLev`.
  ⇒ **per-LP attribution falls out of the SHARE PRICE**, which already exists (`convertToAssets`): an
  LP entering later buys in at the prevailing price and their IL is that price's movement. No
  `ilBasisPx` needed.
  ⇒ **DISSOLVES, rather than solves:** the 4,801 bps cross-subsidy · §LEVER-UP-SUPPLY-ON-DEMAND and
  the GATE 2 fairness ruling · §SINGLE-LP-IS-THE-LEDGER · §IL-BASIS-√-BLEND (no basis to blend) ·
  §C19/§E339's reseat-reanchor hazard.
- **Rust (`quid-ln/quid-bridge`)**: whatever builds per-LP `lps[]` arrays for
  `cascadeDelever`/`rebalanceMany`, and any variance/EWMA fetch. **Not yet enumerated.**

### 5c. Known defects to fix, not remove
- **`MIN_SWAP_SKEW_WAD` never reaches the swap-IN rail** — `creditSwapInBody` / `_swapInSettle` have
  ZERO live refs to it (both hits are comments); its docblock says *"the refill settles at the honest
  fillPrice"*. Against the owner's *"all swaps even balance restoring must pay at least the minimum."*
- **The de-lever REFUSES instead of degrading** — `sellColl`'s oracle floor reverts when the sale
  cannot cover, so the safety mechanism does **nothing** in exactly the market that triggers it.
- **`TARGET_LTV_CAP_BPS = 7500` vs weETH LT `7300`** — the target cap sits ABOVE one deployed venue's
  liquidation threshold. Either `_bandBps` clamps it per-venue (untraced) or the target is
  liquidatable before any market move.
- **`_retarget` never overwrites w0 `executor` / w3 `srcReceiver`**, and `swapMin = minLeg == 0 ? 1`
  with `_selfServableQuote` stable-only ⇒ **1 wei router bound on volatile legs**. Single-leg BTC/ETH
  paths are safe (aggregate `minOut` is oracle-floored); **multi-leg `convertShortfall` is not**, and
  **GHO has no `_hubRowOf` row**, so it is that leg. Byte-blocked: LevMath has 71 bytes.
- **93.6% duplicate bodies**: `LevManager:627 deleverRepayUsd` ↔ `LevBase:146 debtDeltaToTarget` —
  the drift hazard `_targetInputs`' own docblock names.

---

## §6 — WHAT GATES ALL OF §3/§4/§5b
### ✅ CHECK 1 IS RESOLVED — **THE DRAIN'S DOLLARS ARE THE LP'S, AND THEY ARE CLAIMABLE** (traced 2026-09-10)
The register that answers it is not `usd_owed` (that really is the fee leg). It is the PAIR
`POOLED_USD` vs `basketUsd`, read together by `Quid._usdLegs6()`:
- `Core._poolUsdInRange(usdAmount, mint, basketLeg)` does `POOLED_USD += usdAmount` ALWAYS, and
  `basketUsd += usdAmount` **only when `basketLeg`**. `basketUsd` is therefore the BASKET's own
  contribution, and the difference is everything the basket did NOT put there.
- **A SWAP PASSES `basketLeg = false`** (`Core:786` → `:902`; only `modLP` at `:666` passes `true`).
  ⇒ a swapper's dollars raise `POOLED_USD` and leave `basketUsd` untouched.
- `Quid._rangeIncrement6()` names it outright: *"the range's **LP-OWNED USD leg** — everything in the
  curve's USD mirror **beyond what the BASKET put there**"*, `usd6 > base6 ? usd6 - base6 : 0`.
⇒ **IT REACHES LPs TWO WAYS.** `_pricingBacking` adds `(usd6 − base6)` to the share-price base,
valued AT THE ORACLE and **SIGNED** — a range that bought ETH with basket dollars reads negative and
correctly reduces the claim, *"flooring at zero would gift the LP the basket's capital"*. And
`_payUsdLeg` pays the pro-rata slice in QU!D on exit.
📌 **CONSEQUENCE: §3 HAS FUEL.** A drain leaves `ΔE·px` of LP-OWNED dollars, which is exactly what
repays debt to restore that LP's delta. The mechanism's premise holds.
📌 **AND IT RAISES `_payUsdLeg`'s `ZeroTwap` REVERT (landed on main) FROM HOUSEKEEPING TO LOAD-BEARING**
— it guards the payout of the LP's OWN dollars, not an incidental fee.
⛔ **A CORRECTION THIS RETIRES:** an earlier reading in this session said the LP's claim is
ETH-denominated and excludes `POOLED_USD`. **False** — `_pricingBacking` folds the increment in at the
oracle. **VALUE is preserved by settlement; what is not preserved without the lever is UPSIDE**, and
those two are the distinction the whole design turns on.

### ⏸️ THE REMAINING CHECKS
2. **Does `immatureSupply()` have a real maturity PROFILE**, or is it a headline number? Redemption is
   marked `min($1, solvent/matureSupply)`, so immature supply is excluded from the claim — but a
   schedule that can mature quickly is not a fundable base.
3. **`borrowRateRay(extraBorrow)` at our notional** — it has **zero callers** and has never been
   called. If carry is expensive at our size, "transient is free" fails.
4. **Are `haircutTvl` + the tranches a real attachment point**, or bookkeeping?

📌 **Also unresolved and load-bearing:** what `L` actually is per venue, because `(1 − L)` is the
residual depeg exposure on **every** sell-in and it sizes the whole risk.

---

## §6b — DEBTS THE REMOVALS CREATED (2026-09-10, all measured)

These are **not** discovered problems — they are the price of cuts already made, recorded so nothing
depends on my commit messages being read.

| # | debt | evidence |
|---|---|---|
| 1 | **THE KEEPER HAS NO POOL-LEVEL DE-LEVER.** ✅ `LevManager.deleverToVault` is the pooled crash response (`repayPool` + `withdrawPool` + sell, O(1)) but it is RANGE-gated: `LevManager.sol:584` `if (msg.sender != RANGE && msg.sender != address(this)) revert NotGov()`. Only a redeem/swap-out settle can reach it. My own commit `acf8bb50` said *"the keeper's de-lever is now the pooled `deleverToVault`"* — **that is wrong as written**; the keeper cannot call it. | `deleverOne` is LP-only (`msg.sender != lp` → `Auth()`), so the keeper's surviving actuator is the permissionless per-LP `rebalance(address,uint256,uint256,uint256,bytes)`, which carries the down-leg. The Rust keeper now loops it, urgent first. O(N) txs where the pooled call would be one. |
| 2 | **`_bandBps` IS A CONSTANT PLACEHOLDER.** ✅ `LevBase._bandBps` returns a literal `300`. §DERIVED-BAND derived it from `kLvrWad`, which is deleted with θ. The band must be re-derived from CARRY (owner: *"gas has nothing to do with lvr"*). | `LevBase.sol` — `function _bandBps(uint256, ILevVenue) internal pure returns (uint256) { return 300; }` |
| 3 | **THE ENUMERATION MOVED TO LOGS.** ✅ `openLevCount`/`openLpAt` are gone, so both Rust keepers now build the open set from `Opened`/`Closed` events (`lev_keeper::open_lps_from_logs`, shared by the ETH and BTC keepers). Same-block open-then-close resolves as CLOSED, deliberately. | The events are declared on `LevBase` (`:260`, `:261`), so one helper serves both managers. |
| 4 | **`SkewVsUniswapV3` MUST COME BACK AS AN ASSERTION.** ⏸️ It was deleted because it only LOGGED. The competitive ceiling in §4 is a requirement, and nothing currently falsifies it. | Rebuild as `ourCost ≤ theirs at every size we serve`. |
| 5 | **DELETING IT COST THE ONLY IN-TREE ABI FOR THE V3 QUOTER, AND A GATE SAYS SO.** ✅ `tools/check-client-abis.py` goes 4 → 6 RUST DRIFT on this lane, and the two new hits are `getPool(address,address,uint24)` and `quoteExactInputSingle((address,address,uint256,uint24,uint160))` — both declared ONLY in `SkewVsUniswapV3.t.sol` and `PermittedPoolSet.t.sol`. The Rust keeper still calls both against live Uniswap; nothing now checks its encoding. | The other four drifts are pre-existing on `main` (third-party venue reads with no in-tree declaration — the same false-positive class as `orphans-allow.txt` CLASS 1). Rebuilding #4 closes #5 as a side effect, which is a second reason to do it rather than a separate task. |

**Gates that were updated deliberately rather than dropped** (each demands a stated reason, and each
now carries one): `tools/check-skew-agnostic.py` (five of eight skew functions deleted; the gate stays
because the sell-in capacity term must not read a v4 concept or a measured flow), `tools/verify-seq-audit.py`
(fourteen symbols moved LIVE → GONE), `tools/check-signer-allowlist.py` + `evm_validating_signer.rs`
(both batch selectors removed as ORPHANs — signable surface nothing sends).

---

## §6c — THE DEVIATION GUARD COMPARES CHAINLINK WITH CHAINLINK ✅ (measured 2026-09-10)

Not created by any removal — but the removals made it the guard's **only** remaining justification, so
it can no longer sit behind σ².

**The chain of facts, all read from code:**
1. `Aux.getTWAPforAsset` → `Aux.resolvedTwap` → `SwapLib.twapBody` (the ring's TWAP) cross-checked by
   `SwapLib.twapResolve` against the pinned Chainlink feed; >5% apart ⇒ **return Chainlink**.
2. `Core._observeIfSourced` writes the ring. Its `src == address(0)` arm reads the **Chainlink anchor**
   and writes that.
3. `setObservationSource` has **zero non-test callers and no deploy script calls it** (its own docblock
   says so, and `DeployLib` confirms it).
⇒ The ring is a time-weighted average **of Chainlink**, checked against **Chainlink**. The guard fires
on staleness. It cannot fire on manipulation of the source, because there is only one source.

**Why this is now sharper than before.** §E222's independent-source rule had two consumers: the
deviation guard and σ². σ² is deleted, so the rule stands or falls on the guard alone — and
`OneInchGasProbe` (which measured 1inch's `getRate` at **31.7M gas**, past a whole block, corroborated
by the node refusing at its own 16.7M estimation ceiling) records that the obvious independent source
is not callable on chain. Curve's on-pool EMA was the fallback pick and the only ETH/USD pool
(TriCrypto) is removed from this codebase as a venue *and* as a read.

**The decision this owes.** Either (a) pin a genuinely independent source and accept a weaker one than
1inch (one venue, different MECHANISM — an EMA of executed trades vs a pushed feed), or (b) state that
Chainlink is the trust root, delete the ring as a smoother that cannot detect what it was built to
detect, and read the anchor directly. **Do not leave it implicit.** ⏸️ Owner ruling needed — (b) is a
removal of live, working code whose value is real (it smooths a single bad round), so it is not a
sweep-up.

---

## §7 — WHAT IS KEPT AND WHY (so it is not cut by a later sweep)
- **Oracle settlement / no curve** — the premise of everything.
- **The competitive ceiling as a REQUIREMENT** — the owner's, and it is what bounds the fee.
- **`_maxWellSkew`'s ARGUMENT** (not necessarily its runtime form): *"an AMM filling at oracle with no
  spread is a FREE OPTION… THE SKEW IS THE MARKET-MAKER SPREAD, and a spread of zero is the exposure."*
- **The §E68/§E68b INTEGRAL — conditionally.** It exists because the rate varied along the swap's own
  displacement. If the surviving drain charge is flat, **there is nothing to integrate and it goes
  too**; it survives only on the sell-in side, where the rate rises toward capacity.
- **Responsiveness as the liquidation defence**, with its four failure modes written down: gap risk ·
  the de-lever refusing to execute · permissionless ≠ someone calls · acting on a price up to 5% stale.
