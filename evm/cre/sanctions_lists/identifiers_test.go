package main

import (
	"os"
	"strings"
	"testing"
)

// The fixture is REAL: five entries cut verbatim from OFAC's published SDN.XML (2026-08-07), chosen
// to cover an entity with many TRX addresses, one with XMR, one individual carrying BOTH a passport
// and an XBT address, and an individual with two passports of which one has no country. It also
// carries the noise types the filter has to reject - Email Address, Gender, Organization Type - and a
// passport whose idNumber is `19820215`, i.e. a BIRTHDATE in a passport field.
func loadIDFixture(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/ofac_ids_excerpt.xml")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return b
}

func TestDecodeIdentifiersKeepsOnlyDigitalCurrencyRows(t *testing.T) {
	ids, err := decodeIdentifiers(loadIDFixture(t), ofacDigitalCurrency)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	// 137 TRX + 3 XMR + 1 XBT in the fixture.
	if len(ids) != 141 {
		t.Fatalf("expected 141 digital-currency rows, got %d", len(ids))
	}
	for _, id := range ids {
		if !strings.HasPrefix(id.IDType, "Digital Currency Address") {
			t.Fatalf("filter admitted a non-address row: %q", id.IDType)
		}
		if id.Value == "" {
			t.Fatalf("row of type %q has an empty value", id.IDType)
		}
	}
}

// NON-VACUITY. Without this, a decoder that returned everything would pass the test above only by
// accident of the count. The fixture definitely contains Passport, Email Address and Gender rows;
// none may appear.
func TestDecodeIdentifiersRejectsTheNoiseTypes(t *testing.T) {
	ids, err := decodeIdentifiers(loadIDFixture(t), ofacDigitalCurrency)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, id := range ids {
		switch id.IDType {
		case "Passport", "Email Address", "Gender", "Organization Type:":
			t.Fatalf("filter admitted %q, which is not an address", id.IDType)
		}
	}
	// ...and prove the fixture really contains them, so the check above is not vacuous.
	all, err := decodeIdentifiers(loadIDFixture(t), IdentifierSet{
		Path: ofacDigitalCurrency.Path, TypeField: "idType", ValueField: "idNumber", TypePrefix: "",
	})
	if err != nil {
		t.Fatalf("decode all: %v", err)
	}
	var sawPassport bool
	for _, id := range all {
		if id.IDType == "Passport" {
			sawPassport = true
		}
	}
	if !sawPassport {
		t.Fatal("fixture contains no Passport rows, so the rejection test proves nothing")
	}
}

// THE ONE THAT WOULD HAVE SHIPPED A CORRUPTED TREE. Folding case is correct for hex chains and
// destructive for base58, so normalisation must be per-type.
func TestNormaliseIdentifierIsPerChain(t *testing.T) {
	cases := []struct{ idType, in, want string }{
		// Ethereum-family: an on-chain address has no case, so a checksummed literal must fold.
		{"Digital Currency Address - ETH", "0xAbC123dEf456", "0xabc123def456"},
		{"Digital Currency Address - USDT", "0xFFEE00", "0xffee00"},
		// base58 / bech32: case is significant, folding it yields a DIFFERENT address.
		{"Digital Currency Address - XBT", "1MFbFkQr6QRPmnR8Xr1", "1MFbFkQr6QRPmnR8Xr1"},
		{"Digital Currency Address - TRX", "TNiq9AXBp9EjUqhDhrwrfv", "TNiq9AXBp9EjUqhDhrwrfv"},
		{"Digital Currency Address - XMR", "44dZUJ7w1T3fKAvFW8XyXU", "44dZUJ7w1T3fKAvFW8XyXU"},
		// whitespace is never meaningful
		{"Digital Currency Address - ETH", "  0xAB  ", "0xab"},
	}
	for _, c := range cases {
		if got := normaliseIdentifier(c.idType, c.in); got != c.want {
			t.Errorf("%s: normalise(%q) = %q, want %q", c.idType, c.in, got, c.want)
		}
	}
}

// A Bitcoin address and an Ethereum address that happen to share a string must not collide, because
// the type is bound into the leaf.
func TestIdentifierLeafBindsTheChain(t *testing.T) {
	a := identifierLeafHash("OFAC_SDN_ADDRESSES", ListedIdentifier{IDType: "Digital Currency Address - XBT", Value: "0xAB"})
	b := identifierLeafHash("OFAC_SDN_ADDRESSES", ListedIdentifier{IDType: "Digital Currency Address - ETC", Value: "0xAB"})
	if a == b {
		t.Fatal("two chains produced the same leaf for the same string")
	}
	// And the registry key is bound too, so the same address under two registries differs.
	c := identifierLeafHash("SOME_OTHER_LIST", ListedIdentifier{IDType: "Digital Currency Address - XBT", Value: "0xAB"})
	if a == c {
		t.Fatal("two registries produced the same leaf")
	}
}

// The anchor REVERTS on unsorted or duplicate leaves, so this is not a tidiness property - it decides
// whether the workflow can publish at all.
func TestIdentifierLeavesAreDedupedAndStrictlyAscending(t *testing.T) {
	ids, err := decodeIdentifiers(loadIDFixture(t), ofacDigitalCurrency)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	leaves := identifierLeaves("OFAC_SDN_ADDRESSES", ids)
	if len(leaves) == 0 {
		t.Fatal("no leaves")
	}
	for i := 1; i < len(leaves); i++ {
		if !bytesLess(leaves[i-1], leaves[i]) {
			t.Fatalf("leaf %d is not strictly greater than %d - the anchor would revert", i, i-1)
		}
	}
	// Feeding the same set twice must not grow the tree.
	again := identifierLeaves("OFAC_SDN_ADDRESSES", append(ids, ids...))
	if len(again) != len(leaves) {
		t.Fatalf("duplicates were not removed: %d vs %d", len(again), len(leaves))
	}
}

// A matching type with no value is a schema change upstream. Failing loudly is the point: dropping
// the row would shorten the snapshot while it still looked complete.
func TestDecodeIdentifiersRefusesAMatchingRowWithNoValue(t *testing.T) {
	doc := []byte(`<sdnList><sdnEntry><idList><id>
	  <uid>1</uid><idType>Digital Currency Address - ETH</idType><idNumber></idNumber>
	</id></idList></sdnEntry></sdnList>`)
	if _, err := decodeIdentifiers(doc, ofacDigitalCurrency); err == nil {
		t.Fatal("expected an error for an address row with no idNumber")
	}
}

// The nested <uid> inside idList/id must not be confused for anything else; this pins that the walker
// reads the row's own direct children rather than any descendant.
func TestDecodeIdentifiersReadsDirectChildrenOnly(t *testing.T) {
	doc := []byte(`<sdnList><sdnEntry>
	  <uid>999</uid>
	  <idList><id><uid>1</uid><idType>Digital Currency Address - ETH</idType><idNumber>0xAA</idNumber></id></idList>
	</sdnEntry></sdnList>`)
	ids, err := decodeIdentifiers(doc, ofacDigitalCurrency)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(ids) != 1 || ids[0].Value != "0xAA" {
		t.Fatalf("expected one row valued 0xAA, got %+v", ids)
	}
}
