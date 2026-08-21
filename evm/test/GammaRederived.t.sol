// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

/// @title §E274 — Γ RE-DERIVED, AND THE UNCAPPED KERNEL MEASURED AGAINST THE 1e18 ARITHMETIC LIMIT.
/// @notice §E273 established the haircut's real failure point is `1e18` (`retainSkewPremium` does
///         `r.amount -= amount·skew/1e18`, so `skew > 1e18` ⇒ panic 0x11) and observed the cap sits
///         33× below it. It then named the REMAINING precondition and did not run it:
///         *"whether the curve can produce `1e18 ≤ skew < ∞` for FINITE q once Γ is no longer pinned
///         to the cap. Measure the new Γ's worst case against 1e18 before deleting."* This runs it.
///
/// THE CIRCULARITY BEING BROKEN: `SwapLib:1013-1014` records `Γ ≡ MAX_WELL_SKEW` EXACTLY — Γ was
/// DEFINED so that `skew(q=1, σ²=SIGMA_REF) = Γ·SIGMA_REF` lands on the cap. §GAMMA-HORIZON-DERIVED
/// then read a horizon back OUT of that number: 946,080 s = 10.95 days — *"a horizon nobody chose"*.
/// So the chain is cap → Γ → horizon, and NOTHING in it is measured. Deleting the cap therefore
/// deletes the curve's SCALE, which is why this must be answered before, not after.
///
/// `skewWad` is `public pure`, so all of this is measured with no fixture and no fork.
contract GammaRederivedTest is Test {
    // target = flowUsd (SwapLib:~980). inv0 = poolVolUsd. inv1 = inv0 − drainUsd6.
    // ⇒ q = (target − inv)/target, so q is set by choosing inv against a fixed target.
    uint constant TARGET = 1_000_000e6;
    uint constant CAP    = 3e16;      // MAX_WELL_SKEW
    uint constant LIMIT  = 1e18;      // §E273's real arithmetic failure point

    /// Faithful mirror of the kernel at `SwapLib:1044-1056`, with NO cap applied:
    ///     qBar = [ln((1−q0)/(1−q1)) − Δ]/Δ,  Δ = q1 − q0
    ///     kernel = Γ·σ²·qBar
    /// Γ is passed in so the same mirror serves the current Γ and any re-derived one.
    function _kernel(uint gamma, uint sigmaSq, uint q0, uint q1) internal pure returns (uint) {
        uint oneMinusQ = 1e18 - q1;
        uint qBar;
        if (oneMinusQ == 0) return type(uint).max;              // the pole itself
        if (q1 == q0) qBar = SoladyMath.fullMulDiv(q0, 1e18, 1e18 - q0);
        else {
            uint d = q1 - q0;
            uint lnTerm = uint(SoladyMath.lnWad(int(SoladyMath.fullMulDiv(1e18 - q0, 1e18, oneMinusQ))));
            qBar = lnTerm > d ? SoladyMath.fullMulDiv(lnTerm - d, 1e18, d) : 0;
        }
        return SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(gamma, sigmaSq, 1e18), qBar, 1e18);
    }

    function _invFor(uint q) internal pure returns (uint) { return TARGET - TARGET * q / 1e18; }

    /// CONTROL FIRST (repo rule: would this measurement look the same if I were wrong?).
    /// The mirror must reproduce the LIVE function wherever the cap does NOT bind. If it does not,
    /// every number below is about a formula the contract does not run.
    function test_E274_MirrorIsFaithfulWhereTheCapDoesNotBind() public pure {
        uint sigma = 1e12;                       // tiny σ² ⇒ kernel far below the cap
        uint q0 = 0.10e18; uint q1 = 0.50e18;
        uint inv0 = _invFor(q0); uint inv1 = _invFor(q1);
        uint live = SwapLib.skewWad(inv0, TARGET, sigma, SwapLib.ethRisk(), inv0 - inv1);
        uint mirror = _kernel(CAP, sigma, q0, q1);
        // live = kernel + base + depletion. The mirror is the kernel alone, so it must be the
        // DOMINANT part and must not exceed live. Both must sit under the cap for this control.
        assertLt(mirror, CAP, "control void: mirror already at cap");
        assertLe(mirror, live, "mirror exceeds live => not a faithful kernel");
        console2.log("CONTROL  live:", live, " mirror(kernel):", mirror);
    }

    /// THE MEASUREMENT §E273 ASKED FOR: does the UNCAPPED kernel reach 1e18 at FINITE q?
    function test_E274_UncappedKernelCrosses1e18AtFiniteQ() public pure {
        uint[4] memory sigmas = [uint(1e16), 1e17, 1e18, 4e18];  // 10%, 32%, 100%, 200% ann. vol
        uint[5] memory q1s = [uint(0.90e18), 0.99e18, 0.999e18, 0.9999e18, 0.99999e18];
        uint q0 = 0.50e18;
        console2.log("=== uncapped kernel, gamma = 3e16 (current), q0 = 0.5 ===");
        uint firstCross = type(uint).max;
        for (uint i; i < sigmas.length; ++i) {
            for (uint j; j < q1s.length; ++j) {
                uint k = _kernel(CAP, sigmas[i], q0, q1s[j]);
                console2.log("  sigma2:", sigmas[i]);
                console2.log("    q1:", q1s[j], " kernel:", k);
                if (k >= LIMIT && firstCross == type(uint).max) firstCross = q1s[j];
            }
        }
        console2.log("first q1 crossing 1e18:", firstCross);
        // The claim under test: the cap is NOT what keeps the haircut safe; finite q reaches the
        // panic point on its own. If this fails, deleting the cap is safe on this axis after all.
        assertTrue(firstCross != type(uint).max, "kernel never reaches 1e18 at finite q");
    }

    /// Where does the CAP bind today? Everything above this is currently invisible.
    function test_E274_WhereTheCapBindsToday() public pure {
        uint sigma = 1e18;
        uint q0 = 0.50e18;
        uint[5] memory q1s = [uint(0.60e18), 0.70e18, 0.80e18, 0.90e18, 0.95e18];
        for (uint j; j < q1s.length; ++j) {
            uint inv0 = _invFor(q0); uint inv1 = _invFor(q1s[j]);
            uint live = SwapLib.skewWad(inv0, TARGET, sigma, SwapLib.ethRisk(), inv0 - inv1);
            uint k = _kernel(CAP, sigma, q0, q1s[j]);
            console2.log("  q1:", q1s[j]);
            console2.log("    live(capped):", live, " uncapped kernel:", k);
        }
    }
}

/// @notice §E274 part 2 — Γ RE-DERIVED FROM A HORIZON SOMEBODY CHOSE, AND ITS WORST CASE MEASURED.
///
/// THE DERIVATION. A–S's reservation premium is `q·γ·σ²·(T−t)`; the code folds γ and (T−t) into Γ
/// (`SwapLib:~740`). σ² is ANNUALIZED (`QuidLib:161,169`: tickVar·SECS_PER_YEAR/THETA_STEP), so
/// (T−t) must be in YEARS. The only holding horizon in this repo that was chosen for a stated reason
/// is `Core.sol:207` `FLOW_DECAY` — a **48h half-life**, documented as the flow-EWMA memory for
/// "the well's flow-EWMA / inventory-skew target". That IS the timescale on which an imbalance is
/// expected to be worked off, which is precisely what (T−t) means here.
///     Γ_derived = γ·(T−t) = 1 · 172,800/31,536,000 = 5.48e15
/// versus Γ_current = 3e16 ⇒ an implied 946,080 s = 10.95 days, which §GAMMA-HORIZON-DERIVED calls
/// "a horizon nobody chose". **The current Γ is 5.475× the one the flow register implies.**
contract GammaRederivedPart2Test is Test {
    uint constant TARGET = 1_000_000e6;
    uint constant LIMIT  = 1e18;
    uint constant G_CUR  = 3e16;      // Γ ≡ MAX_WELL_SKEW (circular)
    uint constant G_NEW  = 5.48e15;   // Γ = 48h/1yr, γ = 1

    function _kernel(uint gamma, uint sigmaSq, uint q0, uint q1) internal pure returns (uint) {
        uint oneMinusQ = 1e18 - q1;
        uint qBar;
        if (oneMinusQ == 0) return type(uint).max;
        if (q1 == q0) qBar = SoladyMath.fullMulDiv(q0, 1e18, 1e18 - q0);
        else {
            uint d = q1 - q0;
            uint lnTerm = uint(SoladyMath.lnWad(int(SoladyMath.fullMulDiv(1e18 - q0, 1e18, oneMinusQ))));
            qBar = lnTerm > d ? SoladyMath.fullMulDiv(lnTerm - d, 1e18, d) : 0;
        }
        return SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(gamma, sigmaSq, 1e18), qBar, 1e18);
    }

    /// WORST CASE OVER BOTH q0 AND q1 — the previous test held q0 at 0.5, which is NOT the worst
    /// case: qBar grows as the drain SHRINKS near the pole (Δ→0), not as it grows.
    function test_E274_WorstCaseIsTheSMALLDrainNearThePole() public pure {
        uint sigma = 4e18;                                  // 200% annualized vol
        uint[3] memory q0s = [uint(0.90e18), 0.99e18, 0.999e18];
        console2.log("=== sigma2 = 4e18, tiny drain above each q0 ===");
        for (uint i; i < q0s.length; ++i) {
            uint q1 = q0s[i] + (1e18 - q0s[i]) / 10;        // consume 10% of REMAINING headroom
            console2.log("  q0:", q0s[i]);
            console2.log("    q1:", q1);
            console2.log("    kernel @Gamma=3e16 :", _kernel(G_CUR, sigma, q0s[i], q1));
            console2.log("    kernel @Gamma=5.48e15:", _kernel(G_NEW, sigma, q0s[i], q1));
        }
    }

    /// THE ZERO-SIZE QUOTE (Δ=0) IS THE REAL WORST CASE — and it is the path `Aux` reads for the
    /// MM/solver signal, i.e. a QUOTE, not a fill. `qBar = q/(1−q)` diverges with no integral to
    /// average it down.
    function test_E274_ZeroSizeQuoteIsUnboundedUnderBothGammas() public pure {
        uint sigma = 4e18;
        uint[4] memory qs = [uint(0.99e18), 0.999e18, 0.9999e18, 0.99999e18];
        console2.log("=== Delta = 0 (instantaneous quote), sigma2 = 4e18 ===");
        for (uint i; i < qs.length; ++i) {
            uint kc = _kernel(G_CUR, sigma, qs[i], qs[i]);
            uint kn = _kernel(G_NEW, sigma, qs[i], qs[i]);
            console2.log("  q:", qs[i]);
            console2.log("    @3e16   :", kc, kc >= LIMIT ? " >= 1e18 PANIC" : " ok");
            console2.log("    @5.48e15:", kn, kn >= LIMIT ? " >= 1e18 PANIC" : " ok");
        }
    }
}
