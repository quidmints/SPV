// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MuSig2Agg} from "../src/imports/MuSig2Agg.sol";

/// @notice (E129) `MuSig2Agg.isTwoOfTwoOutputKey` against a ground-truth vector produced by
///         the BIP-327 REFERENCE IMPLEMENTATION (bitcoin/bips bip-0327/reference.py), not by
///         reading my own code back to itself.
///
///         ⚠️ THIS CAUGHT TWO REAL BUGS, both of which compile and both of which produce a
///         plausible-looking aggregate that is simply the wrong point:
///           1. `key_agg_coeff_internal` returns **1** for the "second key" (the first entry
///              differing from `pubkeys[0]`) rather than a hash. I hashed both.
///           2. BIP-341 tweaks the **even-y lift** of the aggregate. I tweaked it as computed,
///              which is wrong for half of all key pairs.
///         Neither is visible by inspection. That is the whole argument for spec vectors.
contract MuSig2AggTest is Test {
    // Two compressed pubkeys from the BIP-327 example set.
    bytes constant PK_A =
        hex"02F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9";
    bytes constant PK_B =
        hex"03DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659";

    // Produced by reference.py: key_agg(sorted([A,B])) -> even-y lift -> BIP-341 TapTweak.
    bytes32 constant EXPECTED_Q =
        0xdee725e810716d6f0748b3d82aa67cdc1066028ffc8a8ebbe5ca148148153325;

    /// The whole point of the library: `Q` is accepted only if BOTH named keys are in it.
    function test_matches_the_bip327_reference_vector() public view {
        assertTrue(
            MuSig2Agg.isTwoOfTwoOutputKey(PK_A, PK_B, EXPECTED_Q),
            "Q == TapTweak(KeyAgg(KeySort(A,B)))"
        );
    }

    /// KeySort means argument order must not matter.
    function test_argument_order_is_irrelevant() public view {
        assertTrue(
            MuSig2Agg.isTwoOfTwoOutputKey(PK_B, PK_A, EXPECTED_Q),
            "KeySort makes (B,A) identical to (A,B)"
        );
    }

    /// ⚠️ THE CONTROL. Everything above would pass for a function that returned `true`
    ///    unconditionally. This is the property that actually matters: a `Q` the LP's key is
    ///    NOT inside must be refused — that is precisely the grow-splice custody migration
    ///    (E129) the library exists to stop.
    function test_rejects_a_Q_the_keys_are_not_in() public view {
        assertFalse(
            MuSig2Agg.isTwoOfTwoOutputKey(PK_A, PK_B, bytes32(uint256(EXPECTED_Q) ^ 1)),
            "a one-bit-different Q must be refused"
        );
        // A real curve point that simply is not this aggregate: the generator's x.
        assertFalse(
            MuSig2Agg.isTwoOfTwoOutputKey(PK_A, PK_B,
                bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798))),
            "G.x is a valid point but not this 2-of-2"
        );
    }

    /// Substituting either key must break it — the anti-substitution property.
    function test_rejects_a_substituted_key() public view {
        bytes memory other =
            hex"023590A94E768F8E1815C2F24B4D80A8E3149316C3518CE7B7AD338368D038CA66";
        assertFalse(MuSig2Agg.isTwoOfTwoOutputKey(PK_A, other, EXPECTED_Q), "B swapped out");
        assertFalse(MuSig2Agg.isTwoOfTwoOutputKey(other, PK_B, EXPECTED_Q), "A swapped out");
    }

    /// Malformed input is refused rather than silently mis-decoded.
    function test_rejects_malformed_pubkeys() public {
        vm.expectRevert(bytes("MuSig2Agg: bad SEC1 prefix"));
        this.callIsTwoOfTwo(hex"04F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9", PK_B, EXPECTED_Q);
    }

    function callIsTwoOfTwo(bytes memory a, bytes memory b, bytes32 q)
        external view returns (bool) { return MuSig2Agg.isTwoOfTwoOutputKey(a, b, q); }
}
