// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external returns (uint256 amountOut, uint160 after_, uint32 ticks, uint256 gas);
}

/// @title  §SKEW-VS-V3 — **AT WHAT SIZE IS OUR SKEW WORSE THAN UNISWAP'S SLIPPAGE?**
///
/// @notice Owner: *"are you sure people won't just use uniswap v4 because there will be less
///         slippage there in the range vs our skew? at what transaction size does this become a real
///         difference. i need empirical data."*
///
///         Both sides measured on the SAME mainnet fork, at the SAME notional, in bps against the
///         SAME oracle mid, so the numbers are comparable rather than two scales side by side.
///         ⚠️ Uniswap is quoted through the REAL `QuoterV2` against the REAL 0.05% WETH/USDC pool —
///         its depth is whatever the market actually has at this block, not a model.
contract SkewVsUniswapV3Test is AllesFixture {
    IQuoterV2 constant QUOTER = IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);
    address   constant USDC_M = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint24    constant FEE_5BPS = 500;

    function _seed() internal returns (uint px) {
        deal(address(USDC), User01, 4_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(User02);
        ETH.deposit{value: 400 ether}(0, User02);
        px = AUX.getTWAPforAsset(address(WETH), 1800);
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        // (§E294) ONE LOOP: the anchor moves, then a real swap records it. Both sigma^2 legs are fed
        // only from `swap()` (Core:1031/1039), so the old push-only loop built variance through a
        // path production does not use — and the swaps it needed for `flowEwmaUsd` were already here.
        uint spx = px;
        vm.startPrank(User03);                            // real swaps -> non-zero flowEwmaUsd
        USDC.approve(address(AUX), type(uint).max);
        for (uint i; i < 6; ++i) {                        // MOVING samples -> real sigma^2
            spx = i % 2 == 0 ? spx + spx / 50 : spx - spx / 51;
            _setEthFeed(spx / 1e10);
            AUX.swap(address(USDC), address(WETH), true, 50_000 * USDC_PRECISION, 0, true);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
    }

    function test_SkewVsV3_CrossoverSize() public {
        uint px = _seed();
        emit log_named_uint("oracle px (usd18/ETH)", px);
        emit log_named_uint("our sigma^2          ", CORE.realizedVarianceWad());
        emit log_named_uint("our flowEwmaUsd      ", CORE.flowEwmaUsd());
        emit log_named_uint("our POOLED (ETH)     ", CORE.POOLED());
        emit log_string("size_usd | uniV3_bps | our_skew_bps | cheaper");

        uint[8] memory sizes = [uint(1_000), 10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000];
        for (uint i; i < sizes.length; ++i) {
            uint usd = sizes[i];
            // --- Uniswap v3: USDC -> WETH through the real pool, slippage vs oracle mid ---
            uint amtIn = usd * USDC_PRECISION;
            (uint out,,,) = QUOTER.quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDC_M, tokenOut: address(WETH), amountIn: amtIn, fee: FEE_5BPS, sqrtPriceLimitX96: 0}));
            uint fairEth = usd * 1e36 / px;               // usd(1e0) * 1e18 / (px/1e18)
            uint uniBps  = fairEth > out ? (fairEth - out) * 10_000 / fairEth : 0;
            // --- ours: the PRODUCTION entry, same notional ---
            uint ourWad = AUX.wellSkew(address(WETH), usd * 1e6);
            uint ourBps = ourWad / 1e14;                  // WAD -> bps
            emit log_named_string(
                string.concat("$", vm.toString(usd)),
                string.concat(vm.toString(uniBps), " bps uni | ", vm.toString(ourBps),
                              " bps ours | ", ourBps <= uniBps ? "OURS" : "UNI"));
        }
    }
}
