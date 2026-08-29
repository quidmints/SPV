// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// §E352-REACHABILITY — **IS THE UNMEASURED-VARIANCE FREE CELL REACHABLE BY A SWAP THAT MOVES VALUE?**
///
/// §E352 is booked as *"a free drain at σ²=0"* and gates the largest task cluster in `SPRINT.md`.
/// The cell it pins (`SkewUnmeasuredVariance::test_FlushRangeStillOwesOnlyTheBase`) calls
/// `skewWad(POOL, POOL/10, 0, ethRisk(), 0)` — **`drainUsd6 == 0`**, i.e. a swap that drains nothing.
/// `SkewLearningsAreLive::test_E287_RefillDirectionIsExemptNotPaid` calls the same shape with
/// `σ² = SIGMA` and asserts `> 0`. **Both pass, and both pass ZERO drain**, so between them they
/// bracket σ² and say nothing about drain.
///
/// The production path never passes zero. `SwapLib:444` is
/// `wellSkew(c.core, r.px, r.amount)` — *"§E68: `r.amount` IS the 6-dec drain size"* — and
/// `_fillableDrain` returns `wanted` UNCHANGED when `sigmaSqWad == 0` (`:1`, first branch), so the
/// full swap size reaches `skewWad` precisely in the unmeasured case.
///
/// These tests measure the cell that production can actually construct: **σ² unmeasured AND a real
/// drain.** If the charge is non-zero there, "free drain" is not reachable and §E352 is a question
/// about a synthetic call rather than about money.
contract SkewE352Reachability is Test {
    uint constant POOL = 1_000_000e6;   // $1m range inventory, 6-dec
    uint constant FLOW = 2_000_000e6;   // shed target ABOVE inventory ⇒ scarce
    uint constant CEIL = 3e16;          // UNKNOWN_VARIANCE_SKEW, 3%

    /// THE FLUSH BRANCH, UNMEASURED VARIANCE, WITH A REAL DRAIN. This is the branch §E352 names:
    /// `inv1 >= target` returns `_maxWellSkew(σ²) + _depletion(inv0, inv1)` before the σ² sentinel.
    /// On ETH `_maxWellSkew(0)` IS zero (no splice floor) — so whatever is charged here is the
    /// σ²-FREE depletion term, and it is the whole defence in the unmeasured case.
    function test_UnmeasuredFlushWithARealDrainIsNotFree() public pure {
        uint drain = POOL / 10;                                   // 10% of inventory, a real swap
        uint flush = SwapLib.skewWad(POOL, POOL / 2, 0, SwapLib.ethRisk(), drain);
        assertGt(flush, 0,
            "SE352: an unmeasured FLUSH swap that actually drains must not be free -- _depletion is "
            "sigma-free and is what makes the branch order safe");
        assertLt(flush, CEIL, "and it must not jump to the unknown-variance ceiling either");
    }

    /// THE SAME CELL ON BTC, where `_maxWellSkew(0)` is the 0.2% splice floor rather than zero, so
    /// the charge has two sources. Pinned separately: if the ETH assertion above ever goes red, this
    /// one localises whether the depletion term or the floor was what moved.
    function test_UnmeasuredFlushOnBtcChargesAtLeastTheSpliceFloor() public pure {
        uint flush = SwapLib.skewWad(POOL, POOL / 2, 0, SwapLib.btcRisk(), POOL / 10);
        assertGe(flush, 2e15, "BTC's splice floor is owed even when variance is unmeasured");
    }

    /// AND THE SCARCE BRANCH, which is the one the sentinel actually guards: `inv1 < target` falls
    /// past `:1282` to `:1333` and returns `UNKNOWN_VARIANCE_SKEW`. Pinned so that a change to the
    /// flush branch cannot silently alter the scarce one — they are decided together or not at all.
    function test_UnmeasuredScarceStillChargesTheSentinel() public pure {
        uint scarce = SwapLib.skewWad(POOL, FLOW, 0, SwapLib.ethRisk(), POOL / 10);
        assertEq(scarce, CEIL,
            "SE352: a SCARCE range with unmeasured variance charges the sentinel, not the base");
    }

    /// THE CONTROL, and the reason the two existing tests could not answer this: with `drainUsd6 == 0`
    /// the charge IS zero on ETH at σ²=0. That is the cell §E352 pins — and it is a swap that moves
    /// nothing, which `SwapLib:444` cannot construct because it passes the swap's own size.
    function test_ControlTheZeroDrainCellIsTheOnlyFreeOne() public pure {
        uint zeroDrain = SwapLib.skewWad(POOL, POOL / 2, 0, SwapLib.ethRisk(), 0);
        assertEq(zeroDrain, 0, "the pinned free cell requires drain == 0");
    }
}
