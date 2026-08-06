//! Contains the CA cert and end-entity certs for "shared seed" mTLS.

use std::str::FromStr;

use quid_common::root_seed::RootSeed;
use quid_crypto::{ed25519, rng::Crng};
use rcgen::string::Ia5String;

use crate as tls;
use crate::{
    ed25519_ext::{Ed25519KeyPairExt, RcgenEd25519KeyPair},
    types::{LxCertificateDer, LxPrivatePkcs8KeyDer},
};

/// The "ephemeral issuing" CA cert derived from the root seed.
/// The keypair is derived from the root seed.
pub struct EphemeralIssuingCaCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

/// The ephemeral end-entity cert used by the client.
/// Signed by the "ephemeral issuing" CA cert.
///
/// The key pair for the client cert is sampled.
pub struct EphemeralClientCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

/// The ephemeral end-entity cert used by the server.
/// Signed by the "ephemeral issuing" CA cert.
///
/// The key pair for the server cert is sampled.
pub struct EphemeralServerCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

/// The "revocable issuing" CA cert derived from the root seed.
pub struct RevocableIssuingCaCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

/// The revocable end-entity cert used by the client.
/// Signed by the "revocable issuing" CA cert.
pub struct RevocableClientCert {
    key_pair: ed25519::KeyPair,
    cert_params: rcgen::CertificateParams,
}

// --- impl ephemeral certs --- //

impl EphemeralIssuingCaCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    // TODO(max): Ideally rename this to "Quid ephemeral issuing CA cert", but
    // need to be careful about backwards compatibility. Both client and server
    // would need to trust the old and new CAs before the old CA can be removed.
    const COMMON_NAME: &'static str = "Quid shared seed CA cert";

    /// Deterministically derive the CA cert from the [`RootSeed`].
    pub fn from_root_seed(root_seed: &RootSeed) -> Self {
        let key_pair = root_seed.derive_ephemeral_issuing_ca_key_pair();
        // We want the cert to be deterministic, so no expiration
        let not_before = rcgen::date_time_ymd(1975, 1, 1);
        let not_after = rcgen::date_time_ymd(4096, 1, 1);

        let cert_params = tls::build_rcgen_cert_params(
            Self::COMMON_NAME,
            not_before,
            not_after,
            crate::DEFAULT_SUBJECT_ALT_NAMES.clone(),
            key_pair.public_key(),
            |params: &mut rcgen::CertificateParams| {
                // This is a CA cert, and there should be 0 intermediate certs.
                params.is_ca =
                    rcgen::IsCa::Ca(rcgen::BasicConstraints::Constrained(0));
            },
        );

        Self {
            key_pair,
            cert_params,
        }
    }

    /// Self-sign and DER-encode the CA cert.
    pub fn serialize_der_self_signed(
        &self,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .self_signed(&self.key_pair.rcgen())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// [`rcgen::Issuer`] that can sign child certs.
    fn issuer(&self) -> rcgen::Issuer<'_, RcgenEd25519KeyPair<'_>> {
        rcgen::Issuer::from_params(&self.cert_params, self.key_pair.rcgen())
    }
}

impl EphemeralClientCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    const COMMON_NAME: &'static str = "Quid ephemeral client cert";

    /// Generate an ephemeral client cert with a randomly-sampled keypair.
    pub fn generate_from_rng(rng: &mut impl Crng) -> Self {
        let key_pair = ed25519::KeyPair::from_rng(rng);
        let now = time::OffsetDateTime::now_utc();
        let not_before = now - time::Duration::HOUR;
        // TODO(max): We want ephemeral cert lifetimes (+-1 hour), but some
        // nodes might live longer than that, causing TLS handshakes to fail.
        // We use a long default for now (90 days) until automatic cert rotation
        // is implemented. Most likely design is to spawn a tokio task that
        // regenerates the cert every once in a while, then `ArcSwap`s the new
        // cert into the `ResolvesClientCert`/`ResolvesServerCert` resolver used
        // on both the client and server side.
        let not_after = now + (90 * time::Duration::DAY);
        // let not_after = now + time::Duration::HOUR;

        let cert_params = tls::build_rcgen_cert_params(
            Self::COMMON_NAME,
            not_before,
            not_after,
            // Client auth fails without a SAN, even though it is ignored..
            crate::DEFAULT_SUBJECT_ALT_NAMES.clone(),
            key_pair.public_key(),
            |_| (),
        );

        Self {
            key_pair,
            cert_params,
        }
    }

    /// CA-sign and DER-encode the cert.
    pub fn serialize_der_ca_signed(
        &self,
        ca_cert: &EphemeralIssuingCaCert,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .signed_by(&self.key_pair.rcgen(), &ca_cert.issuer())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// DER-encode the cert's private key.
    pub fn serialize_key_der(&self) -> LxPrivatePkcs8KeyDer {
        LxPrivatePkcs8KeyDer(self.key_pair.serialize_pkcs8_der().to_vec())
    }
}

impl EphemeralServerCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    const COMMON_NAME: &'static str = "Quid ephemeral server cert";

    /// Generate an ephemeral server cert with a randomly-sampled keypair.
    pub fn from_rng(
        rng: &mut impl Crng,
        dns_names: &[&str],
    ) -> anyhow::Result<Self> {
        let key_pair = ed25519::KeyPair::from_rng(rng);
        let now = time::OffsetDateTime::now_utc();
        let not_before = now - time::Duration::HOUR;
        // TODO(max): We want ephemeral cert lifetimes (+-1 hour), but some
        // nodes might live longer than that, causing TLS handshakes to fail.
        // We use a long default for now (90 days) until automatic cert rotation
        // is implemented. Most likely design is to spawn a tokio task that
        // regenerates the cert every once in a while, then `ArcSwap`s the new
        // cert into the `ResolvesClientCert`/`ResolvesServerCert` resolver used
        // on both the client and server side.
        let not_after = now + (90 * time::Duration::DAY);

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
            |_| (),
        );

        Ok(Self {
            key_pair,
            cert_params,
        })
    }

    /// CA-sign and DER-encode the cert.
    pub fn serialize_der_ca_signed(
        &self,
        ca_cert: &EphemeralIssuingCaCert,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .signed_by(&self.key_pair.rcgen(), &ca_cert.issuer())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// DER-encode the cert's private key.
    pub fn serialize_key_der(&self) -> LxPrivatePkcs8KeyDer {
        LxPrivatePkcs8KeyDer(self.key_pair.serialize_pkcs8_der().to_vec())
    }
}

// --- impl revocable --- //

impl RevocableIssuingCaCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    const COMMON_NAME: &'static str = "Quid revocable issuing CA cert";

    /// Deterministically derive the CA cert from the [`RootSeed`].
    pub fn from_root_seed(root_seed: &RootSeed) -> Self {
        let key_pair = root_seed.derive_revocable_issuing_ca_key_pair();
        // We want the cert to be deterministic, so no expiration
        let not_before = rcgen::date_time_ymd(1975, 1, 1);
        let not_after = rcgen::date_time_ymd(4096, 1, 1);

        let cert_params = tls::build_rcgen_cert_params(
            Self::COMMON_NAME,
            not_before,
            not_after,
            crate::DEFAULT_SUBJECT_ALT_NAMES.clone(),
            key_pair.public_key(),
            |params: &mut rcgen::CertificateParams| {
                // This is a CA cert, and there should be 0 intermediate certs.
                params.is_ca =
                    rcgen::IsCa::Ca(rcgen::BasicConstraints::Constrained(0));
            },
        );

        Self {
            key_pair,
            cert_params,
        }
    }

    /// DER-encode and self-sign the CA cert.
    pub fn serialize_der_self_signed(
        &self,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .self_signed(&self.key_pair.rcgen())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// [`rcgen::Issuer`] that can sign child certs.
    fn issuer(&self) -> rcgen::Issuer<'_, RcgenEd25519KeyPair<'_>> {
        rcgen::Issuer::from_params(&self.cert_params, self.key_pair.rcgen())
    }
}

impl RevocableClientCert {
    /// The Common Name (CN) component of this cert's Distinguished Name (DN).
    const COMMON_NAME: &'static str = "Quid revocable client cert";

    /// Generate an revocable client cert with a randomly-sampled keypair.
    pub fn generate_from_rng(rng: &mut impl Crng) -> Self {
        let key_pair = ed25519::KeyPair::from_rng(rng);
        // Since the certs are revocable they should also have no hard-coded
        // expiration, so SDK integrators can avoid the hassle of having to
        // rotate their client certs when it is not needed.
        let not_before = rcgen::date_time_ymd(1975, 1, 1);
        let not_after = rcgen::date_time_ymd(4096, 1, 1);

        let cert_params = tls::build_rcgen_cert_params(
            Self::COMMON_NAME,
            not_before,
            not_after,
            // Client auth fails without a SAN, even though it is ignored..
            crate::DEFAULT_SUBJECT_ALT_NAMES.clone(),
            key_pair.public_key(),
            |_| (),
        );

        Self {
            key_pair,
            cert_params,
        }
    }

    pub fn public_key(&self) -> &ed25519::PublicKey {
        self.key_pair.public_key()
    }

    /// CA-sign and DER-encode the cert.
    pub fn serialize_der_ca_signed(
        &self,
        ca_cert: &RevocableIssuingCaCert,
    ) -> Result<LxCertificateDer, rcgen::Error> {
        self.cert_params
            .signed_by(&self.key_pair.rcgen(), &ca_cert.issuer())
            .map(|cert| LxCertificateDer(cert.der().to_vec()))
    }

    /// DER-encode the cert's private key.
    pub fn serialize_key_der(&self) -> LxPrivatePkcs8KeyDer {
        LxPrivatePkcs8KeyDer(self.key_pair.serialize_pkcs8_der().to_vec())
    }
}

#[cfg(test)]
mod test {
    use quid_crypto::rng::FastRng;
    use quid_hex::hex;
    use rustls::pki_types::CertificateDer;

    use super::*;

    #[test]
    fn test_certs_parse_successfully() {
        let mut rng = FastRng::from_u64(20240215);
        let root_seed = RootSeed::from_rng(&mut rng);

        let assert_parseable = |cert_der: LxCertificateDer| {
            let cert_der = CertificateDer::from(cert_der.as_slice());
            let _ = webpki::EndEntityCert::try_from(&cert_der).unwrap();
        };

        let eph_ca_cert = EphemeralIssuingCaCert::from_root_seed(&root_seed);
        let eph_ca_cert_der = eph_ca_cert.serialize_der_self_signed().unwrap();
        assert_parseable(eph_ca_cert_der);

        let eph_client_cert = EphemeralClientCert::generate_from_rng(&mut rng);
        let eph_client_cert_der = eph_client_cert
            .serialize_der_ca_signed(&eph_ca_cert)
            .unwrap();
        assert_parseable(eph_client_cert_der);

        let dns_names = &["run.quid.io"];
        let eph_server_cert =
            EphemeralServerCert::from_rng(&mut rng, dns_names).unwrap();
        let eph_server_cert_der = eph_server_cert
            .serialize_der_ca_signed(&eph_ca_cert)
            .unwrap();
        assert_parseable(eph_server_cert_der);

        let rev_ca_cert = RevocableIssuingCaCert::from_root_seed(&root_seed);
        let rev_ca_cert_der = rev_ca_cert.serialize_der_self_signed().unwrap();
        assert_parseable(rev_ca_cert_der);

        let rev_client_cert = RevocableClientCert::generate_from_rng(&mut rng);
        let rev_client_cert_der = rev_client_cert
            .serialize_der_ca_signed(&rev_ca_cert)
            .unwrap();
        assert_parseable(rev_client_cert_der);
    }

    /// Check that the derived CA keypairs are the same as a snapshot from the
    /// same [`RootSeed`].
    ///
    /// ```
    /// $ cargo test -p quid-api derived_ca_keypair_snapshot_test -- --show-output
    /// ```
    /// ⚠️ REPINNED 2026-08-07 — CAUSE PROVEN BEFORE REPINNING, do not repeat blindly.
    /// These snapshots encoded PRE-RENAME values. `RootSeed::HKDF_SALT` is
    /// `QUID-REALM::RootSeed` (`quid-common/src/root_seed.rs:41`), renamed from the
    /// vendored Lexe predecessor. The salt feeds EVERY `derive()` call, so the rename
    /// changed every derived key — the labels themselves ("shared seed tls ca key pair")
    /// never moved. The old certs carried `lexe-app`/`lexe.app`; the derived ones carry
    /// `quid-app`/`quid.io`, and the public keys differ because the SALT differs.
    /// NEVER restore the old prefix to make these pass. If they fail again, prove the
    /// cause the same way before touching them — a real derivation regression looks
    /// identical to this at the assertion.
    #[test]
    fn derived_ca_keypair_snapshot_test() {
        let root_seed = RootSeed::from_u64(20240514);

        fn do_keypair_snapshot_test(
            derived_keypair: ed25519::KeyPair,
            snapshot_keypair_seed_hex: &str,
        ) {
            let derived_keypair_seed = derived_keypair.secret_key();

            // Uncomment to regenerate
            let derived_keypair_hex = hex::display(derived_keypair_seed);
            println!("---KP---");
            println!("{derived_keypair_hex}");

            let snapshot_keypair_seed =
                hex::decode(snapshot_keypair_seed_hex).unwrap();

            assert_eq!(derived_keypair_seed, snapshot_keypair_seed.as_slice());
        }

        do_keypair_snapshot_test(
            root_seed.derive_ephemeral_issuing_ca_key_pair(),
            "897cd09bb8895f8949cf75ffccd47ca07c82c03bdfe2ae07266ed0194652efbd",
        );

        do_keypair_snapshot_test(
            root_seed.derive_revocable_issuing_ca_key_pair(),
            "ce1dcccaee8663372141c65f7972a25f8520e78efb484c6143ccb9333d9a68b8",
        );
    }

    /// Tests that a freshly derived ephemeral issuing CA cert serialized into
    /// DER is bit-for-bit the same as a snapshot from the same [`RootSeed`].
    ///
    /// ```
    /// $ cargo test -p quid-api ca_cert_snapshot_test -- --show-output
    /// ```
    // Bit-for-bit serialization compatibility is a stronger guarantee than we
    // need - I wrote the test this way to save time. If ephemeral issuing CA
    // cert generation needs to change in a backwards compatible way, update
    // this test so that we only check that *handshakes* between the older and
    // newer certs succeed (which is a bit more annoying to write)
    #[test]
    fn ca_cert_snapshot_test() {
        let root_seed = RootSeed::from_u64(20240514);

        #[track_caller]
        fn do_ca_cert_snapshot_test(
            derived_cert_der: LxCertificateDer,
            snapshot_cert_der_hex: &str,
        ) {
            // Uncomment to regenerate
            let derived_cert_hex = hex::display(derived_cert_der.as_slice());
            println!("---CERT---");
            println!("{derived_cert_hex}");

            let snapshot_cert_der = hex::decode(snapshot_cert_der_hex).unwrap();
            if derived_cert_der.as_slice() != snapshot_cert_der.as_slice() {
                let snapshot_cert_pem =
                    LxCertificateDer(snapshot_cert_der.clone()).serialize_pem();
                let derived_cert_pem = derived_cert_der.serialize_pem();
                panic!(
                    "ca cert is different:\
                     \n\nsnapshot:\n{snapshot_cert_pem}\n\
                     ~~~\n\
                     derived:\n{derived_cert_pem}"
                )
            }
        }

        {
            let derived_eph_ca_cert =
                EphemeralIssuingCaCert::from_root_seed(&root_seed);
            let derived_eph_ca_cert_der =
                derived_eph_ca_cert.serialize_der_self_signed().unwrap();
            do_ca_cert_snapshot_test(
                derived_eph_ca_cert_der,
                "308201ad3082015fa00302010202142b416f2fbd452e3b359e3fcbde28aa66ad7aa824300506032b65703050310b300906035504060c025553310b300906035504080c0243413111300f060355040a0c08717569642d6170703121301f06035504030c185175696420736861726564207365656420434120636572743020170d3735303130313030303030305a180f34303936303130313030303030305a3050310b300906035504060c025553310b300906035504080c0243413111300f060355040a0c08717569642d6170703121301f06035504030c18517569642073686172656420736565642043412063657274302a300506032b6570032100fc6959aeff3b0318037ff9ecd8eaa4773e62121e6958907b7cf5a97fb73f2fd2a349304730120603551d11040b30098207717569642e696f301d0603551d0e041604142b416f2fbd452e3b359e3fcbde28aa66ad7aa82430120603551d130101ff040830060101ff020100300506032b65700341001b8547f445cca4cc465364c96d2d8fa30fa07b3cf0184aca380289352ee53cd0bc119df7a52ac9e2e874f0dbe3b44452334b678cb4d843c1d94011729438d100",
            );
        }

        {
            let derived_rev_ca_cert =
                RevocableIssuingCaCert::from_root_seed(&root_seed);
            let derived_rev_ca_cert_der =
                derived_rev_ca_cert.serialize_der_self_signed().unwrap();

            do_ca_cert_snapshot_test(
                derived_rev_ca_cert_der,
                "308201b93082016ba00302010202147067332a4244ee1dbe34d0138414f6caed5aa53a300506032b65703056310b300906035504060c025553310b300906035504080c0243413111300f060355040a0c08717569642d6170703127302506035504030c1e51756964207265766f6361626c652069737375696e6720434120636572743020170d3735303130313030303030305a180f34303936303130313030303030305a3056310b300906035504060c025553310b300906035504080c0243413111300f060355040a0c08717569642d6170703127302506035504030c1e51756964207265766f6361626c652069737375696e672043412063657274302a300506032b6570032100a4b01e2d929f3eb35a7c92a4ecf243a20fbd1b458ca198d095ee3497a722cd6ea349304730120603551d11040b30098207717569642e696f301d0603551d0e041604147067332a4244ee1dbe34d0138414f6caed5aa53a30120603551d130101ff040830060101ff020100300506032b6570034100c6cab9bf1f41dff228038f40e939048e647663b65f6dd00067ab6b906c1be6c98472109e68239a8f3498d4f964ae02e789ede3dabfb2e0b8a96123bad939af03",
            );
        }
    }
}
