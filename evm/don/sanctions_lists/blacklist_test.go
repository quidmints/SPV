package main

import (
	"bytes"
	"math/big"
	"testing"
)

// TestTheLeavesAreTheSmtPreimage is the property the whole redesign exists for.
//
// Anyone holding the anchor's calldata must be able to rebuild the SMT root and check it. That was
// impossible before: the leaves were name hashes and the SMT root was over document keys, so the
// published evidence and the enforced root described DIFFERENT DATA and no amount of on-chain
// hashing could connect them.
//
// This rebuilds from nothing but the leaf array - exactly what a verifier has - and requires the
// root to match.
func TestTheLeavesAreTheSmtPreimage(t *testing.T) {
	bl, err := BuildBlacklist([]PassportRow{
		{Number: "1084010", Country: "Egypt"},
		{Number: "304555", Country: "Egypt"},
		{Number: "T14553558", Country: "Iran"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bl.Leaves) != 3 {
		t.Fatalf("want 3 leaves, got %d", len(bl.Leaves))
	}

	// A verifier's view: the leaves, and nothing else.
	rebuilt := make([]SmtEntry, len(bl.Leaves))
	for i, leaf := range bl.Leaves {
		rebuilt[i] = SmtEntry{Key: new(big.Int).SetBytes(leaf[:]), Value: big.NewInt(1)}
	}
	root, err := SmtRoot(rebuilt)
	if err != nil {
		t.Fatal(err)
	}
	var got [32]byte
	root.FillBytes(got[:])

	if got != bl.SmtRoot {
		t.Fatalf("the published leaves do not reproduce the published root:\n  rebuilt %x\n  root    %x\n"+
			"  The calldata is supposed to BE the SMT's preimage - if it is not, nobody can check "+
			"the root the pool enforces.", got, bl.SmtRoot)
	}
}

// The anchor rejects leaves that are not strictly ascending, so this is a publication requirement
// rather than tidiness: unsorted leaves make the snapshot unpublishable.
func TestLeavesAreStrictlyAscending(t *testing.T) {
	bl, err := BuildBlacklist([]PassportRow{
		{Number: "T14553558", Country: "Iran"},
		{Number: "1084010", Country: "Egypt"},
		{Number: "304555", Country: "Egypt"},
	})
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i < len(bl.Leaves); i++ {
		if bytes.Compare(bl.Leaves[i-1][:], bl.Leaves[i][:]) >= 0 {
			t.Fatalf("leaf %d is not greater than leaf %d - the anchor will refuse this snapshot", i, i-1)
		}
	}
}

// One passport listed twice - the same document under two aliases, which the UK export makes
// ordinary - must contribute ONE leaf. Two would break strict ascent and make the snapshot
// unpublishable, which is a whole-feed outage caused by one duplicated row upstream.
func TestADuplicateDocumentContributesOneLeaf(t *testing.T) {
	bl, err := BuildBlacklist([]PassportRow{
		{Number: "1084010", Country: "Egypt"},
		{Number: "1084010", Country: "Egypt"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bl.Leaves) != 1 {
		t.Fatalf("want 1 leaf for one document listed twice, got %d", len(bl.Leaves))
	}
}

// A separator is presentation, so `AB-123456` and `AB123456` are ONE document. Asserted here as well
// as in documents_test because it is the dedup that depends on it: if normalisation let them differ,
// the same passport would occupy two leaves and be listed twice.
func TestNormalisationCollapsesTheSameDocument(t *testing.T) {
	bl, err := BuildBlacklist([]PassportRow{
		{Number: "AB-123456", Country: "Iran"},
		{Number: "AB123456", Country: "Iran"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bl.Leaves) != 1 {
		t.Fatalf("the same document under two spellings produced %d leaves", len(bl.Leaves))
	}
}

// An empty publication is the zero root, which is what the pool REFUSES - so a feed that keys
// nothing halts withdrawals rather than admitting everyone. Pinned so that stays true.
func TestAnEmptyPublicationIsTheZeroRoot(t *testing.T) {
	bl, err := BuildBlacklist(nil)
	if err != nil {
		t.Fatal(err)
	}
	if bl.SmtRoot != ([32]byte{}) {
		t.Fatalf("an empty blacklist is not the zero root: %x", bl.SmtRoot)
	}
}

// Skips are reported, not swallowed: each is a false negative for an exclusion predicate.
func TestSkipsSurviveIntoThePublication(t *testing.T) {
	bl, err := BuildBlacklist([]PassportRow{
		{Number: "1084010", Country: "Egypt"},
		{Number: "19820215", Country: ""},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bl.Leaves) != 1 || len(bl.Skipped) != 1 {
		t.Fatalf("want 1 leaf and 1 skip, got %d and %d", len(bl.Leaves), len(bl.Skipped))
	}
}
