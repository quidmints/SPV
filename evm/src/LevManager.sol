// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevMath} from "./imports/LevMath.sol";
import {LevBase} from "./imports/LevBase.sol";
import {Types} from "./imports/Types.sol";
import {ILevVenue, IERC20Min, IWETH9} from "./imports/ILevVenue.sol";
import {IWeETH} from "./imports/Interfaces.sol";
import {IAux} from "./imports/Interfaces.sol";
import {IMorphoFlash} from "./imports/Interfaces.sol";
import {ILevSyncHook} from "./imports/Interfaces.sol";
import {ILevVenueColl} from "./imports/Interfaces.sol";



/// @notice The venue's collateral ERC20 — BOTH escrow adapters (Morpho/Euler) expose this public immutable,
///         so the manager DERIVES the collateral type per position (weETH vs WETH) from the venue itself,
///         never storing it on `Pos` (the public struct ABI stays a stable 6-tuple).


/// @notice weETH↔WETH legs of the leverage swap (stable↔WETH is the basket SOR — `ISwapAux.sorSelfFunded`).
///         UP: MINT weETH via the ether.fi adapter at the fair rate (zero-slippage; never the thin pool).
///         DOWN: SELL weETH → WETH on the deep v3 pool (`LevMath._weethToWethDex`, two tiers cheapest-first,
///         floored at `getEETHByWeETH` − `SELL_SLIP_BPS`). ⚠️ THE LEGS ARE NOT SYMMETRIC: the up-leg mints at
///         the fair rate, the down-leg pays pool slippage. The ether.fi instant-redeem that once made them
///         symmetric was REMOVED 2026-08-06 — it was unguarded, its capacity measured ZERO at every sampled
///         block over 90 days, and reaching it REVERTED THE WHOLE CALL rather than degrading (see
///         `LevMath._weethToWeth`). Do not re-describe this leg as deterministic-cost.
// IERC20Min + IWETH9 (WETH deposit/withdraw) now come from ILevVenue.sol (shared across the lev cluster). The
// ether.fi adapter/redeemer surfaces moved to LevMath with the sell/buy machinery.

/// @notice Morpho Blue flash-loan surface — FREE (zero-fee), so the ONLY flash source we use. The de-lever
///         path (`_deleverFlash`) flashes the venue stable, REPAYS the LP's debt FIRST, then withdraws the
///         freed collateral to sell — so the position's LTV only ever DROPS mid-operation. This DISSOLVES the
///         withdraw-before-repay hazard by construction (there is no health breach to clamp against), instead
///         of the old "withdraw only the health-safe slice and iterate" band-aid. One Morpho flash covers
///         BOTH Euler and Morpho positions (Morpho lends from its global stable liquidity, independent of
///         where the position lives), so a single pinned provider serves every venue.

/// @title  LevManager — the IL-protect: a per-LP, isolated, weETH-collateral leverage overlay
/// @notice Each LP's leverage is an ISOLATED position on an external `ILevVenue` (real Euler EVK or Morpho
///         Blue — see `MorphoEscrowVenue`). The COLLATERAL is **weETH** (staked, not lent ⇒
///         no rehypothecation; earns ether.fi yield while pledged). The loop borrows the venue stable, buys
///         weETH, supplies it, until LTV hits the live target = the band's SOLD FRACTION `1 − √(entry/now)`
///         (NOT the static `L=1/α` knob — see the `debtDeltaToTarget` comment), capped at 2× — so the leverage
///         only engages to cancel the IL the flow actually created. The keeper (`quid-bridge::lev_keeper`) holds LTV
///         in band via `rebalance` and proactively de-levers via `deleverOne`/`cascadeDelever` so the
///         venue's liquidation engine never fires; a position it can't save falls to the venue's OWN
///         isolated liquidation (that LP only, never the basket). No QUI is minted; nothing touches
///         `POOLED_USD`. (The old LEVERAGE-ENGINE-SPEC.md is gone; this file is the canonical design.)
contract LevManager is LevBase {
    // ── immutables ──
    IERC20Min public immutable WEETH;   // collateral token (ether.fi weETH)
    IWeETH    internal immutable RATE;    // weETH→ETH rate (== WEETH addr; getEETHByWeETH)
    IERC20Min public immutable QUID;    // the basket stablecoin — redeemed (via AUX) to protect a levered LP's debt
    // ether.fi weETH mint (up-leg only — the down-leg is the v3 pool; see the header). NOT our band.
    address public constant ETHERFI_ADAPTER  = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    // (ETHERFI_REDEEMER + ETHFI_NATIVE_ETH removed 2026-08-09 — the instant-redeem leg they addressed was
    //  deleted 2026-08-06 and neither constant had a use site after it.)
    address internal constant SWAP_ROUTER_02   = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // Uniswap V3 (down-leg DEX fallback)
    address   public immutable WETH;    // oracle key (getTWAPforAsset(WETH))

    // ── leverage band ──
    // QU!D policy ceiling on the LP's CHOSEN target LTV. 50% = 2× is the IL-NEUTRAL max (delta-1); above it is
    // opt-in DIRECTIONAL (long-biased) leverage — the LP's own risk, isolated at the venue (buffer USD ≤ debt,
    // deliverable excludes gross). 7500 = 75% LTV ≈ 4×. Conservative LPs still pass 5000 (2×). Tunable policy.
    // ⚠️ The "~11% headroom below the 86% venue LLTV" this comment used to assert is NOT read from anywhere —
    // the 0.86 is hardcoded three times over (this comment, the keeper's QUID_LEV_VENUE_LIQ_BPS env var, and
    // the test's own permissionless `createMarket`). Morpho Blue markets are IMMUTABLE, so a market's LLTV is
    // exactly knowable via `idToMarketParams(id).lltv` and should be READ, never configured. Until it is, the
    // headroom this constant leaves is an assumption, not a fact — see QUEUE.md OPEN 19.
    uint256 internal constant BAND_BPS           = 300;  // ±3% LTV before a rebalance is worth doing
    uint256 internal constant MAX_LOOPS          = 8;    // bound the open/rebalance loop
    uint256 internal constant MAX_SLIPPAGE_BPS   = 100;  // 1% oracle-derived floor on EVERY swap (anti-MEV; see _floor)
    // Safe LTV the venue's protocol trove mints BOLD at, for a depth-independent close (see `_onFlashMint`). The
    // WETH locked above the BOLD's face value = the over-collateralization (1/LTV − 1 = 25% at 8000bps) the
    // PROTOCOL funds from `boldCloseReserve`, so the closing LP still gets full fair equity. Conservative vs the
    // ~90.9% Liquity max so the protocol trove itself is never near liquidation.
    uint256 internal constant PROTOCOL_MINT_LTV_BPS = 8000;
    /// Min collateral to OPEN — keeps the `_openLps` book (iterated in vogueETH on every deposit/withdraw/swap)
    /// from being Sybil-bloated by free zero-collateral opens (a gas-griefing DoS). ~0.05 weETH.
    uint256 internal constant MIN_OPEN_WEETH     = 0.05 ether;
    uint256 internal constant WAD = 1e18;

    /// @dev `targetLtvCapBps` = the LP's max-leverage LTV cap (≤ TARGET_LTV_CAP_BPS = 7500 bps ≈ 4×; 2× / 5000
    ///      bps is the IL-neutral value, higher is opt-in directional). `entryPriceWad` = ETH/USD at open: the IL
    ///      target is `1 − √(entryPrice/pxNow)` = the ETH the band has sold since entry (capped). Opens at
    ///      ZERO leverage and grows only with the realized move — proven in test/LevYbPnl.t.sol.

    /// @dev Enumerable set of LPs with an open position, so the Vault can sum the LIVE net-equity of the
    ///      whole book on-chain (`totalNetEquityEth`). `_lpIdx` is 1-based (0 = absent). Swap-pop on close.
    /// @notice Number of LPs with an open levered position (the cardinality the Vault iterates).
    function openLevCount() external view returns (uint256) { return _openLps.length; }
    /// @notice The `i`-th open LP — lets the off-chain keeper enumerate the book (`openLevCount` + `openLpAt`).
    function openLpAt(uint256 i) external view returns (address) { return _openLps[i]; }

    event Opened(address indexed lp, address venue, uint256 targetLtvBps);
    event Rebalanced(address indexed lp, bool levUp, uint256 amount, uint256 ltvBps);
    event Closed(address indexed lp, uint256 weethReturned);
    event DeleverFailed(address indexed lp, uint256 ltvBps);    // cascade skipped this LP → its venue liquidates it
    event RebalanceFailed(address indexed lp, uint256 ltvBps);  // batch rebalance skipped this LP (retried next tick)
    /// @dev RENAMED from `Reanchored` 2026-08-09 (was `(lp, uint64 epoch, uint160, uint256)`). The `epoch`
    ///      field went with the `reseatEpoch` counter. Renaming rather than shortening in place is deliberate:
    ///      a stale off-chain decoder reading the OLD 4-field shape does not revert on a 3-field payload, it
    ///      MISPARSES. A new name makes it fail to match instead — loud beats plausible.
    event ReanchoredToBand(address indexed lp, uint160 entrySqrtP, uint256 e0);

    error AlreadyOpen();
    error Reentrancy();
    error VenueNotAllowed();
    error NotGov();
    error NotFlash();
    error Slippage();
    error LenMismatch();   // batch arrays differ in length (custom error — no string-revert bytecode, EIP-170)
    error Auth();          // rebalanceOne/deleverOne caller ∉ {self, lp}
    event ProtectedFromQuid(address indexed lp, uint256 quidRedeemed, uint256 debtRepaid);

    uint256 private _lock = 1;
    modifier nonReentrant() { if (_lock != 1) revert Reentrancy(); _lock = 2; _; _lock = 1; }

    /// @notice Governance — the ONLY party that can allow a venue. CRITICAL: a caller-supplied venue feeds
    ///         collateralOf/debtOf into `totalNetEquityEth → vogueETH`, so an UNVETTED (fake) venue could
    ///         inject arbitrary phantom ETH backing and drain real ETH-LP principal on redemption. Only the
    ///         deployed Euler/Morpho adapters may ever be allowed. Pinned at construction.
    address internal immutable GOV;
    mapping(address => bool) public allowedVenue;
    bool internal venuesFrozen;                              // set by pinVenues → allowlist immutable thereafter
    event VenueAllowed(address indexed venue, bool ok);

    /// @notice Vogue (the band) — `closeLev` calls `syncLev` on it so a closed position's levered fee slice is
    ///         burned atomically (else it keeps earning band fees on backing that's gone, diluting honest LPs,
    ///         and the closer is incentivized never to poke the permissionless syncLev). GOV-pinned. 0 = unset.
    address public vogueSyncHook;
    /// PIN-ONCE via `init` (below), then frozen (not rotatable) — matches the renounce-everything posture.

    /// @notice (B) Sold-fraction target activation. Default OFF ⇒ the PROVEN 1−√(entry/now) target stays
    ///         active. GOV flips it ON only AFTER the band-driven fork proof of the sold-fraction
    ///         IL-cancellation + the reseat re-anchor land — so the wiring ships without changing the proven
    ///         behavior or activating money-path math the oracle-mock unit tests cannot exercise.


    /// @notice The Morpho singleton used PURELY as a zero-fee flash source for `_deleverFlash` (repay-first
    ///         de-lever). Pin-ONCE then frozen — NOT a rotatable setter: set at deploy to the canonical
    ///         Morpho, then immutable in effect. A flash source can't inject phantom backing (unlike a
    ///         venue), but pin-once keeps it off the governance attack surface entirely, matching the
    ///         venue-allowlist / renounce-everything posture. 0 = unset (de-lever disabled until pinned).
    address public flashProvider;

    /// WETH reserve that funds the Liquity over-collateralization when closing a BOLD-levered LP (see
    /// `_onFlashMint`). It is CONSUMED per close (becomes the protocol trove's own equity), so it is replenished
    /// from protocol capital / accrued leverage fees. The reserve balance is ITSELF the bound — NO governance cap:
    /// a close whose over-collateralization exceeds it simply reverts (fail-closed) and the LP falls to Liquity's
    /// own liquidation, never socialized. Permissionless top-up (only ever adds protocol WETH).
    uint256 public boldCloseReserve;
    function fundBoldCloseReserve(uint256 amount) external {
        if (amount == 0) return;
        IERC20Min(WETH).transferFrom(msg.sender, address(this), amount);
        boldCloseReserve += amount;
    }
    event FlashProviderSet(address provider);
    // flashProvider is pinned atomically alongside the hook + venues in `init` (below).

    // LIVE AND LOAD-BEARING — do not delete on the strength of the comment that used to be here (it named the
    // ether.fi instant-redeem, removed 2026-08-06, and a `_sellWeeth` that never existed in this contract).
    // The REAL producer is `LevMath._reimburse:663`: `IWETH9(weth).withdraw(pay)` runs under DELEGATECALL, so
    // WETH sends native ETH to THIS address before it is forwarded to the keeper. Removing this reverts the
    // keeper-gas peel on every de-lever.
    receive() external payable {}

    constructor(address weeth, address aux, address weth, address gov, address quid) LevBase(aux, weth) {
        WEETH = IERC20Min(weeth); RATE = IWeETH(weeth); WETH = weth;
        GOV = gov; QUID = IERC20Min(quid);
    }

    /// @notice ONE-SHOT GOV config — pin-once, then FROZEN, atomic (no partial-config window). Wires together:
    ///         the band sync-hook (`hook` = Vogue — closeLev re-syncs the fee slice + the BAND-ONLY E0 source),
    ///         the zero-fee flash provider (`flash` = Morpho for repay-first de-lever; `address(0)` disables it),
    ///         and the audited venue allowlist (`venues`, then FROZEN). NOT rotatable — a rotatable allowlist is
    ///         the phantom-backing rug vector the freeze exists to prevent (GOV could add a fake venue → phantom
    ///         backing → drain); a new hook/flash/venue ⇒ deploy a new LevManager. Consolidates the former
    ///         setVogueSyncHook/setFlashProvider/pinVenues (the manager↔venue circular dependency rules out a
    ///         constructor immutable). Matches BtcLevManager.init.
    function init(address hook, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert VenueNotAllowed();
        venuesFrozen = true;
        vogueSyncHook = hook;
        flashProvider = flash;
        emit FlashProviderSet(flash);
        for (uint i; i < venues.length; i++) {
            address v = venues[i];
            // COLLATERAL-SET gate: a LONG venue's collateral is custodied + valued by `_collToEth`, which
            // handles ONLY WETH (1:1) or weETH (rate) -- any other collateral silently misvalues into phantom ETH
            // backing (the rug the frozen allowlist stops). `LevMath.vetVenue` reverts an unvaluable one even for
            // GOV. (It also classifies a stable-collateral INVERSE venue as exempt — harmless if one is
            // allowlisted; the short subsystem that consumed it was removed, so the classification is unused.)
            LevMath.vetVenue(v, WETH, WETH, address(WEETH));
            allowedVenue[v] = true; emit VenueAllowed(v, true);
        }
    }

    // ════════════════════════════ COLLATERAL TYPE (weETH vs WETH) ════════════════════════════
    // The collateral type is DERIVED from the position's venue collateral token — never stored on `Pos`, so the
    // public struct ABI stays a stable 6-tuple. A WETH-collateral venue values 1:1 (WETH == ETH) and SKIPS the
    // ether.fi weETH<->WETH mint/redeem legs; every OTHER venue is the existing weETH path, byte-identical (the
    // weETH branch reduces to exactly what it did before this option existed).

    /// @notice True iff `venue`'s collateral token is WETH (⇒ 1:1 ETH valuation + no ether.fi mint/redeem).
    ///         (The mint-close BOLD/Liquity detection — try/catch `usesMintClose()` — now lives in
    ///         `LevMath.deleverFlashBody`, which owns the flash-WETH→mint-BOLD routing.)
    function _isWethVenue(ILevVenue venue) internal view returns (bool) {
        return ILevVenueColl(address(venue)).COLLATERAL() == WETH;
    }
    /// @notice The venue's collateral ERC20 (WETH or weETH) — the token this manager custodies for that position.
    function _collToken(ILevVenue venue) internal view returns (address) {
        return _isWethVenue(venue) ? WETH : address(WEETH);
    }
    /// @notice Collateral units -> ETH (1e18): weETH via the ether.fi staking rate; WETH 1:1. VIEW-safe, so the
    ///         Vault's `vogueETH()` (which sums grossCollateralEth/netEquityEth) still reads it as a pure view.
    function _collToEth(ILevVenue venue, uint256 units) internal view returns (uint256) {
        if (units == 0) return 0;
        return _isWethVenue(venue) ? units : RATE.getEETHByWeETH(units);
    }
    /// @notice USD (1e18) value of `units` collateral on `venue` = coll->ETH x ETH->USD oracle.
    function _collValueUsd(ILevVenue venue, uint256 units) internal returns (uint256) {
        if (units == 0) return 0;
        return (_collToEth(venue, units) * AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW)) / 1e18;
    }
    /// @notice Pull `amount` of the venue's equity collateral (weETH OR WETH) from `lp` and supply it as `lp`'s
    ///         isolated collateral. Own frame so `openLev` stays under the no-via_ir stack limit.
    function _supplyCollFrom(ILevVenue venue, address lp, uint256 amount) internal {
        address collTok = _collToken(venue);
        IERC20Min(collTok).transferFrom(lp, address(this), amount);
        IERC20Min(collTok).transfer(address(venue), amount);
        venue.supply(lp, amount);
    }

    // ════════════════════════════ VALUATION ════════════════════════════

    /// @notice USD (1e18) value of `weethUnits` weETH = weETH→ETH (rate) × ETH→USD (oracle).
    function weethValueUsd(uint256 weethUnits) public returns (uint256) {
        if (weethUnits == 0) return 0;
        uint256 ethAmt = RATE.getEETHByWeETH(weethUnits);           // 1e18 ETH
        uint256 pxUsd  = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);    // 1e18 USD/ETH
        return (ethAmt * pxUsd) / 1e18;
    }

    /// @notice `lp`'s LIVE net-equity in ETH (1e18) = collateral(weETH→ETH) − debt(USD→ETH), floored at 0.
    ///         This — NOT the gross collateral — is what the Vault counts as band backing (`vogueETH`): only
    ///         the LP's un-encumbered slice can ever be paired into `POOLED_ETH`, so a venue liquidation
    ///         (collateral seized, the equity term →0) can never strand the basket's `POOLED_USD`. The debt
    ///         leg is valued at the SAME oracle px the band pairs at; `px==0` (dead oracle) ⇒ 0 (no credit,
    ///         the conservative side). All-`view`: `collateralOf`/`debtOf`/`getEETHByWeETH`/the TWAP read are
    ///         every one a `view`, so this is safe to call from `Vault.vogueETH()`.
    function netEquityEth(address lp) public view returns (uint256) {
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _netEquityAt(lp, px);
    }
    /// @notice LIVE sum of every open position's net-equity (ETH, 1e18). Reads the oracle ONCE for the whole
    ///         book (price-consistent + cheaper). This is the single term `Vault.vogueETH()` adds.
    function totalNetEquityEth() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        if (n == 0) return 0;
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        for (uint256 i; i < n; i++) total += _netEquityAt(_openLps[i], px);
    }

    /// @notice #67 deliverability — USD this ETH-levered position can produce via a bounded, value-neutral
    ///         de-lever (LevMath.deliverableDollars). The REAL USD backing the band's pairing may count
    ///         (LEVERED-DELIVERABILITY-SPEC.md) so levered volatile pairs + earns fees even at basket surplus==0;
    ///         margin-bounded (never phantom). All-view (mirrors netEquityEth's view path — safe mid-swap).
    function deliverableDollars(address lp) public view returns (uint256) {
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _deliverableDollarsAt(lp, px);
    }
    /// @notice LIVE sum of every open position's deliverableDollars — the aggregate #67 counts as available USD
    ///         backing in the band-pairing sizer (sizeBySurplus addend). Reads the oracle ONCE (price-consistent).

    /// @notice `lp`'s GROSS collateral in ETH (1e18) = weETH→ETH, NO debt subtraction. This is the full-2× band
    ///         CAPACITY (net-equity + the debt-funded buffer). Price-independent (the ether.fi staking rate).
    ///         The buffer half's USD counterpart is the LP's own debt (folded into POOLED_USD and
    ///         excluded from committed via committedUsd18's live-debt subtraction, NOT basket surplus), so it
    ///         never strands basket USD; delivery of the buffer is unwind-only (`closeLev`).
    function grossCollateralEth(address lp) public view returns (uint256) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        return _collToEth(p.venue, p.venue.collateralOf(lp)); // weETH → ETH (rate) OR WETH 1:1
    }

    /// @notice LIVE sum of every open position's GROSS collateral (ETH, 1e18). Consumed as the well skew's
    ///         LOCKED-INVENTORY basis (Core.levGrossNative → SwapLib.skewWad `inv`): POOLED_ETH already pairs the
    ///         full 2× gross buffer in as tokenless depth, so the deliverable reservoir is `poolVol − gross`.
    ///         (Solvency accounting uses NET, not this: `vogueETH()` adds `totalNetEquityEth` and the shortfall
    ///         compares net-vs-net — the debt-funded buffer half is offset by the LP's borrow, see VaultLib.)
    function totalGrossCollateralEth() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        for (uint256 i; i < n; i++) total += grossCollateralEth(_openLps[i]);
    }

    /// @notice LIVE sum of every open position's debt (USD 1e18) — the invariant ceiling for the in-pool
    ///         buffer USD — each LP's `levBufferUsd ≤ debtUsd` (the per-LP debt cap), the debt-backed analog of
    ///         `committedUsd ≤ TVL`.
    function totalDebtUsd() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        for (uint256 i; i < n; i++) if (pos[_openLps[i]].open) total += debtUsd(_openLps[i]);
    }

    /// @notice `lp`'s net equity in USD (1e18) = collateral − debt, floored at 0. The single clean read the
    ///         off-chain keeper uses to size the economic (gas-vs-benefit) floor.
    function netEquityUsd(address lp) public returns (uint256) {
        if (!pos[lp].open) return 0;
        ILevVenue v = pos[lp].venue;
        uint256 coll = _collValueUsd(v, v.collateralOf(lp));
        uint256 d = debtUsd(lp);
        return coll > d ? coll - d : 0;
    }

    /// @notice `lp`'s debt in USD (1e18), normalizing the venue loan token's decimals AND its PRICE.
    function debtUsd(address lp) public view override returns (uint256) {
        ILevVenue v = pos[lp].venue;
        address loan = v.stable();
        return LevMath._toUsd18(address(AUX),loan, v.debtOf(lp));
    }


    /// @notice VENUE-SAFETY LTV of `lp`, in bps = debt / ACTUAL collateral. The keeper uses THIS (and only
    ///         this) for the liquidation-avoidance track — it must track the venue's own health basis.
    function getCurrentLtvBps(address lp) public returns (uint256) {
        ILevVenue v = pos[lp].venue;
        uint256 coll = _collValueUsd(v, v.collateralOf(lp));
        return LevMath.ltvBps(debtUsd(lp), coll);
    }

    /// @notice Delegated QU!D-protect (autonomous layer): redeem the LP's OWN opted-in QUID to repay the LP's
    ///         OWN debt when the position nears venue liquidation. Moves NO value to the caller — proceeds only
    ///         ever reduce `lp`'s debt; any excess stable is refunded to `lp`. Opt-in = the LP's QUID `approve`
    ///         to this manager (an EOA for solo, the n-of-m family Safe for a family plan — either works, the
    ///         allowance is just a `transferFrom` source). The amount redeemed is DERIVED from the debt (and
    ///         capped by the allowance), so a hostile operator can neither over-redeem the LP's QUID nor extract
    ///         a wei. Permissionless (the fleet keeper / enclave calls it), near-liq-gated (anti-grief). No
    ///         per-action quorum or cap — safety is by construction. Reuses `venue.repayFor`.
    function protectFromQuid(address lp, uint256 minStableOut) external nonReentrant returns (uint256 repaid) {
        if (!pos[lp].open) revert NotOpen();
        // Gate (near-liq anti-grief) + mechanics (redeem the LP's opted-in QUID → repay the LP's OWN debt → refund
        // excess to the LP) live in LevMath (public, delegatecall — bytecode OUTSIDE this contract, run in-context).
        uint256 pull;
        (pull, repaid) = LevMath.protectExec(
            address(QUID), address(AUX), SWAP_ROUTER_02, address(pos[lp].venue), lp, getCurrentLtvBps(lp), minStableOut);
        _reimburseKeeper(msg.sender, 0);   // the refund is stable (no WETH to peel) ⇒ keeper gas drawn from gasReserve
        emit ProtectedFromQuid(lp, pull, repaid);
    }

    /// @notice IL-TARGET LTV of `lp`, in bps = debt / E0 (the FIXED band-only base the debt is sized to).
    ///         The keeper's IL-track compares THIS to `ilTargetLtvBps` so it triggers on the same debt-vs-E0
    ///         basis the sizing (`debtDeltaToTarget = E0·t`) uses — NOT the actual-collateral LTV, which
    ///         would re-settle at the old 1/(1−t) over-hedge. Distinct from `getCurrentLtvBps` (venue safety).
    function ilLtvBps(address lp) public returns (uint256) {
        if (!pos[lp].open) return 0;
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        uint256 e0Usd = LevMath.e0Usd(pos[lp].e0, px);
        return LevMath.ltvBps(debtUsd(lp), e0Usd);
    }

    /// @notice Stable delta (USD, 1e18) + direction to re-hit target LTV. Inside the band ⇒ (false,0).
    ///         Reads the oracle ONCE (price-consistent — avoids the getTWAPforAsset-mutates-mid-call flip).
    function debtDeltaToTarget(address lp) public returns (bool levUp, uint256 amountUsd) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (false, 0);
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        uint256 curDebt = debtUsd(lp);
        // (B) LIVE IL target = the band's ACTUAL sold fraction (soldFractionWad), capped; √p fallback.
        uint256 t = _ilTargetLive(p, px);
        // Size the IL hedge to the FIXED E0 (band-only at entry), valued at the current px — NOT the
        // buffer's own growing collateral, which caused the 1/(1−t) over-hedge. targetDebt = E0·t; band in bps.
        // Shared target/in-band/direction math (identical to the BTC path — see LevMath.debtDelta).
        uint256 e0Usd = LevMath.e0Usd(p.e0, px);
        return LevMath.debtDelta(e0Usd, curDebt, t, BAND_BPS);
    }

    /// @notice The IL-cancelling target LTV (bps) = `1 − √(entryPrice / pxNow)` = the ETH the band has sold
    ///         since entry, clamped to the LP's chosen LTV cap (≤ 7500 bps). ZERO when flat/down (no IL accrued ⇒ no leverage).
    ///         PROVEN in test/LevYbPnl.t.sol. This REPLACES the static knob / the wrong `L=1/α`.
    function ilTargetLtvBps(address lp) public returns (uint256) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return _ilTargetLive(p, px);
    }
    /// @notice (B) LIVE IL target (bps): the band's ACTUAL sold fraction (`Vogue.soldFractionWad`) capped at
    ///         the LP's cap — the ground-truth IL, reflecting the band's real (drifting) α (subsumes A). Falls
    ///         back to the 1−√(entry/now) estimate when the band host is unwired or the sold fraction is
    ///         unmeasurable (band unset / `entrySqrtP` 0). A band reseat recenters the ticks + realizes IL, so
    ///         `entrySqrtP` (and E0/entryPrice) MUST be re-anchored to the new center to avoid over-measuring the
    ///         sold fraction across the reseat — `_reanchorIfReseated` (below, called from `rebalance`) does this
    ///         on every keeper cycle, and the sold-fraction IL-cancellation is fork-proven (LevYbReal/LevCascade
    ///         with `setSoldFractionActive(true)`).
    function _ilTargetLive(Types.Pos memory p, uint256 px) internal returns (uint256) {
        return LevMath.ilTargetLive(vogueSyncHook, p.entrySqrtP, p.entryPriceWad, px, p.targetLtvCapBps);
    }

    /// @notice (B) Realize on a band RESEAT. If the band recentered since this position last anchored
    ///         (`Vogue.reseatEpoch()` advanced), re-anchor the sold-fraction reference (`entrySqrtP`), the
    ///         entry price, and E0 to the NEW center — E0 becomes the LP's CURRENT band ETH depth (BAND-ONLY,
    ///         matching `openLev`; the buffer is HODL-neutral equity, not IL), so the next hedge cycle starts at
    ///         ZERO IL from the recentered band instead of measuring the sold fraction across the tick-config
    ///         change (which over-hedges). No-op unless the sold-fraction target is active (the √p fallback
    ///         re-anchors implicitly via px). Mutating ⇒ only reachable from the keeper's `rebalance`.
    function _reanchorIfReseated(address lp) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) return;
        (bool go, uint160 s) = LevMath.reanchorCompute(vogueSyncHook, p.entrySqrtP);
        if (!go) return;
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // (A): a reseat REALIZES the accrued IL, so re-anchor E0 to the position's CURRENT net-equity (the new
        // fixed base) — NOT bandEthOf (which is 0 in the (A) model, since the deposit has no separate unlevered
        // band position). Net-equity is the delta-1 slice now in the recentered band; the next hedge cycle sizes
        // from it at zero IL. (The over-hedge fix still holds: E0 tracks net-equity, NOT the growing collateral.)
        uint256 base = netEquityEth(lp);
        p.entrySqrtP    = s;
        p.entryPriceWad = uint128(px);
        p.e0         = uint128(base);
        emit ReanchoredToBand(lp, s, base);
    }

    // ════════════════════════════ OPEN ════════════════════════════

    /// @notice Open an isolated leveraged position. The LP supplies `collWeeth` weETH (approved here) as
    ///         equity; the loop borrows the venue stable, buys weETH via the SOR+converter, and supplies it
    ///         back until LTV reaches `targetLtvBps`. `minWethOut[i]` bounds each loop's stable→WETH swap
    ///         (off-chain quoted). `targetLtvBps` must sit inside `[1, TARGET_LTV_CAP_BPS]` (7500 bps = 75% LTV → up to ~4×).
    function openLev(uint64 targetLtvBps, ILevVenue venue, uint256 collWeeth, uint256[] calldata minWethOut)
        external nonReentrant
    {
        if (pos[msg.sender].open) revert AlreadyOpen();
        // venue must be on the frozen allowlist AND not incident-flagged (GOV setVaultHealth) -- fresh
        // collateral must never land on an unvetted or broken market. Reverts live in LevMath (off this EIP-170-
        // critical manager). Only OPEN is gated: close/rebalance stay open so the keeper can unwind OUT of a block.
        LevMath.requireOpenable(allowedVenue[address(venue)], address(AUX), address(venue));
        if (collWeeth < MIN_OPEN_WEETH) revert BadTarget();           // anti-Sybil: no free zero-collateral book entries
        if (targetLtvBps == 0 || targetLtvBps > TARGET_LTV_CAP_BPS) revert BadTarget();
        // `targetLtvBps` is the LP's max-leverage CAP; the live target is the entry-price-driven IL target.
        // Pin the entry price so the position opens at ZERO leverage and levers only as the band sells.
        uint256 entryPx = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // (A) INTRINSIC deposit model (2026-07-03): the LP's ONE deposit (`collWeeth`) IS the levered position.
        // Its net-equity is synced into the concentrated band (`levPooled`) as delta-1 (IL-free) depth by the 2×
        // leverage — so E0, the FIXED IL base the hedge sizes against, is the DEPOSIT ITSELF (in ETH), NOT a
        // separate unlevered band position. FIXED at open (the over-hedge fix): the collateral grows as the keeper
        // levers, but E0 stays = the deposit, so `targetDebt = E0·soldFrac` cancels the band's IL exactly. (Unlike
        // the old (B) two-pool model, there is no separate deliverable principal band — that isolation is traded
        // for capital efficiency; the whole deposit is levered.) SAFETY:
        // the up-side-only clamp de-levers this toward 0 debt below entry, so the deposit is never held at 2× into
        // a crash. `entrySqrtP` still tracks the band for the sold-fraction reference.
        uint256 e0 = _collToEth(venue, collWeeth);   // (A): the deposit (weETH→ETH rate, or WETH 1:1) is the IL base
        uint160 entrySqrtP;
        if (vogueSyncHook != address(0)) {
            try ILevSyncHook(vogueSyncHook).bandSqrtP() returns (uint160 s) { entrySqrtP = s; } catch {}
        }
        pos[msg.sender] = Types.Pos({venue: venue, targetLtvCapBps: targetLtvBps, entryPriceWad: uint128(entryPx),
                               e0: uint128(e0), entrySqrtP: entrySqrtP, open: true});
        _trackOpen(msg.sender);   // join the book the Vault sums net-equity over

        // 1. Pull equity collateral (weETH OR WETH, per the venue) and supply as isolated collateral.
        _supplyCollFrom(venue, msg.sender, collWeeth);

        // 2. Loop: borrow toward target, buy collateral, supply, until inside band (or MAX_LOOPS).
        address stable = venue.stable();
        for (uint256 i; i < MAX_LOOPS; i++) {
            (bool levUp, uint256 needUsd) = debtDeltaToTarget(msg.sender);
            if (!levUp || needUsd == 0) break;
            uint256 minOut = i < minWethOut.length ? minWethOut[i] : 0;
            _leverUpBuy(venue, msg.sender, stable, needUsd, minOut);
        }
        // No MIN-debt floor: the corrected design opens at ZERO leverage (IL target = 0 at entry) and levers
        // up only as the band sells. The MAX bound is the per-position LTV cap (≤ 7500 bps ≈ 4×), enforced by the target.
        emit Opened(msg.sender, address(venue), targetLtvBps);
    }

    /// @notice Adjust the caller's max-leverage CAP (bps LTV, ≤ TARGET_LTV_CAP_BPS = 7500 ≈ 4×). The live IL target = the band's sold
    ///         fraction `1 − √(entry/now)` and is auto-computed each tick, never exceeding this cap. Permissioned
    ///         to the LP because the cap is a risk choice — `rebalance` toward the target stays permissionless.
    // ════════════════════════════ REBALANCE (keeper, up-side overlay) ════════════════════════════

    /// @notice Hold `lp`'s LTV inside the band. levUp: borrow→buy-weETH→supply. levDown (the
    ///         liquidation-avoidance): withdraw weETH→sell→repay. `minOut` bounds the single swap this call
    ///         performs (off-chain quoted by the keeper). Permissionless: only moves toward target.
    /// PERMISSIONLESS single-LP rebalance toward the IL target. Sets `_activeKeeper` so the flash reimburses the caller.
    function rebalance(address lp, uint256 minOut) external nonReentrant {
        _activeKeeper = msg.sender;
        _rebalanceBody(lp, minOut);
    }

    /// @notice BATCH rebalance — hold every out-of-band LP at its IL target in ONE tx (mirrors `cascadeDelever`),
    ///         FAULT-TOLERANT: an LP whose rebalance reverts is SKIPPED (emit `RebalanceFailed`) and the loop
    ///         continues. PERMISSIONLESS + only moves toward target. Lets the keeper fire ONE tx for the whole book
    ///         instead of N per-LP txs — the central-rebalancer path.
    function rebalanceMany(address[] calldata lps, uint256[] calldata minOuts) external nonReentrant {
        if (lps.length != minOuts.length) revert LenMismatch();
        _activeKeeper = msg.sender;              // set ONCE for the batch (transient; each rebalanceOne's flash reads it)
        for (uint256 i; i < lps.length; i++) {
            if (!pos[lps[i]].open) continue;
            try this.rebalanceOne(lps[i], minOuts[i]) {}
            catch { emit RebalanceFailed(lps[i], getCurrentLtvBps(lps[i])); }
        }
    }

    /// @notice The atomic unit of the batch; `external` so `rebalanceMany` can try/catch it. Self/LP ONLY — the
    ///         permissionless entries are `rebalance`/`rebalanceMany`. NO `nonReentrant` (the entrypoint holds the
    ///         guard); `_activeKeeper` is set by that entrypoint before the loop, so the flash-callback
    ///         reimbursement still targets the real keeper.
    function rebalanceOne(address lp, uint256 minOut) external {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        _rebalanceBody(lp, minOut);
    }

    function _rebalanceBody(address lp, uint256 minOut) internal {
        if (!pos[lp].open) revert NotOpen();
        _reanchorIfReseated(lp);                 // (B) realize + re-anchor E0/entrySqrtP if the band recentered
        ILevVenue venue = pos[lp].venue;
        address stable = venue.stable();
        (bool levUp, uint256 deltaUsd) = debtDeltaToTarget(lp);
        // `deltaUsd == 0` means already on target, so both branches below are skipped. (This line used to
        // explain the absence of an early return by pointing at "the bidirectional short below" — that
        // subsystem was REMOVED 2026-07-24, see the note under this block. The sync hook at the end of the
        // function is the only remaining reason there is no early return.)
        if (deltaUsd != 0) {
            if (levUp) {
                _leverUpBuy(venue, lp, stable, deltaUsd, minOut);
            } else {
                // Flash-repay-first: `deleverRepayUsd` is the closed-form `Δ/(1−t)`, so one flash lands on target
                // with NO withdraw-before-repay health breach. (It used to also return 0 while a SHORT was open,
                // so the de-lever would not fight the short leg's funding — that case is DEAD, the short
                // subsystem was removed 2026-07-24 and no short can be open.)
                _deleverFlash(venue, lp, stable, deleverRepayUsd(lp), minOut);
            }
            emit Rebalanced(lp, levUp, deltaUsd, getCurrentLtvBps(lp));
        }
        // SHORT SUBSYSTEM REMOVED (2026-07-24): the below-entry "restore delta-1" short REALIZES the down-side LVR
        // (sells the over-hold into the fall, forfeits the recovery) — down-side IL is IMPERMANENT and heals on
        // its own, so for a long-biased LP holding strictly dominates over any round-trip; same fees, minus the
        // realized leak. It's a bet AGAINST the LP's long thesis (the up-side overlay bets WITH it — that stays).
        // Up-side-only is the correct design, not just the default. See docs §J.4 (settled verdict).
        // full-2×: reconcile the band to the NEW gross/debt atomically so each levBufferUsd ≤ its debt and the
        // band depth stay exact after a lever-up/de-lever — correct-by-construction, not reliant on a poke.
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
    }

    // ════════════════════════════ CASCADE DE-LEVER (the correlated-crash path) ════════════════════════════

    /// @notice De-lever ONE position toward target (down-leg only). The atomic unit of the cascade;
    ///         `external` so `cascadeDelever` can try/catch it. Callable by the contract itself (cascade) or
    ///         the LP. Iterates to within band (one chunk only gets close — selling weETH reflexively nudges
    ///         the band mark + slippage leave headroom — so re-solve on the new mark and chip again,
    ///         bounded by MAX_LOOPS; a no-progress chunk breaks early so a stuck position never spins).
    /// @dev NO `nonReentrant` BY DESIGN: `cascadeDelever` (which holds the guard) calls this via `this.deleverOne`,
    ///      so a guard here would revert the whole cascade. Safe without it — caller is self or the LP only, and
    ///      every token leg uses ACTUAL balance deltas (no nominal trust), so a re-entry can't mis-account.
    function deleverOne(address lp, uint256 minOut) external {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        Types.Pos memory p = pos[lp];
        if (!p.open) return;
        uint256 repayUsd = deleverRepayUsd(lp);                                 // Δ/(1−t), 0 if inside band
        if (repayUsd == 0) return;                                              // inside band → done
        uint256 debtBefore = p.venue.debtOf(lp);
        // ONE flash-repay-first shot reaches target (no health breach, any depth). If the position is
        // genuinely underwater/illiquid the flash can't be repaid → the whole op reverts → `cascadeDelever`
        // catches it and the position falls to the venue's own isolated liquidation.
        _deleverFlash(p.venue, lp, p.venue.stable(), repayUsd, minOut);
        require(p.venue.debtOf(lp) < debtBefore, "delever: no liquidity");      // sourced nothing → cascade skips it
        emit Rebalanced(lp, false, 0, getCurrentLtvBps(lp));
        // full-2×: reconcile the band to the reduced gross/debt (levBufferUsd must not exceed the now-smaller
        // debt) — atomic, so the ≤Σdebt invariant holds continuously even mid-cascade. try/catch: never break it.
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
    }

    /// @notice SYSTEMIC cascade de-lever — the correlated-crash path. De-levers a batch in ONE tx,
    ///         FAULT-TOLERANT: a position whose de-lever can't source liquidity is SKIPPED (emit
    ///         `DeleverFailed`) and the loop continues — one stuck LP can NEVER block the rest; it falls to
    ///         its venue's OWN isolated liquidation. PERMISSIONLESS + only moves toward target.
    function cascadeDelever(address[] calldata lps, uint256[] calldata minOuts) external nonReentrant {
        if (lps.length != minOuts.length) revert LenMismatch();
        _activeKeeper = msg.sender;              // each deleverOne's flash callback reimburses this keeper's gas
        for (uint256 i; i < lps.length; i++) {
            address lp = lps[i];
            if (!pos[lp].open) continue;
            try this.deleverOne(lp, minOuts[i]) {}
            catch { emit DeleverFailed(lp, getCurrentLtvBps(lp)); }
        }
    }

    // ════════════════════════════ CLOSE ════════════════════════════

    /// @notice Fully unwind `lp`'s position: repay all debt by selling collateral, return the remaining
    ///         weETH to the LP. Loop-bounded. `minOut` bounds each weETH→stable swap. LP-only.
    function closeLev(uint256 minOut) external nonReentrant {
        _closeLev(msg.sender, minOut, false);   // LP chose to exit -- nothing to restore, drop the slot
    }

    /// @notice Permissioned force-close of `lp`'s lever ON THEIR BEHALF — the §4.2 cover-lever entry
    ///         (docs/actionable/JIT-DEPTH-GUARANTEE.md). Callable ONLY by the GOV-pinned `vogueSyncHook`
    ///         (the ETH band — so a `Vogue._withdraw` can cover an open lever before the free-ladder burn) — NO
    ///         GOV force-close (no live governance authority). SEPARATE trusted-caller path, so the LP-only
    ///         `closeLev` msg.sender gate is left intact (NOT
    ///         weakened). Same unwind mechanics as `closeLev` (flash-repay-FIRST → return the collateral to `lp`);
    ///         `minOut` bounds each collateral→stable swap. Backing-safe by construction: it only ever repays
    ///         `lp`'s OWN debt and hands `lp`'s OWN freed collateral back to `lp`, so a hostile hook can neither
    ///         extract value nor redirect it — at worst it forces a close the LP could do themselves.
    ///         `nonReentrant`: the tail `syncLev` hook call-back is already try/catch-wrapped, so a re-entrant
    ///         band context degrades to the permissionless slice reconcile.
    function closeLevFor(address lp, uint256 minOut) external nonReentrant {
        if (msg.sender != vogueSyncHook) revert NotGov();
        _closeLev(lp, minOut, true);            // INVOLUNTARY -- retain state so the LP can be restored
    }

    /// @dev Shared close body — parameterized by `lp` so the LP-only `closeLev` and the permissioned
    ///      `closeLevFor` reuse ONE implementation (no duplicated flash/withdraw/short-unwind logic). Verbatim of
    ///      the prior in-line `closeLev` body; only `lp` moved from a local (`msg.sender`) to a parameter.
    function _closeLev(address lp, uint256 minOut, bool keepState) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) revert NotOpen();
        ILevVenue venue = p.venue;
        address stable = venue.stable();

        // Repay ALL debt in ONE flash-repay-first shot (repay → withdraw the freed collateral → sell → return
        // the flash), then hand back the remaining collateral. Repaying FIRST means the withdraw never
        // breaches health — dissolving the withdraw-before-repay bug the real-Euler close test surfaced,
        // with no per-pass health-safe clamp or loop. A truly underwater position can't cover the flash, so
        // this reverts and the position falls to the venue's isolated liquidation (as it should).
        uint256 d = debtUsd(lp);
        if (d > 0) _deleverFlash(venue, lp, stable, d, minOut);
        uint256 remaining = venue.collateralOf(lp);
        uint256 back = remaining > 0 ? venue.withdraw(lp, remaining) : 0;
        if (back > 0) IERC20Min(_collToken(venue)).transfer(lp, back); // weETH OR WETH, per the venue (incl. rebuilt short base)
        // A voluntary close DROPS the slot. An involuntary one (closeLevFor, the band covering a lever
        // before its free-ladder burn) RETAINS every field with open=false, because the LP did not choose to
        // exit and must be restorable to the same position after the refill. Safe only because ilLtvBps,
        // ilTargetLtvBps and debtDeltaToTarget now gate on .open -- before that, a retained Pos made
        // debtDeltaToTarget report "lever up" on a closed position.
        if (keepState) p.open = false; else delete pos[lp];
        _untrackOpen(lp);          // leave the book — net-equity contribution drops to 0
        // Burn the LP's levered band slice NOW (net-equity is 0 post-delete) so it can't keep earning band
        // fees on vanished backing. Non-fatal: the slice is also reconcilable permissionlessly via syncLev.
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
        emit Closed(lp, back);
    }

    /// @notice The stable (USD 1e18) that must be REPAID to bring `lp` to target LTV. De-levering sells
    ///         collateral too, so the naive `curDebt−targetDebt` UNDERSHOOTS (that's exactly why the old
    ///         chunked path had to loop); the closed form that lands ON target is `Δ/(1−t)`. Zero when the
    ///         position is inside the de-lever band (or below target). One consistent oracle read.
    function deleverRepayUsd(address lp) internal returns (uint256) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        // (Self-funded short holds stable collateral, not debt, so the keeper de-lever no longer needs to be gated
        // on an open short — below entry the long debt is 0, so de-lever is a natural no-op there anyway.)
        // Compare-math folded to LevMath.deleverRepay: on the FIXED E0 the repay is simply curDebt − targetDebt
        // (no Δ/(1−t) inflation — that was only needed when the target tracked the shrinking collateral).
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return LevMath.deleverRepay(LevMath.e0Usd(p.e0, px), debtUsd(lp), _ilTargetLive(p, px), BAND_BPS);
    }

    // ════════════════════════════ DE-LEVER — flash-repay-FIRST (no health breach by construction) ══════════

    /// @notice De-lever `lp` toward target by repaying `repayUsd` (USD 1e18) via a Morpho flash loan that
    ///         REPAYS the debt FIRST, then withdraws the freed collateral to sell. Because the repay precedes
    ///         the withdraw, the LTV only ever DROPS during the op — a health-gated venue can NEVER revert on
    ///         a "withdraw breaches health" (the bug the old withdraw-then-repay chunk hit near liquidation).
    ///         Atomic and single-shot at any depth. Shared by rebalance-down, deleverOne, and close.
    function _deleverFlash(ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut) internal {
        // repay-first flash (mode 0), or for a mint-close (BOLD) venue flash-WETH→mint-BOLD (mode 1): body in LevMath
        // (delegatecall — bytecode OUTSIDE this contract). The flash re-enters this manager's own onMorphoFlashLoan.
        LevMath.deleverFlashBody(_extractCfg(_isWethVenue(venue)), venue, lp, stable, repayUsd, minOut, PROTOCOL_MINT_LTV_BPS);
    }

    /// Transient handoff for the mode-2 (`deleverToVault`) callback's freed-stable result. Auto-clears at tx end.
    uint256 private transient _lastFreed;

    /// The manager's runtime addresses + gas-reserve for the mode-2 extraction body (delegatecall → LevMath).
    function _extractCfg(bool isWeth) internal view returns (LevMath.ExtractCfg memory) {
        return LevMath.ExtractCfg({ weth: WETH, weeth: address(WEETH), aux: address(AUX),
            flashProvider: flashProvider, keeper: _activeKeeper, gasReserve: gasReserve,
            maxSlippageBps: uint16(MAX_SLIPPAGE_BPS), isWethVenue: isWeth });
    }

    /// @notice §G.3 REDEEM/SWAP-OUT value-neutral extraction: free up to `extractUsd` (USD 1e18) of THIS LP's
    ///         in-band levered net-equity to `vault` (the redeem sink) via a flash-repay-FIRST partial de-lever
    ///         that PRESERVES LTV — repay ΔD=`extractUsd`·debt/netEq, withdraw+sell the paired collateral, surplus
    ///         → `vault`. Gated to the band (`vogueSyncHook`, the redeem/swap-out settle path) — NEVER
    ///         permissionless (it routes value OUT). Bounded by the #67 `deliverableDollars` (never past the liq
    ///         threshold). The LP's residual position stays OPEN (unlike `closeLev`); `syncLev` reconciles the
    ///         shrunk net-equity band slice. Uniform over YB + directional (both in-band); the YB-vs-directional
    ///         settlement is on the LP's untouched residual, not here. Returns the stable actually routed to `vault`.
    function deleverToVault(address lp, uint256 extractUsd, address vault, uint256 minOut)
        external returns (uint256 freed)     // NOT nonReentrant: the outer deleverBook (or the band's redeem lock) holds it — mirrors deleverOne
    {
        if (msg.sender != vogueSyncHook && msg.sender != address(this)) revert NotGov(); // band settle OR deleverBook self-call
        Types.Pos memory p = pos[lp];
        if (!p.open || extractUsd == 0 || flashProvider == address(0)) return 0;
        uint256 cap = deliverableDollars(lp);                     // value-neutral bound (≤ liq threshold, #67)
        if (extractUsd > cap) extractUsd = cap;
        if (extractUsd == 0) return 0;
        uint256 repayStable = LevMath.sizeRepayStable(                     // d/netEq/clamp — body in LevMath (EIP-170)
            p.venue, lp, extractUsd, debtUsd(lp), AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW), _isWethVenue(p.venue), address(WEETH), address(AUX));
        if (repayStable == 0) return 0;
        // mode 2 = flash the debt stable → repay-first → withdraw+sell paired collateral → surplus to `vault`.
        IMorphoFlash(flashProvider).flashLoan(p.venue.stable(), repayStable,
            abi.encode(uint8(2), lp, address(p.venue), p.venue.stable(), extractUsd, vault, minOut));
        freed = _lastFreed; _lastFreed = 0;
        // Reconcile the shrunk net-equity into the band slice (try/catch: never block the settle).
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
    }

    /// @notice §M.1 #54-ETH funding quote: for `lp`, the venue stable + the EXACT native amount the Vault must
    ///         pre-fund to the venue to de-lever up to `maxUsd18` of debt (clamped to LIVE debt so no stray stable
    ///         strands on the adapter — `swapOutDelever` repays exactly this, recomputing the same clamp). View.
    ///         IDENTICAL shape to `BtcLevManager.swapOutDeleverAmt` (the ETH swap-out mirror of #54).

    /// @notice §M.1 UNLEVERED (0-debt) net-equity delivery — the HODL slice below entry where the keeper has
    ///         de-levered target debt → 0. `swapOutDelever` no-ops here (nothing to repay), which would leave the
    ///         unlevered net-equity PHANTOM (priced in POOLED_ETH, undeliverable because its collateral sits in the
    ///         lev venue, not the base 4626). This delivers it. NO repay / NO `takeToSettle` (no debt) ⇒ NO basket-
    ///         stable draw ⇒ NO backing hazard: withdraw up to `wethWanted`-worth of the net-equity collateral and
    ///         deliver it as WETH. The V4 curve already did the ETH→USD rebalance for the LP's band slice; `syncLev`
    ///         reconciles the shrunk net-equity; the keeper re-levers next tick. Gated to the band.
    function swapOutDeliverUnlevered(address lp, uint256 wethWanted, address recipient, uint256 minWethOut)
        external nonReentrant returns (uint256 wethDelivered) {
        if (msg.sender != vogueSyncHook) revert NotGov();          // band settle path only
        Types.Pos memory p = pos[lp];
        if (!p.open || wethWanted == 0) return 0;
        if (p.venue.debtOf(lp) != 0) return 0;                     // levered ⇒ use swapOutDelever (repay path)
        // withdraw net-equity collateral + MEV-floor + deliver-as-WETH: body in LevMath (delegatecall, EIP-170).
        wethDelivered = LevMath.swapOutDeliverUnleveredBody(p.venue, lp, wethWanted, recipient, minWethOut, _extractCfg(_isWethVenue(p.venue)));
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
    }

    /// @notice §M.1 ETH SWAP-OUT delivery-side de-lever (equity-preserving; mirrors `BtcLevManager.swapOutDelever`
    ///         but DELIVERS WETH instead of un-encumbering — ETH has no already-spliced sats). The Vault
    ///         pre-transfers `stableUsd`-worth of the swap's OWN proceeds to the venue (via `takeToSettle`); here we
    ///         repay the LP's debt with it, then free EXACTLY the repaid value of collateral and deliver it to
    ///         `recipient` as WETH. VALUE-NEUTRAL: −collateral −debt of equal oracle value ⇒ net-equity preserved,
    ///         LTV improves, the LP only DE-LEVERS (keeper re-levers next tick). Turns the §M phantom levered depth
    ///         into REAL deliverable ETH. Gated to the Vault settle path. Returns (USD 1e18 repaid, WETH delivered).
    function swapOutDelever(address lp, uint256 stableUsd, address recipient, uint256 minWethOut)
        external nonReentrant returns (uint256 usedUsd, uint256 wethDelivered) {
        if (msg.sender != vogueSyncHook) revert NotGov();          // Vault/band settle path only
        Types.Pos memory p = pos[lp];
        if (!p.open) return (0, 0);
        // repay-with-the-Vault-pre-transferred-stable → free EXACTLY the repaid value of collateral → deliver as
        // WETH (value-neutral): body in LevMath (delegatecall, bytecode OUTSIDE this contract).
        (usedUsd, wethDelivered) = LevMath.swapOutDeleverBody(
            p.venue, lp, stableUsd, recipient, minWethOut, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW), _extractCfg(_isWethVenue(p.venue)));
        // Reconcile the shrunk slice into the band (try/catch: never block the settle).
        if (vogueSyncHook != address(0)) { try ILevSyncHook(vogueSyncHook).syncLev(lp) {} catch {} }
    }

    /// @notice §G.3/§G.6 REACTIVE de-lever sweep — the ONE mechanism the redeem AND swap-out settle paths share
    ///         (the keeper's `cascadeDelever` is the PROACTIVE half; it stays distinct because its per-LP intent is
    ///         restore-to-target, not extract-to-sink). Walks the open-lever book (this manager OWNS `_openLps`, so
    ///         the walk lives here, not reached into from the basket) and value-neutrally extracts up to `usdWanted`
    ///         (USD 1e18) into `sink`, stopping as soon as it's met. FAULT-TOLERANT via the same `this.`-self-call
    ///         pattern as `cascadeDelever`: a stuck/illiquid position reverts its own `deleverToVault` and is
    ///         SKIPPED, never blocking the sweep. Gated to the band (`vogueSyncHook`). Partial de-lever keeps
    ///         positions OPEN, so the book is stable across the walk (no swap-pop mid-loop). Returns stable routed
    ///         to `sink`. Book-order (not strict LTV rank): each tap is value-neutral + capped at its own #67
    ///         deliverable, so order only picks WHICH lightly-levered LPs are tapped — strict LTV-ranking is the
    ///         proactive cascade's job.
    function deleverBook(uint256 usdWanted, address sink, uint256 minOut)
        external nonReentrant returns (uint256 freed)
    {
        if (msg.sender != vogueSyncHook) revert NotGov();
        uint256 n = _openLps.length;
        for (uint256 i; i < n && freed < usdWanted; i++) {
            try this.deleverToVault(_openLps[i], usdWanted - freed, sink, minOut) returns (uint256 f) { freed += f; }
            catch { /* stuck position skipped → falls to the keeper cascade / venue liquidation */ }
        }
    }

    /// @notice Morpho flash-loan callback. ONLY the pinned provider may call it, and Morpho invokes it solely
    ///         on the address that called `flashLoan` (us), so it fires only from `_deleverFlash`. Repays the
    ///         LP's debt with the flashed stable, withdraws the now-health-safe collateral, sells it, keeps
    ///         exactly `assets` to return to Morpho (guaranteed by the swap's oracle floor, else the whole op
    ///         reverts), and hands any surplus (realized over-collateralization) to the LP.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != flashProvider) revert NotFlash();
        // Both layouts share the shape (uint8 mode, address lp, address venue, address stable, uint256): the
        // trailing word is `minOut` (mode 0, flashed stable) or `repayBold` (mode 1, flashed WETH).
        (uint8 mode, address lp, address venueAddr, address stable, uint256 last) =
            abi.decode(data, (uint8, address, address, address, uint256));
        if (mode == 1) { _onFlashMint(assets, lp, venueAddr, stable, last); return; }   // own frame (stack, no via_ir)
        if (mode == 2) { _extractSettle(assets, data); return; }             // §G.3 redeem/swap-out — own frame
        _deleverSettle(assets, lp, venueAddr, stable, last);
    }

    /// mode-2 (§G.3 redeem/swap-out extraction) settle in its OWN frame (no via_ir): the wider layout
    /// (2, lp, venue, stable, extractUsd, vault, minOut2); the extract body lives in LevMath (bytecode outside
    /// this contract). Extracted from onMorphoFlashLoan to stay within the legacy stack.
    function _extractSettle(uint256 assets, bytes calldata data) internal {
        (, address lp, address venueAddr, address stable, uint256 extractUsd, address vault, uint256 minOut2) =
            abi.decode(data, (uint8, address, address, address, uint256, address, uint256));
        (gasReserve, _lastFreed) = LevMath.extractToVaultBody(
            assets, lp, venueAddr, stable, extractUsd, vault, minOut2,
            _extractCfg(_isWethVenue(ILevVenue(venueAddr))));
    }

    /// mode-0 (generic flash-stable) settle in its OWN frame (no via_ir): repay-first → withdraw → sell → return the
    /// flash + surplus to the LP. Sell + keeper-gas peel run in LevMath (bytecode outside this contract).
    function _deleverSettle(uint256 assets, address lp, address venueAddr, address stable, uint256 last) internal {
        // repay-first → withdraw the freed collateral → sell → return the flash + surplus: body in LevMath (EIP-170).
        gasReserve = LevMath.deleverSettleBody(assets, lp, venueAddr, stable, last,
            AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW), _extractCfg(_isWethVenue(ILevVenue(venueAddr))));
    }

    /// @notice mode-1 (BOLD) callback: flashed `wethFlashed` WETH in hand. Mint `repayBold` BOLD at face value via
    ///         the venue's protocol trove, repay the LP's own trove with it, and settle the WETH flash — the LP
    ///         gets FULL fair equity and the protocol funds the Liquity over-collateralization from
    ///         `boldCloseReserve` (it becomes the protocol trove's own equity). Depth-independent at any size.
    /// @notice mode-1 (BOLD) callback: flashed `wethFlashed` WETH in hand. Mint `repayBold` BOLD at face value via
    ///         the venue's protocol trove, repay the LP's own trove with it, and settle the WETH flash — the LP
    ///         gets FULL fair equity and the protocol funds the Liquity over-collateralization from
    ///         `boldCloseReserve` (it becomes the protocol trove's own equity). Depth-independent at any size.
    /// @dev Thin forwarder: the fat body moved to `LevMath.onFlashMintBody` (public, delegatecall — bytecode OUTSIDE
    ///      this EIP-170-critical manager). Passes the runtime addresses + the two WETH reserves in via `FlashMintCfg`
    ///      and writes the updated reserves back here (value-type deltas). Logic unchanged.
    function _onFlashMint(uint256 wethFlashed, address lp, address venueAddr, address stable, uint256 repayBold)
        internal
    {
        (boldCloseReserve, gasReserve) = LevMath.onFlashMintBody(
            wethFlashed, lp, venueAddr, stable, repayBold,
            LevMath.FlashMintCfg({weth: WETH, aux: address(AUX), flashProvider: flashProvider,
                                  keeper: _activeKeeper, boldReserve: boldCloseReserve, gasReserve: gasReserve}));
    }

    /// The ETH sell/buy machinery lives in LevMath now (delegatecall, bytecode OUTSIDE this contract, so the
    /// manager fits EIP-170). This builds the context it needs: the manager's runtime addresses + the crank keeper
    /// + the live WETH gas-reserve (threaded in, returned updated).
    function _sellCtx(address keeper) internal view returns (LevMath.SellCtx memory) {
        return LevMath.SellCtx({ weth: WETH, weeth: address(WEETH), aux: address(AUX), keeper: keeper, reserveIn: gasReserve });
    }

    /// Lever-UP BUY (own frame, no via_ir): borrow `usd` stable, swap → collateral (LevMath.stableToColl), supply
    /// it to the venue for `who`. Shared by openLev's ladder + rebalance's up-leg (dedup).
    function _leverUpBuy(ILevVenue venue, address who, address stable, uint256 usd, uint256 minOut) internal {
        uint256 coll = LevMath.stableToColl(
            _sellCtx(address(0)), _isWethVenue(venue), stable, venue.borrow(who, LevMath._fromUsd(address(AUX),stable, usd)), minOut);
        IERC20Min(_collToken(venue)).transfer(address(venue), coll);
        venue.supply(who, coll);
    }

    // ════════════════════════ SELF-FUNDING KEEPER GAS (no operator subsidy) ════════════════════════
    /// WETH reserve covering a keeper's de-lever/protect gas when the freed value's own headroom can't (mirrors
    /// boldCloseReserve). Topped by the 1× surplus skimmed on ample de-levers + this permissionless protocol top-up.
    uint256 public gasReserve;
    function fundGasReserve(uint256 amount) external {
        if (amount == 0) return;
        IERC20Min(WETH).transferFrom(msg.sender, address(this), amount);
        gasReserve += amount;
    }
    /// The crank's msg.sender, stashed so the Morpho-flash callback (where value is freed) reimburses it. Transient
    /// ⇒ auto-clears at tx end; unset (0) on LP-only paths (closeLev / direct deleverOne) ⇒ no reimbursement.
    address private transient _activeKeeper;
    /// Reimburse `keeper`'s gas as native ETH from `availWeth` (freed WETH), shortfall from gasReserve, 1× top-up on
    /// ample headroom. Body in LevMath (delegatecall) so the manager fits EIP-170; runs in-context (the ETH is ours).
    function _reimburseKeeper(address keeper, uint256 availWeth) internal returns (uint256 skimmed) {
        (skimmed, gasReserve) = LevMath.reimburseKeeper(WETH, keeper, availWeth, gasReserve);
    }

    /// @dev ETH: weETH is rate-bearing, so native units need the ether.fi conversion.
    function _collNative(ILevVenue v, address lp) internal view override returns (uint) {
        return _collToEth(v, v.collateralOf(lp));   // weETH → ETH via the ether.fi rate, or WETH 1:1
    }
}
