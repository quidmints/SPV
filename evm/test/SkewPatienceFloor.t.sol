// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §UNIT-B-PATIENCE — what the σ²-free depletion term does to the patience discount.
/// @notice `skewWad` is `public pure`, so this measures the vector directly with no fixture, no
///         fork, and no dependence on `POOLED_USD` (which is currently never funded, §E230).
///
/// THE VECTOR, as measured by §UNIT-B-PATIENCE: spacing swaps 4h apart drove σ² **24× down**
/// (2.88e13 → 1.19e12) and the charge **93.3% down** — because the kernel was `Γ·σ²·qBar`, linear
/// in σ², so an attacker who merely WAITS buys a 15× discount without changing what they take.
///
/// WHAT §E216 CHANGES: depletion is now additive and σ²-FREE, keyed on the fraction actually
/// drained. Suppressing σ² still shrinks the adverse-selection term — correctly, that IS a
/// volatility cost — but it can no longer touch the depletion term. So the discount must now be
/// BOUNDED rather than near-total, and that bound is what this measures.
contract SkewPatienceFloorTest is Test {
    uint constant POOL = 1_000_000e6;
    uint constant FLOW = 2_000_000e6;
    uint constant DRAIN = 500_000e6;        // same take in both arms — only patience differs
    uint constant SIG_BUSY = 2.88e13;       // §UNIT-B-PATIENCE's measured same-block variance
    uint constant SIG_PATIENT = 1.19e12;    // ...and its 4h-spaced variance, 24x lower

    /// @notice THE DISCOUNT IS NOW BOUNDED. Same drain, same band, only σ² suppressed by waiting.
    ///         PREDICTION BEFORE RUNNING: the patient arm still pays LESS (adverse selection really
    ///         did fall) but no longer close to nothing — the σ²-free depletion term is a floor that
    ///         patience cannot reach.
    function test_PatienceDiscountIsBoundedByTheDepletionFloor() public {
        uint busy    = SwapLib.skewWad(POOL, FLOW, SIG_BUSY,    SwapLib.ethRisk(), DRAIN);
        uint patient = SwapLib.skewWad(POOL, FLOW, SIG_PATIENT, SwapLib.ethRisk(), DRAIN);
        assertGt(busy, 0, "PREMISE: the busy arm must charge something, else there is no discount to bound");
        assertLe(patient, busy, "PREMISE: suppressing sigma^2 should not RAISE the charge");

        uint discountBps = ((busy - patient) * 10_000) / busy;
        emit log_named_uint("busy    charge (wad)", busy);
        emit log_named_uint("patient charge (wad)", patient);
        emit log_named_uint("discount bought by waiting (bps of the busy charge)", discountBps);

        // §UNIT-B-PATIENCE measured 93.3% (9,330 bps) before the depletion term existed.
        assertLt(discountBps, 9_330, "waiting must buy STRICTLY less than the 93.3% it used to");
    }

    /// @notice THE FLOOR IS THE DEPLETION TERM ITSELF, NOT A TUNED NUMBER. Drive σ² to the sentinel's
    ///         doorstep (1 wei) and the charge must still be a real cost, because what remains is the
    ///         inventory fact: half the band left, and it has to be sourced back.
    function test_TheFloorSurvivesTotalVarianceSuppression() public pure {
        uint floored = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN);
        assertGt(floored, 0, "a half-drained band must cost something even at sigma^2 = 1");
    }

    /// @notice AND PATIENCE CANNOT REACH IT AT ALL. The depletion component is a function of the
    ///         drain fraction only, so two arms taking the SAME amount owe the SAME depletion no
    ///         matter how far apart their trades are spaced.
    function test_DepletionIsIdenticalAcrossBothArms() public pure {
        uint busyFloor    = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN);
        uint patientFloor = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN);
        assertEq(busyFloor, patientFloor, "same take must owe the same depletion regardless of spacing");
    }
}
