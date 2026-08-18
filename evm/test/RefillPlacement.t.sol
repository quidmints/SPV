// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {QuidLib} from "../src/imports/QuidLib.sol";

/// @title §E48 REFILL PLACEMENT — the refill as a placement computation, not a trade.
/// @notice These are PURE-FUNCTION tests on purpose: the whole point of the placement form is that
///         it needs no pool, no tick, no sqrt-price, no counterparty — and, since 2026-08-16, no
///         BAND WIDTH either. A test that needed a fixture would be evidence the form is wrong.
///
/// ⛔ `test_BoundsAreRatioSymmetricAroundPx` WAS DELETED, NOT WEAKENED (owner: *"why is there a
///    bound at all, we dont care to store upper and lower"*). It asserted `pLower·pUpper == px²`.
///    That identity is Uniswap's — it presumes an `L` and a curve — and it silently assumed the band
///    is RATIO-SYMMETRIC about `px`. If the half-width comes from an external blended reference
///    (ETH/USDT on v4 with ETH/USDC on v3, TWAP-weighted) the bounds need not be symmetric, so the
///    identity can go false while the placement stays right, because the placement never used it.
///    What replaces it is the invariant stated directly: **equal VALUE on both placed legs**,
///    `tokPlaced·px == usd6Placed`, which assumes nothing about width or symmetry.
contract RefillPlacementTest is Test {
    uint constant PX = 1_884e18;        // USD18 per 1e18 ETH, near the fork's live price

    /// @notice THE TARGET COMPOSITION HOLDS BY CONSTRUCTION. Whatever the inventory mix, the two
    ///         legs PLACED must be equal in VALUE — that is what "1:1" means.
    function test_PlacedLegsAreEqualInValue() public pure {
        uint[3] memory tok = [uint(400e18), 400e18, 10e18];
        uint[3] memory usd = [uint(753_600e6), 100_000e6, 900_000e6];
        for (uint i; i < 3; i++) {
            (uint tokP, uint usd6P,,) = SwapLib.refillPlacement(tok[i], usd[i], PX);
            assertGt(tokP + usd6P, 0, "PREMISE: nothing was placed, so the check is vacuous");
            uint tokPAsUsd6 = tokP * PX / 1e30;
            // exact to rounding: both sides are one mulDiv from the same quantity
            assertApproxEqAbs(tokPAsUsd6, usd6P, 1, "placed legs are not 1:1 by value");
        }
    }

    /// @notice THE WIDTH IS NOT AN INPUT, AND THIS IS THE TEST THAT SAYS SO. The old signature took
    ///         `deltaBps` and returned `pLower`/`pUpper`. The composition never read it: equating
    ///         x·P = y through x = L(1/√P − 1/√Pb), y = L(√P − √Pa) gives P = √(Pa·Pb), which
    ///         ratio-symmetric bounds satisfy for ANY δ. So a band 10x wider places the SAME split,
    ///         and the width can come from an external TWAP-weighted reference without this
    ///         function knowing or storing it.
    function test_CompositionIsIndependentOfAnyWidth() public pure {
        // There is no width argument left to vary, so vary the thing a width would have moved: the
        // answer must depend on (inventory, price) alone. Two calls, identical inputs, and the
        // 1:1-by-value property must hold at every price the band could be reseated at.
        uint[4] memory prices = [uint(1e18), 1_884e18, 50_000e18, 1e24];
        for (uint i; i < 4; i++) {
            (uint tokP, uint usd6P,,) = SwapLib.refillPlacement(400e18, 753_600e6, prices[i]);
            if (tokP == 0 && usd6P == 0) continue;              // degenerate at extreme px, covered below
            uint asUsd6 = FullMathLikeMulDiv(tokP, prices[i]);
            assertApproxEqAbs(asUsd6, usd6P, 1, "1:1 must hold at every price, with no width in sight");
        }
    }

    function FullMathLikeMulDiv(uint tok, uint px) internal pure returns (uint) {
        return tok * px / 1e30;
    }

    /// @notice THE SCARCER LEG BINDS, AND THE SURPLUS IS REPORTED RATHER THAN HIDDEN.
    function test_ScarceLegBinds_AndSurplusIdles() public pure {
        // ETH scarce: 10 ETH (~$18,840) against $900,000
        (uint tokP, uint usdP, uint tokI, uint usdI) =
            SwapLib.refillPlacement(10e18, 900_000e6, PX);
        assertEq(tokP, 10e18, "ETH is scarce, so all of it should be placed");
        assertEq(tokI, 0,     "no ETH should idle when ETH is the binding leg");
        assertGt(usdI, 0,     "USD surplus must be reported, not silently absorbed");
        assertEq(usdP + usdI, 900_000e6, "USD must be conserved across placed + idle");

        // USD scarce: 400 ETH (~$753,600) against $100,000
        (tokP, usdP, tokI, usdI) = SwapLib.refillPlacement(400e18, 100_000e6, PX);
        assertEq(usdP, 100_000e6, "USD is scarce, so all of it should be placed");
        assertEq(usdI, 0,         "no USD should idle when USD is the binding leg");
        assertGt(tokI, 0,         "ETH surplus must be reported");
        assertEq(tokP + tokI, 400e18, "ETH must be conserved across placed + idle");
    }

    /// @notice "SHORT ETH OUTRIGHT" IS REPORTED HONESTLY, NOT PAPERED OVER. This is where "restore
    ///         to 1:1" and "maximise representation of what we hold" DIVERGE: no placement can
    ///         conjure ETH, so the band ends 1:1 on a SMALLER position with USD left over.
    function test_ShortEthCannotBeFixedByPlacement() public pure {
        (uint tokP, uint usdP,, uint usdI) = SwapLib.refillPlacement(1e18, 500_000e6, PX);
        assertEq(tokP, 1e18, "all the ETH we hold should be represented");
        assertApproxEqAbs(usdP, 1_884e6, 1, "USD placed should match the ETH's value, not the balance");
        assertGt(usdI, 490_000e6, "the vast majority of USD cannot be represented and must idle");
    }

    /// @notice THE PLACEMENT FUNCTION IS ALSO THE ATTRIBUTION KEY — idle inventory IS the imbalance.
    ///         ANALYTIC PREDICTION, STATED BEFORE THE RUN. From a balanced band (x·px == y, idle 0),
    ///         a drain of D ETH leaves (x−D) ETH and (y + D·px) USD. ETH becomes the binding leg, so
    ///         placeable USD is (x−D)·px and idle = (y + D·px) − (x−D)·px = 2·D·px — TWICE the value
    ///         removed: the swapper's withdrawal plus the USD they paid that now has no ETH to pair.
    function test_IdleIsTheImbalanceCreated_AndItIsTwiceTheDrain() public pure {
        uint x = 400e18;
        uint y = x * PX / 1e30;                       // exactly balanced: x*px == y
        (,, uint tokI0, uint usdI0) = SwapLib.refillPlacement(x, y, PX);
        assertEq(tokI0 + usdI0, 0, "PREMISE: the starting band must be balanced, else the delta is not the trade's");

        uint drain = 32e18;
        uint paid  = drain * PX / 1e30;
        (,, uint tokI1, uint usdI1) = SwapLib.refillPlacement(x - drain, y + paid, PX);

        assertEq(tokI1, 0, "ETH is now the binding leg, so no ETH should idle");
        assertApproxEqAbs(usdI1, 2 * paid, 2, "idle USD is not 2x the drained value");

        // And it is a DELTA, so a second identical drain adds the same again.
        (,,, uint usdI2) = SwapLib.refillPlacement(x - 2 * drain, y + 2 * paid, PX);
        assertApproxEqAbs(usdI2 - usdI1, 2 * paid, 2, "the second drain must create the same imbalance as the first");
    }

    /// @notice THE RESHAPED FEE IS REVENUE-NEUTRAL ON THE CANONICAL CASE, WITH NO NEW CONSTANT.
    ///         210 ppm on the imbalance must equal 420 ppm on the notional for a drain from balance,
    ///         because that drain creates exactly 2x its own value in idle inventory.
    function test_ReshapedFeeMatchesTheFlatFeeOnADrainFromBalance() public pure {
        uint x = 400e18;
        uint y = x * PX / 1e30;
        (,,, uint idle0) = SwapLib.refillPlacement(x, y, PX);
        assertEq(idle0, 0, "PREMISE: band must start balanced");

        uint drain = 32e18;
        uint paid  = drain * PX / 1e30;
        (,,, uint idle1) = SwapLib.refillPlacement(x - drain, y + paid, PX);

        (uint fee, uint created) = SwapLib.imbalanceFeeUsd6(idle0, idle1, 210);
        assertGt(created, 0, "PREMISE: no imbalance created, so the fee comparison is vacuous");
        assertApproxEqAbs(fee, paid * 420 / 1e6, 2, "reshaped fee is not revenue-neutral on the canonical case");
    }

    /// @notice THE REFILL DIRECTION EXEMPTS ITSELF — and it is not a special case, it is the floor.
    function test_RefillDirectionPaysNothing() public pure {
        uint x = 400e18;
        uint y = x * PX / 1e30;
        (,,, uint idleBefore) = SwapLib.refillPlacement(x - 32e18, y + (32e18 * PX / 1e30), PX);
        assertGt(idleBefore, 0, "PREMISE: the band must start imbalanced, else there is nothing to reduce");

        (,,, uint idleAfter) =
            SwapLib.refillPlacement(x - 16e18, y + (32e18 * PX / 1e30) - (16e18 * PX / 1e30), PX);
        assertLt(idleAfter, idleBefore, "PREMISE: the refill-direction trade must actually reduce idle");

        (uint fee, uint created) = SwapLib.imbalanceFeeUsd6(idleBefore, idleAfter, 210);
        assertEq(created, 0, "a trade that reduces imbalance created none");
        assertEq(fee, 0, "a trade that helps must not be taxed for helping");
    }

    /// @notice DEGENERATE INPUT MUST NOT SILENTLY PLACE. A zero price cannot value either leg, so
    ///         everything idles — a caller that ignores that and places anyway is the failure here.
    function test_ZeroPricePlacesNothing() public pure {
        (uint tokP, uint usdP, uint tokI, uint usdI) =
            SwapLib.refillPlacement(400e18, 100_000e6, 0);
        assertEq(tokP + usdP, 0, "nothing may be placed at an unknown price");
        assertEq(tokI, 400e18,   "all volatile must be reported idle");
        assertEq(usdI, 100_000e6, "all USD must be reported idle");
    }

    /// @notice §E48 THE DELIVERABILITY PRECONDITION HAS TEETH — feeding NOMINAL inventory where a
    ///         DELIVERABLE figure belongs overstates the band's depth, silently.
    ///
    ///         THIS REPLACED A WRAPPER, AND THE DELETION IS THE POINT (standing rule 17). An earlier
    ///         revision added `refillRealisable`, taking `min(nominal, realisable)`. That was a
    ///         SECOND bound over what `QuidLib.deliverableETH` already bounds — it subtracts the
    ///         weETH beyond what Curve can pay for and the unwind-only leverage net-equity. Passing
    ///         the deliverable figure at the SOURCE makes the discrepancy unconstructible rather
    ///         than merely detectable.
    function test_NominalInventoryOverstatesDepthVersusDeliverable() public pure {
        uint x = 400e18;
        uint y = x * PX / 1e30;                       // balanced against the NOMINAL volatile leg
        uint deliverable = x / 2;                     // half is stuck in venues that cannot source it

        (uint nomPlaced,,,)  = SwapLib.refillPlacement(x,           y, PX);
        (uint delPlaced,, uint delIdleTok, uint delIdleUsd) =
                               SwapLib.refillPlacement(deliverable, y, PX);

        assertEq(nomPlaced, x, "PREMISE: on nominal inventory the whole volatile leg places");
        assertEq(delPlaced, deliverable, "deliverable placement must place exactly what can be sourced");
        assertLt(delPlaced, nomPlaced,   "deliverable placement must be strictly shallower than nominal");
        assertEq(delIdleTok, 0,  "no volatile may idle when the volatile leg is the binding one");
        assertGt(delIdleUsd, 0,  "the USD left unpaired must be reported idle, not silently placed");
        assertEq(nomPlaced - delPlaced, x - deliverable,
                 "the depth overstatement must equal the undeliverable inventory exactly");
    }
}
