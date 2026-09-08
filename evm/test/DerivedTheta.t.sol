// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {QuidLib} from "../src/imports/QuidLib.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @notice Reads the REAL derived θ = yield/(K·σ²) from live on-chain inputs, where BOTH K and σ²
///   are measured live (no hardcoded constant). σ² = Quid.realizedVarianceWad (Core's oracle ring);
///   K = Quid.kLvrWad — the closed-form range-geometry LVR coefficient computed from the live range
///   BOUNDS (there are no ticks; §V4-CUT removed them and `updateBounds` is a bps band on a price).
///   avgYield on the fork is ~0 (mock venues don't accrue over a short test), so we ALSO show θ at
///   realistic yields {3,5,8%} using the real measured K·σ² — the meaningful "real number".
contract DerivedThetaProbe is AllesFixture {
    address volActor = makeAddr("theta-vol");

    function _thetaAt(uint kWad, uint sigmaSq, uint yieldWad) internal pure returns (uint) {
        uint work = kWad * sigmaSq / 1e18;   // K·σ² with the LIVE range-geometry K (no hardcode)
        if (work == 0) return 1e18;
        uint th = yieldWad * 1e18 / work;
        return th > 1e18 ? 1e18 : th;
    }

    function _read(string memory tag) internal returns (uint k, uint sigmaSq, uint theta5) {
        try ETH.realizedVarianceWad() returns (uint s) {
            sigmaSq = s;
            k = ETH.kLvrWad();   // LIVE range-geometry K
            theta5 = _thetaAt(k, s, 5e16);
            emit log_string("________________________________");
            emit log_named_string("regime", tag);
            emit log_named_uint("  realized sigma^2 (WAD)", s);
            emit log_named_uint("  implied sigma (annual %, approx)", _approxSigmaPct(s));
            emit log_named_uint("  LIVE K from range geometry (WAD)", k);
            emit log_named_uint("  on-chain avgYield (WAD, fork~0)", AUX.avgYield());
            emit log_named_uint("  on-chain derivedTheta (uses fork yield)", ETH.derivedThetaWad());
            emit log_named_uint("  theta @ 3% yield (WAD)", _thetaAt(k, s, 3e16));
            emit log_named_uint("  theta @ 5% yield (WAD)", theta5);
            emit log_named_uint("  theta @ 8% yield (WAD)", _thetaAt(k, s, 8e16));
        } catch {
            emit log_named_string("  (theta read reverted - insufficient oracle history)", tag);
        }
    }

    // crude integer sqrt(sigmaSq)*100 for a human-readable annual vol %
    function _approxSigmaPct(uint sigmaSqWad) internal pure returns (uint) {
        uint x = sigmaSqWad; // WAD
        if (x == 0) return 0;
        uint z = (x + 1) / 2; uint y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }   // sqrt of the raw WAD
        return y * 100 / 1e9;   // sqrt(WAD)=1e9*sqrt(frac) -> *100 /1e9 = pct
    }

    /// @notice ⭐ §SKEW-COVERAGE-HOLE — WARM σ² FROM REAL MAINNET ROUNDS FIRST, OR THIS PROBE ONLY
    ///         EVER MEASURES θ's FAIL-OPEN PATH. `_thetaAt` returns `1e18` when `work == 0`, and
    ///         `work` is `K·σ²` — so at σ² == 0 (which is what a suite pinned to ONE block produces:
    ///         `_sampleAnchorVariance` advances `_varPx` only on a MOVE with `dt > 0`) every θ this
    ///         reported was the 1e18 ceiling, not a derived number. The docblock's promise that θ is
    ///         "measured live (no hardcoded constant)" was true of K and vacuous for σ².
    function testDerivedTheta_RealNumbers() public {
        address lp = makeAddr("theta-lp");
        _stageIL(lp, 50 ether);
        vm.deal(volActor, 200000 ether);

        // warm the oracle ring past the 40-min window with SMALL moves (calm)
        _moveEth(true, 2 ether, 12, volActor);
        // ⭐ AFTER the fixture has pinned its own feed: warm σ² from REAL rounds, else `work = K·σ²`
        //    is 0 and `_thetaAt` returns the 1e18 FAIL-OPEN ceiling for every regime below.
        emit log_named_uint("sigma^2 after real-round warm-up (0 == FAIL-OPEN)",
                            warmVarianceFromRealRounds(12));
        (uint kCalm, uint sigCalm, uint th5Calm) = _read("calm (small moves)");

        // sustained one-way trend -> higher realized vol -> smaller theta
        _moveEth(true, 60 ether, 10, volActor);
        (, uint sigTrend, uint th5Trend) = _read("trend-down (large sustained)");

        // chop: alternate sell/buy -> two-way vol
        for (uint i = 0; i < 8; i++) _moveEth(i % 2 == 0, 40 ether, 2, volActor);
        (, uint sigChop, uint th5Chop) = _read("chop (two-way)");

        emit log_string("________________________________");
        emit log_string("READ: theta = yield/(K*sigma^2). BOTH K (live range geometry) and sigma^2 (live realized) are measured on-chain -- NO hardcoded constant. Higher realized vol -> smaller safe theta.");

        // ── ASSERT the live-K behaviour (no hardcoded constant) ──────────────────────────────────────
        // (1) K is MEASURED from the live range geometry: a positive, O(10) closed-form coefficient for a
        //     concentrated range (K_center≈12.56 for the ±2% range) — well above the RETIRED 0.71/2.24
        //     sim-fit constants, and finite. The calm regime keeps spot near range-centre, so this is the
        //     deterministic central value; later regimes move spot and K tracks it (correctly) live.
        assertGt(kCalm, 0, "K must be measurable from the live range (not 0/degenerate)");
        // ⭐ BOUNDED BY DERIVATION, NOT BY A REMEMBERED NUMBER — and the window is TIGHT because the
        //    geometry makes it tight. The band is always `updateBounds(spot, RANGE_DELTA)`, so the
        //    RATIO `lo/up` is pinned at `(1-δ)/(1+δ)` however far spot has drifted; and `kLvrAt`
        //    CLAMPS spot into the band, so K cannot run away. K therefore lives in a closed interval
        //    whose ends are the two extreme spot positions:
        //      · spot at the CENTRE → the minimum (the widest denominator)
        //      · spot at either EDGE → the maximum (`r2 = 1`, the narrowest)
        //    Both are computed here from `SwapLib.RANGE_DELTA` through the production `QuidLib.kLvrAt`,
        //    so widening the range moves the window with it instead of leaving it behind.
        // ⚠️ WHAT WAS HERE BEFORE, AND WHY IT COULD NOT FAIL: `4e18 < kCalm < 400e18`, justified by a
        //    comment reading "the live range is MEASURED at LOWER_TICK 200570 / UPPER_TICK 200610 = 40
        //    ticks ~ +/-0.2% ... so ~125e18 is the correct central value for THIS geometry". There are
        //    no ticks any more and the band is ±2%, so the 12.56 that comment overrode was right all
        //    along. The window it left was 3x below and 32x above the true value — wide enough that
        //    the DEGENERATE case it named (spot pinned at an edge) also passes, at 12.62.
        (uint loK, uint upK) = SwapLib.updateBounds(1e18 * 100_000, SwapLib.RANGE_DELTA);
        uint kAtCentre = QuidLib.kLvrAt(1e18 * 100_000, loK, upK);
        uint kAtEdge   = QuidLib.kLvrAt(loK,            loK, upK);
        assertGe(kCalm, kAtCentre, "live K below the centre-of-band minimum -- the band is not RANGE_DELTA wide");
        assertLe(kCalm, kAtEdge,   "live K above the edge-of-band maximum -- the clamp is not holding");
        // cross-check θ@5% is exactly yield/(K·σ²) at the live K (no clamp in this regime).
        if (sigCalm > 0) assertEq(th5Calm, _thetaAt(kCalm, sigCalm, 5e16), "theta must be yield/(K*sigma^2) at the live K");
        // (2) MORE realized vol ⇒ SMALLER safe θ (the entire point of deriving θ live).
        if (sigTrend > sigCalm && sigCalm > 0) assertLt(th5Trend, th5Calm, "higher realized vol must shrink theta");
        // (3) FAIL-OPEN: a regime with no measurable vol yields θ=1 (pool not paralysed, no IL pressure).
        if (sigChop == 0) assertEq(th5Chop, 1e18, "zero realized vol must fail open to theta=1");
    }
}
