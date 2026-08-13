// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E63 — WHAT DOES A CALMLY-TRADING BAND ACTUALLY MEASURE?
///
/// Four memory policies all failed downstream of one fact: `_calmVol()` performs 16 real swaps and
/// the estimator still reports variance 0. Before any more policy work, find out whether that is a
/// SCALE problem (small moves truncating), a SAMPLE-COUNT problem (too few real updates in the
/// window), or a genuine "the ticks did not move" — those need different fixes and only the
/// numbers can tell them apart.
contract VarPrecision is Alles {
    address lpA = User02;
    address trader = address(0xBEEF01);
    address bold;

    function _seed() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function _swap(uint amt, uint warpMin) internal {
        deal(bold, trader, amt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), amt);
        try AUX.swap(bold, address(WETH), true, amt, 0) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpMin * 60);
    }

    function test_E63_WhatCalmTradingMeasures() public {
        _seed();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        vm.roll(block.number + 1);

        // BIG moves first — the control. If this reads 0 the estimator is broken outright.
        for (uint i; i < 12; i++) _swap(6_000e18, 20);
        emit log_named_uint("variance after BIG moves   ", CORE.realizedVarianceWad(false));
        (,, int24 tickBig) = CORE.poolTicks(false);
        emit log_named_int ("  tick after BIG           ", tickBig);

        // SIZE LADDER: find the smallest swap that moves a tick at all. That is the boundary
        // between "calm" (measurable, small) and "no data" (unmeasurable), and it decides whether
        // the lev fixture needs bigger trades or the band needs finer resolution.
        uint[4] memory sizes = [uint(30e18), 300e18, 1_500e18, 4_000e18];
        for (uint k; k < 4; k++) {
            (,, int24 t0) = CORE.poolTicks(false);
            for (uint i; i < 16; i++) _swap(sizes[k], 6);
            (,, int24 t1) = CORE.poolTicks(false);
            emit log_named_uint("swap size (1e18)         ", sizes[k] / 1e18);
            emit log_named_int ("  ticks moved over 16     ", int(t1) - int(t0));
            emit log_named_uint("  variance now            ", CORE.realizedVarianceWad(false));
        }
        emit log_named_uint("variance after CALM trades ", CORE.realizedVarianceWad(false));
        (,, int24 tickCalm) = CORE.poolTicks(false);
        emit log_named_int ("  tick after CALM          ", tickCalm);
        emit log_named_int ("  tick MOVED by            ", int(tickCalm) - int(tickBig));

        // PREMISE: the calm leg must actually trade, else "0" says nothing about precision.
        assertGt(CORE.POOLED_USD_ETH(), 0, "PREMISE: the band is live");
        emit log_string("If tick MOVED but variance reads 0 => PRECISION. If tick did not move => the");
        emit log_string("swaps are too small to shift a tick at all, and 0 is the honest answer.");
    }
}
