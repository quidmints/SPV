// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";

/// @title  LevBookLib — the open-position BOOK, as a delegatecalled library
/// @notice §FOLD-MEASURE. `LevBase` is an ABSTRACT BASE, so every body in it is COMPILED INTO BOTH
///         `LevManager` AND `BtcLevManager`. A delegatecalled library's bodies live in the library's
///         OWN deployed bytecode and cost each caller only a jump + argument marshalling.
///         This library exists to MEASURE that trade at the smallest honest scale: the two book
///         mutators, which need no events, no immutables and no virtual dispatch, so nothing but the
///         seam cost distinguishes the two shapes.
/// @dev    Storage is passed by REFERENCE (`address[] storage`, `mapping storage`) — the same
///         technique `ChannelLib.initVaultsBody` and `VogueLib` already use in this tree, which is
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
}
