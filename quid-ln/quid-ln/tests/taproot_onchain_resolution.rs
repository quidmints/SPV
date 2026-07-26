//! Simple-taproot **ON-CHAIN RESOLUTION** tests
//! (`docs/TAPROOT-CHANNELS-BUILD-SPEC.md`).
//!
//! These exercise the on-chain claim/justice/sweep witnesses that
//! `chain/package.rs` + the `*_taproot` signer methods build for a simple-taproot
//! commitment's OUTPUTS (the gap M9e closes — before M9e every on-chain spend was
//! a silent P2WSH/ECDSA assumption, invalid for the taproot tapscript outputs).
//!
//! Each test signs the real spend through the production signer
//! (`InMemorySigner` via `KeysManager::derive_channel_keys`), assembles the exact
//! witness the package builder emits, then **cryptographically verifies** the
//! BIP340 Schnorr signature against the spent leaf's key (script-path) or the
//! tweaked output key (key-path) over the matching BIP341 sighash. A signature
//! that did not really satisfy the leaf would fail `verify_schnorr` — so this
//! drives the on-chain branch, not a happy path. (bitcoind acceptance is the
//! live-harness layer; these are the in-process crypto-validity layer, matching
//! the existing M9a/M9b taproot witness-shape tests.)

use bitcoin::absolute::LockTime;
use bitcoin::hashes::Hash;
use bitcoin::secp256k1::{schnorr, Message, PublicKey, Secp256k1, SecretKey};
use bitcoin::sighash::TapSighashType;
use bitcoin::{Amount, OutPoint, Sequence, Transaction, TxIn, TxOut, Witness};

use lightning::chain;
use lightning::ln::chan_utils::{
    self, get_taproot_htlc_spk, get_taproot_offered_htlc_success_script,
    get_taproot_received_htlc_timeout_script, get_taproot_to_local_delay_script,
    get_taproot_to_local_revoke_script, get_taproot_to_local_spk, get_taproot_to_remote_script,
    get_taproot_to_remote_spk, taproot_htlc_spend_info, taproot_to_local_spend_info,
    ChannelTransactionParameters, CounterpartyChannelTransactionParameters, HTLCOutputInCommitment,
    TxCreationKeys,
};
use lightning::sign::ecdsa::EcdsaChannelSigner;
use lightning::sign::{ChannelSigner, KeysManager, SignerProvider};
use lightning::types::features::ChannelTypeFeatures;
use lightning::types::payment::{PaymentHash, PaymentPreimage};

fn taproot_features() -> ChannelTypeFeatures {
    let mut f = ChannelTypeFeatures::anchors_zero_htlc_fee_and_dependencies();
    f.set_simple_taproot_required();
    f
}

/// A holder (us) + counterparty channel-param fixture, with the holder's
/// production signer. `to_self_delay` is the holder-selected contest delay (used
/// on the counterparty's broadcast = the delay WE'd wait if we were broadcasting,
/// and the CSV on the counterparty's to_local that we sweep on a breach).
struct Fixture {
    holder_signer: lightning::sign::InMemorySigner,
    params: ChannelTransactionParameters,
    secp: Secp256k1<bitcoin::secp256k1::All>,
}

fn fixture(to_self_delay: u16) -> Fixture {
    let secp = Secp256k1::new();
    let holder_km = KeysManager::new(&[7u8; 32], 0, 0, false);
    let cp_km = KeysManager::new(&[9u8; 32], 0, 0, false);
    let holder_signer = holder_km.derive_channel_keys(&holder_km.generate_channel_keys_id(false, 0));
    let cp_signer = cp_km.derive_channel_keys(&cp_km.generate_channel_keys_id(true, 1));

    let holder_pubkeys = holder_signer.pubkeys(&secp).clone();
    let counterparty_pubkeys = cp_signer.pubkeys(&secp).clone();
    let params = ChannelTransactionParameters {
        holder_pubkeys,
        holder_selected_contest_delay: to_self_delay,
        is_outbound_from_holder: true,
        counterparty_parameters: Some(CounterpartyChannelTransactionParameters {
            pubkeys: counterparty_pubkeys,
            selected_contest_delay: to_self_delay,
        }),
        funding_outpoint: Some(chain::transaction::OutPoint {
            txid: bitcoin::Txid::all_zeros(),
            index: 0,
        }),
        splice_parent_funding_txid: None,
        channel_type_features: taproot_features(),
        channel_value_satoshis: 1_000_000,
    };
    Fixture { holder_signer, params, secp }
}

fn spending_tx(prevout: OutPoint, sequence: Sequence, value: u64) -> Transaction {
    Transaction {
        version: bitcoin::transaction::Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: prevout,
            script_sig: bitcoin::ScriptBuf::new(),
            sequence,
            witness: Witness::new(),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(value - 500),
            script_pubkey: bitcoin::ScriptBuf::new_op_return([]),
        }],
    }
}

fn cp_keys(f: &Fixture, per_commitment_point: &PublicKey) -> TxCreationKeys {
    // The counterparty is the broadcaster on a breach / their force-close.
    let directed = f.params.as_counterparty_broadcastable();
    TxCreationKeys::from_channel_static_keys(
        per_commitment_point,
        directed.broadcaster_pubkeys(),
        directed.countersignatory_pubkeys(),
        &f.secp,
    )
}

fn verify_schnorr(sig: &schnorr::Signature, msg: &[u8; 32], xonly: &bitcoin::XOnlyPublicKey) {
    let secp = Secp256k1::verification_only();
    let m = Message::from_digest(*msg);
    secp.verify_schnorr(sig, &m, xonly)
        .expect("M9e resolution Schnorr sig must verify against the leaf/output key");
}

// (1a) JUSTICE — sweep a revoked counterparty `to_local` via the revoke tapleaf.
#[test]
fn justice_to_local_revoke_taproot() {
    let f = fixture(144);
    // The counterparty revealed this revocation secret when they revoked the state
    // they then broadcast.
    let per_commitment_key = SecretKey::from_slice(&[0x11; 32]).unwrap();
    let per_commitment_point = PublicKey::from_secret_key(&f.secp, &per_commitment_key);
    let keys = cp_keys(&f, &per_commitment_point);

    // The revoked to_local output we are sweeping.
    let to_self_delay = f.params.holder_selected_contest_delay;
    let spk = get_taproot_to_local_spk(
        &f.secp,
        &keys.revocation_key,
        to_self_delay,
        &keys.broadcaster_delayed_payment_key,
    );
    let amount = 250_000u64;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let mut tx = spending_tx(prevout, Sequence::ENABLE_RBF_NO_LOCKTIME, amount);
    let all_prevouts = vec![TxOut { value: Amount::from_sat(amount), script_pubkey: spk }];

    let sig = f
        .holder_signer
        .sign_justice_revoked_output_taproot(
            &f.params,
            &tx,
            0,
            amount,
            &per_commitment_key,
            &all_prevouts,
            &f.secp,
        )
        .expect("justice to_local sign");

    // Assemble + assert the witness shape [sig(64B), leaf, control_block].
    let leaf =
        get_taproot_to_local_revoke_script(&keys.revocation_key, &keys.broadcaster_delayed_payment_key);
    let spend_info = taproot_to_local_spend_info(
        &f.secp,
        &keys.revocation_key,
        to_self_delay,
        &keys.broadcaster_delayed_payment_key,
    );
    let elem = chan_utils::taproot_schnorr_witness_element(&sig, TapSighashType::Default);
    let witness = chan_utils::build_taproot_script_path_witness(elem, &leaf, &spend_info).unwrap();
    tx.input[0].witness = witness.clone();
    let items = witness.to_vec();
    assert_eq!(items.len(), 3, "script-path witness = [sig, leaf, control_block]");
    assert_eq!(items[0].len(), 64, "SIGHASH_DEFAULT Schnorr sig is 64 bytes");
    assert_eq!(items[1], leaf.as_bytes(), "second element is the revoke tapleaf");

    // The revoke leaf's CHECKSIG key is the revocation key — verify the sig vs it
    // over the script-path sighash.
    let sighash = chan_utils::taproot_sweep_leaf_sighash(&tx, 0, &leaf, &all_prevouts).unwrap();
    verify_schnorr(
        &sig,
        sighash.as_ref(),
        &keys.revocation_key.to_public_key().x_only_public_key().0,
    );
}

// (1b) JUSTICE — sweep a revoked HTLC output via the HTLC tree KEY path
// (internal key = revocation key; witness = single 64-byte sig).
#[test]
fn justice_htlc_keypath_taproot() {
    let f = fixture(144);
    let per_commitment_key = SecretKey::from_slice(&[0x22; 32]).unwrap();
    let per_commitment_point = PublicKey::from_secret_key(&f.secp, &per_commitment_key);
    let keys = cp_keys(&f, &per_commitment_point);

    let htlc = HTLCOutputInCommitment {
        offered: true,
        amount_msat: 100_000_000,
        cltv_expiry: 800_000,
        payment_hash: PaymentHash([0x33; 32]),
        transaction_output_index: Some(0),
    };
    let spk = get_taproot_htlc_spk(
        &f.secp,
        &htlc,
        &keys.broadcaster_htlc_key,
        &keys.countersignatory_htlc_key,
        &keys.revocation_key,
    );
    let amount = htlc.amount_msat / 1000;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let tx = spending_tx(prevout, Sequence::ENABLE_RBF_NO_LOCKTIME, amount);
    let all_prevouts = vec![TxOut { value: Amount::from_sat(amount), script_pubkey: spk }];

    let sig = f
        .holder_signer
        .sign_justice_revoked_htlc_taproot(
            &f.params,
            &tx,
            0,
            amount,
            &per_commitment_key,
            &htlc,
            &all_prevouts,
            &f.secp,
        )
        .expect("justice htlc sign");

    // Key-path: verify vs the tweaked OUTPUT key over the key-spend sighash.
    let spend_info = taproot_htlc_spend_info(
        &f.secp,
        &htlc,
        &keys.broadcaster_htlc_key,
        &keys.countersignatory_htlc_key,
        &keys.revocation_key,
    );
    let output_key = spend_info.output_key().to_x_only_public_key();
    let sighash = chan_utils::taproot_sweep_keyspend_sighash(&tx, 0, &all_prevouts).unwrap();
    verify_schnorr(&sig, sighash.as_ref(), &output_key);
}

// (2a) HTLC ON-CHAIN — claim a counterparty-OFFERED HTLC via the success leaf
// (preimage). Witness = [sig, preimage, leaf, control_block].
#[test]
fn counterparty_offered_htlc_success_taproot() {
    let f = fixture(144);
    let per_commitment_key = SecretKey::from_slice(&[0x44; 32]).unwrap();
    let per_commitment_point = PublicKey::from_secret_key(&f.secp, &per_commitment_key);
    let keys = cp_keys(&f, &per_commitment_point);

    let preimage = PaymentPreimage([0x55; 32]);
    let payment_hash = PaymentHash(bitcoin::hashes::sha256::Hash::hash(&preimage.0).to_byte_array());
    let htlc = HTLCOutputInCommitment {
        offered: true,
        amount_msat: 50_000_000,
        cltv_expiry: 0,
        payment_hash,
        transaction_output_index: Some(0),
    };
    let spk = get_taproot_htlc_spk(
        &f.secp,
        &htlc,
        &keys.broadcaster_htlc_key,
        &keys.countersignatory_htlc_key,
        &keys.revocation_key,
    );
    let amount = htlc.amount_msat / 1000;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let tx = spending_tx(prevout, Sequence::from_consensus(1), amount);
    let all_prevouts = vec![TxOut { value: Amount::from_sat(amount), script_pubkey: spk }];

    let sig = f
        .holder_signer
        .sign_counterparty_htlc_transaction_taproot(
            &f.params,
            &tx,
            0,
            amount,
            &per_commitment_point,
            &htlc,
            &all_prevouts,
            &f.secp,
        )
        .expect("counterparty offered htlc claim sign");

    // The success leaf's CHECKSIG key is OUR (countersignatory) htlc key.
    let leaf =
        get_taproot_offered_htlc_success_script(&keys.countersignatory_htlc_key, &htlc.payment_hash);
    let sighash = chan_utils::taproot_sweep_leaf_sighash(&tx, 0, &leaf, &all_prevouts).unwrap();
    verify_schnorr(
        &sig,
        sighash.as_ref(),
        &keys.countersignatory_htlc_key.to_public_key().x_only_public_key().0,
    );
}

// (2b) HTLC ON-CHAIN — reclaim a counterparty-RECEIVED HTLC via the timeout leaf
// (CLTV). Witness = [sig, leaf, control_block].
#[test]
fn counterparty_received_htlc_timeout_taproot() {
    let f = fixture(144);
    let per_commitment_key = SecretKey::from_slice(&[0x66; 32]).unwrap();
    let per_commitment_point = PublicKey::from_secret_key(&f.secp, &per_commitment_key);
    let keys = cp_keys(&f, &per_commitment_point);

    let htlc = HTLCOutputInCommitment {
        offered: false,
        amount_msat: 75_000_000,
        cltv_expiry: 750_000,
        payment_hash: PaymentHash([0x77; 32]),
        transaction_output_index: Some(0),
    };
    let spk = get_taproot_htlc_spk(
        &f.secp,
        &htlc,
        &keys.broadcaster_htlc_key,
        &keys.countersignatory_htlc_key,
        &keys.revocation_key,
    );
    let amount = htlc.amount_msat / 1000;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let tx = spending_tx(prevout, Sequence::from_consensus(1), amount);
    let all_prevouts = vec![TxOut { value: Amount::from_sat(amount), script_pubkey: spk }];

    let sig = f
        .holder_signer
        .sign_counterparty_htlc_transaction_taproot(
            &f.params,
            &tx,
            0,
            amount,
            &per_commitment_point,
            &htlc,
            &all_prevouts,
            &f.secp,
        )
        .expect("counterparty received htlc timeout sign");

    let leaf =
        get_taproot_received_htlc_timeout_script(&keys.countersignatory_htlc_key, htlc.cltv_expiry);
    let sighash = chan_utils::taproot_sweep_leaf_sighash(&tx, 0, &leaf, &all_prevouts).unwrap();
    verify_schnorr(
        &sig,
        sighash.as_ref(),
        &keys.countersignatory_htlc_key.to_public_key().x_only_public_key().0,
    );
}

// (3) DELAYED SWEEP — the BROADCASTER claims its own `to_local` after the CSV via
// the to_delay tapleaf. Drives the real `KeysManager::sign_dynamic_p2wsh_input`
// taproot branch (the production delayed-sweep path) through
// `sign_spendable_outputs_psbt`, then verifies the resulting [sig, leaf,
// control_block] witness against the to_delay leaf key.
#[test]
fn delayed_to_local_sweep_taproot() {
    use bitcoin::psbt::Psbt;
    use lightning::sign::{DelayedPaymentOutputDescriptor, SpendableOutputDescriptor};

    let secp = Secp256k1::new();
    let km = KeysManager::new(&[0x21; 32], 0, 0, false);
    let keys_id = km.generate_channel_keys_id(false, 0);
    let signer = km.derive_channel_keys(&keys_id);

    let f = fixture(144);
    let to_self_delay = f.params.holder_selected_contest_delay;
    // Build params whose holder pubkeys are THIS signer's (so its delayed base
    // key produces the to_delay leaf key we spend).
    let mut params = f.params.clone();
    params.holder_pubkeys = signer.pubkeys(&secp).clone();

    let per_commitment_key = SecretKey::from_slice(&[0x88; 32]).unwrap();
    let per_commitment_point = PublicKey::from_secret_key(&secp, &per_commitment_key);
    let directed = params.as_holder_broadcastable();
    let keys = TxCreationKeys::from_channel_static_keys(
        &per_commitment_point,
        directed.broadcaster_pubkeys(),
        directed.countersignatory_pubkeys(),
        &secp,
    );
    let spk = get_taproot_to_local_spk(
        &secp,
        &keys.revocation_key,
        to_self_delay,
        &keys.broadcaster_delayed_payment_key,
    );
    let amount = 400_000u64;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let output = TxOut { value: Amount::from_sat(amount), script_pubkey: spk };

    let descriptor = DelayedPaymentOutputDescriptor {
        outpoint: lightning::chain::transaction::OutPoint {
            txid: prevout.txid,
            index: prevout.vout as u16,
        },
        per_commitment_point,
        to_self_delay,
        output: output.clone(),
        revocation_pubkey: keys.revocation_key,
        channel_keys_id: keys_id,
        channel_value_satoshis: params.channel_value_satoshis,
        channel_transaction_parameters: Some(params.clone()),
    };
    let desc = SpendableOutputDescriptor::DelayedPaymentOutput(descriptor);

    let tx = Transaction {
        version: bitcoin::transaction::Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: prevout,
            script_sig: bitcoin::ScriptBuf::new(),
            sequence: Sequence(to_self_delay as u32),
            witness: Witness::new(),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(amount - 1000),
            script_pubkey: bitcoin::ScriptBuf::new_op_return([]),
        }],
    };
    let mut psbt = Psbt::from_unsigned_tx(tx).unwrap();
    psbt.inputs[0] = desc.to_psbt_input(&secp);

    let signed = km
        .sign_spendable_outputs_psbt(&[&desc], psbt, &secp)
        .expect("delayed sweep must sign");
    let witness = signed.inputs[0]
        .final_script_witness
        .clone()
        .expect("delayed sweep witness");
    let items = witness.to_vec();
    assert_eq!(items.len(), 3, "to_delay sweep witness = [sig, leaf, control_block]");
    assert_eq!(items[0].len(), 64, "SIGHASH_DEFAULT Schnorr sig is 64 bytes");

    // Verify the produced sig vs the to_delay leaf key over the script-path sighash.
    let leaf = get_taproot_to_local_delay_script(to_self_delay, &keys.broadcaster_delayed_payment_key);
    assert_eq!(items[1], leaf.as_bytes(), "second element is the to_delay tapleaf");
    let sig = schnorr::Signature::from_slice(&items[0]).unwrap();
    let all_prevouts = vec![output];
    let sighash = chan_utils::taproot_sweep_leaf_sighash(&signed.unsigned_tx, 0, &leaf, &all_prevouts)
        .unwrap();
    verify_schnorr(
        &sig,
        sighash.as_ref(),
        &keys.broadcaster_delayed_payment_key.to_public_key().x_only_public_key().0,
    );
}

// (4) to_remote SWEEP. When the COUNTERPARTY (e.g. the hop) broadcasts ITS
// commitment, OUR balance is the taproot `to_remote` output (1-CSV tapleaf)
// on that tx. Before this fix the monitor matched it as P2WSH and the sweep witness was
// P2WSH/P2WPKH ⇒ INVALID ⇒ we could not claim our own balance (the LP-side recovery
// hole, mirror of M9a). This drives the real
// `KeysManager::sign_counterparty_payment_input` taproot branch through
// `sign_spendable_outputs_psbt`, then verifies the resulting
// [sig, leaf, control_block] witness against the to_remote leaf key over the BIP341
// script-path sighash. A P2WSH-only signer would have errored or produced an invalid
// witness here.
#[test]
fn to_remote_sweep_taproot() {
    use bitcoin::psbt::Psbt;
    use lightning::sign::{SpendableOutputDescriptor, StaticPaymentOutputDescriptor};

    let secp = Secp256k1::new();
    let km = KeysManager::new(&[0x55; 32], 0, 0, false);
    let keys_id = km.generate_channel_keys_id(false, 0);
    let signer = km.derive_channel_keys(&keys_id);

    let f = fixture(144);
    // Params whose HOLDER pubkeys are THIS signer's: the monitor builds the watched
    // `to_remote` SPK from `holder_pubkeys.payment_point` (= our payment key), so the
    // descriptor's output script is the one our `payment_key_v1` can sweep.
    let mut params = f.params.clone();
    params.holder_pubkeys = signer.pubkeys(&secp).clone();

    // The taproot `to_remote` output on the counterparty's broadcast = OUR balance.
    let remote_pubkey = params.holder_pubkeys.payment_point;
    let spk = get_taproot_to_remote_spk(&secp, &remote_pubkey);

    let amount = 300_000u64;
    let prevout = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
    let output = TxOut { value: Amount::from_sat(amount), script_pubkey: spk };

    let descriptor = StaticPaymentOutputDescriptor {
        outpoint: lightning::chain::transaction::OutPoint {
            txid: prevout.txid,
            index: prevout.vout as u16,
        },
        output: output.clone(),
        channel_keys_id: keys_id,
        channel_value_satoshis: params.channel_value_satoshis,
        channel_transaction_parameters: Some(params.clone()),
    };
    let desc = SpendableOutputDescriptor::StaticPaymentOutput(descriptor);

    // The to_remote tapleaf carries `1 OP_CSV` ⇒ the spend must set sequence >= 1.
    let tx = Transaction {
        version: bitcoin::transaction::Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: prevout,
            script_sig: bitcoin::ScriptBuf::new(),
            sequence: Sequence::from_consensus(1),
            witness: Witness::new(),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(amount - 1000),
            script_pubkey: bitcoin::ScriptBuf::new_op_return([]),
        }],
    };
    let mut psbt = Psbt::from_unsigned_tx(tx).unwrap();
    psbt.inputs[0] = desc.to_psbt_input(&secp);

    let signed = km
        .sign_spendable_outputs_psbt(&[&desc], psbt, &secp)
        .expect("to_remote sweep must sign");
    let witness = signed.inputs[0]
        .final_script_witness
        .clone()
        .expect("to_remote sweep witness");
    let items = witness.to_vec();
    assert_eq!(items.len(), 3, "to_remote sweep witness = [sig, leaf, control_block]");
    assert_eq!(items[0].len(), 64, "SIGHASH_DEFAULT Schnorr sig is 64 bytes");

    // Second element is the to_remote tapleaf; the leaf's CHECKSIGVERIFY key is our
    // payment key — verify the Schnorr sig vs it over the BIP341 script-path sighash.
    let leaf = get_taproot_to_remote_script(&remote_pubkey);
    assert_eq!(items[1], leaf.as_bytes(), "second element is the to_remote tapleaf");
    let sig = schnorr::Signature::from_slice(&items[0]).unwrap();
    let all_prevouts = vec![output];
    let sighash =
        chan_utils::taproot_sweep_leaf_sighash(&signed.unsigned_tx, 0, &leaf, &all_prevouts).unwrap();
    verify_schnorr(&sig, sighash.as_ref(), &remote_pubkey.x_only_public_key().0);
}
