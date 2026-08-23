// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IMorphoStaticTyping as IMorphoTest, MarketParams, Id} from "../src/imports/Interfaces.sol";
import {IOracle as IMorphoOraclePrice} from "../src/imports/Interfaces.sol";
import {Vm} from "forge-std/Vm.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/Interfaces.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {VenueNotAllowed} from "../src/imports/Types.sol";

interface IERC20R {
    function approve(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
}

interface IChainlinkFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IWeETHRateT { function getEETHByWeETH(uint) external view returns (uint); }

/// Fuller Morpho Blue surface (create a real market + seed borrow liquidity + authorize + liquidate).
interface IVaultRoverT { function ROVER() external view returns (address); }

/// Morpho IOracle (`price()` = collateral→loan, 1e36-scaled). NOT a mock — REAL sources: weETH→ETH (ether.fi
/// getEETHByWeETH) x ETH→USD (REAL Chainlink ETH/USD). Morpho scale weETH(18)→USDC(6): price = weETH_USD(1e18)x1e6.
/// A "crash" overrides the SAME real ETH/USD feed (one drawdown moves this AND our range oracle), no hardcoded price.
contract RealRateMorphoOracle {
    address public immutable WEETH;
    IChainlinkFeedT public immutable ETH_USD;
    constructor(address weeth, address ethUsd) { WEETH = weeth; ETH_USD = IChainlinkFeedT(ethUsd); }
    function price() external view returns (uint256) {
        uint ethPerWeeth = IWeETHRateT(WEETH).getEETHByWeETH(1e18);
        (, int256 p,,,) = ETH_USD.latestRoundData();
        uint weethUsd1e18 = ethPerWeeth * uint(p) / 1e8;
        return weethUsd1e18 * 1e6;
    }
}

/// @notice CORRELATED-CRASH cascade de-lever, FULLY on the REAL mainnet-fork stack (no mocks): N weETH-collateral
///   leveraged positions on a REAL Morpho Blue market + the REAL Quid ETH range as the E0/sold-fraction source, all
///   levered by a REAL range rally (genuine IL), then crashed so they breach their de-lever range together, then
///   `cascadeDelever`ed in one tx — asserting each is de-levered or gracefully skipped, isolated, with net progress.
///   The mocks (MockWeeth/MockSwapper/MaliciousSwapper/MockRangeHost/MockFlashLender/TestLevVenue) are DELETED; the
///   folded LevManager mints/redeems real weETH via ether.fi + routes stable legs through the basket SOR, and the
///   venue/flash/liquidation are the LIVE Morpho singleton. Mirrors LevYbReal's real-venue scaffolding.
contract LevCascadeProbe is AllesFixture {
    // Real mainnet addresses (same fork Alles pins).
    address constant WEETH        = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant CL_ETH_USD   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // real Chainlink ETH/USD, 8-dec

    // Kept as fields (not deep locals) so the e2e frame stays shallow — no via_ir (matches LevYbReal).
    LevManager lm;
    MorphoEscrowVenue venue;
    address mOracle;
    MarketParams mp;
    address[3] lps = [address(0xBEEF1), address(0xBEEF2), address(0xBEEF3)];

    // §SILENT-SETUP — `try ETH.withdraw(...) {} catch {}` records NOTHING, so a run where the
    // withdraw REVERTED is indistinguishable from one where it moved the range. Both uses below are
    // load-bearing SETUP (one asserts the levered slice survived a free withdraw, the other shrinks
    // the plain base so the debt can exceed the leg), so a swallowed revert makes the case vacuous
    // rather than failing it. Same shape as `VarPrecision.swapsLanded`.
    uint internal withdrawsAttempted;
    uint internal withdrawsLanded;

    // ─────────────────────────── real-stack setup ───────────────────────────

    function _setupLev() internal {
        _seedBasket();
        RealRateMorphoOracle oracle = new RealRateMorphoOracle(WEETH, CL_ETH_USD);
        mOracle = address(oracle);
        mp = MarketParams({
            loanToken: address(USDC), collateralToken: WEETH,
            oracle: address(oracle), irm: ADAPTIVE_IRM, lltv: 0.86e18
        });
        IMorphoTest morpho = IMorphoTest(MORPHO);
        morpho.createMarket(mp);
        // Seed borrow liquidity (this contract is the lender).
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, 5_000_000 * USDC_PRECISION);
        morpho.supply(mp, 5_000_000 * USDC_PRECISION, 0, address(this), "");
        // Wire the YB stack against the real venue + the REAL Quid range (ETH) as the RANGE-ONLY E0 / sold-fraction
        // source — NO MockRangeHost — + the real Morpho flash (zero-fee repay-first de-lever). One atomic pin-once.
        lm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        venue = new MorphoEscrowVenue(MORPHO, mp, address(lm));
        address[] memory vs = new address[](1); vs[0] = address(venue);
        lm.init(address(ETH), MORPHO, vs);

        // PIN THE ETH/USD ANCHOR (2026-07-26, BUILD-QUEUE §A.13). This fixture already maintains
        // `ETH_FEED` as a pool-tracking mock (`_setEthFeed`, refreshed every crash/rally step) but never
        // registered it with Aux, so `assetPriceFeed(WETH)` was address(0) — MEASURED. With no anchor,
        // once a crash walks the pool to its tick boundary `getTWAPforAsset` returns 0 and
        // `rebalanceCore`'s `if (twap == 0) return r` leaves `didRepack == false`, so `addLiq` never
        // runs and the range can never be re-paired. Registering the tracking feed is what lets the
        // twapResolve anchor fall-through actually rescue this fixture, exactly as the real deploy
        // pins Chainlink (DeployL1_s:326).
        _setEthFeed(AUX.getTWAPforAsset(address(WETH), 1800) / 1e10);   // seed it before pinning
        AUX.setAssetFeed(address(WETH), ETH_FEED);
    }

    /// Seed REAL basket POOLED_USD surplus (mint QUID against USDC) so syncLev can pair the levered range slice.
    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// Move the REAL ETH range UP by buying WETH out of it in bounded steps (each under the 50bps/swap manip cap),
    /// warping between so each step measures from spot≈TWAP and the guard resets. Real swaps only — the range sells
    /// ETH → real IL accrues; kept under the 5% Chainlink anchor so no reseat/no oracle override. Self-calibrating.
    function _rallyRange(uint syncKeyPx, uint targetWad, uint maxSteps, uint usdcPerStep) internal {
        deal(address(USDC), address(this), maxSteps * usdcPerStep);
        IERC20R(address(USDC)).approve(address(AUX), maxSteps * usdcPerStep);
        for (uint i; i < maxSteps; i++) {
            if (ETH.soldFractionWad(syncKeyPx) >= targetWad) break;
            // 🔴 §E310 — READ THE POOL, NOT THE RING. This read `AUX.getTWAPforAsset` (the
            // observation ring) and set the Chainlink mock FROM it, so the anchor was a copy of the
            // thing it anchors and NEITHER could move. Measured (§C18): ring TWAP, Chainlink and the
            // pinned `ilBasisPx` were all 2501.13975863 after TEN successful swaps, so `ilTargetBps`
            // returned 0 and `venue.borrow` was NEVER INVOKED -- which reads as "Morpho will not
            // lend". ⛔ `rangePrice()` is NOT an escape: `CORE.poolStats().priceWad` IS
            // `obsState.lastPrice`, the ring again. §V4-CUT settles fills AT ORACLE against
            // inventory, so A SWAP MOVES NO PRICE -- the move must be INJECTED, not read.
            uint px = ETH.rangePrice(); if (px == 0) break;
            // ⚠️ +8%, NOT +5% — THE DEADBAND SETS THE FLOOR, and this file had the §E310 mechanism
            // with the WRONG SIZE. `debtDelta` no-ops below `RANGE_BPS` = 300 bps, and a +5% move is
            // `1 - sqrt(1/1.05)` = 241 bps of sold fraction, which never reaches it: `ilTargetBps`
            // stayed 0, `venue.borrow` was never invoked, and it read as "Morpho will not lend" —
            // the SAME symptom §E310 fixed, surviving in this file because only the mechanism was
            // copied across and not the sizing. +8% gives `1 - sqrt(1/1.08)` = 377 bps.
            // ⇒ The number is DERIVED from `RANGE_BPS`, not tuned: if that deadband moves, redo the
            // arithmetic here and in `LevYbReal._rallyRange`, which carries the same constant.
            px += px * 8 / 100;                     // +8%: the MARKET moves, EXOGENOUSLY
            _setLiveEthFeed(px / 1e10);             // Chainlink follows the market (LIVE feed, §E310) ...
            CORE.pushObservation(px);               // ... and the ring records it (deviation 0 => admissible)
            try AUX.swap(address(USDC), address(WETH), true, usdcPerStep, 0, true) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Real DOWN move: sell ETH into the range so the mark crashes ~`dropBps` (drives the venue-safety de-lever).
    function _crashRange(uint dropBps, uint maxSteps, uint ethPerStep) internal {
        uint start = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.deal(address(this), maxSteps * ethPerStep);
        for (uint i; i < maxSteps; i++) {
            // 🔴 §E310 (DOWN-SIDE TWIN) — the last circular crash helper, fixed to match
            // `LevYbReal._crashRange`. It read the observation RING and set the Chainlink mock FROM
            // it, so `px` never changed and `px <= start - drop` was UNREACHABLE: the loop burned
            // every step and MOVED NOTHING. ⛔ `rangePrice()` is not an escape either —
            // `CORE.poolStats().priceWad` IS `obsState.lastPrice`. §V4-CUT settles fills AT ORACLE
            // against inventory, so a swap moves no price: the move must be INJECTED.
            uint px = ETH.rangePrice(); if (px == 0) break;
            if (px <= start - start * dropBps / 10000) break;
            px -= px * 2 / 100;                     // -2%: the MARKET moves, EXOGENOUSLY
            _setLiveEthFeed(px / 1e10);             // the LIVE feed, not the 0xE7F0FEED sentinel
            CORE.pushObservation(px);               // ring records it (deviation 0 => admissible)
            try AUX.swap{value: ethPerStep}(address(USDC), address(WETH), false, 0, 0, true) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Calm realized vol after a rally so θ=yield/(K·σ²) recovers (the θ-budget cap refuses new range depth while vol
    /// is elevated). The realistic sequence: an IL event, then vol calms — what lets syncLev add the levered depth.
    function _calmVol() internal {
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        vm.deal(address(this), 20 ether);
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            if (i % 2 == 0) { try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0, true) {} catch {} }
            else            { try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) {} catch {} }
        }
    }

    /// Realign the range oracle to the REAL Chainlink market before a real weETH↔stable leg / basket reconcile
    /// (the rally elevates the mock-token range feed we can move; the leverage's external legs execute on REAL
    /// Uniswap which we can't — a fork artifact fix, matches LevYbReal).
    function _realignRangeToReal() internal {
        (, int256 clp,,,) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        _setEthFeed(uint(clp)); ETH.reseat();
    }

    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }
    function _entryPrice(address lp) internal view returns (uint s) { ( , , , , s, ) = lm.pos(lp); }

    /// REAL Morpho seizure of `lp`: realign the range oracle to the market, crash the SHARED Chainlink feed so the
    /// position lands ~92% LTV (liquidatable per lltv 0.86, not deep bad debt), then liquidate by REPAID SHARES
    /// (a fraction of the ACTUAL debt — never `seizedAssets`, which over-repays a tiny debt and underflows
    /// Morpho's `borrowShares -= repaidShares`). Repays `numer/denom` of the debt; leaves the position smaller.
    function _seizeReal(address lp, uint numer, uint denom) internal {
        _realignRangeToReal();
        uint collValue = venue.collateralOf(lp) * IMorphoOraclePrice(mOracle).price() / 1e36;
        uint vdebt = venue.debtOf(lp);
        (uint80 rid, int256 p,, uint256 ut, uint80 ar) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        uint crashed = uint256(p) * vdebt * 100 / (collValue * 92);
        vm.mockCall(CL_ETH_USD, abi.encodeWithSelector(IChainlinkFeedT.latestRoundData.selector),
            abi.encode(rid, int256(crashed), ut, ut, ar));
        (, uint128 borrowShares,) = IMorphoTest(MORPHO).position(venue.MARKET_ID(), lp);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, type(uint).max);
        IMorphoTest(MORPHO).liquidate(mp, lp, 0, uint256(borrowShares) * numer / denom, ""); // repay by SHARES
        vm.clearMockedCalls();
        _realignRangeToReal();
    }

    /// Establish `lp`'s REAL range position (the E0 IL base, read live from ETH) — a genuine ETH range deposit,
    /// which (unlike the old MockRangeHost.setRange) ITSELF adds to `rangeETH`, so tests that measure the
    /// leverage's OWN rangeETH contribution must baseline AFTER this (see `_openLevOnly`). Also mints the LP's
    /// weETH equity + does the one-time Morpho authorization.
    function _rangeE0(address lp, uint sizeEth) internal {
        vm.deal(lp, sizeEth + 1 ether);
        vm.prank(lp); ETH.deposit{value: sizeEth}(0, lp);   // venue 3 = all-Galaxy (no offramp noise)
        deal(WEETH, lp, sizeEth);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true); // one-time Morpho isolation
    }

    /// Open at ZERO leverage against the already-established range position (entry pinned from ETH.rangeSqrtP).
    function _openLevOnly(address lp, uint sizeEth) internal {
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), sizeEth);
        lm.openLev(5000, ILevVenue(address(venue)), sizeEth, mins); // cap = 2x; opens at ZERO leverage
        vm.stopPrank();
    }

    function _openAtEntry(address lp, uint sizeEth) internal { _rangeE0(lp, sizeEth); _openLevOnly(lp, sizeEth); }

    // ═══════════════════════════════ tests ═══════════════════════════════

    /// FOUNDATION PROOF — net-equity backing + seizure-safety. The levered weETH's NET-of-debt equity is recognized
    /// in `rangeETH` (backs the range), and a REAL Morpho liquidation removes that credit cleanly while `POOLED_USD`
    /// stays intact — no socialization.
    function test_NetEquity_BackingRecognized_SeizureLeavesPooledUsdIntact() public {
        _setupLev();
        EV.setLevManager(address(lm));                         // pin the leveraged book into rangeETH

        // Establish the REAL range position FIRST, then baseline — the range deposit itself adds to rangeETH
        // (unlike the old mock), so the leverage's OWN contribution is measured from the post-deposit baseline.
        _rangeE0(lps[0], 5 ether);
        uint range0 = AUX.rangeETH();

        // Open at entry ⇒ ZERO leverage ⇒ net-equity == principal (weETH→ETH via the real staking rate).
        _openLevOnly(lps[0], 5 ether);
        uint principalEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        assertApproxEqAbs(lm.netEquity(lps[0]), principalEth, 1e15, "open: net-equity == principal");
        assertApproxEqAbs(AUX.rangeETH(), range0 + principalEth, 1e15, "open: rangeETH gains exactly the net-equity");

        // Lever up on a REAL range rally (real IL): debt > 0, but the borrow is self-financing ⇒ equity ~principal.
        // (A real rally executes real swaps, which legitimately move POOLED_USD — so the mock's "POOLED_USD frozen
        // across the lever" assertion is unmeasurable here; the real invariant is deliverable-covers-range, below.)
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        assertGt(venue.debtOf(lps[0]), 0, "levered: real Morpho debt > 0");
        // §LEV-CLUSTER INSTRUMENT — the ~2.7% shortfall here (7500… vs 7707…) is a DIFFERENT
        // SIGNATURE from the 8x miss elsewhere in this file, so do not assume a shared cause. The
        // trio below is the one that answered the stuck-LP question (target 279 bps against a
        // 300 bps dead-band): if `ilTarget` is UNDER 300 the rally never levered the position as
        // far as this fixture assumes and `rangeETH` is simply short of the net-equity credit the
        // assertion budgets for — one CALIBRATION cause. If `ilTarget` is OVER 300 while `debtOf`
        // and `currentLtv` stay low, the position failed to LEVER and that is a different defect.
        emit log_named_uint("levered: lp0 ilTargetLtvBps ", lm.ilTargetLtvBps(lps[0]));
        emit log_named_uint("levered: lp0 venue.debtOf   ", venue.debtOf(lps[0]));
        emit log_named_uint("levered: lp0 currentLtvBps  ", lm.getCurrentLtvBps(lps[0]));
        emit log_named_uint("levered: AUX.rangeETH()     ", AUX.rangeETH());
        emit log_named_uint("levered: CORE.POOLED()      ", CORE.POOLED());
        emit log_named_uint("levered: lm.netEquity(lp0)  ", lm.netEquity(lps[0]));
        emit log_named_uint("levered: lm.grossColl(lp0)  ", lm.grossCollateral(lps[0]));
        assertGe(AUX.rangeETH(), CORE.POOLED(), "levered: deliverable ETH still covers the range");

        // SEIZE via a REAL Morpho liquidation (repay half the debt by shares — see `_seizeReal`).
        uint tvl0 = _tvl();
        uint vdebt = venue.debtOf(lps[0]);
        _seizeReal(lps[0], 1, 2);
        assertLt(venue.debtOf(lps[0]), vdebt, "seize: REAL Morpho liquidation reduced the debt");

        // Basket clean: the liquidation took NOTHING from the basket (TVL intact) and deliverable ETH still
        // covers the range — the loss is isolated to the LP's Morpho account, never socialized.
        assertGe(_tvl(), tvl0, "seized: basket real backing (TVL) intact - nothing socialized");
        assertGe(AUX.rangeETH(), CORE.POOLED(), "seized: deliverable ETH still covers the range");
    }

    /// FEE-LANE PROOF: the levered weETH equity (a) EARNS range fees via the same machinery as a weETH deposit,
    /// (b) is UNWIND-ONLY (the free ladder can't pull it), and (c) a REAL seizure burns the slice clean.
    function test_LevFeeLane_EarnsFees_UnwindOnly_SeizureBurnsClean() public {
        _setupLev();
        EV.setLevManager(address(lm));
        // Thicken the range with a normal ETH-LP so small swaps clear the manip guard.
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 10 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);                                 // real levered position
        _calmVol();                                             // θ recovers ⇒ syncLev can add the depth

        uint pu0 = CORE.POOLED_USD();
        ETH.syncLev(lps[0]);                                     // mint the levered range slice (tokenless)
        uint lev = ETH.levPooled(lps[0]);
        assertGt(lev, 0, "syncLev minted the levered slice into the range");
        // The levered slice is IN the range's depth. NOT "grew at this instant": `lm.rebalance` above
        // already minted it through the manager's syncLev HOOK, so the explicit `ETH.syncLev` here is
        // IDEMPOTENT and `pe0` (captured after the rebalance) already contains the slice. MEASURED:
        // levPooled 5.503 and levBuf 1.507 are both already live, while POOLED moves by -23 wei of
        // modLP rounding — so the old `assertGt(POOLED, pe0)` was asserting a transition that had
        // already happened, and could only ever pass or fail on rounding noise.
        assertGe(CORE.POOLED(), lev, "the levered slice is part of the range's in-range depth");
        assertGt(ETH.levBuf(lps[0]), 0, "the debt-funded buffer is live and fee-earning");
        // SAME DEFECT AS THE `pe0` ASSERTION ABOVE, fixed the same way. `pu0` is captured AFTER
        // `lm.rebalance`, which already minted the slice via the manager's syncLev hook, so the explicit
        // `ETH.syncLev` is IDEMPOTENT and POOLED_USD cannot GROW here. The old `assertGt(.., pu0)` was
        // asserting a transition that had already happened, and could only pass or fail on modLP
        // rounding — MEASURED at 3,596 of 6-dec USD ($0.0036), the same order as the -23 wei the ETH
        // side moves. Assert the STATE that matters (USD is paired against the levered slice, so the
        // depth is in-range and fee-earning) rather than a delta that is pure noise.
        assertGt(CORE.POOLED_USD(), 0, "POOLED_USD paired against it (in-range, fee-earning)");

        // (a) small swaps generate range fees; the levered LP IS range depth.
        for (uint i; i < 10; i++) {
            try AUX.swap{value: 0.2 ether}(address(USDC), address(WETH), false, 0, 0, true) returns (uint) {} catch {}
            vm.roll(vm.getBlockNumber() + 1);
        }
        (uint ethR, uint usdR) = ETH.pendingRewards(lps[0]);
        assertGt(ethR + usdR, 0, "(a) levered LP ACCRUES range fees on its equity");

        // (b) UNWIND-ONLY: the free ladder cannot pull the levered slice.
        vm.prank(lps[0]);
        ++withdrawsAttempted;
        try ETH.withdraw(type(uint).max, lps[0], lps[0]) { ++withdrawsLanded; } catch {}
        emit log_named_uint("(b) free withdraws landed  ", withdrawsLanded);
        emit log_named_uint("(b)           attempted    ", withdrawsAttempted);
        // PREMISE: if the free withdraw never executed, "the free ladder cannot pull the levered
        // slice" is proven by NOTHING — the slice is untouched because nothing touched anything.
        assertGt(withdrawsLanded, 0, "PREMISE: the free withdraw actually ran (else UNWIND-ONLY is vacuous)");
        assertEq(ETH.levPooled(lps[0]), lev, "free withdraw leaves the levered slice untouched");

        // (c) SEIZE via REAL Morpho liquidation → syncLev burns the slice clean.
        _seizeReal(lps[0], 1, 2);
        ETH.syncLev(lps[0]);
        assertLt(ETH.levPooled(lps[0]), lev, "seizure: levered slice shrank/burned toward the liquidated equity");
    }

    /// CRITICAL: a caller-supplied, NON-allowlisted venue (which could return phantom collateral → fake rangeETH →
    /// ETH-LP drain) is rejected. Only pinned adapters can be opened against.
    function test_VenueAllowlist_BlocksUnvettedVenue() public {
        _setupLev();
        MorphoEscrowVenue rogue = new MorphoEscrowVenue(MORPHO, mp, address(lm)); // real, but NOT pinned
        _openAtEntry(lps[0], 5 ether); // establishes a range position for lps[0]
        // Fresh LP so the AlreadyOpen guard doesn't mask the venue check.
        address lp = address(0xBEEF4);
        vm.deal(lp, 6 ether);
        vm.prank(lp); ETH.deposit{value: 5 ether}(0, lp);
        deal(WEETH, lp, 5 ether);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(rogue), true);
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), 5 ether);
        vm.expectRevert(VenueNotAllowed.selector);
        lm.openLev(5000, ILevVenue(address(rogue)), 5 ether, mins);
        vm.stopPrank();
    }

    /// @notice #43 DELEGATED QU!D-protect, adversarial, FULLY on the real fork. A levered LP opts in (QUID
    ///         `approve` to the manager); its position is pushed near venue liquidation; then an ARBITRARY hostile
    ///         caller invokes `protectFromQuid`. Proves the by-construction safety of the autonomous-layer
    ///         entrypoint: the caller nets ZERO (cannot skim a wei), the LP's OWN debt falls (its OWN QUID is
    ///         redeemed to fund it), and the gate rejects a healthy position (NotNearLiq) and a non-opted-in LP
    ///         (NoOptIn). No per-action quorum, no cap — the constraint is the guard.
    function test_ProtectFromQuid_HostileOperatorNetsZero() public {
        _setupLev();
        address lp = lps[0]; address lp2 = lps[1];
        _openAtEntry(lp, 1 ether);
        _openAtEntry(lp2, 1 ether);
        // The LP funds + votes + mints its own redeemable QUID (Basket.mint's depositor is the RECIPIENT, and the
        // recipient is gated on a current-month vote) — all pranked as the LP, mirroring `_seedBasket`.
        deal(address(USDC), lp, 500_000 * USDC_PRECISION);
        vm.startPrank(lp);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(lp, 300_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        // ONE shared real rally ⇒ correlated IL ⇒ lever both to the IL target (debt > 0).
        _rallyRange(_entryPrice(lp), 0.2e18, 24, 8_000 * USDC_PRECISION);
        lm.rebalance(lp, 0); lm.rebalance(lp2, 0);
        assertGt(venue.debtOf(lp), 0, "rally must lever the position (debt > 0)");

        // (1) HEALTHY ⇒ NotNearLiq. Checked FIRST (before the opt-in), so a low-LTV position is rejected even
        //     un-approved — a hostile caller can never force-redeem a safe LP's QUID. Feed is fresh from the rally.
        vm.expectRevert(LevMath.NotNearLiq.selector);
        lm.protectFromQuid(lp, 0);

        // Opt in (the one-time delegated approve).
        vm.prank(lp); QUID.approve(address(lm), type(uint).max);
        // Mature the LP's QUID vintage (redeem is mature-only). getCurrentLtvBps extrapolates the last tick across
        // the warp (OracleLib `observe`, target >= latest); refresh Chainlink for the redeem's stale-TWAP fallback.
        { uint px = AUX.getTWAPforAsset(address(WETH), 1800);
          vm.warp(block.timestamp + 35 days); vm.roll(block.number + 1);
          _setEthFeed(px / 1e10); }
        // Stage the near-liq TRIGGER by tightening ONLY the venue liquidation threshold to just above the live LTV.
        // The ENTIRE money path (redeem -> repay -> refund) stays 100% REAL against the fork; only the risk-param
        // that decides *when* protection is warranted is staged — a natural ~65% crash to the real 86% LLTV is
        // impractical on the fork's manipulation-guarded oracle (`observe([2400..])` reverts "twap: pre-history"
        // without a long enough history to ride a crash that large). This IS the condition the fleet keeper acts on.
        vm.mockCall(address(venue), abi.encodeWithSelector(venue.liqThresholdBps.selector),
            abi.encode(lm.getCurrentLtvBps(lp) + 1000));
        // Heal the no-CRE fork's spurious default depeg on the redeemed legs (as DrainProbe does), so the range's
        // backing isn't haircut below its committed claims — else ANY redeem trips the OverCommitted drain guard.
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(DAI)), abi.encode(uint(0)));

        // (2) lp2 is near-liq but NOT opted in ⇒ NoOptIn (no allowance ⇒ nothing to pull).
        if (venue.debtOf(lp2) > 0 && lm.getCurrentLtvBps(lp2) + 1500 >= venue.liqThresholdBps()) {
            vm.expectRevert(LevMath.NoOptIn.selector);
            lm.protectFromQuid(lp2, 0);
        }

        // (3) ADVERSARIAL + HAPPY PATH: an arbitrary hostile caller invokes protect on the opted-in LP. With the
        //     pro-rata redeem + multi-route consolidation, the redeem now COMPLETES under leverage (targeted redeem
        //     over-committed; pro-rata + swap-to-venue-stable does not). Value moves ONLY toward the LP: its OWN
        //     QUID is redeemed to repay its OWN debt; the hostile caller nets exactly ZERO.
        address hostile = address(0xBADBEEF);
        uint hQuid0 = QUID.balanceOf(hostile); uint hUsdc0 = USDC.balanceOf(hostile);
        uint lpDebt0 = venue.debtOf(lp); uint lpQuid0 = QUID.balanceOf(lp);
        vm.prank(hostile);
        uint repaid = lm.protectFromQuid(lp, 0);
        assertGt(repaid, 0, "protect repaid the LP's debt (redeem completes under leverage)");
        assertGe(repaid, lpDebt0 / 2, "protect repaid a MEANINGFUL fraction (pro-rata + consolidation delivers real USDC, not dust)");
        assertLt(venue.debtOf(lp), lpDebt0, "the LP's OWN debt fell");
        assertLt(QUID.balanceOf(lp), lpQuid0, "the LP's own QUID funded its own protection");
        assertEq(QUID.balanceOf(hostile), hQuid0, "hostile caller gained NO QUID");
        assertEq(USDC.balanceOf(hostile), hUsdc0, "hostile caller gained NO stable");
    }

    function test_CascadeDelever_CorrelatedCrash() public {
        _setupLev();
        // 3 levered LPs on the SHARED real range (small so each loop's SOR buy stays under the manip cap).
        _openAtEntry(lps[0], 5 ether);
        _openAtEntry(lps[1], 4 ether);
        _openAtEntry(lps[2], 3 ether);
        // ONE shared REAL rally ⇒ correlated IL for all three ⇒ lever each up to the IL target.
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 24, 8_000 * USDC_PRECISION);
        for (uint i; i < 3; i++) {
            lm.rebalance(lps[i], 0);
            assertGt(venue.debtOf(lps[i]), 0, "rally must lever each position to the IL target (debt > 0)");
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }

        uint[3] memory dbtBefore;
        for (uint i; i < 3; i++) dbtBefore[i] = venue.debtOf(lps[i]);

        // CORRELATED CRASH: one shared ~30% down-move drops every mark well below its pinned entry ⇒ each IL
        // target clamps to 0 ⇒ every position is far above target ⇒ a full de-lever fires. The hybrid down-leg
        // (the deep V3 weETH/WETH pool — the ether.fi instant-redeem tier that used to sit beside it was
        // removed 2026-08-06) services the large redeem, so all three de-lever without bricking.
        _crashRange(3000, 24, 40 ether);

        address[] memory batch = new address[](3);
        uint[] memory mins = new uint[](3);
        batch[0] = lps[0]; batch[1] = lps[1]; batch[2] = lps[2];
        vm.recordLogs();
        lm.cascadeDelever(batch, mins);

        // Assert only what IS invariant (this rides the UNPINNED real range; magnitudes vary block-to-block):
        //   (1) ISOLATED + NON-DESTRUCTIVE: every position OPEN, none made worse (post-debt ≤ pre).
        //   (2) FAULT-TOLERANT: de-levered + DeleverFailed-skipped == 3 (batch never reverts).
        //   (3) NET PROGRESS: total batch debt strictly falls (≥1 full sell→repay ran end-to-end).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 failSig = keccak256("DeleverFailed(address,uint256)");
        uint skipped;
        for (uint j; j < logs.length; j++) if (logs[j].topics[0] == failSig) skipped++;

        uint totalBefore; uint totalAfter; uint deLevered;
        for (uint i; i < 3; i++) {
            (, , , , , bool open) = lm.pos(lps[i]);
            assertTrue(open, "position must remain open (isolated, never force-closed)");
            uint dAfter = venue.debtOf(lps[i]);
            uint tol = dbtBefore[i] / 100;   // Morpho interest accrues market-wide during the cascade tx (real market)
            assertLe(dAfter, dbtBefore[i] + tol, "cascade must NEVER materially increase a position's debt");
            if (dAfter + tol < dbtBefore[i]) deLevered++;   // materially decreased (beyond interest noise)
            totalBefore += dbtBefore[i]; totalAfter += dAfter;
        }
        assertLt(totalAfter, totalBefore, "cascade made no net de-lever progress (no sell->repay ran)");
        assertGe(deLevered, 1, "cascade de-levered no position");
        assertEq(deLevered + skipped, 3, "every position de-levered OR gracefully skipped (DeleverFailed)");
    }

    /// @notice ISOLATION: a STUCK LP (its de-lever can source nothing) must be skipped + left UNTOUCHED, and must
    ///   NOT block or corrupt another LP's de-lever in the same cascade tx. REAL stuck mechanism: the LP REVOKES
    ///   the venue's Morpho authorization → the adapter's withdraw/borrow revert `NotAuthorized` → `deleverOne`
    ///   reverts atomically (repay-first is rolled back) → `cascadeDelever` catches it. Deterministic, no mock.
    function test_Isolation_StuckLpDoesNotTouchAnother() public {
        _setupLev();
        _openAtEntry(lps[0], 5 ether);
        _openAtEntry(lps[1], 4 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 24, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0); vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        lm.rebalance(lps[1], 0); vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        _crashRange(3000, 24, 40 ether);   // ~30%: full de-lever; hybrid down-leg services the redeem

        // BRICK lp0: revoke the adapter's Morpho authorization ⇒ its withdraw can source nothing.
        vm.prank(lps[0]); IMorphoTest(MORPHO).setAuthorization(address(venue), false);

        uint dbt0 = venue.debtOf(lps[0]); uint coll0 = venue.collateralOf(lps[0]);
        uint dbt1 = venue.debtOf(lps[1]);

        address[] memory batch = new address[](2); batch[0] = lps[0]; batch[1] = lps[1];
        uint[] memory mins = new uint[](2);
        // §LEVCASCADE-STUCK — THE DECISIVE PAIR. This test asserts a stuck LP emits DeleverFailed and
        // gets 0. By elimination the only remaining explanation is that `deleverOne` RETURNS before it
        // ever touches Morpho, so the revoked authorization is never reached. These two numbers say
        // which: NON-ZERO debt with a ZERO target ⇒ the crash killed the target (`ilTargetBps` is 0 at
        // or below entry, `LevMath:92`) and the no-op success is a real finding about the down-leg;
        // ZERO debt ⇒ the rally never levered and this is a fixture problem.
        emit log_named_uint("lp0 debt before cascade    ", venue.debtOf(lps[0]));
        emit log_named_uint("lp0 ilTarget bps           ", lm.ilTargetLtvBps(lps[0]));
        emit log_named_uint("lp1 debt before cascade    ", venue.debtOf(lps[1]));
        vm.recordLogs();
        lm.cascadeDelever(batch, mins);

        // lp0 (stuck): emitted DeleverFailed and its venue state is BYTE-for-byte unchanged (atomic revert).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint failed; bytes32 sig = keccak256("DeleverFailed(address,uint256)");
        for (uint j; j < logs.length; j++) if (logs[j].topics[0] == sig) failed++;
        assertEq(failed, 1, "the stuck LP must emit exactly one DeleverFailed");
        // The stuck LP's de-lever reverted atomically (no repay/withdraw for it). Its COLLATERAL is exactly
        // unchanged (Morpho collateral doesn't accrue); its DEBT only drifts up by market-wide interest that
        // lp1's real Morpho ops accrued — NOT a repay. So: collateral exact, debt within a small interest range.
        assertApproxEqAbs(venue.debtOf(lps[0]), dbt0, dbt0 / 100 + 1, "stuck LP debt only drifts by market interest (no repay)");
        assertEq(venue.collateralOf(lps[0]), coll0, "stuck LP collateral UNTOUCHED (no withdraw)");
        // lp1: de-levered for real DESPITE lp0 being stuck (no blocking, no corruption).
        assertLt(venue.debtOf(lps[1]), dbt1, "the other LP must de-lever despite the stuck one (isolation)");
        ( , , , , , bool open0) = lm.pos(lps[0]); ( , , , , , bool open1) = lm.pos(lps[1]);
        assertTrue(open0 && open1, "both positions remain open (no force-close)");
    }

    /// @notice ANTI-MEV: the contract's slippage floor REJECTS a lever-up trade that would underdeliver weETH. On a
    ///   fork we can't stage a real DEX sandwich, so we bind the SAME protective path (`_stableToWeeth`'s
    ///   `if (weethOut < minWeethOut) revert Slippage()`) via an unsatisfiable keeper `minOut` — proving the
    ///   position is NOT levered at a bad price. (The oracle-derived `wethFloor` on `sorSelfFunded` guards the
    ///   minOut=0 case and is exercised on every happy-path rebalance.)
    function test_MEV_OracleFloorRejectsSandwich() public {
        _setupLev();
        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION); // IL accrues ⇒ a rebalance wants to lever
        // An impossibly high min-weETH-out (1e30) can never be met by the real mint ⇒ the floor reverts the trade.
        vm.expectRevert(LevManager.Slippage.selector);
        lm.rebalance(lps[0], 1e30);
    }

    /// @notice ECONOMIC linkage: the CONTRACT levers to exactly the PROVEN IL-cancelling target `1 − 1/√r`. At 2x
    ///   the target is 29.3% — confirming the deployed sizing IS the IL-cancelling one, not a fixed knob. Uses the
    ///   px-based fallback target (sold-fraction OFF) with an oracle move — a vm-level ETH/USD override (no mock
    ///   contract), the deterministic way to hit an exact ratio.
    function test_Economic_LeversToProvenIlTarget() public {
        _setupLev();
        _openAtEntry(lps[0], 10 ether);                 // opens at ZERO leverage
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.mockCall(address(AUX),
            abi.encodeWithSelector(AUX.getTWAPforAsset.selector, address(WETH), uint32(1800)), abi.encode(px * 2));
        assertApproxEqAbs(lm.ilTargetLtvBps(lps[0]), 2929, 1, "on-chain IL target must be 1 - 1/sqrt(2)");
        for (uint k; k < 8; k++) lm.rebalance(lps[0], 0); // keeper loops successive ticks toward target
        uint ltv = lm.ilLtvBps(lps[0]);                  // debt/E0 basis (the sizing target)
        emit log_named_uint("levered IL-LTV (debt/E0) at 2x", ltv);
        assertApproxEqAbs(ltv, 2929, 400, "must lever to the proven 1 - 1/sqrt(2) IL target (debt/E0 basis)");
        vm.clearMockedCalls();
    }

    /// @notice IL-PROTECTION PROOF — two EQUAL 5-ETH range LPs through ONE shared real rally, one levered, one not.
    ///   Proves the four things the design must guarantee:
    ///     (1) the LEVERED LP is IL-protected — its ETH exposure (net-equity) is preserved as the range sells BTC,
    ///         because the debt (the IL hedge) grows to exactly the sold fraction;
    ///     (2) the UNLEVERED LP eats the IL — withdrawing after the rally returns LESS ETH than it deposited (the
    ///         range sold its ETH on the way up);
    ///     (3) NO CROSS-SUBSIDY / not worsened — the levered LP's hedge is isolated at the venue: syncing its
    ///         levered slice leaves the unlevered LP's pooled claim AND the basket TVL untouched, so the unlevered
    ///         LP's IL is purely its own price-path IL, neither subsidized nor deepened by the levered LP;
    ///     (4) NO RACE — syncLev settles fees before moving pooled (Quid.sol:513) and is idempotent, so a second
    ///         call with no equity change does not double-credit the levered slice.
    function test_IlProtection_LeveredVsUnlevered_NoCrossSubsidy() public {
        _setupLev();
        EV.setLevManager(address(lm));
        // Thick shared range so the rally's swaps clear the 50bps manip guard.
        vm.deal(address(this), 40 ether);
        ETH.deposit{value: 20 ether}(0, address(this));

        // Two EQUAL range LPs: lps[0] levers, lps[1] stays a plain ETH-LP.
        _openAtEntry(lps[0], 5 ether);        // levered: range E0 + openLev at ZERO leverage
        _rangeE0(lps[1], 5 ether);             // unlevered: identical range deposit, NO openLev
        uint principalEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        (uint unlevPooled0,,,) = ETH.autoManaged(lps[1]);

        // ONE shared REAL rally ⇒ identical price-path IL on BOTH range positions.
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        assertGt(venue.debtOf(lps[0]), 0, "levered LP hedged: debt = IL target > 0");

        // (1) LEVERED LP IL-protected: ETH exposure preserved despite the range selling ETH.
        assertApproxEqRel(lm.netEquity(lps[0]), principalEth, 0.05e18,
            "(1) levered: net-equity (ETH exposure) preserved = IL cancelled by the hedge");

        // (3) NO CROSS-SUBSIDY: mint the levered depth; the unlevered LP's claim + basket TVL are untouched.
        _calmVol();
        uint tvlPre = _tvl();
        (uint unlevPre,,,) = ETH.autoManaged(lps[1]);
        ETH.syncLev(lps[0]);
        (uint unlevPost,,,) = ETH.autoManaged(lps[1]);
        assertEq(unlevPost, unlevPre, "(3) levered sync did NOT touch the unlevered LP's pooled claim");
        assertGe(_tvl(), tvlPre, "(3) levered sync took nothing from the basket (no cross-subsidy)");

        // (3b) FULL-2x PROOF: the synced range depth is the GROSS collateral (2x, net-equity + the debt-funded
        //   buffer), NOT just net-equity. Post-fold the buffer folds into the ONE POOLED_USD slice and
        //   `committedUsd18` EXCLUDES it by subtracting the LP's LIVE leverage debt (buffer == debt), so
        //   committed + totalDebtUsd == the full in-range USD. Live ⇒ no stale segregation counter to desync.
        // Post net-equity rewrite (#52/#53) the levered depth is SPLIT: `levPooled` = the NET leg, `levBuf` =
        // the debt-funded buffer, and the range CAPACITY = their sum == GROSS collateral (Quid._reconcileLev:
        // `gross == levPooled[lp] + levBuf[lp]`). The old assertion compared levPooled ALONE to gross (missing
        // levBuf), so its gap grew with leverage. Assert the true identity: net leg + buffer == gross (full-2×).
        assertApproxEqRel(ETH.levPooled(lps[0]) + ETH.levBuf(lps[0]), lm.grossCollateral(lps[0]), 0.05e18,
            "(3b) full-2x: range CAPACITY (net leg levPooled + debt buffer levBuf) == GROSS collateral (2x)");
        assertGt(lm.grossCollateral(lps[0]), lm.netEquity(lps[0]),
            "(3b) full-2x: gross > net => a real debt-funded buffer is in the range");
        assertGt(lm.totalDebtUsd(), 0, "(3b) full-2x: a real debt-funded buffer exists (live leverage debt > 0)");
        // §#12 RE-DERIVED: same claim — committed EXCLUDES the debt-funded buffer — but measured
        // against BASKET-SUPPLIED depth rather than curve inventory, because committed no longer
        // tracks what a swap put in the curve. The buffer folds into `basketUsd*` at `addLiq`
        // (mod path) exactly as it used to fold into `POOLED_USD_*`, so the identity still bites.
        // §LEV-CLUSTER INSTRUMENT — this identity is stated in DOLLARS, so it fails either because
        // `totalDebtUsd` is too small (the position never levered to the target the fixture assumes)
        // or because `committedUsd18` is not the quantity the identity names. The trio separates
        // them: `ilTarget` UNDER the 300 bps dead-band means the manager had no reason to borrow, so
        // the "debt-funded buffer" this assertion subtracts barely exists — a CALIBRATION cause
        // shared with the two siblings. `ilTarget` OVER 300 with `debtOf`/`currentLtv` still low is a
        // levering bug and belongs to a separate investigation.
        emit log_named_uint("(3b) lp0 ilTargetLtvBps    ", lm.ilTargetLtvBps(lps[0]));
        emit log_named_uint("(3b) lp0 venue.debtOf      ", venue.debtOf(lps[0]));
        emit log_named_uint("(3b) lp0 currentLtvBps     ", lm.getCurrentLtvBps(lps[0]));
        emit log_named_uint("(3b) lm.totalDebtUsd       ", lm.totalDebtUsd());
        emit log_named_uint("(3b) CORE.committedUsd18   ", CORE.committedUsd18());
        emit log_named_uint("(3b) CORE.basketUsd (6d)   ", CORE.basketUsd());
        emit log_named_uint("(3b) ETH.levPooled(lp0)    ", ETH.levPooled(lps[0]));
        emit log_named_uint("(3b) ETH.levBuf(lp0)       ", ETH.levBuf(lps[0]));
        assertEq(CORE.committedUsd18() + lm.totalDebtUsd(),
                 (CORE.basketUsd() + CORE.basketUsd()) * 1e12,
            "(3b) full-2x: committed EXCLUDES the debt-funded buffer (committed == basket depth - live debt)");

        // (4) NO RACE: syncLev idempotent — a second call with no equity change is a no-op (no double-credit).
        uint levSlice = ETH.levPooled(lps[0]);
        ETH.syncLev(lps[0]);
        assertEq(ETH.levPooled(lps[0]), levSlice, "(4) syncLev idempotent - no double-credit of the levered slice");

        // (2) The IL is REAL and ONLY the UNLEVERED LP bears it. (A direct withdraw-IL measurement is unreliable
        //     on the fork: the mock range moves but takeETH delivers from real venues at the real price, so the
        //     price would have to be reseated to deliver — which round-trips the move and erases the IL. The
        //     deterministic proof is the sold fraction + the hedge differential.)
        uint sold = ETH.soldFractionWad(_entryPrice(lps[0]));
        assertGt(sold, 0, "(2) the range SOLD ETH on the rally => IL accrued to every range LP");
        // The UNLEVERED LP has NO leverage position => zero hedge => it bears the full sold fraction as IL.
        ( , , , , , bool unlevOpen) = lm.pos(lps[1]);
        assertTrue(!unlevOpen, "(2) unlevered LP is unhedged (no lev position) => bears the full sold-fraction IL");
        // The LEVERED LP DOES hedge exactly that sold fraction (debt/E0 == sold fraction), so its ETH exposure is
        // preserved per (1) — one takes the IL, the other doesn't, from the SAME shared range move.
        assertApproxEqAbs(lm.ilLtvBps(lps[0]) * 1e14, sold, 0.06e18,
            "(2) levered: the hedge (debt/E0) tracks the sold fraction => IL cancelled");
        assertLt(unlevPooled0, 5 ether + 1, "sanity: unlevered opened with ~5 ETH pooled");
    }

    /// @notice BUFFER EXHAUSTION (the violent tail): beyond the 2x cap the IL target saturates and the LP bears the
    ///   residual IL — isolated, never the basket, never a force-close. At 9x the raw target is 66.7% but MUST cap
    ///   at 50%.
    function test_BufferExhaustion_CapBindsAtViolentMove() public {
        _setupLev();
        _openAtEntry(lps[0], 10 ether);
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.mockCall(address(AUX),
            abi.encodeWithSelector(AUX.getTWAPforAsset.selector, address(WETH), uint32(1800)), abi.encode(px * 9));
        // The VIEW proves the target saturates: raw 1−1/√9 = 66.7% but the per-position cap binds at 50% (2x).
        assertEq(lm.ilTargetLtvBps(lps[0]), 5000, "violent move => IL target capped at the per-position cap (2x)");
        // Levering toward a 9x-inflated target can't physically execute on the REAL Morpho market — its oracle
        // prices the weETH collateral at the TRUE price, so the borrow hits "insufficient collateral" and stops.
        // That IS the buffer exhausting: the LP can't over-lever past what real collateral supports, bears the
        // residual IL, and the position is NEVER force-closed. (The keeper's rebalance reverts are swallowed.)
        for (uint k; k < 8; k++) { try lm.rebalance(lps[0], 0) {} catch {} }
        uint ltv = lm.getCurrentLtvBps(lps[0]);
        emit log_named_uint("levered LTV at 9x (real Morpho caps the borrow)", ltv);
        assertLe(ltv, 5000 + 300, "must NOT lever past the 2x cap (residual IL borne by the LP)");
        ( , , , , , bool open) = lm.pos(lps[0]);
        assertTrue(open, "position stays open (LP bears the residual, isolated - no force-close)");
        vm.clearMockedCalls();
    }

    /// @notice REGRESSION (#26) — the leverage lifecycle NEVER mints or burns QUID. The whole IL-protect is
    ///   funded by the EXTERNAL venue (Morpho flash + collateral sale via ether.fi/V3), so no unmatured/unbacked
    ///   QUID is ever created to open, lever, de-lever, or close a position. Asserting `QUID.totalSupply()` is
    ///   invariant around EACH leverage call (measured in isolation from the rally/crash basket swaps) is the
    ///   hard gate that the old "burn unmatured QD to maintain a Trove" vector (dead Liquity design) can't exist.
    function test_Leverage_NeverMintsOrBurnsQuid() public {
        _setupLev();

        uint s0 = QUID.totalSupply();
        _rangeE0(lps[0], 5 ether);
        _openLevOnly(lps[0], 5 ether);
        assertEq(QUID.totalSupply(), s0, "open: leverage must not mint/burn QUID");

        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        uint s1 = QUID.totalSupply();
        lm.rebalance(lps[0], 0);
        assertEq(QUID.totalSupply(), s1, "rebalance/lever-up: leverage must not mint/burn QUID");

        _crashRange(3000, 24, 40 ether);
        address[] memory batch = new address[](1); batch[0] = lps[0];
        uint[] memory mins = new uint[](1);
        uint s2 = QUID.totalSupply();
        lm.cascadeDelever(batch, mins);
        assertEq(QUID.totalSupply(), s2, "de-lever: leverage must not mint/burn QUID");
        // (closeLev's QUID-neutrality is the same code paths — no QUID.mint/burn anywhere in LevManager — and is
        // exercised by LevYbReal's testReal_Euler_CloseUnwindsFully. It's omitted here because closing while the
        // range feed is still CRASHED (no _realignRangeToReal, which LevYbReal does before its close) diverges from
        // real-Uniswap execution — a fork artifact, not a QUID/close bug.)
    }


    /// @notice (A) INTRINSIC DEPOSIT MODEL — the capital-efficiency win. A levered LP makes ONE deposit and does
    ///   ONLY `openLev` (NO separate `ETH.deposit` range position). Proves E0 comes from the deposit ITSELF, the
    ///   single deposit's net-equity IS the LP's entire range presence, and `syncLev` turns it into IL-free range
    ///   depth — so the LP hedges with one capital leg, not a principal-range-plus-separate-buffer (the old (B)).
    function test_A_IntrinsicOneDeposit_IsTheLeverageBase() public {
        _setupLev();
        EV.setLevManager(address(lm));
        address lp = address(0xBEEF8);

        // (A): ONE deposit — mint weETH + openLev. Deliberately NO ETH.deposit (the LP has no separate range).
        deal(WEETH, lp, 5 ether);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), 5 ether);
        lm.openLev(5000, ILevVenue(address(venue)), 5 ether, mins);
        vm.stopPrank();

        // E0 = the deposit itself (weETH→ETH via the ether.fi rate), NOT a separate range position (there is none).
        uint depositEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        ( , , , uint128 entryEquity, , ) = lm.pos(lp);
        assertApproxEqAbs(uint(entryEquity), depositEth, 1e15, "(A): E0 == the single deposit, not a separate range slice");
        // Zero leverage at open ⇒ the deposit's net-equity == the deposit; it IS the LP's entire range presence.
        assertApproxEqAbs(lm.netEquity(lp), depositEth, 1e15, "(A): net-equity == the single deposit");

        // syncLev turns the single deposit into the LP's IL-free levered range slice — no principal range needed.
        uint pe0 = CORE.POOLED();
        ETH.syncLev(lp);
        assertApproxEqAbs(ETH.levPooled(lp), depositEth, 2e15, "(A): the single deposit IS the levered range slice");
        assertGt(CORE.POOLED(), pe0, "(A): the one deposit deepened the range as levPooled (capital-efficient)");
    }

    // ─────────────────────────── #36 venue safety gates (REAL Morpho venue) ───────────────────────────

    /// @notice (#36a) init must REJECT a real venue whose collateral the manager cannot value (not WETH/weETH):
    ///   a WBTC-collateral Morpho market would inject phantom ETH backing into rangeETH. GOV can't pin it.
    function test_LevVenueGate_InitRejectsUnvaluableCollateral() public {
        _setupLev();   // establishes mOracle + the good (weETH) reference stack
        LevManager lm2 = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        MarketParams memory badMp = MarketParams({
            loanToken: address(USDC), collateralToken: address(WBTC),   // WBTC collateral: NOT weETH/WETH
            oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18 });
        MorphoEscrowVenue bad = new MorphoEscrowVenue(MORPHO, badMp, address(lm2));
        address[] memory vs = new address[](1); vs[0] = address(bad);
        vm.expectRevert(LevMath.BadCollateral.selector);
        lm2.init(address(ETH), MORPHO, vs);
    }

    /// @notice (#36b) openLev must REJECT a NEW position onto an incident-flagged venue (GOV setVaultHealth) --
    ///   fresh collateral must never land on a broken market. Close/rebalance stay OPEN (not asserted here).
    function test_LevVenueGate_OpenRejectsBlockedVenue() public {
        _setupLev();
        EV.setLevManager(address(lm));
        AUX.setVaultHealth(address(venue), true);   // real incident flag (AUX owner == this test)
        uint256[] memory mins = new uint256[](0);
        vm.prank(lps[0]);
        vm.expectRevert(LevMath.VenueBlocked.selector);
        lm.openLev(5000, ILevVenue(address(venue)), 5 ether, mins);
    }

    // ═════════════════════════ V1b — PRE-UNIFICATION CONTROL ═════════════════════════
    //
    // `committedUsd18()` is `_rangeEquityUsd18(false) + _rangeEquityUsd18(true)`, each term floored
    // at ZERO **PER RANGE** (`Core.sol:112-116`), so one range's leverage debt can never eat the
    // other range's equity. The `POOLED_USD` unification merges those counters, and the naive form
    // takes a SINGLE floor over the unified total:
    //
    //      per-range (today):  max(0, ethUsd - ethDebt) + max(0, btcUsd - btcDebt)
    //      unified (naive) :  max(0, (ethUsd + btcUsd) - (ethDebt + btcDebt))
    //
    // They agree while each range's debt is below its OWN USD leg. When one range's debt EXCEEDS its
    // own leg, the naive form lets that overflow eat the other range's equity, reporting LESS
    // committed — a LOOSER `committedUsd18() <= haircutTvl` gate that admits commitments the
    // per-range form rejects. Nothing reverts; the basket silently over-commits. Caveat B6.
    //
    // ⚠️ WHAT THIS TEST DOES AND DOES NOT COVER. `test_IlProtection_LeveredVsUnlevered_NoCrossSubsidy`
    // already pins `committed + totalDebtUsd == (both USD legs) x 1e12` with live debt — but that
    // is the SUM form, which is IDENTICAL under both definitions and therefore cannot discriminate
    // them. This test pins the PER-RANGE decomposition instead, which is the part the merge would
    // change. The fully discriminating case (one range's debt > its own USD leg) needs BTC-range
    // leverage or a deliberately thin ETH leg and is NOT built here — tracked as V1b-disc.
    function test_V1b_CommittedDecomposesPerRangeWithLiveLeverageDebt() public {
        _setupLev();
        EV.setLevManager(address(lm));
        vm.deal(address(this), 40 ether);
        ETH.deposit{value: 20 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);

        // Debt is entry-price-driven: `openLev` opens at ZERO leverage, so a rally is what creates
        // the IL hedge. Without it `totalDebtUsd() == 0` and the whole test is vacuous — the
        // PREMISE below caught exactly that on the first run.
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        _calmVol();
        ETH.syncLev(lps[0]);

        // SEED THE BTC RANGE. Without it `btcPooled18 == 0` and the cross-range assertion below is
        // `0 == 0` — it would "prove" that ETH debt cannot reach BTC equity while there is no BTC
        // equity to reach. `requestDeposit` is gated to BTCChannels, impersonated as in BtcRangeTheta.
        AUX.setBTCChannels(address(this));
        BTC.requestDeposit(User01, 2e7);          // 0.2 BTC

        uint debt = lm.totalDebtUsd();
        emit log_named_uint("live ETH leverage debt (18d)", debt);
        assertGt(debt, 0, "PREMISE: leverage debt must be outstanding, else the floor has nothing to floor");

        // §#12: the per-range floor now applies to the BASKET's contribution, not the curve leg.
        // §WRONG-RANGE — BOTH LEGS WERE `CORE.basketUsd()`, i.e. the SAME handle, the SAME call, so
        // `btcPooled18 == ethPooled18` BY CONSTRUCTION and the BTC leg was never read from the BTC
        // engine. `Aux.swap(USDC, WBTC, …)` settles on `_rangeOf(WBTC)`, which is the OTHER `Core`;
        // `Alles.t.sol:1404` records this exact class costing **246** failures plus four sibling
        // buckets, and it was fixed by making `Vault.CORE` public — a fix this file never adopted.
        uint ethPooled18 = CORE.basketUsd() * 1e12;
        uint btcPooled18 = BTC.CORE().basketUsd() * 1e12;
        uint committed   = CORE.committedUsd18();
        uint btcEquity   = BTC.CORE().rangeEquityUsd18();   // §WRONG-RANGE: the BTC engine's equity
        uint ethEquity   = committed - btcEquity;
        emit log_named_uint("ETH USD leg (18d)", ethPooled18);
        emit log_named_uint("BTC USD leg (18d)", btcPooled18);
        emit log_named_uint("committedUsd18   ", committed);
        emit log_named_uint("  ETH range equity", ethEquity);
        emit log_named_uint("  BTC range equity", btcEquity);

        // THE PER-RANGE DECOMPOSITION — the property the merge must preserve or consciously redefine.
        assertEq(ethEquity, ethPooled18 > debt ? ethPooled18 - debt : 0,
            "ETH range equity == its OWN BASKET DEPTH less its OWN debt, floored at 0");
        assertGt(btcPooled18, 0,
            "PREMISE: the BTC range must be SEEDED, else the cross-range assertion below is 0 == 0");
        assertEq(btcEquity, btcPooled18,
            "BTC range carries no debt here, so its equity is its FULL basket depth -- the ETH range's debt must NOT reach it");
        assertEq(committed, ethEquity + btcEquity,
            "committedUsd18 is the SUM OF PER-RANGE FLOORED equities, not one floor over the total");
        assertLt(committed, ethPooled18 + btcPooled18,
            "live debt must pull committed BELOW the raw two-leg sum, else the debt term is inert");
    }

    // ════════════════ V1b-disc — THE DISCRIMINATING CASE ════════════════
    //
    // V1b pins the per-range DECOMPOSITION, but while each range's debt stays below its own USD leg
    // both floors are non-binding and the per-range and single-floor definitions agree exactly. So
    // V1b — like `test_IlProtection_…:573` before it — passes under BOTH definitions and cannot
    // catch the merge going wrong. THIS is the case that can:
    //
    //   ethLeg = 1,000  ·  ethDebt = 3,522  ·  btcLeg = 11,542
    //     per-range  : max(0, 1000-3522) + max(0, 11542-0) = 0 + 11,542 = 11,542
    //     naive     : max(0, (1000+11542) - 3522)         =              9,020
    //
    // The naive form lets the ETH range's debt OVERFLOW into the BTC range's equity, reporting LESS
    // committed. `_poolUsdInRange` gates on `committedUsd18() <= haircutTvl`, so LESS committed is
    // a LOOSER gate — it admits commitments the per-range form rejects. Nothing reverts; the basket
    // silently over-commits, and the BTC range's LPs have quietly underwritten the ETH range's
    // leverage. Silent + plausible-but-wrong ⇒ standing rule 3's earns-a-check shape.
    //
    // Construction: establish real debt via the rally (openLev opens at ZERO leverage), seed the
    // BTC range, then DRAIN the ETH range's USD leg with sells until it falls BELOW the debt.
    function test_V1bdisc_OneRangesDebtExceedingItsOwnLegMustNotEatTheOther() public {
        _setupLev();
        EV.setLevManager(address(lm));
        vm.deal(address(this), 40 ether);
        ETH.deposit{value: 2 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);

        _rallyRange(_entryPrice(lps[0]), 0.2e18, 40, 16_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        _calmVol();
        ETH.syncLev(lps[0]);

        AUX.setBTCChannels(address(this));
        BTC.requestDeposit(User01, 2e7);                       // 0.2 BTC — the range that must stay whole

        uint debt = lm.totalDebtUsd();
        assertGt(debt, 0, "PREMISE: leverage debt must exist before we try to exceed a leg with it");

        // §#12/E28-r RE-DERIVED CONSTRUCTION, twice. (1) The ORIGINAL method drained the curve until
        // its USD leg fell below the debt — but draining is a SWAP, and after #12 a swap no longer
        // reduces the BASKET's contribution. (2) The replacement shrank the range by withdrawing the
        // plain LP position — which worked only while the basket leg came off FIRST-OUT; once E28-r
        // made that removal PROPORTIONAL, a 95% withdrawal left 95%-of-a-large-leg behind and the
        // premise stopped holding. Both times the premise assertion caught it rather than letting
        // the case go vacuous. What discriminates is a SMALL plain base with a LARGE debt, and the
        // reliable lever is the RALLY: it raises the debt (the manager re-borrows at target LTV)
        // while leaving the basket leg alone, exactly because of (1).
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        vm.prank(address(this));
        ++withdrawsAttempted;
        try ETH.withdraw(2 ether, address(this), address(this)) { ++withdrawsLanded; } catch {}
        emit log_named_uint("shrink withdraws landed    ", withdrawsLanded);
        emit log_named_uint("               attempted   ", withdrawsAttempted);
        // PREMISE: this withdraw IS the construction — it shrinks the plain base so the debt can
        // exceed the ETH leg. A swallowed revert leaves the base at full size and the premise
        // assertion below then fails for a reason that has nothing to do with leverage.
        assertGt(withdrawsLanded, 0, "PREMISE: the shrink withdraw actually ran (else the construction never happened)");
        vm.roll(block.number + 1); vm.warp(block.timestamp + 10 minutes);

        // §#12: the per-range floor now applies to the BASKET's contribution, not the curve leg.
        // §WRONG-RANGE — BOTH LEGS WERE `CORE.basketUsd()`, i.e. the SAME handle, the SAME call, so
        // `btcPooled18 == ethPooled18` BY CONSTRUCTION and the BTC leg was never read from the BTC
        // engine. `Aux.swap(USDC, WBTC, …)` settles on `_rangeOf(WBTC)`, which is the OTHER `Core`;
        // `Alles.t.sol:1404` records this exact class costing **246** failures plus four sibling
        // buckets, and it was fixed by making `Vault.CORE` public — a fix this file never adopted.
        uint ethPooled18 = CORE.basketUsd() * 1e12;
        uint btcPooled18 = BTC.CORE().basketUsd() * 1e12;
        debt = lm.totalDebtUsd();                             // re-read: the drain may have moved it
        uint committed = CORE.committedUsd18();
        uint btcEquity = BTC.CORE().rangeEquityUsd18();     // §WRONG-RANGE: the BTC engine's equity
        emit log_named_uint("ETH USD leg (18d)", ethPooled18);
        emit log_named_uint("ETH debt    (18d)", debt);
        emit log_named_uint("BTC USD leg (18d)", btcPooled18);
        emit log_named_uint("committedUsd18   ", committed);
        emit log_named_uint("  BTC range equity", btcEquity);
        // §LEV-CLUSTER INSTRUMENT — the measured miss is 8x in the OPPOSITE direction from the
        // construction's intent (debt 547e18 against a 79,187e18 leg), i.e. the DEBT is tiny, not the
        // leg large. Two candidate causes and this trio tells them apart. (i) `ilTarget` UNDER the
        // 300 bps dead-band ⇒ `lm.rebalance` had nothing to do, the rally never re-borrowed, and
        // `totalDebtUsd` is only entry dust — the CALIBRATION cause the two siblings may share.
        // (ii) `ilTarget` OVER 300 with `debtOf`/`currentLtv` still near zero ⇒ the borrow was
        // attempted and did not land: a levering defect, NOT shared with them.
        // ⚠️ `totalDebtUsd` is protocol-wide while `debtOf`/`currentLtv` are per-LP. If those two
        // disagree the fault is an aggregation or wrong-instance read — a THIRD cause, and the same
        // class the §WRONG-RANGE note above records. Do not group the three until these numbers say so.
        emit log_named_uint("  lp0 ilTargetLtvBps", lm.ilTargetLtvBps(lps[0]));
        emit log_named_uint("  lp0 venue.debtOf  ", venue.debtOf(lps[0]));
        emit log_named_uint("  lp0 currentLtvBps ", lm.getCurrentLtvBps(lps[0]));
        emit log_named_uint("  lp0 netEquity     ", lm.netEquity(lps[0]));
        emit log_named_uint("  lp0 grossColl     ", lm.grossCollateral(lps[0]));

        // PREMISES — without BOTH of these the case is not the discriminating one and the
        // assertions below hold under either definition.
        assertGt(debt, ethPooled18,
            "PREMISE: the ETH range's debt must EXCEED its own USD leg, else both definitions agree");
        assertGt(btcPooled18, 0,
            "PREMISE: the BTC range must hold equity for the overflow to be able to eat");

        // THE DISCRIMINATOR. Per-range: the ETH range floors at 0 and the BTC range is untouched, so
        // committed is EXACTLY the BTC leg. The naive single floor would instead return
        // `(ethLeg + btcLeg) - debt`, which is strictly SMALLER here.
        assertEq(btcEquity, btcPooled18,
            "the ETH range's excess debt must NOT reach the BTC range's equity");
        assertEq(committed, btcPooled18,
            "committed == the BTC basket depth alone: the ETH range floors at ZERO, its overflow is NOT netted against BTC");
        assertGt(committed, ethPooled18 + btcPooled18 > debt ? ethPooled18 + btcPooled18 - debt : 0,
            "per-range flooring must report STRICTLY MORE committed than a single floor over the total");
    }
}
