// The first tests this workflow has ever had (TODO.md sec. 3, GAP 1).
//
// WHY THIS FILE EXISTS. `backend/cre/sanctions_lists` decides WHO IS RECORDED AS SANCTIONED, and it
// had no tests at all — everything lived in `main.go` behind `//go:build wasip1`, so no ordinary
// `go test` could reach any of it. That is the same shape `notary_registry` was in, fixed the same
// way.
//
// AND IT WAS NOT MERELY UNTESTED. The workflow could never have published anything: it sorted its
// ENTRIES by uid and then mapped them to leaf HASHES, which are in no particular order, while
// `RegistrySourceAnchor._computeRoot` reverts `LeavesNotStrictlySorted` on anything but strict
// ascent. Every `onReport` would have reverted. Zero tests is how that survived being written,
// reviewed and marked "compiling".
//
// THE FIXTURES ARE REAL BYTES. `testdata/*.xml` are verbatim excerpts of the actual published
// exports, fetched 2026-08-02 — headers, namespaces, element casing, empty elements and all.
// Nothing here is a hand-written approximation of a schema, because the last time this project
// guessed one, every single tag was wrong and the parse returned zero rows (sec. 2.18ce).
package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func load(t *testing.T, name string) []byte {
	t.Helper()
	body, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return body
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED STATES — OFAC SDN
// ═══════════════════════════════════════════════════════════════════

func TestTheUSExportDecodesWithItsKindsAndNameParts(t *testing.T) {
	subjects, err := decodeSubjects("OFAC_SDN", load(t, "ofac_sdn_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(subjects) != 7 {
		t.Fatalf("want 7 rows, got %d", len(subjects))
	}

	// An entity: lastName carries the whole name, firstName is absent — and the empty part is still
	// committed, so arity is the same as an individual's.
	if subjects[0].Reference != "7728" || subjects[0].Kind != KindEntity {
		t.Fatalf("entity row wrong: %+v", subjects[0])
	}
	if got := subjects[0].NameParts; len(got) != 2 || got[0] != "MANCO OIL COMPANY" || got[1] != "" {
		t.Fatalf("entity name parts wrong: %q", got)
	}

	// An individual: both parts populated, in published order (last, first). The reference is the
	// entry's OWN uid — aka, address and id blocks nested inside an sdnEntry carry `uid` elements
	// too, and a decoder that reached into them would key leaves on an alias's identifier.
	if subjects[2].Reference != "7741" || subjects[2].Kind != KindIndividual {
		t.Fatalf("individual row wrong: %+v", subjects[2])
	}
	if got := subjects[2].NameParts; got[0] != "MILOSEVIC" || got[1] != "Milanka" {
		t.Fatalf("individual name parts wrong: %q", got)
	}

	// The kind vocabulary covers all four types OFAC publishes, not just the two people expect.
	if subjects[5].Kind != KindVessel || subjects[6].Kind != KindAircraft {
		t.Fatalf("vessel/aircraft rows wrong: %+v %+v", subjects[5], subjects[6])
	}
}

// THE EXPORT DECLARES ITS OWN LENGTH, and that is the strongest anti-rot guard available: a schema
// change that silently drops rows is caught without any external reference point. Under-counting is
// the dangerous direction — a snapshot missing designated parties still looks complete.
func TestAUSManifestMismatchIsRefused(t *testing.T) {
	body := string(load(t, "ofac_sdn_excerpt.xml"))
	tampered := strings.Replace(body, "<Record_Count>7</Record_Count>", "<Record_Count>8</Record_Count>", 1)
	if tampered == body {
		t.Fatal("fixture no longer contains the Record_Count this test tampers with")
	}

	_, err := decodeSubjects("OFAC_SDN", []byte(tampered))
	if err == nil {
		t.Fatal("a snapshot disagreeing with its own manifest was accepted")
	}
	if !strings.Contains(err.Error(), "Record_Count") {
		t.Fatalf("error does not name the manifest: %v", err)
	}
}

// A FIFTH sdnType is how a silent under-count arrives. Defaulting an unknown kind to "entity" would
// publish a plausible, wrong snapshot; refusing publishes nothing and says why.
func TestAnUnknownUSSubjectTypeRefusesTheSnapshot(t *testing.T) {
	body := strings.Replace(string(load(t, "ofac_sdn_excerpt.xml")),
		"<sdnType>Vessel</sdnType>", "<sdnType>Spacecraft</sdnType>", 1)

	_, err := decodeSubjects("OFAC_SDN", []byte(body))
	if err == nil {
		t.Fatal("an undeclared sdnType was silently accepted")
	}
	if !strings.Contains(err.Error(), "Spacecraft") {
		t.Fatalf("error does not name the unknown type: %v", err)
	}
}

// The US export declares its reference unique (measured: 19,181 uids, all distinct). If that ever
// stops holding, two designations would merge into one leaf — so it is CHECKED, not trusted.
func TestADuplicateUSReferenceIsRefusedBecauseTheSourceDeclaresItUnique(t *testing.T) {
	body := `<?xml version="1.0" standalone="yes"?>
<sdnList xmlns="https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/XML">
  <publshInformation><Publish_Date>07/30/2026</Publish_Date><Record_Count>2</Record_Count></publshInformation>
  <sdnEntry><uid>36</uid><lastName>ONE</lastName><sdnType>Entity</sdnType></sdnEntry>
  <sdnEntry><uid>36</uid><lastName>TWO</lastName><sdnType>Entity</sdnType></sdnEntry>
</sdnList>`

	_, err := decodeSubjects("OFAC_SDN", []byte(body))
	if err == nil {
		t.Fatal("a duplicated uid was accepted by a source that declares uid unique")
	}
	if !strings.Contains(err.Error(), "unique") {
		t.Fatalf("error does not explain the broken uniqueness claim: %v", err)
	}
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED KINGDOM — OFSI consolidated list
// ═══════════════════════════════════════════════════════════════════

// THE TEST THAT JUSTIFIES THE WHOLE REDESIGN. OFSI publishes ONE ROW PER ALIAS, so a single
// designation appears several times under one identifier — 19,761 rows carry 5,135 distinct ones.
// A design keyed on "reference identifies a row", which the US export happens to satisfy, silently
// collapses three quarters of the UK list into a quarter of the leaves.
func TestUKAliasRowsShareOneReferenceAndStillProduceDistinctLeaves(t *testing.T) {
	subjects, err := decodeSubjects("UK_OFSI_CONSOLIDATED", load(t, "uk_ofsi_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(subjects) != 4 {
		t.Fatalf("want 4 rows, got %d", len(subjects))
	}

	// GroupID 8384 is UKSanctionsListRef IRQ0140 in the published file; the leaf follows the
	// GroupID, because that is the field the real export always populates.
	shared := 0
	for _, s := range subjects {
		if s.Reference == "8384" {
			shared++
		}
	}
	if shared != 3 {
		t.Fatalf("want 3 rows under IRQ0140, got %d", shared)
	}

	leaves := snapshotLeaves("UK_OFSI_CONSOLIDATED", subjects)
	if len(leaves) != 4 {
		t.Fatalf("three alias rows collapsed into one leaf: %d leaves from 4 rows", len(leaves))
	}

	// And the reason they stay distinct is the FULL six-part name, empties included: OFSI moves a
	// name between slots across alias rows of one designation, and dropping empties would make
	// "Rudi" in slot 1 and "Rudi" in slot 2 hash identically.
	if got := subjects[2].NameParts; len(got) != 6 || got[0] != "Rudi" || got[1] != "Untaywan" || got[5] != "Slaywah" {
		t.Fatalf("UK name parts wrong: %q", got)
	}
}

func TestTheUKShipTypeMapsToVessel(t *testing.T) {
	subjects, err := decodeSubjects("UK_OFSI_CONSOLIDATED", load(t, "uk_ofsi_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if subjects[3].Kind != KindVessel {
		t.Fatalf("OFSI 'Ship' did not map to the shared vessel kind: %+v", subjects[3])
	}
}

// REPRODUCES THE ONE ROW IN 19,761 THAT DECIDED THE UK KEY. Alexander SAMOFAL, designated
// 2023-04-21 under Global Human Rights, is published with an EMPTY `UKSanctionsListRef`. Keyed on
// that field, he is unanchorable — and because a row with no reference is refused outright, he takes
// the whole UK snapshot down with him. Keyed on `GroupID`, which the export always populates, the
// list publishes and he is in it.
func TestAUKRowWithNoFcdoReferenceStillAnchors(t *testing.T) {
	body := strings.Replace(string(load(t, "uk_ofsi_excerpt.xml")),
		"<UKSanctionsListRef>DPR0096</UKSanctionsListRef>",
		"<UKSanctionsListRef></UKSanctionsListRef>", 1)
	if body == string(load(t, "uk_ofsi_excerpt.xml")) {
		t.Fatal("fixture no longer contains the reference this test blanks")
	}

	subjects, err := decodeSubjects("UK_OFSI_CONSOLIDATED", []byte(body))
	if err != nil {
		t.Fatalf("a real designation was dropped for having no FCDO reference: %v", err)
	}
	if len(subjects) != 4 {
		t.Fatalf("want 4 rows, got %d", len(subjects))
	}
	if _, err := merkleRoot(snapshotLeaves("UK_OFSI_CONSOLIDATED", subjects)); err != nil {
		t.Fatalf("root: %v", err)
	}
}

func TestAnUnknownUKGroupTypeRefusesTheSnapshot(t *testing.T) {
	body := strings.Replace(string(load(t, "uk_ofsi_excerpt.xml")),
		"<GroupTypeDescription>Ship</GroupTypeDescription>",
		"<GroupTypeDescription>Aircraft</GroupTypeDescription>", 1)

	_, err := decodeSubjects("UK_OFSI_CONSOLIDATED", []byte(body))
	if err == nil {
		t.Fatal("an undeclared GroupTypeDescription was silently accepted")
	}
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED NATIONS — Security Council consolidated list
// ═══════════════════════════════════════════════════════════════════

// A THIRD WAY OF ENCODING SUBJECT KIND: the UN carries it STRUCTURALLY, in which container a row
// sits, with no field on the row saying so. OFAC uses a field, OFSI uses a differently-named field.
// That is why a decoder is a function per source and not a field-mapping table.
func TestTheUNKindComesFromTheContainerNotAField(t *testing.T) {
	subjects, err := decodeSubjects("UN_SC_CONSOLIDATED", load(t, "un_sc_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(subjects) != 3 {
		t.Fatalf("want 3 rows, got %d", len(subjects))
	}
	if subjects[0].Kind != KindIndividual || subjects[1].Kind != KindIndividual {
		t.Fatalf("individuals misclassified: %+v %+v", subjects[0], subjects[1])
	}
	if subjects[2].Kind != KindEntity {
		t.Fatalf("entity misclassified: %+v", subjects[2])
	}
	if subjects[0].Reference != "6909475" || subjects[0].NameParts[0] != "KEMPES" {
		t.Fatalf("individual fields wrong: %+v", subjects[0])
	}
	// An entity's name arrives in FIRST_NAME with the remaining parts empty — same arity as an
	// individual, so the shapes cannot collide even before the kind is hashed in.
	if got := subjects[2].NameParts; len(got) != 4 || got[0] != "GHORB NOOH" || got[1] != "" {
		t.Fatalf("entity name parts wrong: %q", got)
	}
}

// ═══════════════════════════════════════════════════════════════════
//  The declaration itself
// ═══════════════════════════════════════════════════════════════════

func TestAnUndeclaredRegistryRefusesToPublish(t *testing.T) {
	if _, err := sourceFor("EU_CFSP_CONSOLIDATED"); err == nil {
		t.Fatal("an undeclared registry was allowed to publish")
	}
	if _, err := decodeSubjects("EU_CFSP_CONSOLIDATED", load(t, "ofac_sdn_excerpt.xml")); err == nil {
		t.Fatal("an undeclared registry decoded a body it has no schema for")
	}
}

// Every entry must answer sec. 2.18cb's questions. A list anchored without declaring what its
// ABSENCES mean silently gives the weaker guarantee everywhere, because a jurisdiction whose
// register expresses removal by absence cannot support proof-bound revocation at all.
func TestEveryDeclaredSourceAnswersTheSemanticsQuestions(t *testing.T) {
	if len(sources) == 0 {
		t.Fatal("no sources declared at all")
	}
	for key, spec := range sources {
		if spec.Key != key {
			t.Errorf("%s: spec.Key is %q — the map key and the hashed registry key must not diverge", key, spec.Key)
		}
		if _, err := sourceFor(key); err != nil {
			t.Errorf("%s: declared but not publishable: %v", key, err)
		}
		if spec.PublishedAt == "" {
			t.Errorf("%s: no published-at URL recorded, so nothing can be compared against config", key)
		}
	}
}

// ═══════════════════════════════════════════════════════════════════
//  The declarative machinery — what replaced the compiler's checking
// ═══════════════════════════════════════════════════════════════════

// THE BEHAVIOUR LOCK. These roots were computed BEFORE the per-country decoders were replaced by
// one declarative walker, and they are unchanged after it — which is the only way to claim that
// refactor preserved behaviour rather than merely still passing its own tests. The fixtures are
// fixed bytes, so these values are deterministic forever; if one moves, decoding changed, and the
// question is what changed rather than what to update.
func TestTheExcerptRootsAreUnchangedByRefactoring(t *testing.T) {
	for _, tc := range []struct{ key, file, root string }{
		{"OFAC_SDN", "ofac_sdn_excerpt.xml",
			"f7fa85f6dd7490414be1e5872940ec2cb73c3553c8025971c12a21fc95aec156"},
		{"UK_OFSI_CONSOLIDATED", "uk_ofsi_excerpt.xml",
			"56fcf533b4fd74a0031a171e2656d3e2c4450ad1465a2724d4c298cf4e623bb3"},
		{"UN_SC_CONSOLIDATED", "un_sc_excerpt.xml",
			"731b6d03a4e695a1890a5a2123e1735704b097cd231df6a72bdbe1f842df7fce"},
	} {
		subjects, err := decodeSubjects(tc.key, load(t, tc.file))
		if err != nil {
			t.Fatalf("%s decode: %v", tc.key, err)
		}
		root, err := merkleRoot(snapshotLeaves(tc.key, subjects))
		if err != nil {
			t.Fatalf("%s root: %v", tc.key, err)
		}
		if got := fmt.Sprintf("%x", root); got != tc.root {
			t.Fatalf("%s root moved:\n  was %s\n  now %s", tc.key, tc.root, got)
		}
	}
}

// THE CLAIM THE DECLARATIVE SHAPE MAKES IS THAT A NEW COUNTRY IS DATA, NOT CODE — so this adds one
// and writes no code to do it. The register below is INVENTED, deliberately: it tests the
// MECHANISM, and nothing invented is ever added to `sources`, because a fabricated register is
// exactly the fabrication sec. 2.18k forbids.
//
// It is shaped to share nothing with the three declared sources — rows in two containers three deep
// under a different root, a non-English kind vocabulary, three name parts, no manifest, and a
// reference that repeats — and it decodes, hashes and roots on the same walker.
func TestAFourthRegisterNeedsNoNewCode(t *testing.T) {
	invented := SourceSpec{
		Key: "TEST_ONLY_INVENTED_REGISTER",
		Records: []RecordSet{
			{Path: "registre/personnes/personne", Kind: KindIndividual},
			{Path: "registre/navires/navire", KindField: "categorie"},
		},
		ReferenceField: "identifiant",
		NameFields:     []string{"nom", "prenom", "autre"},
		KindVocabulary: map[string]SubjectKind{"navire": KindVessel},
		AlwaysPresent:  []string{"identifiant", "nom"},
		Listing:        membershipMeansListed,
		Authenticity:   authenticityTransportOnly,
		PublishedAt:    "https://example.invalid/registre.xml",
	}
	if err := invented.validate(); err != nil {
		t.Fatalf("a complete declaration was rejected: %v", err)
	}

	body := []byte(`<?xml version="1.0"?>
<registre>
  <personnes>
    <personne><identifiant>A-1</identifiant><nom>DUPONT</nom><prenom>Marie</prenom></personne>
    <personne><identifiant>A-1</identifiant><nom>DUPONT</nom><prenom>Marie-Claire</prenom></personne>
  </personnes>
  <navires>
    <navire><identifiant>N-9</identifiant><nom>ETOILE</nom><categorie>navire</categorie></navire>
  </navires>
</registre>`)

	subjects, err := decodeXML(invented, body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(subjects) != 3 {
		t.Fatalf("want 3 rows, got %d", len(subjects))
	}
	if subjects[0].Kind != KindIndividual || subjects[2].Kind != KindVessel {
		t.Fatalf("kinds wrong: %+v %+v", subjects[0], subjects[2])
	}
	// Two rows share a reference, as OFSI's do, and stay distinct on their names.
	if subjects[0].Reference != subjects[1].Reference {
		t.Fatal("the fixture no longer exercises a shared reference")
	}
	leaves := snapshotLeaves(invented.Key, subjects)
	if len(leaves) != 3 {
		t.Fatalf("want 3 leaves, got %d", len(leaves))
	}
	if _, err := merkleRoot(leaves); err != nil {
		t.Fatalf("root: %v", err)
	}

	// And every fail-closed rule applies to it with no per-source code to carry them.
	undeclaredKind := []byte(`<registre><navires><navire><identifiant>N-9</identifiant>` +
		`<nom>ETOILE</nom><categorie>sous-marin</categorie></navire></navires></registre>`)
	if _, err := decodeXML(invented, undeclaredKind); err == nil {
		t.Fatal("an undeclared kind was accepted for the new register")
	}
	missingName := []byte(`<registre><personnes><personne><identifiant>A-1</identifiant>` +
		`<prenom>Marie</prenom></personne></personnes></registre>`)
	if _, err := decodeXML(invented, missingName); err == nil {
		t.Fatal("a row missing an always-present element was accepted for the new register")
	}
}

// A DECLARED PATH IS A STRING, SO THE COMPILER NO LONGER CHECKS IT. `validate` is what buys that
// back, and it must fire on the incomplete declaration rather than halfway through a real export.
func TestAnIncompleteSourceDeclarationIsRefused(t *testing.T) {
	complete := sources["OFAC_SDN"]

	for name, spec := range map[string]SourceSpec{
		"no record sets":  {Key: "X", ReferenceField: "uid", NameFields: []string{"n"}, Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"kind undecided":  {Key: "X", Records: []RecordSet{{Path: "a/b"}}, ReferenceField: "uid", NameFields: []string{"n"}, Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"kind twice over": {Key: "X", Records: []RecordSet{{Path: "a/b", Kind: KindEntity, KindField: "t"}}, ReferenceField: "uid", NameFields: []string{"n"}, Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"no vocabulary":   {Key: "X", Records: []RecordSet{{Path: "a/b", KindField: "t"}}, ReferenceField: "uid", NameFields: []string{"n"}, Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"no reference":    {Key: "X", Records: []RecordSet{{Path: "a/b", Kind: KindEntity}}, NameFields: []string{"n"}, Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"no name fields":  {Key: "X", Records: []RecordSet{{Path: "a/b", Kind: KindEntity}}, ReferenceField: "uid", Listing: membershipMeansListed, Authenticity: authenticityTransportOnly},
		"no semantics":    {Key: "X", Records: []RecordSet{{Path: "a/b", Kind: KindEntity}}, ReferenceField: "uid", NameFields: []string{"n"}},
		"no authenticity": {Key: "X", Records: []RecordSet{{Path: "a/b", Kind: KindEntity}}, ReferenceField: "uid", NameFields: []string{"n"}, Listing: membershipMeansListed},
	} {
		if err := spec.validate(); err == nil {
			t.Errorf("a spec with %s was accepted", name)
		}
	}

	if err := complete.validate(); err != nil {
		t.Fatalf("a real declaration was rejected: %v", err)
	}
}

// THE CHECK STRUCT TAGS NEVER GAVE. An unmatched `xml:"..."` tag yields "" in silence, so a renamed
// element used to fill every row with empty names and publish a plausible, wrong snapshot. Here the
// rows still decode — the reference, the kind and the manifest all still line up — and the snapshot
// is refused anyway, on the strength of one element having vanished from a row.
//
// PER ROW, NOT PER DOCUMENT. The first version of this guard asked whether an element appeared
// ANYWHERE, and refused three valid documents: `firstName` is on 7,473 of 19,181 US rows and
// `SECOND_NAME` on 727 of 736 UN individuals, so optional elements are legitimately absent from any
// small excerpt. Only elements measured on EVERY row of the real export are required.
func TestARenamedNameElementRefusesTheSnapshotRatherThanEmptyingIt(t *testing.T) {
	body := strings.ReplaceAll(string(load(t, "ofac_sdn_excerpt.xml")), "lastName>", "surname>")

	_, err := decodeSubjects("OFAC_SDN", []byte(body))
	if err == nil {
		t.Fatal("a renamed name element decoded to empty names and was accepted")
	}
	if !strings.Contains(err.Error(), "lastName") {
		t.Fatalf("error does not name the missing element: %v", err)
	}
}

// ONLY DIRECT CHILDREN. An sdnEntry nests `<uid>` inside akaList, addressList and idList, so a
// walker taking any descendant would key the leaf on whichever alias came last. The excerpt really
// does contain those nested uids — this is a property of the published file, not of a contrived
// fixture.
func TestNestedIdentifiersAreNotMistakenForTheRowsOwn(t *testing.T) {
	raw := string(load(t, "ofac_sdn_excerpt.xml"))
	if !strings.Contains(raw, "<akaList>") && !strings.Contains(raw, "<idList>") {
		t.Skip("the excerpt no longer contains a nested identifier to be confused by")
	}

	subjects, err := decodeSubjects("OFAC_SDN", []byte(raw))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, s := range subjects {
		if !strings.Contains(raw, "<sdnEntry>\n    <uid>"+s.Reference+"</uid>") {
			t.Fatalf("reference %q is not an entry's own uid - a nested identifier leaked into the leaf", s.Reference)
		}
	}
}

func TestTheRegistryIdFollowsTheRegistryKey(t *testing.T) {
	if registryIDFor("OFAC_SDN") == registryIDFor("UK_OFSI_CONSOLIDATED") {
		t.Fatal("two registries hash to one id")
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Leaves — the unambiguity rules
// ═══════════════════════════════════════════════════════════════════

// A BARE CONCATENATION IS RE-SPLITTABLE, which is what this workflow shipped with
// (`uid + "|" + name + "|" + type`). Reference "12" with name "3X" must not hash like reference
// "123" with name "X". Hashing each component to a fixed 32 bytes removes the boundary entirely and
// stops any delimiter from having to be forbidden inside a name.
func TestFieldsCannotBeReSplitAcrossTheReferenceNameBoundary(t *testing.T) {
	a := leafHash("OFAC_SDN", ListedSubject{Reference: "12", Kind: KindEntity, NameParts: []string{"3X"}})
	b := leafHash("OFAC_SDN", ListedSubject{Reference: "123", Kind: KindEntity, NameParts: []string{"X"}})
	if a == b {
		t.Fatal("a field boundary can be moved without changing the leaf")
	}
}

// Arity varies BY SOURCE — two US parts, six UK, four UN. Padding one shape with empties must not
// reach another's leaf, so the part COUNT is committed alongside the parts.
func TestThePartCountIsCommitted(t *testing.T) {
	a := leafHash("OFAC_SDN", ListedSubject{Reference: "1", Kind: KindEntity, NameParts: []string{"A"}})
	b := leafHash("OFAC_SDN", ListedSubject{Reference: "1", Kind: KindEntity, NameParts: []string{"A", ""}})
	if a == b {
		t.Fatal("a trailing empty name part is invisible to the leaf")
	}
}

// WITHOUT THE REGISTRY KEY IN THE LEAF, a UK row and a US row describing the same subject hash
// identically — and a proof against the UK root would satisfy a check written against the US one.
// Different lists, different law, different consequences.
func TestTheSameSubjectInTwoRegistriesGetsDifferentLeaves(t *testing.T) {
	s := ListedSubject{Reference: "X1", Kind: KindIndividual, NameParts: []string{"SMITH", "John"}}
	if leafHash("OFAC_SDN", s) == leafHash("UK_OFSI_CONSOLIDATED", s) {
		t.Fatal("a leaf can be replayed from one sanctions list as proof of listing on another")
	}
}

func TestTheKindIsCommitted(t *testing.T) {
	a := ListedSubject{Reference: "1", Kind: KindIndividual, NameParts: []string{"A"}}
	b := ListedSubject{Reference: "1", Kind: KindVessel, NameParts: []string{"A"}}
	if leafHash("OFAC_SDN", a) == leafHash("OFAC_SDN", b) {
		t.Fatal("an individual and a vessel with one name produce one leaf")
	}
}

// ═══════════════════════════════════════════════════════════════════
//  What gets submitted — the contract's own rule, enforced here
// ═══════════════════════════════════════════════════════════════════

// THE DEFECT THIS SUITE WAS WRITTEN FOR. Leaves must be strictly ascending or
// `RegistrySourceAnchor._computeRoot` reverts, so this is not tidiness: unsorted output is a
// workflow that can never publish at all.
func TestSubmittedLeavesAreStrictlyAscendingForEverySource(t *testing.T) {
	for _, tc := range []struct{ key, file string }{
		{"OFAC_SDN", "ofac_sdn_excerpt.xml"},
		{"UK_OFSI_CONSOLIDATED", "uk_ofsi_excerpt.xml"},
		{"UN_SC_CONSOLIDATED", "un_sc_excerpt.xml"},
	} {
		subjects, err := decodeSubjects(tc.key, load(t, tc.file))
		if err != nil {
			t.Fatalf("%s decode: %v", tc.key, err)
		}
		leaves := snapshotLeaves(tc.key, subjects)
		for i := 1; i < len(leaves); i++ {
			if !bytesLess(leaves[i-1], leaves[i]) {
				t.Fatalf("%s leaf %d is not greater than its predecessor", tc.key, i)
			}
		}
		if _, err := merkleRoot(leaves); err != nil {
			t.Fatalf("%s root: %v", tc.key, err)
		}
	}
}

// Replays the original bug directly: leaves in row order rather than hash order.
func TestTheRootBuilderRejectsUnsortedLeavesRatherThanComputingOne(t *testing.T) {
	subjects, err := decodeSubjects("OFAC_SDN", load(t, "ofac_sdn_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	rowOrder := make([][32]byte, 0, len(subjects))
	for _, s := range subjects {
		rowOrder = append(rowOrder, leafHash("OFAC_SDN", s))
	}

	sorted := snapshotLeaves("OFAC_SDN", subjects)
	same := len(rowOrder) == len(sorted)
	for i := range rowOrder {
		if same && rowOrder[i] != sorted[i] {
			same = false
		}
	}
	if same {
		t.Skip("this fixture's rows happen to be in hash order; the ordering bug is not observable here")
	}

	if _, err := merkleRoot(rowOrder); err == nil {
		t.Fatal("row-ordered leaves produced a root; the contract would have reverted on them")
	}
}

func TestEqualNeighboursAreRejectedBecauseTheContractRequiresStrictAscent(t *testing.T) {
	leaf := leafHash("OFAC_SDN", ListedSubject{Reference: "1", Kind: KindEntity, NameParts: []string{"A"}})
	if _, err := merkleRoot([][32]byte{leaf, leaf}); err == nil {
		t.Fatal("duplicate neighbours were accepted")
	}
}

// One duplicated row upstream must not make a whole country's snapshot unpublishable — a liveness
// failure over somebody else's data-entry slip.
func TestDuplicateRowsAreDeduplicated(t *testing.T) {
	s := ListedSubject{Reference: "1", Kind: KindEntity, NameParts: []string{"A"}}
	leaves := snapshotLeaves("OFAC_SDN", []ListedSubject{s, s, s})
	if len(leaves) != 1 {
		t.Fatalf("want 1 leaf from 3 identical rows, got %d", len(leaves))
	}
	if _, err := merkleRoot(leaves); err != nil {
		t.Fatalf("root: %v", err)
	}
}

func TestTheRootDoesNotDependOnRowOrder(t *testing.T) {
	subjects, err := decodeSubjects("UK_OFSI_CONSOLIDATED", load(t, "uk_ofsi_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	forward, err := merkleRoot(snapshotLeaves("UK_OFSI_CONSOLIDATED", subjects))
	if err != nil {
		t.Fatalf("root: %v", err)
	}

	reversed := make([]ListedSubject, len(subjects))
	for i, s := range subjects {
		reversed[len(subjects)-1-i] = s
	}
	backward, err := merkleRoot(snapshotLeaves("UK_OFSI_CONSOLIDATED", reversed))
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	if forward != backward {
		t.Fatal("the root depends on the order the register happened to publish its rows in")
	}
}

func TestASingleLeafIsItsOwnRoot(t *testing.T) {
	leaf := leafHash("OFAC_SDN", ListedSubject{Reference: "1", Kind: KindEntity, NameParts: []string{"A"}})
	root, err := merkleRoot([][32]byte{leaf})
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	if root != leaf {
		t.Fatal("a one-leaf tree hashed its only leaf instead of promoting it")
	}
}

// An empty parse is far more likely to be schema drift than a genuinely empty sanctions list, and
// publishing an empty root would silently clear the anchored set.
func TestAnEmptyDecodeIsRefusedRatherThanPublished(t *testing.T) {
	empty := `<?xml version="1.0" standalone="yes"?>
<sdnList xmlns="https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/XML">
  <publshInformation><Publish_Date>07/30/2026</Publish_Date><Record_Count>0</Record_Count></publshInformation>
</sdnList>`
	if _, err := decodeSubjects("OFAC_SDN", []byte(empty)); err == nil {
		t.Fatal("an empty snapshot was accepted")
	}
	if _, err := merkleRoot(nil); err == nil {
		t.Fatal("an empty leaf set produced a root")
	}
}

func TestMalformedXmlIsRefused(t *testing.T) {
	if _, err := decodeSubjects("OFAC_SDN", []byte("<sdnList><sdnEntry>")); err == nil {
		t.Fatal("truncated XML was accepted")
	}
}

// A RENAMED ELEMENT MUST NOT DECODE TO NOTHING QUIETLY. This is how `notary_registry`'s guessed
// schema failed — zero rows, no error — and the only reason it was caught is that an empty result
// is refused.
func TestARenamedElementIsRefusedRatherThanReturningNothing(t *testing.T) {
	body := strings.ReplaceAll(string(load(t, "un_sc_excerpt.xml")), "INDIVIDUAL>", "PERSON>")
	body = strings.ReplaceAll(body, "ENTITY>", "ORGANISATION>")
	if _, err := decodeSubjects("UN_SC_CONSOLIDATED", []byte(body)); err == nil {
		t.Fatal("a renamed schema decoded to zero rows and was accepted")
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Cross-language: Go must agree with Solidity, not only with itself
// ═══════════════════════════════════════════════════════════════════

/*
 * Everything above proves Go agrees with Go. The convention that actually matters — strict ascent,
 * sorted pairs at every internal node, odd node PROMOTED rather than hashed with itself — lives in
 * `RegistrySourceAnchor._computeRoot`, and a builder can be perfectly self-consistent and still
 * disagree with it. The disagreement is silent on this side and surfaces as a revert at publish
 * time, with nothing pointing back here.
 *
 * So this writes a real snapshot to a fixture that
 * `backend/contracts/test/registry/RegistrySourceAnchor.t.sol` publishes through the actual
 * contract, which recomputes the root from the same leaves and must reach the same value.
 *
 * Deliberately a TEST that writes a fixture rather than a committed generator: the fixture is
 * regenerated by `go test`, so it cannot drift from the code that produced it.
 *
 * AND THE FIXTURE MUST BE NON-DEGENERATE, WHICH IS NOT AUTOMATIC. The first version of it held four
 * designations, and a cross-check built on it was worthless: with leaves already ascending, the
 * sorted-pair rule is a no-op at the first level, four leaves never produce an odd level so nothing
 * is ever PROMOTED, and the one remaining pair happened to be in order too. Deleting the pair
 * sorting from the Go builder entirely left the Forge test still passing - caught by mutation, not
 * by reading. `assertExercisesBothMerkleRules` below is what stops that recurring: the fixture now
 * fails to generate unless its tree exercises both conventions it exists to pin.
 */
func TestEmitSolidityCrossCheckFixture(t *testing.T) {
	const key = "OFAC_SDN"
	subjects, err := decodeSubjects(key, load(t, "ofac_sdn_excerpt.xml"))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	leaves := snapshotLeaves(key, subjects)
	root, err := merkleRoot(leaves)
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	assertExercisesBothMerkleRules(t, leaves)

	registryID := registryIDFor(key)
	var b strings.Builder
	fmt.Fprintf(&b, "registryId %x\n", registryID)
	fmt.Fprintf(&b, "root %x\n", root)
	for _, l := range leaves {
		fmt.Fprintf(&b, "leaf %x\n", l)
	}

	out := "../../contracts/test/fixtures/sanctions_snapshot.txt"
	if err := os.WriteFile(out, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	t.Logf("wrote %s (%d leaves)", out, len(leaves))
}

// assertExercisesBothMerkleRules walks the tree the fixture will produce and requires it to depend
// on BOTH conventions the cross-check exists to pin. A tree that depends on neither cannot detect a
// divergence in either, however green it looks.
//
//	SORTED PAIRS  - some internal node must receive its children out of order, so that swapping the
//	                hash inputs would change the root. Ascending leaves make level one a no-op, so
//	                this can only ever come from a deeper level.
//	CARRY-UP      - some level must have odd length above 1, so an unpaired node is PROMOTED rather
//	                than hashed with itself. A power-of-two leaf count never produces one.
//
// Both are properties of WHICH ROWS the excerpt holds, so this fails at generation time with an
// instruction rather than silently emitting a fixture that proves nothing.
func assertExercisesBothMerkleRules(t *testing.T, leaves [][32]byte) {
	t.Helper()

	var sawUnorderedPair, sawCarryUp bool
	level := make([][32]byte, len(leaves))
	copy(level, leaves)

	for len(level) > 1 {
		if len(level)%2 == 1 {
			sawCarryUp = true
		}
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i])
				continue
			}
			if bytesLess(level[i+1], level[i]) {
				sawUnorderedPair = true
			}
			next = append(next, hashSortedPair(level[i], level[i+1]))
		}
		level = next
	}

	if !sawUnorderedPair {
		t.Fatalf("the fixture's tree never hashes a pair out of order, so it cannot detect a "+
			"sorted-pair divergence between Go and Solidity - add or swap rows in the excerpt "+
			"(%d leaves)", len(leaves))
	}
	if !sawCarryUp {
		t.Fatalf("the fixture's tree has no odd level, so odd-node promotion is never exercised - "+
			"use a leaf count that is not a power of two (%d leaves)", len(leaves))
	}
}

// ═══════════════════════════════════════════════════════════════════
//  The real exports, when they are available
// ═══════════════════════════════════════════════════════════════════

// THE FIXTURES ARE EXCERPTS, and an excerpt cannot prove the decoder survives 19,181 rows of the
// real thing — the manifest cross-check, the uniqueness claim and the kind vocabularies are all
// statements about the WHOLE file. This runs the same code over the full downloads when they are
// present; it skips loudly rather than silently passing, because a skip that reads as a pass is the
// shape sec. 3 records as a false success.
//
//	SANCTIONS_EXPORT_DIR=/path/to/downloads go test -run RealExports -v ./...
//
// expecting SDN.XML, UK_ConList.xml and UN_consolidated.xml in that directory.
func TestRealExportsDecodeEndToEnd(t *testing.T) {
	dir := os.Getenv("SANCTIONS_EXPORT_DIR")
	if dir == "" {
		t.Skip("SANCTIONS_EXPORT_DIR not set - skipping the full-export check (excerpt fixtures still ran)")
	}

	for _, tc := range []struct {
		key, file string
		minRows   int
	}{
		{"OFAC_SDN", "SDN.XML", 19000},
		{"UK_OFSI_CONSOLIDATED", "UK_ConList.xml", 19000},
		{"UN_SC_CONSOLIDATED", "UN_consolidated.xml", 900},
	} {
		body, err := os.ReadFile(dir + "/" + tc.file)
		if err != nil {
			t.Fatalf("%s: %v", tc.key, err)
		}
		subjects, err := decodeSubjects(tc.key, body)
		if err != nil {
			t.Fatalf("%s decode: %v", tc.key, err)
		}
		if len(subjects) < tc.minRows {
			t.Fatalf("%s decoded %d rows, expected at least %d", tc.key, len(subjects), tc.minRows)
		}
		leaves := snapshotLeaves(tc.key, subjects)
		root, err := merkleRoot(leaves)
		if err != nil {
			t.Fatalf("%s root: %v", tc.key, err)
		}
		t.Logf("%s: %d rows -> %d leaves, root %x", tc.key, len(subjects), len(leaves), root)
	}
}
