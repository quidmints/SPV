// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CRSADispatcher} from '../../../src/identity/certificate/dispatchers/CRSADispatcher.sol';

/*
 * The dispatcher wiring on the DSC-admission path (sec. 2.18x).
 *
 * `Registration2.registerCertificate` reads a DSC's public key and expiry out of CSCA-signed
 * attributes through this contract, then derives the `certificateKey` that becomes a leaf of
 * `certificatesSmt` - the tree `register_identity` proves membership in. X509's parsing is tested
 * (sec. 2.18m); what was untested is the dispatcher wrapping it and the key derivation on top.
 *
 * THE OFFSETS ARE CALLER-SUPPLIED AND UNSIGNED. The CSCA signature covers the ATTRIBUTES, never the
 * offsets used to read them - which is what made sec. 2.18m's out-of-bounds read reachable. These
 * tests pin that the bounds now hold through the dispatcher, not only in the library.
 */
contract CRSADispatcherTest is Test {
    CRSADispatcher internal dispatcher;

    /// A SubjectPublicKeyInfo-ish marker; only its length matters to the parsing.
    bytes internal constant PREFIX = hex'0282';
    uint256 internal constant KEY_BYTES = 128;

    function setUp() public {
        dispatcher = new CRSADispatcher();
        dispatcher.__CRSADispatcher_init(address(0x51), KEY_BYTES, PREFIX);
    }

    function _attributes(uint256 len_, uint256 keyOffset_) internal pure returns (bytes memory out_) {
        out_ = new bytes(len_);
        for (uint256 i = 0; i < len_; ++i) {
            out_[i] = bytes1(uint8((i % 251) + 1));
        }
        out_[keyOffset_ - 2] = PREFIX[0];
        out_[keyOffset_ - 1] = PREFIX[1];
    }

    function test_ExtractsTheKeyAtTheGivenOffset() public view {
        bytes memory sa_ = _attributes(300, 16);
        bytes memory key_ = dispatcher.getCertificatePublicKey(sa_, 16);

        assertEq(key_.length, KEY_BYTES, 'wrong key length');
        for (uint256 i = 0; i < KEY_BYTES; ++i) {
            assertEq(uint8(key_[i]), uint8(sa_[16 + i]), 'key bytes are not the ones at the offset');
        }
    }

    /// The bound from sec. 2.18m must hold THROUGH the dispatcher, not just in X509 directly.
    function test_RefusesAKeyRunningPastTheAttributes() public {
        bytes memory sa_ = _attributes(140, 130);

        vm.expectRevert(bytes('X509: key runs past the signed attributes'));
        dispatcher.getCertificatePublicKey(sa_, 130);
    }

    function test_RefusesAnOffsetWithoutThePrefix() public {
        bytes memory sa_ = _attributes(300, 16);

        vm.expectRevert(bytes('X509: wrong check placement'));
        dispatcher.getCertificatePublicKey(sa_, 17);
    }

    /*
     * The certificate key must be a FUNCTION of the whole key, and distinct keys must not collide -
     * a collision would let one DSC's admission stand in for another's.
     */
    function test_TheCertificateKeyIsDeterministicAndKeyDependent() public view {
        bytes memory a_ = _attributes(300, 16);
        bytes memory b_ = _attributes(300, 16);
        b_[16 + KEY_BYTES - 1] = bytes1(uint8(b_[16 + KEY_BYTES - 1]) ^ 0x01);

        uint256 ka_ = dispatcher.getCertificateKey(dispatcher.getCertificatePublicKey(a_, 16));
        uint256 kb_ = dispatcher.getCertificateKey(dispatcher.getCertificatePublicKey(b_, 16));

        assertEq(ka_, dispatcher.getCertificateKey(dispatcher.getCertificatePublicKey(a_, 16)), 'not deterministic');
        assertTrue(ka_ != kb_, 'two different keys produced the same certificate key');
        assertTrue(ka_ != 0, 'a zero certificate key would collide with an empty SMT slot');
    }

    function test_ExtractsTheExpiry() public view {
        bytes memory sa_ = new bytes(64);
        sa_[20] = 0x17;
        sa_[21] = 0x0d;
        bytes memory ascii_ = bytes('300911072126');
        for (uint256 i = 0; i < 12; ++i) {
            sa_[22 + i] = ascii_[i];
        }

        assertEq(dispatcher.getCertificateExpirationTimestamp(sa_, 22), 1_915_341_686);
    }

    /*
     * Twelve ASCII digits from `offset` need `offset + 12` bytes. With a 30-byte array, offset 19
     * overruns by one and offset 18 does NOT - and the first version of this test used 18, which
     * reverted for an unrelated reason (the ASCII conversion underflowing on a zero byte) and
     * looked like the bound firing. Exactly the accident sec. 2.18m found in the library itself.
     */
    function test_RefusesAnExpiryRunningPastTheAttributes() public {
        bytes memory sa_ = new bytes(30);
        sa_[17] = 0x17;
        sa_[18] = 0x0d;

        vm.expectRevert(bytes('X509: expiration runs past the signed attributes'));
        dispatcher.getCertificateExpirationTimestamp(sa_, 19);
    }

    /// And the boundary itself is accepted, so the guard is not merely off-by-one strict.
    function test_AcceptsAnExpiryEndingExactlyAtTheLastByte() public view {
        bytes memory sa_ = new bytes(30);
        sa_[16] = 0x17;
        sa_[17] = 0x0d;
        bytes memory ascii_ = bytes('300911072126');
        for (uint256 i = 0; i < 12; ++i) {
            sa_[18 + i] = ascii_[i];
        }

        assertEq(dispatcher.getCertificateExpirationTimestamp(sa_, 18), 1_915_341_686);
    }
}
