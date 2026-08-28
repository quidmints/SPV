package main

import (
	"encoding/json"
	"math/big"
	"os"
	"testing"

	"github.com/iden3/go-iden3-crypto/poseidon"
)

const fixtures = "../../contracts/test/fixtures/"

func readHexArray(t *testing.T, path string) []*big.Int {
	t.Helper()
	raw, err := os.ReadFile(fixtures + path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var hex []string
	if err := json.Unmarshal(raw, &hex); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	out := make([]*big.Int, len(hex))
	for i, h := range hex {
		v, ok := new(big.Int).SetString(h[2:], 16)
		if !ok {
			t.Fatalf("%s[%d] is not hex: %s", path, i, h)
		}
		out[i] = v
	}
	return out
}

// TestSmtRootMatchesTheSolidityTree is THE test this file exists for.
//
// It builds a root over the same listed entries `BlacklistWitnessFixture.t.sol` was given, and
// compares it against the root that fixture emitted from a real solarity SparseMerkleTree - the same
// library the circuit's exclusion proofs are verified against on the identity path.
//
// ⛔ WITHOUT THIS THERE IS NO WAY TO TELL A WRONG TREE FROM A WRONG PROOF. A convention mismatch -
// leaf vs branch hashing, bit order, how an empty subtree is represented - does not error anywhere.
// It yields a different-but-valid root, every exclusion proof fails to verify, and the investigation
// starts in Noir. Three languages have to agree on this one number; two of them are checked here and
// the third is checked by `nargo execute` accepting a witness built against it.
func TestSmtRootMatchesTheSolidityTree(t *testing.T) {
	listed := readHexArray(t, "blacklist_listed.json")
	if len(listed) == 0 {
		t.Fatal("blacklist_listed.json is empty - an empty tree would pass this test vacuously")
	}

	entries := make([]SmtEntry, len(listed))
	for i, k := range listed {
		// The emitter inserts value 1 for every listed key.
		entries[i] = SmtEntry{Key: k, Value: big.NewInt(1)}
	}

	got, err := SmtRoot(entries)
	if err != nil {
		t.Fatalf("SmtRoot: %v", err)
	}

	raw, err := os.ReadFile(fixtures + "blacklist_witness.json")
	if err != nil {
		t.Fatalf("read blacklist_witness.json: %v", err)
	}
	var wit struct {
		Root string `json:"root"`
	}
	if err := json.Unmarshal(raw, &wit); err != nil {
		t.Fatalf("parse blacklist_witness.json: %v", err)
	}
	want, ok := new(big.Int).SetString(wit.Root[2:], 16)
	if !ok {
		t.Fatalf("root is not hex: %s", wit.Root)
	}

	if got.Cmp(want) != 0 {
		t.Fatalf("the Go tree and the Solidity tree disagree:\n  go       %s\n  solidity %s\n"+
			"  Check the three rules in smt.go against SparseMerkleTree._getNodeHash - a mismatch "+
			"here means every exclusion proof will fail to verify with no indication why.", got, want)
	}
}

// A leaf is not a branch, and the trailing 1 is what makes that true. Without it a single-entry tree
// could collide with a two-child node, which is the classic second-preimage shape.
func TestLeafIsDomainSeparatedFromBranch(t *testing.T) {
	a, b := big.NewInt(7), big.NewInt(9)
	leaf, err := SmtRoot([]SmtEntry{{Key: a, Value: b}})
	if err != nil {
		t.Fatal(err)
	}
	branch, err := poseidon.Hash([]*big.Int{a, b})
	if err != nil {
		t.Fatal(err)
	}
	if leaf.Cmp(branch) == 0 {
		t.Fatal("a leaf hashes to the same value as a branch over its key and value")
	}
}

// An empty tree is the zero root, which is what makes the all-zero exclusion witness valid for every
// key - the bootstrap the batch fixtures relied on before a real tree existed.
func TestEmptyTreeIsZero(t *testing.T) {
	root, err := SmtRoot(nil)
	if err != nil {
		t.Fatal(err)
	}
	if root.Sign() != 0 {
		t.Fatalf("empty tree is not the zero root: %s", root)
	}
}

// Two entries for one key is a defect upstream; keeping one silently would publish a tree that
// disagrees with the list everyone else reads.
func TestDuplicateKeysAreRejected(t *testing.T) {
	k := big.NewInt(42)
	if _, err := SmtRoot([]SmtEntry{{Key: k, Value: big.NewInt(1)}, {Key: k, Value: big.NewInt(1)}}); err == nil {
		t.Fatal("a duplicate key was accepted")
	}
}
