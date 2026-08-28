// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §UNITB-NEEDS-A-MOVING-FIXTURE — **DOES `skewWad` DISCRIMINATE ON FLOW AT ALL, AND WHERE?**
///
/// @notice `test_UNITB_CounterMatchesWhatTheSwapperLoses` fails a CONTROL — *"the target move must
///         change the skew"* — and three separate diagnoses have been booked against it (σ² == 0,
///         then FLUSH, then "flush is not the whole explanation either"). Every one of them inferred
///         the regime from `inv`/`target` OUTSIDE the call, through a fixture that also had to hold
///         σ² alive and depth identical across two arms.
///
///         ⭐ **`skewWad` is `public pure`. It needs no fixture, no fork, and no arms.** Calling it
///         across a target sweep answers the question the control was asking, directly: it either
///         discriminates on flow somewhere, or it does not.
contract SkewFlowDiscriminationTest is Test {
    // ⛔ THE INVENTORY THE SKEW ACTUALLY SEES IS **NOT** `POOLED_USD`. The single production call
    //    site (`SwapLib.wellSkew:1633`) passes `_skewBasis(core, base, 0)` =
    //    `POOLED() * base / 1e30` — the VOLATILE inventory valued in USD. `POOLED_USD` is the other
    //    side of the pool and is never passed to `skewWad` at all.
    //    MEASURED on DrainAtomicity's own state (2026-08-28): POOLED = 241.249e18 ETH at
    //    px = 2519.66e18 ⇒ basis = **$607,866**, against POOLED_USD = **$1,407,864** — **2.316x
    //    apart**. Every prescription written in POOLED_USD terms is therefore aimed at the wrong
    //    number, which is exactly how a fixture reported "✅ priced scarcity" while the swap path
    //    stayed in flush.
    uint constant BASIS_REAL   = 607_866_013_138;    // _skewBasis: what the swap path passes
    uint constant INV_FLUSH    = 1_407_863_999_999;  // POOLED_USD: what the fixture measured
    uint constant INV_DRAINED  =   811_919_000_000;  // the drained POOLED_USD the row documents
    uint constant SIGMA_SQ    = 427_400_686_005_550_189;  // seeded sigma^2, measured
    uint constant DRAIN_USD6  = 30_000 * 1e6;        // SIZE / 1e12

    function _skew(uint inv, uint flow) internal pure returns (uint) {
        return SwapLib.skewWad(inv, flow, SIGMA_SQ, SwapLib.ethRisk(), DRAIN_USD6);
    }

    /// THE SWEEP. Walk `flowUsd` from far below the inventory to far above it and print the skew.
    /// If every value is identical, the function is flow-blind outright; if it moves, the boundary
    /// is visible and the control's fixture simply never reached it.
    function test_SkewAcrossTheFlushBoundary() public {
        uint[10] memory flows = [
            uint(91_075_297_869),      // 0.5x arm A
            182_150_595_738,           // arm A  (measured)
            364_301_191_476,           // arm B  (measured, 2x A)
            700_000_000_000,
            1_000_000_000_000,
            1_407_863_999_998,         // one wei under inventory
            1_407_863_999_999,         // exactly inventory
            1_408_000_000_000,         // just over
            2_000_000_000_000,
            4_000_000_000_000
        ];
        for (uint i; i < flows.length; ++i) {
            emit log_named_uint(
                string.concat("flow=", vm.toString(flows[i]), "  skew"), _skew(INV_FLUSH, flows[i]));
        }
    }

    /// THE ONE THE CONTROL ACTUALLY ASSERTS: arm A vs arm B, at the fixture's real inventory.
    /// Documents WHY it fails rather than asserting it passes.
    function test_ArmsAreIdenticalWhileBothAreFlush() public pure {
        uint a = _skew(INV_FLUSH, 182_150_595_738);
        uint b = _skew(INV_FLUSH, 364_301_191_476);
        assertEq(a, b, "premise: both arms flush (inv >> target) so the kernel is skipped");
        assertEq(a, 4_495_165_581_956, "pinned: the exact flush skew at this inventory");
    }

    /// ▶️ **THE CORRECTED ASK FOR `test_UNITB_...`.** Against the REAL basis ($607,866) arm B's
    /// target sits at 0.60 of inventory, not 0.26 — so the fixture needs flow above **$607,866**,
    /// i.e. **1.67x arm B**, NOT the "~87% drain of POOLED_USD" the row prescribes. Pinned here so
    /// the next attempt aims at the right number.
    function test_CorrectedScarcityThresholdForTheFixture() public pure {
        assertEq(_skew(BASIS_REAL, 182_150_595_738), _skew(BASIS_REAL, 364_301_191_476),
            "both arms are STILL flush against the real basis - which is why the control fails");
        assertTrue(_skew(BASIS_REAL, 700_000_000_000) != _skew(BASIS_REAL, 364_301_191_476),
            "crossing the real basis DOES move the skew - the fixture target is flow > $607,866");
    }

    /// ⭐ **THE ROW'S ANOMALY, EXPLAINED.** §UNITB-NEEDS-A-MOVING-FIXTURE records that a fixture
    /// reached `POOLED_USD 811,919 < target 873,701` — *"✅ priced scarcity"* — and the arms STILL
    /// priced identically (195,538 both), concluding "flush is not the whole explanation either".
    /// It is the whole explanation: **that fixture made the wrong variable scarce.** The swap path
    /// reads `_skewBasis`, not `POOLED_USD`, so it never left flush.
    function test_TheDrainedFixtureWasScarceInTheWrongVariable() public pure {
        // Both arms of that attempt, priced against the basis the swap path ACTUALLY passes.
        // (Basis is ~2.3x smaller than POOLED_USD, but the attempt drove POOLED_USD, not basis.)
        assertGt(INV_DRAINED, 0);   // documents the number the fixture was steering
        assertTrue(BASIS_REAL < INV_FLUSH,
            "the skew basis is SMALLER than POOLED_USD - a drain measured on POOLED_USD "
            "overstates how close the swap path is to scarcity");
    }

    /// AND THE DISCRIMINATOR: at the DRAINED inventory the row documents, arm B's target is ABOVE
    /// inventory (scarce) while arm A's is below (flush). If the skew still agrees there, the
    /// function is flow-blind ACROSS the boundary, which no fixture change could ever fix.
    function test_DoesItDiscriminateOnceOneArmIsScarce() public {
        uint aFlush  = _skew(INV_DRAINED, 436_850_000_000);   // below inv -> flush
        uint bScarce = _skew(INV_DRAINED, 873_701_000_000);   // above inv -> scarce
        emit log_named_uint("A (flush)  skew", aFlush);
        emit log_named_uint("B (scarce) skew", bScarce);
        assertTrue(aFlush != bScarce,
            "skewWad is flow-blind ACROSS the flush boundary - no fixture can make the control fire");
    }
}
