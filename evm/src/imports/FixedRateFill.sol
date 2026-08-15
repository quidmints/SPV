// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";
import {ICore} from "./Interfaces.sol";

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
    function quoteDrain(address core, uint base, bool isBTC, uint wantUsd6, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (wantUsd6 == 0) revert NoQuote();          // a zero-size settlement quote is a category error
        q.skewWad   = SwapLib.wellSkew(core, base, isBTC, wantUsd6);
        q.rateWad   = _applySkew(base, q.skewWad, true);
        q.maxSizeIn = wantUsd6;                        // the quote is valid for THIS size, not more
        q.deadline  = uint64(block.timestamp) + ttl;
    }

    /// @notice Quote a FILL — volatile into the band, the abundant direction.
    /// @param  addedTok the volatile being deposited. Passed so the sell is judged on inventory AFTER
    ///         its own contribution — a pool sitting exactly at target would otherwise never charge
    ///         any sell, however large (the §E54 note on `sellSkew`).
    function quoteFill(address core, uint base, bool isBTC, uint addedTok, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (addedTok == 0) revert NoQuote();
        q.skewWad   = SwapLib.sellSkew(core, base, isBTC, addedTok);
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
    // TRUE-UP — settlement charges an ESTIMATE; the batch's REALISED cost is authoritative
    // ─────────────────────────────────────────────────────────────────────────────
    /// DECIDED (owner, 2026-08-15): ESTIMATE WITH TRUE-UP, not a final charge.
    /// The alternative — charge the A-S skew and call it done — substitutes a MODEL for a
    /// MEASURABLE FACT (what Curve actually cost to restore 1:1). The skew is a good relative
    /// measure of who created how much imbalance; it is not a prediction of an execution price.
    /// Letting the model BE the price is how a plausible-but-wrong number becomes unfalsifiable.
    ///
    /// SHAPE: at settlement, collect `estimateWad` and record the swapper's `skewWad` into the open
    /// batch. When the keeper rebalances, it measures the REALISED cost (a balance delta over the
    /// Curve legs — never a number the swap path reports about itself) and each participant's share
    /// is that cost pro-rata by CONTRIBUTED SKEW. The difference against their estimate is owed or
    /// refunded.
    ///
    /// ⚠️ THE SWAPPER HAS USUALLY LEFT BY THEN. A true-up that assumes a live counterparty does not
    /// work here, so the difference must land in a CLAIMABLE balance keyed by address, not a
    /// push-payment. (Storage lives in the caller — this library holds none. Sizing that mapping is
    /// an EIP-170 question and `Vogue` has 190 bytes; measure before siting it there.)
    ///
    /// ⚠️ AND THE BATCH MUST NOT BE ABLE TO STRAND ANYONE. If a batch never rebalances, its
    /// participants are owed a true-up that never comes and their estimate is a silent
    /// over-collection. Whatever holds `Batch` needs a path that settles or refunds unconditionally.
    /// NOT SOLVED HERE — named so it is not discovered later.

    /// @param realisedCost total measured cost of the batch's rebalance (balance delta, 6-dec USD).
    /// @param mySkewWad    this participant's contributed skew.
    /// @param totalSkewWad sum of contributed skew across the batch. MUST be the same accumulator
    ///                     `mySkewWad` was added to, or the split is against the wrong denominator.
    /// @param myEstimate   what this participant was charged at settlement.
    /// @return owed        additional amount due FROM the participant (0 if they overpaid).
    /// @return refund      amount due TO the participant (0 if they underpaid).
    function trueUpShare(uint realisedCost, uint mySkewWad, uint totalSkewWad, uint myEstimate)
        internal pure returns (uint owed, uint refund)
    {
        // A batch with no recorded skew cannot attribute anything. Returning (0,0) would silently
        // absorb the whole realised cost into the fee lane, which is the socialisation this design
        // exists to avoid — so refuse rather than paper over it.
        if (totalSkewWad == 0) revert NoQuote();
        uint myShare = (realisedCost * mySkewWad) / totalSkewWad;
        // if/else over a ternary DELIBERATELY: in `? (a - b, 0) : (0, b - a)` solc infers the bare
        // `0` as uint8 in one arm and uint256 in the other, so the tuple types disagree and it does
        // not compile. Named returns default to 0 and sidestep the literal typing entirely.
        if (myShare > myEstimate) owed   = myShare - myEstimate;
        else                      refund = myEstimate - myShare;
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
