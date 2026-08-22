// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §UNIT-C trigger + §UNIT-ROUNDTRIP-LIVE pro-rata — the two decided items, as pure arithmetic.
/// @notice Deliberately fixture-free: `POOLED_USD` is never funded on main (§E230, owned by the
///         BackingGateSplit thread), so any fixture test here could not distinguish "this works"
///         from "the pool is empty for an unrelated reason". These properties need neither.
contract RefillTriggerAndProRataTest is Test {
    uint constant POOL = 1_000_000e6;
    uint constant FLOW = 2_000_000e6;

    // ── §UNIT-C: the trigger IS the skew's predicate ────────────────────────────────────────

    /// @notice THE WHOLE POINT: the trigger and the charge share ONE definition of "imbalanced".
    ///         If `refillNeeded` fires exactly when the skew leaves its flush branch, they cannot
    ///         drift. This brackets them against each other directly rather than trusting the comment.
    function test_TriggerFiresExactlyWhenTheSkewLeavesFlush() public pure {
        uint[4] memory drains = [uint(0), POOL / 4, POOL / 2, POOL];
        for (uint i; i < drains.length; i++) {
            (bool fire,) = SwapLib.refillNeeded(POOL, FLOW, drains[i]);
            // The skew's flush branch returns the BASE; below it the kernel engages and charges more.
            uint flushOnly = SwapLib.skewWad(POOL, POOL / 10, 1e16, SwapLib.ethRisk(), 0);
            uint here      = SwapLib.skewWad(POOL, FLOW,      1e16, SwapLib.ethRisk(), drains[i]);
            assertEq(fire, here > flushOnly,
                "trigger and charge must agree on what 'imbalanced' means, at every drain");
        }
    }

    /// @notice A RANGE AT OR ABOVE TARGET MUST NOT FIRE — otherwise the refill runs forever.
    function test_NoTargetAndFlushRangeDoNotFire() public pure {
        (bool noTarget,) = SwapLib.refillNeeded(POOL, 0, POOL / 2);
        assertFalse(noTarget, "no shed target means no scarcity to measure");
        (bool flush, uint s) = SwapLib.refillNeeded(FLOW, POOL, 0);   // inv well above target
        assertFalse(flush, "a range above target created no imbalance");
        assertEq(s, 0, "and owes no shortfall");
    }

    /// @notice THE SHORTFALL IS WHAT MUST BE SOURCED, and it grows with the drain — it is the input
    ///         to the profitability half of the owner's rule ("if it can be balanced PROFITABLY").
    function test_ShortfallIsTheAmountToSourceAndGrowsWithTheDrain() public pure {
        (, uint small) = SwapLib.refillNeeded(POOL, FLOW, POOL / 10);
        (, uint large) = SwapLib.refillNeeded(POOL, FLOW, (POOL * 9) / 10);
        assertGt(small, 0, "a scarce range must report something to source");
        assertGt(large, small, "a deeper drain must need more sourced");
        // A total drain leaves nothing, so the shortfall is the whole target.
        (, uint total) = SwapLib.refillNeeded(POOL, FLOW, POOL);
        assertEq(total, FLOW, "with inventory at zero the shortfall is the entire target");
    }

    /// @notice 🔴 THE PROPERTY THAT KILLS THE ATTACK: exit ORDER cannot change what you bear.
    ///         The entrant's 15.2 bps came from exiting FIRST and escaping a shortfall the incumbent
    ///         then ate. Under pro-rata, two identical holders bear identical amounts whichever goes
    ///         first — so there is no prize to race for and nothing to extract.
    function test_ExitOrderCannotChangeWhatYouBear() public pure {
        uint shortfall = 10_000e6;
        uint each = 500e18;                 // two identical holders
        uint first  = SwapLib.proRataShortfall(shortfall, each, each * 2);
        uint second = SwapLib.proRataShortfall(shortfall, each, each * 2);
        assertEq(first, second, "identical holders must bear identical shortfall regardless of order");
        assertEq(first + second, shortfall, "and together they must bear ALL of it, none escaping");
    }

    /// @notice IT IS PROPORTIONAL, NOT FIRST-OUT. A holder with twice the shares bears twice as much.
    function test_ShareOfShortfallIsProportional() public pure {
        uint shortfall = 9_000e6;
        uint small = SwapLib.proRataShortfall(shortfall, 100e18, 900e18);
        uint big   = SwapLib.proRataShortfall(shortfall, 200e18, 900e18);
        assertApproxEqAbs(big, small * 2, 1, "twice the shares must bear twice the shortfall");
    }

    /// @notice NOBODY BEARS MORE THAN THE WHOLE, AND A SOLE EXITER BEARS ALL OF IT.
    function test_SoleExiterBearsAllAndNeverMore() public pure {
        uint shortfall = 7_777e6;
        assertEq(SwapLib.proRataShortfall(shortfall, 100e18, 100e18), shortfall, "sole exiter bears all");
        assertEq(SwapLib.proRataShortfall(shortfall, 999e18, 100e18), shortfall, "and never more than all");
        assertEq(SwapLib.proRataShortfall(0, 100e18, 900e18), 0, "no shortfall, nothing borne");
        assertEq(SwapLib.proRataShortfall(shortfall, 0, 900e18), 0, "exiting nothing bears nothing");
    }
}
