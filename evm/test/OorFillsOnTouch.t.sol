// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {RangeLib} from "../src/imports/RangeLib.sol";
import {SortedSetLib} from "../src/imports/Types.sol";

/// @notice Exercises `SortedSetLib` on its own, as the CONTROL for the key-packing decision.
///         Not a mock of anything: it is the real library, called directly, which is the only way
///         to show what the rejected design would have done.
contract RawSortedSet {
    SortedSetLib.Set internal set;

    function insert(uint v) external { SortedSetLib.insert(set, v); }
    function count() external view returns (uint) { return SortedSetLib.getSortedSet(set).length; }
}

/// @title §E258 — A BOUNDARY ORDER IS A LIMIT ORDER AGAIN, NOT AN OPTION
///
/// @notice **THIS FILE EXISTS BECAUSE THE DEFECT IT COVERS HAD NO BROKEN SYMBOL.** The v4 cut
///         removed the PoolManager, and with it the tick crossing that filled a resting boundary
///         order as part of any swap through its range. `outOfRange` still compiled, still stored,
///         still tested green — what vanished was a BEHAVIOUR supplied by a deleted dependency, and
///         no tool in the repo looks for one of those. The order stopped being a limit order and
///         became an option its owner had to exercise, which is the variant that was rejected in
///         writing when the design was chosen.
///
/// ⚠️ **WHAT THIS FILE DOES NOT PROVE, STATED HERE RATHER THAN LEFT TO BE DISCOVERED.** It does not
///    execute a fill across a real crossing. A crossing needs the range's ORACLE price to move, and
///    on a pinned mainnet fork it cannot: `getTWAPforAsset` is the observation ring anchored to
///    Chainlink, and neither budges for `vm.roll` or `vm.warp`. Moving it would mean mocking the
///    oracle, which would prove the test can lie to itself and nothing else. So what is asserted
///    below is everything reachable WITHOUT that: the index property the whole design rests on, the
///    guard that decides when an order is fillable, and the absence of the 47-block rule on the
///    fill path. **The end-to-end crossing is booked as §E258-CROSSING-TEST and is not closed.**
contract OorFillsOnTouchTest is AllesFixture {

    /// 🔑 **THE TRAP THE SPEC WAS WRITTEN AROUND, AND IT IS SILENT.** `SortedSetLib.insert` opens
    ///    with `if (self.exists[value]) return;` — it DISCARDS a duplicate and reports nothing. Had
    ///    the index been keyed on the bare trigger price, two orders resting at the same price would
    ///    have collapsed into one entry: the second would never be found by a sweep, never fill, and
    ///    its funds would sit unreachable with no revert anywhere to say so.
    ///    This is the CONTROL for that claim — the real library, two equal values, one survivor.
    function test_TheRawSetSilentlyDropsADuplicate_whichIsWhyTheKeyIsPacked() public {
        RawSortedSet raw = new RawSortedSet();
        raw.insert(1895e18);
        raw.insert(1895e18);
        assertEq(raw.count(), 1,
            "premise: the set ignores duplicates; if this is 2, the packed key is no longer needed");

        // The packed key is what breaks the tie: same price, different id, two distinct entries.
        assertTrue(RangeLib.oorKey(1895e18, 1) != RangeLib.oorKey(1895e18, 2),
            "two orders at one price must produce two keys");
    }

    /// The packing must also PRESERVE PRICE ORDER, or a sorted set sorted by the wrong thing is
    /// worse than no index — `binarySearch` would return a range that is not the crossed range.
    function test_ThePackedKeySortsByPriceFirst() public pure {
        // A higher price outranks a lower one no matter how the ids compare.
        assertTrue(RangeLib.oorKey(2000e18, 0) > RangeLib.oorKey(1999e18, type(uint96).max),
            "price must dominate the ordering; if id can outweigh it the sweep range is wrong");
        // And within one price, the ids simply separate.
        assertTrue(RangeLib.oorKey(2000e18, 5) > RangeLib.oorKey(2000e18, 4), "id breaks the tie");
    }

    /// A FRESH ORDER IS NOT FILLABLE, and the poke says so instead of filling it. `oorBounds`
    /// requires a new order to rest wholly OUTSIDE the active range, so at the moment of placement
    /// the price has by construction not touched it. If this ever starts filling, the order's
    /// bounds and the price the poke reads have drifted onto different bases — which would hand
    /// every placer an instant fill at their own limit.
    function test_AFreshOrderIsNotTouched_soThePokeRefusesIt() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = ETH.outOfRange(rack / 10, address(USDC), 1000, 100);
        vm.stopPrank();

        (,, bool usdFunded,,, int amt) = ETH.selfManaged(id);
        assertTrue(usdFunded, "a stable-funded order is a resting BID and must record itself as one");
        assertGt(amt, 0, "premise: the order exists");

        vm.expectRevert(RangeLib.NotTouched.selector);
        ETH.fillOOR(id);
    }

    /// THE POKE IS PERMISSIONLESS BY DESIGN — anyone may call it, because the order settles at its
    /// OWN limit price, so a caller chooses the timing and never the terms. What it must not do is
    /// pay out an order that does not exist.
    function test_ThePokeRejectsAnOrderThatIsNotThere() public {
        vm.prank(User02);
        vm.expectRevert(RangeLib.NoSuchOrder.selector);
        ETH.fillOOR(999_999);
    }

    /// ⚠️ **`pull`'s 47-BLOCK GUARD MUST NOT REACH THE FILL PATH.** That rule is an anti-gaming
    ///    bound on an owner-initiated CLOSE; an execution is not a withdrawal. If it gated a fill,
    ///    every order would be unfillable for its first 47 blocks — reinstating precisely the "no
    ///    execution guarantee at the moment of crossing" defect §E258 exists to remove. The
    ///    discriminator: in the SAME block, `pull` refuses on the guard and the poke gets past it to
    ///    a decision about PRICE.
    function test_TheFillPathIsNotGatedByPullsFortySevenBlockRule() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = ETH.outOfRange(rack / 10, address(USDC), 1000, 100);

        // Same block as creation: the owner's close is refused by the age rule ...
        vm.expectRevert(bytes("too soon"));
        ETH.pull(id, 100, address(USDC));
        vm.stopPrank();

        // ... while the fill path has already moved past age and is deciding on price. `NotTouched`
        // — not "too soon" — IS the assertion: it proves the age rule is not in this path at all.
        vm.expectRevert(RangeLib.NotTouched.selector);
        ETH.fillOOR(id);
    }

    /// A FULL PULL MUST ALSO LEAVE THE INDEX. Otherwise the sorted set outlives the position it
    /// describes, and the book and the index become two structures that can disagree — the exact
    /// shape the spec forbade when it ruled out a parallel `mapping(price => id[])`. Observable
    /// here as: after the pull, the poke reports the order GONE rather than merely untouched.
    function test_AFullPullLeavesNoGhostInTheIndex() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = ETH.outOfRange(rack / 10, address(USDC), 1000, 100);
        vm.roll(vm.getBlockNumber() + 1000);
        ETH.pull(id, 100, address(USDC));
        vm.stopPrank();

        (,,,,, int amt) = ETH.selfManaged(id);
        assertEq(amt, 0, "premise: the position is closed");
        vm.expectRevert(RangeLib.NoSuchOrder.selector);
        ETH.fillOOR(id);
    }

    /// TWO ORDERS AT ONE TRIGGER PRICE BOTH SURVIVE PLACEMENT — the end-to-end form of the first
    /// test. Identical geometry (same distance, same range, same block) yields the same bounds and
    /// therefore the same trigger, which is precisely the case a bare-price key would have lost.
    function test_TwoOrdersAtTheSameTriggerBothRemainReal() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack * 2);
        uint a = ETH.outOfRange(rack / 10, address(USDC), 1000, 100);
        uint b = ETH.outOfRange(rack / 10, address(USDC), 1000, 100);
        vm.stopPrank();

        assertTrue(a != b, "two placements must be two positions");
        (,,, uint loA, uint upA, int amtA) = ETH.selfManaged(a);
        (,,, uint loB, uint upB, int amtB) = ETH.selfManaged(b);
        assertEq(upA, upB, "premise: identical geometry gives one shared trigger price");
        assertEq(loA, loB, "premise: identical geometry gives identical bounds");
        assertGt(amtA, 0, "the first order is live");
        assertGt(amtB, 0, "the SECOND order is live: the one a bare-price key would strand");

        // And both are still individually addressable through the fill path.
        vm.expectRevert(RangeLib.NotTouched.selector);
        ETH.fillOOR(a);
        vm.expectRevert(RangeLib.NotTouched.selector);
        ETH.fillOOR(b);
    }
}
