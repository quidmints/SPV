// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";

// §POOL-VENUE — the FORK characterisation tests that lived here now sit in `LevCascade.t.sol`
// beside the fixture they need. Reaching that fixture by `is LevCascadeProbe` INHERITED its 18
// tests and re-ran them all (measured: 21 tests reported, 18 of them clones on a fork).
// What stays here is the one invariant that needs no fork at all.

/// @notice 🔴 THE ONE INVARIANT THE WALK IS MOST LIKELY TO BREAK — AND IT NEEDS NO FORK, SO IT RUNS
///         IN MILLISECONDS AND CANNOT BE SKIPPED BY A DEAD RPC.
///
/// `LevMath.netEquityBase` FLOORS AT ZERO. With one pooled position, "floor then sum" and "sum then
/// floor" are the same number, which is why nothing today distinguishes them. The moment a second
/// venue joins they diverge, and the wrong order SOCIALISES one venue's underwater slice across the
/// book — over-reporting equity. That is §E333's error, the one that drove `committedUsd18` high
/// enough to trip `checkBacking` on the BTC delivery path.
/// ⇒ **THE WALK MUST SUM COLLATERAL AND DEBT FIRST AND FLOOR ONCE OVER THE TOTALS.**
contract NetEquityFloorsOnce is Test {
    /// A solvent venue and an underwater one. Floor-per-venue hides the second's deficit at 0;
    /// floor-once lets it offset the first, which is the honest book-level number.
    function test_FloorPerVenueOverReportsAgainstFloorOnce() public pure {
        uint px = 3_000e18;                      // USD per collateral unit, 1e18
        uint c1 = 10e18; uint d1 =  6_000e18;    // solvent:    30k coll vs 6k debt
        uint c2 =  1e18; uint d2 = 30_000e18;    // underwater:  3k coll vs 30k debt

        uint floorOnce   = LevMath.netEquityBase(c1 + c2, d1 + d2, px);
        uint floorPerVen = LevMath.netEquityBase(c1, d1, px) + LevMath.netEquityBase(c2, d2, px);

        assertGt(floorPerVen, floorOnce,
            "floor-per-venue must OVER-report: the underwater venue's deficit is clamped away");
        assertEq(LevMath.netEquityBase(c2, d2, px), 0, "premise: the second venue is underwater");
    }

    /// ...and where nothing is underwater the two orders agree, so the fix is not a behaviour change
    /// for the healthy book — it only bites in the case that matters.
    function test_BothOrdersAgreeWhenEveryVenueIsSolvent() public pure {
        uint px = 3_000e18;
        uint c1 = 10e18; uint d1 = 6_000e18;
        uint c2 =  5e18; uint d2 = 3_000e18;
        assertEq(LevMath.netEquityBase(c1 + c2, d1 + d2, px),
                 LevMath.netEquityBase(c1, d1, px) + LevMath.netEquityBase(c2, d2, px),
                 "solvent book: floor order is immaterial");
    }
}
