// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from 'contracts/libraries/Poseidon.sol';

/**
 * Emit the blacklist root and the non-inclusion witnesses the withdrawal fixtures prove against.
 *
 * WHY THIS IS A CONTRACT AND NOT A SCRIPT, for the same reason `test_EmitIdentityWitnessFixture`
 * is: a witness built in JS would only prove that two of our own implementations agree, and would
 * need a second sparse-trie kept byte-compatible with solarity's forever. The circuit already
 * verifies inclusion against a solarity tree on the identity path, so the conventions are known to
 * match - reuse that rather than re-establish it.
 *
 * ⚠️ THE TREE IS DELIBERATELY NON-EMPTY, AND THAT IS THE ENTIRE POINT OF THE FILE. Every batch
 * witness in the tree today carries `blacklist_root = 0` with the all-zero `is_old0 = true` witness,
 * which verifies against an EMPTY tree FOR ANY KEY. So the exclusion branch has never once been
 * exercised with a real sibling path: a bug anywhere in it - wrong hasher, wrong depth, wrong
 * key derivation - would pass every test we have. Populated entries force real siblings.
 *
 * The entries are arbitrary non-keys: they must not collide with any label or document the fixtures
 * use, or the exclusion proof would correctly FAIL and read as a broken circuit.
 */
contract BlacklistWitnessFixtureTest is Test {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  SparseMerkleTree.Bytes32SMT private _tree;

  /// Matches IDENTITY_TREE_DEPTH in the circuit. A shorter tree yields shorter sibling arrays and
  /// the prover rejects the witness on length, which reads as a malformed fixture.
  uint32 internal constant DEPTH = 32;

  function _h2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a), uint256(b)]));
  }

  function _h3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a), uint256(b), uint256(c)]));
  }

  function setUp() public {
    _tree.initialize(DEPTH);
    _tree.setHashers(_h2, _h3);
  }

  function test_EmitBlacklistWitnessFixture() public {
    // The listed keys. Values are 1 - the circuit only asks whether the key is ABSENT, so the value
    // carries no meaning; a non-zero one makes an accidental read of it visible.
    // Paths are overridable so the SAME tree can serve more than one generator: the 32-member
    // batch and the standalone withdrawal fixtures need exclusion proofs for different keys, and
    // they must be proven against ONE root or they could never settle in the same pool.
    uint256[] memory listed = abi.decode(
      vm.parseJson(vm.readFile(vm.envOr('BLACKLIST_LISTED', string('test/identity/fixtures/blacklist_listed.json')))),
      (uint256[])
    );
    for (uint256 i = 0; i < listed.length; i++) _tree.add(bytes32(listed[i]), bytes32(uint256(1)));

    uint256[] memory queries = abi.decode(
      vm.parseJson(vm.readFile(vm.envOr('BLACKLIST_QUERIES', string('test/identity/fixtures/blacklist_queries.json')))),
      (uint256[])
    );

    bytes32 root = _tree.getRoot();
    require(root != bytes32(0), 'a populated tree hashed to the empty root');

    bytes32[] memory oldKey = new bytes32[](queries.length);
    bytes32[] memory oldValue = new bytes32[](queries.length);
    bytes32[] memory isOld0 = new bytes32[](queries.length);
    bytes32[] memory siblings = new bytes32[](queries.length * DEPTH);

    for (uint256 i = 0; i < queries.length; i++) {
      SparseMerkleTree.Proof memory p = _tree.getProof(bytes32(queries[i]));

      // A query that EXISTS cannot yield an exclusion proof. It means a fixture label collided with
      // a listed key, and the resulting witness would fail in-circuit for a reason having nothing to
      // do with the circuit.
      require(!p.existence, 'a queried key is listed - pick different listed entries');

      oldKey[i] = p.auxKey;
      oldValue[i] = p.auxValue;
      isOld0[i] = p.auxExistence ? bytes32(0) : bytes32(uint256(1));
      for (uint256 j = 0; j < p.siblings.length; j++) siblings[i * DEPTH + j] = p.siblings[j];
    }

    string memory json = 'blacklistWitness';
    vm.serializeBytes32(json, 'root', root);
    vm.serializeBytes32(json, 'oldKey', oldKey);
    vm.serializeBytes32(json, 'oldValue', oldValue);
    vm.serializeBytes32(json, 'isOld0', isOld0);
    string memory out = vm.serializeBytes32(json, 'siblings', siblings);
    vm.writeJson(out, vm.envOr('BLACKLIST_WITNESS', string('test/identity/fixtures/blacklist_witness.json')));
  }
}
