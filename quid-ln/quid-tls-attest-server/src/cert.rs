//! Manage self-signed x509 certificate containing enclave remote attestation
//! endorsements.

use std::{str::FromStr, time::Duration};

use anyhow::Context;
use quid_crypto::{ed25519, rng::Crng};
use quid_tls::{
    self as tls,
    ed25519_ext::Ed25519KeyPairExt,
    types::{LxCertificateDer, LxPrivatePkcs8KeyDer},
};
use rcgen::string::Ia5String;

/// An x509 certificate containing remote attestation endorsements.
pub struct AttestationCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

// -- impl AttestationCert -- //

impl AttestationCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    const COMMON_NAME: &'static str = "QU!D remote attestation cert";

    /// Sample a fresh cert keypair, gather remote attestation evidence, and
    /// embed these in an ephemeral TLS cert which has the remote attestation
    /// evidence embedded, and which is bound to the given DNS name.
    pub fn generate(
        rng: &mut impl Crng,
        dns_names: &[&str],
        lifetime: Duration,
    ) -> anyhow::Result<Self> {
        // Generate a fresh key pair, which we'll use for the attestation cert.
        let key_pair = ed25519::KeyPair::from_rng(rng);

        // Get our enclave measurement and cert pk quoted by the enclave
        // platform. This process binds the cert pk to the quote evidence. When
        // a client verifies the Quote, they can also trust that the cert was
        // generated on a valid, genuine enclave. Once this trust is settled,
        // they can safely provision secrets onto the enclave via the newly
        // established secure TLS channel.
        //
        // Get the quote as an x509 cert extension that we'll embed in our
        // self-signed provisioning cert.
        let attestation_ext =
            super::quote::quote_enclave(rng, key_pair.public_key())
                .context("Failed to quote enclave")?;
        let cert_ext = attestation_ext.to_cert_extension();

        let now = time::OffsetDateTime::now_utc();
        let not_before = now - time::Duration::HOUR;
        let not_after = now + lifetime;

        let subject_alt_names = dns_names
            .iter()
            .map(|&dns_name| {
                Ia5String::from_str(dns_name).map(rcgen::SanType::DnsName)
            })
            .collect::<Result<Vec<_>, _>>()?;

        let cert_params = tls::build_rcgen_cert_params(
            Self::COMMON_NAME,
            not_before,
            not_after,
            subject_alt_names,
            key_pair.public_key(),
            |params: &mut rcgen::CertificateParams| {
                params.custom_extensions = vec![cert_ext];
            },
        );

        Ok(Self {
            key_pair,
            cert_params,
        })
    }

    /// Self-sign and DER-encode the attestation cert.
    pub fn serialize_der_self_signed(
        &self,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .self_signed(&self.key_pair.rcgen())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// DER-encode the attestation cert's private key.
    pub fn serialize_key_der(&self) -> LxPrivatePkcs8KeyDer {
        LxPrivatePkcs8KeyDer(self.key_pair.serialize_pkcs8_der().to_vec())
    }
}

#[cfg(test)]
mod test {
    use quid_crypto::rng::FastRng;
    use quid_tls::attest_client::verifier::{
        AttestationCertVerifier, EnclavePolicy,
    };
    use rustls::{
        client::danger::ServerCertVerifier,
        pki_types::{ServerName, UnixTime},
    };

    use super::*;

    #[test]
    fn test_gen_cert() {
        let mut rng = FastRng::from_u64(20240217);
        let dns_name = "hello.world";
        let lifetime = Duration::from_secs(3600);

        let cert =
            AttestationCert::generate(&mut rng, &[dns_name], lifetime).unwrap();
        let _cert_bytes = cert.serialize_der_self_signed().unwrap();
    }

    // Outside SGX we embed a dummy quote; verify it round-trips through the
    // dummy-quote verifier path.
    #[cfg(not(target_env = "sgx"))]
    #[test]
    fn test_verify_dummy_server_cert() {
        let mut rng = FastRng::new();
        let dns_name = quid_common::constants::NODE_RUN_DNS.to_owned();
        let lifetime = Duration::from_secs(60);

        let cert = AttestationCert::generate(&mut rng, &[&dns_name], lifetime)
            .unwrap();
        let cert_der = cert.serialize_der_self_signed().unwrap();

        let verifier = AttestationCertVerifier {
            expect_dummy_quote: true,
            enclave_policy: EnclavePolicy::dangerous_trust_any(),
        };

        let intermediates = &[];
        let ocsp_response = &[];

        verifier
            .verify_server_cert(
                &cert_der.into(),
                intermediates,
                &ServerName::try_from(dns_name.as_str()).unwrap(),
                ocsp_response,
                UnixTime::now(),
            )
            .unwrap();
    }

    /// Dump fresh attestation cert (intended for SGX only):
    ///
    /// ```bash
    /// cargo test -p quid-tls-attest-server --target=x86_64-fortanix-unknown-sgx dump_attest_cert -- --ignored --show-output
    /// ```
    #[test]
    #[cfg(target_env = "sgx")]
    #[ignore]
    fn dump_attest_cert() {
        use base64::Engine;
        use quid_enclave::enclave;

        use crate::cert::AttestationCert;

        let mut rng = FastRng::new();
        let dns_name = "localhost".to_owned();
        // Use a long lifetime so the test won't fail just bc the cert expired
        let lifetime = Duration::from_secs(60 * 60 * 24 * 365 * 1000);

        let attest_cert =
            AttestationCert::generate(&mut rng, &[&dns_name], lifetime)
                .unwrap();

        println!("measurement: '{}'", enclave::measurement());
        println!("Set `SERVER_MRENCLAVE` to this value.");

        let cert_der = attest_cert.serialize_der_self_signed().unwrap();
        let cert_base64 = base64::engine::general_purpose::STANDARD
            .encode(cert_der.as_slice());

        println!("attestation certificate:");
        println!("-----BEGIN CERTIFICATE-----");
        println!("{cert_base64}");
        println!("-----END CERTIFICATE-----");
    }
}
