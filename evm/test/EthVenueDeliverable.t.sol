// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {ICurvePool, ILevEquity, IWeETH} from "../src/imports/Interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title `deliverableETH()` BROKEN DOWN INTO ITS TERMS, AND THE BREAKDOWN ASSERTED.
///
/// @notice `QuidLib.deliverableETH` is `_rangeETH` minus two haircuts, and every term of both is a
///         balance or a view this test can read independently. So the breakdown is recomputed from
///         the parts and compared to the number the range reports — which is what makes a silent
///         term-level regression (a leg dropped from the sum, a haircut applied twice, a balance
///         read at the wrong holder) land HERE, on a named term, instead of surfacing three suites
///         away as a mysterious shortfall on LP exit.
///
/// ⛔ THIS FILE USED TO BE A LOG-ONLY DIAGNOSTIC AND CARRIED ~50 LINES OF SCAFFOLDING FOR VENUES
///    THAT NO LONGER EXIST. Deleted 2026-09-08: `struct Acc`, `_scanVault(...)` and
///    `interface I4626Depth`. `_scanVault` iterated the WETH-4626 CURATOR VENUES, tallying par vs
///    withdrawable per vault to isolate an "EXACT ~1/5 shortfall" attributed to a fifth leg. Those three
///    curator venues were removed 2026-08-14, so `_scanVault` had **zero call sites** — `grep -n
///    _scanVault` returned only its own definition — and the surviving test's name still promised
///    the per-venue "DeliverableBreakdown" the deleted helper used to produce. `interface IDecimals`
///    and the `IMorphoV2Probe` / `IERC4626` / `QuidLib` imports went with it; every one of them was
///    reachable only from the dead helper.
/// ⇒ THE NAME NOW MATCHES THE MEASUREMENT, and the measurement is asserted rather than printed.
///   weETH + eETH + idle WETH + levered net equity IS the whole ETH position; there is no per-vault
///   dimension left to iterate, so the breakdown is by TERM, which is what the position actually has.
///   ⛔ Do not restore a vault loop here without restoring the venues — a scan over an empty set
///   prints "0 vaults seen" and reads as coverage.
contract EthVenueDeliverableProbe is AllesFixture {

    /// The four claims, in the order `QuidLib` computes them:
    ///   1. `_rangeETH` is EXACTLY its six terms — weETH marked to eETH, idle WETH at BOTH holders,
    ///      raw eETH at BOTH holders, and the levered NET equity (`QuidLib.sol:478-513`).
    ///   2. `deliverableETH` subtracts the CURVE deferral: weETH beyond 90% of the pool's WETH leg
    ///      cannot be realised, so it defers (`QuidLib.sol:614-621`).
    ///   3. …and then the levered net equity, the same term `_rangeETH` added — unwind-only, never
    ///      drawn by a redemption (`QuidLib.sol:626-630`).
    ///   4. …so the composed result must cover a half exit, which is the property that matters to
    ///      an LP and the only one this file asserted before.
    /// Each is recomputed here from live balances rather than pinned, so the terms cannot drift
    /// apart silently the way the deleted vault scan's assumptions did.
    function test_DeliverableIsRangeMinusCurveDeferralAndLevEquity() public {
        vm.prank(User01);
        ETH.deposit{value: 10 ether}(0, User01);

        uint range = EV.rangeETH();
        uint deliv = EV.deliverableETH();

        // ── The terms of `_rangeETH`, read independently ────────────────────────────────────
        // 🔴 §AUXIDLE — `_rangeETH` NOW HAS **FIVE** TERMS, NOT SIX: `IERC20(eeth).balanceOf(aux)`
        //    was deleted (no code path puts eETH at Aux, and Aux has no way to deliver it, so it
        //    counted phantom backing). `eethAtAux` is KEPT in the recomputation below on purpose —
        //    it is 0 in every state this contract can reach, so the identity still holds, and if it
        //    ever becomes non-zero this assert FAILS and that is the signal we want: eETH arrived
        //    somewhere with no delivery path. Do not "fix" the failure by re-adding the term.
        address weeth = EV.WEETH();
        address eeth  = EV.ETHERFI_EETH();
        uint wBal        = IERC20(weeth).balanceOf(address(EV));
        uint weethAsEth  = wBal > 0 ? IWeETH(weeth).getEETHByWeETH(wBal) : 0;
        uint idleAtQuid  = IERC20(address(WETH)).balanceOf(address(EV));
        uint idleAtAux   = IERC20(address(WETH)).balanceOf(address(AUX));
        uint eethAtQuid  = IERC20(eeth).balanceOf(address(EV));
        uint eethAtAux   = IERC20(eeth).balanceOf(address(AUX));
        // ⚠️ THE try/catch MIRRORS PRODUCTION AND IS NOT DEFENSIVENESS. `_rangeETH` and
        //    `deliverableETH` both wrap this read (`QuidLib.sol:511`, `:627`) and degrade to "no lev
        //    credit" on a revert. Reading it bare here would make the recomputation disagree with the
        //    contract in exactly the case the contract was written to survive — a test failing on the
        //    fixture's shape rather than on the identity it claims to check.
        address lm = EV.LEV_MANAGER();
        uint netEquity;
        if (lm != address(0)) {
            try ILevEquity(lm).totalNetEquity() returns (uint n) { netEquity = n; } catch {}
        }

        emit log_named_decimal_uint("deposited            ", 10 ether, 18);
        emit log_named_decimal_uint("rangeETH             ", range, 18);
        emit log_named_decimal_uint("deliverableETH       ", deliv, 18);
        emit log_named_decimal_uint("  weETH, as eETH     ", weethAsEth, 18);
        emit log_named_decimal_uint("  idle WETH @EthVenue", idleAtQuid, 18);
        emit log_named_decimal_uint("  idle WETH @Aux     ", idleAtAux, 18);
        emit log_named_decimal_uint("  raw eETH @EthVenue ", eethAtQuid, 18);
        emit log_named_decimal_uint("  raw eETH @Aux      ", eethAtAux, 18);
        emit log_named_decimal_uint("  lev NET equity     ", netEquity, 18);
        emit log_named_address     ("  levManager         ", lm);

        // (1) The sum IS the aggregate. A term silently dropped from `_rangeETH` — or counted at one
        //     holder when the code counts it at two — fails here and names itself.
        assertEq(range,
            weethAsEth + idleAtQuid + idleAtAux + eethAtQuid + eethAtAux + netEquity,
            "rangeETH != its terms -- a leg was added, dropped, or read at the wrong holder");

        // (2)+(3) `deliverableETH` = rangeETH − curve deferral − lev net equity, in that order.
        //     The deferral is what makes an unrealisable weETH slice DEFER instead of overstating
        //     delivery; recomputing it against the LIVE Curve balance is what keeps this test from
        //     re-pinning a number that only held on one fork block.
        uint payable_ = (ICurvePool(EV.ETHERFI_CURVE_POOL()).balances(0) * 9) / 10;
        uint deferred = weethAsEth > payable_ ? weethAsEth - payable_ : 0;
        emit log_named_decimal_uint("  curve WETH leg x0.9", payable_, 18);
        emit log_named_decimal_uint("  weETH DEFERRED     ", deferred, 18);
        uint composed = range - deferred;
        composed = composed > netEquity ? composed - netEquity : 0;
        assertEq(deliv, composed,
            "deliverableETH != rangeETH - curveDeferral - levNetEquity: a haircut moved, doubled, or vanished");

        // (4) THE POINT, unchanged: a 5-ETH exit out of a 10-ETH position must be fully deliverable.
        //     Kept as its own assertion because (2)+(3) would still hold if every term were zero.
        assertGe(deliv, 5 ether, "deliverableETH must cover a 5 ETH exit from a 10 ETH position");
    }
}
