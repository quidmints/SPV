// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {PoseidonSMTMock} from '../mocks/state/PoseidonSMTMock.sol';

/// Every root is anchored on commit; this suite never reads the statements back.
contract SmtEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key_, bytes32 value_) external {
    statements[keccak256(abi.encodePacked(msg.sender, key_))] = value_;
  }
}

contract UnsafeSmtProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

/*
 * `isRootValid` is the guard under EVERY proof-consuming root check in this system
 * (sec. 2.18o): IdentityRegistry.register, HolderRegistration.registerDocumentViaIcao,
 * and Registration2's certificate gate all reduce to it.
 *
 * IT USED TO ACCEPT ROOTS THE TREE HAD NEVER HELD. `_roots[unknown]` is 0, so
 * `_roots[root] + ROOT_VALIDITY > block.timestamp` read as `3600 > block.timestamp` - true for
 * every invented root until an hour past the epoch. Live chains are far past that, which is the
 * only reason it was ever safe: a fact about the world, not a property of the code.
 *
 * Found because a test that did NOT warp - the natural way to write one - had its guard silently
 * pass. The same shape as X509's expiration read (sec. 2.18m): protection that came from an
 * accident rather than from an assertion.
 */
contract PoseidonSMTRootValidityTest is Test {
  PoseidonSMTMock internal smt;

  function setUp() public {
    smt = PoseidonSMTMock(address(new UnsafeSmtProxy(address(new PoseidonSMTMock()))));
    smt.__PoseidonSMT_init(address(this), address(new SmtEvidenceRegistry()), 80);
  }

  /// THE REGRESSION. At a low timestamp - a fresh chain, a devnet, or any un-warped test - an
  /// invented root must still be refused.
  /// @dev The low timestamp is now CONSTRUCTED, not inherited. This read `assertLt(block.timestamp,
  ///      1 hours)` against forge's un-warped default and that default is not a property of this
  ///      contract: a toolchain whose default `block.timestamp` is the wall clock turns the
  ///      PRECONDITION red and leaves the CLAIM below untested, which is the worse of the two
  ///      failures. `vm.warp` states the condition the test name asserts; the `assertLt` stays and
  ///      is not vacuous, because deleting the warp is what makes it fire.
  function test_AnUnknownRootIsInvalidEvenAtALowTimestamp() public {
    vm.warp(1);
    assertLt(block.timestamp, 1 hours, 'precondition: the warp above is what constructs this');

    assertFalse(smt.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
    assertFalse(smt.isRootValid(bytes32(uint256(1))), 'an invented root was accepted');
  }

  /// And at a realistic timestamp, which is where it accidentally worked before.
  function test_AnUnknownRootIsInvalidAtARealisticTimestamp() public {
    vm.warp(1_700_000_000);
    assertFalse(smt.isRootValid(bytes32(uint256(0xBAD0))), 'an invented root was accepted');
  }

  function test_TheZeroRootIsAlwaysInvalid() public view {
    assertFalse(smt.isRootValid(bytes32(0)), 'the zero root was accepted');
  }

  /// The latest root is valid however old, so inaction never invalidates a live tree.
  function test_TheLatestRootIsValid() public {
    smt.add(bytes32(uint256(7)), bytes32(uint256(7)));
    bytes32 latest = smt.getRoot();

    assertTrue(smt.isRootValid(latest), 'the latest root must be valid');

    vm.warp(block.timestamp + 3650 days);
    assertTrue(smt.isRootValid(latest), 'the latest root expired');
  }

  /// A superseded root stays valid for its grace window, then stops.
  function test_ASupersededRootExpires() public {
    vm.warp(1_700_000_000);
    smt.add(bytes32(uint256(7)), bytes32(uint256(7)));
    bytes32 first = smt.getRoot();

    smt.add(bytes32(uint256(8)), bytes32(uint256(8)));
    assertTrue(smt.isRootValid(first), 'a just-superseded root should still be usable');
    assertFalse(smt.isRootLatest(first), 'precondition: it is no longer latest');

    vm.warp(block.timestamp + 1 hours + 1);
    assertFalse(smt.isRootValid(first), 'a superseded root never expired');
  }
}
