// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/*

Made with ♥ for 0xBow by

░██╗░░░░░░░██╗░█████╗░███╗░░██╗██████╗░███████╗██████╗░██╗░░░░░░█████╗░███╗░░██╗██████╗░
░██║░░██╗░░██║██╔══██╗████╗░██║██╔══██╗██╔════╝██╔══██╗██║░░░░░██╔══██╗████╗░██║██╔══██╗
░╚██╗████╗██╔╝██║░░██║██╔██╗██║██║░░██║█████╗░░██████╔╝██║░░░░░███████║██╔██╗██║██║░░██║
░░████╔═████║░██║░░██║██║╚████║██║░░██║██╔══╝░░██╔══██╗██║░░░░░██╔══██║██║╚████║██║░░██║
░░╚██╔╝░╚██╔╝░╚█████╔╝██║░╚███║██████╔╝███████╗██║░░██║███████╗██║░░██║██║░╚███║██████╔╝
░░░╚═╝░░░╚═╝░░░╚════╝░╚═╝░░╚══╝╚═════╝░╚══════╝╚═╝░░╚═╝╚══════╝╚═╝░░╚═╝╚═╝░░╚══╝╚═════╝░

https://defi.sucks/

*/

import {AccessControlUpgradeable} from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
// OZ 5.6.1 dropped ReentrancyGuardUpgradeable: the transient-storage (EIP-1153) variant carries no
// persistent state, so there's no upgradeable-vs-plain distinction left to make - use the plain one.
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {Constants} from './lib/Constants.sol';
import {ProofLib} from './lib/ProofLib.sol';

import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

/**
 * @title Entrypoint
 * @notice Serves as the main entrypoint for a series of ASP-operated Privacy Pools
 */
contract Entrypoint is
  AccessControlUpgradeable,
  UUPSUpgradeable,
  ReentrancyGuardTransient,
  IEntrypoint
{
  using SafeERC20 for IERC20;
  using ProofLib for ProofLib.WithdrawProof;

  /// @dev 0xb19546dff01e856fb3f010c267a7b1c60363cf8a4664e21cc89c26224620214e
  bytes32 internal constant _OWNER_ROLE = keccak256('OWNER_ROLE');

  /// @inheritdoc IEntrypoint
  mapping(uint256 _scope => IPrivacyPool _pool) public scopeToPool;

  /// @inheritdoc IEntrypoint
  mapping(IERC20 _asset => AssetConfig _config) public assetConfig;

  /*
   * THE ASP TREE NO LONGER LIVES HERE. It moved out (sec. 2.5a) and has since been superseded
   * entirely by contracts/registry/IdentityRegistry.sol - the single identity tree,
   * which is NON-UPGRADEABLE and unowned - see sec. 2.5a. Keeping it in this contract made
   * the append-only claim untrue in practice: `_authorizeUpgrade` is onlyRole(_OWNER_ROLE), so the
   * owner could upgrade this implementation and rewrite the membership set at will. PrivacyPool now
   * holds a direct reference to the registry, so this contract is out of the ASP trust path
   * entirely and remains upgradeable only for asset config and routing.
   */

  /// @notice Every ASP root this contract has ever computed, mapped to the timestamp it was
  ///         created at. Historical roots stay valid forever: the tree is append-only, so an old
  ///         root's membership set is a strict subset of the current one and honouring it grants
  ///         nothing the current root would not. This is the same reasoning that makes `State`'s
  ///         64-root window safe for the commitment tree. `0` means "never seen".

  /// @notice Guards against inserting the same identity twice, which would waste gas and put a
  ///         duplicate leaf in the tree for no benefit.

  /// @inheritdoc IEntrypoint
  mapping(uint256 _precommitment => bool _used) public usedPrecommitments;

  /// @inheritdoc IEntrypoint
  IEvidenceRegistry public EVIDENCE_REGISTRY;

  /*///////////////////////////////////////////////////////////////
                          INITIALIZATION
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Disables initializers. Using UUPS upgradeability pattern
   */
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IEntrypoint
  function initialize(address _owner, address _evidenceRegistry) external initializer {
    // Sanity check initial addresses
    if (_owner == address(0)) revert ZeroAddress();
    if (_evidenceRegistry == address(0)) revert ZeroAddress();

    // ERC-7812 evidence registry: shared, tamper-evident anchor for every ASP root (the same
    // registry rarime anchors identity state roots in — one truth registry for both).
    EVIDENCE_REGISTRY = IEvidenceRegistry(_evidenceRegistry);

    // Initialize upgradeable contracts
    // UUPSUpgradeable has no storage/init step in OZ 5.6.1 (it's a thin, stateless wrapper);
    // ReentrancyGuardTransient is likewise stateless (EIP-1153 transient storage).
    __AccessControl_init();
    // Initialize roles
    _setRoleAdmin(DEFAULT_ADMIN_ROLE, _OWNER_ROLE);
    _setRoleAdmin(_OWNER_ROLE, _OWNER_ROLE); // Owner can manage owner role

    _grantRole(_OWNER_ROLE, _owner);
  }

  /*///////////////////////////////////////////////////////////////
                      ASSOCIATION SET METHODS
  //////////////////////////////////////////////////////////////*/

  /*
   * THERE IS NO ADMISSION PATH IN THIS CONTRACT, AND UNTIL 2026-08-03 THE COMMENTS SAID OTHERWISE.
   *
   * This block described `admitIdentityWithAuthorization` / `_admitIdentity` - an EIP-712 admission
   * signed by an `ASP_POSTMAN`, with replay protection in `aspAdmitted[_holderRoot]` and an
   * append-only `_aspTree`. **None of those exist.** No function, no mapping, no tree; the role was
   * declared, given a role admin and granted in `initialize`, and then gated nothing. Removed
   * together, because a role that guards no function is not a safety margin - it is an invitation to
   * assume a check that is not there, and `frontend/.../pp/stateTree.ts` had already recorded the
   * assumption as fact.
   *
   * WHAT IS ACTUALLY ENFORCED, so this is not read as a gap where none exists: exclusion lives in
   * `IdentityRegistry.revoke`, which writes a non-zero predicate over a commitment so every
   * clean-status inclusion proof for it becomes impossible. That is the PP-native mechanism -
   * exclusion, not exposure - and it is gated by `CONTROLLER`, a single address.
   *
   * WHAT REPLACES THE REMOVED ROLE when an admission path is built: not another role. Admission
   * should be a PROOF against the CRE-anchored sanctions root, whose leaves `_computeRoot` already
   * forces to be strictly ascending, so non-membership is provable by bracketing two adjacent
   * leaves. See TODO sec. 2.18cq for the binding that still blocks it.
   */


  /*///////////////////////////////////////////////////////////////
                          DEPOSIT METHODS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function deposit(uint256 _precommitment) external payable nonReentrant returns (uint256 _commitment) {
    // Handle deposit as native asset
    _commitment = _handleDeposit(IERC20(Constants.NATIVE_ASSET), msg.value, _precommitment);
  }

  /// @inheritdoc IEntrypoint
  function deposit(
    IERC20 _asset,
    uint256 _value,
    uint256 _precommitment
  ) external nonReentrant returns (uint256 _commitment) {
    // Pull funds from user
    _asset.safeTransferFrom(msg.sender, address(this), _value);
    // Handle deposit as ERC20
    _commitment = _handleDeposit(_asset, _value, _precommitment);
  }

  /*///////////////////////////////////////////////////////////////
                               RELAY
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function relay(
    IPrivacyPool.Withdrawal calldata _withdrawal,
    ProofLib.WithdrawProof calldata _proof,
    uint256 _scope
  ) external nonReentrant {
    // Check withdrawn amount is non-zero
    if (_proof.withdrawnValue() == 0) revert InvalidWithdrawalAmount();
    // Check allowed processooor is this Entrypoint
    if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();

    // Fetch pool by scope
    IPrivacyPool _pool = scopeToPool[_scope];
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Store pool asset
    IERC20 _asset = IERC20(_pool.ASSET());
    uint256 _balanceBefore = _assetBalance(_asset);

    // Process withdrawal
    _pool.withdraw(_withdrawal, _proof);

    // Decode relay data
    RelayData memory _data = abi.decode(_withdrawal.data, (RelayData));

    if (_data.relayFeeBPS > assetConfig[_asset].maxRelayFeeBPS) revert RelayFeeGreaterThanMax();

    uint256 _withdrawnAmount = _proof.withdrawnValue();

    // Deduct fees
    uint256 _amountAfterFees = _deductFee(_withdrawnAmount, _data.relayFeeBPS);

    uint256 _feeAmount = _withdrawnAmount - _amountAfterFees;

    // Transfer withdrawn funds to recipient
    _transfer(_asset, _data.recipient, _amountAfterFees);
    // Transfer fees to fee recipient
    _transfer(_asset, _data.feeRecipient, _feeAmount);

    // Check pool balance has not been reduced
    uint256 _balanceAfter = _assetBalance(_asset);
    if (_balanceBefore > _balanceAfter) revert InvalidPoolState();

    emit WithdrawalRelayed(msg.sender, _data.recipient, _asset, _withdrawnAmount, _feeAmount);
  }

  /*///////////////////////////////////////////////////////////////
                          POOL MANAGEMENT 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function registerPool(
    IERC20 _asset,
    IPrivacyPool _pool,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) external onlyRole(_OWNER_ROLE) {
    // Sanity check addresses
    if (address(_asset) == address(0)) revert ZeroAddress();
    if (address(_pool) == address(0)) revert ZeroAddress();

    // Fetch pool configuration
    AssetConfig storage _config = assetConfig[_asset];
    if (address(_config.pool) != address(0)) revert AssetPoolAlreadyRegistered();

    if (_pool.dead()) revert PoolIsDead();
    if (address(_pool.ENTRYPOINT()) != address(this)) revert InvalidEntrypointForPool();

    // Fetch pool scope and validate asset
    uint256 _scope = _pool.SCOPE();
    if (address(scopeToPool[_scope]) != address(0)) revert ScopePoolAlreadyRegistered();
    if (_asset != IERC20(_pool.ASSET())) revert AssetMismatch();

    // Store pool configuration
    scopeToPool[_scope] = _pool;
    _config.pool = _pool;

    // Update pool configuration with validation
    _setPoolConfiguration(_config, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);

    // If asset is an ERC20, approve pool to spend
    if (address(_asset) != Constants.NATIVE_ASSET) _asset.forceApprove(address(_pool), type(uint256).max);

    emit PoolRegistered(_pool, _asset, _scope);
  }

  /// @inheritdoc IEntrypoint
  function removePool(IERC20 _asset) external onlyRole(_OWNER_ROLE) {
    // Fetch pool by asset
    IPrivacyPool _pool = assetConfig[_asset].pool;
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Fetch pool scope
    uint256 _scope = _pool.SCOPE();

    // If asset is an ERC20, revoke pool allowance
    if (address(_asset) != Constants.NATIVE_ASSET) _asset.forceApprove(address(_pool), 0);

    // Remove pool configuration
    delete scopeToPool[_scope];
    delete assetConfig[_asset];

    emit PoolRemoved(_pool, _asset, _scope);
  }

  /// @inheritdoc IEntrypoint
  function updatePoolConfiguration(
    IERC20 _asset,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) external onlyRole(_OWNER_ROLE) {
    // Fetch pool configuration
    AssetConfig storage _config = assetConfig[_asset];
    if (address(_config.pool) == address(0)) revert PoolNotFound();

    // Update pool configuration with validation
    _setPoolConfiguration(_config, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);

    emit PoolConfigurationUpdated(_config.pool, _asset, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);
  }

  /// @inheritdoc IEntrypoint
  function windDownPool(IPrivacyPool _pool) external onlyRole(_OWNER_ROLE) {
    // Call `windDown` on pool
    _pool.windDown();

    emit PoolWindDown(_pool);
  }

  /// @inheritdoc IEntrypoint
  function withdrawFees(IERC20 _asset, address _recipient) external nonReentrant onlyRole(_OWNER_ROLE) {
    // Fetch current asset balance
    uint256 _balance = _assetBalance(_asset);

    // Transfer funds
    _transfer(_asset, _recipient, _balance);

    emit FeesWithdrawn(_asset, _recipient, _balance);
  }

  /*
   * THERE ARE NO VIEW METHODS HERE, AND FOUR ORPHANED DOC BLOCKS SAID OTHERWISE UNTIL 2026-08-07.
   *
   * They documented `latestActiveRoot`, an ASP tree size accessor, an ASP tree depth accessor and an
   * ASP statement-key helper - none of which exist; the next function after them was `receive()`.
   * Deleted rather than updated, because the reasoning inside them was ACTIVELY WRONG and pointed at
   * the money path:
   *
   *   "any root this contract has ever computed is accepted, forever - safe ONLY because the tree is
   *    append-only"
   *
   * The tree that now gates withdrawals is NOT append-only. `IdentityRegistry.revoke` calls
   * `_tree.update(commitment_, predicate_)`, so a pre-revocation root still shows a revoked identity
   * as CLEAN. Accepting old roots forever would let a revoked identity withdraw. That is why
   * `IdentityRegistry.isValidRoot` bounds acceptance by `MAX_ROOT_AGE` (see its sec. 3 header), and
   * why anyone porting the deleted reasoning to the identity path would remove the guard that stops
   * exactly this. See TODO sec. 2.18fb.
   *
   * One block also claimed a withdrawal proof "must carry" an `asp_tree_depth` public signal.
   * `ProofLib.WithdrawProof` has SEVEN slots and no such signal; the ASP tree depth was upstream's,
   * needed because its ASP tree was a variable-depth LeanIMT. Ours is a fixed-depth SMT (2.18fc).
   */

  /*///////////////////////////////////////////////////////////////
                            RECEIVE
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Needed to receive native asset from a pool when withdrawing
   * @dev Only accepts native asset from the local native asset pool
   */
  receive() external payable {
    address _nativePool = address(assetConfig[IERC20(Constants.NATIVE_ASSET)].pool);
    if (msg.sender != _nativePool) revert NativeAssetNotAccepted();
  }

  /*///////////////////////////////////////////////////////////////
                        INTERNAL METHODS 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc UUPSUpgradeable
  function _authorizeUpgrade(address) internal override onlyRole(_OWNER_ROLE) {}

  /**
   * @notice Handle deposit logic for both native asset and ERC20 deposits
   * @param _asset The asset being deposited
   * @param _value The amount being deposited
   * @param _precommitment The precommitment for the deposit
   * @return _commitment The deposit commitment hash
   */
  function _handleDeposit(IERC20 _asset, uint256 _value, uint256 _precommitment) internal returns (uint256 _commitment) {
    // Fetch pool by asset
    AssetConfig memory _config = assetConfig[_asset];
    IPrivacyPool _pool = _config.pool;
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Check if the `_precommitment` has already been used
    if (usedPrecommitments[_precommitment]) revert PrecommitmentAlreadyUsed();
    // Mark it as used
    usedPrecommitments[_precommitment] = true;

    // Check minimum deposit amount
    if (_value < _config.minimumDepositAmount) revert MinimumDepositAmount();

    // Deduct vetting fees
    uint256 _amountAfterFees = _deductFee(_value, _config.vettingFeeBPS);

    // Deposit commitment into pool (forwarding native asset if applicable)
    uint256 _nativeAssetValue = address(_asset) == Constants.NATIVE_ASSET ? _amountAfterFees : 0;
    _commitment = _pool.deposit{value: _nativeAssetValue}(msg.sender, _amountAfterFees, _precommitment);

    emit Deposited(msg.sender, _pool, _commitment, _amountAfterFees);
  }

  /**
   * @notice Transfer out an asset to a recipient
   * @param _asset The asset to send
   * @param _recipient The recipient address
   * @param _amount The amount to send
   */
  function _transfer(IERC20 _asset, address _recipient, uint256 _amount) internal {
    if (_recipient == address(0)) revert ZeroAddress();

    if (_asset == IERC20(Constants.NATIVE_ASSET)) {
      (bool _success,) = _recipient.call{value: _amount}('');
      if (!_success) revert NativeAssetTransferFailed();
    } else {
      _asset.safeTransfer(_recipient, _amount);
    }
  }

  /**
   * @notice Fetch asset balance for the Entrypoint
   * @param _asset The asset address
   * @return _balance The asset balance
   */
  function _assetBalance(IERC20 _asset) internal view returns (uint256 _balance) {
    if (_asset == IERC20(Constants.NATIVE_ASSET)) {
      _balance = address(this).balance;
    } else {
      _balance = _asset.balanceOf(address(this));
    }
  }

  /**
   * @notice Deduct fees from an amount
   * @param _amount The amount before fees
   * @param _feeBPS The fee in basis points
   * @return _afterFees The amount after fees are deducted
   */
  function _deductFee(uint256 _amount, uint256 _feeBPS) internal pure returns (uint256 _afterFees) {
    _afterFees = _amount - ((_amount * _feeBPS) / 10_000);
  }

  /**
   * @notice Sets pool configuration parameters with validation
   * @dev Validates and sets minimum deposit amount and vetting fee
   * @param _config The pool configuration to update
   * @param _minimumDepositAmount The new minimum deposit amount
   * @param _vettingFeeBPS The new vetting fee in basis points
   * @param _maxRelayFeeBPS The maximum relay fee in basis points
   */
  function _setPoolConfiguration(
    AssetConfig storage _config,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) internal {
    // Check fee is less than 100%
    if (_vettingFeeBPS >= 10_000 || _maxRelayFeeBPS >= 10_000) revert InvalidFeeBPS();

    _config.minimumDepositAmount = _minimumDepositAmount;
    _config.vettingFeeBPS = _vettingFeeBPS;
    _config.maxRelayFeeBPS = _maxRelayFeeBPS;
  }
}
