//! (E177) The ON-CHAIN comparand for a validating channel signer.
//!
//! # Why this exists
//!
//! Every input a signer receives arrives from the node it is meant to constrain — including
//! the "previous" value that self-consistency checks compare against. So self-consistency
//! binds a node that CONTRADICTS ITSELF, and nothing more: it does not bind one that lies
//! consistently from the first context onward, nor one that RESTARTS the signer to clear
//! the comparand (measured — `validating_signer::tests::nonce_binding_does_not_survive_a_restart`).
//!
//! The only checks that bind a consistently-lying node are checks against a source of truth
//! the node does not author. `BTCChannels` is that source: it pins `keysHash` and
//! `amountSats` per channel, at open, on-chain.
//!
//! # Why the reads are AGREEMENT-classed
//!
//! [`eth_call_raw_agreed`] pins to `tip − AGREED_READ_DEPTH` — a buried block — so an
//! untrusted host can only DEFLATE the tip and serve an OLDER view; it cannot forge the
//! value at the block it names. An older view is safe here because both facts are pinned at
//! OPEN and never change for a funding scope (a splice rotates the live funding keys, which
//! is exactly why the signer compares the BASE key — see `ChannelTruthSource`).
//!
//! # Fail closed
//!
//! Every error path returns `Err(())`. An unreadable chain is NOT permission to sign against
//! an unchecked context — otherwise a hostile host disables the entire check by breaking its
//! own RPC endpoint, which is the cheapest attack available to it.

use std::sync::Arc;

use alloy_primitives::Address;
use quid_ln::validating_signer::ChannelTruthSource;

use crate::client::eth_call_raw_agreed;
use crate::transport::JsonRpc;

/// `channels(bytes32)` returns the flat `Types.BTCChannel` tuple:
/// `(uint amountSats, bytes32 fundingTxId, address lpEth, uint32 fundingVout,
///   uint8 status, bytes32 keysHash)` — SIX static words.
///
/// ⚠️ `channel_driver::read_channel_state` documents "5 static words" and only requires 160
/// bytes; that predates §E153 adding `keysHash` and is why it never reads it. Six words are
/// required here, and a short return is refused rather than indexed into.
const CHANNELS_WORDS: usize = 6;
const W_AMOUNT_SATS: usize = 0;
const W_KEYS_HASH: usize = 5;

fn word(bytes: &[u8], i: usize) -> Result<&[u8], ()> {
    bytes.get(i * 32..(i + 1) * 32).ok_or(())
}

/// A [`ChannelTruthSource`] backed by `BTCChannels` on the EVM.
pub struct OnChainChannelTruth<R: JsonRpc> {
    rpc: Arc<R>,
    btc_channels: Address,
    channel_id: [u8; 32],
}

impl<R: JsonRpc> OnChainChannelTruth<R> {
    pub fn new(rpc: Arc<R>, btc_channels: Address, channel_id: [u8; 32]) -> Self {
        Self { rpc, btc_channels, channel_id }
    }

    /// The raw `channels(channelId)` return, refused unless it is the full six words.
    fn read(&self) -> Result<Vec<u8>, ()> {
        let bytes = eth_call_raw_agreed(
            &*self.rpc,
            self.btc_channels,
            "channels(bytes32)",
            Some(&self.channel_id),
        )
        .map_err(|_| ())?;
        if bytes.len() < CHANNELS_WORDS * 32 {
            return Err(());
        }
        Ok(bytes)
    }
}

impl<R: JsonRpc + Send + Sync> ChannelTruthSource for OnChainChannelTruth<R> {
    fn verify_funding_keys(&self, lp_pubkey: &[u8; 33], hop_pubkey: &[u8; 33]) -> Result<(), ()> {
        let bytes = self.read()?;
        // Constant-time-ness is not required (both sides are public), but an EXACT match is:
        // this is the whole check, and a prefix comparison would accept a truncated read.
        if word(&bytes, W_KEYS_HASH)? == quid_hop::evm_codec::keys_hash(lp_pubkey, hop_pubkey) {
            Ok(())
        } else {
            Err(())
        }
    }

    fn amount_sats(&self) -> Result<u64, ()> {
        let bytes = self.read()?;
        let w = word(&bytes, W_AMOUNT_SATS)?;
        // ⚠️ REFUSE an out-of-range value rather than truncating it. `amountSats` is compared
        // against the funding value committed in the BIP-341 sighash, so silently wrapping a
        // garbage response into a plausible u64 would make the comparison meaningless — the
        // same reasoning `read_channel_state` gives for not capping to u128::MAX.
        if w[..24].iter().any(|b| *b != 0) {
            return Err(());
        }
        let mut le = [0u8; 8];
        le.copy_from_slice(&w[24..32]);
        Ok(u64::from_be_bytes(le))
    }
}
