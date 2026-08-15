// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedRateFill} from "../src/imports/FixedRateFill.sol";
import {BatchLedger} from "../src/BatchLedger.sol";

/// @notice Exercises the settlement arithmetic and the batch lifecycle at their BOUNDARIES, which is
///         where this repo's defects have actually lived — a green suite over the interior is what an
///         unreached corner produces. No mocks: the ledger is the real contract, and the settler and
///         keeper are ordinary addresses because that is exactly what they are on-chain.
contract FillAndBatchTest is Test {
    BatchLedger ledger;
    address settler = address(0xA11CE);
    address keeper  = address(0xB0B);
    address alice   = address(0xA1);
    address bob     = address(0xB2);

    // 60/30/10 in range; OOR shifts weight OFF the swapper, because out of range the band's two
    // supplier legs have collapsed and the operation is re-enter-range rather than restore-1:1.
    FixedRateFill.Split IN_RANGE = FixedRateFill.Split(6000, 3000, 1000);
    FixedRateFill.Split OOR      = FixedRateFill.Split(2000, 5000, 3000);

    function setUp() public { ledger = new BatchLedger(settler, keeper); }

    // ─── splitCost ────────────────────────────────────────────────────────────

    /// THE PROPERTY THAT MATTERS: the parts sum to the whole, exactly, with no dust escaping.
    /// This is why basketShare is the remainder rather than a third mulDiv — three truncating
    /// divisions lose up to 2 wei, and a conservation check downstream would then fail on ROUNDING
    /// rather than on a real defect.
    function test_splitCost_partsSumToWhole_acrossAwkwardAmounts() public view {
        uint[7] memory amounts = [uint(0), 1, 2, 3, 9_999, 10_001, 1_234_567_891];
        for (uint i; i < amounts.length; i++) {
            (uint s, uint l, uint b) = FixedRateFill.splitCost(amounts[i], IN_RANGE, OOR, true);
            assertEq(s + l + b, amounts[i], "parts must sum to the whole exactly");
        }
    }

    /// The OOR selector must actually select. If this passes with identical weights it proves
    /// nothing, so the two Splits above are deliberately different.
    function test_splitCost_outOfRangeUsesDifferentWeights() public view {
        (uint sIn,,)  = FixedRateFill.splitCost(1_000_000, IN_RANGE, OOR, true);
        (uint sOut,,) = FixedRateFill.splitCost(1_000_000, IN_RANGE, OOR, false);
        assertEq(sIn,  600_000, "in-range swapper share");
        assertEq(sOut, 200_000, "OOR swapper share");
        assertTrue(sIn != sOut, "the inRange flag must change the answer");
    }

    function test_splitCost_rejectsWeightsThatDoNotSumToOne() public {
        FixedRateFill.Split memory bad = FixedRateFill.Split(6000, 3000, 999); // 9,999
        vm.expectRevert(FixedRateFill.WeightsMustSumToOne.selector);
        this.callSplit(1000, bad, OOR, true);
    }

    function callSplit(uint c, FixedRateFill.Split memory a, FixedRateFill.Split memory b, bool r)
        external pure returns (uint x, uint y, uint z) { return FixedRateFill.splitCost(c, a, b, r); }

    // ─── trueUpShare ──────────────────────────────────────────────────────────

    function test_trueUp_overEstimateRefunds_underEstimateOwes() public pure {
        // Realised 1000, I contributed half the skew ⇒ my share is 500.
        (uint owed, uint refund) = FixedRateFill.trueUpShare(1000, 50, 100, 800);
        assertEq(owed, 0);        assertEq(refund, 300, "overpaid 800 vs 500");
        (owed, refund) = FixedRateFill.trueUpShare(1000, 50, 100, 200);
        assertEq(owed, 300);      assertEq(refund, 0, "underpaid 200 vs 500");
    }

    /// A zero denominator means the batch attributed nothing. Returning (0,0) would silently absorb
    /// the whole realised cost into the fee lane — the socialisation this design exists to prevent —
    /// so it must REFUSE rather than look like it worked.
    function test_trueUp_refusesZeroDenominator() public {
        vm.expectRevert(FixedRateFill.NoQuote.selector);
        this.callTrueUp(1000, 0, 0, 0);
    }

    function callTrueUp(uint c, uint m, uint t, uint e) external pure returns (uint, uint) {
        return FixedRateFill.trueUpShare(c, m, t, e);
    }

    // ─── grindability: no FIXED weight is safe ────────────────────────────────

    /// The four data points from the grinding derivation, asserted exactly. w >= 1 - fee/C with
    /// fee = 420 ppm. If this drifts, the floor has stopped matching the arithmetic it encodes.
    function test_grindFloor_matchesTheDerivedBound() public {
        // C = 4.2bp: the fee alone covers the round trip, so ANY split is safe.
        // C == 0 has NO REFERENT and must REVERT, not pass -- see the docblock.
        vm.expectRevert(FixedRateFill.NoExternalCostToBound.selector);
        this.callGrind(0, 420, 0);
        // C = 4.2bp: the fee alone covers the round trip, so ANY split is safe.
        FixedRateFill.requireNonAbusable(0, 420, 420);
        // C = 5bp -> 16%, C = 10bp -> 58%, C = 26bp -> 83.85%
        FixedRateFill.requireNonAbusable(1600, 420, 500);
        FixedRateFill.requireNonAbusable(5800, 420, 1000);
        FixedRateFill.requireNonAbusable(8385, 420, 2600);
    }

    /// 🔴 THE POINT OF THE CHECK: a weight that is SAFE at one Curve fee is GRINDABLE at another,
    /// and TriCrypto's fee is dynamic across that range. 50% passes at 5bp and must fail at 10bp.
    function test_sameWeightSafeAtOneFeeAndGrindableAtAnother() public {
        FixedRateFill.requireNonAbusable(5000, 420, 500);      // 5bp: floor 16%, 50% clears it
        vm.expectRevert(FixedRateFill.SplitIsGrindable.selector);
        this.callGrind(5000, 420, 1000);                        // 10bp: floor 58%, 50% does NOT
    }

    function test_grindFloor_rejectsJustBelow() public {
        vm.expectRevert(FixedRateFill.SplitIsGrindable.selector);
        this.callGrind(5799, 420, 1000);                        // one bp under the 58% floor
    }

    function callGrind(uint16 w, uint f, uint c) external pure {
        FixedRateFill.requireNonAbusable(w, f, c);
    }

    // ─── the estimate floor ───────────────────────────────────────────────────

    /// The true-up is one-directional: refunds are payable, `owed` is not collectible from a
    /// departed swapper. So an under-estimate silently moves cost off the causer and onto the fee
    /// lane. A discount is therefore a broken invariant, not a configuration, and must REVERT rather
    /// than clamp — clamping would let a caller believe it configured a discount and hear nothing.
    function test_estimate_rejectsAnyDiscount() public {
        vm.expectRevert(FixedRateFill.UpliftBelowFloor.selector);
        this.callEstimate(1000, 9_999);
    }

    function test_estimate_parityIsTheFloor_andUpliftScales() public view {
        assertEq(FixedRateFill.estimateFrom(1000, 10_000), 1000, "parity is allowed");
        assertEq(FixedRateFill.estimateFrom(1000, 12_000), 1200, "120% uplift");
    }

    function callEstimate(uint c, uint16 b) external pure returns (uint) {
        return FixedRateFill.estimateFrom(c, b);
    }

    // ─── BatchLedger lifecycle ────────────────────────────────────────────────

    function _record(address who, uint skew, uint est) internal {
        vm.prank(settler);
        ledger.record(who, skew, est);
    }

    function test_record_accumulatesPerAddress_soNobodyClaimsTwice() public {
        _record(alice, 30, 300);
        _record(alice, 20, 200);
        (uint128 skew, uint128 est) = ledger.entryOf(0, alice);
        assertEq(skew, 50, "two swaps, one entry");
        assertEq(est, 500);
    }

    function test_record_onlySettler() public {
        vm.expectRevert(BatchLedger.NotSettler.selector);
        ledger.record(alice, 1, 1);
    }

    function test_claim_creditsRefund_andSecondClaimReverts() public {
        _record(alice, 50, 800);
        _record(bob,   50, 800);
        vm.prank(keeper);
        ledger.close(1000, IN_RANGE, OOR, true);   // swapperPot = 600, alice's share = 300

        ledger.claim(0, alice);
        assertEq(ledger.claimable(alice), 500, "800 charged, 300 owed, so 500 back");

        vm.expectRevert(BatchLedger.AlreadyClaimed.selector);
        ledger.claim(0, alice);
    }

    function test_claim_beforeCloseReverts() public {
        _record(alice, 1, 1);
        vm.expectRevert(BatchLedger.BatchOpen.selector);
        ledger.claim(0, alice);
    }

    function test_close_rejectsEmptyBatch_andNonKeeper() public {
        vm.prank(keeper);
        vm.expectRevert(BatchLedger.NothingRecorded.selector);
        ledger.close(1000, IN_RANGE, OOR, true);

        _record(alice, 1, 1);
        vm.expectRevert(BatchLedger.NotKeeper.selector);
        ledger.close(1000, IN_RANGE, OOR, true);
    }

    function test_close_advancesBatchId() public {
        _record(alice, 1, 1);
        assertEq(ledger.currentBatch(), 0);
        vm.prank(keeper);
        ledger.close(100, IN_RANGE, OOR, true);
        assertEq(ledger.currentBatch(), 1, "next swap must land in a fresh batch");
    }

    // ─── the anti-stranding path ──────────────────────────────────────────────

    /// 🔴 THE TEST THAT JUSTIFIES THE DEADLINE. Without forceRefund a batch that never rebalances
    /// leaves participants owed a true-up that never arrives, and their estimate becomes a SILENT
    /// over-collection: no revert, no event, just money that stopped being theirs.
    function test_forceRefund_afterTimeout_isPermissionlessAndReturnsEverything() public {
        _record(alice, 50, 800);
        vm.warp(block.timestamp + 7 days);
        ledger.forceRefund(0);                       // no prank: ANYONE may call it
        ledger.claim(0, alice);
        assertEq(ledger.claimable(alice), 800, "full estimate back when nothing was attributable");
    }

    function test_forceRefund_beforeTimeoutReverts() public {
        _record(alice, 1, 1);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(BatchLedger.NotStrandedYet.selector);
        ledger.forceRefund(0);
    }

    function test_forceRefund_cannotReopenASettledBatch() public {
        _record(alice, 1, 1);
        vm.prank(keeper);
        ledger.close(100, IN_RANGE, OOR, true);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(BatchLedger.BatchClosed.selector);
        ledger.forceRefund(0);
    }
}
