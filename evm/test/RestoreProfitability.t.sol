// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E69 — IS RESTORING THE BAND'S BALANCE NATURALLY PROFITABLE?
///
/// Asked twice by the owner, answered twice by me with an ARGUMENT, and once by citing E25's
/// "0 bps across 300k" as though it settled the matter. IT DOES NOT: E25 measured a BALANCED
/// band under ORDINARY volume. The question is the dislocation in an IMBALANCED band — the only
/// state in which a restorer would act. This fixture asks the actual question.
///
/// TWO ERRORS IN THE FIRST DRAFT OF THIS FILE, RECORDED SO THEY ARE NOT REPEATED:
///   1. DIRECTION INVERTED. I labelled a stable→volatile BUY as "adds volatile to the band".
///      It does the opposite: the band HANDS OUT BTC, so `inv` FALLS and the band gets SCARCER.
///      A volatile→stable SELL is what RAISES `inv`. Every comment was backwards.
///   2. THE SKEW STAYED 0 AND I NEARLY READ THAT AS "NO PREMIUM EXISTS". It was the flush
///      branch: `target = flowEwmaUsd` GROWS with the very volume used to drive the drain, so
///      `inv >= target` held throughout and `wellSkew` correctly returned 0. **The fixture was
///      not reaching the state it was trying to measure.** Hence the explicit inv/target log
///      below, and the early INCONCLUSIVE exit — a measurement that cannot show its own state
///      is indistinguishable from its own bug, which is what CLAUDE.md's control question asks.
///
/// WHAT "PROFITABLE" MEANS HERE. A restorer moves `inv` back toward target and unwinds at oracle
/// elsewhere. It nets only if execution BEATS oracle by more than gas + LP fee. So the measurable
/// is the SIGN of  (what the restorer received) − (what the same size fetches at oracle).
///   > 0 => the curve pays the restorer; an external arb closes the imbalance unaided.
///  == 0 => restoration is priced AT oracle; the restorer is gas + fee NEGATIVE, nobody does it,
///          and the imbalance persists until someone is PAID to fix it.
contract RestoreProfitability is AllesFixture {
    address lpA = User02;
    address drainer = address(0xBEEF02);
    address restorer = address(0xBEEF03);
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

    /// stable → volatile. The band HANDS OUT ETH ⇒ `inv` FALLS ⇒ the band gets SCARCER.
    function _drainEth(uint boldAmt) internal {
        deal(bold, drainer, boldAmt);
        vm.startPrank(drainer);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) {} catch {}
        vm.stopPrank();
        _settle();
    }

    /// The band's scarcity state, in the SAME terms the skew itself computes it.
    function _state() internal view returns (uint invUsd6, uint targetUsd6) {
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        invUsd6 = CORE.POOLED() * px / 1e30;
        targetUsd6 = CORE.flowEwmaUsd();
    }

    /// TOTAL stable value held by `who`, in 18-dec USD, across EVERY basket stable plus QUID.
    /// §E69 — this exists because TWO successive runs reported a zero edge that was really me
    /// reading the WRONG TOKEN: the sell pays out in whichever stable the basket selects, not
    /// necessarily `bold`. Summing all of them takes my guess out of the measurement, so a zero
    /// here means zero PROCEEDS rather than zero KNOWLEDGE of where they went.
    function _stableValue18(address who) internal view returns (uint total) {
        address[] memory ss = AUX.getStables();
        for (uint i = 0; i < ss.length; ++i) {
            uint bal = IERC20(ss[i]).balanceOf(who);
            if (bal == 0) continue;
            uint8 d = IERC20(ss[i]).decimals();
            total += d < 18 ? bal * (10 ** (18 - d)) : bal;
        }
        total += QUID.balanceOf(who);
    }

    function test_E69_IsRestoringNaturallyProfitable() public {
        _seedBasket();
        vm.prank(lpA);
        ETH.deposit{value: 400 ether}(0, lpA);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        (uint inv0, uint tgt0) = _state();
        emit log_named_uint("START inv (usd6)   ", inv0);
        emit log_named_uint("START target (usd6)", tgt0);
        emit log_named_uint("START wellSkew     ", AUX.wellSkew(address(WETH), 0));

        // ---- 1. DRAIN until the band is genuinely SCARCE (inv < target), or give up and SAY SO
        //         rather than reporting a number from a state we never reached.
        for (uint i = 0; i < 30; ++i) {
            _drainEth(40_000 * 1e18);
            (uint iv, uint tg) = _state();
            if (iv < tg) break;
        }
        (uint inv1, uint tgt1) = _state();
        emit log_named_uint("AFTER inv (usd6)   ", inv1);
        emit log_named_uint("AFTER target (usd6)", tgt1);
        emit log_named_uint("AFTER wellSkew     ", AUX.wellSkew(address(WETH), 0));

        if (inv1 >= tgt1) {
            emit log("INCONCLUSIVE: never reached inv < target -- the scarce leg was never live.");
            emit log("Do NOT read a zero edge from this run; the fixture did not reach the state.");
            return;
        }

        // ---- 2. THE RESTORING TRADE: sell ETH back, which RAISES inv toward target.
        //         Measure BOTH plausible payout tokens, so a wrong guess about where proceeds
        //         land cannot masquerade as a zero edge — the first draft's exact failure.
        uint pxNow = AUX.getTWAPforAsset(address(WETH), 1800);   // price AT THE TRADE, not pre-drain
        emit log_named_uint("oracle px PRE-drain ", px);
        emit log_named_uint("oracle px AT-trade  ", pxNow);
        uint sellSize = 20 ether;
        deal(address(WETH), restorer, sellSize);
        uint valueBefore = _stableValue18(restorer);
        vm.startPrank(restorer);
        WETH.approve(address(AUX), sellSize);
        uint minOut = 1;   // the weakest possible demand: ANY non-zero delivery
        AUX.swap(bold, address(WETH), false, sellSize, minOut);
        vm.stopPrank();
        uint wethLeft = WETH.balanceOf(restorer);
        emit log_named_uint("restorer WETH left (0=input taken, 20e18=no-op)", wethLeft);
        uint got = _stableValue18(restorer) - valueBefore;
        emit log_named_uint("restorer got (all stables + QUID, usd18)", got);
        // §S16 / E91 REGRESSION GUARD — ASSERT AT THE RECIPIENT, WHICH IS THE ONLY PLACE THAT KNOWS.
        // The delivery bug this fixture uncovered survived SIX layers of diagnosis because every
        // guard in the stack asserts on a number REPORTED BY THE FAILING CODE: `max` reports the
        // swap's delta (not the user's receipt), `minOut` compares against that same `max`, and the
        // `NothingDelivered` aggregate reads a `sent` that `withdrawFromSP` returned non-zero while
        // transferring nothing. All three were structurally blind. A BALANCE DELTA measured by the
        // caller is the only assertion that cannot be fooled by the code under test — so make it one,
        // not a log line. If BOLD-SP (or any venue) ever stops delivering again, this fails loudly.
        assertGt(got, 0, "S16: swap consumed input and delivered NOTHING to the recipient");
        uint atOracle = sellSize * pxNow / 1e18;   // CONFOUND FIX: compare against the LIVE price
        emit log_named_uint("same size at oracle", atOracle);

        if (got == 0) {
            emit log("INCONCLUSIVE: no proceeds in either token -- payout path still unidentified.");
        } else if (got > atOracle) {
            emit log_named_uint("EDGE bps (POSITIVE)", (got - atOracle) * 10_000 / atOracle);
            emit log("RESULT: the curve PAYS the restorer -- an external arb closes this unaided.");
        } else {
            emit log_named_uint("SHORTFALL bps      ", (atOracle - got) * 10_000 / atOracle);
            emit log("RESULT: restoration is priced AT-OR-BELOW oracle -- it does NOT pay for itself.");
        }
    }
}
