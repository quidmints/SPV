# ROVER / weETH — what was measured on 2026-08-03, and what it means

> ▶️ **THE SHIP DECISION IS AT THE BOTTOM OF THIS FILE** (`# ⚖️ THE SHIP DECISION`). It answers the six
> questions this doc leaves open, with fresh reads at block **25,675,658**. Read it before acting on
> anything above — two of the six answers **reverse** a hypothesis stated above, and one method used
> above is retracted there.

# 🎯 THE GOAL, IN THE USER'S WORDS (this is the whole point of Rover — judge everything against it)
> *"our goal is to **not require our LPs or swappers to pay the 0.3 instant redeem rate without
> forcing them to wait**."*

⇒ Rover exists to give a **cheap AND immediate** weETH→ETH exit. ether.fi offers cheap-but-slow (queue)
  or immediate-but-0.3% (instant redeem). **Rover's only job is to beat that trade-off.** Every finding
  below is scored against it — NOT against "does the LP earn a yield".

# ⏳ NOT DEPLOYED ≠ NOT BROKEN — the bleeding is SCHEDULED, not absent (user, 2026-08-03)
> *"it's a bleeding contract nonetheless — just because it's not bleeding yet doesn't mean it won't be."*

**Correct, and an earlier framing in this doc was too comfortable.** "Nothing is deployed" was written
as if it lowered urgency. **It does the opposite:**
- **Every defect below is LATENT, not absent.** The ratchet, the stranding, the DoS surface, the
  uncapped `deliverableETH` leg — each activates on the FIRST mint. None of them requires an attacker
  or an unlucky market; they are properties of the design meeting a monotonic asset.
- ⏱️ **Pre-deploy is the ONLY window in which these are FREE.** After the first position exists, every
  one of them costs real inventory to fix plus a migration — and `deliverableETH` mis-stating
  deliverable ETH is the kind of thing that is discovered by a redemption failing, not by a test.
- 🔴 **The one that is genuinely worse if deferred: "LARGE ENOUGH" is a SIZING decision.** Ship at the
  wrong size and you cannot correct it without unwinding into the very pool whose exit you mis-sized.
⇒ 📌 **Read the rest of this doc as a PRE-SHIP DEFECT LIST with a closing window, NOT as an audit of a
  live system.** "Not live yet" is the reason to fix it now, not a reason to schedule it later.

# 🏗️ THE ORIGINAL DESIGN INTENT (user, stated at the OUTSET — recovered from the transcript 2026-08-03)
> *"if the rover NFT (**which guarantees liquidity won't be pulled out** from the WETH/weETH v3 pool)
> is both **BALANCED** and **LARGE ENOUGH** to support **INSTANT conversion** of some weETH amount back
> to WETH…"*

⇒ **This is the frame everything else must be judged in, and it was missing from this doc.** The NFT is
  not a yield position — it is deliberately **the un-pullable floor under the exit**. Three requirements:
| requirement | today |
|---|---|
| **un-pullable** | ✅ **the ONLY property that survives everything measured.** Third-party WETH can be withdrawn with one call, no notice — ours cannot. This directly answers *"what if they remove the stranded inventory"*: **that is precisely why we hold our own.** |
| **BALANCED** | 🔴 **NOT today.** The ratchet converts our weETH → WETH exactly as it did everyone else's, and `_refreshAndRepack` re-centres on SPOT, so it re-inherits the stale price. **"Balanced" is a maintenance property, not a set-and-forget one** — and the maintenance is currently broken. ⚠️ This is also the honest home for *"pack at the imbalance ratio, not fair"*: the original requirement was **balanced**, so any change must say what it now targets and why. |
| **LARGE ENOUGH for instant conversion** | 🔴 **UNQUANTIFIED — nobody has ever sized it.** "Large enough" needs a number: the max single Vogue LP withdrawal / swap-out that must clear instantly. **Without it, `deliverableETH` cannot be capped correctly and there is no test for adequacy.** ▶️ **This is the missing requirement that makes everything else decidable.** |
📌 **So the three live failures map 1:1 onto the three requirements:** stranding breaks *un-pullable in
  practice* (out-of-range ⇒ contributes nothing), the ratchet + spot-centring breaks *balanced*, and the
  unsized position breaks *large enough*. **Fixing `_nearFair` alone addresses only the first.**

# 📋 USER CONSTRAINTS & OPEN ASKS — verbatim, because these are decision rules, not findings
| # | constraint | status |
|---|---|---|
| 1 | *"if we cannot substantiate our case in the .md document **and** in our implemented design for why we are adding this machinery we shouldn't continue with it"* | 🔴 **UNMET.** The fee case rests on a healthy-window measurement; the venue is now frozen. |
| 2 | *"we need to solve **the DoS surface, the LVR carry and the stranding**"* | DoS + stranding: fix shape known. **LVR carry: NOT solvable** (external pool ⇒ no party to re-allocate to). |
| 3 | *"fixing `_nearFair` is **not the only thing** that needs to be done"* | ✅ correct — see the higher-gravity list + `deliverableETH`. |
| 4 | *"we need to **adapt our rover either way to go where the volume is**"* | 🔴 **No volume found anywhere** — v3 both tiers frozen, Curve empty, v4 ~20× shallower. |
| 5 | *"we shouldn't **pack it at the fair ratio but at the current imbalance ratio** of the pool"* | 🟠 **UNEVALUATED.** Sound instinct (supply the scarce side = weETH); unpriced because flow ≈ 0. |
| 6 | *"are you sure `_priceOr` is correct? … degrading … might be good for weETH:WETH but **not WETH to dollar**"* | ✅ **Right, and the distinction matters.** For Rover the anchor IS the mint/redeem rate ⇒ degrading is unexploitable. For WETH:USD the anchor is Chainlink ⇒ genuinely a trade-off. **Do not transfer Vogue's precedent as proof — only as analogy.** |
| 7 | *"would it make sense to **drop the contract** (what would that buy)"* | Buys: no stranding, no DoS, no LVR. Costs: fee rebate on own flow + the controlled route. **Does NOT cost safety** — the un-pullable ether.fi queue is the guarantee, never Rover. |
| 8 | *"can they remove it any time (**vulnerability/liability** for us if we are counting on it)"* | ✅ **Yes — one `decreaseLiquidity` call, no lock, no notice.** `minOut` ⇒ revert not loss ⇒ **liveness risk, not solvency.** |

# 🚀 BRIEF FOR A DEDICATED ROVER THREAD
**Start here, then the sections below. Use a `git worktree` — another thread has unpushed work in this
checkout touching `QUEUE.md` and the `tickUpper` seam.**
**First three tasks, in order (each is ONE bounded read or measurement):**
 1. **Read `swapWeethForWeth`'s pool-order logic** — is selection SIZE-AWARE? B cliffs at 1–2k weETH;
    A degrades gracefully to 4k. A fixed order can revert on B when A would have filled.
 2. **Read `_deliverableCap`'s exact semantics** (`VaultLib.sol`) so the Rover analogue matches the
    file's existing pattern — then implement the `deliverableETH` cap (spec in this doc).
 3. **Measure `T`** = Rover-serviced offramp volume ÷ Rover weETH position, annualised. **This single
    number decides whether the NFT stays**, because the only surviving argument for it is the
    fee rebate on our own flow.
**Reproducible measurement toolkit** (all used to produce this doc):
```
POOL_A=0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3   # 0.05%
POOL_B=0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93   # 0.01%
WEETH=0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee  QUOTER=0x61fFE014bA17989E743c5F6cB21bF9697530B21e
cast call $POOL 'liquidity()(uint128)'            --block N   # in-range depth
cast call $POOL 'feeGrowthGlobal0X128()(uint256)' --block N   # fees/unit L (frozen ⇒ no trades)
cast call $WEETH 'getRate()(uint256)'             --block N   # fair; monotonic
cast call $QUOTER 'quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)' "($WEETH,$WETH,$AMT,$FEE,0)" --block N
```
⚠️ **Method warnings earned the hard way today — 7 retractions, 4 caught by the user:**
 • **Sample SEVERAL windows.** One window is a point, not a trend. The −1.6%/yr verdict came from the
   single 30-day window in which the pool died.
 • **Read total BALANCES before diagnosing `liquidity()`.** In-range `L` collapsing 3.5M× looked like
   abandonment; balances proved capital never moved — the price had drifted out of range.
 • **A comment describes past state.** The `~7%` band comment was stale; the band is ONE TICK. It
   mis-framed an entire analysis.
 • **Read `IL-CERTIFICATION.md` + `IL-VIA-BONDS.md` BEFORE theorising** — the single-sided/ratchet
   proposal was already tested across 5 model classes and REMOVED as inert. I re-derived it badly.


All figures are **point-in-time archive reads at named blocks** (mainnet, tip ≈ 25,674,xxx), not models.
Where this doc was wrong before, the correction is kept next to the claim — the reads were sound
throughout; the *inferences between them* were not, and that is the reusable lesson.

## 1. VENUES — where weETH/WETH liquidity actually is
| venue | address | state |
|---|---|---|
| Uni-v3 **0.05%** (`ETHERFI_POOL_A`) | `0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3` | 4,840 WETH · **1.0 weETH**; in-range `L`=6.6e17 |
| Uni-v3 **0.01%** (`ETHERFI_POOL_B`) | `0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93` | 2,053 WETH · **0.8 weETH**; in-range `L`=3.9e19 |
| Uni-v3 0.30% | `0x6f5C74e2170cfD6F5B7829F4742Dc54CEC42eA07` | 100 WETH; `L`=2.4e14 — negligible |
| **Curve** | `0xC13E07b6d204F638D5Ca803c12cb71e2F5416755` | ❌ **EMPTY (0/0) at 0d, 30d, 60d** — registered, never used |
| **Uniswap v4** | — | ⚠️ **NOT CHECKED.** v4 pool IDs are `keccak(PoolKey)` hashes, not factory lookups ⇒ needs an indexer/subgraph, not an RPC call. **Open.** |
📌 **Both v3 tiers are already wired** (`Vault.sol:133-134`, fees at `:348-349`). There was never a
  "switch to the other tier" to make — A and B both exist.

## 2. THE CENTRAL FACT — the liquidity never left; it went OUT OF RANGE
| pool | | now | −30d | −60d |
|---|---|---|---|---|
| 0.05% | WETH | 4,840.2 | 3,831.2 | 5,844.8 |
| | **weETH** | **1.0** | **921.6** | 2.8 |
| 0.01% | WETH | 2,052.6 | 1,613.7 | 3,106.2 |
| | **weETH** | **0.8** | **400.2** | 87.5 |
**WETH is flat-to-up. Only the weETH side vanished.** In-range `L` fell **3,497,327×** (2.310e24 → 6.605e17) (0.05%) and 25,000×
(0.01%) — but **TVL did not move**. ⇒ ⛔ **"The pool was abandoned" was WRONG (asserted 3×).** LPs did
not withdraw: the monotonic drift converted their weETH → WETH and walked price OUT of their ranges.
**This is the ratchet, observed in the wild** — and their parked WETH now bids for weETH at prices the
market has passed and, because the rate only rises, **will never revisit.**

## 3. PRICE — decompose it, or every conclusion is wrong
- **`weETH.getRate()` is MONOTONIC** (verified: 1.098451976 → 1.100658406 over 30d ⇒ **0.67 bps/day ≈ 2.4% APR**, higher at every sample).
- **DRIFT** = the rate. One-way, **never arbable**, pure cost to whoever quotes.
- **DEVIATION** = pool spot vs fair (today **−12 bps**). **This oscillates and IS arbable — it is the only revenue.**
⛔ Earlier claims conflated the two and counted drift while ignoring deviation ⇒ **every carry number
  produced on 2026-08-03 is biased against the LP and must be recomputed on the split.**

## 4. EXECUTION — measured via QuoterV2, selling weETH
| size | 0.01% tier | 0.05% tier |
|---|---|---|
| 1 weETH | **−16.0 bps** | −24.1 bps |
| 10 | −16.2 | −24.1 |
| 100 | **−17.2** | −24.6 |
⇒ **Flat to 100 weETH** (0.5–1.2 bps slippage over 100×). **The sell side is DEEP** — because the
  stranded WETH *is* the bid stack: selling weETH raises `P` into exactly the ranges that hold WETH.
⇒ ⭐ **vs ether.fi INSTANT REDEEM at −30 bps: the pool SAVES 6–14 bps and needs no queue.**
  **It is NOT "amortising" the 0.3% — it is beating it outright**, which is Rover's whole purpose.
⇒ 🎯 **The pool is deep for SELLING weETH and empty for BUYING it. Rover only ever sells** (it acquires
  by MINTING at fair, `Rover.sol:22-23`) ⇒ **the venue fits the need exactly.**

## 5. WHAT ROVER'S NFT ACTUALLY BUYS — **CONTROL**, not fees
The −16 bps offramp depends on **other people's stranded WETH, which they can withdraw at any time.**
It is out of range and earning them nothing, so there is no reason for it to stay.
⇒ ⭐ **Rover's own NFT is the ONLY liquidity we control.** Its value is a **floor on offramp
  availability** that survives everyone else leaving — not fee capture. Judged as a fee business it
  looks marginal; judged as *sovereignty over the exit*, it is the only thing that guarantees the exit
  exists. **This is the answer to "does Rover give us no benefit."**
⇒ Rover also has a capability no other LP has: **it can re-arm by MINTING weETH at fair, unlimited and
  slippage-free.** Everyone else must BUY weETH to rebalance — and there is none to buy. **So the
  failure mode "exploited away in a way we cannot rebalance" does NOT apply to Rover.**

## 6. LIVE DEFECTS (code reads — independent of any economics)
| | |
|---|---|
| 🔴 **Stranding** | `_nearFair` **REFUSES** mint/recenter/compound beyond 50 bps from fair. A shove that knocks the one-tick band out of range also trips the gate ⇒ **the recenter that would fix it is refused.** |
| 🔴 **Precedent** | **Vogue already fixed this exact bug.** `SwapLib._priceOr` (`:119-136`): the prior revert-on-divergence *"bricked QUI redemption and froze swaps/deposits … DEADLOCKED the protocol until the price mean-reverted"* — **proven by `test/TwapAnchorDeadlock.t.sol`**. Fix = **degrade to the anchor, never refuse**. ⇒ Rover holds the pattern Vogue abandoned, and unlike Vogue's case **nothing here incentivises the mean-reversion that cleared it.** |
| 🟠 **DoS cost is state-dependent** | Tripping the gate costs ~$5 at today's `L`, **~$18.2M at 30-day-ago `L`** (linear in `L`). It is a symptom of the out-of-range condition, not an inherent flaw. |
| ✅ **Fixed 2026-08-03** | The `~7%` band comment was **stale** — `_adjustTicks` is a **TRUE ONE-TICK band** (`floor(tick)`→`+TICK_SPACING`, ≈10 bps). Deleted; it mis-framed an entire analysis. |

## 6b. THE CYCLE — where the loss actually occurs (and where it does NOT)
**Minting is NOT where you lose.** `getRate()` is fair by definition — no spread, no slippage.
**The loss is entirely the accrual between placing weETH in range and an arber lifting it.** Your range
quotes a FIXED price while fair climbs underneath it; the moment the gap exceeds the fee, someone takes
the weETH and leaves you WETH.
> **hold WETH → mint at fair (neutral) → place in range → rate accrues, quote goes STALE → arber lifts
> → hold WETH again.** Round-tripped into the NON-yielding asset, having earned the fee tier and
> forfeited the accrual in that window.
⇒ **The real cost is being systematically converted OUT of the yield-bearing asset.** Holding weETH
  earns the full staking rate; LPing earns the fee per lift instead.
⇒ 🔴 **THERE IS NO STATE IN WHICH WAITING RECOVERS YOUR weETH.** Every other LP is already at the
  terminal state — **4,840 WETH vs 1.03 weETH is what "eventually" looks like.**
⇒ **The only escape is CADENCE:** loss/cycle = accrual during the window. Recenter fast ⇒ window → 0.
  Recenter slowly ⇒ concede the whole drift. **A race between recenter cadence and accrual rate.**
🔴 **AND THE RACE IS ALREADY LOST BY CONSTRUCTION:** `_refreshAndRepack` (`:78-83`) reads `_slot0()` and
  repacks on `getPrice(sqrtPriceX96)` — **POOL SPOT, not `getRate()` fair.** It re-inherits the very
  stale price it is trying to escape, **so the leak persists REGARDLESS of cadence.** Centring on fair
  is the precondition for cadence to matter at all.

## 6c. NEVER EVALUATED — options that may dominate everything above
| | status |
|---|---|
| **JIT liquidity** | 🔴 **NEVER EVALUATED, and this repo ALREADY HAS THE MACHINERY** (`JIT-DEPTH-GUARANTEE.md` + Vogue's JIT defense). Standing liquidity is what gets picked off; provide depth only in the block it is needed and withdraw. **Zero standing exposure, zero DoS surface, offramp served exactly when asked. Should have been considered FIRST.** |
| **Lending weETH** | 🔴 **NEVER PRICED.** weETH as Morpho/Euler collateral earns a supply rate ON TOP of staking, with no LVR and no liveness surface. §A.36 proves the venue plumbing exists. **The option table is incomplete without it.** |
| **Fee tier** | 🟠 never questioned — 0.05% vs 0.01% vs 0.30% is a free lever. |
| **Is Rover even DEPLOYED?** | 🔴 **UNCHECKED.** If its `L` is inside the historical ~1e24, the "with Rover" case is ALREADY MEASURED and the counterfactual work is unnecessary. **Cheapest check on the list — do it first.** |
📌 **Pattern:** each is an option never put on the table, and each could dominate what WAS analysed.
  **The failure mode was optimising WITHIN a frame instead of testing the frame.**

## 7. STILL OPEN
1. **Uniswap v4** — unchecked (needs an indexer).
2. **Why did every LP's weETH convert in the same window?** One large LP, or the ratchet reaching a
   common range boundary at once.
3. **Recompute the carry on the drift/deviation split** (§3) — prior numbers are biased.
4. **Pack at the pool's SCARCITY, not the fair ratio.** The pool is starved of weETH; supplying the
   scarce side is what can earn. ⚠️ But fees were **0.6 WETH/30d** — being sole seller in a pool with
   no flow earns the same as holding. **Size this against measured flow, not intent.**
5. **`IL-CERTIFICATION.md` already covers the LVR/limit-order class** (ratchet spread-capture ≈0 across
   five model classes). Read it BEFORE re-deriving. *(User indicates a different doc is the right
   reference — locate it first.)*

## 8. METHOD — why this doc leads with reads
Across one session the same error recurred: **a sound measurement, then an unexamined inference.**
"Abandoned" (balances disproved it), "$5 DoS" (state-dependent), "structurally negative" (measured in
the collapse window), "single-sided fixes it" (v3 cannot enforce direction; the repo had already
tested and removed it). ⇒ **Read the balances before naming the cause; sample several windows before
calling one a trend; and check whether the repo already answered it.**

---

# ⭐ THE SYNTHESIS — the only framing that survives EVERY measurement
Two verdicts were produced today and **both were artefacts of the window sampled**:
| verdict | why it was wrong |
|---|---|
| "liability, −1.6%/yr" | measured in the **collapse window** where fees ≈ 0 |
| "asset, +242% APR" | measured in a **healthy window** with flow that no longer exists |
⇒ ✅ **Correct framing: the pool's exit quality is a DEPLETING RESOURCE we are actively consuming,
  with no replenishment mechanism — and our valuation does not model it at all.**

## Why "no in-range liquidity" and "−16 bps to 1,000 weETH" are BOTH true
`liquidity()` reports only the tick we sit on — that genuinely is ~nil. The depth the quotes hit is
**ADJACENT**, in ticks the price recently passed through. Selling weETH pushes `P` up, back across the
ranges the drift just vacated. ⇒ **The exit is cheap BECAUSE THE STRANDING IS FRESH** (~30 days old).
**That is a snapshot, not a property.**

## 📉 THE DEPLETION MODEL — exit cost grows at the drift rate
Distance to the parked ranges grows one-way at **0.67 bps/day**, the WETH does not follow, and **no new
liquidity arrives** (nobody LPs into the position that just converted everyone).
| days from now | 0.01% exit | 0.05% exit | vs 0.3% redeem |
|---|---|---|---|
| 0 | −16.0 | −24.1 | pool wins |
| 7 | −20.7 | −28.8 | pool wins |
| 14 | −25.4 | −33.5 | mixed |
| **21** | **−30.1** | −38.2 | 🔴 **redeem now CHEAPER** |
| 30 | −36.1 | −44.2 | 🔴 redeem cheaper |
| 90 | −76.3 | −84.4 | 🔴 redeem cheaper |
⇒ 🔴 **The 0.05% tier crosses the instant-redeem rate in ≈8.8 days; the 0.01% tier in ≈20.9 days.**
⇒ **Total resource: 4,840 + 2,053 = 6,893 WETH — non-replenishing, consumed per offramp, receding daily.**
### ✅ MODEL CONFIRMED EMPIRICALLY — and the mechanism is cleaner than modelled
Same **100 weETH** quoted through QuoterV2 at historical blocks (0.05% tier):
| block offset | WETH out | vs fair |
|---|---|---|
| −30.0d | 109.7053 | −12.8 bps |
| −20.8d | 109.7861 | −11.3 bps |
| −13.9d | **109.7955** | −15.6 bps |
| −6.9d | **109.7955** | −20.1 bps |
| **now** | **109.7955** | **−24.7 bps** |

🔴 **The WETH output is BYTE-IDENTICAL across the last 14 days.** The pool price has not moved — **there
have been NO trades.** The entire degradation is `fair` rising *away from a frozen pool*.
⇒ Over that frozen stretch: **9.1 bps / 13.9 d = 0.65 bps/day**, against the independently measured
  drift of **0.67 bps/day**. **Two derivations from completely different data (fee-growth + rate reads
  vs quoter simulations) agree.** The depletion model is not an extrapolation — it is observed.
⇒ ⏱️ **CROSSOVER FROM TODAY: (30 − 24.7) / 0.65 ≈ 8 DAYS** on the 0.05% tier (~20 on the 0.01%).
  After that the **0.3% instant redeem is strictly cheaper** than routing through the pool.

### ⇒ WHAT THIS SETTLES ABOUT ROVER (the question is now much narrower)
- The venue is **not a functioning market** — a static price with zero flow, decaying at exactly the
  staking rate. "Thin liquidity" was the wrong diagnosis; **"no trades at all" is the right one.**
- **Rover's LP position cannot fix this.** Adding depth to a pool with no flow earns no fees — it only
  places our inventory where the same drift will convert it. **The fee-rebate-on-own-flow argument is
  the ONLY remaining case for the NFT**, and it is bounded by the 1–5 bps tier, not the price impact.
- Nothing in 30 days suggests new liquidity is coming.
📌 **Therefore the live decision is NOT "is the LP profitable" but "when do we stop routing exits here."**
  On today's numbers that is **~8 days** for tier A, ~20 for tier B — after which the ether.fi queue
  (0.3%, un-pullable) is both cheaper AND more reliable.

⚠️ Original caveat retained: linear extrapolation of the measured drift. It ignores any new LP arriving (none has in 30d)
  and any deviation mean-reversion (which moves it a few bps either way, not the trend).

# 🔴 HIGHER-GRAVITY CONCERNS (unverified — code NOT read; verify before treating as findings)
1. **VALUATION vs REALISABLE-AT-SIZE.** `valueWeth` prices at fair (pool-independent). The exit is flat
   only to ~1,000 weETH: **2,000 → −677 bps; 4,000 → −5,339 bps** on the 0.01% tier. If `deliverableETH`
   counts the Rover leg at fair, **the protocol believes it can deliver ETH it cannot realise** — same
   class as C10 (which clamped ether.fi REDEMPTION capacity, not POOL EXIT DEPTH). **And per the model
   above this gap WIDENS daily.** ▶️ Read `deliverableETH`'s Rover branch.
2. **POOL SELECTION MAY NOT BE SIZE-AWARE.** B (0.01%) is better small and **cliffs** at 1–2k; A (0.05%)
   degrades gracefully to 4k (−42 bps). If the ladder tries a fixed order, a large offramp can revert on
   B when A would have filled — liveness failure with a fill available. `minOut` stops us selling badly;
   it does not route us to the pool that works. ▶️ Read the order in `swapWeethForWeth`.
3. **THE COUNTERPARTY IS ABANDONED CAPITAL, withdrawable with no notice.** `minOut` ⇒ revert not loss,
   so liveness not solvency — but `IL-VIA-BONDS` states the ~0.12% fill as a property of the VENUE when
   it is a property of **third-party inaction**.
4. **STRANDING** (`_nearFair` refuses the recenter) — drops us out of range exactly when the pool is
   disturbed, i.e. when our own offramp needs the depth most.

# 🟡 LOWER-GRAVITY (checked, sound — recorded so they are not re-raised)
- `setLevManager` (`:132`) is **not** `onlyOwner` — correct: gated `msg.sender == AUX && levManager == 0`,
  pin-once. Rover renounces ownership in `setAux`, so `onlyOwner` is impossible by construction.
- `withdraw` (`:664`) is public but share-proportional via `fetch(msg.sender)` — caller's own position only.

# 💡 WHAT THE NFT IS ACTUALLY FOR — a fee REBATE on our OWN flow (not external yield)
External flow is ~0.6 WETH/30d. **But we are the volume:** every Vogue LP withdrawal / swap-out routing
through the ether.fi rung IS a weETH→WETH trade. If Rover is both LP and swapper, the fee it pays is
**partly paid to itself**, in proportion to its share of ACTIVE `L`. ⇒ The NFT is a **cost reduction on
required flow**, not a yield play — an argument **robust to external volume being zero**, unlike the
`IL-VIA-BONDS` "fee-earning convenience route" framing.
⚠️ Bounded: the rebate is on the FEE TIER (1–5 bps), not the ~16–24 bps price impact, which is paid to
  the stranded LPs regardless. Size it against real Vogue offramp volume.
📌 **Mechanically, every offramp converts other LPs' stranded WETH into weETH — their abandoned
  inventory IS our counterparty.** That is why the quote is flat to 1,000 weETH.

---

# 📊 THE FEES-vs-LVR MEASUREMENT (healthy window, drift and deviation SEPARATED)
Blocks **25,242,708 → 25,458,708** (~30d, `L` ≈ 1.1–2.3e24 — i.e. BEFORE the strand):
| component | value |
|---|---|
| **DRIFT** (fair rate) | 1.096233 → 1.098452 = **+0.67 bps/day** — one-way, pure cost, never arbable |
| **DEVIATION** (spot vs fair) | −8.8 → −7.4 bps (moved +1.4) — **mean-reverts ⇒ this is the REVENUE source, not a carry** |
| **FEES** (one-tick position) | **+67.07 bps/day** |
| **NET** | **+66.40 bps/day ≈ +242% APR vs holding** |
⇒ **Fees exceeded drift ~100:1 when flow existed.** ⚠️ Assumes full in-range time; drift moves price
  ~2 tick-spacings per 30d, so halve it for realistic re-centring ⇒ still **~120% APR vs a 2.4% drift
  cost.** **The ratio is the finding, not the headline.**
⇒ 🔴 **This is why the −1.6%/yr "liability" verdict was wrong: it was the SAME calculation run on the
  collapse window where fees ≈ 0.** Same method, opposite answer, because the window differed.
⇒ 📌 **And it is why the position is worth protecting: stranding does not cost −1.6%, it costs THIS —
  IF flow ever returns.** Today it has not (see: frozen pool, zero trades in 14 days).

# 📚 WHAT THE REPO ALREADY KNEW (read these BEFORE re-deriving — I did not, and re-derived badly)
- **`IL-CERTIFICATION.md:38`** — *"LVR … can be **re-allocated but never avoided**."*
- **`IL-CERTIFICATION.md:81-90`** — *"Limit orders / 'ratchet' do NOT change this … they suffer the same
  adverse selection. Tested across GBM, OU, real-data variance-ratio, real-data breakeven and the BTC
  delivery model: its spread-capture is **≈0 in every one** … **removed** as inert machinery."*
  ⇒ **This pre-empts the entire single-sided / off-fair-ask proposal.** It was tested and removed here.
- **`IL-VIA-BONDS.md:839-869`** — Rover is a *"fee-earning convenience route, **not the safety floor**"*;
  the guarantee is the **un-pullable ether.fi queue (rung 3)**; `minOut` capped at ~0.3% of fair so a
  drained/manipulated pool **reverts** rather than selling to arbers; and *"we are structurally weETH
  sellers"* ⇒ directional inventory risk was already known.

# ⚖️ WHY VOGUE HAS NO LVR CARRY AND ROVER CANNOT COPY IT
Vogue's band liquidity is **VIRTUAL** — mock token/USD, with the LP's real asset at a yield venue and
*"the paired **USD side is the basket's surplus, not the LP's**"* (`IL-CERTIFICATION`). So Vogue does not
avoid LVR — **it re-allocates it to the basket.** That transfer IS #12's measured −$59,966.
⇒ 🔴 **Rover has no such escape: it LPs REAL weETH into an EXTERNAL Uniswap pool.** You cannot mint mock
  tokens into someone else's pool. Vogue can virtualise because it owns its curve; **Rover is a guest in
  a public one, so its counterparty is an arbitrageur rather than our own basket.**
⇒ **That is the precise reason "nothing fixes" Rover's LVR:** LVR is only re-allocatable to a party you
  control, and in an external pool no such party exists.

---

# ⚖️ THE SHIP DECISION (2026-08-03, fresh reads at block **25,675,658**)

**Framing that changes the stakes: NOTHING IS DEPLOYED.** Rover has never held a position; every number
above and below is a read of an EXTERNAL pool. So no defect here is live, nothing is losing money right
now, and the cost of getting this right is design time. This is a SHIP / DON'T SHIP call.

⚠️ **STATUS MARKERS OBEY STANDING RULE 16** (`CLAUDE.md`): ✅ means *nothing can reopen it* — a
structural code fact or an on-chain invariant. A **measurement is not ✅** (it goes stale), and a
**design decision is not ✅** (reversing it reopens everything downstream). Almost everything here is
therefore OPEN or ⏸️ on purpose.

## 0. The benchmark, written as a number — everything below is scored against it
> *"not require our LPs or swappers to pay the 0.3 instant redeem rate without forcing them to wait."*

⇒ The thing to beat is **30 bps, with no wait.** So the one test every rung must pass is: **does it
deliver ETH in this block for an all-in cost under 30 bps?** Rungs are not judged on yield, on fee
capture, or on depth — only on that. Stating it as a number is what makes the six questions decidable.

## 1. SIZE — the ceiling is set by the VENUE, and Rover's own size cannot raise it
**Measured fresh (QuoterV2, selling weETH, vs `getRate()` = 1.100671697):**
| size (weETH) | 0.01% tier B | 0.05% tier A |
|---|---|---|
| 1 | **−16.23** | −24.23 |
| 100 | **−17.28** | −24.68 |
| 500 | **−21.45** | −26.49 |
| 1,000 | **−26.65** | −28.75 |
| 1,200 | **−28.73** | −29.66 |
| 1,400 | −30.81 | **−30.56** |
| 2,000 | −678.01 ⛔ cliff | **−33.27** |
| 4,000 | −5,339.01 ⛔ | **−42.31** |

⇒ 📏 **THE NUMBER THAT DID NOT EXIST: the 30 bps crossover is ≈1,250 weETH on tier A and ≈1,300 weETH
  on tier B** (≈1,375 ETH). **Above that size, routing through the pool costs MORE than the instant
  redeem it exists to beat.** That is the venue's answer to "large enough" — and it is a CEILING, not
  a target. *(OPEN — a measurement, and §📉 above says it falls with drift.)*
⇒ Tier B's cliff is total: output pins at **2,052.09 WETH**, and the pool's whole WETH balance is
  **2,052.62**. Past ~1,300 weETH the pool is simply drained. *(OPEN — measurement.)*
⇒ The 0.30% tier quotes **−914 bps at 100 weETH**. Correctly never wired; do not add it. *(OPEN.)*

### 🔴 The two structural facts that dissolve the sizing question
**(a) We never chose a size, and cannot.** `Vault.supplyEtherFiToRover` (`:409-417`) states it outright:
*"NO exposure cap — over-allocation is a structural non-problem… **Sizing is depositor
self-selection**, like every other venue."* Rover's size is EMERGENT, not a design parameter. So
"large enough" has no knob today. *(✅ as a code fact — the comment and the absent cap are both there.
Whether that is CORRECT is the ship decision, and stays OPEN.)*

**(b) 🔴 A LIQUIDITY POSITION CANNOT BE ITS OWN COUNTERPARTY — so making Rover bigger does not help.**
Depth Rover owns is depth Rover cannot sell into: swapping weETH through your own position hands you
back your own WETH, minus gas, having converted nothing. Rover's NFT therefore raises the exit ceiling
**for every party except Rover**, and Rover is the party that needs it. The only capital that can
actually buy our weETH is the **third-party** stranded WETH (6,893 total) — which §5 above already
establishes is non-replenishing and withdrawable without notice.
⇒ ⭐ **So requirement 3 ("large enough for instant conversion") is UNSATISFIABLE BY THE NFT.** Not
  "unsized" — unsatisfiable. Adding Rover capital adds weETH inventory that must still be sold through
  a fixed third-party bid. The only part of Rover that serves an exit without a counterparty is its
  **WETH leg pulled via `decreaseLiquidity`** — and that is just our own WETH, held in a v3 position
  instead of in a wallet. *(OPEN — this is the load-bearing argument of the whole decision and the
  first thing to attack if you want to ship the NFT.)*

## 2. VENUE — the freeze is re-confirmed one day on, and one method above is RETRACTED
- The 100-weETH quote is **still byte-identical at 109.7955 WETH**, matching this doc's readings at
  −13.9d, −6.9d and "now". A trade of any size moves `sqrtPrice` and would break that equality.
  ⇒ ~15 days with no price-moving trade. *(OPEN — measurement; re-read it before acting.)*
- ⛔ **RETRACTED METHOD — I tried to prove "zero trades" from `Swap` logs and it is invalid here.**
  `cast logs` returned 0 events for both pools. **The CONTROL refutes it:** the same query against
  USDC/WETH 0.05% (indisputably active) also returned 0, because this node answers archive requests
  with `HTTP 403 {"Archive requests require a personal token"}` — the "0" was an error string, not an
  empty result. **Do not use log counts for liveness on a keyless endpoint.** *(✅ — the control ran
  and failed; the method is dead regardless of any later decision.)*
- Historical `--block` reads are likewise unavailable keyless (all of −7d…−365d failed). The
  depletion model above cannot be re-verified from here; it needs an archival endpoint. *(OPEN.)*

### ⚠️ A DISMISSAL IN THIS DOC THAT DOES NOT HOLD (standing rule 13)
§📉's caveat waves off mean-reversion as *"a few bps either way, not the trend"*. **That is a
conclusion asserted without evidence, and there is a mechanism against it:** anyone can buy weETH from
the pool at a discount and exit at fair through ether.fi's **free** wait-NFT. At a 7-day queue, a 30 bps
discount is ~15.6% APR — well above hurdle. **So the discount is arbitrage-bounded, not linear**, and
the −76 bps at 90 days is very likely wrong.
⇒ 🎯 **But this makes the case for the NFT WORSE, not better.** The bound is set by *the ether.fi exit
  menu itself*, so the pool cannot durably be much cheaper than the queue — it can only offer
  immediacy, which is exactly what rung 3 already sells at 30 bps. **The −16 bps we measure is the arb
  being slow, not a durable edge.** *(OPEN — the arb bound is reasoned, not measured; measuring it
  needs the archival series.)*

## 3. `deliverableETH` — the Rover leg is uncapped, CONFIRMED; but the requested fix is the wrong shape
**Confirmed by code read:** `VaultLib._vogueETH:141-143` adds `IRover.valueWeth()` at full face;
`deliverableETH:203-204` runs `_deliverableCap` over **only** the three 4626 curators. *(✅ — structural.)*
⚠️ The docblock at `:182-200` **already says this** and warns off the fix: *"Do NOT 'fix' this by
rebuilding it as a ladder twin without first re-establishing a harm — the previous attempt rested on a
19.4%-short figure that measurement showed to be stale (~3%, and DEFERRED not lost)."*
**I could not re-establish the harm.** Both consumers tolerate over-statement: `Vogue:605-608` uses it
only to size `firstBurn` and then derives the shortfall from the ACTUAL `sent`, re-crediting the
remainder as recoverable `LP.pooled` (`:628`); `SwapLib.deleverEthOnDelivery` under-triggers into
`minOut` + deferral. ⇒ **Sourcing ORDER shifts; no value is lost.** *(OPEN — absence of harm is not
proof of safety, and I did not run the sim.)*

### ▶️ SPEC, if the NFT ships — and it is NOT a ladder twin, and needs NO venue-liveness gate
Do not cap against pool state; **cap against the rung that always works.** Rung 3 (instant redeem) is
the pool-independent floor at 30 bps, so count every **weETH-denominated** leg in `deliverableETH` at
that floor instead of at fair:
```
weETH leg counted as  getEETHByWeETH(x) * 997 / 1000     // the rung-3 floor, not the pool
```
Applied uniformly to the legs the docblock itself lists as full-face — Rover's `valueWeth`, weETH at
the Vault (`:124-127`), raw eETH (`:135-138`) — not to Rover alone.
- It **cannot go stale**, so the requested VENUE-LIVENESS gate (`feeGrowthGlobal` unchanged over a
  window) becomes unnecessary: a haircut that never trusts the pool cannot be fooled by a frozen one.
  A liveness gate is a clamp that would need its own window parameter, its own staleness failure mode,
  and would still be wrong the moment the pool un-freezes — **rule 3: attack the cause.**
- It **earns its place under the rule-3 inverse**: over-statement here is silent and plausible-looking.
- `vogueETH` (solvency) keeps full fair value — the free wait-NFT really does deliver fair, just not
  promptly. **The split is the point:** `vogueETH` = can we back it, `deliverableETH` = can we hand it
  over now. *(⏸️ SPEC'D, NOT WRITTEN — conditional on the ship decision. Money path ⇒ rule 15.)*

## 4. POOL SELECTION — the real defect is the OPPOSITE of the hypothesis
- 🔴 **`swapWeethForWeth` DOES NOT EXIST.** It survives only in four comments (`Rover.sol:61`, `:129`,
  `:259`, `Vault.sol:387`). The function was renamed to **`absorb`** (`Rover.sol:146`), which is a
  fair-rate IDLE-INVENTORY swap that never touches a pool — so it has no "order" to verify. **A comment
  describing past state, exactly as `CLAUDE.md` warns.** *(✅ finding — structural. Deleting the four
  comments is an ACTION and stays OPEN.)*
- The real routing is `SwapLib.offrampBody:604-613` (rung 1) and `sourceWethBody:708-717`, both looping
  `uint24[2] fees = [c.poolFee, c.poolFee2]` = **[A 0.05%, B 0.01%]** (`Vault.sol:348-349, :454`). *(✅.)*
- ⇒ ⛔ **The hypothesis "a fixed order can revert on B when A would have filled" is BACKWARDS.** A is
  tried FIRST, and the table in §1 shows **B is cheaper at every size below ~1,300 weETH**. A always
  fills inside the 50 bps budget, so **B — the better pool — is never reached.** The cost is not a
  liveness failure; it is **7–8 bps overpaid on every small offramp, silently.** *(OPEN — measurement.)*
- ⇒ ▶️ **Fix = reverse the array to `[B, A]` and set the budget below 30 bps (§4b).** That is
  size-aware and liveness-aware BY CONSTRUCTION, with no new machinery: B fills what it can, its cliff
  reverts it on `minOut`, A takes the remainder, and both fall through to rung 3 once drift has eaten
  the budget. **The pool's own quote already prices depth AND staleness** — the only bug was comparing
  it to the wrong benchmark. *(OPEN — money path, needs a test.)*

## 4b. 🔴 THE MINOUT IS SET ABOVE THE RATE IT EXISTS TO BEAT — the most purpose-relevant defect found
| site | budget | vs rung 3 |
|---|---|---|
| `offrampBody:610` rung 1 | `covered * 995/1000` ⇒ **50 bps** | ahead of a 30 bps rung |
| `sourceWethBody:707` | **50 bps** | — |
| `Rover._fairMinOut:189-192` | `(1e6−POOL_FEE)/1e6 * 995/1000` ⇒ **55 bps** on tier A | — |

⇒ ⭐ **The ladder is PERMITTED to pay 50–55 bps for an exit that rung 3 sells at 30, and it fails
  silently** — the swap succeeds, nothing reverts, the LP just receives less. **This is the owner's
  stated goal inverted, in one constant.** It is also the only finding here that is worth fixing
  **whether or not the NFT ships**, because it is on the offramp ladder, not on Rover.
⇒ Sizing: the budget must be **strictly below the instant-redeem rate**, all-in including the pool fee
  (~25 bps total is the natural choice — it leaves rung 3 as the strict fallback and makes every
  earlier rung genuinely cheaper). *(OPEN — money path, rules 10 + 15.)*

## 5. `_nearFair` / `_refreshAndRepack` — both confirmed, and there is a THIRD failure nobody named
**Confirmed as stated:** `_refreshAndRepack:79-82` reads `_slot0()` and repacks on
`getPrice(sqrtPriceX96)` — **pool spot, not `getRate()` fair**; `_repackNFT:199, 205, 226` refuses
mint/recenter/compound when `!_nearFair()`. *(✅ — structural code facts.)*

### 🔴 NEW — `take()` ROUND-TRIPS THE WETH IT IS ABOUT TO DELIVER
On-chain (verified this session): both pools have **token0 = WETH, token1 = weETH**, so in production
`token1isWETH == false`. *(✅ — immutable on-chain fact.)* Then:
1. Drift lowers weETH-per-WETH ⇒ the tick falls **below** `LOWER_TICK` ⇒ the position becomes **100%
   token0 = 100% WETH**. This is precisely §2's observed state (4,840 WETH : 1.0 weETH), i.e. the
   EXPECTED steady state, not an edge case.
2. `take()` calls `_refreshAndRepack(false)` **first** (`:601`). If `_nearFair` passes, `_repackNFT`
   burns the all-WETH position and `_mintOrCompound` enters the **mint** branch (`liquidity > 0`),
   whose `_swap` **MINTS weETH via the adapter with ~half that WETH** (`:494-508`).
3. `take()` then reads idle WETH (now ≈0), sizes a withdrawal, and **sells the weETH leg back on the
   pool at −24 bps** (`:629`).
⇒ 💸 **We already held the WETH. We converted half of it to weETH at fair, then sold it back at −24 bps
  — ≈12 bps of every delivery, paid for nothing.** The same mechanism runs on `_wrapIdle` (`:545-550`),
  which converts **all** idle WETH to weETH after every deposit/repack/compound, so Rover is
  architected to hold **no WETH** — while its stated job is to deliver WETH instantly.
⇒ 🔴 **And if `_nearFair` FAILS instead, the other branch is worse:** no recenter happens, and `take()`
  sizes with `getLiquidityForAmount0(sqrtCurrent, sqrtUpper, need/2)` (`:617`) while `sqrtCurrent` sits
  below the band. That range is wider than the real `[LOWER, UPPER]`, so `L` is understated and — with
  no weETH leg left to swap — the delivery is short by **more than half, silently** (`withdrawETH:414`
  try/catch, re-credited at `Vogue:628`).
⇒ ⇒ **Both branches of the expected steady state fail the purpose.** `_nearFair` is not the only gate
  that needs fixing; centring on fair (`getRate()`) is the precondition, and `take()` must prefer WETH
  it already holds over re-deriving it.
⚠️ **CODE READ, NOT RUN.** `RoverFork.t.sol` has exactly **two** tests (`test_compound_selfFundingTip`,
`test_deposit_mints_balanced_position_via_adapter`) — neither touches `take()`, out-of-range, or the
ladder. **Per rule 9 this is reasoned, not tested, and must not be called confirmed until a fork test
drives it.** *(OPEN.)*

## 6. JIT and LENDING — priced at last, and LENDING WINS OUTRIGHT
### ⛔ JIT — dominated. Do not build.
Two independent kills, both from §1(b):
1. **JIT earns the fee on OTHER people's flow.** External flow is ~0.6 WETH/30d ⇒ JIT income ≈ **0**.
2. **JIT cannot improve our OWN exit.** Minting depth and then trading through it returns our own
   capital minus gas — it converts "sell at −24 bps" into "did not sell", and we needed the WETH.
Also a scope error worth recording: `JIT-DEPTH-GUARANTEE.md` is about **Vogue's own band**
(`unwindForRedeem` / `addLiq` / `outOfRange`), where the protocol **owns the curve**. None of it
transfers to a guest position in a public pool — the same asymmetry §⚖️ above already established.
*(OPEN — reasoned, not measured. But #2 is arithmetic, so this is unlikely to reopen.)*

### ⭐ LENDING — this is the design that actually meets the stated purpose
**Do not sell the weETH at all. Borrow WETH against it, and repay from the FREE ether.fi queue.**
| | |
|---|---|
| **cost** | borrow APR × queue duration. **Breakeven vs the 0.3% redeem: ≈15.6% APR** at a 7-day queue, **≈7.8% APR** at 14 days. WETH borrow on Morpho/Euler runs far below either. |
| **immediacy** | a borrow fills in one block ⇒ **cheap AND immediate, which is the whole ask** |
| **yield** | keeps the ~2.4% staking accrual — §6b's "systematically converted OUT of the yield asset" loss **does not occur at all** |
| **surface** | no LVR, no pool dependence, no DoS surface, no venue-liveness question, no stranding |
| **plumbing** | `LevManager` already does borrow-against-collateral and is **venue-agnostic on collateral** (QUEUE §A.36); the Vault already supplies to Euler/Morpho 4626s |

⇒ 🎯 **The conclusion is robust to the unmeasured rate** — it holds for any WETH borrow rate below
  ~7.8% APR, which is a wide margin.
⚠️ **BUT TWO THINGS ARE UNMEASURED AND MUST BE BEFORE THIS IS MORE THAN A RECOMMENDATION (rule 9):**
  1. the live WETH borrow rate **and the weETH-collateral market's LTV + WETH-side liquidity** — the
     latter sets how large a single exit this can serve, i.e. it is the REAL answer to §1's "large
     enough", and it is the one number that could sink this;
  2. **it introduces a liquidation surface the LP design does not have.** weETH/ETH is correlated so it
     is small, but "small" is not "priced" — and the axis nobody measures is where the regression is.
*(OPEN — this is a recommendation, not a decision.)*

---

# 🚦 THE VERDICT
🔴 **DON'T SHIP THE NFT** — on §1(b), which is the load-bearing argument: **a liquidity position cannot
be its own counterparty**, so the NFT cannot satisfy the requirement it was created for
("large enough for instant conversion"). Everything else — the frozen venue, the ratchet, the stranding,
the DoS — is corroboration; §1(b) would hold even in a healthy pool.
📌 Note what this does **not** say: the un-pullability argument (§5 above) was always sound. It is just
that un-pullable **third-party** depth is what an exit needs, and ours cannot be that for us.

**Ship instead, in this order — the first is independent of the decision and should go regardless:**
1. **§4b — the `minOut` budget**, on the offramp ladder. One constant, largest purpose impact, lives
   outside Rover entirely, and is correct whatever happens to the NFT. *(OPEN)*
2. **§4 — reverse the tier order to `[B, A]`.** Free, measured, and makes routing size-aware with no
   new machinery. *(OPEN)*
3. **§6 — price the lending route** (both unmeasured items above). This is the candidate that actually
   delivers "cheap AND immediate". *(OPEN)*
4. **§3 — the rung-3-floor haircut** in `deliverableETH`, if and only if anything weETH-denominated
   stays counted at full face. *(⏸️ conditional)*
5. **§5 — the `take()` fork test.** Needed either way: `absorb`/`take` survive even if the NFT does
   not, and neither has a test today. *(OPEN)*

⚠️ **NOTHING ABOVE IS CLOSED.** Per standing rule 16 the only ✅ marks are structural code facts, the
on-chain token order, and the retracted log method. Every recommendation, measurement and spec stays
OPEN because the ship decision itself is still being weighed — and reversing it reopens all of them.
