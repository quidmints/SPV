// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CRSASigner} from '../../contracts/certificate/signers/CRSASigner.sol';

/*
 * ICAO'S OWN SIGNATURE OVER THE MASTER LIST, ENFORCED ON-CHAIN (sec. 2.18ci, 2026-08-03).
 *
 * WHY THIS IS THE POINT. sec. 2.18bv concluded that SOURCE-SIGNED DATA removes the trusted publisher
 * completely - stronger than TLS provenance, because a source signature is bound to the DATA rather
 * than to a session, so anyone can verify it at any time with no privileged position in the
 * connection. That design sat blocked because sec. 2.18bw could not confirm that either register we
 * had actually signed its data. **The ICAO Master List does**, and this test is that claim made
 * executable: the contract itself checks ICAO's signature, so a fabricated master list cannot be
 * anchored by anyone - not a postman, not a TSS committee, not an owner key.
 *
 * WHAT MAKES IT CHEAP, AND IT IS NOT OBVIOUS. The Master List is 876 KB, which cannot be hashed in
 * calldata or in-circuit. But CMS does not sign the content directly: it signs `signedAttributes`,
 * a 104-BYTE structure that CONTAINS `messageDigest = SHA-256(eContent)`. So one RSA-2048
 * verification over 104 bytes yields an ICAO-authenticated digest of the whole list, on-chain, for
 * ordinary gas.
 *
 * THE TRUST ANCHOR. This signer is certified by the UN CSCA whose
 * `sha256(modulus) = 19d41f41...a1f4`, which is itself certificate 0368 of the master list (0389 is
 * its rollover twin, sharing the key - which is why the KEY is the thing to pin, not the certificate
 * and not the name). That chain was verified BY SIGNATURE, because `signerCert.issuer` and
 * `cscaCert.subject` differ as bytes: **an implementation that chains by DN equality rejects the
 * real ICAO master list.**
 *
 * WHAT THIS DOES NOT YET DO. It authenticates the DIGEST of the list, not the derived Merkle root.
 * Tying `digest -> root` on-chain needs the 876 KB, so it is either chunked incremental hashing on
 * an L2 or a challenge window. Until then the root is AUDITABLE (anyone can re-derive it from a list
 * whose digest this contract has authenticated) rather than ENFORCED, and saying otherwise would
 * overstate it.
 */
contract IcaoMasterListSignatureTest is Test {
    CRSASigner internal signer;
    string internal fixture;

    function setUp() public {
        fixture = vm.readFile('test/fixtures/icao_master_list_signature.json');

        signer = new CRSASigner();
        signer.__CRSASigner_init(vm.parseJsonUint(fixture, '.signerExponent'), CRSASigner.HF.sha256);
    }

    function _b(string memory key_) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fixture, string.concat('.', key_));
    }

    /// THE CLAIM: this contract, unaided, accepts ICAO's signature over the real Master List.
    function test_icaoSignatureOverTheMasterListVerifiesOnChain() public view {
        assertTrue(
            signer.verifyICAOSignature(_b('signedAttrs'), _b('cmsSignature'), _b('signerModulus')),
            "ICAO's own signature over its published Master List was rejected"
        );
    }

    /// Non-vacuity: the signature covers the attributes, so any edit must break it. Without this a
    /// verifier that ignored its inputs would satisfy the test above.
    function test_aTamperedSignedAttributesIsRejected() public view {
        bytes memory tampered_ = _b('signedAttrs');
        tampered_[60] = bytes1(uint8(tampered_[60]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(tampered_, _b('cmsSignature'), _b('signerModulus')),
            'a modified Master List attribute set still verified'
        );
    }

    /// And a different key must not validate ICAO's signature - otherwise "signed by ICAO" would
    /// mean "signed by anyone".
    function test_anotherKeyDoesNotValidateIcaosSignature() public view {
        bytes memory wrongKey_ = _b('signerModulus');
        wrongKey_[0] = bytes1(uint8(wrongKey_[0]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(_b('signedAttrs'), _b('cmsSignature'), wrongKey_),
            'a key that is not the Master List Signer validated the signature'
        );
    }

    /// THE LINK THAT MAKES 104 BYTES WORTH 876 KB: the authenticated attributes carry the digest of
    /// the entire Master List, so verifying them authenticates the whole list by reference.
    function test_theAuthenticatedAttributesCarryTheDigestOfTheWholeList() public view {
        bytes memory attrs_ = _b('signedAttrs');
        bytes32 digest_ = abi.decode(vm.parseJson(fixture, '.eContentSha256'), (bytes32));

        bool found_;
        for (uint256 i = 0; i + 32 <= attrs_.length; ++i) {
            bytes32 window_;
            assembly {
                window_ := mload(add(add(attrs_, 32), i))
            }
            if (window_ == digest_) {
                found_ = true;
                break;
            }
        }

        assertTrue(found_, 'the signed attributes do not contain the eContent digest');
    }
}
