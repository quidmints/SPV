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
/// @notice §RANGE-MERGE. `QuidLib` (ETH, 633 lines) and `BtcLib` (BTC, 623) are the ETH/BTC
///         pair of one logic. With `Types.RangeCfg`/`RangeP` shared, the pairs differ ONLY in their
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
///         copy serves both ranges — which is the whole size argument. An `internal` shared function
///         would inline into both libraries and buy nothing.
library RangeLib {

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
    /// @dev    MERGED PAIR. The only genuine difference was the SIZING CALL -- `ICore(this).addLiq`
    ///         on ETH versus the library-local `addLiqChannel` on BTC -- and that is now one method
    ///         on the range face (`ICore.addLiq`), because routing is exactly what belongs in the
    ///         range. The other three differences were drift: price passed vs read (read here,
    ///         once), `modLP` direct vs wrapped (direct), and the refresh placement (carried, see
    ///         `levBurnAll`).
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
    /// @dev    USD is the buffer collateral at range price CAPPED AT THE LP'S OWN DEBT. Both sides
    ///         already used `LevMath.capBufferUsd` for that -- BTC reached it through `_bufUsdBtc`,
    ///         a wrapper that read the price itself. One body, price passed in.
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

    /// @notice Add the LP's full-2x slice as BOTH legs.
    /// @dev    `ILevEquity` and `ILevEquityBtc` both declare `netEquity(address)`; the two bodies
    ///         differed only in which interface they cast through, for the same member.
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

    // ═══════════════════ §OOR-BOOK-DELETED (2026-08-29) ═══════════════════
    // The out-of-range BOOK lived here — `pull`, `openOor`, `sweepOor`, `pokeOor`, `fillOne`,
    // `deindexOor`, `oorKey`, `oorTrigger` and the packed-key constants. It is gone, and the
    // resting order it served is now a signed intent with ZERO on-chain footprint until it fills:
    // `SwapLib.fillIntentBody` + `Quid.fillIntent` (§OOR-AS-INTENT, `abb685c4`).
    //
    // ⭐ WHAT THE BOOK WAS AND WHY IT COULD NOT BE FIXED IN PLACE. §E258 built it because the v4
    //   cut removed the PoolManager and with it the tick crossing that used to fill a boundary
    //   order inside any swap through its range — *"a capability regression leaves no broken symbol
    //   to find"*. But `sweepOor` was only an EMULATION of that crossing: capped at four fills per
    //   swap, needing an unincentivised permissionless poke for the remainder, and — because
    //   `book.lastSweptPx` advanced UNCONDITIONALLY, before the first fill was attempted — dropping
    //   every order the cap or a short pool skipped out of all future sweeps
    //   (§OOR-WATERMARK-DROPS-ORDERS). It was paying for a fill guarantee it did not keep, in
    //   storage per resting order, in a public per-address link to intentions that might never
    //   fill, and in capital parked OUTSIDE the fee-earning share base the whole time it waited.
    // ⛔ DO NOT RESTORE IT. The property it emulated left with §V4-CUT, not with this deletion.















    /// @notice A resting order executed. `limitPx` is the price it settled at — its own, not the
    ///         range's — which is what makes the accrual question above measurable from logs.




    /// 🔴 §AUDIT-OPENLPS-DOS — THE CEILING ON THE OPEN-POSITION BOOK, AND WHY IT SITS AT THE PUSH.
    ///
    /// `_openLps` was UNBOUNDED and ATTACKER-GROWABLE, and it is walked in full by
    /// `totalDeliverableDollars`, `totalNetEquity`, `totalDebtUsd`, `totalGrossCollateral`,
    /// `LevManager.sweepDelever` and `SwapLib.deleverEthOnDelivery` — several of them on the money
    /// path of every deposit, withdraw and swap. Grow the book past what fits in a block and those
    /// stop being expensive and start being IMPOSSIBLE: the range halts for everyone.
    ///
    /// ⚠️ **THE BOUND CANNOT GO ON THE LOOPS, AND THAT IS THE WHOLE REASON IT IS HERE.** Truncating
    /// `totalNetEquity` or `totalDeliverableDollars` at N would not bound a cost — it would return
    /// a WRONG SMALLER NUMBER for the book's equity and deliverable dollars, silently, on the
    /// backing math. A gas clamp that under-reports backing is worse than the DoS it prevents.
    /// The only place a bound is both effective and truthful is the one write that makes the loops
    /// longer.
    ///
    /// ⚠️ **AND IT TRADES ONE DENIAL FOR A SMALLER ONE — SAY SO PLAINLY.** At the cap, a new LP
    /// cannot open until someone closes. An attacker can reach the cap for `MAX_OPEN_LPS ×
    /// MIN_OPEN_WEETH` (~6.4 weETH) of REAL collateral, at risk, in levered positions it must keep
    /// solvent. That buys "no new levered opens". Without the cap the same spend, continued, buys
    /// "no deposits, no withdrawals, no swaps, for anyone, permanently". The second is the one
    /// worth refusing. `MIN_OPEN_WEETH` is the dial that prices the first.
    ///
    /// ⛔ **THIS IS A CLAMP (standing rule 17) AND IT IS MEANT TO BE DELETED.** The root fix is to
    /// stop keeping one venue position PER LP at all — pool the venue exposure and hold per-LP
    /// SHARES of it, after which there is no book to walk, no cap to hit, and this whole seam
    /// (`_openLps`, `_lpIdx`, `trackOpen`, `untrackOpen`, four Σ-loops) goes away. Until that
    /// lands the range must not be haltable by a stranger with 7 ETH. When it lands, delete this.
    ///
    /// @dev 128 is chosen from the WORST loop, not the cheapest: `deleverEthOnDelivery` does
    ///      several external calls per LP (~50k gas) and, when nothing delivers, does them for
    ///      every entry — 128 × ~50k ≈ 6.4M, which fits a block with room for the swap that
    ///      triggered it. The Σ-views cost ~6k per entry (~0.8M). Raising this is a GAS
    ///      measurement, not a preference.
    // ✅ §AUDIT-OPENLPS-DOS — `MAX_OPEN_LPS = 128`, `error BookFull()` and `_requireRoom` are DELETED
    //    (2026-08-24), and this is standing rule 17 completing rather than a guard being dropped.
    //    The block that stood here said so itself: *"THIS IS A CLAMP AND IT IS MEANT TO BE DELETED.
    //    The root fix is to stop keeping one venue position PER LP at all — pool the venue exposure
    //    and hold per-LP SHARES of it, after which there is no book to walk, no cap to hit."*
    //    §POOL-VENUE did exactly that, so the condition the clamp named is met.
    // ⚠️ THE DELETION WAS GATED ON A MEASUREMENT, NOT ON THE COMMENT MATCHING. Checked first, and it
    //    was NOT safe on the first attempt: `LevManager.deleverBook` still walked the whole book on a
    //    state-changing path. Only after that and all four `LevBase` Sigma-loops became O(1) pool
    //    reads did `grep '_openLps.length'` return nothing but length checks, a push, a swap-and-pop
    //    and `openLevCount`. **A guard whose reason is still live must not be removed because its
    //    description matches.**
    // ⇒ WHAT THIS GIVES BACK: the cap traded one denial for a smaller one — at 128 open positions a
    //    new LP could not open until someone closed, and an attacker could reach that for ~6.4 weETH
    //    of real collateral. That griefing surface is gone with the loops it was protecting.

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
    // MEASURED RATE FROM BATCH 1: moving `trackOpen`/`untrackOpen` (10 code lines) freed 212 bytes
    // on `LevManager` and 213 on `BtcLevManager` -- ~106 bytes PER BODY, per manager. The seam is
    // cheaper than duplication even for 5-line bodies, which refuted the prediction that a
    // delegatecall stub would exceed a short inlined body. Everything below follows that result.
    //
    // ⚠️ WHAT CANNOT MOVE, AND WHY IT IS A HARD LIMIT RATHER THAN A CHOICE: a library body cannot
    // read the caller's IMMUTABLES (`AUX`, `ORACLE_KEY` live in the caller's code, not its storage)
    // and cannot call the caller's VIRTUALS (`_collToBase`). So every value derived from those must
    // be computed by the caller and passed BY VALUE. That is exactly what `LevBase`'s own note
    // predicted. It is why `_reanchorIfReseated` takes `base` instead of reading it.
    // ⚠️ IT TOOK `px` TOO UNTIL §C19. That argument was `AUX.getTWAPforAsset(...)` -- a LIVE ORACLE
    // READ ON EVERY RESEAT -- and its only use was `q.ilBasisPx = uint128(px)`, the write that made
    // the levered book inert. Deleting the write deleted the reason to read the oracle here at all.

    // §E358 — `TargetSet` DELETED with the per-LP cap it announced. An event nothing emits is
    // API surface telling a reader this contract has a setting it does not have.
    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);


    // §E358 — `setTargetLtv` DELETED: its only caller was `LevBase.setTargetLtv`, and an LP
    // choosing its own debt-to-collateral ratio is the thing protocol-wide IL-protect removes.

    /// @notice Write a fresh position and enrol the LP, in one call.
    /// @dev    `rangePx` is passed because `_rangePrice()` try/catches a call to the caller's `RANGE`.
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
        // §AUDIT-OPENLPS-DOS is CLOSED, and by deletion on both sides: there is no longer an
        // "other" push site (`trackOpen` was its own callerless duplicate and is gone), and no cap
        // to evade (`_requireRoom`/`MAX_OPEN_LPS` went with the Sigma-loops — see the tombstone above).
        // This is now the SOLE writer of the book.
        if (lpIdx[lp] == 0) { openLps.push(lp); lpIdx[lp] = openLps.length; }
    }

    /// @notice Re-anchor a position to the range's current price if the range has reseated.
    /// @dev    `px` and `base` are computed by the CALLER: `px` needs `AUX`/`ORACLE_KEY` (immutables)
    ///         and `base` needs `netEquity`, which routes through the `_collToBase` VIRTUAL. Neither
    ///         is reachable from here, and passing them is what lets the rest of the body be shared.
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
        // 🔴 §C19 — `q.ilBasisPx = uint128(px)` WAS HERE AND IT MADE THE LEVERED BOOK INERT.
        // `RANGE_ANCHOR = o.spotPrice` is unconditional (`Quid._rebalance`), so the range recenters on
        // spot at every repack and this reseat fires on any drift past `RANGE_DELTA` (20 bps). Writing
        // the CURRENT price into the IL basis then reset the very quantity the hedge measures: the
        // most IL that could ever accumulate was one half-range, `1 - sqrt(1/1.002)` = **9.99 bps**,
        // against `debtDelta`'s `RANGE_BPS` = **300 bps** deadband -- so `debtDelta` returned
        // `(false, 0)` on EVERY path and `venue.borrow` was UNREACHABLE BY CONSTRUCTION.
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
