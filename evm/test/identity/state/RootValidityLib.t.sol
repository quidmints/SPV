// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {RootValidity} from 'contracts/state/RootValidity.sol';

/*
 * THE LIBRARY ITSELF, DIRECTLY.
 *
 * `RootValidityCopiesTest` and `PoseidonSMTRootValidityTest` are named after this library but
 * NEITHER IMPORTS IT - they drive `L1RegistrationState`, `RegistrationSMTReplicator` and
 * `PoseidonSMT` and assert the behaviour through them. So the rule was covered only as far as its
 * three current consumers exercise it, and a FOURTH consumer adopting it wrongly would have been
 * caught by nothing.
 *
 * That matters more here than it would elsewhere: this library exists BECAUSE the rule was written
 * out three separate times and all three copies carried the same defect (an unrecorded root maps to
 * 0, so `0 + validity > block.timestamp` returned true for every invented root on a young chain).
 * The whole point was to have one definition; a definition with no direct test is one nobody can
 * check without a consumer.
 *
 * Each test below names the clause it pins, in the order the library documents them.
 */
contract RootValidityLibTest is Test {
  uint256 internal constant WINDOW = 1 hours;

  /// Wrapper: the library is `internal`, and calling through a contract also proves it is usable
  /// the way a consumer would use it rather than only via the test's own inlining.
  function isValid(bytes32 root_, bool isLatest_, uint256 recordedAt_, uint256 window_)
    external
    view
    returns (bool)
  {
    return RootValidity.isValid(root_, isLatest_, recordedAt_, window_);
  }

  function setUp() public {
    // A chain YOUNGER than the validity window - the exact condition under which the original
    // defect returned true. Testing at a large timestamp would hide it.
    vm.warp(WINDOW / 2);
  }

  // ── clause 1: the zero root is never valid ────────────────────────────────────────────────

  function test_ZeroRootIsNeverValid() public view {
    // Not even as the latest root, and not even when recorded - it is the empty-tree sentinel and
    // the default of any unset slot, so accepting it means accepting an uninitialised anything.
    assertFalse(this.isValid(bytes32(0), true, block.timestamp, WINDOW));
    assertFalse(this.isValid(bytes32(0), false, block.timestamp, WINDOW));
    assertFalse(this.isValid(bytes32(0), true, 0, WINDOW));
  }

  // ── clause 2: the latest root is always valid, however old ────────────────────────────────

  function test_LatestRootStaysValidHoweverOld() public {
    bytes32 root = keccak256('latest');
    uint256 recorded = block.timestamp;
    vm.warp(block.timestamp + 3650 days); // a decade of nobody updating the tree
    assertTrue(
      this.isValid(root, true, recorded, WINDOW),
      'inaction became censorship: a stale tree stopped admitting its own members'
    );
  }

  // ── clause 3: a superseded root is valid only briefly, and only if it EXISTED ──────────────

  /// THE DEFECT THIS LIBRARY WAS CREATED TO KILL. `recordedAt_ == 0` means the tree never held this
  /// root; without that clause the arithmetic reads `0 + WINDOW > block.timestamp`, which is TRUE
  /// on any chain younger than the window - so every invented root passed.
  function test_UnrecordedRootIsRejectedEvenOnAYoungChain() public view {
    assertLt(block.timestamp, WINDOW, 'the fixture must sit inside the window or it proves nothing');
    assertFalse(
      this.isValid(keccak256('never recorded'), false, 0, WINDOW),
      'an invented root was accepted - the recordedAt != 0 clause is gone'
    );
  }

  function test_SupersededRootIsValidInsideTheWindow() public {
    bytes32 root = keccak256('superseded');
    uint256 recorded = block.timestamp;
    vm.warp(recorded + WINDOW - 1);
    assertTrue(this.isValid(root, false, recorded, WINDOW));
  }

  /// The boundary is strict: `recordedAt + window > now`, so exactly at the edge it is EXPIRED.
  /// Pinned because an off-by-one here silently widens the grace period for every consumer.
  function test_SupersededRootExpiresAtTheBoundary() public {
    bytes32 root = keccak256('superseded');
    uint256 recorded = block.timestamp;
    vm.warp(recorded + WINDOW);
    assertFalse(this.isValid(root, false, recorded, WINDOW), 'the boundary is inclusive - it must not be');
    vm.warp(recorded + WINDOW + 1);
    assertFalse(this.isValid(root, false, recorded, WINDOW));
  }

  /// A zero window means no grace at all: a superseded root is immediately unusable. Consumers may
  /// legitimately configure this, so it must not underflow into "always valid".
  function test_ZeroWindowGivesNoGrace() public view {
    assertFalse(this.isValid(keccak256('superseded'), false, block.timestamp, 0));
    // ...but the latest root is still valid, because clause 2 does not consult the window.
    assertTrue(this.isValid(keccak256('latest'), true, block.timestamp, 0));
  }

  /// A window large enough to overflow must not wrap into acceptance. `recordedAt + window` is
  /// unchecked-free in 0.8, so this reverts rather than silently passing - pin which it is.
  function test_AbsurdWindowRevertsRatherThanWrapping() public {
    vm.expectRevert(); // arithmetic overflow, not a silent `true`
    this.isValid(keccak256('superseded'), false, type(uint256).max, type(uint256).max);
  }
}
