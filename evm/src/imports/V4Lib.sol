// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UNIVERSAL_ROUTER, PERMIT2, UR_EXECUTE, CMD_V4_SWAP, ACT_SWAP_IN_SINGLE, ACT_SETTLE_ALL,
        ACT_TAKE_ALL, IPermit2, PoolKey, V4ExactInputSingleParams, V4_FEE_OFFSET,
        V4_TICKSP_OFFSET} from "./Interfaces.sol";

/// @notice §SESS-83 — **UNISWAP V4, IN ITS OWN LEAF LIBRARY, AND THE REASON IS ARCHITECTURAL.**
///
/// 🔑 **`LevMath` IS THE BOTTOM LAYER: it imports none of `SwapLib`/`BasketLib`/`QuidLib`, and
///    `SwapLib` imports IT (`SwapLib.sol:28`), so the dependency runs one way by design.** The v4 hop
///    first landed in `SwapLib`, which put it out of reach of `LevMath._hubHop` — the exact place a
///    stable→USDC v4 leg is needed, and the leg GHO depends on. Moving it up would have inverted that
///    dependency; moving it DOWN into `LevMath` costs bytes that contract does not have (**222 free**).
/// ⇒ a LEAF library, imported by both, importing neither. ⭐ **And `external`, not `internal`, on
///   purpose: an external library function is DELEGATECALLED and lives in its OWN deployment, so
///   `LevMath` pays only for the call site rather than inlining ~80 lines of nested `abi.encode` into
///   a contract with 222 bytes to spare.** `address(this)` is still the caller, so balances,
///   approvals and the measured delta all belong to the manager exactly as before.
library V4Lib {
    using SafeERC20 for IERC20OZ;

    /// @notice §SESS-83 — **THE WORD IS DECODED HERE, NOT AT THE CALL SITE, AND THAT IS A SIZE FACT.**
    ///         Decoding `fee`/`tickSpacing` in `LevMath` put it **177 BYTES OVER EIP-170** — the whole
    ///         point of an `external` library is that its code lives in its OWN deployment, and a
    ///         caller that unpacks the arguments first throws that away. One external call, five
    ///         arguments, nothing unpacked on the other side.
    /// ⛔ `hooks` is absent from the word BY CONSTRUCTION and `v4Swap` forces `address(0)`, so no
    ///    caller — keeper, manager or otherwise — can put foreign code on our call stack.
    /// @param word `proto | tickSpacing | fee`; @param toUsdc direction, the caller's not the word's.
    function v4SwapWord(uint256 word, address stable, address usdc, uint256 amt, bool toUsdc,
                        uint256 minOut) external returns (uint256) {
        uint24 f  = uint24(word >> V4_FEE_OFFSET);
        int24  ts = int24(uint24(word >> V4_TICKSP_OFFSET));
        return toUsdc ? v4SwapInner(stable, usdc, amt, minOut, f, ts)
                      : v4SwapInner(usdc, stable, amt, minOut, f, ts);
    }

    /// §SESS-79 — a v4 leg that failed or came in under the floor. Distinct from `Slippage()` so a
    /// red is attributable to the venue arm rather than to the aggregate conversion.
    error V4SwapFailed();

    /// @notice §SESS-79 — **A UNISWAP V4 HOP. THE CALLER NAMES A FEE TIER; EVERYTHING ELSE IS OURS.**
    ///
    /// 🔒 **THE QUESTION THIS ANSWERS: "CAN A HACKED KEEPER SUPPLY AN ARBITRARY PoolKey AND HIJACK
    ///    FUNDS IN FLIGHT?"** Without controls, **YES — and not by a slippage margin.** A V4 `PoolKey`
    ///    carries a `hooks` address, and a v4 hook is **ARBITRARY CODE THAT RUNS INSIDE OUR
    ///    TRANSACTION** with `beforeSwap`/`afterSwap` callbacks while the PoolManager lock is held.
    ///    That is a different class from a bad venue: it is attacker code on our call stack, not a
    ///    worse price. **A balance-delta floor bounds a bad price; it does not bound re-entrancy.**
    /// ⇒ **THREE CONTROLS, AND THE FIRST IS THE ONE THAT MATTERS:**
    ///   1. ⛔ **`hooks` IS FORCED TO `address(0)` AND IS NOT A PARAMETER.** A hookless pool is a plain
    ///      AMM with no foreign code in the path. **MEASURED AFFORDABLE, not assumed:** 13 hookless
    ///      pools exist across our pairs, including **GHO/USDC at fee 500 with real liquidity
    ///      (2.0e21)** — the route this basket lacked entirely.
    ///   2. **`currency0`/`currency1` ARE DERIVED** from `tokenIn`/`tokenOut` (sorted), so a pool of
    ///      unrelated tokens is **unconstructible** rather than merely rejected.
    ///   3. **`SETTLE_ALL`/`TAKE_ALL` NAME OUR CURRENCIES**, so we can only ever pay the token we are
    ///      selling — capped at `amountIn` — and only ever receive the token we asked for.
    /// ⇒ **the caller's whole remaining freedom is `fee`/`tickSpacing`: WHICH hookless pool of the pair
    ///   we are already trading.** Worst case it names an empty tier, the swap returns little, and the
    ///   floor reverts. **Liveness, never custody** — the same bound as every other arm in this lane.
    /// ⚠️ **AND THE COST OF CONTROL 1 IS STATED, NOT HIDDEN: USDS's V4 DEPTH IS NOT HOOKLESS.** Its
    ///    hookless pools exist at every tier and all hold **zero** liquidity, so the 76.2M in the
    ///    singleton sits behind a hook we will not execute. **We reach GHO and not USDS.** Widening to
    ///    hooked pools would need a hook allowlist, which is a trusted-address decision, not a tweak.
    ///
    /// @dev Builds ONE canonical shape and parses nothing: commands `0x10`, actions
    ///      `SWAP_EXACT_IN_SINGLE / SETTLE_ALL / TAKE_ALL`. 🔴 **BUILD-DON'T-PATCH IS DELIBERATE.**
    ///      UniversalRouter calldata is three levels of dynamic nesting and its action sequence VARIES
    ///      in live traffic (a real `0x10` transaction decoded as `070c0e`, the multi-hop variant with
    ///      an 896-byte path param), so there is no fixed offset for the amount the way there is in
    ///      1inch's static `SwapDescription`. Patching here would be guessing at an offset.
    /// @dev The router pulls through **Permit2**, so the token is approved to Permit2 and Permit2 is
    ///      permitted to the router — both for `amountIn` only, and the ERC-20 leg is re-zeroed after.
    /// @return out the MEASURED balance delta of `tokenOut`, never the router's own return value.
    function v4Swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut,
                    uint24 fee, int24 tickSpacing) external returns (uint256 out) {
        return v4SwapInner(tokenIn, tokenOut, amountIn, minOut, fee, tickSpacing);
    }

    /// The body, `internal` so both entrypoints share ONE implementation rather than two that drift.
    function v4SwapInner(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut,
                         uint24 fee, int24 tickSpacing) internal returns (uint256 out) {
        if (amountIn == 0) return 0;
        // ⚠️ **SCOPED BLOCKS, NOT `via_ir`.** This hit `Stack too deep` at 14 locals; `foundry.toml`
        //    keeps `via_ir = false` deliberately and CLAUDE.md prescribes moving locals out of scope
        //    rather than turning the IR pipeline on. Each block below drops its temporaries.
        IERC20OZ(tokenIn).forceApprove(PERMIT2, amountIn);
        IPermit2(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp + 1));

        uint256 before_ = IERC20(tokenOut).balanceOf(address(this));
        bool ok;
        {
            bytes[] memory params = new bytes[](3);
            {
                (address c0, address c1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
                // ⚠️ **ENCODE THE STRUCT, NOT THE FIELDS.** `hookData` is `bytes`, so the tuple is
                //    DYNAMIC and `abi.encode(struct)` emits a leading offset the field-wise form
                //    omits. The router decodes `params[0]` as one struct; the loose form decoded as
                //    garbage and reverted inside `unlockCallback` with nothing swapped.
                params[0] = abi.encode(V4ExactInputSingleParams({
                    poolKey: PoolKey({ currency0: c0, currency1: c1, fee: fee,
                                       tickSpacing: tickSpacing,
                                       hooks: address(0) }),      // ⛔ control 1: never a parameter
                    zeroForOne: tokenIn == c0,                    // derived, not supplied
                    amountIn: uint128(amountIn),
                    amountOutMinimum: uint128(minOut),
                    hookData: bytes("") }));
            }
            params[1] = abi.encode(tokenIn,  amountIn);           // SETTLE_ALL — our currency, our cap
            params[2] = abi.encode(tokenOut, minOut);             // TAKE_ALL   — our currency, our floor
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(
                abi.encodePacked(ACT_SWAP_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL), params);
            (ok, ) = UNIVERSAL_ROUTER.call(abi.encodeWithSelector(
                UR_EXECUTE, abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp));
        }
        IERC20OZ(tokenIn).forceApprove(PERMIT2, 0);               // zeroed on BOTH paths
        out = IERC20(tokenOut).balanceOf(address(this)) - before_;
        // ⚠️ The delta is the ONLY thing trusted, exactly as `convertTo` and `curveExchange` do — a
        //    router's own return value is not evidence and a hostile venue cannot fake our balance.
        if (!ok || out < minOut) revert V4SwapFailed();
    }
}
