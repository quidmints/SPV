// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice §SESS-79 — **DOES THE V4 ENCODING ACTUALLY EXECUTE?** Build-don't-patch is only correct if
///         the shape we build is the shape the router accepts, and the only way to know that is to
///         send it. ⛔ A unit test over the encoded bytes would assert my own assumptions back at me —
///         which is exactly how `requestSwapOutOnchain` shipped a phantom fifth token with a correct
///         selector and green tests.
/// An external frame so `vm.expectRevert` has something to attach to.
contract V4Caller {
    function hop(address a, address b, uint256 amt, uint256 minOut, uint24 fee, int24 ts)
        external returns (uint256) { return SwapLib.v4Swap(a, b, amt, minOut, fee, ts); }
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
        uint256 out = SwapLib.v4Swap(USDC, WETH, amt, 0, 500, 10);
        emit log_named_decimal_uint("USDC -> WETH via UniV4", out, 18);
        assertGt(out, 0, "the v4 encoding did not fill - build-don't-patch produced a shape the router "
                         "does not accept, and no amount of unit-testing the bytes would have said so");
        assertEq(IERC20(USDC).balanceOf(address(this)), 0, "the input must have been spent");
        // 🔴 **AND THE FILL IS TERRIBLE, WHICH IS THE POINT OF RECORDING IT.** 50,000 USDC returned
        //    15.44 WETH — roughly $38.5k of $50k, a **~23% loss** — because this v4 tier is thin.
        //    ⚠️ `assertGt(out, 0)` PASSES on that, which is the §VACUOUS-BOUNDS shape in a test I
        //    wrote myself: the defect drives the value toward the asserted side. The encoding is
        //    proven by the fill EXISTING; the venue is condemned by its size.
        // ⇒ **the oracle floor would reject this fill, so it is liveness-safe — but the KEEPER must
        //   never select it**, which is why depth gates candidacy before price (§SESS-67).
        // expected WETH at a ~$2,490 mark, 18-dec: amt(6-dec) * 1e18 / (2490 * 1e6)
        uint256 expected = amt * 1e18 / (2490 * 1e6);
        emit log_named_decimal_uint("expected at a ~$2,490 mark", expected, 18);
        emit log_named_uint("shortfall vs that mark (bps)",
            expected > out ? (expected - out) * 10_000 / expected : 0);
    }

    /// 🔴 **THE ROUTE THIS WHOLE ARM EXISTS FOR.** GHO's UniV3 pools hold 8,179 and its V3/WETH pools
    ///    hold zero, so GHO is unroutable today. Its hookless v4 pool at fee 500 holds 2.0e21.
    function test_GhoIsRoutableOnV4AndOnlyThere() public {
        uint256 amt = 10_000e18;
        deal(GHO, address(this), amt);
        uint256 out = SwapLib.v4Swap(GHO, USDC, amt, 0, 500, 10);
        emit log_named_decimal_uint("GHO -> USDC via UniV4", out, 6);
        assertGt(out, 0, "GHO did not fill on v4 - the one venue measured to have its liquidity");
        // Stables are ~1:1, so a fill this far from par means the wrong pool or the wrong direction.
        assertGt(out, amt / 1e12 * 90 / 100, "GHO->USDC filled >10% off par: wrong pool or direction");
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
        vm.expectRevert(SwapLib.V4SwapFailed.selector);
        c.hop(USDS, USDC, amt, 1, 500, 10);
    }
}
