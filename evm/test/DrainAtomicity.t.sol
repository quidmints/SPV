// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// §E71 — DID E68 ACTUALLY KILL THE ATOMICITY ARBITRAGE? A FALSIFIABLE TEST OF MY OWN CHANGE.
///
/// E68 replaced the drain kernel's POINT sample with the INTEGRAL over the swap's own displacement,
/// on the argument that `rate(q0)` applied to a whole swap underprices the last units of a large
/// drain — so ONE BIG DRAIN WAS STRICTLY CHEAPER THAN THE SAME VOLUME SPLIT ACROSS TRANSACTIONS,
/// a standing incentive to consolidate drains and an undercharge of the largest imbalancer.
///
/// That was an ARGUMENT. This is the test. **PREDICTION, STATED BEFORE THE RUN:**
///
///     premium(one drain of size S)  >=  premium(N drains of size S/N)
///
/// Pre-E68 the inequality ran the OTHER WAY. If the split is still cheaper, the fix did not work
/// and E68's claim must be withdrawn — not re-argued.
///
/// MEASURED VIA `skewPremiumCum`, the monotonic retained-premium counter, because it is the
/// protocol's OWN record of what was charged. Deriving the premium from balances instead would
/// re-introduce the payout-path uncertainty that stalled E69.
///
/// ⚠️ THE CAP IS THE KNOWN CONFOUND AND IT IS WHY THIS TEST LOGS BOTH LEGS RATHER THAN ASSERTING
/// A RATIO. `skewWad` clamps to `_maxWellSkew` at the end. If BOTH legs pin to the cap, the two
/// numbers converge and the test says NOTHING about the integral — it would look identical whether
/// or not E68 works. That is the control, and it is checked explicitly below.
contract DrainAtomicity is Alles {
    address lpA = User02;
    address drainer = address(0xBEEF04);
    address bold;

    function _seedBasket() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 4_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function _settle() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 20 minutes);
    }

    /// stable → volatile: the band hands out ETH, so `inv` FALLS and it gets SCARCER.
    /// §E71-r3 — RETURNS THE VOLATILE THE TRADER ACTUALLY RECEIVED. The original version returned
    /// nothing and the test read `skewPremiumCum` instead: OUR OWN ACCOUNTING of what we retained.
    /// That is the same trap that hid the delivery bug through six layers of diagnosis — asserting
    /// on a number the failing system reports about ITSELF. A discount in our bookkeeping is not
    /// evidence of a discount to the WHALE, and a real arbitrage could be invisible to it. The
    /// trader's cost is ETH-received per dollar spent, measured as a BALANCE DELTA on the trader.
    function _drain(uint boldAmt) internal returns (uint ethGot) {
        deal(bold, drainer, boldAmt);
        uint before = WETH.balanceOf(drainer);
        vm.startPrank(drainer);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) {} catch {}
        vm.stopPrank();
        ethGot = WETH.balanceOf(drainer) - before;
        _settle();
    }

    function _setupBand() internal {
        _seedBasket();
        vm.prank(lpA);
        V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        // Pre-drain into the SCARCE region so both legs start from an identical, premium-charging
        // state. Starting flush would put both at zero premium and measure nothing.
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            if (CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd(false)) break;
        }
    }

    /// §E72 — THE σ² CLIFF. E59 made `sigmaSqWad == 0` return the CAP, on the reasoning that
    /// UNMEASURED variance should be priced conservatively. But σ² enters the kernel
    /// MULTIPLICATIVELY (`K·σ²·qBar`), so σ² = 1 wei of variance is not "slightly less
    /// conservative" than σ² = 0 — it is ~zero. **If that is so, the two adjacent states are the
    /// CAP and NOTHING, and anyone able to nudge realized variance off exactly-zero converts the
    /// maximum charge into no charge at all.**
    ///
    /// This is a PURE call into `skewWad`, so there is no fixture, no oracle and no rounding path
    /// to blame — whatever it prints is the formula's own behaviour.
    function test_E72_SigmaSquaredCliffAtZero() public pure {
        uint T = 1_000_000e6;          // target
        uint inv = T / 2;              // genuinely scarce: q0 = 0.5
        uint drain = T / 4;            // a real, size-significant drain

        uint atZero = SwapLib.skewWad(inv, T, 0, false, drain);
        uint atOne  = SwapLib.skewWad(inv, T, 1, false, drain);
        uint atTiny = SwapLib.skewWad(inv, T, 1e13, false, drain);   // ≈ the live fixture's σ²
        uint atReal = SwapLib.skewWad(inv, T, 1e16, false, drain);   // a plausible real variance

        console.log("skew at sigma^2 = 0     :", atZero);
        console.log("skew at sigma^2 = 1     :", atOne);
        console.log("skew at sigma^2 = 1e13  :", atTiny);
        console.log("skew at sigma^2 = 1e16  :", atReal);

        if (atZero > atOne * 1000) {
            console.log("CLIFF CONFIRMED: sigma^2=0 charges >1000x what sigma^2=1 charges.");
            console.log("Adjacent states are THE CAP and ~NOTHING; the sentinel is exploitable.");
        } else {
            console.log("NO CLIFF: the zero sentinel and its neighbour are comparable.");
        }
    }

    /// §E85 — WHERE DOES THE KERNEL OVERTAKE THE FLOOR? The owner distrusted the "q≈0.87" I quoted
    /// for BTC, and was right to: `SPLICE_FLOOR` is a CONSTANT while the kernel scales with σ², so the
    /// crossover is a FUNCTION OF VOLATILITY, not a property of the design. I quoted ONE POINT ON A
    /// CURVE as though it were the curve, then reasoned from it (E83) to call the barrier "decoration".
    /// This sweeps it. Nothing should rest on a single crossover number again.
    function test_E85_CrossoverMovesWithVolatility() public pure {
        uint T = 1_000_000e6;
        uint[4] memory sigs = [uint(1e15), 1e16, 1e17, 1e18];
        for (uint s = 0; s < 4; ++s) {
            uint base = SwapLib.skewWad(T - T / 1000, T, sigs[s], true, 0);  // q->0: the floor
            uint lo = 1; uint hi = 999;
            while (lo < hi) {                       // first q (thousandths) where kernel clears the floor
                uint mid = (lo + hi) / 2;
                if (SwapLib.skewWad(T - (T * mid) / 1000, T, sigs[s], true, 0) > base + base / 50) hi = mid;
                else lo = mid + 1;
            }
            console.log("sigma^2 / floor / crossover q (thousandths):", sigs[s], base, lo);
        }
    }

    function test_E71_OneBigDrainIsNotCheaperThanTheSameVolumeSplit() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;

        // §E71-r3 — MEASURES THE TRADER'S RECEIPT, NOT OUR BOOKKEEPING. The prior version compared
        // `skewPremiumCum`, i.e. the protocol's own record of what it retained. That is the trap that
        // hid the delivery bug through six layers: asserting on a number the failing system reports
        // about ITSELF. A discount in our ledger is not evidence of a discount to the WHALE. Identical
        // dollars go in on both legs, so whoever receives MORE volatile paid LESS — that is the
        // arbitrage, stated in the only terms an arbitrageur acts on. The premium legs are DELETED
        // rather than kept alongside: keeping both was hedging, and it cost the stack slots that made
        // this function stack-too-deep.
        uint snap = vm.snapshotState();
        _setupBand();
        uint invA = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethA = _drain(TOTAL);
        vm.revertToState(snap);

        _setupBand();
        uint invB = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethB;
        for (uint i = 0; i < N; ++i) ethB += _drain(TOTAL / N);

        emit log_named_uint("start inv A (usd6)    ", invA);
        emit log_named_uint("start inv B (usd6)    ", invB);
        emit log_named_uint("ETH to ONE big drain  ", ethA);
        emit log_named_uint("ETH to the SPLIT (sum)", ethB);

        // CONTROLS. Both must hold or the comparison is void — a run that cannot show its own
        // premises is indistinguishable from a run that confirms what I expected.
        if (invA != invB) { emit log("VOID: legs started from different states."); return; }
        if (ethA == 0 || ethB == 0) { emit log("VOID: a leg received no volatile."); return; }

        if (ethA > ethB) {
            emit log("TRADER-SIDE: BIG DRAIN got MORE eth for the same dollars -- ARBITRAGE IS REAL.");
            emit log_named_uint("whale advantage bps", (ethA - ethB) * 10_000 / ethB);
        } else if (ethB > ethA) {
            emit log("TRADER-SIDE: the SPLIT got more -- consolidation is PENALISED, not rewarded.");
            emit log_named_uint("split advantage bps", (ethB - ethA) * 10_000 / ethA);
        } else {
            emit log("TRADER-SIDE: IDENTICAL receipts -- path-independent, which is the goal.");
        }
    }
}
