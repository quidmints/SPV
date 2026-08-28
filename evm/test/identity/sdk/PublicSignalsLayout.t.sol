// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PublicSignalsBuilder} from '../../../src/identity/sdk/lib/PublicSignalsBuilder.sol';

/*
 * THE SLOT MAP BETWEEN THE BUILDER AND THE CIRCUIT (sec. 2.18af).
 *
 * `PublicSignalsBuilder` assembles the 23 public signals a `query_identity` proof is verified
 * against. **Their ORDER is a contract with the circuit and nothing enforced it.** A field written
 * one slot out verifies happily against the wrong claim - a proof of someone's nationality checked
 * as though it were their sex - and no test in the repo would notice, because the existing
 * "equivalence" tests compare the library against a reference in the SAME FILE. That proves
 * internal consistency, not agreement with the circuit (the vacuity of sec. 2.18i).
 *
 * THE REFERENCE HERE IS THE CIRCUIT SOURCE, which is the only thing that cannot drift with this
 * library. `query_identity/src/main.nr` returns, in order:
 *
 *    0 nullifier            8 documentNumber        16 identityCounterLowerbound
 *    1 birthDate            9 eventId               17 identityCounterUpperbound
 *    2 expirationDate      10 eventData             18 birthDateLowerbound
 *    3 name (surname)      11 idStateRoot           19 birthDateUpperbound
 *    4 nameResidual        12 selector              20 expirationDateLowerbound
 *    5 nationality         13 currentDate           21 expirationDateUpperbound
 *    6 citizenship         14 timestampLowerbound   22 citizenshipMask
 *    7 sex                 15 timestampUpperbound
 *
 * Each assertion below writes ONE distinctive value and checks it lands in the slot the circuit
 * reads it from. Needs no proof, no phone and no document - which is why it should have existed
 * long before any of those.
 */
contract PublicSignalsLayoutTest is Test {
    uint256 internal constant SLOT_NULLIFIER = 0;
    uint256 internal constant SLOT_NAME = 3;
    uint256 internal constant SLOT_NAME_RESIDUAL = 4;
    uint256 internal constant SLOT_NATIONALITY = 5;
    uint256 internal constant SLOT_CITIZENSHIP = 6;
    uint256 internal constant SLOT_SEX = 7;
    uint256 internal constant SLOT_EVENT_ID = 9;
    uint256 internal constant SLOT_EVENT_DATA = 10;
    uint256 internal constant SLOT_SELECTOR = 12;
    uint256 internal constant SLOT_CURRENT_DATE = 13;
    uint256 internal constant SLOT_TIMESTAMP_LOWER = 14;
    uint256 internal constant SLOT_TIMESTAMP_UPPER = 15;
    uint256 internal constant SLOT_COUNTER_LOWER = 16;
    uint256 internal constant SLOT_COUNTER_UPPER = 17;
    uint256 internal constant SLOT_BIRTH_LOWER = 18;
    uint256 internal constant SLOT_BIRTH_UPPER = 19;
    uint256 internal constant SLOT_EXPIRY_LOWER = 20;
    uint256 internal constant SLOT_EXPIRY_UPPER = 21;
    uint256 internal constant SLOT_CITIZENSHIP_MASK = 22;

    function _signals(uint256 ptr_) internal pure returns (uint256[] memory out_) {
        assembly {
            out_ := ptr_
        }
    }

    function test_TheArrayIsExactlyTwentyThreeSignals() public pure {
        uint256 p_ = PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);
        assertEq(_signals(p_).length, 23, 'the circuit returns 23 public outputs');
        assertEq(PublicSignalsBuilder.PROOF_SIGNALS_COUNT, 23);
    }

    function test_NullifierAndSelectorLandWhereTheCircuitReadsThem() public pure {
        uint256 p_ = PublicSignalsBuilder.newPublicSignalsBuilder(0xABCDE, 0x1111);

        assertEq(_signals(p_)[SLOT_NULLIFIER], 0x1111, 'nullifier is not slot 0');
        assertEq(_signals(p_)[SLOT_SELECTOR], 0xABCDE, 'selector is not slot 12');
    }

    function test_TheIdentityFieldsLandInSlotsThreeToSeven() public pure {
        uint256 p_ = PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);

        PublicSignalsBuilder.withName(p_, 0xAA11);
        PublicSignalsBuilder.withNameResidual(p_, 0xBB22);
        PublicSignalsBuilder.withNationality(p_, 0xCC33);
        PublicSignalsBuilder.withCitizenship(p_, 0xDD44);
        PublicSignalsBuilder.withSex(p_, 0xEE55);

        uint256[] memory s_ = _signals(p_);
        assertEq(s_[SLOT_NAME], 0xAA11, 'surname is not slot 3');
        assertEq(s_[SLOT_NAME_RESIDUAL], 0xBB22, 'given name is not slot 4');
        assertEq(s_[SLOT_NATIONALITY], 0xCC33, 'nationality is not slot 5');
        assertEq(s_[SLOT_CITIZENSHIP], 0xDD44, 'citizenship is not slot 6');
        assertEq(s_[SLOT_SEX], 0xEE55, 'sex is not slot 7');
    }

    function test_TheEventFieldsLandInSlotsNineAndTen() public pure {
        uint256 p_ = PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);
        PublicSignalsBuilder.withEventIdAndData(p_, 0x9999, 0xAAAA);

        assertEq(_signals(p_)[SLOT_EVENT_ID], 0x9999, 'eventId is not slot 9');
        assertEq(_signals(p_)[SLOT_EVENT_DATA], 0xAAAA, 'eventData is not slot 10');
    }

    /*
     * THE BOUND PAIRS ARE WHERE AN OFF-BY-ONE WOULD BE WORST, and hardest to see: every one of them
     * is a (lower, upper) pair of the same shape, so a pair written one slot out still looks like a
     * plausible range - it would simply constrain the WRONG attribute. Age checked as a timestamp,
     * expiry checked as a birth date.
     */
    function test_EveryBoundPairLandsOnItsOwnAttribute() public pure {
        uint256 p_ = PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);

        PublicSignalsBuilder.withTimestampLowerboundAndUpperbound(p_, 0x1001, 0x1002);
        PublicSignalsBuilder.withIdentityCounterLowerbound(p_, 0x2001, 0x2002);
        PublicSignalsBuilder.withBirthDateLowerboundAndUpperbound(p_, 0x3001, 0x3002);
        PublicSignalsBuilder.withExpirationDateLowerboundAndUpperbound(p_, 0x4001, 0x4002);
        PublicSignalsBuilder.withCitizenshipMask(p_, 0x5555);

        uint256[] memory s_ = _signals(p_);
        assertEq(s_[SLOT_TIMESTAMP_LOWER], 0x1001, 'timestamp lower is not slot 14');
        assertEq(s_[SLOT_TIMESTAMP_UPPER], 0x1002, 'timestamp upper is not slot 15');
        assertEq(s_[SLOT_COUNTER_LOWER], 0x2001, 'counter lower is not slot 16');
        assertEq(s_[SLOT_COUNTER_UPPER], 0x2002, 'counter upper is not slot 17');
        assertEq(s_[SLOT_BIRTH_LOWER], 0x3001, 'birth lower is not slot 18');
        assertEq(s_[SLOT_BIRTH_UPPER], 0x3002, 'birth upper is not slot 19');
        assertEq(s_[SLOT_EXPIRY_LOWER], 0x4001, 'expiry lower is not slot 20');
        assertEq(s_[SLOT_EXPIRY_UPPER], 0x4002, 'expiry upper is not slot 21');
        assertEq(s_[SLOT_CITIZENSHIP_MASK], 0x5555, 'citizenship mask is not slot 22');
    }

    /// A fresh builder must default the date-shaped slots to ZERO_DATE, not 0 - the circuit reads
    /// them as passport timestamps, and a raw zero is a different claim from "unconstrained".
    function test_UnsetDateBoundsDefaultToZeroDate() public pure {
        uint256[] memory s_ = _signals(PublicSignalsBuilder.newPublicSignalsBuilder(0, 0));
        uint256 z_ = PublicSignalsBuilder.ZERO_DATE;

        assertEq(s_[SLOT_CURRENT_DATE], z_, 'currentDate should default to ZERO_DATE');
        assertEq(s_[SLOT_BIRTH_LOWER], z_, 'birth lower should default to ZERO_DATE');
        assertEq(s_[SLOT_BIRTH_UPPER], z_, 'birth upper should default to ZERO_DATE');
        assertEq(s_[SLOT_EXPIRY_LOWER], z_, 'expiry lower should default to ZERO_DATE');
        assertEq(s_[SLOT_EXPIRY_UPPER], z_, 'expiry upper should default to ZERO_DATE');
    }
}
