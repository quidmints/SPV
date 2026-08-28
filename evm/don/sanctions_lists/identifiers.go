package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

// ═══════════════════════════════════════════════════════════════════
//  IDENTIFIER ROWS - the only fields in these exports an on-chain predicate can consume
// ═══════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS AT ALL. `decodeXML` collects a designation's NAMES, and a name-keyed Merkle tree
// cannot be checked against anything on-chain: our `label` is a per-deposit identifier and our
// `dg1Hash` is a hash of an MRZ, and neither lives in the same key space as
// `keccak(registryKey, Reference, Kind, NameParts...)`. A non-membership proof of either against a
// tree of name-hashes is TRUE FOR EVERYONE - it costs constraints and constrains nothing
// (TODO sec. 2.18fh).
//
// OFAC publishes exactly one family of fields that does live in an on-chain key space: the `idList`
// records, whose `idType` includes `"Digital Currency Address - XBT"`, `"- ETH"` and so on. Those are
// canonical bytes - no transliteration, no alias ordering, no similarity matching, no threshold.
//
// ⚠️ AND THE EXISTING WALKER DELIBERATELY SKIPS THEM. `decodeXML` reads DIRECT CHILDREN only,
// precisely so that a `<uid>` nested inside `akaList`/`addressList`/`idList` cannot be mistaken for
// the entry's own. That rule is correct and is not relaxed here; this is a separate pass with its own
// depth tracking, so the name path is untouched.
//
// SCOPE: addresses only, for now. Passport numbers sit in the same container (`idType == "Passport"`,
// with `idCountry`), and joining them to an MRZ needs a country-name -> ISO alpha-3 table because
// OFAC publishes `"Korea, North"` where the MRZ carries `PRK` (TODO sec. 2.18fo/2.18fp). That table
// is a separate change with its own failure mode, so it is not smuggled in here.

// ListedIdentifier is one identification record belonging to a designated party.
//
// NO `Reference` FIELD, AND THAT IS THE POINT. `ListedSubject` binds OFAC's own row identifier into
// its leaf, which is right for a name: names are not unique, so the leaf must say WHICH designation
// it belongs to. An address leaf must NOT, because the party checking it knows only an address - it
// has no idea what OFAC calls the entry. A leaf carrying the reference cannot be reconstructed by
// its consumer, so the tree anchors correctly, verifies correctly, and answers nothing.
type ListedIdentifier struct {
	// IDType verbatim, e.g. "Digital Currency Address - ETH". Bound into the leaf so a Bitcoin
	// address and an Ethereum address can never collide, and so normalisation stays per-chain.
	IDType string

	// Value as published, before normalisation.
	Value string
	// Country as published, when the set declares a CountryField. EMPTY IS A REAL STATE, not a
	// parse failure: the OFAC excerpt carries a passport row with an idNumber and no idCountry.
	Country string
}

// IdentifierSet declares where identifier rows live and which of them to keep.
type IdentifierSet struct {
	// Path from the document root to the repeating identifier element,
	// e.g. "sdnList/sdnEntry/idList/id".
	Path string

	// TypeField and ValueField are DIRECT CHILDREN of that element.
	TypeField  string
	ValueField string
	// CountryField is an OPTIONAL direct child naming the issuing state. Set only where the key needs
	// it - a digital-currency address has no issuing state, and a passport's key is meaningless
	// without one.
	//
	// ⚠️ OPTIONAL ON THE ROW TOO, and that is not laxity: a missing VALUE is a schema change and
	// errors below, while a missing COUNTRY is something the real export actually contains. Erroring
	// on it would fail the whole publication over one malformed listing; keying without it would
	// produce an entry no MRZ can match. It is dropped and counted instead - see DocumentKeys.
	CountryField string

	// TypePrefix keeps only rows whose type starts with it. A prefix rather than an exact match
	// because the currency is part of the type string: "Digital Currency Address - XBT",
	// "- ETH", "- USDT" and seventeen more.
	TypePrefix string
}

// ofacPassports keeps the passport rows, whose key the circuit computes from the MRZ.
//
// ⚠️ `TypePrefix: "Passport"` IS EXACT IN PRACTICE and was checked against the real export: the other
// idTypes are `Secondary sanctions risk:`, `Email Address`, `Gender` and `Digital Currency Address -
// …`, none of which begins with it. A looser match would key the tree on prose - one of those rows
// carries `section 1(b) of Executive Order 13224, as amended…` as its idNumber.
var ofacPassports = IdentifierSet{
	Path:         "sdnList/sdnEntry/idList/id",
	TypeField:    "idType",
	ValueField:   "idNumber",
	CountryField: "idCountry",
	TypePrefix:   "Passport",
}

// ofacDigitalCurrency is the only identifier set declared so far.
var ofacDigitalCurrency = IdentifierSet{
	Path:       "sdnList/sdnEntry/idList/id",
	TypeField:  "idType",
	ValueField: "idNumber",
	TypePrefix: "Digital Currency Address",
}

// normaliseIdentifier canonicalises a published identifier for hashing.
//
// ⚠️ PER-TYPE, AND THE OBVIOUS IMPLEMENTATION IS DESTRUCTIVE. The natural thing to write is
// `strings.ToUpper` over every address. That silently corrupts the majority of this feed: XBT, TRX,
// XMR, LTC and BCH addresses are base58 or bech32, where CASE IS SIGNIFICANT and folding it produces
// a different address. Ethereum-family addresses are hex, where case carries only an EIP-55
// checksum, so lower-casing them is both safe and necessary - an on-chain `address` has no case at
// all, and a checksummed literal would never match one derived from a transaction.
//
// So: fold case for the hex chains, and leave every other chain exactly as published.
func normaliseIdentifier(idType, value string) string {
	v := strings.TrimSpace(value)
	switch strings.TrimSpace(strings.TrimPrefix(idType, "Digital Currency Address -")) {
	case "ETH", "ETC", "ARB", "BSC", "BNB", "USDT", "USDC":
		return strings.ToLower(v)
	default:
		return v
	}
}

// identifierLeafHash binds the registry, the type and the normalised value - and nothing else.
//
// The consumer of this tree holds an address and a chain. It can reconstruct exactly these three
// things and no more, which is the whole requirement (see ListedIdentifier).
func identifierLeafHash(registryKey string, id ListedIdentifier) [32]byte {
	parts := make([]byte, 0, 96)
	parts = append(parts, crypto.Keccak256([]byte(registryKey))...)
	parts = append(parts, crypto.Keccak256([]byte(id.IDType))...)
	parts = append(parts, crypto.Keccak256([]byte(normaliseIdentifier(id.IDType, id.Value)))...)
	return crypto.Keccak256Hash(parts)
}

// identifierLeaves produces exactly the array RegistrySourceAnchor accepts: hashed, deduplicated,
// strictly ascending.
//
// SORTING IS NOT COSMETIC - `_computeRoot` REVERTS with `LeavesNotStrictlySorted` on anything else,
// so an unsorted array is not an untidy publish, it is a workflow that can never publish at all.
// Deduplication is load-bearing here too: one designated party routinely lists the same address under
// several entries, and OFAC lists 137 TRX addresses for a single entity in the excerpt alone.
func identifierLeaves(registryKey string, ids []ListedIdentifier) [][32]byte {
	seen := make(map[[32]byte]struct{}, len(ids))
	out := make([][32]byte, 0, len(ids))
	for _, id := range ids {
		h := identifierLeafHash(registryKey, id)
		if _, dup := seen[h]; dup {
			continue
		}
		seen[h] = struct{}{}
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool { return bytesLess(out[i], out[j]) })
	return out
}

// decodeIdentifiers streams the document and collects the declared identifier rows.
//
// DEPTH IS TRACKED, NOT ASSUMED, for the same reason `decodeXML` tracks it: `idList/id` contains its
// own `<uid>`, and a walker matching on element name alone would read the wrong thing. Namespaces are
// ignored, matching `decodeXML` - all three exports declare one and none uses it to disambiguate.
func decodeIdentifiers(body []byte, set IdentifierSet) ([]ListedIdentifier, error) {
	want := strings.Split(set.Path, "/")

	var (
		decoder   = xml.NewDecoder(bytes.NewReader(body))
		path      []string
		out       []ListedIdentifier
		rowDepth  int
		inRow     bool
		row       map[string]string
		fieldName string
		field     strings.Builder
	)

	atPath := func() bool {
		if len(path) != len(want) {
			return false
		}
		for i := range want {
			if path[i] != want[i] {
				return false
			}
		}
		return true
	}

	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("identifier parse: %w", err)
		}

		switch t := token.(type) {
		case xml.StartElement:
			path = append(path, t.Name.Local)
			if !inRow && atPath() {
				inRow, rowDepth = true, len(path)
				row = make(map[string]string, 3)
			} else if inRow && len(path) == rowDepth+1 {
				fieldName, field = t.Name.Local, strings.Builder{}
			}

		case xml.CharData:
			if inRow && fieldName != "" && len(path) == rowDepth+1 {
				field.Write(t)
			}

		case xml.EndElement:
			if inRow && fieldName != "" && len(path) == rowDepth+1 {
				row[fieldName] = field.String()
				fieldName = ""
			} else if inRow && len(path) == rowDepth {
				idType := strings.TrimSpace(row[set.TypeField])
				value := strings.TrimSpace(row[set.ValueField])
				// An empty value with a matching type is a schema change, not a designation with no
				// address - and dropping it silently is how a snapshot ends up short while looking
				// complete.
				if strings.HasPrefix(idType, set.TypePrefix) {
					if value == "" {
						return nil, fmt.Errorf("%q row carries no %s - the schema has changed", idType, set.ValueField)
					}
					id := ListedIdentifier{IDType: idType, Value: value}
					if set.CountryField != "" {
						id.Country = strings.TrimSpace(row[set.CountryField])
					}
					out = append(out, id)
				}
				inRow, row = false, nil
			}
			path = path[:len(path)-1]
		}
	}

	return out, nil
}
