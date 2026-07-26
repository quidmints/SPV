//! # mTLS using SGX remote attestation (prover / enclave side)
//!
//! This crate contains the server/enclave attestation and x509 cert generation
//! logic. The matching verifier/client side lives in
//! [`quid_tls::attest_client`].
//!
//! ## Code-level remote attestation + TLS process
//!
//! On the prover side, inside SGX:
//!
//! 1. An [`AttestationCert`] is generated during the construction of an
//!    attestation-based TLS config ([`AttestationCert::generate`]).
//! 2. [`AttestationCert::generate`] calls [`quote::quote_enclave`], which does
//!    the low-level work to actually generate an attestation quote which binds
//!    to and endorses the cert's pubkey. In our code, the quote is just a
//!    `Cow<'a, [u8]>`.
//! 3. The quote bytes are packaged up into a [`SgxAttestationExtension`], which
//!    is an x509 cert extension containing all evidence needed by the client to
//!    verify the remote attestation. The [`SgxAttestationExtension`] is embedded
//!    into the [`AttestationCert`] presented to the verifier.
//!
//! On the verifier side, typically outside of SGX (see [`quid_tls`]):
//!
//! 4. The verifier uses the [`AttestationCertVerifier`] as the
//!    [`ClientCertVerifier`] or [`ServerCertVerifier`] in its TLS config, which
//!    verifies remote attestation evidence and accepts or rejects the TLS
//!    connection according to a configured [`EnclavePolicy`].
//!
//! 5. Finally, if all verifications passed, a TLS connection is established.
//!
//! [`AttestationCert`]: cert::AttestationCert
//! [`AttestationCert::generate`]: cert::AttestationCert::generate
//! [`quote::quote_enclave`]: quote::quote_enclave
//! [`AttestationCertVerifier`]: quid_tls::attest_client::verifier::AttestationCertVerifier
//! [`SgxAttestationExtension`]: quid_tls::attest_client::cert::SgxAttestationExtension
//! [`EnclavePolicy`]: quid_tls::attest_client::verifier::EnclavePolicy
//! [`ClientCertVerifier`]: rustls::server::danger::ClientCertVerifier
//! [`ServerCertVerifier`]: rustls::client::danger::ServerCertVerifier

use std::{sync::OnceLock, time::Duration};

use anyhow::{Context, format_err};
use quid_common::constants;
use quid_crypto::rng::Crng;
use quid_enclave::enclave::{Measurement, MrShort};
use quid_tls::types::CertWithKey;

/// Self-signed x509 cert containing enclave remote attestation endorsements.
pub mod cert;
/// Get a quote for the running node enclave.
pub mod quote;

/// Server-side TLS config for the provisioning API (the attested tunnel the
/// app/operator uses to provision or import a sealed seed). Also returns the
/// node's DNS name.
pub fn app_node_provision_server_config(
    rng: &mut impl Crng,
    measurement: &Measurement,
) -> anyhow::Result<(rustls::ServerConfig, String)> {
    let mr_short = measurement.short();
    let node_mode = NodeMode::Provision { mr_short };
    let (attestation_cert, dns_name) =
        get_or_generate_node_attestation_cert(rng, node_mode)
            .context("Failed to get or generate node attestation cert")?;
    let (cert_chain, cert_key) = attestation_cert.clone().into_chain_and_key();

    let mut config = quid_tls_core::server_config_builder()
        .with_no_client_auth()
        .with_single_cert(cert_chain, cert_key)
        .context("Failed to build TLS config")?;
    config
        .alpn_protocols
        .clone_from(&quid_tls_core::QUID_ALPN_PROTOCOLS);

    Ok((config, dns_name))
}

/// The mode that the user node is currently running in, and associated info.
#[derive(Copy, Clone)]
pub enum NodeMode {
    Mega { mr_short: MrShort },
    Provision { mr_short: MrShort },
    Run,
}

/// A helper to get or generate a remote attestation TLS cert for the user node.
/// This function prevents the user node from generating multiple (duplicate)
/// remote attestations per node mode during a single node lifetime.
/// Additionally returns the DNS name that the cert was bound to.
fn get_or_generate_node_attestation_cert(
    rng: &mut impl Crng,
    node_mode: NodeMode,
) -> anyhow::Result<(&'static CertWithKey, String)> {
    // Determine the cert lifetime. Until we can refresh the TLS cert during
    // runtime, this has to be longer than the time between node restarts.
    let lifetime = match node_mode {
        // Long lifetime (3 months); Mega and Provision nodes restart at least
        // once every deploy.
        NodeMode::Mega { .. } | NodeMode::Provision { .. } =>
            Duration::from_secs(60 * 60 * 24 * 90),
        // Medium lifetime; Run nodes restart fairly frequently.
        NodeMode::Run => Duration::from_secs(60 * 60 * 24 * 14), // 2 weeks
    };

    // The DNS name to bind the remote attestation cert to. Currently only
    // useful for a provisioning node which embeds the remote attestation
    // evidence in its server cert.
    let dns_name = match node_mode {
        NodeMode::Mega { mr_short } | NodeMode::Provision { mr_short } =>
            constants::node_provision_dns(&mr_short),
        NodeMode::Run => constants::NODE_RUN_DNS.to_owned(),
    };

    // Only generate a remote attestation cert once per node mode during a
    // node's lifetime. We use separate statics to ensure Run mode and
    // Provision/Mega modes get different certs with appropriate DNS names.
    static RUN_ATTESTATION_CERT: OnceLock<anyhow::Result<CertWithKey>> =
        OnceLock::new();
    static PROVISION_ATTESTATION_CERT: OnceLock<anyhow::Result<CertWithKey>> =
        OnceLock::new();

    let static_cert = match node_mode {
        NodeMode::Run => &RUN_ATTESTATION_CERT,
        NodeMode::Mega { .. } | NodeMode::Provision { .. } =>
            &PROVISION_ATTESTATION_CERT,
    };

    let attestation_cert = static_cert
        .get_or_init(|| {
            let cert =
                cert::AttestationCert::generate(rng, &[&dns_name], lifetime)
                    .context("Could not generate remote attestation cert")?;
            let cert_der = cert.serialize_der_self_signed().context(
                "Failed to self-sign and serialize attestation cert",
            )?;
            let key_der = cert.serialize_key_der();
            let cert_with_key = CertWithKey {
                cert_der,
                cert_chain_der: vec![],
                key_der,
            };

            Ok(cert_with_key)
        })
        .as_ref()
        .map_err(|err| {
            format_err!("Couldn't get or init attestation cert: {err:#}")
        })?;

    Ok((attestation_cert, dns_name))
}

#[cfg(test)]
mod test {
    use std::sync::Arc;

    use quid_common::env::DeployEnv;
    use quid_crypto::rng::FastRng;
    use quid_enclave::enclave;
    use quid_tls::{
        attest_client::app_node_provision_client_config, test_utils,
    };

    use super::*;

    /// Sanity check an App->Node Provision TLS handshake
    #[tokio::test]
    async fn app_node_provision_handshake_succeeds() {
        let client_measurement = enclave::measurement();

        let [client_result, server_result] =
            do_app_node_provision_tls_handshake(client_measurement).await;

        client_result.unwrap();
        server_result.unwrap();
    }

    /// App->Node Provision TLS handshake should fail if the client trusts a
    /// different measurement from the one reported by the enclave.
    #[tokio::test]
    async fn app_node_provision_negative_test() {
        let client_measurement = Measurement::new([69; 32]);

        let [client_result, server_result] =
            do_app_node_provision_tls_handshake(client_measurement).await;

        let client_error = client_result.unwrap_err();
        assert!(client_error.contains("Client didn't connect"));
        assert!(
            client_error
                .contains("our trust policy rejected the remote enclave")
        );
        assert!(server_result.unwrap_err().contains("Server didn't accept"));
    }

    // Shorthand to do a App->Node Provision TLS handshake.
    async fn do_app_node_provision_tls_handshake(
        client_measurement: Measurement,
    ) -> [Result<(), String>; 2] {
        let mut rng = FastRng::from_u64(20240514);
        let use_sgx = cfg!(target_env = "sgx");
        let deploy_env = DeployEnv::Dev;

        // NOTE: It is a pain to make an attestation quote (both SGX and non-SGX)
        // which pretends to attest to a passed-in bogus measurement, but it is
        // not impossible. Maybe this can be added in the future.
        let server_measurement = enclave::measurement();
        let expected_dns =
            constants::node_provision_dns(&server_measurement.short());

        let client_config = Arc::new(app_node_provision_client_config(
            use_sgx,
            deploy_env,
            client_measurement,
        ));

        let server_config =
            app_node_provision_server_config(&mut rng, &server_measurement)
                .map(|(config, _dns)| Arc::new(config))
                .unwrap();

        test_utils::do_tls_handshake(
            client_config,
            server_config,
            &expected_dns,
        )
        .await
    }
}
