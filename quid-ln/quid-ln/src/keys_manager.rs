use anyhow::anyhow;
use bitcoin::{
    absolute,
    blockdata::transaction::{Transaction, TxOut},
    secp256k1::{
        All, PublicKey, Secp256k1, ecdh, ecdsa, scalar::Scalar, schnorr,
    },
};
use quid_common::{api::user::NodePk, root_seed::RootSeed};
use quid_crypto::rng::{Crng, RngExt};
use lightning::{
    ln::{
        inbound_payment::ExpandedKey, msgs::UnsignedGossipMessage,
        script::ShutdownScript,
    },
    offers::invoice::UnsignedBolt12Invoice,
    sign::{
        EntropySource, KeysManager, NodeSigner, OutputSpender,
        PeerStorageKey, ReceiveAuthKey, Recipient, SignerProvider,
        SpendableOutputDescriptor,
    },
};
use lightning_invoice::RawBolt11Invoice;
use secrecy::ExposeSecret;
use tracing::{debug, error};

use crate::{
    validating_signer::ValidatingChannelSigner, wallet::OnchainWallet,
};

/// Wraps LDK's [`KeysManager`] to provide the following:
///
/// 1) We have a simplified init API and a `get_node_pk` convenience method.
/// 2) Mirroring [ldk-node's implementation], we override
///    [`get_destination_script`] and [`get_shutdown_scriptpubkey`] so that LDK
///    gets addresses managed by BDK whenever it has the opportunity to close a
///    channel to a [`StaticOutput`] (usually (or only?) a cooperative close).
///    This allows us to avoid the on-chain fees incurred by a tx that sweeps
///    the output descriptors given to us in the [`SpendableOutputs`] event.
///
/// [ldk-node's implementation]: https://github.com/lightningdevkit/ldk-node/blob/3c7dac9d01ffdf66705b4a27ac699ab3d83c77f6/src/wallet.rs#L461-L484
/// [`get_destination_script`]: SignerProvider::get_destination_script.
/// [`get_shutdown_scriptpubkey`]: SignerProvider::get_shutdown_scriptpubkey.
/// [`StaticOutput`]: lightning::sign::SpendableOutputDescriptor::StaticOutput
/// [`SpendableOutputs`]: lightning::events::Event::SpendableOutputs
pub struct QuidKeysManager {
    inner: KeysManager,
    wallet: OnchainWallet,
}

impl QuidKeysManager {
    /// Initialize a [`QuidKeysManager`] from a [`RootSeed`] and
    /// [`OnchainWallet`].
    pub fn new(
        rng: &mut impl Crng,
        root_seed: &RootSeed,
        wallet: OnchainWallet,
    ) -> anyhow::Result<Self> {
        // Build the KeysManager from the LDK seed derived from the root seed
        let ldk_seed = root_seed.derive_ldk_seed();

        // KeysManager requires a "starting_time_secs" and "starting_time_nanos"
        // to seed an CRNG. We just provide random values from our system CRNG.
        let random_secs = rng.gen_u64();
        let random_nanos = rng.gen_u32();
        // new channels will force close to one of 2000 static spks.
        // NOTE(phlip9): not safe to downgrade node from LDK v0.2.2 -> v0.1.7
        let v2_remote_key_derivation = true;
        let inner = KeysManager::new(
            ldk_seed.expose_secret(),
            random_secs,
            random_nanos,
            v2_remote_key_derivation,
        );

        Ok(Self { inner, wallet })
    }

    /// Get the "Node ID" [`NodePk`] for this [`QuidKeysManager`].
    pub fn node_pk(&self) -> NodePk {
        self.inner
            .get_node_id(Recipient::Node)
            .map(NodePk)
            .expect("Always succeeds when called with Recipient::Node")
    }

    /// Signs a message using the "node ID" secret key.
    /// Returns the signature corresponding to the message.
    pub fn sign_message(&self, msg: &str) -> String {
        // signature := zbase32(
        //   sign-recoverable(
        //     sha256d(“Lightning Signed Message:” || msg)
        //   )
        // )
        lightning::util::message_signing::sign(
            msg.as_bytes(),
            &self.inner.get_node_secret_key(),
        )
    }

    /// Verifies that a message was signed by the given public key.
    #[must_use]
    pub fn verify_message(
        &self,
        msg: &str,
        signature: &str,
        node_pk: &NodePk,
    ) -> bool {
        lightning::util::message_signing::verify(
            msg.as_bytes(),
            signature,
            &node_pk.0,
        )
    }

    /// Overrides [`KeysManager::spend_spendable_outputs`] so that we don't try
    /// to spend any [`StaticOutput`]s given to us in the `descriptors`
    /// parameter, since these are already managed by BDK.
    ///
    /// Based off of [ldk-node's implementation].
    ///
    /// [`StaticOutput`]: lightning::sign::SpendableOutputDescriptor::StaticOutput
    /// [ldk-node's implementation]: https://github.com/lightningdevkit/ldk-node/blob/3c7dac9d01ffdf66705b4a27ac699ab3d83c77f6/src/wallet.rs#L361-L378
    pub fn spend_spendable_outputs(
        &self,
        descriptors: &[&SpendableOutputDescriptor],
        outputs: Vec<TxOut>,
        change_destination_script: bitcoin::ScriptBuf,
        feerate_sat_per_1000_weight: u32,
        maybe_locktime: Option<absolute::LockTime>,
        secp_ctx: &Secp256k1<All>,
    ) -> anyhow::Result<Option<Transaction>> {
        let num_outputs = descriptors.len();
        debug!("spend_spendable_outputs spending {num_outputs} outputs");
        let only_non_static = descriptors
            .iter()
            .filter(|d| {
                if matches!(d, SpendableOutputDescriptor::StaticOutput { .. }) {
                    debug!("Skipping StaticOutput");
                    false
                } else {
                    true
                }
            })
            .copied()
            .collect::<Vec<_>>();

        if only_non_static.is_empty() {
            debug!("spend_spendable_outputs: No non-static outputs to spend");
            return Ok(None);
        }

        self.inner
            .spend_spendable_outputs(
                &only_non_static,
                outputs,
                change_destination_script,
                feerate_sat_per_1000_weight,
                maybe_locktime,
                secp_ctx,
            )
            .map(Some)
            .map_err(|()| anyhow!("spend_spendable_outputs failed"))
    }
}

// --- LDK impls --- //

impl EntropySource for QuidKeysManager {
    fn get_secure_random_bytes(&self) -> [u8; 32] {
        self.inner.get_secure_random_bytes()
    }
}

impl NodeSigner for QuidKeysManager {
    fn get_node_id(&self, recipient: Recipient) -> Result<PublicKey, ()> {
        self.inner.get_node_id(recipient)
    }

    fn ecdh(
        &self,
        recipient: Recipient,
        other_key: &PublicKey,
        tweak: Option<&Scalar>,
    ) -> Result<ecdh::SharedSecret, ()> {
        self.inner.ecdh(recipient, other_key, tweak)
    }

    fn sign_invoice(
        &self,
        invoice: &RawBolt11Invoice,
        recipient: Recipient,
    ) -> Result<ecdsa::RecoverableSignature, ()> {
        self.inner.sign_invoice(invoice, recipient)
    }

    fn sign_bolt12_invoice(
        &self,
        invoice: &UnsignedBolt12Invoice,
    ) -> Result<schnorr::Signature, ()> {
        self.inner.sign_bolt12_invoice(invoice)
    }

    fn sign_gossip_message(
        &self,
        msg: UnsignedGossipMessage<'_>,
    ) -> Result<ecdsa::Signature, ()> {
        self.inner.sign_gossip_message(msg)
    }

    /// NOTE(phlip9): these keys would allow us to create invoices outside the
    /// node (without any communication, even offline!). we would probably
    /// export the original input key material `[u8; 32]` and rederive the
    /// child keys.
    fn get_expanded_key(&self) -> ExpandedKey {
        self.inner.get_expanded_key()
    }

    fn get_peer_storage_key(&self) -> PeerStorageKey {
        self.inner.get_peer_storage_key()
    }

    /// NOTE(phlip9): this key would also be required to build BOLT12 offers
    /// outside the node, though we would need to know the current
    /// `lsp_info.node_pk`.
    fn get_receive_auth_key(&self) -> ReceiveAuthKey {
        self.inner.get_receive_auth_key()
    }

    fn sign_message(&self, msg: &[u8]) -> Result<String, ()> {
        self.inner.sign_message(msg)
    }
}

impl SignerProvider for QuidKeysManager {
    type EcdsaSigner = ValidatingChannelSigner;
    // Taproot is folded into the default build (no `cfg(taproot)` gate), so
    // `SignerProvider::TaprootSigner` is now an unconditional associated type.
    // QU!D's simple-taproot channels use the SAME validating signer: it
    // implements both `EcdsaChannelSigner` and `TaprootChannelSigner` over one
    // `PolicyState` (anti-revoked-reuse + closing-payout lock are scheme-agnostic).
    type TaprootSigner = ValidatingChannelSigner;

    // Required methods
    fn generate_channel_keys_id(
        &self,
        inbound: bool,
        user_channel_id: u128,
    ) -> [u8; 32] {
        self.inner
            .generate_channel_keys_id(inbound, user_channel_id)
    }

    /// Derive the node's production channel signer.
    ///
    /// We build the in-process `InMemorySigner` exactly as the inner LDK
    /// `KeysManager` does, then wrap it in the self-host
    /// [`ValidatingChannelSigner`] with the LP's committed close script as the
    /// closing-payout-script lock. The expected script is the wallet's STABLE
    /// external-index-0 P2TR (BIP86 key-path) — the *same* script `get_shutdown_scriptpubkey`
    /// commits via `commit_upfront_shutdown_pubkey` and that
    /// `BTCChannels._lpFinalBalance` reads on the EVM side (see
    /// `get_shutdown_scriptpubkey` below). It is derived here, never persisted.
    ///
    /// This is also the read-back path: the vendored LDK fork reconstructs a
    /// monitor's signer by calling `derive_channel_signer(channel_keys_id)` (it
    /// does not deserialize signer bytes — see `onchaintx.rs`), so a node that
    /// reboots and reloads its `ChannelMonitor`s gets the identical wrapper with
    /// a fresh (correctly-reconstructed) monotonic policy tracker.
    fn derive_channel_signer(
        &self,
        channel_keys_id: [u8; 32],
    ) -> Self::EcdsaSigner {
        let inner = self.inner.derive_channel_signer(channel_keys_id);
        let expected_holder_close_script =
            self.wallet.get_destination_script();
        ValidatingChannelSigner::new(inner, expected_holder_close_script)
    }

    /// Simple-taproot channels (M6) hold a `ChannelSignerType::Taproot(_)`. QU!D's
    /// `TaprootSigner` is the SAME `ValidatingChannelSigner` as the ECDSA path: the
    /// anti-revoked-reuse monotonic gate + closing-payout-script lock are
    /// scheme-agnostic, and the MuSig2 key-path bodies live on it (M5). The inner
    /// `InMemorySigner` is re-derived from the identical `channel_keys_id`.
    fn derive_taproot_channel_signer(
        &self,
        channel_keys_id: [u8; 32],
    ) -> Self::TaprootSigner {
        let inner = self.inner.derive_taproot_channel_signer(channel_keys_id);
        let expected_holder_close_script =
            self.wallet.get_destination_script();
        ValidatingChannelSigner::new(inner, expected_holder_close_script)
    }

    /// Returns the scriptpubkey that we should receive time-locked, contestible
    /// channel force-close outputs to.
    ///
    /// See: `OnchainWallet::get_destination_script`.
    fn get_destination_script(
        &self,
        _channel_keys_id: [u8; 32],
    ) -> Result<bitcoin::ScriptBuf, ()> {
        Ok(self.wallet.get_destination_script())
    }

    /// Returns the (BOLT2-compatible) scriptpubkey that we should receive
    /// channel coop-close outputs to.
    ///
    /// QU!D: this MUST be the wallet's STABLE external-index-0 P2TR (BIP86 key-path)
    /// (`get_destination_script` / `external_spk_0`), NOT a rotating internal
    /// (change) address. `BTCChannels._lpFinalBalance` attributes the LP's
    /// cooperative-close balance ONLY to outputs paying `0x5120||btcRecipientOf`
    /// — so the coop-close payout must land on a single, deterministic script the
    /// LP has registered on-chain via `setBtcRecipient`. With a rotating change
    /// address the payout would never match `btcRecipientOf`, `_lpFinalBalance`
    /// would read 0, and `delivered = funded` would over-attribute the pool's
    /// shared swap-out proceeds. We also set `commit_upfront_shutdown_pubkey=true`
    /// (see `quid-hop::node`) so this script is committed at open and LDK rejects
    /// any deviating `Shutdown` at close, and the open driver verifies it equals
    /// `P2WPKH(btcRecipientOf)` before driving the hop-gated `openChannel`.
    fn get_shutdown_scriptpubkey(&self) -> Result<ShutdownScript, ()> {
        let spk = self.wallet.get_destination_script();
        ShutdownScript::try_from(spk)
            .inspect_err(|e| error!("external-0 spk is not a valid shutdown script: {e:?}"))
            .map_err(|_| ())
    }
}

#[cfg(test)]
mod test {
    use quid_crypto::rng::FastRng;
    use proptest::{arbitrary::any, prop_assert_eq, proptest};

    use super::*;

    /// Tests that [`RootSeed::derive_node_pk`] generates the same [`NodePk`]
    /// that [`KeysManager::get_node_id`] does.
    #[test]
    fn test_rootseed_keysmanager_derivation_equivalence() {
        proptest!(|(
            root_seed in any::<RootSeed>(),
            mut rng in any::<FastRng>()
        )| {
            let root_seed_node_pk = root_seed.derive_node_pk();

            let v2_remote_key_derivation = true;
            let keys_manager = KeysManager::new(
                root_seed.derive_ldk_seed().expose_secret(),
                rng.gen_u64(),
                rng.gen_u32(),
                v2_remote_key_derivation,
            );
            let keys_manager_node_pk = keys_manager
                .get_node_id(Recipient::Node)
                .map(NodePk)
                .expect("Always succeeds when called with Recipient::Node");
            prop_assert_eq!(root_seed_node_pk, keys_manager_node_pk);
        });
    }

    /// Tests the `sign_message` and `verify_message` APIs.
    #[test]
    #[cfg(not(target_env = "sgx"))]
    fn test_sign_verify_message() {
        proptest!(|(
            root_seed1 in any::<RootSeed>(),
            root_seed2 in any::<RootSeed>(),
            mut rng in any::<FastRng>(),
            msg in ".*",
        )| {
            let network = quid_common::ln::network::Network::Regtest;

            // Create users 1 and 2
            let master_xprv1 = root_seed1.derive_bip32_master_xprv(network);
            let changeset = None;
            let wallet1 = OnchainWallet::dummy(master_xprv1, changeset);
            let keys_manager1 =
                QuidKeysManager::new(&mut rng, &root_seed1, wallet1).unwrap();
            let node_pk1 = keys_manager1.node_pk();

            let master_xprv2 = root_seed2.derive_bip32_master_xprv(network);
            let changeset = None;
            let wallet2 = OnchainWallet::dummy(master_xprv2, changeset);
            let keys_manager2 =
                QuidKeysManager::new(&mut rng, &root_seed2, wallet2).unwrap();

            // User 1 signs
            let sig = keys_manager1.sign_message(&msg);

            // User 2 verifies
            assert!(keys_manager2.verify_message(&msg, &sig, &node_pk1));
        });
    }
}
