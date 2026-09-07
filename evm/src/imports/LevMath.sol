// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WAD, VenueNotAllowed} from "./Types.sol";
// §A.52: the canonical view lives in Interfaces.sol — imported, never re-declared file-local.
import {ICore, IAux, IWeETH, IDepositAdapter, ILevVenue, TWAP_WINDOW_SECS} from "./Interfaces.sol";
import {IERC20Min, IWETH9} from "../imports/Interfaces.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, SWAP_SELECTOR, PROTO_UNIV3,
        ZERO_FOR_ONE, IUniV3PoolMin, ICurvePool, CURVE_USDC_RLUSD, CRV_RLUSD_IDX, CRV_RLUSD_USDC_IDX, CURVE_PYUSD_USDC, CRV_PYUSD_IDX, CRV_PYUSD_USDC_IDX, USDC, RLUSD_TOKEN, PYUSD_TOKEN, CURVE_3POOL, USDT_TOKEN, CRV_USDT_IDX, CRV_USDT_USDC_IDX, DAI_TOKEN, CRV_DAI_IDX, CRV_DAI_USDC_IDX, USDG_TOKEN, CURVE_USDG_USDC, CRV_USDG_IDX, CRV_USDG_USDC_IDX, CRVUSD_TOKEN, CURVE_CRVUSD_USDC, CRV_CRVUSD_IDX, CRV_CRVUSD_USDC_IDX} from "./Interfaces.sol";

// ether.fi weETH/WETH Curve pool (weETH is coin1, WETH coin0). Same address as Vault.ETHERFI_CURVE_POOL.
address constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
import {IMorphoBase as IMorphoFlash} from "../imports/Interfaces.sol";
/// @dev Token/SOR surfaces the leg mechanics touch. IERC20Min + IWETH9 come from ILevVenue (shared).
/// ONE Aux surface for everything LevMath touches on it (redeem / stables / TWAP / SOR both directions / venue /
/// health) — was five tiny IAux* slices (consolidation).
// ETH-side sell/buy machinery surfaces — moved here (delegatecall, bytecode OUTSIDE LevManager for EIP-170).
/// Morpho Blue zero-fee flash surface — the ONLY flash source (see LevManager.IMorphoFlash). Mirrored here so the
/// moved de-lever bodies (`deleverFlashBody`) can invoke it from the manager's delegatecall context.
/// The range surface the derived band + the reseat decision read. Mirrors the managers' `ICore`
/// handle — a delegatecall'd library can't read their immutables, so the manager passes the
/// range address in. All view: the three members this file reaches (`kLvrWad`, `rangePrice`,
/// `rangeBounds`) are `view` fns or auto-generated getters over `public` state, so `view` external calls are
/// STATICCALL-safe inside the try/catch below (Solidity allows try/catch on view calls) and callable from
/// both view and non-view callers.

/// @title  LevMath — asset-agnostic IL-protect leverage economics + up-side leg mechanics
/// @notice ONE leverage library shared by the ETH (`LevManager`, weETH) and BTC (`BtcLevManager`, vBTC) paths.
///         Holds the up-side IL-protect economics + money-movement bodies: the IL-cancelling target
///         (`1 − √(entry/now)`), net-equity, debt-delta, and the lever-up/de-lever/flash-close leg mechanics, all
///         `public` (delegatecall-linked, bytecode OUTSIDE the manager) so the managers fit EIP-170. Only the
///         *acquisition/exit rails* differ between assets — the economics don't — so both managers reuse this. Leg
///         funcs run in the MANAGER's context (`address(this)`==manager); immutables the manager owns (AUX/volatile)
///         come in via the cfg structs. Routing is SPLIT BY LEG TYPE and no longer "all Curve":
///         the STABLE hops (stable↔USDC) are Curve stableswap, and every VOLATILE hop
///         (USDC↔WETH, USDC↔WBTC) goes through `_aggSwap` against the pinned 1inch router.
///         §V-R1-MIN's keeper discipline survives the aggregator: `_aggSwap` takes a POOL WORD, so
///         the keeper names a VENUE and never a rate — the amount, the floor and the callee are ours.
///         The USDC<->volatile Curve leg is GONE from this file — only weETH→WETH (`ETHERFI_CURVE_POOL`) remains
///         Curve-on-a-volatile-pair, and that is a dedicated LST pool, not a router.
///         (The below-entry SHORT / inverse-venue subsystem was removed — up-side-only is the design.)
library LevMath {
    using SafeERC20 for IERC20OZ;


    /// Zero oracle anchor. A named error, NOT a string require: the string form cost enough
    /// bytecode to push this library 38 bytes past EIP-170 (measured).
    error NoPrice();

    /// @notice The LTV (bps) of `debt` against a position worth `collValue` (same unit); `collValue==0 ⇒ 0`.
    ///         The leverage's target leverage is L = 2 — the IL-vanishing point: a constant-L position has
    ///         `V* ∝ V_c^L`, a √p range has `V_c ∝ √p`, so `V* ∝ p^(L/2)` and L=2 ⇒ `V* ∝ p` (IL cancels),
    ///         = 2·α⁻¹ (measured α≈0.5). ⛔ THERE IS NO SAFE-DEBT ENVELOPE TO ADD BACK HERE: solvency is
    ///         held by the LTV-range rebalance (`debtDelta`) plus each venue's own LLTV health, and a
    ///         second MIN/MAX band over the same quantity is a bound with no one reading it.
    function ltvBps(uint256 debt, uint256 collValue) internal pure returns (uint256) {
        if (collValue == 0) return 0;
        return (debt * 10_000) / collValue;
    }

    /// @dev    §DERIVED-BAND — the body of `LevBase._bandBps`, moved here so it lands in this library
    ///         rather than being inlined into both managers (see the note on `noTradeBandBps`). The
    ///         caller's immutables are parameters because a delegatecalled library cannot read them.
    ///
    ///         `K` comes through the pinned range in the same `try/catch` idiom as
    ///         `LevBase._rangePrice()`: the range is genuinely unset between deploy and `init`, and a
    ///         revert there must not strand a position. Unmeasured ⇒ band 0 ⇒ always rebalance,
    ///         which is the fail-open direction argued at `noTradeBandBps`.
    /// @param aux         the manager's `AUX`, for the ETH/USD TWAP that prices gas.
    /// @param range       the pinned range, source of `kLvrWad()`. Zero ⇒ unmeasured ⇒ 0.
    /// @param twapWindow  the SAME window the IL target is priced with, so the band cannot be
    ///                    widened by a spot print the target ignores.
    /// @param gasRebalance measured gas for one rebalance; the live PRICE of it is `block.basefee`.
    /// @param collUsdWad  position size, USD 1e18.
    /// @param headroomBps `venue.liqThresholdBps() − TARGET_LTV_CAP_BPS`, resolved by the caller because
    ///        the VENUE is the caller's to know. §POOL-VENUE — see `noTradeBandBps`.
    function bandBpsFor(
        address aux,
        address range,
        uint32 twapWindow,
        uint256 gasRebalance,
        uint256 collUsdWad,
        uint256 headroomBps
    ) public view returns (uint256) {
        if (range == address(0)) return 0;
        uint256 kWad;
        try ICore(range).kLvrWad() returns (uint256 k) { kWad = k; } catch { return 0; }
        if (kWad == 0) return 0;
        // basefee × gas = wei; × ETH/USD ÷ 1e18 = USD 1e18.
        uint256 ethUsd = IAux(aux).getTWAPforAsset(IAux(aux).WETH(), twapWindow);
        uint256 gasUsdWad = (block.basefee * gasRebalance * ethUsd) / 1e18;
        return noTradeBandBps(gasUsdWad, collUsdWad, kWad, headroomBps);
    }

    /// @dev `public`, NOT `internal`, and that is an EIP-170 decision rather than a style one.
    ///      `internal` INLINES the body into every inheritor, and `LevBase`'s inheritors are
    ///      `LevManager` and `BtcLevManager` — `LevManager` being the binding contract in this tree
    ///      (986 bytes spare at the last measurement). A `public` library body is delegatecall-linked
    ///      and lands in `LevMath` (4,372 spare), which is the convention this file already states
    ///      for exactly this reason. ⚠️ Re-measure with `tools/check-contract-sizes.py`; that margin
    ///      is a reading with a timestamp, not a fact.
    /// @notice The no-trade band around the IL target, DERIVED — half-width in LTV bps.
    /// @dev    §DERIVED-BAND — the band is DERIVED, and ⛔ MUST NOT BE FROZEN BACK INTO A CONSTANT.
    ///         A hand-set bps says what it is supposed to be ("before a rebalance is worth its gas")
    ///         and then makes it a guess, which is not something a lender can rely on — and a flat
    ///         300 bps does not merely mis-size the band, it disables the product. `ilTargetBps` is
    ///         `1 − √(entry/now)`, so clearing 300 bps needs `√(entry/now) < 0.97`, i.e. a **6.3% move
    ///         off entry** before the overlay borrows at all: the hedge would arm only after the move
    ///         it exists to protect against, and `venue.borrow` would never be reached on any
    ///         realistic path.
    ///
    ///         **The derivation.** The mis-hedge is not noise to be tolerated, it is a measurable
    ///         leak. Being off target by a fraction `h` of collateral leaves that fraction of the
    ///         LP's in-range depth unhedged, and unhedged in-range depth loses to arbitrage at
    ///         exactly the LVR rate — `K·σ²` per year, the same `K·σ²` this protocol already
    ///         computes for `derivedThetaWad` ("are fees beating LVR?"). So over a year the band
    ///         costs `C·K·σ²·E|h|` in leak and `g` in gas each time the target escapes it.
    ///
    ///         The target is `1 − √(entry/p)`, so `∂target/∂ln p = ½`: it diffuses at `σ/2`, and a
    ///         band of half-width `h` is escaped every `4h²/σ²` years. With `E|h| ≈ h/2`,
    ///
    ///             cost(h) = g·σ²/(4h²)  +  C·K·σ²·h/2
    ///             dcost/dh = 0    ⇒    h³ = g / (C·K)
    ///
    ///         **`σ` cancels.** Higher volatility crosses the band sooner *and* makes the error
    ///         costlier, and for this cost structure the two exactly offset — so the band needs no
    ///         volatility estimate, and cannot be moved by anyone who can move a volatility
    ///         estimate. What is left is a cube root of three quantities that are all read, never
    ///         chosen: `g` from `block.basefee` and the ETH TWAP, `C` from the position, and `K`
    ///         from `QuidLib.kLvrWad` — pure range geometry, `1/(4(2 − √(P/Pb) − √(Pa/P)))`.
    ///         The cube root is not a coincidence either; it is the classic form of a no-trade
    ///         region under a fixed transaction cost (Constantinides; Janeček–Shreve).
    ///
    ///         It behaves the way a hand-set band cannot: a $100k position at 3 gwei bands at ~62
    ///         bps, a $1k position at ~288 bps — small positions rightly tolerate a wider error
    ///         because gas dominates their economics, and both tighten as gas falls.
    ///
    ///         ⚠️ Returns 0 — rebalance ALWAYS — when any input is unmeasured. That is the fail-open
    ///         direction on purpose, and it is the opposite of θ's: θ failing open means "do not
    ///         throttle depth", and here the failure that costs money is *not hedging*, which is the
    ///         defect this function exists to remove. A zero band cannot mis-size a borrow; it can
    ///         only spend gas, and `LevMath.debtDelta` still sizes the borrow off the target.
    /// @param gasUsdWad  cost of one rebalance, USD 1e18 — live basefee × measured gas × ETH TWAP.
    /// @param collUsdWad position size, USD 1e18.
    /// @param kLvrWad    the range's LVR coefficient (WAD), `QuidLib.kLvrWad`.
    /// @notice The band for a live position — resolve `K` and the gas price, then derive.
    /// @param headroomBps distance from the LP's LTV cap to the venue's liquidation threshold,
    ///        `liqThresholdBps() − TARGET_LTV_CAP_BPS`. §POOL-VENUE — **THIS PARAMETER EXISTS BECAUSE
    ///        LIQUIDATION IS NO LONGER PER-LP.** `LevVenueBase:117` records the change: there is ONE
    ///        position under the adapter and *"a liquidation hits every LP pro-rata"*, so
    ///        `cascadeDelever` and this hysteresis are, in its words, *"the only things keeping the
    ///        aggregate off the liquidation threshold"*. The economic band above was derived against
    ///        a position's OWN tracking cost, which was the right model when a liquidation was that
    ///        position's own problem and is not now.
    ///
    ///        🔑 **WHAT DOES NOT CHANGE, AND IT IS THE HALF THAT MATTERS: THE BAND NEVER GATED THE
    ///        CRASH PATH.** `ilTargetBps` returns 0 at or below entry, so a falling price collapses
    ///        the target to zero, `debtDelta` sees `cur ≫ 0`, and a FULL de-lever fires at any band
    ///        width. Downside safety is gated by the keeper acting, never by this number — so a wide
    ///        band was never the liquidation exposure it looked like.
    ///
    ///        ⇒ What the pool DOES add is an upside bound. `∛(g/(C·K))` grows as `C` shrinks — ~493
    ///        bps at the minimum open — and a cluster of small positions parked at the top of a wide
    ///        band lifts the AGGREGATE toward a threshold that now takes everyone with it.
    ///
    ///        **The two constraints combine in SERIES, which is a derivation and not a clamp:**
    ///            1/h = 1/h_econ + 1/H   ⇒   h = h_econ·H / (h_econ + H)
    ///        `h → h_econ` when headroom is ample (the normal case, behaviour unchanged), and
    ///        `h < H` **by construction** — there is no branch to mis-order and no ceiling to breach,
    ///        which is the whole difference between this and `min(h, H)`.
    ///        ⚠️ `headroomBps == 0` ⇒ band 0 ⇒ rebalance ALWAYS. A position whose cap already sits at
    ///        the liquidation threshold has no room to drift, and that is the fail-safe direction.
    function noTradeBandBps(uint256 gasUsdWad, uint256 collUsdWad, uint256 kLvrWad, uint256 headroomBps)
        public pure returns (uint256)
    {
        if (gasUsdWad == 0 || collUsdWad == 0 || kLvrWad == 0 || headroomBps == 0) return 0;
        // h³ = g/(C·K), every term WAD. `fullMulDiv` first so the product cannot overflow before
        // the divide, and `cbrtWad` (solady, audited) carries the WAD through the root.
        uint256 denom = FixedPointMathLib.fullMulDiv(collUsdWad, kLvrWad, WAD);
        if (denom == 0) return 0;
        uint256 hCubedWad = FixedPointMathLib.fullMulDiv(gasUsdWad, WAD, denom);
        uint256 hWad = FixedPointMathLib.cbrtWad(hCubedWad);
        // Series combination — see the `headroomBps` note. One `mulDiv`, no branch, and `< H` by
        // construction rather than by a ceiling someone has to remember to apply.
        // ⚠️ COMBINED IN WAD, CONVERTED TO BPS ONCE. Doing it the other way round truncates twice —
        // measured: a 62.1bps band became 62 at the first conversion and 61 at the second, and since
        // the quantity is a CUBE ROOT that 1.6% error is ~4.9% in `g/(C·K)`. Precision loss compounds
        // in the direction that makes the band tighter, i.e. more rebalances, so it degraded safely
        // and would not have announced itself.
        uint256 headWad = (headroomBps * WAD) / 10_000;
        hWad = (hWad * headWad) / (hWad + headWad);
        return (hWad * 10_000) / WAD;
    }

    /// @notice #67 deliverability (LEVERED-DELIVERABILITY-SPEC.md §1) — the USD a levered position can produce via
    ///         a bounded, VALUE-NEUTRAL de-lever, = the real USD backing the range's pairing may count. The MIN of:
    ///         (a) `netEquityUsd` — the proportional de-lever (sell a fraction of collateral pro-rata to debt):
    ///         LTV-preserving, always safe; and (b) the dollar-heavy pull bound `C·(1 − curLtv/(LLTV − margin))` —
    ///         the USD extractable by withdrawing collateral until LTV reaches a FULL keeper-margin below the venue
    ///         liquidation line (solve `D/(C−x) = LLTV−margin ⇒ x = C·(1 − curLtv/(LLTV−margin))`). Same
    ///         `PROTECT_MARGIN_BPS` the protect/de-lever already ride. CONSERVATIVE by construction (min + the
    ///         at/over-ceiling⇒0 clamp) so it can never over-count backing (`D ≥ S + L` stays true); real, bounded
    ///         by the liquidation edge, never phantom. Symmetric ETH+BTC — the managers pass their own C/D/LTV/LLTV.
    function deliverableDollars(uint256 netEquityUsd, uint256 collValueUsd, uint256 curLtvBps, uint256 lltvBps)
        internal pure returns (uint256)
    {
        if (lltvBps <= PROTECT_MARGIN_BPS) return 0;             // venue with no safe headroom below its liq line
        uint256 safeLtv = lltvBps - PROTECT_MARGIN_BPS;         // de-lever ceiling: a full keeper-margin under LLTV
        if (curLtvBps >= safeLtv) return 0;                     // already at/over the ceiling ⇒ no safe capacity
        uint256 buffer = collValueUsd * (safeLtv - curLtvBps) / safeLtv;  // C·(1 − curLtv/safeLtv)
        return netEquityUsd < buffer ? netEquityUsd : buffer;   // min — bounded by BOTH equity and the margin edge
    }

    // Venue-gate reverts. Name-derived selectors, so `revert VenueNotAllowed()` here is INDISTINGUISHABLE
    // from LevManager's own `VenueNotAllowed()` (same signature) -- callers/tests keep the typed error.
    error BadCollateral();    // a pinned LONG venue whose collateral the manager cannot value/custody
    error VenueBlocked();     // open onto an incident-flagged venue

    /// @notice IL-cancelling target LTV (bps) = `1 − √(ilBasisPx/pxNow)`, clamped to `capBps`.
    ///         ZERO when flat/down (no IL accrued ⇒ no leverage). `ilBasisPx`/`pxNow` are
    ///         USD-per-base (1e18). `LevBase._ilTargetLive` is the thin wrapper that supplies
    ///         `TARGET_LTV_CAP_BPS` as `capBps`; there is no second implementation of this target.
    function ilTargetBps(uint128 ilBasisPx, uint256 pxNow, uint64 capBps)
        public pure returns (uint256)
    {
        // at/below entry → no UP-SIDE IL → no up-side overlay. (There IS down-side IL below entry — the range
        // over-holds the falling asset — but a long LP does NOT hedge it: the up-side-only LP just HOLDS long
        // through the fall. Holding beats an LVR-leaking downside rebalance: down-side IL is impermanent and heals,
        // so a below-entry short would realize the loss and forfeit the recovery. Up-side-only is the design.)
        if (ilBasisPx == 0 || pxNow <= ilBasisPx) return 0;
        uint256 ratioWad = (uint256(ilBasisPx) * WAD) / pxNow;    // entry/now < 1 (WAD)
        uint256 sqrtWad  = FixedPointMathLib.sqrt(ratioWad * WAD);    // √(entry/now), WAD (solady, audited)
        uint256 ilBps    = ((WAD - sqrtWad) * 10_000) / WAD;          // 1 − √(entry/now), bps
        return ilBps > capBps ? capBps : ilBps;
    }

    /// @notice The reseat DECISION, reached from `LevBase._reanchorIfReseated` via
    ///         `RangeLib.reanchorIfReseated`.
    /// @dev  Re-anchor iff the position's `syncKeyPx` now sits OUTSIDE the range's current `[lower, upper]`.
    ///       The bounds fire only when the frame moved RELATIVE TO THIS POSITION: a reseat that leaves
    ///       this anchor inside the new range needs no re-anchor, and there is no separate counter to
    ///       keep in sync with the ticks.
    /// ⚠️   IT IS A POINT-IN-TIME TEST. It answers "is my anchor stale NOW", NOT "were these two reads taken in
    ///       the SAME frame". §E117 measured a 1h TWAP tick of 200766 sitting neatly inside a post-reseat range
    ///       [200730, 200770) whose window spanned FOUR frame changes — no bounds check can see that. Safe here
    ///       because BOTH live consumers ask the point-in-time question; the windowed consumer (§E93) is
    ///       refuted and blocked. **If anyone builds a WINDOWED reading over the tick series, the epoch must
    ///       come back, and §E117 is the evidence for why.**
    /// @dev  Compared in SQRT space, never by converting `syncKeyPx` to a tick: tick conversion truncates, so
    ///       a position anchored exactly at a boundary would flip on rounding.
    /// §MUTABILITY 2026-08-18 — `view`: body reads only, verified it touches none of the
    /// cache-sensitive family (`get_deposits`/`get_metrics`/`refreshHoldingsSelf`/`redeemableAmount`).
    function reanchorCompute(address range, uint syncKeyPx)
        public view returns (bool go, uint newPrice) {   // §DE-TICK — was `newSqrtP`; it is assigned from
                                                 // `rangePrice()`, so it always held a PRICE.
        if (range == address(0) || syncKeyPx == 0) return (false, 0);
        try ICore(range).rangePrice() returns (uint v) { newPrice = v; } catch { return (false, 0); }
        if (newPrice == 0) return (false, 0);
        // ONE accessor pair. The range is per-asset and answers for its own range, so `rangeBounds()`
        // is declared once with no per-asset variant — there is no name to select between.
        uint lo; uint hi;
        // §ONE-ANCHOR — ONE call, ONE try/catch. Two reads meant two chances to half-fail and a
        // caller left holding a lower bound with no upper; the pair now arrives together or not at
        // all, which is the property the `catch` was there to protect in the first place.
        try ICore(range).rangeBounds() returns (uint l, uint u) { lo = l; hi = u; }
        catch { return (false, 0); }
        if (lo >= hi) return (false, 0);                       // range unset/degenerate → nothing to compare against
        // §DE-TICK — a DIRECT price comparison. The bounds are prices; converting them through the
        // tick grid was the only reason this needed TickMath.
        if (syncKeyPx >= lo && syncKeyPx <= hi) return (false, 0);   // still inside its own frame
        go = true;
    }

    // ⛔ §C22 — **DO NOT SOURCE THE IL TARGET FROM `ICore(range).soldFractionWad(syncKeyPx)`, AND DO
    //   NOT ADD A BRANCH THAT PREFERS IT OVER THE ESTIMATE. IT IS A CONSTANT**, and the proof is two
    //   lines of algebra plus a measurement that agrees to nine significant figures:
    //     `holdingRatioWad` CLAMPS `p0` into the live range, and `RANGE_ANCHOR = spotPrice` is set
    //     unconditionally on every repack, so the range recentres and the triple is always
    //     (lo, P, hi) = (P(1-d), P, P(1+d)). P CANCELS:
    //         holdingRatio = sqrt(1-d) * (sqrt(1+d) - 1) / (sqrt(1+d) - sqrt(1-d))
    //     With RANGE_DELTA = 20 bps that is 0.499250000, i.e. soldFraction = **0.500750000** — a
    //     function of RANGE WIDTH ALONE, with no price in it.
    //   MEASURED over a rally that doubled the price (2716.84 -> 5430.99, ten steps): the range's
    //   real inventory `POOLED` fell 7.566 -> 2.331 ETH while `soldFractionWad` returned
    //   0.500750000312500535 at EVERY step, moving only in the 18th decimal.
    //   => It is not a measure of IL. It reports a 50.075% hedge at open, at +100%, and the same on
    //      the way down. ⚠️ SUCH A BRANCH LOOKS HARMLESS ONLY WHILE THE REANCHOR KEEPS
    //      `syncKeyPx == spot` and `sf` comes back 0 — the estimate then runs, correctly, BY ACCIDENT.
    //      Restoring `syncKeyPx` (the natural next step after §C19) would switch every position in
    //      the book to a constant 50% hedge, capped at `capBps`.
    //   `ilTargetBps` above is the ONLY target, and it is `public` so the body stays in this
    //   delegatecalled library rather than inlining into the size-critical managers.

    /// @notice (§3) The stable (USD 1e18) to REPAY to bring a position to target LTV on the FIXED E0 (over-hedge
    ///         fix): `curDebt − targetDebt`, ZERO inside the de-lever range. Pure; folded out of `deleverRepayUsd`.
    /// §DEDUP-NAMES (2026-08-18) — the first parameter was `entryEquityUsd`, which SHADOWED the library's own
    /// `entryEquityUsd(entryEquity, price)` helper thirty lines below. Inside this body `entryEquityUsd` was the number, not
    /// the function, and nothing said so — the same read-ambiguity that made `inputCount` worth
    /// renaming in `BitcoinTx`. `equityUsd` is what the value actually is: the position's equity,
    /// already converted, which is precisely what `entryEquityUsd()` RETURNS.
    function deleverRepay(uint256 equityUsd, uint256 curDebt, uint256 tBps, uint256 rangeBps) public pure returns (uint256) {
        uint256 targetDebt = (equityUsd * tBps) / 10_000;
        if (curDebt <= targetDebt + (equityUsd * rangeBps) / 10_000) return 0;
        return curDebt - targetDebt;
    }

    /// @notice (WBTC-mode) Lever-UP for a WBTC-collateral BTC position: borrow stable → SOR to WBTC → supply — the
    ///         EXACT 4-step custody, all in the delegatecall context (== the manager). ON-CHAIN oracle floor (WBTC
    ///         value − `slipBps`) so `BtcLevManager.rebalanceWbtc` is anti-sandwich even when permissionless. `usd`
    ///         is the debt-delta (USD18). Returns (borrowed, wbtcBought) for the manager to emit. Byte lives HERE so
    ///         the manager stays under EIP-170 (mirrors how the ETH lever mechanics live in this lib).
    /// @dev (WBTC-mode) config bundle — keeps the leg fns under the no-via_ir 16-slot stack limit (6 params, not 9).
    struct WbtcCfg { address aux; address wbtc; uint32 twapWindow; uint16 slipBps; uint256 dex; uint256 dex2; bytes route; }

    /// @notice §V-R1-MIN — borrow the venue stable, buy WBTC through the routed swap, supply it.
    /// @dev    `minOut` is FLOORED against the oracle HERE, never taken from the caller: `rebalanceWbtc`
    ///         is permissionless, so the caller picks WHEN and the contract picks the PRICE BOUND.
    function leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint256 usd, uint256 minOut, WbtcCfg memory cfg)
        public returns (uint256 borrowed, uint256 wbtcBought) {
        borrowed = venue.borrow(lp, _fromUsd(cfg.aux, stable, usd));
        if (borrowed == 0) return (0, 0);
        {
            uint256 floorWbtc = (usd * 1e18 / IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow))
                                * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorWbtc) minOut = floorWbtc;   // the oracle floor always wins
        }
        wbtcBought = _stableToWbtc(stable, borrowed, minOut, cfg.wbtc, cfg.route);
        IERC20Min(cfg.wbtc).transfer(address(venue), wbtcBought);
        venue.supply(lp, wbtcBought);
    }

    // ⛔ §E357 — DO NOT ADD A DIRECT, NON-FLASH WBTC DE-LEVER BACK. It would have to withdraw
    // collateral and THEN sell to repay — the withdraw-before-repay ordering the flash path below
    // exists to dissolve, and under §POOL-VENUE it raises the LTV of a position every LP shares.
    // `init` refuses a zero `flashProvider`, so there is no state that needs the direct path.


    /// @notice (WBTC-mode) FLASH-repay-first de-lever settle (mirror of LevManager._deleverSettle) — runs inside the
    ///         manager's `onMorphoFlashLoan` callback with `assets` flashed stable in hand: repay the LP's debt FIRST
    ///         (LTV drops ⇒ the withdraw is ALWAYS health-safe — kills the direct path's near-liq limitation), withdraw
    ///         the freed WBTC (grossed up by the slippage buffer so the sale covers `assets`), reverse-SOR to stable
    ///         (ON-CHAIN oracle floor), return exactly `assets` to the flash provider (zero-fee pull-back), and hand any
    ///         realized surplus to the LP. Body HERE (delegatecall) so the manager's callback stays thin under EIP-170.
    /// @notice §V-R1-MIN RESTORED FROM HISTORY, NOT RECONSTRUCTED. Flash-repay-FIRST de-lever: the
    ///         debt is repaid before any collateral is withdrawn, so the position's LTV only ever
    ///         DROPS mid-operation — the withdraw-before-repay hazard is dissolved by construction.
    /// @dev    ⚠️ I FIRST WROTE THIS FROM THE PATTERN AND IT WAS WRONG IN TWO WAYS THAT ONLY A TRACE
    ///         REVEALED. Both are in the `pulled` sizing:
    ///           ① `repaid` is in STABLE units (6-dec USDC), not USD18 — it must go through
    ///              `_toUsd18` before dividing by `px`. Omitting it is a 1e12 mis-scale.
    ///           ② the withdraw must OVER-size by `10_000/(10_000 - slipBps)`. Withdrawing exactly
    ///              the notional leaves the swap output SHORT of `assets` after slippage, and the
    ///              flash provider then pulls more than the manager holds.
    ///         The failure surfaced as `ERC20: transfer amount exceeds balance` inside Morpho Blue's
    ///         repayment pull — three frames from the cause, naming neither the sizing nor the swap.
    ///         ⇒ RESTORE FROM `git show`, DO NOT REWRITE FROM MEMORY.
    function flashDeleverWbtcSettle(uint256 assets, address lp, address venueAddr, address stable,
                                    uint256 minOut, address flashProvider, WbtcCfg memory cfg) public {
        ILevVenue venue = ILevVenue(venueAddr);
        IERC20OZ(stable).safeTransfer(address(venue), assets);
        uint256 pulled;
        {   // repay-FIRST → size + withdraw the freed WBTC → oracle floor (own frame for the stack)
            uint256 repaid = venue.repay(lp, assets);                            // == assets (capped upstream)
            uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow);
            pulled = venue.withdraw(lp, (_toUsd18(cfg.aux, stable, repaid) * 1e18 / px)
                                        * 10_000 / (10_000 - cfg.slipBps));
            uint256 floorStable = _fromUsd(cfg.aux, stable, pulled * px / 1e18)
                                  * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorStable) minOut = floorStable;
        }
        uint256 stableOut = _volToStable(cfg.wbtc, stable, pulled, minOut, cfg.route);
        IERC20OZ(stable).forceApprove(flashProvider, assets);   // provider pulls `assets`; a short approve reverts the whole op
        if (stableOut > assets) IERC20OZ(stable).safeTransfer(lp, stableOut - assets);   // realized surplus → LP
    }

    /// @notice Net-equity in BASE-asset units (1e18) = `collBase − debtUsd/price`, floored at 0.
    ///         `collBase` is collateral ALREADY in base units (ETH or BTC); `debtUsd` is 1e18 USD;
    ///         `price` is USD per 1 base (1e18). `debt==0 ⇒ collBase`; `px==0 ⇒ 0` (dead oracle,
    ///         the conservative side — no phantom credit). `LevBase.netEquity` is the caller; it
    ///         pre-computes `collBase` through `_collNative` (weETH→ETH on the ETH side, raw sats on BTC).
    function netEquityBase(uint256 collBase, uint256 debtUsd, uint256 price)
        internal pure returns (uint256)
    {
        if (debtUsd == 0) return collBase;
        if (price == 0) return 0;
        uint256 debtBase = (debtUsd * WAD) / price;
        return collBase > debtBase ? collBase - debtBase : 0;
    }

    /// @notice USD (1e18) value of a RANGE-ONLY E0 base amount: `entryEquity · price / 1e18`. `entryEquity` is the LP's
    ///         unlevered range deposit in BASE units (ETH 1e18, or BTC 8-dec sats), `price` is USD-per-base
    ///         (1e18; WBTC-lifted ×1e10 on the BTC side, so the SAME `/1e18` yields 18-dec USD for both). This
    ///         is the SINGLE scale layer both managers value E0 through — the exact site the BTC 1e10 mis-scale
    ///         (`/1e8`) lived in; centralized here so the decimals can never drift between the two managers again.
    function entryEquityUsd(uint256 entryEquity, uint256 price) internal pure returns (uint256) {
        return (entryEquity * price) / WAD;
    }

    /// @notice Debt-backed BUFFER-leg USD (6-dec) for a range-reconcile buffer of `bufBase` volatile units at range
    ///         price `price` (USD/base, 1e18), CAPPED at the LP's OWN debt (`debtUsd`, 1e18). The debt-funded
    ///         buffer is fee-earning DEPTH, never equity, and is bounded by the LP's own debt BY CONSTRUCTION — the
    ///         exact `min((bufBase·px/1e18)/1e12, debtUsd/1e12)` the range-reconcile buffer leg needs.
    ///         `RangeLib.levAddBuf` is the ONE caller and serves BOTH sides, so — like `entryEquityUsd` —
    ///         the buffer cap + its 6-dec scaling cannot drift between the two paths. `bufBase` is ETH-1e18 or
    ///         BTC-8dec-sats; `price` is WBTC-lifted ×1e10 on the BTC side, so the SAME `/1e18` yields 18-dec USD
    ///         for both before the shared `/1e12` to 6-dec (identical to the two former inline computations).
    function capBufferUsd(uint256 bufBase, uint256 price, uint256 debtUsd) internal pure returns (uint256 bufUsd) {
        bufUsd = ((bufBase * price) / WAD) / 1e12;
        uint256 dCap = debtUsd / 1e12;
        if (bufUsd > dCap) bufUsd = dCap;
    }

    // ═══════════════════════════ VENUE SAFETY GATES (public — delegatecall-linked) ═══════════════════════════
    // Both managers are EIP-170-critical, so the venue-vetting + health checks live HERE (bytecode outside the
    // manager). Shared by LevManager (ETH, weETH/WETH collateral) and BtcLevManager (BTC, vBTC collateral).

    /// @notice Vet + classify a GOV-pinned lev venue. The COLLATERAL CHECK RUNS FIRST AND
    ///         UNCONDITIONALLY: `v`'s collateral MUST be one of the manager-valuable tokens (`c0`/`c1`,
    ///         e.g. {WETH,weETH} or {vBTC}) -- anything else would silently misvalue into PHANTOM
    ///         backing (the exact rug the frozen allowlist guards), so revert even for GOV
    ///         (defense-in-depth against a config mistake). The return then CLASSIFIES: true iff
    ///         `stable() == base`, i.e. the venue borrows the volatile — the BASE-DEBT/short shape.
    /// ⛔ DO NOT PUT THE CLASSIFICATION FIRST AND EXEMPT ANYTHING FROM THE COLLATERAL CHECK. Behind an
    ///    `if (stable() == base) return true;` a base-debt venue is allowlisted with its collateral
    ///    NEVER VALIDATED — and that is not hypothetical: the weETH-collateral/WETH-LOAN venue has
    ///    `stable() == WETH == base`, so it takes exactly that early return. Its collateral is weETH
    ///    and always was; the point is that nothing checked.
    /// ⚠️ THE RETURN IS LOAD-BEARING, DO NOT DROP IT. BOTH callers consume it and both REJECT a
    ///    base-debt venue: `LevManager:152` reverts `VenueNotAllowed()`, `BtcLevManager:72` reverts
    ///    `BadAuth()`. Deleting it opens both sides, not just one.
    function vetVenue(address v, address base, address c0, address c1) public view returns (bool isShort) {
        address coll = ILevVenue(v).COLLATERAL();
        if (coll != c0 && coll != c1) revert BadCollateral();
        return ILevVenue(v).stable() == base;
    }

    /// @notice Gate a NEW levered open: the venue must be on the frozen allowlist AND not incident-flagged
    ///         (GOV `setVaultHealth`). Fresh collateral must never land on a de-allowlisted or broken market. Only
    ///         OPEN is gated -- close/rebalance stay open so the keeper can always unwind OUT of a blocked venue.
    function requireOpenable(bool allowed, address aux, address venue) public view {
        if (!allowed) revert VenueNotAllowed();
        if (IAux(aux).vaultBlocked(venue)) revert VenueBlocked();
    }


    error NoStableRoute();
    error NoOptIn();
    error Slippage();
    /// §SESS-22 — a route CONSUMED an input leg and delivered NOTHING to `outToken`.
    error RouteTookAndGaveNothing();
    error BadRoute();   // §SESS-65 — a supplied route whose selector or length we do not recognise
    error NoVolatileRoute();
    error NotNearLiq();
    error NoDebt();
    /// Protect only a position within PROTECT_MARGIN_BPS (LTV) of its venue liquidation threshold — anti-grief
    /// (a healthy, low-LTV LP can never be force-redeemed); mirrors the cascade de-lever trigger range.
    uint256 internal constant PROTECT_MARGIN_BPS = 1500;

    // ═══════════════════════ ETH SELL/BUY MACHINERY + SELF-FUNDING KEEPER GAS ═══════════════════════
    // Moved out of LevManager (delegatecall-linked, bytecode OUTSIDE the manager) so it fits EIP-170. Runs in the
    // MANAGER's context (address(this)==manager); the manager's runtime addresses arrive via `SellCtx`, the fixed
    // mainnet addresses are constants here. The keeper-gas peel is folded into the down-leg sells: the crank's
    // gas is reimbursed as native ETH from the de-lever's over-collateralization HEADROOM (never the flash-repay
    // amount), shortfall from the passed WETH gas-reserve (threaded in/out), so the operator funds ZERO gas.
    address internal constant ETHERFI_ADAPTER_M  = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;   // WETH→weETH mint (up-leg)
    /// @dev The dollar peg, 1e18. Passed as `pxUsd18` wherever the token IS a stable — which is every
    ///      site today. Named rather than inlined so a switch to a real price is visible in a diff.
    /// @dev PAR. Referenced ONLY by `loanPxUsd18` below — never passed as a price argument. Passing it at a
    ///      call site is what made every WETH-denominated figure wrong by ~4,000x while looking fine.
    uint256 private constant USD_PX = 1e18;

    /// @notice USD price (1e18) of a venue's LOAN token — the single decision point for every `_toUsd18`
    ///         / `_fromUsd` on the lever path.
    /// @dev  DISCRIMINATED BY THE FEED REGISTRY, NOT BY NAMING WETH. `assetPriceFeed` is empty for a basket
    ///       stable (par by construction) and set for a real asset. Naming WETH would re-open this the moment
    ///       a second non-dollar loan token is allowlisted — which is exactly how it opened.
    /// @dev  A pinned-but-DEAD feed reverts rather than returning 0: debt valued at zero reads as SOLVENT,
    ///       and a zero-based slippage floor disables anti-MEV protection while still looking enabled.
    function loanPxUsd18(address aux, address loan) internal view returns (uint256 px) {
        if (IAux(aux).assetPriceFeed(loan) == address(0)) return USD_PX;   // dollar stable ⇒ par
        px = IAux(aux).getTWAPforAsset(loan, TWAP_WIN_M);
        if (px == 0) revert NoPrice();
    }
    /// §SESS-42 — one declaration (`TWAP_WINDOW_SECS`). Kept as an alias so the ~20 call sites in
    /// this library do not churn; it is now a REFERENCE, not a second source of truth.
    uint32  internal constant TWAP_WIN_M         = TWAP_WINDOW_SECS;
    /// @dev 🔴 **THE CEILING, AND EVERY BASIS POINT OF IT IS ONE A COMPROMISED KEEPER MAY TAKE.**
    ///      `minOut` is `oracle x (10000 - slip)/10000`, so a hostile route can return EXACTLY the
    ///      floor and keep the rest — silently, because the swap succeeds (§THE-SLIPPAGE-WINDOW-IS-THE-LEAK).
    ///      Kept at 100 so that **nothing which executes today can start reverting**; `_slipBps`
    ///      below tightens it for the sizes where 100 is provably far too loose.
    uint256 internal constant SELL_SLIP_BPS      = 100;                                           // 1% anti-MEV CEILING

    /// @dev ⭐ **A FLAT ALLOWANCE IS SIMULTANEOUSLY TOO LOOSE AND TOO TIGHT, WHICH IS WHY THIS IS A
    ///      FUNCTION.** Measured 2026-08-30 on the leg this actually bounds (stable→WETH, NOT the
    ///      stable→stable hub hop): **USDT→WETH costs 11 bps at $1M and 56 bps at $5M; USDC→WETH
    ///      44 bps and 224 bps.** So at $100k a flat 100 bps is ~20x the honest need — pure leak —
    ///      while at $5M it is already too tight for the worse tier. Impact scales with notional;
    ///      a constant cannot.
    ///      ⚠️ **THE CEILING IS PRESERVED DELIBERATELY: this can only ever RAISE the floor, never
    ///      lower it, so it cannot make a swap that succeeds today begin to fail.** That is what
    ///      makes it safe to land without knowing live position sizes.
    ///      📌 Base and slope are set ABOVE the measured cost of the worse tier at each size (25 bps
    ///      covers USDC→WETH's 44 bps only from ~$1M; below that the honest cost is a few bps), so
    ///      an honest keeper routing through a sane pool clears it with margin.
    /// @dev Per-leg gas ceiling for an aggregator route. Sized from measurement, not taste: a REAL
    ///      1inch route converting 250k USDC to WETH executed inside ~511k gas total for the whole
    ///      test, so 3M leaves a wide margin for a genuinely complex split while still bounding a
    ///      leg that tries to burn everything. ⚠️ Too LOW silently fails legitimate routes (they
    ///      surface as a skipped leg and a short fill, not an error) — raise it on evidence, and
    ///      never remove it.
    uint256 internal constant ROUTE_GAS_CAP      = 3_000_000;

    uint256 internal constant SLIP_BASE_BPS      = 25;   // small-trade floor
    uint256 internal constant SLIP_PER_MM_BPS    = 25;   // added per $1M of notional

    /// @notice §SESS-44 — **THE ONE FLOOR FORMULA.** Three sites computed the identical expression
    ///         three different ways; this is that expression, once.
    /// ⛔ **`slipBps` IS A PARAMETER ON PURPOSE — THE DEDUP IS OF THE FORMULA, NOT OF THE BUDGET.**
    ///    The three sites carry three DIFFERENT budgets (`_slipBps` on the open leg, `_slipBps` on the
    ///    close leg, a flat `CONSOL_SLIP_BPS` on consolidation). Collapsing those too would change
    ///    behaviour on every path at once — §SIZE-AWARE-SLIP's own warning, and exactly the false
    ///    negative to avoid. **Passing the budget in makes the three budgets VISIBLE in one place,
    ///    which is the precondition for deciding them, and changes nothing today.**
    /// 🔑 **AND THE PRICE LOOKUP IS FEED-INDEPENDENT, WHICH IS WHY THE THREE HAD DIVERGED.**
    ///    `loanPxUsd18` returns par whenever `assetPriceFeed[t] == 0`, so a floor written with
    ///    `_fromUsd` is correct only where the feed is pinned — production pins WETH/WBTC
    ///    (`DeployL1_s:356-357`) but `AllesFixture` does not, which is what drove the open leg and the
    ///    close leg to write the same formula two different ways. ⛔ DO NOT REINTRODUCE EITHER
    ///    SPELLING: **asking the oracle and falling back to par is correct in BOTH environments**, so
    ///    `_stableToWethSor` and `_wethStableFloor` both price through `swapFloor`/`_pxUsd18` here.
    function _pxUsd18(address aux, address t) internal view returns (uint256) {
        try IAux(aux).getTWAPforAsset(t, TWAP_WIN_M) returns (uint256 p) {
            if (p != 0) return p;
        } catch {}
        return USD_PX;                       // not oracle-priced ⇒ a dollar stable ⇒ par
    }

    /// @notice `amtIn` of `give`, valued at the oracle in `want`'s units, haircut by `slipBps`.
    function swapFloor(address aux, address give, uint256 amtIn, address want, uint256 slipBps)
        internal view returns (uint256) {
        uint256 usd18 = (amtIn * _pxUsd18(aux, give)) / (10 ** IERC20Min(give).decimals());
        uint256 raw   = (usd18 * (10 ** IERC20Min(want).decimals())) / _pxUsd18(aux, want);
        return (raw * (10_000 - slipBps)) / 10_000;
    }

    function _slipBps(uint256 usd18) internal pure returns (uint256 bps) {
        bps = SLIP_BASE_BPS + (usd18 / 1e24) * SLIP_PER_MM_BPS;   // 1e24 = $1M in USD18
        if (bps > SELL_SLIP_BPS) bps = SELL_SLIP_BPS;             // never looser than today
    }
    uint256 internal constant DELEVER_GAS        = 400_000;                                       // conservative de-lever crank gas
    uint256 internal constant KEEPER_MAX_GASPRICE = 200 gwei;                                     // anti-grief gasprice ceiling

    /// The manager's runtime addresses + the crank's keeper + the live WETH gas-reserve, threaded into the moved fns.
    /// §C2.1 — `route` is the 1inch AggregationRouterV6 calldata the KEEPER built off-chain. It rides
    /// in `SellCtx` because that struct is already threaded `_sellAndPay → sellColl → sellWeeth →
    /// _wethToStableDex`: one memory pointer, so it costs no extra stack in a no-via_ir build.
    /// EMPTY means "no route supplied": `routedSwap` then encodes the keeper's POOL WORDS through
    /// `_aggSwap` instead, against the same floor — see `_wethToStableDex`.
    struct SellCtx { address weth; address weeth; address aux; address keeper; uint256 reserveIn; uint256 dex; uint256 dex2; bytes route; }

    /// @notice Sell `pulled` collateral → `stable` at the anti-MEV oracle floor, peeling the keeper's gas (native ETH)
    ///         from the over-collateralization headroom. `pulled` is always weETH — all collateral is weETH.
    /// @return stableOut stable delivered (the flash pull-back + LP surplus come from this). @return reserveOut new gas-reserve.
    function sellColl(SellCtx memory c, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        public returns (uint256 stableOut, uint256 reserveOut)
    {
        return sellWeeth(c, stable, pulled, minOut, assets);
    }

    /// weETH → WETH (Curve pool) → peel keeper gas →
    /// WETH → stable. The weETH→WETH acquisition is its OWN frame (`_weethToWeth`) so the peel below fits the stack.
    function sellWeeth(SellCtx memory c, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        internal returns (uint256 stableOut, uint256 reserveOut)
    {
        reserveOut = c.reserveIn;
        uint256 wethGot = _weethToWeth(c, pulled);      // LEG 1 — bounded inside `_weethToWethDex`
        { // peel keeper gas from headroom (own frame — no via_ir)
            uint256 need = _wethForAssets(c, stable, assets);
            uint256 skimmed;
            (skimmed, reserveOut) = _reimburse(c.weth, c.keeper, wethGot > need ? wethGot - need : 0, reserveOut);
            wethGot -= skimmed;
        }
        // 🔴 **THE TWO LEGS WERE SHARING ONE SLIPPAGE BUDGET WHILE EACH WAS BOUNDED AS IF IT HAD ALL
        //    OF IT.** This read `_stableFloor(c, stable, pulled)` — the floor for the WETH→stable leg
        //    derived from `pulled`, which is LEG 1'S INPUT. But `_weethToWethDex` already enforces
        //    `getEETHByWeETH(pulled) * (1 − SELL_SLIP_BPS)` on that leg, so leg 1 may legitimately
        //    return up to `SELL_SLIP_BPS` less WETH than oracle — and leg 2 was then required to
        //    deliver the FULL oracle value of `pulled` out of that reduced amount. If leg 1 used any
        //    of its allowance, leg 2 had to be PERFECT; if it used all of it, leg 2 could not pass at
        //    any price. The bounds overlapped instead of composing.
        // ⭐ MEASURED: the sell executed at the TRUE market rate — 0.209873 WETH → 523.880428 USDC,
        //    $2,496/ETH, the real V3 price that block — and still reverted `Slippage()`. A floor that
        //    a correctly-priced trade cannot clear is not protecting anything; it is a liveness bug
        //    wearing a safety bound's name. It broke §G.7/#109 (`Quid.withdraw`'s auto-de-lever) and
        //    every keeper close.
        // ⇒ Derive leg 2's floor from `wethGot`, THE WETH ACTUALLY IN HAND, so each leg is bounded
        //    against its own input and the two allowances compose. Standing rule 17: this also makes
        //    the old peel-rescale line (`floorOut = floorOut * wethGot / wethBefore`) DELETABLE —
        //    computing the floor after the peel is what that line was approximating.
        uint256 floorOut = _wethStableFloor(c, stable, wethGot);   // LEG 2 — its own input, its own bound
        stableOut = _wethToStableDex(c, stable, wethGot, minOut > floorOut ? minOut : floorOut);
    }

    /// weETH → WETH via the Curve weETH/WETH pool (weETH is coin1, WETH coin0).
    /// There is deliberately NO ether.fi emergency-redeem fallback: its capacity measures ZERO at every
    /// sampled block, and being unguarded it would revert the WHOLE call rather than degrade. Under-delivery
    /// is surfaced by the caller's own floor (`collToWethDeliver`'s `require(wethDelivered >= minOut)`),
    /// which fails closed with a legible reason.
    function _weethToWeth(SellCtx memory c, uint256 pulled) internal returns (uint256 wethGot) {
        if (pulled > 0) wethGot = _weethToWethDex(c, pulled);
    }


    /// @notice ⭐ **THE CONVERSION PRIMITIVE — RESTORED 2026-08-31.** Deleted one commit earlier as
    ///         unreachable under *"1inch only, no API key"*; the owner can obtain a key, so `swap()`
    ///         calldata is reachable and this is the path to the venues `unoswap` cannot address
    ///         (Fluid, Balancer, Maverick, the `lite-psm`/`dai-usds` par converters, SPLIT routes).
    ///         **The deletion was correct on the information available and is reversed by new
    ///         information, not by a change of mind — recovered from `c3f98ff8` rather than rewritten.**
    /// @dev 🔴 **THE POOL-WORD PATH (`_aggSwap`) MUST SURVIVE AS A FALLBACK, AND THAT IS NOT
    ///      CONSERVATISM.** A key makes route-building depend on 1inch's API being *up and not
    ///      rate-limiting*, on a path that is PERMISSIONLESS and whose whole purpose is to fire when
    ///      positions are stressed. An outage would mean signed orders and levered positions silently
    ///      stop rebalancing. ⇒ **Calldata when a route is available, pool words when it is not** —
    ///      the owner's own `Amp.sol` ladder ("pull if you can here and if you cant then here")
    ///      applied to routing. **The ladder belongs at the CALL SITE**, which is where "did I get a
    ///      route?" is already answered; keeping it out of here leaves each primitive doing one thing.
    /// @dev ⚠️ **THE KEY IS A KEEPER SECRET, AND THAT IS AN OPERATIONAL RISK, NOT A PROTOCOL ONE.**
    ///      A compromised enclave leaks it — but the key only FETCHES routes, and every route is
    ///      bounded here by the oracle floor on a measured balance delta. It buys an attacker better
    ///      quotes, never the protocol's funds.
    /// @notice ⭐ **THE CONVERSION PRIMITIVE: M INPUTS → ONE OUTPUT, THROUGH THE PINNED AGGREGATOR.**
    ///         Every value conversion in this protocol is an instance of it — a pro-rata basket
    ///         bundle, a single borrowed stable, WETH, WBTC or weETH — and the only thing that
    ///         differs is what goes in.
    /// @dev ⭐ **ONE BODY, BECAUSE THERE IS ONE OPERATION.** `_stableToWethSor`, `_stableToWbtc`,
    ///      `_volToStable`, `_wethToStableDex`, `_hubHop` and `sellWeethOnCurve` are six spellings
    ///      of "turn what we hold into what we owe". Six spellings is six places to add a router, six
    ///      approval patterns to get wrong, and six ways for the basket's offramp to drift from the
    ///      lever's — which had ALREADY happened once (§ONE-WEETH-HOP).
    /// @dev 🔴 **`routes` IS PER-INPUT BECAUSE AGGREGATOR CALLDATA IS SINGLE-INPUT.** No aggregator
    ///      takes a multi-token input, so M inputs is M router calls. That is not a workaround: it is
    ///      what gives the split across venues that do not compete for the same liquidity, and a
    ///      pro-rata bundle supplies that spread **by construction** with nobody choosing it
    ///      (§PRO-RATA-IN-ONE-TOKEN-OUT).
    /// @dev 🔒 **THE SECURITY MODEL IS UNCHANGED FROM `_aggSwap`, AND THAT IS THE POINT — the caller
    ///      proposes a path, the contract verifies an OUTCOME:**
    ///        1. the callee is the PINNED router; a route naming anything else cannot be reached;
    ///        2. each approval is EXACT and ZEROED on both paths, so a failed leg leaves no standing
    ///           claim on the next block's balance;
    ///        3. `minOut` is enforced ONCE, on the MEASURED BALANCE DELTA OF THE WHOLE OPERATION —
    ///           never per-leg and never on a router return value, which is a number the callee
    ///           chooses. A hostile or stale route can therefore fail the bound; it cannot extract.
    ///      ⚠️ `minOut` MUST be oracle-derived by the caller. This function does NOT value its own
    ///      inputs — valuation differs per asset class and already lives correctly at each call site,
    ///      where the size-aware `_slipBps` is applied.
    /// @dev §SESS-84 — rewrite one pool word's `ZERO_FOR_ONE` from a token this frame owns.
    ///      `matchIsZero` distinguishes the two rules: hop 1 sets the bit when `token == token0`,
    ///      the last hop sets it when `token != token0`. Both need only `token0()`, which is why the
    ///      interface never had to widen. A pool that cannot be read is LEFT ALONE.
    function _deriveBit(bytes memory route, uint256 off, address token, bool matchIsZero) private view {
        uint256 w;
        assembly { w := mload(add(route, off)) }
        if (w >> 253 != PROTO_UNIV3) return;
        (bool ok, bytes memory r) = address(uint160(w)).staticcall(abi.encodeWithSelector(
            IUniV3PoolMin.token0.selector));
        if (!ok || r.length < 32) return;                 // not a pool we can read — leave it as-is
        address t0 = abi.decode(r, (address));
        w &= ~ZERO_FOR_ONE;
        if (matchIsZero ? token == t0 : token != t0) w |= ZERO_FOR_ONE;
        assembly { mstore(add(route, off), w) }
    }

    /// @notice §SESS-65 — **THE ONLY THING A CALLER MAY CHOOSE IS THE VENUE.**
    ///
    /// Rewrites a supplied `unoswap`-family call so its `token`, `amount` and `minReturn` are OURS.
    /// Everything left untouched is a pool word — the venue choice — which is precisely the decision
    /// we WANT delegated, because it is the one an off-chain quote can make better than we can.
    ///
    /// ⛔ **WHITELIST BY SELECTOR *AND* EXACT LENGTH, THEN PATCH — NEVER PATCH AND HOPE.** The offsets
    ///    below are only meaningful for a known member of the family, so an unrecognised selector or a
    ///    length that does not match its arity is REFUSED. A "close enough" length would let a crafted
    ///    blob put our amount somewhere that is not the amount field.
    /// ⛔ **THE GENERIC `swap()` DESCRIPTOR (`0x07ed2379`) IS DELIBERATELY EXCLUDED.** It carries a
    ///    `dstReceiver` and a nested struct, so its amount is NOT at a fixed offset and its payout
    ///    target is caller-chosen — the exact shape `RouteTookAndGaveNothing` exists to catch. It
    ///    cannot be made safe by patching, so it is not admitted at all.
    /// ⚠️ **EMPTY IS LEGAL AND MEANS "NO SUPPLIED ROUTE"** — `_aggSwap` encodes one from pool words
    ///    instead. Both arms end in the same executor and the same floor.
    /// 📌 Memory layout: `route` data begins at `route + 0x20`; the 4-byte selector sits there, so
    ///    word 0 (`token`) is at `+0x24`, word 1 (`amount`) at `+0x44`, word 2 (`minReturn`) at `+0x64`.
    /// ⚠️ `minReturn` is set to **0** on purpose. The bound that matters is `convertTo`'s aggregate
    ///    floor on the MEASURED balance delta — the one number this contract computes itself. Writing
    ///    a per-leg floor here would add a second bound that a multi-input conversion cannot size
    ///    correctly, and the file's own rule is ONE floor on the whole conversion.
    function _retarget(bytes memory route, address tokenIn, address tokenOut, uint256 amountIn)
        internal view
    {
        uint256 len = route.length;
        if (len == 0) return;                                  // pool-word arm; nothing to retarget
        if (len < 4) revert BadRoute();
        bytes4 sel;
        assembly { sel := mload(add(route, 0x20)) }
        uint256 words = sel == UNOSWAP_SELECTOR  ? 4
                      : sel == UNOSWAP2_SELECTOR ? 5
                      : 0;
        if (words != 0) {
            if (len != 4 + words * 32) revert BadRoute();
            assembly {
                mstore(add(route, 0x24), tokenIn)              // word 0 — what we are selling
                mstore(add(route, 0x44), amountIn)             // word 1 — how much, computed on-chain
                mstore(add(route, 0x64), 0)                    // word 2 — the aggregate floor decides
            }
            // ⭐ §SESS-84 — **DERIVE THE DIRECTION BITS HERE, FOR BOTH ARMS.** This was `_aggSwap`'s
            //    real job — *"the keeper names a POOL; which way we cross it is a fact about
            //    `tokenIn`, which this frame owns … removes the last thing a keeper could get
            //    wrong"* — and it is the half that had to STAY when the encoder left. Whatever bit
            //    arrived is DISCARDED, so one route serves a lever-up and the de-lever that unwinds it.
            // ⚠️ First hop from `tokenIn`, last from `tokenOut`: the same trick, needing no knowledge
            //    of the token BETWEEN them. A 3-hop route's middle bit stays as supplied — a stated
            //    gap. The full chaining version was built and measured at **+425 bytes**, which put
            //    `LevMath` 203 OVER EIP-170, and a green suite would not have caught that.
            // ⚠️ **`token0()` IS READ WITHOUT TRUSTING THE POOL TO EXIST.** A typed call to an address
            //    with no code REVERTS on solc's `extcodesize` guard, which would turn a bad pool word
            //    into a hard revert HERE instead of the graceful skip `convertTo` already implements
            //    (*"a failed leg is skipped and the floor decides"*). Measured: four tests that
            //    deliberately name a dead pool went from skipping to reverting.
            // ⇒ a raw `staticcall`: **a pool we cannot read is left as the keeper set it**, and the
            //   leg then fails at the router and is skipped, exactly as before. Derivation is a
            //   correction where it can be applied, never a new failure mode.
            _deriveBit(route, 0x84, tokenIn, true);                       // hop 1, from tokenIn
            uint256 lOff = 0x24 + (words - 1) * 32;
            if (lOff != 0x84) _deriveBit(route, lOff, tokenOut, false);   // last hop, from tokenOut
            return;
        }
        // ⭐ §SESS-69 — **THE GENERIC EXECUTOR, AND IT IS THE ONLY DOOR TO UNISWAP V4.** A v4 pool has
        //    no address (a singleton keyed by `PoolKey`), so no pool word can name one; the same is
        //    true of Balancer and anything else 1inch reaches through its own executor. Admitting
        //    `swap()` is therefore not "one more venue", it is **every venue a pool word cannot spell**.
        // 🔑 **THE DESCRIPTOR IS A STATIC STRUCT, SO IT IS INLINED AND ITS FIELDS ARE AT FIXED
        //    OFFSETS** — which is the entire reason this is patchable at all:
        //      w0 executor · w1 srcToken · w2 dstToken · w3 srcReceiver · w4 dstReceiver
        //      w5 amount   · w6 minReturnAmount · w7 flags · w8 offset→data
        // ⛔ **`dstReceiver` IS FORCED TO US, AND THAT IS THE POINT OF ADMITTING THIS AT ALL.**
        //    `convertTo`'s own note says a hacked keeper can name a `dstReceiver` and have the pinned
        //    router pay ITSELF — that is what `RouteTookAndGaveNothing` exists to CATCH. Overwriting
        //    the field makes the diversion **unconstructible** instead of detectable (standing rule
        //    17), and turns that guard into a backstop rather than the defence.
        // ⚠️ **THE DYNAMIC TAIL IS WHY THE LENGTH CHECK CHANGES SHAPE.** `swap()` carries a `bytes`
        //    argument, so total length is not fixed and cannot be pinned. What IS fixed is the HEAD:
        //    the offset word must equal the head size exactly. A crafted blob that moved it would put
        //    our amount somewhere that is not the amount field — the same failure the arity check
        //    prevents for the unoswap family, expressed the only way a dynamic call allows.
        if (sel != SWAP_SELECTOR) revert BadRoute();
        if (len < 4 + 10 * 32) revert BadRoute();              // 9 head words + at least a length word
        uint256 dataOff;
        assembly { dataOff := mload(add(route, add(0x24, mul(8, 0x20)))) }
        if (dataOff != 9 * 32) revert BadRoute();              // the tail must begin where the head ends
        assembly {
            mstore(add(route, 0x44), tokenIn)                  // w1 srcToken
            mstore(add(route, 0x64), tokenOut)                 // w2 dstToken
            mstore(add(route, 0xA4), address())                // w4 dstReceiver — diversion made impossible
            mstore(add(route, 0xC4), amountIn)                 // w5 amount
            mstore(add(route, 0xE4), 0)                        // w6 minReturnAmount — the delta floor decides
        }
        // ⚠️ **`flags` (w7) IS DELIBERATELY LEFT ALONE, AND IT IS A BOOKED GAP, NOT AN OVERSIGHT.**
        //    1inch's flag word carries a PARTIAL-FILL bit, and the owner's rule is *"no partial fill
        //    … if and only if the swapper agrees to load balance."* Clearing it here would implement
        //    that — but I have not verified WHICH bit it is against the deployed router, and asserting
        //    a bit position I have not measured is the exact failure this function was written to
        //    avoid. **Zeroing the whole word is worse**: `flags` also gates legitimate behaviour, so a
        //    blanket zero would break routes rather than constrain them.
        //    ⇒ value is safe REGARDLESS — a partial fill delivers less and the aggregate delta floor
        //      refuses it. What is unhandled is the swapper's EXPERIENCE, which is §SESS-65 item 3.
    }

    function convertTo(address[] memory inTokens, uint256[] memory inAmounts,
                       address outToken, uint256 minOut, bytes[] memory routes)
        internal returns (uint256 got) {
        uint256 n = inTokens.length;
        require(n == inAmounts.length && n == routes.length, "convertTo/len");
        uint256 before_ = IERC20Min(outToken).balanceOf(address(this));
        uint256 outPrev = before_;                            // §SESS-22 — per-leg watermark
        for (uint256 k; k < n; ++k) {
            uint256 amt = inAmounts[k];
            if (amt == 0 || inTokens[k] == outToken) continue;   // nothing to do / already the target
            uint256 inPrev = IERC20Min(inTokens[k]).balanceOf(address(this));   // §SESS-22
            // ⭐ §SESS-65 — **RETARGET THE SUPPLIED ROUTE ONTO *OUR* NUMBERS.** The caller chooses the
            //    VENUE; this frame owns what is sold, how much, and the floor — so those three words
            //    are overwritten rather than trusted, and a hostile or merely stale route cannot
            //    misstate any of them. **This is what lets `route` carry ANY unoswap-family call, and
            //    therefore any hop count 1inch supports, without an ABI change.**
            // 🔑 **IT ALSO DISSOLVES THE STALENESS THAT POOL WORDS EXISTED TO DODGE.** `dex_word`'s own
            //    note said full calldata *"embeds an `amount`… unknowable off-chain to the wei"*. True —
            //    and irrelevant once the amount is written HERE, from a borrow return this transaction
            //    just computed. ⇒ the pool-word arm is no longer the only amount-safe one.
            _retarget(routes[k], inTokens[k], outToken, amt);
            // 🔴 **`forceApprove`, NOT `approve` — AND THIS WAS A LATENT BUG, NOT A NEW NEED.**
            //    `IERC20Min.approve` declares `returns (bool)`, and **USDT RETURNS NOTHING**, so the
            //    ABI decoder reverts on empty returndata. `_aggSwap` has always called it this way,
            //    which means **USDT could never have been `tokenIn` on the lever path** — a stable
            //    with $252M borrowable on Aave v3 and a 1.7 bps 3pool route. Found by executing a
            //    real USDT route, not by review.
            //    ⭐ `forceApprove` also subsumes the zero-then-set dance USDT demands (it rejects a
            //    non-zero to non-zero approve), so one call replaces the pair and is correct for
            //    standard and non-standard tokens alike.
            IERC20OZ(inTokens[k]).forceApprove(ONEINCH_ROUTER, amt);
            // 🔴 **THE GAS CAP IS A SECURITY BOUND, NOT A TUNING KNOB.** An uncapped `.call` into a
            //    router with CALLER-SUPPLIED calldata can consume the entire budget: measured here at
            //    **931,857,691 gas** on a route that reverts deep inside 1inch's executor. By EIP-150
            //    the outer frame then resumes with 1/64 of what was left, which is not enough to
            //    finish — so `if (!ok) continue` does NOT protect against this. **The whole
            //    transaction dies even though the failure was handled.**
            //    ⚠️ AND IT IS EXACTLY THE KEEPER-COMPROMISE CASE: a hostile route need not steal to
            //    hurt — calldata engineered to burn gas griefs EVERY conversion it is included in.
            //    Capping per leg means one bad leg costs its own budget and nothing more.
            (bool ok, ) = ONEINCH_ROUTER.call{gas: ROUTE_GAS_CAP}(routes[k]);
            IERC20OZ(inTokens[k]).forceApprove(ONEINCH_ROUTER, 0);   // zeroed on BOTH paths
            // ⚠️ **A FAILED LEG IS SKIPPED AND THE FLOOR DECIDES.** ⛔ **THE REASON I FIRST GAVE
            //    FOR THIS WAS WRONG AND IS CORRECTED HERE:** I claimed two independently-built
            //    aggregator routes cannot compose in one transaction. **They compose — measured,
            //    250k USDC + 250k USDT → 201.63 WETH in a single call.** The paired failure was two
            //    real defects (the gas cap above and the `forceApprove` below), not a property of
            //    aggregator routing.
            //    ⇒ The skip still earns its place, on the honest argument: with M inputs, one
            //    unlucky leg should not void a conversion the other legs completed, and `minOut` on
            //    the TOTAL is the bound that matters. **The 1-input case is unchanged** — a failed
            //    single leg yields `got == 0`, below any non-zero floor, so `_aggSwap` reverts
            //    exactly as it always did.
            if (!ok) continue;
            // 🔴 **§SESS-22 — A LEG THAT TOOK OUR TOKENS MUST HAVE GIVEN US TOKENS.**
            //    The aggregate floor does NOT catch a route that SUCCEEDS while sending its output
            //    elsewhere: 1inch's `swap` descriptor names a `dstReceiver`, so a hacked keeper can have
            //    the pinned router pull leg `k`'s input and pay ITSELF. That leg contributes 0 to `got`,
            //    and **the conversion still passes so long as the other legs clear `minOut`** — so up to
            //    the floor's own slack walks out per call, and `convertShortfall` runs ONE LEG PER
            //    STABLE, which is precisely a supply of small legs to divert.
            //    ⇒ `spent > 0 ⇒ delivered > 0` per leg makes that **UNCONSTRUCTIBLE** (standing rule 17)
            //    rather than bounded — the same move `_aggSwap` made against staleness: do not guard the
            //    bad outcome, remove the shape that produces it. **This is what lets the calldata arm
            //    reach ANY venue safely**, which is the whole point of the ladder.
            //    ⚠️ **A REVERT, NOT A `continue`.** The `continue` above is for legs that FAILED, which
            //    cost nothing. Skipping a theft would be the §VACUOUS-BOUNDS shape — an error path that
            //    tolerates the one case it exists to catch.
            //    ⚠️ Deliberately `> 0` and not proportional: any honest route that moves our tokens
            //    delivers SOMETHING, and a per-leg SIZE bound is what §SESS-20 rules out (a keeper would
            //    pass the aggregate by over-delivering one leg).
            uint256 outNow = IERC20Min(outToken).balanceOf(address(this));
            if (IERC20Min(inTokens[k]).balanceOf(address(this)) < inPrev && outNow <= outPrev)
                revert RouteTookAndGaveNothing();
            outPrev = outNow;
        }
        got = IERC20Min(outToken).balanceOf(address(this)) - before_;
        if (got < minOut) revert Slippage();                     // ONE floor, on the WHOLE conversion
    }

    /// @notice **THE LADDER: aggregator calldata when the caller has it, pool words when it does not.**
    /// @dev ⭐ This is the owner's `Amp.sol` pattern applied to routing — *"pull if you can here and
    ///      if you cant then here"* — and the fallback is not conservatism. A route makes execution
    ///      depend on 1inch's API being UP AND NOT RATE-LIMITING, on paths that are PERMISSIONLESS
    ///      and whose purpose is to fire when positions are stressed. An outage must degrade to the
    ///      keyless pool-word path, not to a stalled rebalance.
    ///      ⚠️ BOTH ARMS SHARE ONE FLOOR AND ONE EXECUTOR (`convertTo`), so the calldata arm is not
    ///      a second security surface — it is the same bound reached by a different encoder.
    ///      📊 What the calldata arm buys, measured: Fluid, Balancer, Maverick, Ekubo and the
    ///      `lite-psm`/`dai-usds` par converters that beat every AMM at 0.000%, plus SPLIT routes —
    ///      none of which a pool word can address.
    /// ⭐ §SESS-91 — **ONE VENUE CHANNEL. THE ON-CHAIN ENCODER IS DELETED.**
    ///
    /// 🔴 **IT WAS A DUPLICATE OF A FUNCTION THAT ALREADY EXISTS OFF-CHAIN.** It built
    ///    `abi.encodeWithSelector(UNOSWAP_SELECTOR, 0, 0, 0, dex)`; the keeper's `Plan::route_bytes`
    ///    builds the same bytes from the same pool words. Not two mechanisms — one mechanism written
    ///    twice, in two languages, and the Solidity copy is the one that cost three failed refactors
    ///    over the `(0,w) → (w,0)` compaction and 26 red tests each time.
    /// ⛔ **AND IT WAS NOT THE KEYLESS FALLBACK, WHICH IS WHAT I DEFENDED IT AS.** The fallback is the
    ///    keeper PLANNING without the 1inch API and emitting unoswap calldata itself — that survives
    ///    untouched, is wired to all four legs, and lands here as `route` like everything else. What
    ///    is gone is a second door to the same room.
    /// 🔑 **NOTHING IS LOST IN TRUST TERMS EITHER.** A pool word was caller-supplied; a route is
    ///    caller-supplied. Both are retargeted onto our own token/amount/receiver/floor by
    ///    `_retarget` and bounded on a measured balance delta by `convertTo`. Anyone who could pass a
    ///    pool word can pass a one-hop unoswap route containing it, so the expressive power is a
    ///    superset and the attack surface is identical.
    /// ⚠️ AN EMPTY ROUTE NOW REVERTS. That is the honest surface: a caller naming no venue cannot
    ///    trade, and a silent 0 would reappear as a slippage failure frames away.
    function routedSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut,
                        bytes memory route) internal returns (uint256) {
        if (route.length == 0) revert NoVolatileRoute();
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes[]   memory r = new bytes[](1);
        t[0] = tokenIn; a[0] = amountIn; r[0] = route;
        return convertTo(t, a, tokenOut, minOut, r);
    }

    /// @notice Opportunistic weETH → WETH offramp. Moved here from `SwapLib` (see the note there):
    ///         it is weETH code, and the hop it swaps through is the one body in this library.
    /// @dev    NON-BLOCKING BY DESIGN — every early return is 0, and `sellWeethOnCurve` is called
    ///         with `soft: true`, so a thin or paused pool yields nothing instead of reverting the
    ///         caller. Takes the two fields rather than SwapLib's `OfframpCfg`: SwapLib imports this
    ///         library, so importing the struct back would be a cycle.
    function sourceWeth(uint want, address weeth, address curvePool) public returns (uint) {
        if (want == 0 || weeth == address(0) || curvePool == address(0)) return 0;
        uint idle = IERC20Min(weeth).balanceOf(address(this));
        if (idle == 0) return 0;
        uint weethFull = IWeETH(weeth).getWeETHByeETH(want);
        if (weethFull == 0) return 0;
        uint weethIn = weethFull > idle ? idle : weethFull;
        if (weethIn == 0) return 0;
        uint fairWeth = FixedPointMathLib.fullMulDiv(want, weethIn, weethFull);
        return sellWeethOnCurve(weeth, curvePool, weethIn, (fairWeth * 995) / 1000);  // 0.5% cap
    }

    /// @notice Draw a shortfall PRO-RATA and convert it into the token the maker signed for.
    /// @dev ⭐ `public`, NOT `internal` — an internal library function is INLINED into its caller, and
    ///      inlining this put `Quid` 124 bytes over EIP-170. `public` makes it a delegatecall.
    ///      ⚠️ UNITS, EACH ESTABLISHED RATHER THAN ASSUMED: `short18` is USD **18-dec**, the unit
    ///      `BasketLib.takeBody` expects on the pro-rata path (it clamps against `amounts[14]`, the
    ///      18-dec basket total); `convertTo` returns the payout token's **NATIVE** units, being a
    ///      measured balance delta; the return is **6-dec USD**. A slip between these is the 1e12
    ///      class that already cost a full position debit on this rail.
    /// @dev ⭐ A PRO-RATA draw leaves basket composition UNTOUCHED, which is why no envelope is
    ///      needed on the input side — and it is multi-source BY CONSTRUCTION, so the aggregator
    ///      splits across venues that do not compete for the same liquidity with nobody choosing it.
    function convertShortfall(address aux, address quid, address payoutToken, address owner,
                              uint short18, bytes[] memory routes) public returns (uint) {
        // 🔴🔴 **THE FLOOR IS THE WHOLE SAFETY OF THIS FUNCTION. IT WAS `0` AND THAT WAS A DRAIN.**
        //    With no floor, a caller supplies routes that consume the approved stables and return
        //    nothing: `got == 0` clears `0 >= 0`, the basket's drawn slice is GONE, the maker is
        //    paid nothing, and because their ether debit is derived from the proceeds it barely
        //    moves — so the position is not even reduced to compensate. **Nothing reverts.**
        //    ⚠️ AND `fillIntent` IS PERMISSIONLESS, so this was open to anyone, not only to a
        //    compromised enclave. Found auditing my own change from twenty minutes earlier.
        // ⭐ THE DRAW'S OWN RETURN IS THE RIGHT BASIS, not `short18`: the basket may deliver LESS
        //    than asked (§PARTIAL-TAKE), and flooring against what we asked for would revert an
        //    honest conversion of a short draw. `take` reports USD18 actually drawn.
        uint drawn18 = IAux(aux).take(address(this), short18, quid, 0);   // token == QU!D ⇒ PRO-RATA
        if (drawn18 == 0) return 0;
        address[] memory st = IAux(aux).getStables();
        uint[] memory amt = new uint[](st.length);
        // The range custodies no basket stables in the normal course, so a post-draw balance IS
        // exactly what the draw delivered — no before/after snapshot needed.
        for (uint k; k < st.length; ++k) amt[k] = IERC20Min(st[k]).balanceOf(address(this));
        // Oracle-derived and SIZE-AWARE — the same curve every other floor in this library uses, so
        // a large conversion is not held to a small trade's tolerance.
        uint floor_ = _fromUsd(aux, payoutToken, drawn18) * (10_000 - _slipBps(drawn18)) / 10_000;
        // §SESS-23 — **RAISE THE FLOOR TO WHAT WE COULD HAVE SERVED OURSELVES.** Summed per leg because
        // the floor is on the WHOLE conversion (a per-leg floor would cost the liveness the `continue`
        // above exists to buy). A leg with no quotable route contributes 0, so this can only ever
        // TIGHTEN the bound — never loosen it, and never revert a conversion for want of a quote.
        uint ref_;
        for (uint k; k < st.length; ++k) ref_ += _selfServableQuote(st[k], amt[k], payoutToken);
        if (ref_ > floor_) floor_ = ref_;
        uint extra = convertTo(st, amt, payoutToken, floor_, routes);
        if (extra == 0) return 0;
        IERC20OZ(payoutToken).safeTransfer(owner, extra);
        return scaleTo6(extra, payoutToken);
    }

    /// @notice Native token units → 6-dec USD, by the token's own `decimals()`.
    ///         THE ONLY IMPLEMENTATION IN THE TREE — `SwapLib` names this body directly
    ///         (`SwapLib.sol:521`, `:2020`); there is no twin to keep in step.
    /// @dev ⛔ DO NOT COPY IT BACK INTO `SwapLib` "to avoid a cycle" — there is none. `LevMath` is the
    ///      bottom layer (it imports none of SwapLib/BasketLib/QuidLib) and `SwapLib` imports it at
    ///      `SwapLib.sol:28`, so the dependency only ever runs one way.
    /// ⛔ NOT `BasketLib.from6`, WHICH IS THE INVERSE AND MUST NOT BE FOLDED IN. That one goes 6-dec →
    ///    NATIVE and MULTIPLIES where this divides; the duplicate-body detector scores them as similar
    ///    because the shape matches, and substituting either for the other is a decimal-basis bug —
    ///    this repo's most common class (§A.72 cost 333 failing tests).
    function scaleTo6(uint amount, address token) internal view returns (uint) {
        uint8 d = IERC20Min(token).decimals();
        return d == 6 ? amount : (d > 6 ? amount / 10 ** (d - 6) : amount * 10 ** (6 - d));
    }

    /// @notice weETH → WETH on a Curve pool. **THE ONLY IMPLEMENTATION OF THIS TRADE IN THE TREE.**
    /// @dev ⛔ **DO NOT WRITE THIS TRADE A SECOND TIME.** It was written twice once — the lever's
    ///      de-lever and the basket's weETH offramp, the SAME six lines (approve, `exchange(1, 0)`,
    ///      catch, zero the approval, return 0) differing only in where the pool came from. Two copies
    ///      of one external call is two places to add a router, two places to get an approval wrong,
    ///      and two places for the ETH offramp to drift from the lever's.
    ///      ⭐ **THE BODY LIVES HERE BECAUSE `SwapLib` ALREADY IMPORTS `LevMath` (`SwapLib.sol:28`)
    ///      AND THE REVERSE WOULD BE A CYCLE.** Callers today: `QuidLib`, plus `sourceWeth` and
    ///      `_weethToWethDex` in this file (the latter adds the redemption-rate floor).
    ///      ▶️ **THIS IS THE SEAM TO ROUTE, AND THE REASON TO FOLD FIRST: a single hardcoded Curve
    ///      pool is not a best path.** `ETHERFI_CURVE_POOL` has no fallback — if it is thin or paused
    ///      the leg returns 0 and the de-lever silently sources nothing. Adding an aggregator here
    ///      now upgrades EVERY weETH offramp at once; adding it before this fold would have upgraded
    ///      one and left the other behind.
    function sellWeethOnCurve(address weeth, address pool, uint256 amountIn, uint256 minOut)
        internal returns (uint256) {
        return curveExchange(weeth, pool, int128(1), int128(0), amountIn, minOut, true);
    }

    /// @notice **THE ONLY DIRECT CURVE CALL IN THE TREE.** Every stable⇄stable and weETH→WETH hop that
    ///         does not go through the aggregator lands here.
    /// @dev §PM-INVARIANT-3 — exact-amount approval, ZEROED on the failure path. An allowance that
    ///      survives a failed swap is a standing claim on the next block's balance.
    ///      ⚠️ `forceApprove`, not `approve`: a basket stable may be USDT, which returns no bool
    ///      (§NONSTANDARD-ERC20) and refuses a non-zero to non-zero approve.
    /// @param soft `true` ⇒ a reverting pool yields 0 rather than propagating. The weETH offramp is
    ///        OPPORTUNISTIC and must not take the caller down with it; the hub hop is NOT — a silent
    ///        0 there would leave a position unhedged, so it propagates.
    function curveExchange(address tokenIn, address pool, int128 i, int128 j,
                           uint256 amountIn, uint256 minOut, bool soft) internal returns (uint256) {
        if (pool == address(0) || amountIn == 0) return 0;
        // 🔴 **§SESS-46 — DO NOT DECODE THE POOL'S RETURN VALUE. OLD CURVE POOLS RETURN NOTHING.**
        //    This read `return ICurvePool(pool).exchange(...)` against an interface declaring
        //    `returns (uint256)`. **Curve's 3pool (`0xbEbc4478`) is an old Vyper pool whose `exchange`
        //    returns VOID**, so the ABI decoder reverted on empty returndata — the swap having already
        //    SUCCEEDED (measured: DAI in, 10.739097 USDC out, then the revert). ⚠️ **That is verbatim
        //    the USDT trap `convertTo` records** — *"`approve` declares `returns (bool)`, and USDT
        //    RETURNS NOTHING, so the ABI decoder reverts on empty returndata"* — in a second place.
        //    ⇒ it is why routing USDT or DAI through 3pool failed. ⚠️ **IT IS *NOT* WHY USDT WAS
        //    UNBORROWABLE, AND I WROTE THAT SENTENCE HERE BEFORE CHECKING — the keeper was discarding
        //    the hub pool word it had already planned (§SESS-47, `plan_for_lp`).** Two independent
        //    defects on one path: this one is real and is fixed below, and it would have stayed
        //    invisible had the other not sent every non-USDC stable through here. Per standing rule 13
        //    a dismissal is a conclusion — so note that this fix is kept on its OWN merits (`_hubHop`
        //    runs EVERY hub hop through this body), not as the USDT fix.
        // ⭐ **MEASURE THE DELTA INSTEAD — the discipline `_aggSwap` already states:** *"`minOut` IS
        //    ENFORCED ON THE BALANCE DELTA, NEVER ON THE ROUTER'S RETURN VALUE … a hostile or merely
        //    mis-encoded pool cannot fake our own balance."* The same argument applies to a pool.
        // ✅ **AND IT CLOSES §SESS-2's SECOND HAZARD IN THE SAME CHANGE:** the approval was zeroed only
        //    on the failure path, leaving a standing allowance after a SUCCESSFUL partial pull — *"a
        //    standing claim on the next block's balance."* It is now zeroed on BOTH paths.
        address tokenOut = ICurvePool(pool).coins(uint256(int256(j)));
        uint256 before_ = IERC20Min(tokenOut).balanceOf(address(this));
        IERC20OZ(tokenIn).forceApprove(pool, amountIn);
        // Low-level: a void-returning pool must not revert the decoder. Success is the DELTA.
        (bool ok, ) = pool.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", i, j, amountIn, minOut));
        IERC20OZ(tokenIn).forceApprove(pool, 0);                 // zeroed on BOTH paths
        uint256 got = IERC20Min(tokenOut).balanceOf(address(this)) - before_;
        if (!ok || got < minOut) {
            if (soft) return 0;                                  // soft: a thin pool yields nothing
            revert Slippage();                                   // hard: fail loud, never a silent 0
        }
        return got;
    }

    function _weethToWethDex(SellCtx memory c, uint256 pulled) internal returns (uint256) {
        // ⚠️ The floor is the REDEMPTION RATE, not an AMM quote, which is why it keeps the flat
        //    `SELL_SLIP_BPS` rather than the size-aware curve — trade size is not the variable here.
        uint256 wethFloor = IWeETH(c.weeth).getEETHByWeETH(pulled) * (10_000 - SELL_SLIP_BPS) / 10_000;
        return sellWeethOnCurve(c.weeth, ETHERFI_CURVE_POOL, pulled, wethFloor);
    }

    /// stable → collateral (lever-up BUY). ONE arm, no venue branch: buy WETH, mint weETH at ether.fi.
    function stableToColl(SellCtx memory c, address stable, uint256 stableAmt, uint256 minOut)
        public returns (uint256)
    {
        return _stableToWeeth(c, stable, stableAmt, minOut);
    }

    /// @dev stable → weETH. THE ONLY COLLATERAL PATH: raw-WETH collateral is strictly dominated — same
    ///      delta and the same IL offset, but it forgoes the ether.fi ratchet (+2.46%/yr, measured) for
    ///      as long as it sits as collateral. It is a worse way to buy the SAME hedge, not a different
    ///      hedge, so there is no WETH-collateral branch to select.
    function _stableToWeeth(SellCtx memory c, address stable, uint256 stableAmt, uint256 minWeethOut) internal returns (uint256 weethOut) {
        weethOut = _wethToWeeth(c, _stableToWethSor(c, stable, stableAmt));
        if (weethOut < minWeethOut) revert Slippage();
    }

    /// WETH → weETH on-ramp (the INVERSE of `_weethToWeth`): mint at ether.fi's fair rate. NON-reverting —
    /// a fair-rate mint always clears, and `wethRem == 0` is a no-op rather than an error, so the single
    /// caller (`_stableToWeeth`) can apply its own `minWeethOut` instead of catching a nested revert.
    function _wethToWeeth(SellCtx memory c, uint256 wethRem) internal returns (uint256 weethOut) {
        if (wethRem > 0) { // mint the remainder WETH→weETH at ether.fi's fair rate.
            IERC20Min(c.weth).approve(ETHERFI_ADAPTER_M, wethRem);
            uint256 bef = IERC20Min(c.weeth).balanceOf(address(this));
            IDepositAdapter(ETHERFI_ADAPTER_M).depositWETHForWeETH(wethRem, address(0));
            weethOut += IERC20Min(c.weeth).balanceOf(address(this)) - bef;
        }
    }

    /// stable → WETH via the caller-funded basket SOR (REAL markets), floored at oracle WETH − MAX_SLIPPAGE (anti-MEV).
    /// @dev IDENTITY WHEN THE LOAN TOKEN IS ALREADY WETH — no SOR, no fee, no slippage.
    ///      The IL-protect lever borrows, then immediately buys the ETH it is hedging with. While the
    ///      loan token is a stable that costs a SOR leg on EVERY OPEN (here) and another on every
    ///      close (`_wethToStableDex`), each paying our in-range fee PLUS the external venue fee PLUS
    ///      slippage — a double charge, twice per round trip, to reach an asset we could have
    ///      borrowed directly. The collateral is weETH, the exposure hedged is ETH-denominated and
    ///      the exit needs WETH; the stable is a detour with a toll at both ends.
    ///      This short-circuit makes the lever WETH-LOAN-READY with zero behaviour change while the
    ///      market still lends a stable. Registering a weETH-collateral / WETH-loan market then
    ///      removes both legs by itself.
    /// @dev Borrowed stable → WETH. Two hops, because the deep dollar markets are RLUSD/PYUSD
    ///      while the volatile book is reached through the aggregator:
    ///          stable →(Curve stableswap, int128)→ USDC →(1inch, `_aggSwap`)→ WETH
    ///      The caller mints the result straight into weETH; WETH never rests as collateral.
    /// ⚠️ THE FLOOR IS ORACLE-DERIVED AND APPLIED TO THE WHOLE ROUTE, not per hop. A per-hop floor
    ///      would let the pair of hops lose more than the stated slippage between them. This is the
    ///      only real protection on the leg — the caller's `minOut` is an ADDITIONAL check, and a
    ///      permissionless `rebalance` may pass 0 for it.
    /// @notice §V-R1-MIN — THE KEYLESS ARM OF THE LADDER: a pool word in, router calldata built HERE.
    /// @dev    The keeper supplies no calldata on this path and needs no HTTP client, so its whole
    ///         role stays "decide the moment, name a venue". The two properties that make that safe
    ///         are enforced downstream in `convertTo`, which is the single executor for BOTH arms:
    ///         ① EXACT, ZEROED APPROVAL — set to `amountIn`, cleared on both paths. Clearing to 0
    ///            first keeps USDT-style tokens (which reject a non-zero-to-non-zero approve) working.
    ///         ② THE FLOOR IS CHECKED AGAINST A MEASURED BALANCE DELTA, not the router's return
    ///            value. A return value is a number the callee chooses; a guard that trusts one is
    ///            checking the failing party's own homework — and a POOL's fill is not something we
    ///            get to assert either.
    ///
    ///         ⚠️ `minOut` IS ORACLE-DERIVED BY THE CALLER, never passed through from a user. Every
    ///         call site floors it at `TWAP * (10_000 - slip)/10_000` first. `rebalance` is
    ///         permissionless, so the caller picks WHEN and the contract picks the PRICE BOUND —
    ///         that division is what makes a permissionless rebalance anti-sandwich.
    /// @notice Execute a volatile hop on 1inch AggregationRouterV6. §C2.1 (owner: "1inch only").
    /// @dev  ⭐ **THE KEEPER SUPPLIES NO CALLDATA ON THIS ARM, AND THAT IS THE WHOLE POINT OF ITS
    ///       SHAPE.** ⛔ Do not make this function take `bytes route` and `call` it verbatim — that is
    ///       `routedSwap`'s other arm, and it belongs there rather than here, because **1inch calldata
    ///       embeds its own `amount` and every amount that reaches this function is computed
    ///       ON-CHAIN.** `_stableToWethSor` passes `_hubHop(...)`'s CURVE OUTPUT; `leverUpBuyWbtc`
    ///       passes `venue.borrow(...)`'s return. Neither is predictable off-chain to the wei, so a
    ///       pre-built route's amount is stale by construction: too high and the router's
    ///       `transferFrom` reverts, too low and it under-swaps. **A keeper cannot supply a route that
    ///       is right by construction here, only one that happens to work** — which is exactly why the
    ///       keyless arm has to exist beside the calldata one.
    ///       ⇒ Taking the POOL and building the calldata here makes that class UNCONSTRUCTIBLE
    ///       (standing rule 17) rather than guarded. The contract owns `tokenIn`, `amountIn`,
    ///       `minOut` and the callee; the keeper owns only the venue choice, which is the one part
    ///       it actually knows better than we do.
    /// @dev  🔴 THE THREE PROPERTIES THAT KEEP AN EXTERNAL CALL SAFE WHILE HOLDING FLASH-BORROWED
    ///       FUNDS ARE ALL STRICTLY STRONGER NOW, BUT STILL REQUIRED:
    ///        1. THE CALLEE IS A PINNED CONSTANT (`ONEINCH_ROUTER`), and now so is the SELECTOR.
    ///           The keeper picks a pool, never a destination and never a function.
    ///        2. `minOut` IS ENFORCED ON THE BALANCE DELTA, NEVER ON THE ROUTER'S RETURN VALUE.
    ///           ⚠️ NOT REDUNDANT WITH THE `minReturn` WE NOW PASS: **measured 2026-08-26, a V2
    ///           pool word against `unoswap` returned `ok` AND MOVED ZERO TOKENS** — the router's
    ///           own bound did not fire. Only our balance delta caught it. A hostile or merely
    ///           mis-encoded pool cannot fake our own balance.
    ///        3. THE APPROVAL IS RESET ON BOTH SIDES, including the failure path — an allowance
    ///           that survives a reverted swap is a standing claim on the next block's balance.
    ///       ⚠️ `dex == 0` is REFUSED rather than treated as a no-op: silently swapping nothing and
    ///       returning 0 would surface as a slippage revert four frames away.
    /// @dev   ⚠️ EVERY SECURITY PROPERTY OF THE ONE-HOP FORM IS UNCHANGED AND SHARED, WHICH IS WHY THIS
    ///        IS ONE BODY AND NOT AN OVERLOAD: the callee is still the pinned router, the selector is
    ///        still a CONSTANT (now one of two, chosen by our own arithmetic rather than by the
    ///        caller), the amount is still computed on-chain, `minOut` is still the caller's
    ///        oracle-derived floor, and the floor is still enforced on the MEASURED BALANCE DELTA of
    ///        `tokenOut` — which bounds the whole route regardless of how many pools it crossed.
    ///        ⛔ A second selector does NOT widen what the keeper can reach: it still supplies only

    function _stableToWethSor(SellCtx memory c, address stable, uint256 stableAmt) internal returns (uint256) {
        if (stable == c.weth) return stableAmt;          // already WETH: no venue needed
        uint256 usd18_ = _toUsd18(c.aux, stable, stableAmt);
        // §SESS-44 — ONE formula (`swapFloor`), same budget. Was an inline TWAP division here and
        // `_fromUsd` on the close leg: the same expression written two ways to dodge the same
        // feed-wiring hazard. `swapFloor` prices feed-independently, so both can share it.
        uint256 floor_ = swapFloor(c.aux, stable, stableAmt, c.weth, _slipBps(usd18_));
        // ⭐ NOTE THE `floor_`: THIS SIDE BOUNDS THE SWAP, AND ITS MIRROR DID NOT. `_wethToStableDex`
        //    (the CLOSE leg) passed `0` and discarded its own `minOut` — see §MINOUT-DROPPED. The
        //    open/close asymmetry is what identified it: one direction derives an oracle floor at
        //    `SELL_SLIP_BPS`, the other trusted the keeper's route outright.
        // §SESS-50 — **THE COMPAT ARM IS NOW EXACTLY WHAT IT IS FOR: A NON-HUB STABLE THE KEEPER
        //    COULD NOT PLAN.** USDC has no hub hop BY NATURE, not by omission, and `_aggSwap` now
        //    compacts that zero — so a USDC venue takes the routed path like everything else, and in
        //    doing so **reaches `c.route` for the first time.** The old guard sent it down a branch
        //    that drops `route`, which is how the full-venue arm came to be unreachable for the most
        //    common venue in the system.
        // ⭐ §SESS-51 — **NO FALLBACK LEFT, BECAUSE THERE IS NOTHING TO FALL BACK TO.** The hub hop is
        //    ALWAYS available: the keeper's word when it has one, `_hubHop`'s table otherwise. This is
        //    a plain OVERRIDE WITH A DEFAULT, not a migration branch waiting to be deleted.
        // No keeper word ⇒ take the table's route. `minOut` 0 on the hub leg is correct: `floor_`
        // bounds the whole route on the final token.
        // ⭐ §SESS-91 — **NO HUB BRANCH. THE ROUTE *IS* THE HUB HOP PLUS THE VOLATILE HOP.**
        //    This split `stable → USDC → volatile` into an on-chain Curve hop and a routed hop, and
        //    passed `""` to the second one — so for every NON-HUB stable the supplied route was
        //    DISCARDED and the volatile leg fell back to a single pool word. No two-hop, no split,
        //    no v4, no Fluid, on exactly the stables that need them most.
        // ⇒ one call, whatever shape the route describes. `floor_` bounds the FINAL token, which is
        //   what it always did; the USDC intermediate was never bounded and no longer exists as a
        //   separate frame to leave value in.
        return routedSwap(stable, c.weth, stableAmt, floor_, c.route);
    }


    /// @notice §SESS-52 — **ONE HUB HOP, EITHER DIRECTION, ON THE ONE TABLE.** Curve stableswap,
    ///         `toUsdc ? stable→USDC : USDC→stable`; ONE body for the two legs, which differ only in
    ///         which token is approved and in the index order. A stable that is not on `_hubRowOf`
    ///         fails CLOSED (`NoStableRoute`) — a silent 0 would leave a position unhedged.
    /// ⛔ **DO NOT GIVE THE EXECUTION PATH ITS OWN ROUTE TABLE.** `_hubRowOf` returns exactly the
    ///    `(pool, iStable, iUsdc)` this needs and is already pinned row-by-row by
    ///    `CurveTablePins.t.sol`; a second table — settable or not — is a copy of a superset, which
    ///    standing rule 23, question 2 rules out (*a subset or a copy is never worth a declaration*),
    ///    and a SETTABLE one would additionally break the floor: **a floor whose reference is settable
    ///    by the same key that sets the route is not a floor.**
    /// ⚠️ **`minOut` IS CARRIED, AND ⛔ MUST NOT GO BACK TO ZERO.** Calling the pool with a `min_dy`
    ///    of `0` and leaning on a downstream floor to catch the final output leaves the intermediate
    ///    hop unbounded — the hazard this file flags on the mirror leg. `curveExchange` enforces the
    ///    floor it is given on the measured delta.
    /// ⚠️ **DIRECTION IS THE CALLER'S, NEVER THE TABLE'S** — same discipline as `_aggSwap` deriving
    ///    `ZERO_FOR_ONE` rather than trusting a keeper bit, so one row serves a lever-up and the
    ///    de-lever that unwinds it and the two cannot disagree about which way to cross a pool.
    /// ⛔ §SESS-91 — **CONSOLIDATE-ONLY NOW, AND THE `word` PARAMETER IS GONE WITH THE LEVERED ARMS.**
    ///    Every levered leg takes a supplied route; the ONE caller left is `_consolidateTo`, which
    ///    always passed `0` because `protectFromQuid` is PERMISSIONLESS — caller-supplied venues there
    ///    would hand an anonymous address the SELECTION of every venue against a 20 bps floor, and the
    ///    floor bounds the loss, never the selection.
    /// ⛔ **AND THE DISTINCTION IS NOT AUTHENTICATION — I WROTE THAT AND IT IS FALSE.** `rebalance`
    ///    is `external nonReentrant` with NO auth (`LevManager:282`, it merely records
    ///    `_activeKeeper = msg.sender`), exactly like `protectFromQuid`. **Both callers are
    ///    anonymous.** The difference is that `protectFromQuid` takes no venue parameter at all.
    /// 🔑 **THE REAL PRINCIPLE IS ABOUT WHAT A REPEATED SELECTION CAN EXTRACT.** A levered leg is ONE
    ///    trade against a floor derived from the TWAP, so delegating its venue risks the floor's slack
    ///    once. `consolidate` runs **one leg per stable**, so a caller who could name venues would get
    ///    that slack again per slice, on demand, for free — *the floor bounds the loss, never the
    ///    selection, and selection is the takeable part.* ⇒ **venue selection is delegated where it is
    ///    exercised once and bounded once; it is fixed where the same anonymous caller can repeat it.**
    function _hubHop(address stable, uint256 amt, bool toUsdc, uint256 minOut)
        internal returns (uint256)
    {
        if (amt == 0) return 0;
        if (stable == USDC) return amt;            // hub itself — nothing to convert, either direction
        // ⛔ §SESS-86 — **NO `PROTO_V4` ARM HERE, AND `V4Lib` IS DELETED.** It was UNREACHABLE, not
        //    merely unnecessary: every caller of `_hubHop` reaches it only under
        //    `hub == 0 || hub >> 253 == PROTO_CURVE`, so a v4 word could never arrive — and the
        //    keeper cannot send one anyway (`venue_word(Venue::V4) => None`, because a singleton has
        //    no address to put in a word). ⚠️ **The only test it had called the library DIRECTLY**,
        //    so a green suite said "the v4 encoding executes" about a branch nothing could enter.
        // ⇒ v4 belongs where every other multi-hop venue already lives: in a route BUILT OFF-CHAIN
        //   and retargeted here. Building UniversalRouter calldata on-chain was ~80 lines and a
        //   linked deployment to reach a case that never arrived.
        (address pool, int128 iS, int128 iU) = _hubRowOf(stable);
        // fail closed — a silent 0 would leave the position unhedged, and a caller that sizes a hedge
        // from "converted nothing" is the failure this revert exists to make loud.
        if (pool == address(0)) revert NoStableRoute();
        // `soft: false` — an unhedged position is worse than a revert.
        return toUsdc ? curveExchange(stable, pool, iS, iU, amt, minOut, false)
                      : curveExchange(USDC,   pool, iU, iS, amt, minOut, false);
    }

    /// @notice §SESS-23 — **WHAT THIS CONTRACT COULD GET FOR ITSELF, WITHOUT A KEEPER.** 0 when it has
    ///         no way to know, which is the whole reason this is safe to use as a FLOOR.
    ///
    /// ⭐ **WHY THIS EXISTS: THE FLOOR'S SLACK IS THE BLEED, AND THE SLACK IS A GUESS.** `_slipBps` is
    ///    25 bps rising to a 100 bps cap, applied to every leg — while §ROUTE-COST-MEASURED puts real
    ///    execution at **1.7–8 bps** for the stables we route. **Every basis point between the two is a
    ///    basis point a compromised keeper may take** by routing through a venue that delivers exactly
    ///    the floor. §SESS-22 closed the outright THEFT (a leg that takes and gives nothing); this is
    ///    the remaining QUALITY residual.
    /// 🔑 **AND IT DISSOLVES THE OPEN QUESTION RATHER THAN ANSWERING IT.** The booked remedy was
    ///    *"tighten `_slipBps`"*, with the standing warning *"**measure per-route before choosing the
    ///    number** — the number that is safe for USDT is not automatically safe for GHO."* A quote
    ///    **IS** that per-route measurement, taken live at the size actually being traded. ⇒ the
    ///    constant stops being load-bearing wherever a quote exists, so nothing has to be guessed.
    ///
    /// ⚠️ **`max(oracleFloor, quote)` IS THE MANIPULATION-SAFE DIRECTION, AND THE DIRECTION IS THE
    ///    ARGUMENT.** A reference pushed DOWN cannot lower our floor — `max` falls back to the oracle,
    ///    i.e. exactly today's behaviour. A reference pushed UP costs LIVENESS (honest routes fail),
    ///    never custody. That asymmetry is why a manipulable venue is admissible here and would not be
    ///    admissible as a price. Same discipline as the min-of-two-prices shape used elsewhere.
    /// ⚠️ **COVERAGE IS THE SIX ROWS IN `_hubRowOf`**, so this raises the floor on the stables it knows
    ///    and is inert on the rest — **inert, never loosening.** Growing that table grows the coverage;
    ///    that is the same ungrowable-roster item §S2 books.
    /// @dev Every read is `try`-wrapped to 0: an unquotable route must contribute NOTHING to the floor
    ///      rather than revert a conversion, because a missing quote is not a missing conversion.
    function _selfServableQuote(address tokenIn, uint256 amtIn, address tokenOut)
        internal view returns (uint256)
    {
        if (amtIn == 0) return 0;
        if (tokenIn == tokenOut) return amtIn;
        if (tokenIn == USDC)  return _curveQuote(tokenOut, amtIn, false);
        if (tokenOut == USDC) return _curveQuote(tokenIn,  amtIn, true);
        uint256 viaHub = _curveQuote(tokenIn, amtIn, true);      // tokenIn → USDC
        if (viaHub == 0) return 0;
        return _curveQuote(tokenOut, viaHub, false);             // USDC → tokenOut
    }

    /// @notice §SESS-52 — **THE ONE CURVE HUB TABLE: SIX COMPILE-TIME ROWS, QUOTED *AND* TRADED.**
    ///         `_curveQuote`/`_selfServableQuote` price against it, `_hubHop` executes against it, and
    ///         `_routableStable` asks it whether a slice can move at all. There is no second table and
    ///         no settable one.
    /// 🔴 **IT STAYS BYTECODE, AND THAT IS A TRUST PROPERTY RATHER THAN A STYLE ONE: a floor whose
    ///    reference is settable by the same key that sets the route is not a floor.** ⛔ DO NOT MOVE
    ///    THESE ROWS INTO OWNER-SET STORAGE. Compile-time means nobody can re-point what we will
    ///    ACCEPT, and because the same rows are what we TRADE, nobody can re-point that either.
    /// ⚠️ **ADDING A ROW IS A BEHAVIOUR CHANGE, NOT A WIDENING — MEASURE FIRST.** Every row here is
    ///    executable, so a new one flips slices from refunded to SWAPPED: §SESS-24 measured exactly
    ///    that breaking `test_ProtectFromQuid_HostileOperatorNetsZero`. The four rows that were once
    ///    quote-only measure **4 / 1 / -1 / 0 bps flat to $1M**, which is why they are safe to trade;
    ///    a row without that measurement is not.
    /// @dev Each row was picked by DEPTH AT SIZE and verified against `coins()` — see the constants'
    ///      block, `evm/test/CurveTablePins.t.sol` (pins all six rows, asserts the exclusions stay
    ///      zero) and `evm/test/HubHopRoster.t.sol` (asserts the execution behaviour head-on).
    function _hubRowOf(address stable) private pure returns (address pool, int128 iStable, int128 iUsdc) {
        if (stable == RLUSD_TOKEN)  return (CURVE_USDC_RLUSD,   CRV_RLUSD_IDX,  CRV_RLUSD_USDC_IDX);
        if (stable == PYUSD_TOKEN)  return (CURVE_PYUSD_USDC,   CRV_PYUSD_IDX,  CRV_PYUSD_USDC_IDX);
        if (stable == USDT_TOKEN)   return (CURVE_3POOL,        CRV_USDT_IDX,   CRV_USDT_USDC_IDX);
        if (stable == DAI_TOKEN)    return (CURVE_3POOL,        CRV_DAI_IDX,    CRV_DAI_USDC_IDX);
        if (stable == USDG_TOKEN)   return (CURVE_USDG_USDC,    CRV_USDG_IDX,   CRV_USDG_USDC_IDX);
        if (stable == CRVUSD_TOKEN) return (CURVE_CRVUSD_USDC,  CRV_CRVUSD_IDX, CRV_CRVUSD_USDC_IDX);
        // Absent ⇒ (0,0,0). On the QUOTE side that contributes NOTHING to the floor — never a revert,
        // never a loosening. On the EXECUTION side it is the fail-closed case: `_routableStable` says no
        // and `_hubHop` reverts `NoStableRoute` rather than trading somewhere unmeasured.
    }

    /// @dev One table hop, quoted. `toUsdc` mirrors `_hubHop`'s parameter, and both read the SAME
    ///      `_hubRowOf` row, so the quote and the swap cannot disagree about the pool OR the direction.
    function _curveQuote(address stable, uint256 amt, bool toUsdc) private view returns (uint256) {
        (address pool, int128 iStable, int128 iUsdc) = _hubRowOf(stable);
        if (pool == address(0)) return 0;                        // not on the table ⇒ no opinion
        try ICurvePool(pool).get_dy(toUsdc ? iStable : iUsdc, toUsdc ? iUsdc : iStable, amt)
            returns (uint256 dy) { return dy; } catch { return 0; }
    }

    /// @dev Does this stable have a hub route on the table? Checked rather than caught: an unroutable
    ///      slice must be SKIPPED and refunded, not swapped at whatever a fallback would give.
    /// §SESS-52 — asks THE one table. `pure` again: nothing about a route is state any more.
    function _routableStable(address t) internal pure returns (bool) {
        if (t == USDC) return true;                // the hub itself
        (address pool,,) = _hubRowOf(t);
        return pool != address(0);
    }

    /// @dev stable → WBTC (BTC lev open) and WBTC → stable (close), both VIA USDC — two hops on
    ///      DIFFERENT venues: stable↔USDC is Curve stableswap, USDC↔WBTC goes through the aggregator.
    ///      `minOut` is applied on the LAST hop so it bounds the whole route.
    /// @dev §V-R1-MIN's two hops SURVIVE; what the keeper supplies is WHERE EACH ONE EXECUTES. With
    ///      both pool words present they cross as ONE `unoswap2` route, so **any stable with an
    ///      addressable pool is borrowable** and no compile-time table has to be extended for it.
    ///      ⭐ THE SAFETY ARGUMENT IS UNCHANGED AND STRICTLY STRONGER: the keeper names only pools,
    ///      and the ORACLE FLOOR bounds the WHOLE route on a measured balance delta.
    /// 🔴 **ARGUMENT ORDER IS A TRAP HERE AND IS DELIBERATE. `_aggSwap` takes (hop1, hop2); the
    ///    keeper's LONG-STANDING `dex` MEANS THE VOLATILE POOL, WHICH IS HOP **2**.** The new `dex2`
    ///    carries the stable→USDC hub hop, i.e. hop **1**. Passing them in declaration order would
    ///    silently redefine what the third argument of every live entrypoint means — the keeper would
    ///    keep sending the same word and it would be used for the wrong leg. Appending the new
    ///    parameter and CROSSING it here keeps every existing caller's meaning intact.
    /// @dev ⚠️ **`hubDex == 0` IS AN OVERRIDE WITH A DEFAULT, NOT A COMPATIBILITY SHIM.** No keeper
    ///      word for the hub leg ⇒ take the table's route (`_hubHop` → `_hubRowOf`), which is available
    ///      for every stable on the table and needs no keeper to be up. `stable == USDC` skips the guard
    ///      because USDC IS the hub — there is no hub leg to route, and `_aggSwap` compacts the
    ///      resulting zero hop (§SESS-50) so a USDC venue reaches `route` like every other venue.
    ///      ⛔ **NOT A "BRIDGE".** In this repo `quid-bridge` is the DAEMON — `channel_driver.rs`,
    ///      `deadman_exit.rs` and `lp_seed.rs` (Lightning) live in the same crate as `lev_keeper.rs`
    ///      and `lev_keeper_btc.rs`. **The Lightning bridge and the leverage keeper are ONE PROCESS**,
    ///      so the word is taken and using it for a compatibility branch reads as if this had
    ///      something to do with the hop. It does not.
    ///      🔴 **AND THAT SHARED PROCESS IS A SECURITY FACT, NOT A PACKAGING DETAIL: compromising
    ///      the LN daemon compromises the lev keeper, and vice versa.** It is why the owner's
    ///      "keeper is hacked and replaced with malicious code" constraint spans both roles at once,
    ///      and why an API key placed there is leaked alongside the Lightning material.
    ///      🔴 **THE `stable != USDC` HALF OF THE GUARD IS LOAD-BEARING AND ONLY WORKS BECAUSE
    ///      `_aggSwap` COMPACTS A ZERO HOP.** Without that compaction it sends a USDC venue — which
    ///      legitimately has `hubDex == 0` — onto the two-hop path with a ZERO first pool word, and
    ///      **17 tests fail with `NoVolatileRoute()`**. ⚠️ The compiler cannot see this; only running
    ///      the suite did.
    function _stableToWbtc(address stable, uint256 amt, uint256 minOut, address wbtc,
                           bytes memory route) internal returns (uint256) {
        return routedSwap(stable, wbtc, amt, minOut, route);   // §SESS-91 — the route is the whole path
    }

    /// @dev Mirror of `_stableToWbtc`: volatile → USDC through the aggregator, stableswap hub back
    ///      out. `minOut` is applied to the FINAL stable amount, not the USDC intermediate, so the
    ///      floor bounds what the caller actually receives.
    ///      ONE body for BOTH volatiles — the WBTC and WETH down-legs differ only in `vol`, and
    ///      `internal` in a library is copied into every caller, so collapsing two bodies to one
    ///      multiplies by the caller count.
    /// @dev ⚠️ NO ROUTE **AND** NO POOL WORD ⇒ `_aggSwap` REVERTS `NoVolatileRoute()`. That is
    ///      deliberate: a caller that names neither venue CANNOT trade, and the revert is the honest
    ///      surface — a silent 0 would reappear as a slippage failure frames away.
    /// 🔴 SAME CROSSED ORDER as `_stableToWbtc`, and MIRRORED because this leg runs the other way:
    ///    here the VOLATILE pool is hop 1 and the hub hop is hop 2.
    function _volToStable(address vol, address stable, uint256 amt, uint256 minOut,
                          bytes memory route) internal returns (uint256) {
        // ⭐ THE FLOOR RIDES THE ROUTE ITSELF — ⛔ do not re-express it as an unbounded hop plus an
        //    `if (out < minOut) revert Slippage()` a frame later. Both arms end on the FINAL token
        //    with `minOut` enforced on a measured balance delta: `routedSwap` through `_aggSwap`, and
        //    the table arm through `_hubHop`, which carries the floor into `curveExchange`. Only the
        //    USDC intermediate is deliberately unbounded, because nothing leaves on it.
        return routedSwap(vol, stable, amt, minOut, route);    // §SESS-91 — the route is the whole path
    }

    /// @dev IDENTITY WHEN THE LOAN TOKEN IS ALREADY WETH — the close-side twin of the note on
    ///      `_stableToWethSor`. `minOut` is unused on that branch because no trade occurs.
    function _wethToStableDex(SellCtx memory c, address stable, uint256 wethIn, uint256 minOut) internal returns (uint256) {
        if (stable == c.weth) return wethIn;              // loan token IS WETH — nothing to convert
        // 🔴 §MINOUT-DROPPED — ⛔ **DO NOT ADD A `route.length != 0` FAST PATH BESIDE THIS CALL.** The
        //   two arms are the same operation, and hand-inlining the routed one is how `minOut` came to
        //   be accepted as a parameter and silently discarded on the leg that actually ran. ONE call:
        //   `_volToStable` picks the arm and carries the bound onto the final token either way.
        return _volToStable(c.weth, stable, wethIn, minOut, c.route);   // one routed call, floor on the final token
    }

    /// @dev The anti-MEV floor for the **WETH → stable** leg, priced off the WETH being sold.
    ///      §SLIP-BUDGET — was `_stableFloor(c, stable, weethAmt)`, which took the weETH and ran it
    ///      through `getEETHByWeETH` first. That made it the floor for a leg it does not guard: the
    ///      weETH→WETH conversion is leg 1 and carries its own bound. Taking WETH directly is both
    ///      the correct quantity and one external call cheaper.
    function _wethStableFloor(SellCtx memory c, address stable, uint256 wethAmt) internal view returns (uint256) {
        uint256 usd18 = (wethAmt * IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M)) / 1e18;
        // §SIZE-AWARE-SLIP — the CLOSE-side sibling of `_stableToWethSor`'s floor. Tightening one and
        // not the other would have left the de-lever leg on the flat 100 bps while the open leg used
        // the curve: the same round trip bounded two different ways.
        return swapFloor(c.aux, c.weth, wethAmt, stable, _slipBps(usd18));   // §SESS-44 — ONE formula
    }

    /// The WETH that must remain to repay `assets` (flashed stable) at worst-case slippage — above it is skimmable headroom.
    function _wethForAssets(SellCtx memory c, address stable, uint256 assets) internal view returns (uint256) {
        uint256 usd18 = _toUsd18(c.aux, stable, assets);
        uint256 weth = (usd18 * 1e18) / IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M);
        // 🔴 MUST USE THE SAME ALLOWANCE AS `_wethStableFloor`, AND THIS IS THE INVERSE OF IT. That
        //    floor says how little stable a sale may yield; this says how much WETH must be RETAINED
        //    to repay `assets` at the same worst case. If they disagree the round trip is asymmetric —
        //    a tighter floor with a stale gross-up under-retains and the repay comes up short.
        return (weth * 10_000) / (10_000 - _slipBps(usd18));
    }

    /// @notice Self-funding keeper-gas — external entry for the manager's direct reimburse points (the de-lever
    ///         settle's freed WETH, protect). Delegatecall ⇒ WETH unwrapped + ETH sent are the MANAGER's. See
    ///         `_reimburse`.
    function reimburseKeeper(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        public returns (uint256 skimmed, uint256 reserveOut)
    {
        return _reimburse(weth, keeper, availWeth, reserveIn);
    }

    /// The manager's runtime addresses + gas-reserve, threaded into `extractToVaultBody` (delegatecall) and
    /// returned updated. `maxSlippageBps` grosses the collateral withdraw so the sale covers the flash even at
    /// worst execution. Collateral units are always weETH-rate: raw WETH collateral is dominated and gone.
    /// §C2.1 — `route` is the keeper-built 1inch calldata, threaded from the flash `data` down to
    /// `_wethToStableDex`. EMPTY means none was supplied and the leg executes the keeper's POOL WORDS
    /// (`dex`/`dex2`) instead, against the same floor.
    /// @dev §SESS-19 — **`route` JOINS `dex`/`dex2` HERE, WHICH MAKES THIS STRUCT MATCH THE OTHER TWO.**
    ///      `SellCtx` (`:537`) and `WbtcCfg` (`:317`) already carry all THREE together; `ExtractCfg`
    ///      carried only the two pool words, and that omission is what forced `_sellAndPay` and
    ///      `collToWethDeliver` to build their `SellCtx` with `route: ""` — **the identical literal
    ///      §E357 named as the BUY side's whole defect** (*"that one literal is where every empty route
    ///      on the BUY side came from"*). Same bug class, same file, on the mirror leg.
    struct ExtractCfg { address weth; address weeth; address aux; address flashProvider; address keeper; uint256 gasReserve; uint16 maxSlippageBps; uint256 dex; uint256 dex2; bytes route; }

    /// @dev Repay-first + withdraw the paired collateral, in its OWN frame so both callers' stacks stay shallow
    ///      (no via_ir). Flashed `assets` → venue → repay; then withdraw collateral worth (repaid + `extractUsd`)
    ///      of ETH at `pxWeth`, grossed by max slippage so the sale covers the flash at worst execution. WETH
    ///      venue = 1:1 ETH; weETH venue = via the ether.fi rate.
    ///      ONE body for BOTH callers — the §G.3 extraction (via `_pullForExtract`) and the mode-0 settle
    ///      (`deleverSettleBody`, direct). They differ in exactly ONE scalar, the extra `extractUsd` of value
    ///      to free beyond what was repaid, which the settle path passes as 0 — plus WHERE `pxWeth` comes
    ///      from: `_pullForExtract` resolves a live TWAP, `deleverSettleBody` passes the caller's
    ///      already-resolved price.
    ///      ⚠️ THE `NoPrice` GUARD BELONGS HERE, NOT ON ONE CALLER, AND A ZERO PRICE MUST NEVER PANIC.
    ///      `Aux.getTWAPforAsset` deliberately NEVER reverts — that is what makes #101's degrade-to-
    ///      partial-fill work — so an unset or stale Chainlink anchor propagates `pxWeth == 0` straight
    ///      into this divisor. MEASURED: `testReal_Morpho_OpenAndDelever` and `testReal_Euler_OpenAndDelever`
    ///      both died on `panic: division or modulo by zero (0x12)` here, via `twapResolve(feed=0x0,
    ///      price=0)`. A panic burns all gas and is undiagnosable; a named revert is the correct failure
    ///      for an operation that genuinely cannot be sized without a price.
    ///      ⛔ `extractToVaultBody` REACHES THIS THROUGH `_pullForExtract`, WHICH EXISTS PURELY FOR THE
    ///      NON-via_ir STACK AND MUST NOT BE INLINED AWAY. That caller carries 8 params + 2 named returns, and
    ///      its own `_sellAndPay` call already peaks at the legacy DUP limit — a SEVENTH argument evaluated in
    ///      that frame (worse, one whose value is a nested external call) is where stack-too-deep starts.
    ///      `deleverSettleBody` is 7 params + 1 return, so it calls this directly and has room to.
    function _repayAndPull(uint256 assets, address lp, address venueAddr, address stable, uint256 extractUsd, uint256 pxWeth, ExtractCfg memory cfg)
        private returns (uint256 pulled)
    {
        IERC20OZ(stable).safeTransfer(venueAddr, assets);
        uint256 repaid = ILevVenue(venueAddr).repay(lp, assets);       // == assets when capped ≤ debt upstream
        if (pxWeth == 0) revert NoPrice();
        uint256 ethAmt = ((_toUsd18(cfg.aux,stable, repaid) + extractUsd) * 1e18) / pxWeth;
        uint256 collUnits = (ethAmt * 1e18) / IWeETH(cfg.weeth).getEETHByWeETH(1e18);
        pulled = ILevVenue(venueAddr).withdraw(lp, (collUnits * 10_000) / (10_000 - cfg.maxSlippageBps));
    }

    /// @dev The §G.3 extraction's shim onto `_repayAndPull`: resolves the live WETH TWAP HERE, in a shallow
    ///      frame, so `extractToVaultBody` keeps making the same 6-argument call it always did. See the stack
    ///      note on `_repayAndPull` — this wrapper is load-bearing for the legacy codegen, not decoration.
    function _pullForExtract(uint256 assets, address lp, address venueAddr, address stable, uint256 extractUsd, ExtractCfg memory cfg)
        private returns (uint256 pulled)
    {
        return _repayAndPull(assets, lp, venueAddr, stable, extractUsd,
            IAux(cfg.aux).getTWAPforAsset(cfg.weth, TWAP_WIN_M), cfg);
    }

    /// @notice REDEEM/SWAP-OUT value-neutral partial de-lever (§G.3, the ETH analog of BTC `deleverOnDelivery`/#54),
    ///         delegatecall-linked (bytecode OUTSIDE the EIP-170-critical manager, runs in the manager's context).
    ///         Flashed `assets` in hand: REPAY the LP's debt FIRST, withdraw the paired collateral, sell it, return
    ///         `assets` to the flash, and route the value-neutral SURPLUS to `vault` (the redeem sink) — NOT the LP
    ///         (unlike `closeLev`). `assets = X·debt/netEq` so LTV is PRESERVED; `sellColl`'s oracle floor reverts
    ///         unless the sale covers the flash, so an underwater position can never settle unbacked.
    /// @return newGasReserve gas-reserve after the keeper peel.
    /// @return freed stable routed to `vault` (≈ extractUsd, less slippage).
    function extractToVaultBody(uint256 assets, address lp, address venueAddr, address stable, uint256 extractUsd, address vault, uint256 minOut, ExtractCfg memory cfg)
        public returns (uint256 newGasReserve, uint256 freed)
    {
        uint256 pulled = _pullForExtract(assets, lp, venueAddr, stable, extractUsd, cfg);   // repay-first + withdraw (own frame)
        // Sell + return-flash + route-surplus in its OWN frame (non-via_ir stack: keeps `lp`/`venueAddr`/`extractUsd`
        // — dead after the pull — from co-living with the sellColl call args).
        return _sellAndPay(pulled, stable, minOut, assets, vault, cfg);
    }

    /// @dev Sell the withdrawn/freed collateral (oracle-floored on `assets`: reverts unless stableOut ≥ assets ⇒ the
    ///      flash is always repayable), return `assets` to the flash provider (zero-fee pull-back), hand the
    ///      value-neutral surplus to `recipient`. ONE body for both sinks — `extractToVaultBody` passes the
    ///      redeem sink `vault`, `deleverSettleBody` passes `lp`; `recipient` is the ONLY difference, and
    ///      `stableOut > assets ? stableOut - assets : 0` covers the zero-surplus case without a branch.
    ///      Own frame purely for the non-via_ir stack budget of the two callers.
    function _sellAndPay(uint256 pulled, address stable, uint256 minOut, uint256 assets, address recipient, ExtractCfg memory cfg)
        private returns (uint256 newGasReserve, uint256 freed)
    {
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2, route: cfg.route});
        uint256 stableOut;
        (stableOut, newGasReserve) = sellColl(sc, stable, pulled, minOut, assets);
        IERC20OZ(stable).forceApprove(cfg.flashProvider, assets);
        freed = stableOut > assets ? stableOut - assets : 0;
        if (freed > 0) IERC20OZ(stable).safeTransfer(recipient, freed);
    }

    /// @notice §M.1 — convert `collAmt` of freed leverage collateral to WETH and deliver it to `recipient` (the ETH
    ///         swap-out). Collateral is always weETH, so there is no venue branch: it goes through the
    ///         ether.fi Curve offramp (`_weethToWeth`, shared with `sellWeeth`). Bytecode lives HERE
    ///         (delegatecall-linked, address(this)==manager) so the manager stays
    ///         under EIP-170. `minOut` floors the delivered WETH against MEV on the internal conversion. NO
    ///         flash / NO stable-sale — the debt was already repaid by the swap's own proceeds; this only turns the
    ///         value-neutrally-freed collateral into deliverable ETH (equity untouched).
    function collToWethDeliver(uint256 collAmt, address recipient, uint256 minOut, ExtractCfg memory cfg)
        public returns (uint256 wethDelivered) {
        if (collAmt == 0) return 0;
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2, route: cfg.route});
        wethDelivered = _weethToWeth(sc, collAmt);
        require(wethDelivered >= minOut, "swapDelever:minOut");
        if (wethDelivered > 0) IERC20Min(cfg.weth).transfer(recipient, wethDelivered);
    }

    /// Pay `keeper` its gas as native ETH: skim from `availWeth` (freed WETH headroom) first, shortfall from
    /// `reserveIn`; skim an extra 1× into the reserve when the headroom covers 2× the gas. Bounded by the reserve —
    /// NEVER reverts (a safety unwind must complete). `keeper==0` ⇒ no-op. Returns (WETH skimmed, new reserve).
    function _reimburse(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        internal returns (uint256 skimmed, uint256 reserveOut)
    {
        reserveOut = reserveIn;
        if (keeper == address(0)) return (0, reserveOut);
        uint256 gp = tx.gasprice < KEEPER_MAX_GASPRICE ? tx.gasprice : KEEPER_MAX_GASPRICE;
        uint256 owed = gp * DELEVER_GAS;
        if (owed == 0) return (0, reserveOut);
        uint256 want = availWeth >= 2 * owed ? 2 * owed : owed;   // top the reserve only when headroom is ample
        skimmed = availWeth < want ? availWeth : want;
        uint256 keeperCut = skimmed < owed ? skimmed : owed;      // keeper's share of the skim (≤ owed)
        reserveOut += skimmed - keeperCut;                        // surplus 1× stays as WETH → reserve
        uint256 shortfall = owed - keeperCut;                     // still owed after the skim
        if (shortfall > reserveOut) shortfall = reserveOut;       // reserve is the bound — safety unwind never blocked
        reserveOut -= shortfall;
        uint256 pay = keeperCut + shortfall;
        if (pay > 0) {
            IWETH9(weth).withdraw(pay);                           // WETH → native ETH (manager's context)
            (bool ok, ) = payable(keeper).call{ value: pay }("");
            require(ok, "keeper gas send");
        }
    }

    /// @notice Delegated QU!D-protect mechanics (runs in the MANAGER's context via delegatecall, so `address(this)`
    ///         is the manager). Gates on `lp` being within PROTECT_MARGIN of the venue liquidation LTV, then
    ///         redeems the LP's OWN opted-in QUID to repay the LP's OWN debt on `venue`; moves NO value to anyone
    ///         but `lp` (debt repaid + any excess refunded to `lp`). The pull is DERIVED from the debt (capped by
    ///         the LP's allowance/balance), so a hostile caller can neither over-redeem nor skim.
    /// @return pull   QUID actually redeemed. @return repaid stable applied to `lp`'s debt.
    function protectExec(address quid, address aux, address venue, address lp, uint256 curLtvBps, uint256 minStableOut)
        public returns (uint256 pull, uint256 repaid)
    {
        if (curLtvBps + PROTECT_MARGIN_BPS < ILevVenue(venue).liqThresholdBps()) revert NotNearLiq();
        uint256 debt = ILevVenue(venue).debtOf(lp);
        if (debt == 0) revert NoDebt();
        address stable = ILevVenue(venue).stable();
        {
            uint8 dec = IERC20Min(stable).decimals();
            pull = dec >= 18 ? debt : debt * (10 ** (18 - dec)); // debt (stable units) → QUID (18-dec, ~1:1 USD)
            uint256 lim = IERC20Min(quid).allowance(lp, address(this));
            if (pull > lim) pull = lim;                          // the opt-in allowance is the LP's own ceiling
            lim = IERC20Min(quid).balanceOf(lp);
            if (pull > lim) pull = lim;
        }
        if (pull == 0) revert NoOptIn();
        uint256 got = IERC20Min(stable).balanceOf(address(this));
        IERC20Min(quid).transferFrom(lp, address(this), pull);     // pull the LP's opted-in QUID
        // PRO-RATA redeem — `redeem(uint)` takes no target, so this gets the LP's FAIR slice of every basket
        // stable and can never force-drain the basket of one (a targeted draw over-commits under leverage).
        // `_consolidateTo` then moves that mix into the venue's own loan token.
        IAux(aux).redeem(pull);                           // burn THIS manager's QUID → a mix of stables here
        _consolidateTo(aux, stable, lp);
        got = IERC20Min(stable).balanceOf(address(this)) - got;    // venue-stable gained (direct slice + swaps)
        if (got < minStableOut) revert Slippage();
        // Clamp to the debt BEFORE transferring in; debt only accrues upward in-tx, so `repay`'s own clamp uses
        // all of `pay` — nothing strands in the venue.
        uint256 pay = got > debt ? debt : got;
        IERC20OZ(stable).safeTransfer(venue, pay);                    // venue.repay expects it already transferred in
        repaid = ILevVenue(venue).repay(lp, pay);                // manager is the venue's authorized MANAGER
        if (got > pay) IERC20OZ(stable).safeTransfer(lp, got - pay);  // refund the un-needed portion to the LP
    }

    /// @dev Consolidate every OTHER basket stable this manager holds into `target` (the venue's loan token, whatever
    ///      stable it lends) so the protect never depends on the basket holding a specific stable. ONE ROUTE PER
    ///      SLICE: `stable → USDC → target`, both hops on the `_hubRowOf` Curve rows (`_hubHop`). A slice whose
    ///      stable — or whose `target` — is not on that table is NOT swapped at all; it is refunded to the LP below.
    ///      Each pair carries its own `swapFloor`, enforced on the SECOND hop; the caller's aggregate
    ///      `minStableOut` is the outer bound, so a slice that cannot move only lowers `got` and trips that floor
    ///      (fail-safe, never a silent shortfall).
    /// ⭐ §SESS-70 — **TIGHTENED 100 → 20 bps, AND THE JUSTIFICATION IS THIS TREE'S OWN MEASUREMENT.**
    ///
    /// 🔑 **THIS CONSTANT ONLY EVER APPLIES TO THE SIX `_hubRowOf` ROWS** — `_consolidateTo` asks
    ///    `_routableStable` first and REFUNDS anything not on the table, so no unmeasured stable can
    ///    reach it. And `Interfaces.sol:244` records what those rows cost, measured at three sizes:
    ///    **USDT 4/4/4 · DAI 1/1/1 · USDG −1/−1/−1 · crvUSD 0/0/0 bps, FLAT to $1M.**
    ///    ⇒ **100 bps was 25x the worst case on a path that cannot reach an unmeasured venue.**
    /// 🔴 **AND THE SLACK IS NOT A SAFETY MARGIN, IT IS THE ENTIRE EXPOSURE — TWICE OVER.** §SESS-69:
    ///    a hacked keeper's maximum take is exactly the gap between the reference and the floor, because
    ///    every other lever (token, amount, receiver, callee, allowance, gas) is overwritten or pinned.
    ///    §SESS-68: a sandwicher's maximum take is the same gap. **One number, two threats.** A wide
    ///    floor does not buy safety here; it *is* the loss budget.
    /// ⚠️ **20 AND NOT 4: five times the worst measured cost.** The residual headroom covers the
    ///    quote-vs-execute drift a pre-trade reference cannot see — most concretely, a slice whose two
    ///    hops share ONE pool (`s → USDC → target` both on 3pool) moves that pool between them, which
    ///    `_selfServableQuote` prices on the pre-trade state. ⛔ Going to the measured 4 would make the
    ///    floor unmeetable by its own execution, which is §SESS-41's liveness defect re-created on
    ///    purpose — *"a path that reverts is worse than one that leaks."*
    /// 📌 Deliberately still FLAT rather than size-aware: the four measurements are flat to $1M, so a
    ///    size curve would model a cost this path does not have (§SESS-41 measured the size-aware curve
    ///    as sometimes UNMEETABLE). **Size-awareness belongs where impact grows, and here it does not.**
    uint256 internal constant CONSOL_SLIP_BPS = 20;

    function _consolidateTo(address aux, address target, address lp) private {
        address[] memory sts = IAux(aux).getStables();
        for (uint256 i; i < sts.length; i++) {
            address s = sts[i];
            if (s == target) continue;
            uint256 bal = IERC20Min(s).balanceOf(address(this));
            if (bal == 0) continue;
            // Anti-MEV floor: stables are ~1:1, so expect ~the same USD out of the swap; allow CONSOL_SLIP_BPS for
            // pool fee + impact. A stable depegged below the floor cannot clear the hop pair ⇒ it refunds to the LP
            // (below) rather than swapping at a loss — fail-safe, and the same oracle-derived `swapFloor`
            // the rebalance legs apply.
            // §SESS-44 — ONE formula. ⚠️ **BUDGET DELIBERATELY UNCHANGED** (flat `CONSOL_SLIP_BPS`,
            // not `_slipBps`): swapping it here would tighten every consolidation swap at once, and
            // §SESS-41 measured the size-aware curve as sometimes UNMEETABLE. The formula is deduped;
            // the three budgets stay as they were and are now visible side by side.
            // ⭐ §SESS-70 — **THE REFERENCE IS THE BETTER OF THE ORACLE AND WHAT WE COULD GET
            //    OURSELVES.** `_selfServableQuote` walks the same `_hubRowOf` rows `_hubHop` executes,
            //    through live `get_dy` at the size actually being traded — no tolerance, no curve, no
            //    tuned number in it. Taking the MAX states the anti-abuse rule directly: **you may not
            //    do worse than we could do without you.**
            // ⚠️ `max` is the manipulation-safe direction, and the asymmetry is the point: a reference
            //    pushed DOWN falls back to the oracle and changes nothing; one pushed UP costs a FILL
            //    (liveness), never custody. So the arm an attacker can move is the harmless one.
            // ⛔ It binds only where it EXCEEDS par — which is exactly the stables the table measured
            //    at a NEGATIVE cost (USDG −1 bps). For the rest the oracle arm is already tighter, so
            //    this is a floor that ratchets up and never down.
            uint256 floor = swapFloor(aux, s, bal, target, CONSOL_SLIP_BPS);
            {
                uint256 q = _selfServableQuote(s, bal, target);
                if (q != 0) {
                    q = (q * (10_000 - CONSOL_SLIP_BPS)) / 10_000;   // ONE budget, both arms
                    if (q > floor) floor = q;
                }
            }
            // ROUTABILITY IS CHECKED, NOT CAUGHT. A library cannot `try this.…` — in a delegatecalled
            // library `this` is the CALLER — and the condition the old try/catch actually guarded was
            // "this stable has no route", which is now a pure predicate. An unroutable slice is skipped
            // and refunded to the LP below, exactly as before.
            // ⚠️ BEHAVIOUR NARROWED, DELIBERATELY: a REVERT INSIDE CURVE (pool paused, depeg past the
            //    floor) now propagates instead of being swallowed per-slice. That is the safer
            //    direction here — a per-slice catch could silently leave a consolidation half-done, and the
            //    floor already refuses a bad price rather than trading at a loss.
            // ⛔ §SESS-51 — **DO NOT THREAD CALLER-SUPPLIED HOP WORDS IN THROUGH `protectFromQuid`.**
            //    That entrypoint is PERMISSIONLESS, so caller-supplied pools would hand an arbitrary
            //    address the SELECTION of every venue against a flat 100 bps `CONSOL_SLIP_BPS` — the
            //    floor bounds the loss, never the selection, and selection is the takeable part. It
            //    would also widen `LevManager`, which has **133 bytes** left.
            //    ⇒ the pools come from `_hubRowOf`, which no caller can influence.
            if (_routableStable(s) && _routableStable(target)) {
                // `floor` is enforced on the SECOND hop, so it bounds the pair on the measured delta.
                _hubHop(target, _hubHop(s, bal, true, 0), false, floor);
            }
            // Whatever of this slice did not move — an unroutable stable, or a remainder — goes back to the LP.
            // Never strand the LP's own redeemed value in the manager (it only lowers `got`, which the
            // aggregate floor already guards).
            uint256 rem = IERC20Min(s).balanceOf(address(this));
            if (rem > 0) IERC20OZ(s).safeTransfer(lp, rem);
        }
    }

    /// @notice Debt delta (USD 1e18) + direction to re-hit `targetBps` LTV, given the position's
    ///         collateral value (`collUsd`) and current debt (`curDebtUsd`). Inside `±rangeBps` of
    ///         target ⇒ `(false, 0)`. `LevBase.debtDeltaToTarget` is the caller and supplies the four inputs.
    function debtDelta(uint256 collUsd, uint256 curDebtUsd, uint256 targetBps, uint256 rangeBps)
        internal pure returns (bool levUp, uint256 amountUsd)
    {
        uint256 cur = ltvBps(curDebtUsd, collUsd);
        if (cur + rangeBps >= targetBps && cur <= targetBps + rangeBps) return (false, 0); // in range
        uint256 targetDebt = (collUsd * targetBps) / 10_000;
        if (targetDebt > curDebtUsd) { levUp = true;  amountUsd = targetDebt - curDebtUsd; }
        else                         { levUp = false; amountUsd = curDebtUsd - targetDebt; }
    }

    // ═══════════════════════ ETH SWAP-OUT / DE-LEVER SETTLE BODIES (delegatecall — EIP-170) ═══════════════════════
    // Moved out of LevManager (bytecode OUTSIDE the manager) so it fits EIP-170. Each runs in the MANAGER's context
    // (address(this)==manager); the manager's runtime addresses + gas-reserve arrive via `ExtractCfg` (reused), and
    // any flashLoan invoked here re-enters the manager's own `onMorphoFlashLoan` (address(this) is preserved).

    /// @notice §M.1 UNLEVERED (0-debt) net-equity delivery body — withdraw up to `wethWanted`-worth of the LP's
    ///         net-equity collateral (== collateral, no debt) and deliver it as WETH. The body of
    ///         `LevManager.swapOutDeliverUnlevered`, delegatecall-linked; `cfg.weeth` doubles as the weETH
    ///         rate source.
    function swapOutDeliverUnleveredBody(ILevVenue venue, address lp, uint256 wethWanted, address recipient, uint256 minWethOut, ExtractCfg memory cfg)
        public returns (uint256 wethDelivered) {
        uint256 coll = venue.collateralOf(lp);
        uint256 collInEth = IWeETH(cfg.weeth).getEETHByWeETH(coll); // net-equity == collateral (0 debt)
        if (collInEth == 0) return 0;
        uint256 pull = wethWanted >= collInEth ? coll : (coll * wethWanted) / collInEth;
        if (pull == 0) return 0;
        uint256 got = venue.withdraw(lp, pull);                                    // net-equity collateral → the manager
        uint256 floor = minWethOut;
        { uint256 pullEth = (collInEth * got) / coll;                              // ETH value of the withdrawn collateral
          uint256 f = (pullEth * (10_000 - cfg.maxSlippageBps)) / 10_000; if (f > floor) floor = f; }  // MEV floor
        wethDelivered = collToWethDeliver(got, recipient, floor, cfg);
    }


    /// @notice §G.3 size the debt-stable to flash-repay for extracting `extractUsd` of value: ΔD = X·debt/netEq,
    ///         clamped to live debt. `debtUsd18` = the LP's live debt (USD 1e18, decimal-normalized by the manager);
    ///         `pxWeth` = USD/WETH TWAP. The net-equity computation and the repay sizing are ONE body here;
    ///         `LevManager:619` is the caller.
    function sizeRepayStable(ILevVenue venue, address lp, uint256 extractUsd, uint256 debtUsd18, uint256 pxWeth, address weeth, address aux)
        public view returns (uint256 repayStable) {
        uint256 rawColl = venue.collateralOf(lp);
        uint256 collUsd = (IWeETH(weeth).getEETHByWeETH(rawColl) * pxWeth) / 1e18;
        uint256 netEq = collUsd > debtUsd18 ? collUsd - debtUsd18 : 0;
        if (netEq == 0) return 0;
        repayStable = _fromUsd(aux,venue.stable(), (extractUsd * debtUsd18) / netEq);
        uint256 debt = venue.debtOf(lp);
        if (repayStable > debt) repayStable = debt;
    }

    /// @notice mode-0 (generic flash-stable) settle body: repay-first → withdraw the freed collateral (grossed up by
    ///         the max-slippage buffer) → sell → return the flash + surplus to the LP. Repay-and-pull and
    ///         sell-and-pay are the two shared frames (`_repayAndPull`, `_sellAndPay`), so this body is the
    ///         mode-0 wiring and nothing else. `pxWeth` = USD/WETH TWAP. @return newGasReserve gas-reserve
    ///         after the keeper peel (the thin forwarder writes it back).
    /// @dev §SESS-19 — **THE MODE-0 PAYLOAD IS DECODED HERE, NOT IN THE MANAGER.** It used to be
    ///      decoded in `LevManager._deleverSettle`, and widening it from one pool word to
    ///      `(dex, dex2, route)` pushed `LevManager` **93 bytes OVER EIP-170** — measured, not feared.
    ///      This library is `delegatecall`'d, so its bytecode does not count against the manager: the
    ///      tree's own remedy (*"body in LevMath (EIP-170)"*) applied to the decode as well as the body.
    ///      ⭐ It is also the better shape independently — the struct is populated in ONE place, beside
    ///      the encoder that wrote the payload, so the two cannot drift in field order.
    function deleverSettleBody(uint256 assets, address lp, address venueAddr, address stable, uint256 minOut, uint256 pxWeth, ExtractCfg memory cfg, bytes calldata data)
        public returns (uint256 newGasReserve) {
        (,,,,, cfg.dex, cfg.dex2, cfg.route) =
            abi.decode(data, (uint8, address, address, address, uint256, uint256, uint256, bytes));
        uint256 pulled = _repayAndPull(assets, lp, venueAddr, stable, 0, pxWeth, cfg);   // repay-first + withdraw (own frame)
        (newGasReserve, ) = _sellAndPay(pulled, stable, minOut, assets, lp, cfg);   // sell + return-flash + surplus→LP (own frame)
    }

    /// @notice De-lever `lp` by flashing `repayUsd`-worth of the debt stable (repay-first, mode-0). Reuses
    ///         `ExtractCfg` (weth/aux/flashProvider).
    /// @dev    §E304-mintclose: mode 0 is the ONLY mode, and ⛔ do not re-introduce a mint-close fork beside
    ///         it. Morpho does not mint — you borrow what exists — and no venue can, because `ILevVenue` is
    ///         denominated in weETH collateral. The `uint8(0)` in the payload is a literal for that reason,
    ///         not a placeholder awaiting a second value.
    /// @dev §SESS-19 — `dex2` and `route` ride the SAME payload the other five fields do. The close leg
    ///      could reach only the single-hop `unoswap` before this: `_delever` took all three and handed
    ///      on `dex` alone, and even had it not, the payload had nowhere to put them.
    function deleverFlashBody(ExtractCfg memory cfg, ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route)
        public {
        if (repayUsd == 0 || cfg.flashProvider == address(0)) return;
        uint256 debt = venue.debtOf(lp);
        if (debt == 0) return;
        uint256 repayStable = _fromUsd(cfg.aux,stable, repayUsd);
        if (repayStable > debt) repayStable = debt;                              // never flash more than we can repay
        if (repayStable == 0) return;
        // mode 0 = the generic flash-the-stable → repay → withdraw → sell → return path.
        IMorphoFlash(cfg.flashProvider).flashLoan(stable, repayStable, abi.encode(uint8(0), lp, address(venue), stable, minOut, dex, dex2, route));
    }

    /// USD(1e18) <-> `stable` native units (decimals). Canonical here so both managers can dedup onto them.
    /// @notice USD(1e18) -> native token units, at `pxUsd18` = the USD price of ONE WHOLE token,
    ///         1e18-scaled. `tokens = usd * 10^dec / px`.
    ///
    ///         ⚠️ THE PRICE PARAMETER IS THE POINT. These two used to do a DECIMALS SHIFT ONLY, which
    ///         silently assumes ONE TOKEN = ONE DOLLAR. True of every basket stable; catastrophically
    ///         false of WETH, which has 18 decimals — a plain decimals shift would return `usd`
    ///         UNCHANGED, reading $4,000 of debt as 4,000 WETH, and this result feeds `venue.borrow`
    ///         directly in `leverUpBuyWbtc`. Every shape and decimal typechecks, so the error is SILENT.
    ///         This matters because the WETH-LOAN MARKET is the next step: it removes both
    ///         stable<->WETH SOR legs from every lever open and close, and lets the WETH supply
    ///         venues go. It cannot land while these assume a dollar peg.
    ///
    ///         The price comes from `loanPxUsd18(aux, loan)` — the ONE decision point, resolved inside this
    ///         body so no call site can pass the wrong one. `loanPxUsd18` returns par for a dollar stable and
    ///         the pinned feed's TWAP for anything else, so admitting a real loan token is a feed registration,
    ///         not an edit here.
    /// @dev Takes `aux`, NOT a price. The price is resolved HERE, once, by `loanPxUsd18`. Composing it at the
    ///      call site (`_fromUsd(aux,t, u)`) was tried and is UNBUILDABLE: the extra nested
    ///      frame blew the stack on the de-lever sell path with `via_ir` off by choice. Resolving inside is also the
    ///      better shape — one decision point, and no call site can pass the wrong price.
    function _fromUsd(address aux, address stable, uint256 usd) internal view returns (uint256) {
        uint256 pxUsd18 = loanPxUsd18(aux, stable);
        uint8 dec = IERC20Min(stable).decimals();
        // Plain arithmetic: `usd` is 1e18-scaled USD and `10**dec` <= 1e18, so the product peaks
        // around 1e42 against a ~1.15e77 ceiling. No mulDiv needed and FullMath is not imported here.
        return (usd * (10 ** dec)) / pxUsd18;
    }
    /// @notice Native token units -> USD(1e18), the inverse of `_fromUsd`. `usd = amt * px / 10^dec`.
    ///         Same price contract and same reasoning — see `_fromUsd` above.
    function _toUsd18(address aux, address stable, uint256 amt) internal view returns (uint256) {
        uint256 pxUsd18 = loanPxUsd18(aux, stable);
        uint8 dec = IERC20Min(stable).decimals();
        return (amt * pxUsd18) / (10 ** dec);
    }
}
