// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {console} from "forge-std/console.sol";
import {Core} from "../src/Core.sol";

/// @title  BackingGateSplit — WHICH band is over-committing, measured per band.
///
/// @notice §OVERCOMMITTED-ROOT. 960 suite failures revert on `Aux.sol:1149 OverCommitted()`
///         (`committedSum > totalLiquid`). Two explanations were on the table and they demand
///         OPPOSITE fixes, so guessing is not an option:
///
///           (a) the fixtures genuinely over-commit the shared basket, encoding the world from
///               BEFORE `_reportEquity` was wired (when `total()` was permanently 0 and the
///               `require` compared `0 <= haircutTvl`: always true), or
///           (b) `_reportEquity`/`committedUsd18` DOUBLE-COUNTS across the two bands.
///
///         The discriminator is the PER-BAND SPLIT, which no failure message shows: the revert
///         prints only the sum. If ONE band's own figure already ≈ TVL, the sum is honest and
///         (a) holds — the basket is fully drawn and the sibling correctly cannot commit. If the
///         two bands report OVERLAPPING claims on the same dollars, (b) holds.
///
/// @dev    ⚠️ This asserts NOTHING about which is true. It is an instrument, and it reads the
///         EXACT public quantities the deployed gate uses (`Aux.committedOf`,
///         `Core.bandEquityUsd18`, `AUX.get_deposits()[14]`) so its numbers ARE the gate's.
///         Asserting a conclusion here is how a probe stops being able to disprove it.
contract BackingGateSplit is AllesFixture {

    function test_backingGate_perBandSplit() public {
        _stageDepeg();  // heal the fork's default depeg; build real basket backing

        // §BANDBACKING-FOLD — the accountant IS `AUX` now. `committedOf` and `committedTotal` are
        // public there, so the per-band split is still readable without a registry to enumerate:
        // the ETH band by address, the BTC band as the remainder of the same total the bound uses.

        // TVL is the gate's ceiling, read from the same accessor `backingCoreBody` uses.
        (uint[15] memory d,,, uint depegLoss) = AUX.get_deposits();
        uint totalLiquid = d[14];
        uint haircutTvl  = totalLiquid > depegLoss ? totalLiquid - depegLoss : 0;

        console.log("--- ceiling ---");
        console.log("TVL _d[14]        (18d):", totalLiquid);
        console.log("depegLoss         (18d):", depegLoss);
        console.log("haircutTvl        (18d):", haircutTvl);

        // Enumerate every registered band. `total()` reverts unless sealed, so a revert here is
        // itself a finding: it would mean the deploy never sealed and the gate cannot be trusted.
        console.log("--- per band ---");
        uint ethCommitted = AUX.committedOf(address(CORE));
        uint reportedTotal = AUX.committedTotal();
        console.log("ETH band committedOf:", ethCommitted);
        console.log("ETH band live equity:", CORE.bandEquityUsd18());  // divergence == a STALE push
        console.log("ETH band POOLED_USD :", CORE.POOLED_USD());
        console.log("BTC band (remainder):", reportedTotal - ethCommitted);
        uint sum = reportedTotal;
        console.log("--- sum ---");
        console.log("sum(committedOf)  :", sum);
        console.log("AUX.committedTotal:", reportedTotal);
        console.log("committedUsd18    :", CORE.committedUsd18());

        // §THE-ACTUAL-TRIP. `testRegularSwaps` and the other OverCommitted failures do exactly this
        // and nothing else beforehand: one LP deposits 100 ETH into the ETH band. A two-sided band
        // must PAIR that ETH with USD depth drawn from the basket, so the question the gate asks is
        // whether the basket can back the pairing. Measure what one deposit costs in headroom.
        (uint spot,) = CORE.poolStats();
        console.log("--- depositing 100 ETH (the trip in testRegularSwaps) ---");
        console.log("ETH spot          :", spot);
        console.log("100 ETH is worth  :", (100 * spot));   // 18-dec USD

        vm.deal(User01, 200 ether);
        vm.prank(User01);
        try V4.deposit{value: 100 ether}(0, User01) {
            console.log("deposit SUCCEEDED");
        } catch Error(string memory reason) {
            console.log("deposit reverted:", reason);
        } catch (bytes memory lowLevel) {
            console.log("deposit reverted (selector):", vm.toString(lowLevel));
        }

        console.log("--- after the deposit ---");
        uint ethAfter = AUX.committedOf(address(CORE));
        uint totAfter = AUX.committedTotal();
        console.log("ETH band committedOf:", ethAfter);
        console.log("ETH band POOLED_USD :", CORE.POOLED_USD());
        console.log("BTC band (remainder):", totAfter - ethAfter);
        (uint[15] memory d2,,, uint loss2) = AUX.get_deposits();
        uint ceil2 = d2[14] > loss2 ? d2[14] - loss2 : 0;
        console.log("TVL after         :", d2[14]);
        console.log("committed after   :", totAfter);
        if (totAfter > ceil2) console.log("OVER BY           :", totAfter - ceil2);
        else console.log("headroom left     :", ceil2 - totAfter);

        _swapLeg();
    }

    /// @dev Own frame — `via_ir` is false in this repo ON PURPOSE, so stack-too-deep is solved by
    ///      giving the work its own frame, never by turning on the IR pipeline.
    function _swapLeg() private {
        // §THE-SWAP-LEG. The deposit alone passes, so the trip is downstream. `basketLeg` is
        // documented TRUE only from `_handleMod` (Core.sol:984), which would mean a USER swap
        // cannot move `basketUsd` and therefore cannot move committed at all. Test that claim
        // directly rather than trusting the comment -- a comment describes past state.
        console.log("--- one swap (as testRegularSwaps does) ---");
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        try AUX.swap{value: 1 ether}(address(USDC), address(WETH), false, 0, 0) {
            console.log("swap SUCCEEDED");
        } catch Error(string memory reason) {
            console.log("swap reverted:", reason);
        } catch (bytes memory lowLevel) {
            console.log("swap reverted (selector):", vm.toString(lowLevel));
        }
        vm.stopPrank();

        (uint[15] memory d3,,, uint loss3) = AUX.get_deposits();
        uint ceil3 = d3[14] > loss3 ? d3[14] - loss3 : 0;
        uint tot3  = AUX.committedTotal();
        console.log("TVL after swap    :", d3[14]);
        console.log("committed after   :", tot3);
        console.log("ETH band POOLED_USD:", CORE.POOLED_USD());
        if (tot3 > ceil3) console.log("OVER BY           :", tot3 - ceil3);
        else console.log("headroom left     :", ceil3 - tot3);

        // §BANDBACKING-FOLD — THE OLD "total == sum of parts" ASSERTION IS DELETED, NOT REWRITTEN.
        // Under the registry it was a real check: `bands` could be partial, `seal()` could be
        // missed, and a partial sum under-reports and passes a bound it should fail. Aux adds two
        // IMMUTABLE addresses, so the property now holds by construction and any assertion of it
        // reduces to `x + (t - x) == t` -- true for every t, testing nothing. A vacuous assertion is
        // worse than none: it reads as coverage.
        //
        // What IS still worth pinning is the relation the gate actually depends on.
        assertLe(AUX.committedOf(address(CORE)), tot3,
                 "a band's own committed figure can never exceed the joint total");
        assertEq(tot3, CORE.committedUsd18(),
                 "committedUsd18 must be the accountant's total, not a per-band figure");

        _drift();
    }

    /// @dev §THE-DRIFT. One swap already shows `POOLED_USD` falling while `committedOf` holds. If
    ///      that is the root, repeating the swap must erode headroom MONOTONICALLY with committed
    ///      pinned -- and the gap `basketUsd - POOLED_USD` is the phantom basket claim, growing by
    ///      the USD each swap removed. Own frame for the same no-via_ir reason as `_swapLeg`.
    function _drift() private {
        console.log("--- repeated swaps: does the gap widen? ---");
        for (uint n; n < 8; ++n) {
            vm.deal(User01, 5 ether);
            vm.prank(User01);
            try AUX.swap{value: 1 ether}(address(USDC), address(WETH), false, 0, 0) {}
            catch { console.log("swap reverted at iteration", n); break; }

            (uint[15] memory dn,,, uint lossN) = AUX.get_deposits();
            uint ceilN = dn[14] > lossN ? dn[14] - lossN : 0;
            uint totN  = AUX.committedTotal();
            uint pooled18 = CORE.POOLED_USD() * 1e12;
            console.log("iter", n);
            console.log("   committed :", totN);
            console.log("   POOLED*1e12:", pooled18);
            console.log("   phantom   :", totN > pooled18 ? totN - pooled18 : 0);
            console.log("   headroom  :", ceilN > totN ? ceilN - totN : 0);
        }
    }
}
