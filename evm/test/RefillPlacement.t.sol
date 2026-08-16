// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E48 REFILL PLACEMENT — the refill as a placement computation, not a trade.
/// @notice These are PURE-FUNCTION tests on purpose: the whole point of the placement form is that
///         it needs no pool, no tick, no sqrt-price and no counterparty, so a test that needed a
///         fixture would be evidence the form is wrong.
contract RefillPlacementTest is Test {
    uint constant PX = 1_884e18;        // USD18 per 1e18 ETH, near the fork's live price
    uint constant D  = 20;              // BAND_DELTA, ±0.2%

    /// @notice THE TARGET COMPOSITION HOLDS BY CONSTRUCTION. Whatever the inventory mix, the two
    ///         legs PLACED must be equal in VALUE — that is what "1:1" means, and it is the property
    ///         the ratio-symmetric bounds deliver without a square root.
    function test_PlacedLegsAreEqualInValue() public pure {
        uint[3] memory tok = [uint(400e18), 400e18, 10e18];
        uint[3] memory usd = [uint(753_600e6), 100_000e6, 900_000e6];
        for (uint i; i < 3; i++) {
            (uint tokP, uint usd6P,,,,) = SwapLib.refillPlacement(tok[i], usd[i], PX, D);
            assertGt(tokP + usd6P, 0, "PREMISE: nothing was placed, so the check is vacuous");
            uint tokPAsUsd6 = tokP * PX / 1e30;
            // exact to rounding: both sides are one mulDiv from the same quantity
            assertApproxEqAbs(tokPAsUsd6, usd6P, 1, "placed legs are not 1:1 by value");
        }
    }

    /// @notice THE SCARCER LEG BINDS, AND THE SURPLUS IS REPORTED RATHER THAN HIDDEN.
    ///         Prediction before running: with ETH scarce, ALL ETH is placed and USD is left idle;
    ///         with USD scarce, the mirror. Exactly one side idles in each case.
    function test_ScarceLegBinds_AndSurplusIdles() public pure {
        // ETH scarce: 10 ETH (~$18,840) against $900,000
        (uint tokP, uint usdP, uint tokI, uint usdI,,) =
            SwapLib.refillPlacement(10e18, 900_000e6, PX, D);
        assertEq(tokP, 10e18, "ETH is scarce, so all of it should be placed");
        assertEq(tokI, 0,     "no ETH should idle when ETH is the binding leg");
        assertGt(usdI, 0,     "USD surplus must be reported, not silently absorbed");
        assertEq(usdP + usdI, 900_000e6, "USD must be conserved across placed + idle");

        // USD scarce: 400 ETH (~$753,600) against $100,000
        (tokP, usdP, tokI, usdI,,) = SwapLib.refillPlacement(400e18, 100_000e6, PX, D);
        assertEq(usdP, 100_000e6, "USD is scarce, so all of it should be placed");
        assertEq(usdI, 0,         "no USD should idle when USD is the binding leg");
        assertGt(tokI, 0,         "ETH surplus must be reported");
        assertEq(tokP + tokI, 400e18, "ETH must be conserved across placed + idle");
    }

    /// @notice "SHORT ETH OUTRIGHT" IS REPORTED HONESTLY, NOT PAPERED OVER. This is the case where
    ///         "restore to 1:1" and "maximise representation of what we hold" DIVERGE: no placement
    ///         can conjure ETH, so the band ends 1:1 on a SMALLER position with USD left over.
    function test_ShortEthCannotBeFixedByPlacement() public pure {
        (uint tokP, uint usdP,, uint usdI,,) = SwapLib.refillPlacement(1e18, 500_000e6, PX, D);
        assertEq(tokP, 1e18, "all the ETH we hold should be represented");
        assertApproxEqAbs(usdP, 1_884e6, 1, "USD placed should match the ETH's value, not the balance");
        assertGt(usdI, 490_000e6, "the vast majority of USD cannot be represented and must idle");
    }

    /// @notice THE BOUNDS ARE RATIO-SYMMETRIC, WHICH IS WHY NO ROOT IS NEEDED.
    ///         px must be the GEOMETRIC mean of the bounds: pLower·pUpper == px².
    function test_BoundsAreRatioSymmetricAroundPx() public pure {
        (,,,, uint lo, uint hi) = SwapLib.refillPlacement(400e18, 753_600e6, PX, D);
        assertLt(lo, PX, "lower bound must sit below px");
        assertGt(hi, PX, "upper bound must sit above px");
        // geometric-mean identity, to rounding: lo*hi == px*px
        assertApproxEqRel(lo * hi, PX * PX, 1e12, "px is not the geometric mean of the bounds");
        // and the half-width is the one asked for
        assertApproxEqRel(hi, PX * (10_000 + D) / 10_000, 1e12, "upper bound is not px*(1+delta)");
    }

    /// @notice THE PLACEMENT FUNCTION IS ALSO THE ATTRIBUTION KEY — idle inventory IS the imbalance.
    ///         The owner's frame is *"charging for the imbalance created"*. Un-representable inventory
    ///         is precisely that: value the band holds but cannot put to work at the current price.
    ///         So the imbalance a trade creates = the INCREASE in idle value it leaves behind, computed
    ///         from inventory alone — no pool, no tick, no oracle beyond the price already in hand.
    ///
    ///         ANALYTIC PREDICTION, STATED BEFORE THE RUN. From a balanced band (x·px == y, idle 0), a
    ///         drain of D ETH leaves (x−D) ETH and (y + D·px) USD. ETH becomes the binding leg, so
    ///         placeable USD is (x−D)·px and
    ///             idle = (y + D·px) − (x−D)·px = 2·D·px
    ///         The imbalance created is TWICE the value of the ETH removed — the swapper's own
    ///         withdrawal, plus the USD they paid in that now has no ETH to pair with.
    function test_IdleIsTheImbalanceCreated_AndItIsTwiceTheDrain() public pure {
        uint x = 400e18;
        uint y = x * PX / 1e30;                       // exactly balanced: x*px == y
        (,, uint tokI0, uint usdI0,,) = SwapLib.refillPlacement(x, y, PX, D);
        assertEq(tokI0 + usdI0, 0, "PREMISE: the starting band must be balanced, else the delta is not the trade's");

        uint drain = 32e18;                            // D
        uint paid  = drain * PX / 1e30;                // USD the swapper pays in
        (,, uint tokI1, uint usdI1,,) = SwapLib.refillPlacement(x - drain, y + paid, PX, D);

        assertEq(tokI1, 0, "ETH is now the binding leg, so no ETH should idle");
        uint predicted = 2 * paid;                     // 2*D*px
        assertApproxEqAbs(usdI1, predicted, 2, "idle USD is not 2x the drained value");

        // And it is a DELTA, so a second identical drain adds the same again -- the measure is
        // additive in the imbalance created rather than in the level arrived into.
        (,,, uint usdI2,,) = SwapLib.refillPlacement(x - 2 * drain, y + 2 * paid, PX, D);
        assertApproxEqAbs(usdI2 - usdI1, predicted, 2, "the second drain must create the same imbalance as the first");
    }

    /// @notice DEGENERATE INPUT MUST NOT SILENTLY PLACE. A zero price cannot value either leg, so
    ///         everything idles and the bounds are zero — a caller that ignores that and places
    ///         anyway is the failure this guards.
    function test_ZeroPricePlacesNothing() public pure {
        (uint tokP, uint usdP, uint tokI, uint usdI, uint lo, uint hi) =
            SwapLib.refillPlacement(400e18, 100_000e6, 0, D);
        assertEq(tokP + usdP, 0, "nothing may be placed at an unknown price");
        assertEq(tokI, 400e18,   "all volatile must be reported idle");
        assertEq(usdI, 100_000e6, "all USD must be reported idle");
        assertEq(lo + hi, 0,     "bounds must be zero, not a range around zero");
    }
}
