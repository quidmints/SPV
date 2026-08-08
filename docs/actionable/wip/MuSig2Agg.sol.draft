// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EC256} from "@solarity/solidity-lib/libs/crypto/EC256.sol";

/// @title  MuSig2Agg — prove a taproot output key IS the 2-of-2 of two named pubkeys
/// @notice Closes the gap `BTCChannels.sol` has always admitted: *"The contract does NO
///         secp256k1 EC, so it does NOT prove Q == KeyAgg(lpPubkey, hopPubkey)"*. Until now
///         `lpPubkey`/`hopPubkey` were only LENGTH-validated (`ChannelLib.sol:494`) and the
///         funding output was located purely by the caller-supplied `Q` — so a hop could
///         open, or splice into, a `Q` it solely controls. In fleet mode the operator holds
///         both halves and can do that alone (E129).
///
///         ⚠️ NO NEW DEPENDENCY, AND NO VENDORING. The solarity solidity-lib is already a
///         remapped dependency (it supplies `BlockHeader`/`TxMerkleProof` to the SPV
///         gateway) and ships an AUDITED, curve-parameterised `EC256`. Its `jMultShamir2`
///         computes `u1·P1 + u2·P2` in one pass — which IS 2-key KeyAgg. That removes the
///         need for Chainlink's witness pattern (whose lifted code drops an on-curve check)
///         and for crysol (unaudited). secp256k1 is just parameters here: a=0, b=7.
library MuSig2Agg {
    using EC256 for *;

    /// secp256k1. `a = 0`, `b = 7`, and n/p/G are the standard constants.
    function curve() internal pure returns (EC256.Curve memory) {
        return EC256.Curve({
            a:  0,
            b:  7,
            p:  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
            n:  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
            gx: 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            gy: 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
        });
    }

    /// @dev BIP-340 tagged hash: `SHA256(SHA256(tag) || SHA256(tag) || msg)`.
    ///      SHA256 is precompile 0x02, so this is cheap.
    function taggedHash(string memory tag, bytes memory msg_) internal pure returns (bytes32) {
        bytes32 t_ = sha256(bytes(tag));
        return sha256(abi.encodePacked(t_, t_, msg_));
    }

    /// @notice Decompress a 33-byte SEC1 pubkey. Reverts if the bytes are not a curve point.
    /// @dev The y-parity is the prefix byte (0x02 even, 0x03 odd), and `y = ±sqrt(x³+7)`.
    ///      p ≡ 3 (mod 4) so the root is `(x³+7)^((p+1)/4)`; squaring it back is what makes
    ///      this a decision rather than a guess — a non-residue still yields a value.
    function decompress(bytes memory pk33) internal view returns (EC256.APoint memory pt) {
        require(pk33.length == 33, "MuSig2Agg: pubkey must be 33 bytes");
        uint8 prefix = uint8(pk33[0]);
        require(prefix == 2 || prefix == 3, "MuSig2Agg: bad SEC1 prefix");

        uint256 p = curve().p;
        uint256 x;
        assembly ("memory-safe") { x := mload(add(pk33, 33)) }   // bytes 1..32
        require(x != 0 && x < p, "MuSig2Agg: x out of field");

        uint256 ySq = addmod(mulmod(mulmod(x, x, p), x, p), 7, p);
        uint256 y = _modExp(ySq, (p + 1) >> 2, p);
        require(mulmod(y, y, p) == ySq, "MuSig2Agg: x is not on the curve");

        if ((y & 1) != (prefix & 1)) y = p - y;                  // match the declared parity
        pt = EC256.APoint({x: x, y: y});
    }

    /// @notice TRUE iff `qXOnly` is the BIP-341 output key of the MuSig2 2-of-2 over these
    ///         two pubkeys — i.e. `Q = KeyAgg(KeySort(pk1, pk2)) + H_TapTweak(x)·G`.
    /// @dev The whole point: it can only be true if BOTH named keys are inside `Q`.
    function isTwoOfTwoOutputKey(
        bytes memory pkA33,
        bytes memory pkB33,
        bytes32 qXOnly
    ) internal view returns (bool) {
        EC256.Curve memory ec = curve();

        // BIP-327 KeySort: lexicographic over the 33-byte encodings.
        (bytes memory p1_, bytes memory p2_) =
            _lessThan(pkA33, pkB33) ? (pkA33, pkB33) : (pkB33, pkA33);

        // Coefficients bind the WHOLE sorted list, which is what defeats rogue-key attacks.
        bytes32 listHash_ = taggedHash("KeyAgg list", abi.encodePacked(p1_, p2_));
        uint256 a1_ = uint256(taggedHash("KeyAgg coefficient", abi.encodePacked(listHash_, p1_))) % ec.n;
        uint256 a2_ = uint256(taggedHash("KeyAgg coefficient", abi.encodePacked(listHash_, p2_))) % ec.n;

        EC256.APoint memory P1_ = decompress(p1_);
        EC256.APoint memory P2_ = decompress(p2_);
        // ⚠️ Explicit, because a library that assumes it is how crysol shipped an
        //    `isOnCurve` that accepted off-curve points.
        require(ec.isOnCurve(P1_) && ec.isOnCurve(P2_), "MuSig2Agg: pubkey off curve");

        // a1·P1 + a2·P2 in one Shamir pass — this IS 2-key KeyAgg.
        EC256.APoint memory agg_ = ec.toAffine(
            ec.jMultShamir2(EC256.toJacobian(P1_), EC256.toJacobian(P2_), a1_, a2_)
        );

        // BIP-341: the tweak commits to the aggregate's x-only form (even-y convention).
        uint256 t_ = uint256(taggedHash("TapTweak", abi.encodePacked(bytes32(agg_.x)))) % ec.n;
        EC256.APoint memory q_ = ec.toAffine(
            ec.jAddPoint(EC256.toJacobian(agg_), ec.jMultShamir(ec.jbasepoint(), t_))
        );

        return q_.x == uint256(qXOnly);
    }

    function _lessThan(bytes memory a, bytes memory b) private pure returns (bool) {
        return uint256(keccak256(a)) == uint256(keccak256(b))
            ? false
            : _cmp(a, b);
    }

    function _cmp(bytes memory a, bytes memory b) private pure returns (bool) {
        for (uint256 i = 0; i < 33; ++i) {
            if (uint8(a[i]) != uint8(b[i])) return uint8(a[i]) < uint8(b[i]);
        }
        return false;
    }

    function _modExp(uint256 base, uint256 e, uint256 m) private view returns (uint256 r) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0x20) mstore(add(p, 0x20), 0x20) mstore(add(p, 0x40), 0x20)
            mstore(add(p, 0x60), base) mstore(add(p, 0x80), e) mstore(add(p, 0xa0), m)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            r := mload(p)
        }
    }
}
