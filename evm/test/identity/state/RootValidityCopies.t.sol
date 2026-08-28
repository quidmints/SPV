// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {L1RegistrationState} from '../../../src/identity/state/L1RegistrationState.sol';
import {RegistrationSMTReplicator} from '../../../src/identity/sdk/RegistrationSMTReplicator.sol';

contract UnsafeRootProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

/*
 * THE OTHER TWO COPIES of the root-validity defect (sec. 2.18o).
 *
 * `PoseidonSMT.isRootValid` accepted roots the tree had never held, because an unrecorded root maps
 * to 0 and `0 + ROOT_VALIDITY > block.timestamp` is TRUE until an hour past the epoch. Grepping the
 * pattern found the same line in two more places, and both guard proofs:
 *
 *   - `L1RegistrationState` - the L1 state that `RegistrationSMT` extends.
 *   - `RegistrationSMTReplicator` - the L2 MIRROR, where this matters most: a rollup counting from
 *     a low timestamp is not a hypothetical, it is the deployment target.
 *
 * Neither had a single test. The fix in each is one existence check, and these are what stop it
 * coming back - a third rewrite of the same expression is exactly how it would.
 */
contract RootValidityCopiesTest is Test {
  L1RegistrationState internal l1;
  RegistrationSMTReplicator internal replicator;

  address internal constant ROLLUP = address(0x9011);
  address internal constant ORACLE = address(0x0AC1E5);

  function setUp() public {
    l1 = L1RegistrationState(address(new UnsafeRootProxy(address(new L1RegistrationState()))));
    l1.__L1RegistrationState_init(address(this), ROLLUP);

    replicator =
      RegistrationSMTReplicator(address(new UnsafeRootProxy(address(new RegistrationSMTReplicator()))));
    address[] memory oracles = new address[](1);
    oracles[0] = ORACLE;
    replicator.__RegistrationSMTReplicator_init(oracles, address(0xDEAD));
  }

  // ── L1RegistrationState ────────────────────────────────────────────────────────────────────

  /// THE REGRESSION. Un-warped is the natural way to write a test, and it is exactly the condition
  /// that used to make every invented root valid.
  function test_L1_AnUnknownRootIsInvalidAtALowTimestamp() public view {
    assertLt(block.timestamp, 1 hours, 'precondition: the default timestamp is what exposed this');
    assertFalse(l1.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
  }

  function test_L1_AnUnknownRootIsInvalidAtARealisticTimestamp() public {
    vm.warp(1_700_000_000);
    assertFalse(l1.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
  }

  function test_L1_TheZeroRootIsAlwaysInvalid() public view {
    assertFalse(l1.isRootValid(bytes32(0)));
  }

  function test_L1_ARootTheRollupSetIsValidAndTheLatestNeverExpires() public {
    vm.warp(1_700_000_000);
    vm.prank(ROLLUP);
    l1.setRegistrationRoot(bytes32(uint256(7)), block.timestamp);

    assertTrue(l1.isRootValid(bytes32(uint256(7))), 'a root the rollup set was rejected');

    vm.warp(block.timestamp + 3650 days);
    assertTrue(l1.isRootValid(bytes32(uint256(7))), 'the latest root expired');
  }

  function test_L1_ASupersededRootExpires() public {
    vm.warp(1_700_000_000);
    vm.startPrank(ROLLUP);
    l1.setRegistrationRoot(bytes32(uint256(7)), block.timestamp);
    l1.setRegistrationRoot(bytes32(uint256(8)), block.timestamp + 1);
    vm.stopPrank();

    assertTrue(l1.isRootValid(bytes32(uint256(7))), 'a just-superseded root should still be usable');

    vm.warp(block.timestamp + 1 hours + 1);
    assertFalse(l1.isRootValid(bytes32(uint256(7))), 'a superseded root never expired');
  }

  // ── RegistrationSMTReplicator (the L2 mirror) ──────────────────────────────────────────────

  /// THE ONE THAT MATTERS MOST. This contract exists to run on an L2, and an L2 counting from a low
  /// timestamp is the ordinary case rather than the exotic one.
  function test_Replicator_AnUnknownRootIsInvalidAtALowTimestamp() public view {
    assertLt(block.timestamp, 1 hours, 'precondition: a low chain timestamp');
    assertFalse(replicator.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
  }

  function test_Replicator_AnUnknownRootIsInvalidAtARealisticTimestamp() public {
    vm.warp(1_700_000_000);
    assertFalse(replicator.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
  }

  function test_Replicator_TheZeroRootIsAlwaysInvalid() public view {
    assertFalse(replicator.isRootValid(bytes32(0)));
  }

  function test_Replicator_ATransitionedRootIsValid() public {
    vm.warp(1_700_000_000);
    vm.prank(ORACLE);
    replicator.transitionRoot(bytes32(uint256(7)), block.timestamp);

    assertTrue(replicator.isRootValid(bytes32(uint256(7))), 'a transitioned root was rejected');
  }

  function test_Replicator_ASupersededRootExpires() public {
    vm.warp(1_700_000_000);
    vm.startPrank(ORACLE);
    replicator.transitionRoot(bytes32(uint256(7)), block.timestamp);
    replicator.transitionRoot(bytes32(uint256(8)), block.timestamp + 1);
    vm.stopPrank();

    assertTrue(replicator.isRootValid(bytes32(uint256(7))), 'a just-superseded root should be usable');

    vm.warp(block.timestamp + 1 hours + 1);
    assertFalse(replicator.isRootValid(bytes32(uint256(7))), 'a superseded root never expired');
  }
}
