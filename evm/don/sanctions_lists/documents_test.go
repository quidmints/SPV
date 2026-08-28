package main

import (
	"math/big"
	"testing"
)

// TestPaddedIdentifierMatchesTheMrzDerivation is the test the whole file exists for.
//
// The expected value was computed by the WALLET's Poseidon over a TD1 DG1 whose document-number
// field holds the published `1084010` as ICAO writes it - `1084010<<`, left-aligned and filler-padded
// - read at the offsets `td1_dg1_data_extractor` reads. That derivation is itself pinned to the
// circuit: `nargo execute` solves the escrow witness only when the wallet's document id equals the
// one the circuit computes in-constraint.
//
// ⛔ SO THIS PINS THE PADDING RULE ACROSS THREE LANGUAGES. Publish `1084010` unpadded and the key is
// a different field element: the root still anchors, every exclusion proof still verifies, and the
// listed person still passes. Nothing errors, anywhere.
func TestPaddedIdentifierMatchesTheMrzDerivation(t *testing.T) {
	state, err := NormaliseIssuingState("Egypt")
	if err != nil {
		t.Fatalf("issuing state: %v", err)
	}
	if state != "EGY" {
		t.Fatalf("Egypt mapped to %q, not EGY", state)
	}

	num, err := NormaliseDocumentNumber("1084010")
	if err != nil {
		t.Fatalf("document number: %v", err)
	}
	if num != "1084010<<" {
		t.Fatalf("padding is wrong: %q", num)
	}

	got, err := DocumentIdentifier(state, num)
	if err != nil {
		t.Fatalf("identifier: %v", err)
	}
	want, _ := new(big.Int).SetString(
		"5259271935849978876198604472875515961162731750508986531990478677439328748239", 10)
	if got.Cmp(want) != 0 {
		t.Fatalf("the feed's key and the MRZ's key disagree:\n  go  %s\n  mrz %s\n"+
			"  Every listed holder would pass, and nothing would error.", got, want)
	}
}

// The unpadded form is a DIFFERENT key. Asserted so that the padding is never "simplified" away by
// someone who reads `1084010<<` as a formatting artefact.
func TestUnpaddedNumberIsADifferentKey(t *testing.T) {
	padded, _ := DocumentIdentifier("EGY", "1084010<<")
	// Nine characters, but the filler moved to the front - the same characters, a different document.
	shifted, _ := DocumentIdentifier("EGY", "<<1084010")
	if padded.Cmp(shifted) == 0 {
		t.Fatal("filler position does not affect the key; alignment is not being hashed")
	}
}

// Over-length numbers are refused rather than truncated: a truncated number is a DIFFERENT document's
// key, published as if it were this one's.
func TestOverLengthNumberIsRefused(t *testing.T) {
	if _, err := NormaliseDocumentNumber("1234567890"); err == nil {
		t.Fatal("a ten-character document number was accepted")
	}
}

// Separators are presentation; the MRZ has none.
func TestSeparatorsAreDropped(t *testing.T) {
	a, err := NormaliseDocumentNumber("AB-123456")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NormaliseDocumentNumber("AB123456")
	if a != b {
		t.Fatalf("%q and %q are the same document but normalise differently", a, b)
	}
}

// The row the real export actually contains: a passport with NO issuing state. It cannot be keyed -
// the circuit's key takes both arguments - so it must be reported, never keyed with an empty state.
func TestACountrylessRowIsSkippedAndCounted(t *testing.T) {
	keys, skipped, err := DocumentKeys([]PassportRow{
		{Number: "1084010", Country: "Egypt"},
		{Number: "19820215", Country: ""}, // real row from ofac_ids_excerpt.xml
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 {
		t.Fatalf("want 1 key, got %d", len(keys))
	}
	if len(skipped) != 1 || skipped[0].Number != "19820215" {
		t.Fatalf("the countryless row was not reported: %+v", skipped)
	}
}

// An unmapped country is reported by name, so the table grows from what the feed contains rather
// than from someone guessing which spellings OFAC uses.
func TestAnUnmappedCountryIsNamedInTheSkip(t *testing.T) {
	_, skipped, err := DocumentKeys([]PassportRow{{Number: "123456", Country: "Curacao"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(skipped) != 1 {
		t.Fatalf("want 1 skip, got %d", len(skipped))
	}
	if !contains(skipped[0].Reason, "Curacao") {
		t.Fatalf("the skip does not name the country: %q", skipped[0].Reason)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// TestPassportRowsFromTheRealExport decodes the committed OFAC excerpt and keys what it can.
//
// ⚠️ AGAINST THE REAL FILE, because every assumption in documents.go came from reading it and would
// otherwise be a guess about a schema. The excerpt's four passport rows are exactly the interesting
// spread: two mappable countries, one row with NO country, and numbers of six, seven, eight and nine
// characters - so the padding path, the skip path and the mapping path are all exercised by data
// nobody wrote for the test.
func TestPassportRowsFromTheRealExport(t *testing.T) {
	ids, err := decodeIdentifiers(load(t, "ofac_ids_excerpt.xml"), ofacPassports)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(ids) != 4 {
		t.Fatalf("want 4 passport rows, got %d - the excerpt has four", len(ids))
	}

	rows := make([]PassportRow, len(ids))
	for i, id := range ids {
		if id.IDType != PassportIDType {
			t.Fatalf("row %d is %q, not a passport - the type filter is too loose", i, id.IDType)
		}
		rows[i] = PassportRow{Number: id.Value, Country: id.Country}
	}

	keys, skipped, err := DocumentKeys(rows)
	if err != nil {
		t.Fatalf("keys: %v", err)
	}
	// Three are keyable; the fourth is the row published with an idNumber and no idCountry.
	if len(keys) != 3 || len(skipped) != 1 {
		t.Fatalf("want 3 keys and 1 skip, got %d and %d (%+v)", len(keys), len(skipped), skipped)
	}
	if skipped[0].Number != "19820215" {
		t.Fatalf("the wrong row was skipped: %+v", skipped[0])
	}

	// Distinct keys. Two of these share an issuing state, so a construction that dropped the number
	// or the domain would collide here rather than in production.
	seen := map[string]bool{}
	for _, k := range keys {
		if seen[k.String()] {
			t.Fatal("two passports produced the same blacklist key")
		}
		seen[k.String()] = true
	}
}
