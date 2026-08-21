// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §E294 / §E306 — **CALL `pushObservation` AND SEE WHETHER σ² MOVES**
///
/// @notice **THE QUESTION THIS SETTLES: is σ² ≡ 0 because NOTHING WRITES the ring, or because the
///         ESTIMATOR cannot produce a number from writes?** Those have opposite remedies — the first
///         is wired by a keeper, the second means a 1inch pusher would change nothing — and until now
///         no test could tell them apart.
///
///         🔴 **THE EVIDENCE ON RECORD POINTS THE WRONG WAY, AND THAT IS WHY THIS EXISTS.**
///         `DrainAtomicity::test_UNITA_FixtureDrivesRealVariance` drives 20 ticks and reports
///         *"σ² = 1, 1, 1, 0 wad across FOUR full-suite runs … `realizedVarianceWad()` is pinned at ~0
///         and 20 driven ticks cannot budge it"* — read by §E277 / §UNIT-SERIES-MEASURED as a property
///         of OUR SERIES. ⚠️ **But that driver moves the ring only through `_observeIfSourced`, which
///         returns at `if (src == address(0)) return;` — and NO SOURCE IS PINNED (§C1).** So it writes
///         NOTHING, and "the ticks cannot budge it" is the expected result of an unwritten ring rather
///         than a measurement of the estimator. **That test is missing this control.**
///
///         ⇒ `pushObservation` is the OTHER writer: permissionless, anchor-bounded, and with **zero
///         callers anywhere** (§E294). Calling it is the discriminator.
contract PushObservationFillsTheRingTest is AllesFixture {
    uint256 constant OBS_PUSH_MAX_BPS = 50;      // mirrors Core's internal constant

    address constant CL_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// 🔴 **THE FIXTURE DOES NOT PIN AN ASSET FEED, AND THAT IS A FINDING, NOT A NUISANCE.**
    /// `DeployL1_s.sol:356` pins `setAssetFeed(WETH, CL_ETH_USD)` in the REAL deploy; `DeployLib` —
    /// which `AllesFixture` uses — does not. So `AUX.assetPriceFeed(WETH)` is `address(0)` here,
    /// `twapResolve` returns a zero anchor, and **`pushObservation` refuses EVERY push on the
    /// `anchorPx == 0` branch.** ⇒ Any test of the push path through this fixture is VACUOUS unless
    /// it pins the feed first, and it fails SILENTLY: the pushes look accepted and σ² stays 0, which
    /// reads exactly like a broken estimator. **The premise assertion is what caught it.**
    function _pinFeedIfNeeded() internal {
        if (AUX.assetPriceFeed(address(WETH)) != address(0)) return;
        vm.prank(AUX.owner());
        AUX.setAssetFeed(address(WETH), CL_ETHUSD);
    }

    /// The Chainlink anchor, fetched the same way `pushObservation` fetches it.
    function _anchor() internal view returns (uint256 px) {
        (px,) = SwapLib.twapResolve(AUX.assetPriceFeed(address(WETH)), 0, false, OBS_PUSH_MAX_BPS, 1 days);
    }

    /// 🔴 THE DISCRIMINATOR. Push a VARYING but IN-RANGE series, advancing the clock so the ring takes
    ///    distinct samples, then read σ². If it moves, the estimator works and σ² ≡ 0 is purely a
    ///    "nobody calls the writer" gap — which is a keeper, not a redesign.
    function test_E294_PushingObservationsMovesSigma() public {
        _pinFeedIfNeeded();
        uint256 before = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 BEFORE (wad)", before);

        uint256 anchor = _anchor();
        assertGt(anchor, 0, "premise: the anchor is live, else every push is refused");

        // 9 samples: `ringVariance` needs card >= 3 AND n >= 3 AND >= 2 DISTINCT values, and it reads
        // 9 points. Jitter stays inside the 50 bps range on purpose - a push outside it is refused
        // SILENTLY, so an out-of-range series would look exactly like an estimator that does not work.
        for (uint256 i = 0; i < 9; ++i) {
            vm.warp(block.timestamp + 60);           // distinct timestamps, or the ring will not advance
            uint256 jitterBps = (i % 5) * 8;         // 0,8,16,24,32 bps - all < 50
            uint256 px = i % 2 == 0
                ? anchor + anchor * jitterBps / 10_000
                : anchor - anchor * jitterBps / 10_000;
            CORE.pushObservation(px);
        }

        uint256 afterPush = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 AFTER  (wad)", afterPush);
        assertGt(afterPush, before,
            "pushing a varying in-range series did NOT move sigma - the estimator, not the source, is the gap");
    }

    /// CONTROL 1 — would this look the same if I were wrong? An OUT-OF-RANGE push must be REFUSED, and
    /// refused SILENTLY (no revert), because that silence is what makes the call safe to attach to a
    /// carrier transaction (§E294). If out-of-range pushes were accepted, the test above would prove
    /// nothing about the guard.
    function test_E294_ControlOutOfRangePushIsRefusedSilently() public {
        _pinFeedIfNeeded();
        uint256 anchor = _anchor();
        uint256 sigmaBefore = CORE.realizedVarianceWad();
        vm.warp(block.timestamp + 60);
        CORE.pushObservation(anchor * 2);            // 10,000 bps out - must be ignored, not revert
        assertEq(CORE.realizedVarianceWad(), sigmaBefore,
            "an out-of-range push changed state - the 50 bps guard is not holding");
    }

    /// CONTROL 2 — **A SINGLE FLAT PUSH MUST NOT PRODUCE A MEANINGFUL VARIANCE**, or the headline
    /// test proves nothing: σ² could have moved because the ring was WRITTEN rather than because the
    /// series VARIES.
    /// ⛔ **THIS CONTROL WAS WRONG ON FIRST WRITING AND THE CORRECTION IS THE INTERESTING PART.** I
    /// asserted one push leaves σ² UNCHANGED, reasoning that `ringVariance` returns 0 below three
    /// samples. It returned **1 wad**, because `Core.setup` SEEDS the ring — so "one push" is never
    /// the first sample and the floor is already cleared.
    /// ⭐ **AND 1 wad IS EXACTLY THE NUMBER §E277 KEPT MEASURING** (*"σ² = 1, 1, 1, 0 across four
    /// runs"*). That is not a pinned estimator; it is **the floor of a seeded, otherwise-unwritten
    /// ring**, reported faithfully. The estimator was never the problem.
    function test_E294_ControlOneFlatPushIsNegligible() public {
        _pinFeedIfNeeded();
        vm.warp(block.timestamp + 60);
        CORE.pushObservation(_anchor());
        uint256 flat = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 after ONE flat push (wad)", flat);
        // ~17 orders of magnitude below the varying series' 7.7e17.
        assertLt(flat, 1e6, "a single flat push produced a real variance - the series is not the cause");
    }
}
