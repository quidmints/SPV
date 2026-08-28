// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {Date2Time} from '../../contracts/utils/Date2Time.sol';

/*
 * Date2Time had no tests, and it gates real decisions: PublicSignalsBuilder /
 * PublicSignalsTD1Builder reject a query whose `currentDate` is too far from `block.timestamp`, and
 * X509 uses it for certificate validity windows. A wrong conversion there rejects valid passports
 * or accepts stale ones.
 *
 * Reference values are from Python's `calendar.timegm` - an independent implementation, not a
 * re-derivation from this library.
 *
 * THE +2000 IS CORRECT, AND ITS SCOPE IS THE POINT. `timestampFromDate(uint256)` decodes a 6-byte
 * ASCII `yyMMdd` and adds 2000 to the two-digit year, so "740812" is 2074, not 1974. That is right
 * for the ONLY thing it is used on - the CURRENT date - and would be badly wrong for a birth date.
 * Birth dates never reach it: they stay encoded as `birthDateLowerbound`/`birthDateUpperbound` and
 * are compared inside the circuit. test_TwoDigitYearIsAlways20xx pins that so the function is not
 * later reused somewhere it does not belong.
 */
contract Date2TimeTest is Test {
  /// ASCII "yyMMdd" packed big-endian, the MRZ encoding these builders pass in.
  function _enc(string memory yymmdd) internal pure returns (uint256 v) {
    bytes memory b = bytes(yymmdd);
    require(b.length == 6, 'need 6 chars');
    for (uint256 i = 0; i < 6; i++) v = (v << 8) | uint8(b[i]);
  }

  function test_timestampFromDate_matchesReference() public pure {
    assertEq(Date2Time.timestampFromDate(2024, 7, 27), 1_722_038_400, '2024-07-27');
    assertEq(Date2Time.timestampFromDate(2000, 1, 1), 946_684_800, '2000-01-01');
    assertEq(Date2Time.timestampFromDate(2099, 12, 31), 4_102_358_400, '2099-12-31');
  }

  /// @notice Leap years are where hand-rolled date maths breaks. 2024 is a leap year; 2100 is NOT
  /// (divisible by 100, not 400), which a naive `% 4` rule gets wrong.
  function test_leapYearHandling() public pure {
    assertEq(Date2Time.timestampFromDate(2024, 2, 29), 1_709_164_800, '2024-02-29 is valid');
    assertEq(Date2Time.timestampFromDate(2023, 3, 1), 1_677_628_800, '2023-03-01 after a non-leap Feb');
    assertEq(Date2Time.timestampFromDate(2100, 3, 1), 4_107_542_400, '2100 is NOT a leap year');
  }

  function test_encodedMrzDateDecodesCorrectly() public pure {
    assertEq(Date2Time.timestampFromDate(_enc('240727')), 1_722_038_400, 'MRZ 240727');
    assertEq(Date2Time.timestampFromDate(_enc('000101')), 946_684_800, 'MRZ 000101');
    assertEq(Date2Time.timestampFromDate(_enc('240229')), 1_709_164_800, 'MRZ 240229 leap day');
  }

  /*
   * The two-digit year is ALWAYS read as 20xx. Correct for `currentDate`, and the reason this
   * function must never be pointed at a birth date - "990101" is 2099, not 1999.
   */
  function test_TwoDigitYearIsAlways20xx() public pure {
    assertEq(
      Date2Time.timestampFromDate(_enc('990101')),
      Date2Time.timestampFromDate(2099, 1, 1),
      '99 must decode as 2099'
    );
    assertTrue(
      Date2Time.timestampFromDate(_enc('990101')) > Date2Time.timestampFromDate(2024, 1, 1),
      'a 99 year decoding as 1999 would be in the past - it must not'
    );
  }

  function test_roundTripsThroughTimestampToDate() public pure {
    (uint256 y, uint256 m, uint256 d) = Date2Time.timestampToDate(1_722_038_400);
    assertEq(y, 2024);
    assertEq(m, 7);
    assertEq(d, 27);
  }
}
