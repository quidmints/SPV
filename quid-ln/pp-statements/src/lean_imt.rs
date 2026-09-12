//! LeanIMT inclusion — `@zk-kit/lean-imt` as the pool's state tree hashes it (`PoseidonT3`), with
//! the carry-up rule: a zero sibling means the node is carried to the next level unhashed.
//! Mirrors `pp/src/lean_imt.nr`, itself differential-tested against `lean-imt.sol`.

use crate::field::Fr;
use crate::poseidon::hash;
use ark_ff::{BigInteger, PrimeField, Zero};

/// The root implied by `leaf` at `leaf_index` with `siblings`, walking `actual_depth` levels.
/// `Err` when `actual_depth` exceeds the sibling array — the circuit's `assert(actual_depth <= MAX_DEPTH)`.
pub fn inclusion(leaf: Fr, leaf_index: Fr, siblings: &[Fr], actual_depth: usize) -> Result<Fr, &'static str> {
    if actual_depth > siblings.len() {
        return Err("lean_imt: depth exceeds the sibling array");
    }
    let bits = leaf_index.into_bigint().to_bits_le();
    let mut node = leaf;
    // Every level of the array is walked, as the fixed-width circuit does; `actual_depth` only
    // bounds it. Past the tree's depth a well-formed witness carries zero siblings, and the
    // carry-up rule makes each such level the identity.
    for (i, sibling) in siblings.iter().enumerate() {
        if sibling.is_zero() {
            continue;
        }
        let right_child = bits.get(i).copied().unwrap_or(false);
        node = if right_child { hash(&[*sibling, node]) } else { hash(&[node, *sibling]) };
    }
    Ok(node)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::field::from_dec;

    fn d(s: &str) -> Fr {
        from_dec(s).unwrap()
    }

    /// `lean_imt.nr::test_matches_lean_imt_sol_three_leaves` and two of its fuzz vectors.
    #[test]
    fn matches_lean_imt_sol() {
        assert_eq!(
            inclusion(Fr::from(1u64), Fr::from(0u64), &[Fr::from(2u64), Fr::from(3u64)], 2).unwrap(),
            d("13816780880028945690020260331303642730075999758909899334839547418969502592169")
        );
        let z = Fr::from(0u64);
        assert_eq!(
            inclusion(d("771542434896270695"), z, &[z; 8], 0).unwrap(),
            d("771542434896270695"),
            "a one-leaf tree's root is the leaf"
        );
        assert_eq!(
            inclusion(d("18220607450983656993"), Fr::from(1u64), &[d("17448036227231216792"), z, z, z, z, z, z, z], 1).unwrap(),
            d("4872492189337491109994569408025775109149422060106672696281092769329676785083")
        );
        assert_eq!(
            inclusion(d("12690389589401385431"), z, &[d("3695901138668934445"), d("1951146152130020494"), z, z, z, z, z, z], 2).unwrap(),
            d("5885686806379232589708813548494304953386472061266441823978427574364883829116")
        );
    }

    #[test]
    fn refuses_a_depth_beyond_the_array() {
        let z = Fr::from(0u64);
        assert!(inclusion(z, z, &[z; 4], 5).is_err());
    }
}
