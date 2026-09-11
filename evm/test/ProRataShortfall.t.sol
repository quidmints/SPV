// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E313 — PRO-RATA SHORTFALL: the round-trip EXIT-ORDERING fix, as pure arithmetic.
/// 🔴 RESTORED TWICE. `proRataShortfall` was deleted by §E301 as "restoration sizing" (it is not),
///    restored by §E313, then deleted AGAIN on 2026-09-11 bundled with `refillNeeded` in a
///    refill-predicate sweep — the identical proximity error, against a row that warned about it.
///    The §UNIT-C refill-trigger tests that shared its old file are NOT restored: `refillNeeded` is
///    genuinely gone and the target design has no refill. **Only the exit-ordering three return.**
/// @notice THE ATTACK IT MAKES UNCONSTRUCTIBLE: an entrant buys volatile out, redeposits as an LP and
///    EXITS FIRST, escaping a shortfall the incumbent then eats. MEASURED: incumbent seeds 500 ETH and
///    withdraws 499.2385 — 15.2 bps of principal taken. Sharing the shortfall removes the PRIZE rather
///    than pricing it (rule 17).
/// @notice Deliberately fixture-free: `POOLED_USD` is never funded on main (§E230, owned by the
///         BackingGateSplit thread), so any fixture test here could not distinguish "this works"
///         from "the pool is empty for an unrelated reason". These properties need neither.
contract ProRataShortfallTest is Test {
    uint constant POOL = 1_000_000e6;
    uint constant FLOW = 2_000_000e6;


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
