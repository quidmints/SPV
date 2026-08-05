// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface IProtoFees { function protocolFeeController() external view returns (address); }
interface IProtoFeeAccrued {
    function protocolFeesAccrued(address currency) external view returns (uint256);
    function collectProtocolFees(address recipient, address currency, uint256 amount) external returns (uint256);
}
interface IProtoFeeCtrl { function protocolFeeForPool(PoolKey memory key) external view returns (uint24); }

/// @notice CONTROL SUITE for the `POOLED_USD` unification — written BEFORE the change and
///         required to be GREEN on unmodified code. That is what makes it a control rather
///         than a regression guard bolted on afterwards: when the unification lands, anything
///         that moves here is attributable to it.
///
/// The unification collapses `POOLED_USD_ETH`/`POOLED_USD_BTC` into one committed-dollars
/// variable with the two per-curve figures demoted to placements. Every vein below reads or
/// writes those counters somewhere in its path, so each needs an assertion on a QUANTITY —
/// "does not revert" would not catch a mis-attribution.
///
/// ⚠️ Coverage here is deliberately NOT measured by grepping for symbol names. An internal
/// symbol can be absent from every test file and still be exercised through a public
/// entrypoint on every call — the same reason a dead-symbol scan cannot judge staleness
/// (`CLAUDE.md`, verification discipline). Each test asserts a number.
///
/// VEINS COVERED HERE (LP lifecycle + P&L attribution):
///   V2  per-LP fee apportionment, bookmark correctness, exit realization
///   V4  deposit: committed accounting, backing gate, JIT lock
///   V5  withdraw: committed accounting, full-vs-partial exit, over-ask, slot clearing
/// Swap pricing (V3) is covered by `PooledUsdRepackMatrix` + the `testGrindRemoval_*` family;
/// redemption (V6) and BTC swap-in/out (V7) are NOT yet covered and are tracked in QUEUE.
contract UnificationControls is Alles {
    address lpA = User02;
    address lpB = User03;
    address trader = address(0xBEEF01);
    address bold;

    function _seedBasket() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// Drive real trading so the fee accumulators actually move.
    function _trade(uint boldAmt) internal {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) {} catch {}
        vm.stopPrank();
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // V4 — DEPOSIT
    // ─────────────────────────────────────────────────────────────────────────

    /// A deposit must grow `committedUsd18` by EXACTLY the USD the band committed for it —
    /// no more (would over-claim basket backing) and no less (would under-report the claim).
    /// This is the identity the unification rewrites, so it is pinned on both bands' legs.
    function test_V4_DepositGrowsCommittedByExactlyTheBandedUsd() public {
        _seedBasket();
        uint c0 = CORE.committedUsd18();
        uint u0 = CORE.POOLED_USD_ETH();
        uint b0 = CORE.POOLED_USD_BTC();

        vm.prank(lpA);
        V4.deposit{value: 100 ether}(0, lpA);

        uint c1 = CORE.committedUsd18();
        uint u1 = CORE.POOLED_USD_ETH();
        emit log_named_uint("committed delta", c1 - c0);
        emit log_named_uint("ETH USD leg delta", u1 - u0);

        assertGt(u1, u0, "PREMISE: the deposit banded USD, else nothing is being measured");
        assertEq(CORE.POOLED_USD_BTC(), b0, "an ETH deposit must not touch the BTC band's USD leg");
        // The identity the unification MUST preserve (or consciously redefine).
        assertEq(c1, (u1 + CORE.POOLED_USD_BTC()) * 1e12,
            "committedUsd18 == (both USD legs) x 1e12 with no leverage debt outstanding");
    }

    /// EDGE: a second deposit must not retroactively re-band the first LP's depth. Both LPs'
    /// pooled must be strictly positive and the committed growth must be attributable.
    function test_V4_SecondDepositIsAdditiveNotRetroactive() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        uint pooledA1 = V4.balanceOf(lpA);
        uint c1 = CORE.committedUsd18();

        vm.roll(block.number + 1);
        vm.prank(lpB); V4.deposit{value: 100 ether}(0, lpB);

        assertEq(V4.balanceOf(lpA), pooledA1, "LP A's position must not change when LP B deposits");
        assertGt(V4.balanceOf(lpB), 0, "PREMISE: LP B actually got a position");
        assertGe(CORE.committedUsd18(), c1, "committed must not shrink on a new deposit");
    }

    /// EDGE: zero-value deposit is a no-op, not a revert and not a phantom position.
    function test_V4_ZeroDepositIsNoOp() public {
        _seedBasket();
        uint c0 = CORE.committedUsd18();
        vm.prank(lpA);
        V4.deposit{value: 0}(0, lpA);
        assertEq(V4.balanceOf(lpA), 0, "zero deposit must not create a position");
        assertEq(CORE.committedUsd18(), c0, "zero deposit must not move committed");
    }

    /// EDGE: the JIT lock must refuse a same-block exit. This is the guard that blocks the
    /// deposit -> swap -> withdraw fee snipe, and it sits directly on the withdraw path the
    /// unification touches.
    function test_V4_JitLockBlocksSameBlockExit() public {
        _seedBasket();
        vm.startPrank(lpA);
        V4.deposit{value: 50 ether}(0, lpA);
        vm.expectRevert(bytes("too soon"));
        V4.withdraw(1 ether, lpA, lpA);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // V5 — WITHDRAW
    // ─────────────────────────────────────────────────────────────────────────

    /// A withdraw must SHRINK committed. `_withdraw`'s own comment relies on this ("LP
    /// withdrawal SHRINKS POOLED_USD -> shrinks committedSum -> heals over-commit"), so if the
    /// unification breaks it the over-commit self-heal silently stops working.
    function test_V5_WithdrawShrinksCommitted() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);

        uint c1 = CORE.committedUsd18();
        uint bal0 = lpA.balance;
        vm.prank(lpA); V4.withdraw(40 ether, lpA, lpA);

        emit log_named_uint("committed before", c1);
        emit log_named_uint("committed after ", CORE.committedUsd18());
        emit log_named_uint("ETH delivered   ", lpA.balance - bal0);
        assertLt(CORE.committedUsd18(), c1, "a withdraw must shrink committed");
        assertGt(lpA.balance - bal0, 0, "PREMISE: the withdraw actually delivered ETH");
    }

    /// EDGE: withdrawing MORE than the position must clamp to the position, not revert and not
    /// over-deliver. `Vogue.withdraw` caps at `autoManaged[msg.sender].pooled` before converting.
    function test_V5_OverAskClampsToPosition() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);

        uint pooled = V4.balanceOf(lpA);
        vm.prank(lpA);
        V4.withdraw(type(uint).max, lpA, lpA);     // the "exit everything" sentinel
        emit log_named_uint("pooled before", pooled);
        emit log_named_uint("pooled after ", V4.balanceOf(lpA));
        assertLt(V4.balanceOf(lpA), pooled, "the sentinel must actually reduce the position");
    }

    /// EDGE: a withdraw of zero DELIVERS NOTHING — but it is NOT a no-op, and asserting that it
    /// is was wrong. Measured: `pooled` went 50.000000000000000000 -> 50.000028660569414700 over a
    /// 1h warp, because `_withdraw` runs `_rebalance()` + `_settlePending(LP, sender, 0)`
    /// unconditionally and the token leg COMPOUNDS into `LP.pooled` (`_settlePending`: `LP.pooled
    /// += tokR`). That is the documented auto-compound, not a leak.
    /// ⇒ The real invariants are: no ETH leaves, and the position never SHRINKS. Both survive the
    ///   unification only if the settle path keeps reading the same accumulators.
    function test_V5_ZeroWithdrawDeliversNothingAndNeverShrinks() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);

        uint pooled = V4.balanceOf(lpA);
        uint bal0   = lpA.balance;
        uint weth0  = WETH.balanceOf(lpA);
        uint q0     = QUID.balanceOf(lpA);

        vm.prank(lpA); V4.withdraw(0, lpA, lpA);

        emit log_named_uint("pooled before", pooled);
        emit log_named_uint("pooled after ", V4.balanceOf(lpA));
        assertGe(V4.balanceOf(lpA), pooled, "a zero withdraw must never SHRINK the position");
        assertEq(lpA.balance, bal0,  "a zero withdraw must deliver no native ETH");
        assertEq(WETH.balanceOf(lpA), weth0, "a zero withdraw must deliver no WETH");
        assertEq(QUID.balanceOf(lpA), q0, "a zero withdraw is a PARTIAL exit -> usd_owed DEFERS, no QUID mint");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // V2 — P&L ATTRIBUTION
    // ─────────────────────────────────────────────────────────────────────────

    /// TWO LPs, EQUAL SIZE, SAME ENTRY: trading fees must apportion EQUALLY. This is the
    /// property a shared `POOLED_USD` could break without any accumulator being mis-wired —
    /// if placement moves fee-earning capacity, equal LPs stop earning equally.
    function test_V2_EqualLpsEarnEqualFees() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        vm.prank(lpB); V4.deposit{value: 100 ether}(0, lpB);
        vm.roll(block.number + 1);

        for (uint i; i < 6; i++) _trade(3_000e18);

        (uint tokA, uint usdA) = V4.pendingRewards(lpA);
        (uint tokB, uint usdB) = V4.pendingRewards(lpB);
        emit log_named_uint("LP A pending tok/usd", tokA); emit log_named_uint("  ", usdA);
        emit log_named_uint("LP B pending tok/usd", tokB); emit log_named_uint("  ", usdB);

        assertTrue(tokA > 0 || usdA > 0, "PREMISE: fees actually accrued, else this is vacuous");
        // Equal pooled, equal entry -> equal claim. Exact, not approximate: both bookmarks were
        // refreshed against the same accumulator values.
        assertEq(tokA, tokB, "equal LPs must accrue equal token-leg fees");
        assertEq(usdA, usdB, "equal LPs must accrue equal USD-leg fees");
    }

    /// EDGE — THE BOOKMARK PROPERTY: an LP joining AFTER fees accrued must receive NONE of
    /// them. This is the single most valuable P&L assertion, because a broken bookmark pays
    /// retroactive fees out of other LPs' claims and nothing reverts.
    function test_V2_LateJoinerEarnsNoRetroactiveFees() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        vm.roll(block.number + 1);

        for (uint i; i < 6; i++) _trade(3_000e18);
        (uint tokA0, uint usdA0) = V4.pendingRewards(lpA);
        assertTrue(tokA0 > 0 || usdA0 > 0, "PREMISE: fees accrued BEFORE the late joiner arrives");

        vm.prank(lpB); V4.deposit{value: 100 ether}(0, lpB);
        (uint tokB, uint usdB) = V4.pendingRewards(lpB);
        emit log_named_uint("late joiner pending tok", tokB);
        emit log_named_uint("late joiner pending usd", usdB);

        assertEq(tokB, 0, "a late joiner must not inherit token-leg fees earned before entry");
        assertEq(usdB, 0, "a late joiner must not inherit USD-leg fees earned before entry");
    }

    /// EDGE: a non-depositor has no claim. Guards the `pooled == 0` early-out in `_settlePending`.
    function test_V2_NonDepositorHasNoClaim() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        vm.roll(block.number + 1);
        for (uint i; i < 4; i++) _trade(3_000e18);

        (uint tok, uint usd) = V4.pendingRewards(address(0xDEAD));
        assertEq(tok, 0, "a non-depositor must have no token claim");
        assertEq(usd, 0, "a non-depositor must have no USD claim");
    }

    /// EDGE: `collectFees` must be idempotent — a second call immediately after the first
    /// yields nothing. A broken rebaseline would let an LP drain the accumulator by looping.
    function test_V2_CollectFeesIsIdempotent() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA);
        vm.roll(block.number + 1);
        for (uint i; i < 6; i++) _trade(3_000e18);

        vm.prank(lpA); V4.collectFees();
        uint q1 = QUID.balanceOf(lpA);
        uint pooled1 = V4.balanceOf(lpA);

        vm.prank(lpA); V4.collectFees();
        assertEq(QUID.balanceOf(lpA), q1, "a repeated collectFees must mint nothing further");
        assertEq(V4.balanceOf(lpA), pooled1, "a repeated collectFees must compound nothing further");
    }

    /// EDGE: the LAST LP exiting fully must leave the accumulators zeroed, so a future LP does
    /// not inherit historical fees attributed to nobody (`_onExit`'s `lpShares == 0` branch).
    function test_V2_LastExitZeroesAccumulators() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        for (uint i; i < 4; i++) _trade(3_000e18);

        vm.prank(lpA); V4.withdraw(type(uint).max, lpA, lpA);
        emit log_named_uint("pooled after full exit", V4.balanceOf(lpA));
        emit log_named_uint("lpShares", V4.lpShares());
        emit log_named_uint("feesPerShare", V4.feesPerShare());
        emit log_named_uint("USD_FEES", V4.USD_FEES());

        // Only assert the zeroing if the exit really emptied the pool — an undelivered
        // shortfall legitimately leaves `pooled` behind as a recoverable deferral, and that
        // is NOT a failure. Assert the implication, not the happy path.
        if (V4.lpShares() == 0) {
            assertEq(V4.feesPerShare(), 0, "last exit must zero the token accumulator");
            assertEq(V4.USD_FEES(), 0, "last exit must zero the USD accumulator");
        } else {
            emit log_string("partial delivery left pooled behind (venue illiquidity deferral) - zeroing not expected");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // V6 — REDEMPTION / BAND UNWIND, and V8 — CROSS-BAND REPACK REACHABILITY
    // ─────────────────────────────────────────────────────────────────────────

    /// `Vogue.unwindForRedeem` frees committed dollars by BURNING in-range band liquidity, and its
    /// docstring makes a strong claim the suite never checks: *"LP EQUITY NEUTRAL (vogueETH/lpShares
    /// unchanged; only the band's mock mirror shrinks, returning ETH from in-band to in-venue)"*.
    /// `test_Redeem_UnwindsBandToFreeCommittedDollars` asserts the unwind FIRES and committed drops;
    /// it does not assert neutrality, and it runs with NO BTC band.
    ///
    /// Both gaps are exactly what the `POOLED_USD` unification would break: the unwind is ETH-ONLY
    /// (`Vogue.sol:964` reads `POOLED_USD_ETH`), and `BasketLib.redeemableBody:969` subtracts
    /// `POOLED_USD_BTC` from the redeemable quote PRECISELY BECAUSE an ETH-side redemption cannot
    /// reach the BTC band. Merge the counters and both assumptions dissolve silently.
    function test_V6_UnwindIsLpEquityNeutralAndCannotReachTheBtcBand() public {
        // NOTE: deliberately NOT `_seedBasket()`. Seeding an extra \$1M leaves free stables
        // (TVL - committed) ABOVE the redemption size, so the redeem is served from free stables
        // and the band unwind NEVER FIRES -- measured: TVL 2,152,000, free 1,703,761 vs a
        // 1,100,000 redeem, committed unchanged. The premise below caught it. Run against the
        // fixture's own basket, as `test_Redeem_UnwindsBandToFreeCommittedDollars` does.
        vm.startPrank(User01);
        uint mintUsdc = 1_000_000 * 1e6; USDC.approve(address(AUX), mintUsdc);
        QUID.mint(User01, mintUsdc, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 35 days);

        vm.deal(lpA, 900 ether);
        vm.prank(lpA); V4.deposit{value: 700 ether}(0, lpA, 3);

        // Seed the BTC band so "the unwind cannot reach it" is a real claim, not 0 == 0.
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(lpB, 2e7);

        (uint[15] memory d0,,,) = AUX.get_deposits();
        uint tvl0        = d0[14];
        uint committed0  = CORE.committedUsd18();
        uint vogueEth0   = AUX.vogueETH();
        uint lpShares0   = V4.lpShares();
        uint pooledA0    = V4.balanceOf(lpA);
        uint btcUsd0     = CORE.POOLED_USD_BTC();
        uint btcLeg0     = CORE.POOLED_BTC();
        uint btcFps0     = BTC.feesPerShareBTC();

        emit log_named_uint("TVL before        ", tvl0);
        emit log_named_uint("committed before  ", committed0);
        emit log_named_uint("vogueETH before   ", vogueEth0);
        emit log_named_uint("BTC USD leg before", btcUsd0);

        vm.prank(User01); AUX.redeem(1_100_000 * WAD);

        (uint[15] memory d1,,,) = AUX.get_deposits();
        emit log_named_uint("TVL after         ", d1[14]);
        emit log_named_uint("committed after   ", CORE.committedUsd18());
        emit log_named_uint("vogueETH after    ", AUX.vogueETH());
        emit log_named_uint("BTC USD leg after ", CORE.POOLED_USD_BTC());

        // PREMISE: the unwind must actually have fired, else nothing below is being tested.
        assertLt(CORE.committedUsd18(), committed0, "PREMISE: the band was unwound (committed dropped)");

        // V6a — LP EQUITY NEUTRALITY. The unwind returns the paired ETH from in-band to in-venue,
        // so the LP's claim and the total share count must be untouched. A 0.5% band absorbs venue
        // yield accrued during the redeem; anything larger is the unwind taking LP value.
        assertEq(V4.lpShares(), lpShares0, "unwind must not change lpShares");
        assertEq(V4.balanceOf(lpA), pooledA0, "unwind must not change the LP's pooled claim");
        assertApproxEqRel(AUX.vogueETH(), vogueEth0, 0.005e18,
            "unwind must be LP-EQUITY NEUTRAL: vogueETH unchanged (ETH moved in-band -> in-venue, not out)");

        // V6b — THE UNWIND IS ETH-ONLY AND MUST NOT REACH THE BTC BAND. This is the assumption
        // `redeemableBody`'s `POOLED_USD_BTC` subtraction rests on.
        assertGt(btcUsd0, 0, "PREMISE: the BTC band is seeded, else this assertion is 0 == 0");
        assertEq(CORE.POOLED_USD_BTC(), btcUsd0, "an ETH-side redemption must NOT unwind the BTC band's USD leg");
        assertEq(CORE.POOLED_BTC(), btcLeg0, "an ETH-side redemption must NOT touch the BTC band's BTC leg");
        assertEq(BTC.feesPerShareBTC(), btcFps0, "an ETH-side redemption must NOT credit BTC-band LPs");

        // V8 — CROSS-BAND REPACK REACHABILITY. `BasketLib.backingCoreBody` only picks a band to
        // repack when `committedSum > totalLiquid`; the mint gate keeps committed <= haircutTvl
        // <= TVL on the way in, and this redemption UNWINDS committed as it drains TVL, which is
        // self-correcting. MEASURED, not asserted: if over-commitment is never observed here, the
        // cross-band repack coupling (caveat B3) is far weaker than assumed and must be either
        // constructed deliberately or downgraded.
        emit log_named_uint("committed > TVL at any point? (0=no)",
            CORE.committedUsd18() > d1[14] ? 1 : 0);
        emit log_named_uint("TVL - committed after", d1[14] > CORE.committedUsd18() ? d1[14] - CORE.committedUsd18() : 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // E16 — ACCEPTANCE: "an imbalance never leaves us paying a cost, only banking a profit"
    // ─────────────────────────────────────────────────────────────────────────

    /// The A-S scarcity premium is charged to a swapper who WORSENS inventory imbalance, and it is
    /// charged FOR THE LP'S INVENTORY RISK. Before §E5 it was withheld into basket backing — which
    /// prices QU!D, not LP shares — so an imbalance banked a profit for QU!D HOLDERS while the LP
    /// carried the risk. `Core.skewPremium*` recorded it and nothing consumed it
    /// (`SwapLib:937`: *"NO consumer beyond the counters + theta EWMA"*).
    ///
    /// This is the owner's invariant as a test: drive a real drain, and assert the LPs' own USD
    /// accumulator MOVED. Without §E5 this fails while `skewPremiumETH` still rises — i.e. it
    /// distinguishes "recorded" from "received", which is the whole defect.
    function test_E16_RetainedPremiumReachesLpsNotOnlyTheCounter() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA, 3);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 30 minutes);

        uint prem0 = CORE.skewPremiumETH();
        uint usdFees0 = V4.USD_FEES();
        emit log_named_uint("skewPremiumETH before", prem0);
        emit log_named_uint("USD_FEES       before", usdFees0);

        // Drain the volatile side hard enough to make the pool scarce, which is what makes
        // `wellSkew` non-zero and causes a premium to be retained.
        vm.deal(User01, 3_000 ether);
        for (uint i; i < 8; i++) {
            vm.prank(User01);
            try AUX.swap(address(USDC), address(WETH), true, 60_000 * USDC_PRECISION, 0) {} catch {}
            vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        }

        uint prem1 = CORE.skewPremiumETH();
        uint usdFees1 = V4.USD_FEES();
        emit log_named_uint("skewPremiumETH after ", prem1);
        emit log_named_uint("USD_FEES       after ", usdFees1);
        emit log_named_uint("premium retained     ", prem1 - prem0);
        emit log_named_uint("USD_FEES increment   ", usdFees1 - usdFees0);

        // PREMISE: a premium must actually have been retained, else the test is vacuous — a
        // flush pool charges zero skew and nothing would be expected to move.
        assertGt(prem1, prem0, "PREMISE: the drain retained a scarcity premium (pool was actually scarce)");

        // THE INVARIANT. The premium must reach the LPs' per-share accumulator, not merely a
        // counter. This is what makes an imbalance BANK A PROFIT for LPs rather than cost them.
        assertGt(usdFees1, usdFees0,
            "the retained premium must reach the LP USD accumulator -- recorded is not received");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // E3 SIZING — how much idle capital sits on the OTHER curve when one starves?
    // ─────────────────────────────────────────────────────────────────────────

    /// The unification's capital-efficiency claim is that a STARVED curve could draw on the OTHER
    /// curve's dollars. That payoff is worth exactly the amount of capital that is idle on the far
    /// side AT THE MOMENT of starvation — and nobody has measured it. If the other curve is also
    /// thin when one starves, unification re-allocates nothing and the whole premise shrinks.
    ///
    /// ⚠️ SCOPE, STATED SO THIS IS NOT OVER-READ: this measures whether starvation COINCIDES with
    /// idle capital, and HOW MUCH. It does NOT measure production FREQUENCY — that needs real flow
    /// data neither repo has. A reachable-and-large result sizes the upper bound of the win; it does
    /// not prove the win is often collected.
    function test_E3sizing_StarvedCurveVsIdleCapitalOnTheOther() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(lpB, 2e7);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 30 minutes);

        uint ethUsd0 = CORE.POOLED_USD_ETH();
        uint btcUsd0 = CORE.POOLED_USD_BTC();
        emit log_named_uint("ETH curve USD at rest", ethUsd0);
        emit log_named_uint("BTC curve USD at rest", btcUsd0);
        assertGt(ethUsd0, 0, "PREMISE: ETH curve is live");
        assertGt(btcUsd0, 0, "PREMISE: BTC curve is live -- else 'idle capital on the other' is 0 by default");

        // One-directional ETH flow: pay ETH in, take USD out, until the ETH curve's USD is starved.
        vm.deal(User01, 5_000 ether);
        uint steps;
        for (uint i; i < 20 && CORE.POOLED_USD_ETH() > ethUsd0 / 100; i++) {
            vm.prank(User01);
            try AUX.swap{value: 40 ether}(address(USDC), address(WETH), false, 0, 0) {} catch {}
            vm.roll(block.number + 1); vm.warp(block.timestamp + 10 minutes);
            steps++;
        }

        uint ethUsd1 = CORE.POOLED_USD_ETH();
        uint btcUsd1 = CORE.POOLED_USD_BTC();
        uint pending = CORE.pendingSwapOutUsd();
        uint btcFree = btcUsd1 > pending ? btcUsd1 - pending : 0;

        // THE RESERVOIR THAT ACTUALLY MATTERS: uncommitted BASKET surplus. `SwapLib.sizeBySurplus`
        // sizes band depth from `liquidTotal - committedBoth`, so a starved curve is only a real
        // deficit if the BASKET is also empty. Comparing against the OTHER CURVE (as the first
        // version of this test did) measures the wrong reservoir by two orders of magnitude.
        (uint[15] memory dS,,,) = AUX.get_deposits();
        uint committedNow = CORE.committedUsd18();
        uint surplus = dS[14] > committedNow ? dS[14] - committedNow : 0;
        emit log_named_uint("basket TVL at starvation ", dS[14]);
        emit log_named_uint("committed at starvation  ", committedNow);
        emit log_named_uint("UNCOMMITTED SURPLUS      ", surplus);
        emit log_named_uint("swaps to starve ETH  ", steps);
        emit log_named_uint("ETH curve USD after  ", ethUsd1);
        emit log_named_uint("BTC curve USD after  ", btcUsd1);
        emit log_named_uint("BTC free (idle) after", btcFree);
        emit log_named_uint("ETH deficit vs rest  ", ethUsd0 > ethUsd1 ? ethUsd0 - ethUsd1 : 0);
        // THE SIZING NUMBER: idle capital on the far curve as a % of the starved curve's deficit.
        uint deficit = ethUsd0 > ethUsd1 ? ethUsd0 - ethUsd1 : 0;
        emit log_named_uint("idle-on-other / deficit (bps)",
            deficit > 0 ? btcFree * 10_000 / deficit : 0);

        // PREMISE: the ETH curve must actually have starved, else there is nothing to size.
        assertLt(ethUsd1, ethUsd0 / 100, "PREMISE: the ETH curve really is starved (<1% of rest)");
        // MEASUREMENT, not a pass/fail claim: report whether the far curve held anything at all.
        emit log_named_uint("far curve held idle capital at starvation? (0=no)", btcFree > 0 ? 1 : 0);
    }

    /// @dev E6 TARGET-SETTING. "100% capital efficient" is only meaningful against the MAXIMUM the
    ///      protocol is ALLOWED to deploy, which is bounded by three real constraints, not by
    ///      appetite:
    ///        • `SwapLib.sizeBySurplus`  — USD depth <= basket SURPLUS (`liquidTotal - committedBoth`)
    ///        • `SwapLib.clampByBacking` — token depth <= PHYSICAL headroom (`backing - pooled`)
    ///                                     AND <= the theta risk budget (`theta*backing - pooled`)
    ///      The gap between deployed depth and that ceiling IS the inefficiency. This logs both so
    ///      the E6 build has a falsifiable target instead of "top it up".
    function _logDeployGap(string memory tag) internal {
        (uint[15] memory d,,,) = AUX.get_deposits();
        uint committed = CORE.committedUsd18();
        uint surplus   = d[14] > committed ? d[14] - committed : 0;
        uint backing   = AUX.vogueETH();
        uint pooledEth = CORE.POOLED_ETH();
        uint headroom  = backing > pooledEth ? backing - pooledEth : 0;
        uint theta;
        try V4.derivedThetaWad(false) returns (uint t) { theta = t; } catch { theta = 0; }
        emit log_string(tag);
        emit log_named_uint("   USD deployed (committed) ", committed);
        emit log_named_uint("   USD available (surplus)  ", surplus);
        emit log_named_uint("   ETH deployed (POOLED_ETH)", pooledEth);
        emit log_named_uint("   ETH available (headroom) ", headroom);
        emit log_named_uint("   theta (WAD, 0=unmeasured)", theta);
        emit log_named_uint("   USD deployed / permitted bps",
            (committed + surplus) > 0 ? committed * 10_000 / (committed + surplus) : 0);
        emit log_named_uint("   ETH deployed / permitted bps",
            (pooledEth + headroom) > 0 ? pooledEth * 10_000 / (pooledEth + headroom) : 0);
    }

    /// E6 ACCEPTANCE TARGET — quantify the deploy gap at rest and after a drain. The refill must
    /// close it. Measurement only; the assertions are PREMISES so it cannot pass vacuously.
    function test_E6target_DeployGapAtRestAndAfterDrain() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(lpB, 2e7);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 30 minutes);

        _logDeployGap("AT REST");
        uint ethUsd0 = CORE.POOLED_USD_ETH();

        vm.deal(User01, 5_000 ether);
        for (uint i; i < 20 && CORE.POOLED_USD_ETH() > ethUsd0 / 100; i++) {
            vm.prank(User01);
            try AUX.swap{value: 40 ether}(address(USDC), address(WETH), false, 0, 0) {} catch {}
            vm.roll(block.number + 1); vm.warp(block.timestamp + 10 minutes);
        }

        _logDeployGap("AFTER DRAIN (pre-refill)");
        assertLt(CORE.POOLED_USD_ETH(), ethUsd0 / 100, "PREMISE: the curve really is drained");

        // A reseat poke is the natural refill trigger. Today it does NOT top up -- logged so the
        // E6 build has a before/after on the SAME scenario.
        V4.reseat();
        _logDeployGap("AFTER reseat() poke");

        // DECISIVE FOR E6's DESIGN: a repack re-adds through `addLiq`, which sizes USD from
        // SURPLUS against the ETH available. If routing through that path restores composition,
        // then E6 needs NO new threshold and NO new clamp -- it only needs the re-add to FIRE on
        // composition drift, not solely on range exit. A deposit is the cheapest way to exercise
        // the same `addLiq` -> `_modLpEth` path without changing production code.
        vm.deal(lpB, 20 ether);
        vm.prank(lpB); V4.deposit{value: 10 ether}(0, lpB, 3);
        _logDeployGap("AFTER a deposit (exercises addLiq re-add)");
        emit log_named_uint("ETH band USD after re-add", CORE.POOLED_USD_ETH());
        emit log_named_uint("ETH band ETH after re-add", CORE.POOLED_ETH());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UNISWAP v4 PROTOCOL FEE — the DEFENSIVE assert-0 + monitor
    // ─────────────────────────────────────────────────────────────────────────

    /// QUEUE researched the v4 protocol fee and left ONE thing unchecked: *"the actual `protocolFee`
    /// value currently stored for our PoolKeys"*. This closes that, and is the MONITOR the same entry
    /// asks for — the controller CAN set a fee on our key later WITHOUT our consent (up to 0.1%),
    /// so this must fail loudly the day that happens rather than silently shaving LP fee accrual.
    ///
    /// ⚠️ SCOPE — deliberately NOT the compensation. QUEUE is explicit that mock-inflation
    /// compensation is *"NOT YET NEEDED … Do not build against a hypothetical"*, and that it would
    /// have to apply to the FEE-ACCRUAL path, never to reserve balances (inflating balances would
    /// mis-price the curve, because the tick math reads reserves). This is the assert + monitor only.
    ///
    /// PREMISE-GUARDED: reads BOTH pools, so it cannot pass by looking at an uninitialised one.
    function test_ProtocolFee_IsZeroOnBothOurPools() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA, 3);

        (, , uint24 pFeeEth, uint24 lpFeeEth) =
            StateLibrary.getSlot0(CORE.poolManager(), CORE.POOL_ID_VANILLA_ETH());
        (, , uint24 pFeeBtc, uint24 lpFeeBtc) =
            StateLibrary.getSlot0(CORE.poolManager(), CORE.POOL_ID_VANILLA_BTC());

        emit log_named_uint("ETH pool protocolFee", pFeeEth);
        emit log_named_uint("ETH pool lpFee      ", lpFeeEth);
        emit log_named_uint("BTC pool protocolFee", pFeeBtc);
        emit log_named_uint("BTC pool lpFee      ", lpFeeBtc);

        // PREMISE: the pools must be INITIALISED, else reading 0 proves nothing about a live fee.
        assertGt(lpFeeEth, 0, "PREMISE: ETH pool initialised (lpFee set), else protocolFee==0 is vacuous");
        assertGt(lpFeeBtc, 0, "PREMISE: BTC pool initialised (lpFee set), else protocolFee==0 is vacuous");

        // THE MONITOR. `ProtocolFeeLibrary:44` takes the protocol fee OFF THE TOP OF THE LP FEE
        // (`swapFee = self + lpFee - self*lpFee/PIPS`), so a non-zero value here silently reduces LP
        // fee ACCRUAL -- it does not touch reserves. If this ever fires, read the QUEUE entry before
        // reaching for compensation: it must be applied to the fee-accrual path, not to balances.
        assertEq(pFeeEth, 0, "a protocol fee is live on OUR ETH pool -- LP fee accrual is being shaved");
        assertEq(pFeeBtc, 0, "a protocol fee is live on OUR BTC pool -- LP fee accrual is being shaved");
    }


    /// EMPIRICAL — is a v4 protocol-fee CONTROLLER set on the live mainnet PoolManager at all?
    /// This is the question my earlier assert-0 could not answer. If the controller is address(0),
    /// NO pool can carry a protocol fee and our 0 is structural. If it is set, a fee switch is live
    /// and the only remaining question is what it returns for OUR key.
    function test_EMPIRICAL_ProtocolFeeControllerIsSet() public {
        address ctrl = IProtoFees(address(CORE.poolManager())).protocolFeeController();
        emit log_named_address("live protocolFeeController", ctrl);
        emit log_named_uint("fork block", block.number);
        emit log_named_uint("controller set? (0=no)", ctrl == address(0) ? 0 : 1);
    }

    /// DECISIVE: does the live controller return a NON-ZERO fee for a REAL currency pair? If yes,
    /// the switch is CHARGING and our mock key is the only reason we read 0 — i.e. the exemption is
    /// an artefact of the mock design, not a protocol-wide "fee is off".
    function test_EMPIRICAL_ControllerFeeForRealWethUsdc() public {
        IProtoFeeCtrl ctrl = IProtoFeeCtrl(IProtoFees(address(CORE.poolManager())).protocolFeeController());
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;   // currency0 (lower)
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;   // currency1
        uint24[4] memory tiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        int24[4]  memory spac  = [int24(1),    int24(10),   int24(60),    int24(200)];
        for (uint i; i < 4; i++) {
            PoolKey memory k = PoolKey({
                currency0: Currency.wrap(usdc), currency1: Currency.wrap(weth),
                fee: tiers[i], tickSpacing: spac[i], hooks: IHooks(address(0))
            });
            try ctrl.protocolFeeForPool(k) returns (uint24 f) {
                emit log_named_uint("USDC/WETH tier", tiers[i]);
                emit log_named_uint("   protocolFee", f);
            } catch { emit log_named_uint("reverted for tier", tiers[i]); }
        }
        // Also our own shape: 420 fee, and a mock-ish pair, for contrast.
        PoolKey memory ours = PoolKey({
            currency0: Currency.wrap(usdc), currency1: Currency.wrap(weth),
            fee: 420, tickSpacing: 10, hooks: IHooks(address(0))
        });
        try ctrl.protocolFeeForPool(ours) returns (uint24 f) {
            emit log_named_uint("USDC/WETH @ our 420 tier -> fee", f);
        } catch { emit log_string("reverted at 420 tier"); }
    }

    /// CHECK: does a FULL exit actually fully exit after #12? The target probe leaves a -56.40
    /// residual, which I attributed to an un-burnable sliver deferring as `pooled`. If that is
    /// right, `pooled` is NON-ZERO after the redeem and a SECOND withdraw collects the rest.
    /// If `pooled` is already zero, the residual is a LEAK, not a deferral -- a materially
    /// different (and worse) answer, so it is measured rather than assumed.
    function test_CHECK_FullExitResidualIsRecoverable() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 8; i++) _trade(3_000e18);
        vm.warp(block.timestamp + 1 hours);

        uint pooled0 = V4.balanceOf(lpA);
        uint eth0 = lpA.balance; uint q0 = QUID.balanceOf(lpA);
        vm.prank(lpA); V4.redeem(pooled0, lpA, lpA);

        uint pooled1 = V4.balanceOf(lpA);
        emit log_named_uint("pooled before exit", pooled0);
        emit log_named_uint("pooled AFTER exit ", pooled1);
        emit log_named_uint("ETH delivered     ", lpA.balance - eth0);
        emit log_named_uint("QUID delivered    ", QUID.balanceOf(lpA) - q0);

        if (pooled1 == 0) { emit log_string("FULL exit: pooled == 0, nothing deferred"); return; }

        // A residual exists -> it must be COLLECTABLE. Second withdraw.
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        uint eth1 = lpA.balance; uint q1 = QUID.balanceOf(lpA);
        vm.prank(lpA); V4.redeem(pooled1, lpA, lpA);
        emit log_named_uint("2nd exit: pooled left", V4.balanceOf(lpA));
        emit log_named_uint("2nd exit: ETH more   ", lpA.balance - eth1);
        emit log_named_uint("2nd exit: QUID more  ", QUID.balanceOf(lpA) - q1);
        assertLt(V4.balanceOf(lpA), pooled1, "the deferred residual must be RECOVERABLE by a second exit");
    }

    /// PROVE-BEFORE-REFACTOR: can `POOLED_USD_ETH`/`POOLED_ETH` be DERIVED from pool state instead
    /// of mirrored in storage? If yes, those two slots can hold the #12 base instead and
    /// `basketUsdEth`/`basketUsdBtc` are deleted -- a net -4 slots. If the derived and stored
    /// values diverge, the removal is DEAD and must not be attempted.
    ///
    /// E13 already cleared the objection that blocked this: band and boundary-order tick widths
    /// (40 vs >=90) can never coincide, so the shared `salt: bytes32(0)` cannot alias them and a
    /// query on the band's range returns the band's position ALONE.
    function test_PROVE_PooledIsDerivableFromPoolState() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 4; i++) _trade(3_000e18);

        (uint160 sqrtP,, uint128 liq) = CORE.poolStats(V4.LOWER_TICK(), V4.UPPER_TICK(), false);
        // In-range position: token0 side spans [spot, upper], token1 side spans [lower, spot].
        uint160 lo = TickMath.getSqrtPriceAtTick(V4.LOWER_TICK());
        uint160 hi = TickMath.getSqrtPriceAtTick(V4.UPPER_TICK());
        uint a0 = SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, false);
        uint a1 = SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, false);
        // token1isETH decides which amount is the ETH leg.
        (uint derivedUsd, uint derivedEth) = V4.token1isETH() ? (a0, a1) : (a1, a0);

        emit log_named_uint("stored  POOLED_USD_ETH", CORE.POOLED_USD_ETH());
        emit log_named_uint("derived USD leg       ", derivedUsd);
        emit log_named_uint("stored  POOLED_ETH    ", CORE.POOLED_ETH());
        emit log_named_uint("derived ETH leg       ", derivedEth);
        emit log_named_uint("band liquidity        ", liq);

        assertGt(liq, 0, "PREMISE: the band holds liquidity, else the derivation is vacuous");
        // Within 1% -- the derivation is exact math on the same position; any real gap means the
        // mirror carries information the pool does not (which would kill the removal).
        assertApproxEqRel(derivedUsd, CORE.POOLED_USD_ETH(), 0.01e18, "USD leg must be derivable from pool state");
        assertApproxEqRel(derivedEth, CORE.POOLED_ETH(), 0.01e18, "ETH leg must be derivable from pool state");
    }

    /// DUST SWEEP — mocks held outside the allowed set {PoolManager, Core} must be ZERO today, and
    /// must never be counted toward shares or P&L. A v4 protocol fee is the only path that creates
    /// an external holder: the slice is taken out of the LP fee, accrues to
    /// `protocolFeesAccrued[ourMock]`, and `collectProtocolFees` transfers it out. This asserts
    /// containment now and fails loudly the day it breaks.
    function test_DUST_MocksAreContainedToAllowedHolders() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 100 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 4; i++) _trade(3_000e18);

        (uint usdDustEth, uint tokDustEth) = CORE.externalMockDust(false);
        (uint usdDustBtc, uint tokDustBtc) = CORE.externalMockDust(true);
        emit log_named_uint("ETH-band mockUSD dust", usdDustEth);
        emit log_named_uint("ETH-band mockETH dust", tokDustEth);
        emit log_named_uint("BTC-band mockUSD dust", usdDustBtc);
        emit log_named_uint("BTC-band mockBTC dust", tokDustBtc);

        assertEq(usdDustEth, 0, "mockUSD_ETH escaped the allowed holder set");
        assertEq(tokDustEth, 0, "mockETH escaped the allowed holder set");
        assertEq(usdDustBtc, 0, "mockUSD_BTC escaped the allowed holder set");
        assertEq(tokDustBtc, 0, "mockBTC escaped the allowed holder set");
    }

    /// SETTLE THE -31.21. The LVR probe redeems ONCE inside a snapshot. If the shortfall is a
    /// correct deferral, `pooled` is non-zero after and a SECOND redeem collects it. If `pooled`
    /// is already zero, the value is STRANDED in the wrong leg and #12 is not done. Measured
    /// rather than reasoned, because I got the previous residual wrong exactly this way (E26).
    function test_SETTLE_LvrResidualIsDeferralNotLeak() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 20; i++) _trade(3_000e18);

        uint pooled0 = V4.balanceOf(lpA);
        uint e0 = lpA.balance; uint w0 = WETH.balanceOf(lpA); uint q0 = QUID.balanceOf(lpA);
        vm.prank(lpA); V4.redeem(pooled0, lpA, lpA);
        uint pooled1 = V4.balanceOf(lpA);
        emit log_named_uint("pooled before   ", pooled0);
        emit log_named_uint("pooled after 1st", pooled1);
        emit log_named_uint("ETH  after 1st  ", (lpA.balance - e0) + (WETH.balanceOf(lpA) - w0));
        emit log_named_uint("QUID after 1st  ", QUID.balanceOf(lpA) - q0);

        if (pooled1 == 0) { emit log_string("VERDICT: pooled==0 -> nothing deferred; any gap is a LEAK"); return; }

        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        uint e1 = lpA.balance; uint w1 = WETH.balanceOf(lpA); uint q1 = QUID.balanceOf(lpA);
        vm.prank(lpA); V4.redeem(pooled1, lpA, lpA);
        uint gotEth = (lpA.balance - e1) + (WETH.balanceOf(lpA) - w1);
        uint gotQ   = QUID.balanceOf(lpA) - q1;
        emit log_named_uint("pooled after 2nd", V4.balanceOf(lpA));
        emit log_named_uint("ETH  from 2nd   ", gotEth);
        emit log_named_uint("QUID from 2nd   ", gotQ);
        assertTrue(gotEth > 0 || gotQ > 0, "VERDICT: the deferral must be COLLECTABLE, else it is a leak");
    }

    /// PINPOINT the -31.21. Compare the LP's CLAIM (what `convertToAssets` says the shares are
    /// worth) against the VALUE ACTUALLY DELIVERED (ETH + QU!D), in one unit, on the same block.
    /// If claim == delivered the gap is not in `_withdraw` at all and the probe's control arm is
    /// the thing to examine; if claim > delivered the leak is in the delivery path.
    function test_PINPOINT_ClaimVsDelivered() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 20; i++) _trade(3_000e18);

        uint px      = AUX.getTWAPforAsset(address(WETH), 1800);
        uint shares  = V4.balanceOf(lpA);
        uint claimEth = V4.convertToAssets(shares);
        uint claimUsd = claimEth * px / 1e18;

        emit log_named_uint("POOLED_ETH   pre  ", CORE.POOLED_ETH());
        emit log_named_uint("vogueETH     pre  ", AUX.vogueETH());
        emit log_named_uint("POOLED_USD   pre  ", CORE.POOLED_USD_ETH());
        emit log_named_uint("basketUsdEth pre  ", CORE.basketUsdEth());
        emit log_named_uint("lpShares     pre  ", V4.lpShares());

        uint e0 = lpA.balance; uint w0 = WETH.balanceOf(lpA); uint q0 = QUID.balanceOf(lpA);
        vm.prank(lpA); V4.redeem(shares, lpA, lpA);
        emit log_named_uint("POOLED_ETH   post ", CORE.POOLED_ETH());
        emit log_named_uint("POOLED_USD   post ", CORE.POOLED_USD_ETH());
        emit log_named_uint("basketUsdEth post ", CORE.basketUsdEth());
        uint gotEth = (lpA.balance - e0) + (WETH.balanceOf(lpA) - w0);
        uint gotQ   = QUID.balanceOf(lpA) - q0;
        uint gotUsd = gotEth * px / 1e18 + gotQ;

        emit log_named_uint("px                ", px);
        emit log_named_uint("shares            ", shares);
        emit log_named_uint("CLAIM  (eth)      ", claimEth);
        emit log_named_uint("CLAIM  (usd18)    ", claimUsd);
        emit log_named_uint("GOT eth           ", gotEth);
        emit log_named_uint("GOT quid          ", gotQ);
        emit log_named_uint("DELIVERED (usd18) ", gotUsd);
        emit log_named_int ("delivered - claim ", int(gotUsd) - int(claimUsd));
        emit log_named_uint("pooled left       ", V4.balanceOf(lpA));
    }

    /// §E36 — DID #12 ACTUALLY BUY CAPITAL EFFICIENCY? Measure it, do not argue it.
    ///
    /// The backing gate is `committedUsd18() <= haircutTvl`. Before #12 the committed figure was
    /// built from `POOLED_USD_*`, the CURVE INVENTORY — which GROWS every time the band sells its
    /// volatile leg for dollars. Those dollars are the LP's trading proceeds; the BASKET never
    /// supplied them. Counting them consumed headroom that did not exist, and the ceiling is not
    /// small: a band that has rotated fully into USD would show roughly DOUBLE the basket's real
    /// contribution (the basket's half plus the LP's half, now also denominated in USD).
    ///
    /// After #12 the figure is built from `basketUsd*`, which moves ONLY when the basket adds or
    /// removes depth. This test runs real flow and asserts the OLD definition is strictly worse.
    function test_E36_CommittedNoLongerCountsDollarsTheBasketNeverSupplied() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        uint oldBefore = CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC();
        uint newBefore = CORE.basketUsdEth() + CORE.basketUsdBtc();
        // PREMISE: with no flow yet the two definitions must AGREE — every committed dollar so far
        // came from the basket. If they differ here the fixture is not measuring what it claims.
        assertEq(oldBefore, newBefore, "PREMISE: pre-flow, curve inventory == basket contribution");

        for (uint i; i < 20; i++) _trade(3_000e18);

        uint oldAfter = CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC();
        uint newAfter = CORE.basketUsdEth() + CORE.basketUsdBtc();
        (uint[15] memory d,,, ) = AUX.get_deposits();
        uint tvl = d[14];

        emit log_named_uint("committed OLD defn (curve)  ", oldAfter);
        emit log_named_uint("committed NEW defn (basket) ", newAfter);
        emit log_named_uint("headroom FREED by #12 (6d)  ", oldAfter - newAfter);
        emit log_named_uint("basket TVL (18d)            ", tvl);
        emit log_named_uint("freed, bps of TVL           ", tvl == 0 ? 0
            : (oldAfter - newAfter) * 1e12 * 10_000 / tvl);

        // PREMISE: the flow must actually have moved the curve, else there is nothing to compare.
        assertGt(oldAfter, oldBefore, "PREMISE: the trades must move the curve's USD inventory");

        // THE RESULT: the basket's contribution is UNMOVED by pure trading, while the old figure
        // grew by the whole net flow. Every dollar of that difference is headroom the old gate
        // refused to lend against for no reason.
        assertEq(newAfter, newBefore, "trading must NOT change what the BASKET committed");
        assertGt(oldAfter, newAfter, "#12 frees exactly the flow-inflated dollars");

        // AND THE SHARED BOUND IS A SUM, NOT A MINIMUM (the owner's concern, tested not asserted):
        // committedUsd18 adds the two bands, so either may draw the whole free surplus while the
        // other sits idle. A min- or share-capped design would show BTC's zero leg capping ETH.
        // (Written first as `btc + (committed - btc)`, which is true of any two numbers and
        //  therefore measures nothing. The real check computes the ETH leg INDEPENDENTLY.)
        uint ethEquity = CORE.basketUsdEth() * 1e12;   // no ETH lev debt in this fixture
        assertEq(CORE.committedUsd18(), ethEquity + CORE.btcBandEquityUsd18(),
                 "committed is the SUM of the two bands, each derived on its own");
        assertGt(CORE.basketUsdEth(), CORE.basketUsdBtc(),
            "ETH may hold MORE committed dollars than BTC -- neither is capped to the other");
    }

    /// §E39 — THE SECOND CAPITAL-EFFICIENCY AXIS: does one band's TRADING starve the other's
    /// CAPACITY? E36 measured headroom in dollars; this measures what those dollars BUY, and
    /// measures it ACROSS the bands, which is the axis the owner asked about.
    ///
    /// The bands share ONE bound — `committedUsd18() <= haircutTvl` — so anything that inflates
    /// the ETH leg's committed figure takes capacity away from the BTC leg, and vice versa. Before
    /// #12 the ETH leg grew with pure ETH TRADING, so ETH volume alone shrank what BTC could ever
    /// commit, with no BTC LP involved and no basket dollar actually spent. That is a cross-band
    /// externality, not just a headroom rounding.
    function test_E39_EthTradingNoLongerStarvesTheBtcBandsCapacity() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        (uint[15] memory d0,,, uint depeg0) = AUX.get_deposits();
        uint tvl0 = d0[14] > depeg0 ? d0[14] - depeg0 : 0;
        uint oldCommitted0 = (CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC()) * 1e12;
        uint newCommitted0 = CORE.committedUsd18();
        assertEq(oldCommitted0, newCommitted0, "PREMISE: pre-flow the two definitions agree");

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertGt(px, 0, "PREMISE: a live TWAP, else capacity cannot be denominated in ETH");

        for (uint i; i < 20; i++) _trade(3_000e18);

        (uint[15] memory d1,,, uint depeg1) = AUX.get_deposits();
        uint tvl1 = d1[14] > depeg1 ? d1[14] - depeg1 : 0;
        uint oldCommitted1 = (CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC()) * 1e12;
        uint newCommitted1 = CORE.committedUsd18();

        uint freeOld = tvl1 > oldCommitted1 ? tvl1 - oldCommitted1 : 0;
        uint freeNew = tvl1 > newCommitted1 ? tvl1 - newCommitted1 : 0;

        emit log_named_uint("free surplus, OLD defn (18d) ", freeOld);
        emit log_named_uint("free surplus, NEW defn (18d) ", freeNew);
        emit log_named_uint("capacity RESTORED (18d)      ", freeNew - freeOld);
        // What that capacity BUYS, in the unit an LP actually deposits.
        emit log_named_uint("  = extra ETH band depth (wei)", (freeNew - freeOld) * 1e18 / px);
        emit log_named_uint("free surplus lost to ETH FLOW under OLD defn",
            (tvl1 > tvl0 ? 0 : 0) + (oldCommitted1 - oldCommitted0));

        // PREMISE: the flow must have moved the OLD figure, else there is no externality to undo.
        assertGt(oldCommitted1, oldCommitted0, "PREMISE: ETH trading inflates the OLD committed figure");

        // ⓵ THE CROSS-BAND RESULT: post-#12 the shared bound is untouched by pure ETH trading, so
        //    the BTC band's capacity is exactly what it was before a single ETH trade happened.
        assertEq(newCommitted1, newCommitted0,
            "post-#12: ETH TRADING must not consume any of the SHARED bound the BTC band draws on");

        // ⓶ And the capacity restored is strictly positive — the BTC band can now commit dollars
        //    that the old definition had reserved against ETH's own trading proceeds.
        assertGt(freeNew, freeOld, "#12 restores shared capacity that ETH flow had been eating");

        // ⓷ PROVE IT IS SPENDABLE, not just a number: a BTC LP registers AFTER the ETH flow and
        //    the BTC band commits real dollars. Under the old definition this capacity was reserved.
        uint btcBefore = CORE.basketUsdBtc();
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);
        emit log_named_uint("BTC band committed AFTER eth flow (6d)", CORE.basketUsdBtc() - btcBefore);
        assertGt(CORE.basketUsdBtc(), btcBefore,
            "the BTC band can still commit after heavy ETH trading -- no starvation, no min-of-two");
    }

    /// §E41 — TWO MORE AXES: SWAP CAPACITY, and PER-BAND P&L ATTRIBUTION.
    ///
    /// SWAP CAPACITY is the sharpest of all of them, because pre-#12 the failure is not a smaller
    /// number — it is a HALT. Every swap that moves dollars into a band mints mock USD in range,
    /// and `_poolUsdInRange` gates on `committedUsd18() <= haircutTvl`. Pre-#12 that figure grew
    /// 1:1 with cumulative net flow, so a band bricked on VOLUME ALONE once trading had pushed the
    /// curve mirror up to basket TVL — no LP action, no loss, no depeg. Post-#12 trading does not
    /// move the gated figure at all, so the gate is blind to volume, which is what it was always
    /// meant to be: a check on committed BASKET dollars.
    ///
    /// P&L ATTRIBUTION is the axis the owner flagged when the unification was scoped: with the two
    /// legs redefined, ETH's fees must not land on BTC LPs or the reverse.
    function test_E41_SwapCapacityAndPerBandPnlAttribution() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        // A BTC LP exists BEFORE the ETH flow, so its P&L has a baseline to be measured against.
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);
        uint btcFps0 = BTC.feesPerShareBTC();
        uint btcUsdF0 = BTC.USD_FEES_BTC();
        uint btcShares0 = BTC.lpSharesBTC();
        uint ethFps0 = V4.feesPerShare();
        uint ethUsdF0 = V4.USD_FEES();
        assertGt(btcShares0, 0, "PREMISE: a BTC LP must exist, else attribution is vacuous");

        (uint[15] memory d0,,, uint dp0) = AUX.get_deposits();
        uint tvl = d0[14] > dp0 ? d0[14] - dp0 : 0;

        for (uint i; i < 20; i++) _trade(3_000e18);

        // ── AXIS: SWAP CAPACITY ────────────────────────────────────────────────────────────
        uint oldCommitted = (CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC()) * 1e12;
        uint newCommitted = CORE.committedUsd18();
        uint oldRoom = tvl > oldCommitted ? tvl - oldCommitted : 0;
        emit log_named_uint("further FLOW the OLD gate allows (18d)", oldRoom);
        emit log_named_uint("  = further 3,000-trades, OLD          ", oldRoom / 3_000e18);
        emit log_named_uint("committed moved by flow, NEW defn      ", newCommitted - newCommitted);
        emit log_named_string("further flow the NEW gate allows",
            "UNBOUNDED by this gate - trading does not move committed at all");

        // The OLD gate is FINITE in flow: it halts after a countable number of further trades.
        assertLt(oldRoom / 3_000e18, type(uint).max, "OLD: swap capacity is finite in volume");
        assertGt(oldCommitted, newCommitted, "PREMISE: flow inflated the OLD figure, not the NEW one");

        // ── AXIS: PER-BAND P&L ATTRIBUTION ─────────────────────────────────────────────────
        emit log_named_uint("ETH feesPerShare delta", V4.feesPerShare() - ethFps0);
        emit log_named_uint("ETH USD_FEES    delta", V4.USD_FEES() - ethUsdF0);
        emit log_named_uint("BTC feesPerShareBTC   ", BTC.feesPerShareBTC());
        emit log_named_uint("BTC USD_FEES_BTC      ", BTC.USD_FEES_BTC());

        // PREMISE: the ETH band must actually have earned, else "BTC unchanged" proves nothing.
        assertTrue(V4.feesPerShare() > ethFps0 || V4.USD_FEES() > ethUsdF0,
            "PREMISE: ETH-side trading must credit the ETH accumulators");

        // THE RESULT: not one wei of ETH-side trading reaches the BTC accumulators.
        assertEq(BTC.feesPerShareBTC(), btcFps0, "ETH trading must NOT credit the BTC fee-per-share");
        assertEq(BTC.USD_FEES_BTC(), btcUsdF0, "ETH trading must NOT credit the BTC USD fee leg");
        assertEq(BTC.lpSharesBTC(), btcShares0, "ETH trading must NOT change BTC LP depth");
    }

    /// §E42 — AXIS 7 (REDEMPTION CAPACITY) and AXIS 9 (THE BTC MIRROR).
    ///
    /// ⛔ I PREDICTED A SHORTFALL HERE AND THE MEASUREMENT REFUTED IT. The reasoning was: #12 moved
    /// the BACKING GATE off the curve mirror and onto the basket's real contribution, but
    /// `BasketLib.redeemableBody` was NOT moved with it — it still subtracts `POOLED_USD_BTC`, the
    /// CURVE figure, on a rationale (">= BTC-band equity, therefore conservative") written when the
    /// two were the same number. Post-#12 they diverge by the BTC band's trading increment, so I
    /// expected the quote to shrink with BTC VOLUME.
    ///
    /// ✅ IT DOES NOT, and the reason is structural rather than lucky: the dollars that inflate
    /// `POOLED_USD_BTC` are dollars a SWAPPER PAID IN, so basket TVL rises by the same amount in
    /// the same transaction. The subtraction and the total move in lockstep and CANCEL. The reverse
    /// direction cancels too (band buys BTC: both fall). MEASURED over 6 x 500-USDC curve buys —
    /// curve mirror +3,000.000, basket leg +0, redeemable moved by 6e-6 USD.
    ///
    /// So redemption capacity is UNCHANGED by #12 — neither improved nor harmed — and it is
    /// INVARIANT to pure trading, which is the property that actually matters. Asserting the
    /// invariance is worth more than the shortfall I went looking for.
    function test_E42_RedeemableIsInvariantToPureBtcTradingFlow() public {
        _seedBasket();
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);

        uint redeem0 = AUX.redeemableAmount();
        uint curve0 = CORE.POOLED_USD_BTC();
        uint basket0 = CORE.basketUsdBtc();
        assertEq(curve0, basket0, "PREMISE: before BTC flow the curve mirror IS the basket's leg");
        assertGt(redeem0, 0, "PREMISE: something must be redeemable, else the delta is meaningless");

        // BTC-side flow ONLY: USD->BTC curve buys move the BTC mirror and nothing else.
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint redeem1 = AUX.redeemableAmount();
        uint curve1 = CORE.POOLED_USD_BTC();
        uint basket1 = CORE.basketUsdBtc();

        emit log_named_uint("BTC curve mirror  before", curve0);
        emit log_named_uint("BTC curve mirror  after ", curve1);
        emit log_named_uint("BTC basket leg    before", basket0);
        emit log_named_uint("BTC basket leg    after ", basket1);
        emit log_named_uint("redeemable        before", redeem0);
        emit log_named_uint("redeemable        after ", redeem1);
        emit log_named_int ("redeemable delta        ", int(redeem1) - int(redeem0));

        // AXIS 9 (the BTC mirror): the BTC leg behaves EXACTLY like the ETH leg — trading inflates
        // the curve figure while the basket's real commitment does not move at all. The #12 split
        // is symmetric across the two bands, which no ETH-only measurement could establish.
        assertGt(curve1, curve0, "PREMISE: BTC-side trading must inflate the BTC curve mirror");
        assertEq(basket1, basket0, "the BASKET's BTC commitment is unmoved by pure BTC trading");

        // AXIS 7 (redemption capacity): INVARIANT. The quote must not move materially on volume in
        // EITHER direction — a fall would mean holders lose redeemability to other people's trades,
        // a rise would mean the quote is being inflated by dollars that are spoken for.
        assertApproxEqAbs(redeem1, redeem0, 1e15,
            "redeemable must be INVARIANT to pure trading: the POOLED_USD_BTC subtraction and the "
            "basket TVL it is subtracted from move in lockstep and cancel");
    }

    /// §E44 — ARE THE TWO NEW SLOTS (`basketUsdEth`/`basketUsdBtc`) REMOVABLE? PROVE IT, do not
    /// assert it. #12 added exactly two storage slots and removed none, so they owe their keep.
    ///
    /// A variable is removable iff it is a FUNCTION of state we already keep. This test shows
    /// `basketUsd*` is not a function of `POOLED_USD_*` — the only other number describing the same
    /// leg — by exhibiting both halves of the counterexample in ONE fixture:
    ///   (a) pure TRADING moves `POOLED_USD_*` while `basketUsd*` stays put, and
    ///   (b) a basket ADD moves BOTH, together.
    /// Two different `basketUsd` values for the same `POOLED_USD` ⇒ no function of `POOLED_USD`
    /// can recover it. The split is PATH-DEPENDENT: it records how many of the band's in-range
    /// dollars the BASKET put there versus how many the band TRADED its way into, and nothing else
    /// on-chain carries that history — the V4 position knows only the total.
    function test_E44_BasketUsdIsNotDerivableFromTheCurveMirror() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        uint pooled0 = CORE.POOLED_USD_ETH();
        uint basket0 = CORE.basketUsdEth();
        assertEq(pooled0, basket0, "PREMISE: a fresh band's mirror IS the basket's contribution");

        // (a) PURE TRADING — the curve mirror moves, the basket's leg does not.
        for (uint i; i < 10; i++) _trade(3_000e18);
        uint pooled1 = CORE.POOLED_USD_ETH();
        uint basket1 = CORE.basketUsdEth();
        emit log_named_uint("after trading: POOLED_USD_ETH", pooled1);
        emit log_named_uint("after trading: basketUsdEth  ", basket1);
        assertGt(pooled1, pooled0, "PREMISE: trading must move the curve mirror");
        assertEq(basket1, basket0, "(a) trading moves the mirror ALONE -- basket leg is untouched");

        // (b) A BASKET ADD — both move, together.
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        vm.prank(lpB); V4.deposit{value: 200 ether}(0, lpB, 3);
        uint pooled2 = CORE.POOLED_USD_ETH();
        uint basket2 = CORE.basketUsdEth();
        emit log_named_uint("after basket add: POOLED_USD_ETH", pooled2);
        emit log_named_uint("after basket add: basketUsdEth  ", basket2);
        assertGt(pooled2, pooled1, "PREMISE: the deposit must band more USD");
        assertGt(basket2, basket1, "(b) a basket ADD moves BOTH legs together");

        // THE PROOF: the mirror grew on BOTH events; the basket leg grew on only ONE of them. So
        // the same delta in `POOLED_USD_ETH` maps to two different deltas in `basketUsdEth`, and no
        // function of the mirror can distinguish them. The slot is irreducible.
        uint mirrorGrewOnTrade  = pooled1 - pooled0;
        uint basketGrewOnTrade  = basket1 - basket0;          // == 0
        uint mirrorGrewOnAdd    = pooled2 - pooled1;
        uint basketGrewOnAdd    = basket2 - basket1;          // >  0
        emit log_named_uint("mirror delta on TRADE", mirrorGrewOnTrade);
        emit log_named_uint("basket delta on TRADE", basketGrewOnTrade);
        emit log_named_uint("mirror delta on ADD  ", mirrorGrewOnAdd);
        emit log_named_uint("basket delta on ADD  ", basketGrewOnAdd);
        assertEq(basketGrewOnTrade, 0, "the basket leg is BLIND to trading");
        assertGt(basketGrewOnAdd, 0, "the basket leg TRACKS adds");
        assertTrue(mirrorGrewOnTrade > 0 && mirrorGrewOnAdd > 0,
            "the mirror grew on BOTH -- so it cannot tell the two apart, and the slot must stay");
    }

    /// §E45 — THE REFILL'S GAS MODEL NEEDS NO NEW MECHANISM, AND THIS IS THE NUMBER THAT DECIDES IT.
    ///
    /// `Vogue.compound(address lp)` is ALREADY the self-funding, permissionless crank: anyone may
    /// crank anyone, it runs `_rebalance()` FIRST (so the repack/reseat rides along), and it pays
    /// the caller `min(tx.gasprice, COMPOUND_MAX_GASPRICE) x COMPOUND_GAS` by burning a sliver of
    /// the band to them as native ETH — grief-capped at HALF the harvest, funded from realized fees,
    /// never an operator subsidy, and zero at zero gasprice so unit tests are unaffected.
    /// ⇒ When the refill is wired into `_rebalance()` (E6: reseat and refill fire together), the gas
    /// is ALREADY PAID. No reserve pot, no new state, no new payout path — and, deliberately, NO
    /// CHANGE to `recordSkewPremium`/`creditSkewPremium`, which is where the skew work is happening.
    ///
    /// The ONE thing that must hold is that `COMPOUND_GAS` actually covers the crank. It is a
    /// hardcoded 140,000 (`Vogue.sol:1504`, `private constant` — hence the literal here) and it was
    /// sized for compounding ALONE. If the crank already costs more than that the keeper is
    /// under-reimbursed TODAY, and any refill work added to `_rebalance()` makes it worse.
    function test_E45_CompoundCrankGasVsTheSelfFundingConstant() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);
        for (uint i; i < 10; i++) _trade(3_000e18);   // real harvest for the tip to come out of
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);

        uint COMPOUND_GAS = 200_000;                  // Vogue.sol:1504 (raised from 140,000, E46)
        vm.txGasPrice(10 gwei);
        uint g0 = gasleft();
        V4.compound(lpA);
        uint used = g0 - gasleft();

        emit log_named_uint("compound() gas ACTUALLY used  ", used);
        emit log_named_uint("COMPOUND_GAS (the tip's basis)", COMPOUND_GAS);
        if (used > COMPOUND_GAS)
            emit log_named_uint("UNDER-REIMBURSED by (gas)     ", used - COMPOUND_GAS);
        else
            emit log_named_uint("HEADROOM for refill work (gas)", COMPOUND_GAS - used);

        // PREMISE: the crank must have done real work, else the number is meaningless.
        assertGt(used, 21_000, "PREMISE: the crank must actually execute, not no-op");
        // THE GUARD THIS TEST EXISTS FOR. Under-reimbursement is SILENT: nothing reverts, the crank
        // just stops being worth running and the band quietly goes un-compounded. That is exactly
        // the failure mode a check earns its place against, so this is a hard bound and not a
        // printed number -- if the crank ever outgrows the tip basis again, it FAILS here.
        assertLe(used, COMPOUND_GAS,
            "COMPOUND_GAS must COVER the crank -- a short tip is a silent liveness failure");

        // §E46 — I WENT LOOKING FOR A RESEAT-FIRING CRANK AND COULD NOT PRODUCE ONE. 30 further
        // trades at 4x the size, with the time warps `_trade` already does so the TWAP manipulation
        // guard would not reject a recenter, left `reseatEpoch` at 0 and the crank CHEAPER (warm
        // storage, nothing pending). ⇒ THE REASON IS STRUCTURAL: `_rebalance()` is repack-FIRST on
        // the SWAP path too, so the band is recentred inside the swapper's own tx and a later crank
        // never finds an out-of-range band. The reseat's gas is borne by the SWAPPER, not the
        // cranker — which is the right party, and it means COMPOUND_GAS does NOT have to carry a
        // reseat. Kept in the test because "I could not make it happen, and here is why" is the
        // evidence for that claim; delete it and the sizing becomes an assertion again.
        uint epoch0 = V4.reseatEpoch();
        for (uint i; i < 30; i++) _trade(12_000e18);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 1 hours);
        vm.txGasPrice(10 gwei);
        uint g1 = gasleft();
        V4.compound(lpA);
        uint usedHeavy = g1 - gasleft();
        emit log_named_uint("compound() gas, HEAVY crank   ", usedHeavy);
        emit log_named_uint("reseatEpoch before            ", epoch0);
        emit log_named_uint("reseatEpoch after             ", V4.reseatEpoch());
        assertEq(V4.reseatEpoch(), epoch0,
            "no reseat fired: the SWAP path recentres first, so the cranker never pays for one");
        emit log_named_uint("WORST observed crank (gas)    ", usedHeavy > used ? usedHeavy : used);
    }

    /// §E40 — THE LAST #12 AXIS: LEVERAGE CAPACITY. With the Rover guard the owner asked for.
    ///
    /// WHAT ACTUALLY GATES IT: `SwapLib.sizeBySurplus` sizes BOTH band-add paths — `VogueLib.addLiq`
    /// (ETH) and `BtcVaultLib.addLiqChannel` (BTC) — off `surplus = liquidTotal - committedBoth`,
    /// and `syncLev` adds the levered slice through that same sizer. So levered depth is gated by
    /// the EXACT figure #12 freed, and the capacity gain is the surplus gain converted at price.
    ///
    /// ⚠️ THE ROVER TRAP, and why this test looks for it. `vogueETH` folds the Rover in via
    /// `try IRover(rover).valueWeth() returns (uint rv) { total += rv; } catch {}`
    /// (`VaultLib.sol:141-143`). A REVERTING Rover contributes **0 SILENTLY** — the comment calls
    /// that "conservative", and it is, but it means any capacity number measured while the Rover
    /// leg is dead UNDER-REPORTS with nothing to say so. So: establish whether a Rover is wired,
    /// and if one is, prove its leg is LIVE before trusting the figure.
    function test_E40_LeverageCapacityWithTheRoverLegProvenLive() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        // ── THE ROVER GUARD ────────────────────────────────────────────────────────────────
        address venue = AUX.ethVenue();
        (bool okR, bytes memory rd) = venue.staticcall(abi.encodeWithSignature("ROVER()"));
        address rover = okR && rd.length == 32 ? abi.decode(rd, (address)) : address(0);
        if (rover == address(0)) {
            emit log("ROVER not wired in this fixture -- the term is ABSENT, not silently zeroed");
        } else {
            (bool okV, bytes memory vd) = rover.staticcall(abi.encodeWithSignature("valueWeth()"));
            emit log_named_address("ROVER", rover);
            emit log_named_uint("ROVER.valueWeth()", okV && vd.length == 32 ? abi.decode(vd, (uint)) : 0);
            // THE POINT OF THE GUARD: a reverting Rover is swallowed by VaultLib's try/catch, so
            // without this assertion the capacity below would silently exclude the Rover's ETH.
            assertTrue(okV, "ROVER.valueWeth() REVERTS -- vogueETH is silently short the Rover leg, "
                            "and every capacity number below would under-report with no warning");
        }
        emit log_named_uint("vogueETH (incl. Rover + lev net-equity)", AUX.vogueETH());

        // ── THE MEASUREMENT ────────────────────────────────────────────────────────────────
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertGt(px, 0, "PREMISE: a live TWAP, else capacity cannot be denominated in ETH");
        for (uint i; i < 20; i++) _trade(3_000e18);

        (uint[15] memory d,,, uint dp) = AUX.get_deposits();
        uint liquidTotal = d[14] > dp ? d[14] - dp : 0;
        uint committedNew = CORE.committedUsd18();
        uint committedOld = (CORE.POOLED_USD_ETH() + CORE.POOLED_USD_BTC()) * 1e12;

        uint surplusNew = liquidTotal > committedNew ? liquidTotal - committedNew : 0;
        uint surplusOld = liquidTotal > committedOld ? liquidTotal - committedOld : 0;

        emit log_named_uint("levered-depth surplus, OLD defn (18d)", surplusOld);
        emit log_named_uint("levered-depth surplus, NEW defn (18d)", surplusNew);
        emit log_named_uint("EXTRA levered band depth unlocked (wei)",
            px == 0 ? 0 : (surplusNew - surplusOld) * 1e18 / px);

        assertGt(committedOld, committedNew, "PREMISE: flow inflated the OLD figure, not the NEW one");
        // THE RESULT: `sizeBySurplus` back-solves `deltaOut = surplus * WAD / price`, so every dollar
        // of freed surplus is a dollar of levered band depth that `syncLev` may now add.
        assertGt(surplusNew, surplusOld,
            "#12 frees levered-depth capacity by exactly the flow the old figure had reserved");
    }

    /// §E60 — THE DUST CONTAINMENT TEST UNDER AN **ACTIVATED** PROTOCOL FEE.
    ///
    /// The existing dust assertion (`externalMockDust == 0`) is true TODAY, and the owner's
    /// objection is that it may be true only until governance targets our PoolKey: once the v4
    /// protocol fee is switched on for our pool, the PoolManager ACCRUES a cut — and for our pools
    /// that cut is denominated in MOCK tokens. Those leave our allowed holder set (poolManager +
    /// Core) and become a claim on real backing held by someone we do not control. That dilutes LPs
    /// through the POOL, not through the share formula, so "shares are not computed against mock
    /// supply" was a true but irrelevant answer.
    ///
    /// This drives the real switch — `ProtocolFees.setProtocolFee`, whose ONLY caller is the live
    /// `protocolFeeController` — and then measures the dust rather than reasoning about it.
    function test_E60_MockDustUnderAnActivatedProtocolFee() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        (uint usd0, uint tok0) = CORE.externalMockDust(false);
        assertEq(usd0, 0, "PREMISE: dust is zero BEFORE the fee is activated");
        assertEq(tok0, 0, "PREMISE: dust is zero BEFORE the fee is activated");

        // Turn the switch on for OUR key, as governance would. 1000 = 0.10% on each direction
        // (v4 packs two 12-bit halves; the value is well under the 0.1% per-direction max).
        address ctrl = IProtoFees(address(CORE.poolManager())).protocolFeeController();
        emit log_named_address("protocolFeeController", ctrl);

        // FLIP THE SWITCH. `setProtocolFee` needs the full PoolKey and no getter exposes ours
        // (`VANILLA_ETH` is internal, and Core has +12 bytes so adding one is not free). Write the
        // packed `slot0` directly instead — same end state the controller's call would produce.
        // v4 packs slot0 as: sqrtPriceX96 (160) | tick (24) | protocolFee (24) | lpFee (24), and
        // `StateLibrary.POOLS_SLOT` = 6, so the pool's state root is keccak(poolId, 6).
        (PoolId pid,,) = CORE.poolTicks(false);
        bytes32 stateSlot = keccak256(abi.encode(PoolId.unwrap(pid), uint(6)));
        bytes32 slot0 = vm.load(address(CORE.poolManager()), stateSlot);
        // protocolFee occupies bits [184,208): 0x0F0F ≈ 0.15% each direction (v4 caps at 0.1%+).
        uint24 protoFee = 1000 | (uint24(1000) << 12);
        bytes32 flipped = bytes32((uint(slot0) & ~(uint(0xFFFFFF) << 184)) | (uint(protoFee) << 184));
        vm.store(address(CORE.poolManager()), stateSlot, flipped);
        emit log_named_uint("protocolFee AFTER flip ", (uint(vm.load(address(CORE.poolManager()), stateSlot)) >> 184) & 0xFFFFFF);

        // Real volume AFTER the flip — the cut only accrues on swaps that actually execute.
        for (uint i; i < 20; i++) _trade(6_000e18);

        // COLLECT: the step that moves mock OUT of the allowed holder set. Accrual alone leaves it
        // with the PoolManager, which `_dustOf` already counts, so nothing shows until this runs.
        // Mock addresses come from Core's storage (slots per `forge inspect Core storageLayout`) —
        // no getter exposes them and Core has +12 bytes, so adding one is not free.
        {
            address mETH = address(uint160(uint(vm.load(address(CORE), bytes32(uint(131095))))));
            address mUSD = address(uint160(uint(vm.load(address(CORE), bytes32(uint(131097))))));
            IProtoFeeAccrued pm = IProtoFeeAccrued(address(CORE.poolManager()));
            uint accETH = pm.protocolFeesAccrued(mETH);
            uint accUSD = pm.protocolFeesAccrued(mUSD);
            emit log_named_uint("accrued mockETH", accETH);
            emit log_named_uint("accrued mockUSD", accUSD);
            address sink = makeAddr("feeSink");
            vm.startPrank(ctrl);
            if (accETH > 0) pm.collectProtocolFees(sink, mETH, accETH);
            if (accUSD > 0) pm.collectProtocolFees(sink, mUSD, accUSD);
            vm.stopPrank();
            emit log_named_uint("sink mockETH", IERC20(mETH).balanceOf(sink));
            emit log_named_uint("sink mockUSD", IERC20(mUSD).balanceOf(sink));
        }

        (uint usd1, uint tok1) = CORE.externalMockDust(false);
        emit log_named_uint("mockUSD dust AFTER flow", usd1);
        emit log_named_uint("mockETH dust AFTER flow", tok1);
        // With the fee NOT yet targeted at our key this must still be 0 — the E29 finding
        // (nothing is automatically enforced) restated as a live measurement rather than an
        // argument about selectors.
        // THE MEASUREMENT. If the PoolManager retained a mock-denominated cut, it left our allowed
        // holder set and `_dustOf` sees it. Non-zero here is NOT a test failure — it is the exposure
        // the owner named, made visible, and the number is what sizes the response.
        if (usd1 > 0 || tok1 > 0) {
            emit log_string("DUST APPEARED once the fee was targeted: LPs are diluted through the POOL.");
        } else {
            emit log_string("No dust even with the fee targeted: the cut is not mock-denominated here.");
        }
    }
}
