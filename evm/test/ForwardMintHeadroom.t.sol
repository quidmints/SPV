// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles} from "./Alles.t.sol";
import {Aux} from "../src/Aux.sol";
import {console} from "forge-std/console.sol";

/// Steady-state (post-month-12) forward-mint horizon now SCALES with the live
/// over-collateralization buffer (depeg-adjusted backing − supply): longer locks
/// are only permitted when the buffer can absorb the pre-spend. This exercises
/// the exact new branch in Basket._finishMint — the post-month-12 path that
/// DepegBackingProbe explicitly flagged as a coverage TODO.
///
/// The maturity BUCKET a far-dated mint lands in is the clean observable: the 1:1
/// cap only changes the AMOUNT minted, never the `month` bucket, so reading
/// balanceOf[who][month] isolates the horizon clamp from the cap entirely.
contract ForwardMintHeadroom is Alles {
    uint constant MONTH = 2_420_000; // BasketLib.MONTH

    /// Mirror of the contract's buffer→maxFwd tiering (Basket._finishMint).
    function _maxFwdFor(uint bufBps) internal pure returns (uint) {
        return bufBps >= 500 ? 12 : bufBps >= 300 ? 6 : bufBps >= 150 ? 3 : 1;
    }

    /// Warps into steady state, mints `when` FAR beyond the cap as a fresh user,
    /// and returns (minted, the single maturity bucket the cohort landed in,
    /// nextMonth, expectedMaxFwd derived from the SAME metrics the mint reads).
    function _mintFarDated(address user, uint expectBufBps)
        internal returns (uint minted, uint actualM, uint nextMonth, uint expMaxFwd)
    {
        uint cm = QUID.currentMonth();
        assertGe(cm, 12, "must be in steady state for the new branch");
        nextMonth = cm + 1;
        expMaxFwd = _maxFwdFor(expectBufBps);

        deal(address(USDC), user, 1_000_000e6);
        vm.startPrank(user);
        USDC.approve(address(AUX), type(uint).max);
        uint when = nextMonth + expMaxFwd + 6; // request beyond the cap
        minted = QUID.mint(user, 100_000e6, address(USDC), when);
        vm.stopPrank();

        // New branch executed safely; 1:1 cap floors the credit at the (post
        // deposit-fee) principal — never below it, never the depositor's loss.
        assertGt(minted, 0, "steady-state mint must succeed");
        assertGt(minted, 99_900e18, "cap floors credit at ~principal");

        uint nonzero;
        for (uint m = nextMonth; m <= nextMonth + 13; ++m) {
            if (QUID.balanceOf(user, m) > 0) { actualM = m; nonzero++; }
        }
        assertEq(nonzero, 1, "exactly one maturity cohort from one mint");
        assertLe(actualM, nextMonth + 12, "never beyond a one-year lock");
        assertGe(actualM, nextMonth, "never before next month");
        assertLt(actualM, when, "far `when` was clamped down to the cap");
    }

    /// Thin buffer (the harness's natural post-seed state ≈ 0 bps): the horizon
    /// must collapse to the ~1-month floor — the SAFETY direction (a thin buffer
    /// must NOT be stretchable into long-dated cohorts).
    function test_forwardHorizon_thinBuffer_clampsToFloor() public {
        bytes4 sevSel = bytes4(keccak256("getDepegSeverityBps(address)"));
        vm.mockCall(address(AUX), abi.encodeWithSelector(sevSel), abi.encode(uint(0)));
        vm.warp(block.timestamp + 13 * MONTH);

        // Confirm the live buffer is genuinely thin so maxFwd=1 is the real path.
        (uint total,) = AUX.get_metrics(true);
        uint loss = AUX.depegLoss();
        total -= total < loss ? total : loss;
        uint sup = QUID.totalSupply();
        uint bufBps = total > sup ? (total - sup) * 10_000 / total : 0;
        console.log("live buffer (bps):", bufBps);
        assertLt(bufBps, 150, "precondition: natural buffer is thin (<1.5%)");

        (, uint actualM, uint nextMonth,) = _mintFarDated(User02, bufBps);
        assertEq(actualM, nextMonth + 1, "thin buffer -> ~1mo floor lock");
    }

    /// Ample buffer: with a healthy over-collateralization cushion the horizon
    /// opens up to a full year. The real-vault fork can't cheaply manufacture a
    /// >5% buffer, so we drive `get_metrics` (the SAME source both the buffer
    /// gate and the 1:1 cap read) to a >5% cushion and assert the lock extends.
    function test_forwardHorizon_ampleBuffer_allowsYearLock() public {
        bytes4 sevSel = bytes4(keccak256("getDepegSeverityBps(address)"));
        vm.mockCall(address(AUX), abi.encodeWithSelector(sevSel), abi.encode(uint(0)));
        vm.warp(block.timestamp + 13 * MONTH);

        // Ample buffer (≥5% tier) with a normal 15% projected yield. Add a large
        // ABSOLUTE cushion (not just a %) so the 1:1 cap has room to actually
        // credit the forward-yield bonus rather than flooring to baseAmount. Mock
        // by selector so the buffer read in _finishMint and the cap both see it.
        uint sup = QUID.totalSupply();
        uint mockTotal = sup + 2_000_000e18; // huge absolute headroom, bufBps ≫ 500
        vm.mockCall(address(AUX),
            abi.encodeWithSelector(Aux.get_metrics.selector),
            abi.encode(mockTotal, uint(0.15e18)));

        uint bufBps = (mockTotal - sup) * 10_000 / mockTotal;
        console.log("mocked buffer (bps):", bufBps);
        assertGe(bufBps, 500, "precondition: ample buffer (>=5%)");

        (uint minted, uint actualM, uint nextMonth, uint expMaxFwd)
            = _mintFarDated(User03, bufBps);
        assertEq(expMaxFwd, 12, "ample buffer tier is a full year");
        assertEq(actualM, nextMonth + 12, "ample buffer -> year-long lock allowed");
        // Ample headroom means the cap does NOT bind: the forward-yield bonus is
        // actually credited (minted strictly above principal), proving the long
        // lock delivers term value rather than just clamping to baseAmount.
        assertGt(minted, 105_000e18, "year lock pays the projected forward yield");
    }
}
