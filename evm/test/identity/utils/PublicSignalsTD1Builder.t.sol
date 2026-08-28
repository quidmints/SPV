// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PublicSignalsTD1Builder} from '../../../src/identity/sdk/lib/PublicSignalsTD1Builder.sol';
import {PublicSignalsBuilder} from '../../../src/identity/sdk/lib/PublicSignalsBuilder.sol';

/*
 * The TD1 (ID card) builder, same hand-computed-assembly-offset risk as the TD3 one.
 *
 * IT IS NOT THE TD3 BUILDER WITH AN EXTRA FIELD. 24 signals rather than 23, and the layout genuinely
 * differs - TD1 carries birthDate/expirationDate/documentNumberHash/personalNumberHash/documentType
 * as signals in their own right, which shifts nearly everything after index 3. `withNationality` is
 * at offset 160 here and 192 there; `withSelector` at 448 here and 416 there.
 *
 * That matters because the two are easy to confuse, and confusing them is silent: every setter
 * still exists, every call still compiles, and the array produced is plausible but wrong. It is the
 * same TD1/TD3 trap that made the SDK's MRZ parser read passports at ID-card offsets.
 */
contract PublicSignalsTD1BuilderTest is Test {
  uint256 internal constant SELECTOR = 0x1111;
  uint256 internal constant NULLIFIER = 0x2222;

  function _built() internal view returns (uint256[] memory) {
    uint256 p = PublicSignalsTD1Builder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);

    PublicSignalsTD1Builder.withBirthDate(p, 0xB1);
    PublicSignalsTD1Builder.withExpirationDate(p, 0xB2);
    PublicSignalsTD1Builder.withName(p, 0xB3);
    PublicSignalsTD1Builder.withNationality(p, 0xB4);
    PublicSignalsTD1Builder.withCitizenship(p, 0xB5);
    PublicSignalsTD1Builder.withSex(p, 0xB6);
    PublicSignalsTD1Builder.withDocumentNumberHash(p, 0xB7);
    PublicSignalsTD1Builder.withPersonalNumberHash(p, 0xB8);
    PublicSignalsTD1Builder.withDocumentType(p, 0xB9);
    PublicSignalsTD1Builder.withEventIdAndData(p, 0xBA, 0xBB);
    PublicSignalsTD1Builder.withTimestampLowerboundAndUpperbound(p, 0xBC, 0xBD);
    PublicSignalsTD1Builder.withIdentityCounterLowerbound(p, 0xBE, 0xBF);
    PublicSignalsTD1Builder.withBirthDateLowerboundAndUpperbound(p, 0xC0, 0xC1);
    PublicSignalsTD1Builder.withExpirationDateLowerboundAndUpperbound(p, 0xC2, 0xC3);
    PublicSignalsTD1Builder.withCitizenshipMask(p, 0xC4);

    return PublicSignalsTD1Builder.buildAsUintArray(p);
  }

  function test_everySignalLandsAtItsDocumentedIndex() public view {
    uint256[] memory s = _built();

    assertEq(s.length, PublicSignalsTD1Builder.PROOF_SIGNALS_COUNT, 'array length');
    assertEq(s.length, 24, 'TD1 has 24 signals, not 23');

    assertEq(s[0], NULLIFIER, 'index 0 nullifier');
    assertEq(s[1], 0xB1, 'index 1 birthDate');
    assertEq(s[2], 0xB2, 'index 2 expirationDate');
    assertEq(s[3], 0xB3, 'index 3 name');
    assertEq(s[4], 0xB4, 'index 4 nationality');
    assertEq(s[5], 0xB5, 'index 5 citizenship');
    assertEq(s[6], 0xB6, 'index 6 sex');
    assertEq(s[7], 0xB7, 'index 7 documentNumberHash');
    assertEq(s[8], 0xB8, 'index 8 personalNumberHash');
    assertEq(s[9], 0xB9, 'index 9 documentType');
    assertEq(s[10], 0xBA, 'index 10 eventId');
    assertEq(s[11], 0xBB, 'index 11 eventData');
    assertEq(s[13], SELECTOR, 'index 13 selector');
    assertEq(s[15], 0xBC, 'index 15 timestampLowerbound');
    assertEq(s[16], 0xBD, 'index 16 timestampUpperbound');
    assertEq(s[17], 0xBE, 'index 17 identityCounterLowerbound');
    assertEq(s[18], 0xBF, 'index 18 identityCounterUpperbound');
    assertEq(s[19], 0xC0, 'index 19 birthDateLowerbound');
    assertEq(s[20], 0xC1, 'index 20 birthDateUpperbound');
    assertEq(s[21], 0xC2, 'index 21 expirationDateLowerbound');
    assertEq(s[22], 0xC3, 'index 22 expirationDateUpperbound');
    assertEq(s[23], 0xC4, 'index 23 citizenshipMask');
  }

  /// @notice No setter clobbers another - only visible when the whole array is read at once.
  function test_noSetterClobbersAnother() public view {
    uint256[] memory s = _built();
    uint256[22] memory expected = [
      NULLIFIER, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB,
      SELECTOR, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4
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

  /*
   * THE TWO BUILDERS MUST NOT AGREE. If TD1 and TD3 produced the same layout, using the wrong one
   * would be harmless and this whole distinction would be noise - but they do not, and a mix-up is
   * silent. Pinning the divergence stops a future "simplification" from merging them.
   */
  function test_td1AndTd3LayoutsGenuinelyDiffer() public view {
    assertTrue(
      PublicSignalsTD1Builder.PROOF_SIGNALS_COUNT != PublicSignalsBuilder.PROOF_SIGNALS_COUNT,
      'signal counts converged - the builders may have been merged'
    );

    uint256 td1 = PublicSignalsTD1Builder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);
    PublicSignalsTD1Builder.withNationality(td1, 0xFEED);
    uint256[] memory a = PublicSignalsTD1Builder.buildAsUintArray(td1);

    uint256 td3 = PublicSignalsBuilder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);
    PublicSignalsBuilder.withNationality(td3, 0xFEED);
    uint256[] memory b = PublicSignalsBuilder.buildAsUintArray(td3);

    // Same field, same value, DIFFERENT slot - which is exactly why the builders are not
    // interchangeable and why picking the wrong one cannot be caught by the compiler.
    assertEq(a[4], 0xFEED, 'TD1 nationality is index 4');
    assertEq(b[5], 0xFEED, 'TD3 nationality is index 5');
  }

  function test_datesAreSeededNotLeftZero() public view {
    uint256 p = PublicSignalsTD1Builder.newPublicSignalsBuilder(SELECTOR, NULLIFIER);
    uint256[] memory s = PublicSignalsTD1Builder.buildAsUintArray(p);

    assertTrue(s[14] != 0, 'currentDate not seeded');
    assertTrue(s[19] != 0, 'birthDateLowerbound not seeded');
    assertTrue(s[20] != 0, 'birthDateUpperbound not seeded');
    assertTrue(s[21] != 0, 'expirationDateLowerbound not seeded');
    assertTrue(s[22] != 0, 'expirationDateUpperbound not seeded');
  }
}
