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
// §BANDBACKING-FOLD — `IBandBacking` DELETED, along with the contract it described. Its members
// moved onto `Aux` (`report`, `committedTotal`), which is where the gate that consumes them already
// lives; `otherThan` was dropped rather than moved, having had no callers. Note this interface was
// declared in TWO places — here and again in Core.sol — which is exactly what the warning below was
// written about, and which standing rule 2 exists to prevent.
//
// ⚠️ KEEP THE WARNING, it outlives the interface: a duplicate interface surfaces as forge's
// `Error writing output JSON`, NOT as a redeclaration error — the message points at the wrong layer
// entirely, and it has cost this repo hours on two separate days.

library Interfaces {}   // no code — this file exists purely to host the declarations below

/// Aave v4 spoke. Union of the five former variants: `IAaveV4Spoke` (Aux, Vault, BasketLib),
/// `IAaveV4Spoke_V` (VaultLib), `IAaveV4SpokeCL` (ChannelLib).
/// Canonical Aave **v4** spoke view — union of the former per-file variants
/// (formerly also `AaveV4Venue::IAaveSpoke`, removed 2026-08-13). NOTE `getReserveId` is `view`: the declarations DISAGREED on
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
    function addLiq(uint deltaTok, uint price) external returns (uint usdOut, uint outDelta);
    function unwindForRedeem(uint usdWanted) external returns (uint usdFreed);  // E21: was BasketLib.IVogueUnwind                              // E21: was BasketLib.IWiredVogue
    function derivedThetaWad() external view returns (uint);
    function pendingRewards(address user) external view returns (uint ethReward, uint usdReward);
}

/// Curve `weETH/WETH-ng` (0xdb74dfdd…). ⚠️ THE `int128` SIGNATURE IS THE ONE THIS POOL ANSWERS — the
/// uint256 `-ng` variant REVERTS on it (verified live 2026-08-09). coin0 = WETH, coin1 = weETH.
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    /// @dev Coin balances. Read for a CAPACITY decision only — never to size a tolerance. A live balance
    ///      read is sound for capacity because shrinking is monotone in the safe direction (an attacker who
    ///      REMOVES WETH shrinks us further; one who ADDS improves the fill), and unsound for a tolerance,
    ///      where the same manipulation WIDENS the guard exactly when it needs to hold.
    function balances(uint256 i) external view returns (uint256);
}

// Curve TriCryptoUSDC — the ONLY external route to WETH/WBTC. VERIFIED LIVE 2026-08-15 on mainnet:
//   coins(0)=USDC 0xA0b8…eB48 · coins(1)=WBTC 0x2260…C599 · coins(2)=WETH 0xC02a…6Cc2
//   get_dy(0→2, 10_000 USDC) = 5.293e18   (~$1,889/ETH)
//   get_dy(0→1, 10_000 USDC) = 1.584e7 sats (~$63.1k/BTC)
// The ORDERING was read from the chain, not assumed — a wrong index swaps the wrong pair at size and
// there is no id to assert against, unlike the Morpho markets.
// (Plain `//`, not NatSpec — solc rejects @notice/@dev on file-level variables.)
address constant CURVE_TRICRYPTO_USDC = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;
uint256 constant TRICRYPTO_USDC_IDX = 0;
uint256 constant TRICRYPTO_WBTC_IDX = 1;
uint256 constant TRICRYPTO_WETH_IDX = 2;

// Stableswap legs: the borrowed stable → USDC, before TriCrypto takes USDC → WETH/WBTC.
// 🔴 THE TWO POOLS ARE ORDERED OPPOSITELY. Read from mainnet 2026-08-15:
//     0xD001aE43…  coins(0)=USDC  coins(1)=RLUSD   ⇒ RLUSD is 1, USDC is 0
//     0x383E6b44…  coins(0)=PYUSD coins(1)=USDC    ⇒ PYUSD is 0, USDC is 1
// A SHARED index constant would therefore be silently wrong for one of them — wrong-pair swap at
// size, no revert, no id to assert against. Each pool carries its own pair of indices for that reason.
// Token handles for the routing branch (the basket's own stables; USDC is TriCrypto's coin 0).
// USDC — the stable ROUTING HUB. §SCRUB (2026-08-16): was `CURVE_TRICRYPTO_USDC_TOKEN`, which named
// it after a pool it has nothing to do with — it is used as the hub in `_toUsdc`/`_fromUsdc`/
// `_routableStable`, where no TriCrypto is involved. The genuine TriCrypto names below are the POOL
// and its coin indices, and those stay. Also the ONE declaration (rule 2): `SOR.USDC_HUB` was a
// second private copy of this same address.
// (`///` is a DOC tag; solc rejects it on a file-level variable, so these are plain `//`.)
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant RLUSD_TOKEN                = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
address constant PYUSD_TOKEN                = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
address constant CURVE_USDC_RLUSD      = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
int128  constant CRV_RLUSD_IDX         = 1;
int128  constant CRV_RLUSD_USDC_IDX    = 0;
address constant CURVE_PYUSD_USDC      = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
int128  constant CRV_PYUSD_IDX         = 0;
int128  constant CRV_PYUSD_USDC_IDX    = 1;

/// @notice Curve crypto-swap (TriCrypto). Uniswap is gone from every leg: stable→stable goes through
///         the stableswap pools via `ICurvePool` (int128), stable→volatile through this one (uint256).
/// @dev    🔴 A SEPARATE INTERFACE, NOT AN OVERLOAD ON `ICurvePool`, DELIBERATELY. Curve's two families
///         encode indices differently — stableswap `int128`, crypto-swap `uint256` — and calling the
///         wrong one REVERTS (CLAUDE.md records the uint256 variant reverting on the weETH/WETH ng
///         pool). Overloading both on one interface would let a caller pick the wrong ABI by
///         integer-literal inference. Two named types make the choice explicit, and reverting is the
///         SAFE failure: a mis-encoded index would otherwise swap the wrong pair.
interface ICurveTriCrypto {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
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

/// Canonical ILevEquity — ONE interface over BOTH lev managers. Union of ILevEquity, ILevEquity_V,
/// ILevEquity_VG and the former `ILevEquityBtc`/`ILevBtc_V`.
///
/// §LEV-FOLD-2 — THE BTC MIRROR IS GONE, AND THE GUARD IT PROVIDED IS NOT. The old note here said
/// these were "NOT mergeable ... a single interface would let a caller reach a BTC read on the ETH
/// manager (and vice versa)", and that was TRUE: distinct selectors made a wrong-manager call
/// REVERT rather than quietly return the other band's book, which matters in a tree that has
/// shipped three address-confusion bugs of that shape in one session.
///
/// But that is a CLAMP -- it catches the mis-assignment once per call, forever, and only if the
/// caller happens to use the suffixed accessor. The state it was detecting is now
/// UNCONSTRUCTIBLE instead: `setLevManager` refuses any manager whose `ORACLE_KEY` is not the
/// pinning band's own asset, so a BTC manager cannot be pinned to the ETH band at all and there is
/// no wrong-manager handle for a caller to hold. Standing rule 17 — a root fix makes the previous
/// guard DELETABLE, which is exactly the test for whether it was a fix or a clamp.
///
/// UNITS ARE PER INSTANCE, not per interface: `netEquity`/`grossCollateral` are 1e18 ETH on the
/// ETH manager and 8-dec sats on the BTC one. The MEANING is identical, which is why one name
/// serves both — the same argument `LevBase.netEquity` already records.
interface ILevEquity {
    /// The band asset this manager prices against — WETH or WBTC. The identity `setLevManager`
    /// checks, and the reason a wrong-band pin cannot be built.
    function ORACLE_KEY() external view returns (address);
    function totalGrossCollateral() external view returns (uint256);
    function totalNetEquity() external view returns (uint256);
    function netEquity(address lp) external view returns (uint);
    function grossCollateral(address lp) external view returns (uint);
    function debtUsd(address lp) external view returns (uint);
    function totalDebtUsd() external view returns (uint256);          // §E21: was Core.ILevDebtTotal
}

/// §E21: was `Vogue.ILevClose`. Kept as its own interface rather than folded into
/// `ILevEquity` -- that one is a VIEW surface and this is a mutator.
interface ILevClose { function closeLevFor(address lp, uint256 minOut) external; }


/// Canonical ILevHost — union of ILevHost, ILevHost_VG.
interface ILevHost {
    function LEV_MANAGER() external view returns (address);
}

/// Canonical ILevSyncHook — union of ILevSyncHook, ILevSyncHookB.
/// Canonical view — union of the former per-file variants (`ILevSyncHookM`). Two declarations
/// described ONE contract, so a signature change had to be made twice and a missed one still compiled.
interface ILevSyncHook {
    /// §SLOP — ONE NAME. This interface declared BOTH `syncLev` and `syncLev` for the same
    /// operation, so the two bands could not be called through one method even though the
    /// interface existed precisely to make that possible. The interface IS the polymorphism;
    /// a second name for the same call defeats it.
    function syncLev(address lp) external;
    function soldFractionWad(uint entryPrice) external view returns (uint256);
    function bandPrice() external view returns (uint);
    // Band bounds. These replace the former `reseatEpoch()` counter as the re-anchor signal: the counter and
    // the ticks are written in the same statement pair (Vogue:1137-1138, Vault:711-712), so the bounds carry
    // the same information AND strictly more of it -- a reseat that leaves an anchor inside the new range
    // bumped the counter but needs no re-anchor. All four are auto-generated getters for existing public
    // state (Vogue:92-93, Vault:214-215); no new contract code implements them.
    function LOWER_PRICE() external view returns (uint);
    function UPPER_PRICE() external view returns (uint);
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

// Uniswap V3 SwapRouter02. Plain `//`, not NatSpec — solc rejects @notice/@dev on file-level variables.
address constant V3_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

/// @notice Uniswap V3 SwapRouter02 — the SOR's multi-hop route. Callers here only INITIATE swaps, so
///         `IUniswapV3SwapCallback` (implemented by pools) is deliberately not inherited.
interface IV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// Canonical IAux — union of IAux, IAux_VG.
/// Canonical Aux view — union of the former per-file variants (`IAux`, `IAux`,
/// `ChannelLib::IAux`, `BasketLib::IAux`). FIVE declarations described
/// ONE contract; a signature change had to be made up to six times and a missed one still compiled.
interface IAux {
    /// @dev The per-asset price-feed registry. Its EMPTINESS is the honest discriminator for "this token
    ///      is a dollar stable, worth par": a basket stable has no feed, a real asset (WETH/WBTC) does.
    ///      Used instead of naming WETH, which would re-open on the next non-dollar loan token.
    function assetPriceFeed(address asset) external view returns (address);
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
    function get_metricsWith(uint raw, uint rateWeighted) external returns (uint total, uint avgYield);
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
    function illiquidLossFlagging() external returns (uint);
    function flagIlliquidSelf(address vault, bool illiquid) external;
    function _depositVol(address asset, address sender, uint amount) external payable returns (uint sent);
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
    function BACKING() external view returns (address);
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    function modLP(int256 delta, int256 deltaUSD, address sender) external returns (uint);
    function outOfRange(address sender, int amount, uint loPrice, uint upPrice, address token) external returns (uint);
    function POOLED() external view returns (uint);
    function btcThetaBacking() external view returns (uint);
    function poolStats() external view returns (uint priceWad, uint liquidity);
    // §ISBTC-SPLIT — ONE ARGUMENT. The `bool` selected which of two rings a single Core owned;
    // each instance owns exactly one, so there is nothing left to select. This declaration had
    // drifted from `Core.observe(uint32[])` and the mismatch was INVISIBLE to the compiler: an
    // external call through an interface is encoded from the DECLARATION, so it reverted at
    // RUNTIME with "unrecognized function selector" inside every fixture's setUp.
    function observe(uint32[] calldata secondsAgos) external view returns (uint192[] memory);
    function premiumEwmaUsd() external view returns (uint);
    function POOLED_USD() external view returns (uint);
    function pendingSwapOutUsd() external view returns (uint);
    function levClaimUsd6() external view returns (uint);
    function flowEwmaUsd() external view returns (uint);
    function realizedVarianceWad() external view returns (uint);
    function riskParams() external view returns (uint confFracWad, uint spliceFloor);
    function recordSkewPremium(uint256 premiumUsd) external;
    function refundUnfilled(address token, uint amount, address to) external;
    function repack(uint newLower, uint newUpper) external returns (uint price);   // §V4-CUT: the four zero legs are gone, and `reseat` folded in here
    function collectFees() external returns (uint, uint);
    
    function btcVault() external view returns (address);   // E21: was BasketLib.IWiredCore
    /// §E56 — the MONOTONIC (never-decayed) retained-premium counters. Their value here is NOT the
    /// amount: it is that they are CUMULATIVE, which makes them the liveness signal a decayed EWMA
    /// cannot be. `flow == 0` is ambiguous between a DEAD pool and a NEW one; `skewPremium > 0`
    /// resolves it, because a pool that has never traded cannot have accrued any.
    function skewPremiumCum() external view returns (uint);
    /// §E59 — realized tick variance from the STORED observations (per-second, WAD) + the measured
    /// span. Reads the RING, so it never sees observe()'s interpolation, which used to manufacture
    /// zeros in any stretch quieter than the old wall-clock sample grid. span 0 = UNKNOWN, not calm.
    /// §E53 — the BTC band's equity alone. With committedUsd18() (the SUM) this yields the OTHER
    /// band's share of the one bound both compete for, which is what the shared-scarcity amplifier
    /// needs and what no isBTC-scoped input could ever supply.
    function bandEquityUsd18() external view returns (uint);
    function swap(address sender, bool inputIsUsd, address token, uint amount) external returns (uint);   // §DE-TICK: no price limit, no isBTC -- the instance IS the asset
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
/// @notice The BAND MANAGER surface — implemented by BOTH `Vogue` (ETH) and `Vault` (BTC), which is why
///         every dispatch site already casts both to ONE type: `IBandManager(v4).repack(false)` vs
///         `IBandManager(btcVault).repack(true)`. Callers therefore do NOT block the one-band-manager
///         merge; they already treat the two as a single type.
/// @dev    Split out of `IEthVenue` (2026-08-14), which had fused these with ETH-VENUE CUSTODY under a
///         name that asserted ETH while declaring `feesPerShare`/`USD_FEES`/`derivedThetaWadBtc`.
///         `Aux.sol` called it "the merged Vault (ETH+BTC)" in a comment. The split follows the same
///         fault line the `Vault` contract splits on, so extracting ETH-venue custody becomes a matter
///         of repointing `ethVenue` rather than re-typing call sites.
interface IBandManager {
    /// §DE-TICK — uniform 256-bit: price, bounds, liquidity. The narrow widths were v4 packing.
    function repack() external returns (uint price, uint lower, uint upper, uint liquidity, uint);
    function feesPerShare() external view returns (uint);
    function USD_FEES() external view returns (uint);
    /// This band's engine. Without it a caller holding two band managers cannot reach the second
    /// band's `POOLED`/`POOLED_USD`, which is what silently made cross-band isolation untestable.
    function CORE() external view returns (address);
    function derivedThetaWad() external view returns (uint);
    function setBTCChannels(address b) external;
}

/// @notice ETH-VENUE CUSTODY ONLY — the AAVE-v4 WETH + ether.fi weETH positions. Today `Vault`
///         implements this; the slice is being extracted to its own contract, and because callers
///         already speak this interface at an `ethVenue` pointer, that extraction repoints a pointer
///         instead of re-typing every site.
interface IEthVenue {
    function vogueETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function vogueOp(uint amount, uint8 op) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);
    function offrampEtherFi(uint amount, address recipient) external returns (uint);
}

/// Canonical IAux — union of IAux, IAux.

/// @notice §E5 — the per-band sink that routes a retained scarcity premium into that band's LP
///         fee accumulator. Implemented by BOTH `Vogue` (ETH) and `Vault` (BTC) under the SAME
///         signature so `Core.recordSkewPremium` dispatches by ADDRESS through one call site.
/// E21 -- the last of the per-file restatements, homed here so there is ONE declaration each.
interface IBTCChannels { function btcRecipientOf(address user) external view returns (bytes32); }


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

interface IBtcVaultBridge {
    // BTC LP position: open/close/splice (driven on channel open/close).
    function requestDeposit(address lpEth, uint sats) external;
    function requestRedeem(address lpEth, uint lpPayoutSats) external;
    // (E145) `settleBtcFeesOwed` REMOVED — the BTC fee leg compounds into `pooled` in sats,
    // so there is no owed ledger to clear. Leaving the DECLARATION here is what let a deleted
    // implementation still compile at the call site; the two must be removed together.
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

/// §ISBTC-SPLIT — THE BAND MANAGER'S FACE, SO `Core` STOPS ASKING WHICH ASSET IT IS.
///
/// Every remaining `IS_BTC` branch on Core's money path was Core reaching into ONE OF TWO band
/// managers for the same fact and having to know which. `ISkewSink` above already proved the shape
/// works -- both managers expose `creditSkewPremium`, so that one call site needed no branch. This
/// extends that to the rest, and the two contracts implement it differently BECAUSE THE BANDS
/// DIFFER, which is the honest place for the difference to live.
///
/// ⚠️ THE TWO NO-OPS ARE THE POINT, not laziness:
///   • `deliverVolatile` — ETH pays out real ether; BTC settles by Lightning cooperative close, so
///     there is nothing on-chain to send. One of the four known-REAL asymmetries (CLAUDE.md).
///   • `onShortfall` — BTC routes to the hop (real-BTC delivery, no basket stables). ETH does
///     NOTHING **deliberately**: a surplus-funded refill would buy ETH for a usually-impermanent
///     shortfall and realise that IL onto shared backing, compensating the flow at every LP's
///     expense. Real ETH demand is met at withdrawal via the share price instead.
/// Encoding those as members means the BAND owns its settlement, instead of `Core` branching on an
/// identity it should not need to carry -- and it is the precondition for the two managers becoming
/// one implementation with two instances.
interface IBand {
    /// Size and commit `deltaTok` of the band's volatile at `price`. ETH routes through the venue,
    /// BTC through channels -- the ONE genuine difference in the merged `levAddNet`.
    function addLiq(uint deltaTok, uint price) external returns (uint usdOut, uint outDelta);
    function creditSkewPremium(uint premium6) external;
    /// The band's leverage manager (`totalDebtUsd` is shared; only the lookup differed).
    function levManager() external view returns (address);
    /// Gross levered collateral in the band's NATIVE unit (wei / sats).
    function levGrossNative() external view returns (uint);
    /// Share base the shortfall trigger compares against -- NET for ETH, net + levered buffer for
    /// BTC, so the comparison stays gross-to-gross on both sides.
    function sharesForShortfall() external view returns (uint);
    /// REAL inventory, never just the in-pool token: ETH counts venue retention and idle, BTC
    /// counts pooled sats plus swept off-pool WBTC.
    function realInventory() external view returns (uint);
    /// Remediation when inventory falls short of shares. See the no-op note above.
    function onShortfall(address sender, uint shortfall) external;
    /// Pay the volatile leg out to `who`. See the no-op note above.
    function deliverVolatile(uint amount, address who) external returns (uint sent);
}
