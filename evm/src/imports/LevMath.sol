// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WAD, VenueNotAllowed} from "./Types.sol";
// §A.52: the canonical view (was a file-local `IRangeM`).
import { ICore, IAux, IWeETH, IDepositAdapter, ILevVenue } from "./Interfaces.sol";
import {ILevVenue, IERC20Min, IWETH9} from "../imports/Interfaces.sol";
import {DEFAULT_UNWIND_DEX, ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, PROTO_UNIV3, ZERO_FOR_ONE, IUniV3PoolMin, ICurvePool, CURVE_USDC_RLUSD, CRV_RLUSD_IDX, CRV_RLUSD_USDC_IDX, CURVE_PYUSD_USDC, CRV_PYUSD_IDX, CRV_PYUSD_USDC_IDX, USDC, RLUSD_TOKEN, PYUSD_TOKEN} from "./Interfaces.sol";

// ether.fi weETH/WETH Curve pool (weETH is coin1, WETH coin0). Same address as Vault.ETHERFI_CURVE_POOL.
address constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
import {IMorphoBase as IMorphoFlash} from "../imports/Interfaces.sol";
/// @dev Token/SOR surfaces the leg mechanics touch. IERC20Min + IWETH9 come from ILevVenue (shared).
/// ONE Aux surface for everything LevMath touches on it (redeem / stables / TWAP / SOR both directions / venue /
/// health) — was five tiny IAux* slices (consolidation).
// ETH-side sell/buy machinery surfaces — moved here (delegatecall, bytecode OUTSIDE LevManager for EIP-170).
/// Morpho Blue zero-fee flash surface — the ONLY flash source (see LevManager.IMorphoFlash). Mirrored here so the
/// moved de-lever bodies (`deleverFlashBody`) can invoke it from the manager's delegatecall context.
/// The range sync-range surface the sold-fraction target + reseat reads. Mirrors the managers'
/// ICore/IRangeB — a delegatecall'd library can't read their immutables, so the manager passes the
/// range address in. All view: the Quid impls are all view (soldFractionWad/rangePrice are
/// `view` fns, reseatEpoch is a `public` state var), and `view` external calls are STATICCALL-safe inside the
/// try/catch below (Solidity allows try/catch on view calls) and callable from both view and non-view callers.

/// @title  LevMath — asset-agnostic IL-protect leverage economics + up-side leg mechanics
/// @notice ONE leverage library shared by the ETH (`LevManager`, weETH) and BTC (`BtcLevManager`, vBTC) paths.
///         Holds the up-side IL-protect economics + money-movement bodies: the IL-cancelling target
///         (`1 − √(entry/now)`), net-equity, debt-delta, and the lever-up/de-lever/flash-close leg mechanics, all
///         `public` (delegatecall-linked, bytecode OUTSIDE the manager) so the managers fit EIP-170. Only the
///         *acquisition/exit rails* differ between assets — the economics don't — so both managers reuse this. Leg
///         funcs run in the MANAGER's context (`address(this)`==manager); immutables the manager owns (AUX/volatile)
///         come in via the cfg structs. Routing is SPLIT BY LEG TYPE and no longer "all Curve":
///         the STABLE hops (stable↔USDC) are Curve stableswap, and every VOLATILE hop
///         (USDC↔WETH, USDC↔WBTC) is a pinned Uniswap V3 pool via `_poolSwap` (§V-R1-MIN).
///         The USDC<->volatile Curve leg is GONE from this file — only weETH→WETH (`ETHERFI_CURVE_POOL`) remains
///         Curve-on-a-volatile-pair, and that is a dedicated LST pool, not a router.
///         (The below-entry SHORT / inverse-venue subsystem was removed — up-side-only is the design.)
library LevMath {
    using SafeERC20 for IERC20OZ;


    /// Zero oracle anchor. A named error, NOT a string require: the string form cost enough
    /// bytecode to push this library 38 bytes past EIP-170 (measured).
    error NoPrice();

    /// @notice The LTV (bps) of `debt` against a position worth `collValue` (same unit); `collValue==0 ⇒ 0`.
    ///         Consolidated in from the former `YBLib` (its only LIVE surface). the leverage's target leverage is L = 2 —
    ///         the IL-vanishing point: a constant-L position has `V* ∝ V_c^L`, a √p range has `V_c ∝ √p`, so
    ///         `V* ∝ p^(L/2)` and L=2 ⇒ `V* ∝ p` (IL cancels), = 2·α⁻¹ (measured α≈0.5). YBLib's `requireSafeDebt`
    ///         + MIN/MAX_SAFE_DEBT envelope were DEAD (no callers) — superseded by the LTV-range rebalance
    ///         (`debtDelta`) + each venue's own LLTV health, so they were dropped, not moved.
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
    /// @dev    §DERIVED-BAND — replaces `LevBase.RANGE_BPS = 300`, whose own docstring said what it
    ///         was supposed to be ("before a rebalance is worth its gas") and then froze it as a
    ///         guess. A guess is not something a lender can rely on, and this one did not merely
    ///         mis-size the band — it disabled the product. `ilTargetBps` is `1 − √(entry/now)`, so
    ///         clearing 300 bps needs `√(entry/now) < 0.97`, i.e. a **6.3% move off entry** before
    ///         the overlay borrows at all. The hedge only armed after the move it exists to protect
    ///         against, and `venue.borrow` was never reached on any realistic path.
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
    ///         USD-per-base (1e18). Identical to `LevManager._ilTargetBps`.
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

    /// @notice The reseat DECISION folded out of both managers' `_reanchorIfReseated`.
    /// @dev  Re-anchor iff the position's `syncKeyPx` now sits OUTSIDE the range's current `[lower, upper]`.
    ///       This REPLACED a `reseatEpoch` counter (removed 2026-08-09) and is strictly MORE PRECISE, not
    ///       merely smaller: the counter fired on EVERY reseat, including ones that left this anchor still
    ///       inside the new range and therefore needed no re-anchor. The bounds fire only when the frame moved
    ///       RELATIVE TO THIS POSITION, and there is no counter to desynchronise.
    /// ⚠️   IT IS A POINT-IN-TIME TEST. It answers "is my anchor stale NOW", NOT "were these two reads taken in
    ///       the SAME frame". §E117 measured a 1h TWAP tick of 200766 sitting neatly inside a post-reseat range
    ///       [200730, 200770) whose window spanned FOUR frame changes — no bounds check can see that. Safe here
    ///       because BOTH live consumers ask the point-in-time question; the windowed consumer (§E93) is
    ///       refuted and blocked. **If anyone builds a WINDOWED reading over the tick series, the epoch must
    ///       come back, and §E117 is the evidence for why.**
    /// @dev  Compared in SQRT space, never by converting `syncKeyPx` to a tick: tick conversion truncates, so
    ///       a position anchored exactly at a boundary would flip on rounding.
    /// @dev Same `active` deletion as `ilTargetLive` — this gate is why re-anchoring NEVER FIRED in
    ///      production, including after the 2026-08-09 bounds-check rewrite.
    /// §MUTABILITY 2026-08-18 — `view`: body reads only, verified it touches none of the
    /// cache-sensitive family (`get_deposits`/`get_metrics`/`refreshHoldings`/`redeemableAmount`).
    function reanchorCompute(address range, uint syncKeyPx)
        public view returns (bool go, uint newPrice) {   // §DE-TICK — was `newSqrtP`; it is assigned from
                                                 // `rangePrice()`, so it always held a PRICE.
        if (range == address(0) || syncKeyPx == 0) return (false, 0);
        try ICore(range).rangePrice() returns (uint v) { newPrice = v; } catch { return (false, 0); }
        if (newPrice == 0) return (false, 0);
        // ONE accessor pair. The range is per-asset and answers for its own range, so there is no name
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

    // §C22 — `ilTargetLive` IS DELETED. Its PRIMARY branch read `ICore(range).soldFractionWad(
    //   syncKeyPx)` and preferred it over the estimate whenever it was non-zero. THAT BRANCH WAS A
    //   CONSTANT, and the proof is two lines of algebra plus a measurement that agrees to nine
    //   significant figures:
    //     `holdingRatioWad` CLAMPS `p0` into the live range, and `RANGE_ANCHOR = spotPrice` is set
    //     unconditionally on every repack, so the range recentres and the triple is always
    //     (lo, P, hi) = (P(1-d), P, P(1+d)). P CANCELS:
    //         holdingRatio = sqrt(1-d) * (sqrt(1+d) - 1) / (sqrt(1+d) - sqrt(1-d))
    //     With RANGE_DELTA = 20 bps that is 0.499250000, i.e. soldFraction = **0.500750000** — a
    //     function of RANGE WIDTH ALONE, with no price in it.
    //   MEASURED over a rally that doubled the price (2716.84 -> 5430.99, ten steps): the range's
    //   real inventory `POOLED` fell 7.566 -> 2.331 ETH while `soldFractionWad` returned
    //   0.500750000312500535 at EVERY step, moving only in the 18th decimal.
    //   => It is not a measure of IL. It reported a 50.075% hedge at open, at +100%, and it would
    //      report the same on the way down. It never fired in production only because the reanchor
    //      kept `syncKeyPx == spot` and `sf` came back 0 — so the estimate ran, correctly, BY
    //      ACCIDENT. Restoring `syncKeyPx` (the natural next step after §C19) would have switched
    //      every position in the book to a constant 50% hedge, capped at `capBps`.
    //   `ilTargetBps` below is now the ONLY target, and it is `public` so the body stays in this
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
    struct WbtcCfg { address aux; address wbtc; uint32 twapWindow; uint16 slipBps; uint256 dex; uint256 dex2; }

    /// @dev §E240-tri — PARAMETER NAMES ARE COMMENTED OUT, NOT REMOVED. The body reverts, so the
    ///      names are unused (solc 5667) -- but they are the restore contract for §V-R1 and deleting
    ///      them would lose the signature's meaning. Commenting is solc's own prescribed remedy.
    /// @notice §V-R1-MIN RESTORED — borrow the venue stable, buy WBTC on the pinned pool, supply it.
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
        wbtcBought = _stableToWbtc(stable, borrowed, minOut, cfg.wbtc, cfg.dex, cfg.dex2);
        IERC20Min(cfg.wbtc).transfer(address(venue), wbtcBought);
        venue.supply(lp, wbtcBought);
    }

    // §E357 — `deleverWbtc` (the DIRECT, non-flash WBTC de-lever) is DELETED. Its only caller was
    // `BtcLevManager._deleverWbtc`, which existed for the `flashProvider == address(0)` branch;
    // `init` now refuses a zero provider, so both went. What it did was withdraw collateral and THEN
    // sell to repay — the withdraw-before-repay ordering the flash path exists to dissolve, and one
    // that under §POOL-VENUE would raise the LTV of a position every LP shares.
    // ⚠️ NOT a rule-1 deletion of something merely unused: the STATE that reached it is now
    // unconstructible, which is what makes deleting it safe rather than merely tidy (rule 17).


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
        uint256 stableOut = _volToStable(cfg.wbtc, stable, pulled, minOut, cfg.dex, cfg.dex2);
        IERC20OZ(stable).forceApprove(flashProvider, assets);   // provider pulls `assets`; a short approve reverts the whole op
        if (stableOut > assets) IERC20OZ(stable).safeTransfer(lp, stableOut - assets);   // realized surplus → LP
    }

    /// @notice Net-equity in BASE-asset units (1e18) = `collBase − debtUsd/price`, floored at 0.
    ///         `collBase` is collateral ALREADY in base units (ETH or BTC); `debtUsd` is 1e18 USD;
    ///         `price` is USD per 1 base (1e18). `debt==0 ⇒ collBase`; `px==0 ⇒ 0` (dead oracle,
    ///         the conservative side — no phantom credit). Identical to `LevManager._netEquityEthAt`
    ///         tail (with `collBase` = weETH→ETH pre-computed by the caller).
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
    ///         exact `min((bufBase·px/1e18)/1e12, debtUsd/1e12)` that BOTH range-reconcile buffer legs applied
    ///         inline (ETH `QuidLib.levAddBuf`, BTC `QuidLib._bufUsdBtc`). Centralized here — like `entryEquityUsd` — so
    ///         the buffer cap + its 6-dec scaling can never drift between the two paths. `bufBase` is ETH-1e18 or
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

    /// @notice Vet + classify a GOV-pinned lev venue. Returns true iff `v` is the SHORT (inverse) venue
    ///         (`stable()==base` -- borrows the volatile against stable collateral, valued via the short leg, so its
    ///         collateral is exempt). Otherwise `v` is a LONG venue whose collateral this manager custodies and
    ///         values, so it MUST be one of the manager-valuable tokens (`c0`/`c1`, e.g. {WETH,weETH} or {vBTC}) --
    ///         anything else would silently misvalue into PHANTOM backing (the exact rug the frozen allowlist
    ///         guards), so revert even for GOV (defense-in-depth against a config mistake).
    /// ⚠️ ORDER CHANGED 2026-08-09 — the collateral check now runs UNCONDITIONALLY, before the classification.
    ///    It used to sit behind `if (stable() == base) return true;`, so a BASE-DEBT venue was allowlisted with
    ///    its collateral NEVER VALIDATED. The exemption was written for a genuine SHORT, whose collateral is a
    ///    stable and so legitimately outside `{c0,c1}` — but the short subsystem was REMOVED 2026-07-24, so the
    ///    branch no longer protects anything and only widened the gate this function exists to close.
    ///    It became reachable when the weETH-collateral/WETH-LOAN venue landed: its `stable()` IS `WETH` IS
    ///    `base`, so it took the early return. Its collateral is weETH and always was — the point is that
    ///    nothing checked.
    /// ⚠️ THE RETURN IS STILL LOAD-BEARING, DO NOT DROP IT. `LevManager:211` discards it (which is why
    ///    `LevManager:210` calls the classification "unused" — true of THAT CALLER ONLY), but
    ///    `BtcLevManager:108` consumes it as `if (isShort) revert BadAuth()`. Deleting it opens the BTC side.
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
    uint32  internal constant TWAP_WIN_M         = 1800;
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

    /// @notice Test-only view onto `_slipBps`. `internal` cannot be reached from a test contract
    ///         that does not inherit the library, and the curve is exactly the kind of arithmetic
    ///         that should be pinned by assertion rather than by reading it.
    function slipBpsForTest(uint256 usd18) external pure returns (uint256) { return _slipBps(usd18); }

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
    /// EMPTY means "no route supplied" and the leg falls back to V3 — see `_wethToStableDex`.
    struct SellCtx { address weth; address weeth; address aux; address keeper; uint256 reserveIn; uint256 dex; uint256 dex2; }

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
    ///      `_volToStable`, `_wethToStableDex`, `_hubSwap` and `sellWeethOnCurve` are six spellings
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
    function convertTo(address[] memory inTokens, uint256[] memory inAmounts,
                       address outToken, uint256 minOut, bytes[] memory routes)
        internal returns (uint256 got) {
        uint256 n = inTokens.length;
        require(n == inAmounts.length && n == routes.length, "convertTo/len");
        uint256 before_ = IERC20Min(outToken).balanceOf(address(this));
        for (uint256 k; k < n; ++k) {
            uint256 amt = inAmounts[k];
            if (amt == 0 || inTokens[k] == outToken) continue;   // nothing to do / already the target
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
        }
        got = IERC20Min(outToken).balanceOf(address(this)) - before_;
        if (got < minOut) revert Slippage();                     // ONE floor, on the WHOLE conversion
    }

    /// @notice weETH → WETH on a Curve pool. **THE ONLY IMPLEMENTATION OF THIS TRADE IN THE TREE.**
    /// @dev 🔴 **IT WAS WRITTEN TWICE.** `LevMath._weethToWethDex` (the lever's de-lever) and
    ///      `SwapLib.curveSellWeeth` (the basket's weETH offramp) were the SAME six lines — approve,
    ///      `exchange(1, 0)`, catch, zero the approval, return 0 — differing only in where the pool
    ///      came from and whether they spelled the token `IERC20` or `IERC20Min`. Two copies of one
    ///      external call is two places to add a router, two places to get an approval wrong, and
    ///      two places for the ETH offramp to drift from the lever's.
    ///      ⭐ **THE BODY LIVES HERE BECAUSE `SwapLib` ALREADY IMPORTS `LevMath` (`SwapLib.sol:30`)
    ///      AND THE REVERSE WOULD BE A CYCLE.** Both former implementations are now thin wrappers.
    ///      ▶️ **THIS IS THE SEAM TO ROUTE, AND THE REASON TO FOLD FIRST: a single hardcoded Curve
    ///      pool is not a best path.** `ETHERFI_CURVE_POOL` has no fallback — if it is thin or paused
    ///      the leg returns 0 and the de-lever silently sources nothing. Adding an aggregator here
    ///      now upgrades EVERY weETH offramp at once; adding it before this fold would have upgraded
    ///      one and left the other behind.
    function sellWeethOnCurve(address weeth, address pool, uint256 amountIn, uint256 minOut)
        internal returns (uint256) {
        if (pool == address(0) || amountIn == 0) return 0;
        // §PM-INVARIANT-3 — exact-amount approval, ZEROED IN THE CATCH. An allowance that survives a
        // failed swap is a standing claim on the next block's balance.
        IERC20Min(weeth).approve(pool, amountIn);
        try ICurvePool(pool).exchange(int128(1), int128(0), amountIn, minOut) returns (uint256 out) {
            return out;
        } catch { IERC20Min(weeth).approve(pool, 0); return 0; }
    }

    function _weethToWethDex(SellCtx memory c, uint256 pulled) internal returns (uint256) {
        // ⚠️ The floor is the REDEMPTION RATE, not an AMM quote, which is why it keeps the flat
        //    `SELL_SLIP_BPS` rather than the size-aware curve — trade size is not the variable here.
        uint256 wethFloor = IWeETH(c.weeth).getEETHByWeETH(pulled) * (10_000 - SELL_SLIP_BPS) / 10_000;
        return sellWeethOnCurve(c.weeth, ETHERFI_CURVE_POOL, pulled, wethFloor);
    }

    /// stable → collateral (lever-up BUY). weETH venue mints via ether.fi; WETH venue supplies WETH directly.
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

    /// WETH → weETH on-ramp (the INVERSE of `_weethToWeth`): mint at ether.fi's fair rate. NON-reverting (fair-rate mint always clears) so the short-close
    /// can call it after its own try/catch'd stable→WETH SOR without a nested revert escaping the catch.
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
    ///      while the volatile book is a pinned Uniswap V3 pool:
    ///          stable →(Curve stableswap, int128)→ USDC →(Uniswap V3, `_poolSwap`)→ WETH
    ///      The caller mints the result straight into weETH; WETH never rests as collateral.
    /// ⚠️ THE FLOOR IS ORACLE-DERIVED AND APPLIED TO THE WHOLE ROUTE, not per hop. A per-hop floor
    ///      would let the pair of hops lose more than the stated slippage between them. This is the
    ///      only real protection on the leg — the caller's `minOut` is an ADDITIONAL check, and a
    ///      permissionless `rebalance` may pass 0 for it.
    /// @notice §V-R1-MIN — THE ONE SWAP EVERY LEVER LEG ROUTES THROUGH. Pinned pool, no calldata.
    /// @dev    The keeper supplies NOTHING here. That is the point: routing through an aggregator
    ///         would need off-chain calldata, which would make the keeper choose the execution path
    ///         and run an HTTP client to do it. This takes a fee tier that is a CONSTANT and a floor
    ///         the CONTRACT computes, so the keeper's whole role stays "decide the moment".
    ///
    ///         THE TWO PROPERTIES THAT STILL MATTER, both kept from the aggregator design because
    ///         they are about the OUTCOME rather than the venue:
    ///         ① EXACT, ZEROED APPROVAL — set to `amountIn`, cleared on both paths. Clearing to 0
    ///            first keeps USDT-style tokens (which reject a non-zero-to-non-zero approve) working.
    ///         ② THE FLOOR IS CHECKED AGAINST A MEASURED BALANCE DELTA, not the router's return
    ///            value. A return value is a number the callee chooses; a guard that trusts one is
    ///            checking the failing party's own homework. This survives even though the venue is
    ///            now trusted, because the POOL's fill is still not something we get to assert.
    ///
    ///         ⚠️ `minOut` IS ORACLE-DERIVED BY THE CALLER, never passed through from a user. Every
    ///         call site floors it at `TWAP * (10_000 - slip)/10_000` first. `rebalance` is
    ///         permissionless, so the caller picks WHEN and the contract picks the PRICE BOUND —
    ///         that division is what makes a permissionless rebalance anti-sandwich, and it is
    ///         unchanged by dropping the aggregator.
    /// @notice Execute a volatile hop on 1inch AggregationRouterV6. §C2.1 (owner: "1inch only").
    /// @param dex THE KEEPER SUPPLIES ONE THING: **WHICH POOL**. Packed as V6's `Address` word —
    ///        low 160 bits the pool, protocol in bits 253-255 (`0` UniswapV2, `1` UniswapV3,
    ///        `2` Curve), and for V3 bit 247 is `zeroForOne`. `0` means "no pool supplied".
    /// @dev  ⭐ **THE KEEPER DOES NOT SUPPLY CALLDATA, AND THAT IS THE WHOLE POINT OF THIS SHAPE.**
    ///       This used to take `bytes route` and `call` it verbatim, which is the standard 1inch
    ///       integration and is WRONG HERE — **1inch calldata embeds its own `amount`, and every
    ///       amount that reaches this function is computed ON-CHAIN.** `_stableToWethSor` passes
    ///       `_hubSwap(...)`'s CURVE OUTPUT; `leverUpBuyWbtc` passes `venue.borrow(...)`'s return.
    ///       Neither is predictable off-chain to the wei, so a pre-built route's amount is stale by
    ///       construction: too high and the router's `transferFrom` reverts, too low and it
    ///       under-swaps into a `Slippage()` four frames away. **The keeper could not have supplied
    ///       a working route, only a route that happened to work.**
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
    /// @param dex2 OPTIONAL second pool, same encoding as `dex`. **`0` means one hop** — the single-pool
    ///        call is unchanged, so every existing caller keeps its exact behaviour. Non-zero switches
    ///        to `unoswap2`, which is 1inch's TWO-POOL entrypoint and, crucially, still takes the
    ///        amount as a runtime argument (§CURVE-ALONE-CANNOT-DO-IT).
    /// @dev   ⚠️ EVERY SECURITY PROPERTY OF THE ONE-HOP FORM IS UNCHANGED AND SHARED, WHICH IS WHY THIS
    ///        IS ONE BODY AND NOT AN OVERLOAD: the callee is still the pinned router, the selector is
    ///        still a CONSTANT (now one of two, chosen by our own arithmetic rather than by the
    ///        caller), the amount is still computed on-chain, `minOut` is still the caller's
    ///        oracle-derived floor, and the floor is still enforced on the MEASURED BALANCE DELTA of
    ///        `tokenOut` — which bounds the whole route regardless of how many pools it crossed.
    ///        ⛔ A second selector does NOT widen what the keeper can reach: it still supplies only
    ///        pool words, never a destination and never a function.
    function _aggSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 dex,
                      uint256 dex2) internal returns (uint256 out)
    {
        if (amountIn == 0) return 0;
        if (dex == 0) revert NoVolatileRoute();
        // ⭐ `zeroForOne` IS DERIVED, NEVER TRUSTED. The keeper names a POOL; which way we cross it
        //    is a fact about `tokenIn`, which this frame owns. Reading `token0()` costs one cold
        //    SLOAD-equivalent and removes the last thing a keeper could get wrong — and it means ONE
        //    pool word serves BOTH directions, so a lever-up and the de-lever that unwinds it take
        //    the identical argument. A keeper that had to flip the bit by direction would be
        //    re-deriving state it reads a block earlier than we execute it.
        if (dex >> 253 == PROTO_UNIV3) {
            dex &= ~ZERO_FOR_ONE;                                  // ignore whatever the keeper set
            if (tokenIn == IUniV3PoolMin(address(uint160(dex))).token0()) dex |= ZERO_FOR_ONE;
        }
        // ⭐ HOP 2's DIRECTION IS DERIVED FROM ITS **OUTPUT**, WHERE HOP 1's COMES FROM ITS **INPUT** —
        //    and that symmetry is what makes the intermediate token unnecessary. This frame owns
        //    `tokenIn` (hop 1 consumes it) and `tokenOut` (hop 2 produces it); the token BETWEEN the
        //    pools is whatever pool 1 pays out, which we would otherwise have to read and trust.
        //    `ZERO_FOR_ONE` means token0→token1, so hop 2 must set it exactly when `tokenOut` is the
        //    pool's token1 — expressed here as `tokenOut != token0()`, which needs only the SAME
        //    accessor hop 1 uses and so does not widen `IUniV3PoolMin`. As with hop 1, whatever the
        //    keeper set in that bit is DISCARDED: the keeper names pools, never directions.
        if (dex2 != 0 && dex2 >> 253 == PROTO_UNIV3) {
            dex2 &= ~ZERO_FOR_ONE;
            if (tokenOut != IUniV3PoolMin(address(uint160(dex2))).token0()) dex2 |= ZERO_FOR_ONE;
        }
        // §C15 — **THE SEAM IS ONE FUNCTION.** This no longer executes anything: it ENCODES a
        //    pool-word route and hands it to `convertTo`, which is the single execution path for
        //    every conversion in the protocol. Two encoders (pool words here, aggregator calldata
        //    off-chain), ONE executor — so the approval pattern, the pinned callee and the
        //    balance-delta floor exist in exactly one place and cannot drift between paths.
        address[] memory tin = new address[](1);
        uint256[] memory tam = new uint256[](1);
        bytes[]   memory rts = new bytes[](1);
        tin[0] = tokenIn; tam[0] = amountIn;
        rts[0] = dex2 == 0
            ? abi.encodeWithSelector(UNOSWAP_SELECTOR,  uint256(uint160(tokenIn)), amountIn, minOut, dex)
            : abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(uint160(tokenIn)), amountIn, minOut, dex, dex2);
        return convertTo(tin, tam, tokenOut, minOut, rts);
    }

    // §C2.1 — `_poolSwap` (Uniswap V3 `exactInputSingle`) IS DELETED. Owner: "we dont need v3
    // anymore pull it out and delete it completley". Every volatile hop now goes through `_aggSwap`
    // against the pinned 1inch router, and a hop with NO ROUTE REVERTS `NoVolatileRoute()` rather
    // than silently returning 0 — see the warning on `_volToStable`.

    function _stableToWethSor(SellCtx memory c, address stable, uint256 stableAmt) internal returns (uint256) {
        if (stable == c.weth) return stableAmt;          // already WETH: no venue needed
        uint256 usd18_ = _toUsd18(c.aux, stable, stableAmt);
        uint256 floor_ = (usd18_ * 1e18 / IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M))
                         * (10_000 - _slipBps(usd18_)) / 10_000;   // size-aware, capped at the old constant
        // ⭐ NOTE THE `floor_`: THIS SIDE BOUNDS THE SWAP, AND ITS MIRROR DID NOT. `_wethToStableDex`
        //    (the CLOSE leg) passed `0` and discarded its own `minOut` — see §MINOUT-DROPPED. The
        //    open/close asymmetry is what identified it: one direction derives an oracle floor at
        //    `SELL_SLIP_BPS`, the other trusted the keeper's route outright.
        if (c.dex2 == 0)             // legacy COMPAT BRANCH — see `_stableToWbtc`
            return _aggSwap(USDC, c.weth, _hubSwap({stable: stable, amt: stableAmt, toUsdc: true}), floor_, c.dex, 0);
        return _aggSwap(stable, c.weth, stableAmt, floor_, c.dex2, c.dex);  // hub hop FIRST
    }

    /// @dev THE routing table — the single place a Curve stable route is written down. Maps a stable
    ///      to `(pool, its own index, USDC's index)`; `pool == address(0)` means "not on the table",
    ///      which is the one condition `_routableStable` asks and both swap legs reject.
    ///      Each pool carries its OWN index pair — the two live pools are ordered OPPOSITELY (verified
    ///      on-chain), so a shared constant would be wrong for one of them with no revert to catch it.
    ///
    ///      §E210 — WHY A TABLE AND NOT A BRANCH PER STABLE. The roster used to be written THREE
    ///      times (once in each swap leg's body, once in `_routableStable`), and each new stable cost
    ///      TWO inlined `approve`+`exchange` bodies. `LevMath` is the tightest contract in the repo,
    ///      so that shape had made the roster UNGROWABLE — not merely verbose. This is standing rule
    ///      8c applied to branches instead of modifiers: one routine, N jumps. Adding a stable is now
    ///      ONE line here, and the swap bodies below never change again.
    function _routeOf(address stable)
        private pure returns (address pool, int128 iStable, int128 iUsdc)
    {
        if (stable == RLUSD_TOKEN) return (CURVE_USDC_RLUSD, CRV_RLUSD_IDX, CRV_RLUSD_USDC_IDX);
        if (stable == PYUSD_TOKEN) return (CURVE_PYUSD_USDC, CRV_PYUSD_IDX, CRV_PYUSD_USDC_IDX);
        // Absent ⇒ (0,0,0). Deliberately does NOT revert: this predicate serves `_routableStable`,
        // which must be able to ASK without failing (an unroutable slice is skipped and refunded).
    }

    /// @dev Curve stableswap hub hop, BOTH directions: `toUsdc ? stable→USDC : USDC→stable`.
    ///      One body where there were two (`_toUsdc`/`_fromUsdc`) — the legs differed only in which
    ///      token is approved and the index order. Call it with named arguments so the direction is
    ///      readable at the site (`_hubSwap({stable: s, amt: a, toUsdc: true})`), not a bare bool.
    function _hubSwap(address stable, uint256 amt, bool toUsdc) internal returns (uint256) {
        if (amt == 0) return 0;
        if (stable == USDC) return amt;            // hub itself — nothing to convert, either direction
        (address pool, int128 iStable, int128 iUsdc) = _routeOf(stable);
        if (pool == address(0)) revert NoStableRoute();  // fail closed — a silent 0 would leave the position unhedged
        IERC20OZ(toUsdc ? stable : USDC).forceApprove(pool, amt);
        return toUsdc
            ? ICurvePool(pool).exchange(iStable, iUsdc, amt, 0)
            : ICurvePool(pool).exchange(iUsdc, iStable, amt, 0);
    }

    /// @dev Is this stable on the Curve routing table? Checked rather than caught: an unroutable
    ///      slice must be SKIPPED and refunded, not swapped at whatever a fallback would give.
    function _routableStable(address t) internal pure returns (bool) {
        if (t == USDC) return true;                // the hub itself
        (address pool,,) = _routeOf(t);
        return pool != address(0);
    }

    /// @dev stable → WBTC (BTC lev open) and WBTC → stable (close), both VIA USDC — and the two
    ///      hops sit on DIFFERENT venues: stable↔USDC is Curve stableswap, USDC↔WBTC is a pinned
    ///      Uniswap V3 pool.
    ///      `minOut` is applied on the LAST hop so it bounds the whole route.
    /// @dev §V-R1-MIN's two hops SURVIVE — what changes is WHERE THE FIRST HOP'S POOL COMES FROM.
    ///      It used to be `_hubSwap`, a COMPILE-TIME table of two Curve pools (`_routeOf`), so the
    ///      lever could borrow **RLUSD or PYUSD and nothing else** — every other stable hit
    ///      `NoStableRoute()`. Now both hops are keeper-supplied pool words through one `unoswap2`,
    ///      so **any stable with an addressable pool is borrowable** and there is no table to extend.
    ///      ⭐ THE SAFETY ARGUMENT IS UNCHANGED AND STRICTLY STRONGER: the keeper still names only
    ///      pools, and the ORACLE FLOOR now bounds the WHOLE route on a measured balance delta.
    ///      🔴 The old first hop called `ICurvePool.exchange(i, j, amt, **0**)` — `min_dy` of ZERO,
    ///      bounded only because the downstream floor caught the final output. One call, one floor.
    /// 🔴 **ARGUMENT ORDER IS A TRAP HERE AND IS DELIBERATE. `_aggSwap` takes (hop1, hop2); the
    ///    keeper's LONG-STANDING `dex` MEANS THE VOLATILE POOL, WHICH IS HOP **2**.** The new `dex2`
    ///    carries the stable→USDC hub hop, i.e. hop **1**. Passing them in declaration order would
    ///    silently redefine what the third argument of every live entrypoint means — the keeper would
    ///    keep sending the same word and it would be used for the wrong leg. Appending the new
    ///    parameter and CROSSING it here keeps every existing caller's meaning intact.
    /// @dev ⚠️ `hubDex == 0` FALLS BACK TO THE LEGACY CURVE HUB HOP — a MIGRATION BRANCH with a named
    ///      removal condition, not a permanent clamp.
    ///      ⛔ **NOT A "BRIDGE".** In this repo `quid-bridge` is the DAEMON — `channel_driver.rs`,
    ///      `deadman_exit.rs` and `lp_seed.rs` (Lightning) live in the same crate as `lev_keeper.rs`
    ///      and `lev_keeper_btc.rs`. **The Lightning bridge and the leverage keeper are ONE PROCESS**,
    ///      so the word is taken and using it for a compatibility branch reads as if this had
    ///      something to do with the hop. It does not.
    ///      🔴 **AND THAT SHARED PROCESS IS A SECURITY FACT, NOT A PACKAGING DETAIL: compromising
    ///      the LN daemon compromises the lev keeper, and vice versa.** It is why the owner's
    ///      "keeper is hacked and replaced with malicious code" constraint spans both roles at once,
    ///      and why an API key placed there is leaked alongside the Lightning material. Without it this change would be a
    ///      LIVE REGRESSION: the deployed RLUSD and PYUSD venues route through `_routeOf`'s table
    ///      today, and no keeper supplies a hub pool word yet, so a bare one-hop `stable→WBTC` has no
    ///      pool and would revert. Same shape as `rangeUnwindDex`'s `zero ⇒ DEFAULT_UNWIND_DEX`.
    ///      ▶️ **DELETE THIS BRANCH — and `_hubSwap`/`_routeOf`/`_routableStable`/`NoStableRoute`
    ///      with it — once the keepers supply `hubDex` for every venue stable in use.**
    ///      🔴 THE GUARD IS `hubDex == 0` ALONE, AND ADDING `&& stable != USDC` BROKE 17 TESTS WITH
    ///      `NoVolatileRoute()`. A USDC-denominated venue legitimately has NO hub hop, so its
    ///      `hubDex` is 0 — the extra clause pushed exactly that case onto the two-hop path with a
    ///      ZERO first pool word. `_hubSwap` already returns `amt` unchanged when `stable == USDC`,
    ///      so the identity case is handled INSIDE the fallback and needs no condition of its own.
    ///      ⚠️ The compiler cannot see this; only running the suite did.
    function _stableToWbtc(address stable, uint256 amt, uint256 minOut, address wbtc, uint256 volDex,
                           uint256 hubDex) internal returns (uint256) {
        if (hubDex == 0)
            return _aggSwap(USDC, wbtc, _hubSwap({stable: stable, amt: amt, toUsdc: true}), minOut, volDex, 0);
        return _aggSwap(stable, wbtc, amt, minOut, hubDex, volDex);
    }

    /// @dev Mirror of `_stableToWbtc`: pinned pool to USDC, stableswap hub back out. `minOut` is
    ///      applied to the FINAL stable amount, not the USDC intermediate, so the floor bounds what
    ///      the caller actually receives.
    ///      ONE body for BOTH volatiles: the WBTC and WETH down-legs differed only in the V3 fee
    ///      tier, so `fee` is now an argument. `internal` in a library is copied into every caller,
    ///      so collapsing two bodies to one multiplies by the caller count.
    /// @dev ⚠️ `route` EMPTY ⇒ `_aggSwap` REVERTS `NoVolatileRoute()`. That is deliberate: with V3
    ///      gone there is no fallback venue, so a caller that supplies no route CANNOT trade. The
    ///      revert is the honest surface — a silent 0 would reappear as a slippage failure frames away.
    /// 🔴 SAME CROSSED ORDER as `_stableToWbtc`, and MIRRORED because this leg runs the other way:
    ///    here the VOLATILE pool is hop 1 and the hub hop is hop 2.
    function _volToStable(address vol, address stable, uint256 amt, uint256 minOut, uint256 volDex,
                          uint256 hubDex) internal returns (uint256) {
        // ⭐ THE FLOOR MOVED ONTO THE ROUTE ITSELF. This used to swap to USDC with `minOut = 0`, run
        //    `_hubSwap` back out, then compare — so the INTERMEDIATE hop was unbounded and the check
        //    lived a frame away. `_aggSwap` now enforces `minOut` on the measured delta of the FINAL
        //    token, which is the same guarantee expressed once instead of twice.
        if (hubDex == 0) {           // legacy COMPAT BRANCH — see `_stableToWbtc`
            uint256 usdc = _aggSwap(vol, USDC, amt, 0, volDex, 0);
            uint256 out = _hubSwap({stable: stable, amt: usdc, toUsdc: false});
            if (out < minOut) revert Slippage();
            return out;
        }
        return _aggSwap(vol, stable, amt, minOut, volDex, hubDex);
    }

    /// @dev IDENTITY WHEN THE LOAN TOKEN IS ALREADY WETH — the close-side twin of the note on
    ///      `_stableToWethSor`. `minOut` is unused on that branch because no trade occurs.
    function _wethToStableDex(SellCtx memory c, address stable, uint256 wethIn, uint256 minOut) internal returns (uint256) {
        if (stable == c.weth) return wethIn;              // loan token IS WETH — nothing to convert
        // 🔴 §MINOUT-DROPPED — THE `route.length != 0` FAST PATH IS DELETED, AND IT WAS THE LIVE ONE.
        // Its comment described *"1INCH WHEN THE KEEPER SUPPLIED A ROUTE, V3 OTHERWISE"*, but V3 is
        // GONE (`V3_FEE_WETH`: 0 refs; `_poolSwap`: comments only), so the "otherwise" arm called
        // `_volToStable` with an EMPTY route — which `_aggSwap` rejects with `NoVolatileRoute()`.
        // A fallback that can only revert is not a fallback.
        // ⭐ AND THE TWO ARMS WERE THE SAME OPERATION, WHICH IS WHY THIS IS A FIX AND NOT JUST A
        //   DELETION: `_hubSwap(stable, _aggSwap(weth, USDC, wethIn, **0**, route), false)` is
        //   `_volToStable` MINUS its `if (out < minOut) revert Slippage()`. So the arm that actually
        //   ran was the UNBOUNDED one — a keeper-supplied route executed with NO slippage bound at
        //   the stable leg, `minOut` accepted as a parameter and silently discarded.
        // ⇒ One call, bound restored. `minOut` is now honoured on every path through here.
        return _volToStable(c.weth, stable, wethIn, minOut, c.dex, c.dex2);  // one routed call, floor on the final token
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
        return (_fromUsd(c.aux, stable, usd18) * (10_000 - _slipBps(usd18))) / 10_000;
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
    ///         `_reimburse`. (§E304-mintclose: the BOLD-close entry named here went with the Liquity venue.)
    function reimburseKeeper(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        public returns (uint256 skimmed, uint256 reserveOut)
    {
        return _reimburse(weth, keeper, availWeth, reserveIn);
    }

    /// The manager's runtime addresses + gas-reserve, threaded into `extractToVaultBody` (delegatecall) and
    /// returned updated. `maxSlippageBps` grosses the collateral withdraw so the sale covers the flash even at
    /// worst execution. Collateral units are always weETH-rate: raw WETH collateral is dominated and gone.
    /// §C2.1 — `route` is the keeper-built 1inch calldata, threaded from the flash `data` down to
    /// `_wethToStableDex`. EMPTY means none was supplied and the leg falls back to V3.
    struct ExtractCfg { address weth; address weeth; address aux; address flashProvider; address keeper; uint256 gasReserve; uint16 maxSlippageBps; uint256 dex; uint256 dex2; }

    /// @dev Repay-first + withdraw the paired collateral, in its OWN frame so both callers' stacks stay shallow
    ///      (no via_ir). Flashed `assets` → venue → repay; then withdraw collateral worth (repaid + `extractUsd`)
    ///      of ETH at `pxWeth`, grossed by max slippage so the sale covers the flash at worst execution. WETH
    ///      venue = 1:1 ETH; weETH venue = via the ether.fi rate.
    ///      ONE body where there were two: `_pullForExtract` (§G.3 extraction) and `_repayAndFree` (mode-0 settle)
    ///      differed in exactly ONE scalar — the extra `extractUsd` of value to free beyond what was repaid, which
    ///      the settle path passes as 0 — plus WHERE `pxWeth` came from, a live TWAP read on one side and the
    ///      caller's already-resolved price on the other. Both still resolve it the same way they always did —
    ///      the extraction's live TWAP read simply moved down into `_pullForExtract` — so the arithmetic here is
    ///      byte-identical to what each of the two bodies computed before.
    ///      ⚠️ The `NoPrice` guard was on the settle side only; the extraction side divided by a raw TWAP and
    ///      would have PANICKED on a zero anchor. `Aux.getTWAPforAsset` deliberately never reverts, so that is
    ///      reachable — see `freeAndDeliverBody`'s note, which argues the named revert for exactly this divisor.
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
    ///      value-neutral surplus to `recipient`. ONE body where there were two: `_sellAndRoute` (recipient = the
    ///      redeem sink `vault`) and `_sellAndReturn` (recipient = `lp`) were byte-identical apart from that name —
    ///      `stableOut > assets ? stableOut - assets : 0` is exactly the `if (stableOut > assets)` guard the second
    ///      one wrote inline. Own frame purely for the non-via_ir stack budget of the two callers.
    function _sellAndPay(uint256 pulled, address stable, uint256 minOut, uint256 assets, address recipient, ExtractCfg memory cfg)
        private returns (uint256 newGasReserve, uint256 freed)
    {
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2});
        uint256 stableOut;
        (stableOut, newGasReserve) = sellColl(sc, stable, pulled, minOut, assets);
        IERC20OZ(stable).forceApprove(cfg.flashProvider, assets);
        freed = stableOut > assets ? stableOut - assets : 0;
        if (freed > 0) IERC20OZ(stable).safeTransfer(recipient, freed);
    }

    /// @notice §M.1 — convert `collAmt` of freed leverage collateral to WETH and deliver it to `recipient` (the ETH
    ///         swap-out). WETH venue = 1:1; weETH venue = the V3→ether.fi offramp (`_weethToWeth`, shared with
    ///         `sellWeeth`). Bytecode lives HERE (delegatecall-linked, address(this)==manager) so the manager stays
    ///         under EIP-170. `minOut` floors the delivered WETH against MEV on the internal conversion. NO
    ///         flash / NO stable-sale — the debt was already repaid by the swap's own proceeds; this only turns the
    ///         value-neutrally-freed collateral into deliverable ETH (equity untouched).
    function collToWethDeliver(uint256 collAmt, address recipient, uint256 minOut, ExtractCfg memory cfg)
        public returns (uint256 wethDelivered) {
        if (collAmt == 0) return 0;
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2});
        wethDelivered = _weethToWeth(sc, collAmt);
        require(wethDelivered >= minOut, "swapDelever:minOut");
        if (wethDelivered > 0) IERC20Min(cfg.weth).transfer(recipient, wethDelivered);
    }

    /// @notice Free `usedUsd`-worth of collateral (value-neutral, `pxWeth`-priced) and deliver it as WETH — the
    ///         manager's _freeAndDeliverWeth/_pullForFree/_deliverColl, folded here (delegatecall, address(this)==
    ///         manager) to keep the manager under EIP-170. `cfg.weeth` doubles as the weETH rate source.
    function freeAndDeliverBody(ILevVenue venue, address lp, uint256 usedUsd, address recipient,
        uint256 minWethOut, uint256 pxWeth, ExtractCfg memory cfg) public returns (uint256 wethDelivered) {
        // A ZERO oracle price must never PANIC. `Aux.getTWAPforAsset` deliberately NEVER reverts
        // (that is what makes #101's degrade-to-partial-fill work), so an unset/stale Chainlink anchor
        // propagates `pxWeth == 0` straight into these divisors — measured: testReal_Morpho_OpenAndDelever
        // and testReal_Euler_OpenAndDelever both died on `panic: division or modulo by zero (0x12)` here,
        // via twapResolve(feed=0x0, price=0). A panic burns all gas and is undiagnosable; a named revert
        // is the correct failure for an operation that genuinely cannot be sized without a price.
        if (pxWeth == 0) revert NoPrice();
        uint256 freeEth = (usedUsd * 1e18) / pxWeth;                              // WETH-equivalent to free
        uint256 coll = venue.collateralOf(lp);
        uint256 collInEth = IWeETH(cfg.weeth).getEETHByWeETH(coll);
        uint256 pull = collInEth == 0 ? 0 : (freeEth >= collInEth ? coll : (coll * freeEth) / collInEth);
        if (pull == 0) return 0;
        uint256 got = venue.withdraw(lp, pull);                                   // collateral → the manager
        uint256 floor = minWethOut;
        { uint256 f = (freeEth * (10_000 - cfg.maxSlippageBps)) / 10_000; if (f > floor) floor = f; } // MEV floor
        wethDelivered = collToWethDeliver(got, recipient, floor, cfg);
    }

    // §E304-mintclose: the `onFlashMintBody` (mode-1 BOLD) docblock was left here after its body went with the
    // Liquity V2 venue (`c11cb40f`); it had no declaration under it and read as `_reimburse`'s natspec. Deleted.

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
        // PRO-RATA redeem (no `preferred`): take the LP's FAIR slice of every basket stable — never force-drains
        // the basket of one stable (the targeted path over-commits under leverage). Then consolidate that mix into
        // the venue's own loan token via the multi-route SOR (basket V4 hops, UniV3-backed fallback).
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
    ///      stable it lends) so the protect never depends on the basket holding a specific stable. MULTIPLE ROUTES:
    ///      the basket SOR first (V4 hops / UniV3-backed), then an EXTERNAL UniV3 fallback on the deep stable tiers —
    ///      GUARANTEEING a route to whatever's borrowed even if the SOR has no encoded path (`NoSelfFundedPath`).
    ///      Per-swap minOut is 0; the caller's aggregate `minStableOut` floor bounds total slippage, and a stable
    ///      that BOTH routes can't move only lowers `got`, tripping that floor (fail-safe, never a silent shortfall).
    uint256 internal constant CONSOL_SLIP_BPS = 100;  // 1% anti-MEV floor on each stable→loan-token consolidation swap

    function _consolidateTo(address aux, address target, address lp) private {
        address[] memory sts = IAux(aux).getStables();
        for (uint256 i; i < sts.length; i++) {
            address s = sts[i];
            if (s == target) continue;
            uint256 bal = IERC20Min(s).balanceOf(address(this));
            if (bal == 0) continue;
            // Anti-MEV floor: stables are ~1:1, so expect ~the same USD out of the swap; allow CONSOL_SLIP_BPS for
            // pool fee + impact. A stable depegged below the floor can't clear either route ⇒ it refunds to the LP
            // (below) rather than swapping at a loss — fail-safe, mirroring `rebalance`'s oracle-derived `_floor`.
            uint256 floor = _fromUsd(aux,target, _toUsd18(aux,s, bal)) * (10_000 - CONSOL_SLIP_BPS) / 10_000;
            // ROUTABILITY IS CHECKED, NOT CAUGHT. A library cannot `try this.…` — in a delegatecalled
            // library `this` is the CALLER — and the condition the old try/catch actually guarded was
            // "this stable has no route", which is now a pure predicate. An unroutable slice is skipped
            // and refunded to the LP below, exactly as before.
            // ⚠️ BEHAVIOUR NARROWED, DELIBERATELY: a REVERT INSIDE CURVE (pool paused, depeg past the
            //    floor) now propagates instead of being swallowed per-slice. That is the safer
            //    direction here — the old catch could silently leave a consolidate half-done, and the
            //    floor already refuses a bad price rather than trading at a loss.
            if (_routableStable(s) && _routableStable(target)) {
                uint256 moved = _hubSwap({stable: target, amt: _hubSwap({stable: s, amt: bal, toUsdc: true}), toUsdc: false});
                if (moved < floor) revert Slippage();
            }
            // If BOTH routes failed to move this slice (no pool at all), refund it to the LP — never strand the
            // LP's own redeemed value in the manager (it only lowers `got`, which the aggregate floor already guards).
            uint256 rem = IERC20Min(s).balanceOf(address(this));
            if (rem > 0) IERC20OZ(s).safeTransfer(lp, rem);
        }
    }

    /// @notice Debt delta (USD 1e18) + direction to re-hit `targetBps` LTV, given the position's
    ///         collateral value (`collUsd`) and current debt (`curDebtUsd`). Inside `±rangeBps` of
    ///         target ⇒ `(false, 0)`. Identical to `LevManager.debtDeltaToTarget` tail.
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
    ///         net-equity collateral (== collateral, no debt) and deliver it as WETH. VERBATIM of the manager's
    ///         former inline `swapOutDeliverUnlevered` tail; `cfg.weeth` doubles as the weETH rate source.
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

    // §J2-LEV-ARITY — `swapOutDeleverBody` DELETED with its only caller (the per-LP ETH
    // `swapOutDelever`). `swapOutDeleverPooled` never used it: it does repay/withdraw against the POOL
    // directly. A library body whose sole caller is gone is unreachable, not spare capacity.

    /// @dev Repay `stableUsd`-worth (clamped to debt) of `lp`'s debt with the stable the Vault pre-transferred to the
    ///      venue; returns the USD 1e18 actually applied. Own frame so `swapOutDeleverBody`'s stack stays shallow.
    function _repayPretransferred(ILevVenue venue, address lp, uint256 stableUsd, address aux) private returns (uint256 usedUsd) {
        address stable = venue.stable();
        uint256 amt = _fromUsd(aux,stable, stableUsd);
        uint256 debt = venue.debtOf(lp);
        if (amt > debt) amt = debt;                                               // clamp to debt (never over-repay / strand)
        if (amt > 0) usedUsd = _toUsd18(aux,stable, venue.repay(lp, amt));            // USD 1e18 actually applied to the debt
    }

    /// @notice §G.3 size the debt-stable to flash-repay for extracting `extractUsd` of value: ΔD = X·debt/netEq,
    ///         clamped to live debt. `debtUsd18` = the LP's live debt (USD 1e18, decimal-normalized by the manager);
    ///         `pxWeth` = USD/WETH TWAP. VERBATIM of the manager's former inline `_netEqUsd`+`_sizeRepayStable`.
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
    ///         the max-slippage buffer) → sell → return the flash + surplus to the LP. VERBATIM of the manager's
    ///         former `_repayAndFree`+`_deleverSettle`. `pxWeth` = USD/WETH TWAP. @return newGasReserve gas-reserve
    ///         after the keeper peel (the thin forwarder writes it back).
    function deleverSettleBody(uint256 assets, address lp, address venueAddr, address stable, uint256 minOut, uint256 pxWeth, ExtractCfg memory cfg)
        public returns (uint256 newGasReserve) {
        uint256 pulled = _repayAndPull(assets, lp, venueAddr, stable, 0, pxWeth, cfg);   // repay-first + withdraw (own frame)
        (newGasReserve, ) = _sellAndPay(pulled, stable, minOut, assets, lp, cfg);   // sell + return-flash + surplus→LP (own frame)
    }

    /// @notice De-lever `lp` by flashing `repayUsd`-worth of the debt stable (repay-first, mode-0). VERBATIM of
    ///         the manager's former `_deleverFlash`; reuses `ExtractCfg` (weth/aux/flashProvider).
    /// @dev    §E304-mintclose: this used to fork to a mint-close (BOLD/Liquity) mode-1 that flashed WETH and
    ///         minted BOLD at the trove's `protocolMintLtvBps`. Morpho does not mint — you borrow what exists —
    ///         and Liquity went with `c11cb40f` because a trove cannot take weETH, which `ILevVenue` is
    ///         denominated in. The detector was unconditionally false, so mode-0 is the only path and always was.
    function deleverFlashBody(ExtractCfg memory cfg, ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 dex)
        public {
        if (repayUsd == 0 || cfg.flashProvider == address(0)) return;
        uint256 debt = venue.debtOf(lp);
        if (debt == 0) return;
        uint256 repayStable = _fromUsd(cfg.aux,stable, repayUsd);
        if (repayStable > debt) repayStable = debt;                              // never flash more than we can repay
        if (repayStable == 0) return;
        // mode 0 = the generic flash-the-stable → repay → withdraw → sell → return path.
        IMorphoFlash(cfg.flashProvider).flashLoan(stable, repayStable, abi.encode(uint8(0), lp, address(venue), stable, minOut, dex));
    }

    // §E304-mintclose: `_isMintVenueM`'s natspec outlived the detector and hung over `_fromUsd`. The
    // try/catch was itself the tell — you only wrap a capability probe in `try` when you expect the
    // callee not to have it, and after Liquity's removal NO venue had it.

    /// USD(1e18) <-> `stable` native units (decimals). Canonical here so both managers can dedup onto them.
    /// @notice USD(1e18) -> native token units, at `pxUsd18` = the USD price of ONE WHOLE token,
    ///         1e18-scaled. `tokens = usd * 10^dec / px`.
    ///
    ///         ⚠️ THE PRICE PARAMETER IS THE POINT. These two used to do a DECIMALS SHIFT ONLY, which
    ///         silently assumes ONE TOKEN = ONE DOLLAR. True of every basket stable; catastrophically
    ///         false of WETH, which has 18 decimals — so `_fromUsd(cfg.aux,weth, usd)` returned `usd`
    ///         UNCHANGED, reading $4,000 of debt as 4,000 WETH, and it feeds `venue.borrow` directly
    ///         at :148. Every shape and decimal typechecks, so the error would be SILENT.
    ///         This matters because the WETH-LOAN MARKET is the next step: it removes both
    ///         stable<->WETH SOR legs from every lever open and close, and lets the WETH supply
    ///         venues go. It cannot land while these assume a dollar peg.
    ///
    ///         Every call site passes `loanPxUsd18(aux, loan)` — the ONE decision point. It formerly passed a
    ///         hardcoded `USD_PX`, correct for a dollar stable and a ~4,000x error for a WETH loan token
    ///         shift EXACTLY — verified by an unchanged suite. Switching a site to a real loan token
    ///         is now one argument: pass `IAux(aux).getTWAPforAsset(tok, TWAP_WIN_M)`.
    /// @dev Takes `aux`, NOT a price. The price is resolved HERE, once, by `loanPxUsd18`. Composing it at the
    ///      call site (`_fromUsd(aux,t, u)`) was tried and is UNBUILDABLE: the extra nested
    ///      frame blew the stack in `sellForStable` with `via_ir` off by choice. Resolving inside is also the
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
