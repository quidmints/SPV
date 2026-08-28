// Identity-based withdraw circuit.
//
// ONE IDENTITY TREE, AND NO sk_identity (sec. 2.13k). This circuit previously proved TWO
// separate things about identity: inclusion of `holder_root` in an ASP tree, and non-inclusion of
// that same value in a separate revocation tree. Both collapse into a SINGLE INCLUSION PROOF once
// status lives in the leaf VALUE: `commitment -> 0` means registered and clean, and a non-zero
// value is the revocation predicate. There is no state a revoked identity can prove.
//
// MEASURED: 43,772 -> 24,812 ACIR opcodes, -43%. Two sources - the ASP scalar multiplication
// disappears entirely (~11.8k, since `holder_root` is no longer derived here), and a LeanIMT
// inclusion plus an SMT exclusion (~18.5k combined) become one SMT inclusion (~11.9k).
//
// WHY DROPPING sk_identity IS SOUND. Identity is proven ONCE, at escrow: `escrow_envelope` proves
// `holder_root` derives from `sk_identity`, binds the authenticated MRZ, and IdentityRegistry
// additionally requires that MRZ to be a document already registered through the ICAO-verified
// path. A commitment can therefore only enter the tree backed by a real, uniquely-bound passport.
// By withdrawal time, knowing the escrowed secret IS the proof of clearance - and knowing it
// authorises nothing else, since spending a note still requires that note's own secrets.
//
// PUBLIC I/O pinned to ProofLib.WithdrawProof.pubSignals - EIGHT elements: seven, plus the taint
// root that carries the Privacy Pools EXCLUSION predicate (2.18gz-unify).
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] identity_root   <- replaces asp_root AND revocation_root
//   [2] withdrawn_value         [6] context
//                               [7] blacklist_root    <- non-association (sec. 2.18gz-unify)
//   [3] state_root
// `asp_tree_depth` is gone with the LeanIMT identity tree; the SMT depth is FIXED, so there is no
// prover-supplied depth to reason about at all.
//
// `context` is a pass-through public signal, and the pass-through IS the mechanism. PrivacyPool
// does not compare its own keccak256(abi.encode(withdrawal, scope)) % SNARK_SCALAR_FIELD against
// what the prover put here - it SUBSTITUTES it, handing the derived value to the verifier in slot
// [6] and ignoring the proof's. So the circuit owes only that the proof be BOUND to whatever was
// passed, which `pub` guarantees, and a proof made for another withdrawal fails inside the verifier
// rather than at a check someone could delete.
use pp::withdraw::{IDENTITY_TREE_DEPTH, verify_withdrawal, WithdrawSignals, WithdrawWitness};

fn main(
    new_commitment: pub Field,
    existing_nullifier_hash: pub Field,
    withdrawn_value: pub Field,
    state_root: pub Field,
    state_tree_depth: pub Field,
    identity_root: pub Field,
    context: pub Field,
    blacklist_root: pub Field,
    value: Field,
    label: Field,
    nullifier: Field,
    secret: Field,
    state_leaf_index: Field,
    state_siblings: [Field; 32],
    out_nullifier: Field,
    out_secret: Field,
    revocation_secret: Field,
    identity_siblings: [Field; IDENTITY_TREE_DEPTH],
    blacklist_siblings: [Field; IDENTITY_TREE_DEPTH],
    blacklist_old_key: Field,
    blacklist_old_value: Field,
    blacklist_is_old0: bool,
    document_id: Field,
    document_siblings: [Field; IDENTITY_TREE_DEPTH],
    document_old_key: Field,
    document_old_value: Field,
    document_is_old0: bool,
) {
    verify_withdrawal(
        WithdrawSignals {
            new_commitment,
            existing_nullifier_hash,
            withdrawn_value,
            state_root,
            state_tree_depth,
            identity_root,
            context,
            blacklist_root,
        },
        WithdrawWitness {
            value,
            label,
            nullifier,
            secret,
            state_leaf_index,
            state_siblings,
            out_nullifier,
            out_secret,
            revocation_secret,
            identity_siblings,
            blacklist_siblings,
            blacklist_old_key,
            blacklist_old_value,
            blacklist_is_old0,
            document_id,
            document_siblings,
            document_old_key,
            document_old_value,
            document_is_old0,
        },
    );
}
