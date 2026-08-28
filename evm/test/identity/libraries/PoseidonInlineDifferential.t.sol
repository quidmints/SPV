// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {PoseidonT2} from 'poseidon-solidity/PoseidonT2.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {PoseidonT4} from 'poseidon-solidity/PoseidonT4.sol';
import {PoseidonT5} from 'poseidon-solidity/PoseidonT5.sol';
import {PoseidonT6} from 'poseidon-solidity/PoseidonT6.sol';
import {PoseidonT2Inline} from 'contracts/libraries/inline/PoseidonT2Inline.sol';
import {PoseidonT3Inline} from 'contracts/libraries/inline/PoseidonT3Inline.sol';
import {PoseidonT4Inline} from 'contracts/libraries/inline/PoseidonT4Inline.sol';
import {PoseidonT5Inline} from 'contracts/libraries/inline/PoseidonT5Inline.sol';
import {PoseidonT6Inline} from 'contracts/libraries/inline/PoseidonT6Inline.sol';

/*
 * EVERY TEST HERE ALLOCATES MEMORY FIRST. That is the whole point.
 *
 * The previous version of this suite called the inline libraries as the first allocation in a
 * trivial body, so the argument array landed at 0x80 by luck - satisfying, by accident, the hidden
 * precondition the upstream assembly has (it reads inputs from HARDCODED 0x80/0xa0/...). It passed
 * 8 tests and 512 fuzz runs and certified a library that broke 31 tests the moment a real caller
 * had memory allocated first.
 *
 * `_pad()` below forces the arrays away from 0x80. Any test that does not call it is not testing
 * the property that matters.
 */
contract PoseidonInlineDifferentialTest is Test {
  uint256 internal constant P =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  /// Allocate junk so the following arrays cannot sit at 0x80, and leave a recognisable pattern
  /// there so a failure to restore it is visible rather than silent.
  function _pad() internal pure returns (bytes memory junk) {
    junk = new bytes(320);
    for (uint256 i = 0; i < 320; ++i) junk[i] = bytes1(uint8(0xAB));
  }

  function _v() internal pure returns (uint256[8] memory v) {
    v = [uint256(0), 1, 2, P - 1, P - 2, 0x1234567890abcdef,
         12345678901234567890123456789012345678901234567890,
         uint256(keccak256('quid.poseidon.differential')) % P];
  }

  function test_T2_MatchesUpstream() public pure {
    bytes memory junk = _pad();
    uint256[8] memory v = _v();
    for (uint256 i = 0; i < 8; ++i) {
      assertEq(PoseidonT2Inline.hash([v[i]]), PoseidonT2.hash([v[i]]), 'T2');
    }
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  function test_T3_MatchesUpstream() public pure {
    bytes memory junk = _pad();
    uint256[8] memory v = _v();
    for (uint256 i = 0; i < 8; ++i) {
      uint256 a = v[i]; uint256 b = v[(i + 3) % 8];
      assertEq(PoseidonT3Inline.hash([a, b]), PoseidonT3.hash([a, b]), 'T3');
    }
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  function test_T4_MatchesUpstream() public pure {
    bytes memory junk = _pad();
    uint256[8] memory v = _v();
    for (uint256 i = 0; i < 8; ++i) {
      uint256 a = v[i]; uint256 b = v[(i + 3) % 8]; uint256 c = v[(i + 5) % 8];
      assertEq(PoseidonT4Inline.hash([a, b, c]), PoseidonT4.hash([a, b, c]), 'T4');
    }
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  function test_T5_MatchesUpstream() public pure {
    bytes memory junk = _pad();
    uint256[8] memory v = _v();
    for (uint256 i = 0; i < 8; ++i) {
      uint256 a = v[i]; uint256 b = v[(i + 3) % 8];
      uint256 c = v[(i + 5) % 8]; uint256 d = v[(i + 7) % 8];
      assertEq(PoseidonT5Inline.hash([a, b, c, d]), PoseidonT5.hash([a, b, c, d]), 'T5');
    }
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  function test_T6_MatchesUpstream() public pure {
    bytes memory junk = _pad();
    uint256[8] memory v = _v();
    for (uint256 i = 0; i < 8; ++i) {
      uint256 a = v[i]; uint256 b = v[(i + 3) % 8]; uint256 c = v[(i + 5) % 8];
      uint256 d = v[(i + 7) % 8]; uint256 e = v[(i + 1) % 8];
      assertEq(PoseidonT6Inline.hash([a, b, c, d, e]), PoseidonT6.hash([a, b, c, d, e]), 'T6');
    }
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  /// Nested: the inline hash must survive being called with ITS OWN result feeding more allocation,
  /// which is what an SMT path does.
  function test_ChainedFromAllocatingCaller() public pure {
    bytes memory junk = _pad();
    uint256 acc = 1;
    for (uint256 i = 0; i < 16; ++i) {
      bytes memory more = new bytes(64);
      more[0] = 0x01;
      // PREVIOUS accumulator, kept because the inline call overwrites `acc` on the next line - so the
      // upstream comparison must be made against the INPUT, not the output.
      //
      // ⚠️ THIS LINE ASSERTED NOTHING UNTIL 2026-08-09. It read
      //     assertEq(acc, PoseidonT3.hash([acc == 0 ? 0 : acc, i]) == acc ? acc : acc);
      // whose ternary yields `acc` on BOTH branches, reducing the whole statement to
      // `assertEq(acc, acc)` - the upstream hash was computed and thrown away. It could not fail
      // however badly `PoseidonT3Inline` behaved, and it also fed the POST-hash `acc`, so even the
      // comparison it appeared to make was against the wrong operand. TODO sec. 2.18fx.
      uint256 prev = acc;
      acc = PoseidonT3Inline.hash([acc, i]);
      assertEq(acc, PoseidonT3.hash([prev, i]), 'inline diverged from upstream at this step');
    }
    uint256 ref = 1;
    for (uint256 i = 0; i < 16; ++i) ref = PoseidonT3.hash([ref, i]);
    assertEq(acc, ref, 'chained inline hashing diverged from upstream');
    assertEq(uint8(junk[0]), 0xAB, 'caller memory was clobbered');
  }

  function testFuzz_T3(uint256 a, uint256 b) public pure {
    _pad();
    assertEq(PoseidonT3Inline.hash([a, b]), PoseidonT3.hash([a, b]));
  }

  function testFuzz_T6(uint256 a, uint256 b, uint256 c) public pure {
    _pad();
    assertEq(PoseidonT6Inline.hash([a, b, c, 7, 9]), PoseidonT6.hash([a, b, c, 7, 9]));
  }

  function test_GasSaving() public {
    bytes memory junk = _pad();
    uint256 g = gasleft(); PoseidonT3.hash([uint256(1), 2]); uint256 pub = g - gasleft();
    g = gasleft(); PoseidonT3Inline.hash([uint256(1), 2]); uint256 inl = g - gasleft();
    console.log('T3 public ', pub);
    console.log('T3 inline ', inl);
    assertLt(inl, pub, 'inlining is not cheaper');
    assertEq(uint8(junk[0]), 0xAB);
  }
}
