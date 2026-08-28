// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';

/*
 * WHAT A GROTH16 VERIFICATION COSTS ON-CHAIN - PRICED FROM THE PRECOMPILES (2026-08-04).
 *
 * WHY NOT JUST CALL A GROTH16 VERIFIER. Tried that first, and the result was 1,040,429,520 gas -
 * because a snarkjs-generated verifier answers an invalid proof with `invalid()` (0xfe), which
 * BURNS ALL REMAINING GAS. So a rejection costs nothing like an acceptance, and without the trusted
 * setup we deliberately do not have, no valid proof exists to measure. Recorded because the failure
 * is instructive: "constant-time verification" is true of the ALGORITHM and false of the CONTRACT.
 *
 * WHAT IS MEASURED INSTEAD. Groth16 verification is dominated by ONE `ecPairing` call over 4 pairs,
 * plus a handful of `ecAdd`/`ecMul` to fold the public inputs. Those precompiles are priced by INPUT
 * SIZE, not by whether the pairing holds (EIP-1108), so calling them with well-formed points gives
 * the true cost of the dominant term. This is a measurement of the EVM, not of a proof.
 */
contract VerificationCostComparisonTest is Test {
    /// Measured elsewhere in this suite, restated so the comparison is legible in one place.
    uint256 internal constant HONK_SINGLE = 2_528_007;
    uint256 internal constant HONK_BATCH16_TOTAL = 2_980_094;

    function test_MeasureGroth16DominantTerm() public view {
        // 4 pairs of (G1, G2) points - the shape Groth16 verification submits. Using the curve
        // generators keeps the input well-formed so the precompile prices it normally.
        uint256[24] memory input;
        for (uint256 i = 0; i < 4; ++i) {
            input[i * 6 + 0] = 1; // G1.x
            input[i * 6 + 1] = 2; // G1.y
            input[i * 6 + 2] = 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2;
            input[i * 6 + 3] = 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed;
            input[i * 6 + 4] = 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b;
            input[i * 6 + 5] = 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa;
        }

        uint256 g0 = gasleft();
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x08, input, 0x300, 0x00, 0x20)
        }
        uint256 pairingGas = g0 - gasleft();

        // ecMul, used ~1x per public input to fold the IC points.
        uint256[3] memory mulIn = [uint256(1), uint256(2), uint256(7)];
        g0 = gasleft();
        assembly {
            ok := staticcall(gas(), 0x07, mulIn, 0x60, 0x00, 0x40)
        }
        uint256 mulGas = g0 - gasleft();

        uint256 groth16Estimate = pairingGas + 5 * mulGas + 21_000 / 10; // 5 public inputs + overhead

        console.log('ecPairing (4 pairs) gas:      ', pairingGas);
        console.log('ecMul gas (per public input): ', mulGas);
        console.log('groth16 verification, approx: ', groth16Estimate);
        console.log('honk SINGLE withdrawal verify:', HONK_SINGLE);
        console.log('  ratio honk/groth16:         ', HONK_SINGLE / groth16Estimate);
        console.log('honk batch of 16, per w/d:    ', HONK_BATCH16_TOTAL / 16);
        console.log('  ratio batched/groth16:      ', (HONK_BATCH16_TOTAL / 16) * 100 / groth16Estimate);

        assertTrue(ok, 'precompile call failed');
        assertGt(pairingGas, 100_000, 'pairing did not run');
    }
}
