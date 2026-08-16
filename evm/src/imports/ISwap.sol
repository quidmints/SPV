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
    // SIZE IS MANDATORY. A `wellSkew(address)` returning the drain-0 rate was retired 2026-08-16:
    // settlement charges the INTEGRAL of the pole over the path the swap walks (§E68), so the
    // starting rate is the cheapest point on it — measured 1.11× understated at a 10% drain and
    // 4.12× at 90%. Since the defect WAS consumers reading a size-blind number, leaving one callable
    // preserved the mistake; `wellSkew(asset, 0)` still gives the indicative rate, but the caller has
    // to say they meant zero size. Inventory, not `L`, separates a full band from a drained one at
    // the same price, and a size-blind quote cannot express that difference at all.
    function wellSkew(address asset, uint256 drainUsd6) external view returns (uint256 skewWad);
    function swapFeePpm() external pure returns (uint24 feePpm);   // flat V4 pool tier (420 = 0.042%)
}
