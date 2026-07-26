//! Operator provisioning client — verify a QU!D hop/LP enclave's attestation
//! over RA-TLS, then import + seal a root seed into it.
//!
//! Seeds are normally BORN in-enclave (no provisioning). This tool is for the
//! guarded import case (migration / recovery), where an operator imports a known
//! seed into a *verified* enclave. The enclave's DCAP quote is verified during
//! the TLS handshake (native Rust `dcap-ql` via `quid-tls`) BEFORE the seed is
//! sent — so the seed only ever enters the genuine, expected MRENCLAVE.
//!
//! Usage:
//!   quid-provision --addr <ip:port> --measurement <hex32> --seed <hex32> \
//!       [--network mainnet|testnet3|testnet4|regtest|signet] [--dummy]
//!
//! --dummy disables real SGX quote verification (ONLY for testing against a
//! non-SGX hop presenting a dummy quote). Never use against production.

use std::{net::SocketAddr, str::FromStr};

use anyhow::{Context, bail};
use quid_bridge::boot::flag;
use quid_bridge::provision_api::provision_client_request;
use quid_common::{ln::network::Network, root_seed::RootSeed};
use quid_enclave::enclave::Measurement;
use quid_hop::seed::deploy_env_for_network;

#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    let addr_s = flag(&args, "--addr")
        .context("--addr <ip:port> required (the hop's provisioning address)")?;
    let addr = SocketAddr::from_str(&addr_s).context("--addr must be ip:port")?;

    let measurement = Measurement::from_str(
        &flag(&args, "--measurement")
            .context("--measurement <hex32> required (expected MRENCLAVE)")?,
    )
    .context("--measurement must be 32-byte hex")?;

    let root_seed = RootSeed::from_str(
        &flag(&args, "--seed").context("--seed <hex32> required")?,
    )
    .context("--seed must be 32-byte hex")?;

    let network = match flag(&args, "--network") {
        Some(n) => Network::from_str(&n)
            .map_err(|_| anyhow::anyhow!("unknown --network"))?,
        None => Network::Mainnet,
    };
    let deploy_env = deploy_env_for_network(network);

    let use_sgx = !args.iter().any(|a| a == "--dummy");
    if !use_sgx {
        // Footgun guard: --dummy accepts a dummy quote (no real attestation) —
        // refuse it against a real network so a seed can't be imported into an
        // unverified "enclave".
        if deploy_env.is_staging_or_prod() {
            bail!("--dummy (no attestation) refused on staging/prod — drop --dummy");
        }
        eprintln!(
            "WARNING: --dummy disables SGX attestation verification; testing only",
        );
    }

    // Operator provisioning token (must match the enclave's QUID_PROVISION_TOKEN).
    let token = flag(&args, "--token");

    eprintln!(
        "verifying enclave {measurement} at {addr} (sgx={use_sgx}) then importing seed…",
    );
    provision_client_request(
        addr,
        measurement,
        root_seed,
        use_sgx,
        deploy_env,
        token.as_deref(),
    )
    .await
    .context("provisioning failed")?;
    println!("OK: seed imported + sealed into the verified enclave");
    Ok(())
}
