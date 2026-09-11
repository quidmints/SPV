// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library TargetsHelper {

    uint32 public constant EXPECTED_TARGET_BLOCKS_TIME = 1209600;

    uint64 public constant DIFFICULTY_ADJUSTMENT_INTERVAL = 2016;

    bytes32 public constant INITIAL_TARGET =
        0x00000000ffff0000000000000000000000000000000000000000000000000000;

    uint256 public constant TARGET_FIXED_POINT_FACTOR = 10 ** 18;

    uint256 public constant MAX_TARGET_FACTOR = 4;

    uint256 public constant MAX_TARGET_RATIO = TARGET_FIXED_POINT_FACTOR * MAX_TARGET_FACTOR;

    uint256 public constant MIN_TARGET_RATIO = TARGET_FIXED_POINT_FACTOR / MAX_TARGET_FACTOR;

    function isTargetAdjustmentBlock(uint64 blockHeight_) internal pure returns (bool) {
        return getEpochBlockNumber(blockHeight_) == 0 && blockHeight_ > 0;
    }

    function getEpochBlockNumber(uint64 blockHeight_) internal pure returns (uint64) {
        return blockHeight_ % DIFFICULTY_ADJUSTMENT_INTERVAL;
    }

    function countNewRoundedTarget(
        bytes32 currentTarget_,
        uint32 actualPassedTime_
    ) internal pure returns (bytes32) {
        return roundTarget(countNewTarget(currentTarget_, actualPassedTime_));
    }

    function countNewTarget(
        bytes32 currentTarget_,
        uint32 actualPassedTime_
    ) internal pure returns (bytes32) {
        uint256 currentRatio = (actualPassedTime_ * TARGET_FIXED_POINT_FACTOR) /
            EXPECTED_TARGET_BLOCKS_TIME;

        currentRatio = Math.min(Math.max(currentRatio, MIN_TARGET_RATIO), MAX_TARGET_RATIO);

        bytes32 target_ = bytes32(
            Math.mulDiv(uint256(currentTarget_), currentRatio, TARGET_FIXED_POINT_FACTOR)
        );

        return target_ > INITIAL_TARGET ? INITIAL_TARGET : target_;
    }

    function countBlockWork(bytes32 target_) internal pure returns (uint256 blockWork_) {
        assembly {

            blockWork_ := div(not(blockWork_), add(target_, 0x1))
        }
    }

    function bitsToTarget(bytes4 bits_) internal pure returns (bytes32 target_) {
        assembly {
            let targetShift := mul(sub(0x20, byte(0, bits_)), 0x8)

            target_ := shr(targetShift, shl(0x8, bits_))
        }
    }

    function roundTarget(bytes32 currentTarget_) internal pure returns (bytes32 roundedTarget_) {
        assembly {
            let coefficientLength := 0x3
            let coefficientEndIndex := 0

            for {
                let i := 0
            } lt(i, 0x20) {
                i := add(i, 0x1)
            } {
                let currentByte := byte(i, currentTarget_)

                if gt(currentByte, 0) {
                    coefficientEndIndex := add(i, coefficientLength)

                    if gt(currentByte, 0x80) {
                        coefficientEndIndex := sub(coefficientEndIndex, 0x1)
                    }

                    break
                }
            }

            let keepBits := mul(sub(0x20, coefficientEndIndex), 8)
            let mask := not(sub(shl(keepBits, 1), 1))

            roundedTarget_ := and(currentTarget_, mask)
        }
    }
}
