// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
// The SELL leg is `view` over live `Core` state, so its probe inherits the real deployment rather
// than mocking one — see `SellSkewUnmeasuredVarianceProbe` at the foot of this file.
import {AllesFixture} from "./Alles.t.sol";
import {ICore} from "../src/imports/Interfaces.sol";

/// @title §E59/§E79 — UNMEASURED VARIANCE MUST PRICE AT THE CEILING, NOT AT ZERO.
/// @notice `SwapLib.skewWad` is `public pure`, so this needs no fixture and no fork.
///
/// WHAT THIS CAUGHT (measured 2026-08-16, on a $1m range with a $2m shed target). At σ² = 0 the ETH
/// charge was **0** at 10%, 50% AND 90% drains; only a 100% drain reached the ceiling, and it did so
/// through the SEPARATE `qBar == type(uint).max` pole. BTC returned `SPLICE_FLOOR` alone. The kernel
/// is `Γ·σ²·qBar`, identically 0 when σ² is 0 however scarce the range is — so §E59's guard had to sit
/// OUTSIDE the product, and after §E79 inverted `_maxWellSkew` from ceiling to base there was nothing
/// left holding it. §E79's own comment predicted exactly this: *"returning [the base] here would
/// re-open the free-drain hole E59 closed."*
///
/// ⚠️ THE FIRST VERSION OF THIS PROBE WAS VACUOUS AND LOOKED LIKE A FINDING. It passed `flowUsd = 0`,
///    but `target = flowUsd` and `skewWad` returns the base at `target == 0` (`:845`,`:851`), so it
///    never reached the kernel and every drain size returned an IDENTICAL value. That constancy was
///    the tell. `test_PREMISE_*` below exists so the same mistake fails loudly next time instead of
///    reading as "the skew charges nothing".

contract SkewUnmeasuredVarianceTest is Test {
    uint constant POOL = 1_000_000e6;          // $1m range inventory, 6-dec
    uint constant FLOW = 2_000_000e6;          // shed target ABOVE inventory ⇒ genuinely scarce
    uint constant CEIL = 3e16;                 // MAX_WELL_SKEW, 3%

    /// @notice THE PREMISE EVERY OTHER TEST HERE DEPENDS ON: the kernel must actually be reached.
    ///         If drain size does not move the charge, `skewWad` short-circuited and any zero below
    ///         would be an artifact of the call, not a property of the skew.
    function test_PREMISE_TheKernelIsReachedAtAll() public pure {
        uint small = SwapLib.skewWad(POOL, FLOW, 1e16, SwapLib.ethRisk(), POOL / 10);
        uint large = SwapLib.skewWad(POOL, FLOW, 1e16, SwapLib.ethRisk(), (POOL * 9) / 10);
        assertGt(small, 0, "PREMISE: a measured-variance drain charges nothing, kernel unreached");
        assertGt(large, small, "PREMISE: drain size does not move the charge, kernel unreached");
    }

    /// @notice §E59 part 2, verbatim: "real scarcity (q > 0) plus UNMEASURED variance ⇒ charge the
    ///         ceiling. That is the conservative reading of 'unknown'."
    ///         Partial drains are the case that regressed; the 100% pole was always covered.
    function test_UnmeasuredVarianceChargesTheCeilingAtPartialScarcity() public pure {
        uint[3] memory drains = [POOL / 10, POOL / 2, (POOL * 9) / 10];
        for (uint i; i < drains.length; i++) {
            // PREMISE: the drain must leave the range genuinely scarce (inv1 < target), else the
            // flush branch returns the base and the assertion below tests nothing.
            assertLt(POOL - drains[i], FLOW, "PREMISE: this drain does not create scarcity");
            assertEq(SwapLib.skewWad(POOL, FLOW, 0, SwapLib.ethRisk(), drains[i]), CEIL,
                     "ETH: unmeasured variance with real scarcity must price at the ceiling");
            assertEq(SwapLib.skewWad(POOL, FLOW, 0, SwapLib.btcRisk(), drains[i]), CEIL,
                     "BTC: unmeasured variance with real scarcity must price at the ceiling");
        }
    }

    /// @notice THE SENTINEL MUST NOT SWALLOW A GENUINELY CALM MARKET. §E59 is explicit that only the
    ///         UNMEASURED case is treated as dangerous: "a genuinely calm market reports a SMALL
    ///         NON-ZERO variance and still caps low." A fix that charged the ceiling for tiny-but-real
    ///         variance would be over-charging every quiet tape, so this brackets the other side.
    function test_SmallButMeasuredVarianceStillPricesFarBelowTheCeiling() public pure {
        uint charge = SwapLib.skewWad(POOL, FLOW, 1e12, SwapLib.ethRisk(), POOL / 2);   // σ² tiny but REAL
        assertGt(charge, 0, "a measured variance must still charge something");
        assertLt(charge, CEIL / 100, "a calm-but-measured tape must not be priced near the ceiling");
    }


    /// @notice THE FLUSH BRANCH IS UNAFFECTED — a swap that ends at/above target created no scarcity
    ///         and still owes only the base, sentinel or not. Without this, the fix above could have
    ///         silently started charging 3% on every non-scarce swap and no test would have said so.
    function test_FlushRangeStillOwesOnlyTheBase() public pure {
        // inv1 >= target ⇒ the §UNIT-A flush path, which returns `_maxWellSkew` and never the kernel.
        uint flush = SwapLib.skewWad(POOL, POOL / 10, 0, SwapLib.ethRisk(), 0);
        assertLt(flush, CEIL, "a flush range must not be charged the unknown-variance ceiling");
        // 🔴 §E352 — PIN THE CELL, BECAUSE THE BOUND ABOVE IS SATISFIED **BY THE DEFECT**. On ETH at
        // σ² == 0 this value is 0, so `0 < 3e16` holds exactly as well as "the base" would: the
        // inequality cannot fail whichever way the arithmetic is decided, and the suite therefore
        // reported this branch as covered while it was not. (§VACUOUS-BOUNDS: the test's NAME claims
        // what the assertion does not check — it says *StillOwes* and never asserts anything is owed.)
        //
        // This assertion says what is ACTUALLY true today and names it as the open cell rather than
        // as correct behaviour: `target == 0` and `inv1 >= target` both return `_maxWellSkew` BEFORE
        // the σ² sentinel, and `_maxWellSkew(0, ethRisk)` is 0 because ETH's profile is
        // `(ETH_CONF_FRAC_WAD, 0)` — no splice floor. So §UNIT-A's "return the BASE, not zero" is
        // neutralised exactly when variance is unmeasured, because there the base IS zero.
        //
        // ⚠️ IT IS DELIBERATELY AN EQUALITY: it passes now and turns RED the moment §E278 is decided
        // either way, which an inequality cannot do. **An assertion a fix cannot fail is not coverage
        // of the fix.** Do NOT "repair" this by widening it back to a bound.
        assertEq(flush, 0,
            "SE352 CELL, NOT 'the base': an unmeasured flush range is charged ZERO on ETH. Pending the "
            "SE278 owner call. When that lands this MUST go red -- update it to the decided value.");
    }
}

/// §E278 half one, ON THE REAL RANGE. The drain leg above is `pure` and needs no fixture; `sellSkew`
/// is `view` over live `Core` state, so this half inherits the real deployment rather than standing a
/// double in front of it (CLAUDE.md rule 5, and the owner: *"there should be no mocks"*).
///
/// **WHAT IT GUARDS.** `sellSkew` prices an INVENTORY-INCREASING sell — somebody dumping the falling
/// asset into the range, the toxic direction. Its kernel is `Γ·σ²·qBar`, exactly 0 at σ² == 0 however
/// large `qBar` is, and `_composePrice` then adds `_maxWellSkew(0)`, which the §E79 inversion turned
/// into a FLOOR of ~0 — zero on ETH. So the whole charge was zero whenever variance was unmeasured,
/// on the one leg §E59 did not reach, while the code carried a comment saying it was guarded.
contract SellSkewUnmeasuredVarianceProbe is AllesFixture {
    uint constant CEIL = 3e16;   // UNKNOWN_VARIANCE_SKEW / MAX_WELL_SKEW, 3%

    /// 🔴 **THE INVARIANT THE GUARD BUYS, AND IT HOLDS IN BOTH VARIANCE REGIMES.** A sell that
    /// genuinely overshoots the shed target is never free. That is exactly what the defect violated
    /// — it returned 0 — and asserting it this way needs no control over σ², which on a real range is
    /// not ours to set. The regime is measured and printed rather than assumed, and each regime gets
    /// the assertion that can actually fail in it:
    ///   * σ² == 0 (unmeasured) ⇒ the kernel IS the ceiling. Before the guard: 0.
    ///   * σ²  > 0 (measured)   ⇒ the kernel is `Γ·σ²·qBar` and must be strictly positive, and must
    ///     NOT sit at the ceiling, or the sentinel is leaking into the measured path.
    ///
    /// ⚠️ `addedTok` is deliberately enormous so `over > 0` is true BY CONSTRUCTION rather than by
    ///    luck of the fixture's inventory — `inv` includes `addedTok` (see `_skewBasis`), and a probe
    ///    that accidentally set up a refill would return 0 at the `over == 0` exemption and prove
    ///    nothing. That is the §E59 vacuity failure, and it is what the premise assertions below
    ///    exist to make loud instead of silent.
    function test_SellLeg_AnOvershootingSellIsNeverFree() public {
        address core = address(CORE);
        uint px = AUX.getTWAPforAsset(address(WETH), 0);

        // PREMISE 1 — a target must exist. `sellSkew` returns 0 at `target == 0` before reaching any
        // kernel, so without live flow this test would be vacuous whatever the guard does.
        uint target = ICore(core).flowEwmaUsd();
        emit log_named_uint("flowEwmaUsd (target)  ", target);
        assertGt(target, 0, "PREMISE: no shed target on the live range, so the kernel is unreachable");

        uint sigmaSq = ICore(core).realizedVarianceWad();
        emit log_named_uint("realizedVarianceWad   ", sigmaSq);

        // Overshoot the target by orders of magnitude so `over > 0` cannot be an accident.
        uint addedTok = 1_000_000 ether;
        uint skew = SwapLib.sellSkew(core, px, addedTok);
        emit log_named_uint("sellSkew (wad)        ", skew);

        // THE INVARIANT, both regimes: the toxic direction is never priced at nothing.
        assertGt(skew, 0, "an inventory-increasing sell was priced at ZERO");

        if (sigmaSq == 0) {
            assertGe(skew, CEIL,
                "unmeasured variance must price the sell at the CEILING (this returned 0 before the guard)");
        } else {
            assertLt(skew, CEIL,
                "measured variance priced at the ceiling -- the sentinel is leaking into the kernel");
        }
    }

    /// PREMISE 2, AS ITS OWN TEST — the exemption is real and distinguishable. A sell that does NOT
    /// overshoot must return 0, so the assertion above is reading the kernel rather than a function
    /// that returns a positive number for every input.
    function test_PREMISE_SellLeg_ARefillIsExempt() public {
        // `addedTok == 0` cannot push a range above a target it is not already above; if the live
        // range happens to sit above target on its own this asserts nothing, so it is checked.
        address core = address(CORE);
        uint inv = ICore(core).POOLED();
        uint target = ICore(core).flowEwmaUsd();
        emit log_named_uint("POOLED (inv, native)  ", inv);
        emit log_named_uint("flowEwmaUsd (target)  ", target);
        uint px = AUX.getTWAPforAsset(address(WETH), 0);
        uint invUsd6 = (inv * px) / 1e30;
        if (invUsd6 > target) {
            emit log("live range already overshoots; exemption not exercisable here");
            return;
        }
        assertEq(SwapLib.sellSkew(core, px, 0), 0, "a non-overshooting sell must be exempt");
    }
}
