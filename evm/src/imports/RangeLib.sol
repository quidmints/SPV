// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {ICore, IAux, ILevEquity} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";
import {SwapLib} from "./SwapLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";

library RangeLib {

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

        uint pooledTok = ICore(c.core).POOLED();
        uint usdOut = pooledTok == 0
            ? levBufferUsd[lp]
            : SoladyMath.fullMulDiv(ICore(c.core).basketUsd(), grossRem, pooledTok);
        ICore(c.core).modLP(int256(grossRem), int256(usdOut), address(0));
        LP.pooled -= netRem; levPooled[lp] -= netRem;
        levBuf[lp] = 0; levBufferUsd[lp] = 0;

        SwapLib.refreshBookmarks(LP, LP.pooled, p.feesPerShare, p.usdFees);
        return (netRem, bufBurned);
    }

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
        ICore(c.core).modLP(-int256(netTok), -int256(netUsd), lp);
        return netTok;
    }

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
        ICore(c.core).modLP(-int256(bufTok), -int256(bufUsd), lp);
        return bufTok;
    }

    function levAddGross(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.RangeP memory p
    ) public returns (uint addedNet, uint bufAdded) {
        if (p.gross == 0) return (0, 0);
        uint price = IAux(c.aux).assetPrice(c.asset);
        if (price == 0) return (0, 0);
        uint netEq = ILevEquity(p.mgr).netEquity(lp);
        addedNet = levAddNet(c, LP, levPooled, levBuf, lp, netEq, price, p);
        if (p.gross > netEq)
            bufAdded = levAddBuf(c, LP, levBufferUsd, levBuf, lp, p.gross - netEq, price, p);
    }

    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);

    function openPos(
        mapping(address => Types.Pos) storage pos,
        address lp,
        Types.Pos memory p
    ) external {

        pos[lp] = p;

    }

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

        q.entryEquity            = uint128(base);
        emit ReanchoredToRange(lp, s, base);
        return true;
    }
}
