// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {ICore} from "../src/imports/Interfaces.sol";

/// §DERIVED-BAND — the no-trade band is `∛(g/(C·K))`, and this suite is what keeps it honest.
///
/// It exists because the thing it replaced, `LevBase.RANGE_BPS = 300`, was not wrong in a way any
/// test could see: it was a plausible number that quietly required a **+6.3% move off entry**
/// before the IL overlay borrowed anything. The band is now read from three live quantities, so the
/// failure mode moves from "someone picked badly" to "someone reads badly", and these are the
/// reads.
contract LevDerivedBandProbe is AllesFixture {
    /// `WAD` is inherited from `AllesFixture` -- redeclaring it here shadowed it and broke the build.

    /// A ±20bps range: K = 1/(4·(2 − √(P/Pb) − √(Pa/P))) ≈ 125.
    uint constant K_20BPS = 125 * WAD;

    /// 1. THE SHAPE. `h³ = g/(C·K)` is the whole claim, so assert the cube directly rather than a
    ///    remembered output — a test that only pins numbers cannot tell a rewrite from a regression.
    function test_band_isTheCubeRootOfGasOverSizeTimesK() public pure {
        uint g = 3 * WAD;              // $3 of gas
        uint c = 100_000 * WAD;        // $100k position
        uint bps = LevMath.noTradeBandBps(g, c, K_20BPS);

        // Recompose: (h)³·C·K should return g, within integer-root truncation.
        uint hWad = (bps * WAD) / 10_000;
        uint recomposed = (((hWad * hWad) / WAD) * hWad / WAD) * (c / WAD) * (K_20BPS / WAD);
        assertApproxEqRel(recomposed, g, 0.02e18, "band is not the cube root of g/(C*K)");
    }

    /// 2. THE PROPERTY A CONSTANT CANNOT HAVE. Gas is a fixed cost, so it dominates a small
    ///    position and is noise to a large one — the band must widen as size falls. `RANGE_BPS`
    ///    charged a $1k position and a $10m position the same 300bps, which is the actual defect.
    function test_band_widensForSmallPositions() public pure {
        uint g = 3 * WAD;
        uint small = LevMath.noTradeBandBps(g, 1_000 * WAD,   K_20BPS);
        uint mid   = LevMath.noTradeBandBps(g, 100_000 * WAD, K_20BPS);
        uint large = LevMath.noTradeBandBps(g, 10_000_000 * WAD, K_20BPS);

        assertGt(small, mid,   "a small position must tolerate a wider error");
        assertGt(mid,   large, "a large position must rebalance tighter");
        // And the direction is not merely monotone — it is the cube root, so 100x the size is ~4.64x
        // tighter. A linear or stepped rule would fail here while passing the assertions above.
        assertApproxEqRel(mid * 4641 / 1000, small, 0.05e18, "not scaling as the cube root of size");
    }

    /// 3. CHEAPER GAS ⇒ TIGHTER TRACKING, with no one deciding that.
    function test_band_tightensAsGasFalls() public pure {
        uint c = 100_000 * WAD;
        assertGt(LevMath.noTradeBandBps(30 * WAD, c, K_20BPS),
                 LevMath.noTradeBandBps(3 * WAD,  c, K_20BPS),
                 "a 10x gas spike must widen the band");
    }

    /// 4. THE FIX ITSELF. At $100k and $3 of gas the band is ~62bps, and `ilTargetBps` is
    ///    `1 − √(entry/now)`, so it arms at roughly a **1.2%** move rather than 6.3%. This is the
    ///    number that decides whether the product works, so it is asserted, not described.
    function test_band_armsTheHedgeLongBeforeTheOldConstant() public pure {
        uint bps = LevMath.noTradeBandBps(3 * WAD, 100_000 * WAD, K_20BPS);
        assertLt(bps, 300, "the derived band must be tighter than the 300bps it replaced");
        assertApproxEqAbs(bps, 62, 12, "band moved off its derived value");

        // Price move that clears it: 1 - sqrt(1/k) = bps/1e4  =>  k = 1/(1-bps/1e4)^2.
        // At 62bps that is +1.25%; the old constant needed +6.34%.
        assertLt(bps * 2, 634, "the arming move must be far inside the old 6.3%");
    }

    /// 5. FAIL OPEN TOWARD HEDGING. Every unmeasured input yields a ZERO band — rebalance always —
    ///    because the failure this replaced was silent inaction, not churn. A zero band cannot
    ///    mis-size a borrow: `debtDelta` still sizes it off the target.
    function test_band_failsOpenOnAnyUnmeasuredInput() public pure {
        assertEq(LevMath.noTradeBandBps(0, 100_000 * WAD, K_20BPS), 0, "no gas price");
        assertEq(LevMath.noTradeBandBps(3 * WAD, 0, K_20BPS),       0, "no position");
        assertEq(LevMath.noTradeBandBps(3 * WAD, 100_000 * WAD, 0), 0, "no range geometry");
    }

    /// 6. K COMES OFF THE LIVE RANGE, not a literal — and off BOTH of them, because the overlay is
    ///    asset-agnostic and a band that only resolves on the ETH side would strand the BTC book.
    ///    If this reverts or returns 0 the band fails open, so the value being real is what makes
    ///    the band real.
    function test_lvrK_isReadableFromTheLiveRange() public view {
        uint k = ICore(address(ETH)).kLvrWad();
        assertGt(k, 0, "ETH range reports no LVR coefficient");
        assertGt(ICore(address(BTC)).kLvrWad(), 0, "BTC range reports no LVR coefficient");
        // K = 1/(4·(2 − √(P/Pb) − √(Pa/P))) is > 1/8 for any non-degenerate range and grows without
        // bound as the range narrows; a concentrated range sits far above 1.
        assertGt(k, WAD / 8, "K below its analytic floor");
    }
}
