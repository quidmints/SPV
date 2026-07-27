// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Reuse the real-fork weETH probe wholesale (mainnet fork via Alles, band/rally/crash helpers, constants,
// interfaces). Only the borrow VENUE differs here: the live Aave V4 Hub/Spoke instead of a Morpho market.
import "./LevYbReal.t.sol";
import {AaveV4Venue} from "../src/AaveV4Venue.sol";

/// @notice REAL-FORK proof that the Aave V4 venue (WETH collateral, USDC debt, per-LP escrow isolation) is
///   production-live THROUGH `LevManager` — open -> lever-up -> close — not just at the ILevVenue adapter level
///   (test/AaveV4Venue.t.sol). It takes the SAME generic WETH-collateral manager path the Morpho-WETH probe uses
///   (1:1 valuation, USDC borrow, SOR-buy WETH, WETH sold back on close); the only difference is the venue, so a
///   green run proves LevManager is genuinely venue-agnostic across the newly-registered Aave venue.
contract LevYbAaveProbe is LevYbRealProbe {
    // Live Aave V4 Hub/Spoke (same addresses the basket supply-side + AaveV4Venue.t.sol use).
    address constant AAVE_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address constant AAVE_HUB   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;

    LevManager alm;
    AaveV4Venue avenue;

    function _setupAave() internal {
        _seedBasket();
        rpx = AUX.getTWAPforAsset(address(WETH), 1800);
        alm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        avenue = new AaveV4Venue(AAVE_SPOKE, AAVE_HUB, address(WETH), address(USDC), address(alm), 8000);
        // Flash provider is MORPHO — USDC is Morpho-flashable, so the repay-first de-lever engine works unchanged.
        // No setAuthorization: Aave isolation is the per-LP escrow the venue deploys, not an onBehalf grant.
        { address[] memory vs = new address[](1); vs[0] = address(avenue); alm.init(address(V4), MORPHO, vs); }
    }

    function _openAaveLp() internal {
        vm.deal(LP, 6 ether);
        vm.prank(LP); V4.deposit{value: 5 ether}(0, LP, 3);   // 5 ETH plain band equity (all-Galaxy venue)
        deal(address(WETH), LP, 5 ether);                       // 5 WETH lev equity
        uint[] memory mins = new uint[](8);
        vm.startPrank(LP);
        IERC20R(address(WETH)).approve(address(alm), 5 ether);
        alm.openLev(5000, ILevVenue(address(avenue)), 5 ether, mins); // cap 2x, zero leverage at entry
        vm.stopPrank();
        alm.setSoldFractionActive(true);
        _rallyBand(_entrySqrt(alm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        alm.rebalance(LP, 0);         // lever up: borrow USDC from live Aave V4 + SOR-buy WETH, supply back
    }

    function testReal_Aave_OpenLeverClose() public {
        _setupAave();
        ETH.setLevManager(address(alm));    // BACKING: vogueETH counts this WETH lev book
        _openAaveLp();

        uint debt0 = avenue.debtOf(LP);
        uint coll0 = avenue.collateralOf(LP);
        emit log_named_uint("Aave USDC debt after open+lever", debt0);
        emit log_named_uint("Aave WETH collateral after open+lever", coll0);
        emit log_named_uint("LTV after open (bps)", alm.getCurrentLtvBps(LP));
        assertGt(debt0, 0, "open+lever must take on real Aave USDC debt");
        assertGt(coll0, 5 ether, "lever-up must grow WETH collateral beyond the 5 WETH equity");

        // GROSS collateral flows into the band 1:1 (WETH == ETH); debt buffers net-equity below gross.
        assertEq(alm.grossCollateralEth(LP), coll0, "WETH gross collateral valued 1:1 in ETH");
        uint netEq = alm.netEquityEth(LP);
        assertGt(netEq, 0, "net-equity is positive");
        assertLt(netEq, coll0, "debt buffers gross above net-equity");
        assertGt(alm.totalDebtUsd(), 0, "book debt includes the Aave position");
        // Same correction as testReal_Weth_OpenLeverClose (BUILD-QUEUE §A.14): assert against the
        // protocol's OWN ETH-backing composition, `vogueETH + totalBuffer` (VogueLib.addLiq:
        // `IAux(aux).vogueETH() + grossBuffer`). `vogueETH` counts a levered position at NET equity by
        // design; the debt-funded remainder is tracked in `totalBuffer` and excluded from equity so it
        // cannot be withdrawn as if it were the LP's. Asking `vogueETH` alone to cover GROSS made one
        // term do two jobs, and it failed by exactly the debt (5.893 vs 7.507).
        assertGe(AUX.vogueETH() + V4.totalBuffer(), coll0,
            "ETH backing (vogueETH net + totalBuffer gross) counts the Aave gross collateral");

        // Close unwinds through the SAME manager path: sell WETH -> repay all USDC -> return the remaining WETH.
        _realignBandToReal();
        uint lpWethBefore = IERC20R(address(WETH)).balanceOf(LP);
        vm.prank(LP);
        alm.closeLev(0);

        assertLt(avenue.debtOf(LP), 1e6, "close: real Aave USDC debt fully repaid (<1 USDC dust)");
        assertLt(avenue.collateralOf(LP), 1e12, "close: real Aave WETH collateral fully withdrawn (dust only)");
        assertGt(IERC20R(address(WETH)).balanceOf(LP), lpWethBefore, "close: remaining WETH returned to the LP");
        assertEq(alm.grossCollateralEth(LP), 0, "close: position drops out of the band");
        (,,,,, bool stillOpen) = alm.pos(LP);
        assertTrue(!stillOpen, "close: position deleted");
    }
}
