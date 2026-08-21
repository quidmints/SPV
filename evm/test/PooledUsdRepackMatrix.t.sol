// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ICore} from "../src/imports/Interfaces.sol";
import {Core} from "../src/Core.sol";

/// @notice #12 PREREQUISITE MATRIX — BOTH RANGES. Is the LP-owned claim well defined?
///
/// #12 would credit an LP the range's position MINUS the basket-supplied quoting depth.
/// Three things must be MEASURED before any money-path code moves:
///   1. Is the LP claim ever NEGATIVE? A negative claim means the range bought inventory with
///      basket dollars and the LP kept it — a one-way ratchet in the LP's favour.
///   2. Is VALUE CONSERVED across composition changes and repacks?
///   3. Do the two ranges' P&L accumulators stay ISOLATED? A unified `POOLED_USD` must never
///      let one range's flow credit the other range's LPs.
///
/// ⚠️ THE DEFINITION THAT MATTERS (corrected 2026-08-03 after a measurement of mine was wrong).
/// The claim is NOT `POOLED_USD − base`. That single-leg comparison goes negative whenever the
/// range rotates into the volatile leg, which is ordinary curve behaviour and not a transfer —
/// measured: the ETH range's USD leg sat 8,610 BELOW base while its ETH leg was 4.65 ETH ABOVE
/// deposit, i.e. the SAME trade seen from one side only.
///     LP claim  =  range TWO-LEG value  −  basket-supplied capital (at par)
/// which is leg-agnostic, monotone under honest flow, and negative ONLY on a real loss.
///
/// ⚠️ MEASUREMENT TRAPS THIS FILE EXISTS TO AVOID — each already cost a wrong conclusion:
///   • `reseatEpoch` IS NOT A REPACK SIGNAL. It bumps only when the RANGE changes
///     (`QuidLib:519`); a repack onto the same boundaries fires without it. The true signal is
///     `LAST_REPACK` (`Quid.sol:113`), stamped only under `if (r.didRepack)`.
///   • A LARGE ONE-SHOT SWAP CANNOT REPACK. `rebalanceCore:1620-1629` re-centres only when out
///     of range AND `!isManipulated(spot, twap, 300)` — flow big enough to leave the range also
///     breaks the 300-bps tolerance, so the repack REFUSES and the range strands.
///   • AN UNSEEDED RANGE MAKES EVERY ISOLATION ASSERTION VACUOUS. A previous version of this
///     file "proved" cross-range isolation while every BTC field was 0 at both ends, i.e. it
///     asserted 0 == 0. `_seedBoth` now seeds BOTH ranges and PREMISE-asserts both are live.
///
/// DECIMALS (`CLAUDE.md`): the WBTC price carries a ×1e10 lift (`usd·1e28`) which closes the
/// 8↔18 gap, so `leg * px / 1e18` is the correct USD18 valuation for BOTH assets — sats×1e28/1e18
/// lands on 1e18 exactly as wei×1e18/1e18 does. Do NOT add a second ×1e10 "to fix BTC".
contract PooledUsdRepackMatrix is AllesFixture {
    address bold; address lp = User02; address trader = User03;
    /// Per-swap warp. 20 min is the default the sibling probes use (lets the observation ring
    /// absorb the move). Scenarios that must keep the Chainlink anchor FRESH lower it: 18 swaps
    /// x 20 min = 6h, past `ASSET_FEED_MAX_AGE = 4 hours`, which makes `twapResolve` fall through
    /// to `(price,false)` and silently disables the auto-heal -- a TEST artefact that masks the
    /// production question.
    uint warpPerSwap = 20 minutes;

    /// §ONE-PER-INSTANCE — ONE field per concept, and a Snap is of ONE RANGE. The previous version
    /// carried `usdEth`/`usdBtc`, `feesPerShareEth`/`feesPerShareBtc` and so on: four names for two
    /// concepts, mirroring in the fixture exactly the duplication the contracts just deleted. A range
    /// manager owns one `feesPerShare` and one `USD_FEES`; two ranges means two SNAPSHOTS, not two
    /// fields. `_snap(range)` takes the instance, so the range-qualified spelling cannot be written.
    ///
    /// 🔴 AND THE OLD SHAPE HID A LIVE DEFECT. `usdBtc`/`btcLeg` were assigned from `CORE` -- the
    /// ETH engine -- because `Vault.CORE` was `internal` and `ICore` had no `core()`, so the
    /// BTC engine was UNREACHABLE from a test. Every "ETH flow must not move the BTC range's USD
    /// leg" assertion therefore compared a value to ITSELF. Both are now read through
    /// `ICore(range).CORE()`, which is why that accessor was made public.
    ///
    /// `epoch` is DELETED: a keccak of (LOWER_PRICE, UPPER_PRICE) that nothing asserted on. The
    /// bounds it hashed are read directly where they are wanted, and a hash of two values you can
    /// print is a worse instrument than the two values.
    struct Snap {
        uint usd;  uint leg;
        uint committed;
        uint feesPerShare; uint usdFees;
        uint lastRepack;
        uint price;   // §DETICK: was `tick`; it holds a PRICE now and the name said otherwise
    }

    /// @param range the range manager to snapshot. ONE instance in, one Snap out.
    function _snap(ICore range) internal view returns (Snap memory s) {
        Core c = Core(payable(range.CORE()));
        s.usd = c.POOLED_USD();  s.leg = c.POOLED();
        s.committed = c.committedUsd18();          // joint by construction; same on both ranges
        s.feesPerShare = range.feesPerShare(); s.usdFees = range.USD_FEES();
        (s.price,) = c.poolStats();                // was CALLED AND DISCARDED, leaving `price` at 0
    }
    /// Both ranges, each read through ITS OWN engine. `Snap` stays one-per-instance; this is two
    /// INSTANCES of it, which is the distinction the whole refactor turns on.
    struct Pair { Snap eth; Snap btc; }
    function _snap() internal view returns (Pair memory p) {
        p.eth = _snap(ICore(address(ETH)));
        p.btc = _snap(ICore(address(BTC)));
        // §ONE-REPACK-STAMP — ETH ONLY, and deliberately not mirrored. `LAST_REPACK` exists on
        // Quid and not on Vault, which looks like an asymmetry to close until you check who reads
        // it: NO CONTRACT DOES. It is stamped by the rebalance forwarder and consumed only by
        // tests. Giving Vault one would add money-path state to make a test observable symmetric,
        // which is backwards -- the direction here is fewer variables, not matching sets of them.
        // If a BTC repack ever needs to be observable, that is when the second stamp earns its slot.
        p.eth.lastRepack = ETH.LAST_REPACK();
    }

    function _log(string memory tag, Pair memory s) internal {
        emit log_string(tag);
        emit log_named_uint("   ETH range USD (6d) ", s.eth.usd);
        emit log_named_uint("   ETH range ETH (18d)", s.eth.leg);
        emit log_named_uint("   BTC range USD (6d) ", s.btc.usd);
        emit log_named_uint("   BTC range BTC (8d) ", s.btc.leg);
        emit log_named_uint("   committedUsd18    ", s.eth.committed);
        emit log_named_uint("   feesPerShare  ETH ", s.eth.feesPerShare);
        emit log_named_uint("   USD_FEES      ETH ", s.eth.usdFees);
        emit log_named_uint("   feesPerShare  BTC ", s.btc.feesPerShare);
        emit log_named_uint("   USD_FEES      BTC ", s.btc.usdFees);
        emit log_named_uint("   LAST_REPACK   ETH ", s.eth.lastRepack);
        emit log_named_uint("   price         ETH ", s.eth.price);
        emit log_named_uint("   price         BTC ", s.btc.price);
    }

    /// @dev Two-leg value of one range in USD18. Flat `/1e18` on the volatile leg is correct for
    ///      BOTH assets — see the DECIMALS note in the contract docblock.
    function _value(uint volLeg, uint px, uint usdLeg) internal pure returns (uint) {
        return volLeg * px / 1e18 + usdLeg * 1e12;
    }
    function _ethValue(Pair memory s, uint px) internal pure returns (uint) { return _value(s.eth.leg, px, s.eth.usd); }
    function _btcValue(Pair memory s, uint px) internal pure returns (uint) { return _value(s.btc.leg, px, s.btc.usd); }

    function _pxEth() internal view returns (uint) { return AUX.getTWAPforAsset(address(WETH), 1800); }
    function _pxBtc() internal view returns (uint) { return AUX.getTWAPforAsset(address(WBTC), 1800); }

    /// Seed BOTH ranges. Seeding BTC is what makes every cross-range assertion non-vacuous.
    function _seedBoth(uint ethDeposit, uint sats) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        vm.prank(lp);
        // §NO-SHADOW-STATE — was a CONTRACT-level `uint lpShares`, written here and read only on
        // the next line. A local doing a state variable's job, wearing the name of the range state it
        // is not: `ETH.lpShares()` is the real one, and a reader had two things called lpShares to
        // tell apart for no gain. The deposit's return is what this line actually wants.
        require(ETH.deposit{value: ethDeposit}(0, lp) > 0, "lp deposit failed");

        // requestDeposit is gated to BTCChannels; impersonate it exactly as BtcRangeTheta does.
        AUX.setBTCChannels(address(this));
        BTC.requestDeposit(LP_Alice, sats);
    }

    /// BOLD → WETH: the range SELLS the LP's ETH and takes USD in (grows the ETH-range claim).
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpPerSwap);
    }

    /// ETH in, USD out: the range BUYS ETH back. `size` sets the REGIME — incremental keeps the
    /// range in range, one-shot walks it past the 300-bps repack tolerance and strands it.
    function _sellEth(uint size) internal {
        vm.prank(User01);
        try AUX.swap{value: size}(address(USDC), address(WETH), false, 0, 0, true) {} catch {}
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpPerSwap);
    }

    /// @dev CONTROL for E7: the same oracle reads at EVERY step, so a degenerate value at the
    ///      tick extreme can be distinguished from a unit I simply misread. Would this
    ///      measurement look the same if I were wrong? -- that is what the t0/t1 rows answer.
    function _oracleTrace(string memory tag) internal {
        (uint rTwap, bool rStale) = AUX.resolvedTwap(address(WETH), 1800);
        (uint sp,) = CORE.poolStats();
        uint spot = sp;   // §DETICK: poolStats() RETURNS the price; converting it again was a double conversion
        emit log_string(tag);
        emit log_named_uint("   getTWAPforAsset ", AUX.getTWAPforAsset(address(WETH), 1800));
        emit log_named_uint("   resolvedTwap    ", rTwap);
        emit log_named_uint("   stale?          ", rStale ? 1 : 0);
        emit log_named_uint("   curve spot      ", spot);
        emit log_named_uint("   spotPrice    ", uint(sp));
        emit log_named_address("   assetPriceFeed  ", AUX.assetPriceFeed(address(WETH)));
    }

    /// @dev The invariant every scenario must satisfy, asserted identically everywhere so a
    ///      scenario cannot quietly opt out of it.
    function _assertClaimsSane(Pair memory s0, Pair memory s1, uint pxE, uint pxB) internal {
        uint baseEth = _ethValue(s0, pxE);
        uint baseBtc = _btcValue(s0, pxB);
        uint nowEth  = _ethValue(s1, pxE);
        uint nowBtc  = _btcValue(s1, pxB);
        emit log_named_uint("ETH range value t0 / t1", baseEth);
        emit log_named_uint("                      ", nowEth);
        emit log_named_uint("BTC range value t0 / t1", baseBtc);
        emit log_named_uint("                      ", nowBtc);
        // NEVER NEGATIVE: the two-leg value must not fall below the capital that was put in.
        // A 2% floor absorbs real fees/slippage paid along the way; a LEAK is what this catches.
        assertGe(nowEth * 100, baseEth * 98, "ETH range: LP claim must not go negative (two-leg value leaked)");
        assertGe(nowBtc * 100, baseBtc * 98, "BTC range: LP claim must not go negative (two-leg value leaked)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S1 — NORMAL FLOW on the ETH range, BTC range live and idle beside it.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S1_EthIncrementalFlow_BothRanges() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Pair memory s0 = _snap();
        _log("S1 t0", s0);
        assertGt(s0.eth.usd, 0, "PREMISE: ETH range is live");
        assertGt(s0.btc.leg, 0, "PREMISE: BTC range is SEEDED (else every cross-range assertion is vacuous)");

        uint landed;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; landed++; }
        for (uint r = 0; r < 6; r++) _sellEth(4 ether);
        assertGt(landed, 0, "PREMISE: ETH-range flow landed");

        Pair memory s1 = _snap();
        _log("S1 t1", s1);
        _assertClaimsSane(s0, s1, pxE, pxB);

        // CROSS-RANGE ISOLATION — now non-vacuous, the BTC range holds real sats.
        assertEq(s1.btc.feesPerShare, s0.btc.feesPerShare, "ETH flow must not move the BTC token-fee accumulator");
        assertEq(s1.btc.usdFees,   s0.btc.usdFees,   "ETH flow must not move the BTC USD-fee accumulator");
        assertEq(s1.btc.leg,          s0.btc.leg,          "ETH flow must not move the BTC range's BTC leg");
        assertEq(s1.btc.usd,          s0.btc.usd,          "ETH flow must not move the BTC range's USD leg");
        // The ETH range's own accumulators MUST have moved, else the isolation claim is untested.
        assertTrue(s1.eth.feesPerShare != s0.eth.feesPerShare || s1.eth.usdFees != s0.eth.usdFees,
            "PREMISE: ETH-range accumulators moved");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S2 — BTC range GROWS while the ETH range is live and idle. The mirror of S1:
    // BTC-side activity must not credit ETH LPs.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S2_BtcGrowth_LeavesEthRangeUntouched() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Pair memory s0 = _snap();
        _log("S2 t0", s0);
        assertGt(s0.btc.leg, 0, "PREMISE: BTC range is seeded");

        BTC.requestDeposit(User01, 2e7);
        BTC.requestDeposit(User03, 1e7);

        Pair memory s1 = _snap();
        _log("S2 t1", s1);
        assertGt(s1.btc.leg, s0.btc.leg, "PREMISE: the BTC range actually grew");
        _assertClaimsSane(s0, s1, pxE, pxB);

        assertEq(s1.eth.feesPerShare, s0.eth.feesPerShare, "BTC growth must not move the ETH token-fee accumulator");
        assertEq(s1.eth.usdFees,   s0.eth.usdFees,   "BTC growth must not move the ETH USD-fee accumulator");
        assertEq(s1.eth.leg,       s0.eth.leg,       "BTC growth must not move the ETH range's ETH leg");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S3 — COMPOUND PATH (the stranding regime). Build an increment with incremental
    // opens FIRST, then hit it with one-shot size. This is the ordering that
    // previously produced tick 887271 (MAX_TICK 887272) with the USD leg at $25 and
    // NO repack after six pokes — the plain one-shot path does NOT reproduce it.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S3_CompoundPath_StrandingRegime() public {
        _seedBoth(400 ether, 2e7);
        Pair memory s0 = _snap();
        _log("S3 t0", s0);
        _oracleTrace("S3 t0 oracle");

        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; }
        Pair memory s1 = _snap();
        _log("S3 t1 (increment built)", s1);
        _oracleTrace("S3 t1 oracle");

        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        ETH.reseat();

        Pair memory s2 = _snap();
        _log("S3 t2 (one-shot on top)", s2);
        _oracleTrace("S3 t2 oracle");

        bool outOfRange = s2.eth.price >= _bHi(address(ETH)) || s2.eth.price < _bLo(address(ETH));
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.eth.lastRepack != s0.eth.lastRepack ? 1 : 0);
        emit log_named_uint("UPPER_PRICE", _bHi(address(ETH)));
        emit log_named_uint("LOWER_PRICE", _bLo(address(ETH)));

        // ── ROOT-CAUSE TRACE. `rebalanceCore` has exactly three ways to decline a re-centre;
        //    read the inputs to each so the blocking branch is IDENTIFIED, not guessed at.
        //      (a) auto-heal  : fires only when `stale` (resolved price fell back to Chainlink)
        //      (b) twap == 0  : bootstrap / dead feed
        //      (c) manipulated: `dev * 10000 > twap * 300` (BasketLib.isManipulated:368)
        (uint rTwap, bool rStale) = AUX.resolvedTwap(address(WETH), 1800);
        (uint sp2,) = CORE.poolStats();
        uint spot2 = sp2;  // §DETICK: see above
        emit log_named_uint("(a) resolvedTwap stale?", rStale ? 1 : 0);
        emit log_named_uint("(b) resolvedTwap price ", rTwap);
        emit log_named_uint("    curve spot         ", spot2);
        uint devBps = rTwap == 0 ? 0
            : (spot2 > rTwap ? spot2 - rTwap : rTwap - spot2) * 10000 / rTwap;
        emit log_named_uint("(c) spot deviation bps ", devBps);
        emit log_named_uint("    manipulated @300bps?", rTwap != 0 && devBps > 300 ? 1 : 0);

        // A range left OUT of range MUST have re-centred. If this fails, the stranding is real
        // and `reseat()` cannot recover it — which is the defect E6 needs to fix, not a bad test.
        assertTrue(!outOfRange || s2.eth.lastRepack != s0.eth.lastRepack,
            "a range left OUT OF RANGE must re-centre; stranded-out-of-range is the defect");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S4 — BOTH ranges driven together. `AUX.checkBacking()` runs at the head of every
    // deposit and can repack EITHER range (`BasketLib.backingCoreBody:918` picks by
    // `POOLED_USD >= POOLED_USD`), so this is the case where a per-range
    // baseline is most exposed and where a unified POOLED_USD must not cross-credit.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S4_BothRangesDriven_NoCrossCredit() public {
        _seedBoth(400 ether, 2e7);
        uint pxE = _pxEth(); uint pxB = _pxBtc();
        Pair memory s0 = _snap();
        _log("S4 t0", s0);

        for (uint r = 0; r < 6; r++) { if (_open(3_000e18) == 0) break; }
        BTC.requestDeposit(User01, 2e7);
        for (uint r = 0; r < 3; r++) _sellEth(4 ether);
        BTC.requestDeposit(User03, 1e7);

        Pair memory s1 = _snap();
        _log("S4 t1", s1);
        _assertClaimsSane(s0, s1, pxE, pxB);

        // The derived-today identity: committed is exactly the two USD legs scaled. THIS IS THE
        // LINE THE #12 SPLIT DELIBERATELY BREAKS — when committed stops tracking POOLED_USD and
        // starts tracking only basket-supplied capital, this assertion MUST be re-derived rather
        // than relaxed. Pinning it now makes that change visible instead of silent.
        // §#12 LANDED — this pin FIRED as designed and is now re-derived. committed tracks the
        // BASKET's contribution, so a swap moves the curve legs WITHOUT moving committed. That
        // separation IS #12; asserting the old equality would re-couple them.
        assertEq(s1.eth.committed, (CORE.basketUsd() + CORE.basketUsd()) * 1e12,
            "committedUsd18 == (both BASKET depths) x 1e12 -- the #12 split, pinned in its new form");
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

        Pair memory s0 = _snap();
        _oracleTrace("S3b t0 oracle (anchored)");

        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; }
        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        ETH.reseat();

        Pair memory s2 = _snap();
        _log("S3b t2 (one-shot on top, ANCHORED)", s2);
        _oracleTrace("S3b t2 oracle (anchored)");

        bool outOfRange = s2.eth.price >= _bHi(address(ETH)) || s2.eth.price < _bLo(address(ETH));
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.eth.lastRepack != s0.eth.lastRepack ? 1 : 0);

        assertTrue(!outOfRange || s2.eth.lastRepack != s0.eth.lastRepack,
            "ANCHORED: a range left OUT OF RANGE must re-centre -- if this fails, production is exposed too");
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

        Pair memory s0 = _snap();
        _oracleTrace("S3c t0 (anchored + fresh)");

        uint opens;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; opens++; }
        for (uint i = 0; i < 6; i++) _sellEth(30 ether);
        ETH.reseat();

        Pair memory s2 = _snap();
        _log("S3c t2", s2);
        _oracleTrace("S3c t2 (anchored + fresh)");
        emit log_named_uint("opens landed", opens);
        emit log_named_uint("hours warped", (block.timestamp - s0.eth.lastRepack) / 3600);

        bool outOfRange = s2.eth.price >= _bHi(address(ETH)) || s2.eth.price < _bLo(address(ETH));
        emit log_named_uint("out of range?", outOfRange ? 1 : 0);
        emit log_named_uint("LAST_REPACK moved?", s2.eth.lastRepack != s0.eth.lastRepack ? 1 : 0);

        assertTrue(!outOfRange || s2.eth.lastRepack != s0.eth.lastRepack,
            "ANCHORED+FRESH: out-of-range range must re-centre -- failing here means PRODUCTION is exposed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S5 — THE PREMISE OF THE R2 FIX, MEASURED. Bounding `sqrtPriceLimitX96` at the
    // range edge is only neutral if a swap CANNOT FILL past that edge — i.e. the
    // teleport to MAX_SQRT_PRICE moves price WITHOUT moving tokens. If instead real
    // volume trades out there, bounding the limit would change fills and the fix is
    // NOT neutral. This measures the marginal swap in isolation: drain the range's
    // USD leg first, then do ONE more swap and compare price movement against
    // tokens actually exchanged.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S5_UnfillableSwapMovesPriceForFree() public {
        _seedBoth(400 ether, 2e7);

        // Drain the USD leg to EXHAUSTION first. Measured: the 5th sell still fills completely
        // (30 ETH in, 25,168.89 USDC out, USD leg 25,185.75 -> 16.85, tick +1), so the teleport is
        // the swap AFTER exhaustion -- that is the one this isolates.
        for (uint i = 0; i < 5; i++) _sellEth(30 ether);

        Pair memory a = _snap();
        uint ethBefore  = User01.balance;
        uint usdcBefore = USDC.balanceOf(User01);
        // E10: `_refundExcess` pays the unfilled remainder via `aux.withdrawSelf(r.inToken, ...)`,
        // and for a volatile-in swap `inToken` is WETH -- so the refund arrives as WETH, NOT native.
        // Measuring only `.balance` + USDC (as the first version of this test did) MISSES it and
        // makes an ordinary partial fill look like a 70% overpay.
        uint wethBefore = WETH.balanceOf(User01);
        emit log_named_uint("pre-marginal  USD leg (6d)", a.eth.usd);
        emit log_named_uint("pre-marginal  price       ", a.eth.price);
        emit log_named_uint("pre-marginal  POOLED ", a.eth.leg);

        // THE MARGINAL SWAP.
        _sellEth(30 ether);

        Pair memory b = _snap();
        uint ethSpent = ethBefore - User01.balance;
        uint usdcGot  = USDC.balanceOf(User01) - usdcBefore;
        uint wethGot  = WETH.balanceOf(User01) - wethBefore;
        uint px       = _pxEth();
        // VALUE ACCOUNTING (USD18): what the swapper paid vs what came back on ALL legs.
        uint paid = ethSpent * px / 1e18;
        uint back = wethGot * px / 1e18 + usdcGot * 1e12;
        emit log_named_uint("marginal swap: WETH refund", wethGot);
        emit log_named_uint("value paid  (USD18)      ", paid);
        emit log_named_uint("value back  (USD18)      ", back);
        emit log_named_int ("value delta (USD18)      ", int(back) - int(paid));
        emit log_named_uint("post-marginal USD leg (6d)", b.eth.usd);
        emit log_named_uint("post-marginal price       ", b.eth.price);
        emit log_named_uint("post-marginal POOLED ", b.eth.leg);
        emit log_named_uint("marginal swap: ETH spent ", ethSpent);
        emit log_named_uint("marginal swap: USDC recvd", usdcGot);
        emit log_named_uint("price moved by            ", b.eth.price - a.eth.price);
        emit log_named_uint("range ETH leg moved by    ", b.eth.leg > a.eth.leg ? b.eth.leg - a.eth.leg : 0);
        emit log_named_uint("range USD leg moved by    ", a.eth.usd > b.eth.usd ? a.eth.usd - b.eth.usd : 0);

        // NOT an assertion about the fix -- a MEASUREMENT of whether price moved without trade.
        // Reported so the neutrality claim rests on numbers, not on reading Uniswap semantics.
        emit log_string("If tick moves far while the legs barely move, the price moved for FREE");
        emit log_string("=> bounding sqrtPriceLimitX96 at the range edge is FILL-NEUTRAL.");
    }

    /// @dev One sell, fully instrumented. Returns false if the swap REVERTED — `_sellEth`'s
    ///      try/catch hides that, and "which swap reverted" turned out to matter.
    function _sellEthLogged(uint i, uint size) internal returns (bool ok) {
        (uint spA,) = CORE.poolStats();   // §DETICK: price is now the FIRST element, and it is a uint
        uint uA = CORE.POOLED_USD(); uint eA = CORE.POOLED();
        vm.prank(User01);
        try AUX.swap{value: size}(address(USDC), address(WETH), false, 0, 0, true) { ok = true; } catch { ok = false; }
        (uint spB,) = CORE.poolStats();   // §DETICK: price is now the FIRST element, and it is a uint
        emit log_named_uint("--- sell #", i);
        emit log_named_uint("    reverted?      ", ok ? 0 : 1);
        emit log_named_uint("    spotPrice before   ", uint(spA));
        emit log_named_uint("    spotPrice after    ", uint(spB));
        emit log_named_uint("    USD leg before ", uA);
        emit log_named_uint("    USD leg after  ", CORE.POOLED_USD());
        emit log_named_uint("    ETH leg before ", eA);
        emit log_named_uint("    ETH leg after  ", CORE.POOLED());
        emit log_named_uint("    UPPER_PRICE     ", _bHi(address(ETH)));
        emit log_named_uint("    LOWER_PRICE     ", _bLo(address(ETH)));
        vm.roll(block.number + 1); vm.warp(block.timestamp + warpPerSwap);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S6 — WHICH SWAP TELEPORTS, AND FROM WHAT STATE. S3 (12 opens, then 6 x 30 BTC)
    // reaches MAX_TICK; S5 (the same 6 sells with NO opens) does not, and drains the
    // USD leg FURTHER while staying at tick 201019. So exhaustion is not the trigger
    // and the opens are somehow necessary. This logs every sell so the exact
    // transition is IDENTIFIED rather than inferred -- three inferred mechanisms
    // have already been wrong.
    // ═══════════════════════════════════════════════════════════════════════════
    function testMatrix_S6_WhichSwapTeleports() public {
        _seedBoth(400 ether, 2e7);
        Pair memory s0 = _snap();
        emit log_named_uint("price after seed", s0.eth.price);
        emit log_named_uint("USD leg after seed", s0.eth.usd);

        uint opens;
        for (uint r = 0; r < 12; r++) { if (_open(3_000e18) == 0) break; opens++; }
        Pair memory s1 = _snap();
        emit log_named_uint("opens landed", opens);
        emit log_named_uint("price after opens", s1.eth.price);
        emit log_named_uint("USD leg after opens", s1.eth.usd);
        emit log_named_uint("ETH leg after opens", s1.eth.leg);
        emit log_named_uint("UPPER_PRICE after opens", _bHi(address(ETH)));
        emit log_named_uint("LOWER_PRICE after opens", _bLo(address(ETH)));

        for (uint i = 1; i <= 6; i++) _sellEthLogged(i, 30 ether);
    }
}
