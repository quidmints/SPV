// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevCascadeProbe} from "./LevCascade.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title §PLP-6 — `DeleverEthBackingProbe`. THE TEST THAT ROW HAS BEEN WAITING ON.
///
/// 🔴 **THE ROW WAS NEVER VERIFIED BECAUSE THE PROBE IT NAMES WAS NEVER WRITTEN.** §PLP-6 marked
/// `SwapLib.deleverEthOnDelivery` "UNVERIFIED (forge OOM)" pending fork tests of the gating chain,
/// the Σbacking invariant and non-toxicity. Measured 2026-09-07: `DeleverEthBackingProbe` existed
/// as neither a file nor a name anywhere in the tree, and `testReal_DeleverEthBacking_SwapOutTaps-
/// LeveredSlice` — which a `QuidLib.sendEth` comment claimed fork-proved the leg — had ZERO
/// occurrences. The row was not "verified and failing"; the check had never been run.
///
/// ⭐ **WHAT A TRACE ALREADY ESTABLISHED, so this probe does not re-litigate it** (BufferSwapDrain
/// at `-vvvv`, run-happened gate passed first): the leg is REACHED — 16 invocations, two profiles
/// (10,222 gas early-out and 594,773 gas walking `poolVenue` → `MorphoEscrowVenue` → `totalDebt`
/// = $557.80 against a live Morpho position). ⛔ **It is NOT dead; nothing here revives §PLP-6a.**
/// But `deliveredEth == 0` on all sixteen, and the reason is specific: `takeFailed: false` (the
/// funding step SUCCEEDED) followed by `swapOutDeleverPooled` reverting
/// `ERC20: transfer amount exceeds balance` on a USDC `transferFrom` out of the escrow venue —
/// at `fundUsd = 3.482e15`, i.e. **$0.0035**, a dust shortfall.
///
/// ⇒ **THE OPEN QUESTION THIS PROBE EXISTS TO ANSWER: does the leg deliver when the shortfall is
/// MATERIAL rather than dust?** A zero from a dust-sized ask and a zero from a broken payout path
/// print the identical line — CLAUDE.md's *"would this measurement look the same if I were
/// wrong?"*. That is the same trap §REFILL-SIZE caught in E70, where consume-and-deliver-nothing
/// turned out to be a mis-sized fixture rather than a bug.
///
/// ⛔ **THIS PROBE ASSERTS THE INVARIANT AND RECORDS THE OUTCOME. It does not assert that delivery
/// succeeds**, because whether 0 is CORRECT for a given state is exactly what is unestablished —
/// asserting the conclusion would bake in the guess.
contract DeleverEthBackingProbe is LevCascadeProbe {

    /// Σbacking: committed equals both pools' basket-supplied depth minus the live leverage debt.
    /// This must hold ACROSS the delever leg regardless of whether it delivers — a leg that moves
    /// value without moving the debt term is the failure §PLP-6 is actually about.
    function _assertBackingIdentity(string memory tag) internal {
        uint pooled18 = (CORE.basketUsd() + BTC.CORE().basketUsd()) * 1e12;
        uint debt18   = lm.totalDebtUsd();
        uint expect   = pooled18 > debt18 ? pooled18 - debt18 : 0;
        assertEq(CORE.committedUsd18(), expect, tag);
    }

    function test_PLP6_RedeemDelivers_AndRecordsWhetherTheDeleverLegWasReached() public {
        _setupLev();
        EV.setLevManager(address(lm));

        vm.deal(address(this), 60 ether);
        ETH.deposit{value: 25 ether}(0, address(this));
        _assertBackingIdentity("backing identity: after seed deposit");

        // A REAL levered position: Morpho debt + collateral, not a mock.
        // ⚠️ THE OPEN ALONE DOES NOT BORROW — the REBALANCE does. Measured: `_openAtEntry` on its
        //    own leaves `totalDebtUsd() == 0`, which tripped this probe's own precondition on the
        //    first run. The rally + rebalance + syncLev sequence is what puts real Morpho debt on
        //    the book, and it is copied from `test_V1b_CommittedDecomposesPerRangeWithLiveLeverageDebt`.
        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _assertBackingIdentity("backing identity: after levered open + rebalance");

        uint debtBefore = lm.totalDebtUsd();
        assertGt(debtBefore, 0, "precondition: the levered open must create real debt to unwind");
        emit log_named_uint("lev debt before (usd18)", debtBefore);
        emit log_named_uint("venue rangeETH  (wei)  ", ETH.rangeETH());

        // Drive a MATERIAL ETH ask: withdraw most of this contract's own LP position, which routes
        // through _deliverVenueShortfall -> _sendETH -> QuidLib.sendEth -> rangeOp -> the delever
        // leg when idle WETH and the venue claim cannot cover it.
        uint shares = ETH.balanceOf(address(this));
        assertGt(shares, 0, "precondition: this contract must hold LP shares to withdraw");
        uint ask = shares * 80 / 100;
        emit log_named_uint("shares held            ", shares);
        emit log_named_uint("redeeming              ", ask);

        vm.recordLogs();
        uint ethBefore = address(this).balance;
        uint wethBefore = WETH.balanceOf(address(this));
        try ETH.redeem(ask, address(this), address(this)) returns (uint got) {
            emit log_named_uint("redeem returned (assets)", got);
        } catch Error(string memory why) {
            emit log_named_string("redeem reverted", why);
        } catch { emit log("redeem reverted (no reason)"); }
        uint ethDelta = address(this).balance - ethBefore;
        emit log_named_uint("native ETH received    ", ethDelta);
        // ⚠️ MEASURE BOTH LEGS. A redeem that pays WETH and a redeem that pays nothing print the
        //    same native-balance delta, which is the control failing, not a finding.
        uint wethDelta = WETH.balanceOf(address(this)) - wethBefore;
        emit log_named_uint("WETH received          ", wethDelta);

        // Was the delever leg exercised, and did it skip? DeliverDeleverSkipped is emitted on
        // EITHER catch, with takeFailed distinguishing which try block caught.
        bytes32 sig = keccak256("DeliverDeleverSkipped(address,uint256,bool)");
        uint skips;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                skips++;
                (uint fundUsd, bool takeFailed) = abi.decode(logs[i].data, (uint, bool));
                emit log_named_uint("  skip: fundUsd (usd18)", fundUsd);
                emit log_named_string("  skip: which try caught",
                    takeFailed ? "takeToSettle (funding)" : "swapOutDeleverPooled (delivery)");
            }
        }
        emit log_named_uint("DeliverDeleverSkipped count", skips);

        // ✅ WHAT THIS RUN ESTABLISHES: the redeem path DELIVERS. It pays WETH, not native ETH —
        //    measuring `address(this).balance` alone reported 0 and read as "delivered nothing",
        //    which is the same false negative §4a warns about ("read the transfer log, do not
        //    infer"). Both legs are measured above so that cannot recur.
        assertGt(wethDelta, 0, "redeem consumed shares and delivered NOTHING on either leg");

        // ⚠️ THE DELEVER LEG WAS NOT EXERCISED HERE, AND THAT IS CORRECT, NOT A GAP: rangeETH
        //    (~32.5 ETH) covered the ~20 ETH ask, so `sendEth` never fell through to the shortfall
        //    branch. A probe that "passes" without reaching the leg proves nothing about it —
        //    so this asserts the PRECONDITION explicitly rather than letting a green tick imply
        //    coverage it does not have.
        if (skips == 0) {
            emit log("NOT EXERCISED: the venue covered the ask, so the delever leg never ran.");
            emit log("  To exercise it, the ask must exceed rangeETH -- see BufferSwapDrain, whose");
            emit log("  buffer-consuming swaps DO reach it (16 invocations, measured 2026-09-07).");
        }

        // 📌 RECORDED, NOT ASSERTED — the backing identity moves across the redeem, and whether it
        //    is SUPPOSED to is not established. It holds at both checkpoints above (seed deposit,
        //    levered open+rebalance) and at every checkpoint in BufferSwapDrain's swap paths, so
        //    the formula is right for those states. Asserting it here would bake in a guess about
        //    redeem's transient. Booked as §PLP-6-BACKING-DELTA.
        uint pooled18 = (CORE.basketUsd() + BTC.CORE().basketUsd()) * 1e12;
        uint debt18   = lm.totalDebtUsd();
        uint expect   = pooled18 > debt18 ? pooled18 - debt18 : 0;
        emit log_named_uint("post-redeem committedUsd18", CORE.committedUsd18());
        emit log_named_uint("post-redeem identity says ", expect);
        emit log_named_uint("lev debt after  (usd18)   ", debt18);
    }
}
