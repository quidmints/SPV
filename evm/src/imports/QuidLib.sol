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
import {IWETH9} from "./Interfaces.sol";
import {ICore} from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IEtherFiLiquidityPool} from "./Interfaces.sol";   // the wait-NFT rung's `requestWithdraw`
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IWeETH} from "./Interfaces.sol";
import {ICurvePool} from "./Interfaces.sol";
import {IDepositAdapter} from "./Interfaces.sol";

// ── Minimal external surfaces the extracted Quid bodies touch. The library is
//    DELEGATECALL'd (public fns), so `address(this)` is Quid: every immutable
//    Quid reads (CORE/AUX/WETH plus the ETH-venue addresses) is passed in via a
//    cfg struct or an interface handle; reference-type state (the autoManaged
//    Deposit + the levPooled/levBufferUsd/levBuf/venueBm mappings) is passed by
//    STORAGE REF so writes land on Quid's slots. Value-type state (lpShares) is
//    mutated by RETURNING the delta, applied by the thin Quid forwarder. ──────
/// @title  QuidLib — sizeable Quid bodies extracted to free bytecode under the
///         EIP-170 limit. DELEGATECALL'd by Quid (public fns): inside each,
///         `address(this)`/`msg.sender`/`msg.value` are Quid's, so token custody
///         and external calls leave from Quid exactly as the former in-Quid
///         bodies did. Byte-for-byte semantics; only the home moved.
library QuidLib {

    /// The ether.fi placement returned 0 — paused or unwired. There is ONE destination and so no
    /// fallback to redirect to: fail loud rather than leave the deposit sitting here as idle WETH.
    error VenueUnavailable();

    /// @dev DIRECT weETH, always: it earns the full ether.fi staking rate.
    function _supplyEtherFi(address ev, uint amount) private returns (uint placed) {
        placed = IEthVenue(ev).supplyEtherFi(amount);
    }

    // Mirror Quid's selectors (name-derived) for the delegatecalled bodies.
    error InsufficientBalance();

    // ════════════════════════════════════════════════════════════════════
    //  IL-protect: ETH levered range slice (full-2x fee lane). Bodies of
    //  Quid._reconcileLev's legs extracted. Reference state passed by storage
    //  ref; the value-type lpShares delta is returned as (added, burned) and the
    //  Quid forwarder applies `lpShares += added - burned`.
    // ════════════════════════════════════════════════════════════════════

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

    // ════════════════════════════════════════════════════════════════════
    //  ETH deposit placement (body of Quid._depositETH). DELEGATECALL'd:
    //  msg.value/address(this) are Quid's, so the WETH wrap + the ether.fi
    //  placement leave from Quid. NO storage refs and NO per-LP attribution:
    //  this writes no state and takes no LP identity — the caller keeps every
    //  per-LP effect.
    // ════════════════════════════════════════════════════════════════════
    function depositETH(
        address weth, address aux, address ev,
        address sender, uint amount
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
            uint placed = _supplyEtherFi(ev, toDeposit);
            if (placed == 0) revert VenueUnavailable();   // chosen venue placed nothing ⇒ paused/unwired ⇒ NO fallback
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  θ / LVR math (kLvrWad, realizedAlphaWad, derivedThetaWad). Pure
    //  range geometry, extracted for EIP-170 headroom; view fns (no state
    //  written) and the live range bounds arrive as PRICES (§DE-TICK).
    //  Realized variance is NOT computed here — it is read off Core.
    // ════════════════════════════════════════════════════════════════════
    /// @notice The LVR coefficient K (WAD), derived LIVE from range geometry.
    /// §DE-TICK — same quantity, computed from PRICE bounds. The body only ever used RATIOS of the
    /// roots (`s/√Pb` and `√Pa/s`), and a ratio of roots is the root of the ratio:
    ///     s/√Pb = √(P/Pb)   ·   √Pa/s = √(Pa/P)
    /// so the tick→sqrt lookup disappears and the arithmetic is unchanged. √ survives as an
    /// OPERATION (range width is genuinely √-shaped) but nothing is stored or passed as a sqrt price.
    function kLvrWad(address core, uint loPrice, uint upPrice) public view returns (uint) {
        (uint priceWad,) = ICore(core).poolStats();
        return kLvrAt(priceWad, loPrice, upPrice);
    }

    /// @notice `kLvrWad` with the spot supplied rather than read — the whole formula, no chain.
    /// @dev    THE READ AND THE ARITHMETIC ARE SPLIT BECAUSE THE ARITHMETIC HAD DRIFTED IN COPIES.
    ///         Two test files reimplemented this closed form to reason about K off-chain, and when
    ///         `RANGE_DELTA` widened 20 → 200 bps the copies kept the old geometry's answer (`125e18`
    ///         for ±0.2%, against a live `≈12.56e18`) while still passing — a test measuring its own
    ///         literal cannot see the range move. `internal`, so it inlines and costs no deployed
    ///         bytecode; the on-chain caller above is unchanged.
    function kLvrAt(uint priceWad, uint loPrice, uint upPrice) internal pure returns (uint) {
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

    /// @notice θ derived live: **range fee yield** / (K·σ²). NOT clamped at 1e18 — the returned
    ///         value may exceed it, so the external views report HOW FAR above the no-throttle
    ///         threshold the range sits. Every consumer treats `θ >= 1e18` as a no-op
    ///         (`SwapLib.applyTheta`), and the real bound on range depth is the PHYSICAL
    ///         `backing − pooled` headroom in `clampByBacking` (audit #8), which θ never gates.
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
    function derivedThetaWad(address core, uint loPrice, uint upPrice) public view returns (uint) {
        uint sigmaSq = ICore(core).realizedVarianceWad();   // §E59: ONE source, read from Core
        if (sigmaSq == 0) return 1e18;
        uint kWad = kLvrWad(core, loPrice, upPrice);
        if (kWad == 0) return 1e18;
        uint work = SoladyMath.fullMulDiv(kWad, sigmaSq, 1e18);
        if (work == 0) return 1e18;
        // FAIL OPEN on an unmeasured premium register: `_rangeFeeYieldWad` returns 0 for both
        // `premium == 0` and `pooled == 0`, and dividing that through would make θ fail CLOSED —
        // the deadlock the docstring warns about (no depth ⇒ no fees ⇒ no premium ⇒ no depth,
        // forever), so a cold range could never bootstrap. Matches every other unmeasured path here
        // (`sigmaSq == 0`, `kWad == 0`, `work == 0`), and is safe for the same reason they are:
        // `SwapLib.clampByBacking` applies the PHYSICAL `backing − pooled` headroom independently.
        uint rangeFeeYield = _rangeFeeYieldWad(core);
        if (rangeFeeYield == 0) return 1e18;
        return SoladyMath.fullMulDiv(rangeFeeYield, 1e18, work);
    }

    // ════════════════════════════════════════════════════════════════════
    //  addLiq body (in-range pairing sizer). TWO clamps, both inside
    //  `SwapLib.addLiqBody`: the SOLVENCY surplus (`sizeBySurplus`, which is
    //  surplus-only — no asset-specific policy cap), then `clampByBacking` —
    //  the PHYSICAL `backing − pooled` headroom AND the live θ-budget. Writes
    //  no state. Extracted for EIP-170 headroom; the onlyUs guard stays in the
    //  Quid forwarder.
    // ════════════════════════════════════════════════════════════════════
    /// @dev §E270 — `wantTok` is the REQUEST and is never written; `deltaTok` is the evolving value
    ///      (surplus-sized, then theta/backing-capped). Mirrors the BTC range, which already kept its
    ///      request in `sats`.
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
    //  Body of Quid._rebalance (ETH side) — the venue-yield sync plus
    //  `SwapLib.rebalanceCore`. Mutates ONLY value-type accumulators (no per-LP
    //  Deposit / lpShares / pooled / native-ETH), returned as INCREMENTS/flags
    //  the thin Quid forwarder applies — so `_rebalance()`'s callers are
    //  byte-unchanged. No trading-fee distribution runs in here.
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

    /// @dev Plain-venue ETH balance = rangeETH − lev net-equity. §FOLD-VENUEBAL: this is the ONE
    ///      definition — `Quid._venueBalance` is a thin forwarder to it, so its `_withdraw`/
    ///      `_depositImpl` callers read exactly this. No-op subtraction when no leverage.
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
            // The branch's ONE live effect: LAST_REPACK := block.timestamp, applied by the forwarder.
            // NO trading-fee distribution happens here — `repack`/`reseat` report no fees at all, so
            // `feesPerShareInc`/`usdFeesInc` leave this body at zero. The fee LANE is DORMANT, not
            // removed: whether per-share accrual comes back is the deferred decision recorded at
            // `Core._fillDelta` (fees currently compound into POOLED_* instead).
            o.setLastRepack = true;
        }
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
    ///      ⚠️ NOT fork-proved. `SwapLib.deleverEthOnDelivery`'s own docblock marks this leg
    ///      🔴 UNVERIFIED (forge OOM), and the test that would close it —
    ///      `testReal_DeleverEthBacking_SwapOutTapsLeveredSlice`, booked in SPRINT.md — has never
    ///      been written. Do not cite this path as proved.
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
    //  ETH-VENUE CUSTODY. `Quid` IS the ETH venue: the bodies below run under its
    //  delegatecall, so `address(this)` is Quid and the weETH/eETH/WETH they value and move are
    //  Quid's own. `Vault` is the BTC range manager and calls none of them.
    // ══════════════════════════════════════════════════════════════════════════════

    /// @dev Quid's ETH-venue addresses, gathered by `Quid._ethCfg()` so the delegatecalled library
    ///      can operate on them (it cannot read Quid's own constant/immutable slots).
    struct EthCfg {
        address weth;
        address aux;
        address curvePool;   // bounds what weETH is DELIVERABLE — see deliverableETH
        address weeth;
        address eeth;        // ETHERFI_EETH (raw eETH transiently held mid wait-NFT)
        address levManager;
    }

    /// ether.fi deposit adapter — the SAME compile-time constant `Quid.ETHERFI_ADAPTER` pins; kept
    /// here so `supplyVenueBody` needs no extra `EthCfg` field.
    address internal constant ETHERFI_ADAPTER_VL = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;

    // ── Venue valuation ───────────────────────────────────────────────────


    /// @dev Body of Quid.rangeETH — AGGREGATE ETH-equivalent backing: weETH valued in ETH, idle
    ///      WETH, transient eETH, plus the levered book's net-equity.
    function _rangeETH(EthCfg memory c) internal view returns (uint total) {
        if (c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) total += IWeETH(c.weeth).getEETHByWeETH(w);
        }
        // Idle WETH is still ETH backing — count it at BOTH Quid (venue
        // custody, evacuated remainders) AND Aux (transient swap/deposit legs).
        total += IERC20(c.weth).balanceOf(address(this));
        total += IERC20(c.weth).balanceOf(c.aux);
        // Raw eETH transiently sits here mid wait-NFT withdrawal — real backing,
        // counted at BOTH Quid and Aux so a partial failure never strands it.
        if (c.eeth != address(0)) {
            total += IERC20(c.eeth).balanceOf(address(this));
            total += IERC20(c.eeth).balanceOf(c.aux);
        }
        // IL-protect: count the leveraged book's net-equity (gross collateral - debt), not gross. The buffer
        // half is debt-funded (offset by the LP's borrow), so counting gross would overstate solvency by the debt
        // -- the same error the fold fixed for `committed`. Net-equity is the LP's real deliverable claim (what
        // `closeLev` returns after auto-repaying the debt).
        // 🔴 §LEVBUF-NOT-STALE — **THIS SAID `levPooled = gross` AND THAT IS FALSE.** `Quid:975-977` states
        //    the real split — *"`levPooled` is the NET leg and `levBuf` the debt-funded buffer, so the live
        //    gross depth is their SUM"* — and `Quid:978` enforces exactly that (`gross == levPooled + levBuf`).
        //    MEASURED, both Γ arms, every run: `levPooled` and `ILevEquity.totalNetEquity()` are equal TO THE
        //    WEI (2,762,836,981,602,135,476), so `levPooled` is the NET leg and `gross − net == levBuf` exactly.
        //    ⛔ THE FALSE VERSION COST A WRONG ROOT-CAUSE. Reading `levPooled = gross` here makes
        //      `levPooled − totalNetEquity` look like the debt; it measures 0, which reads as "the debt is
        //      gone but `levBuf` still reports 0.1077 ETH" — a buffer that outlived its debt. **There is no
        //      such defect.** `levBuf` is correct; the subtraction was meaningless because both terms are the
        //      net leg. Do not re-derive that conclusion from this line.
        //    ⇒ The 2× range depth is `levPooled + levBuf`, and only the NET half is counted here — which is
        //      the whole point of the paragraph above: counting gross would overstate solvency by the debt.
        // try/catch degrades to "no lev credit". Unified with the BTC model.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) { total += n; } catch {}
        }
    }

    /// @notice Body of Vault.rangeETH.
    function rangeETH(EthCfg memory c) public view returns (uint) {
        return _rangeETH(c);
    }


    /// @notice Body of Quid.deliverableETH — SOLVENCY-side ETH backing with PARTIAL liquidity haircuts.
    ///
    /// @dev    READ THE NAME NARROWLY (§A.5c, re-derived 2026-07-27). This is NOT a promptness
    ///         guarantee and NOT a view-twin of the withdraw ladder. It haircuts the weETH side by
    ///         what CURVE can pay and subtracts the levered net equity, but it counts the raw eETH at
    ///         FULL FACE — which is not instantly convertible (the ether.fi legs need the offramp
    ///         ladder, whose rung 1 is a CURVE `weETH/WETH-ng` sale floored at 25 bps below the
    ///         ether.fi rate and whose rung 2 is a multi-day wait NFT — there is NO
    ///         deterministic-cost tier between them since the instant-redeem was removed 2026-08-06).
    ///
    ///         WHY OVER-STATEMENT IS SAFE RATHER THAN A BUG — it is not load-bearing for delivery.
    ///         It has exactly ONE reader (`Quid._withdraw`, via the `Aux.deliverableETH` forwarder),
    ///         and that reader tolerates over-statement: it uses this ONLY to cap `firstBurn`, i.e.
    ///         how much of a withdrawal is sourced from the in-range burn before the venue ladder
    ///         takes the remainder. The shortfall is then derived from the ACTUAL `sent`, never from
    ///         this number, so an over-statement shifts the sourcing ORDER and self-corrects.
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
    ///         Everything else (AAVE, MetaMorpho v1.1) has honest max-views — a real venue reports
    ///         `maxWithdraw` equal to the full position — and keeps the conservative read. Both branches
    ///         are try/catch'd: a venue whose view REVERTS (some vaults consult an external controller registry
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
            // `maxWithdraw` REVERTED. Such a vault does this whenever the holder has no
            // controller enabled on the EVC (fork-traced: `liquidityAdapter()` is also absent on
            // the current implementation, so BOTH probes above miss and we land here). Returning 0
            // valued a real, fully-liquid position at NOTHING — which understated backing and made
            // the venue unwithdrawable, so an LP whose ETH sat in such a venue could redeem and receive 0.
            //
            // Fall back to the share value, which is exactly what the `liquidityAdapter` branch
            // above uses for Morpho-V2. It is an UPPER bound on what the venue can pay if the vault
            // is illiquid — but every caller clamps its pull to what it actually needs and the
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
    ///      no deferral left to recover. Its purpose: virtual burn == real delivery.
    ///      ⚠️ Do NOT add a further per-venue cap on top. weETH has no genuinely-unreachable state:
    ///      if Curve cannot absorb it the wait-NFT redeems it at fair value from ether.fi, so the
    ///      value is SLOWER, never stuck. Such a cap would model a state that cannot occur, and
    ///      would understate backing on every read.
    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _rangeETH(c);
        // WEETH IS ONLY DELIVERABLE TO THE EXTENT CURVE CAN PAY FOR IT — this is what makes an
        // undeliverable slice DEFER. Without it `_rangeETH` counts weETH at full oracle value while
        // the exit can realise at most the pool's WETH, so delivery is overstated and the deferral
        // machinery never engages. (Measured: removing it breaks
        // test_SETTLE_LvrResidualIsDeferralNotLeak, test_RunSim_B_LiquidityRace_* and
        // testRT_DeliveredPlusRetainedEqualsPrincipal, all of which pass on stock main — a control
        // run, not an inference.)
        // Bound only the weETH-sourced portion: idle WETH and eETH are already deliverable as-is.
        if (c.curvePool != address(0) && c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) {
                uint weethEth = IWeETH(c.weeth).getEETHByWeETH(w);
                uint payable_ = (ICurvePool(c.curvePool).balances(0) * 9) / 10;   // same headroom as offrampBody
                if (weethEth > payable_) total -= (weethEth - payable_);          // the surplus DEFERS
            }
        }
        // The leverage net-equity is solvency backing (counted in rangeETH as net) but NOT deliverable
        // from here (unwind-only via closeLev -- the LP gets it back by repaying debt + withdrawing coll,
        // not from redemption). Exclude the same net-equity term rangeETH added, so deliverableETH == base
        // (non-levered venue ETH), byte-identical to the prior gross-in/gross-out result. Redemptions never draw it.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) {
                total = total > n ? total - n : 0;
            } catch {}
        }
    }

    // ── Supply ────────────────────────────────────────────────────────────





    /// @notice Consolidated venue-supply body — the `transferFrom` + adapter call for every ETH supply
    ///         wrapper, so the Quid forwarders keep only their gate (bytecode OUTSIDE the
    ///         EIP-170-critical Quid). `from` = the approver the WETH is pulled from: Quid itself for
    ///         `Quid.supplyEtherFi` (which needs no gate — the caller is the contract), AUX for
    ///         `Quid.supplyFromAux` (`NotAux`).
    /// @dev There is NO venue selector. Every value routes to the ether.fi adapter, so there is
    ///      nothing to choose between.
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
        if (ETHERFI_ADAPTER_VL == address(0)) return 0;
        IERC20(c.weth).transferFrom(from, address(this), amount);
        IDepositAdapter(ETHERFI_ADAPTER_VL).depositWETHForWeETH(amount, address(this));
        return amount;
    }

    // ── Withdraw ────────────────────────────────────────────────────────────

    /// @notice Body of Quid._withdrawETH. TWO sources, in order: idle WETH (swept from Aux, then
    ///         held here), and — only if that is short — ONE opportunistic weETH→WETH Curve sale.
    ///         There is no venue-pull rung beyond those: whatever WETH is on hand after them is what
    ///         gets served, and a short serve is a PARTIAL fill, not a revert. Only WETH is served.
    function withdrawETH(EthCfg memory c, SwapLib.OfframpCfg memory off,
        address token, uint amount, address to) public returns (uint sent) {
        if (amount == 0) return 0;
        require(token == c.weth, "ethv:notWeth");
        // Sweep any idle WETH from Aux in first (Aux approved us), preserving the
        // idle-first order (rangeETH counts Aux idle as backing).
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

    // ── ether.fi OFFRAMP ────────────────────────────────────────────────────────────────────
    //  Its ONE caller is `Quid.offrampEtherFi` (`Quid.sol:206`).
    /// @notice Body of Quid.offrampEtherFi — the exit ladder. Rung 1 = Curve pool sale; rung 2 = wait NFT.
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
        // There is deliberately NO ether.fi instant-redeem rung: ether.fi's instant-redeem buffer
        // measured ZERO at every sampled block, because the pool absorbs the flow first.
        // RUNG 2 (last) — no-fee withdrawal NFT, minted to the WITHDRAWER.
        //
        // ⚠️ THE LADDER IS TWO RUNGS, AND THE INTENDED FIRST RUNG IS MISSING. Today it sells weETH on
        // CURVE (rung 1) and falls back to a redemption claim (rung 2). The DESIGN is: BORROW WETH
        // against the weETH, deliver that, and repay from the redemption — with the pool SALE as the
        // borrow's ONLY alternative (owner, 2026-08-09). Under that design `waitNft` stops being a way
        // to serve an LP and becomes the REPAYMENT of the borrow.
        //
        // The sale is charged ONLY on the slice `weethIn` covers — i.e. the weETH this contract holds
        // FREE (the `if (weethIn > bal)` clamp at the top of this function pins it to
        // `balanceOf(address(this))`). Levered collateral sits in per-LP venue escrows and is
        // untouchable here, so the sale is a bounded slice, NOT the whole withdrawal.
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
    ///         pool sale above it fails its 25 bps floor (`covered * 9975 / 10_000`),
    ///         or when this contract holds no free weETH to sell. Redemption never
    ///         reaches here: redemption is stables-only. ⚠️ It is the ONLY thing under
    ///         rung 1 — there is no instant-redeem buffer to exhaust first, so a pool
    ///         that cannot fill puts the withdrawer straight into a multi-day queue.
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
