//! Reusable regtest harness — a real `bitcoind` (auto-downloaded) + Blockstream
//! esplora-electrs (the REST API our `Esplora` client speaks), plus the node
//! boot/connect/sync helpers. Factored out of `tests/e2e.rs` so BOTH that test
//! AND the `e2e_ffi` bin (the forge cross-chain driver) share one definition.
//!
//! Gated behind the `harness` feature (pulls `electrsd`'s bitcoind/electrs
//! download surface + the `test-utils` cuts on quid-ln/quid-common). The e2e
//! test re-exports these via `quid_hop::harness::*` under the same feature; for
//! a plain hop build none of this compiles.

use std::{path::PathBuf, time::Duration};

use electrsd::{
    bitcoind::{self, BitcoinD, P2P},
    Conf as ElectrsConf, ElectrsD,
};
use quid_common::{ln::network::Network, root_seed::RootSeed};

use crate::node::{self, HopNode};

/// A running regtest backend: `bitcoind` + esplora-electrs, plus the esplora
/// REST base URL our nodes connect to.
pub struct Regtest {
    pub bitcoind: BitcoinD,
    pub electrsd: ElectrsD,
    pub esplora_url: String,
}

impl Regtest {
    pub fn start() -> Self {
        // Prefer env-provided binaries (offline runs); fall back to the
        // auto-downloaded paths when the download features are active.
        let bitcoind_exe = std::env::var("BITCOIND_EXE")
            .ok()
            .or_else(|| bitcoind::exe_path().ok())
            .expect("set BITCOIND_EXE or enable bitcoind download");
        let electrs_exe = std::env::var("ELECTRS_EXE")
            .ok()
            .or_else(electrsd::downloaded_exe_path)
            .expect("set ELECTRS_EXE or enable electrs download");

        // esplora-electrs connects to bitcoind over p2p, so enable it.
        let mut bconf = bitcoind::Conf::default();
        bconf.p2p = P2P::Yes;
        let bitcoind = BitcoinD::with_conf(&bitcoind_exe, &bconf)
            .expect("start bitcoind");

        let mut econf = ElectrsConf::default();
        econf.http_enabled = true; // expose the esplora REST endpoint
        let electrsd = ElectrsD::with_conf(&electrs_exe, &bitcoind, &econf)
            .expect("start electrs");

        // electrsd reports e.g. "0.0.0.0:3002"; clients dial 127.0.0.1.
        let raw = electrsd.esplora_url.clone().expect("esplora enabled");
        let esplora_url = format!("http://{}", raw.replace("0.0.0.0", "127.0.0.1"));

        Self { bitcoind, electrsd, esplora_url }
    }

    /// Mine `n` blocks, paying the coinbase to `address` (a string, to dodge
    /// `bitcoin`-crate version coupling between our fork and bitcoind's).
    pub fn mine_to(&self, address: &str, n: u64) {
        self.bitcoind
            .client
            .call::<electrsd::bitcoind::serde_json::Value>(
                "generatetoaddress",
                &[n.into(), address.into()],
            )
            .expect("generatetoaddress");
        self.sync_electrs();
    }

    /// Nudge electrs to index the new tip, then wait until it catches up to
    /// bitcoind's height.
    pub fn sync_electrs(&self) {
        let target = self.tip_height();
        self.electrsd.trigger().expect("trigger electrs");
        for _ in 0..100 {
            if self.electrs_height() >= target {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("electrs did not catch up to height {target}");
    }

    pub fn tip_height(&self) -> u64 {
        self.bitcoind
            .client
            .call::<electrsd::bitcoind::serde_json::Value>("getblockcount", &[])
            .expect("getblockcount")
            .as_u64()
            .unwrap()
    }

    pub fn electrs_height(&self) -> u64 {
        use electrsd::electrum_client::ElectrumApi;
        self.electrsd
            .client
            .block_headers_subscribe()
            .map(|h| h.height as u64)
            .unwrap_or(0)
    }

    /// Mine `n` blocks to a throwaway bitcoind address (confirms broadcast txs).
    pub fn mine(&self, n: u64) {
        let addr = self
            .bitcoind
            .client
            .call::<electrsd::bitcoind::serde_json::Value>("getnewaddress", &[])
            .expect("getnewaddress");
        let addr = addr.as_str().expect("address string");
        self.mine_to(addr, n);
    }

    /// Number of txs in bitcoind's mempool — used to detect a broadcast funding tx.
    pub fn mempool_len(&self) -> usize {
        self.bitcoind
            .client
            .call::<electrsd::bitcoind::serde_json::Value>("getrawmempool", &[])
            .expect("getrawmempool")
            .as_array()
            .map(|a| a.len())
            .unwrap_or(0)
    }
}

/// Spawn a TCP listener for `node` on `127.0.0.1:port` that feeds inbound
/// connections to its peer manager. Returns the accept task (held alive by the
/// caller; the accepted connection tasks are kept inside it).
pub async fn spawn_listener(node: &HopNode, port: u16) -> tokio::task::JoinHandle<()> {
    let pm = node.peer_manager.clone();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .expect("bind p2p listener");
    tokio::spawn(async move {
        let mut conns = Vec::new();
        while let Ok((stream, _addr)) = listener.accept().await {
            conns.push(quid_ln::p2p::spawn_inbound(&pm, stream));
        }
    })
}

/// Dial `to_pk` @ `127.0.0.1:to_port` from `from`. Returns the connection task
/// (held alive by the caller).
pub async fn connect(
    from: &HopNode,
    to_pk: &quid_common::api::user::NodePk,
    to_port: u16,
) -> quid_tokio::task::MaybeLxTask<()> {
    use quid_common::ln::addr::LxSocketAddress;
    let addr = LxSocketAddress::TcpIpv4 {
        ip: std::net::Ipv4Addr::LOCALHOST,
        port: to_port,
    };
    quid_ln::p2p::connect_peer_if_necessary(&from.peer_manager, to_pk, &[addr])
        .await
        .expect("connect peer")
}

/// Force an LDK chain resync and wait for it to finish.
pub async fn ldk_resync(node: &HopNode) {
    let (tx, rx) = tokio::sync::oneshot::channel();
    node.ldk_resync_tx.send(tx).await.expect("send ldk resync");
    rx.await.expect("ldk resync completed");
}

/// Boot a fresh hop node in a unique temp dir, routing through `lsp` (its
/// counterparty). Returns the booted node.
pub async fn boot_node(
    regtest: &Regtest,
    seed: u64,
    role: &str,
    lsp: quid_api::cli::LspInfo,
) -> HopNode {
    let data_dir: PathBuf = std::env::temp_dir()
        .join(format!("quid-hop-e2e-{role}-{seed}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&data_dir);
    let root_seed = RootSeed::from_u64(seed);
    node::boot(
        Network::Regtest,
        regtest.esplora_url.clone(),
        &root_seed,
        data_dir,
        lsp,
        // Regtest harness: host is trusted, so the in-memory anchor is fine.
        std::sync::Arc::new(crate::freshness::InMemoryFreshnessAnchor::new()),
    )
    .await
    .expect("boot hop node")
}

/// RE-boot a node from its EXISTING on-disk state (the restart path), reusing the
/// SAME data dir `boot_node(seed, role)` created — WITHOUT wiping it. This is the
/// crash-restart primitive: the prior node must already be DROPPED (its background
/// tasks + the `DiskFs` handle released) so the `HopPersister`'s synchronous writes
/// have landed and the dir is quiescent. On boot, `node::boot` reloads the
/// persisted channel monitors + channel manager (custody-critical state) and LDK
/// re-emits any still-pending `PaymentClaimable` for HTLCs left unclaimed — the
/// idempotency property under test. Same `(seed, role)` ⇒ same dir ⇒ restore.
pub async fn reboot_node(
    regtest: &Regtest,
    seed: u64,
    role: &str,
    lsp: quid_api::cli::LspInfo,
) -> HopNode {
    // Identical dir derivation to `boot_node`, but NO `remove_dir_all` — restore.
    let data_dir: PathBuf = std::env::temp_dir()
        .join(format!("quid-hop-e2e-{role}-{seed}-{}", std::process::id()));
    let root_seed = RootSeed::from_u64(seed);
    node::boot(
        Network::Regtest,
        regtest.esplora_url.clone(),
        &root_seed,
        data_dir,
        lsp,
        // Regtest harness: host is trusted, so the in-memory anchor is fine.
        std::sync::Arc::new(crate::freshness::InMemoryFreshnessAnchor::new()),
    )
    .await
    .expect("re-boot hop node from disk")
}

/// Force a full BDK wallet resync and wait for it to finish.
pub async fn bdk_full_sync(node: &HopNode) {
    use quid_ln::sync::BdkSyncRequest;
    let (tx, rx) = tokio::sync::oneshot::channel();
    node.bdk_resync_tx
        .send(BdkSyncRequest { full_sync: true, tx })
        .await
        .expect("send bdk resync");
    rx.await.expect("bdk resync completed");
}

/// Build a minimal `LspInfo` pointing at `node_pk` @ `127.0.0.1:port`. The
/// fee/HTLC params are placeholders — they don't affect boot or a single-hop
/// regtest payment.
pub fn lsp_info(node_pk: quid_common::api::user::NodePk, port: u16) -> quid_api::cli::LspInfo {
    use quid_common::{ln::addr::LxSocketAddress, ppm::Ppm};
    quid_api::cli::LspInfo {
        node_pk,
        private_p2p_addr: LxSocketAddress::TcpIpv4 {
            ip: std::net::Ipv4Addr::LOCALHOST,
            port,
        },
        lsp_usernode_base_fee_msat: 0,
        lsp_usernode_prop_fee: Ppm::ZERO,
        lsp_external_prop_fee: Ppm::ZERO,
        lsp_external_base_fee_msat: 0,
        cltv_expiry_delta: 72,
        htlc_minimum_msat: 1,
        htlc_maximum_msat: 21_000_000_0000_0000,
    }
}
