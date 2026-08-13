// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {LevManager} from "../src/LevManager.sol";
import {ILevVenue} from "../src/imports/ILevVenue.sol";
import {MorphoEscrowVenue, MarketParams} from "../src/MorphoEscrowVenue.sol";

interface IERC20R {
    function approve(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
}
interface IChainlinkFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IWeETHRateT { function getEETHByWeETH(uint) external view returns (uint); }
interface IMorphoTest {
    function createMarket(MarketParams memory m) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256, uint256);
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128);
}
interface IMorphoOraclePrice { function price() external view returns (uint256); }
interface ILevBandView { function bandSqrtP(bool isBtc) external view returns (uint160); }

/// Morpho IOracle from REAL sources (weETH→ETH ether.fi rate × real Chainlink ETH/USD), 1e36-scaled. No mock price.
contract RealRateMorphoOracle {
    address public immutable WEETH;
    IChainlinkFeedT public immutable ETH_USD;
    constructor(address weeth, address ethUsd) { WEETH = weeth; ETH_USD = IChainlinkFeedT(ethUsd); }
    function price() external view returns (uint256) {
        uint ethPerWeeth = IWeETHRateT(WEETH).getEETHByWeETH(1e18);
        (, int256 p,,,) = ETH_USD.latestRoundData();
        return (ethPerWeeth * uint(p) / 1e8) * 1e6;
    }
}

/// @title  LeverageCrossSubsidyProbe — REAL-stack regression for the ONE cross-subsidy invariant that matters
/// @notice A PASSIVE regular band LP is NOT expensed by a LEVERED LP's full lifecycle (open → lever → venue
///   liquidation). The IL-protect leverage is isolated BY CONSTRUCTION: `levPooled ≡ netEquity`, `deliverableETH`
///   EXCLUDES the levered slice, and every leverage leg executes EXTERNALLY (Morpho borrow + ether.fi/Uniswap
///   sale via SOR), NEVER the internal band. So a levered LP being liquidated socializes NOTHING onto the passive
///   LP: measured at a MATCHED price (to strip the price move the lever's rally drives), the passive LP's
///   redeemable value and the basket's real backing (TVL) are intact. (The dead Liquity-Trove design this probe
///   used to model is gone; this is the real-venue replacement.)
contract LeverageCrossSubsidyProbe is Alles {
    address constant WEETH        = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant CL_ETH_USD   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    LevManager lm;
    MorphoEscrowVenue venue;
    address mOracle;
    MarketParams mp;
    address constant PASSIVE = address(0xBEEF5);   // passive regular band LP (the potential victim)
    address constant LEVR    = address(0xBEEF7);   // leveraged LP

    function _setupLev() internal {
        _seedBasket();
        RealRateMorphoOracle oracle = new RealRateMorphoOracle(WEETH, CL_ETH_USD);
        mOracle = address(oracle);
        mp = MarketParams({loanToken: address(USDC), collateralToken: WEETH,
            oracle: address(oracle), irm: ADAPTIVE_IRM, lltv: 0.86e18});
        IMorphoTest morpho = IMorphoTest(MORPHO);
        morpho.createMarket(mp);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, 5_000_000 * USDC_PRECISION);
        morpho.supply(mp, 5_000_000 * USDC_PRECISION, 0, address(this), "");
        lm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        venue = new MorphoEscrowVenue(MORPHO, mp, address(lm));
        address[] memory vs = new address[](1); vs[0] = address(venue);
        lm.init(address(V4), MORPHO, vs);

        // PIN THE ETH/USD ANCHOR (BUILD-QUEUE §A.13). This fixture maintains ETH_FEED as a
        // pool-tracking mock (`_setEthFeed`) but never registered it with Aux, so assetPriceFeed(WETH)
        // was address(0). Without an anchor, a rally that walks the pool toward its tick boundary makes
        // getTWAPforAsset return 0, `rebalanceCore`'s `if (twap == 0) return r` blocks the repack, and
        // the band stops being re-paired — which also makes `_realignBandToReal`'s `V4.reseat()` a
        // no-op. For a TREATMENT-vs-CONTROL comparison that is fatal: the two arms can diverge on
        // oracle availability rather than on the levered LP's actual effect, which is the only thing
        // this probe is trying to measure.
        _setEthFeed(AUX.getTWAPforAsset(address(WETH), 1800) / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
    }

    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

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

    function _realignBandToReal() internal {
        (, int256 clp,,,) = IChainlinkFeedT(CL_ETH_USD).latestRoundData();
        _setEthFeed(uint(clp)); V4.reseat();
    }

    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }
    function _entrySqrt(address lp) internal view returns (uint160 s) { ( , , , , s, ) = lm.pos(lp); }

    function _bandE0(address lp, uint sizeEth) internal {
        vm.deal(lp, sizeEth + 1 ether);
        vm.prank(lp); V4.deposit{value: sizeEth}(0, lp);
        deal(WEETH, lp, sizeEth);
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);
    }
    function _openLevOnly(address lp, uint sizeEth) internal {
        uint[] memory mins = new uint[](8);
        vm.startPrank(lp);
        IERC20R(WEETH).approve(address(lm), sizeEth);
        lm.openLev(5000, ILevVenue(address(venue)), sizeEth, mins);
        vm.stopPrank();
    }

    /// REAL Morpho seizure of `lp` (repay `numer/denom` of the debt by SHARES — never seizedAssets, which
    /// over-repays a small debt and underflows Morpho). Crashes the shared Chainlink feed to ~92% LTV first.
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
        IMorphoTest(MORPHO).liquidate(mp, lp, 0, uint256(borrowShares) * numer / denom, "");
        vm.clearMockedCalls();
        _realignBandToReal();
    }

    /// The passive LP's redeemable value (USD 1e18) at the CURRENT (real, post-realign) price — redeem in a
    /// snapshot, value the ETH + QUID it receives, then revert. Matched-price so the measurement strips the
    /// lever's rally price move and isolates any cross-subsidy transfer.
    function _passiveValueUsd(uint shares) internal returns (uint usd) {
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        uint snap = vm.snapshotState();
        uint e0 = PASSIVE.balance; uint w0 = WETH.balanceOf(PASSIVE); uint q0 = QUID.balanceOf(PASSIVE);
        vm.prank(PASSIVE); try V4.redeem(shares, PASSIVE, PASSIVE) {} catch {}
        usd = ((PASSIVE.balance - e0) + (WETH.balanceOf(PASSIVE) - w0)) * px / 1e18 + (QUID.balanceOf(PASSIVE) - q0);
        vm.revertToState(snap);
    }

    /// CONTROL vs TREATMENT at a matched price. The band's IL from the rally price move hits the passive LP in
    /// BOTH arms (it is NOT cross-subsidy — the band sells the passive LP's ETH on any move); differencing it
    /// out, the cross-subsidy is (treatment − control). If the leverage is isolated, they're equal: the levered
    /// LP's external ops + isolated slice add NOTHING onto the passive LP beyond the shared price path.
    function test_PassiveLp_NotExpensedByLeveredLpLifecycle() public {
        _setupLev();

        // A passive REGULAR band LP (no leverage) — the party that must not be expensed.
        vm.deal(PASSIVE, 20 ether);
        vm.prank(PASSIVE); uint shares = V4.deposit{value: 10 ether}(0, PASSIVE);
        require(shares > 0 && CORE.POOLED_ETH() > 0, "no in-range pool for the passive LP");
        uint160 startSqrt = ILevBandView(address(V4)).bandSqrtP(false);   // shared rally reference for both arms

        uint snap = vm.snapshotState();

        // ── TREATMENT: a levered LP runs its FULL lifecycle over the SAME rally price path ──
        ETH.setLevManager(address(lm));                     // pin the leveraged book into vogueETH
        _bandE0(LEVR, 5 ether);
        _openLevOnly(LEVR, 5 ether);
        _rallyBand(startSqrt, 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(LEVR, 0);                              // real Morpho borrow + external Uniswap buy (NOT the band)
        require(venue.debtOf(LEVR) > 0, "precondition: levered position took real debt");
        _seizeReal(LEVR, 1, 1);                             // REAL Morpho liquidation of the levered LP
        _realignBandToReal();
        uint passiveT = _passiveValueUsd(shares);
        uint tvlT     = _tvl();

        vm.revertToState(snap);

        // ── CONTROL: the SAME band rally price path, NO levered LP at all ──
        _rallyBand(startSqrt, 0.2e18, 20, 8_000 * USDC_PRECISION);
        _realignBandToReal();
        uint passiveC = _passiveValueUsd(shares);
        uint tvlC     = _tvl();

        // Cross-subsidy = treatment − control. Isolated leverage ⇒ treatment ≥ control (to a rounding band):
        // the levered LP's borrow/buy/liquidation took NOTHING from the passive LP beyond the shared IL.
        assertGe(passiveT, passiveC * 9990 / 10000,
            "CROSS-SUBSIDY: levered LP must not expense the passive LP beyond the shared rally IL");
        assertGe(tvlT, tvlC * 9990 / 10000,
            "CROSS-SUBSIDY: basket real backing (TVL) not reduced by the levered LP's presence + liquidation");
    }
}
