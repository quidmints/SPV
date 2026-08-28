// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {PoseidonT3Inline} from 'contracts/libraries/inline/PoseidonT3Inline.sol';

/*
 * WHAT A SANCTIONS ROOT COSTS TO COMPUTE ON-CHAIN, PER HASH FUNCTION (TODO.md sec. 2.18db / 2.18ep).
 *
 * 2.18db left the sanctions root's hash open and asked for a measurement rather than a preference,
 * because the two candidates are cheap in OPPOSITE places:
 *
 *   keccak    ~30 gas on the EVM        heavy in a circuit
 *   Poseidon  cheap in a circuit        thousands of gas on the EVM
 *
 * The question became decidable once the tree got a definite in-circuit consumer: a holder proving
 * their document is NOT on the list (2.18ep). This file measures the EVM half, which is the half
 * that could kill the design - `RegistrySourceAnchor._computeRoot` hashes the WHOLE leaf set on
 * every refresh, so the per-hash cost is multiplied by N-1.
 *
 * MEASURED HERE, NOT ESTIMATED, because 2.18db's own figure (32,549 gas) was for a DELEGATECALL to a
 * library and the inlined form is the one that would actually be used.
 *
 * This is a cost probe, not a behavioural test. It asserts only that the measurement ran.
 */
contract SanctionsRootHashCostTest is Test {
    /// Realistic list sizes. The OFAC SDN is ~17k entries; a document tree emits at least one leaf
    /// per published passport, so the interesting range is thousands to tens of thousands.
    uint256 internal constant SMALL = 1_000;
    uint256 internal constant SDN_SCALE = 17_000;

    function _leaves(uint256 n) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) out[i] = keccak256(abi.encodePacked(i));
    }

    /// One keccak pair-hash, sorted - exactly `RegistrySourceAnchor._hashSortedPair`.
    function _keccakPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// The same shape with Poseidon, which is what an in-circuit consumer would want.
    function _poseidonPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? bytes32(PoseidonT3Inline.hash([uint256(a), uint256(b)]))
            : bytes32(PoseidonT3Inline.hash([uint256(b), uint256(a)]));
    }

    function test_MeasurePerHashCost() public view {
        bytes32 a = keccak256('a');
        bytes32 b = keccak256('b');

        uint256 g0 = gasleft();
        _keccakPair(a, b);
        uint256 kGas = g0 - gasleft();

        g0 = gasleft();
        _poseidonPair(a, b);
        uint256 pGas = g0 - gasleft();

        console.log('keccak   pair hash gas:', kGas);
        console.log('poseidon pair hash gas:', pGas);
        console.log('  ratio poseidon/keccak:', pGas / (kGas == 0 ? 1 : kGas));
        console.log('');
        console.log('a tree over N leaves costs N-1 pair hashes:');
        console.log('  N=1,000   keccak:', (SMALL - 1) * kGas);
        console.log('  N=1,000 poseidon:', (SMALL - 1) * pGas);
        console.log('  N=17,000  keccak:', (SDN_SCALE - 1) * kGas);
        console.log('  N=17,000 poseidon:', (SDN_SCALE - 1) * pGas);
        console.log('');
        console.log('for reference, an Ethereum block is 30,000,000 gas');

        assertGt(kGas, 0, 'keccak measurement did not run');
        assertGt(pGas, 0, 'poseidon measurement did not run');
    }

    /*
     * AND THE CALLDATA, which is the cost nobody costs. `_computeRoot` takes the FULL leaf set as
     * calldata so the snapshot is self-contained and replayable - that is a deliberate design
     * property, not an oversight - but it means every refresh pays for N words of calldata whatever
     * the hash is. At 16 gas per non-zero byte that is often the DOMINANT term, and it applies to
     * the existing keccak design exactly as much as to any Poseidon replacement.
     */
    function test_MeasureCalldataFloor() public pure {
        uint256 perLeafBytes = 32;
        uint256 gasPerNonZeroByte = 16;
        uint256 small = SMALL * perLeafBytes * gasPerNonZeroByte;
        uint256 sdn = SDN_SCALE * perLeafBytes * gasPerNonZeroByte;

        console.log('calldata floor, ignoring hashing entirely:');
        console.log('  N=1,000  leaves:', small);
        console.log('  N=17,000 leaves:', sdn);
        console.log('  (32 bytes/leaf x 16 gas/non-zero byte)');
    }
}
