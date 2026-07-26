// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Shared token surfaces for the whole leverage cluster (LevManager / LevMath / BtcLevManager) — was three
/// byte-identical ERC-20 slices (IERC20Min / IErc20M / IERC20B) + three WETH slices. One each now.
interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}
interface IWETH9 { function deposit() external payable; function withdraw(uint256) external; }

/// @title  ILevVenue — per-LP isolated borrow-venue adapter for the leverage overlay
/// @notice Each LP's leverage lives in its OWN isolated position on the venue (the LP is the venue
///         account / borrower); `LevManager` orchestrates the constant-LTV logic venue-agnostically
///         through this interface, so one LP's liquidation can never cascade into a shared pile. The
///         adapter owns the per-venue isolation mechanism (Morpho authorization, a per-LP Liquity Trove,
///         Aave/Euler sub-account) and the HARD risk params (liq threshold, oracle) — those are NOT
///         abstracted away. Collateral is weETH (ether.fi, staked not lent); the borrowed asset is `stable()`.
///
///         Custody convention: `LevManager` transfers the collateral/stable to the adapter before
///         `supply`/`repay`, and the adapter transfers withdrawn collateral / borrowed stable back to
///         `LevManager` (the caller). All amounts are the venue asset's own units (weETH = 1e18,
///         `stable()` in its own decimals); USD valuation/LTV is computed in `LevManager`.
interface ILevVenue {
    /// @notice Supply `collAmount` weETH (already transferred in) as `lp`'s isolated collateral.
    /// @return supplied weETH actually credited to `lp`'s position.
    function supply(address lp, uint256 collAmount) external returns (uint256 supplied);

    /// @notice Borrow `stableAmount` of `stable()` against `lp`'s isolated position; sends it to the caller.
    /// @return borrowed `stable()` actually drawn.
    function borrow(address lp, uint256 stableAmount) external returns (uint256 borrowed);

    /// @notice Repay `stableAmount` of `lp`'s debt (the stable was already transferred in). Repays at most
    ///         the outstanding debt; the caller (`LevManager._deleverChunk`) clamps the transfer IN to the
    ///         current debt, so no cross-LP excess is ever left sitting on the adapter.
    /// @return repaid `stable()` actually applied to debt.
    function repay(address lp, uint256 stableAmount) external returns (uint256 repaid);

    /// @notice Withdraw `collAmount` weETH of `lp`'s collateral to the caller (capped at the position).
    /// @return withdrawn weETH actually returned.
    function withdraw(address lp, uint256 collAmount) external returns (uint256 withdrawn);

    /// @notice `lp`'s outstanding `stable()` debt, in `stable()` units.
    function debtOf(address lp) external view returns (uint256);

    /// @notice `lp`'s weETH collateral balance on the venue, in weETH (1e18) units.
    function collateralOf(address lp) external view returns (uint256);

    /// @notice The stablecoin this venue lends (the debt asset).
    function stable() external view returns (address);

    /// @notice Venue liquidation threshold in bps of collateral value (e.g. 8000 = 80% LLTV).
    function liqThresholdBps() external view returns (uint256);
}
