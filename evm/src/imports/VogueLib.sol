// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SwapLib} from "./SwapLib.sol";
// §A.52: the SHARED WETH view (was a file-local `IWETH_VG` restating the same members).
import {IWETH9} from "./ILevVenue.sol";
// §A.52: ONE canonical Vogue view (was two file-local variants, `IVogue_VG` + `IVogueView_VG`).
import {IVogue} from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {ILevEquity} from "./Interfaces.sol";
import {ILevHost} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {ICore} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";

// ── Minimal external surfaces the extracted Vogue bodies touch. The library is
//    DELEGATECALL'd (public fns), so `address(this)` is Vogue: every immutable
//    Vogue reads (V4/AUX/WETH/QUID/EV) is passed in via a cfg struct or an
//    interface handle; reference-type state (LP Deposit + the levPooled/
//    levBufferUsd/ethfiBacked/aaveBacked mappings) is passed by STORAGE REF so
//    writes land on Vogue's slots. Value-type state (lpShares) is mutated by
//    RETURNING the delta, applied by the thin Vogue forwarder. ─────────────────
/// @title  VogueLib — sizeable Vogue bodies extracted to free bytecode under the
///         EIP-170 limit. DELEGATECALL'd by Vogue (public fns): inside each,
///         `address(this)`/`msg.sender`/`msg.value` are Vogue's, so token custody
///         and external calls leave from Vogue exactly as the former in-Vogue
///         bodies did. Byte-for-byte semantics; only the home moved.
library VogueLib {
    uint constant WAD = 1e18;

    // Venue tags mirror Vogue's constants (per-deposit venue routing).
    // Deliberately NO VENUE_ETHERFI (=1) dispatch tag: per the venue TODO, ether.fi is NOT a distinct
    // user choice — it ALWAYS routes through Rover (VENUE_ROVER), and direct weETH is used internally
    // ONLY as the Rover-self-liquidated fallback (see `_supplyEtherFi`).
    uint8 constant VENUE_AAVE    = 2;
    uint8 constant VENUE_GALAXY  = 3;
    uint8 constant VENUE_ROVER   = 4;
    uint8 constant VENUE_EULER   = 5;
    uint8 constant VENUE_GAUNTLET= 6;
    uint8 constant VENUE_SPLIT   = 0;
    /// A chosen venue (or a SPLIT leg) placed 0 — paused / unwired / de-allowlisted. We do NOT
    /// silently redirect to a fallback venue: Galaxy AND Gauntlet are Morpho CURATED vaults (Aave/
    /// Euler likewise), so NONE can be assumed always-live. Fail loud — the depositor picks a live venue.
    error VenueUnavailable();

    /// @dev ether.fi supply — ALWAYS via Rover (the protocol-owned weETH/WETH v3 LP). Direct weETH
    ///      (supplyEtherFi) is used ONLY here, and ONLY as the internal FALLBACK when Rover cannot take
    ///      the deposit. Two ways Rover declines, BOTH fall through to direct weETH:
    ///        1. self-liquidated — the v3 pool has drained, so `rover.deposit` REVERTS (caught below);
    ///        2. unavailable — Rover is unset/inert, so `supplyEtherFiToRover` RETURNS 0 (no revert).
    ///      Either way the ether.fi exposure is preserved as a direct weETH position on the SAME
    ///      ethfiBacked wall + offramp ladder. VENUE_ETHERFI is not a user-facing venue — this is the
    ///      single internal use of the direct-weETH path. Returns 0 only if BOTH paths place nothing
    ///      (⇒ caller reverts VenueUnavailable, no silent strand).
    function _supplyEtherFi(address ev, uint amount) private returns (uint placed) {
        try IEthVenue(ev).supplyEtherFiToRover(amount) returns (uint p) { placed = p; }
        catch { placed = 0; }                                     // self-liquidated: Rover deposit reverted
        if (placed == 0) placed = IEthVenue(ev).supplyEtherFi(amount); // → direct weETH fallback
    }

    // Mirror Vogue's selectors (name-derived) for the delegatecalled bodies.
    error InsufficientBalance();
    error NotOwner();
    error BadPercent();
    error Dust();

    // ════════════════════════════════════════════════════════════════════
    //  IL-protect: ETH levered band slice (full-2x fee lane). Bodies of
    //  Vogue._reconcileLev's legs extracted. Reference state passed by storage
    //  ref; the value-type lpShares delta is returned as (added, burned) and the
    //  Vogue forwarder applies `lpShares += added - burned`.
    // ════════════════════════════════════════════════════════════════════

    /// @dev Vogue immutables the levered-band bodies touch.
    struct LevCfg { address core; address aux; address weth; }
    /// @dev Live pool range + reconcile targets, bundled to stay off the stack.
    struct LevP { uint160 sqrtP; int24 tickLower; int24 tickUpper; address lm; uint gross; }

    function levManager(address aux) public view returns (address) {
        address host = aux == address(0) ? address(0) : IAux(aux).ethVenue();
        return host == address(0) ? address(0) : ILevHost(host).LEV_MANAGER();
    }
    function bufTarget(address lm, address lp) public view returns (uint) {
        return lm == address(0) ? 0 : ILevEquity(lm).debtUsd(lp) / 1e12; // 1e18 USD -> 6-dec
    }

    /// @notice Burn the current slice then re-add the gross target as two legs.
    ///         NET model: `pooled`/`lpShares` carry ONLY the net-equity leg; the debt-funded
    ///         buffer is depth (fee weight + V4) tracked in `levBuf`/`totalBuffer`. Returns the
    ///         NET lpShares deltas (addedNet, burnedNet) AND the buffer deltas (bufAdded, bufBurned)
    ///         for the Vogue forwarder to apply (lpShares += addedNet - burnedNet; totalBuffer += ...).
    function reconcileLegs(
        LevCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, LevP memory p
    ) public returns (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) {
        if (levPooled[lp] > 0 || levBuf[lp] > 0)
            (burnedNet, bufBurned) = levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        if (p.gross > 0)
            (addedNet, bufAdded) = levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
    }

    /// @dev Burn `lp`'s ENTIRE levered slice tokenlessly (no delivery). Burns the GROSS depth
    ///      (net leg `levPooled` + buffer `levBuf`) from V4; the net leg leaves `pooled`/`lpShares`,
    ///      the buffer leaves `totalBuffer` (via the bufBurned return) — a liquidation leaves the
    ///      basket intact.
    function levBurnAll(
        LevCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, LevP memory p
    ) public returns (uint netBurned, uint bufBurned) {
        uint netRem = levPooled[lp];
        if (netRem > LP.pooled) netRem = LP.pooled;   // net leg is in pooled
        bufBurned = levBuf[lp];
        uint grossRem = netRem + bufBurned;
        if (grossRem == 0) { levBufferUsd[lp] = 0; return (0, 0); }
        ICore(c.core).modLP(false, p.sqrtP, grossRem, 0, p.tickLower, p.tickUpper, address(0));
        LP.pooled -= netRem; levPooled[lp] -= netRem;  // net leg leaves pooled/lpShares
        levBuf[lp] = 0; levBufferUsd[lp] = 0;          // buffer leg leaves totalBuffer (bufBurned)
        return (netRem, bufBurned);
    }

    /// @dev Add `lp`'s full-2x slice as TWO legs: net-equity (goes into pooled/lpShares) + the
    ///      debt-funded buffer (goes into levBuf/totalBuffer, NOT equity). Returns (addedNet, bufAdded).
    function levAddGross(
        LevCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, LevP memory p
    ) public returns (uint addedNet, uint bufAdded) {
        uint price = IAux(c.aux).getTWAPforAsset(c.weth, 1800);
        if (price == 0) return (0, 0);
        uint netEq = ILevEquity(p.lm).netEquityEth(lp);
        addedNet = levAddNet(c, LP, levPooled, lp, netEq, price, p);
        if (p.gross > netEq)
            bufAdded = levAddBuf(c, LP, levBufferUsd, levBuf, lp, p.gross - netEq, price, p);
    }

    /// @dev NET-equity leg — basket-surplus USD. Grows pooled/lpShares (equity) + levPooled (the
    ///      unwind-only net slice) + V4 depth.
    function levAddNet(
        LevCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        address lp, uint netEq, uint price, LevP memory p
    ) public returns (uint added) {
        (uint netUsd, uint netEth) = IVogue(address(this)).addLiq(netEq, price, false);
        if (netEth == 0) return 0;
        LP.pooled += netEth; levPooled[lp] += netEth;
        ICore(c.core).modLP(false, p.sqrtP, netEth, netUsd, p.tickLower, p.tickUpper, lp);
        return netEth;
    }

    /// @dev BUFFER leg — the debt-funded half. It is fee-earning V4 DEPTH but NOT equity, so it grows
    ///      levBuf (fee weight + totalBuffer via the return) and the V4 position, but NOT pooled/lpShares.
    ///      USD = buffer collateral at band price, CAPPED at the LP's OWN debt (debt-backed; folds into POOLED_USD).
    function levAddBuf(
        LevCfg memory c, Types.Deposit storage /*unused*/,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, uint bufEth, uint price, LevP memory p
    ) public returns (uint added) {
        uint bufUsd = LevMath.capBufferUsd(bufEth, price, ILevEquity(p.lm).debtUsd(lp));
        if (bufUsd == 0) return 0;
        levBuf[lp] += bufEth; levBufferUsd[lp] += bufUsd;   // depth + fee weight, NOT equity
        ICore(c.core).modLP(false, p.sqrtP, bufEth, bufUsd, p.tickLower, p.tickUpper, lp);
        return bufEth;
    }

    // ════════════════════════════════════════════════════════════════════
    //  ETH-venue deposit routing (body of Vogue._depositETH). DELEGATECALL'd:
    //  msg.value/address(this) are Vogue's, so the WETH wrap + venue placement
    //  leave from Vogue. The per-LP wall attribution (ethfiBacked/aaveBacked) is
    //  written via STORAGE REF. Byte-identical to the former in-Vogue body.
    // ════════════════════════════════════════════════════════════════════
    function depositETH(
        address weth, address aux, address ev,
        mapping(address => uint) storage ethfiBacked,
        address sender, address pledge, uint amount, uint8 venue
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
            // Route ALL WETH at Vogue to the depositor's CHOSEN ETH venue. Only the ether.fi/Rover
            // slice is attributed (ethfiBacked, capped at `sent` = the LP's own capital) — it exits via
            // the isolated offramp ladder; the fungible 4626 venues (AAVE/Euler/Galaxy/Gauntlet) withdraw
            // from the pooled book and need no per-LP attribution.
            // NO ALWAYS-LIVE FALLBACK (user, 2026-07-26): Galaxy AND Gauntlet are Morpho CURATED vaults
            // (Aave/Euler curated too), so NONE can be assumed always-live. A chosen venue (or a SPLIT
            // leg) that places 0 — paused / unwired / de-allowlisted — REVERTS; it is NEVER silently
            // swept to Galaxy or any other default. The depositor must pick a venue that is live.
            uint toDeposit = IWETH9(weth).balanceOf(address(this));
            IWETH9(weth).approve(aux, toDeposit);
            uint placed;
            bool attrib = pledge != address(0);
            uint8 v = venue;
            if (v == VENUE_ROVER) {
                // ether.fi = the depositor's ONLY ether.fi choice, and it ALWAYS routes through Rover
                // (the protocol-owned weETH/WETH v3 LP). Per the venue TODO, VENUE_ETHERFI (direct weETH)
                // is NOT a user-facing venue — `_supplyEtherFi` uses it INTERNALLY, and ONLY as the
                // fallback for when the Rover NFT has self-liquidated (v3 pool drained ⇒ the Rover deposit
                // reverts). Either path is ether.fi-sourced ⇒ attributed (ethfiBacked) + exits via the offramp.
                placed = _supplyEtherFi(ev, toDeposit);
                if (placed > 0 && attrib) ethfiBacked[pledge] += Math.min(placed, sent);
            } else if (v == VENUE_AAVE) {
                placed = IEthVenue(ev).supplyAaveEth(toDeposit);
            } else if (v == VENUE_EULER) {
                placed = IEthVenue(ev).supplyEulerEth(toDeposit);
            } else if (v == VENUE_GAUNTLET) {
                placed = IEthVenue(ev).supplyGauntlet(toDeposit);
            } else if (v == VENUE_GALAXY) {
                // Explicit Galaxy (its own Morpho vault, via vogueOp). vogueOp REVERTS if that vault is
                // paused/de-allowlisted, so a down Galaxy fails loud right here — no fallback.
                IEthVenue(ev).vogueOp(false, toDeposit, 0, bytes32(0));
                placed = toDeposit;
            } else if (v == VENUE_SPLIT) {
                // User TODO: split EQUALLY across ALL venues {AAVE, Euler, Rover, Galaxy, Gauntlet} to
                // diversify curator risk. NO sink: if ANY leg places short — a paused/unwired curated
                // vault — the WHOLE deposit REVERTS, never over-concentrated into one venue. Only the
                // Rover (ether.fi) fifth is attributed.
                uint fifth = toDeposit / 5;
                uint extSum;                              // the 4 curated 4626 legs (return the WETH placed)
                extSum += IEthVenue(ev).supplyAaveEth(fifth);
                extSum += IEthVenue(ev).supplyEulerEth(fifth);
                uint roverPut = _supplyEtherFi(ev, fifth);   // ether.fi leg: Rover, or direct-weETH if Rover self-liquidated
                if (roverPut > 0 && attrib) ethfiBacked[pledge] += Math.min(roverPut, sent);
                extSum += roverPut;
                extSum += IEthVenue(ev).supplyGauntlet(fifth);
                if (extSum < fifth * 4) revert VenueUnavailable();   // a curated leg placed short ⇒ fail loud
                IEthVenue(ev).vogueOp(false, toDeposit - extSum, 0, bytes32(0)); // Galaxy leg = its fifth + dust; reverts if paused
                placed = toDeposit;
            }
            if (placed == 0) revert VenueUnavailable();   // chosen venue placed nothing ⇒ paused/unwired ⇒ NO fallback
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  θ / LVR / realized-vol math (bodies of Vogue._kLvrWad, realizedAlphaWad,
    //  realizedVarianceWad, derivedThetaWad). Pure band-geometry + oracle-ring
    //  math extracted for EIP-170 headroom; view fns (no state written), the
    //  live band ticks arrive as params. Byte-identical to the in-Vogue bodies.
    // ════════════════════════════════════════════════════════════════════
    uint32  constant THETA_STEP = 300;         // 5-min sample window
    uint    constant THETA_N    = 8;           // 8 windows -> 40-min realized-vol horizon
    uint    constant SECS_PER_YEAR = 31536000;

    /// @notice The LVR coefficient K (WAD), derived LIVE from band geometry.
    function kLvrWad(address core, int24 lo, int24 up, bool isBTC) public view returns (uint) {
        (uint160 sqrtP,,) = ICore(core).poolStats(0, 0, isBTC);
        if (lo >= up) return 0;
        uint sqrtPa = TickMath.getSqrtPriceAtTick(lo);
        uint sqrtPb = TickMath.getSqrtPriceAtTick(up);
        uint s = sqrtP < sqrtPa ? sqrtPa : (sqrtP > sqrtPb ? sqrtPb : sqrtP);
        uint r1 = FullMath.mulDiv(s, 1e18, sqrtPb);
        uint r2 = FullMath.mulDiv(sqrtPa, 1e18, s);
        uint denom = 2e18;
        if (r1 + r2 >= denom) return 0;
        denom -= (r1 + r2);
        return FullMath.mulDiv(1e18, 1e18, 4 * denom);
    }

    /// @notice The band's LIVE realized concavity α (WAD).
    function realizedAlphaWad(address core, int24 lo, int24 up, bool isBTC) public view returns (uint) {
        (uint160 sqrtP,,) = ICore(core).poolStats(0, 0, isBTC);
        if (lo >= up) return 0;
        uint sqrtPa = TickMath.getSqrtPriceAtTick(lo);
        uint sqrtPb = TickMath.getSqrtPriceAtTick(up);
        uint s = sqrtP < sqrtPa ? sqrtPa : (sqrtP > sqrtPb ? sqrtPb : sqrtP);
        uint r1 = FullMath.mulDiv(s, 1e18, sqrtPb);
        uint r2 = FullMath.mulDiv(sqrtPa, 1e18, s);
        if (r1 >= 1e18 || r1 + r2 >= 2e18) return 0;
        return FullMath.mulDiv(1e18 - r1, 1e18, 2e18 - r1 - r2);
    }

    /// @dev Annualized WAD yield the BAND itself earned on the capital it put at risk — θ's
    ///      numerator (#107/D3). Both inputs come off Core and are 6-dec USD, so the ratio is
    ///      unitless and needs no scale plumbing:
    ///        • numerator   = `premiumEwmaUsd` — retained scarcity premium, decayed over ~48h.
    ///        • denominator = that pool's in-range band USD (`POOLED_USD_*`), i.e. the capital that
    ///          actually bore the IL. Using the band's own capital (not TVL, not backing) is what
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
    ///      "did realized fees cover the IL we bore?" (`spec.md` §3.8), whereas the derived form would
    ///      only answer "does our own pricing formula contain σ²" — i.e. nothing.
    ///
    ///      ⚠️ `PREMIUM_ANNUALIZE` is the ONE number here worth reviewing. An exponential EWMA with
    ///      half-life H has mean lifetime H/ln2, so it represents roughly that much accrual: for the
    ///      48h `FLOW_DECAY`, 48/ln2 ≈ 69.25h, and a year is 8760/69.25 ≈ 126.5 such windows (rounded UP to 127 per user). σ² is
    ///      ANNUALIZED (see `realizedVarianceWad`), so the numerator must be annualized too or θ is
    ///      dimensionally wrong and would systematically under-size the band. 127 is that factor,
    ///      not a tuning knob — if `FLOW_DECAY`'s half-life ever changes, this must change with it.
    uint internal constant PREMIUM_ANNUALIZE = 127;

    function _bandFeeYieldWad(address core, bool isBTC) internal view returns (uint) {
        uint prem6 = ICore(core).premiumEwmaUsd(isBTC);
        if (prem6 == 0) return 0;                       // unmeasured ⇒ caller fails OPEN
        uint pooled6 = isBTC ? ICore(core).POOLED_USD_BTC() : ICore(core).POOLED_USD_ETH();
        if (pooled6 == 0) return 0;                     // no band capital at risk ⇒ nothing to size
        return FullMath.mulDiv(prem6 * PREMIUM_ANNUALIZE, 1e18, pooled6);
    }

    /// @notice θ derived live: **band fee yield** / (K·σ²), clamped to <=1.
    ///
    /// @dev #107/D3 (2026-07-26): the numerator is the BAND's realized market-making yield, NOT the
    ///      reserve `avgYield` it used to read. θ is Merton's `μ/(K·σ²)` — the optimal fraction of
    ///      capital to commit to a RISKY bet — and the bet being sized here is IL-bearing in-range
    ///      band depth. The compensation for that bet is the retained scarcity premium, full stop.
    ///      Reserve `avgYield` is earned whether the dollar leg is banded or sits idle (`spec.md`),
    ///      so it is NOT marginal compensation for IL and using it over-sized the band. Per the user:
    ///      *"the size of the band should have nothing to do with avgYield at all — that is only a
    ///      number that tells us how much QUI to mint upfront."* Two different jobs, two inputs.
    ///      Kept θ-LOCAL (read straight off Core) rather than folded into `avgYield`, precisely
    ///      because `avgYield` also feeds `seedFee` mint-valuation — folding would have moved mint
    ///      pricing as a side effect.
    ///
    ///      This makes θ encode the protocol's own rationality test directly: premium in the
    ///      numerator over σ² in the denominator IS "are fees beating LVR?" (`spec.md` §3.8).
    ///
    ///      FAILS OPEN on an unmeasured register (`premium == 0` ⇒ return 1e18), matching every
    ///      other unmeasured path here (`sigmaSq == 0`, `kWad == 0`, cold oracle ring) and the
    ///      documented "θ≥1 fails open (calm/unmeasured) → only HEADROOM binds". That is what lets a
    ///      cold band BOOTSTRAP: a fresh band has earned no premium, and failing CLOSED would clamp
    ///      it to zero depth forever (no depth ⇒ no fees ⇒ no depth). Failing open is safe rather
    ///      than unbounded because `SwapLib.clampByBacking` applies the PHYSICAL
    ///      `backing − pooled` headroom independently — audit #8 was closed so that "every path
    ///      stays bounded at the real backing even when θ fails open".
    /// @dev `aux` was DROPPED (2026-07-27): the only thing that read it was the old `avgYield`
    ///      numerator, which #107/D3 replaced with the band-fee premium EWMA read off `core`. The
    ///      parameter has been dead since that change — the compiler flagged it as unused.
    function derivedThetaWad(address core, int24 lo, int24 up, bool isBTC) public view returns (uint) {
        uint sigmaSq = ICore(core).realizedVarianceWad(isBTC);   // §E59: ONE source, read from Core
        if (sigmaSq == 0) return 1e18;
        uint kWad = kLvrWad(core, lo, up, isBTC);
        if (kWad == 0) return 1e18;
        uint work = FullMath.mulDiv(kWad, sigmaSq, 1e18);
        if (work == 0) return 1e18;
        // The `theta > 1e18 ? 1e18 : theta` clamp that used to close this function is DELETED — it
        // adds no safety. EVERY consumer already short-circuits at the same threshold:
        // `SwapLib.applyTheta:1299` is `if (thetaEff >= 1e18) return available;` (so 1e18 and 12e18
        // are byte-identical no-ops), `VogueLib:470` and `BtcVaultLib:136` both document and treat
        // ">= 1e18 ⇒ no-op / fail-open", and the real bound on band depth is the PHYSICAL
        // `backing − pooled` headroom in `clampByBacking` (audit #8), which θ never gates.
        // Removing it also makes the external views (`Vogue.derivedThetaWad`,
        // `Vault.derivedThetaWadBtc`) strictly MORE informative: they now report HOW FAR above the
        // no-throttle threshold the band is, instead of flattening everything to exactly 1.0 — which
        // matters more post-#107/D3, since a band earning real premium in a calm tape clears 1e18
        // routinely where the old reserve-`avgYield` numerator rarely did.
        // FAIL OPEN on an unmeasured premium register. This was MISSING (fixed 2026-07-26): the
        // docstring above already promised it, and `_bandFeeYieldWad` returns 0 for both
        // `premium == 0` and `pooled == 0`, so `mulDiv(0, ...)` made θ fail CLOSED — the exact
        // deadlock the docstring warns about (no depth ⇒ no fees ⇒ no premium ⇒ no depth, forever).
        // A cold band could never bootstrap. Matches every other unmeasured path here
        // (`sigmaSq == 0`, `kWad == 0`, `work == 0`), and is safe for the same reason they are:
        // `SwapLib.clampByBacking` applies the PHYSICAL `backing − pooled` headroom independently.
        uint bandFeeYield = _bandFeeYieldWad(core, isBTC);
        if (bandFeeYield == 0) return 1e18;
        return FullMath.mulDiv(bandFeeYield, 1e18, work);
    }

    /// @notice Annualized realized variance (WAD) from Core's oracle ring.

    // ════════════════════════════════════════════════════════════════════
    //  addLiq body (in-range pairing sizer). Clamps deltaTok to the three
    //  bounds: SOLVENCY surplus (+BTC policy cap via SwapLib.sizeBySurplus),
    //  PHYSICAL inventory, and the live θ-budget. View-ish (no state written).
    //  Extracted for EIP-170 headroom; the onlyUs guard stays in the Vogue
    //  forwarder. Byte-identical to the in-Vogue body.
    // ════════════════════════════════════════════════════════════════════
    function addLiq(address core, address aux, uint deltaTok, uint price, bool isBTC, uint grossBuffer)
        public returns (uint usdOut, uint outDelta) {
        (uint[15] memory deposits,,,) = IAux(aux).get_deposits();
        uint committedBoth = ICore(core).committedUsd18();
        uint targetUSD; uint surplus;
        (deltaTok, targetUSD, surplus) =
            SwapLib.sizeBySurplus(deposits[14], committedBoth, deltaTok, price);
        if (surplus == 0) return (0, 0);

        // ETH: vogueETH (NET venue principal) + grossBuffer (totalBuffer) = gross-consistent with POOLED_ETH.
        // BTC: native backing = Core.btcThetaBacking() (lpSharesBTC net + totalBufferBTC gross) -- the SAME
        // source the LP-add clamp (BtcVaultLib._thetaClampBtc) uses, so this reseat throttles on the real
        // risk capital and can't collapse the band to ~0. NOT the disjoint WBTC-donation vogueBTC, and NOT
        // Vogue's ETH `grossBuffer` (wrong asset for a BTC band; btcThetaBacking carries the BTC buffer).
        // ONE principle (SwapLib.clampByBacking): physical backing HEADROOM (backing − pooled) AND the theta
        // risk-budget (θ·backing − pooled) — shared verbatim with the BTC LP-add clamp
        // (BtcVaultLib._thetaClampBtc). `backing` = the IL-bearing capital (ETH: vogueETH venue principal +
        // gross buffer; BTC: Core.btcThetaBacking = lpSharesBTC + gross buffer). vogueAvail/pooled inlined into
        // the call to keep this frame off the legacy-pipeline stack (no via-IR).
        uint capped = SwapLib.clampByBacking(
            _liveTheta(isBTC),
            isBTC ? ICore(core).btcThetaBacking() : IAux(aux).vogueETH() + grossBuffer,
            isBTC ? ICore(core).POOLED_BTC() : ICore(core).POOLED_ETH(),
            deltaTok);
        if (capped < deltaTok) {
            deltaTok = capped;
            targetUSD = FullMath.mulDiv(deltaTok, price, WAD);
        }
        usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        outDelta = deltaTok;
    }

    /// @dev addLiq's live θ: derivedThetaWad, fail-OPEN (θ=1) when the oracle ring
    ///      is too thin to measure vol. Self-call to Vogue's forwarder (delegatecall
    ///      context: address(this) == Vogue).
    function _liveTheta(bool isBTC) private view returns (uint) {
        try IVogue(address(this)).derivedThetaWad(isBTC) returns (uint t) { return t == 0 ? 1e18 : t; }
        catch { return 1e18; }
    }

    // ════════════════════════════════════════════════════════════════════
    //  Body of Vogue._rebalance (ETH side) — the fee/yield HARVEST cluster
    //  (_syncYield + SwapLib.rebalanceCore + _calcYield/_distributeV4Fees).
    //  Mutates ONLY value-type accumulators (no per-LP Deposit / lpShares /
    //  pooled / native-ETH), returned as INCREMENTS/flags the thin Vogue
    //  forwarder applies — so `_rebalance()`'s callers are byte-unchanged.
    //  The dead `_calcYield` yield return (discarded in _rebalance) is dropped.
    // ════════════════════════════════════════════════════════════════════
    struct RebalIn {
        address core; address aux; address ev; address weth;
        bool token1isETH; uint lpShares; uint totalLevPooled; uint totalBuffer;
        int24 lowerTick; int24 upperTick; uint bookmark;
    }
    struct RebalOut {
        uint160 sqrtPriceX96; int24 tickLower; int24 tickUpper; uint128 myLiquidity; uint resolvedTwap;
        uint feesPerShareInc; uint usdFeesInc; uint venueFeesPerShareInc; uint newBookmark;
        bool setLastRepack; bool reseatBump;
    }

    /// @dev Plain-venue ETH balance = vogueETH − lev net-equity (replica of Vogue._venueBalance; that one STAYS in
    ///      Vogue for its _withdraw/_depositImpl callers). No-op subtraction when no leverage.
    function _venueBalanceLib(address ev, address aux) internal returns (uint total) {
        total = IEthVenue(ev).vogueOp(false, 0, 2, bytes32(0));
        address lm = levManager(aux);
        if (lm != address(0)) {
            try ILevEquity(lm).totalNetEquityEth() returns (uint n) { total = total > n ? total - n : 0; } catch {}
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
                    o.venueFeesPerShareInc = FullMath.mulDiv(current - c.bookmark, WAD, plainDepth);
                o.newBookmark = current;
            }
        }
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, c.weth, false, c.upperTick, c.lowerTick);
        if (r.didRepack) {
            // _calcYield's live effect: reorder to token-canonical + _distributeV4Fees; the APY `yield` it also
            // computed was discarded by _rebalance, so it is dropped. LAST_REPACK := block.timestamp (forwarder).
            (uint fees, uint usd_fees) = c.token1isETH ? (r.fees1, r.fees0) : (r.fees0, r.fees1);
            (o.feesPerShareInc, o.usdFeesInc) = SwapLib.feeIncrements(fees, usd_fees, c.lpShares + c.totalBuffer);
            o.setLastRepack = true;
        } else if (r.jitFees) {
            // JIT-snipe defense: fees already canonical (USD,tok) by rebalanceCore; distribute without re-reorder.
            (o.feesPerShareInc, o.usdFeesInc) = SwapLib.feeIncrements(r.jitFeesTok, r.jitFeesUsd, c.lpShares + c.totalBuffer);
        }
        if (r.tickLower != c.lowerTick || r.tickUpper != c.upperTick) o.reseatBump = true; // ticks recentered → re-anchor
        o.sqrtPriceX96 = r.sqrtPriceX96; o.tickLower = r.tickLower; o.tickUpper = r.tickUpper;
        o.myLiquidity = r.myLiquidity; o.resolvedTwap = r.resolvedTwap;
    }

    /// @dev Replica of Vogue._refreshBookmarks (that one STAYS in Vogue for its many other callers): rebaseline
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
        venueBm[user] = FullMath.mulDiv(plainW, venueFeesPerShare, WAD);
    }

    // ════════════════════════════════════════════════════════════════════
    //  Body of Vogue._transferShares — VERBATIM relocation. Settles BOTH
    //  parties' pending rewards (compound ETH → pooled/lpShares, accrue USD →
    //  usd_owed) BEFORE moving principal, so the moved pooled carries no
    //  past-reward claim. The value-type `lpShares` growth is returned as a
    //  delta the Vogue forwarder applies; the Transfer event stays in Vogue.
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
            (uint ethReward, uint usdReward) = IVogue(address(this)).pendingRewards(from);
            if (ethReward > 0) { L.pooled += ethReward; lpSharesDelta += ethReward; }
            if (usdReward > 0) L.usd_owed += usdReward;
        }
        // Settle pending rewards for `to` (if they have a position).
        Types.Deposit storage R = autoManaged[to];
        if (R.pooled > 0) {
            (uint ethReward, uint usdReward) = IVogue(address(this)).pendingRewards(to);
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
    //  Body of Vogue.pull — reduce/close a self-managed boundary order. VERBATIM
    //  relocation: owner + maturity + percent guards, liquidity slice, the
    //  full-close array swap-pop cleanup, and the V4.outOfRange burn. Storage
    //  refs (selfManaged/positions) mutate in place; the nonReentrant guard stays
    //  in the Vogue forwarder. `owner` = msg.sender (preserved through delegatecall).
    // ════════════════════════════════════════════════════════════════════
    function pullBody(
        address core,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint id, int percent, address token, address owner
    ) public {
        Types.SelfManaged storage position = selfManaged[id];
        if (position.owner != owner) revert NotOwner();
        require(block.number >= position.created + 47, "too soon");
        if (percent == 0 || percent > 100) revert BadPercent();
        int liquidity = position.liq * percent / 100;
        if (liquidity == 0) revert Dust();
        int24 lower = position.lower;
        int24 upper = position.upper;
        uint[] storage myIds = positions[owner];
        uint lastIndex = myIds.length > 0 ? myIds.length - 1 : 0;
        if (percent == 100) {
            delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) myIds[i] = myIds[lastIndex];
                    myIds.pop(); break;
                }
            }
        } else {
            position.liq -= liquidity;
            if (position.liq == 0) revert Dust();
        }
        ICore(core).outOfRange(false, owner, -liquidity, lower, upper, token);
    }

    // ════════════════════════════════════════════════════════════════════
    //  Self-managed boundary-order sizing (body of Vogue._sizeOutOfRange):
    //  deposit the position's backing (ETH at the chosen venue, or a stable via
    //  AUX) and size the single-sided liquidity. pledge==0 -> no wall attribution.
    //  Ticks bundled to keep the Vogue forwarder off the legacy stack.
    // ════════════════════════════════════════════════════════════════════
    // §A.54: `OorTicks` was byte-identical to `SwapLib.Oor` — same four fields, same order, same
    // types — i.e. one concept under two names. Collapsed onto `SwapLib.Oor`, which is the better home:
    // it already owns the `SwapLib.oorTicks(...)` factory that CONSTRUCTS the value, and this library
    // already imports SwapLib.

    function sizeOutOfRange(
        address weth, address aux, address ev,
        mapping(address => uint) storage ethfiBacked,
        uint amount, address token, bool token1isETH, uint8 venue, SwapLib.Oor memory t
    ) public returns (uint128 liquidity) {
        // §A.56: both branches were an INLINE COPY of `SwapLib.sizeOorUsd` — the same helper the BTC
        // path (`BtcVaultLib.outOfRangeBtc`) already calls. Verified byte-identical: the USD side maps
        // to `sizeOorUsd(.., token1isETH)` and the ETH side is its MIRROR (`!token1isETH`), because
        // depositing the ASSET places the order on the opposite side of spot from depositing USD.
        // One definition now sizes every out-of-range order, ETH and BTC alike. The bare `require`s
        // became `TickOutOfRange()` (the helper's named error) — same guard, better diagnostics.
        if (token == address(0)) {
            amount = depositETH(weth, aux, ev, ethfiBacked, msg.sender, address(0), amount, venue);
            liquidity = SwapLib.sizeOorUsd(amount, t, !token1isETH);
        } else {
            amount = SwapLib.scaleTo6(IAux(aux).deposit(msg.sender, token, amount), token);
            liquidity = SwapLib.sizeOorUsd(amount, t, token1isETH);
        }
    }

    /// @dev DEPLOY-TIME ONLY — the body of `Vogue.setup`, moved here for the same
    ///      reason `Core.setup`'s body moved to OracleLib (E32): one-shot wiring was
    ///      billing Vogue's RUNTIME bytes against a hard EIP-170 deficit. Vogue keeps
    ///      what cannot leave: the `onlyOwner` gate, the AlreadyInitialized guard,
    ///      `renounceOwnership()` (Ownable's slot is Vogue's), the QUID back-pin check,
    ///      and the assignments of the value-type state this returns.
    function setupBody(address _aux, address _core)
        external returns (address weth, bool token1isETH, int24 lower, int24 upper) {
        weth = IAux(_aux).WETH();
        IWETH9(weth).approve(_aux, type(uint).max);
        (uint160 sqrtPriceX96,,) = ICore(_core).poolStats(0, 0, false);
        token1isETH = ICore(_core).token1isETH();
        (lower,, upper,) = SwapLib.updateTicks(sqrtPriceX96, SwapLib.BAND_DELTA);
    }

    /// @dev Vogue's ETH delivery ladder, moved here for EIP-170 (E32). Native balance
    ///      first, then this contract's WETH, then a venue pull, then — only if the
    ///      venue base is exhausted while POOLED_ETH priced the swap against the
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
                inWETH += IEthVenue(ev).vogueOp(false, needed - inWETH, 1, bytes32(0));
                if (inWETH < needed) {
                    address mgr = ILevHost(ev).LEV_MANAGER();
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
}
