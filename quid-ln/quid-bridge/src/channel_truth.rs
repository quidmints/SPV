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

use std::sync::{Arc, OnceLock, Weak};

use alloy_primitives::Address;
use quid_hop::node::{onchain_cid_from_monitor, HopChainMonitor};
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

/// (§BTC-2.1) Resolves `channel_keys_id → on-chain channelId` by **COMPUTING it, never by
/// caching it.**
///
/// ⛔ **DO NOT REPLACE THIS WITH A `channel_keys_id → channelId` MAP.** `channelId =
/// keccak256(lpPubkey, hopPubkey, fundingTxId, vout)` (`ChannelLib.sol:640`) is a deterministic
/// function of four values a `ChannelMonitor` already holds, so a map stores only what can be
/// recomputed — and it needs a WRITER. A writer lives in one process; the comparand is needed in
/// **every process that signs**, and the one whose refusal actually matters is the LP's half — which
/// today is produced inside the fleet (§NO-SELF-PROVISIONED-LPS) and tomorrow by the remote
/// `ChannelSigner` on the LP's phone (`§BITCOIN-ORDER` item 0). Recomputing from the monitor is what
/// lets that future process check anything at all without a feed from here. A signer wired to a map
/// nobody fills answers `NotRecorded` forever: permanently permissive while `has_truth_source()`
/// reports `true`.
///
/// 🔑 **WHY THE MONITOR IS REACHABLE HERE WHEN IT IS NOT AT DERIVE TIME.**
/// [`TruthSourceFactory::for_channel`] is called from `SignerProvider::derive_channel_signer`,
/// which is handed a `channel_keys_id` and nothing else. But the source resolves the cid
/// **LAZILY, AT VERIFY TIME**, and by then the channel's `ChannelMonitor` exists and the
/// `ChainMonitor` that owns it has been built — so this holds a handle to the `ChainMonitor` and
/// finds the monitor by its `channel_keys_id` on each check.
///
/// ⚠️ **`Weak`, NOT `Arc`, AND THAT IS LOAD-BEARING.** The `ChainMonitor` owns the
/// `ChannelMonitor`s, which own the signers, which own this source. An `Arc` pointing back at the
/// `ChainMonitor` closes that cycle and leaks the whole monitor set for the process lifetime.
///
/// ⚠️ **SET ONCE, AFTER `node::boot` RETURNS.** The keys manager (which holds the factory) is
/// constructed BEFORE the `ChainMonitor` inside `quid_hop::node::boot`, so the handle cannot be a
/// constructor argument. Until [`Self::attach`] runs — and for any channel whose monitor is not
/// yet watched, which is every channel between `funding_created` and `watch_channel` — this
/// answers `None`, which the caller reports as [`TruthVerdict::NotRecorded`]. That is the same
/// permissive-then-latched window the three-state check is built around, not a new hole.
///
/// ⚠️ **NO LOCK IS HELD ACROSS THE `eth_call`.** `cid_for` takes and releases the `ChainMonitor`
/// read lock before [`OnChainChannelTruth::read`] makes its RPC. The check runs inside
/// `provide_taproot_context`, which LDK calls only from `ln/channel.rs` (never from under the
/// `ChainMonitor`'s own lock), so this look-up does not re-enter a lock its caller holds.
#[derive(Default)]
pub struct MonitorCids {
    monitors: OnceLock<Weak<HopChainMonitor>>,
}

impl MonitorCids {
    pub fn new() -> Self {
        Self::default()
    }

    /// Attach the node's `ChainMonitor`. Call ONCE, immediately after `node::boot`. Returns
    /// `false` if a handle was already set — a second attach is REFUSED rather than swapped,
    /// because the monitor set decides which on-chain channel every signer is checked against,
    /// and letting it move would let the node pick its own referee.
    pub fn attach(&self, chain_monitor: &Arc<HopChainMonitor>) -> bool {
        self.monitors.set(Arc::downgrade(chain_monitor)).is_ok()
    }

    /// True once [`Self::attach`] has run — so a boot path can ASSERT the comparand is
    /// resolvable instead of silently running permissive.
    pub fn is_attached(&self) -> bool {
        self.monitors.get().is_some()
    }

    /// The STABLE on-chain `channelId` for the channel this `channel_keys_id` signs, or `None`
    /// while it cannot be computed (no handle yet, or no monitor watching that channel yet).
    ///
    /// ⚠️ (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) The derivation is [`onchain_cid_from_monitor`] —
    /// the SAME one `select_delivery_channels`, the reconciler, the freshness key and
    /// `VaultNode::ldk_channel_for` use. It pairs the ORIGINAL outpoint with the ORIGINAL
    /// pubkey pair, because LDK rotates the live pair on every splice while `BTCChannels`
    /// hashes both originals into the id. This is IDENTITY, not spend. Do not reimplement it
    /// here: a pricing/identity term written twice is one that drifts.
    ///
    /// The scan is linear in this node's channel count and runs once per check, which is free
    /// beside the `eth_call` the caller makes immediately afterwards.
    pub fn cid_for(&self, channel_keys_id: &[u8; 32]) -> Option<[u8; 32]> {
        let chain_monitor = self.monitors.get()?.upgrade()?;
        for ch_id in chain_monitor.list_monitors() {
            let Ok(monitor) = chain_monitor.get_monitor(ch_id) else { continue };
            if monitor.channel_keys_id() == *channel_keys_id {
                return onchain_cid_from_monitor(&monitor);
            }
        }
        None
    }
}

/// A [`ChannelTruthSource`] backed by `BTCChannels` on the EVM.
pub struct OnChainChannelTruth<R: JsonRpc> {
    rpc: Arc<R>,
    btc_channels: Address,
    cids: Arc<MonitorCids>,
    channel_keys_id: [u8; 32],
}

impl<R: JsonRpc> OnChainChannelTruth<R> {
    pub fn new(
        rpc: Arc<R>,
        btc_channels: Address,
        cids: Arc<MonitorCids>,
        channel_keys_id: [u8; 32],
    ) -> Self {
        Self { rpc, btc_channels, cids, channel_keys_id }
    }

    /// The raw `channels(channelId)` return. `Ok(None)` = the cid is not known yet, which
    /// the caller reports as `NotRecorded`. Refused unless the return is the full six words.
    fn read(&self) -> Result<Option<Vec<u8>>, ()> {
        let Some(cid) = self.cids.cid_for(&self.channel_keys_id) else {
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
    cids: Arc<MonitorCids>,
}

impl<R: JsonRpc> OnChainTruthFactory<R> {
    pub fn new(rpc: Arc<R>, btc_channels: Address, cids: Arc<MonitorCids>) -> Self {
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

    /// An UNATTACHED resolver must read as NOT RECORDED rather than erroring or panicking:
    /// that is the legitimate pre-record window (the EVM records a channel only once its
    /// funding is SPV-proven, and a monitor is watched only after the first commitment), and
    /// erroring would fail closed and deadlock every channel open.
    #[test]
    fn an_unattached_resolver_is_not_recorded() {
        let r = MonitorCids::new();
        assert!(!r.is_attached());
        assert_eq!(r.cid_for(&[3u8; 32]), None);
    }
}
