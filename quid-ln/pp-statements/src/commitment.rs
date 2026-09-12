//! The note commitment and its nullifier hash — `commitment.circom` as the pool deployed it.

use crate::field::Fr;
use crate::poseidon::hash;

pub struct Commitment {
    pub commitment: Fr,
    pub nullifier_hash: Fr,
}

/// `commitment = Poseidon(value, label, Poseidon(nullifier, secret))`, `nullifier_hash = Poseidon(nullifier)`.
pub fn commitment_hasher(value: Fr, label: Fr, nullifier: Fr, secret: Fr) -> Commitment {
    let nullifier_hash = hash(&[nullifier]);
    let precommitment = hash(&[nullifier, secret]);
    Commitment { commitment: hash(&[value, label, precommitment]), nullifier_hash }
}
