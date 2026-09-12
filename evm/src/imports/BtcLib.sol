// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";
import {NotOpen, BadTarget} from "./Types.sol";
import { IERC20Min } from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {LevMath} from "./LevMath.sol";
import {ICore} from "./Interfaces.sol";
import {IBasket} from "./Interfaces.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";

library BtcLib {

    error ZeroTwap();
    error InsufficientChannelBtc();

    function settleBtcLp(
        Types.Deposit storage LP,
        address payTo, address quid,
        uint usdFees, uint weight
    ) public {
        // §BTC-10b(c)+(d). This RETURNED `compoundedSats` — the native fee leg compounded into
        // shares — and it was always ZERO, because `feesPerShare` has no writer left: its only
        // increments were `+= o.feesPerShareInc`, and that field was never assigned. So
        // `pendingFor`'s `tokReward` is identically 0 and the `if (tokR > 0)` branch was
        // unreachable.
        // 🔑 **DELETING THE RETURN IS THE ROOT FIX FOR THE EXIT-PATH MINT, NOT A TIDY-UP.**
        // `_resize` did `lpShares = lpShares + o.feeCompounded - o.sharesRemoved`, and
        // `feeCompounded` was a MINT on a path that never calls `checkBacking()` —
        // `requestDeposit` has that check, the exit does not. It was safe only because this value
        // could not be non-zero, i.e. two dead things were making each other safe. Adding a guard
        // would have held the mint; removing the mint means there is nothing left to guard, and
        // reviving the fee feed cannot silently re-arm it.
        if (weight == 0) return;
        uint usdR = SwapLib.pendingFor(LP, weight, usdFees);
        if (payTo != address(0)) {
            usdR += LP.usd_owed;
            LP.usd_owed = 0;

            if (usdR > 0) IBasket(quid).mint(payTo, usdR * 1e12, quid, 0);
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
        SwapLib.refreshBookmarks(LP, weight, usdFees);
    }

    function settleDelivered(address lpEth, uint deliveredRaw, uint exactUsd,
        address core, address quid) public returns (uint deliveredSlice) {
        deliveredSlice = deliveredRaw;
        if (exactUsd == 0) return deliveredSlice;
        ICore(core).drawPooledUsdBtc(exactUsd);
        ICore(core).subPendingSwapOut(exactUsd);
        IBasket(quid).mint(lpEth, exactUsd * 1e12, quid, 0);
    }

    function addLiqChannel(address core, address aux, uint sats, uint price)
        public returns (uint usdOut, uint outDelta) {

        return SwapLib.addLiqBody(core, aux, sats, price,
            ICore(core).btcBacking() + sats);
    }

    struct ResizeArgs {
        address lpEth;
        uint    shrinkSats;
        uint    lpPayoutSats;
        bool    full;
        uint    exactUsd;
        uint    inrange;
        uint    lev;
        uint    buf;
        uint spotPrice;
        uint    loPrice;
        uint    upPrice;
        uint    usdFees;
    }

    struct ResizeOut { uint sharesRemoved; bool cleared; uint bufRemoved; }

    function resizeBtcLpTail(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        ResizeArgs memory a
    ) public returns (ResizeOut memory o) {
        Types.Deposit storage LP = autoManaged[a.lpEth];
        {

            settleBtcLp(LP, a.lpEth, quid, a.usdFees, LP.pooled + a.buf);
            uint deliveredRaw = a.shrinkSats > a.lpPayoutSats ? a.shrinkSats - a.lpPayoutSats : 0;
            uint deliveredSlice = settleDelivered(a.lpEth, deliveredRaw, a.exactUsd, core, quid);
            uint nativeSlice = a.shrinkSats - deliveredSlice;
            SwapLib.burnInRange(core, nativeSlice, address(0));

            if (a.full && a.lev > 0)
                SwapLib.burnInRange(core, a.lev, address(0));
            if (a.full && a.buf > 0) {
                SwapLib.burnInRange(core, a.buf, address(0));
                o.bufRemoved = a.buf;
            }
        }

        o.sharesRemoved = a.full ? LP.pooled : a.shrinkSats;
        LP.pooled -= o.sharesRemoved;
        if (a.full) { levPooled[a.lpEth] = 0; levBuf[a.lpEth] = 0; }

        if (LP.pooled == 0) {
            delete autoManaged[a.lpEth];
            o.cleared = true;
        } else {

            SwapLib.refreshBookmarks(LP, LP.pooled + a.buf, a.usdFees);
        }
    }

    function resize(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd
    ) public returns (ResizeOut memory o) {

        ResizeArgs memory a;
        a.lpEth = lpEth; a.lpPayoutSats = lpPayoutSats; a.full = full; a.exactUsd = exactUsd;
        a.inrange = autoManaged[lpEth].pooled;
        a.lev = levPooled[lpEth];
        a.buf = levBuf[lpEth];
        {
            uint funded = a.inrange > a.lev ? a.inrange - a.lev : 0;
            if (funded == 0 && a.lev == 0 && a.buf == 0) return o;
            if (full) {
                a.shrinkSats = funded;
            } else {
                if (shrinkSats == 0) return o;
                a.shrinkSats = shrinkSats > funded ? funded : shrinkSats;
            }
        }
        (a.spotPrice, a.loPrice, a.upPrice,,) = ICore(address(this)).repack();
        a.usdFees = ICore(address(this)).USD_FEES();
        return resizeBtcLpTail(core, quid, autoManaged, levPooled, levBuf, a);
    }

    struct LevDelta { uint addedNet; uint burnedNet; uint bufAdded; uint bufBurned; }

    function requestDeposit(
        Types.RangeCfg memory c,
        Types.Deposit storage LP,
        address lpEth, uint sats, address quid, uint weight
    ) public returns (uint sharesAdded) {

        if (sats == 0 || lpEth == address(0)) return 0;
        IAux(c.aux).checkBacking();

        Types.RangeP memory p;

        (p.spotPrice, p.loPrice, p.upPrice,,) = ICore(address(this)).repack();
        p.usdFees = ICore(address(this)).USD_FEES();
        p.buf = weight - LP.pooled;
        settleBtcLp(LP, address(0), quid, p.usdFees, weight);

        uint price = IAux(c.aux).assetPrice(IAux(c.aux).WBTC());
        if (price == 0) revert ZeroTwap();
        (uint deltaUSD, uint deltaBTC) = addLiqChannel(c.core, c.aux, sats, price);

        if (deltaBTC > 0) sharesAdded += _pairRegLeg(c.core, LP, p, deltaBTC, deltaUSD, lpEth);
        uint unpaired = sats - deltaBTC;
        if (unpaired > 0) {

            LP.pooled += unpaired; sharesAdded += unpaired;

            SwapLib.refreshBookmarks(LP, LP.pooled + p.buf, p.usdFees);
        }
    }

    function _pairRegLeg(
        address core, Types.Deposit storage LP, Types.RangeP memory p,
        uint deltaBTC, uint deltaUSD, address lpEth
    ) private returns (uint) {
        LP.pooled += deltaBTC;

        SwapLib.refreshBookmarks(LP, LP.pooled + p.buf, p.usdFees);
        ICore(core).modLP(-int256(deltaBTC), -int256(deltaUSD), lpEth);
        return deltaBTC;
    }

    function syncLev(
        Types.RangeCfg memory c,
        Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, address mgr, address quid
    ) public returns (LevDelta memory d) {

        uint gross = mgr == address(0) ? 0 : ILevEquity(mgr).grossCollateral(lp);

        if (gross == 0 && levPooled[lp] == 0 && levBuf[lp] == 0 && levBufferUsd[lp] == 0) return d;
        if (gross == levPooled[lp] + levBuf[lp] &&
            levBufferUsd[lp] == (mgr == address(0) ? 0 : ILevEquity(mgr).debtUsd(lp) / 1e12)) return d;

        uint w = LP.pooled + levBuf[lp];
        Types.RangeP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = ICore(address(this)).repack();
        p.usdFees = ICore(address(this)).USD_FEES();
        p.mgr = mgr; p.gross = gross;

        settleBtcLp(LP, address(0), quid, p.usdFees, w);
        (d.burnedNet, d.bufBurned) = RangeLib.levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        (d.addedNet, d.bufAdded)   = RangeLib.levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
    }

    function vbtcExposeBody(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        address lp, uint sats
    ) public {
        uint pooled = autoManaged[lp].pooled;
        uint free = SwapLib.plainNet(pooled, levPooled[lp]);
        if (sats == 0 || sats > free) revert InsufficientChannelBtc();
        levPooled[lp] += sats;
    }

    function vbtcUnexposeBody(
        mapping(address => uint) storage levPooled,
        address lp, uint sats
    ) public {
        uint lev = levPooled[lp];
        levPooled[lp] = sats >= lev ? 0 : lev - sats;
    }

    function transferSharesBody(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levBuf,
        address from, address to, uint amount,
        uint usdFees, address quid
    ) public {
        // §BTC-10b(c). This returned a share DELTA that was only ever the dead fee-compounding
        // amount, so the caller's `lpShares += …` added zero. ⭐ And a transfer must not move total
        // supply at all — it moves `L.pooled` to `R.pooled` — so removing the return does not just
        // delete a no-op, it makes that invariant visible instead of arithmetic nobody can check.
        if (to == address(0) || from == to) revert BadTarget();
        if (amount == 0) return;
        Types.Deposit storage L = autoManaged[from];

        settleBtcLp(L, address(0), quid, usdFees, L.pooled + levBuf[from]);
        Types.Deposit storage R = autoManaged[to];
        if (R.pooled > 0)
            settleBtcLp(R, address(0), quid, usdFees, R.pooled + levBuf[to]);
        L.pooled -= amount; R.pooled += amount;
        SwapLib.refreshBookmarks(L, L.pooled + levBuf[from], usdFees);
        SwapLib.refreshBookmarks(R, R.pooled + levBuf[to], usdFees);
    }

    struct RebalOut {
        uint spotPrice; uint    loPrice; uint    upPrice; uint myLiquidity; uint anchorPrice;
    }

    function rebalanceBody(
        Types.RangeCfg memory c, uint loPrice, uint upPrice
    ) public returns (RebalOut memory o) {

        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, IAux(c.aux).WBTC(), upPrice, loPrice);

        o.spotPrice = r.spotPrice; o.loPrice = r.loPrice; o.upPrice = r.upPrice;
        o.myLiquidity = r.myLiquidity; o.anchorPrice = r.anchorPrice;
    }

    event Borrowed(address indexed lp, uint stableOut);
    event Supplied(address indexed lp, uint vbtcIn);
    event Withdrawn(address indexed lp, uint vbtcOut);
    event Repaid(address indexed lp, uint stableIn);

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
