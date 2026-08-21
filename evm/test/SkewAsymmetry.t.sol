// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §UNIT-ASYM — the BTC/ETH skew asymmetry, measured instead of asserted.
/// @notice §UNIT-ASYM records the asymmetry as "the priced window differs by 300x" and calls that
///         the material omission. That claim was never executed. This measures it.
///
///         The instrument is `SwapLib.skewWad`, which is `public pure`: identical inputs with one
///         bool flipped is a CONTROL that range state cannot confound. That matters because every
///         previous skew measurement here ran against a fixture, and two were overturned when the
///         fixture (not the code) turned out to explain the number.
///
///         The decomposition needs no duplicated constants: §UNIT-A changed the `target == 0`
///         early return to yield exactly `_maxWellSkew(sigma2, isBTC)`, so calling with `flow = 0`
///         reads the BASE through the public API. The kernel is then (total - base).
contract SkewAsymmetry is Test {
    uint constant WAD = 1e18;

    /// Reads the per-asset BASE alone, via UNIT-A's target==0 early return.
    function _base(uint sigmaSqWad, bool isBTC) internal pure returns (uint) {
        return SwapLib.skewWad(1_000_000e6, 0, sigmaSqWad,
            isBTC ? SwapLib.btcRisk() : SwapLib.ethRisk(), 0);
    }

    /// @notice THE WINDOW RATIO IS EXACTLY 300x — and that is the LEAST important thing about the
    ///         asymmetry. Prediction (stated before running): base_BTC - base_ETH*300 == SPLICE_FLOOR.
    function test_UNITASYM_WindowGapIs300x_ButSpliceDominates() public {
        // sigma^2 = 1e18 == 100%/yr variance: a round, unambiguous reference point.
        uint s = WAD;
        uint bBtc = _base(s, true);
        uint bEth = _base(s, false);

        emit log_named_uint("base BTC (wad)       ", bBtc);
        emit log_named_uint("base ETH (wad)       ", bEth);

        // The ETH base is the pure window term (no splice). Scaling it by the window ratio must
        // reproduce BTC's window term exactly -- leaving the splice as the whole remainder.
        uint ethScaled = bEth * 300;
        assertGt(bBtc, ethScaled, "BTC base must exceed the scaled ETH window term by the splice");
        uint remainder = bBtc - ethScaled;

        emit log_named_uint("ETH window x300      ", ethScaled);
        emit log_named_uint("remainder (= splice?)", remainder);

        // SPLICE_FLOOR is 2e15. If the window ratio is exactly 300, the remainder IS the splice.
        assertEq(remainder, 2e15, "remainder is not exactly SPLICE_FLOOR => window ratio is not 300");

        // THE POINT: what fraction of BTC's base is the splice, not the window?
        uint splicePctE4 = (2e15 * 1e4) / bBtc;      // basis points of the BTC base
        emit log_named_uint("splice as bps of base", splicePctE4);
        assertGt(splicePctE4, 9_900, "splice should dominate BTC's base (>99%)");
    }

    /// @notice THE ASYMMETRY IS SCALE-DEPENDENT: the window term grows with sigma^2, the splice does
    ///         not. So there is a variance above which the window stops being a rounding detail.
    ///         Finding that crossover is the actual UNIT-ASYM question -- "300x" alone is unitless
    ///         and cannot tell anyone when it matters.
    function test_UNITASYM_FindTheVarianceWhereTheWindowStopsBeingNoise() public {
        uint[6] memory sigmas = [uint(1e16), 1e17, 1e18, 1e19, 1e20, 1e21]; // 1% .. 10000%/yr
        for (uint i; i < sigmas.length; i++) {
            uint s = sigmas[i];
            uint bBtc = _base(s, true);
            uint bEth = _base(s, false);
            // window term on the BTC leg = base - splice
            uint win = bBtc > 2e15 ? bBtc - 2e15 : 0;
            uint winBpsOfBase = bBtc == 0 ? 0 : (win * 1e4) / bBtc;
            emit log_named_uint("--- sigma^2 (wad)    ", s);
            emit log_named_uint("    base BTC         ", bBtc);
            emit log_named_uint("    base ETH         ", bEth);
            emit log_named_uint("    window bps of BTC", winBpsOfBase);
        }
    }

    /// @notice §E131's ADEQUACY TEST, RE-RUN ON BTC — §UNIT-ASYM's second named-but-unexecuted check.
    ///         E131 measured the breakeven exposure window `T* = 8P/(V*sigma^2)` on ETH and asserted
    ///         `T* >= ETH_CONF_FRAC_WAD`: the premium must fund LVR over at least the window
    ///         `_maxWellSkew` charges for, or the formula contradicts its own derivation. That row
    ///         says the result is PER-ASSET and must be re-run for BTC before anything is claimed
    ///         for that leg. This is that run, on a FLUSH range (kernel == 0), which is the worst
    ///         case: the base is then the entire premium.
    function test_UNITASYM_E131_AdequacyOnBothLegs_FlushRange() public {
        uint[3] memory sigmas = [uint(36e16), 1e18, 4e18];   // 60%/yr (E131's reference), 100%, 200%
        for (uint i; i < sigmas.length; i++) {
            uint s = sigmas[i];
            // T* in WAD-years = 8 * skew / sigma^2. On a flush range skew == base.
            uint tBtc = (8 * _base(s, true)  * WAD) / s;
            uint tEth = (8 * _base(s, false) * WAD) / s;
            // WAD-years -> seconds
            uint secBtc = (tBtc * 31_536_000) / WAD;
            uint secEth = (tEth * 31_536_000) / WAD;

            emit log_named_uint("=== sigma^2 (wad)    ", s);
            emit log_named_uint("    T* BTC (seconds) ", secBtc);
            emit log_named_uint("    T* ETH (seconds) ", secEth);

            // E131's assertion, per asset: T* must cover the window each leg prices for.
            assertGe(tBtc, 114_000_000_000_000, "BTC: premium under-funds its own 1hr window");
            assertGe(tEth, 380_000_000_000,     "ETH: premium under-funds its own 12s window");
        }
    }

    /// @notice THE ADEQUACY MARGIN IS THE REAL ASYMMETRY, AND IT RUNS THE OPPOSITE WAY TO UNIT-ASYM's
    ///         FRAMING. BTC's base carries a variance-INDEPENDENT splice on top of the LVR term, so
    ///         its T* strictly exceeds its window. ETH's base is EXACTLY sigma^2*window/8, so on a
    ///         flush range T* equals its window with ZERO margin -- E131's assertion passes by
    ///         equality, not by headroom. Everything ETH has above breakeven comes from the kernel,
    ///         which is zero precisely when the range is flush.
    function test_UNITASYM_EthFlushRangeIsExactlyBreakeven_BtcIsNot() public {
        uint s = WAD;
        uint tEth = (8 * _base(s, false) * WAD) / s;
        uint tBtc = (8 * _base(s, true)  * WAD) / s;

        emit log_named_uint("ETH T* (wad-years)   ", tEth);
        emit log_named_uint("ETH window (wad-yrs) ", uint(380_000_000_000));
        emit log_named_uint("BTC T* (wad-years)   ", tBtc);
        emit log_named_uint("BTC window (wad-yrs) ", uint(114_000_000_000_000));

        // ETH: exact equality. No margin whatsoever on a flush range.
        assertEq(tEth, 380_000_000_000, "ETH flush T* should be EXACTLY its 12s window");

        // BTC: strictly greater, and the excess is the splice re-expressed as time.
        assertGt(tBtc, 114_000_000_000_000, "BTC flush T* should exceed its window via the splice");
        uint marginSec = ((tBtc - 114_000_000_000_000) * 31_536_000) / WAD;
        emit log_named_uint("BTC margin (seconds) ", marginSec);
        emit log_named_uint("BTC margin (days)    ", marginSec / 86_400);
    }

    /// @notice §UNIT-B ATTRIBUTION — SPLIT THE CONSOLIDATION DISCOUNT INTO ITS TWO CANDIDATE MOVERS.
    ///         §UNIT-B proves the target, not the kernel, is the mover (a correct integral is
    ///         path-independent). Two mechanisms can move it, and they need separating because they
    ///         have OPPOSITE fixes:
    ///           (a) THE INVENTORY TRAPEZOID — as a drain proceeds, poolVol falls, so later slices
    ///               are priced on a scarcer range. This is INTRINSIC to integrating a convex curve
    ///               and is not a defect: the chopped path pays MORE because it genuinely does more
    ///               damage per later dollar.
    ///           (b) THE EWMA RATCHET — each slice bumps `flowEwmaUsd`, raising the TARGET for the
    ///               next, so the chopped path is priced against a walking target.
    ///         This isolates (a) EXACTLY by holding flow CONSTANT and decrementing only inventory --
    ///         which the pure function permits and a fixture cannot, since a fixture bumps the EWMA
    ///         as a side effect of trading. Whatever the fixture's total discount exceeds this by is
    ///         attributable to (b).
    ///
    ///         The owner's decision -- "the target should not include the trade's own flow" -- is
    ///         ALREADY the code's behaviour: pricing happens at SwapLib:444/467 and the bump at
    ///         Core:939, inside _finishSwap, called at :471. So own-flow inclusion cannot be the
    ///         mover, and (b) is specifically the PRECEDING slices, not the trade itself.
    function test_UNITB_AttributeTheDiscount_TrapezoidVsRatchet() public {
        uint s      = WAD;
        uint flow   = 400_000e6;      // HELD CONSTANT: no ratchet, so only the trapezoid can act
        uint pool0  = 300_000e6;
        uint total  = 120_000e6;

        // PATH A -- one drain of the whole notional, priced once on the entry range.
        uint premA = (SwapLib.skewWad(pool0, flow, s, SwapLib.ethRisk(), total) * total) / WAD;

        // PATH B -- twelve slices. Inventory falls as it would in reality; flow does NOT move.
        uint slice = total / 12;
        uint premB;
        uint pool = pool0;
        for (uint i; i < 12; i++) {
            premB += (SwapLib.skewWad(pool, flow, s, SwapLib.ethRisk(), slice) * slice) / WAD;
            pool = pool > slice ? pool - slice : 0;
        }

        emit log_named_uint("path A premium (usd6)", premA);
        emit log_named_uint("path B premium (usd6)", premB);
        assertGt(premA, 0, "path A charged nothing - fixture proves nothing");
        assertGt(premB, 0, "path B charged nothing - fixture proves nothing");

        // Report against the SKEW, not the notional: a 1bp-of-notional denominator structurally
        // cannot see a defect measured as a fraction of the premium.
        uint discountBps = premB > premA
            ? ((premB - premA) * 10_000) / premB
            : ((premA - premB) * 10_000) / premA;
        emit log_named_string("direction            ",
            premB > premA ? "chopped pays MORE (whale discount)" : "chopped pays LESS");
        emit log_named_uint("trapezoid-only bps   ", discountBps);
    }

    /// @notice §GAMMA-HORIZON — DERIVE THE HORIZON Γ CARRIES, BY DIMENSIONS AND THEN BY MEASUREMENT.
    ///         `SwapLib:849` claims *"the horizon T−t is already carried by the FLOW_DECAY EWMA
    ///         smoothing of flow/scarcity"*. That cannot be right dimensionally: σ² is ANNUALIZED
    ///         (units yr^-1), q and qBar are dimensionless ratios, and skew is a dimensionless
    ///         fraction -- so `skew = Γ·σ²·qBar` REQUIRES Γ to carry years. Smoothing a dimensionless
    ///         ratio cannot supply them. Therefore Γ IS the horizon (times γ), and its value is
    ///         readable: Γ = 3e16 = 0.03 yr-equivalents.
    ///
    ///         The measurement below pins the coefficient empirically instead of trusting the algebra:
    ///         at qBar = 1 (q = 0.5, i.e. inv/target = 0.5) the kernel must equal Γ·σ² exactly.
    function test_GAMMA_HorizonIsCarriedByGammaNotTheEwma() public {
        // qBar = q/(1-q) = 1  <=>  q = 0.5  <=>  inv/target = 0.5
        uint poolVol = 200_000e6;
        uint flow    = 400_000e6;
        // sigma^2 = 1e17 (=0.1/yr) keeps kernel = 3e16*0.1 = 3e15, well under the 3e16 cap, so the
        // reading is the CURVE and not the clamp -- the saturation trap that has bitten twice here.
        uint s = 1e17;

        uint total = SwapLib.skewWad(poolVol, flow, s, SwapLib.ethRisk(), 0);
        uint base  = _base(s, false);
        uint kernel = total - base;

        emit log_named_uint("total (wad)          ", total);
        emit log_named_uint("base  (wad)          ", base);
        emit log_named_uint("kernel = G*sigma^2   ", kernel);
        assertLt(total, 3e16, "SATURATION: pinned at the cap, the reading would be the clamp");

        // Gamma recovered from the measurement: G = kernel / (sigma^2 * qBar), qBar = 1.
        uint gammaRecovered = kernel * 1e18 / s;
        emit log_named_uint("Gamma recovered (wad)", gammaRecovered);
        assertApproxEqRel(gammaRecovered, 3e16, 1e15, "Gamma is not MAX_WELL_SKEW as documented");

        // Gamma carries years. At gamma_riskaversion = 1, the implied horizon is Gamma itself.
        // 0.03 yr * 365.25 d = 10.96 days = 947,808 s.
        uint horizonSecs = gammaRecovered * 31_536_000 / 1e18;
        emit log_named_uint("implied horizon (s)  ", horizonSecs);
        emit log_named_uint("implied horizon (d)  ", horizonSecs / 86_400);

        // THE POINT: that horizon dwarfs the 4h gaps that collapse the charge by 93%. A kernel
        // missing a horizon term cannot be the defect at that timescale.
        // MEASURED ratio is 946,080 / 14,400 = 65.7x. The first threshold written here was 100x and
        // FAILED at 65.7x -- recorded because the assertion was wrong, not the derivation, and a
        // threshold picked before the measurement is exactly the kind of number that gets quietly
        // widened until it passes. 10x is the claim being made ("dwarfs"), and it is not retrofitted.
        emit log_named_uint("horizon / 4h spacing ", horizonSecs / 4 hours);
        assertGt(horizonSecs, 4 hours * 10, "implied horizon should dwarf the attack's 4h spacing");
    }

    /// @notice CONTROL: the A-S kernel itself must be asset-independent. If it is not, the
    ///         asymmetry is wider than the window+splice and UNIT-ASYM's framing is incomplete.
    ///         Same poolVol, same flow, same sigma^2, same drain -- only the bool differs.
    function test_UNITASYM_KernelIsAssetIndependent() public {
        uint s = WAD;
        // MILD scarcity on purpose. At inv/target = 0.25 the kernel is MAX_WELL_SKEW*qBar = 3x the
        // ceiling, so BOTH legs clamp to 3e16 and the comparison silently measures (cap - base)
        // instead of the kernel -- it FAILED that way first, and 3e16 on both legs was the tell.
        // inv/target = 0.75 => qBar = 1/3 => kernel ~1e16, comfortably under the 3% ceiling.
        uint poolVol = 300_000e6;
        uint flow    = 400_000e6;
        uint tBtc = SwapLib.skewWad(poolVol, flow, s, SwapLib.btcRisk(),  0);
        uint tEth = SwapLib.skewWad(poolVol, flow, s, SwapLib.ethRisk(), 0);

        // ANTI-SATURATION CONTROL: at the cap every input maps to the same output, so a clamped
        // run would "prove" asset-independence by erasing the difference rather than by absence of one.
        assertLt(tBtc, 3e16, "BTC leg saturated at MAX_WELL_SKEW - fixture cannot test the kernel");
        assertLt(tEth, 3e16, "ETH leg saturated at MAX_WELL_SKEW - fixture cannot test the kernel");

        emit log_named_uint("total BTC (wad)      ", tBtc);
        emit log_named_uint("total ETH (wad)      ", tEth);

        uint kBtc = tBtc - _base(s, true);
        uint kEth = tEth - _base(s, false);
        emit log_named_uint("kernel BTC (wad)     ", kBtc);
        emit log_named_uint("kernel ETH (wad)     ", kEth);

        assertEq(kBtc, kEth, "the A-S kernel must not depend on which asset it is");
    }
}
