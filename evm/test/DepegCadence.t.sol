// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeLib} from "../src/imports/FeeLib.sol";

/// @notice A controllable Chainlink-style aggregator for the live depeg feed.
contract MockAggregator {
    int256  public answer;
    uint8   public dec;
    uint256 public updatedAt;
    bool    public revertRead;

    constructor(int256 _answer, uint8 _dec, uint256 _updatedAt) {
        answer = _answer; dec = _dec; updatedAt = _updatedAt;
    }
    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function setRevert(bool r) external { revertRead = r; }
    function decimals() external view returns (uint8) { return dec; }
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        require(!revertRead, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
    /// Doubles as the depeg-severity hook Aux exposes post-CRE: severity is the
    /// feed's own live downside deviation (this is exactly Aux.getDepegSeverityBps).
    function getDepegSeverityBps(address) external view returns (uint) {
        return FeeLib.liveDepegBps(address(this), 1 days);
    }
}

/// @notice Depeg severity now comes ON-CHAIN from each stable's pinned Chainlink
///         feed (the off-chain CRE was removed). `riskFactor(token, hook)` reads
///         `hook.getDepegSeverityBps`, which is the feed's live downside deviation
///         via liveDepegBps. These cases drive the feed (acting as its own hook)
///         straight through riskFactor: deviation→factor, deadband, stale/revert
///         defer-to-0, the 6500 clamp, and non-8-dec scaling.
contract DepegCadenceTest is Test {
    address constant TOKEN = address(0xDEAD);

    function _rf(MockAggregator feed) internal view returns (uint) {
        return FeeLib.riskFactor(TOKEN, address(feed));
    }

    function test_belowPeg_haircutsByLiveDeviation() public {
        // 0.97 USD (8-dec) = 300 bps below peg -> factor 9700, even though the
        // CRE (link=0) reports nothing this round.
        MockAggregator feed = new MockAggregator(0.97e8, 8, block.timestamp);
        assertEq(_rf(feed), 9700, "live 3% depeg haircuts to 9700");
    }

    function test_atOrAbovePeg_noHaircut() public {
        MockAggregator atPeg = new MockAggregator(1e8, 8, block.timestamp);
        assertEq(_rf(atPeg), 10000, "at peg: no haircut");
        MockAggregator above = new MockAggregator(1.01e8, 8, block.timestamp);
        assertEq(_rf(above), 10000, "above peg: no haircut (no redemption risk)");
    }

    function test_staleFeed_defersToCRE() public {
        // A stale feed (benign Chainlink heartbeat lapse) must DEFER to the CRE,
        // not inflict a haircut — the live leg only ever ADDS severity, so a
        // frozen feed can't hide a depeg; it just stops contributing. (With
        // link=0 here, deferring means no haircut at all → 10000.)
        vm.warp(10 days);
        MockAggregator stale =
            new MockAggregator(0.50e8, 8, block.timestamp - 2 days); // even a "depegged" stale read defers
        assertEq(_rf(stale), 10000, "stale feed defers to CRE (no live haircut)");
    }

    function test_deepDepeg_recognizesFullSeverity() public {
        // THE FLOOR WAS REMOVED ON PURPOSE, and this test was left asserting it (fixed 2026-07-26).
        // `FeeLib.riskFactor` now documents the reason in its own docstring: it "recognizes the FULL
        // live severity; the old 6500/65c floor understated severe depegs". So a 0.40 USD read is a
        // 6000 bps deviation and the factor is 4000 (40% of par), NOT clamped up to 6500 — clamping
        // would have valued a 60%-depegged stable at 65c, overstating basket backing exactly when it
        // matters most. Verified pre-existing (not caused by this session's clamp removals, which
        // touched FeeLib MAX_FEE and the theta ceiling, neither of them this floor; the QuidLens
        // lens that used to read it is deleted).
        MockAggregator deep = new MockAggregator(0.40e8, 8, block.timestamp);
        assertEq(_rf(deep), 4000, "deep depeg recognizes FULL severity (no 65% floor)");
    }

    function test_revertingFeed_defersToCRE() public {
        // A reverting feed read defers (no haircut from the feed) — the CRE and
        // the dark-feed gate remain the backstops; redemption isn't bricked.
        MockAggregator down = new MockAggregator(0.97e8, 8, block.timestamp);
        down.setRevert(true);
        assertEq(_rf(down), 10000, "reverting feed defers, no spurious haircut");
    }

    function test_nonStablecoinDecimals_18dec() public {
        // Feeds need not be 8-dec; the peg is 10**decimals. 0.95 at 18-dec.
        MockAggregator feed = new MockAggregator(0.95e18, 18, block.timestamp);
        assertEq(_rf(feed), 9500, "18-dec feed: 5% depeg -> 9500");
    }
}
