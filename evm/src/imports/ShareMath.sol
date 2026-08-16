// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

/// @title  ShareMath — the ONE valuation of QU!D as basket shares
/// @notice QU!D is an ERC-4626-style share of the stablecoin basket, NOT a pegged $1 coin. `burned` QD is worth
///         its PRO-RATA slice of the deliverable backing, CAPPED at par ($1/QD — the surplus stays as LP equity,
///         so QD is the senior/stable claim and LPs are the junior/yield equity). Below par (supply drifted above
///         backing) it pays the true pro-rata share. This SAME function values a redemption AND a QD-in swap, so
///         QD can never be worth more one way than the other (no swap↔redeem arbitrage). Non-abusable BY
///         CONSTRUCTION: Σ over all holders = `total` exactly, so the basket can never be drained — the last
///         redeemer gets the same per-QD value as the first, no matter how far supply has drifted. This is what
///         lets minting run UNCONSTRAINED (drift is fine); safety is a structural invariant, not a mint-side cap.
library ShareMath {
    /// @param burned         QU!D burned (18-dec, the shares surrendered).
    /// @param total          Deliverable backing in 18-dec USD (par TVL minus the depeg + illiquidity haircuts).
    /// @param supplyPreBurn  Pre-burn MATURE QU!D supply (both callers — swap & redeem — pass matureSupply();
    ///                       immature QU!D is not yet a redeemable claim). Passing the SAME basis on both paths is
    ///                       what preserves swap↔redeem parity; there is no maturation jump to game.
    /// @return dollars       Payout in 18-dec USD: `min(burned /*par*/, total·burned/supplyPreBurn /*share*/)`.
    function qdShareValue(uint256 burned, uint256 total, uint256 supplyPreBurn)
        internal pure returns (uint256 dollars)
    {
        if (burned == 0 || supplyPreBurn == 0) return burned;
        uint256 share = SoladyMath.fullMulDiv(total, burned, supplyPreBurn);
        return burned < share ? burned : share;   // min(par, pro-rata share)
    }
}
