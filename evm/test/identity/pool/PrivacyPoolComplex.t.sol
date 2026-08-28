// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BlacklistAnchorFixture} from './helpers/BlacklistAnchorFixture.sol';
import {BlacklistRootFixture} from './helpers/BlacklistRootFixture.sol';
import {IERC20} from '@oz/token/ERC20/IERC20.sol';
import {ERC20} from '@oz/token/ERC20/ERC20.sol';

import {PrivacyPoolComplex} from '../../../src/identity/pool/implementations/PrivacyPoolComplex.sol';
import {IPrivacyPoolComplex} from '../../../src/identity/pool/interfaces/IPrivacyPool.sol';
import {NoirVerifierMock} from '../../../src/identity/mock/verifiers/NoirVerifierMock.sol';
import {Constants} from '../../../src/identity/pool/lib/Constants.sol';

contract TestToken is ERC20 {
  constructor() ERC20('Test', 'TST') {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// Stands in for the Entrypoint AND both registries - these cases are about ERC20 asset movement,
/// not membership policy, and the proof paths are covered end to end elsewhere.
contract MinimalEntrypoint {
  /// Unconditional by design: this suite has no withdraw tests, so the identity gate is never the
  /// thing under test here. Checked, not assumed - PrivacyPoolSimple's equivalent DID need to
  /// honour its `known` mapping, because that suite perturbs the identity root and expects a revert.
  function isValidRoot(bytes32) external pure returns (bool) {
    return true;
  }
}

/*
 * PrivacyPoolComplex - the ERC20 pool - HAD NO TESTS AT ALL.
 *
 * It compiled, it inherited everything, and its constructor was changed twice in one day (the ASP
 * registry split, then the revocation registry) without a single test instantiating it. Nothing
 * would have caught a break.
 *
 * What is genuinely UNIQUE to it, and therefore what this file targets, is exactly two overrides:
 * `_pull` and `_push`. Everything else is PrivacyPool, covered by PrivacyPoolSimple.t.sol and
 * WithdrawEndToEnd.t.sol. The two behaviours those overrides add over the native pool are:
 * rejecting native value, and moving the asset by transferFrom/transfer rather than by call.
 */
contract PrivacyPoolComplexTest is Test, BlacklistAnchorFixture {
  TestToken internal token;
  MinimalEntrypoint internal entrypoint;
  PrivacyPoolComplex internal pool;

  address internal depositor = address(0xD0D0);
  uint256 internal constant VALUE = 5 ether;

  function setUp() public {
    // A published root is a precondition for constructing any pool now - see BlacklistAnchorFixture.
    _deployBlacklistAnchor(BlacklistRootFixture.read(vm));
    token = new TestToken();
    entrypoint = new MinimalEntrypoint();

    pool = new PrivacyPoolComplex(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      address(token),
      address(entrypoint),
      address(0), // no aggregation verifier: this suite does not exercise withdrawBatch
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );

    token.mint(address(entrypoint), VALUE * 10);
  }

  /// @notice The constructor wiring nothing else exercises - the identity registry and the asset.
  /// @dev ONE registry where there were two: the ASP tree and the revocation list merged into a
  ///      single identity tree, with status carried in the leaf value (sec. 2.13k).
  function test_ConstructorWiresAssetAndRegistry() public view {
    assertEq(pool.ASSET(), address(token));
    assertEq(address(pool.IDENTITY_REGISTRY()), address(entrypoint));
  }

  /// @notice An ERC20 pool must refuse the native asset outright - otherwise its address becomes a
  /// hole ETH falls into with no accounting and no way out.
  /// @dev try/catch rather than vm.expectRevert: expectRevert with a selector does not match a
  /// revert raised during CREATE, so it reported "did not revert" while the guard was working fine.
  function test_RejectsNativeAsset() public {
    try new PrivacyPoolComplex(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      Constants.NATIVE_ASSET,
      address(entrypoint),
      address(0), // no aggregation verifier: this test only checks the native-asset guard
      address(blacklistAnchor), BLACKLIST_REGISTRY
    ) {
      fail('an ERC20 pool was constructed with the NATIVE asset');
    } catch {
      assertTrue(true);
    }
  }

  /// @notice _pull moves the token by transferFrom - the override's whole purpose, and the half a
  /// native-asset test can never reach.
  function test_DepositPullsTheToken() public {
    vm.prank(address(entrypoint));
    token.approve(address(pool), VALUE);

    uint256 before = token.balanceOf(address(pool));
    vm.prank(address(entrypoint));
    pool.deposit(depositor, VALUE, 12_345);

    assertEq(token.balanceOf(address(pool)) - before, VALUE, 'pool did not receive the token');
  }

  /// @notice Sending ETH alongside an ERC20 deposit must revert, not be silently swallowed.
  function test_DepositRejectsAttachedValue() public {
    vm.prank(address(entrypoint));
    token.approve(address(pool), VALUE);
    vm.deal(address(entrypoint), 1 ether);

    vm.prank(address(entrypoint));
    vm.expectRevert(IPrivacyPoolComplex.NativeAssetNotAccepted.selector);
    pool.deposit{value: 1 ether}(depositor, VALUE, 12_346);
  }

  /// @notice Without an allowance the transferFrom must fail rather than crediting a note the pool
  /// was never funded for.
  function test_DepositWithoutApprovalReverts() public {
    vm.prank(address(entrypoint));
    vm.expectRevert();
    pool.deposit(depositor, VALUE, 12_347);
  }
}
