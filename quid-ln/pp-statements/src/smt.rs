//! circomlib `SMTVerifier` (iden3 sparse Merkle tree): inclusion, and the two shapes of
//! exclusion — an empty slot, or another key's leaf where this key's path ends. A port of
//! `pp/src/smt.nr`, itself a port of `smtverifier.circom`, kept in the circuit's arithmetic form
//! (the state machine over `{top, i0, iold, inew, na}` selectors) so the two cannot differ on an
//! edge the prose would have paraphrased away. Differential-tested against circomlibjs below.

use crate::field::Fr;
use crate::poseidon::hash;
use ark_ff::{BigInteger, One, PrimeField, Zero};

fn switcher(l: Fr, r: Fr, bit: bool) -> (Fr, Fr) {
    let aux = (r - l) * Fr::from(bit as u64);
    (aux + l, r - aux)
}

/// Leaf hash: `Poseidon(key, value, 1)`.
fn hash1(key: Fr, value: Fr) -> Fr {
    hash(&[key, value, Fr::one()])
}

fn is_zero(x: &Fr) -> Fr {
    Fr::from(x.is_zero() as u64)
}

/// `smt_level_ins`: which level the leaf is inserted at — the last level whose sibling is non-zero,
/// scanning from the top. `Err` when the deepest sibling is non-zero (the circuit's assert).
fn level_ins(siblings: &[Fr]) -> Result<Vec<Fr>, &'static str> {
    let n = siblings.len();
    if !siblings[n - 1].is_zero() {
        return Err("SMT inner verification failure");
    }
    let mut done = vec![Fr::zero(); n - 1];
    let mut out = vec![Fr::zero(); n];
    out[n - 1] = Fr::one() - is_zero(&siblings[n - 2]);
    done[n - 2] = out[n - 1];
    for i in 0..n - 2 {
        out[n - 2 - i] = (Fr::one() - done[n - 2 - i]) * (Fr::one() - is_zero(&siblings[n - 3 - i]));
        done[n - 3 - i] = out[n - 2 - i] + done[n - 2 - i];
    }
    out[0] = Fr::one() - done[0];
    Ok(out)
}

/// `(st_top, st_i0, st_iold, st_inew, st_na)`.
type Sm = (Fr, Fr, Fr, Fr, Fr);

fn sm_full(is0: Fr, lev_ins: Fr, fnc: Fr, prev: Sm) -> Sm {
    let (prev_top, prev_i0, prev_iold, prev_inew, prev_na) = prev;
    let prev_top_lev_ins = prev_top * lev_ins;
    let prev_top_lev_ins_fnc = prev_top_lev_ins * fnc;
    (
        prev_top - prev_top_lev_ins,
        prev_top_lev_ins * is0,
        prev_top_lev_ins_fnc * (Fr::one() - is0),
        prev_top_lev_ins - prev_top_lev_ins_fnc,
        prev_na + prev_inew + prev_iold + prev_i0,
    )
}

#[allow(clippy::too_many_arguments)]
fn level_full(st_top: Fr, st_iold: Fr, st_inew: Fr, sibling: Fr, old_1_leaf: Fr, new_1_leaf: Fr, lrbit: bool, child: Fr) -> Fr {
    let (l, r) = switcher(child, sibling, lrbit);
    hash(&[l, r]) * st_top + old_1_leaf * st_iold + new_1_leaf * st_inew
}

/// Verify inclusion (`fnc = false`) of `(key, value)` or EXCLUSION (`fnc = true`) of `key` under
/// `root`. For exclusion supply what the path ends at: `is_old0 = true` for an empty slot, else the
/// occupying leaf's `old_key`/`old_value`. `Err` is the circuit's assert — a malformed witness, or
/// the soundness line: exclusion claimed for a key that is present.
#[allow(clippy::too_many_arguments)]
pub fn verify_full(root: Fr, key: Fr, value: Fr, old_key: Fr, old_value: Fr, is_old0: bool, fnc: bool, siblings: &[Fr]) -> Result<bool, &'static str> {
    if fnc && !is_old0 && old_key == key {
        return Err("SMT exclusion claimed for a key that is present (old_key == key)");
    }
    let n = siblings.len();
    if n < 2 {
        return Err("SMT needs at least two levels");
    }
    let fnc_f = Fr::from(fnc as u64);
    let is0_f = Fr::from(is_old0 as u64);
    let hash1_old = hash1(old_key, old_value);
    let hash1_new = hash1(key, value);
    let key_bits = key.into_bigint().to_bits_le();
    let lev_ins = level_ins(siblings)?;
    let mut sm = vec![(Fr::zero(), Fr::zero(), Fr::zero(), Fr::zero(), Fr::zero()); n];
    sm[0] = sm_full(is0_f, lev_ins[0], fnc_f, (Fr::one(), Fr::zero(), Fr::zero(), Fr::zero(), Fr::zero()));
    for i in 1..n {
        sm[i] = sm_full(is0_f, lev_ins[i], fnc_f, sm[i - 1]);
    }
    let bit = |i: usize| key_bits.get(i).copied().unwrap_or(false);
    let mut level = level_full(sm[n - 1].0, sm[n - 1].2, sm[n - 1].3, siblings[n - 1], hash1_old, hash1_new, bit(n - 1), Fr::zero());
    for j in (0..n - 1).rev() {
        level = level_full(sm[j].0, sm[j].2, sm[j].3, siblings[j], hash1_old, hash1_new, bit(j), level);
    }
    Ok(level == root)
}

#[cfg(test)]
mod tests {
    //! circomlibjs 0.1.7 vectors: the tree built by inserting (1,11), (2,22), (7,77), (9,99).
    use super::*;
    use crate::field::from_dec;

    fn d(s: &str) -> Fr {
        from_dec(s).unwrap()
    }
    fn root() -> Fr {
        d("518494836555806875742446376098343000486175381741467406929375446995815951571")
    }
    fn siblings_key7() -> Vec<Fr> {
        let mut v = vec![Fr::zero(); 10];
        v[0] = d("3538372437315232912232383076351801231931604997820687320170917796819460581158");
        v[1] = d("7219773115889511897248370091680383759521588836236378252329610603114958225446");
        v
    }
    fn f(n: u64) -> Fr {
        Fr::from(n)
    }
    fn incl(root: Fr, key: u64, value: u64, sib: &[Fr]) -> bool {
        verify_full(root, f(key), f(value), f(0), f(0), false, false, sib).unwrap()
    }

    #[test]
    fn inclusion_matches_circomlibjs_and_each_perturbation_fails() {
        let sib = siblings_key7();
        assert!(incl(root(), 7, 77, &sib));
        assert!(!incl(root(), 7, 78, &sib), "wrong value");
        assert!(!incl(root(), 8, 77, &sib), "wrong key");
        assert!(!incl(root() + Fr::one(), 7, 77, &sib), "wrong root");
        let mut t = sib.clone();
        t[0] += Fr::one();
        assert!(!incl(root(), 7, 77, &t), "tampered sibling");
    }

    #[test]
    fn exclusion_matches_circomlibjs_in_both_shapes() {
        // key=5 is absent and its path ends at an EMPTY subtree.
        let mut sib = vec![Fr::zero(); 10];
        sib[0] = d("3538372437315232912232383076351801231931604997820687320170917796819460581158");
        sib[1] = d("7623680454338960526645764969964785413027269598530557012829785131842723566171");
        sib[2] = d("12556884404771194108685558266628964754582687227852416218991473495993258837549");
        assert!(verify_full(root(), f(5), f(0), f(5), f(0), true, true, &sib).unwrap());
        // key=1024 is absent because key=2 (value 22) occupies the slot its path leads to.
        let mut sib = vec![Fr::zero(); 10];
        sib[0] = d("14615772771365257397421554110268415743234227304552007892570694122567980124822");
        assert!(verify_full(root(), f(1024), f(0), f(2), f(22), false, true, &sib).unwrap());
        assert!(!verify_full(root() + Fr::one(), f(1024), f(0), f(2), f(22), false, true, &sib).unwrap(), "wrong root");
        assert!(!verify_full(root(), f(1024), f(0), f(2), f(23), false, true, &sib).unwrap(), "wrong old_value");
        // fnc = false must still be inclusion.
        assert!(verify_full(root(), f(7), f(77), f(0), f(0), false, false, &siblings_key7()).unwrap());
    }

    /// THE SOUNDNESS LINE: absence claimed by pointing at the very key.
    #[test]
    fn exclusion_of_a_present_key_is_refused_not_false() {
        let e = verify_full(root(), f(7), f(0), f(7), f(77), false, true, &siblings_key7()).unwrap_err();
        assert!(e.contains("old_key == key"));
    }
}
