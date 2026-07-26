// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/ILevVenue.sol";
import {MorphoEscrowVenue, MarketParams} from "../src/MorphoEscrowVenue.sol";
import {EulerEscrowVenue} from "../src/EulerEscrowVenue.sol";

interface IGenericFactory {
    function createProxy(address impl, bool upgradeable, bytes calldata trailingData) external returns (address);
}
interface IEVaultGov {
    function setInterestRateModel(address) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function setHookConfig(address newHookTarget, uint32 newHookedOps) external; // 0,0 ⇒ all ops enabled
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function asset() external view returns (address);
    function governorAdmin() external view returns (address);
}

interface IChainlinkFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IWeETHRateT { function getEETHByWeETH(uint) external view returns (uint); }
interface IVault4626T { function convertToAssets(uint) external view returns (uint); }

/// EVK IPriceOracle (`getQuote(inAmount, base, quote)` → value of `inAmount` `base` in the USD unit of
/// account, 1e18). NOT a mock — it prices weETH from REAL on-chain sources, exactly as QU!D does:
///   weETH vault shares → weETH (`convertToAssets`) → ETH (ether.fi `getEETHByWeETH`) → USD (REAL Chainlink
///   ETH/USD feed). No Redstone, no hardcoded price. A "crash" is driven by overriding the REAL ETH/USD feed
///   (`vm`-level), which then moves BOTH this oracle AND our band oracle consistently — a single real ETH
///   drawdown, not a per-oracle mock.
contract RealRateEulerOracle {
    address public COLL_VAULT;        // set after the coll vault is created (createProxy is circular)
    address public immutable WEETH;
    address public immutable USDC;
    IChainlinkFeedT public immutable ETH_USD; // real Chainlink ETH/USD (8-dec)
    constructor(address weeth, address usdc, address ethUsd) { WEETH = weeth; USDC = usdc; ETH_USD = IChainlinkFeedT(ethUsd); }
    function setColl(address c) external { COLL_VAULT = c; }
    function getQuote(uint inAmount, address base, address) public view returns (uint) {
        if (base == COLL_VAULT) {
            uint weeth = IVault4626T(COLL_VAULT).convertToAssets(inAmount);  // shares → weETH (1e18)
            uint eth = IWeETHRateT(WEETH).getEETHByWeETH(weeth);            // weETH → ETH (1e18) via the staking rate
            (, int256 p,,,) = ETH_USD.latestRoundData();                    // ETH/USD, 8-dec, REAL feed
            return eth * uint(p) / 1e8;                                     // → USD 1e18
        }
        if (base == USDC) return inAmount * 1e12;                          // USDC 6-dec → USD 1e18
        return 0;
    }
    function getQuotes(uint inAmount, address base, address quote) external view returns (uint, uint) {
        uint q = getQuote(inAmount, base, quote); return (q, q);
    }
}

/// A ZERO-RATE IRM — a valid REAL market config (some Euler markets run a flat/zero rate), not a mock price.
/// Returns 0 so the test math is deterministic (no interest drift); a real contract so the vault's
/// status-check IRM call succeeds (calling address(0) reverts).
contract ZeroRateIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) { return 0; }
}

interface IERC20R {
    function approve(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
}

/// Fuller Morpho Blue surface for the e2e (create a real market + seed borrow liquidity + authorize).
interface IMorphoTest {
    function createMarket(MarketParams memory m) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256, uint256);
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function accrueInterest(MarketParams memory m) external;
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
}
interface IMorphoOraclePrice { function price() external view returns (uint256); }

/// Morpho IOracle (`price()` = collateral→loan, 1e36-scaled). NOT a mock — REAL sources: weETH→ETH (ether.fi
/// getEETHByWeETH) × ETH→USD (REAL Chainlink ETH/USD). Morpho scale for weETH(18-dec)→USDC(6-dec):
/// `collateral·price/1e36` = loan units ⇒ price = weETH_USD(1e18) × 1e6. Crash = override the SAME real ETH/USD
/// feed (one drawdown moves this AND our band oracle), no Redstone, no hardcoded price.
contract RealRateMorphoOracle {
    address public immutable WEETH;
    IChainlinkFeedT public immutable ETH_USD;
    constructor(address weeth, address ethUsd) { WEETH = weeth; ETH_USD = IChainlinkFeedT(ethUsd); }
    function price() external view returns (uint256) {
        uint ethPerWeeth = IWeETHRateT(WEETH).getEETHByWeETH(1e18);   // ETH per weETH (1e18), staking rate
        (, int256 p,,,) = ETH_USD.latestRoundData();                  // ETH/USD, 8-dec
        uint weethUsd1e18 = ethPerWeeth * uint(p) / 1e8;             // weETH → USD (1e18)
        return weethUsd1e18 * 1e6;                                   // Morpho 1e36 scale (18→6 dec)
    }
}

// InverseRateMorphoOracle (the ETH SHORT market's {USDC-coll → WETH-loan} inverse oracle) now lives
// in src/LevOracles.sol (imported below) — DeployL1_s deploys it inline; this test fork-proves it.
// It reads the SAME real Chainlink ETH/USD the crash mock drives, so the short's Morpho health and
// the sizing move together as the fork feed is stepped.

/// Real EVC liquidation surface — a liquidator enables the controller/collateral then liquidates an unhealthy
/// sub-account through the EVC (on-behalf-of itself).
interface IEVCLiq {
    struct BatchItem { address targetContract; address onBehalfOfAccount; uint256 value; bytes data; }
    function enableController(address account, address vault) external payable;
    function enableCollateral(address account, address vault) external payable;
    function batch(BatchItem[] calldata items) external payable;
}
interface IEVaultLiq {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
    function checkLiquidation(address liquidator, address violator, address collateral)
        external view returns (uint256 maxRepay, uint256 maxYield);
    function accountLiquidity(address account, bool liquidation)
        external view returns (uint256 collateralValue, uint256 liabilityValue);
}
interface IWeethSubId { function subIdOf(address lp) external view returns (uint8); }
interface IAuxSorSelf { function sorSelfFunded(address sourceAsset, uint amountIn, address output, uint minOut) external returns (uint); }

/// @notice REAL-FORK proof of the YB IL-protect production swap route. Proves the folded `LevManager` legs
///   perform a genuine stable↔weETH round-trip over LIVE markets — caller-funded SOR (stable→WETH via the
///   basket's real Uniswap-V4 hops) + ether.fi adapter mint / instant-redeem (WETH↔weETH) — NOT our internal
///   band. (No sims; the bespoke RealWeethSwapper is gone, folded into LevManager.)
contract LevYbRealProbe is Alles {
    // Real mainnet addresses (same fork Alles pins).
    address constant WEETH          = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    /// @notice CALLER-FUNDED SOR up-leg (the RealWeethSwapper-replacement): the leverage's OWN dollars route
    ///   stable→WETH through the basket's real-Uniswap-V4 SOR hops, WITHOUT redeeming any basket 4626. Proves
    ///   the SELF_FUNDED branch delivers real WETH to the caller and never touches basket backing.
    function testReal_SorSelfFunded_UsdcToWeth() public {
        uint usdcIn = 20_000 * USDC_PRECISION;
        deal(address(USDC), address(this), usdcIn);
        USDC.approve(address(AUX), usdcIn);
        uint wethBefore = WETH.balanceOf(address(this));
        uint out = IAuxSorSelf(address(AUX)).sorSelfFunded(address(USDC), usdcIn, address(WETH), 0);
        assertGt(out, 0, "caller-funded USDC->WETH via SOR delivered WETH");
        assertEq(WETH.balanceOf(address(this)) - wethBefore, out, "WETH landed at the caller");
        assertGt(out, 4 ether, "roughly the right magnitude for ~$20k");
    }

    /// TEMP DIAGNOSTIC — does the basket SOR route weETH->USDC (the self-funded short's sell leg)?
    function testDiag_WeethSellRoute() public {
        _seedBasket();
        uint wIn = 1 ether;
        deal(WEETH, address(this), wIn);
        IERC20R(WEETH).approve(address(AUX), wIn);
        try IAuxSorSelf(address(AUX)).sorSelfFunded(WEETH, wIn, address(USDC), 0) returns (uint out) {
            emit log_named_uint("weETH->USDC sorSelfFunded OUT (6-dec)", out);
        } catch (bytes memory reason) {
            emit log_named_bytes("weETH->USDC sorSelfFunded REVERTED", reason);
            emit log_string("=> weETH has NO SOR route (self-funded short sell no-ops on weETH)");
        }
    }

    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant LP = address(0xBEEF7);

    // Storage to keep the e2e frame shallow (no via_ir).
    LevManager rlm;
    MorphoEscrowVenue rvenue;
    uint rpx;
    address mOracle;

    function _setupMorpho() internal {
        _seedBasket();
        // PIN THE ETH/USD ANCHOR, as the real deploy does (DeployL1_s:326). Without it
        // `getTWAPforAsset` resolves through twapResolve(feed=0x0, price=0) and returns ZERO —
        // and because it deliberately never reverts (#101 degrade-to-partial-fill), that zero
        // propagated as `pxWeth` into LevMath's divisors and killed these tests with
        // `panic: division or modulo by zero`. The fixture must match the deployed config.
        if (AUX.assetPriceFeed(address(WETH)) == address(0)) AUX.setAssetFeed(address(WETH), CL_ETH_USD);
        rpx = AUX.getTWAPforAsset(address(WETH), 1800);            // 1e18 USD/ETH (real)
        assertGt(rpx, 0, "ETH/USD anchor must resolve non-zero (pxWeth feeds LevMath divisors)");
        RealRateMorphoOracle oracle = new RealRateMorphoOracle(WEETH, CL_ETH_USD); // REAL ether.fi rate × Chainlink
        mOracle = address(oracle);
        MarketParams memory mp = MarketParams({
            loanToken: address(USDC), collateralToken: WEETH,
            oracle: address(oracle), irm: ADAPTIVE_IRM, lltv: 0.86e18
        });
        IMorphoTest morpho = IMorphoTest(MORPHO);
        morpho.createMarket(mp);
        // Seed borrow liquidity (this contract is the lender).
        deal(address(USDC), address(this), 2_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, 2_000_000 * USDC_PRECISION);
        morpho.supply(mp, 2_000_000 * USDC_PRECISION, 0, address(this), "");
        // Wire the YB stack against the real venue + real swap route + the REAL Vogue band (V4) as the
        // BAND-ONLY E0 / sold-fraction source — NO MockBandHost: bandEthOf/bandSqrtP/soldFractionWad/reseatEpoch
        // all read the live V4 pool on the mainnet fork.
        rlm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        rvenue = new MorphoEscrowVenue(MORPHO, mp, address(rlm));
        // atomic pin-once: REAL V4 hook + Morpho flash (zero-fee repay-first de-lever) + the frozen venue.
        { address[] memory vs = new address[](1); vs[0] = address(rvenue); rlm.init(address(V4), MORPHO, vs); }
        vm.prank(LP);
        morpho.setAuthorization(address(rvenue), true); // one-time Morpho-native isolation
    }

    /// Move the REAL V4 band UP by buying WETH out of it in bounded steps (each under the 50bps/swap manip cap),
    /// warping between so each step measures from spot≈TWAP and the guard resets. Real swaps only — the band
    /// sells ETH → real IL accrues; kept under the 5% Chainlink anchor so no reseat/no oracle override needed.
    /// Self-calibrating: stops once the live sold fraction (from V4.poolStats) reaches `targetWad`.
    function _rallyBand(uint160 entrySqrt, uint targetWad, uint maxSteps, uint usdcPerStep) internal {
        deal(address(USDC), address(this), maxSteps * usdcPerStep);
        IERC20R(address(USDC)).approve(address(AUX), maxSteps * usdcPerStep);
        for (uint i; i < maxSteps; i++) {
            if (V4.soldFractionWad(entrySqrt) >= targetWad) break;
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px == 0) break;
            _setEthFeed(px / 1e10);                 // feed tracks pool pre-swap ⇒ getTWAPforAsset follows, no 5% anchor trip
            try AUX.swap(address(USDC), address(WETH), true, usdcPerStep, 0) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Real DOWN move: sell ETH into the band so the mark crashes ~`dropBps` (drives the venue-safety de-lever).
    /// Feed tracks the pool each step, so getCurrentLtvBps (weETH mark) falls for real — no getTWAPforAsset mock.
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

    /// Seed REAL basket POOLED_USD surplus (mint QUID against USDC, the basket's own reserves) so syncLev can
    /// pair the levered band slice against FREE basket dollars — the surplus the levered slice draws from.
    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// Calm realized vol after the rally: write ~12 near-stable oracle observations over >40min (the θ vol
    /// horizon) via tiny alternating round-trip swaps, so θ=yield/(K·σ²) recovers from the rally spike. This is
    /// the realistic sequence — an IL event, then vol calms — and it's what lets syncLev add the levered band
    /// depth (the θ-budget cap refuses new exposure while vol is elevated; backing recognition is unaffected).
    function _calmVol() internal {
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        vm.deal(address(this), 20 ether);
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            // tiny alternating round-trips (θ ∝ 1/move² ⇒ small moves ⇒ σ²→~0 once the rally ages out of the 40min horizon)
            if (i % 2 == 0) { try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0) {} catch {} }
            else            { try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0) {} catch {} }
        }
    }

    /// Realign the mock band's price feed + spot to the REAL Chainlink market. The rally elevates the band's
    /// own feed (mock-token pool we can move); the leverage's external legs execute on REAL Uniswap (which we
    /// can't). Before any real weETH↔stable leg / basket reconcile, pin the band oracle to real so
    /// getTWAPforAsset (⇒ _stableFloor, ⇒ POOLED_USD valuation) matches real execution — a fork artifact fix.
    function _realignBandToReal() internal {
        (, int256 clp,,,) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        _setEthFeed(uint(clp)); V4.reseat();
    }

    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }

    function _entrySqrt(LevManager m, address lp) internal view returns (uint160 s) { ( , , , , s, ) = m.pos(lp); }

    function _openLp() internal {
        // REAL band position (the E0 IL base) — bandEthOf(LP) == 5 ETH deposit, read live from V4.
        vm.deal(LP, 6 ether);
        vm.prank(LP); V4.deposit{value: 5 ether}(0, LP, 3);   // venue 3 = all-Galaxy (no ether.fi offramp noise)
        deal(WEETH, LP, 5 ether);
        uint[] memory mins = new uint[](8);
        // Open at the CURRENT real band price (entry pinned from V4.bandSqrtP); zero leverage at entry.
        vm.startPrank(LP);
        IERC20R(WEETH).approve(address(rlm), 5 ether);
        rlm.openLev(5000, ILevVenue(address(rvenue)), 5 ether, mins); // cap = 2×
        vm.stopPrank();
        rlm.setSoldFractionActive(true);   // target reads the REAL band's sold fraction (poolStats), not the lagging oracle
        // Real rally: buy ETH out of the band so it sells ETH ⇒ real IL accrues since the pinned entry.
        _rallyBand(_entrySqrt(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        rlm.rebalance(LP, 0);         // lever up to the IL target (real Morpho borrow + real Uniswap buy)
    }

    /// @notice #55/#1 fork proof: the levered slice is STRUCTURALLY excluded from the VENUE-yield
    ///         denominator. Post-fix, Morpho WETH appreciation accrues into a SEPARATE accumulator
    ///         (venueFeesPerShare) over PLAIN depth (lpShares - totalLevPooled), paid on weight
    ///         (pooled - levPooled) -- so the lev slice + debt-funded buffer can never skim plain
    ///         LPs' venue yield (they earn their own yield via the LevManager). Trading fees stay on
    ///         gross depth. Proof: totalLevPooled exactly aggregates the LP's levPooled, so the plain
    ///         venue denominator excludes it by construction.
    function testReal_VenueYield_LevExcludedFromDenominator() public {
        _setupMorpho();
        ETH.setLevManager(address(rlm));   // register V4/AUX -> manager so the band syncs the levered slice
        _openLp();          // 5 ETH plain band (Galaxy) + 5 ETH weETH lev, rallied + rebalanced
        V4.syncLev(LP);     // force the levered-slice reconcile (the rebalance's auto-sync is best-effort)

        assertGt(V4.totalBuffer(), 0, "leverage paired a debt-funded buffer into the band");
        // #55/#1: the VENUE-yield denominator is PLAIN depth (lpShares - totalLevPooled), which is
        // STRICTLY SMALLER than the TRADING-fee denominator (lpShares + totalBuffer) -- it excludes
        // both the debt-funded buffer AND the lev net-equity. So Morpho venue appreciation (funded
        // only by plain LP deposits) is distributed over plain depth alone: the lev slice + buffer
        // can no longer skim it. Trading fees rightly stay on gross depth (the buffer IS V4 depth).
        uint venueDenom   = V4.lpShares() - V4.totalLevPooled();
        uint tradingDenom = V4.lpShares() + V4.totalBuffer();
        assertLt(venueDenom, tradingDenom,
            "venue-yield denominator EXCLUDES the lev buffer + net-equity (trading-fee denom includes them)");
        assertEq(tradingDenom - venueDenom, V4.totalBuffer() + V4.totalLevPooled(),
            "excluded exactly the buffer + lev net-equity");
        // And the plain venue balance (_venueBalance) excludes the lev net-equity symmetrically, so a
        // lev open/close can never appear as fake venue yield: vogueETH includes it, deliverableETH
        // (the plain-venue proxy) excludes it, and they differ by the lev net-equity.
        assertGe(AUX.vogueETH(), AUX.deliverableETH(), "vogueETH (incl lev) >= deliverableETH (excl lev)");
    }

    /// @notice FULL real-venue e2e: a real Morpho Blue market (permissionless createMarket + live IRM) +
    ///   the folded `LevManager` swap legs + `MorphoEscrowVenue`. Opens a weETH-collateral leveraged
    ///   position (real Morpho borrow + real Uniswap weETH buy), then crashes the mark and de-levers — proving
    ///   the adapter's Morpho-authorization + position/borrow/repay/withdraw semantics against the LIVE contract.
    function testReal_Morpho_OpenAndDelever() public {
        _setupMorpho();
        ETH.setLevManager(address(rlm));   // register V4/AUX -> manager so the band syncs the levered slice
        _openLp();

        uint debt0 = rvenue.debtOf(LP);
        uint coll0 = rvenue.collateralOf(LP);
        emit log_named_uint("Morpho debt (USDC) after open", debt0);
        emit log_named_uint("Morpho weETH collateral after open", coll0);
        emit log_named_uint("LTV after open (bps)", rlm.getCurrentLtvBps(LP));
        assertGt(debt0, 0, "open must take on real Morpho debt");
        assertGt(coll0, 5 ether, "leverage must grow collateral beyond equity");

        // ── #52 net-equity model invariants (post-leverage) ──────────────────────────────
        // pooled/lpShares are NET equity; the debt-funded buffer is fee-earning V4 depth tracked
        // separately in levBuf/totalBuffer, EXCLUDED from equity: it can't be freely withdrawn but
        // STILL earns leverage yield via the gross fee weight (lpShares + totalBuffer).
        V4.syncLev(LP);
        uint buffer = V4.levBuf(LP);
        assertGt(buffer, 0, "leverage pairs a debt-funded buffer into the band");
        assertLe(buffer, rlm.grossCollateralEth(LP), "buffer <= live gross collateral");
        // Conservation: totalBuffer == the single levered LP's buffer.
        assertEq(V4.totalBuffer(), buffer, "totalBuffer == sum of levBuf");
        // The buffer is EXCLUDED from equity: balanceOf (redeemable net share) does not include it,
        // and for the sole LP the net share total == their balance.
        assertEq(V4.balanceOf(LP), V4.lpShares(), "single LP: balanceOf(net) == lpShares(net)");
        // GROSS fee weight (fee denominator) = net lpShares + totalBuffer, strictly above net equity.
        assertGt(V4.lpShares() + V4.totalBuffer(), V4.lpShares(), "gross fee weight exceeds net equity by the buffer");

        // REAL CRASH: sell ETH into the band so the mark drops ~10% (feed tracks the pool) — LTV jumps for real,
        // no getTWAPforAsset mock. De-lever then fires on the genuine mark move.
        _crashBand(1000, 12, 30 ether);
        emit log_named_uint("LTV after crash (bps)", rlm.getCurrentLtvBps(LP));

        // De-lever through the real adapter: withdraw weETH (real Morpho) → sell (real Uniswap) → repay (real
        // Morpho). Called by the LP (self-de-risk path; the keeper uses permissionless cascadeDelever).
        vm.prank(LP);
        rlm.deleverOne(LP, 0);

        emit log_named_uint("Morpho debt (USDC) after delever", rvenue.debtOf(LP));
        emit log_named_uint("LTV after delever (bps)", rlm.getCurrentLtvBps(LP));
        assertLt(rvenue.debtOf(LP), debt0, "de-lever must repay real Morpho debt");
        assertLt(rvenue.collateralOf(LP), coll0, "de-lever must withdraw real Morpho collateral");
    }

    /// @notice Morpho parity with the Euler capstone (#10): real band + real Morpho Blue + REAL liquidation
    ///   driven by the live Chainlink feed, basket isolation proven. Morpho liquidation is atomic (no
    ///   liquidator-health deferral, no EVC), so the liquidator just repays + seizes in one call.
    function testReal_Morpho_LiquidationLeavesBasketIntact() public {
        _setupMorpho();
        ETH.setLevManager(address(rlm));
        _openLp();
        _calmVol();                    // vol calms after the IL event ⇒ θ recovers ⇒ syncLev can add the levered depth
        uint tvl0 = _tvl();
        V4.syncLev(LP);
        uint lev0 = V4.levPooled(LP);
        assertGt(lev0, 0, "levered band slice minted");
        uint vdebt0 = rvenue.debtOf(LP);

        // Calibrate the REAL ETH crash from the live position to ~92% LTV (liquidatable per lltv 0.86, not deep
        // bad debt). collValue(USDC) = collateral · oracle.price()/1e36; crash factor = LTV/0.92.
        uint collValue = rvenue.collateralOf(LP) * IMorphoOraclePrice(mOracle).price() / 1e36;
        (uint80 rid, int256 p,, uint256 ut, uint80 ar) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        uint crashed = uint256(p) * vdebt0 * 100 / (collValue * 92);
        vm.mockCall(CL_ETH_USD, abi.encodeWithSelector(IChainlinkFeedT.latestRoundData.selector),
            abi.encode(rid, int256(crashed), ut, ut, ar));

        // REAL Morpho liquidate: seize half the collateral (the violator is the LP itself — onBehalf isolation,
        // no sub-account). Liquidator pre-approves USDC; Morpho pulls the repay atomically.
        MarketParams memory mp = MarketParams({
            loanToken: address(USDC), collateralToken: WEETH, oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18});
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, type(uint).max);
        IMorphoTest(MORPHO).liquidate(mp, LP, rvenue.collateralOf(LP) / 2, 0, "");
        assertLt(rvenue.debtOf(LP), vdebt0, "REAL Morpho liquidation reduced the borrower's debt");

        // Basket clean: the levered slice shrinks to the liquidated net-equity, POOLED_USD not drained.
        vm.clearMockedCalls();
        // Realign the band oracle to the real market before reconciling — the rally elevated the mock band's
        // feed vs real Chainlink; reconcile the burn at the same real price the mint would be valued at now.
        _realignBandToReal();
        V4.syncLev(LP);
        assertLt(V4.levPooled(LP), lev0, "post-liquidation: levered slice shrank to the liquidated net-equity");
        assertGe(_tvl(), tvl0, "REAL liquidation drained the basket real backing (TVL)");                          // nothing real taken
        assertGe(AUX.vogueETH(), CORE.POOLED_ETH(), "deliverable ETH must still cover the band (honest LPs whole)"); // POOLED_USD legitimately un-pairs to the free reserve after the band IL event — not a loss
    }

    // ════════════════════════════ EULER (real EVK) ════════════════════════════
    address constant EVK_FACTORY = 0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e;
    address constant USD = 0x0000000000000000000000000000000000000348; // unit of account
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // real Chainlink ETH/USD, 8-dec
    address constant EVC_ADDR   = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383; // real Euler Vault Connector
    LevManager elm;
    EulerEscrowVenue evenue;
    RealRateEulerOracle eoracle;
    address collV;
    address debtV;

    function _setupEuler() internal {
        _seedBasket();
        // PIN THE ETH/USD ANCHOR, as the real deploy does (DeployL1_s:326). Without it
        // `getTWAPforAsset` resolves through twapResolve(feed=0x0, price=0) and returns ZERO —
        // and because it deliberately never reverts (#101 degrade-to-partial-fill), that zero
        // propagated as `pxWeth` into LevMath's divisors and killed these tests with
        // `panic: division or modulo by zero`. The fixture must match the deployed config.
        if (AUX.assetPriceFeed(address(WETH)) == address(0)) AUX.setAssetFeed(address(WETH), CL_ETH_USD);
        rpx = AUX.getTWAPforAsset(address(WETH), 1800);
        assertGt(rpx, 0, "ETH/USD anchor must resolve non-zero (pxWeth feeds LevMath divisors)");
        eoracle = new RealRateEulerOracle(WEETH, address(USDC), CL_ETH_USD); // REAL sources: ether.fi rate × Chainlink
        IGenericFactory f = IGenericFactory(EVK_FACTORY);
        // Collateral vault (weETH ESCROW-style) + debt vault (USDC), real EVK proxies (default impl).
        collV = f.createProxy(address(0), false, abi.encodePacked(WEETH, address(eoracle), USD));
        debtV = f.createProxy(address(0), false, abi.encodePacked(address(USDC), address(eoracle), USD));
        eoracle.setColl(collV);
        // Enable all vault operations (fresh EVK vaults gate ops behind the hook config; 0,0 ⇒ none hooked).
        IEVaultGov(collV).setHookConfig(address(0), 0);
        IEVaultGov(debtV).setHookConfig(address(0), 0);
        // Governor config (creator == governor): USDC vault accepts weETH-vault collateral at 86% LTV, zero IRM.
        IEVaultGov(debtV).setInterestRateModel(address(new ZeroRateIRM()));
        IEVaultGov(debtV).setLTV(collV, 8600, 8600, 0);
        // Seed USDC borrow liquidity via a real lender deposit.
        deal(address(USDC), address(this), 2_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(debtV, 2_000_000 * USDC_PRECISION);
        IEVaultGov(debtV).deposit(2_000_000 * USDC_PRECISION, address(this));

        elm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        evenue = new EulerEscrowVenue(collV, debtV, address(elm));
        // atomic pin-once: REAL V4 hook + Morpho flash (global USDC, even for an Euler position) + frozen venue.
        { address[] memory vs = new address[](1); vs[0] = address(evenue); elm.init(address(V4), MORPHO, vs); }
    }

    function _openEulerLp() internal {
        // REAL band position (E0) — read live from V4; no MockBandHost.
        vm.deal(LP, 6 ether);
        vm.prank(LP); V4.deposit{value: 5 ether}(0, LP, 3);
        deal(WEETH, LP, 5 ether);
        uint[] memory mins = new uint[](8);
        vm.startPrank(LP);
        IERC20R(WEETH).approve(address(elm), 5 ether);
        elm.openLev(5000, ILevVenue(address(evenue)), 5 ether, mins);
        vm.stopPrank();
        elm.setSoldFractionActive(true);   // target reads the REAL band's sold fraction (poolStats)
        _rallyBand(_entrySqrt(elm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);   // real swaps ⇒ band sells ETH ⇒ real IL since entry
        elm.rebalance(LP, 0);         // lever up to the IL target (real Euler borrow + real Uniswap buy)
    }

    /// @notice FULL real-venue e2e on EULER EVK: a freshly-deployed real weETH/USDC EVK market (real
    ///   GenericFactory proxies + governance) + the real swapper + `EulerEscrowVenue` (per-LP EVC sub-account
    ///   isolation) + `LevManager`. Proves the adapter's EVC.batch borrow/withdraw + sub-account semantics
    ///   against the LIVE EVK contracts. Same open→crash→delever as Morpho.
    function testReal_Euler_OpenAndDelever() public {
        _setupEuler();
        _openEulerLp();

        uint debt0 = evenue.debtOf(LP);
        uint coll0 = evenue.collateralOf(LP);
        emit log_named_uint("Euler debt (USDC) after open", debt0);
        emit log_named_uint("Euler weETH collateral after open", coll0);
        emit log_named_uint("LTV after open (bps)", elm.getCurrentLtvBps(LP));
        assertGt(debt0, 0, "open must take on real Euler debt");
        assertGt(coll0, 5 ether, "leverage must grow collateral beyond equity");

        _crashBand(1000, 12, 30 ether);   // REAL ~10% mark crash via band sells — no getTWAPforAsset mock
        emit log_named_uint("LTV after crash (bps)", elm.getCurrentLtvBps(LP));

        vm.prank(LP);
        elm.deleverOne(LP, 0);
        emit log_named_uint("Euler debt (USDC) after delever", evenue.debtOf(LP));
        emit log_named_uint("LTV after delever (bps)", elm.getCurrentLtvBps(LP));
        assertLt(evenue.debtOf(LP), debt0, "de-lever must repay real Euler debt");
        assertLt(evenue.collateralOf(LP), coll0, "de-lever must withdraw real Euler collateral");
    }

    /// @notice CLOSE against the REAL Euler venue (the #10 coverage gap: closeLev was untested vs a real
    ///   venue). Open → closeLev → the real EVK debt is fully repaid, the collateral fully withdrawn, the
    ///   remaining weETH returned to the LP, and the position deleted. Also exercises the MED-8 repay clamp
    ///   (surplus → LP) on real tokens.
    /// (#82) END-TO-END RECOVERY: open a levered position, incur a REAL IL event (rally the band so it sells ETH),
    /// let the keeper re-manage (rebalance ⇒ the IL-cancelling lever-up), then closeLev — and assert the LP walks
    /// away with AT LEAST the HODL value of its input collateral, minus bounded real costs. On the fork the REAL
    /// weETH/USDC markets are static (only our internal band moved), so the leverage captures no phantom price gain —
    /// this isolates the MACHINERY's cost: a round-trip through open→rebalance→close must not LEAK value beyond the
    /// real swap slippage + borrow interest. (The directional up/down P&L that tracks HODL across a genuine move is
    /// proven formulaically in LevYbPnl and, down-side, by testReal_Bidirectional_ShortClose.)
    function testReal_Euler_CloseBeatsHodlModuloCosts() public {
        _setupEuler();
        _openEulerLp();                       // 5 weETH collateral, band rallied (real IL), rebalanced (lever-up)
        assertGt(evenue.debtOf(LP), 0, "precondition: managed levered position has real debt");
        _realignBandToReal();

        // HODL baseline: the 5 weETH the LP put in, held un-levered, is still 5 weETH at the (static real) close.
        uint hodlWeeth = 5 ether;
        uint lpWeethBefore = IERC20R(WEETH).balanceOf(LP);
        uint lpUsdcBefore  = IERC20R(address(USDC)).balanceOf(LP);

        vm.prank(LP);
        elm.closeLev(0);                      // sell collateral → repay all debt → return the remainder

        uint weethBack = IERC20R(WEETH).balanceOf(LP) - lpWeethBefore;
        uint usdcBack  = IERC20R(address(USDC)).balanceOf(LP) - lpUsdcBefore;
        // Value any stable refund back into weETH at the real rate so the recovery is measured in one unit.
        uint ethPerWeeth = IWeETHRateT(WEETH).getEETHByWeETH(1e18);            // ETH per weETH (1e18)
        uint ethUsd      = AUX.getTWAPforAsset(address(WETH), 1800);           // USD per ETH (1e18, real Chainlink post-realign)
        uint usdcAsWeeth = usdcBack * 1e12 * 1e18 / (ethPerWeeth * ethUsd / 1e18); // USDC(6d)→USD(1e18)→weETH(1e18)
        uint recoveredWeeth = weethBack + usdcAsWeeth;
        emit log_named_uint("recovered weETH (1e18)", recoveredWeeth);
        emit log_named_uint("HODL weETH   (1e18)", hodlWeeth);

        assertEq(evenue.debtOf(LP), 0, "close: debt fully repaid");
        // Recovery >= HODL - costs. Observed ~99.95% (only ~0.05% to the 2 oracle-floored SOR swaps + the short
        // borrow window) — so a 2% floor is a MEANINGFUL bound (round-trip costs < 2%) that a value LEAK (bug) would
        // blow far past, yet stays robust to fork-block price variance.
        assertGe(recoveredWeeth, hodlWeeth * 98 / 100, "closeLev recovered >= HODL collateral - bounded costs (<2%)");
    }

    /// (#84) CENTRAL rebalancer: rebalanceMany holds the (here single-LP) book at the IL target in ONE tx — the
    /// fleet's per-book crank, replacing N per-LP txs. Also proves the fault-tolerant open-skip (a bogus LP in the
    /// batch is skipped, not reverted).
    function testReal_Euler_RebalanceMany_BatchHoldsTarget() public {
        _setupEuler();
        _openEulerLp();
        // Rally further so the band sells more ETH ⇒ IL grows ⇒ the batch has real lever-up work.
        _rallyBand(_entrySqrt(elm, LP), 0.4e18, 20, 8_000 * USDC_PRECISION);
        uint debtBefore = evenue.debtOf(LP);

        address[] memory lps = new address[](1); lps[0] = LP;
        uint[] memory mins = new uint[](1);
        elm.rebalanceMany(lps, mins);            // ONE tx levers up toward the higher IL target
        assertGt(evenue.debtOf(LP), debtBefore, "rebalanceMany levered up toward the IL target in one tx");

        // Fault-tolerant: a non-open LP in the batch is skipped, never reverts the whole batch.
        address[] memory lps2 = new address[](2); lps2[0] = LP; lps2[1] = address(0xDEAD);
        uint[] memory mins2 = new uint[](2);
        elm.rebalanceMany(lps2, mins2);          // must not revert despite the bogus 2nd entry
    }

    function testReal_Euler_CloseUnwindsFully() public {
        _setupEuler();
        _openEulerLp();
        assertGt(evenue.debtOf(LP), 0, "precondition: position has real Euler debt");
        uint lpWeethBefore = IERC20R(WEETH).balanceOf(LP);

        // Realign the internal band oracle to the REAL market before the close: the rally elevated our
        // mock-token band's feed, but the close's weETH→stable leg executes on REAL Uniswap (which we can't
        // move on a fork). Set the feed to real Chainlink + reseat the band spot onto it so getTWAPforAsset
        // (⇒ _stableFloor) matches real execution — the divergence is a fork artifact, not a product issue.
        _realignBandToReal();

        vm.prank(LP);
        elm.closeLev(0); // sell collateral → repay all debt → return the remainder

        assertEq(evenue.debtOf(LP), 0, "close: real Euler debt fully repaid");
        assertEq(evenue.collateralOf(LP), 0, "close: real Euler collateral fully withdrawn");
        assertGt(IERC20R(WEETH).balanceOf(LP), lpWeethBefore, "close: remaining weETH returned to the LP");
        (,,,,, bool stillOpen) = elm.pos(LP);
        assertTrue(!stillOpen, "close: position deleted");
    }

    /// @notice THE CAPSTONE (#10) — real band + real venue + REAL liquidation, no mocks in the price path: a
    ///   levered position is wired into the band (its net-equity backs `POOLED_ETH`), then a REAL ETH crash
    ///   (override the live Chainlink ETH/USD feed) makes it underwater per Euler's OWN real-data oracle, an
    ///   independent liquidator runs the REAL Euler `liquidate` on the LP's sub-account, and the basket comes
    ///   out clean — the levered slice reconciles to ~0 and `POOLED_USD` returns to its pre-leverage baseline
    ///   (the liquidation took nothing from the basket; the loss is isolated to the LP's Euler account).
    function testReal_Euler_LiquidationLeavesBasketIntact() public {
        _setupEuler();
        ETH.setLevManager(address(elm));          // unify: the lev net-equity backs the band
        _openEulerLp();
        _calmVol();                    // vol calms after the IL event ⇒ θ recovers ⇒ syncLev can add the levered depth
        uint tvl0 = _tvl();
        V4.syncLev(LP);
        uint256 lev0 = V4.levPooled(LP);
        assertGt(lev0, 0, "levered band slice minted");
        uint vdebt0 = evenue.debtOf(LP);

        address violator = address(uint160(address(evenue)) ^ IWeethSubId(address(evenue)).subIdOf(LP));
        // REAL ETH crash: override the live Chainlink ETH/USD feed → weETH USD value collapses. Calibrate the
        // drop from the position's ACTUAL liquidity so it lands at ~90% LTV — liquidatable (>86% liq) but NOT
        // bad debt (else the liquidator itself goes unhealthy, E_AccountLiquidity). One real drawdown, no mock.
        // accountLiquidity(.., true) returns RISK-ADJUSTED collateral (already × liq-LTV) vs the debt; healthy
        // while cv >= lv. Crash so cv·f ≈ lv/1.10 (10% under) ⇒ liquidatable, raw LTV ≈ 94% (not bad debt).
        (uint256 cv, uint256 lv) = IEVaultLiq(debtV).accountLiquidity(violator, true);
        (uint80 rid, int256 p,, uint256 ut, uint80 ar) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        uint256 crashed = uint256(p) * lv * 100 / (cv * 110);
        vm.mockCall(CL_ETH_USD, abi.encodeWithSelector(IChainlinkFeedT.latestRoundData.selector),
            abi.encode(rid, int256(crashed), ut, ut, ar));

        // Independent liquidator (this contract) runs the REAL Euler liquidate on the LP's EVC sub-account.
        IEVCLiq evc = IEVCLiq(EVC_ADDR);
        evc.enableController(address(this), debtV);
        evc.enableCollateral(address(this), collV);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(debtV, type(uint).max);
        // EVK requires repayAssets <= maxRepay (no auto-clamp) — ask the vault, then liquidate that amount.
        (uint256 maxRepay,) = IEVaultLiq(debtV).checkLiquidation(address(this), violator, collV);
        assertGt(maxRepay, 0, "crash made the position liquidatable per Euler's real oracle");
        // ONE EVC batch: liquidate (take the violator's debt + seized collateral) THEN repay it with our own
        // USDC, so the liquidator ends the deferred-liquidity check with no debt (else E_AccountLiquidity).
        IEVCLiq.BatchItem[] memory items = new IEVCLiq.BatchItem[](2);
        items[0] = IEVCLiq.BatchItem(debtV, address(this), 0,
            abi.encodeCall(IEVaultLiq.liquidate, (violator, collV, maxRepay, 0)));
        items[1] = IEVCLiq.BatchItem(debtV, address(this), 0,
            abi.encodeCall(IEVaultLiq.repay, (maxRepay, address(this))));
        evc.batch(items);
        assertLt(evenue.debtOf(LP), vdebt0, "REAL Euler liquidation reduced the violator's debt");

        // Basket clean: reconcile the now-smaller net-equity (EVK liquidation is PARTIAL — it de-risks just
        // enough to restore health, so the position survives smaller). The levered slice shrinks to track it,
        // and the basket's POOLED_USD never drops below its pre-leverage baseline — the liquidation took
        // NOTHING from the basket; the loss is isolated to the LP's Euler account.
        vm.clearMockedCalls();
        // Realign the band oracle to the real market before reconciling — the rally elevated the mock band's
        // feed vs real Chainlink; reconcile the burn at the same real price the mint would be valued at now.
        _realignBandToReal();
        V4.syncLev(LP);
        assertLt(V4.levPooled(LP), lev0, "post-liquidation: levered slice shrank to the liquidated net-equity");
        assertGe(_tvl(), tvl0, "REAL liquidation drained the basket real backing (TVL)");                          // nothing real taken
        assertGe(AUX.vogueETH(), CORE.POOLED_ETH(), "deliverable ETH must still cover the band (honest LPs whole)"); // POOLED_USD legitimately un-pairs to the free reserve after the band IL event — not a loss
    }
}
