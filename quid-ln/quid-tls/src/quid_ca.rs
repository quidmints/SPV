//! Public-WebPKI server verification for the app->gateway TLS.

use std::sync::Arc;

use quid_common::env::DeployEnv;
use rustls::client::WebPkiServerVerifier;

/// Client-side TLS config for app->gateway APIs, i.e. the `GatewayClient`.
/// This TLS config covers:
/// - `AppGatewayApi`
/// - `AppBackendApi`
/// - `BearerAuthBackendApi` for the app
///
/// It does *not* cover the gateway's node proxy.
pub fn app_gateway_client_config(deploy_env: DeployEnv) -> rustls::ClientConfig {
    // Verify the gateway's public (WebPKI) server cert; no client auth (the node behind it is attested).
    let quid_verifier = quid_server_verifier(deploy_env);
    let mut config = quid_tls_core::client_config_builder()
        .with_webpki_verifier(quid_verifier)
        .with_no_client_auth();
    config
        .alpn_protocols
        .clone_from(&quid_tls_core::QUID_ALPN_PROTOCOLS);

    config
}

/// [`ServerCertVerifier`] for the app->gateway OUTER TLS. The gateway is only transport: the user node behind it
/// is verified end-to-end by SGX remote attestation (see [`crate::attest_client`]), so a MITM'd gateway can't
/// forge the node's quote. The gateway therefore just presents an ordinary PUBLIC cert (auto-issued + auto-renewed
/// by Let's Encrypt) and we trust the standard WebPKI roots in EVERY environment — there is NO private QU!D CA and
/// NO dummy CA to generate, store, ship, or rotate.
///
/// [`ServerCertVerifier`]: rustls::client::danger::ServerCertVerifier
pub fn quid_server_verifier(_deploy_env: DeployEnv) -> Arc<WebPkiServerVerifier> {
    WebPkiServerVerifier::builder_with_provider(
        quid_tls_core::WEBPKI_ROOT_CERTS.clone(),
        quid_tls_core::QUID_CRYPTO_PROVIDER.clone(),
    )
    .build()
    .expect("WebPKI roots + crypto provider are always valid")
}

#[cfg(test)]
mod test {
    use proptest::{arbitrary::any, proptest, test_runner::Config};

    use super::*;

    #[test]
    fn verifier_builds() {
        let config = Config::with_cases(4);
        proptest!(config, |(deploy_env in any::<DeployEnv>())| {
            quid_server_verifier(deploy_env);
        })
    }
}
