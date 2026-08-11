// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Alles} from "./Alles.t.sol";

/// @notice §E155. The yield factor `yieldW[i]/amounts[i]` is a SHARE PRICE and must therefore be
///         DIMENSIONLESS — a number near 1.0, whatever decimals the stable or its vault happen to use.
///         Nothing asserted that, and the consequence was silent: `_valueStable` built the factor as a
///         RAW assets-per-share ratio, so an 18-dec MetaMorpho share against a 6-dec asset produced
///         ~1e-12 instead of ~1.012. Those legs then dragged `amounts[0]` below `amounts[14]`, and
///         `computeMetrics` floored `metrics.yield` to ZERO — so `calcMintYield` minted exactly
///         `principal` at every tenor and the forward-yield bond paid nothing at all.
///
///         MEASURED on a mainnet fork before the fix (Galaxy USDC, $1M position): factor 0.000000000001
///         against a true share price of 1.012358. The whole 4,187-test suite passed either way.
///
///         These two tests are the missing pins. The FIRST is the general invariant — it catches any
///         venue whose factor is off by a decimal power, in either direction, including venues not yet
///         wired. The SECOND pins the consequence, so a future regression that re-zeroes the yield is
///         caught at the number the bond curve actually consumes rather than at a vault read.
contract YieldFactorDimensions is Alles {
    /// Band around 1.0. Wide on purpose: this is a DIMENSIONAL check, not a yield-value check —
    /// it must not need updating when a vault's real APY moves. A decimals error is off by 1e6+,
    /// so nothing near this boundary is ambiguous.
    uint constant FACTOR_MIN_WAD = 0.5e18;
    uint constant FACTOR_MAX_WAD = 2.0e18;

    function _seedBasket() internal {
        deal(address(USDC), User01, 400_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 200_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// THE INVARIANT. Every stable holding real balance must report a dimensionless factor.
    function test_YieldFactorIsDimensionless_EveryStable() public {
        _seedBasket();
        (uint[15] memory amounts, uint[15] memory yieldW,,) = AUX.get_deposits();

        address[] memory stables = AUX.getStables();
        uint checked;
        for (uint i; i < stables.length; i++) {
            uint bal = amounts[i + 1];
            if (bal == 0) continue;               // unwired / empty leg carries no claim
            uint factorWad = (yieldW[i + 1] * 1e18) / bal;
            emit log_named_uint(string.concat("factor x1e18, slot ", vm.toString(i)), factorWad);
            assertGe(factorWad, FACTOR_MIN_WAD,
                "yield factor collapsed - raw assets-per-share instead of a dimensionless share price");
            assertLe(factorWad, FACTOR_MAX_WAD,
                "yield factor exploded - a decimal lift applied twice");
            checked++;
        }
        assertGt(checked, 0, "no funded stable found - the assertion was vacuous");
    }

    /// THE CONSEQUENCE. `metrics.yield` is what `calcMintYield` multiplies the tenor by; if it is zero
    /// the bond premium is zero no matter what the vaults earn.
    function test_AvgYieldIsNonZero_SoTheBondActuallyPays() public {
        _seedBasket();
        (, uint avgYield) = AUX.get_metrics(true);
        emit log_named_uint("metrics.yield (WAD)", avgYield);
        assertGt(avgYield, 0,
            "metrics.yield floored to 0 - every vintage mints exactly principal, the term premium is inert");
    }
}
