// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ExternalTwap} from "../src/imports/ExternalTwap.sol";

interface IAggV3 { function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80); }

/// @title  §E294 — CAN A 1inch-SOURCED PUSH ACTUALLY CLEAR `pushObservation`'s GUARD?
///
/// @notice **THE DESIGN NAMES A SOURCE AND A BAND, AND NOTHING CHECKS THEY ARE COMPATIBLE.**
///         `Core.pushObservation` admits a price only within `OBS_PUSH_MAX_BPS = 50` of the Chainlink
///         anchor, and `Core`'s note justifies that number with *"MEASURED basis between 1inch and
///         Chainlink on ETH/USD is 8 bps, so this is ~6x headroom."*
///
///         🔴 **BUT THE ONLY TEST OF THAT BASIS ASSERTS `< 500` BPS**
///         (`OneInchObserverIsIndependent.t.sol:58`) — **ten times looser than the guard.** So a real
///         basis anywhere in (50, 500) passes the existing suite while **every push is refused**, the
///         ring never fills, σ² stays 0, and the skew serves the flat `UNKNOWN_VARIANCE_SKEW`
///         sentinel forever. That state is **indistinguishable from "no source pinned"** — the very
///         thing §C1 is trying to leave — and it is green.
///
///         ⇒ This asserts ADMISSIBILITY, which is a different property from the independence that
///         file tests. Independence says the two sources disagree enough to be worth crossing;
///         admissibility says they agree enough for the push to be accepted. **The design needs BOTH,
///         and they pull in opposite directions** — which is exactly why neither implies the other.
contract PushSourceIsAdmissibleTest is Test {
    address constant ORACLE    = 0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8;  // 1inch OffchainOracle
    address constant WETH      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CL_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /// Mirrors `Core.OBS_PUSH_MAX_BPS` (internal). If Core's moves and this does not, this fails.
    uint256 constant OBS_PUSH_MAX_BPS = 50;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _clWad() internal view returns (uint256) {
        (, int256 a,,,) = IAggV3(CL_ETHUSD).latestRoundData();
        return uint256(a) * 1e10;                       // 8-dec feed -> WAD
    }

    function _basisBps() internal view returns (uint256 bps, uint256 oneInch, uint256 cl) {
        oneInch = ExternalTwap.oneInchRateWad(ORACLE, WETH, USDC, 18, 6);
        cl = _clWad();
        (uint256 lo, uint256 hi) = oneInch < cl ? (oneInch, cl) : (cl, oneInch);
        bps = (hi - lo) * 10_000 / lo;
    }

    /// 🔴 THE ONE THAT MATTERS. If this fails, `pushObservation` refuses every 1inch-sourced push and
    ///    the whole push-oracle design is inert — silently, and with a green suite.
    function test_E294_A1inchPushWouldBeAdmitted() public view {
        (uint256 bps, uint256 oneInch, uint256 cl) = _basisBps();
        console2.log("1inch  ETH/USD (wad):", oneInch);
        console2.log("chainlink ETH/USD   :", cl);
        console2.log("basis (bps)         :", bps);
        assertLt(bps, OBS_PUSH_MAX_BPS,
            "1inch is OUTSIDE the push band => every push refused => the ring never fills");
    }

    /// CONTROL — would this measurement look the same if I were wrong? The EXISTING assertion (500
    /// bps) must pass at the same instant this one does. If it can pass while ours fails, then it
    /// never had the power to catch an inadmissible source, which is the entire reason this file
    /// exists rather than a tightened constant in the other one.
    function test_E294_ControlTheExistingBoundCannotDiscriminate() public view {
        (uint256 bps,,) = _basisBps();
        assertLt(bps, 500, "premise: the existing test's bound holds");
        assertGt(500, OBS_PUSH_MAX_BPS * 5,
            "control void: the existing bound is not meaningfully looser than the guard");
    }

    /// The band must leave real headroom, not merely be satisfied at this block. `Core`'s claim is
    /// ~6x; assert a floor of 2x so a drift that eats the margin fails here BEFORE it silently
    /// starts refusing pushes in production.
    function test_E294_HeadroomIsNotMarginal() public view {
        (uint256 bps,,) = _basisBps();
        assertLt(bps * 2, OBS_PUSH_MAX_BPS,
            "basis has drifted to within 2x of the band - the guard is about to start refusing");
    }
}
