// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {SPVFixtures} from "./SPVFixtures.sol";

/// @title  §AUDIT-SPV-RETARGET — A CHECKPOINT THAT IS NOT AN EPOCH START MUST BE REFUSED AT INIT
///
/// @notice **THE BUG THIS PINS IS DELAYED BY UP TO 2016 BLOCKS, WHICH IS WHY THE EXISTING SUITE IS
///         BLIND TO IT.** `__SPVGateway_init` took any `blockHeight_`. `_retargetIfEpochBoundary`
///         fires at every `h % 2016 == 0` and `_getEpochPassedTime(h)` reads the header at
///         `h - 2016`. Init at an unaligned H and the first retarget above it needs a block BELOW
///         H — a height the gateway has never stored. `getBlockHash` returns zero, the epoch start
///         time reads 0, the recomputed target is garbage, and every header from there on is
///         rejected with `InvalidTarget`. `initializer` means there is no second chance: a routine
///         Bitcoin difficulty adjustment permanently bricks the gateway and the whole BTC path.
///
///         ⚠️ **EVERY EXISTING GATEWAY IN THE TREE IS ALIGNED BY ACCIDENT, NOT BY RULE.**
///         `SPVGateway.t.sol` inits at 0 and at signet 304416 (= 2016 × 151); `Alles`,
///         `OpenChannelE2E`, `BtcSelfManaged`, `SPVGatewayAdversarial` and `DriverE2E` all init at
///         regtest genesis, height 0. `0 % 2016 == 0`, so all of them pass with or without the
///         guard. **A green suite was never evidence here** — that is the entire reason this file
///         exists, and it is why the finding could survive in production configuration where the
///         checkpoint height comes from an operator's env var (`DeployL1_s.sol:328`).
///
///         ⛔ **NOT A MIRROR OF THE PRODUCTION CHECK, AND NOT A DUPLICATE OF THE BURIAL ONE.** It
///         calls the real `__SPVGateway_init` on a real `SPVGateway`, and it asserts the property
///         the retarget arithmetic needs (USABLE), which is independent of the property
///         `DeployLib:289` asserts (CANONICAL). A buried-but-unaligned checkpoint satisfies that
///         one and still bricks.
contract SPVGatewayInitAlignmentTest is Test {
    uint64 constant EPOCH = 2016;

    /// The offsets worth naming: one past the boundary, one before the next, and the deceptive
    /// "looks round" case. A height chosen by a human eye — 304400, say — is exactly the shape of
    /// mistake this refuses.
    function test_unalignedCheckpointHeightIsRefused() public {
        _expectRefused(SPVFixtures.SIGNET_INIT_HEIGHT + 1);            // just past a boundary
        _expectRefused(SPVFixtures.SIGNET_INIT_HEIGHT + EPOCH - 1);    // just short of the next
        _expectRefused(SPVFixtures.SIGNET_INIT_HEIGHT - 16);           // 304400 — "looks round"
    }

    /// A FRESH gateway per case: `initializer` is one-shot, so reusing one would make every case
    /// after the first pass on `InvalidInitialization` instead of on the rule under test.
    function _expectRefused(uint64 height) internal {
        SPVGateway g = new SPVGateway();
        vm.expectRevert(
            abi.encodeWithSelector(SPVGateway.UnalignedCheckpointHeight.selector, height));
        g.__SPVGateway_init(SPVFixtures.SIGNET_INIT_HEADER, height, 0);
    }

    /// The control, and it is load-bearing: a guard that refused EVERYTHING would also make the
    /// test above pass. This is the same call at the aligned height the signet fixture actually
    /// uses, and it must go through.
    function test_alignedCheckpointHeightIsAccepted() public {
        SPVGateway g = new SPVGateway();
        g.__SPVGateway_init(SPVFixtures.SIGNET_INIT_HEADER, SPVFixtures.SIGNET_INIT_HEIGHT, 0);
        assertEq(g.getMainchainHeight(), SPVFixtures.SIGNET_INIT_HEIGHT, "checkpoint is the head");
        assertEq(SPVFixtures.SIGNET_INIT_HEIGHT % EPOCH, 0, "fixture height must be an epoch start");
    }

    /// Height 0 is the regtest/synthetic case every other BTC fixture uses. Aligned, so it stays
    /// green — asserted here so that a future tightening of this guard cannot break the whole BTC
    /// suite silently.
    function test_genesisHeightZeroStillInitialises() public {
        SPVGateway g = new SPVGateway();
        g.__SPVGateway_init(SPVFixtures.GEN_HEADER, 0, 0);
        assertEq(g.getMainchainHeight(), 0, "genesis head");
    }
}
