// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types, NotOpen, BadTarget} from "./Types.sol";
import {ILevVenue, IERC20Min} from "./ILevVenue.sol";
import {ICore, IBand, IAux, ILevEquity} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";
import {SwapLib} from "./SwapLib.sol";
import {QuidLib} from "./QuidLib.sol";

/// @title  BandLib — the ONE implementation of each band-manager body, for both bands.
///
/// @notice §BAND-MERGE. `QuidLib` (ETH, 633 lines) and `BtcLib` (BTC, 623) are the ETH/BTC
///         pair of one logic. With `Types.BandCfg`/`BandP` shared, the pairs differ ONLY in their
///         bodies, and diffing them showed FOUR kinds of difference of which THREE are drift:
///
///           • price passed as a parameter (ETH) vs read internally (BTC)
///           • `ICore.modLP` called directly (ETH) vs through a one-line extracted wrapper (BTC)
///           • `ILevEquity` vs `ILevEquityBtc` for the SAME `netEquity` member
///           • bookmark refresh at end-of-operation (ETH `_onExit`) vs inline per leg (BTC)
///
///         Only the fourth needed an argument rather than a decision, and it has one: within ONE
///         transaction `feesPerShare` cannot move (it advances only on a swap/repack), and
///         `refreshBookmarks` ASSIGNS `fees_tok = weight · accum` rather than accumulating. So an
///         extra intermediate refresh is a NO-OP, and the merged body can carry the refresh
///         unconditionally: BTC keeps the one it depends on, ETH gets a harmless second write that
///         its own `_onExit` then overwrites at the final weight.
///
/// @dev    `public`, not `internal`, ON PURPOSE. These bodies are delegatecalled, so one DEPLOYED
///         copy serves both bands — which is the whole size argument. An `internal` shared function
///         would inline into both libraries and buy nothing.
library BandLib {

    /// @notice Burn an LP's ENTIRE levered slice — both legs. Net equity leaves `pooled` (and so
    ///         the share count); the debt-funded buffer leaves the fee weight but was never equity.
    ///
    /// @dev    THE MERGED PAIR: `QuidLib.levBurnAll` ∥ `BtcLib.levBurnAllBtc` were line-for-
    ///         line identical apart from (a) BTC routing `modLP` through `_burnLpBtc`, a one-line
    ///         wrapper whose `p` argument was UNUSED, and (b) BTC's trailing refresh. Both resolved
    ///         above, so this is one body rather than a parameterised compromise.
    /// @dev    The `netRem > LP.pooled` clamp is NOT defensive padding: the net leg lives INSIDE
    ///         `pooled`, and burning past the position would take equity that is not levered.
    function levBurnAll(
        Types.BandCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.BandP memory p
    ) public returns (uint netBurned, uint bufBurned) {
        uint netRem = levPooled[lp];
        if (netRem > LP.pooled) netRem = LP.pooled;
        bufBurned = levBuf[lp];
        uint grossRem = netRem + bufBurned;
        if (grossRem == 0) { levBufferUsd[lp] = 0; return (0, 0); }
        ICore(c.core).modLP(int256(grossRem), 0, address(0));   // LEAVES ⇒ positive: tokenless burn of GROSS depth
        LP.pooled -= netRem; levPooled[lp] -= netRem;      // net leg leaves pooled / the share count
        levBuf[lp] = 0; levBufferUsd[lp] = 0;              // buffer leg leaves the fee weight
        // `levBuf[lp]` is now 0, so the GROSS fee weight is simply `LP.pooled`. Safe on both sides:
        // an assignment at the same weight is idempotent, and the ETH path's `_onExit` overwrites
        // it at the final weight after the add legs run.
        SwapLib.refreshBookmarks(LP, LP.pooled, p.feesPerShare, p.usdFees);
        return (netRem, bufBurned);
    }

    /// @notice NET-EQUITY leg. Grows `pooled` (and so the share count) and the levered net slice.
    /// @dev    MERGED PAIR. The only genuine difference was the SIZING CALL -- `IQuid(this).addLiq`
    ///         on ETH versus the library-local `addLiqChannel` on BTC -- and that is now one method
    ///         on the band face (`IBand.addLiq`), because routing is exactly what belongs in the
    ///         band. The other three differences were drift: price passed vs read (read here,
    ///         once), `modLP` direct vs wrapped (direct), and the refresh placement (carried, see
    ///         `levBurnAll`).
    function levAddNet(
        Types.BandCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        address lp, uint netEq, uint price, Types.BandP memory p
    ) public returns (uint added) {
        if (netEq == 0 || price == 0) return 0;
        (uint netUsd, uint netTok) = IBand(address(this)).addLiq(netEq, price);
        if (netTok == 0) return 0;
        LP.pooled += netTok; levPooled[lp] += netTok;
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[lp], p.feesPerShare, p.usdFees);
        ICore(c.core).modLP(-int256(netTok), -int256(netUsd), lp);   // ENTERS ⇒ negative
        return netTok;
    }

    /// @notice BUFFER leg — the DEBT-FUNDED half. Fee-earning depth, never equity: it grows the fee
    ///         weight and the band position but NOT `pooled`/shares.
    /// @dev    USD is the buffer collateral at band price CAPPED AT THE LP'S OWN DEBT. Both sides
    ///         already used `LevMath.capBufferUsd` for that -- BTC reached it through `_bufUsdBtc`,
    ///         a wrapper that read the price itself. One body, price passed in.
    function levAddBuf(
        Types.BandCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, uint bufTok, uint price, Types.BandP memory p
    ) public returns (uint added) {
        uint bufUsd = LevMath.capBufferUsd(bufTok, price, ILevEquity(p.mgr).debtUsd(lp));
        if (bufUsd == 0) return 0;
        levBuf[lp] += bufTok; levBufferUsd[lp] += bufUsd;
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[lp], p.feesPerShare, p.usdFees);
        ICore(c.core).modLP(-int256(bufTok), -int256(bufUsd), lp);   // ENTERS ⇒ negative
        return bufTok;
    }

    /// @notice Add the LP's full-2x slice as BOTH legs.
    /// @dev    `ILevEquity` and `ILevEquityBtc` both declare `netEquity(address)`; the two bodies
    ///         differed only in which interface they cast through, for the same member.
    function levAddGross(
        Types.BandCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.BandP memory p
    ) public returns (uint addedNet, uint bufAdded) {
        if (p.gross == 0) return (0, 0);
        uint price = IAux(c.aux).getTWAPforAsset(c.asset, 1800);
        if (price == 0) return (0, 0);
        uint netEq = ILevEquity(p.mgr).netEquity(lp);
        addedNet = levAddNet(c, LP, levPooled, levBuf, lp, netEq, price, p);
        if (p.gross > netEq)
            bufAdded = levAddBuf(c, LP, levBufferUsd, levBuf, lp, p.gross - netEq, price, p);
    }

    /// @notice Close all or part of an out-of-range boundary order.
    /// @dev    MERGED PAIR, and this one was a PURE DUPLICATE: `QuidLib.pullBody` and
    ///         `BtcLib.pullBtc` were BYTE-IDENTICAL after normalising the storage PARAMETER
    ///         names (`selfManaged`/`selfManaged`, `positions`/`positions`) -- and those are
    ///         parameters, so the bodies never differed at all. Two deployed copies of one function
    ///         because the mappings they were handed had different names at the call site.

    function pull(
        address core,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint id, int percent, address token, address owner
    ) public {
        Types.SelfManaged storage position = selfManaged[id];
        if (position.owner != owner) revert NotOwner();
        require(block.number >= position.created + 47, "too soon");
        if (percent == 0 || percent > 100) revert BadPercent();
        int closed = position.amt * percent / 100;
        if (closed == 0) revert Dust();
        uint lower = position.lower;
        uint upper = position.upper;
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
            position.amt -= closed;
            if (position.amt == 0) revert Dust();
        }
        ICore(core).outOfRange(owner, -closed, lower, upper, token);
    }

    error NotOwner();
    error BadPercent();
    error Dust();


    // ═══════════════ §FOLD-BOOK — WAS `LevBookLib`'s POSITION BOOK (2026-08-19) ═══════════════
    // Band-neutral: reached from `LevBase`, so it serves BOTH lev managers. Lands here rather than
    // in `LevMath` for the size reason recorded above, and `LevBase` therefore links `BandLib`.

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
