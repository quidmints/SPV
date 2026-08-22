// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {ILevVenue} from "./Interfaces.sol";
import {IAux, ICore} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";

/// @title  LevBase — the per-LP position registry both lev managers duplicated
///
/// @notice §A.71 STEP 3. `LevManager` and `BtcLevManager` each carried their own copy of this
///         registry: the same `pos` mapping, the same open-LP enumeration, the same target-LTV cap
///         and the same four functions. 15 of 33 bodies scored as near-duplicates, and these four
///         differed ONLY cosmetically — `uint256` vs `uint`, a parameter named `capBps` vs `cap`,
///         and one `address(AUX)` cast. One implementation now, two instances.
///
///         TWO RESIDUALS WERE SETTLED BY MEASUREMENT, NOT TASTE, BECAUSE BOTH ANSWERS COST SOMETHING:
///         • `AUX` was `IAux` in one manager and `address` in the other — which is exactly why
///           `swapOutDeleverAmt` read `_fromUsd(address(AUX), …)` on one side and `_fromUsd(AUX, …)`
///           on the other. Unified on `IAux`: ABI-SAFE, since both forms generate an
///           address-returning getter.
///         • `TARGET_LTV_CAP_BPS` was `internal` in one and `public` in the other. `internal` would
///           have DELETED BtcLevManager's existing public getter — an ABI break. `public` only adds a
///           getter to LevManager, and measurement says it can afford one: 24,352 bytes with 224 to
///           spare (CLAUDE.md's "70 bytes" line is stale). So `public` is both the compatible answer
///           and the affordable one. ⚠️ Re-run tools/check-contract-sizes.py after any addition here:
///           224 bytes is headroom, not licence, and `forge test` does NOT enforce EIP-170.
///
///         ⚠️ `_openLps` / `_lpIdx` are `internal`, not `private`, ONLY because a derived contract
///         cannot see a `private` member. No ABI consequence — neither visibility emits a getter.
///         ⚠️ `pos` is PUBLIC, so its generated getter is an ABI-visible 6-tuple. Do not reorder
///         `Types.Pos`'s fields for tidiness; clients decode by position.
abstract contract LevBase {
    /// TWAP window both sides price against. Identical (1800) in each manager; PUBLIC here because
    /// BtcLevManager already exposed a getter and removing it would be an ABI break, while adding one
    /// to LevManager is affordable (317 bytes of margin, measured).
    uint32 public constant TWAP_WINDOW = 1800;

    /// Max-leverage LTV ceiling an LP may set for itself: 7500 bps ≈ 4×.
    uint256 public constant TARGET_LTV_CAP_BPS = 7500;
    /// @dev §FOLD-DELTA — ±3% LTV dead-range before a rebalance is worth its gas. Was declared on BOTH
    ///      managers with the same value (ETH `internal`, BTC `public`; no reader of either outside
    ///      the managers, checked across src/ test/ script/).
    uint256 internal constant RANGE_BPS = 300;

    /// @notice How far the LP's debt is from the IL-hedge target, and in which direction.
    /// @dev §FOLD-DELTA — was duplicated on each manager (0.71 similarity). The two bodies computed
    ///      the SAME thing in a different statement order; the only real difference was ETH's
    ///      `if (!p.open)` early-out. BTC was not buggy — `closeBtcLev` does `delete pos[lp]`, so
    ///      `ilBasisPx == 0` makes `_ilTargetLive` return 0 and `debtDelta` reports in-range —
    ///      whereas ETH RETAINS the `Pos` with `open = false` on its keepState branch, which is why
    ///      only ETH needed the gate. A REAL asymmetry; the shared body keeps the gate because it is
    ///      correct for both and strictly cheaper than reaching `debtUsd` for a closed position.
    function debtDeltaToTarget(address lp) public view returns (bool levUp, uint256 amountUsd) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (false, 0);
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return LevMath.debtDelta(LevMath.entryEquityUsd(p.entryEquity, px), debtUsd(lp), _ilTargetLive(p, px), RANGE_BPS);
    }

    /// Oracle (`getTWAPforAsset`) + the caller-funded paths both managers reach through.
    IAux public immutable AUX;

    /// @notice The asset this instance prices against — WETH on the ETH side, WBTC on the BTC side.
    ///         THE ONLY per-asset input to the shared valuation bodies. Before this existed, every
    ///         shared function differed solely by naming `WETH` or `WBTC` in its TWAP call, which is
    ///         what kept ~20 otherwise-identical lines from being one implementation.
    address public immutable ORACLE_KEY;

    /// Per-LP, one isolated position. PUBLIC ⇒ ABI-visible 6-tuple getter (see note above).
    mapping(address => Types.Pos) public pos;

    /// @dev Enumerable set of LPs with an open position, so the whole book's live net equity can be
    ///      summed on-chain. `_lpIdx` is 1-based (0 = absent); removal is swap-and-pop.
    address[] internal _openLps;
    mapping(address => uint256) internal _lpIdx;

    /// The range's sync range (Quid's `syncLev` / Vault's `syncLev`). GOV pin-once, then frozen —
    ///  the SETTER stays per-manager (BtcLevManager fuses it into `init` alongside `venuesFrozen`).
    address public RANGE;

    event TargetSet(address indexed lp, uint256 targetLtvBps);

    /// @notice §E298 — the five events `LevManager` and `BtcLevManager` each declared separately.
    ///         Both inherit this contract, so one declaration here reaches both and an inherited
    ///         event still appears in each child's ABI. Three were already byte-identical at every
    ///         emit site. Two had DRIFTED and are reconciled to the richer ETH shape:
    ///         `Opened` lacked `venue` on the BTC side even though BTC picks a venue too
    ///         (`ILevVenueColl(address(venue)).COLLATERAL()` decides vBTC vs WBTC mode), and
    ///         `VenueAllowed` lacked the `ok` flag, so a BTC de-authorisation was indistinguishable
    ///         from an authorisation in the log.
    /// ⚠️ `Closed`'s two declarations shared a SELECTOR while meaning different things — the ETH
    ///         one named `weethReturned`, the BTC one `vbtcReturned`. Identical topic0, different
    ///         asset: an indexer reading both managers could not tell them apart. The parameter is
    ///         now `assetReturned`, which is what it always was — the venue's own collateral token.
    event Opened(address indexed lp, address venue, uint256 targetLtvBps);
    event Closed(address indexed lp, uint256 assetReturned);
    event VenueAllowed(address indexed venue, bool ok);
    event DeleverFailed(address indexed lp, uint256 ltvBps);
    event ProtectedFromQuid(address indexed lp, uint256 quidRedeemed, uint256 debtRepaid);
    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);

    error NotOpen();
    error BadTarget();

    constructor(address aux, address oracleKey) { AUX = IAux(aux); ORACLE_KEY = oracleKey; }

    /// @notice Poke the range to reconcile `lp`'s levered slice to live net equity. ONE routine for
    ///         what was THIRTEEN byte-identical inlined copies (6 in `LevManager`, 7 in
    ///         `BtcLevManager`), every one of them exactly
    ///         `if (RANGE != address(0)) { try ICore(RANGE).syncLev(lp) {} catch {} }`.
    /// @dev    §FOLD-SYNC. A FUNCTION, not a modifier, per standing rule 8c: a modifier's body is
    ///         inlined at every use site, so 13 uses would be 13 copies again — which is the thing
    ///         being removed. This is one body and 13 jumps. Precedent for the direction: §E210
    ///         collapsed per-stable `if` chains into one table and handed back 435 bytes on
    ///         `LevMath` — folding N INLINED BODIES into one routine gives bytes back, whereas
    ///         folding a whole CONTRACT in costs them (its code still has to land somewhere).
    ///
    ///         WHY THE try/catch IS LOAD-BEARING AND MUST NOT BECOME A BARE CALL: this is a
    ///         PERMISSIONLESS courtesy poke on the tail of money-moving operations. If the range
    ///         reverts, the lever/delever that already succeeded must still commit — the slice is
    ///         separately reconcilable by anyone calling `syncLev` directly, so a failed poke costs
    ///         a delay, while a propagated revert would strand the position. The `RANGE != 0` guard
    ///         is not defensive dressing either: `RANGE` is pin-once and genuinely unset between
    ///         deploy and wiring, and a call to address(0) SUCCEEDS silently rather than reverting,
    ///         so without it an unwired deploy would look reconciled and not be.
    /// @notice §FOLD-REBALANCE — THE ONE REBALANCE, FOR BOTH RANGES.
    /// @dev Both managers ran this identical shape: reanchor, require open, read the target, branch on
    ///      direction, sync the range. FOUR things actually differed and each is now a seam:
    ///        • an extra per-asset precondition (BTC requires WBTC collateral)  -> `_requireRebalancable`
    ///        • which lever-up leg runs                                          -> `_leverUp`
    ///        • which de-lever leg runs                                          -> `_delever`
    ///        • ETH emitted `Rebalanced`, BTC emitted NOTHING. That was an OBSERVABILITY GAP, not a
    ///          per-asset fact, so the shared body emits for both. ⚠️ A BTC rebalance now logs where it
    ///          previously did not — an ADDED event, which no consumer can break on, but say so.
    ///      ⚠️ `_delever` RECEIVES `deltaUsd` AND IS FREE TO IGNORE IT: ETH re-derives the closed-form
    ///      `Δ/(1−t)` via `deleverRepayUsd` so one flash lands on target with no withdraw-before-repay
    ///      health breach, while BTC repays the delta directly. The two ranges size the repay differently
    ///      and that is REAL, not drift.
    /// @dev Order note: ETH checked `open` BEFORE reanchoring and BTC after. Immaterial —
    ///      `_reanchorIfReseated` already early-returns on a closed position.
    function _rebalance(address lp, uint256 minOut) internal {
        _reanchorIfReseated(lp);
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        _requireRebalancable(p);
        address stable = p.venue.stable();
        (bool levUp, uint256 deltaUsd) = debtDeltaToTarget(lp);
        if (deltaUsd != 0) {
            if (levUp) _leverUp(p.venue, lp, stable, deltaUsd, minOut);
            else       _delever(p.venue, lp, stable, deltaUsd, minOut);
            emit Rebalanced(lp, levUp, deltaUsd, getCurrentLtvBps(lp));
        }
        _syncRange(lp);
    }

    event Rebalanced(address indexed lp, bool levUp, uint256 amount, uint256 ltvBps);

    /// @dev Per-asset precondition. ETH has none; BTC requires WBTC collateral.
    function _requireRebalancable(Types.Pos memory p) internal view virtual {}
    function _leverUp(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut) internal virtual;
    function _delever(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut) internal virtual;

    function _syncRange(address lp) internal {
        if (RANGE != address(0)) { try ICore(RANGE).syncLev(lp) {} catch {} }
    }

    /// @notice The range's anchor price, or 0 if the range is unwired or reverts. §FOLD-SYNC — was
    ///         inlined identically in both managers' open paths.
    /// @dev    Returning 0 rather than reverting is deliberate and matches the pre-fold behaviour:
    ///         `syncKeyPx` is the sold-fraction REFERENCE, and `_ilTargetLive`/`reanchorCompute`
    ///         already treat 0 as "never anchored" (that is what `_reanchorIfReseated` exists to
    ///         repair). Reverting here would make an unwired range block position OPENING, which is
    ///         strictly worse than opening with a reference that the first reanchor fills in.
    function _rangePrice() internal view returns (uint px) {
        if (RANGE != address(0)) {
            try ICore(RANGE).rangePrice() returns (uint s) { px = s; } catch {}
        }
    }

    /// @notice Write a fresh position and enrol the LP in the book. §FOLD-OPEN — this tail was
    ///         duplicated verbatim in `LevManager.openLev` and `BtcLevManager.openBtcLev`; the two
    ///         differed ONLY in how they computed `entryEquity` (weETH→ETH for the ETH side, sats-as-is for
    ///         BTC, because vBTC IS sats) and in the local name of the LTV cap. Everything after
    ///         that — the range-price read, the `Types.Pos` literal, the book enrolment — was one
    ///         shape written twice, and a struct literal is not cheap in bytecode.
    /// @param  entryEquity  the IL base, FIXED at open. Caller computes it because it is the one genuinely
    ///             per-asset quantity here; passing it in is what lets the rest be shared.
    /// @notice §FOLD-MEASURE — body in `RangeLib` (§FOLD-BOOK). `_rangePrice()` is resolved HERE because it
    ///         try/catches a call to `RANGE`, and the struct is built here so the library takes one
    ///         memory pointer rather than five scalars (cheaper seam, and `Types.Pos`'s field order
    ///         stays owned by one place).
    function _openPos(ILevVenue venue, uint64 capBps, uint entryPx, uint entryEquity) internal {
        RangeLib.openPos(pos, _openLps, _lpIdx, msg.sender,
            Types.Pos({venue: venue, targetLtvCapBps: capBps, ilBasisPx: uint128(entryPx),
                       entryEquity: uint128(entryEquity), syncKeyPx: _rangePrice(), open: true}));
    }

    function _trackOpen(address lp) internal {
        RangeLib.trackOpen(_openLps, _lpIdx, lp);   // §FOLD-MEASURE
    }

    function _untrackOpen(address lp) internal {
        RangeLib.untrackOpen(_openLps, _lpIdx, lp);   // §FOLD-MEASURE
    }

    /// @notice Adjust the caller's max-leverage CAP (bps LTV, ≤ TARGET_LTV_CAP_BPS).
    /// @notice §FOLD-MEASURE — body in `RangeLib` (§FOLD-BOOK). The ceiling is PASSED, not duplicated there:
    ///         `TARGET_LTV_CAP_BPS` is a constant and constants live in the caller's code, so one
    ///         definition stays here and the library reads whatever it is given.
    function setTargetLtv(uint64 capBps) external {
        RangeLib.setTargetLtv(pos, msg.sender, capBps, TARGET_LTV_CAP_BPS);
    }

    /// @notice Venue + stable + native amount for a swap-out-driven delever of `lp`.
    function swapOutDeleverAmt(address lp, uint256 maxUsd18)
        external view returns (address venue, address stable, uint256 amtNative) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (address(0), address(0), 0);
        venue = address(p.venue);
        stable = p.venue.stable();
        amtNative = LevMath._fromUsd(address(AUX), stable, maxUsd18);
    }

    /// @notice Book-level deliverable dollars across every open LP.
    ///         LIFTED from both managers — after ORACLE_KEY the two copies were BYTE-IDENTICAL.
    ///         Safe over `_openLps` because _untrackOpen is called UNCONDITIONALLY on close
    ///         (LevManager:659, BtcLevManager:529), including the ETH keepState branch that
    ///         retains the Pos with open=false. So this never iterates a closed position.
    function totalDeliverableDollars() external view returns (uint total) {
        uint n = _openLps.length;
        if (n == 0) return 0;
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        for (uint i; i < n; i++) total += _deliverableDollarsAt(_openLps[i], px);
    }

    /// @dev ⚠️ WHEN THESE MOVE TO A DELEGATECALL LIBRARY, THE CALLER COMPUTES THIS AND PASSES IT AS
    ///      A VALUE — a library cannot call a virtual on its caller. That constraint is why the
    ///      per-asset step is kept as narrow as possible: one `uint → uint` conversion is trivial to
    ///      pass by value, whereas a range that needed the venue or the LP would not be.
    ///
    ///      §FOLD-COLL removed a stale justification that stood here. It read: "it is a range rather
    ///      than a shared helper because `_collToEth` CANNOT serve BTC: it tests
    ///      `COLLATERAL() == WETH`, which is false for a vBTC venue, so sats would be routed through
    ///      `getEETHByWeETH` and silently mis-converted." The `_collToEth` that existed when this was
    ///      written did test the collateral token; the one that survived to be folded did NOT — its
    ///      body was `units == 0 ? 0 : RATE.getEETHByWeETH(units)` with an UNNAMED venue parameter.
    ///      So the stated reason for the range had already stopped being true, while the range itself
    ///      remained correct for a different and simpler reason: the two sides convert differently
    ///      (a rate lookup vs the identity), which is reason enough and needs no misvaluation story.
    /// @notice §FOLD-COLL — **THE ONLY PER-ASSET PRIMITIVE IN THE VALUATION STACK.** Collateral
    ///         UNITS as held by the venue → the instance's native base unit.
    ///           • ETH: weETH → eETH/ETH via the ether.fi rate (`RATE.getEETHByWeETH`).
    ///           • BTC: IDENTITY — vBTC IS sats, and the WBTC price already carries the ×1e10 lift
    ///             that closes the 8↔18 decimal gap, so a second conversion here would double-count.
    /// @dev    Takes UNITS, not `(venue, units)`. The ETH implementation's venue parameter was
    ///         UNNAMED — i.e. declared and never read — so it was never a per-venue conversion, and
    ///         carrying it would have made the shared signature wider than the work it does.
    function _collToBase(uint units) internal view virtual returns (uint);

    /// @notice Collateral units → USD(1e18) at the instance's own oracle key. §FOLD-COLL: was
    ///         `LevManager._collValueUsd(venue, units)` and `BtcLevManager.vBtcValueUsd(units)` —
    ///         the SAME formula, `base · TWAP / 1e18`, differing only by the conversion now behind
    ///         `_collToBase` and by the BTC one having no conversion to do.
    /// @dev    `view`. The ETH copy was non-`view` for no reason: it called only `_collToEth` (view)
    ///         and `getTWAPforAsset` (view, as the BTC copy being `public view` already proved).
    ///         That was drift, and it propagated — `getCurrentLtvBps` and `ilLtvBps` were non-`view`
    ///         on the ETH side and `view` on the BTC side purely because of it.
    function collValueUsd(uint units) public view returns (uint) {
        if (units == 0) return 0;
        return (_collToBase(units) * AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW)) / 1e18;
    }

    /// @notice Per-LP collateral in the native base unit. §FOLD-COLL — now CONCRETE and no longer
    ///         `virtual`: both overrides were `_collToBase(v.collateralOf(lp))` once the conversion
    ///         was named, the ETH one spelling it via `_collToEth` and the BTC one as the identity.
    function _collNative(ILevVenue v, address lp) internal view returns (uint) {
        return _collToBase(v.collateralOf(lp));
    }

    /// @notice The LP's venue debt in USD(1e18). §FOLD-LTV — was declared `virtual` here and
    ///         overridden with the SAME body in both managers (0.88 similarity; the only difference
    ///         was ETH hoisting `v.stable()` into a local). Concrete now, and the overrides go.
    /// @dev ⚠️ THE `address(v) == 0` EARLY-OUT IS NOT A DEFENSIVE CLAMP — it is the one case the
    ///      §FOLD-LTV trace below missed. That note argues the `!open` guards were droppable because
    ///      every downstream helper returns 0 on a zeroed struct. True — but ALL of them are reached
    ///      THROUGH this function, and a zeroed `Pos` zeroes `venue` too, so `v.stable()` is a
    ///      high-level call to `address(0)`: solc's extcodesize check REVERTS before any zero-guard
    ///      runs. `BtcLevManager.closeBtcLev` does `delete pos[lp]`, so this is reachable for every
    ///      closed BTC position and any address that never opened one — and `debtUsd`,
    ///      `getCurrentLtvBps` and `debtDeltaToTarget` are all `public`. Returning 0 for "no position"
    ///      makes the query TOTAL; it cannot mask a real debt, because a real debt requires a venue.
    function debtUsd(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;
        if (address(v) == address(0)) return 0;
        return LevMath._toUsd18(address(AUX), v.stable(), v.debtOf(lp));
    }

    /// @notice Delegated QU!D-protect: redeem the LP's OWN opted-in QU!D to repay the LP's OWN debt
    ///         when the position nears venue liquidation. Moves NO value to the caller.
    ///
    /// §PROTECT-FOLD (2026-08-22) — ONE body for both managers. The two copies were identical except
    /// for (a) `QUID`'s DECLARED TYPE (`IERC20Min` on ETH, `address` on BTC) and (b) the ETH side
    /// reimbursing the keeper. Both are now hooks, so the gate, the `LevMath.protectExec` call and
    /// the event live once.
    /// ⚠️ **THE MECHANICS WERE ALREADY SHARED** — both copies delegated to the SAME
    /// `LevMath.protectExec`. What was duplicated was the WRAPPER, which is the part that drifts
    /// silently: a gate added to one side and not the other reads as a per-asset decision.
    /// ⚠️ **`internal`, AND THE GUARD STAYS WITH THE CALLER — deliberately.** Each manager defines
    /// its OWN `nonReentrant` (its own `_lock` slot); `LevBase` has none. Moving the guard here would
    /// relocate that storage into the base and change the layout of BOTH deployed contracts, which is
    /// not worth the four lines it would save. So the managers keep a thin `external nonReentrant`
    /// wrapper and THE BODY — the gate, the `protectExec` call, the event — lives once, which is the
    /// part that drifts silently.
    /// 🔎 `nonReentrant` itself IS duplicated across the two managers. Folding it is a storage-layout
    /// change and is booked separately, not smuggled in here.
    function _protectFromQuidBody(address lp, uint256 minStableOut) internal returns (uint256 repaid) {
        if (!pos[lp].open) revert NotOpen();
        uint256 pull;
        (pull, repaid) = LevMath.protectExec(
            _quidAddr(), address(AUX), address(pos[lp].venue), lp, getCurrentLtvBps(lp), minStableOut);
        _afterProtect(msg.sender);
        emit ProtectedFromQuid(lp, pull, repaid);
    }

    /// @dev QU!D as an address. ETH declares it `IERC20Min`, BTC `address` — one cast, one place.
    function _quidAddr() internal view virtual returns (address);

    /// @dev Post-protect keeper settlement. ETH reimburses from the WETH gas reserve; BTC has no
    ///      reserve to draw on, so the default is a NO-OP and that asymmetry is REAL, not drift.
    function _afterProtect(address keeper) internal virtual {}

    /// @notice Live LTV against CURRENT collateral value (the venue-liquidation view).
    /// @dev    §FOLD-LTV. ⚠️ THE `if (!open) return 0` EARLY-OUTS FROM THE ETH COPIES ARE DROPPED,
    ///         AND THAT IS A DELETION OF DEAD CHECKS, NOT A WEAKENING — traced through every layer
    ///         before removing them: a closed position zeroes the struct, and
    ///         `LevMath.ltvBps` returns 0 when `collValue == 0`, `collValueUsd` returns 0 when
    ///         `units == 0`, `ilTargetBps` returns 0 when `ilBasisPx == 0`, and
    ///         `ilTargetLive`'s range branch is already gated on `syncKeyPx != 0`. So every path
    ///         returns 0 for a closed position WITHOUT the guard. The BTC copies never had it and
    ///         were correct; the asymmetry was drift, and keeping it would have been a clamp that
    ///         cannot change an outcome (standing rule 3).
    function getCurrentLtvBps(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;                       // same address(0) case as `debtUsd`
        if (address(v) == address(0)) return 0;
        return LevMath.ltvBps(debtUsd(lp), collValueUsd(v.collateralOf(lp)));
    }

    /// @notice LTV against the FIXED IL base `entryEquity` — the reference the IL target is measured against,
    ///         which is why it does NOT move with collateral. §FOLD-LTV.
    function ilLtvBps(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return LevMath.ltvBps(debtUsd(lp), LevMath.entryEquityUsd(pos[lp].entryEquity, px));
    }

    /// @notice The live IL target in bps. §FOLD-LTV.
    /// ⚠️ THE NOTE HERE SAID *"NOT `view`: `_ilTargetLive` reaches the range's `soldFractionWad`"* —
    ///    and it was ALREADY FALSE when written, because the function below is declared `public
    ///    view`. §C22 then removed the reason as well: `_ilTargetLive` no longer touches the range
    ///    at all, so there is no non-view call anywhere on this path.
    function ilTargetLtvBps(address lp) public view returns (uint) {
        return _ilTargetLive(pos[lp], AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    /// @notice Per-LP deliverable dollars at price `px`. LIFTED from both managers 2026-08-13 —
    ///         identical once `_collNative` absorbed the collateral conversion.
    function _deliverableDollarsAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        uint collUsd = (_collNative(p.venue, lp) * px) / 1e18;          // C (USD 1e18)
        uint d = debtUsd(lp);                                           // D (USD 1e18)
        uint netEq = collUsd > d ? collUsd - d : 0;
        return LevMath.deliverableDollars(netEq, collUsd, LevMath.ltvBps(d, collUsd), p.venue.liqThresholdBps());
    }

    /// @notice Per-LP net equity in NATIVE units at price `px`. Same lift, same reason.
    function _netEquityAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        return LevMath.netEquityBase(_collNative(p.venue, lp), debtUsd(lp), px);
    }

    // §FOLD-LTV — the `virtual` declaration of `debtUsd` was HERE and is gone: it is implemented
    // concretely above, because both managers overrode it with the same body. "Per-asset only in
    // which stable the venue names" was true and was never a reason to make it abstract — the venue
    // names its own stable, so one body reads it on both sides.

    /// @notice Per-LP net-of-debt equity in the instance's OWN native unit — 1e18 ETH on the ETH side,
    ///         8-dec sats on the BTC side. The unit differs; the MEANING does not, which is why one
    ///         name serves both. (Was `netEquityEth`/`netEquityBtc`; those two names were the last
    ///         per-asset difference in `_reanchorIfReseated`.)
    function netEquity(address lp) public view returns (uint256) {
        return _netEquityAt(lp, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    // ─── §LEV-FOLD — five bodies that were written TWICE, identically ─────────────────────────
    //
    // These lived once in `LevManager` and once in `BtcLevManager` and differed only in the
    // spelling `uint` vs `uint256`. Every symbol they touch already lives HERE -- `AUX`,
    // `ORACLE_KEY`, `TWAP_WINDOW`, `_openLps`, `pos`, `_netEquityAt`, `_deliverableDollarsAt`,
    // `debtUsd` -- so neither copy was ever expressing a per-asset difference; the base simply had
    // not been given them. `netEquity` above was the same case one step further along: declared
    // `virtual` here and overridden with the identical body on both sides.
    //
    // ⚠️ WHAT IS DELIBERATELY *NOT* FOLDED, and the discriminator is a real one. The suffixed
    // accessors -- `totalNetEquity`/`totalNetEquity`, `grossCollateral`/`grossCollateral`,
    // `totalGrossCollateral`/`totalGrossCollateral` -- stay as they are, because
    // `ILevEquity` and `ILevEquityBtc` are two interfaces over two DIFFERENT manager contracts.
    // Distinct selectors mean `ILevEquity(btcManager).totalNetEquity()` REVERTS rather than
    // silently returning the wrong range's book, and this repo has already shipped three
    // address-confusion bugs of exactly that shape in one session (an `ethVenue` passed into a
    // parameter named `btc`, among them). Note the discriminator: the members below all take
    // an LP ADDRESS or none and read THIS instance's own book, so a wrong-manager call yields 0 or
    // this manager's own total -- whereas a no-arg `totalNetEquity()` on the wrong handle would
    // hand back a different range's number that looks perfectly valid. Standing rule 3: a guard
    // earns its place when the failure it prevents would otherwise be silent.

    /// @notice Deliverable dollars for `lp` — oracle read ONCE.
    function deliverableDollars(address lp) public view returns (uint256) {
        return _deliverableDollarsAt(lp, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    /// @notice How many LPs have an open levered position.
    function openLevCount() external view returns (uint256) { return _openLps.length; }

    /// @notice The `i`-th open LP — lets an off-chain keeper enumerate the book.
    function openLpAt(uint256 i) external view returns (address) { return _openLps[i]; }

    /// @notice Live sum of every open position's debt (USD 1e18).
    function totalDebtUsd() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        for (uint256 i; i < n; i++) if (pos[_openLps[i]].open) total += debtUsd(_openLps[i]);
    }

    /// @dev The IL target at the live price, for a position already in memory.
    /// §MUTABILITY 2026-08-18 — `view` CASCADED here: it became restrictable only once
    /// `LevMath.ilTargetLive` was, which is the same shape as the dead-variable cascade earlier
    /// today. Tightening a callee is what lets the caller tighten.
    function _ilTargetLive(Types.Pos memory p, uint256 px) internal view returns (uint256) {
        // §C22 — was `LevMath.ilTargetLive(RANGE, p.syncKeyPx, …)`. That function preferred
        // `soldFractionWad(syncKeyPx)`, which is a CONSTANT (0.500750000 = f(RANGE_DELTA) alone —
        // the range recentres on spot, so the price cancels out of the ratio). It is gone; the
        // estimate on the entry-pinned basis is the target.
        return LevMath.ilTargetBps(p.ilBasisPx, px, p.targetLtvCapBps);
    }

    // ─── §LEV-FOLD-2 — the last three per-asset accessors, folded through `_collNative` ────────
    //
    // `grossCollateral`/`grossCollateral` looked like a REAL per-asset difference and were
    // not: ETH ran `_collToEth(v, v.collateralOf(lp))` (weETH -> ETH via the ether.fi rate) while
    // BTC ran `v.collateralOf(lp)` raw, because vBTC IS sats. That difference is ALREADY isolated
    // in `_collNative`, the range each manager overrides -- the note on `_deliverableDollarsAt`
    // above records the same discovery ("identical once `_collNative` absorbed the collateral
    // conversion"). So the conversion was never in these bodies; it was one call down.
    //
    // ⚠️ AND THE SUFFIX WAS LOAD-BEARING UNTIL THIS COMMIT, so it is not simply deleted. Distinct
    // selectors were what made `ILevEquity(btcManager).totalNetEquity()` REVERT instead of
    // silently returning the wrong range's book -- a real guard against a bug class this tree has
    // shipped three times. Removing it without replacement would trade a loud failure for a quiet
    // one. It is replaced at the ROOT: `setLevManager` now refuses a manager whose `ORACLE_KEY` is
    // not this range's own asset, so a lev manager CANNOT be pinned to the wrong range at all.
    // Standing rule 17 -- a clamp detects the bad state per call, the root fix makes it
    // unconstructible, and the clamp is then deletable rather than merely redundant.

    /// @notice This LP's GROSS collateral in the range's native unit (1e18 ETH / 8-dec sats).
    function grossCollateral(address lp) public view returns (uint256) {
        Types.Pos memory p = pos[lp];
        return p.open ? _collNative(p.venue, lp) : 0;
    }

    /// @notice LIVE sum of every open position's GROSS collateral, native unit.
    function totalGrossCollateral() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        for (uint256 i; i < n; i++) total += grossCollateral(_openLps[i]);
    }

    /// @notice LIVE sum of every open position's NET equity, native unit. Oracle read ONCE.
    function totalNetEquity() external view returns (uint256 total) {
        uint256 n = _openLps.length;
        if (n == 0) return 0;
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        for (uint256 i; i < n; i++) total += _netEquityAt(_openLps[i], px);
    }

    /// @notice A range reseat REALIZES accrued IL, so re-anchor `E0` to the position's CURRENT
    ///         net-equity — the new fixed base — NOT the range position (which is 0 in the (A) model,
    ///         the deposit having no separate unlevered range slice). Net-equity IS the delta-1 slice
    ///         now sitting in the recentered range; the next hedge cycle sizes from it at zero IL.
    /// @dev    The over-hedge fix still holds: `E0` tracks NET-EQUITY, never the growing collateral.
    ///         IDENTICAL on both sides once `netEquity` replaced the two per-asset accessors — the
    ///         bodies differed only in `uint` vs `uint256` spelling and comment framing.
    /// @notice §FOLD-MEASURE — body in `RangeLib` (§FOLD-BOOK). `px` and `base` are computed HERE and passed BY
    ///         VALUE because a library cannot reach the caller's immutables (`AUX`, `ORACLE_KEY`) or
    ///         its virtuals (`netEquity` routes through `_collToBase`). That is the hard boundary on
    ///         what can move, and it is why the guard is re-checked in the library rather than here:
    ///         computing `px`/`base` for a closed position is wasted gas but never wrong, and one
    ///         `open` check in the library is cheaper than two.
    function _reanchorIfReseated(address lp) internal {
        if (!pos[lp].open) return;   // cheap pre-filter: skip the two oracle/equity reads entirely
        // §C19 — the `getTWAPforAsset` argument is GONE with the `ilBasisPx` write it fed; the reseat
        // re-bases the seat and the equity, never the entry price, so it needs no oracle read.
        RangeLib.reanchorIfReseated(pos, RANGE, lp, netEquity(lp));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Homed here from `src/LevOracles.sol` (2026-08-15) to cut a file. THE CONTRACT STAYS
// STANDALONE, DELIBERATELY — do not fold it into `LevBase` above. Morpho's marketId is
// `keccak256(abi.encode(MarketParams))` and `oracle` is one of those five fields, so the
// oracle's ADDRESS IS PART OF THE MARKET'S IDENTITY. Pointing the market at a manager
// would make a manager redeploy a *different market*, silently, orphaning the old one.
// A tiny immutable is the most stable address we can give it.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice No usable price. These are Morpho `IOracle` implementations, so MORPHO calls them — which
///         makes the failure mode a security decision, not a style one (BUILD-QUEUE §A.13/§A.25):
///           • RETURNING 0 would have Morpho value collateral at zero ⇒ EVERY position instantly
///             liquidatable ⇒ irreversible value destruction.
///           • PANICKING (division by zero) reverts Morpho's calls too, but with an undiagnosable
///             `Panic(0x12)` and after burning all forwarded gas.
///         REVERTING with a named error is the safe failure: Morpho cannot price, so new borrows and
///         liquidations halt, and everything RESUMES once the feed recovers. A frozen market is
///         recoverable; a mass liquidation at a false zero is not.
error NoPrice();

/// @notice REAL Morpho IOracle for the vBTC/USDC market (collateral→loan, 1e36-scaled), from the SAME live
///   source the manager values vBTC through: `getTWAPforAsset(WBTC)` (USD18 per 1e18-raw, WBTC-lifted ×1e10).
///   vBTC is 8-dec sats: `sats · twap / 1e18 = USD18`; Morpho wants `sats · price / 1e36 = USDC6 = USD18/1e12`
///   ⇒ price = twap × 1e6. Fork-proven (incl. real Morpho seizure off this price) in test/VBtcLevFeeLane.t.sol.
///
///   ⚠️ It prices vBTC through `Aux.getTWAPforAsset`, and AUX is deployed inside the same broadcast, so
///   `MORPHO_VBTC_ORACLE` can NEVER be a pre-supplied env address — DeployL1_s must deploy it inline.
contract RealRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        uint256 twap = IAux(AUX).getTWAPforAsset(WBTC, 1800);
        if (twap == 0) revert NoPrice();   // 0 would value all vBTC collateral at zero — see NoPrice
        return twap * 1e6;
    }
}
