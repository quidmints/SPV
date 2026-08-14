// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
// §A.52: the canonical view (was a file-local `ILevSyncHookM`).
import {ILevSyncHook, IAux, IWeETH, IWiredVault,
        IDepositAdapter, ILevVenueColl, ILevMintVenue} from "./Interfaces.sol";
import {ILevVenue, IERC20Min, IWETH9} from "../imports/ILevVenue.sol";
import {ICurvePool} from "./Interfaces.sol";

// ether.fi weETH/WETH Curve pool (weETH is coin1, WETH coin0). Same address as Vault.ETHERFI_CURVE_POOL.
address constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
import {IMorphoFlash} from "../imports/Interfaces.sol";

/// @dev Token/SOR surfaces the leg mechanics touch. IERC20Min + IWETH9 come from ILevVenue (shared).
/// ONE Aux surface for everything LevMath touches on it (redeem / stables / TWAP / SOR both directions / venue /
/// health) — was five tiny IAux* slices (consolidation).
// ETH-side sell/buy machinery surfaces — moved here (delegatecall, bytecode OUTSIDE LevManager for EIP-170).
/// BOLD/Liquity venue mint-for-close surface — the manager flashes WETH and draws BOLD at face value from the
/// venue's protocol trove. Mirrors LevManager.ILevMintVenue (mintForClose + the usesMintClose detection marker
/// `deleverFlashBody` reads to route the un-flashable BOLD debt through the flash-WETH→mint-BOLD path).
/// Morpho Blue zero-fee flash surface — the ONLY flash source (see LevManager.IMorphoFlash). Mirrored here so the
/// moved de-lever bodies (`deleverFlashBody`) can invoke it from the manager's delegatecall context.
/// The band sync-hook surface the sold-fraction target + reseat reads. Mirrors the managers'
/// ILevSyncHook/ILevSyncHookB — a delegatecall'd library can't read their immutables, so the manager passes the
/// hook address in. All view: the Vogue impls are all view (soldFractionWad/bandSqrtP are
/// `view` fns, reseatEpoch is a `public` state var), and `view` external calls are STATICCALL-safe inside the
/// try/catch below (Solidity allows try/catch on view calls) and callable from both view and non-view callers.

/// @title  LevMath — asset-agnostic IL-protect leverage economics + up-side leg mechanics
/// @notice ONE leverage library shared by the ETH (`LevManager`, weETH) and BTC (`BtcLevManager`, vBTC) paths.
///         Holds the up-side IL-protect economics + money-movement bodies: the IL-cancelling target
///         (`1 − √(entry/now)`), net-equity, debt-delta, and the lever-up/de-lever/flash-close leg mechanics, all
///         `public` (delegatecall-linked, bytecode OUTSIDE the manager) so the managers fit EIP-170. Only the
///         *acquisition/exit rails* differ between assets — the economics don't — so both managers reuse this. Leg
///         funcs run in the MANAGER's context (`address(this)`==manager); immutables the manager owns (AUX/volatile)
///         come in via the cfg structs; the swaps reuse the basket SOR (`sorSelfFunded`, UniV3-backed).
///         (The below-entry SHORT / inverse-venue subsystem was removed — up-side-only is the design.)
library LevMath {

    /// Zero oracle anchor. A named error, NOT a string require: the string form cost enough
    /// bytecode to push this library 38 bytes past EIP-170 (measured).
    error NoPrice();
    uint256 internal constant WAD = 1e18;

    /// @notice The LTV (bps) of `debt` against a position worth `collValue` (same unit); `collValue==0 ⇒ 0`.
    ///         Consolidated in from the former `YBLib` (its only LIVE surface). the leverage's target leverage is L = 2 —
    ///         the IL-vanishing point: a constant-L position has `V* ∝ V_c^L`, a √p band has `V_c ∝ √p`, so
    ///         `V* ∝ p^(L/2)` and L=2 ⇒ `V* ∝ p` (IL cancels), = 2·α⁻¹ (measured α≈0.5). YBLib's `requireSafeDebt`
    ///         + MIN/MAX_SAFE_DEBT envelope were DEAD (no callers) — superseded by the LTV-band rebalance
    ///         (`debtDelta`) + each venue's own LLTV health, so they were dropped, not moved.
    function ltvBps(uint256 debt, uint256 collValue) internal pure returns (uint256) {
        if (collValue == 0) return 0;
        return (debt * 10_000) / collValue;
    }

    /// @notice #67 deliverability (LEVERED-DELIVERABILITY-SPEC.md §1) — the USD a levered position can produce via
    ///         a bounded, VALUE-NEUTRAL de-lever, = the real USD backing the band's pairing may count. The MIN of:
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
    error VenueNotAllowed();  // open onto a venue not on the frozen allowlist
    error VenueBlocked();     // open onto an incident-flagged venue

    /// @notice IL-cancelling target LTV (bps) = `1 − √(entryPrice/pxNow)`, clamped to `capBps`.
    ///         ZERO when flat/down (no IL accrued ⇒ no leverage). `entryPriceWad`/`pxNow` are
    ///         USD-per-base (1e18). Identical to `LevManager._ilTargetBps`.
    function ilTargetBps(uint128 entryPriceWad, uint256 pxNow, uint64 capBps)
        internal pure returns (uint256)
    {
        // at/below entry → no UP-SIDE IL → no up-side overlay. (There IS down-side IL below entry — the band
        // over-holds the falling asset — but a long LP does NOT hedge it: the up-side-only LP just HOLDS long
        // through the fall. Holding beats an LVR-leaking downside rebalance: down-side IL is impermanent and heals,
        // so a below-entry short would realize the loss and forfeit the recovery. Up-side-only is the design.)
        if (entryPriceWad == 0 || pxNow <= entryPriceWad) return 0;
        uint256 ratioWad = (uint256(entryPriceWad) * WAD) / pxNow;    // entry/now < 1 (WAD)
        uint256 sqrtWad  = FixedPointMathLib.sqrt(ratioWad * WAD);    // √(entry/now), WAD (solady, audited)
        uint256 ilBps    = ((WAD - sqrtWad) * 10_000) / WAD;          // 1 − √(entry/now), bps
        return ilBps > capBps ? capBps : ilBps;
    }

    /// @notice The reseat DECISION folded out of both managers' `_reanchorIfReseated`.
    /// @dev  Re-anchor iff the position's `entrySqrtP` now sits OUTSIDE the band's current `[lower, upper]`.
    ///       This REPLACED a `reseatEpoch` counter (removed 2026-08-09) and is strictly MORE PRECISE, not
    ///       merely smaller: the counter fired on EVERY reseat, including ones that left this anchor still
    ///       inside the new range and therefore needed no re-anchor. The bounds fire only when the frame moved
    ///       RELATIVE TO THIS POSITION, and there is no counter to desynchronise.
    /// ⚠️   IT IS A POINT-IN-TIME TEST. It answers "is my anchor stale NOW", NOT "were these two reads taken in
    ///       the SAME frame". §E117 measured a 1h TWAP tick of 200766 sitting neatly inside a post-reseat band
    ///       [200730, 200770) whose window spanned FOUR frame changes — no bounds check can see that. Safe here
    ///       because BOTH live consumers ask the point-in-time question; the windowed consumer (§E93) is
    ///       refuted and blocked. **If anyone builds a WINDOWED reading over the tick series, the epoch must
    ///       come back, and §E117 is the evidence for why.**
    /// @dev  Compared in SQRT space, never by converting `entrySqrtP` to a tick: tick conversion truncates, so
    ///       a position anchored exactly at a boundary would flip on rounding.
    /// @dev Same `active` deletion as `ilTargetLive` — this gate is why re-anchoring NEVER FIRED in
    ///      production, including after the 2026-08-09 bounds-check rewrite.
    function reanchorCompute(address hook, uint160 entrySqrtP)
        public returns (bool go, uint160 newSqrtP) {
        if (hook == address(0) || entrySqrtP == 0) return (false, 0);
        try ILevSyncHook(hook).bandSqrtP() returns (uint160 v) { newSqrtP = v; } catch { return (false, 0); }
        if (newSqrtP == 0) return (false, 0);
        // ONE accessor pair. The hook is per-asset and answers for its own band, so there is no name
        // to select — which is all the removed `isBTC` did here.
        int24 lo; int24 hi;
        try ILevSyncHook(hook).LOWER_TICK() returns (int24 l) { lo = l; } catch { return (false, 0); }
        try ILevSyncHook(hook).UPPER_TICK() returns (int24 u) { hi = u; } catch { return (false, 0); }
        if (lo >= hi) return (false, 0);                       // band unset/degenerate → nothing to compare against
        if (entrySqrtP >= TickMath.getSqrtPriceAtTick(lo) &&
            entrySqrtP <= TickMath.getSqrtPriceAtTick(hi)) return (false, 0);   // still inside its own frame
        go = true;
    }

    /// @notice The live IL target (bps) with the hook read folded out of both managers' `_ilTargetLive`. `public`
    ///         (delegatecall) ⇒ state-call-classed ⇒ the forwarders are non-view (BTC's `ilTargetLtvBps`/
    ///         `debtDeltaToTarget` drop `view` — no on-chain view caller depends on them; off-chain eth_call is
    ///         fine). Band's ACTUAL sold fraction (capped), else the 1−√(entry/now) estimate.
    /// @dev The `bool active` gate was DELETED 2026-08-09. It was `LevManager.soldFractionActive`, a GOV-only
    ///      flag defaulting FALSE that the deploy script never set — so in production this ALWAYS fell through
    ///      to the estimate and the band's measured sold fraction was never read, while three test suites
    ///      flipped it true in setUp and verified the path production did not run. The remaining conditions
    ///      (`entrySqrtP != 0 && hook != address(0)`) already ARE the availability test the flag stood in for:
    ///      use ground truth whenever it can be obtained, else the estimate. Adaptive by construction, no latch.
    function ilTargetLive(address hook, uint160 entrySqrtP, uint128 entryPriceWad, uint256 px, uint64 capBps)
        public returns (uint256) {
        if (entrySqrtP != 0 && hook != address(0)) {
            try ILevSyncHook(hook).soldFractionWad(entrySqrtP) returns (uint256 sf) {
                if (sf != 0) { uint256 bps = sf / 1e14; return bps > capBps ? capBps : bps; }
            } catch {}
        }
        return ilTargetBps(entryPriceWad, px, capBps);
    }

    /// @notice (§3) The stable (USD 1e18) to REPAY to bring a position to target LTV on the FIXED E0 (over-hedge
    ///         fix): `curDebt − targetDebt`, ZERO inside the de-lever band. Pure; folded out of `deleverRepayUsd`.
    function deleverRepay(uint256 e0Usd, uint256 curDebt, uint256 tBps, uint256 bandBps) public pure returns (uint256) {
        uint256 targetDebt = (e0Usd * tBps) / 10_000;
        if (curDebt <= targetDebt + (e0Usd * bandBps) / 10_000) return 0;
        return curDebt - targetDebt;
    }

    /// @notice (WBTC-mode) Lever-UP for a WBTC-collateral BTC position: borrow stable → SOR to WBTC → supply — the
    ///         EXACT 4-step custody, all in the delegatecall context (== the manager). ON-CHAIN oracle floor (WBTC
    ///         value − `slipBps`) so `BtcLevManager.rebalanceWbtc` is anti-sandwich even when permissionless. `usd`
    ///         is the debt-delta (USD18). Returns (borrowed, wbtcBought) for the manager to emit. Byte lives HERE so
    ///         the manager stays under EIP-170 (mirrors how the ETH lever mechanics live in this lib).
    /// @dev (WBTC-mode) config bundle — keeps the leg fns under the no-via_ir 16-slot stack limit (6 params, not 9).
    struct WbtcCfg { address aux; address wbtc; uint32 twapWindow; uint16 slipBps; }

    function leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint256 usd, uint256 minOut, WbtcCfg memory cfg)
        public returns (uint256 borrowed, uint256 wbtcBought) {
        borrowed = venue.borrow(lp, _fromUsd(cfg.aux,stable, usd));                       // stable → manager (delegatecall ctx)
        if (borrowed == 0) return (0, 0);
        {   // anti-sandwich oracle floor — own frame so the local releases (stack)
            uint256 floorWbtc = (usd * 1e18 / IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow))
                                * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorWbtc) minOut = floorWbtc;
        }
        IERC20Min(stable).approve(cfg.aux, borrowed);
        wbtcBought = IAux(cfg.aux).sorSelfFunded(stable, borrowed, cfg.wbtc, minOut); // SOR → WBTC → manager
        IERC20Min(cfg.wbtc).transfer(address(venue), wbtcBought);                 // manager → venue
        venue.supply(lp, wbtcBought);                                            // venue → escrow
    }

    /// @notice (WBTC-mode) De-lever: withdraw `repayUsd`-worth WBTC → reverse-SOR to stable → repay (clamp-before-
    ///         transfer). ON-CHAIN oracle floor (anti-sandwich). DIRECT — health-safe at the IL-target LTV. Returns
    ///         (pulled, repaid) for the manager to emit.
    function deleverWbtc(ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, WbtcCfg memory cfg)
        public returns (uint256 pulled, uint256 repaid) {
        if (repayUsd == 0) return (0, 0);
        uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow);    // USD18 per 1e18 WBTC-raw
        pulled = venue.withdraw(lp, repayUsd * 1e18 / px);                        // WBTC → manager (venue caps at position/health)
        if (pulled == 0) return (0, 0);
        {   // anti-sandwich oracle floor — own frame
            uint256 floorStable = _fromUsd(cfg.aux,stable, pulled * px / 1e18) * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorStable) minOut = floorStable;
        }
        IERC20Min(cfg.wbtc).approve(cfg.aux, pulled);
        uint256 got = IAux(cfg.aux).sorSelfFundedReverse(cfg.wbtc, stable, pulled, minOut); // WBTC → stable → manager
        { uint256 debt = venue.debtOf(lp); if (got > debt) got = debt; }          // never over-repay — own frame
        if (got == 0) return (pulled, 0);
        IERC20Min(stable).transfer(address(venue), got);
        repaid = venue.repay(lp, got);
    }

    /// @notice (WBTC-mode) FLASH-repay-first de-lever settle (mirror of LevManager._deleverSettle) — runs inside the
    ///         manager's `onMorphoFlashLoan` callback with `assets` flashed stable in hand: repay the LP's debt FIRST
    ///         (LTV drops ⇒ the withdraw is ALWAYS health-safe — kills the direct path's near-liq limitation), withdraw
    ///         the freed WBTC (grossed up by the slippage buffer so the sale covers `assets`), reverse-SOR to stable
    ///         (ON-CHAIN oracle floor), return exactly `assets` to the flash provider (zero-fee pull-back), and hand any
    ///         realized surplus to the LP. Body HERE (delegatecall) so the manager's callback stays thin under EIP-170.
    function flashDeleverWbtcSettle(uint256 assets, address lp, address venueAddr, address stable,
                                    uint256 minOut, address flashProvider, WbtcCfg memory cfg) public {
        ILevVenue venue = ILevVenue(venueAddr);
        IERC20Min(stable).transfer(address(venue), assets);
        uint256 pulled;
        {   // repay-FIRST → size + withdraw the freed WBTC → oracle floor (own frame for the stack, no via_ir)
            uint256 repaid = venue.repay(lp, assets);                            // == assets (capped ≤ debt upstream)
            uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow);
            pulled = venue.withdraw(lp, (_toUsd18(cfg.aux,stable, repaid) * 1e18 / px) * 10_000 / (10_000 - cfg.slipBps));
            uint256 floorStable = _fromUsd(cfg.aux,stable, pulled * px / 1e18) * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorStable) minOut = floorStable;
        }
        IERC20Min(cfg.wbtc).approve(cfg.aux, pulled);
        uint256 stableOut = IAux(cfg.aux).sorSelfFundedReverse(cfg.wbtc, stable, pulled, minOut);
        IERC20Min(stable).approve(flashProvider, assets);                        // provider pulls `assets` back; short approve ⇒ whole op reverts (underwater-safe)
        if (stableOut > assets) IERC20Min(stable).transfer(lp, stableOut - assets); // realized surplus → LP
    }

    /// @notice Net-equity in BASE-asset units (1e18) = `collBase − debtUsd/pxBase`, floored at 0.
    ///         `collBase` is collateral ALREADY in base units (ETH or BTC); `debtUsd` is 1e18 USD;
    ///         `pxBase` is USD per 1 base (1e18). `debt==0 ⇒ collBase`; `px==0 ⇒ 0` (dead oracle,
    ///         the conservative side — no phantom credit). Identical to `LevManager._netEquityEthAt`
    ///         tail (with `collBase` = weETH→ETH pre-computed by the caller).
    function netEquityBase(uint256 collBase, uint256 debtUsd, uint256 pxBase)
        internal pure returns (uint256)
    {
        if (debtUsd == 0) return collBase;
        if (pxBase == 0) return 0;
        uint256 debtBase = (debtUsd * WAD) / pxBase;
        return collBase > debtBase ? collBase - debtBase : 0;
    }

    /// @notice USD (1e18) value of a BAND-ONLY E0 base amount: `e0Base · pxBase / 1e18`. `e0Base` is the LP's
    ///         unlevered band deposit in BASE units (ETH 1e18, or BTC 8-dec sats), `pxBase` is USD-per-base
    ///         (1e18; WBTC-lifted ×1e10 on the BTC side, so the SAME `/1e18` yields 18-dec USD for both). This
    ///         is the SINGLE scale layer both managers value E0 through — the exact site the BTC 1e10 mis-scale
    ///         (`/1e8`) lived in; centralized here so the decimals can never drift between the two managers again.
    function e0Usd(uint256 e0Base, uint256 pxBase) internal pure returns (uint256) {
        return (e0Base * pxBase) / WAD;
    }

    /// @notice Debt-backed BUFFER-leg USD (6-dec) for a band-reconcile buffer of `bufBase` volatile units at band
    ///         price `pxBase` (USD/base, 1e18), CAPPED at the LP's OWN debt (`debtUsd`, 1e18). The debt-funded
    ///         buffer is fee-earning DEPTH, never equity, and is bounded by the LP's own debt BY CONSTRUCTION — the
    ///         exact `min((bufBase·px/1e18)/1e12, debtUsd/1e12)` that BOTH band-reconcile buffer legs applied
    ///         inline (ETH `VogueLib.levAddBuf`, BTC `VaultLib._bufUsdBtc`). Centralized here — like `e0Usd` — so
    ///         the buffer cap + its 6-dec scaling can never drift between the two paths. `bufBase` is ETH-1e18 or
    ///         BTC-8dec-sats; `pxBase` is WBTC-lifted ×1e10 on the BTC side, so the SAME `/1e18` yields 18-dec USD
    ///         for both before the shared `/1e12` to 6-dec (identical to the two former inline computations).
    function capBufferUsd(uint256 bufBase, uint256 pxBase, uint256 debtUsd) internal pure returns (uint256 bufUsd) {
        bufUsd = ((bufBase * pxBase) / WAD) / 1e12;
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
        address coll = ILevVenueColl(v).COLLATERAL();
        if (coll != c0 && coll != c1) revert BadCollateral();
        return ILevVenueColl(v).stable() == base;
    }

    /// @notice Gate a NEW levered open: the venue must be on the frozen allowlist AND not incident-flagged
    ///         (GOV `setVaultHealth`). Fresh collateral must never land on a de-allowlisted or broken market. Only
    ///         OPEN is gated -- close/rebalance stay open so the keeper can always unwind OUT of a blocked venue.
    function requireOpenable(bool allowed, address aux, address venue) public view {
        if (!allowed) revert VenueNotAllowed();
        if (IAux(aux).vaultBlocked(venue)) revert VenueBlocked();
    }


    error NoOptIn();
    error Slippage();
    error NotNearLiq();
    error NoDebt();
    /// Protect only a position within PROTECT_MARGIN_BPS (LTV) of its venue liquidation threshold — anti-grief
    /// (a healthy, low-LTV LP can never be force-redeemed); mirrors the cascade de-lever trigger band.
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
    uint256 internal constant SELL_SLIP_BPS      = 100;                                           // 1% anti-MEV floor
    uint256 internal constant DELEVER_GAS        = 400_000;                                       // conservative de-lever crank gas
    uint256 internal constant KEEPER_MAX_GASPRICE = 200 gwei;                                     // anti-grief gasprice ceiling

    /// The manager's runtime addresses + the crank's keeper + the live WETH gas-reserve, threaded into the moved fns.
    struct SellCtx { address weth; address weeth; address aux; address keeper; uint256 reserveIn; }

    /// @notice Sell `pulled` collateral → `stable` at the anti-MEV oracle floor, peeling the keeper's gas (native ETH)
    ///         from the over-collateralization headroom. `isWethVenue` ⇒ `pulled` is already WETH; else weETH.
    /// @return stableOut stable delivered (the flash pull-back + LP surplus come from this). @return reserveOut new gas-reserve.
    function sellColl(SellCtx memory c, bool isWethVenue, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        public returns (uint256 stableOut, uint256 reserveOut)
    {
        if (!isWethVenue) return sellWeeth(c, stable, pulled, minOut, assets);
        reserveOut = c.reserveIn;
        // Peel the keeper-gas sliver (WETH) from headroom BEFORE selling — never the flash-repay amount.
        uint256 need = _wethForAssets(c, stable, assets);
        uint256 skimmed;
        (skimmed, reserveOut) = _reimburse(c.weth, c.keeper, pulled > need ? pulled - need : 0, reserveOut);
        pulled -= skimmed;
        // WETH branch: floor at the ETH oracle value of what's LEFT (WETH==ETH, 1:1) − MAX_SLIPPAGE.
        uint256 usd18 = (pulled * IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M)) / 1e18;
        uint256 floorOut = (_fromUsd(c.aux, stable, usd18) * (10_000 - SELL_SLIP_BPS)) / 10_000;
        uint256 useMin = minOut > floorOut ? minOut : floorOut;
        stableOut = _wethToStableDex(c, stable, pulled, useMin);
    }

    /// weETH → WETH (Curve pool) → peel keeper gas →
    /// WETH → stable. The weETH→WETH acquisition is its OWN frame (`_weethToWeth`) so the peel below fits the stack.
    function sellWeeth(SellCtx memory c, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        internal returns (uint256 stableOut, uint256 reserveOut)
    {
        reserveOut = c.reserveIn;
        uint256 wethGot = _weethToWeth(c, pulled);
        uint256 floorOut = _stableFloor(c, stable, pulled);
        { // peel from headroom (own frame — no via_ir), then scale the anti-MEV floor to the post-peel amount.
            uint256 need = _wethForAssets(c, stable, assets);
            uint256 wethBefore = wethGot;
            uint256 skimmed;
            (skimmed, reserveOut) = _reimburse(c.weth, c.keeper, wethGot > need ? wethGot - need : 0, reserveOut);
            wethGot -= skimmed;
            if (wethGot < wethBefore) floorOut = (floorOut * wethGot) / wethBefore;
        }
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


    function _weethToWethDex(SellCtx memory c, uint256 pulled) internal returns (uint256) {
        uint256 wethFloor = IWeETH(c.weeth).getEETHByWeETH(pulled) * (10_000 - SELL_SLIP_BPS) / 10_000;
        IERC20Min(c.weeth).approve(ETHERFI_CURVE_POOL, pulled);
        try ICurvePool(ETHERFI_CURVE_POOL).exchange(int128(1), int128(0), pulled, wethFloor) returns (uint256 out) {
            return out;
        } catch { IERC20Min(c.weeth).approve(ETHERFI_CURVE_POOL, 0); return 0; }
    }

    /// stable → collateral (lever-up BUY). weETH venue mints via ether.fi; WETH venue supplies WETH directly.
    function stableToColl(SellCtx memory c, bool isWethVenue, address stable, uint256 stableAmt, uint256 minOut)
        public returns (uint256)
    {
        if (!isWethVenue) return _stableToWeeth(c, stable, stableAmt, minOut);
        uint256 wethGot = _stableToWethSor(c, stable, stableAmt);
        if (wethGot < minOut) revert Slippage();
        return wethGot;
    }

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
    ///      close (`_wethToStableDex`), each paying our in-band fee PLUS the external venue fee PLUS
    ///      slippage — a double charge, twice per round trip, to reach an asset we could have
    ///      borrowed directly. The collateral is weETH, the exposure hedged is ETH-denominated and
    ///      the exit needs WETH; the stable is a detour with a toll at both ends.
    ///      This short-circuit makes the lever WETH-LOAN-READY with zero behaviour change while the
    ///      market still lends a stable. Registering a weETH-collateral / WETH-loan market then
    ///      removes both legs by itself.
    function _stableToWethSor(SellCtx memory c, address stable, uint256 stableAmt) internal returns (uint256) {
        if (stable == c.weth) return stableAmt;          // loan token IS WETH — nothing to convert
        uint256 wethFloor = (_toUsd18(c.aux,stable, stableAmt) * 1e18 / IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M))
            * (10_000 - SELL_SLIP_BPS) / 10_000;
        IERC20Min(stable).approve(c.aux, stableAmt);
        return IAux(c.aux).sorSelfFunded(stable, stableAmt, c.weth, wethFloor);
    }

    /// @dev IDENTITY WHEN THE LOAN TOKEN IS ALREADY WETH — the close-side twin of the note on
    ///      `_stableToWethSor`. `minOut` is unused on that branch because no trade occurs.
    function _wethToStableDex(SellCtx memory c, address stable, uint256 wethIn, uint256 minOut) internal returns (uint256) {
        if (stable == c.weth) return wethIn;              // loan token IS WETH — nothing to convert
        IERC20Min(c.weth).approve(c.aux, wethIn);
        return IAux(c.aux).sorSelfFundedReverse(c.weth, stable, wethIn, minOut);
    }

    function _stableFloor(SellCtx memory c, address stable, uint256 weethAmt) internal returns (uint256) {
        uint256 usd18 = (IWeETH(c.weeth).getEETHByWeETH(weethAmt) * IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M)) / 1e18;
        return (_fromUsd(c.aux,stable, usd18) * (10_000 - SELL_SLIP_BPS)) / 10_000;
    }

    /// The WETH that must remain to repay `assets` (flashed stable) at worst-case slippage — above it is skimmable headroom.
    function _wethForAssets(SellCtx memory c, address stable, uint256 assets) internal returns (uint256) {
        uint256 weth = (_toUsd18(c.aux,stable, assets) * 1e18) / IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M);
        return (weth * 10_000) / (10_000 - SELL_SLIP_BPS);
    }

    /// @notice Self-funding keeper-gas — external entry for the manager's direct reimburse points (BOLD-close
    ///         WETH equity, protect). Delegatecall ⇒ WETH unwrapped + ETH sent are the MANAGER's. See `_reimburse`.
    function reimburseKeeper(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        public returns (uint256 skimmed, uint256 reserveOut)
    {
        return _reimburse(weth, keeper, availWeth, reserveIn);
    }

    /// The manager's runtime addresses + gas-reserve, threaded into `extractToVaultBody` (delegatecall) and
    /// returned updated. `maxSlippageBps` grosses the collateral withdraw so the sale covers the flash even at
    /// worst execution; `isWethVenue` selects WETH-1:1 vs weETH-rate collateral units.
    struct ExtractCfg { address weth; address weeth; address aux; address flashProvider; address keeper; uint256 gasReserve; uint16 maxSlippageBps; bool isWethVenue; }

    /// @dev Repay-first + withdraw the paired collateral, in its OWN frame so `extractToVaultBody`'s stack stays
    ///      shallow (no via_ir). Flashed `assets` → venue → repay; then withdraw collateral worth (repaid +
    ///      extractUsd) of ETH, grossed by max slippage so the sale covers the flash at worst execution. WETH
    ///      venue = 1:1 ETH; weETH venue = via the ether.fi rate.
    function _pullForExtract(uint256 assets, address lp, address venueAddr, address stable, uint256 extractUsd, ExtractCfg memory cfg)
        private returns (uint256 pulled)
    {
        IERC20Min(stable).transfer(venueAddr, assets);
        uint256 repaid = ILevVenue(venueAddr).repay(lp, assets);
        uint256 ethAmt = ((_toUsd18(cfg.aux,stable, repaid) + extractUsd) * 1e18) / IAux(cfg.aux).getTWAPforAsset(cfg.weth, TWAP_WIN_M);
        uint256 collUnits = cfg.isWethVenue ? ethAmt : (ethAmt * 1e18) / IWeETH(cfg.weeth).getEETHByWeETH(1e18);
        collUnits = (collUnits * 10_000) / (10_000 - cfg.maxSlippageBps);
        pulled = ILevVenue(venueAddr).withdraw(lp, collUnits);
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
        return _sellAndRoute(pulled, stable, minOut, assets, vault, cfg);
    }

    /// @dev Sell the withdrawn collateral (oracle-floored on `assets`: reverts unless stableOut ≥ assets ⇒ flash
    ///      always repayable), return `assets` to the flash (zero-fee pull-back), route the value-neutral surplus to
    ///      the redeem sink `vault`. Own frame purely for the non-via_ir stack budget of `extractToVaultBody`.
    function _sellAndRoute(uint256 pulled, address stable, uint256 minOut, uint256 assets, address vault, ExtractCfg memory cfg)
        internal returns (uint256 newGasReserve, uint256 freed)
    {
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve});
        uint256 stableOut;
        (stableOut, newGasReserve) = sellColl(sc, cfg.isWethVenue, stable, pulled, minOut, assets);
        IERC20Min(stable).approve(cfg.flashProvider, assets);
        freed = stableOut > assets ? stableOut - assets : 0;
        if (freed > 0) IERC20Min(stable).transfer(vault, freed);
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
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve});
        wethDelivered = cfg.isWethVenue ? collAmt : _weethToWeth(sc, collAmt);
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
        uint256 collInEth = cfg.isWethVenue ? coll : IWeETH(cfg.weeth).getEETHByWeETH(coll);
        uint256 pull = collInEth == 0 ? 0 : (freeEth >= collInEth ? coll : (coll * freeEth) / collInEth);
        if (pull == 0) return 0;
        uint256 got = venue.withdraw(lp, pull);                                   // collateral → the manager
        uint256 floor = minWethOut;
        { uint256 f = (freeEth * (10_000 - cfg.maxSlippageBps)) / 10_000; if (f > floor) floor = f; } // MEV floor
        wethDelivered = collToWethDeliver(got, recipient, floor, cfg);
    }

    /// The manager's runtime addresses + the two WETH reserves the BOLD-close leg reads/writes, threaded into
    /// `onFlashMintBody` (delegatecall) and returned updated so the thin forwarder can write them back.
    struct FlashMintCfg { address weth; address aux; address flashProvider; address keeper; uint256 boldReserve; uint256 gasReserve; }

    /// @notice mode-1 (BOLD) flash-mint close body — VERBATIM of LevManager._onFlashMint, moved here (public,
    ///         delegatecall-linked, bytecode OUTSIDE the manager) so the manager fits EIP-170. Runs in the
    ///         MANAGER's context (address(this)==manager). Flashed `wethFlashed` WETH in hand: mint `repayBold`
    ///         BOLD at face value via the venue's protocol trove, repay the LP's own trove, and settle the WETH
    ///         flash — the LP gets FULL fair equity and the protocol funds the Liquity over-collateralization from
    ///         `boldReserve` (becomes the protocol trove's own equity). Depth-independent at any size.
    /// @return newBoldReserve boldCloseReserve after funding the over-collateralization. @return newGasReserve gas-reserve after the keeper peel.
    function onFlashMintBody(uint256 wethFlashed, address lp, address venueAddr, address stable, uint256 repayBold, FlashMintCfg memory cfg)
        public returns (uint256 newBoldReserve, uint256 newGasReserve)
    {
        uint256 fairDebtWeth;
        uint256 freed;
        {   // 1. Mint `repayBold` BOLD against the flashed WETH (pushed to the venue), from the protocol trove. Liquity's
            //    one-time WETH gas compensation on the protocol trove's first open is covered by the venue's own
            //    gas-comp buffer (seeded at deploy), the same buffer that funds LP-trove opens — never the flash/LP.
            uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.weth, TWAP_WIN_M);
            IERC20Min(cfg.weth).transfer(venueAddr, wethFlashed);
            uint256 minted = ILevMintVenue(venueAddr).mintForClose(wethFlashed, repayBold);
            fairDebtWeth = (_toUsd18(cfg.aux,stable, minted) * 1e18) / px;          // fair WETH value of the BOLD repaid
            // 2. Repay the LP's trove. Liquity returns ALL of its collateral here if this repay CLOSES the trove (full
            //    close); a partial de-lever returns nothing yet → we withdraw the LP's fair slice next.
            uint256 wBefore = IERC20Min(cfg.weth).balanceOf(address(this));
            IERC20Min(stable).transfer(venueAddr, minted);
            ILevVenue(venueAddr).repay(lp, minted);
            freed = IERC20Min(cfg.weth).balanceOf(address(this)) - wBefore;
        }
        // 3. Partial de-lever (trove still open): withdraw the LP's FAIR freed WETH (= value of the BOLD repaid,
        //    NOT grossed up — no sale). Equity-neutral: −BOLD debt, −(its fair WETH). Full close already returned all.
        if (freed == 0 && (ILevVenue(venueAddr).debtOf(lp) > 0 || ILevVenue(venueAddr).collateralOf(lp) > 0))
            freed = ILevVenue(venueAddr).withdraw(lp, fairDebtWeth);
        // 4. Settle: repay `wethFlashed` to Morpho + pay the LP `freed − fairDebtWeth` (their equity on a full close;
        //    0 on a partial). The gap = `wethFlashed − fairDebtWeth` = the over-collateralization the protocol
        //    funds from the reserve (becomes the protocol trove's equity). Fail-closed if the reserve is short.
        {
            uint256 overColl = wethFlashed > fairDebtWeth ? wethFlashed - fairDebtWeth : 0;
            require(cfg.boldReserve >= overColl, "bold-close: reserve");
            newBoldReserve = cfg.boldReserve - overColl;
        }
        IERC20Min(cfg.weth).approve(cfg.flashProvider, wethFlashed);        // Morpho pulls exactly this back
        uint256 lpDue = freed > fairDebtWeth ? freed - fairDebtWeth : 0;
        uint256 skimmed;
        (skimmed, newGasReserve) = _reimburse(cfg.weth, cfg.keeper, lpDue, cfg.gasReserve); // keeper gas from the freed WETH equity (native ETH)
        lpDue -= skimmed;
        if (lpDue > 0) IERC20Min(cfg.weth).transfer(lp, lpDue);            // LP's fair equity (full close) / 0 (partial)
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
        IERC20Min(stable).transfer(venue, pay);                    // venue.repay expects it already transferred in
        repaid = ILevVenue(venue).repay(lp, pay);                // manager is the venue's authorized MANAGER
        if (got > pay) IERC20Min(stable).transfer(lp, got - pay);  // refund the un-needed portion to the LP
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
            IERC20Min(s).approve(aux, bal);
            try IAux(aux).sorSelfFunded(s, bal, target, floor) returns (uint256) {}
            catch { IERC20Min(s).approve(aux, 0); }   // slice unmoved -> refunded to the LP below
            // If BOTH routes failed to move this slice (no pool at all), refund it to the LP — never strand the
            // LP's own redeemed value in the manager (it only lowers `got`, which the aggregate floor already guards).
            uint256 rem = IERC20Min(s).balanceOf(address(this));
            if (rem > 0) IERC20Min(s).transfer(lp, rem);
        }
    }

    /// @notice Debt delta (USD 1e18) + direction to re-hit `targetBps` LTV, given the position's
    ///         collateral value (`collUsd`) and current debt (`curDebtUsd`). Inside `±bandBps` of
    ///         target ⇒ `(false, 0)`. Identical to `LevManager.debtDeltaToTarget` tail.
    function debtDelta(uint256 collUsd, uint256 curDebtUsd, uint256 targetBps, uint256 bandBps)
        internal pure returns (bool levUp, uint256 amountUsd)
    {
        uint256 cur = ltvBps(curDebtUsd, collUsd);
        if (cur + bandBps >= targetBps && cur <= targetBps + bandBps) return (false, 0); // in band
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
        uint256 collInEth = cfg.isWethVenue ? coll : IWeETH(cfg.weeth).getEETHByWeETH(coll); // net-equity == collateral (0 debt)
        if (collInEth == 0) return 0;
        uint256 pull = wethWanted >= collInEth ? coll : (coll * wethWanted) / collInEth;
        if (pull == 0) return 0;
        uint256 got = venue.withdraw(lp, pull);                                    // net-equity collateral → the manager
        uint256 floor = minWethOut;
        { uint256 pullEth = (collInEth * got) / coll;                              // ETH value of the withdrawn collateral
          uint256 f = (pullEth * (10_000 - cfg.maxSlippageBps)) / 10_000; if (f > floor) floor = f; }  // MEV floor
        wethDelivered = collToWethDeliver(got, recipient, floor, cfg);
    }

    /// @notice §M.1 ETH SWAP-OUT delivery-side de-lever body — repay `stableUsd`-worth of the LP's debt with the
    ///         stable the Vault pre-transferred to the venue, then free EXACTLY the repaid value of collateral and
    ///         deliver it as WETH (value-neutral). VERBATIM of the manager's former inline `swapOutDelever` tail.
    ///         @return usedUsd USD 1e18 actually applied to the debt. @return wethDelivered WETH handed to `recipient`.
    function swapOutDeleverBody(ILevVenue venue, address lp, uint256 stableUsd, address recipient, uint256 minWethOut, uint256 pxWeth, ExtractCfg memory cfg)
        public returns (uint256 usedUsd, uint256 wethDelivered) {
        usedUsd = _repayPretransferred(venue, lp, stableUsd, cfg.aux);                     // repay-with-Vault-pre-transferred (own frame)
        if (usedUsd > 0) wethDelivered = freeAndDeliverBody(venue, lp, usedUsd, recipient, minWethOut, pxWeth, cfg);
    }

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
    function sizeRepayStable(ILevVenue venue, address lp, uint256 extractUsd, uint256 debtUsd18, uint256 pxWeth, bool isWethVenue, address weeth, address aux)
        public view returns (uint256 repayStable) {
        uint256 rawColl = venue.collateralOf(lp);
        uint256 collUsd = ((isWethVenue ? rawColl : IWeETH(weeth).getEETHByWeETH(rawColl)) * pxWeth) / 1e18;
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
        uint256 pulled = _repayAndFreeBody(assets, lp, venueAddr, stable, pxWeth, cfg);   // repay-first + withdraw (own frame)
        return _sellAndReturn(pulled, stable, minOut, assets, lp, cfg);                   // sell + return-flash + surplus→LP (own frame)
    }

    /// @dev Repay `lp`'s debt with the flashed `assets` FIRST (LTV drops ⇒ the withdraw is always health-safe), then
    ///      withdraw the freed collateral grossed up by the slippage buffer so the sale covers `assets`. Own frame so
    ///      `deleverSettleBody`'s stack stays shallow (no via_ir). VERBATIM of the manager's former `_repayAndFree`.
    function _repayAndFreeBody(uint256 assets, address lp, address venueAddr, address stable, uint256 pxWeth, ExtractCfg memory cfg)
        private returns (uint256 pulled) {
        IERC20Min(stable).transfer(venueAddr, assets);
        uint256 repaid = ILevVenue(venueAddr).repay(lp, assets);                 // == assets (capped ≤ debt upstream)
        if (pxWeth == 0) revert NoPrice();     // see the note above — never panic on a zero anchor
        uint256 ethAmt = (_toUsd18(cfg.aux,stable, repaid) * 1e18) / pxWeth;
        uint256 collUnits = cfg.isWethVenue ? ethAmt : (ethAmt * 1e18) / IWeETH(cfg.weeth).getEETHByWeETH(1e18);
        pulled = ILevVenue(venueAddr).withdraw(lp, (collUnits * 10_000) / (10_000 - cfg.maxSlippageBps));
    }

    /// @dev Sell the freed collateral (oracle-floored on `assets` ⇒ flash always repayable), return `assets` to the
    ///      flash provider, hand the realized surplus to `lp`. Own frame for the non-via_ir stack budget.
    function _sellAndReturn(uint256 pulled, address stable, uint256 minOut, uint256 assets, address lp, ExtractCfg memory cfg)
        private returns (uint256 newGasReserve) {
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve});
        uint256 stableOut;
        (stableOut, newGasReserve) = sellColl(sc, cfg.isWethVenue, stable, pulled, minOut, assets);
        // Return `assets` to Morpho (approve the zero-fee pull-back) + surplus to the LP. stableOut < assets ⇒ short
        // approve ⇒ Morpho's pull reverts the whole op (underwater-safe).
        IERC20Min(stable).approve(cfg.flashProvider, assets);
        if (stableOut > assets) IERC20Min(stable).transfer(lp, stableOut - assets);
    }

    /// @notice De-lever `lp` by flashing `repayUsd`-worth of the debt stable (repay-first, mode-0) — or, for a
    ///         mint-close (BOLD/Liquity) venue, flashing WETH sized to mint the BOLD at the protocol trove's safe
    ///         LTV (mode-1). VERBATIM of the manager's former `_deleverFlash`+`_deleverMint`; reuses `ExtractCfg`
    ///         (weth/aux/flashProvider). `protocolMintLtvBps` = the safe LTV the protocol trove mints BOLD at.
    function deleverFlashBody(ExtractCfg memory cfg, ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 protocolMintLtvBps)
        public {
        if (repayUsd == 0 || cfg.flashProvider == address(0)) return;
        uint256 debt = venue.debtOf(lp);
        if (debt == 0) return;
        uint256 repayStable = _fromUsd(cfg.aux,stable, repayUsd);
        if (repayStable > debt) repayStable = debt;                              // never flash more than we can repay
        if (repayStable == 0) return;
        if (_isMintVenueM(address(venue))) {
            // BOLD/Liquity: flash WETH grossed up to mint `repayStable` BOLD at the protocol trove's safe LTV (so the
            // flash covers the over-collateralization), finish in the manager's mode-1 callback (_onFlashMint).
            uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.weth, TWAP_WIN_M);    // USD 1e18 / WETH
            uint256 wethToFlash = ((_toUsd18(cfg.aux,stable, repayStable) * 1e18 / px) * 10_000) / protocolMintLtvBps;
            IMorphoFlash(cfg.flashProvider).flashLoan(cfg.weth, wethToFlash, abi.encode(uint8(1), lp, address(venue), stable, repayStable));
            return;
        }
        // mode 0 = the generic flash-the-stable → repay → withdraw → sell → return path.
        IMorphoFlash(cfg.flashProvider).flashLoan(stable, repayStable, abi.encode(uint8(0), lp, address(venue), stable, minOut));
    }

    /// try/catch mint-close detection — every non-BOLD venue lacks the marker ⇒ false ⇒ the generic flash-stable path.
    function _isMintVenueM(address venue) private view returns (bool) {
        try ILevMintVenue(venue).usesMintClose() returns (bool m) { return m; } catch { return false; }
    }

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
