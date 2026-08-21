// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E58 — WHAT DID THE SKEW CHANGES DO TO THE PRICE?
///
/// Four changes landed on the skew in one session, each verified against the SUITE and none
/// against MAGNITUDE. The suite asserts bounds, invariants and sign; nothing pins the actual
/// VALUE, so all four can be individually green and jointly mis-calibrated. Three remain:
///   pole removal (sell leg)   -> CUTS
///   E55 min(fast, slow)       -> RAISES (smaller target => larger q)
///   E53 shared amplifier      -> RAISES (1x -> 2x)
/// Two raises against one cut, partially cancelling BY ACCIDENT. This prints the number so the
/// same fixture can be run at the pre-session commit and the two compared.
contract SkewCalibration is AllesFixture {
    address lpA = User02;
    address trader = address(0xBEEF01);
    address bold;

    function _seedBasket() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function _trade(uint boldAmt) internal {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    /// Fixed fixture, fixed flow, then read the LIVE skew off the public surface.
    function test_E58_SkewMagnitudeOnAFixedFixture() public {
        _seedBasket();
        vm.prank(lpA); ETH.deposit{value: 400 ether}(0, lpA);
        vm.roll(block.number + 1);
        // §E58 DRAIN FIXTURE: 12x3,000 left inv/target at 20x and the flush branch firing. To reach
        // the SCARCITY regime the range must shed most of its ~$714k, so drain hard and let the TWAP
        // keep up (each _trade warps 20 min). Sized to overshoot deliberately — the question is
        // whether the curve EVER engages, so a fixture that stops short answers nothing.
        for (uint i; i < 120; i++) _trade(20_000e18);   // drain into SCARCITY, where the curve engages

        emit log_named_uint("ETH wellSkew (wad)   ", AUX.wellSkew(address(WETH), 0));
        emit log_named_uint("BTC wellSkew (wad)   ", AUX.wellSkew(address(WBTC), 0));
        emit log_named_uint("flowEwmaUsd ETH      ", CORE.flowEwmaUsd());
        emit log_named_uint("flowEwmaUsd BTC      ", CORE.flowEwmaUsd());
        emit log_named_uint("committedUsd18       ", CORE.committedUsd18());
        emit log_named_uint("btcRangeEquityUsd18   ", CORE.rangeEquityUsd18());
        emit log_named_uint("POOLED           ", CORE.POOLED());
        emit log_named_uint("POOLED_USD       ", CORE.POOLED_USD());
        // No assertion on the VALUE — the value is the output. Only a premise, so a zeroed
        // fixture cannot masquerade as "the skew is small".
        assertGt(CORE.POOLED(), 0, "PREMISE: the range must hold inventory, else 0 means nothing");

        // §E48/E58 — THE REGIME QUESTION IN ONE NUMBER. `wellSkew` is 0 above because
        // `target = flow + levClaimUsd6` is tiny against range inventory, so the scarcity curve never
        // engages. `committed` there is the LEVERAGE DEBT, ~0 in this fixture. If a real levered book
        // lifts it toward inventory scale, the regime is ORDINARY and both the skew changes and the
        // refill matter; if it cannot, they address a state the system rarely enters. Print the ratio
        // rather than assert it — the ratio IS the answer.
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        uint invUsd6 = px == 0 ? 0 : (CORE.POOLED() * px / 1e18) / 1e12;
        uint target6 = CORE.flowEwmaUsd() + CORE.levClaimUsd6();
        emit log_named_uint("realizedVarianceWad ETH", CORE.realizedVarianceWad());
        emit log_named_uint("levClaimUsd6 ETH (debt)", CORE.levClaimUsd6());
        emit log_named_uint("target = flow + debt   ", target6);
        emit log_named_uint("range inventory (6-dec) ", invUsd6);
        emit log_named_uint("inv / target  (x)      ", target6 == 0 ? 0 : invUsd6 / target6);
        emit log_string("inv/target >> 1 => flush branch => skew 0. The scarcity regime needs this near 1.");
    }
}
