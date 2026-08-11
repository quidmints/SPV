// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
import {ExitLib} from "../../src/imports/ExitLib.sol";

/// @notice (E128) The THREE verified pieces, joined: structure → BIP-341 sighash → BIP-340
///         signature. This is what turns `emitDeadManExit` from *"record whatever bytes the hop
///         supplies"* into a checked guarantee.
///
///         ⚠️ THIS FIXTURE IS SELF-GENERATED, AND THAT IS ACCEPTABLE **ONLY** BECAUSE EACH
///         COMPONENT IS SEPARATELY PINNED TO OFFICIAL VECTORS: the sighash to BIP-341
///         `keyPathSpending[0]/inputSpending[3]` (`TapSighash.t.sol`) and the signature to BIP-340
///         vectors 0–4 (`SchnorrBip340.t.sol`). What is tested HERE is the WIRING — witness
///         extraction, input location, prevout pinning, byte order — not the cryptography. A
///         self-generated fixture could never establish the latter.
contract DeadManExitVerifyTest is Test {
    bytes32 constant FUNDING_TXID =
        bytes32(0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20);
    uint32  constant FUNDING_VOUT = 1;
    uint    constant FUNDING_SATS = 250_000;
    uint64  constant DEADLINE     = 800_042;
    uint    constant PAYS_LP      = 249_000;

    /// The funding output key. Its secret is BIP-340 vector 1's key, so `q` is that vector's
    /// public key — a real point with a known discrete log, which is what lets the fixture be
    /// signed at all.
    bytes32 constant Q =
        bytes32(0xdff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659);

    function _payoutScript() internal pure returns (bytes memory) {
        return hex"512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    }

    /// A genuinely signed key-path taproot spend: segwit-serialised, one 64-byte Schnorr witness,
    /// nLockTime = the deadline.
    function _signedExit() internal pure returns (bytes memory) {
        return hex"020000000001010102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e"
               hex"1f200100000000ffffffff01a8cc0300000000002251"
               hex"2079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
               hex"014079c27b3777830f8d159325d329f5577e6e6a4f798cd7ca0541133e14f8c22d48"
               hex"9ab8942d7514acd75dcbc9c31f16640e65967756935434f555f96d79a42b73102a350c00";
    }

    function _check() internal pure returns (ExitLib.ExitCheck memory) {
        return ExitLib.ExitCheck({
            fundingTxId: FUNDING_TXID, fundingVout: FUNDING_VOUT,
            fundingSats: FUNDING_SATS, q: Q, cltvDeadline: DEADLINE });
    }

    function _prev() internal pure returns (uint64[] memory v, bytes[] memory s) {
        v = new uint64[](1); s = new bytes[](1);   // both overwritten by the contract
    }

    function test_verifiesAGenuinelySignedExit() public view {
        (uint64[] memory v, bytes[] memory s) = _prev();
        assertEq(
            ExitLib.verifyDeadManExit(_signedExit(), _check(), _payoutScript(), v, s),
            PAYS_LP, "sats the exit pays the LP's committed script"
        );
    }

    /// ⚠️ THE PREVOUT-PINNING TEST, and the reason the contract overwrites the caller's array.
    /// `Prevouts::All` commits to the funding prevout's VALUE. If that were caller-supplied, a hop
    /// could compute a sighash over a different amount, sign THAT, and pass. Here the caller's
    /// values are deliberate garbage — verification must still succeed, because the contract
    /// substitutes what the chain knows.
    function test_callerSuppliedFundingPrevoutIsIgnored() public view {
        uint64[] memory v = new uint64[](1); bytes[] memory s = new bytes[](1);
        v[0] = 999_999_999;                             // a lie
        s[0] = hex"0014deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";   // also a lie
        assertEq(
            ExitLib.verifyDeadManExit(_signedExit(), _check(), _payoutScript(), v, s),
            PAYS_LP, "the contract pins the funding prevout itself"
        );
    }

    /// ⚠️ THE CONTROL. Every assertion above is positive; a verifier that never checked the
    /// signature would pass them all. Claiming a different funding VALUE changes the sighash, so
    /// the signature must stop verifying.
    function test_aWrongFundingValueBreaksTheSignature() public {
        ExitLib.ExitCheck memory c = _check();
        c.fundingSats = FUNDING_SATS + 1;
        (uint64[] memory v, bytes[] memory s) = _prev();
        vm.expectRevert(ExitLib.ExitSignatureInvalid.selector);
        ExitLib.verifyDeadManExit(_signedExit(), c, _payoutScript(), v, s);
    }

    /// The signature is bound to Q. A different key must not verify.
    function test_aDifferentFundingKeyIsRejected() public {
        ExitLib.ExitCheck memory c = _check();
        c.q = bytes32(0xf9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9);
        (uint64[] memory v, bytes[] memory s) = _prev();
        vm.expectRevert(ExitLib.ExitSignatureInvalid.selector);
        ExitLib.verifyDeadManExit(_signedExit(), c, _payoutScript(), v, s);
    }

    /// A key-path spend carries exactly one 64-byte witness item. Anything else is not the shape
    /// this verifier understands, and must be refused rather than mis-read.
    function test_aTamperedWitnessIsRejected() public {
        bytes memory raw = _signedExit();
        raw[raw.length - 6] ^= bytes1(0x01);      // flip a bit inside `s`
        (uint64[] memory v, bytes[] memory s_) = _prev();
        vm.expectRevert(ExitLib.ExitSignatureInvalid.selector);
        ExitLib.verifyDeadManExit(raw, _check(), _payoutScript(), v, s_);
    }

    /// (E128) THE GENERATED FIXTURE — a channel whose funding key `Q` is a real MuSig2 aggregate
    /// of two per-channel pubkeys, signed with the aggregate secret. This is the shape every
    /// channel-opening test must move to now that arming VERIFIES, and it proves the generator
    /// (`gen_deadman_exit_fixture.py`) produces something the contract actually accepts —
    /// including the two parity flips BIP-327/341 force, which are the whole difficulty.
    function test_generatedFixtureVerifies() public view {
        string memory j = vm.readFile(
            string.concat(vm.projectRoot(), "/test/btc/deadman_exit_fixture.json"));
        ExitLib.ExitCheck memory c = ExitLib.ExitCheck({
            fundingTxId:  vm.parseJsonBytes32(j, ".exits[0].fundingTxId"),
            fundingVout:  uint32(vm.parseJsonUint(j, ".exits[0].fundingVout")),
            fundingSats:  vm.parseJsonUint(j, ".exits[0].fundingSats"),
            q:            vm.parseJsonBytes32(j, ".exits[0].fundingTaproot"),
            cltvDeadline: uint64(vm.parseJsonUint(j, ".exits[0].cltvDeadline"))
        });
        uint64[] memory v = new uint64[](1); bytes[] memory s_ = new bytes[](1);
        assertEq(
            ExitLib.verifyDeadManExit(
                vm.parseJsonBytes(j, ".exits[0].signedExitTx"), c, _payoutScript(), v, s_),
            vm.parseJsonUint(j, ".exits[0].paysLp"),
            "a fixture-generated exit must verify against the aggregate key Q"
        );
    }
}
