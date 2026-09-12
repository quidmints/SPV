//! The BN254 scalar field and the two conversions a journal needs.

pub use ark_bn254::Fr;
use ark_ff::{BigInteger, PrimeField};

/// A field element from its decimal text (the Noir/TOML and JSON spelling).
pub fn from_dec(s: &str) -> Option<Fr> {
    let mut acc = Fr::from(0u64);
    let ten = Fr::from(10u64);
    if s.is_empty() {
        return None;
    }
    for b in s.bytes() {
        let d = (b as char).to_digit(10)?;
        acc = acc * ten + Fr::from(d as u64);
    }
    Some(acc)
}

/// A field element from a 32-byte big-endian word; `None` if the word is not below the modulus.
pub fn from_be_word(w: &[u8; 32]) -> Option<Fr> {
    let mut limbs = [0u64; 4];
    for (i, chunk) in w.chunks(8).enumerate() {
        limbs[3 - i] = u64::from_be_bytes(chunk.try_into().unwrap());
    }
    Fr::from_bigint(ark_ff::BigInt::<4>(limbs))
}

/// The canonical 32-byte big-endian word of a field element — one journal word.
pub fn to_be_word(x: &Fr) -> [u8; 32] {
    let bytes = x.into_bigint().to_bytes_be();
    let mut w = [0u8; 32];
    w[32 - bytes.len()..].copy_from_slice(&bytes);
    w
}

/// `x < 2^bits` — the range checks the circuits express as `to_le_bits::<bits>()`.
pub fn fits_bits(x: &Fr, bits: usize) -> bool {
    x.into_bigint().num_bits() as usize <= bits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_round_trip_and_the_modulus_is_refused() {
        let x = from_dec("21888242871839275222246405745257275088548364400416034343698204186575808495616").unwrap();
        assert_eq!(from_be_word(&to_be_word(&x)), Some(x), "p - 1 round-trips");
        let mut p = to_be_word(&x);
        p[31] += 1; // p itself
        assert_eq!(from_be_word(&p), None);
        assert!(fits_bits(&Fr::from(u128::MAX), 128));
        assert!(!fits_bits(&(Fr::from(u128::MAX) + Fr::from(1u64)), 128));
    }
}
