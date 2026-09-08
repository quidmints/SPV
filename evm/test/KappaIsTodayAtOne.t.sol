// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §E289 — κ = 1e18 IS THE PRE-REFACTOR KERNEL, EXACTLY
///
/// @notice **THE POINT OF THIS FILE IS THAT IT MUST PASS UNCHANGED BOTH BEFORE AND AFTER THE `κ`
///         REFACTOR.** It pins `skewWad` to values captured from the ORIGINAL `q/(1−q)` kernel, so it
///         is a behaviour lock, not a description of the new code.
///
///         ⚠️ **EVERY ASSERTION IS AN EQUALITY, DELIBERATELY.** §E287 landed a kernel replacement that
///         `GammaRederived`'s `assertLe`-based "control" passed unchanged, and §E279 records the same
///         class on the swap path (`assertGt` cannot distinguish `s` from `s·(2−s)`). A refactor
///         claiming to be behaviour-preserving is exactly the case a directional assertion cannot
///         check, so there is not one here.
///
///         🔴 **§E274-LAND — AND Γ MOVING RAISES THEM TOO, WHICH IS A FALSE SIGNAL THIS FILE COULD NOT
///         DISTINGUISH.** All three equalities below went red on `a4787689`, which moved Γ off `3e16`
///         onto its `FLOW_HALFLIFE` derivation and touched κ not at all. project-bc attributed it:
///         green at 11:26, red at 17:32, and **byte-identical before and after an unrelated revert**,
///         which is what proved the cause was neither of the changes in flight. ⇒ They are the fifth,
///         sixth and seventh members of the stale-Γ-binder class `37d752b4` fixed four of.
///         ⛔ **AND A Γ-KEYED SWEEP CANNOT FIND THEM — THE LITERALS ARE KERNEL *OUTPUTS*, NOT Γ.** My
///         sweep grepped for Γ's VALUE (`3e16`); `225438091215876142` contains it nowhere. The
///         structural sweep is *"every literal compared against a `_skew`/kernel reading"*, never
///         *"every file that mentions gamma"* — a third arrival of the same audit-by-name failure.
///
///         🔴 **WHEN κ IS RAISED, THESE NUMBERS MUST CHANGE.** That is the intended failure: this file
///         going red on a κ move is the signal that the ECONOMIC commit has landed, and the expected
///         values must then be re-derived from the new κ rather than relaxed. **Do not "fix" it with a
///         tolerance** — that is rule 4, and the reason the pole survived three bad patches today.
contract KappaIsTodayAtOneTest is Test {
    uint constant TARGET = 1_000_000e6;      // flow EWMA, 6-dec USD
    uint constant SIGMA  = 16e18;            // 400% ann. Chosen so the KERNEL dominates the base and the
                                             // depletion term - at 1e12 the base swamps it and the fixture
                                             // stops discriminating, which is exactly how GammaRederived's
                                             // control went vacuous (see the header).

    function _invFor(uint q) internal pure returns (uint) { return TARGET - TARGET * q / 1e18; }

    function _skew(uint q0, uint q1) internal pure returns (uint) {
        uint inv0 = _invFor(q0);
        uint inv1 = _invFor(q1);
        return SwapLib.skewWad(inv0, TARGET, SIGMA, SwapLib.ethRisk(), inv0 - inv1);
    }

    /// A mid-range drain, well clear of both the flush branch and the pole.
    /// ⚠️ **RE-CAPTURED AT THE DERIVED Γ, AND THEREBY DEMOTED.** `225438091215876142` was a genuine
    ///    pre-κ-refactor capture, which is what made it evidence rather than a lock. Γ moving spends
    ///    that provenance and **no rescaling recovers it**: MEASURED, `base + (captured−base)·Γ/3e16`
    ///    gives 41,176,528,258,607,510 against an actual 41,252,814,407,770,371 — **0.185% out**,
    ///    because §E68's midpoint `qBar` and §E89b's amplifier are not linear in Γ (only the Δ=0
    ///    branch is; see the next test, where the same rescaling is EXACT to the wei).
    /// ⇒ So this is now a DRIFT LOCK at the landed Γ, exactly what the header already says about
    ///   `NearThePole`, and it must NOT be cited as evidence the κ refactor preserved behaviour.
    ///   ⛔ Not given a tolerance — that is the header's own rule 4 — and not deleted, because a lock
    ///     that catches the next unintended move is still worth having.
    function test_E289_MidRangeDrainIsUnchanged() public pure {
        assertEq(_skew(0.10e18, 0.50e18), 41252814407770371, "kappa=1 must reproduce the original");
    }

    /// The zero-size read — the Aux/MM signal, and the Δ=0 branch the refactor rewrote.
    function test_E289_ZeroSizeReadIsUnchanged() public pure {
        uint inv = _invFor(0.40e18);
        // ⭐ **THIS ONE KEEPS ITS PROVENANCE, because the Δ=0 branch IS exactly linear in Γ.** The
        //    original pre-refactor capture was `320000759999999999` at Γ = 3e16; rescaling the KERNEL
        //    part while leaving the Γ-free base alone reproduces the live value **to the wei**
        //    (58,448,248,584,474,879 — verified, not asserted). So the §E287 cross-check survives Γ
        //    intact here, and it is written as the derivation so it survives the NEXT Γ move too.
        //    `base` is read live from the flush branch, which charges the base alone (§E89).
        uint base = SwapLib.skewWad(TARGET, TARGET, SIGMA, SwapLib.ethRisk(), 0);
        assertEq(SwapLib.skewWad(inv, TARGET, SIGMA, SwapLib.ethRisk(), 0),
                 base + (uint(320000759999999999) - base) * SwapLib.GAMMA_WAD / 3e16,
                 "the delta-zero branch must be untouched at kappa=1");
    }

    /// Deep scarcity, where the pole's convexity dominates and any change of exponent would show.
    /// ⚠️ **PROVENANCE, because it differs from the two above and that matters.** The mid-range and
    ///    zero-size values were measured on the kernel BEFORE the κ refactor (they are the actual
    ///    values from §E287's failing run) and they still hold after it — **those two are genuine
    ///    cross-checks of behaviour-preservation.** This one was captured AFTER, so it is a LOCK
    ///    against future drift, not evidence about the refactor. Do not cite it as the latter.
    function test_E289_NearThePoleIsUnchanged() public pure {
        // §E274-LAND: re-captured at the derived Γ. Rescaling misses by 0.113%
        // (136,664,574,233,818,743 vs 136,819,053,685,873,538) for the same non-linearity as
        // `MidRangeDrain`. This value was ALREADY a lock rather than evidence, per the note above, so
        // re-capturing costs nothing here — unlike the other two, it loses no provenance it had.
        assertEq(_skew(0, 0.90e18), 136819053685873538, "the convex tail must be untouched");
    }

    /// 🔴 THE POLE ITSELF. At κ = 1e18 a full drain still ends at `inv1 == 0`, so `kMinusQ1 == 0` and
    ///    the sentinel still fires — **the brake is still there.** This is the assertion that would
    ///    have caught §E287 before it was pushed.
    function test_E289_FullDrainStillHitsTheSentinel() public pure {
        assertEq(_skew(0, 1e18), type(uint).max,
                 "at kappa=1 the range must still be unemptiable - the brake is not removed yet");
    }

    /// CONTROL — would this look the same if I were wrong? These values were captured from the kernel
    /// BEFORE the refactor. If the refactor changed the arithmetic at κ=1e18, at least one of the
    /// three finite assertions above moves; if it changed only the pole handling, the fourth does.
    /// A refactor that broke everything would fail all four, and one that broke nothing passes all
    /// four — which is the discrimination `assertLe` could not provide.
    function test_E289_ControlTheValuesAreDistinct() public pure {
        assertTrue(_skew(0.10e18, 0.50e18) != _skew(0, 0.90e18), "control void: fixtures collapsed");
        assertGt(_skew(0, 0.90e18), _skew(0.10e18, 0.50e18), "and the curve is increasing in scarcity");
    }
}
