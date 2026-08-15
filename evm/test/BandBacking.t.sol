// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BandBacking} from "../src/BandBacking.sol";

/// @notice The two silent failures this contract exists to prevent are the two tests that matter
///         here: double-committing the same backing, and an amplifier that reads `other = 0`.
///         Neither reverts in the broken version, so both must be asserted on VALUES, not on
///         whether a call succeeded.
contract BandBackingTest is Test {
    BandBacking b;
    address ethBand = address(0xE7);
    address btcBand = address(0xB7);

    function setUp() public {
        b = new BandBacking();
        b.register(ethBand);
        b.register(btcBand);
        b.seal();
    }

    function _report(address band, uint amt) internal { vm.prank(band); b.report(amt); }

    // ─── the solvency bound is a SUM ──────────────────────────────────────────

    /// THE DOUBLE-COMMIT TEST. Under independent instances each band gates against the FULL TVL as
    /// though the sibling did not exist, so 700 + 700 both "fit" under 1000. Here they must not.
    function test_boundIsTheSum_notPerBand() public {
        _report(ethBand, 700);
        _report(btcBand, 700);
        assertEq(b.total(), 1400, "the bound is the SUM of both bands");
        vm.expectRevert(bytes("backing"));
        b.requireBacked(1000);
        b.requireBacked(1400);   // exactly at the limit is allowed
    }

    /// Either band may draw the whole free surplus while the other is idle — the code's stated
    /// intent (no per-band cap, no fixed ETH/BTC split).
    function test_eitherBandMayTakeTheWholeSurplus() public {
        _report(ethBand, 1000);
        _report(btcBand, 0);
        b.requireBacked(1000);
        assertEq(b.total(), 1000);
    }

    // ─── the E53 scarcity amplifier reads ACROSS ──────────────────────────────

    /// THE UNDER-PRICING TEST. A band that cannot see its sibling reads other = 0 forever and
    /// under-prices every skew. Assert the VALUE, since the broken version returns cleanly.
    function test_otherThan_seesTheSibling() public {
        _report(ethBand, 300);
        _report(btcBand, 700);
        assertEq(b.otherThan(ethBand), 700, "ETH must see BTC's claim");
        assertEq(b.otherThan(btcBand), 300, "BTC must see ETH's claim");
    }

    function test_otherThan_isZeroWhenSiblingIdle_butNotBecauseItIsBlind() public {
        _report(ethBand, 500);
        _report(btcBand, 0);
        assertEq(b.otherThan(ethBand), 0, "genuinely zero, and total proves it is not blindness");
        assertEq(b.total(), 500);
    }

    // ─── the seal, which is what makes total() trustworthy ────────────────────

    /// An unsealed accountant can still gain bands, so any sum is PARTIAL — and a partial sum
    /// UNDER-reports, passing a bound it should fail. Refuse rather than answer.
    function test_totalRefusesBeforeSeal() public {
        BandBacking fresh = new BandBacking();
        fresh.register(ethBand);
        vm.expectRevert(BandBacking.NotSealed.selector);
        fresh.total();
    }

    function test_cannotRegisterAfterSeal_norSealTwice() public {
        vm.expectRevert(BandBacking.AlreadySealed.selector);
        b.register(address(0xC0));
        vm.expectRevert(BandBacking.AlreadySealed.selector);
        b.seal();
    }

    function test_onlyRegisteredBandsMayReport() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(BandBacking.NotBand.selector);
        b.report(1);
    }

    function test_onlyDeployerRegisters() public {
        BandBacking fresh = new BandBacking();
        vm.prank(address(0xBAD));
        vm.expectRevert(BandBacking.NotDeployer.selector);
        fresh.register(ethBand);
    }

    /// `report` REPLACES rather than accumulates — it is a level, not a delta. If it accumulated,
    /// a band reporting its unchanged equity twice would double its apparent claim.
    function test_reportIsALevelNotADelta() public {
        _report(ethBand, 400);
        _report(ethBand, 400);
        assertEq(b.total(), 400, "reporting the same level twice must not double it");
    }

    /// The amplifier's denominator is the SAME total the bound uses, by construction. This pins
    /// that they cannot drift apart.
    function test_amplifierAndBoundShareOneDenominator() public {
        _report(ethBand, 250);
        _report(btcBand, 750);
        assertEq(b.otherThan(ethBand) + b.committedOf(ethBand), b.total(), "parts equal the whole");
    }
}
