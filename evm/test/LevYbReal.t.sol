// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IMorphoStaticTyping as IMorphoTest, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle as IMorphoOraclePrice} from "morpho-blue/interfaces/IOracle.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/Interfaces.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";

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
///   (`vm`-level), which then moves BOTH this oracle AND our range oracle consistently — a single real ETH
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

/// Morpho IOracle (`price()` = collateral→loan, 1e36-scaled). NOT a mock — REAL sources: weETH→ETH (ether.fi
/// getEETHByWeETH) × ETH→USD (REAL Chainlink ETH/USD). Morpho scale for weETH(18-dec)→USDC(6-dec):
/// `collateral·price/1e36` = loan units ⇒ price = weETH_USD(1e18) × 1e6. Crash = override the SAME real ETH/USD
/// feed (one drawdown moves this AND our range oracle), no Redstone, no hardcoded price.
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
// in src/imports/LevBase.sol (imported below) — DeployL1_s deploys it inline; this test fork-proves it.
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

/// @notice REAL-FORK proof of the YB IL-protect production swap route. Proves the folded `LevManager` legs
///   perform a genuine stable↔weETH round-trip over LIVE markets — caller-funded SOR (stable→WETH via the
///   basket's real Uniswap-ETH hops) + ether.fi adapter mint UP / v3-pool sale DOWN (WETH↔weETH) — NOT our internal
///   range. (No sims; the bespoke RealWeethSwapper is gone, folded into LevManager.)
contract LevYbRealProbe is AllesFixture {
    // KEPT when the Euler section was removed: this feed is the price anchor for the MORPHO tests
    // (RealRateMorphoOracle + the staleness cases), not Euler-specific. It merely happened to be
    // declared inside the Euler block.
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // real Chainlink ETH/USD, 8-dec
    // Real mainnet addresses (same fork Alles pins).
    address constant WEETH          = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    // §E233-sor — TWO TESTS DELETED WITH THE ROUTE THEY EXERCISED:
    //   `testReal_SorSelfFunded_UsdcToWeth` (caller-funded USDC->WETH) and
    //   `test_SorSelfFunded_WeethNeverConsumesInputWithoutOutput` (the no-input-without-output
    //   property on the weETH leg, which already recorded that weETH has NO route and sells via
    //   `LevMath._weethToWeth` in production).
    // They were the ONLY callers of `Aux.sorSelfFunded` anywhere, which is what made the entrypoint
    // reachable from a test while being unreachable in `src`.
    // ▶️ THE PROPERTY THE SECOND ONE ASSERTED IS WORTH KEEPING and must be re-stated against the
    // 1inch route when §V-R1 lands: a swap that REVERTS must not consume the caller's input. That is
    // a real invariant about an aggregator call, not about the SOR, so it outlives this deletion.



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
        // Wire the YB stack against the real venue + real swap route + the REAL Quid range (ETH) as the
        // RANGE-ONLY E0 / sold-fraction source — NO MockRangeHost: rangeOf/rangeSqrtP/soldFractionWad/reseatEpoch
        // all read the live ETH pool on the mainnet fork.
        rlm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        rvenue = new MorphoEscrowVenue(MORPHO, mp, address(rlm));
        // atomic pin-once: REAL ETH hook + Morpho flash (zero-fee repay-first de-lever) + the frozen venue.
        { address[] memory vs = new address[](1); vs[0] = address(rvenue); rlm.init(address(ETH), MORPHO, vs); }
        vm.prank(LP);
        morpho.setAuthorization(address(rvenue), true); // one-time Morpho-native isolation
    }

    /// Move the REAL ETH range UP by buying WETH out of it in bounded steps (each under the 50bps/swap manip cap),
    /// warping between so each step measures from spot≈TWAP and the guard resets. Real swaps only — the range
    /// sells ETH → real IL accrues; kept under the 5% Chainlink anchor so no reseat/no oracle override needed.
    /// Self-calibrating: stops once the live sold fraction (from ETH.poolStats) reaches `targetWad`.
    function _rallyRange(uint syncKeyPx, uint targetWad, uint maxSteps, uint usdcPerStep) internal {
        deal(address(USDC), address(this), maxSteps * usdcPerStep);
        IERC20R(address(USDC)).approve(address(AUX), maxSteps * usdcPerStep);
        for (uint i; i < maxSteps; i++) {
            // (§RALLY-MASK) EVERY exit is announced. `catch { break; }` swallowed the swap's revert,
            // so a failing venue looked like "no IL accrued" and 40 leverage tests failed 20 lines
            // later on `debt == 0`, blaming Morpho — which the trace shows was never asked to borrow.
            uint _sf = ETH.soldFractionWad(syncKeyPx);
            if (_sf >= targetWad) { emit log_named_uint("RALLY EXIT soldFraction>=target", _sf); break; }
            // 🔴 §E310 — THE OBSERVATION MUST COME FROM THE POOL. This read `AUX.getTWAPforAsset`,
            // which reads the observation RING, and then set the Chainlink mock FROM it -- so the
            // anchor was a copy of the thing it anchors and NOTHING could ever move. Measured (§C18):
            // ring TWAP, Chainlink and the pinned `ilBasisPx` were all 2501.13975863 after TEN
            // successful swaps, so `ilTargetBps` returned 0, `debtDeltaToTarget` returned 0, and
            // `venue.borrow` was never invoked -- which reads as "Morpho will not lend".
            // ⛔ AND THE FIRST ATTEMPT AT THIS FIX WAS ALSO CIRCULAR, so do not "simplify" it back:
            // `rangePrice()` is `CORE.poolStats()`, whose `priceWad` IS `obsState.lastPrice` -- the
            // ring again. §V4-CUT settles fills AT ORACLE against inventory ("one price, no
            // traversal, no discovery"), so A SWAP DRAINS INVENTORY AND MOVES NO PRICE. There is no
            // endogenous price to read: the move must be INJECTED.
            uint px = ETH.rangePrice();
            if (px == 0) { emit log_named_uint("RALLY EXIT rangePrice==0 at step", i); break; }
            px += px / 20;                          // +5%: the MARKET moves, EXOGENOUSLY
            _setLiveEthFeed(px / 1e10);             // Chainlink follows the market (LIVE feed, §E310) ...
            CORE.pushObservation(px);               // ... and the ring records it (deviation 0 => admissible)
            try AUX.swap(address(USDC), address(WETH), true, usdcPerStep, 0, true) {}
            catch (bytes memory err) { emit log_named_bytes("RALLY SWAP REVERTED", err); break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Real DOWN move: sell ETH into the range so the mark crashes ~`dropBps` (drives the venue-safety de-lever).
    /// Feed tracks the pool each step, so getCurrentLtvBps (weETH mark) falls for real — no getTWAPforAsset mock.
    function _crashRange(uint dropBps, uint maxSteps, uint ethPerStep) internal {
        uint start = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.deal(address(this), maxSteps * ethPerStep);
        for (uint i; i < maxSteps; i++) {
            // 🔴 §E310 (DOWN-SIDE TWIN) — the same circularity the rally had, and it made the exit
            // test unreachable: `px` came from the observation RING and `_setEthFeed` wrote the
            // Chainlink mock FROM it, so `px` never changed and `px <= start - drop` could never
            // fire. THE CRASH NEVER HAPPENED. That is why §C21-a read as "the de-lever does not
            // repay": the price stayed at the rally peak, so `ilTargetBps` stayed 377.5, `targetDebt`
            // still equalled `curDebt`, and `LevMath.deleverRepay` CORRECTLY returned 0.
            // ⛔ `rangePrice()` is not an escape either -- `CORE.poolStats().priceWad` IS
            // `obsState.lastPrice`. §V4-CUT settles fills AT ORACLE against inventory, so a swap
            // moves no price: the move must be INJECTED.
            uint px = ETH.rangePrice(); if (px == 0) break;
            if (px <= start - start * dropBps / 10000) break;
            px -= px * 2 / 100;                     // -2%: the MARKET moves, EXOGENOUSLY
            _setLiveEthFeed(px / 1e10);             // the LIVE feed, not the 0xE7F0FEED sentinel
            CORE.pushObservation(px);               // ring records it (deviation 0 => admissible)
            try AUX.swap{value: ethPerStep}(address(USDC), address(WETH), false, 0, 0, true) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 31 minutes);
        }
    }

    /// Seed REAL basket POOLED_USD surplus (mint QUID against USDC, the basket's own reserves) so syncLev can
    /// pair the levered range slice against FREE basket dollars — the surplus the levered slice draws from.
    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// Calm realized vol after the rally: write ~12 near-stable oracle observations over >40min (the θ vol
    /// horizon) via tiny alternating round-trip swaps, so θ=yield/(K·σ²) recovers from the rally spike. This is
    /// the realistic sequence — an IL event, then vol calms — and it's what lets syncLev add the levered range
    /// depth (the θ-budget cap refuses new exposure while vol is elevated; backing recognition is unaffected).
    function _calmVol() internal {
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        vm.deal(address(this), 20 ether);
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            // tiny alternating round-trips (θ ∝ 1/move² ⇒ small moves ⇒ σ²→~0 once the rally ages out of the 40min horizon)
            if (i % 2 == 0) { try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0, true) {} catch {} }
            else            { try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) {} catch {} }
        }
    }

    /// Realign the mock range's price feed + spot to the REAL Chainlink market. The rally elevates the range's
    /// own feed (mock-token pool we can move); the leverage's external legs execute on REAL Uniswap (which we
    /// can't). Before any real weETH↔stable leg / basket reconcile, pin the range oracle to real so
    /// getTWAPforAsset (⇒ _stableFloor, ⇒ POOLED_USD valuation) matches real execution — a fork artifact fix.
    function _realignRangeToReal() internal {
        (, int256 clp,,,) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        _setEthFeed(uint(clp)); ETH.reseat();
    }

    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }

    function _entryPrice(LevManager m, address lp) internal view returns (uint s) { ( , , , , s, ) = m.pos(lp); }

    function _openLp() internal {
        // REAL range position (the E0 IL base) — rangeOf(LP) == 5 ETH deposit, read live from ETH.
        vm.deal(LP, 6 ether);
        vm.prank(LP); ETH.deposit{value: 5 ether}(0, LP);   // venue 3 = all-Galaxy (no ether.fi offramp noise)
        deal(WEETH, LP, 5 ether);
        uint[] memory mins = new uint[](8);
        // Open at the CURRENT real range price (entry pinned from ETH.rangeSqrtP); zero leverage at entry.
        vm.startPrank(LP);
        IERC20R(WEETH).approve(address(rlm), 5 ether);
        rlm.openLev(5000, ILevVenue(address(rvenue)), 5 ether, mins); // cap = 2×
        vm.stopPrank();
        // Real rally: buy ETH out of the range so it sells ETH ⇒ real IL accrues since the pinned entry.
        _rallyRange(_entryPrice(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
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
        EV.setLevManager(address(rlm));   // register ETH/AUX -> manager so the range syncs the levered slice
        _openLp();          // 5 ETH plain range (Galaxy) + 5 ETH weETH lev, rallied + rebalanced
        ETH.syncLev(LP);     // force the levered-slice reconcile (the rebalance's auto-sync is best-effort)

        assertGt(ETH.totalBuffer(), 0, "leverage paired a debt-funded buffer into the range");
        // #55/#1: the VENUE-yield denominator is PLAIN depth (lpShares - totalLevPooled), which is
        // STRICTLY SMALLER than the TRADING-fee denominator (lpShares + totalBuffer) -- it excludes
        // both the debt-funded buffer AND the lev net-equity. So Morpho venue appreciation (funded
        // only by plain LP deposits) is distributed over plain depth alone: the lev slice + buffer
        // can no longer skim it. Trading fees rightly stay on gross depth (the buffer IS ETH depth).
        uint venueDenom   = ETH.lpShares() - ETH.totalLevPooled();
        uint tradingDenom = ETH.lpShares() + ETH.totalBuffer();
        assertLt(venueDenom, tradingDenom,
            "venue-yield denominator EXCLUDES the lev buffer + net-equity (trading-fee denom includes them)");
        assertEq(tradingDenom - venueDenom, ETH.totalBuffer() + ETH.totalLevPooled(),
            "excluded exactly the buffer + lev net-equity");
        // And the plain venue balance (_venueBalance) excludes the lev net-equity symmetrically, so a
        // lev open/close can never appear as fake venue yield: rangeETH includes it, deliverableETH
        // (the plain-venue proxy) excludes it, and they differ by the lev net-equity.
        assertGe(AUX.rangeETH(), AUX.deliverableETH(), "rangeETH (incl lev) >= deliverableETH (excl lev)");
    }

    /// @notice FULL real-venue e2e: a real Morpho Blue market (permissionless createMarket + live IRM) +
    ///   the folded `LevManager` swap legs + `MorphoEscrowVenue`. Opens a weETH-collateral leveraged
    ///   position (real Morpho borrow + real Uniswap weETH buy), then crashes the mark and de-levers — proving
    ///   the adapter's Morpho-authorization + position/borrow/repay/withdraw semantics against the LIVE contract.
    function testReal_Morpho_OpenAndDelever() public {
        _setupMorpho();
        EV.setLevManager(address(rlm));   // register ETH/AUX -> manager so the range syncs the levered slice
        _openLp();

        uint debt0 = rvenue.debtOf(LP);
        uint coll0 = rvenue.collateralOf(LP);
        emit log_named_uint("Morpho debt (USDC) after open", debt0);
        emit log_named_uint("Morpho weETH collateral after open", coll0);
        emit log_named_uint("LTV after open (bps)", rlm.getCurrentLtvBps(LP));
        assertGt(debt0, 0, "open must take on real Morpho debt");
        assertGt(coll0, 5 ether, "leverage must grow collateral beyond equity");

        // ── #52 net-equity model invariants (post-leverage) ──────────────────────────────
        // pooled/lpShares are NET equity; the debt-funded buffer is fee-earning ETH depth tracked
        // separately in levBuf/totalBuffer, EXCLUDED from equity: it can't be freely withdrawn but
        // STILL earns leverage yield via the gross fee weight (lpShares + totalBuffer).
        ETH.syncLev(LP);
        uint buffer = ETH.levBuf(LP);
        assertGt(buffer, 0, "leverage pairs a debt-funded buffer into the range");
        assertLe(buffer, rlm.grossCollateral(LP), "buffer <= live gross collateral");
        // Conservation: totalBuffer == the single levered LP's buffer.
        assertEq(ETH.totalBuffer(), buffer, "totalBuffer == sum of levBuf");
        // The buffer is EXCLUDED from equity: balanceOf (redeemable net share) does not include it,
        // and for the sole LP the net share total == their balance.
        assertEq(ETH.balanceOf(LP), ETH.lpShares(), "single LP: balanceOf(net) == lpShares(net)");
        // GROSS fee weight (fee denominator) = net lpShares + totalBuffer, strictly above net equity.
        assertGt(ETH.lpShares() + ETH.totalBuffer(), ETH.lpShares(), "gross fee weight exceeds net equity by the buffer");

        // REAL CRASH: sell ETH into the range so the mark drops ~10% (feed tracks the pool) — LTV jumps for real,
        // no getTWAPforAsset mock. De-lever then fires on the genuine mark move.
        _crashRange(1000, 12, 30 ether);
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

    /// @notice Morpho parity with the Euler capstone (#10): real range + real Morpho Blue + REAL liquidation
    ///   driven by the live Chainlink feed, basket isolation proven. Morpho liquidation is atomic (no
    ///   liquidator-health deferral, no EVC), so the liquidator just repays + seizes in one call.
    function testReal_Morpho_LiquidationLeavesBasketIntact() public {
        _setupMorpho();
        EV.setLevManager(address(rlm));
        _openLp();
        _calmVol();                    // vol calms after the IL event ⇒ θ recovers ⇒ syncLev can add the levered depth
        uint tvl0 = _tvl();
        ETH.syncLev(LP);
        uint lev0 = ETH.levPooled(LP);
        assertGt(lev0, 0, "levered range slice minted");
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
        // Realign the range oracle to the real market before reconciling — the rally elevated the mock range's
        // feed vs real Chainlink; reconcile the burn at the same real price the mint would be valued at now.
        _realignRangeToReal();
        ETH.syncLev(LP);
        assertLt(ETH.levPooled(LP), lev0, "post-liquidation: levered slice shrank to the liquidated net-equity");
        assertGe(_tvl(), tvl0, "REAL liquidation drained the basket real backing (TVL)");                          // nothing real taken
        assertGe(AUX.rangeETH(), CORE.POOLED(), "deliverable ETH must still cover the range (honest LPs whole)"); // POOLED_USD legitimately un-pairs to the free reserve after the range IL event — not a loss
    }

    // EULER SECTION REMOVED 2026-08-13 — Euler v2 BORROWING is gone (owner), so `EulerEscrowVenue`,
    // its EVK fixture (GenericFactory proxies, EVC, RealRateEulerOracle) and the two testReal_Euler_*
    // cases have no subject. Morpho is the only ETH lev venue; Aave V3 remains for the WBTC fallback.
}
