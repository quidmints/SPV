// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {AllesFixture} from "./Alles.t.sol";

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
contract YieldFactorDimensions is AllesFixture {
    /// Range around 1.0. Wide on purpose: this is a DIMENSIONAL check, not a yield-value check —
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

    /// §E190. THE SENIORITY CARVE-OUT MUST NOT MOVE THE MEASUREMENT.
    /// `get_deposits` excludes the seed tranche from a leg's redeemable balance. It used to take the
    /// same NOMINAL amount off `yieldWeighted` too — but `yieldWeighted == balance × f`, so removing
    /// `cap` from each leaves `(b·f − cap)/(b − cap)`, which is not `f`. The carve-out therefore
    /// INFLATED the leg's apparent yield in proportion to how much of it was reserved (measured at
    /// the live Galaxy-USDC price: +1.2% at a 50k/100k tranche, +23.7% at 95k/100k).
    ///
    /// The invariant: a leg's REPORTED factor must equal its PRE-TRANCHE cached ratio. The tranche is
    /// a property of the CLAIM; the share price is a property of the VENUE, and a seed reserve does
    /// not change what a vault earns per share.
    ///
    /// ⚠️ NON-VACUITY IS ASSERTED. `seedFee` returns 0 when `avgYield == 0`, and the §E155-rate
    /// estimator bootstraps to 0 — so a single mint tips NO tranche and this test would pass while
    /// checking nothing. Hence the warp and the second mint: they are what make a tranche exist.
    function test_TrancheDoesNotDistortTheYieldFactor() public {
        _seedBasket();

        // Create the carve-out through the REAL path. `tipSelf` is gated to Aux itself, so a prank
        // drives the production `tipBody` — no mock, no vm.store. In production this is fed by
        // `seedFee` from `depositBody`; that route CANNOT be used here because `seedFee` returns 0
        // when `avgYield == 0`, and the §E155-rate estimator bootstraps to 0, so a fresh harness
        // tips nothing (observed: tranche 0 even after a warp and a second mint). Driving `tipSelf`
        // directly is what makes this assertion non-vacuous.
        (uint bCached, uint ywCached,,,) = AUX.storedHoldings(address(USDC));
        require(bCached > 0, "USDC leg unfunded - assertion would be vacuous");
        vm.prank(address(AUX));
        AUX.tipSelf(200_000 * USDC_PRECISION, address(USDC), int(1));

        uint reserved = AUX.tranche(address(USDC));
        emit log_named_uint("tranche[USDC] (18-dec)", reserved);
        emit log_named_uint("USDC leg balance      ", bCached);
        assertGt(reserved, 0, "no tranche was created - the assertion would be vacuous");

        (uint[15] memory amounts, uint[15] memory yieldW,,) = AUX.get_deposits();
        uint idx = AUX.toIndex(address(USDC));       // 1-based
        require(idx > 0 && amounts[idx] > 0, "USDC leg carved to zero - nothing left to measure");

        uint preTrancheWad = (ywCached * 1e18) / bCached;
        uint reportedWad   = (yieldW[idx] * 1e18) / amounts[idx];
        emit log_named_uint("pre-tranche factor x1e18", preTrancheWad);
        emit log_named_uint("reported   factor x1e18", reportedWad);
        // 1-2 wei of rounding is inherent to the mulDiv. The nominal double-subtraction this pins
        // against is off by PERCENT at this reserve fraction (~50% reserved => ~+1.2%), so nothing
        // sits anywhere near the tolerance.
        assertApproxEqAbs(reportedWad, preTrancheWad, 2,
            "the seed carve-out moved the yield factor - nominal subtraction from both sides");
    }

    /// §E155 LEFT THIS AUDIT UNEXECUTED AND I ALMOST CLOSED THE THREAD WITHOUT IT.
    /// `_aaveYieldWeighted` is `mulDiv(assets, assets, shares)` — the SAME raw ratio that collapsed the
    /// 4626 leg to 1e-12 — and it is correct ONLY if `getUserSuppliedAssets` and `getUserSuppliedShares`
    /// carry the same decimals. I booked "unstated and unverified; audit it in the same pass" and did
    /// not. MEASURED against the live v4 spoke: factor 1.009911, i.e. the liquidity index. No bug.
    ///
    /// ⚠️ TWO deposits, not one, and that is itself the finding: routing picks the LEAST-FULL member and
    /// ties go to the FIRST in the set, so with both legs at zero the 4626 wins and the aave leg sees
    /// NOTHING. A single-mint version of this test measured 0/0 and would have proved nothing.
    function test_aaveLegYieldFactorIsDimensionless() public {
        address spoke = AUX.AAVE_SPOKE();
        require(spoke != address(0), "no spoke wired - assertion would be vacuous");
        vm.prank(AUX.owner());
        AUX.setVault(address(USDT), spoke);

        deal(address(USDT), User02, 100_000 * USDC_PRECISION);
        vm.startPrank(User02);
        (bool ok,) = address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", address(AUX), type(uint).max));
        require(ok, "usdt approve");
        QUID.mint(User02, 50_000 * USDC_PRECISION, address(USDT), 0);   // fills the 4626 leg
        QUID.mint(User02, 50_000 * USDC_PRECISION, address(USDT), 0);   // now the spoke is least-full
        vm.stopPrank();

        uint a = AUX.aaveBalance(address(USDT));
        uint sh = AUX.aaveShares(address(USDT));
        emit log_named_uint("aave assets", a);
        emit log_named_uint("aave shares", sh);
        assertGt(a, 0, "aave leg unfunded - the assertion would be vacuous");
        assertGt(sh, 0, "aave shares zero - the assertion would be vacuous");

        uint factorWad = (a * 1e18) / sh;
        emit log_named_uint("aave factor x1e18", factorWad);
        assertGe(factorWad, FACTOR_MIN_WAD,
            "aave yield factor collapsed - assets and shares do not share decimals");
        assertLe(factorWad, FACTOR_MAX_WAD, "aave yield factor exploded");
    }
}
