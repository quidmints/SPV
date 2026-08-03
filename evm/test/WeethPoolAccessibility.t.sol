// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IV3SwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";

/// @notice MEASUREMENT, not a regression guard. Answers one question with REAL swaps rather than
///         QuoterV2 simulations: is the ~4,840 WETH sitting in `ETHERFI_POOL_A` actually REACHABLE
///         by us, given that `liquidity()` (the tick we sit on) reports ~nil?
///
///         The Quoter runs the same tick-crossing maths the pool does, so it should agree — but it
///         is a simulation, and "the depth is adjacent, not in-range" is exactly the kind of claim
///         that deserves an execution rather than a quote. This does the execution and prints the
///         realised rate against `getRate()` fair, plus how far the tick moved and how many
///         initialized ticks were crossed to get there.
contract WeethPoolAccessibilityTest is ForkPin {
    address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH  = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant POOL_A = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3; // 0.05%
    address constant POOL_B = 0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93; // 0.01%

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// @dev One real swap. Returns (wethOut, realised bps vs fair, ticks moved).
    function _sell(uint amountIn, uint24 fee, address pool) internal returns (uint out, int bps, int24 moved) {
        (, int24 tick0,,,,,) = IUniswapV3Pool(pool).slot0();
        deal(WEETH, address(this), amountIn);
        IERC20(WEETH).approve(ROUTER, amountIn);
        out = IV3SwapRouter(ROUTER).exactInputSingle(IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WEETH, tokenOut: WETH, fee: fee, recipient: address(this),
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        uint fair = IWeETH(WEETH).getEETHByWeETH(amountIn);
        bps = (int(out) - int(fair)) * 10000 / int(fair);
        (, int24 tick1,,,,,) = IUniswapV3Pool(pool).slot0();
        moved = tick1 - tick0;
    }

    /// @notice Sell an escalating ladder into pool A for real, and report the realised price.
    ///         If the "stranded WETH is adjacent, not in-range" reading is correct, these fills
    ///         succeed and degrade gradually. If the WETH were genuinely unreachable, they would
    ///         return dust regardless of size.
    function test_realSwaps_poolA_areFillable() public {
        uint[6] memory sizes = [uint(1e18), 100e18, 500e18, 1000e18, 2000e18, 4000e18];
        emit log_string("--- POOL A (0.05%) REAL SWAPS: weETH in -> WETH out ---");
        emit log_named_uint("in-range liquidity() before", IUniswapV3Pool(POOL_A).liquidity());
        for (uint i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();            // each swap starts from untouched pool state
            (uint out, int bps, int24 moved) = _sell(sizes[i], 500, POOL_A);
            emit log_named_uint("weETH in ", sizes[i] / 1e18);
            emit log_named_uint("  WETH out (wei)", out);
            emit log_named_int ("  realised bps vs fair", bps);
            emit log_named_int ("  ticks moved", int(moved));
            // The whole point: a real fill, not dust. 1 weETH must return ~1.09 WETH, not ~0.
            assertGt(out, sizes[i] * 105 / 100, "fill returned dust - WETH NOT reachable");
            vm.revertToState(snap);
        }
    }

    /// @notice Same ladder on pool B, which the quote data says CLIFFS near 1.3k weETH because the
    ///         pool simply runs out of WETH. A real swap should show the same wall.
    function test_realSwaps_poolB_cliff() public {
        uint[4] memory sizes = [uint(1e18), 1000e18, 2000e18, 4000e18];
        emit log_string("--- POOL B (0.01%) REAL SWAPS ---");
        emit log_named_uint("pool B WETH balance", IERC20(WETH).balanceOf(POOL_B));
        for (uint i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint out, int bps, int24 moved) = _sell(sizes[i], 100, POOL_B);
            emit log_named_uint("weETH in ", sizes[i] / 1e18);
            emit log_named_uint("  WETH out (wei)", out);
            emit log_named_int ("  realised bps vs fair", bps);
            emit log_named_int ("  ticks moved", int(moved));
            vm.revertToState(snap);
        }
    }

    /// @notice The REVERSE direction, which decides the "the pool wants to dump its WETH surplus"
    ///         reading. If that were true, WETH in -> weETH out would fill readily. Executed for
    ///         real rather than quoted.
    function test_realSwaps_buyingWeethIsBroken() public {
        emit log_string("--- POOL A REVERSE: WETH in -> weETH out ---");
        emit log_named_uint("pool A weETH balance (all that CAN be bought)", IERC20(WEETH).balanceOf(POOL_A));
        uint amountIn = 1e18;
        deal(WETH, address(this), amountIn);
        IERC20(WETH).approve(ROUTER, amountIn);
        uint out = IV3SwapRouter(ROUTER).exactInputSingle(IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH, tokenOut: WEETH, fee: 500, recipient: address(this),
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        uint fair = IWeETH(WEETH).getWeETHByeETH(amountIn);
        emit log_named_uint("  WETH in (wei) ", amountIn);
        emit log_named_uint("  weETH out (wei)", out);
        emit log_named_uint("  fair weETH would be", fair);
        emit log_named_int ("  realised bps vs fair", (int(out) - int(fair)) * 10000 / int(fair));
    }
}
