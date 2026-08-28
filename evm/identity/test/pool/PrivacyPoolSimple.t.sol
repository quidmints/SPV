// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BlacklistAnchorFixture} from './helpers/BlacklistAnchorFixture.sol';
import {BlacklistRootFixture} from './helpers/BlacklistRootFixture.sol';
import {PoseidonT4} from 'poseidon/PoseidonT4.sol';

import {PrivacyPoolSimple} from '../../contracts/pool/implementations/PrivacyPoolSimple.sol';
import {IPrivacyPool, IPrivacyPoolSimple} from '../../contracts/pool/interfaces/IPrivacyPool.sol';
import {IState} from '../../contracts/pool/interfaces/IState.sol';
import {ProofLib} from '../../contracts/pool/lib/ProofLib.sol';
import {Constants} from '../../contracts/pool/lib/Constants.sol';
import {NoirVerifierMock} from '../../contracts/mock/verifiers/NoirVerifierMock.sol';

/// Minimal stand-in for BOTH the Entrypoint and the ASP registry. Since the sec. 2.5a split the
/// pool asks the REGISTRY about roots, not the Entrypoint; this mock plays both parts so these
/// tests stay focused on pool mechanics. (the
/// ASP-gating check in `validWithdrawal`) - deposit/withdraw/ragequit are otherwise pool-internal,
/// so this settable double is enough to exercise the pool's OWN logic in isolation, same pattern
/// as HolderStateKeeper.t.sol standing in a plain EOA for "the registration contract".
///
/// Note the shape change from the old `latestActiveRoot()` single-root getter: the real Entrypoint
/// now accepts ANY root its append-only ASP tree has ever produced, so the double is a SET, not a
/// single value. `Entrypoint`'s own append-only behaviour is tested directly in EntrypointAsp.t.sol.
contract MockEntrypoint {
  mapping(uint256 => bool) public known;

  function setActiveRoot(uint256 root_) external {
    known[root_] = true;
  }

  /// Stands in for the IdentityRegistry: the pool asks isValidRoot before accepting a proof.
  ///
  /// THIS MUST HONOUR `known`, not return true. It previously DID return true unconditionally,
  /// which was fine when it only stood in for the revocation registry and the ASP root was checked
  /// separately via isKnownAspRoot. Under the single identity tree this IS the only identity gate,
  /// so an unconditional true would make test_withdraw_revertsOnInvalidIdentityRoot pass while
  /// asserting nothing at all.
  function isValidRoot(bytes32 root_) external view returns (bool) {
    if (root_ == bytes32(0)) return false;
    return known[uint256(root_)];
  }
}

/// PP core: deposit / withdraw / ragequit - previously zero test coverage on this fork.
contract PrivacyPoolSimpleTest is Test, BlacklistAnchorFixture {
  MockEntrypoint internal entrypoint;
  // BOTH paths are Noir/Honk-proved - withdrawal via ProofLib.WithdrawProof, ragequit via
  // RagequitProof - which is why ONE mock type serves both. State.sol declares each as
  // `INoirVerifier`; no Groth16 remains in this pool.
  NoirVerifierMock internal withdrawalVerifier;
  NoirVerifierMock internal ragequitVerifier;
  PrivacyPoolSimple internal pool;

  address internal depositor = address(0xD0D0);
  address internal processooor = address(0xF00D);

  uint256 internal constant FIELD = Constants.SNARK_SCALAR_FIELD;

  function setUp() public {
    entrypoint = new MockEntrypoint();
    withdrawalVerifier = new NoirVerifierMock();
    ragequitVerifier = new NoirVerifierMock();
    _deployBlacklistAnchor(BlacklistRootFixture.read(vm));
    pool = new PrivacyPoolSimple(
      address(entrypoint), address(withdrawalVerifier), address(ragequitVerifier),
      address(entrypoint),
      address(0), // no aggregation verifier: this suite does not exercise withdrawBatch
      address(blacklistAnchor), BLACKLIST_REGISTRY
    );


    vm.deal(address(entrypoint), 0); // deposits are relayed as msg.value from the caller, not the entrypoint's own balance
    vm.deal(depositor, 0);
    vm.deal(processooor, 0);
  }

  // ── helpers ─────────────────────────────────────────────────────────────────────────────

  function _label(uint256 nonce_) internal view returns (uint256) {
    return uint256(keccak256(abi.encodePacked(pool.SCOPE(), nonce_))) % FIELD;
  }

  function _deposit(uint256 value_, uint256 precommitment_) internal returns (uint256 commitment_, uint256 label_) {
    label_ = _label(pool.nonce() + 1);
    // {value: value_} is drawn from the pranked caller's balance (entrypoint), not this test
    // contract's - deal the address that actually sends it.
    vm.deal(address(entrypoint), value_);
    vm.prank(address(entrypoint));
    commitment_ = pool.deposit{value: value_}(depositor, value_, precommitment_);
  }

  function _emptyWithdrawProof() internal pure returns (ProofLib.WithdrawProof memory p) {
    p.pubSignals = [uint256(0), 0, 0, 0, 0, 0, 0, 0]; // 8th = taint root (2.18gz-unify)
  }

  /// @dev Honk since the sec. 2.5b port - `proof` is bytes, not pA/pB/pC.
  function _emptyRagequitProof() internal pure returns (ProofLib.RagequitProof memory p) {
    p.pubSignals = [uint256(0), 0, 0, 0];
  }

  // ── deposit ─────────────────────────────────────────────────────────────────────────────

  function test_deposit_succeeds() public {
    (uint256 commitment, uint256 label) = _deposit(1 ether, 123);

    assertEq(pool.currentTreeSize(), 1);
    assertEq(pool.depositors(label), depositor);
    assertEq(commitment, PoseidonT4.hash([uint256(1 ether), label, uint256(123)]));
    assertTrue(pool.currentRoot() != 0);
  }

  function test_deposit_revertsOnNotEntrypoint() public {
    vm.deal(address(this), 1 ether);
    vm.expectRevert(IState.OnlyEntrypoint.selector);
    pool.deposit{value: 1 ether}(depositor, 1 ether, 123);
  }

  function test_deposit_revertsOnValueMismatch() public {
    // Deal the actual msg.value being sent (0.5 ether) so the CALL's own value transfer
    // succeeds and execution reaches the InsufficientValue check inside deposit() itself,
    // rather than failing at the EVM value-transfer level first.
    vm.deal(address(entrypoint), 0.5 ether);
    vm.prank(address(entrypoint));
    vm.expectRevert(IPrivacyPoolSimple.InsufficientValue.selector);
    pool.deposit{value: 0.5 ether}(depositor, 1 ether, 123);
  }

  function test_deposit_revertsOnValueTooLarge() public {
    uint256 tooLarge = type(uint128).max;
    // {value: tooLarge} is drawn from the pranked caller (entrypoint), not this test contract.
    vm.deal(address(entrypoint), tooLarge);
    vm.prank(address(entrypoint));
    vm.expectRevert(IPrivacyPool.InvalidDepositValue.selector);
    pool.deposit{value: tooLarge}(depositor, tooLarge, 123);
  }

  function test_deposit_revertsOnPrecommitmentOutOfField() public {
    // {value: 1 ether} is drawn from the pranked caller (entrypoint), not this test contract.
    vm.deal(address(entrypoint), 1 ether);
    vm.prank(address(entrypoint));
    vm.expectRevert(IPrivacyPool.InvalidPrecommitmentHash.selector);
    pool.deposit{value: 1 ether}(depositor, 1 ether, FIELD); // == FIELD is already out of range
  }

  // ── withdraw ────────────────────────────────────────────────────────────────────────────

  function _validWithdrawProof(uint256 withdrawnValue_)
    internal
    returns (IPrivacyPool.Withdrawal memory withdrawal_, ProofLib.WithdrawProof memory proof_)
  {
    (, uint256 label) = _deposit(1 ether, 123);
    uint256 identityRoot = 999;
    entrypoint.setActiveRoot(identityRoot);

    withdrawal_ = IPrivacyPool.Withdrawal({processooor: processooor, data: abi.encode(label)});
    uint256 context = uint256(keccak256(abi.encode(withdrawal_, pool.SCOPE()))) % FIELD;

    proof_ = _emptyWithdrawProof();
    proof_.pubSignals[0] = 777; // newCommitmentHash (arbitrary - NoirVerifierMock does not check)
    proof_.pubSignals[1] = 555; // existingNullifierHash
    proof_.pubSignals[2] = withdrawnValue_;
    proof_.pubSignals[3] = pool.currentRoot();
    proof_.pubSignals[4] = pool.currentTreeDepth();
    proof_.pubSignals[5] = identityRoot;
    proof_.pubSignals[6] = context;
  }

  function test_withdraw_succeeds() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);

    uint256 balanceBefore = processooor.balance;
    vm.prank(processooor);
    pool.withdraw(w, p);

    assertEq(processooor.balance, balanceBefore + 0.4 ether);
    assertTrue(pool.nullifierHashes(p.pubSignals[1]));
    assertEq(pool.currentTreeSize(), 2); // original deposit + new change commitment
  }

  function test_withdraw_revertsOnWrongProcessooor() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);

    vm.expectRevert(IPrivacyPool.InvalidProcessooor.selector);
    pool.withdraw(w, p); // called by the test contract, not `processooor`
  }

  function test_withdraw_revertsOnContextMismatch() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);
    p.pubSignals[6] = p.pubSignals[6] + 1; // corrupt context - slot 6 since asp_tree_depth went

    vm.prank(processooor);
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    pool.withdraw(w, p);
  }

  function test_withdraw_revertsOnUnknownStateRoot() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);
    p.pubSignals[3] = 0xDEAD; // a root never actually inserted

    vm.prank(processooor);
    vm.expectRevert(IPrivacyPool.UnknownStateRoot.selector);
    pool.withdraw(w, p);
  }

  /// The identity gate: slot 5 is now `identityRoot`, checked against IdentityRegistry.isValidRoot
  /// rather than the old ASP root equality. One registry where there were two (sec. 2.13k).
  function test_withdraw_revertsOnInvalidIdentityRoot() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);
    p.pubSignals[5] = p.pubSignals[5] + 1; // no longer a root the registry ever had

    vm.prank(processooor);
    vm.expectRevert(IPrivacyPool.InvalidIdentityRoot.selector);
    pool.withdraw(w, p);
  }

  function test_withdraw_revertsOnInvalidTreeDepth() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);
    p.pubSignals[4] = pool.MAX_TREE_DEPTH() + 1;

    vm.prank(processooor);
    vm.expectRevert(IPrivacyPool.InvalidTreeDepth.selector);
    pool.withdraw(w, p);
  }

  function test_withdraw_revertsOnInvalidProof() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);

    withdrawalVerifier.setShouldVerify(false);
    vm.prank(processooor);
    vm.expectRevert(IPrivacyPool.InvalidProof.selector);
    pool.withdraw(w, p);
  }

  function test_withdraw_revertsOnDoubleSpend() public {
    (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) = _validWithdrawProof(0.4 ether);

    vm.prank(processooor);
    pool.withdraw(w, p);

    // Same nullifier, re-submitted (as if replaying the exact same proof) - a fresh proof would
    // naturally get a fresh context (the withdrawal struct or scope would differ), so this
    // specifically checks the nullifier-spend guard itself, not context-replay.
    entrypoint.setActiveRoot(p.pubSignals[5]); // still active, isolate the nullifier check
    vm.prank(processooor);
    vm.expectRevert(IState.NullifierAlreadySpent.selector);
    pool.withdraw(w, p);
  }

  // ── ragequit ────────────────────────────────────────────────────────────────────────────

  function test_ragequit_succeeds() public {
    uint256 value = 1 ether;
    uint256 precommitment = 123;
    (uint256 commitment, uint256 label) = _deposit(value, precommitment);

    ProofLib.RagequitProof memory p = _emptyRagequitProof();
    p.pubSignals[0] = commitment;
    p.pubSignals[1] = 555; // nullifierHash - arbitrary, NoirVerifierMock does not check
    p.pubSignals[2] = value;
    p.pubSignals[3] = label;

    uint256 balanceBefore = depositor.balance;
    vm.prank(depositor);
    pool.ragequit(p);

    assertEq(depositor.balance, balanceBefore + value);
    assertTrue(pool.nullifierHashes(p.pubSignals[1]));
  }

  function test_ragequit_revertsOnNotOriginalDepositor() public {
    uint256 value = 1 ether;
    (uint256 commitment, uint256 label) = _deposit(value, 123);

    ProofLib.RagequitProof memory p = _emptyRagequitProof();
    p.pubSignals[0] = commitment;
    p.pubSignals[2] = value;
    p.pubSignals[3] = label;

    vm.prank(processooor); // not `depositor`
    vm.expectRevert(IPrivacyPool.OnlyOriginalDepositor.selector);
    pool.ragequit(p);
  }

  function test_ragequit_revertsOnUnknownCommitment() public {
    (, uint256 label) = _deposit(1 ether, 123);

    ProofLib.RagequitProof memory p = _emptyRagequitProof();
    p.pubSignals[0] = 0xDEAD; // never actually inserted
    p.pubSignals[2] = 1 ether;
    p.pubSignals[3] = label;

    vm.prank(depositor);
    vm.expectRevert(IPrivacyPool.InvalidCommitment.selector);
    pool.ragequit(p);
  }

  function test_ragequit_revertsOnInvalidProof() public {
    NoirVerifierMock rejecting = new NoirVerifierMock();
    rejecting.setShouldVerify(false);
    PrivacyPoolSimple rejectingPool =
      new PrivacyPoolSimple(
        address(entrypoint), address(withdrawalVerifier), address(rejecting),
        address(entrypoint),
        address(0), // no aggregation verifier: this suite does not exercise withdrawBatch
        address(blacklistAnchor), BLACKLIST_REGISTRY
      );

    uint256 value = 1 ether;
    // {value: value} is drawn from the pranked caller (entrypoint), not this test contract.
    vm.deal(address(entrypoint), value);
    vm.prank(address(entrypoint));
    uint256 commitment = rejectingPool.deposit{value: value}(depositor, value, 123);
    // rejectingPool is a SEPARATE pool instance with its own SCOPE (derived from its own
    // address) - must NOT reuse the shared _label() helper, which hardcodes `pool.SCOPE()`.
    uint256 label = uint256(keccak256(abi.encodePacked(rejectingPool.SCOPE(), uint256(1)))) % FIELD;

    ProofLib.RagequitProof memory p = _emptyRagequitProof();
    p.pubSignals[0] = commitment;
    p.pubSignals[2] = value;
    p.pubSignals[3] = label;

    vm.prank(depositor);
    vm.expectRevert(IPrivacyPool.InvalidProof.selector);
    rejectingPool.ragequit(p);
  }

  function test_ragequit_revertsOnDoubleSpend() public {
    uint256 value = 1 ether;
    (uint256 commitment, uint256 label) = _deposit(value, 123);

    ProofLib.RagequitProof memory p = _emptyRagequitProof();
    p.pubSignals[0] = commitment;
    p.pubSignals[1] = 555;
    p.pubSignals[2] = value;
    p.pubSignals[3] = label;

    vm.prank(depositor);
    pool.ragequit(p);

    vm.prank(depositor);
    vm.expectRevert(IState.NullifierAlreadySpent.selector);
    pool.ragequit(p);
  }
}
