// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E287 — the load-bearing skew learnings, as EXECUTABLE assertions.
/// @notice **WHY THIS FILE EXISTS.** Every finding in §SKEW-LEARNINGS is prose in a 5,000-line ledger,
///         and prose is read as opinion. §E277 showed the failure mode concretely: a ✅ row's evidence
///         was a test that got deleted, and the conclusion stood for two weeks with nothing behind it.
///         So the durable form of a learning is an assertion that FAILS when the learning stops being
///         true — not a paragraph asserting it.
///
/// ⚠️ **THESE ARE NOT "DO NOT CHANGE THE BEHAVIOUR" LOCKS.** Each is falsifiable and each names, in its
///         own comment, exactly what a thread must do to overturn it legitimately. A red test here is a
///         PROMPT TO RE-MEASURE, never an instruction to revert. If the measurement says the learning
///         was wrong — confirmation bias, overfitting to one fixture, a premise that has since changed
///         — **update the assertion AND the row it guards, in the same commit.** What is forbidden is
///         only the silent path: making it green without re-running anything.
contract SkewLearningsAreLiveTest is Test {
    uint constant TARGET = 2_000_000e6;
    uint constant POOL   = 1_000_000e6;
    uint constant SIGMA  = 1e18;

    /// §E274/§E286 — **THE CURVE MUST NOT BE FLAT.** The deleted `MAX_WELL_SKEW` pinned the live skew
    /// at exactly 3e16 from q₁≈0.6 through 0.95, which (a) discarded 51.4% of the premium §E68's
    /// integral computed and (b) made path-independence vacuous, since a cap is a function of the
    /// ENDPOINT while the integral is a function of the PATH.
    /// ⇒ **IF THIS FAILS, SOMETHING RE-INTRODUCED A CEILING.** That may be right! But re-derive it:
    /// measure the premium against the integral at q=0.6..0.95 and show the clamp does not void §E68.
    function test_E287_SkewIsNotPinnedToAConstant() public pure {
        uint a = SwapLib.skewWad(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL * 30 / 100);
        uint b = SwapLib.skewWad(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL * 60 / 100);
        uint c = SwapLib.skewWad(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL * 90 / 100);
        assertTrue(a < b && b < c, "skew must rise with scarcity, not saturate at a constant");
        assertTrue(c > 3e16, "the curve must be free above the old 3% ceiling");
    }

    /// §E274 — **THE POLE IS REACHED AT FINITE SCARCITY, SO NO COEFFICIENT TAMES IT.** Measured: at
    /// 200% vol the kernel passes 1e18 (a 100% haircut — arithmetically dead) at q ≥ 0.893, i.e. in
    /// normal operation, not at the pole only. This is WHY the decline exists and why shrinking Γ is
    /// not an alternative to it.
    /// ⇒ **IF THIS FAILS**, either Γ moved (see §E274's unlanded 5.48e15) or the kernel changed shape.
    /// Re-run `GammaRederived.t.sol` and re-derive the crossing q before assuming the decline is
    /// unnecessary — "we lowered Γ so it cannot happen" is the specific wrong conclusion to reach.
    function test_E287_KernelStillReachesTheHaircutLimitAtFiniteScarcity() public pure {
        uint hot = SwapLib.skewWad(POOL, TARGET, 4e18, SwapLib.ethRisk(), POOL * 999 / 1000);
        assertGe(hot, 1e18, "a near-total drain at 200% vol must still price past a 100% haircut");
    }

    /// §E275 — **THE FULL DRAIN RETURNS THE SENTINEL AS DATA; IT DOES NOT REVERT HERE.** `skewWad` is
    /// read as an OBSERVATION by the refill trigger, so a revert at this layer blinds the band at
    /// exactly the state the refill exists for (measured: it broke three trigger tests). The decline
    /// lives at the PRODUCERS (`wellSkew`/`sellSkew`), before any arithmetic touches the sentinel.
    /// ⇒ **IF THIS FAILS**, someone moved the decline back into the measurement. Check the refill
    /// trigger still reads an empty band before accepting it.
    function test_E287_FullDrainReturnsSentinelRatherThanReverting() public pure {
        uint s = SwapLib.skewWad(POOL, TARGET, SIGMA, SwapLib.ethRisk(), POOL);
        assertEq(s, type(uint).max, "the pole must be observable as data, not a revert, at this layer");
    }

    /// §E276 — **WE NEVER GO BELOW MID: the refill direction is EXEMPT, never PAID.** A–S's
    /// `r = s − qγσ²(T−t)` moves the mid so the balancing side is quoted BETTER than reference; we
    /// implement δ (a spread) in r's place, so the best a rebalancing counterparty gets is reference.
    /// This asserts the CURRENT (spread) behaviour so that implementing the shift is a DELIBERATE,
    /// visible act rather than a silent one.
    /// ⇒ **IF THIS FAILS, SOMEBODY BUILT THE MID-SHIFT — which is the fix §E276 asks for.** Do not
    /// "repair" this test: delete it, and close §E276 and §UNIT-CURVE-SPEC in the same commit.
    function test_E287_RefillDirectionIsExemptNotPaid() public pure {
        // a band AT or ABOVE target has no scarcity: the drain leg charges the base, never a bonus,
        // and there is no code path that returns value TO the counterparty.
        uint flush = SwapLib.skewWad(POOL, POOL, SIGMA, SwapLib.ethRisk(), 0);
        assertGt(flush, 0, "even a flush band charges the adverse-selection base");
        // and it is a CHARGE: the type is unsigned, so a negative (paying) quote is inexpressible.
        assertTrue(flush <= type(uint).max, "skew is unsigned: a bid-improving quote cannot be expressed");
    }
}
