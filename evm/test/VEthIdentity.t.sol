// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Alles} from "./Alles.t.sol";
import {VEth} from "../src/VEth.sol";

/// @notice §J.2b — VEth carries the vETH ERC-4626 identity; Vogue no longer claims it.
///
///         WHY THIS TEST IS NEEDED. Vogue is the band manager for BOTH asset classes (its math is
///         parameterised by `isBTC` throughout), so a single-asset 4626 identity on it was a false
///         claim: a 4626-aware integrator would read the ETH side and silently mis-account BTC.
///         This pins BOTH halves of the fix — that VEth reports the identity correctly, AND that
///         Vogue has actually STOPPED reporting it. The second half is the one that can rot: the
///         identity could be re-added to Vogue by a later edit and every other test would stay green.
contract VEthIdentity is Alles {

    /// @dev Vogue has a `fallback() external payable {}`, so a removed function does NOT make the raw
    ///      call fail — the fallback swallows it and returns SUCCESS with EMPTY returndata. The real,
    ///      checkable property is therefore "returns nothing", which is exactly what makes a TYPED
    ///      `IERC4626(vogue).asset()` revert on decode. Asserting `!ok` here would be wrong and would
    ///      silently pass for the wrong reason.
    function _returnsNothing(bytes memory callData) internal view returns (bool) {
        (bool ok, bytes memory ret) = address(V4).staticcall(callData);
        return ok && ret.length == 0;
    }

    function test_VEth_CarriesTheIdentity_AndProjectsVogueWithoutDuplicatingState() public {
        VEth veth = new VEth(address(V4), address(WETH), address(AUX));

        vm.prank(User01);
        V4.deposit{value: 10 ether}(0, User01, 3);          // VENUE_GALAXY

        // ── the identity itself ──────────────────────────────────────────────────────────────────
        assertEq(veth.asset(), address(WETH), "asset() is the ONE asset this identity is over");
        assertEq(veth.decimals(), 18, "vETH is ETH-denominated");
        assertEq(veth.symbol(), "vETH", "symbol moved off Vogue");

        // ── projection: every read equals Vogue's own state, with NO duplicated storage ───────────
        // This is the asymmetry with VBtc (which owns its balances): vETH's balances ARE the band
        // state, so VEth must read through rather than hold a second copy that could diverge.
        assertGt(veth.balanceOf(User01), 0, "the deposit registered (test would be vacuous otherwise)");
        assertEq(veth.balanceOf(User01), V4.balanceOf(User01), "balance projects autoManaged.pooled");
        assertEq(veth.totalSupply(), V4.lpShares(), "supply projects lpShares");
        assertEq(veth.maxRedeem(User01), V4.balanceOf(User01), "maxRedeem == pooled");
        assertEq(veth.maxWithdraw(User01), V4.convertToAssets(V4.balanceOf(User01)), "maxWithdraw");
        assertEq(veth.previewRedeem(1e18), V4.convertToAssets(1e18), "previewRedeem delegates");
        assertEq(veth.previewDeposit(1e18), V4.convertToShares(1e18), "previewDeposit delegates");
        assertEq(veth.totalAssets(), AUX.vogueETH(), "totalAssets is the raw venue-side backing");

        // Conversions must delegate, so the §A.16b same-clock pricing has exactly ONE implementation
        // — a second copy here is precisely how the cross-subsidy defect would come back.
        assertEq(veth.convertToAssets(veth.balanceOf(User01)),
                 V4.convertToAssets(V4.balanceOf(User01)), "conversion delegates, never recomputed");
    }

    /// THE POINT OF §J.2b: Vogue must no longer answer the 4626 identity at all.
    function test_Vogue_NoLongerAnswersThe4626Identity() public {
        assertTrue(_returnsNothing(abi.encodeWithSignature("asset()")),          "Vogue still has asset()");
        assertTrue(_returnsNothing(abi.encodeWithSignature("totalAssets()")),    "Vogue still has totalAssets()");
        assertTrue(_returnsNothing(abi.encodeWithSignature("maxWithdraw(address)", User01)), "maxWithdraw()");
        assertTrue(_returnsNothing(abi.encodeWithSignature("maxRedeem(address)", User01)),   "maxRedeem()");
        assertTrue(_returnsNothing(abi.encodeWithSignature("previewRedeem(uint256)", 1e18)), "previewRedeem()");
        assertTrue(_returnsNothing(abi.encodeWithSignature("maxDeposit(address)", User01)),  "maxDeposit()");

        // The consequence for an integrator — a typed `IERC4626(vogue).asset()` yields no answer —
        // follows directly from the empty returndata above, but is NOT expressible as an assertion in
        // this frame, and both natural attempts pass/fail for the WRONG reason:
        //   • `vm.expectRevert()` fails: the fallback makes the CALL succeed, so the cheatcode sees a
        //     non-reverting call. The decode error happens afterwards, back in this frame.
        //   • `try/catch` fails too: Solidity does not route return-data DECODING failures through
        //     `catch` — they raise in the calling frame and are uncatchable.
        // Asserting empty returndata is the same fact, checked where it can actually be checked.
    }
}
