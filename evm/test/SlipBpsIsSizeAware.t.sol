// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";

/// @notice §THE-SLIPPAGE-WINDOW-IS-THE-LEAK — `minOut` is `oracle x (10000 - slip)/10000`, so every
///         basis point of the allowance is one a compromised keeper can take by returning exactly the
///         floor. A FLAT 100 bps was ~20x the honest need at small size (pure leak) and already too
///         tight at $5M on the worse tier. This pins the size-aware replacement.
contract SlipBpsIsSizeAwareTest is Test {
    /// THE SAFETY PROPERTY, AND THE REASON THIS COULD LAND WITHOUT KNOWING LIVE POSITION SIZES:
    /// the allowance is CAPPED at the old constant, so it can only ever TIGHTEN the floor. No swap
    /// that executes today can begin to revert.
    function testFuzz_NeverLooserThanTheOldConstant(uint256 usd18) public pure {
        usd18 = bound(usd18, 0, 1e40);                 // up to $10 trillion, absurd on purpose
        assertLe(LevMath.slipBpsForTest(usd18), 100, "the ceiling must hold at every size");
    }

    /// It must actually BITE at the sizes where 100 bps was pure leak - otherwise it changes nothing.
    function test_SmallTradesGetAMuchTighterFloor() public pure {
        assertEq(LevMath.slipBpsForTest(100_000e18), 25, "$100k: 25 bps, 4x tighter than the old flat 100");
        assertEq(LevMath.slipBpsForTest(1_000_000e18), 50, "$1M: 50 bps");
        assertEq(LevMath.slipBpsForTest(2_000_000e18), 75, "$2M: 75 bps");
    }

    /// ...and it must NOT bite at the sizes where the honest cost genuinely approaches 100 bps.
    /// Measured: USDC->WETH costs 224 bps at $5M, so the ceiling is the binding constraint there and
    /// tightening further would revert honest swaps. That is why the ceiling stays.
    function test_LargeTradesKeepTodaysAllowance() public pure {
        assertEq(LevMath.slipBpsForTest(3_000_000e18), 100, "$3M reaches the ceiling");
        assertEq(LevMath.slipBpsForTest(50_000_000e18), 100, "and never exceeds it");
    }

    /// Monotonic: a larger trade may never receive a TIGHTER allowance than a smaller one, or the
    /// curve would refuse big honest swaps while waving small ones through.
    function testFuzz_MonotonicInSize(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 1e30); b = bound(b, 0, 1e30);
        if (a > b) (a, b) = (b, a);
        assertLe(LevMath.slipBpsForTest(a), LevMath.slipBpsForTest(b), "allowance must not fall with size");
    }
}
