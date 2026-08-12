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

    /// THE CONSEQUENCE. `metrics.yield` is what `calcMintYield` multiplies the tenor by, so it must be
    /// non-zero — and it must be a RATE.
    ///
    /// ⚠️ THE WARP IS NOT TEST SUGAR, IT IS THE POINT (§E155-rate). `metrics.yield` is now an
    /// ANNUALISED DELTA between two samples of each leg's share price, so it is 0 until a leg has been
    /// observed TWICE at least `RATE_SAMPLE_MIN` apart. A level needed no elapsed time; a rate does.
    /// This assertion originally passed with no warp at all — that it now requires one is the change
    /// working, not a regression, and 0-before-the-second-sample is the conservative direction
    /// (under-mints the bond, never over-mints).
    ///
    /// 🔴 THIS TEST ASSERTS SHAPE, NOT MAGNITUDE, AND THE NUMBER IT PRINTS IS NOT A REAL YIELD.
    /// `vm.warp` moves the EVM clock but the forked venue state is frozen at the fork block, so a
    /// MetaMorpho vault accrues almost nothing across the warp. MEASURED here: `lastLevel` moved
    /// ~3e-6 relative over a 30-day warp where the real 30-day accrual is ~3e-3 — a thousandfold
    /// short — which is why this reports ~0.34% instead of USDC's real ~3.7%. Do not tighten the
    /// bounds below into a magnitude check on this harness; it structurally cannot support one.
    /// THE ARITHMETIC IS VALIDATED SEPARATELY against real archive reads 30 days apart: the USDC
    /// vault levelled 1.009559 -> 1.012621, a 0.3033% 30-day growth, and `growth x YEAR/elapsed`
    /// gives 3.690% against a 3.753% compounded reference. Note the estimator annualises SIMPLY, so
    /// it under-states by ~0.06pp at these rates — the safe direction for a mint.
    /// ▶️ A magnitude harness needs `FORK_BLOCK` set to a past block plus `vm.rollFork` forward, so
    /// both samples read REAL venue state. Booked, not built.
    function test_AvgYieldIsARate_NonZeroAndSane() public {
        _seedBasket();
        AUX.get_metrics(true);                 // sample 1: bootstrap anchors each leg, rate stays 0

        (, uint atBootstrap) = AUX.get_metrics(true);
        assertEq(atBootstrap, 0, "a single observation cannot produce a rate - bootstrap must report 0");

        vm.warp(block.timestamp + 30 days);    // let the real forked vaults accrue
        vm.roll(block.number + 1);
        // Sample 2 comes from a MUTATION, not from a read: the estimator advances inside
        // `_refreshOne`, which runs on the mint/redeem refresh. There is no public refresh
        // entrypoint (`refreshAllHoldingsSelf` is `onlySelf`), so the second observation is
        // organic-traffic-driven — the same dependency the vault-health poke has.
        _seedBasket();
        (, uint avgYield) = AUX.get_metrics(true);

        // DIAGNOSTIC: decompose the reported rate into its inputs, so a wrong number can be
        // attributed to the estimator vs to how much the forked vault actually accrued.
        {
            (uint bal,, uint lastLevel, uint rate, uint40 lastAt) = AUX.storedHoldings(address(USDC));
            emit log_named_uint("USDC balance      ", bal);
            emit log_named_uint("USDC lastLevel WAD", lastLevel);
            emit log_named_uint("USDC rate      WAD", rate);
            emit log_named_uint("USDC lastAt       ", uint(lastAt));
            emit log_named_uint("now               ", block.timestamp);
        }
        emit log_named_uint("metrics.yield (WAD)", avgYield);
        assertGt(avgYield, 0,
            "metrics.yield is 0 after two samples - every vintage mints exactly principal, the premium is inert");
        // THE REGRESSION GUARD, and the reason this test earns its place: a CUMULATIVE level reads
        // 8.36% here and up to 101% on a single leg, because it carries venue age and the venue's
        // arbitrary price base. A genuine annualised rate on this basket is single-digit percent.
        // 20% is far above any real stablecoin yield and far below what a level reports, so nothing
        // sits near the boundary.
        assertLt(avgYield, 0.20e18,
            "metrics.yield looks like a cumulative LEVEL again, not an annualised rate (see E155-overreport)");
    }
}
