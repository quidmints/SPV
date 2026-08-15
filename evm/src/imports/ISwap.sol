// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Aux's public stable<->volatile swap surface (Aux.sol `swap`), declared
///         once here as the single source of truth. `Aux` implements it; peripherals
///         (formerly also `SorExchange`, the Liquity-zapper adapter, deleted 2026-08) consume it without
///         re-declaring a duplicate interface. `token` = stable side (or QUID/zero),
///         `asset` = volatile side (WETH/WBTC), `forVolatile` true = stable->volatile.
interface ISwap {
    function swap(address token, address asset, bool forVolatile, uint256 amount, uint256 minOut)
        external payable returns (uint256);

    // ── Unified QUOTE surface ──────────────────────────────────────────────
    // The pricing views an RFQ maker (Bebop) or an Arcadia solver (Khalani) reads to
    // quote the SAME fill the swap executes at: the Chainlink-anchored TWAP, its
    // staleness flag, and the well's inventory-skew taker-limit. Quote = base × (1−skew)
    // (swap-OUT), base the oracle price for `asset` (WETH/WBTC). `Aux` implements all.
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint256 price);
    function resolvedTwap(address asset, uint32 period) external view returns (uint256 price, bool stale);
    function wellSkew(address asset) external view returns (uint256 skewWad);
    function swapFeePpm() external pure returns (uint24 feePpm);   // flat V4 pool tier (420 = 0.042%)
}
