// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles} from "./Alles.t.sol";
import {console} from "forge-std/console.sol";
import {BandBacking} from "../src/BandBacking.sol";
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
///         EXACT public quantities the deployed gate uses (`BandBacking.committedOf`,
///         `Core.bandEquityUsd18`, `AUX.get_deposits()[14]`) so its numbers ARE the gate's.
///         Asserting a conclusion here is how a probe stops being able to disprove it.
contract BackingGateSplit is Alles {

    function test_backingGate_perBandSplit() public {
        _stageDepeg();  // heal the fork's default depeg; build real basket backing

        BandBacking backing = BandBacking(address(CORE.BACKING()));

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
        uint sum;
        for (uint i; ; ++i) {
            address band;
            try backing.bands(i) returns (address b) { band = b; } catch { break; }
            uint reported = backing.committedOf(band);
            uint live     = Core(payable(band)).bandEquityUsd18();
            sum += reported;
            console.log("band            :", band);
            console.log("  committedOf   :", reported);
            console.log("  live equity   :", live);   // divergence here == a STALE push (§A.16b clock)
            console.log("  POOLED_USD    :", Core(payable(band)).POOLED_USD());
        }

        uint reportedTotal = backing.total();
        console.log("--- sum ---");
        console.log("sum(committedOf)  :", sum);
        console.log("BandBacking.total :", reportedTotal);
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
        for (uint i; ; ++i) {
            address band;
            try backing.bands(i) returns (address b) { band = b; } catch { break; }
            console.log("band            :", band);
            console.log("  committedOf   :", backing.committedOf(band));
            console.log("  POOLED_USD    :", Core(payable(band)).POOLED_USD());
        }
        (uint[15] memory d2,,, uint loss2) = AUX.get_deposits();
        uint ceil2 = d2[14] > loss2 ? d2[14] - loss2 : 0;
        console.log("TVL after         :", d2[14]);
        console.log("committed after   :", backing.total());
        if (backing.total() > ceil2) console.log("OVER BY           :", backing.total() - ceil2);
        else console.log("headroom left     :", ceil2 - backing.total());

        _swapLeg(backing);
    }

    /// @dev Own frame — `via_ir` is false in this repo ON PURPOSE, so stack-too-deep is solved by
    ///      giving the work its own frame, never by turning on the IR pipeline.
    function _swapLeg(BandBacking backing) private {
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
        uint tot3  = backing.total();
        console.log("TVL after swap    :", d3[14]);
        console.log("committed after   :", tot3);
        console.log("ETH band POOLED_USD:", CORE.POOLED_USD());
        if (tot3 > ceil3) console.log("OVER BY           :", tot3 - ceil3);
        else console.log("headroom left     :", ceil3 - tot3);

        // The one thing that IS an invariant regardless of which explanation holds: the accountant's
        // total must equal the sum of its parts. If these disagree the bug is in BandBacking itself,
        // not in either band's attribution -- and that would make every other reading here moot.
        uint parts;
        for (uint i; ; ++i) {
            address band;
            try backing.bands(i) returns (address b) { band = b; } catch { break; }
            parts += backing.committedOf(band);
        }
        assertEq(tot3, parts, "BandBacking.total must equal the sum of committedOf");

        _drift(backing);
    }

    /// @dev §THE-DRIFT. One swap already shows `POOLED_USD` falling while `committedOf` holds. If
    ///      that is the root, repeating the swap must erode headroom MONOTONICALLY with committed
    ///      pinned -- and the gap `basketUsd - POOLED_USD` is the phantom basket claim, growing by
    ///      the USD each swap removed. Own frame for the same no-via_ir reason as `_swapLeg`.
    function _drift(BandBacking backing) private {
        console.log("--- repeated swaps: does the gap widen? ---");
        for (uint n; n < 8; ++n) {
            vm.deal(User01, 5 ether);
            vm.prank(User01);
            try AUX.swap{value: 1 ether}(address(USDC), address(WETH), false, 0, 0) {}
            catch { console.log("swap reverted at iteration", n); break; }

            (uint[15] memory dn,,, uint lossN) = AUX.get_deposits();
            uint ceilN = dn[14] > lossN ? dn[14] - lossN : 0;
            uint totN  = backing.total();
            uint pooled18 = CORE.POOLED_USD() * 1e12;
            console.log("iter", n);
            console.log("   committed :", totN);
            console.log("   POOLED*1e12:", pooled18);
            console.log("   phantom   :", totN > pooled18 ? totN - pooled18 : 0);
            console.log("   headroom  :", ceilN > totN ? ceilN - totN : 0);
        }
    }
}
