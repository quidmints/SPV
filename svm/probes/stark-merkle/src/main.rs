use p3_field::{PrimeCharacteristicRing, PrimeField32};
use p3_sha256::Sha256;
use p3_uni_stark::{prove, verify};
use p3probe::*;
use rand::{Rng, SeedableRng};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let height: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(32);
    let num_queries: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(60);
    let log_blowup: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(2);
    let out = args.get(4).cloned();

    let mut rng = rand::rngs::SmallRng::seed_from_u64(7);
    let leaf: [Val; DIGEST] = core::array::from_fn(|_| Val::from_u32(rng.gen::<u32>() % 0x7f000001));
    let siblings: Vec<[Val; DIGEST]> = (0..height).map(|_| core::array::from_fn(|_| Val::from_u32(rng.gen::<u32>() % 0x7f000001))).collect();
    let bits: Vec<bool> = (0..height).map(|_| rng.gen()).collect();

    let (trace, root) = generate_trace(leaf, &siblings, &bits);
    let pis = public_values(leaf, root);
    let air = MerklePathAir::new();
    let cfg = config(Sha256, FriShape { log_blowup, num_queries, query_pow_bits: 16 });

    let t = Instant::now();
    let proof = prove(&cfg, &air, trace, &pis);
    let prove_ms = t.elapsed().as_millis();
    let bytes = postcard::to_allocvec(&proof).unwrap();
    let t = Instant::now();
    verify(&cfg, &air, &proof, &pis).expect("verifies");
    let verify_ms = t.elapsed().as_micros();
    println!("height {height} width {TRACE_WIDTH} queries {num_queries} log_blowup {log_blowup}: proof {} bytes, prove {prove_ms} ms, verify {verify_ms} us", bytes.len());
    if let Some(o) = out {
        std::fs::write(&o, &bytes).unwrap();
        let pv: Vec<u32> = pis.iter().map(|x| x.as_canonical_u32()).collect();
        std::fs::write(format!("{o}.pis"), postcard::to_allocvec(&pv).unwrap()).unwrap();
    }
}
