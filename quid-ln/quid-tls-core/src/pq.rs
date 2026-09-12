//! §BTC-4.5 — post-quantum key agreement for RA-TLS.
//!
//! # What this closes
//!
//! `quid-hop`'s enclave-to-enclave migration POSTs the **root seed** over RA-TLS
//! (`quid_hop::seed::provision_seed`). Under a classical-only key agreement that handshake is a
//! harvest-now-decrypt-later target with an unusually bad payoff: breaking a recorded TLS session
//! normally buys that session, but this one carries the seed every hop and channel key is derived
//! from, and a seed does not expire. That is why `§NO-POST-QUANTUM-ANYWHERE` retracted its
//! "taproot first" ranking in favour of the transport.
//!
//! # Why this is written here instead of switching providers
//!
//! `rustls` ships ML-KEM only in its **aws-lc-rs** provider. This workspace is pinned to the
//! **ring** provider — and to a *fork* of ring (`quidmints/ring`) — because everything targets
//! `x86_64-fortanix-unknown-sgx`, and aws-lc builds C and assembly. So the provider swap is the one
//! move that is closed to us.
//!
//! `rustls::crypto::SupportedKxGroup` is public, and its `start_and_complete` docstring names this
//! exact case: *"If there is such a data dependency (like key encapsulation mechanisms), this
//! function should be implemented."* So the hybrid is composed here, out of ring's X25519 and a
//! **pure-Rust** ML-KEM-768, and the SGX target is never left.
//!
//! # Wire format
//!
//! `X25519MLKEM768` (`NamedGroup` 0x11EC, draft-ietf-tls-ecdhe-mlkem). ⚠️ **The ML-KEM element
//! comes FIRST** in both key shares and in the concatenated secret — the opposite of
//! `SECP256R1MLKEM768`, which rustls' own source calls out as "dismal and unprincipled". Getting
//! this backwards produces a handshake that fails only against other implementations, never
//! against itself, so `pq_hybrid_negotiates_end_to_end` is a loopback test of the PLUMBING and the
//! byte layout is pinned separately by `share_layout_is_mlkem_first`.
//!
//! ```text
//!   client share : ML-KEM encapsulation key (1184) || X25519 public (32)  = 1216
//!   server share : ML-KEM ciphertext        (1088) || X25519 public (32)  = 1120
//!   shared secret: ML-KEM shared secret       (32) || X25519 secret  (32) =   64
//! ```
//!
//! # Randomness
//!
//! Every random byte comes from the **provider's own** `SecureRandom` — the same ring-backed source
//! that already generates the X25519 ephemeral keys — via `DecapsulationKey::from_seed` and
//! `encapsulate_deterministic`. ⚠️ Those are `ml-kem`'s "hazmat" entry points and the warning on
//! them is real: they are catastrophic if fed anything but uniform bytes. They are the right choice
//! *here* specifically because they let this module inherit the entropy source the enclave already
//! trusts, rather than introducing a second one (`getrandom` is not enabled, and in SGX a second
//! source is a second thing to get wrong).

use std::sync::LazyLock;

use ml_kem::array::Array;
use ml_kem::kem::{Decapsulate, KeyExport};
use ml_kem::{DecapsulationKey, EncapsulationKey, MlKem768};
use rustls::crypto::{
    ActiveKeyExchange, CompletedKeyExchange, SecureRandom, SharedSecret, SupportedKxGroup,
};
use rustls::{Error, NamedGroup, PeerMisbehaved, ProtocolVersion};

/// X25519 public key / shared secret length.
const X25519_LEN: usize = 32;
/// ML-KEM-768 encapsulation key, i.e. what the CLIENT sends.
const MLKEM768_ENCAP_LEN: usize = 1184;
/// ML-KEM-768 ciphertext, i.e. what the SERVER sends back.
const MLKEM768_CIPHERTEXT_LEN: usize = 1088;

const INVALID_KEY_SHARE: Error = Error::PeerMisbehaved(PeerMisbehaved::InvalidKeyShare);

/// The provider's own CSPRNG. Taken from `ring::default_provider()` rather than from
/// [`crate::QUID_CRYPTO_PROVIDER`], because that provider's `kx_groups` contain THIS group —
/// reading it back here would be a circular `LazyLock` initialisation and would deadlock on first
/// handshake rather than fail visibly.
static RNG: LazyLock<&'static dyn SecureRandom> =
    LazyLock::new(|| rustls::crypto::ring::default_provider().secure_random);

fn random<const N: usize>() -> Result<[u8; N], Error> {
    let mut buf = [0u8; N];
    RNG.fill(&mut buf)
        .map_err(|_| Error::General("quid-tls: CSPRNG failed for ML-KEM".into()))?;
    Ok(buf)
}

/// `X25519MLKEM768`: ring's X25519 composed with pure-Rust ML-KEM-768.
#[derive(Debug)]
pub struct X25519MlKem768;

/// The one value to register in `CryptoProvider::kx_groups`.
pub static X25519MLKEM768: &dyn SupportedKxGroup = &X25519MlKem768;

fn classical() -> &'static dyn SupportedKxGroup {
    rustls::crypto::ring::kx_group::X25519
}

/// Split a received share into (ML-KEM, X25519). ML-KEM is first on this group.
fn split(share: &[u8], pq_len: usize) -> Result<(&[u8], &[u8]), Error> {
    if share.len() != pq_len + X25519_LEN {
        return Err(INVALID_KEY_SHARE);
    }
    Ok(share.split_at(pq_len))
}

impl SupportedKxGroup for X25519MlKem768 {
    fn start(&self) -> Result<Box<dyn ActiveKeyExchange>, Error> {
        let classical = classical().start()?;

        let seed = Array(random::<64>()?);
        let decaps: DecapsulationKey<MlKem768> = DecapsulationKey::from_seed(seed);
        let encaps_bytes = decaps.encapsulation_key().to_bytes();

        let mut combined_pub_key = Vec::with_capacity(MLKEM768_ENCAP_LEN + X25519_LEN);
        combined_pub_key.extend_from_slice(encaps_bytes.as_slice());
        combined_pub_key.extend_from_slice(classical.pub_key());

        Ok(Box::new(ActiveX25519MlKem768 { classical, decaps, combined_pub_key }))
    }

    fn start_and_complete(&self, client_share: &[u8]) -> Result<CompletedKeyExchange, Error> {
        let (pq_share, classical_share) = split(client_share, MLKEM768_ENCAP_LEN)?;

        let cl = classical().start_and_complete(classical_share)?;

        let encaps_key = Array::try_from(pq_share).map_err(|_| INVALID_KEY_SHARE)?;
        let encaps = EncapsulationKey::<MlKem768>::new(&encaps_key).map_err(|_| INVALID_KEY_SHARE)?;
        let (ciphertext, pq_secret) = encaps.encapsulate_deterministic(&Array(random::<32>()?));

        let mut pub_key = Vec::with_capacity(MLKEM768_CIPHERTEXT_LEN + X25519_LEN);
        pub_key.extend_from_slice(ciphertext.as_slice());
        pub_key.extend_from_slice(&cl.pub_key);

        let mut secret = Vec::with_capacity(2 * X25519_LEN);
        secret.extend_from_slice(pq_secret.as_slice());
        secret.extend_from_slice(cl.secret.secret_bytes());

        Ok(CompletedKeyExchange {
            group: self.name(),
            pub_key,
            secret: SharedSecret::from(&secret[..]),
        })
    }

    fn name(&self) -> NamedGroup {
        NamedGroup::X25519MLKEM768
    }

    /// TLS 1.3 only — which is all `QUID_TLS_PROTOCOL_VERSIONS` offers anyway.
    fn usable_for_version(&self, version: ProtocolVersion) -> bool {
        version == ProtocolVersion::TLSv1_3
    }
}

struct ActiveX25519MlKem768 {
    classical: Box<dyn ActiveKeyExchange>,
    decaps: DecapsulationKey<MlKem768>,
    combined_pub_key: Vec<u8>,
}

impl ActiveKeyExchange for ActiveX25519MlKem768 {
    fn complete(self: Box<Self>, peer_pub_key: &[u8]) -> Result<SharedSecret, Error> {
        let (pq_share, classical_share) = split(peer_pub_key, MLKEM768_CIPHERTEXT_LEN)?;

        let cl = self.classical.complete(classical_share)?;
        let ciphertext = Array::try_from(pq_share).map_err(|_| INVALID_KEY_SHARE)?;
        let pq = self.decaps.decapsulate(&ciphertext);

        let mut secret = Vec::with_capacity(2 * X25519_LEN);
        secret.extend_from_slice(pq.as_slice());
        secret.extend_from_slice(cl.secret_bytes());
        Ok(SharedSecret::from(&secret[..]))
    }

    /// Lets a peer that does not know this group select the X25519 half of our share instead of
    /// failing the handshake. This is the graceful-degradation half of offering both groups, and it
    /// is not a downgrade vector: TLS 1.3 covers group selection in the transcript, so a MITM
    /// cannot force it silently.
    fn hybrid_component(&self) -> Option<(NamedGroup, &[u8])> {
        Some((self.classical.group(), self.classical.pub_key()))
    }

    fn complete_hybrid_component(
        self: Box<Self>,
        peer_pub_key: &[u8],
    ) -> Result<SharedSecret, Error> {
        self.classical.complete(peer_pub_key)
    }

    fn pub_key(&self) -> &[u8] {
        &self.combined_pub_key
    }

    fn group(&self) -> NamedGroup {
        NamedGroup::X25519MLKEM768
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 🔑 THE BYTE LAYOUT, PINNED SEPARATELY FROM THE HANDSHAKE. A loopback handshake agrees with
    /// itself under EITHER ordering, so it cannot catch ML-KEM-vs-X25519 being swapped — and that
    /// swap is exactly the mistake this group invites, because `SECP256R1MLKEM768` orders them the
    /// other way. This asserts the sizes and positions against the draft directly.
    #[test]
    fn share_layout_is_mlkem_first() {
        let active = X25519MlKem768.start().unwrap();
        let share = active.pub_key();
        assert_eq!(share.len(), MLKEM768_ENCAP_LEN + X25519_LEN, "client share is 1216 bytes");

        // The X25519 half must be the LAST 32 bytes, and must equal the classical component we
        // advertise for degradation — which is what proves the ML-KEM part is first.
        let (_, x25519) = share.split_at(MLKEM768_ENCAP_LEN);
        let (group, classical_pub) = active.hybrid_component().expect("hybrid component");
        assert_eq!(group, NamedGroup::X25519);
        assert_eq!(x25519, classical_pub, "X25519 occupies the TAIL; ML-KEM is first");

        let completed = X25519MlKem768.start_and_complete(share).unwrap();
        assert_eq!(
            completed.pub_key.len(),
            MLKEM768_CIPHERTEXT_LEN + X25519_LEN,
            "server share is 1120 bytes"
        );
        assert_eq!(completed.group, NamedGroup::X25519MLKEM768);
    }

    /// Both sides derive the SAME 64-byte secret, and it is genuinely both halves: 32 bytes of
    /// ML-KEM followed by 32 of X25519.
    #[test]
    fn both_sides_agree_on_the_hybrid_secret() {
        let client = X25519MlKem768.start().unwrap();
        let server = X25519MlKem768
            .start_and_complete(client.pub_key())
            .unwrap();
        let client_secret = client.complete(&server.pub_key).unwrap();

        assert_eq!(client_secret.secret_bytes().len(), 2 * X25519_LEN, "64-byte hybrid secret");
        assert_eq!(
            client_secret.secret_bytes(),
            server.secret.secret_bytes(),
            "client and server must derive the same hybrid secret"
        );
    }

    /// A share of the wrong LENGTH must be refused rather than silently mis-split. Without the
    /// length check, a short share would split at 1184 and hand X25519 an empty slice.
    #[test]
    fn malformed_shares_are_refused() {
        assert!(X25519MlKem768.start_and_complete(&[0u8; 32]).is_err(), "too short");
        assert!(
            X25519MlKem768
                .start_and_complete(&[0u8; MLKEM768_ENCAP_LEN + X25519_LEN + 1])
                .is_err(),
            "too long"
        );
        // Right length, garbage ML-KEM key: must be an error, not a panic.
        assert!(
            X25519MlKem768
                .start_and_complete(&[0u8; MLKEM768_ENCAP_LEN + X25519_LEN])
                .is_err(),
            "well-sized but invalid"
        );
    }
}
