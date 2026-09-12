//! The ragequit statement — `ragequit/src/main.nr`: the depositor proves ownership of a note by
//! opening its commitment, with the value and label public so the pool can refund it to the
//! original depositor. No trees, no identity: a ragequit is not private and is not meant to be.

use crate::commitment::commitment_hasher;
use crate::field::{to_be_word, Fr};

/// The four public signals, in `ProofLib.RagequitProof.pubSignals` order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RagequitSignals {
    pub commitment_hash: Fr,
    pub nullifier_hash: Fr,
    pub value: Fr,
    pub label: Fr,
}

impl RagequitSignals {
    pub fn journal(&self) -> [u8; 128] {
        let mut out = [0u8; 128];
        for (i, x) in [self.commitment_hash, self.nullifier_hash, self.value, self.label].iter().enumerate() {
            out[i * 32..(i + 1) * 32].copy_from_slice(&to_be_word(x));
        }
        out
    }
}

pub struct RagequitWitness {
    pub nullifier: Fr,
    pub secret: Fr,
}

pub fn verify_ragequit(s: &RagequitSignals, w: &RagequitWitness) -> Result<(), &'static str> {
    let c = commitment_hasher(s.value, s.label, w.nullifier, w.secret);
    if c.commitment != s.commitment_hash {
        return Err("commitment does not open to these secrets");
    }
    if c.nullifier_hash != s.nullifier_hash {
        return Err("nullifier hash does not match");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    //! The Noir e2e ragequit input — proven by a real Honk proof and settled by
    //! `test_RagequitWithRealProofThroughTheRealPool`.
    use super::*;
    use crate::field::from_dec;

    fn fixture() -> (RagequitSignals, RagequitWitness) {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../evm/noir/ragequit/Prover.e2e.toml");
        let t: toml::Table = std::fs::read_to_string(path).expect("Prover.e2e.toml").parse().unwrap();
        let f = |k: &str| from_dec(t[k].as_str().unwrap()).unwrap();
        (
            RagequitSignals { commitment_hash: f("commitment_hash"), nullifier_hash: f("nullifier_hash"), value: f("value"), label: f("label") },
            RagequitWitness { nullifier: f("nullifier"), secret: f("secret") },
        )
    }

    #[test]
    fn accepts_the_witness_a_real_proof_was_made_from_and_rejects_perturbations() {
        let (s, w) = fixture();
        verify_ragequit(&s, &w).unwrap();
        let one = Fr::from(1u64);
        let mut t = s.clone();
        t.value += one;
        assert!(verify_ragequit(&t, &w).is_err(), "value");
        let mut t = s.clone();
        t.nullifier_hash += one;
        assert!(verify_ragequit(&t, &w).is_err(), "nullifier hash");
        let u = RagequitWitness { nullifier: w.nullifier, secret: w.secret + one };
        assert!(verify_ragequit(&s, &u).is_err(), "secret");
        assert_eq!(s.journal().len(), 128);
    }
}
