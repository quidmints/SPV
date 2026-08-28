// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {EscrowFixtureBase} from './EscrowFixtureBase.sol';
import {PoseidonSMT} from '../../contracts/state/PoseidonSMT.sol';

/*
 * EMITS the registrationSmt inclusion witness that escrow_envelope proves against (sec. 2.18).
 *
 * WHY THIS LIVES IN ITS OWN FILE, apart from IdentityRegistry.t.sol where the other fixture emitter
 * sits. IT MUST RUN BEFORE ANY ESCROW PROOF EXISTS. The escrow circuit takes the witness emitted
 * here as an INPUT, so a suite that also loads `escrow_envelope<i>.proof` could not produce it -
 * those proofs are downstream of this file's output. Keeping the emitter free of every escrow
 * dependency is what lets the pipeline bootstrap from an empty fixtures directory.
 *
 * WHY THE SUITE GENERATES IT AT ALL, rather than a script. Same reason
 * `test_EmitIdentityWitnessFixture` does, and the same reason the wallet asks the contract instead
 * of mirroring it (see frontend/identity-wallet/src/pp/identityProof.ts): a witness built off-chain
 * would need a second implementation of a sparse trie kept byte-compatible forever, and would only
 * ever prove that two of our own implementations agree.
 *
 * THE PIPELINE, in order. Each step consumes the previous step's output:
 *   1. node tools/build-escrow-fixtures.js --documents 3   ->  escrow_documents.json
 *   2. forge test --match-test test_EmitRegistrationWitnessFixture  ->  registration_witness.json
 *   3. node tools/build-escrow-fixtures.js 3               ->  Prover.escrow<i>.toml
 *   4. backend/circuits/codegen-verifiers.sh               ->  proofs + verifier
 */
contract RegistrationWitnessFixtureTest is EscrowFixtureBase {
  function setUp() public {
    _setUpStateKeeper();
  }

  function test_EmitRegistrationWitnessFixture() public {
    bytes32[] memory indices = _bindDocumentsFromFixture();
    PoseidonSMT smt = _registrationSmt();

    // Serialised FLAT rather than as an array of objects: forge-std can emit a bytes32[] under a
    // key but not an array of nested objects without string-quoting them, and a flat shape the
    // generator indexes by position is less machinery than either.
    string memory json = 'registrationWitness';
    vm.serializeUint(json, 'count', indices.length);

    for (uint256 i = 0; i < indices.length; ++i) {
      SparseMerkleTree.Proof memory p = smt.getProof(indices[i]);

      assertTrue(p.existence, 'document leaf is absent from registrationSmt');
      assertLe(p.siblings.length, REGISTRATION_TREE_DEPTH, 'witness deeper than the circuit');

      bool anyNonZero = false;
      for (uint256 j = 0; j < p.siblings.length; ++j) {
        if (p.siblings[j] != bytes32(0)) anyNonZero = true;
      }
      assertTrue(anyNonZero, 'DEGENERATE witness - no sibling would ever be hashed');

      vm.serializeBytes32(json, string.concat('siblings', vm.toString(i)), p.siblings);
      // seq is 0 for a first binding; `_bindDocument` increments it only on renewal.
      vm.serializeUint(json, string.concat('seq', vm.toString(i)), 0);
      vm.serializeUint(json, string.concat('timestamp', vm.toString(i)), FIXTURE_TIMESTAMP);
    }

    string memory out = vm.serializeBytes32(json, 'root', smt.getRoot());
    vm.writeJson(out, 'test/fixtures/registration_witness.json');
  }
}
