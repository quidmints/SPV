// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E63 — WHAT DOES A CALMLY-TRADING RANGE ACTUALLY MEASURE?
///
/// Four memory policies all failed downstream of one fact: `_calmVol()` performs 16 real swaps and
/// the estimator still reports variance 0. Before any more policy work, find out whether that is a
/// SCALE problem (small moves truncating), a SAMPLE-COUNT problem (too few real updates in the
/// window), or a genuine "the ticks did not move" — those need different fixes and only the
/// numbers can tell them apart.
contract VarPrecision is AllesFixture {
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

    /// §SILENT-SETUP — THE CATCH STAYS, THE SILENCE DOES NOT. This helper was
    /// `try AUX.swap(...) {} catch {}` with nothing recorded, so a run in which EVERY swap reverted
    /// was indistinguishable from one in which all 76 landed — and the test below then reports what
    /// a range with no flow measures, while claiming to report what a CALMLY TRADING one does.
    /// ⚠️ IT COST REAL TIME, WHICH IS WHY IT IS FIXED HERE FIRST: working §E345 I could not tell
    /// whether σ² read 0 because the estimator was broken or because no swap had landed. The answer
    /// needed an ad-hoc `POOLED_USD` log; it should have needed a counter.
    /// ⛔ THE CATCH IS NOT REMOVED, DELIBERATELY. A drain that exhausts the range SHOULD revert, and
    /// the size ladder below depends on that — the requirement is a COUNT, not a hard failure.
    /// ⭐ The pattern is already in this tree: `DrainAtomicity` does `try … { ++buys; } catch {}` and
    /// `Alles._moveEth` returns `moved`. One line longer, and the test can tell "it ran" from "it
    /// reverted 76 times".
    uint internal swapsAttempted;
    uint internal swapsLanded;

    function _swap(uint amt, uint warpMin) internal {
        deal(bold, trader, amt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), amt);
        ++swapsAttempted;
        try AUX.swap(bold, address(WETH), true, amt, 0, true) { ++swapsLanded; } catch {}
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpMin * 60);
    }

    function test_E63_WhatCalmTradingMeasures() public {
        _seed();
        vm.prank(lpA); ETH.deposit{value: 400 ether}(0, lpA);
        vm.roll(block.number + 1);

        // BIG moves first — the control. If this reads 0 the estimator is broken outright.
        for (uint i; i < 12; i++) _swap(6_000e18, 20);
        emit log_named_uint("variance after BIG moves   ", CORE.realizedVarianceWad());
        (uint tickBig,) = CORE.poolStats();
        emit log_named_uint("  price after BIG          ", tickBig);

        // SIZE LADDER: find the smallest swap that moves a tick at all. That is the boundary
        // between "calm" (measurable, small) and "no data" (unmeasurable), and it decides whether
        // the lev fixture needs bigger trades or the range needs finer resolution.
        uint[4] memory sizes = [uint(30e18), 300e18, 1_500e18, 4_000e18];
        for (uint k; k < 4; k++) {
            (uint t0,) = CORE.poolStats();
            for (uint i; i < 16; i++) _swap(sizes[k], 6);
            (uint t1,) = CORE.poolStats();
            emit log_named_uint("swap size (1e18)         ", sizes[k] / 1e18);
            emit log_named_int ("  ticks moved over 16     ", int(t1) - int(t0));
            emit log_named_uint("  variance now            ", CORE.realizedVarianceWad());
        }
        emit log_named_uint("variance after CALM trades ", CORE.realizedVarianceWad());
        (uint tickCalm,) = CORE.poolStats();
        emit log_named_uint("  price after CALM         ", tickCalm);
        emit log_named_int ("  tick MOVED by            ", int(tickCalm) - int(tickBig));

        // PREMISE: the calm leg must actually trade, else "0" says nothing about precision.
        assertGt(CORE.POOLED_USD(), 0, "PREMISE: the range is live");
        // §SILENT-SETUP — AND THE PREMISE THIS FILE ACTUALLY RESTS ON, WHICH WAS NEVER ASSERTED.
        // `POOLED_USD > 0` says the range was FUNDED; it says nothing about whether a single swap
        // landed, and every conclusion below is about what TRADING measures. With the helper's
        // `catch {}` silent, a run where all 76 reverted produced the same "variance 0" line as a
        // run where none did — and "0" would then be the honest answer to a question nobody asked.
        emit log_named_uint("swaps landed / attempted   ", swapsLanded);
        emit log_named_uint("  attempted                ", swapsAttempted);
        assertGt(swapsLanded, 0, "PREMISE: the fixture actually traded (else this measures nothing)");
        emit log_string("If tick MOVED but variance reads 0 => PRECISION. If tick did not move => the");
        emit log_string("swaps are too small to shift a tick at all, and 0 is the honest answer.");
    }
}
