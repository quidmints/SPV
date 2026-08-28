// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {InternalLeanIMT, LeanIMTData} from 'lean-imt/InternalLeanIMT.sol';

/*
 * sec. 2A Phase 1b feasibility probe.
 *
 * Phase 1b moves ASP admission from operator-pushed roots to on-chain incremental insertion, which
 * is what makes the tree append-only BY CONSTRUCTION and removes the postman's ability to drop a
 * member (sec. 2.13 channel 2). The known cost is that admission becomes one on-chain insert per
 * identity instead of one batched root push.
 *
 * This measures that cost rather than estimating it, because the answer decides whether Phase 1b is
 * viable as scoped. A LeanIMT insert is O(log n) Poseidon hashes and Poseidon is expensive on the
 * EVM, so the growth curve matters as much as the absolute number.
 */
contract AspTreeGasProbe is Test {
  using InternalLeanIMT for LeanIMTData;

  LeanIMTData internal tree;

  function _insert(uint256 _leaf) internal returns (uint256 _gasUsed) {
    uint256 _before = gasleft();
    tree._insert(_leaf);
    _gasUsed = _before - gasleft();
  }

  /// @dev MEASUREMENT ONLY - deliberately has no assertion; it exists to print the gas curve.
  /// Named `test_` so `forge test` runs it, but do not mistake it for coverage.
  function test_MeasureInsertCostAcrossTreeGrowth() public {
    uint256[] memory _samplePoints = new uint256[](6);
    _samplePoints[0] = 1;
    _samplePoints[1] = 2;
    _samplePoints[2] = 16;
    _samplePoints[3] = 128;
    _samplePoints[4] = 1024;
    _samplePoints[5] = 4096;

    uint256 _next;
    for (uint256 _s = 0; _s < _samplePoints.length; ++_s) {
      uint256 _target = _samplePoints[_s];
      uint256 _lastGas;
      while (_next < _target) {
        // Leaf values must be non-zero: LeanIMT treats 0 as "empty sibling".
        _lastGas = _insert(_next + 1);
        ++_next;
      }
      emit log_named_uint(
        string.concat('insert #', vm.toString(_target), ' gas'), _lastGas
      );
      emit log_named_uint(string.concat('  tree depth at ', vm.toString(_target)), tree.depth);
    }
  }
}
