//! Anchor-channel CPFP support — the replacement-cycling / flood-and-loot
//! defense. Impls LDK's `WalletSourceSync` over the BDK `OnchainWallet` so the
//! `BumpTransactionEventHandler` can fund commitment / HTLC-claim fee bumps with
//! the wallet's confirmed UTXOs. (quid itself defers anchors — no reference; this
//! is built from the LDK trait contract.)

use bitcoin::{psbt::Psbt, ScriptBuf, Transaction};
use lightning::events::bump_transaction::{sync::WalletSourceSync, Utxo};

use quid_ln::wallet::OnchainWallet;

/// A `WalletSourceSync` backed by the hop's BDK on-chain wallet.
pub struct HopWalletSource {
    pub wallet: OnchainWallet,
}

impl WalletSourceSync for HopWalletSource {
    fn list_confirmed_utxos(&self) -> Result<Vec<Utxo>, ()> {
        let utxos = self
            .wallet
            .get_utxos()
            .into_iter()
            .filter(|u| u.chain_position.is_confirmed())
            .filter_map(|u| {
                // The wallet is BIP-86 (key-path P2TR): scriptPubKey = OP_1 <32-byte x-only key>.
                // `is_p2tr()` is exactly `len()==34 && [0]==OP_PUSHNUM_1(0x51) && [1]==OP_PUSHBYTES_32(0x20)`.
                if u.txout.script_pubkey.is_p2tr() {
                    // Proven LDK P2TR key-spend Utxo (satisfaction_weight = LDK's own constant).
                    Some(Utxo::new_v1_p2tr_key_spend(u.outpoint, u.txout.clone()))
                } else {
                    None
                }
            })
            .collect();
        Ok(utxos)
    }

    fn get_change_script(&self) -> Result<ScriptBuf, ()> {
        Ok(self.wallet.get_internal_address().script_pubkey())
    }

    fn sign_psbt(&self, psbt: Psbt) -> Result<Transaction, ()> {
        self.wallet.sign_psbt(psbt).map_err(|_| ())
    }
}
