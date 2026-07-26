//! Anti-rollback freshness guard for channel-state persistence.
//!
//! ## The gap this closes
//! The hop persists channel monitors as encrypted blobs on a **host-owned** flat
//! file store ([`crate::ffs::Ffs`]). Sealing (confidentiality/integrity) does NOT
//! stop a malicious host from serving an *older* monitor on boot — a rollback. A
//! rolled-back monitor re-opens exactly the funding-key-leak / lost-preimage /
//! revoked-state hazards that the deterministic-nonce + `bind_nonce` guards defend
//! against only *within* a process (they are re-derived, not persisted): the host
//! restarts the enclave onto stale state and the guards forget.
//!
//! ## The mechanism (quid's discrepancy pattern, QU!D's on-chain anchor)
//! Quid reconciles a fast **untrusted** store against a **rollback-resistant** one
//! (GDrive) and trusts the latter on any mismatch (`node/src/persister/
//! discrepancy.rs`). QU!D keeps the fast untrusted store (`Ffs`) but — being
//! Bitcoin/EVM-native — anchors freshness on-chain instead of a cloud provider:
//! every channel monitor carries LDK's monotonic `update_id`; on each persist we
//! `commit` the latest `(monitor, update_id)` to a rollback-resistant
//! [`FreshnessAnchor`], and on boot we `verify` that the monitor the host handed
//! back is **not behind** what the anchor attests. A stale monitor ⇒ fail closed.
//!
//! The anchor is the ONLY new trust-minimised primitive; everything else (the
//! `Ffs`, the AES-master-key VFS encryption, the `update_id`) is reused. The
//! production anchor is an on-chain per-channel counter (blockchain immutability =
//! rollback resistance, no added trusted party — see [`OnChainFreshnessAnchor`]);
//! [`InMemoryFreshnessAnchor`] is the dev/test double.

use std::collections::HashMap;
use std::sync::Mutex;

/// Anchor/ledger key for the channel-MANAGER blob. Unlike a monitor (keyed
/// by its derived on-chain channelId hex), the manager has no per-channel id — this
/// sentinel routes to the per-hop `managerFreshnessSeq` on-chain slot. It is NOT a
/// 64-char hex string, so it can never collide with a real channel key.
pub const MANAGER_FRESHNESS_KEY: &str = "channel-manager";

/// Hex-encode a 32-byte id (the LDK `channel_id`) as the freshness anchor/ledger key:
/// lowercase, no `0x` — matching the bridge resolver's `hex::decode` parse and the
/// on-chain channelId hex.
pub fn hex32(bytes: &[u8; 32]) -> String {
    let mut s = String::with_capacity(64);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// A rollback-resistant record of the highest persisted `update_id` per monitor.
///
/// Contract: `highest(m)` MUST reflect the largest `update_id` ever `commit`ted for
/// `m`, and MUST NOT regress even if the host destroys/rewinds local storage — i.e.
/// the anchor lives OUTSIDE the host's rollback-able storage (on-chain, a hardware
/// monotonic counter, or an independent attested store). An anchor that a host can
/// rewind provides no protection; see [`OnChainFreshnessAnchor`].
pub trait FreshnessAnchor {
    /// Record that `monitor` was durably persisted at `update_id`. Idempotent and
    /// monotonic: committing an `update_id` <= the current highest is a no-op.
    fn commit(&self, monitor: &str, update_id: u64) -> anyhow::Result<()>;

    /// The highest `update_id` ever committed for `monitor`, or `None` if the
    /// anchor has never seen it (a brand-new monitor).
    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>>;
}

/// Outcome of a freshness check on a monitor the host handed back at boot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Freshness {
    /// The loaded `update_id` is >= the anchored one — safe to load.
    Fresh,
    /// The loaded `update_id` is BEHIND the anchored one — the host served stale
    /// state (rollback). Fail closed. Carries (loaded, anchored) for logging.
    Stale { loaded: u64, anchored: u64 },
}

/// Verify that a monitor the host loaded is not behind the anchor. This is the
/// enforcement point: a `Stale` result MUST abort the boot (never load the stale
/// monitor). A monitor the anchor has never seen (`highest == None`) is `Fresh`
/// (first persist of a new channel) — the anchor is written *after* the first
/// successful persist, so a fresh channel legitimately has no anchored value yet.
pub fn verify<A: FreshnessAnchor + ?Sized>(
    anchor: &A,
    monitor: &str,
    loaded_update_id: u64,
) -> anyhow::Result<Freshness> {
    match anchor.highest(monitor)? {
        Some(anchored) if loaded_update_id < anchored =>
            Ok(Freshness::Stale { loaded: loaded_update_id, anchored }),
        _ => Ok(Freshness::Fresh),
    }
}

/// In-memory anchor: a dev/test double ONLY. It lives in the enclave's own memory,
/// so a host restart wipes it — it provides NO real rollback resistance and MUST
/// NOT be used in staging/prod (use [`OnChainFreshnessAnchor`]). It exists to unit-
/// test the guard mechanism and to run dev/regtest where the host is trusted.
#[derive(Default)]
pub struct InMemoryFreshnessAnchor {
    highest: Mutex<HashMap<String, u64>>,
}

impl InMemoryFreshnessAnchor {
    pub fn new() -> Self {
        Self { highest: Mutex::new(HashMap::new()) }
    }
}

impl FreshnessAnchor for InMemoryFreshnessAnchor {
    fn commit(&self, monitor: &str, update_id: u64) -> anyhow::Result<()> {
        let mut map = self.highest.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
        let entry = map.entry(monitor.to_owned()).or_insert(0);
        if update_id > *entry {
            *entry = update_id;
        }
        Ok(())
    }

    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>> {
        let map = self.highest.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
        Ok(map.get(monitor).copied())
    }
}

/// The rollback-resistant backing store for [`LedgerFreshnessAnchor`] — the piece
/// that MUST live outside the host's rewind-able storage. QU!D's production impl
/// (in `quid-bridge`) is an **on-chain** per-channel counter on `BTCChannels`
/// (`mapping(bytes32 channelId => uint64 freshnessSeq)`, monotonic, written by the
/// channel's hop): the blockchain cannot be rolled back, so a host that rewinds
/// local disk cannot rewind the ledger. Any store with the same guarantee (a
/// hardware monotonic counter, an independent attested quorum) also qualifies.
pub trait FreshnessLedger {
    /// The highest committed `update_id` for `monitor` as the rollback-resistant store
    /// attests it (`None` = never committed). Read LAZILY at boot verify (per monitor),
    /// so no bulk seed / monitor list is needed at construction; it survives a host
    /// restart because the store does.
    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>>;

    /// Durably record `(monitor, update_id)` in the rollback-resistant store. For
    /// the on-chain ledger this is an EVM write (may be async/batched internally);
    /// it must be monotonic (a lower id is rejected) and, once returned Ok, survive
    /// a host restart.
    fn store(&self, monitor: &str, update_id: u64) -> anyhow::Result<()>;
}

/// A [`FreshnessAnchor`] backed by a rollback-resistant [`FreshnessLedger`], with a
/// local cache filled LAZILY from the ledger on the first `highest()` per monitor.
/// This is the REAL anti-rollback anchor (unlike [`InMemoryFreshnessAnchor`]): because
/// the ledger survives a host restart, `highest()` still reflects the true committed
/// sequence after the host restarts the enclave onto stale disk state — so the boot
/// `verify()` catches it. No boot seed / monitor list needed (lazy per-monitor read).
pub struct LedgerFreshnessAnchor<L: FreshnessLedger> {
    ledger: L,
    /// Cache of highest-seen per monitor: filled from `ledger.highest()` on a miss and
    /// advanced on each `commit`. Avoids re-reading the ledger every verify.
    cache: Mutex<HashMap<String, u64>>,
}

impl<L: FreshnessLedger> LedgerFreshnessAnchor<L> {
    pub fn new(ledger: L) -> Self {
        Self { ledger, cache: Mutex::new(HashMap::new()) }
    }
}

impl<L: FreshnessLedger> FreshnessAnchor for LedgerFreshnessAnchor<L> {
    fn commit(&self, monitor: &str, update_id: u64) -> anyhow::Result<()> {
        {
            let mut cache = self.cache.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
            let entry = cache.entry(monitor.to_owned()).or_insert(0);
            if update_id <= *entry {
                return Ok(()); // monotonic: a lower/equal id is a no-op, no ledger write
            }
            *entry = update_id;
        }
        // Advance the rollback-resistant store. Cache is already advanced so reads
        // are consistent; a ledger-write failure surfaces to the caller (persister
        // logs it — the local blob is still written, only the freshness window widens).
        self.ledger.store(monitor, update_id)
    }

    fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>> {
        {
            let cache = self.cache.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
            if let Some(v) = cache.get(monitor) {
                return Ok(Some(*v));
            }
        }
        // Cache miss: read the rollback-resistant ledger (the on-chain truth) and cache
        // it. This is what catches a restart — the host wiped in-memory state, but the
        // ledger still attests the pre-restart sequence.
        let v = self.ledger.highest(monitor)?;
        if let Some(u) = v {
            let mut cache = self.cache.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
            cache.entry(monitor.to_owned()).or_insert(u);
        }
        Ok(v)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn commit_is_monotonic() {
        let a = InMemoryFreshnessAnchor::new();
        a.commit("chan#a", 5).unwrap();
        a.commit("chan#a", 3).unwrap(); // lower ⇒ no-op
        assert_eq!(a.highest("chan#a").unwrap(), Some(5));
        a.commit("chan#a", 9).unwrap();
        assert_eq!(a.highest("chan#a").unwrap(), Some(9));
    }

    #[test]
    fn fresh_when_at_or_ahead_of_anchor() {
        let a = InMemoryFreshnessAnchor::new();
        a.commit("chan#a", 7).unwrap();
        assert_eq!(verify(&a, "chan#a", 7).unwrap(), Freshness::Fresh); // equal
        assert_eq!(verify(&a, "chan#a", 8).unwrap(), Freshness::Fresh); // ahead
    }

    #[test]
    fn stale_when_behind_anchor_is_detected() {
        // The rollback: host persisted update_id 10, then serves an OLD blob at 6.
        let a = InMemoryFreshnessAnchor::new();
        a.commit("chan#a", 10).unwrap();
        assert_eq!(
            verify(&a, "chan#a", 6).unwrap(),
            Freshness::Stale { loaded: 6, anchored: 10 },
            "a monitor behind the anchor MUST be flagged stale (rollback)"
        );
    }

    #[test]
    fn unseen_monitor_is_fresh() {
        // A brand-new channel: the anchor is written only AFTER the first persist,
        // so no anchored value yet ⇒ must not spuriously fail the first boot.
        let a = InMemoryFreshnessAnchor::new();
        assert_eq!(verify(&a, "chan#new", 0).unwrap(), Freshness::Fresh);
    }

    #[test]
    fn per_monitor_isolation() {
        let a = InMemoryFreshnessAnchor::new();
        a.commit("chan#a", 10).unwrap();
        a.commit("chan#b", 2).unwrap();
        assert_eq!(verify(&a, "chan#a", 9).unwrap(), Freshness::Stale { loaded: 9, anchored: 10 });
        assert_eq!(verify(&a, "chan#b", 9).unwrap(), Freshness::Fresh);
    }

    /// A persistent mock ledger (shared state that survives anchor recreation) —
    /// models the on-chain counter surviving a host restart.
    #[derive(Clone, Default)]
    struct MockLedger(Arc<Mutex<HashMap<String, u64>>>);
    impl FreshnessLedger for MockLedger {
        fn highest(&self, monitor: &str) -> anyhow::Result<Option<u64>> {
            Ok(self.0.lock().unwrap().get(monitor).copied())
        }
        fn store(&self, monitor: &str, update_id: u64) -> anyhow::Result<()> {
            let mut m = self.0.lock().unwrap();
            let e = m.entry(monitor.to_owned()).or_insert(0);
            if update_id > *e {
                *e = update_id;
            }
            Ok(())
        }
    }

    #[test]
    fn ledger_anchor_survives_restart_and_catches_rollback() {
        let ledger = MockLedger::default();
        // Pre-restart: commit update_id 10.
        let a1 = LedgerFreshnessAnchor::new(ledger.clone());
        a1.commit("chan#a", 10).unwrap();
        assert_eq!(a1.highest("chan#a").unwrap(), Some(10));

        // Host RESTART: a brand-new anchor (empty cache) over the SAME (rollback-
        // resistant) ledger. Unlike InMemory, a lazy read recovers the committed seq.
        let a2 = LedgerFreshnessAnchor::new(ledger.clone());
        assert_eq!(a2.highest("chan#a").unwrap(), Some(10), "ledger survived the restart");
        // The host now serves a STALE monitor (update_id 6) → caught ACROSS the restart.
        assert_eq!(
            verify(&a2, "chan#a", 6).unwrap(),
            Freshness::Stale { loaded: 6, anchored: 10 },
            "ledger-backed anchor catches rollback across a restart (InMemory could not)"
        );
        // A genuinely fresh monitor is still allowed.
        assert_eq!(verify(&a2, "chan#a", 11).unwrap(), Freshness::Fresh);
    }

    #[test]
    fn ledger_anchor_monotonic_write_through() {
        let ledger = MockLedger::default();
        let a = LedgerFreshnessAnchor::new(ledger.clone());
        a.commit("chan#a", 5).unwrap();
        a.commit("chan#a", 3).unwrap(); // lower ⇒ no-op, no ledger write
        a.commit("chan#a", 9).unwrap();
        assert_eq!(ledger.highest("chan#a").unwrap(), Some(9));
    }
}
