// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E278 — an oversized drain is a PARTIAL FILL, not an unfillable quote.
/// @notice **THIS IS THE TEST §E104 SAID DID NOT EXIST.** That entry recorded a full-drain panic that
///         4,308 green tests missed because *"the suite never drains a band to zero"*. The same blind
///         spot let §E275's decline regress the partial-fill path: four full-suite runs across BOTH
///         arms agreed, precisely because none of them asks for more than the band holds.
///
/// THE BEHAVIOUR UNDER TEST. `swapToBody` prices the skew on the REQUESTED size (`SwapLib:448`) and
/// only bounds it to inventory ~20 lines later, where `routeSwap` returns `consumed` and
/// `_refundExcess` (`:488`, #105) refunds the unfilled remainder. So asking for more than the band
/// holds is a partial fill BY DESIGN — the owner's rule: *"you still get the remainder of the
/// inventory at the same price"*. Before the cap was deleted the pole pinned to 3% and the fill went
/// through; after, the pole reverts `QuoteUnfillable` and kills a swap the band can partly serve.
contract SkewPricesTheFillableAmountTest is Test {
    uint constant POOL   = 1_000_000e6;   // inventory
    uint constant TARGET = 2_000_000e6;   // shed target (band is short ⇒ scarcity is real)
    uint constant SIGMA  = 1e16;

    /// THE REGRESSION GUARD: asking for MORE than the band holds must not revert.
    function test_E278_OversizedDrainDoesNotRevert() public view {
        uint skew = SwapLib.wellSkewPure(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL * 3);
        assertLt(skew, 1e18, "an oversized drain must price as a partial fill, not an unfillable quote");
    }

    /// AND IT MUST PRICE THE SAME AS DRAINING EXACTLY THE INVENTORY — because that IS what happens.
    /// If these diverge, the swapper's premium depends on a quantity that was refunded to them.
    function test_E278_OversizedPricesLikeAFullDrain() public view {
        uint exact = SwapLib.wellSkewPure(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL);
        uint over  = SwapLib.wellSkewPure(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL * 7);
        assertEq(over, exact, "the premium must not depend on the refunded remainder");
    }

    /// THE POLE STAYS REACHABLE WHERE IT MEANS SOMETHING: an empty band has no partial fill to
    /// protect, so declining is correct there and must not be clamped away.
    function test_E278_EmptyBandStillDeclines() public view {
        uint skew = SwapLib.wellSkewPure(0, TARGET, SIGMA, SwapLib.ethRisk(), 1e6);
        assertGe(skew, 1e18, "an empty band has nothing to fill and must remain unfillable");
    }
}
