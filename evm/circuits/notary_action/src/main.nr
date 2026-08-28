// Anonymous notary authorisation.
//
// WHAT THIS REPLACES AND WHY (sec. 2.18am). `TitleLedger` used to take `address notary_` and check
// an ECDSA signature against it. That named the acting notary three ways at once: a public
// `TitleEntry.notary` field, an `address indexed notary` topic on three events - `indexed`, so
// "every title this notary touched" was ONE log query - and a public `notaryIdentityOf` map from
// signing key to identity. The funding application claimed the opposite, for people it also said
// "can be punished for serving a system like this".
//
// NO NEW STRUCTURE, AND DELIBERATELY SO. *"there is no governance design. we are inheriting the ASP
// structure of PP, why should it be any extension of that"* (user, 2026-07-31). Correct, and it
// removes the hardest part of the problem. An earlier framing had the notary's identity sealed and
// "openable by a quorum of custodians against a proven fault" - which needs a custodian set, a fault
// procedure, and an answer to what stops the quorum colluding. None of that exists, and a quorum
// whose membership is undefined is not a privacy mechanism, it is a promise.
//
// THE ASP ANSWER TO "PROVEN FAULT" IS REVOCATION, NOT DEANONYMISATION. Privacy Pools does not open a
// bad actor's identity; it EXCLUDES them from the association set. The identity registry already
// works exactly this way - `withdraw_identity` proves inclusion at STATUS_CLEAN, and revoking writes
// a non-zero value that no clean-status proof can equal. A revoked notary simply stops being able to
// prove anything. Nobody needs to learn who they were.
//
// So this circuit is `withdraw_identity`'s identity section with the note-spending half removed:
// prove knowledge of the secret behind a commitment that sits in the notary tree carrying
// STATUS_CLEAN, bound to the action being authorised.
use pp::envelope::{derive_notary_secret, secret_commitment};
use pp::smt::smt_verifier_full;

/// MUST equal the notary registry contract's `treeHeight_` and the wallet's depth constant. 32
/// matches the identity registry for the same reason: raising a tree's depth later invalidates
/// every proof already issued and forces a migration.
global NOTARY_TREE_DEPTH: u32 = 32;

/// `fnc = 0` selects INCLUSION. Passing 1 would prove the OPPOSITE - that this commitment is ABSENT
/// from the notary tree - which is what a non-notary can prove and a notary cannot.
global SMT_INCLUSION: bool = false;

/// The value an active notary's leaf carries. Non-zero means revoked, and the value IS the
/// predicate, so one inclusion proof answers "is a notary" and "is not revoked" together.
///
/// Both ways this could be hollow are already tested in pp/src/smt.nr rather than assumed:
///   - an ABSENT key cannot be proven present with value 0 (else anyone at all passes)
///   - a leaf holding a NON-ZERO value cannot claim 0 (else revocation is escapable)
global STATUS_CLEAN: Field = 0;

fn main(
    // Root of the notary SMT, checked on-chain against the registry's own validity window - the
    // same rule as the identity registry, and required for the same reason: this tree carries
    // revocations, so an unbounded-age root would let a revoked notary act forever.
    notary_root: pub Field,
    // UNCONSTRAINED IN-CIRCUIT ON PURPOSE, exactly as `withdraw_identity`'s `context` is
    // (sec. 2.18ah). This carries keccak256 of the action being authorised - which title, which
    // operation, which ledger. Nothing else in this circuit says WHAT is being authorised, so
    // without it a proof minted for one title could be replayed against any other. There is nothing
    // to CHECK here: the value's meaning lives entirely in data only the contract holds, so
    // `TitleLedger` DERIVES it and passes its own value to the verifier in this slot rather than
    // comparing against the prover's. What the circuit owes is that the proof COMMITS to whatever
    // was passed, which `pub` gives in the transcript whether or not a gate reads it.
    action_context: pub Field,
    // The notary's IDENTITY key - the same `sk_identity` they already hold as an ordinary user of
    // this system. NOT a separate notary key (sec. 2.18au).
    //
    // An earlier version took a free `notary_secret`, which quietly invented a THIRD secret to keep:
    // `sk_identity`, the escrowed revocation secret, and a notary key. A secret that can be lost
    // independently is a way to lose a professional role independently, and it was unnecessary -
    // a notary is already a registered identity here. Deriving under a distinct domain separator
    // keeps the notary commitment unlinkable from the pool commitment, so the role is revocable
    // through the same machinery without publishing the link `TitleLedger` refuses to publish.
    sk_identity: Field,
    // Inclusion witness, straight from the registry's own getProof().
    siblings: [Field; NOTARY_TREE_DEPTH],
) {
    // Says "no gate reads this, and that is intended" in code rather than only in a comment. Without
    // it nargo warns `unused variable action_context` on every build, and a warning that is expected
    // forever is a warning nobody reads - so the day a public input goes unused BY ACCIDENT, the
    // diagnostic that would have caught it is already background noise. Costs no constraints.
    let _ = action_context;

    // The key is DERIVED, never a free input. Letting the prover supply the commitment directly
    // would make this vacuous: every active notary's commitment is public in the tree, so they would
    // name one and act as them. Knowledge of the preimage is the whole gate - and the preimage is
    // now two derivations deep, from the identity key nobody else holds.
    let commitment = secret_commitment(derive_notary_secret(sk_identity));

    let active = smt_verifier_full::<NOTARY_TREE_DEPTH>(
        notary_root,
        commitment,
        STATUS_CLEAN,
        0,
        0,
        false,
        SMT_INCLUSION,
        siblings,
    );
    assert(active == true, "not an active notary: unregistered, revoked, or a bad inclusion witness");
}

// =================================================================================================
// TESTS. Written with the circuit rather than after it, because this one replaces a security check
// that DID work - an ECDSA signature naming a specific address. Anonymity that also loses the
// authorisation would be a worse outcome than the exposure it fixes.
//
// The witness is built in-circuit from the same primitives the circuit uses, as sec. 2.18ah built
// withdraw_identity's: a single-leaf tree whose root IS the leaf hash, with all-zero siblings.
// Nothing is faked and no fixture is needed.
mod wiring_tests {
    use super::{main, NOTARY_TREE_DEPTH, STATUS_CLEAN};
    use pp::envelope::{derive_notary_secret, secret_commitment};
    use poseidon::poseidon::PoseidonHasher;
    use std::hash::Hasher;

    global AN_IDENTITY_KEY: Field = 8675309;
    global AN_ACTION: Field = 424242;

    /// The single-leaf root: Poseidon(key, value, 1), the leaf convention `smt_verifier_full` uses.
    /// Recomputed here rather than imported so that a change to that convention breaks these tests
    /// loudly instead of letting them agree with a moved target.
    fn root_holding(sk_identity: Field, status: Field) -> Field {
        let mut hasher = PoseidonHasher::default();
        hasher.write(secret_commitment(derive_notary_secret(sk_identity)));
        hasher.write(status);
        hasher.write(1);
        hasher.finish()
    }

    #[test]
    fn test_an_active_notary_can_authorise_an_action() {
        main(root_holding(AN_IDENTITY_KEY, STATUS_CLEAN), AN_ACTION, AN_IDENTITY_KEY, [0; NOTARY_TREE_DEPTH]);
    }

    /// THE POINT OF THE WHOLE CIRCUIT. Anonymity must not become "anyone may act": someone who does
    /// not know a registered notary's secret has to fail, even though the root is public and the
    /// commitments in it are public too.
    #[test(should_fail_with = "not an active notary")]
    fn test_a_stranger_cannot_authorise_an_action() {
        main(root_holding(AN_IDENTITY_KEY, STATUS_CLEAN), AN_ACTION, AN_IDENTITY_KEY + 1, [0; NOTARY_TREE_DEPTH]);
    }

    /// REVOCATION IS THE FAULT MECHANISM - the reason no custodian quorum is needed. A leaf holding
    /// a non-zero status cannot prove STATUS_CLEAN, so a revoked notary stops being able to act
    /// without anyone learning who they were.
    #[test(should_fail_with = "not an active notary")]
    fn test_a_revoked_notary_cannot_authorise_an_action() {
        main(root_holding(AN_IDENTITY_KEY, 1), AN_ACTION, AN_IDENTITY_KEY, [0; NOTARY_TREE_DEPTH]);
    }

    /// A notary who is genuinely active in ANOTHER tree cannot act against this root. This is what
    /// stops a stale or foreign snapshot being presented - the per-jurisdiction separation task #12
    /// depends on.
    #[test(should_fail_with = "not an active notary")]
    fn test_a_proof_against_the_wrong_root_fails() {
        main(root_holding(AN_IDENTITY_KEY + 99, STATUS_CLEAN), AN_ACTION, AN_IDENTITY_KEY, [0; NOTARY_TREE_DEPTH]);
    }

    /// The action context is a PASS-THROUGH and must not be constrained here - any value proves,
    /// because `TitleLedger` substitutes its own derived value at verification time. If this ever
    /// started failing, the contract-side substitution would have silently become the only thing
    /// binding a proof to an action, which is the defect sec. 2.18ah fixed in the withdrawal path.
    #[test]
    fn test_any_action_context_proves_because_the_contract_substitutes_its_own() {
        main(root_holding(AN_IDENTITY_KEY, STATUS_CLEAN), 0, AN_IDENTITY_KEY, [0; NOTARY_TREE_DEPTH]);
        main(root_holding(AN_IDENTITY_KEY, STATUS_CLEAN), AN_ACTION + 7, AN_IDENTITY_KEY, [0; NOTARY_TREE_DEPTH]);
    }
}
