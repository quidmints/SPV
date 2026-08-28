// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ICertificateSigner} from "../../interfaces/signers/ICertificateSigner.sol";

import {RSA} from "../../utils/RSA.sol";
import {SHA1} from "../../utils/SHA1.sol";
import {SHA512} from "../../utils/SHA512.sol";

contract CRSASigner is ICertificateSigner, Initializable {
    using RSA for bytes;
    using SHA1 for bytes;
    using SHA512 for bytes;

    enum HF {
        sha1,
        sha256,
        sha512
    }

    uint256 public exponent; // RSA exponent
    HF public hashFunction; // hash function switcher

    function __CRSASigner_init(uint256 exponent_, HF hashFunction_) external initializer {
        exponent = exponent_;
        hashFunction = hashFunction_;
    }

    /// DigestInfo DER prefixes from RFC 8017 section 9.2, notes 1-2. `T` is prefix || hash.
    bytes internal constant DIGEST_INFO_SHA1 = hex"3021300906052b0e03021a05000414";
    bytes internal constant DIGEST_INFO_SHA256 =
        hex"3031300d060960864801650304020105000420";
    bytes internal constant DIGEST_INFO_SHA512 =
        hex"3051300d060960864801650304020305000440";

    /**
     * @notice Verifies ICAO member RSA signature of the X509 certificate SA.
     *
     * @dev THE FULL PKCS#1 v1.5 ENCODING IS CHECKED, not just the trailing hash (sec. 2.18u).
     *
     * This function used to decrypt and compare ONLY the last 20/32/64 bytes against the digest,
     * ignoring everything to their left. That is not a weakness with a low exponent, it is a
     * FORGERY: cubing is a bijection on odd residues mod 2^k, so for any target digest H one can
     * Hensel-lift a root of `s^3 = H (mod 2^256)`. Such an `s` is ~255 bits, so `s^3` is ~765 bits -
     * far below a 2048-bit modulus - and modexp performs no reduction at all, returning the plain
     * cube whose last 32 bytes ARE H by construction. A demonstrated forgery, built with no private
     * key, is committed at test/certificate/CRSASignerForgery.t.sol.
     *
     * What that would have bought an attacker: `Registration2.registerCertificate` verifies exactly
     * this signature before admitting a DSC key into `certificatesSmt` - the tree
     * `register_identity` proves membership in. Forging it inserts a signer key of the attacker's
     * choosing, and from there they sign their own SODs and enrol fabricated identities through the
     * permissionless path.
     *
     * So the whole encoded message is now reconstructed and compared:
     *     EM = 0x00 || 0x01 || 0xFF...FF || 0x00 || DigestInfo || H
     * which pins every byte the decryption produces, leaving nothing for an attacker to choose.
     */
    function verifyICAOSignature(
        bytes memory x509SignedAttributes_,
        bytes memory icaoMemberSignature_,
        bytes memory icaoMemberKey_
    ) external view override returns (bool) {
        bytes memory decrypted_ = icaoMemberSignature_.decrypt(
            abi.encodePacked(exponent),
            icaoMemberKey_
        );

        bytes memory digest_;
        bytes memory digestInfo_;

        if (hashFunction == HF.sha1) {
            // SHA1.sha1 returns bytes20, so this is exactly 20 bytes - no truncation needed.
            digest_ = abi.encodePacked(x509SignedAttributes_.sha1());
            digestInfo_ = DIGEST_INFO_SHA1;
        } else if (hashFunction == HF.sha256) {
            digest_ = abi.encodePacked(sha256(x509SignedAttributes_));
            digestInfo_ = DIGEST_INFO_SHA256;
        } else {
            digest_ = x509SignedAttributes_.sha512();
            digestInfo_ = DIGEST_INFO_SHA512;
        }

        return _checkPkcs1v15(decrypted_, digestInfo_, digest_);
    }

    /**
     * @dev Rebuild `EM = 0x00 || 0x01 || PS || 0x00 || T` and compare it to the decryption, where
     *      `PS` is at least eight 0xFF bytes and `T` is the DigestInfo followed by the hash.
     *
     *      Constructing the expected value and comparing the WHOLE thing is deliberate: a check
     *      that walks the decryption looking for a separator is the shape that produced
     *      Bleichenbacher's 2006 forgery, because it leaves the attacker room after the digest.
     *      There is nothing to parse here and nothing left over.
     */
    function _checkPkcs1v15(
        bytes memory decrypted_,
        bytes memory digestInfo_,
        bytes memory digest_
    ) private pure returns (bool) {
        uint256 emLen_ = decrypted_.length;
        uint256 tLen_ = digestInfo_.length + digest_.length;

        // RFC 8017 section 9.2 step 3: PS must be at least 8 bytes long.
        if (emLen_ < tLen_ + 11) {
            return false;
        }

        if (decrypted_[0] != 0x00 || decrypted_[1] != 0x01) {
            return false;
        }

        uint256 psEnd_ = emLen_ - tLen_ - 1;

        for (uint256 i = 2; i < psEnd_; ++i) {
            if (decrypted_[i] != 0xff) {
                return false;
            }
        }

        if (decrypted_[psEnd_] != 0x00) {
            return false;
        }

        for (uint256 i = 0; i < digestInfo_.length; ++i) {
            if (decrypted_[psEnd_ + 1 + i] != digestInfo_[i]) {
                return false;
            }
        }

        for (uint256 i = 0; i < digest_.length; ++i) {
            if (decrypted_[psEnd_ + 1 + digestInfo_.length + i] != digest_[i]) {
                return false;
            }
        }

        return true;
    }
}
