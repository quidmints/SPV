//! (B) The fleet **vault node** — the in-process LP-side LDK node, booted ONLY when
//! `QUID_FLEET_COHOSTS_VAULT=true`.
//!
//! 🔴 **READ THIS BEFORE THE OPTION-B DESCRIPTION BELOW: IT IS NO LONGER THE DEFAULT
//! DEPLOYMENT, AND THE PARAGRAPH AFTER IT DESCRIBES A DEPLOYMENT MOST FLEETS DO NOT
//! RUN.** Since §E175 the **LP funding half lives on the LP's own box** — see
//! `LpConsent` below, which is the current statement: *"a fleet that could construct
//! these would, by definition, still hold the LP half."* And since B0 (`99fda5e9`)
//! the fleet is **vault-less by default**. So in the deployment that ships:
//!   • the 2-of-2 is REAL — `drive_open` reads both funding pubkeys out of LDK, and
//!     the counterparty half belongs to the LP's own node, not to this one;
//!   • `lpEth` IS the LP's funding key (`ChannelLib.lpEthOf` = `evmAddressOfCompressed(lpPubkey)`),
//!     so identity and custody are ONE secret the fleet never sees;
//!   • the LP signs the exit **ladder ONCE at open** and may then be offline forever —
//!     `_armLadder`'s *"the LP's ONE-TIME participation buys every exit it will ever
//!     need."* §SPRINT-B4: with the fleet vault-less the heartbeat does not run and
//!     **that ladder is the LP's ONLY escape**, which is why depth is load-bearing.
//! ⇒ **THE LP'S PROTECTION IS THE PRE-SIGNED LADDER PLUS ITS OWN FUNDING HALF — NOT
//!   "enclave key custody", which is what this header used to say and is the exact
//!   assumption §HOP-RCE exists to test.** A reader who takes the old sentence at face
//!   value concludes the fleet is trusted with the LP's BTC. It is not, by default.
//!
//! **The co-hosted (Option B) deployment, which the rest of this module implements:**
//! the retail LP runs NOTHING (a pure EVM identity `lpEth` in the SPA; BTC on
//! Binance/Electrum). The fleet operator runs BOTH the hop node (drives the EVM,
//! accepts channels) AND this second `HopNode` — the "vault" — which holds the
//! LP-side channel keys and INITIATES opens funded by each LP's on-chain BTC
//! deposit. One vault node serves ALL lpEths: N channels to the hop, each credited
//! on-chain to a different `lpEth` (`openChannel(…, lpEth)`) with that LP's
//! `btcRecipientOf` payout pin.
//! ⚠️ **In THAT deployment one custodian holds both halves and the 2-of-2 is NOMINAL** —
//! `quid-bridge-daemon` says so at the opt-in and refuses to imply otherwise.
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
/// ⚠️ **SO THE 2-of-2 IS NOMINAL IN THIS DEPLOYMENT, AND NOTHING SHOULD CLAIM OTHERWISE.**
///
/// 🔑 **THE PARTY THAT MUST HOLD THE OTHER HALF IS THE LP — NOT "a separate operator".** This
/// module's own first line calls the vault *"the in-process **LP-side** LDK node"*, holding
/// *"the LP-side channel keys"*: the half is **already the LP's**, the fleet merely holds it on
/// their behalf. So the fix is to give it to them (§E165/§E171-r/§E188 — a key off the LP's own
/// BIP-39 seed, in their app or on their always-on box), and a third-party custodian would
/// **not** be a weaker version of that. It would be a different thing that misses the point:
/// the threat is *the LP's UTXO spent without the LP*, and two custodians who can jointly spend
/// without them leaves that threat exactly where it was, while adding a collusion assumption
/// §E188 ruled out for the funds path (acceptable for service, never for safety).
///
/// ⇒ It is also why "migration authority on a DIFFERENT Safe" is not a requirement here, despite
/// appearing in older rows: once the LP holds the seed, the fleet's `MigrationAuth` **cannot
/// reach it at all** — it was never in the fleet's enclave. That requirement was an artifact of
/// the separate-operator framing, and it dissolves with it.
///
/// A genuine second half is therefore a **topology** — the LP running [`boot_vault`] with a seed
/// the fleet never has (§E175 remainder) — not a seed setting, which is precisely why it cannot
/// be reached by editing this function.
pub fn derive_vault_seed(hop_seed: &RootSeed) -> RootSeed {
    RootSeed::new(hop_seed.derive(&[VAULT_SEED_LABEL]))
}

/// (§E172, option c) How many HTLCs are MID-FLIGHT across every channel this node holds.
///
/// 🔑 **WHY THIS IS THE SHUTDOWN GATE, AND WHY IT IS THE ONLY ONE AVAILABLE HERE.** The vault is a
/// PASSIVE counterparty: it never initiates a payment and holds N channels to one hop, so it has
/// no forward/do-not-forward decision to gate. It signs whatever the channel protocol asks of it.
/// The moment it DISCONNECTS, no new HTLC can reach it — LDK cannot route to an offline peer — so
/// "stop taking new work" needs no mechanism at all.
///
/// What disconnecting does NOT solve is the HTLCs already committed at that instant. Those must be
/// resolved on-chain if their CLTV expires while the peer is away, which turns a clean departure
/// into a FORCE-CLOSE. So an orderly shutdown is: wait for a window where this count is ZERO, and
/// leave inside it.
pub fn inflight_htlcs(node: &HopNode) -> usize {
    node.channel_manager
        .list_channels()
        .iter()
        .map(|c| c.pending_inbound_htlcs.len() + c.pending_outbound_htlcs.len())
        .sum()
}

/// Poll `inflight` until it reports zero, or `max_wait` elapses. `true` ⇒ safe to disconnect.
///
/// Generic over the counter so the ORDERING — which is the part that can be wrong — is testable
/// without a live LDK node. A version that returned `true` on timeout would be worse than none:
/// it would report a safe departure precisely when the departure is unsafe.
pub async fn await_quiescent<F: Fn() -> usize>(
    inflight: F,
    max_wait: Duration,
    poll: Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + max_wait;
    loop {
        let n = inflight();
        if n == 0 {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            warn!(inflight = n, "quiesce: timed out with HTLCs still in flight");
            return false;
        }
        tokio::time::sleep(poll).await;
    }
}

#[cfg(test)]
mod quiesce_tests {
    use super::await_quiescent;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    /// The success case: it returns as soon as the count reaches zero, not after `max_wait`.
    #[tokio::test]
    async fn returns_true_once_the_last_htlc_clears() {
        let n = AtomicUsize::new(3);
        let started = tokio::time::Instant::now();
        let ok = await_quiescent(
            || {
                // Drain one per observation.
                let cur = n.load(Ordering::SeqCst);
                if cur > 0 {
                    n.store(cur - 1, Ordering::SeqCst);
                }
                cur
            },
            Duration::from_secs(30),
            Duration::from_millis(1),
        )
        .await;
        assert!(ok, "must report quiescent once nothing is in flight");
        assert!(started.elapsed() < Duration::from_secs(5), "must not wait out max_wait on success");
    }

    /// The failure case, and the one that matters: a departure under load must report UNSAFE.
    /// Returning `true` here would tell the operator to leave with HTLCs live, whose resolution
    /// is then a force-close.
    #[tokio::test]
    async fn returns_false_when_traffic_never_stops() {
        let ok = await_quiescent(
            || 1, // never drains
            Duration::from_millis(20),
            Duration::from_millis(1),
        )
        .await;
        assert!(!ok, "a timeout must NOT be reported as safe to disconnect");
    }
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
/// there and relayed: `auth.btc_recipient_pop` is a BIP-340 proof-of-possession over
/// `btcRecipientPoPDigest(lpEth)`, and each `exits` rung is a pre-signed spend of the
/// 2-of-2. A fleet that could construct these would, by definition, still hold the LP half.
#[derive(Clone, Debug, PartialEq)]
pub struct LpConsent {
    pub auth: quid_hop::evm_codec::OpenAuth,
    pub exits: Vec<quid_hop::evm_codec::ExitArming>,
}

/// How many blocks an unfunded onboard stays POLLED. ~1 day: generous for a human who
/// onboards and then goes to fund, and short enough that the poll set reflects recent
/// activity rather than every onboard since boot.
///
/// ⚠️ This bounds WORK, never a user's ability to onboard. Nothing is refused at any count —
/// a cap or a rate limit would refuse a real LP to punish a fake one, which is the shape this
/// deliberately avoids. What it removes is the AMPLIFICATION: one request used to buy
/// unbounded polling; it now buys at most `WATCH_WINDOW_BLOCKS` worth.
pub const WATCH_WINDOW_BLOCKS: u32 = 144;

/// One watched deposit address: the LP's funding intent, plus the height past which the
/// orchestrator stops POLLING it. Expiry never removes the entry — see `by_deposit_addr`.
#[derive(Clone, Debug)]
struct Watch {
    funding: LpFunding,
    /// Poll while `tip <= armed_until`. Re-armed by a repeat `/lp/onboard` for the same lpEth.
    armed_until: u32,
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
    /// `OpenAuth.btc_recipient_pop` is the LP's BIP-340 proof-of-possession, and the ladder
    /// rungs are spends of the 2-of-2 — **both require the LP funding half, which after §E175
    /// the fleet does not have IN THE DEFAULT (LP-HOSTED) TOPOLOGY.** So the fleet RELAYS
    /// consent; it never manufactures it.
    ///
    /// ⚠️ §C2.3② — STATE THE TOPOLOGY, NOT AN ABSOLUTE. "The fleet does not have the LP half"
    /// is true exactly when this process has NO vault node. That is decided at boot by
    /// `QUID_FLEET_COHOSTS_VAULT` (`quid-bridge-daemon`, DEFAULT FALSE) and carried at runtime
    /// as `vault: Option<Arc<VaultNode>>`:
    ///   - `None` (default, LP-hosted): the LP half lives on the LP's own box via
    ///     `quid-lp-daemon`; the fleet cannot produce a PoP or a ladder rung, and
    ///     `run_deadman_exit_heartbeat` disables itself. The sentence above holds.
    ///   - `Some` (opt-in single custodian): `boot_vault` is seeded with
    ///     `derive_vault_seed(&root_seed)` — a function of the SAME enclave seed as the hop —
    ///     so the fleet DOES hold both halves, `presign_deadman_exit` runs, and the boot path
    ///     logs a `warn!` saying the 2-of-2 is nominal. Every `VaultNode` method on this type
    ///     (including [`VaultNode::deliver_swap_out`]) exists only in that mode.
    /// Anything reachable only through a `VaultNode` is therefore co-hosted-mode-only; do not
    /// read this doc as proof that such a path is unreachable.
    ///
    /// ⚠️ The witness is a Schnorr PoP rather than an EVM signature: `lpEth` is DERIVED from
    /// `lpPubkey` on chain (§E183), so there is no EVM signature for the LP to produce.
    ///
    /// ⚠️ Same lifecycle as `by_funding`: only IN-FLIGHT opens AND SPLICES (§E233-ladder — a splice's
    /// rotated outpoint needs its own fresh ladder, and it binds here under the same
    /// `txid:vout` key), dropped once mirrored on-chain, so it cannot grow without bound over
    /// the daemon's lifetime. 🔴 THAT WAS PROSE ONLY UNTIL 2026-08-17 — see `clear_inflight`,
    /// which is now the call that makes this sentence true.
    consent: Mutex<HashMap<String, LpConsent>>,
    /// vault deposit address string → the LP's funding intent + how long to keep POLLING it.
    ///
    /// 🔑 **THE ENTRY IS PERMANENT; THE POLLING IS NOT — and that split is the whole fix.**
    /// Every entry here costs ONE esplora `scripthash_txs` call per orchestrator tick
    /// (`run_vault_open_orchestrator` PHASE A), and before [`Watch::armed_until`] existed an
    /// entry was removed ONLY when its open actually started. So an onboard that was never
    /// funded polled **forever**: one free `/lp/onboard` request bought unbounded work.
    ///
    /// ⚠️ **That was a leak with NO adversary involved** — every LP who abandons onboarding
    /// left a permanent poll — which is why this is a root fix and not an anti-abuse clamp.
    /// The field directly above already states the property this one was missing: *"only
    /// IN-FLIGHT opens … so it cannot grow without bound over the daemon's lifetime."*
    ///
    /// Expiring the WATCH while KEEPING the entry is what makes it safe: `deposit_addr_of`
    /// still returns the same address for an lpEth forever, so a re-onboard re-arms the SAME
    /// address rather than allocating a new one, and a late deposit can never be orphaned on
    /// an address the vault has forgotten.
    by_deposit_addr: Mutex<HashMap<String, Watch>>,
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
/// §AUDIT-SWAPOUT-DOUBLEPAY — a delivery splice was successfully INITIATED but had not LOCKED
/// when the caller's timeout expired. **THIS IS NOT A FAILURE, IT IS AN UNKNOWN**, and the
/// distinction is the whole point of the type: LDK exposes no way to unilaterally abort a splice
/// it is already negotiating, so the sats may still leave to `swapper_script` minutes later.
///
/// ⚠️ A caller that treats this like the pre-initiation error and moves to the next candidate
/// channel DOUBLE-PAYS the swapper — the second channel delivers, then the first one locks.
/// `drive_swap_out_onchain` therefore neither retries nor reverses on this error: a reversal
/// would refund on EVM while the BTC is still in flight, which is the same loss mirrored. The
/// swap halts for resolution instead.
#[derive(Debug)]
pub struct DeliveryInFlight;

impl std::fmt::Display for DeliveryInFlight {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("delivery splice was initiated but did not lock within timeout; it may still \
                     land on-chain, so this channel must not be retried and must not be reversed")
    }
}

impl std::error::Error for DeliveryInFlight {}

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
    /// Register (or RE-ARM) a watched deposit address. `tip` is the current chain height;
    /// polling runs until `tip + WATCH_WINDOW_BLOCKS`. Re-arming an existing address is how a
    /// repeat `/lp/onboard` resumes a watch that lapsed, WITHOUT allocating a new address.
    pub fn register_deposit(&self, deposit_addr: String, f: LpFunding, tip: u32) {
        self.by_deposit_addr.lock().unwrap().insert(
            deposit_addr,
            Watch { funding: f, armed_until: tip.saturating_add(WATCH_WINDOW_BLOCKS) },
        );
    }

    /// Re-arm an address the vault already knows, keeping its stored funding intent.
    /// Returns false if the address is unknown (nothing to re-arm).
    pub fn rearm_deposit(&self, deposit_addr: &str, tip: u32) -> bool {
        let mut m = self.by_deposit_addr.lock().unwrap();
        match m.get_mut(deposit_addr) {
            Some(w) => {
                w.armed_until = tip.saturating_add(WATCH_WINDOW_BLOCKS);
                true
            }
            None => false,
        }
    }

    /// Look up the funding intent for a deposit address (the orchestrator matches a
    /// confirmed UTXO's address to its LP).
    pub fn funding_for_addr(&self, deposit_addr: &str) -> Option<LpFunding> {
        self.by_deposit_addr.lock().unwrap().get(deposit_addr).map(|w| w.funding.clone())
    }

    /// The existing watched deposit address for `lp_eth`, if any (idempotency: one
    /// watch per identity).
    pub fn deposit_addr_of(&self, lp_eth: Address) -> Option<String> {
        self.by_deposit_addr
            .lock()
            .unwrap()
            .iter()
            .find(|(_, w)| w.funding.lp_eth == lp_eth)
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

    /// Drop everything held ONLY for an in-flight open or splice, once it is mirrored on-chain:
    /// the funding→lpEth binding AND the LP's relayed consent. Neither map should ever hold every
    /// channel ever opened (no unbounded memory growth over the daemon's lifetime). `drive_open`
    /// calls this after a successful `openChannel`, `drive_splice` after a successful `splice`.
    ///
    /// 🔴 **`consent` WAS NEVER CLEARED, AND ITS OWN DOC CLAIMED IT WAS.** The field comment on
    /// [`VaultRegistry::consent`] read *"Same lifecycle as `by_funding`: only IN-FLIGHT opens,
    /// dropped once mirrored on-chain, so it cannot grow without bound"* — and the only remover
    /// touched `by_funding`. Every LP consent ever relayed stayed resident for the daemon's life,
    /// each holding a full pre-signed exit tx. Same shape as the `Watch` leak documented above:
    /// **no adversary involved, and invisible because the invariant was asserted in prose rather
    /// than enforced by a call.** Found 2026-08-17 while threading this map into `drive_splice`.
    ///
    /// ⚠️ RENAMED FROM `clear_funding` deliberately — it clears two maps now, and a name that
    /// says "funding" would be the same prose-vs-code drift that hid the leak.
    pub fn clear_inflight(&self, funding_txid_hex: &str, vout: u32) {
        let key = format!("{funding_txid_hex}:{vout}");
        self.by_funding.lock().unwrap().remove(&key);
        if let Ok(mut m) = self.consent.lock() {
            m.remove(&key);
        }
        if let Some(s) = &self.store {
            s.forget_funding_lp(&key);
        }
    }

    /// Snapshot the pending (not-yet-opened) deposit intents for the orchestrator scan.
    /// The addresses the orchestrator should SCAN this tick: those still armed at `tip`.
    ///
    /// Expired entries stay in the map on purpose — `deposit_addr_of` must keep resolving an
    /// lpEth to the SAME address forever, so a late deposit is never stranded on an address
    /// the vault has forgotten. A repeat `/lp/onboard` re-arms it and the deposit is picked up
    /// on the next tick.
    fn pending(&self, tip: u32) -> Vec<(String, LpFunding)> {
        self.by_deposit_addr
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, w)| w.armed_until >= tip)
            .map(|(a, w)| (a.clone(), w.funding.clone()))
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
/// address for it and start watching it.
///
/// THE `delegated` PARAMETER IS GONE (2026-08-15). It gated on the caller having verified
/// `delegationVersion[lpEth] > 0` on-chain, and that selector NO LONGER EXISTS: `e0fed54`
/// folded delegation INTO THE OPEN, so there is no separate registration to read a version
/// from. Its only caller had already been reduced to passing a literal `true`
/// (`swap_in_api.rs`, with the reasoning written out at the site), which made this an
/// `ensure!` that COULD NOT FIRE while still reading as an anti-spam gate — the same shape
/// as the I-3 hot-key check deleted in this pass, and the reason a green suite over it
/// proved nothing.
///
/// THE ANTI-SPAM PROPERTY IS NOT LOST, because it was never enforced here. Post-E157 an LP
/// that has opened is delegated BY CONSTRUCTION: the open itself requires the LP's funds and
/// passes the on-chain `_authorizedHop` gate, so gas is still spent per identity and the
/// watch set still cannot grow for free. That gate is the real one and always was; this was
/// a pre-check that, once delegation moved into the open, had nothing left to discriminate.
pub async fn register_lp(
    registry: &VaultRegistry,
    vault: &HopNode,
    f: LpFunding,
) -> anyhow::Result<bitcoin::Address> {
    // The arming height. One esplora call per onboard, which is the same order as the work
    // the request already does, and it is what bounds the watch this creates.
    let tip = vault
        .esplora
        .client()
        .get_height()
        .await
        .context("chain tip for deposit watch window")?;

    // IDEMPOTENT PER lpEth: one deposit address per identity, FOREVER. If this lpEth is
    // already known, return its existing address and RE-ARM it.
    //
    // 🔑 Re-arming rather than re-allocating is what makes watch expiry safe. An LP who
    // onboards, wanders off past `WATCH_WINDOW_BLOCKS`, then funds anyway has sent coins to
    // an address the vault still owns and still recognises — it merely stopped polling it.
    // One repeat `/lp/onboard` resumes the watch on the SAME address and the next tick picks
    // the deposit up. Handing out a NEW address here would be the bug that version could not
    // recover from: the old address would hold real BTC that nothing was looking for.
    if let Some(existing) = registry.deposit_addr_of(f.lp_eth) {
        registry.rearm_deposit(&existing, tip);
        return Ok(bitcoin::Address::<bitcoin::address::NetworkUnchecked>::from_str(&existing)
            .context("stored deposit address")?
            .assume_checked());
    }
    let addr = vault.wallet.get_address();
    registry.register_deposit(addr.to_string(), f, tip);
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
            // §AUDIT-SWAPOUT-DOUBLEPAY — `cancel` drops the correlator slot so the map cannot
            // leak, but it CANNOT stop the splice: that was handed to LDK above and is still
            // being negotiated. The typed error is what stops the caller retrying into a
            // second channel while this one may yet pay.
            Err(_) => {
                self.deliveries.cancel(&ldk_id.0);
                return Err(anyhow::Error::new(DeliveryInFlight))
                    .context("delivery splice-out never locked within timeout");
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
/// The hop's p2p socket, built from the address the caller actually supplied.
///
/// Trivial on purpose — it exists so the bug below CANNOT come back silently. This address
/// used to be built twice: once from the `hop_addr` parameter and once with
/// `Ipv4Addr::LOCALHOST` hardcoded. The hardcoded copy won both uses that matter (the dial,
/// and the address stored for every later re-dial), so an LP-hosted vault could never reach
/// the fleet while the signature advertised that it could. Reintroducing the constant now
/// fails the test below instead of compiling clean.
pub(crate) fn hop_socket_addr(ip: Ipv4Addr, port: u16) -> LxSocketAddress {
    LxSocketAddress::TcpIpv4 { ip, port }
}

#[cfg(test)]
mod hop_socket_tests {
    use super::{hop_socket_addr, LxSocketAddress};
    use std::net::Ipv4Addr;

    #[test]
    fn a_remote_hop_address_survives_construction() {
        // TEST-NET-3 (RFC 5737) — unroutable, and unmistakably not localhost.
        let remote = Ipv4Addr::new(203, 0, 113, 7);
        match hop_socket_addr(remote, 9735) {
            LxSocketAddress::TcpIpv4 { ip, port } => {
                assert_eq!(
                    ip, remote,
                    "the hop address must be the one supplied: hardcoding LOCALHOST here \
                     pins every vault to the fleet's own machine and silently defeats the \
                     LP-hosted split (M1#2)"
                );
                assert_eq!(port, 9735);
            }
            other => panic!("expected TcpIpv4, got {other:?}"),
        }
    }
}

pub async fn boot_vault(
    network: Network,
    esplora_url: String,
    vault_seed: &RootSeed,
    vault_data_dir: PathBuf,
    hop_node_pk: NodePk,
    // (M1#2) Where the hop listens — NOT hardcoded to localhost any more, which was the last
    // thing pinning the vault to the fleet's own machine. A co-hosted vault passes
    // `Ipv4Addr::LOCALHOST`; an LP running its own passes the fleet's address, and nothing else
    // about the node changes. The split is a TOPOLOGY, so it should cost a parameter.
    hop_addr: Ipv4Addr,
    hop_listen_port: u16,
    splice_feerate: u32,
    store: Arc<crate::store::BridgeStore>,
    anchor: Arc<dyn quid_hop::freshness::FreshnessAnchor + Send + Sync>,
) -> anyhow::Result<VaultNode> {
    // 🔴 ONE CONSTRUCTION, THREE USES — and that is the fix, not a tidy-up. This address was
    // built TWICE: once here from `hop_addr` (correct) and once below with
    // `ip: Ipv4Addr::LOCALHOST` HARDCODED (wrong). The second one won everything that
    // matters — it was the address actually dialled, and it was the one stored on the node,
    // so `ensure_hop_connected` re-dialled localhost forever too. An LP-hosted vault could
    // therefore never reach the fleet: the parameter whose own comment calls it "the split"
    // was accepted and then discarded. It compiled because both sides are `Ipv4Addr`.
    // Building it once makes the divergence UNCONSTRUCTIBLE rather than merely fixed.
    let hop_socket = hop_socket_addr(hop_addr, hop_listen_port);
    // The vault's LSP = the hop it opens channels to.
    let lsp_info = LspInfo {
        node_pk: hop_node_pk,
        private_p2p_addr: hop_socket.clone(),
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
    // Dial the hop at the address we were GIVEN — co-hosted that is localhost, LP-hosted it
    // is the fleet. The connection task lives inside the returned handle;
    // connect_peer_if_necessary is a no-op if already connected.
    let addr = hop_socket;
    if let Err(e) =
        quid_ln::p2p::connect_peer_if_necessary(&node.peer_manager, &hop_node_pk, &[addr.clone()]).await
    {
        warn!("vault could not dial hop yet ({e:#}); the reconnector below will retry");
    }

    // (§A.5g) THE RECONNECTOR. Until now `hop_addr` was STORED "for every later re-dial" and
    // NOTHING RE-DIALLED: LDK's `PeerManager` owns sockets but never re-dials, the boot dial above
    // is one-shot, and a widened grep for a spawned reconnect task found ZERO. So a dropped
    // vault<->hop link failed every channel op until a process restart — a liveness bug that is
    // invisible until the drop, and whose own docblock asserted the capability existed.
    //
    // ⭐ AN INTERVAL LOOP IS THE WHOLE FIX, because `connect_peer_if_necessary` is ALREADY
    //   IDEMPOTENT — the boot call above documents it: "a no-op if already connected". Tracking
    //   connection state here would duplicate what the dialler does and could disagree with it.
    // ⚠️ BACKOFF IS NOT OPTIONAL: a hop that is DOWN would otherwise become a dial storm. It
    //   doubles to a 5-minute ceiling and resets on success, so a brief drop reconnects fast and a
    //   long outage costs one dial per 5 minutes.
    {
        let pm = node.peer_manager.clone();
        let pk = hop_node_pk.clone();
        let a = addr.clone();
        tokio::spawn(async move {
            const MIN: Duration = Duration::from_secs(5);
            const MAX: Duration = Duration::from_secs(300);
            let mut backoff = MIN;
            loop {
                tokio::time::sleep(backoff).await;
                match quid_ln::p2p::connect_peer_if_necessary(&pm, &pk, &[a.clone()]).await {
                    Ok(_) => backoff = MIN,
                    Err(e) => {
                        warn!("vault->hop re-dial failed ({e:#}); retrying in {:?}", backoff);
                        backoff = (backoff * 2).min(MAX);
                    }
                }
            }
        });
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
        for (addr_str, f) in vault.registry.pending(tip) {
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
mod watch_window_tests {
    use super::{LpFunding, PayoutMode, VaultRegistry, WATCH_WINDOW_BLOCKS};
    use alloy_primitives::Address;

    fn funding(byte: u8) -> LpFunding {
        LpFunding {
            lp_eth: Address::repeat_byte(byte),
            btc_recipient: [byte; 32],
            desired_sats: 100_000,
            payout_mode: PayoutMode::Invoice,
        }
    }

    /// The bound itself: an onboard that is never funded stops costing an esplora call per
    /// tick. Before the watch window, `pending` returned it forever, so ONE free request
    /// bought unbounded polling.
    #[test]
    fn an_unfunded_watch_stops_being_polled_after_the_window() {
        let r = VaultRegistry::new();
        r.register_deposit("addr-1".into(), funding(1), 1_000);

        assert_eq!(r.pending(1_000).len(), 1, "armed at the height it was registered");
        assert_eq!(
            r.pending(1_000 + WATCH_WINDOW_BLOCKS).len(),
            1,
            "still armed on the last block of the window (inclusive bound)"
        );
        assert_eq!(
            r.pending(1_000 + WATCH_WINDOW_BLOCKS + 1).len(),
            0,
            "past the window it must no longer be polled — this is the whole point"
        );
    }

    /// 🔑 THE SAFETY PROPERTY, and the reason expiry is not deletion.
    ///
    /// A lapsed watch must still resolve its lpEth to the SAME address. An LP who funds late
    /// has sent real BTC to an address the vault owns; if expiry had removed the entry, the
    /// next `/lp/onboard` would hand out a NEW address and those coins would sit where
    /// nothing is looking. This test fails if anyone "simplifies" expiry into a remove.
    #[test]
    fn an_expired_watch_keeps_its_address_and_can_be_rearmed() {
        let r = VaultRegistry::new();
        let f = funding(2);
        r.register_deposit("addr-2".into(), f.clone(), 1_000);
        let expired_at = 1_000 + WATCH_WINDOW_BLOCKS + 1;
        assert_eq!(r.pending(expired_at).len(), 0, "precondition: the watch has lapsed");

        assert_eq!(
            r.deposit_addr_of(f.lp_eth).as_deref(),
            Some("addr-2"),
            "a lapsed watch must STILL resolve to the same address — otherwise a late \
             deposit is stranded on an address the vault no longer hands out"
        );

        assert!(r.rearm_deposit("addr-2", expired_at), "re-arming a known address succeeds");
        assert_eq!(
            r.pending(expired_at).len(),
            1,
            "re-onboarding resumes the watch on the SAME address, so the late deposit is seen"
        );
        assert!(!r.rearm_deposit("addr-unknown", expired_at), "unknown address cannot be re-armed");
    }

    /// Re-arming must not fork the identity: one lpEth keeps exactly one address.
    #[test]
    fn rearming_never_allocates_a_second_address_for_one_lp() {
        let r = VaultRegistry::new();
        let f = funding(3);
        r.register_deposit("addr-3".into(), f.clone(), 1_000);
        r.rearm_deposit("addr-3", 2_000);
        r.rearm_deposit("addr-3", 3_000);
        assert_eq!(r.pending(3_000).len(), 1, "still exactly one watched address");
        assert_eq!(r.deposit_addr_of(f.lp_eth).as_deref(), Some("addr-3"));
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

    /// ⚠️ The varying field is the **PoP**, because after §E183 that is the only thing in an
    /// `OpenAuth` the LP signs. It used to be `lp_sig`, an ECDSA signature over an EVM digest;
    /// that field is gone precisely because the LP now signs NOTHING on the EVM side — its
    /// address is DERIVED from `lpPubkey` on chain rather than asserted alongside a signature.
    /// So a "conflicting consent" is now a conflicting BIP-340 proof-of-possession, which is
    /// the authorisation that actually exists. Same test, current binding.
    fn a_consent(pop_byte: u8) -> LpConsent {
        LpConsent {
            auth: quid_hop::evm_codec::OpenAuth {
                btc_recipient: [0x11u8; 32],
                btc_recipient_pop: vec![pop_byte; 64],
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
        assert_eq!(r.consent_for_funding("aa", 0).unwrap().auth.btc_recipient_pop, vec![0x22u8; 64],
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
