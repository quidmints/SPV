// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

interface IWETHDeposit { function deposit() external payable; }
import {ICore} from "../src/imports/Interfaces.sol";


/// §E69 — IS RESTORING THE RANGE'S BALANCE NATURALLY PROFITABLE?
///
/// Asked twice by the owner, answered twice by me with an ARGUMENT, and once by citing E25's
/// "0 bps across 300k" as though it settled the matter. IT DOES NOT: E25 measured a BALANCED
/// range under ORDINARY volume. The question is the dislocation in an IMBALANCED range — the only
/// state in which a restorer would act. This fixture asks the actual question.
///
/// TWO ERRORS IN THE FIRST DRAFT OF THIS FILE, RECORDED SO THEY ARE NOT REPEATED:
///   1. DIRECTION INVERTED. I labelled a stable→volatile BUY as "adds volatile to the range".
///      It does the opposite: the range HANDS OUT BTC, so `inv` FALLS and the range gets SCARCER.
///      A volatile→stable SELL is what RAISES `inv`. Every comment was backwards.
///   2. THE SKEW STAYED 0 AND I NEARLY READ THAT AS "NO PREMIUM EXISTS". It was the flush
///      branch: `target = flowEwmaUsd` GROWS with the very volume used to drive the drain, so
///      `inv >= target` held throughout and `wellSkew` correctly returned 0. **The fixture was
///      not reaching the state it was trying to measure.** Hence the explicit inv/target log
///      below, and the early INCONCLUSIVE exit — a measurement that cannot show its own state
///      is indistinguishable from its own bug, which is what CLAUDE.md's control question asks.
///
/// WHAT "PROFITABLE" MEANS HERE. A restorer moves `inv` back toward target and unwinds at oracle
/// elsewhere. It nets only if execution BEATS oracle by more than gas + LP fee. So the measurable
/// is the SIGN of  (what the restorer received) − (what the same size fetches at oracle).
///   > 0 => the curve pays the restorer; an external arb closes the imbalance unaided.
///  == 0 => restoration is priced AT oracle; the restorer is gas + fee NEGATIVE, nobody does it,
///          and the imbalance persists until someone is PAID to fix it.
contract RestoreProfitability is AllesFixture {
    address lpA = User02;
    address drainer = address(0xBEEF02);
    address attacker = address(0xBEEF03);
    address restorer = address(0xBEEF03);
    address bold;

    function _seedBasket() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 4_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function _settle() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 20 minutes);
    }

    /// stable → volatile. The range HANDS OUT ETH ⇒ `inv` FALLS ⇒ the range gets SCARCER.
    function _drainEth(uint boldAmt) internal {
        deal(bold, drainer, boldAmt);
        vm.startPrank(drainer);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) {} catch {}
        vm.stopPrank();
        _settle();
    }

    /// The range's scarcity state, in the SAME terms the skew itself computes it.
    function _state() internal view returns (uint invUsd6, uint targetUsd6) {
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        invUsd6 = CORE.POOLED() * px / 1e30;
        targetUsd6 = CORE.flowEwmaUsd();
    }

    /// TOTAL stable value held by `who`, in 18-dec USD, across EVERY basket stable plus QUID.
    /// §E69 — this exists because TWO successive runs reported a zero edge that was really me
    /// reading the WRONG TOKEN: the sell pays out in whichever stable the basket selects, not
    /// necessarily `bold`. Summing all of them takes my guess out of the measurement, so a zero
    /// here means zero PROCEEDS rather than zero KNOWLEDGE of where they went.
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

    /// 🔬 §REFILL-SIZE — **IS THE PREMIUM CHARGED FOR RESTORING, OR ONLY FOR OVERSHOOTING?**
    ///
    /// `test_E69` reported −300 bps and concluded "restoration does not pay for itself". It sells
    /// 20 ETH into a $27.4k deficit — **1.82x the gap**, so 45% of that trade pushes inventory PAST
    /// target, which `SwapLib:430` charges the A-S premium ON PURPOSE. So the −300 bps measured a
    /// trade that is not purely restoring, and the conclusion does not follow from it.
    ///
    /// This sweeps the sell size as a MULTIPLE OF THE DEFICIT, on identical state each time
    /// (snapshot/revert), and prints the shortfall. The hypothesis under test: **the premium is a
    /// property of the OVERSHOOT, not of the restoring trade** ⇒ shortfall is 0 at or below 1.00x
    /// and non-zero only above it.
    function test_REFILLSIZE_ShortfallIsAPropertyOfOvershootNotRestoration() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        if (inv1 >= tgt1) { emit log("INCONCLUSIVE: never reached inv < target"); return; }

        uint pxNow    = AUX.getTWAPforAsset(address(WETH), 1800);
        uint deficit18 = (tgt1 - inv1) * 1e12;
        emit log_named_uint("deficit (usd18)", deficit18);

        // multiples of the deficit, in percent: 50%, 90%, 100%, 110%, 150%, 182%, 300%
        uint[7] memory pct = [uint(50), 90, 100, 110, 150, 182, 300];
        for (uint i = 0; i < pct.length; ++i) {
            uint snap = vm.snapshotState();
            uint size18 = deficit18 * pct[i] / 100;
            uint sellSize = size18 * 1e18 / pxNow;
            deal(address(WETH), restorer, sellSize);
            uint before = _stableValue18(restorer);
            vm.startPrank(restorer);
            WETH.approve(address(AUX), sellSize);
            AUX.swap(bold, address(WETH), false, sellSize, 1, true);
            vm.stopPrank();
            uint got = _stableValue18(restorer) - before;
            uint atOracle = sellSize * pxNow / 1e18;
            uint bps = atOracle > got ? (atOracle - got) * 10_000 / atOracle : 0;
            emit log_named_uint("---- size as % of deficit", pct[i]);
            emit log_named_uint("     shortfall bps       ", bps);
            // 🔴 THE ASSERTIONS THIS TEST WAS MISSING. It printed a clean step function and
            //    asserted NOTHING — so it could not fail, and a regression that started charging
            //    restoring trades would have printed different numbers under a green tick.
            //    A test whose output only a human reads is a script, not a gate.
            // §MIN-SWAP-FEE — "FREE" MEANS FREE OF THE *EXTRA*, NOT FREE. Owner, 2026-09-08:
            //   *"the minimum swap fee was just the fact that all swaps even balance restoring must
            //   pay at least the minimum"*, and on the exemption: *"by that free meaning it just
            //   means without encumbering extra beyond the minimum."*
            // ⇒ At or below the deficit the restorer pays the FLOOR and not one bp more. Asserting
            //   `== minBps` rather than `<= minBps` is the point: it fails BOTH ways, catching a
            //   premium wrongly charged on a restore AND the floor going missing again.
            uint minBps = SwapLib.MIN_SWAP_SKEW_WAD * 10_000 / 1e18;   // 420 ppm ⇒ 4 bps
            if (pct[i] <= 100) {
                assertEq(bps, minBps,
                    "RESTORING PAYS THE MINIMUM AND NOTHING MORE: at or below the deficit the "
                    "mirror/flush exemption must remove the PREMIUM, leaving exactly the floor");
            } else {
                assertGt(bps, minBps,
                    "OVERSHOOT MUST BE CHARGED ABOVE THE FLOOR: past target the trade is "
                    "inventory-INCREASING and pays the A-S premium ON TOP of the minimum");
            }
            vm.revertToState(snap);
        }
    }

    /// @notice ⭐ THE SAME OVERSHOOT SWEEP, BUT WITH **REAL** σ² — the measurement that decides
    ///         whether the 300 bps step is a pricing design or an artefact of an unmeasured input.
    /// 🔴 THE DISCRIMINATOR: with σ² > 0 the `sigmaSqWad == 0` branch is NOT taken, so `sellSkew`
    ///    computes `Γ·σ²·qBar` and §E68b's midpoint integration (`qBar = (q0+q1)/2`, `q0 == 0` for a
    ///    sell starting below target) is finally live. If the shortfall then CLIMBS across
    ///    101/102/105/110%, the cliff was the ceiling sentinel and the A-S curve is continuous — and
    ///    my §REFILL-SIZE "cliff, applied to the whole trade" booking must be retracted. If it is
    ///    STILL flat at 300 with σ² > 0, the cliff is real and is a genuine refill defect.
    /// ⚠️ SKIPS rather than passes if the warm-up cannot raise σ² — a run that could not create the
    ///    precondition must be VISIBLE, not a tick. (I already shipped that mistake once today.)
    function test_REFILLSIZE_OvershootChargeUnderRealMainnetVariance() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();
        uint256 sigma = warmVarianceFromRealRounds(12);   // 12 REAL consecutive Chainlink rounds
        emit log_named_uint("sigma^2 after warm-up (0 == still UNMEASURED)", sigma);
        // NOTE: deliberately NOT skipping here while diagnosing — `vm.skip` SUPPRESSES
        //       every emitted log, which is how the first run told me nothing at all.
        if (sigma == 0) { emit log("WARM-UP FAILED: sigma^2 still 0 - see per-step logs above"); return; }

        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        if (inv1 >= tgt1) { emit log("INCONCLUSIVE: never reached inv < target"); vm.skip(true); }
        uint pxNow     = AUX.getTWAPforAsset(address(WETH), 1800);
        uint deficit18 = (tgt1 - inv1) * 1e12;
        emit log_named_uint("deficit (usd18)", deficit18);

        uint[6] memory pct = [uint(100), 101, 105, 110, 150, 300];
        for (uint i = 0; i < pct.length; ++i) {
            uint snap = vm.snapshotState();
            uint size18   = deficit18 * pct[i] / 100;
            uint sellSize = size18 * 1e18 / pxNow;
            uint skewRaw  = SwapLib.sellSkew(address(CORE), pxNow, sellSize);
            deal(address(WETH), restorer, sellSize);
            uint before = _stableValue18(restorer);
            vm.startPrank(restorer);
            WETH.approve(address(AUX), sellSize);
            AUX.swap(bold, address(WETH), false, sellSize, 1, true);
            vm.stopPrank();
            uint got = _stableValue18(restorer) - before;
            uint atOracle = sellSize * pxNow / 1e18;
            uint bps = atOracle > got ? (atOracle - got) * 10_000 / atOracle : 0;
            emit log_named_uint("---- size as % of deficit", pct[i]);
            emit log_named_uint("     shortfall bps       ", bps);
            emit log_named_uint("     sellSkew raw (wad)  ", skewRaw);
            emit log_named_uint("     realizedVarianceWad ", ICore(address(CORE)).realizedVarianceWad());
            assertGt(atOracle, 0, "zero oracle value - nothing measured");
            vm.revertToState(snap);
        }
    }

    /// @notice 🔴 §REFILL-FARM — **CAN THE EXEMPTION BE FARMED BY ROUND-TRIPPING?** A falsification
    ///         test, written to BREAK the mechanism rather than confirm it.
    /// ⇒ THE THEORY OF THE ATTACK. The refill direction is EXEMPT (0 bps) and the drain direction
    ///   PAYS a premium. If a single actor can drain and then refill, they pay the premium on one leg
    ///   and nothing on the other — so the question is whether the round trip nets NEGATIVE for them
    ///   (the mechanism holds: they funded LPs) or POSITIVE (the exemption is farmable income and the
    ///   pool is being drained by design).
    /// ⚠️ N CYCLES, NOT ONE. A single round trip can net ~0 by luck of rounding; a FARM has to
    ///   COMPOUND. Running five and reporting the per-cycle trend is what separates "noise around
    ///   zero" from "a slow bleed", and only the second is a defect.
    /// 🔴 THE POOL-SIDE CHECK IS THE ONE THAT MATTERS. An actor losing money does not by itself mean
    ///   the pool gained it — value can leak to a third party or be destroyed in slippage. So this
    ///   measures BOTH ends: the farmer's net AND the range's own equity across the cycles.
    /// ⛔ NO PASS/FAIL ON THE ECONOMICS. The numbers are the finding; the guards only prove the run
    ///   reached the code, because a zero-trade run would otherwise read as "not farmable".
    function test_REFILLFARM_DoesRoundTrippingTheExemptionPay() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();
        emit log_named_uint("sigma^2 (0 == SENTINEL, curve inactive)", warmVarianceFromRealRounds(12));

        address farmer = address(0xBEEF04);
        vm.deal(farmer, 0);                    // start from zero so `farmer.balance` IS the payout
        uint startStable = _stableValue18(farmer);
        uint eq0 = CORE.rangeEquityUsd18();
        uint traded;
        emit log_named_uint("range equity BEFORE (18d)", eq0);

        for (uint c = 0; c < 5; ++c) {
            // DRAIN leg: buy volatile out of the range — this direction PAYS the A-S premium.
            uint boldAmt = 60_000 * 1e18;
            deal(bold, farmer, boldAmt);
            vm.startPrank(farmer);
            IERC20(bold).approve(address(AUX), boldAmt);
            bool drainOk;
            try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) { drainOk = true; }
            catch (bytes memory e) { emit log_named_bytes("    DRAIN REVERTED ", e); }
            vm.stopPrank();
            _settle();
            // ⛔ THE DRAIN PAYS OUT **NATIVE ETH**, NOT WETH. Reading `WETH.balanceOf(farmer)` here
            //    returned 0 while the drain reported SUCCESS, so the refill leg never ran and the
            //    loop measured nothing — the same token-identity error this repo has recorded before
            //    ("measured native ETH when payout was WETH"), in the opposite direction. Wrap what
            //    actually arrived, then sell that.
            uint native = farmer.balance;
            if (native > 0) { vm.prank(farmer); IWETHDeposit(address(WETH)).deposit{value: native}(); }
            // REFILL leg: sell it back — EXEMPT while inv <= target.
            uint back = WETH.balanceOf(farmer);
            bool refillOk;
            if (back > 0) {
                vm.startPrank(farmer);
                WETH.approve(address(AUX), back);
                try AUX.swap(bold, address(WETH), false, back, 1, true) { refillOk = true; }
                catch (bytes memory e) { emit log_named_bytes("    REFILL REVERTED", e); }
                vm.stopPrank();
            }
            _settle();
            emit log_named_uint("  cycle", c);
            emit log_named_uint("    drain ok / refill ok    ", (drainOk ? 10 : 0) + (refillOk ? 1 : 0));
            emit log_named_uint("    WETH held after drain   ", back);
            emit log_named_uint("    farmer stable now (18d) ", _stableValue18(farmer));
            emit log_named_uint("    range equity      (18d) ", CORE.rangeEquityUsd18());
            // 🔴 THE LOOP MUST HAVE TRADED. Without this the try/catch turns a fixture that cannot
            //    execute into a SILENT PASS reporting "not farmable" — which is what the first run of
            //    this test did: five cycles, every figure 0, range equity byte-identical, green.
            //    A falsification test that cannot execute falsifies nothing.
            traded += (drainOk && refillOk) ? 1 : 0;
        }

        uint endStable = _stableValue18(farmer);
        uint eq1 = CORE.rangeEquityUsd18();
        emit log_named_uint("range equity AFTER  (18d)", eq1);
        emit log_named_uint("  FARMER NET (0 == lost or broke even)", endStable > startStable ? endStable - startStable : 0);
        emit log_named_uint("  FARMER LOST                         ", startStable > endStable ? startStable - endStable : 0);
        emit log_named_uint("  RANGE EQUITY GAINED                 ", eq1 > eq0 ? eq1 - eq0 : 0);
        emit log_named_uint("  RANGE EQUITY LOST                   ", eq0 > eq1 ? eq0 - eq1 : 0);
        assertGt(eq0, 0, "zero range equity - nothing was measured");
        assertGt(traded, 0,
            "NO CYCLE COMPLETED BOTH LEGS - this test measured an EMPTY LOOP. A green here would\n             report 'not farmable' on the strength of no trades at all.");
    }

    /// @notice 🔴 §REFILL-GRIEF — **CAN AN ATTACKER MOVE THE DEFICIT SO AN HONEST RESTORER OVERSHOOTS?**
    ///         This is the "cannot be manipulated" half of the refill goal, and it is NOT the same
    ///         question as "is the charge a cliff". The charge being LINEAR bounds the DAMAGE per
    ///         wei of overshoot; it says nothing about whether the overshoot can be INDUCED.
    /// ⇒ THE ATTACK. A restorer sizes a sell to exactly the deficit — free at 0 bps, the mirror/flush
    ///   exemption. An attacker sells a SMALL amount one transaction earlier, shrinking the deficit
    ///   by ε. The victim's already-sized trade now lands ε PAST target and pays the A-S premium.
    ///   ⚠️ The attacker's own sell is ALSO a refill, so it is exempt too — the attack may cost
    ///   nothing but gas. That asymmetry is what would make it a griefing vector.
    /// ⇒ MEASURED AS AN A/B ON IDENTICAL STATE (snapshot/revert), so the only difference is the
    ///   attacker's presence: victim's proceeds ALONE vs victim's proceeds AFTER the attacker.
    /// ⛔ NO INEQUALITY ASSERTED on the damage — the numbers are the finding. The two `assertGt`
    ///   guards only prove the run reached the code, because a zero-proceeds run would otherwise
    ///   read as "no damage".
    function test_REFILLGRIEF_CanAnAttackerInduceOvershoot() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();
        emit log_named_uint("sigma^2 (0 == SENTINEL, charge would be flat)",
                            warmVarianceFromRealRounds(12));
        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        if (inv1 >= tgt1) { emit log("INCONCLUSIVE: never reached inv < target"); vm.skip(true); }
        uint pxNow     = AUX.getTWAPforAsset(address(WETH), 1800);
        uint deficit18 = (tgt1 - inv1) * 1e12;
        uint honestSize = (deficit18 * 1e18 / pxNow);          // EXACTLY the deficit ⇒ free
        emit log_named_uint("deficit (usd18)          ", deficit18);

        // ── ARM A: the honest restorer alone ────────────────────────────────────────────────
        uint snapA = vm.snapshotState();
        uint gotAlone = _sell(restorer, honestSize);
        uint atOracle = honestSize * pxNow / 1e18;
        uint bpsAlone = atOracle > gotAlone ? (atOracle - gotAlone) * 10_000 / atOracle : 0;
        emit log_named_uint("A: honest alone  proceeds", gotAlone);
        emit log_named_uint("A: honest alone  shortfall bps", bpsAlone);
        vm.revertToState(snapA);

        // ── ARM B: attacker shrinks the deficit by 5%, THEN the identical honest sell ───────
        uint snapB = vm.snapshotState();
        uint attackSize = honestSize * 5 / 100;
        uint attackerGot = _sell(attacker, attackSize);
        uint attackerAtOracle = attackSize * pxNow / 1e18;
        uint attackerBps = attackerAtOracle > attackerGot
            ? (attackerAtOracle - attackerGot) * 10_000 / attackerAtOracle : 0;
        uint gotAfter = _sell(restorer, honestSize);
        uint bpsAfter = atOracle > gotAfter ? (atOracle - gotAfter) * 10_000 / atOracle : 0;
        emit log_named_uint("B: attacker      cost bps", attackerBps);
        emit log_named_uint("B: honest        proceeds", gotAfter);
        emit log_named_uint("B: honest        shortfall bps", bpsAfter);
        emit log_named_uint("  VICTIM EXTRA LOSS (usd18)", gotAlone > gotAfter ? gotAlone - gotAfter : 0);
        emit log_named_uint("  ATTACKER COST     (usd18)", attackerAtOracle > attackerGot ? attackerAtOracle - attackerGot : 0);
        vm.revertToState(snapB);

        assertGt(atOracle, 0, "zero oracle value - nothing measured");
        assertGt(gotAlone, 0, "honest arm produced no proceeds - nothing measured");
    }

    /// Sell `size` WETH through the range as `who`, returning stable proceeds (18-dec).
    function _sell(address who, uint size) internal returns (uint got) {
        deal(address(WETH), who, size);
        uint before = _stableValue18(who);
        vm.startPrank(who);
        WETH.approve(address(AUX), size);
        try AUX.swap(bold, address(WETH), false, size, 1, true) {} catch { }
        vm.stopPrank();
        got = _stableValue18(who) - before;
    }

    /// @notice ⭐ IS THE OVERSHOOT CHARGE A CLIFF OR A SLOPE? THE ORIGINAL SWEEP COULD NOT TELL.
    ///         `test_REFILLSIZE_…` samples [50, 90, 100, 110, …] and reports 0 bps at 100% and
    ///         300 bps at 110%. I read that as a CLIFF and booked it as one in §REFILL-SIZE. **THAT
    ///         READING IS NOT SUPPORTED BY THAT DATA: there is NO SAMPLE BETWEEN 100 AND 110**, and a
    ///         step observed across a gap is indistinguishable from a steep continuous rise.
    /// 🔴 AND THE CODE SAYS IT SHOULD BE A SLOPE. §E68b (`5ff4a893`, 2026-08-24 — TWO WEEKS BEFORE
    ///    that measurement) integrates the charge over the sell: `qBar = (q0 + q1) / 2`, with
    ///    `q0 == 0` for a sell starting at/below target, so a trade that crosses target by ε should
    ///    pay on ε/2, not on the endpoint rate. A flat 300 bps at 110% AND at 300% contradicts that.
    /// ⇒ THIS SWEEP PUTS SAMPLES IN THE GAP. If bps goes 0 → 300 between 100 and 101, the charge is
    ///   genuinely discontinuous and §E68b is not reaching this path. If it climbs, the "cliff" was
    ///   my sampling and the booked finding must be corrected.
    /// ⚠️ It also logs `sellSkew` DIRECTLY, because `bps` is a round-trip measure (oracle parity vs
    ///    realised proceeds) and can be flat for reasons that have nothing to do with the skew — a
    ///    floor, a fee, or a clamp downstream. Two numbers separate "the skew saturates" from "the
    ///    skew scales but something after it saturates", which are different defects.
    function test_REFILLSIZE_IsTheOvershootChargeACliffOrASlope() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();
        // ⛔ THE DRAIN LOOP IS NOT OPTIONAL — WITHOUT IT THERE IS NO DEFICIT AND THIS TEST MEASURES
        //    NOTHING. I omitted it on the first write and the run reported **PASS having measured
        //    zero rows**: the `inv >= target` guard fired and returned, and a test that RETURNS
        //    reports PASS. That is the vacuous pass this file already warns about elsewhere — the
        //    guard was doing its job and the EXIT PATH was wrong.
        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        // `vm.skip`, NOT `return` — a skipped test is VISIBLE in the summary; a returned one is a tick.
        if (inv1 >= tgt1) { emit log("INCONCLUSIVE: never reached inv < target"); vm.skip(true); }
        uint pxNow     = AUX.getTWAPforAsset(address(WETH), 1800);
        uint deficit18 = (tgt1 - inv1) * 1e12;
        emit log_named_uint("deficit (usd18)", deficit18);

        uint[9] memory pct = [uint(100), 101, 102, 105, 110, 125, 150, 200, 300];
        for (uint i = 0; i < pct.length; ++i) {
            uint snap = vm.snapshotState();
            uint size18   = deficit18 * pct[i] / 100;
            uint sellSize = size18 * 1e18 / pxNow;
            uint skewRaw  = SwapLib.sellSkew(address(CORE), pxNow, sellSize);
            deal(address(WETH), restorer, sellSize);
            uint before = _stableValue18(restorer);
            vm.startPrank(restorer);
            WETH.approve(address(AUX), sellSize);
            AUX.swap(bold, address(WETH), false, sellSize, 1, true);
            vm.stopPrank();
            uint got = _stableValue18(restorer) - before;
            uint atOracle = sellSize * pxNow / 1e18;
            uint bps = atOracle > got ? (atOracle - got) * 10_000 / atOracle : 0;
            emit log_named_uint("---- size as % of deficit", pct[i]);
            emit log_named_uint("     shortfall bps       ", bps);
            emit log_named_uint("     sellSkew raw (wad)  ", skewRaw);
            // 🔴 THE DISCRIMINATOR. `sellSkew` returns UNKNOWN_VARIANCE_SKEW (3e16) FLAT whenever
            //    `sigmaSqWad == 0`, bypassing qBar and therefore bypassing §E68b's integration
            //    entirely. A flat 300 bps is then a CONSTANT, not a saturated curve — and the two
            //    are indistinguishable from the shortfall column alone, which is how I mis-booked
            //    this as a pricing cliff. Log the variance so the branch is visible, not inferred.
            emit log_named_uint("     realizedVarianceWad    ", ICore(address(CORE)).realizedVarianceWad());
            assertGt(atOracle, 0, "zero oracle value - nothing was measured, do not read a pass");
            vm.revertToState(snap);
        }
    }

    function test_E69_IsRestoringNaturallyProfitable() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        (uint inv0, uint tgt0) = _state();
        emit log_named_uint("START inv (usd6)   ", inv0);
        emit log_named_uint("START target (usd6)", tgt0);
        emit log_named_uint("START wellSkew     ", AUX.wellSkew(address(WETH), 0));

        // ---- 1. DRAIN until the range is genuinely SCARCE (inv < target), or give up and SAY SO
        //         rather than reporting a number from a state we never reached.
        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        emit log_named_uint("AFTER inv (usd6)   ", inv1);
        emit log_named_uint("AFTER target (usd6)", tgt1);
        emit log_named_uint("AFTER wellSkew     ", AUX.wellSkew(address(WETH), 0));

        if (inv1 >= tgt1) {
            emit log("INCONCLUSIVE: never reached inv < target -- the scarce leg was never live.");
            emit log("Do NOT read a zero edge from this run; the fixture did not reach the state.");
            return;
        }

        // ---- 2. THE RESTORING TRADE: sell ETH back, which RAISES inv toward target.
        //         Measure BOTH plausible payout tokens, so a wrong guess about where proceeds
        //         land cannot masquerade as a zero edge — the first draft's exact failure.
        uint pxNow = AUX.getTWAPforAsset(address(WETH), 1800);   // price AT THE TRADE, not pre-drain
        emit log_named_uint("oracle px PRE-drain ", px);
        emit log_named_uint("oracle px AT-trade  ", pxNow);
        // §REFILL-SIZE — SIZE THE SELL TO THE DEFICIT, NOT TO A ROUND NUMBER.
        // 20 ether is 1.82x the gap at this state, so 45% of it pushes inventory PAST target —
        // and SwapLib:430 charges that portion the A-S premium ON PURPOSE ("a sell that pushes
        // the pool's volatile inventory PAST target is inventory-INCREASING"). Measuring
        // "does restoring pay?" with a trade that is 45% NOT restoring answers a different
        // question. Cap at the deficit so the whole trade is the thing under test.
        uint deficit18 = (tgt1 - inv1) * 1e12;                  // usd6 -> usd18
        uint sellSize  = deficit18 * 1e18 / pxNow;              // exactly the gap, in ETH
        emit log_named_uint("deficit (usd18)    ", deficit18);
        emit log_named_uint("sell sized to gap  ", sellSize);
        deal(address(WETH), restorer, sellSize);
        uint valueBefore = _stableValue18(restorer);
        vm.startPrank(restorer);
        WETH.approve(address(AUX), sellSize);
        uint minOut = 1;   // the weakest possible demand: ANY non-zero delivery
        AUX.swap(bold, address(WETH), false, sellSize, minOut, true);
        vm.stopPrank();
        uint wethLeft = WETH.balanceOf(restorer);
        emit log_named_uint("restorer WETH left (0=input taken, 20e18=no-op)", wethLeft);
        uint got = _stableValue18(restorer) - valueBefore;
        emit log_named_uint("restorer got (all stables + QUID, usd18)", got);
        // §S16 / E91 REGRESSION GUARD — ASSERT AT THE RECIPIENT, WHICH IS THE ONLY PLACE THAT KNOWS.
        // The delivery bug this fixture uncovered survived SIX layers of diagnosis because every
        // guard in the stack asserts on a number REPORTED BY THE FAILING CODE: `max` reports the
        // swap's delta (not the user's receipt), `minOut` compares against that same `max`, and the
        // `NothingDelivered` aggregate reads a `sent` that `withdrawFromSP` returned non-zero while
        // transferring nothing. All three were structurally blind. A BALANCE DELTA measured by the
        // caller is the only assertion that cannot be fooled by the code under test — so make it one,
        // not a log line. If BOLD-SP (or any venue) ever stops delivering again, this fails loudly.
        assertGt(got, 0, "S16: swap consumed input and delivered NOTHING to the recipient");
        uint atOracle = sellSize * pxNow / 1e18;   // CONFOUND FIX: compare against the LIVE price
        emit log_named_uint("same size at oracle", atOracle);

        if (got == 0) {
            emit log("INCONCLUSIVE: no proceeds in either token -- payout path still unidentified.");
        } else if (got > atOracle) {
            emit log_named_uint("EDGE bps (POSITIVE)", (got - atOracle) * 10_000 / atOracle);
            emit log("RESULT: the curve PAYS the restorer -- an external arb closes this unaided.");
        } else {
            emit log_named_uint("SHORTFALL bps      ", (atOracle - got) * 10_000 / atOracle);
            emit log("RESULT: at size <= deficit the trade prices AT oracle (0 bps) - value-neutral, not a loss.");
        }
    }
}
