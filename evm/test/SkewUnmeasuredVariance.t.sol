// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E59/§E79 — UNMEASURED VARIANCE MUST PRICE AT THE CEILING, NOT AT ZERO.
/// @notice `SwapLib.skewWad` is `public pure`, so this needs no fixture and no fork.
///
/// WHAT THIS CAUGHT (measured 2026-08-16, on a $1m range with a $2m shed target). At σ² = 0 the ETH
/// charge was **0** at 10%, 50% AND 90% drains; only a 100% drain reached the ceiling, and it did so
/// through the SEPARATE `qBar == type(uint).max` pole. BTC returned `SPLICE_FLOOR` alone. The kernel
/// is `Γ·σ²·qBar`, identically 0 when σ² is 0 however scarce the range is — so §E59's guard had to sit
/// OUTSIDE the product, and after §E79 inverted `_maxWellSkew` from ceiling to base there was nothing
/// left holding it. §E79's own comment predicted exactly this: *"returning [the base] here would
/// re-open the free-drain hole E59 closed."*
///
/// ⚠️ THE FIRST VERSION OF THIS PROBE WAS VACUOUS AND LOOKED LIKE A FINDING. It passed `flowUsd = 0`,
///    but `target = flowUsd` and `skewWad` returns the base at `target == 0` (`:845`,`:851`), so it
///    never reached the kernel and every drain size returned an IDENTICAL value. That constancy was
///    the tell. `test_PREMISE_*` below exists so the same mistake fails loudly next time instead of
///    reading as "the skew charges nothing".
contract SkewUnmeasuredVarianceTest is Test {
    uint constant POOL = 1_000_000e6;          // $1m range inventory, 6-dec
    uint constant FLOW = 2_000_000e6;          // shed target ABOVE inventory ⇒ genuinely scarce
    uint constant CEIL = 3e16;                 // MAX_WELL_SKEW, 3%

    /// @notice THE PREMISE EVERY OTHER TEST HERE DEPENDS ON: the kernel must actually be reached.
    ///         If drain size does not move the charge, `skewWad` short-circuited and any zero below
    ///         would be an artifact of the call, not a property of the skew.
    function test_PREMISE_TheKernelIsReachedAtAll() public pure {
        uint small = SwapLib.skewWad(POOL, FLOW, 1e16, SwapLib.ethRisk(), POOL / 10);
        uint large = SwapLib.skewWad(POOL, FLOW, 1e16, SwapLib.ethRisk(), (POOL * 9) / 10);
        assertGt(small, 0, "PREMISE: a measured-variance drain charges nothing, kernel unreached");
        assertGt(large, small, "PREMISE: drain size does not move the charge, kernel unreached");
    }

    /// @notice §E59 part 2, verbatim: "real scarcity (q > 0) plus UNMEASURED variance ⇒ charge the
    ///         ceiling. That is the conservative reading of 'unknown'."
    ///         Partial drains are the case that regressed; the 100% pole was always covered.
    function test_UnmeasuredVarianceChargesTheCeilingAtPartialScarcity() public pure {
        uint[3] memory drains = [POOL / 10, POOL / 2, (POOL * 9) / 10];
        for (uint i; i < drains.length; i++) {
            // PREMISE: the drain must leave the range genuinely scarce (inv1 < target), else the
            // flush branch returns the base and the assertion below tests nothing.
            assertLt(POOL - drains[i], FLOW, "PREMISE: this drain does not create scarcity");
            assertEq(SwapLib.skewWad(POOL, FLOW, 0, SwapLib.ethRisk(), drains[i]), CEIL,
                     "ETH: unmeasured variance with real scarcity must price at the ceiling");
            assertEq(SwapLib.skewWad(POOL, FLOW, 0, SwapLib.btcRisk(), drains[i]), CEIL,
                     "BTC: unmeasured variance with real scarcity must price at the ceiling");
        }
    }

    /// @notice THE SENTINEL MUST NOT SWALLOW A GENUINELY CALM MARKET. §E59 is explicit that only the
    ///         UNMEASURED case is treated as dangerous: "a genuinely calm market reports a SMALL
    ///         NON-ZERO variance and still caps low." A fix that charged the ceiling for tiny-but-real
    ///         variance would be over-charging every quiet tape, so this brackets the other side.
    function test_SmallButMeasuredVarianceStillPricesFarBelowTheCeiling() public pure {
        uint charge = SwapLib.skewWad(POOL, FLOW, 1e12, SwapLib.ethRisk(), POOL / 2);   // σ² tiny but REAL
        assertGt(charge, 0, "a measured variance must still charge something");
        assertLt(charge, CEIL / 100, "a calm-but-measured tape must not be priced near the ceiling");
    }

    /// @notice THE FLUSH BRANCH IS UNAFFECTED — a swap that ends at/above target created no scarcity
    ///         and still owes only the base, sentinel or not. Without this, the fix above could have
    ///         silently started charging 3% on every non-scarce swap and no test would have said so.
    function test_FlushRangeStillOwesOnlyTheBase() public pure {
        // inv1 >= target ⇒ the §UNIT-A flush path, which returns `_maxWellSkew` and never the kernel.
        uint flush = SwapLib.skewWad(POOL, POOL / 10, 0, SwapLib.ethRisk(), 0);
        assertLt(flush, CEIL, "a flush range must not be charged the unknown-variance ceiling");
    }
}
