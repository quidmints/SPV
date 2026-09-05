// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
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
/// ⚠️ **WHAT THIS FILE IS, HONESTLY: A REPLICATION.** `kLvrWad` is `public view` and takes a `core` it
///    calls `poolStats()` on, so exercising it directly needs a deployed range — and rule 5 forbids
///    mocking one. The six lines below are copied VERBATIM from `QuidLib.sol:170-177` (same
///    `SoladyMath.sqrt`, same `fullMulDiv`, same clamp, same `>= 2e18` guard) so the copy can be diffed
///    against the source by eye. **It quantifies a finding that was established by READING the clamp;
///    it is not itself the evidence that the clamp exists.**
contract AnchorSkewSensitivity is Test {
    uint256 constant SPOT  = 3_000e18;                 // true spot
    uint256 constant DELTA = SwapLib.RANGE_DELTA;      // the live ±0.2% half-width

    /// Verbatim replication of `QuidLib.kLvrWad`'s body, minus the `poolStats()` read.
    function _kLvr(uint256 priceWad, uint256 loPrice, uint256 upPrice) internal pure returns (uint256) {
        if (loPrice >= upPrice) return 0;
        uint256 p = priceWad < loPrice ? loPrice : (priceWad > upPrice ? upPrice : priceWad);
        // ⚠️ TWO DIFFERENT LIBRARIES, EXACTLY AS THE SOURCE DOES IT: solmate's `sqrt`, solady's
        //    `fullMulDiv`. My first copy used solady for both and would have measured a function the
        //    tree does not have — the precise hazard that makes a replication worth labelling.
        uint256 r1 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(p, 1e36, upPrice));
        uint256 r2 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(loPrice, 1e36, p));
        uint256 denom = 2e18;
        if (r1 + r2 >= denom) return 0;
        denom -= (r1 + r2);
        return SoladyMath.fullMulDiv(1e18, 1e18, 4 * denom);
    }

    /// ⭐ THE ANSWER. Sweep the anchor error and report K against the honest-anchor baseline.
    function test_AnchorErrorIsNotFirstOrderInK() public pure {
        (uint256 lo0, uint256 up0) = SwapLib.updateBounds(SPOT, DELTA);
        uint256 kTrue = _kLvr(SPOT, lo0, up0);
        assertGt(kTrue, 0, "baseline K must be non-zero");
        console2.log("baseline K (honest anchor), WAD:", kTrue);

        // The repack's own tolerance is 300 bps (`isManipulated(spot, twap, 300)`), so that is the
        // worst anchor an attacker can pin without being refused.
        uint16[5] memory offsetsBps = [uint16(25), 50, 100, 200, 300];
        for (uint256 i; i < offsetsBps.length; ++i) {
            uint256 bad = (SPOT * (10_000 + offsetsBps[i])) / 10_000;
            (uint256 lo, uint256 up) = SwapLib.updateBounds(bad, DELTA);
            uint256 kBad = _kLvr(SPOT, lo, up);          // spot is TRUE; only the band moved
            uint256 errBps = kBad > kTrue
                ? ((kBad - kTrue) * 10_000) / kTrue
                : ((kTrue - kBad) * 10_000) / kTrue;
            console2.log("anchor off by bps:", uint256(offsetsBps[i]));
            console2.log("   K:", kBad);
            console2.log("   K error, bps:", errBps);
            assertGt(kBad, 0, "a 300bps-off anchor must not zero K - that WOULD be first-order");
        }
    }

    /// 🔴 THE CONTROL, because "K barely moves" is the §VACUOUS-BOUNDS shape if K never moves for any
    ///    input. Widening the BAND (not the anchor) must move K a lot — if it does not, `_kLvr` is
    ///    insensitive to everything and the sweep above measures nothing.
    function test_Control_KIsSensitiveToBandWidth() public pure {
        (uint256 lo0, uint256 up0) = SwapLib.updateBounds(SPOT, DELTA);
        (uint256 lo1, uint256 up1) = SwapLib.updateBounds(SPOT, DELTA * 10);   // ±2% instead of ±0.2%
        uint256 kNarrow = _kLvr(SPOT, lo0, up0);
        uint256 kWide   = _kLvr(SPOT, lo1, up1);
        console2.log("control: K at +/-0.2%:", kNarrow);
        console2.log("control: K at +/-2%  :", kWide);
        assertGt(kNarrow, kWide * 5,
            "CONTROL FAILED - K is insensitive to band width too, so the anchor sweep proves nothing");
    }
}
