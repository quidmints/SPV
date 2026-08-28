// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.21;

import {Test} from 'forge-std/Test.sol';
import {X509} from '../../contracts/utils/X509.sol';

/// X509's functions are `internal`, so they need a harness to be called across a message boundary.
contract X509Harness {
  using X509 for bytes;

  function extractPublicKey(
    bytes memory signedAttributes_,
    bytes memory checkPrefix_,
    uint256 keyOffset_,
    uint256 keyLength_
  ) external view returns (bytes memory) {
    return signedAttributes_.extractPublicKey(checkPrefix_, keyOffset_, keyLength_);
  }

  function extractExpirationTimestamp(
    bytes memory signedAttributes_,
    uint256 expirationOffset_
  ) external pure returns (uint256) {
    return signedAttributes_.extractExpirationTimestamp(expirationOffset_);
  }
}

/*
 * X509 parses the certificate bytes that gate EVERY DSC admission (sec. 2.18l).
 *
 * WHY THIS SUITE EXISTS. `Registration2.registerCertificate` is permissionless by design: anyone may
 * present a CSCA-signed DSC and have its key added to `certificatesSmt`, which is the tree
 * `register_identity` proves membership in. The CSCA SIGNATURE covers `signedAttributes` - but the
 * OFFSETS used to read a key and an expiry out of those bytes are separate, caller-supplied struct
 * fields that no signature covers. So this library is exactly where a caller-controlled value meets
 * trusted data, and it had no tests at all.
 */
contract X509Test is Test {
  X509Harness internal x509;

  /// The SubjectPublicKeyInfo prefix a real dispatcher is initialised with (CRSADispatcher uses a
  /// sequence of this shape); only its LENGTH matters to the parsing logic under test.
  bytes internal constant PREFIX = hex'0282';

  function setUp() public {
    x509 = new X509Harness();
  }

  /// Build `len` bytes of recognisable filler with `PREFIX` ending exactly at `keyOffset`.
  function _attributes(uint256 len_, uint256 keyOffset_) internal pure returns (bytes memory out_) {
    out_ = new bytes(len_);
    for (uint256 i = 0; i < len_; ++i) {
      out_[i] = bytes1(uint8(0x11));
    }
    out_[keyOffset_ - 2] = PREFIX[0];
    out_[keyOffset_ - 1] = PREFIX[1];
  }

  // ── the behaviour that is correct today ────────────────────────────────────────────────────

  function test_ExtractsAKeyThatSitsEntirelyInsideTheAttributes() public view {
    bytes memory sa = _attributes(64, 8);
    bytes memory key = x509.extractPublicKey(sa, PREFIX, 8, 32);

    assertEq(key.length, 32);
    for (uint256 i = 0; i < 32; ++i) {
      assertEq(uint8(key[i]), 0x11, 'key bytes are not the ones at keyOffset');
    }
  }

  function test_RejectsAnOffsetWhereThePrefixIsAbsent() public {
    bytes memory sa = _attributes(64, 8);
    // The prefix sits before offset 8, so 9 must not be accepted.
    vm.expectRevert(bytes('X509: wrong check placement'));
    x509.extractPublicKey(sa, PREFIX, 9, 32);
  }

  /// The prefix is read at `offset - prefixLength`, so a small offset underflows and must revert
  /// rather than wrap into a huge index.
  function test_RejectsAnOffsetSmallerThanThePrefix() public {
    bytes memory sa = _attributes(64, 8);
    vm.expectRevert();
    x509.extractPublicKey(sa, PREFIX, 1, 32);
  }

  function test_ExtractsAnExpirationTimestamp() public view {
    // "170d" then ASCII "300911072126" -> 2030-09-11 07:21:26 UTC, the example in X509's own docs.
    bytes memory sa = new bytes(32);
    sa[8] = 0x17;
    sa[9] = 0x0d;
    bytes memory ascii_ = bytes('300911072126');
    for (uint256 i = 0; i < 12; ++i) {
      sa[10 + i] = ascii_[i];
    }

    // 1_915_341_686 == 2030-09-11 07:21:26 UTC, the worked example in X509's own doc comment.
    assertEq(x509.extractExpirationTimestamp(sa, 10), 1_915_341_686);
  }

  /*
   * The expiration read is bounded EXPLICITLY, not by how it happens to be written.
   *
   * Indexing `bytes memory` bounds-checks in Solidity, so this reverted before the require existed -
   * with a bare Panic(0x32), and only because the loop indexes rather than memcpys. `extractPublicKey`
   * two functions down did the same job with `unsafeCopy` and had a real out-of-bounds read
   * (sec. 2.18m); the difference between them was style, not intent. This asserts the named error, so
   * the protection belongs to the function rather than to its current implementation.
   */
  function test_RejectsAnExpirationRunningPastTheAttributes() public {
    bytes memory sa = new bytes(24);
    sa[10] = 0x17;
    sa[11] = 0x0d;

    // 12 ASCII digits from offset 12 need 24 bytes; the array has exactly 24, so 13 overruns by one.
    sa[11] = 0x00;
    sa[12] = 0x17;
    sa[13] = 0x0d;
    vm.expectRevert(bytes('X509: expiration runs past the signed attributes'));
    x509.extractExpirationTimestamp(sa, 14);
  }

  /// The boundary is accepted: twelve digits ending exactly at the final byte is an ordinary read.
  function test_AcceptsAnExpirationEndingExactlyAtTheLastByte() public view {
    bytes memory sa = new bytes(24);
    sa[10] = 0x17;
    sa[11] = 0x0d;
    bytes memory ascii_ = bytes('300911072126');
    for (uint256 i = 0; i < 12; ++i) {
      sa[12 + i] = ascii_[i];
    }

    assertEq(x509.extractExpirationTimestamp(sa, 12), 1_915_341_686);
  }

  // ── THE DEFECT ─────────────────────────────────────────────────────────────────────────────

  /*
   * `extractPublicKey` USED TO READ PAST THE END OF THE ATTRIBUTES INSTEAD OF REVERTING.
   *
   * `_checkPrefix` validates only the bytes immediately BEFORE `keyOffset_`; nothing anywhere
   * checks that `keyOffset_ + keyLength_` is within the array. The copy itself is
   * `MemoryUtils.unsafeCopy`, a raw identity-precompile memcpy with no bounds check of any kind.
   *
   * WHY IT MATTERS HERE SPECIFICALLY. `keyOffset` is a caller-supplied field of
   * `Registration2.Certificate` and is NOT covered by the CSCA signature over `signedAttributes`.
   * So a caller holding one genuine CSCA-signed certificate can resubmit it with a different
   * `keyOffset` and have the "public key" read out of adjacent memory - memory that, in a call
   * whose other arguments (`icaoMember.publicKey`, `icaoMember.signature`) are also
   * caller-supplied, they have considerable influence over.
   *
   * That key would then be added to `certificatesSmt` by `addCertificate`, and `certificatesSmt` is
   * the tree `register_identity` proves membership in. A key an attacker controls, admitted there,
   * lets them sign their own SODs and enrol fabricated identities through the permissionless path -
   * which is precisely the path sec. 2.18g is building.
   *
   * BEFORE THE FIX both of these returned a key built from adjacent memory. They are kept as the
   * regression tests for the bounds check.
   */
  function test_RejectsAKeyRunningPastTheEndOfTheAttributes() public {
    // The prefix ends exactly at the final byte, so a 32-byte key lies ENTIRELY beyond the array.
    bytes memory sa = _attributes(64, 64);

    vm.expectRevert(bytes('X509: key runs past the signed attributes'));
    x509.extractPublicKey(sa, PREFIX, 64, 32);
  }

  /// The same read with an absurd length - a 512-byte key out of 64 bytes of attributes.
  function test_RejectsAKeyLongerThanTheAttributes() public {
    bytes memory sa = _attributes(64, 8);

    vm.expectRevert(bytes('X509: key runs past the signed attributes'));
    x509.extractPublicKey(sa, PREFIX, 8, 512);
  }

  /// The boundary itself must still be ACCEPTED - a key ending exactly at the final byte is normal.
  function test_AcceptsAKeyEndingExactlyAtTheLastByte() public view {
    bytes memory sa = _attributes(64, 32);
    bytes memory key = x509.extractPublicKey(sa, PREFIX, 32, 32);
    assertEq(key.length, 32, 'a key ending flush with the attributes must be accepted');
  }
}
