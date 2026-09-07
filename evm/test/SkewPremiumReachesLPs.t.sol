// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        uint chargedBefore = CORE.skewPremiumCum();
        uint usdFeesBefore = ETH.USD_FEES();
        for (uint i = 0; i < 20; ++i) {
            _drainEth(40_000 * 1e18);
            if (CORE.skewPremiumCum() > chargedBefore) break;
        }
        uint charged = CORE.skewPremiumCum() - chargedBefore;
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
}
