//! The withdrawal statement, extracted so it exists ONCE.
//!
//! WHY THIS FILE EXISTS. `withdraw_identity` proves a withdrawal and exposes seven `pub` signals in
//! the order `ProofLib.WithdrawProof.pubSignals` pins. The IVC/chonk path needs the SAME statement
//! with a different calling convention: the app circuit returns its signals as `return_data` so a
//! kernel can consume them through `call_data`, rather than exposing them as public inputs.
//!
//! Two `main`s, one statement. Copying the body instead would put the money path in two places, and
//! the copies would drift the first time either is touched - which is exactly how a fold that
//! verifies a DIFFERENT statement than the contract checks would arrive, silently.
//!
//! THE EXTRACTION MUST NOT CHANGE THE EXISTING CIRCUIT, and that is checkable rather than arguable:
//! `bb write_vk -t evm` on `withdraw_identity` produced sha256 `366f53d7...` before this file
//! existed. If it still does, the constraint system is untouched and every generated verifier,
//! fixture and committed proof remains valid. If it does not, this extraction is wrong and must be
//! reverted rather than re-pinned.
use crate::commitment::commitment_hasher;
use crate::envelope::identity_commitment;
use crate::lean_imt::lean_imt_inclusion;
use crate::blacklist::{blacklist_key, DOMAIN_DOCUMENT, DOMAIN_LABEL};
use crate::smt::smt_verifier_full;

/// SMT depth of the identity registry. MUST equal IdentityRegistry's constructor `treeHeight_` and
/// the wallet's IDENTITY_TREE_DEPTH. A mismatch fails every proof with no useful diagnostic.
///
/// 32, not 20: this tree holds EVERY registered identity, not just revoked ones, so it is the large
/// tree. Depth 20 caps at ~1M identities and would be cheaper in-circuit (7,889 vs 11,856 opcodes),
/// but raising a tree's depth later invalidates every proof and forces a migration.
pub global IDENTITY_TREE_DEPTH: u32 = 32;

/// `fnc = 0` selects INCLUSION in smt_verifier_full. Named because passing 1 here would prove the
/// OPPOSITE - that the identity is absent from the registry - which is what an UNREGISTERED party
/// can prove and a registered one cannot.
global SMT_INCLUSION: bool = false;

/// `fnc = 1` selects EXCLUSION - proving a key is ABSENT. Named for the same reason as its twin:
/// passing `false` here would silently prove the opposite of what the taint check means.
global SMT_EXCLUSION: bool = true;

/// The value a clean identity carries. Non-zero means revoked, and the value IS the predicate.
global STATUS_CLEAN: Field = 0;

/// The seven signals, in `ProofLib.WithdrawProof.pubSignals` order. The ORDER is load-bearing in
/// both directions: the contract indexes these positionally, and `BatchCommitmentLib` folds them
/// positionally, so a reordering here produces a commitment the contract cannot reproduce.
pub struct WithdrawSignals {
    pub new_commitment: Field,
    pub existing_nullifier_hash: Field,
    pub withdrawn_value: Field,
    pub state_root: Field,
    pub state_tree_depth: Field,
    pub identity_root: Field,
    pub context: Field,
    /// Root of the TAINT set - deposits whose provenance is disqualifying. The withdrawal proves
    /// its `label` is NOT in it (sec. 2.18gz-unify).
    ///
    /// EXCLUSION, not inclusion, and the polarity is the point: an empty taint set admits everyone,
    /// so a stalled feed or an unreachable publisher fails OPEN. Upstream PP proved INCLUSION in an
    /// approved set, which fails closed - stop publishing and nobody withdraws.
    pub blacklist_root: Field,
}

/// The witness a withdrawal is proven against. Grouped into a struct only so both `main`s can pass
/// it through without restating eleven parameters; it is not a semantic boundary.
pub struct WithdrawWitness {
    pub value: Field,
    pub label: Field,
    pub nullifier: Field,
    pub secret: Field,
    pub state_leaf_index: Field,
    pub state_siblings: [Field; 32],
    pub out_nullifier: Field,
    pub out_secret: Field,
    pub revocation_secret: Field,
    pub identity_siblings: [Field; IDENTITY_TREE_DEPTH],
    /// Exclusion witness for `label` against `blacklist_root`. For an EMPTY taint set every field is
    /// zero with `blacklist_is_old0 = true` - proven in `smt::test_exclusion_against_an_empty_tree_is_
    /// the_zero_witness`, which is what makes the bootstrap free.
    pub blacklist_siblings: [Field; IDENTITY_TREE_DEPTH],
    pub blacklist_old_key: Field,
    pub blacklist_old_value: Field,
    pub blacklist_is_old0: bool,
    /// `document_identifier(issuing_state, document_number)` for the document this identity was
    /// escrowed against. NOT free input despite being a witness: it is hashed into the identity leaf
    /// (step 4), so naming a different document breaks the inclusion proof.
    pub document_id: Field,
    /// Exclusion witness for the DOCUMENT key against the SAME `blacklist_root`. Same zero-witness
    /// bootstrap as the label fields above.
    pub document_siblings: [Field; IDENTITY_TREE_DEPTH],
    pub document_old_key: Field,
    pub document_old_value: Field,
    pub document_is_old0: bool,
}

/// Prove one withdrawal. Constraint-for-constraint the body `withdraw_identity/src/main.nr` carried
/// before the extraction, in the same order, so the verification key is unchanged.
pub fn verify_withdrawal(signals: WithdrawSignals, w: WithdrawWitness) {
    // Says "no gate reads this, and that is intended" in code rather than in a comment. Without it
    // the compiler warns `unused variable context` on every build, and a warning that is expected
    // forever is a warning nobody reads - so the day a public input goes unused BY ACCIDENT, the
    // diagnostic that would have caught it is already background noise. Costs no constraints.
    let _ = signals.context;

    // 1. Existing note: reconstruct its commitment + nullifier hash, and prove membership in the
    // PP state tree at `state_root`. `state_tree_depth` is contract-selectable, capped at
    // MAX_TREE_DEPTH=32 on-chain, and taken directly as the actual depth - a false depth simply
    // fails to reconstruct `state_root`, so no separate range check is needed beyond
    // lean_imt_inclusion's own `assert(actual_depth <= MAX_DEPTH)`.
    let existing = commitment_hasher(w.value, w.label, w.nullifier, w.secret);
    assert(existing.nullifier_hash == signals.existing_nullifier_hash);
    let computed_state_root = lean_imt_inclusion(
        existing.commitment,
        w.state_leaf_index,
        w.state_siblings,
        signals.state_tree_depth as u32,
    );
    assert(computed_state_root == signals.state_root);

    // 2. Value conservation: existing value == withdrawn + carried into the change note.
    // Range-checked to 128 bits (ample for token amounts) via to_le_bits' own constraint, so the
    // subtraction below can't wrap the ~254-bit field and hide a fabricated balance.
    let _value_bits: [bool; 128] = w.value.to_le_bits();
    let _withdrawn_bits: [bool; 128] = signals.withdrawn_value.to_le_bits();
    let new_value = w.value - signals.withdrawn_value;
    let _new_value_bits: [bool; 128] = new_value.to_le_bits();

    // 3. Change note commitment.
    let out = commitment_hasher(new_value, w.label, w.out_nullifier, w.out_secret);
    assert(out.commitment == signals.new_commitment);

    // 4. REGISTERED AND NOT REVOKED, in one proof. The withdrawer must know the escrowed
    // `revocation_secret` whose commitment sits in the identity registry carrying STATUS_CLEAN.
    //
    // The key is DERIVED from the secret, never a free input. Letting the prover supply the key
    // directly would make this vacuous: they would name any clean identity's commitment - all of
    // which are public in the tree - and withdraw as someone else. Knowledge of the preimage is the
    // whole gate.
    // ⚠️ THE LEAF BINDS THE DOCUMENT, AND THAT IS WHAT MAKES STEP 6 MEAN ANYTHING. Committing to the
    // secret alone would let this prove "some registered identity" and then name ANY document for
    // the sanctions check - a stranger's clean passport - because nothing tied the number checked to
    // the number escrowed. See `envelope::identity_commitment`.
    let commitment = identity_commitment(w.revocation_secret, w.document_id);
    let cleared = smt_verifier_full::<IDENTITY_TREE_DEPTH>(
        signals.identity_root,
        commitment,
        STATUS_CLEAN,
        0,
        0,
        false,
        SMT_INCLUSION,
        w.identity_siblings,
    );
    assert(
        cleared == true,
        "identity is unregistered or revoked, or the inclusion witness is invalid",
    );

    // 5. NOT TAINTED. The deposit's `label` must be ABSENT from the taint set.
    //
    // This is the Privacy Pools paper's EXCLUSION branch - "my withdrawal does not come from one of
    // these deposits" - as opposed to the membership branch 0xbow deployed. Same object, opposite
    // failure direction: an allowlist that stops being published censors everyone, a blacklist that
    // stops being published admits everyone.
    //
    // KEYED ON `label`, which is already bound into both commitments above, so the prover cannot
    // present someone else's provenance. That binding is why this costs one SMT term and not a
    // redesign.
    //
    // ⚠️ SECOND USE OF THE SAME PRIMITIVE, AND THE LAST ONE THIS PREDICATE NEEDS. Identity uses it
    // with `fnc = false` (inclusion, status clean); this uses `fnc = true` (exclusion).
    // 🔑 **AN EARLIER NOTE HERE SAID SANCTIONS WOULD BE "THE SAME CALL AGAIN AGAINST A DIFFERENT
    // TREE - one proof shape, three predicates". IT IS ONE TREE AND ONE PREDICATE.** The key is
    // domain-separated (`blacklist.nr`), so chainalysis taint, address taint and sanctioned
    // documents are all non-membership in ONE root: one anchor, one activation window, and adding a
    // country's register is a DATA change rather than a code change.
    // ⚠️ The domain is not decoration - a passport number and a pool label are both `Field`s, and
    // without it a sanctioned document number could collide with an innocent label and blacklist it
    // while the tree stayed CORRECT.
    let untainted = smt_verifier_full::<IDENTITY_TREE_DEPTH>(
        signals.blacklist_root,
        blacklist_key(DOMAIN_LABEL, w.label),
        0,
        w.blacklist_old_key,
        w.blacklist_old_value,
        w.blacklist_is_old0,
        SMT_EXCLUSION,
        w.blacklist_siblings,
    );
    assert(
        untainted == true,
        "this deposit's label is blacklisted, or the exclusion witness is invalid",
    );

    // 6. NOT A SANCTIONED DOCUMENT. The escrowed document must be ABSENT from the same set.
    //
    // Same primitive, same root, same failure direction - only the DOMAIN differs. That is the whole
    // content of "one predicate": provenance taint and a sanctions listing are not two systems with
    // two roots and two activation windows, they are two keys in one tree, and a country's register
    // joins by being inserted rather than by being coded for.
    //
    // ⚠️ WHAT MAKES THIS NON-VACUOUS IS UPSTREAM, NOT HERE. `w.document_id` is a private witness, so
    // read in isolation this term looks like it checks a number the prover chose. It is bound at
    // step 4: the identity leaf is `Poseidon(revocation_secret, document_id)`, so a substituted
    // document produces a leaf that is not in `identity_root` and the withdrawal fails there. The
    // two terms are load-bearing only as a PAIR - separating them re-opens the hole.
    let unsanctioned = smt_verifier_full::<IDENTITY_TREE_DEPTH>(
        signals.blacklist_root,
        blacklist_key(DOMAIN_DOCUMENT, w.document_id),
        0,
        w.document_old_key,
        w.document_old_value,
        w.document_is_old0,
        SMT_EXCLUSION,
        w.document_siblings,
    );
    assert(
        unsanctioned == true,
        "this identity's document is blacklisted, or the exclusion witness is invalid",
    );
}
