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
// Declared with VEth's EXACT event name — `expectEmit` matches on topic0, which is the
// keccak of the SIGNATURE, so a differently-named local event never matches.
event Transfer(address indexed from, address indexed to, uint value);

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
        V4.deposit{value: 10 ether}(0, User01);          // VENUE_GALAXY

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

    /// (§J.2c) The ERC-20 TRANSFER FACE moved from Vogue to VEth. Two properties, both of which
    /// the move exists to create:
    ///   1. a vETH transfer THROUGH `VEth` moves the band shares in Vogue (state stayed put, the
    ///      face moved) — and the token emits its own `Transfer`, so an indexer watching vETH sees it;
    ///   2. Vogue's `transferSharesFor` is gated to `VEth` ALONE, so nobody else can move band
    ///      shares — which is what makes the ambiguous "which asset's shares?" question unaskable
    ///      of Vogue rather than merely discouraged.
    /// Without this test the moved surface had ZERO coverage: no test transfers vETH at all.
    function test_VEth_OwnsTheTransferFace_AndVogueGatesItToVEthAlone() public {
        VEth veth = new VEth(address(V4), address(WETH), address(AUX));
        // `DEPLOYER` is Vogue's immutable deployer; `DeployLib` constructs Vogue from THIS
        // contract's context (DeployLib.sol:107), so the test IS the deployer — no prank.
        V4.setVEth(address(veth));

        vm.prank(User01);
        V4.deposit{value: 10 ether}(0, User01);          // VENUE_GALAXY
        uint from0 = V4.balanceOf(User01);
        uint to0   = V4.balanceOf(User02);
        assertGt(from0, 0, "PREMISE: the sender must hold band shares, else the move proves nothing");

        // (1) the transfer goes THROUGH the token and moves Vogue's state.
        uint amt = from0 / 4;
        vm.expectEmit(true, true, false, true, address(veth));
        emit Transfer(User01, User02, amt);
        vm.prank(User01);
        assertTrue(veth.transfer(User02, amt), "vETH transfer returns true");
        assertEq(V4.balanceOf(User01), from0 - amt, "sender's BAND shares fell by the amount");
        assertEq(V4.balanceOf(User02), to0 + amt,   "recipient's BAND shares rose by the amount");
        assertEq(veth.balanceOf(User01), V4.balanceOf(User01), "VEth projects Vogue, it does not copy it");

        // (2) the authority half: nobody but VEth may move band shares.
        vm.prank(User01);
        vm.expectRevert(bytes("403"));
        V4.transferSharesFor(User01, User02, amt);

        // (3) allowance lives on the TOKEN, and transferFrom honours it.
        vm.prank(User01);
        veth.approve(User02, amt);
        assertEq(veth.allowance(User01, User02), amt, "allowance is the token's own state");
        vm.prank(User02);
        veth.transferFrom(User01, User02, amt);
        assertEq(veth.allowance(User01, User02), 0, "allowance decremented on use");
    }
}
