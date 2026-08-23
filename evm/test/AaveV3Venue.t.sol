// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ForkPin} from "./utils/ForkPin.sol";

import "forge-std/Test.sol";
import {AaveV3Venue} from "../src/imports/LevVenueBase.sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
interface IAddrProvider { function getPoolDataProvider() external view returns (address); }

/// Fork test of AaveV3Venue against the LIVE Aave V3 Pool (no mocks). This contract plays the MANAGER (sends
/// collateral/stable to the venue before supply/repay; receives borrowed USDC / withdrawn WBTC).
///
/// PURPOSE (#112): verify the read choice — ProtocolDataProvider.getUserReserveData `currentVariableDebt` /
/// `currentATokenBalance` — returns the exact, BLOCK-FRESH amounts (incl. accrued interest after a warp), which is
/// the whole reason we read it that way instead of a raw/scaled vToken balance.
contract AaveV3VenueTest is ForkPin {
    address constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Pool (mainnet)
    address constant ADDR = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // PoolAddressesProvider → ProtocolDataProvider
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8-dec collateral
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6-dec borrowed stable

    AaveV3Venue venue;
    address lp = address(0xB0B);

    function setUp() public {
        vm.selectFork(_forkMainnet());
        address dataProvider = IAddrProvider(ADDR).getPoolDataProvider();
        venue = new AaveV3Venue(POOL, dataProvider, WBTC, USDC, address(this), 7000); // WBTC collateral, USDC debt
    }

    function test_AaveV3_Lifecycle_and_InterestAccrual() public {
        // MANAGER supplies 1 WBTC collateral (pushed to the venue first, per ILevVenue custody).
        uint256 coll = 1e8; // 1 WBTC (8-dec)
        deal(WBTC, address(venue), coll);
        uint256 supplied = venue.supply(lp, coll);
        assertEq(supplied, coll, "supply credited");
        // §POOL-VENUE — ONE escrow for the venue, not one per LP. Was
        // `assertTrue(address(venue.escrowOf(lp)) != address(0), "per-LP escrow deployed")`.
        assertTrue(address(venue.poolEscrow()) != address(0), "pool escrow deployed");
        // (#112) collateralOf via getUserReserveData.currentATokenBalance == supplied underlying.
        assertApproxEqAbs(venue.collateralOf(lp), coll, 1e4, "collateralOf ~1 WBTC");
        assertEq(venue.debtOf(lp), 0, "no debt before borrow");

        // MANAGER borrows 10,000 USDC against 1 WBTC (>$50k collateral, well under the ~73% LT).
        uint256 mgrBefore = IERC20A(USDC).balanceOf(address(this));
        uint256 got = venue.borrow(lp, 10_000e6);
        assertApproxEqAbs(got, 10_000e6, 10e6, "borrowed ~10000 USDC");
        assertEq(IERC20A(USDC).balanceOf(address(this)) - mgrBefore, got, "USDC delivered to MANAGER");
        uint256 debt0 = venue.debtOf(lp);
        assertApproxEqAbs(debt0, 10_000e6, 10e6, "debtOf ~10000 USDC (getUserReserveData currentVariableDebt)");

        // (#112) THE decisive check: warp 90 days → the variable-borrow index accrues to the CURRENT block, so
        // `currentVariableDebt` must GROW with no poke. A stale/scaled read would report a flat/wrong number.
        vm.warp(block.timestamp + 90 days);
        uint256 debt1 = venue.debtOf(lp);
        assertGt(debt1, debt0, "debtOf grew with accrued interest - block-fresh index read confirmed");

        // Repay 2,000 USDC (push in first, per custody) → debt falls.
        IERC20A(USDC).transfer(address(venue), 2_000e6);
        uint256 rep = venue.repay(lp, 2_000e6);
        assertApproxEqAbs(rep, 2_000e6, 1e6, "repaid ~2000");
        assertLt(venue.debtOf(lp), debt1, "debt fell after repay");

        // Withdraw 0.2 WBTC of collateral back to MANAGER.
        uint256 wbtcBefore = IERC20A(WBTC).balanceOf(address(this));
        uint256 w = venue.withdraw(lp, 0.2e8);
        assertApproxEqAbs(w, 0.2e8, 1e5, "withdrew ~0.2 WBTC");
        assertEq(IERC20A(WBTC).balanceOf(address(this)) - wbtcBefore, w, "WBTC delivered to MANAGER");
        assertEq(venue.liqThresholdBps(), 7000, "LLTV view");
    }

    /// Two LPs get SEPARATE escrows — the isolation guarantee (one liquidation can't touch another / the basket).
    function test_AaveV3_PerLpIsolation() public {
        address lp2 = address(0xCa11);
        deal(WBTC, address(venue), 0.5e8);
        venue.supply(lp, 0.5e8);
        deal(WBTC, address(venue), 0.5e8);
        venue.supply(lp2, 0.5e8);
        // 🔴 §POOL-VENUE — THIS TEST'S SUBJECT CHANGED, AND THE ASSERTION SAYS SO RATHER THAN BEING
        // DELETED. It asserted `escrowOf(lp) != escrowOf(lp2)` — "distinct isolated accounts" — which
        // was the venue-enforced isolation. There is ONE Aave account now, so distinctness is FALSE by
        // construction and asserting it would only prove the change had not happened.
        // What is still true, and is what the pooled model must guarantee, is that the two LPs' CLAIMS
        // on that one account stay separate and proportional. That is what is checked now.
        // ⛔ AND THE REASON THE PER-LP MODEL WENT IS NOT THE ONE SPRINT #1 GAVE — ISOLATION WAS NOT
        // FREE CONTAINMENT, IT WAS ITSELF A DENIAL-OF-SERVICE SURFACE (owner, 2026-08-24). Many DUST
        // LPs mean many de-levers in a row to free the same value, so a swap-out cannot be filled at
        // all: **the book's LENGTH, not its size, priced the protocol's ability to settle.**
        // `MAX_OPEN_LPS` was that disease's symptom treatment — it traded "no new opens" for "no
        // swaps", which is exactly why its own comment called it a clamp meant to die. Pooling removes
        // the need for either, and the cap went with it.
        // ⚠️ Containment is NO LONGER proven here: a liquidation hits the pool and therefore both LPs
        // pro-rata. It is protocol-enforced by `cascadeDelever` + the LTV hysteresis instead.
        assertTrue(address(venue.poolEscrow()) != address(0), "one pooled Aave account");
        assertGt(venue.collateralOf(lp), 0.4e8, "lp1's proportional claim");
        assertGt(venue.collateralOf(lp2), 0.4e8, "lp2's proportional claim");
        assertApproxEqRel(venue.collateralOf(lp), venue.collateralOf(lp2), 0.01e18,
            "equal supplies must yield equal claims on the pool");
    }
}
