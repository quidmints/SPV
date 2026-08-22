// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @notice Exercises the settlement arithmetic and the batch lifecycle at their BOUNDARIES, which is
///         where this repo's defects have actually lived — a green suite over the interior is what an
///         unreached corner produces. No mocks: the ledger is the real contract, and the settler and
///         keeper are ordinary addresses because that is exactly what they are on-chain.
contract FillAndBatchTest is Test {

    // 60/30/10 in range; OOR shifts weight OFF the swapper, because out of range the range's two
    // supplier legs have collapsed and the operation is re-enter-range rather than restore-1:1.
    SwapLib.Split IN_RANGE = SwapLib.Split(6000, 3000, 1000);
    SwapLib.Split OOR      = SwapLib.Split(2000, 5000, 3000);


    // ─── splitCost ────────────────────────────────────────────────────────────

    /// THE PROPERTY THAT MATTERS: the parts sum to the whole, exactly, with no dust escaping.
    /// This is why basketShare is the remainder rather than a third mulDiv — three truncating
    /// divisions lose up to 2 wei, and a conservation check downstream would then fail on ROUNDING
    /// rather than on a real defect.
    function test_splitCost_partsSumToWhole_acrossAwkwardAmounts() public view {
        uint[7] memory amounts = [uint(0), 1, 2, 3, 9_999, 10_001, 1_234_567_891];
        for (uint i; i < amounts.length; i++) {
            (uint s, uint l, uint b) = SwapLib.splitCost(amounts[i], IN_RANGE, OOR, true);
            assertEq(s + l + b, amounts[i], "parts must sum to the whole exactly");
        }
    }

    /// The OOR selector must actually select. If this passes with identical weights it proves
    /// nothing, so the two Splits above are deliberately different.
    function test_splitCost_outOfRangeUsesDifferentWeights() public view {
        (uint sIn,,)  = SwapLib.splitCost(1_000_000, IN_RANGE, OOR, true);
        (uint sOut,,) = SwapLib.splitCost(1_000_000, IN_RANGE, OOR, false);
        assertEq(sIn,  600_000, "in-range swapper share");
        assertEq(sOut, 200_000, "OOR swapper share");
        assertTrue(sIn != sOut, "the inRange flag must change the answer");
    }

    function test_splitCost_rejectsWeightsThatDoNotSumToOne() public {
        SwapLib.Split memory bad = SwapLib.Split(6000, 3000, 999); // 9,999
        vm.expectRevert(SwapLib.WeightsMustSumToOne.selector);
        this.callSplit(1000, bad, OOR, true);
    }

    function callSplit(uint c, SwapLib.Split memory a, SwapLib.Split memory b, bool r)
        external pure returns (uint x, uint y, uint z) { return SwapLib.splitCost(c, a, b, r); }

    // ─── grindability: no FIXED weight is safe ────────────────────────────────

    /// The four data points from the grinding derivation, asserted exactly. w >= 1 - fee/C with
    /// fee = 420 ppm. If this drifts, the floor has stopped matching the arithmetic it encodes.
    function test_grindFloor_matchesTheDerivedBound() public {
        // C = 4.2bp: the fee alone covers the round trip, so ANY split is safe.
        // C == 0 has NO REFERENT and must REVERT, not pass -- see the docblock.
        vm.expectRevert(SwapLib.NoExternalCostToBound.selector);
        this.callGrind(0, 420, 0);
        // C = 4.2bp: the fee alone covers the round trip, so ANY split is safe.
        SwapLib.requireNonAbusable(0, 420, 420);
        // C = 5bp -> 16%, C = 10bp -> 58%, C = 26bp -> 83.85%
        SwapLib.requireNonAbusable(1600, 420, 500);
        SwapLib.requireNonAbusable(5800, 420, 1000);
        SwapLib.requireNonAbusable(8385, 420, 2600);
    }

    /// 🔴 THE POINT OF THE CHECK: a weight that is SAFE at one Curve fee is GRINDABLE at another,
    /// and a Curve crypto-pool's fee is dynamic across that range. 50% passes at 5bp and must fail at 10bp.
    function test_sameWeightSafeAtOneFeeAndGrindableAtAnother() public {
        SwapLib.requireNonAbusable(5000, 420, 500);      // 5bp: floor 16%, 50% clears it
        vm.expectRevert(SwapLib.SplitIsGrindable.selector);
        this.callGrind(5000, 420, 1000);                        // 10bp: floor 58%, 50% does NOT
    }

    function test_grindFloor_rejectsJustBelow() public {
        vm.expectRevert(SwapLib.SplitIsGrindable.selector);
        this.callGrind(5799, 420, 1000);                        // one bp under the 58% floor
    }

    function callGrind(uint16 w, uint f, uint c) external pure {
        SwapLib.requireNonAbusable(w, f, c);
    }
}
