// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EC256} from "@solarity/solidity-lib/libs/crypto/EC256.sol";
// `Math.modExp` — reached through the `@openzeppelin-submodule/` alias, NOT the global
// `@openzeppelin/` one. Two OZ copies coexist here and only one has this function: the global
// alias resolves to `lib/v4-core/lib/openzeppelin-contracts` at **5.0.2**, which predates
// `modExp` (verified: 0 matches for `function modExp` in its `Math.sol`); the alias below
// resolves to the top-level submodule, currently **5.7.0**, which has it.
// ⚠️ THE ALIAS IS DELIBERATELY NOT NAMED FOR A VERSION. It was `@openzeppelin-5.4/` and went
//    stale the moment the submodule moved — I had locally downgraded 5.7.0 → 5.4.0 to get
//    `modExp`, which was never necessary and would have committed a dependency regression.
//    Name it for WHICH COPY it is, since that is what distinguishes the two and cannot drift.
import {Math} from "@openzeppelin-submodule/utils/math/Math.sol";

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
// (E128) `isValidXOnlyKey` is the lift_x precondition — see `schnorrVerify`.
import {BitcoinTx} from "./BitcoinTx.sol";

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
        uint256 y = Math.modExp(ySq, (p + 1) >> 2, p);   // p ≡ 3 (mod 4)
        require(mulmod(y, y, p) == ySq, "MuSig2Agg: x is not on the curve");
        // `y == 0` would be an order-2 point. secp256k1's group order is PRIME, so none
        // exists and `x³+7 == 0` has no on-curve solution — but the code should not rely on
        // an unstated theorem, and the check costs nothing.
        require(y != 0, "MuSig2Agg: degenerate point");

        if ((y & 1) != (prefix & 1)) y = p - y;                  // match the declared parity
        pt = EC256.APoint({x: x, y: y});
    }

    /// @notice TRUE iff `qXOnly` is the BIP-341 output key of the MuSig2 2-of-2 over these
    ///         two pubkeys — i.e. `Q = KeyAgg(KeySort(pk1, pk2)) + H_TapTweak(x)·G`.
    /// @dev The whole point: it can only be true if BOTH named keys are inside `Q`.
    /// @dev Locals in a struct: one memory pointer costs less stack than a dozen values.
    ///      (House rule — stack-too-deep is solved this way here, never with via_ir.)
    struct AggVars {
        EC256.Curve ec;
        bytes p1;
        bytes p2;
        uint256 a1;
        EC256.APoint P1;
        EC256.APoint P2;
        EC256.APoint agg;
        uint256 t;
    }

    /// @dev `public`, not `internal`, so this DEPLOYS AS A LINKED LIBRARY and is delegatecalled
    ///      rather than inlined. Inlined it added ~4.8 KB to `BTCChannels` and pushed it 1,344
    ///      bytes OVER EIP-170 — which `forge test` does not enforce and only
    ///      `forge build --sizes` reveals. Same pattern the codebase already uses for SwapLib
    ///      and LevMath; the large external surface is deliberate, not accidental API.
    function isTwoOfTwoOutputKey(
        bytes memory pkA33,
        bytes memory pkB33,
        bytes32 qXOnly
    ) public view returns (bool) {
        return computeOutputKey(pkA33, pkB33) == qXOnly;
    }

    /// @notice The same aggregate, RETURNED rather than compared: the BIP-341 output key of
    ///         the MuSig2 2-of-2 over these two pubkeys.
    /// @dev    Exists because a test fixture that wants a channel the gate will ACCEPT has to
    ///         be able to build a genuine `Q`, and the alternative — a hardcoded triple — pins
    ///         every splice fixture to one key pair. Note the circularity this creates and why
    ///         it is safe: fixtures built with this function cannot detect a bug IN it, so the
    ///         correctness of the aggregation is pinned independently by
    ///         `MuSig2Agg.t.sol`'s BIP-327 reference vector, which is ground truth from
    ///         outside this repo. Fixtures prove the WIRING; the vector proves the MATH.
    function computeOutputKey(
        bytes memory pkA33,
        bytes memory pkB33
    ) public view returns (bytes32) {
        // ⚠️ VALIDATE LENGTH BEFORE SORTING. `_cmp` walks 33 bytes, so a short array used to
        // panic inside the comparison rather than reverting with a reason — an unclear
        // failure on the validation path itself.
        require(pkA33.length == 33 && pkB33.length == 33, "MuSig2Agg: pubkey must be 33 bytes");

        AggVars memory v;
        v.ec = curve();

        // BIP-327 KeySort: lexicographic over the 33-byte encodings.
        (v.p1, v.p2) = _lessThan(pkA33, pkB33) ? (pkA33, pkB33) : (pkB33, pkA33);

        // ⚠️ THE "SECOND KEY" RULE, which the BIP-327 vectors caught me getting wrong.
        //    `key_agg_coeff_internal` returns 1 — NOT a hash — for the second key (the first
        //    entry differing from `pubkeys[0]`). Hashing both yields a plausible-looking
        //    aggregate that is simply a different point: invisible by inspection.
        v.a1 = uint256(taggedHash(
            "KeyAgg coefficient",
            abi.encodePacked(taggedHash("KeyAgg list", abi.encodePacked(v.p1, v.p2)), v.p1)
        )) % v.ec.n;

        v.P1 = decompress(v.p1);
        v.P2 = decompress(v.p2);
        // Explicit, because assuming it is how crysol shipped a broken `isOnCurve`.
        require(v.ec.isOnCurve(v.P1) && v.ec.isOnCurve(v.P2), "MuSig2Agg: pubkey off curve");

        // a1·P1 + 1·P2 in one Shamir pass — this IS 2-key KeyAgg.
        v.agg = v.ec.toAffine(
            v.ec.jMultShamir2(EC256.toJacobian(v.P1), EC256.toJacobian(v.P2), v.a1, 1)
        );

        // BIP-341 tweaks the EVEN-Y LIFT of the aggregate, not the aggregate as computed.
        // Skipping this was the second bug the vectors caught — wrong for half of all pairs.
        if (v.agg.y % 2 != 0) v.agg.y = v.ec.p - v.agg.y;
        v.t = uint256(taggedHash("TapTweak", abi.encodePacked(bytes32(v.agg.x)))) % v.ec.n;

        return bytes32(v.ec.toAffine(
            v.ec.jAddPoint(EC256.toJacobian(v.agg), v.ec.jMultShamir(v.ec.jbasepoint(), v.t))
        ).x);
    }

    /// @notice (E159) BIP-341 TapLeaf hash for ONE script leaf:
    ///         `tagged_hash("TapLeaf", leafVersion || compactSize(script) || script)`.
    /// @dev Leaf version is fixed at 0xc0 (the only version taproot defines today). Scripts
    ///      longer than 252 bytes revert rather than emitting a wrong compact size — a
    ///      silently mis-encoded length would hash to a plausible leaf that simply is not the
    ///      one on chain, which is the failure this whole path exists to make impossible.
    function tapLeafHash(bytes memory script) public pure returns (bytes32) {
        require(script.length < 0xfd, "MuSig2Agg: leaf script too long");
        return taggedHash(
            "TapLeaf", abi.encodePacked(bytes1(0xc0), bytes1(uint8(script.length)), script));
    }

    /// @notice (T2) BIP-341 TapBranch: combine two child hashes into their parent —
    ///         `tagged_hash("TapBranch", min(a,b) || max(a,b))`.
    /// @dev THE SORT IS CONSENSUS, NOT TIDINESS. BIP-341 orders the two children
    ///      lexicographically so a merkle path need not record which side each sibling was on;
    ///      concatenating them in call order instead would compute a root Bitcoin does not agree
    ///      with, and the deposit address derived from it would simply never be paid.
    /// @dev Exists so a deposit address can commit to MORE than the refund leaf. Today
    ///      `swapInDepositKey` tweaks by a single leaf hash, so the address proves who may
    ///      reclaim the deposit and nothing else; §T2 adds a second, unspendable leaf carrying
    ///      `sha256(seller, token, minDeliveredUsd)` so the address commits to the whole quote
    ///      and the hop cannot restate any of it. `taprootOutputKeyWithLeaf` already accepts a
    ///      merkle ROOT rather than a leaf (see its docblock), so this is the only piece missing.
    function tapBranch(bytes32 a, bytes32 b) public pure returns (bytes32) {
        return a < b
            ? taggedHash("TapBranch", abi.encodePacked(a, b))
            : taggedHash("TapBranch", abi.encodePacked(b, a));
    }

    /// @notice (E159) BIP-341 output key for an internal key committing to a SINGLE leaf:
    ///         `Q = lift_x_even(P) + H_TapTweak(x(P) || leafHash)·G`.
    /// @dev Differs from `computeOutputKey` in exactly two ways, both load-bearing: the
    ///      internal key is GIVEN (not aggregated from two pubkeys), and the TapTweak hash
    ///      commits to the merkle root as well as the key. `computeOutputKey` passes only the
    ///      key because a channel funding output has an EMPTY tree; a swap-in deposit has the
    ///      user's CLTV refund leaf, so omitting the root here would compute the key for a
    ///      DIFFERENT (key-path-only) address that no deposit will ever pay.
    function taprootOutputKeyWithLeaf(bytes32 internalX, bytes32 leafHash)
        public view returns (bytes32)
    {
        EC256.Curve memory ec = curve();
        // Even-Y lift of the x-only internal key, exactly as BIP-341 specifies.
        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), internalX));
        require(ec.isOnCurve(P), "MuSig2Agg: internal key off curve");
        uint t = uint256(taggedHash(
            "TapTweak", abi.encodePacked(internalX, leafHash))) % ec.n;
        return bytes32(ec.toAffine(
            ec.jAddPoint(EC256.toJacobian(P), ec.jMultShamir(ec.jbasepoint(), t))
        ).x);
    }

    /// @notice (E128) BIP-340 Schnorr verification: `s·G == R + e·P`, with `R.x == r` and R even-Y.
    /// @param px x-only public key (the taproot output key `Q` for a key-path spend)
    /// @param rx signature's R.x  · @param sig signature's s  · @param m the 32-byte message
    ///
    /// @dev ⚠️ WHY THIS IS HAND-WRITTEN RATHER THAN IMPORTED (§E128-r/§E128-r2): **no EVM Schnorr
    ///      library verifies BITCOIN signatures.** Chronicle's Scribe, ERC-7816 and crysol all
    ///      standardise a DIFFERENT scheme — a shared lineage that is not BIP-340 — so their
    ///      contracts verify the wrong thing. Only the CURVE arithmetic is borrowed (solarity's
    ///      audited `EC256`); the protocol layer is ours, exactly as with KeyAgg.
    ///
    /// @dev ⚠️ RETURNS FALSE, NEVER REVERTS, on every malformed input. BIP-340 defines an
    ///      out-of-range `r`/`s`, an off-curve key, an infinite `R` and an odd-Y `R` as INVALID
    ///      SIGNATURES — not as errors. Reverting instead would make a bad signature
    ///      indistinguishable from a bad call at the call site.
    function schnorrVerify(bytes32 px, bytes32 rx, bytes32 sig, bytes32 m)
        public view returns (bool)
    {
        EC256.Curve memory ec = curve();
        if (uint256(rx) >= ec.p || uint256(sig) >= ec.n) return false;

        // ⚠️ THE ON-CURVE TEST MUST COME **BEFORE** `decompress`, WHICH REVERTS. I wrote this
        // the other way round — decompress, then `isOnCurve` — and the off-curve test failed with
        // `MuSig2Agg: x is not on the curve` instead of returning false, making the check
        // UNREACHABLE. BIP-340 classifies an unliftable x as an INVALID SIGNATURE, not an error.
        if (!BitcoinTx.isValidXOnlyKey(px)) return false;
        // lift_x: BIP-340 keys are x-only and always the EVEN-Y point.
        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), px));

        uint e = uint256(taggedHash(
            "BIP0340/challenge", abi.encodePacked(rx, px, m))) % ec.n;

        // R = s·G − e·P, computed as s·G + (n−e)·P in ONE Shamir pass.
        // e == 0 would make the second scalar `n`, which is ≡ 0 but not necessarily handled as
        // such by the ladder — so it is normalised here rather than relied upon.
        EC256.APoint memory R = ec.toAffine(ec.jMultShamir2(
            ec.jbasepoint(), EC256.toJacobian(P), uint256(sig), e == 0 ? 0 : ec.n - e));

        if (R.x == 0 && R.y == 0) return false;   // point at infinity
        if (R.y % 2 != 0) return false;           // BIP-340 requires even-Y R
        return bytes32(R.x) == rx;
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
}
