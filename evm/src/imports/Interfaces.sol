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
/// Canonical Aave **v4** spoke view — union of the former per-file variants
/// (`AaveV4Venue::IAaveSpoke`). NOTE `getReserveId` is `view`: the two declarations DISAGREED on
/// mutability, and `view` is correct — four live call sites (`Aux`, `Vault`, `ChannelLib`) already
/// STATICCALL it in production. Aave **v3** is a DIFFERENT protocol with its own ABI
/// (`AaveV3Venue::IAaveV3Pool`/`IAaveV3DataProvider`, WBTC-only) and is deliberately NOT merged here.
interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);
    function setUsingAsCollateral(uint256 reserveId, bool useAsCollateral, address onBehalfOf) external;
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256);
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256);
    function getUserDebt(uint256 reserveId, address user) external view returns (uint256);
    // Risk config. `collateralRisk` is a CONFIG ID, not a risk magnitude -- it is the second argument to
    // getDynamicReserveConfig. Reading it as a number makes an ordinary reserve look unconfigured (0).
    function getReserveConfig(uint256 reserveId)
        external view returns (uint24 collateralRisk, bool paused, bool frozen, bool borrowable, bool receiveSharesEnabled);
    function getDynamicReserveConfig(uint256 reserveId, uint32 configId)
        external view returns (uint16 collateralFactor, uint32 maxLiquidationBonus, uint16 liquidationFee);
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
    function unwindForRedeem(uint usdWanted) external returns (uint usdFreed);  // E21: was BasketLib.IVogueUnwind
    function EV() external view returns (address);                              // E21: was BasketLib.IWiredVogue
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
    function totalDebtUsd() external view returns (uint256);          // §E21: was Core.ILevDebtTotal
}

/// §E21: was `Vogue.ILevClose`. Kept as its own interface rather than folded into
/// `ILevEquity` -- that one is a VIEW surface and this is a mutator.
interface ILevClose { function closeLevFor(address lp, uint256 minOut) external; }

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
    function totalGrossCollateralBtc() external view returns (uint256); // §E21: was Core.ILevGrossBtc
}

/// Canonical ILevHost — union of ILevHost, ILevHost_VG.
interface ILevHost {
    function LEV_MANAGER() external view returns (address);
}

/// Canonical ILevSyncHook — union of ILevSyncHook, ILevSyncHookB.
/// Canonical view — union of the former per-file variants (`ILevSyncHookM`). Two declarations
/// described ONE contract, so a signature change had to be made twice and a missed one still compiled.
interface ILevSyncHook {
    function syncLev(address lp) external;
    function soldFractionWad(uint160 entrySqrtP) external view returns (uint256);
    function bandSqrtP(bool isBTC) external view returns (uint160);
    function reseatEpoch() external view returns (uint64);
    function syncLevBTC(address lp) external;
}

/// Canonical ILevVenueColl — union of ILevVenueColl, ILevVenueCollB.
interface ILevVenueColl {
    function COLLATERAL() external view returns (address);
    function stable() external view returns (address);   // E21: was LevMath.ILevVenueVet
}

/// BOLD/Liquity venue mint-for-close surface -- the manager flashes WETH and draws BOLD at face
/// value from the venue's protocol trove. `usesMintClose` is the detection marker
/// `deleverFlashBody` reads to route un-flashable BOLD debt through flash-WETH->mint-BOLD.
/// (was LevMath.ILevMintVenueM)
interface ILevMintVenue {
    function usesMintClose() external view returns (bool);
    function mintForClose(uint256 wethIn, uint256 boldWanted) external returns (uint256 boldOut);
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
    /// Rule 2: declared HERE, not as a file-local restatement. `Aux.WETH` is a public
    /// `WETH9` state var; over the ABI that is an address, which is all any caller needs.
    function WETH() external view returns (address);
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
    /// §E21 — absorbed from the three per-file restatements (`LevMath.IAuxM`,
    /// `LevManager.ISwapAux`, `FeeLib.IAuxFee`). ⚠️ `sorSelfFundedReverse` takes FOUR
    /// arguments; `ISwapAux` declared THREE. It was never called through that handle, so
    /// the wrong selector never fired — which is exactly why a per-file restatement is
    /// dangerous: it drifts silently and only breaks the first time someone uses it.
    function redeem(uint amount) external;
    function swap(address token, address asset, bool forVolatile, uint amount, uint minOut) external returns (uint);
    function sorSelfFunded(address sourceAsset, uint amountIn, address output, uint minOut) external returns (uint);
    function sorSelfFundedReverse(address sourceVol, address targetStable, uint amountIn, uint minOut) external returns (uint);
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
    function observe(uint32[] calldata secondsAgos, bool isBTC) external view returns (int56[] memory);
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
    function btcVault() external view returns (address);   // E21: was BasketLib.IWiredCore
    /// §E56 — the MONOTONIC (never-decayed) retained-premium counters. Their value here is NOT the
    /// amount: it is that they are CUMULATIVE, which makes them the liveness signal a decayed EWMA
    /// cannot be. `flow == 0` is ambiguous between a DEAD pool and a NEW one; `skewPremium > 0`
    /// resolves it, because a pool that has never traded cannot have accrued any.
    function skewPremiumCum(bool isBTC) external view returns (uint);
    /// §E59 — realized tick variance from the STORED observations (per-second, WAD) + the measured
    /// span. Reads the RING, so it never sees observe()'s interpolation, which used to manufacture
    /// zeros in any stretch quieter than the old wall-clock sample grid. span 0 = UNKNOWN, not calm.
    /// §E53 — the BTC band's equity alone. With committedUsd18() (the SUM) this yields the OTHER
    /// band's share of the one bound both compete for, which is what the shared-scarcity amplifier
    /// needs and what no isBTC-scoped input could ever supply.
    function btcBandEquityUsd18() external view returns (uint);
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
/// Canonical view — union of the former per-file variants (`IEthVenueV`). Two declarations
/// described ONE contract, so a signature change had to be made twice and a missed one still compiled.
interface IEthVenue {
    function repack(bool isBTC) external returns (uint160, int24, int24, uint128, uint);
    function feesPerShareBTC() external view returns (uint);
    function USD_FEES_BTC() external view returns (uint);
    function derivedThetaWadBtc() external view returns (uint);
    function totalBufferBTC() external view returns (uint);
    function vogueETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function GALAXY_VAULT() external view returns (address);
    function EULER_VAULT() external view returns (address);
    function GAUNTLET_VAULT() external view returns (address);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function btcChannels() external view returns (address);
    function evacuateVenue(address vault) external;
    function venuePosition(address vault) external view returns (uint reported, uint liquid);
    function vogueOp(bool isBTC, uint amount, uint8 op, bytes32 ctx) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);
    function supplyAaveEth(uint amount) external returns (uint);
    function supplyEulerEth(uint amount) external returns (uint);
    function supplyGauntlet(uint amount) external returns (uint);
    function offrampEtherFi(uint amount, address recipient, bool instant) external returns (uint);
}

/// Canonical IAux — union of IAux, IAux.

/// @notice §E5 — the per-band sink that routes a retained scarcity premium into that band's LP
///         fee accumulator. Implemented by BOTH `Vogue` (ETH) and `Vault` (BTC) under the SAME
///         signature so `Core.recordSkewPremium` dispatches by ADDRESS through one call site.
/// E21 -- the last of the per-file restatements, homed here so there is ONE declaration each.
/// `IBTCChannels` absorbed `SwapLib.IBtcChan2`, a byte-identical second copy under the
/// numeric-suffix spelling of the very `IFoo_` pattern rule 2 bans.
interface IBTCChannels { function btcRecipientOf(address user) external view returns (bytes32); }

interface IBtcVault {
    function repack(bool isBTC) external returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity);
    function setBTCChannels(address b) external;
}

/// G.6 redeem shortfall sweep: the ETH LevManager's ONE reactive de-lever entry (SHARED with
/// swap-out). Frees levered net-equity into the sink value-neutrally. (was BasketLib.ILevSweepB)
interface ILevSweep { function deleverBook(uint256 usdWanted, address sink, uint256 minOut) external returns (uint256 freed); }

/// Deploy-finalize linkage cross-check on the BASKET. Kept as its own interface rather than folded
/// into `IAux`: `AUX()` is a getter ON Basket, so hanging it off the Aux surface would have made the
/// canonical file assert a member Aux does not have — the compiler caught exactly that.
interface IWiredBasket { function AUX() external view returns (address);
                         function BTC_VAULT() external view returns (address); }

/// Deploy-finalize linkage cross-check on the Vault (BasketLib.assertFullyWired).
interface IWiredVault { function btcChannels() external view returns (address);
                        function LEV_MANAGER() external view returns (address); }

/// Canonical Basket turn/maturity view (was BasketLib.IBasketTurn, itself already a union of two
/// earlier per-file variants).
interface IBasketTurn {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
    function immatureBalanceOf(address who) external view returns (uint);
}
interface IBasketMint { function mint(address pledge, uint amount, address token, uint when) external returns (uint); }
interface IQuidTarget { function target() external view returns (uint); }

/// BTC swap-out de-lever surface on the BTC LevManager. (was SwapLib.ILevManagerDeliver)
interface ILevManagerDeliver {
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external returns (uint usedUsd, uint freedSats);
}
/// M.1 ETH delivery-side de-lever. Distinct from BTC's `swapOutDelever` (ETH DELIVERS WETH to a
/// recipient; BTC un-encumbers spliced sats), and ETH is POOLED so it walks the book.
/// (was SwapLib.ILevEthDeliver)
interface ILevEthDeliver {
    function openLevCount() external view returns (uint);
    function openLpAt(uint i) external view returns (address);
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, address recipient, uint minWethOut)
        external returns (uint usedUsd, uint wethDelivered);
    function swapOutDeliverUnlevered(address lp, uint wethWanted, address recipient, uint minWethOut)
        external returns (uint wethDelivered);
}

/// E21 (final) -- the last per-file declarations of OUR OWN contracts, homed here. `IAuxBacking`
/// is gone entirely: `IAux.vogueETH()` already said the same thing.
interface IVogueShares {
    function lpShares() external view returns (uint);
    function balanceOf(address user) external view returns (uint);
    function convertToShares(uint assets) external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
    /// (§J.2c) The ONLY external door to Vogue's `_transferShares`, gated to this contract.
    function transferSharesFor(address from, address to, uint amount) external;
}

interface IBtcVaultBridge {
    // BTC LP position: open/close/splice (driven on channel open/close).
    function registerBtcLp(address lpEth, uint sats) external;
    function unregisterBtcLp(address lpEth, uint lpPayoutSats) external;
    function settleBtcFeesOwed(address lpEth, uint sats) external; // clear owed BTC-leg fees paid into a splice
    // `exactUsd` > 0 ⇒ on-chain swap-out delivery (pay the LP that exact proceeds);
    // 0 ⇒ LP-withdrawal splice-out (all native).
    function resizeBtcLp(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd) external;
    // BTC↔USD swap settlement (the swap-IN credit + on-curve swap-OUT buy).
    function creditSwapIn(address seller, uint sats, address token, uint minDeliveredUsd) external returns (uint consumedSats);
    function creditSwapOut(address swapper, address token, uint usdAmount, uint minSats)
        external returns (uint sats, uint usd6);
    // Record / clear an on-chain swap-out obligation's USD in pendingSwapOutUsd.
    function addPendingSwapOut(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
}

interface IVaultExposeB {
    function exposeBtcToLev(address lp, uint sats) external returns (bool);
    function unexposeBtcFromLev(address lp, uint sats) external returns (bool);
}

interface IVBtcToken { function VAULT() external view returns (address); }

interface ISkewSink { function creditSkewPremium(uint premium6) external; }
