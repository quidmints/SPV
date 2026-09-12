//! The withdrawal statement — `withdraw_identity/src/main.nr` + `pp/src/withdraw.nr`, verbatim in
//! meaning: spend one note in the pool's state tree, commit the remainder as a change note, show
//! the withdrawer's identity is registered and clean, and show neither the note's label nor the
//! identity's document is on the blacklist. `context` binds the withdrawal terms and is not
//! examined here — the pool recomputes it.

use crate::commitment::commitment_hasher;
use crate::field::{fits_bits, to_be_word, Fr};
use crate::lean_imt;
use crate::poseidon::hash;
use crate::smt;
use ark_ff::PrimeField;

pub const IDENTITY_TREE_DEPTH: usize = 32;
pub const STATE_TREE_MAX_DEPTH: usize = 32;
/// `blacklist.nr` domains: one tree, keyed by `Poseidon(domain, identifier)`.
pub const DOMAIN_LABEL: u64 = 1;
pub const DOMAIN_ADDRESS: u64 = 2;
pub const DOMAIN_DOCUMENT: u64 = 3;
const STATUS_CLEAN: u64 = 0;

/// The eight public signals, in `ProofLib.WithdrawProof.pubSignals` order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WithdrawSignals {
    pub new_commitment: Fr,
    pub existing_nullifier_hash: Fr,
    pub withdrawn_value: Fr,
    pub state_root: Fr,
    pub state_tree_depth: Fr,
    pub identity_root: Fr,
    pub context: Fr,
    pub blacklist_root: Fr,
}

impl WithdrawSignals {
    /// The journal: the eight signals as consecutive 32-byte words — `abi.encode(uint256[8])`.
    pub fn journal(&self) -> [u8; 256] {
        let mut out = [0u8; 256];
        for (i, x) in self.words().iter().enumerate() {
            out[i * 32..(i + 1) * 32].copy_from_slice(&to_be_word(x));
        }
        out
    }

    pub fn words(&self) -> [Fr; 8] {
        [
            self.new_commitment,
            self.existing_nullifier_hash,
            self.withdrawn_value,
            self.state_root,
            self.state_tree_depth,
            self.identity_root,
            self.context,
            self.blacklist_root,
        ]
    }
}

/// An SMT exclusion witness: what the key's path ends at.
#[derive(Clone, Debug)]
pub struct Exclusion {
    pub siblings: Vec<Fr>,
    pub old_key: Fr,
    pub old_value: Fr,
    pub is_old0: bool,
}

#[derive(Clone, Debug)]
pub struct WithdrawWitness {
    pub value: Fr,
    pub label: Fr,
    pub nullifier: Fr,
    pub secret: Fr,
    pub state_leaf_index: Fr,
    pub state_siblings: Vec<Fr>,
    pub out_nullifier: Fr,
    pub out_secret: Fr,
    pub revocation_secret: Fr,
    pub identity_siblings: Vec<Fr>,
    pub document_id: Fr,
    pub label_exclusion: Exclusion,
    pub document_exclusion: Exclusion,
}

/// `Poseidon(domain, identifier)` — `blacklist.nr::blacklist_key`.
pub fn blacklist_key(domain: u64, identifier: Fr) -> Fr {
    hash(&[Fr::from(domain), identifier])
}

/// `Poseidon(revocation_secret, document_id)` — `envelope.nr::identity_commitment`.
pub fn identity_commitment(revocation_secret: Fr, document_id: Fr) -> Fr {
    hash(&[revocation_secret, document_id])
}

/// Accept or reject. Every `Err` is one of the circuit's asserts, named.
pub fn verify_withdrawal(s: &WithdrawSignals, w: &WithdrawWitness) -> Result<(), &'static str> {
    let existing = commitment_hasher(w.value, w.label, w.nullifier, w.secret);
    if existing.nullifier_hash != s.existing_nullifier_hash {
        return Err("nullifier hash does not match the spent note");
    }
    let depth: usize = s.state_tree_depth.into_bigint().0[0] as usize;
    if !fits_bits(&s.state_tree_depth, 8) || depth > STATE_TREE_MAX_DEPTH || w.state_siblings.len() != STATE_TREE_MAX_DEPTH {
        return Err("state tree depth out of range");
    }
    let state_root = lean_imt::inclusion(existing.commitment, w.state_leaf_index, &w.state_siblings, depth)?;
    if state_root != s.state_root {
        return Err("note is not in the state tree at that index");
    }
    // The three 128-bit range checks: value, withdrawn, and the remainder — so the subtraction
    // cannot wrap around the field.
    if !fits_bits(&w.value, 128) || !fits_bits(&s.withdrawn_value, 128) {
        return Err("value exceeds 128 bits");
    }
    let new_value = w.value - s.withdrawn_value;
    if !fits_bits(&new_value, 128) {
        return Err("withdrawn more than the note holds");
    }
    let out = commitment_hasher(new_value, w.label, w.out_nullifier, w.out_secret);
    if out.commitment != s.new_commitment {
        return Err("change note commitment does not match");
    }
    if w.identity_siblings.len() != IDENTITY_TREE_DEPTH {
        return Err("identity witness depth");
    }
    let commitment = identity_commitment(w.revocation_secret, w.document_id);
    let cleared = smt::verify_full(
        s.identity_root, commitment, Fr::from(STATUS_CLEAN), Fr::from(0u64), Fr::from(0u64), false, false, &w.identity_siblings,
    )?;
    if !cleared {
        return Err("identity is unregistered or revoked, or the inclusion witness is invalid");
    }
    let excluded = |key: Fr, x: &Exclusion| -> Result<bool, &'static str> {
        if x.siblings.len() != IDENTITY_TREE_DEPTH {
            return Err("blacklist witness depth");
        }
        smt::verify_full(s.blacklist_root, key, Fr::from(0u64), x.old_key, x.old_value, x.is_old0, true, &x.siblings)
    };
    if !excluded(blacklist_key(DOMAIN_LABEL, w.label), &w.label_exclusion)? {
        return Err("this deposit's label is blacklisted, or the exclusion witness is invalid");
    }
    if !excluded(blacklist_key(DOMAIN_DOCUMENT, w.document_id), &w.document_exclusion)? {
        return Err("this identity's document is blacklisted, or the exclusion witness is invalid");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    //! The acceptance test is the Noir e2e prover input: the witness a REAL Honk proof was made
    //! from, whose signals `PrivacyPool.withdraw` then settled (`WithdrawEndToEnd.t.sol`). The
    //! statement must accept exactly that witness and reject each single perturbation.
    use super::*;
    use crate::field::from_dec;

    fn fixture() -> (WithdrawSignals, WithdrawWitness) {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../evm/noir/withdraw_identity/Prover.e2e.toml");
        let t: toml::Table = std::fs::read_to_string(path).expect("Prover.e2e.toml").parse().unwrap();
        let f = |k: &str| from_dec(t[k].as_str().unwrap()).unwrap();
        let arr = |k: &str| -> Vec<Fr> { t[k].as_array().unwrap().iter().map(|v| from_dec(v.as_str().unwrap()).unwrap()).collect() };
        let b = |k: &str| t[k].as_bool().unwrap();
        let s = WithdrawSignals {
            new_commitment: f("new_commitment"),
            existing_nullifier_hash: f("existing_nullifier_hash"),
            withdrawn_value: f("withdrawn_value"),
            state_root: f("state_root"),
            state_tree_depth: f("state_tree_depth"),
            identity_root: f("identity_root"),
            context: f("context"),
            blacklist_root: f("blacklist_root"),
        };
        let w = WithdrawWitness {
            value: f("value"),
            label: f("label"),
            nullifier: f("nullifier"),
            secret: f("secret"),
            state_leaf_index: f("state_leaf_index"),
            state_siblings: arr("state_siblings"),
            out_nullifier: f("out_nullifier"),
            out_secret: f("out_secret"),
            revocation_secret: f("revocation_secret"),
            identity_siblings: arr("identity_siblings"),
            document_id: f("document_id"),
            label_exclusion: Exclusion {
                siblings: arr("blacklist_siblings"),
                old_key: f("blacklist_old_key"),
                old_value: f("blacklist_old_value"),
                is_old0: b("blacklist_is_old0"),
            },
            document_exclusion: Exclusion {
                siblings: arr("document_siblings"),
                old_key: f("document_old_key"),
                old_value: f("document_old_value"),
                is_old0: b("document_is_old0"),
            },
        };
        (s, w)
    }

    #[test]
    fn accepts_the_witness_a_real_proof_was_made_from() {
        let (s, w) = fixture();
        verify_withdrawal(&s, &w).unwrap();
        // And the journal is the pubSignals the chain saw, word for word.
        let sigs: Vec<String> = serde_json_lite(concat!(
            env!("CARGO_MANIFEST_DIR"), "/../../evm/test/identity/fixtures/withdraw_e2e_pubsignals.json"
        ));
        let j = s.journal();
        for (i, hex) in sigs.iter().enumerate() {
            assert_eq!(format!("0x{}", hex_of(&j[i * 32..(i + 1) * 32])), *hex, "signal {i}");
        }
    }

    #[test]
    fn rejects_each_single_perturbation() {
        let (s, w) = fixture();
        let one = Fr::from(1u64);
        let mut t = s.clone();
        t.existing_nullifier_hash += one;
        assert!(verify_withdrawal(&t, &w).is_err(), "nullifier");
        let mut t = s.clone();
        t.state_root += one;
        assert!(verify_withdrawal(&t, &w).is_err(), "state root");
        let mut t = s.clone();
        t.withdrawn_value = w.value + one;
        assert!(verify_withdrawal(&t, &w).is_err(), "over-withdraw wraps the field");
        let mut t = s.clone();
        t.new_commitment += one;
        assert!(verify_withdrawal(&t, &w).is_err(), "change note");
        let mut t = s.clone();
        t.identity_root += one;
        assert!(verify_withdrawal(&t, &w).is_err(), "identity root");
        let mut t = s.clone();
        t.blacklist_root += one;
        assert!(verify_withdrawal(&t, &w).is_err(), "blacklist root");
        let mut u = w.clone();
        u.state_leaf_index += one;
        assert!(verify_withdrawal(&s, &u).is_err(), "leaf index");
        let mut u = w.clone();
        u.label_exclusion.old_key = blacklist_key(DOMAIN_LABEL, w.label);
        assert!(verify_withdrawal(&s, &u).is_err(), "exclusion pointing at the key itself");
        // context is not examined: the pool recomputes it.
        let mut t = s.clone();
        t.context += one;
        verify_withdrawal(&t, &w).unwrap();
    }

    fn hex_of(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }
    /// The fixture is a JSON array of 8 hex strings; no JSON crate for that.
    fn serde_json_lite(path: &str) -> Vec<String> {
        std::fs::read_to_string(path).unwrap().split('"').filter(|s| s.starts_with("0x")).map(str::to_string).collect()
    }
}
