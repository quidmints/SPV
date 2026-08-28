// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {RegistrySourceAnchor} from 'contracts/registry/RegistrySourceAnchor.sol';
import {MockEvidenceRegistry} from '../../title/TitleLedger.t.sol';

/**
 * Stand up a REAL `RegistrySourceAnchor` holding a published, activated blacklist root.
 *
 * ⚠️ THE POOL NO LONGER TAKES A ROOT, SO A TEST CANNOT HAND IT ONE. `PrivacyPool` pulls from an
 * anchor precisely so that nobody - including a test - can choose the value. That is the property
 * being protected, so the setup cost here is the property working: to give a pool a root you must
 * publish one the way production does, through `onReport` with a pinned workflow, from the pinned
 * forwarder, and then wait out the activation delay.
 *
 * ⛔ THE EVIDENCE REGISTRY IS THE ONE STUB, AND IT IS NOT THE THING UNDER TEST. `IEvidenceRegistry`
 * is Rarimo's, external, with no implementation in this repo, and the anchor's only use of it is a
 * single `addStatement` on publication. Stubbing a collaborator that does not exist here is not the
 * same as stubbing the mechanism being asserted - the anchor, its workflow pin, its forwarder gate
 * and its activation delay are all real.
 */
abstract contract BlacklistAnchorFixture is Test {
  /// The registry within the anchor that carries the blacklist. Arbitrary but fixed.
  bytes32 internal constant BLACKLIST_REGISTRY = keccak256('quid.blacklist.v1');

  /// The workflow permitted to publish it. Reports naming anything else are refused.
  bytes32 internal constant BLACKLIST_WORKFLOW = keccak256('sanctions_lists.wasm@test');

  address internal constant ANCHOR_ADMIN = address(0xA11CE);
  address internal constant ANCHOR_FORWARDER = address(0xF0DA);

  RegistrySourceAnchor internal blacklistAnchor;

  /**
   * Deploy the anchor and publish `smtRoot_` as an ACTIVE snapshot.
   *
   * ⚠️ WARPS TIME TWICE, and both are load-bearing: once past `WORKFLOW_ACTIVATION_DELAY` so the pin
   * takes effect before publishing, and once past `ROOT_ACTIVATION_DELAY` so the snapshot becomes
   * the ACTIVE one. Skip the second and `latestActiveSmtRoot` reverts `NoActiveSnapshot` - correctly,
   * and it reads exactly like a broken pool.
   */
  function _deployBlacklistAnchor(uint256 smtRoot_) internal {
    // Direct construction: the anchor is not upgradeable, so config is constructor-set.
    blacklistAnchor = new RegistrySourceAnchor(address(new MockEvidenceRegistry()), ANCHOR_ADMIN);

    vm.startPrank(ANCHOR_ADMIN);
    blacklistAnchor.pinWorkflow(BLACKLIST_REGISTRY, BLACKLIST_WORKFLOW);
    blacklistAnchor.setForwarder(ANCHOR_FORWARDER); // first set is immediate: no incumbent to protect
    vm.stopPrank();
    vm.warp(block.timestamp + blacklistAnchor.WORKFLOW_ACTIVATION_DELAY() + 1);

    _publishBlacklistRoot(smtRoot_);
  }

  /// Publish another snapshot and activate it. Used to test rotation.
  function _publishBlacklistRoot(uint256 smtRoot_) internal {
    bytes32[] memory leaves_ = new bytes32[](1);
    leaves_[0] = keccak256('blacklist-leaf-set');

    vm.prank(ANCHOR_FORWARDER);
    blacklistAnchor.onReport(
      _anchorMetadata(BLACKLIST_WORKFLOW),
      abi.encode(BLACKLIST_REGISTRY, bytes32(smtRoot_), leaves_)
    );
    vm.warp(block.timestamp + blacklistAnchor.ROOT_ACTIVATION_DELAY() + 1);
  }

  /**
   * The 109-byte CRE header, with the workflow id at offset 45.
   *
   * Duplicated from `test/registry/CreReportMetadata.sol` deliberately rather than imported: that
   * contract is inherited by the registry suites, and inheriting it here too would drag its whole
   * fixture surface into every pool test. The layout is pinned in its docblock; if it ever moves,
   * both copies fail together because the anchor rejects the report.
   */
  function _anchorMetadata(bytes32 workflowId_) internal pure returns (bytes memory) {
    return abi.encodePacked(
      bytes1(0x01),        // version
      bytes32(0),          // executionId
      bytes4(0),           // timestamp
      bytes4(0),           // donId
      bytes4(0),           // donConfigVersion
      workflowId_,         // workflowId  <- offset 45
      bytes10(0),          // workflowName
      bytes20(0),          // workflowOwner
      bytes2(0)            // reportId
    );
  }
}
