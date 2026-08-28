// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {MerkleProof} from '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';

/*
 * THE GO SCRAPER AND THE SOLIDITY VERIFIER MUST AGREE ABOUT MERKLE TREES (sec. 2.18at).
 *
 * `backend/cre/notary_registry` builds the notary snapshot in Go; `TitleLedger.registerNotary`
 * checks membership with OpenZeppelin's `MerkleProof.verify`. Two conventions have to line up
 * exactly - sorted pairs at every node, and an odd node PROMOTED unchanged rather than hashed with
 * itself - and BOTH failure modes are silent: a mismatched generator emits proofs that never
 * verify, with no diagnostic beyond a boolean false.
 *
 * Go testing Go cannot catch that; a shared misunderstanding would make the generator and its own
 * checker agree and both be wrong. So the fixture below is produced by the REAL Go generator
 * (`go test -run EmitSolidity` in backend/cre/notary_registry, which rewrites it) and verified here
 * by the REAL library the contract uses. If the conventions ever diverge, this fails.
 *
 * FIXTURE PROVENANCE. Four records, one of them `terminated` so the active filter is exercised, and
 * the proof is for "123 / Jane Doe / Kyiv / active". Regenerate with:
 *   cd backend/cre/notary_registry && GOOS=darwin go test -run EmitSolidity ./...
 */
/*
 * TRAP FOR THE POSEIDON MIRROR (sec. 2.18bm, task #16). This suite exists because Go and Solidity can
 * disagree about Merkle construction SILENTLY - sorted pairs, odd-node promotion - and only a
 * cross-language fixture catches it.
 *
 * Anonymous enrolment adds a SECOND tree: a Poseidon mirror of the same leaf set, so the circuit can
 * prove inclusion cheaply (keccak costs ~one hash per level in-circuit). **That mirror needs its own
 * equivalent of this file.** Nothing automatically ties the two trees together: they could hold
 * different leaf sets, or agree on the set and disagree on ordering, and every test on each side
 * would still pass while a proof against the mirror asserted membership in a set the keccak root
 * never contained.
 *
 * The check to write: recompute BOTH roots from the SAME published leaves and require the mirror to
 * be a faithful image - not "the mirror is internally consistent", which is what a mirror-only test
 * would prove and is exactly the vacuous shape sec. 2.18ag warns about.
 */
contract NotaryRegistryProofTest is Test {
  function _fixture() internal view returns (bytes32 root_, bytes32 leaf_, bytes32[] memory proof_) {
    string memory raw = vm.readFile('test/fixtures/notary_registry_proof.txt');
    string[] memory lines = vm.split(raw, '\n');

    uint256 count;
    for (uint256 i = 0; i < lines.length; ++i) {
      if (bytes(lines[i]).length == 0) continue;
      string[] memory parts = vm.split(lines[i], ' ');
      bytes32 value = vm.parseBytes32(string.concat('0x', parts[1]));
      if (keccak256(bytes(parts[0])) == keccak256('root')) root_ = value;
      else if (keccak256(bytes(parts[0])) == keccak256('leaf')) leaf_ = value;
      else ++count;
    }

    proof_ = new bytes32[](count);
    uint256 j;
    for (uint256 i = 0; i < lines.length; ++i) {
      if (bytes(lines[i]).length == 0) continue;
      string[] memory parts = vm.split(lines[i], ' ');
      if (keccak256(bytes(parts[0])) == keccak256('proof')) {
        proof_[j++] = vm.parseBytes32(string.concat('0x', parts[1]));
      }
    }
  }

  /// THE BASELINE: a proof the Go scraper produced is accepted by the library the contract uses.
  function test_TheGoGeneratedProofVerifiesInSolidity() public view {
    (bytes32 root, bytes32 leaf, bytes32[] memory proof) = _fixture();
    assertTrue(
      MerkleProof.verify(proof, root, leaf),
      'the Go scraper and OpenZeppelin disagree about Merkle construction'
    );
  }

  /// And it is not vacuous: a different leaf must be rejected against the same root and path.
  /// Without this, a `verify` that returned true unconditionally would pass the test above.
  function test_ADifferentLeafIsRejected() public view {
    (bytes32 root, bytes32 leaf, bytes32[] memory proof) = _fixture();
    assertFalse(
      MerkleProof.verify(proof, root, bytes32(uint256(leaf) ^ 1)),
      'a leaf outside the snapshot verified'
    );
  }

  function test_ATamperedProofIsRejected() public view {
    (bytes32 root, bytes32 leaf, bytes32[] memory proof) = _fixture();
    require(proof.length > 0, 'fixture must have a non-empty path for this to mean anything');
    proof[0] = bytes32(uint256(proof[0]) ^ 1);
    assertFalse(MerkleProof.verify(proof, root, leaf), 'a tampered sibling verified');
  }

  function test_ADifferentRootIsRejected() public view {
    (bytes32 root, bytes32 leaf, bytes32[] memory proof) = _fixture();
    assertFalse(
      MerkleProof.verify(proof, bytes32(uint256(root) ^ 1), leaf),
      'the proof verified against a snapshot it does not belong to'
    );
  }
}
