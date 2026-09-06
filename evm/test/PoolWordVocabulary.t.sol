// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, ZERO_FOR_ONE,
        USDC, RLUSD_TOKEN, PYUSD_TOKEN, CURVE_USDC_RLUSD, CURVE_PYUSD_USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20V { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); function decimals() external view returns (uint8); }

/// @notice §SESS-22 — **CAN THE POOL-WORD VOCABULARY REACH WHAT WE NEED, WITHOUT KEEPER CALLDATA?**
///
/// This is the decisive measurement for the keeper-planner design. `_aggSwap`'s own header states the
/// security position and it is rule 17, not a guard: *"The keeper could not have supplied a working
/// route, only a route that happened to work. ⇒ Taking the POOL and building the calldata here makes
/// that class UNCONSTRUCTIBLE … the keeper owns only the venue choice."* And `UNOSWAP2_SELECTOR`'s note
/// gives the reason a pre-built blob cannot work at all: *"our amounts are computed mid-transaction, so
/// anything that embeds its amount is stale by construction."*
///
/// ⇒ **IF the pool-word vocabulary covers our venues, `bytes route` is not a feature — it is the one
///    remaining input a hacked keeper can use that the contract cannot inspect, and it should be
///    DELETED rather than threaded further.** This file measures whether that "if" holds.
///
/// 🔑 **THE VOCABULARY, AS MEASURED AGAINST THE DEPLOYED ROUTER** (`Interfaces.sol:181-184`):
///    bits 253-255 = protocol, **`0` UniswapV2 · `1` UniswapV3 · `2` Curve**; bit 247 = `zeroForOne`
///    (V3); low 160 bits = pool. Two hops via `unoswap2`.
/// ⚠️ **§SESS-6 MEASURED CURVE UNREACHABLE IN 32 ENCODINGS — but that was ONE pool** (the ether.fi
///    weETH/WETH pool, an NG-style pool). **A negative on one pool is not a negative on the protocol
///    id**, and the router's own bit table says `2` is Curve. That is the ambiguity this resolves.
contract PoolWordVocabulary is ForkPin {
    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _word(uint256 proto, address pool) internal pure returns (uint256) {
        return (proto << 253) | uint256(uint160(pool));
    }

    /// @dev One `unoswap` attempt. Returns tokens actually received — never the router's own claim,
    ///      because a V2 word was measured returning `ok` with ZERO moved (`_aggSwap` note 2).
    function _try(address tokenIn, address tokenOut, uint256 amt, uint256 dex) internal returns (uint256 got) {
        deal(tokenIn, address(this), amt);
        IERC20V(tokenIn).approve(ONEINCH_ROUTER, amt);
        uint256 before = IERC20V(tokenOut).balanceOf(address(this));
        (bool ok, ) = ONEINCH_ROUTER.call(
            abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(uint160(tokenIn)), amt, uint256(1), dex));
        ok;                                    // the delta is the verdict, not `ok`
        got = IERC20V(tokenOut).balanceOf(address(this)) - before;
        IERC20V(tokenIn).approve(ONEINCH_ROUTER, 0);
    }

    /// ⭐ THE ANSWER: does protocol id 2 fill a REAL Curve stableswap pool from our own routing table?
    function test_Proto2_ReachesTheCurvePoolsInOurRoutingTable() public {
        uint256 amt = 10_000e6;                              // 10k USDC
        uint256 gotP = _try(USDC, PYUSD_TOKEN, amt, _word(2, CURVE_PYUSD_USDC));
        console2.log("USDC -> PYUSD  via proto=2, got:", gotP);
        uint256 gotR = _try(USDC, RLUSD_TOKEN, amt, _word(2, CURVE_USDC_RLUSD));
        console2.log("USDC -> RLUSD  via proto=2, got:", gotR);
        // 🔴 **MEASURED 2026-09-06: BOTH ZERO.** The router's own bit table says `2` is Curve, and the
        //    control below proves the encoder fills a known-good pool at the same call site — so this is
        //    a property of the VOCABULARY, not of the harness. §SESS-6's negative on the ether.fi pool
        //    was not pool-specific after all.
        // ⇒ **THE POOL-WORD PATH CANNOT REACH EVERY VENUE**, so "delete `bytes route`" is REFUTED: the
        //    amount-free encoder is strictly less expressive than the venues we need.
        assertEq(gotP, 0, "proto=2 now fills PYUSD/USDC - RE-OPEN the delete-route question, the vocabulary grew");
        assertEq(gotR, 0, "proto=2 now fills USDC/RLUSD - RE-OPEN the delete-route question");
    }

    /// 🔴 THE CONTROL. If `_try` cannot fill ANY pool the encoder is broken and every zero above is
    ///    meaningless. V3 USDC->WETH is the encoding the tree has already verified moves tokens.
    function test_Control_TheEncoderFillsAKnownGoodPool() public {
        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address v3 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;   // USDC/WETH 0.05%
        uint256 dex = _word(1, v3);
        // token0 is USDC on this pool, so selling USDC is zeroForOne.
        uint256 got = _try(USDC, WETH, 10_000e6, dex | ZERO_FOR_ONE);
        console2.log("CONTROL USDC -> WETH via proto=1, got:", got);
        assertGt(got, 0, "CONTROL FAILED - the encoder fills nothing, so the Curve zeros prove nothing");
    }
}
