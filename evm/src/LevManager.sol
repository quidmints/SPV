// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AlreadyOpen, NotFlash, Reentrancy, VenueNotAllowed, Types } from "./imports/Types.sol";
import { ILevVenue, IERC20Min, ILevPooled, IWeETH, IMorphoBase as IMorphoFlash } from "./imports/Interfaces.sol";
import {LevMath} from "./imports/LevMath.sol";
import {LevBase} from "./imports/LevBase.sol";
/// @notice The venue's collateral ERC20 — BOTH escrow adapters (Morpho/Euler) expose this public immutable,
///         so the manager DERIVES the collateral type per position (weETH vs WETH) from the venue itself,
///         never storing it on `Pos` (the public struct ABI stays a stable 6-tuple).


/// @notice weETH↔WETH legs of the leverage swap (stable↔WETH is routed through CURVE —
///         `LevMath._wethToStable` / `_hubSwap`; it was the basket SOR until 084bc5c).
///         UP: MINT weETH via the ether.fi adapter at the fair rate (zero-slippage; never the thin pool).
///         DOWN: SELL weETH → WETH on the deep v3 pool (`LevMath._weethToWethDex`, two tiers cheapest-first,
///         floored at `getEETHByWeETH` − `SELL_SLIP_BPS`). ⚠️ THE LEGS ARE NOT SYMMETRIC: the up-leg mints at
///         the fair rate, the down-leg pays pool slippage. The ether.fi instant-redeem that once made them
///         symmetric was REMOVED 2026-08-06 — it was unguarded, its capacity measured ZERO at every sampled
///         block over 90 days, and reaching it REVERTED THE WHOLE CALL rather than degrading (see
///         `LevMath._weethToWeth`). Do not re-describe this leg as deterministic-cost.
// IERC20Min + IWETH9 (WETH deposit/withdraw) now come from Interfaces.sol (§E296 folded
// ILevVenue.sol in; it was shared across the lev cluster). The
// ether.fi adapter/redeemer surfaces moved to LevMath with the sell/buy machinery.

/// @notice Morpho Blue flash-loan surface — FREE (zero-fee), so the ONLY flash source we use. The de-lever
///         path (`_deleverFlash`) flashes the venue stable, REPAYS the LP's debt FIRST, then withdraws the
///         freed collateral to sell — so the position's LTV only ever DROPS mid-operation. This DISSOLVES the
///         withdraw-before-repay hazard by construction (there is no health breach to clamp against), instead
///         of the old "withdraw only the health-safe slice and iterate" range-aid. One Morpho flash covers
///         BOTH Euler and Morpho positions (Morpho lends from its global stable liquidity, independent of
///         where the position lives), so a single pinned provider serves every venue.

/// @title  LevManager — the IL-protect: a per-LP, isolated, weETH-collateral leverage overlay
/// @notice Each LP's leverage is an ISOLATED position on an external `ILevVenue` (real Euler EVK or Morpho
///         Blue — see `MorphoEscrowVenue`). The COLLATERAL is **weETH** (staked, not lent ⇒
///         no rehypothecation; earns ether.fi yield while pledged). The loop borrows the venue stable, buys
///         weETH, supplies it, until LTV hits the live target = the range's SOLD FRACTION `1 − √(entry/now)`
///         (NOT the static `L=1/α` knob — see the `debtDeltaToTarget` comment), capped at 2× — so the leverage
///         only engages to cancel the IL the flow actually created. The keeper (`quid-bridge::lev_keeper`) holds LTV
///         in range via `rebalance` and proactively de-levers via `deleverOne`/`cascadeDelever` so the
///         venue's liquidation engine never fires; a position it can't save falls to the venue's OWN
///         isolated liquidation (that LP only, never the basket). No QUI is minted; nothing touches
///         `POOLED_USD`. (The old LEVERAGE-ENGINE-SPEC.md is gone; this file is the canonical design.)
contract LevManager is LevBase {
    // ── immutables ──
    // ether.fi weETH mint (up-leg only — the down-leg is the v3 pool; see the header). NOT our range.
    address   public immutable WETH;    // oracle key (getTWAPforAsset(WETH))

    // ── leverage range ──
    // QU!D policy ceiling on the LP's CHOSEN target LTV. 50% = 2× is the IL-NEUTRAL max (delta-1); above it is
    // opt-in DIRECTIONAL (long-biased) leverage — the LP's own risk, isolated at the venue (buffer USD ≤ debt,
    // deliverable excludes gross). 7500 = 75% LTV ≈ 4×. Conservative LPs still pass 5000 (2×). Tunable policy.
    // ⚠️ The "~11% headroom below the 86% venue LLTV" this comment used to assert is NOT read from anywhere —
    // the 0.86 is hardcoded three times over (this comment, the keeper's QUID_LEV_VENUE_LIQ_BPS env var, and
    // the test's own permissionless `createMarket`). Morpho Blue markets are IMMUTABLE, so a market's LLTV is
    // exactly knowable via `idToMarketParams(id).lltv` and should be READ, never configured. Until it is, the
    // headroom this constant leaves is an assumption, not a fact — see QUEUE.md OPEN 19.
    uint256 internal constant MAX_LOOPS          = 8;    // bound the open/rebalance loop
    /// Min collateral to OPEN — keeps the `_openLps` book (iterated in rangeETH on every deposit/withdraw/swap)
    /// from being Sybil-bloated by free zero-collateral opens (a gas-griefing DoS). ~0.05 weETH.

    /// @dev §E358 — this described `targetLtvCapBps` as "the LP's max-leverage LTV cap … 2× is the
    ///      IL-neutral value, higher is opt-in directional". That field is DELETED: IL-protect is a
    ///      protocol-wide liability, so no LP carries a debt-to-collateral ratio and there is no
    ///      per-LP directional opt-in to carry one. `TARGET_LTV_CAP_BPS` bounds the book.
    ///      `ilBasisPx` = ETH/USD at open: the IL target is `1 − √(ilBasisPx/pxNow)` = the ETH the
    ///      range has sold since entry (capped). Opens at ZERO leverage and grows only with the
    ///      realized move — proven in test/LevYbPnl.t.sol.
    /// ⚠️ `ilBasisPx` AND `entryEquity` ARE STILL PER-LP AND THAT IS THE REMAINING HALF. A
    ///      protocol-wide liability wants a protocol-wide IL BASIS too, and §C22 already found the
    ///      obvious candidate empty: the range-level `soldFractionWad(syncKeyPx)` is a CONSTANT
    ///      (~0.5008 = f(RANGE_DELTA)) because the range recentres on spot, so the price cancels.
    ///      Replacing per-LP entry pinning needs a real aggregate basis, which is design, not a
    ///      deletion — do not remove these two by symmetry with the cap.


    event RebalanceFailed(address indexed lp, uint256 ltvBps);  // batch rebalance skipped this LP (retried next tick)

    error NotGov();
    error Slippage();
    error LenMismatch();   // batch arrays differ in length (custom error — no string-revert bytecode, EIP-170)
    error Auth();          // rebalanceOne/deleverOne caller ∉ {self, lp}

    /// §RULE-8C — A MODIFIER'S BODY IS INLINED AT EVERY USE SITE, AND THIS ONE HAS **15**. The
    /// check-and-set half is now ONE routine (15 jumps instead of 15 copies); the release stays
    /// inline because it is a single `SSTORE` and a call would cost more than it saves.
    /// ⚠️ THE STRUCTURE IS DELIBERATELY UNCHANGED — `_;` still sits between enter and release, so
    /// every early return still releases the lock. Hoisting the RELEASE into a function would not.
    /// §RULE-8C, same reason: this exact line appeared **5** times.
    function _onlyRange() private view { if (msg.sender != RANGE) revert NotGov(); }

    /// @notice Governance — the ONLY party that can allow a venue. CRITICAL: a caller-supplied venue feeds
    ///         collateralOf/debtOf into `totalNetEquity → rangeETH`, so an UNVETTED (fake) venue could
    ///         inject arbitrary phantom ETH backing and drain real ETH-LP principal on redemption. Only the
    ///         deployed Euler/Morpho adapters may ever be allowed. Pinned at construction.
    mapping(address => bool) public allowedVenue;

    /// PIN-ONCE via `init` (below), then frozen (not rotatable) — matches the renounce-everything posture.

    /// @notice (B) Sold-fraction target activation. Default OFF ⇒ the PROVEN 1−√(entry/now) target stays
    ///         active. GOV flips it ON only AFTER the range-driven fork proof of the sold-fraction
    ///         IL-cancellation + the reseat re-anchor land — so the wiring ships without changing the proven
    ///         behavior or activating money-path math the oracle-mock unit tests cannot exercise.


    /// @notice The Morpho singleton used PURELY as a zero-fee flash source for `_deleverFlash` (repay-first
    ///         de-lever). Pin-ONCE then frozen — NOT a rotatable setter: set at deploy to the canonical
    ///         Morpho, then immutable in effect. A flash source can't inject phantom backing (unlike a
    ///         venue), but pin-once keeps it off the governance attack surface entirely, matching the
    ///         venue-allowlist / renounce-everything posture. 0 = unset (de-lever disabled until pinned).

    /// §E304-mintclose: a truncated docblock for the BOLD-close WETH reserve sat here and described the
    /// event below it. The reserve, the mint-close mode and their venue (Liquity V2, `c11cb40f`) are gone;
    /// the only WETH reserve left is `gasReserve`, which is keeper gas and documents itself.
    event FlashProviderSet(address provider);
    // flashProvider is pinned atomically alongside the range + venues in `init` (below).

    receive() external payable {}

    /// §J.2 — the public arity is UNCHANGED so no deploy site moves; everything it used to assign
    /// locally now lands on `LevBase`. `weeth` is passed twice on purpose: it is both the collateral
    /// AND its own rate source (`IWeETH(weETH).getEETHByWeETH`), which is exactly the fact the BTC
    /// side expresses by passing `address(0)` there.
    constructor(address weeth, address aux, address weth, address gov, address quid)
        LevBase(aux, weth, gov, quid, weeth, weeth, 0.05 ether) { WETH = weth; }

    /// @notice ONE-SHOT GOV config — pin-once, then FROZEN, atomic (no partial-config window). Wires together:
    ///         the range sync-range (`range` = Quid — closeLev re-syncs the fee slice + the RANGE-ONLY E0 source),
    ///         the zero-fee flash provider (`flash` = Morpho for repay-first de-lever; `address(0)` disables it),
    ///         and the audited venue allowlist (`venues`, then FROZEN). NOT rotatable — a rotatable allowlist is
    ///         the phantom-backing rug vector the freeze exists to prevent (GOV could add a fake venue → phantom
    ///         backing → drain); a new range/flash/venue ⇒ deploy a new LevManager. Consolidates the former
    ///         setQuidSyncRange/setFlashProvider/pinVenues (the manager↔venue circular dependency rules out a
    ///         constructor immutable). Matches BtcLevManager.init.
    function init(address range, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert VenueNotAllowed();
        venuesFrozen = true;
        RANGE = range;
        flashProvider = flash;
        emit FlashProviderSet(flash);
        for (uint i; i < venues.length; i++) {
            address v = venues[i];
            // COLLATERAL-SET gate: a LONG venue's collateral is custodied + valued by `_collToEth`, which
            // handles ONLY WETH (1:1) or weETH (rate) -- any other collateral silently misvalues into phantom ETH
            // backing (the rug the frozen allowlist stops). `LevMath.vetVenue` reverts an unvaluable one even for
            // GOV. (It also classifies a stable-collateral INVERSE venue as exempt — harmless if one is
            // allowlisted; the short subsystem that consumed it was removed, so the classification is unused.)
            // §INIT-VETVENUE — RETURN VALUE HONOURED, MIRRORING `BtcLevManager`. `vetVenue` returns
            // TRUE for a stable-collateral INVERSE venue mis-pinned as a long; discarding it allowlisted
            // exactly the collateral the comment above says "silently misvalues into phantom ETH
            // backing". Silent misvaluation is why the check earns its place (standing rule 3's inverse).
            if (LevMath.vetVenue(v, WETH, WETH, address(COLL))) revert VenueNotAllowed();
            allowedVenue[v] = true; emit VenueAllowed(v, true);
        }
    }

    // ════════════════════════════ COLLATERAL TYPE (weETH vs WETH) ════════════════════════════
    // The collateral type is DERIVED from the position's venue collateral token — never stored on `Pos`, so the
    // public struct ABI stays a stable 6-tuple. A WETH-collateral venue values 1:1 (WETH == ETH) and SKIPS the
    // ether.fi weETH<->WETH mint/redeem legs; every OTHER venue is the existing weETH path, byte-identical (the
    // weETH branch reduces to exactly what it did before this option existed).

    /// @notice ALL COLLATERAL IS weETH. `_isWethVenue` and the WETH-collateral branch it selected are
    ///         gone: raw WETH is STRICTLY DOMINATED — identical delta and identical IL offset, minus the
    ///         ether.fi ratchet (+2.46%/yr, measured) for every block it sits as collateral. It is a
    ///         worse way to buy the SAME hedge, not a different hedge, so there was never a reason to
    ///         select it. The last WETH-collateral market left the allowlist with the USDC venues.
    ///         ⚠️ Anything bought as WETH is minted straight into weETH (`LevMath._stableToWeeth`);
    ///         WETH is a TRANSIT asset here and never rests as collateral.
    function _collToken(ILevVenue) internal view returns (address) {
        return address(COLL);
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


    /// @notice LIVE sum of every open position's deliverableDollars — the aggregate #67 counts as available USD
    ///         backing in the range-pairing sizer (sizeBySurplus addend). Reads the oracle ONCE (price-consistent).




    /// @notice `lp`'s net equity in USD (1e18) = collateral − debt, floored at 0. The single clean read the
    ///         off-chain keeper uses to size the economic (gas-vs-benefit) floor.
    /// @notice §FOLD-COLL — THE ETH SIDE'S ENTIRE PER-ASSET CONTRIBUTION TO THE VALUATION STACK.
    ///         weETH units → ETH, at the ether.fi rate. Everything built on it (`collValueUsd`,
    ///         `_collNative`, `debtUsd`, `getCurrentLtvBps`, `ilLtvBps`, `ilTargetLtvBps`) is shared
    ///         in `LevBase`; this three-line override is what used to justify seven duplicated
    ///         functions. Was `_collToEth(ILevVenue, uint)` whose venue parameter was never read.

    function netEquityUsd(address lp) public view returns (uint256) {
        if (!pos[lp].open) return 0;
        ILevVenue v = pos[lp].venue;
        uint256 coll = collValueUsd(v.collateralOf(lp));   // §FOLD-COLL — shared in LevBase
        uint256 d = debtUsd(lp);
        return coll > d ? coll - d : 0;
    }




    /// §PROTECT-FOLD — the two per-asset facts the shared `protectFromQuid` needs.

    /// §PROTECT-FOLD — the guard is here (this contract owns `_lock`); the body is in `LevBase`.
    function protectFromQuid(address lp, uint256 minStableOut) external nonReentrant returns (uint256) {
        return _protectFromQuidBody(lp, minStableOut);
    }
    /// The refund is stable (no WETH to peel), so the keeper's gas comes from the reserve.
    function _afterProtect(address keeper) internal override { _reimburseKeeper(keeper, 0); }

    /// @notice Stable delta (USD, 1e18) + direction to re-hit target LTV. Inside the range ⇒ (false,0).
    ///         Reads the oracle ONCE (price-consistent — avoids the getTWAPforAsset-mutates-mid-call flip).


    // ════════════════════════════ OPEN ════════════════════════════

    /// @notice Open an isolated leveraged position. The LP supplies `collWeeth` weETH (approved here) as
    ///         equity, and that is ALL an open does — it takes NO debt and performs NO swap.
    ///         §E358 — the LP names NO leverage cap: IL-protect is a protocol-wide liability, so the
    ///         single `TARGET_LTV_CAP_BPS` bounds the whole book and leverage is taken later by
    ///         `rebalance` as the range actually sells. §E357 — this said "the loop borrows … until LTV
    ///         reaches `targetLtvBps`" and described a ladder that could never run.
    function openLev(ILevVenue venue, uint256 collWeeth)
        external nonReentrant
    {
        if (pos[msg.sender].open) revert AlreadyOpen();
        // venue must be on the frozen allowlist AND not incident-flagged (GOV setVaultHealth) -- fresh
        // collateral must never land on an unvetted or broken market. Reverts live in LevMath (off this EIP-170-
        // critical manager). Only OPEN is gated: close/rebalance stay open so the keeper can unwind OUT of a block.
        LevMath.requireOpenable(allowedVenue[address(venue)], address(AUX), address(venue));
        if (collWeeth < MIN_OPEN) revert BadTarget();           // anti-Sybil: no free zero-collateral book entries
        // §DERIVED-BAND — the floor is the position's OWN band, so it is priced off the collateral
        // actually being deposited rather than a constant every position shared.
        // Pin the entry price so the position opens at ZERO leverage and levers only as the range sells.
        uint256 entryPx = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        // (A) INTRINSIC deposit model (2026-07-03): the LP's ONE deposit (`collWeeth`) IS the levered position.
        // Its net-equity is synced into the concentrated range (`levPooled`) as delta-1 (IL-free) depth by the 2×
        // leverage — so E0, the FIXED IL base the hedge sizes against, is the DEPOSIT ITSELF (in ETH), NOT a
        // separate unlevered range position. LEVERAGE-INVARIANT (the over-hedge fix): the collateral grows as the keeper
        // levers, but E0 does not, so `targetDebt = E0·soldFrac` cancels the range's IL exactly instead of chasing a
        // 1/(1−t) fixed point. ⚠️ E0 IS NOT FIXED AT OPEN — `_reanchorIfReseated` re-bases it to `netEquity(lp)`
        // (RangeLib.reanchorIfReseated) whenever the range reseats. That is SAFE and is the actual invariant: levering moves
        // collateral and debt by the SAME amount, so net equity is LEVERAGE-INVARIANT. Sizing against GROSS
        // collateral is what re-opens the over-hedge; any future base must be leverage-invariant, not "fixed". (Unlike
        // the old (B) two-pool model, there is no separate deliverable principal range — that isolation is traded
        // for capital efficiency; the whole deposit is levered.) SAFETY:
        // the up-side-only clamp de-levers this toward 0 debt below entry, so the deposit is never held at 2× into
        // a crash. `syncKeyPx` still tracks the range for the sold-fraction reference.
        uint256 entryEquity = _collToBase(collWeeth);   // (A) the deposit (weETH->ETH rate, or WETH 1:1) is the IL base
        // §FOLD-OPEN — range-price read + Pos literal + book enrolment are `LevBase._openPos`, shared
        // with the BTC side. Only `entryEquity` above is per-asset.
        _openPos(venue, entryPx, entryEquity);   // joins the book the Vault sums net-equity over

        // 1. Pull equity collateral (weETH OR WETH, per the venue) and supply as isolated collateral.
        _supplyCollFrom(venue, msg.sender, collWeeth);

        // §E357 — **THE LEVER-UP LADDER IS DELETED, AND IT WAS UNREACHABLE BY CONSTRUCTION.**
        // `_openPos` pins `ilBasisPx = entryPx`, and `debtDeltaToTarget` immediately re-reads the
        // SAME TWAP — so `pxNow <= ilBasisPx`, `ilTargetBps` returns 0, and `debtDelta` answers
        // `(false, 0)`. The loop broke on `i == 0` on EVERY path, always. That is not an accident of
        // arguments; it is the design the next comment already states — an open is at ZERO leverage,
        // and a ladder that runs once the target has moved is `rebalance`, which is where it lives.
        // ⇒ `minWethOut` and the routes array went with it: both existed ONLY to feed rungs that
        // never execute. Rule 1, and it is why this signature got SIMPLER while every other
        // entrypoint gained a route.
        // No MIN-debt floor: the corrected design opens at ZERO leverage (IL target = 0 at entry) and levers
        // up only as the range sells. The MAX bound is the per-position LTV cap (≤ 7500 bps ≈ 4×), enforced by the target.
        emit Opened(msg.sender, address(venue), TARGET_LTV_CAP_BPS);
    }

    /// @notice Adjust the caller's max-leverage CAP (bps LTV, ≤ TARGET_LTV_CAP_BPS = 7500 ≈ 4×). The live IL target = the range's sold
    ///         fraction `1 − √(entry/now)` and is auto-computed each tick, never exceeding this cap. Permissioned
    ///         to the LP because the cap is a risk choice — `rebalance` toward the target stays permissionless.
    // ════════════════════════════ REBALANCE (keeper, up-side overlay) ════════════════════════════

    /// @notice Hold `lp`'s LTV inside the range. levUp: borrow→buy-weETH→supply. levDown (the
    ///         liquidation-avoidance): withdraw weETH→sell→repay. `minOut` bounds the single swap this call
    ///         performs (off-chain quoted by the keeper). Permissionless: only moves toward target.
    /// PERMISSIONLESS single-LP rebalance toward the IL target. Sets `_activeKeeper` so the flash reimburses the caller.
    /// @param dex the volatile leg's router calldata. §E357 — REQUIRED, and its absence is why
    ///        this entrypoint could not work at all: `_aggSwap` refuses an empty route and this
    ///        passed one, so every keeper rebalance reverted `NoVolatileRoute()` no matter what
    ///        credential existed anywhere. The keeper computes it off-chain (an aggregator quote, or
    ///        our own pool reads over multicall); the DESTINATION remains the pinned
    ///        `ONEINCH_ROUTER`, so what arrives here is a PATH, never an address.
    function rebalance(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) external nonReentrant {
        _activeKeeper = msg.sender;
        _rebalance(lp, minOut, dex, dex2, route);
    }

    /// @notice BATCH rebalance — hold every out-of-range LP at its IL target in ONE tx (mirrors `cascadeDelever`),
    ///         FAULT-TOLERANT: an LP whose rebalance reverts is SKIPPED (emit `RebalanceFailed`) and the loop
    ///         continues. PERMISSIONLESS + only moves toward target. Lets the keeper fire ONE tx for the whole book
    ///         instead of N per-LP txs — the central-rebalancer path.
    /// @param dexes ONE PER LP, positionally. ⚠️ **A BATCH CANNOT SHARE A SINGLE ROUTE.** A route is
    ///        quoted for an AMOUNT, and each position swaps its own size, so one route reused across
    ///        the book would under- or over-shoot every LP but the one it was quoted for — and the
    ///        oracle floor would then revert those legs rather than mis-price them, turning a batch
    ///        into a single success and N `RebalanceFailed` events.
    /// @dev ⚠️ THE BATCH PATH KEEPS THREE ARRAYS ON PURPOSE. A fourth would mean extending the keeper's
    ///      shared `encode_batch` helper, which is a wider change than this one — so the per-LP
    ///      entrypoints carry the new hub word and the batch falls back to the legacy Curve hub hop
    ///      (`hubDex = 0`), which IS today's behaviour. **Extend this the same way when the batch
    ///      encoder moves; until then a batch cannot route a stable the old table does not cover.**
    function rebalanceMany(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes) external nonReentrant {
        _batch(lps, minOuts, dexes, false);
    }

    /// @dev §RULE-8C, APPLIED TO A BODY RATHER THAN A MODIFIER. `find-duplicate-bodies.py` scores
    ///      `rebalanceMany` and `cascadeDelever` at **86.5%** — they differed only in which
    ///      `this.X(...)` they called and which event they emitted, while both carried their own
    ///      copy of the length triple-check, the `_activeKeeper` write, the loop scaffolding and the
    ///      `pos[lp].open` read. One routine and two jumps instead of two inlined copies, which is
    ///      the same trade that gave this contract back 440 bytes when `nonReentrant`'s body was
    ///      hoisted out of 15 sites.
    /// ⚠️ BOTH EXTERNAL ENTRYPOINTS STAY. They are pinned in the keeper's validating-signer
    ///      allowlist, and merging them into one selector with a flag would widen what that hot key
    ///      can sign — a de-lever and a rebalance are not the same authority.
    /// ⚠️ THE TWO `try/catch` ARMS ARE THE IRREDUCIBLE DIFFERENCE and are deliberately NOT collapsed
    ///      behind one event: `RebalanceFailed` and `DeleverFailed` are separate signals the indexer
    ///      reads, and folding them would trade bytecode for a blind spot in exactly the path that
    ///      only speaks when something has gone wrong.
    /// @param delever true ⇒ the cascade (de-lever) arm; false ⇒ the IL-target rebalance arm.
    function _batch(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes, bool delever)
        private
    {
        if (lps.length != minOuts.length || lps.length != dexes.length) revert LenMismatch();
        // Set ONCE for the batch (transient): each inner call's flash reads it to reimburse gas.
        _activeKeeper = msg.sender;
        for (uint256 i; i < lps.length; i++) {
            address lp = lps[i];
            if (!pos[lp].open) continue;
            if (delever) {
                try this.deleverOne(lp, minOuts[i], dexes[i]) {}
                catch { emit DeleverFailed(lp, getCurrentLtvBps(lp)); }
            } else {
                try this.rebalanceOne(lp, minOuts[i], dexes[i], 0, "") {}   // 0 ⇒ legacy hub hop (see rebalanceMany)
                catch { emit RebalanceFailed(lp, getCurrentLtvBps(lp)); }
            }
        }
    }

    /// @notice The atomic unit of the batch; `external` so `rebalanceMany` can try/catch it. Self/LP ONLY — the
    ///         permissionless entries are `rebalance`/`rebalanceMany`. NO `nonReentrant` (the entrypoint holds the
    ///         guard); `_activeKeeper` is set by that entrypoint before the loop, so the flash-callback
    ///         reimbursement still targets the real keeper.
    function rebalanceOne(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) external {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        _rebalance(lp, minOut, dex, dex2, route);
    }

    /// @dev ⚠️ **THE LEVER-UP LEG NEEDS A ROUTE TOO, AND `§ROUTE-BLOCKED-24` DID NOT NAME THAT HALF.**
    ///      `_leverUpBuy` reaches `_stableToWethSor` → `_aggSwap` (stable→WETH), so a rebalance that
    ///      levers UP reverted on an empty route exactly as a de-lever did. Reading the row as a
    ///      de-lever problem would have fixed half the entrypoint and left the other half dead.
    function _leverUp(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override { _leverUpBuy(venue, lp, stable, deltaUsd, minOut, dex, dex2, route); }

    /// @dev IGNORES `deltaUsd` deliberately: `deleverRepayUsd` is the closed-form `Δ/(1−t)`, so ONE
    ///      flash lands on target with no withdraw-before-repay health breach.
    function _delever(ILevVenue venue, address lp, address stable, uint256, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override { _deleverFlash(venue, lp, stable, deleverRepayUsd(lp), minOut, dex); }

    // ════════════════════════════ CASCADE DE-LEVER (the correlated-crash path) ════════════════════════════

    /// @notice De-lever ONE position toward target (down-leg only). The atomic unit of the cascade;
    ///         `external` so `cascadeDelever` can try/catch it. Callable by the contract itself (cascade) or
    ///         the LP. Iterates to within range (one chunk only gets close — selling weETH reflexively nudges
    ///         the range mark + slippage leave headroom — so re-solve on the new mark and chip again,
    ///         bounded by MAX_LOOPS; a no-progress chunk breaks early so a stuck position never spins).
    /// @dev NO `nonReentrant` BY DESIGN: `cascadeDelever` (which holds the guard) calls this via `this.deleverOne`,
    ///      so a guard here would revert the whole cascade. Safe without it — caller is self or the LP only, and
    ///      every token leg uses ACTUAL balance deltas (no nominal trust), so a re-entry can't mis-account.
    /// @notice §E357 — ONE entrypoint, and it carries the route. The un-routed
    ///         `deleverOne(address,uint256)` and its `deleverOneRouted` twin are FOLDED INTO THIS.
    /// @dev ⛔ **THE TWIN EXISTED ON A PREMISE THAT WAS ALREADY FALSE, AND BOTH ITS CLAUSES WERE
    ///      WRONG.** It said: *"A SEPARATE ENTRYPOINT, NOT AN EXTRA PARAMETER ON `deleverOne`.
    ///      `deleverOne(address,uint256)` is pinned in the validating signer's allowlist
    ///      (`evm_validating_signer.rs`)… `route` empty ⇒ identical behaviour to `deleverOne`
    ///      (V3 fallback)."*
    ///        · **`deleverOne` is NOT in that allowlist** — checked; it pins `cascadeDelever` and
    ///          `rebalanceMany` and nothing else — so the compatibility it was protecting was
    ///          imaginary, and the cost of the split was a real duplicate entrypoint.
    ///        · **There is no V3 fallback.** §C2.1 removed it, so an empty route stopped being
    ///          "identical behaviour" and became `NoVolatileRoute()`. The un-routed twin was not a
    ///          gentler default; it was the one that could never work.
    ///      ⇒ Two entrypoints for one action, one of which always reverts, is the fallback the owner
    ///      ruled out. There is now one, and it fails closed.
    function deleverOne(address lp, uint256 minOut, uint256 dex) external {
        _deleverOne(lp, minOut, dex);
    }

    function _deleverOne(address lp, uint256 minOut, uint256 dex) internal {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        Types.Pos memory p = pos[lp];
        if (!p.open) return;
        uint256 repayUsd = deleverRepayUsd(lp);                                 // Δ/(1−t), 0 if inside range
        if (repayUsd == 0) return;                                              // inside range → done
        uint256 debtBefore = p.venue.debtOf(lp);
        // ONE flash-repay-first shot reaches target (no health breach, any depth). If the position is
        // genuinely underwater/illiquid the flash can't be repaid → the whole op reverts → `cascadeDelever`
        // catches it and the position falls to the venue's own isolated liquidation.
        _deleverFlash(p.venue, lp, p.venue.stable(), repayUsd, minOut, dex);
        require(p.venue.debtOf(lp) < debtBefore, "delever: no liquidity");      // sourced nothing → cascade skips it
        emit Rebalanced(lp, false, 0, getCurrentLtvBps(lp));
        // full-2×: reconcile the range to the reduced gross/debt (levBufferUsd must not exceed the now-smaller
        // debt) — atomic, so the ≤Σdebt invariant holds continuously even mid-cascade. try/catch: never break it.
        _syncRange(lp);
    }

    /// @notice SYSTEMIC cascade de-lever — the correlated-crash path. De-levers a batch in ONE tx,
    ///         FAULT-TOLERANT: a position whose de-lever can't source liquidity is SKIPPED (emit
    ///         `DeleverFailed`) and the loop continues — one stuck LP can NEVER block the rest; it falls to
    ///         its venue's OWN isolated liquidation. PERMISSIONLESS + only moves toward target.
    /// @param dexes one per LP, positionally — see `rebalanceMany` for why a batch cannot share one.
    /// ⚠️ **THIS SIGNATURE IS PINNED IN `quid-bridge/src/evm_validating_signer.rs`'s ALLOWLIST** and
    ///    must move with it in the same commit, or the keeper's own signer refuses to sign the call
    ///    it is built to send.
    function cascadeDelever(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes) external nonReentrant {
        _batch(lps, minOuts, dexes, true);
    }

    // ════════════════════════════ CLOSE ════════════════════════════

    /// @notice Fully unwind `lp`'s position: repay all debt by selling collateral, return the remaining
    ///         weETH to the LP. Loop-bounded. `minOut` bounds each weETH→stable swap. LP-only.
    /// @param dex the volatile leg's router calldata — a close sells collateral back to the loan
    ///        token, so it swaps exactly as a de-lever does and was equally unable to execute.
    function closeLev(uint256 minOut, uint256 dex) external nonReentrant {
        _closeLev(msg.sender, minOut, false, dex);   // LP chose to exit -- nothing to restore, drop the slot
    }

    /// @notice Permissioned force-close of `lp`'s lever ON THEIR BEHALF — the §4.2 cover-lever entry
    ///         (docs/actionable/JIT-DEPTH-GUARANTEE.md). Callable ONLY by the GOV-pinned `RANGE`
    ///         (the ETH range — so a `Quid._withdraw` can cover an open lever before the free-ladder burn) — NO
    ///         GOV force-close (no live governance authority). SEPARATE trusted-caller path, so the LP-only
    ///         `closeLev` msg.sender gate is left intact (NOT
    ///         weakened). Same unwind mechanics as `closeLev` (flash-repay-FIRST → return the collateral to `lp`);
    ///         `minOut` bounds each collateral→stable swap. Backing-safe by construction: it only ever repays
    ///         `lp`'s OWN debt and hands `lp`'s OWN freed collateral back to `lp`, so a hostile range can neither
    ///         extract value nor redirect it — at worst it forces a close the LP could do themselves.
    ///         `nonReentrant`: the tail `syncLev` range call-back is already try/catch-wrapped, so a re-entrant
    ///         range context degrades to the permissionless slice reconcile.
    /// ⚠️ **NO `dex` PARAMETER, DELIBERATELY.** `_onlyRange()` means the sole caller is the range,
    ///    and the range has no route to supply — see `LevBase.rangeUnwindDex`. A parameter with no
    ///    possible supplier is API surface that can only ever be passed `0`; taking the venue from
    ///    the pinned slot instead keeps `ILevClose`'s two-argument signature intact.
    function closeLevFor(address lp, uint256 minOut) external nonReentrant {
        _onlyRange();
        _closeLev(lp, minOut, true, _unwindDex());   // INVOLUNTARY -- retain state so the LP can be restored
    }

    /// @dev Shared close body — parameterized by `lp` so the LP-only `closeLev` and the permissioned
    ///      `closeLevFor` reuse ONE implementation (no duplicated flash/withdraw/short-unwind logic). Verbatim of
    ///      the prior in-line `closeLev` body; only `lp` moved from a local (`msg.sender`) to a parameter.
    function _closeLev(address lp, uint256 minOut, bool keepState, uint256 dex) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) revert NotOpen();
        ILevVenue venue = p.venue;
        address stable = venue.stable();

        // Repay ALL debt in ONE flash-repay-first shot (repay → withdraw the freed collateral → sell → return
        // the flash), then hand back the remaining collateral. Repaying FIRST means the withdraw never
        // breaches health — dissolving the withdraw-before-repay bug the real-Euler close test surfaced,
        // with no per-pass health-safe clamp or loop. A truly underwater position can't cover the flash, so
        // this reverts and the position falls to the venue's isolated liquidation (as it should).
        // §DUST-BLOCKS-THE-LAST-EXIT — ACCRUE BEFORE SIZING, not just before repaying. `debtUsd`
        // reads `MORPHO.market(...)` raw, so with interest pending it UNDER-REPORTS and the flash
        // below is borrowed short of what the position actually owes — the repay then cannot clear
        // it no matter how it is denominated. Accruing here makes every read in this transaction,
        // and the venue's own repay, agree on one market state.
        venue.accrue();
        uint256 d = debtUsd(lp);
        if (d > 0) _deleverFlash(venue, lp, stable, d, minOut, dex);
        uint256 remaining = venue.collateralOf(lp);
        uint256 back = remaining > 0 ? venue.withdraw(lp, remaining) : 0;
        if (back > 0) IERC20Min(_collToken(venue)).transfer(lp, back); // weETH OR WETH, per the venue (incl. rebuilt short base)
        // A voluntary close DROPS the slot. An involuntary one (closeLevFor, the range covering a lever
        // before its free-ladder burn) RETAINS every field with open=false, because the LP did not choose to
        // exit and must be restorable to the same position after the refill. Safe only because ilLtvBps,
        // ilTargetLtvBps and debtDeltaToTarget now gate on .open -- before that, a retained Pos made
        // debtDeltaToTarget report "lever up" on a closed position.
        if (keepState) p.open = false; else delete pos[lp];
        _untrackOpen(lp);          // leave the book — net-equity contribution drops to 0
        // Burn the LP's levered range slice NOW (net-equity is 0 post-delete) so it can't keep earning range
        // fees on vanished backing. Non-fatal: the slice is also reconcilable permissionlessly via syncLev.
        _syncRange(lp);
        emit Closed(lp, back);
    }

    /// @notice The stable (USD 1e18) that must be REPAID to bring `lp` to target LTV. De-levering sells
    ///         collateral too, so the naive `curDebt−targetDebt` UNDERSHOOTS (that's exactly why the old
    ///         chunked path had to loop); the closed form that lands ON target is `Δ/(1−t)`. Zero when the
    ///         position is inside the de-lever range (or below target). One consistent oracle read.
    function deleverRepayUsd(address lp) internal view returns (uint256) {
        (bool open, uint256 e0, uint256 debtNow, uint256 target) = _targetInputs(lp);
        if (!open) return 0;
        // (Self-funded short holds stable collateral, not debt, so the keeper de-lever no longer needs to be gated
        // on an open short — below entry the long debt is 0, so de-lever is a natural no-op there anyway.)
        // Compare-math folded to LevMath.deleverRepay: on the FIXED E0 the repay is simply curDebt − targetDebt
        // (no Δ/(1−t) inflation — that was only needed when the target tracked the shrinking collateral).
        return LevMath.deleverRepay(e0, debtNow, target, _bandFor(lp, e0));
    }

    // ════════════════════════════ DE-LEVER — flash-repay-FIRST (no health breach by construction) ══════════

    /// @notice De-lever `lp` toward target by repaying `repayUsd` (USD 1e18) via a Morpho flash loan that
    ///         REPAYS the debt FIRST, then withdraws the freed collateral to sell. Because the repay precedes
    ///         the withdraw, the LTV only ever DROPS during the op — a health-gated venue can NEVER revert on
    ///         a "withdraw breaches health" (the bug the old withdraw-then-repay chunk hit near liquidation).
    ///         Atomic and single-shot at any depth. Shared by rebalance-down, deleverOne, and close.
    function _deleverFlash(ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 dex) internal {
        // repay-first flash (mode 0) — the ONLY mode this path emits; body in LevMath
        // (delegatecall — bytecode OUTSIDE this contract). The flash re-enters this manager's own onMorphoFlashLoan.
        LevMath.deleverFlashBody(_extractCfg(), venue, lp, stable, repayUsd, minOut, dex);
    }

    /// Transient handoff for the mode-2 (`deleverToVault`) callback's freed-stable result. Auto-clears at tx end.
    uint256 private transient _lastFreed;

    /// The manager's runtime addresses + gas-reserve for the mode-2 extraction body (delegatecall → LevMath).
    function _extractCfg() internal view returns (LevMath.ExtractCfg memory) {
        return LevMath.ExtractCfg({ weth: WETH, weeth: address(COLL), aux: address(AUX),
            flashProvider: flashProvider, keeper: _activeKeeper, gasReserve: gasReserve,
            maxSlippageBps: uint16(MAX_SLIPPAGE_BPS), dex: 0, dex2: 0 });
    }

    /// @notice §G.3 REDEEM/SWAP-OUT value-neutral extraction: free up to `extractUsd` (USD 1e18) of THIS LP's
    ///         in-range levered net-equity to `vault` (the redeem sink) via a flash-repay-FIRST partial de-lever
    ///         that PRESERVES LTV — repay ΔD=`extractUsd`·debt/netEq, withdraw+sell the paired collateral, surplus
    ///         → `vault`. Gated to the range (`RANGE`, the redeem/swap-out settle path) — NEVER
    ///         permissionless (it routes value OUT). Bounded by the #67 `deliverableDollars` (never past the liq
    ///         threshold). The LP's residual position stays OPEN (unlike `closeLev`); `syncLev` reconciles the
    ///         shrunk net-equity range slice. Uniform over YB + directional (both in-range); the YB-vs-directional
    ///         settlement is on the LP's untouched residual, not here. Returns the stable actually routed to `vault`.
    function deleverToVault(address lp, uint256 extractUsd, address vault, uint256 minOut)
        external returns (uint256 freed)     // NOT nonReentrant: the outer deleverBook (or the range's redeem lock) holds it — mirrors deleverOne
    {
        if (msg.sender != RANGE && msg.sender != address(this)) revert NotGov(); // range settle OR deleverBook self-call
        Types.Pos memory p = pos[lp];
        if (!p.open || extractUsd == 0 || flashProvider == address(0)) return 0;
        uint256 cap = deliverableDollars(lp);  // value-neutral bound (≤ liq threshold)
        
        if (extractUsd > cap) extractUsd = cap;
        if (extractUsd == 0) return 0;
        
        uint256 repayStable = LevMath.sizeRepayStable(// d/netEq/clamp in LevMath 
            p.venue, lp, extractUsd, debtUsd(lp), AUX.getTWAPforAsset(ORACLE_KEY, 
                                    TWAP_WINDOW), address(COLL), address(AUX));
        if (repayStable == 0) return 0;

        // mode 2 = flash the debt stable → repay-first → withdraw+sell paired collateral → surplus to `vault`.
        IMorphoFlash(flashProvider).flashLoan(p.venue.stable(), repayStable,
            abi.encode(uint8(2), lp, address(p.venue), 
            p.venue.stable(), extractUsd, vault, minOut));

        freed = _lastFreed; _lastFreed = 0;
        // Reconcile the shrunk net-equity into the range slice (try/catch: never block the settle).
        _syncRange(lp);
    }

    /// @notice §M.1 #54-ETH funding quote: for `lp`, the venue stable + the EXACT native amount the Vault must
    ///         pre-fund to the venue to de-lever up to `maxUsd18` of debt (clamped to LIVE debt so no stray stable
    ///         strands on the adapter — `swapOutDelever` repays exactly this, recomputing the same clamp). View.
    ///         IDENTICAL shape to `BtcLevManager.swapOutDeleverAmt` (the ETH swap-out mirror of #54).

    /// @notice §M.1 UNLEVERED (0-debt) net-equity delivery — the HODL slice below entry where the keeper has
    ///         de-levered target debt → 0. `swapOutDelever` no-ops here (nothing to repay), which would leave the
    ///         unlevered net-equity PHANTOM (priced in POOLED, undeliverable because its collateral sits in the
    ///         lev venue, not the base 4626). This delivers it. NO repay / NO `takeToSettle` (no debt) ⇒ NO basket-
    ///         stable draw ⇒ NO backing hazard: withdraw up to `wethWanted`-worth of the net-equity collateral and
    ///         deliver it as WETH. The V4 curve already did the ETH→USD rebalance for the LP's range slice; `syncLev`
    ///         reconciles the shrunk net-equity; the keeper re-levers next tick. Gated to the range.
    function swapOutDeliverUnlevered(address lp, uint256 wethWanted, address recipient, uint256 minWethOut)
        external nonReentrant returns (uint256 wethDelivered) {
        _onlyRange();          // range settle path only
        Types.Pos memory p = pos[lp];
        if (!p.open || wethWanted == 0) return 0;
        if (p.venue.debtOf(lp) != 0) return 0;                     // levered ⇒ use swapOutDelever (repay path)
        // withdraw net-equity collateral + MEV-floor + deliver-as-WETH: body in LevMath (delegatecall, EIP-170).
        wethDelivered = LevMath.swapOutDeliverUnleveredBody(p.venue, lp, wethWanted, recipient, minWethOut, _extractCfg());
        _syncRange(lp);
    }

    // §J2-LEV-ARITY RESOLVED BY DELETION — **the ETH `swapOutDelever(lp, uint, address, uint)` is
    // GONE, and with it the overload that blocked merging the two managers.** CLAUDE.md recorded the
    // arity split as the blocker: BTC's is `(address,uint,uint)` and ETH's was
    // `(address,uint,address,uint)`, so one contract could not carry both without an overload — which
    // the `ICurvePool` note forbids (integer-literal inference picking the wrong ABI).
    // ⇒ IT DID NOT NEED RECONCILING, IT NEEDED DELETING. §POOL-VENUE superseded it with
    //   `swapOutDeleverPooled(venue, …)`, which is self-contained (`repayPool` → `withdrawPool` →
    //   `collToWethDeliver`) and is what `SwapLib:2127` actually calls. The per-LP form had ZERO
    //   callers: the only two `swapOutDelever(` sites in the tree are `SwapLib:2021`/`:2042`, both
    //   using the 3-arg BTC form via `ILevManagerDeliver` inside `_sourceRepayFree` — the BTC
    //   swap-out path (channel BTC, splice-proven, vBTC debt). The remaining mentions are comments.
    // ⇒ Only the BTC 3-arg signature survives, so `Vogue` can carry one `swapOutDelever` and no
    //   overload exists to disambiguate.

    /// @notice §POOL-VENUE — THE ONE-CALL DELIVERY-SIDE DE-LEVER. This is what SPRINT #1 exists for.
    ///
    /// ⛔ WHAT IT REPLACES, AND WHY THE OLD SHAPE HAD A CEILING: `SwapLib.deleverEthOnDelivery` walked
    /// the open-lev book and repaid EACH LP's own Morpho position, because a repay cannot be aggregated
    /// across N `onBehalf` accounts. Every iteration was a basket draw plus a venue repay, the loop ran
    /// `while deliveredEth < shortfallEth`, so **swap size was capped by how many LP repays fit in a
    /// block, and the cap TIGHTENED AS THE BOOK GREW** (§E342). One position makes it two calls whose
    /// size is bounded by stable liquidity instead.
    ///
    /// @dev THE PAIR IS THE INVARIANT. `repayPool` lowers the pool's debt; `withdrawPool` frees the
    ///      collateral that repayment un-encumbers. Doing the second without the first RAISES the pool's
    ///      LTV toward a liquidation threshold that Morpho no longer enforces per-LP — see the
    ///      §POOL-VENUE header. They are ordered repay-FIRST here for the same reason the per-LP path
    ///      was: LTV may only ever fall mid-operation.
    /// @dev VALUE-NEUTRAL PER LP, BY CONSTRUCTION RATHER THAN BY BOOKKEEPING. Neither call writes a
    ///      per-LP slot: both sides are UNITS of the pool, so the repay lowers every LP's debt in
    ///      proportion and the withdraw lowers every LP's collateral in the same proportion. That is
    ///      what makes this O(1) and what makes it fair — the two effects cancel per LP.
    /// ⚠️   NOT venue-agnostic, deliberately. `ILevPooled` is cast, not added to `ILevVenue`, because
    ///      `AaveV3Venue` (the WBTC leg) is still per-LP escrowed. A venue that is not pooled must fail
    ///      loudly here, not silently do something else.
    /// @param stableUsd USD 1e18 the range pre-transferred to the venue for the repay.
    /// @return usedUsd USD actually applied to the pool's debt. @return wethDelivered WETH to `recipient`.
    function swapOutDeleverPooled(address venue, uint256 stableUsd, address recipient, uint256 minWethOut)
        external nonReentrant returns (uint256 usedUsd, uint256 wethDelivered) {
        _onlyRange();
        if (stableUsd == 0) return (0, 0);
        address stable = ILevVenue(venue).stable();
        uint256 repaid = ILevPooled(venue).repayPool(LevMath._fromUsd(address(AUX), stable, stableUsd));
        if (repaid == 0) return (0, 0);
        usedUsd = LevMath._toUsd18(address(AUX), stable, repaid);
        // Free exactly the repaid VALUE of collateral: USD -> ETH at the anchor, ETH -> weETH at the
        // ether.fi rate. `getWeETHByeETH` is the inverse of the `getEETHByWeETH` every valuation here
        // uses, so the round trip cannot drift the two apart.
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        if (px == 0) return (usedUsd, 0);          // no anchor: repay stands, deliver nothing (never divide by 0)
        uint256 freeWeeth = IWeETH(address(COLL)).getWeETHByeETH((usedUsd * 1e18) / px);
        uint256 got = ILevPooled(venue).withdrawPool(freeWeeth);
        if (got > 0) wethDelivered = LevMath.collToWethDeliver(got, recipient, minWethOut, _extractCfg());
    }

    /// @notice §G.3/§G.6 REACTIVE de-lever sweep — the ONE mechanism the redeem AND swap-out settle paths share
    ///         (the keeper's `cascadeDelever` is the PROACTIVE half; it stays distinct because its per-LP intent is
    ///         restore-to-target, not extract-to-sink). Walks the open-lever book (this manager OWNS `_openLps`, so
    ///         the walk lives here, not reached into from the basket) and value-neutrally extracts up to `usdWanted`
    ///         (USD 1e18) into `sink`, stopping as soon as it's met. FAULT-TOLERANT via the same `this.`-self-call
    ///         pattern as `cascadeDelever`: a stuck/illiquid position reverts its own `deleverToVault` and is
    ///         SKIPPED, never blocking the sweep. Gated to the range (`RANGE`). Partial de-lever keeps
    ///         positions OPEN, so the book is stable across the walk (no swap-pop mid-loop). Returns stable routed
    ///         to `sink`. Book-order (not strict LTV rank): each tap is value-neutral + capped at its own #67
    ///         deliverable, so order only picks WHICH lightly-levered LPs are tapped — strict LTV-ranking is the
    ///         proactive cascade's job.
    function deleverBook(uint256 usdWanted, address sink, uint256 minOut)
        external nonReentrant returns (uint256 freed)
    {
        _onlyRange();
        // §POOL-VENUE — ONE EXTRACTION, NOT A WALK. This looped every open LP, extracting from each
        // until `usdWanted` was met, so the redeem-side sweep carried the same O(open LPs) cost the
        // delivery side did — and it is the LAST walk of `_openLps` on a state-changing path.
        // With one pooled position an extraction against ANY open LP repays the pool and frees pool
        // collateral, so naming one is naming all of them; the book is read only to find the venue.
        // ⚠️ AND THE CAP IS NOW THE POOL'S, WHICH IS WHY THIS DOES NOT UNDER-EXTRACT. `deleverToVault`
        // bounds itself by `deliverableDollars(lp)`, which pooled is that LP's PROPORTIONAL slice —
        // extracting through one LP would have capped at ~1/N of the pool. `totalDeliverableDollars`
        // is now the aggregate bound, evaluated once on the pool, and is what this passes.
        // ⛔ THE `try/catch` STAYS: a venue that cannot source must leave the redeem short rather than
        // revert it, which is the same fault-tolerance the per-LP walk had.
        // §POOL-VENUE — same correction as the delivery path: gate on the PINNED pool, not on the
        // book being non-empty. A pool holding a remainder after its last LP closed still owes a
        // de-lever, and `_openLps.length == 0` refused it without saying so.
        if (poolVenue == address(0)) return 0;
        uint256 cap = this.totalDeliverableDollars();
        uint256 want = usdWanted > cap ? cap : usdWanted;
        if (want == 0) return 0;
        // 🔴 §POOL-VENUE — **THE GATE ABOVE WAS CORRECTED AND THIS LINE DEFEATS IT.** The comment
        //    directly above records changing the guard from `_openLps.length == 0` to
        //    `poolVenue == address(0)` so that *"a pool holding a remainder after its last LP closed
        //    still owes a de-lever"*. But `_openLps[0]` on an EMPTY book is an out-of-bounds panic,
        //    and it is evaluated HERE, in this frame, BEFORE the external call — so the `try/catch`
        //    below cannot absorb it. The redeem REVERTS in precisely the case the gate was widened
        //    to admit, which is worse than the refusal it replaced.
        // ⇒ Guard the index. This restores the graceful `freed = 0` the `try/catch` intends, and a
        //   revert can no longer escape a path whose entire contract is "fall short, never revert".
        // ⏸️ IT DOES NOT YET SERVE THE POOL-REMAINDER CASE, and that is booked rather than faked:
        //    `deleverToVault` needs `pos[lp].open` and sizes off `deliverableDollars(lp)`, so with no
        //    open LP there is nothing to route through. Serving it needs a POOL-LEVEL extraction
        //    (venue from `poolVenue`, size from `totalDeliverableDollars`), which is the book-level
        //    collapse — not a line change here.
        // ⚠️ AND A SECOND DEFECT ON THIS PATH, MEASURED BY READING: the caller computes the AGGREGATE
        //    bound (`this.totalDeliverableDollars()`) and the comment says that is "what this passes"
        //    — but `deleverToVault` then re-clamps to `deliverableDollars(lp)`, the LP's PROPORTIONAL
        //    slice. So the aggregate is capped back to ~1/N inside the callee, which is the exact
        //    under-extraction the aggregate was introduced to remove. Also the collapse's job.
        if (_openLps.length == 0) return 0;
        try this.deleverToVault(_openLps[0], want, sink, minOut) returns (uint256 f) { freed = f; }
        catch { /* pool could not source → redeem falls short, never reverts (keeper cascade picks it up) */ }
    }

    /// @notice Morpho flash-loan callback. ONLY the pinned provider may call it, and Morpho invokes it solely
    ///         on the address that called `flashLoan` (us), so it fires only from `_deleverFlash`. Repays the
    ///         LP's debt with the flashed stable, withdraws the now-health-safe collateral, sells it, keeps
    ///         exactly `assets` to return to Morpho (guaranteed by the swap's oracle floor, else the whole op
    ///         reverts), and hands any surplus (realized over-collateralization) to the LP.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != flashProvider) revert NotFlash();
        // Both layouts share the shape (uint8 mode, address lp, address venue, address stable, uint256): the
        // trailing word is `minOut`. §E304-mintclose: mode 1 (flash WETH → mint BOLD) is DELETED, so the
        // live tags are 0 (generic flash-stable) and 2 (§G.3 extraction); the `uint8` stays because mode 2
        // carries a WIDER layout and the tag is what tells the two apart.
        (uint8 mode, address lp, address venueAddr, address stable, uint256 last) =
            abi.decode(data, (uint8, address, address, address, uint256));
        if (mode == 2) { _extractSettle(assets, data); return; }             // §G.3 redeem/swap-out — own frame
        _deleverSettle(assets, lp, venueAddr, stable, last, data);
    }

    /// mode-2 (§G.3 redeem/swap-out extraction) settle in its OWN frame (no via_ir): the wider layout
    /// (2, lp, venue, stable, extractUsd, vault, minOut2); the extract body lives in LevMath (bytecode outside
    /// this contract). Extracted from onMorphoFlashLoan to stay within the legacy stack.
    function _extractSettle(uint256 assets, bytes calldata data) internal {
        (, address lp, address venueAddr, address stable, uint256 extractUsd, address vault, uint256 minOut2) =
            abi.decode(data, (uint8, address, address, address, uint256, address, uint256));
        (gasReserve, _lastFreed) = LevMath.extractToVaultBody(
            assets, lp, venueAddr, stable, extractUsd, vault, minOut2,
            _extractCfg());
    }

    /// mode-0 (generic flash-stable) settle in its OWN frame (no via_ir): repay-first → withdraw → sell → return the
    /// flash + surplus to the LP. Sell + keeper-gas peel run in LevMath (bytecode outside this contract).
    function _deleverSettle(uint256 assets, address lp, address venueAddr, address stable, uint256 last, bytes calldata data) internal {
        // §C2.1 — pull the keeper's 1inch POOL WORD out of the SAME flash payload the other five fields
        // ride in. Mode 0 is the only layout that carries it; mode 2 returns above this line.
        LevMath.ExtractCfg memory cfg = _extractCfg();
        (,,,,, uint256 dex) = abi.decode(data, (uint8, address, address, address, uint256, uint256));
        cfg.dex = dex;
        // repay-first → withdraw the freed collateral → sell → return the flash + surplus: body in LevMath (EIP-170).
        gasReserve = LevMath.deleverSettleBody(assets, lp, venueAddr, stable, last,
            AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW), cfg);
    }

    /// The ETH sell/buy machinery lives in LevMath now (delegatecall, bytecode OUTSIDE this contract, so the
    /// manager fits EIP-170). This builds the context it needs: the manager's runtime addresses + the crank keeper
    /// + the live WETH gas-reserve (threaded in, returned updated).
    /// @dev §E357 — `route` is a PARAMETER because this struct field was hardcoded `""`, and that
    ///      one literal is where every empty route on the BUY side came from. `_aggSwap` refuses an
    ///      empty route, so `stableToColl` → `_stableToWethSor` → `_aggSwap` could never execute:
    ///      the lever-up leg was dead at the source, not at the entrypoints.
    function _sellCtx(address keeper, uint256 dex, uint256 dex2, bytes memory route) internal view returns (LevMath.SellCtx memory) {
        return LevMath.SellCtx({ weth: WETH, weeth: address(COLL), aux: address(AUX), keeper: keeper, reserveIn: gasReserve, dex: dex, dex2: dex2, route: route });
    }

    /// Lever-UP BUY (own frame, no via_ir): borrow `usd` stable, swap → collateral (LevMath.stableToColl), supply
    /// it to the venue for `who`. Shared by openLev's ladder + rebalance's up-leg (dedup).
    function _leverUpBuy(ILevVenue venue, address who, address stable, uint256 usd, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route) internal {
        uint256 coll = LevMath.stableToColl(
            _sellCtx(address(0), dex, dex2, route), stable, venue.borrow(who, LevMath._fromUsd(address(AUX),stable, usd)), minOut);
        IERC20Min(_collToken(venue)).transfer(address(venue), coll);
        venue.supply(who, coll);
    }

    // ════════════════════════ SELF-FUNDING KEEPER GAS (no operator subsidy) ════════════════════════
    /// WETH reserve covering a keeper's de-lever/protect gas when the freed value's own headroom can't. The
    /// balance is ITSELF the bound (`LevMath._reimburse` clamps the shortfall to it and never reverts, so a
    /// safety unwind is never blocked by an empty reserve); permissionless top-up via `fundGasReserve`.
    /// §E304-mintclose: the sentence broke off at "(mirrors" — it pointed at the BOLD-close reserve, deleted.
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

}
