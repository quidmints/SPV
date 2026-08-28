// Commitment hasher - faithful port of PP's commitment.circom.
//
//   nullifierHash   = Poseidon1(nullifier)
//   precommitment   = Poseidon2(nullifier, secret)
//   commitment      = Poseidon3(value, label, precommitment)
//
// circomlib-Poseidon (fixed arity) via noir-lang/poseidon - identical to the wallet's @iden3
// derivation (src/pp/notes.ts) and the on-chain poseidon-solidity, so commitments match end-to-end.
// noir-lang/poseidon's own bn254.nr states it is "Consistent with Circom's implementation".
//
// CONFIRMED on dev machine (nargo 1.0.0-beta.1, poseidon tag v0.1.0): import path is
// `poseidon::poseidon::bn254` (package `poseidon` re-exports `pub mod poseidon;` in lib.nr, which
// itself contains the `bn254` submodule) - NOT `poseidon::bn254`.
use poseidon::poseidon::bn254;

pub struct Commitment {
    pub commitment: Field,
    pub nullifier_hash: Field,
}

pub fn commitment_hasher(value: Field, label: Field, nullifier: Field, secret: Field) -> Commitment {
    let nullifier_hash = bn254::hash_1([nullifier]);
    let precommitment = bn254::hash_2([nullifier, secret]);
    let commitment = bn254::hash_3([value, label, precommitment]);

    Commitment { commitment, nullifier_hash }
}

// Differential test vector, cross-checked against poseidon-solidity's PoseidonT2/T3/T4 on
// 2026-07-01 (see PP-NOIR-FUSION.md P0 log) - the SAME functions PP's own PrivacyPool.sol calls
// (PoseidonT4.hash for the commitment), so this checks the exact on-chain computation.
#[test]
fn test_matches_poseidon_solidity() {
    let c = commitment_hasher(10, 20, 30, 40);
    assert(c.nullifier_hash == 7532086780038402662674345296860422071861903663404908958571451852914592667893);
    assert(c.commitment == 10718981984499290237711722178490140094119483277114902091282087901089143679380);
}
