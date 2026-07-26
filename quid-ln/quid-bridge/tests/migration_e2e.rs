//! e2e: enclave-to-enclave seed migration with a real 2-of-3
//! operator authorization, off-SGX.
//!
//! Two of the three DEV operator keys (secp256k1 secrets 1,2,3, whose EVM
//! addresses are the snapshot `OPERATOR_OWNERS`) sign the EIP-712 MigrationAuth
//! for the successor's MRENCLAVE; the OLD enclave (`migrate_seed_to`) verifies the
//! 2-of-3 Safe-owner bundle BEFORE exporting, then
//! transfers the seed over the attested channel (token-gated); the NEW enclave
//! seals it and unseals the SAME seed at boot. A 1-of-3 bundle is refused (the
//! exhaustive 2-of-3 verify cases live in `quid_hop::migration` unit tests).
//! Off-SGX uses a dummy quote + mock seal, so it runs without SGX.

use std::{sync::Arc, time::Duration};

use quid_bridge::provision_api::{migrate_seed_to, serve_provision};
use quid_common::{
    ExposeSecret, env::DeployEnv, ln::network::Network, root_seed::RootSeed,
};
use quid_crypto::rng::SysRng;
use quid_hop::{
    ffs::DiskFs,
    migration::{MigrationAuth, combine_migration_auths, sign_migration_auth},
    seed::{self, SeedSource},
};

/// A dev operator (Safe-owner) secret — secp256k1 secrets 1,2,3, whose addresses
/// are the snapshot `OPERATOR_OWNERS`.
fn dev_operator(i: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    s[31] = i;
    s
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn migrate_with_2of3_operator_auth() {
    let network = Network::Regtest;
    let deploy_env = DeployEnv::Dev;
    // Off-SGX both "enclaves" share the mock measurement; the operators authorize
    // this as the successor's MRENCLAVE.
    let target = quid_enclave::enclave::measurement();
    let token = "operator-migration-token";

    // Two of the three operators sign the EIP-712 authorization (2-of-3).
    let auth = MigrationAuth { measurement: target, deploy_env, network, nonce: [0x11u8; 32] };
    let s1 = sign_migration_auth(&dev_operator(1), &auth).unwrap();
    let s2 = sign_migration_auth(&dev_operator(2), &auth).unwrap();
    let bundle = combine_migration_auths(auth.clone(), vec![s1.clone(), s2]).unwrap();

    // The OLD enclave's live seed.
    let root_seed = RootSeed::from_rng(&mut SysRng::new());
    let seed_bytes = root_seed.expose_secret().as_slice().to_vec();

    // The NEW enclave: fresh data dir, serving its attested provision endpoint.
    let new_dir = tempfile::tempdir().unwrap();
    let new_ffs = Arc::new(
        DiskFs::create_dir_all(new_dir.path().to_path_buf()).unwrap(),
    );
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(serve_provision(
        listener,
        new_ffs.clone(),
        deploy_env,
        network,
        Some(token.to_string()),
    ));
    tokio::time::sleep(Duration::from_millis(200)).await;

    // A 1-of-3 bundle is refused before any seed leaves the old enclave.
    let one = combine_migration_auths(auth.clone(), vec![s1]).unwrap();
    let decoy = RootSeed::from_rng(&mut SysRng::new());
    migrate_seed_to(addr, &one, decoy, false, deploy_env, network, Some(token), None)
        .await
        .expect_err("1-of-3 must be refused");

    // 2-of-3 authorized ⇒ seed transfers to the authorized successor.
    migrate_seed_to(addr, &bundle, root_seed, false, deploy_env, network, Some(token), None)
        .await
        .expect("migrate with 2-of-3 operator auth");

    server.await.unwrap().expect("successor provisioning ran cleanly");

    let loaded = seed::load_or_provision(
        &*new_ffs,
        &mut SysRng::new(),
        SeedSource::BornInEnclave,
        deploy_env,
        network,
    )
    .unwrap();
    assert_eq!(
        loaded.expose_secret().as_slice(),
        seed_bytes.as_slice(),
        "successor must unseal the exact migrated seed",
    );
}
