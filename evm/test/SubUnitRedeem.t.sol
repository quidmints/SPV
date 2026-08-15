// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Alles} from "./Alles.t.sol";
import {BasketLib} from "../src/imports/BasketLib.sol";

/// @notice §E191. A DUST REDEEM MUST SAY IT IS DUST, NOT CLAIM EVERY VENUE FAILED.
///
///         The pro-rata allocation is 18-dec and the withdraw is native, so a draw below one native
///         unit of a leg (1e12 wei for a 6-dec stable) truncates to ZERO on every leg and `sent` comes
///         back 0. That tripped `NothingDelivered`, whose documented meaning is that every venue
///         failed — so a sub-unit request read as a venue outage.
///
///         This was found the hard way: it only became reachable once §E155's over-issuance was fixed.
///         Before that, supply exceeded backing, `perShare` sat below par, a 1-wei burn rounded to zero
///         BEFORE reaching delivery, and the dust path was a silent no-op whose assertion passed
///         vacuously. Two defects were cancelling.
contract SubUnitRedeem is Alles {
    function test_dustRedeemRevertsAsTooSmall_notAsAVenueOutage() public {
        deal(address(USDC), User01, 50_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), 50_000 * USDC_PRECISION);
        QUID.mint(User01, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 35 days);

        // NON-VACUITY: the holder must actually hold mature QU!D, or the revert proves nothing.
        assertGt(QUID.balanceOf(User01), 0, "precondition: holder must have QUID to burn");

        vm.prank(User01);
        vm.expectRevert(BasketLib.AmountTooSmall.selector);
        AUX.redeem(1);            // 1 wei: below one native unit of every leg
    }

    /// The distinction has to hold in the other direction too, or it is just a renamed error.
    function test_aNormalRedeemStillDelivers() public {
        deal(address(USDC), User01, 50_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), 50_000 * USDC_PRECISION);
        QUID.mint(User01, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 35 days);

        uint pre = USDC.balanceOf(User01);
        vm.prank(User01);
        AUX.redeem(1_000e18);
        assertGt(USDC.balanceOf(User01), pre, "a normal redeem must still deliver");
    }
}
