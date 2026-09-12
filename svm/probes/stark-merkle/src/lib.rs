//! §SOLANA-STARK-PROBE — a Poseidon2/KoalaBear Merkle-path AIR under a SHA-256 FRI STARK.
//! Prover-agnostic pieces here (the AIR, the config types); the native prover is `main.rs`,
//! the Solana verifier is `../p3probe-sbf`.
#![cfg_attr(not(feature = "native"), no_std)]
extern crate alloc;

use alloc::vec::Vec;
use core::borrow::Borrow;

use p3_air::{Air, AirBuilder, BaseAir, WindowAccess};
use p3_challenger::{HashChallenger, SerializingChallenger32};
use p3_commit::ExtensionMmcs;
use p3_dft::Radix2DitParallel;
use p3_field::extension::BinomialExtensionField;
use p3_field::{Field, PrimeCharacteristicRing};
use p3_fri::{FriParameters, TwoAdicFriPcs};
use p3_koala_bear::{
    GenericPoseidon2LinearLayersKoalaBear, KoalaBear, KOALABEAR_POSEIDON2_RC_16_EXTERNAL_FINAL,
    KOALABEAR_POSEIDON2_RC_16_EXTERNAL_INITIAL, KOALABEAR_POSEIDON2_RC_16_INTERNAL,
};
use p3_matrix::dense::RowMajorMatrix;
use p3_merkle_tree::MerkleTreeMmcs;
use p3_poseidon2_air::{generate_trace_rows, num_cols, Poseidon2Air, Poseidon2Cols, RoundConstants};
use p3_symmetric::{CompressionFunctionFromHasher, CryptographicHasher, SerializingHasher};
use p3_uni_stark::{StarkConfig, SubAirBuilder};

pub type Val = KoalaBear;
pub const WIDTH: usize = 16;
pub const DIGEST: usize = 8;
pub const SBOX_DEGREE: u64 = 3;
pub const SBOX_REGISTERS: usize = 0;
pub const HALF_FULL_ROUNDS: usize = 4;
pub const PARTIAL_ROUNDS: usize = 20;

pub type P2Air = Poseidon2Air<Val, GenericPoseidon2LinearLayersKoalaBear, WIDTH, SBOX_DEGREE, SBOX_REGISTERS, HALF_FULL_ROUNDS, PARTIAL_ROUNDS>;
pub type P2Cols<T> = Poseidon2Cols<T, WIDTH, SBOX_DEGREE, SBOX_REGISTERS, HALF_FULL_ROUNDS, PARTIAL_ROUNDS>;
pub const P2_COLS: usize = num_cols::<WIDTH, SBOX_DEGREE, SBOX_REGISTERS, HALF_FULL_ROUNDS, PARTIAL_ROUNDS>();
/// Poseidon2 columns ‖ bit ‖ sibling[8].
pub const TRACE_WIDTH: usize = P2_COLS + 1 + DIGEST;
/// Public values: leaf[8] ‖ root[8].
pub const NUM_PUBLIC: usize = 2 * DIGEST;

pub fn round_constants() -> RoundConstants<Val, WIDTH, HALF_FULL_ROUNDS, PARTIAL_ROUNDS> {
    RoundConstants::new(
        KOALABEAR_POSEIDON2_RC_16_EXTERNAL_INITIAL,
        KOALABEAR_POSEIDON2_RC_16_INTERNAL,
        KOALABEAR_POSEIDON2_RC_16_EXTERNAL_FINAL,
    )
}

/// One Merkle path of `height` levels, one Poseidon2 compression per row:
/// row i permutes `bit ? sibling‖node : node‖sibling` and its first 8 outputs are row i+1's node.
/// Row 0's node is the public leaf; the last row's output is the public root.
pub struct MerklePathAir {
    pub p2: P2Air,
}

impl MerklePathAir {
    pub fn new() -> Self {
        Self { p2: P2Air::new(round_constants()) }
    }
}

impl Default for MerklePathAir {
    fn default() -> Self {
        Self::new()
    }
}

impl<F> BaseAir<F> for MerklePathAir {
    fn width(&self) -> usize {
        TRACE_WIDTH
    }
    fn num_public_values(&self) -> usize {
        NUM_PUBLIC
    }
    fn max_constraint_degree(&self) -> Option<usize> {
        Some(3)
    }
}

impl<AB: AirBuilder<F = Val>> Air<AB> for MerklePathAir {
    fn eval(&self, builder: &mut AB) {
        {
            let mut sub = SubAirBuilder::<AB, P2Air, AB::Var>::new(builder, 0..P2_COLS);
            self.p2.eval(&mut sub);
        }
        let pis: Vec<AB::Expr> = builder.public_values().iter().map(|v| (*v).into()).collect();
        let main = builder.main();
        let local = main.current_slice();
        let next = main.next_slice();
        let p2_local: &P2Cols<AB::Var> = local[..P2_COLS].borrow();
        let p2_next: &P2Cols<AB::Var> = next[..P2_COLS].borrow();
        let bit = local[P2_COLS];
        let sib = &local[P2_COLS + 1..];
        let out = &p2_local.ending_full_rounds[HALF_FULL_ROUNDS - 1].post;

        builder.assert_bool(bit);

        // The node entering row 0 is the leaf; the node entering row i+1 is row i's output.
        let node_first: Vec<AB::Expr> = pis[..DIGEST].to_vec();
        let mut first = builder.when_first_row();
        for k in 0..DIGEST {
            let l = p2_local.inputs[k];
            let r = p2_local.inputs[DIGEST + k];
            // bit 0 ⇒ inputs = node‖sib; bit 1 ⇒ sib‖node.
            first.assert_eq(l.into() - node_first[k].clone() + bit * (node_first[k].clone() - sib[k].into()), AB::Expr::ZERO);
            first.assert_eq(r.into() - sib[k].into() + bit * (sib[k].into() - node_first[k].clone()), AB::Expr::ZERO);
        }
        drop(first);

        let bit_next = next[P2_COLS];
        let sib_next = &next[P2_COLS + 1..];
        let mut tr = builder.when_transition();
        for k in 0..DIGEST {
            let node: AB::Expr = out[k].into();
            let l = p2_next.inputs[k];
            let r = p2_next.inputs[DIGEST + k];
            tr.assert_eq(l.into() - node.clone() + bit_next * (node.clone() - sib_next[k].into()), AB::Expr::ZERO);
            tr.assert_eq(r.into() - sib_next[k].into() + bit_next * (sib_next[k].into() - node), AB::Expr::ZERO);
        }
        drop(tr);

        let mut last = builder.when_last_row();
        for k in 0..DIGEST {
            last.assert_eq(out[k], pis[DIGEST + k].clone());
        }
    }
}

/// The trace for a path: `siblings[i]`/`bits[i]` per level. Returns (trace, root).
pub fn generate_trace(leaf: [Val; DIGEST], siblings: &[[Val; DIGEST]], bits: &[bool]) -> (RowMajorMatrix<Val>, [Val; DIGEST]) {
    use p3_koala_bear::default_koalabear_poseidon2_16;
    use p3_symmetric::Permutation;
    let n = siblings.len();
    assert!(n.is_power_of_two() && n == bits.len());
    let perm = default_koalabear_poseidon2_16();
    let mut node = leaf;
    let mut inputs = Vec::with_capacity(n);
    for i in 0..n {
        let mut st = [Val::ZERO; WIDTH];
        if bits[i] {
            st[..DIGEST].copy_from_slice(&siblings[i]);
            st[DIGEST..].copy_from_slice(&node);
        } else {
            st[..DIGEST].copy_from_slice(&node);
            st[DIGEST..].copy_from_slice(&siblings[i]);
        }
        inputs.push(st);
        let out = perm.permute(st);
        node.copy_from_slice(&out[..DIGEST]);
    }
    let p2 = generate_trace_rows::<Val, GenericPoseidon2LinearLayersKoalaBear, WIDTH, SBOX_DEGREE, SBOX_REGISTERS, HALF_FULL_ROUNDS, PARTIAL_ROUNDS>(inputs, &round_constants(), 0);
    let mut values = Vec::with_capacity(n * TRACE_WIDTH);
    for i in 0..n {
        values.extend_from_slice(&p2.values[i * P2_COLS..(i + 1) * P2_COLS]);
        values.push(Val::from_bool(bits[i]));
        values.extend_from_slice(&siblings[i]);
    }
    (RowMajorMatrix::new(values, TRACE_WIDTH), node)
}

// ── the STARK config, generic over the byte hash so the SBF verifier can use the syscall ──
pub type Challenge = BinomialExtensionField<Val, 4>;
pub type FieldHash<H> = SerializingHasher<H>;
pub type Compress<H> = CompressionFunctionFromHasher<H, 2, 32>;
pub type ValMmcs<H> = MerkleTreeMmcs<Val, u8, FieldHash<H>, Compress<H>, 2, 32>;
pub type ChallengeMmcs<H> = ExtensionMmcs<Val, Challenge, ValMmcs<H>>;
pub type Challenger<H> = SerializingChallenger32<Val, HashChallenger<u8, H, 32>>;
pub type Dft = Radix2DitParallel<Val>;
pub type Pcs<H> = TwoAdicFriPcs<Val, Dft, ValMmcs<H>, ChallengeMmcs<H>>;
pub type Config<H> = StarkConfig<Pcs<H>, Challenge, Challenger<H>>;

pub struct FriShape {
    pub log_blowup: usize,
    pub num_queries: usize,
    pub query_pow_bits: usize,
}

pub fn config<H: CryptographicHasher<u8, [u8; 32]> + Clone + Sync>(h: H, fri: FriShape) -> Config<H> {
    let field_hash = FieldHash::new(h.clone());
    let compress = Compress::new(h.clone());
    let val_mmcs = ValMmcs::new(field_hash, compress, 0);
    let challenge_mmcs = ChallengeMmcs::new(val_mmcs.clone());
    let fri_params = FriParameters {
        log_blowup: fri.log_blowup,
        log_final_poly_len: 0,
        max_log_arity: 1,
        num_queries: fri.num_queries,
        commit_proof_of_work_bits: 0,
        query_proof_of_work_bits: fri.query_pow_bits,
        mmcs: challenge_mmcs,
    };
    let pcs = Pcs::new(Dft::default(), val_mmcs, fri_params);
    let challenger = Challenger::from_hasher(Vec::new(), h);
    Config::new(pcs, challenger)
}

pub fn public_values(leaf: [Val; DIGEST], root: [Val; DIGEST]) -> Vec<Val> {
    let mut v = leaf.to_vec();
    v.extend_from_slice(&root);
    v
}

/// Suppress the unused-import lint on `Field` for the no_std build.
#[allow(dead_code)]
fn _field_marker<F: Field>() {}
