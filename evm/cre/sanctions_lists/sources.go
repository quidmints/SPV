// Pure sanctions-list logic: decode a published export, canonicalise it, build the Merkle root.
//
// NO `//go:build wasip1` TAG, DELIBERATELY. `main.go` is WASM-only because it links the CRE runtime,
// which meant none of the logic below could be tested on a host machine - and this is exactly the
// logic that needs testing. `notary_registry/registry.go` is the same split, for the same reason,
// and this file deliberately mirrors it rather than inventing a second shape.
//
// WHAT CONSENSUS DOES NOT COVER. `cre.ConsensusIdenticalAggregation` requires every DON node to
// produce a BYTE-IDENTICAL result, which protects against a rogue NODE. It cannot protect against a
// DECODER THAT IS WRONG THE SAME WAY EVERYWHERE: every node agrees, and they agree on the wrong set.
// Consensus covers the FETCH, not the MEANING - and the meaning lives here.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// ADDING A COUNTRY IS ADDING DATA, NOT CODE. There is no such thing as "the" sanctions list: the
// US, the UK, the UN and the EU each publish their own, under their own law, in their own schema,
// with their own idea of what a row even is. The first version of this file answered that with a
// struct, a decoder function and a vocabulary map PER COUNTRY - which makes the fifth country the
// same work as the first, and guarantees the five drift apart.
//
// So a source is now a `SourceSpec` LITERAL - where its rows live, which element identifies one,
// which elements carry names, how the subject kind is decided - and ONE walker (`decodeXML`) reads
// any of them. A new jurisdiction is an entry in `sources` and nothing else.
//
// WHAT THAT COSTS, SAID PLAINLY: element paths become strings instead of struct tags, so the
// compiler stops checking them. Two guards buy that back, and together they check MORE than tags
// did - `validate` rejects an incomplete declaration before any fetch, and `AlwaysPresent` refuses
// any ROW missing an element the real export carries on all of them, where an unmatched
// `xml:"..."` tag silently yielded "" and published a snapshot full of empty names.
//
// THE SIX AXES a register can differ on are TODO.md sec. 2.18cb's, written for notary registers and
// confirmed here against three real sanctions exports:
//
//  1. TRANSPORT   - all three serve a single bulk file over HTTPS. None needed the zip handling
//     `notary_registry` carries, so none is implemented (no-unreachable-code); a
//     source needing it gets a declared decompression step, not a bespoke decoder.
//  2. FORMAT      - XML for all three, so the walker is XML. A CSV or JSON source needs a second
//     walker producing the SAME ListedSubject, not a second everything.
//  3. SCHEMA      - fully declarative below: paths, field names, vocabularies.
//  4. LISTING SEMANTICS - the one that breaks designs. Declared per source, never inferred.
//  5. LANGUAGE/SCRIPT   - names are committed AS PUBLISHED; nothing here folds case or script.
//  6. AUTHENTICITY      - declared per source, and it decides whether the postman can ever be
//     removed for that jurisdiction (sec. 2.18bv). It is a per-country answer,
//     so some lists may be trustlessly anchorable and others not.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// Nothing in this file touches the network, the CRE runtime, or a chain: stdlib plus keccak.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

// ═══════════════════════════════════════════════════════════════════
//  The canonical row every source decodes to
// ═══════════════════════════════════════════════════════════════════

// SubjectKind is what a listed row is ABOUT. Every source's own vocabulary is TRANSLATED into these
// - never inferred from a name, never defaulted when unrecognised: the same fail-closed rule
// `notary_registry`'s status vocabulary follows, and for the same reason - a wrong mapping is silent.
type SubjectKind string

const (
	KindIndividual SubjectKind = "individual"
	KindEntity     SubjectKind = "entity"
	KindVessel     SubjectKind = "vessel"
	KindAircraft   SubjectKind = "aircraft"
)

// ListedSubject is ONE PUBLISHED ROW, canonicalised - not one person. The distinction is the whole
// reason this type exists rather than each source's own shape reaching the leaf:
//
//   - OFAC publishes one row per designation, with aliases nested inside it.
//   - OFSI publishes one row PER ALIAS, so a single designation appears several times under one
//     identifier (measured: 19,761 rows carry 5,135 designations).
//
// A design that assumed "row == subject == unique reference" - which the US export happens to
// satisfy - collapses on the UK's the moment it is pointed at it.
type ListedSubject struct {
	// Reference is the source's OWN identifier for the listing, as published. Never our own
	// numbering: a row number is not stable across refreshes, and a name is not stable at all
	// (transliteration and alias ordering both vary).
	Reference string

	Kind SubjectKind

	// NameParts are the source's name fields IN ITS OWN ORDER AND ARITY, uncombined. They are not
	// joined into one string anywhere, because joining is what makes a leaf ambiguous - see leafHash.
	NameParts []string
}

// ═══════════════════════════════════════════════════════════════════
//  What a source declares
// ═══════════════════════════════════════════════════════════════════

// RecordSet is one place rows live, and how the subject kind is decided for them.
//
// TWO FORMS, BECAUSE REGISTERS GENUINELY DIFFER: OFAC and OFSI put the kind IN a field, while the
// UN encodes it STRUCTURALLY - individuals and entities sit in different containers and no field on
// the row says which. Exactly one of `Kind` and `KindField` is set, and `validate` enforces that.
type RecordSet struct {
	// Path is the element path from the document root, e.g. "sdnList/sdnEntry".
	Path string

	// Kind applies to every row here (structural form).
	Kind SubjectKind

	// KindField names the direct-child element carrying the kind, translated via KindVocabulary.
	KindField string
}

// ListingSemantics answers "what does this export say about someone who is NO LONGER listed?" -
// TODO.md sec. 2.18cb axis 4, the axis that decides whether DELISTING can be proven at all.
type ListingSemantics int

const (
	// membershipMeansListed: the export contains exactly those currently designated and carries no
	// status. Presence is provable against a Merkle root; ABSENCE IS NOT (sec. 2.18bp), so "this
	// person was removed" cannot be proven to this anchor by any proof. All three sources declared
	// below are this family - measured, not assumed.
	membershipMeansListed ListingSemantics = iota + 1

	// statusField: rows carry their own status, so delisting is a PRESENCE claim about a row whose
	// status says so - and therefore provable. No source here uses it yet; the constant exists
	// because the declaration must be able to express it, and a source that has one must say so.
	statusField

	// separateDelistingFeed: removals live in a second document, which must be fetched and pinned as
	// of the same instant as the first. OFAC and the UN both publish one; neither is anchored here.
	separateDelistingFeed
)

// Authenticity is axis 6: what, if anything, lets a verifier believe the bytes came from the
// authority rather than from whoever fetched them.
type Authenticity int

const (
	// authenticityTransportOnly: the publisher signs nothing. The only authenticity is the TLS
	// session the DON node itself opened, which it cannot prove to anyone afterwards - so the
	// snapshot RESTS ON DON HONESTY for this source (sec. 2.18bv/2.18br).
	//
	// AND THAT IS A TRUST ASSUMPTION, NOT AN AUTHORITY. An earlier version of this comment concluded
	// "...and the postman CANNOT be removed for this source". That does not follow, and the two must
	// not be collapsed (sec. 2.18cp):
	//   - what is irreducible here is WHOM YOU TRUST ABOUT THE CONTENT - the DON, because nothing
	//     else vouches for bytes the publisher never signed;
	//   - what is removable is WHO MAY SUBMIT. Verify the DON's report signature on-chain and the
	//     submitter becomes untrusted: anyone may relay, and a forged report fails the check. That is
	//     the same move ICAO's CMS signature makes for a signed source, with the DON's quorum key in
	//     place of the authority's.
	// Removal additionally needs REPLAY PROTECTION, because a permissionless relay could re-submit an
	// old valid report and regress `latestRoot`. The metadata header already carries what that needs
	// (timestamp at offset 33, execution ID at 1).
	//
	// This is not a claim that no signed artifact exists anywhere; it records that the export we
	// fetch is unsigned and that no detached signature was found beside it. Finding one is a change
	// to this field, not to any code.
	authenticityTransportOnly Authenticity = iota + 1

	// authenticityDetachedSignature: a `.p7s`/CMS or XAdES artifact is published alongside, so the
	// authority's own signature can be verified in-workflow and trust in the DON drops to liveness.
	authenticityDetachedSignature
)

// SourceSpec is the WHOLE per-jurisdiction declaration. Adding a country means adding one of these.
type SourceSpec struct {
	// Key is the registry key. `registryIDFor` hashes it into the `registryId` that
	// RegistrySourceAnchor stores snapshots under, and leafHash binds it into every leaf.
	Key string

	// Records: where the rows are, and how each one's kind is decided.
	Records []RecordSet

	// ReferenceField is the direct-child element holding the source's own identifier for a listing.
	ReferenceField string

	// Identifiers declares where this source publishes the rows the PREDICATE can key, if it does.
	//
	// ⚠️ A ZERO VALUE IS A REAL STATE, NOT AN OVERSIGHT: not every register publishes document
	// numbers, and a source that does not simply contributes no keys. It must be visible as a
	// declaration rather than inferred from an empty tree - an empty tree admits everyone, so
	// "this source publishes nothing keyable" and "this source failed to parse" must not look alike.
	Identifiers IdentifierSet

	// NameFields are direct-child elements, IN PUBLISHED ORDER. Every one is read for every row,
	// present or not, so arity is constant within a source - which is what stops a name moving
	// between slots from producing a colliding leaf.
	NameFields []string

	// KindVocabulary translates this register's own words. Required exactly when some RecordSet
	// names a KindField. An unlisted value REFUSES THE SNAPSHOT - a new word is how a register says
	// something we have not seen, and guessing drops designated parties while looking complete.
	KindVocabulary map[string]SubjectKind

	// AlwaysPresent are the elements the real export carries on EVERY row, so a row missing one has
	// been renamed or removed upstream. THIS IS WHAT REPLACES THE COMPILER'S CHECKING of struct
	// tags, and it checks more than they did: an unmatched `xml:"..."` tag yields "" in silence,
	// filling every row with empty names and publishing a plausible, wrong snapshot.
	//
	// PER ROW, NOT PER DOCUMENT, and that distinction was found by testing rather than by design.
	// The first version demanded that every declared element appear SOMEWHERE, which refused valid
	// documents: US `firstName` is on 7,473 of 19,181 rows and UN `SECOND_NAME` on 727 of 736, so
	// entities and mononymous individuals legitimately lack them, and a small export could lack them
	// entirely. A guard that fires on correct input is a clamp, not a check. Optional elements are
	// simply not listed here; the ones that are, are measured.
	AlwaysPresent []string

	// ManifestCountPath is an element whose integer value must equal the number of rows decoded.
	// Optional, because only some publishers state it - and where they do, it is the strongest
	// anti-rot guard available, detecting silent row loss with no external reference point.
	ManifestCountPath string

	Listing      ListingSemantics
	Authenticity Authenticity

	// ReferenceIdentifiesRow records whether the identifier is unique across rows. It is CHECKED,
	// not trusted: a source that declares uniqueness and stops honouring it has changed what a row
	// means, and that must fail loudly rather than silently merge two designations.
	ReferenceIdentifiesRow bool

	// PublishedAt IS the URL fetched. It was config-supplied until 2026-08-07, on the reasoning that
	// "hardcoding one is a hardcoded dependency on a publisher's URL scheme surviving" - and that
	// reasoning does not survive how CRE pins a workflow.
	//
	// A WORKFLOW ID IS A HASH OF THE BINARY **AND THE CONFIG**, and changes whenever either does.
	// So a config-supplied URL was never cheaper to change than a compiled-in one: both produce a new
	// workflowId, and both then require `pinWorkflow` plus the 24h WORKFLOW_ACTIVATION_DELAY before
	// `onReport` will accept a report. The indirection bought no operational flexibility whatsoever.
	//
	// WHAT IT DID BUY was a way for the declared URL and the fetched URL to DIVERGE, guarded only by
	// "a human can compare the two". Deleting the second value deletes the comparison rather than
	// making it more reliable. One binary still serves every source, because `RegistryKey` selects
	// the spec - that never depended on config carrying a URL. See TODO sec. 2.18fl.
	//
	// ⚠️ A MIRROR IS NOT A VALID SUBSTITUTE, which is the one thing config flexibility might have
	// been used for. Authenticity here is transport-only (see Authenticity, below), so fetching from
	// anywhere but the publisher's own host discards the only authenticity the source has.
	PublishedAt string
}

// sources is the declared roster. EVERY FIELD OF EVERY ENTRY WAS READ OFF THE REAL EXPORT on
// 2026-08-02, not off documentation of it - `notary_registry` shipped a guessed schema in which
// every single tag was wrong and the parse yielded ZERO rows (sec. 2.18ce), and that guess came
// from third-party descriptions exactly like the ones available for these three.
//
// UNDECLARED MEANS UNPUBLISHABLE. `sourceFor` refuses a key that is not here, and refuses a spec
// that leaves any of these questions unanswered - sec. 2.18cb's rule, which exists because a list
// anchored without declaring what its absences mean silently gives the weaker guarantee everywhere.
var sources = map[string]SourceSpec{
	// UNITED STATES - OFAC Specially Designated Nationals.
	// Measured 2026-08-02 on the 2026-07-29 publication: 19,181 entries, `uid` unique across all of
	// them, sdnType in {Entity 9840, Individual 7473, Vessel 1524, Aircraft 344}, `lastName` on
	// every row, `firstName` on exactly the 7,473 Individuals.
	//
	// ONLY DIRECT CHILDREN COUNT, and here that is load-bearing rather than pedantic: an sdnEntry
	// nests `<uid>` elements of its own inside akaList, addressList and idList, so a walker that
	// took any descendant would key an entry's leaf on whichever alias came last.
	"OFAC_SDN": {
		Key:            "OFAC_SDN",
		Records:        []RecordSet{{Path: "sdnList/sdnEntry", KindField: "sdnType"}},
		ReferenceField: "uid",
		NameFields:     []string{"lastName", "firstName"},
		Identifiers:    ofacPassports,
		// Measured on all 19,181 rows. `firstName` is deliberately absent from this list: it is on
		// the 7,473 Individuals only, because an entity, a vessel and an aircraft each have one name.
		AlwaysPresent:     []string{"uid", "lastName", "sdnType"},
		ManifestCountPath: "sdnList/publshInformation/Record_Count", // Treasury's own missing "i"
		KindVocabulary: map[string]SubjectKind{
			"Individual": KindIndividual,
			"Entity":     KindEntity,
			"Vessel":     KindVessel,
			"Aircraft":   KindAircraft,
		},
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: true,
		PublishedAt:            "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/SDN.XML",
	},

	// UNITED KINGDOM - OFSI consolidated list of financial sanctions targets.
	// Measured 2026-08-02: 19,761 rows carrying 5,135 designations, because each alias is its own
	// row (AliasType: AKA 7,700 / Primary name 6,240 / Primary name variation 5,794 / FKA 27).
	// GroupTypeDescription in {Individual 13863, Entity 5817, Ship 81}. Only 13,865 rows are
	// distinct once decoded, so DEDUPLICATION IS LOAD-BEARING HERE, not a precaution: ~5,900 rows
	// repeat a designation's name set exactly, and equal neighbours fail the contract's ascent rule.
	//
	// `GroupID` IS THE KEY, NOT `UKSanctionsListRef`, and that is a measurement rather than a
	// preference. The obvious choice is the FCDO reference, because it is the citable one
	// ("GHR0086"). It is EMPTY on one row of 19,761 - Alexander SAMOFAL, a real individual
	// designated 2023-04-21 under Global Human Rights - so keying on it makes him unanchorable and,
	// because a row with no reference is refused, takes the ENTIRE UK snapshot down with him.
	// `GroupID` is never empty and partitions the rows identically (5,135 distinct either way, no
	// GroupID spanning two references). Both fields look equally good in any fixture small enough to
	// read; the difference is one row in twenty thousand, and it decides whether the list publishes.
	//
	// Note OFSI's own inconsistent casing - `name1`..`name5` lowercase, `Name6` capitalised. Copied
	// from the published file rather than normalised.
	"UK_OFSI_CONSOLIDATED": {
		Key:            "UK_OFSI_CONSOLIDATED",
		Records:        []RecordSet{{Path: "ArrayOfFinancialSanctionsTarget/FinancialSanctionsTarget", KindField: "GroupTypeDescription"}},
		ReferenceField: "GroupID",
		NameFields:     []string{"name1", "name2", "name3", "name4", "name5", "Name6"},
		// Measured: all eight are on all 19,761 rows, empty ones included as empty elements.
		AlwaysPresent: []string{"GroupID", "name1", "name2", "name3", "name4", "name5", "Name6", "GroupTypeDescription"},
		KindVocabulary: map[string]SubjectKind{
			"Individual": KindIndividual,
			"Entity":     KindEntity,
			"Ship":       KindVessel,
		},
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: false,
		PublishedAt:            "https://ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.xml",
	},

	// UNITED NATIONS - Security Council consolidated list.
	// Measured 2026-08-02: 736 individuals + 275 entities, DATAID unique across both containers.
	// THE KIND IS STRUCTURAL - which container a row sits in - with no field on the row saying so,
	// which is why RecordSet has to express both forms. An entity's name arrives in FIRST_NAME with
	// the rest empty, i.e. the same arity as an individual's.
	"UN_SC_CONSOLIDATED": {
		Key: "UN_SC_CONSOLIDATED",
		Records: []RecordSet{
			{Path: "CONSOLIDATED_LIST/INDIVIDUALS/INDIVIDUAL", Kind: KindIndividual},
			{Path: "CONSOLIDATED_LIST/ENTITIES/ENTITY", Kind: KindEntity},
		},
		ReferenceField: "DATAID",
		NameFields:     []string{"FIRST_NAME", "SECOND_NAME", "THIRD_NAME", "FOURTH_NAME"},
		// Measured: only these two are universal. SECOND_NAME is on 727 of 736 individuals and on NO
		// entity - an entity's whole name is FIRST_NAME - so requiring it would refuse the real file.
		AlwaysPresent:          []string{"DATAID", "FIRST_NAME"},
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: true,
		PublishedAt:            "https://scsanctions.un.org/resources/xml/en/consolidated.xml",
	},
}

// sourceFor resolves a declared source and validates its declaration.
func sourceFor(registryKey string) (SourceSpec, error) {
	spec, ok := sources[registryKey]
	if !ok {
		return SourceSpec{}, fmt.Errorf(
			"no source declared for registry %q - a sanctions list's schema, its listing semantics "+
				"and its authenticity are per-jurisdiction facts that must be read off the real "+
				"export and declared in `sources` before it can publish", registryKey)
	}
	if err := spec.validate(); err != nil {
		return SourceSpec{}, fmt.Errorf("source %q: %w", registryKey, err)
	}
	return spec, nil
}

// validate is what a declarative table buys back from the compiler. Every failure means somebody
// added a source without answering one of these questions - and it fires BEFORE any fetch, rather
// than halfway through a real export.
func (s SourceSpec) validate() error {
	if len(s.Records) == 0 {
		return fmt.Errorf("declares no record sets, so there is nowhere to read rows from")
	}
	needsVocabulary := false
	for _, rs := range s.Records {
		if rs.Path == "" {
			return fmt.Errorf("a record set declares no path")
		}
		if (rs.Kind == "") == (rs.KindField == "") {
			return fmt.Errorf(
				"record set %q must declare EITHER a structural Kind or a KindField, not both and "+
					"not neither - a row whose kind is undecided cannot be hashed", rs.Path)
		}
		if rs.KindField != "" {
			needsVocabulary = true
		}
	}
	if needsVocabulary && len(s.KindVocabulary) == 0 {
		return fmt.Errorf(
			"reads its subject kind from a field but declares no vocabulary to translate it - a " +
				"register writes its kinds in its own words, and guessing them drops rows")
	}
	if s.ReferenceField == "" {
		return fmt.Errorf("declares no reference field, so no leaf could be cited")
	}
	if len(s.NameFields) == 0 {
		return fmt.Errorf("declares no name fields, so every row of one kind would share a leaf")
	}
	if len(s.AlwaysPresent) == 0 {
		return fmt.Errorf(
			"names no always-present elements, so a renamed or removed element would silently " +
				"produce rows of empty values instead of refusing the snapshot")
	}
	if s.Listing == 0 || s.Authenticity == 0 {
		return fmt.Errorf(
			"declares no listing semantics or no authenticity - refusing to publish a list whose " +
				"absences and provenance are undefined")
	}
	return nil
}

func registryIDFor(registryKey string) [32]byte {
	return crypto.Keccak256Hash([]byte(registryKey))
}

// decodeSubjects decodes a published export and enforces what its source claims about itself.
func decodeSubjects(registryKey string, body []byte) ([]ListedSubject, error) {
	spec, err := sourceFor(registryKey)
	if err != nil {
		return nil, err
	}

	subjects, err := decodeXML(spec, body)
	if err != nil {
		return nil, err
	}
	if len(subjects) == 0 {
		// Publishing an empty root would silently clear the anchored set, and an empty parse is far
		// more likely to be schema drift than a genuinely empty sanctions list. Loud beats plausible.
		return nil, fmt.Errorf("%s decoded 0 rows - refusing to publish an empty snapshot", registryKey)
	}

	if spec.ReferenceIdentifiesRow {
		seen := make(map[string]struct{}, len(subjects))
		for _, s := range subjects {
			if _, dup := seen[s.Reference]; dup {
				return nil, fmt.Errorf(
					"%s declares its reference unique but %q appears twice - the export has changed "+
						"what a row means, and continuing would merge two designations into one leaf",
					registryKey, s.Reference)
			}
			seen[s.Reference] = struct{}{}
		}
	}

	for _, s := range subjects {
		if s.Reference == "" {
			return nil, fmt.Errorf("%s produced a row with no reference - it could never be cited", registryKey)
		}
	}
	return subjects, nil
}

// ═══════════════════════════════════════════════════════════════════
//  ONE WALKER, ANY DECLARED SOURCE
// ═══════════════════════════════════════════════════════════════════

// decodeXML streams the document, collecting the DIRECT CHILDREN of each declared record path.
//
// DIRECT CHILDREN, NOT DESCENDANTS. OFAC nests `<uid>` inside an entry's akaList, addressList and
// idList, so a walker that took any descendant named `uid` would key that entry's leaf on an
// alias's identifier. Depth is tracked rather than assumed.
//
// NAMESPACES ARE IGNORED. All three exports declare a default namespace, none uses it to
// disambiguate, and matching on local names means a publisher changing their namespace URI - which
// says nothing about the data - cannot silently empty the snapshot.
//
// EVERY DECLARED ELEMENT MUST APPEAR AT LEAST ONCE. This is the check that replaces what struct
// tags never gave: an unmatched `xml:"..."` tag yields "" in silence, so a renamed element used to
// produce rows full of empty names rather than an error.
func decodeXML(spec SourceSpec, body []byte) ([]ListedSubject, error) {
	recordSets := make(map[string]RecordSet, len(spec.Records))
	for _, rs := range spec.Records {
		recordSets[rs.Path] = rs
	}

	var (
		decoder  = xml.NewDecoder(bytes.NewReader(body))
		path     []string
		subjects []ListedSubject

		current   *RecordSet        // the record set being read, nil outside one
		rowDepth  int               // len(path) at the record element itself
		row       map[string]string // its direct children
		fieldName string            // the direct child being read, "" between them
		field     strings.Builder

		manifest      strings.Builder
		manifestFound bool
	)

	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%s parse: %w", spec.Key, err)
		}

		switch t := token.(type) {
		case xml.StartElement:
			path = append(path, t.Name.Local)

			if current == nil {
				if rs, isRecord := recordSets[strings.Join(path, "/")]; isRecord {
					set := rs
					current, rowDepth = &set, len(path)
					row = make(map[string]string, len(spec.NameFields)+2)
				}
			} else if len(path) == rowDepth+1 {
				fieldName, field = t.Name.Local, strings.Builder{}
			}

			if spec.ManifestCountPath != "" && strings.Join(path, "/") == spec.ManifestCountPath {
				manifestFound, manifest = true, strings.Builder{}
			}

		case xml.CharData:
			// Only text sitting DIRECTLY inside the element being read is its value; whitespace
			// between sibling elements reaches neither.
			if current != nil && fieldName != "" && len(path) == rowDepth+1 {
				field.Write(t)
			} else if manifestFound && strings.Join(path, "/") == spec.ManifestCountPath {
				manifest.Write(t)
			}

		case xml.EndElement:
			if current != nil && fieldName != "" && len(path) == rowDepth+1 {
				// Recording the element as PRESENT, empty or not, is what distinguishes "this
				// designation has no first name" from "the schema no longer has that element".
				row[fieldName] = field.String()
				fieldName = ""
			} else if current != nil && len(path) == rowDepth {
				subject, err := spec.subjectFrom(*current, row)
				if err != nil {
					return nil, err
				}
				subjects = append(subjects, subject)
				current, row = nil, nil
			}
			path = path[:len(path)-1]
		}
	}

	if err := spec.checkManifest(manifestFound, manifest.String(), len(subjects)); err != nil {
		return nil, err
	}
	return subjects, nil
}

// checkManifest compares the export's own declared length with what was decoded.
//
// THE EXPORT DECLARING ITS OWN LENGTH is the strongest anti-rot guard available here: it detects
// silent row loss with no external reference point at all. Under-counting is the dangerous
// direction for a sanctions list - it omits someone who IS designated while the snapshot still
// looks complete.
func (s SourceSpec) checkManifest(found bool, raw string, decoded int) error {
	if s.ManifestCountPath == "" {
		return nil
	}
	if !found {
		return fmt.Errorf(
			"%s declares a manifest at %q and the document has no such element - the export's "+
				"schema has changed under a guard that exists to catch exactly that",
			s.Key, s.ManifestCountPath)
	}
	declared, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return fmt.Errorf("%s manifest %q is not a number: %w", s.Key, raw, err)
	}
	if declared != decoded {
		return fmt.Errorf(
			"%s declares %d records at %s but %d rows decoded - refusing to publish a snapshot that "+
				"disagrees with its own manifest", s.Key, declared, s.ManifestCountPath, decoded)
	}
	return nil
}

func (s SourceSpec) subjectFrom(set RecordSet, row map[string]string) (ListedSubject, error) {
	for _, element := range s.AlwaysPresent {
		if _, present := row[element]; !present {
			return ListedSubject{}, fmt.Errorf(
				"%s row %q has no %q element, which the real export carries on every row - a renamed "+
					"or removed element must refuse the snapshot, not quietly fill the row with an "+
					"empty value", s.Key, row[s.ReferenceField], element)
		}
	}

	kind := set.Kind
	if set.KindField != "" {
		published := row[set.KindField]
		translated, known := s.KindVocabulary[published]
		if !known {
			return ListedSubject{}, fmt.Errorf(
				"%s row %q has unrecognised %s %q - declare it in the source's KindVocabulary rather "+
					"than defaulting, because guessing wrong drops a designated party from the snapshot",
				s.Key, row[s.ReferenceField], set.KindField, published)
		}
		kind = translated
	}

	// Every declared name field, present or not, so arity is constant within a source.
	parts := make([]string, len(s.NameFields))
	for i, f := range s.NameFields {
		parts[i] = row[f]
	}

	return ListedSubject{Reference: row[s.ReferenceField], Kind: kind, NameParts: parts}, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Leaves
// ═══════════════════════════════════════════════════════════════════

// leafHash commits to the registry, the reference, the kind and every name part UNAMBIGUOUSLY.
//
// EVERY COMPONENT IS HASHED FIRST, so each is fixed-width and no boundary can be re-split. A bare
// concatenation with a delimiter - which is what this workflow shipped with, `uid + "|" + name` -
// hashes reference "12" with name "3X" identically to reference "123" with name "X", and forbids
// the delimiter from ever appearing inside a name. `notary_registry` had the same defect and fixed
// it the same way (sec. 2.18ao); the argument that real data never collides is an argument about
// TODAY'S DATA, not about the construction.
//
// THE PART COUNT IS COMMITTED TOO, in four fixed bytes, because arity varies BY SOURCE: two name
// parts for the US, six for the UK, four for the UN. Padding one with empties must not be able to
// reach another's leaf.
//
// THE REGISTRY KEY IS IN THE LEAF, which is what stops a leaf from one list being replayed as proof
// of listing on another. Without it, a UK row and a US row describing the same person hash
// identically, and a proof against the UK root would satisfy a check written against the US one.
func leafHash(registryKey string, s ListedSubject) [32]byte {
	parts := make([]byte, 0, 32*(3+len(s.NameParts))+4)
	parts = append(parts, crypto.Keccak256([]byte(registryKey))...)
	parts = append(parts, crypto.Keccak256([]byte(s.Reference))...)
	parts = append(parts, crypto.Keccak256([]byte(s.Kind))...)

	var count [4]byte
	binary.BigEndian.PutUint32(count[:], uint32(len(s.NameParts)))
	parts = append(parts, count[:]...)

	for _, p := range s.NameParts {
		parts = append(parts, crypto.Keccak256([]byte(p))...)
	}
	return crypto.Keccak256Hash(parts)
}

// snapshotLeaves produces exactly the array to hand to RegistrySourceAnchor: hashed, deduplicated,
// strictly ascending.
//
// SORTING IS NOT COSMETIC. `RegistrySourceAnchor._computeRoot` REVERTS with
// `LeavesNotStrictlySorted` on anything else, so an unsorted array is not a slow path or an untidy
// one - it is a workflow that can never publish at all. This workflow shipped that way: it sorted
// its ENTRIES by uid and then mapped them to hashes, which are in no particular order.
//
// DEDUPLICATION is required by the same rule from the other side: equal neighbours are not strict
// ascent, so a single duplicated row upstream would make the whole snapshot unpublishable. Two
// identical rows carry no more information than one, and the UK export - one row per alias - makes
// exact duplicates ordinary rather than exceptional.
func snapshotLeaves(registryKey string, subjects []ListedSubject) [][32]byte {
	leaves := make([][32]byte, 0, len(subjects))
	seen := make(map[[32]byte]struct{}, len(subjects))

	for _, s := range subjects {
		leaf := leafHash(registryKey, s)
		if _, dup := seen[leaf]; dup {
			continue
		}
		seen[leaf] = struct{}{}
		leaves = append(leaves, leaf)
	}

	sort.Slice(leaves, func(i, j int) bool { return bytesLess(leaves[i], leaves[j]) })
	return leaves
}

func bytesLess(a, b [32]byte) bool {
	return bytes.Compare(a[:], b[:]) < 0
}

// ═══════════════════════════════════════════════════════════════════
//  Merkle root - the exact algorithm RegistrySourceAnchor._computeRoot implements
// ═══════════════════════════════════════════════════════════════════

// merkleRoot mirrors the contract line for line: strict-ascent check, sorted-pair internal nodes
// (so proofs carry no direction bits), odd node promoted unchanged.
//
// IT ENFORCES THE ORDERING RATHER THAN IMPOSING IT, which is the difference that matters. A version
// that sorted internally would compute a root the contract could not reproduce from the same array,
// and the disagreement would surface as a revert at publish time with nothing pointing back here.
// Failing on the same condition, in the same place, is what keeps the two implementations honest.
func merkleRoot(leaves [][32]byte) ([32]byte, error) {
	if len(leaves) == 0 {
		// `_computeRoot` reverts EmptyLeafSet; there is no root to agree on.
		return [32]byte{}, fmt.Errorf("empty leaf set")
	}
	for i := 1; i < len(leaves); i++ {
		if !bytesLess(leaves[i-1], leaves[i]) {
			return [32]byte{}, fmt.Errorf(
				"leaves are not strictly ascending at index %d - RegistrySourceAnchor would revert "+
					"LeavesNotStrictlySorted", i)
		}
	}

	level := make([][32]byte, len(leaves))
	copy(level, leaves)

	for len(level) > 1 {
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i]) // odd one out, carried up unchanged
				continue
			}
			next = append(next, hashSortedPair(level[i], level[i+1]))
		}
		level = next
	}
	return level[0], nil
}

// hashSortedPair orders the pair before hashing, so a proof does not need to carry direction bits -
// matching OpenZeppelin's MerkleProof and `RegistrySourceAnchor._hashSortedPair`.
func hashSortedPair(a, b [32]byte) [32]byte {
	if bytesLess(b, a) {
		a, b = b, a
	}
	return crypto.Keccak256Hash(a[:], b[:])
}
