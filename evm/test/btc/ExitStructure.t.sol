// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
import {ExitLib} from "../../src/imports/ExitLib.sol";
import {BitcoinTx} from "../../src/imports/BitcoinTx.sol";

/// @notice (E128) STRUCTURAL verification of a pre-signed dead-man exit.
///
///         🔴 WHY IT EXISTS: `emitDeadManExit` takes `signedExitTx` and only EMITS it. Nothing
///         parses it, nothing checks it. Since §E156 armed the exit at OPEN, those bytes are the
///         LP's only fleet-independent escape — and a hop can arm every channel with garbage while
///         the chain records it as protection.
///
///         ⚠️ SCOPE, SO A GREEN RUN IS NOT MISREAD: this covers STRUCTURE only — spends the
///         funding outpoint, pays the committed script, matures at the recorded deadline. **The
///         SIGNATURE is not checked here.** A structurally perfect exit with invalid witness bytes
///         passes every assertion below and is unbroadcastable in reality.
contract ExitStructureTest is Test {
    /// ⚠️ DELIBERATELY NOT A BYTE PALINDROME. This was `0x1111...11`, and
    /// `test_reversedTxidIsRejected` FAILED — not because the reversal guard was broken but
    /// because reversing a run of identical bytes yields the SAME value, so the test compared a
    /// txid against itself and asserted nothing. A constant chosen for readability silently
    /// removed the only property the test existed to check.
    bytes32 constant FUNDING_TXID =
        bytes32(0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20);
    uint32  constant FUNDING_VOUT = 1;
    uint64  constant DEADLINE     = 800_042;

    /// The LP's committed payout: `0x5120 || x-only`.
    function _payoutScript() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x51), bytes1(0x20),
            bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
    }

    function _le4(uint32 v) internal pure returns (bytes4) {
        return bytes4(uint32(
            ((v & 0xff) << 24) | (((v >> 8) & 0xff) << 16) | (((v >> 16) & 0xff) << 8) | ((v >> 24) & 0xff)));
    }
    function _le8(uint64 v) internal pure returns (bytes8 o) {
        for (uint i; i < 8; ++i) o |= bytes8(bytes1(uint8(v >> (8 * i)))) >> (8 * i);
    }

    /// A SEGWIT transaction — marker 0x00, flag 0x01, one witness item per input. This is the
    /// shape `BitcoinTx` refuses outright (`_assertLegacy` rejects `raw[4] == 0x00`), which is the
    /// whole reason `TxParser` is used here.
    function _signedExit(bytes32 prevTxidInternal, uint32 vout, uint64 payValue, uint32 locktime)
        internal pure returns (bytes memory)
    {
        bytes memory spk = _payoutScript();
        return abi.encodePacked(
            hex"02000000",                        // version 2
            hex"00", hex"01",                     // segwit marker + flag
            hex"01",                              // 1 input
            prevTxidInternal, _le4(vout),         // outpoint (INTERNAL byte order, as serialized)
            hex"00",                              // empty scriptSig
            hex"ffffffff",                        // sequence
            hex"01",                              // 1 output
            _le8(payValue), bytes1(uint8(spk.length)), spk,
            hex"01", hex"40", new bytes(64),      // witness: 1 item, 64 bytes (a Schnorr sig)
            _le4(locktime)
        );
    }

    /// Sanity: our own parser genuinely cannot read this, which is the premise of §E140-r.
    function test_bitcoinTxCannotParseAWitnessTx() public {
        bytes memory raw = _signedExit(FUNDING_TXID, FUNDING_VOUT, 50_000, uint32(DEADLINE));
        vm.expectRevert();
        this.callInputCount(raw);
    }
    function callInputCount(bytes calldata raw) external pure returns (uint) {
        return BitcoinTx.inputCount(raw);
    }

    function test_acceptsAWellFormedExitAndReturnsThePayout() public view {
        bytes memory raw = _signedExit(FUNDING_TXID, FUNDING_VOUT, 50_000, uint32(DEADLINE));
        uint paid = ExitLib.verifyExitStructure(
            raw, FUNDING_TXID, FUNDING_VOUT, _payoutScript(), DEADLINE);
        assertEq(paid, 50_000, "sats paid to the LP's committed script");
    }

    /// ⚠️ THE BYTE-ORDER REGRESSION GUARD (§E140-r2). `TxParser` returns `previousHash` in DISPLAY
    /// order while our `fundingTxId` is INTERNAL order. If the reversal is ever dropped, this test
    /// fails — whereas the happy path above would ALSO fail, silently looking like "no input
    /// spends the channel". The reversed-txid case below is what distinguishes the two.
    function test_reversedTxidIsRejected() public {
        bytes32 reversed;
        for (uint i; i < 32; ++i)
            reversed |= bytes32(bytes1(FUNDING_TXID[31 - i])) >> (8 * i);
        bytes memory raw = _signedExit(reversed, FUNDING_VOUT, 50_000, uint32(DEADLINE));
        vm.expectRevert(ExitLib.ExitNotForThisChannel.selector);
        ExitLib.verifyExitStructure(raw, FUNDING_TXID, FUNDING_VOUT, _payoutScript(), DEADLINE);
    }

    function test_wrongVoutIsRejected() public {
        bytes memory raw = _signedExit(FUNDING_TXID, FUNDING_VOUT + 1, 50_000, uint32(DEADLINE));
        vm.expectRevert(ExitLib.ExitNotForThisChannel.selector);
        ExitLib.verifyExitStructure(raw, FUNDING_TXID, FUNDING_VOUT, _payoutScript(), DEADLINE);
    }

    function test_wrongLocktimeIsRejected() public {
        bytes memory raw = _signedExit(FUNDING_TXID, FUNDING_VOUT, 50_000, uint32(DEADLINE) + 1);
        vm.expectRevert(ExitLib.ExitLocktimeMismatch.selector);
        ExitLib.verifyExitStructure(raw, FUNDING_TXID, FUNDING_VOUT, _payoutScript(), DEADLINE);
    }

    /// An exit paying somewhere else is structurally valid but pays the LP ZERO. It does NOT
    /// revert — the caller decides what a shortfall means, exactly as the stale-close guard does.
    function test_payingAnotherScriptYieldsZero() public view {
        bytes memory raw = _signedExit(FUNDING_TXID, FUNDING_VOUT, 50_000, uint32(DEADLINE));
        bytes memory otherScript = abi.encodePacked(bytes1(0x51), bytes1(0x20), bytes32(uint256(7)));
        assertEq(
            ExitLib.verifyExitStructure(raw, FUNDING_TXID, FUNDING_VOUT, otherScript, DEADLINE),
            0, "an exit paying elsewhere credits the LP nothing"
        );
    }
}
