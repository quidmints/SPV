//! Dependencies-minimized core for Quid TLS.

use std::sync::{Arc, LazyLock};

/// Allow accessing [`rustls`] via `quid_tls::rustls`.
pub use rustls;
use rustls::{ClientConfig, ServerConfig, crypto::WebPkiSupportedAlgorithms};
/// Allow accessing [`webpki_roots`] via `quid_tls::webpki_roots`.
#[cfg(feature = "webpki-roots")]
pub use webpki_roots;

/// Helper to get a builder for a [`ClientConfig`] with Quid's presets.
/// NOTE: Remember: Set `alpn_protocols` to [`QUID_ALPN_PROTOCOLS`] afterwards!
pub fn client_config_builder()
-> rustls::ConfigBuilder<ClientConfig, rustls::WantsVerifier> {
    // We use the correct provider and TLS versions here
    #[allow(clippy::disallowed_methods)]
    ClientConfig::builder_with_provider(QUID_CRYPTO_PROVIDER.clone())
        .with_protocol_versions(QUID_TLS_PROTOCOL_VERSIONS)
        .expect("Checked in tests")
}

/// Helper to get a builder for a [`ServerConfig`] with Quid's presets.
/// NOTE: Remember: Set `alpn_protocols` to [`QUID_ALPN_PROTOCOLS`] afterwards!
pub fn server_config_builder()
-> rustls::ConfigBuilder<ServerConfig, rustls::WantsVerifier> {
    // We use the correct provider and TLS versions here
    #[allow(clippy::disallowed_methods)]
    ServerConfig::builder_with_provider(QUID_CRYPTO_PROVIDER.clone())
        .with_protocol_versions(QUID_TLS_PROTOCOL_VERSIONS)
        .expect("Checked in tests")
}

/// Quid TLS protocol version: TLSv1.3
pub static QUID_TLS_PROTOCOL_VERSIONS: &[&rustls::SupportedProtocolVersion] =
    &[&rustls::version::TLS13];
/// Quid cipher suite: specifically `TLS13_AES_128_GCM_SHA256`
static QUID_CIPHER_SUITES: &[rustls::SupportedCipherSuite] =
    &[rustls::crypto::ring::cipher_suite::TLS13_AES_128_GCM_SHA256];
/// §BTC-4.5 — post-quantum key agreement, ON BY DEFAULT.
#[cfg(feature = "pq")]
pub mod pq;

/// Quid key exchange groups, in PREFERENCE ORDER.
///
/// 🔴 **`X25519MLKEM768` IS FIRST AND THAT IS THE WHOLE POINT.** `quid-hop`'s enclave migration
/// POSTs the ROOT SEED over RA-TLS (`quid_hop::seed::provision_seed`), so a recorded classical
/// handshake is a harvest-now-decrypt-later target whose payload never expires — it re-derives
/// every hop and channel key. Ordering decides what an honest peer actually negotiates; listing the
/// hybrid second would leave that handshake classical in practice.
///
/// ⭐ **X25519 STAYS, AND IT IS NOT A HEDGE.** It is what a peer that does not know the hybrid
/// negotiates, and `ActiveKeyExchange::hybrid_component` additionally lets such a peer take the
/// X25519 half of a hybrid share rather than failing. Neither is a downgrade vector: TLS 1.3 covers
/// group selection in the transcript, so a MITM cannot force either quietly.
#[cfg(feature = "pq")]
static QUID_KEY_EXCHANGE_GROUPS: &[&dyn rustls::crypto::SupportedKxGroup] =
    &[pq::X25519MLKEM768, rustls::crypto::ring::kx_group::X25519];

/// Quid key exchange group without `pq`: X25519 only. ⚠️ This build has NO post-quantum protection
/// on the migration handshake — see [`pq`] for what that costs.
#[cfg(not(feature = "pq"))]
static QUID_KEY_EXCHANGE_GROUPS: &[&dyn rustls::crypto::SupportedKxGroup] =
    &[rustls::crypto::ring::kx_group::X25519];
/// Quid default value for [`ClientConfig::alpn_protocols`] and
/// [`ServerConfig::alpn_protocols`]: HTTP/1.1 and HTTP/2
pub static QUID_ALPN_PROTOCOLS: LazyLock<Vec<Vec<u8>>> =
    LazyLock::new(|| vec!["h2".into(), "http/1.1".into()]);

/// Our [`rustls::crypto::CryptoProvider`].
/// Use this instead of [`rustls::crypto::ring::default_provider`].
pub static QUID_CRYPTO_PROVIDER: LazyLock<Arc<rustls::crypto::CryptoProvider>> =
    LazyLock::new(|| {
        #[allow(clippy::disallowed_methods)] // We customize it here
        let mut provider = rustls::crypto::ring::default_provider();
        QUID_CIPHER_SUITES.clone_into(&mut provider.cipher_suites);
        QUID_KEY_EXCHANGE_GROUPS.clone_into(&mut provider.kx_groups);
        provider.signature_verification_algorithms = QUID_SIGNATURE_ALGORITHMS;
        // provider.secure_random = &Ring;
        // provider.key_provider = &Ring;
        Arc::new(provider)
    });

/// The value to pass to
/// [`ServerCertVerifier::supported_verify_schemes`](rustls::client::danger::ServerCertVerifier::supported_verify_schemes)
pub static QUID_SUPPORTED_VERIFY_SCHEMES: LazyLock<
    Vec<rustls::SignatureScheme>,
> = LazyLock::new(|| {
    QUID_SIGNATURE_ALGORITHMS
        .mapping
        .iter()
        .map(|(sigscheme, _sig_verify_alg)| *sigscheme)
        .collect()
});

/// Quid signature algorithms: Only Ed25519.
/// Pass this to [`rustls::crypto::verify_tls13_signature`].
pub static QUID_SIGNATURE_ALGORITHMS: WebPkiSupportedAlgorithms =
    WebPkiSupportedAlgorithms {
        all: &[webpki::ring::ED25519],
        mapping: &[(
            rustls::SignatureScheme::ED25519,
            &[webpki::ring::ED25519],
        )],
    };

/// Mozilla's webpki roots as a lazily-initialized [`rustls::RootCertStore`].
///
/// In some places where we must trust Mozilla's webpki roots, we add the trust
/// anchors manually to avoid enabling reqwest's `rustls-tls-webpki-roots`
/// feature, which propagates to other crates via feature unification.
///
/// It's safer to add the Mozilla roots manually than to have to remember to set
/// `.tls_built_in_root_certs(false)` in every `reqwest` client builder.
///
/// # Example
///
/// ```ignore
/// # use std::time::Duration;
/// # use anyhow::Context;
/// #
/// fn build_reqwest_client() -> anyhow::Result<reqwest::Client> {
///     let tls_config = quid_tls::client_config_builder()
///         .with_root_certificates(quid_tls::WEBPKI_ROOT_CERTS.clone())
///         .with_no_client_auth();
///
///     let client = reqwest::ClientBuilder::new()
///         .https_only(true)
///         .use_preconfigured_tls(tls_config)
///         .timeout(Duration::from_secs(10))
///         .build()
///         .context("reqwest::ClientBuilder::build failed")?;
///
///     Ok(client)
/// }
/// ```
#[cfg(feature = "webpki-roots")]
pub static WEBPKI_ROOT_CERTS: std::sync::LazyLock<
    std::sync::Arc<rustls::RootCertStore>,
> = LazyLock::new(|| {
    let roots = webpki_roots::TLS_SERVER_ROOTS.to_vec();
    Arc::new(rustls::RootCertStore { roots })
});

#[cfg(all(test, feature = "pq"))]
mod pq_wiring_tests {
    use super::*;

    /// §BTC-4.5 — THE WIRING, WHICH IS THE PART THAT CAN SILENTLY NOT HAPPEN. `pq.rs` is tested on
    /// its own, but a correct key-exchange group that is not in the provider — or is listed SECOND —
    /// protects nothing, and no handshake fails to tell you: it just negotiates X25519 and succeeds.
    ///
    /// ⭐ The end-to-end negotiation itself is proved by the EXISTING handshake tests in `quid-tls`
    /// (`shared_seed`, `quid-tls-attest-server`): they run through whatever this list says, so a
    /// broken hybrid makes them fail. What they cannot catch is the hybrid being absent or demoted,
    /// because both of those still hand them a working classical handshake. That is this test.
    #[test]
    fn the_hybrid_is_registered_and_preferred() {
        let groups = &QUID_CRYPTO_PROVIDER.kx_groups;
        assert_eq!(
            groups[0].name(),
            rustls::NamedGroup::X25519MLKEM768,
            "X25519MLKEM768 must be FIRST — preference order is what an honest peer negotiates, \
             and the migration handshake carries the root seed"
        );
        assert!(
            groups.iter().any(|g| g.name() == rustls::NamedGroup::X25519),
            "X25519 must remain offered, so a peer that does not know the hybrid still connects"
        );
        assert_eq!(groups.len(), 2, "exactly these two; an unlisted third group is not reviewed");
    }

    /// TLS 1.3 only, matching `QUID_TLS_PROTOCOL_VERSIONS`. A hybrid offered to TLS 1.2 would be
    /// meaningless (no `key_share` semantics for it) and rustls asks the group directly.
    #[test]
    fn the_hybrid_is_tls13_only() {
        let hybrid = QUID_CRYPTO_PROVIDER.kx_groups[0];
        assert!(hybrid.usable_for_version(rustls::ProtocolVersion::TLSv1_3));
        assert!(!hybrid.usable_for_version(rustls::ProtocolVersion::TLSv1_2));
    }
}

