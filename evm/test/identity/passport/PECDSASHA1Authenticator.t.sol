// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PECDSASHA1Authenticator} from '../../../src/identity/passport/authenticators/PECDSASHA1Authenticator.sol';

/*
 * ECDSA Active Authentication over brainpoolP256r1 (sec. 2.18v, second site).
 *
 * This contract had the SAME low-s defect as the certificate signers: it handed the signature
 * straight to a library that accepts only the lower half of the curve, while passports do not
 * normalise. Roughly half of all genuine AA responses were refused.
 *
 * Both vectors are real signatures from one brainpoolP256r1 key over SHA-1 of the challenge, chosen
 * so one has HIGH s and the other LOW - the fix must repair the refused half without disturbing the
 * canonical one.
 */
contract PECDSASHA1AuthenticatorTest is Test {
    PECDSASHA1Authenticator internal auth;

    bytes internal constant CHALLENGE = hex'aabbccddeeff0011';

    uint256 internal constant X = 0xa0b3b4af8026961e1e8fa6d7e43218513d036bfb49937b7a9484219a2b8ff048;
    uint256 internal constant Y = 0x879de0cef50a489ca54d792b4640e31d59c487099e01459652bee8bef26820fc;

    /// s > n/2 - the half that was refused outright.
    uint256 internal constant HI_R = 0x69a49bf89e191030202c7780423b1fc091e80c7a68be1a0c730514675aee123d;
    uint256 internal constant HI_S = 0x861ab9baabd2b84be3f38f0cf73ee1f7e202ffbc8265b748439192bbaebafc89;

    /// s < n/2 - already canonical.
    uint256 internal constant LO_R = 0x6b3416f179c74b162f6bb6ba5b8aefdff705d56787fb79f41c05d99268f775b7;
    uint256 internal constant LO_S = 0x4250a23fa28399441e45cbadf221d5753377c74986d0b2cbd437110fd4aa5723;

    function setUp() public {
        auth = new PECDSASHA1Authenticator();
    }

    function test_AuthenticatesAGenuineHighSResponse() public view {
        assertTrue(
            auth.authenticate(CHALLENGE, HI_R, HI_S, X, Y),
            "a genuine high-s AA response was refused - about half of real ones look like this"
        );
    }

    function test_AuthenticatesAGenuineLowSResponse() public view {
        assertTrue(
            auth.authenticate(CHALLENGE, LO_R, LO_S, X, Y),
            "normalisation broke an already-canonical response"
        );
    }

    function test_RejectsADifferentChallenge() public view {
        assertFalse(
            auth.authenticate(hex'1100ffeeddccbbaa', HI_R, HI_S, X, Y),
            "authenticated against another challenge - replay would be free"
        );
    }

    function test_RejectsATamperedSignature() public view {
        assertFalse(auth.authenticate(CHALLENGE, HI_R ^ 1, HI_S, X, Y), "tampered r authenticated");
        assertFalse(auth.authenticate(CHALLENGE, HI_R, HI_S ^ 1, X, Y), "tampered s authenticated");
    }

    function test_RejectsADifferentKey() public view {
        assertFalse(auth.authenticate(CHALLENGE, HI_R, HI_S, X ^ 1, Y), "authenticated under another key");
    }

    function test_RejectsAZeroSignature() public view {
        assertFalse(auth.authenticate(CHALLENGE, 0, 0, X, Y), "r = s = 0 authenticated");
    }
}
