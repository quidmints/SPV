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
// ⚠️ THE FAILURE MODE STANDING RULE 2 EXISTS TO PREVENT: declaring the same interface in TWO files
// surfaces as forge's `Error writing output JSON`, NOT as a redeclaration error — the message points
// at the wrong layer entirely, and it has cost this repo hours on two separate days.

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

/// Canonical Aave **v4** spoke view — the ONE declaration every consumer imports.
interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);
    // ⛔ NO BORROW SURFACE HERE, DELIBERATELY. `cbbc0993` dropped the borrowing venues
    // removed the FEATURE, not the protocol member: `setUsingAsCollateral` / `borrow` / `repay` /
    // `getUserDebt` still exist ON THE SPOKE. Do not declare them here to reach them — its own
    // message says why the rest of this interface stays: *"Aave V4 BORROWING is gone; Aave V4
    // SUPPLY is not."*
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

// §C2.1 — THE VOLATILE LEG IS A KEEPER-SUPPLIED 1INCH ROUTE. The route is chosen off-chain per
// swap; the on-chain bound is `minOut` measured on the BALANCE DELTA, never the router's own
// `minReturn`. (Plain `//`, not NatSpec — solc rejects @notice/@dev on file-level variables.)
// 1inch AggregationRouterV6 (mainnet) — the volatile leg's venue. PINNED AS A CONSTANT AND
// THAT IS LOAD-BEARING: the executor `call`s it, so the ONLY thing standing between a malicious
// keeper and the protocol's funds is that the CALLEE cannot be chosen. An `address` parameter here
// would make the whole design a rug vector.
address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

// §SESS-42 — **THE TWAP AVERAGING WINDOW, DECLARED ONCE.** It was written THREE times for ONE concept:
// `LevBase.TWAP_WINDOW` (the managers'), `LevMath.TWAP_WIN_M` (the library's), and carried a third time
// as `WbtcCfg.twapWindow` — all feeding the same `getTWAPforAsset(asset, window)` parameter. Rule 2:
// one declaration, in the shared file.
// ⚠️ **THIS IS NOT THE SAME CASE AS THE TWO `100`s** (`MAX_SLIPPAGE_BPS` and `SELL_SLIP_BPS`), which do
// DIFFERENT jobs — a withdraw gross-up plus MEV floor, versus the cap on the size-aware slip curve.
// §E275's doctrine is explicit that constants sharing a value **by inheritance rather than by
// derivation** must stay SEPARATE, *"so Γ can move without silently repricing the unknown-variance
// case."* ⇒ **deduplicate identical CONCEPTS, never merely identical VALUES.**
uint32 constant TWAP_WINDOW_SECS = 1800;

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
// `routedSwap` bounds on the BALANCE DELTA and not on the router's own `minReturn` — see the note
// there. Pinning the selector is what lets the contract build its own calldata; see `routedSwap`'s
// header for why keeper-supplied calldata could not work on this money path at all.
bytes4 constant UNOSWAP_SELECTOR = 0x83800a8e;
// 1inch V6 `unoswap2(uint256 token, uint256 amount, uint256 minReturn, uint256 dex, uint256 dex2)`.
// §CURVE-ALONE-CANNOT-DO-IT — TWO SEQUENTIAL POOLS, and like `unoswap` it takes the AMOUNT AS A
// RUNTIME PARAMETER, which is the whole reason it is usable here where `swap()` is not: our amounts
// are computed mid-transaction, so anything that embeds its amount is stale by construction.
// Verified present in the deployed router 2026-08-30.
// Measured worth: on the BTC leg two hops beat one at every size — USDT→WETH→WBTC costs 0.67% at
// $1M against 0.92% direct, and 3.29% vs 4.96% at $5M.
bytes4 constant UNOSWAP2_SELECTOR = 0x8770ba91;
// §SESS-65 — the THIRD member of the family, three pools in one call. Adding it costs nothing on-chain
// beyond this line, because the route is no longer ENCODED here: it is supplied and RETARGETED
// (`LevMath._retarget`). ⇒ hop count stops being an ABI shape and becomes a property of the calldata.
// ⛔ §SESS-91 — `UNOSWAP3_SELECTOR` DELETED. Measured 2026-09-07 with a live key: 1inch returned the
// generic `swap()` (0x07ed2379) for **24 of 24** pair/size combinations (USDC/USDT/DAI/GHO/crvUSD/
// FRXUSD x {WETH,WBTC} x {$100k,$1M}) and NOT ONE unoswap of any arity. Our own planner caps at two
// hops (`hops: vec![w]` or `vec![w1, second]`), so the 3-hop form had no producer on either side.

// §SESS-66 — **A CURVE HOP WORD, EXECUTED BY US, NEVER HANDED TO 1inch.** ⚠️ I deleted this in
// §SESS-52 as "capability nobody asked for" and that was right at the time: the roster route was the
// only Curve we could reach and it needed no tag. It is back because the PLANNER can now discover
// Curve pools, and a pool it finds is worthless unless the contract can be told to use it.
// ⛔ Still not 1inch's encoding: six candidate layouts for a Curve pool word through `unoswap` were
// executed against the live router and **0 of 6 filled**. We already speak `exchange` directly and
// bound it on a measured delta (§SESS-46), so there is nothing to reverse-engineer.
// Layout, low bits first: pool(160) | i(8) | j(8) | … | proto(3 @ 253). `i` is the NON-USDC coin's
// index, `j` is USDC's. Direction is the caller's, never the word's — one word serves both ways.
// §SESS-69 — 1inch v6's GENERIC executor. ⚠️ **THE SELECTOR IS THE PROOF, NOT A RECOLLECTION:**
// `swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)` hashes to
// **0x07ed2379**, and the v5 four-argument form (…,bytes,bytes) hashes to 0x12aa3caf — a different
// function. Checked with `cast sig` against the deployed router's selector before a line was written.
// ⭐ **THIS IS THE ONLY WAY TO REACH UNISWAP V4.** A v4 pool has NO ADDRESS — it is a singleton keyed
// by a `PoolKey` inside the PoolManager — so a 160-bit pool word cannot name one. Balancer, Maverick
// and anything else 1inch reaches are in the same position.
bytes4 constant SWAP_SELECTOR   = 0x07ed2379;

// ⛔ §SESS-86 — **THE WHOLE V4 CONSTANT BLOCK IS DELETED WITH `V4Lib`.** `UNIVERSAL_ROUTER`,
// `PERMIT2`, `UR_EXECUTE`, `CMD_V4_SWAP`, the three action bytes, `PROTO_V4`, the two word offsets,
// `struct PoolKey`, `struct V4ExactInputSingleParams` and `interface IPermit2` had **zero users**
// outside the library, and the library's one on-chain call site was unreachable (`_hubHop` is only
// entered with `hub == 0` or a CURVE word, and `venue_word(Venue::V4)` returns `None` so no v4 word
// is ever produced). Standing rule 23: a declaration nothing can reach is not a declaration.
// ⚠️ **THE MEASUREMENT STANDS AND IS WORTH KEEPING**: the v4 singleton holds USDS 76,178,513 and GHO
// 2,270,133 against 10,928 and 8,179 on UniswapV3, and a hookless GHO/USDC fill was executed at par.
// v4 is the right venue for those two — it just has to arrive as an OFF-CHAIN-BUILT ROUTE like every
// other venue, not as ~80 lines of nested `abi.encode` and a linked deployment. Booked in L-routing.
// ⭐ §SESS-92 — **SKY'S `DaiUsds` 1:1 CONVERTER: THE ONLY PATH USDS HAS.**
// 🔴 **MEASURED FIRST, AND THE OBVIOUS ANSWER WAS A TRAP.** Curve's registry answers
//    `find_pool_for_coins(USDS, USDC)` with `0x364EE692…` — whose `coins(0)` is **USDT**, whose
//    balances are **ZERO**, and whose `get_coin_indices` returns `i = 5` for a two-coin pool.
//    Adding it as a seventh row would have been one line and a dead venue. §SESS-24 rejected
//    `0xEf3a1CaE…` for the same class of registry answer; the registry is not evidence.
// ⇒ USDS reaches USDC as **USDS → DAI (1:1, no pool, no slippage, no depth limit) → USDC** on the
//   DAI row that is already on the table and already pinned. Verified on-chain: `dai()` and `usds()`
//   return the canonical tokens and the contract carries 2,859 bytes of code.
address constant DAI_USDS        = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
bytes4  constant SKY_USDS_TO_DAI = 0x68f30150;   // usdsToDai(address,uint256)
bytes4  constant SKY_DAI_TO_USDS = 0xf2c07aae;   // daiToUsds(address,uint256)
address constant USDS_TOKEN      = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

// ⭐ §SESS-94 — **MEASURED: `proto = 0` IS THE UNISWAP-V2 FAMILY AND IT FILLS THROUGH `unoswap`.**
// Executed at FORK_BLOCK 25927822, 25,000 USDC in: UniswapV2 USDC/WETH → **9.983 WETH**, SushiSwap
// USDC/WETH → **8.480 WETH**, against the V3 control's 10.019 under `proto = 1`. `proto = 2` (Curve)
// and `proto = 3` filled ZERO on every pool, both direction bits.
// 🔴 **THIS OVERTURNS THE LINE EVERYTHING KEYLESS WAS BUILT ON.** §SESS-22 concluded *"proto = 1 is
// the ONLY protocol id measured to fill"* — but it only ever tested CURVE, and the conclusion was
// generalised to every non-V3 venue. Keyless coverage sat at 11/14, and GHO/FRXUSD were called
// key-only, because of a claim that was never tested against a V2 pool.
// ⚠️ **V2 FILLS ONLY WITH BIT 247 SET**, and `_deriveBit` used to skip every non-V3 word — so that
// bit arrived caller-supplied and unchecked. Deriving it for `proto = 0` closes a hacked-keeper hole
// and is what makes the family safe to admit, not merely reachable.
uint256 constant PROTO_UNIV2   = 0;
uint256 constant PROTO_CURVE   = 2;
uint256 constant HOP_I_OFFSET  = 160;
uint256 constant HOP_J_OFFSET  = 168;
uint256 constant PROTO_UNIV3   = 1;             // `dex >> 253` for a UniswapV3 pool
uint256 constant ZERO_FOR_ONE  = uint256(1) << 247;  // V3 direction flag, DERIVED by `routedSwap`

// §RANGE-UNWIND — the venue the RANGE falls back to when it force-closes a lever with no keeper to
// name one (see `LevBase._unwindDex`). Uniswap V3 WETH/USDC 0.05%, the deepest ETH/USDC pool on
// mainnet; `routedSwap` derives the direction, so ONE word serves both legs.
// ⛔ NOT OVERRIDABLE — this said "GOV-overridable" and there was no GOV path to override it with.
// This system has no governance knobs; repointing it is a code change and a redeploy.
uint256 constant DEFAULT_UNWIND_DEX =
    (PROTO_UNIV3 << 253) | uint256(uint160(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640));

// §SESS-92 — the WBTC twin. UniswapV3 USDC/WBTC 0.30%, the pool `dex_word_wbtc()` has always named
// off-chain and `AggSwapTwoHop.t.sol` measures against. ⛔ Same rule: not overridable, a code change.
// 🔑 **WHY A DEFAULT EXISTS AT ALL.** `routedSwap` used to revert `NoVolatileRoute` on an empty
// route, which was correct while a caller could pass POOL WORDS instead — §SESS-91 deleted those, so
// "no route" stopped meaning "names no venue" and started meaning "cannot trade at all". That took 39
// lev tests down with `NoVolatileRoute()`, and `LevMath:1380` already recorded the same incident at
// 17 tests. ⇒ an empty route now means **the protocol's own default venue**, which is a defined
// behaviour and the same one `LevBase._unwindDex` already relies on for a keeper-less force-close.
uint256 constant DEFAULT_WBTC_DEX =
    (PROTO_UNIV3 << 253) | uint256(uint160(0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35));
address constant WBTC_TOKEN = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

/// @dev The one V3 accessor `routedSwap` needs: which token a pool calls `token0`, so the direction
///      flag is computed from `tokenIn` instead of taken on trust from a keeper.
// §SESS-92 — `token1()` joins `token0()`: `LevMath._poolToken` reads EITHER through one shared
// staticcall, so deriving a direction bit still costs exactly one call and the new
// "does this pool hold what we are selling" check costs two only where it is asked.
interface IUniV3PoolMin {
    function token0() external view returns (address);
    function token1() external view returns (address);
}




// Stableswap legs: the borrowed stable → USDC, before the volatile venue takes USDC → WETH/WBTC.
// 🔴 THE TWO POOLS ARE ORDERED OPPOSITELY. Read from mainnet 2026-08-15:
//     0xD001aE43…  coins(0)=USDC  coins(1)=RLUSD   ⇒ RLUSD is 1, USDC is 0
//     0x383E6b44…  coins(0)=PYUSD coins(1)=USDC    ⇒ PYUSD is 0, USDC is 1
// A SHARED index constant would therefore be silently wrong for one of them — wrong-pair swap at
// size, no revert, no id to assert against. Each pool carries its own pair of indices for that reason.
// Token handles for the routing branch (the basket's own stables; USDC is the routing hub).
// USDC — the stable ROUTING HUB, and the ONE declaration of this address (rule 2). Named for the
// ROLE, not for a venue: `_routableStable` and the hub hop reach it with no pool in the name. The
// genuine venue names below are the POOL and its coin indices, and those stay.
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

// §SESS-24 — FOUR MORE ROWS, EVERY FIGURE READ FROM THE CHAIN AT `FORK_BLOCK=25800000`.
// ⚠️ **PICKED BY DEPTH AT SIZE, NOT BY REGISTRY ORDER.** Curve's MetaRegistry
// `find_pool_for_coins(from,to,0)` returns *a* pool, not the deepest — for PYUSD it returns
// `0x61fA2c94…`, which is NOT the pool this tree already verified. Every row below was found by
// enumerating candidates, REJECTING metapools (`is_underlying == true` ⇒ our `curveExchange` calls
// `exchange`, not `exchange_underlying`, so the quote would price a swap we cannot execute), and
// verifying the indices with `coins(i)`/`coins(j)` on the pool ITSELF rather than trusting the
// registry — the standing rule that *"a wrong index swaps the wrong pair at size and there is no id
// to assert against."*
// ⛔ **AND A POOL THAT MERELY DOES NOT REVERT IS NOT A CANDIDATE.** `0xEf3a1CaE…` answers `get_dy`
// for PYUSD, GHO, RLUSD and USDS alike with **427 USDC per 10,000 in** — a 95% loss, no revert. A
// "didn't revert" filter would have taken it. Depth is the discriminator, exactly as §E292's removed
// venue taught.
// MEASURED COST, 10k / 100k / 1M (bps): USDT 4/4/4 · DAI 1/1/1 · USDG -1/-1/-1 · crvUSD 0/0/0.
// All four are FLAT to $1M, which is the bar the predecessor venue failed between $10k and $25k.
address constant CURVE_3POOL           = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
address constant USDT_TOKEN            = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
int128  constant CRV_USDT_IDX          = 2;
int128  constant CRV_USDT_USDC_IDX     = 1;
address constant DAI_TOKEN             = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
int128  constant CRV_DAI_IDX           = 0;
int128  constant CRV_DAI_USDC_IDX      = 1;
address constant USDG_TOKEN            = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
address constant CURVE_USDG_USDC       = 0xc061caa073f3d95F80f8e5428d32D2d76F5e1622;
int128  constant CRV_USDG_IDX          = 0;
int128  constant CRV_USDG_USDC_IDX     = 1;
address constant CRVUSD_TOKEN          = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
address constant CURVE_CRVUSD_USDC     = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
int128  constant CRV_CRVUSD_IDX        = 1;
int128  constant CRV_CRVUSD_USDC_IDX   = 0;

// 🔴 CURVE'S TWO FAMILIES ENCODE INDICES DIFFERENTLY — stableswap `int128`, crypto-swap
// `uint256` — and calling the wrong one REVERTS (CLAUDE.md records the uint256 variant reverting on
// the weETH/WETH ng pool). Reverting is the SAFE failure: a mis-encoded index would otherwise swap
// the wrong pair. ⇒ a crypto-swap surface, if one is ever needed, gets its OWN interface; NEVER an
// overload on `ICurvePool`, which would let a caller pick the wrong ABI by integer-literal inference.
// §E240-tri — `ICurvePool` (int128 stableswap) stays, and `ICurveOracle` (declared below) is a
// separate, still-live price surface -- do not confuse them.

interface IEtherFiLiquidityPool { function requestWithdraw(address r, uint a) external returns (uint); }


/// Canonical IDepositAdapter — union of the former per-file variants.
interface IDepositAdapter {
    function depositWETHForWeETH(uint _amount, address _referral) external;
    function weETH() external view returns (address);
}

/// Canonical IAaveV4Hub — union of the former per-file variants.
interface IAaveV4Hub {
    function getAssetId(address underlying) external view returns (uint256);
    /// §S12 — **THE CASH.** MEASURED 2026-09-05 at `FORK_BLOCK=25800000` against the live hub
    /// `0xCca852Bc`: this returns the hub's own token balance to within dust (USDT/USDG/GHO drift
    /// EXACTLY 0; USDC drift 315 units = $0.0003 of donated dust). The spokes hold effectively
    /// nothing themselves — `USDC/USDG/GHO.balanceOf(spoke)` are all 0 and USDT is $1,001 against
    /// $2.87M at the hub — so in v4's hub-and-spoke shape **the hub holds the liquidity and this is
    /// the only honest "can we actually get it out" number.**
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
}

/// Canonical ILevEquity — ONE interface over BOTH lev managers, the ETH one and the BTC one.
///
/// §LEV-FOLD-2 — ONE FACE IS SAFE HERE BECAUSE THE MIS-ASSIGNMENT IS UNCONSTRUCTIBLE, not because
/// it would be harmless. Per-asset accessors would only CLAMP a wrong-manager call — once per call,
/// forever, and only where the caller happens to reach for the suffixed name. Instead `setLevManager`
/// refuses any manager whose `ORACLE_KEY` is not the pinning range's own asset, so a BTC manager
/// cannot be pinned to the ETH range at all and there is no wrong-manager handle for a caller to
/// hold. Standing rule 17 — a root fix makes the previous guard DELETABLE, which is exactly the
/// test for whether it was a fix or a clamp.
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



/// Canonical ICollection view.
/// ⚠️ `transferFrom` here is ERC-721 (`tokenId`) and shares its ABI signature with
///    `IERC20Min.transferFrom` (`amount`). Same selector, different meaning — do not merge them.
interface ICollection {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getApproved(uint tokenId) external view returns (address);
}

/// Canonical Chainlink aggregator view.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns ( uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}


/// Canonical Aux view — union of FIVE former per-file variants, which described ONE contract, so a
/// signature change had to be made up to six times and a missed one still compiled.
/// @notice §E296 — `ISwap.sol` and `ILevVenue.sol` folded in (standing rule 2: one declaration per
///         interface, in THIS file). Both files existed ONLY to hold interfaces, so both are deleted.
///         `IAux is ISwap` rather than restating its three members: `getTWAPforAsset`, `resolvedTwap`
///         and `swap` were declared in BOTH places and had DRIFTED — `Aux.swap` is `public payable`
///         (`Aux.sol:862`), `ISwap` agreed, and `IAux` said non-payable. No `src` caller used either
///         handle, so the wrong selector never fired; that is exactly the §E21 failure mode this rule
///         exists to prevent, caught this time before it could bite.
/// @notice Aux's public stable<->volatile swap surface (Aux.sol `swap`), declared
///         once here as the single source of truth. `Aux` implements it; peripherals consume
///         it without re-declaring a duplicate interface. `token` = stable side (or QUID/zero),
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
    function takeWith(address who, uint amount, address token, uint seed, uint[16] memory amounts, uint[16] memory yieldW) external returns (uint);
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
    function get_deposits() external returns (uint[16] memory amounts, uint[16] memory yieldW, uint avgYield, uint depegLoss);
    function getStables() external view returns (address[] memory);
    function getVaults(address stable) external view returns (address[] memory);
    function AAVE_SPOKE() external view returns (address);
    function AAVE_HUB() external view returns (address);
    function ethVenue() external view returns (address);
    function GHO_RESERVE_ID() external view returns (uint256);
    function USDG_RESERVE_ID() external view returns (uint256);
    function aaveReserveId(address stable) external view returns (uint256);
    function deposit(address from, address token, uint amount) external returns (uint);
    function avgYield() external view returns (uint);
    function vaultBlocked(address vault) external view returns (bool);
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
    function redeem(uint amount) external;
}
/// The ONE ERC-20 slice for the whole leverage cluster (LevManager / LevMath / BtcLevManager).
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
/// do not each declare a private variant.
interface IWETH9 is IERC20Min { function deposit() external payable; function withdraw(uint256) external; }

/// @title  ILevVenue — per-LP isolated borrow-venue adapter for the leverage overlay
/// @notice Each LP's leverage lives in its OWN isolated position on the venue (the LP is the venue
///         account / borrower); `LevManager` orchestrates the constant-LTV logic venue-agnostically
///         through this interface, so one LP's liquidation can never cascade into a shared pile. The
///         adapter owns the per-venue isolation mechanism (Morpho authorization, a per-LP Liquity Trove,
///         Aave sub-account) and the HARD risk params (liq threshold, oracle) — those are NOT
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
    /// @dev    Surfaced on the interface so `LevManager` can call it before it SIZES anything
    ///         (`LevManager.sol:539`); it is the fix for the pre-accrual drift that
    ///         `MorphoEscrowVenue.accrue`'s own docblock describes.
    ///         Permissionless (Morpho's `accrueInterest` is), idempotent within a block, and a
    ///         NO-OP on a venue whose debt view already reflects accrued interest at read time.
    function accrue() external;

    /// @notice Repay `stableAmount` of `lp`'s debt (the stable was already transferred in). Repays at most
    ///         the outstanding debt; the de-lever paths in `LevMath` cap the transfer IN to the
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
    // `stable()` above and `COLLATERAL()` here come from the SAME implementor — verified as one
    // implementor rather than one address (the `EthVenue`-split lesson): `LevVenueBase` provides
    // BOTH `COLLATERAL()` (a `public immutable`, so its getter is auto-generated) and
    // `supply(address,uint256)`.
    function COLLATERAL() external view returns (address);

    /// @notice Venue liquidation threshold in bps of collateral value (e.g. 8000 = 80% LLTV).
    function liqThresholdBps() external view returns (uint256);

    /// @notice The venue's whole position, AS THE VENUE ITSELF VALUES IT.
    /// @dev    §CHEAPEST-DOLLAR — this is what lets one collateral position carry SEVERAL debts
    ///         without any basket accounting on our side: we ask the lender what it thinks the
    ///         position is worth instead of pricing the legs ourselves.
    ///         ⭐ **THE QUOTE UNIT ONLY HAS TO BE CONSISTENT WITHIN A VENUE, AND THAT IS WHY THIS IS
    ///         SOUND.** Every consumer of these two numbers uses their RATIO (LTV, health, headroom),
    ///         which is unitless — so Aave may answer in its 8-dec oracle USD and Morpho in
    ///         loan-token terms and the two never need reconciling. **Cross-venue comparison happens
    ///         through `borrowRateRay`, which is already a pure rate.** Do not "fix" this into a
    ///         single global unit: that would buy nothing and would put an oracle into every adapter.
    ///         ⚠️ Both amounts are lifted to 18 decimals so the ratio has room, NOT because they are
    ///         commensurable across venues.
    function position() external view returns (VenuePosition memory);

    /// @notice How much MORE collateral this venue can accept RIGHT NOW, in COLLATERAL token units.
    ///         `type(uint256).max` when the venue is uncapped.
    /// @dev    §V4-IS-FULL — the third dynamic quantity the allocator needs, and the one that was
    ///         missing. Rate is live (`borrowRateRay`) and BORROW capacity is live (an unfundable
    ///         draw reverts) — but COLLATERAL capacity was measured off-chain and written into a
    ///         ledger row, which is not a measurement a running system can act on. **A supply cap is
    ///         governance-mutable and can change in any block**, so an allocator that ranks venues by
    ///         rate alone will eventually pick one it cannot enter and fail at execution.
    ///         ⭐ It also deletes a human step: §V4-IS-FULL said *"do it when the cap lifts"*, which
    ///         needs someone watching. Read on-chain, the venue simply becomes eligible again.
    ///         ⚠️ This is a READ, deliberately — it does NOT clamp `supply()`. Exceeding a cap should
    ///         REVERT loudly at the venue rather than silently partial-fill (standing rule 3).
    function supplyHeadroom() external view returns (uint256);

    /// @notice `lp`'s OWN slice of `position()`, in the same quote unit.
    /// @dev    ⚠️ **PER-LP LTV IS NOT POOL LTV, AND SUBSTITUTING ONE FOR THE OTHER IS A REAL BUG.**
    ///         The venue is POOLED (§POOL-VENUE): `debtUnits[lp]/totalDebtUnits` and
    ///         `collUnits[lp]/totalCollUnits` are INDEPENDENT fractions, so an LP's debt-to-collateral
    ///         ratio equals the pool's only when those two shares happen to be equal. Every per-LP
    ///         health question must go through this, and every pool-level one through `position()`.
    function positionOf(address lp) external view returns (VenuePosition memory);

    /// @notice The borrow APR, in RAY (1e27), that would apply to `stable()` on this venue if
    ///         `extraBorrow` MORE were drawn right now. `extraBorrow == 0` is the current rate.
    /// @dev    §CHEAPEST-DOLLAR — this is the ONE new accessor the allocator needs, and the reason
    ///         it takes a size rather than being a plain getter: **a spot rate is a rate that stops
    ///         existing when we arrive.** Measured on Aave v3, USDT moves 4.08% → 4.45% at +$25M and
    ///         → 7.49% at +$100M, so comparing two venues at spot compares two counterfactuals.
    ///         ⭐ EVERY IMPLEMENTATION DELEGATES TO THE PROTOCOL'S OWN RATE VIEW rather than
    ///         reconstructing its curve — see `CalcRatesParams`. A reconstruction was measured wrong
    ///         by 2-16 bps on the first try and would drift silently on any IRM upgrade.
    ///         ⚠️ MAY REVERT when `extraBorrow` exceeds what the venue can fund; that is a feature,
    ///         not a case to catch — an unfundable borrow has no rate.
    function borrowRateRay(uint256 extraBorrow) external view returns (uint256);
}


/// Canonical Core view — union of FOUR former per-file variants, which described ONE contract, so a
/// signature change had to be made up to four times and any missed one still compiled.
interface ICore {
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    function modLP(int256 delta, int256 deltaUSD, address sender) external returns (uint sent);
    /// §OOR-AS-INTENT — settle ONE filled intent. Both legs at once, because a fill is a TRADE.
    /// ⚠️ THIS SURVIVED THE BOOK'S DELETION AND IS NOW ITS ONLY CONSUMER: `Quid.fillIntent` calls
    /// it with the deltas `SwapLib.fillIntentBody` derives AT THE SIGNED LIMIT, not at spot.
    function settleOor(address owner, int256 usdDelta, int256 volDelta, bool loadBalance) external;
    function POOLED() external view returns (uint);
    function btcThetaBacking() external view returns (uint);
    function poolStats() external view returns (uint priceWad, uint liquidity);
    // §ISBTC-SPLIT — ONE ARGUMENT: each `Core` instance owns exactly one ring, so there is nothing
    // left to select. ⚠️ MUST MATCH `Core.observe(uint32[])` EXACTLY. A drifted declaration is
    // INVISIBLE to the compiler — an external call through an interface is encoded from the
    // DECLARATION — and reverts at RUNTIME with "unrecognized function selector" inside every
    // fixture's setUp.
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
    function redeemEwmaUsd() external view returns (uint);
    /// §SESS-18 — swap flow + redemption unwinds; what BOTH skews price scarcity against.
    function skewTargetUsd() external view returns (uint);
    function realizedVarianceWad() external view returns (uint);
    function riskParams() external view returns (uint confFracWad, uint spliceFloor);
    function recordSkewPremium(uint256 premiumUsd, uint256 premiumNative) external;
    function retainedEthPremium() external view returns (uint256);
    function refundUnfilled(address token, uint amount, address to) external;
    function repack(uint anchorPrice) external returns (uint price);   // §ONE-ANCHOR: bounds derive from this
    
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

    // ═══ ONE INTERFACE FOR CORE AND BOTH RANGE MANAGERS ═══
    // The pool face and the range face named the same objects from opposite sides, so they were one
    // concept wearing two nouns: `Core`, `Quid` and `Vault` all cast to `ICore`.
    // ⚠️ THIS INTERFACE DELIBERATELY OVER-PROMISES, AND THAT IS THE COST OF ONE NOUN. No single
    //    contract implements all 47 members: `Core` has the pool surface, `Quid` and `Vault` the
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

    // ═══ ONE RANGE FACE, NOT TWO ═══
    // The two former faces shared ZERO member names and `Quid` and `Vault` each implement BOTH, so
    // they were never two objects - only two names for one. Nothing was declared twice, which is why
    // standing rule 2 never flagged it; the defect was that a caller holding a range had no way to
    // know which of two faces to reach for, in a codebase whose target is ONE range manager.
    // ⚠️ `feesPerShare`, `USD_FEES` (`Shares.sol:126-127`) and `CORE` (`Quid.sol:78`, `Vault.sol:84`)
    //    are PUBLIC STATE, not functions - their getters are auto-generated, so grepping for their
    //    `function` form in `Quid.sol` returns 0
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
    // ⚠️ `Core` implements NONE of the three members below: `ICore` is the polymorphic RANGE-MANAGER
    // face as well as the pool face, and these three are `Quid`-only — ABI-legal, and exactly how the
    // merged face already works.
    function unwindForRedeem(uint usdWanted) external returns (uint usdFreed);
    function pendingRewards(address user) external view returns (uint ethReward, uint usdReward);
    function setBTCChannels(address b) external;

    /// §SLOP — ONE NAME FOR BOTH RANGES. The interface IS the polymorphism; a per-asset second name
    /// for the same call would defeat the reason it exists.
    function syncLev(address lp) external;
    function soldFractionWad(uint syncKeyPx) external view returns (uint256);
    function rangePrice() external view returns (uint);
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
    /// @notice The lev manager this venue hosts.
    function LEV_MANAGER() external view returns (address);
}


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
    function btcRecipientPoPDigest(address lpEth, bytes32 bindHash) external view returns (bytes32);
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

/// Canonical Basket turn/maturity view.
interface IBasket {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
    function immatureBalanceOf(address who) external view returns (uint);
    /// `target()` lives in `Basket.sol` alongside the three above.
    /// 📖 **NAMING, SO IT IS NOT RE-READ AS DRIFT:** `Basket` is the QU!D token contract, and the
    /// variables that hold it are named `quid` accordingly — `DeployLib:171` `Basket quid = new
    /// Basket(...)`. The contract *named* `Quid` is the ETH RANGE (`DeployLib:118` `Quid ethRange = new
    /// Quid()`). **Deliberate and correct: the type names the implementation, the variable names the
    /// role.** So `IBasket(quid)` reads the QU!D token, which is what `turn`, `matureSupply`,
    /// `immatureBalanceOf` and `target` all belong to.
    /// ⇒ Interfaces here are named for the CONTRACT they address, never for the variable at the call
    /// site.
    function target() external view returns (uint);
    /// @notice Mint `amount` against `pledge`'s deposit of `token`, dated `when`.
    function mint(address pledge, uint amount, address token, uint when) external returns (uint);
}

/// BTC swap-out de-lever surface on the BTC LevManager. (was SwapLib.ILevManagerDeliver)
interface ILevManagerDeliver {
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external returns (uint usedUsd, uint freedSats);
    /// §PAUSED-VAULT-REROUTE — convert whatever the basket ACTUALLY paid into the venue's own loan
    /// token and deliver it there, so a paused vault reroutes instead of denying service.
    function consolidateForRepay(address lp, address refundTo) external returns (uint sent);
}
/// M.1 ETH delivery-side de-lever. Distinct from BTC's `swapOutDelever` (ETH DELIVERS WETH to a
/// recipient; BTC un-encumbers spliced sats), and ETH is POOLED so it walks the book.
/// (was SwapLib.ILevEthDeliver)
interface ILevEthDeliver {
    function openLevCount() external view returns (uint);
    function openLpAt(uint i) external view returns (address);
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    // ⛔ DO NOT RE-ADD `swapOutDelever(address,uint,address,uint)` HERE. §J2-LEV-ARITY was RESOLVED BY
    //    DELETION (see the block at `LevManager.sol` above `swapOutDeleverPooled`): the per-LP ETH form
    //    is GONE from the tree, superseded by `swapOutDeleverPooled(venue, …)`. Only the BTC 3-arg
    //    `swapOutDelever` on `ILevManagerDeliver` still has an implementation. A declaration of a
    //    function that no contract implements COMPILES and reverts at run time on a missing selector —
    //    the exact silent-failure shape this file exists to prevent. Removed 2026-09-08 with zero
    //    callers in `evm/src`, `evm/test`, `evm/script`, `spa/`, `app/`, `indexer/` or `quid-ln/`.
    /// §POOL-VENUE — the pinned pool venue, or 0 if this range has never opened a position. Reading
    /// THIS rather than `openLpAt(0)` is what stops a de-lever silently skipping a pool that still
    /// holds collateral after its last LP closed.
    function poolVenue() external view returns (address);
    /// §POOL-VENUE — the AGGREGATE delivery de-lever. Takes a VENUE, not an LP: the position is pooled,
    /// so there is no per-LP repay to name. Replaces the O(LPs) walk `deleverEthOnDelivery` used to do.
    function swapOutDeleverPooled(address venue, uint stableUsd, address recipient, uint minWethOut,
        uint askNative) external returns (uint usedUsd, uint wethDelivered);
    function swapOutDeliverUnlevered(address lp, uint wethWanted, address recipient, uint minWethOut)
        external returns (uint wethDelivered);
}

interface IBtc {
    // BTC LP position: open/close/splice (driven on channel open/close).
    function requestDeposit(address lpEth, uint sats) external;
    function requestRedeem(address lpEth, uint lpPayoutSats) external;
    // ⚠️ A DECLARATION AND ITS IMPLEMENTATION MUST BE REMOVED TOGETHER: leaving the declaration
    // behind is what lets a deleted implementation still compile at the call site.
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
    /// @notice Returns totalCollateralBase, totalDebtBase and availableBorrowsBase (all 8-dec
    ///         oracle USD), then currentLiquidationThreshold and ltv (bps, POSITION-WEIGHTED across
    ///         every reserve the account holds), then healthFactor (WAD, max when debtless).
    /// @dev    ⭐ THIS IS THE WHOLE MULTI-DEBT GENERALISATION. Aave already aggregates and prices an
    ///         account's entire basket of debts with the SAME oracles it liquidates on, so a venue
    ///         holding GHO and USDT and DAI at once needs no basket accounting of its own — and the
    ///         health number it reports becomes, by construction, the one Aave will act on.
    ///         ⚠️ Returns ZEROS for an unknown account rather than reverting (verified 2026-08-30),
    ///         which is what makes the pre-escrow case cost no special-casing.
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor);
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
/// @notice Aave's OWN interest-rate view. §CHEAPEST-DOLLAR — we ask Aave what the rate WOULD BE
///         rather than reimplementing its kinked curve, per standing rule 8. Measured 2026-08-30:
///         a hand-rolled `Uopt/slope1/slope2` reconstruction gave USDT +$25M as 4.47% where Aave's
///         own view says **4.45%**, and +$100M as 7.65% against **7.49%** — close, and wrong, and it
///         would drift again the next time Aave changes an IRM.
/// @dev    ⭐ IT ALSO ENFORCES CAPACITY FOR FREE: `liquidityTaken` above the virtual balance REVERTS
///         (measured on GHO, whose $24M ceiling makes a $25M draw underflow), so an unfundable borrow
///         cannot return a flattering rate — it cannot return at all.
struct CalcRatesParams {
    uint256 unbacked;
    uint256 liquidityAdded;
    uint256 liquidityTaken;
    uint256 totalDebt;
    uint256 reserveFactor;
    address reserve;
    bool    usingVirtualBalance;
    uint256 virtualUnderlyingBalance;
}

/// @notice A venue position in the venue's own quote unit, 18-dec. See `ILevVenue.position`.
struct VenuePosition {
    uint256 collateral;      // quote-unit value of collateral, 18-dec
    uint256 debt;            // quote-unit value of ALL debts, 18-dec
    uint256 liqThresholdBps; // LIVE and position-weighted, not the constructor's constant
}

interface IAaveV3RateStrategy {
    /// @return liquidityRate, variableBorrowRate — both RAY (1e27) APRs.
    function calculateInterestRates(CalcRatesParams memory params)
        external view returns (uint256, uint256);
}

/// @notice Morpho's rate view. Takes the market state AS AN ARGUMENT, which is exactly what lets us
///         price a HYPOTHETICAL borrow: hand it the market with our draw already added.
/// @dev    ⚠️ RETURNS WAD PER SECOND, where Aave returns RAY PER YEAR. `borrowRateRay` normalises.
struct MorphoMarket {
    uint128 totalSupplyAssets; uint128 totalSupplyShares;
    uint128 totalBorrowAssets; uint128 totalBorrowShares;
    uint128 lastUpdate;        uint128 fee;
}

interface IIrm {
    function borrowRateView(MarketParams memory marketParams, MorphoMarket memory market)
        external view returns (uint256);
}

interface IAaveV3DataProvider {
    function getInterestRateStrategyAddress(address asset) external view returns (address);
    /// @notice (borrowCap, supplyCap) in WHOLE TOKENS, not wei. ⚠️ **`0` MEANS UNCAPPED** in Aave's
    ///         convention, not "no room" — reading it as a quantity inverts the meaning exactly.
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);
    /// @notice Aave's TRACKED virtual balance. ⚠️ NOT the same as `totalAToken - totalDebt`, and the
    ///         difference is not noise: deriving it instead of reading it made `borrowRateRay`
    ///         disagree with Aave's own live rate by 2.6e-6 relative on USDT (2026-08-30). It
    ///         matched EXACTLY on GHO — whose rate is flat, so no input error can surface — which is
    ///         precisely why the equality control has to run on a SLOPED market to mean anything.
    function getVirtualUnderlyingBalance(address asset) external view returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 unbacked, uint256 accruedToTreasuryScaled, uint256 totalAToken,
        uint256 totalStableDebt, uint256 totalVariableDebt, uint256 liquidityRate,
        uint256 variableBorrowRate, uint256 stableBorrowRate, uint256 averageStableBorrowRate,
        uint256 liquidityIndex, uint256 variableBorrowIndex, uint40 lastUpdateTimestamp);
    function getReserveConfigurationData(address asset) external view returns (
        uint256 decimals, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus,
        uint256 reserveFactor, bool usageAsCollateralEnabled, bool borrowingEnabled,
        bool stableBorrowRateEnabled, bool isActive, bool isFrozen);
    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt,
        uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate,
        uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled);
}
