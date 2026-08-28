// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BlacklistAnchorFixture} from './helpers/BlacklistAnchorFixture.sol';
import {BlacklistRootFixture} from './helpers/BlacklistRootFixture.sol';
import {DeployLib} from 'contracts/pool/lib/DeployLib.sol';
import {PrivacyPoolSimple} from 'contracts/pool/implementations/PrivacyPoolSimple.sol';
import {PrivacyPoolComplex} from 'contracts/pool/implementations/PrivacyPoolComplex.sol';
import {PrivacyPool} from 'contracts/pool/PrivacyPool.sol';
import {IPrivacyPool} from 'contracts/pool/interfaces/IPrivacyPool.sol';
import {NoirVerifierMock} from '../mocks/verifiers/NoirVerifierMock.sol';
import {MockEntrypoint} from './PrivacyPoolSimple.t.sol';

/*
 * THE DEPLOYMENT PATH, WHICH DID NOT EXIST.
 *
 * `DeployLib` held SALTS AND NOTHING ELSE - no function in the repo constructed a pool, there is no
 * `script/` directory, and all five construction sites were tests. Two consequences that only look
 * like documentation problems until you try to ship:
 *
 *   1. `BATCH_VERIFIER` had NO path by which a real deployment could set it, so `withdrawBatch`
 *      could never be enabled however correct the contract was.
 *   2. `PrivacyPoolComplex` had never been deployed by anything - its salt was declared and never
 *      used - so the entire ERC-20 path shipped to nobody.
 *
 * This suite exercises the deployment functions themselves, so the path is verified rather than
 * merely present. It deliberately does NOT deploy the identity/state layer: those have their own
 * constructors and suites, and the gap being closed here is the pool layer.
 */
contract DeployPoolTest is Test, BlacklistAnchorFixture {
  MockEntrypoint internal entrypoint;
  address internal withdrawalVerifier;
  address internal ragequitVerifier;
  address internal batchVerifier;

  function setUp() public {
    entrypoint = new MockEntrypoint();
    withdrawalVerifier = address(new NoirVerifierMock());
    ragequitVerifier = address(new NoirVerifierMock());
    batchVerifier = address(new NoirVerifierMock());
    // A pool cannot be deployed without a blacklist source now - which is the point of this suite:
    // it asserts DeployLib can build a pool a real deployment could use.
    _deployBlacklistAnchor(BlacklistRootFixture.read(vm));
  }

  function _simple(address aggregation_) internal returns (PrivacyPoolSimple) {
    return DeployLib.deploySimplePool(
      address(entrypoint), withdrawalVerifier, ragequitVerifier, address(entrypoint), aggregation_,
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );
  }

  // ── the gap this closes ───────────────────────────────────────────────────────────────────

  /// The whole point: a deployed pool can now HAVE an aggregation verifier.
  function test_DeployedPoolCarriesTheAggregationVerifier() public {
    PrivacyPoolSimple pool = _simple(batchVerifier);
    assertEq(
      address(pool.BATCH_VERIFIER()),
      batchVerifier,
      'a deployed pool still cannot be given an aggregation verifier'
    );
  }

  /// ...and batching is genuinely reachable on it, rather than reverting on an unset verifier.
  /// Reaching `EmptyBatch` proves execution got PAST the configuration guard.
  function test_BatchingIsReachableOnADeployedPool() public {
    PrivacyPoolSimple pool = _simple(batchVerifier);
    IPrivacyPool.Withdrawal[] memory ws = new IPrivacyPool.Withdrawal[](0);
    uint256[8][] memory s = new uint256[8][](0);
    // NOT BatchVerifierNotConfigured - that is the distinction being asserted.
    vm.expectRevert(bytes4(keccak256('EmptyBatch()')));
    pool.withdrawBatch(ws, s, '');
  }

  /// Zero is a legitimate deployment - a pool that does not offer batching - and must refuse
  /// explicitly rather than call into an empty address.
  function test_APoolMayBeDeployedWithoutBatching() public {
    PrivacyPoolSimple pool = _simple(address(0));
    assertEq(address(pool.BATCH_VERIFIER()), address(0));
    IPrivacyPool.Withdrawal[] memory ws = new IPrivacyPool.Withdrawal[](1);
    uint256[8][] memory s = new uint256[8][](1);
    vm.expectRevert(PrivacyPool.BatchVerifierNotConfigured.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// `PrivacyPoolComplex` had never been deployed by ANYTHING. Now it is, through the same path.
  function test_ComplexPoolCanBeDeployed() public {
    address asset = address(0xC0FFEE);
    PrivacyPoolComplex pool = DeployLib.deployComplexPool(
      address(entrypoint), withdrawalVerifier, ragequitVerifier, asset, address(entrypoint), batchVerifier,
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );
    assertEq(pool.ASSET(), asset);
    assertEq(address(pool.BATCH_VERIFIER()), batchVerifier);
  }

  // ── determinism, which is the reason the salts exist at all ───────────────────────────────

  /// External so the CREATE2 failure reverts at a LOWER depth than the cheatcode - a revert raised
  /// during CREATE in this contract's own frame does not match `expectRevert`, the same wrinkle
  /// PrivacyPoolComplexTest documents for its native-asset guard.
  function deploySimpleExternal(address aggregation_) external returns (PrivacyPoolSimple) {
    return _simple(aggregation_);
  }

  /// Same deployer + same salt must collide on a second deployment. If it did not, the addresses
  /// were never deterministic and the salts were decoration.
  function test_TheSaltMakesTheAddressDeterministic() public {
    this.deploySimpleExternal(batchVerifier);
    vm.expectRevert(); // CREATE2 collision: the address is already occupied
    this.deploySimpleExternal(batchVerifier);
  }

  /// A different deployer must get a different address, or two operators would fight over one slot.
  function test_DifferentDeployersGetDifferentAddresses() public {
    PrivacyPoolSimple a = _simple(batchVerifier);
    vm.prank(address(0xBEEF));
    PrivacyPoolSimple b = _simple(batchVerifier);
    assertTrue(address(a) != address(b), 'the salt does not bind the deployer');
  }
}
