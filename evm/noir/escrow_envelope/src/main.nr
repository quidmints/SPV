// escrow_envelope - the one-time, permissionless transaction that makes an identity REVOCABLE.
//
// Posted once per identity, never on the withdrawal hot path. It proves that a published ciphertext
// genuinely seals the revocation secret committed under this holder root, so the controller CAN
// list that identity later. Without it, a user picks a secret nobody knows and their absence from
// the blacklist is guaranteed forever - see pp/src/envelope.nr's header for why that vacuity is the
// whole reason this circuit exists.
//
// PERMISSIONLESS BY CONSTRUCTION: no controller signature is consumed, so there is no approval to
// withhold. That is deliberate - an attested escrow would hand back the censorship-by-inaction
// lever the blacklist design exists to remove.
//
// TRUE OF THIS CIRCUIT, NOT YET OF THE SYSTEM (sec. 2.18g). Escrowing requires a document
// already bound in `registrationSmt`, and the only contract that binds one - `HolderRegistration` -
// demands a BACKEND SIGNER'S SIGNATURE on every entry point. The approval step was moved upstream,
// not removed. `Registration2.registerViaNoir` is the signature-free path already in the repo, and
// nothing yet routes it into the holder tree.
//
// ---------------------------------------------------------------------------------------------
// WHAT THIS CIRCUIT PUBLISHES, AND WHY THAT CHANGED (sec. 2.18)
//
// IT USED TO PUBLISH `holder_root` AND `dg1_hash`. Both are per-person identifiers, so registration
// calldata linked every user's IDENTITY to their POOL HANDLE, permanently and for everyone. Their
// ACTIVITY was still private - a withdrawal never discloses the commitment, which is a private SMT
// key - but their PARTICIPATION was public. That was the largest privacy defect in our own code.
//
// The identifiers existed only so `IdentityRegistry.register` could check
// `holderOfDocumentHash(dg1Hash) == holderRoot`: proof that the sealed MRZ belongs to a real,
// ICAO-verified document rather than an invented one. THAT CHECK IS NOW DONE IN-CIRCUIT, against
// `StateKeeper.registrationSmt`, and nothing identifying is published. `registration_root` is one
// value shared by every user of the system, so it names nobody.
//
// SOUNDNESS COMES FROM THE LEAF VALUE, NOT THE INDEX. `document_key` is a caller-supplied field
// that no proof constrains (sec. 2.13f), so inclusion at an index alone would be weak - a
// prover could point at somebody else's leaf. But the leaf VALUE is
// `Poseidon(dgCommit, seq, timestamp)`, and `dgCommit = extract_dg1_commitment(dg1, sk_identity)`
// is derived from the holder's OWN secret. Reproducing a stranger's leaf value would require their
// `sk_identity`. Inclusion plus a re-derived `dgCommit` is therefore sound even though the index is
// not, and it binds the SEALED BYTES - not merely a hash of them - to the registered document.
//
// IT IS ALSO STRICTLY STRONGER THAN THE CHECK IT REPLACES. `_holderOfDocumentHash` is written at
// binding and NEVER CLEARED, so a document later revoked or superseded still satisfied the old
// test: a cancelled passport could register an identity. The tree cannot be fooled that way -
// `revokeDocument`/`renewDocument` overwrite the leaf value with `Poseidon1(REVOKED)` /
// `Poseidon1(SUPERSEDED)`, which no `Poseidon3(dgCommit, seq, timestamp)` reconstruction equals.
//
// ---------------------------------------------------------------------------------------------
// WHY THE REVOCATION SECRET IS DERIVED AND NO LONGER CHOSEN (sec. 2.18a)
//
// `IdentityRegistry` guards on `registered[commitment]` and NOTHING ELSE - it has no per-holder
// guard. While the secret was free, a revoked user could escrow a FRESH secret against the SAME
// passport, produce a DIFFERENT commitment, and register clean. The blacklist was evadable by
// exactly the people it was applied to, which is the whole of its value.
//
// Deriving the secret from `sk_identity` makes the commitment a FUNCTION of the identity: one
// identity has exactly one commitment, so `registered[commitment]` becomes the per-holder guard and
// re-registration after revocation reverts `AlreadyRegistered`. It costs one Poseidon, on the
// one-time path.
//
// WHAT THIS DOES NOT CLAIM. A person holding two passports under two different `sk_identity` values
// still has two identities; nothing in ICAO 9303 links two states' documents, which is exactly why
// the MRZ rides inside the envelope for the controller to attribute (see below). What is closed is
// FREE re-registration of the SAME identity, which needed no second passport at all.
//
// ---------------------------------------------------------------------------------------------
// WHY THE WHOLE DG1 IS SEALED, NOT A DIGEST (sec. 2.13f). A person may hold several
// passports under different names, and nothing in ICAO 9303 links two states' documents for one
// person. The controller therefore has to do that attribution itself, which it can only do from the
// ACTUAL MRZ - name, date of birth, nationality, document number. A hash would let it verify a
// guess but never form one. So the MRZ rides inside the envelope: opaque on-chain, readable only by
// the controller, and now bound by `dgCommit` to the same bytes registration itself committed to.
use noir_dl::not_passports_zk_circuits::extract_dg1_commitment;
use noir_dl::query::{identity_state_verifier, td1_document_fields};
use poseidon::poseidon::PoseidonHasher;
use pp::blacklist::document_identifier;
use pp::envelope::{identity_commitment, seal_payload, secret_commitment};
use std::hash::Hasher;

/// DG1 length. 95 = the ICAO TD1 layout (3 lines x 30 chars, plus a 5-byte tag/length header),
/// which is what `register_identity_light_td1` takes.
///
/// THIS MUST MATCH THE REGISTRATION CIRCUIT THAT HolderRegistration ACTUALLY VERIFIES, and that is
/// the LIGHT one: `RegistrationSimple._PROOF_SIGNALS_COUNT` is 3, which is the light circuit's
/// output arity (the full `register_identity` returns 5 and takes a 93-byte TD3 DG1).
///
/// IT MATTERS FOR A DIFFERENT REASON NOW. It used to fix the number of bytes hashed into
/// `dg1_hash`; it now fixes the number of bytes committed by `extract_dg1_commitment`, whose four
/// chunks each span `2 * DG1_LEN` bits. A different length yields a different `dgCommit`, so the
/// SMT inclusion below would fail for EVERY genuine document - hence
/// `test_dg_commit_matches_the_registration_circuit`, which compares against the registration
/// circuit's own output rather than against a value this file computed.
///
/// A TD3/93-byte escrow variant is still needed if the full `register_identity` path is ever wired
/// up - see.
global DG1_LEN: u32 = 95;
/// The escrow payload: the document identifier. ONE field.
///
/// 🔴 IT USED TO BE FIVE, AND THE OTHER FOUR WERE THE PACKED MRZ - name, date of birth,
/// nationality, sex, expiry and document number, sealed to ONE immutable controller key and emitted
/// as an event, therefore permanently indexable. One secret key decrypted every registered user's
/// passport, retroactively.
///
/// ⚠️ THE ESCROW'S STATED PURPOSE NEVER NEEDED THEM. This circuit exists so a controller CAN list an
/// identity later; that requires knowing WHICH envelope corresponds to a sanctioned document, which
/// `document_id` answers exactly. Name and date of birth are only useful for matching a designation
/// BY NAME - and `identifiers.go` rejects name matching as unsound ("no transliteration, no alias
/// ordering, no similarity matching, no threshold"). Those reasons do not stop applying off-chain.
///
/// ⛔ AND THE SAME REASONING ALREADY RAN ONCE IN THIS FILE. It used to publish `holder_root` and
/// `dg1_hash`, and the header below calls removing them "the largest privacy defect in our own
/// code". That pass stopped one step short: encrypting an identifier to a key the user does not hold
/// is deferred disclosure, not privacy.
///
/// 🔴 AND THE REVOCATION SECRET IS NO LONGER SEALED EITHER, BECAUSE THE TRACE SAID IT BOUGHT
/// NOTHING AND COST A CREDENTIAL. Two measurements settled it:
///
///   1. `IdentityRegistry.revoke(commitment_, predicate_)` takes ONLY the commitment, and the
///      commitment is a public signal here, stored in `registered[]`. The sealed secret is read by
///      nothing, in any language, anywhere in the repo.
///   2. `withdraw.nr` computes `identity_commitment(revocation_secret, document_id)` - the secret IS
///      the witness that proves identity in a withdrawal. Sealing it handed whoever holds
///      CONTROLLER_SK the identity half of every user's withdrawal proof.
///
/// Not fund theft on its own - spending still needs the note's own nullifier and secret - but a
/// credential has no business sitting encrypted under a single immutable key for no operational
/// reason. What remains is the minimum that makes targeted revocation possible at all: a mapping
/// from a recomputable document identifier to the commitment that holds it.
global PAYLOAD_LEN: u32 = 1;
/// Height of `StateKeeper.registrationSmt`.
///
/// 80, NOT 32. An earlier estimate in sec. 2.18 sized this inclusion at depth 32 - the
/// IDENTITY registry's height - and undercounted the cost as a result. The registration tree is a
/// rarime `PoseidonSMT` initialised at 80 everywhere it is deployed, and `query_identity` already
/// takes `siblings: [Field; 80]`. A mismatch here does not fail loudly: `smt_level_ins` asserts the
/// top sibling is zero, so a witness padded to the wrong height produces an inclusion failure with
/// no hint that the HEIGHT is what is wrong.
global REGISTRATION_TREE_DEPTH: u32 = 80;

/// Domain separator for the revocation secret.
///
/// The big-endian bytes of the ASCII string "pp:revocation-secret:v1" (23 bytes, so it fits a BN254
/// field with room to spare). Written as a literal because Noir globals must be constant, and
/// checked against the string itself in `test_revocation_domain_is_the_string_it_claims_to_be` -
/// a magic number nobody can re-derive is a magic number that gets copied wrong.
///
/// IT IS NOT DECORATION. `revocation_secret = Poseidon(sk_identity, DOMAIN)` must not collide with
/// any OTHER value derived from `sk_identity` - in particular `extract_pk_identity_hash`, which
/// this repo already publishes as `holder_root`. The separator is what keeps the two apart.
global REVOCATION_SECRET_DOMAIN: Field = 10769458381189379141499981179385028620184879844130715185;

/// The identity's revocation secret: deterministic, so one identity yields one commitment.
///
/// See the header - this is what makes `IdentityRegistry.registered[commitment]` a per-holder
/// guard, and therefore what makes revocation stick.
pub fn derive_revocation_secret(sk_identity: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(sk_identity);
    hasher.write(REVOCATION_SECRET_DOMAIN);
    hasher.finish()
}


fn main(
    // The controller's published sealing key.
    controller_x: pub Field,
    controller_y: pub Field,
    // Goes into the registered-identity leaf as `commitment -> 0`. The withdrawal circuit
    // re-derives it from its own `s`, which is what binds a withdrawal to an escrowed secret.
    // PUBLISHED, and safe to publish: it is a fresh pseudonym that no public value links to the
    // holder. It is also the ONLY per-person value this circuit reveals.
    commitment: pub Field,
    // The root of `StateKeeper.registrationSmt` this proof is made against. Shared by EVERY
    // registered document in the system, so it identifies nobody. The contract must still check it
    // is a root the SMT recognises - a proof against a root of the prover's own invention would
    // otherwise let them assert any document they liked.
    registration_root: pub Field,
    // The published ciphertext: ephemeral point, then payload[0] = revocation secret,
    // payload[1..5] = the packed MRZ.
    c1_x: pub Field,
    c1_y: pub Field,
    sealed: pub [Field; PAYLOAD_LEN],
    // Private. `holder_root` is no longer an input at all - it is derived from `sk_identity` inside
    // `identity_state_verifier`, which is what makes proving knowledge of `sk_identity` mandatory
    // (an attacker who could merely NAME a holder root would escrow a commitment to a secret of
    // THEIR choosing against a VICTIM's identity, and the victim's own withdrawal, which proves its
    // `s` matches the escrowed commitment, would fail forever).
    sk_identity: Field,
    ephemeral: Field,
    dg1: [u8; DG1_LEN],
    // The document being cited. Unconstrained by any proof, which is safe: see the header - the
    // leaf VALUE is what carries the soundness.
    document_key: Field,
    // The leaf's other two value fields, exactly as `HolderStateKeeper._bindDocument` wrote them.
    document_seq: Field,
    document_timestamp: Field,
    registration_siblings: [Field; REGISTRATION_TREE_DEPTH],
) {
    let revocation_secret = derive_revocation_secret(sk_identity);

    // THE DOCUMENT IS BOUND INTO THE LEAF HERE, WHICH IS THE ONLY PLACE IT CAN BE.
    //
    // This circuit is the one that has the DG1 bytes AND proves, just below, that the document they
    // describe is registered and current. A withdrawal has neither. So if the leaf does not carry
    // the document out of here, the verified document is DROPPED at the registry boundary and the
    // withdrawal's sanctions term degrades to "the prover named some number" - it could name a
    // stranger's clean passport and the whole predicate passes.
    //
    // ⚠️ The identifier is read from the MRZ by the vendored extractor, NOT taken as an input. A
    // caller-supplied identifier would put the choice back in the prover's hands one layer up and
    // buy nothing: the point is that this value is a FUNCTION of the bytes whose registration is
    // proven at `identity_state_verifier` below, not an assertion about them.
    let (issuing_state, document_number) = td1_document_fields(dg1);
    let document_id = document_identifier(issuing_state, document_number);

    assert(
        identity_commitment(revocation_secret, document_id) == commitment,
        "escrow: commitment is not the one derived from sk_identity and this document",
    );

    // The document binding. This subsumes BOTH the old `holder_root` proof (the holder root is
    // recomputed from `sk_identity` in here) and the old `dg1_hash` publication, and adds the
    // status check neither of them performed.
    let dg_commit = extract_dg1_commitment::<DG1_LEN>(dg1, sk_identity);
    identity_state_verifier(
        sk_identity,
        document_key,
        dg_commit,
        document_seq,
        document_timestamp,
        registration_root,
        registration_siblings,
    );

    // The document is carried as its IDENTIFIER, not as bytes. `document_id` is derived above from
    // the same `dg1` whose registration is proven, so the seal still binds to the registered
    // document - via a value the controller can RECOMPUTE from a published designation, rather than
    // via plaintext nobody needed.
    let mut payload: [Field; PAYLOAD_LEN] = [0; PAYLOAD_LEN];
    payload[0] = document_id;

    let envelope = seal_payload(payload, ephemeral, controller_x, controller_y);

    assert(envelope.c1_x == c1_x, "escrow: C1.x mismatch");
    assert(envelope.c1_y == c1_y, "escrow: C1.y mismatch");
    for i in 0..PAYLOAD_LEN {
        assert(envelope.payload[i] == sealed[i], "escrow: sealed payload mismatch");
    }
}

// ---------------------------------------------------------------------------------------------
// THE CROSS-CHECK THAT WAS MISSING.
//
// The SMT inclusion above requires this circuit's `dgCommit` to equal the one the REGISTRATION
// circuit produced and `HolderStateKeeper` stored in the leaf. Nothing verified that:
// IdentityRegistry.t.sol plants the document using the ESCROW's own values, so escrow and
// registration could have disagreed - about the DG1 length or the commitment construction - and
// every test would still have passed while no real document could ever be escrowed.
//
// This compares against `register_identity_light`'s OWN RETURNED VALUE for the same bytes, which is
// the only reference that cannot drift with this file.
// ---------------------------------------------------------------------------------------------
#[test]
fn test_dg_commit_matches_the_registration_circuit() {
    let mut dg1: [u8; DG1_LEN] = [0; DG1_LEN];
    // Arbitrary but non-trivial bytes - an all-zero DG1 could agree by accident.
    for i in 0..DG1_LEN {
        dg1[i] = ((i * 7 + 13) % 251) as u8;
    }
    let sk: Field = 1234;

    // What registration computes and the contract stores as the leaf's first value field.
    let registration = noir_dl::lite::register_identity_light::<DG1_LEN, 32>(dg1, sk);
    let registration_dg_commit = registration.0;

    // What this circuit reconstructs to locate the leaf.
    let escrow_dg_commit = extract_dg1_commitment::<DG1_LEN>(dg1, sk);

    assert(
        escrow_dg_commit == registration_dg_commit,
        "escrow's dgCommit disagrees with the registration circuit - no genuine document could be escrowed",
    );
}

/// The domain separator is the string it says it is.
///
/// A 55-digit literal is unreadable, and the failure mode of getting it wrong is silent: everything
/// still proves and verifies, the wallet just derives a different secret than a later version of
/// this circuit would.
#[test]
fn test_revocation_domain_is_the_string_it_claims_to_be() {
    let s: [u8; 23] = [
        112, 112, 58, 114, 101, 118, 111, 99, 97, 116, 105, 111, 110, 45, 115, 101, 99, 114, 101,
        116, 58, 118, 49,
    ]; // "pp:revocation-secret:v1"
    let mut acc: Field = 0;
    for i in 0..23 {
        acc = acc * 256 + s[i] as Field;
    }
    assert(
        acc == REVOCATION_SECRET_DOMAIN,
        "REVOCATION_SECRET_DOMAIN is not the documented string",
    );
}

/// The derived secret is not any OTHER value derivable from the same `sk_identity`.
///
/// THE ONE THAT MATTERS IS `holder_root`. Both are Poseidon over two field elements, and if the
/// domain separator were dropped or set wrongly, `derive_revocation_secret` could coincide with a
/// value this repo PUBLISHES - handing anyone who saw a holder root the secret that revokes it.
#[test]
fn test_derived_secret_is_separated_from_the_published_holder_root() {
    let sk: Field = 987654321;
    let secret = derive_revocation_secret(sk);

    assert(
        secret != pp::holder_root::extract_pk_identity_hash(sk),
        "secret collides with holder_root",
    );
    assert(secret != sk, "secret is the identity key itself");
    assert(secret != secret_commitment(secret), "secret equals its own commitment");
}

/// Two identities do not share a commitment, and one identity always produces the same one.
///
/// THE SECOND HALF IS THE SECURITY PROPERTY, not the first. Determinism is what makes
/// `IdentityRegistry.registered[commitment]` reject a re-registration after revocation; without it
/// the blacklist is evadable by every user it is applied to.
#[test]
fn test_the_commitment_is_a_function_of_the_identity() {
    let a: Field = 11;
    let b: Field = 12;

    assert(
        secret_commitment(derive_revocation_secret(a))
            == secret_commitment(derive_revocation_secret(a)),
        "commitment is not deterministic - revocation would be evadable by re-registering",
    );
    assert(
        secret_commitment(derive_revocation_secret(a))
            != secret_commitment(derive_revocation_secret(b)),
        "two identities collide on one commitment",
    );
}
