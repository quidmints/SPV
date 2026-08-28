// Which registration circuit a document needs, and the key its verifier is registered under.
//
// THE MISSING LINK BETWEEN A DOCUMENT AND A VERIFIER. `Registration2.passportVerifiers` is indexed
// by `zkType`, and `HolderRegistration.registerDocumentViaIcao` takes one as a selector — but
// nothing computed which zkType a given document needs. The chain document → profile → zkType
// existed on paper and in no code, so every proof-side binding was wired at both ends and joined in
// the middle by nobody.
//
// SELECTION IS EXACT, NOT NEAREST-MATCH, and that is deliberate. A document either matches a
// profile's fourteen generics or it does not. Choosing a "closest" profile would produce a proof
// against a circuit whose SOD layout constants disagree with the document, which fails at witness
// generation if you are lucky and produces a `registrationSmt` leaf nothing can reproduce if you
// are not — the exact "correct-looking and inert" failure `HolderRegistration` warns about for the
// TD3/TD1 mixup.
//
// ⚠️ ALL FOURTEEN FIELDS ARE REQUIRED. Measured against the manifest: the full tuples are unique
// across all 88 profiles, but dropping the DG15 fields (`DG15_LEN`, `DG15_SHIFT`, `AA_SHIFT`) and
// `EC_FIELD_SIZE` collapses three pairs — e.g. `1_256_3_4_336_248_1_1496_4_256` and
// `1_256_3_4_336_248_1_560_4_256` become indistinguishable. A selector that ignored the Active
// Authentication layout would silently pick the wrong one of a pair.
import { PROFILES, PROFILE_FIELDS, type PassportProfile } from './profiles.generated.ts';

export { PROFILES, PROFILE_FIELDS, type PassportProfile };

/** The fourteen generics read off a document's SOD and DSC, in `PROFILE_FIELDS` order. */
export type DocumentGenerics = readonly number[];

export class NoMatchingProfileError extends Error {
  readonly generics: DocumentGenerics;

  constructor(generics: DocumentGenerics) {
    const described = PROFILE_FIELDS.map((f, i) => `${f}=${generics[i]}`).join(' ');
    super(
      `no passport profile matches this document: ${described}. ` +
        'It is a real document class we have no circuit for — record the tuple and add a profile; ' +
        'do NOT substitute a near match.',
    );
    this.name = 'NoMatchingProfileError';
    this.generics = generics;
  }
}

/**
 * The profile whose generics match this document exactly.
 *
 * Throws `NoMatchingProfileError` rather than returning null: an unmatched document is a coverage
 * gap worth surfacing loudly, and the tuple in the message is exactly what a new profile entry
 * needs. Roughly 3.5% of ICAO PKD signer certificates currently land here.
 */
export function selectProfile(generics: DocumentGenerics): PassportProfile {
  if (generics.length !== PROFILE_FIELDS.length) {
    throw new Error(
      `expected ${PROFILE_FIELDS.length} generics in PROFILE_FIELDS order, got ${generics.length}`,
    );
  }

  const match = PROFILES.find((p) => p.generics.every((v, i) => v === generics[i]));
  if (!match) throw new NoMatchingProfileError(generics);

  return match;
}

/** The registry key for a document, i.e. what `registerDocumentViaIcao` takes as its selector. */
export function selectZkType(generics: DocumentGenerics): string {
  return selectProfile(generics).zkType;
}
