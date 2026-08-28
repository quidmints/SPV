// sanctions_lists/smt.go — the Poseidon sparse Merkle tree the blacklist predicate proves against.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// THIS IS NOT THE TREE `merkleRoot` BUILDS, AND CONFUSING THE TWO IS THE FAILURE MODE.
//
//	merkleRoot   keccak, dense, binary. Cheap on-chain; what the anchor's inclusion checks use.
//	SmtRoot      Poseidon, sparse, keyed. The ONLY one a circuit can verify - in-circuit the cost
//	             relation inverts and keccak becomes the expensive hash.
//
// ⛔ THE CONVENTION IS COPIED FROM `SparseMerkleTree.sol`, NOT CHOSEN. A mismatch does not error: it
// produces a different-but-valid root, every exclusion proof fails to verify, and the search starts
// in the circuit. The three rules, from `_getNodeHash` and the traversal at `(key >> depth) & 1`:
//
//	leaf   = Poseidon(key, value, 1)      <- the trailing 1 is what separates a leaf from a branch
//	branch = Poseidon(left, right)
//	empty  = 0                            <- and an empty subtree contributes 0, never a hash of 0
//
// `smt_conformance_test.go` builds a root over the SAME entries the Solidity emitter used and
// compares it to the root that emitter produced. That test is the only thing standing between this
// file and a silent divergence.
//
// 🔴 NOT CALLED BY THE WORKFLOW YET, AND THAT IS A MISSING INPUT RATHER THAN MISSING WIRING.
// `onSchedule` still publishes a zero root. The reason is upstream: the predicate keys the tree by
// `blacklist_key(DOMAIN_DOCUMENT, document_identifier(issuing_state, document_number))`, and
// `ListedSubject` carries `Reference`, `Kind` and `NameParts` - no document number, no issuing
// state. No source parser extracts them today.
//
// ⛔ DO NOT "FINISH" THIS BY PUBLISHING A ROOT OVER THE NAME LEAVES. It would compute, anchor and
// look published, and every exclusion proof would still succeed - because the circuit queries keys
// that tree does not contain. That is strictly worse than the zero it replaces: zero halts
// withdrawals loudly, whereas a name-keyed root passes silently while listing nobody the predicate
// can see. Wire this only once a parser yields document numbers.
// ─────────────────────────────────────────────────────────────────────────────────────────────────

package main

import (
	"fmt"
	"math/big"

	"github.com/iden3/go-iden3-crypto/poseidon"
)

// MaxSmtDepth matches IDENTITY_TREE_DEPTH in the circuit and the emitter's DEPTH.
//
// ⚠️ IT IS A REAL BOUND, NOT A FORMALITY. Two keys agreeing on their first MaxSmtDepth bits cannot
// be separated, and a tree that silently merged them would prove non-membership for a key that IS
// listed - the one failure this whole predicate exists to prevent. Poseidon makes that astronomically
// unlikely and the error path says so rather than assuming it.
const MaxSmtDepth = 32

// SmtEntry is one listed key. Value is carried because the leaf hash commits to it, even though the
// predicate only ever asks whether the key is absent.
type SmtEntry struct {
	Key   *big.Int
	Value *big.Int
}

// SmtRoot builds the sparse Merkle tree over `entries` and returns its root.
//
// Duplicate keys are rejected rather than deduplicated: two entries for one key is a defect in
// whatever produced the list, and silently keeping one of them would publish a tree that disagrees
// with the source everyone else reads.
func SmtRoot(entries []SmtEntry) (*big.Int, error) {
	seen := make(map[string]struct{}, len(entries))
	for _, e := range entries {
		if e.Key == nil || e.Value == nil {
			return nil, fmt.Errorf("smt: nil key or value")
		}
		k := e.Key.String()
		if _, dup := seen[k]; dup {
			return nil, fmt.Errorf("smt: duplicate key %s", k)
		}
		seen[k] = struct{}{}
	}
	return smtNode(entries, 0)
}

func smtNode(entries []SmtEntry, depth int) (*big.Int, error) {
	switch len(entries) {
	case 0:
		// An empty subtree is the zero node. NOT Poseidon(0) - the tree is sparse precisely because
		// absent subtrees cost nothing to represent.
		return big.NewInt(0), nil
	case 1:
		return poseidon.Hash([]*big.Int{entries[0].Key, entries[0].Value, big.NewInt(1)})
	}

	if depth >= MaxSmtDepth {
		return nil, fmt.Errorf(
			"smt: %d keys share their first %d bits and cannot be separated", len(entries), MaxSmtDepth)
	}

	var left, right []SmtEntry
	for _, e := range entries {
		// Bit `depth` of the key, LSB first, exactly as the Solidity traversal reads it.
		if e.Key.Bit(depth) == 1 {
			right = append(right, e)
		} else {
			left = append(left, e)
		}
	}

	l, err := smtNode(left, depth+1)
	if err != nil {
		return nil, err
	}
	r, err := smtNode(right, depth+1)
	if err != nil {
		return nil, err
	}
	return poseidon.Hash([]*big.Int{l, r})
}
