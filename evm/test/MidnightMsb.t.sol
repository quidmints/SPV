// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {UtilsLib} from "../src/midnight/libraries/UtilsLib.sol";

contract MsbTest is Test {
    /// @dev Independent reference: highest set bit by descending scan. Deliberately NOT the
    ///      smear/popcount form under test, so agreement is evidence and not a tautology.
    function ref(uint128 x) internal pure returns (uint256) {
        for (uint256 i = 127; ; --i) { if (x & (uint128(1) << i) != 0) return i; if (i == 0) break; }
        revert("zero");
    }
    function test_EveryBitPosition() public pure {
        for (uint256 i = 0; i < 128; ++i) {
            uint128 x = uint128(1) << i;
            assertEq(UtilsLib.msb(x), i, "single bit");
            assertEq(UtilsLib.msb(x), ref(x), "vs reference");
        }
    }
    function test_TopBitDominates() public pure {
        for (uint256 i = 1; i < 128; ++i) {
            uint128 x = uint128((uint256(1) << i) | ((uint256(1) << i) - 1)); // all bits <= i
            assertEq(UtilsLib.msb(x), i, "smeared");
        }
    }
    function testFuzz_MatchesReference(uint128 x) public pure {
        vm.assume(x != 0);
        assertEq(UtilsLib.msb(x), ref(x));
    }
    /// @dev Upstream `sub(255, clz(0))` wraps to type(uint256).max; ours must wrap identically.
    function test_ZeroWrapsLikeUpstream() public pure {
        assertEq(UtilsLib.msb(0), type(uint256).max);
    }
}
