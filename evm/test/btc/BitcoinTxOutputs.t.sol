// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BitcoinTx} from "../../src/imports/BitcoinTx.sol";

/// @notice Unit tests for `BitcoinTx.sumOutputValuesExcept` — the primitive behind the
///         withdrawal-splice anti-redirection guard (`BTCChannels._withdrawalPayout`). A
///         pure LP-withdrawal splice may pay ONLY the new funding output (by index) and
///         the LP's committed P2WPKH; any other ("foreign") output means the LP is routing
///         channel value where the EVM can't attribute it, which would let it drive
///         `_lpFinalBalance` → 0 and over-claim the shared swap-out proceeds pool. The guard
///         requires this sum to be 0. These tests prove it sees exactly the foreign value.
contract BitcoinTxOutputsTest is Test {
    BitcoinTxHarness h;

    // A funding-like P2WSH (0x0020 + 32) and an LP payout P2WPKH (0x0014 + 20).
    bytes constant FUNDING = hex"0020aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes constant PAYOUT  = hex"0014bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    bytes constant FOREIGN = hex"0014cccccccccccccccccccccccccccccccccccccccc";

    function setUp() public { h = new BitcoinTxHarness(); }

    /// version(4) + 1 input + the supplied outputs + locktime(4). Each output is
    /// value(8 LE) + scriptLen(varint, 1 byte for our short scripts) + script.
    function _tx(bytes memory outputs, uint8 nOut) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(uint(0x1234)), hex"00000000", hex"00", hex"ffffffff",
            bytes1(nOut), outputs,
            hex"00000000");
    }

    function _out(uint value, bytes memory spk) internal pure returns (bytes memory) {
        return abi.encodePacked(_le(value), bytes1(uint8(spk.length)), spk);
    }

    function _le(uint v) internal pure returns (bytes memory b) {
        b = new bytes(8);
        for (uint i = 0; i < 8; i++) { b[i] = bytes1(uint8(v >> (8 * i))); }
    }

    /// Funding(vout 0) + payout → no foreign value.
    function test_clean_withdrawal_no_foreign() public view {
        bytes memory tx_ = _tx(abi.encodePacked(_out(1_000_000, FUNDING), _out(600_000, PAYOUT)), 2);
        assertEq(h.exceptSum(tx_, 0, PAYOUT), 0, "funding+payout has no foreign output");
        assertEq(h.toScript(tx_, PAYOUT), 600_000, "payout sum is the withdrawal");
    }

    /// Funding(vout 0) + a FOREIGN output → the guard sees exactly the redirected value.
    function test_foreign_output_detected() public view {
        bytes memory tx_ = _tx(abi.encodePacked(_out(1_000_000, FUNDING), _out(600_000, FOREIGN)), 2);
        assertEq(h.exceptSum(tx_, 0, PAYOUT), 600_000, "redirected withdrawal counted as foreign");
        assertEq(h.toScript(tx_, PAYOUT), 0, "nothing paid to the committed payout script");
    }

    /// Funding + payout + a sneaky extra foreign output → only the foreign value counts.
    function test_partial_redirect_detected() public view {
        bytes memory tx_ = _tx(
            abi.encodePacked(_out(1_000_000, FUNDING), _out(500_000, PAYOUT), _out(100_000, FOREIGN)), 3);
        assertEq(h.exceptSum(tx_, 0, PAYOUT), 100_000, "the foreign slice is caught even alongside a real payout");
    }

    /// Payout split across TWO outputs to the committed script → still no foreign value
    /// (matches sumOutputValuesToScript's sum-all behavior; can't be evaded by splitting).
    function test_split_payout_is_not_foreign() public view {
        bytes memory tx_ = _tx(
            abi.encodePacked(_out(1_000_000, FUNDING), _out(300_000, PAYOUT), _out(300_000, PAYOUT)), 3);
        assertEq(h.exceptSum(tx_, 0, PAYOUT), 0, "split payout is all to the committed script");
        assertEq(h.toScript(tx_, PAYOUT), 600_000, "both payout outputs sum");
    }

    /// The excluded funding index is honored at a non-zero position (payout first,
    /// funding second): excluding vout 1 leaves no foreign value.
    function test_funding_index_excluded_nonzero() public view {
        bytes memory tx_ = _tx(abi.encodePacked(_out(600_000, PAYOUT), _out(1_000_000, FUNDING)), 2);
        assertEq(h.exceptSum(tx_, 1, PAYOUT), 0, "funding at vout 1 is excluded, payout matches");
        // If we (wrongly) excluded vout 0 instead, the funding P2WSH would read as foreign.
        assertEq(h.exceptSum(tx_, 0, PAYOUT), 1_000_000, "excluding the wrong index exposes the funding output");
    }

    // ───────────────────── M7: taproot (P2TR) funding adapter ──────────────────
    // A simple-taproot channel funds a P2TR output `0x5120||Q` (34 bytes), where Q
    // is the 32-byte x-only key-path MuSig2 aggregate. The contract does NO secp256k1
    // EC math: it builds `0x5120||Q` from the supplied Q and byte-matches the
    // SPV-proven funding output (exactly as the P2WSH path builds wsh(...) and matches).

    /// `buildTaprootScriptPubKey(Q)` == OP_1 (0x51) PUSH32 (0x20) || Q — 34 bytes.
    function test_taproot_spk_is_op1_push32_q() public view {
        bytes32 q = bytes32(uint256(0xC0FFEE)) | bytes32(uint256(0xAB) << 248);
        bytes memory spk = h.taprootSpk(q);
        assertEq(spk.length, 34, "P2TR spk is 34 bytes");
        assertEq(uint8(spk[0]), 0x51, "OP_1");
        assertEq(uint8(spk[1]), 0x20, "push 32");
        for (uint i = 0; i < 32; i++) assertEq(spk[2 + i], q[i], "tail is Q");
    }

    /// The taproot funding output is located by its `0x5120||Q` scriptPubKey, with
    /// its value read back — the taproot analogue of the P2WSH `findOutputByScript`.
    function test_taproot_funding_output_located() public {
        bytes32 q = keccak256("M7-taproot-Q");
        bytes memory tapSpk = h.taprootSpk(q);
        // tx: a decoy P2WPKH at vout 0, the P2TR funding at vout 1.
        bytes memory tx_ = _tx(abi.encodePacked(_out(5_000, PAYOUT), _out(1_000_000, tapSpk)), 2);
        (uint32 vout, uint sats) = h.findByScript(tx_, tapSpk);
        assertEq(vout, 1, "P2TR funding output at vout 1");
        assertEq(sats, 1_000_000, "funding value read back");
        // A tx with NO P2TR output reverts (a P2WSH-only tx is not a taproot channel).
        bytes memory wsh = _tx(abi.encodePacked(_out(7, FUNDING)), 1);
        vm.expectRevert(BitcoinTx.OutputNotFound.selector);
        h.findByScript(wsh, tapSpk);
    }

    // ──────────── H2: BOLT#3 commitment-tx discriminator (force-retire gate) ──────
    // `isCommitmentTx` gates the PERMISSIONLESS force-retire. It must accept ONLY a
    // genuine commitment tx (nLockTime top byte 0x20 AND input nSequence top byte
    // 0x80, BOLT#3) — so a splice (locktime=block height) or a cooperative close
    // (locktime 0) CANNOT be replayed by a third party to force-retire a LIVE
    // channel.

    /// version(4) + 1 input with a CUSTOM nSequence + the outputs + a CUSTOM locktime.
    function _txSL(bytes memory outputs, uint8 nOut, bytes4 seqLE, bytes4 ltLE)
        internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(uint(0x1234)), hex"00000000", hex"00",  // outpoint + empty scriptSig
            seqLE,                                          // input[0] nSequence (LE)
            bytes1(nOut), outputs,
            ltLE);                                          // nLockTime (LE)
    }

    function test_isCommitmentTx_discriminates_commitment_from_splice_and_coop() public view {
        bytes memory outs = _out(1_000_000, FUNDING);
        // Commitment (force-close): seq 0x80000001, locktime 0x20000001 (BOLT#3) → PASS.
        assertTrue(h.isCommit(_txSL(outs, 1, hex"01000080", hex"01000020")),
            "genuine commitment tx passes");
        assertEq(h.input0Seq(_txSL(outs, 1, hex"01000080", hex"01000020")), 0x80000001,
            "input[0] nSequence extracted");
        // Cooperative close: locktime 0, seq 0xffffffff → FAIL.
        assertFalse(h.isCommit(_txSL(outs, 1, hex"ffffffff", hex"00000000")),
            "cooperative close is not a commitment tx");
        // Splice: locktime = a block height (~800000 = 0x000c3500, top byte 0x00),
        // RBF sequence 0xfffffffd → FAIL (this is the HIGH-2 replay vector, blocked).
        assertFalse(h.isCommit(_txSL(outs, 1, hex"fdffffff", hex"00350c00")),
            "splice tx is not a commitment tx");
        // BOTH bytes are required: seq-only or locktime-only → FAIL.
        assertFalse(h.isCommit(_txSL(outs, 1, hex"01000080", hex"00000000")),
            "0x80 sequence alone is not enough");
        assertFalse(h.isCommit(_txSL(outs, 1, hex"ffffffff", hex"01000020")),
            "0x20 locktime alone is not enough");
    }
}

/// Thin external wrapper so the calldata-taking internal library fns are callable.
contract BitcoinTxHarness {
    function exceptSum(bytes calldata raw, uint32 v, bytes calldata spk) external pure returns (uint) {
        return BitcoinTx.sumOutputValuesExcept(raw, v, spk);
    }
    function toScript(bytes calldata raw, bytes calldata spk) external pure returns (uint) {
        return BitcoinTx.sumOutputValuesToScript(raw, spk);
    }
    function taprootSpk(bytes32 q) external pure returns (bytes memory) {
        return BitcoinTx.buildTaprootScriptPubKey(q);
    }
    function findByScript(bytes calldata raw, bytes calldata spk)
        external pure returns (uint32, uint) {
        return BitcoinTx.findOutputByScript(raw, spk);
    }
    function isCommit(bytes calldata raw) external pure returns (bool) {
        return BitcoinTx.isCommitmentTx(raw);
    }
    function input0Seq(bytes calldata raw) external pure returns (uint32) {
        return BitcoinTx.extractInput0Sequence(raw);
    }
}
