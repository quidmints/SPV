// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {SHA1} from '../../contracts/utils/SHA1.sol';
import {SHA384} from '../../contracts/utils/SHA384.sol';
import {SHA512} from '../../contracts/utils/SHA512.sol';

/*
 * DIFFERENTIAL TESTS for the hand-written hash primitives, which had NO TESTS AT ALL.
 *
 * These sit underneath passport signature verification - CRSASigner and the CECDSA signers all
 * digest with them - so a wrong hash does not fail loudly. It produces a digest that simply never
 * matches a real passport's signature, or worse, matches something it should not. They are also
 * hand-rolled assembly rather than a precompile, which is exactly the code that most needs a
 * reference to check against.
 *
 * Vectors come from Python's hashlib (an independent implementation, not a re-derivation from this
 * one). The lengths are chosen deliberately: 111, 112 and 128 bytes straddle the SHA-2 padding
 * boundary, where a block-length off-by-one hides. A test on "abc" alone would pass on an
 * implementation that pads wrongly.
 */
contract HashPrimitivesTest is Test {
  function _a(uint256 n) internal pure returns (bytes memory out) {
    out = new bytes(n);
    for (uint256 i = 0; i < n; i++) out[i] = 'a';
  }

  // ── SHA-1 ────────────────────────────────────────────────────────────────────────────────

  function test_sha1_matchesHashlib() public pure {
    assertEq(SHA1.sha1(''), bytes20(hex'da39a3ee5e6b4b0d3255bfef95601890afd80709'), 'empty');
    assertEq(SHA1.sha1('abc'), bytes20(hex'a9993e364706816aba3e25717850c26c9cd0d89d'), 'abc');
  }

  /// @notice 55/56/64 straddle SHA-1's own padding boundary - the classic off-by-one.
  function test_sha1_paddingBoundaries() public pure {
    assertEq(SHA1.sha1(_a(111)), bytes20(hex'ac877859d427d9192054eea8feb3b8a403ef83a5'), '111');
    assertEq(SHA1.sha1(_a(112)), bytes20(hex'689993727ba37386bb032495e9dbdfb4dd1ba744'), '112');
    assertEq(SHA1.sha1(_a(128)), bytes20(hex'ad5b3fdbcb526778c2839d2f151ea753995e26a0'), '128');
    assertEq(SHA1.sha1(_a(200)), bytes20(hex'e61cfffe0d9195a525fc6cf06ca2d77119c24a40'), '200');
  }

  // ── SHA-384 ──────────────────────────────────────────────────────────────────────────────

  function test_sha384_matchesHashlib() public pure {
    assertEq(
      SHA384.sha384('abc'),
      hex'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7',
      'abc'
    );
    assertEq(
      SHA384.sha384(''),
      hex'38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b',
      'empty'
    );
  }

  /// @notice SHA-384/512 pad to a 128-byte block, so 111/112/128 are where a wrong length lands.
  function test_sha384_paddingBoundaries() public pure {
    assertEq(
      SHA384.sha384(_a(111)),
      hex'3c37955051cb5c3026f94d551d5b5e2ac38d572ae4e07172085fed81f8466b8f90dc23a8ffcdea0b8d8e58e8fdacc80a',
      '111'
    );
    assertEq(
      SHA384.sha384(_a(112)),
      hex'187d4e07cb306103c69967bf544d0dfbe9042577599c73c330abc0cb64c61236d5ed565ee19119d8c31779a38f791fcd',
      '112'
    );
    assertEq(
      SHA384.sha384(_a(128)),
      hex'edb12730a366098b3b2beac75a3bef1b0969b15c48e2163c23d96994f8d1bef760c7e27f3c464d3829f56c0d53808b0b',
      '128'
    );
  }

  // ── SHA-512 ──────────────────────────────────────────────────────────────────────────────

  function test_sha512_matchesHashlib() public pure {
    assertEq(
      SHA512.sha512('abc'),
      hex'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
      'abc'
    );
    assertEq(
      SHA512.sha512(''),
      hex'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
      'empty'
    );
  }

  function test_sha512_paddingBoundaries() public pure {
    assertEq(
      SHA512.sha512(_a(111)),
      hex'fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2',
      '111'
    );
    assertEq(
      SHA512.sha512(_a(112)),
      hex'c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca',
      '112'
    );
    assertEq(
      SHA512.sha512(_a(128)),
      hex'b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321',
      '128'
    );
  }

  /// @notice SHA-384 must NOT be SHA-512 truncated to a different IV - they share a compression
  /// function but differ in initial state, and conflating them is a real porting mistake.
  function test_sha384_isNotTruncatedSha512() public pure {
    bytes memory s384 = SHA384.sha384('abc');
    bytes memory s512 = SHA512.sha512('abc');
    bool same = true;
    for (uint256 i = 0; i < 48; i++) {
      if (s384[i] != s512[i]) {
        same = false;
        break;
      }
    }
    assertFalse(same, 'sha384 is just truncated sha512 - the IV is wrong');
  }
}
