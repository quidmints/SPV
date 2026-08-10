// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MuSig2Agg} from "../../src/imports/MuSig2Agg.sol";

/// @notice (E159) BIP-341 output key for an internal key committing to a SINGLE leaf — the
///         shape a swap-in deposit address has (key path = the hop's claim, one leaf = the
///         user's CLTV refund).
///
///         ⚠️ WHY THIS EXISTS AT ALL: `settleSwapIn` currently credits the shared pool on the
///         hop's WORD, with no proof any BTC arrived (§E159). The on-chain rail CAN be proven,
///         but only if the contract can recompute the deposit address — otherwise a hop could
///         SPV-prove a payment to a script it controls and collect USD for BTC that never
///         entered protocol custody. This is that recomputation.
///
///         ⚠️ THE VECTOR IS INDEPENDENT, WHICH IS THE POINT. It is computed in Python directly
///         from BIP-341 (tagged hashes + secp256k1 point add/mul), NOT by running this library
///         and recording what it said. A self-generated vector proves only that the code is
///         deterministic — it would confirm a wrong tweak just as happily as a right one.
contract TaprootLeafKeyTest is Test {
    // secp256k1 G.x, standing in for the PINNED fleet deposit internal key.
    bytes32 constant INTERNAL =
        bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    // A real x-only curve point standing in for the user's refund key.
    bytes32 constant REFUND =
        bytes32(uint256(0x2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4));
    uint32 constant CLTV = 800_001;

    /// The leaf `swap_in_onchain.rs::refund_leaf` builds:
    /// `<cltv> OP_CLTV OP_DROP <user_refund> OP_CHECKSIG`.
    /// `<cltv>` is a MINIMAL script number: 800001 = 0x0C3501 → LE `01 35 0c`, high bit clear,
    /// so 3 bytes with no sign padding. Getting that encoding wrong changes the leaf hash and
    /// therefore the address — silently, which is why the expected bytes are pinned here.
    function _leafScript() internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(0x03), bytes3(0x01350c),   // PUSH3 <cltv little-endian>
            bytes1(0xb1),                     // OP_CHECKLOCKTIMEVERIFY
            bytes1(0x75),                     // OP_DROP
            bytes1(0x20), REFUND,             // PUSH32 <user refund x-only>
            bytes1(0xac)                      // OP_CHECKSIG
        );
    }

    function test_leafScriptMatchesTheRustBuilder() public pure {
        bytes memory s = _leafScript();
        assertEq(s.length, 40, "leaf script length");
        assertEq(
            keccak256(s),
            keccak256(hex"0301350cb175202f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4ac"),
            "leaf script bytes must match the Python/Rust construction exactly"
        );
    }

    function test_tapLeafHashMatchesBip341() public pure {
        assertEq(
            MuSig2Agg.tapLeafHash(_leafScript()),
            bytes32(0x3f4c19fe35422362757a3e4d12cb9ee71713dd4fae1a776b7b085312fb4048cc),
            "TapLeaf = tagged_hash(TapLeaf, 0xc0 || compactSize || script)"
        );
    }

    /// The whole point: `Q = lift_x_even(P) + H_TapTweak(x(P) || leafHash)*G`.
    function test_outputKeyMatchesBip341() public view {
        bytes32 leaf = MuSig2Agg.tapLeafHash(_leafScript());
        assertEq(
            MuSig2Agg.taprootOutputKeyWithLeaf(INTERNAL, leaf),
            bytes32(0xd0d16740ae143319f7883497b4b76efd9bb829725cf7e885c37dacff3be4e4ca),
            "single-leaf taproot output key"
        );
    }

    /// ⚠️ THE CONTROL. Omitting the merkle root from the TapTweak is the exact mistake that
    /// would compile, pass a self-generated vector, and produce a KEY-PATH-ONLY address no
    /// deposit ever pays. If this ever equals the real output key, the tweak is not committing
    /// to the leaf and every downstream proof is checking the wrong address.
    function test_omittingTheLeafGivesADifferentKey() public view {
        bytes32 leaf = MuSig2Agg.tapLeafHash(_leafScript());
        bytes32 withLeaf = MuSig2Agg.taprootOutputKeyWithLeaf(INTERNAL, leaf);
        bytes32 withoutLeaf = MuSig2Agg.taprootOutputKeyWithLeaf(INTERNAL, bytes32(0));
        assertTrue(withLeaf != withoutLeaf, "TapTweak MUST commit to the merkle root");
    }

    /// A different refund key or a different timelock is a different address. Asserted because
    /// per-swap uniqueness rests entirely on the leaf once the internal key is pinned and
    /// shared across every swap.
    function test_leafUniquenessCarriesPerSwapIdentity() public view {
        bytes32 a = MuSig2Agg.taprootOutputKeyWithLeaf(INTERNAL, MuSig2Agg.tapLeafHash(_leafScript()));
        bytes memory other = abi.encodePacked(
            bytes1(0x03), bytes3(0x02350c), bytes1(0xb1), bytes1(0x75),
            bytes1(0x20), REFUND, bytes1(0xac));      // cltv + 1
        bytes32 b = MuSig2Agg.taprootOutputKeyWithLeaf(INTERNAL, MuSig2Agg.tapLeafHash(other));
        assertTrue(a != b, "a different timelock must yield a different deposit address");
    }

    /// ⚠️ x = 5 is the FIRST off-curve x, and the value matters. This test was written with
    /// x = 1 and failed — not because the guard was broken but because **x = 1 IS on the
    /// curve**: y² = 1 + 7 = 8, and 8 is a quadratic residue mod p. A "surely invalid" constant
    /// picked by eye asserted the opposite of what it looked like, and a green run would have
    /// recorded the curve check as tested when it had never been exercised.
    function test_offCurveInternalKeyReverts() public {
        vm.expectRevert();
        MuSig2Agg.taprootOutputKeyWithLeaf(bytes32(uint256(5)), bytes32(0));
    }

    /// The companion to the above: x = 1 is a REAL point, so it must be accepted. Without this
    /// the revert test could be satisfied by a guard that rejects everything.
    function test_onCurveInternalKeyIsAccepted() public view {
        assertTrue(
            MuSig2Agg.taprootOutputKeyWithLeaf(bytes32(uint256(1)), bytes32(0)) != bytes32(0),
            "x=1 is on secp256k1 (y^2 = 8, a QR) and must not be rejected"
        );
    }
}
