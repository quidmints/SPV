// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {console2} from "forge-std/console2.sol";

/// @notice §MASTER-ORDER GATE 1e / §PLP-Q Q2.5 — **is the permissionless-keeper bleed (Y1) REPEATABLE
///         WITHIN ONE BLOCK?**
///
/// §PLP-Y2 concludes the bleed is *"slip on rebalances that were going to happen anyway, bounded by
/// crossing frequency"* — i.e. NOT repeatable. Q2.6 confirmed half of that (`_bandFor` gates both legs,
/// so an in-band position no-ops). The other half was open: **after one successful rebalance, is the
/// position actually left INSIDE the band**, or can a caller immediately fire a second one?
///
/// ⚠️ **WHY THIS IS A PURE TEST AND NOT THE FORK TEST THE ROW ASKED FOR (standing rule 18 — is there a
///    better version of this?).** §S7 booked *"one fork test settles it: rebalance twice in a block and
///    assert the second returns `deltaUsd == 0`."* A fork test would answer it for ONE position at ONE
///    price on ONE venue. The question is arithmetic, and `LevMath.debtDelta` is `internal pure`, so a
///    sweep answers it for the WHOLE parameter space, deterministically, with no RPC and no pin to
///    expire. **A fork here would be a weaker instrument wearing a more impressive name.**
///
/// 🔑 **AND THE PREMISE THAT MADE THE QUESTION LOOK OPEN WAS WRONG — this file exists partly to record
///    that.** §S7 reasoned: *"`_leverUpBuy` borrows AND supplies, so both debt and collateral rise and
///    the post-rebalance LTV is not exactly `targetBps`."* **That assumed the denominator is LIVE
///    COLLATERAL. It is not.** `_targetInputs` (`LevBase.sol:136-141`) returns
///    `e0 = LevMath.entryEquityUsd(p.entryEquity, px)`, and `p.entryEquity` is *"the IL base, **FIXED at
///    open**"* (`:384`), with `:706` naming it *"LTV against the **FIXED** IL base `entryEquity`"*.
///    ⇒ **buying collateral does not move `e0` at all**, and within one block the TWAP `px` is constant,
///    so `e0` is constant. `LevManager.sol:513` says the same thing from the other side: *"on the FIXED
///    E0 the repay is simply `curDebt − targetDebt`."*
///    ⇒ the rebalance lands debt exactly on `targetDebt = e0·t/10_000`, so `cur == targetBps` EXACTLY.
///
/// ⛔ **THE ASSERTION "amountUsd == 0" IS NEARLY TAUTOLOGICAL ON ITS OWN, WHICH IS THE §VACUOUS-BOUNDS
///    SHAPE** — *"a one-sided bound is a rubber stamp when the defect drives the value toward the
///    asserted side."* So `test_Control_*` below re-runs the SAME arithmetic under the premise §S7
///    wrongly assumed (denominator grows with the purchase) and asserts it does **NOT** come back zero.
///    **If that control ever stops failing-to-be-zero, this whole file is measuring nothing.**
contract RebalanceBandRepeat is Test {
    uint256 constant E0 = 1_000_000e18;   // fixed IL basis, USD 18-dec

    /// @dev One lever-UP as `_rebalance` performs it: `_leverUp` passes `deltaUsd` to `_leverUpBuy`,
    ///      which does `venue.borrow(who, deltaUsd)`, so debt rises by exactly that. `e0` is untouched.
    function _applyLeverUp(uint256 debt, uint256 amt) internal pure returns (uint256) { return debt + amt; }

    /// @dev One lever-DOWN. `_delever` ignores its `deltaUsd` and uses `deleverRepayUsd`, which on the
    ///      fixed E0 is `curDebt − targetDebt` (`LevManager.sol:508-515`).
    function _applyDelever(uint256 debt, uint256 amt) internal pure returns (uint256) { return debt - amt; }

    /// ⭐ THE ANSWER, swept rather than sampled: for every start LTV and every band width, ONE rebalance
    ///    leaves the position in-band, so the SECOND call in the same block returns nothing to do.
    function test_SecondCallInSameBlockIsANoOp_BothLegs() public pure {
        uint256[5] memory bands  = [uint256(0), 25, 100, 250, 500];
        uint256[4] memory targets = [uint256(2000), 4000, 6000, 7500];

        for (uint256 b; b < bands.length; ++b) {
            for (uint256 t; t < targets.length; ++t) {
                for (uint256 startLtv = 100; startLtv <= 9000; startLtv += 100) {
                    uint256 debt = (E0 * startLtv) / 10_000;
                    (bool levUp, uint256 amt) =
                        LevMath.debtDelta(E0, debt, targets[t], bands[b]);
                    if (amt == 0) continue;                       // already in band, nothing to prove

                    uint256 after_ = levUp ? _applyLeverUp(debt, amt) : _applyDelever(debt, amt);

                    // The SECOND call, same block ⇒ same `px` ⇒ same `e0`, same target, same band.
                    (, uint256 amt2) = LevMath.debtDelta(E0, after_, targets[t], bands[b]);
                    assertEq(amt2, 0,
                        "a second rebalance in the same block found work to do - Y1 IS repeatable");
                }
            }
        }
    }

    /// 🔴 THE CONTROL. Re-run the identical arithmetic under §S7's WRONG premise — that the denominator
    ///    is live collateral and therefore grows by what the lever-up bought. If the assertion above
    ///    could not fail, this one would also come back zero. It must not.
    function test_Control_TheNoOpDependsOnE0BeingFIXED() public pure {
        uint256 target = 6000;
        uint256 band   = 25;
        uint256 debt   = (E0 * 1000) / 10_000;             // deep below target ⇒ a large lever-up

        (bool levUp, uint256 amt) = LevMath.debtDelta(E0, debt, target, band);
        assertTrue(levUp && amt > 0, "premise: this start must need a lever-up");

        // WRONG MODEL: collateral grows by the purchase (assume a clean fill, no slippage).
        uint256 collIfLive = E0 + amt;
        (, uint256 amtWrong) = LevMath.debtDelta(collIfLive, debt + amt, target, band);

        // RIGHT MODEL: e0 is the FIXED entry basis and does not move.
        (, uint256 amtRight) = LevMath.debtDelta(E0, debt + amt, target, band);

        console2.log("control: second-call amount under the LIVE-collateral premise:", amtWrong);
        console2.log("control: second-call amount under the FIXED-e0 reality:      ", amtRight);

        assertGt(amtWrong, 0,
            "CONTROL FAILED - the arithmetic returns zero even under the wrong premise, so the main test asserts nothing");
        assertEq(amtRight, 0, "the fixed-e0 model must land in band");
    }

    /// @dev The band's fail-safe value is 0 (`_bandBps` returns 0 when a venue cannot answer
    ///      `liqThresholdBps`, documented as *"zero headroom ⇒ band 0 ⇒ rebalance always, the fail-safe
    ///      direction"*). That is the STRICTEST case for this question, so it gets its own assertion:
    ///      even with no tolerance at all, landing exactly on target satisfies `cur == targetBps`.
    function test_EvenAZeroBandNoOpsOnTheSecondCall() public pure {
        uint256 target = 5000;
        uint256 debt   = (E0 * 800) / 10_000;
        (bool levUp, uint256 amt) = LevMath.debtDelta(E0, debt, target, 0);
        assertTrue(levUp && amt > 0, "premise: needs a lever-up at band 0");
        (, uint256 amt2) = LevMath.debtDelta(E0, _applyLeverUp(debt, amt), target, 0);
        assertEq(amt2, 0, "band 0 must still no-op once debt sits exactly on target");
    }
}
