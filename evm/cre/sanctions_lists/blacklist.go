// sanctions_lists/blacklist.go — the key set the withdrawal predicate proves non-membership against.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// THIS IS NOT THE TREE THE ANCHOR HASHES, AND THE TWO ARE NOT REDUNDANT.
//
//	leaves   EVERY designation, keyed by name, keccak, derived ON-CHAIN. The transparency artefact.
//	SmtRoot  only designations the predicate can KEY, Poseidon, asserted. What the pool enforces.
//
// ⛔ COLLAPSING THEM INTO ONE WAS TRIED AND IS A SILENT REGRESSION. Making the anchored leaves the
// KEYS reads as an elegant simplification - one dataset, and the calldata becomes the SMT's preimage
// - but `UK_OFSI_CONSOLIDATED` and `UN_SC_CONSOLIDATED` publish no document numbers at all. Those
// two registries would have anchored an EMPTY leaf set and a zero root while still reporting
// success. A name tree cannot be consumed by a predicate, and a key tree cannot represent a register
// that publishes no keys; both are true at once, which is why there are two.
//
// ⚠️ SO THE SMT ROOT IS ASSERTED, NOT DERIVED, AND THAT IS FORCED RATHER THAN CHOSEN. Deriving it
// on-chain would mean Poseidon at list scale - ~494M gas for 17k entries against a 30M block
// (measured, SanctionsRootHashCost.t.sol). Verifying it means rebuilding from the SOURCE, which is
// public; that is the same thing an auditor does to check the leaves are honest anyway.
//
// ⚠️ WHAT THE SMT COVERS IS NARROWER THAN WHAT IS ANCHORED, and the gap is the point of `Skipped`.
// A designation with no keyable passport is in the leaves and NOT in the SMT: anchored, and not
// enforced. For an EXCLUSION predicate each one is a false negative, so the count is returned rather
// than logged and forgotten - `onSchedule` warns on every run with a reason per row.
//
// ⛔ ADDRESSES ARE DELIBERATELY NOT PUBLISHED YET, though the feed carries them (137 TRX rows in the
// committed excerpt, and the type prefix already admits `- ETH`). `DOMAIN_ADDRESS` has no circuit
// term, so its identifier convention is pinned to nothing - publishing keys under a guessed
// convention would put entries in the tree that no future term matches, which is the silent-pass
// hole this file exists to avoid, arriving early instead of late. Add them WITH the term.
// ─────────────────────────────────────────────────────────────────────────────────────────────────

package main

import (
	"bytes"
	"fmt"
	"math/big"
	"sort"
)

// Blacklist is one publication: the same key set expressed as anchor leaves and as an SMT root.
type Blacklist struct {
	// Leaves are the keys, strictly ascending and deduplicated - the order `_publishSnapshot`
	// requires. This array is both the anchor's calldata and the SMT's preimage.
	Leaves [][32]byte
	// SmtRoot is the Poseidon root the withdrawal circuit proves non-membership against.
	SmtRoot [32]byte
	// Skipped are the rows that could not be keyed. NOT an error and NOT noise: for an EXCLUSION
	// predicate each one is a false negative, so the count is the feed's own health metric.
	Skipped []SkippedDocument
}

// BuildBlacklist turns published passport rows into a publication.
//
// Sorting and deduplication are the anchor's requirements, not preferences: `_publishSnapshot`
// rejects leaves that are not strictly ascending, and two identical rows carry no more information
// than one - the UK export publishes one row per alias, so exact duplicates are ordinary.
func BuildBlacklist(rows []PassportRow) (Blacklist, error) {
	keys, skipped, err := DocumentKeys(rows)
	if err != nil {
		return Blacklist{}, err
	}

	// Dedup on the KEY, which is what both views are built from. Two rows for one document - the
	// same passport listed under two aliases - must contribute one leaf, or the leaf array is not
	// strictly ascending and the snapshot cannot publish at all.
	seen := make(map[string]struct{}, len(keys))
	unique := make([]*big.Int, 0, len(keys))
	for _, k := range keys {
		s := k.String()
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		unique = append(unique, k)
	}

	entries := make([]SmtEntry, len(unique))
	leaves := make([][32]byte, len(unique))
	for i, k := range unique {
		// The SMT stores value 1 for every listed key, matching BlacklistWitnessFixture.t.sol - the
		// predicate only ever asks whether the key is ABSENT, so the value carries no meaning beyond
		// being non-zero.
		entries[i] = SmtEntry{Key: k, Value: big.NewInt(1)}
		k.FillBytes(leaves[i][:])
	}

	root, err := SmtRoot(entries)
	if err != nil {
		return Blacklist{}, fmt.Errorf("smt root: %w", err)
	}

	sort.Slice(leaves, func(i, j int) bool { return bytes.Compare(leaves[i][:], leaves[j][:]) < 0 })

	var smt [32]byte
	root.FillBytes(smt[:])
	return Blacklist{Leaves: leaves, SmtRoot: smt, Skipped: skipped}, nil
}
