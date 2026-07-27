//! Thin `QuidPersister`-over-`Ffs` adapter for the hop node.
//!
//! Reuse, not rewrite: storage is quid's `Ffs` (copied verbatim in `ffs.rs`),
//! encryption is quid-ln's existing free helpers (`quid_ln::persister::*`). We
//! implement only the trait surface the node stack requires:
//!   • `Vfs`        — channel-manager / channel-monitor blobs, over `Ffs`.
//!   • `PersisterMethods` — `persist_manager` + `persist_channel_monitor`
//!     are real; the ~15 payment-DB methods are STUBBED, because a hop tracks
//!     swap state on-chain (`settleSwapIn`) and runs no `PaymentsManager`.
//!   • `Persist<SignerType>` — synchronous monitor persistence to `Ffs`
//!     (returns `Completed`); no async persister task needed for the hop.
//! The blanket `impl QuidPersister` (quid-ln `traits.rs`) then applies for free.

use std::sync::Arc;

use anyhow::{anyhow, bail};
use async_trait::async_trait;
use serde::Serialize;
use tracing::{error, warn};
use quid_async_util::notify_once::NotifyOnce;

use lightning::{
    chain::{
        chainmonitor::Persist, channelmonitor::ChannelMonitorUpdate,
        ChannelMonitorUpdateStatus,
    },
    ln::types::ChannelId,
    util::{persist::MonitorName, ser::Writeable},
};

use quid_api::{
    error::BackendApiError,
    models::command::{GetUpdatedPaymentMetadata, GetUpdatedPayments},
    types::{
        payments::{DbPaymentMetadata, DbPaymentV2, PaymentId},
        Empty,
    },
    vfs::{self, Vfs, VfsDirectory, VfsDirectoryList, VfsFile, VfsFileId},
};
use quid_common::{ln::channel::LxChannelId, time::TimestampMs};
use quid_crypto::{aes::AesMasterKey, rng::SysRng};

use quid_ln::{
    alias::{ChannelMonitorType, ChainMonitorType, SignerType},
    channel_monitor::LxMonitorName,
    payments::{
        manager::{CheckedPayment, PersistedPayment},
        PaymentMetadata, PaymentV2, PaymentWithMetadata,
    },
    persister as ln_persister,
    persister::PersisterMethods,
    traits::QuidPersister,
};

use crate::ffs::Ffs;
use crate::freshness::FreshnessAnchor;

/// Persister backed by a flat-file store (`Ffs`) + quid-ln's AES master key.
pub struct HopPersister<F: Ffs> {
    ffs: F,
    vfs_master_key: Arc<AesMasterKey>,
    /// Signalled to shut the node down if a monitor write persistently fails
    /// (mirrors quid's persist-failure → graceful-shutdown, vs LDK's
    /// `UnrecoverableError` which panics).
    shutdown: NotifyOnce,
    /// Anti-rollback: after a monitor is durably persisted at `update_id` we
    /// `commit` it to this rollback-resistant anchor, so a host that later serves
    /// a stale monitor is caught at boot (`crate::freshness`). The `Ffs` alone
    /// gives no freshness — sealing doesn't stop the host serving an OLD blob.
    anchor: Arc<dyn FreshnessAnchor + Send + Sync>,
    /// Monotonic channel-MANAGER blob freshness counter. LDK's channel
    /// manager has no in-blob update_id, so we stamp this seq INTO the sealed blob
    /// (inside the AEAD, so a host can't forge it) and `commit` it to the anchor
    /// under `MANAGER_FRESHNESS_KEY` on every persist. Set from the loaded blob's
    /// embedded seq at boot (`set_manager_seq`), then increments per persist.
    manager_seq: std::sync::atomic::AtomicU64,
}

impl<F: Ffs> HopPersister<F> {
    pub fn new(
        ffs: F,
        vfs_master_key: Arc<AesMasterKey>,
        shutdown: NotifyOnce,
        anchor: Arc<dyn FreshnessAnchor + Send + Sync>,
    ) -> Self {
        Self {
            ffs,
            vfs_master_key,
            shutdown,
            anchor,
            manager_seq: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// Seed the manager-freshness counter from the seq embedded in the loaded manager
    /// blob at boot, BEFORE any persist, so the first post-boot persist advances from
    /// the real on-chain value (not from 0, which would false-`FreshnessNotMonotonic`).
    pub fn set_manager_seq(&self, seq: u64) {
        self.manager_seq
            .store(seq, std::sync::atomic::Ordering::SeqCst);
    }

    /// Flatten a `VfsFileId` (dir + filename) into one flat `Ffs` filename. The
    /// vfs dir names are protocol constants without `#`, so `#` separates
    /// cleanly and `list_directory` can recover filenames by prefix.
    fn flat(file_id: &VfsFileId) -> String {
        format!("{}#{}", file_id.dir.dirname, file_id.filename)
    }

    /// Encrypt + write a channel monitor to the monitors dir (synchronous).
    fn write_monitor(
        &self,
        name: MonitorName,
        monitor: &ChannelMonitorType,
    ) -> ChannelMonitorUpdateStatus {
        // LDK's monotonic per-monitor update id (the freshness sequence), and the
        // freshness anchor key = the STABLE on-chain channelId DERIVED from this SEALED
        // monitor (audit F3) — NOT the host-writable `BridgeStore.onchain_cid` map,
        // which a host could repoint to another channel's counter. `None` before the
        // funding params are populated (pre-funding: no revoked state to protect), in
        // which case we still persist the monitor but skip the anchor commit. The FILE
        // keeps its LxMonitorName layout.
        let update_id = monitor.get_latest_update_id();
        let monitor_cid = crate::node::onchain_cid_from_monitor(monitor);
        let file_id = VfsFileId::new(
            vfs::CHANNEL_MONITORS_DIR,
            LxMonitorName::from(name).to_string(),
        );
        let mut rng = SysRng::new();
        let file = ln_persister::encrypt_ldk_writeable(
            &mut rng,
            &self.vfs_master_key,
            file_id,
            monitor,
        );
        let key = Self::flat(&file.id);
        // Retry transient write failures. Since persistence is SYNCHRONOUS there
        // is no async completion to drive `InProgress` → on persistent failure we
        // signal graceful shutdown and return `InProgress` (the channel freezes,
        // which is moot as the node is going down). We do NOT return
        // `UnrecoverableError`, which LDK turns into an immediate panic.
        for attempt in 0..3u32 {
            match self.ffs.write(&key, &file.data) {
                Ok(()) => {
                    // Durably persisted at `update_id` — commit it to the rollback-
                    // resistant anchor so a later stale reload of this monitor is
                    // caught at boot. Skip only when the on-chain cid isn't derivable
                    // yet (pre-funding: no revoked state to protect).
                    if let Some(oc) = &monitor_cid {
                        let monitor_key = crate::freshness::hex32(oc);
                        if let Err(e) = self.anchor.commit(&monitor_key, update_id) {
                            // A queued-ledger commit fails ONLY when the background
                            // committer thread is gone (mpsc receiver dropped) —
                            // permanent, not transient. Continuing would advance the
                            // in-memory cache while the on-chain counter freezes, so a
                            // later rollback above the frozen value would pass
                            // `verify()` silently (audit F6). Fail closed: shut down;
                            // the next boot reads the real on-chain anchor. (The
                            // InMemory dev anchor never errors here.)
                            error!(
                                "Fatal: freshness anchor commit failed \
                                 ({monitor_key}@{update_id}): {e:#} — committer down, \
                                 shutting down"
                            );
                            self.shutdown.send();
                            return ChannelMonitorUpdateStatus::InProgress;
                        }
                    }
                    return ChannelMonitorUpdateStatus::Completed;
                }
                Err(e) => warn!("monitor persist attempt {attempt} failed: {e}"),
            }
        }
        error!("Fatal: could not persist channel monitor; shutting down");
        self.shutdown.send();
        ChannelMonitorUpdateStatus::InProgress
    }
}

#[async_trait]
impl<F: Ffs + Send + Sync> Vfs for HopPersister<F> {
    async fn get_file(
        &self,
        file_id: &VfsFileId,
    ) -> Result<Option<VfsFile>, BackendApiError> {
        match self.ffs.read(&Self::flat(file_id)) {
            Ok(data) => Ok(Some(VfsFile::from_parts(file_id.clone(), data))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(BackendApiError::database(e)),
        }
    }

    async fn upsert_file(
        &self,
        file_id: &VfsFileId,
        data: bytes::Bytes,
        _retries: usize,
    ) -> Result<Empty, BackendApiError> {
        self.ffs
            .write(&Self::flat(file_id), &data)
            .map_err(BackendApiError::database)?;
        Ok(Empty {})
    }

    async fn delete_file(
        &self,
        file_id: &VfsFileId,
    ) -> Result<Empty, BackendApiError> {
        match self.ffs.delete(&Self::flat(file_id)) {
            Ok(()) => Ok(Empty {}),
            // Idempotent delete: missing file is success.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Empty {}),
            Err(e) => Err(BackendApiError::database(e)),
        }
    }

    async fn list_directory(
        &self,
        dir: &VfsDirectory,
    ) -> Result<VfsDirectoryList, BackendApiError> {
        let prefix = format!("{}#", dir.dirname);
        let mut filenames = Vec::new();
        self.ffs
            .read_dir_visitor(|name| {
                if let Some(rest) = name.strip_prefix(&prefix) {
                    filenames.push(rest.to_owned());
                }
                Ok(())
            })
            .map_err(BackendApiError::database)?;
        Ok(VfsDirectoryList {
            dirname: dir.dirname.clone(),
            filenames,
        })
    }

    #[inline]
    fn encrypt_ldk_writeable<W: Writeable>(
        &self,
        file_id: VfsFileId,
        writeable: &W,
    ) -> VfsFile {
        let mut rng = SysRng::new();
        ln_persister::encrypt_ldk_writeable(
            &mut rng,
            &self.vfs_master_key,
            file_id,
            writeable,
        )
    }

    #[inline]
    fn encrypt_json<T: Serialize>(
        &self,
        file_id: VfsFileId,
        value: &T,
    ) -> VfsFile {
        let mut rng = SysRng::new();
        ln_persister::encrypt_json(
            &mut rng,
            &self.vfs_master_key,
            file_id,
            value,
        )
    }

    #[inline]
    fn encrypt_bytes(
        &self,
        file_id: VfsFileId,
        plaintext_bytes: &[u8],
    ) -> VfsFile {
        let mut rng = SysRng::new();
        ln_persister::encrypt_bytes(
            &mut rng,
            &self.vfs_master_key,
            file_id,
            plaintext_bytes,
        )
    }

    #[inline]
    fn decrypt_file(
        &self,
        expected_file_id: &VfsFileId,
        file: VfsFile,
    ) -> anyhow::Result<Vec<u8>> {
        ln_persister::decrypt_file(&self.vfs_master_key, expected_file_id, file)
    }
}

#[async_trait]
impl<F: Ffs + Send + Sync> PersisterMethods for HopPersister<F> {
    async fn persist_manager<CM: Writeable + Send + Sync>(
        &self,
        channel_manager: &CM,
    ) -> anyhow::Result<()> {
        use std::sync::atomic::Ordering;
        let file_id =
            VfsFileId::new(vfs::SINGLETON_DIRECTORY, vfs::CHANNEL_MANAGER_FILENAME);
        // Stamp a monotonic freshness seq INTO the sealed blob: plaintext =
        // seq_le(8) ‖ manager. The seq rides inside the AEAD, so a host can't pair a
        // forged-high seq with stale content — it can only serve an OLD (seq, blob)
        // pair, caught as a rollback at boot. `boot` strips + verifies these 8 bytes.
        let seq = self.manager_seq.fetch_add(1, Ordering::SeqCst) + 1;
        let mut plaintext = Vec::with_capacity(8 + 4096);
        plaintext.extend_from_slice(&seq.to_le_bytes());
        channel_manager
            .write(&mut plaintext)
            .expect("Serialization into an in-memory buffer should never fail");
        let file = self.encrypt_bytes(file_id, &plaintext);
        self.upsert_file(&file.id, file.data.into(), 0)
            .await
            .map_err(|e| anyhow!("persist manager: {e:?}"))?;
        // Commit the manager freshness to the rollback-resistant anchor. Fail-closed
        // like the monitor path (audit F6): a queued-ledger commit fails only if the
        // committer thread died (permanent) — continuing would freeze the on-chain seq
        // while the local seq advances, silently degrading anti-rollback protection.
        if let Err(e) = self
            .anchor
            .commit(crate::freshness::MANAGER_FRESHNESS_KEY, seq)
        {
            error!("Fatal: channel-manager freshness commit failed @{seq}: {e:#} — committer down, shutting down");
            self.shutdown.send();
            anyhow::bail!("channel-manager freshness anchor commit failed @{seq}: {e:#}");
        }
        Ok(())
    }

    async fn persist_channel_monitor<PS: QuidPersister>(
        &self,
        chain_monitor: &ChainMonitorType<PS>,
        channel_id: &LxChannelId,
        monitor_name: &LxMonitorName,
    ) -> anyhow::Result<()> {
        let file = {
            let locked_monitor = chain_monitor
                .get_monitor(ChannelId::from(*channel_id))
                .map_err(|e| anyhow!("No monitor for channel_id: {e:?}"))?;
            let file_id =
                VfsFileId::new(vfs::CHANNEL_MONITORS_DIR, monitor_name.to_string());
            self.encrypt_ldk_writeable(file_id, &*locked_monitor)
        };
        self.upsert_file(&file.id, file.data.into(), 0)
            .await
            .map_err(|e| anyhow!("persist monitor: {e:?}"))?;
        Ok(())
    }

    // --- Payment DB: STUBBED (hop runs no PaymentsManager) --- //

    async fn get_pending_payments(&self) -> anyhow::Result<Vec<PaymentV2>> {
        Ok(Vec::new())
    }

    async fn get_payment_by_id(
        &self,
        _id: PaymentId,
    ) -> anyhow::Result<Option<PaymentV2>> {
        Ok(None)
    }

    async fn get_payment_metadata_by_id(
        &self,
        _id: PaymentId,
    ) -> anyhow::Result<Option<PaymentMetadata>> {
        Ok(None)
    }

    async fn upsert_payment(
        &self,
        _checked: CheckedPayment,
    ) -> anyhow::Result<PersistedPayment> {
        bail!("quid-hop: payment DB unused")
    }

    async fn upsert_payment_batch(
        &self,
        _checked_batch: Vec<CheckedPayment>,
    ) -> anyhow::Result<Vec<PersistedPayment>> {
        bail!("quid-hop: payment DB unused")
    }

    async fn get_updated_payments(
        &self,
        _req: GetUpdatedPayments,
    ) -> anyhow::Result<Vec<DbPaymentV2>> {
        Ok(Vec::new())
    }

    async fn get_updated_payment_metadata(
        &self,
        _req: GetUpdatedPaymentMetadata,
    ) -> anyhow::Result<Vec<DbPaymentMetadata>> {
        Ok(Vec::new())
    }

    async fn get_payments_by_ids(
        &self,
        _ids: Vec<PaymentId>,
    ) -> anyhow::Result<Vec<DbPaymentV2>> {
        Ok(Vec::new())
    }

    async fn get_payment_metadatas_by_ids(
        &self,
        _ids: Vec<PaymentId>,
    ) -> anyhow::Result<Vec<DbPaymentMetadata>> {
        Ok(Vec::new())
    }

    async fn upsert_payments(
        &self,
        _payments: Vec<DbPaymentV2>,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    async fn upsert_payment_metadatas(
        &self,
        _metadatas: Vec<DbPaymentMetadata>,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn encrypt_pwm(
        &self,
        _rng: &mut SysRng,
        _payment: &PaymentV2,
        _metadata: Option<&PaymentMetadata>,
        _created_at: TimestampMs,
        _updated_at: TimestampMs,
    ) -> anyhow::Result<(DbPaymentV2, Option<DbPaymentMetadata>)> {
        bail!("quid-hop: payment DB unused")
    }

    fn decrypt_payment_with_metadata(
        &self,
        _db_payment: DbPaymentV2,
        _db_metadata: Option<DbPaymentMetadata>,
    ) -> anyhow::Result<PaymentWithMetadata> {
        bail!("quid-hop: payment DB unused")
    }

    fn decrypt_metadata(
        &self,
        _db_metadata: DbPaymentMetadata,
    ) -> anyhow::Result<PaymentMetadata> {
        bail!("quid-hop: payment DB unused")
    }

    async fn read_wallet_changeset_legacy(
        &self,
    ) -> anyhow::Result<Option<bdk_wallet::ChangeSet>> {
        Ok(None)
    }
}

impl<F: Ffs + Send + Sync> Persist<SignerType> for HopPersister<F> {
    fn persist_new_channel(
        &self,
        name: MonitorName,
        monitor: &ChannelMonitorType,
    ) -> ChannelMonitorUpdateStatus {
        self.write_monitor(name, monitor)
    }

    fn update_persisted_channel(
        &self,
        name: MonitorName,
        _update: Option<&ChannelMonitorUpdate>,
        monitor: &ChannelMonitorType,
    ) -> ChannelMonitorUpdateStatus {
        self.write_monitor(name, monitor)
    }

    fn archive_persisted_channel(&self, name: MonitorName) {
        // Best-effort: move the monitor blob to the archive dir (LDK suggests
        // archiving rather than deleting, to hedge against data loss).
        let filename = LxMonitorName::from(name).to_string();
        let src = VfsFileId::new(vfs::CHANNEL_MONITORS_DIR, filename.clone());
        let dst = VfsFileId::new(vfs::CHANNEL_MONITORS_ARCHIVE_DIR, filename);
        if let Ok(data) = self.ffs.read(&Self::flat(&src)) {
            // Delete the source ONLY after the archive write succeeds — else a
            // failed archive write + successful delete loses the blob entirely
            // (mirrors quid's read→archive→delete ordering).
            if self.ffs.write(&Self::flat(&dst), &data).is_ok() {
                let _ = self.ffs.delete(&Self::flat(&src));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffs::InMemoryFfs;

    /// Vfs round-trip through the Ffs-backed persister: encrypt some bytes to a
    /// VfsFile, upsert, get it back, decrypt, and confirm list_directory finds
    /// it by dir prefix.
    #[tokio::test]
    async fn vfs_roundtrip_over_ffs() {
        let key = Arc::new(AesMasterKey::new(&[0u8; 32]));
        let p = HopPersister::new(InMemoryFfs::new(), key, NotifyOnce::new(), std::sync::Arc::new(crate::freshness::InMemoryFreshnessAnchor::new()));

        let file_id =
            VfsFileId::new(vfs::SINGLETON_DIRECTORY, vfs::CHANNEL_MANAGER_FILENAME);
        let plaintext = b"hello channel manager";
        let file = p.encrypt_bytes(file_id.clone(), plaintext);
        p.upsert_file(&file.id, file.data.clone().into(), 0)
            .await
            .unwrap();

        let got = p.get_file(&file_id).await.unwrap().expect("present");
        let decrypted = p.decrypt_file(&file_id, got).unwrap();
        assert_eq!(decrypted, plaintext);

        let listing = p
            .list_directory(&VfsDirectory::new(vfs::SINGLETON_DIRECTORY))
            .await
            .unwrap();
        assert!(listing
            .filenames
            .contains(&vfs::CHANNEL_MANAGER_FILENAME.to_string()));
    }

    /// Wallet-changeset restore round-trip: persist a `ChangeSet` and read it
    /// back via the exact `read_json` path `boot()` uses on restart.
    #[tokio::test]
    async fn wallet_changeset_restore_roundtrip() {
        use quid_ln::wallet::ChangeSet;
        let key = Arc::new(AesMasterKey::new(&[0u8; 32]));
        let p = HopPersister::new(InMemoryFfs::new(), key, NotifyOnce::new(), std::sync::Arc::new(crate::freshness::InMemoryFreshnessAnchor::new()));

        let file_id = VfsFileId::new(
            vfs::SINGLETON_DIRECTORY,
            vfs::WALLET_CHANGESET_V2_FILENAME,
        );
        let mut cs = ChangeSet::default();
        cs.network = Some(bitcoin::Network::Regtest);
        p.persist_json(file_id.clone(), &cs, 0).await.unwrap();

        let got = p
            .read_json::<ChangeSet>(&file_id)
            .await
            .unwrap()
            .expect("changeset present");
        assert_eq!(got.network, Some(bitcoin::Network::Regtest));
    }

    /// Fresh node: with nothing persisted, the three restore reads `boot()`
    /// performs (monitors dir, channel manager, wallet changeset) all come back
    /// empty / `None` — i.e. boot falls through to genesis construction.
    #[tokio::test]
    async fn fresh_node_restore_is_empty() {
        use quid_ln::wallet::ChangeSet;
        let key = Arc::new(AesMasterKey::new(&[0u8; 32]));
        let p = HopPersister::new(InMemoryFfs::new(), key, NotifyOnce::new(), std::sync::Arc::new(crate::freshness::InMemoryFreshnessAnchor::new()));

        let monitors = p
            .read_dir_bytes(&VfsDirectory::new(vfs::CHANNEL_MONITORS_DIR))
            .await
            .unwrap();
        assert!(monitors.is_empty());

        let mgr_id = VfsFileId::new(
            vfs::SINGLETON_DIRECTORY,
            vfs::CHANNEL_MANAGER_FILENAME,
        );
        assert!(p.read_bytes(&mgr_id).await.unwrap().is_none());

        let cs_id = VfsFileId::new(
            vfs::SINGLETON_DIRECTORY,
            vfs::WALLET_CHANGESET_V2_FILENAME,
        );
        assert!(p.read_json::<ChangeSet>(&cs_id).await.unwrap().is_none());
    }
}
