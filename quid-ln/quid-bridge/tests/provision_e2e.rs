//! e2e: an operator provisions a seed into a (mock, off-SGX) enclave over the
//! attested RA-TLS channel; the seed is sealed in-enclave and unseals to the
//! same value at boot. Exercises prover (server cert with quote) + verifier
//! (client checks it during the handshake) + the seal handler end-to-end.
//!
//! Off-SGX the quote is a dummy and sealing uses the mock keyrequest, so this
//! runs without SGX hardware; the same code path uses the real DCAP quote +
//! EGETKEY seal inside an enclave.

use std::{sync::Arc, time::Duration};

use quid_bridge::provision_api::{provision_client_request, serve_provision};
use quid_common::{
    ExposeSecret, env::DeployEnv, ln::network::Network, root_seed::RootSeed,
};
use quid_crypto::rng::SysRng;
use quid_hop::{
    ffs::DiskFs,
    seed::{self, SeedSource},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn provision_over_attested_tls_seals_seed() {
    let dir = tempfile::tempdir().unwrap();
    let ffs =
        Arc::new(DiskFs::create_dir_all(dir.path().to_path_buf()).unwrap());
    let network = Network::Regtest;
    let deploy_env = DeployEnv::Dev;
    // Off-SGX this is the mock measurement; the client trusts exactly it.
    let measurement = quid_enclave::enclave::measurement();

    // --- provision over the attested channel ---
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let tok = "test-provision-token";
    let server = tokio::spawn(serve_provision(
        listener,
        ffs.clone(),
        deploy_env,
        network,
        Some(tok.to_string()),
    ));
    tokio::time::sleep(Duration::from_millis(200)).await; // let TLS serving start

    let seed = RootSeed::from_rng(&mut SysRng::new());
    let seed_bytes = seed.expose_secret().as_slice().to_vec();

    // Wrong token is rejected (no seed sealed) — exercises the operator-token gate.
    let bad = RootSeed::from_rng(&mut SysRng::new());
    provision_client_request(addr, measurement, bad, false, deploy_env, Some("wrong"))
        .await
        .expect_err("wrong provisioning token must be refused");

    // use_sgx=false: server presents a dummy quote off-SGX (verified as such).
    provision_client_request(addr, measurement, seed, false, deploy_env, Some(tok))
        .await
        .expect("provision over attested TLS");

    // The server self-stops after a successful provision.
    server.await.unwrap().expect("provisioning server ran cleanly");

    // --- boot unseals the exact provisioned seed (disk wins) ---
    let loaded = seed::load_or_provision(
        &*ffs,
        &mut SysRng::new(),
        SeedSource::BornInEnclave,
        deploy_env,
        network,
    )
    .expect("load sealed seed at boot");
    assert_eq!(
        loaded.expose_secret().as_slice(),
        seed_bytes.as_slice(),
        "boot must unseal the exact provisioned seed",
    );

    // --- a second provision is refused (never clobber live keys) ---
    let listener2 = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr2 = listener2.local_addr().unwrap();
    let server2 = tokio::spawn(serve_provision(
        listener2,
        ffs.clone(),
        deploy_env,
        network,
        Some(tok.to_string()),
    ));
    tokio::time::sleep(Duration::from_millis(200)).await;

    let dup = RootSeed::from_rng(&mut SysRng::new());
    let err = provision_client_request(
        addr2, measurement, dup, false, deploy_env, Some(tok),
    )
    .await
    .expect_err("second provision must be refused");
    let msg = format!("{err:#}").to_lowercase();
    assert!(
        msg.contains("already provisioned") || msg.contains("409"),
        "expected already-provisioned rejection, got: {err:#}",
    );
    server2.abort(); // rejected ⇒ no self-stop; tear it down
}
