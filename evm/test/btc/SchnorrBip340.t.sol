// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MuSig2Agg} from "../../src/imports/MuSig2Agg.sol";

/// @notice (E128) BIP-340 verification, checked against the OFFICIAL vectors from
///         `bitcoin/bips/bip-0340/test-vectors.csv` — not against anything this repo generated.
///
///         ⚠️ WHY THAT DISTINCTION IS LOAD-BEARING: a vector produced by signing with our own
///         code and verifying with our own code proves only that the two agree. It would confirm
///         a subtly wrong challenge hash, a wrong lift_x parity rule, or a wrong tagged-hash tag
///         just as happily as a correct one. These bytes come from the BIP.
///
///         ⚠️ AND WHY THE LIBRARY IS HAND-WRITTEN (§E128-r2): no EVM Schnorr library verifies
///         BITCOIN signatures. Scribe, ERC-7816 and crysol share a lineage that is NOT BIP-340,
///         so importing one would verify the wrong scheme — the failure being that valid Bitcoin
///         signatures are rejected and, worse, the shape of what IS accepted is not BIP-340 at all.
contract SchnorrBip340Test is Test {
    function _check(bytes32 pk, bytes32 r, bytes32 s, bytes32 m) internal view returns (bool) {
        return MuSig2Agg.schnorrVerify(pk, r, s, m);
    }

    /// Vector 0 — secret key 3, message all-zero.
    function test_vector0() public view {
        assertTrue(_check(
            0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9,
            0xE907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215,
            0x25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0,
            0x0000000000000000000000000000000000000000000000000000000000000000
        ), "BIP-340 vector 0");
    }

    /// Vector 1 — the classic pi-digits message.
    function test_vector1() public view {
        assertTrue(_check(
            0xDFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659,
            0x6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341,
            0x8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A,
            0x243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89
        ), "BIP-340 vector 1");
    }

    /// Vector 2 — non-trivial aux_rand.
    function test_vector2() public view {
        assertTrue(_check(
            0xDD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8,
            0x5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1B,
            0xAB745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7,
            0x7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C
        ), "BIP-340 vector 2");
    }

    /// Vector 3 — all-ones message, exercising the top of the range.
    function test_vector3() public view {
        assertTrue(_check(
            0x25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517,
            0x7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC,
            0x97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        ), "BIP-340 vector 3");
    }

    /// Vector 4 — public key with no known secret key, and an R.x with many leading zeros.
    /// Included precisely because a small R.x is where a sloppy fixed-width comparison breaks.
    function test_vector4() public view {
        assertTrue(_check(
            0xD69C3509BB99E412E68B0FE8544E72837DFA30746D8BE2AA65975F29D22DC7B9,
            0x00000000000000000000003B78CE563F89A0ED9414F5AA28AD0D96D6795F9C63,
            0x76AFB1548AF603B3EB45C9F8207DEE1060CB71C04E80F593060B07D28308D7F4,
            0x4DF3C3F68FCC83B27E9D42C90431A72499F17875C81A599B566C9889B9696703
        ), "BIP-340 vector 4");
    }

    /// ⚠️ THE CONTROL. Every assertion above is positive, and a verifier hard-wired to `return
    /// true` would pass all five. Flipping one bit of the message must flip the result.
    function test_aTamperedMessageIsRejected() public view {
        assertFalse(_check(
            0xDFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659,
            0x6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341,
            0x8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A,
            0x243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C88 // last byte 9→8
        ), "a tampered message must not verify");
    }

    /// A signature from one vector must not verify against another vector's key.
    function test_crossVectorSignatureIsRejected() public view {
        assertFalse(_check(
            0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9, // key from vector 0
            0x6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341, // sig from vector 1
            0x8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A,
            0x243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89
        ), "vector 1's signature must not verify under vector 0's key");
    }

    /// Malformed inputs are INVALID SIGNATURES, not errors — BIP-340 says so, and reverting
    /// would make a bad signature indistinguishable from a bad call at the call site.
    function test_outOfRangeAndOffCurveReturnFalseRatherThanReverting() public view {
        bytes32 pk = 0xDFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659;
        // s >= n
        assertFalse(_check(pk, bytes32(uint256(1)),
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141, bytes32(0)), "s = n");
        // r >= p
        assertFalse(_check(pk,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
            bytes32(uint256(1)), bytes32(0)), "r = p");
        // x = 5 is the first off-curve x (x = 1 IS on the curve: y^2 = 8, a quadratic residue).
        assertFalse(_check(bytes32(uint256(5)), bytes32(uint256(1)), bytes32(uint256(1)), bytes32(0)),
            "off-curve key");
    }
}
