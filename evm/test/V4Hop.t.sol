// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {V4Lib} from "../src/imports/V4Lib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice §SESS-79 — **DOES THE V4 ENCODING ACTUALLY EXECUTE?** Build-don't-patch is only correct if
///         the shape we build is the shape the router accepts, and the only way to know that is to
///         send it. ⛔ A unit test over the encoded bytes would assert my own assumptions back at me —
///         which is exactly how `requestSwapOutOnchain` shipped a phantom fifth token with a correct
///         selector and green tests.
/// An external frame so `vm.expectRevert` has something to attach to.
contract V4Caller {
    function hop(address a, address b, uint256 amt, uint256 minOut, uint24 fee, int24 ts)
        external returns (uint256) { return V4Lib.v4Swap(a, b, amt, minOut, fee, ts); }
}

contract V4HopTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant GHO  = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    /// ⭐ The deepest hookless v4 pool for a pair we already trade: USDC/WETH, fee 500, tickSpacing 10,
    ///    liquidity 7,849,184,234,207,033 (measured via StateView, hooks = address(0)).
    function test_V4SwapExecutesAgainstTheRealRouter() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(this), amt);
        uint256 out = V4Lib.v4Swap(USDC, WETH, amt, 0, 500, 10);
        emit log_named_decimal_uint("USDC -> WETH via UniV4", out, 18);
        assertEq(IERC20(USDC).balanceOf(address(this)), 0, "the input must have been spent");
        // 🔴 **AND THE FILL IS TERRIBLE, WHICH IS THE POINT OF RECORDING IT.** 50,000 USDC returned
        //    15.44 WETH — roughly $38.5k of $50k, a **~23% loss** — because this v4 tier is thin.
        //    ⚠️ This test SHIPPED with `assertGt(out, 0)` and a comment admitting it was the
        //    §VACUOUS-BOUNDS shape. Documenting a weak bound does not strengthen it: the docblock
        //    said the encoding was proven, and a zero-bound proves it against nothing.
        // ⇒ **the oracle floor would reject this fill, so it is liveness-safe — but the KEEPER must
        //   never select it**, which is why depth gates candidacy before price (§SESS-67).
        // expected WETH at a ~$2,490 mark, 18-dec: amt(6-dec) * 1e18 / (2490 * 1e6)
        uint256 expected = amt * 1e18 / (2490 * 1e6);
        emit log_named_decimal_uint("expected at a ~$2,490 mark", expected, 18);
        emit log_named_uint("shortfall vs that mark (bps)",
            expected > out ? (expected - out) * 10_000 / expected : 0);
        // ⇒ **SO BOUND IT AT HALF THE MARK INSTEAD OF AT ZERO.** The thin tier costs ~23%, which no
        //   par bound survives — but a crossed direction bit or a pool holding neither token does not
        //   cost 23%, it costs everything. Half is loose enough to never fail on this venue's real
        //   slippage and tight enough that the catastrophic shape cannot pass. `assertGt(out, 0)`
        //   could not tell those two apart, and its message claimed it could.
        assertGt(out, expected / 2, "the v4 leg returned less than half the mark - that is not this "
            "tier's slippage, it is a shape the router mis-executed: wrong currency order, wrong "
            "tickSpacing, or a settle/take pair that did not balance");
    }

    /// 🔴 **THE ROUTE THIS WHOLE ARM EXISTS FOR.** GHO's UniV3 pools hold 8,179 and its V3/WETH pools
    ///    hold zero, so GHO is unroutable without v4. Its hookless v4 pool at fee 500 holds 2.0e21.
    /// ⛔ **THE NAME USED TO SAY "AND ONLY THERE" AND NOTHING BELOW CHECKED IT.** Exclusivity is a
    ///    fact about every OTHER venue on one afternoon — the §POINT-IN-TIME-IS-NOT-AN-INVARIANT
    ///    shape — so it stays an observation in this comment and is out of the name. What the body
    ///    proves is the half that is ours: the v4 leg fills, at par.
    function test_GhoFillsOnV4AtPar() public {
        uint256 amt = 10_000e18;
        deal(GHO, address(this), amt);
        uint256 out = V4Lib.v4Swap(GHO, USDC, amt, 0, 500, 10);
        emit log_named_decimal_uint("GHO -> USDC via UniV4", out, 6);
        // Stables are ~1:1, so a fill this far from par means the wrong pool or the wrong direction.
        // ⚠️ ONE BOUND, NOT TWO: an `assertGt(out, 0)` above this line asserted nothing the par bound
        //    does not already assert, and its message named a claim (`the one venue`) that no line
        //    checked. A redundant bound reads as extra coverage and is not.
        assertGt(out, amt / 1e12 * 90 / 100, "GHO->USDC filled >10% off par (or not at all): wrong "
                                             "pool, wrong direction, or the v4 leg did not fill");
    }

    /// ⚠️ **AN EMPTY TIER MUST FAIL LOUDLY, NOT SILENTLY RETURN LITTLE.** A hacked keeper's entire
    ///    freedom is choosing the fee tier, so the worst it can do must be a revert. USDS/USDC's
    ///    hookless pools exist at every tier and all hold ZERO liquidity — a measured empty venue.
    function test_AnEmptyTierRevertsRatherThanFillingBadly() public {
        address USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
        uint256 amt = 1_000e18;
        V4Caller c = new V4Caller();
        deal(USDS, address(c), amt);
        // ⚠️ **AN EXTERNAL FRAME, BECAUSE `vm.expectRevert` CANNOT BIND TO AN INLINED `internal`
        //    LIBRARY CALL.** CLAUDE.md records this trap firing repeatedly; my first version reported
        //    FAIL on a revert that was exactly what it asked for.
        vm.expectRevert(V4Lib.V4SwapFailed.selector);
        c.hop(USDS, USDC, amt, 1, 500, 10);
    }
}
