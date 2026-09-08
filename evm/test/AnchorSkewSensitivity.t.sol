// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {QuidLib} from "../src/imports/QuidLib.sol";
import {console2} from "forge-std/console2.sol";

/// @notice §MASTER-ORDER GATE 1f / §PLP-Q Q2.7 — **is the error from a 300-bps-off `RANGE_ANCHOR`
///         first-order?** §PLP-V books it as the repack's only residual, phrased as *"it mis-prices the
///         **premium** — `q` computed against a wrong band."*
///
/// 🔴 **FIRST FINDING, AND IT IS A CODE READ RATHER THAN A COMPUTATION: THE PREMISE IS WRONG. THE SKEW
///    DOES NOT READ THE BOUNDS AT ALL.** `SwapLib.skewWad(poolVolUsd, flowUsd, sigmaSqWad, Risk rk,
///    drainUsd6)` takes **no `lo`/`hi`/anchor parameter**, and `poolVolUsd` is a BALANCE (`POOLED`),
///    not a bounds-derived quantity — §V4-CUT removed the concentrated position that would have made it
///    one. ⇒ **a wrong anchor cannot reach `q` or the premium through the bounds.**
///    ⇒ **§PLP-V's residual names the wrong victim.** What the anchor actually feeds is
///    `updateBounds` → `loPrice`/`upPrice` → **`QuidLib.kLvrWad`**, i.e. **θ's denominator and
///    `ilTargetBps`'s band** (§PLP-3's *"`K` has at least two consumers"*, Q5.3). It mis-sizes the RANGE
///    and the LEVER TARGET, not the swap premium. Same magnitude question, different victim.
///
/// ⭐ **SECOND FINDING, AND IT IS WHY THE ANSWER IS "NOT FIRST-ORDER": `kLvrWad` CLAMPS THE PRICE INTO
///    THE BAND.** `QuidLib.sol:171` —
///      `uint p = priceWad < loPrice ? loPrice : (priceWad > upPrice ? upPrice : priceWad);`
///    So when a bad anchor moves the band off spot, `p` pins to the nearest EDGE rather than running
///    away, and the two roots stay near their maximally-concentrated values.
///    ⚠️ **I HAND-COMPUTED THIS ONCE WITHOUT NOTICING THE CLAMP AND GOT A +12% K ERROR.** With the
///    clamp the true figure is far smaller. That mistake is the reason this file exists rather than a
///    paragraph of arithmetic in a commit message.
///
/// ✅ **NO LONGER A REPLICATION (2026-09-08).** This file used to carry a hand-copy of `kLvrWad`'s body
///    "so the copy can be diffed against the source by eye", because `kLvrWad` is `public view` over a
///    `core` it calls `poolStats()` on and rule 5 forbids mocking one. Diffing by eye is exactly what
///    failed: the copy survived the `RANGE_DELTA` 20 → 200 widening unnoticed, in this file and in
///    `LevDerivedBand.t.sol`. The read and the arithmetic are now SPLIT in production —
///    `QuidLib.kLvrAt(price, lo, up)` is the whole formula with the `poolStats()` read lifted out, and
///    `kLvrWad` is that call — so this file runs THE function instead of a likeness of it.
contract AnchorSkewSensitivity is Test {
    uint256 constant SPOT  = 3_000e18;                 // true spot
    uint256 constant DELTA = SwapLib.RANGE_DELTA;      // the live half-width: ±2%

    /// ⭐ THE ANSWER. Sweep the anchor error and report K against the honest-anchor baseline.
    function test_AnchorErrorIsNotFirstOrderInK() public pure {
        (uint256 lo0, uint256 up0) = SwapLib.updateBounds(SPOT, DELTA);
        uint256 kTrue = QuidLib.kLvrAt(SPOT, lo0, up0);
        assertGt(kTrue, 0, "baseline K must be non-zero");
        console2.log("baseline K (honest anchor), WAD:", kTrue);

        // The repack's own tolerance is 300 bps (`isManipulated(spot, twap, 300)`), so that is the
        // worst anchor an attacker can pin without being refused.
        uint16[5] memory offsetsBps = [uint16(25), 50, 100, 200, 300];
        for (uint256 i; i < offsetsBps.length; ++i) {
            uint256 bad = (SPOT * (10_000 + offsetsBps[i])) / 10_000;
            (uint256 lo, uint256 up) = SwapLib.updateBounds(bad, DELTA);
            uint256 kBad = QuidLib.kLvrAt(SPOT, lo, up);          // spot is TRUE; only the band moved
            uint256 errBps = kBad > kTrue
                ? ((kBad - kTrue) * 10_000) / kTrue
                : ((kTrue - kBad) * 10_000) / kTrue;
            console2.log("anchor off by bps:", uint256(offsetsBps[i]));
            console2.log("   K:", kBad);
            console2.log("   K error, bps:", errBps);
            assertGt(kBad, 0, "a 300bps-off anchor must not zero K - that WOULD be first-order");
            // ⭐ THE CLAIM IN THE NAME, ASSERTED. `kBad > 0` was the only assertion here, and it
            // cannot fail: `kLvrAt` returns 0 only for `lo >= up` or `r1 + r2 >= 2e18`, neither
            // reachable for a symmetric band. So the sweep printed the answer and checked nothing.
            // SUB-LINEAR is what "not first-order" means: the K error must stay at or under a THIRD
            // of the anchor error that caused it. Measured at DELTA = 200 — 25bps → 0, 50 → 2,
            // 100 → 11, 200 → 48, 300 → 50 — so the worst ratio is 0.24 at the 200bps offset and the
            // bound has real headroom without being slack enough to pass a linear response.
            // ⭐ CONTROL RUN, NOT ARGUED: patching the clamp out of `QuidLib.kLvrAt` (`uint p =
            // priceWad`) turns this RED — "324 > 300" at the 300bps offset, i.e. the ratio goes
            // 0.24 → 0.36. ⚠️ THE MARGIN IS ONE THIRD AGAINST 0.36, WHICH IS NARROW ON PURPOSE:
            // the whole finding is that the clamp buys a factor of ~1.5 here, so a bound loose
            // enough to be comfortable would not detect losing it.
            assertLe(errBps * 3, uint256(offsetsBps[i]),
                "K error is first-order in the anchor error - the clamp is not doing its job");
        }
    }

    /// 🔴 THE CONTROL, because "K barely moves" is the §VACUOUS-BOUNDS shape if K never moves for any
    ///    input. Widening the BAND (not the anchor) must move K a lot — if it does not, `_kLvr` is
    ///    insensitive to everything and the sweep above measures nothing.
    function test_Control_KIsSensitiveToBandWidth() public pure {
        (uint256 lo0, uint256 up0) = SwapLib.updateBounds(SPOT, DELTA);
        (uint256 lo1, uint256 up1) = SwapLib.updateBounds(SPOT, DELTA * 10);   // ±20% instead of ±2%
        uint256 kNarrow = QuidLib.kLvrAt(SPOT, lo0, up0);
        uint256 kWide   = QuidLib.kLvrAt(SPOT, lo1, up1);
        console2.log("control: K at the live band:", kNarrow);
        console2.log("control: K at 10x that   :", kWide);
        assertGt(kNarrow, kWide * 5,
            "CONTROL FAILED - K is insensitive to band width too, so the anchor sweep proves nothing");
    }
}
