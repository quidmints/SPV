// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface ISPq { function getCompoundedBoldDeposit(address) external view returns (uint); }

/// @notice Quantifies the leverage externality on passive LPs — the analysis
///   recorded in memory project-quid-leverage-liquity.md (CORRECTION 2026-06-22).
///
///   On the QU!D side a leveraged-LP OPEN is a BOLD->WETH swap: the trader sheds
///   BOLD into the protocol's backing (Liquity SP) and pulls WETH out of the LP
///   pool. We measure two things on a mainnet fork:
///     (1) the BOLD-ACCUMULATION curve under repeated guard-safe opens, and
///     (2) the LVR / value-transfer to passive LPs via a rigorous control-vs-
///         treatment design (same final ETH price; difference = pure leverage cost).
///
///   LP value is measured TOTAL (both legs): redeem the LP in a snapshot and value
///   ETH-leg (at the scenario price) + QUID-leg ($1). Valuing the redeemed assets at
///   the scenario price sidesteps pool-reseat machinery AND the forked-SP BOLD-out
///   limitation (no unwind leg needed — the open + revaluation already captures the
///   directional transfer, since the open converts the LP's ETH-side to USD-side).
contract LeveragePnLProbe is Alles {
    address bold; address sp; address lp = User02; address trader = User03;
    uint lpShares;

    function _seed(uint ethDeposit) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        sp   = AUX.getVaults(bold)[0];
        // SEED THE BASKET FIRST — $1M of stable backing, the same seed every sibling band probe
        // uses (`LevCascade._seedBasket`, `LeverageCrossSubsidyProbe._seedBasket`).
        //
        // Without it this file had NO stable backing at all: the shared fixture arrives with about
        // $156k of basket TVL, while a 400-ETH LP deposit needs the band to commit roughly $1.5M of
        // USD in range. `Core._poolUsdInRange` then trips `require(committedUsd18() <= haircutTvl,
        // "backing")` (src/Core.sol:1016) on the FIRST swap, so `_open` caught the revert, returned
        // 0, and both loops below `break`d on round one. Every measurement in this file — the whole
        // accumulation curve, the entire control-vs-treatment design — was computed over ZERO
        // executed opens, and both tests reported PASS because neither asserted anything. Seeding
        // is what makes the opens executable; it is not what makes the assertions pass.
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(lp);
        lpShares = V4.deposit{value: ethDeposit}(0, lp);
        require(lpShares > 0, "lp deposit failed");
    }

    /// One guard-safe leverage open. Returns WETH out, or 0 on revert (e.g. guard).
    /// `boldSpent` is measured, not assumed: `swap` may partially fill (#101
    /// degrade-to-partial-fill), so the trader can be left holding change.
    uint lastBoldSpent;
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);          // deal SETS the balance, so leftover == change
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        lastBoldSpent = boldAmt - IERC20(bold).balanceOf(trader);
        // Let the observation ring absorb the move so the next open doesn't trip the
        // 50bps manip guard (spot reconverges toward the 30-min TWAP).
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    uint constant SP_SENTINEL = type(uint).max;
    function _spBold() internal view returns (uint) {
        try ISPq(sp).getCompoundedBoldDeposit(address(AUX)) returns (uint v) { return v; } catch { return SP_SENTINEL; }
    }
    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }

    /// @dev Band/basket state at one instant. Emitted rather than returned so the caller
    ///      keeps no locals — this measurement is what decides #12's ownership question.
    function _snapshotBands(string memory when) internal {
        emit log_string(when);
        emit log_named_uint("   POOLED_USD_ETH", CORE.POOLED_USD_ETH());
        emit log_named_uint("   POOLED_ETH    ", CORE.POOLED_ETH());
        emit log_named_uint("   vogueETH      ", AUX.vogueETH());
        emit log_named_uint("   basketUsdEth  ", CORE.basketUsdEth());
        emit log_named_uint("   lpShares      ", V4.lpShares());
        emit log_named_uint("   totalLevPooled", V4.totalLevPooled());
        emit log_named_uint("   basket TVL    ", _tvl());
        emit log_named_uint("   committedUsd18", CORE.committedUsd18());
    }

    /// TOTAL LP value in USD18 at a given ETH price (USD18 per 1e18 ETH): redeem the
    /// LP in a snapshot, value both legs (ETH + QUID), then revert.
    function _lpValueUsd(uint ethPx18) internal returns (uint usd) {
        uint snap = vm.snapshotState();
        uint eth0 = lp.balance; uint weth0 = WETH.balanceOf(lp); uint q0 = QUID.balanceOf(lp);
        vm.prank(lp);
        try V4.redeem(lpShares, lp, lp) {} catch {}
        uint ethG  = (lp.balance - eth0) + (WETH.balanceOf(lp) - weth0);
        uint quidG = QUID.balanceOf(lp) - q0;
        emit log_named_uint("  leg ETH (wei)", ethG);
        emit log_named_uint("  leg QUID(18d)", quidG);
        usd = ethG * ethPx18 / 1e18 + quidG;
        vm.revertToState(snap);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (1) BOLD accumulation curve under repeated guard-safe opens (flat market).
    // ───────────────────────────────────────────────────────────────────────────
    function testLeverage_BoldAccumulationCurve() public {
        _seed(400 ether);
        uint spStart = _spBold();
        emit log_named_uint("TVL18 @start", _tvl());
        emit log_named_uint("BOLD in SP @start (18d)", spStart);
        // PREMISE 0: the Liquity SP leg must be READABLE on this fork. `_spBold` swallows a
        // revert into SP_SENTINEL, and every "BOLD accumulated" reading below would then be
        // type(uint).max — a number that satisfies any growth check while measuring nothing.
        assertTrue(spStart != SP_SENTINEL, "PREMISE: the Liquity SP deposit must be readable, else nothing is measured");

        uint perOpen = 4_000e18; // ~1.3 ETH out on a 400-ETH pool => <0.5% move
        uint landed; uint boldSpent; uint prevSp = spStart;
        for (uint r = 1; r <= 25; r++) {
            uint w = _open(perOpen);
            if (w == 0) { emit log_named_uint("open tripped guard / reverted at round", r); break; }
            landed++; boldSpent += lastBoldSpent;
            uint spNow = _spBold();
            // SAFETY (the curve this test is NAMED for): the protocol has no mechanism that
            // sheds the BOLD a leveraged open pays it — so the SP balance must never fall.
            // A DROP here means something is shedding/losing BOLD backing round-to-round,
            // which is precisely the accumulation story being falsified.
            assertGe(spNow, prevSp, "BOLD in the SP must never DECREASE (nothing sheds it)");
            prevSp = spNow;
            if (r % 5 == 0 || r == 1) {
                uint tvl = _tvl();
                emit log_named_uint("round", r);
                emit log_named_uint("   BOLD in SP (18d)",    spNow);
                emit log_named_uint("   BOLD % of TVL (bps)", tvl > 0 ? (spNow * 10_000) / tvl : 0);
                emit log_named_uint("   POOLED_ETH",          CORE.POOLED_ETH());
            }
        }
        uint spEnd = _spBold();
        emit log_named_uint("opens that landed", landed);
        emit log_named_uint("BOLD spent by the trader (18d)", boldSpent);
        emit log_named_uint("BOLD accumulated in the SP (18d)", spEnd - spStart);

        // PREMISE 1: at least one open must LAND. The loop `break`s on the first revert, so a
        // guard that trips on round 1 leaves an empty curve — and "BOLD never decreased" would
        // be trivially true over zero rounds.
        assertGt(landed, 0, "PREMISE: at least one leverage open must land, else there is no curve");
        // PREMISE 2: those opens must have actually MOVED BOLD. A landed swap that spent no
        // BOLD (full partial-fill degradation) accumulates nothing to reason about.
        assertGt(boldSpent, 0, "PREMISE: the opens must actually spend BOLD into the protocol");

        // SAFETY: the BOLD the trader paid must ARRIVE in backing. The open is a sale — the
        // trader hands over BOLD and takes WETH out of the LP pool — so if the SP grows by
        // materially less than was spent, the difference is value that left the LP's ETH side
        // and never landed on the basket's stable side. Bound is the MEASURED spend, and the
        // 1% allowance covers Liquity's own deposit accounting, not a fudge for a shortfall.
        assertGe(spEnd - spStart, boldSpent * 99 / 100,
            "the BOLD paid by leverage opens must land in the SP, not evaporate between the legs");
        // SAFETY: 25 rounds of shedding an un-depeg-fed stable into backing must not leave the
        // basket under-collateralised. checkBacking REVERTS on violation, so it is an assertion.
        AUX.checkBacking();
        emit log_string("=> BOLD accumulates monotonically; earmark would PIN it; BOLD has NO depeg feed.");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (2) LVR / value transfer: control (no opens) vs treatment (N opens), valued at
    //     the SAME final ETH price. Difference = pure leverage externality on the LP.
    // ───────────────────────────────────────────────────────────────────────────
    function testLeverage_LvrControlVsTreatment() public {
        _seed(400 ether);
        uint px0 = AUX.getTWAPforAsset(address(WETH), 1800); // USD18 per 1e18 ETH
        emit log_named_uint("ETH px0 (USD18)", px0);

        uint snap0 = vm.snapshotState();

        // Treatment: accumulate guard-safe opens, then value the LP at 3 final prices.
        uint landed;
        // Emitted, not stored: five `before` locals blew the stack here, and the repo's rule is to
        // shed locals rather than reach for via_ir.
        _snapshotBands("before");
        for (uint r = 0; r < 20; r++) { if (_open(3_000e18) == 0) break; landed++; }
        emit log_named_uint("treatment opens landed", landed);
        _snapshotBands("after ");
        emit log_named_uint("BOLD accumulated (18d)", _spBold());
        uint tUp   = _lpValueUsd(px0 * 120 / 100);
        uint tFlat = _lpValueUsd(px0);
        uint tDown = _lpValueUsd(px0 * 80 / 100);

        // Control: same starting pool, NO opens — but TIME-MATCHED to the treatment.
        //
        // `vm.revertToState(snap0)` also rewinds block.number/timestamp to the seed, and
        // `Vogue.withdraw` enforces `block.number > lastDepositBlock[msg.sender]` ("too soon",
        // Vogue.sol:540 — the JIT-deposit guard). The treatment rolls a block per `_open`, so its
        // three redeems clear the guard while the control's REVERTED with "too soon" and
        // `_lpValueUsd`'s try/catch turned that into 0 — which is precisely what PREMISE 2 below
        // exists to catch, and it did.
        //
        // Restoring the treatment's final block/timestamp makes this an actual control: opens are
        // then the ONLY variable between the two arms. Leaving it un-matched compared an aged pool
        // against a brand-new one and called the difference a leverage externality.
        uint tBlock = block.number;
        uint tTime  = block.timestamp;
        vm.revertToState(snap0);
        vm.roll(tBlock);
        vm.warp(tTime);
        uint cUp   = _lpValueUsd(px0 * 120 / 100);
        uint cFlat = _lpValueUsd(px0);
        uint cDown = _lpValueUsd(px0 * 80 / 100);

        emit log_string("scenario | control USD18 | treatment USD18 | externality bps (treat-ctrl)/ctrl");
        _report("ETH +20%", cUp, tUp);
        _report("ETH flat ", cFlat, tFlat);
        _report("ETH -20%", cDown, tDown);
        emit log_string("Expect: +20% => LP WORSE (LVR out); -20% => LP BETTER; flat => ~fees. LP is short the position.");

        // PREMISE 1: the treatment must actually BE a treatment. `_open` swallows a guard
        // revert into wethOut==0 and the loop `break`s, so a guard trip on round 0 makes
        // treatment and control the same scenario — every comparison below then reduces to
        // `x vs x` and passes while measuring nothing.
        assertGt(landed, 0, "PREMISE: at least one leverage open must land, else treatment == control");
        // PREMISE 2: the LP valuation must be REAL. `_lpValueUsd` wraps `V4.redeem` in a
        // try/catch and returns 0 when it reverts — with all six legs at 0 every inequality
        // below holds vacuously. This is the exact hazard that let a zero-delivery redeem hide
        // in `testDD`. Require delivery on all six measurements.
        assertGt(cFlat, 0, "PREMISE: the CONTROL LP redeem must deliver, else nothing is valued");
        assertGt(tFlat, 0, "PREMISE: the TREATMENT LP redeem must deliver, else nothing is valued");
        assertGt(cUp, 0, "PREMISE: control +20% valuation must be non-zero");
        assertGt(tUp, 0, "PREMISE: treatment +20% valuation must be non-zero");
        assertGt(cDown, 0, "PREMISE: control -20% valuation must be non-zero");
        assertGt(tDown, 0, "PREMISE: treatment -20% valuation must be non-zero");
        // PREMISE 3: the opens must have actually CONVERTED the LP's ETH side to USD side —
        // that conversion IS the mechanism under study. Because `_lpValueUsd` values the same
        // redeemed bundle at three prices, (up - down) is exactly 0.4 x px0 x the ETH the LP
        // gets back, so a strictly smaller spread in the treatment is a direct measurement of
        // a smaller ETH leg. If the spreads match, the band never sold and there is no LVR to
        // measure regardless of what the totals say.
        assertLt(tUp - tDown, cUp - cDown,
            "PREMISE: the opens must shrink the LP's ETH leg, else no value transfer occurred");

        // SAFETY: at UNCHANGED price the passive LP must not be left worse off. Up and down
        // moves produce a legitimate two-sided LVR/inventory effect (the LP is short the
        // position by construction and the +20% leg is EXPECTED to be negative — that is a
        // property of AMM inventory, not a defect). The flat leg has no such excuse: the LP
        // sold ETH into the opens at or above mid and collected fees, so if it still comes out
        // behind the control, leverage flow is extracting value from passive liquidity outright.
        assertGe(tFlat, cFlat,
            "at UNCHANGED ETH price, leverage flow must not leave the passive LP worse off than no flow");
        // SAFETY: the other side of the same inventory shift must be present, not just absent
        // harm — having sold ETH into the opens, the treatment LP must be strictly better off
        // in a drawdown. Together with the flat leg this pins the sign of the externality
        // instead of merely bounding its size.
        assertGt(tDown, cDown,
            "having sold ETH into the opens, the LP must be BETTER off in a drawdown (short the position)");
    }

    function _report(string memory tag, uint ctrl, uint treat) internal {
        emit log_named_string("scenario", tag);
        emit log_named_uint("  control USD18",   ctrl);
        emit log_named_uint("  treatment USD18", treat);
        int bps = ctrl > 0 ? (int(treat) - int(ctrl)) * 10_000 / int(ctrl) : int(0);
        emit log_named_int ("  externality bps", bps);
    }
}
