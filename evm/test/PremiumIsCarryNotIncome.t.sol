// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

/// §E125 — IS THE SKEW PREMIUM FAIR CARRY, OR IS IT FARMABLE INCOME?
///
/// WHY THIS FILE EXISTS. §E122 observed that E5 routes the skew premium to the LPs
/// (`ETH.USD_FEES`), and concluded an LP therefore EARNS from an unrepaired imbalance and would
/// rationally refuse to repair it. §E123 withdrew that on the owner's confirmation that
/// premium-to-LP is intended, arguing the premium is priced `Γ·σ²·q` — exactly the variance the
/// skewed inventory is exposed to — so it is CARRY for a risk, not PROFIT to farm.
///
/// THAT WITHDRAWAL WAS REASONING, NOT MEASUREMENT, AND IT REVERSED A CONCLUSION WRITTEN MINUTES
/// EARLIER. The owner asked for it to be tested before anything in the refill design leans on it.
/// This fixture is that test.
///
/// THE FALSIFIABLE FORM. A drained range holds LESS of the volatile asset than a range that was
/// never drained. If the volatile asset then RISES, the drained range gains less — that shortfall
/// IS the inventory risk the premium is supposed to price. So compare, at one common final price:
///
///     DRAINED range value + premium collected     vs     NEVER-DRAINED range value
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
///  2. PREMIUM IS READ FROM `CORE.skewPremium()`, NOT `ETH.USD_FEES()`. `Alles.t.sol:1066`
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
contract PremiumIsCarryNotIncome is AllesFixture {
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

    /// stable → volatile: the range HANDS OUT BTC, so `inv` FALLS and the range gets SCARCER.
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
        try AUX.swap(address(USDC), address(WETH), true, amt, 0, true) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 8 minutes);
    }

    function test_E131_PremiumFundsLvrOverItsPricedWindow() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.prank(lp);
        ETH.deposit{value: 400 ether}(0, lp);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        // Pin the external anchor and HOLD it: production-faithful, since draining OUR pool does
        // not move Chainlink. Without this the drain loop below prices against a drifting oracle.
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        uint snap = vm.snapshotState();

        // ---- ARM 1: NEVER DRAINED. The range keeps its full volatile inventory.
        // ONLY THE ETH COUNT IS NEEDED NOW. Two earlier drafts marked the whole range's VALUE here
        // (`POOLED*px + POOLED_USD`) and both were wrong for it: the level form measured
        // the drain itself because `POOLED_USD` never absorbed the drainer's stables, and the
        // sensitivity form needed a hand-picked move. The breakeven-vs-variance assertion below
        // needs neither, so the range-value helper is gone rather than left around to be misused.
        uint ethQuiet = CORE.POOLED();

        // ---- ARM 2: DRAINED until genuinely scarce, from the SAME starting state.
        vm.revertToState(snap);
        uint premium0 = CORE.skewPremium();
        // §E134-skew — WHERE DOES THE DRAINER'S USD LAND? E125 measured POOLED_USD NOT growing
        // while POOLED fell 400->103, which is why the level comparison was wrong. Reading the
        // RANGE's usd leg and the BASKET's total backing across the same drain settles it by
        // measurement rather than by tracing `inRange`-guarded delta accounting.
        uint rangeUsd0 = CORE.POOLED_USD();
        (uint[15] memory d0,,,) = AUX.get_deposits();
        // DO NOT `break` THE INSTANT THE RANGE TURNS SCARCE — that was this fixture's third
        // zero-premium reading and it was entirely self-inflicted. The premium accrues only on
        // swaps that EXECUTE while `inv < target`; breaking on the transition means every drain
        // ran in the flush state (skew == 0 by design) and the swap that CREATED scarcity was the
        // last thing to happen, so nothing was ever priced against a scarce range. Keep draining
        // AFTER the transition so the premium has swaps to accrue on.
        bool reachedScarce;
        uint scarceSwaps;
        for (uint i = 0; i < 30 && scarceSwaps < 6; ++i) {
            _drainEth(30_000 * USDC_PRECISION, px);
            if (reachedScarce) ++scarceSwaps;
            else if (CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd()) reachedScarce = true;
        }
        emit log_named_uint("swaps priced while SCARCE", scarceSwaps);
        // THE PRICER'S OWN VOLATILITY INPUT. If this sits at the E88-r sentinel (1 wei) the premium
        // was quoted for a market that will NOT move, and comparing it to a 10% move is arithmetic,
        // not a measurement. Logged so the regime is visible in the same run as the result.
        emit log_named_uint("realizedVarianceWad at settle", CORE.realizedVarianceWad());
        emit log_named_uint("wellSkew at settle           ", AUX.wellSkew(address(WETH), 0));
        // §E130-skew — θ IS LOGGED AS CONTEXT AND MUST NOT BE ASSERTED ON HERE. It is an
        // IL-PROTECTION CONTROL (range sizing), not a verdict on skew pricing, and using it as one
        // is CIRCULAR: θ is DERIVED FROM the retained premium (`premiumEwmaUsd` is its numerator)
        // and then used to CLAMP range exposure (`applyTheta`). A small premium ⇒ small θ ⇒ the
        // protocol shrinks exposure — that is IL protection WORKING, so reading θ back as "the
        // premium is inadequate" uses the system's own RESPONSE to the premium as evidence ABOUT
        // it. §E129 briefly claimed adequacy was "one call to derivedThetaWad"; that is withdrawn.
        emit log_named_uint("derivedThetaWad (1e18 = fees COVER IL)", ETH.derivedThetaWad());
        emit log_named_uint("premiumEwmaUsd (rate, usd6)  ", CORE.premiumEwmaUsd());
        uint premium = CORE.skewPremium() - premium0;
        uint ethDrained = CORE.POOLED();

        {
            (uint[15] memory d1,,,) = AUX.get_deposits();
            emit log_named_uint("range USD leg BEFORE (POOLED_USD)", rangeUsd0);
            emit log_named_uint("range USD leg AFTER                  ", CORE.POOLED_USD());
            emit log_named_uint("basket backing BEFORE (d[14])       ", d0[14]);
            emit log_named_uint("basket backing AFTER                ", d1[14]);
        }
        emit log_named_uint("POOLED quiet      ", ethQuiet);
        emit log_named_uint("POOLED drained    ", ethDrained);
        emit log_named_uint("premium collected u18 ", premium);

        // §E69's discipline: a fixture that never reached the state it meant to measure must SAY
        // SO, because an inconclusive run and a null result are indistinguishable from the numbers.
        if (!reachedScarce || ethDrained >= ethQuiet) {
            emit log("INCONCLUSIVE: the range never became scarce -- no imbalance was under test.");
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
        // pinned feed measures 1.553e-4, i.e. ~1.25% ANNUAL vol -- absurd for BTC). Publishing
        // 8P/V lets any reader divide by the sigma^2 they believe, so the measurement survives the
        // fork's volatility being wrong. T* below is that division at the MEASURED sigma^2 and is
        // labelled accordingly.
        //
        // THE ASSERTION IS INTERNAL CONSISTENCY, NOT AN IMPORTED THRESHOLD: the premium must cover
        // the LVR over AT LEAST the window it was explicitly priced for. `_maxWellSkew` charges
        // `sigma^2 * confFrac / 8` with `ETH_CONF_FRAC_WAD` = 380e9 ~ 12 SECONDS (one block). If
        // the premium cannot fund even that, the skew formula contradicts its own derivation. No
        // number outside the contracts enters this.
        uint v18  = SoladyMath.fullMulDiv(ethQuiet - ethDrained, px, 1e18);   // displaced inventory, usd18
        uint invWad = SoladyMath.fullMulDiv(8 * premium * 1e12, 1e18, v18);   // 8P/V, sigma^2-free
        uint tStarWad = SoladyMath.fullMulDiv(invWad, 1e18, CORE.realizedVarianceWad());  // years, WAD

        emit log_named_uint("displaced inventory usd18  ", v18);
        emit log_named_uint("INVARIANT 8P/V (wad, sig^2-free)", invWad);
        emit log_named_uint("T* breakeven window, SECONDS (at MEASURED sig^2)", tStarWad * 31_536_000 / 1e18);
        emit log_named_uint("settlement window it was priced for, SECONDS", uint(380_000_000_000) * 31_536_000 / 1e18);

        // The decision this feeds: compare T* to the refill's ACHIEVABLE latency once it exists.
        // If achievable > T*, the premium is short and the skew's window is what changes. Logged at
        // a REFERENCE annual vol as a SCENARIO, never as a measurement -- 0.36 = 60% annual vol, a
        // plausible ETH figure this thin fork (1.553e-4 => ~1.25%/yr) cannot produce.
        emit log_named_uint("T* SECONDS at 60%/yr reference vol (SCENARIO, not measured)",
            SoladyMath.fullMulDiv(invWad, 1e18, 0.36e18) * 31_536_000 / 1e18);

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
    /// value-neutral -- the range sold ETH at oracle and holds the dollars -- so any shortfall here
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
        ETH.deposit{value: ethIn}(0, lp);
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
        try ETH.withdraw(type(uint).max, lp, lp) {} catch { emit log("withdraw reverted"); }
        uint ethOut = (lp.balance + WETH.balanceOf(lp)) - ethBefore;
        uint usdOut = _stableValue18(lp) - usdBefore;

        uint valueIn18  = SoladyMath.fullMulDiv(ethIn,  px, 1e18);
        uint valueOut18 = SoladyMath.fullMulDiv(ethOut, px, 1e18) + usdOut;

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

    /// §UNIT-B-VERIFIED — RECONCILE WHAT THE PROTOCOL *RECORDS* RETAINING AGAINST WHAT THE SWAPPER
    /// *ACTUALLY PAYS*. The event trace showed a ~1000x disagreement between the premium counter
    /// and E71's trader-side gap; E5 routes the RECORDED number to LPs via USD_FEES, so if the
    /// record overstates, LPs are credited value no swapper paid. All three read in ONE run:
    ///   (a) the swapper's own balance deltas  (the only number the failing code does not produce)
    ///   (b) the skewPremiumCum delta          (what we say we retained)
    ///   (c) the USD_FEES delta                (what reached LPs)
    function test_UNIT_PremiumRecordedEqualsPremiumPaid() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.prank(lp); ETH.deposit{value: 400 ether}(0, lp);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        // Drive into priced scarcity first: a flush-regime swap charges 0 and reconciles trivially.
        for (uint i; i < 14; ++i) _drainEth(30_000 * USDC_PRECISION, px);

        uint prem0 = CORE.skewPremiumCum();
        uint fees0 = ETH.USD_FEES();
        uint usdc0 = USDC.balanceOf(drainer);
        uint eth0  = drainer.balance + WETH.balanceOf(drainer);

        _drainEth(30_000 * USDC_PRECISION, px);

        uint usdcIn  = usdc0 - USDC.balanceOf(drainer);
        uint ethOut  = (drainer.balance + WETH.balanceOf(drainer)) - eth0;
        uint premium = CORE.skewPremiumCum() - prem0;   // usd6
        uint feesDlt = ETH.USD_FEES() - fees0;

        // What the swapper ACTUALLY gave up vs an oracle fill of the same input, in usd6.
        uint fairEth = SoladyMath.fullMulDiv(usdcIn * 1e12, 1e18, px);   // usd18 input / px -> ETH wei
        uint paidUsd6 = fairEth > ethOut ? SoladyMath.fullMulDiv(fairEth - ethOut, px, 1e30) : 0;

        emit log_named_uint("swapper USDC in (6d)        ", usdcIn);
        emit log_named_uint("swapper ETH out (wei)       ", ethOut);
        emit log_named_uint("oracle-fair ETH (wei)       ", fairEth);
        emit log_named_uint("(a) haircut BORNE by swapper, usd6", paidUsd6);
        emit log_named_uint("(b) skewPremiumCum delta,    usd6", premium);
        emit log_named_uint("(c) USD_FEES delta               ", feesDlt);
        if (premium > 0) {
            uint ratio = paidUsd6 * 10_000 / premium;
            emit log_named_uint("borne/recorded (bps, 10000 = exact)", ratio);
        }
        assertGt(premium, 0, "no premium charged -- fixture never reached priced scarcity");
    }

    /// §UNIT-A-DECIDED — A FIXTURE THAT PRODUCES REALISTIC VARIANCE, WHICH NONE OF MINE DID.
    ///
    /// Every measurement in this file ran at sigma^2 = 1.553e-4, i.e. ~1.25% ANNUALISED vol for
    /// ETH against a real ~60% — about 2,300x low in variance terms. The cause was my own
    /// construction: `_drainEth` RE-PINS the feed every step, so the observation ring recorded a
    /// pool that barely moved. The ring only advances ON A SWAP and `observe` INTERPOLATES between
    /// stored points, so a moving tape needs swaps AT MOVING PRICES -- not a pinned feed with
    /// swaps against it.
    ///
    /// This walks the oracle in ~0.3% steps 8 minutes apart (a plausible tape) and swaps at each,
    /// then reports what the ring actually measures. It ASSERTS the result lands in a plausible
    /// range, so a dead-tape run reports INCONCLUSIVE instead of confidently wrong -- the guard
    /// every earlier fixture in this file lacked.
    function test_UNIT_FixtureProducesRealisticVariance() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.deal(drainer, 600 ether);
        vm.prank(lp); ETH.deposit{value: 400 ether}(0, lp);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        emit log_named_uint("sigma^2 BEFORE the walk", CORE.realizedVarianceWad());
        emit log_named_uint("frame lower price BEFORE      ", _bLo(address(ETH)));

        // §UNIT-A-FIXTURE-CORR — DRIVE THE POOL'S TICK, NOT THE FEED, AND WITH SIZE.
        // `ringVariance` reads `tickCumulative` off the POOL's ring and takes the variance of
        // consecutive RATE CHANGES. The previous draft moved the ORACLE 24 times with 4,000 USDC
        // swaps: far too small to traverse a +/-0.2% range or force a reseat, so tickCumulative
        // advanced at a NEARLY CONSTANT rate and the variance of near-constant returns is ~0.
        // Sizing, not spacing -- the estimator is spacing-immune by construction (each return is
        // normalised by its own elapsed time).
        // ALTERNATING large buys and sells is what makes consecutive rates DIFFER: a one-way ramp
        // moves the tick at a steady rate, which is also low variance.
        // ATTEMPT 3: bigger excursions AND uneven step sizes. `ringVariance` takes the variance of
        // consecutive RATE CHANGES, so a metronome -- same size, same interval -- produces a nearly
        // CONSTANT rate and therefore near-zero variance no matter how large the swaps are. Attempt
        // 2 got 370 bps precisely because it was regular. Real tape is uneven in BOTH size and
        // spacing, so vary both.
        uint landed; uint reverted;
        uint p = px;
        // FREQUENCY, NOT AMPLITUDE. Measured: 0.6% -> 556 bps, 1.0% -> 545 bps (NO change), 1.8% ->
        // 28,069 bps. `ringVariance` is BIMODAL -- below the reseat threshold amplitude is
        // irrelevant, above it reseats dominate -- so the target range is stepped OVER, never hit,
        // by scaling amplitude. The lever is HOW OFTEN the walk CROSSES the range edge: two large
        // (crossing) steps in eight, six small (non-crossing) ones.
        uint16[8] memory mult = [uint16(1018), 997, 1002, 1004, 985, 1001, 1003, 998];
        uint16[8] memory size = [uint16(40), 150, 25, 90, 200, 60, 15, 120];            // uneven size
        for (uint i; i < 24; ++i) {
            p = p * mult[i % 8] / 1000;
            _setEthFeed(p / 1e10);
            // §UNIT-VOL-CONTROL / §UNIT-FORK-PINNED — THE LANDED SEQUENCE IS THE ONLY THING THAT
            // MOVES σ², AND `try/catch` MADE IT INVISIBLE. Three walks produced two identical σ²
            // values and one different, which is only explicable by WHICH swaps cleared the
            // TWAP-deviation guards. Count them, so the workload is observable rather than inferred.
            vm.startPrank(drainer);
            if (i % 3 != 1) {
                try AUX.swap(address(USDC), address(WETH), true, uint(size[i % 8]) * 1_000 * USDC_PRECISION, 0, true) { ++landed; }
                catch { ++reverted; }
            } else {
                try AUX.swap{value: uint(size[i % 8]) * 4e17}(address(USDC), address(WETH), false, 0, 0, true) { ++landed; }
                catch { ++reverted; }
            }
            vm.stopPrank();
            // §UNIT-VOL-LANDED — MEASURE THE CHANNEL INSTEAD OF THEORISING ABOUT IT. Three
            // explanations for the sigma^2 spread have now been refuted. The only surviving one is
            // that the range executes against a TWAP rather than the spot feed being poked, so log
            // BOTH: what we SET, and what the venue actually PRICES against.
            if (i % 6 == 0) {
                emit log_named_uint("  step", i);
                emit log_named_uint("   feed SET to        ", p);
                emit log_named_uint("   TWAP the venue uses", AUX.getTWAPforAsset(address(WETH), 1800));
            }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + (i % 5 + 1) * 90);   // uneven spacing, 1.5-7.5 min
        }

        // §UNIT-TWAP-RESOLVE — COUNT THE RESEATS. In this architecture the pool tick moves mainly
        // when the range RESEATS onto a new oracle level (oracle-pegged fills consume inventory
        // without walking the curve), so the reseat count IS the variance driver. +/-1.8% feed
        // moves are 9x the range half-width and should force reseats; measure whether they do.
        emit log_named_uint("frame lower price AFTER the walk", _bLo(address(ETH)));
        emit log_named_uint("swaps LANDED  ", landed);
        emit log_named_uint("swaps REVERTED", reverted);
        uint varWad = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 AFTER the walk  ", varWad);
        emit log_named_uint("implied annualised vol, bps (sqrt of the above)", _sqrtBps(varWad));
        emit log_named_uint("wellSkew at this vol    ", AUX.wellSkew(address(WETH), 0));

        // ~0.2-1.2 annualised variance brackets a plausible ETH tape (45%-110% vol). Outside that,
        // the tape is the finding, not the pricing -- say so rather than quoting a number from it.
        // §E69's discipline: report INCONCLUSIVE, do not fail red -- the fixture is a work in
        // progress and a red test would read as a protocol defect. MEASURED HERE: 36 bps annualised
        // even while walking the ORACLE +/-0.3% every 8 minutes, i.e. LOWER than the pinned-feed
        // runs. CAUSE, and it is in E59's own comment which I read this morning and did not apply:
        // `realizedVarianceWad` samples `observe` on a WALL-CLOCK grid, the ring only advances ON A
        // SWAP, and `observe` LINEARLY INTERPOLATES between stored points -- so a swap spacing
        // COARSER than the sampling grid flattens the tape to a straight line. The variance is not
        // low because the market is calm; it is low because we are sampling a line drawn between
        // our own two points. It also reads the POOL's tick ring, not the oracle -- moving the feed
        // alone moves nothing here.
        // NEXT: swap FINER than the sampling interval (read it out of `realizedVarianceWad` first),
        // and drive the POOL's tick, not the feed.
        if (varWad <= 0.04e18 || varWad >= 2e18) {
            emit log("INCONCLUSIVE: tape is a fixture artifact, not a protocol reading.");
            emit log("Do NOT quote any pricing magnitude from this run.");
            return;
        }
    }

    /// Integer sqrt of a WAD variance, reported in bps of annualised vol.
    function _sqrtBps(uint varWad) internal pure returns (uint) {
        uint x = varWad * 1e18; uint z = (x + 1) / 2; uint y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y / 1e14;
    }


    /// §UNIT-ZOOM-OUT — REAL BACKTEST, NOT A SYNTHETIC WALK. Instead of poking a mock feed and
    /// hoping the range's tick follows, read the tick history of the REAL Uniswap v3 WETH/USDC pool
    /// -- which carries real flow -- and the REAL Chainlink series over the SAME window, through
    /// the SAME estimator (`OracleLib.ringVariance`'s exact arithmetic, per §UNIT-RINGVARIANCE-READ:
    /// rate = dTickCum/dt scaled 1e9, variance of consecutive rate CHANGES, `+ mean*mean` for §E63's
    /// drift term, `/ spanSecs`, then Core's `*31_536_000*1e10/1e18`).
    /// THE QUESTION IS RESPONSIVENESS, NOT MAGNITUDE: does a tick series driven by REAL flow track
    /// the oracle's variance, or is our pegged range structurally deaf to it?
    function test_UNIT_BacktestV3TickVarianceVsChainlink() public {
        IUniV3Pool POOL = IUniV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640); // WETH/USDC 0.05%
        // 🔴 §BACKTEST-OLD — `observe()` REVERTS `"OLD"` WHEN THE LOOKBACK EXCEEDS THE POOL'S
        //   OBSERVATION CARDINALITY, AND THAT IS A UNISWAP REVERT, NOT A DEFECT HERE. A fixed 8h
        //   span assumed a cardinality this pool does not always carry at the fork head, so the
        //   whole diagnostic died on external data. Shrink the INTERVAL until the pool can serve it
        //   (the point count stays 9, so `rate[8]` and `_e63Variance` are unchanged) and report the
        //   window actually used — a backtest over the longest AVAILABLE window is the honest
        //   measurement; one that reverts is no measurement at all.
        // ⚠️ This test carries NO assertions by design: it PRINTS realised variance from a real
        //   mainnet pool beside Chainlink. Do not add one without deciding what it should bound.
        uint32 interval = 3600;
        int56[] memory tc;
        for (uint attempt; attempt < 5; ++attempt) {
            uint32[] memory ago = new uint32[](9);
            for (uint i; i < 9; ++i) ago[i] = uint32((8 - i) * interval);
            try POOL.observe(ago) returns (int56[] memory t, uint160[] memory) { tc = t; break; }
            catch { interval /= 2; }
        }
        if (tc.length == 0) { emit log("v3 pool cannot serve even a 225s window - nothing to backtest"); return; }
        emit log_named_uint("v3 interval used (s)    ", interval);

        int[8] memory rate;
        for (uint i; i < 8; ++i) rate[i] = (int(tc[i + 1] - tc[i]) * 1e9) / int(uint(interval));
        emit log_named_int("v3 avg tick, oldest step", rate[0] / 1e9);
        emit log_named_int("v3 avg tick, newest step", rate[7] / 1e9);
        emit log_named_uint("V3 POOL annualised sigma^2", _e63Variance(rate, 8 * interval));

        // Chainlink over the same 8h, converted to TICK space so the two are directly comparable.
        // 🔴 §BACKTEST-DOUBLE-DIFFERENCE — THIS SIDE WAS PRE-DIFFERENCED AND `_e63Variance`
        //   DIFFERENCES AGAIN, SO THE TWO SERIES WERE NEVER COMPARABLE — which is the whole point of
        //   this test. `_e63Variance` takes `rate[i] - rate[i+1]` internally, i.e. it wants LEVELS.
        //   The V3 side passes levels (an average tick per interval) and is right. This side passed
        //   `((tkHi - tk) * 1e9) / dt` — a RETURN PER SECOND — so the variance was taken of a second
        //   difference, in units 1e9 apart from the V3 series on top of that.
        //   MEASURED BEFORE THE FIX: V3 2.12e16 against Chainlink 1.86e29, ~13 orders apart, printed
        //   side by side under a comment claiming they are *"directly comparable"*.
        // ⇒ Pass tick LEVELS and let `_e63Variance` do the differencing, exactly as the V3 side does,
        //   and annualise over the span the rounds ACTUALLY cover (Chainlink rounds are irregular, so
        //   the span cannot be assumed).
        (uint80 rid,,,,) = AggregatorV3Interface(AGG).latestRoundData();
        int[8] memory clRate; uint got; uint32 clSpan;
        {
            uint tsNewest; uint tsOldest;
            for (uint i; i < 8; ++i) {
                (, int px,, uint ts,) = AggregatorV3Interface(AGG).getRoundData(uint80(uint(rid) - i));
                if (px <= 0 || ts == 0) break;
                // ln(p)*1e18 / (ln(1.0001)*1e18) => ticks*1e9, the SAME scale the V3 side uses.
                clRate[i] = SoladyMath.lnWad(int(uint(px) * 1e10)) / 99995;
                if (i == 0) tsNewest = ts;
                tsOldest = ts; ++got;
            }
            clSpan = tsNewest > tsOldest ? uint32(tsNewest - tsOldest) : 0;
        }
        emit log_named_uint("chainlink span (s)      ", clSpan);
        emit log_named_uint("chainlink intervals used ", got);
        if (got >= 3 && clSpan > 0) emit log_named_uint("CHAINLINK annualised sigma^2", _e63Variance(clRate, clSpan));
        emit log_named_uint("OUR RANGE sigma^2 (for scale)", CORE.realizedVarianceWad());
    }


    /// §UNIT-DEADZONE-COUNT's settling measurement. Our pool TWAP is FROZEN between re-pegs
    /// (§UNIT-PRICE-LOOP), so the divergence `twapResolve` gates on is simply how far Chainlink
    /// drifts from a FIXED point. That is measurable from Chainlink history alone: walk forward
    /// from each round and find how long until |p(t) - p0|/p0 crosses 500 bps. THAT interval IS the
    /// re-peg period, and it is how long the skew charges nothing.
    function test_UNIT_HowLongUntilTheDeadrangeOpens() public {
        (uint80 rid,,,,) = AggregatorV3Interface(AGG).latestRoundData();
        uint N = 119;
        int[] memory px = new int[](N); uint[] memory ts = new uint[](N); uint got;
        for (uint i; i < N; ++i) {
            (, int p2,, uint t2,) = AggregatorV3Interface(AGG).getRoundData(uint80(uint(rid) - (N - 1 - i)));
            if (p2 <= 0 || t2 == 0) break;
            px[i] = p2; ts[i] = t2; ++got;                 // oldest-first
        }
        emit log_named_uint("rounds", got);

        uint opened; uint sumHrs; uint maxDriftBps;
        for (uint a; a + 1 < got; ++a) {                    // each round as a "re-peg" origin
            for (uint b = a + 1; b < got; ++b) {
                uint d = uint(px[b] > px[a] ? px[b] - px[a] : px[a] - px[b]) * 10_000 / uint(px[a]);
                if (d > maxDriftBps) maxDriftBps = d;
                if (d >= 500) { ++opened; sumHrs += (ts[b] - ts[a]) / 3600; break; }
                if (b + 1 == got) { /* never opened from this origin */ }
            }
        }
        emit log_named_uint("origins that EVER crossed 500bps", opened);
        emit log_named_uint("origins tested                  ", got - 1);
        emit log_named_uint("mean HOURS to cross (when it did)", opened == 0 ? 0 : sumHrs / opened);
        emit log_named_uint("MAX drift seen over window, bps ", maxDriftBps);
        emit log_named_uint("window span, hours              ", got < 2 ? 0 : (ts[got-1] - ts[0]) / 3600);
    }

    /// §UNIT-DEADZONE-NEVER-OPENS step 1: the same crossing count at CANDIDATE thresholds, so the
    /// re-peg cadence can be chosen from data rather than asserted. Reports, per threshold, how many
    /// origins ever cross and the mean hours to cross -- i.e. how long the skew would read 0.
    function test_UNIT_RepegCadenceByThreshold() public {
        (uint80 rid,,,,) = AggregatorV3Interface(AGG).latestRoundData();
        uint N = 119;
        int[] memory px = new int[](N); uint[] memory ts = new uint[](N); uint got;
        for (uint i; i < N; ++i) {
            (, int p2,, uint t2,) = AggregatorV3Interface(AGG).getRoundData(uint80(uint(rid) - (N - 1 - i)));
            if (p2 <= 0 || t2 == 0) break;
            px[i] = p2; ts[i] = t2; ++got;
        }
        uint16[5] memory thresh = [uint16(25), 50, 100, 200, 500];
        for (uint k; k < 5; ++k) {
            uint opened; uint sumHrs;
            for (uint a; a + 1 < got; ++a) {
                for (uint b = a + 1; b < got; ++b) {
                    uint d = uint(px[b] > px[a] ? px[b] - px[a] : px[a] - px[b]) * 10_000 / uint(px[a]);
                    if (d >= thresh[k]) { ++opened; sumHrs += (ts[b] - ts[a]) / 3600; break; }
                }
            }
            emit log_named_uint("threshold bps            ", thresh[k]);
            emit log_named_uint("  origins crossing / 118 ", opened);
            emit log_named_uint("  mean HOURS stale       ", opened == 0 ? 999 : sumHrs / opened);
        }
    }

    /// §UNIT-REPEG-CADENCE step 2 — THE MEASUREMENT THAT COULD INVALIDATE THE FIX. Tightening the
    /// deadzone only helps if crossing it POPULATES THE RING. A re-peg that merely moves the spot
    /// without writing distinct observations leaves `card < 3` and sigma^2 at 0, and the whole
    /// diagnosis would be moot. Cross the 5% gate deliberately and watch both.
    function test_UNIT_DoesCrossingTheDeadrangePopulateTheRing() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.prank(lp); ETH.deposit{value: 400 ether}(0, lp);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        emit log_named_uint("TWAP before      ", px);
        emit log_named_uint("sigma^2 before   ", CORE.realizedVarianceWad());

        // Walk the feed WELL PAST the 500 bps gate -- 8 steps of +1.5% compounds to ~12.6%.
        uint p = px;
        for (uint i; i < 8; ++i) {
            p = p * 1015 / 1000;
            _setEthFeed(p / 1e10);
            vm.startPrank(drainer);
            try AUX.swap(address(USDC), address(WETH), true, 20_000 * USDC_PRECISION, 0, true) {} catch {}
            vm.stopPrank();
            vm.roll(block.number + 1); vm.warp(block.timestamp + 5 minutes);
            if (i % 3 == 0) {
                emit log_named_uint("  step", i);
                emit log_named_uint("   feed  ", p);
                emit log_named_uint("   TWAP  ", AUX.getTWAPforAsset(address(WETH), 1800));
            }
        }
        emit log_named_uint("TWAP after       ", AUX.getTWAPforAsset(address(WETH), 1800));
        emit log_named_uint("sigma^2 AFTER    ", CORE.realizedVarianceWad());
        emit log_named_uint("wellSkew AFTER   ", AUX.wellSkew(address(WETH), 0));
    }

    /// §UNIT-REPEG-CADENCE's missing input, outstanding since it was listed six entries ago:
    /// ISOLATED RESEAT GAS. `Quid.reseat()` is the permissionless poke, so the cost can be read
    /// on its own rather than inferred from a whole walk. Measured THREE ways because a single
    /// number would not distinguish the no-op path from the real burn+move+re-range.
    function test_UNIT_IsolatedReseatGas() public {
        _seed();
        deal(address(USDC), drainer, 20_000_000 * USDC_PRECISION);
        vm.prank(drainer); USDC.approve(address(AUX), type(uint).max);
        vm.prank(lp); ETH.deposit{value: 400 ether}(0, lp);
        _settle();
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        AUX.setAssetFeed(address(WETH), ETH_FEED);

        // (a) ALIGNED — the common case. Should be a cheap no-op (`targetSqrt == spotPrice`).
        uint g = gasleft(); ETH.reseat(); uint gNoop = g - gasleft();
        emit log_named_uint("reseat gas: ALIGNED (no-op)   ", gNoop);

        // (b) DRIFTED BELOW THE 5% GATE — the regime real ETH lives in (max 398 bps, §UNIT-DEADZONE-
        //     NEVER-OPENS). Expect ANOTHER no-op: `stale` is false, so the auto-heal never runs.
        _setEthFeed((px * 103 / 100) / 1e10);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        g = gasleft(); ETH.reseat(); uint gSub5 = g - gasleft();
        emit log_named_uint("reseat gas: DRIFTED +3% (<5%) ", gSub5);

        // (c) PAST THE GATE — the only regime the auto-heal fires in. This is the REAL cost.
        _setEthFeed((px * 112 / 100) / 1e10);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        g = gasleft(); ETH.reseat(); uint gStale = g - gasleft();
        emit log_named_uint("reseat gas: DRIFTED +12% (>5%)", gStale);
        emit log_named_uint("  => real reseat cost (c - a) ", gStale > gNoop ? gStale - gNoop : 0);
    }

    address constant AGG = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// `OracleLib.ringVariance`'s arithmetic, mirrored EXACTLY (§UNIT-RINGVARIANCE-READ) — including
    /// §E63's `+ mean*mean`, without which a steadily-trending series measures as perfectly calm.
    function _e63Variance(int[8] memory rate, uint32 spanSecs) internal pure returns (uint) {
        uint m = 7; int mean;
        for (uint i; i < m; ++i) mean += (rate[i] - rate[i + 1]);
        mean /= int(m);
        uint acc;
        for (uint i; i < m; ++i) { int d = (rate[i] - rate[i + 1]) - mean; acc += uint(d * d); }
        acc /= (m - 1);
        acc += uint(mean * mean);                       // §E63 drift term
        return (acc / spanSecs) * 31_536_000 * 1e10 / 1e18;   // Core's annualisation
    }
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int, uint, uint, uint80);
    function getRoundData(uint80) external view returns (uint80, int, uint, uint, uint80);
}

interface IUniV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
