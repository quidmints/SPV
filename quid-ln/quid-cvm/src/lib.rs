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

/// The AEAD core of [`SevSealer::seal`], with the firmware key SUPPLIED rather than
/// fetched.
///
/// WHY THE SPLIT: `sev_derived_key()` needs `/dev/sev-guest`, which exists only inside
/// a real SEV-SNP guest on AMD EPYC. With the fetch inlined, none of the sealing logic
/// below — label domain separation, the nonce-from-keyid rule, the tag check — could be
/// exercised anywhere we can actually run tests, so all of it shipped unverified. The
/// key is data; making it a parameter costs nothing and makes the crypto testable off
/// SEV. The trait impl still fetches from firmware and FAILS CLOSED.
fn seal_with_key(
    sev_key: &[u8; 32],
    random_keyid: [u8; 32],
    label: &[u8],
    data: Cow<'_, [u8]>,
) -> Result<Sealed<'static>, Error> {
    let key = LessSafeKey::new(sev_aesgcm_key(sev_key, label));
    let mut ct = data.into_owned();
    // The key is deterministic per (measurement, label), so the nonce MUST be
    // unique — take it from the random keyid (stored in the blob for unseal).
    let nonce = Nonce::assume_unique_for_key(random_keyid[..12].try_into().expect("32 >= 12"));
    key.seal_in_place_append_tag(nonce, Aad::empty(), &mut ct)
        .map_err(|_| Error::SealInputTooLarge)?;
    Ok(Sealed {
        keyrequest: Cow::Owned(random_keyid.to_vec()),
        ciphertext: Cow::Owned(ct),
    })
}

/// The AEAD core of [`SevSealer::unseal`]. See [`seal_with_key`] for why the key is a
/// parameter.
fn unseal_with_key(sev_key: &[u8; 32], sealed: Sealed<'_>, label: &[u8]) -> Result<Vec<u8>, Error> {
    if sealed.keyrequest.len() < 12 || sealed.ciphertext.len() < Sealed::TAG_LEN {
        return Err(Error::UnsealInputTooSmall);
    }
    let key = LessSafeKey::new(sev_aesgcm_key(sev_key, label));
    let nonce =
        Nonce::assume_unique_for_key(sealed.keyrequest[..12].try_into().expect("checked >= 12"));
    let mut ct = sealed.ciphertext.into_owned();
    let pt = key
        .open_in_place(nonce, Aad::empty(), &mut ct)
        .map_err(|_| Error::UnsealDecryptionError)?;
    let n = pt.len();
    ct.truncate(n);
    Ok(ct)
}

impl Sealer for SevSealer {
    fn seal(
        &self,
        random_keyid: [u8; 32],
        label: &[u8],
        data: Cow<'_, [u8]>,
    ) -> Result<Sealed<'static>, Error> {
        let sev_key = sev_derived_key().map_err(|_| Error::SevKeyUnavailable)?;
        seal_with_key(&sev_key, random_keyid, label, data)
    }

    fn unseal(&self, sealed: Sealed<'_>, label: &[u8]) -> Result<Vec<u8>, Error> {
        let sev_key = sev_derived_key().map_err(|_| Error::SevKeyUnavailable)?;
        unseal_with_key(&sev_key, sealed, label)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for the firmware key. Inside a real SEV-SNP guest this comes from
    /// `/dev/sev-guest` bound to the launch MEASUREMENT; the sealing logic cannot tell
    /// the difference, which is exactly why the split in `seal_with_key` is sound.
    const KEY_A: [u8; 32] = [0x11; 32];
    /// A DIFFERENT firmware key — stands for a different enclave build / measurement.
    const KEY_B: [u8; 32] = [0x22; 32];
    const KEYID: [u8; 32] = [0xAB; 32];
    const LABEL: &[u8] = b"quid::test::label";

    fn seal(key: &[u8; 32], keyid: [u8; 32], label: &[u8], pt: &[u8]) -> Sealed<'static> {
        seal_with_key(key, keyid, label, Cow::Borrowed(pt)).expect("seal")
    }

    // ─── report_data layout ───────────────────────────────────────────────────
    //
    // A relying party re-derives these 64 bytes from the keys the enclave presents and
    // compares against the report. If the layout here disagrees with the verifier by so
    // much as one byte, every attestation fails — or worse, a field lands where the
    // verifier is not looking and goes unchecked.

    #[test]
    fn identity_report_data_places_each_field_at_its_documented_offset() {
        let pk = [0x33u8; 32];
        let addr = [0x44u8; 20];
        let rd = identity_report_data(&pk, &addr);

        assert_eq!(&rd[..32], &pk[..], "tls pk must occupy [0..32]");
        assert_eq!(&rd[32..52], &addr[..], "evm address must occupy [32..52]");
        assert_eq!(&rd[52..], &[0u8; 12][..], "the tail must be zero padding");
    }

    #[test]
    fn identity_report_data_is_injective_in_both_fields() {
        let pk = [0x33u8; 32];
        let addr = [0x44u8; 20];
        let base = identity_report_data(&pk, &addr);

        let mut pk2 = pk;
        pk2[31] ^= 1;
        assert_ne!(base, identity_report_data(&pk2, &addr), "pk change was not bound");

        let mut addr2 = addr;
        addr2[19] ^= 1;
        assert_ne!(base, identity_report_data(&pk, &addr2), "address change was not bound");
    }

    // ─── the sealing round trip ───────────────────────────────────────────────

    #[test]
    fn seal_then_unseal_returns_the_plaintext() {
        let pt = b"the enclave's long-term signing key".to_vec();
        let sealed = seal(&KEY_A, KEYID, LABEL, &pt);
        assert_eq!(unseal_with_key(&KEY_A, sealed, LABEL).expect("unseal"), pt);
    }

    #[test]
    fn an_empty_plaintext_round_trips() {
        // Degenerate but legal: the blob is then exactly the 16-byte tag, which is the
        // boundary the `< TAG_LEN` guard sits on. An off-by-one there would reject it.
        let sealed = seal(&KEY_A, KEYID, LABEL, b"");
        assert_eq!(sealed.ciphertext.len(), Sealed::TAG_LEN);
        assert!(unseal_with_key(&KEY_A, sealed, LABEL).expect("unseal").is_empty());
    }

    #[test]
    fn the_ciphertext_does_not_contain_the_plaintext() {
        let pt = b"AAAAAAAAAAAAAAAAAAAAAAAA".to_vec();
        let sealed = seal(&KEY_A, KEYID, LABEL, &pt);
        assert!(
            !sealed.ciphertext.windows(pt.len()).any(|w| w == &pt[..]),
            "plaintext survived into the sealed blob"
        );
    }

    // ─── the two separations that carry the security claims ───────────────────

    /// THE RE-PROVISION BOUNDARY. The docs claim "a different enclave build cannot
    /// unseal". That property is entirely produced by the firmware key differing per
    /// measurement, so it is worth an explicit test: nothing else in this file enforces
    /// it, and a refactor that dropped the key from the KDF would still round-trip.
    #[test]
    fn a_different_firmware_key_cannot_unseal() {
        let sealed = seal(&KEY_A, KEYID, LABEL, b"secret");
        assert!(
            matches!(
                unseal_with_key(&KEY_B, sealed, LABEL),
                Err(Error::UnsealDecryptionError)
            ),
            "a blob sealed under one measurement opened under another"
        );
    }

    /// LABEL DOMAIN SEPARATION. `sev_aesgcm_key` mixes the label into HKDF; without it
    /// a blob sealed for one purpose could be opened by a code path asking for another.
    #[test]
    fn a_different_label_cannot_unseal() {
        let sealed = seal(&KEY_A, KEYID, LABEL, b"secret");
        assert!(
            matches!(
                unseal_with_key(&KEY_A, sealed, b"quid::test::other"),
                Err(Error::UnsealDecryptionError)
            ),
            "the label is not actually domain-separating the key"
        );
    }

    // ─── the nonce ────────────────────────────────────────────────────────────

    #[test]
    fn the_keyid_is_actually_used_as_the_nonce() {
        let mut other = KEYID;
        other[0] ^= 1; // within the first 12 bytes, which is the slice used as the nonce
        let a = seal(&KEY_A, KEYID, LABEL, b"same plaintext");
        let b = seal(&KEY_A, other, LABEL, b"same plaintext");
        assert_ne!(a.ciphertext, b.ciphertext, "the keyid did not reach the nonce");
    }

    /// A BYTE PAST THE NONCE MUST STILL BE CARRIED. Only `keyid[..12]` is the nonce, but
    /// all 32 bytes are stored in `keyrequest`. This pins that: two keyids differing
    /// only past byte 12 seal IDENTICALLY, so the stored keyrequest is the only thing
    /// distinguishing them. If a future change derived the nonce from more of the keyid,
    /// this test fails and the blob format change has to be deliberate.
    #[test]
    fn only_the_first_twelve_keyid_bytes_affect_the_ciphertext() {
        let mut other = KEYID;
        other[12] ^= 1;
        let a = seal(&KEY_A, KEYID, LABEL, b"same plaintext");
        let b = seal(&KEY_A, other, LABEL, b"same plaintext");
        assert_eq!(a.ciphertext, b.ciphertext);
        assert_ne!(a.keyrequest, b.keyrequest, "the full keyid must be stored");
    }

    /// THE CALLER OWNS NONCE UNIQUENESS, AND THIS PROVES IT IS NOT ENFORCED HERE.
    ///
    /// The key is deterministic per (measurement, label), so reusing a keyid reuses an
    /// AES-GCM nonce — which for GCM is catastrophic, not merely untidy: two blobs under
    /// the same nonce leak the XOR of their plaintexts and expose the authentication
    /// subkey, enabling forgery. `seal_with_key` cannot detect it (it is stateless), so
    /// the guarantee lives entirely in callers passing a fresh random `random_keyid`.
    /// This test documents that contract as executable fact rather than a comment.
    #[test]
    fn repeating_a_keyid_repeats_the_keystream() {
        let a = seal(&KEY_A, KEYID, LABEL, b"same plaintext");
        let b = seal(&KEY_A, KEYID, LABEL, b"same plaintext");
        assert_eq!(
            a.ciphertext, b.ciphertext,
            "if this ever differs, sealing gained internal randomness and the \
             caller-supplied-nonce contract documented above has changed"
        );
    }

    // ─── tamper detection and the length guards ───────────────────────────────

    #[test]
    fn a_flipped_ciphertext_byte_is_rejected() {
        let sealed = seal(&KEY_A, KEYID, LABEL, b"secret payload");
        let mut ct = sealed.ciphertext.into_owned();
        ct[0] ^= 1;
        let tampered = Sealed { keyrequest: sealed.keyrequest, ciphertext: Cow::Owned(ct) };
        assert!(matches!(
            unseal_with_key(&KEY_A, tampered, LABEL),
            Err(Error::UnsealDecryptionError)
        ));
    }

    #[test]
    fn a_flipped_tag_byte_is_rejected() {
        let sealed = seal(&KEY_A, KEYID, LABEL, b"secret payload");
        let mut ct = sealed.ciphertext.into_owned();
        let last = ct.len() - 1;
        ct[last] ^= 1;
        let tampered = Sealed { keyrequest: sealed.keyrequest, ciphertext: Cow::Owned(ct) };
        assert!(matches!(
            unseal_with_key(&KEY_A, tampered, LABEL),
            Err(Error::UnsealDecryptionError)
        ));
    }

    #[test]
    fn a_flipped_keyid_byte_is_rejected() {
        // The keyrequest is stored in the clear alongside the blob, so an attacker can
        // edit it. Changing it changes the nonce, which must fail the tag check.
        let sealed = seal(&KEY_A, KEYID, LABEL, b"secret payload");
        let mut kr = sealed.keyrequest.into_owned();
        kr[0] ^= 1;
        let tampered = Sealed { keyrequest: Cow::Owned(kr), ciphertext: sealed.ciphertext };
        assert!(matches!(
            unseal_with_key(&KEY_A, tampered, LABEL),
            Err(Error::UnsealDecryptionError)
        ));
    }

    #[test]
    fn a_short_keyrequest_is_refused_before_the_nonce_slice() {
        // Without the guard this is a panicking slice, not a clean error - the guard is
        // load-bearing against attacker-supplied blobs, so it gets a test.
        let sealed = seal(&KEY_A, KEYID, LABEL, b"payload");
        let truncated =
            Sealed { keyrequest: Cow::Owned(vec![0u8; 11]), ciphertext: sealed.ciphertext };
        assert!(matches!(
            unseal_with_key(&KEY_A, truncated, LABEL),
            Err(Error::UnsealInputTooSmall)
        ));
    }

    #[test]
    fn a_ciphertext_shorter_than_the_tag_is_refused() {
        let short = Sealed {
            keyrequest: Cow::Owned(KEYID.to_vec()),
            ciphertext: Cow::Owned(vec![0u8; Sealed::TAG_LEN - 1]),
        };
        assert!(matches!(
            unseal_with_key(&KEY_A, short, LABEL),
            Err(Error::UnsealInputTooSmall)
        ));
    }

    // ─── report parsing ───────────────────────────────────────────────────────

    #[test]
    fn sev_measurement_rejects_a_truncated_report_rather_than_panicking() {
        // A relying party feeds this attacker-influenced bytes. It must return Err, not
        // panic and not silently produce a zero measurement.
        assert!(sev_measurement(&[]).is_err());
        assert!(sev_measurement(&[0u8; 16]).is_err());
    }

    // ─── FAIL CLOSED off SEV-SNP ──────────────────────────────────────────────
    //
    // THE HEADLINE SECURITY CLAIM OF THIS CRATE, and the one test that must run on
    // ordinary hardware to mean anything. The whole point of `Error::SevKeyUnavailable`
    // is that sealing REFUSES off SEV-SNP instead of falling back to a weak or constant
    // key. A regression here would not be visible in any of the tests above: they inject
    // a key and would keep passing while the trait impl silently sealed with garbage.
    //
    // These tests are correct on both kinds of machine, and assert something real on
    // each: off SEV-SNP the operation must fail with SevKeyUnavailable; inside a real
    // guest it must succeed and round-trip.

    #[test]
    fn the_sealer_fails_closed_when_no_sev_firmware_is_present() {
        let on_sev = sev_derived_key().is_ok();
        let sealed = SevSealer.seal(KEYID, LABEL, Cow::Borrowed(b"secret"));

        match sealed {
            Err(Error::SevKeyUnavailable) => assert!(
                !on_sev,
                "sealing reported the key unavailable although the firmware answered"
            ),
            Ok(blob) => {
                assert!(on_sev, "sealing SUCCEEDED without an SEV-SNP firmware key");
                let out = SevSealer.unseal(blob, LABEL).expect("unseal on a real guest");
                assert_eq!(out, b"secret");
            }
            Err(_) => panic!("expected SevKeyUnavailable off SEV-SNP"),
        }
    }

    #[test]
    fn unsealing_also_fails_closed() {
        // Both directions matter: an unseal that fell back to a default key would hand
        // plaintext to a host that should not be able to read it.
        let blob = Sealed {
            keyrequest: Cow::Owned(KEYID.to_vec()),
            ciphertext: Cow::Owned(vec![0u8; Sealed::TAG_LEN + 4]),
        };
        match SevSealer.unseal(blob, LABEL) {
            // Off SEV-SNP: refused for want of a key, never opened with a fallback.
            Err(Error::SevKeyUnavailable) => assert!(sev_derived_key().is_err()),
            // On a real guest the key IS available, so this garbage blob must fail the
            // TAG check instead. Asserting this is what stops the test going vacuous on
            // the only hardware that can prove the happy path.
            Err(Error::UnsealDecryptionError) => assert!(sev_derived_key().is_ok()),
            Err(_) => panic!("unexpected error variant from unseal"),
            Ok(_) => panic!("a blob of zeroes was successfully unsealed"),
        }
    }

    /// THE HARDWARE TAIL. Off SEV-SNP every one of these must fail closed. On a real
    /// SEV-SNP guest -- the only place `Firmware::open()`'s happy path can be exercised --
    /// this is the test that proves the report path actually works end to end, so it
    /// asserts on BOTH sides rather than skipping when the hardware is present.
    #[test]
    fn the_report_helpers_match_the_hardware() {
        if sev_derived_key().is_err() {
            assert!(sev_report([0u8; 64]).is_err(), "a report was produced without firmware");
            assert!(attest_identity(&[0u8; 32], &[0u8; 20]).is_err());
            return;
        }

        let tls_pk = [0x33u8; 32];
        let evm_addr = [0x44u8; 20];
        let raw = attest_identity(&tls_pk, &evm_addr).expect("report on a real SEV-SNP guest");

        // The report must actually carry the identity binding we asked for, and its
        // measurement must parse via the typed accessor.
        let expected = identity_report_data(&tls_pk, &evm_addr);
        let report = AttestationReport::from_bytes(&raw).expect("typed parse of a real report");
        assert_eq!(&report.report_data[..], &expected[..], "report_data was not bound");
        assert_eq!(sev_measurement(&raw).expect("measurement").len(), 48);

        // And the derived key must be usable for a real round trip.
        let key = sev_derived_key().expect("derived key");
        let sealed = seal_with_key(&key, KEYID, LABEL, Cow::Borrowed(b"hardware"));
        let out = unseal_with_key(&key, sealed.expect("seal"), LABEL).expect("unseal");
        assert_eq!(out, b"hardware");
    }
}
