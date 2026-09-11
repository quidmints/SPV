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
- ~~**The per-LP position model**~~ 🪦 **CANCELLED 2026-09-10 — see §8.** The owner ruled option (c),
  and (c) keeps the per-LP model because per-LP units, per-LP actuation and an O(1) exact per-LP
  target all already exist inside the ONE pooled position. Nothing here is waiting for a replacement.
  The original reasoning is kept below because its middle step — a *replace*, not a *remove* — was
  right, and only its conclusion was wrong.
  🧠 (was: the largest cut). ⛔ **AND IT IS A *REPLACE*, NOT A *REMOVE* —
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
3. ✅ **RESOLVED 2026-09-10 — `borrowRateRay` RAN, AND IT SPLITS THE QUESTION IN TWO.**
   `test/CarryAtOurNotional.t.sol`, live mainnet, all four DEPLOYED venues:

   | venue | base | +$1M | +$10M | +$50M | +$100M |
   |---|---|---|---|---|---|
   | AaveV3 WBTC/**USDC** (BTC) | 4.29% | +0 bps | +1 | +9 | **+321** (7.51%) |
   | AaveV3 weETH/**USDT** (ETH) | 4.27% | +0 | +1 | +7 | +84 (5.11%) |
   | Morpho weETH/**RLUSD** | 3.88% | **+108** | **+1,102** | ⛔ unfundable | ⛔ |
   | Morpho weETH/**PYUSD** | 4.38% | ⛔ **unfundable at $1M** | ⛔ | ⛔ | ⛔ |

   **(a) THE LEVEL IS NOT FREE: ~4.3%/yr ≈ 1.18 bps/day.** So §3's *"transient is free"* is FALSE as
   stated. What is true is the weaker claim it needs: **the MARGINAL cost of our own draw is ~0 up to
   $50M** (≤9 bps on either Aave venue). Absorption is cheap; HOLDING is not. ⇒ the sell-in leg needs
   the capacity term §4 already plans, and a position held across days needs carry priced into the LP's
   IL-protect accounting — not into the swapper's charge, which is what would make it gameable.

   **(b) CONVEXITY IS A CLIFF, NOT A CURVE.** USDC goes +9 bps at $50M and **+321 bps at $100M** — the
   kink sits between. This is the measured case FOR §MULTI-VENUE: the allocator's entire value is
   keeping each venue on the near side of its own kink, and the optimum is interior precisely because
   the curve is convex there.

   **(c) 🔴 RETRACTED 2026-09-11 — I SAID "THE TWO MORPHO VENUES ARE DECORATIVE, EXCLUDE THEM FROM
   THE SPLIT". THAT IS WRONG FOR RLUSD, AND THE ERROR HAS A SHAPE WORTH KEEPING.** The ladder started
   at **$1M** and I drew a conclusion about every size below it that I had never measured. Owner:
   *"you did not make sense about excluding the morpho venues."* Correct. Re-measured from $5k:

   | marginal APR (bps) | +$5k | +$25k | +$50k | +$100k | +$1M |
   |---|---|---|---|---|---|
   | AaveV3 USDC | 429 | 429 | 429 | 429 | 431 |
   | AaveV3 USDT | 423 | 423 | 423 | 423 | 424 |
   | **Morpho RLUSD** | **394** | **416** | 443 | 497 | 1,495 |
   | Morpho PYUSD | ⛔ | ⛔ | ⛔ | ⛔ | ⛔ |

   ⇒ **RLUSD IS THE CHEAPEST VENUE OF THE FOUR FOR THE FIRST ~$30k**, and stays under USDT until the
   crossover at roughly $30–40k. Excluding it leaves free money on the table — exactly the mistake I
   warned about, made in the opposite direction.
   ⭐ **THE RULE IS MARGINAL-RATE EQUALISATION, NOT A SHORTLIST.** An optimal split allocates to every
   venue until its MARGINAL rate equals the others'. A thin-but-cheap venue then gets a SMALL
   allocation automatically — neither "rank by base rate and send everything" (my §9 warning, still
   right) nor "exclude it" (my error). The steep curve is what SIZES RLUSD's tranche; it is not a
   reason to skip it.
   📌 **PYUSD IS genuinely empty** — unfundable at $5k, so it contributes zero at any size. That half
   of the original claim survives; the generalisation to "the two Morpho venues" did not.
   ⚠️ **AND THE METHOD LESSON, which is the transferable part: a ladder's FLOOR is a measurement
   boundary, not a starting point.** Everything below the lowest rung is unmeasured, and stating a
   conclusion there is inference wearing a measurement's clothes.
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
| 2 | ✅ **DERIVED 2026-09-11 — AND THE ANSWER IS THAT A CARRY-DERIVED BAND IS NOT A WIDTH, IT IS A DWELL.** See §11 below; the `300` placeholder stays for now because the instrument it should become already exists on the keeper. |
| 2b | ~~**`_bandBps` IS A CONSTANT PLACEHOLDER.**~~ (superseded by the row above) ⭐ Its input is now measured: carry is **~4.3%/yr = 1.18 bps/day** on both Aave venues (§6 check 3), so a band is "how many days of drift before a rebalance pays for its round trip". At a ~17 bps round trip that is ~14 days of carry — the band must be derived from that, not from the literal `300`. ✅ `LevBase._bandBps` returns a literal `300`. §DERIVED-BAND derived it from `kLvrWad`, which is deleted with θ. The band must be re-derived from CARRY (owner: *"gas has nothing to do with lvr"*). | `LevBase.sol` — `function _bandBps(uint256, ILevVenue) internal pure returns (uint256) { return 300; }` |
| 3 | **THE ENUMERATION MOVED TO LOGS.** ✅ `openLevCount`/`openLpAt` are gone, so both Rust keepers now build the open set from `Opened`/`Closed` events (`lev_keeper::open_lps_from_logs`, shared by the ETH and BTC keepers). Same-block open-then-close resolves as CLOSED, deliberately. | The events are declared on `LevBase` (`:260`, `:261`), so one helper serves both managers. |
| 4 | **`SkewVsUniswapV3` MUST COME BACK AS AN ASSERTION.** ⏸️ It was deleted because it only LOGGED. The competitive ceiling in §4 is a requirement, and nothing currently falsifies it. | Rebuild as `ourCost ≤ theirs at every size we serve`. |
| 6 | ✅ **FIXED 2026-09-11 — THE SPA SHOWED USERS A PRICING MODEL THE PROTOCOL NO LONGER IMPLEMENTS.** The user-facing copy said the cost was *"a small price lag, capped near 0.5%"* — ~12× the real charge. It now states the flat **0.042% (420 ppm)**, and the A–S block is re-labelled as a model of what a CONVENTIONAL DESK would quote, shown for contrast, with `K_LVR`/`CERTIFIED_THETA` marked ANALYTIC ONLY. ⚠️ `quant.ts`'s header note *"the deployed range is ±0.2%"* was ALSO wrong in the other direction (RANGE_DELTA was widened 20 → 200), and is corrected. ⏸️ Not type-checked — SPA deps are not installed in this tree. | ~~User-facing, so it is worse than a stale comment.~~ Booked as `§PLP-4` in SPRINT.md and never done; that row is cut, so the fix landed here. |
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

## §0b — ⏸️ **IS THE NEW DESIGN BUILT? NO. HERE IS EXACTLY WHAT IS AND IS NOT** (owner asked, 2026-09-11)

**Short answer: the SUBTRACTION is complete; the ADDITION has not started.** Everything removed is
removed, and the flat fee is live — but the mechanism in §3 that makes a flat fee *safe*, the balance
sheet absorbing the imbalance, is **not wired to the swap path at all.**

### ✅ BUILT (verified in code, not recalled)
| piece | evidence |
|---|---|
| **Oracle settlement, no curve** | §V4-CUT. One price for the whole size, bounded by inventory. |
| **The flat fee** | `wellSkew`/`sellSkew` both `return MIN_SWAP_SKEW_WAD` (420 ppm); `retainSkewPremium` credits it to LPs; `SkewPremiumReachesLPs.t.sol` asserts the credit arrives. |
| **No gameable bound anywhere on the charge** | every EWMA, variance register and θ consumer is deleted — `grep` for them returns comments only. |
| **One pooled venue position** | `repayPool`/`withdrawPool`, `poolLtvBps`, `totalDeliverableDollars`. |
| **Per-LP IL targeting inside it** (§8, option (c)) | `debtUnits[lp]`/`collUnits[lp]`, `repay(lp)`/`withdraw(lp)`, `debtDeltaToTarget(lp)` — O(1), exact, no aggregate needed. |
| **Redeem-side de-lever** | `BasketLib._deleverBookForRedeem` → `deleverBook` → `deleverToVault`. |

### 🔴 NOT BUILT — and the first row is the whole design
| piece | measured state |
|---|---|
| **§3 ABSORPTION — THE SELL-IN HALF ONLY** 🔴 **CORRECTED 2026-09-11, MY §0b OVERSTATED THIS** | I wrote *"a swap does not touch the lever"* on the strength of grepping `SwapLib` and `Core.swap`. **The DRAIN half is wired, through a path neither grep covers:** `QuidLib.sendEth` → when Quid holds too little WETH → `SwapLib.deleverEthOnDelivery(mgr, aux, px, shortfall, recipient)` → `poolVenue` → source stable → repay pool debt → `withdrawPool` → convert → deliver. So a swap-out that exceeds inventory DOES de-lever to serve itself, and §3's drain row is substantially already built (the dollars are drawn from the basket rather than earmarked from the swap, which is the same balance sheet). **What is genuinely missing is the SELL-IN half: nothing borrows against volatile the pool has just received**, so when dollars run short the swap partial-fills instead of absorbing. |
| **The sell-in capacity term** (§4) | `sellSkew` is the same flat constant as `wellSkew`. The `(1−L)` residual that motivates it is unpriced. |
| **`_bandBps` from carry** (§6b·2) | still the literal `300`. Its input is now measured (1.18 bps/day) but nothing consumes it. |
| **A keeper-callable pooled de-lever** (§6b·1) | `deleverToVault` is RANGE-gated; the keeper holds the book position-by-position via `rebalance(lp)`. |
| **The competitive-ceiling assertion** (§6b·4) | nothing falsifies *"our cost ≤ theirs at every size we serve"*. |
| **The borrow split** (§9) | deferred by the owner. |

### ⚠️ WHY THIS MATTERS MORE THAN A TODO LIST
A flat fee and oracle settlement are only safe **because** something else carries the inventory risk.
§3 is that something. Until it is wired, the protocol is a no-slippage oracle venue that partial-fills
when it runs out — which is a coherent product, and is NOT the design in this document. **Do not read
the deletions as the design having shipped.**

---

## §10 — 🔨 BUILDING §3's SELL-IN ABSORPTION — THE MINIMAL SHAPE, AND THE ONE FORK IT RUNS INTO

Owner: *"build the §3 absorption … minimum new code … tightest most consolidated waves."* Two
measurements collapse most of the job to nothing, and then it hits a fork I will not resolve alone.

### ⭐ FINDING 1 — A PROTOCOL-LEVEL BORROW NEEDS **NO NEW VENUE CODE AND NO NEW ACCOUNTING**
SPRINT booked this as *"the protocol borrow needs NO new accounting. ONE line, at the netting that
already exists"*, and proposed adding a `protocolDebtUsd` field because `totalDebtUsd` iterated
`_openLps`. **§POOL-VENUE already made that true without the field:**
```solidity
function totalDebtUsd() external view returns (uint256 usd18) {     // LevBase — CURRENT
    for (v in poolVenues) usd18 += _toUsd18(v.stable(), ILevPooled(v).totalDebt());
}
```
It reads the VENUE's pool debt, not a sum over positions. So a protocol borrow on the same pooled
position is netted by `_rangeEquityUsd18` → `committedUsd18` **automatically**.

⛔ **BUT IT MUST STILL MINT UNITS, AND THIS IS THE TRAP.** `debtOf(lp)` is
`_sharesToAssetsUp(_unitSlice(debtUnits[lp], totalDebtUnits, _poolShares()))`. A borrow that raised
`_poolShares()` without minting units would raise **every LP's `debtOf` pro-rata** — the protocol's
borrow charged to the LPs, which is the 4,801 bps cross-subsidy arriving through a third door.
⇒ **Borrow against a SENTINEL KEY.** `venue.supply(address(this), …)` / `venue.borrow(address(this), …)`
mint units to the MANAGER's own slot: attribution stays exact, LPs are untouched, `repay(address(this), …)`
retires protocol debt specifically, and `address(this)` can never collide with an LP (`openLev` keys on
`msg.sender`, and the manager never opens). **Zero new venue functions.**

### ⭐ FINDING 2 — THE WETH→COLLATERAL LEG ALSO ALREADY EXISTS
`LevMath.stableToColl(ctx, stable, amt, minOut)` → `_stableToWeeth` → `_stableToWethSor` (**identity
when the loan token is already WETH**) → `_wethToWeeth` (ether.fi mint). So
`stableToColl(ctx, WETH, wethIn, minColl)` IS the WETH→weETH on-ramp. **Zero new conversion code.**

⇒ The whole primitive is ~12 lines on `LevManager`: pull WETH, `stableToColl`, transfer, `supply`,
size against the sentinel slot's own LTV, `borrow`, hand the stable back.

### 🪦 THE A/B/C FORK IS RETRACTED (2026-09-11). Owner: *"idk that either proposed solution for sell
in is the most elegant."* Correct — **all three were wrong, and the mechanism already exists.**

I tabled: **A** keep minting QU!D against the volatile · **B** borrow instead · **C** mint to a cap
then borrow. Every one treats a sell-in as something that must be *funded now*. **It does not have to
be.** See §12.

---

## §12 — ✅ **THE SELL-IN IS ABSORBED BY MATURITY, NOT BY A BALANCE SHEET. IT IS ALREADY BUILT.**

Owner, verbatim, earlier in the same design: *"defer should be opt-in, if you wanna get paid in
volatile that's ok too, mirrored for volatile lp."* That IS the answer, and the machinery for it has
been in the tree the whole time.

### THE MECHANISM, read from code
```solidity
Basket.mint(address pledge, uint amount, address token, uint when)   // ← `when` IS the maturity month
```
- `BasketLib.calcMintYield(...)`: `month = max(nextMonth, when)`, then
  `normalized += normalized · yield · (month − (nextMonth−1)) / (WAD·12)`.
  ⇒ **the holder is PAID forward yield for accepting a later maturity**, at the basket's own `avgYield`.
- `balanceOf[receiver][when]`, `totalSupplies[when]`, `perMonth[receiver]` — a per-vintage ledger.
- `BasketLib.sol:1112`, stated outright: **"MATURE ONLY. Immature/forward QU!D is not a redeemable
  claim and is not a fundable one."** Redemption reads `matureSupply()` and nets
  `immatureBalanceOf(owner)`; `turn` burns matured vintages only.

### WHY THIS DISSOLVES §3's SELL-IN PROBLEM RATHER THAN SOLVING IT
§3 worried that a sell-in re-dollarises only `L`, so `(1−L)` *"permanently backs a dollar claim with
volatile"*. **An immature claim is not a demand on dollars at all** — it is excluded from
`matureSupply`, from the redeemable claim, and from `turn`. So there is nothing to back until it
matures, and by then the flow has had time to reverse. The exposure §3 tried to price away does not
form.

⇒ A sell-in that outruns dollar inventory **pushes `when` out** instead of borrowing. The swapper is
compensated out of yield the basket already earns, rather than the protocol paying **~4.3%/yr** carry
(§6 check 3) on a transient imbalance.

| | A: mint now | B: borrow | **§12: mature later** |
|---|---|---|---|
| new code | none | ~12 lines + a venue slot | **none — `when` is already a parameter** |
| cost to protocol | depeg exposure at the margin | carry ~4.3%/yr, LTV headroom | pays `avgYield × months`, in a claim it issues |
| opt-in? | no | no | **yes, by construction — the swapper picks the tenor** |
| symmetric with the drain's deferral? | no | no | **yes** |

### WHAT §4's CAPACITY TERM BECOMES: A TERM STRUCTURE
The charge on a sell-in is no longer a premium in bps — it is **how far out `when` has to go**, and
that is a function of ACTUAL DOLLAR INVENTORY, a balance-sheet fact. §NO-GAMEABLE-BOUND is satisfied
for the same reason the flat fee satisfies it: an attacker can push others down the curve only by
draining dollars, and draining dollars costs them the drain. Costly to move ≠ free to starve.

### ⏸️ WHAT IS ACTUALLY LEFT TO BUILD, and it is small
1. **Choose `when` from inventory** on the sell-in path (today every swap-side mint passes a flat
   value). This is the whole feature.
2. **Quote it.** The swapper must see the tenor before committing — the same seam
   `Aux.quoteSwapOut` already occupies.
3. **A floor on the term** so the curve cannot be pushed absurdly far by a single large sell.
⛔ NOT NEEDED, and deleted from the plan: the sentinel-key protocol position (§10 finding 1), the
`stableToColl(WETH,…)` on-ramp (finding 2), and any borrow on the swap path. Both findings were
correct and both are now moot — kept in §10 only as the record of a road not taken.
---

## §13 — 🔗 **ONE DEFERRAL PRIMITIVE. THERE ARE THREE IN THE TREE AND THEY DISAGREE.**

Owner: *"collapse the two deferrals into one mechanism."* Measured first — **there are three**, and
finding the third is what makes the collapse obvious.

### THE PRIMITIVE, stated once
> **The pool owes you `X` of asset `A` and holds less than `X`. It issues you a DATED CLAIM on `A`,
> and pays you what `A` EARNS while it is undelivered.**

That is the whole mechanism, in either direction. The asset you are waiting for keeps working; the
yield it makes is what compensates the wait. Nothing is forecast, nothing is borrowed, and the
protocol's cost is zero because it is paying out yield it would not otherwise have owed.

### THE THREE IMPLEMENTATIONS, AND WHICH ONE IS WRONG
| # | site | asset | dated? | paid for the wait? |
|---|---|---|---|---|
| 1 | **QU!D vintages** — `Basket.mint(…, when)`, `balanceOf[holder][when]` | dollars | ✅ `when` | ✅ `calcMintYield`: `yield × months` |
| 2 | **the offramp's LAST RUNG** — `QuidLib.offrampBody` tries **Curve weETH/WETH first**; `waitNft` → ether.fi `requestWithdraw` is the FALLBACK | volatile | ✅ the NFT's own queue | ✅ eETH staking yield accrues to the holder |
| 3 | 🔴 **`usd_owed`** — `Quid.sol:543-551`, `:822`, `:974` | dollars | ❌ **undated** | ❌ **nothing** |

⇒ **1 and 2 ARE ALREADY THE SAME MECHANISM** — one for each asset, each paying that asset's own yield.
They look different only because one is ours and one is ether.fi's.
🔴 **AND THE ASYMMETRY THE OWNER NAMED (2026-09-11: *"waitnft is a fallback if we want use curve"*)
IS THE IMPORTANT PART, NOT A DETAIL.** The volatile side does NOT defer by choice: `offrampBody` tries
**Curve weETH/WETH first** and only falls through to the dated claim when that route cannot serve.
⇒ **The two directions are not yet symmetric, and the asymmetry is the right way round.** Deferral is
the LAST RESORT on the volatile side and would become the FIRST response on the dollar side under §12.
Collapsing them means adopting the volatile side's ordering everywhere: **try to serve now; defer only
when serving now is worse for the counterparty than waiting.** On a sell-in that means: pay from
dollar inventory if it is there, and offer the dated claim only when paying now would mean selling
something at a bad price — which is exactly when a swapper would rather wait and be paid for it. **`usd_owed` is the outlier:** a
deferral that pays the deferred party *nothing*, tracked in a bespoke per-LP register instead of the
vintage ledger that already exists. Its docblock calls it *"a deferred, unrealized claim — strictly
conservative, no mint"*, and conservative is exactly right about SUPPLY and exactly wrong about the LP,
who is lending the protocol money for free.

### THE COLLAPSE
1. **`usd_owed` becomes a QU!D vintage.** Accrue the LP's USD fee leg as `mint(lp, amount, token, when)`
   rather than into a private register. Same ledger, same maturity semantics, same redemption path —
   and the LP is paid `avgYield × months` for the wait instead of nothing. **Deletes a register and a
   realisation branch** (`:974`'s mint-out-on-full-exit), because the claim is already a token.
2. **The swap's partial-fill refund becomes opt-in deferral.** Today an inventory-bounded swap takes a
   partial fill and refunds the rest — a REFUSAL, not a deferral. Under the primitive the swapper
   chooses: take the refund, or take a dated claim on the remainder and be paid for the wait. That is
   the owner's *"defer should be opt-in"*, and it is the same choice in both directions.
3. **The two directions stop being separate subsystems.** Dollar-short ⇒ dated dollar claim (1).
   Volatile-short ⇒ dated volatile claim (2). The sell-in and the drain are then one rule with a sign.

### ⚠️ WHAT THE COLLAPSE COSTS, stated because it is not free
Converting `usd_owed` to a vintage **MINTS**, where today it deliberately does not. `totalSupplies[when]`
rises, and `Basket.mint`'s supply cap applies to protocol-internal mints (strict after month 12). So
this trades a silent, unpaid IOU for a supply-capped, yield-bearing one — better for the LP and more
honest in the accounting, but it consumes cap headroom that the current design leaves untouched.
**That is a real trade and the owner should see it before it lands, not after.**

✅ **CHECKED — DIRECTION 2 IS A ONE-LINE REACH.** `QuidLib.waitNft(amount, recipient, cfg)` already
takes an arbitrary `recipient` and passes it straight to `IEtherFiLiquidityPool.requestWithdraw(recipient, eeth)`.
A swapper can be that recipient today.
⭐ **AND THE CODE ALREADY DEFENDS THE SEMANTICS WE NEED.** A standing warning at that call site records
that the NFT was briefly repointed to `address(this)` on 2026-08-06 so it could repay a WETH borrow,
that the borrow *"does not exist, and worse, cannot exist against this venue"*, and that while mis-set
**every exit reaching this rung delivered the withdrawer NOTHING while taking their weETH** — caught by
three tests reporting *"delivered ETH: 0"*. The note ends *"do not repoint this again"*. Issuing the
claim **to the waiting party** is therefore not a new decision; it is the one the tree already made and
paid for.

---

## §14 — 🔑 **NO IL FOR A PASSIVE LP: WHERE IT COMES FROM, AND WHY IT IS NOT FREE**

Owner: *"no IL for passive lp."* Traced to the exact line that creates it, then costed. **The honest
answer is that it is deliverable, it is ONE accounting change, and it is not free — and the cheapest
version makes the lever PROTOCOL-LEVEL rather than per-LP opt-in.**

### THE LINE THAT CREATES IT — `Quid._pricingBacking()`
```solidity
total  = _auxRangeETH();                                   // the ETH still held
uint px = _wethTwap();
if (usd6 > base6) total += fullMulDiv((usd6 - base6)*1e12, 1e18, px);   // ← the USD leg, at TODAY's price
```
An LP's claim is denominated in ETH — the ETH still held, **plus the LP-owned USD converted back to ETH
at the CURRENT oracle.** Worked:

> Deposit **100 ETH** at $2,000. A drain sells 50 for $100,000 ⇒ `rangeETH = 50`, USD leg = $100,000.
> Price doubles to $4,000 ⇒ claim = `50 + 100,000/4,000` = **75 ETH**. Holding was 100. **−25 ETH.**

⇒ **That is the whole of our IL, and note what it is NOT.** No arb picked us off (no stale price, no
LVR) and the sale was at the honest oracle. It is pure INVENTORY RISK: we sold at a fair price and the
price moved after. An AMM's IL is that PLUS adverse selection; ours is the residue that survives
deleting the curve.

### 🔴 CORRECTION 2026-09-11 — **MY DEFINITION OF IL WAS WRONG, AND THE FIX I PROPOSED WAS OPTION (b) AGAIN**

Owner: *"you dont define il right. its different for every lp based on when they enter and when they
want to leave. then there is instantaneous il for everyone at any given time."* Correct on both counts,
and the worked example above hides it by speaking of *"the"* IL as if the pool had one.

**IL IS THREE DIFFERENT QUANTITIES AND I CONFLATED THEM:**
1. **REALISED, per LP** — fixed only at EXIT, and a function of BOTH endpoints: that LP's entry price
   and the price on the day it leaves. Two LPs leaving the same day with different entries realise
   different numbers; the same LP leaving a week later realises a different number again.
2. **INSTANTANEOUS, per LP** — at any moment every open LP carries an unrealised gap between its claim
   and what it would have held since ITS OWN entry. It is a distribution across the book, not a scalar.
3. **PATH-DEPENDENT** — it round-trips. A gap that is wide today narrows if price retraces, which is
   why it is called impermanent and why the design refuses to hedge the DOWN side.

⇒ **THE POOL DOES NOT HAVE "AN IL". IT HAS ONE PER LP PER INSTANT**, and only the exit collapses one
into a number.

⛔ **SO "VALUE THE USD LEG AT THE PRICE IT WAS CREATED AT" IS WRONG** — that is a POOL-level basis,
belonging to no LP. An LP that joined after the sale would be handed a hedge it never needed; one that
joined before would get too little. **That is exactly option (b) from §8** — the equity-weighted
pooled basis I rejected there as cross-subsidising — arriving by a different road. I should have caught
it; §8 is four sections up.

✅ **AND THE TREE ALREADY GETS THIS RIGHT, which is the strongest argument that the correction is the
design and not a patch:**
- `Types.Pos{ ilBasisPx, entryEquity }` — **per LP, FIXED AT OPEN.**
- `LevMath.ilTargetBps(p.ilBasisPx, pxNow, cap) = min(cap, 1 − √(entry/now))` — each LP's hedge sized
  off **its own** entry against **today's** price. That IS quantity 2, computed per LP, on demand.
- `pxNow <= ilBasisPx ⇒ 0` — the down side is deliberately unhedged, because it heals (quantity 3).
- `soldFractionWad(syncKeyPx, …)` — keyed to the position's own sync price, not the pool's.

⇒ The per-LP model is not legacy to be collapsed (§8 already concluded that). **It is the only shape
that can represent the quantity at all.**

### ⇒ THE ANSWER, RESTATED PER-LP: **AUTOMATIC, BUT NOT POOLED**
The hedge should be **automatic rather than opt-in** — an LP does not elect to be short volatile, the
book makes it so — but it must still be sized **per LP off that LP's own `ilBasisPx`**, exactly as
`ilTargetBps` already does. "Automatic" changes WHO DECIDES (nobody — it is the protocol closing a
delta it created); it must not change WHAT IS MEASURED (each LP's own entry). Collapsing the basis is
the cross-subsidy; collapsing the DECISION is the improvement.
⭐ **THIS ALSO RELOCATES "OPT-IN" TO WHERE THE OWNER ALREADY PUT IT.** *"Defer should be opt-in."* The
choice an LP makes is not *"do I want a hedge"* — it is *"will I wait to be paid in kind."* §13's
primitive is the opt-in; the hedge is not.

### 📌 WHY LEVERAGE AT ALL — the owner asked, and I did not originate this
**I did not choose it. The owner did, and the reason was market impact** (verbatim, earlier in this
design): *"why are we buying anything back if all of this is transient and we would be incurring huge
slippage on external venues by moving our entire tvl. we should use leverage instead."*

But that is the reason for rejecting BUY-BACK, and it is not by itself the reason leverage is the
right replacement. The structural reason, stated so it can be attacked:

> **After serving a drain the pool must be TWO things at once: holding dollars as inventory for the
> other direction, AND long volatile for the LP. One pot of capital cannot be both. Leverage is what
> lets the same capital do both jobs.**

Spend the sale proceeds buying volatile back and the dollar inventory is gone — the pool can no longer
serve a sell-in, and the imbalance has simply been moved to the other side. Hold the dollars and the
LP is short its own asset. Borrowing against collateral is the only way to be long the volatile while
the dollars stay available as inventory.

⚠️ **AND THE HONEST LIMITS OF THAT ARGUMENT:**
- It does NOT avoid market impact, only *reduces* it: the lever still buys volatile, just at the size
  of the IL rather than of the TVL. The owner's slippage point survives at the smaller size.
- It is not free — **~4.3%/yr** (§6 check 3), which is what the break-even below is about.
- ⭐ **AND IT IS NOT THE ONLY INSTRUMENT.** Deferral (§12/§13) achieves the same delta at ZERO carry
  when flow reverses — the LP is owed volatile in kind and the obligation clears itself. Leverage is
  what you use when flow does NOT reverse. **So the ordering is the same one §13 arrived at:
  serve/settle now if you can, defer if the counterparty prefers it, and lever only for the residue
  that neither clears.** Leverage is the third choice, not the first — and nothing in the tree
  currently expresses that ordering.

### THE BREAK-EVEN, so this is a number and not a hope
Carry on levered notional `L` is `4.3%·L/yr`. Fee revenue is `4.2 bps × volume`. Break-even:
```
volume / L  =  4.3% / 0.042%  ≈  102× per year   ≈  2× per week
```
**The pool must turn over its levered notional about twice a week to pay for hedging it out of fees.**
That is a demanding but ordinary number for a real venue — and it is the single measurement that
decides whether protocol-level hedging is self-funding or a subsidy. ⏸️ **UNMEASURED. It is the most
important open number in this document.**

### WHAT SURVIVES OF "NO SLIPPAGE, NO LVR, NO IL"
| claim | status |
|---|---|
| **no slippage** | ✅ **structural** — oracle settlement, one price for the whole size. Nothing to price away. |
| **no LVR** | ✅ **structural** — we publish no stale price, so there is no free option to exercise. |
| **no IL** | 🔧 **NOT structural — it is PURCHASED**, either with carry (the lever) or with time (deferral). The structural part is that ours is smaller than an AMM's, because the adverse-selection half is already gone. |

⛔ **Do not claim "no IL" as a property of the architecture.** It is a property of the hedge, and the
hedge has a price. Saying otherwise is the same overclaim §0b caught about the deletions.

---

## §11 — ✅ THE NO-TRADE BAND IS **NEITHER A WIDTH NOR A DWELL — IT IS A REALISED-COST ACCUMULATOR**

§6b debt 2 asked for `_bandBps` to be derived from carry rather than from gas (*"gas has nothing to do
with lvr"*) or from LVR (which needs σ, now deleted). With carry measured, the derivation runs — and
it lands somewhere other than a width.

**THE ARITHMETIC.** A position off-target by `Δ` debt costs carry on debt it does not need:
`Δ · carry · T`. Rebalancing costs a round trip on roughly the same notional: `roundtrip · Δ`.
Rebalance when the first exceeds the second:

```
Δ·carry·T > roundtrip·Δ      ⇒      T > roundtrip / carry
```

⭐ **`Δ` CANCELS.** The condition has no size in it and no width in it — **it is purely temporal.** At
today's numbers (carry 4.3%/yr = **1.18 bps/day**, §6 check 3; round trip ~17 bps, §4's competitive
band) that is **T ≈ 14 days**.

⇒ **This is why the two earlier derivations failed, and the failures were informative:**
- **GAS** gives a width, because gas is a FIXED cost that does not scale with `Δ` — so `Δ` does not
  cancel and you get a minimum size. That is `min_rebalance_usd` ($50), which already exists and is
  the right instrument for gas. The owner's *"gas has nothing to do with lvr"* is exactly this.
- **LVR** needs σ, which is deleted as gameable.
- **CARRY** cancels `Δ` and yields a TIME. The keeper already has that instrument:
  `DwellTracker::persisted(lp, out_of_range, now, dwell_secs)`.

### 🔴 AND THE MEASURED GAP IS THREE ORDERS OF MAGNITUDE
`LevKeeperConfig::default()` ships `dwell_secs` at **1800s (30 min)** against a carry-justified
**~14 days** — a **670×** gap — and `target_range_bps: 300`, which mirrors the on-chain `_bandBps`
placeholder. On the carry argument alone the keeper rebalances far more often than the round trips
pay for.

🔴 **AND THE DWELL ITSELF IS A FORECAST, WHICH THE OWNER HAS NOW RULED OUT** (2026-09-11: *"we should
not be making forecasts at all"*). A dwell waits because the move **might reverse** — an implicit
mean-reversion bet, and nothing measures whether it is true. I had also left a caveat here saying the
omitted hedge-error term *"needs σ"* and proposing to price it from the observed gap. **Both die
under the same rule, and the replacement is simpler than either:**

> **Rebalance when the carry ALREADY PAID on the excess debt exceeds the round trip it would cost to
> fix it.**

Purely backward-looking. No timer, no σ, no reversal assumption, no term to size — an accumulator of
REALISED cost against a KNOWN cost. It is the same move the flat fee made one layer down: stop
predicting what flow will do and charge what is actually there.
⇒ So the answer to *"what should `_bandBps` be"* is: **neither a width nor a dwell — an accumulator.**
The ~14-day figure above is what that accumulator would trip at under today's carry, but it is an
OUTPUT of the rule, not a constant to set.

⏸️ **What is owed before changing either constant:** the ~17 bps round trip is quoted from §4's
competitive band and has not been measured on our own rebalance path. That measurement is the same one
§6b debt 4 needs (`SkewVsUniswapV3` as an assertion), so one piece of work closes both.

---

## §9 — ⏸️ SPLIT THE BORROW ACROSS STABLES (owner, 2026-09-11) — DEFERRED, BUT THE NUMBER IS NOW MEASURED

Owner: *"the borrow cost is too high, must be split between stables to be small… but we'll get to that
after settling everything else."* Booked here so the arithmetic is not re-derived, and NOT started.

**THE MEASURED CASE, straight off §6 check 3's ladder.** Borrowing $100M on USDC alone costs **7.51%**,
because that draw crosses the kink. Split $50M/$50M across the two Aave venues instead:

| plan | USDC leg | USDT leg | blended | vs single-venue |
|---|---|---|---|---|
| $100M on USDC alone | 4.29% → **7.51%** | — | **7.51%** | — |
| $50M + $50M | 4.39% | 4.34% | **~4.37%** | **−314 bps ≈ $3.1M/yr** |

⚠️ **AND THE HONEST HALF: SPLITTING KILLS THE CLIFF, NOT THE FLOOR.** The base is ~4.3% on both
venues and splitting does not move it — that is the market's price for the dollar, and no allocation
changes it. What splitting removes is the CONVEX part, which is the whole $3.1M. Anyone reading
*"split it to make it small"* as *"split it to make it cheap"* will be disappointed at small size and
right at large size; the benefit is zero until a leg approaches its own kink.

⛔ **ALLOCATE BY EQUALISING MARGINAL RATES — `borrowRateRay(size)`, never `borrowRateRay(0)`.**
🔴 An earlier version of this line said *"do not include the two Morpho weETH venues in the split"*.
**Retracted** — see §6 check 3(c). RLUSD is the CHEAPEST of the four for the first ~$30k (394 bps at
+$5k against USDT's 423), and only becomes the worst past its crossover. Marginal-rate equalisation
handles both facts with no shortlist: RLUSD gets a small tranche, USDC/USDT get the bulk, and PYUSD
gets zero because it is unfundable at every size measured.

**WHAT IT NEEDS, so the size of the job is known before it starts:** `borrowRateRay` and
`supplyHeadroom` are already declared on both venue classes and allowlisted as §MULTI-VENUE orphans;
the per-venue walk exists at three sites (`LevBase:538/:700/:791`). The single blocker is
`LevBase:422-423` — `else if (poolVenue != address(venue)) revert VenueNotPooled()` — i.e. the
one-venue pin, not any missing aggregation. (Recorded in `tools/orphans-allow.txt`, CLASS 2.)

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

---

## §8 — 🪦 THE POOLED DELTA TARGET — **CANCELLED 2026-09-10. OWNER RULED (c), AND (c) IS ALREADY BUILT.**

Owner: *"c wasnt continue. i dont like buckets"* — i.e. option **(c)**, and a rejection of (a)/(a′),
which were both grids.

⛔ **AND THE RULING EXPOSES THAT §8 INVENTED ITS OWN PROBLEM.** I framed this as *"the pooled delta
target, which gates every remaining removal"* and then spent two passes on how to compute
`Σ target_i · e0_i` in sub-linear time — a closed form, then a grid, then a Fenwick tree.
**Nothing needs that sum.** Measured, three greps:

| claim | measurement |
|---|---|
| Per-LP debt is REAL under one pooled position | `LevVenueBase:110-111` — `p.debt = _unitSlice(debtUnits[lp], totalDebtUnits, pool.debt)`. `debtUnits[lp]`/`collUnits[lp]` are that LP's exact share slice; interest accrues to the pool and reaches every LP through that one conversion. |
| Per-LP actuation is REAL | `repay(lp, …)` → `_repayCreditingLp` and `withdraw(lp, …)` burn **that LP's own units** (`:345` *"this LP's exact share slice"*). §POOL-VENUE ADDED `repayPool`/`withdrawPool` for pool-wide sweeps; it did not remove the per-LP pair. |
| The per-LP target is already O(1) and exact | `debtDeltaToTarget(lp)` → `_targetInputs(lp)` reads ONE `Types.Pos` + `debtUsd(lp)`. No walk, no aggregate, always fresh in price. |
| **Nothing sums targets** | `grep -c 'totalTarget\|sumTarget\|aggregateTarget\|targetDebtTotal' src` = **0**. |

⇒ **(c) IS NOT "A LAZILY MAINTAINED SUM THAT LAGS" — THERE IS NO SUM.** The pool's debt is an
OUTCOME: each LP's own delta is computed exactly, when that LP is touched, and applied against that
LP's units. The venue's `totalDebt()` is whatever those deltas produced. My "the lag is the crash
window" objection was against a stored aggregate that this design does not have.

**AND THE CRASH PATH NEVER NEEDED IT EITHER.** `deleverToVault` is pool-level and LTV-driven — it
reads `totalDeliverableDollars` and `poolLtvBps`, not any target. Safety and targeting are separate
questions, and only targeting is per-LP.

### 🔴 CONSEQUENCE: §5b's LARGEST REMOVAL IS CANCELLED
`Types.Pos{ilBasisPx, entryEquity, syncKeyPx}`, `debtDeltaToTarget`/`_targetInputs`/`_bandFor`/
`deleverRepayUsd`, `_repayCreditingLp`/`repayFor`, `closeLev`, `ilTargetBps`, and
`debtUnits`/`collUnits` + `_mintUnits`/`_burnUnits`/`_unitSlice` were listed as *"waiting for the
pooled target"*. **They are not waiting for anything — they ARE the design under (c).** §5b's
proposed replacement (*"per-LP attribution falls out of the SHARE PRICE… no `ilBasisPx` needed"*) is
the cross-subsidising option (b) wearing different words: an LP entering later would be hedged against
the pooled entry basis rather than its own.

✅ **WHAT REMAINS TRUE FROM §8**: the closed form `D* = (px·S1 − √px·S2)/1e18` is correct arithmetic
and cost nothing to derive, but it has no consumer. Recorded, not built — `RangeLib.openPos:202`'s
standing rule 1 (*"the branch would be unreachable"*) applies to it now for a second reason.

### WHEN BORROW FIRES, ONCE THIS EXISTS
`D*` is a **function of price and the two sums, evaluated on read.** So:
- a **drain** raises no debt and lowers LTV; the proceeds **repay** toward `D*` (§3);
- a **sell-in** supplies collateral and **borrows** toward `D*`, bounded by the capacity term (§4);
- a **price rise** raises `D*` (more up-side IL to cancel) ⇒ the keeper levers up;
- a **price fall** lowers `D*` ⇒ repay, which is the same call the crash path makes.
There is no separate schedule and no forecast: **borrow fires whenever live debt ≠ `D*(px)` by more
than the band**, and the band is §6b debt 2 (to be derived from carry, not gas, not LVR).

📌 **`_bandBps` and this share an input.** `borrowRateRay(extraBorrow)` is declared on BOTH venue
classes (`LevVenueBase.sol:536` and `:811`), has **zero callers**, and is allowlisted as a
§MULTI-VENUE orphan. It is the carry the band must be derived from *and* §6 check 3 (*"is carry
expensive at our notional?"*). One fork measurement answers both. ⏸️ Not taken — the owner stopped
test runs (*"i dont care about tests at all now. dont run any until i explicitly tell you"*).
