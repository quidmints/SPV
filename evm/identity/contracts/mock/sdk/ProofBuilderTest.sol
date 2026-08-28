// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {PublicSignalsBuilder} from "../../sdk/lib/PublicSignalsBuilder.sol";
import {AQueryProofExecutor} from "../../sdk/AQueryProofExecutor.sol";
import {Date2Time} from "../../utils/Date2Time.sol";

/// Minimal registration-SMT stub so the equivalence tests can exercise withIdStateRoot
/// (which validates the root against the registration SMT) without a full SMT deployment.
contract MockRegistrationSMT {
    function isRootValid(bytes32) external pure returns (bool) {
        return true;
    }
}

contract ProofBuilderTest is AQueryProofExecutor, Test {
    uint256 private constant PROOF_SIGNALS_COUNT = PublicSignalsBuilder.PROOF_SIGNALS_COUNT;
    uint256 private constant ZERO_DATE = PublicSignalsBuilder.ZERO_DATE;

    AQueryProofExecutor.AExecutorStorage internal mockBuilderStorage;

    error Mismatch(uint256 iteration, uint256 original, uint256 lib);

    MockRegistrationSMT internal registrationSMTMock;

    function setUp() public {
        registrationSMTMock = new MockRegistrationSMT();
        this.init(address(registrationSMTMock));
    }

    function init(address registrationSMT_) external initializer {
        __AQueryProofExecutor_init(registrationSMT_, address(0));
    }

    function _buildPublicSignals(
        bytes32,
        uint256,
        bytes memory
    ) internal pure override returns (uint256) {
        return 0;
    }

    function _buildPublicSignalsTD1(
        bytes32,
        uint256,
        bytes memory
    ) internal pure override returns (uint256) {
        return 0;
    }

    function _initializeArrays(
        uint256 selector,
        uint256 nullifier
    ) internal pure returns (uint256[] memory original, uint256 builder) {
        original = new uint256[](PROOF_SIGNALS_COUNT);
        original[0] = nullifier;
        original[12] = selector;
        original[13] = ZERO_DATE;
        original[18] = ZERO_DATE;
        original[19] = ZERO_DATE;
        original[20] = ZERO_DATE;
        original[21] = ZERO_DATE;

        builder = PublicSignalsBuilder.newPublicSignalsBuilder(selector, nullifier);
    }

    function _compareArrays(uint256[] memory original, uint256[] memory lib) internal pure {
        for (uint256 i = 0; i < PROOF_SIGNALS_COUNT; i++) {
            if (original[i] != lib[i]) {
                revert Mismatch(i, original[i], lib[i]);
            }
        }
    }

    function testEquivalencePart1_NewBuilder() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart2_Name() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 name_ = 3;
        uint256 nameResidual_ = 4;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[3] = name_;
        originalPubSignals[4] = nameResidual_;

        PublicSignalsBuilder.withName(builder, name_);
        PublicSignalsBuilder.withNameResidual(builder, nameResidual_);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart3_NationalityCitizenshipSex() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 nationality_ = 5;
        uint256 citizenship_ = 6;
        uint256 sex_ = 7;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[5] = nationality_;
        originalPubSignals[6] = citizenship_;
        originalPubSignals[7] = sex_;

        PublicSignalsBuilder.withNationality(builder, nationality_);
        PublicSignalsBuilder.withCitizenship(builder, citizenship_);
        PublicSignalsBuilder.withSex(builder, sex_);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart4_Event() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 eventId_ = 9;
        uint256 eventData_ = 10;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[9] = eventId_;
        originalPubSignals[10] = eventData_;

        PublicSignalsBuilder.withEventIdAndData(builder, eventId_, eventData_);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart5_IdStateRoot(bytes32 idStateRoot_) external view {
        uint256 nullifier = 1;
        uint256 selector = 2;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[11] = uint256(idStateRoot_);

        PublicSignalsBuilder.withIdStateRoot(builder, idStateRoot_);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart6_CurrentDate() external {
        uint256 nullifier = 1;
        uint256 selector = 2;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        // A valid encoded date (ASCII "yyMMdd"); warp block.timestamp onto its parsed value so the
        // builder's +-timeBound validity check passes. Unbounded fuzzing previously fed Date2Time
        // garbage that overflowed; the equivalence under test is independent of the date value.
        uint256 currentDate_ = 0x323430363330; // "240630"
        vm.warp(Date2Time.timestampFromDate(currentDate_));

        originalPubSignals[13] = currentDate_;

        PublicSignalsBuilder.withCurrentDate(builder, currentDate_, 1 days);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart7_TimestampBounds() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 timestampLowerbound_ = 14;
        uint256 timestampUpperbound_ = 15;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[14] = timestampLowerbound_;
        originalPubSignals[15] = timestampUpperbound_;

        PublicSignalsBuilder.withTimestampLowerboundAndUpperbound(
            builder,
            timestampLowerbound_,
            timestampUpperbound_
        );

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart8_IdentityCounterBounds() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 identityCounterLowerbound_ = 16;
        uint256 identityCounterUpperbound_ = 17;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[16] = identityCounterLowerbound_;
        originalPubSignals[17] = identityCounterUpperbound_;

        PublicSignalsBuilder.withIdentityCounterLowerbound(
            builder,
            identityCounterLowerbound_,
            identityCounterUpperbound_
        );

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart9_BirthDateBounds() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 birthDateLowerbound_ = 18;
        uint256 birthDateUpperbound_ = 19;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[18] = birthDateLowerbound_; // Overwrite ZERO_DATE
        originalPubSignals[19] = birthDateUpperbound_; // Overwrite ZERO_DATE

        PublicSignalsBuilder.withBirthDateLowerboundAndUpperbound(
            builder,
            birthDateLowerbound_,
            birthDateUpperbound_
        );

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart10_ExpirationDateBounds() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 expirationDateLowerbound_ = 20;
        uint256 expirationDateUpperbound_ = 21; // Test with a non-ZERO_DATE value

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[20] = expirationDateLowerbound_; // Overwrite ZERO_DATE
        originalPubSignals[21] = expirationDateUpperbound_; // Overwrite ZERO_DATE

        PublicSignalsBuilder.withExpirationDateLowerboundAndUpperbound(
            builder,
            expirationDateLowerbound_,
            expirationDateUpperbound_
        );

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }

    function testEquivalencePart11_CitizenshipMask() external pure {
        uint256 nullifier = 1;
        uint256 selector = 2;
        uint256 citizenshipMask_ = 22;

        (uint256[] memory originalPubSignals, uint256 builder) = _initializeArrays(
            selector,
            nullifier
        );

        originalPubSignals[22] = citizenshipMask_;

        PublicSignalsBuilder.withCitizenshipMask(builder, citizenshipMask_);

        uint256[] memory libPubSignals = PublicSignalsBuilder.buildAsUintArray(builder);
        _compareArrays(originalPubSignals, libPubSignals);
    }
}
