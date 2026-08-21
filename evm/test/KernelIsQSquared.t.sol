// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §E287 — THE DRAIN KERNEL IS `Γ·σ²·q²`, AND THE DEPLETION BARRIER IS GONE
///
/// @notice **THIS FILE EXISTS BECAUSE THE EXISTING CONTROL COULD NOT SEE THE KERNEL.**
///         `GammaRederived.t.sol`'s `test_E274_MirrorIsFaithfulWhereTheCapDoesNotBind` asserts
///         `assertLe(mirror, live)` at `σ² = 1e12`. At that variance `live` is dominated by the
///         DEPLETION term (`DEPLETION_RATE_WAD·Δinv/inv0` ≈ 9.3e13) while the kernel is ~1e10, so the
///         assertion clears by ~4 orders of magnitude **on a term that has nothing to do with the
///         kernel**. It passed unchanged when the kernel was replaced outright. That is the same
///         class §E279 names: a DIRECTIONAL assertion cannot discriminate a magnitude.
///         ⇒ Every assertion here is an EQUALITY or a strict bound on a number that moves with the
///         kernel, and each runs at a σ² where the kernel DOMINATES. `skewWad` is `public pure`, so
///         there is no fixture and no fork.
contract KernelIsQSquaredTest is Test {
    uint constant TARGET = 1_000_000e6;         // flow EWMA, 6-dec USD
    /// ⚠️ MIRRORS `SwapLib.GAMMA_WAD`, which is `internal`. If that constant moves and this does not,
    ///    `test_E287_KernelIsExactlyTheQSquaredIntegral` fails LOUDLY — which is the intended coupling.
    uint constant GAMMA = 3e16;
    /// σ² = 400% annualised. Chosen so the kernel is ~1e14 and dominates the ~9e13 depletion term;
    /// at the 1e12 the old control used, the kernel is invisible. **Do not lower this.**
    uint constant SIGMA = 16e18;

    function _invFor(uint q) internal pure returns (uint) { return TARGET - TARGET * q / 1e18; }

    /// The integral of the NEW kernel, factored: (1/Δ)∫[q0→q1] q² dq = (q1² + q1·q0 + q0²)/3.
    function _qBar(uint q0, uint q1) internal pure returns (uint) {
        return (mulWad(q1, q1) + mulWad(q1, q0) + mulWad(q0, q0)) / 3;
    }
    function mulWad(uint a, uint b) internal pure returns (uint) { return a * b / 1e18; }

    /// Everything `skewWad` adds on top of the kernel, mirrored so the kernel can be asserted EXACTLY.
    function _nonKernel(uint sigmaSq, uint inv0, uint inv1) internal pure returns (uint acc) {
        SwapLib.Risk memory rk = SwapLib.ethRisk();
        acc = sigmaSq * rk.confFracWad / 8e18 + rk.spliceFloor;     // §E79 base (LVR floor)
        if (inv0 != 0 && inv1 < inv0) acc += 2.1e14 * (inv0 - inv1) / inv0;   // DEPLETION_RATE_WAD
    }

    /// 🔴 THE HEADLINE PREDICTION. Before §E287 this input returned `type(uint).max` — the pole — and
    ///    every bound in the system existed to contain it. It must now be an ordinary finite price.
    function test_E287_EmptyBandIsFiniteAndPriced() public pure {
        uint inv0 = _invFor(0);                       // band exactly at target
        uint skew = SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0);  // drain ALL of it
        assertLt(skew, 1e18, "a full drain must price finitely, not at the pole");
        // q0 = 0, q1 = 1 ⇒ qBar = 1/3. This is an EQUALITY, not a bound: it pins the shape.
        assertEq(skew, mulWad(mulWad(GAMMA, SIGMA), _qBar(0, 1e18)) + _nonKernel(SIGMA, inv0, 0),
                 "full drain must equal the q-squared integral plus base and depletion");
    }

    /// The old kernel's defining feature was a DISCONTINUITY at the last unit: 99% drained was
    /// finite, 100% was infinite. A derived convexity has no such step.
    function test_E287_NoJumpAcrossTheOldPole() public pure {
        uint inv0 = _invFor(0);
        uint near = SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0 * 99 / 100);
        uint full = SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0);
        assertLt(full * 100 / near, 105, "the last 1% of inventory must not multiply the price");
        assertGt(full, near, "and the curve must still be increasing in scarcity");
    }

    /// The kernel is the integral, exactly — at a mid-range drain where nothing saturates.
    function test_E287_KernelIsExactlyTheQSquaredIntegral() public pure {
        uint q0 = 0.10e18; uint q1 = 0.50e18;
        uint inv0 = _invFor(q0); uint inv1 = _invFor(q1);
        uint skew = SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0 - inv1);
        assertEq(skew, mulWad(mulWad(GAMMA, SIGMA), _qBar(q0, q1)) + _nonKernel(SIGMA, inv0, inv1),
                 "kernel must be Gamma*sigma^2*(q1^2+q1q0+q0^2)/3");
    }

    /// Δ→0 is the instantaneous rate (the Aux/MM signal). The factored integral's own limit is `q²`,
    /// which is why §E287 could delete the `q1 == q0` branch instead of rewriting it.
    function test_E287_ZeroSizeReadIsTheInstantaneousRate() public pure {
        uint q = 0.40e18;
        uint inv = _invFor(q);
        uint skew = SwapLib.skewWad(inv, TARGET, SIGMA, SwapLib.ethRisk(), 0);
        assertEq(skew, mulWad(mulWad(GAMMA, SIGMA), mulWad(q, q)) + _nonKernel(SIGMA, inv, inv),
                 "a zero-size read must be the point rate q^2, with no branch of its own");
    }

    /// CONTROL — would this look the same if I were wrong? Under the OLD pole kernel
    /// `qBar = [ln((1−q0)/(1−q1)) − Δ]/Δ`, a q0=0→q1=0.5 drain gives qBar ≈ 0.386; under `q²` it is
    /// 0.0833. If this file were accidentally re-testing the pole, this assertion fails.
    function test_E287_ControlTheOldPoleWouldFailThis() public pure {
        uint inv0 = _invFor(0); uint inv1 = _invFor(0.5e18);
        uint skew = SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0 - inv1);
        uint kernel = skew - _nonKernel(SIGMA, inv0, inv1);
        uint poleKernel = mulWad(mulWad(GAMMA, SIGMA), 0.386e18);
        assertLt(kernel, poleKernel / 3, "kernel is not the q-squared one - the pole may be back");
    }
}
