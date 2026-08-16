// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E218 — THE SKEW IS NOT "NOT APPLIED" TO STABLE→STABLE. THERE IS NO STABLE→STABLE SWAP.
///
/// The owner's statement was: *"what about swaps between any stable in the basket to any stable in
/// the basket. we dont apply skew to that because we have no target ratio."* The REASONING is right
/// — inventory skew presupposes a target inventory to be skewed away from, and the basket has no
/// target ratio — but the CODE is stronger than the claim, and this test pins which one is true.
/// `swapToBody`'s FIRST line rejects any `asset` that is not WETH or WBTC, so the pair never forms:
/// there is no code path whose skew could have been switched off, and therefore none that could be
/// switched back on by accident.
///
/// ⚠️ WHY THIS NEEDS NO FIXTURE AND NO FORK. `swapToBody` is an `external` library function and the
///    guard runs BEFORE `IAux(address(this))` is touched, so the whole question is decidable without
///    an Aux, a Core, or a pool. Same reasoning as `SkewUnmeasuredVariance.t.sol`.
///
/// ⚠️ AND WHY THE CONTROL BELOW IS NOT OPTIONAL. `vm.expectRevert(BadAsset)` passing proves only that
///    SOMETHING reverted with that selector. Without `test_CONTROL_*` showing that a VOLATILE asset
///    gets PAST this guard, a `swapToBody` that reverted `BadAsset` unconditionally — or one whose
///    first branch had been reordered — would satisfy every assertion here while meaning the
///    opposite. The control is what makes the pass informative.
/// @dev A library's `external` function cannot be reached by `abi.encodeCall`, and `vm.expectRevert`
///      only asserts THAT a selector matched — never that a DIFFERENT one did. The control needs to
///      read the selector, so it needs a real external frame to catch.
contract SwapCaller {
    /// ⚠️ `reverted` and `sel` are SEPARATE returns on purpose. Collapsing them loses the difference
    ///    between "did not revert" and "reverted with EMPTY data" — and empty is exactly what this
    ///    path produces, because `swapToBody` calls `IAux(address(this)).toIndex(...)` and there is
    ///    no such function here, so the call reverts with zero-length returndata. A single
    ///    `bytes4(0)` sentinel read those two as the same thing and failed the control.
    function revertSelectorOf(
        SwapLib.SwapReq memory r, SwapLib.SwapToCfg memory c, address[] memory stables
    ) external returns (bool reverted, bytes4 sel) {
        try this.run(r, c, stables) { return (false, bytes4(0)); }
        catch (bytes memory err) {
            reverted = true;
            if (err.length >= 4) assembly { sel := mload(add(err, 0x20)) }
        }
    }
    function run(SwapLib.SwapReq memory r, SwapLib.SwapToCfg memory c, address[] memory stables)
        external returns (uint) { return SwapLib.swapToBody(r, c, stables); }
}

contract StableToStableHasNoSwapTest is Test {
    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC  = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    function _cfg() internal pure returns (SwapLib.SwapToCfg memory) {
        return SwapLib.SwapToCfg({
            weth: WETH, wbtc: WBTC, quid: address(0), core: address(0),
            band: address(0), btcChannels: address(0)});
    }

    function _req(address token, address asset, bool forVolatile)
        internal view returns (SwapLib.SwapReq memory) {
        return SwapLib.SwapReq({
            token: token, asset: asset, forVolatile: forVolatile, amount: 1_000e6,
            minOut: 0, recipient: address(this), inToken: address(0), px: 0});
    }

    /// @notice EVERY stable-as-`asset` pairing is rejected at the first line. Three distinct basket
    ///         stables, so the result cannot be an artifact of one token's address.
    function test_StableToStable_RevertsBadAsset_forEveryBasketStable() public {
        address[3] memory outs = [PYUSD, RLUSD, USDC];
        address[3] memory ins  = [USDC,  USDC,  PYUSD];
        address[] memory stables = new address[](0);
        for (uint i = 0; i < outs.length; i++) {
            vm.expectRevert(SwapLib.BadAsset.selector);
            SwapLib.swapToBody(_req(ins[i], outs[i], true), _cfg(), stables);
        }
    }

    /// @notice THE CONTROL. A volatile `asset` must get PAST the guard — it will still revert (there
    ///         is no Aux at `address(this)`), but it must NOT revert with `BadAsset`. If this ever
    ///         fails, the test above is measuring a guard that rejects everything and proves nothing.
    function test_CONTROL_volatileAssetPassesTheGuard() public {
        SwapCaller caller = new SwapCaller();
        address[] memory stables = new address[](0);
        for (uint i = 0; i < 2; i++) {
            address asset = i == 0 ? WETH : WBTC;
            (bool reverted, bytes4 sel) =
                caller.revertSelectorOf(_req(USDC, asset, true), _cfg(), stables);
            assertTrue(reverted, "premise: no Aux here, so this must still revert");
            assertTrue(sel != SwapLib.BadAsset.selector,
                "a VOLATILE asset was rejected by the asset guard - the other test proves nothing");
        }
    }

    /// @notice The BTC direction is closed separately, and NOT by the skew either: volatile→stable
    ///         with WBTC is `BtcInflowsViaChannels`. Recorded so a reader does not infer that BTC
    ///         inflows are a skew-priced swap that merely happens to be disabled.
    function test_BtcInflowIsClosedByChannels_notBySkew() public {
        address[] memory stables = new address[](0);
        vm.expectRevert(SwapLib.BtcInflowsViaChannels.selector);
        SwapLib.swapToBody(_req(address(0), WBTC, false), _cfg(), stables);
    }
}
