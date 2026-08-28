// The first tests this workflow has ever had (sec. 2.18ao).
//
// WHY THIS FILE EXISTS. `backend/cre/notary_registry` is ~500 lines of OUR OWN code with no tests at
// all, and it decides WHO COUNTS AS A NOTARY. Since sec. 2.18am it is also load-bearing for privacy:
// the notary anonymity set is built from what this workflow publishes.
//
// WHAT CONSENSUS DOES NOT COVER. sec. 2.15a chose CRE over TLSNotary because
// `cre.ConsensusIdenticalAggregation` requires every DON node to produce a BYTE-IDENTICAL result.
// That protects against a rogue NODE. It does not protect against a PARSER THAT IS WRONG THE SAME
// WAY EVERYWHERE - every node agrees, and they agree on the wrong set. sec. 2.15a says as much
// ("scrapers rot"), and that is the part with no tests.
//
// THE DANGEROUS DIRECTION IS UNDER-COUNTING. A snapshot with EXTRA notaries would be caught by
// anyone comparing it against the public register. A snapshot MISSING real notaries silently removes
// their ability to act - censorship by parse error rather than by decision - and nobody downstream
// can tell the difference between "not a notary" and "the parser dropped you".
package main

import (
	"archive/zip"
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/crypto"
)

// The vocabulary these tests exercise. Kept as a constant so a future rename of the Ukrainian entry
// does not silently turn every test into a "no vocabulary declared" error that still passes.
const testRegistry = "UA_NOTARY_REGISTRY"

// Shaped exactly like the REAL export (sec. 2.18ce): DATA/RECORD, and an EMPTY <INFO> meaning the
// notary is operating. Copied from `17-ex_xml_wern.xml`, not invented.
const twoActiveNotaries = `<?xml version="1.0" encoding="UTF-8"?>
<DATA FORMAT_VERSION="1.0">
  <RECORD><REGION>Kyiv</REGION><NAME_OBJ>Office A</NAME_OBJ><CONTACTS>addr</CONTACTS><FIO>Jane Doe</FIO><LICENSE>123</LICENSE><INFO></INFO></RECORD>
  <RECORD><REGION>Lviv</REGION><NAME_OBJ>Office B</NAME_OBJ><CONTACTS>addr</CONTACTS><FIO>John Roe</FIO><LICENSE>456</LICENSE><INFO></INFO></RECORD>
</DATA>`

func TestParsesAPlainXmlExport(t *testing.T) {
	records, err := parseRegistryExport([]byte(twoActiveNotaries))
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("want 2 records, got %d", len(records))
	}
	if records[0].License != "123" || records[0].FullName != "Jane Doe" ||
		records[0].Region != "Kyiv" || records[0].Info != "" || records[0].Office != "Office A" {
		t.Fatalf("fields did not land in the right struct members: %+v", records[0])
	}
}

// An export served as a .zip must parse identically - open-data catalogs commonly zip bulk exports,
// and the two paths must not disagree about what the register says.
func TestParsesAZippedExportIdentically(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	f, err := zw.Create("registry.xml")
	if err != nil {
		t.Fatalf("build zip: %v", err)
	}
	if _, err := f.Write([]byte(twoActiveNotaries)); err != nil {
		t.Fatalf("write zip: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}

	zipped, err := parseRegistryExport(buf.Bytes())
	if err != nil {
		t.Fatalf("zipped parse failed: %v", err)
	}
	plain, err := parseRegistryExport([]byte(twoActiveNotaries))
	if err != nil {
		t.Fatalf("plain parse failed: %v", err)
	}

	zippedLeaves, err := activeLeaves(zipped, testRegistry)
	if err != nil {
		t.Fatalf("zipped active filter: %v", err)
	}
	plainLeaves, err := activeLeaves(plain, testRegistry)
	if err != nil {
		t.Fatalf("plain active filter: %v", err)
	}

	if merkleRoot(zippedLeaves) != merkleRoot(plainLeaves) {
		t.Fatal("the zipped and plain paths produced different roots for the same register")
	}
}

/*
 * SCHEMA ROT MUST FAIL LOUDLY, NOT QUIETLY.
 *
 * If the portal renames <record> or <registry>, Go's encoding/xml does NOT error - it returns zero
 * records, because unmarshalling into a struct simply finds nothing to fill. Every DON node would
 * do this identically and reach consensus on an empty register. The explicit zero-records check is
 * the only thing standing between a schema change and a published empty snapshot.
 */
func TestARenamedRecordElementIsRejectedRatherThanReturningNothing(t *testing.T) {
	renamed := `<DATA><NOTARY><LICENSE>1</LICENSE><INFO></INFO></NOTARY></DATA>`
	if _, err := parseRegistryExport([]byte(renamed)); err == nil {
		t.Fatal("a renamed record element parsed to zero records without an error - schema rot would be silent")
	}
}

func TestMalformedXmlIsRejected(t *testing.T) {
	if _, err := parseRegistryExport([]byte("<DATA><RECORD>")); err == nil {
		t.Fatal("truncated XML did not error")
	}
}

// A zip whose first entry is not the export (a README, a licence) must not be parsed as XML. The
// loop takes the FIRST non-directory file, so this pins what happens when that assumption breaks.
func TestAZipWhoseFirstEntryIsNotTheExportFailsRatherThanGuessing(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	readme, _ := zw.Create("README.txt")
	readme.Write([]byte("bulk export of the notary register"))
	xmlFile, _ := zw.Create("registry.xml")
	xmlFile.Write([]byte(twoActiveNotaries))
	zw.Close()

	if _, err := parseRegistryExport(buf.Bytes()); err == nil {
		t.Fatal("a README ahead of the export parsed as XML without complaint")
	}
}

// ── the active filter: where a silent under-count would come from ───────────────────────────

func TestOnlyActiveNotariesBecomeLeaves(t *testing.T) {
	records := []NotaryRecordXML{
		{License: "1", Info: ""},
		{License: "2", Info: "тимчасово не діє"},
		{License: "3", Info: "тимчасово не діє"},
		{License: "4", Info: ""},
	}
	leaves, err := activeLeaves(records, testRegistry)
	if err != nil {
		t.Fatalf("known statuses must not error: %v", err)
	}
	if len(leaves) != 2 {
		t.Fatalf("want 2 active leaves, got %d", len(leaves))
	}
}

/*
 * THE CENSORSHIP-BY-PARSE-ERROR CASE, NOW FIXED (sec. 2.18ao).
 *
 * The filter used to compare exactly against "active", so a migrated portal emitting "Active"
 * dropped those notaries with NO error. Statuses are now normalised, so the same register survives
 * a casing change.
 */
func TestAStatusCasingChangeNoLongerDropsNotaries(t *testing.T) {
	records := []NotaryRecordXML{
		{License: "1", Info: ""},
		{License: "2", Info: ""},
		{License: "3", Info: ""},
		{License: "4", Info: "   "},
	}
	leaves, err := activeLeaves(records, testRegistry)
	if err != nil {
		t.Fatalf("casing variants must not error: %v", err)
	}
	if len(leaves) != 4 {
		t.Fatalf("a casing change still drops notaries: want 4, got %d", len(leaves))
	}
}

/*
 * AND THE PART CASE-FOLDING ALONE WOULD NOT HAVE FIXED.
 *
 * If the register's vocabulary changes to something outside the known set - a Ukrainian-language
 * status, a new "inactive" - folding case admits nobody and the notary is silently omitted. That is
 * the same silent under-count in a different costume. An unknown status now REFUSES THE WHOLE
 * SNAPSHOT, so the failure is a visible outage a human fixes rather than a person quietly losing
 * the ability to act.
 */
func TestAnUnknownStatusRefusesTheSnapshotRatherThanOmittingTheNotary(t *testing.T) {
	records := []NotaryRecordXML{
		{License: "1", Info: ""},
		{License: "2", Info: "\u0434\u0456\u044e\u0447\u0438\u0439"}, // "diyuchyi" - Ukrainian for active
	}
	if _, err := activeLeaves(records, testRegistry); err == nil {
		t.Fatal("an unrecognised status was silently skipped - that is censorship by parse error")
	}
}

func TestKnownInactiveStatusesAreSkippedWithoutError(t *testing.T) {
	records := []NotaryRecordXML{
		{License: "1", Info: ""},
		{License: "2", Info: "тимчасово не діє"},
		{License: "3", Info: "ТИМЧАСОВО НЕ ДІЄ"},
	}
	leaves, err := activeLeaves(records, testRegistry)
	if err != nil {
		t.Fatalf("known inactive statuses must not error: %v", err)
	}
	if len(leaves) != 1 {
		t.Fatalf("want 1 active leaf, got %d", len(leaves))
	}
}

// ---- the Merkle root: it must agree with what the CONTRACT computes ------------------------

/*
 * THE ROOT IS ORDER-INDEPENDENT, which is what makes the workflow's output well-defined.
 *
 * `merkleRoot` sorts in place and hashes each pair in sorted order, so the register's own ordering
 * cannot change the answer. That matters because `RegistrySourceAnchor._computeRoot` recomputes the
 * root on-chain from the submitted leaves: if the two constructions disagreed about ordering, the
 * published root would not match the leaves that justify it.
 */
func TestTheRootDoesNotDependOnTheRegistersOrdering(t *testing.T) {
	a := [32]byte{1}
	b := [32]byte{2}
	c := [32]byte{3}

	forward := merkleRoot([][32]byte{a, b, c})
	backward := merkleRoot([][32]byte{c, b, a})
	shuffled := merkleRoot([][32]byte{b, a, c})

	if forward != backward || forward != shuffled {
		t.Fatal("the root depends on input order - the same register would publish different roots")
	}
}

func TestASingleLeafIsItsOwnRoot(t *testing.T) {
	only := [32]byte{7}
	if merkleRoot([][32]byte{only}) != only {
		t.Fatal("a one-notary register did not produce the leaf as its root")
	}
}

func TestAnEmptyRegisterProducesTheZeroRoot(t *testing.T) {
	if merkleRoot(nil) != ([32]byte{}) {
		t.Fatal("an empty leaf set did not produce the zero root")
	}
}

/*
 * CHANGING ANY FIELD CHANGES THE LEAF - the property the whole snapshot rests on.
 */
func TestEveryFieldIsBoundIntoTheLeaf(t *testing.T) {
	base := NotaryRecordXML{License: "123", FullName: "Jane Doe", Region: "Kyiv", Info: ""}
	h := leafHash(base)

	variants := map[string]NotaryRecordXML{
		"registration number": {License: "124", FullName: "Jane Doe", Region: "Kyiv", Info: ""},
		"full name":           {License: "123", FullName: "Jane Roe", Region: "Kyiv", Info: ""},
		"region":              {License: "123", FullName: "Jane Doe", Region: "Lviv", Info: ""},
		"status":              {License: "123", FullName: "Jane Doe", Region: "Kyiv", Info: "тимчасово не діє"},
	}
	for field, v := range variants {
		if leafHash(v) == h {
			t.Fatalf("changing the %s did not change the leaf", field)
		}
	}
}

/*
 * THE CONCATENATION AMBIGUITY, NOW FIXED (sec. 2.18ao).
 *
 * `leafHash` used to keccak the four fields concatenated with no separator, so reg "12" + name "3X"
 * hashed identically to reg "123" + name "X". Each field is now hashed first, making every part
 * fixed-width, so no boundary is ambiguous.
 */
func TestFieldsCannotBeReSplitAcrossTheRegNumberNameBoundary(t *testing.T) {
	left := NotaryRecordXML{License: "12", FullName: "3X", Region: "Kyiv", Info: ""}
	right := NotaryRecordXML{License: "123", FullName: "X", Region: "Kyiv", Info: ""}

	if leafHash(left) == leafHash(right) {
		t.Fatal("two different notaries still collide across the reg-number/name boundary")
	}
}

/*
 * THE SAME NOTARY LISTED TWICE MUST NOT BREAK THE SNAPSHOT (sec. 2.18ao).
 *
 * RegistrySourceAnchor requires STRICTLY ascending leaves, and sorting duplicates yields equal
 * neighbours rather than strict ascent - so one duplicated row upstream used to make the whole
 * country's snapshot unpublishable. A safe failure, but a liveness one.
 */
func TestDuplicateRecordsAreDeduplicated(t *testing.T) {
	dup := NotaryRecordXML{License: "1", FullName: "Jane", Region: "Kyiv", Info: ""}
	other := NotaryRecordXML{License: "2", FullName: "John", Region: "Lviv", Info: ""}

	leaves, err := activeLeaves([]NotaryRecordXML{dup, other, dup}, testRegistry)
	if err != nil {
		t.Fatalf("duplicates must not error: %v", err)
	}
	if len(leaves) != 2 {
		t.Fatalf("want 2 deduplicated leaves, got %d", len(leaves))
	}
}

/*
 * AND THE PROPERTY DEDUPLICATION EXISTS FOR: the submitted leaves must be STRICTLY ascending, which
 * is what the contract checks. Sorting alone does not give that when duplicates are present.
 */
func TestSubmittedLeavesAreStrictlyAscending(t *testing.T) {
	dup := NotaryRecordXML{License: "1", FullName: "Jane", Region: "Kyiv", Info: ""}
	records := []NotaryRecordXML{dup, dup,
		{License: "2", FullName: "John", Region: "Lviv", Info: ""},
		{License: "3", FullName: "Ann", Region: "Odesa", Info: ""},
	}
	leaves, err := activeLeaves(records, testRegistry)
	if err != nil {
		t.Fatalf("active filter: %v", err)
	}
	merkleRoot(leaves) // sorts in place, exactly as onSchedule relies on before submitting

	for i := 1; i < len(leaves); i++ {
		if bytes.Compare(leaves[i-1][:], leaves[i][:]) >= 0 {
			t.Fatalf("leaves are not strictly ascending at %d - RegistrySourceAnchor would reject the snapshot", i)
		}
	}
}

// ---- the translation layer ------------------------------------------------------------------

/*
 * A REGISTER WRITES STATUSES IN ITS OWN LANGUAGE, and the mapping to protocol meaning is declared
 * per jurisdiction (sec. 2.18ao). This proves the mechanism handles a non-Latin vocabulary - the
 * point being that Ukraine's and Iran's registers will not say "active", and assuming they do is
 * how notaries get silently dropped.
 *
 * NOTE WHAT IS NOT HERE: the REAL Ukrainian status strings. I do not know what the Ministry of
 * Justice register writes, and inventing plausible Cyrillic would be the sec. 2.18k fabrication -
 * a wrong mapping either admits nobody (loud) or assigns the wrong meaning (silent, and it decides
 * who may act). This test declares its OWN vocabulary to exercise the code path.
 */
func TestANonLatinVocabularyWorksOnceDeclared(t *testing.T) {
	const key = "TEST_CYRILLIC_REGISTRY"
	statusVocabularies[key] = map[string]statusMeaning{
		"\u0434\u0456\u044e\u0447\u0438\u0439":             meaningActive,
		"\u0437\u0443\u043f\u0438\u043d\u0435\u043d\u043e": meaningInactive,
	}
	defer delete(statusVocabularies, key)

	records := []NotaryRecordXML{
		{License: "1", Info: "\u0414\u0406\u042e\u0427\u0418\u0419"}, // upper case - must still fold
		{License: "2", Info: "\u0437\u0443\u043f\u0438\u043d\u0435\u043d\u043e"},
	}
	leaves, err := activeLeaves(records, key)
	if err != nil {
		t.Fatalf("a declared Cyrillic vocabulary must work: %v", err)
	}
	if len(leaves) != 1 {
		t.Fatalf("want 1 active leaf from the Cyrillic vocabulary, got %d", len(leaves))
	}
}

/*
 * AND A JURISDICTION WITH NO DECLARED VOCABULARY CANNOT PUBLISH AT ALL.
 *
 * This is the fail-closed property that makes the missing Ukrainian entries safe to leave missing:
 * an undeclared register refuses outright rather than publishing whatever happens to match English.
 */
func TestAnUndeclaredRegistryRefusesToPublish(t *testing.T) {
	records := []NotaryRecordXML{{License: "1", Info: ""}}
	if _, err := activeLeaves(records, "IR_NOTARY_REGISTRY"); err == nil {
		t.Fatal("an undeclared registry published using the English vocabulary by accident")
	}
}

// The on-chain registryId must follow the registry key, so a deployment cannot scrape one country's
// portal while publishing under another's identifier.
func TestTheRegistryIdFollowsTheRegistryKey(t *testing.T) {
	if registryIDFor("UA_NOTARY_REGISTRY") == registryIDFor("IR_NOTARY_REGISTRY") {
		t.Fatal("two registries share an on-chain identifier")
	}
}

// ---- Merkle proofs: the half that was missing ------------------------------------------------

// verifyLikeSolidity mirrors OpenZeppelin's MerkleProof.verify EXACTLY - fold the leaf with each
// sibling in sorted order and compare to the root.
//
// WRITTEN OUT INDEPENDENTLY rather than calling merkleProof/merkleRoot, so a shared misunderstanding
// cannot make the tests agree with the generator and both be wrong. The generator is checked against
// THIS, and this is checked against the real Solidity in NotaryRegistryProof.t.sol.
func verifyLikeSolidity(proof [][32]byte, root [32]byte, leaf [32]byte) bool {
	computed := leaf
	for _, sibling := range proof {
		if bytes.Compare(computed[:], sibling[:]) <= 0 {
			computed = crypto.Keccak256Hash(computed[:], sibling[:])
		} else {
			computed = crypto.Keccak256Hash(sibling[:], computed[:])
		}
	}
	return computed == root
}

// EVERY leaf must be provable, at every tree size. Odd sizes are where the promoted-node rule bites:
// a generator that appends a sibling for a promoted node produces proofs one element too long, and
// they fail with no diagnostic beyond "invalid".
func TestEveryLeafIsProvableAtEveryTreeSize(t *testing.T) {
	for size := 1; size <= 9; size++ {
		records := make([]NotaryRecordXML, 0, size)
		for i := 0; i < size; i++ {
			records = append(records, NotaryRecordXML{
				License: string(rune('A' + i)), FullName: "N", Region: "R", Info: "",
			})
		}
		leaves, err := activeLeaves(records, testRegistry)
		if err != nil {
			t.Fatalf("size %d: %v", size, err)
		}
		root := merkleRoot(append([][32]byte(nil), leaves...))

		for i, leaf := range leaves {
			proof, ok := merkleProof(leaves, leaf)
			if !ok {
				t.Fatalf("size %d leaf %d: no proof produced", size, i)
			}
			if !verifyLikeSolidity(proof, root, leaf) {
				t.Fatalf("size %d leaf %d: proof does not verify (len %d)", size, i, len(proof))
			}
		}
	}
}

// A leaf that is NOT in the snapshot must be reported absent, not given an empty proof. An empty
// path is legitimately valid for a single-leaf tree, so the two cases are only distinguishable by
// the boolean - conflating them would let a non-notary be admitted against a one-notary snapshot.
func TestAnAbsentLeafIsReportedAbsentRatherThanGivenAnEmptyProof(t *testing.T) {
	leaves, _ := activeLeaves([]NotaryRecordXML{
		{License: "1", Info: ""},
		{License: "2", Info: ""},
	}, testRegistry)

	if _, ok := merkleProof(leaves, [32]byte{0xFF}); ok {
		t.Fatal("a leaf outside the snapshot was given a proof")
	}
}

func TestASingleLeafProofIsEmptyAndValid(t *testing.T) {
	leaves, _ := activeLeaves([]NotaryRecordXML{{License: "1", Info: ""}}, testRegistry)
	root := merkleRoot(append([][32]byte(nil), leaves...))

	proof, ok := merkleProof(leaves, leaves[0])
	if !ok {
		t.Fatal("the only notary in the snapshot was not provable")
	}
	if len(proof) != 0 {
		t.Fatalf("a single-leaf proof should be empty, got %d elements", len(proof))
	}
	if !verifyLikeSolidity(proof, root, leaves[0]) {
		t.Fatal("the single-leaf proof does not verify")
	}
}

// merkleProof must not reorder the caller's slice. merkleRoot sorts IN PLACE and Go slices share
// their backing array, so a generator that did the same would silently permute whatever the caller
// still holds - including the leaves about to be submitted on-chain.
func TestGeneratingAProofDoesNotReorderTheCallersLeaves(t *testing.T) {
	leaves, _ := activeLeaves([]NotaryRecordXML{
		{License: "3", Info: ""},
		{License: "1", Info: ""},
		{License: "2", Info: ""},
	}, testRegistry)

	before := append([][32]byte(nil), leaves...)
	_, _ = merkleProof(leaves, leaves[0])

	for i := range before {
		if before[i] != leaves[i] {
			t.Fatal("merkleProof reordered the caller's slice")
		}
	}
}

/*
 * THE CROSS-LANGUAGE CHECK: emit a fixture the SOLIDITY side verifies.
 *
 * Everything above proves Go agrees with Go. The convention that actually matters - sorted pairs,
 * odd-node promotion - lives in OpenZeppelin's MerkleProof.verify, and a generator can be
 * self-consistent and still disagree with it. So this writes a real snapshot, root and proof to a
 * fixture that backend/contracts/test/title/NotaryRegistryProof.t.sol reads and checks with the
 * genuine library. If the two conventions ever diverge, that Forge test fails.
 *
 * Deliberately a TEST that writes a fixture rather than a committed generator binary: the fixture is
 * regenerated by `go test`, so it cannot drift from the code that produced it.
 */
func TestEmitSolidityCrossCheckFixture(t *testing.T) {
	records := []NotaryRecordXML{
		{License: "123", FullName: "Jane Doe", Region: "Kyiv", Info: ""},
		{License: "456", FullName: "John Roe", Region: "Lviv", Info: ""},
		{License: "789", FullName: "Ann Poe", Region: "Odesa", Info: ""},
		{License: "999", FullName: "Old Notary", Region: "Kyiv", Info: "тимчасово не діє"},
	}
	leaves, err := activeLeaves(records, testRegistry)
	if err != nil {
		t.Fatalf("active filter: %v", err)
	}
	root := merkleRoot(append([][32]byte(nil), leaves...))

	target := leafHash(records[0])
	proof, ok := merkleProof(leaves, target)
	if !ok {
		t.Fatal("the target notary was not provable in its own snapshot")
	}
	if !verifyLikeSolidity(proof, root, target) {
		t.Fatal("the fixture proof does not even verify in Go")
	}

	var b strings.Builder
	fmt.Fprintf(&b, "root %x\n", root)
	fmt.Fprintf(&b, "leaf %x\n", target)
	for _, p := range proof {
		fmt.Fprintf(&b, "proof %x\n", p)
	}
	out := "../../contracts/test/fixtures/notary_registry_proof.txt"
	if err := os.WriteFile(out, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	t.Logf("wrote %s (%d proof elements)", out, len(proof))
}
