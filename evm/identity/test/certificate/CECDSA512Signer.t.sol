// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CECDSA512Signer} from '../../contracts/certificate/signers/CECDSA512Signer.sol';

/// The 512-bit third of sec. 2.18v, brainpoolP512r1 + SHA-512. Both vectors genuine, from openssl.
contract CECDSA512SignerTest is Test {
    CECDSA512Signer internal signer;

    bytes internal constant PUBKEY =
        hex"9bf225b5f554f5e4d5a586a08c56d0874093d43f58e1f4555f1d2036fbf3f1b3"
        hex"dc45df63fa2960f10a5a2047c7f177a7231f561088b6ca23450882c9911e17ba"
        hex"1f0670f958984998e6e36b9db9ed0ee3e24d097f09cc7449e6508bca29110e9d"
        hex"bc07c99194c524a05a12be4b731062ede49489870ff0c2410d4005cd3df1a8f2";
    /// s > n/2 - refused outright before EcdsaS.normalize.
    bytes internal constant SIG_HIGH_S =
        hex"05f993f24bceac08a2c2f1483b1cab8b410de5240535c26527020dd5176e4e40"
        hex"32257e5e958642e1a31a1edb5246e9e1bc7b98ece9634e5212086928dd39beaf"
        hex"9bfe81bfa1f6db71faf35eb12e0e0bf6b6308bb6464166d7f4f08b2419c22581"
        hex"1b6765441b3e51040c5af8d71ba8205a5f7a2909c2726ed91c5ad3e04ff0ee77";
    bytes internal constant SIG_LOW_S =
        hex"1705313eb384c97ba23fb47909681f3e02ffdbd827cbb36cb61b8b431beb806b"
        hex"e5f96a5d0e5c3bdda8b055f595aba9d727c3321247f773f8d87e57fdb3051c33"
        hex"3c74cb225e6efa1dc19c9872457d199a14d17cd472e04967254bda3460b86cd5"
        hex"dead4494e0ed51e6b2cc4d2a375dec42b810db65a82fc6badedae42b10d7902f";
    bytes internal constant MESSAGE =
        hex"4943414f207369676e6564206174747269627574657320746865206174746163"
        hex"6b6572206e65766572206861642061207369676e617475726520666f72202330";

    function setUp() public {
        signer = new CECDSA512Signer();
    }

    function test_VerifiesAGenuineHighSSignature() public view {
        assertTrue(
            signer.verifyICAOSignature(MESSAGE, SIG_HIGH_S, PUBKEY),
            "a genuine high-s signature was rejected"
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

    function test_RejectsAZeroSignature() public view {
        assertFalse(signer.verifyICAOSignature(MESSAGE, new bytes(128), PUBKEY), "r = s = 0 accepted");
    }
}
