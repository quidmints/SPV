// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MemoryUtils} from "@solarity/solidity-lib/libs/utils/MemoryUtils.sol";

import {Date2Time} from "./Date2Time.sol";

library X509 {
    using MemoryUtils for bytes;

    /**
     * @notice Extracts expiration timestamp from the certificate SA.
     *
     * The timestamp starts with "170d" sequence, then go hex ASCII codes of the timestamp symbols:
     *
     * "0x170d" + "0x333030393131303732313236" -> 0x333030393131303732313236 -> "3 0  0 9  1 1  0 7  2 1  2 6" ->
     * convert to numbers = 2030-09-11 07:21:26 UTC
     */
    function extractExpirationTimestamp(
        bytes memory x509SignedAttributes_,
        uint256 expirationOffset_
    ) internal pure returns (uint256) {
        _checkPrefix(x509SignedAttributes_, hex"170d", expirationOffset_);

        // BOUNDS, STATED RATHER THAN INHERITED. The loop below indexes `x509SignedAttributes_`
        // directly, so Solidity would already bounds-check it and revert with a bare Panic(0x32).
        // That made this function safe BY ACCIDENT OF STYLE - it is safe because of how the bytes
        // happen to be read, not because anything says so, and a later rewrite to `unsafeCopy` for
        // gas (exactly what `extractPublicKey` does two functions down, where the missing check WAS
        // a live out-of-bounds read - sec. 2.18m) would silently remove the protection.
        //
        // `expirationOffset` is a caller-supplied field of `Registration2.Certificate` and is NOT
        // covered by the CSCA signature over the attributes, so it is unauthenticated input.
        require(
            expirationOffset_ + 12 <= x509SignedAttributes_.length,
            "X509: expiration runs past the signed attributes"
        );

        uint256[] memory asciiTime = new uint256[](6);

        for (uint256 i = 0; i < 12; i++) {
            uint256 asciiNum_ = uint8(x509SignedAttributes_[expirationOffset_ + i]) - 48;

            asciiTime[i / 2] += i % 2 == 0 ? asciiNum_ * 10 : asciiNum_;
        }

        return
            Date2Time.timestampFromDateTime(
                asciiTime[0] + 2000, // only the last 2 digits of the year are encoded
                asciiTime[1],
                asciiTime[2],
                asciiTime[3],
                asciiTime[4],
                asciiTime[5]
            );
    }

    /**
     * @notice extracts `keyLength_` bit X509 public key from the certificate.
     *
     * The key starts with `checkPrefix_` bytes sequence.
     *
     * Straightforward approach by copying memory from the given position
     */
    function extractPublicKey(
        bytes memory x509SignedAttributes_,
        bytes memory checkPrefix_,
        uint256 keyOffset_,
        uint256 keyLength_
    ) internal view returns (bytes memory x509Key_) {
        _checkPrefix(x509SignedAttributes_, checkPrefix_, keyOffset_);

        // BOUNDS. `_checkPrefix` validates only the bytes immediately BEFORE `keyOffset_`, and the
        // copy below is `MemoryUtils.unsafeCopy` - a raw identity-precompile memcpy with no bounds
        // check of any kind. Without this line a `keyOffset_` near the end of the array silently
        // reads ADJACENT MEMORY into the extracted key instead of reverting.
        //
        // THAT WAS REACHABLE, NOT THEORETICAL. `keyOffset` is a caller-supplied field of
        // `Registration2.Certificate` and is NOT covered by the CSCA signature over
        // `signedAttributes`, so anyone holding one genuine CSCA-signed certificate could resubmit
        // it with a different offset and have a key read out of memory they influence - in a call
        // whose other arguments (`icaoMember.publicKey`, `icaoMember.signature`) are also theirs.
        // The result goes to `StateKeeper.addCertificate` and lands in `certificatesSmt`, the tree
        // `register_identity` proves membership in, so an attacker-controlled key admitted there
        // would let them sign their own SODs and enrol fabricated identities. See sec. 2.18m.
        require(
            keyOffset_ + keyLength_ <= x509SignedAttributes_.length,
            "X509: key runs past the signed attributes"
        );

        x509Key_ = new bytes(keyLength_);

        MemoryUtils.unsafeCopy(
            x509SignedAttributes_.getDataPointer() + keyOffset_,
            x509Key_.getDataPointer(),
            keyLength_
        );
    }

    function _checkPrefix(
        bytes memory x509SignedAttributes_,
        bytes memory checker_,
        uint256 offset_
    ) private pure {
        for (uint256 i = 0; i < checker_.length; ++i) {
            require(
                x509SignedAttributes_[offset_ - checker_.length + i] == checker_[i],
                "X509: wrong check placement"
            );
        }
    }
}
