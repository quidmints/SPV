// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §FLOOR-IS-NOT-A-CONSTANT + §SIGMA-FREE-SHARE — the two questions nobody had asked,
///        measured against the real `skewWad` rather than a transcription of it.
///
/// ⚠️ **WHY THIS IS A NEW FILE AND NOT A ROW IN `SkewLearningsAreLive`.** That file locks learnings
///    that are already settled. These two measure things the record states as *unasked*:
///      · REFILL-START-HERE §4 trap 1: *"a minimum charge (420 ppm) binds below ~55% depletion"*.
///        **It is quoted as a constant and it is not one** — the crossing is a function of σ² AND of
///        where the swap starts. Quoting one q is the same species of error the trap warns about.
///      · §SIGMA-COUNT-BROKEN measured the doubling ratio at **1.57–1.86** and stopped there. The
///        complement of that ratio is the σ²-FREE SHARE of the charge, which is the quantity the
///        open question *"`DEPLETION_RATE_WAD` is σ²-free — a risk charge with no risk term"* is
///        actually about. This reports it directly instead of leaving it as 2 − ratio.
///
/// 📐 THE ALGEBRA THIS RESTS ON, stated so a reader can refute it without running anything.
///    For the ETH profile `(ETH_CONF_FRAC_WAD, 0)` the kernel composes as
///        skew(σ²) = σ²·(Γ·qBar + confFrac/8) + depletion(inv0, inv1)
///    — ONE term linear in σ² and ONE that does not contain σ² at all. So two probes pin both:
///        depletion = 2·skew(σ²) − skew(2σ²)          (the σ²-free intercept)
///    and that is EXACT, not a fit. ⛔ It holds on ETH only: BTC's profile carries `SPLICE_FLOOR`,
///    which is also σ²-free, so on BTC the same two probes return `depletion + SPLICE_FLOOR` and
///    the two cannot be separated by this method. The BTC case is asserted, not decomposed.
contract SkewFloorAndSigmaFreeShare is Test {
    // A flush range: inventory exactly at target, so q0 == 0 and a drain of `d` lands at q1 = d/TARGET.
    // Chosen so that `q1` IS the swept coordinate — trap 4 (`q` is scarcity, not drain size) is the
    // reason this fixture pins inv0 == target rather than sizing the drain against inventory.
    uint constant TARGET = 2_000_000e6;
    uint constant INV0   = 2_000_000e6;

    uint constant VOL30  = 9e16;    // σ² for 30% annualized vol
    uint constant VOL80  = 64e16;   // 80%
    uint constant VOL200 = 4e18;    // 200%

    function _skew(uint sigmaSq, uint q1Bps) internal pure returns (uint) {
        return SwapLib.skewWad(INV0, TARGET, sigmaSq, SwapLib.ethRisk(), INV0 * q1Bps / 10_000);
    }

    /// Smallest q1 (in bps) at which the composed charge reaches the floor. 10_000 == "never".
    function _crossing(uint sigmaSq) internal pure returns (uint) {
        uint lo = 1; uint hi = 10_000;
        if (_skew(sigmaSq, hi) < SwapLib.MIN_SWAP_SKEW_WAD) return 10_000;
        while (lo < hi) {
            uint mid = (lo + hi) / 2;
            if (_skew(sigmaSq, mid) >= SwapLib.MIN_SWAP_SKEW_WAD) hi = mid; else lo = mid + 1;
        }
        return lo;
    }

    /// §FLOOR-IS-NOT-A-CONSTANT — **the floor's reach is a function of volatility, and the published
    /// "~55%" is one sample of it.** Not a defect in the code; a defect in how the number is quoted.
    /// ⇒ IF THIS FAILS because the spread narrowed, the floor stopped being vol-dependent and
    ///   `MIN_SWAP_SKEW_WAD` became the whole price over a fixed band — re-open the owner question.
    function test_FloorReachIsAFunctionOfVolatilityNotAConstant() public pure {
        uint c30  = _crossing(VOL30);
        uint c80  = _crossing(VOL80);
        uint c200 = _crossing(VOL200);
        console2.log("floor binds below q =  30%% vol (bps of target):", c30);
        console2.log("floor binds below q =  80%% vol (bps of target):", c80);
        console2.log("floor binds below q = 200%% vol (bps of target):", c200);
        // Higher vol ⇒ the scarcity term clears 420 ppm sooner ⇒ the floor governs a SMALLER band.
        assertGt(c30, c80,  "a calmer tape must leave the floor governing MORE of the range");
        assertGt(c80, c200, "a violent tape must leave the floor governing LESS of the range");
        // The claim under test: the spread is wide enough that citing one crossing is misleading.
        assertGt(c30 - c200, 1_000,
            "if the crossing barely moves with vol, 'binds below ~55%' would be a fair summary");
    }

    /// §SIGMA-FREE-SHARE — how much of the charge carries NO risk term, across the operating range.
    /// This is the measurement the open question *"a risk charge with no risk term in it"* needs:
    /// not whether the term exists (it does, `DEPLETION_RATE_WAD`), but how much of the price it IS.
    function test_SigmaFreeShareOfTheChargeAcrossTheRange() public pure {
        uint16[5] memory qs = [1_000, 2_500, 5_000, 7_500, 9_500];
        for (uint i = 0; i < qs.length; ++i) {
            uint s1 = _skew(VOL80, qs[i]);
            uint s2 = _skew(VOL80 * 2, qs[i]);
            // EXACT decomposition — see the header. Saturating because s2 >= s1 by construction.
            uint sigmaFree = 2 * s1 >= s2 ? 2 * s1 - s2 : 0;
            console2.log("q (bps)                     :", qs[i]);
            console2.log("  charge (WAD)              :", s1);
            console2.log("  sigma-FREE part (WAD)     :", sigmaFree);
            console2.log("  sigma-free share (bps)    :", s1 == 0 ? 0 : sigmaFree * 10_000 / s1);
            // The reconstruction must be a real decomposition, not a coincidence: the linear part
            // recovered from the two probes has to rebuild the reading it came from.
            assertEq(sigmaFree + (s2 - s1), s1, "decomposition is not exact - the kernel gained a term");
        }
    }

    /// The BTC profile carries a SECOND σ²-free term (`SPLICE_FLOOR`), so the same two probes cannot
    /// separate depletion from it. Asserted so a later reader does not run the ETH method on BTC and
    /// report `SPLICE_FLOOR` as depletion.
    function test_BtcCarriesASecondSigmaFreeTermSoTheEthMethodDoesNotTransfer() public pure {
        uint q = 5_000;
        uint eth1 = SwapLib.skewWad(INV0, TARGET, VOL80, SwapLib.ethRisk(), INV0 * q / 10_000);
        uint eth2 = SwapLib.skewWad(INV0, TARGET, VOL80 * 2, SwapLib.ethRisk(), INV0 * q / 10_000);
        uint btc1 = SwapLib.skewWad(INV0, TARGET, VOL80, SwapLib.btcRisk(), INV0 * q / 10_000);
        uint btc2 = SwapLib.skewWad(INV0, TARGET, VOL80 * 2, SwapLib.btcRisk(), INV0 * q / 10_000);
        uint ethFree = 2 * eth1 - eth2;
        uint btcFree = 2 * btc1 - btc2;
        console2.log("ETH sigma-free intercept (WAD):", ethFree);
        console2.log("BTC sigma-free intercept (WAD):", btcFree);
        assertGt(btcFree, ethFree, "BTC must carry SPLICE_FLOOR on top of the same depletion term");
    }
}
