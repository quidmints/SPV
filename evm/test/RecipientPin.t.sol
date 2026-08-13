// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Alles} from "./Alles.t.sol";
import {Vogue} from "../src/Vogue.sol";

/// @notice §A.5f (subset) — the TIMELOCKED withdrawal-recipient pin.
///
///         THREAT MODELLED HERE: the hosted fleet keeper HOLDS THE LP KEY (`BtcLevManager:361`), and
///         `withdraw`/`redeem` leave `receiver` arbitrary, so a compromised keeper can pay an LP's
///         funds to itself. Nothing off-chain constrains this — the Rust `Scope` layer is coarse
///         API-client auth with no notion of EVM actions.
///
///         THE POINT OF THE DELAY, AND WHAT THIS FILE EXISTS TO PROVE: a pin that the LP key can SET,
///         the LP key can also UNSET. An earlier proposal in this queue was exactly that, and it
///         closed nothing — an attacker holding the key would simply re-point and withdraw in the
///         same transaction. `test_StolenKey_CannotRepointAndDrainImmediately` is the test that would
///         fail against that naive design, so it is the one that must never be weakened.
contract RecipientPin is Alles {

    address constant ATTACKER = address(0xBAD);

    function _seed(address lp) internal {
        vm.prank(lp);
        V4.deposit{value: 10 ether}(0, lp);          // VENUE_GALAXY
        // Vogue:538 bars a withdraw in the SAME BLOCK as a deposit ("too soon"). Clear it, or every
        // `expectRevert` below would catch the COOLDOWN instead of the pin and pass vacuously —
        // which is exactly what happened on the first run of this file.
        vm.roll(block.number + 1);
    }

    /// UNPINNED IS UNRESTRICTED — the feature is additive, so every existing LP is untouched.
    function test_Unpinned_ArbitraryRecipientStillAllowed() public {
        _seed(User01);
        assertEq(V4.pinnedRecipient(User01), address(0), "default must be unpinned");
        // ETH+WETH. The Curve offramp settles the band's exit in WETH, not native ETH, so a guard
        // that counts only `.balance` reads a real payment as ZERO -- the delivery happened, the
        // measurement missed it. Count both legs, as `Alles.t_EthLp_RedeemConservationAndFairness`
        // already does; asserting on the recipient's TOTAL is what the pin property is actually about.
        uint before = User02.balance + WETH.balanceOf(User02);
        vm.prank(User01);
        V4.withdraw(1 ether, User02, User01);           // pays a third party, as before
        assertGt(User02.balance + WETH.balanceOf(User02), before, "unpinned LP can still pay an arbitrary receiver");
    }

    /// PINNED — payments to anywhere else revert; payments to the pin succeed.
    function test_Pinned_OnlyThePinCanBePaid() public {
        _seed(User01);
        vm.prank(User01); V4.pinRecipient(User01);       // first pin is immediate (opt-in must be easy)
        assertEq(V4.pinnedRecipient(User01), User01, "first pin applies at once");

        vm.prank(User01);
        vm.expectRevert(Vogue.RecipientNotPinned.selector); V4.withdraw(1 ether, ATTACKER, User01);

        // ETH+WETH. The Curve offramp settles the band's exit in WETH, not native ETH, so a guard
        // that counts only `.balance` reads a real payment as ZERO -- the delivery happened, the
        // measurement missed it. Count both legs, as `Alles.t_EthLp_RedeemConservationAndFairness`
        // already does; asserting on the recipient's TOTAL is what the pin property is actually about.
        uint before = User01.balance + WETH.balanceOf(User01);
        vm.prank(User01); V4.withdraw(1 ether, User01, User01);
        assertGt(User01.balance + WETH.balanceOf(User01), before, "the pinned recipient is still payable");
    }

    /// THE LOAD-BEARING TEST. A stolen key cannot re-point and drain in one go — it can only REQUEST
    /// a change, which is the window in which the real LP can notice and exit. A naive
    /// set-and-use pin passes every other test in this file and fails THIS one.
    function test_StolenKey_CannotRepointAndDrainImmediately() public {
        _seed(User01);
        vm.prank(User01); V4.pinRecipient(User01);

        // The attacker holds the key, so every call below is legitimately authorised.
        vm.prank(User01); V4.pinRecipient(ATTACKER);     // re-point is a REQUEST, not a change
        assertEq(V4.pinnedRecipient(User01), User01, "re-point must NOT take effect immediately");

        vm.prank(User01);
        vm.expectRevert(Vogue.RecipientTimelocked.selector); V4.applyPinnedRecipient();     // still inside the window

        vm.prank(User01);
        vm.expectRevert(Vogue.RecipientNotPinned.selector); V4.withdraw(1 ether, ATTACKER, User01);   // and the drain is still barred
    }

    /// The delay must actually EXPIRE — a lock that never opens would be a brick, not a guard.
    function test_Repoint_AppliesOnceTheWindowElapses() public {
        _seed(User01);
        vm.prank(User01); V4.pinRecipient(User01);
        vm.prank(User01); V4.pinRecipient(User02);

        vm.warp(block.timestamp + V4.RECIPIENT_TIMELOCK() + 1);
        vm.prank(User01); V4.applyPinnedRecipient();
        assertEq(V4.pinnedRecipient(User01), User02, "re-point applies after the window");

        // ETH+WETH. The Curve offramp settles the band's exit in WETH, not native ETH, so a guard
        // that counts only `.balance` reads a real payment as ZERO -- the delivery happened, the
        // measurement missed it. Count both legs, as `Alles.t_EthLp_RedeemConservationAndFairness`
        // already does; asserting on the recipient's TOTAL is what the pin property is actually about.
        uint before = User02.balance + WETH.balanceOf(User02);
        vm.prank(User01); V4.withdraw(1 ether, User02, User01);
        assertGt(User02.balance + WETH.balanceOf(User02), before, "the new pin is payable");
    }
}
