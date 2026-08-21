// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E68 — THE PUBLISHED QUOTE IS SIZE-BLIND, AND SETTLEMENT IS NOT.
/// @notice `Aux.wellSkew(asset)` passes `drainUsd6 = 0`, so it returns the INSTANTANEOUS rate.
///         Since §E68, settlement charges the INTEGRAL of the pole over the path the swap itself
///         walks (q0→q1). The starting rate is the CHEAPEST point on that path, so the one-argument
///         quote understates every non-trivial size — and the gap widens toward the pole, which is
///         exactly where being wrong costs most. Its docblock claimed solvers "quote against the
///         EXACT number a swap executes at": true before §E68, false after.
///
///         This is the concrete form of a more general point: inventory, not `L`, is what
///         distinguishes a full range from a drained one at the same price. A quote that does not
///         take the size being drawn cannot express that difference at all.
///
///         `skewWad` is `public pure`, so the property is provable with no pool, fork or fixture.
contract SkewQuoteIsSizeBlindTest is Test {
    uint constant POOL = 1_000_000e6;      // $1m range inventory, 6-dec
    uint constant FLOW = 2_000_000e6;      // shed target above inventory ⇒ genuinely scarce
    uint constant SIG  = 1e16;             // a measured, plausible variance

    /// @notice THE DIVERGENCE IS REAL AND MONOTONE IN SIZE. The quote must be the cheap end.
    function test_InstantaneousQuoteUnderstatesEverySize() public pure {
        uint quoted = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), 0);          // what Aux publishes
        uint[3] memory sizes = [POOL / 10, POOL / 2, (POOL * 9) / 10];
        uint prev = quoted;
        for (uint i; i < sizes.length; i++) {
            uint actual = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), sizes[i]);
            assertGt(actual, quoted, "settlement must cost MORE than the size-blind quote");
            assertGt(actual, prev,   "the charge must rise monotonically with size");
            prev = actual;
        }
    }

    /// @notice THE TWO AGREE IN THE LIMIT, WHICH IS WHY THE ONE-ARG FORM IS NOT WRONG, ONLY NARROW.
    ///         A dust-sized drain must price within rounding of the instantaneous rate — that is
    ///         what makes the size-aware form a strict generalisation rather than a different curve.
    function test_TheyAgreeAsSizeGoesToZero() public pure {
        uint quoted = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), 0);
        uint dust   = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), 1e6);        // $1 of a $1m range
        assertGt(quoted, 0, "PREMISE: a zero quote would make the comparison vacuous");
        assertApproxEqRel(dust, quoted, 1e15, "size-aware must converge to the instantaneous rate");
    }

    /// @notice THE ERROR IS WORST WHERE IT MATTERS MOST — near the pole, not in the flush case.
    ///         PREDICTION BEFORE RUNNING: the quote's relative understatement on a 90% drain must
    ///         exceed its understatement on a 10% drain, because the pole is convex.
    function test_TheUnderstatementGrowsTowardThePole() public {
        uint quoted = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), 0);
        uint small  = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), POOL / 10);
        uint large  = SwapLib.skewWad(POOL, FLOW, SIG, SwapLib.ethRisk(), (POOL * 9) / 10);
        // ratio of actual to quoted, in WAD, so the two are comparable
        uint errSmall = (small * 1e18) / quoted;
        uint errLarge = (large * 1e18) / quoted;
        emit log_named_uint("understatement factor, 10% drain (WAD)", errSmall);
        emit log_named_uint("understatement factor, 90% drain (WAD)", errLarge);
        assertGt(errLarge, errSmall, "the quote's error must widen toward the pole, not shrink");
    }
}
