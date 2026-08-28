// Compiled entry point for pp::title_holder::title_holder_proof - see pp/src/title_holder.nr for
// the gadget itself and the full rationale (why the public commitment is title-specific, not the
// raw holder_root).
//
// COMPILED, PROVED AND VERIFIED ON-CHAIN (2026-07-26). This header previously read "NOT YET
// nargo-compiled/tested"; that is no longer true. `nargo compile` is clean (circuit size 11,788)
// and a real `bb` proof over pp::title_holder's own published test vector verifies against the
// generated Solidity verifier - see backend/contracts/test/title/TitleHolderHonkVerifier.t.sol
// and sec. 2.3. The gadget test had already cross-checked the underlying Poseidon derivation
// against the wallet's iden3 js-crypto primitives independently.
//
// PUBLIC I/O ordering pinned to TitleLedger.sol's _verifyHolderProof:
//   [0] expected_commitment  (TitleLedger.holderCommitment(titleId) - the on-chain stored value)
//   [1] title_id
use pp::title_holder::title_holder_proof;

fn main(expected_commitment: pub Field, title_id: pub Field, sk_identity: Field) {
    let _proof = title_holder_proof(sk_identity, title_id, expected_commitment);
}
