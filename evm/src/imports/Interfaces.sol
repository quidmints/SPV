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



/// Canonical Vogue view — union of the former per-file variants (`VogueLib::IVogue_VG` +
/// `IVogueView_VG`), which split ONE contract's surface across two declarations so a signature
/// change had to be made twice and a missed one still compiled.
interface IVogue {
    function addLiq(uint deltaTok, uint price, bool isBTC) external returns (uint usdOut, uint outDelta);
    function derivedThetaWad(bool isBTC) external view returns (uint);
    function pendingRewards(address user) external view returns (uint ethReward, uint usdReward);
}

/// Canonical ether.fi RedemptionManager view — union of the former per-file variants
/// (`SwapLib::IRedeem_L`). `totalRedeemableAmount` takes the OUTPUT TOKEN, not a holder:
/// verified against the live implementation's bytecode (selector cf52e9f6).
interface IEtherFiRedemption {
    function redeemWeEth(uint weEthAmount, address receiver, address outputToken) external;
    function totalRedeemableAmount(address outputToken) external view returns (uint);
}

/// Canonical ether.fi LiquidityPool view — was `SwapLib::ILiq_L`.
interface IEtherFiLiquidityPool { function requestWithdraw(address r, uint a) external returns (uint); }

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

/// Canonical ILevEquityBtc — the BTC mirror of ILevEquity (BtcLevManager's per-LP book).
/// Union of the former `ILevEquityBtc` (Vault, all four) and `ILevBtc_V` (BtcVaultLib, the same set
/// minus `totalNetEquityBtc`) — a strict subset, so no signature moved. NOT mergeable into
/// `ILevEquity` despite the mirrored shape: every member is a distinct
/// selector on a distinct manager contract (BtcLevManager, sats/8-dec) — only `debtUsd` is shared,
/// and a single interface would let a caller reach a BTC read on the ETH manager (and vice versa).
interface ILevEquityBtc {
    function netEquityBtc(address lp) external view returns (uint256);   // 8-dec sats
    function totalNetEquityBtc() external view returns (uint256);        // 8-dec sats
    function grossCollateralBtc(address lp) external view returns (uint256); // full-2× band CAPACITY (sats)
    function debtUsd(address lp) external view returns (uint256);        // 1e18 USD (short-stable leg)
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

/// Canonical IAux — union of IAux, IAux.

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
/// Canonical Aux view — union of the former per-file variants (`IAux`, `IAux`,
/// `ChannelLib::IAux`, `BasketLib::IAux`, `QuidLens::IAux`). SIX declarations described
/// ONE contract; a signature change had to be made up to six times and a missed one still compiled.
interface IAux {
    function vaults(address) external returns (address);
    function tranche(address) external returns (uint);
    function take(address who, uint amount, address token, uint seed) external returns (uint);
    function take(address who, uint amount, address token, uint seed, address preferred) external returns (uint);
    function takeWith(address who, uint amount, address token, uint seed, address preferred, uint[15] memory amounts, uint[15] memory yieldW) external returns (uint);
    function riskFactor(address token) external view returns (uint);
    function getDepegSeverityBps(address token) external view returns (uint);
    function GHO() external view returns (address);
    function USDG() external view returns (address);
    function aaveBalance(address token) external view returns (uint);
    function aaveShares(address token) external view returns (uint);
    function withdrawAaveLeg(address stable, uint amount, address to) external returns (uint);
    function get_metrics(bool force) external returns (uint total, uint avgYield);
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
    function aaveReserveId(address stable) external view returns (uint256);
    function deposit(address from, address token, uint amount) external returns (uint);
    function avgYield() external view returns (uint);
    function vaultBlocked(address vault) external view returns (bool);
    function _tryPath(bytes calldata encodedPath, uint amountIn, address output, address recipient, uint minOut) external returns (uint);
    function toIndex(address token) external view returns (uint);
    function supplySelf(address token, uint amount) external returns (uint);
    function withdrawSelf(address token, uint amount, address to) external returns (uint);
    function checkBacking() external returns (uint committedSum, uint totalLiquid);
    function takeToSettle(address who, uint amount, address token) external returns (uint);
    function auxSwap(uint amountIn, address output, address recipient, uint minOut) external returns (uint);
    function WBTC() external view returns (address);
    function tokens(address vault) external view returns (address);
    function illiquidLoss() external view returns (uint);
    function _depositVol(bool isBTC, address sender, uint amount) external payable returns (uint sent);
    function tipSelf(uint cut, address token, int sign) external;
    function bumpVogueBTC(uint amount) external;
    function resolvedTwap(address asset, uint32 period) external view returns (uint price, bool stale);
    function vaultHealth(address) external view returns (bool blocked, uint40 flaggedAt);
    function trancheTotal() external view returns (uint);
    function refreshHoldingsSelf(address stable) external;
    function refreshAllHoldingsSelf() external;
    function reserveIdOf(address token) external view returns (uint256);
    function _withdrawAaveUnsafe(uint256 reserveId, uint amount, address to) external returns (uint);
    function tryCheckBacking() external returns (uint committedSum, uint totalLiquid);
}

/// Canonical ICore — union of ICore_V, ICore_VG.
/// Canonical Core view — union of the former per-file variants (`SwapLib::ICore`,
/// `SwapLib::ICore`, `BasketLib::ICore`). FOUR declarations described ONE contract, so a
/// signature change had to be made up to four times and any missed one still compiled.
interface ICore {
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    function modLP(bool isBTC, uint160 sqrtPriceX96, uint delta, uint deltaUSD, int24 tickLower, int24 tickUpper, address sender) external returns (uint);
    function outOfRange(bool isBTC, address sender, int liquidity, int24 tickLower, int24 tickUpper, address token) external returns (uint);
    function token1isBTC() external view returns (bool);
    function POOLED_BTC() external view returns (uint);
    function btcThetaBacking() external view returns (uint);
    function poolStats(int24 tickLower, int24 tickUpper, bool isBTC) external view returns (uint160 sqrtPriceX96, int24 currentTick, uint128 liquidity);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory);
    function observeBTC(uint32[] calldata secondsAgos) external view returns (int56[] memory);
    function POOLED_ETH() external view returns (uint);
    function premiumEwmaUsd(bool isBTC) external view returns (uint);
    function POOLED_USD_ETH() external view returns (uint);
    function POOLED_USD_BTC() external view returns (uint);
    function token1is(bool isBTC) external view returns (bool);
    function pendingSwapOutUsd() external view returns (uint);
    function levClaimUsd6(bool isBTC) external view returns (uint);
    function levGrossNative(bool isBTC) external view returns (uint);
    function flowEwmaUsd(bool isBTC) external view returns (uint);
    function realizedVarianceWad(bool isBTC) external view returns (uint);
    function recordSkewPremium(bool isBTC, uint256 premiumUsd) external;
    function refundUnfilled(address token, uint amount, address to) external;
    function repack(bool isBTC, uint128 myLiquidity, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, int24 newTickLower, int24 newTickUpper) external returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1);
    function reseat(bool isBTC, uint128 myLiquidity, uint160 currentSqrt, uint160 targetSqrt, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper) external returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1);
    function collectFees(int24 tickLower, int24 tickUpper, bool isBTC) external returns (uint, uint);
    function poolTicks(bool isBTC) external view returns (bytes32, uint160, int24);
    function token1isETH() external view returns (bool);
    function swap(bool isBTC, uint160 sqrtPriceX96, address sender, bool forOne, address token, uint amount) external returns (uint);
}

/// Canonical IEthVenue — the WHOLE external surface of `Vault`, not just its ETH-venue half.
/// Union of IEthVenue, IEthVenue_VG, IEthVenueCL and (2026-07) `IVaultCtx_V` (BtcVaultLib's
/// self-callback surface). The name is historical — `Vault` is the merged EthVenue+BtcVault, so
/// the BTC-band reads below live on the same address; it is NOT renamed to `IVault` only because
/// five consumers (Vogue, Aux, BasketLib, ChannelLib, VogueLib) would have to move with it.
///
/// WHY the BTC members belong here: the second declaration could not drift-detect. `IVaultCtx_V`
/// named Vault's own functions, so a return-shape change in Vault.sol would compile clean and
/// mis-decode at runtime in the delegatecalled library instead of failing the build.
interface IEthVenue {
    // ── BTC-band self-callbacks (delegatecall ⇒ address(this)==Vault; the extracted BtcVaultLib
    //    bodies drive the tick rebalance via Vault's public `repack` and read back the
    //    value-type fee accumulators, which cannot be handed over as storage refs) ──
    function repack(bool isBTC) external returns (uint160, int24, int24, uint128, uint);
    function feesPerShareBTC() external view returns (uint);
    function USD_FEES_BTC() external view returns (uint);
    function derivedThetaWadBtc() external view returns (uint);   // live BTC-band theta (asks Vogue w/ BTC ticks)
    function totalBufferBTC() external view returns (uint);       // aggregate debt-funded buffer (gross-consistency)
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

/// Canonical IAux — union of IAux, IAux.
