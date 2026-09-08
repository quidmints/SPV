// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {Vm} from "forge-std/Vm.sol";   // §M.1: recordLogs discriminator
import {IMorphoStaticTyping as IMorphoTest, MarketParams, Id} from "../src/imports/Interfaces.sol";
import {IOracle as IMorphoOraclePrice} from "../src/imports/Interfaces.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/Interfaces.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";   // §M.1: drive the real delivery entrypoint

interface IChainlinkFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IWeETHRateT { function getEETHByWeETH(uint) external view returns (uint); }

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

/// @notice REAL-FORK proof of the YB IL-protect production swap route. Proves the folded `LevManager` legs
///   perform a genuine stable↔weETH round-trip over LIVE markets — caller-funded SOR (stable→WETH via the
///   basket's real Uniswap-ETH hops) + ether.fi adapter mint UP / v3-pool sale DOWN (WETH↔weETH) — NOT our internal
///   range. (No sims; the bespoke RealWeethSwapper is gone, folded into LevManager.)
contract LevYbRealProbe is AllesFixture {
    // Price anchor for the MORPHO tests (RealRateMorphoOracle + the staleness cases).
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
        if (AUX.assetPriceFeed(address(WETH)) == address(0)) _auxSetAssetFeed(address(WETH), CL_ETH_USD);
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
            px += px * 8 / 100;                     // +8%: the MARKET moves, EXOGENOUSLY.
            // 8 and not 5 because the DEADBAND sets the floor: `debtDelta` no-ops below
            // `RANGE_BPS` = 300 bps, and `1 - sqrt(1/1.05)` = 241 bps does not reach it. +8% gives
            // 377 bps. The rally exits after ONE step here (soldFraction hits 50% > the 20% target),
            // so the whole move has to land in that one step.
            _setLiveEthFeed(px / 1e10);             // Chainlink follows the market (LIVE feed, §E310) ...
            // (§E294) The push is GONE and nothing replaced it: the swap below already feeds BOTH
            // sigma^2 legs (`_observeIfSourced` + `_sampleAnchorVariance`, Core:1031/1039) with the
            // anchor this loop just moved. The push was writing the ring a second time, by hand.
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
            // (§E294) The push is GONE and nothing replaced it: the swap below already feeds BOTH
            // sigma^2 legs (`_observeIfSourced` + `_sampleAnchorVariance`, Core:1031/1039) with the
            // anchor this loop just moved. The push was writing the ring a second time, by hand.
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
    uint internal _calmOk;   // §GAMMA-TRACE: how many of the 16 try/catch swaps actually LANDED
    function _calmVol() internal {
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        vm.deal(address(this), 20 ether);
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            // tiny alternating round-trips (θ ∝ 1/move² ⇒ small moves ⇒ σ²→~0 once the rally ages out of the 40min horizon)
            if (i % 2 == 0) { try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0, true) { ++_calmOk; } catch {} }
            else            { try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) { ++_calmOk; } catch {} }
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

    function _entryPrice(LevManager m, address lp) internal view returns (uint s) { ( , , , s, ) = m.pos(lp); }

    /// @notice The OPEN only — no rally, no rebalance, so the position sits at the ZERO LEVERAGE every
    ///         `openLev` starts from (`LevManager.sol:253-258`: the lever-up ladder is unreachable at
    ///         open because `ilBasisPx == pxNow`). Split out of `_openLp` for §M.1, which needs the
    ///         pooled position observable BEFORE anything levers it.
    function _openLpFlat() internal {
        // REAL range position (the E0 IL base) — rangeOf(LP) == 5 ETH deposit, read live from ETH.
        vm.deal(LP, 6 ether);
        vm.prank(LP); ETH.deposit{value: 5 ether}(0, LP);   // venue 3 = all-Galaxy (no ether.fi offramp noise)
        deal(WEETH, LP, 5 ether);
        // Open at the CURRENT real range price (entry pinned from ETH.rangeSqrtP); zero leverage at entry.
        vm.startPrank(LP);
        IERC20R(WEETH).approve(address(rlm), 5 ether);
        rlm.openLev(ILevVenue(address(rvenue)), 5 ether); // cap = 2×
        vm.stopPrank();
    }

    function _openLp() internal {
        _openLpFlat();
        // Real rally: buy ETH out of the range so it sells ETH ⇒ real IL accrues since the pinned entry.
        _rallyRange(_entryPrice(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        rlm.rebalance(LP, 0, DEX_WETH_USDC, 0, "");         // lever up to the IL target (real Morpho borrow + real Uniswap buy)
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    // §M.1 — IS THE 0-DEBT POOLED POSITION REACHABLE, AND IS ITS NET EQUITY UNDELIVERABLE?
    //
    // `LevManager.swapOutDeliverUnlevered` has ZERO callers and ZERO tests. Its docblock forbids
    // deletion on the ground that *"the §POOL-VENUE collapse took the CALL SITE away — the HOLE DID
    // NOT"*, and defers the question to a fork test that was never written. `SwapLib.sol:2404` books
    // the same thing: *"whether the 0-debt case is still reachable under §POOL-VENUE … is a
    // money-path question that needs a fork test, not a guess."*
    //
    // THE MECHANISM, read from `SwapLib.deleverEthOnDelivery:2434-2437`:
    //     uint poolDebtUsd = _toUsd18(aux, stable, ILevPooled(venue).totalDebt());
    //     uint amtNative   = poolDebtUsd == 0 ? 0 : ...;
    //     if (amtNative == 0) return 0;          // ← never reaches swapOutDeleverPooled
    // ⇒ a pool holding COLLATERAL at ZERO DEBT is refused delivery outright.
    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    function testReal_M1_ZeroDebtPoolIsReachableAndItsEquityIsUndeliverable() public {
        _setupMorpho();
        _openLpFlat();

        // ── PREMISE (rule 21): the state under test must actually EXIST in this fixture ───────────
        assertEq(rvenue.totalDebt(), 0, "premise: an open is at ZERO leverage, so the pool owes nothing");
        assertGt(rvenue.totalCollateral(), 0, "premise: and it nonetheless HOLDS collateral");
        assertGt(rlm.netEquity(LP), 0, "premise: that collateral is real per-LP net equity");

        // ── THE HOLE, MEASURED rather than reasoned: drive the real delivery entrypoint ───────────
        // ⚠️ THE INSTRUMENT NEEDS A DISCRIMINATOR, AND THE FIRST VERSION OF THIS TEST DID NOT HAVE
        //    ONE. `deleverEthOnDelivery` is a PUBLIC library function, so calling it from here
        //    delegatecalls with THIS CONTRACT as context — and `IAux.takeToSettle` is `onlyUs`, so it
        //    reverts and the §SILENT-SKIP try/catch turns that into a plain `return 0`. A bare
        //    `assertEq(delivered, 0)` therefore passes for TWO different reasons and distinguishes
        //    neither. Measured: the naive control (rally, rebalance, call again) also returned 0.
        // ⇒ USE THE EMIT §SILENT-SKIP ADDED. The three exits are now distinguishable:
        //      · 0-debt branch      → returns 0 and emits NOTHING (early return, before the try)
        //      · takeToSettle fails → returns 0 and emits DeliverDeleverSkipped(.., true)
        //      · pooled leg fails   → returns 0 and emits DeliverDeleverSkipped(.., false)
        //    So "no event" IS the proof that the 0-debt branch is what fired.
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertGt(px, 0, "premise: the ETH/USD anchor resolves (else every divisor below is 0)");

        vm.recordLogs();
        uint delivered = SwapLib.deleverEthOnDelivery(address(rlm), address(AUX), px, 1 ether, LP);
        uint skipsAtZeroDebt = _countSkips(vm.getRecordedLogs());
        assertEq(delivered, 0,
            "M.1: a swap-out shortfall against a 0-debt pool delivers NOTHING - the equity is phantom");
        assertEq(skipsAtZeroDebt, 0,
            "M.1: and it returned at the 0-DEBT branch - no skip was emitted, so nothing was swallowed");

        // ── THE CONTROL: with debt in the pool the SAME call must get PAST that branch ────────────
        // It still cannot complete from a test context (onlyUs), but it now reaches the try and
        // ANNOUNCES the skip. A skip event is therefore positive evidence that the early return
        // above was about DEBT and not about the call being inert.
        _rallyRange(_entryPrice(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        rlm.rebalance(LP, 0, DEX_WETH_USDC, 0, "");
        assertGt(rvenue.totalDebt(), 0, "control premise: the rebalance actually levered the pool");

        vm.recordLogs();
        SwapLib.deleverEthOnDelivery(address(rlm), address(AUX), AUX.getTWAPforAsset(address(WETH), 1800), 1 ether, LP);
        assertGt(_countSkips(vm.getRecordedLogs()), 0,
            "control: with debt the call REACHES the try and announces a skip, so the branch keys on debt");
    }

    /// @dev §M.1 discriminator — count `DeliverDeleverSkipped` in a recorded log set.
    function _countSkips(Vm.Log[] memory logs) internal pure returns (uint n) {
        bytes32 sig = keccak256("DeliverDeleverSkipped(address,uint256,bool)");
        for (uint i; i < logs.length; i++) if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) n++;
    }

    /// @notice §M.1 second half — the function that closes the hole actually closes it.
    ///         If this passes, `swapOutDeliverUnlevered` is load-bearing and must NOT be deleted.
    function testReal_M1_UnleveredDeliveryClosesTheHole() public {
        _setupMorpho();
        _openLpFlat();
        assertEq(rvenue.totalDebt(), 0, "premise: 0-debt pool");
        uint coll0 = rvenue.collateralOf(LP);
        assertGt(coll0, 0, "premise: with collateral to deliver");

        uint bal0 = IERC20R(address(WETH)).balanceOf(LP);
        // Gated to the range (`_onlyRange`), which `init` pinned to the ETH range manager.
        vm.prank(address(ETH));
        uint got = rlm.swapOutDeliverUnlevered(LP, 1 ether, LP, 0);

        assertGt(got, 0, "M.1: the unlevered path DOES deliver what the pooled path refused");
        assertEq(IERC20R(address(WETH)).balanceOf(LP) - bal0, got, "and the WETH actually arrives");
        assertLt(rvenue.collateralOf(LP), coll0, "and it comes out of the LP's own venue collateral");
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
        rlm.deleverOne(LP, 0, DEX_WETH_USDC, 0, "");

        emit log_named_uint("Morpho debt (USDC) after delever", rvenue.debtOf(LP));
        emit log_named_uint("LTV after delever (bps)", rlm.getCurrentLtvBps(LP));
        assertLt(rvenue.debtOf(LP), debt0, "de-lever must repay real Morpho debt");
        assertLt(rvenue.collateralOf(LP), coll0, "de-lever must withdraw real Morpho collateral");
    }

    /// @notice Capstone #10: real range + real Morpho Blue + REAL liquidation
    ///   driven by the live Chainlink feed, basket isolation proven. Morpho liquidation is atomic (no
    ///   liquidator-health deferral, no EVC), so the liquidator just repays + seizes in one call.
    /// @notice 🔬 §LIQ-PENALTY-PROBE — **DOES THE OVER-CLAIM TRACK THE LIQUIDATED FRACTION?**
    ///   `testReal_Morpho_LiquidationLeavesBasketIntact` is red by `POOLED − rangeETH − levBuf` =
    ///   0.004915 ETH. Since `rangeETH = tokens + net` and `levBuf = gross − net`, that residual is
    ///   `POOLED − tokens − gross`: the book claiming more than the ETH custodied plus the gross
    ///   levered collateral. The leading hypothesis was the REAL Morpho liquidation's PENALTY, which
    ///   `POOLED` has no path to absorb — it moves only on swap deltas (`Core:1204/1212`).
    /// ⇒ **FALSIFIER: vary the liquidated fraction.** A penalty-driven residual must SCALE with it.
    /// ⭐ **AND THE 0/1 ARM IS THE ONE THAT DECIDES IT.** If the residual is already non-zero with NO
    ///   liquidation at all, the penalty cannot be the cause and the defect is upstream — in the
    ///   fixture or in the book itself. Owner, 2026-09-08: *"maybe its a problem in the tests
    ///   themselves"*. That arm is the control, and it is why this is four tests and not three.
    /// @dev Returns SIGNED: negative means slack (the invariant holds), positive means over-claim.
    function _residualAtFraction(uint numer, uint denom) internal returns (int256) {
        _setupMorpho();
        EV.setLevManager(address(rlm));
        _openLp();
        _calmVol();
        ETH.syncLev(LP);
        if (numer > 0) {
            {   uint vdebt0 = rvenue.debtOf(LP);
                uint collValue = rvenue.collateralOf(LP) * IMorphoOraclePrice(mOracle).price() / 1e36;
                (uint80 rid, int256 pr,, uint256 ut, uint80 ar) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
                vm.mockCall(CL_ETH_USD, abi.encodeWithSelector(IChainlinkFeedT.latestRoundData.selector),
                    abi.encode(rid, int256(uint256(pr) * vdebt0 * 100 / (collValue * 92)), ut, ut, ar));
            }
            deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
            IERC20R(address(USDC)).approve(MORPHO, type(uint).max);
            {   (,, uint128 poolColl) = IMorphoTest(MORPHO).position(rvenue.MARKET_ID(), address(rvenue));
                IMorphoTest(MORPHO).liquidate(MarketParams({loanToken: address(USDC), collateralToken: WEETH,
                    oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18}),
                    address(rvenue), uint256(poolColl) * numer / denom, 0, "");
            }
            vm.clearMockedCalls();
        }
        _realignRangeToReal();
        ETH.syncLev(LP);
        int256 residual = int256(CORE.POOLED()) - int256(AUX.rangeETH()) - int256(ETH.levBuf(LP));
        emit log_named_uint("  liquidated numer   ", numer);
        emit log_named_uint("  POOLED             ", CORE.POOLED());
        emit log_named_uint("  rangeETH           ", AUX.rangeETH());
        emit log_named_uint("  levBuf             ", ETH.levBuf(LP));
        emit log_named_int ("  RESIDUAL (+ = over-claim)", residual);
        return residual;
    }
    /// @notice 🔬 §CALMVOL-LEG-SPLIT — **WHICH OF `_calmVol`'s THREE MOVEMENTS IS UNMATCHED?**
    ///   `_calmVol` moved the residual by +0.005358 ETH and it does THREE things per iteration, not
    ///   two: a DRAIN (USD in, ETH out), a SELL (ETH in, USD out), and a FEED RESET
    ///   (`_setEthFeed(px/1e10)` after a warp). Each arm below does exactly one of them, from the same
    ///   post-`rebalance` state, so the movement that is not custody-neutral is read off directly.
    /// ⚠️ **THE FEED ARM IS NOT A CONTROL, IT IS A SUSPECT.** `rangeETH` adds `totalNetEquity` =
    ///   collateral − debt, and the DEBT is dollars converted at the oracle — so moving the price
    ///   moves `rangeETH` while `POOLED`, a raw token count, cannot follow. That is an unmatched
    ///   movement with no swap in it at all, and it would look exactly like this.
    function _setupToRebalanced() internal {
        _setupMorpho();
        EV.setLevManager(address(rlm));
        _openLpFlat();
        _rallyRange(_entryPrice(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        rlm.rebalance(LP, 0, DEX_WETH_USDC, 0, "");
    }
    function _res() internal returns (int256) {
        return int256(CORE.POOLED()) - int256(AUX.rangeETH()) - int256(ETH.levBuf(LP));
    }
    /// 🔬 §PREMIUM-READABLE — **THE CANDIDATE IDENTITY, MEASURED BEFORE IT IS ASSERTED.** The claim is
    ///    `POOLED + retainedEthPremium == rangeETH + levBuf` (= tokens + gross), i.e. the residual is
    ///    exactly minus the retained ETH premium. ⚠️ It may be FALSE: a cumulative premium can only be
    ///    ≥ 0, so it can only ever explain a NEGATIVE residual, and `_calmVol` produced a POSITIVE one.
    ///    Printing both rather than asserting, because asserting a sign I have not checked is how two
    ///    wrong mechanisms already reached this row.
    function _identity(string memory label) internal {
        int256 res = _res();
        uint256 prem = CORE.retainedEthPremium();
        emit log_named_string("IDENTITY at", label);
        emit log_named_int ("   residual              ", res);
        emit log_named_uint("   retainedEthPremium    ", prem);
        emit log_named_int ("   residual + premium (0?)", res + int256(prem));
    }
    /// The two paths that produced opposite-signed residuals, now with the premium visible.
    function testReal_Identity_A_SellsWithWarps() public {
        _setupToRebalanced(); vm.deal(address(this), 20 ether);
        _identity("before");
        for (uint i; i < 8; i++) {
            vm.warp(block.timestamp + 12 minutes); vm.roll(block.number + 1);
            try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) {} catch {}
        }
        _identity("after 8 sells + warps");
    }
    function testReal_Identity_B_Interleaved() public {
        _setupToRebalanced();
        _identity("before");
        _calmVol();
        _identity("after _calmVol (interleaved)");
    }
    function testReal_CalmLeg_A_DrainsOnly() public {
        _setupToRebalanced();
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        int256 r0 = _res();
        for (uint i; i < 8; i++) {
            try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0, true) {} catch {}
        }
        emit log_named_int("DRAINS ONLY  residual before", r0);
        emit log_named_int("DRAINS ONLY  residual after ", _res());
        emit log_named_int("DRAINS ONLY  DELTA          ", _res() - r0);
    }
    function testReal_CalmLeg_B_SellsOnly() public {
        _setupToRebalanced();
        vm.deal(address(this), 20 ether);
        int256 r0 = _res();
        for (uint i; i < 8; i++) {
            try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) {} catch {}
        }
        emit log_named_int("SELLS ONLY   residual before", r0);
        emit log_named_int("SELLS ONLY   residual after ", _res());
        emit log_named_int("SELLS ONLY   DELTA          ", _res() - r0);
    }
    /// ⭐ §CALMVOL-LEG-SPLIT ROUND 3 — **THE LAST UNTESTED COMBINATION, and by elimination it must
    ///   carry the whole positive offset.** Measured so far: drains −9 wei, sells −450e12, feed 0,
    ///   sells+warps −6,211,973,167,828,659 — **every isolated arm is ≤ 0**, while `_calmVol`
    ///   interleaved is **+5,357,529,343,317,595**. Only DRAINS + warps/feed resets remains.
    /// ⛔ ARM D ALSO REFUTED THE ACCRUAL HYPOTHESIS OUTRIGHT: debt was 559,362,971 BEFORE and AFTER
    ///   96 minutes of warps. Morpho accrues lazily and nothing here touches it, so time alone moves
    ///   no debt. Do not re-derive "the residual is interest accrual" — it is measured false.
    /// 🔎 What is left is the FEED RESET READING A PRICE THE DRAINS MOVED. `_setEthFeed(px/1e10)`
    ///   copies the pool's TWAP into the oracle; `rangeETH` adds `totalNetEquity = collateral −
    ///   debt`, and the debt is dollars valued at that oracle. So a drain moves the price, the reset
    ///   propagates it, `netEquity` re-values, and `rangeETH` moves **with zero custody change** —
    ///   while `POOLED`, a raw token count, cannot follow. Arm C read 0 because with no trades the
    ///   TWAP never moved, so the reset was a no-op. This arm supplies the trades.
    function testReal_CalmLeg_E_DrainsWithWarps() public {
        _setupToRebalanced();
        deal(address(USDC), address(this), 20_000 * USDC_PRECISION);
        USDC.approve(address(AUX), 20_000 * USDC_PRECISION);
        int256 r0 = _res();
        uint px0 = AUX.getTWAPforAsset(address(WETH), 1800);
        for (uint i; i < 8; i++) {
            vm.warp(block.timestamp + 12 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
            try AUX.swap(address(USDC), address(WETH), true, 30 * USDC_PRECISION, 0, true) {} catch {}
        }
        emit log_named_int ("DRAINS+WARP  residual before", r0);
        emit log_named_int ("DRAINS+WARP  residual after ", _res());
        emit log_named_int ("DRAINS+WARP  DELTA          ", _res() - r0);
        emit log_named_uint("DRAINS+WARP  oracle px start", px0);
        emit log_named_uint("DRAINS+WARP  oracle px end  ", AUX.getTWAPforAsset(address(WETH), 1800));
        emit log_named_uint("DRAINS+WARP  netEquity      ", rlm.totalNetEquity());
    }

    /// ⭐ §CALMVOL-LEG-SPLIT ROUND 2 — **NO SINGLE LEG PRODUCES THE OFFSET.** Measured: drains −9 wei,
    ///   sells −450,000,000,000,000 (NEGATIVE, the premium direction, which independently confirms
    ///   §PREMIUM-DENOM-ROOT's sign prediction), feed resets EXACTLY 0. They sum to −0.00045 ETH while
    ///   `_calmVol` produced **+0.005358**. ⇒ the offset is not in any leg; it needs TIME TO PASS
    ///   BETWEEN SWAPS, which is the one thing the isolated arms above do not do.
    ///   ⚠️ Leading candidate: debt accrues (Morpho) while `POOLED` is a raw token count that cannot
    ///   follow, so `totalNetEquity = collateral − debt` falls and `rangeETH` with it. The feed-only
    ///   arm reads 0 because with NO Morpho interaction the debt is never accrued — lazily, on touch.
    ///   ⇒ This arm is sells + warps: same swaps as arm B, with the 6-minute gaps restored.
    function testReal_CalmLeg_D_SellsWithWarps() public {
        _setupToRebalanced();
        vm.deal(address(this), 20 ether);
        int256 r0 = _res();
        uint d0 = rvenue.debtOf(LP);
        for (uint i; i < 8; i++) {
            vm.warp(block.timestamp + 12 minutes); vm.roll(block.number + 1);
            try AUX.swap{value: 0.015 ether}(address(USDC), address(WETH), false, 0, 0, true) {} catch {}
        }
        emit log_named_int ("SELLS+WARP   residual before", r0);
        emit log_named_int ("SELLS+WARP   residual after ", _res());
        emit log_named_int ("SELLS+WARP   DELTA          ", _res() - r0);
        emit log_named_uint("SELLS+WARP   debt before    ", d0);
        emit log_named_uint("SELLS+WARP   debt after     ", rvenue.debtOf(LP));
    }

    function testReal_CalmLeg_C_FeedResetsOnly() public {
        _setupToRebalanced();
        int256 r0 = _res();
        for (uint i; i < 16; i++) {
            vm.warp(block.timestamp + 6 minutes); vm.roll(block.number + 1);
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px != 0) _setEthFeed(px / 1e10);
        }
        emit log_named_int("FEED ONLY    residual before", r0);
        emit log_named_int("FEED ONLY    residual after ", _res());
        emit log_named_int("FEED ONLY    DELTA          ", _res() - r0);
    }

    /// @notice 🔬 §LIQ-PENALTY-REFUTED → **WHERE DOES THE CONSTANT OFFSET ENTER?** The fraction sweep
    ///   returned 4,780,507,795,264,422 IDENTICAL TO THE WEI at 0, 1/4, 1/2 and 3/4 liquidated —
    ///   including the zero arm. A penalty must scale; this does not, and it is present with no
    ///   liquidation at all. ⇒ the residual is a FIXED accounting offset introduced during SETUP.
    ///   This walks the setup one step at a time and prints the residual after each, so the step that
    ///   introduces it is read off rather than guessed.
    function testReal_LiqPenalty_4_WhereDoesTheOffsetEnter() public {
        _setupMorpho();
        EV.setLevManager(address(rlm));
        _step("after _setupMorpho");
        _openLpFlat();
        _step("after _openLpFlat (5 ETH deposit + 5 weETH openLev)");
        _rallyRange(_entryPrice(rlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        _step("after _rallyRange");
        rlm.rebalance(LP, 0, DEX_WETH_USDC, 0, "");
        _step("after rebalance (lever to IL target)");
        _calmVol();
        _step("after _calmVol");
        ETH.syncLev(LP);
        _step("after syncLev");
    }
    function _step(string memory label) internal {
        emit log_named_string("STEP", label);
        emit log_named_uint ("   POOLED  ", CORE.POOLED());
        emit log_named_uint ("   rangeETH", AUX.rangeETH());
        emit log_named_uint ("   levBuf  ", ETH.levBuf(LP));
        emit log_named_int  ("   RESIDUAL", int256(CORE.POOLED()) - int256(AUX.rangeETH()) - int256(ETH.levBuf(LP)));
    }

    /// ⭐ THE CONTROL. No liquidation at all. A penalty hypothesis REQUIRES this to be <= 0.
    function testReal_LiqPenalty_0_ControlNoLiquidation() public { _residualAtFraction(0, 1); }
    function testReal_LiqPenalty_1_Quarter()             public { _residualAtFraction(1, 4); }
    function testReal_LiqPenalty_2_Half()                public { _residualAtFraction(1, 2); }
    function testReal_LiqPenalty_3_ThreeQuarters()       public { _residualAtFraction(3, 4); }

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

        // §POOL-VENUE — THE SEIZED BORROWER IS THE VENUE, BECAUSE THAT IS WHO HOLDS THE POSITION NOW.
        // This named `LP` and the comment claimed "the violator is the LP itself — onBehalf isolation,
        // no sub-account". That is exactly the premise `LevVenueBase` deleted: every Morpho call now
        // passes `address(this)`, so naming `LP` liquidated an EMPTY ACCOUNT and Morpho answered
        // `position is healthy` — a true statement about an account with no position, which is what
        // the failure actually was. The BTC twin (`VBtcLevFeeLane._seizeRealBtc`) was migrated for
        // this and this ETH half was not.
        // 🔴 AND THE GUARANTEE IS GENUINELY WEAKER NOW, SO SAY SO RATHER THAN RE-GREEN IT QUIETLY.
        // Pooled, a seizure hits the pool and therefore EVERY LP pro-rata. What survives — and what
        // the assertions below still bind — is that a REAL Morpho liquidation is survived cleanly and
        // takes NOTHING from the QU!D basket. Containment to one LP is no longer a property of the
        // venue; it is protocol-enforced upstream by `cascadeDelever` + the LTV hysteresis.
        MarketParams memory mp = MarketParams({
            loanToken: address(USDC), collateralToken: WEETH, oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18});
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, type(uint).max);
        (,, uint128 poolColl) = IMorphoTest(MORPHO).position(rvenue.MARKET_ID(), address(rvenue));
        IMorphoTest(MORPHO).liquidate(mp, address(rvenue), uint256(poolColl) / 2, 0, "");
        assertLt(rvenue.debtOf(LP), vdebt0, "REAL Morpho liquidation reduced the pooled debt (LP's pro-rata claim falls)");

        // Basket clean: the levered slice shrinks to the liquidated net-equity, POOLED_USD not drained.
        vm.clearMockedCalls();
        // Realign the range oracle to the real market before reconciling — the rally elevated the mock range's
        // feed vs real Chainlink; reconcile the burn at the same real price the mint would be valued at now.
        _realignRangeToReal();
        ETH.syncLev(LP);
        assertLt(ETH.levPooled(LP), lev0, "post-liquidation: levered slice shrank to the liquidated net-equity");
        assertGe(_tvl(), tvl0, "REAL liquidation drained the basket real backing (TVL)");                          // nothing real taken
        emit log_named_uint("C25 AUX.rangeETH        ", AUX.rangeETH());
        emit log_named_uint("C25 AUX.deliverableETH  ", AUX.deliverableETH());
        emit log_named_uint("C25 CORE.POOLED         ", CORE.POOLED());
        emit log_named_uint("C25 GAP (POOLED-range)  ", CORE.POOLED() - AUX.rangeETH());
        emit log_named_uint("C25 lm.totalNetEquity   ", rlm.totalNetEquity());
        emit log_named_uint("C25 ETH.levPooled(LP)   ", ETH.levPooled(LP));
        emit log_named_uint("C25 ETH.levBuf(LP)      ", ETH.levBuf(LP));
        emit log_named_uint("C25 rvenue.collateralOf ", rvenue.collateralOf(LP));
        // 🔴 §C25 — **THE RANGE IS COVERED BY REAL ETH *PLUS THE DEBT-FUNDED BUFFER*, AND OMITTING
        //    THE SECOND TERM IS WHAT MADE THIS LOOK LIKE A SHORTFALL.** `CORE.POOLED()` is the
        //    range's CAPACITY, and `Quid.sol:979` pins that capacity as `levPooled + levBuf`:
        //    the levered net leg PLUS a buffer funded by BORROWED DOLLARS. `AUX.rangeETH()` counts
        //    only ETH actually held at a venue, so it cannot and must not include a slice that no
        //    ETH backs. ⇒ With leverage live, `rangeETH < POOLED` BY CONSTRUCTION, by ~`levBuf`.
        // ⭐ MEASURED, and this is what closed §C25 after two wrong candidates. The gap was
        //    0.100497 ETH against `levBuf` = 0.107576 — so `rangeETH + levBuf` clears `POOLED`
        //    with 0.00708 ETH to spare, which is the honest-LP margin the assertion is really about.
        //    ⛔ NEITHER of the two deferrals proposed earlier explains it: the LEVERED NET-EQUITY is
        //    subtracted by `deliverableETH`, not by `rangeETH` (which is what this line reads), and
        //    the CURVE bound (`balances(0) * 9/10`) sits near 1,986 ETH against positions of ~5.
        // ⚠️ THE ASSERTION IS NOT WEAKENED — it is stated in the units it always meant. Dropping the
        //    buffer term would have been the clamp; adding it is the identity.
        // 🔬 §GAMMA-BREAKS-HONEST-LP-MARGIN — **THE THREE TERMS, EMITTED, BECAUSE THE VERDICT ALONE
        //    SENT ME TO THE WRONG MECHANISM.** This assertion went red on `a4787689` (Γ moved onto its
        //    derivation, 3e16 → 5.48e15). From the failure line alone I concluded *"a smaller Γ prices
        //    drains cheaper, so more ETH leaves the range"* and published it. **That was wrong.**
        //    Reading the three terms in each Γ arm of THIS fixture showed:
        //        rangeETH + levBuf   4,925,305,260,073,929,011 → 4,925,368,211,597,702,940  (+0.0013%)
        //        POOLED  (capacity)  4,918,038,192,545,221,464 → 4,930,283,601,835,221,980  (+0.012245 ETH)
        //        levBuf                                    IDENTICAL, to the wei
        //    ⇒ **THE ETH NEVER LEFT.** `levBuf` did not move at all, the backing is flat, and the whole
        //      margin loss is `POOLED` — the range's CLAIMED CAPACITY — rising while its backing stays
        //      put. A book-versus-backing divergence, not an outflow. The attribution closes exactly:
        //      `ΔPOOLED − Δ(rangeETH+levBuf)` equals the margin loss to the wei.
        //    ⛔ `levBuf` BEING IDENTICAL IS WHY "re-size the debt-funded buffer" IS A DEAD END — it is
        //      not the quantity that moved. Anyone reaching this red should read the three numbers
        //      before forming a mechanism, which is the step I skipped.
        //    📌 KEPT rather than deleted after the diagnosis (project-bc's argument, and it is right):
        //      a future reader re-deriving this wants to RE-RUN the instrument, not rebuild it. Three
        //      emits cost nothing and turn a bare pass/fail into a diagnosis.
        //    ⚠️ The direction is still UNTRACED — a smaller retained premium should make the book grow
        //      LESS, not more. Do not close that gap with a plausible story; one has already been wrong.
        // 🔬 §GAMMA-TRACE — HOW MANY OF `_calmVol`'s 16 SWAPS LANDED. They are wrapped in
        //    `try {} catch {}`, so a revert is SILENT: a Γ change that flips one marginal swap moves
        //    `POOLED` by that swap's whole size while leaving venue-held `rangeETH` untouched (an
        //    ETH-in swap sits IN-RANGE, not at a venue) — which is exactly the signature this red has.
        //    §E71-r3 booked this class already: *"NO try/catch and NO minOut=0 mask"*.
        emit log_named_uint("calmVol swaps LANDED /16  ", _calmOk);
        emit log_named_uint("rangeETH + levBuf (backing)", AUX.rangeETH() + ETH.levBuf(LP));
        emit log_named_uint("POOLED            (claim)  ", CORE.POOLED());
        emit log_named_uint("levBuf       (debt-funded) ", ETH.levBuf(LP));
        assertGe(AUX.rangeETH() + ETH.levBuf(LP), CORE.POOLED(),
            "real venue ETH + the debt-funded buffer must cover the range (honest LPs whole)");
    }
}
