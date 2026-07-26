//! Simple-taproot **ANCHOR / CPFP** test
//! (`docs/TAPROOT-CHANNELS-BUILD-SPEC.md`).
//!
//! A QU!D simple-taproot channel is an anchor channel (BOLT #995): the
//! commitment carries two taproot anchor outputs so a force-close can be
//! CPFP-fee-bumped. This test exercises the on-chain CPFP key-path spend of the
//! HOLDER's anchor end to end, in-process:
//!   - reconstruct the holder anchor SPK the commitment builder emits
//!     (`get_taproot_anchor_spk(holder local_delayedpubkey)`);
//!   - derive the holder's per-commitment delayed PRIVATE key, tweak it by the
//!     anchor tree's TapTweak, and produce a BIP340 SIGHASH_DEFAULT key-spend
//!     Schnorr signature over the CPFP child's key-spend sighash;
//!   - assemble the witness via the M9g `build_taproot_anchor_input_witness` and
//!     `AnchorDescriptor::taproot_tx_input_witness` arms;
//!   - CRYPTOGRAPHICALLY verify the sig against the tweaked anchor output key.
//!
//! A signature that did not really satisfy the key-path would fail
//! `verify_schnorr` — so this drives the real anchor-spend branch, not a happy
//! path. (bitcoind acceptance is the live-harness layer; this is the in-process
//! crypto-validity layer, matching the M9a/M9b/M9e taproot witness tests.)

use bitcoin::absolute::LockTime;
use bitcoin::hashes::Hash;
use bitcoin::key::{Keypair, TapTweak};
use bitcoin::secp256k1::{Message, PublicKey, Secp256k1, SecretKey};
use bitcoin::sighash::{Prevouts, SighashCache, TapSighashType};
use bitcoin::{Amount, OutPoint, Sequence, Transaction, TxIn, TxOut, Witness};

use lightning::chain;
use lightning::ln::chan_utils::{
    self, build_taproot_anchor_input_witness, get_taproot_anchor_spk, taproot_anchor_spend_info,
    ChannelTransactionParameters, CounterpartyChannelTransactionParameters, TxCreationKeys,
};
use lightning::sign::{ChannelSigner, KeysManager, SignerProvider};
use lightning::types::features::ChannelTypeFeatures;

fn taproot_features() -> ChannelTypeFeatures {
    let mut f = ChannelTypeFeatures::anchors_zero_htlc_fee_and_dependencies();
    f.set_simple_taproot_required();
    f
}

const ANCHOR_VALUE: u64 = 330;

#[test]
fn holder_anchor_cpfp_keypath_spend_verifies() {
    let secp = Secp256k1::new();

    // Holder signer (us) — its delayed-payment base key derives the per-commitment
    // local_delayedpubkey that is the anchor's internal key.
    let holder_km = KeysManager::new(&[0x47; 32], 0, 0, false);
    let holder_signer =
        holder_km.derive_channel_keys(&holder_km.generate_channel_keys_id(false, 0));
    let cp_km = KeysManager::new(&[0x49; 32], 0, 0, false);
    let cp_signer = cp_km.derive_channel_keys(&cp_km.generate_channel_keys_id(true, 1));

    let params = ChannelTransactionParameters {
        holder_pubkeys: holder_signer.pubkeys(&secp).clone(),
        holder_selected_contest_delay: 144,
        is_outbound_from_holder: true,
        counterparty_parameters: Some(CounterpartyChannelTransactionParameters {
            pubkeys: cp_signer.pubkeys(&secp).clone(),
            selected_contest_delay: 144,
        }),
        funding_outpoint: Some(chain::transaction::OutPoint {
            txid: bitcoin::Txid::all_zeros(),
            index: 0,
        }),
        splice_parent_funding_txid: None,
        channel_type_features: taproot_features(),
        channel_value_satoshis: 1_000_000,
    };

    // The HOLDER is the broadcaster of its own force-close commitment.
    let per_commitment_point =
        PublicKey::from_secret_key(&secp, &SecretKey::from_slice(&[0x33; 32]).unwrap());
    let directed = params.as_holder_broadcastable();
    let keys = TxCreationKeys::from_channel_static_keys(
        &per_commitment_point,
        directed.broadcaster_pubkeys(),
        directed.countersignatory_pubkeys(),
        &secp,
    );

    // (1) The holder anchor SPK = get_taproot_anchor_spk(holder local_delayedpubkey)
    // — exactly what insert_non_htlc_outputs emits and onchaintx.rs locates.
    let delayed_pub = keys.broadcaster_delayed_payment_key.to_public_key();
    let anchor_spk = get_taproot_anchor_spk(&secp, &delayed_pub);
    assert_eq!(anchor_spk.as_bytes()[0], 0x51, "anchor is P2TR (OP_1)");
    assert_eq!(anchor_spk.len(), 34, "P2TR spk = OP_1 PUSH32");

    // The anchor utxo on the (notional) force-closed commitment.
    let commitment_txid = bitcoin::Txid::from_slice(&[0xAB; 32]).unwrap();
    let anchor_outpoint = OutPoint { txid: commitment_txid, vout: 0 };
    let anchor_utxo = TxOut { value: Amount::from_sat(ANCHOR_VALUE), script_pubkey: anchor_spk.clone() };

    // (2) Build the CPFP child tx spending the anchor (plus, in production, a wallet
    // UTXO for fees — omitted here; we only need the anchor input's witness/sighash).
    let cpfp = Transaction {
        version: bitcoin::transaction::Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: anchor_outpoint,
            script_sig: bitcoin::ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::new(),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(ANCHOR_VALUE),
            script_pubkey: bitcoin::ScriptBuf::new_op_return([]),
        }],
    };

    // (3) Key-path SIGHASH_DEFAULT over the anchor input (Prevouts::All).
    let prevouts = [anchor_utxo.clone()];
    let sighash = SighashCache::new(&cpfp)
        .taproot_key_spend_signature_hash(0, &Prevouts::All(&prevouts), TapSighashType::Default)
        .expect("anchor key-spend sighash");

    // (4) Sign with the holder's per-commitment delayed PRIVATE key, tweaked by the
    // anchor tree's TapTweak (key-path spend of P2TR(internal=delayed, OP_16 OP_CSV)).
    let delayed_secret = chan_utils::derive_private_key(
        &secp,
        &per_commitment_point,
        &holder_signer.delayed_payment_base_key,
    );
    // Sanity: the derived private key matches the public delayed key on the anchor.
    assert_eq!(
        PublicKey::from_secret_key(&secp, &delayed_secret),
        delayed_pub,
        "derived delayed secret must match the anchor internal key"
    );

    let spend_info = taproot_anchor_spend_info(&secp, &delayed_pub);
    let merkle_root = spend_info.merkle_root();
    let keypair = Keypair::from_secret_key(&secp, &delayed_secret);
    let tweaked = keypair.tap_tweak(&secp, merkle_root);

    let msg = Message::from_digest(*sighash.as_ref());
    let sig = secp.sign_schnorr_no_aux_rand(&msg, &tweaked.to_keypair());

    // (5) Assemble the witness via the M9g chan_utils helper.
    let witness = build_taproot_anchor_input_witness(&sig);
    let items = witness.to_vec();
    assert_eq!(items.len(), 1, "anchor key-path witness = one element");
    assert_eq!(items[0].len(), 64, "BIP340 SIGHASH_DEFAULT key-spend sig is 64 bytes");

    // (6) CRYPTOGRAPHICALLY verify the sig against the tweaked anchor output key.
    let output_key = spend_info.output_key().to_x_only_public_key();
    let verifier = Secp256k1::verification_only();
    verifier
        .verify_schnorr(&sig, &msg, &output_key)
        .expect("CPFP anchor key-path sig must verify vs the tweaked anchor output key");

    // The output key in the SPK must equal the tweaked key we verified against
    // (proves the witness spends THIS anchor output).
    assert_eq!(
        &anchor_spk.as_bytes()[2..],
        &output_key.serialize()[..],
        "anchor SPK output key matches the spend-info tweaked key"
    );
}

/// The M9g `AnchorDescriptor` arms (`previous_utxo` returns the taproot anchor
/// SPK; `taproot_tx_input_witness` builds the key-path witness) reproduce the same
/// SPK and witness shape as the manual reconstruction above — i.e. a consumer of
/// the BumpTransaction CPFP event spends the correct output.
#[test]
fn anchor_descriptor_taproot_arms_match() {
    use lightning::events::bump_transaction::AnchorDescriptor;
    use lightning::sign::ChannelDerivationParameters;

    let secp = Secp256k1::new();
    let holder_km = KeysManager::new(&[0x51; 32], 0, 0, false);
    let keys_id = holder_km.generate_channel_keys_id(false, 0);
    let holder_signer = holder_km.derive_channel_keys(&keys_id);
    let cp_km = KeysManager::new(&[0x53; 32], 0, 0, false);
    let cp_signer = cp_km.derive_channel_keys(&cp_km.generate_channel_keys_id(true, 1));

    let params = ChannelTransactionParameters {
        holder_pubkeys: holder_signer.pubkeys(&secp).clone(),
        holder_selected_contest_delay: 144,
        is_outbound_from_holder: true,
        counterparty_parameters: Some(CounterpartyChannelTransactionParameters {
            pubkeys: cp_signer.pubkeys(&secp).clone(),
            selected_contest_delay: 144,
        }),
        funding_outpoint: Some(chain::transaction::OutPoint {
            txid: bitcoin::Txid::all_zeros(),
            index: 0,
        }),
        splice_parent_funding_txid: None,
        channel_type_features: taproot_features(),
        channel_value_satoshis: 1_000_000,
    };

    let per_commitment_point =
        PublicKey::from_secret_key(&secp, &SecretKey::from_slice(&[0x71; 32]).unwrap());
    let directed = params.as_holder_broadcastable();
    let keys = TxCreationKeys::from_channel_static_keys(
        &per_commitment_point,
        directed.broadcaster_pubkeys(),
        directed.countersignatory_pubkeys(),
        &secp,
    );
    let expected_spk = get_taproot_anchor_spk(&secp, &keys.broadcaster_delayed_payment_key.to_public_key());

    let descriptor = AnchorDescriptor {
        channel_derivation_parameters: ChannelDerivationParameters {
            keys_id,
            value_satoshis: params.channel_value_satoshis,
            transaction_parameters: params.clone(),
        },
        outpoint: OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 },
        value: Amount::from_sat(ANCHOR_VALUE),
        per_commitment_point: Some(per_commitment_point),
    };

    // previous_utxo() reconstructs the SAME taproot anchor SPK.
    let utxo = descriptor.previous_utxo();
    assert_eq!(utxo.script_pubkey, expected_spk, "descriptor previous_utxo = holder taproot anchor SPK");
    assert_eq!(utxo.value, Amount::from_sat(ANCHOR_VALUE));

    // taproot_tx_input_witness builds the 1-element key-path witness.
    let dummy_sig = {
        let kp = Keypair::from_secret_key(&secp, &SecretKey::from_slice(&[0x99; 32]).unwrap());
        secp.sign_schnorr_no_aux_rand(&Message::from_digest([0x42; 32]), &kp)
    };
    let witness = descriptor.taproot_tx_input_witness(&dummy_sig);
    let items = witness.to_vec();
    assert_eq!(items.len(), 1, "taproot anchor witness = one element");
    assert_eq!(items[0].len(), 64, "key-spend sig is 64 bytes");
}
