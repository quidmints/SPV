// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "./Types.sol";
// §E266 — Morpho VAULTS V2 is a different protocol from Blue; import ITS interface rather than
// restating three signatures. A hand-rolled restatement is what drifts silently.
import {IVaultV2} from "./Interfaces.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {SwapLib} from "./SwapLib.sol";
import {LevMath} from "./LevMath.sol";
// §A.52: the SHARED WETH view (was a file-local `IWETH_VG` restating the same members).
import {IWETH9} from "./Interfaces.sol";
// §A.52: ONE canonical Quid view (was two file-local variants, `IQuid_VG` + `IQuidView_VG`).
import {ICore} from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
// §VAULTLIB-FOLD — imports carried in with the merged bodies
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IEtherFiLiquidityPool} from "./Interfaces.sol";   // §E57: the shared OfframpCfg shape (declared there;  still uses it)
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IWeETH} from "./Interfaces.sol";
import {ICurvePool} from "./Interfaces.sol";
import {IDepositAdapter} from "./Interfaces.sol";

// ── Minimal external surfaces the extracted Quid bodies touch. The library is
//    DELEGATECALL'd (public fns), so `address(this)` is Quid: every immutable
//    Quid reads (V4/AUX/WETH/QUID/EV) is passed in via a cfg struct or an
//    interface handle; reference-type state (LP Deposit + the levPooled/
//    levBufferUsd/ethfiBacked/aaveBacked mappings) is passed by STORAGE REF so
//    writes land on Quid's slots. Value-type state (lpShares) is mutated by
//    RETURNING the delta, applied by the thin Quid forwarder. ─────────────────
/// @title  QuidLib — sizeable Quid bodies extracted to free bytecode under the
///         EIP-170 limit. DELEGATECALL'd by Quid (public fns): inside each,
///         `address(this)`/`msg.sender`/`msg.value` are Quid's, so token custody
///         and external calls leave from Quid exactly as the former in-Quid
///         bodies did. Byte-for-byte semantics; only the home moved.
// §VAULTLIB-FOLD — file-level interface carried across with the merged bodies. My first pass
// extracted only the lines BETWEEN `library VaultLib {` and its closing brace, so a declaration
// living OUTSIDE the library block was invisible to it — the merge compiled everywhere except
// the one body that used this, three files from where the mistake was made.


library QuidLib {

    /// A chosen venue placed 0 — paused / unwired / de-allowlisted. We do NOT silently redirect to a
    /// fallback venue: no venue can be assumed always-live. Fail loud — the depositor picks a live one.
    error VenueUnavailable();

    /// @dev DIRECT weETH, always: it earns the full ether.fi staking rate.
    function _supplyEtherFi(address ev, uint amount) private returns (uint placed) {
        placed = IEthVenue(ev).supplyEtherFi(amount);
    }

    // Mirror Quid's selectors (name-derived) for the delegatecalled bodies.
    error InsufficientBalance();
    error NotOwner();
    error BadPercent();
    error Dust();

    // ════════════════════════════════════════════════════════════════════
    //  IL-protect: ETH levered range slice (full-2x fee lane). Bodies of
    //  Quid._reconcileLev's legs extracted. Reference state passed by storage
    //  ref; the value-type lpShares delta is returned as (added, burned) and the
    //  Quid forwarder applies `lpShares += added - burned`.
    // ════════════════════════════════════════════════════════════════════

    /// @dev Quid immutables the levered-range bodies touch.
    // §RANGE-MERGE — the local `LevCfg`/`LevP` moved to `Types.RangeCfg`/`Types.RangeP`, shared with the BTC
    // side. They were the same structs; only the asset field's name and `lm` vs `mgr` differed.

    function levManager(address aux) public view returns (address) {
        address host = aux == address(0) ? address(0) : IAux(aux).ethVenue();
        return host == address(0) ? address(0) : IEthVenue(host).LEV_MANAGER();
    }
    function bufTarget(address lm, address lp) public view returns (uint) {
        return lm == address(0) ? 0 : ILevEquity(lm).debtUsd(lp) / 1e12; // 1e18 USD -> 6-dec
    }

    /// @notice Burn the current slice then re-add the gross target as two legs.
    ///         NET model: `pooled`/`lpShares` carry ONLY the net-equity leg; the debt-funded
    ///         buffer is depth (fee weight + V4) tracked in `levBuf`/`totalBuffer`. Returns the
    ///         NET lpShares deltas (addedNet, burnedNet) AND the buffer deltas (bufAdded, bufBurned)
    ///         for the Quid forwarder to apply (lpShares += addedNet - burnedNet; totalBuffer += ...).
    function reconcileLegs(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.RangeP memory p
    ) public returns (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) {
        if (levPooled[lp] > 0 || levBuf[lp] > 0)
            (burnedNet, bufBurned) = RangeLib.levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        if (p.gross > 0)
            (addedNet, bufAdded) = RangeLib.levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
    }

    /// @dev Burn `lp`'s ENTIRE levered slice tokenlessly (no delivery). Burns the GROSS depth
    ///      (net leg `levPooled` + buffer `levBuf`) from V4; the net leg leaves `pooled`/`lpShares`,
    ///      the buffer leaves `totalBuffer` (via the bufBurned return) — a liquidation leaves the
    ///      basket intact.

    /// @dev Add `lp`'s full-2x slice as TWO legs: net-equity (goes into pooled/lpShares) + the
    ///      debt-funded buffer (goes into levBuf/totalBuffer, NOT equity). Returns (addedNet, bufAdded).

    /// @dev NET-equity leg — basket-surplus USD. Grows pooled/lpShares (equity) + levPooled (the
    ///      unwind-only net slice) + V4 depth.

    /// @dev BUFFER leg — the debt-funded half. It is fee-earning V4 DEPTH but NOT equity, so it grows
    ///      levBuf (fee weight + totalBuffer via the return) and the V4 position, but NOT pooled/lpShares.
    ///      USD = buffer collateral at range price, CAPPED at the LP's OWN debt (debt-backed; folds into POOLED_USD).

    // ════════════════════════════════════════════════════════════════════
    //  ETH-venue deposit routing (body of Quid._depositETH). DELEGATECALL'd:
    //  msg.value/address(this) are Quid's, so the WETH wrap + venue placement
    //  leave from Quid. The per-LP wall attribution (ethfiBacked/aaveBacked) is
    //  written via STORAGE REF. Byte-identical to the former in-Quid body.
    // ════════════════════════════════════════════════════════════════════
    function depositETH(
        address weth, address aux, address ev,
        address sender, address pledge, uint amount
    ) public returns (uint sent) {
        if (msg.value > 0) {
            IWETH9(weth).deposit{value: msg.value}();
            sent = msg.value; amount -= Math.min(amount, msg.value);
        }
        if (amount > 0) {
            uint available = Math.min(
                IWETH9(weth).allowance(sender, address(this)),
                IWETH9(weth).balanceOf(sender));
            uint took = Math.min(amount, available);
            if (took > 0) { IWETH9(weth).transferFrom(sender, address(this), took); sent += took; }
        }
        if (sent > 0) {
            // ONE DESTINATION: every ETH deposit becomes weETH. No venue choice, no default, no dispatch.
            uint toDeposit = IWETH9(weth).balanceOf(address(this));
            IWETH9(weth).approve(aux, toDeposit);
            bool attrib = pledge != address(0);
            uint placed = _supplyEtherFi(ev, toDeposit);
            if (placed == 0) revert VenueUnavailable();   // chosen venue placed nothing ⇒ paused/unwired ⇒ NO fallback
            attrib;
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  θ / LVR / realized-vol math (bodies of Quid._kLvrWad, realizedAlphaWad,
    //  realizedVarianceWad, derivedThetaWad). Pure range-geometry + oracle-ring
    //  math extracted for EIP-170 headroom; view fns (no state written), the
    //  live range ticks arrive as params. Byte-identical to the in-Quid bodies.
    // ════════════════════════════════════════════════════════════════════
    // THETA_N (8 windows → a 40-min horizon) DELETED 2026-08-15: zero references anywhere, code or
    // comment. It described the OLD estimator's window count — `OracleLib:220` names that estimator in
    // the past tense ("the previous estimator sampled `observe` every THETA_STEP seconds") — and E61
    // deleted the round trip that consumed it. A constant nobody reads is a horizon nobody computes.
    // ⚠️ `THETA_STEP` STAYS even though no CODE reads it either: `SwapLib:713` cites it by name to
    //    explain the live variance conversion (tickVar·(SECS_PER_YEAR/THETA_STEP)·1e10). Deleting it
    //    would orphan that explanation and leave 300 as a magic number.
    /// @notice The LVR coefficient K (WAD), derived LIVE from range geometry.
    /// §DE-TICK — same quantity, computed from PRICE bounds. The body only ever used RATIOS of the
    /// roots (`s/√Pb` and `√Pa/s`), and a ratio of roots is the root of the ratio:
    ///     s/√Pb = √(P/Pb)   ·   √Pa/s = √(Pa/P)
    /// so the tick→sqrt lookup disappears and the arithmetic is unchanged. √ survives as an
    /// OPERATION (range width is genuinely √-shaped) but nothing is stored or passed as a sqrt price.
    function kLvrWad(address core, uint loPrice, uint upPrice) public view returns (uint) {
        (uint priceWad,) = ICore(core).poolStats();
        if (loPrice >= upPrice) return 0;
        uint p = priceWad < loPrice ? loPrice : (priceWad > upPrice ? upPrice : priceWad);
        uint r1 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(p, 1e36, upPrice));   // √(P/Pb) · 1e18
        uint r2 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(loPrice, 1e36, p));   // √(Pa/P) · 1e18
        uint denom = 2e18;
        if (r1 + r2 >= denom) return 0;
        denom -= (r1 + r2);
        return SoladyMath.fullMulDiv(1e18, 1e18, 4 * denom);
    }

    /// @notice The range's LIVE realized concavity α (WAD).
    /// §DE-TICK — same conversion as `kLvrWad`: ratios of roots become roots of price ratios.
    function realizedAlphaWad(address core, uint loPrice, uint upPrice) public view returns (uint) {
        (uint priceWad,) = ICore(core).poolStats();
        if (loPrice >= upPrice) return 0;
        uint p = priceWad < loPrice ? loPrice : (priceWad > upPrice ? upPrice : priceWad);
        uint r1 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(p, 1e36, upPrice));   // √(P/Pb) · 1e18
        uint r2 = FixedPointMathLib.sqrt(SoladyMath.fullMulDiv(loPrice, 1e36, p));   // √(Pa/P) · 1e18
        if (r1 >= 1e18 || r1 + r2 >= 2e18) return 0;
        return SoladyMath.fullMulDiv(1e18 - r1, 1e18, 2e18 - r1 - r2);
    }

    /// @dev Annualized WAD yield the RANGE itself earned on the capital it put at risk — θ's
    ///      numerator (#107/D3). Both inputs come off Core and are 6-dec USD, so the ratio is
    ///      unitless and needs no scale plumbing:
    ///        • numerator   = `premiumEwmaUsd` — retained scarcity premium, decayed over ~48h.
    ///        • denominator = that pool's in-range range USD (`POOLED_USD_*`), i.e. the capital that
    ///          actually bore the IL. Using the range's own capital (not TVL, not backing) is what
    ///          makes this a YIELD ON THE BET rather than a yield on the whole reserve.
    ///      Returns 0 when either side is unmeasured, which `derivedThetaWad` turns into fail-open.
    ///
    ///      ⛔ DO NOT "SIMPLIFY" THIS TO `skewWad × flowEwmaUsd / pooled`. It looks strictly better —
    ///      `premium = amount·skew` (`retainSkewPremium`) and `flowEwmaUsd` is ALREADY the decayed
    ///      Σamount, so the product derives this yield with ZERO new storage and no hot-path write,
    ///      which is why it was considered first. It is WRONG: `skewWad = Γ·σ²·q/(1−q)^ρ` already
    ///      CONTAINS σ², so feeding a skew-derived numerator into `θ = numerator/(K·σ²)` makes σ²
    ///      CANCEL — θ would collapse to a vol-independent function of scarcity and flow and stop
    ///      measuring risk at all. That cancellation is the Avellaneda–Stoikov property (fees are
    ///      priced to scale with vol) and it would silently gut θ's purpose.
    ///      The stored register avoids it by measuring REALIZED premium — what flow actually paid —
    ///      against POTENTIAL LVR (`K·σ²`). Those are independent: the numerator moves with whether
    ///      flow arrived, the denominator with how much IL we were exposed to. θ therefore answers
    ///      "did realized fees cover the IL we bore?" — see `derivedThetaWad` below — whereas the derived form would
    ///      only answer "does our own pricing formula contain σ²" — i.e. nothing.
    ///
    ///      ⚠️ `PREMIUM_ANNUALIZE` is the ONE number here worth reviewing. An exponential EWMA with
    ///      half-life H has mean lifetime H/ln2, so it represents roughly that much accrual: for the
    ///      48h `FLOW_DECAY`, 48/ln2 ≈ 69.25h, and a year is 8760/69.25 ≈ 126.5 such windows (rounded UP to 127 per user). σ² is
    ///      ANNUALIZED (see `realizedVarianceWad`), so the numerator must be annualized too or θ is
    ///      dimensionally wrong and would systematically under-size the range. 127 is that factor,
    ///      not a tuning knob — if `FLOW_DECAY`'s half-life ever changes, this must change with it.
    uint internal constant PREMIUM_ANNUALIZE = 127;

    function _rangeFeeYieldWad(address core) internal view returns (uint) {
        uint prem6 = ICore(core).premiumEwmaUsd();
        if (prem6 == 0) return 0;                       // unmeasured ⇒ caller fails OPEN
        uint pooled6 = ICore(core).POOLED_USD();
        if (pooled6 == 0) return 0;                     // no range capital at risk ⇒ nothing to size
        return SoladyMath.fullMulDiv(prem6 * PREMIUM_ANNUALIZE, 1e18, pooled6);
    }

    /// @notice θ derived live: **range fee yield** / (K·σ²), clamped to <=1.
    ///
    /// @dev #107/D3 (2026-07-26): the numerator is the RANGE's realized market-making yield, NOT the
    ///      reserve `avgYield` it used to read. θ is Merton's `μ/(K·σ²)` — the optimal fraction of
    ///      capital to commit to a RISKY bet — and the bet being sized here is IL-bearing in-range
    ///      range depth. The compensation for that bet is the retained scarcity premium, full stop.
    ///      Reserve `avgYield` is earned whether the dollar leg is ranged or sits idle,
    ///      so it is NOT marginal compensation for IL and using it over-sized the range. Per the user:
    ///      *"the size of the range should have nothing to do with avgYield at all — that is only a
    ///      number that tells us how much QUI to mint upfront."* Two different jobs, two inputs.
    ///      Kept θ-LOCAL (read straight off Core) rather than folded into `avgYield`, precisely
    ///      because `avgYield` also feeds `seedFee` mint-valuation — folding would have moved mint
    ///      pricing as a side effect.
    ///
    ///      This makes θ encode the protocol's own rationality test directly: premium in the
    ///      numerator over σ² in the denominator IS "are fees beating LVR?", and θ < 1e18 IS the answer "no".
    ///
    ///      FAILS OPEN on an unmeasured register (`premium == 0` ⇒ return 1e18), matching every
    ///      other unmeasured path here (`sigmaSq == 0`, `kWad == 0`, cold oracle ring) and the
    ///      documented "θ≥1 fails open (calm/unmeasured) → only HEADROOM binds". That is what lets a
    ///      cold range BOOTSTRAP: a fresh range has earned no premium, and failing CLOSED would clamp
    ///      it to zero depth forever (no depth ⇒ no fees ⇒ no depth). Failing open is safe rather
    ///      than unbounded because `SwapLib.clampByBacking` applies the PHYSICAL
    ///      `backing − pooled` headroom independently — audit #8 was closed so that "every path
    ///      stays bounded at the real backing even when θ fails open".
    /// @dev `aux` was DROPPED (2026-07-27): the only thing that read it was the old `avgYield`
    ///      numerator, which #107/D3 replaced with the range-fee premium EWMA read off `core`. The
    ///      parameter has been dead since that change — the compiler flagged it as unused.
    function derivedThetaWad(address core, uint loPrice, uint upPrice) public view returns (uint) {
        uint sigmaSq = ICore(core).realizedVarianceWad();   // §E59: ONE source, read from Core
        if (sigmaSq == 0) return 1e18;
        uint kWad = kLvrWad(core, loPrice, upPrice);
        if (kWad == 0) return 1e18;
        uint work = SoladyMath.fullMulDiv(kWad, sigmaSq, 1e18);
        if (work == 0) return 1e18;
        // The `theta > 1e18 ? 1e18 : theta` clamp that used to close this function is DELETED — it
        // adds no safety. EVERY consumer already short-circuits at the same threshold:
        // `SwapLib.applyTheta:1299` is `if (thetaEff >= 1e18) return available;` (so 1e18 and 12e18
        // are byte-identical no-ops), `QuidLib:470` and `BtcLib:136` both document and treat
        // ">= 1e18 ⇒ no-op / fail-open", and the real bound on range depth is the PHYSICAL
        // `backing − pooled` headroom in `clampByBacking` (audit #8), which θ never gates.
        // Removing it also makes the external views (`Quid.derivedThetaWad`,
        // `Vault.derivedThetaWadBtc`) strictly MORE informative: they now report HOW FAR above the
        // no-throttle threshold the range is, instead of flattening everything to exactly 1.0 — which
        // matters more post-#107/D3, since a range earning real premium in a calm tape clears 1e18
        // routinely where the old reserve-`avgYield` numerator rarely did.
        // FAIL OPEN on an unmeasured premium register. This was MISSING (fixed 2026-07-26): the
        // docstring above already promised it, and `_rangeFeeYieldWad` returns 0 for both
        // `premium == 0` and `pooled == 0`, so `mulDiv(0, ...)` made θ fail CLOSED — the exact
        // deadlock the docstring warns about (no depth ⇒ no fees ⇒ no premium ⇒ no depth, forever).
        // A cold range could never bootstrap. Matches every other unmeasured path here
        // (`sigmaSq == 0`, `kWad == 0`, `work == 0`), and is safe for the same reason they are:
        // `SwapLib.clampByBacking` applies the PHYSICAL `backing − pooled` headroom independently.
        uint rangeFeeYield = _rangeFeeYieldWad(core);
        if (rangeFeeYield == 0) return 1e18;
        return SoladyMath.fullMulDiv(rangeFeeYield, 1e18, work);
    }

    /// @notice Annualized realized variance (WAD) from Core's oracle ring.

    // ════════════════════════════════════════════════════════════════════
    //  addLiq body (in-range pairing sizer). Clamps deltaTok to the three
    //  bounds: SOLVENCY surplus (+BTC policy cap via SwapLib.sizeBySurplus),
    //  PHYSICAL inventory, and the live θ-budget. View-ish (no state written).
    //  Extracted for EIP-170 headroom; the onlyUs guard stays in the Quid
    //  forwarder. Byte-identical to the in-Quid body.
    // ════════════════════════════════════════════════════════════════════
    /// @dev §E270 — `wantTok` is the REQUEST and is never written; `deltaTok` is the evolving value
    ///      (surplus-sized, then theta/backing-capped). Mirrors the BTC range, which already kept its
    ///      request in `sats`. Before this the ETH PARAMETER was overwritten, so past `sizeBySurplus`
    ///      the requested amount existed nowhere in the frame.
    function addLiq(address core, address aux, uint wantTok, uint price, uint grossBuffer)
        public returns (uint usdOut, uint outDelta) {
        // §DELTATOK-FOLD — THE BODY IS `SwapLib.addLiqBody`, SHARED WITH `BtcLib.addLiqChannel`.
        // What stood here was seven statements identical to the BTC copy; the only difference was the
        // two scalars below, so they are all that is passed. θ is computed HERE and not in the shared
        // body because `_liveTheta` reads `ICore(address(this))`, and `address(this)` is `Quid` only
        // under this library's delegatecall — see the warning on `addLiqBody`.
        return SwapLib.addLiqBody(core, aux, wantTok, price,
            _liveTheta(),                        // fails OPEN at θ=1e18 when vol is unmeasurable
            IAux(aux).rangeETH() + grossBuffer); // §ISBTC-SPLIT: NET venue principal + gross buffer
    }

    /// @dev addLiq's live θ: derivedThetaWad, fail-OPEN (θ=1) when the oracle ring
    ///      is too thin to measure vol. Self-call to Quid's forwarder (delegatecall
    ///      context: address(this) == Quid).
    function _liveTheta() private view returns (uint) {   // §ISBTC-SPLIT: the parameter was never read
        try ICore(address(this)).derivedThetaWad() returns (uint t) { return t == 0 ? 1e18 : t; }
        catch { return 1e18; }
    }

    // ════════════════════════════════════════════════════════════════════
    //  Body of Quid._rebalance (ETH side) — the fee/yield HARVEST cluster
    //  (_syncYield + SwapLib.rebalanceCore + _calcYield/_distributeV4Fees).
    //  Mutates ONLY value-type accumulators (no per-LP Deposit / lpShares /
    //  pooled / native-ETH), returned as INCREMENTS/flags the thin Quid
    //  forwarder applies — so `_rebalance()`'s callers are byte-unchanged.
    //  The dead `_calcYield` yield return (discarded in _rebalance) is dropped.
    // ════════════════════════════════════════════════════════════════════
    struct RebalIn {
        address core; address aux; address ev; address weth;
        uint lpShares; uint totalLevPooled; uint totalBuffer;
        uint loPrice; uint upPrice; uint bookmark;   // §DE-TICK: range bounds as PRICES
    }
    struct RebalOut {
        uint    spotPrice; uint    loPrice; uint    upPrice; uint    myLiquidity; uint resolvedTwap;   // §DE-TICK: uniform 256-bit
        uint feesPerShareInc; uint usdFeesInc; uint venueFeesPerShareInc; uint newBookmark;
        bool setLastRepack; bool reseatBump;
    }

    /// @dev Plain-venue ETH balance = rangeETH − lev net-equity (replica of Quid._venueBalance; that one STAYS in
    ///      Quid for its _withdraw/_depositImpl callers). No-op subtraction when no leverage.
    function _venueBalanceLib(address ev, address aux) internal returns (uint total) {
        total = IEthVenue(ev).rangeOp(0, 2);
        address lm = levManager(aux);
        if (lm != address(0)) {
            try ILevEquity(lm).totalNetEquity() returns (uint n) { total = total > n ? total - n : 0; } catch {}
        }
    }

    function rebalanceBody(RebalIn memory c) public returns (RebalOut memory o) {
        o.newBookmark = c.bookmark;
        {   // _syncYield: venue (Morpho WETH) appreciation accrues over PLAIN depth into venueFeesPerShare.
            uint plainDepth = c.lpShares > c.totalLevPooled ? c.lpShares - c.totalLevPooled : 0;
            uint current = _venueBalanceLib(c.ev, c.aux);
            if (plainDepth == 0) {
                o.newBookmark = current;                         // no plain LP depth; just refresh the bookmark
            } else {
                if (c.bookmark > 0 && current > c.bookmark)
                    o.venueFeesPerShareInc = SoladyMath.fullMulDiv(current - c.bookmark, WAD, plainDepth);
                o.newBookmark = current;
            }
        }
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, c.weth, c.upPrice, c.loPrice);   // `c` is RebalIn here, which keeps `weth`
        if (r.didRepack) {
            // _calcYield's live effect: reorder to token-canonical + _distributeV4Fees; the APY `yield` it also
            // computed was discarded by _rebalance, so it is dropped. LAST_REPACK := block.timestamp (forwarder).
            // §DE-TICK: the ordering ternary reordered TWO ZEROS -- `repack`/`reseat` both return
            // `(price, 0, 0, 0, 0)` now that v4 collects nothing, so the fee legs are identically 0
            // and the canonical (USD, tok) order the comment below names is taken directly. The fee
            // LANE is untouched: whether per-share accrual returns is the deferred decision recorded
            // at `Core._fillDelta` (fees currently compound into POOLED_* instead).
            // §V4-CUT-RESIDUE — the two fee lines here are DELETED. They read `r.fees1`/`r.fees0`,
            // which nothing assigns, and ASSIGNED (not `+=`) the zero result to the increments,
            // which are already zero-valued. ⚠️ The branch itself STAYS: `setLastRepack` is its
            // live effect, and the `else if (r.jitFees)` below depends on this arm claiming the
            // repack case first.
            o.setLastRepack = true;
        }
        // (§V4-CUT) The `else if (r.jitFees)` distribution arm is gone with the collect that fed it;
        // it computed `feeIncrements(0, 0, …)`. `setLastRepack` above is still the live effect of the
        // repack arm, which is why THAT branch stays.
        if (r.loPrice != c.loPrice || r.upPrice != c.upPrice) o.reseatBump = true; // ticks recentered → re-anchor
        o.spotPrice = r.spotPrice; o.loPrice = r.loPrice; o.upPrice = r.upPrice;
        o.myLiquidity = r.myLiquidity; o.resolvedTwap = r.resolvedTwap;
    }

    /// @dev Replica of Quid._refreshBookmarks (that one STAYS in Quid for its many other callers): rebaseline
    ///      `user`'s TRADING-fee bookmark against gross weight (pooled + levBuf) and the VENUE-yield bookmark
    ///      (venueBm) against PLAIN weight. Byte-identical arithmetic.
    function _refreshBookmarksLib(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        mapping(address => uint) storage venueBm,
        address user, uint feesPerShare, uint usdFees, uint venueFeesPerShare
    ) internal {
        Types.Deposit storage LP = autoManaged[user];
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[user], feesPerShare, usdFees);
        uint plainW = SwapLib.plainNet(LP.pooled, levPooled[user]);
        venueBm[user] = SoladyMath.fullMulDiv(plainW, venueFeesPerShare, WAD);
    }

    // ════════════════════════════════════════════════════════════════════
    //  Body of Quid._transferShares — VERBATIM relocation. Settles BOTH
    //  parties' pending rewards (compound ETH → pooled/lpShares, accrue USD →
    //  usd_owed) BEFORE moving principal, so the moved pooled carries no
    //  past-reward claim. The value-type `lpShares` growth is returned as a
    //  delta the Quid forwarder applies; the Transfer event stays in Quid.
    //  `pendingRewards` is reached via a self-STATICCALL (public view — same
    //  storage, no reentrancy); the small _refreshBookmarks is replicated above.
    // ════════════════════════════════════════════════════════════════════
    function transferSharesBody(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        mapping(address => uint) storage venueBm,
        address from, address to, uint amount,
        uint feesPerShare, uint usdFees, uint venueFeesPerShare
    ) public returns (uint lpSharesDelta) {
        require(to != address(0), "to=0");
        require(from != to, "self");
        if (amount == 0) return 0;                       // forwarder emits Transfer(from,to,0) == (from,to,amount)

        Types.Deposit storage L = autoManaged[from];
        // Cap transfer at the FREE (non-levered) balance — the levered slice is unwind-only + NON-transferable
        // (mirrors the `pooled - levPooled` cap in _withdraw), else it could be drained via a fresh address.
        uint freeBal = SwapLib.plainNet(L.pooled, levPooled[from]);
        if (amount > freeBal) revert InsufficientBalance();

        // Settle pending rewards for `from` — ETH compounds into pooled (grows lpShares), USD accrues to usd_owed.
        if (L.pooled > 0) {
            (uint ethReward, uint usdReward) = ICore(address(this)).pendingRewards(from);
            if (ethReward > 0) { L.pooled += ethReward; lpSharesDelta += ethReward; }
            if (usdReward > 0) L.usd_owed += usdReward;
        }
        // Settle pending rewards for `to` (if they have a position).
        Types.Deposit storage R = autoManaged[to];
        if (R.pooled > 0) {
            (uint ethReward, uint usdReward) = ICore(address(this)).pendingRewards(to);
            if (ethReward > 0) { R.pooled += ethReward; lpSharesDelta += ethReward; }
            if (usdReward > 0) R.usd_owed += usdReward;
        }
        // Move principal.
        L.pooled -= amount; R.pooled += amount;
        // Refresh both bookmarks to current accumulators — from here both accrue on their new pooled balances.
        _refreshBookmarksLib(autoManaged, levPooled, levBuf, venueBm, from, feesPerShare, usdFees, venueFeesPerShare);
        _refreshBookmarksLib(autoManaged, levPooled, levBuf, venueBm, to, feesPerShare, usdFees, venueFeesPerShare);
    }

    // ════════════════════════════════════════════════════════════════════
    //  Body of Quid.pull — reduce/close a self-managed boundary order. VERBATIM
    //  relocation: owner + maturity + percent guards, liquidity slice, the
    //  full-close array swap-pop cleanup, and the V4.outOfRange burn. Storage
    //  refs (selfManaged/positions) mutate in place; the nonReentrant guard stays
    //  in the Quid forwarder. `owner` = msg.sender (preserved through delegatecall).
    // ════════════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════════════
    //  Self-managed boundary-order sizing (body of Quid._sizeOutOfRange):
    //  deposit the position's backing (ETH at the chosen venue, or a stable via
    //  AUX) and size the single-sided liquidity. pledge==0 -> no wall attribution.
    //  Ticks bundled to keep the Quid forwarder off the legacy stack.
    // ════════════════════════════════════════════════════════════════════
    // §A.54: `OorTicks` was byte-identical to `SwapLib.Oor` — same four fields, same order, same
    // types — i.e. one concept under two names. Collapsed onto `SwapLib.Oor`, which is the better home:
    // it already owns the `SwapLib.oorBounds(...)` factory that CONSTRUCTS the value, and this library
    // already imports SwapLib.



    /// @dev DEPLOY-TIME ONLY — the body of `Quid.setup`, moved here for the same
    ///      reason `Core.setup`'s body moved to OracleLib (E32): one-shot wiring was
    ///      billing Quid's RUNTIME bytes against a hard EIP-170 deficit. Quid keeps
    ///      what cannot leave: the `onlyOwner` gate, the AlreadyInitialized guard,
    ///      `renounceOwnership()` (Ownable's slot is Quid's), the QUID back-pin check,
    ///      and the assignments of the value-type state this returns.
    function setupBody(address _aux, address _core)
        external returns (address weth, uint lower, uint upper) {
        weth = IAux(_aux).WETH();
        IWETH9(weth).approve(_aux, type(uint).max);
        (uint spotPrice,) = ICore(_core).poolStats();
        (lower, upper) = SwapLib.updateBounds(spotPrice, SwapLib.RANGE_DELTA);
    }

    /// @dev Quid's ETH delivery ladder, moved here for EIP-170 (E32). Native balance
    ///      first, then this contract's WETH, then a venue pull, then — only if the
    ///      venue base is exhausted while POOLED priced the swap against the
    ///      LEVERED slice too — de-lever the levered book with the delivery's OWN
    ///      proceeds, turning §M phantom depth into real deliverable ETH.
    ///      VALUE-NEUTRAL per LP, and NOT the removed toxic arbETH (which spent shared
    ///      basket surplus): `deleverEthOnDelivery` repays each LP's OWN debt.
    ///      Fork-proved by testReal_DeleverEthBacking_SwapOutTapsLeveredSlice.
    ///
    ///      A failed send REVERTS so the unlock rolls back atomically — the old
    ///      swallow left unwrapped ETH stranded at the contract while reporting 0.
    function sendEth(address weth, address ev, address aux, uint howMuch, address toWhom)
        external returns (uint sent) {
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) sent = howMuch;
        else { uint needed = howMuch - alreadyInETH;
            uint inWETH = IWETH9(weth).balanceOf(address(this));
            if (needed > inWETH) {
                inWETH += IEthVenue(ev).rangeOp(needed - inWETH, 1);
                if (inWETH < needed) {
                    address mgr = IEthVenue(ev).LEV_MANAGER();
                    if (mgr != address(0)) {
                        uint px = IAux(aux).getTWAPforAsset(weth, 1800);   // USD 1e18 / WETH
                        inWETH += SwapLib.deleverEthOnDelivery(
                            mgr, aux, px, needed - inWETH, address(this));
                    }
                }
            }  IWETH9(weth).withdraw(inWETH);
            sent = inWETH + alreadyInETH;
        }
        (bool success, ) = payable(toWhom).call{value: sent}("");
        require(success, "ethSend");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // §VAULTLIB-FOLD (2026-08-18) — QuidLib merged in and DELETED.
    //
    // Its name had become a lie: `Vault` is the BTC range manager and does not call it. Every
    // non-`Quid` reference to EITHER library across `Core`, `Vault`, `RangeLib` and `BtcLib` is a
    // COMMENT — checked one by one — so both were the ETH range manager's libraries and only one
    // of them said so. `Quid` called them 28 and 11 times respectively.
    //
    // Folded whole rather than split: 12,232 + 5,703 = 17,935 against the 24,576 limit, so it fits
    // in one envelope with ~6,600 to spare and needs no boundary judgement. Zero function-name
    // collisions between the two. The alternative — spreading across RangeLib and this — would have
    // required deciding a range-vs-venue line that the CALLERS do not draw.
    // ══════════════════════════════════════════════════════════════════════════════

    /// §E57: moved with the offramp body — its only emitter.


    // Mirror Vault's custom errors so reverts from delegatecalled bodies carry
    // the SAME 4-byte selector (selector = keccak(name+args), name-derived).

    /// @dev Vault's ETH-venue immutables, gathered so the delegatecalled library
    ///      can operate on them (it can't read Vault's immutable slots).
    struct EthCfg {
        address weth;
        address aux;
        address curvePool;   // bounds what weETH is DELIVERABLE — see deliverableETH
        address weeth;
        address eeth;        // ETHERFI_EETH (raw eETH transiently held mid wait-NFT)
        address levManager;
    }

    /// ether.fi deposit adapter — the SAME compile-time constant Vault pins (ETHERFI_ADAPTER); kept here so
    /// supplyVenueBody (kind 1) needs no extra EthCfg field across its 12 build sites.
    address internal constant ETHERFI_ADAPTER_VL = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;

    // ── Venue valuation ───────────────────────────────────────────────────


    /// @dev Body of Vault.rangeETH — AGGREGATE ETH-equivalent backing across the
    ///      depositor-chosen venues.
    function _rangeETH(EthCfg memory c) internal view returns (uint total) {
        if (c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) total += IWeETH(c.weeth).getEETHByWeETH(w);
        }
        // Idle WETH is still ETH backing — count it at BOTH the Vault (venue
        // custody, evacuated remainders) AND Aux (transient swap/deposit legs).
        total += IERC20(c.weth).balanceOf(address(this));
        total += IERC20(c.weth).balanceOf(c.aux);
        // Raw eETH transiently sits here mid wait-NFT withdrawal — real backing,
        // counted at BOTH Vault and Aux so a partial failure never strands it.
        if (c.eeth != address(0)) {
            total += IERC20(c.eeth).balanceOf(address(this));
            total += IERC20(c.eeth).balanceOf(c.aux);
        }
        // IL-protect: count the leveraged book's net-equity (gross collateral - debt), not gross. The buffer
        // half is debt-funded (offset by the LP's borrow), so counting gross would overstate solvency by the debt
        // -- the same error the fold fixed for `committed`. Net-equity is the LP's real deliverable claim (what
        // `closeLev` returns after auto-repaying the debt). The 2x range depth is untouched -- it lives in
        // `levPooled = gross`, not here. try/catch degrades to "no lev credit". Unified with the BTC model.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) { total += n; } catch {}
        }
    }

    /// @notice Body of Vault.rangeETH.
    function rangeETH(EthCfg memory c) public view returns (uint) {
        return _rangeETH(c);
    }


    /// @notice Body of Vault.deliverableETH — SOLVENCY-side ETH backing with PARTIAL liquidity haircuts.
    ///
    /// @dev    READ THE NAME NARROWLY (§A.5c, re-derived 2026-07-27). This is NOT a promptness
    ///         guarantee and NOT a view-twin of the withdraw ladder. It bounds the WETH-4626 side and
    ///         subtracts the levered net equity, but it counts the weETH at the venue and raw eETH at
    ///         FULL FACE — neither of which is instantly convertible (the ether.fi legs need the offramp
    ///         ladder, whose rung 1 is a CURVE `weETH/WETH-ng` sale at up to the 0.5% slippage cap and
    ///         whose rung 2 is a multi-day wait NFT — there is NO deterministic-cost tier between them
    ///         since the instant-redeem was removed 2026-08-06).
    ///         🔴 **DESTALED 2026-09-05, TWO WAYS.** (a) This said *"caps the three WETH-4626 venues via
    ///         `_deliverableCap`"*; `_deliverableCap` has **0 code references** — the three venue caps
    ///         were removed and re-derived to the Curve bound on 2026-08-13, which `deliverableETH`'s own
    ///         body notes below already record. (b) It said rung 1 is *"a v3 pool sale"*; v3 was removed
    ///         2026-08-09 and rung 1 is Curve — measured 17–25 bps better at every realistic size, so
    ///         this was not a naming slip but a claim about the WRONG VENUE'S execution cost.
    ///
    ///         WHY THAT IS SAFE RATHER THAN A BUG — it is not load-bearing for delivery. Its two
    ///         consumers both tolerate over-statement:
    ///           • `Quid` uses it ONLY to cap `firstBurn`, i.e. how much of a withdrawal is sourced
    ///             from the in-range range burn before the venue ladder takes the remainder. The
    ///             shortfall is then derived from the ACTUAL `sent`, never from this number, so an
    ///             over-statement shifts the sourcing ORDER and self-corrects.
    ///           • `SwapLib.deleverEthOnDelivery` gates the swap-out de-lever; under-triggering there
    ///             is caught downstream by `minOut` + deferral (§A.29).
    ///         Measured: exit fairness holds to 1%, and a full exit strands < 1 gwei
    ///         (`test_RunSim_AllExit_Normal`). Do NOT "fix" this by rebuilding it as a ladder twin
    ///         without first re-establishing a harm — the previous attempt to do so rested on a
    ///         19.4%-short figure that measurement showed to be stale (~3%, and DEFERRED not lost).
    /// @notice The ONE `withdrawable` definition for a WETH 4626 venue — what it can actually pay us.
    ///
    ///         MORPHO-V2 (probed live). A V2 vault parks its assets
    ///         in ADAPTERS and auto-allocates on deposit, so BOTH its max-views are idle-only: with our
    ///         own 20 ETH position it reported `maxWithdraw == 0` AND `maxRedeem == 0`. That is NOT
    ///         illiquidity — `withdraw(1 ether)` SUCCEEDED (burned 0.9939 shares) and `redeem` returned
    ///         1.875 ETH, because `withdraw()` self-deallocates from the adapters. Clamping a pull by
    ///         `maxWithdraw` therefore means we NEVER TRY: measured, that zeroed `deliverableETH` with
    ///         16 ETH sitting solvent in the vault and made EVERY ETH LP exit return 0 while the LP kept a
    ///         full pooled balance. So for a V2 vault the REPORTED position is the deliverable amount.
    ///
    ///         Everything else (Euler, AAVE, MetaMorpho v1.1) has honest max-views — real Euler reports
    ///         `maxWithdraw` equal to the full position — and keeps the conservative read. Both branches
    ///         are try/catch'd: a venue whose view REVERTS (Euler's EVault calls `EVC.getControllers`
    ///         inside `maxWithdraw`; fork-traced) must value at 0 rather than brick every ETH withdraw.
    ///         `holder` is parameterised so the STABLE side (`BasketLib`, whose holder is `Aux`) shares
    ///         this ONE definition rather than keeping a second copy. 6 of our 8 registered stable
    ///         vaults are Morpho-V2 — measured, holding ~124M of ~126M total stable TVL — so the stable
    ///         side had the same understatement, and there it feeds the REDEMPTION haircut.
    function _withdrawableOf(address vault, address holder) internal view returns (uint) {
        try IVaultV2(vault).liquidityAdapter() returns (address adapter) {
            if (adapter != address(0)) {
                try IERC20(vault).balanceOf(holder) returns (uint shares) {
                    if (shares == 0) return 0;
                    try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                    catch { return 0; }
                } catch { return 0; }
            }
        } catch {}
        try IERC4626(vault).maxWithdraw(holder) returns (uint m) { return m; }
        catch {
            // `maxWithdraw` REVERTED. Euler's EVault does this whenever the holder has no
            // controller enabled on the EVC (fork-traced: `liquidityAdapter()` is also absent on
            // the current implementation, so BOTH probes above miss and we land here). Returning 0
            // valued a real, fully-liquid position at NOTHING — which understated backing and made
            // the venue unwithdrawable, so an LP whose ETH sat in Euler could redeem and receive 0.
            //
            // Fall back to the share value, which is exactly what the `liquidityAdapter` branch
            // above uses for Morpho-V2. It is an UPPER bound on what the venue can pay if the vault
            // is illiquid — but `_pull4626` already clamps the pull to `min(need, maxOut)` and the
            // withdraw itself reverts on real illiquidity, so an over-estimate degrades to a failed
            // pull, whereas 0 silently strands the position. Prefer the recoverable failure.
            try IERC20(vault).balanceOf(holder) returns (uint shares) {
                if (shares == 0) return 0;
                try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                catch { return 0; }
            } catch { return 0; }
        }
    }

    /// @dev BOUNDED BY WHAT CURVE CAN PAY, and this is NOT a clamp -- it is what the word DELIVERABLE
    ///      means here. `deliverableETH` is INSTANT deliverability, and weETH's instant deliverability
    ///      genuinely is bounded by the pool: the wait-NFT makes it EVENTUALLY deliverable at fair value,
    ///      which is a different quantity. Conflating the two is what made an earlier attempt argue this
    ///      bound away as unnecessary.
    ///      ⚠️ MEASURED BOTH WAYS. Removing it does not merely under-report: the `amount > 0` fallback in
    ///      `Quid`'s exit then OVER-delivers against backing the offramp cannot source, so nothing
    ///      defers and both test_RunSim_B_LiquidityRace_* fail "deferral recovers: 0 <= 0" -- there is
    ///      no deferral left to recover. It replaces the three per-venue `_deliverableCap` bounds that
    ///      went with the ETH venues, and serves the same purpose: virtual burn == real delivery.
    ///      (Superseded framing, 2026-08-13.) The three `_deliverableCap` venue bounds
    ///      removed with the ETH venues existed because a 4626 curator could hold value that was
    ///      genuinely UNREACHABLE — `maxWithdraw` short of the position with no other exit. weETH has no
    ///      such state: if Curve cannot absorb it the wait-NFT redeems it at fair value from ether.fi, so
    ///      the value is SLOWER, never stuck. A cap here would model an unreachable state that cannot
    ///      occur, and would understate backing on every read.
    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _rangeETH(c);
        // WEETH IS ONLY DELIVERABLE TO THE EXTENT CURVE CAN PAY FOR IT.
        // RE-DERIVED 2026-08-13, replacing the three `_deliverableCap` venue caps removed with the ETH
        // venues. Those caps were what made an undeliverable slice DEFER; deleting them without a
        // replacement left `_rangeETH` counting weETH at full oracle value while the exit can realise at
        // most the pool's WETH, so delivery was overstated and the deferral machinery never engaged.
        // (Measured: that regression broke test_SETTLE_LvrResidualIsDeferralNotLeak,
        // test_RunSim_B_LiquidityRace_* and testRT_DeliveredPlusRetainedEqualsPrincipal, all of which
        // pass on stock main — a control run, not an inference.)
        // Bound only the weETH-sourced portion: idle WETH and eETH are already deliverable as-is.
        if (c.curvePool != address(0) && c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) {
                uint weethEth = IWeETH(c.weeth).getEETHByWeETH(w);
                uint payable_ = (ICurvePool(c.curvePool).balances(0) * 9) / 10;   // same headroom as offrampBody
                if (weethEth > payable_) total -= (weethEth - payable_);          // the surplus DEFERS
            }
        }
        // The leverage net-equity is solvency backing (now counted in rangeETH as net) but NOT deliverable
        // from this Vault (unwind-only via closeLev -- the LP gets it back by repaying debt + withdrawing coll,
        // not from redemption). Exclude the same net-equity term rangeETH added, so deliverableETH == base
        // (non-levered venue ETH), byte-identical to the prior gross-in/gross-out result. Redemptions never draw it.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) {
                total = total > n ? total - n : 0;
            } catch {}
        }
    }

    // ── Supply ────────────────────────────────────────────────────────────





    /// @notice Consolidated venue-supply body — the `transferFrom` + venue call for every ETH supply wrapper, so the
    ///         Vault forwarders keep ONLY their `NotQuidCore`/`NotAux` gate (bytecode OUTSIDE the EIP-170-critical
    ///         Vault). `from` = the approver the WETH is pulled from (V4 for the venue wrappers, AUX for
    ///         `supplyFromAux`).
    /// @dev THE `kind` SELECTOR IS GONE (2026-08-13). It was already ignored — every value routed to the
    ///      ether.fi adapter — and its own docblock said to remove it once the routing decision was
    ///      final. It is: there are no WETH-holding venues left to select, so the parameter had
    ///      nothing left to choose between.
    function supplyVenueBody(EthCfg memory c, uint amount, address from) public returns (uint) {
        if (amount == 0) return 0;
        // ALL ETH SUPPLY IS weETH: it earns the ether.fi ratchet, measured at +0.674 bps/day =
        // 2.46%/yr. That is the hurdle any WETH-holding venue must clear just
        // to break even, before conversion friction each way. AAVE v4 measured 2026-08-06 on live
        // mainnet: WETH 21,103 supplied / 400 borrowed = 1.90% utilisation ⇒ supply APY in SINGLE
        // BASIS POINTS; weETH 714 supplied / ZERO borrowed = 0.00% ⇒ exactly zero yield whatever the
        // rate curve says. Supplying WETH there is a strict loss of ~2.46 points, and the only thing
        // it buys is borrow capacity against the collateral — which is encumbrance (the offramp
        // design), not yield.
        //
        // ⚠️ SUPPLY ONLY. The withdraw ladder below is DELIBERATELY UNTOUCHED so existing positions in
        // those venues stay pullable. Do not remove the withdraw rungs until the balances are drained.
        if (ETHERFI_ADAPTER_VL == address(0)) return 0;
        IERC20(c.weth).transferFrom(from, address(this), amount);
        IDepositAdapter(ETHERFI_ADAPTER_VL).depositWETHForWeETH(amount, address(this));
        return amount;
    }

    // ── Withdraw ladder ─────────────────────────────────────────────────────



    /// @notice Body of Vault._withdrawETH — idle-then-ether.fi(opportunistic)-then
    ///         ladder. Only WETH is served.
    function withdrawETH(EthCfg memory c, SwapLib.OfframpCfg memory off,
        address token, uint amount, address to) public returns (uint sent) {
        if (amount == 0) return 0;
        require(token == c.weth, "ethv:notWeth");
        // Sweep any idle WETH from Aux into the Vault first (Aux approved the Vault),
        // preserving the idle-first ladder (rangeETH counts Aux idle as backing).
        uint auxIdle = IERC20(c.weth).balanceOf(c.aux);
        if (auxIdle > 0) {
            try IERC20(c.weth).transferFrom(c.aux, address(this), auxIdle) {} catch {}
        }
        uint wethBal = IERC20(c.weth).balanceOf(address(this));
        if (wethBal < amount) {
            // OPPORTUNISTIC, NON-BLOCKING: sell idle ether.fi
            // weETH → WETH on the deep pool. Any failure swallowed (returns 0).
            if (LevMath.sourceWeth(amount - wethBal, off.weeth, off.curvePool) > 0)
                wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        if (wethBal < amount) {
            wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        sent = wethBal >= amount ? amount : wethBal;
        if (sent > 0 && to != address(this)) {
            IERC20(c.weth).transfer(to, sent);
        }
        return sent;
    }

    // ── Vault-health evacuate ────────────────────────────────────────────────



    // ── ether.fi OFFRAMP (moved from SwapLib, §E57) ──────────────────────────────────────────
    //  Its ONE caller is `Vault.offrampEtherFi` (`Vault.sol:444`), so it was always a VAULT
    //  concern living in a SWAP library. Moving it is not just tidiness: SwapLib was the binding
    //  EIP-170 contract at +14 bytes while QuidLib had 15,040 spare, and E55/E53 need room in
    //  SwapLib specifically. Put the code where the room is — the same trade as E32.
    /// @notice Body of Aux.offrampEtherFi — the exit ladder. Rung 1 = Curve pool sale; rung 2 = wait NFT.
    ///         HONEST SERVING: when the held weETH covers less than `amount`
    ///         (clamped balance), both rungs report the
    ///         pro-rata `covered` slice, never the full ask — so the caller's
    ///         position accounting only decrements what was actually served.
    function offrampBody(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        external returns (uint) {
        if (amount == 0 || c.weeth == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        uint weethIn = weethFull;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        if (weethIn > bal) weethIn = bal;
        // CAPACITY — shrink to what the pool can actually pay. This MUST happen before `covered` is
        // derived: `covered` is returned as the amount SERVED, and `Quid` burns it and decrements
        // `LP.pooled` by it. Shrinking inside `curveSellWeeth` instead would leave `covered` reflecting
        // the pre-shrink size, so the offramp would report serving more than it sold — a silent
        // over-credit on the exit path. Same arithmetic, wrong place, money-path defect.
        // MEASURED 2026-08-09: fills track ~1.4 + 55·(dx/D)² bps up to ~1,000 weETH (−1.39 at 1, −1.51 at
        // 100, −3.47 at 1,000) and then break by 70× — −722.80 at 2,000. That cliff is NOT slippage but
        // EXHAUSTION: 2,000 weETH asks ~2,202 WETH out of a pool holding 2,047. No floor value survives
        // it, because the pool cannot pay; only sizing does.
        // NEVER GATE — shrink. The unserved remainder falls to the wait-NFT rung on its own, so a partial
        // fill still serves most of a large exit instead of deferring all of it for ~7 days.
        if (c.curvePool != address(0) && weethIn > 0) {
            uint wantOut = (weethFull == 0 || weethIn == weethFull)
                ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);
            // 90% of the pool's WETH: slippage steepens toward the edge, so leave headroom rather than
            // sizing to the exact boundary the quadratic stops describing.
            uint cap = (ICurvePool(c.curvePool).balances(0) * 9) / 10;
            if (wantOut > cap) weethIn = SoladyMath.fullMulDiv(weethIn, cap, wantOut);
        }
        uint covered = (weethFull == 0 || weethIn == weethFull)
            ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);
        // RUNG 1 — CURVE `weETH/WETH-ng` (only if this contract holds weETH). Replaced a two-tier
        // Uniswap v3 loop 2026-08-09. Measured live against the weETH/WETH oracle, Curve vs the 0.01%
        // v3 tier: −1.39 vs −17.55 bps @1, −1.51 vs −18.79 @100, −3.47 vs −28.16 @1000. ~17–25 bps
        // better at every realistic size, so there is no tier to choose between and no ordering to get
        // wrong. Both venues cliff near 2,000 weETH, where Curve's 2,047 WETH runs out — and THAT is the
        // only case rung 2 now exists for.
        // THE FLOOR GUARDS **MEV**, NOT CAPACITY — those were one number until 2026-08-09 and are now two.
        // 50 bps had to straddle "normal" and "drained" because a single constant did both jobs; with the
        // shrink above handling capacity, the floor only has to sit above HONEST execution.
        // 25 bps = worst measured slippage (3.5 bps) + room for the pool-vs-ether.fi-rate offset, which
        // widens at up to 0.674 bps/day (the ratchet) when the pool is unarbed — roughly a month's drift.
        // ⚠️ THAT SECOND TERM IS WHY IT IS NOT 15: sizing against slippage alone ignores a divergence that
        // grows with TIME rather than trade size, and a false reject costs the LP a ~7-day wait-NFT.
        // Anchored to `covered`, i.e. the ether.fi rate — NOT to any pool-derived quote, which a
        // front-runner moves along with the fill it is supposed to police.
        if (weethIn > 0) {
            uint got = LevMath.sellWeethOnCurve(c.weeth, c.curvePool, weethIn, (covered * 9975) / 10_000);
            if (got > 0) {
                IERC20(c.weth).transfer(recipient, got);   // Curve pays msg.sender; deliver onward
                return covered;
            }
        }
        // There is deliberately NO ether.fi instant-redeem rung: `totalRedeemableAmount` measures ZERO
        // at every sampled block, because the pool absorbs the flow first.
        // RUNG 2 (last) — no-fee withdrawal NFT, minted to the WITHDRAWER.
        //
        // ⚠️ THE LADDER IS TWO RUNGS, AND THE INTENDED FIRST RUNG IS MISSING. Today it sells weETH on
        // CURVE (rung 1) and falls back to a redemption claim (rung 2). The DESIGN is: BORROW WETH
        // against the weETH, deliver that, and repay from the redemption — with the pool SALE as the
        // borrow's ONLY alternative (owner, 2026-08-09). Under that design `waitNft` stops being a way
        // to serve an LP and becomes the REPAYMENT of the borrow.
        // 🔴 **DESTALED 2026-09-05: this read "v3" in both places**, contradicting the `RUNG 1 — CURVE`
        // note ~25 lines above it in this same function. v3 was removed on 2026-08-09 — the SAME DATE
        // this owner quote is dated — so the sentence was stale the day it was written.
        //
        // The ~25.6 bps sale is charged ONLY on the slice `weethIn` covers — i.e. the weETH this contract
        // holds FREE (`:452-457` clamps to `balanceOf(address(this))`). Levered collateral sits in per-LP
        // venue escrows and is untouchable here, so the sale is a bounded slice, NOT the whole withdrawal.
        // ⚠️ That makes it LARGEST IN BOOTSTRAP, when little is levered and most weETH is free.
        //
        // ▶️ Building it is NOT deploy config (an earlier note here said so, wrongly). Venue `borrow` is
        // `onlyManager`, so the entrypoint must live on `LevManager` — and with ~100 free bytes there it
        // needs the repo's forwarder shape: thin function in `LevManager`, body in `LevMath` (439 free).
        // The protocol's debt is then seeded into `LevManager.totalDebtUsd`, which already flows to
        // `Core._rangeEquityUsd18` → `committedUsd18`; NO new accounting term (adding one double-subtracts).
        return waitNft(covered, recipient, c);
    }


    /// @notice Rung-2 (last) wait-NFT, standalone: unwrap up to `amount`-worth of the
    ///         held idle weETH → eETH → LiquidityPool withdraw-request NFT
    ///         minted to `recipient`. Returns the ETH-worth actually covered
    ///         (honest: a clamped weETH balance covers proportionally less).
    ///         Used by offrampBody — the LP-exit down-leg fallback when the CURVE
    ///         pool sale above it fails its 0.5% floor (v3 was removed 2026-08-09;
    ///         this said "v3" until 2026-09-05) (the redemption-side
    ///         wrapper was removed: redemption is stables-only). ⚠️ It is the ONLY
    ///         thing under rung 1: there is no instant-redeem buffer to exhaust
    ///         first, so a pool that cannot fill puts the withdrawer straight
    ///         into a multi-day queue.
    function waitNft(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        internal returns (uint) {
        if (amount == 0 || c.weeth == address(0) || c.lp == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        if (weethFull == 0) return 0;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        uint weethIn = weethFull > bal ? bal : weethFull;
        if (weethIn == 0) return 0;
        try IWeETH(c.weeth).unwrap(weethIn) returns (uint eeth) {
            if (eeth > 0) {
                // TO THE WITHDRAWER. This was briefly changed to `address(this)` on 2026-08-06 so the
                // NFT could serve as the repayment leg of a WETH borrow -- but that change was
                // COUPLED to a borrow leg that does not exist, and worse, cannot exist against this
                // venue: MorphoEscrowVenue.borrow(lp, stableAmount) lends STABLE, not WETH, so
                // "borrow WETH against weETH" has no market behind it. Borrowing would yield stable
                // needing a stable->WETH leg, i.e. the SOR double-charge the design exists to avoid.
                // While mis-set, ANY exit reaching this rung delivered the withdrawer NOTHING while
                // taking their weETH -- caught by three tests all reporting "delivered ETH: 0".
                // Do not repoint this again without a weETH-collateral / WETH-loan market AND the
                // claim-and-repay step landed together.
                try IEtherFiLiquidityPool(c.lp).requestWithdraw(recipient, eeth) returns (uint) {
                    return weethIn == weethFull
                        ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);
                } catch {}
            }
        } catch {}
        return 0;
    }

}
