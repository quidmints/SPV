// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from 'forge-std/Vm.sol';

/**
 * The blacklist root the withdrawal fixtures were proven against.
 *
 * READ FROM THE FILE, NOT PINNED. The root is a function of which entries are listed, so a constant
 * here goes stale the moment the fixture generator lists one more - and it goes stale SILENTLY in
 * the worst direction: `withdraw` substitutes the pool's root into the verifier's public inputs, so
 * a stale constant produces `InvalidProof`, which reads as a broken circuit rather than a stale
 * number. The same argument the registration root already carries in IdentityRegistry's tests.
 *
 * ⚠️ ONE ROOT SERVES BOTH FIXTURE SETS. The batch and the standalone withdrawals are proven against
 * separate query lists but the SAME tree, because a pool holds one root: two roots could not both
 * be current, and whichever was not would make its withdrawals unsettleable.
 */
library BlacklistRootFixture {
  function read(Vm vm) internal view returns (uint256) {
    return uint256(vm.parseJsonBytes32(vm.readFile('test/fixtures/blacklist_witness.json'), '.root'));
  }
}
