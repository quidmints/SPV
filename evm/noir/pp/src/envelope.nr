// Sealed envelope: hashed ElGamal over Baby Jubjub, for escrowing the revocation secret.
//
// WHAT THIS IS FOR (sec. 2.13c-f). The blacklist's CONTENTS must stay confidential, but a
// non-inclusion proof needs a PUBLIC set to build a path against. That is resolved by publishing a
// set whose ENTRIES are opaque: each listed identity appears as `Poseidon(s)` for a per-identity
// revocation secret `s`. Anyone can prove absence; nobody but the controller can tell WHO is
// present.
//
// THE HOLE THAT MAKES THIS FILE NECESSARY. If `s` were freely chosen, a user would simply pick one
// the controller has never seen, and their absence from the list would be guaranteed forever - the
// check becomes vacuous. So the controller must be ABLE to compute `Poseidon(s)` for anyone. That
// requires it to learn `s`.
//
// WHY SEALED-AND-POSTED RATHER THAN HANDED OVER. Any scheme where the controller ATTESTS to `s` at
// registration gives it a refusal lever: decline to sign, and the user can never withdraw -
// censorship by inaction, indistinguishable from being slow. That is precisely the failure the
// blacklist design exists to remove, and it must not re-enter through the escrow step. So the user
// SEALS `s` to the controller's published key and POSTS the ciphertext on-chain. There is no
// approval step, hence nothing to withhold.
//
// WHY HASHED ELGAMAL AND NOT TEXTBOOK ELGAMAL. Textbook ElGamal encrypts a POINT (C2 = M + r*PK),
// which would force `s` to be encoded as a curve point and decoded on the way out. Hashing the
// shared secret to a field mask instead (C2 = s + Poseidon(r*PK)) keeps `s` a plain field element,
// costs one hash instead of a point encoding, and lets a whole PAYLOAD ride on ONE pair of scalar
// multiplications - see `seal_payload`. The scalar mults dominate the circuit, so additional sealed
// fields are nearly free.

use crate::jubjub::mul_point;
use poseidon::poseidon::PoseidonHasher;
use std::hash::Hasher;

/// Baby Jubjub's generator, as used by `priv_to_pub` and @iden3/js-crypto's `babyJub.Base8`.
global BASE_X: Field = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
global BASE_Y: Field = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

/// A sealed envelope. `c1` is the ephemeral public point; `payload` is the masked plaintext.
pub struct Envelope<let N: u32> {
    pub c1_x: Field,
    pub c1_y: Field,
    pub payload: [Field; N],
}

/// The public commitment to a revocation secret.
///
/// This is BOTH the value bound into the registered-identity leaf (so a withdrawal proves, via an
/// inclusion proof it already performs, that its `s` is the escrowed one) AND the key under which
/// the controller lists a revoked identity. One value serving both roles is what lets the
/// withdrawal circuit add only a couple of hashes rather than a whole second tree.
pub fn secret_commitment(revocation_secret: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(revocation_secret);
    hasher.finish()
}

/// The registered-identity leaf: a revocation secret bound to the DOCUMENT it was escrowed against.
///
/// ⚠️ THE SECOND FIELD IS WHAT MAKES THE SANCTIONS TERM MEAN ANYTHING, AND WITHOUT IT THAT TERM IS
/// VACUOUS. `escrow_envelope` proves the holder's document is registered, but the leaf used to
/// commit to `sk_identity` ALONE - so the document was verified and then dropped. A withdrawal could
/// prove "some registered identity" and then name ANY document number for the blacklist check,
/// including a stranger's clean one. Binding the document here is what forces the number checked
/// against the blacklist to be the number that was actually escrowed: change it and the commitment
/// changes, and the inclusion proof against `identity_root` fails.
///
/// ⛔ It does NOT reveal the document. The leaf is a Poseidon hash and the identifier is a private
/// witness on both sides; what changes is that the prover can no longer CHOOSE it.
///
/// `document_id` is `blacklist::document_identifier(issuing_state, document_number)` - the same
/// construction the published list is keyed by, or the exclusion proof would be against a key
/// nobody ever inserts. See `blacklist.nr` for why that pairing is the whole predicate.
pub fn identity_commitment(revocation_secret: Field, document_id: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(revocation_secret);
    hasher.write(document_id);
    hasher.finish()
}

/// The per-index mask derived from a shared secret point.
///
/// INDEXED so that a payload of several fields cannot have its elements PERMUTED or REPLAYED across
/// positions: without the index every slot would share one mask, and swapping two ciphertext fields
/// would decrypt to a swapped - but perfectly valid-looking - plaintext.
fn mask(shared_x: Field, shared_y: Field, index: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(shared_x);
    hasher.write(shared_y);
    hasher.write(index);
    hasher.finish()
}

/// Seal `payload` to the controller's public key under ephemeral scalar `ephemeral`.
///
/// THE `ephemeral != 0` ASSERTION IS LOAD-BEARING AND IS NOT A SANITY CHECK. `mul_point(P, 0)`
/// returns this ladder's empty-accumulator sentinel `(0,0)` - measured, see
/// jubjub.nr::test_mul_point_by_zero_returns_the_sentinel_not_the_identity - for EVERY base point.
/// So with `ephemeral = 0` the shared secret is `(0,0)` regardless of whose key is being sealed to,
/// the mask collapses to the constant `Poseidon(0, 0, i)`, and the payload is readable by anyone who
/// looks. It would still produce a well-formed envelope that passes every other check, which is
/// exactly why it has to be rejected here rather than assumed away.
pub fn seal_payload<let N: u32>(
    payload: [Field; N],
    ephemeral: Field,
    controller_x: Field,
    controller_y: Field,
) -> Envelope<N> {
    assert(ephemeral != 0, "envelope: ephemeral scalar must be non-zero");

    let c1 = mul_point(BASE_X, BASE_Y, ephemeral);
    let shared = mul_point(controller_x, controller_y, ephemeral);

    let mut sealed: [Field; N] = [0; N];
    for i in 0..N {
        sealed[i] = payload[i] + mask(shared.0, shared.1, i as Field);
    }

    Envelope { c1_x: c1.0, c1_y: c1.1, payload: sealed }
}

/// Open an envelope with the controller's PRIVATE key.
///
/// Present so the sealing direction can be tested against a real round trip rather than against
/// hand-copied constants - a mask that is wrong in both directions would otherwise look correct.
/// The controller runs this OFF-CHAIN; no circuit proves it.
pub fn open_payload<let N: u32>(
    envelope: Envelope<N>,
    controller_secret: Field,
) -> [Field; N] {
    let shared = mul_point(envelope.c1_x, envelope.c1_y, controller_secret);

    let mut opened: [Field; N] = [0; N];
    for i in 0..N {
        opened[i] = envelope.payload[i] - mask(shared.0, shared.1, i as Field);
    }

    opened
}

// ---------------------------------------------------------------------------------------------
// TESTS
// ---------------------------------------------------------------------------------------------

// A controller keypair. The secret is arbitrary; the point is @iden3/js-crypto's
// babyJub.mulPointEScalar(babyJub.Base8, CONTROLLER_SK), so the curve arithmetic here is pinned to
// the same implementation the wallet and HolderStateKeeper agree with.
global CONTROLLER_SK: Field = 1234;
global CONTROLLER_X: Field =
    4880901335776166390443888589907570248644423541468541082967598048550539024543;
global CONTROLLER_Y: Field =
    6509666988291764283313685078036329297907336602650572952945826675203643401307;

#[test]
fn test_controller_key_matches_babyjub() {
    // If this drifts, every envelope below is sealed to a key nobody holds.
    let pk = mul_point(BASE_X, BASE_Y, CONTROLLER_SK);
    assert(pk.0 == CONTROLLER_X, "controller pubkey x disagrees with @iden3/js-crypto");
    assert(pk.1 == CONTROLLER_Y, "controller pubkey y disagrees with @iden3/js-crypto");
}

#[test]
fn test_seal_then_open_roundtrips() {
    let payload = [42, 7, 999];
    let env = seal_payload(payload, 5555, CONTROLLER_X, CONTROLLER_Y);
    let opened = open_payload(env, CONTROLLER_SK);

    assert(opened[0] == 42, "roundtrip lost payload[0]");
    assert(opened[1] == 7, "roundtrip lost payload[1]");
    assert(opened[2] == 999, "roundtrip lost payload[2]");
}

#[test]
fn test_ciphertext_actually_hides_the_payload() {
    // A mask that was accidentally zero, or an addition that was dropped, would round-trip
    // PERFECTLY while encrypting nothing. So assert the ciphertext differs from the plaintext.
    let payload = [42, 7, 999];
    let env = seal_payload(payload, 5555, CONTROLLER_X, CONTROLLER_Y);

    assert(env.payload[0] != 42, "payload[0] was not masked at all");
    assert(env.payload[1] != 7, "payload[1] was not masked at all");
    assert(env.payload[2] != 999, "payload[2] was not masked at all");
}

#[test]
fn test_each_slot_gets_a_DIFFERENT_mask() {
    // Identical plaintext in two slots must NOT produce identical ciphertext, or the index is not
    // reaching the mask and payload fields could be permuted undetectably.
    let env = seal_payload([77, 77], 5555, CONTROLLER_X, CONTROLLER_Y);
    assert(env.payload[0] != env.payload[1], "two slots shared one mask - index is not applied");
}

#[test]
fn test_a_different_ephemeral_gives_a_different_ciphertext() {
    // Ephemeral reuse across two envelopes would let an observer subtract them and recover the
    // DIFFERENCE of the plaintexts. This pins that the ephemeral genuinely feeds the mask.
    let a = seal_payload([42], 5555, CONTROLLER_X, CONTROLLER_Y);
    let b = seal_payload([42], 6666, CONTROLLER_X, CONTROLLER_Y);

    assert(a.payload[0] != b.payload[0], "ephemeral does not affect the ciphertext");
    assert((a.c1_x != b.c1_x) | (a.c1_y != b.c1_y), "ephemeral does not affect C1");
}

#[test]
fn test_the_wrong_controller_key_does_not_open_it() {
    let env = seal_payload([42], 5555, CONTROLLER_X, CONTROLLER_Y);
    let opened = open_payload(env, CONTROLLER_SK + 1);
    assert(opened[0] != 42, "an envelope opened under the WRONG secret still yielded the plaintext");
}

#[test(should_fail_with = "envelope: ephemeral scalar must be non-zero")]
fn test_zero_ephemeral_is_rejected() {
    let _ = seal_payload([42], 0, CONTROLLER_X, CONTROLLER_Y);
}

#[test]
fn test_zero_ephemeral_would_have_leaked_the_payload() {
    // WHY the assertion above is not merely defensive. Reproduce what a zero ephemeral would
    // produce, WITHOUT going through seal_payload's guard, and show the mask is a public constant
    // that anyone can recompute with no secret at all - so the sealed value falls straight out.
    let shared_if_zero = mul_point(CONTROLLER_X, CONTROLLER_Y, 0);
    assert(shared_if_zero.0 == 0, "sentinel x changed");
    assert(shared_if_zero.1 == 0, "sentinel y changed");

    // Anyone can compute this: it involves no secret and no key.
    let public_mask = mask(0, 0, 0);
    let what_c2_would_be = 42 + public_mask;
    assert(what_c2_would_be - public_mask == 42, "the payload is trivially recoverable, as claimed");
}

#[test]
fn test_secret_commitment_is_deterministic_and_separating() {
    assert(secret_commitment(9) == secret_commitment(9), "commitment is not deterministic");
    assert(secret_commitment(9) != secret_commitment(10), "two secrets share one commitment");
}

/// Domain separator for the NOTARY secret: the big-endian bytes of "pp:notary-secret:v1".
///
/// Checked against the string in `test_notary_domain_is_the_string_it_claims_to_be` - a magic number
/// nobody can re-derive is a magic number that gets copied wrong.
global NOTARY_SECRET_DOMAIN: Field = 2507459921430853321618988341583531743668500017;

/// A notary's secret, DERIVED from their identity key rather than generated separately.
///
/// WHY DERIVED (sec. 2.18au). `notary_action` first took a free `notary_secret`, which quietly
/// invented a THIRD thing for a person to keep: `sk_identity` for their identity, the escrowed
/// revocation secret for the pool, and now a notary key. A secret that can be lost independently is
/// a way to lose a professional role independently - and it is unnecessary, because a notary is
/// already a registered identity in this system. This is exactly the shape `derive_revocation_secret`
/// already uses, and reusing it means a notary keeps ONE key, the same one every other user keeps.
///
/// THE DOMAIN SEPARATOR IS WHAT MAKES IT SAFE. `TitleLedger` deliberately refuses to reuse the pool
/// commitment, because publishing that value would link a notary's public professional role to their
/// private financial identity. Deriving under a DIFFERENT domain gives a commitment that is an
/// unrelated field element: nobody without `sk_identity` can connect the two, so the role is
/// revocable through the same identity machinery without the linkage the pool exists to prevent.
pub fn derive_notary_secret(sk_identity: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(sk_identity);
    hasher.write(NOTARY_SECRET_DOMAIN);
    hasher.finish()
}

#[test]
fn test_notary_domain_is_the_string_it_claims_to_be() {
    let s: [u8; 19] = [
        112, 112, 58, 110, 111, 116, 97, 114, 121, 45, 115, 101, 99, 114, 101, 116, 58, 118, 49,
    ]; // "pp:notary-secret:v1"
    let mut acc: Field = 0;
    for i in 0..19 {
        acc = acc * 256 + s[i] as Field;
    }
    assert(acc == NOTARY_SECRET_DOMAIN, "NOTARY_SECRET_DOMAIN is not the documented string");
}

/// THE SEPARATION PROPERTY, and the whole reason a domain separator exists. A notary's commitment
/// must not equal their POOL commitment, or the ledger would publish the very link
/// `TitleLedger`'s own comment refuses to publish.
#[test]
fn test_the_notary_commitment_is_unrelated_to_the_pool_commitment() {
    let sk: Field = 987654321;

    // The pool's derivation, reproduced here rather than imported: escrow_envelope is a binary
    // crate, so this states the value it must differ from instead of depending on it.
    let mut pool_hasher = PoseidonHasher::default();
    pool_hasher.write(sk);
    pool_hasher.write(10769458381189379141499981179385028620184879844130715185); // "pp:revocation-secret:v1"
    let pool_secret = pool_hasher.finish();

    let notary_secret = derive_notary_secret(sk);

    assert(notary_secret != pool_secret, "the notary secret collides with the pool revocation secret");
    assert(
        secret_commitment(notary_secret) != secret_commitment(pool_secret),
        "the notary commitment equals the pool commitment - the roles are linkable",
    );
    assert(notary_secret != sk, "the notary secret is the identity key itself");
}

/// Deterministic: one identity yields one notary commitment, so revoking it revokes the person
/// rather than one of several keys they might hold.
#[test]
fn test_the_notary_secret_is_deterministic_and_identity_specific() {
    assert(derive_notary_secret(42) == derive_notary_secret(42));
    assert(derive_notary_secret(42) != derive_notary_secret(43));
}

// -------------------------------------------------------------------------------------------------
// THE BINDING PROPERTY, TESTED IN BOTH DIRECTIONS.
//
// One test asserts the leaf MOVES when the document does - that is what stops a prover naming a
// clean document. The other asserts it moves when the SECRET does, which is the property
// `secret_commitment` already had and which the second field must not have quietly destroyed.
// -------------------------------------------------------------------------------------------------
#[test]
fn test_the_identity_leaf_moves_with_the_document() {
    let s = 7;
    assert(
        identity_commitment(s, 111) != identity_commitment(s, 222),
        "one secret gives one leaf for two different documents - the sanctions term is vacuous",
    );
}

#[test]
fn test_the_identity_leaf_still_moves_with_the_secret() {
    let d = 111;
    assert(
        identity_commitment(7, d) != identity_commitment(8, d),
        "two secrets share one leaf",
    );
}

/// A two-field Poseidon is not the one-field Poseidon of the same secret. Asserted because the
/// migration depends on it: if these collided, an OLD leaf would satisfy a NEW inclusion proof and
/// the binding could be bypassed by simply presenting a pre-binding registration.
#[test]
fn test_the_bound_leaf_is_not_the_unbound_leaf() {
    assert(
        identity_commitment(7, 0) != secret_commitment(7),
        "a document-bound leaf collides with an unbound one; pre-binding registrations would pass",
    );
}
