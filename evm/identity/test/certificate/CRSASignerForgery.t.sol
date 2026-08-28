// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CRSASigner} from '../../contracts/certificate/signers/CRSASigner.sol';

/*
 * CRSASigner ACCEPTS A SIGNATURE NOBODY SIGNED (sec. 2.18u).
 *
 * `verifyICAOSignature` decrypts with the public exponent and compares only the LAST 32 bytes of
 * the result against sha256(attributes). It never checks the PKCS#1 v1.5 padding - not the
 * `0x00 01 FF..FF 00` frame, not the DigestInfo. Everything to the left of those 32 bytes is
 * ignored entirely.
 *
 * With a low exponent that is not a weakness, it is a forgery. Cubing is a bijection on odd
 * residues mod 2^k, so for any target digest H one can Hensel-lift a root of s^3 = H (mod 2^256).
 * That s is ~255 bits, so s^3 is ~765 bits - far below a 2048-bit modulus, so modexp performs NO
 * reduction and returns the plain cube, whose last 32 bytes are H by construction.
 *
 * The vector below was built with no private key. `e3.pem`'s secret half was never used.
 */
contract CRSASignerForgeryTest is Test {
    CRSASigner internal signer;

    bytes internal constant MODULUS =
        hex"d02944b2aed4038b3f0563eb2a3897d000dc46b47893278f49d434fb47ed113ebc8c2a956e7914d975984cc81626327d172a1006e99fcf60b83a6954"
            hex"e6d5a574959523a40cbbcc5712c1910cfe5c8ef465aeb134046c55e08943af08c235c145201b0e3ec811bb330bfffb99fe4fce78d86b2b50fbf50094"
            hex"84631db46bdefcc7a39e8eaf10a49d51b4cd61cd692870655253676b3fe979e83f119ecb9f16266b050fe5b18569262adbcee0d256b6dd61e7243cfe"
            hex"11144fe099b0bd2abc3bccf83da2cb1622db2a33fb4814b7e8020a30bfcba93aab44c7b63bff047c969bfdff5daa70ba49c355dc28b827df240f0d2e"
            hex"b7fd4b59586c9d516460d4d1c5b02dd9";
    /// NOT a signature. A cube root of the target digest modulo 2^256.
    bytes internal constant FORGED =
        hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            hex"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000007e54e856f83a7aa4012039d5bf231c62"
            hex"b06ce26382c97d134e59e2aa2b3c40a3";
    bytes internal constant REAL_E3 =
        hex"34271fc85ac6c68fdb2b87c5241ef0e493e563cd9002211319a0e7c5044874c4930f793f466e71bbe025e790bcaf3fa436541bf5b36879f099a5a6ab"
            hex"163309c1cfa7ed5294125a76bf81028e4ff7141c29757714bc68bc72438d8119e957f44a17442d476f224b341697b051a7efc458cafe4ea077c195ac"
            hex"28b2018d8730b5dbed7a974fcaac0dc2c59dec18f7964f1445cd2b567ab0852b3c3ede725c24eaaabd8d54bb6dd9e5991d721e911da54f8203272136"
            hex"eb62ecfba1507a381f4e5a23cd5489c400bd6e9ed0e70d2be1baa122350bcb3774999a8ac5ae11bfe8321faafbbf279fecaad1143cbe2f3f24061d03"
            hex"dc17735650f6830d0fc8ecd5583e3faa";
    bytes internal constant MODULUS_65537 =
        hex"bd6f2fa0347e2218d066897374ec2cbb5b6742fb000103247724963ec0363a3f052603e9a9f4d3d65fd13690ed97bad37bb872b4ac84c9e1840c49bd"
            hex"1df854a2e3d93cb27fa0e20f4ac515a5710548d7170828c3cdd5fe438e22b29272837ac92e785b253c25fd25061ef6ee3d6698f78933fdb7cf39f0d9"
            hex"3e293ffde9f6b88e530b643004e626a7d51f10940695faade4791c00640dd2e3f203f0ed0cc03500969e580fad1cf1057b10c83731931e37855961b9"
            hex"037a4573d29b59c3648de6e6091c5d431434ec22a127cc7537ff93b3a3f8b6735006ccd86e8e6634f55cdd823db8c6a3d48b4186cc6bcfa7079981e7"
            hex"be2dbe1004eafdbb9945eaa67cc581d7";
    bytes internal constant REAL_65537 =
        hex"42fcbb91e3f7b36915f68e86e784ee224f775c3d30c93c68049cae45373d5f9f1f0167826d658fda200d5889abd04c3aac1de865af2bf4cf8493e690"
            hex"8ab99cd43b08bd71272fc8167f8665322f4c7f5b1cffaedd74c3426ef4de69a6ddad123682e46119dbdbb48112df16eace900fe6974042a7ac4bfad4"
            hex"4d67e13d1ab53ae8448af5727fe1eac5f79b5aea818f074843d72574d2863285366d95e86781f7c2856fb48da77eda4ddd64033957db291e11cfebb9"
            hex"e0c1501a3da53a56f931174228d69c7d1d2bed106d184c131ced862d8a50fd1176db51e5a41ec59624e87b37d507c7bb0df0debca05d49c3a893dc34"
            hex"e6d80265f8449afa830e2a10c096f1dd";
    bytes internal constant REAL_SHA1 =
        hex"ad1b6e01fa91662dbb34cfeb0c1f4e3754a75cd34aa5dfc535c7117efc8c20010b41681753a40e57b1d87ea7ae4c092cc7ee9b9bfa4e8c1d4c4f1f24"
            hex"99c3a906a612efa474a18713367109207bd44092826cb3dd241e58e09d873c0d59fb5e4f826107229944aa708e508609a7071ea2cfb0b3f6d2463cf8"
            hex"4598ab82cb551902bfe52b690c8762f68c71b051cc324625f56c06a70a6352244451320a7e420af1b4fb11d35bfcc7537f1356fa83bbb6ab2596bfc9"
            hex"4e443813703007118c3b0d31662bf32c5869c7042952a8271fc10deb62450b2a3e3f6bbc9231bf0432687e18ab8eab3a74a38eae5d520f8749a67900"
            hex"04df32b5577a41d093f10fe17ac1198d";
    bytes internal constant REAL_SHA512 =
        hex"000f72b7c0b1cafe6bf3f31153a0b139ee36119a5bbfe48e720aa61edcceb13dacd49880513339cda5bb5bef2fb94f118dfa7e669c9213d9fb0f36b7"
            hex"e6630204ae72dd40515168c2537f26ff1e7346ffcba45a729801252940a24fb58bb4a60371215021e68cf3a18fd1416c41cec7daed3f1defc2dcadbc"
            hex"95d034e83975f0f435d4d8f942ec2f61220981d91a1758bfa26740c9541388e587793d475aacd9efc3609f17a537af512893966a5d1f9f0f088e840c"
            hex"389b56af7781f5511214f91660ec8cfcce242d27b568e8c958f7079cb879f22f9da088085016c9da36ec48d0095c27687a69cd4a71623ed5266e92c6"
            hex"a37f2bfb0e03fcb00b31b0d4ae77363e";
    bytes internal constant MESSAGE = hex"4943414f207369676e65642061747472696275746573207468652061747461636b6572206e65766572206861642061207369676e617475726520666f72202330";

    function setUp() public {
        signer = new CRSASigner();
        signer.__CRSASigner_init(3, CRSASigner.HF.sha256);
    }

    /*
     * THE FORGERY IS NOW REFUSED. Before the padding check landed this returned TRUE.
     *
     * What it would buy: `Registration2.registerCertificate` verifies the CSCA signature over a
     * DSC's signed attributes and then admits the DSC key into `certificatesSmt` - the tree
     * `register_identity` proves membership in. Forging that signature means inserting a signer key
     * of your own choosing, and from there signing your own SODs and enrolling fabricated
     * identities through the permissionless path.
     *
     */
    function test_RejectsTheForgedSignature() public view {
        assertFalse(
            signer.verifyICAOSignature(MESSAGE, FORGED, MODULUS),
            "a value nobody signed verified as a CSCA signature"
        );
    }

    /// AND THE FIX MUST NOT BREAK REAL SIGNATURES - the failure mode that would matter far more,
    /// since rejecting genuine CSCAs is the censorship outcome sec. 2.18s already nearly shipped.
    /// Both signatures below were produced by openssl with the matching private key and verified
    /// by openssl before being pasted here.
    function test_StillVerifiesAGenuineSignatureUnderExponentThree() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, REAL_E3, MODULUS),
            "a genuine e=3 signature was rejected"
        );
    }

    function test_StillVerifiesAGenuineSignatureUnderExponent65537() public {
        CRSASigner s65537_ = new CRSASigner();
        s65537_.__CRSASigner_init(65537, CRSASigner.HF.sha256);

        assertTrue(
            s65537_.verifyICAOSignature(MESSAGE, REAL_65537, MODULUS_65537),
            "a genuine e=65537 signature was rejected"
        );
    }

    /*
     * THE OTHER TWO HASH BRANCHES, which the fix rewrote and nothing had exercised.
     *
     * A padding fix that silently broke SHA-1 or SHA-512 would reject every CSCA using them - the
     * censorship failure of sec. 2.18s, reintroduced by the repair for sec. 2.18u. Both signatures
     * are genuine, produced and verified by openssl before use.
     *
     * SHA-1 matters in practice: plenty of long-lived CSCA certificates still use it.
     */
    function test_StillVerifiesAGenuineSha1Signature() public {
        CRSASigner s1_ = new CRSASigner();
        s1_.__CRSASigner_init(65537, CRSASigner.HF.sha1);

        assertTrue(
            s1_.verifyICAOSignature(MESSAGE, REAL_SHA1, MODULUS_65537),
            "a genuine SHA-1 signature was rejected"
        );
    }

    function test_StillVerifiesAGenuineSha512Signature() public {
        CRSASigner s512_ = new CRSASigner();
        s512_.__CRSASigner_init(65537, CRSASigner.HF.sha512);

        assertTrue(
            s512_.verifyICAOSignature(MESSAGE, REAL_SHA512, MODULUS_65537),
            "a genuine SHA-512 signature was rejected"
        );
    }

    /// And each branch must still REJECT a signature made under a different hash - otherwise the
    /// DigestInfo check is decorative and algorithm substitution is possible.
    function test_EachHashBranchRejectsAnotherHashesSignature() public {
        CRSASigner s1_ = new CRSASigner();
        s1_.__CRSASigner_init(65537, CRSASigner.HF.sha1);
        assertFalse(
            s1_.verifyICAOSignature(MESSAGE, REAL_SHA512, MODULUS_65537),
            "the SHA-1 branch accepted a SHA-512 signature"
        );

        CRSASigner s512_ = new CRSASigner();
        s512_.__CRSASigner_init(65537, CRSASigner.HF.sha512);
        assertFalse(
            s512_.verifyICAOSignature(MESSAGE, REAL_SHA1, MODULUS_65537),
            "the SHA-512 branch accepted a SHA-1 signature"
        );
    }

    /// A tampered genuine signature must fail - so the test above is not passing for free.
    function test_RejectsATamperedGenuineSignature() public view {
        bytes memory t_ = REAL_E3;
        t_[200] = bytes1(uint8(t_[200]) ^ 0x01);

        assertFalse(signer.verifyICAOSignature(MESSAGE, t_, MODULUS), "a tampered signature verified");
    }

    /// The forgery is bound to the digest it was built for, which is what makes it a forgery of a
    /// SPECIFIC document rather than a fluke.
    function test_TheForgeryIsBoundToItsOwnMessage() public view {
        bytes memory other_ = MESSAGE;
        other_[0] = bytes1(uint8(other_[0]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(other_, FORGED, MODULUS),
            "the forgery verified against a different message too"
        );
    }
}
