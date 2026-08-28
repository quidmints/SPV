// sanctions_lists/documents.go — turning a published passport row into the key the circuit queries.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// THE PARSING IS THE EASY HALF. The circuit keys the blacklist by
// `blacklist_key(DOMAIN_DOCUMENT, document_identifier(issuing_state, document_number))`, where both
// arguments are read FROM THE MRZ at ICAO's offsets — three bytes of ISO 3166 alpha-3, and a
// nine-character field. What OFAC publishes is neither:
//
//	published            in the MRZ           consequence if used as published
//	`Egypt`              `EGY`                a key nobody holds
//	`1084010`            `1084010<<`          a key nobody holds
//
// ⛔ AND NEITHER MISTAKE ANNOUNCES ITSELF. The root anchors, every exclusion proof verifies, and
// every listed person passes — because the tree is keyed on values no MRZ can produce. That is the
// same silent-pass hole as publishing over the name leaves, reached from the normalisation side.
// The conformance tests pin both derivations against the values the circuit actually accepted.
// ─────────────────────────────────────────────────────────────────────────────────────────────────

package main

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/iden3/go-iden3-crypto/poseidon"
)

// mrzDocumentNumberLen is the width of the document-number field in both TD1 and TD3.
//
// The circuit reads exactly this many bytes (`td1_dg1_data_extractor`, DOCUMENT_NUMBER_SIZE = 9), so
// a shorter published number must be padded to it or the two sides hash different byte strings.
const mrzDocumentNumberLen = 9

// mrzFiller is what ICAO pads a short field with. It is a real character in the hashed bytes, not
// whitespace to be trimmed.
const mrzFiller = '<'

// PassportIDType is the exact `idType` a passport row carries.
//
// ⚠️ EXACT, NOT A PREFIX. The same `idList` carries `Secondary sanctions risk:`, `Email Address` and
// `Gender`, whose `idNumber` is prose - `section 1(b) of Executive Order 13224, ...`. A prefix or a
// contains-match would key the tree on sentences.
const PassportIDType = "Passport"

// isoAlpha3 maps the issuing-state names OFAC publishes to the codes an MRZ carries.
//
// ⚠️ SEEDED BY OBSERVATION, NOT BY A STANDARD, AND THAT IS DELIBERATE. OFAC's names are not ISO's:
// the register says `Iran` where ISO says `Iran (Islamic Republic of)`, and will say `Korea, North`
// where ISO says `Korea (Democratic People's Republic of)`. A general ISO library would miss exactly
// the entries a curated table is written to catch, so the table grows from what the feed actually
// contains and an unmapped name is REPORTED rather than guessed at.
var isoAlpha3 = map[string]string{
	"egypt": "EGY",
	"iran":  "IRN",
}

// NormaliseDocumentNumber renders a published number as the MRZ field the circuit hashes.
//
// Uppercased, stripped to the MRZ alphabet, left-aligned and filler-padded to nine. Anything longer
// than nine is refused rather than truncated: TD3 carries an over-length number in the optional field
// with a check-digit convention, so truncating would silently produce a DIFFERENT document's key.
func NormaliseDocumentNumber(published string) (string, error) {
	var b strings.Builder
	for _, r := range strings.ToUpper(strings.TrimSpace(published)) {
		switch {
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '.' || r == '/':
			// Separators are presentation, and the MRZ has none. Dropping them is what makes
			// `AB-123456` and `AB123456` the same document, which they are.
		default:
			return "", fmt.Errorf("document number %q contains %q, which no MRZ can encode", published, r)
		}
	}
	n := b.String()
	if n == "" {
		return "", fmt.Errorf("document number %q is empty after normalisation", published)
	}
	if len(n) > mrzDocumentNumberLen {
		return "", fmt.Errorf(
			"document number %q is %d characters; the MRZ field is %d and over-length numbers use the "+
				"optional-field convention this does not implement", published, len(n), mrzDocumentNumberLen)
	}
	return n + strings.Repeat(string(mrzFiller), mrzDocumentNumberLen-len(n)), nil
}

// NormaliseIssuingState maps a published country name to its MRZ alpha-3 code.
func NormaliseIssuingState(published string) (string, error) {
	key := strings.ToLower(strings.TrimSpace(published))
	if key == "" {
		return "", fmt.Errorf("issuing state is absent")
	}
	if code, ok := isoAlpha3[key]; ok {
		return code, nil
	}
	// A three-letter value is already a code in some feeds; accept it rather than demanding a table
	// entry that would just map it to itself.
	if len(key) == 3 {
		up := strings.ToUpper(key)
		for _, r := range up {
			if r < 'A' || r > 'Z' {
				return "", fmt.Errorf("issuing state %q is not a name in the table nor an alpha-3 code", published)
			}
		}
		return up, nil
	}
	return "", fmt.Errorf("issuing state %q has no alpha-3 mapping; add it to isoAlpha3", published)
}

// DocumentIdentifier is `document_identifier(issuing_state, document_number)` as the circuit computes
// it: a Poseidon over the two MRZ byte strings read big-endian.
//
// ⚠️ BIG-ENDIAN IS COPIED FROM THE EXTRACTOR, NOT CHOSEN. `td1_dg1_data_extractor` accumulates
// `current * dg1[SHIFT + SIZE - 1 - i]` with `current *= 256`, which walks the range backwards from
// its last byte — a plain big-endian read. Reversing it yields a different-but-valid field element:
// the proof still verifies and the key simply never matches.
func DocumentIdentifier(issuingState, mrzNumber string) (*big.Int, error) {
	if len(issuingState) != 3 {
		return nil, fmt.Errorf("issuing state %q must be three characters", issuingState)
	}
	if len(mrzNumber) != mrzDocumentNumberLen {
		return nil, fmt.Errorf("document number %q must be %d characters", mrzNumber, mrzDocumentNumberLen)
	}
	be := func(s string) *big.Int { return new(big.Int).SetBytes([]byte(s)) }
	return poseidon.Hash([]*big.Int{be(issuingState), be(mrzNumber)})
}

// SkippedDocument records a row that could not be keyed, and why.
//
// ⚠️ SKIPS ARE COUNTED AND RETURNED, NEVER SWALLOWED. For an EXCLUSION predicate a dropped listing is
// a false negative — that person's document is absent from the tree, so their withdrawal passes. The
// alternative, failing the whole publication on one unmappable country, halts every withdrawal
// instead. Neither is free, so the choice here is: publish, and make the omissions COUNTABLE, so a
// feed that starts dropping entries is visible rather than quietly permissive.
type SkippedDocument struct {
	Number string
	Reason string
}

// DocumentKeys turns raw passport rows into blacklist keys, reporting what it could not key.
func DocumentKeys(rows []PassportRow) ([]*big.Int, []SkippedDocument, error) {
	var keys []*big.Int
	var skipped []SkippedDocument
	for _, r := range rows {
		state, err := NormaliseIssuingState(r.Country)
		if err != nil {
			skipped = append(skipped, SkippedDocument{Number: r.Number, Reason: err.Error()})
			continue
		}
		num, err := NormaliseDocumentNumber(r.Number)
		if err != nil {
			skipped = append(skipped, SkippedDocument{Number: r.Number, Reason: err.Error()})
			continue
		}
		id, err := DocumentIdentifier(state, num)
		if err != nil {
			return nil, nil, err
		}
		key, err := poseidon.Hash([]*big.Int{big.NewInt(DomainDocument), id})
		if err != nil {
			return nil, nil, err
		}
		keys = append(keys, key)
	}
	return keys, skipped, nil
}

// PassportRow is one `idType == "Passport"` entry, as published.
type PassportRow struct {
	Number  string
	Country string // may be absent, which is why it cannot simply be assumed present
}

// Domains from backend/circuits/pp/src/blacklist.nr. A pool label and a passport number are both
// field elements; without separation a sanctioned document could collide with an innocent label.
const (
	DomainLabel    = 1
	DomainAddress  = 2
	DomainDocument = 3
)
