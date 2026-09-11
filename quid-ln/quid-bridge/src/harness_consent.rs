//! (harness) Produce the LP's consent — `OpenAuth` + a two-rung `ExitArming` ladder — for the
//! regtest e2e, signed by the LP half the fleet now holds.
//!
//! `drive_open` refuses an open without `consent_for_funding`, and a delivery needs a fresh
//! ladder for the outpoint it rotates to (`swap_out_onchain.rs`). The e2e used to stop at that
//! check with the note *"the fleet RELAYS and cannot synthesise [consent], because it holds no
//! LP funding half"*. Since §NO-SELF-PROVISIONED-LPS (`8faddbb1`) that premise is false: the
//! vault holds the LP half in-process and `deadman_exit::build_exit_arming` signs rungs with
//! both halves. This module composes exactly that into an `LpConsent`.
//!
//! ⚠️ HARNESS ONLY, BY CONSTRUCTION. The one thing here that production must NOT do is source
//! `lp_payment_point` and the `btcRecipient` PoP inside the fleet (§BTC-2.4d: *"IT ARRIVES FROM
//! THE LP, AND THIS PROCESS MUST NOT SOURCE IT ITSELF"*). The harness IS the LP, so it may. The
//! module is behind `feature = "harness"` and the daemon never links it.

use bitcoin::hashes::{sha256, Hash};
use bitcoin::secp256k1::{Keypair, Message, Secp256k1, XOnlyPublicKey};
use lightning::sign::ChannelSigner;
use lightning::sign::SignerProvider;

use alloy_primitives::{keccak256, Address, U256};
use quid_hop::node::{HopChainMonitor, HopNode};
use quid_ln::keys_manager::QuidKeysManager;

use crate::deadman_exit::{build_exit_arming, DEAD_MAN_DELTA_BLOCKS};
use crate::vault::LpConsent;

/// `BTCChannels.btcRecipientPoPDigest(who, bindHash)` =
/// `sha256(abi.encode(block.chainid, address(this), who, bindHash))`.
pub fn pop_digest_bound(chain_id: u64, btc_channels: Address, who: Address, bind_hash: [u8; 32]) -> [u8; 32] {
    let mut enc = Vec::with_capacity(128);
    enc.extend_from_slice(&U256::from(chain_id).to_be_bytes::<32>());
    enc.extend_from_slice(&[0u8; 12]);
    enc.extend_from_slice(btc_channels.as_slice());
    enc.extend_from_slice(&[0u8; 12]);
    enc.extend_from_slice(who.as_slice());
    enc.extend_from_slice(&bind_hash);
    sha256::Hash::hash(&enc).to_byte_array()
}

/// The open's digest: `bindHash = keccak256(auth.lpPaymentPoint)`.
pub fn recipient_pop_digest(
    chain_id: u64,
    btc_channels: Address,
    lp_eth: Address,
    lp_payment_point: &[u8],
) -> [u8; 32] {
    pop_digest_bound(chain_id, btc_channels, lp_eth, keccak256(lp_payment_point).0)
}

/// `setBtcRecipient` calldata for `who` (the tx sender) registering `recipient`'s x-only key —
/// the digest binds to `bytes32(0)` on this path. A swapper needs this before
/// `requestSwapOutOnchain`, whose payout script is derived from the registration.
pub fn set_btc_recipient_call(
    chain_id: u64, btc_channels: Address, who: Address, recipient: &Keypair,
) -> (Vec<u8>, [u8; 32]) {
    let xonly = XOnlyPublicKey::from_keypair(recipient).0.serialize();
    let digest = pop_digest_bound(chain_id, btc_channels, who, [0u8; 32]);
    (quid_hop::evm_codec::encode_set_btc_recipient(xonly, recipient_pop(recipient, digest)), xonly)
}

/// The LP's payout key AS THE CONTRACT WILL LOOK FOR IT. `btcRecipientOf[lpEth]` must be the
/// x-only OUTPUT key of the LP node's wallet external-index-0 P2TR — that is the script LDK's
/// cooperative close pays (`get_shutdown_scriptpubkey`, `commit_upfront_shutdown_pubkey`) and the
/// one `BTCChannels._lpFinalBalance` credits. Register any other key and a legitimate close pays
/// a script the contract does not attribute to the LP: payout 0 < checkpoint ⇒ `StaleClose`
/// (measured 2026-09-11, the first harness registered a throwaway keypair).
///
/// BIP86: `m/86'/coin'/0'/0/0` off the node's master xprv, key-path tweaked (no script tree), so
/// the PoP is signed with the TWEAKED keypair — the on-chain key is the tweaked one. The result
/// is asserted against the wallet's own destination script so a derivation drift fails here,
/// not at `recordClose`.
pub fn lp_wallet_recipient(lp: &HopNode, network: bitcoin::Network) -> Keypair {
    use bitcoin::bip32::{ChildNumber, DerivationPath};
    use bitcoin::key::TapTweak;
    let secp = Secp256k1::new();
    let coin_type = if network == bitcoin::Network::Bitcoin { 0 } else { 1 };
    let path: DerivationPath = vec![
        ChildNumber::from_hardened_idx(86).unwrap(),
        ChildNumber::from_hardened_idx(coin_type).unwrap(),
        ChildNumber::from_hardened_idx(0).unwrap(),
        ChildNumber::from_normal_idx(0).unwrap(),
        ChildNumber::from_normal_idx(0).unwrap(),
    ]
    .into();
    let xprv = lp.master_xprv.derive_priv(&secp, &path).expect("bip86 external-0");
    let internal = Keypair::from_secret_key(&secp, &xprv.private_key);
    let tweaked = internal.tap_tweak(&secp, None).to_keypair();
    let xonly = XOnlyPublicKey::from_keypair(&tweaked).0;
    let expected = bitcoin::ScriptBuf::new_p2tr_tweaked(bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(xonly));
    let wallet_spk = lp.wallet.get_destination_script();
    assert_eq!(
        expected, wallet_spk,
        "harness-derived external-0 P2TR must equal the LP wallet's destination script"
    );
    tweaked
}

/// The LP's own Lightning payment basepoint for `ldk_id`, read off the LP node's channel
/// signer — what the LP's wallet derives in production (`hop.ts::deriveLpPaymentPoint`).
pub fn lp_payment_point(lp: &HopNode, ldk_id: lightning::ln::types::ChannelId) -> Option<[u8; 33]> {
    let mon = lp.chain_monitor.get_monitor(ldk_id).ok()?;
    let ckid = mon.channel_keys_id();
    drop(mon);
    let signer = lp.keys_manager.derive_taproot_channel_signer(ckid);
    let secp = Secp256k1::new();
    Some(signer.pubkeys(&secp).payment_point.serialize())
}

/// Sign the `btcRecipient` proof-of-possession with the LP's payout key.
pub fn recipient_pop(recipient: &Keypair, digest: [u8; 32]) -> Vec<u8> {
    let secp = Secp256k1::new();
    secp.sign_schnorr_no_aux_rand(&Message::from_digest(digest), recipient).as_ref().to_vec()
}

/// A two-rung ladder for the channel's CURRENT funding outpoint (rotated or not — the monitors
/// say which), signed by both halves. Deadlines `tip+Δ` and `tip+Δ+1`, which is the minimum
/// `_armLadder` accepts (two rungs, distinct deadlines).
#[allow(clippy::too_many_arguments)]
pub fn ladder(
    hop_keys: &QuidKeysManager,
    hop_monitors: &HopChainMonitor,
    lp_keys: &QuidKeysManager,
    lp_monitors: &HopChainMonitor,
    ldk_id: lightning::ln::types::ChannelId,
    amount_sats: u64,
    recipient_xonly: [u8; 32],
    tip: u32,
    first_height_counter: u64,
) -> anyhow::Result<Vec<quid_hop::evm_codec::ExitArming>> {
    let secp = Secp256k1::new();
    let mut rungs = Vec::with_capacity(2);
    for (i, delta) in [0u32, 1].into_iter().enumerate() {
        let armed = build_exit_arming(
            None,
            hop_keys,
            hop_monitors,
            lp_keys,
            lp_monitors,
            ldk_id,
            amount_sats,
            recipient_xonly,
            tip + DEAD_MAN_DELTA_BLOCKS + delta,
            first_height_counter + i as u64,
            &secp,
        )
        .ok_or_else(|| anyhow::anyhow!("build_exit_arming returned None (rung {i})"))?;
        rungs.push(armed.exit);
    }
    Ok(rungs)
}

/// The whole open consent: PoP over the derived `lpEth` bound to the LP's payment point, plus
/// the ladder for the funding outpoint.
#[allow(clippy::too_many_arguments)]
pub fn open_consent(
    hop: &HopNode,
    lp: &HopNode,
    ldk_id: lightning::ln::types::ChannelId,
    amount_sats: u64,
    recipient: &Keypair,
    chain_id: u64,
    btc_channels: Address,
    lp_eth: Address,
    tip: u32,
) -> anyhow::Result<LpConsent> {
    let point = lp_payment_point(lp, ldk_id)
        .ok_or_else(|| anyhow::anyhow!("no LP monitor for {ldk_id}"))?;
    let xonly = XOnlyPublicKey::from_keypair(recipient).0.serialize();
    let digest = recipient_pop_digest(chain_id, btc_channels, lp_eth, &point);
    let auth = quid_hop::evm_codec::OpenAuth {
        btc_recipient: xonly,
        btc_recipient_pop: recipient_pop(recipient, digest),
        lp_payment_point: point.to_vec(),
    };
    let exits = ladder(
        &hop.keys_manager,
        &hop.chain_monitor,
        &lp.keys_manager,
        &lp.chain_monitor,
        ldk_id,
        amount_sats,
        xonly,
        tip,
        1,
    )?;
    Ok(LpConsent { auth, exits })
}
