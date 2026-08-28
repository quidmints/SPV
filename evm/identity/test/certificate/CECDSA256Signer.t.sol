// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CECDSA256Signer} from '../../contracts/certificate/signers/CECDSA256Signer.sol';

/*
 * The ECDSA half of the CSCA signature path (sec. 2.18v).
 *
 * sec. 2.18s found a byte-order bug in the RSA-PSS signer and sec. 2.18u a forgery in the PKCS#1
 * v1.5 one - both in code nothing had ever exercised. The ECDSA signers were in the same state, so
 * they get the same treatment: a real vector, generated and verified by openssl before use, plus
 * negatives that would catch a verifier which accepts anything.
 *
 * THE CURVE CONSTANTS WERE CHECKED BY HAND against the published parameters for secp256r1,
 * brainpoolP256r1 and brainpoolP512r1 - all three correct. Brainpool's `a` and `b` share a long
 * prefix, which looks like a copy-paste error and is not; they are derived from one seed.
 */
contract CECDSA256SignerTest is Test {
    CECDSA256Signer internal signer;

    /// secp256r1 public key as x || y, from `openssl ec -pubout`.
    bytes internal constant PUBKEY =
        hex"ed050c3b086602864a23d6ab09a2978f6e237018990f235c6386eeee4debbbe3"
        hex"ce7a9bb43bb546f32cae467cac729be718450b1be3a29beb4c817701c55b58a2";

    /// The DER signature openssl produced, converted to the raw r || s the library expects.
    bytes internal constant SIGNATURE =
        hex"a0a61abc96c19ecaf157e9baaa0568fe30f20a8fcbdd8a8e0b070df8d848c200"
        hex"fff3789210f04ed6883e50f4c7b516208018d9ee741882d9cce398cab68435db";

    bytes internal constant MESSAGE =
        hex"4943414f207369676e6564206174747269627574657320746865206174746163"
        hex"6b6572206e65766572206861642061207369676e617475726520666f72202330";

    function setUp() public {
        signer = new CECDSA256Signer();
        signer.__CECDSA256Signer_init(CECDSA256Signer.Curve.secp256r1, CECDSA256Signer.HF.sha2);
    }

    /// A genuine LOW-s signature from the same key, so the normalisation is shown to leave the
    /// already-canonical half alone rather than only fixing the high half.
    bytes internal constant SIGNATURE_LOW_S =
        hex"017910d1f8df0339c6fc6b31f53e52e3469a33d112f50d8b56671ff0177f3158"
        hex"4a2b52133f9eb709b1515f9ed1cd5f4868eb0e1ea6c6fb90b507e0316b66fe38";

    function test_VerifiesAGenuineLowSSignature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIGNATURE_LOW_S, PUBKEY),
            "a genuine low-s signature was rejected"
        );
    }

    /// The committed SIGNATURE is deliberately HIGH-s - the half the library refused outright, and
    /// the half openssl emits about 50% of the time.
    function test_VerifiesAGenuineP256Signature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIGNATURE, PUBKEY),
            "a signature openssl verified was rejected"
        );
    }

    function test_RejectsATamperedSignature() public view {
        bytes memory t_ = SIGNATURE;
        t_[0] = bytes1(uint8(t_[0]) ^ 0x01);
        assertFalse(signer.verifyICAOSignature(MESSAGE, t_, PUBKEY), "a tampered signature verified");
    }

    function test_RejectsADifferentMessage() public view {
        bytes memory m_ = MESSAGE;
        m_[0] = bytes1(uint8(m_[0]) ^ 0x01);
        assertFalse(signer.verifyICAOSignature(m_, SIGNATURE, PUBKEY), "verified against another message");
    }

    function test_RejectsADifferentKey() public view {
        bytes memory k_ = PUBKEY;
        k_[0] = bytes1(uint8(k_[0]) ^ 0x01);
        assertFalse(signer.verifyICAOSignature(MESSAGE, SIGNATURE, k_), "verified under another key");
    }

    /// An all-zero signature (r = s = 0) is the degenerate forgery every ECDSA verifier must refuse.
    function test_RejectsAZeroSignature() public view {
        assertFalse(
            signer.verifyICAOSignature(MESSAGE, new bytes(64), PUBKEY),
            "r = s = 0 was accepted"
        );
    }

    /// The wrong curve must reject - otherwise the curve selector is decorative.
    function test_RejectsUnderTheWrongCurve() public {
        CECDSA256Signer bp_ = new CECDSA256Signer();
        bp_.__CECDSA256Signer_init(CECDSA256Signer.Curve.brainpoolP256r1, CECDSA256Signer.HF.sha2);

        assertFalse(
            bp_.verifyICAOSignature(MESSAGE, SIGNATURE, PUBKEY),
            "a secp256r1 signature verified under brainpoolP256r1"
        );
    }

    /// And the wrong hash must reject, or algorithm substitution is possible.
    function test_RejectsUnderTheWrongHash() public {
        CECDSA256Signer s1_ = new CECDSA256Signer();
        s1_.__CECDSA256Signer_init(CECDSA256Signer.Curve.secp256r1, CECDSA256Signer.HF.sha1);

        assertFalse(
            s1_.verifyICAOSignature(MESSAGE, SIGNATURE, PUBKEY),
            "a SHA-256 signature verified under the SHA-1 setting"
        );
    }
}
