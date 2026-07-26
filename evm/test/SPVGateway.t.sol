// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {SPVFixtures} from "./SPVFixtures.sol";

/// @notice SPVGateway end-to-end against REAL signet data (checkTxInclusion)
///         plus SYNTHETIC mined chains for reorg / competing-chain handling.
///         No fork — pure header/merkle math, fast.
contract SPVGatewayTest is Test {
    SPVGateway gw;

    // ── helper: deploy + init at the signet adjustment block 304416 ──
    function _signetGateway() internal returns (SPVGateway g) {
        g = new SPVGateway();
        g.__SPVGateway_init(
            SPVFixtures.SIGNET_INIT_HEADER,
            SPVFixtures.SIGNET_INIT_HEIGHT,
            0 // cumulativeWork irrelevant for a linear (no-fork) chain
        );
        bytes[] memory hs = SPVFixtures.signetHeaders();
        for (uint i = 0; i < hs.length; i++) g.addBlockHeader(hs[i]);
    }

    // ═══════════════════════════════════════════════════════════════
    //  REAL SIGNET DATA — checkTxInclusion
    // ═══════════════════════════════════════════════════════════════
    function test_signet_chain_extends() public {
        gw = _signetGateway();
        // init 304416 + 11 headers → head at 304427
        assertEq(gw.getMainchainHeight(), 304427, "head height");
        assertTrue(gw.isInMainchain(SPVFixtures.PROOF_BLOCK_HASH_BE), "proof block in mainchain");
    }

    function test_signet_checkTxInclusion_real_proof() public {
        gw = _signetGateway();
        // tx index 5 in block 304426; head is 304427 ⇒ 1 confirmation.
        bool ok = gw.checkTxInclusion(
            SPVFixtures.merkleProof(),
            SPVFixtures.PROOF_BLOCK_HASH_BE,
            SPVFixtures.PROOF_TXID_LE,
            SPVFixtures.PROOF_TX_INDEX,
            1 // minConfirmations
        );
        assertTrue(ok, "valid merkle proof must verify");
    }

    function test_signet_checkTxInclusion_wrong_index_fails() public {
        gw = _signetGateway();
        bool ok = gw.checkTxInclusion(
            SPVFixtures.merkleProof(),
            SPVFixtures.PROOF_BLOCK_HASH_BE,
            SPVFixtures.PROOF_TXID_LE,
            SPVFixtures.PROOF_TX_INDEX + 1, // wrong position
            1
        );
        assertFalse(ok, "wrong tx index must fail");
    }

    function test_signet_checkTxInclusion_unknown_block_fails() public {
        gw = _signetGateway();
        bool ok = gw.checkTxInclusion(
            SPVFixtures.merkleProof(),
            bytes32(uint256(0xdead)), // block not in chain
            SPVFixtures.PROOF_TXID_LE,
            SPVFixtures.PROOF_TX_INDEX,
            1
        );
        assertFalse(ok, "unknown block must fail");
    }

    function test_signet_checkTxInclusion_insufficient_confirmations_fails() public {
        gw = _signetGateway();
        // proof block has only 1 confirmation; demand 6 ⇒ fail.
        bool ok = gw.checkTxInclusion(
            SPVFixtures.merkleProof(),
            SPVFixtures.PROOF_BLOCK_HASH_BE,
            SPVFixtures.PROOF_TXID_LE,
            SPVFixtures.PROOF_TX_INDEX,
            6
        );
        assertFalse(ok, "insufficient confirmations must fail");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SYNTHETIC CHAINS — reorg / competing-chain handling
    //  Chain A: genesis→A1→A2→A3 (3 blocks)
    //  Chain B: genesis→B1→B2→B3→B4 (4 blocks, heavier)
    //  Same difficulty ⇒ more blocks = more cumulative work.
    // ═══════════════════════════════════════════════════════════════
    function _syntheticGateway() internal returns (SPVGateway g) {
        g = new SPVGateway();
        g.__SPVGateway_init(SPVFixtures.GEN_HEADER, 0, 0);
    }

    function test_reorg_lighter_fork_does_not_displace() public {
        gw = _syntheticGateway();
        gw.addBlockHeader(SPVFixtures.A1_HEADER);
        gw.addBlockHeader(SPVFixtures.A2_HEADER);
        gw.addBlockHeader(SPVFixtures.A3_HEADER);
        assertEq(gw.getMainchainHead(), SPVFixtures.A3_HASH_BE, "head = A3");
        assertEq(gw.getMainchainHeight(), 3, "height 3");

        // Build B up to height 3 — TIES A3's work. Strict-greater rule ⇒ no reorg.
        gw.addBlockHeader(SPVFixtures.B1_HEADER);
        gw.addBlockHeader(SPVFixtures.B2_HEADER);
        gw.addBlockHeader(SPVFixtures.B3_HEADER);
        assertEq(gw.getMainchainHead(), SPVFixtures.A3_HASH_BE, "equal work: A3 stays head");
        assertTrue(gw.isInMainchain(SPVFixtures.A3_HASH_BE), "A3 still main");
        assertFalse(gw.isInMainchain(SPVFixtures.B3_HASH_BE), "B3 not yet main");
    }

    /// SECURITY #3: cumulative work is stored PER-BLOCK (parent + own work), so
    /// fork-choice compares each candidate head's TRUE ancestry work. The OLD code
    /// used a single global accumulator + a height-derived partial; that cancels in
    /// the head-vs-head comparison (same global on both sides) and double-counts on
    /// competing-fork boundary submissions, mis-selecting the head across epoch
    /// boundaries. This asserts the per-block accounting is monotonic, ancestry-
    /// correct, and INDEPENDENT across forks. (Same-difficulty synthetic chain: each
    /// block adds a constant work W, so A2 == 2*A1, A3 == 3*A1, a height-1 fork ties A1.)
    function test_cumulativeWork_is_per_block_ancestry() public {
        gw = _syntheticGateway();
        gw.addBlockHeader(SPVFixtures.A1_HEADER);
        gw.addBlockHeader(SPVFixtures.A2_HEADER);
        gw.addBlockHeader(SPVFixtures.A3_HEADER);
        uint256 a1 = gw.getBlockInfo(SPVFixtures.A1_HASH_BE).cumulativeWork;
        uint256 a2 = gw.getBlockInfo(SPVFixtures.A2_HASH_BE).cumulativeWork;
        uint256 a3 = gw.getBlockInfo(SPVFixtures.A3_HASH_BE).cumulativeWork;
        assertGt(a1, 0, "a block contributes nonzero work");
        assertEq(a2, 2 * a1, "A2 = 2 blocks of ancestry work (monotonic)");
        assertEq(a3, 3 * a1, "A3 = 3 blocks of ancestry work");

        // A competing fork off genesis accrues ITS OWN ancestry work, NOT chain A's —
        // the old global would have conflated the two forks' totals.
        gw.addBlockHeader(SPVFixtures.B1_HEADER);
        uint256 b1 = gw.getBlockInfo(SPVFixtures.B1_HASH_BE).cumulativeWork;
        assertEq(b1, a1, "B1 (height-1 fork off genesis) ties A1 - fork-independent ancestry");
    }

    function test_reorg_heavier_fork_displaces() public {
        gw = _syntheticGateway();
        gw.addBlockHeader(SPVFixtures.A1_HEADER);
        gw.addBlockHeader(SPVFixtures.A2_HEADER);
        gw.addBlockHeader(SPVFixtures.A3_HEADER);
        gw.addBlockHeader(SPVFixtures.B1_HEADER);
        gw.addBlockHeader(SPVFixtures.B2_HEADER);
        gw.addBlockHeader(SPVFixtures.B3_HEADER);

        // B4 makes chain B strictly heavier ⇒ reorg.
        gw.addBlockHeader(SPVFixtures.B4_HEADER);

        assertEq(gw.getMainchainHead(), SPVFixtures.B4_HASH_BE, "head = B4 after reorg");
        assertEq(gw.getMainchainHeight(), 4, "height 4");

        // A-chain blocks fall out of the mainchain.
        assertFalse(gw.isInMainchain(SPVFixtures.A1_HASH_BE), "A1 reorged out");
        assertFalse(gw.isInMainchain(SPVFixtures.A2_HASH_BE), "A2 reorged out");
        assertFalse(gw.isInMainchain(SPVFixtures.A3_HASH_BE), "A3 reorged out");

        // B-chain is now canonical at every height.
        assertTrue(gw.isInMainchain(SPVFixtures.B1_HASH_BE), "B1 main");
        assertTrue(gw.isInMainchain(SPVFixtures.B2_HASH_BE), "B2 main");
        assertTrue(gw.isInMainchain(SPVFixtures.B3_HASH_BE), "B3 main");
        assertTrue(gw.isInMainchain(SPVFixtures.B4_HASH_BE), "B4 main");

        // height→hash mapping rewritten to B-chain.
        assertEq(gw.getBlockHash(3), SPVFixtures.B3_HASH_BE, "height 3 now B3");
    }

    function test_reorg_inclusion_flips_after_reorg() public {
        // A confirmed-looking tx anchored to an A-chain block must STOP
        // verifying once the A chain is reorged out. We use A3 as the anchor
        // block and a trivial 1-leaf proof is not available here; instead we
        // assert the block-status flip that checkTxInclusion gates on.
        gw = _syntheticGateway();
        gw.addBlockHeader(SPVFixtures.A1_HEADER);
        gw.addBlockHeader(SPVFixtures.A2_HEADER);
        gw.addBlockHeader(SPVFixtures.A3_HEADER);
        (bool inMainBefore,) = gw.getBlockStatus(SPVFixtures.A3_HASH_BE);
        assertTrue(inMainBefore, "A3 in mainchain pre-reorg");

        gw.addBlockHeader(SPVFixtures.B1_HEADER);
        gw.addBlockHeader(SPVFixtures.B2_HEADER);
        gw.addBlockHeader(SPVFixtures.B3_HEADER);
        gw.addBlockHeader(SPVFixtures.B4_HEADER);

        (bool inMainAfter,) = gw.getBlockStatus(SPVFixtures.A3_HASH_BE);
        assertFalse(inMainAfter, "A3 status flips to NOT-in-mainchain after reorg");
        // ⇒ any checkTxInclusion against an A-chain block now returns false.
    }
}
