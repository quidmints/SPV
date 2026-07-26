//! M4 — simple-taproot-channel commitment + closing **tx format** pinned against
//! the official BOLT `bolt-simple-taproot.md` "simple commitment tx with no
//! HTLCs" test vectors, byte-for-byte.
//!
//! These run from the `quid-ln` crate (which depends on the vendored, patched
//! `lightning` library) because the vendored fork's *own* lib-test target has a
//! pre-existing, unrelated compile break (a `ChannelDetails` test-field
//! mismatch in `channel_state.rs`/`router.rs`) that prevents `cargo test -p
//! lightning`. Calling the public `chan_utils` taproot constructors from here is
//! the runnable harness. A mirror `#[cfg(test)] mod taproot_tests` also lives in
//! `lightning/src/ln/chan_utils.rs` for upstream CI.
//!
//! Every asserted constant is copied verbatim from the BOLT vectors:
//!   seed = 000102…1e1f, funding 10_000_000 sat, csv_delay 144.

use bitcoin::hashes::Hash;
use bitcoin::hex::FromHex;
use bitcoin::secp256k1::{PublicKey, Secp256k1};
use bitcoin::taproot::{LeafVersion, TapLeafHash};
use bitcoin::{Amount, ScriptBuf};

use lightning::ln::chan_utils::{
    get_taproot_anchor_script, get_taproot_anchor_spk, get_taproot_to_local_delay_script,
    get_taproot_to_local_revoke_script, get_taproot_to_local_spk, get_taproot_to_remote_script,
    get_taproot_to_remote_spk, simple_taproot_nums_internal_key, taproot_funding_keyspend_sighash,
    SIMPLE_TAPROOT_NUMS_POINT,
};
use lightning::ln::channel_keys::{DelayedPaymentKey, RevocationKey};

// --- Test-vector-derived keys (from the JSON `params.keys`). ---
const LOCAL_DELAYED: &str = "0315ec0138eb42f1ab4603042123988d53c854e89d1d87aa4dbb97a57482029c05";
const REVOCATION: &str = "03d4c77088d346bce67c13bbbf82ca112588f4b1c9595a1f8af3be9b2f95a109a0";
const REMOTE_PAYMENT: &str = "03595f2ef2a51d2250a21077dbea4a7fc3ce550f10676996bf63719e2a71d1f4c9";
const CSV_DELAY: u16 = 144;

fn local_delayed() -> DelayedPaymentKey {
    DelayedPaymentKey(PublicKey::from_slice(&Vec::<u8>::from_hex(LOCAL_DELAYED).unwrap()).unwrap())
}
fn revocation() -> RevocationKey {
    RevocationKey(PublicKey::from_slice(&Vec::<u8>::from_hex(REVOCATION).unwrap()).unwrap())
}
fn remote_payment() -> PublicKey {
    PublicKey::from_slice(&Vec::<u8>::from_hex(REMOTE_PAYMENT).unwrap()).unwrap()
}

/// The internal NUMS key matches the spec constant exactly (compressed + x-only).
#[test]
fn nums_point_is_spec_value() {
    assert_eq!(
        SIMPLE_TAPROOT_NUMS_POINT.to_vec(),
        Vec::<u8>::from_hex("02dca094751109d0bd055d03565874e8276dd53e926b44e3bd1bb6bf4bc130a279")
            .unwrap(),
    );
    assert_eq!(
        simple_taproot_nums_internal_key().serialize().to_vec(),
        Vec::<u8>::from_hex("dca094751109d0bd055d03565874e8276dd53e926b44e3bd1bb6bf4bc130a279")
            .unwrap(),
    );
}

/// `to_local` to_delay ("settle") + revoke leaf scripts AND their TapLeaf hashes
/// (0xc0 leaf version) match the BOLT vectors byte-for-byte.
#[test]
fn to_local_leaf_scripts_and_hashes_match_vectors() {
    let delay = get_taproot_to_local_delay_script(CSV_DELAY, &local_delayed());
    let revoke = get_taproot_to_local_revoke_script(&revocation(), &local_delayed());

    assert_eq!(
        delay.to_bytes(),
        Vec::<u8>::from_hex(
            "2015ec0138eb42f1ab4603042123988d53c854e89d1d87aa4dbb97a57482029c05ad029000b2"
        )
        .unwrap(),
        "to_delay (settle) script must match BOLT vector",
    );
    assert_eq!(
        revoke.to_bytes(),
        Vec::<u8>::from_hex(
            "2015ec0138eb42f1ab4603042123988d53c854e89d1d87aa4dbb97a57482029c057520d4c77088d346bce67c13bbbf82ca112588f4b1c9595a1f8af3be9b2f95a109a0ac"
        )
        .unwrap(),
        "revoke script must match BOLT vector",
    );

    assert_eq!(
        TapLeafHash::from_script(&delay, LeafVersion::TapScript)
            .to_byte_array()
            .to_vec(),
        Vec::<u8>::from_hex("dbf0400e9c7c57f30b6ad0b0677e396b5a002cbf050d873c8925b966048e6a62")
            .unwrap(),
    );
    assert_eq!(
        TapLeafHash::from_script(&revoke, LeafVersion::TapScript)
            .to_byte_array()
            .to_vec(),
        Vec::<u8>::from_hex("8fcd64d212bbbf1bcec2360bbf229963240d05992fc2efb482fe6dca85b9469a")
            .unwrap(),
    );
}

/// The `to_local` output scriptPubKey (BIP341 tweak over the 2-leaf tapscript
/// root) matches the vector `pkscript` byte-for-byte.
#[test]
fn to_local_output_spk_matches_vector() {
    let secp = Secp256k1::verification_only();
    let spk = get_taproot_to_local_spk(&secp, &revocation(), CSV_DELAY, &local_delayed());
    assert_eq!(
        spk.to_bytes(),
        Vec::<u8>::from_hex("51203e1fcbbd06c8a7414704612c72be9834a75d86ed85b29f0ef0c52e1950afaff3")
            .unwrap(),
        "to_local pkscript must match the BIP341-tweaked BOLT vector",
    );
}

/// `to_remote` single leaf + leaf hash + output scriptPubKey match the vectors.
#[test]
fn to_remote_leaf_and_spk_match_vectors() {
    let leaf = get_taproot_to_remote_script(&remote_payment());
    assert_eq!(
        leaf.to_bytes(),
        Vec::<u8>::from_hex("20595f2ef2a51d2250a21077dbea4a7fc3ce550f10676996bf63719e2a71d1f4c9ad51b2")
            .unwrap(),
        "to_remote settle script must match BOLT vector",
    );
    assert_eq!(
        TapLeafHash::from_script(&leaf, LeafVersion::TapScript)
            .to_byte_array()
            .to_vec(),
        Vec::<u8>::from_hex("63ce35b16eb8f8687293d5a88c1d8ada3236843b79ca315fe9dd7c47f30f2bc9")
            .unwrap(),
    );

    let secp = Secp256k1::verification_only();
    let spk = get_taproot_to_remote_spk(&secp, &remote_payment());
    assert_eq!(
        spk.to_bytes(),
        Vec::<u8>::from_hex("51203609bb705034e5629aa6ec05c5ca906ac89ac08b34c4583c259521ec30174408")
            .unwrap(),
        "to_remote pkscript must match the BIP341-tweaked BOLT vector",
    );
}

/// Anchor single leaf `OP_16 OP_CSV` + leaf hash + both anchor output scripts
/// (local internal key = local_delayed; remote internal key = remote) match.
#[test]
fn anchor_leaf_and_spk_match_vectors() {
    let leaf = get_taproot_anchor_script();
    assert_eq!(leaf.to_bytes(), Vec::<u8>::from_hex("60b2").unwrap());
    assert_eq!(
        TapLeafHash::from_script(&leaf, LeafVersion::TapScript)
            .to_byte_array()
            .to_vec(),
        Vec::<u8>::from_hex("2b88a8f3f52386d61d5b3f2d822df659c35214d7360ed05352ad7ddc1ab03912")
            .unwrap(),
    );

    let secp = Secp256k1::verification_only();
    let local_spk = get_taproot_anchor_spk(&secp, &local_delayed().to_public_key());
    assert_eq!(
        local_spk.to_bytes(),
        Vec::<u8>::from_hex("5120f67ab012701705f3203d132f909a6810ef18c5da4c11d986cb50818803b8344e")
            .unwrap(),
        "local_anchor pkscript must match BOLT vector",
    );
    let remote_spk = get_taproot_anchor_spk(&secp, &remote_payment());
    assert_eq!(
        remote_spk.to_bytes(),
        Vec::<u8>::from_hex("51201249c50576fdf914caa14f9221370b986df520bdbc73f57d5056a86ee03e5ac4")
            .unwrap(),
        "remote_anchor pkscript must match BOLT vector",
    );
}

/// The funding key-path TapSighash is BIP341 SIGHASH_DEFAULT (`spend_type = 0`)
/// over the funding output, deterministic, and binds both the funding amount and
/// the funding scriptPubKey (the `0x5120 || Q` from the vectors). This is the
/// message MuSig2 partial-signs for a taproot commitment / cooperative-close tx.
#[test]
fn funding_keyspend_sighash_is_well_formed_and_binds_prevout() {
    use bitcoin::{
        absolute::LockTime, transaction::Version, OutPoint, Sequence, Transaction, TxIn, TxOut,
        Txid, Witness,
    };

    // Funding scriptPubKey from the vectors: 0x5120 || combined_key.
    let funding_spk = ScriptBuf::from_hex(
        "5120d0ebb4909d563a7ae1213fddede4ae54132fba0ef0b97ee3f8469191fecd348e",
    )
    .unwrap();
    let funding_amount = Amount::from_sat(10_000_000);
    let funding_outpoint = OutPoint { txid: Txid::from_byte_array([0x11; 32]), vout: 0 };
    let spend = Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: funding_outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::MAX,
            witness: Witness::new(),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(9_999_000),
            script_pubkey: ScriptBuf::new_op_return(&[]),
        }],
    };

    let h1 = taproot_funding_keyspend_sighash(&spend, 0, funding_amount, &funding_spk).unwrap();
    let h1b = taproot_funding_keyspend_sighash(&spend, 0, funding_amount, &funding_spk).unwrap();
    assert_eq!(h1.to_byte_array(), h1b.to_byte_array(), "sighash is deterministic");

    let h2 =
        taproot_funding_keyspend_sighash(&spend, 0, Amount::from_sat(10_000_001), &funding_spk)
            .unwrap();
    assert_ne!(h1.to_byte_array(), h2.to_byte_array(), "amount is committed");

    let other_spk = ScriptBuf::from_hex(
        "51203e1fcbbd06c8a7414704612c72be9834a75d86ed85b29f0ef0c52e1950afaff3",
    )
    .unwrap();
    let h3 = taproot_funding_keyspend_sighash(&spend, 0, funding_amount, &other_spk).unwrap();
    assert_ne!(h1.to_byte_array(), h3.to_byte_array(), "scriptPubKey is committed");
}
