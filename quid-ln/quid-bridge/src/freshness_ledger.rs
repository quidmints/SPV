//! On-chain [`FreshnessLedger`] — the rollback-resistant backing for the enclave's
//! anti-rollback freshness guard (`quid_hop::freshness`). It reads/writes the monotonic
//! per-channel `freshnessSeq` counter on `BTCChannels` (`commitFreshness` /
//! `freshnessSeq(bytes32)`) through the bridge EVM client. The chain cannot be rolled
//! back, so `highest()` survives a host restart — the property the in-memory anchor
//! lacks — and the enclave's boot `verify()` catches a host serving stale sealed state.
//!
//! Keyed on the channel's `channelId` (bytes32, hex). The daemon constructs a
//! `quid_hop::freshness::LedgerFreshnessAnchor` over this ledger, seeded at boot with
//! the hop's known channelIds, mapping each channel-monitor to its channelId.

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use alloy_primitives::{hex, keccak256, Address};

use quid_hop::freshness::FreshnessLedger;

use crate::abi::word_to_uint;
use crate::client::{JsonRpcEvmClient, TxSigner};
use crate::transport::JsonRpc;

/// Resolves a monitor key (the persister's per-monitor id = the LDK `channel_id` hex)
/// to the on-chain `channelId` the freshness counter is keyed on. In production this is
/// a store-backed lookup (`BridgeStore::onchain_cid`, populated when a channel is
/// reconciled on-chain); [`identity_resolver`] (the key IS a channelId) is used by the
/// e2e and any caller that already keys on channelId.
pub type CidResolver = Arc<dyn Fn(&str) -> anyhow::Result<[u8; 32]> + Send + Sync>;

/// Parse a monitor key that IS a 32-byte `channelId` hex (with or without `0x`).
fn channel_id_hex(monitor: &str) -> anyhow::Result<[u8; 32]> {
    let s = monitor.strip_prefix("0x").unwrap_or(monitor);
    let bytes =
        hex::decode(s).map_err(|e| anyhow::anyhow!("bad channelId hex {monitor}: {e}"))?;
    <[u8; 32]>::try_from(bytes.as_slice())
        .map_err(|_| anyhow::anyhow!("channelId must be 32 bytes, got {}", bytes.len()))
}

/// Identity resolver: the monitor key IS the channelId hex.
/// The production resolver. The persister/boot key the anchor on the on-chain
/// `channelId` hex DERIVED from the sealed monitor (`node::onchain_cid_from_monitor`
/// — audit F3), so the key already IS the on-chain id: resolving is just the hex
/// parse, no host-writable map. (Formerly `store_backed_resolver` looked the id up in
/// the plaintext `BridgeStore.onchain_cid` map, which a host could repoint.)
pub fn identity_resolver() -> CidResolver {
    Arc::new(channel_id_hex)
}

/// A [`FreshnessLedger`] backed by `BTCChannels.freshnessSeq` / `.commitFreshness`.
pub struct BtcChannelsFreshnessLedger<R: JsonRpc, S: TxSigner> {
    evm: Arc<JsonRpcEvmClient<R, S>>,
    btc_channels: Address,
    gas_limit: u64,
    resolver: CidResolver,
}

impl<R: JsonRpc, S: TxSigner> BtcChannelsFreshnessLedger<R, S> {
    pub fn new(
        evm: Arc<JsonRpcEvmClient<R, S>>,
        btc_channels: Address,
        gas_limit: u64,
        resolver: CidResolver,
    ) -> Self {
        Self { evm, btc_channels, gas_limit, resolver }
    }
}

use quid_hop::freshness::MANAGER_FRESHNESS_KEY;

impl<R: JsonRpc, S: TxSigner> BtcChannelsFreshnessLedger<R, S> {
    /// The hop's address left-padded to a 32-byte ABI word (the `managerFreshnessSeq`
    /// map key = this signer).
    fn hop_address_word(&self) -> [u8; 32] {
        crate::abi::address_word(self.evm.address())
    }
}

impl<R: JsonRpc, S: TxSigner> FreshnessLedger for BtcChannelsFreshnessLedger<R, S> {
    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>> {
        // AGREEMENT-classed read (concrete recent block): a single lying/compromised
        // endpoint can't forge the seq→0 to slip a rolled-back monitor/manager past the
        // boot check (audit F2). See eth_read_agreed for the host-MITM residual.
        let raw = if monitor == MANAGER_FRESHNESS_KEY {
            let hop = self.hop_address_word();
            self.evm.eth_read_agreed(
                self.btc_channels,
                "managerFreshnessSeq(address)",
                Some(&hop),
            )?
        } else {
            let cid = (self.resolver)(monitor)?;
            self.evm
                .eth_read_agreed(self.btc_channels, "freshnessSeq(bytes32)", Some(&cid))?
        };
        let seq: u64 = word_to_uint(&raw, "freshnessSeq")?;
        // The seq is 0 for a never-committed channel/manager (commit is strictly
        // monotonic from 0, so a real committed value is >= 1) ⇒ 0 means None.
        Ok(if seq == 0 { None } else { Some(seq) })
    }

    fn store(&self, monitor: &str, seq: u64) -> anyhow::Result<()> {
        // calldata = selector ‖ [channelId] ‖ seq(word). The manager path drops the
        // channelId (keyed on-chain by msg.sender = hop).
        let mut data = Vec::with_capacity(4 + 64);
        if monitor == MANAGER_FRESHNESS_KEY {
            data.extend_from_slice(&keccak256("commitManagerFreshness(uint64)")[..4]);
        } else {
            let cid = (self.resolver)(monitor)?;
            data.extend_from_slice(&keccak256("commitFreshness(bytes32,uint64)")[..4]);
            data.extend_from_slice(&cid);
        }
        data.extend_from_slice(&crate::abi::u64_word(seq));
        // send_tx returns success=false on revert (the on-chain monotonic guard). A
        // rejected rollback/replay surfaces as Err — the persister logs it; the local
        // blob is still written, only the freshness window widens until the next commit.
        if !self.evm.send_tx(self.btc_channels, data, self.gas_limit)? {
            anyhow::bail!(
                "freshness commit reverted (on-chain monotonic guard) for {monitor}@{seq}"
            );
        }
        Ok(())
    }
}

/// Max update_ids the enclave may sign AHEAD of the last on-chain-CONFIRMED freshness seq
/// before [`QueuedFreshnessLedger::store`] fails closed. On-chain commits are async (off the
/// LDK hot path), so a small in-flight lag is normal; but if the writes stop landing — a host
/// censoring the enclave's (host-routed) EVM RPC in the untrusted-host model — the in-memory
/// cache keeps advancing while the durable on-chain anchor freezes, and a later rollback ABOVE
/// the frozen value would pass boot `verify()` silently (audit F6). Halting past this bound
/// converts censorship into a fail-closed DoS instead of a rollback-theft window; the bound
/// also caps how many revoked states a censoring host could ever choose from. Generous enough
/// to absorb bursts + transient RPC blips (commits land in seconds), tight enough to bound the
/// attack. Self-host (trusted host) never hits it — the writes land.
const MAX_UNCONFIRMED_LAG: u64 = 128;

/// Whether signing at `seq` is too far ahead of the last on-chain-CONFIRMED `confirmed`
/// seq to continue (fail-closed vs a censoring host). Saturating so a `confirmed` that is
/// (transiently) ahead of `seq` never underflows into a false halt. Extracted for testing.
fn lag_exceeds_bound(seq: u64, confirmed: u64) -> bool {
    seq.saturating_sub(confirmed) > MAX_UNCONFIRMED_LAG
}

/// Non-blocking [`FreshnessLedger`] for the LDK monitor-persist HOT PATH.
///
/// `HopPersister::write_monitor` runs on every channel-monitor update and LDK gates
/// channel progress on it returning; the on-chain [`BtcChannelsFreshnessLedger::store`]
/// blocks on a tx receipt (seconds) and costs gas per call, so it must NOT run inline.
/// This wrapper's `store` just ENQUEUES `(channelId, seq)` (never blocks); a background
/// committer thread ([`spawn`]) coalesces per channel (latest seq wins, so N rapid
/// updates collapse to one on-chain write) and does the real writes off the hot path.
/// `load_all` (boot only) reads on-chain directly.
pub struct QueuedFreshnessLedger<R: JsonRpc, S: TxSigner> {
    tx: mpsc::Sender<(String, u64)>,
    reader: Arc<BtcChannelsFreshnessLedger<R, S>>,
    /// Highest seq the background committer has CONFIRMED on-chain, per monitor. The enqueue
    /// path (`store`) refuses to advance more than [`MAX_UNCONFIRMED_LAG`] beyond it, so a
    /// censoring host can't stall the durable anchor while the enclave signs on. Written by
    /// `committer_loop` on each successful on-chain write.
    confirmed: Arc<Mutex<HashMap<String, u64>>>,
}

impl<R: JsonRpc, S: TxSigner> QueuedFreshnessLedger<R, S> {
    /// Wrap `ledger` and spawn the background committer thread. The thread ends cleanly
    /// when this ledger (and every clone of its sender) is dropped (`recv` returns Err).
    pub fn spawn(ledger: Arc<BtcChannelsFreshnessLedger<R, S>>) -> (Self, thread::JoinHandle<()>) {
        let (tx, rx) = mpsc::channel::<(String, u64)>();
        let worker = ledger.clone();
        let confirmed: Arc<Mutex<HashMap<String, u64>>> = Arc::new(Mutex::new(HashMap::new()));
        let committer_confirmed = confirmed.clone();
        let handle = thread::Builder::new()
            .name("freshness-committer".into())
            .spawn(move || committer_loop(rx, worker, committer_confirmed))
            .expect("spawn freshness committer");
        (Self { tx, reader: ledger, confirmed }, handle)
    }
}

impl<R: JsonRpc, S: TxSigner> FreshnessLedger for QueuedFreshnessLedger<R, S> {
    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>> {
        self.reader.highest(monitor)
    }

    fn store(&self, monitor: &str, seq: u64) -> anyhow::Result<()> {
        // FAIL CLOSED if the on-chain commits have stalled too far behind (a host censoring
        // the enclave's EVM RPC in the untrusted-host model): signing more than
        // MAX_UNCONFIRMED_LAG ahead of the last durable on-chain seq would let a later
        // rollback above the frozen anchor pass boot verify() silently (audit F6). The
        // persister turns this Err into a graceful shutdown (the existing committer-down
        // fail-closed path), so the next boot reads the real on-chain anchor. This closes the
        // gap where the committer thread is ALIVE but all its writes are being censored.
        let confirmed = self
            .confirmed
            .lock()
            .map_err(|_| anyhow::anyhow!("freshness confirmed-map poisoned"))?
            .get(monitor)
            .copied()
            .unwrap_or(0);
        if lag_exceeds_bound(seq, confirmed) {
            anyhow::bail!(
                "freshness on-chain commits stalled: {monitor} at seq {seq} is >{} ahead of the \
                 last confirmed on-chain seq {confirmed} — refusing to sign further (host \
                 censorship?); failing closed",
                MAX_UNCONFIRMED_LAG
            );
        }
        // NON-BLOCKING: hand off to the committer thread; never blocks the LDK hot path.
        self.tx
            .send((monitor.to_owned(), seq))
            .map_err(|_| anyhow::anyhow!("freshness committer stopped"))
    }
}

/// The background committer: block for one item, drain the rest currently queued,
/// coalesce to the max seq per channel, then do the real on-chain writes. Coalescing
/// means a burst of monitor updates for a channel becomes a SINGLE on-chain commit at
/// the highest seq. A reverted/stale commit (the on-chain monotonic guard, or a channel
/// whose cid isn't mapped yet) is logged, not fatal — the next update re-commits higher.
fn committer_loop<R: JsonRpc, S: TxSigner>(
    rx: mpsc::Receiver<(String, u64)>,
    ledger: Arc<BtcChannelsFreshnessLedger<R, S>>,
    confirmed: Arc<Mutex<HashMap<String, u64>>>,
) {
    while let Ok(first) = rx.recv() {
        let mut latest: HashMap<String, u64> = HashMap::new();
        let (m, s) = first;
        latest.insert(m, s);
        while let Ok((m, s)) = rx.try_recv() {
            let e = latest.entry(m).or_insert(0);
            if s > *e {
                *e = s;
            }
        }
        for (monitor, seq) in latest {
            // A store error is transient (RPC/relay) — log and keep looping; the next
            // monitor update re-enqueues a higher seq. A PANIC inside `store` (EVM
            // codec / relay path) must NOT kill this thread: if the committer dies the
            // on-chain counter silently freezes while the enclave cache keeps advancing
            // (audit F6). catch_unwind contains it so the committer survives; the
            // persister's commit-failure path is the fail-closed backstop if it ever
            // does exit (mpsc receiver dropped ⇒ node shutdown).
            let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                ledger.store(&monitor, seq)
            }));
            match res {
                Ok(Ok(())) => {
                    // Record the on-chain-confirmed seq so `store`'s lag gate knows how far
                    // durable state has actually advanced (fail-closed vs a censoring host).
                    if let Ok(mut c) = confirmed.lock() {
                        let e = c.entry(monitor.clone()).or_insert(0);
                        if seq > *e {
                            *e = seq;
                        }
                    }
                }
                Ok(Err(e)) => tracing::warn!("freshness committer: {monitor}@{seq}: {e:#}"),
                Err(_) => {
                    tracing::error!("freshness committer PANICKED on {monitor}@{seq} — contained")
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{lag_exceeds_bound, MAX_UNCONFIRMED_LAG};

    #[test]
    fn lag_gate_fails_closed_only_past_the_bound() {
        // Fresh channel / all commits landing: at or under the bound is allowed.
        assert!(!lag_exceeds_bound(MAX_UNCONFIRMED_LAG, 0), "at the bound is allowed");
        assert!(!lag_exceeds_bound(0, 0));
        // One past the bound with the on-chain anchor frozen at 0 (host censoring) → halt.
        assert!(lag_exceeds_bound(MAX_UNCONFIRMED_LAG + 1, 0), "one past the bound fails closed");
        // Commits keeping pace: seq far ahead but confirmed tracks within the bound → allowed.
        assert!(!lag_exceeds_bound(1_000, 1_000 - MAX_UNCONFIRMED_LAG));
        // Commits falling one behind the bound → halt.
        assert!(lag_exceeds_bound(1_000, 1_000 - MAX_UNCONFIRMED_LAG - 1));
        // Saturating: a confirmed seq AHEAD of seq (transient reorder) must never underflow
        // into a false halt.
        assert!(!lag_exceeds_bound(5, 100));
    }
}
