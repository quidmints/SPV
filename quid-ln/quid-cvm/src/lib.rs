//! Confidential-VM backend implementations using battle-tested VENDOR crates,
//! kept out of dependency-minimal `quid-enclave`. SEV-SNP uses AMD's reference
//! `virtee/sev` crate (no hand-rolled ioctls / report parsing); TDX (`tss-esapi`
//! vTPM) and Nitro (AWS NSM/KMS) will follow behind the same seam.

use std::borrow::Cow;

use quid_enclave::enclave::{Error, Sealed, Sealer};
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::hkdf::{self, HKDF_SHA256};
use sev::firmware::guest::{AttestationReport, DerivedKey, Firmware, GuestFieldSelect};

/// `GuestFieldSelect` MEASUREMENT bit (bit 3): bind the derived key to the VM
/// launch measurement, so a different enclave build derives a different key — the
/// SEV analogue of SGX EGETKEY's MRENCLAVE policy.
const GUEST_FIELD_MEASUREMENT: u64 = 1 << 3;

/// Fetch the SEV-SNP measurement-bound derived key (the seal key) via the vetted
/// `sev` crate's `/dev/sev-guest` firmware interface. FAILS CLOSED off SEV-SNP (the
/// device open / firmware call errors). The host cannot read this key.
pub fn sev_derived_key() -> anyhow::Result<[u8; 32]> {
    let mut fw = Firmware::open()?;
    let req = DerivedKey::new(
        false,                                    // root_key_select: VCEK
        GuestFieldSelect(GUEST_FIELD_MEASUREMENT),
        0,                                        // vmpl
        0,                                        // guest_svn
        0,                                        // tcb_version
        None,
    );
    let key = fw.get_derived_key(None, req)?;
    Ok(key)
}

/// Fetch a SEV-SNP attestation report binding `report_data` (e.g. the enclave's
/// TLS pk ‖ EVM address), via the `sev` crate. Returns the raw report bytes to send
/// to the relying party (which verifies them against the AMD cert chain). FAILS
/// CLOSED off SEV-SNP.
pub fn sev_report(report_data: [u8; 64]) -> anyhow::Result<Vec<u8>> {
    let mut fw = Firmware::open()?;
    let raw = fw.get_report(None, Some(report_data), None)?;
    Ok(raw)
}

// ─── Sealing: SEV-SNP measurement-bound firmware key + ring AEAD ──────────────

/// Derive the AES-256-GCM sealing key from the SEV firmware key + a
/// domain-separation `label`, using `ring`'s HKDF (not a hand-rolled KDF).
fn sev_aesgcm_key(sev_key: &[u8; 32], label: &[u8]) -> UnboundKey {
    let mut salt = [0u8; 32];
    let s = b"QUID-REALM::SevSealing";
    salt[..s.len()].copy_from_slice(s);
    UnboundKey::from(
        hkdf::Salt::new(HKDF_SHA256, &salt)
            .extract(sev_key.as_slice())
            .expand(&[label], &AES_256_GCM)
            .expect("HKDF expand to an AES-256-GCM key"),
    )
}

/// The SEV-SNP sealer: seals with the measurement-bound firmware key (the host
/// cannot read it), so a different enclave build cannot unseal — the re-provision
/// boundary, like SGX MRENCLAVE. Implements the enclave's [`Sealer`] trait so it
/// drops into the same seal path as the native SGX/mock sealer. FAILS CLOSED if the
/// firmware key can't be derived.
pub struct SevSealer;

impl Sealer for SevSealer {
    fn seal(
        &self,
        random_keyid: [u8; 32],
        label: &[u8],
        data: Cow<'_, [u8]>,
    ) -> Result<Sealed<'static>, Error> {
        let sev_key = sev_derived_key().map_err(|_| Error::SevKeyUnavailable)?;
        let key = LessSafeKey::new(sev_aesgcm_key(&sev_key, label));
        let mut ct = data.into_owned();
        // The key is deterministic per (measurement, label), so the nonce MUST be
        // unique — take it from the random keyid (stored in the blob for unseal).
        let nonce = Nonce::assume_unique_for_key(
            random_keyid[..12].try_into().expect("32 >= 12"),
        );
        key.seal_in_place_append_tag(nonce, Aad::empty(), &mut ct)
            .map_err(|_| Error::SealInputTooLarge)?;
        Ok(Sealed {
            keyrequest: Cow::Owned(random_keyid.to_vec()),
            ciphertext: Cow::Owned(ct),
        })
    }

    fn unseal(&self, sealed: Sealed<'_>, label: &[u8]) -> Result<Vec<u8>, Error> {
        if sealed.keyrequest.len() < 12 || sealed.ciphertext.len() < Sealed::TAG_LEN {
            return Err(Error::UnsealInputTooSmall);
        }
        let sev_key = sev_derived_key().map_err(|_| Error::SevKeyUnavailable)?;
        let key = LessSafeKey::new(sev_aesgcm_key(&sev_key, label));
        let nonce = Nonce::assume_unique_for_key(
            sealed.keyrequest[..12].try_into().expect("checked >= 12"),
        );
        let mut ct = sealed.ciphertext.into_owned();
        let pt = key
            .open_in_place(nonce, Aad::empty(), &mut ct)
            .map_err(|_| Error::UnsealDecryptionError)?;
        let n = pt.len();
        ct.truncate(n);
        Ok(ct)
    }
}

// ─── Attestation identity binding + measurement (via the sev crate) ──────────

/// Assemble the 64-byte `report_data` binding the enclave's identity keys: TLS
/// cert pk in `[0..32]`, EVM address in `[32..52]` (trailing 12 zero). A relying
/// party checks this against the keys the enclave presents.
pub fn identity_report_data(tls_pk: &[u8; 32], evm_addr: &[u8; 20]) -> [u8; 64] {
    let mut rd = [0u8; 64];
    rd[..32].copy_from_slice(tls_pk);
    rd[32..52].copy_from_slice(evm_addr);
    rd
}

/// Fetch a SEV report bound to this enclave's identity keys (TLS pk ‖ EVM addr).
pub fn attest_identity(tls_pk: &[u8; 32], evm_addr: &[u8; 20]) -> anyhow::Result<Vec<u8>> {
    sev_report(identity_report_data(tls_pk, evm_addr))
}

/// Parse the launch MEASUREMENT from a raw SEV report via the sev crate's typed
/// `AttestationReport` (no hand-rolled offsets).
pub fn sev_measurement(raw: &[u8]) -> anyhow::Result<[u8; 48]> {
    let report = AttestationReport::from_bytes(raw)?;
    let mut m = [0u8; 48];
    m.copy_from_slice(&report.measurement[..]);
    Ok(m)
}
