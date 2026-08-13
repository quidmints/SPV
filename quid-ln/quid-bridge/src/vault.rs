//! (B) The fleet **vault node** — the in-process LP-side LDK node.
//!
//! Under Option B the retail LP runs NOTHING (a pure EVM identity `lpEth` in the
//! SPA; BTC on Binance/Electrum). The fleet operator runs BOTH the hop node (drives
//! the EVM, accepts channels) AND this second `HopNode` — the "vault" — which holds
//! the LP-side channel keys and INITIATES opens funded by each LP's on-chain BTC
//! deposit. One vault node serves ALL lpEths: N channels to the hop, each credited
//! on-chain to a different `lpEth` (`openChannel(…, lpEth)`) with that LP's
//! `btcRecipientOf` payout pin. The LP's protection is the on-chain payout pin +
//! enclave key custody — it never runs Lightning.
//!
//! This module reuses the proven primitives verbatim — `quid_hop::node::boot` (the
//! same boot the hop uses), `quid_ln::p2p::{spawn_inbound, connect_peer_if_necessary}`
//! (the same peering the harness uses), BIP32 for the vault seed derivation, and the
//! BDK wallet for deposit-funded `create_channel`. Nothing is hand-rolled.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::str::FromStr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy_primitives::{hex, Address};
use anyhow::Context;
use bitcoin::Txid;
use bitcoin::secp256k1::PublicKey;
use quid_api::cli::LspInfo;
use quid_common::api::user::NodePk;
use quid_common::ln::addr::LxSocketAddress;
use quid_common::ln::network::Network;
use quid_common::ppm::Ppm;
use quid_common::root_seed::RootSeed;
use quid_hop::event_handler::ChannelLifecycleEvent;
use quid_hop::evm_codec::{channel_id, sort_funding_pubkeys, txid_internal};
use quid_hop::node::{boot, initiate_splice_out_to, HopNode};
use tokio::sync::{mpsc, oneshot};
use tracing::{info, warn};

/// Domain-separation label for the fleet-hosted vault's sibling identity.
const VAULT_SEED_LABEL: &[u8] = b"quid-vault-node-v1";

/// The FLEET-HOSTED vault's `RootSeed`, an HKDF sibling of the hop's (`RootSeed::derive` — no
/// hand-rolled KDF).
///
/// 🔑 **(E175-b) THIS IS DELIBERATE, AND THE HONEST CHOICE — read before "hardening" it.** When
/// the fleet co-hosts the vault, the two nodes are **one custodian**: both seeds live in one
/// process's memory and are sealed to the SAME enclave on the SAME machine. An attacker who
/// reaches either reaches both, so an independent vault seed would buy **no security whatever**
/// while costing two things that are real:
///
/// 1. 🔴 **MIGRATION WOULD SILENTLY DESTROY THE VAULT HALF.** `provision_api` carries a
///    **single `root_seed`** to a successor enclave. Any vault seed that is not a function of it
///    is simply absent after a rotation — the successor provisions a *fresh* one, the vault's
///    node id changes, and **every existing channel's vault half becomes unusable.** Enclave
///    rotation is a designed, expected operation, so this is not an edge case.
/// 2. A second secret to back up, whose loss is unrecoverable.
///
/// ⇒ Deriving it says exactly what is true — *one custodian, one secret* — and cannot be
/// mistaken for two. **`VaultSeedSource::{DerivedFromHop, Independent}` was deleted rather than
/// kept as a knob**, because an in-process "independent" seed is a FALSE ASSURANCE: it looks
/// like a second custodian and is not one, which is the shape of thing standing rule 3 exists
/// to remove. There is now no configuration that can misrepresent this.
///
/// ⚠️ **SO THE 2-of-2 IS NOMINAL IN THIS DEPLOYMENT, AND NOTHING SHOULD CLAIM OTHERWISE.** A
/// genuine second half requires a **different party on a different host** calling [`boot_vault`]
/// with a seed the fleet never has — the LP-hosted split (§E175 remainder). That is a topology,
/// not a seed setting, which is precisely why it cannot be reached by editing this function.
pub fn derive_vault_seed(hop_seed: &RootSeed) -> RootSeed {
    RootSeed::new(hop_seed.derive(&[VAULT_SEED_LABEL]))
}

/// Spawn a localhost TCP p2p listener for `node` on `port`, feeding inbound
/// connections to its peer manager (production twin of `harness::spawn_listener`,
/// reusing `quid_ln::p2p::spawn_inbound`). The vault dials the hop, so the HOP runs
/// this listener.
pub async fn spawn_p2p_listener(
    node: &HopNode,
    port: u16,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let pm = node.peer_manager.clone();
    let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port))
        .await
        .with_context(|| format!("bind vault p2p listener on 127.0.0.1:{port}"))?;
    Ok(tokio::spawn(async move {
        let mut conns = Vec::new();
        while let Ok((stream, _addr)) = listener.accept().await {
            conns.push(quid_ln::p2p::spawn_inbound(&pm, stream));
        }
    }))
}

/// Maps a channel FUNDING OUTPOINT (txid:vout) → the `lpEth` that owns the position.
/// Populated by the deposit→open orchestrator when it initiates `create_channel`
/// (it KNOWS lpEth: it derived that LP's deposit address); read by `drive_open`,
/// which no longer recovers lpEth from an lpAuth signature. Also maps a vault-wallet
/// deposit address → lpEth so a confirmed deposit is attributed to its LP.
/// (E166-3) The LP's consent for one open: everything `openChannel` needs that the fleet
/// cannot produce for itself.
///
/// After §E175 the LP funding half lives on the LP's own box, so both fields are made
/// there and relayed: `auth.lp_sig` signs `openAuthDigest`, and each `exits` rung is a
/// pre-signed spend of the 2-of-2. A fleet that could construct these would, by
/// definition, still hold the LP half.
#[derive(Clone, Debug, PartialEq)]
pub struct LpConsent {
    pub auth: quid_hop::evm_codec::OpenAuth,
    pub exits: Vec<quid_hop::evm_codec::ExitArming>,
}

#[derive(Default)]
pub struct VaultRegistry {
    /// `funding_txid_hex:vout` → lpEth (for drive_open).
    by_funding: Mutex<HashMap<String, Address>>,
    /// (E166-3) `funding_txid_hex:vout` → the LP's CONSENT for that open: the `OpenAuth`
    /// and the pre-signed `ExitArming` ladder.
    ///
    /// 🔑 **WHY THIS EXISTS AND WHY THE FLEET CANNOT SYNTHESISE IT.** §E157 deleted
    /// `registerDelegation` precisely so consent rides WITH the open instead of being
    /// pre-granted to the fleet, and §E165 made a pre-signed exit ladder mandatory at open.
    /// `OpenAuth.lp_sig` is the LP's signature over `openAuthDigest`, and the ladder rungs
    /// are spends of the 2-of-2 — **both require the LP funding half, which after §E175 the
    /// fleet does not have.** So the fleet RELAYS consent; it never manufactures it.
    ///
    /// ⚠️ Same lifecycle as `by_funding`: only IN-FLIGHT opens, dropped once mirrored
    /// on-chain, so it cannot grow without bound over the daemon's lifetime.
    consent: Mutex<HashMap<String, LpConsent>>,
    /// vault deposit address string → (lpEth, btcRecipient x-only key, desired sats).
    by_deposit_addr: Mutex<HashMap<String, LpFunding>>,
    /// `user_channel_id → lpEth` for opens in flight (create_channel called, funding
    /// outpoint not yet generated) — bridged to `by_funding` once LDK reveals the txo.
    opening: Mutex<HashMap<u128, Address>>,
    /// Monotonic source of `user_channel_id`s for opens (so each open is
    /// distinguishable in `list_channels` when binding its funding outpoint → lpEth).
    next_uid: std::sync::atomic::AtomicU64,
    /// (B) Durable backing for `by_funding` — write-through so a daemon restart mid-open
    /// re-arms `drive_open` (a lost binding would strand the LP's open until re-deposit).
    /// `None` in the harness (pure in-memory). Reuses the swap-in-registry BridgeStore pattern.
    store: Option<Arc<crate::store::BridgeStore>>,
}

/// How an LP elects to be paid when it exits its position — a *service* preference,
/// not a security boundary: EITHER way the value lands at the LP's on-chain-committed
/// `btcRecipient`, so a fleet that honours the wrong mode never mis-pays, it just
/// delivers in the other shape.
///
/// - [`PayoutMode::Invoice`] (default): the LP realises value THROUGH the pool
///   (redeem QU!D / swap-out to its `btcRecipient`); the fleet keeps the channel's
///   sats as shared liquidity. This is the swap-out/redeem path — already live +
///   regtest-green.
/// - [`PayoutMode::RawBtc`]: the LP takes its channel balance as native BTC on-chain.
///   Realised by [`VaultNode::withdraw_raw_btc`] — a splice-out of the LP's balance
///   straight to `0x5120||btc_recipient` (the B-model counterpart of the self-host
///   [`quid_hop::node::initiate_splice_out`] withdrawal, which derives the same script
///   from the node's own wallet). The EVM attributes it via `_withdrawalPayout`
///   because the output pays `btcRecipientOf`, exactly as the self-host withdrawal does.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PayoutMode {
    #[default]
    Invoice,
    RawBtc,
}

/// The key-path P2TR scriptpubkey for an LP's committed x-only recipient key:
/// `OP_1 (0x51) PUSH32 (0x20) || 32-byte output key` (34 bytes). This is byte-identical
/// to the EVM's `BTCChannels._lpPayoutScript(lpEth) = 0x5120 || btcRecipientOf[lpEth]`,
/// which `_withdrawalPayout` REQUIRES a withdrawal splice pay (else `ForeignSpliceOutput`)
/// and `_lpFinalBalance` attributes a coop-close to — so a splice-out to this script is
/// recognised on-chain as the LP's own withdrawal/close payout.
pub(crate) fn lp_payout_script(recipient_xonly: [u8; 32]) -> Vec<u8> {
    // rust-bitcoin's `new_witness_program` builds OP_1 (0x51) || push-32 (0x20) ||
    // recipient — byte-for-byte the P2TR scriptPubKey we hand-assembled. A 32-byte v1
    // program is always valid, so `new` cannot fail here. Callers wrap the bytes back
    // into a ScriptBuf, so we return the raw 34-byte Vec.
    let program = bitcoin::WitnessProgram::new(bitcoin::WitnessVersion::V1, &recipient_xonly)
        .expect("32-byte v1 witness program is always valid");
    bitcoin::ScriptBuf::new_witness_program(&program).into_bytes()
}

/// One LP's funding intent, recorded at onboarding (SPA: MetaMask signs the
/// delegation on-chain; here we record where it will deposit + how much + its payout).
#[derive(Clone, Debug)]
pub struct LpFunding {
    pub lp_eth: Address,
    /// The LP's committed key-path P2TR payout (x-only) — MUST equal the
    /// `btcRecipientOf` pinned in its on-chain delegation.
    pub btc_recipient: [u8; 32],
    pub desired_sats: u64,
    /// How this LP elects to be paid at exit (see [`PayoutMode`]). Defaults to
    /// [`PayoutMode::Invoice`]; `RawBtc` routes exit through
    /// [`VaultNode::withdraw_raw_btc`].
    pub payout_mode: PayoutMode,
}

/// (B) Correlates a fleet-initiated swap-out delivery splice-out with its LOCK.
/// `deliver_swap_out` initiates a swapper-directed SpliceOut on the vault's channel
/// and registers a oneshot keyed by the LDK channel id; the vault's lifecycle
/// correlator ([`run_vault_delivery_correlator`]) fires it when the matching `Spliced`
/// event arrives (carrying the new splice outpoint). Bounded to IN-FLIGHT deliveries
/// only — `register` inserts, `resolve`/`cancel` remove — so no unbounded growth.
#[derive(Default)]
pub struct DeliveryCoordinator {
    pending: Mutex<HashMap<[u8; 32], oneshot::Sender<(Txid, u32)>>>,
}

impl DeliveryCoordinator {
    /// Register a pending delivery for `ldk_channel_id`; returns the receiver the
    /// caller awaits for the splice lock's new outpoint.
    fn register(&self, ldk_channel_id: [u8; 32]) -> oneshot::Receiver<(Txid, u32)> {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(ldk_channel_id, tx);
        rx
    }

    /// A `Spliced` locked for `ldk_channel_id` — hand its new outpoint to the waiter.
    /// Returns true if a delivery was awaiting it (an ordinary grow/withdrawal splice
    /// returns false — not our delivery).
    fn resolve(&self, ldk_channel_id: &[u8; 32], txid: Txid, vout: u32) -> bool {
        if let Some(tx) = self.pending.lock().unwrap().remove(ldk_channel_id) {
            let _ = tx.send((txid, vout));
            true
        } else {
            false
        }
    }

    /// Drop a pending delivery (timeout / abort) so the map never leaks a stale entry.
    fn cancel(&self, ldk_channel_id: &[u8; 32]) {
        self.pending.lock().unwrap().remove(ldk_channel_id);
    }
}

impl VaultRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// (B) Durable registry (prod): RELOAD the in-flight funding→lpEth bindings from the
    /// store (restart-safe — every open still awaiting `drive_open` is re-armed) and
    /// write-through future binds/clears. The harness uses [`new`] (pure in-memory).
    pub fn new_durable(store: Arc<crate::store::BridgeStore>) -> Arc<Self> {
        let by_funding = store.load_funding_lps();
        info!(inflight = by_funding.len(), "vault registry: reloaded in-flight opens from store");
        Arc::new(Self {
            by_funding: Mutex::new(by_funding),
            consent: Mutex::new(HashMap::new()),
            store: Some(store),
            ..Default::default()
        })
    }

    /// Record an LP's funding intent against the vault deposit address it was given.
    pub fn register_deposit(&self, deposit_addr: String, f: LpFunding) {
        self.by_deposit_addr.lock().unwrap().insert(deposit_addr, f);
    }

    /// Look up the funding intent for a deposit address (the orchestrator matches a
    /// confirmed UTXO's address to its LP).
    pub fn funding_for_addr(&self, deposit_addr: &str) -> Option<LpFunding> {
        self.by_deposit_addr.lock().unwrap().get(deposit_addr).cloned()
    }

    /// The existing watched deposit address for `lp_eth`, if any (idempotency: one
    /// watch per identity).
    pub fn deposit_addr_of(&self, lp_eth: Address) -> Option<String> {
        self.by_deposit_addr
            .lock()
            .unwrap()
            .iter()
            .find(|(_, f)| f.lp_eth == lp_eth)
            .map(|(a, _)| a.clone())
    }

    /// Bind a channel's funding outpoint to its lpEth (at create_channel time). Write-through
    /// to the store (if durable) so a restart mid-open re-arms `drive_open`.
    pub fn bind_funding(&self, funding_txid_hex: &str, vout: u32, lp_eth: Address) {
        let key = format!("{funding_txid_hex}:{vout}");
        self.by_funding.lock().unwrap().insert(key.clone(), lp_eth);
        if let Some(s) = &self.store {
            s.record_funding_lp(key, lp_eth);
        }
    }

    /// Resolve a funding outpoint → lpEth (drive_open). None if not a vault-owned open.
    /// (E166-3) Record the LP's consent for an in-flight open. Idempotent; a CONFLICTING
    /// re-bind is refused rather than overwritten — the consent authorises one specific
    /// open, and letting it move would let a relay swap in a different one.
    pub fn bind_consent(
        &self,
        funding_txid_hex: &str,
        vout: u32,
        consent: LpConsent,
    ) -> bool {
        let key = format!("{funding_txid_hex}:{vout}");
        let mut m = match self.consent.lock() {
            Ok(m) => m,
            Err(_) => return false,
        };
        match m.get(&key) {
            Some(existing) => existing == &consent,
            None => {
                m.insert(key, consent);
                true
            }
        }
    }

    /// (E166-3) The LP's consent for an in-flight open, if it has arrived yet. `None` is
    /// the ORDINARY pre-consent state, not an error: `drive_open` goes dormant and the
    /// reconciler retries, exactly as it already does for a missing lpEth binding.
    pub fn consent_for_funding(&self, funding_txid_hex: &str, vout: u32) -> Option<LpConsent> {
        self.consent
            .lock()
            .ok()
            .and_then(|m| m.get(&format!("{funding_txid_hex}:{vout}")).cloned())
    }

    pub fn lp_for_funding(&self, funding_txid_hex: &str, vout: u32) -> Option<Address> {
        self.by_funding
            .lock()
            .unwrap()
            .get(&format!("{funding_txid_hex}:{vout}"))
            .copied()
    }

    /// Drop a funding→lpEth binding once its open is mirrored on-chain — `by_funding`
    /// only ever holds IN-FLIGHT opens, never every channel ever opened (no unbounded
    /// memory growth over the daemon's lifetime). drive_open calls this after a
    /// successful openChannel.
    pub fn clear_funding(&self, funding_txid_hex: &str, vout: u32) {
        let key = format!("{funding_txid_hex}:{vout}");
        self.by_funding.lock().unwrap().remove(&key);
        if let Some(s) = &self.store {
            s.forget_funding_lp(&key);
        }
    }

    /// Snapshot the pending (not-yet-opened) deposit intents for the orchestrator scan.
    fn pending(&self) -> Vec<(String, LpFunding)> {
        self.by_deposit_addr
            .lock()
            .unwrap()
            .iter()
            .map(|(a, f)| (a.clone(), f.clone()))
            .collect()
    }

    /// Mark a deposit address as consumed (a channel open was initiated for it) so the
    /// orchestrator doesn't re-open on the next pass, and record its `user_channel_id →
    /// lpEth` so the funding-bind pass can pin the outpoint once LDK generates it.
    fn mark_opening(&self, deposit_addr: &str, user_channel_id: u128, lp_eth: Address) {
        self.by_deposit_addr.lock().unwrap().remove(deposit_addr);
        self.opening.lock().unwrap().insert(user_channel_id, lp_eth);
    }

    fn opening_lp(&self, user_channel_id: u128) -> Option<Address> {
        self.opening.lock().unwrap().get(&user_channel_id).copied()
    }
}

/// (B) Onboard an LP as a BTC liquidity provider: allocate a vault-wallet deposit
/// address for it and start watching it. GATED on `delegated` — the caller MUST have
/// verified on-chain that `delegationVersion[lpEth] > 0` (the LP paid gas to register
/// its delegation). This is the anti-spam gate: the fleet only ever watches
/// gas-committed LPs, so "infinite registration" costs gas per identity and can never
/// grow the watch set for free — it's a gas problem for the attacker, NOT an
/// enclave-horsepower problem for us.
pub fn register_lp(
    registry: &VaultRegistry,
    vault: &HopNode,
    delegated: bool,
    f: LpFunding,
) -> anyhow::Result<bitcoin::Address> {
    anyhow::ensure!(
        delegated,
        "register_lp refused: lpEth {} has no on-chain delegation (delegationVersion==0) — \
         the LP must registerDelegation (gas-paid) first",
        f.lp_eth
    );
    // IDEMPOTENT PER lpEth: one watched deposit address per identity. If this lpEth is
    // already being watched, return its existing address — so a single (gas-paid) LP
    // cannot inflate the watch set by re-onboarding. Bounds the watch set to DISTINCT
    // delegated lpEths (each of which cost gas), never per-request.
    if let Some(existing) = registry.deposit_addr_of(f.lp_eth) {
        return Ok(bitcoin::Address::<bitcoin::address::NetworkUnchecked>::from_str(&existing)
            .context("stored deposit address")?
            .assume_checked());
    }
    let addr = vault.wallet.get_address();
    registry.register_deposit(addr.to_string(), f);
    Ok(addr)
}

/// The booted vault node + the hop peer coordinates it dials.
pub struct VaultNode {
    pub node: HopNode,
    pub registry: Arc<VaultRegistry>,
    /// Pending swap-out delivery splice-outs awaiting their lock (see
    /// [`DeliveryCoordinator`]); the swap-out driver awaits, the correlator resolves.
    pub deliveries: Arc<DeliveryCoordinator>,
    /// The hop's LN node key — the counterparty of every vault channel and the
    /// co-signer of every delivery SpliceOut.
    hop_pk: PublicKey,
    /// Funding feerate (sat/kw) for delivery splice-outs.
    splice_feerate: u32,
    /// (§A.5g) The hop's p2p address, kept so the link can be RE-DIALLED after a drop.
    /// LDK's `PeerManager` owns sockets but does NOT re-dial on its own, and the initial
    /// dial below is one-shot — so without this nothing reconnects a dropped vault↔hop
    /// link and every channel op fails until a restart.
    hop_addr: LxSocketAddress,
}

impl VaultNode {
    /// (harness) Wrap an already-booted `HopNode` as a vault — for the delivery e2e,
    /// which reuses the harness's `open_channel` LP-side node as the vault rather than
    /// booting a fresh one. Production always goes through [`boot_vault`].
    #[cfg(feature = "harness")]
    pub fn from_node(node: HopNode, hop_pk: PublicKey, splice_feerate: u32) -> Self {
        Self {
            node,
            registry: VaultRegistry::new(),
            deliveries: Arc::new(DeliveryCoordinator::default()),
            hop_pk,
            splice_feerate,
        }
    }

    /// Map a STABLE on-chain `channelId` back to the vault's LDK channel by recomputing
    /// each monitor's cid from its funding pubkeys + ORIGINAL outpoint (the reconciler's
    /// derivation — identical to the retired responder's `ldk_channel_for`). `None` if no
    /// live vault channel matches.
    fn ldk_channel_for(&self, on_chain_cid: [u8; 32]) -> Option<lightning::ln::types::ChannelId> {
        for ch_id in self.node.chain_monitor.list_monitors() {
            if let Ok(m) = self.node.chain_monitor.get_monitor(ch_id) {
                let orig = m.original_funding_txo();
                if let Some((h, c)) = m.funding_pubkeys() {
                    let (k0, k1) = sort_funding_pubkeys(h.serialize(), c.serialize());
                    let cid = channel_id(&k0, &k1, txid_internal(&orig.txid), orig.index as u32);
                    if cid == on_chain_cid {
                        return Some(ch_id);
                    }
                }
            }
        }
        None
    }

    /// (#114) The STABLE on-chain BTCChannels `channelId` for one of the vault's live
    /// LDK channels — the FORWARD of [`Self::ldk_channel_for`], reusing the identical
    /// derivation (sorted funding pubkeys + ORIGINAL funding outpoint). `None` if the
    /// monitor is missing or its counterparty funding params aren't populated yet. Used
    /// by the dead-man-exit heartbeat to key `emitDeadManExit` + `read_channel_state`.
    pub fn on_chain_cid(&self, ldk_id: &lightning::ln::types::ChannelId) -> Option<[u8; 32]> {
        let m = self.node.chain_monitor.get_monitor(*ldk_id).ok()?;
        let orig = m.original_funding_txo();
        let (h, c) = m.funding_pubkeys()?;
        let (k0, k1) = sort_funding_pubkeys(h.serialize(), c.serialize());
        Some(channel_id(&k0, &k1, txid_internal(&orig.txid), orig.index as u32))
    }

    /// (B) Deliver a swap-out: initiate a swapper-directed SpliceOut on the vault channel
    /// for `on_chain_cid` (the LP's `sats` leave to `swapper_script`, co-signed by the hop
    /// in-process), then AWAIT the lock and return the splice's new outpoint. Replaces the
    /// retired LP-responder round-trip (`begin`/`complete_swap_out_delivery`): the vault
    /// holds the LP-side keys, so it splices directly — no lpAuth, no LN-message transport.
    /// The caller (`drive_swap_out_onchain`) rebuilds params from the returned outpoint,
    /// SPV-confirmation-gates, and submits the (hop-gated) `deliverSwapOutOnchain`.
    pub async fn deliver_swap_out(
        &self,
        on_chain_cid: [u8; 32],
        sats: u64,
        swapper_script: Vec<u8>,
        timeout: Duration,
    ) -> anyhow::Result<(Txid, u32)> {
        let ldk_id = self.ldk_channel_for(on_chain_cid).with_context(|| {
            format!("vault has no live LDK channel for on-chain cid {}", hex::encode(on_chain_cid))
        })?;
        let rx = self.deliveries.register(ldk_id.0);
        let script = bitcoin::ScriptBuf::from_bytes(swapper_script);
        if let Err(e) = initiate_splice_out_to(
            &self.node.channel_manager,
            &ldk_id,
            &self.hop_pk,
            sats,
            script,
            self.splice_feerate,
        ) {
            self.deliveries.cancel(&ldk_id.0);
            return Err(e).context("initiate delivery splice-out");
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(outpoint)) => Ok(outpoint),
            Ok(Err(_)) => anyhow::bail!("delivery splice oneshot dropped (correlator gone?)"),
            Err(_) => {
                self.deliveries.cancel(&ldk_id.0);
                anyhow::bail!("delivery splice-out never locked within timeout")
            }
        }
    }

    /// (B) RAW-BTC exit ([`PayoutMode::RawBtc`]): INITIATE a splice-out of `sats` from the
    /// LP's channel straight to its on-chain-committed `btc_recipient` (a key-path P2TR
    /// output key). Fleet-model counterpart of the self-host
    /// [`quid_hop::node::initiate_splice_out`] withdrawal — that path derives the payout
    /// script from the node's OWN wallet (one node = one LP); here one vault node serves
    /// many LPs, so the recipient is passed explicitly (the caller reads it from the
    /// authoritative on-chain `btcRecipientOf(lpEth)`).
    ///
    /// The output script is `0x5120||btc_recipient` — byte-identical to what the EVM
    /// `_shrinkSplice`→`_withdrawalPayout` REQUIRES (it reverts `ForeignSpliceOutput` unless
    /// the splice pays exactly `0x5120||btcRecipientOf[lpEth]`), so the pin is enforced
    /// on-chain, not merely trusted here.
    ///
    /// Unlike [`Self::deliver_swap_out`] this does NOT await the lock or register a delivery
    /// oneshot: a withdrawal has no synchronous consumer of the new outpoint — the channel
    /// RECONCILER independently detects the resulting SHRINK (`ldk_value != amount_sats`) and
    /// mirrors it onto the EVM via `drive_splice`. So it just fires the splice-out and
    /// returns; the reconciler + the on-chain pin do the rest. No signer /
    /// `commit_upfront_shutdown_pubkey` change (splice-out to an arbitrary script is already
    /// regtest-covered via the delivery path).
    pub fn withdraw_raw_btc(
        &self,
        on_chain_cid: [u8; 32],
        sats: u64,
        btc_recipient: [u8; 32],
    ) -> anyhow::Result<()> {
        let ldk_id = self.ldk_channel_for(on_chain_cid).with_context(|| {
            format!("vault has no live LDK channel for on-chain cid {}", hex::encode(on_chain_cid))
        })?;
        initiate_splice_out_to(
            &self.node.channel_manager,
            &ldk_id,
            &self.hop_pk,
            sats,
            bitcoin::ScriptBuf::from_bytes(lp_payout_script(btc_recipient)),
            self.splice_feerate,
        )
        .context("initiate raw-btc withdrawal splice-out")
    }

    /// Move the vault's channel-lifecycle receiver out (replacing it with a dead one)
    /// so [`run_vault_delivery_correlator`] can own it. The vault's lifecycle stream is
    /// otherwise unconsumed (the HOP mirrors vault opens/closes on the EVM), so this is
    /// its sole consumer. Call ONCE, before the node is shared behind an `Arc`.
    pub fn take_lifecycle_rx(&mut self) -> mpsc::UnboundedReceiver<ChannelLifecycleEvent> {
        let (_dead_tx, dead_rx) = mpsc::unbounded_channel();
        std::mem::replace(&mut self.node.channel_lifecycle_rx, dead_rx)
    }
}

/// (B) The vault's delivery correlator — consumes the vault node's lifecycle stream and,
/// when a swapper-directed delivery SpliceOut LOCKS (`Spliced`), hands its new outpoint
/// to the awaiting [`VaultNode::deliver_swap_out`]. A `Spliced` that isn't a pending
/// delivery (an ordinary grow/withdrawal) is a no-op (`resolve` returns false).
pub async fn run_vault_delivery_correlator(
    mut lifecycle: mpsc::UnboundedReceiver<ChannelLifecycleEvent>,
    deliveries: Arc<DeliveryCoordinator>,
) {
    info!("vault delivery correlator: started");
    while let Some(ev) = lifecycle.recv().await {
        if let ChannelLifecycleEvent::Spliced {
            channel_id,
            new_funding_txid,
            new_funding_vout,
            ..
        } = ev
        {
            if deliveries.resolve(&channel_id, new_funding_txid, new_funding_vout) {
                info!(
                    channel = %hex::encode(channel_id), splice = %new_funding_txid,
                    "vault: delivery splice-out locked"
                );
            }
        }
    }
    warn!("vault delivery correlator: lifecycle stream ended");
}

/// Boot the vault node (2nd in-process `HopNode`) and peer it to the hop.
///
/// Reuses `node::boot` (identical to the hop boot) with `vault_seed` + its own data dir, then
/// dials the hop over localhost (the hop runs `spawn_p2p_listener`). `lsp_info` for the vault =
/// the HOP (its single counterparty).
///
/// 🔑 **`vault_seed` IS A PARAMETER SO THAT PROVENANCE IS THE CALLER'S, NOT THIS FUNCTION'S**
/// (§E175-b). The fleet daemon passes [`derive_vault_seed`] and is thereby one custodian, by
/// construction and in the open. An **LP-hosted** vault — a different party, a different host —
/// passes its OWN seed, and no derivation is involved because the hop's seed is not there to
/// derive from. Both are expressible here; neither can pretend to be the other.
#[allow(clippy::too_many_arguments)]
pub async fn boot_vault(
    network: Network,
    esplora_url: String,
    vault_seed: &RootSeed,
    vault_data_dir: PathBuf,
    hop_node_pk: NodePk,
    hop_listen_port: u16,
    splice_feerate: u32,
    store: Arc<crate::store::BridgeStore>,
    anchor: Arc<dyn quid_hop::freshness::FreshnessAnchor + Send + Sync>,
) -> anyhow::Result<VaultNode> {
    // The vault's LSP = the hop it opens channels to (localhost listener).
    let lsp_info = LspInfo {
        node_pk: hop_node_pk,
        private_p2p_addr: LxSocketAddress::TcpIpv4 {
            ip: Ipv4Addr::LOCALHOST,
            port: hop_listen_port,
        },
        lsp_usernode_base_fee_msat: 0,
        lsp_usernode_prop_fee: Ppm::ZERO,
        lsp_external_prop_fee: Ppm::ZERO,
        lsp_external_base_fee_msat: 0,
        cltv_expiry_delta: 72,
        htlc_minimum_msat: 1,
        htlc_maximum_msat: 21_000_000_0000_0000,
    };
    info!("booting fleet VAULT node (2nd in-process HopNode)");
    let node = boot(network, esplora_url, vault_seed, vault_data_dir, lsp_info, anchor)
        .await
        .context("boot vault node")?;
    // Dial the hop (in-process, localhost). The connection task lives inside the
    // returned handle; connect_peer_if_necessary is a no-op if already connected.
    let addr = LxSocketAddress::TcpIpv4 { ip: Ipv4Addr::LOCALHOST, port: hop_listen_port };
    if let Err(e) =
        quid_ln::p2p::connect_peer_if_necessary(&node.peer_manager, &hop_node_pk, &[addr.clone()]).await
    {
        warn!("vault could not dial hop yet ({e:#}); the reconnect path will retry");
    }
    Ok(VaultNode {
        node,
        registry: VaultRegistry::new_durable(store), // reload in-flight opens; write-through future binds
        deliveries: Arc::new(DeliveryCoordinator::default()),
        hop_pk: hop_node_pk.0,
        splice_feerate,
        hop_addr: addr,
    })
}

impl VaultNode {
    /// (§A.5g) Ensure the vault↔hop p2p link is up, re-dialling if it has dropped.
    ///
    /// `connect_peer_if_necessary` is a NO-OP when already connected, so this is safe to
    /// call on a timer: it costs a cheap peer-table lookup in the common case and only
    /// dials when the link is actually down. Errors are returned rather than logged here
    /// so the caller decides the cadence and the noise level.
    pub async fn ensure_hop_connected(&self) -> anyhow::Result<()> {
        quid_ln::p2p::connect_peer_if_necessary(
            &self.node.peer_manager,
            &quid_common::api::user::NodePk(self.hop_pk),
            &[self.hop_addr.clone()],
        )
        .await
        .map(|_task| ())
        .map_err(|e| anyhow::anyhow!("re-dial hop: {e:#}"))
    }
}

/// (B) The deposit→open orchestrator — the vault node's loop that turns confirmed LP
/// BTC deposits into channel opens. Every `interval`:
///   PHASE A (open): for each watched deposit address with a confirmed UTXO ≥ the LP's
///     desired size, `create_channel(hop, sats)` funded from the vault wallet (the
///     deposit landed there); the deposit address is consumed (one open per LP).
///   PHASE B (bind): once LDK reveals a channel's funding outpoint, record
///     `funding_outpoint → lpEth` so `drive_open` can mirror it on-chain (no lpAuth —
///     the LP runs nothing).
/// Reuses the swap-in esplora scan (`scripthash_txs` + `find_confirmed_deposit`) + LDK
/// `create_channel`/`list_channels`. Nothing hand-rolled.
pub async fn run_vault_open_orchestrator(
    vault: Arc<VaultNode>,
    hop_pk: NodePk,
    min_confs: u32,
    interval_secs: u64,
) {
    let interval = std::time::Duration::from_secs(interval_secs.max(1));
    info!(interval_secs = interval_secs.max(1), "vault open-orchestrator: started");
    // (B) capacity keeping (PHASE C) state, persistent across ticks: the in-flight splice rate-limit set + the
    // rebalance config. The fleet does ALL keeping — the LP-side `run_rebalancer` loop was retired into PHASE C.
    let capacity_active = Arc::new(Mutex::new(std::collections::HashSet::new()));
    let rebalance_cfg = quid_hop::rebalancer::RebalanceConfig::default();
    loop {
        tokio::time::sleep(interval).await;
        let esplora = &vault.node.esplora;
        let tip = match esplora.client().get_height().await {
            Ok(h) => h,
            Err(e) => {
                warn!("vault orchestrator: esplora height failed ({e:#}); retry next pass");
                continue;
            }
        };
        // PHASE A — scan each watched deposit address; open on a confirmed, sized deposit.
        for (addr_str, f) in vault.registry.pending() {
            let addr = match bitcoin::Address::<bitcoin::address::NetworkUnchecked>::from_str(&addr_str) {
                Ok(a) => a.assume_checked(),
                Err(_) => continue,
            };
            let spk = addr.script_pubkey();
            let txs = match esplora.client().scripthash_txs(spk.as_script(), None).await {
                Ok(t) => t,
                Err(_) => continue, // esplora blip → retry next pass
            };
            let mut scan = Vec::new();
            for tx in &txs {
                for (vout, o) in tx.vout.iter().enumerate() {
                    scan.push(crate::swap_in_onchain::ScannedOutput {
                        outpoint: bitcoin::OutPoint { txid: tx.txid, vout: vout as u32 },
                        value: bitcoin::Amount::from_sat(o.value),
                        spk: o.scriptpubkey.clone(),
                        block_height: tx.status.block_height,
                    });
                }
            }
            let Some(dep) =
                crate::swap_in_onchain::find_confirmed_deposit(&scan, spk.as_script(), tip, min_confs)
            else {
                continue;
            };
            if dep.value < bitcoin::Amount::from_sat(f.desired_sats) {
                continue; // wait for the full deposit before opening
            }
            // Fund a channel to the hop from the vault wallet (the deposit is in it now).
            let uid = vault
                .registry
                .next_uid
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed) as u128;
            match vault
                .node
                .channel_manager
                .create_channel(hop_pk.0, f.desired_sats, 0, uid, None, None)
            {
                Ok(_) => {
                    info!(lp_eth = %f.lp_eth, sats = f.desired_sats, uid,
                        "vault: opening channel from LP deposit");
                    vault.registry.mark_opening(&addr_str, uid, f.lp_eth);
                }
                Err(e) => warn!(lp_eth = %f.lp_eth,
                    "vault: create_channel failed ({e:?}); retry next pass"),
            }
        }
        // PHASE B — bind funding outpoints to lpEth once LDK reveals them.
        for ch in vault.node.channel_manager.list_channels() {
            if let (Some(txo), Some(lp)) =
                (ch.funding_txo, vault.registry.opening_lp(ch.user_channel_id))
            {
                vault.registry.bind_funding(&txo.txid.to_string(), txo.index as u32, lp);
                vault.registry.opening.lock().unwrap().remove(&ch.user_channel_id);
                info!(lp_eth = %lp, "vault: bound funding outpoint → lpEth for drive_open");
            }
        }
        // PHASE C — capacity keeping: splice IN each drained fleet channel (below the per-swap ceiling) from a
        // fresh LP top-up deposit in the vault wallet. Reuses the pure `decide_splice` + `initiate_splice` — the
        // retired LP-side `run_rebalancer`, now fleet-side (the LP runs nothing). LDK guards concurrent splices,
        // so a racing delivery splice just fails gracefully and this retries next tick.
        quid_hop::rebalancer::rebalance_capacity_tick(
            &vault.node.channel_manager,
            &vault.node.wallet,
            &vault.node.esplora,
            hop_pk.0,
            &rebalance_cfg,
            &capacity_active,
        )
        .await;
    }
}

#[cfg(test)]
mod tests {
    use super::lp_payout_script;

    // secp256k1 generator x-coordinate — a valid BIP340 x-only key.
    const KEY_HEX: &str = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    #[test]
    fn payout_script_is_key_path_p2tr_matching_evm_pin() {
        let mut key = [0u8; 32];
        key.copy_from_slice(&alloy_primitives::hex::decode(KEY_HEX).unwrap());
        let spk = lp_payout_script(key);
        // Exactly `0x5120 || key` (34 bytes) — what BTCChannels._lpPayoutScript builds and
        // _withdrawalPayout / _lpFinalBalance byte-match against btcRecipientOf.
        assert_eq!(spk.len(), 34, "P2TR spk is 34 bytes");
        assert_eq!(spk[0], 0x51, "OP_1 (segwit v1)");
        assert_eq!(spk[1], 0x20, "PUSH32");
        assert_eq!(&spk[2..], &key, "witness program is the committed output key");
        assert_eq!(alloy_primitives::hex::encode(&spk), format!("5120{KEY_HEX}"));
        // It is a valid Bitcoin scriptpubkey (segwit v1, 32-byte program).
        let script = bitcoin::ScriptBuf::from_bytes(spk);
        assert!(script.is_p2tr(), "recognised as P2TR by rust-bitcoin");
    }
}

#[cfg(test)]
mod e166_consent_tests {
    use super::*;

    fn a_consent(sig_byte: u8) -> LpConsent {
        LpConsent {
            auth: quid_hop::evm_codec::OpenAuth {
                lp_eth: Address::repeat_byte(0xCC),
                btc_recipient: [0x11u8; 32],
                lp_sig: vec![sig_byte; 65],
                btc_recipient_pop: vec![0x33u8; 64],
            },
            exits: vec![quid_hop::evm_codec::ExitArming {
                cltv_deadline: 800_000,
                checkpoint_sats: 1_000_000,
                signed_exit_tx: vec![0xAAu8; 4],
                ..Default::default()
            }],
        }
    }

    /// ⚠️ **ABSENT CONSENT IS THE ORDINARY STATE, NOT AN ERROR.** `drive_open` used to
    /// `bail!` here, which turned "the LP has not signed yet" into a loud failure on every
    /// reconciler tick. A lookup returning `None` is what makes the open go DORMANT and be
    /// retried, exactly as the missing-lpEth binding already does.
    #[test]
    fn consent_is_absent_until_the_lp_provides_it() {
        let r = VaultRegistry::new();
        assert!(r.consent_for_funding("aa", 0).is_none(),
                "no consent yet must read as absent, not as a failure");
    }

    /// The consent authorises ONE specific open. Letting a re-bind overwrite it would let
    /// whatever relays it swap in a different `OpenAuth` or a different exit ladder — and
    /// after §E175 the relay is exactly the party that must not be able to.
    #[test]
    fn consent_is_idempotent_but_never_rebindable() {
        let r = VaultRegistry::new();
        assert!(r.bind_consent("aa", 0, a_consent(0x22)), "first bind");
        assert!(r.bind_consent("aa", 0, a_consent(0x22)), "identical re-bind is a no-op");
        assert!(!r.bind_consent("aa", 0, a_consent(0x99)),
                "a CONFLICTING consent must be refused, not swapped in");
        assert_eq!(r.consent_for_funding("aa", 0).unwrap().auth.lp_sig, vec![0x22u8; 65],
                   "the original consent survives");
    }

    /// Consent is keyed per funding outpoint: one LP's consent must never satisfy another
    /// open. (Same key shape as `by_funding`, so the two cannot drift apart.)
    #[test]
    fn consent_does_not_leak_across_funding_outpoints() {
        let r = VaultRegistry::new();
        assert!(r.bind_consent("aa", 0, a_consent(0x22)));
        assert!(r.consent_for_funding("aa", 1).is_none(), "a different vout is a different open");
        assert!(r.consent_for_funding("bb", 0).is_none(), "a different txid is a different open");
    }
}
