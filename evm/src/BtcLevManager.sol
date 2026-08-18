// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultExposeB, IVBtcToken} from "./imports/Interfaces.sol";
import {LevBase} from "./imports/LevBase.sol";
import {Types} from "./imports/Types.sol";
import {LevMath} from "./imports/LevMath.sol";
import {LevBookLib} from "./imports/LevBookLib.sol";
import {ILevVenue, IERC20Min} from "./imports/ILevVenue.sol";
import {IMorphoFlash} from "./imports/Interfaces.sol";
import {ILevSyncHook} from "./imports/Interfaces.sol";
// §A.52: use the SHARED `IAux` rather than a file-local `IAuxTWAP_BView` that restated the
// same signature — one declaration, so a change to it cannot silently miss this consumer.
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
///         keeper sequences, plus the read side (`netEquityBtc`, paired into `POOLED` by `syncLev` —
///         that is the solvency count; `bandBTC` is WBTC-only and is never credited the net-equity).
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
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;       // 1% anti-MEV floor on the leg's Curve swaps
    uint256 public constant MIN_OPEN_VBTC      = 50_000;   // anti-Sybil: 0.0005 BTC in 8-dec sats (real confirmed collateral to join)
    uint256 internal constant WAD = 1e18;


    /// @notice (B) Sold-fraction target activation. Default OFF ⇒ the PROVEN 1−√(entry/now) target stays active.
    ///         GOV flips it ON only AFTER the band-driven fork proof lands — parity with `LevManager`.


    /// @notice PIN-ONCE venue ALLOWLIST (not a rotatable governance setter — a rotatable one is the same
    ///         phantom-backing surface). Set ONCE by GOV then frozen (handles the manager↔venue circular
    ///         deploy dependency); mirrors LevManager so a WBTC venue can sit beside the vBTC one. New venue ⇒ new manager.
    mapping(address => bool) public allowedVenue;
    bool    public venuesFrozen;
    address public flashProvider;   // Morpho zero-fee flash (set in init) — powers the WBTC flash-repay-first de-lever
    event VenueAllowed(address venue);
    /// @notice ONE-SHOT GOV config — pin-once, then FROZEN, atomic. Wires the audited venue ALLOWLIST
    ///         (`venues`, then frozen) and the band sync-hook (`hook` = Vault.syncLev, poked by
    ///         closeBtcLev) together. NOT rotatable (a new venue/hook ⇒ deploy a new BtcLevManager). No flash
    ///         provider on the native vBTC path — BTC de-lever is keeper-sequenced (async external BTC
    ///         sourcing). Matches LevManager.init (allowlist so a WBTC venue can sit beside the vBTC one).
    function init(address hook, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert BadAuth();
        venuesFrozen = true; BAND = hook; flashProvider = flash;
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
    event DeleverFailed(address indexed lp, uint ltvBps);   // #10: a batch member skipped (couldn't source / native-only)

    error AlreadyOpen();
    error BadAuth();
    error NotFlash();


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

    /// @notice §FOLD-COLL — THE BTC SIDE'S ENTIRE PER-ASSET CONTRIBUTION: **nothing to convert.**
    ///         vBTC IS sats, and per the scale note directly above, the WBTC TWAP already carries the
    ///         ×1e10 lift that closes the 8↔18 gap — so the identity here is not a stub, it is the
    ///         statement that a second conversion would double-count (the exact 1e10 mis-scale that
    ///         note records as having shipped once already).
    ///         `collValueUsd`, `_collNative`, `debtUsd`, `getCurrentLtvBps`, `ilLtvBps` and
    ///         `ilTargetLtvBps` are all shared in `LevBase` on top of this.
    /// §MUTABILITY 2026-08-18 — `pure`, not `view`: vBTC IS sats, so this is the identity and reads
    /// nothing. Narrowing an override below its `view` virtual is legal and is what solc asked for.
    function _collToBase(uint units) internal pure override returns (uint) { return units; }





    /// @notice LIVE sum of every open position's deliverableDollars — the aggregate #67 counts as available USD
    ///         backing in the band-pairing sizer (sizeBySurplus addend). Reads the oracle ONCE (price-consistent).


    /// §ONE-PROTECT — body is now `LevBase.protectFromQuid`; only these hooks differ.
    function _quid() internal view override returns (address) { return QUID; }


    /// @notice Stable delta (USD 1e18) + direction to re-hit the IL target; oracle read ONCE.
    function debtDeltaToTarget(address lp) public view override returns (bool levUp, uint amountUsd) {
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
        // IS the levered position — its net-equity is synced into the BTC band (levPooled) as delta-1 depth by
        // the 2× leverage, so E0 (the FIXED IL base) = the DEPOSIT ITSELF (in sats — vBTC IS sats, no conversion),
        // NOT a separate unlevered band-BTC position. FIXED at open (over-hedge fix): collateral grows as the
        // keeper levers, but E0 stays = the deposit. SAFETY: the up-side clamp de-levers toward 0 debt below entry.
        uint e0 = initialVbtc;                                         // (A): the deposit (vBTC sats) is the IL base
        // §FOLD-OPEN — shared tail in `LevBase._openPos`. Only `e0` above is per-asset (sats as-is,
        // because vBTC IS sats and needs no conversion).
        _openPos(venue, cap, entryPx, e0);
        // SAME-BTC: expose `initialVbtc` of the LP's OWN free channel band BTC as the levered slice — the Vault
        // mints the vBTC face straight to this manager (no LP pre-mint / transferFrom roundtrip). Opens at zero
        // debt; the band isn't re-paired here (levPooled marks it withdrawal-excluded, LP.pooled unchanged),
        // matching the "open doesn't touch the band" invariant — the keeper's first syncLev tracks net-equity.
        // COLLATERAL SOURCING — venue-agnostic, branched on the venue's collateral token (opens at ZERO debt either
        // way; the band isn't re-paired here so "open doesn't touch the band" holds; the keeper's first syncLev
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
    /// @notice §FOLD-LEGS — body in `LevBookLib`. `debtDeltaToTarget` is resolved HERE because it
    ///         routes through the `_collToBase` virtual, which a library cannot call on its caller.
    function leverBorrow(uint stableUsd) external nonReentrant returns (uint got) {
        _reanchorIfReseated(msg.sender);
        (bool levUp, uint room) = debtDeltaToTarget(msg.sender);
        got = LevBookLib.leverBorrow(pos, address(AUX), msg.sender, stableUsd, levUp, room);
        _syncBand(msg.sender);
    }

    /// @notice Supply `vbtc` (minted against the LP's dedicated UTXO, approved here) as additional collateral —
    ///         the second half of a lever-up step, after the keeper has sourced+minted the BTC.
    /// @notice §FOLD-LEGS — body in `LevBookLib`. `VBTC` is passed as the collateral token; the same
    ///         library body serves weETH on the ETH side, which is why this was never BTC-specific.
    function leverSupply(uint vbtc) external nonReentrant {
        LevBookLib.leverSupply(pos, address(VBTC), msg.sender, vbtc);
        _syncBand(msg.sender);
    }

    /// @notice Withdraw `vbtc` collateral to the LP/keeper (for delever/close: burn + enclave-spend the UTXO →
    ///         sell BTC → repay). Capped at the position by the venue.
    /// @notice §FOLD-LEGS — body in `LevBookLib`, parameterised by the collateral token.
    function deleverWithdraw(uint vbtc) external nonReentrant returns (uint out) {
        _reanchorIfReseated(msg.sender);
        out = LevBookLib.deleverWithdraw(pos, address(VBTC), msg.sender, vbtc);
        _syncBand(msg.sender);
    }

    /// @notice Repay `stableUsd`-worth of the position's debt (stable already transferred in / approved).
    /// @notice §FOLD-LEGS — body in `LevBookLib`. A WRAPPER: reentrancy lock, then the shared leg,
    ///         then the band poke. The poke must follow the venue move, which is why it stays here.
    function repay(uint stableUsd) external nonReentrant returns (uint repaid) {
        repaid = LevBookLib.repay(pos, address(AUX), msg.sender, stableUsd);
        _syncBand(msg.sender);
    }

    // ═══════════════════════ ATOMIC WBTC-MODE (on-chain swap, no external BTC sourcing) ═══════════════════════
    // WBTC-collateral positions (the #74 fallback) lever/de-lever ATOMICALLY on-chain — no Bitcoin-confirmation
    // async legs. PERMISSIONLESS like the ETH LevManager: the borrow is swapped stable→WBTC IN-TX and nothing
    // leaves to an external party, so there is no drain vector. Routed through CURVE by
    // `LevMath._stableToWbtc` / `_wbtcToStable` (084bc5c) — the SAME Curve helpers the ETH lever uses.
    // ⚠️ This previously read "SOR'd … through the V4 USDC/WBTC pool", naming `Aux.sorSelfFunded` /
    //    `sorSelfFundedReverse`. Neither is on this path any more; the SOR is now the BAND's AMM only.
    // Venue-agnostic in shape (every leg is an `ILevVenue` call), but the BTC allowlist is exactly TWO
    // venues — Morpho vBTC and AaveV3 WBTC. Euler and Aave-v4 borrowing were REMOVED.

    /// @notice Atomic rebalance toward the IL target for a WBTC-collateral position (native vBTC uses the async legs).
    /// §ONE-REBALANCE (2026-08-18) — the body is now `LevBase._rebalance`, shared with the ETH
    /// band. Only the three per-band pieces stay here: the WBTC-mode gate and the two leaves.
    function rebalanceWbtc(address lp, uint minOut) external nonReentrant { _rebalance(lp, minOut); }

    /// @dev WBTC-mode ONLY. A native-vBTC position must not take this path — its collateral is
    ///      sats the contract cannot source on-chain. The ETH band has no such mode, so its
    ///      override is the empty default.
    function _requireRebalancable(Types.Pos memory p) internal view override {
        if (ILevVenueColl(address(p.venue)).COLLATERAL() != WBTC) revert BadTarget();
    }

    function _leverUp(ILevVenue venue, address lp, address stable, uint deltaUsd, uint minOut)
        internal override { _leverUpBuyWbtc(venue, lp, stable, deltaUsd, minOut); }

    /// @dev Repay-FIRST when a flash provider is pinned (always health-safe); otherwise the
    ///      graceful withdraw-then-repay fallback. The ETH band has no fallback because its
    ///      provider is not optional.
    function _delever(ILevVenue venue, address lp, address stable, uint deltaUsd, uint minOut)
        internal override {
        if (flashProvider != address(0)) _flashDeleverWbtc(venue, lp, stable, deltaUsd, minOut);
        else                             _deleverWbtc(venue, lp, stable, deltaUsd, minOut);
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

    /// @dev Lever-UP: borrow stable → Curve to WBTC → supply. EXACT 4-step custody of `LevManager._leverUpBuy`
    ///      (borrow→manager, swap→manager, manager→venue transfer, venue.supply→escrow), collateral = WBTC.
    function _leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint usd, uint minOut) internal {
        (uint borrowed, uint wbtc) = LevMath.leverUpBuyWbtc(venue, lp, stable, usd, minOut, LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS)));
        if (borrowed > 0) { emit Borrowed(lp, borrowed); emit Supplied(lp, wbtc); }   // body + oracle floor in LevMath (EIP-170)
    }

    /// @dev De-lever: withdraw `repayUsd`-worth of WBTC → Curve to stable → repay (clamp-before-transfer like `repay`).
    ///      DIRECT — health-safe at the low LTV the IL target holds (opens at 0, levers as IL accrues). A near-liq
    ///      flash-repay-first hardening (mirror `LevManager._deleverFlash`) is the follow-on if the venue's withdraw
    ///      LTV-gate ever blocks the pre-repay withdraw. Swap slippage ⇒ slightly under-target; next tick finishes.
    function _deleverWbtc(ILevVenue venue, address lp, address stable, uint repayUsd, uint minOut) internal {
        (uint pulled, uint repaid) = LevMath.deleverWbtc(venue, lp, stable, repayUsd, minOut, LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS)));
        if (pulled > 0) { emit Withdrawn(lp, pulled); emit Repaid(lp, repaid); }       // body + oracle floor in LevMath (EIP-170)
    }

    /// @dev FLASH-repay-first de-lever: flash `repayUsd`-worth stable from the provider; the callback repays FIRST
    ///      (LTV drops ⇒ withdraw always health-safe — kills the direct path's near-liq wall), then withdraws freed
    ///      WBTC → Curve→stable → returns the flash + surplus. `repayUsd` (= deltaUsd) is already ≤ debt.
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
        _syncBand(lp);
    }

    /// @notice #54 DELIVERY-SIDE de-lever (partial-burn vBTC deliverability). When a native-BTC swap-out is
    ///         delivered from `lp`'s channel but draws on its LEVERED slice (free band exhausted — the stranded
    ///         state), the swap-out PROCEEDS (`stableUsd`-worth, pre-transferred to the venue by the Vault settle
    ///         path from POOLED_USD) repay `lp`'s debt, freeing the matching vBTC collateral — the Vault then
    ///         un-encumbers it (funded rises) so the settled shrink can deliver it. VALUE-NEUTRAL: −BTC −debt of
    ///         equal oracle value ⇒ net-equity preserved, LTV IMPROVES. The LP is paid ONCE — its proceeds became
    ///         debt-reduction instead of the QUI mint (single-pay). Mechanics here mirror closeBtcLev: repay →
    ///         withdraw the freed vBTC to this manager → burn it + un-encumber the LP's channel BTC via
    ///         `unexposeBtcFromLev` (lev→funded), so the Vault's funded/lev clamp no longer bites the settled
    ///         shrink. Gated to the Vault settle path (`BAND`). `freeSats` = the delivered levered slice
    ///         to un-encumber (decoupled from the debt repaid: the levered net slice can exceed its debt backing,
    ///         so we free the sats the channel actually delivered and repay only what debt there is — the pure-
    ///         equity remainder is compensated by the caller minting QUI for it). Equal-value removal (repaid debt
    ///         ⇔ equal-value collateral) keeps LTV IMPROVING; any collateral freed beyond the repaid value is
    ///         zero-debt (LTV already 0 or falling) so the venue withdraw stays healthy. Returns (usedUsd 1e18,
    ///         freedSats) — usedUsd is the debt actually retired (the caller withholds only THIS from the QUI mint).
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external nonReentrant returns (uint usedUsd, uint freedSats) {
        if (msg.sender != BAND) revert BadAuth();          // Vault settle path only
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
            // primitive closeBtcLev uses; msg.sender==this==LEV_MANAGER satisfies the Vault gate.
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
        _syncBand(lp);
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

}
