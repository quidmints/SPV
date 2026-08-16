// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {ICore, IBand, IAux, ILevEquity} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";
import {SwapLib} from "./SwapLib.sol";

/// @title  BandLib — the ONE implementation of each band-manager body, for both bands.
///
/// @notice §BAND-MERGE. `VogueLib` (ETH, 633 lines) and `BtcVaultLib` (BTC, 623) are the ETH/BTC
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
    /// @dev    THE MERGED PAIR: `VogueLib.levBurnAll` ∥ `BtcVaultLib.levBurnAllBtc` were line-for-
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
        ICore(c.core).modLP(grossRem, 0, address(0));      // tokenless burn of GROSS depth
        LP.pooled -= netRem; levPooled[lp] -= netRem;      // net leg leaves pooled / the share count
        levBuf[lp] = 0; levBufferUsd[lp] = 0;              // buffer leg leaves the fee weight
        // `levBuf[lp]` is now 0, so the GROSS fee weight is simply `LP.pooled`. Safe on both sides:
        // an assignment at the same weight is idempotent, and the ETH path's `_onExit` overwrites
        // it at the final weight after the add legs run.
        SwapLib.refreshBookmarks(LP, LP.pooled, p.feesPerShare, p.usdFees);
        return (netRem, bufBurned);
    }

    /// @notice NET-EQUITY leg. Grows `pooled` (and so the share count) and the levered net slice.
    /// @dev    MERGED PAIR. The only genuine difference was the SIZING CALL -- `IVogue(this).addLiq`
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
        ICore(c.core).modLP(netTok, netUsd, lp);
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
        ICore(c.core).modLP(bufTok, bufUsd, lp);
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
    /// @dev    MERGED PAIR, and this one was a PURE DUPLICATE: `VogueLib.pullBody` and
    ///         `BtcVaultLib.pullBtc` were BYTE-IDENTICAL after normalising the storage PARAMETER
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
}
