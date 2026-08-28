// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title EcdsaS
 * @notice Rewrites an ECDSA `s` into the lower half of the curve order, for curves whose order is
 *         held as big-endian `bytes` rather than a `uint256`.
 *
 * WHY THIS EXISTS (sec. 2.18v). `ECDSA256/384/512` accept only low-s - "signatures only
 * from the lower part of the curve are accepted". That is correct for TRANSACTIONS, where a
 * malleated copy would be a second valid transaction, and wrong for verifying someone else's X.509
 * signature: nothing in certificate admission keys on signature bytes, so malleability buys an
 * attacker nothing, while CAs do not normalise. Measured, openssl emitted high-s in 11 of 20
 * signings of one message - so roughly half of all genuine ECDSA CSCA certificates were refused.
 *
 * REWRITING IS SOUND, NOT A BYPASS. If `(r, s)` verifies then so does `(r, n - s)`: they are the two
 * representations of ONE signature and ECDSA verification is symmetric in that reflection, so
 * checking the low form proves exactly the same statement about the same key and message. An
 * invalid signature stays invalid under either representation.
 *
 * `CECDSA256Signer` does this inline because its order is a `uint256`. The 384- and 512-bit signers
 * cannot, which is the only reason this library exists.
 */
library EcdsaS {
    /**
     * @notice Returns `signature_` with `s` rewritten to the lower half of `n_`, if it was not.
     * @param signature_ r || s, big-endian, each half `n_.length` bytes
     * @param n_ the curve order, big-endian
     *
     * PASSES MALFORMED INPUT THROUGH UNTOUCHED rather than guessing at it - the verifier is the
     * right place to reject a wrong-length signature, and rewriting one would only obscure why.
     *
     * `s >= n` IS ALSO PASSED THROUGH, and that clause is not cosmetic: a signature made under a
     * DIFFERENT curve can carry an `s` larger than this curve's order, and `n - s` would underflow.
     * Such a signature is invalid here anyway. The equivalent guard was missing from the first
     * version of the 256-bit fix and a wrong-curve test caught it immediately.
     */
    function normalize(
        bytes memory signature_,
        bytes memory n_
    ) internal pure returns (bytes memory) {
        uint256 half_ = n_.length;

        if (signature_.length != half_ * 2) {
            return signature_;
        }

        bytes memory s_ = new bytes(half_);

        for (uint256 i = 0; i < half_; ++i) {
            s_[i] = signature_[half_ + i];
        }

        if (!_lt(s_, n_)) {
            return signature_; // s >= n: invalid for this curve, and n - s would underflow
        }

        if (!_gtHalf(s_, n_)) {
            return signature_; // already canonical
        }

        bytes memory low_ = _sub(n_, s_);
        bytes memory out_ = new bytes(half_ * 2);

        for (uint256 i = 0; i < half_; ++i) {
            out_[i] = signature_[i];
            out_[half_ + i] = low_[i];
        }

        return out_;
    }

    /**
     * @notice The same rule for a curve whose order fits a `uint256`.
     *
     * SHARED RATHER THAN COPIED. `CECDSA256Signer` and `PECDSASHA1Authenticator` both need it, and
     * the root-validity rule earlier today (sec. 2.18o) is the argument against writing it
     * twice: it was duplicated three ways, so fixing one copy left two live.
     *
     * `s_ < n_` is not redundant - a signature made under a DIFFERENT curve can carry an `s` larger
     * than this order, and `n_ - s_` would underflow. Such a signature is invalid here anyway, so it
     * is returned untouched for the verifier to reject.
     */
    function normalizeScalar(uint256 s_, uint256 n_) internal pure returns (uint256) {
        if (s_ > n_ / 2 && s_ < n_) {
            return n_ - s_;
        }

        return s_;
    }

    /// @dev Big-endian `a < b` for equal-length arrays.
    function _lt(bytes memory a_, bytes memory b_) private pure returns (bool) {
        for (uint256 i = 0; i < a_.length; ++i) {
            if (a_[i] != b_[i]) {
                return uint8(a_[i]) < uint8(b_[i]);
            }
        }

        return false; // equal
    }

    /**
     * @dev Big-endian `a > n / 2`, computed WITHOUT materialising `n / 2`.
     *
     * Comparing `2a` against `n` avoids the halving entirely: `a > n/2` exactly when `2a > n`, and
     * the doubling is one pass with a carry. Halving `n` first would need a rounding decision on
     * an odd order - every curve order here IS odd - and getting that wrong shifts the boundary by
     * one, which no test with a random signature would reliably catch.
     */
    function _gtHalf(bytes memory a_, bytes memory n_) private pure returns (bool) {
        uint256 len_ = a_.length;
        bytes memory doubled_ = new bytes(len_);
        uint256 carry_ = 0;

        for (uint256 i = len_; i > 0; --i) {
            uint256 v_ = uint256(uint8(a_[i - 1])) * 2 + carry_;
            doubled_[i - 1] = bytes1(uint8(v_ & 0xff));
            carry_ = v_ >> 8;
        }

        if (carry_ != 0) {
            return true; // 2a overflowed the width, so it certainly exceeds n
        }

        return _lt(n_, doubled_);
    }

    /// @dev Big-endian `a - b`, assuming `a >= b`.
    function _sub(bytes memory a_, bytes memory b_) private pure returns (bytes memory) {
        uint256 len_ = a_.length;
        bytes memory out_ = new bytes(len_);
        uint256 borrow_ = 0;

        for (uint256 i = len_; i > 0; --i) {
            uint256 av_ = uint256(uint8(a_[i - 1]));
            uint256 bv_ = uint256(uint8(b_[i - 1])) + borrow_;

            if (av_ < bv_) {
                av_ += 256;
                borrow_ = 1;
            } else {
                borrow_ = 0;
            }

            out_[i - 1] = bytes1(uint8(av_ - bv_));
        }

        return out_;
    }
}
