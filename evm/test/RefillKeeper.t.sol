// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Asserts the TOXIC make-whole cluster is GONE: an ETH-pool shortfall no
///   longer draws the basket's shared surplus (refillETH removed), and a no-recipient
///   BTC shortfall is a clean no-op (the WBTC-from-surplus fallback removed). The shared
///   safety margin is "what we owe back", not a reserve to compensate one party — so no
///   path may spend it to patch a (usually impermanent) inventory shortfall. IL is borne
///   fairly via the share price (convertToAssets = pro-rata of vogueETH).
contract RefillKeeperProbe is Alles {
    address lp = User01; address adv = User03;

    function _backing() internal returns (uint) { (uint[15] memory d,,,) = AUX.get_deposits(); return d[14]; }
    function _surplus() internal returns (int) { return int(_backing()) - int(QUID.totalSupply()); }
    function _seedBacking(uint usdcAmt) internal {
        deal(address(USDC), address(this), usdcAmt);
        IERC20(address(USDC)).approve(address(AUX), usdcAmt);
        QUID.mint(address(this), usdcAmt, address(USDC), 0);
    }
    function _seedPool(uint ethAmt) internal {
        vm.prank(lp); V4.deposit{value: ethAmt}(0, lp);
        require(CORE.POOLED_ETH() > 0, "no in-range pool");
    }
    function _buyEth(uint usdc) internal {
        deal(address(USDC), adv, usdc);
        vm.startPrank(adv);
        IERC20(address(USDC)).approve(address(AUX), usdc);
        try AUX.swap(address(USDC), address(WETH), true, usdc, 0) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
    }

    /// An ETH-pool shortfall (ETH bought out by swaps) must leave the SHARED surplus
    /// untouched: the eager refillETH is removed, and the in-frame swap path no longer
    /// emits a refill request. Nothing buys ETH from backing to patch the shortfall.
    function test_EthShortfall_DoesNotDrawSurplus() public {
        _seedBacking(500_000 * USDC_PRECISION);
        _seedPool(100 ether);

        // Free backing (surplus over committed claims) BEFORE the drain.
        (uint cBefore, uint lBefore) = AUX.checkBacking();
        uint freeBefore = lBefore > cBefore ? lBefore - cBefore : 0;

        for (uint i = 0; i < 12; i++) _buyEth(5_000 * USDC_PRECISION);
        uint vShort = ETH.vogueETH();
        uint shares = V4.totalShares();
        require(vShort < shares, "expected a shortfall to exist");

        // INVARIANT: the shortfall did NOT consume the shared free backing (no toxic
        // refill). The swaps paid USDC IN, so free backing may only have grown.
        (uint cAfter, uint lAfter) = AUX.checkBacking();
        uint freeAfter = lAfter > cAfter ? lAfter - cAfter : 0;
        assertGe(freeAfter, freeBefore, "ETH-pool shortfall must NOT draw shared surplus");
        assertGe(lAfter, cAfter, "committedUsd <= TVL preserved");
        emit log_named_uint("vogueETH shortfall (ETH owed, unpatched - borne via share price)", shares - vShort);
    }
    // (BTC no-recipient no-op is covered by Alles.test_BtcShortfall_NoRecipient_NoWbtcFromSurplus,
    //  which has the correct harness wiring: setBTCChannels + mocked btcRecipientOf + V4 pranker.)

    /// CROSS-POOL drainage vector (audit D-1): the OLD race was arbETH(ETH) + btcShortfall-WBTC(BTC)
    /// drawing the SAME freeBackingUsdc — induce both → one starves or the drain doubles. BOTH draws
    /// are removed. Induce an ETH shortfall AND a no-recipient BTC shortfall in the same state →
    /// assert the shared free backing is untouched, no WBTC, no QUI minted, committedUsd<=TVL. Proves
    /// the cross-pool race cannot drain (the mechanisms that raced are gone).
    function test_CrossPool_BothShortfalls_NoDrain() public {
        _seedBacking(500_000 * USDC_PRECISION);
        _seedPool(100 ether);
        (uint c0, uint l0) = AUX.checkBacking();
        uint free0 = l0 > c0 ? l0 - c0 : 0;
        uint qd0 = QUID.totalSupply();

        for (uint i = 0; i < 12; i++) _buyEth(5_000 * USDC_PRECISION);   // ETH shortfall
        AUX.setBTCChannels(address(this));                                // BTC no-recipient shortfall
        vm.mockCall(address(this), abi.encodeWithSignature("btcRecipientOf(address)", User02), abi.encode(bytes32(0)));
        uint wbtc0 = WBTC.balanceOf(User02);
        vm.prank(address(V4));
        AUX.btcShortfall(User02, 1e7);

        (uint c1, uint l1) = AUX.checkBacking();
        uint free1 = l1 > c1 ? l1 - c1 : 0;
        assertGe(free1, free0, "no cross-pool race: shared free backing not drawn by either shortfall");
        assertGe(l1, c1, "committedUsd <= TVL across BOTH shortfalls");
        assertEq(WBTC.balanceOf(User02) - wbtc0, 0, "no WBTC from surplus");
        assertEq(QUID.totalSupply(), qd0, "no reflexive QUI mint by either shortfall path");
    }

    /// SILENT-NO-OP vector (audit D-3 + the one thing the removal INTRODUCED): btcShortfall with no
    /// recipient now returns silently. Assert the silent return corrupts NO state and strands NO
    /// value — no WBTC, no surplus draw, no QUI mint, POOLED_USD_BTC unchanged, and it does NOT revert.
    /// (The old exploit was timing a withdrawal into arbETH's no-op window; arbETH's window is gone,
    ///  and this no-op touches nothing drainable.)
    function test_SilentNoOp_BtcShortfall_NoStateCorruption() public {
        _seedBacking(500_000 * USDC_PRECISION);
        AUX.setBTCChannels(address(this));
        vm.mockCall(address(this), abi.encodeWithSignature("btcRecipientOf(address)", User02), abi.encode(bytes32(0)));
        (uint c0, uint l0) = AUX.checkBacking();
        uint free0 = l0 > c0 ? l0 - c0 : 0;
        uint qd0 = QUID.totalSupply();
        uint pub0 = CORE.POOLED_USD_BTC();
        uint wbtc0 = WBTC.balanceOf(User02);

        vm.prank(address(V4));
        AUX.btcShortfall(User02, 1e7);   // silent no-op — must NOT revert

        assertEq(WBTC.balanceOf(User02) - wbtc0, 0, "silent no-op delivers no WBTC");
        assertEq(QUID.totalSupply(), qd0, "silent no-op mints no QUI");
        assertEq(CORE.POOLED_USD_BTC(), pub0, "silent no-op leaves POOLED_USD_BTC unchanged");
        (uint c1, uint l1) = AUX.checkBacking();
        uint free1 = l1 > c1 ? l1 - c1 : 0;
        assertEq(free1, free0, "silent no-op leaves free backing unchanged");
    }
}
