// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";

/// @title  §E306 — **THE MISSING INSTRUMENT: ENTER THROUGH THE PRODUCTION CALLER**
///
/// @notice §E306's finding: every skew test enters at `SwapLib.skewWad`, which takes σ² as a
///         PARAMETER, so each test supplies its own and none observes what production supplies.
///         *"The parameterisation that makes the function testable is exactly what hides the
///         unreachability."* `GammaRederived` goes further and reimplements the kernel locally — a
///         mirror cannot notice its subject is unreachable, and demonstrably did not notice when the
///         subject was replaced wholesale (§E287-qsquared).
///
///         ⭐ **THE GAP IS BETWEEN `skewWad` AND `wellSkew`.** `Aux.wellSkew(asset, drainUsd6)` READS
///         `realizedVarianceWad()` off the live `Core` itself. Nothing tested it. This does.
///
///         ⚠️ §E306 named the reason this went unbuilt for weeks: *"it needs a `Core`, and only
///         `Alles.t.sol` builds one — that fixture cost is the actual reason."* So this file pays
///         that cost once, by extending the fixture rather than mocking around it.
contract SkewLivePathReachesKernelTest is AllesFixture {
    uint constant SENTINEL = 3e16;   // SwapLib.UNKNOWN_VARIANCE_SKEW — returned when sigma^2 == 0

    /// Seed a range with depth, pin the anchor, and drive MOVING samples so the ring records real
    /// variance. All three are required and each was a separate diagnosis in its own right:
    /// the bare fixture leaves `assetPriceFeed(WETH)` at address(0) (so the anchor fallback writes
    /// nothing), and identical samples give sigma^2 == 0 with a completely full ring.
    function _seedDepthAndVariance() internal returns (uint px) {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(User02);
        ETH.deposit{value: 400 ether}(0, User02);

        px = AUX.getTWAPforAsset(address(WETH), 1800);
        _setEthFeed(px / 1e10);
        AUX.setAssetFeed(address(WETH), ETH_FEED);
        uint spx = px;
        for (uint i; i < 6; ++i) {
            spx = i % 2 == 0 ? spx + spx / 50 : spx - spx / 51;   // ~+-2%, MOVING (equal samples give 0)
            _setEthFeed(spx / 1e10);                              // anchor follows, else the push is refused
            CORE.pushObservation(spx);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 30 minutes);
        }
        // ⭐ **THE THIRD PRECONDITION, AND IT IS NOT IN §E306's WRITE-UP.** `skewWad` opens with
        //    `if (target == 0) return _maxWellSkew(sigmaSq, rk)` — SIZE-INDEPENDENT. `target` is
        //    `flowEwmaUsd()`, which only `_bumpFlow` (`Core:1050`, on the swap path) ever raises. A
        //    fixture with depth and variance but NO FLOW therefore returns a flat number at every
        //    drain while looking perfectly healthy. Real swaps are the only way to bump it.
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i; i < 4; ++i) {
            AUX.swap(address(USDC), address(WETH), true, 50_000 * USDC_PRECISION, 0, true);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
    }

    /// 🔴 **THE ASSERTION §E306 ASKED FOR.** Call the PRODUCTION entry across a drain sweep that
    ///     crosses the flush boundary, and require that the skew actually MOVES. If the live path
    ///     never reaches the kernel it returns the flat sentinel at every size, which is the whole
    ///     finding — Γ, ρ, the pole, §E68's integral and κ would all be downstream of a
    ///     multiply-by-zero and none of them would ever have executed.
    function test_E306_LivePathReachesTheKernel_NotTheFlatSentinel() public {
        _seedDepthAndVariance();
        uint sigma = CORE.realizedVarianceWad();
        emit log_named_uint("live sigma^2 (wad)", sigma);
        emit log_named_uint("live flowEwmaUsd  ", CORE.flowEwmaUsd());
        emit log_named_uint("live POOLED       ", CORE.POOLED());
        assertGt(sigma, 1, "PREMISE: the live Core reports no variance, so this measures nothing");
        assertGt(CORE.flowEwmaUsd(), 0,
            "PREMISE: flowEwmaUsd == 0 makes skewWad return _maxWellSkew SIZE-INDEPENDENTLY, so a "
            "size sweep would be flat for a reason that has nothing to do with the kernel");

        uint small = AUX.wellSkew(address(WETH), 10_000e6);
        uint mid   = AUX.wellSkew(address(WETH), 200_000e6);
        uint big   = AUX.wellSkew(address(WETH), 600_000e6);
        emit log_named_uint("wellSkew @   10k", small);
        emit log_named_uint("wellSkew @  200k", mid);
        emit log_named_uint("wellSkew @  600k", big);

        assertTrue(small != SENTINEL || mid != SENTINEL || big != SENTINEL,
            "E306: the PRODUCTION path returns UNKNOWN_VARIANCE_SKEW at every size - sigma^2 is 0 "
            "on the live Core and the kernel has never executed");
        assertGt(big, small,
            "E306: the production skew does not vary with size - the live path is not reaching the "
            "kernel, so every Gamma/rho/pole/kappa result was measured on a curve production never takes");
    }

    /// CONTROL — the same call BEFORE any variance is seeded must return the sentinel. Without this,
    /// the test above could pass in a world where the kernel is unreachable but something else moves.
    function test_E306_Control_UnseededCoreReturnsTheSentinel() public {
        vm.prank(User02);
        ETH.deposit{value: 400 ether}(0, User02);
        assertEq(CORE.realizedVarianceWad(), 0, "PREMISE: the bare fixture should have no variance");
        // ⛔ **§E306 SAYS THIS RETURNS "THE FLAT SENTINEL". IT DOES NOT — IT RETURNS 0.** With no
        //    flow, `target == 0` short-circuits to `_maxWellSkew(0, ethRisk())`, and ETH's profile is
        //    `(ETH_CONF_FRAC_WAD, 0)` — `spliceFloor == 0` — so the whole expression is ZERO. The
        //    `UNKNOWN_VARIANCE_SKEW` sentinel sits BELOW that short-circuit and is never reached.
        //    ⇒ On a flush ETH range the production skew is 0, not 3e16, which is
        //    §ZERO-REVENUE-ON-A-FLUSH-ETH-RANGE seen from the production entry point.
        assertEq(AUX.wellSkew(address(WETH), 10_000e6), 0,
            "an unseeded ETH range must quote ZERO (target==0 -> _maxWellSkew, and ETH's spliceFloor "
            "is 0). If this is now the 3e16 sentinel, the short-circuit order changed.");
    }
}
