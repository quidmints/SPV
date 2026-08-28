// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CECDSA384Signer} from '../../../src/identity/certificate/signers/CECDSA384Signer.sol';

/*
 * The 384-bit half of sec. 2.18v. Same defect as the 256-bit signer - the library accepts only
 * low-s, CAs do not normalise - but the curve order is `bytes`, so the rewrite needed a big-endian
 * bignum subtraction (contracts/utils/EcdsaS.sol) rather than one line.
 *
 * BOTH VECTORS ARE GENUINE, produced by openssl over secp384r1 and chosen deliberately: one with
 * HIGH s, which the library refused outright, and one with LOW s, which proves the rewrite leaves
 * an already-canonical signature alone.
 */
contract CECDSA384SignerTest is Test {
    CECDSA384Signer internal signer;

    bytes internal constant PUBKEY =
        hex"ef5fb8e147ed0a4f45b8fb4adf629eb2fda9d9479aaa6e89c713fe363e8a512c"
        hex"0b3bf3e61cec25735acd0702fa2aa7a45e00a191aa84b2914c41458d268faf42"
        hex"931925ac0d27b321a22c4ddcc689f31ef1c4f6270ff3d6042ed1d8af8be0ad97";
    /// s > n/2 - the half that was rejected before EcdsaS.normalize.
    bytes internal constant SIG_HIGH_S =
        hex"fa6295bd79fa93d7cd07e3828bdfd0fe14a7e70ad72267b9f40487f205e2d887"
        hex"8e713bc1885bbda7264ec89a61db8962e464b08d2619c2b57bdba573eb7641f4"
        hex"deeadd928588d3c1a244a1de7c68f408c57e25f5bfd01400d7e6481b040925ef";
    /// s < n/2 - already canonical.
    bytes internal constant SIG_LOW_S =
        hex"07bb98e4cc77d0d9358f83cae0a07e2a213066bc99226179142dd9e099c4a410"
        hex"3cbf263a1948f885f673c60a957e66894e1a6bf10e2ca754458cde9d0ea08b45"
        hex"0fe2f1cbd2a0984044d9f3755d4469f1d4f7098e3ff9fe0d54c762528152fd38";
    bytes internal constant MESSAGE =
        hex"4943414f207369676e6564206174747269627574657320746865206174746163"
        hex"6b6572206e65766572206861642061207369676e617475726520666f72202330";

    function setUp() public {
        signer = new CECDSA384Signer();
        signer.__CECDSA384Signer_init(
            CECDSA384Signer.Curve.secp384r1,
            CECDSA384Signer.HF.sha384
        );
    }

    function test_VerifiesAGenuineHighSSignature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIG_HIGH_S, PUBKEY),
            "a genuine high-s signature was rejected - roughly half of all real ones look like this"
        );
    }

    function test_VerifiesAGenuineLowSSignature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIG_LOW_S, PUBKEY),
            "normalisation broke an already-canonical signature"
        );
    }

    function test_RejectsATamperedSignature() public view {
        bytes memory t_ = SIG_HIGH_S;
        t_[0] = bytes1(uint8(t_[0]) ^ 0x01);
        assertFalse(signer.verifyICAOSignature(MESSAGE, t_, PUBKEY), "a tampered signature verified");
    }

    function test_RejectsADifferentMessage() public view {
        bytes memory m_ = MESSAGE;
        m_[0] = bytes1(uint8(m_[0]) ^ 0x01);
        assertFalse(signer.verifyICAOSignature(m_, SIG_HIGH_S, PUBKEY), "verified against another message");
    }

    function test_RejectsAZeroSignature() public view {
        assertFalse(signer.verifyICAOSignature(MESSAGE, new bytes(96), PUBKEY), "r = s = 0 accepted");
    }

    /// The wrong-curve case is what caught the missing `s < n` guard on the 256-bit fix: a
    /// signature from another curve can carry an s exceeding this order, and n - s would underflow.
    function test_RejectsUnderTheWrongCurve() public {
        CECDSA384Signer bp_ = new CECDSA384Signer();
        bp_.__CECDSA384Signer_init(
            CECDSA384Signer.Curve.brainpoolP384r1,
            CECDSA384Signer.HF.sha384
        );

        assertFalse(
            bp_.verifyICAOSignature(MESSAGE, SIG_HIGH_S, PUBKEY),
            "a secp384r1 signature verified under brainpoolP384r1"
        );
    }
}
