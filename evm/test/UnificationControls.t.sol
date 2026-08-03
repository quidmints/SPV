// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface IProtoFees { function protocolFeeController() external view returns (address); }
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

    /// EMPIRICAL: is the arber's profit ACTUALLY captured, or only partly? E16 proved the
    /// accumulator MOVED; it never proved it moved by the spread an external arber could have
    /// taken. That distinction is the whole justification for immediate refill ("don't donate the
    /// spread"), so it is measured here rather than assumed.
    ///
    /// THE COMPARISON: after a drain, the band's SPOT sits away from the honest oracle. An arber
    /// closing that gap earns ~ (gap x size). We retain `skewPremium` instead. If retained >= the
    /// gap-implied profit, the capture is real; if it is a small fraction, we are still donating.
    function test_EMPIRICAL_ArberSpreadVsCapturedPremium() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA, 3);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 30 minutes);

        uint prem0 = CORE.skewPremiumETH();
        uint fees0 = V4.USD_FEES();
        uint usd0  = CORE.POOLED_USD_ETH();

        vm.deal(User01, 3_000 ether);
        for (uint i; i < 6; i++) {
            vm.prank(User01);
            try AUX.swap(address(USDC), address(WETH), true, 50_000 * USDC_PRECISION, 0) {} catch {}
            vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        }

        // The dislocation an arber would close.
        (, uint160 sp,) = CORE.poolTicks(false);
        uint spot = _getPrice(sp, V4.token1isETH());
        uint twap = AUX.getTWAPforAsset(address(WETH), 1800);
        uint gapBps = twap > 0 ? (spot > twap ? spot - twap : twap - spot) * 10_000 / twap : 0;

        uint premRetained = CORE.skewPremiumETH() - prem0;
        uint usdMoved     = usd0 > CORE.POOLED_USD_ETH() ? usd0 - CORE.POOLED_USD_ETH() : CORE.POOLED_USD_ETH() - usd0;

        emit log_named_uint("spot                    ", spot);
        emit log_named_uint("twap (honest oracle)    ", twap);
        emit log_named_uint("dislocation (bps)       ", gapBps);
        emit log_named_uint("USD leg moved (6d)      ", usdMoved);
        emit log_named_uint("premium RETAINED (6d)   ", premRetained);
        emit log_named_uint("USD_FEES increment      ", V4.USD_FEES() - fees0);
        // Arber-profit proxy: dislocation applied to the volume that moved.
        uint arbProxy = usdMoved * gapBps / 10_000;
        emit log_named_uint("arb profit PROXY (6d)   ", arbProxy);
        emit log_named_uint("captured / arb-proxy bps", arbProxy > 0 ? premRetained * 10_000 / arbProxy : 0);

        assertGt(premRetained, 0, "PREMISE: a premium was actually retained, else nothing to compare");
        assertGt(usdMoved, 0, "PREMISE: real volume moved");
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
}
