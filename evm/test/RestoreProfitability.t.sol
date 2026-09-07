// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {ICore} from "../src/imports/Interfaces.sol";

interface IAgg { function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80); }

// The REAL mainnet Chainlink ETH/USD aggregator proxy — not the fixture's synthetic `ETH_FEED`.
address constant CL_ETH_USD_REAL = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

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
            if (pct[i] <= 100) {
                assertEq(bps, 0,
                    "RESTORING MUST BE FREE: at or below the deficit the mirror/flush exemption "
                    "must zero the premium (SwapLib:430)");
            } else {
                assertGt(bps, 0,
                    "OVERSHOOT MUST BE CHARGED: past target the trade is inventory-INCREASING and "
                    "pays the A-S premium");
            }
            vm.revertToState(snap);
        }
    }

    /// @dev ⭐ WARM THE ANCHOR-VARIANCE REGISTERS FROM **REAL MAINNET CHAINLINK HISTORY**, replayed
    ///      at ONE pinned block. Real prices, real round spacing, real inter-round gaps.
    /// 🔴 WHY NOT `vm.rollFork`, WHICH IS THE OBVIOUS WAY AND THE ONE I TRIED FIRST: forge deploys
    ///    the LINKED LIBRARIES (`SwapLib`, `LevMath`, …) as real contracts, and `rollFork` wipes any
    ///    address not marked persistent. Every swap then dies with
    ///    `CheatcodeError: Contract 0x… does not exist and is not marked as persistent`, the
    ///    try/catch swallows it, and σ² stays 0 for a reason that has NOTHING to do with variance.
    ///    Persisting the fixture is not enough — the libraries have no handles in the test.
    /// 🔴 WHY `vm.warp` ALONE CANNOT DO IT EITHER: warping moves the EVM clock, not forked external
    ///    state. `YieldFactorDimensions.t.sol:68` measured a vault accruing ~3e-6 over a 30-day warp
    ///    against a real ~3e-3 — a THOUSANDFOLD short.
    /// ⇒ THE READABLE PATH: the Chainlink PROXY's roundIds are phase-encoded (`phase<<64 | round`,
    ///   ~1.29e20 — which OVERFLOWS a 64-bit shell, how I first "proved" they were unreadable), but
    ///   the PHASE AGGREGATOR behind it takes small round numbers and answers `getRoundData` for
    ///   history at ANY block. So read the real series once, then replay it.
    /// ⚠️ Each replayed round warps to its OWN real timestamp, so `Σdt` carries the REAL gaps —
    ///    §E343's finding is that the series must be read PER ROUND, because on a fixed grid the
    ///    gaps flatten and σ² collapses.
    function _warmVarianceFromRealRounds(uint256 nRounds) internal returns (uint256 sigma) {
        // ⛔ PIN THE **REAL** CHAINLINK AGGREGATOR, NOT THE FIXTURE'S SYNTHETIC `ETH_FEED`
        //    (`address(0xE7F0FEED)`, mocked to a CONSTANT). The base `AllesFixture` pins NO asset
        //    feed for WETH at all — `assetPriceFeed(WETH)` is `address(0)` — which is why my first
        //    attempt staticcalled 0x0 and died with "Contract 0x000…000 does not exist". A synthetic
        //    feed cannot produce variance by construction: its price never moves and its roundId is
        //    hard-coded to 1, so `_varPx` never advances and σ² is 0 FOREVER.
        address feed = CL_ETH_USD_REAL;
        _auxSetAssetFeed(address(WETH), feed);
        // ⛔ READ HISTORY THROUGH THE **PROXY**, NOT THE PHASE AGGREGATOR BEHIND IT. Chainlink's
        //    `AccessControlledOffchainAggregator` REFUSES CONTRACT CALLERS — a `cast call` works
        //    because `eth_call` presents as an EOA, a test contract does not. Reading the aggregator
        //    directly therefore succeeds from the shell and returns "UNREADABLE" for all 12 rounds
        //    in-test, which looks like missing data and is an access check.
        // ⇒ And keep the roundId PHASE-ENCODED (`phase<<64 | round`, ~1.29e20). Do not "simplify" by
        //   stripping the phase: the proxy needs it, `uint80` holds it comfortably, and it is only a
        //   64-bit SHELL that overflows on it — which is how I first convinced myself the history
        //   was unreadable at all.
        (, , , , uint80 latestPhaseRound) = IAgg(feed).latestRoundData();
        uint256 prevTs;
        for (uint256 i = nRounds; i > 0; --i) {
            uint80 rid = latestPhaseRound - uint80(i);
            (bool ok, bytes memory ret) = feed.staticcall(
                abi.encodeWithSignature("getRoundData(uint80)", rid));
            if (!ok) { emit log_named_uint("  round UNREADABLE", rid); continue; }
            (, int256 px, , uint256 ts, ) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
            if (px <= 0 || ts == 0) continue;
            // Present this REAL round as the anchor's current answer, at its REAL timestamp.
            vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
            // Present the REAL price as of NOW (the warped clock), so `twapResolve`'s 1-day
            // staleness bound sees a fresh answer. The historical `ts` is used only to derive the
            // real GAP above — feeding it as the round's timestamp would make every round stale.
            vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"),
                abi.encode(uint80(rid), px, uint256(0), block.timestamp, uint80(rid)));
            // ⛔ WARP FORWARD BY THE REAL GAP — NEVER BACKWARDS TO THE ROUND'S OWN TIMESTAMP.
            //    Setting `block.timestamp` to the historical `ts` (~10h BEHIND the pinned block)
            //    made every swap revert `0x4e487b71` (Panic): the swap path differences
            //    `block.timestamp` against state stamped at the fork's LATER time, so the
            //    subtraction underflows. The try/catch swallowed it and σ² read 0 — a harness bug
            //    presenting as "the estimator does not work".
            //    ⇒ Keep the real PRICES and the real inter-round GAPS, but run the clock FORWARD
            //      from the fork instant. `_sampleAnchorVariance` only needs `dt` and a MOVING
            //      anchor; it never compares the feed's timestamp to the round's own.
            if (i < nRounds) { uint gap = prevTs == 0 ? 0 : (ts > prevTs ? ts - prevTs : 0);
                               if (gap > 0) vm.warp(block.timestamp + gap); }
            prevTs = ts;
            // ⛔ THE **USD-IN** DIRECTION, NOT THE SELL. `_sampleAnchorVariance()` lives inside
            //    `Core.swap` (Core.sol:989/1041), whose ONLY caller is `BasketLib.sol:526` — and a
            //    volatile-in sell does not reach it. MEASURED with `-vvvv`: the sell shape produced
            //    `Aux::swap` x2, `latestRoundData` x2, and **`Core::swap` ZERO TIMES**, so the
            //    sampler never ran and σ² stayed 0 while every swap reported success. The drain
            //    direction (`inputIsUsd = true`, the shape `_drainEth` uses) does reach it.
            uint256 tinyUsd = 25_000 * 1e18;
            deal(bold, drainer, tinyUsd);
            vm.startPrank(drainer);
            IERC20(bold).approve(address(AUX), tinyUsd);
            bool swapped;
            try AUX.swap(bold, address(WETH), true, tinyUsd, 0, true) { swapped = true; }
            catch (bytes memory e) { emit log_named_bytes("    swap REVERTED", e); }
            vm.stopPrank();
            sigma = ICore(address(CORE)).realizedVarianceWad();
            emit log_named_uint("  round                ", rid);
            emit log_named_uint("    real px (8dec)     ", uint256(px));
            emit log_named_uint("    real ts            ", ts);
            emit log_named_uint("    swap ok (1=yes)    ", swapped ? 1 : 0);
            emit log_named_uint("    sigma^2            ", sigma);
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
        uint256 sigma = _warmVarianceFromRealRounds(12);   // 12 REAL consecutive Chainlink rounds
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
