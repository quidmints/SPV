//! Loads the SBF build (real BPF execution, real compute metering) and verifies a proof made by
//! `p3probe`'s native prover.
use p3_field::{PrimeCharacteristicRing, PrimeField32};
use p3_sha256::Sha256;
use p3_uni_stark::prove;
use p3probe::*;
use rand::{Rng, SeedableRng};
use solana_program_test::ProgramTest;
use solana_sdk::{
    account::Account, instruction::{AccountMeta, Instruction}, pubkey::Pubkey, signature::Signer, transaction::Transaction,
};

fn make_proof(height: usize, fri: (usize, usize, usize)) -> (Vec<u8>, Vec<Val>) {
    let mut rng = rand::rngs::SmallRng::seed_from_u64(7);
    let leaf: [Val; DIGEST] = core::array::from_fn(|_| Val::from_u32(rng.gen::<u32>() % 0x7f000001));
    let siblings: Vec<[Val; DIGEST]> = (0..height).map(|_| core::array::from_fn(|_| Val::from_u32(rng.gen::<u32>() % 0x7f000001))).collect();
    let bits: Vec<bool> = (0..height).map(|_| rng.gen()).collect();
    let (trace, root) = generate_trace(leaf, &siblings, &bits);
    let pis = public_values(leaf, root);
    let cfg = config(Sha256, FriShape { log_blowup: fri.0, num_queries: fri.1, query_pow_bits: fri.2 });
    let proof = prove(&cfg, &MerklePathAir::new(), trace, &pis);
    (postcard::to_allocvec(&proof).unwrap(), pis)
}

async fn run(height: usize, fri: (usize, usize, usize), tamper: bool) -> (bool, Vec<String>) {
    let (mut proof_bytes, pis) = make_proof(height, fri);
    if tamper {
        let i = proof_bytes.len() / 2;
        proof_bytes[i] ^= 1;
    }
    let program_id = Pubkey::new_unique();
    let proof_key = Pubkey::new_unique();
    let scratch_key = Pubkey::new_unique();
    // `None` processor ⇒ the SBF build in target/deploy is loaded: real BPF execution, real metering.
    let mut pt = ProgramTest::new("p3probe_sbf", program_id, None);
    pt.set_compute_max_units(1_400_000_000);
    pt.add_account(proof_key, Account { lamports: 1_000_000_000, data: proof_bytes.clone(), owner: program_id, executable: false, rent_epoch: 0 });
    pt.add_account(scratch_key, Account { lamports: 1_000_000_000, data: vec![0u8; 8 * 1024 * 1024], owner: program_id, executable: false, rent_epoch: 0 });
    pt.prefer_bpf(true);
    let mut ctx = pt.start_with_context().await;
    // A program deployed at genesis becomes callable one slot later.
    ctx.warp_to_slot(2).unwrap();
    let (banks, payer, blockhash) = (ctx.banks_client.clone(), ctx.payer.insecure_clone(), ctx.last_blockhash);
    let mut data = vec![fri.0 as u8, fri.1 as u8, fri.2 as u8];
    for v in &pis {
        data.extend_from_slice(&v.as_canonical_u32().to_le_bytes());
    }
    let ix = Instruction { program_id, accounts: vec![AccountMeta::new_readonly(proof_key, false), AccountMeta::new(scratch_key, false)], data };
    let tx = Transaction::new_signed_with_payer(&[ix], Some(&payer.pubkey()), &[&payer], blockhash);
    let res = banks.process_transaction_with_metadata(tx).await.unwrap();
    let logs = res.metadata.map(|m| m.log_messages).unwrap_or_default();
    (res.result.is_ok(), logs)
}

#[tokio::test]
async fn verifies_on_sbf_and_reports_compute_units() {
    for (height, fri) in [(32usize, (3usize, 42usize, 16usize)), (32, (2, 60, 16)), (128, (3, 42, 16))] {
        let (ok, logs) = run(height, fri, false).await;
        let interesting: Vec<&String> = logs.iter().filter(|l| l.contains("consumed") || l.contains("heap") || l.contains("failed") || l.contains("exceeded")).collect();
        println!("height {height} fri {fri:?} ok={ok}");
        for l in interesting {
            println!("  {l}");
        }
        assert!(ok, "verification failed: {logs:?}");
    }
    let (ok, logs) = run(32, (3, 42, 16), true).await;
    assert!(!ok, "a tampered proof must be refused: {logs:?}");
    println!("tampered proof refused: {}", logs.iter().find(|l| l.contains("failed")).cloned().unwrap_or_default());
}
