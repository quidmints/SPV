// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {HolderRegistration} from "../../../src/identity/holder/HolderRegistration.sol";

/*
 * THE MRZ EXPIRY -> EPOCH CONVERSION, pinned to dates computed independently (sec. 2.18gz-nocontroller).
 *
 * WHY THIS FILE EXISTS AT ALL. `notAfter` used to be hardcoded 0 because "nothing in the proof
 * attests an expiry" - true of `register_identity`, false of the codebase, since `query.nr` had read
 * the field for TD1 all along. The circuit now emits it, so this is the arithmetic standing between a
 * signed statement by the issuing state and a document that expires on its own terms rather than
 * needing an authority to revoke it.
 *
 * THE EXPECTED VALUES ARE NOT WHAT THE IMPLEMENTATION PRODUCES. They were computed with Python's
 * datetime before this test was written - the same discipline as `mrzKey.test.ts`, which pins to
 * ICAO's own worked example rather than to itself. A self-consistent implementation agrees with
 * itself and can still be wrong.
 *
 * ⚠️ FAILURE DIRECTION IS THE POINT OF THE REVERTS. `HolderStateKeeper` reads `notAfter == 0` as
 * "no expiry", so a parse that silently returned 0 would promote an expiring document to a permanent
 * one. Malformed input must revert, never default.
 */
contract MrzExpiryHarness is HolderRegistration {
    function mrzDateToTimestamp(uint256 packed_) external pure returns (uint64) {
        return _mrzDateToTimestamp(packed_);
    }
}

contract MrzExpiryTest is Test {
    MrzExpiryHarness internal h;

    function setUp() public {
        h = new MrzExpiryHarness();
    }

    /// Six ASCII digits packed big-endian, exactly as the circuit emits them.
    function _packed(string memory yymmdd) internal pure returns (uint256 out) {
        bytes memory b = bytes(yymmdd);
        require(b.length == 6, "test: bad fixture");
        for (uint256 i = 0; i < 6; ++i) out = (out << 8) | uint8(b[i]);
    }

    function test_knownDates() public view {
        // Computed with Python datetime, UTC, BEFORE this test existed.
        assertEq(h.mrzDateToTimestamp(_packed("300101")), 1893456000, "2030-01-01");
        assertEq(h.mrzDateToTimestamp(_packed("700101")), 0, "1970-01-01 is the epoch");
        assertEq(h.mrzDateToTimestamp(_packed("991231")), 946598400, "1999-12-31");
        assertEq(h.mrzDateToTimestamp(_packed("260813")), 1786579200, "2026-08-13");
    }

    /// A leap day the century window puts in 2000 - the case a naive /4 rule gets wrong.
    function test_leapDay2000() public view {
        assertEq(h.mrzDateToTimestamp(_packed("000229")), 951782400, "2000-02-29");
    }

    /// The window is policy and is asserted, not assumed: 69 -> 2069, 70 -> 1970.
    function test_centuryWindowBoundary() public view {
        assertEq(h.mrzDateToTimestamp(_packed("690101")), 3124224000, "69 must mean 2069");
        assertEq(h.mrzDateToTimestamp(_packed("700101")), 0, "70 must mean 1970");
    }

    function test_nonDigitReverts() public {
        vm.expectRevert("HolderRegistration: non-digit in expiry");
        h.mrzDateToTimestamp(_packed("30A101"));
    }

    function test_impossibleMonthReverts() public {
        vm.expectRevert("HolderRegistration: bad expiry month");
        h.mrzDateToTimestamp(_packed("301301"));
    }

    function test_zeroDayReverts() public {
        vm.expectRevert("HolderRegistration: bad expiry day");
        h.mrzDateToTimestamp(_packed("300100"));
    }

    /// An all-zero field must NOT silently become "no expiry".
    function test_allZeroDoesNotBecomePermanent() public {
        vm.expectRevert("HolderRegistration: bad expiry month");
        h.mrzDateToTimestamp(_packed("000000"));
    }
}
