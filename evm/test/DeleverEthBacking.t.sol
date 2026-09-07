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

    /// 🔬 §PLP-6-BACKING-DELTA's RESIDUAL — **THE SIBLING TERM, EXERCISED.**
    ///
    /// The single-range probe below proved the gap is a STALE PUSH: `committedUsd18()` is
    /// `AUX.committedTotal()`, the SUM of the last figures pushed by `_reportEquity()`, and a
    /// de-lever moves `basketUsd`/debt through a path that never reaches the reporting site. It
    /// self-heals on that range's next mint or burn, and the backing gate re-pushes THIS range on
    /// the line before `require(committedUsd18() <= haircutTvl)` — so a range never reads its own
    /// stale figure.
    ///
    /// ⚠️ **WHAT THAT ARGUMENT DOES NOT COVER IS THE SIBLING.** §BACKING-DEAD says the gate sees
    /// *"THIS range's new equity, and the sibling's LAST PUSHED figure"*. So range B's gate reads
    /// range A's stale term. That could not be exercised in the single-range probe because BTC was
    /// 0 throughout — reported 0, live 0, nothing to be stale against.
    ///
    /// This builds BOTH ranges: an active BTC leg, a de-lever on ETH, then a BTC mint BEFORE ETH
    /// re-pushes. ⛔ It asserts the EXPOSURE (that BTC's gate ran while ETH's term was stale and
    /// LOW), not a loss — under-stating commitment makes the gate MORE permissive, and whether any
    /// reachable state turns that into an over-commit is a separate question this does not claim.
    function test_PLP6_SiblingTermIsStaleAcrossADeleverOnTheOtherRange() public {
        _setupLev();
        EV.setLevManager(address(lm));
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 10 ether}(0, address(this));

        // ETH: a real levered position, so there is a de-lever to run.
        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _realignRangeToReal();

        // BTC: make the sibling REAL. Without this the sibling term is 0 and cannot be stale —
        // which is exactly why the single-range probe could not reach this state.
        AUX.setBTCChannels(address(this));
        BTC.requestDeposit(User01, 2e7);
        uint btcReported0 = AUX.committedOf(address(BTC.CORE()));
        assertGt(btcReported0, 0, "PREMISE: the BTC range must be active, else there is no sibling");
        emit log_named_uint("BTC reported (pre)     ", btcReported0);

        // ETH de-lever: the state change that moves basketUsd/debt off the reporting path.
        vm.prank(lps[0]);
        ETH.withdraw(type(uint).max, lps[0], lps[0]);
        assertEq(venue.debtOf(lps[0]), 0, "PREMISE: the de-lever must have run");

        uint ethStale = AUX.committedOf(address(CORE));
        uint ethLive  = CORE.basketUsd() * 1e12 - lm.totalDebtUsd();
        emit log_named_uint("ETH reported (stale)   ", ethStale);
        emit log_named_uint("ETH live               ", ethLive);
        assertTrue(ethStale != ethLive, "PREMISE: ETH's pushed term must actually be stale here");

        // 🔴 THE EXPOSURE: mint on BTC while ETH's term is stale. BTC's own `_reportEquity` runs
        //    before its gate, so BTC is fresh — but the SUM the gate compares against carries
        //    ETH's stale figure.
        uint committedDuringBtcMint = CORE.committedUsd18();
        uint liveTotal = ethLive + BTC.CORE().basketUsd() * 1e12;
        emit log_named_uint("committedUsd18 (sum)   ", committedDuringBtcMint);
        emit log_named_uint("live total             ", liveTotal);

        BTC.requestDeposit(User01, 1e7);   // a second BTC mint -> BTC re-pushes, ETH does not

        uint ethAfterBtcMint = AUX.committedOf(address(CORE));
        emit log_named_uint("ETH reported after BTC mint", ethAfterBtcMint);
        // ⛔ NOT ASSERTED, BECAUSE IT CANNOT FAIL: "a BTC mint does not refresh ETH's term" is
        //    structural — `Aux.report` writes `committedOf[msg.sender]`, so only the reporting
        //    range's slot can move. Asserting it would be restating the source as a measurement.
        //    Logged so the mechanism is visible; the assertion below is the part that can fail.

        // 🔴 THE ASSERTION THAT CAN FAIL: while ETH's term is stale, the aggregate the backing gate
        //    reads is UNDERSTATED by a material amount, and a sibling mint completes against it.
        //    This depends on the de-lever actually having moved value off the reporting path — if
        //    it had not, or if some path re-pushed ETH, the gap would be 0 and this would fail.
        assertGt(liveTotal, committedDuringBtcMint,
                 "SIBLING EXPOSURE: the aggregate must be understated while the sibling term is stale");
        uint understated = liveTotal - committedDuringBtcMint;
        emit log_named_uint("understatement (live - sum)", understated);
        assertGt(understated, 1e21,
                 "the understatement must be MATERIAL (>1000 usd18), not dust rounding");

        // ⚠️ WHAT THIS DOES **NOT** ESTABLISH, stated so the row cannot be over-read: no gate was
        //    shown to PASS WHEN IT SHOULD HAVE FAILED. That needs a state where
        //    `liveTotal > haircutTvl >= committedUsd18()`, i.e. the understatement straddles the
        //    bound. Understating commitment makes the gate more permissive, so the exposure is
        //    real in direction; its reachability is a separate question and is NOT claimed here.
    }

    function test_PLP6_RedeemDelivers_AndRecordsWhetherTheDeleverLegWasReached() public {
        // ⚠️ RECORD FROM THE FIRST LINE. Recording just before the withdraw reported `skips: 0`
        //    — CORRECTLY for that window, and misleadingly overall: the leg actually runs during
        //    SETUP (rally/rebalance/realign) at trace lines 2488 and 4450, while `recordLogs` sat
        //    at 17085. A window that starts after the event is a control failure, not a result.
        vm.recordLogs();
        _setupLev();
        EV.setLevManager(address(lm));

        // ⚠️ SIZED FROM `test_G7_WithdrawPastFreeDepthAutoDeLevers`, NOT INVENTED. My first
        //    version deposited 25 ETH and withdrew 80% as a PLAIN LP; rangeETH (~32.5) covered the
        //    ask every time, so the shortfall branch never ran and the probe proved nothing about
        //    the leg. G7 reaches it by making free depth SMALL (10 ETH) and having the LEVERED LP
        //    withdraw `type(uint).max` — past free depth is exactly the state that forces the
        //    auto-de-lever. Copying the state that is known to reach the code under test beats
        //    inventing one that looks reasonable.
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 10 ether}(0, address(this));
        _assertBackingIdentity("backing identity: after seed deposit");

        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _realignRangeToReal();

        uint debtBefore = lm.totalDebtUsd();
        assertGt(debtBefore, 0, "precondition: the levered open must create real debt to unwind");
        assertGt(venue.debtOf(lps[0]), 0, "precondition: the position must carry real venue debt");
        emit log_named_uint("lev debt before (usd18)", debtBefore);
        emit log_named_uint("venue rangeETH  (wei)  ", ETH.rangeETH());
        emit log_named_uint("deliverableETH  (wei)  ", ETH.deliverableETH());
        emit log_named_uint("levered LP debtOf      ", venue.debtOf(lps[0]));

        // THE ASK THAT EXCEEDS FREE DEPTH: the levered LP exits everything.
        uint wethBefore = WETH.balanceOf(lps[0]);
        uint ethBefore  = lps[0].balance;
        vm.prank(lps[0]);
        ETH.withdraw(type(uint).max, lps[0], lps[0]);
        uint wethDelta = WETH.balanceOf(lps[0]) - wethBefore;
        uint ethDelta  = lps[0].balance - ethBefore;
        emit log_named_uint("LP native ETH received ", ethDelta);
        emit log_named_uint("LP WETH received       ", wethDelta);

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
        assertGt(wethDelta + ethDelta, 0, "withdraw consumed the position and delivered NOTHING on either leg");

        // ⚠️ THE DELEVER LEG WAS NOT EXERCISED HERE, AND THAT IS CORRECT, NOT A GAP: rangeETH
        //    (~32.5 ETH) covered the ~20 ETH ask, so `sendEth` never fell through to the shortfall
        //    branch. A probe that "passes" without reaching the leg proves nothing about it —
        //    so this asserts the PRECONDITION explicitly rather than letting a green tick imply
        //    coverage it does not have.
        // 🔴 THE POINT OF THE PROBE: past free depth the auto-de-lever MUST run and MUST repay.
        assertEq(venue.debtOf(lps[0]), 0, "PLP-6: past free depth the venue debt must be repaid in full");
        ( , , , , bool stillOpen) = lm.pos(lps[0]);
        assertTrue(!stillOpen, "PLP-6: the position must close, not be left half-unwound");
        emit log_named_uint("lev debt after  (usd18)", lm.totalDebtUsd());

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
        // 🔬 DECOMPOSE THE GAP PER RANGE. `committedUsd18` is NOT computed live — it is
        //    `AUX.committedTotal()`, the SUM OF THE LAST REPORTED figures
        //    (`committedOf[CORE] + committedOf[BTC_CORE]`), pushed by `_reportEquity()`. So a
        //    mismatch is either a STALE PUSH on one range or a genuine value gap, and only the
        //    per-range split tells them apart.
        address btcCore = address(BTC.CORE());
        uint ethReported = AUX.committedOf(address(CORE));
        uint btcReported = AUX.committedOf(btcCore);
        uint ethLive = CORE.basketUsd() * 1e12;
        uint btcLive = BTC.CORE().basketUsd() * 1e12;
        emit log_named_uint("  ETH reported            ", ethReported);
        emit log_named_uint("  ETH live basketUsd*1e12 ", ethLive);
        emit log_named_uint("  BTC reported            ", btcReported);
        emit log_named_uint("  BTC live basketUsd*1e12 ", btcLive);
        emit log_named_uint("  debt term (totalDebtUsd)", debt18);
        // 🔬 IS IT A STALE PUSH OR A VALUE GAP? `_reportEquity` fires on BOTH arms of
        //    `_poolUsdInRange`, so ANY mint or burn on this range re-pushes. If the gap closes
        //    after a trivial deposit, the accounting was never wrong — the aggregate had simply
        //    not been told about a change that did not route through the reporting site.
        vm.deal(address(this), 2 ether);
        ETH.deposit{value: 1 ether}(0, address(this));
        uint afterReport = AUX.committedOf(address(CORE));
        uint liveAfter   = CORE.basketUsd() * 1e12 - lm.totalDebtUsd();
        emit log_named_uint("  AFTER a 1-ETH deposit: reported", afterReport);
        emit log_named_uint("  AFTER a 1-ETH deposit: live    ", liveAfter);
        emit log_named_int ("  residual gap (reported - live) ",
                            int256(afterReport) - int256(liveAfter));
        // 🔴 §PLP-6-BACKING-DELTA, CLOSED: the pre-deposit gap is a STALE PUSH, not a value leak.
        //    Any mint or burn on this range re-pushes and the aggregate becomes exact again.
        assertEq(afterReport, liveAfter,
                 "PLP-6-BACKING-DELTA: the reported aggregate must be exact once the range re-pushes");
        emit log_named_uint("lev debt after  (usd18)   ", debt18);
    }
}
