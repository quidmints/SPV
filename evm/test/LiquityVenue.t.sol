// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ForkPin} from "./utils/ForkPin.sol";

import "forge-std/Test.sol";
import {LiquityTroveVenue} from "../src/LiquityTroveVenue.sol";

interface IERC20L {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ITMRate { // read a trove's live annual interest rate (field 6 of LatestTroveData)
    function getLatestTroveData(uint256) external view returns (
        uint256,uint256,uint256,uint256,uint256,uint256,uint256 annualInterestRate,uint256,uint256,uint256);
}

/// Fork test of LiquityTroveVenue against the LIVE Liquity V2 WETH branch (no mocks). This test contract
/// plays the MANAGER (pushes coll/BOLD in before supply/repay, receives borrowed BOLD / withdrawn coll).
contract LiquityVenueTest is ForkPin {
    // Live Liquity V2 WETH branch (verified on mainnet via cast).
    address constant BO   = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65; // BorrowerOperations
    address constant TM   = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A; // TroveManager
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    LiquityTroveVenue venue;
    address lp = address(0xB0B);

    function setUp() public {
        vm.selectFork(_forkMainnet());
        venue = new LiquityTroveVenue(BO, TM, BOLD, WETH, address(this), 0.05e18, 2000e18);
    }

    function test_Liquity_FullLifecycle() public {
        // MANAGER supplies 5 WETH of collateral (pushed to the venue first, per ILevVenue custody).
        uint256 coll = 5 ether;
        deal(WETH, address(venue), coll + 0.1 ether);           // + buffer for any WETH gas-comp pull
        uint256 supplied = venue.supply(lp, coll);
        assertEq(supplied, coll, "supply credited");
        assertGt(venue.collateralOf(lp), 4 ether, "trove opened with ~5 WETH collateral");
        uint256 pend = venue.pendingBold(lp);
        assertGt(pend, 1900e18, "floor BOLD (~2000) drawn + held pending");
        // The deliverable floor (2000) is netted out; the only residual debt is V2's one-time upfront fee
        // (~1 BOLD) folded into trove debt but delivered to no one — a real liability from the moment of open.
        assertLt(venue.debtOf(lp), 2e18, "no DELIVERED principal yet, only the ~1 BOLD upfront fee remains");

        // MANAGER borrows 1000 BOLD — served from the held floor draw first.
        uint256 mgrBoldBefore = IERC20L(BOLD).balanceOf(address(this));
        uint256 got = venue.borrow(lp, 1000e18);
        assertApproxEqAbs(got, 1000e18, 1e18, "borrowed ~1000 BOLD");
        assertEq(IERC20L(BOLD).balanceOf(address(this)) - mgrBoldBefore, got, "BOLD delivered to MANAGER");
        assertApproxEqAbs(venue.debtOf(lp), 1000e18, 5e18, "delivered debt ~1000");

        // Borrow MORE than remains pending → forces a withdrawBold from the trove.
        got = venue.borrow(lp, 3000e18);
        assertGt(got, 0, "second borrow drew from the trove");
        assertGt(venue.debtOf(lp), 3000e18, "debt grew past the floor");

        // Repay 1000 BOLD (push it in first, per custody).
        uint256 debtBefore = venue.debtOf(lp);
        IERC20L(BOLD).transfer(address(venue), 1000e18);
        uint256 rep = venue.repay(lp, 1000e18);
        assertApproxEqAbs(rep, 1000e18, 1e18, "repaid ~1000");
        assertLt(venue.debtOf(lp), debtBefore, "debt fell after repay");

        // Withdraw 1 WETH of collateral back to the MANAGER.
        uint256 wethBefore = IERC20L(WETH).balanceOf(address(this));
        uint256 w = venue.withdraw(lp, 1 ether);
        assertApproxEqAbs(w, 1 ether, 1, "withdrew ~1 WETH");
        assertEq(IERC20L(WETH).balanceOf(address(this)) - wethBefore, w, "WETH delivered to MANAGER");

        // Views sane + LLTV from live MCR (110% MCR -> ~9090 bps).
        assertApproxEqAbs(venue.liqThresholdBps(), 9090, 5, "LLTV = 10000*1e18/MCR");
    }

    /// The BORROWER's chosen rate reaches the trove (not the venue default), and re-pricing an open trove works.
    function test_Liquity_BorrowerSetsRate() public {
        // LP picks 12% instead of the 5% default, BEFORE opening.
        vm.prank(lp);
        venue.setInterestRate(0.12e18);
        assertEq(venue.rateOf(lp), 0.12e18, "borrower rate recorded");

        deal(WETH, address(venue), 5 ether + 0.1 ether);
        venue.supply(lp, 5 ether);                        // MANAGER opens the trove
        uint256 id = venue.troveIdOf(lp);
        (,,,,,,uint256 rate,,,) = ITMRate(TM).getLatestTroveData(id);
        assertApproxEqAbs(rate, 0.12e18, 1e12, "trove opened at the borrower's 12% rate, not the 5% default");

        // Re-price the OPEN trove to 3% (owner-only adjust via the adapter).
        vm.prank(lp);
        venue.setInterestRate(0.03e18);
        (,,,,,,rate,,,) = ITMRate(TM).getLatestTroveData(id);
        assertApproxEqAbs(rate, 0.03e18, 1e12, "open trove re-priced to 3%");

        // Out-of-range input clamps into [0.5%, 250%] instead of reverting the call.
        vm.prank(lp);
        venue.setInterestRate(0);                          // below MIN
        assertEq(venue.rateOf(lp), 5e15, "clamped up to MIN_RATE 0.5%");
    }
}
