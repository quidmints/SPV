// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {UNOSWAP_SELECTOR, PROTO_UNIV3, PROTO_UNIV2} from "../src/imports/Interfaces.sol";
import {IERC20 as IERC20F} from "forge-std/interfaces/IERC20.sol";

/// @notice ⭐ §SESS-97 — **THE SPLIT ARM, EXERCISED. BUILT-AND-UNEXERCISED IS THE SHAPE THIS TREE HAS
///         SHIPPED FOUR TIMES** (a phantom fifth token, a v4 library nothing could reach, a `bytes
///         route` arm with no producer, an unoswap3 selector neither side emitted). A split executor
///         that no test splits through is the fifth.
contract SplitRouteTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V3_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant V3_030 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _w(address pool, uint256 proto) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(0), uint256(0), uint256(0),
            uint256(uint160(pool)) | (proto << 253));
    }

    /// ⭐ ① **A SPLIT EXECUTES, SPENDS EVERYTHING, AND LANDS NEAR THE UNSPLIT BASELINE.**
    /// ⚠️ Proximity, NOT superiority. Whether splitting beats one pool is a fact about depth on one
    ///    afternoon (§POINT-IN-TIME-IS-NOT-AN-INVARIANT) — §SESS-71 already retracted one superiority
    ///    assertion that failed at three blocks on identical bytecode. What CAN break here is a leg
    ///    being silently dropped or double-counted, and that is not a 2% effect.
    function test_SplitAcrossThreeVenuesFillsAndSpendsEverything() public {
        uint256 amt = 300_000e6;
        uint256 snap = vm.snapshotState();

        deal(USDC, address(this), amt);
        bytes[] memory one = new bytes[](1);
        one[0] = _w(V3_005, PROTO_UNIV3);
        uint256 unsplit = LevMath.routedSwap(USDC, WETH, amt, 0, one);
        emit log_named_decimal_uint("unsplit  (V3 0.05% alone)", unsplit, 18);
        vm.revertToState(snap);

        deal(USDC, address(this), amt);
        bytes[] memory three = new bytes[](3);
        three[0] = _w(V3_005, PROTO_UNIV3);
        three[1] = _w(V3_030, PROTO_UNIV3);
        three[2] = _w(V2_PAIR, PROTO_UNIV2);          // §SESS-94 — the V2 family, measured to fill
        uint256 split = LevMath.routedSwap(USDC, WETH, amt, 0, three);
        emit log_named_decimal_uint("split    (V3 .05 + V3 .30 + V2)", split, 18);

        assertEq(IERC20F(USDC).balanceOf(address(this)), 0,
            "the split did not spend the whole input - a leg was skipped or the dust was stranded");
        assertGt(split, 0, "the split produced nothing");
        uint256 gap = split > unsplit ? (split - unsplit) * 10_000 / unsplit
                                      : (unsplit - split) * 10_000 / unsplit;
        emit log_named_uint("split vs unsplit, gap (bps)", gap);
        assertLt(gap, 200,
            "split and unsplit diverged by more than 2% - at these depths that is a DROPPED or "
            "DOUBLE-COUNTED leg, not a market spread");
    }

    /// ⭐ ② **WEIGHT BY REPETITION IS THE WHOLE WEIGHTING MECHANISM, SO IT MUST ACTUALLY WEIGHT.**
    ///    Three copies of one venue and one of another is a 3:1 split. ⛔ If repetition were ignored
    ///    and the list de-duplicated, this would equal the 1:1 case — which is exactly the silent
    ///    failure the equal-share design trades the weight field for.
    function test_RepetitionActuallyShiftsTheSplit() public {
        uint256 amt = 400_000e6;
        uint256 snap = vm.snapshotState();

        deal(USDC, address(this), amt);
        bytes[] memory even = new bytes[](2);
        even[0] = _w(V3_005, PROTO_UNIV3); even[1] = _w(V2_PAIR, PROTO_UNIV2);
        uint256 oneToOne = LevMath.routedSwap(USDC, WETH, amt, 0, even);
        vm.revertToState(snap);

        deal(USDC, address(this), amt);
        bytes[] memory tilted = new bytes[](4);
        tilted[0] = _w(V3_005, PROTO_UNIV3); tilted[1] = _w(V3_005, PROTO_UNIV3);
        tilted[2] = _w(V3_005, PROTO_UNIV3); tilted[3] = _w(V2_PAIR, PROTO_UNIV2);
        uint256 threeToOne = LevMath.routedSwap(USDC, WETH, amt, 0, tilted);

        emit log_named_decimal_uint("1:1  V3/V2", oneToOne, 18);
        emit log_named_decimal_uint("3:1  V3/V2", threeToOne, 18);
        assertEq(IERC20F(USDC).balanceOf(address(this)), 0, "the 3:1 split left input unspent");
        assertNotEq(oneToOne, threeToOne,
            "1:1 and 3:1 produced IDENTICAL output - repetition is being ignored, so the only "
            "weighting mechanism the split arm has does nothing");
    }
}
