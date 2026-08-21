// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";

/// @title  FixedRateFill — the settlement primitive that replaces the v4 AMM (§28, Phase 3 step 1)
///
/// @notice ONE PRICE, NO TRAVERSAL. The swapper is quoted a SINGLE rate for a SINGLE size, bounded by
///         inventory, and that rate is what settles. There is no curve to walk, no tick to cross, and
///         no average-execution-across-a-range — which is precisely why √P and the tick grid leave in
///         the same cut (owner, 2026-08-15: "work around geometric means").
///
///         WHY THIS IS NOT AN AMM. An AMM DISCOVERS the price by moving along a curve as the trade
///         executes, so the marginal price at the end differs from the start and the average is a
///         geometric mean of the two. Here the price is COMMITTED BEFORE EXECUTION and does not move
///         during it. The imbalance the trade creates is priced INTO the quote via the skew, rather
///         than being expressed as slippage discovered on the way through.
///
///         ⇒ THE SKEW IS NOT A SPREAD PAID TO ARBERS. IT IS THE ATTRIBUTION KEY FOR A REBALANCE WE
///         PERFORM OURSELVES (owner, 2026-08-15). An AMM's spread exists to PAY EXTERNAL
///         ARBITRAGEURS to push the pool back to target — that is the entire economic function of
///         the curve. We restore 1:1 from the INSIDE via Curve, so there are no arbers to
///         compensate and nothing the spread would be funding.
///
///         WHAT REMAINS IS A REAL COST, AND IT IS NOT FREE: curving back to target pays Curve's fee
///         plus slippage, and it is incurred BECAUSE someone pushed the band off target.
///         ⇒ **THE COST SPLITS ACROSS ALL THREE** (owner, 2026-08-15, correcting an earlier
///         causer-pays-only reading). A band trade has **TWO SUPPLIERS, NOT ONE**: the volatile leg
///         is LP INVENTORY, the USD leg is BASKET CAPITAL (at rest ~246k of basket dollars against a
///         739k ETH deposit). The rebalance cost is therefore incurred against capital supplied by
///         both, and CAUSATION IS ONLY ONE AXIS. Each pure answer is a corner solution:
///           • swapper-only — ignores that LPs earn the fee lane *precisely for* carrying inventory
///             risk, so they are being paid for a cost they are not bearing;
///           • LP-only — socialises a large swapper's imbalance onto LPs who did not create it;
///           • basket-only — makes the basket fund a rebalance of depth it ALREADY supplied, paying
///             twice for one trade.
///         The split must be weighted by WHO TOOK THE RISK ON EACH LEG, which is the same test that
///         resolves the corner solutions.
///
/// 🔴 THIS IS THE SAME QUESTION AS #12 (count-once) AND MUST BE SETTLED WITH IT.
///         #12 cannot be evaluated without stating who owns the PROCEEDS of a band→basket sale —
///         two suppliers, both corners wrong, the survivor being "credit the LP its inventory's
///         proceeds MINUS a depth fee". That is this split seen from the other side: one asks who
///         pays a cost, the other who receives a proceed, and both answer "apportion between the
///         two suppliers". Settle them together or they WILL drift apart.
///
/// 🔴 OUT-OF-RANGE IS A FOURTH STATE AND IT BREAKS THE TWO-SUPPLIER SYMMETRY.
///         When the band is OOR it holds a SINGLE asset — the two legs have collapsed into one, so
///         "who supplied what" has a different answer entirely. The operation is also different: not
///         *restore 1:1* but *RE-ENTER RANGE*, a different cost with a different beneficiary. **A
///         split calibrated on an in-range band is simply WRONG when applied out of range**, and it
///         will not announce itself — it produces a plausible apportionment against the wrong basis.
///         ⚠️ NOT SOLVED HERE. Any split rule must state its OOR behaviour explicitly rather than
///         inheriting the in-range weights by default.
///
///         SO THE SKEW SURVIVES, WITH A DIFFERENT JOB. `wellSkew` measures the SCARCE side
///         (volatile-OUT drain — A&S's reservation price with the `q/(1−q)` pole, because you CAN
///         run out and the last unit is priceless); `sellSkew` measures the ABUNDANT side
///         (volatile-IN, LINEAR `Γσ²·q`, no pole, because YOU CANNOT RUN OUT OF SURPLUS — §E54).
///         Both are `public view`, so both directions are readable before settlement.
///
/// 🔴 THE OPEN PIECE — BATCHING MAKES THE COST JOINT, SO ATTRIBUTION NEEDS A RULE.
///         The keeper rebalances in BATCHES so gas is amortised (#28). That means the actual Curve
///         cost is incurred PER BATCH and is not known at any individual swap's settlement time.
///         The shape that follows from "the causer pays": charge the measured skew at settlement
///         into a pot, pay the keeper's rebalance OUT of that pot, and let surplus/deficit accrue
///         to the fee lane — with each swapper's share of a batch's joint cost being PRO-RATA BY
///         THE SKEW THEY CONTRIBUTED. That reuses the skew for what it is actually good at: a
///         relative measure of who created how much imbalance.
///         ⚠️ NOT YET DECIDED, AND IT MATTERS: whether the settlement charge is a FINAL price or an
///         ESTIMATE trued up against realised cost. A final charge is a model (A-S) standing in for
///         a measurable fact (what Curve actually cost), which is the kind of substitution this repo
///         has been burned by. An estimate-plus-true-up is honest but needs somewhere to hold the
///         difference. DECIDE BEFORE WIRING `_applySkew` INTO A LIVE PATH.
///
/// @dev    ⚠️ A QUOTE IS ONLY AS FRESH AS THE BLOCK IT WAS TAKEN IN. `sellSkew`'s own docblock says
///         so and says the binding must carry its own staleness bound — so `Quote.deadline` is NOT
///         optional garnish, it is the thing that stops a quote taken in a calm block from settling
///         in a violent one. A committed rate with no expiry is a FREE OPTION written to the swapper,
///         and the band is the counterparty who paid for it.
library FixedRateFill {
    /// A rate committed before execution, with the two bounds that make committing safe.
    /// @param rateWad     volatile↔USD rate INCLUSIVE of the skew charge. What settles.
    /// @param maxSizeIn   inventory bound — the largest input this quote is valid for.
    /// @param skewWad     the imbalance charge folded into `rateWad`, surfaced so the swapper can
    ///                    see what they are being charged for the imbalance THEY create.
    /// @param deadline    unix seconds after which this quote is void. See the staleness note above.
    struct Quote {
        uint256 rateWad;
        uint256 maxSizeIn;
        uint256 skewWad;
        uint64  deadline;
    }

    error QuoteExpired();
    error SizeExceedsInventory();
    error ConservationViolated();
    error NoQuote();

    /// @notice Quote a DRAIN — volatile out of the band, the scarce direction.
    /// @param  core     the Core holding the pooled accumulators the skew reads.
    /// @param  base     the oracle price (the SAME base `wellSkew` takes; the WBTC ×1e10 lift already
    ///                  closes the 8↔18 gap, so one flat scale serves both assets — do NOT add a
    ///                  second ×1e10 "to fix BTC", it double-counts).
    /// @param  wantUsd6 the volatile-out this swap will take, 6-dec USD. Size-AWARE deliberately:
    ///                  passing 0 gives the Δ→0 instantaneous rate, which is a DASHBOARD signal and
    ///                  NOT a settlement quote. A settlement quote must pass its real size, or the
    ///                  swapper is charged for an imbalance smaller than the one they create.
    function quoteDrain(address core, uint base, uint wantUsd6, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (wantUsd6 == 0) revert NoQuote();          // a zero-size settlement quote is a category error
        q.skewWad   = SwapLib.wellSkew(core, base, wantUsd6);
        q.rateWad   = _applySkew(base, q.skewWad, true);
        q.maxSizeIn = wantUsd6;                        // the quote is valid for THIS size, not more
        q.deadline  = uint64(block.timestamp) + ttl;
    }

    /// @notice Quote a FILL — volatile into the band, the abundant direction.
    /// @param  addedTok the volatile being deposited. Passed so the sell is judged on inventory AFTER
    ///         its own contribution — a pool sitting exactly at target would otherwise never charge
    ///         any sell, however large (the §E54 note on `sellSkew`).
    function quoteFill(address core, uint base, uint addedTok, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (addedTok == 0) revert NoQuote();
        q.skewWad   = SwapLib.sellSkew(core, base, addedTok);
        q.rateWad   = _applySkew(base, q.skewWad, false);
        q.maxSizeIn = addedTok;
        q.deadline  = uint64(block.timestamp) + ttl;
    }

    /// @dev The skew moves the rate AGAINST the swapper in both directions — it is a spread, not a
    ///      directional view. On a drain the band parts with scarce inventory and charges MORE per
    ///      unit; on a fill the band absorbs unwanted inventory and pays LESS per unit. Symmetric by
    ///      construction, which is what makes it a spread rather than a fee with a sign bug.
    function _applySkew(uint base, uint skewWad, bool draining) private pure returns (uint) {
        return draining
            ? base + (base * skewWad) / 1e18
            : base - (base * skewWad) / 1e18;
    }

    /// @notice Enforce a quote at settlement time. Both bounds, or the commitment is not a commitment.
    function enforce(Quote memory q, uint sizeIn) internal view {
        if (block.timestamp > q.deadline) revert QuoteExpired();
        if (sizeIn > q.maxSizeIn)         revert SizeExceedsInventory();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // THE THREE-WAY SPLIT — weights are INPUTS, and the OOR case cannot be skipped
    // ─────────────────────────────────────────────────────────────────────────────
    /// Basis-point weights for apportioning a realised rebalance cost. MUST sum to 10_000.
    struct Split { uint16 swapperBps; uint16 lpBps; uint16 basketBps; }

    error WeightsMustSumToOne();
    error SplitIsGrindable();
    error NoExternalCostToBound();

    /// @notice Reject a split the swapper can GRIND against. **NO FIXED WEIGHT IS SAFE**, which is
    ///         why this is a runtime check on live cost rather than a constant chosen once.
    ///
    /// @dev THE ARITHMETIC (from the skew thread, verified against its four data points). A grinder
    ///      with no price view displaces the band and reverts it, paying our fee TWICE while we pay
    ///      the restoration leg twice:
    ///          trader pays 2·(fee + w·C)   ·   we pay 2·C   ·   non-abusable iff 2·fee + 2C(w−1) ≥ 0
    ///      ⇒   **w ≥ 1 − fee/C**   (w = swapper's share, C = per-leg restoration cost, fee = 420 ppm)
    ///
    ///          C = 4.2bp → w ≥ 0%        C = 10bp → w ≥ 58.0%
    ///          C = 5bp   → w ≥ 16.0%     C = 26bp → w ≥ 83.8%
    ///
    ///      🔴 **a Curve crypto-pool's fee is DYNAMIC across roughly that whole 4–26bp range**, so a constant
    ///      w is safe at 5bp and grindable at 10bp+. The weights being INPUTS is not sufficient —
    ///      they must clear this floor at the cost that actually applies.
    ///
    ///      ⚠️ IN-RANGE ONLY. The derivation assumes TWO supplier legs. Out of range the band holds a
    ///      SINGLE asset, so the round-trip it models does not exist and this bound says nothing —
    ///      do not apply it to the OOR split.
    ///      ⚠️ `costPpm` READ LIVE IS A TOLERANCE, NOT A CAPACITY READ. An attacker who moves Curve so
    ///      the cost reads CHEAP lowers this floor exactly when it needs to hold — the same hazard
    ///      `Interfaces.sol:74-77` records for `balances()`. FLOOR the cost conservatively; never
    ///      pass a naked `get_dy`.
    ///      🔴 **EXTERNALLY-SOURCED RESTORATION ONLY — A SECOND PRECONDITION, ADDED AFTER THE FACT.**
    ///      `C` is an EXTERNAL per-leg cost. The recorded refill spec (§UNIT-C-OWNER-SPEC / §E48)
    ///      says restoration is INTERNAL — repositioning ETH already held, not buying more
    ///      (*"uncommitted dollars shouldnt be sold for ETH out of band… that would be a misuse"*).
    ///      With an internal restoration there is NO Curve leg, so `C == 0` and this bound has NO
    ///      REFERENT. It therefore **REVERTS on a zero cost instead of passing**: an early `return`
    ///      would make the guard a silent no-op that reads as protection while checking nothing —
    ///      exactly the failure the paragraph above warns about. A caller whose restoration is
    ///      internal must not call this at all; it needs a different rule, not a free pass.
    ///      ⚠️ WHICH MODEL GOVERNS IS AN OPEN CONFLICT (spec dated 2026-08-06 vs this week's
    ///      "restore inventories to 1:1"), and is the owner's to settle — not something to resolve
    ///      by choosing the reading that makes this compile.
    function requireNonAbusable(uint16 swapperBps, uint feePpm, uint costPpm) internal pure {
        if (costPpm == 0) revert NoExternalCostToBound();
        if (feePpm >= costPpm) return;                   // fee alone already covers the round trip
        uint floorBps = 10_000 - (feePpm * 10_000) / costPpm;
        if (swapperBps < floorBps) revert SplitIsGrindable();
    }

    /// @notice Apportion a realised rebalance cost across the three parties with a stake in it.
    ///
    /// @dev  ⚠️ TAKES **BOTH** SPLITS AND SELECTS ON `inRange`, DELIBERATELY. The obvious signature
    ///       takes ONE `Split` and lets the caller decide which to pass — and that is precisely how
    ///       out-of-range silently inherits the in-range weights. When the band is OOR it holds a
    ///       SINGLE asset: the two supplier legs have collapsed into one, so "who supplied what" has
    ///       a different answer, and the operation is not *restore 1:1* but *RE-ENTER RANGE* — a
    ///       different cost with a different beneficiary. An in-range split applied out of range
    ///       still returns three plausible numbers against the wrong basis, and NOTHING ANNOUNCES IT.
    ///       Requiring both makes the OOR decision a compile-time obligation rather than an omission.
    ///
    ///       WHY THREE PARTIES (owner, 2026-08-15, correcting a causer-pays-only reading): a band
    ///       trade has TWO SUPPLIERS — the volatile leg is LP inventory, the USD leg is basket
    ///       capital — so the cost lands on capital both provided, and causation is only one axis.
    ///       Each pure answer is a corner solution: swapper-only ignores that LPs are paid via the
    ///       fee lane *for* carrying inventory risk; LP-only socialises one swapper's imbalance onto
    ///       LPs who did not cause it; basket-only makes the basket fund a rebalance of depth it
    ///       already supplied, paying twice for one trade.
    ///
    /// @param realisedCost measured cost of the rebalance (a BALANCE DELTA over the Curve legs —
    ///        never a number the swap path reports about itself).
    /// @param inRange  whether the band was in range for this batch. Selects which weights apply.
    function splitCost(uint realisedCost, Split memory inRangeSplit, Split memory oorSplit, bool inRange)
        internal pure returns (uint swapperShare, uint lpShare, uint basketShare)
    {
        Split memory s = inRange ? inRangeSplit : oorSplit;
        unchecked {
            if (uint(s.swapperBps) + s.lpBps + s.basketBps != 10_000) revert WeightsMustSumToOne();
        }
        swapperShare = (realisedCost * s.swapperBps) / 10_000;
        lpShare      = (realisedCost * s.lpBps)      / 10_000;
        // REMAINDER, not a third multiply: integer division truncates each share, so three
        // independent mulDivs lose up to 2 wei and the parts stop summing to the whole. The basket
        // absorbs the dust because it is the residual claimant on the balance sheet — and a
        // conservation check downstream would otherwise fail on rounding rather than on a real defect,
        // which is exactly the false positive that teaches people to add tolerances.
        basketShare  = realisedCost - swapperShare - lpShare;
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // CONSERVATION — the ONE property worth keeping from v4's `unlockCallback`
    // ─────────────────────────────────────────────────────────────────────────────
    /// @notice v4's flash accounting reverts unless every delta nets to zero. That is a CONSERVATION
    ///         PROOF, and it is SEPARABLE from the two things it was bundled with: PRICING (ticks,
    ///         √P) and CUSTODY (the PoolManager holding the funds). We keep the proof and drop the
    ///         other two — the accumulators it protects (`POOLED_*`) live in `Core`, never in v4, so
    ///         nothing about them changes when the AMM leaves.
    ///
    ///         SHAPE: snapshot our own balances → run the settlement → assert the deltas net. Same
    ///         guarantee, no external singleton, no callback re-entry surface.
    ///
    /// @dev    ⚠️ THIS EARNS ITS PLACE UNDER STANDING RULE 3 PRECISELY BECAUSE THE FAILURE IS SILENT.
    ///         A settlement that moves the wrong amount does not announce itself: it produces a
    ///         plausible balance and a wrong `POOLED_*`, and the error compounds into share pricing
    ///         where nobody can attribute it later. That is the discriminator the rule names — a
    ///         check is justified when violating it would be silent and produce plausible-but-wrong
    ///         output. It is NOT a clamp on a reachable bad state; it is a proof obligation.
    /// @param  expectedOut what the quote committed to deliver.
    /// @param  actualOut   what the settlement actually moved, measured as a BALANCE DELTA — never a
    ///                     number reported by the code under test, or the check reads its own output.
    function assertConserved(uint expectedIn, uint actualIn, uint expectedOut, uint actualOut)
        internal pure
    {
        // EXACT. No tolerance: a tolerance here is the thing that makes a real defect pass, and the
        // amounts are integers under our own control on both legs — there is no rounding source that
        // a correct settlement would produce.
        if (actualIn != expectedIn || actualOut != expectedOut) revert ConservationViolated();
    }
}
