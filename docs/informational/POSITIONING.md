# Positioning — the instrument, the regime call, and the field

⚠️ **Read `CLAUDE.md`'s warning about this folder first.** `docs/informational/` contradicts the
contracts in roughly ten verified places. Every claim below that touches the code was checked
against the code on 2026-08-16 and carries its `file:line`; anything unverifiable is marked as
such rather than asserted.

**This file deliberately does not restate `IL-VIA-BONDS.md`.** Cross-references, not copies:

| already written | where |
|---|---|
| the comp-mint drivetrain / cold start | `IL-VIA-BONDS.md` §5, §5.1 |
| why a depeg *prediction market* cannot offset over-issuance | §6 |
| the numismatic principle, and why panic cannot remove the dollars | §7, §7.3 |
| Lightning's dead-capital problem and what this lifts | §8.2, §8.3 |
| the YieldBasis comparison | §9 |
| the θ-budget cap and the honest TAM | §2.4.1, §2.4.2 |

---

## 1. The primitive is a bill, not a loan

The stack's distinctive instrument is a **dated, fully-backed, discountable claim on a known future
date**. It is not a loan, not a perpetual yield token, and not a wrapper. A holder knows the
maturity and the face; before maturity it trades at a discount.

That instrument has a name and three centuries of practice behind it: a **bankers' acceptance**, and
the discount market ran on exactly that. The useful consequence is that the pricing question is not
novel — a discount curve against a known redemption date is the oldest solved problem in credit.

The protocol therefore knows its **entire forward liability curve** at any moment: month *M* owes
*X*, *M+1* owes *Y*. That is not a stablecoin with an unpredictable redemption queue; it is a
scheduled liability stream, which is what a duration-matched insurance book is, expressed as a
token.

⚠️ *Unverified here:* the "nobody else in crypto issues one" claim is a market assertion, not a code
fact. It is not checkable from this repo and should be stated as a positioning view.

---

## 2. Leverage is a view, not a default — and the regimes split on path, not destination

The cleanest statement of the trade:

> the unlevered position's cost depends on **where price ends**; the levered position's cost depends
> on **how it got there**.

An unlevered depositor's IL is realised only at withdrawal, and the repack crystallises nothing
along the way, so their loss is a function of the final price. The lever is the opposite — it
borrows and buys as price rises, sells and repays as it falls, and every cycle costs spread on both
legs plus interest for the duration. **Path length, not destination.** So the regimes split on the
ratio of total path travelled to net move.

| regime | who wins | why |
|---|---|---|
| choppy, round-tripping swings | unlevered | two spreads per cycle against IL that reverts for free; the de-lever range suppresses small oscillations but large ones trigger it. **ETH's most common regime.** |
| rise then fall | unlevered, clearly | bought with borrowed money up, sold it down — buy high sell low, on the buffer specifically, realised through `_deleverFlash` (`LevManager.sol:34`, `:500`) |
| low volume | unlevered, outright | fees on the buffer ≈ 0, so the amplification argument evaporates while carry is still paid |
| long horizon, no forced exit | unlevered | IL is impermanent *for you* in the strict sense; paying carry to hedge something that resolves itself is negative EV |
| sustained directional move | levered | drift exceeds churn |
| high volume | levered | fee capture on doubled depth dominates carry |
| exit timing not your choice | levered | impermanent loss may be permanent *when it matters* |

**Two things worth drawing out.**

**The lever is not downside protection.** The target is zero at or below entry, so a depositor
expecting a fall gains nothing and pays spreads and interest to discover that. Bearish or flat
view ⇒ it is strictly a cost.

**It is a view, not a default.** The decision reduces to whether you expect net drift to exceed path
churn over your holding period. That is a market call, which is exactly why it is **opt-in per
depositor** rather than something the protocol does on everyone's behalf.

### 2.1 The open tension: leverage against socialised LVR

Stated as a tension because it is one, not as a feature.

To give LPs a linear claim, AMM rebalancing loss is transferred from the LP to the shared basket
surplus. A levered LP puts a larger in-range position to work, generates amplified LVR, and that
amplified loss lands on the **same shared surplus** — so a levered LP consumes more of the common
buffer than its share. In a per-position AMM each LP eats its own IL and leverage is not an
externality; the linear-claim design makes it one.

- **calm:** net beneficial — more capital, deeper liquidity, faster surplus growth
- **stress:** net harmful — amplified LVR drains the shared surplus faster, thinning the buffer for
  LPs who never levered

This is the strongest internal argument for keeping leverage opt-in and bounded, and it is the axis
to measure before loosening either.

---

## 3. Why we refuse the toxic refill — and what we buy instead

A constant-product AMM keeps inventory balanced by letting arbitrageurs trade against its own
**stale** price: the market moves, the pool lags, arbers realign it and pocket the gap. That is LVR,
and it means inventory is kept full **by picking off the LPs**.

We refuse it: oracle pricing ⇒ no stale price ⇒ no LVR to harvest. But refusing it has a cost —
inventory no longer refills itself for free. So the rebalancing has to be **bought** rather than
extracted, and the skew is the purchase price: paid by the trader who created the exposure, handed
to the LP who bears it. That is the Avellaneda–Stoikov reservation premium — the price of inventory
risk.

**This is also why "refill" is not a component.** Representing inventory we already hold is the
repack's existing pairing step (`QuidLib.addLiq:341-372`, which ends `targetUSD = deltaTok·price`
— equal value on both legs). Acquiring inventory we do **not** hold cannot be done by any reseat;
it needs a counterparty bringing real BTC or ETH, priced by the skew.

🔴 **CORRECTION — the "swap-in bonus" does not exist.** `payRefillBonus` was **removed 2026-07-22**
(`Core.sol:404`, `Vault.sol:432`, `SwapLib.sol:659`), and the code says *"paying a swapper a bonus
is exactly what the removal was meant to stop… Do NOT rebuild it."* The **actor** is real — an
active party holding BTC in reserve for JIT — but they are compensated by the **retained skew
premium staying with LPs as backing**, not by a bonus paid to the swapper.

---

## 4. The field

### 4.1 Cork — depeg swaps, and why the premise is unpriceable

Actuarial pricing needs an observable base rate, an exogenous hazard, and independent risks. A peg
breaks all three:

- **the base rate is unobservable** — a peg sits at ~1.0 until it doesn't, then jumps regime.
  Bimodal, almost all mass at par, thin catastrophic tail, and each peg is *sui generis*, so there
  is no frequency data to estimate the tail from.
- **the hazard is reflexive** — a depeg is a confidence/coordination failure, so the price of the
  insurance feeds back into the probability of the event. Spiking depeg-swap prices are themselves a
  run signal. You cannot price a hazard whose probability is a function of its own price.
- **the risk is perfectly correlated in the only state that pays** — depegs cluster in liquidity
  crises (USDC March 2023 dragging DAI through its collateral; UST/LUNA; the LST cascade). The
  underwriter collects small premiums in calm and is wiped out exactly when many pegs break at once,
  and the underwriting collateral is usually the same asset class being insured, so payout capacity
  evaporates precisely when claims arrive.

There is also no replicating portfolio: the underlying gaps discontinuously, so you cannot
delta-hedge through the gap, and there is no deep options surface to back out implied probabilities.
A market-implied clearing price for a reflexive, correlated, un-hedgeable tail is not an actuarial
price — it is the momentary agreement of two speculative crowds. **The implementation was elegant;
the premise was unpriceable.** Structural, not a tuning problem.

⇒ If you cannot price the tail of any single peg, the robust move is to never take a concentrated
bet on any single peg's survival: **bound the risk by breadth instead of pricing it.** (This is the
same conclusion §6 reaches for prediction markets, by a different route — do not read the two as
independent confirmations.)

### 4.2 Bunni — an LDF that deprived its own arbers

Bunni's hook replaced native mechanics with a Liquidity Distribution Function rebalancing the pool
after every trade to maintain token ratios. By doing the arb **itself** it removed the discrepancy
arbers exploit — no discrepancy, no arb, no arb fee flow. The pool ate the arb profit through the
rebalancing mechanism instead of letting external parties capture it and return it as fees. Arb
volume is typically the majority of fee revenue in volatile pairs, so LPs got less fee revenue than
a vanilla pool at the same TVL — while still paying the rebalancing cost in gas and hook overhead.

🔴 **CORRECTION — our range is ±0.2%, not ~2%, and the cited call does not exist.** `RANGE_DELTA = 20`
(`SwapLib.sol:732`), i.e. **±0.2%** — an order of magnitude tighter than the "~2% range" the draft
claims — and there is no `_updateTicks(sqrtPriceX96, 200)` call in the tree.

The contrast is also **stronger** than the draft states, as of 2026-08-16: we no longer store range
bounds at all. The 1:1 composition is `tokPlaced·px == usd6Placed` — a function of inventory and
price, with no width term — so we are not "a simpler LDF", we are not on that axis.

### 4.3 Pendle — two tokens, a decaying curve, fragmented liquidity

Pendle wraps a yield-bearing asset, splits it into PT (redeems 1:1 at maturity, trades at a discount
before) and YT (captures yield to maturity), and trades them on a time-decaying AMM whose rate
anchor and scalar must be re-parametrised as expiry approaches, with liquidity fragmented per
maturity.

Four axes where a bill is simpler:

1. **no token split** — yield accrues to the reserve and is reflected in the scheduled redemption;
   one instrument, not PT+YT
2. **no bespoke decaying AMM** — redemption is on a known schedule against the reserve, so there is
   no secondary curve to maintain and no keeper re-parametrisation risk
3. **no liquidity fragmentation** — maturity is an accounting stamp, not a separate pool
4. **matched yield, not stripped-and-sold** — the yield stays inside the reserve servicing the bond,
   so it is self-funding with positive carry and needs nobody to buy the strip

### 4.4 mStable — the only comparable basket

Works exogenously with Pendle; does not redeploy the stables to Morpho or Aave, and has **no
endogenous yield** — it does not trade the stables against each other, or against ETH/BTC.

### 4.5 The throughline

Cork and Bunni both died by adding expressive machinery on top of V4 — an unpriceable insurance
market, a per-trade liquidity-reshaping LDF — and Pendle carries structural overhead in the split,
the decaying curve, and per-maturity fragmentation. **Our edge everywhere is subtractive:** bound
risk by diversification instead of pricing it; hold one range around the oracle instead of a
continuous distribution; redeem on a schedule instead of on a maintained curve. The minimalism *is*
the safety argument.

---

## 5. Corrections ledger

Claims in circulation that the code contradicts, so they are not repeated downstream.

| claim | status | evidence |
|---|---|---|
| "a ~2% range via `_updateTicks(sqrtPriceX96, 200)`" | 🔴 wrong on both counts | `RANGE_DELTA = 20` ⇒ ±0.2%, `SwapLib.sol:732`; no such call exists |
| "the swap-in bonus is for a JIT actor" | 🔴 instrument removed | `payRefillBonus` deleted 2026-07-22 — `Core.sol:404`, `Vault.sol:432`, `SwapLib.sol:659` |
| "we froze the fee and built a separate adaptive scalar beside it" | 🟠 historical | the skew now carries a base charged on **all** flow (§UNIT-A), so the skew *is* the fee; `swapFeePpm()` is a disclosure accessor that charges nothing, and the 420 is a v4 pool tier |
| "solvers quote the exact number a swap executes at" | ✅ **fixed 2026-08-16** | was the instantaneous rate while settlement charges the §E68 integral — a 90%-of-range drain filled **4.12×** worse than quoted. `wellSkew(asset, drainUsd6)` added; `Aux.sol`, `ISwap.sol` |
| "range bounds are stored" | ✅ no longer true | `deltaBps`/`pLower`/`pUpper` deleted; composition is width-independent |
