// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// §E266 — flashLoan comes from Morpho Blue itself; this was a hand-rolled restatement of
// IMorphoBase.flashLoan(address,uint256,bytes), identical in signature.

/// @title  Interfaces — the ONE declaration site for external ABIs shared across the tree.
///
/// @notice STANDING RULE: one declaration per interface. Before this file the same external ABI was
///         re-declared per consumer with a per-file suffix (`_V`, `_VG`, `_L`, `CL`, `B`), each a
///         DISJOINT SUBSET of the same contract — `IAaveV4Spoke` alone existed 5× across `Aux`,
///         `Vault`, `QuidLib`, `BasketLib` and `ChannelLib`, no two listing the same functions.
///         That is pure drift surface: a signature fixed in one copy stays wrong in the other four,
///         and a reader cannot tell whether the subsets disagree on purpose.
///
///         Consolidating is FREE. An interface emits ZERO bytecode — it only informs the compiler how
///         to encode a call — so importing the full ABI instead of a hand-picked subset cannot move a
///         contract's EIP-170 size. (Verified against the razor-thin margins this tree runs at:
///         `LevManager` has 70 bytes of headroom and `SwapLib` 295, and both are unchanged by this.)
///         Every merge here is a strict UNION of previously-declared members with byte-identical
///         signatures, so no call encoding changes.
// §RANGEBACKING-FOLD — `IRangeBacking` DELETED, along with the contract it described. Its members
// moved onto `Aux` (`report`, `committedTotal`), which is where the gate that consumes them already
// lives; `otherThan` was dropped rather than moved, having had no callers. Note this interface was
// declared in TWO places — here and again in Core.sol — which is exactly what the warning below was
// written about, and which standing rule 2 exists to prevent.
//
// ⚠️ KEEP THE WARNING, it outlives the interface: a duplicate interface surfaces as forge's
// `Error writing output JSON`, NOT as a redeclaration error — the message points at the wrong layer
// entirely, and it has cost this repo hours on two separate days.

// (there is no wrapper type here: a Solidity file may hold interfaces alone, and the empty
//  `library Interfaces {}` that used to sit on this line was a no-op that only produced an artifact)


// ═════════════════ MORPHO — minimal, un-vendored (§MORPHO-UNVENDOR 2026-08-22) ═════════════════
// `lib/morpho-blue` (23 files) and `lib/morpho-vaults-v2` are GONE. They were carried for FOURTEEN
// `IMorpho` members, ONE `MarketParamsLib.id()`, ONE `IOracle.price()` and ONE
// `IVaultV2.liquidityAdapter()`. "TAKE THE PIECES, NOT THE REPO" applied to the last two places it
// had not been: an interface emits ZERO bytecode, so vendoring bought nothing a declaration does not.
// ⚠️ Need a member that is not here? ADD IT HERE. Do not re-vendor the repo to get it.
type Id is bytes32;

struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }

interface IMorphoBase {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function borrow(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function supplyCollateral(MarketParams memory m, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory m, uint256 assets, address onBehalf, address receiver) external;
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function accrueInterest(MarketParams memory marketParams) external;
}

/// ⚠️ **THE TUPLE-RETURNING VARIANT, AND THAT IS LOAD-BEARING.** Upstream also ships an `IMorpho`
/// whose getters return STRUCTS. This tree imports StaticTyping everywhere; swapping them would
/// COMPILE and then MIS-DECODE at runtime.
interface IMorphoStaticTyping is IMorphoBase {
    function position(Id id, address user)
        external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(Id id) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares,
        uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function idToMarketParams(Id id)
        external view returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

interface IOracle { function price() external view returns (uint256); }

/// `internal pure` ⇒ inlines, no deployed bytecode. ⚠️ Hashes `MarketParams`' 5 words IN DECLARATION
/// ORDER — reorder that struct and every market id changes.
library MarketParamsLib {
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;
    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        assembly ("memory-safe") { marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH) }
    }
}

/// Morpho **Vaults V2** — a DIFFERENT protocol from Blue above, and the tree calls ONE member.
interface IVaultV2 { function liquidityAdapter() external view returns (address); }

/// Aave v4 spoke. Union of the five former variants: `IAaveV4Spoke` (Aux, Vault, BasketLib),
/// `IAaveV4Spoke_V` (QuidLib), `IAaveV4SpokeCL` (ChannelLib).
/// Canonical Aave **v4** spoke view — union of the former per-file variants
interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);
    // §E325 — THE BORROW SURFACE IS GONE, AND IT WENT WITH THE FEATURE, NOT WITH A GREP.
    // `setUsingAsCollateral` / `borrow` / `repay` / `getUserDebt` were declared here.
    // `cbbc0993` ("Drop Euler v2 and Aave V4 borrowing") deleted their only call sites —
    // `SPOKE.setUsingAsCollateral(COLL_RESERVE, true, address(this))` and
    // `SPOKE.getUserDebt(STABLE_RESERVE, address(e))` are both in that diff — and left the
    // four declarations behind. Its own message says why the rest of this interface stays:
    // *"Aave V4 BORROWING is gone; Aave V4 SUPPLY is not."*
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



/// Canonical Quid view — union of the former per-file variants (`QuidLib::IQuid_VG` +
/// `IQuidView_VG`), which split ONE contract's surface across two declarations so a signature
/// change had to be made twice and a missed one still compiled.

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

// §SCRUB-TRI (2026-08-21) — the block that stood here described the removed Curve 3-coin pool as "the ONLY
// external route to WETH/WBTC" in the PRESENT tense, twelve lines above the note recording that it
// was REMOVED. Its verified coins/`get_dy` figures are preserved in §E292. The venue below is the
// live one.
//   coins(0)=USDC 0xA0b8…eB48 · coins(1)=WBTC 0x2260…C599 · coins(2)=WETH 0xC02a…6Cc2
//   get_dy(0→2, 10_000 USDC) = 5.293e18   (~$1,889/ETH)
//   get_dy(0→1, 10_000 USDC) = 1.584e7 sats (~$63.1k/BTC)
// The ORDERING was read from the chain, not assumed — a wrong index swaps the wrong pair at size and
// there is no id to assert against, unlike the Morpho markets.
// (Plain `//`, not NatSpec — solc rejects @notice/@dev on file-level variables.)
// §V-R1-MIN — THE VOLATILE VENUE, PINNED ON-CHAIN. Uniswap V3 SwapRouter02.
// MEASURED 2026-08-17, and this depth IS the argument for these pools (the predecessor venue was
// removed for breaching the 1% floor between $10k and $25k — a DEPTH problem, §E292):
//     USDC/WETH 0.05%  32,497 WETH + 36.9M USDC   — 46x the predecessor's 698 WETH
//     WBTC/USDC 0.30%   262.9 WBTC + 10.3M USDC   — 12.7x the predecessor's 20.72 WBTC
// It was removed because BOTH legs breached the 1% floor between $10k and $25k. That was a
// DEPTH problem, and a deeper pool solves it. It did NOT require an aggregator.
//
// ⚠️ WHY PINNED AND NOT AGGREGATED — THIS IS A KEEPER-SCOPE DECISION, NOT A ROUTING PREFERENCE.
// 1inch resolves routes OFF-CHAIN, so routing through it forces a `bytes route` argument, which
// forces the KEEPER to run an HTTP client, hold API access, handle quote staleness, and choose the
// execution path. That moves the keeper from "picks WHEN" to "picks HOW", and every one of those is
// a new moving part that can fail independently of the chain. A pinned pool needs none of it: the
// keeper passes NOTHING and its entire role stays "decide the moment".
// §C2.1 — THE PINNED-V3-POOL RATIONALE ABOVE IS HISTORY. V3 is deleted; the volatile leg is a
// keeper-supplied 1inch route, so "a pinned pool can be thin at size" is no longer the trade-off
// being made. What replaces it: the ROUTE is chosen off-chain per swap, and the on-chain bound is
// `minOut` on the balance delta.
// 1inch AggregationRouterV6 (mainnet). §C2.1 — the volatile leg's venue. PINNED AS A CONSTANT AND
// THAT IS LOAD-BEARING: the executor `call`s it, so the ONLY thing standing between a malicious
// keeper and the protocol's funds is that the CALLEE cannot be chosen. An `address` parameter here
// would make the whole design a rug vector.
address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

// `unoswap(Address token, uint256 amount, uint256 minReturn, Address dex)` — V6's single-pool
// entrypoint, and the ONLY selector we ever send. ⭐ **VERIFIED AGAINST THE DEPLOYED ROUTER, NOT
// TAKEN FROM DOCUMENTATION** (2026-08-26): the selector is present in the live bytecode, and a fork
// call of 1,000 USDC → WETH through the V3 0.05% pool returned 0.39954 WETH (≈ $2,503/ETH, the real
// rate at head). ⚠️ **THE `dex` WORD'S BIT LAYOUT WAS MEASURED THE SAME WAY AND IS NOT GUESSABLE:**
// four candidate encodings were tried on a fork and exactly one moved tokens.
//   • bits 253-255 — protocol: `0` UniswapV2, `1` UniswapV3, `2` Curve
//   • bit 247 (V3) — `zeroForOne`: SET when selling the pool's `token0` for its `token1`
//   • low 160 bits — the pool address
// ⛔ The V2 candidate (`proto=0`, bare pool) returned **`ok` with ZERO tokens moved**, which is why
// `_aggSwap` bounds on the BALANCE DELTA and not on the router's own `minReturn` — see the note
// there. Pinning the selector is what lets the contract build its own calldata; see `_aggSwap`'s
// header for why keeper-supplied calldata could not work on this money path at all.
bytes4 constant UNOSWAP_SELECTOR = 0x83800a8e;
uint256 constant PROTO_UNIV3   = 1;             // `dex >> 253` for a UniswapV3 pool
uint256 constant ZERO_FOR_ONE  = uint256(1) << 247;  // V3 direction flag, DERIVED by `_aggSwap`

// §RANGE-UNWIND — the venue the RANGE falls back to when it force-closes a lever with no keeper to
// name one (see `LevBase.rangeUnwindDex`). Uniswap V3 WETH/USDC 0.05%, the deepest ETH/USDC pool on
// mainnet; `_aggSwap` derives the direction, so ONE word serves both legs. GOV-overridable.
uint256 constant DEFAULT_UNWIND_DEX =
    (PROTO_UNIV3 << 253) | uint256(uint160(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640));

/// @dev The one V3 accessor `_aggSwap` needs: which token a pool calls `token0`, so the direction
///      flag is computed from `tokenIn` instead of taken on trust from a keeper.
interface IUniV3PoolMin { function token0() external view returns (address); }




// Stableswap legs: the borrowed stable → USDC, before the volatile venue takes USDC → WETH/WBTC.
// 🔴 THE TWO POOLS ARE ORDERED OPPOSITELY. Read from mainnet 2026-08-15:
//     0xD001aE43…  coins(0)=USDC  coins(1)=RLUSD   ⇒ RLUSD is 1, USDC is 0
//     0x383E6b44…  coins(0)=PYUSD coins(1)=USDC    ⇒ PYUSD is 0, USDC is 1
// A SHARED index constant would therefore be silently wrong for one of them — wrong-pair swap at
// size, no revert, no id to assert against. Each pool carries its own pair of indices for that reason.
// Token handles for the routing branch (the basket's own stables; USDC is the routing hub).
// USDC — the stable ROUTING HUB. §SCRUB (2026-08-16): its old name embedded a venue, which named
// it after a pool it has nothing to do with — it is used as the hub in `_hubSwap`/
// `_routableStable`, where that venue is not involved. The genuine venue names below are the POOL
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

/// @notice Curve crypto-swap. Uniswap is gone from every leg: stable→stable goes through
///         the stableswap pools via `ICurvePool` (int128), stable→volatile through this one (uint256).
/// @dev    🔴 A SEPARATE INTERFACE, NOT AN OVERLOAD ON `ICurvePool`, DELIBERATELY. Curve's two families
///         encode indices differently — stableswap `int128`, crypto-swap `uint256` — and calling the
///         wrong one REVERTS (CLAUDE.md records the uint256 variant reverting on the weETH/WETH ng
///         pool). Overloading both on one interface would let a caller pick the wrong ABI by
///         integer-literal inference. Two named types make the choice explicit, and reverting is the
///         SAFE failure: a mis-encoded index would otherwise swap the wrong pair.
// §E240-tri — the 3-coin crypto-swap interface DELETED: no caller. `ICurvePool` (int128 stableswap) stays, and
// `ICurveOracle` in `OracleLib` is a separate, still-live price surface -- do not confuse them.

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

/// Canonical ILevEquity — ONE interface over BOTH lev managers. Union of ILevEquity, ILevEquity_V,
/// ILevEquity_VG and the former `ILevEquityBtc`/`ILevBtc_V`.
///
/// §LEV-FOLD-2 — THE BTC MIRROR IS GONE, AND THE GUARD IT PROVIDED IS NOT. The old note here said
/// these were "NOT mergeable ... a single interface would let a caller reach a BTC read on the ETH
/// manager (and vice versa)", and that was TRUE: distinct selectors made a wrong-manager call
/// REVERT rather than quietly return the other range's book, which matters in a tree that has
/// shipped three address-confusion bugs of that shape in one session.
///
/// But that is a CLAMP -- it catches the mis-assignment once per call, forever, and only if the
/// caller happens to use the suffixed accessor. The state it was detecting is now
/// UNCONSTRUCTIBLE instead: `setLevManager` refuses any manager whose `ORACLE_KEY` is not the
/// pinning range's own asset, so a BTC manager cannot be pinned to the ETH range at all and there is
/// no wrong-manager handle for a caller to hold. Standing rule 17 — a root fix makes the previous
/// guard DELETABLE, which is exactly the test for whether it was a fix or a clamp.
///
/// UNITS ARE PER INSTANCE, not per interface: `netEquity`/`grossCollateral` are 1e18 ETH on the
/// ETH manager and 8-dec sats on the BTC one. The MEANING is identical, which is why one name
/// serves both — the same argument `LevBase.netEquity` already records.
interface ILevEquity {
    /// The range asset this manager prices against — WETH or WBTC. The identity `setLevManager`
    /// checks, and the reason a wrong-range pin cannot be built.
    function ORACLE_KEY() external view returns (address);
    function totalGrossCollateral() external view returns (uint256);
    function totalNetEquity() external view returns (uint256);
    function netEquity(address lp) external view returns (uint);
    function grossCollateral(address lp) external view returns (uint);
    function debtUsd(address lp) external view returns (uint);
    function totalDebtUsd() external view returns (uint256);          // §E21: was Core.ILevDebtTotal
}

interface ILevClose { function closeLevFor(address lp, uint256 minOut) external; }

/// @notice §POOL-VENUE — the AGGREGATE surface of a pooled lev venue. Declared NARROWLY and
///         deliberately NOT added to `ILevVenue`: `AaveV3Venue` (the WBTC leg) is still per-LP
///         escrowed, and widening the shared interface would make it claim an aggregate it does not
///         have. One interface per capability, not per contract.
/// ⚠️      `repayPool` and `withdrawPool` are a PAIR. Repaying alone lowers the pool's LTV (safe);
///         withdrawing alone RAISES it toward a liquidation threshold that Morpho no longer enforces
///         per-LP since the position was pooled. Never call the second without the first.
interface ILevPooled {
    function repayPool(uint256 stableAmount) external returns (uint256 repaid);
    function withdrawPool(uint256 collAmount) external returns (uint256 got);
    function totalDebt() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
}



/// Canonical ILevVenue — union of ILevVenue, ILevVenueB.

// §E325 — a DANGLING `/// Canonical IAux — union of IAux, IAux.` stood here, attached to no
// declaration at all, so a reader takes it for `ICollection`'s docblock. Deleted, with its twin
// above `IBTCChannels`. See the note on `ICollection` for where the degenerate text comes from.

/// Canonical ICollection view.
/// ⚠️ §E325 — this read "union of ICollection, ICollection". `b748857f` GENERATED these
///    "union of A, B" lines mechanically for every consolidated pair, and where the two variants
///    had already collapsed to one spelling it emitted the same name twice. There is no earlier,
///    non-degenerate form to restore: the sentence was born saying nothing. The pre-consolidation
///    variants are recoverable from `b748857f^` if they are ever needed.
/// ⚠️ `transferFrom` here is ERC-721 (`tokenId`) and shares its ABI signature with
///    `IERC20Min.transferFrom` (`amount`). Same selector, different meaning — do not merge them.
interface ICollection {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getApproved(uint tokenId) external view returns (address);
}

/// Canonical Chainlink aggregator view. (§E325: was "union of IAggregatorV3, IAggregatorV3" —
/// same `b748857f` generator as `ICollection` above.)
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns ( uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// Uniswap V3 SwapRouter02. Plain `//`, not NatSpec — solc rejects @notice/@dev on file-level variables.
// §SLOP — `V3_SWAP_ROUTER` DELETED: its only consumer was `SOR._v3Route`, removed with `SOR.sol`.
// ⚠️ AND IT CAME BACK BEFORE GOING AGAIN — THIS TOMBSTONE WAS FALSE FOR MONTHS. `e4f9c512` re-pinned
// the router days after `9eef279a` cut it, because deleting the only volatile route re-opened the
// hole. It is deleted AGAIN under §C2.1, and this time the replacement (a keeper-supplied 1inch
// route) landed FIRST. A tombstone is only true while nothing needs what it buried.

/// @notice Uniswap V3 SwapRouter02 — the SOR's multi-hop route. Callers here only INITIATE swaps, so
///         `IUniswapV3SwapCallback` (implemented by pools) is deliberately not inherited.
// §SLOP — `IV3Router` DELETED with the router constant above: zero references after the SOR cut.

/// Canonical Aux view — union of FIVE former per-file variants, which described ONE contract, so a
/// signature change had to be made up to six times and a missed one still compiled.
/// ⚠️ §E325 — the variant list here read `(IAux, IAux, ChannelLib::IAux, BasketLib::IAux)` plus a
///    header line "union of IAux, IAux_VG". The later suffix-stripping passes rewrote each variant
///    into the surviving name, so the list stopped naming what was merged and started asserting
///    that `IAux` was merged with itself. `19072701` ("Consolidate six Aux interface views into one
///    canonical IAux") holds the real names; they are NOT restated here, because a name that no
///    longer resolves is exactly what CLAUDE.md's rename table says to leave in history.
/// @notice §E296 — `ISwap.sol` and `ILevVenue.sol` folded in (standing rule 2: one declaration per
///         interface, in THIS file). Both files existed ONLY to hold interfaces, so both are deleted.
///         `IAux is ISwap` rather than restating its three members: `getTWAPforAsset`, `resolvedTwap`
///         and `swap` were declared in BOTH places and had DRIFTED — `Aux.swap` is `public payable`
///         (`Aux.sol:721`), `ISwap` agreed, and `IAux` said non-payable. No `src` caller used either
///         handle, so the wrong selector never fired; that is exactly the §E21 failure mode this rule
///         exists to prevent, caught this time before it could bite.
/// @notice Aux's public stable<->volatile swap surface (Aux.sol `swap`), declared
///         once here as the single source of truth. `Aux` implements it; peripherals
///         (formerly also `SorExchange`, the Liquity-zapper adapter, deleted 2026-08) consume it without
///         re-declaring a duplicate interface. `token` = stable side (or QUID/zero),
///         `asset` = volatile side (WETH/WBTC), `forVolatile` true = stable->volatile.
interface ISwap {
    function swap(address token, address asset, bool forVolatile, uint256 amount, uint256 minOut, bool loadBalance)
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
    // to say they meant zero size. Inventory, not `L`, separates a full range from a drained one at
    // the same price, and a size-blind quote cannot express that difference at all.
    function wellSkew(address asset, uint256 drainUsd6) external view returns (uint256 skewWad);
}

interface IAux is ISwap {
    /// @dev The per-asset price-feed registry. Its EMPTINESS is the honest discriminator for "this token
    ///      is a dollar stable, worth par": a basket stable has no feed, a real asset (WETH/WBTC) does.
    ///      Used instead of naming WETH, which would re-open on the next non-dollar loan token.
    function assetPriceFeed(address asset) external view returns (address);
    function vaults(address) external returns (address);
    function tranche(address) external returns (uint);
    function take(address who, uint amount, address token, uint seed) external returns (uint);
    function takeWith(address who, uint amount, address token, uint seed, uint[15] memory amounts, uint[15] memory yieldW) external returns (uint);
    function riskFactor(address token) external view returns (uint);
    function getDepegSeverityBps(address token) external view returns (uint);
    function GHO() external view returns (address);
    function USDG() external view returns (address);
    function aaveBalance(address token) external view returns (uint);
    function aaveShares(address token) external view returns (uint);
    function withdrawAaveLeg(address stable, uint amount, address to) external returns (uint);
    function get_metrics(bool force) external returns (uint total, uint avgYield);
    function get_metricsWith(uint raw, uint rateWeighted) external returns (uint total, uint avgYield);
    function rangeETH() external view returns (uint);
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
    // §E325 — `_tryPath` removed. `09fedf18` ("Delete the SOR…") deleted the BODY from `Aux.sol` and
    // left this declaration; `Aux.sol:765` names it in the removal list. That is the exact shape
    // §E145 warns about six interfaces down — *"Leaving the DECLARATION here is what let a deleted
    // implementation still compile at the call site; the two must be removed together."*
    function toIndex(address token) external view returns (uint);
    function supplySelf(address token, uint amount) external returns (uint);
    function withdrawSelf(address token, uint amount, address to) external returns (uint);
    function checkBacking() external returns (uint committedSum, uint totalLiquid);
    function takeToSettle(address who, uint amount, address token) external returns (uint);
    function WBTC() external view returns (address);
    /// Rule 2: declared HERE, not as a file-local restatement. `Aux.WETH` is a public
    /// `WETH9` state var; over the ABI that is an address, which is all any caller needs.
    function WETH() external view returns (address);
    function tokens(address vault) external view returns (address);
    function illiquidLoss() external view returns (uint);
    function illiquidLossFlagging() external returns (uint);
    function flagIlliquidSelf(address vault, bool illiquid) external;
    /// §INTENT-FUNDING-LEG — burn `owner`'s mature basket claim and report the 6-dec USD it
    /// realised. Range-gated on Aux; the caller must already have verified `owner`'s signature.
    function spendClaim(address owner, uint usd6) external returns (uint funded6);
    function _depositVol(address asset, address sender, uint amount) external payable returns (uint sent);
    function tipSelf(uint cut, address token, int sign) external;
    function bumpQuidBTC(uint amount) external;
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
}
/// Shared token surfaces for the whole leverage cluster (LevManager / LevMath / BtcLevManager) — was three
/// byte-identical ERC-20 slices (IERC20Min / IErc20M / IERC20B) + three WETH slices. One each now.
interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
    /// §E21: absorbed from `Core.IERC20Min`, which was a SECOND declaration of this same
    /// name in a second file — the literal rule-2 violation. Core's dust sweep is the only
    /// caller; adding the member here costs nothing (interfaces emit no runtime bytecode).
    function totalSupply() external view returns (uint256);
}

/// §A.52: the ONE WETH view. Inherits `IERC20Min` so consumers needing balance/allowance/transfer
/// do not each declare a private variant — `QuidLib::IWETH_VG` and `SwapLib::IWethDeposit` were both
/// partial restatements of exactly this, and a signature change had to be made in three places.
interface IWETH9 is IERC20Min { function deposit() external payable; function withdraw(uint256) external; }

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

    /// @notice §DUST — bring the venue's debt accounting up to NOW before anything READS it.
    /// @dev    Surfaced on the interface so `LevManager` can call it before it SIZES anything.
    ///         `MorphoEscrowVenue.accrue` has existed since the keeper work and was never called
    ///         from `src`; it is the fix for the pre-accrual drift its own docblock describes.
    ///         Permissionless (Morpho's `accrueInterest` is), idempotent within a block, and a
    ///         NO-OP on a venue whose debt view already reflects accrued interest at read time.
    function accrue() external;

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
    // §ILEVVENUE FOLD — `ILevVenue` is DELETED into this face. `stable()` above was declared
    // identically in both, so the merge DEDUPES it; `COLLATERAL()` is the only member it added.
    // Verified same implementor rather than same address (the `EthVenue`-split lesson):
    // `LevVenueBase` provides BOTH `COLLATERAL()` and `supply(address,uint256)`.
    function COLLATERAL() external view returns (address);

    /// @notice Venue liquidation threshold in bps of collateral value (e.g. 8000 = 80% LLTV).
    function liqThresholdBps() external view returns (uint256);
}


/// Canonical Core view — union of FOUR former per-file variants, which described ONE contract, so a
/// signature change had to be made up to four times and any missed one still compiled.
/// (§E325: the variant list read `SwapLib::ICore, SwapLib::ICore, BasketLib::ICore` — the same
///  rename flattening as `IAux` above. Real names in `b748857f^`.)
interface ICore {
    // §E325 — `BACKING()` removed: THE SUBJECT OF THIS ACCESSOR NO LONGER EXISTS. It arrived with
    // `6b4de0ee` as the pointer to the `IBandBacking`/`IRangeBacking` accountant, and
    // §RANGEBACKING-FOLD (top of this file) deleted that interface *"along with the contract it
    // described"*, moving `report`/`committedTotal` onto `Aux`. No contract in `evm/src` declares
    // `BACKING` — not as a function, not as public state — so a call through this handle would have
    // fallen through the dispatcher at ~195 gas, the failure mode this interface's own header warns
    // about 60 lines below. Every other `BACKING` in the tree is English prose in a comment.
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    /// §E315 — RESTORED. A conflict auto-merge spliced TWO declarations into one broken line,
    /// `function mo.  t amount, address token)`, which left `ICore` declaring NEITHER `modLP`
    /// nor `outOfRange` while both are called through it. Signatures recovered from `Core.sol`
    /// and from the live call sites, not reconstructed by guess. (`outOfRange` itself went with
    /// §OOR-BOOK-DELETED; only `modLP` remains of that pair.)
    function modLP(int256 delta, int256 deltaUSD, address sender) external returns (uint sent);
    /// §OOR-AS-INTENT — settle ONE filled intent. Both legs at once, because a fill is a TRADE.
    /// ⚠️ THIS SURVIVED THE BOOK'S DELETION AND IS NOW ITS ONLY CONSUMER: `Quid.fillIntent` calls
    /// it with the deltas `SwapLib.fillIntentBody` derives AT THE SIGNED LIMIT, not at spot.
    function settleOor(address owner, int256 usdDelta, int256 volDelta, bool loadBalance) external;
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
    /// §BURN-RELEASES-NO-USD — the BASKET's share of the USD leg, distinct from `POOLED_USD` (which
    /// also holds the LP-owned increment). A burn releases the basket's dollars; the increment is
    /// paid to the LP separately by `_payUsdLeg`/`absorbPaidUsd`. Reading the wrong one over-releases.
    function basketUsd() external view returns (uint);
    function pendingSwapOutUsd() external view returns (uint);
    function levClaimUsd6() external view returns (uint);
    function flowEwmaUsd() external view returns (uint);
    function realizedVarianceWad() external view returns (uint);
    function riskParams() external view returns (uint confFracWad, uint spliceFloor);
    function recordSkewPremium(uint256 premiumUsd) external;
    function refundUnfilled(address token, uint amount, address to) external;
    function repack(uint anchorPrice) external returns (uint price);   // §ONE-ANCHOR: bounds derive from this
    function collectFees() external returns (uint, uint);
    
    function btc() external view returns (address);   // E21: was BasketLib.IWiredCore
    /// §E56 — the MONOTONIC (never-decayed) retained-premium counters. Their value here is NOT the
    /// amount: it is that they are CUMULATIVE, which makes them the liveness signal a decayed EWMA
    /// cannot be. `flow == 0` is ambiguous between a DEAD pool and a NEW one; `skewPremium > 0`
    /// resolves it, because a pool that has never traded cannot have accrued any.
    function skewPremiumCum() external view returns (uint);
    /// §E59 — realized tick variance from the STORED observations (per-second, WAD) + the measured
    /// span. Reads the RING, so it never sees observe()'s interpolation, which used to manufacture
    /// zeros in any stretch quieter than the old wall-clock sample grid. span 0 = UNKNOWN, not calm.
    /// §E53 — the BTC range's equity alone. With committedUsd18() (the SUM) this yields the OTHER
    /// range's share of the one bound both compete for, which is what the shared-scarcity amplifier
    /// needs and what no isBTC-scoped input could ever supply.
    function rangeEquityUsd18() external view returns (uint);
    function swap(address recipient, bool inputIsUsd, address token, uint amount, bool loadBalance) external returns (uint);   // §DE-TICK: no price limit, no isBTC -- the instance IS the asset

    // ═══ §E305 — `IBand` FOLDED IN. ONE INTERFACE FOR CORE AND BOTH RANGE MANAGERS ═══
    // 🔴 §E325 — THIS NOTE SAID "`ICore` FOLDED IN … `ICore` named the same objects this does",
    //    INSIDE `interface ICore`, WHICH NAMES NOTHING. `c372f7b0` ("E305: … and IBand folds into
    //    ICore") wrote the sentence with the folded interface ALREADY spelled as its destination,
    //    so the note lost the only fact it existed to carry. The absorbed interface was **`IBand`**.
    // `IBand` named the same objects this does, from the other side, so the two were one concept
    // wearing two nouns. Its 16 members are below; `Core`, `Quid` and `Vault` all cast to `ICore`.
    // ⚠️ THIS INTERFACE DELIBERATELY OVER-PROMISES, AND THAT IS THE COST OF ONE NOUN. No single
    //    contract implements all 44 members (43 when this was written; §E307 added three and §E325
    //    removed `BACKING`): `Core` has the pool surface, `Quid` and `Vault` the
    //    range surface. A call to a member the target does not implement COMPILES and reverts at
    //    runtime with no matching selector (~195 gas, the dispatcher falling through). If that
    //    ever bites, the tell is the gas number, not the message.
    // ⚠️ `repack` EXISTS TWICE AND THEY ARE DIFFERENT OPERATIONS: `repack(uint anchorPrice)` is
    //    `Core`'s, `repack()` is the range manager's. Solidity keeps them as OVERLOADS because the
    //    parameter lists differ — the arity is what selects, so neither call site changes meaning.
    /// Size and commit `deltaTok` of the range's volatile at `price`. ETH routes through the venue,
    /// BTC through channels -- the ONE genuine difference in the merged `levAddNet`.
    function addLiq(uint deltaTok, uint price) external returns (uint usdOut, uint outDelta);
    /// §E5 — the per-range sink that routes a retained scarcity premium into that range's LP fee
    /// accumulator. Implemented by BOTH `Quid` (ETH) and `Vault` (BTC) under the SAME signature, so
    /// `Core.recordSkewPremium` dispatches by ADDRESS through one call site. (§E325: this docblock
    /// had been stranded above `interface IBTCChannels`, which does not implement it.)
    function creditSkewPremium(uint premium6) external;
    /// The range's leverage manager (`totalDebtUsd` is shared; only the lookup differed).
    function levManager() external view returns (address);
    /// Gross levered collateral in the range's NATIVE unit (wei / sats).
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

    // ═══ §E302 — `IBandManager`'s SEVEN MEMBERS, MERGED IN. ONE RANGE FACE, NOT TWO ═══
    // 🔴 §E325 — THIS ROW SAID `IRangeManager`, AND NO SUCH SYMBOL HAS EVER BEEN DECLARED IN THIS
    //    TREE. The merge happened as `7f3b1f93` while the pair was still spelled `IBandManager` +
    //    `IBand`; the Band→Range pass (`1b21ca09`) then rewrote the DEAD name in this comment into
    //    the live vocabulary, which is CLAUDE.md's own warning arriving from inside the source:
    //    *"Renaming a tombstone does not destale it; it disguises it."* The cost was measured —
    //    the merge below reads as OUTSTANDING WORK to anyone who greps `IRangeManager`, and it is
    //    DONE. Verified 2026-08-23: `grep -rn "IRangeManager\|IRange\b" src test script` returns
    //    exactly this file's comments, and all 16 members are present in `ICore` below.
    // The two interfaces shared ZERO member names and `Quid` and `Vault` each implement BOTH, so
    // they were never two objects - only two names for one. Nothing was declared twice, which is
    // why standing rule 2 never flagged it; the defect was that a caller holding a range had no way
    // to know which of two faces to reach for, in a codebase whose target is ONE range manager.
    // ⚠️ `feesPerShare`, `USD_FEES` and `CORE` are PUBLIC STATE on `Shares`, not functions - their
    //    getters are auto-generated, so grepping for their `function` form in `Quid.sol` returns 0
    //    while the members are fully implemented.
    /// §DE-TICK — uniform 256-bit: price, bounds, liquidity. The narrow widths were v4 packing.
    function repack() external returns (uint price, uint lower, uint upper, uint liquidity, uint);
    /// §ONE-ANCHOR — the derived range, from the single stored anchor.
    function rangeBounds() external view returns (uint lo, uint hi);
    function feesPerShare() external view returns (uint);
    function USD_FEES() external view returns (uint);
    /// This range's engine. Without it a caller holding two range managers cannot reach the second
    /// range's `POOLED`/`POOLED_USD`, which is what silently made cross-range isolation untestable.
    function CORE() external view returns (address);
    function derivedThetaWad() external view returns (uint);
    /// §DERIVED-BAND — the range's LVR coefficient, `1/(4(2 − √(P/Pb) − √(Pa/P)))`. Already the `K`
    /// in `derivedThetaWad`'s `μ/(K·σ²)`, and `Quid` has exposed it as `kLvrWad()` since that work —
    /// declared here so the leverage overlay can reach it through `ICore` on EITHER range.
    function kLvrWad() external view returns (uint);
    // §E325-IQUID FOLD — the last two members of `IQuid`, which is now DELETED. `derivedThetaWad`
    // above was declared IDENTICALLY in both, so the fold DEDUPES it rather than colliding.
    // ⚠️ `Core` implements NONE of these three: `ICore` has been the polymorphic RANGE-MANAGER face
    // since `IBand` was folded in, and its implementors are `Quid` and `Vault`. These two are
    // `Quid`-only, which is ABI-legal and matches how the merged face already works.
    function unwindForRedeem(uint usdWanted) external returns (uint usdFreed);
    function pendingRewards(address user) external view returns (uint ethReward, uint usdReward);
    function setBTCChannels(address b) external;

    // §E307 — the LEFTOVER `IBand` folded in; members `ICore` already had are not duplicated
    // (that is why `bandBounds`, which both carried, appears once above as `rangeBounds`).
    // 🔴 §E325 — this line said "`ICore` folded in", naming its own destination again. `1b21ca09`
    //    absorbed a SECOND interface still called `IBand` — `{syncLev, soldFractionWad, bandPrice,
    //    bandBounds}` — which had survived §E305's fold of the first one.
    /// §SLOP — ONE NAME. This interface declared BOTH `syncLev` and `syncLevBTC` for the same
    /// operation, so the two ranges could not be called through one method even though the
    /// interface existed precisely to make that possible. The interface IS the polymorphism;
    /// a second name for the same call defeats it.
    function syncLev(address lp) external;
    function soldFractionWad(uint syncKeyPx) external view returns (uint256);
    function rangePrice() external view returns (uint);
    // Range bounds. These replace the former `reseatEpoch()` counter as the re-anchor signal: the counter and
    // the ticks are written in the same statement pair (Quid:1137-1138, Vault:711-712), so the bounds carry
    // the same information AND strictly more of it -- a reseat that leaves an anchor inside the new range
    // bumped the counter but needs no re-anchor. All four are auto-generated getters for existing public
    // state (Quid:92-93, Vault:214-215); no new contract code implements them.
}

/// @notice ETH-VENUE CUSTODY ONLY — the AAVE-v4 WETH + ether.fi weETH positions. Today `Vault`
///         implements this; the slice is being extracted to its own contract, and because callers
///         already speak this interface at an `ethVenue` pointer, that extraction repoints a pointer
///         instead of re-typing every site.
interface IEthVenue {
    function rangeETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function rangeOp(uint amount, uint8 op) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);
    // §E325 — `offrampEtherFi` removed from this FACE; the function is alive and stays
    // (`Quid.sol:131`, `public`, and `Quid` IS the ethVenue — `DeployL1_s:534,546` cast
    // `Quid(payable(AUX.ethVenue()))`). Nothing ever reached it THROUGH `IEthVenue`: its one
    // caller is `Quid.sol:702`, an internal call, and the scripts hold the concrete type.
    /// §E306 — folded in from `ILevHost`, a one-function face over this SAME contract: all three of its
    /// call sites resolved `IAux(...).ethVenue()`, which is what `IEthVenue` is already cast on.
    /// (§E325: this said "folded in from `IEthVenue`" — its own name. `892c5b78` is titled
    ///  *"fold ILevHost and IBasketMint away"*, which is where both real names come from.)
    /// @notice The lev manager this venue hosts.
    function LEV_MANAGER() external view returns (address);
}

// §E325 — the second dangling `/// Canonical IAux — union of IAux, IAux.` stood here, and above it
// the §E5 docblock describing `creditSkewPremium` — a member of `ICore`, not of `IBTCChannels`.
// Both were left behind when their subjects were folded away, and a `///` block immediately above
// `interface IBTCChannels` reads as ITS documentation. The §E5 prose moved to the member it
// describes; only the line that is actually about this interface stays.

/// E21 -- the last of the per-file restatements, homed here so there is ONE declaration each.
interface IBTCChannels {
    function btcRecipientOf(address user) external view returns (bytes32);
    /// (§TEST-RECONSTRUCTIONS) The canonical PoP digest. `BTCChannels` declares this `public`
    /// precisely so a signer *"signs EXACTLY what the contract checks rather than a
    /// reconstruction"* (`BTCChannels.sol:2429`) — and `ExitFixture` was reconstructing it by hand
    /// anyway, tag and field order copied. Homed here so the fixtures reach it through the ONE
    /// canonical interface rather than growing a second (standing rule 2, same as every merge above).
    /// ⚠️ **A HAND COPY OF THIS DIGEST DRIFTS SILENTLY**: change the tag, a field, or the field
    /// ORDER in the contract and every copy keeps signing the old shape and keeps PASSING, until
    /// something integration-level fails somewhere nobody can localise. That is the same root as
    /// `#21`, where the fixtures kept their own notion of `lpEth` and §E183 moved the contract's.
    function btcRecipientPoPDigest(address lpEth) external view returns (bytes32);
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

/// Canonical Basket turn/maturity view (was `BasketLib.IBasketTurn`, itself already a union of two
/// earlier per-file variants). §E325: read `BasketLib.IBasket` — this interface's own name.
interface IBasket {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
    function immatureBalanceOf(address who) external view returns (uint);
    /// §E303 — folded in from `IQuidTarget`, which was a SECOND interface over this SAME contract.
    /// `target()` lives in `Basket.sol` alongside the three above, so both faces described one thing.
    /// 📖 **NAMING, SO IT IS NOT RE-READ AS DRIFT:** `Basket` is the QU!D token contract, and the
    /// variables that hold it are named `quid` accordingly — `DeployLib:171` `Basket quid = new
    /// Basket(...)`. The contract *named* `Quid` is the ETH RANGE (`DeployLib:118` `Quid ethRange = new
    /// Quid()`). **Deliberate and correct: the type names the implementation, the variable names the
    /// role.** So `IBasket(quid)` reads the QU!D token, which is what `turn`, `matureSupply`,
    /// `immatureBalanceOf` and `target` all belong to.
    /// ⇒ Interfaces here are named for the CONTRACT they address, never for the variable at the call
    /// site — which is why the `IQuid*` name was the one to retire, not this one.
    function target() external view returns (uint);
    /// §E306 — folded in from `IBasketMint` (§E325: the note said `IBasket`, its own name; the real
    /// one is in `892c5b78`), a one-function face over this SAME contract. Both were cast
    /// on `quid`, and `Basket.sol` implements `mint` alongside `turn` / `matureSupply` / `target`.
    /// @notice Mint `amount` against `pledge`'s deposit of `token`, dated `when`.
    function mint(address pledge, uint amount, address token, uint when) external returns (uint);
}

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
    /// §POOL-VENUE — the pinned pool venue, or 0 if this range has never opened a position. Reading
    /// THIS rather than `openLpAt(0)` is what stops a de-lever silently skipping a pool that still
    /// holds collateral after its last LP closed.
    function poolVenue() external view returns (address);
    /// §POOL-VENUE — the AGGREGATE delivery de-lever. Takes a VENUE, not an LP: the position is pooled,
    /// so there is no per-LP repay to name. Replaces the O(LPs) walk `deleverEthOnDelivery` used to do.
    function swapOutDeleverPooled(address venue, uint stableUsd, address recipient, uint minWethOut)
        external returns (uint usedUsd, uint wethDelivered);
    function swapOutDeliverUnlevered(address lp, uint wethWanted, address recipient, uint minWethOut)
        external returns (uint wethDelivered);
}

interface IBtc {
    // BTC LP position: open/close/splice (driven on channel open/close).
    function requestDeposit(address lpEth, uint sats) external;
    function requestRedeem(address lpEth, uint lpPayoutSats) external;
    // (E145) `settleBtcFeesOwed` REMOVED — the BTC fee leg compounds into `pooled` in sats,
    // so there is no owed ledger to clear. Leaving the DECLARATION here is what let a deleted
    // implementation still compile at the call site; the two must be removed together.
    // `exactUsd` > 0 ⇒ on-chain swap-out delivery (pay the LP that exact proceeds);
    // 0 ⇒ LP-withdrawal splice-out (all native).
    // §EIP-7540 — NOT given a `request*` name, deliberately. 7540 has requestDeposit and
    // requestRedeem and NOTHING for a PARTIAL close: this shrinks a position by `shrinkSats`
    // without retiring the channel, which the standard does not model. Inventing `requestResize`
    // would dress a non-standard operation in standard vocabulary, which is worse than a plain
    // name. The `Btc` suffix goes because that is the range-instance cleanup, not the 7540 one.
    function resize(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd) external;
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


/// @notice §E297 — the last five interfaces that lived outside this file (standing rule 2).
///         `ISwap.sol`/`ILevVenue.sol` were deleted by §E296 because they held nothing else;
///         these five sat inside files that also hold real libraries, so only the declarations
///         moved. `Interfaces.sol` already declared `IAaveV4Spoke`, `IAaveV4Hub` and
///         `ICurvePool`, so the Aave/Curve handles now all live in one place instead of two.

/// @notice Minimal interface for Liquity V2 StabilityPool
/// @dev 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF (WETH)
interface IStabilityPool {
    function provideToSP(uint _topUp, bool _doClaim) external;
    function withdrawFromSP(uint _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint);
    function getDepositorYieldGainWithPending(address _depositor) external view returns (uint);
}

/// Curve's on-pool EMA oracle. Returns a PLAIN PRICE (WAD) of coin `k+1` in units of coin 0 —
/// no ticks, no sqrt price, nothing to decode.
interface ICurveOracle {
    function price_oracle(uint256 k) external view returns (uint256);
    function price_oracle() external view returns (uint256);   // two-coin pools take no index
}

/// @title  OracleLib — the INDEPENDENT price observer, restoring what the v4 cut deleted
///
/// @notice **WHY THIS EXISTS.** Before the cut, the observation ring recorded the RANGE POOL'S SPOT
///         PRICE — an actual observation of executed trades — and Chainlink was the ANCHOR checking
///         it. Two genuinely different sources, which is what made `twapResolve`'s deviation test and
///         `BasketLib.isManipulated` mean anything.
///
///         Removing the AMM removed the observation. `Core.swap` now writes the ring from
///         `AUX.getTWAPforAsset`, which reads that same ring and anchors to Chainlink — so the ring
///         records a value derived from itself plus Chainlink, and every guard compares one source
///         against a smoothed copy of itself. **Nothing reverts. The guards still run and still
///         compute; they simply lost the ability to disagree.**
///
/// @dev **WHY CURVE AND NOT A UNISWAP TWAP.** A v3 TWAP is tick-cumulative, so reading one means
///      `1.0001^tick` — i.e. `TickMath`, the exact dependency this refactor removed. Curve's
///      `price_oracle()` is a plain WAD price maintained by the pool, so it needs no decoding at
///      all. It is also a genuinely DIFFERENT mechanism from Chainlink's pushed feeds — an EMA over
///      executed trades versus a signed off-chain report — which is what makes the cross-check
///      informative rather than decorative. And we already route every swap leg through these pools,
///      so it adds no new integration surface.
///
/// ⚠️ **AN EMA IS NOT A WINDOWED TWAP, AND THE DIFFERENCE MATTERS FOR THE BOUND.** Curve's oracle
///      decays exponentially toward spot with a pool-configured half-life; it has no explicit window
///      you choose. So its manipulation profile is set by the POOL, not by us — you cannot widen the
///      window to buy safety the way you can with a v3 observation. The deviation bound must be
///      derived against that half-life, not inherited from `TWAP_MAX_DEVIATION_BPS`, which was
///      calibrated for a 30-minute windowed reading.
///
/// ⚠️ **CORRELATED SOURCES ARE ONE SOURCE.** Two stablecoin-quoted ETH pools share a depeg mode:
///      when the stable moves, both move together, in exactly the regime the guard exists for.
///      Relating the volatile legs through ONE BTC↔ETH ratio avoids compounding two USD oracle
///      errors into the number that actually matters. Count correlated readings as one observer.
/// @dev 1inch OffchainOracle — the AGGREGATED spot-rate reader. `useWrappers=false` keeps the lookup
///      on the token as given rather than letting the oracle substitute a wrapper: a substitution
///      would quietly reintroduce the wrapped-asset basis this protocol is removing (§E221).
interface IOffchainOracle {
    function getRate(address srcToken, address dstToken, bool useWrappers)
        external view returns (uint256 weightedRate);
    /// @dev §E297 — absorbed from `OneInchGasProbe.t.sol`, which declared its own `IOffchainOracle`
    ///      carrying this member as well. The two declarations had DRIFTED: the test's had
    ///      `getRateToEth` and this one did not, so folding the file-local copy in without taking
    ///      this member would have deleted a call the probe actually makes (`:65`). Union, not
    ///      truncation — that is what "one declaration" has to mean when the copies disagree.
    function getRateToEth(address srcToken, bool useWrappers) external view returns (uint256);
}

/// ── Aave V3 Pool surface this adapter needs. Signatures proven against the LIVE Aave V3 Pool by the (tested)
///    Amp.sol integration: supply(asset,amt,onBehalf,ref) / borrow(asset,amt,rateMode,ref,onBehalf) /
///    repay(asset,amt,rateMode,onBehalf) / withdraw(asset,amt,to). V3 keys a position by the CALLER (no
///    sub-account / on-behalf-borrow), so per-LP isolation uses a per-LP escrow (the pattern `LevVenueBase` holds).
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}

/// @dev Aave's ProtocolDataProvider — the PROVEN read Amp.sol used (`getReserveTokensAddresses`). Its per-asset
///      `getUserReserveData` returns the CURRENT (already index-scaled, block-fresh, underlying-unit) aToken balance
///      and variable debt DIRECTLY — no vToken.balanceOf, no hardcoded reservesList index, one asset per call
///      (cheap on the on-chain rangeBTC sum). This is why we read positions here and not off the raw tokens.
interface IAaveV3DataProvider {
    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt,
        uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate,
        uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled);
}
