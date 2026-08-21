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

    /// @notice THE DISCOUNT IS NOW BOUNDED. Same drain, same range, only σ² suppressed by waiting.
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
    ///         inventory fact: half the range left, and it has to be sourced back.
    function test_TheFloorSurvivesTotalVarianceSuppression() public pure {
        uint floored = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN);
        assertGt(floored, 0, "a half-drained range must cost something even at sigma^2 = 1");
    }

    /// @notice §E234-vac — THIS TEST WAS VACUOUS AND IS REWRITTEN. It read:
    ///
    ///             uint busyFloor    = skewWad(POOL, FLOW, 1, ethRisk(), DRAIN);
    ///             uint patientFloor = skewWad(POOL, FLOW, 1, ethRisk(), DRAIN);
    ///             assertEq(busyFloor, patientFloor, ...);
    ///
    ///         — two BYTE-IDENTICAL calls asserted equal, which holds for any implementation of
    ///         `skewWad` including one that returns a constant. It passed in the very run where its
    ///         two siblings caught a genuinely missing term, so it collected credit for their work.
    ///         Its NAME also misdescribed it: nothing about spacing was varied, because with σ² not
    ///         an argument to either call there were never "both arms".
    ///
    ///         WHAT IT MEANS TO SAY AND NOW DOES: the depletion component is keyed on the FRACTION
    ///         DRAINED (`inv0 != 0 && inv1 < inv0`, scaled by `(inv0-inv1)/inv0`). Two properties
    ///         follow, and both are checked here WITHOUT a tolerance — each is a strict inequality
    ///         between measured values, so neither can be satisfied by a constant or by luck:
    ///           (1) a LARGER drain owes strictly MORE at the same σ² — so the term tracks the
    ///               fraction rather than being a flat floor;
    ///           (2) a ZERO drain owes strictly LESS than any real drain — so a range nobody depleted
    ///               is not charged for depletion, which is the bootstrap property the constant's
    ///               derivation claims (`inv0 == 0` ⇒ no fall ⇒ no charge, BY CONSTRUCTION).
    ///         σ² is pinned at 1 for all three so the adverse-selection kernel is as close to zero
    ///         as the sentinel allows and what moves is the depletion term.
    function test_DepletionTracksTheDrainFractionAndSparesAnUndrainedRange() public pure {
        uint none = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), 0);
        uint half = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN);
        uint most = SwapLib.skewWad(POOL, FLOW, 1, SwapLib.ethRisk(), DRAIN * 3 / 2);

        assertGt(half, none, "a drained range must owe MORE than one nobody touched");
        assertGt(most, half, "a bigger drain must owe MORE: the term tracks the fraction, not a flat floor");
    }
}
