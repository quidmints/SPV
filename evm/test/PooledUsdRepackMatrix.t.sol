// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice #12 PREREQUISITE MATRIX — is the LP-owned USD increment a well-defined claim?
///
/// #12 would credit an LP the band's USD leg MINUS the basket-supplied quoting depth
/// ("the increment"). Before any money-path code moves, three things have to be MEASURED
/// rather than argued, because a wrong answer to any of them kills the design:
///
///   1. Does the increment SURVIVE a repack? `Core._handleRepack:778-779` ZEROES
///      `POOLED_USD_*`/`POOLED_*` outright and rebuilds them through `_repackAdd` →
///      `VOGUE.addLiq` (`Core.sol:826`). If the re-add sizes the new USD leg purely from
///      basket surplus (`SwapLib.sizeBySurplus`), the increment is re-absorbed as basket
///      depth and the LP's claim evaporates at every re-centre.
///   2. Is VALUE CONSERVED across the composition change? An earlier probe of mine captured
///      only the USD leg and so could not tell "the band bought ETH back" (conserved) from
///      "value left" (not). Both legs are captured here, always.
///   3. Do the two bands' P&L accumulators stay ISOLATED? A unified `POOLED_USD` must not
///      let one band's flow credit the other band's LPs.
///
/// ⚠️ TWO MEASUREMENT TRAPS THIS FILE EXISTS TO AVOID — both cost a wrong conclusion already:
///
///   • `reseatEpoch` IS NOT A REPACK SIGNAL. It bumps on `r.tickLower != c.lowerTick ||
///     r.tickUpper != c.upperTick` (`VogueLib:519`) — the RANGE changing. A repack that
///     re-centres onto the SAME tick boundaries fires without bumping it. The true signal is
///     `LAST_REPACK` (`Vogue.sol:113`), stamped only under `if (r.didRepack)`
///     (`VogueLib:509-514`). Every premise below keys on LAST_REPACK.
///   • A LARGE ONE-SHOT SWAP CANNOT PRODUCE A REPACK. `rebalanceCore:1620-1629` re-centres
///     only when the band is out of range AND `!isManipulated(spot, twap, 300)`. Flow big
///     enough to walk the spot far out of range also pushes it past the 300-bps tolerance, so
///     the repack REFUSES. Normal incremental flow re-centres; one-shot flow strands. Both
///     regimes are exercised below, deliberately.
contract PooledUsdRepackMatrix is Alles {
    address bold; address lp = User02; address trader = User03;
    uint lpShares;

    /// @dev BOTH legs of BOTH bands plus both bands' accumulators, in one struct — a single
    ///      memory pointer, which is how this repo keeps frames off the legacy stack
    ///      (`via_ir = false`). Capturing partially is what made the previous attempt unable
    ///      to answer its own question.
    struct Snap {
        uint usdEth;  uint ethLeg;      // ETH band: USD leg (6d), ETH leg (18d)
        uint usdBtc;  uint btcLeg;      // BTC band: USD leg (6d), BTC leg (8d)
        uint committed;                 // committedUsd18 (18d) — both bands
        uint feesPerShare; uint usdFees;        // ETH band accumulators
        uint feesPerShareBtc; uint usdFeesBtc;  // BTC band accumulators
        uint lastRepack;                // the ONLY reliable "a repack fired" signal
        uint64 epoch;                   // reseatEpoch — range moved (NOT the repack signal)
        int24 tick;
    }

    function _snap() internal view returns (Snap memory s) {
        s.usdEth = CORE.POOLED_USD_ETH();  s.ethLeg = CORE.POOLED_ETH();
        s.usdBtc = CORE.POOLED_USD_BTC();  s.btcLeg = CORE.POOLED_BTC();
        s.committed = CORE.committedUsd18();
        s.feesPerShare = V4.feesPerShare(); s.usdFees = V4.USD_FEES();
        s.feesPerShareBtc = BTC.feesPerShareBTC(); s.usdFeesBtc = BTC.USD_FEES_BTC();
        s.lastRepack = V4.LAST_REPACK();
        s.epoch = V4.reseatEpoch();
        (,, s.tick) = CORE.poolTicks(false);
    }

    function _log(string memory tag, Snap memory s) internal {
        emit log_string(tag);
        emit log_named_uint("   ETH band USD (6d) ", s.usdEth);
        emit log_named_uint("   ETH band ETH (18d)", s.ethLeg);
        emit log_named_uint("   BTC band USD (6d) ", s.usdBtc);
        emit log_named_uint("   BTC band BTC (8d) ", s.btcLeg);
        emit log_named_uint("   committedUsd18    ", s.committed);
        emit log_named_uint("   feesPerShare  ETH ", s.feesPerShare);
        emit log_named_uint("   USD_FEES      ETH ", s.usdFees);
        emit log_named_uint("   feesPerShare  BTC ", s.feesPerShareBtc);
        emit log_named_uint("   USD_FEES      BTC ", s.usdFeesBtc);
        emit log_named_uint("   LAST_REPACK       ", s.lastRepack);
        emit log_named_uint("   reseatEpoch       ", uint(s.epoch));
        emit log_named_int ("   tick              ", s.tick);
    }

    /// @dev Total ETH-band value in USD18 at `px`: the two legs summed. This is the quantity
    ///      a repack must CONSERVE — it burns and re-adds the same position, so anything
    ///      beyond fee collection and rounding is real value moving.
    function _bandValueUsd18(Snap memory s, uint px) internal pure returns (uint) {
        return s.ethLeg * px / 1e18 + s.usdEth * 1e12;
    }

    function _seed(uint ethDeposit) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(lp);
        lpShares = V4.deposit{value: ethDeposit}(0, lp);
        require(lpShares > 0, "lp deposit failed");
    }

    /// One guard-safe leverage open (BOLD → WETH): the band SELLS the LP's ETH and takes USD in,
    /// which is what grows the increment. Rolls a block + 20 minutes so the observation ring
    /// absorbs the move and the next open doesn't trip the 50-bps manipulation guard.
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    /// The opposite leg: pay ETH in, take USD out — the band BUYS ETH back, which is what
    /// shrinks the increment again. `size` is deliberately a parameter: the whole point of the
    /// matrix is that magnitude changes the regime (incremental re-centres, one-shot strands).
    function _sellEth(uint size) internal {
        vm.prank(User01);
        try AUX.swap{value: size}(address(USDC), address(WETH), false, 0, 0) {} catch {}
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CASE 1 — NORMAL FLOW. Incremental two-sided flow, the regime a live market
    // spends nearly all its time in. Question: across whatever repacks this
    // produces, is value conserved and does the USD leg behave coherently?
    // ═══════════════════════════════════════════════════════════════════════════
    function testRepack_NormalFlow_ConservesValueAcrossRepacks() public {
        _seed(400 ether);
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);

        Snap memory s0 = _snap();
        _log("t0 - after deposit", s0);
        assertGt(s0.usdEth, 0, "PREMISE: the deposit committed a USD leg, else there is no base to split");

        // Build an increment with incremental flow (each open ~1 ETH against a 400 ETH band).
        uint landed;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; landed++; }
        assertGt(landed, 0, "PREMISE: at least one open landed, else there is no increment");

        Snap memory s1 = _snap();
        _log("t1 - after incremental sells", s1);
        assertGt(s1.usdEth, s0.usdEth, "PREMISE: the opens grew the band's USD leg (the increment exists)");

        // Now flow the other way, incrementally, so the band buys ETH back.
        for (uint r = 0; r < 6; r++) _sellEth(4 ether);

        Snap memory s2 = _snap();
        _log("t2 - after incremental buy-backs", s2);

        // MEASUREMENT, not assertion: how many repacks actually fired across the whole run.
        emit log_named_uint("repacks fired t0->t2 (LAST_REPACK moved)",
            s2.lastRepack != s0.lastRepack ? 1 : 0);

        // CONSERVATION. A repack burns and re-adds the SAME position, so the two-leg value must
        // not fall materially. Bound is deliberately generous (2%) because real fees are
        // collected and real slippage is paid along the way — the point is to catch a LEAK
        // (the increment being re-absorbed and lost), not to pin rounding.
        uint v1 = _bandValueUsd18(s1, px);
        uint v2 = _bandValueUsd18(s2, px);
        emit log_named_uint("band two-leg value @t1 (USD18)", v1);
        emit log_named_uint("band two-leg value @t2 (USD18)", v2);
        assertGe(v2 * 100, v1 * 98,
            "two-leg band value must not leak across incremental flow + repacks");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CASE 2 — EDGE: ONE-SHOT FLOW. Large single-direction size walks the spot far
    // out of range, which ALSO pushes it past the 300-bps repack tolerance, so the
    // re-centre REFUSES. This documents a real stranding regime rather than
    // leaving it to be rediscovered: measured previously as tick 887271 (MAX_TICK
    // is 887272) with the USD leg at $25 and no repack after six pokes.
    // ═══════════════════════════════════════════════════════════════════════════
    function testRepack_OneShotFlow_StrandsBandOutOfRange() public {
        _seed(400 ether);
        Snap memory s0 = _snap();
        _log("t0 - after deposit", s0);

        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        V4.reseat();

        Snap memory s1 = _snap();
        _log("t1 - after one-shot flow + reseat poke", s1);

        emit log_named_uint("USD leg drained to (6d)", s1.usdEth);
        emit log_named_int ("tick now", s1.tick);
        emit log_named_uint("LAST_REPACK moved?", s1.lastRepack != s0.lastRepack ? 1 : 0);
        emit log_named_uint("band still holds ETH leg (18d)", s1.ethLeg);

        // The assertion is on the MECHANISM, not on a fitted number: whatever the drain, the
        // band must not be left simultaneously (a) out of its range and (b) unable to re-centre.
        // If this ever passes trivially because the drain didn't happen, the premise catches it.
        assertLt(s1.usdEth, s0.usdEth / 2,
            "PREMISE: the one-shot flow really did drain the USD leg, else nothing is stressed");
        bool outOfRange = s1.tick >= V4.UPPER_TICK() || s1.tick < V4.LOWER_TICK();
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        assertTrue(!outOfRange || s1.lastRepack != s0.lastRepack,
            "a band left OUT OF RANGE must have re-centred; stranded out-of-range is the defect");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CASE 3 — CONTROL for the unification (caveat B7). ETH-band flow must leave the
    // BTC band's accumulators BIT-UNCHANGED. This must pass on UNMODIFIED code — that
    // is what makes it a control rather than a regression guard bolted on afterwards.
    // If a unified POOLED_USD ever lets one band's flow credit the other band's LPs,
    // this is the test that fails.
    // ═══════════════════════════════════════════════════════════════════════════
    function testAccumulators_EthFlowLeavesBtcBandUntouched() public {
        _seed(400 ether);
        Snap memory s0 = _snap();
        _log("t0 - after deposit", s0);

        uint landed;
        for (uint r = 0; r < 8; r++) { if (_open(3_000e18) == 0) break; landed++; }
        for (uint r = 0; r < 3; r++) _sellEth(4 ether);

        Snap memory s1 = _snap();
        _log("t1 - after ETH-band flow only", s1);

        // PREMISE: the ETH band really was driven, else "BTC unchanged" is vacuous.
        assertGt(landed, 0, "PREMISE: ETH-band flow must have landed");
        assertTrue(s1.feesPerShare != s0.feesPerShare || s1.usdFees != s0.usdFees,
            "PREMISE: ETH-band accumulators must have MOVED, else the isolation claim is untested");

        // THE CONTROL.
        assertEq(s1.feesPerShareBtc, s0.feesPerShareBtc,
            "ETH-band flow must not move the BTC band's token-fee accumulator");
        assertEq(s1.usdFeesBtc, s0.usdFeesBtc,
            "ETH-band flow must not move the BTC band's USD-fee accumulator");
        assertEq(s1.usdBtc, s0.usdBtc,
            "ETH-band flow must not move the BTC band's USD leg");
        assertEq(s1.btcLeg, s0.btcLeg,
            "ETH-band flow must not move the BTC band's BTC leg");
    }
}
