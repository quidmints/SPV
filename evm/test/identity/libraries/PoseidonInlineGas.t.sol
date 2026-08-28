// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {PoseidonT3Inline} from 'contracts/libraries/inline/PoseidonT3Inline.sol';

/*
 * WHAT INLINING POSEIDON ACTUALLY SAVES - measured, because the figure in TODO sec. 2.x
 * ("over 1M gas today, ~90k inlined" for a depth-32 insert) implies a ~91% cut and is used to
 * prioritise work.
 *
 * TWO THINGS TO SETTLE:
 *   1. the per-hash delta between the DELEGATECALL (`public` upstream) and inline (`internal`) forms;
 *   2. whether that delta is the dominant term in an SMT insert, or a rounding error next to
 *      Poseidon's own intrinsic cost.
 *
 * This matters because a 91% claim justifies doing it FIRST. If the saving is the call overhead only,
 * the intrinsic permutation cost survives inlining and the work is worth far less than advertised.
 */
contract PoseidonInlineGasTest is Test {
    /// A library with `public` functions is DELEGATECALLed; this forces that path to be real.
    function _upstream(uint256 a, uint256 b) external pure returns (uint256) {
        return PoseidonT3.hash([a, b]);
    }

    function test_MeasureInlineVersusDelegatecall() public {
        uint256 a = 0x1234567890abcdef;
        uint256 b = 0xfedcba0987654321;

        uint256 g0 = gasleft();
        uint256 inlineResult = PoseidonT3Inline.hash([a, b]);
        uint256 inlineGas = g0 - gasleft();

        g0 = gasleft();
        uint256 extResult = this._upstream(a, b);
        uint256 extGas = g0 - gasleft();

        assertEq(inlineResult, extResult, 'the two forms must agree');

        emit log_named_uint('inline (internal) gas', inlineGas);
        emit log_named_uint('external call gas    ', extGas);
        emit log_named_uint('saving per hash      ', extGas - inlineGas);
        emit log_named_uint('saving as % of ext   ', ((extGas - inlineGas) * 100) / extGas);

        // A depth-32 SMT insert is ~32 hashes. Project both, so the priority claim is checkable.
        emit log_named_uint('depth-32 inline  (32x)', inlineGas * 32);
        emit log_named_uint('depth-32 external(32x)', extGas * 32);
    }
}
