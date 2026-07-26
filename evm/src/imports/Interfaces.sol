// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  Interfaces — the ONE declaration site for external ABIs shared across the tree.
///
/// @notice STANDING RULE: one declaration per interface. Before this file the same external ABI was
///         re-declared per consumer with a per-file suffix (`_V`, `_VG`, `_L`, `CL`, `B`), each a
///         DISJOINT SUBSET of the same contract — `IAaveV4Spoke` alone existed 5× across `Aux`,
///         `Vault`, `VaultLib`, `BasketLib` and `ChannelLib`, no two listing the same functions.
///         That is pure drift surface: a signature fixed in one copy stays wrong in the other four,
///         and a reader cannot tell whether the subsets disagree on purpose.
///
///         Consolidating is FREE. An interface emits ZERO bytecode — it only informs the compiler how
///         to encode a call — so importing the full ABI instead of a hand-picked subset cannot move a
///         contract's EIP-170 size. (Verified against the razor-thin margins this tree runs at:
///         `LevManager` has 70 bytes of headroom and `SwapLib` 295, and both are unchanged by this.)
///         Every merge here is a strict UNION of previously-declared members with byte-identical
///         signatures, so no call encoding changes.
library Interfaces {}   // no code — this file exists purely to host the declarations below

/// Aave v4 spoke. Union of the five former variants: `IAaveV4Spoke` (Aux, Vault, BasketLib),
/// `IAaveV4Spoke_V` (VaultLib), `IAaveV4SpokeCL` (ChannelLib).
interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    /// Scaled (principal-basis) supply shares — the Aave-v4 analog of a 4626's share balance.
    /// `suppliedAssets/suppliedShares` is the reserve's liquidity index = its cumulative yield factor
    /// (same role as 4626 share price).
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);
}

/// Canonical IWeETH — union of the former per-file variants.
interface IWeETH {
    function getEETHByWeETH(uint _weETHAmount) external view returns (uint);
    function getWeETHByeETH(uint _eETHAmount) external view returns (uint);
    function unwrap(uint _weETHAmount) external returns (uint); // weETH → eETH
}

/// Canonical IRover — union of the former per-file variants.
interface IRover {
    function deposit(uint amount) external payable;
    function take(uint amount) external returns (uint wethAmount);
    function valueWeth() external view returns (uint); // WETH-equiv of the Rover's holdings
    function setLevManager(address lm) external;       // pin the LevManager as an allowed Rover.absorb caller
}

/// Canonical IDepositAdapter — union of the former per-file variants.
interface IDepositAdapter {
    function depositWETHForWeETH(uint _amount, address _referral) external;
    function weETH() external view returns (address);
}

/// Canonical IAaveV4Hub — union of the former per-file variants.
interface IAaveV4Hub {
    function getAssetId(address underlying) external view returns (uint256);
}

/// Canonical IMorphoFlash — union of the former per-file variants.
interface IMorphoFlash {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}
