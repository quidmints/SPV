// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {NotOpen, BadTarget} from "./Types.sol";
import {ICore, IAux, ILevEquity} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";
import {SwapLib} from "./SwapLib.sol";
import {BasketLib} from "./BasketLib.sol";
import {SortedSetLib, OorBook} from "./Types.sol";

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
    using SortedSetLib for SortedSetLib.Set;

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
        uint bufUsd = levBufferUsd[lp];
        ICore(c.core).modLP(int256(grossRem), int256(bufUsd), address(0));   // LEAVES ⇒ positive, both legs
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

    /// @notice Close all or part of an out-of-range boundary order.
    /// @dev    MERGED PAIR, and this one was a PURE DUPLICATE: `QuidLib.pullBody` and
    ///         `BtcLib.pullBtc` were BYTE-IDENTICAL after normalising the storage PARAMETER
    ///         names (`selfManaged`/`selfManaged`, `positions`/`positions`) -- and those are
    ///         parameters, so the bodies never differed at all. Two deployed copies of one function
    ///         because the mappings they were handed had different names at the call site.

    /// @dev §E258 — `ix` was added so a full close also leaves the TRIGGER-PRICE INDEX. Without it
    ///      a pulled order stays in the sorted set, and the next sweep across its price reads a
    ///      deleted position: harmless today only because `fillOne` re-checks `amt`, which is
    ///      exactly the "two structures to keep in sync" shape the spec warned against. Removing it
    ///      here keeps the set and the book one thing.
    function pull(
        address core,
        OorBook storage book,
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
        if (percent == 100) {
            deindexOor(book, oorKey(oorTrigger(position), id));
            delete selfManaged[id];
            // ⚠️ `i < myIds.length`, NOT `i <= lastIndex` WITH A SATURATING `lastIndex`. The old form
            // computed `myIds.length > 0 ? myIds.length - 1 : 0`, so an EMPTY array gave `lastIndex == 0`
            // and the loop still ran once — reading `myIds[0]` and PANICKING (0x32) instead of reverting
            // cleanly. `fillOne` a few lines down already uses this bounded form against the same
            // mapping; the two disagreed about the same walk. One shape, and the empty case is a no-op.
            for (uint i = 0; i < myIds.length; i++) {
                if (myIds[i] == id) {
                    if (i < myIds.length - 1) myIds[i] = myIds[myIds.length - 1];
                    myIds.pop(); break;
                }
            }
        } else {
            position.amt -= closed;
            if (position.amt == 0) revert Dust();
        }
        ICore(core).outOfRange(owner, -closed, token);
    }

    // ═══════════════════ §E258 — RESTING BOUNDARY ORDERS EXECUTE AGAIN ═══════════════════
    //
    // The v4 cut removed the PoolManager, and with it the tick crossing that used to fill a
    // boundary order automatically as part of any swap through its range. Nothing replaced it:
    // `outOfRange` still created positions and `pull` still closed them, so every symbol a reader
    // would grep for was present and green. **A capability regression leaves no broken symbol to
    // find** — which is why this went a week unnoticed and why the mechanism is written here, next
    // to `pull`, rather than in a new file nobody looks at.
    //
    // It lives in this library and not in the range manager for the measured reason `pull` does:
    // `Quid` has ~600 bytes of EIP-170 margin and is the tightest contract in the tree, while a
    // delegatecalled body is deployed once and serves both ranges.

    /// Width of the id field in a packed index key. A trigger price is a WAD USD price (~2e21 for
    /// ETH, ~71 bits), so price and id share 256 bits with room to spare.
    uint private constant OOR_ID_BITS = 96;
    uint private constant OOR_ID_MASK = (1 << OOR_ID_BITS) - 1;

    /// @notice Pack an order's trigger price and id into one sortable key.
    /// @dev    The id is the LOW bits precisely so that ordering is by PRICE first: two orders at
    ///         the same trigger sort next to each other, and neither is lost. See the warning on
    ///         `State.oorBook` for what happens without it.
    function oorKey(uint triggerPrice, uint id) internal pure returns (uint) {
        return (triggerPrice << OOR_ID_BITS) | id;
    }

    /// @notice The price at which a resting order becomes fillable: its NEAR edge.
    /// @dev    A USD-funded order is a bid resting BELOW spot, so it is touched on the way down at
    ///         its `upper` edge; a volatile-funded order is an ask resting ABOVE spot and is touched
    ///         on the way up at its `lower` edge. Fill-on-touch means the order settles at the edge
    ///         the price actually reached — never at a better price it never traded through.
    function oorTrigger(Types.SelfManaged storage p) internal view returns (uint) {
        return p.usdFunded ? p.upper : p.lower;
    }

    /// @notice Record a freshly sized boundary order: the position, the owner's id list, and the
    ///         trigger-price index, in one place so the three cannot drift apart.
    /// @dev    The range managers used to inline this block and `BtcLib` still carries its twin. It
    ///         is here because `Quid` is the tightest contract in the tree under EIP-170 and a
    ///         struct construction plus two container writes is not a cheap thing to hold.
    function openOor(
        OorBook storage book,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint id, address owner, bool usdFunded, uint lower, uint upper, int amt
    ) public {
        selfManaged[id] = Types.SelfManaged({
            created: block.number, owner: owner, usdFunded: usdFunded,
            lower: lower, upper: upper, amt: amt });
        positions[owner].push(id);
        // Indexed by the TRIGGER price — the NEAR edge, the one the price has to touch.
        book.index.insert(oorKey(usdFunded ? upper : lower, id));
    }

    /// @notice Drop an order from the index when its owner closes it out entirely.
    /// @dev    Idempotent by inspection rather than by `try`: `SortedSetLib.remove` REVERTS on a
    ///         value that is not present ("Value does not exist"), and a partial `pull` leaves the
    ///         order resting, so an unconditional remove here would revert every partial close.
    function deindexOor(OorBook storage book, uint key) public {
        if (book.index.exists[key]) book.index.remove(key);
    }

    /// @notice Consume every resting order whose trigger the price has crossed since the last sweep.
    /// @param  pxNew the price the range is at now; the interval swept runs from the stored watermark.
    /// @param  maxFills the per-call cap. ⚠️ **THIS CAP IS WHY `fillOne` MUST BE PERMISSIONLESS.**
    ///         An unbounded sweep is a griefing vector — anyone can rest a crowd of cheap orders in
    ///         the path and make the next swapper pay to execute all of them — so the sweep stops
    ///         early by design, and something else has to be able to drain the remainder. The poke
    ///         is a LIVENESS REQUIREMENT created by this cap, not a convenience.
    /// @return filled how many orders were consumed.
    function sweepOor(
        address core,
        OorBook storage book,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint pxNew, uint maxFills
    ) public returns (uint filled) {
        uint pxOld = book.lastSweptPx;
        book.lastSweptPx = pxNew;
        // THE FIRST CALL SEEDS THE WATERMARK, IT DOES NOT FILL. At `pxOld == 0` the crossed interval
        // would be `(0, pxNew]`, which contains the trigger of every resting bid in the book — so a
        // fresh deploy would execute the entire bid side on its first swap, at prices nothing ever
        // touched. Seeding is the whole reason the watermark is stored rather than derived.
        if (pxOld == 0 || pxOld == pxNew) return 0;
        (uint lo, uint hi) = pxOld < pxNew ? (pxOld, pxNew) : (pxNew, pxOld);
        // A MEMORY SNAPSHOT, DELIBERATELY. `SortedSetLib.remove` compacts the array on every
        // removal, so iterating the STORAGE array while filling would renumber the indices under
        // the loop and skip orders. The snapshot is taken once and each key is looked up by value.
        uint[] memory keys = book.index.getSortedSet();
        (uint i,) = book.index.binarySearch(oorKey(lo, 0));
        uint stop = oorKey(hi, OOR_ID_MASK);
        for (; i < keys.length && filled < maxFills; i++) {
            uint k = keys[i];
            if (k > stop) break;
            if (fillOne(core, book, selfManaged, positions, k & OOR_ID_MASK)) filled++;
        }
    }

    /// @notice §E258 — THE PERMISSIONLESS POKE. Execute one resting order whose price has been
    ///         reached, for callers that are not a swap.
    /// @dev    **A LIVENESS REQUIREMENT, NOT A CONVENIENCE.** `sweepOor` is capped so a crowd of
    ///         cheap resting orders cannot be used to grief the next swapper, which means something
    ///         must be able to drain the remainder. It also covers the case no swap can: `repack`
    ///         moves the range with no swapper present to carry a sweep.
    ///         Anyone may call it, and that is safe because the order settles at ITS OWN limit
    ///         price — the caller chooses the timing, never the terms.
    /// ⚠️      NO TIP IS PAID. Sizing one means deciding where the difference between the order's
    ///         limit price and the range's price accrues, which is exactly the question §E258's spec
    ///         leaves to #12. Booked as §E258-POKE-INCENTIVE rather than guessed at here.
    function pokeOor(
        address core, address aux, address asset,
        OorBook storage book,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint id
    ) public {
        Types.SelfManaged storage p = selfManaged[id];
        if (p.amt <= 0) revert NoSuchOrder();
        uint px = IAux(aux).getTWAPforAsset(asset, 1800);
        // The price must actually have REACHED the order: a bid fills on the way down through its
        // upper edge, an ask on the way up through its lower edge.
        if (p.usdFunded ? px > p.upper : px < p.lower) revert NotTouched();
        if (!fillOne(core, book, selfManaged, positions, id)) revert NotFillable();
    }

    /// @notice Execute ONE resting order against the range's own inventory, at the order's own price.
    ///
    /// @dev    ⚠️ `pull`'s 47-block guard is DELIBERATELY ABSENT. That rule is an anti-gaming bound
    ///         on an OWNER-INITIATED close; an execution is not a withdrawal, and applying it here
    ///         would make every order unfillable for its first 47 blocks — reinstating exactly the
    ///         "no execution guarantee at the moment of crossing" defect this exists to remove.
    ///
    /// @dev    THE ORDER SETTLES AT ITS OWN LIMIT PRICE, NOT AT THE RANGE'S FILL PRICE. That is the
    ///         whole difference between a limit order and a participant in the swap. ⚠️ **WHERE THE
    ///         DIFFERENCE BETWEEN THE TWO ACCRUES IS NOT DECIDED HERE, ON PURPOSE** — it is the same
    ///         question as `SwapLib`'s two suppliers (LP inventory vs basket capital) and is
    ///         flagged there as having to be settled WITH #12. `OorFilled` carries both prices so
    ///         the quantity is observable while the split is still open; inventing an answer here
    ///         would bake it into the share maths before the question is asked.
    ///
    /// @dev    A fill the range cannot pay for is SKIPPED, not reverted — the order simply stays
    ///         resting and remains fillable later. Reverting would let one unfundable order block
    ///         the whole sweep, and with it the swap that carries it.
    function fillOne(
        address core,
        OorBook storage book,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        uint id
    ) public returns (bool) {
        Types.SelfManaged storage p = selfManaged[id];
        int amt = p.amt;
        if (amt <= 0) return false;                     // already closed, or never existed
        uint size = uint(amt);
        uint limitPx = oorTrigger(p);
        address owner = p.owner;
        bool usdFunded = p.usdFunded;

        // The order's funded side ENTERS the range and the other side LEAVES it, at `limitPx`.
        // Signs follow `_handleDelta`'s one rule: positive LEAVES the pool, negative ENTERS it.
        int usdDelta;
        int volDelta;
        if (usdFunded) {                                 // a resting bid: USD in, volatile out
            uint volOut = BasketLib.convert(size, limitPx, true);
            if (volOut == 0 || volOut > ICore(core).POOLED()) return false;
            usdDelta = -int(size);
            volDelta =  int(volOut);
        } else {                                         // a resting ask: volatile in, USD out
            uint usdOut = BasketLib.convert(size, limitPx, false);
            if (usdOut == 0 || usdOut > ICore(core).POOLED_USD()) return false;
            usdDelta =  int(usdOut);
            volDelta = -int(size);
        }

        // Remove BEFORE the settlement call, which pays the owner: state-before-external-call, so a
        // re-entrant fill of the same id finds `amt == 0` and returns false rather than paying twice.
        deindexOor(book, oorKey(limitPx, id));
        delete selfManaged[id];
        uint[] storage myIds = positions[owner];
        for (uint j = 0; j < myIds.length; j++) {
            if (myIds[j] == id) {
                if (j < myIds.length - 1) myIds[j] = myIds[myIds.length - 1];
                myIds.pop(); break;
            }
        }
        ICore(core).settleOor(owner, usdDelta, volDelta);
        emit OorFilled(id, owner, size, limitPx, usdFunded);
        return true;
    }

    /// @notice A resting order executed. `limitPx` is the price it settled at — its own, not the
    ///         range's — which is what makes the accrual question above measurable from logs.
    event OorFilled(uint indexed id, address indexed owner, uint size, uint limitPx, bool usdFunded);

    error NotOwner();
    error BadPercent();
    error Dust();
    error NoSuchOrder();
    error NotTouched();
    error NotFillable();



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
