// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PRSASHAAuthenticator} from '../../contracts/passport/authenticators/PRSASHAAuthenticator.sol';

/*
 * Active Authentication, ISO/IEC 9796-2 Scheme 1 (sec. 2.18y).
 *
 * NOT CURRENTLY REACHABLE: AA needs DG15, and our `register_identity` variant is built with
 * `DG15_LEN = 0`. Tested and fixed anyway, because "unreachable" here is not a property of the
 * code - it is a property of one generic parameter in one circuit, and a TD3 variant would make it
 * live without anyone revisiting this file.
 *
 * THE VECTOR IS A REAL SIGNATURE. The encoded message was assembled to the standard -
 * `0x6A || M1 || SHA1(M1 || challenge) || 0xBC` - and raised to `d` with the private key, then
 * checked against `e` before being pasted here. Nothing about it is self-referential to this
 * contract.
 */
contract PRSASHAAuthenticatorTest is Test {
    PRSASHAAuthenticator internal auth;

    bytes internal constant MODULUS =
        hex"bd6f2fa0347e2218d066897374ec2cbb5b6742fb000103247724963ec0363a3f"
        hex"052603e9a9f4d3d65fd13690ed97bad37bb872b4ac84c9e1840c49bd1df854a2"
        hex"e3d93cb27fa0e20f4ac515a5710548d7170828c3cdd5fe438e22b29272837ac9"
        hex"2e785b253c25fd25061ef6ee3d6698f78933fdb7cf39f0d93e293ffde9f6b88e"
        hex"530b643004e626a7d51f10940695faade4791c00640dd2e3f203f0ed0cc03500"
        hex"969e580fad1cf1057b10c83731931e37855961b9037a4573d29b59c3648de6e6"
        hex"091c5d431434ec22a127cc7537ff93b3a3f8b6735006ccd86e8e6634f55cdd82"
        hex"3db8c6a3d48b4186cc6bcfa7079981e7be2dbe1004eafdbb9945eaa67cc581d7";
    bytes internal constant SIGNATURE =
        hex"2b49646be3f448bf26bf157429a962d186722a20023e786a3dc98b7bbc4fac50"
        hex"3db524a96799d83b4dd1138f2a87c99ac22036674b8312c24420bb352fbca29f"
        hex"722af9d589d7ddbb4a448431b76e990e6d07712a8b5ee3ed48ce4119b89aa384"
        hex"6a069c249f533fe2227641c84c511c3742fd219dfcdcaaf897d1982423350d6d"
        hex"06b4ec0b1d01d03e864b2f893df8937b55cd87c3cd80f67dd18423ac0b2bba2d"
        hex"8673697623d84d14fb37a5f13e483b8019b8d976f399e3748d7a7f157ff929c7"
        hex"4dcc6676b5e734112abdfe3af31de03fafa59df6b7c8ccb3168219d7fcec4646"
        hex"9eb8d17669ebbba2191b92f6b1351470e43772f99cc9171398ae2124c9716ba5";
    bytes internal constant CHALLENGE = hex"0102030405060708";

    /*
     * THE THREE FRAME VECTORS. Each is a REAL signature under the same private key, with a correct
     * `M1` and a correct `SHA1(M1 || challenge)` - only the ISO 9796-2 framing differs. Before the
     * fix all three authenticated, because the header was skipped unread and the trailer stripped
     * unread.
     */
    /// Header 0x00 instead of 0x6A / 0x4A.
    bytes internal constant SIG_BAD_HEADER =
        hex"3775b4f4afc9082d153dee63d6e3304c1d8024f154c2340182f49ff6fc817034"
        hex"e442f46a3f24c49852085babb96a0907c65aa8af52cde9bdf577148984622e83"
        hex"cf291dd77a6630048b207587d99a5f8120893b5b14e42cb1c0d480fe58f7c17d"
        hex"3cd4c8477185825cd86e86fe3092b505ca746a75f7c8b1da70851765b6fdf9a5"
        hex"bc4968fe4dd2b1ecff8d4c9818c9be5ea3263696c1588ec99415cd7d2b6d7363"
        hex"28ba61e8938894681247bfb9ccc61661e617e8ea4c166f044c10dfb85bbe6ac7"
        hex"9d366f73920efc5ef0e5c2843b89043912cf722082436bb5bb096fd6bc7971df"
        hex"0bd88b36fc5c542cc69a6d72ec56b90ab9f3fd795824d85be00ab9021b7406d7";
    /// Trailer 0xAA instead of 0xBC.
    bytes internal constant SIG_BAD_TRAILER =
        hex"2c1aeb7d2f7ba2f2dc6aeedef04f249252075181e0dcade00218dad4a636e962"
        hex"318d3e188ee07932c944de163ce1ec4fd67f27ab33645570b69db1361c55fc8e"
        hex"5090d9d7d4871f18f8781aaf60913a427157a548edc8a211e3231803864e8def"
        hex"d9181773b6b98db875df0c9a2f397a62d4c2607d67028e59e685b6615ed71a74"
        hex"725a90ca21141d2802a97b4a4380d1138bda9a5dbdb1ce9be78cc47e6936c3af"
        hex"3259dd825da029f0658aa68d3ae0c2894c6aa6e7e2839be36d567d6e15c1081e"
        hex"0d3eed8e3931fcbe024ebcc94f0268af4fcfb7b1014fde30c6262c027a765ab2"
        hex"9598f4f55deb65c232064bba6093f8849625f10597ba50c6eaa8461e562d6a36";
    /// Header 0x4A - the LEGAL total-recovery variant, which must still be accepted.
    bytes internal constant SIG_ALT_HEADER =
        hex"48a41ac8baffd8f6b8bb6ff9081e5e876f606524d945ca6d9096fdbe599c6152"
        hex"8f8b0141953f8bec613c8c83aaef9dd31d07a744df3634f2b76487477668a4a3"
        hex"ac0ea22190dfd708c1b1131920e5a5de2504318d3b7047ebf9cee109c0819fc7"
        hex"55c59de5f46369d44d0e4d49ff1b5ad1ef6750d2c1161fab78edb09279f9a3d9"
        hex"cb2643aecd9eb7313c4aac4ee8eabd9fff0ef451d18987334147e471f90a412e"
        hex"05e06520f9610b70d7766d65b98a147d114f31da05338f0461ce98cc0e1d5583"
        hex"ce13127dbfaaf3ca95e58f0b721516f15ea240697346b10a61afa8e69442c80d"
        hex"53be525ea7e4da727f5131b614dab5219356bcd1f2650b745370ebe3ce978233";

    function setUp() public {
        auth = new PRSASHAAuthenticator();
        auth.__PRSASHAAuthenticator_init(65537, true);
    }

    function test_AuthenticatesAGenuineSignature() public view {
        assertTrue(auth.authenticate(CHALLENGE, SIGNATURE, MODULUS), "a genuine AA signature failed");
    }

    function test_RejectsADifferentChallenge() public view {
        assertFalse(
            auth.authenticate(hex"0807060504030201", SIGNATURE, MODULUS),
            "the signature authenticated against another challenge - replay would be free"
        );
    }

    function test_RejectsATamperedSignature() public view {
        bytes memory t_ = SIGNATURE;
        t_[0] = bytes1(uint8(t_[0]) ^ 0x01);
        assertFalse(auth.authenticate(CHALLENGE, t_, MODULUS), "a tampered signature authenticated");
    }

    function test_RejectsADifferentKey() public view {
        bytes memory k_ = MODULUS;
        k_[5] = bytes1(uint8(k_[5]) ^ 0x01);
        assertFalse(auth.authenticate(CHALLENGE, SIGNATURE, k_), "authenticated under another key");
    }

    function test_RejectsAnInvalidHeaderByte() public view {
        assertFalse(
            auth.authenticate(CHALLENGE, SIG_BAD_HEADER, MODULUS),
            "a block with no ISO 9796-2 header authenticated"
        );
    }

    function test_RejectsAnInvalidTrailerByte() public view {
        assertFalse(
            auth.authenticate(CHALLENGE, SIG_BAD_TRAILER, MODULUS),
            "a block with the wrong trailer authenticated"
        );
    }

    /// 0x4A is legal - the fix must not narrow the standard to only one of its two headers.
    function test_AcceptsTheTotalRecoveryHeader() public view {
        assertTrue(
            auth.authenticate(CHALLENGE, SIG_ALT_HEADER, MODULUS),
            "the legal 0x4A total-recovery header was rejected"
        );
    }

    function test_RejectsEmptyInputs() public view {
        assertFalse(auth.authenticate(CHALLENGE, "", MODULUS), "empty signature accepted");
        assertFalse(auth.authenticate(CHALLENGE, SIGNATURE, ""), "empty modulus accepted");
    }
}
