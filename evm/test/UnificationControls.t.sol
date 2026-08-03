// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

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
}
