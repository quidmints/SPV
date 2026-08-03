// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice #12 PREREQUISITE MATRIX — BOTH BANDS. Is the LP-owned claim well defined?
///
/// #12 would credit an LP the band's position MINUS the basket-supplied quoting depth.
/// Three things must be MEASURED before any money-path code moves:
///   1. Is the LP claim ever NEGATIVE? A negative claim means the band bought inventory with
///      basket dollars and the LP kept it — a one-way ratchet in the LP's favour.
///   2. Is VALUE CONSERVED across composition changes and repacks?
///   3. Do the two bands' P&L accumulators stay ISOLATED? A unified `POOLED_USD` must never
///      let one band's flow credit the other band's LPs.
///
/// ⚠️ THE DEFINITION THAT MATTERS (corrected 2026-08-03 after a measurement of mine was wrong).
/// The claim is NOT `POOLED_USD − base`. That single-leg comparison goes negative whenever the
/// band rotates into the volatile leg, which is ordinary curve behaviour and not a transfer —
/// measured: the ETH band's USD leg sat 8,610 BELOW base while its ETH leg was 4.65 ETH ABOVE
/// deposit, i.e. the SAME trade seen from one side only.
///     LP claim  =  band TWO-LEG value  −  basket-supplied capital (at par)
/// which is leg-agnostic, monotone under honest flow, and negative ONLY on a real loss.
///
/// ⚠️ MEASUREMENT TRAPS THIS FILE EXISTS TO AVOID — each already cost a wrong conclusion:
///   • `reseatEpoch` IS NOT A REPACK SIGNAL. It bumps only when the RANGE changes
///     (`VogueLib:519`); a repack onto the same boundaries fires without it. The true signal is
///     `LAST_REPACK` (`Vogue.sol:113`), stamped only under `if (r.didRepack)`.
///   • A LARGE ONE-SHOT SWAP CANNOT REPACK. `rebalanceCore:1620-1629` re-centres only when out
///     of range AND `!isManipulated(spot, twap, 300)` — flow big enough to leave the range also
///     breaks the 300-bps tolerance, so the repack REFUSES and the band strands.
///   • AN UNSEEDED BAND MAKES EVERY ISOLATION ASSERTION VACUOUS. A previous version of this
///     file "proved" cross-band isolation while every BTC field was 0 at both ends, i.e. it
///     asserted 0 == 0. `_seedBoth` now seeds BOTH bands and PREMISE-asserts both are live.
///
/// DECIMALS (`CLAUDE.md`): the WBTC price carries a ×1e10 lift (`usd·1e28`) which closes the
/// 8↔18 gap, so `leg * px / 1e18` is the correct USD18 valuation for BOTH assets — sats×1e28/1e18
/// lands on 1e18 exactly as wei×1e18/1e18 does. Do NOT add a second ×1e10 "to fix BTC".
contract PooledUsdRepackMatrix is Alles {
    address bold; address lp = User02; address trader = User03;
    uint lpShares;
    /// Per-swap warp. 20 min is the default the sibling probes use (lets the observation ring
    /// absorb the move). Scenarios that must keep the Chainlink anchor FRESH lower it: 18 swaps
    /// x 20 min = 6h, past `ASSET_FEED_MAX_AGE = 4 hours`, which makes `twapResolve` fall through
    /// to `(price,false)` and silently disables the auto-heal -- a TEST artefact that masks the
    /// production question.
    uint warpPerSwap = 20 minutes;

    struct Snap {
        uint usdEth;  uint ethLeg;
        uint usdBtc;  uint btcLeg;
        uint committed;
        uint feesPerShare; uint usdFees;
        uint feesPerShareBtc; uint usdFeesBtc;
        uint lastRepack;
        uint64 epoch;
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
        emit log_named_int ("   tick              ", s.tick);
    }

    /// @dev Two-leg value of one band in USD18. Flat `/1e18` on the volatile leg is correct for
    ///      BOTH assets — see the DECIMALS note in the contract docblock.
    function _value(uint volLeg, uint px, uint usdLeg) internal pure returns (uint) {
        return volLeg * px / 1e18 + usdLeg * 1e12;
    }
    function _ethValue(Snap memory s, uint px) internal pure returns (uint) { return _value(s.ethLeg, px, s.usdEth); }
    function _btcValue(Snap memory s, uint px) internal pure returns (uint) { return _value(s.btcLeg, px, s.usdBtc); }

    function _pxEth() internal view returns (uint) { return AUX.getTWAPforAsset(address(WETH), 1800); }
    function _pxBtc() internal view returns (uint) { return AUX.getTWAPforAsset(address(WBTC), 1800); }

    /// Seed BOTH bands. Seeding BTC is what makes every cross-band assertion non-vacuous.
    function _seedBoth(uint ethDeposit, uint sats) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        vm.prank(lp);
        lpShares = V4.deposit{value: ethDeposit}(0, lp);
        require(lpShares > 0, "lp deposit failed");

        // registerBtcLp is gated to BTCChannels; impersonate it exactly as BtcBandTheta does.
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(LP_Alice, sats);
    }

    /// BOLD → WETH: the band SELLS the LP's ETH and takes USD in (grows the ETH-band claim).
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpPerSwap);
    }

    /// ETH in, USD out: the band BUYS ETH back. `size` sets the REGIME — incremental keeps the
    /// band in range, one-shot walks it past the 300-bps repack tolerance and strands it.
    function _sellEth(uint size) internal {
        vm.prank(User01);
        try AUX.swap{value: size}(address(USDC), address(WETH), false, 0, 0) {} catch {}
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpPerSwap);
    }

    /// @dev CONTROL for E7: the same oracle reads at EVERY step, so a degenerate value at the
    ///      tick extreme can be distinguished from a unit I simply misread. Would this
    ///      measurement look the same if I were wrong? -- that is what the t0/t1 rows answer.
    function _oracleTrace(string memory tag) internal {
        (uint rTwap, bool rStale) = AUX.resolvedTwap(address(WETH), 1800);
        (, uint160 sp,) = CORE.poolTicks(false);
        uint spot = _getPrice(sp, V4.token1isETH());
        emit log_string(tag);
        emit log_named_uint("   getTWAPforAsset ", AUX.getTWAPforAsset(address(WETH), 1800));
        emit log_named_uint("   resolvedTwap    ", rTwap);
        emit log_named_uint("   stale?          ", rStale ? 1 : 0);
        emit log_named_uint("   curve spot      ", spot);
        emit log_named_uint("   sqrtPriceX96    ", uint(sp));
        emit log_named_address("   assetPriceFeed  ", AUX.assetPriceFeed(address(WETH)));
    }

    /// @dev The invariant every scenario must satisfy, asserted identically everywhere so a
    ///      scenario cannot quietly opt out of it.
    function _assertClaimsSane(Snap memory s0, Snap memory s1, uint pxE, uint pxB) internal {
        uint baseEth = _ethValue(s0, pxE);
        uint baseBtc = _btcValue(s0, pxB);
        uint nowEth  = _ethValue(s1, pxE);
        uint nowBtc  = _btcValue(s1, pxB);
        emit log_named_uint("ETH band value t0 / t1", baseEth);
        emit log_named_uint("                      ", nowEth);
        emit log_named_uint("BTC band value t0 / t1", baseBtc);
        emit log_named_uint("                      ", nowBtc);
        // NEVER NEGATIVE: the two-leg value must not fall below the capital that was put in.
        // A 2% floor absorbs real fees/slippage paid along the way; a LEAK is what this catches.
        assertGe(nowEth * 100, baseEth * 98, "ETH band: LP claim must not go negative (two-leg value leaked)");
        assertGe(nowBtc * 100, baseBtc * 98, "BTC band: LP claim must not go negative (two-leg value leaked)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S1 — NORMAL FLOW on the ETH band, BTC band live and idle beside it.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S1_EthIncrementalFlow_BothBands() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Snap memory s0 = _snap();
        _log("S1 t0", s0);
        assertGt(s0.usdEth, 0, "PREMISE: ETH band is live");
        assertGt(s0.btcLeg, 0, "PREMISE: BTC band is SEEDED (else every cross-band assertion is vacuous)");

        uint landed;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; landed++; }
        for (uint r = 0; r < 6; r++) _sellEth(4 ether);
        assertGt(landed, 0, "PREMISE: ETH-band flow landed");

        Snap memory s1 = _snap();
        _log("S1 t1", s1);
        _assertClaimsSane(s0, s1, pxE, pxB);

        // CROSS-BAND ISOLATION — now non-vacuous, the BTC band holds real sats.
        assertEq(s1.feesPerShareBtc, s0.feesPerShareBtc, "ETH flow must not move the BTC token-fee accumulator");
        assertEq(s1.usdFeesBtc,      s0.usdFeesBtc,      "ETH flow must not move the BTC USD-fee accumulator");
        assertEq(s1.btcLeg,          s0.btcLeg,          "ETH flow must not move the BTC band's BTC leg");
        assertEq(s1.usdBtc,          s0.usdBtc,          "ETH flow must not move the BTC band's USD leg");
        // The ETH band's own accumulators MUST have moved, else the isolation claim is untested.
        assertTrue(s1.feesPerShare != s0.feesPerShare || s1.usdFees != s0.usdFees,
            "PREMISE: ETH-band accumulators moved");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S2 — BTC band GROWS while the ETH band is live and idle. The mirror of S1:
    // BTC-side activity must not credit ETH LPs.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S2_BtcGrowth_LeavesEthBandUntouched() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Snap memory s0 = _snap();
        _log("S2 t0", s0);
        assertGt(s0.btcLeg, 0, "PREMISE: BTC band is seeded");

        BTC.registerBtcLp(User01, 2e7);
        BTC.registerBtcLp(User03, 1e7);

        Snap memory s1 = _snap();
        _log("S2 t1", s1);
        assertGt(s1.btcLeg, s0.btcLeg, "PREMISE: the BTC band actually grew");
        _assertClaimsSane(s0, s1, pxE, pxB);

        assertEq(s1.feesPerShare, s0.feesPerShare, "BTC growth must not move the ETH token-fee accumulator");
        assertEq(s1.usdFees,      s0.usdFees,      "BTC growth must not move the ETH USD-fee accumulator");
        assertEq(s1.ethLeg,       s0.ethLeg,       "BTC growth must not move the ETH band's ETH leg");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S3 — COMPOUND PATH (the stranding regime). Build an increment with incremental
    // opens FIRST, then hit it with one-shot size. This is the ordering that
    // previously produced tick 887271 (MAX_TICK 887272) with the USD leg at $25 and
    // NO repack after six pokes — the plain one-shot path does NOT reproduce it.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S3_CompoundPath_StrandingRegime() public {
        _seedBoth(400 ether, 2e7);
        Snap memory s0 = _snap();
        _log("S3 t0", s0);
        _oracleTrace("S3 t0 oracle");

        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; }
        Snap memory s1 = _snap();
        _log("S3 t1 (increment built)", s1);
        _oracleTrace("S3 t1 oracle");

        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        V4.reseat();

        Snap memory s2 = _snap();
        _log("S3 t2 (one-shot on top)", s2);
        _oracleTrace("S3 t2 oracle");

        bool outOfRange = s2.tick >= V4.UPPER_TICK() || s2.tick < V4.LOWER_TICK();
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.lastRepack != s0.lastRepack ? 1 : 0);
        emit log_named_int ("UPPER_TICK", V4.UPPER_TICK());
        emit log_named_int ("LOWER_TICK", V4.LOWER_TICK());

        // ── ROOT-CAUSE TRACE. `rebalanceCore` has exactly three ways to decline a re-centre;
        //    read the inputs to each so the blocking branch is IDENTIFIED, not guessed at.
        //      (a) auto-heal  : fires only when `stale` (resolved price fell back to Chainlink)
        //      (b) twap == 0  : bootstrap / dead feed
        //      (c) manipulated: `dev * 10000 > twap * 300` (BasketLib.isManipulated:368)
        (uint rTwap, bool rStale) = AUX.resolvedTwap(address(WETH), 1800);
        (, uint160 sp2,) = CORE.poolTicks(false);
        uint spot2 = _getPrice(sp2, V4.token1isETH());
        emit log_named_uint("(a) resolvedTwap stale?", rStale ? 1 : 0);
        emit log_named_uint("(b) resolvedTwap price ", rTwap);
        emit log_named_uint("    curve spot         ", spot2);
        uint devBps = rTwap == 0 ? 0
            : (spot2 > rTwap ? spot2 - rTwap : rTwap - spot2) * 10000 / rTwap;
        emit log_named_uint("(c) spot deviation bps ", devBps);
        emit log_named_uint("    manipulated @300bps?", rTwap != 0 && devBps > 300 ? 1 : 0);

        // A band left OUT of range MUST have re-centred. If this fails, the stranding is real
        // and `reseat()` cannot recover it — which is the defect E6 needs to fix, not a bad test.
        assertTrue(!outOfRange || s2.lastRepack != s0.lastRepack,
            "a band left OUT OF RANGE must re-centre; stranded-out-of-range is the defect");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S4 — BOTH bands driven together. `AUX.checkBacking()` runs at the head of every
    // deposit and can repack EITHER band (`BasketLib.backingCoreBody:918` picks by
    // `POOLED_USD_ETH >= POOLED_USD_BTC`), so this is the case where a per-band
    // baseline is most exposed and where a unified POOLED_USD must not cross-credit.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S4_BothBandsDriven_NoCrossCredit() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Snap memory s0 = _snap();
        _log("S4 t0", s0);

        for (uint r = 0; r < 6; r++) { if (_open(3_000e18) == 0) break; }
        BTC.registerBtcLp(User01, 2e7);
        for (uint r = 0; r < 3; r++) _sellEth(4 ether);
        BTC.registerBtcLp(User03, 1e7);

        Snap memory s1 = _snap();
        _log("S4 t1", s1);
        _assertClaimsSane(s0, s1, pxE, pxB);

        // The derived-today identity: committed is exactly the two USD legs scaled. THIS IS THE
        // LINE THE #12 SPLIT DELIBERATELY BREAKS — when committed stops tracking POOLED_USD and
        // starts tracking only basket-supplied capital, this assertion MUST be re-derived rather
        // than relaxed. Pinning it now makes that change visible instead of silent.
        assertEq(s1.committed, (s1.usdEth + s1.usdBtc) * 1e12,
            "committedUsd18 == (both USD legs) x 1e12 -- pinned so the #12 split cannot land silently");
    }

    /// Chainlink ETH/USD, 8-dec — the SAME address `script/DeployL1_s.sol:126` pins in production.
    /// Real feed on a mainnet fork, not the `0xE7F0FEED` mock the anchored Alles tests use, because
    /// the question here is specifically what PRODUCTION does.
    address constant CL_ETH_USD_REAL = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ═══════════════════════════════════════════════════════════════════════════
    // S3b — THE CONTROL FOR E7. Identical compound path to S3, but with the WETH
    // Chainlink anchor PINNED exactly as production pins it. This is what decides
    // whether the brick is a real production defect or an artefact of a fixture
    // that ships unanchored:
    //   • self-heals here  ⇒ production is protected; the finding is that the BASE
    //     FIXTURE runs unanchored, so §A.13's fix is untested by ~25 inheriting suites.
    //   • bricks here too  ⇒ §A.13's fix does not cover the price==25 case (it keys on
    //     price==0) and production IS exposed.
    // Either outcome is worth knowing; asserting neither, MEASURING, and reporting.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S3b_CompoundPath_WithProductionAnchor() public {
        _seedBoth(400 ether, 2e7);

        // Pin the anchor the way production does. setAssetFeed is onlyOwner + pin-once.
        AUX.setAssetFeed(address(WETH), CL_ETH_USD_REAL);
        assertEq(AUX.assetPriceFeed(address(WETH)), CL_ETH_USD_REAL,
            "PREMISE: the production Chainlink anchor is pinned, else this is not a control");

        Snap memory s0 = _snap();
        _oracleTrace("S3b t0 oracle (anchored)");

        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; }
        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        V4.reseat();

        Snap memory s2 = _snap();
        _log("S3b t2 (one-shot on top, ANCHORED)", s2);
        _oracleTrace("S3b t2 oracle (anchored)");

        bool outOfRange = s2.tick >= V4.UPPER_TICK() || s2.tick < V4.LOWER_TICK();
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.lastRepack != s0.lastRepack ? 1 : 0);

        assertTrue(!outOfRange || s2.lastRepack != s0.lastRepack,
            "ANCHORED: a band left OUT OF RANGE must re-centre -- if this fails, production is exposed too");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S3c — THE HONEST CONTROL. Anchor pinned AND kept FRESH (18 swaps x 10 min =
    // 3h < ASSET_FEED_MAX_AGE 4h), so `twapResolve` actually reaches its deviation
    // test instead of falling through on age. THIS is the run that decides whether
    // production is exposed. S3b's failure was my own 6h of warping.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S3c_CompoundPath_AnchorPinnedAndFresh() public {
        warpPerSwap = 10 minutes;
        _seedBoth(400 ether, 2e7);
        AUX.setAssetFeed(address(WETH), CL_ETH_USD_REAL);

        Snap memory s0 = _snap();
        _oracleTrace("S3c t0 (anchored + fresh)");

        uint opens;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; opens++; }
        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        V4.reseat();

        Snap memory s2 = _snap();
        _log("S3c t2", s2);
        _oracleTrace("S3c t2 (anchored + fresh)");
        emit log_named_uint("opens landed", opens);
        emit log_named_uint("hours warped", (block.timestamp - s0.lastRepack) / 3600);

        bool outOfRange = s2.tick >= V4.UPPER_TICK() || s2.tick < V4.LOWER_TICK();
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.lastRepack != s0.lastRepack ? 1 : 0);

        assertTrue(!outOfRange || s2.lastRepack != s0.lastRepack,
            "ANCHORED+FRESH: out-of-range band must re-centre -- failing here means PRODUCTION is exposed");
    }
}
