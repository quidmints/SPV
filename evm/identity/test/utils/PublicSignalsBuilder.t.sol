// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PublicSignalsBuilder} from '../../contracts/sdk/lib/PublicSignalsBuilder.sol';

/*
 * PublicSignalsBuilder had no tests, and it is the highest-risk kind of code in the repo: 23 public
 * signals written by HAND-COMPUTED ASSEMBLY OFFSETS (`mstore(add(ptr, 544), x)`), each with the
 * arithmetic spelled out in a comment. The array it produces is fed straight to a verifier.
 *
 * A wrong offset does not revert. It puts a value in the wrong slot AND silently clobbers whichever
 * signal really lives there, so the proof simply fails to verify - or, worse, verifies against
 * signals nobody intended. Nothing else in the codebase would notice.
 *
 * So this pins every index independently: each setter gets a unique sentinel, and the whole array
 * is read back at once. Testing one field at a time would miss the clobber - that is the half that
 * matters, since a collision needs TWO fields to be observed together.
 */
contract PublicSignalsBuilderTest is Test {
  uint256 internal constant SELECTOR = 0x1111;
  uint256 internal constant NULLIFIER = 0x2222;

  function _built() internal view returns (uint256[] memory) {
    uint256 p = PublicSignalsBuilder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);

    PublicSignalsBuilder.withName(p, 0xA1);
    PublicSignalsBuilder.withNameResidual(p, 0xA2);
    PublicSignalsBuilder.withNationality(p, 0xA3);
    PublicSignalsBuilder.withCitizenship(p, 0xA4);
    PublicSignalsBuilder.withSex(p, 0xA5);
    PublicSignalsBuilder.withEventIdAndData(p, 0xA6, 0xA7);
    PublicSignalsBuilder.withTimestampLowerboundAndUpperbound(p, 0xA8, 0xA9);
    PublicSignalsBuilder.withIdentityCounterLowerbound(p, 0xAA, 0xAB);
    PublicSignalsBuilder.withBirthDateLowerboundAndUpperbound(p, 0xAC, 0xAD);
    PublicSignalsBuilder.withExpirationDateLowerboundAndUpperbound(p, 0xAE, 0xAF);
    PublicSignalsBuilder.withCitizenshipMask(p, 0xB0);

    return PublicSignalsBuilder.buildAsUintArray(p);
  }

  /// @notice Every signal lands at the index its own comment claims. The sentinels are distinct, so
  /// a swapped pair of offsets shows up as two failures rather than none.
  function test_everySignalLandsAtItsDocumentedIndex() public view {
    uint256[] memory s = _built();

    assertEq(s.length, PublicSignalsBuilder.PROOF_SIGNALS_COUNT, 'array length');
    assertEq(s[0], NULLIFIER, 'index 0 nullifier');
    assertEq(s[3], 0xA1, 'index 3 name');
    assertEq(s[4], 0xA2, 'index 4 nameResidual');
    assertEq(s[5], 0xA3, 'index 5 nationality');
    assertEq(s[6], 0xA4, 'index 6 citizenship');
    assertEq(s[7], 0xA5, 'index 7 sex');
    assertEq(s[9], 0xA6, 'index 9 eventId');
    assertEq(s[10], 0xA7, 'index 10 eventData');
    assertEq(s[12], SELECTOR, 'index 12 selector');
    assertEq(s[14], 0xA8, 'index 14 timestampLowerbound');
    assertEq(s[15], 0xA9, 'index 15 timestampUpperbound');
    assertEq(s[16], 0xAA, 'index 16 identityCounterLowerbound');
    assertEq(s[17], 0xAB, 'index 17 identityCounterUpperbound');
    assertEq(s[18], 0xAC, 'index 18 birthDateLowerbound');
    assertEq(s[19], 0xAD, 'index 19 birthDateUpperbound');
    assertEq(s[20], 0xAE, 'index 20 expirationDateLowerbound');
    assertEq(s[21], 0xAF, 'index 21 expirationDateUpperbound');
    assertEq(s[22], 0xB0, 'index 22 citizenshipMask');
  }

  /// @notice No setter may clobber another. Every sentinel is distinct, so if any two offsets
  /// collide one of the values is simply gone - which a per-field test could never see.
  function test_noSetterClobbersAnother() public view {
    uint256[] memory s = _built();

    uint256[18] memory expected = [
      NULLIFIER, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, SELECTOR,
      0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0
    ];
    for (uint256 i = 0; i < expected.length; i++) {
      bool found = false;
      for (uint256 j = 0; j < s.length; j++) {
        if (s[j] == expected[i]) {
          found = true;
          break;
        }
      }
      assertTrue(found, 'a written signal is missing - two offsets collided');
    }
  }

  /// @notice The constructor pre-seeds the date signals with ZERO_DATE. A caller that never sets
  /// them must still produce a well-formed array rather than raw zeros, which the circuit's range
  /// checks would read as a date of 0000-00-00.
  function test_datesAreSeededNotLeftZero() public view {
    uint256 p = PublicSignalsBuilder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);
    uint256[] memory s = PublicSignalsBuilder.buildAsUintArray(p);

    assertTrue(s[13] != 0, 'currentDate not seeded');
    assertTrue(s[18] != 0, 'birthDateLowerbound not seeded');
    assertTrue(s[19] != 0, 'birthDateUpperbound not seeded');
    assertTrue(s[20] != 0, 'expirationDateLowerbound not seeded');
    assertTrue(s[21] != 0, 'expirationDateUpperbound not seeded');
  }

  /// @notice buildAsUintArray and buildAsBytesArray are the SAME memory reinterpreted - they must
  /// agree, or a caller picking the wrong one gets silently different signals.
  function test_uintAndBytesViewsAgree() public view {
    uint256 p = PublicSignalsBuilder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);
    PublicSignalsBuilder.withName(p, 0xDEAD);

    uint256[] memory u = PublicSignalsBuilder.buildAsUintArray(p);
    bytes32[] memory b = PublicSignalsBuilder.buildAsBytesArray(p);

    assertEq(u.length, b.length, 'lengths differ');
    for (uint256 i = 0; i < u.length; i++) {
      assertEq(bytes32(u[i]), b[i], 'views disagree');
    }
  }
}
