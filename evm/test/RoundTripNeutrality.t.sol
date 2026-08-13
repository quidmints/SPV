// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Alles} from "./Alles.t.sol";
import {LevYbRealProbe} from "./LevYbReal.t.sol";

/// @notice §J.2 PREREQ — the deposit→band→withdraw round-trip CHARACTERISATION.
///
///         WHY THIS EXISTS: §J.2 wants to refactor the vault-share model (Vogue not a 4626; vBTC's
///         ERC-20 face segregated out of Vault). The user's gate is that the collapse/merge must be
///         proven BEHAVIOUR-NEUTRAL on a round-trip FIRST. This file is that baseline: it pins what the
///         round-trip does TODAY so the refactor can be shown to change nothing.
///
///         IT ASSERTS ABSOLUTE VALUES, DELIBERATELY (§A.16d). A relative/round-trip assertion applies
///         the same price on both sides, so it CANCELS a wrong price and passes — that is exactly how a
///         69% share-price under-valuation survived a green 123/0 suite earlier in this session. Every
///         claim here is either an exact identity or a bound derived from live state, never a
///         hardcoded constant (§A.22).
contract RoundTripNeutrality is Alles {

    /// (1) ENTRY IDENTITY — a deposit credits `pooled` 1:1 with assets, and `lpShares` moves by exactly
    ///     that amount. This is the invariant the refactor must not disturb: `pooled` IS the share unit.
    function testRT_EntryIsOneToOne() public {
        uint before  = V4.lpShares();
        vm.prank(User01);
        V4.deposit{value: 10 ether}(0, User01);          // VENUE_GALAXY

        (uint pooled,,,) = V4.autoManaged(User01);
        assertEq(pooled, 10 ether, "deposit credits pooled 1:1 with assets");
        assertEq(V4.lpShares() - before, pooled, "lpShares moves by EXACTLY the credited pooled");
        assertEq(V4.balanceOf(User01), pooled, "balanceOf(user) == that user's pooled");
    }

    /// (2) ROUND-TRIP CONSERVATION — delivered + RETAINED == principal. The retained term is
    ///     load-bearing: `withdraw` delivers what the ETH ladder can source and DEFERS the rest as a
    ///     live claim (§A.11 measured 423.14 delivered + 76.86 retained == exactly 500.00). Asserting
    ///     delivery alone reads that deferral as a loss, which is the mistake §A.9 corrected.
    function testRT_DeliveredPlusRetainedEqualsPrincipal() public {
        uint principal = 10 ether;
        vm.prank(User01);
        V4.deposit{value: principal}(0, User01);
        vm.roll(block.number + 1);                          // JIT-lock: exit must be a later block

        uint e0 = User01.balance + WETH.balanceOf(User01);
        vm.prank(User01); V4.withdraw(type(uint).max, User01, User01);
        uint delivered = (User01.balance + WETH.balanceOf(User01)) - e0;
        (uint retained,,,) = V4.autoManaged(User01);

        // TOLERANCE 1e12 -> 3e15 (0.001 bps -> 3 bps of 10 ETH). NOT a nudge to green: the mechanism is
        // TRACED. The exit runs `Curve.exchange(1, 0, 9.0795e18, ...)` and mints NO wait-NFT, so the
        // principal crosses TWO conversions -- WETH->weETH in, weETH->WETH out -- at ~0.5 bp each.
        // Measured residual 1.03e15 on 1e19 = ~1.03 bps. 1e12 asserted a LOSSLESS round trip, which was
        // only ever true because the old venue split sent a fifth to Galaxy as WETH and never converted
        // it; all-weETH converts the whole principal both ways.
        // ⚠️ THE SPREAD GOES TO THE MARKET, NOT THE PROTOCOL -- `retained` is ~0, so this is a cost, not
        // the RETAINED PRINCIPAL this test exists to catch. That leak measured 0.18% (1.8e16); 3e15 is
        // 6x tighter, so the defect it was written for still fails it by a wide margin.
        assertApproxEqAbs(delivered + retained, principal, 3e15,
            "delivered + retained == principal (deferral is a claim, not a loss)");
    }

    /// (3) THE NEUTRALITY CLAIM ITSELF — one LP's full round-trip must not move ANOTHER LP's claim.
    ///     This is what "behaviour-neutral" has to mean for a share model, and it is the property the
    ///     §J.2 refactor must preserve. Asserted in ABSOLUTE terms: the bystander's redeemable value is
    ///     compared before/after against a tolerance derived from its own size, not a constant.
    function testRT_BystanderClaimUnmovedByAnotherLpRoundTrip() public {
        vm.prank(User02); V4.deposit{value: 10 ether}(0, User02);   // the bystander
        (uint bystanderPooled,,,) = V4.autoManaged(User02);
        uint valueBefore = V4.convertToAssets(bystanderPooled);

        vm.prank(User01); V4.deposit{value: 25 ether}(0, User01);   // the round-tripper
        vm.roll(block.number + 1);
        vm.prank(User01); V4.withdraw(type(uint).max, User01, User01);

        (uint stillPooled,,,) = V4.autoManaged(User02);
        assertEq(stillPooled, bystanderPooled, "a bystander's SHARE COUNT is untouched by another LP");
        assertApproxEqRel(V4.convertToAssets(stillPooled), valueBefore, 0.005e18,
            "a bystander's REDEEMABLE VALUE is untouched by another LP's full round-trip");
    }
}

/// @notice §J.2 PREREQ, part 2 — the share-price identity UNDER LEVERAGE. Split into its own contract
///         because it needs the LevManager wiring, and because the unlevered version of this assertion
///         is BLIND: with no position open, `totalNetEquityEth == 0`, so subtracting it changes nothing
///         and the reverted-separation bug (§A.16d) passes unnoticed. MUTATION-CHECKED against exactly
///         that bug — reintroducing it must turn this RED.
contract RoundTripNeutralityLevered is LevYbRealProbe {

    /// The numerator must read the levered book on the DENOMINATOR's clock: `pricingBacking` =
    /// vogueETH − LIVE totalNetEquityEth + RECORDED totalLevPooled. In sync those two cancel, so the
    /// price is EXACTLY vogueETH/lpShares — and that exact identity is what a separation-style
    /// regression breaks (it produced 0.1886 vs 0.614 when the recorded term was not restored).
    function testRT_SharePriceHoldsWithLeverageOpen() public {
        _setupMorpho();
        ETH.setLevManager(address(rlm));
        _openLp();
        V4.syncLev(LP);

        assertGt(V4.totalLevPooled(), 0, "precondition: a levered slice IS open, else this is blind");
        assertGt(rlm.totalNetEquityEth(), 0, "precondition: live lev net-equity is non-zero");

        // §#12 RE-DERIVED: `_pricingBacking` is no longer `vogueETH` alone — it adds the LP-owned
        // USD leg (the band's USD beyond the basket's contribution) valued at the band's own
        // ratio. With the clocks coincident the LEVERED term still cancels, which is what this
        // test is about; the two-leg term is added here so the identity measures that and not #12.
        uint backing = AUX.vogueETH();
        {   uint usd6 = CORE.POOLED_USD_ETH(); uint base6 = CORE.basketUsdEth();
            // Valued at the ORACLE, matching `_pricingBacking`. The band's leg ratio is NOT a
            // price for a concentrated position -- using it over-valued the increment ~2.2x.
            uint px = AUX.getTWAPforAsset(address(WETH), 1800);
            if (px > 0 && usd6 != base6) {
                if (usd6 > base6) backing += ((usd6 - base6) * 1e12) * 1e18 / px;
                else { uint d = ((base6 - usd6) * 1e12) * 1e18 / px; backing = backing > d ? backing - d : 0; }
            }
        }
        uint expected = 1e18 * backing / V4.lpShares();
        assertEq(V4.convertToAssets(1e18), expected,
            "with the book in sync the price is EXACTLY vogueETH/lpShares (clocks coincide)");
    }
}
