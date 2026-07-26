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

/// Canonical ILevEquity — union of ILevEquity, ILevEquity_V, ILevEquity_VG.
interface ILevEquity {
    function totalGrossCollateralEth() external view returns (uint256);
    function totalNetEquityEth() external view returns (uint256);
    function netEquityEth(address lp) external view returns (uint);
    function grossCollateralEth(address lp) external view returns (uint);
    function debtUsd(address lp) external view returns (uint);
}

/// Canonical ILevHost — union of ILevHost, ILevHost_VG.
interface ILevHost {
    function LEV_MANAGER() external view returns (address);
}

/// Canonical ILevSyncHook — union of ILevSyncHook, ILevSyncHookB.
interface ILevSyncHook {
    // Vogue.syncLev — reconcile the LP's levered band slice to its (now-changed) net-equity
    function syncLev(address lp) external;
    function soldFractionWad(uint160 entrySqrtP) external view returns (uint256);
    // (B) actual sold fraction (LONG)
    function bandSqrtP(bool isBTC) external view returns (uint160);
    // band spot √P at open
    function reseatEpoch() external view returns (uint64);
    function syncLevBTC(address lp) external;
}

/// Canonical ILevVenueColl — union of ILevVenueColl, ILevVenueCollB.
interface ILevVenueColl {
    function COLLATERAL() external view returns (address);
}

/// Canonical IAuxTwap — union of IAuxTwap, IAuxTwap.
interface IAuxTwap {
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint256);
    function resolvedTwap(address asset, uint32 period) external view returns (uint price, bool stale);
}

/// Canonical ICollection — union of ICollection, ICollection.
interface ICollection {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getApproved(uint tokenId) external view returns (address);
}

/// Canonical IAggregatorV3 — union of IAggregatorV3, IAggregatorV3.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns ( uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// Canonical IAux — union of IAux, IAux_VG.
interface IAux {
    function vaults(address) external returns (address);
    function tranche(address) external returns (uint);
    function take(address who, uint amount, address token, uint seed) external returns (uint);
    /// @notice Targeted-draw redemption overload: `preferred` (a basket stable,
    ///         or address(0) for pure pro-rata) is drawn FIRST, then the remainder
    ///         pro-rata. Mirrors the swap path's named-stable branch; the cherry-
    ///         pick concentration fee rides along on the preferred leg.
    function take(address who, uint amount, address token, uint seed, address preferred) external returns (uint);
    /// @notice take() with pre-fetched deposit vectors (redeem dedup): skips a second
    ///         get_deposits by reusing the haircut-pass fetch. See Aux.takeWith.
    function takeWith(address who, uint amount, address token, uint seed, address preferred, uint[15] memory amounts, uint[15] memory yieldW) external returns (uint);
    /// @notice Per-stable yield-factor in basis points (10000 = no
    /// adjustment). Applied as a multiplier on yieldWeighted in
    /// get_deposits — routes the depeg-market signal through the
    /// basket's time-averaged yield rather than the mint-time discount
    /// path. Defined on Aux, read here.
    function riskFactor(address token) external view returns (uint);
    function getDepegSeverityBps(address token) external view returns (uint);
    /// @notice AAVE-routed stables (GHO, USDG): live asset-denominated
    /// balance held by Aux on the AAVE v4 spoke. get_deposits uses this
    /// for both AAVE-routed stables; the rest of the basket uses
    /// IERC4626(vault).convertToAssets.
    function GHO() external view returns (address);
    function USDG() external view returns (address);
    function aaveBalance(address token) external view returns (uint);
    function aaveShares(address token) external view returns (uint);
    /// @notice Self-gated dual-venue (USDC/USDT) Aave-leg withdraw. Called by
    ///         multiVaultWithdrawBody via the library delegatecall (msg.sender
    ///         == Aux). Mirrors the 4626 redeem leg for the spoke member.
    function withdrawAaveLeg(address stable, uint amount, address to) external returns (uint);
    function get_metrics(bool force) external returns (uint total, uint avgYield);
    /// @notice get_metrics(true) with pre-fetched totals (redeem dedup): recomputes the
    ///         par-backing metric from the caller's already-fresh get_deposits pass
    ///         instead of a second internal scan. See Aux.get_metricsWith.
    function get_metricsWith(uint raw, uint yieldWeighted) external returns (uint total, uint avgYield);
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint);
    function vogueETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function get_deposits() external returns (uint[15] memory amounts, uint[15] memory yieldW, uint avgYield, uint depegLoss);
    function getStables() external view returns (address[] memory);
    function getVaults(address stable) external view returns (address[] memory);
    function AAVE_SPOKE() external view returns (address);
    function ethVenue() external view returns (address);
    function GHO_RESERVE_ID() external view returns (uint256);
    function USDG_RESERVE_ID() external view returns (uint256);
    /// @notice Generalized Aave-v4 reserve-id for dual-venue stables (USDC/USDT);
    ///         0 for stables with no Aave leg. (GHO/USDG use the immutables above.)
    function aaveReserveId(address stable) external view returns (uint256);
    function deposit(address from, address token, uint amount) external returns (uint);
    function avgYield() external view returns (uint);
}

/// Canonical ICore — union of ICore_V, ICore_VG.
interface ICore {
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    function modLP(bool isBTC, uint160 sqrtPriceX96, uint delta, uint deltaUSD, int24 tickLower, int24 tickUpper, address sender) external returns (uint);
    function outOfRange(bool isBTC, address sender, int liquidity, int24 tickLower, int24 tickUpper, address token) external returns (uint);
    function token1isBTC() external view returns (bool);
    function POOLED_BTC() external view returns (uint);
    // GROSS BTC band depth (theta cap denominator)
    function btcThetaBacking() external view returns (uint);
    function poolStats(int24 tickLower, int24 tickUpper, bool isBTC) external view returns (uint160 sqrtPriceX96, int24 currentTick, uint128 liquidity);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory);
    function observeBTC(uint32[] calldata secondsAgos) external view returns (int56[] memory);
    function POOLED_ETH() external view returns (uint);
    // θ numerator inputs (#107/D3) — retained band premium as a decayed rate, over the band's own
    // in-range USD. Both 6-dec, so `_bandFeeYieldWad` needs no scale conversion.
    function premiumEwmaUsd(bool isBTC) external view returns (uint);
    function POOLED_USD_ETH() external view returns (uint);
    function POOLED_USD_BTC() external view returns (uint);
}

/// Canonical IEthVenue — union of IEthVenue, IEthVenue, IEthVenue_VG, IEthVenueCL.
interface IEthVenue {
    function vogueETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function GALAXY_VAULT() external view returns (address);
    function EULER_VAULT() external view returns (address);
    function GAUNTLET_VAULT() external view returns (address);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function ROVER() external view returns (address);
    function btcChannels() external view returns (address);
    function evacuateVenue(address vault) external;
    function venuePosition(address vault) external view returns (uint reported, uint liquid);
    function vogueOp(bool isBTC, uint amount, uint8 op, bytes32 ctx) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);
    function supplyAaveEth(uint amount) external returns (uint);
    function supplyEulerEth(uint amount) external returns (uint);
    function supplyGauntlet(uint amount) external returns (uint);
    function supplyEtherFiToRover(uint amount) external returns (uint);
}

/// Canonical IAuxSwap — union of IAuxSwap, IAuxSwap.
interface IAuxSwap {
    function _tryPath(bytes calldata encodedPath, uint amountIn, address output, address recipient, uint minOut) external returns (uint);
    function toIndex(address token) external view returns (uint);
    function get_deposits() external returns (uint[15] memory amounts, uint[15] memory yieldW, uint avgYield, uint depegLoss);
    function supplySelf(address token, uint amount) external returns (uint);
    function withdrawSelf(address token, uint amount, address to) external returns (uint);
    function checkBacking() external returns (uint committedSum, uint totalLiquid);
    function takeToSettle(address who, uint amount, address token) external returns (uint);
    // soft-backing settle drain
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint);
    function auxSwap(uint amountIn, address output, address recipient, uint minOut) external returns (uint);
    function deposit(address from, address token, uint amount) external returns (uint usd);
    function WBTC() external view returns (address);
    // ── merged from the former IAuxSwap (same Aux self-delegatecall target) ──
    function tokens(address vault) external view returns (address);
    function tranche(address token) external view returns (uint);
    function get_metricsWith(uint raw, uint yieldWeighted) external returns (uint total, uint avgYield);
    function illiquidLoss() external view returns (uint);
    function _depositVol(bool isBTC, address sender, uint amount) external payable returns (uint sent);
    function tipSelf(uint cut, address token, int sign) external;
    function bumpVogueBTC(uint amount) external;
}
