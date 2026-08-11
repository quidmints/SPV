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
use quid_ln::validating_signer::{ChannelTruthSource, TruthSourceFactory, TruthVerdict};

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

/// (E177) `channel_keys_id → on-chain channelId`.
///
/// The signer is derived from a `channel_keys_id`; the EVM knows the channel by
/// `channelId = keccak(lpPubkey, hopPubkey, fundingTxid, vout)`, which needs a funding
/// outpoint that does not exist at derive time. The daemon learns the pairing later (it
/// already derives a cid from a monitor via `onchain_cid_from_monitor`) and records it
/// here; the comparand resolves through it on every check.
///
/// ⚠️ **AN UNRESOLVED ENTRY IS `NotRecorded`, NOT AN ERROR.** That is exactly right and it
/// is why the three-state check exists: a channel whose cid is not yet known is a channel
/// the EVM has not recorded, the window is permissive so opening can proceed, and the
/// signer's `truth_recorded` latch makes it ONE-WAY the moment the chain first answers —
/// so this map cannot be used to downgrade a channel that has already been seen.
#[derive(Default)]
pub struct CidRegistry {
    map: std::sync::RwLock<std::collections::HashMap<[u8; 32], [u8; 32]>>,
}

impl CidRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record the pairing. Idempotent; a conflicting re-bind is REFUSED and returns `false`
    /// rather than overwriting — the cid identifies which on-chain channel a signer is
    /// checked against, so letting it move would let the node pick the comparand.
    pub fn bind(&self, channel_keys_id: [u8; 32], channel_id: [u8; 32]) -> bool {
        let mut m = match self.map.write() {
            Ok(m) => m,
            Err(_) => return false,
        };
        match m.get(&channel_keys_id) {
            Some(existing) => *existing == channel_id,
            None => {
                m.insert(channel_keys_id, channel_id);
                true
            }
        }
    }

    pub fn get(&self, channel_keys_id: &[u8; 32]) -> Option<[u8; 32]> {
        self.map.read().ok().and_then(|m| m.get(channel_keys_id).copied())
    }
}

/// A [`ChannelTruthSource`] backed by `BTCChannels` on the EVM.
pub struct OnChainChannelTruth<R: JsonRpc> {
    rpc: Arc<R>,
    btc_channels: Address,
    cids: Arc<CidRegistry>,
    channel_keys_id: [u8; 32],
}

impl<R: JsonRpc> OnChainChannelTruth<R> {
    pub fn new(
        rpc: Arc<R>,
        btc_channels: Address,
        cids: Arc<CidRegistry>,
        channel_keys_id: [u8; 32],
    ) -> Self {
        Self { rpc, btc_channels, cids, channel_keys_id }
    }

    /// The raw `channels(channelId)` return. `Ok(None)` = the cid is not known yet, which
    /// the caller reports as `NotRecorded`. Refused unless the return is the full six words.
    fn read(&self) -> Result<Option<Vec<u8>>, ()> {
        let Some(cid) = self.cids.get(&self.channel_keys_id) else {
            return Ok(None);
        };
        let bytes = eth_call_raw_agreed(
            &*self.rpc,
            self.btc_channels,
            "channels(bytes32)",
            Some(&cid),
        )
        .map_err(|_| ())?;
        if bytes.len() < CHANNELS_WORDS * 32 {
            return Err(());
        }
        Ok(Some(bytes))
    }
}

/// (E177) Builds a comparand per derived signer. Held by `QuidKeysManager`.
pub struct OnChainTruthFactory<R: JsonRpc> {
    rpc: Arc<R>,
    btc_channels: Address,
    cids: Arc<CidRegistry>,
}

impl<R: JsonRpc> OnChainTruthFactory<R> {
    pub fn new(rpc: Arc<R>, btc_channels: Address, cids: Arc<CidRegistry>) -> Self {
        Self { rpc, btc_channels, cids }
    }
}

impl<R: JsonRpc + Send + Sync + 'static> TruthSourceFactory for OnChainTruthFactory<R> {
    fn for_channel(&self, channel_keys_id: [u8; 32]) -> Arc<dyn ChannelTruthSource> {
        Arc::new(OnChainChannelTruth::new(
            self.rpc.clone(),
            self.btc_channels,
            self.cids.clone(),
            channel_keys_id,
        ))
    }
}

impl<R: JsonRpc + Send + Sync> ChannelTruthSource for OnChainChannelTruth<R> {
    fn verify(
        &self,
        lp_pubkey: &[u8; 33],
        hop_pubkey: &[u8; 33],
        funding_value_sat: u64,
    ) -> Result<TruthVerdict, ()> {
        // Cid not yet known ⇒ the EVM cannot have recorded this channel.
        let Some(bytes) = self.read()? else { return Ok(TruthVerdict::NotRecorded) };
        let keys_hash = word(&bytes, W_KEYS_HASH)?;

        // ⚠️ `keysHash == 0` IS THE "no record" TEST, NOT `amountSats == 0`.
        // `keysHash` is pinned at open and never cleared, whereas `amountSats` legitimately
        // reaches 0 on a CLOSED channel — so testing the amount would report a closed
        // channel as never-recorded, which is precisely the state a downgrade wants to
        // reach. An unwritten mapping entry reads as all-zero words.
        if keys_hash.iter().all(|b| *b == 0) {
            return Ok(TruthVerdict::NotRecorded);
        }

        if keys_hash != quid_hop::evm_codec::keys_hash(lp_pubkey, hop_pubkey) {
            return Ok(TruthVerdict::Mismatch);
        }

        // The funded size is committed in the BIP-341 key-path sighash, so it is part of
        // the identity being checked, not a separate nicety.
        let w = word(&bytes, W_AMOUNT_SATS)?;
        // ⚠️ REFUSE an out-of-range value rather than truncating it: silently wrapping a
        // garbage response into a plausible u64 would make the comparison meaningless —
        // the same reasoning `read_channel_state` gives for not capping to u128::MAX.
        if w[..24].iter().any(|b| *b != 0) {
            return Err(());
        }
        let mut be = [0u8; 8];
        be.copy_from_slice(&w[24..32]);
        if u64::from_be_bytes(be) != funding_value_sat {
            return Ok(TruthVerdict::Mismatch);
        }
        Ok(TruthVerdict::Match)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The registry is a comparand SELECTOR: it decides which on-chain channel a signer is
    /// checked against. Letting a bind move would let the node point the check at a
    /// different (or empty) record — choosing its own referee.
    #[test]
    fn a_cid_bind_is_idempotent_but_never_rebindable() {
        let r = CidRegistry::new();
        let keys = [1u8; 32];
        assert!(r.bind(keys, [9u8; 32]), "first bind");
        assert!(r.bind(keys, [9u8; 32]), "identical re-bind is a no-op, not a failure");
        assert!(!r.bind(keys, [7u8; 32]), "a CONFLICTING re-bind must be refused");
        assert_eq!(r.get(&keys), Some([9u8; 32]), "the original binding survives");
    }

    /// An unknown `channel_keys_id` must read as NOT RECORDED rather than erroring: that is
    /// the legitimate pre-record window (the EVM records a channel only once its funding is
    /// SPV-proven), and erroring would fail closed and deadlock every channel open.
    #[test]
    fn an_unknown_channel_keys_id_is_not_recorded() {
        let r = CidRegistry::new();
        assert_eq!(r.get(&[3u8; 32]), None);
    }
}
