// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §SKEW-SHAPE — **PROPERTIES OF `skewWad`, NOT A CALIBRATION OF IT**
///
/// @notice ⛔ **THIS FILE DELIBERATELY PINS NO MAGIC NUMBERS, AND THE FIRST DRAFT DID.** It asserted
///         `assertEq(skew, 4_495_165_581_956)` — a value read off one fixture at one fork block.
///         That is blind calibration: it breaks whenever the fork moves, it says nothing about
///         whether the formula is *right*, and it invites tuning the constant until green. Worse, it
///         made a **32x step** look like a cliff in the function when it was only two samples taken
///         far apart on a steep-but-continuous curve.
///
///         ⭐ **WHAT IS WORTH ASSERTING IS THAT ONE FORMULA FITS EVERY SIZE.** `skewWad` is
///         `public pure`, so each property below is a closed-form question — no fork, no fixture, no
///         seeded variance, no two arms.
contract SkewFlowDiscriminationTest is Test {
    uint constant SIG = 427_400_686_005_550_189;   // any positive sigma^2; results below are ratios

    function _s(uint inv, uint flow, uint drain) internal pure returns (uint) {
        return SwapLib.skewWad(inv, flow, SIG, SwapLib.ethRisk(), drain);
    }

    /// ⭐ **(1) SCALE INVARIANCE — THE "ANY-SIZE-FITS-ALL" PROPERTY.** Multiply inventory, target and
    ///     drain by the same λ and the skew must not move: the formula reads RATIOS
    ///     (`q = (target−inv1)/target`, depletion as `inv1/inv0`), so a protocol with $1M of depth
    ///     and one with $100B must be priced by the identical curve. **This is the property that
    ///     makes a pinned constant unnecessary — and its failure would mean the skew is calibrated
    ///     to a magnitude and silently mis-prices at any other scale.**
    function test_ScaleInvariant_AcrossFiveOrdersOfMagnitude() public pure {
        uint[5] memory lam = [uint(1), 10, 1_000, 100_000, 10_000_000];
        uint flushRef  = _s(1_000_000e6, 500_000e6, 30_000e6);      // inv1 > target
        uint scarceRef = _s(1_000_000e6, 1_500_000e6, 30_000e6);    // inv1 < target
        for (uint i; i < lam.length; ++i) {
            uint L = lam[i];
            assertEq(_s(1_000_000e6 * L, 500_000e6 * L, 30_000e6 * L), flushRef,
                "FLUSH branch is not scale-invariant - the skew is calibrated to a magnitude");
            assertEq(_s(1_000_000e6 * L, 1_500_000e6 * L, 30_000e6 * L), scarceRef,
                "SCARCE branch is not scale-invariant - the skew is calibrated to a magnitude");
        }
    }

    /// **(2) THE BRANCH IS ON `inv1` (POST-DRAIN), NOT `inv0`** — `inv1 = inv0 − drainUsd6`, and the
    ///     flush test is `inv1 >= target`. Pinned as a LAW because three separate diagnoses of
    ///     `test_UNITB_…` reasoned about `inv0` and concluded the fixture was already scarce when it
    ///     was not. Holds at every scale, so it is asserted at three.
    function test_BranchIsOnPostDrainInventory() public pure {
        uint[3] memory inv = [uint(1_000e6), 1_000_000e6, 1_000_000_000e6];
        for (uint i; i < inv.length; ++i) {
            uint I = inv[i];
            uint drain = I / 10;
            uint inv1 = I - drain;
            // target just under inv1 -> flush; just over -> scarce. Same inv0 in both.
            assertEq(_s(I, inv1, drain), _s(I, inv1 - 1, drain),
                "at or below inv1 both must take the flush branch");
            assertGt(_s(I, inv1 * 2, drain), _s(I, inv1, drain),
                "a target ABOVE inv1 must price higher - the scarce branch must engage");
        }
    }

    /// **(3) CONTINUITY AT THE FLUSH BOUNDARY.** The scarce branch as `q1 -> 0` must meet the flush
    ///     branch. A step here would be an arbitrage seam: two swaps either side of `inv1 == target`
    ///     would pay materially different prices for an immaterial difference in size.
    function test_NoCliffAtTheFlushBoundary() public pure {
        uint inv = 1_000_000e6; uint drain = 30_000e6; uint inv1 = inv - drain;
        uint atBoundary = _s(inv, inv1, drain);
        assertEq(_s(inv, inv1 + 1, drain), atBoundary, "discontinuity one wei into scarcity");
        assertEq(_s(inv, inv1 - 1, drain), atBoundary, "discontinuity one wei into flush");
    }

    /// **(4) MONOTONE IN SIZE.** A bigger drain must never be cheaper, across the branch boundary.
    function test_MonotoneInDrainSize() public pure {
        uint inv = 1_000_000e6; uint prev;
        for (uint d = 10_000e6; d <= 500_000e6; d += 10_000e6) {
            uint cur = _s(inv, 900_000e6, d);
            assertGe(cur, prev, "a LARGER drain priced CHEAPER - the skew is not monotone in size");
            prev = cur;
        }
    }

    /// **(5) MONOTONE IN SCARCITY.** Holding the drain fixed, a higher target (more scarcity
    ///     relative to what the drain leaves) must never price lower.
    function test_MonotoneInScarcity() public pure {
        uint inv = 1_000_000e6; uint drain = 100_000e6; uint prev;
        for (uint t = 100_000e6; t <= 3_000_000e6; t += 100_000e6) {
            uint cur = _s(inv, t, drain);
            assertGe(cur, prev, "a SCARCER target priced CHEAPER - the skew is not monotone in flow");
            prev = cur;
        }
    }

    /// ⭐ **(6) THE SEPARATION LAW THAT FIXED `test_UNITB_…`.** Two arms differing ONLY in target can
    ///     price differently **iff** the drain puts one target above `inv1` and leaves the other
    ///     below — i.e. iff `drain > inv0 − target` for exactly one of them. Asserted as a law at
    ///     several scales rather than as the one window that happened to fix one fixture.
    function test_ArmsSeparateExactlyWhenTheDrainCrossesOneTarget() public pure {
        uint[3] memory inv = [uint(10_000e6), 607_866e6, 50_000_000e6];
        for (uint i; i < inv.length; ++i) {
            uint I = inv[i];
            uint lo = I * 30 / 100;      // arm A target
            uint hi = I * 60 / 100;      // arm B target (2x A)
            // drain below (inv0 - hi): both flush -> identical, and the control CANNOT fire.
            assertEq(_s(I, lo, (I - hi) / 2), _s(I, hi, (I - hi) / 2),
                "below the separation point both arms must be flush and price identically");
            // drain inside (inv0 - hi, inv0 - lo): B scarce, A flush -> must differ.
            assertTrue(_s(I, lo, I - hi + (hi - lo) / 2) != _s(I, hi, I - hi + (hi - lo) / 2),
                "inside the window the arms MUST price differently, else no fixture can fire the control");
        }
    }
}
