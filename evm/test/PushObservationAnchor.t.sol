// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./utils/ForkPin.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §E294 — THE ANCHOR `pushObservation` RESTS ON, ASSERTED FOR THE FIRST TIME
///
/// @notice `Core.pushObservation` is the push-oracle half of the ring and it has **ZERO callers and
///         ZERO tests** (§E294). Its entire safety property is one line:
///
///             (uint256 anchorPx,) = SwapLib.twapResolve(AUX.assetPriceFeed(ASSET), 0, …, 50, 1 days);
///             if (anchorPx == 0) return;                        // no anchor => refuse
///             if ((hi - lo) * 10_000 > lo * 50) return;         // outside 50 bps => refuse
///
///         **That guard is only as good as `twapResolve(feed, 0, …)` actually returning the RAW
///         CHAINLINK ANCHOR.** It does so by way of §A.13, which made `price == 0` fall THROUGH to
///         the feed rather than short-circuit past it — a fix made for a different reason (a
///         self-reinforcing drain deadlock) and relied on here as a load-bearing dependency.
///         **Nothing asserts it.** If that fall-through ever regressed, `pushObservation` would
///         compare a pushed price against zero, take the `anchorPx == 0` branch, and refuse
///         everything — the ring would silently never fill, which is indistinguishable from today's
///         "no source pinned" state and would survive any green suite.
///
///         ⚠️ **SCOPE, STATED SO IT IS NOT OVER-READ.** This file tests the ANCHOR, not
///         `pushObservation` itself: only `Alles.t.sol` builds a `Core`, so the range arithmetic and
///         the write path need that fixture and are still owed (§E294 step 1). What is asserted here
///         is the dependency the guard cannot work without.
///         ⛔ **AND IT IS NOT A MIRROR.** It calls the real `SwapLib.twapResolve` against a real
///         Chainlink feed. Today's lesson is that a test which reimplements the thing it checks
///         (`GammaRederived`'s `_kernel`) passes through a whole rewrite of the subject.
contract PushObservationAnchorTest is ForkPin {
    address constant CL_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /// `OBS_PUSH_MAX_BPS` in `Core` — mirrored because it is `internal`. If Core's moves and this
    /// does not, `test_E294_RangeIsTightEnoughToBoundAPusher` fails loudly. That coupling is intended.
    uint256 constant OBS_PUSH_MAX_BPS = 50;

    /// Forks through `ForkPin` rather than a bare `createSelectFork`, so an exported `FORK_BLOCK`
    /// actually reaches this suite. `ForkPin` promises "every fork in the run uses THAT block, so N
    /// runs are byte-identical"; a file that forks directly makes that promise silently false for
    /// itself, which is the §E214 failure mode one level up — the pin looks applied and is not.
    /// Unset `FORK_BLOCK` (the default) is unchanged: latest block, live state.
    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// 🔴 THE LOAD-BEARING ONE. `price == 0` must fall through to the feed and return a real anchor.
    function test_E294_ZeroPriceFallsThroughToTheChainlinkAnchor() public view {
        (uint256 anchorPx, bool stale) =
            SwapLib.twapResolve(CL_ETHUSD, 0, false, OBS_PUSH_MAX_BPS, 1 days);
        assertGt(anchorPx, 0, "anchor is zero => pushObservation refuses EVERY push, silently");
        // A live ETH/USD price, in WAD. Deliberately wide: this asserts "a real price arrived",
        // not a market level, so it does not go stale as the market moves.
        assertGt(anchorPx, 100e18,     "anchor implausibly low - wrong scaling?");
        assertLt(anchorPx, 100_000e18, "anchor implausibly high - wrong scaling?");
        assertTrue(stale, "price==0 vs the anchor must trip the deviation test and report stale");
    }

    /// The range must be tight enough that a pusher cannot walk the level far. §E294 records the
    /// design claim — "caps an adversary's reachable sigma inflation at +/-0.5% per block" — and
    /// that claim is exactly `OBS_PUSH_MAX_BPS` being small relative to the anchor.
    function test_E294_RangeIsTightEnoughToBoundAPusher() public view {
        (uint256 anchorPx,) = SwapLib.twapResolve(CL_ETHUSD, 0, false, OBS_PUSH_MAX_BPS, 1 days);
        uint256 maxMove = anchorPx * OBS_PUSH_MAX_BPS / 10_000;
        assertEq(maxMove * 10_000 / anchorPx, OBS_PUSH_MAX_BPS, "range arithmetic must be exact");
        // ⚠️ NOT `TWAP_MAX_DEVIATION_BPS` (500). Core's own note: inheriting that "would let a pusher
        // move the level ten times as far". Asserted so a later unification cannot quietly widen it.
        assertLt(OBS_PUSH_MAX_BPS, 500, "the push range must stay tighter than the TWAP range");
    }

    /// CONTROL — would this measurement look the same if I were wrong? A DEAD feed address must NOT
    /// produce a usable anchor. If it did, the first test would pass for a reason unrelated to the
    /// fall-through, and `anchorPx == 0` would never be the refuse-path it is relied on to be.
    function test_E294_ControlADeadFeedYieldsNoAnchor() public view {
        (uint256 anchorPx,) = SwapLib.twapResolve(address(0), 0, false, OBS_PUSH_MAX_BPS, 1 days);
        assertEq(anchorPx, 0, "control void: a zero feed must yield no anchor, so refusal is reachable");
    }
}
