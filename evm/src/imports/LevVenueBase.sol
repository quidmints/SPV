// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILevVenue} from "./ILevVenue.sol";

/// Minimal ERC20 surface shared by both weETH lending-venue adapters.
interface ILevERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title  LevVenueBase — shared scaffolding for the per-LP-isolated weETH lending adapters
/// @notice `EulerEscrowVenue` and `MorphoEscrowVenue` differ ONLY in the venue's isolation mechanism (EVC
///         sub-accounts vs Morpho `onBehalf`) and its borrow/repay/withdraw calls. Everything else — the
///         `MANAGER`-only auth, the reentrancy guard, the `stable()` accessor, the custody convention — is
///         identical and lives here. (`SorExchange` is NOT unified in: it's the adapter for a SEPARATE,
///         live product — the optional Liquity-V2 ~10x directional long (BOLD into the Stability Pool, or
///         WETH into the venues), still wired in the UI. Different protocol + BOLD/WETH collateral, so it
///         can't be a weETH `ILevVenue` — a distinct product, NOT a deprecated path.)
abstract contract LevVenueBase is ILevVenue {
    address public immutable MANAGER;   // the only caller (LevManager)
    address public immutable STABLE;    // the debt asset this venue lends

    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyManager() { require(msg.sender == MANAGER, "auth"); _; }

    constructor(address manager, address stable_) { MANAGER = manager; STABLE = stable_; }

    function stable() external view returns (address) { return STABLE; }
}
