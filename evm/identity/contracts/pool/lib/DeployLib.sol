// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title DeployLib
 * @dev A library for deterministic deployment of Privacy Pool contracts and related components
 * using CREATE2 via the CreateX contract.
 *
 * This library provides predefined salt values for deterministic deployments of:
 * - Entrypoint (as an UUPS proxy)
 * - Simple Privacy Pool (for native assets)
 * - Complex Privacy Pool (for ERC20 tokens)
 * - Ragequit verifier (Honk since 2026-07-27 - see sec. 2.5b)
 * - Withdrawal verifier (Honk)
 *
 * Each component can be deployed with a deterministic address based on these predefined salts.
 */
import {PrivacyPoolSimple} from '../implementations/PrivacyPoolSimple.sol';
import {PrivacyPoolComplex} from '../implementations/PrivacyPoolComplex.sol';

library DeployLib {
  /**
   * @dev Predefined salt values for each contract type
   * @notice These values ensure deterministic addresses across deployments
   */
  bytes11 internal constant ENTRYPOINT_IMPL_SALT = bytes11(keccak256('EntrypointImplementation_1'));
  bytes11 internal constant ENTRYPOINT_PROXY_SALT = bytes11(keccak256('EntrypointProxy_1'));
  bytes11 internal constant SIMPLE_POOL_SALT = bytes11(keccak256(abi.encodePacked('PrivacyPoolSimple_1')));
  bytes11 internal constant COMPLEX_POOL_SALT = bytes11(keccak256(abi.encodePacked('PrivacyPoolComplex_1')));
  bytes11 internal constant WITHDRAWAL_VERIFIER_SALT = bytes11(keccak256(abi.encodePacked('WithdrawalVerifier_1')));
  bytes11 internal constant RAGEQUIT_VERIFIER_SALT = bytes11(keccak256(abi.encodePacked('RagequitVerifier_1')));
  /// @dev The two registries PrivacyPool now holds directly (sec. 2.5a) - both NON-UPGRADEABLE, so
  ///      their addresses are fixed at deploy and worth pinning deterministically like the rest.
  /// The single identity tree - registration AND revocation status in one contract
  /// (sec. 2.13k). Replaces the separate ASP and revocation registry salts, which named contracts
  /// that no longer exist.
  bytes11 internal constant IDENTITY_REGISTRY_SALT = bytes11(keccak256(abi.encodePacked('IdentityRegistry_1')));
  bytes11 internal constant ESCROW_VERIFIER_SALT = bytes11(keccak256(abi.encodePacked('EscrowEnvelopeVerifier_1')));

  /**
   * @dev Creates a custom salt for deterministic deployments
   * @param _deployer Address of the deployer
   * @param _custom Custom salt value
   * @return _customSalt The generated salt
   */
  function salt(address _deployer, bytes11 _custom) internal pure returns (bytes32 _customSalt) {
    return bytes32(abi.encodePacked(_deployer, hex'00', _custom));
  }

  /**
   * @notice Deploy a native-asset pool deterministically.
   *
   * WHY THIS EXISTS. Until now this library held SALTS AND NOTHING ELSE: no function here
   * constructed a pool, there is no deployment script in the repo, and every one of the five
   * construction sites is a test. So the pools were only ever built by tests, and
   * `BATCH_VERIFIER` - which `withdrawBatch` reads - had no path by which a real deployment
   * could ever set it. Batching could not be switched on, whatever the contract said.
   *
   * @param _batchVerifier MAY be zero: a pool that does not offer batching is a legitimate
   *        deployment, and `withdrawBatch` then refuses explicitly with `BatchVerifierNotConfigured`
   *        rather than calling into an empty address. Passing it HERE rather than through a setter
   *        is what keeps it immutable - a settable verifier could be swapped for one that accepts
   *        anything, which is the whole security of the batch path.
   * @param _blacklistAnchor the RegistrySourceAnchor the pool PULLS its blacklist root from, and
   *        `_blacklistRegistryId` the registry within it. Both immutable, and passed here for the
   *        same reason `_batchVerifier` is: a settable source is a settable root wearing one more
   *        layer, and whoever can re-point it can choose the value it returns. Changing either means
   *        deploying a new pool - a decision with a diff, rather than a transaction.
   */
  function deploySimplePool(
    address _entrypoint,
    address _withdrawalVerifier,
    address _ragequitVerifier,
    address _identityRegistry,
    address _batchVerifier,
    address _blacklistAnchor,
    bytes32 _blacklistRegistryId
  ) internal returns (PrivacyPoolSimple _pool) {
    _pool = new PrivacyPoolSimple{salt: salt(msg.sender, SIMPLE_POOL_SALT)}(
      _entrypoint, _withdrawalVerifier, _ragequitVerifier, _identityRegistry, _batchVerifier,
      _blacklistAnchor, _blacklistRegistryId
    );
  }

  /**
   * @notice Deploy an ERC-20 pool deterministically.
   *
   * `PrivacyPoolComplex` has never been deployed by anything in this repo - its salt above was
   * declared and never used - so the ERC-20 path has shipped to nobody. That is why the ERC-20
   * first-spend problem (TODO.md task 22) is a guard placed before the failure rather than a repair.
   */
  function deployComplexPool(
    address _entrypoint,
    address _withdrawalVerifier,
    address _ragequitVerifier,
    address _asset,
    address _identityRegistry,
    address _batchVerifier,
    address _blacklistAnchor,
    bytes32 _blacklistRegistryId
  ) internal returns (PrivacyPoolComplex _pool) {
    _pool = new PrivacyPoolComplex{salt: salt(msg.sender, COMPLEX_POOL_SALT)}(
      _entrypoint, _withdrawalVerifier, _ragequitVerifier, _asset, _identityRegistry, _batchVerifier,
      _blacklistAnchor, _blacklistRegistryId
    );
  }
}
