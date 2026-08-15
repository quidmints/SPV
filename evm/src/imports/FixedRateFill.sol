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
///         ⇒ **THE SWAPPER WHO CAUSED IT PAYS** (owner's decision, 2026-08-15). Not the band LPs
///         (socialising it charges LPs who did not cause the imbalance) and emphatically not the
///         basket (whose dollars already supply band depth — making them fund the rebalance too
///         would have one party pay twice for the same trade).
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
