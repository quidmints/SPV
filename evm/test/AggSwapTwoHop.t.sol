// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {PROTO_UNIV3, ZERO_FOR_ONE, IERC20Min} from "../src/imports/Interfaces.sol";
import {UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR} from "../src/imports/Interfaces.sol";

/// @notice §CURVE-ALONE-CANNOT-DO-IT — the route encoder gained a second pool word. ONE claim is
///         tested against LIVE pools: that a two-hop route EXECUTES and lands within a spread's
///         distance of the one hop it replaces.
/// ⛔ **IT DOES NOT CLAIM THE TWO-HOP IS CHEAPER, AND THE OLD HEADER DID.** §SESS-71 reshaped the
///    assertion to proximity after superiority failed at three blocks on identical bytecode; this
///    header kept asserting the "0.67% vs 0.92%" reading for a session after that stopped being what
///    the body checked. A stale docblock is a misleading test even when every assertion is sound —
///    the reader takes the claim from the prose, not from the `assertLt`.
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

    function test_TwoHopExecutesAndLandsWithinASpreadOfTheDirectPool() public {
        uint256 amt = 1_000_000e6;

        deal(USDC, address(this), amt);
        uint256 twoHop = LevMath.routedSwap(USDC, WBTC, amt, 0, _rr(abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(0), uint256(0), uint256(0), _word(USDC_WETH_005), _word(WETH_WBTC_005))));
        assertGt(twoHop, 0, "two-hop produced no WBTC");
        emit log_named_decimal_uint("USDC->WETH->WBTC", twoHop, 8);

        deal(USDC, address(this), amt);
        uint256 oneHop = LevMath.routedSwap(USDC, WBTC, amt, 0, _rr(abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(0), uint256(0), uint256(0), _word(USDC_WBTC_030))));
        assertGt(oneHop, 0, "one-hop produced no WBTC");
        emit log_named_decimal_uint("USDC->WBTC direct  ", oneHop, 8);

        // ⭐ §SESS-71 — **RESHAPED. `assertGt(twoHop, oneHop)` ASSERTED THE MARKET, NOT THE CODE.**
        //
        // 🔴 It failed three times today at three different blocks, on identical bytecode — direct won
        //    by 3.8 bps, then 5.5 bps, then 5.5 again — and it is the same class as §SESS-48 (the slip
        //    test), §SESS-53 (E2) and `VenueBorrowRate.t.sol`'s own §POINT-IN-TIME-IS-NOT-AN-INVARIANT.
        //    Measured independently this session: the two-hop wins USDT→WETH by ~28 bps at both $100k
        //    and $1M, and LOSES on USDC→WETH at $1M. **Neither route wins by class**, which is exactly
        //    why §SESS-49 made the planner QUOTE both instead of preferring one.
        // ⛔ **AND SUPERIORITY WAS NEVER THE PROPERTY THIS TEST GUARDS.** What can actually break here
        //    is `_aggSwap` deriving a direction bit wrongly or naming a pool that does not hold the
        //    token — and that produces a CATASTROPHIC difference, not a five-basis-point one. A 5 bps
        //    gap does not mean the routing is broken; a 90% gap does. §VACUOUS-BOUNDS' discriminator
        //    is whether the extreme value MEANS the thing the message says, and here it did not.
        // ⇒ assert PROXIMITY, which fails loudly on the real defect and never on market drift. The
        //   magnitude stays as an emitted OBSERVATION, because it is a fact about the pools today.
        uint256 gapBps = twoHop > oneHop
            ? (twoHop - oneHop) * 10_000 / oneHop
            : (oneHop - twoHop) * 10_000 / oneHop;
        emit log_named_uint("two-hop vs direct, gap (bps)", gapBps);
        emit log_named_string("winner", twoHop > oneHop ? "two-hop" : "direct");
        assertLt(gapBps, 200,
            "the two routes diverged by more than 2% - at these depths that is not a market spread, "
            "it is a crossed direction bit or a pool that does not hold the token");
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
        uint256 clean = LevMath.routedSwap(USDC, WBTC, amt, 0, _rr(abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(0), uint256(0), uint256(0), _word(USDC_WETH_005), _word(WETH_WBTC_005))));
        vm.revertToState(snap);
        deal(USDC, address(this), amt);
        uint256 lied = LevMath.routedSwap(USDC, WBTC, amt, 0, _rr(abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(0), uint256(0), uint256(0), _word(USDC_WETH_005) | ZERO_FOR_ONE, _word(WETH_WBTC_005) | ZERO_FOR_ONE)));
        assertEq(clean, lied, "a keeper-supplied direction bit must not change the outcome");
        assertGt(clean, 0, "control: a zero result would make the equality vacuous");
    }
    function _rr(bytes memory b) internal pure returns (bytes[] memory o) { o = new bytes[](1); o[0] = b; }

}
