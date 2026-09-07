// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {ICore, IAux, ILevEquity} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";
import {SwapLib} from "./SwapLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";

/// @title  RangeLib — the ONE implementation of each range-manager body, for both ranges.
///
/// @notice §RANGE-MERGE. ETH (`QuidLib`) and BTC (`BtcLib`) run the SAME range-manager logic over
///         the shared `Types.RangeCfg`/`RangeP`, so each body below is written once and called from
///         both. One shape for both sides: price is READ once per operation (`levAddGross`) and
///         passed down the legs, `ICore.modLP` is called directly, and the bookmark refresh is
///         carried on every leg unconditionally.
///
///         THE UNCONDITIONAL REFRESH IS THE ONE CHOICE THAT NEEDED AN ARGUMENT, AND IT HAS ONE:
///         within ONE transaction `feesPerShare` cannot move (it advances only on a swap/repack),
///         and `refreshBookmarks` ASSIGNS `fees_tok = weight · accum` rather than accumulating. So
///         an intermediate refresh is a NO-OP — BTC keeps the one it depends on, and ETH gets a
///         harmless second write that `Quid._onExit` then overwrites at the final weight.
///
/// @dev    `public`, not `internal`, ON PURPOSE. These bodies are delegatecalled, so one DEPLOYED
///         copy serves both ranges — which is the whole size argument. An `internal` shared function
///         would inline into both libraries and buy nothing.
library RangeLib {

    /// @notice Burn an LP's ENTIRE levered slice — both legs. Net equity leaves `pooled` (and so
    ///         the share count); the debt-funded buffer leaves the fee weight but was never equity.
    ///
    /// @dev    The `netRem > LP.pooled` clamp is NOT defensive padding: the net leg lives INSIDE
    ///         `pooled`, and burning past the position would take equity that is not levered.
    function levBurnAll(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.RangeP memory p
    ) public returns (uint netBurned, uint bufBurned) {
        uint netRem = levPooled[lp];
        if (netRem > LP.pooled) netRem = LP.pooled;
        bufBurned = levBuf[lp];
        uint grossRem = netRem + bufBurned;
        if (grossRem == 0) { levBufferUsd[lp] = 0; return (0, 0); }
        // 🔴 §BUF-USD-RATCHET — THE USD ARGUMENT WAS `0` AND THE BUFFER'S DOLLARS LEAKED.
        // `levAddBuf` pairs `bufUsd` INTO `POOLED_USD` (`modLP(-bufTok, -bufUsd)`); this burn zeroed
        // `levBufferUsd[lp]` in storage but passed `0` here, and `_settleUsdSide` does NOTHING on a
        // zero delta — the `deltaUSD == 0` flag `modLP` derives is `keep`, which only suppresses the
        // PAYOUT, it does not re-derive the amount. So the dollars stayed in `POOLED_USD` with no
        // per-LP record pointing at them, and every sync re-added a fresh buffer on top: a RATCHET,
        // not a one-off. Burning at the RECORDED figure is exact by construction — it is the same
        // number `levAddBuf` added — so this cannot over- or under-burn.
        // Measured (VBtcLevFeeLane, post-liquidation sync): POOLED_USD ROSE 388,270,880 across a
        // syncLev that must fall, and that is old bufUsd 776,542,536 − new 388,271,656 TO THE WEI.
        // 🔴 §DELIVER-BACKING — **THE TOKEN DELTA IS BOTH LEGS AND THE USD DELTA WAS ONE.** This
        //    passed `levBufferUsd[lp]` — the BUFFER's USD only — while `grossRem` is
        //    `netRem + bufBurned`, i.e. both legs' tokens. `levAddGross` then re-credits BOTH legs'
        //    USD (`levAddNet(netEq)` + `levAddBuf(gross − netEq)`, which correctly sum to `gross`),
        //    so every resync netted ONE LEG'S USD into `basketUsd` and nothing ever took it out.
        //    ⭐ MEASURED on a captured trace (`modLP` POSITIVE usd = BURN, NEGATIVE = MINT):
        //        BURN 1.495 BTC / $120,046   ← one leg's USD
        //        MINT 1.495 BTC / $120,046   ← net leg
        //        MINT 1.495 BTC / $120,046   ← buffer leg
        //      Tokens balance (1.495 out, 2.99 in — the buffer leg being established); USD does not
        //      ($120,046 out, $240,092 in). `basketUsd` 272,046 → 392,092 and
        //      `committed = basketUsd − levDebt` = 272,046 against a TVL of 157,000, so
        //      `require(committedUsd18() <= haircutTvl)` refuses — blocking the delivery that was
        //      de-levering. A liveness failure, not a solvency one.
        // ⇒ **DEBIT THE USD PROPORTIONAL TO THE TOKENS LEAVING — the SAME expression `burnInRange`
        //   already uses** (`fullMulDiv(basketUsd, pulled, pooled)`). `grossRem` is both legs, so this
        //   removes both legs' USD, and the resync becomes USD-NEUTRAL: what the burn takes out is
        //   what `levAddGross` puts back.
        // ⚠️ WHY PROPORTIONAL AND NOT `netEq + bufUsd`: `basketUsd` is the range's own accounting of
        //   the basket's claim, and every other burn in the system releases it pro-rata to the
        //   liquidity leaving. Reconstructing the two legs' USD from the manager would re-mark them
        //   at a fresh price mid-resync — two clocks in one operation, which is the §A.16b defect.
        // ⚠️ AND IT PRESERVES THE PINNED INVARIANT: `LevCascade` asserts
        //   `committedUsd18() + totalDebtUsd() == basketUsd * 1e12`, i.e. `basketUsd` DOES carry the
        //   debt-funded buffer and `committed` excludes it by subtracting the debt ONCE. That only
        //   holds if the resync neither creates nor destroys basket USD, which is what this restores.
        uint pooledTok = ICore(c.core).POOLED();
        uint usdOut = pooledTok == 0
            ? levBufferUsd[lp]
            : SoladyMath.fullMulDiv(ICore(c.core).basketUsd(), grossRem, pooledTok);
        ICore(c.core).modLP(int256(grossRem), int256(usdOut), address(0));   // LEAVES ⇒ positive, both legs
        LP.pooled -= netRem; levPooled[lp] -= netRem;      // net leg leaves pooled / the share count
        levBuf[lp] = 0; levBufferUsd[lp] = 0;              // buffer leg leaves the fee weight
        // `levBuf[lp]` is now 0, so the GROSS fee weight is simply `LP.pooled`. Safe on both sides:
        // an assignment at the same weight is idempotent, and the ETH path's `_onExit` overwrites
        // it at the final weight after the add legs run.
        SwapLib.refreshBookmarks(LP, LP.pooled, p.feesPerShare, p.usdFees);
        return (netRem, bufBurned);
    }

    /// @notice NET-EQUITY leg. Grows `pooled` (and so the share count) and the levered net slice.
    /// @dev    The sizing call is ONE method on the range face, `ICore.addLiq`, because routing the
    ///         deposit to the venue (pool on ETH, channel on BTC) is exactly what belongs in the
    ///         range rather than in this body. `price` is passed in, read once by the caller.
    function levAddNet(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        address lp, uint netEq, uint price, Types.RangeP memory p
    ) public returns (uint added) {
        if (netEq == 0 || price == 0) return 0;
        (uint netUsd, uint netTok) = ICore(address(this)).addLiq(netEq, price);
        if (netTok == 0) return 0;
        LP.pooled += netTok; levPooled[lp] += netTok;
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[lp], p.feesPerShare, p.usdFees);
        ICore(c.core).modLP(-int256(netTok), -int256(netUsd), lp);   // ENTERS ⇒ negative
        return netTok;
    }

    /// @notice BUFFER leg — the DEBT-FUNDED half. Fee-earning depth, never equity: it grows the fee
    ///         weight and the range position but NOT `pooled`/shares.
    /// @dev    USD is the buffer collateral at range price CAPPED AT THE LP'S OWN DEBT, which is
    ///         what `LevMath.capBufferUsd` does. `price` is passed in, read once by the caller.
    function levAddBuf(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, uint bufTok, uint price, Types.RangeP memory p
    ) public returns (uint added) {
        uint bufUsd = LevMath.capBufferUsd(bufTok, price, ILevEquity(p.mgr).debtUsd(lp));
        if (bufUsd == 0) return 0;
        levBuf[lp] += bufTok; levBufferUsd[lp] += bufUsd;
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[lp], p.feesPerShare, p.usdFees);
        ICore(c.core).modLP(-int256(bufTok), -int256(bufUsd), lp);   // ENTERS ⇒ negative
        return bufTok;
    }

    /// @notice Add the LP's full-2x slice as BOTH legs. This is where the range price is READ, once
    ///         per operation, and handed to both legs so they cannot disagree about it.
    function levAddGross(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.RangeP memory p
    ) public returns (uint addedNet, uint bufAdded) {
        if (p.gross == 0) return (0, 0);
        uint price = IAux(c.aux).getTWAPforAsset(c.asset, 1800);
        if (price == 0) return (0, 0);
        uint netEq = ILevEquity(p.mgr).netEquity(lp);
        addedNet = levAddNet(c, LP, levPooled, levBuf, lp, netEq, price, p);
        if (p.gross > netEq)
            bufAdded = levAddBuf(c, LP, levBufferUsd, levBuf, lp, p.gross - netEq, price, p);
    }

    // ═══════════════════════════════ §OOR-AS-INTENT ═══════════════════════════════
    // A resting out-of-range order has NO at-rest footprint here or anywhere else: it is a SIGNED
    // INTENT, and the only storage it ever touches is `Quid.intentUsed[owner][nonce]`, written AT
    // THE FILL by `Quid.fillIntent` → `SwapLib.fillIntentBody`.
    //
    // ⛔ DO NOT BUILD AN ON-CHAIN OUT-OF-RANGE BOOK HERE. The property such a book would emulate —
    //   the tick crossing that used to fill a boundary order inside any swap through its range —
    //   left with §V4-CUT (the PoolManager removed with it), and an emulation does not bring it
    //   back: it pays in storage per resting order, in a public per-address link to intentions that
    //   may never fill, and in capital parked OUTSIDE the fee-earning share base for the whole wait,
    //   while still needing an unincentivised permissionless poke for whatever a per-swap fill cap
    //   skipped — and a watermark that advances past skipped orders drops them silently.

    /// @notice Remove `lp` from the book by SWAP-AND-POP, keeping the 1-based index consistent.
    /// @dev    The moved element's index must be rewritten BEFORE the pop, and `lpIdx[lp] = 0` after,
    ///         or the book leaks a stale index that `openPos`'s push would then treat as present.
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
    // MEASURED RATE FROM BATCH 1: moving the book-enrolment bodies (10 code lines) freed 212 bytes
    // on `LevManager` and 213 on `BtcLevManager` -- ~106 bytes PER BODY, per manager. The seam is
    // cheaper than duplication even for 5-line bodies, which refuted the prediction that a
    // delegatecall stub would exceed a short inlined body. Everything below follows that result.
    //
    // ⚠️ WHAT CANNOT MOVE, AND WHY IT IS A HARD LIMIT RATHER THAN A CHOICE: a library body cannot
    // read the caller's IMMUTABLES (`AUX`, `ORACLE_KEY` live in the caller's code, not its storage),
    // and it cannot call back into the caller's own accessors over them (`netEquity`). So every value
    // derived from those must be computed by the caller and passed BY VALUE. That is exactly what
    // `LevBase`'s own note predicted, and it is why `reanchorIfReseated` takes `base` rather than
    // reading it.

    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);

    /// @notice Write a fresh position and enrol the LP, in one call.
    /// @dev    `p.syncKeyPx` arrives already filled by the caller (`LevBase._openPos` reads it from
    ///         `_rangePrice()`), which try/catches a call to the caller's `RANGE` immutable — not
    ///         reachable from here. The whole `Types.Pos` comes in as one memory pointer so the seam
    ///         carries a pointer rather than five scalars.
    function openPos(
        mapping(address => Types.Pos) storage pos,
        address[] storage openLps,
        mapping(address => uint256) storage lpIdx,
        address lp,
        Types.Pos memory p
    ) external {
        // ⚠️ §E339 — WHOLESALE OVERWRITE, AND IT IS ONLY SAFE BECAUSE TOP-UPS ARE REFUSED.
        // `LevManager.openLev` reverts `AlreadyOpen` on a second open, so `lp` is always fresh here and
        // there is nothing to blend. THE DAY A TOP-UP PATH EXISTS, this line silently re-anchors
        // `ilBasisPx`: top up after a rise and the LP destroys its own protection (it is 0 at/below
        // entry); dust top-up at a low and the protocol pays protection nobody bought. Both directions
        // are wrong and the second is an attack. ⇒ Blend `ilBasisPx` SIZE-WEIGHTED here, in the SAME
        // commit that opens the path — the defect is this assignment, not its caller. No blending is
        // added now because the branch would be unreachable (standing rule 1).
        pos[lp] = p;
        // THE SOLE PUSH SITE. This line and `untrackOpen`'s swap-and-pop are the only two writers of
        // `openLps`/`lpIdx` anywhere in the tree, and there is no cap on the length: the Sigma-loops
        // that made a long book expensive are O(1) pool reads since §POOL-VENUE. The `lpIdx[lp] == 0`
        // test is what makes the push idempotent for an LP already enrolled.
        if (lpIdx[lp] == 0) { openLps.push(lp); lpIdx[lp] = openLps.length; }
    }

    /// @notice Re-anchor a position to the range's current price if the range has reseated.
    /// @dev    `base` is computed by the CALLER — it is `netEquity(lp)`, which reads the caller's
    ///         `AUX`/`ORACLE_KEY` immutables and so is not reachable from here. Passing it by value
    ///         is what lets the rest of the body be shared. No price is passed or read: the reseat
    ///         re-bases the seat and the equity, never the entry price.
    ///         Returns whether it fired so the caller need not re-read to know.
    function reanchorIfReseated(
        mapping(address => Types.Pos) storage pos,
        address range,
        address lp,
        uint256 base
    ) external returns (bool fired) {
        Types.Pos storage q = pos[lp];
        if (!q.open) return false;
        (bool go, uint s) = LevMath.reanchorCompute(range, q.syncKeyPx);
        if (!go) return false;
        q.syncKeyPx    = s;
        // ⛔ §C19 — DO NOT WRITE `q.ilBasisPx` HERE. IT MAKES THE LEVERED BOOK INERT.
        // `RANGE_ANCHOR = o.spotPrice` is unconditional (`Quid._rebalance:1481`), so the range recenters
        // on spot at every repack and this reseat fires on any drift past `RANGE_DELTA` (20 bps).
        // Re-basing the IL basis on each reseat resets the very quantity the hedge measures, capping
        // the most IL that can ever accumulate at ONE HALF-RANGE, `1 - sqrt(1/1.002)` = **9.99 bps**.
        // Any no-trade band wider than that then makes `debtDelta` return `(false, 0)` on EVERY path,
        // and `venue.borrow` is UNREACHABLE BY CONSTRUCTION -- silently, because nothing reverts.
        // (`debtDelta` takes its `rangeBps` as an argument now, sized per position by
        // `LevBase._bandBps`, so the exact width is not fixed here -- but it is not 10 bps.)
        // ⚠️ THE INVARIANT THAT DEFENDS THIS RESEAT COVERS `entryEquity` ONLY. It reads: levering
        // moves collateral and debt by the SAME amount, so NET EQUITY is leverage-invariant -- true,
        // and it says nothing about a PRICE basis. A leverage-invariant equity base does not imply a
        // resettable price base, and the note has been read as blessing both.
        // ⇒ The seat moved, so `syncKeyPx` is re-based; the equity is leverage-invariant, so
        //   `entryEquity` is re-based. THE ENTRY PRICE IS NEITHER, so it stays pinned at open.
        q.entryEquity            = uint128(base);
        emit ReanchoredToRange(lp, s, base);
        return true;
    }
}
