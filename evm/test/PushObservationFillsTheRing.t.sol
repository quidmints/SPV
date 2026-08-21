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

    /// The Chainlink anchor, fetched the same way `pushObservation` fetches it.
    function _anchor() internal view returns (uint256 px) {
        (px,) = SwapLib.twapResolve(AUX.assetPriceFeed(address(WETH)), 0, false, OBS_PUSH_MAX_BPS, 1 days);
    }

    /// 🔴 THE DISCRIMINATOR. Push a VARYING but IN-BAND series, advancing the clock so the ring takes
    ///    distinct samples, then read σ². If it moves, the estimator works and σ² ≡ 0 is purely a
    ///    "nobody calls the writer" gap — which is a keeper, not a redesign.
    function test_E294_PushingObservationsMovesSigma() public {
        uint256 before = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 BEFORE (wad)", before);

        uint256 anchor = _anchor();
        assertGt(anchor, 0, "premise: the anchor is live, else every push is refused");

        // 9 samples: `ringVariance` needs card >= 3 AND n >= 3 AND >= 2 DISTINCT values, and it reads
        // 9 points. Jitter stays inside the 50 bps band on purpose - a push outside it is refused
        // SILENTLY, so an out-of-band series would look exactly like an estimator that does not work.
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
            "pushing a varying in-band series did NOT move sigma - the estimator, not the source, is the gap");
    }

    /// CONTROL 1 — would this look the same if I were wrong? An OUT-OF-BAND push must be REFUSED, and
    /// refused SILENTLY (no revert), because that silence is what makes the call safe to attach to a
    /// carrier transaction (§E294). If out-of-band pushes were accepted, the test above would prove
    /// nothing about the guard.
    function test_E294_ControlOutOfBandPushIsRefusedSilently() public {
        uint256 anchor = _anchor();
        uint256 sigmaBefore = CORE.realizedVarianceWad();
        vm.warp(block.timestamp + 60);
        CORE.pushObservation(anchor * 2);            // 10,000 bps out - must be ignored, not revert
        assertEq(CORE.realizedVarianceWad(), sigmaBefore,
            "an out-of-band push changed state - the 50 bps guard is not holding");
    }

    /// CONTROL 2 — the ring must need MORE than one sample, or the first control is vacuous. A single
    /// push cannot produce a variance (`ringVariance` returns 0 below 3 samples), so if sigma moved
    /// after one write the estimator would be doing something other than what it claims.
    function test_E294_ControlOneSampleIsNotEnough() public {
        uint256 sigmaBefore = CORE.realizedVarianceWad();
        vm.warp(block.timestamp + 60);
        CORE.pushObservation(_anchor());
        assertEq(CORE.realizedVarianceWad(), sigmaBefore,
            "one sample produced a variance - ringVariance's card/n floor is not what it claims");
    }
}
