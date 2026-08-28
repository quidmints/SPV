// Title-holder proof - the privacy-preserving half of the title-ledger design (2026-07-24, see
// backend/contracts/contracts/title/TitleLedger.sol's header for the full rationale).
//
// DELIBERATELY NOT reusing pp::identity_asp's holder_root directly as the on-chain commitment:
// holder_root (Poseidon(pubkey(sk_identity))) is a FIXED, durable per-identity value used
// everywhere else in this fusion (HolderStateKeeper leaves, the PP identity ASP tree). If a
// title's public holder-commitment were holder_root itself, anyone could compare that one field
// across every title-ledger entry and correlate "does the same person hold titles A and B" -
// exactly the linkage the user's stated goal ("can never be traced") forbids. Instead the
// commitment is `Poseidon2(holder_root, title_id)` - a title-specific derivation (same pattern
// HolderStateKeeper already uses: `Poseidon2(documentKey, holderRoot)` for its own leaf index),
// so two commitments for the same identity on different titles are unrelated field elements with
// no public link between them.
//
// Reused for TWO purposes by TitleLedger.sol: (1) authorizing a transfer (prove you are the
// current holder, supply a new commitment), and (2) proving loan-collateral eligibility to an
// external lender (prove you are the current holder, reveal nothing else) - same circuit, same
// public inputs, different caller intent.
use crate::holder_root::extract_pk_identity_hash;
use poseidon::poseidon::bn254;

pub struct TitleHolderProof {
    pub holder_commitment: Field,
}

/// Proves `sk_identity` derives the SAME holder_commitment already recorded on-chain for
/// `title_id` (passed in as the public `expected_commitment`, e.g.
/// TitleLedger.holderCommitment(title_id)). Returns the recomputed commitment so the caller can
/// assert equality against a DIFFERENT title's commitment too, if ever needed - though
/// TitleLedger.sol always compares against the same title's stored value.
pub fn title_holder_proof(sk_identity: Field, title_id: Field, expected_commitment: Field) -> TitleHolderProof {
    let holder_root = extract_pk_identity_hash(sk_identity);
    let holder_commitment = bn254::hash_2([holder_root, title_id]);
    assert(holder_commitment == expected_commitment);

    TitleHolderProof { holder_commitment }
}

// Cross-checked EMPIRICALLY (2026-07-24) against an INDEPENDENT computation in Node using
// @iden3/js-crypto's babyJub + Poseidon (the wallet's real primitives) - not a tautological
// self-comparison (computing bn254::hash_2 twice would just prove the function agrees with
// itself). Run through nargo and PROVED END-TO-END on 2026-07-26: this exact vector is the witness
// behind the real Honk proof that verifies against the generated Solidity verifier in
// backend/contracts/test/title/TitleHolderHonkVerifier.t.sol (sec. 2.3).
//   sk_identity = 1234  =>  holder_root = 11639338456537070031828088151704016282968167813614481831572112488559037365741
//                           (same value identity_asp.nr's own test vector already established)
//   title_id = 777       =>  holder_commitment = Poseidon2(holder_root, 777)
//                         = 15178211280200039192911808844426622693395308695089241633877037774023814804545
#[test]
fn test_matches_wallet_derivation() {
    let sk_identity: Field = 1234;
    let title_id: Field = 777;
    let expected_commitment: Field =
        15178211280200039192911808844426622693395308695089241633877037774023814804545;

    let result = title_holder_proof(sk_identity, title_id, expected_commitment);
    assert(result.holder_commitment == expected_commitment);
}
