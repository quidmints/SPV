// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeLib} from "./imports/FeeLib.sol";

/// Minimal read-only surface of Aux the lens needs (all already public on Aux).
interface IAuxLens {
    function get_deposits() external returns (uint[15] memory amounts, uint[15] memory yieldW, uint, uint);
    function getStables() external view returns (address[] memory);
    function getDepegSeverityBps(address token) external view returns (uint);
}

/// @title  QuidLens — SPA hints for a STRICT swap-out (BTC/ETH → a chosen USD stable, instead of pro-rata)
/// @notice The frontend multi-calls `quoteStrict` once per candidate stable to show the user the real cost of
///         cherry-picking each, so they pick the cheapest — which is also the stable the basket most wants shed
///         (the same `calcFeeL1` yield-vs-baseline signal the redemption path charges). Read-only; kept OUT of
///         Aux (EIP-170-tight) as a periphery lens that only reads Aux's public getters + reuses `FeeLib`. No
///         state change — the SPA reads it via `eth_call`.
contract QuidLens {
    /// @notice Cost of drawing `amountUsd6` (6-dec USD) strictly from `stable`, exactly as the redemption path
    ///         prices it: `feeBps` = the composite outflow friction (magnitude-scaled `calcFeeL1` yield-vs-baseline,
    ///         capped at `MAX_FEE` = 30 bps — the `baseRate` this line used to name was REMOVED, see the body
    ///         comment below); `depegBps` = live depeg severity
    ///         (0 when pegged). Lower total ⇒ cheaper for the user AND healthier for the basket. Non-view because
    ///         `get_deposits` isn't view; call via `eth_call`.
    function quoteStrict(address aux, address stable, uint amountUsd6)
        external returns (uint feeBps, uint depegBps)
    {
        IAuxLens a = IAuxLens(aux);
        (uint[15] memory deps, uint[15] memory yields,,) = a.get_deposits();
        address[] memory stables = a.getStables();
        uint idx = type(uint).max;
        for (uint i; i < stables.length; i++) if (stables[i] == stable) { idx = i; break; }
        require(idx != type(uint).max, "QuidLens: not a basket stable");

        // Magnitude-scaled yield-vs-baseline (identical to calcNeeded: 6-dec amount → 18-dec basis). The baseRate
        // velocity toll was REMOVED (no peg-arb loop; see Aux._takeArgs), so the outflow fee is concentration-only.
        // R5: the `f > MAX_FEE ? MAX_FEE : f` clamp that used to sit here is DELETED — it can never
        // fire. `scaledFeeL1` returns either `full` (which `calcFeeL1` documents as `[BASE, MAX_FEE]`)
        // or `BASE + (full-BASE)·frac/WAD` with `frac` ALREADY clamped to `WAD` (`FeeLib:146`), so the
        // scaled branch is `<= BASE + (full-BASE) == full <= MAX_FEE` on every path. Keeping it also
        // MASKED any future violation of calcFeeL1's stated range instead of surfacing it here.
        feeBps = FeeLib.scaledFeeL1(idx, amountUsd6 * 1e12, deps, yields);
        depegBps = a.getDepegSeverityBps(stable);
    }
}
