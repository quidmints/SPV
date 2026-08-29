// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {PoseidonUnit2L} from '../../../src/identity/libraries/Poseidon.sol';
import {HolderStateKeeperMock} from '../mocks/holder/HolderStateKeeperMock.sol';
import {PoseidonSMTMock} from '../mocks/state/PoseidonSMTMock.sol';
import {PoseidonSMT} from '../../../src/identity/state/PoseidonSMT.sol';

/*
 * The state keeper and the bound documents that every escrow_envelope fixture is proven against.
 *
 * WHY A SHARED BASE. Since sec. 2.18 the escrow circuit proves SMT INCLUSION of the
 * document's leaf, so a proof only verifies against the exact registration tree it was built
 * against - same documents, same dgCommits, same binding TIMESTAMP, in the same order. Two suites
 * need that tree: RegistrationWitnessFixture.t.sol, which EMITS the witness, and
 * IdentityRegistry.t.sol, which consumes the resulting proofs. Building it twice would mean two
 * copies of a setup where any silent divergence - a different warp, a document bound in a different
 * order - produces an inclusion failure with no indication that the SETUP is what differs.
 *
 * THE DOCUMENTS COME FROM THE SAME JSON THE CIRCUIT WITNESS DID. `escrow_documents.json` is written
 * by tools/build-escrow-fixtures.js --documents, which takes each dgCommit from
 * register_identity_light_td1's own output. Nothing here invents a document value.
 *
 * (Before 2.18, `_plantDocument` bound a document with `dgCommit = 111` and the proof still
 * verified, because the contract only checked `holderOfDocumentHash`. The leaf VALUE now carries
 * the soundness, so a placeholder commitment no longer passes - which is the point.)
 */
abstract contract EscrowFixtureBase is Test {
  HolderStateKeeperMock internal sk;
  TestEvidenceRegistry internal evidence;

  bytes32 internal constant ICAO = 0x2c50ce3aa92bc3dd0351a89970b02630415547ea83c487befbc8b1795ea90c45;

  /// Height of registrationSmt everywhere it is deployed. MUST equal escrow_envelope's
  /// REGISTRATION_TREE_DEPTH - a mismatch produces an inclusion failure with no hint that the
  /// HEIGHT is the problem.
  uint256 internal constant REGISTRATION_TREE_DEPTH = 80;

  /// `_bindDocument` writes `block.timestamp` into the leaf VALUE, so the witness and the circuit's
  /// `document_timestamp` must agree EXACTLY. Pinned rather than left to forge-std's default of 1,
  /// which would work but reads as an accident and would break silently if that default changed.
  uint256 internal constant FIXTURE_TIMESTAMP = 1_700_000_000;

  function _setUpStateKeeper() internal {
    PoseidonSMTMock smt = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
    PoseidonSMTMock certs = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
    sk = HolderStateKeeperMock(_proxy(address(new HolderStateKeeperMock())));

    evidence = new TestEvidenceRegistry();
    smt.__PoseidonSMT_init(address(sk), address(evidence), REGISTRATION_TREE_DEPTH);
    certs.__PoseidonSMT_init(address(sk), address(evidence), REGISTRATION_TREE_DEPTH);
    sk.__StateKeeper_init(address(0xA11CE), address(smt), address(certs), ICAO);

    // Open the registration gate to this test so documents can be bound directly. The ICAO chain is
    // verified by the registration circuit, which is not what these suites exercise.
    string[] memory keys = new string[](1);
    keys[0] = 'test';
    address[] memory vals = new address[](1);
    vals[0] = address(this);
    sk.mockAddRegistrations(keys, vals);

    vm.warp(FIXTURE_TIMESTAMP);
  }

  function _proxy(address impl) internal returns (address) {
    return address(new UnsafeFixtureProxy(impl));
  }

  function _registrationSmt() internal view returns (PoseidonSMT) {
    return PoseidonSMT(address(sk.registrationSmt()));
  }

  /// Bind every document in the fixture, in file order, and return their SMT indices.
  function _bindDocumentsFromFixture() internal returns (bytes32[] memory indices_) {
    return _bindDocumentsInto(sk);
  }

  /*
   * Rebuild the EXACT registration tree the escrow proofs were built against, in ANY suite.
   *
   * TAKES THE KEEPER because WithdrawEndToEnd.t.sol builds its own alongside a whole pool, and
   * duplicating this loop there would mean two copies of a setup where any silent divergence -
   * a different order, a different timestamp - yields a different root and an inclusion failure
   * that points nowhere near the cause.
   */
  function _bindDocumentsInto(HolderStateKeeperMock keeper_)
    internal
    returns (bytes32[] memory indices_)
  {
    // THE TIMESTAMP IS PART OF THE LEAF. `_bindDocument` writes `block.timestamp` into
    // `Poseidon(dgCommit, seq, timestamp)`, so binding at any other time produces a different root
    // and every escrow proof stops verifying - with `UnknownRegistrationRoot`, which does not
    // mention time at all. Asserting it here is the difference between a one-line diagnosis and an
    // afternoon.
    require(
      block.timestamp == FIXTURE_TIMESTAMP,
      'EscrowFixtureBase: warp to FIXTURE_TIMESTAMP before binding, or the leaf values differ'
    );

    string memory raw = vm.readFile('test/identity/fixtures/escrow_documents.json');

    uint256 count_ = 0;
    while (vm.keyExistsJson(raw, string.concat('.documents[', vm.toString(count_), ']'))) {
      ++count_;
    }
    require(count_ > 1, 'need more than one document: a single leaf has an EMPTY inclusion path');

    indices_ = new bytes32[](count_);
    for (uint256 i = 0; i < count_; ++i) {
      string memory at = string.concat('.documents[', vm.toString(i), ']');
      bytes32 documentKey = vm.parseJsonBytes32(raw, string.concat(at, '.documentKey'));
      bytes32 holderRoot = vm.parseJsonBytes32(raw, string.concat(at, '.holderRoot'));

      keeper_.addDocument(
        documentKey,
        vm.parseJsonBytes32(raw, string.concat(at, '.documentHash')),
        holderRoot,
        keeper_.DOC_PASSPORT(),
        vm.parseJsonUint(raw, string.concat(at, '.dgCommit')),
        0
      );

      indices_[i] = bytes32(PoseidonUnit2L.poseidon([uint256(documentKey), uint256(holderRoot)]));
    }
  }
}

/// OZ 5.6.1 rejects empty proxy init data; these suites deploy-then-initialize, safe single-threaded.
/// Named distinctly from WithdrawEndToEnd.t.sol's own `UnsafeTestProxy`, which that suite declares
/// itself - two contracts of one name in a single import scope will not compile.
contract UnsafeFixtureProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

/// Every SMT root is anchored here; these suites read them back only where a test says so.
contract TestEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key_, bytes32 value_) external {
    statements[keccak256(abi.encodePacked(msg.sender, key_))] = value_;
  }
}
