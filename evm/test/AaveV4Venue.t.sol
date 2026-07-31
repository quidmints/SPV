// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ForkPin} from "./utils/ForkPin.sol";

import "forge-std/Test.sol";
import {AaveV4Venue} from "../src/AaveV4Venue.sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Fork test of AaveV4Venue against the LIVE Aave V4 Hub/Spoke (no mocks). This contract plays the MANAGER
/// (sends collateral/stable to the venue before supply/repay; receives borrowed USDC / withdrawn WETH).
contract AaveV4VenueTest is ForkPin {
    // Live Aave V4 (same Hub/Spoke the basket's supply-side EthVenue/Aux already use).
    address constant SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address constant HUB   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    AaveV4Venue venue;
    address lp = address(0xB0B);

    function setUp() public {
        vm.selectFork(_forkMainnet());
        venue = new AaveV4Venue(SPOKE, HUB, WETH, USDC, address(this), 8000); // WETH collateral, USDC debt
    }

    function test_AaveV4_FullLifecycle() public {
        // MANAGER supplies 5 WETH collateral (pushed to the venue first, per ILevVenue custody).
        uint256 coll = 5 ether;
        deal(WETH, address(venue), coll);
        uint256 supplied = venue.supply(lp, coll);
        assertEq(supplied, coll, "supply credited");
        address escrow = address(venue.escrowOf(lp));
        assertTrue(escrow != address(0), "per-LP escrow deployed");
        assertGt(venue.collateralOf(lp), 4.9 ether, "escrow holds ~5 WETH collateral (isolated)");
        assertEq(venue.debtOf(lp), 0, "no debt before borrow");

        // MANAGER borrows 5,000 USDC against the WETH (well under the ~82% LT on ~$15k collateral).
        uint256 mgrBefore = IERC20A(USDC).balanceOf(address(this));
        uint256 got = venue.borrow(lp, 5_000e6);
        assertApproxEqAbs(got, 5_000e6, 5e6, "borrowed ~5000 USDC");
        assertEq(IERC20A(USDC).balanceOf(address(this)) - mgrBefore, got, "USDC delivered to MANAGER");
        assertApproxEqAbs(venue.debtOf(lp), 5_000e6, 5e6, "debt ~5000 USDC");

        // Repay 1,000 USDC (push it in first, per custody).
        uint256 debtBefore = venue.debtOf(lp);
        IERC20A(USDC).transfer(address(venue), 1_000e6);
        uint256 rep = venue.repay(lp, 1_000e6);
        assertApproxEqAbs(rep, 1_000e6, 1e6, "repaid ~1000");
        assertLt(venue.debtOf(lp), debtBefore, "debt fell after repay");

        // Withdraw 1 WETH of collateral back to MANAGER.
        uint256 wethBefore = IERC20A(WETH).balanceOf(address(this));
        uint256 w = venue.withdraw(lp, 1 ether);
        assertApproxEqAbs(w, 1 ether, 1e15, "withdrew ~1 WETH");
        assertEq(IERC20A(WETH).balanceOf(address(this)) - wethBefore, w, "WETH delivered to MANAGER");

        assertEq(venue.liqThresholdBps(), 8000, "LLTV view");
    }

    /// Two LPs get SEPARATE escrows — the core isolation guarantee.
    function test_AaveV4_PerLpIsolation() public {
        address lp2 = address(0xCa11);
        deal(WETH, address(venue), 2 ether);
        venue.supply(lp, 1 ether);
        deal(WETH, address(venue), 2 ether);
        venue.supply(lp2, 1 ether);
        assertTrue(address(venue.escrowOf(lp)) != address(venue.escrowOf(lp2)), "distinct isolated accounts");
        assertGt(venue.collateralOf(lp), 0.9 ether, "lp1 isolated collateral");
        assertGt(venue.collateralOf(lp2), 0.9 ether, "lp2 isolated collateral");
    }
}
