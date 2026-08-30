// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {PROTO_UNIV3, ZERO_FOR_ONE, IERC20Min} from "../src/imports/Interfaces.sol";

/// @notice §CURVE-ALONE-CANNOT-DO-IT — `_aggSwap` gained a second pool word. Two claims are tested
///         against LIVE pools: that the two-hop route EXECUTES, and that it is CHEAPER than the one
///         hop it replaces on the BTC leg (measured 0.67% vs 0.92% at $1M).
contract AggSwapTwoHopTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    // live UniV3 pools
    address constant USDC_WETH_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant WETH_WBTC_005 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address constant USDC_WBTC_030 = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    /// Pool word: low 160 bits the pool, protocol in 253-255. The direction bit is deliberately left
    /// UNSET — `_aggSwap` must derive it, and if it did not this swap would cross the pool backwards.
    function _word(address pool) internal pure returns (uint256) {
        return uint256(uint160(pool)) | (uint256(PROTO_UNIV3) << 253);
    }

    function test_TwoHopExecutesAndBeatsTheDirectPool() public {
        uint256 amt = 1_000_000e6;

        deal(USDC, address(this), amt);
        uint256 twoHop = LevMath._aggSwap(USDC, WBTC, amt, 0, _word(USDC_WETH_005), _word(WETH_WBTC_005));
        assertGt(twoHop, 0, "two-hop produced no WBTC");
        emit log_named_decimal_uint("USDC->WETH->WBTC", twoHop, 8);

        deal(USDC, address(this), amt);
        uint256 oneHop = LevMath._aggSwap(USDC, WBTC, amt, 0, _word(USDC_WBTC_030), 0);
        assertGt(oneHop, 0, "one-hop produced no WBTC");
        emit log_named_decimal_uint("USDC->WBTC direct  ", oneHop, 8);

        // the measured claim: two pools beat the best direct pool at this size
        assertGt(twoHop, oneHop, "two-hop must beat the direct pool on the BTC leg");
    }

    /// The direction bit is DERIVED, never trusted: passing it set the WRONG way must not corrupt the
    /// swap, because `_aggSwap` clears it and recomputes from tokenIn / tokenOut.
    function test_ADeliberatelyWrongDirectionBitIsIgnored() public {
        uint256 amt = 100_000e6;
        // ⚠️ THE SNAPSHOT IS LOAD-BEARING, AND WITHOUT IT THIS TEST FAILS FOR A REASON THAT IS NOT THE
        //    CODE. Both arms trade through the SAME live pools, so running them back to back means the
        //    first arm MOVES THE PRICE and the second necessarily gets less — measured 126,130,716 vs
        //    125,872,495, a 0.2% gap that looks exactly like a direction bug and is pure sequencing.
        //    Comparing two swaps requires they start from the same state.
        uint256 snap = vm.snapshotState();
        deal(USDC, address(this), amt);
        uint256 clean = LevMath._aggSwap(USDC, WBTC, amt, 0, _word(USDC_WETH_005), _word(WETH_WBTC_005));
        vm.revertToState(snap);
        deal(USDC, address(this), amt);
        uint256 lied = LevMath._aggSwap(USDC, WBTC, amt, 0,
            _word(USDC_WETH_005) | ZERO_FOR_ONE, _word(WETH_WBTC_005) | ZERO_FOR_ONE);
        assertEq(clean, lied, "a keeper-supplied direction bit must not change the outcome");
        assertGt(clean, 0, "control: a zero result would make the equality vacuous");
    }
}
