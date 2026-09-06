// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {HOP_I_OFFSET, HOP_J_OFFSET,
        RLUSD_TOKEN, PYUSD_TOKEN, USDT_TOKEN, DAI_TOKEN, USDG_TOKEN, CRVUSD_TOKEN,
        CURVE_USDC_RLUSD, CRV_RLUSD_IDX, CRV_RLUSD_USDC_IDX} from "../src/imports/Interfaces.sol";

interface IB { function balanceOf(address) external view returns (uint256); }

/// ⚠️ **`vm.expectRevert` CANNOT BIND TO AN INLINED `internal` LIBRARY CALL** — `LevMath._hubHop(...)`
/// compiles into the caller, so there is no external frame for the cheatcode to attach to and the
/// expectation silently matches the NEXT external call instead. CLAUDE.md records this exact trap
/// firing twice before; this wrapper is the fix, not a convenience.
contract HubHopCaller {
    function hop(address aux, address stable, uint256 amt, bool toUsdc) external returns (uint256) {
        return LevMath._hubHop(aux, stable, amt, toUsdc, 0);
    }
}

/// @notice §SESS-51 — **THE ROUTE MOVED FROM BYTECODE TO THE ROSTER. THESE PIN THAT IT MOVED AND
///         NOTHING ELSE DID.**
///
/// `LevMath._routeOf` — a compile-time two-row `if`-chain — is deleted; `Aux.hubHopOf` holds the same
/// two routes as owner-set data. The risk in a refactor this shape is not that it breaks loudly, it is
/// that it **silently changes WHICH stables consolidate will trade**, because `_routableStable` decides
/// whether a slice is swapped or refunded to the LP.
contract HubHopRosterTest is AllesFixture {

    /// ⭐ ① **BEHAVIOUR-NEUTRALITY, ASSERTED IN BOTH DIRECTIONS.** §SESS-24 measured that adding
    ///    USDT/DAI/USDG/crvUSD to the EXECUTION table flips four consolidate slices from refunded to
    ///    swapped and breaks `test_ProtectFromQuid_HostileOperatorNetsZero`. The deploy therefore seeds
    ///    **exactly the two rows the deleted table held**, and this asserts the exclusions stay
    ///    excluded — the half a "did it still work?" check would miss.
    /// ⚠️ A one-sided version of this (only the inclusions) would be the §VACUOUS-BOUNDS shape: seeding
    ///    every stable would pass it while changing behaviour for four of them.
    function test_TheRosterHoldsExactlyTheRoutesTheDeletedTableHeld() public view {
        assertTrue(LevMath._routableStable(address(AUX), RLUSD_TOKEN), "RLUSD lost its route");
        assertTrue(LevMath._routableStable(address(AUX), PYUSD_TOKEN), "PYUSD lost its route");
        assertTrue(LevMath._routableStable(address(AUX), address(USDC)),        "USDC is the hub, always routable");
        // The quote-only four: priced by `_quoteOf`, deliberately NOT executable.
        assertFalse(LevMath._routableStable(address(AUX), USDT_TOKEN),   "USDT became executable - behaviour changed");
        assertFalse(LevMath._routableStable(address(AUX), DAI_TOKEN),    "DAI became executable - behaviour changed");
        assertFalse(LevMath._routableStable(address(AUX), USDG_TOKEN),   "USDG became executable - behaviour changed");
        assertFalse(LevMath._routableStable(address(AUX), CRVUSD_TOKEN), "crvUSD became executable - behaviour changed");
    }

    /// ⭐ ② **THE WORD DECODES TO THE POOL AND INDICES THE CONSTANTS ALWAYS NAMED.** The two pools are
    ///    ordered OPPOSITELY on mainnet, so a shared index constant would be silently wrong for one of
    ///    them — a wrong-pair swap at size with no revert. This pins the pair, not just the pool.
    function test_TheSeededWordDecodesToTheRightPoolAndIndices() public view {
        uint256 w = AUX.hubHopOf(RLUSD_TOKEN);
        assertEq(address(uint160(w)), CURVE_USDC_RLUSD, "wrong pool");
        assertEq(int128(uint128(uint8(w >> HOP_I_OFFSET))), CRV_RLUSD_IDX,      "i must be RLUSD's own index");
        assertEq(int128(uint128(uint8(w >> HOP_J_OFFSET))), CRV_RLUSD_USDC_IDX, "j must be USDC's index");
    }

    /// ⭐ ③ **AND IT ACTUALLY FILLS — BOTH WAYS, THROUGH THE REAL POOL.** A decode test proves the
    ///    encoding; only an execution proves the route. Both directions matter because ONE word serves
    ///    both, so an index swap that is harmless one way is a wrong-pair swap the other.
    function test_TheRosterRouteFillsInBothDirections() public {
        uint256 amt = 10_000e18;                       // RLUSD is 18-dec
        deal(RLUSD_TOKEN, address(this), amt);
        uint256 usdcOut = LevMath._hubHop(address(AUX), RLUSD_TOKEN, amt, true, 0);
        emit log_named_uint("RLUSD -> USDC out (6-dec)", usdcOut);
        assertGt(usdcOut, 0, "the roster route did not fill - a zero here is the whole defect");

        uint256 back = LevMath._hubHop(address(AUX), RLUSD_TOKEN, usdcOut, false, 0);
        emit log_named_uint("USDC -> RLUSD back (18-dec)", back);
        assertGt(back, 0, "the reverse direction did not fill");
        // Round-trip must lose only fees, never ~everything: an index mix-up trades the wrong pair and
        // shows up here as a collapse, which a one-way test cannot see.
        assertGt(back, amt * 90 / 100, "round-trip lost >10% - indices are crossed, not a fee");
    }

    /// ⭐ ④ **THE ROUTE IS OWNER-SET, AND THAT IS LOAD-BEARING.** `protectFromQuid` is permissionless
    ///    and consolidation runs against a flat 100 bps `CONSOL_SLIP_BPS`; if any caller could re-point
    ///    a hop they would own the SELECTION of every venue, which the floor bounds the loss of but not
    ///    the choice of. This is the check that keeps the move from becoming a privilege escalation.
    function test_ARandomCallerCannotRepointAHubRoute() public {
        vm.prank(address(0xBADBAD));
        vm.expectRevert();
        AUX.setHubHop(RLUSD_TOKEN, uint256(uint160(address(0xDEAD))));
        assertEq(address(uint160(AUX.hubHopOf(RLUSD_TOKEN))), CURVE_USDC_RLUSD, "route was re-pointed");
    }

    /// ⭐ ⑤ **A STABLE WITH NO ENTRY FAILS CLOSED, LOUDLY.** `_hubHop` reverts rather than returning 0,
    ///    because a caller that sizes a hedge from "converted nothing" is the silent failure the revert
    ///    exists to prevent. ⚠️ `consolidate` never reaches this — it asks `_routableStable` first and
    ///    refunds the slice — so the two behaviours are complementary, not contradictory.
    function test_AStableWithNoRouteRevertsRatherThanReturningZero() public {
        HubHopCaller c = new HubHopCaller();
        deal(USDT_TOKEN, address(c), 1_000e6);
        vm.expectRevert(LevMath.NoStableRoute.selector);
        c.hop(address(AUX), USDT_TOKEN, 1_000e6, true);
    }
}
