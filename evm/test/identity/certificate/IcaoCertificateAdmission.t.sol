// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {MerkleProof} from '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';

import {CRSADispatcher} from '../../../src/identity/certificate/dispatchers/CRSADispatcher.sol';
import {CRSASigner} from '../../../src/identity/certificate/signers/CRSASigner.sol';

/*
 * THE DSC ADMISSION PATH, DRIVEN BY REAL ICAO DATA (2026-08-03).
 *
 * Every other test on this path uses synthetic bytes - `CRSADispatcher.t.sol` builds attributes out
 * of a counter, and the signer suites use constructed keys. That is right for probing edge cases and
 * useless for the question that actually matters: does this code accept a genuine passport-authority
 * certificate chain?
 *
 * IT DOES NOT NEED A PASSPORT, which is why this test can exist at all. `registerCertificate` is
 * permissionless and proves three things - that a CSCA is in the ICAO master tree, that THIS CSCA
 * signed THIS DSC, and what the DSC's key and expiry are. All three are certificate-level facts.
 * The document only enters one level further on, when a passport's SOD is checked against an
 * admitted DSC (task 6).
 *
 * PROVENANCE OF THE FIXTURE - `test/identity/fixtures/icao_certificate_admission.json`:
 *   - the CSCA comes from `ICAO_ML_20260721154956.ml`, the signed ICAO Master List, whose CMS
 *     signature was verified before anything was extracted (581 certificates, 103 countries)
 *   - the DSC comes from `icaopkd-001-complete-10245.ldif`, ICAO's published PKD feed (31,410 DSCs)
 *   - the pair was checked off-chain first (RSA PKCS#1 v1.5, SHA-256) so that a failure here is a
 *     CONTRACT problem and never a bad fixture
 *   - regenerate the root with `tools/build-icao-master-root.py`, which refuses to run on a master
 *     list whose CMS signature does not verify - "never fake a root" (TODO sec. 2.18k)
 *
 * NOTHING HERE IS SYNTHETIC. If any assertion below fails, this repo cannot admit a real
 * certificate from a real issuing authority.
 */
contract IcaoCertificateAdmissionTest is Test {
    CRSADispatcher internal dispatcher;
    CRSASigner internal signer;

    /// The ASN.1 INTEGER header of a 2048-bit modulus plus its leading zero: 02 82 01 01 00.
    /// `X509._checkPrefix` matches the bytes IMMEDIATELY BEFORE `keyOffset`, so this is what sits
    /// there in a real certificate - read out of the DSC rather than assumed.
    bytes internal constant RSA_2048_PREFIX = hex'0282010100';
    uint256 internal constant RSA_2048_KEY_BYTES = 256;

    string internal fixture;

    function setUp() public {
        fixture = vm.readFile('test/identity/fixtures/icao_certificate_admission.json');

        signer = new CRSASigner();
        signer.__CRSASigner_init(_uint('cscaExponent'), CRSASigner.HF.sha256);

        dispatcher = new CRSADispatcher();
        dispatcher.__CRSADispatcher_init(address(signer), RSA_2048_KEY_BYTES, RSA_2048_PREFIX);
    }

    function _bytes(string memory key_) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fixture, string.concat('.', key_));
    }

    function _uint(string memory key_) internal view returns (uint256) {
        return vm.parseJsonUint(fixture, string.concat('.', key_));
    }

    /// STEP 1 OF `registerCertificate`: the CSCA must be in the ICAO master tree. Same check the
    /// contract runs - `icaoMerkleProof_.processProof(keccak256(icaoMember_.publicKey))` - against a
    /// root built from all 581 published CSCA certificates.
    function test_theRealCscaIsProvablyInTheIcaoMasterTree() public view {
        bytes32[] memory proof_ = vm.parseJsonBytes32Array(fixture, '.icaoMerkleProof');
        bytes32 root_ = vm.parseJsonBytes32(fixture, '.icaoMasterTreeMerkleRoot');
        bytes32 leaf_ = keccak256(_bytes('cscaModulus'));

        assertEq(leaf_, vm.parseJsonBytes32(fixture, '.cscaLeaf'), 'leaf is not keccak(publicKey)');
        assertTrue(MerkleProof.verify(proof_, root_, leaf_), 'the real CSCA is not in the master tree');
    }

    /// AND THE PROOF IS NOT VACUOUS: any other key must fail against the same root. Without this a
    /// `verify` that ignored its arguments would satisfy the test above.
    function test_aKeyOutsideTheMasterListIsRejected() public view {
        bytes32[] memory proof_ = vm.parseJsonBytes32Array(fixture, '.icaoMerkleProof');
        bytes32 root_ = vm.parseJsonBytes32(fixture, '.icaoMasterTreeMerkleRoot');

        assertFalse(
            MerkleProof.verify(proof_, root_, keccak256(abi.encodePacked('not a CSCA key'))),
            'a key that is not on the ICAO list proved membership'
        );
    }

    /// STEP 2, AND THE ONE THAT MATTERS MOST: a real national CSCA's RSA signature over a real DSC,
    /// verified ON-CHAIN by our own signer. 4096-bit modulus, e=65537, SHA-256.
    function test_theRealCscaSignatureOverTheRealDscVerifiesOnChain() public view {
        assertTrue(
            signer.verifyICAOSignature(_bytes('dscTbs'), _bytes('icaoSignature'), _bytes('cscaModulus')),
            'a genuine CSCA signature over a genuine DSC was rejected'
        );
    }

    /// Non-vacuity for the signature too: flip one byte of the signed data and it must fail.
    /// `dscTbs` is exactly what the CSCA signed, so any edit invalidates it.
    function test_aTamperedDscIsRejected() public view {
        bytes memory tampered_ = _bytes('dscTbs');
        tampered_[100] = bytes1(uint8(tampered_[100]) ^ 0x01);

        assertFalse(
            signer.verifyICAOSignature(tampered_, _bytes('icaoSignature'), _bytes('cscaModulus')),
            'a modified DSC still verified under the real CSCA signature'
        );
    }

    /// STEP 3: the dispatcher must read the DSC's own public key out of the CSCA-signed attributes
    /// at the caller-supplied offset. The offset is NOT covered by the signature (sec. 2.18m), which
    /// is why the prefix check exists - here it is exercised against a real certificate's layout.
    function test_theDscPublicKeyIsExtractedFromTheSignedAttributes() public view {
        bytes memory key_ = dispatcher.getCertificatePublicKey(_bytes('dscTbs'), _uint('keyOffset'));

        assertEq(key_.length, RSA_2048_KEY_BYTES, 'wrong DSC key length');
        // The first and last bytes of the real 2048-bit modulus, taken from the certificate itself.
        assertEq(uint8(key_[0]), 0xc4, 'key does not start where the certificate says it does');
        assertEq(uint8(key_[RSA_2048_KEY_BYTES - 1]), 0xe7, 'key does not end where it should');
    }

    /// A WRONG OFFSET MUST REVERT RATHER THAN RETURN ADJACENT MEMORY. This is the shape of the
    /// out-of-bounds read from sec. 2.18m, now driven by a real certificate instead of a synthetic
    /// buffer: the attacker controls the offset, never the signature over the attributes.
    function test_aShiftedKeyOffsetIsRefused() public {
        vm.expectRevert(bytes('X509: wrong check placement'));
        dispatcher.getCertificatePublicKey(_bytes('dscTbs'), _uint('keyOffset') + 1);
    }
}
