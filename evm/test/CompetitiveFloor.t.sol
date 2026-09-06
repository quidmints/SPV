// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {USDC, RLUSD_TOKEN, PYUSD_TOKEN} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20D2 { function decimals() external view returns (uint8); }

/// @notice §SESS-23 — **THE COMPETITIVE FLOOR: the conversion must beat what we could serve ourselves.**
///
/// §SESS-22 closed the outright theft (a leg that takes our tokens and gives none). What remained was
/// QUALITY: a keeper may route through a venue that delivers **exactly the floor** and keep the rest.
/// The slack is `_slipBps` — **25 bps rising to a 100 bps cap** — while §ROUTE-COST-MEASURED puts real
/// execution at **1.7–8 bps**. Every basis point between is takeable.
///
/// ⭐ **THIS DISSOLVES THE OPEN QUESTION RATHER THAN ANSWERING IT.** The booked remedy was *"tighten
///    `_slipBps`"*, carrying the standing warning *"measure per-route before choosing the number — the
///    number that is safe for USDT is not automatically safe for GHO."* **A live quote IS that
///    per-route measurement**, taken at the size actually being traded, so no number has to be guessed.
///
/// ⚠️ **THE DIRECTION IS THE SAFETY ARGUMENT.** `max(oracleFloor, quote)` means a reference pushed DOWN
///    cannot lower our floor (it falls back to the oracle — today's behaviour), and one pushed UP costs
///    LIVENESS, never custody. That asymmetry is why a manipulable venue is admissible as a FLOOR and
///    would not be admissible as a PRICE.
contract CompetitiveFloorTest is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// ⭐ THE QUOTE IS REAL, AND IT IS THE PRICE A SWAP WOULD ACTUALLY GET.
    function test_TheQuoteIsRealOnTheTableStables() public view {
        uint256 dx = 10_000e6;                                     // 10k USDC
        uint256 qP = LevMath._selfServableQuote(USDC, dx, PYUSD_TOKEN);
        uint256 qR = LevMath._selfServableQuote(USDC, dx, RLUSD_TOKEN);
        console2.log("USDC -> PYUSD quote (6dec):", qP);
        console2.log("USDC -> RLUSD quote (18dec):", qR);
        // Near par, both directions, in the OUTPUT token's own decimals.
        assertGt(qP, 9_000e6,  "PYUSD quote implausibly low");
        assertLt(qP, 11_000e6, "PYUSD quote implausibly high");
        assertGt(qR, 9_000e18,  "RLUSD quote implausibly low");
        assertLt(qR, 11_000e18, "RLUSD quote implausibly high");
    }

    /// ⭐ AND IT BINDS: at these sizes a real Curve hop beats `oracle x (1 - slip)`, which is the entire
    ///    point — the floor stops being the slack and starts being the market.
    function test_TheQuoteBeatsTheSlackenedOracleFloor() public view {
        uint256 dx = 10_000e6;
        uint256 q = LevMath._selfServableQuote(USDC, dx, PYUSD_TOKEN);
        // The oracle arm at par, carrying the live slack for this size.
        uint256 slip = 25;                                          // SLIP_BASE_BPS at small size
        uint256 oracleArm = dx * (10_000 - slip) / 10_000;
        console2.log("oracle arm (par - 25bps):", oracleArm);
        console2.log("self-servable quote     :", q);
        assertGt(q, oracleArm,
            "the quote does NOT beat the slackened oracle floor at this size - the floor would not tighten");
        console2.log("bps of bleed removed:", (q - oracleArm) * 10_000 / dx);
    }

    /// 🔴 CONTROL 1 — an UNQUOTABLE route must contribute ZERO, never revert and never loosen.
    ///    WETH is not on `_routeOf`, and USDT/DAI are not either: 2 of 14 stables are covered today.
    function test_Control_UnquotableRoutesContributeZero() public view {
        assertEq(LevMath._selfServableQuote(USDC, 10_000e6, WETH), 0, "WETH must be unquotable");
        assertEq(LevMath._selfServableQuote(WETH, 1 ether, USDC), 0, "WETH must be unquotable, both ways");
        // Identity is the one free answer.
        assertEq(LevMath._selfServableQuote(USDC, 123, USDC), 123, "identity must pass through");
        assertEq(LevMath._selfServableQuote(USDC, 0, PYUSD_TOKEN), 0, "zero in, zero out");
    }

    /// 🔴 CONTROL 2 — the two-hop path composes, or a stable->stable conversion silently gets no floor.
    function test_Control_TwoHopComposesThroughTheHub() public view {
        uint256 dx = 10_000e6;                                      // PYUSD is 6-dec
        uint256 q = LevMath._selfServableQuote(PYUSD_TOKEN, dx, RLUSD_TOKEN);
        console2.log("PYUSD -> USDC -> RLUSD quote (18dec):", q);
        assertGt(q, 9_000e18, "the two-hop quote collapsed - stable->stable would carry no competitive floor");
    }

    /// 🔴 CONTROL 3 — **THE VACUITY CHECK.** If the quote were zero everywhere, every assertion above
    ///    about "never loosens" would hold trivially and the floor would never tighten. At least one
    ///    real route must produce a NON-ZERO quote, or this whole mechanism is inert.
    function test_Control_TheMechanismIsNotInert() public view {
        uint256 q = LevMath._selfServableQuote(USDC, 10_000e6, PYUSD_TOKEN);
        assertGt(q, 0, "CONTROL FAILED - no route quotes anything, so the competitive floor never binds");
    }
}
