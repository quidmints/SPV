// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {BtcLib} from "../src/imports/BtcLib.sol";

/// @notice §BTC-10b, second pass — the settlement layer's own question: *"where value is created
///         and destroyed."* This one is on the EXIT side of it.
///
///         `BtcLib.resizeBtcLpTail` splits a shrink into two slices and settles each differently:
///           · `nativeSlice` — burned out of the range's depth (`SwapLib.burnInRange`)
///           · `deliveredSlice` — paid for out of pooled USD (`settleDelivered` draws `exactUsd`
///             and mints the LP against it)
///         and the split is `deliveredRaw = shrinkSats − lpPayoutSats`, i.e. whatever left the
///         channel WITHOUT reaching the LP's registered payout script.
///
///         🔴 THE QUESTION THIS FILE ANSWERS: what settles those sats when `exactUsd == 0`?
///         `settleDelivered` opens `deliveredSlice = deliveredRaw` and only THEN returns early on
///         `exactUsd == 0` — so it reports the sats as DELIVERED on the one branch where it
///         delivered nothing: no `drawPooledUsdBtc`, no `subPendingSwapOut`, no mint. The caller
///         then computes `nativeSlice = shrinkSats − deliveredSlice` and excludes them from the
///         burn too. ⇒ NEITHER treatment.
///
///         ⚠️ AND `exactUsd == 0` IS NOT A CORNER — it is one of the two live call sites.
///         `BTCChannels.sol:496` (`_shrinkSplice`, the LP-withdrawal splice) passes 0 always; only
///         the swap-out delivery at `:903` passes a real `so.usd`. Any splice whose transaction
///         costs a miner fee pays the LP less than it shrank, so `deliveredRaw` is the fee.
///
///         📌 `testBtcLp_ResizeSplicePartialClose` already covers `exactUsd == 0` and does NOT
///         reach this: it passes `lpPayout == shrink` ("the LP physically takes the whole shrunk
///         slice"), which makes `deliveredRaw` exactly zero. The gap is one argument wide.
contract BtcResizeDeliveredSlice is AllesFixture {

    /// MEASUREMENT, stated as a prediction before it was run: with `exactUsd == 0` and the LP paid
    /// LESS than the shrink, the LP's shares fall by the FULL `shrinkSats` while the range's depth
    /// falls by only `lpPayoutSats` — the gap being settled by nothing at all.
    function test_resize_withdrawalSpliceUnderpaysTheLp_whatSettlesTheGap() public {
        AUX.setBTCChannels(address(this));

        uint funded = 2e7; // 0.2 BTC
        BTC.requestDeposit(User01, funded);

        // A deliberately LARGE gap, so the mechanism is unambiguous against the `_rebalance()`
        // that `resize` performs on its way in. A real splice fee is ~2,000 sats; the code path
        // does not care which number it is.
        uint shrink = funded / 2;
        uint gap    = shrink / 10;
        uint payout = shrink - gap;

        uint sharesBefore = BTC.totalShares();
        uint pooledBefore = BCORE().POOLED();

        BTC.resize(User01, shrink, payout, 0);

        uint sharesDrop = sharesBefore - BTC.totalShares();
        uint pooledDrop = pooledBefore > BCORE().POOLED() ? pooledBefore - BCORE().POOLED() : 0;

        emit log_named_uint("shrinkSats                ", shrink);
        emit log_named_uint("lpPayoutSats              ", payout);
        emit log_named_uint("gap (shrink - payout)     ", gap);
        emit log_named_uint("lpShares dropped by       ", sharesDrop);
        emit log_named_uint("Core.POOLED dropped by    ", pooledDrop);

        assertEq(sharesDrop, shrink, "PREMISE: the LP is charged the FULL shrink in shares");

        // THE FIX: `settleDelivered` returns 0 when `exactUsd == 0`, because nothing was
        // delivered — so the whole shrink burns out of the range and the two ledgers agree.
        // Before it, this was `payout` (9,000,000 against a 10,000,000 shares drop), leaving the
        // range quoting depth for sats that had left the channel and were owed to nobody.
        assertEq(pooledDrop, shrink,
            "range depth must fall by the FULL shrink when no USD settles the gap");
    }

    /// 🔴 THE THIRD BRANCH, AND IT IS THE ONE THAT NEARLY MADE THE FIX A REGRESSION.
    /// `SwapLib.deleverOnDelivery` clamps at `exactUsd6` (`SwapLib.sol:537`), so it can consume the
    /// WHOLE obligation — and a genuine swap-out delivery then reaches `settleDelivered` with
    /// nothing left to draw. Keying the early return off "is there USD left" instead of "was there
    /// a delivery" would burn the swapper's slice in the range ON TOP of having paid for it out of
    /// pooled USD. That is why the function takes `delevUsd` rather than a pre-netted amount.
    ///
    /// Asserted directly on the library, because `draw == 0` returns BEFORE touching `Core` or
    /// `Quid` — so passing `address(0)` for both proves the absence of those calls: any draw, sub
    /// or mint on this path would revert on a call to the zero address rather than pass quietly.
    function test_settleDelivered_deliveryFullyPaidByTheDelever_stillCountsAsDelivered() public {
        uint deliveredRaw = 1_000_000;
        uint exactUsd     = 500e6;

        assertEq(
            BtcLib.settleDelivered(address(0), deliveredRaw, exactUsd, exactUsd, address(0), address(0)),
            deliveredRaw,
            "a delivery whose USD the de-lever already drew is STILL delivered - it must not "
            "also burn out of the range"
        );

        // And the splice branch, which is what this pass fixed: no delivery, so nothing is
        // delivered and the whole shrink is left to the range burn.
        assertEq(
            BtcLib.settleDelivered(address(0), deliveredRaw, 0, 0, address(0), address(0)),
            0,
            "exactUsd == 0 is the LP-withdrawal splice: nothing delivered these sats"
        );
    }

    /// THE CONTROL, and it is the load-bearing half: the swap-out path passes a REAL `exactUsd`
    /// and MUST keep excluding the delivered slice from the burn — there the gap is the swapper's
    /// sats, and they are settled by `drawPooledUsdBtc` + the LP's mint, not by destroying depth.
    /// A fix that burned the slice unconditionally would double-charge that path, so this asserts
    /// the branch it must not have touched.
    function test_resize_swapOutDelivery_stillExcludesTheDeliveredSliceFromTheBurn() public {
        AUX.setBTCChannels(address(this));

        uint funded = 2e7;
        BTC.requestDeposit(User01, funded);

        uint shrink = funded / 2;
        uint gap    = shrink / 10;      // the swapper's sats
        uint payout = shrink - gap;     // the LP's own slice

        // Prime an obligation so `subPendingSwapOut` has something to consume.
        uint exactUsd = 1_000 * 1e6;
        BTC.addPendingSwapOut(exactUsd);   // routed through the Vault; Core.addPendingSwapOut is `onlyUs`

        uint sharesBefore = BTC.totalShares();
        uint pooledBefore = BCORE().POOLED();

        BTC.resize(User01, shrink, payout, exactUsd);

        uint sharesDrop = sharesBefore - BTC.totalShares();
        uint pooledDrop = pooledBefore > BCORE().POOLED() ? pooledBefore - BCORE().POOLED() : 0;

        emit log_named_uint("[control] lpShares dropped by ", sharesDrop);
        emit log_named_uint("[control] POOLED dropped by   ", pooledDrop);

        assertEq(sharesDrop, shrink, "the LP is still charged the full shrink in shares");
        assertEq(pooledDrop, payout,
            "with USD settling the gap, only the LP's own slice may burn out of the range");
    }
}
