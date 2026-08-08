// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

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
/// ⚠️ THE PREMIUM COUNTER IS **usd6**, AND THIS TEST'S FIRST ASSERTION WAS DIMENSIONALLY WRONG
/// BECAUSE OF IT. `SwapLib.retainSkewPremium:1629` records `premium` unconverted on the two drain
/// legs ("the BUY-DRIVING USD, already 6-dec") and `mulDiv(premium, r.px, 1e30)` on the native
/// sell leg — both land in 6 decimals. So 428,780 is **$0.43**, not the 4e-13 an 18-dec reading
/// gives. The original `assertLt(premium, foregone)` compared usd6 against u18 and was therefore
/// **biased 1e12 TOWARD PASSING — toward this file's own hypothesis.** It passed honestly only
/// because the premium is genuinely small. `premium18` below is the fix; the comparison is now
/// dimensionally sound and would FAIL if the premium ever did cover the exposure.
///
/// §E120 still bars quoting the magnitude as a protocol property — the fork cannot support it.
/// THE SIGN IS WHAT THIS TEST OWNS: holding an imbalance does not out-earn the exposure it creates.
contract PremiumIsCarryNotIncome is Alles {
    address lp = User02;
    address drainer = address(0xBEEF04);
    address bold;

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
        // ONLY THE ETH COUNT IS NEEDED NOW. Two earlier drafts marked the whole band's VALUE here
        // (`POOLED_ETH*px + POOLED_USD_ETH`) and both were wrong for it: the level form measured
        // the drain itself because `POOLED_USD_ETH` never absorbed the drainer's stables, and the
        // sensitivity form needed a hand-picked move. The breakeven-vs-variance assertion below
        // needs neither, so the band-value helper is gone rather than left around to be misused.
        uint ethQuiet = CORE.POOLED_ETH();

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
        // THE PRICER'S OWN VOLATILITY INPUT. If this sits at the E88-r sentinel (1 wei) the premium
        // was quoted for a market that will NOT move, and comparing it to a 10% move is arithmetic,
        // not a measurement. Logged so the regime is visible in the same run as the result.
        emit log_named_uint("realizedVarianceWad at settle", CORE.realizedVarianceWad(false));
        emit log_named_uint("wellSkew at settle           ", AUX.wellSkew(address(WETH)));
        // §E130-skew — θ IS LOGGED AS CONTEXT AND MUST NOT BE ASSERTED ON HERE. It is an
        // IL-PROTECTION CONTROL (band sizing), not a verdict on skew pricing, and using it as one
        // is CIRCULAR: θ is DERIVED FROM the retained premium (`premiumEwmaUsd` is its numerator)
        // and then used to CLAMP band exposure (`applyTheta`). A small premium ⇒ small θ ⇒ the
        // protocol shrinks exposure — that is IL protection WORKING, so reading θ back as "the
        // premium is inadequate" uses the system's own RESPONSE to the premium as evidence ABOUT
        // it. §E129 briefly claimed adequacy was "one call to derivedThetaWad"; that is withdrawn.
        emit log_named_uint("derivedThetaWad (1e18 = fees COVER IL)", V4.derivedThetaWad(false));
        emit log_named_uint("premiumEwmaUsd (rate, usd6)  ", CORE.premiumEwmaUsd(false));
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

        // ---- THE COMPARISON, WITH THE MOVE SIZE TAKEN FROM THE PRICER, NOT FROM ME.
        //
        // Two earlier forms were wrong. A LEVEL comparison of the two bands passed for the wrong
        // reason: the 626,040 gap was just the 296.4 ETH that LEFT times the move, because
        // `POOLED_USD_ETH` never absorbed the drainer's stables -- it compared a 400-ETH band to a
        // 103-ETH band and called the difference inventory risk. A SENSITIVITY comparison at a
        // hand-picked +10% fixed that, but 10% is 8 SIGMA here (measured sigma^2 = 1.553e-4, so
        // sigma ~ 1.25%): it quoted a premium for a 1.25%-vol market and demanded it cover an 8x
        // excursion. A premium failing THAT is arithmetic, not a measurement.
        //
        // So: derive the BREAKEVEN MOVE -- the fractional price move at which the premium is
        // exactly exhausted by the foregone upside on the ETH the band no longer holds --
        //     breakeven = premium / (missingEth * px)
        // and compare it to the volatility the premium was ACTUALLY priced from. Comparing in
        // VARIANCE space keeps this exact and needs no square root:
        //     breakeven^2  <  realizedVarianceWad     <=>     breakeven < sigma
        // If the premium cannot survive a ONE-SIGMA move by its own volatility input, it is carry
        // for a risk that exceeds it. No chosen constant enters the assertion.
        uint premium18  = premium * 1e12;   // usd6 -> u18; see the header on the 1e12 bias
        uint missingEth = ethQuiet - ethDrained;
        uint breakevenWad = FullMath.mulDiv(premium18, 1e18, FullMath.mulDiv(missingEth, px, 1e18));
        uint breakevenSqWad = FullMath.mulDiv(breakevenWad, breakevenWad, 1e18);
        uint varWad = CORE.realizedVarianceWad(false);

        emit log_named_uint("missing ETH                ", missingEth);
        emit log_named_uint("premium u18 (=usd6*1e12)   ", premium18);
        emit log_named_uint("BREAKEVEN move (wad)       ", breakevenWad);
        emit log_named_uint("realizedVarianceWad (sig^2)", varWad);
        emit log_named_uint("breakeven^2 (wad)          ", breakevenSqWad);

        if (breakevenSqWad >= varWad) {
            emit log("RESULT: the premium SURVIVES a one-sigma move -- it is farmable income.");
            emit log("=> E123 IS REFUTED; E122's consequence 2 must be reinstated.");
        } else {
            emit log("RESULT: the premium is exhausted well INSIDE one sigma. Carry, not income.");
        }

        assertLt(breakevenSqWad, varWad,
            "E123: premium must NOT survive a one-sigma move by its own variance input");
    }
}
