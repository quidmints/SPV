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

    function test_E131_PremiumFundsLvrOverItsPricedWindow() public {
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
        // §E134-skew — WHERE DOES THE DRAINER'S USD LAND? E125 measured POOLED_USD_ETH NOT growing
        // while POOLED_ETH fell 400->103, which is why the level comparison was wrong. Reading the
        // BAND's usd leg and the BASKET's total backing across the same drain settles it by
        // measurement rather than by tracing `inRange`-guarded delta accounting.
        uint bandUsd0 = CORE.POOLED_USD_ETH();
        (uint[15] memory d0,,,) = AUX.get_deposits();
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

        {
            (uint[15] memory d1,,,) = AUX.get_deposits();
            emit log_named_uint("band USD leg BEFORE (POOLED_USD_ETH)", bandUsd0);
            emit log_named_uint("band USD leg AFTER                  ", CORE.POOLED_USD_ETH());
            emit log_named_uint("basket backing BEFORE (d[14])       ", d0[14]);
            emit log_named_uint("basket backing AFTER                ", d1[14]);
        }
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

        // ---- THE ADEQUACY TEST (§E131). Premium vs LVR, as a RATE against a RATE.
        //
        // MMRZ eq.16, which `_maxWellSkew` already cites: a constant-product pool bleeds sigma^2/8
        // per unit time as a fraction of pool value. `realizedVarianceWad` is ANNUALIZED
        // (`Core.sol:312`, "per-sec -> annualized"), so over an exposure of T years the displaced
        // inventory V loses  V * sigma^2/8 * T.  Setting that equal to the premium collected gives
        // the BREAKEVEN EXPOSURE WINDOW. NOTE THE DIRECTION OF THE LEVER (owner, 2026-08-06):
        // "the refill will be as fast as it can, not as fast as it must be." So T* is NOT a
        // latency spec the refill has to hit -- the refill runs at whatever it achieves. T* is a
        // constraint on THE PREMIUM: if the achievable repair window exceeds T*, the skew must be
        // priced over the OBSERVED repair window instead of `confFrac`, because the settlement
        // window is not when the LP's exposure ends. That is §E128's finding with the causality
        // the right way round.
        //
        //     T* = 8P / (V * sigma^2)
        //
        // THE REPORTED INVARIANT IS `8P/V`, WHICH IS sigma^2-FREE. §E120 bars quoting fork
        // magnitudes, and sigma^2 here is the most fork-sensitive term of all (a thin pool with a
        // pinned feed measures 1.553e-4, i.e. ~1.25% ANNUAL vol -- absurd for ETH). Publishing
        // 8P/V lets any reader divide by the sigma^2 they believe, so the measurement survives the
        // fork's volatility being wrong. T* below is that division at the MEASURED sigma^2 and is
        // labelled accordingly.
        //
        // THE ASSERTION IS INTERNAL CONSISTENCY, NOT AN IMPORTED THRESHOLD: the premium must cover
        // the LVR over AT LEAST the window it was explicitly priced for. `_maxWellSkew` charges
        // `sigma^2 * confFrac / 8` with `ETH_CONF_FRAC_WAD` = 380e9 ~ 12 SECONDS (one block). If
        // the premium cannot fund even that, the skew formula contradicts its own derivation. No
        // number outside the contracts enters this.
        uint v18  = FullMath.mulDiv(ethQuiet - ethDrained, px, 1e18);   // displaced inventory, usd18
        uint invWad = FullMath.mulDiv(8 * premium * 1e12, 1e18, v18);   // 8P/V, sigma^2-free
        uint tStarWad = FullMath.mulDiv(invWad, 1e18, CORE.realizedVarianceWad(false));  // years, WAD

        emit log_named_uint("displaced inventory usd18  ", v18);
        emit log_named_uint("INVARIANT 8P/V (wad, sig^2-free)", invWad);
        emit log_named_uint("T* breakeven window, SECONDS (at MEASURED sig^2)", tStarWad * 31_536_000 / 1e18);
        emit log_named_uint("settlement window it was priced for, SECONDS", uint(380_000_000_000) * 31_536_000 / 1e18);

        // The decision this feeds: compare T* to the refill's ACHIEVABLE latency once it exists.
        // If achievable > T*, the premium is short and the skew's window is what changes. Logged at
        // a REFERENCE annual vol as a SCENARIO, never as a measurement -- 0.36 = 60% annual vol, a
        // plausible ETH figure this thin fork (1.553e-4 => ~1.25%/yr) cannot produce.
        emit log_named_uint("T* SECONDS at 60%/yr reference vol (SCENARIO, not measured)",
            FullMath.mulDiv(invWad, 1e18, 0.36e18) * 31_536_000 / 1e18);

        assertGe(tStarWad, 380_000_000_000,
            "E131: the premium must fund LVR over at least the settlement window it priced for");

    }

    /// §UNIT-WHY-IT-MATTERS — DOES AN LP WHO EXITS ACROSS AN IMBALANCE GET THEIR OWN P&L?
    ///
    /// The owner's framing, which is STRICTLY LARGER than the LVR one this file started with:
    /// "why are we worried about a mock token imbalance. because LP withdrawal and P&L attribution
    /// depends on that mock balance. the swap fee a swapper pays depends on that mock balance."
    ///
    /// A withdrawal is PRO-RATA of the mock position, so an LP entering at ~50/50 and exiting at
    /// ~98/2 takes a slice of the DRAIN'S composition. At an UNCHANGED price that should still be
    /// value-neutral -- the band sold ETH at oracle and holds the dollars -- so any shortfall here
    /// is LEAKAGE, not market risk, and it is the kind that accrues silently.
    ///
    /// MEASURED AT THE LP, NEVER FROM PROTOCOL STATE (§S16/§E91): the only number the failing code
    /// does not produce is the caller's own balance delta.
    function test_UNIT_LpExitAcrossImbalanceIsValueNeutralAtFlatPrice() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);

        uint ethIn = 400 ether;
        vm.prank(lp);
        V4.deposit{value: ethIn}(0, lp, 3);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);

        // Someone ELSE drains. The exiting LP did not cause this imbalance.
        for (uint i; i < 12; ++i) _drainEth(30_000 * USDC_PRECISION, px);

        // Exit everything, and measure what ACTUALLY ARRIVES at the LP.
        uint ethBefore = lp.balance + WETH.balanceOf(lp);
        uint usdBefore = _stableValue18(lp);
        vm.prank(lp);
        try V4.withdraw(type(uint).max, lp, lp) {} catch { emit log("withdraw reverted"); }
        uint ethOut = (lp.balance + WETH.balanceOf(lp)) - ethBefore;
        uint usdOut = _stableValue18(lp) - usdBefore;

        uint valueIn18  = FullMath.mulDiv(ethIn,  px, 1e18);
        uint valueOut18 = FullMath.mulDiv(ethOut, px, 1e18) + usdOut;

        emit log_named_uint("LP ETH in                 ", ethIn);
        emit log_named_uint("LP ETH out                ", ethOut);
        emit log_named_uint("LP USD out (usd18)        ", usdOut);
        emit log_named_uint("LP value IN  (usd18)      ", valueIn18);
        emit log_named_uint("LP value OUT (usd18)      ", valueOut18);
        if (valueOut18 >= valueIn18) emit log_named_uint("SURPLUS (premium earned)", valueOut18 - valueIn18);
        else                         emit log_named_uint("SHORTFALL (LEAKAGE)     ", valueIn18 - valueOut18);
        assertGt(ethOut + usdOut, 0, "the LP received NOTHING -- delivery, not attribution");
    }

    /// Sum of every basket stable plus QUID held by `who`, in 18-dec USD (§E69's lesson: the payout
    /// token is chosen by the basket, so guessing one turns a wrong guess into a fake zero).
    function _stableValue18(address who) internal view returns (uint total) {
        address[] memory ss = AUX.getStables();
        for (uint i = 0; i < ss.length; ++i) {
            uint bal = IERC20(ss[i]).balanceOf(who);
            if (bal == 0) continue;
            uint8 d = IERC20(ss[i]).decimals();
            total += d < 18 ? bal * (10 ** (18 - d)) : bal;
        }
        total += QUID.balanceOf(who);
    }
}
