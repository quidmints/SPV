// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// `IERC20Min` was declared here: a strict SUBSET of `IERC20Min` (4 of its members, identical
// signatures) — the same rule-2 violation `IERC20Min` records already absorbing once, from Core.
import {ILevVenue, IERC20Min} from "./ILevVenue.sol";

/// Minimal ERC20 surface shared by both weETH lending-venue adapters.

/// @title  LevVenueBase — shared scaffolding for the per-LP-isolated lending adapters
/// @notice What is ACTUALLY shared lives here and is small: the `MANAGER`-only auth, the reentrancy
///         guard, the `stable()` accessor and the custody convention.
///
/// ⚠️ THIS HEADER USED TO SAY THE TWO ADAPTERS "differ ONLY in the venue's isolation mechanism".
///    TRUE, AND MISLEADING — measured 2026-08-15. The isolation mechanism IS THE BODY OF EVERY
///    FUNCTION, so they share a six-function SHAPE and NO CODE:
///      • `supply`  — Morpho: `approve` + `supplyCollateral(_params(), amt, lp, "")`, `onBehalf = lp`.
///                    Aave:   lazily `new AaveV3Escrow(...)`, transfer to it, `e.supplyColl(amt)`.
///      • `borrow`  — Morpho: `isAuthorized(lp, this)` then debit the LP directly.
///                    Aave:   route through the per-LP escrow handle.
///    ⇒ Hoisting them into an abstract with six abstract members SAVES ZERO BYTECODE. Do not read
///    this file as evidence that a dedup is available; it was read that way once and the dedup was
///    refused on measurement (task #48). Nor is `AaveV3Venue` deletable in favour of a Morpho WBTC
///    market: `DeployL1_s.sol:93` keeps it on a DEPTH measurement (deepest WBTC/USDC book), which is
///    a REAL asymmetry, not drift.
///
///         (`SorExchange` is NOT unified in either, for a DIFFERENT and stronger reason: it is the
///         adapter for a SEPARATE, LIVE product — the optional Liquity-V2 ~10x directional long (BOLD
///         into the Stability Pool, or WETH into the venues), still wired in the UI. Different
///         protocol + BOLD/WETH collateral, so it cannot be a weETH `ILevVenue`. ⛔ A DISTINCT
///         PRODUCT, NOT A DEPRECATED PATH — do not delete it as an unmerged straggler.) (`SorExchange` is NOT unified in: it's the adapter for a SEPARATE,
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
