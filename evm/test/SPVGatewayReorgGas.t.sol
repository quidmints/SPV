// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {SPVFixtures} from "./SPVFixtures.sol";

/// @notice §AUDIT-REORG-DOS (§BITCOIN-ORDER item 9, the half `NEW-1` left open): price the
///         fork-switch walk-back in `SPVGateway._updateMainchainHead`, which rewrites
///         `blocksHeightToBlockHash` one height at a time from the new head back to the fork
///         point — O(depth) SLOAD+SSTORE inside the SINGLE transaction that submits the
///         switching block.
///
///         🔴 WHY THE ANSWER MATTERS MORE HERE THAN IN A TYPICAL RELAY: `DeployLib.sol:266`
///         does `new SPVGateway()` — NOT behind a proxy — and `BTCChannels.spv` is
///         `immutable`. There is no upgrade and no setter. If the switching transaction can
///         never fit in a block, the gateway's head is stuck for good and every SPV-proven
///         path in `BTCChannels` (swap-in settlement, swap-out delivery, force-close
///         recording) is stuck with it. The `Initializable` import reads like an upgradeable
///         contract and is not one in this deployment.
///
///         ⛔ THIS FILE MEASURES. It asserts only what it has measured, and deliberately does
///         not add a clamp: the failure mode is an out-of-gas REVERT, which is loud, and
///         standing rule 3 spends a guard on silence, not on noise. What was missing was the
///         number.
contract SPVGatewayReorgGas is Test {
    /// regtest bits 0x207fffff ⇒ target = 0x7fffff << 232. ~half of all nonces pass, so
    /// "mining" a synthetic header here costs ~2 hashes, not work.
    bytes4 constant BITS_LE = 0x207fffff; // wire order of 0x207fffff is ff ff 7f 20
    bytes32 constant REGTEST_TARGET =
        bytes32(uint256(0x7fffff) << 232);

    SPVGateway gw;

    /// Build + "mine" one synthetic regtest header on top of `prevBE`.
    /// Returns the 80-byte wire header and its BE (display-order) hash, which is the form
    /// `SPVGateway` stores and compares against the target.
    function _mine(bytes32 prevBE, bytes32 merkle, uint32 time)
        internal
        pure
        returns (bytes memory header, bytes32 hashBE)
    {
        bytes32 prevLE = _rev(prevBE);
        for (uint32 nonce; nonce < type(uint32).max; ++nonce) {
            header = abi.encodePacked(
                bytes4(0x01000000),          // version 1, LE
                prevLE,
                merkle,
                _u32le(time),
                bytes4(0xffff7f20),          // bits 0x207fffff, LE
                _u32le(nonce)
            );
            hashBE = _rev(sha256(abi.encodePacked(sha256(header))));
            if (hashBE <= REGTEST_TARGET) return (header, hashBE);
        }
        revert("unmineable");
    }

    function _u32le(uint32 v) internal pure returns (bytes4 o) {
        o = bytes4(
            uint32(v >> 24) | ((v >> 8) & 0xff00) | ((v << 8) & 0xff0000) | (v << 24)
        );
    }

    function _rev(bytes32 b) internal pure returns (bytes32 o) {
        for (uint i; i < 32; ++i) o |= bytes32(uint256(uint8(b[i])) << (8 * i));
    }

    /// Extend `from` by `n` synthetic blocks tagged with `tag` (so the two chains'
    /// merkle roots — and therefore their hashes — differ at every height).
    /// Timestamps ascend, which satisfies median-time-past for both chains independently.
    function _extend(bytes32 from, uint n, bytes1 tag, uint32 t0)
        internal
        returns (bytes32 tip)
    {
        tip = from;
        for (uint i; i < n; ++i) {
            bytes32 merkle;
            for (uint j; j < 32; ++j) merkle |= bytes32(uint256(uint8(tag)) << (8 * j));
            merkle ^= bytes32(i);
            (bytes memory h, bytes32 hashBE) = _mine(tip, merkle, t0 + uint32(i) * 600);
            gw.addBlockHeader(h);
            tip = hashBE;
        }
    }

    /// The measurement. Chain A and chain B both fork at genesis and run to `depth`; A is
    /// submitted first and holds the head (equal work ties, and the rule is strictly-greater).
    /// Then ONE more B block makes B heavier, and that single call must walk `depth` heights
    /// back rewriting the index. Returns the gas that one call cost.
    function _switchGasAtDepth(uint depth) internal returns (uint gasUsed) {
        gw = new SPVGateway();
        gw.__SPVGateway_init(SPVFixtures.GEN_HEADER, 0, 0);

        uint32 t0 = 0x6553f100;
        _extend(SPVFixtures.GEN_HASH_BE, depth, 0xa1, t0);
        bytes32 bTip = _extend(SPVFixtures.GEN_HASH_BE, depth, 0xb2, t0);
        assertEq(gw.getMainchainHeight(), depth, "PREMISE: chain A still holds the head");

        (bytes memory flip,) = _mine(bTip, bytes32(uint256(0xb2b2)), t0 + uint32(depth) * 600);
        uint before = gasleft();
        gw.addBlockHeader(flip);
        gasUsed = before - gasleft();

        assertEq(gw.getMainchainHeight(), depth + 1, "the heavier fork took the head");
    }

    /// 🔑 THE SHAPE IS THE FINDING: cost per unit of reorg depth, measured at three depths
    /// so the slope is a measurement and not an inference from one point.
    function test_reorgDepth_costsLinearGas_andTheSlopeIsTheBrickBound() public {
        uint g8  = _switchGasAtDepth(8);
        uint g32 = _switchGasAtDepth(32);
        uint g64 = _switchGasAtDepth(64);

        emit log_named_uint("switch gas @ depth  8", g8);
        emit log_named_uint("switch gas @ depth 32", g32);
        emit log_named_uint("switch gas @ depth 64", g64);

        // Slope between the two widest points, in gas per extra block of depth.
        uint perBlock = (g64 - g32) / 32;
        emit log_named_uint("gas per block of depth", perBlock);

        assertGt(g64, g32, "cost rises with depth - the walk is O(depth), not O(1)");
        assertGt(g32, g8,  "and it rises at the shallow end too");

        // At a 30M block gas limit, this is the reorg depth beyond which the switching
        // transaction cannot be mined at all - and, because the gateway is not proxied and
        // BTCChannels.spv is immutable, that is permanent.
        uint brickDepth = 30_000_000 / perBlock;
        emit log_named_uint("brick depth @ 30M gas", brickDepth);

        // 🔑 THE BOUND, PRICED FROM THE MEASUREMENT ABOVE RATHER THAN FROM AN ADJECTIVE.
        // Measured 2026-09-12: 7,471 gas per block of depth ⇒ a brick depth of 4,015
        // Bitcoin blocks, about 28 days of chain. Flipping the head requires a fork with
        // strictly MORE cumulative work, so reaching that depth means out-working the whole
        // network for those 28 days -- the walk is not a cheap lever for anyone.
        //
        // The assertion is set at 2,000 (~14 days), leaving ~2x headroom over the measured
        // value, because the number that matters is REORG DEPTH and not gas. It fires on a
        // change that materially raises the per-iteration cost: one extra cold SSTORE in the
        // loop is +5,000, which alone takes the depth to 2,406 and a second one below the
        // floor. That is the drift this guards -- NOT the adversary, who cannot afford
        // either number.
        assertGt(
            brickDepth, 2_000,
            "the fork-switch walk must stay affordable past a ~2-week-deep reorg; if this "
            "fires, something made _updateMainchainHead's per-height loop more expensive "
            "and the gateway is NOT upgradeable (deployed bare, BTCChannels.spv immutable)"
        );
    }
}
