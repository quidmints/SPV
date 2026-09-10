// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {SwapLib} from "../../src/imports/SwapLib.sol";

/// @title Echidna harness — `SwapLib.clampByBacking` is the ONE range-add bound (audit #8).
///
/// @notice #8 was closed by EXTRACTING this helper and sharing it verbatim across the ETH range,
///         the BTC LP-add and the BTC reseat — "not by asserting the skip is sound". Its docstring
///         commits to `min(want, HEADROOM, THETA)` where `HEADROOM = backing - pooled`, and the
///         load-bearing claim is the tail: *"now every path stays bounded at the real backing even
///         when theta fails open."* That is a safety property over ALL inputs, which is exactly
///         what a fuzzer should own rather than a hand-picked fork case.
///
///         ASSERTION MODE (`--test-mode assertion`): Echidna fuzzes these arguments directly.
///         `clampByBacking` is `internal pure`, so this thin external wrapper is the only way to
///         reach it — it adds no logic of its own, so a failure here is a failure in SwapLib.
///
///         Deliberately self-contained: no PoolManager, no venues, no fork state. Per the §C#20
///         note, the whole-protocol campaign is the thing that needs 8-16 GB and a mainnet fork;
///         this pure-math slice runs anywhere and is the first invariant to lock down.
contract SwapLibClampEchidna {
    /// @notice The three bounds `clampByBacking` promises, checked on every fuzzed input.
    /// §NO-GAMEABLE-BOUND — `thetaEff` is gone from the signature. The invariant is UNCHANGED and
    /// is now the WHOLE of the function rather than the surviving one of two bounds: headroom was
    /// always the binding cap, and theta could only ever shrink below it.
    function check_clampByBacking(
        uint backing,
        uint pooled,
        uint want
    ) public pure {
        uint got = SwapLib.clampByBacking(backing, pooled, want);

        // HEADROOM: the physical room above current in-range depth. Zero-floored, because
        // `pooled > backing` is reachable (a repack/price move can leave the range over its
        // backing) and must clamp to 0 rather than underflow into a huge allowance.
        uint headroom = backing > pooled ? backing - pooled : 0;

        // (1) Never hand back more depth than was asked for.
        assert(got <= want);

        // (2) THE #8 INVARIANT — never exceed real backing. It used to have to hold for EVERY
        //     theta, including the fail-open branch that was the case #8 was actually about (the BTC
        //     add once had ONLY the theta bound, so a failing theta left it unbounded). With theta
        //     deleted that whole failure mode is unconstructible: headroom is the only bound, and it
        //     is a statement about our own balance sheet.
        assert(got <= headroom);

        // (3) The result is EXACTLY min(want, headroom), unconditionally. This used to be the
        //     fail-open BRANCH -- guarded by `thetaEff >= 1e18` -- and it is now the whole
        //     function, which is the strongest form this assertion has ever had: there is no
        //     longer a configuration in which the clamp is anything else.
        assert(got == (want < headroom ? want : headroom));
    }
}
