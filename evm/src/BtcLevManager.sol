// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultExposeB, IVBtcToken} from "./imports/Interfaces.sol";
import {LevBase} from "./imports/LevBase.sol";
import {Types} from "./imports/Types.sol";
import {LevMath} from "./imports/LevMath.sol";
import {ILevVenue, IERC20Min} from "./imports/ILevVenue.sol";
import {IMorphoFlash} from "./imports/Interfaces.sol";
import {V3_SWAP_ROUTER} from "./imports/Interfaces.sol";
import {ILevSyncHook} from "./imports/Interfaces.sol";
// §A.52: use the SHARED `IAux` rather than a file-local `IAuxTWAP_BView` that restated the
// same signature — one declaration, so a change to it cannot silently miss this consumer.
import {IAux} from "./imports/Interfaces.sol";
import {ILevVenueColl} from "./imports/Interfaces.sol";

   // branch open on the venue's collateral token
 // zero-fee flash (WBTC flash-repay-first de-lever)
/// SAME-BTC leverage: the vBTC token IS the Vault, which exposes/un-exposes the LP's own channel band
/// BTC as levered collateral (no separate mint/transferFrom roundtrip). See Vault.exposeBtcToLev.
/// §J.2: the vBTC TOKEN's back-pointer to the Vault that owns its supply. `VBtc.VAULT` is immutable and
/// set to its deployer (the Vault), so reading it once at construction gives a binding that CANNOT be
/// misconfigured — no extra constructor arg, no deploy-site change, no runtime cost after the ctor.
/// @title  BtcLevManager — the BTC IL-protect: per-LP isolated vBTC-collateral leverage overlay
/// @notice The BTC analogue of `LevManager`, sharing its economics via `LevMath` but with the acquisition
///         model corrected for BTC: the collateral is **vBTC** (an
///         8-dec token, 1e8 = 1 BTC = 1 sat-unit — matching the internal 8-dec BTC pool token — minted 1:1 by
///         the bridge/enclave against attested channel state, NOT a public deposit). Because acquiring BTC crosses Bitcoin
///         confirmation, there is **no synchronous swap loop** like `openLev`'s — the fleet keeper drives the
///         fill/unwind over async steps (borrow → source BTC externally → mint vBTC → supply), so this manager
///         only exposes the **venue legs** (`leverBorrow`/`leverSupply`/`deleverWithdraw`/`repay`) that the
///         keeper sequences, plus the read side (`netEquityBtc`, paired into `POOLED_BTC` by `syncLevBTC` —
///         that is the solvency count; `vogueBTC` is WBTC-only and is never credited the net-equity).
///
///         Reuses verbatim: `LevMath` (target `1−√(entry/now)`, net-equity, debt-delta), `ILevVenue` (the
///         renamed collateral-agnostic `Euler/MorphoEscrowVenue`, deployed against a vBTC market). Acquisition
///         is EXTERNAL (never the swap-out rail → the band is never traded → no encroachment on other LPs).
contract BtcLevManager is LevBase {
    IERC20Min public immutable VBTC;   // collateral (8-dec, 1e8 = 1 BTC = 1 sat-unit)
    address public immutable WBTC;   // oracle key
    address public immutable GOV;
    address public immutable QUID;
    /// The Vault behind `VBTC` — band authority for expose/unexpose. Distinct from `VBTC` since §J.2
    /// split the token face out of the Vault; before that split one address served as both.
    address public immutable VAULT;   // basket stablecoin — redeemed via AUX to repay a levered LP's OWN debt
    // QU!D policy ceiling on the LP's CHOSEN target LTV. 50%=2× is IL-neutral (delta-1); above = opt-in
    // DIRECTIONAL (LP's own risk, isolated). 7500=75%≈4×, headroom below the 86% venue LLTV. Tunable. (ETH parity.)
    uint256 public constant BAND_BPS           = 300;       // ±3% LTV before a rebalance is worth doing
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;       // 1% anti-MEV floor on the leg's SOR swaps
    uint256 public constant MIN_OPEN_VBTC      = 50_000;   // anti-Sybil: 0.0005 BTC in 8-dec sats (real confirmed collateral to join)
    uint256 internal constant WAD = 1e18;


    /// @notice (B) Sold-fraction target activation. Default OFF ⇒ the PROVEN 1−√(entry/now) target stays active.
    ///         GOV flips it ON only AFTER the band-driven fork proof lands — parity with `LevManager`.

    // Enumerable open-LP set so `vogueBTC` can sum live net-equity on-chain (bounded via MIN_OPEN_VBTC).
    function openLevCount() external view returns (uint) { return _openLps.length; }
    function openLpAt(uint i) external view returns (address) { return _openLps[i]; }

    /// @notice PIN-ONCE venue ALLOWLIST (not a rotatable governance setter — a rotatable one is the same
    ///         phantom-backing surface). Set ONCE by GOV then frozen (handles the manager↔venue circular
    ///         deploy dependency); mirrors LevManager so a WBTC venue can sit beside the vBTC one. New venue ⇒ new manager.
    mapping(address => bool) public allowedVenue;
    bool    public venuesFrozen;
    address public flashProvider;   // Morpho zero-fee flash (set in init) — powers the WBTC flash-repay-first de-lever
    event VenueAllowed(address venue);
    address public vogueSyncHook;                          // Vault.syncLevBTC — GOV pin-ONCE then frozen
    /// @notice ONE-SHOT GOV config — pin-once, then FROZEN, atomic. Wires the audited venue ALLOWLIST
    ///         (`venues`, then frozen) and the band sync-hook (`hook` = Vault.syncLevBTC, poked by
    ///         closeBtcLev) together. NOT rotatable (a new venue/hook ⇒ deploy a new BtcLevManager). No flash
    ///         provider on the native vBTC path — BTC de-lever is keeper-sequenced (async external BTC
    ///         sourcing). Matches LevManager.init (allowlist so a WBTC venue can sit beside the vBTC one).
    function init(address hook, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert BadAuth();
        venuesFrozen = true; vogueSyncHook = hook; flashProvider = flash;
        for (uint i; i < venues.length; i++) {
            address v = venues[i];
            if (v == address(0)) revert BadAuth();
            // each LONG venue's collateral is custodied + valued as 8-dec BTC (vBTC sats OR WBTC — SAME oracle
            // price, so valuation is identical); any OTHER collateral silently misvalues into phantom BTC backing
            // (the rug the frozen allowlist guards). LevMath.vetVenue reverts an unvaluable one even for GOV, and
            // rejects a SHORT ({stable,WBTC}) mis-pinned as a long (returns true). c1=WBTC ⇒ WBTC venue allowed.
            if (LevMath.vetVenue(v, WBTC, address(VBTC), WBTC)) revert BadAuth();
            allowedVenue[v] = true; emit VenueAllowed(v);
        }
    }

    event Opened(address indexed lp, uint targetLtvCapBps);
    event Borrowed(address indexed lp, uint stableOut);
    event Supplied(address indexed lp, uint vbtcIn);
    event Withdrawn(address indexed lp, uint vbtcOut);
    event Repaid(address indexed lp, uint stableIn);
    event Closed(address indexed lp, uint vbtcReturned);
    /// @dev RENAMED from `Reanchored` 2026-08-09 — see the note on `LevManager.ReanchoredToBand`. A stale
    ///      decoder reading the old 4-field shape MISPARSES a 3-field payload rather than reverting.
    event ReanchoredToBand(address indexed lp, uint160 entrySqrtP, uint e0);
    event ProtectedFromQuid(address indexed lp, uint quidRedeemed, uint debtRepaid);
    event DeleverFailed(address indexed lp, uint ltvBps);   // #10: a batch member skipped (couldn't source / native-only)

    error AlreadyOpen();
    error BadAuth();
    error NotFlash();
    error Reentrancy();

    uint private _lock = 1;
    modifier nonReentrant() { if (_lock != 1) revert Reentrancy(); _lock = 2; _; _lock = 1; }

    constructor(address vbtc, address aux, address wbtc, address gov, address quid) LevBase(aux, wbtc) {
        VBTC = IERC20Min(vbtc); VAULT = IVBtcToken(vbtc).VAULT(); WBTC = wbtc; GOV = gov; QUID = quid;
    }

    // ═══════════════════════════ VALUATION (8-dec vBTC / sats basis) ═══════════════════════════
    // SCALE (authoritative — reference-gettwapforasset-scale + SwapLib.sizeBySurplus/twapResolve, and the
    // tested BTC-LP pairing path Alles.t.sol:1913): `getTWAPforAsset(WBTC)` returns USD18 per 1e18 RAW units,
    // with the WBTC anchor LIFTED ×1e10. So valuing 8-dec sats: `vbtc · px / 1e18` = USD18 (NOT /1e8 — that
    // over-values by 1e10). Inverting, USD→sats is `usd18 · 1e18 / px`, which lands back in 8-dec sats because
    // the ×1e10 lift cancels the 8↔18 dec gap. The ENTIRE rest of the codebase uses /1e18; this manager must
    // too (the former /1e8 & /1e10 were a 1e10 mis-scale masked by zero-debt-only tests).

    /// @notice USD (1e18) value of `vbtc` (8-dec) collateral: `vbtc · px / 1e18` (px is USD18/1e18-raw, WBTC-lifted).
    function vBtcValueUsd(uint vbtc) public view returns (uint) {
        if (vbtc == 0) return 0;
        return (vbtc * AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW)) / 1e18;
    }

    /// @notice `lp`'s debt in USD (1e18), normalizing the venue stable's decimals.
    function debtUsd(address lp) public view override returns (uint) {
        ILevVenue v = pos[lp].venue;
        return LevMath._toUsd18(address(AUX),v.stable(), v.debtOf(lp));          // canonical decimal-normalize (dedup)
    }

    /// @notice `lp`'s LIVE net-equity in BTC-units (1e18) = collateral(vBTC) − debt(USD→BTC), floored at 0.
    ///         The single SOLVENCY term `Vault.vogueBTC()` adds — never deliverable (cross-chain custody).
    ///         All-view (collateralOf/debtOf/getTWAPforAsset are views), safe from `vogueBTC()`.
    function netEquityBtc(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _netEquityAt(lp, px);
    }
    /// @notice LIVE sum of every open position's net-equity (BTC-units, 1e18); reads the oracle ONCE.
    function totalNetEquityBtc() external view returns (uint total) {
        uint n = _openLps.length;
        if (n == 0) return 0;
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        for (uint i; i < n; i++) total += _netEquityAt(_openLps[i], px);
    }

    /// @notice `lp`'s GROSS collateral in sats (8-dec, price-independent) — the full-2× band CAPACITY (net-equity
    ///         + the debt-funded buffer). vBTC IS sats, so no conversion. Buffer USD folds into POOLED_USD_BTC
    ///         (excluded from committed via committedUsd18's live-debt subtraction).
    function grossCollateralBtc(address lp) public view returns (uint) {
        Types.Pos memory p = pos[lp];
        return p.open ? p.venue.collateralOf(lp) : 0;
    }
    /// @notice LIVE sum of every open position's GROSS collateral (sats) — the single term the BTC band CAPACITY
    ///         (levPooledBTC) is synced to under the full-2× model (replaces the net-equity target).
    function totalGrossCollateralBtc() external view returns (uint total) {
        uint n = _openLps.length;
        for (uint i; i < n; i++) if (pos[_openLps[i]].open) total += pos[_openLps[i]].venue.collateralOf(_openLps[i]);
    }
    /// @notice LIVE sum of every open position's debt (USD 1e18) — the invariant ceiling for the in-pool BTC
    ///         buffer USD — each LP's `levBufferUsdBTC ≤ debtUsd` (the per-LP debt cap), the debt-backed analog
    ///         of `committedUsd ≤ TVL`.
    function totalDebtUsd() external view returns (uint total) {
        uint n = _openLps.length;
        for (uint i; i < n; i++) if (pos[_openLps[i]].open) total += debtUsd(_openLps[i]);
    }

    /// @notice #67 deliverability — USD this BTC-levered position can produce via a bounded, value-neutral
    ///         de-lever (LevMath.deliverableDollars). This is the REAL USD backing the band's pairing may count
    ///         (LEVERED-DELIVERABILITY-SPEC.md) so levered volatile pairs + earns fees even at basket surplus==0;
    ///         margin-bounded (never phantom). All-view.
    function deliverableDollars(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _deliverableDollarsAt(lp, px);
    }
    /// @notice LIVE sum of every open position's deliverableDollars — the aggregate #67 counts as available USD
    ///         backing in the band-pairing sizer (sizeBySurplus addend). Reads the oracle ONCE (price-consistent).

    /// @notice VENUE-SAFETY LTV (bps) = debt / ACTUAL collateral. The keeper uses THIS only for the
    ///         liquidation-avoidance track (it tracks the venue's health basis).
    function getCurrentLtvBps(address lp) public view returns (uint) {
        return LevMath.ltvBps(debtUsd(lp), vBtcValueUsd(pos[lp].venue.collateralOf(lp)));
    }

    /// @notice Delegated QU!D-protect for a BTC-levered LP — the BTC counterpart of `LevManager.protectFromQuid`
    ///         — the previously-stubbed keeper path. Redeems the LP's OWN opted-in QUID (`approve` = opt-in) to
    ///         repay the LP's OWN BTC-lev debt near liquidation; moves NO value to the caller (excess refunds to
    ///         `lp`). Asset-agnostic: the SAME `LevMath.protectExec` the ETH side uses — the venue abstracts
    ///         collateral/stable, so there is ZERO BTC-specific glue. Permissionless + near-liq-gated (anti-grief).
    function protectFromQuid(address lp, uint minStableOut) external nonReentrant returns (uint repaid) {
        if (!pos[lp].open) revert NotOpen();
        uint pull;
        (pull, repaid) = LevMath.protectExec(
            QUID, address(AUX), V3_SWAP_ROUTER, address(pos[lp].venue), lp, getCurrentLtvBps(lp), minStableOut);
        emit ProtectedFromQuid(lp, pull, repaid);
    }
    /// @notice IL-TARGET LTV (bps) = debt / E0 (the FIXED band-only base) — the keeper's IL-track basis,
    ///         consistent with the debt=E0·t sizing. Distinct from getCurrentLtvBps (venue safety).
    function ilLtvBps(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        uint e0Usd = LevMath.e0Usd(pos[lp].e0, px);   // shared scale layer (WBTC-lifted px ⇒ /1e18)
        return LevMath.ltvBps(debtUsd(lp), e0Usd);
    }
    /// @notice IL-cancelling target LTV (bps) = `1 − √(entry/now)`, clamped to the LP's cap. 0 flat/down.
    function ilTargetLtvBps(address lp) public returns (uint) {
        Types.Pos memory p = pos[lp];
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _ilTargetLive(p, px);
    }

    /// @notice (B) LIVE IL target (bps): the BTC band's ACTUAL sold fraction (`Vault.soldFractionWad`), capped
    ///         at the LP's cap; falls back to the proven 1−√(entry/now) when the sold-fraction path is inactive
    ///         or unmeasurable. Mirror of `LevManager._ilTargetLive`.
    function _ilTargetLive(Types.Pos memory p, uint px) internal returns (uint) {
        return LevMath.ilTargetLive(vogueSyncHook, p.entrySqrtP, p.entryPriceWad, px, p.targetLtvCapBps);
    }

    /// @notice (B) Realize on a BTC band RESEAT — mirror of `LevManager._reanchorIfReseated`. E0 becomes the
    ///         LP's CURRENT band-BTC depth (BAND-ONLY, matching `openBtcLev`; the buffer is HODL-neutral BTC
    ///         equity, not IL); the sold-fraction reference resets to the recentered band spot. No-op unless the
    ///         sold-fraction target is active. Mutating ⇒ only reachable from the keeper legs.
    function _reanchorIfReseated(address lp) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) return;
        (bool go, uint160 s) = LevMath.reanchorCompute(vogueSyncHook, p.entrySqrtP);
        if (!go) return;
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // (A): a reseat realizes accrued IL ⇒ re-anchor E0 to the position's CURRENT net-equity (sats) — NOT
        // bandBtcOf (0 in the (A) model). The over-hedge fix holds: E0 tracks net-equity, not growing collateral.
        uint base = netEquityBtc(lp);
        p.entrySqrtP    = s;
        p.entryPriceWad = uint128(px);
        p.e0         = uint128(base);
        emit ReanchoredToBand(lp, s, base);
    }
    /// @notice Stable delta (USD 1e18) + direction to re-hit the IL target; oracle read ONCE.
    function debtDeltaToTarget(address lp) public returns (bool levUp, uint amountUsd) {
        Types.Pos memory p = pos[lp];
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // Size to the FIXED, BAND-ONLY E0 (band sats at entry) valued at px — NOT band+buffer (over-hedge) and
        // NOT the buffer's growing collateral (the 1/(1−t) over-hedge). e0Usd = e0·px/1e18 (18-dec, matching
        // debtUsd; px is WBTC-lifted ×1e10 — /1e8 inflated targetDebt 1e10 ⇒ over-hedge to the venue ceiling).
        uint e0Usd = LevMath.e0Usd(p.e0, px);
        uint t = _ilTargetLive(p, px);                    // (B) live sold fraction, capped; √p fallback
        return LevMath.debtDelta(e0Usd, debtUsd(lp), t, BAND_BPS);
    }

    // ═══════════════════════════ OPEN / CONFIG (LP) ═══════════════════════════

    /// @notice Open an isolated BTC-lev position at ZERO leverage. The LP supplies `initialVbtc` vBTC (already
    ///         minted against its dedicated UTXO, approved here) as equity; the keeper fills the IL target over
    ///         async steps as the band sells. `cap` is the LP's max-leverage LTV ceiling (≤ TARGET_LTV_CAP_BPS
    ///         = 7500 bps ≈ 4×; 2× is the IL-neutral value). Venue is the
    ///         pin-once venue (no caller-supplied venue ⇒ no phantom backing).
    function openBtcLev(uint64 cap, uint initialVbtc, ILevVenue venue) external nonReentrant {
        if (pos[msg.sender].open) revert AlreadyOpen();
        // caller picks from the frozen allowlist (no phantom backing). requireOpenable reverts a non-allowlisted
        // OR incident-flagged (GOV setVaultHealth) venue; close/rebalance stay open so the keeper can unwind.
        LevMath.requireOpenable(allowedVenue[address(venue)], address(AUX), address(venue));
        if (initialVbtc < MIN_OPEN_VBTC) revert BadTarget();           // anti-Sybil
        if (cap == 0 || cap > TARGET_LTV_CAP_BPS) revert BadTarget();
        uint entryPx = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // (A) INTRINSIC deposit model (2026-07-03, mirror of LevManager): the LP's ONE deposit (`initialVbtc`)
        // IS the levered position — its net-equity is synced into the BTC band (levPooledBTC) as delta-1 depth by
        // the 2× leverage, so E0 (the FIXED IL base) = the DEPOSIT ITSELF (in sats — vBTC IS sats, no conversion),
        // NOT a separate unlevered band-BTC position. FIXED at open (over-hedge fix): collateral grows as the
        // keeper levers, but E0 stays = the deposit. SAFETY: the up-side clamp de-levers toward 0 debt below entry.
        uint e0 = initialVbtc;                                         // (A): the deposit (vBTC sats) is the IL base
        uint160 entrySqrtP;
        if (vogueSyncHook != address(0)) {
            try ILevSyncHook(vogueSyncHook).bandSqrtP() returns (uint160 s) { entrySqrtP = s; } catch {}
        }
        pos[msg.sender] = Types.Pos({venue: venue, targetLtvCapBps: cap, entryPriceWad: uint128(entryPx),
                               e0: uint128(e0), entrySqrtP: entrySqrtP, open: true});
        _trackOpen(msg.sender);
        // SAME-BTC: expose `initialVbtc` of the LP's OWN free channel band BTC as the levered slice — the Vault
        // mints the vBTC face straight to this manager (no LP pre-mint / transferFrom roundtrip). Opens at zero
        // debt; the band isn't re-paired here (levPooledBTC marks it withdrawal-excluded, LP.pooled unchanged),
        // matching the "open doesn't touch the band" invariant — the keeper's first syncLevBTC tracks net-equity.
        // COLLATERAL SOURCING — venue-agnostic, branched on the venue's collateral token (opens at ZERO debt either
        // way; the band isn't re-paired here so "open doesn't touch the band" holds; the keeper's first syncLevBTC
        // tracks net-equity). vBTC (native #74): expose the LP's OWN free channel BTC (Vault mints the vBTC face to
        // this manager — no pre-mint/transferFrom roundtrip). WBTC (fallback): the caller/SPA already SOR'd its USD
        // equity → WBTC; pull it in. `initialVbtc` is the collateral amount (8-dec) in either token.
        if (ILevVenueColl(address(venue)).COLLATERAL() == address(VBTC)) {
            IVaultExposeB(VAULT).exposeBtcToLev(msg.sender, initialVbtc);
            VBTC.transfer(address(venue), initialVbtc);
        } else {
            IERC20Min(WBTC).transferFrom(msg.sender, address(venue), initialVbtc);  // WBTC-mode: LP-brought equity
        }
        venue.supply(msg.sender, initialVbtc);
        emit Opened(msg.sender, cap);
    }

    /// @notice Adjust the caller's max-leverage cap (the IL target is auto-computed and never exceeds it).

    // ═══════════════════════════ KEEPER-DRIVEN ASYNC LEGS (LP-gated) ═══════════════════════════
    // Unlike ETH's atomic openLev/rebalance, BTC acquisition spans Bitcoin confirmation, so the legs are
    // SPLIT and the fleet keeper (holding the LP key) sequences them. LP-gated (msg.sender == lp) — never
    // permissionless: `leverBorrow` sends stable OUT (to fund external BTC sourcing), so an open permissionless
    // borrow would be a drain. The keeper never over-borrows ahead of not-yet-confirmed BTC.

    /// @notice Borrow `stableUsd`-worth of the venue stable against the position; sent to the LP/keeper to
    ///         source BTC externally. Clamped to the debt-delta-to-target so it can only move toward the IL
    ///         target (never past the LP's LTV cap, ≤ 7500 bps).
    function leverBorrow(uint stableUsd) external nonReentrant returns (uint got) {
        address lp = msg.sender;
        _reanchorIfReseated(lp);                 // (B) realize + re-anchor if the BTC band recentered
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        (bool levUp, uint room) = debtDeltaToTarget(lp);
        if (!levUp || room == 0) revert BadTarget();                   // only toward target
        uint want = stableUsd > room ? room : stableUsd;
        got = p.venue.borrow(lp, LevMath._fromUsd(address(AUX),p.venue.stable(), want));    // stable → this
        if (got > 0) IERC20Min(p.venue.stable()).transfer(lp, got);      // → LP/keeper for external BTC sourcing
        emit Borrowed(lp, got);
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} } // full-2× reconcile
    }

    /// @notice Supply `vbtc` (minted against the LP's dedicated UTXO, approved here) as additional collateral —
    ///         the second half of a lever-up step, after the keeper has sourced+minted the BTC.
    function leverSupply(uint vbtc) external nonReentrant {
        address lp = msg.sender;
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        VBTC.transferFrom(lp, address(this), vbtc);
        VBTC.transfer(address(p.venue), vbtc);
        p.venue.supply(lp, vbtc);
        emit Supplied(lp, vbtc);
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} } // full-2× reconcile
    }

    /// @notice Withdraw `vbtc` collateral to the LP/keeper (for delever/close: burn + enclave-spend the UTXO →
    ///         sell BTC → repay). Capped at the position by the venue.
    function deleverWithdraw(uint vbtc) external nonReentrant returns (uint out) {
        address lp = msg.sender;
        _reanchorIfReseated(lp);                 // (B) realize + re-anchor if the BTC band recentered (down-leg start)
        if (!pos[lp].open) revert NotOpen();
        out = pos[lp].venue.withdraw(lp, vbtc);                        // vBTC → this
        if (out > 0) VBTC.transfer(lp, out);                           // → LP/keeper
        emit Withdrawn(lp, out);
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} } // full-2× reconcile
    }

    /// @notice Repay `stableUsd`-worth of the position's debt (stable already transferred in / approved).
    function repay(uint stableUsd) external nonReentrant returns (uint repaid) {
        address lp = msg.sender;
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        uint amt = LevMath._fromUsd(address(AUX),p.venue.stable(), stableUsd);
        // Clamp to the current debt BEFORE the transfer. `venue.repay` already caps the repaid amount at
        // the position's debt, but the transfer above moves the full `amt` in — so an over-repay
        // (`amt > debt`) would leave `amt − debt` stranded on the venue adapter permanently (subsequent
        // borrow forwards only the balance delta, so the excess is never swept and is unrecoverable).
        // Mirror LevManager: clamp-before-transfer so exactly the repaid amount is ever moved.
        uint debt = p.venue.debtOf(lp);                 // stable native units (== LevMath._fromUsd output units)
        if (amt > debt) amt = debt;
        if (amt == 0) { emit Repaid(lp, 0); return 0; } // nothing owed — skip the transfer + sync entirely
        IERC20Min(p.venue.stable()).transferFrom(lp, address(p.venue), amt);
        repaid = p.venue.repay(lp, amt);
        emit Repaid(lp, repaid);
        // full-2×: repay REDUCES debt → levBufferUsd must be re-capped at the smaller debt (else the ≤Σdebt
        // invariant transiently breaks). Reconcile atomically. try/catch: never block a repay.
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} }
    }

    // ═══════════════════════ ATOMIC WBTC-MODE (on-chain SOR, no external BTC sourcing) ═══════════════════════
    // WBTC-collateral positions (the #74 fallback) lever/de-lever ATOMICALLY on-chain — no Bitcoin-confirmation
    // async legs. PERMISSIONLESS like the ETH LevManager: the borrow is SOR'd stable→WBTC IN-TX and nothing leaves
    // to an external party, so there is no drain vector. Reuses `Aux.sorSelfFunded`(fwd) / `sorSelfFundedReverse`
    // (rev) — the SAME caller-funded SOR the ETH weETH lever uses, output=WBTC — through the V4 USDC/WBTC pool.
    // Venue-agnostic: every leg is an `ILevVenue` call, so it runs identically on Morpho/Euler/Aave-v4/Aave-v3.

    /// @notice Atomic rebalance toward the IL target for a WBTC-collateral position (native vBTC uses the async legs).
    function rebalanceWbtc(address lp, uint minOut) external nonReentrant {
        _reanchorIfReseated(lp);                                          // (B) realize + re-anchor on a band reseat
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        if (ILevVenueColl(address(p.venue)).COLLATERAL() != WBTC) revert BadTarget(); // WBTC-mode ONLY — a native vBTC
        //   venue would get WBTC supplied into it (collateral mismatch). Native positions use the async legs above.
        address stable = p.venue.stable();
        (bool levUp, uint deltaUsd) = debtDeltaToTarget(lp);             // deltaUsd = curDebt−targetDebt on the FIXED E0
        if (deltaUsd != 0) {
            if (levUp) _leverUpBuyWbtc(p.venue, lp, stable, deltaUsd, minOut);
            else if (flashProvider != address(0)) _flashDeleverWbtc(p.venue, lp, stable, deltaUsd, minOut); // repay-FIRST: always health-safe
            else       _deleverWbtc(p.venue, lp, stable, deltaUsd, minOut);                                 // graceful fallback (no flash provider)
        }
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} }
    }

    /// @notice #10 SYSTEMIC batch de-lever for WBTC-mode positions — the BTC analog of ETH `LevManager.cascadeDelever`.
    ///         De-levers a keeper-supplied (LTV-ranked) batch in ONE tx via the atomic `rebalanceWbtc` (flash-repay-
    ///         first, health-safe, direction decided on-chain). PERMISSIONLESS + only-toward-target. FAULT-TOLERANT:
    ///         a member whose `rebalanceWbtc` can't source liquidity — OR a NATIVE vBTC position (those use the async
    ///         keeper legs, not this atomic path, so `rebalanceWbtc` reverts `BadTarget`) — is SKIPPED (`DeleverFailed`)
    ///         and the loop continues; one stuck LP can NEVER block the rest (it falls to its venue's own isolated
    ///         liquidation). NOT `nonReentrant`: each `this.rebalanceWbtc` self-locks (mirrors ETH's cascade calling
    ///         the per-LP entry). Keeper ranks by LTV off-chain and supplies the descending list + per-position minOut.
    function cascadeDeleverMany(address[] calldata lps, uint[] calldata minOuts) external {
        require(lps.length == minOuts.length, "len");
        for (uint i; i < lps.length; i++) {
            address lp = lps[i];
            if (!pos[lp].open) continue;
            try this.rebalanceWbtc(lp, minOuts[i]) {}
            catch { emit DeleverFailed(lp, getCurrentLtvBps(lp)); }
        }
    }

    /// @dev Lever-UP: borrow stable → SOR to WBTC → supply. EXACT 4-step custody of `LevManager._leverUpBuy`
    ///      (borrow→manager, SOR→manager, manager→venue transfer, venue.supply→escrow), collateral = WBTC.
    function _leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint usd, uint minOut) internal {
        (uint borrowed, uint wbtc) = LevMath.leverUpBuyWbtc(venue, lp, stable, usd, minOut, LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS)));
        if (borrowed > 0) { emit Borrowed(lp, borrowed); emit Supplied(lp, wbtc); }   // body + oracle floor in LevMath (EIP-170)
    }

    /// @dev De-lever: withdraw `repayUsd`-worth of WBTC → SOR to stable → repay (clamp-before-transfer like `repay`).
    ///      DIRECT — health-safe at the low LTV the IL target holds (opens at 0, levers as IL accrues). A near-liq
    ///      flash-repay-first hardening (mirror `LevManager._deleverFlash`) is the follow-on if the venue's withdraw
    ///      LTV-gate ever blocks the pre-repay withdraw. SOR slippage ⇒ slightly under-target; next tick finishes.
    function _deleverWbtc(ILevVenue venue, address lp, address stable, uint repayUsd, uint minOut) internal {
        (uint pulled, uint repaid) = LevMath.deleverWbtc(venue, lp, stable, repayUsd, minOut, LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS)));
        if (pulled > 0) { emit Withdrawn(lp, pulled); emit Repaid(lp, repaid); }       // body + oracle floor in LevMath (EIP-170)
    }

    /// @dev FLASH-repay-first de-lever: flash `repayUsd`-worth stable from the provider; the callback repays FIRST
    ///      (LTV drops ⇒ withdraw always health-safe — kills the direct path's near-liq wall), then withdraws freed
    ///      WBTC → SOR→stable → returns the flash + surplus. `repayUsd` (= deltaUsd) is already ≤ debt.
    function _flashDeleverWbtc(ILevVenue venue, address lp, address stable, uint repayUsd, uint minOut) internal {
        if (repayUsd == 0) return;
        IMorphoFlash(flashProvider).flashLoan(stable, LevMath._fromUsd(address(AUX),stable, repayUsd),
            abi.encode(lp, address(venue), stable, minOut));
    }

    /// @notice Flash-loan callback — ONLY the pinned provider, and the provider invokes it solely on the flashLoan
    ///         INITIATOR (us), so it fires only from `_flashDeleverWbtc` (an attacker's own flashLoan calls back the
    ///         attacker, not us). NOT `nonReentrant`: it runs INSIDE `rebalanceWbtc`'s lock. Body in LevMath (EIP-170).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != flashProvider) revert NotFlash();
        (address lp, address venueAddr, address stable, uint minOut) = abi.decode(data, (address, address, address, uint256));
        LevMath.flashDeleverWbtcSettle(assets, lp, venueAddr, stable, minOut, flashProvider,
            LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS)));
        emit Repaid(lp, assets);
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} }
    }

    /// @notice #54 DELIVERY-SIDE de-lever (partial-burn vBTC deliverability). When a native-BTC swap-out is
    ///         delivered from `lp`'s channel but draws on its LEVERED slice (free band exhausted — the stranded
    ///         state), the swap-out PROCEEDS (`stableUsd`-worth, pre-transferred to the venue by the Vault settle
    ///         path from POOLED_USD_BTC) repay `lp`'s debt, freeing the matching vBTC collateral — the Vault then
    ///         un-encumbers it (funded rises) so the settled shrink can deliver it. VALUE-NEUTRAL: −BTC −debt of
    ///         equal oracle value ⇒ net-equity preserved, LTV IMPROVES. The LP is paid ONCE — its proceeds became
    ///         debt-reduction instead of the QUI mint (single-pay). Mechanics here mirror closeBtcLev: repay →
    ///         withdraw the freed vBTC to this manager → burn it + un-encumber the LP's channel BTC via
    ///         `unexposeBtcFromLev` (lev→funded), so the Vault's funded/lev clamp no longer bites the settled
    ///         shrink. Gated to the Vault settle path (`vogueSyncHook`). `freeSats` = the delivered levered slice
    ///         to un-encumber (decoupled from the debt repaid: the levered net slice can exceed its debt backing,
    ///         so we free the sats the channel actually delivered and repay only what debt there is — the pure-
    ///         equity remainder is compensated by the caller minting QUI for it). Equal-value removal (repaid debt
    ///         ⇔ equal-value collateral) keeps LTV IMPROVING; any collateral freed beyond the repaid value is
    ///         zero-debt (LTV already 0 or falling) so the venue withdraw stays healthy. Returns (usedUsd 1e18,
    ///         freedSats) — usedUsd is the debt actually retired (the caller withholds only THIS from the QUI mint).
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external nonReentrant returns (uint usedUsd, uint freedSats) {
        if (msg.sender != vogueSyncHook) revert BadAuth();          // Vault settle path only
        Types.Pos memory p = pos[lp];
        if (!p.open) return (0, 0);
        uint amt = LevMath._fromUsd(address(AUX),p.venue.stable(), stableUsd);   // usd → native stable units
        uint debt = p.venue.debtOf(lp);
        if (amt > debt) amt = debt;                                 // clamp to debt (never over-repay / strand)
        if (amt > 0) {
            uint repaid = p.venue.repay(lp, amt);                   // stable pre-transferred to venue by the Vault
            usedUsd = LevMath._toUsd18(address(AUX),p.venue.stable(), repaid);   // USD 1e18 actually applied to the debt
        }
        freedSats = freeSats;                                       // the delivered levered slice (channel-proven)
        uint coll = p.venue.collateralOf(lp);
        if (freedSats > coll) freedSats = coll;                     // cap at the position (venue also caps)
        if (freedSats > 0) {
            uint got = p.venue.withdraw(lp, freedSats);             // vBTC → this manager
            if (got != freedSats) freedSats = got;
            // Burn the withdrawn vBTC + convert the LP's levered slice back to FREE channel band depth
            // (lev→funded), so the Vault settle path's funded/lev clamp delivers the settled shrink. Same
            // primitive closeBtcLev uses; msg.sender==this==LEV_MANAGER_BTC satisfies the Vault gate.
            if (freedSats > 0) IVaultExposeB(VAULT).unexposeBtcFromLev(lp, freedSats);
        }
    }

    /// @notice #54 funding quote: for `lp`, the venue stable + the EXACT native amount the Vault must fund to the
    ///         venue to de-lever up to `maxUsd18` of debt — clamped to live debt so no stray stable is stranded on
    ///         the venue adapter (swapOutDelever repays exactly this, recomputing the same clamp). View.

    /// @notice Fully retire the caller's position once debt is repaid: withdraw all remaining vBTC to the LP,
    ///         delete the position, and re-sync the levered band slice so it stops earning on vanished backing.
    function closeBtcLev() external nonReentrant {
        address lp = msg.sender;
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        if (p.venue.debtOf(lp) != 0) revert BadTarget();               // repay first (keeper unwinds async)
        // Mark the levered slice to the live (now zero-debt) net-equity BEFORE unwinding, so it == `back`.
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLevBTC(lp) {} catch {} }
        uint rem = p.venue.collateralOf(lp);
        uint back = rem > 0 ? p.venue.withdraw(lp, rem) : 0;           // vBTC → this manager
        delete pos[lp];
        _untrackOpen(lp);
        // SAME-BTC: burn the withdrawn vBTC and un-freeze the levered slice back to FREE channel band depth
        // (lev→funded) — grown/shrunk by the realized leverage P&L. The LP keeps its channel band position; it
        // never receives loose vBTC (that would double-claim the same channel BTC). No post-sync needed: the
        // slice is zeroed here, and the position is gone.
        if (back > 0) IVaultExposeB(VAULT).unexposeBtcFromLev(lp, back);
        emit Closed(lp, back);
    }

    /// @dev BTC: vBTC is sats already; there is no rate to apply and _collToEth would MIS-CONVERT (it tests
    ///      COLLATERAL() == WETH, false here, and would route sats through getEETHByWeETH).
    function _collNative(ILevVenue v, address lp) internal view override returns (uint) {
        return v.collateralOf(lp);                  // vBTC IS sats — no conversion exists to apply
    }
}
