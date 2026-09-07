// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {RLUSD_TOKEN, PYUSD_TOKEN, USDT_TOKEN, DAI_TOKEN, USDG_TOKEN,
        CRVUSD_TOKEN} from "../src/imports/Interfaces.sol";

/// ⚠️ **`vm.expectRevert` CANNOT BIND TO AN INLINED `internal` LIBRARY CALL** — `LevMath._hubHop(...)`
/// compiles into the caller, so there is no external frame for the cheatcode to attach to and the
/// expectation silently matches the NEXT external call instead. CLAUDE.md records this trap firing
/// twice before; this wrapper is the fix, not a convenience.
contract HubHopCaller {
    function hop(address stable, uint256 amt, bool toUsdc) external returns (uint256) {
        return LevMath._hubHop(stable, amt, toUsdc, 0, 0);
    }
}

/// @notice §SESS-52 — **ONE TABLE. `_routeOf` IS DELETED AND NOTHING REPLACED IT.**
///
/// 🔴 **THE HISTORY IS THE POINT.** §SESS-51 deleted `_routeOf` (two rows) and created `Aux.hubHopOf`
///    to hold them — **while `_hubRowOf`, in the same file, already held both rows and four more.** The
///    owner caught it from the variable name. `_hubHop` now reads `_hubRowOf`, and the mapping, setter,
///    event, interface member, two offset constants, deploy seeding and a threaded `aux` parameter are
///    all gone. See CLAUDE.md standing rule 23.
contract HubHopRosterTest is AllesFixture {

    /// ⭐ ① **THE ROUTABLE SET, ASSERTED HEAD-ON — INCLUDING THE FOUR THAT CHANGED.**
    /// 🔴 **THIS IS A DELIBERATE BEHAVIOUR CHANGE AND IT IS STATED, NOT HIDDEN.** §SESS-24 measured
    ///    that making USDT/DAI/USDG/crvUSD executable flips four consolidate slices from REFUNDED to
    ///    SWAPPED. Under one table they are executable. That is defensible on the numbers the rows were
    ///    chosen by — **4 / 1 / -1 / 0 bps, flat to $1M**, each verified against `coins()` — and a
    ///    slice that swaps at a measured-flat venue serves the LP better than one refunded mid-protect.
    /// ⚠️ If this assertion ever has to be weakened to make something pass, the second table is being
    ///    re-invented; re-read standing rule 23 before doing it.
    function test_EverySelectedRowIsTradeableAndNothingElseIs() public pure {
        address[6] memory rows = [RLUSD_TOKEN, PYUSD_TOKEN, USDT_TOKEN, DAI_TOKEN, USDG_TOKEN, CRVUSD_TOKEN];
        for (uint256 i; i < rows.length; ++i)
            assertTrue(LevMath._routableStable(rows[i]), "a selected row is not tradeable");
        // Exclusions stay excluded: a stable with no row must NOT become routable by accident. §SESS-24
        // rejected `0xEf3a1CaE…`, which answers `get_dy` for four stables with a 95% loss and no revert.
        assertFalse(LevMath._routableStable(address(0xBEEF)), "an unlisted token became routable");
        assertFalse(LevMath._routableStable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            "WETH is not a dollar and must not route");
    }

    /// ⭐ ② **IT FILLS, BOTH WAYS, THROUGH THE REAL POOL.** A table test proves the rows; only an
    ///    execution proves the route. Both directions matter because ONE row serves both, so an index
    ///    mix-up that is harmless one way is a wrong-pair swap the other — and there is no id to
    ///    assert against, only the round-trip.
    function test_TheRouteFillsInBothDirections() public {
        uint256 amt = 10_000e18;                       // RLUSD is 18-dec
        deal(RLUSD_TOKEN, address(this), amt);
        uint256 usdcOut = LevMath._hubHop(RLUSD_TOKEN, amt, true, 0, 0);
        emit log_named_uint("RLUSD -> USDC out (6-dec)", usdcOut);
        assertGt(usdcOut, 0, "the route did not fill - a zero here is the whole defect");

        uint256 back = LevMath._hubHop(RLUSD_TOKEN, usdcOut, false, 0, 0);
        emit log_named_uint("USDC -> RLUSD back (18-dec)", back);
        assertGt(back, amt * 90 / 100, "round-trip lost >10% - indices are crossed, not a fee");
    }

    /// ⭐ ③ **A STABLE WITH NO ROW FAILS CLOSED, LOUDLY.** `_hubHop` reverts rather than returning 0:
    ///    a caller that sizes a hedge from "converted nothing" is the silent failure this prevents.
    ///    ⚠️ `consolidate` never reaches it — it asks `_routableStable` first and refunds the slice —
    ///    so the two behaviours are complementary, not contradictory.
    function test_AStableWithNoRowRevertsRatherThanReturningZero() public {
        HubHopCaller c = new HubHopCaller();
        vm.expectRevert(LevMath.NoStableRoute.selector);
        c.hop(address(0xBEEF), 1_000e6, true);
    }

    // ⛔ NO "does the RLUSD row name the right pool" TEST HERE, AND NO `_hubRowOfForTest` ACCESSOR TO
    //    ENABLE ONE. `_hubRowOf` is `private`, and `CurveTablePins.t.sol` ALREADY pins all six rows and
    //    asserts the exclusions stay zero. Adding an accessor so this file could re-assert it would be
    //    standing rule 23's exact failure - a declaration that exists to serve a duplicate test.
}
