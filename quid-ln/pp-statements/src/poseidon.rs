//! circomlib Poseidon over BN254, arity 1..=16 — `poseidon::bn254::hash_N` in the Noir circuits,
//! `Poseidon.hash` in `@iden3/js-crypto`, `PoseidonTn` on-chain. One function, the arity is the
//! input length.

use crate::field::Fr;
use light_poseidon::{Poseidon, PoseidonHasher};

pub fn hash(inputs: &[Fr]) -> Fr {
    let mut h = Poseidon::<Fr>::new_circom(inputs.len()).expect("circom Poseidon arity 1..=16");
    h.hash(inputs).expect("inputs are field elements")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::field::from_dec;

    /// `commitment.nr::test_matches_poseidon_solidity`: Poseidon(30) and the three-deep commitment.
    #[test]
    fn matches_the_circuits_and_the_solidity_poseidon() {
        let f = |n: u64| Fr::from(n);
        assert_eq!(
            hash(&[f(30)]),
            from_dec("7532086780038402662674345296860422071861903663404908958571451852914592667893").unwrap()
        );
        let pre = hash(&[f(30), f(40)]);
        assert_eq!(
            hash(&[f(10), f(20), pre]),
            from_dec("10718981984499290237711722178490140094119483277114902091282087901089143679380").unwrap()
        );
    }
}
