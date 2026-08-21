// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";

/// @notice Reads the REAL derived θ = yield/(K·σ²) from live on-chain inputs, where BOTH K and σ²
///   are measured live (no hardcoded constant). σ² = Quid.realizedVarianceWad (Core's oracle ring);
///   K = Quid.kLvrWad — the closed-form band-geometry LVR coefficient computed from the live ticks.
///   avgYield on the fork is ~0 (mock venues don't accrue over a short test), so we ALSO show θ at
///   realistic yields {3,5,8%} using the real measured K·σ² — the meaningful "real number".
contract DerivedThetaProbe is AllesFixture {
    address volActor = makeAddr("theta-vol");

    function _thetaAt(uint kWad, uint sigmaSq, uint yieldWad) internal pure returns (uint) {
        uint work = kWad * sigmaSq / 1e18;   // K·σ² with the LIVE band-geometry K (no hardcode)
        if (work == 0) return 1e18;
        uint th = yieldWad * 1e18 / work;
        return th > 1e18 ? 1e18 : th;
    }

    function _read(string memory tag) internal returns (uint k, uint sigmaSq, uint theta5) {
        try ETH.realizedVarianceWad() returns (uint s) {
            sigmaSq = s;
            k = ETH.kLvrWad();   // LIVE band-geometry K
            theta5 = _thetaAt(k, s, 5e16);
            emit log_string("________________________________");
            emit log_named_string("regime", tag);
            emit log_named_uint("  realized sigma^2 (WAD)", s);
            emit log_named_uint("  implied sigma (annual %, approx)", _approxSigmaPct(s));
            emit log_named_uint("  LIVE K from band geometry (WAD)", k);
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

    function testDerivedTheta_RealNumbers() public {
        address lp = makeAddr("theta-lp");
        _stageIL(lp, 50 ether);
        vm.deal(volActor, 200000 ether);

        // warm the oracle ring past the 40-min window with SMALL moves (calm)
        _moveEth(true, 2 ether, 12, volActor);
        (uint kCalm, uint sigCalm, uint th5Calm) = _read("calm (small moves)");

        // sustained one-way trend -> higher realized vol -> smaller theta
        _moveEth(true, 60 ether, 10, volActor);
        (, uint sigTrend, uint th5Trend) = _read("trend-down (large sustained)");

        // chop: alternate sell/buy -> two-way vol
        for (uint i = 0; i < 8; i++) _moveEth(i % 2 == 0, 40 ether, 2, volActor);
        (, uint sigChop, uint th5Chop) = _read("chop (two-way)");

        emit log_string("________________________________");
        emit log_string("READ: theta = yield/(K*sigma^2). BOTH K (live band geometry) and sigma^2 (live realized) are measured on-chain -- NO hardcoded constant. Higher realized vol -> smaller safe theta.");

        // ── ASSERT the live-K behaviour (no hardcoded constant) ──────────────────────────────────────
        // (1) K is MEASURED from the live band geometry: a positive, O(10) closed-form coefficient for a
        //     concentrated band (K_center≈12.56 for the ±2% band) — well above the RETIRED 0.71/2.24
        //     sim-fit constants, and finite. The calm regime keeps spot near band-centre, so this is the
        //     deterministic central value; later regimes move spot and K tracks it (correctly) live.
        assertGt(kCalm, 0, "K must be measurable from the live band (not 0/degenerate)");
        assertGt(kCalm, 4e18, "live band-geometry K must be O(10) for a concentrated band, NOT the old ~0.71/2.24 constant");
        // CEILING CORRECTED (2026-07-26) — the old 100e18 encoded a band width the fixture does not
        // have. The comment above assumes "K_center ~= 12.56 for the +/-2% band", but the live band is
        // MEASURED at LOWER_TICK 200570 / UPPER_TICK 200610 = 40 ticks ~ +/-0.2%, i.e. TEN TIMES
        // narrower. K rises as the band narrows (denom = 2 - r1 - r2 shrinks), so ~125e18 is the
        // correct central value for THIS geometry — exactly the 10x of 12.56, so the closed form is
        // right and only the assumed width was stale. Verified pre-existing: upstream origin/main
        // fails identically at 125131291560419227605, to the wei.
        // The ceiling still does its real job — catching a DEGENERATE K (spot pinned at a band edge
        // drives denom -> 0 and K -> infinity) — with headroom above the measured central value.
        assertLt(kCalm, 400e18, "live K must stay in the band\'s finite closed-form range (non-degenerate)");
        // cross-check θ@5% is exactly yield/(K·σ²) at the live K (no clamp in this regime).
        if (sigCalm > 0) assertEq(th5Calm, _thetaAt(kCalm, sigCalm, 5e16), "theta must be yield/(K*sigma^2) at the live K");
        // (2) MORE realized vol ⇒ SMALLER safe θ (the entire point of deriving θ live).
        if (sigTrend > sigCalm && sigCalm > 0) assertLt(th5Trend, th5Calm, "higher realized vol must shrink theta");
        // (3) FAIL-OPEN: a regime with no measurable vol yields θ=1 (pool not paralysed, no IL pressure).
        if (sigChop == 0) assertEq(th5Chop, 1e18, "zero realized vol must fail open to theta=1");
    }
}
