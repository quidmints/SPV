# ROVER / weETH — what was measured on 2026-08-03, and what it means

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
**WETH is flat-to-up. Only the weETH side vanished.** In-range `L` fell 3.5M× (0.05%) and 25,000×
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
⚠️ Caveat: linear extrapolation of the measured drift. It ignores any new LP arriving (none has in 30d)
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
