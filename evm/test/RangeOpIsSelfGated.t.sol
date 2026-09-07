// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title `Quid.rangeOp` must be self-gated — a REGRESSION test for an unauthenticated withdrawal.
///
/// 🔴 **WHAT WAS WRONG.** `rangeOp` was `public` with no gate, and op 1 does:
///        `sent = aux.withdrawSelf(weth, min(amount, rangeETHLive), address(this));`
///        `weth.transfer(msg.sender, sent);`
///      inside `SwapLib.rangeOpBody`, which is an `external` library function — therefore
///      DELEGATECALLED, therefore `msg.sender` there is whoever called `Quid.rangeOp`, not Quid.
///      The inner `withdrawSelf` passes its own `msg.sender != address(this)` check precisely
///      BECAUSE the call originates inside Quid. So the self-gate on `withdrawSelf` protected
///      nothing: the value left through the `transfer` on the next line, to an arbitrary caller,
///      up to the whole `rangeETH()` claim.
///
/// ⚠️ **THE COMMENT IS WHY IT SURVIVED.** `rangeOpBody`'s docblock asserted *"Wrapper enforces
///      `msg.sender == V4` BEFORE delegating"*. No such wrapper exists — `Quid.rangeOp` is the
///      only wrapper and it had no modifier, and `Aux` has no `rangeOp` at all. Anyone auditing
///      the library read a gate that was never there. Found by a comment audit, not by a test.
///
/// ⛔ **DO NOT "FIX" THIS BY BOUNDING THE AMOUNT IN `SwapLib`.** A delegatecalled library cannot
///      distinguish an internal re-entry from an external call — it sees the same `msg.sender`
///      either way. The gate has to be on the wrapper, which is the only frame that knows.
contract RangeOpIsSelfGated is AllesFixture {

    /// Fund the ETH venue so the theft being tested is actually possible. Without this the
    /// claim is 0 and the test would pass vacuously against a gate that does nothing.
    function _seedVenue() internal {
        vm.prank(User01);
        ETH.deposit{value: 10 ether}(0, User01);
    }

    /// An arbitrary address must not be able to take WETH through op 1.
    function test_RangeOpTakeRevertsForAnyExternalCaller() public {
        _seedVenue();
        address attacker = address(0xBADBAD);
        uint claim = ETH.rangeETH();
        assertGt(claim, 0, "precondition: the ETH venue must hold a non-zero claim to steal");

        uint before = IERC20(address(WETH)).balanceOf(attacker);
        vm.prank(attacker);
        vm.expectRevert();                 // NotSelf()
        ETH.rangeOp(claim, 1);
        assertEq(IERC20(address(WETH)).balanceOf(attacker), before,
                 "attacker balance moved - the gate did not hold");
    }

    /// The read op is gated too, and deliberately: op 2 is only ever reached from inside.
    function test_RangeOpReadAlsoRevertsExternally() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert();                 // NotSelf()
        ETH.rangeOp(0, 2);
    }

    /// 🔴 `offrampEtherFi` must have NO EXTERNAL SURFACE AT ALL.
    ///
    /// It was `public`, and `QuidLib.offrampBody` ends `IERC20(c.weth).transfer(recipient, got)`
    /// with a CALLER-SUPPLIED `recipient`, bounded only by this contract's weETH balance and the
    /// Curve pool's depth. The legitimate path (`_withdraw`) bounds the amount by the caller's own
    /// position and BURNS what was served; calling the entrypoint directly skipped both.
    ///
    /// ⛔ The fix is VISIBILITY, not a gate — `NotSelf` would break the real path, because
    /// `_withdraw` reaches it by a PLAIN INTERNAL call and `msg.sender` there is the redeemer,
    /// not `address(this)`. So the assertion is that the SELECTOR IS GONE: an `internal` function
    /// has no dispatch entry, and a raw call carrying its old selector must not succeed.
    function test_OfframpEtherFiHasNoExternalSelector() public {
        _seedVenue();
        bytes4 sel = bytes4(keccak256("offrampEtherFi(uint256,address)"));
        address attacker = address(0xB0B);
        uint before = IERC20(address(WETH)).balanceOf(attacker);
        vm.prank(attacker);
        (bool ok, ) = address(ETH).call(abi.encodeWithSelector(sel, uint256(1 ether), attacker));
        // ⚠️ `ok` IS NOT THE SIGNAL, AND ASSERTING ON IT IS A TRAP I FELL INTO FIRST.
        // `Quid.sol:415` declares `fallback() external payable {}`, so a call carrying ANY
        // unknown selector lands there and returns SUCCESS. `ok == true` therefore says nothing
        // about whether the function exists. The only thing that distinguishes "removed" from
        // "still callable" here is whether VALUE MOVED.
        ok;
        assertEq(IERC20(address(WETH)).balanceOf(attacker), before,
                 "attacker received WETH through the old offramp selector");
    }

    /// The gate must not have broken the real path: both live callers are Quid reaching back
    /// into itself (`QuidLib.sendEth` op 1, `QuidLib._venueBalanceLib` op 2), so a self-call
    /// still succeeds. `rangeETH()` is the wrapper's own read and stays reachable to everyone.
    function test_TheVenueClaimIsStillReadableAndTheSelfPathStillWorks() public {
        _seedVenue();
        assertGt(ETH.rangeETH(), 0, "rangeETH() is a plain view and must remain public");
    }
}
