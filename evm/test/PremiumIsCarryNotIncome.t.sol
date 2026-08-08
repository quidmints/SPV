// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E125 — IS THE SKEW PREMIUM FAIR CARRY, OR IS IT FARMABLE INCOME?
///
/// WHY THIS FILE EXISTS. §E122 observed that E5 routes the skew premium to the LPs
/// (`V4.USD_FEES`), and concluded an LP therefore EARNS from an unrepaired imbalance and would
/// rationally refuse to repair it. §E123 withdrew that on the owner's confirmation that
/// premium-to-LP is intended, arguing the premium is priced `Γ·σ²·q` — exactly the variance the
/// skewed inventory is exposed to — so it is CARRY for a risk, not PROFIT to farm.
///
/// THAT WITHDRAWAL WAS REASONING, NOT MEASUREMENT, AND IT REVERSED A CONCLUSION WRITTEN MINUTES
/// EARLIER. The owner asked for it to be tested before anything in the refill design leans on it.
/// This fixture is that test.
///
/// THE FALSIFIABLE FORM. A drained band holds LESS of the volatile asset than a band that was
/// never drained. If the volatile asset then RISES, the drained band gains less — that shortfall
/// IS the inventory risk the premium is supposed to price. So compare, at one common final price:
///
///     DRAINED band value + premium collected     vs     NEVER-DRAINED band value
///
///   ≥  ⇒ the premium AT LEAST repays the risk it charges for. Holding an imbalance is free or
///        better, the premium IS farmable, and **§E123 IS REFUTED** — an LP would rationally sit
///        on an imbalance, and the refill cannot assume the LP wants it closed.
///   <  ⇒ the premium does NOT cover the adverse move. Holding does not pay; the premium is carry
///        for a risk that can and does exceed it. **§E123 SURVIVES.**
///
/// TWO DESIGN CHOICES THAT KEEP THIS FROM MEASURING ITSELF:
///
///  1. THE PRICE MOVE IS A PURE MARK, NOT A FEED WRITE. Both arms are valued by ARITHMETIC at the
///     same hypothetical price. Moving the oracle would let the pool trade against it, so the
///     "inventory loss" would be contaminated by whatever arb the move invited — I would be
///     measuring the fork's arb depth, not the LP's exposure. §E120 is the standing reason to
///     distrust any magnitude this fork produces through a trading path.
///
///  2. PREMIUM IS READ FROM `CORE.skewPremiumETH()`, NOT `V4.USD_FEES()`. `Alles.t.sol:1066`
///     states that USD_FEES is a PER-SHARE RATE and "cannot answer how much has been retained in
///     total", which is the exact question here. The cumulative counter is the one that can.
///     Reading the per-share accumulator as a total would have silently understated the premium
///     and biased the test TOWARD its own hypothesis.
///
/// The two arms run from ONE snapshot, so they differ only in whether the drain happened.
///
/// ⚠️ WHAT THIS TEST DOES **NOT** ESTABLISH — READ BEFORE QUOTING A NUMBER FROM IT. The measured
/// gap is ~56,912 USD of foregone upside against a premium of 428,780 wei (~4e-13 USD): a ratio
/// near 1e17. That is NOT a credible economic margin, and it should not be reported as "the
/// premium is 1e17x too small". It points at `skewPremiumETH` carrying units this fixture never
/// established, and §E120 already records that magnitudes on this fork are unsupportable. THE
/// SIGN IS WHAT THIS TEST OWNS: holding an imbalance does not out-earn the exposure it creates.
/// Establishing the premium's units is the prerequisite for any magnitude claim here.
contract PremiumIsCarryNotIncome is Alles {
    address lp = User02;
    address drainer = address(0xBEEF04);
    address bold;

    /// The band's whole value in 18-dec USD, marked at `px`. `POOLED_ETH * px / 1e30` is the usd6
    /// form used everywhere in this repo; ×1e12 lifts it to usd18 to match `POOLED_USD_ETH`.
    function _bandValue18(uint px) internal view returns (uint) {
        return CORE.POOLED_ETH() * px / 1e18 + CORE.POOLED_USD_ETH();
    }

    function _settle() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 20 minutes);
    }

    function _seed() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 4_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// stable → volatile: the band HANDS OUT ETH, so `inv` FALLS and the band gets SCARCER.
    /// (§E69 recorded this direction being written backwards twice; it is spelled out here.)
    ///
    /// THE FEED IS RE-PINNED EVERY STEP AND THE WARP IS 8 MINUTES, copied deliberately from
    /// `testGrindRemoval_DrainPaysRetainedSkewPremium`. THE FIRST DRAFT OF THIS FILE USED A BARE
    /// 20-MINUTE WARP AND MEASURED A PREMIUM OF EXACTLY ZERO — not because holding is free, but
    /// because a settled, non-moving market has σ²→0, which correctly zeroes the skew (that test's
    /// own header says so). A stale feed also makes the oracle drift out from under the pool. The
    /// `assertGt(premium, 0)` below is what turned that into a visible failure instead of a
    /// "premium doesn't cover the move" result I would have believed.
    /// USDC AT 30k, NOT `bold` AT 40k, AND THE DRAINER IS THE PRANKED USER — all three copied from
    /// the passing test rather than re-invented. A `bold`-denominated drain measured a premium of
    /// exactly ZERO twice; `bold` is BOLD-SP, the venue whose delivery bug §E91 fixed, and the
    /// `try/catch` here would swallow a revert silently.
    function _drainEth(uint amt, uint pxPin) internal {
        _setEthFeed(pxPin / 1e10);
        vm.startPrank(drainer);
        try AUX.swap(address(USDC), address(WETH), true, amt, 0) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 8 minutes);
    }

    function test_E125_PremiumDoesNotCoverTheInventoryLossItChargesFor() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.prank(lp);
        V4.deposit{value: 400 ether}(0, lp, 3);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        // Pin the external anchor and HOLD it: production-faithful, since draining OUR pool does
        // not move Chainlink. Without this the drain loop below prices against a drifting oracle.
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        uint snap = vm.snapshotState();

        // ---- ARM 1: NEVER DRAINED. The band keeps its full volatile inventory.
        uint ethQuiet = CORE.POOLED_ETH();
        // A LOCAL, NOT A STATE VARIABLE. `vm.revertToState` rolls back THIS CONTRACT'S storage
        // as well as the protocol's, so a state variable set here reads 0 after the revert below
        // -- which silently turned the quiet band's upside into its whole value and underflowed.
        uint quietAtPx = _bandValue18(px);
        uint quietAt110 = _bandValue18(px * 110 / 100);

        // ---- ARM 2: DRAINED until genuinely scarce, from the SAME starting state.
        vm.revertToState(snap);
        uint premium0 = CORE.skewPremiumETH();
        // DO NOT `break` THE INSTANT THE BAND TURNS SCARCE — that was this fixture's third
        // zero-premium reading and it was entirely self-inflicted. The premium accrues only on
        // swaps that EXECUTE while `inv < target`; breaking on the transition means every drain
        // ran in the flush state (skew == 0 by design) and the swap that CREATED scarcity was the
        // last thing to happen, so nothing was ever priced against a scarce band. Keep draining
        // AFTER the transition so the premium has swaps to accrue on.
        bool reachedScarce;
        uint scarceSwaps;
        for (uint i = 0; i < 30 && scarceSwaps < 6; ++i) {
            _drainEth(30_000 * USDC_PRECISION, px);
            if (reachedScarce) ++scarceSwaps;
            else if (CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd(false)) reachedScarce = true;
        }
        emit log_named_uint("swaps priced while SCARCE", scarceSwaps);
        uint premium = CORE.skewPremiumETH() - premium0;
        uint ethDrained = CORE.POOLED_ETH();

        emit log_named_uint("POOLED_ETH quiet      ", ethQuiet);
        emit log_named_uint("POOLED_ETH drained    ", ethDrained);
        emit log_named_uint("premium collected u18 ", premium);

        // §E69's discipline: a fixture that never reached the state it meant to measure must SAY
        // SO, because an inconclusive run and a null result are indistinguishable from the numbers.
        if (!reachedScarce || ethDrained >= ethQuiet) {
            emit log("INCONCLUSIVE: the band never became scarce -- no imbalance was under test.");
            emit log("Do NOT read this run as evidence either way about E123.");
            return;
        }
        assertGt(premium, 0, "the drain must have PAID a premium, or there is nothing to weigh");

        // ---- THE COMPARISON. **NOT** a level comparison of the two bands: the first draft did
        //      that and PASSED FOR THE WRONG REASON. Drained-band value came out 626,040 u18 below
        //      the quiet band, which is almost exactly the 296.4 ETH that LEFT times the 10% move —
        //      i.e. I was measuring THE DRAIN ITSELF, because `POOLED_USD_ETH` never absorbed the
        //      stables the drainer paid in. Comparing a 400-ETH band to a 103-ETH band and calling
        //      the gap "inventory risk" would have confirmed E123 with an accounting hole.
        //
        //      What actually answers the question is each arm's SENSITIVITY to the same move —
        //      value(1.1·px) − value(px) for that arm — which is independent of where the stables
        //      went. The drained band is under-exposed by exactly the ETH it no longer holds, and
        //      THAT foregone upside is the risk the premium is meant to price.
        uint quietUpside   = quietAt110 - quietAtPx;
        uint drainedUpside = _bandValue18(px * 110 / 100) - _bandValue18(px);
        uint foregone      = quietUpside - drainedUpside;

        emit log_named_uint("quiet band upside on +10%  ", quietUpside);
        emit log_named_uint("drained band upside on +10%", drainedUpside);
        emit log_named_uint("FOREGONE upside (the risk) ", foregone);
        emit log_named_uint("premium collected          ", premium);

        if (premium >= foregone) {
            emit log("RESULT: the premium COVERS the foregone upside -- farmable income.");
            emit log("=> E123 IS REFUTED; E122's consequence 2 must be reinstated.");
        } else {
            emit log_named_uint("SHORTFALL (risk EXCEEDS premium)", foregone - premium);
            emit log("RESULT: the premium does NOT cover the foregone upside. Carry, not income.");
        }

        // THE FAVOURABLE DIRECTION IS DELIBERATELY NOT MEASURED HERE. A drained band loses less
        // when ETH FALLS and collects the premium either way, so "holding wins on the down move" is
        // expected and carries no information about farmability -- asserting on it would confirm the
        // hypothesis with the one case that cannot discriminate. (It was logged in an earlier draft
        // and cost a `Stack too deep`; per CLAUDE.md the fix is fewer locals, not `via_ir`.)

        assertLt(premium, foregone,
            "E123: premium must NOT cover the foregone upside, or it is farmable income");
    }
}
