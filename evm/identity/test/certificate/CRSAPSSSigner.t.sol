// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CRSAPSSSigner} from '../../contracts/certificate/signers/CRSAPSSSigner.sol';

/*
 * THE FIRST TEST OF THE ICAO SIGNATURE PATH (sec. 2.18l).
 *
 * `Registration2.registerCertificate` admits a DSC into `certificatesSmt` - the tree
 * `register_identity` proves membership in - only after this contract verifies a CSCA's signature
 * over the DSC's signed attributes. So every document that can ever enrol permissionlessly passes
 * through `verifyICAOSignature`, and it had no tests.
 *
 * THE VECTOR IS REAL AND REPRODUCIBLE, not a fixture from our own code. Generated with openssl and
 * independently verified by it before being pasted here:
 *
 *   openssl genrsa -out rsa.pem 2048
 *   openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
 *     -sign rsa.pem -out sig.bin msg.bin
 *   openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
 *     -verify rsa.pub.pem -signature sig.bin msg.bin        # -> Verified OK
 *
 * That matters more than convenience: a vector produced by the contract under test would only prove
 * self-consistency. This one proves the contract agrees with a reference implementation about what
 * RSASSA-PSS with SHA-256 and a 32-byte salt means.
 *
 * NO PASSPORT NEEDED. This half of the chain is signature verification, nothing more - which is why
 * it can be tested today while the enrolment path it feeds still waits on a real document.
 *
 * WRITING THIS TEST FOUND A BUG IN @solarity/solidity-lib (sec. 2.18s). `RSASSAPSS._pss`
 * read the modulus's LAST byte to count leading zero bits, where a big-endian modulus keeps its
 * most significant byte FIRST - so `sigBits_` was wrong whenever that last byte was under 0x80, and
 * roughly HALF of all valid signatures were rejected, chosen by an irrelevant property of the key.
 * The vector below has a modulus ending 0x41 and was rejected before the fix; four further keys
 * ending 0x85/0x99/0xeb/0xff were accepted. That is why this vector, specifically, is the committed
 * one - it is the half of the keyspace the bug used to break.
 */
contract CRSAPSSSignerTest is Test {
    CRSAPSSSigner internal signer;

    /// 2048-bit RSA modulus of the generated key.
    bytes internal constant MODULUS =
        hex"eabd9cac8617763429106d4e0e8d2f4f4d636258f2e8faecbb0bcc50e704f869fbf09e59241718e8322336d5c641801aa89436b7955a50f631777e64"
        hex"000f179e15858d61be388666706052aa0630f154266e9ab132cc97fb77f55f88aba23c15c86d68e5087fb4828bcac0045776fe84edbe39165032efb2"
        hex"4123405a7e321b028b338f31b6d655f91a107f6d8727cd902af0636d0a8387f9b6d6b4a00323cb85ccf1b855e6cfd68cdcd50acd5de5363c89703d7e"
        hex"4c5a80a82b1e5060117d8753d93bd1c10e6e0f720ad4d26083f36820febdd43ac5e608f38de8f6088b228055c0be5dffed468466e674ff1ef1e79935"
        hex"e07f01de25f801870b4da85a0eb47a41";

    /// RSASSA-PSS signature over MESSAGE, SHA-256, 32-byte salt.
    bytes internal constant SIGNATURE =
        hex"808550fcb09b7201fdf90e65bf796c6ce3e51cde3cc2c1cf0cd35b5c67d3e0867590cfc5589e6dc8d47ac1b63c20cf151a3ab93b4cb98fee7ad5b53b"
        hex"57fab853eb9127fa80ac58d2d22b64b43e6fc60bbde2c9d233a5ecab6c2bf31e0d914987b38a38d680508f59ecd3aa25e38b82e022e57e3fbb2d0237"
        hex"95b6988951da3bf792146c27be9f00aca729326b60d8ac5a68411465be153b2670a8b6b2c2576f526eebcd4b5688b412d3bfb4f934974d9bb60b3625"
        hex"95be7088290761a9121a0b4304ed74f6a140f8fb6976fd57ed656510242e16a7344342c2f1e58012c2506a2eb79482ddfcac2ea99dac6167a4198775"
        hex"52d2daa1951495001a476f9a1012e84b";

    /// The signed attributes stand-in - arbitrary bytes, signed for real.
    bytes internal constant MESSAGE =
        hex"4943414f2074657374207369676e65642061747472696275746573202d2064657465726d696e697374696320766563746f7220666f72204352534150"
        hex"53535369676e6572";

    uint256 internal constant EXPONENT = 65537;

    function setUp() public {
        signer = new CRSAPSSSigner();
        signer.__CRSAPSSSigner_init(EXPONENT, CRSAPSSSigner.HF.sha256);
    }

    /// The baseline: a signature openssl accepts, this contract must accept.
    function test_VerifiesAGenuineRsaPssSignature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIGNATURE, MODULUS),
            "a signature openssl verified was rejected"
        );
    }

    /// A flipped bit anywhere in the signature must not verify. Without this the suite would pass
    /// against an implementation that returned true unconditionally.
    function test_RejectsATamperedSignature() public view {
        bytes memory tampered_ = SIGNATURE;
        tampered_[0] = bytes1(uint8(tampered_[0]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(MESSAGE, tampered_, MODULUS),
            "a tampered signature verified"
        );
    }

    /// The signature must be bound to THESE attributes - the property the whole certificate chain
    /// rests on, since the attributes carry the DSC key that gets admitted.
    function test_RejectsADifferentMessage() public view {
        bytes memory other_ = MESSAGE;
        other_[0] = bytes1(uint8(other_[0]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(other_, SIGNATURE, MODULUS),
            "the signature verified against different attributes"
        );
    }

    /// A different CSCA key must not verify, or membership of the ICAO master list would be
    /// decorative.
    function test_RejectsADifferentKey() public view {
        bytes memory otherKey_ = MODULUS;
        otherKey_[10] = bytes1(uint8(otherKey_[10]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(MESSAGE, SIGNATURE, otherKey_),
            "the signature verified under a different key"
        );
    }

    /// The exponent is contract state, not caller input, so a wrong one must simply fail closed.
    function test_RejectsUnderTheWrongExponent() public {
        CRSAPSSSigner other_ = new CRSAPSSSigner();
        other_.__CRSAPSSSigner_init(3, CRSAPSSSigner.HF.sha256);

        assertFalse(
            other_.verifyICAOSignature(MESSAGE, SIGNATURE, MODULUS),
            "verified under an exponent the key was not generated with"
        );
    }

    /// Selecting a different hash must reject a SHA-256 signature - the switch has to be real.
    function test_TheHashFunctionSwitchIsLoadBearing() public {
        CRSAPSSSigner sha384_ = new CRSAPSSSigner();
        sha384_.__CRSAPSSSigner_init(EXPONENT, CRSAPSSSigner.HF.sha384);

        assertFalse(
            sha384_.verifyICAOSignature(MESSAGE, SIGNATURE, MODULUS),
            "a SHA-256 signature verified under the SHA-384 parameters"
        );
    }
}
