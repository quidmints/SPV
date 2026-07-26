//! Attested provisioning endpoint — the network analogue of the
//! `QUID_SEED` env import, over a remotely-attested channel.
//!
//! The enclave serves an RA-TLS endpoint whose server certificate embeds the SGX
//! attestation quote (built by the ported
//! [`quid_tls_attest_server::app_node_provision_server_config`]). The client (the
//! operator's `quid-provision` CLI, or the OLD enclave during a migration)
//! verifies that quote during the TLS handshake — confirming it is talking to the
//! genuine, EXPECTED MRENCLAVE — and only THEN POSTs the root seed, which is
//! sealed in-enclave via [`seed::provision_seed`].
//!
//! Born-in-enclave remains the default (no provisioning needed). This path is for
//! migration / recovery, where the OPERATOR imports a known seed into a verified
//! enclave. There is NO governance/approval authority — the operator is the sole
//! authority (the same entity that deploys the contracts). Two controls gate the
//! receiving side so a network attacker can't race a seed in:
//!   1. **Network isolation** — bind the listener to an operator-private address.
//!   2. **A provisioning token** — an operator-set shared secret carried in the
//!      `x-provision-token` header (over the attested TLS, so never on the wire in
//!      the clear). The handler requires it (constant-time compared) when set.
//! Even without these, the worst a wrong seed achieves is a DoS (the resulting
//! enclave can't sign for the existing channels) — never theft, since the real
//! seed only ever lives in the genuine enclaves.

use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::Context;
use axum::{
    Json, Router, extract::State, http::HeaderMap, http::StatusCode,
    routing::post,
};
use axum_server::{Handle, tls_rustls::RustlsConfig};
use quid_common::{env::DeployEnv, ln::network::Network, root_seed::RootSeed};
use quid_crypto::rng::SysRng;
use quid_enclave::enclave::Measurement;
use quid_hop::{ffs::DiskFs, seed};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

/// Header carrying the operator's provisioning token.
const PROVISION_TOKEN_HEADER: &str = "x-provision-token";

/// Request body for `POST /provision`. The seed travels over the attested TLS
/// channel only after the client has verified the enclave's attestation.
#[derive(Deserialize, Serialize)]
pub struct ProvisionRequest {
    /// The root seed to seal into this enclave.
    pub root_seed: RootSeed,
}

#[derive(Clone)]
struct ProvisionState {
    ffs: Arc<DiskFs>,
    deploy_env: DeployEnv,
    network: Network,
    /// Operator-set provisioning token; `None` disables the check (dev only).
    token: Option<Arc<str>>,
    /// Signaled to stop the server once a seed is successfully provisioned.
    handle: Handle,
}

/// Constant-time byte comparison (avoid leaking the token via timing).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Serve the attested provisioning endpoint on a pre-bound `listener`. Returns
/// `Ok(())` once a seed has been successfully provisioned (the server self-stops
/// so the operator can restart the node in run mode) or on error. `ffs` is the
/// node's `DiskFs` over its data dir; the sealed seed is written there.
///
/// `token` is the operator's provisioning secret; requests must present it in the
/// `x-provision-token` header. Pass `None` ONLY for dev/tests (the production
/// daemons always require it).
pub async fn serve_provision(
    listener: std::net::TcpListener,
    ffs: Arc<DiskFs>,
    deploy_env: DeployEnv,
    network: Network,
    token: Option<String>,
) -> anyhow::Result<()> {
    let addr: SocketAddr =
        listener.local_addr().context("provisioning listener addr")?;
    let measurement = quid_enclave::enclave::measurement();
    let (tls_config, dns_name) =
        quid_tls_attest_server::app_node_provision_server_config(
            &mut SysRng::new(),
            &measurement,
        )
        .context("Failed to build attested provisioning TLS config")?;

    info!(
        %addr, %dns_name, %measurement, token_required = token.is_some(),
        "serving attested provisioning endpoint",
    );

    let handle = Handle::new();
    let state = ProvisionState {
        ffs,
        deploy_env,
        network,
        token: token.map(Arc::from),
        handle: handle.clone(),
    };
    let app = Router::new()
        .route("/provision", post(provision_handler))
        .with_state(state);

    let rustls_config = RustlsConfig::from_config(Arc::new(tls_config));

    axum_server::from_tcp_rustls(listener, rustls_config)
        .handle(handle)
        .serve(app.into_make_service())
        .await
        .context("attested provisioning server error")
}

/// Operator-side provisioning client (used by the `quid-provision` CLI, the OLD
/// enclave's migration mode, and the e2e tests). Verifies the enclave at `addr`
/// against `expected_measurement` over RA-TLS — the attestation quote is checked
/// during the TLS handshake by [`quid_tls::attest_client`] — and only then POSTs
/// `root_seed` (with the operator `token`) to be sealed in-enclave.
///
/// `use_sgx` must be `true` against a real SGX enclave (verify the real DCAP
/// quote); `false` is for tests against a non-SGX server presenting a dummy quote.
pub async fn provision_client_request(
    addr: std::net::SocketAddr,
    expected_measurement: Measurement,
    root_seed: RootSeed,
    use_sgx: bool,
    deploy_env: DeployEnv,
    token: Option<&str>,
) -> anyhow::Result<()> {
    // The attested server cert is bound to this DNS name (derived from the
    // measurement); use it as SNI while resolving it to the real `addr`.
    let dns = quid_common::constants::node_provision_dns(
        &expected_measurement.short(),
    );
    let tls_config = quid_tls::attest_client::app_node_provision_client_config(
        use_sgx,
        deploy_env,
        expected_measurement,
    );

    let client = reqwest::Client::builder()
        .use_preconfigured_tls(tls_config)
        .resolve(&dns, addr)
        .build()
        .context("build provisioning HTTP client")?;

    let url = format!("https://{dns}:{}/provision", addr.port());
    let mut req = client.post(&url).json(&ProvisionRequest { root_seed });
    if let Some(token) = token {
        req = req.header(PROVISION_TOKEN_HEADER, token);
    }
    let resp = req
        .send()
        .await
        .context("send provision request (enclave attestation verified during TLS handshake)")?;

    let status = resp.status();
    anyhow::ensure!(
        status.is_success(),
        "provision rejected: {status} {}",
        resp.text().await.unwrap_or_default(),
    );
    Ok(())
}

/// Migration client (OLD-enclave side): transfer this enclave's
/// `root_seed` to the successor enclave authorized by a **2-of-3 operator**
/// `auth_bundle`. The bundle (≥2 distinct off-host operator signatures over the
/// target MRENCLAVE) is verified against the baked-in operator keys BEFORE
/// exporting — so a malicious host that controls the migration config cannot
/// redirect the export to an attacker enclave (it can't forge 2-of-3). We then
/// verify the successor's attestation == the authorized MRENCLAVE during the TLS
/// handshake before sending.
/// Consumes an operator `MigrationAuth` nonce on-chain (audit HIGH, M11-SGX) — a one-shot,
/// rollback-proof anti-replay guard. `consume` sends `BTCChannels.markMigrationNonceUsed`
/// and AGREEMENT-CONFIRMS it landed before returning; an `Err` means the tx reverted (the
/// nonce is already used ⇒ this bundle is a REPLAY) or couldn't be confirmed (a host
/// suppressed it). Impl'd by the EVM client. The migrating enclave exports the seed ONLY
/// after this returns `Ok`, so a captured bundle can never re-export the seed.
pub trait MigrationNonceConsumer {
    fn consume(&self, nonce: [u8; 32]) -> anyhow::Result<()>;
}

/// `consumer`: `Some` in the untrusted-host (fleet/family-SGX) mode — the migrating enclave
/// consumes the bundle's nonce on-chain BEFORE exporting, so a replay reverts and a host
/// can't roll the consumption back. `None` for a self-hosted node that trusts its own host
/// (no on-chain anti-replay needed / no active-hop identity to gate the consume).
pub async fn migrate_seed_to(
    new_addr: std::net::SocketAddr,
    auth_bundle: &[u8],
    root_seed: RootSeed,
    use_sgx: bool,
    deploy_env: DeployEnv,
    network: Network,
    token: Option<&str>,
    consumer: Option<&dyn MigrationNonceConsumer>,
) -> anyhow::Result<()> {
    let (target, nonce) = quid_hop::migration::verify_migration_auth(
        auth_bundle,
        &quid_hop::migration::OPERATOR_OWNERS,
        quid_hop::migration::MIGRATION_THRESHOLD,
        deploy_env,
        network,
    )
    .context("verify operator-Safe migration authorization before exporting seed")?;

    // ANTI-REPLAY (audit HIGH): consume the bundle's nonce on-chain BEFORE exporting. A
    // replayed bundle's nonce is already used ⇒ this reverts ⇒ we do NOT export. Fail-closed:
    // a host that suppresses the consume tx gets no confirmation ⇒ no export.
    if let Some(consumer) = consumer {
        consumer
            .consume(nonce)
            .context("consume migration nonce on-chain before exporting seed (anti-replay)")?;
        info!(%target, %new_addr, "migration authorized (2-of-3) + nonce consumed on-chain; transferring seed");
    } else {
        info!(%target, %new_addr, "migration authorized (2-of-3), self-host (no on-chain nonce); transferring seed");
    }
    provision_client_request(
        new_addr,
        target,
        root_seed,
        use_sgx,
        deploy_env,
        token,
    )
    .await
    .context("transfer seed to authorized successor enclave")
}

async fn provision_handler(
    State(state): State<ProvisionState>,
    headers: HeaderMap,
    Json(req): Json<ProvisionRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    // Operator-token gate (when configured): a network attacker who reaches the
    // endpoint can't race a seed in without the operator's secret.
    if let Some(expected) = state.token.as_deref() {
        let presented = headers
            .get(PROVISION_TOKEN_HEADER)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !ct_eq(presented.as_bytes(), expected.as_bytes()) {
            warn!("provisioning rejected: missing/invalid provisioning token");
            return Err((
                StatusCode::UNAUTHORIZED,
                "missing or invalid x-provision-token".to_string(),
            ));
        }
    }

    let mut rng = SysRng::new();
    match seed::provision_seed(
        &*state.ffs,
        &mut rng,
        &req.root_seed,
        state.deploy_env,
        state.network,
    ) {
        Ok(()) => {
            info!("provisioned + sealed seed via attested endpoint");
            // Stop the server (with a grace period so this 200 flushes first),
            // so the operator can restart the node in run mode.
            state.handle.graceful_shutdown(Some(Duration::from_secs(2)));
            Ok(StatusCode::OK)
        }
        Err(e) => {
            let msg = format!("{e:#}");
            warn!("provisioning rejected: {msg}");
            // "already provisioned" is a conflict; anything else is malformed.
            let code = if msg.contains("already provisioned") {
                StatusCode::CONFLICT
            } else {
                StatusCode::BAD_REQUEST
            };
            Err((code, msg))
        }
    }
}
