// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {RSA} from "../../utils/RSA.sol";
import {SHA1} from "../../utils/SHA1.sol";

contract PRSASHAAuthenticator is Initializable {
    using RSA for bytes;
    using SHA1 for bytes;

    uint256 public exponent; // RSA exponent
    bool public isSha1;
    uint256 private hashLen;

    function __PRSASHAAuthenticator_init(uint256 exponent_, bool isSha1_) external initializer {
        exponent = exponent_;
        isSha1 = isSha1_;
        hashLen = isSha1 ? 20 : 32;
    }

    /**
     * @notice Checks active authentication of a passport. The RSA algorithm is as follows:
     *
     * 1. Decrypt the signature
     * 2. Remove the 1 byte or 2 bytes (hash function indicator) suffix
     * 3. The last 20 bytes of the decrypted signature is the SHA1 hash of random + challenge or the last 32 bytes in case SHA2 hash
     */
    function authenticate(
        bytes memory challenge_,
        bytes memory s_,
        bytes memory n_
    ) external view returns (bool) {
        bytes memory e_ = abi.encodePacked(exponent);

        if (s_.length == 0 || n_.length == 0) {
            return false;
        }

        bytes memory decipher_ = s_.decrypt(e_, n_);

        uint256 suffixLen_ = isSha1 ? 1 : 2;

        if (decipher_.length < hashLen + suffixLen_ + 2) {
            return false;
        }

        /*
         * THE ISO 9796-2 FRAME IS CHECKED, not skipped (sec. 2.18y).
         *
         * This function used to advance past `decipher_[0]` and strip the trailer WITHOUT LOOKING AT
         * EITHER, recovering `M1` from whatever lay between. The header nibble and the trailer are
         * the only things distinguishing a signature-shaped block from an arbitrary one, so
         * discarding them unread leaves the scheme's framing unenforced.
         *
         * Header: 0x6A for partial recovery, 0x4A for total. Trailer: 0xBC for the implicit
         * one-byte form, 0xCC when a hash identifier precedes it.
         *
         * THIS IS NOT CURRENTLY REACHABLE - Active Authentication needs DG15, and our
         * `register_identity` variant is built with `DG15_LEN = 0`. It is fixed anyway because
         * being unreachable today is not a property of the code, it is a property of one generic
         * parameter in one circuit.
         */
        bytes1 header_ = decipher_[0];

        if (header_ != 0x6a && header_ != 0x4a) {
            return false;
        }

        if (decipher_[decipher_.length - 1] != (suffixLen_ == 1 ? bytes1(0xbc) : bytes1(0xcc))) {
            return false;
        }

        assembly {
            mstore(decipher_, sub(mload(decipher_), suffixLen_))
        }

        bytes memory prepared_ = new bytes(decipher_.length - hashLen - 1);
        bytes memory digest_ = new bytes(hashLen);

        for (uint256 i = 0; i < prepared_.length; ++i) {
            prepared_[i] = decipher_[i + 1];
        }

        for (uint256 i = 0; i < digest_.length; ++i) {
            digest_[i] = decipher_[decipher_.length - hashLen + i];
        }

        return bytes32(digest_) == _hash(abi.encodePacked(prepared_, challenge_));
    }

    function _hash(bytes memory data_) private view returns (bytes32) {
        return isSha1 ? data_.sha1() : sha256(data_);
    }
}
