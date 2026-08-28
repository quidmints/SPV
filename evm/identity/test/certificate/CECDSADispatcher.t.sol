// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CECDSADispatcher} from '../../contracts/certificate/dispatchers/CECDSADispatcher.sol';

/*
 * The ECDSA dispatcher on the DSC-admission path (sec. 2.18x).
 *
 * Shares `AbstractCDispatcher`'s extraction with the RSA one, but derives the certificate key
 * DIFFERENTLY: `Bytes2Poseidon.hash512` for keys under 128 bytes and `hash1024` at or above. That
 * branch is the whole difference between the two dispatchers and nothing exercised it.
 *
 * The key it derives becomes a `certificatesSmt` leaf - the tree `register_identity` proves
 * membership in - so a collision there would let one DSC's admission stand in for another's.
 */
contract CECDSADispatcherTest is Test {
    CECDSADispatcher internal small; // 64-byte key -> hash512 branch
    CECDSADispatcher internal large; // 128-byte key -> hash1024 branch

    bytes internal constant PREFIX = hex'0342';

    function setUp() public {
        small = new CECDSADispatcher();
        small.__CECDSADispatcher_init(address(0x51), 64, PREFIX);

        large = new CECDSADispatcher();
        large.__CECDSADispatcher_init(address(0x51), 128, PREFIX);
    }

    function _attributes(uint256 len_, uint256 keyOffset_) internal pure returns (bytes memory out_) {
        out_ = new bytes(len_);
        for (uint256 i = 0; i < len_; ++i) {
            out_[i] = bytes1(uint8((i % 251) + 1));
        }
        out_[keyOffset_ - 2] = PREFIX[0];
        out_[keyOffset_ - 1] = PREFIX[1];
    }

    function test_ExtractsAP256SizedKey() public view {
        bytes memory sa_ = _attributes(200, 16);
        assertEq(small.getCertificatePublicKey(sa_, 16).length, 64);
    }

    function test_ExtractsAP512SizedKey() public view {
        bytes memory sa_ = _attributes(300, 16);
        assertEq(large.getCertificatePublicKey(sa_, 16).length, 128);
    }

    /*
     * THE TOP BYTE OF EACH 32-BYTE COORDINATE IS DISCARDED, DELIBERATELY (sec. 2.18ab).
     *
     * `Bytes2Poseidon.hash512/hash1024` reduce each 32-byte word `% 2 ** 248`, dropping its most
     * significant byte so the value fits a BN254 field element. The CIRCUIT does the same: the
     * ECDSA branch of `extract_pk_hash` accumulates `EC_FIELD_SIZE - DIFF` bits, i.e. the LOW 248,
     * discarding the identical byte. **They agree, which is what matters** - a mismatch would mean
     * no ECDSA DSC ever verified.
     *
     * This test exists because the first version of the one below flipped byte 0 of the key and
     * asserted the derived key must change. It did not, and that looked like a collision bug. It is
     * a documented consequence of the field reduction, mirrored on both sides, and NOT reachable:
     * an attacker would need a curve point colliding in the low 248 bits AND its private key, which
     * a colliding x-coordinate does not hand them.
     */
    function test_TheTopByteOfEachCoordinateIsIgnored() public view {
        bytes memory a_ = _attributes(300, 16);
        bytes memory b_ = _attributes(300, 16);
        b_[16] = bytes1(uint8(b_[16]) ^ 0x80); // byte 0 of the key - the discarded one

        assertEq(
            small.getCertificateKey(small.getCertificatePublicKey(a_, 16)),
            small.getCertificateKey(small.getCertificatePublicKey(b_, 16)),
            "the top byte is NOT being discarded - the contract no longer mirrors the circuit"
        );
    }

    /// Both branches must be deterministic and key-dependent - a collision in the RETAINED bits
    /// would let one admitted DSC stand in for another.
    function test_BothHashBranchesAreDeterministicAndKeyDependent() public view {
        bytes memory a_ = _attributes(300, 16);
        bytes memory b_ = _attributes(300, 16);
        b_[17] = bytes1(uint8(b_[17]) ^ 0x01); // byte 1 - retained

        for (uint256 i = 0; i < 2; ++i) {
            CECDSADispatcher d_ = i == 0 ? small : large;
            uint256 ka_ = d_.getCertificateKey(d_.getCertificatePublicKey(a_, 16));
            uint256 kb_ = d_.getCertificateKey(d_.getCertificatePublicKey(b_, 16));

            assertEq(ka_, d_.getCertificateKey(d_.getCertificatePublicKey(a_, 16)), 'not deterministic');
            assertTrue(ka_ != kb_, 'two different keys collided');
            assertTrue(ka_ != 0, 'a zero key would collide with an empty SMT slot');
        }
    }

    /// The two branches are different functions over the same bytes, so the same 128-byte key must
    /// not derive the same certificate key under both - otherwise the size switch is meaningless.
    function test_TheTwoBranchesAreDistinct() public view {
        bytes memory sa_ = _attributes(300, 16);
        bytes memory key_ = large.getCertificatePublicKey(sa_, 16);

        assertTrue(
            small.getCertificateKey(key_) != large.getCertificateKey(key_),
            'hash512 and hash1024 produced the same value for one key'
        );
    }

    /// sec. 2.18m's bound must hold through this dispatcher too.
    function test_RefusesAKeyRunningPastTheAttributes() public {
        bytes memory sa_ = _attributes(80, 70);

        vm.expectRevert(bytes('X509: key runs past the signed attributes'));
        small.getCertificatePublicKey(sa_, 70);
    }
}
