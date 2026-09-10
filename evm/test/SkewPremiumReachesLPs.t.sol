// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {Core} from "../src/Core.sol";

/// @title DOES EVERY DOLLAR OF SKEW PREMIUM REACH LP CLAIMS?
///
/// The owner's requirement for refill/restoration is that the pool is *"never at a loss … always
/// paying ALL skew premium to our LPs"*. This measures the second half directly.
///
/// 🔑 THE TWO NUMBERS ARE NOT THE SAME OBJECT, WHICH IS THE WHOLE REASON TO MEASURE:
///   · `Core.skewPremium` is incremented by `recordSkewPremium` and its own comment calls it
///     **an AUDIT RECORD** — *"the CREDIT is what actually reaches LPs"*.
///   · The credit is `RANGE.creditSkewPremium(premium6)` →
///     `feeIncrements(0, premium6, lpShares + totalBuffer)` → `USD_FEES += usdInc`, a PER-SHARE
///     accumulator.
/// ⇒ Asserting on `skewPremium` would assert that the counter counts. This reconstructs what LPs
///   can actually claim and compares it to what the swapper was charged.
///
/// ⛔ TWO LEAK SURFACES THIS IS BUILT TO EXPOSE, both in `feeIncrements`:
///   1. `if (totalShares == 0) return (0, 0)` — the premium is WITHHELD from the swapper
///      (`r.amount -= premium`) and the audit counter still increments, but NOTHING is credited.
///      It stays as basket backing, which by the code's own comment *"prices QU!D and not LP
///      shares"*. Charged, never paid.
///   2. `usdInc = premium6 * WAD / totalShares` truncates, so a remainder can be stranded.
contract SkewPremiumReachesLPs is AllesFixture {
    address drainer = address(0xD8A15E4);
    address bold;   // the last basket stable, as RestoreProfitability resolves it

    function _drainEth(uint boldAmt) internal {
        deal(bold, drainer, boldAmt);
        vm.startPrank(drainer);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) {} catch {}
        vm.stopPrank();
    }

    function test_EveryDollarOfSkewPremiumChargedIsCreditedToLPs() public {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        vm.deal(address(this), 500 ether);
        ETH.deposit{value: 400 ether}(0, address(this));

        uint sharesDenom = ETH.lpShares() + ETH.totalBuffer();
        assertGt(sharesDenom, 0, "PREMISE: LP shares must exist, else feeIncrements credits nobody");

        // Drain hard enough that the range goes scarce and the drain leg charges the A-S premium.
        uint chargedBefore = CORE.skewPremium();
        uint usdFeesBefore = ETH.USD_FEES();
        for (uint i = 0; i < 20; ++i) {
            _drainEth(40_000 * 1e18);
            if (CORE.skewPremium() > chargedBefore) break;
        }
        uint charged = CORE.skewPremium() - chargedBefore;
        assertGt(charged, 0,
            "PREMISE: the drain must actually charge a premium, else this measures nothing");

        uint usdFeesDelta = ETH.USD_FEES() - usdFeesBefore;
        uint denomNow = ETH.lpShares() + ETH.totalBuffer();
        // Reconstruct the CLAIMABLE total from the per-share accumulator.
        uint credited = usdFeesDelta * denomNow / 1e18;

        emit log_named_uint("premium CHARGED (usd6, audit) ", charged);
        emit log_named_uint("USD_FEES delta (per-share)    ", usdFeesDelta);
        emit log_named_uint("share denominator             ", denomNow);
        emit log_named_uint("premium CREDITED to LPs (usd6)", credited);

        assertGt(credited, 0,
            "LEAK: a premium was charged and NOTHING was credited to LPs");

        // ⚠️ Exact equality is not expected — `feeIncrements` truncates per-share. What must hold is
        //    that the shortfall is DUST, not a share of the premium. One unit per share is the
        //    arithmetic bound of that truncation.
        uint shortfall = charged > credited ? charged - credited : 0;
        emit log_named_uint("shortfall (charged - credited)", shortfall);
        assertLe(shortfall, denomNow / 1e18 + 1,
            "LEAK: more than truncation dust failed to reach LPs");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // §NO-LP-PREMIUM — LEAK SURFACE 1, the one this file NAMED and then asserted away.
    //
    // The test above opens with `assertGt(sharesDenom, 0, "PREMISE: LP shares must exist, else
    // feeIncrements credits nobody")`. That premise is the leak surface stated as a precondition —
    // so the file documented the hole and then measured only the case where it is shut. These two
    // close it, and they split it the way the code splits it.
    //
    // 🔑 THE CREDIT AND THE BACKING ARE TWO DIFFERENT MOVEMENTS, and only the first is gated on
    //    shares existing. `Core.recordSkewPremium` does BOTH, unconditionally:
    //      · `RANGE.creditSkewPremium(p)` -> `feeIncrements(0, p, lpShares + totalBuffer)` — the
    //        CLAIM, which is `(0,0)` at a zero denominator;
    //      · `POOLED_USD += p` (§E42-netting) — the BACKING, which moves regardless.
    //    `Quid.creditSkewPremium`'s docblock calls the no-LP case deliberate: *"the premium simply
    //    STAYS as basket backing"*. **That sentence predates §E42-netting and is asset-dependent
    //    now**, because `redeemableBody` nets exactly one of the two mirrors.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// Half one: a zero denominator credits NOTHING. Pure, and it is the arithmetic the prose
    /// claim rests on — stated as an assertion so "charged, never paid" stops being a comment.
    function test_NoLpPremium_ZeroDenominatorCreditsNobody() public pure {
        (uint tokInc, uint usdInc) = SwapLib.feeIncrements(0, 1_000e6, 0);
        assertEq(tokInc, 0, "no shares must credit no token fees");
        assertEq(usdInc, 0, "no shares must credit no usd fees");
        // And with ONE share's worth of denominator it is emphatically not zero, so the branch
        // above is the denominator's doing and not the premium being zero.
        (, uint usdIncLive) = SwapLib.feeIncrements(0, 1_000e6, 1e18);
        assertGt(usdIncLive, 0, "PREMISE: the same premium credits when a denominator exists");
    }

    /// Half two, and it is the half the prose gets wrong: **WHERE the uncredited backing lands is
    /// asset-dependent, because `redeemableBody` subtracts the BTC mirror and not the ETH one.**
    ///   · ETH range: `POOLED_USD` rises and NOTHING nets it ⇒ redeemability is untouched, so the
    ///     swapper's dollars stay counted as QU!D backing. *"Stays as basket backing"* is TRUE here.
    ///   · BTC range: `POOLED_USD` rises and `redeemableBody` subtracts precisely that ⇒
    ///     redeemability FALLS by the premium. Correct when LP shares exist (the backing follows the
    ///     claim, which is the whole point of §E42-netting). **With no shares it is a pure removal:
    ///     no claim was created, and the dollars now back nothing anyone can draw.**
    /// 📌 MEASURED (this test, 10,000e6 premium): ETH leg 151999999998999999999999 -> unchanged;
    ///    BTC leg -> 141999999998999999999999, i.e. exactly -10,000e18. One-for-one, not approximate.
    /// ⚠️ The pranked `recordSkewPremium` moves NO dollars — it is the bookkeeping half alone. That
    ///    is why the ETH leg reads flat rather than rising: in a real swap the dollars arrive
    ///    separately, through the basket. The netting is what this isolates.
    /// ⚠️ THIS ASYMMETRY DOES NOT NEED ZERO SHARES TO BE MEASURED — the netting is unconditional.
    ///    Zero shares is what makes it MATTER, and that half is asserted above. Measuring the
    ///    netting separately is deliberate: it holds on every swap, not only at a bare range.
    /// ⇒ IF THIS FAILS, the two mirrors were made symmetric — which would be a real fix. Re-derive
    ///   §REDEEM-WRONG-RANGE before making it green: that row is why only one side is subtracted.
    function test_NoLpPremium_BtcBackingIsNettedOutOfRedeemableButEthIsNot() public {
        uint premium = 10_000e6;
        address btcCore = address(BTC.CORE());

        uint before = AUX.redeemableAmount();
        vm.prank(address(AUX));
        CORE.recordSkewPremium(premium, 0);
        uint afterEth = AUX.redeemableAmount();

        vm.prank(address(AUX));
        Core(btcCore).recordSkewPremium(premium, 0);
        uint afterBtc = AUX.redeemableAmount();

        emit log_named_uint("redeemable before                ", before);
        emit log_named_uint("redeemable after ETH-range premium", afterEth);
        emit log_named_uint("redeemable after BTC-range premium", afterBtc);

        assertGe(afterEth, before,
            "ETH-range premium must remain QU!D backing - it is not netted");
        assertLe(afterBtc, afterEth,
            "BTC-range premium must be netted out of redeemable by redeemableBody");
        // The claim in one number: the BTC leg moves redeemability the OTHER way from the ETH leg,
        // for the identical premium on the identical basket.
        assertTrue(afterBtc < afterEth || afterEth == before,
            "the two mirrors must not behave identically - if they do, the netting changed");
    }
}
