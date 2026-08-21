// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {ILevVenue, IERC20Min} from "./ILevVenue.sol";

/// @title  LevBookLib — the open-position BOOK, as a delegatecalled library
/// @notice §FOLD-MEASURE. `LevBase` is an ABSTRACT BASE, so every body in it is COMPILED INTO BOTH
///         `LevManager` AND `BtcLevManager`. A delegatecalled library's bodies live in the library's
///         OWN deployed bytecode and cost each caller only a jump + argument marshalling.
///         This library exists to MEASURE that trade at the smallest honest scale: the two book
///         mutators, which need no events, no immutables and no virtual dispatch, so nothing but the
///         seam cost distinguishes the two shapes.
/// @dev    Storage is passed by REFERENCE (`address[] storage`, `mapping storage`) — the same
///         technique `ChannelLib.initVaultsBody` and `QuidLib` already use in this tree, which is
///         what makes a library able to mutate its caller's state without owning a layout.
library LevBookLib {
    /// @notice Enrol `lp` in the open-position book. `lpIdx` is 1-BASED so 0 means absent.
    function trackOpen(
        address[] storage openLps,
        mapping(address => uint256) storage lpIdx,
        address lp
    ) external {
        if (lpIdx[lp] == 0) { openLps.push(lp); lpIdx[lp] = openLps.length; }
    }

    /// @notice Remove `lp` from the book by SWAP-AND-POP, keeping the 1-based index consistent.
    /// @dev    The moved element's index must be rewritten BEFORE the pop, and `lpIdx[lp] = 0` after,
    ///         or the book leaks a stale index that `trackOpen` would then treat as present.
    function untrackOpen(
        address[] storage openLps,
        mapping(address => uint256) storage lpIdx,
        address lp
    ) external {
        uint256 idx = lpIdx[lp];
        if (idx == 0) return;
        uint256 last = openLps.length;
        if (idx != last) { address moved = openLps[last - 1]; openLps[idx - 1] = moved; lpIdx[moved] = idx; }
        openLps.pop();
        lpIdx[lp] = 0;
    }

    // ── §FOLD-MEASURE BATCH 2 ──────────────────────────────────────────────────────────────────
    // MEASURED RATE FROM BATCH 1: moving `trackOpen`/`untrackOpen` (10 code lines) freed 212 bytes
    // on `LevManager` and 213 on `BtcLevManager` -- ~106 bytes PER BODY, per manager. The seam is
    // cheaper than duplication even for 5-line bodies, which refuted the prediction that a
    // delegatecall stub would exceed a short inlined body. Everything below follows that result.
    //
    // ⚠️ WHAT CANNOT MOVE, AND WHY IT IS A HARD LIMIT RATHER THAN A CHOICE: a library body cannot
    // read the caller's IMMUTABLES (`AUX`, `ORACLE_KEY` live in the caller's code, not its storage)
    // and cannot call the caller's VIRTUALS (`_collToBase`). So every value derived from those must
    // be computed by the caller and passed BY VALUE. That is exactly what `LevBase`'s own note
    // predicted. It is why `_reanchorIfReseated` takes `px` and `base` instead of reading them.

    event TargetSet(address indexed lp, uint256 targetLtvBps);
    event ReanchoredToBand(address indexed lp, uint entryPrice, uint256 e0);

    error NotOpen();
    error BadTarget();

    /// @notice An LP sets its own max-leverage LTV cap.
    /// @dev    `cap` is passed rather than read: `TARGET_LTV_CAP_BPS` is a caller CONSTANT, and a
    ///         constant lives in the caller's code. Passing it keeps ONE ceiling definition instead
    ///         of a second copy here that could silently diverge.
    function setTargetLtv(
        mapping(address => Types.Pos) storage pos,
        address lp,
        uint64 capBps,
        uint256 cap
    ) external {
        if (!pos[lp].open) revert NotOpen();
        if (capBps == 0 || capBps > cap) revert BadTarget();
        pos[lp].targetLtvCapBps = capBps;
        emit TargetSet(lp, capBps);
    }

    /// @notice Write a fresh position and enrol the LP, in one call.
    /// @dev    `bandPx` is passed because `_bandPrice()` try/catches a call to the caller's `BAND`.
    function openPos(
        mapping(address => Types.Pos) storage pos,
        address[] storage openLps,
        mapping(address => uint256) storage lpIdx,
        address lp,
        Types.Pos memory p
    ) external {
        pos[lp] = p;
        if (lpIdx[lp] == 0) { openLps.push(lp); lpIdx[lp] = openLps.length; }
    }

    /// @notice Re-anchor a position to the band's current price if the band has reseated.
    /// @dev    `px` and `base` are computed by the CALLER: `px` needs `AUX`/`ORACLE_KEY` (immutables)
    ///         and `base` needs `netEquity`, which routes through the `_collToBase` VIRTUAL. Neither
    ///         is reachable from here, and passing them is what lets the rest of the body be shared.
    ///         Returns whether it fired so the caller need not re-read to know.
    function reanchorIfReseated(
        mapping(address => Types.Pos) storage pos,
        address band,
        address lp,
        uint256 px,
        uint256 base
    ) external returns (bool fired) {
        Types.Pos storage q = pos[lp];
        if (!q.open) return false;
        (bool go, uint s) = LevMath.reanchorCompute(band, q.entryPrice);
        if (!go) return false;
        q.entryPrice    = s;
        q.entryPriceWad = uint128(px);
        q.e0            = uint128(base);
        emit ReanchoredToBand(lp, s, base);
        return true;
    }

    // ── §FOLD-LEGS — THE FOUR VENUE LEGS, ASSET-AGNOSTIC ─────────────────────────────────────────
    // These lived ONLY on `BtcLevManager` and read as BTC-specific. They are not: every one is a
    // generic venue operation whose sole asset-specific input is the COLLATERAL TOKEN, which is now a
    // parameter. `leverBorrow`/`repay` do not touch the collateral at all -- they move the venue's
    // STABLE in and out -- which is why the BTC lever cycle survived TriCrypto's removal untouched
    // while the ETH atomic path did not.
    //
    // ⚠️ EVENTS ARE DECLARED HERE AND STILL EMIT FROM THE MANAGER'S ADDRESS -- delegatecall preserves
    // `address(this)`. The topics are unchanged because the declarations are byte-identical to the
    // manager's, so no client ABI moves. If you edit an event here, you have edited the manager's ABI.
    //
    // ⚠️ `_syncBand` IS NOT CALLED FROM HERE. It try/catches a call to `BAND` and returning a flag for
    // the caller to act on would be the same code in a worse place, so the WRAPPER pokes the band
    // after this returns. That ordering matters: the poke must happen AFTER the venue state moves.

    event Borrowed(address indexed lp, uint stableOut);
    event Supplied(address indexed lp, uint vbtcIn);
    event Withdrawn(address indexed lp, uint vbtcOut);
    event Repaid(address indexed lp, uint stableIn);

    /// @notice Borrow the venue's stable toward the IL target and hand it to the LP.
    /// @dev    `room` is computed by the CALLER (`debtDeltaToTarget` routes through the `_collToBase`
    ///         virtual). Clamping `want` to `room` is what makes an over-ask harmless: it can only
    ///         reach the target, never pass it -- so this stays safe even though `stableUsd` is
    ///         caller-supplied.
    function leverBorrow(
        mapping(address => Types.Pos) storage pos,
        address aux, address lp, uint stableUsd, bool levUp, uint room
    ) external returns (uint got) {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        if (!levUp || room == 0) revert BadTarget();
        uint want = stableUsd > room ? room : stableUsd;
        got = q.venue.borrow(lp, LevMath._fromUsd(aux, q.venue.stable(), want));
        if (got > 0) IERC20Min(q.venue.stable()).transfer(lp, got);
        emit Borrowed(lp, got);
    }

    /// @notice Pull `amount` of COLLATERAL from the LP and supply it as isolated collateral.
    /// @param  coll the collateral token — weETH on the ETH side, vBTC on the BTC side. The ONLY
    ///         asset-specific input, and the reason this body was never BTC-specific.
    function leverSupply(
        mapping(address => Types.Pos) storage pos,
        address coll, address lp, uint amount
    ) external {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        IERC20Min(coll).transferFrom(lp, address(this), amount);
        IERC20Min(coll).transfer(address(q.venue), amount);
        q.venue.supply(lp, amount);
        emit Supplied(lp, amount);
    }

    /// @notice Withdraw collateral from the venue to the LP (to burn/sell externally, then repay).
    function deleverWithdraw(
        mapping(address => Types.Pos) storage pos,
        address coll, address lp, uint amount
    ) external returns (uint out) {
        if (!pos[lp].open) revert NotOpen();
        out = pos[lp].venue.withdraw(lp, amount);
        if (out > 0) IERC20Min(coll).transfer(lp, out);
        emit Withdrawn(lp, out);
    }

    /// @notice Repay debt from the LP's own stable.
    /// @dev    CAPPED AT `debtOf` BEFORE the transfer, so an over-repay cannot pull more stable than
    ///         the debt needs — the LP is never charged for value the venue will not credit. The
    ///         `amt == 0` early return still emits, so a no-op repay is observable rather than silent.
    function repay(
        mapping(address => Types.Pos) storage pos,
        address aux, address lp, uint stableUsd
    ) external returns (uint repaid) {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        uint amt = LevMath._fromUsd(aux, q.venue.stable(), stableUsd);
        uint debt = q.venue.debtOf(lp);
        if (amt > debt) amt = debt;
        if (amt == 0) { emit Repaid(lp, 0); return 0; }
        IERC20Min(q.venue.stable()).transferFrom(lp, address(q.venue), amt);
        repaid = q.venue.repay(lp, amt);
        emit Repaid(lp, repaid);
    }
}
