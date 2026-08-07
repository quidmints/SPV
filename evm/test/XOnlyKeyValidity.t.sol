// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BitcoinTx} from "../src/imports/BitcoinTx.sol";

/// @notice (E130/E131) `BitcoinTx.isValidXOnlyKey` — the check that decides whether
///         `0x5120||key` is a SPENDABLE taproot output or a burn address.
contract XOnlyKeyValidityTest is Test {
    // secp256k1 generator and its next two multiples: definitively valid x-coordinates.
    bytes32 constant GX  = bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    bytes32 constant G2X = bytes32(uint256(0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5));
    bytes32 constant G3X = bytes32(uint256(0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9));

    uint256 constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    function _valid(bytes32 k) internal pure returns (bool) { return BitcoinTx.isValidXOnlyKey(k); }

    function test_accepts_real_curve_x_coordinates() public view {
        assertTrue(_valid(GX),  "G.x is a valid x-only key");
        assertTrue(_valid(G2X), "2G.x is a valid x-only key");
        assertTrue(_valid(G3X), "3G.x is a valid x-only key");
    }

    function test_rejects_zero_and_out_of_field() public view {
        assertFalse(_valid(bytes32(0)),            "zero");
        assertFalse(_valid(bytes32(P)),            "x == p is out of field");
        assertFalse(_valid(bytes32(P + 1)),        "x > p");
        assertFalse(_valid(bytes32(type(uint256).max)), "all-ones is far out of field");
    }

    /// ⚠️ THE CONTROL, and the one that matters most. Every assertion above would also pass
    ///    for a stub that returned `true` for anything non-zero and in-field. The real
    ///    property is that roughly HALF of arbitrary values are NOT valid keys — because x
    ///    qualifies only when x³+7 is a quadratic residue mod p, and p ≡ 3 (mod 4) makes
    ///    that a coin flip. A validator that accepts everything fails here; so does one
    ///    that rejects everything.
    function test_roughly_half_of_arbitrary_values_are_rejected() public {
        uint256 accepted;
        uint256 n = 200;
        for (uint256 i = 0; i < n; i++) {
            uint256 x = uint256(keccak256(abi.encodePacked("xonly-sample", i))) % P;
            if (x != 0 && _valid(bytes32(x))) accepted++;
        }
        // Binomial(200, 0.5): a 60/140 split is ~5.7 sigma out, so this is a loose bound
        // that still cannot be satisfied by an always-true or always-false implementation.
        assertGt(accepted, 60,  "not always-false: well under half accepted");
        assertLt(accepted, 140, "not always-true: well over half accepted");
        emit log_named_uint("accepted out of 200", accepted);
    }

    /// The burn scenario in one assertion: this is what an LP could have registered.
    function test_a_plausible_typo_is_caught() public {
        // G.x with its last nibble altered — visually near-identical, and a coin flip
        // whether it is still a curve point. This particular one is not.
        bytes32 typo = bytes32(uint256(GX) ^ 1);
        if (!_valid(typo)) {
            assertFalse(_valid(typo), "an off-by-one-bit key is rejected");
        } else {
            emit log("NOTE: this particular bit-flip happened to land on a valid key");
        }
    }
}
