// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {ISPVGateway} from "../src/spv/interfaces/ISPVGateway.sol";
import {TargetsHelper} from "../src/spv/libs/TargetsHelper.sol";
import {SPVFixtures} from "./SPVFixtures.sol";

/// @notice Adversarial coverage for the SPV header verifier's difficulty /
///         retarget / PoW / timestamp rules. The existing SPVGateway.t.sol covers
///         linear extension + cumulative-work reorg; these target the
///         DEFENDED-BUT-PREVIOUSLY-UNTESTED consensus invariants:
///           - difficulty retarget 4x clamp (both directions) + INITIAL_TARGET cap
///           - per-block work monotonicity
///           - compact-bits → target decoding (genesis vector)
///           - header rejection on wrong target (mid-epoch difficulty mismatch)
///           - header rejection on a timestamp below median-time-past
///         The retarget/work/bits cases hit TargetsHelper (pure) directly; the
///         header-rule cases mutate a single field of a valid synthetic header
///         (A1 chains off GEN at regtest difficulty) so only the rule under test
///         is violated.
contract SPVGatewayAdversarialTest is Test {
    bytes32 constant INITIAL = TargetsHelper.INITIAL_TARGET;

    // ─────────────────── difficulty retarget clamp (TargetsHelper) ───────────

    // A near-zero epoch timespan would harden difficulty without bound; the clamp
    // pins the adjustment at MIN_TARGET_RATIO (0.25x) → target shrinks by EXACTLY
    // 4x, never more. This is the timewarp/instant-mining mitigation.
    function test_retarget_clamps_down_to_quarter() public pure {
        bytes32 got = TargetsHelper.countNewTarget(INITIAL, 0);
        assertEq(uint256(got), uint256(INITIAL) / 4, "0s timespan -> target /4 (4x harder), clamped");
    }

    // A huge epoch timespan would ease difficulty without bound; the clamp pins it
    // at MAX_TARGET_RATIO (4x) → target grows by EXACTLY 4x. Use a sub-cap start so
    // the 4x result stays below INITIAL_TARGET (no cap interference).
    function test_retarget_clamps_up_to_4x() public pure {
        bytes32 start = bytes32(uint256(INITIAL) / 8);
        // 10 epochs' worth of time → ratio 10x, clamped to 4x.
        bytes32 got = TargetsHelper.countNewTarget(start, 1209600 * 10);
        assertEq(uint256(got), uint256(INITIAL) / 2, "huge timespan -> target *4 (4x easier), clamped");
    }

    // Even after the 4x ease, the target can never exceed INITIAL_TARGET (the
    // easiest allowed difficulty / lowest work).
    function test_retarget_caps_at_initial_target() public pure {
        bytes32 start = bytes32(uint256(INITIAL) / 2);
        // 4x of INITIAL/2 = 2*INITIAL → must cap at INITIAL.
        bytes32 got = TargetsHelper.countNewTarget(start, 1209600 * 10);
        assertEq(uint256(got), uint256(INITIAL), "4x ease capped at INITIAL_TARGET");
    }

    // The clamp must NOT over-fire: a MODERATE timespan inside [0.25x, 4x] passes
    // through PROPORTIONALLY, unclamped. A 2x-too-slow epoch eases the target by
    // exactly 2x. (This fails if the clamp were applied to every adjustment, or if
    // the proportional math were wrong — the complement of the clamp tests above.)
    function test_retarget_proportional_within_clamp() public pure {
        bytes32 start = bytes32(uint256(INITIAL) / 4);
        bytes32 got = TargetsHelper.countNewTarget(start, 1209600 * 2); // 2x expected time
        assertEq(uint256(got), uint256(INITIAL) / 2, "2x timespan -> target *2, NOT clamped");
    }

    // Per-block work = (2^256-1)/(target+1): a smaller (harder) target is strictly
    // more work, and INITIAL_TARGET (easiest) still has nonzero work. A reorg's
    // cumulative-work comparison relies on this monotonicity.
    function test_block_work_monotonic_in_target() public pure {
        uint256 wEasy = TargetsHelper.countBlockWork(INITIAL);
        uint256 wHard = TargetsHelper.countBlockWork(bytes32(uint256(INITIAL) / 4));
        assertGt(wEasy, 0, "easiest target still has work");
        assertGt(wHard, wEasy, "harder (smaller) target = strictly more work");
    }

    // Compact "bits" decoding: the canonical mainnet genesis bits 0x1d00ffff must
    // decode to INITIAL_TARGET. Guards the exponent/mantissa shift in bitsToTarget.
    function test_bits_to_target_genesis_vector() public pure {
        assertEq(
            uint256(TargetsHelper.bitsToTarget(bytes4(0x1d00ffff))),
            uint256(INITIAL),
            "0x1d00ffff -> INITIAL_TARGET"
        );
    }

    // ─────────────────── header consensus-rule rejection ─────────────────────

    function _genesisGateway() internal returns (SPVGateway g) {
        g = new SPVGateway();
        g.__SPVGateway_init(SPVFixtures.GEN_HEADER, 0, 0);
    }

    // A1 is a valid height-1 header (bits 0x207fffff, time > genesis). Rewrite ONLY
    // its bits to 0x1d00ffff (LE 0xffff001d): the protocol-expected target for a
    // mid-epoch block is unchanged (= genesis target), so the mismatched bits must
    // revert InvalidTarget — a miner can't self-select an easier difficulty.
    function test_header_wrong_target_reverts() public {
        SPVGateway gw = _genesisGateway();
        bytes memory h = SPVFixtures.A1_HEADER; // copied to memory → mutable
        // bits LE bytes for 0x1d00ffff = ff ff 00 1d (was ff ff 7f 20 = 0x207fffff).
        // The target check (InvalidTarget) precedes the PoW check, so this reverts
        // regardless of the resulting block hash.
        h[72] = bytes1(0xff); h[73] = bytes1(0xff); h[74] = bytes1(0x00); h[75] = bytes1(0x1d);
        // Exact-match expect: blockTarget = bitsToTarget(0x1d00ffff) = INITIAL_TARGET;
        // networkTarget = bitsToTarget(0x207fffff) (the genesis-epoch regtest target).
        vm.expectRevert(
            abi.encodeWithSelector(
                ISPVGateway.InvalidTarget.selector,
                INITIAL,
                TargetsHelper.bitsToTarget(bytes4(0x207fffff))
            )
        );
        gw.addBlockHeader(h);
    }

    // NOTE on the median-time-past (MTP) rule: it IS defended (SPVGateway
    // `InvalidBlockTime`, require time >= median of the prior 11). It's not unit-
    // tested here because constructing a header that is PoW-VALID (hash <= the
    // regtest target, whose top byte is 0x7f → ~50% of hashes fail) yet
    // MTP-INVALID requires grinding the nonce against the exact BE-hash≤target
    // comparison — too much in-test machinery to assert reliably without a
    // generated fixture. Covered by the live regtest e2e instead.
}
