# OWNER-DECISIONS — the 17 rulings that unblock the file, in one pass

Reduced from **115 lines** in `SPRINT.md` matching *owner decision · owner must · blocked on a person ·
owner ruling · OWNER-BLOCKED* to **17 distinct open decisions**. Every one below was re-verified against
the tree on 2026-09-08 by grepping a quoted phrase, not by trusting a cited line number. Everything
struck is in Appendix A (already ruled) or Appendix B (not a decision / subject deleted).

⚠️ Coordinates below were re-read on 2026-09-08 and **the tree is being edited concurrently** — two files
moved by 14-17 lines between two reads in the same session. If a line number does not land, grep the
quoted phrase; the quote is the identifier, the number is a convenience.

🔴 **ADVERSARIAL RE-VERIFICATION, 2026-09-08 (second pass) — TWO STRIKES WERE OVERTURNED AND ONE
DECISION WAS MIS-STATED.** The first pass struck 27 rows; two of those strikes removed live decisions
from the queue, and they are restored below as **16** (`§E332-c`) and **17** (the swap-IN remainder).
Both failed the same way, and `SPRINT.md:7600-7612` already records that exact failure with these very
rows as its worked examples: *"its cited line was deleted, so I marked the premise withdrawn. **The
deletion killed the CITATION, not the design question**"*, and *"its wording is literally false … **but
its CONCERN is PRODUCTION wiring**."* ⇒ **A mechanism's deletion does not answer the question the
mechanism posed.** Decision **8** is additionally re-stated: its question as written was already
answered by measurement.

| # | question | unblocks | recommendation |
|---|---|---|---|
| 1 | Is an ETH depositor owed **ETH**, or **value**? | 4 rows retired + 3 gated | settle in value |
| 2 | Should a range that is deep relative to its flow pay the **kernel**, or only depletion? | 5 void controls, §E326, §E278 | charge the kernel |
| 3 | When σ² is unmeasured on a **flush** swap, charge the ceiling or ~nothing? | same 5 + §SKEW-COVERAGE-HOLE | charge the ceiling |
| 4 | Zero-debt levered equity: **deliver it** or **stop counting it**? | §M.1b, L4 item 1 | stop counting it |
| 5 | Pooled Morpho venue: restore **per-LP isolation** or **disclose the subsidy**? | §CROSS-SUBSIDY, §E342, §POOL-VENUE | disclose and cap |
| 6 | Should a **swap-in** pay the BTC LPs anything? | 1 inverted test, §E145 cluster | no — leave it |
| 7 | Is the **fleet** willing to be principal on the LN leg? | 6 deleted rows stay dead | yes — ratify |
| 8 | Do the **two-source guards** get a second source, or are they declared vacuous? | §E222, §E274 — **does *not* gate 2/3** | one source, say so |
| 9 | Which range BTC is mintable as **vBTC**? | §E251, §C3, §V-R10 shape | levered slice only |
| 10 | What is the **key-recovery** trust anchor? | `#14`, §LADDER-VALUE-IS-CONDITIONAL | second registered key |
| 11 | What is the LP **seed entropy** mix *for*? | §LP-SEED-ENTROPY, §M1#2(c) | freshness, not secrecy |
| 12 | **θ or the lever** — which instrument carries linearity? | GATE 2.5, 6e, 7a | θ first, lever for tail |
| 13 | Mint the **position token** to the LP on both legs? | `B8` / ERC-7540 | yes, both legs |
| 14 | Does a depositor capture the mark's **recovery upside**? | `test_E2_MintAtMark_*` | no — par plus yield |
| 15 | Who bears a **stranded reversal remainder** (swap-**OUT**)? | `reverseSwapOut`'s `requireFull` | hop bears it |
| 16 | Should an **out-of-range intent fill** pay the inventory term? | §E332-c, §E331 #1, couples to 2 | yes — price it at rest |
| 17 | Who bears a stranded **swap-IN** remainder, and must the chain see it? | §LN-SWAPIN-REMAINDER, §NO-REJECT | gated on 7 — see below |

**THE THREE ENTANGLED PAIRS. Answer each pair in one sitting or the second half is decided by accident.**
- **2 ∥ 3** — two questions about the **same two `return` statements** (`SwapLib.sol:1382` and `:1445`).
- **2 ∥ 16** — `SPRINT.md` names them together, twice, as the only two live execution levers:
  *"the live levers are `§E332`'s unpriced OOR discount and `§E330`'s flush exemption"* (`:22271`, and
  again at `:22339`). Both are "which flow escapes the skew"; answering one and not the other just moves
  the escape. §E331 #1 says it outright — *"do not settle one without the other."*
- **7 ∥ 17** — decision 7 answered **yes** is what pushes the swap-IN remainder off-chain into the
  fleet's hands (`§FLEET-FRONTS-THE-WINDOW` cost 4: *"Partial fills move off-chain … the fleet now
  decides what to pay its own counterparty"*). Answered **no**, §HOP-BOND returns and 17 comes straight
  back on-chain. **17 is not answerable before 7.**

⛔ **THE ORDERING CLAIM THAT STOOD HERE — *"decision 8 changes what 2 and 3 are worth, so take 8 first"*
— IS WITHDRAWN, AND IT WAS WRONG BY MEASUREMENT, NOT BY OPINION.** `Core.sol:1680`: *"⇒ **CONSEQUENCE
FOR ANYONE SIZING THIS WORK: σ² NEEDS NO INDEPENDENT SOURCE.**"* §E343 sampled 60 consecutive Chainlink
ETH/USD rounds and measured **57.3 updates/day, 20.5-min median gap, 0.53% median move, implied
annualised σ = 95.5%** — and `realizedVarianceWad` is `max(ringVariance, anchorVarianceWad)`
(`Core.sol:440`), so the anchor leg already carries σ² whether or not a ring source is ever pinned.
**Pinning a source does not change what the flush branch is worth.** 2 and 3 are independent of 8.

---

## 1. Is an ETH depositor owed ETH, or owed value?

**The question.** When the range holds less ETH than the pro-rata claims imply, does the protocol owe
each depositor *ether*, or does it owe *dollar value settled in whatever the basket is abundant in*?

**Why it needs a person.** Nothing measures it. Both readings are solvent, both are implementable, and
the tree has shipped machinery for the first (`onShortfall`, `btcShortfall`, the shortfall trigger)
without ever stating that the obligation had to be denominated that way.

**The evidence.**
- `evm/src/Quid.sol:1496` — `function onShortfall(address, uint) external {}` with the docblock above it:
  *"Real ETH demand is met fairly at withdrawal instead… Do not 'implement' this."* The ETH remediation
  is already a deliberate no-op.
- `evm/src/Core.sol:995` — `RANGE.onShortfall(sender, shortfall);   // ETH: a deliberate no-op`, fired
  from `_shortfallLoadBalance` at a 1% threshold.
- `SPRINT.md` §PLP-R3: conditions (1) *range ETH below claims* and (2) `onShortfall` are both marked
  eliminable by option F; (2) *"exists only to refuse to fix (1)"*.

**The options.**
- **(F) value-denominated.** Condition (1) becomes a composition reading, (2) has nothing left to refuse,
  `§4796-4812` is retired rather than answered, and `RangeLib.onShortfall` leaves the dead-code table by
  being unnecessary. Makes impossible: any promise that a withdrawal returns ether specifically.
- **(asset-denominated) keep it.** Then `onShortfall`, `btcShortfall` and the trigger must all be wired,
  bounded, tested and documented — §BTC-2.6, §PLP-14 and §PLP-U option D all become real work.

**My recommendation.** Take F. The ETH side already behaves that way in code and has for long enough
that the alternative would be new construction, not a restoration.

**What it unblocks.** §PLP-R3 conditions 1 and 2, `§4796-4812`, §PLP-X's dead-code row, §BTC-2.6,
§PLP-14, §PLP-U option D. `SPRINT.md` calls it *"the highest-leverage item not gated on measurement."*

---

## 2. Should a range that is deep relative to its flow pay the kernel, or only depletion?

**The question.** When inventory ends at or above the flow target, the swap skips the `Γ·σ²·q` kernel
entirely and pays only a size-based depletion term. Is that the intended charge on ordinary flow?

**Why it needs a person.** It is the whole of LP revenue since the flat fee was deleted, so it is a price,
not a bug. Either answer is internally consistent; the tree cannot tell you which one it meant.

**The evidence.**
- `evm/src/imports/SwapLib.sol:1445` — `if (inv1 >= target) return _maxWellSkew(sigmaSqWad, rk) + _depletion(inv0, inv1);`
  and its twin at `:1382` for `target == 0`. Neither reaches the kernel. ⚠️ **BOTH ARMS NOW CARRY
  `+ _depletion` — the `target == 0` twin gained it in §E352-DEPLETION.** The two arms return the
  identical expression today, so the branch is a shortcut, not a distinct price; only the *order*
  against the σ² sentinel still differs, and that is decision 3.
- 🔴 **THE "ONLY LANE LEFT" ARGUMENT DIED THIS MORNING AND THE ROW MUST NOT BE READ WITHOUT IT.**
  `d047fd6e` (§MIN-SWAP-FEE, **2026-09-08**) restored a floor: `SwapLib.sol:823`
  `uint public constant MIN_SWAP_SKEW_WAD = 4.2e14;` — *"420 ppm — the floor, on every swap"* — applied
  at **both producers**, `wellSkew` (`:1935`, `max(_amplify(...), MIN_SWAP_SKEW_WAD)`) and `sellSkew`'s
  composer (`:2116`), *"APPLIED AT THE PRODUCERS, NOT AT `retainSkewPremium`, so the published QUOTE
  carries it."* Owner, 2026-09-08: *"the minimum swap fee was just the fact that all swaps even balance
  restoring must pay at least the minimum."* ⇒ **`Core.sol:1497`'s *"§E311 — THE FLAT 420 ppm IS GONE"*
  is now a historical note, not the premise of this decision.** The flush branch is no longer the only
  lane, and the question narrows to: **above the 420 ppm floor, does ordinary flow owe the kernel?**
  The floor bounds the loss; it does not price scarcity, and it is `σ²`-blind.
- Measured in `SPRINT.md` §E330: inside the flush branch at σ²=0, 10,054 → 19,385 → 32,536 **ppb** across
  6/12/20 drain rounds — linear in depth, ~1,630 ppb per round. (Measure in ppb; 0.325 bps prints as 0.)

**The options.**
- **(a) flush is exempt from the kernel** — a deep range earns depletion only. Then the five
  `DrainAtomicity` `CONTROL:` guards and `test_V2_EqualLpsEarnEqualFees` encode the retired flat-fee model
  and must be rewritten to drive scarcity first.
- **(b) the kernel applies before scarcity** — LPs earn on ordinary flow; the flush exemption narrows to
  refills only. Makes the charge σ²-sensitive everywhere, which is what decision 3 then has to price.

**My recommendation.** (b). The exemption was justified by a settlement-window argument that is
~0.000233 bps on ETH (recorded at `SwapLib.sol:1437`) while depletion is ~2.1 bps — the term that was
supposed to carry the branch does not carry it.

**What it unblocks.** The 5 `DrainAtomicity` controls, §E326, §E278's second half, §SKEW-COVERAGE-HOLE,
and `test_V2_EqualLpsEarnEqualFees` / `E41` / `Matrix_S1`'s *"PREMISE: fees actually accrued"*.

---

## 3. When σ² is unmeasured on a flush swap, charge the ceiling or ~nothing?

**The question.** Two functions read `σ² == 0` and disagree — the sentinel says *charge the ceiling*,
`_maxWellSkew` says *charge `spliceFloor`* (which is 0 on ETH) — and branch order, not a decision, picks
the second. Which resolution is right?

**Why it needs a person.** "Unmeasured" is a policy word. Neither answer is more correct arithmetically;
one is conservative to the LP, one to the swapper.

⚠️ **"~NOTHING" IS NOW 420 ppm, NOT ZERO — AND ONLY AT THE PRODUCER.** §MIN-SWAP-FEE (`d047fd6e`, today)
floors `wellSkew` and `sellSkew` at `MIN_SWAP_SKEW_WAD = 4.2e14`. It does **not** floor `skewWad`, which
is where both flush returns live, so the arithmetic this decision is about is unchanged and still
returns 0 on ETH at σ² == 0. What moved is the *stake*: the spread between the two answers is now
ceiling-vs-420 ppm rather than ceiling-vs-zero.

**The evidence.**
- `evm/src/imports/SwapLib.sol:1394-1397` — *"THIS RETURN AND THE `target == 0` TWIN ABOVE SIT BEFORE THE
  σ² SENTINEL, SO ON THESE TWO BRANCHES THE PERMISSIVE RESOLUTION WINS AND THE 3e16 SENTINEL NEVER FIRES."*
- `evm/src/Core.sol:345-347` — *"IT IS THE SENTINEL, NOT `_maxWellSkew`, THAT CHARGES THE CEILING — and the
  two DISAGREE, which is §E352."*
- `evm/src/imports/SwapLib.sol:1414-1424` — the test cited as covering this cell,
  `SkewUnmeasuredVariance.t.sol::test_FlushRangeStillOwesOnlyTheBase`, asserts `assertLt(flush, CEIL)`,
  which `0 < 3e16` satisfies **by the defect**. The branch reads as covered and is not.

**The options.**
- **(ceiling)** move the sentinel above both flush returns. Closes the free-drain hole §E59 closed once;
  makes a flush swap expensive whenever the oracle is quiet or stale.
- **(permissive, ratified)** leave the order and say so at the site. Then §UNIT-A's *"return the base, not
  zero"* is permanently neutralised on ETH, because at σ²=0 the base *is* zero.

**My recommendation.** Ceiling. `Core.sol:345` already states the house rule in its own words —
*"0 means UNKNOWN, NEVER 'calm'"* — and this is the one place the code does not obey it.

**What it unblocks.** Same five controls as decision 2, plus §E278's flush half.
✅ **THE INSTRUMENT THIS SECTION ASKED FOR ALREADY EXISTS — DO NOT ADD IT AGAIN.** The first pass said
*"before landing either, add `assertEq(flush, 0)`"*; measured 2026-09-08, it is at
`evm/test/SkewUnmeasuredVariance.t.sol:92`, carrying its own instruction: *"SE352 CELL, NOT 'the base' …
Pending the SE278 owner call. **When that lands this MUST go red — update it to the decided value.**"*
⇒ **The cell is instrumented; the ruling is the only thing missing, and the test will announce the
moment it arrives.**

---

## 4. Zero-debt levered equity: deliver it, or stop counting it?

**The question.** Collateral held against no debt is counted as protocol backing and cannot be delivered.
Do we build the release path, or remove it from the count?

**Why it needs a person.** Delivering it needs a value-attribution rule that does not exist — who is
credited when collateral is freed against no debt. That is a fairness choice, not an arithmetic one.

**The evidence.** (Bodies, not docblocks.)
- `evm/src/imports/LevMath.sol:222-223` — `buffer = collValueUsd * (safeLtv - curLtvBps) / safeLtv;
  return netEquityUsd < buffer ? netEquityUsd : buffer;`. At `curLtvBps == 0`, `buffer == collValueUsd`,
  so the whole net equity is returned and `LevBase.sol:544` sums it across the book.
- `evm/src/imports/SwapLib.sol:2529-2531` — `uint amtNative = poolDebtUsd == 0 ? 0 : …` then
  `if (amtNative == 0) return 0;`. None of it is deliverable.
- Measured green: `testReal_M1b_ZeroDebtEquityIsCountedDeliverableButIsNot` — counted **13,741.61 USD**,
  delivered **0 wei**.

**The options.**
- **(A) deliver it** — free the collateral and credit the LPs (e.g. the range buys the ETH at oracle,
  crediting `POOLED_USD`). Needs the attribution rule; `withdrawPool` writes no per-LP unit, so a naive
  pooled release is an uncompensated transfer from every LP to the payee.
- **(B) stop counting it** — return 0 from `deliverableDollars` when the delivery path cannot reach it.
  No new machinery; reported deliverable backing falls by exactly the measured amount.

**My recommendation.** (B) now, (A) later if the number grows. Doing neither is the status quo and it
overstates solvency by exactly this figure.

**What it unblocks.** §M.1b, L4 priority item 1, and the §M.1-SETTLED `swapOutDeliverUnlevered` KEEP
verdict stops being read as licence to implement the branch.

---

## 5. Pooled Morpho venue: restore per-LP isolation, or price and disclose the subsidy?

**The question.** One shared Morpho position means a liquidation caused entirely by one LP hits every LP
pro-rata. Do we take back per-LP isolation, or keep the O(1) repay and disclose what joining costs?

**Why it needs a person.** Both sides are real and priced. It is a product positioning call about what an
LP is buying, and reversing it undoes a shipped gas optimisation.

**The evidence.**
- `evm/src/imports/LevVenueBase.sol:200` — *"THE LARGER COST IS THAT PER-LP LIQUIDATION ISOLATION IS
  GONE… a liquidation hits EVERY LP pro-rata and the position is protocol-side, so isolation is
  PROTOCOL-ENFORCED rather than MORPHO-ENFORCED."* The file names the test that should measure it.
- Measured green, real Morpho: `LeverageCrossSubsidyProbe.test_LateZeroDebtLp_PaysForTheEarlyLpsLiquidation`
  — late LP collateral 5.000000 → 2.599165 ETH, **4,801 bps** paid by an LP asserted at `debtOf == 0`
  before and after. That is ~32× §E338's worst-case convexity figure, on a different axis.
- The subsidy runs both ways: the first probe version got `position is healthy` from Morpho because the
  late LP's zero-debt collateral was propping up the early LP's aggregate.

**The options.**
- **(isolation back)** reverses §POOL-VENUE / §E342: swap size is again capped by how many per-LP repays
  fit in a block, and that cap tightens as the book grows. Restores Morpho-enforced isolation.
- **(keep pooled, disclose)** the O(1) repay survives; joining must be priced or gated as what it is —
  and `cascadeDelever` plus `LevBase._bandBps` become the only things standing between the book and a
  4,801 bps event. Neither is a guarantee today.

**My recommendation.** Keep pooled and disclose, but only alongside a hard cap on the aggregate LTV the
band is allowed to reach. The gas win is real; the unbounded version of it is not defensible.

**What it unblocks.** §CROSS-SUBSIDY-MEASURED, §POOL-VENUE, §E342's O(1) claim, and L4's ordering.

---

## 6. Should a swap-in pay the BTC LPs anything?

**The question.** When the protocol sells BTC into its own pool against LP inventory, should the LPs be
paid a fee for that inventory?

**Why it needs a person.** It is a money-path change with no defect behind it — nothing is broken today,
the charge simply does not exist. The measurement is complete; only the preference is missing.

**The evidence.**
- `evm/test/Alles.t.sol:5094-5100` — instrumented across `creditSwapIn` on the pinned gate, **every**
  candidate accumulator is flat: `POOLED 17,503,967 → 18,003,967` (the swap-in exactly, nothing retained),
  `USD_FEES` unchanged, `skewPremium` unchanged, `feesPerShare 0 → 0`. The synonym check covered
  `USD_FEES`, `skewPremium`, `POOLED_USD`, `basketUsd` and `lpShares`; none moves.
- `evm/src/imports/BtcLib.sol:418` — *"⛔ (§V4-CUT) NO FEE DISTRIBUTION HAPPENS HERE, so `o.feesPerShareInc`/
  `o.usdFeesInc` come back zero"*, and `QuidLib.sol:329` — *"whether per-share accrual comes back is the
  deferred decision."*
- The test's assertions were inverted to `assertEq` on 2026-08-28 so the gap announces its own resolution;
  they carry the restore instruction in their failure messages.

**The options.**
- **(no)** the swap-in is protocol plumbing and pays nothing. Restore nothing; the inverted assertions
  become permanent and the `assertGt` instruction should be deleted from them.
- **(yes)** extend the skew lane to `creditSwapIn`, or bring back a trading-fee leg. Changes what a
  swap-in costs the protocol, and a `!r.didRepack` guard is required (`BtcLib.sol:419-421`) or a
  repack-and-reseat pays fees out.

**My recommendation.** No. The protocol is on both sides of that trade; charging itself moves value from
`POOLED` to `feesPerShare` and back with nothing entering the system.

**What it unblocks.** `testBtcLp_swapInAccruesTheBtcLegFee`, the §E145 cluster's *"where does the fee
land"* question, and the last row of `Alles`'s owner-gated list.

---

## 7. Is the fleet willing to be principal on the LN leg?

**The question.** The Lightning leg is now seller ⇄ **fleet** (an ordinary off-protocol payment) and the
protocol only ever pays against an SPV-proven deposit. Is the fleet willing to front that working capital?

**Why it needs a person.** It is a business risk allocation, not a code property. The code has already
shipped both ways round; what is missing is the owner saying the fleet accepts the exposure.

**The evidence.**
- `evm/src/BTCChannels.sol:2098-2100` — *"Partials are accepted on this rail: the seller's remainder is
  refundable trustlessly via the deposit's own CLTV leaf, which is exactly why the on-chain rail can take
  them and the all-or-nothing LN rail cannot."*
- `settleSwapInProven` (`BTCChannels.sol:2090`) is the only credit path and places no restriction on
  `terms.seller`, so the fleet can name itself and prove its own deposit. `settleSwapInBuffered`,
  `proveHopReserve` and `provenSatsAvailable` have **zero declarations** in `evm/src`.
- `SPRINT.md` §FLEET-FRONTS-THE-WINDOW records this as *executed 2026-08-30 (`32168f74`)*, a net deletion.

**The options.**
- **(yes)** ratify. Nothing to build. Costs: the fleet fronts USD sized to in-flight LN volume and carries
  the price move to reconciliation; the LN seller's counterparty is explicitly the fleet.
  ⚠️ **AND A FOURTH COST THE FIRST PASS DROPPED, WHICH IS WHY DECISION 17 EXISTS.**
  `§FLEET-FRONTS-THE-WINDOW` lists it: *"**Partial fills move off-chain**: `requireFull` existed because
  the LN rail cannot refund. **The fleet now decides what to pay its own counterparty**, and the pool
  sees only a proven deposit."* Ratifying **yes** does not delete the who-bears-the-remainder question —
  it *relocates* it to the fleet, where three sub-policies are already set in Rust and none is written
  down as a term. **Answer 17 in the same breath.**
- **(no)** fall back to §HOP-BOND — the hop posts an EVM-side bond the contract holds, a credit consumes
  bond, and `proveHopReserve` becomes the release path. That is rebuilding what was deleted.

**My recommendation.** Yes — ratify. The alternative reintroduces a mechanism whose deletion is already
shipped and tested, and the pool's exposure is zero by construction under the current shape.

**What it unblocks.** Keeps §RESERVE-HAS-NO-RETURN-PATH, §LN-SWAPIN-RAIL-BROKEN and §HOP-RCE-3's
buffered half closed rather than reopened, and settles §T1-e's ordering question by removing the rail.
**It also gates decision 17**, which cannot be answered until this one is.

---

## 8. Do the two-source GUARDS get a second source, or are they declared known-vacuous?

🔴 **RE-STATED 2026-09-08. THE QUESTION AS FIRST WRITTEN — *"does the σ² ring get an independent
source?"* — IS ALREADY ANSWERED, BY MEASUREMENT, IN THE CODE.** `Core.sol:1680`: *"⇒ **CONSEQUENCE FOR
ANYONE SIZING THIS WORK: σ² NEEDS NO INDEPENDENT SOURCE.** §E222's independent-source rule is scoped to
`twapResolve`'s deviation test and `BasketLib.isManipulated` — guards that need two sources able to
DISAGREE. σ² is a…"* §E343 measured the anchor at **57.3 updates/day, 20.5-min median gap, 0.53% median
move, implied annualised σ = 95.5%**, refuting the *"a Chainlink-sourced ring would measure σ² ≈ 0"*
intuition that made an independent σ² source look necessary. **Asking the owner to rule on σ²'s source
would be asking them to re-decide a measurement.**

**The question.** `observationSource` is unset, and there is exactly one price source in production.
Two guards are built on there being two — `twapResolve`'s deviation test and `BasketLib.isManipulated`.
Do we fund a second source for those, or delete the two-source framing and record that they are vacuous?

**Why it needs a person.** Both named candidates are unusable, so this is not "pick the best source" — it
is "accept a weaker property, or fund building a new source." That is a risk-appetite call.
⚠️ **AND IT IS NARROWER THAN IT LOOKS: NOTHING IN THE PRICING PATH DEPENDS ON THE ANSWER.** Only the two
manipulation guards do.

**The evidence.**
- `evm/src/Core.sol:1698-1712` — *"§OBSERVATION-SOURCE-UNSET — THE RING FEEDS ITSELF FROM THE CHAINLINK
  ANCHOR WHEN NO EXTERNAL SOURCE IS PINNED. `setObservationSource` has ZERO non-test callers and no deploy
  script calls it."* It then rules out both candidates in place: Curve's EMA (TriCrypto removed entirely)
  and 1inch `getRate` (*"§E232 measured it at 31.7M gas, past a whole block"*).
- `evm/src/Core.sol:1530-1533` — *"`address(0)` DOES NOT MEAN 'no observations'… What a zero costs is
  INDEPENDENCE, not liveness."*
- `evm/src/imports/OracleLib.sol:459-465` — `oneInchRateWad` and `curvePriceWad` have zero call sites and
  are deliberately preserved: *"Whoever wires them also owns the agreement check that consumes them; none exists yet."*

**The options.**
- **(accept one source)** delete the §E222 disagreement framing and say in the docs that the ring and the
  anchor are the same source. Cheap, honest, and `isManipulated` / `twapResolve`'s deviation test become
  known-vacuous rather than silently vacuous.
- **(build independence)** fund a new non-circular source. Nothing on the shelf qualifies; unverified what
  it costs.

**My recommendation.** Accept one source and record it. Independence that cannot be bought at any
affordable gas price is not a decision being deferred, it is a property we do not have.

**What it unblocks.** §E222 and §E274's *"blocked on §C1"* status.
⛔ **IT DOES NOT GATE DECISIONS 2 AND 3, AND THE CLAIM THAT IT DID WAS WRONG.** `realizedVarianceWad` is
`max(ringVariance(), anchorVarianceWad())` (`Core.sol:440`), so the anchor already supplies σ² whether
or not a ring source is pinned — pinning one cannot change what the flush branch is worth. Take 2 and 3
in any order relative to this.

---

## 9. Which range BTC is mintable as vBTC?

**The question.** Today only the levered slice can back vBTC. The design wants out-of-range locked BTC
mintable and lendable too. Which BTC is eligible?

**Why it needs a person.** It trades LP yield against swapper deliverability, and the answer determines
whether one subset marker survives or two are needed.

**The evidence.**
- `evm/src/Vault.sol:283` — `VBTC.mintTo(msg.sender, sats);` is the **only** call site of `VBtc.mintTo`
  (`evm/src/VBtc.sol:134`), and it sits inside `exposeBtcToLev` (`:279`), gated
  `if (msg.sender != LEV_MANAGER) revert NotLevManagerBtc();` (`:280`).
  So the entire vBTC supply is range BTC currently exposed to leverage. Out-of-range BTC mints none.
- `Vault.sol:276` — *"only `levPooled` grows (funded→lev, withdrawal-excluded). vBTC is thus only ever
  'minted' against real channel BTC (here), never conjured."* The guard is `BtcLib.vbtcExposeBody`'s
  `sats <= plainNet(pooled, levPooled)`.
- Owner's stated design (2026-08-17, quoted in §E251): *"totalSupply includes outOfRange locked liquidity
  that can be lent as vBTC deposited on the Morpho market."*

**The options.**
- **(levered slice only)** status quo. vBTC stays a leverage instrument; nothing new to guard.
- **(widen to out-of-range locked)** needs a second subset marker before any code — an LP could be
  lev-exposed *and* lent-out, and `plainNet` assumes one. A second consumer counting against the same
  `pooled` would pass the existing guard while jointly over-minting. That is the double-count arriving
  *through* the guard rather than around it.
- **(widen to all `pooled`)** in-range depth stops being deliverable to swappers. Not recommended.

**My recommendation.** Levered slice only for now. Widening is a three-part design (eligibility, marker
generalisation, and what happens to lent-out vBTC when the range needs the BTC) and the third part is the
same unanswered question §V-R10 raises for sUSDE.

**What it unblocks.** §E251, and the ETH-side mirror of it in §C3.

---

## 10. What is the key-recovery trust anchor?

**The question.** An LP that loses its phone key cannot be paid. What replaces the key — a Shamir/family
plan, a delayed co-signer, or a second registered key?

**Why it needs a person.** Each option produces a different contract surface on an immutable contract, and
the choice is about who the LP is willing to trust, which is not measurable.

**The evidence.**
- `evm/src/BTCChannels.sol:255-264` — `mapping(address => bytes32) public btcRecipientOf;` followed by
  *"Once an address registers via a channel open, its `btcRecipientOf` is LOCKED"* and
  `mapping(address => bool) public btcRecipientLocked;`. The lock exists for a real reason (an LP that
  could re-point it would make `_lpFinalBalance` read 0 and over-claim), so it is not simply removable.
- Every ladder rung pays `btcRecipientOf`, so the dead-man escape confirms, pays, and pays an address
  nobody can spend. `SPRINT.md` calls this *"the dominant residual"* now that theft is off the table.
- Two constraints that pre-rule options: ERC-7947-style rotation of `lpEth` is out because
  `_lpPayoutScript` derives the BTC payout **from** `lpEth`; and `migration.rs`'s k-of-n cannot serve
  recovery because it is the *old enclave* that exports.

**The options.**
- **(second registered key)** a second BIP-340 key committed at open, usable only to re-point
  `btcRecipientOf`. Smallest surface; the LP must keep two keys.
- **(delayed co-signer)** a timelocked third party can re-point. Adds a party the LP must trust and a
  liveness assumption.
- **(Shamir / family plan)** off-chain, no contract change, but no enforcement and no way to know it
  was done.

**My recommendation.** Second registered key. It is the only option that keeps the property the lock
exists to protect — the payout destination is still something only the LP's own secp256k1 material can move.

**What it unblocks.** `#14`, §LADDER-VALUE-IS-CONDITIONAL (the ladder is only worth funding if the address
it pays is recoverable), and it is a GATE 3 item, so it must land before `BTCChannels` deploys.

---

## 11. What is the LP seed entropy mix for?

**The question.** Production already uses a system CSPRNG. The ask is to mix in chain-native randomness —
what property is that supposed to buy?

**Why it needs a person.** The ask is right and the stated reason cannot be the real one, so only the
owner can say which threat is meant. Building from the shape would produce a mechanism nobody can justify.

**The evidence.**
- `quid-ln/quid-hop/src/seed.rs:389` — `let mut rng = SysRng::new();` (`quid_crypto::rng::SysRng`, i.e.
  `ring::SystemRandom`). Production is **not** deterministic, which is the reassuring half.
- Owner, 2026-08-16: *"it cant be deterministic, we need real randomness here from the device that can
  mix with chain native randomness."*
- The blocking fact: chain randomness is **public**, so it cannot add secrecy — if the device RNG is
  predictable, `H(device ‖ chain)` is equally predictable.

**The options.**
- **(freshness / anti-collision)** the real thing a public beacon buys. Identical images, thin first-boot
  entropy and VM snapshots are genuine LP-box failure modes and a beacon fixes them.
- **(secrecy against a weak device RNG)** then the answer is an independent **private** source — user
  entropy, or generating from a user-supplied mnemonic — and the beacon is the wrong instrument.
- **(both)** `HKDF(os ‖ user ‖ beacon)`, each term's job documented at the site.

**My recommendation.** State it as freshness and implement `HKDF(os ‖ user ‖ beacon)` with the mnemonic
as the system of record. If the real worry is a weak device RNG, say so — that changes the design.

**What it unblocks.** §LP-SEED-ENTROPY and the open half of §M1#2's phase 1 (items (a) and (b) are done).

---

## 12. θ or the lever — which instrument carries linearity?

**The question.** The range sheds ETH as price rises; the lever buys it back with a borrow, a venue, a
route and a keeper. θ (the in-range fraction) does the same thing with none of those. Which do we build toward?

**Why it needs a person.** It can delete a machine. The comparison is in-range fee yield against
`venueYield + borrowing cost + g + liquidation risk`, and under the lever the last three are real and
unmeasured while under θ they are zero — but the boundary between them is a design judgement.

**The evidence.**
- `evm/src/imports/LevMath.sol:235` — `ilTargetBps(uint128 ilBasisPx, uint256 pxNow, uint64 capBps)`
  implements `1 − √(ilBasisPx/pxNow)`, which rises with price exactly as the range sheds.
- Un-ranged ETH sits in weETH and holds constant units (linear); in-range ETH holds √p (concave). So
  lowering the in-range fraction sheds less and needs less lever — a quantity already computed on-chain.
- Blocked on one real unknown, not a read: can θ hit `1 − √(entry/now)` **exactly**, or only track its
  direction? That decides *substitute* vs *reduce-the-size-of*, and nobody has established it.

**The options.**
- **(θ substitutes)** the lever's four dependencies go away for the common case. Only valid if θ can hit
  the target exactly; θ can only shed what is *in* range, so once in-range is fully withdrawn the lever
  returns for the tail.
- **(lever stays primary)** then 6e (measure `g` from the up-leg) and 7a (collapse the rebalance walk) are
  worth doing. Measuring `g` on a leg you are about to stop using is the ordering trap.
- **(asymmetric band, cheap third option)** rebalance down promptly (self-funding, atomic, routeless) and
  up lazily. Costs a wider `h`; no new machinery at all.

**My recommendation.** θ for the common case, lever for the tail — and price the asymmetric band in the
same pass. The evidence does not settle where the boundary sits; the measurement that would is whether θ
can hit `1 − √(entry/now)` exactly, and it is a pure sweep needing no deployment.

**What it unblocks.** GATE 2.5, and it must precede 6e and 7a.

---

## 13. Mint the position token to the LP on both legs?

**The question.** ERC-7540's blocker is shares — the vault must *be* the share token. On the BTC leg vBTC
goes to `LEV_MANAGER`, never to an LP. Do we make the LP position the token, on both legs, in one change?

**Why it needs a person.** It changes what an LP holds and what a third party can hold on their behalf.
The engineering is small; the product surface is not.

**The evidence.**
- `evm/src/Vault.sol:284` — vBTC mints to `msg.sender`, which is `LEV_MANAGER` by the gate two lines up.
- `evm/src/Quid.sol:1642` — `function totalSupply() external view returns (uint) { return lpShares; }`,
  and `:1649` `balanceOf`. The ETH side already carries the identical `pooled`/`levPooled` structure.
- It is cheaper than it looks: `balanceOf` is a view over `autoManaged[a].pooled`, so there is no mint,
  no migration window and no dual model. The correct mapping is `balanceOf = pooled − levPooled`.

**The options.**
- **(yes, both legs, one change)** `B8` / the 7540 fold becomes possible. Two hazards must land in the
  same change: settle fee bookmarks for **both** parties on transfer (`_refreshBookmarks`), and the
  free-part bound (the mapping already enforces it).
- **(no)** any 7540 interface work is a face built over a share model this would replace.

**My recommendation.** Yes, both legs in one change. Splitting the legs is the failure mode — they diverge
and the second one is then a migration instead of an edit.

**What it unblocks.** `B8`, ERC-7540 conformance's semantic half, and it is the named predecessor of both.

---

## 14. Does a depositor capture the mark's recovery upside?

**The question.** A depositor entering at mark `m0` and redeeming at `m1` — are they owed `paid·m1/m0`
(they capture the recovery from 0.92 → 1.0), or `≈par plus vintage yield`, which is what ships today?

**Why it needs a person.** The two are mutually exclusive at any real shortfall and the tree has never
ruled. It decides whether new money subsidises incumbents, which is a product positioning call.

**The evidence.**
- Measured (§SESS-30): `AUX.deposit` credits **$49,999.999999** for $50,000 — *no entry haircut at all*.
  The mint issues **50,331.98 = paid × 1.00664**. Entry-at-the-mark at `m0 = 0.920362738446759367`
  would need **paid × 1.0865 = 54,326.41**.
- `test_E2_MintAtMark_NewDepositorIsNotHaircut` caps the mark-up at ≤1% (`assertLe(minted, 10_100e18)`);
  entry-at-the-mark needs 8.65%. **Both assertions cannot hold.** Three of the four `MintAtMark` tests
  pass under the shipped policy; the failing one is the minority.
- The assertion was rewritten policy-neutral (`received ≥ paid·m1/WAD`) rather than picked, and §SESS-33
  confirms the ruling survives the owner's *"why should there be a shortfall at all?"* — §E2-#1 (enter at
  the mark) already shipped; what is asked for on top is the **recovery upside**, a strictly stronger claim.

**The options.**
- **(par + yield, as shipped)** the basket is self-healing; new money funds part of a legacy shortfall
  silently, and entering a distressed basket is unattractive exactly when deposits are most wanted.
- **(entry at the mark)** fair per-cohort, shortfall stays with the holders who incurred it, and the ≤1%
  mark-up cap has to go.

**My recommendation.** Par plus yield, as shipped — and delete `test_E2_MintAtMark_RealRedeemMatchesTheMark`'s
`paid·m1/m0` claim rather than leaving it as a policy the code contradicts. The recovery upside belongs to
whoever held through the drawdown.

**What it unblocks.** The `MintAtMark` cluster, and it is the same question decision 1 asks on the ETH leg.

---

## 15. Who bears a stranded remainder on a swap-**OUT** reversal?

**The question.** When a failed swap-out is reversed and the pool can only partially absorb it, the
remainder is stranded — the swapper has no deposit or HTLC to reclaim it from. Who eats it?

**Why it needs a person.** The choice is currently delegated to a hop-supplied boolean per call, which is
not a policy. Somebody has to say what the policy is.

**The evidence.**
- `evm/src/BTCChannels.sol:2167` — `consumed = btc.creditSwapIn(so.swapper, so.sats, so.token, minDeliveredUsd);`
  then `:2168-2170` — `// All-or-nothing: a partial refund strands the remainder… if (requireFull &&
  consumed < so.sats) revert SwapInPartialRejected();`
- `function reverseSwapOut(bytes32 swapId, uint minDeliveredUsd, bool requireFull)` is at `:2157`.
  `requireFull` is a parameter, and the function is `_onlyHop()`-gated, so today the **hop** chooses per
  call whether a partial reversal is accepted or reverted.
- `SwapInPartialRejected` (`BTCChannels.sol:471`) now exists in exactly this one place. This is *not* the
  swap-**IN** remainder — **that is a separate live decision, 17.**

**The options.**
- **(revert always)** drop the parameter, always all-or-nothing. The swapper waits and uses
  `refundExpiredSwapOut` (`BTCChannels.sol:2201`, permissionless of the hop) after `SWAPOUT_REFUND_BLOCKS`.
  Simple, and the escape already exists.
- **(accept partials, hop covers the gap)** the hop makes the swapper whole off-protocol, which is the
  same shape as decision 7's fleet-as-principal.
- **(keep it hop-chosen)** status quo; the hop decides case by case, which is a trust surface with no rule.

**My recommendation.** Revert always and delete the parameter. `refundExpiredSwapOut` is permissionless
and pinned to the recorded swapper, so the swapper's recovery does not depend on the hop's choice — which
makes the flag a decision that only ever costs someone something.

**What it unblocks.** One `BTCChannels` parameter before the contract deploys immutable. ⚠️ It does
**not** discharge §NO-REJECT / §LN-SWAPIN-REMAINDER — that is decision 17.

---

## 16. Should an out-of-range intent fill pay the inventory term?

🔴 **RESTORED 2026-09-08. THE FIRST PASS STRUCK THIS AS *"gone — nothing rests"*, WHICH IS TRUE OF THE
BOOK AND FALSE OF THE QUESTION.** `sweepOor` and `fillOOR` really do have zero declarations. But the
resting-order path was **replaced, not removed** — `Quid.fillIntent` (`Quid.sol:1246`) is the survivor,
and it inherits §E332-c's question in a sharper form, because the intent path pays the range *nothing at
all*. `SPRINT.md:7494` still lists **§E332-c** among *"the four standing"* owner decisions, alongside
§E352 and §E330 (decisions 3 and 2).

**The question.** An out-of-range fill drains range inventory at a price the maker chose. Should that
fill be charged the inventory (scarcity) term — priced into where the order **rests**, so the trigger
includes it and the fill still honours its stated limit — or does an out-of-range maker fill free?

**Why it needs a person.** It is a standing unpriced maker discount on every crossed order, and pricing
it changes what an intent is worth to sign. That is a product call, not an arithmetic one.

**The evidence.** (Code, not docblocks.)
- `evm/src/imports/SwapLib.sol:1287` — the fill converts at the **signed limit**:
  `uint volOut = BasketLib.convert(funded, i.limitPx, true);`. No `wellSkew`, no `skewWad`, no
  `_depletion` anywhere in `fillIntentBody`.
- `evm/src/imports/Interfaces.sol:637-638` — `settleOor`'s own declaration says so: *"`Quid.fillIntent`
  calls it with the deltas `SwapLib.fillIntentBody` derives **AT THE SIGNED LIMIT, not at spot**."*
- `evm/src/Core.sol:977-981` — `settleOor` is `_handleDelta(...)` plus an optional
  `_shortfallLoadBalance`. **There is no charge on the path at all.**
- `SPRINT.md:5670` names it: *"§E331 #1 (**OOR fills pay NO skew at all**)"*, and adds *"do not settle
  one without the other"* — the other being decision 2.
- ⚠️ **AND THIS IS NOW AN INCONSISTENCY WITH A RULING MADE TODAY.** §MIN-SWAP-FEE (`d047fd6e`, owner
  2026-09-08) floors **every swap** at 420 ppm — *"all swaps even balance restoring must pay at least
  the minimum"* — by flooring `wellSkew` and `sellSkew`. `fillIntent` reaches neither, so it is now the
  one path that consumes range inventory and pays zero. Whether that is intended is exactly this call.

**The options.**
- **(price it at rest — §E343's clean form)** the inventory term enters the *trigger* price, so the
  order rests further out and the fill still executes at its stated limit. Limit semantics intact; no
  new state; cheapest of the four standing decisions.
- **(charge it at the fill)** breaks the maker's stated price, which is the reason §E343 rejected it.
- **(leave it free, and say so)** ratify the discount as the price of resting liquidity — then
  §MIN-SWAP-FEE's *"every swap"* needs the exception written next to it, or the two rulings contradict.

**My recommendation.** Price it into where the order rests. It is the only option that keeps both
§MIN-SWAP-FEE's "every swap pays" and the maker's signed limit, and it needs no new declaration.

**What it unblocks.** §E332-c, §E331 #1, §E276's surviving design question (`SPRINT.md:17512`:
*"its CITATION is dead — but the design question … is live as §E330 / §E332-c"*), and it is the second
half of decision 2's pair.

---

## 17. Who bears a stranded swap-IN remainder, and must the chain see it?

🔴 **RESTORED 2026-09-08. THE FIRST PASS STRUCK THIS AS *"gone — `settleSwapInProven` accepts partials
by design"*. THE PARTIAL IS ACCEPTED; THE REMAINDER IS NOT REFUNDED BY THE MECHANISM THE CONTRACT
NAMES.** This is the row the owner calls the biggest vulnerability (`SPRINT.md:12613`), and it is still
open — the 2026-09-08 re-scoping pointed it at `reverseSwapOut` (a swap-OUT refund, decision 15), and
the first pass then read that mis-pointing as the question's disappearance. **Both are wrong: the
question lives on the `settleSwapInProven` → hop-claim path.**

**The question.** A swap-in deposits `sats` and the pool can only convert `consumed < sats`. The
remainder is BTC the protocol holds and delivered no USD for. Does the chain have to see it settled —
or is a refund the hop constructs off-chain, at its own discretion, the policy?

**Why it needs a person.** Three sub-policies are already decided **in Rust, by nobody**, and each moves
value: dust is kept, a failed log read keeps everything, and an omitted refund output is undetectable.

**The evidence.** (Code, in both trees.)
- `evm/src/BTCChannels.sol:2098-2100` claims the remainder *"is refundable trustlessly via the deposit's
  own CLTV leaf."* 🔴 **THE HOP KEY-PATH-CLAIMS THE WHOLE DEPOSIT IMMEDIATELY AFTER SETTLE, SO THE CLTV
  LEAF IS NEVER REACHED.** `quid-ln/quid-hop/src/swap_in_onchain.rs:141-143`: *"Build the hop's KEY-PATH
  claim tx… **No timelock (the hop claims immediately after settle)**."* A refund by CLTV requires the
  deposit still to be unspent at expiry, and it is not.
- The **actual** refund is a second output the hop chooses to add:
  `quid-hop/src/swap_in_onchain.rs:164-170` `build_claim_tx_with_refund(..., refund: Option<TxOut>)`.
  Nothing in `evm/src` requires it, observes it, or can penalise its absence.
- **Sub-policy 1 — dust is kept by the hop.** `quid-bridge/src/swap_in_onchain.rs:331-336`:
  `if amt < refund_spk.minimal_non_dust() { warn!("partial remainder below dust — taking the whole
  deposit"); None }`, documented at `:308-309` as *"the seller's loss is ≤ the dust limit."*
- **Sub-policy 2 — a failed read keeps everything.** `quid-bridge/src/client.rs:880`:
  *"🔴 **`read_consumed_sats` MUST FAIL TOWARD 'TAKE THE WHOLE DEPOSIT', NEVER TOWARD A REFUND.**"*
  Four tests at `:891-915` pin that: empty log set, empty data, short data, garbage — *"must take all"*.
- **Sub-policy 3 — silent omission.** `SwapInSettled` emits `sats` and `consumed`, so the gap is
  *visible*; nothing on-chain consumes it, so it is not *enforced*.

**The options.**
- **(fleet's problem — ratify)** the answer decision 7 implies. `§FLEET-FRONTS-THE-WINDOW` cost 4 says
  it plainly: *"Partial fills move off-chain… the fleet now decides what to pay its own counterparty,
  and the pool sees only a proven deposit."* Then sub-policies 1-3 are the fleet's commercial terms and
  should be **written down as terms**, not left in three Rust files.
- **(the chain sees it)** an owed ledger keyed on the deposit txid, settled or refunded on-chain. This
  is the §NO-REJECT shape and `SPRINT.md` measured its cost: *"no `owed`/`obligation` mapping in
  `evm/src`, and **zero** `Intent`/`Shortfall`/`Unfilled`/`Remainder` events anywhere"* — an owed
  ledger plus a settlement path plus emission, on a contract with ~1.3 KB of EIP-170 margin.
- **(pre-empt it)** bound the deposit at quote time to what the pool can absorb, so `consumed == sats`
  by construction and there is no remainder to bear.

**My recommendation.** Gated on decision 7. If 7 is **yes**, take "fleet's problem" — but write the
three sub-policies into the fleet's terms and add one assertion that `sats − consumed` is either
refunded or below dust, so the fleet's discretion is bounded by something other than its own code. If 7
is **no**, §HOP-BOND returns and this becomes on-chain work before `BTCChannels` deploys immutable.

**What it unblocks.** §LN-SWAPIN-REMAINDER, §NO-REJECT, §B9b-iii, and it re-points the 2026-09-08
re-scoping (which sent this row to `reverseSwapOut`) at the path that actually carries it.

---

# Appendix A — decisions already made, still recorded as open

Mark the **decision** closed. ⚠️ **That is not the same as marking the ROW closed** — three of these
carry a surviving engineering item or a condition, flagged inline below. Per rule 16, a ruling that a
later fact can reopen is ⏸️, never ✅.

✅ **Every quote in this table was re-checked against `SPRINT.md` on 2026-09-08 and every one resolves to
a dated primary source** — which matters here, because `SPRINT.md`'s own navigation header (`:37-45`)
records **46 bare `(owner)` tags against 246 dated ones**, and one of the 46 drove six rows before it was
struck. Two rows below arrived undated in the first pass and are now dated.

| ruling | quote / date | what to strike |
|---|---|---|
| **C17 eMode** — not used | owner 2026-08-26: *"we dont need emode for anyhting"* | Verified: `setUserEMode` has **zero occurrences** in `evm/`. Still listed as one of "the four owner decisions" in several places. |
| **`BTCChannels` governance** — no owner | owner 2026-09-08: *"delete the ownable, no owner"* | Verified: `evm/src/BTCChannels.sol:112` is `contract BTCChannels {` with no base. `MIN_CONFIRMATIONS` and `SWAPOUT_REFUND_BLOCKS` are fixed at deploy by construction; GATE 3 item 4's "add a setter" answer is foreclosed. |
| **§MSIG-NOT-SAFE** — plain multisig, not a Gnosis Safe | owner 2026-08-14; destaled 2026-09-07 (`§MSIG-NOT-SAFE-DESTALE ✅`, `SPRINT.md:57746`) | Still bundled as an open owner decision at `SPRINT.md`'s "12" row alongside §LP-SEED-ENTROPY. ⚠️ **The DECISION is closed; one engineering check survives it and must not be swept up** (`SPRINT.md:15928`): the enclave `ecrecover`s owner signatures against a **sealed snapshot** pinning the msig address only as `verifyingContract`, so *"check whether the chosen msig keeps a STABLE ADDRESS across owner-set changes — if it does not, every rotation costs a NEW SEALED SNAPSHOT"*, i.e. an enclave rebuild per owner change. That is measurable, so it is not the owner's to rule on — but it is not discharged either. |
| **§PHASE-ORDER** — the Bitcoin work order | superseded by `§MASTER-ORDER-2026-09-05`; closed 2026-09-06 | Bundled in the same "12" row. It is an order, and a newer order won. |
| **§SECOND-FUNDING-HALF** — the phone SIGNS, the daemon FUNDS | **owner 2026-08-16** (the first pass left this an undated `(owner)`; the date is at `SPRINT.md:48627`) | Two rows still cite it as the blocker for the acceptor-contributes path. ⚠️ **"LDK's `TODO(dual_funding)` superseded" was too strong — it is a MEASUREMENT, and it is the one thing that can reopen this.** `SPRINT.md:48627`: the vendored LDK splicing acceptor cannot contribute inputs, the dual-funding paths sit behind a `cfg` enabled in **none** of our `Cargo.toml`s, so *"whoever funds MUST initiate"* — the closure holds **only while "the LP runs a daemon" holds.** If a node-less LP is ever required to fund a grow, this reopens as vendored-code work, not wiring. |
| **§M1#2 phase 1** — same seed, taproot path | owner 2026-08-30; `deriveFundingKey` at BIP-86 `m/86'/0'/0'/0/0`, point matches the published vector | The cell read 🔴 while the list twelve lines below read "DECIDED AND BUILT". Phase 1 is done except for decision 11. |
| **§B7** — smart-wallet capability removal | ratified 2026-08-18 (`D2 #8`), answer *"yes, excluded"* | Still listed among "the eleven genuine owner decisions". Note the caveat that survives: EIP-7702 means `SignatureChecker` must stay. |
| **§UNIT-A** — delete the skew ceilings, use measured variance | owner 2026-08-06 | Landed. Do not re-derive it from §UNIT-B's framing. |
| **§NO-VBTC-MORPHO-MARKET** — the vBTC Morpho market is deleted | standing ruling, closed by deletion 2026-09-07 | Rows still reasoning about a Morpho/Euler vBTC liquidator-exit are reasoning about a venue that is gone. |
| **§ANY-DOLLAR-BORROW** | **owner 2026-09-07**, verbatim at `SPRINT.md:57658`: *"…but do this later, **delay it until all our other work is done**."* | Reads as open work in the gate tables. **⏸️, not ✅** — it is deferred, not decided against, and `SPRINT.md:4562` warns *"DO NOT CLOSE IT"* because it re-adds a second venue. Strike it from the decision queue, not from the plan. |
| **Stale-comment sweep** | owner ruling 2026-09-05: *"its not possible to automate the stale comments sweep, you really have to [read them]"* | Quoted twice as if still open. |
| **§E279 / §E345** — `retainSkewPremium` is the intended charge; σ² sourced from the anchor | landed `f5499659` / `56249fe8` | Listed as decisions (a) and (b) of "the four" in a table that still reads as a queue. |
| **Curve → 1inch, per use-site** (GATE 2.4) | owner 2026-09-05 | stable↔USDC hub: **1inch, decided**. weETH→WETH offramp: **keep direct, measured 2026-09-05** — and 1inch's `unoswap` encoder cannot reach that Curve pool at all (32 encodings, zero fills). Only the depth *read* is open, and it is a read, not a swap. |

---

# Appendix B — rows that read as owner decisions but are not

⛔ **DO NOT "STRIKE WITHOUT READING" — THAT INSTRUCTION STOOD HERE AND IT COST TWO LIVE DECISIONS
(rows 4 and 5, restored as decisions 16 and 17).** The failure mode in both: a symbol-liveness grep
came back zero, and the *question* was retired along with the *mechanism*. ⇒ **For every "gone" below,
the test is not "does the symbol resolve" but "did the capability survive under another name, and does
the question survive the capability?"** `SPRINT.md:7600-7612` records this same error being made on
these same rows once before.

1. **§E205 — "should the 420 ppm tier be ZEROED?"** — **⚠️ SUBJECT RESTORED TODAY, QUESTION STILL DEAD.**
   `swapFeePpm` has zero declarations in `evm/src|test|script` (one historical mention in a comment at
   `SwapLib.sol:801`), and `Core.sol:1497` still records *"THE FLAT 420 ppm IS GONE"*. **But §MIN-SWAP-FEE
   (`d047fd6e`, owner 2026-09-08) brought the 420 ppm back as `SwapLib.MIN_SWAP_SKEW_WAD = 4.2e14`
   (`:823`), a FLOOR on the skew rather than a flat tier.** The row's own question — *zero the tier?* —
   is still moot (there is no tier), but **do not cite this row as evidence that 420 ppm is gone from the
   tree**; it is not, and decision 2 turns on that.
2. **§E294 — "delete `pushObservation` or wire it?"** — **gone, and the concern is accounted for.**
   `pushObservation` has **zero declarations** in `evm/src|test|script` (5 comment references only);
   `OracleLib.sol:288-289` and `SwapLib.sol:966` / `:1476` all record *"`Core.pushObservation` does not
   exist"*. ✅ **THE σ²-SUPPRESSION CONCERN DID NOT EVAPORATE — IT WAS RE-HOMED, IN WRITING, TWICE, AND I
   CHECKED BOTH.** (a) The *attack* is closed by construction: §E345 made `realizedVarianceWad` return
   `max(ringVariance, anchorVarianceWad)` (`Core.sol:440`), so a drainer who stretches the clock
   suppresses only the ring leg — `SwapLib.sol:1487-1491` states exactly that, and the guard is kept
   anyway. (b) The *residual* is named and relocated: `SwapLib.sol:1478-1480` — *"The hazard is now the
   PINNED-SOURCE case `Core.sol:1675` names — that branch writes what the source returns with NO
   deviation check — so the day a source is pinned this floor would be exactly the wrong thing to add."*
   ⇒ **That residual is decision 8's, and only fires if 8 is answered "pin a source."**
3. **§E258 — "OOR orders became options; should they auto-execute?"** — **the AUTO-EXECUTE half is gone;
   the row is bundled with 4, which is not.** `sweepOor` and `fillOOR` have zero declarations, and
   `Core.sol:1095` reads *"§OOR-BOOK-DELETED — THERE IS NOTHING TO SWEEP."* `SPRINT.md:5399` closes the
   sub-row explicitly: *"§E258-POKE-INCENTIVE — **dissolves — there is no poke.**"* ⚠️ **Two things
   survive and are NOT struck:** `§E258-CROSSING-TEST` stays open (`SPRINT.md:5347`, *"it was never
   closed for the book either"*), which is test work; and the *pricing* half is decision 16.
4. 🔴 **§E332-c — "should OOR fills pay the inventory term, priced into where the order RESTS?" —
   OVERTURNED 2026-09-08. THIS IS LIVE, AND IT IS DECISION 16.** The struck reasoning was *"nothing
   rests"* — true of the ETH range's boundary-order **state** and irrelevant to the question. The book was
   replaced by signed intents, and the replacement charges **nothing**: `SwapLib.sol:1287` fills at the
   maker's signed limit (`BasketLib.convert(funded, i.limitPx, true)`), `Interfaces.sol:638` says so in
   the declaration (*"AT THE SIGNED LIMIT, not at spot"*), and `Core.sol:977-981`'s `settleOor` is
   `_handleDelta` plus an optional load-balance with no charge on the path. `SPRINT.md:7494` still lists
   §E332-c among *"the four standing"* owner decisions; `:5670` names it *"OOR fills pay NO skew at all"*
   and adds *"do not settle one without the other."* ⚠️ **The `Vault.sol:659-667` quote is real and was
   read too widely: it is about the BTC range having no boundary path, not about the ETH intent path.**
5. 🔴 **§LN-SWAPIN-REMAINDER / §NO-REJECT — OVERTURNED 2026-09-08. THIS IS LIVE, AND IT IS DECISION 17.**
   Two claims were made here and both fail. **(a) *"`settleSwapInProven` accepts partials by design"* is
   true and does not answer the question** — the contract's own justification, *"the seller's remainder is
   refundable trustlessly via the deposit's own CLTV leaf"* (`BTCChannels.sol:2098-2100`), **is
   unreachable in practice**, because the hop key-path-claims the whole deposit immediately after settle
   (`quid-hop/src/swap_in_onchain.rs:141-143`, *"No timelock (the hop claims immediately after settle)"*).
   The real refund is an optional second output the hop chooses to add (`:164-170`
   `build_claim_tx_with_refund`), with three policies already set in Rust and none on-chain — see decision
   17. **(b) The re-scoping WAS wrong about the survivor, and that was correctly spotted** —
   `BTCChannels.sol:2157`/`:2170` (the re-scoping's `:2141`/`:2154`, since rotted) are `reverseSwapOut`,
   which is decision 15. **But "the re-scoping pointed at the wrong path" is not "the question is gone."**
   The question lives on `settleSwapInProven` → hop-claim, and `SPRINT.md:12613` still carries it as the
   row *"the owner calls the biggest vulnerability."*
6. **§DEPOSIT-VERIFIER** — **discharged as a decision.** §T2 landed both sides (`evm/src/imports/BitcoinTx.sol`
   — `termsCommitment` at `:795`, `settleFloorUsd` at `:807`; `quid-hop/src/swap_in_onchain.rs:100-114`).
   ⚠️ **Correction: the client verifier is NOT unwritten.** It exists and is unit-tested —
   `app/features/identity/chain/taproot.ts` (`verifyQuotedDepositAddress` at `:221`), tested at
   `taproot.test.ts:141-160`. **What remains is WIRING it into `spa/src/app/(app)/app/page.tsx`, which
   still merely renders the address.** Do not write a second verifier.
7. **Routing-fee attribution (pool-wide vs per-channel) / §FEE-CREDIT "split weights"** — **no subject
   yet.** `announce_for_forwarding` has zero occurrences outside the vendored LDK fork, so the node is
   unannounced and unroutable; `channel_driver.rs:1326` says LN routing fees *"are never observed upstream
   (no `PaymentForwarded` handling anywhere in the tree)"*. This decides the split of a revenue stream that
   does not exist. Revisit when the node announces.
8. **§V-R11 — "should a hedge partially fill?"** — **already ruled, then engineering.** The owner gave the
   invariant on 2026-08-16 (*"it must never stop tracking like this"*). What remains is a sizing loop:
   1inch `unoswap` takes a fixed `amountIn`, so the free variable is size, not the floor
   (`LevMath.sol:509` `SELL_SLIP_BPS = 100`, clamped in `_slipBps` at `:566`). Do not weaken `minOut`.
9. **§E199-old-aave-leg-uncovered** — **measurable.** `evm/script/DeployL1_s.sol:306` wires `aaveSpoke`;
   `Alles.t.sol:758` does too but gives USDC/USDT their Morpho vaults only. Wiring a harness is work.
10. **§E244 — mock router vs `expectRevert`** — a test-authoring choice with a stated rule already
    (*"the unacceptable resolution is a tolerance that makes them pass"*). One test remains:
    `LevCascade::test_Economic_LeversToProvenIlTarget`.
11. **§PLP-T class ruling (GATE 2.2)** — **not answerable in one sitting.** Gated on M1–M3 and M7, which
    need realised flow; `evm/deployments/l1.json` names mainnet addresses with **zero code** at the archive
    pin. Two halves *are* decidable now by pure sweep and are recorded there; the class choice is not.
12. **§E76 "what is the skew for" / §E93 / §E98** — subsumed. §E76's funding justification is gone and the
    live form of the question is decisions 2 and 3. §E93 and §E98 are tasks the owner already set, not forks.
13. **§E172 "does the channel keep forwarding?"** — **de facto answered by the shipped design.**
    `quid-ln/quid-hop/src/rebalancer.rs:1-32` builds the whole splice-in trigger on the LP forwarding
    swap-ins (`next_outbound_htlc_limit_msat` vs the per-swap ceiling), and the owner already chose option
    (c) — the LP is online sometimes and the channel quiesces before departure. Reopen only if the ladder's
    status as escape-vs-vestige is being re-litigated.
14. **The "50 rows are OWNER-BLOCKED" / "62 owner decisions" / "56 of GATE 2's 63" headline counts** — those
    are counts of *rows*, not of decisions, and the two largest were measured before the 2026-09-08 dedup on
    a file that carried itself twice. **The decision count is 17** (15 in the first pass, plus the two
    restored above). ⚠️ **That number is a reading with a timestamp like any other here** — it is the
    count that survived one adversarial re-verification, not a proof that no eighteenth exists. Every
    strike above now states the *capability* test it passed, not just the symbol grep, so the next
    reader can re-run the right check rather than the cheap one.
