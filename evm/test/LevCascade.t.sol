// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/ILevVenue.sol";
import {MorphoEscrowVenue, MarketParams} from "../src/MorphoEscrowVenue.sol";
import {LevMath} from "../src/imports/LevMath.sol";

interface IERC20R {
    function approve(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
}

interface IChainlinkFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IWeETHRateT { function getEETHByWeETH(uint) external view returns (uint); }

/// Fuller Morpho Blue surface (create a real market + seed borrow liquidity + authorize + liquidate).
interface IMorphoTest {
    function createMarket(MarketParams memory m) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256, uint256);
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function accrueInterest(MarketParams memory m) external;
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128);
}
interface IMorphoOraclePrice { function price() external view returns (uint256); }
interface IVaultRoverT { function ROVER() external view returns (address); }

/// Morpho IOracle (`price()` = collateral→loan, 1e36-scaled). NOT a mock — REAL sources: weETH→ETH (ether.fi
/// getEETHByWeETH) x ETH→USD (REAL Chainlink ETH/USD). Morpho scale weETH(18)→USDC(6): price = weETH_USD(1e18)x1e6.
/// A "crash" overrides the SAME real ETH/USD feed (one drawdown moves this AND our band oracle), no hardcoded price.
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
///   leveraged positions on a REAL Morpho Blue market + the REAL Vogue V4 band as the E0/sold-fraction source, all
///   levered by a REAL band rally (genuine IL), then crashed so they breach their de-lever band together, then
///   `cascadeDelever`ed in one tx — asserting each is de-levered or gracefully skipped, isolated, with net progress.
///   The mocks (MockWeeth/MockSwapper/MaliciousSwapper/MockBandHost/MockFlashLender/TestLevVenue) are DELETED; the
///   folded LevManager mints/redeems real weETH via ether.fi + routes stable legs through the basket SOR, and the
///   venue/flash/liquidation are the LIVE Morpho singleton. Mirrors LevYbReal's real-venue scaffolding.
contract LevCascadeProbe is Alles {
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
        // Wire the YB stack against the real venue + the REAL Vogue band (V4) as the BAND-ONLY E0 / sold-fraction
        // source — NO MockBandHost — + the real Morpho flash (zero-fee repay-first de-lever). One atomic pin-once.
        lm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        venue = new MorphoEscrowVenue(MORPHO, mp, address(lm));
        address[] memory vs = new address[](1); vs[0] = address(venue);
        lm.init(address(V4), MORPHO, vs);

        // PIN THE ETH/USD ANCHOR (2026-07-26, BUILD-QUEUE §A.13). This fixture already maintains
        // `ETH_FEED` as a pool-tracking mock (`_setEthFeed`, refreshed every crash/rally step) but never
        // registered it with Aux, so `assetPriceFeed(WETH)` was address(0) — MEASURED. With no anchor,
        // once a crash walks the pool to its tick boundary `getTWAPforAsset` returns 0 and
        // `rebalanceCore`'s `if (twap == 0) return r` leaves `didRepack == false`, so `addLiq` never
        // runs and the band can never be re-paired. Registering the tracking feed is what lets the
        // twapResolve anchor fall-through actually rescue this fixture, exactly as the real deploy
        // pins Chainlink (DeployL1_s:326).
        _setEthFeed(AUX.getTWAPforAsset(address(WETH), 1800) / 1e10);   // seed it before pinning
        AUX.setAssetFeed(address(WETH), ETH_FEED);
    }

    /// Seed REAL basket POOLED_USD surplus (mint QUID against USDC) so syncLev can pair the levered band slice.
    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// Move the REAL V4 band UP by buying WETH out of it in bounded steps (each under the 50bps/swap manip cap),
    /// warping between so each step measures from spot≈TWAP and the guard resets. Real swaps only — the band sells
    /// ETH → real IL accrues; kept under the 5% Chainlink anchor so no reseat/no oracle override. Self-calibrating.
    function _rallyBand(uint160 entrySqrt, uint targetWad, uint maxSteps, uint usdcPerStep) internal {
        deal(address(USDC), address(this), maxSteps * usdcPerStep);
        IERC20R(address(USDC)).approve(address(AUX), maxSteps * usdcPerStep);
        for (uint i; i < maxSteps; i++) {
            if (V4.soldFractionWad(entrySqrt) >= targetWad) break;
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px == 0) break;
            _setEthFeed(px / 1e10);
            try AUX.swap(address(USDC), address(WETH), true, usdcPerStep, 0) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Real DOWN move: sell ETH into the band so the mark crashes ~`dropBps` (drives the venue-safety de-lever).
    function _crashBand(uint dropBps, uint maxSteps, uint ethPerStep) internal {
        uint start = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.deal(address(this), maxSteps * ethPerStep);
        for (uint i; i < maxSteps; i++) {
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px == 0) break;
            if (px <= start - start * dropBps / 10000) break;
            _setEthFeed(px / 1e10);
            try AUX.swap{value: ethPerStep}(address(USDC), address(WETH), false, 0, 0) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Calm realized vol after a rally so θ=yield/(K·σ²) recovers (the θ-budget cap refuses new band depth while vol
    /// is elevated). The realistic sequence: an IL event, then vol calms — what lets syncLev add the levered depth.
    function _calmVol() internal {
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        vm.deal(address(this), 20 ether);
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            if (i % 2 == 0) { try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0) {} catch {} }
            else            { try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0) {} catch {} }
        }
    }

    /// Realign the band oracle to the REAL Chainlink market before a real weETH↔stable leg / basket reconcile
    /// (the rally elevates the mock-token band feed we can move; the leverage's external legs execute on REAL
    /// Uniswap which we can't — a fork artifact fix, matches LevYbReal).
    function _realignBandToReal() internal {
        (, int256 clp,,,) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        _setEthFeed(uint(clp)); V4.reseat();
    }

    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }
    function _entrySqrt(address lp) internal view returns (uint160 s) { ( , , , , s, ) = lm.pos(lp); }

    /// REAL Morpho seizure of `lp`: realign the band oracle to the market, crash the SHARED Chainlink feed so the
    /// position lands ~92% LTV (liquidatable per lltv 0.86, not deep bad debt), then liquidate by REPAID SHARES
    /// (a fraction of the ACTUAL debt — never `seizedAssets`, which over-repays a tiny debt and underflows
    /// Morpho's `borrowShares -= repaidShares`). Repays `numer/denom` of the debt; leaves the position smaller.
    function _seizeReal(address lp, uint numer, uint denom) internal {
        _realignBandToReal();
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
        _realignBandToReal();
    }

    /// Establish `lp`'s REAL band position (the E0 IL base, read live from V4) — a genuine ETH band deposit,
    /// which (unlike the old MockBandHost.setBand) ITSELF adds to `vogueETH`, so tests that measure the
    /// leverage's OWN vogueETH contribution must baseline AFTER this (see `_openLevOnly`). Also mints the LP's
    /// weETH equity + does the one-time Morpho authorization.
    function _bandE0(address lp, uint sizeEth) internal {
        vm.deal(lp, sizeEth + 1 ether);
        vm.prank(lp); V4.deposit{value: sizeEth}(0, lp);   // venue 3 = all-Galaxy (no offramp noise)
        deal(WEETH, lp, sizeEth);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true); // one-time Morpho isolation
    }

    /// Open at ZERO leverage against the already-established band position (entry pinned from V4.bandSqrtP).
    function _openLevOnly(address lp, uint sizeEth) internal {
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), sizeEth);
        lm.openLev(5000, ILevVenue(address(venue)), sizeEth, mins); // cap = 2x; opens at ZERO leverage
        vm.stopPrank();
    }

    function _openAtEntry(address lp, uint sizeEth) internal { _bandE0(lp, sizeEth); _openLevOnly(lp, sizeEth); }

    // ═══════════════════════════════ tests ═══════════════════════════════

    /// FOUNDATION PROOF — net-equity backing + seizure-safety. The levered weETH's NET-of-debt equity is recognized
    /// in `vogueETH` (backs the band), and a REAL Morpho liquidation removes that credit cleanly while `POOLED_USD`
    /// stays intact — no socialization.
    function test_NetEquity_BackingRecognized_SeizureLeavesPooledUsdIntact() public {
        _setupLev();
        ETH.setLevManager(address(lm));                         // pin the leveraged book into vogueETH

        // Establish the REAL band position FIRST, then baseline — the band deposit itself adds to vogueETH
        // (unlike the old mock), so the leverage's OWN contribution is measured from the post-deposit baseline.
        _bandE0(lps[0], 5 ether);
        uint vogue0 = AUX.vogueETH();

        // Open at entry ⇒ ZERO leverage ⇒ net-equity == principal (weETH→ETH via the real staking rate).
        _openLevOnly(lps[0], 5 ether);
        uint principalEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        assertApproxEqAbs(lm.netEquityEth(lps[0]), principalEth, 1e15, "open: net-equity == principal");
        assertApproxEqAbs(AUX.vogueETH(), vogue0 + principalEth, 1e15, "open: vogueETH gains exactly the net-equity");

        // Lever up on a REAL band rally (real IL): debt > 0, but the borrow is self-financing ⇒ equity ~principal.
        // (A real rally executes real swaps, which legitimately move POOLED_USD — so the mock's "POOLED_USD frozen
        // across the lever" assertion is unmeasurable here; the real invariant is deliverable-covers-band, below.)
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        assertGt(venue.debtOf(lps[0]), 0, "levered: real Morpho debt > 0");
        assertGe(AUX.vogueETH(), CORE.POOLED_ETH(), "levered: deliverable ETH still covers the band");

        // SEIZE via a REAL Morpho liquidation (repay half the debt by shares — see `_seizeReal`).
        uint tvl0 = _tvl();
        uint vdebt = venue.debtOf(lps[0]);
        _seizeReal(lps[0], 1, 2);
        assertLt(venue.debtOf(lps[0]), vdebt, "seize: REAL Morpho liquidation reduced the debt");

        // Basket clean: the liquidation took NOTHING from the basket (TVL intact) and deliverable ETH still
        // covers the band — the loss is isolated to the LP's Morpho account, never socialized.
        assertGe(_tvl(), tvl0, "seized: basket real backing (TVL) intact - nothing socialized");
        assertGe(AUX.vogueETH(), CORE.POOLED_ETH(), "seized: deliverable ETH still covers the band");
    }

    /// FEE-LANE PROOF: the levered weETH equity (a) EARNS band fees via the same machinery as a weETH deposit,
    /// (b) is UNWIND-ONLY (the free ladder can't pull it), and (c) a REAL seizure burns the slice clean.
    function test_LevFeeLane_EarnsFees_UnwindOnly_SeizureBurnsClean() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        // Thicken the band with a normal ETH-LP so small swaps clear the manip guard.
        vm.deal(address(this), 20 ether);
        V4.deposit{value: 10 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);                                 // real levered position
        _calmVol();                                             // θ recovers ⇒ syncLev can add the depth

        uint pu0 = CORE.POOLED_USD_ETH();
        V4.syncLev(lps[0]);                                     // mint the levered band slice (tokenless)
        uint lev = V4.levPooled(lps[0]);
        assertGt(lev, 0, "syncLev minted the levered slice into the band");
        // The levered slice is IN the band's depth. NOT "grew at this instant": `lm.rebalance` above
        // already minted it through the manager's syncLev HOOK, so the explicit `V4.syncLev` here is
        // IDEMPOTENT and `pe0` (captured after the rebalance) already contains the slice. MEASURED:
        // levPooled 5.503 and levBuf 1.507 are both already live, while POOLED_ETH moves by -23 wei of
        // modLP rounding — so the old `assertGt(POOLED_ETH, pe0)` was asserting a transition that had
        // already happened, and could only ever pass or fail on rounding noise.
        assertGe(CORE.POOLED_ETH(), lev, "the levered slice is part of the band's in-range depth");
        assertGt(V4.levBuf(lps[0]), 0, "the debt-funded buffer is live and fee-earning");
        // SAME DEFECT AS THE `pe0` ASSERTION ABOVE, fixed the same way. `pu0` is captured AFTER
        // `lm.rebalance`, which already minted the slice via the manager's syncLev hook, so the explicit
        // `V4.syncLev` is IDEMPOTENT and POOLED_USD cannot GROW here. The old `assertGt(.., pu0)` was
        // asserting a transition that had already happened, and could only pass or fail on modLP
        // rounding — MEASURED at 3,596 of 6-dec USD ($0.0036), the same order as the -23 wei the ETH
        // side moves. Assert the STATE that matters (USD is paired against the levered slice, so the
        // depth is in-range and fee-earning) rather than a delta that is pure noise.
        assertGt(CORE.POOLED_USD_ETH(), 0, "POOLED_USD paired against it (in-range, fee-earning)");

        // (a) small swaps generate band fees; the levered LP IS band depth.
        for (uint i; i < 10; i++) {
            try AUX.swap{value: 0.2 ether}(address(USDC), address(WETH), false, 0, 0) returns (uint) {} catch {}
            vm.roll(vm.getBlockNumber() + 1);
        }
        (uint ethR, uint usdR) = V4.pendingRewards(lps[0]);
        assertGt(ethR + usdR, 0, "(a) levered LP ACCRUES band fees on its equity");

        // (b) UNWIND-ONLY: the free ladder cannot pull the levered slice.
        vm.prank(lps[0]);
        try V4.withdraw(type(uint).max, lps[0], lps[0]) {} catch {}
        assertEq(V4.levPooled(lps[0]), lev, "free withdraw leaves the levered slice untouched");

        // (c) SEIZE via REAL Morpho liquidation → syncLev burns the slice clean.
        _seizeReal(lps[0], 1, 2);
        V4.syncLev(lps[0]);
        assertLt(V4.levPooled(lps[0]), lev, "seizure: levered slice shrank/burned toward the liquidated equity");
    }

    /// CRITICAL: a caller-supplied, NON-allowlisted venue (which could return phantom collateral → fake vogueETH →
    /// ETH-LP drain) is rejected. Only pinned adapters can be opened against.
    function test_VenueAllowlist_BlocksUnvettedVenue() public {
        _setupLev();
        MorphoEscrowVenue rogue = new MorphoEscrowVenue(MORPHO, mp, address(lm)); // real, but NOT pinned
        _openAtEntry(lps[0], 5 ether); // establishes a band position for lps[0]
        // Fresh LP so the AlreadyOpen guard doesn't mask the venue check.
        address lp = address(0xBEEF4);
        vm.deal(lp, 6 ether);
        vm.prank(lp); V4.deposit{value: 5 ether}(0, lp);
        deal(WEETH, lp, 5 ether);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(rogue), true);
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), 5 ether);
        vm.expectRevert(LevManager.VenueNotAllowed.selector);
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
        _rallyBand(_entrySqrt(lp), 0.2e18, 24, 8_000 * USDC_PRECISION);
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
        // Heal the no-CRE fork's spurious default depeg on the redeemed legs (as DrainProbe does), so the band's
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
        // 3 levered LPs on the SHARED real band (small so each loop's SOR buy stays under the manip cap).
        _openAtEntry(lps[0], 5 ether);
        _openAtEntry(lps[1], 4 ether);
        _openAtEntry(lps[2], 3 ether);
        // ONE shared REAL rally ⇒ correlated IL for all three ⇒ lever each up to the IL target.
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 24, 8_000 * USDC_PRECISION);
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
        _crashBand(3000, 24, 40 ether);

        address[] memory batch = new address[](3);
        uint[] memory mins = new uint[](3);
        batch[0] = lps[0]; batch[1] = lps[1]; batch[2] = lps[2];
        vm.recordLogs();
        lm.cascadeDelever(batch, mins);

        // Assert only what IS invariant (this rides the UNPINNED real band; magnitudes vary block-to-block):
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
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 24, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0); vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        lm.rebalance(lps[1], 0); vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        _crashBand(3000, 24, 40 ether);   // ~30%: full de-lever; hybrid down-leg services the redeem

        // BRICK lp0: revoke the adapter's Morpho authorization ⇒ its withdraw can source nothing.
        vm.prank(lps[0]); IMorphoTest(MORPHO).setAuthorization(address(venue), false);

        uint dbt0 = venue.debtOf(lps[0]); uint coll0 = venue.collateralOf(lps[0]);
        uint dbt1 = venue.debtOf(lps[1]);

        address[] memory batch = new address[](2); batch[0] = lps[0]; batch[1] = lps[1];
        uint[] memory mins = new uint[](2);
        vm.recordLogs();
        lm.cascadeDelever(batch, mins);

        // lp0 (stuck): emitted DeleverFailed and its venue state is BYTE-for-byte unchanged (atomic revert).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint failed; bytes32 sig = keccak256("DeleverFailed(address,uint256)");
        for (uint j; j < logs.length; j++) if (logs[j].topics[0] == sig) failed++;
        assertEq(failed, 1, "the stuck LP must emit exactly one DeleverFailed");
        // The stuck LP's de-lever reverted atomically (no repay/withdraw for it). Its COLLATERAL is exactly
        // unchanged (Morpho collateral doesn't accrue); its DEBT only drifts up by market-wide interest that
        // lp1's real Morpho ops accrued — NOT a repay. So: collateral exact, debt within a small interest band.
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
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION); // IL accrues ⇒ a rebalance wants to lever
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

    /// @notice IL-PROTECTION PROOF — two EQUAL 5-ETH band LPs through ONE shared real rally, one levered, one not.
    ///   Proves the four things the design must guarantee:
    ///     (1) the LEVERED LP is IL-protected — its ETH exposure (net-equity) is preserved as the band sells ETH,
    ///         because the debt (the IL hedge) grows to exactly the sold fraction;
    ///     (2) the UNLEVERED LP eats the IL — withdrawing after the rally returns LESS ETH than it deposited (the
    ///         band sold its ETH on the way up);
    ///     (3) NO CROSS-SUBSIDY / not worsened — the levered LP's hedge is isolated at the venue: syncing its
    ///         levered slice leaves the unlevered LP's pooled claim AND the basket TVL untouched, so the unlevered
    ///         LP's IL is purely its own price-path IL, neither subsidized nor deepened by the levered LP;
    ///     (4) NO RACE — syncLev settles fees before moving pooled (Vogue.sol:513) and is idempotent, so a second
    ///         call with no equity change does not double-credit the levered slice.
    function test_IlProtection_LeveredVsUnlevered_NoCrossSubsidy() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        // Thick shared band so the rally's swaps clear the 50bps manip guard.
        vm.deal(address(this), 40 ether);
        V4.deposit{value: 20 ether}(0, address(this));

        // Two EQUAL band LPs: lps[0] levers, lps[1] stays a plain ETH-LP.
        _openAtEntry(lps[0], 5 ether);        // levered: band E0 + openLev at ZERO leverage
        _bandE0(lps[1], 5 ether);             // unlevered: identical band deposit, NO openLev
        uint principalEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        (uint unlevPooled0,,,) = V4.autoManaged(lps[1]);

        // ONE shared REAL rally ⇒ identical price-path IL on BOTH band positions.
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        assertGt(venue.debtOf(lps[0]), 0, "levered LP hedged: debt = IL target > 0");

        // (1) LEVERED LP IL-protected: ETH exposure preserved despite the band selling ETH.
        assertApproxEqRel(lm.netEquityEth(lps[0]), principalEth, 0.05e18,
            "(1) levered: net-equity (ETH exposure) preserved = IL cancelled by the hedge");

        // (3) NO CROSS-SUBSIDY: mint the levered depth; the unlevered LP's claim + basket TVL are untouched.
        _calmVol();
        uint tvlPre = _tvl();
        (uint unlevPre,,,) = V4.autoManaged(lps[1]);
        V4.syncLev(lps[0]);
        (uint unlevPost,,,) = V4.autoManaged(lps[1]);
        assertEq(unlevPost, unlevPre, "(3) levered sync did NOT touch the unlevered LP's pooled claim");
        assertGe(_tvl(), tvlPre, "(3) levered sync took nothing from the basket (no cross-subsidy)");

        // (3b) FULL-2x PROOF: the synced band depth is the GROSS collateral (2x, net-equity + the debt-funded
        //   buffer), NOT just net-equity. Post-fold the buffer folds into the ONE POOLED_USD_ETH slice and
        //   `committedUsd18` EXCLUDES it by subtracting the LP's LIVE leverage debt (buffer == debt), so
        //   committed + totalDebtUsd == the full in-range USD. Live ⇒ no stale segregation counter to desync.
        // Post net-equity rewrite (#52/#53) the levered depth is SPLIT: `levPooled` = the NET leg, `levBuf` =
        // the debt-funded buffer, and the band CAPACITY = their sum == GROSS collateral (Vogue._reconcileLev:
        // `gross == levPooled[lp] + levBuf[lp]`). The old assertion compared levPooled ALONE to gross (missing
        // levBuf), so its gap grew with leverage. Assert the true identity: net leg + buffer == gross (full-2×).
        assertApproxEqRel(V4.levPooled(lps[0]) + V4.levBuf(lps[0]), lm.grossCollateralEth(lps[0]), 0.05e18,
            "(3b) full-2x: band CAPACITY (net leg levPooled + debt buffer levBuf) == GROSS collateral (2x)");
        assertGt(lm.grossCollateralEth(lps[0]), lm.netEquityEth(lps[0]),
            "(3b) full-2x: gross > net => a real debt-funded buffer is in the band");
        assertGt(lm.totalDebtUsd(), 0, "(3b) full-2x: a real debt-funded buffer exists (live leverage debt > 0)");
        // §#12 RE-DERIVED: same claim — committed EXCLUDES the debt-funded buffer — but measured
        // against BASKET-SUPPLIED depth rather than curve inventory, because committed no longer
        // tracks what a swap put in the curve. The buffer folds into `basketUsd*` at `addLiq`
        // (mod path) exactly as it used to fold into `POOLED_USD_*`, so the identity still bites.
        assertEq(CORE.committedUsd18() + lm.totalDebtUsd(),
                 (CORE.basketUsdEth() + CORE.basketUsdBtc()) * 1e12,
            "(3b) full-2x: committed EXCLUDES the debt-funded buffer (committed == basket depth - live debt)");

        // (4) NO RACE: syncLev idempotent — a second call with no equity change is a no-op (no double-credit).
        uint levSlice = V4.levPooled(lps[0]);
        V4.syncLev(lps[0]);
        assertEq(V4.levPooled(lps[0]), levSlice, "(4) syncLev idempotent - no double-credit of the levered slice");

        // (2) The IL is REAL and ONLY the UNLEVERED LP bears it. (A direct withdraw-IL measurement is unreliable
        //     on the fork: the mock band moves but takeETH delivers from real venues at the real price, so the
        //     price would have to be reseated to deliver — which round-trips the move and erases the IL. The
        //     deterministic proof is the sold fraction + the hedge differential.)
        uint sold = V4.soldFractionWad(_entrySqrt(lps[0]));
        assertGt(sold, 0, "(2) the band SOLD ETH on the rally => IL accrued to every band LP");
        // The UNLEVERED LP has NO leverage position => zero hedge => it bears the full sold fraction as IL.
        ( , , , , , bool unlevOpen) = lm.pos(lps[1]);
        assertTrue(!unlevOpen, "(2) unlevered LP is unhedged (no lev position) => bears the full sold-fraction IL");
        // The LEVERED LP DOES hedge exactly that sold fraction (debt/E0 == sold fraction), so its ETH exposure is
        // preserved per (1) — one takes the IL, the other doesn't, from the SAME shared band move.
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
        _bandE0(lps[0], 5 ether);
        _openLevOnly(lps[0], 5 ether);
        assertEq(QUID.totalSupply(), s0, "open: leverage must not mint/burn QUID");

        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        uint s1 = QUID.totalSupply();
        lm.rebalance(lps[0], 0);
        assertEq(QUID.totalSupply(), s1, "rebalance/lever-up: leverage must not mint/burn QUID");

        _crashBand(3000, 24, 40 ether);
        address[] memory batch = new address[](1); batch[0] = lps[0];
        uint[] memory mins = new uint[](1);
        uint s2 = QUID.totalSupply();
        lm.cascadeDelever(batch, mins);
        assertEq(QUID.totalSupply(), s2, "de-lever: leverage must not mint/burn QUID");
        // (closeLev's QUID-neutrality is the same code paths — no QUID.mint/burn anywhere in LevManager — and is
        // exercised by LevYbReal's testReal_Euler_CloseUnwindsFully. It's omitted here because closing while the
        // band feed is still CRASHED (no _realignBandToReal, which LevYbReal does before its close) diverges from
        // real-Uniswap execution — a fork artifact, not a QUID/close bug.)
    }


    /// @notice (A) INTRINSIC DEPOSIT MODEL — the capital-efficiency win. A levered LP makes ONE deposit and does
    ///   ONLY `openLev` (NO separate `V4.deposit` band position). Proves E0 comes from the deposit ITSELF, the
    ///   single deposit's net-equity IS the LP's entire band presence, and `syncLev` turns it into IL-free band
    ///   depth — so the LP hedges with one capital leg, not a principal-band-plus-separate-buffer (the old (B)).
    function test_A_IntrinsicOneDeposit_IsTheLeverageBase() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        address lp = address(0xBEEF8);

        // (A): ONE deposit — mint weETH + openLev. Deliberately NO V4.deposit (the LP has no separate band).
        deal(WEETH, lp, 5 ether);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), 5 ether);
        lm.openLev(5000, ILevVenue(address(venue)), 5 ether, mins);
        vm.stopPrank();

        // E0 = the deposit itself (weETH→ETH via the ether.fi rate), NOT a separate band position (there is none).
        uint depositEth = IWeETHRateT(WEETH).getEETHByWeETH(5 ether);
        ( , , , uint128 e0, , ) = lm.pos(lp);
        assertApproxEqAbs(uint(e0), depositEth, 1e15, "(A): E0 == the single deposit, not a separate band slice");
        // Zero leverage at open ⇒ the deposit's net-equity == the deposit; it IS the LP's entire band presence.
        assertApproxEqAbs(lm.netEquityEth(lp), depositEth, 1e15, "(A): net-equity == the single deposit");

        // syncLev turns the single deposit into the LP's IL-free levered band slice — no principal band needed.
        uint pe0 = CORE.POOLED_ETH();
        V4.syncLev(lp);
        assertApproxEqAbs(V4.levPooled(lp), depositEth, 2e15, "(A): the single deposit IS the levered band slice");
        assertGt(CORE.POOLED_ETH(), pe0, "(A): the one deposit deepened the band as levPooled (capital-efficient)");
    }

    // ─────────────────────────── #36 venue safety gates (REAL Morpho venue) ───────────────────────────

    /// @notice (#36a) init must REJECT a real venue whose collateral the manager cannot value (not WETH/weETH):
    ///   a WBTC-collateral Morpho market would inject phantom ETH backing into vogueETH. GOV can't pin it.
    function test_LevVenueGate_InitRejectsUnvaluableCollateral() public {
        _setupLev();   // establishes mOracle + the good (weETH) reference stack
        LevManager lm2 = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        MarketParams memory badMp = MarketParams({
            loanToken: address(USDC), collateralToken: address(WBTC),   // WBTC collateral: NOT weETH/WETH
            oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18 });
        MorphoEscrowVenue bad = new MorphoEscrowVenue(MORPHO, badMp, address(lm2));
        address[] memory vs = new address[](1); vs[0] = address(bad);
        vm.expectRevert(LevMath.BadCollateral.selector);
        lm2.init(address(V4), MORPHO, vs);
    }

    /// @notice (#36b) openLev must REJECT a NEW position onto an incident-flagged venue (GOV setVaultHealth) --
    ///   fresh collateral must never land on a broken market. Close/rebalance stay OPEN (not asserted here).
    function test_LevVenueGate_OpenRejectsBlockedVenue() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        AUX.setVaultHealth(address(venue), true);   // real incident flag (AUX owner == this test)
        uint256[] memory mins = new uint256[](0);
        vm.prank(lps[0]);
        vm.expectRevert(LevMath.VenueBlocked.selector);
        lm.openLev(5000, ILevVenue(address(venue)), 5 ether, mins);
    }

    // ═════════════════════════ V1b — PRE-UNIFICATION CONTROL ═════════════════════════
    //
    // `committedUsd18()` is `_bandEquityUsd18(false) + _bandEquityUsd18(true)`, each term floored
    // at ZERO **PER BAND** (`Core.sol:112-116`), so one band's leverage debt can never eat the
    // other band's equity. The `POOLED_USD` unification merges those counters, and the naive form
    // takes a SINGLE floor over the unified total:
    //
    //      per-band (today):  max(0, ethUsd - ethDebt) + max(0, btcUsd - btcDebt)
    //      unified (naive) :  max(0, (ethUsd + btcUsd) - (ethDebt + btcDebt))
    //
    // They agree while each band's debt is below its OWN USD leg. When one band's debt EXCEEDS its
    // own leg, the naive form lets that overflow eat the other band's equity, reporting LESS
    // committed — a LOOSER `committedUsd18() <= haircutTvl` gate that admits commitments the
    // per-band form rejects. Nothing reverts; the basket silently over-commits. Caveat B6.
    //
    // ⚠️ WHAT THIS TEST DOES AND DOES NOT COVER. `test_IlProtection_LeveredVsUnlevered_NoCrossSubsidy`
    // already pins `committed + totalDebtUsd == (both USD legs) x 1e12` with live debt — but that
    // is the SUM form, which is IDENTICAL under both definitions and therefore cannot discriminate
    // them. This test pins the PER-BAND decomposition instead, which is the part the merge would
    // change. The fully discriminating case (one band's debt > its own USD leg) needs BTC-band
    // leverage or a deliberately thin ETH leg and is NOT built here — tracked as V1b-disc.
    function test_V1b_CommittedDecomposesPerBandWithLiveLeverageDebt() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        vm.deal(address(this), 40 ether);
        V4.deposit{value: 20 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);

        // Debt is entry-price-driven: `openLev` opens at ZERO leverage, so a rally is what creates
        // the IL hedge. Without it `totalDebtUsd() == 0` and the whole test is vacuous — the
        // PREMISE below caught exactly that on the first run.
        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        _calmVol();
        V4.syncLev(lps[0]);

        // SEED THE BTC BAND. Without it `btcPooled18 == 0` and the cross-band assertion below is
        // `0 == 0` — it would "prove" that ETH debt cannot reach BTC equity while there is no BTC
        // equity to reach. `registerBtcLp` is gated to BTCChannels, impersonated as in BtcBandTheta.
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);          // 0.2 BTC

        uint debt = lm.totalDebtUsd();
        emit log_named_uint("live ETH leverage debt (18d)", debt);
        assertGt(debt, 0, "PREMISE: leverage debt must be outstanding, else the floor has nothing to floor");

        // §#12: the per-band floor now applies to the BASKET's contribution, not the curve leg.
        uint ethPooled18 = CORE.basketUsdEth() * 1e12;
        uint btcPooled18 = CORE.basketUsdBtc() * 1e12;
        uint committed   = CORE.committedUsd18();
        uint btcEquity   = CORE.btcBandEquityUsd18();
        uint ethEquity   = committed - btcEquity;
        emit log_named_uint("ETH USD leg (18d)", ethPooled18);
        emit log_named_uint("BTC USD leg (18d)", btcPooled18);
        emit log_named_uint("committedUsd18   ", committed);
        emit log_named_uint("  ETH band equity", ethEquity);
        emit log_named_uint("  BTC band equity", btcEquity);

        // THE PER-BAND DECOMPOSITION — the property the merge must preserve or consciously redefine.
        assertEq(ethEquity, ethPooled18 > debt ? ethPooled18 - debt : 0,
            "ETH band equity == its OWN BASKET DEPTH less its OWN debt, floored at 0");
        assertGt(btcPooled18, 0,
            "PREMISE: the BTC band must be SEEDED, else the cross-band assertion below is 0 == 0");
        assertEq(btcEquity, btcPooled18,
            "BTC band carries no debt here, so its equity is its FULL basket depth -- the ETH band's debt must NOT reach it");
        assertEq(committed, ethEquity + btcEquity,
            "committedUsd18 is the SUM OF PER-BAND FLOORED equities, not one floor over the total");
        assertLt(committed, ethPooled18 + btcPooled18,
            "live debt must pull committed BELOW the raw two-leg sum, else the debt term is inert");
    }

    // ════════════════ V1b-disc — THE DISCRIMINATING CASE ════════════════
    //
    // V1b pins the per-band DECOMPOSITION, but while each band's debt stays below its own USD leg
    // both floors are non-binding and the per-band and single-floor definitions agree exactly. So
    // V1b — like `test_IlProtection_…:573` before it — passes under BOTH definitions and cannot
    // catch the merge going wrong. THIS is the case that can:
    //
    //   ethLeg = 1,000  ·  ethDebt = 3,522  ·  btcLeg = 11,542
    //     per-band  : max(0, 1000-3522) + max(0, 11542-0) = 0 + 11,542 = 11,542
    //     naive     : max(0, (1000+11542) - 3522)         =              9,020
    //
    // The naive form lets the ETH band's debt OVERFLOW into the BTC band's equity, reporting LESS
    // committed. `_poolUsdInRange` gates on `committedUsd18() <= haircutTvl`, so LESS committed is
    // a LOOSER gate — it admits commitments the per-band form rejects. Nothing reverts; the basket
    // silently over-commits, and the BTC band's LPs have quietly underwritten the ETH band's
    // leverage. Silent + plausible-but-wrong ⇒ standing rule 3's earns-a-check shape.
    //
    // Construction: establish real debt via the rally (openLev opens at ZERO leverage), seed the
    // BTC band, then DRAIN the ETH band's USD leg with sells until it falls BELOW the debt.
    function test_V1bdisc_OneBandsDebtExceedingItsOwnLegMustNotEatTheOther() public {
        _setupLev();
        ETH.setLevManager(address(lm));
        vm.deal(address(this), 40 ether);
        V4.deposit{value: 2 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);

        _rallyBand(_entrySqrt(lps[0]), 0.2e18, 40, 16_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        _calmVol();
        V4.syncLev(lps[0]);

        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);                       // 0.2 BTC — the band that must stay whole

        uint debt = lm.totalDebtUsd();
        assertGt(debt, 0, "PREMISE: leverage debt must exist before we try to exceed a leg with it");

        // §#12/E28-r RE-DERIVED CONSTRUCTION, twice. (1) The ORIGINAL method drained the curve until
        // its USD leg fell below the debt — but draining is a SWAP, and after #12 a swap no longer
        // reduces the BASKET's contribution. (2) The replacement shrank the band by withdrawing the
        // plain LP position — which worked only while the basket leg came off FIRST-OUT; once E28-r
        // made that removal PROPORTIONAL, a 95% withdrawal left 95%-of-a-large-leg behind and the
        // premise stopped holding. Both times the premise assertion caught it rather than letting
        // the case go vacuous. What discriminates is a SMALL plain base with a LARGE debt, and the
        // reliable lever is the RALLY: it raises the debt (the manager re-borrows at target LTV)
        // while leaving the basket leg alone, exactly because of (1).
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        vm.prank(address(this));
        try V4.withdraw(2 ether, address(this), address(this)) {} catch {}
        vm.roll(block.number + 1); vm.warp(block.timestamp + 10 minutes);

        // §#12: the per-band floor now applies to the BASKET's contribution, not the curve leg.
        uint ethPooled18 = CORE.basketUsdEth() * 1e12;
        uint btcPooled18 = CORE.basketUsdBtc() * 1e12;
        debt = lm.totalDebtUsd();                             // re-read: the drain may have moved it
        uint committed = CORE.committedUsd18();
        uint btcEquity = CORE.btcBandEquityUsd18();
        emit log_named_uint("ETH USD leg (18d)", ethPooled18);
        emit log_named_uint("ETH debt    (18d)", debt);
        emit log_named_uint("BTC USD leg (18d)", btcPooled18);
        emit log_named_uint("committedUsd18   ", committed);
        emit log_named_uint("  BTC band equity", btcEquity);

        // PREMISES — without BOTH of these the case is not the discriminating one and the
        // assertions below hold under either definition.
        assertGt(debt, ethPooled18,
            "PREMISE: the ETH band's debt must EXCEED its own USD leg, else both definitions agree");
        assertGt(btcPooled18, 0,
            "PREMISE: the BTC band must hold equity for the overflow to be able to eat");

        // THE DISCRIMINATOR. Per-band: the ETH band floors at 0 and the BTC band is untouched, so
        // committed is EXACTLY the BTC leg. The naive single floor would instead return
        // `(ethLeg + btcLeg) - debt`, which is strictly SMALLER here.
        assertEq(btcEquity, btcPooled18,
            "the ETH band's excess debt must NOT reach the BTC band's equity");
        assertEq(committed, btcPooled18,
            "committed == the BTC basket depth alone: the ETH band floors at ZERO, its overflow is NOT netted against BTC");
        assertGt(committed, ethPooled18 + btcPooled18 > debt ? ethPooled18 + btcPooled18 - debt : 0,
            "per-band flooring must report STRICTLY MORE committed than a single floor over the total");
    }
}
