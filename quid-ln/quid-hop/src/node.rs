//! Hop LDK node boot.
//!
//! Reuses the **full quid-ln (quid) stack** — its node graph is type-welded to
//! `QuidRouter` via `alias.rs`, and `QuidRouter` fits a hop (single channel to
//! the LP → route everything via that one peer, with the LP as the `LspInfo`).
//! So we mirror quid `node/run.rs` (the fresh-node path), backed by our M1
//! `HopPersister`, dropping the SGX/gdrive/HBA/migration/API extras.
//!
//! The node is **concrete on `DiskFs`** (like quid's node crate fixes its
//! persister) — keeps the LDK type aliases readable. The regtest test uses a
//! temp dir. Boot needs a live esplora, so it's exercised by the regtest
//! harness, not a unit test.

use std::{
    io::Cursor,
    path::PathBuf,
    sync::Arc,
};

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context};
use tokio::sync::{mpsc, oneshot};

use alloy_primitives::{Address, U256};
use bitcoin::{
    hashes::{sha256, Hash as _},
    BlockHash,
};
use lightning::{
    chain::{chainmonitor::ChainMonitor, BestBlock},
    ln::{
        channelmanager::{
            ChainParameters, ChannelManager, ChannelManagerReadArgs, MIN_CLTV_EXPIRY_DELTA,
        },
        peer_handler::IgnoringMessageHandler,
    },
    routing::{
        gossip::{NetworkGraph, RoutingFees},
        router::{RouteHint, RouteHintHop},
        scoring::{ProbabilisticScorer, ProbabilisticScoringDecayParameters},
    },
    sign::{NodeSigner, Recipient},
    util::{
        config::{MaxDustHTLCExposure, UserConfig},
        ser::ReadableArgs,
    },
};
use lightning::types::payment::{PaymentHash, PaymentPreimage};
use lightning_invoice::{Bolt11Invoice, Currency, InvoiceBuilder};

use lightning::events::bump_transaction::sync::{
    BumpTransactionEventHandlerSync, WalletSync,
};

use quid_api::{
    cli::LspInfo,
    vfs::{self, Vfs, VfsDirectory, VfsFileId},
};
use quid_common::{
    api::user::NodePk,
    constants::{
        CHANNEL_MAX_FUNDING_SATS, FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS,
        LSP_RESERVE_PROPORTION,
    },
    ln::network::Network,
    root_seed::RootSeed,
};
use quid_crypto::rng::SysRng;

use quid_ln::{
    alias::{
        BroadcasterType, ChannelMonitorType, EsploraSyncClientType,
        ChainMonitorType, ChannelManagerType, OnionMessengerType,
        PeerManagerType, NetworkGraphType, ProbabilisticScorerType,
    },
    background_processor,
    esplora::Esplora,
    keys_manager::QuidKeysManager,
    logger::TracingLogger,
    message_router::QuidMessageRouter,
    route::QuidRouter,
    sync::{self, BdkSyncRequest},
    test_event,
    tx_broadcaster::TxBroadcaster,
    wallet::{self, ChangeSet, CoinSelector, OnchainWallet},
};
use quid_async_util::{
    events_bus::EventsBus, notify, notify_once::NotifyOnce, task::LxTask,
};

use crate::{
    bump::HopWalletSource,
    event_handler::{
        encode_swap_in_metadata, ChannelLifecycleEvent, EventCtx, HopEventHandler, SwapInMsg,
    },
    ffs::DiskFs,
    peer::HopPeerManager,
    persister::HopPersister,
};

/// Final-CLTV delta for swap-in invoices — well above LDK's 18-block
/// `MIN_FINAL_CLTV_EXPIRY_DELTA` floor so a fresh inbound HTLC carries enough
/// Bitcoin-block budget for the cross-chain settle-then-claim (EVM settle + the
/// HTLC-success confirmation + margin). Paired with the event handler's
/// `SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS` gate (H-2); the floor was the prior bug.
///
/// COUPLED with [`crate::event_handler::SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS`]: this
/// delta MUST exceed that headroom (a fresh HTLC must be able to pass the settle
/// gate with slack). The relationship is enforced at compile time by a
/// `const _: () = assert!(…)` next to the headroom const — do not edit one without
/// the other; the build breaks if they cross.
pub const SWAP_IN_FINAL_CLTV_DELTA: u16 = 144; // ~24h at 10-min blocks

/// Anti balance-jamming cap: the percent of the channel the counterparty may hold
/// IN-FLIGHT toward the hop (the hop's inbound). Committed at open in
/// [`boot`]'s `max_inbound_htlc_value_in_flight_percent_of_channel`. This ALSO
/// bounds a single swap-in to ≤ this percent of the channel, which is exactly the
/// per-swap ceiling the rebalancer must restore — so both sites read THIS const
/// (single source of truth). Changing it here changes the boot config AND the
/// rebalancer's ceiling math together; they can no longer silently diverge.
pub const HOP_MAX_INBOUND_IN_FLIGHT_PCT: u8 = 50;

// --- Concrete node type aliases (persister fixed to DiskFs) --- //
pub type HopPst = Arc<HopPersister<DiskFs>>;
pub type HopChainMonitor = ChainMonitorType<HopPst>;
pub type HopChannelManager = ChannelManagerType<HopPst>;
pub type HopOnionMessenger = OnionMessengerType<Arc<HopChannelManager>>;
pub type HopPeerManagerType = PeerManagerType<
    Arc<HopChannelManager>,
    IgnoringMessageHandler,
    HopPst,
    IgnoringMessageHandler,
>;

/// The channel's two 2-of-2 funding pubkeys (serialized, unsorted), looked up by
/// funding outpoint: maps outpoint → `ChannelId` via the channel list, then reads
/// the monitor's `funding_pubkeys()` (the QU!D LDK accessor —
/// `lib/rust-lightning/QUID_PATCHES.md`). `None` if there's no such channel /
/// monitor, or the counterparty params aren't populated yet. Used to build
/// `BTCChannels.OpenParams` at open time (the funding P2WSH hides the keys).
pub fn channel_funding_pubkeys(
    chain_monitor: &HopChainMonitor,
    channel_manager: &HopChannelManager,
    funding_txid: bitcoin::Txid,
    funding_vout: u32,
) -> Option<([u8; 33], [u8; 33])> {
    let outpoint = lightning::chain::transaction::OutPoint {
        txid: funding_txid,
        index: funding_vout as u16,
    };
    let channel_id = channel_manager
        .list_channels()
        .into_iter()
        .find(|c| c.funding_txo == Some(outpoint))
        .map(|c| c.channel_id)?;
    let monitor = chain_monitor.get_monitor(channel_id).ok()?;
    let (holder, counterparty) = monitor.funding_pubkeys()?;
    Some((holder.serialize(), counterparty.serialize()))
}

/// The channel's ORIGINAL 2-of-2 funding pubkeys — the pair it was OPENED with, which is what
/// `BTCChannels` hashes into `channelId` (`ChannelLib.sol:617`). Companion to
/// [`channel_funding_pubkeys`], which returns the monitor's CURRENT pair.
///
/// ⚠️ USE THIS WHEREVER THE VALUE FEEDS AN IDENTITY, AND THE OTHER ONE WHEREVER IT FEEDS A SPEND.
/// A splice rotates both halves (`new_funding_pubkey(prev_funding_txid)`), so the two diverge the
/// moment a channel is spliced: `deliverSwapOutOnchain`/`splice` need the CURRENT pair, because
/// that is what the on-chain output commits to; `channelId` needs the ORIGINAL one.
///
/// Looks the channel up by its LIVE funding outpoint, exactly as [`channel_funding_pubkeys`] does
/// — post-splice that is the splice outpoint — then reads the original pair off the monitor.
pub fn original_channel_funding_pubkeys(
    chain_monitor: &HopChainMonitor,
    channel_manager: &HopChannelManager,
    funding_txid: bitcoin::Txid,
    funding_vout: u32,
) -> Option<([u8; 33], [u8; 33])> {
    let outpoint = lightning::chain::transaction::OutPoint {
        txid: funding_txid,
        index: funding_vout as u16,
    };
    let channel_id = channel_manager
        .list_channels()
        .into_iter()
        .find(|c| c.funding_txo == Some(outpoint))
        .map(|c| c.channel_id)?;
    let monitor = chain_monitor.get_monitor(channel_id).ok()?;
    let (holder, counterparty) = monitor.original_funding_pubkeys()?;
    Some((holder.serialize(), counterparty.serialize()))
}

/// Derive a channel's STABLE on-chain `channelId` from its SEALED monitor ALONE —
/// the freshness anchor key. Every input comes from the AES-sealed `ChannelMonitor`
/// (never the host-writable `BridgeStore.onchain_cid` map), so a host cannot repoint
/// a monitor at another channel's — or a nonexistent — freshness counter to force a
/// stale reload past `verify()` (audit F3). Uses the ORIGINAL funding outpoint AND the
/// ORIGINAL funding pubkeys, sorted into the same open/close order the contract hashes
/// — identical to the reconciler's derivation. `None` before the counterparty funding
/// params are populated (pre-funding: no revoked state to protect yet).
///
/// ⛔ (§SPLICE-ROTATES-BOTH-FUNDING-KEYS, 2026-08-31) THIS USED TO READ `funding_pubkeys()`
/// WHILE CORRECTLY READING `original_funding_txo()`, AND THE DOCBLOCK SAID WHY THE OUTPOINT
/// NEEDED THE "ORIGINAL" ACCESSOR WITHOUT NOTICING THE PAIR NEEDS IT FOR THE SAME REASON.
/// **A splice rotates BOTH**: `send_splice_init` and the `splice_ack` handler each call
/// `ChannelSigner::new_funding_pubkey(prev_funding_txid)`, and `funding_pubkeys()` reads the
/// CURRENT scope. So this function — documented as deriving a STABLE id — returned a
/// DIFFERENT id after every splice lock. Three consumers were affected: the EVM `channelId`
/// (definitively wrong, since `ChannelLib.sol:617` binds it to the ORIGINAL pair), the
/// freshness / anti-rollback anchor key (`node.rs`'s `verify` call and `persister.rs`'s
/// write, whose key silently migrated at splice lock), and the restatements in
/// `liveness.rs` / `freshness_ledger.rs`.
/// ⛔ **DO NOT "SIMPLIFY" THIS BACK TO `funding_pubkeys()`.** The id must NOT follow the
/// channel's live scope — that is the whole reason `original_funding_txo` exists.
pub fn onchain_cid_from_monitor(monitor: &ChannelMonitorType) -> Option<[u8; 32]> {
    let orig = monitor.original_funding_txo();
    let (holder, counterparty) = monitor.original_funding_pubkeys()?;
    let (k0, k1) =
        crate::evm_codec::sort_funding_pubkeys(holder.serialize(), counterparty.serialize());
    Some(crate::evm_codec::channel_id(
        &k0,
        &k1,
        crate::evm_codec::txid_internal(&orig.txid),
        orig.index as u32,
    ))
}

/// LP-initiated COOPERATIVE close of the LP's channel(s) to `counterparty` (the hop).
/// The LP's node sends `shutdown`; the hop co-signs; once the close tx confirms the
/// hop's reconciler records it on the EVM via `recordClose`, settling the LP's BTC
/// (in the close tx) + its proportional swap proceeds as QUI. This is the LP's exit:
/// LP-initiated, not hop/reconciler-decided. Returns how many channels were closed.
/// (Cooperative requires the hop online — if it's down the LP simply waits/retries;
/// funds aren't trapped, the position + channel persist until coop-close settles it.)
pub fn close_channels_to(
    channel_manager: &HopChannelManager,
    counterparty: &bitcoin::secp256k1::PublicKey,
) -> anyhow::Result<usize> {
    let mut n = 0usize;
    for c in channel_manager.list_channels() {
        if c.counterparty.node_id != *counterparty {
            continue;
        }
        channel_manager
            .close_channel(&c.channel_id, counterparty)
            .map_err(|e| anyhow::anyhow!("close_channel({:?}): {e:?}", c.channel_id))?;
        n += 1;
    }
    Ok(n)
}

/// The counterparty's (LP's) committed upfront shutdown script for the channel
/// at `funding_txid:funding_vout`, via the QU!D `ChannelDetails` accessor
/// (`lib/rust-lightning/QUID_PATCHES.md`). This is the exact output the LP's
/// balance is paid to at a COOPERATIVE close — LDK rejects any `Shutdown` that
/// differs from the committed script. The open driver checks it equals
/// `P2WPKH(lp_funding_pubkey)` (what `BTCChannels._lpFinalBalance` attributes
/// balance to) before driving the hop-gated `openChannel`. `None` if there's no
/// such channel or the LP made no upfront commitment.
pub fn channel_counterparty_shutdown_script(
    channel_manager: &HopChannelManager,
    funding_txid: bitcoin::Txid,
    funding_vout: u32,
) -> Option<bitcoin::ScriptBuf> {
    let outpoint = lightning::chain::transaction::OutPoint {
        txid: funding_txid,
        index: funding_vout as u16,
    };
    channel_manager
        .list_channels()
        .into_iter()
        .find(|c| c.funding_txo == Some(outpoint))
        .and_then(|c| c.counterparty_shutdown_scriptpubkey)
}
/// LP-side: initiate a SPLICE-IN to grow channel `ldk_channel_id` by `grow_sats`,
/// contributing the sats from this wallet's confirmed P2WPKH UTXOs. Because the
/// vendored LDK splicing ACCEPTOR cannot contribute inputs, the party whose BTC
/// funds the grow (the LP, self-custody) MUST initiate — the hop accepts. LDK
/// negotiates the splice; both sides co-sign via
/// `Event::FundingTransactionReadyForSigning` (handled in the hop event handler),
/// and on lock the new (larger) funding outpoint surfaces via `Event::SplicePending`
/// for the EVM `splice` drive. Selection is greedy largest-first over a
/// `grow + fee-buffer` target; LDK computes the exact fee + returns change.
pub async fn initiate_splice(
    channel_manager: &HopChannelManager,
    wallet: &OnchainWallet,
    esplora: &Esplora,
    ldk_channel_id: &lightning::ln::types::ChannelId,
    counterparty: &bitcoin::secp256k1::PublicKey,
    grow_sats: u64,
    funding_feerate_per_kw: u32,
) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use lightning::ln::funding::{FundingTxInput, SpliceContribution};

    // `spendable_utxos` (NOT `get_utxos`): this path selects its own fee inputs, so it
    // bypasses the `default_tx_builder` exclusion entirely. Using the unfiltered set here
    // would let a splice consume the dead-man FRESHNESS outpoint as a fee input and
    // silently invalidate every emitted exit (#114) — no error, no log, just a lost
    // backstop for every LP.
    let mut utxos: Vec<_> = wallet
        .spendable_utxos()
        .into_iter()
        .filter(|u| u.chain_position.is_confirmed())
        .collect();
    // Most-confirmed (oldest) first: prefers MATURE UTXOs, so a coinbase-funded
    // wallet (e.g. regtest) never contributes an immature coinbase — Bitcoin's
    // 100-block coinbase maturity rule rejects the splice tx as
    // "premature-spend-of-coinbase" otherwise. Production LPs use ordinary UTXOs.
    utxos.sort_by_key(|u| {
        u.chain_position
            .confirmation_height_upper_bound()
            .unwrap_or(u32::MAX)
    });

    // Generous fee buffer (excess returns as change); LDK enforces the real fee.
    let target = grow_sats.saturating_add(20_000);
    let mut inputs = Vec::new();
    let mut total: u64 = 0;
    for u in utxos {
        if total >= target {
            break;
        }
        // P2WPKH only (matches the wallet's BIP-84 keychain + list_confirmed_utxos).
        let spk = u.txout.script_pubkey.as_bytes();
        if !(spk.len() == 22 && spk[0] == 0x00 && spk[1] == 0x14) {
            continue;
        }
        let prevtx = esplora
            .client()
            .get_tx(&u.outpoint.txid)
            .await
            .with_context(|| format!("get_tx({}) for splice input", u.outpoint.txid))?
            .with_context(|| format!("splice input prevtx {} not found", u.outpoint.txid))?;
        // Wallet UTXOs are key-path P2TR (BIP86 tr descriptor) — contribute them via LDK's
        // proven taproot key-spend funding input (no hand-rolled witness).
        let input = FundingTxInput::new_p2tr_key_spend(prevtx, u.outpoint.vout)
            .map_err(|()| anyhow::anyhow!("splice input {} not P2TR", u.outpoint))?;
        inputs.push(input);
        total = total.saturating_add(u.txout.value.to_sat());
    }
    anyhow::ensure!(
        total >= target,
        "insufficient confirmed funds for splice-in: have {total} sat, need ~{target} sat"
    );

    let contribution = SpliceContribution::SpliceIn {
        value: bitcoin::Amount::from_sat(grow_sats),
        inputs,
        change_script: Some(wallet.get_internal_address().script_pubkey()),
    };
    channel_manager
        .splice_channel(ldk_channel_id, counterparty, contribution, funding_feerate_per_kw, None)
        .map_err(|e| anyhow::anyhow!("splice_channel: {e:?}"))?;
    Ok(())
}

// The self-host keysend_to_lp (hop→LP LN-balance move for fee-into-channel) was
// REMOVED: under Option B the LP runs no LN node (the fleet vault holds the LP-side), so
// there is no LP peer to keysend to. BTC-leg fees compound via the hop-funded fee-splice +
// `feeSettleSats` on-chain clear (drive_splice / maybe_flush_btc_fees) which grows LP.pooled
// directly — no LN-balance leg. See project-quid-fee-into-close-design.

/// LP-side: initiate a SPLICE-OUT (partial withdrawal) shrinking channel
/// `ldk_channel_id` by `withdraw_sats`, paying that BTC to the LP's OWN committed
/// payout script — `P2WPKH(lp_funding_pubkey)`, exactly what
/// `BTCChannels._lpFinalBalance` credits as the LP's payout (the same script
/// `btcRecipientOf` was committed to at open). The channel stays OPEN at the
/// reduced funding. Like splice-in, the LP initiates (the vendored LDK acceptor
/// contributes nothing); the hop accepts + co-signs, and on lock the new (smaller)
/// funding outpoint surfaces via `Event::SplicePending` → the EVM `splice` drive,
/// which reads this payout output from the splice tx to split native vs delivered.
/// Unlike splice-in there are no inputs to contribute (the removed value comes from
/// the channel balance), so this needs no wallet/esplora and is synchronous. The
/// splice miner fee is borne by the LP (removed value = `withdraw_sats` + fee);
/// the EVM treats that fee like a close fee — `delivered = shrink − payout`,
/// clamped — so it can never over-mint.
pub fn initiate_splice_out(
    keys_manager: &QuidKeysManager,
    channel_manager: &HopChannelManager,
    ldk_channel_id: &lightning::ln::types::ChannelId,
    counterparty: &bitcoin::secp256k1::PublicKey,
    withdraw_sats: u64,
    funding_feerate_per_kw: u32,
) -> anyhow::Result<()> {
    // The withdrawal payout MUST be the LP's committed upfront-shutdown script
    // (`get_shutdown_scriptpubkey` — the stable external-0 key), because that is exactly
    // what the EVM records as `btcRecipientOf` and what `_withdrawalPayout` attributes the
    // withdrawal to. Deriving from the FUNDING pubkey (as this used to) pays a DIFFERENT
    // key → the on-chain guard rejects it as `ForeignSpliceOutput`. This is the same
    // funding-vs-shutdown bug the cooperative-close path was fixed for, missed here.
    // Cross-side coverage: VBtcLevFeeLane::test_Seam_WithdrawalPayout_MustMatchShutdownKey.
    use lightning::sign::SignerProvider;
    let payout_script = keys_manager
        .get_shutdown_scriptpubkey()
        .map_err(|()| anyhow!("LP shutdown scriptpubkey unavailable"))?
        .into_inner();
    initiate_splice_out_to(
        channel_manager, ldk_channel_id, counterparty, withdraw_sats, payout_script,
        funding_feerate_per_kw,
    )
}

/// LP-side: initiate a SPLICE-OUT removing `amount_sats` from the channel to an
/// ARBITRARY `dest_script`. The withdrawal path ([`initiate_splice_out`]) passes the
/// LP's OWN P2WPKH; the ON-CHAIN swap-out DELIVERY passes the SWAPPER's script — the
/// LP delivers its channel BTC straight to the swapper's Bitcoin address and earns
/// its EXACT proceeds (QUI = the swapper's recorded USD) when the hop settles
/// `deliverSwapOutOnchain`. As
/// with splice-in / withdrawal, the LP INITIATES (the vendored LDK acceptor
/// contributes 0, so the party whose channel balance leaves must drive it); the hop
/// accepts + co-signs, and the new (smaller) funding outpoint surfaces via
/// `Event::SplicePending`. No inputs to contribute (the value comes from the channel
/// balance), so this is synchronous — no wallet/esplora needed.
pub fn initiate_splice_out_to(
    channel_manager: &HopChannelManager,
    ldk_channel_id: &lightning::ln::types::ChannelId,
    counterparty: &bitcoin::secp256k1::PublicKey,
    amount_sats: u64,
    dest_script: bitcoin::ScriptBuf,
    funding_feerate_per_kw: u32,
) -> anyhow::Result<()> {
    use lightning::ln::funding::SpliceContribution;
    let contribution = SpliceContribution::SpliceOut {
        outputs: vec![bitcoin::TxOut {
            value: bitcoin::Amount::from_sat(amount_sats),
            script_pubkey: dest_script,
        }],
    };
    channel_manager
        .splice_channel(ldk_channel_id, counterparty, contribution, funding_feerate_per_kw, None)
        .map_err(|e| anyhow::anyhow!("splice_channel (out): {e:?}"))?;
    Ok(())
}

pub type HopBumpHandler = BumpTransactionEventHandlerSync<
    BroadcasterType,
    Arc<WalletSync<Arc<HopWalletSource>, TracingLogger>>,
    Arc<QuidKeysManager>,
    TracingLogger,
>;

/// A booted hop node: the core LDK graph + the background tasks that keep it
/// alive (esplora connection, tx broadcaster, p2p process-events). Dropping
/// this shuts the node down via `shutdown`.
pub struct HopNode {
    pub keys_manager: Arc<QuidKeysManager>,
    pub channel_manager: Arc<HopChannelManager>,
    pub chain_monitor: Arc<HopChainMonitor>,
    pub onion_messenger: Arc<HopOnionMessenger>,
    pub peer_manager: HopPeerManager,
    pub network_graph: Arc<NetworkGraphType>,
    pub esplora: Arc<Esplora>,
    /// On-chain BDK wallet — funds channel opens, receives swap-out payouts.
    pub wallet: OnchainWallet,
    /// BIP32 master — retained so the bridge daemon can derive per-swap on-chain
    /// swap-in deposit keys (`m/70'/idx'`, see `swap_in_onchain`) for the key-path claim.
    pub master_xprv: bitcoin::bip32::Xpriv,
    /// The LDK on-chain tx broadcaster (funding/splice/close). (No longer also
    /// backs an LP-fee payer — that off-chain settler was retired.)
    pub tx_broadcaster: TxBroadcaster,
    pub persister: HopPst,
    pub shutdown: NotifyOnce,
    /// Settled swap-ins, for the caller's EVM-sender task to drive `settleSwapIn`.
    pub swap_in_rx: mpsc::UnboundedReceiver<SwapInMsg>,
    /// BTC-channel lifecycle transitions (funding ready / closed), for the
    /// bridge's channel driver to mirror on the EVM (`openChannel` / close).
    pub channel_lifecycle_rx: mpsc::UnboundedReceiver<ChannelLifecycleEvent>,
    /// Bitcoin network — used to set the invoice currency in `issue_swap_in_invoice`.
    pub bitcoin_network: bitcoin::Network,
    /// On-chain receive notifications from the BDK sync task (held open).
    pub onchain_recv_rx: notify::Receiver,
    /// Trigger an on-demand BDK resync (held open to keep the sync task alive).
    pub bdk_resync_tx: mpsc::Sender<BdkSyncRequest>,
    /// Trigger an on-demand LDK resync (held open to keep the sync task alive).
    pub ldk_resync_tx: mpsc::Sender<oneshot::Sender<()>>,
    _tasks: Vec<LxTask<()>>,
}

/// Settle-then-claim handle for the EVM-sender bridge. Wraps only the
/// channel-manager `Arc`, so it's cheap to clone and lets the bridge drive the
/// claim/fail without depending on LDK types (`PaymentPreimage`/`PaymentHash`).
/// See [`ClaimedSwapIn`](crate::event_handler::ClaimedSwapIn) for the contract
/// this implements (steps 2 and 3).
#[derive(Clone)]
pub struct SwapInClaimer {
    cm: Arc<HopChannelManager>,
}

impl SwapInClaimer {
    /// Step 2 (settle succeeded): take the seller's BTC.
    pub fn claim(&self, preimage: [u8; 32]) {
        self.cm.claim_funds(PaymentPreimage(preimage));
    }
    /// Step 3 (undeliverable): fail the inbound HTLC so the seller reclaims it.
    pub fn fail(&self, payment_hash: [u8; 32]) {
        self.cm.fail_htlc_backwards(&PaymentHash(payment_hash));
    }
}

impl HopNode {
    /// The node's Lightning node id.
    pub fn node_pk(&self) -> NodePk {
        self.keys_manager.node_pk()
    }

    /// A `Clone`-able handle the EVM-sender bridge holds to drive the
    /// settle-then-claim claim/fail. Grab it BEFORE moving `swap_in_rx` out of the
    /// node (it only clones the channel-manager `Arc`, so the node stays usable).
    pub fn swap_in_claimer(&self) -> SwapInClaimer {
        SwapInClaimer { cm: self.channel_manager.clone() }
    }

    // lp_fee_payer / OnchainLpFeePayer REMOVED with the settler — BTC-leg fees now
    // compound in-channel; no off-chain native payout to construct.

    /// Issue a BOLT11 swap-in invoice for `amount_sats`, binding `(seller, token)`
    /// into the invoice's `payment_metadata`. The payer echoes that field (BOLT11
    /// `m`), so it returns to us in `PaymentClaimed.onion_fields` — which LDK
    /// persists with the claimable HTLC. The hop therefore keeps NO per-invoice
    /// state: no map, no bespoke persistence, and the binding survives restarts
    /// for free. The seller does nothing extra — a normal invoice payment.
    ///
    /// Built from public APIs (`create_inbound_payment`, `list_usable_channels`,
    /// `NodeSigner::sign_invoice`) rather than `create_bolt11_invoice`, which does
    /// not expose `payment_metadata`.
    pub fn issue_swap_in_invoice(
        &self,
        seller: Address,
        token: Address,
        amount_sats: u64,
        min_delivered_usd: U256,
        description: &str,
    ) -> anyhow::Result<Bolt11Invoice> {
        self.invoicer().issue(seller, token, amount_sats, min_delivered_usd, description)
    }

    /// A cheaply-cloneable handle that issues swap-in invoices, for a prod request
    /// ingrid (i.e. ingress, bridge's swap-in HTTP API) to hold without the whole node.
    pub fn invoicer(&self) -> SwapInInvoicer {
        self.invoicer_gated(None)
    }

    /// (§LP-LIVENESS) The invoicer with the routing gate attached: channels whose LP has not posted
    /// a recent heartbeat are dropped from the route hints, so no NEW swapper is sent down one.
    ///
    /// ⚠️ Separate from [`Self::invoicer`] rather than replacing it, because the gate FAILS CLOSED:
    /// handing it to a deployment that is not yet collecting heartbeats would refuse every channel
    /// and issue invoices with no hints at all. Pass `Some` once the phone posts them.
    pub fn invoicer_gated(
        &self,
        gate: Option<Arc<crate::liveness::RoutingGate>>,
    ) -> SwapInInvoicer {
        SwapInInvoicer {
            cm: self.channel_manager.clone(),
            keys_manager: self.keys_manager.clone(),
            bitcoin_network: self.bitcoin_network,
            gate,
        }
    }
}

/// Swap-in invoice issuer — the `issue_swap_in_invoice` logic behind a
/// `Clone`-able handle (holds only the Arcs it needs), so a request
/// server can issue invoices without owning the `HopNode`.
#[derive(Clone)]
pub struct SwapInInvoicer {
    cm: Arc<HopChannelManager>,
    keys_manager: Arc<QuidKeysManager>,
    bitcoin_network: bitcoin::Network,
    /// (§LP-LIVENESS) The routing gate. `None` disables the filter entirely, which is the honest
    /// default for a deployment that has not started collecting heartbeats — a gate with no data
    /// would refuse every channel, since it fails closed.
    gate: Option<Arc<crate::liveness::RoutingGate>>,
}

impl SwapInInvoicer {
    /// Issue a BOLT11 swap-in invoice for `amount_sats`, binding
    /// `(seller, token, min_delivered_usd)` into `payment_metadata`. See
    /// [`HopNode::issue_swap_in_invoice`] for the durability rationale.
    pub fn issue(
        &self,
        seller: Address,
        token: Address,
        amount_sats: u64,
        min_delivered_usd: U256,
        description: &str,
    ) -> anyhow::Result<Bolt11Invoice> {
        let amount_msat = amount_sats.saturating_mul(1000);
        let expiry_secs: u32 = 3600;
        let (payment_hash, payment_secret) = self
            .cm
            .create_inbound_payment(Some(amount_msat), expiry_secs, None)
            .map_err(|()| anyhow!("create_inbound_payment rejected the amount"))?;

        // Route hints so the payer can reach us over unannounced channels — the
        // public-API equivalent of the crate-private `sort_and_filter_channels`
        // that `create_bolt11_invoice` uses internally.
        let route_hints: Vec<RouteHint> = self
            .cm
            .list_usable_channels()
            .into_iter()
            // (§LP-LIVENESS) THE ROUTING GATE. A channel whose LP has not posted a recent heartbeat
            // is left OUT of the hints, so the payer is never given a path to it and no new swap
            // starts down a channel whose LP cannot complete the co-signs it needs. That is the DoS
            // this prevents, and it is also what makes per-splice ladder re-arming (§E233-ladder)
            // OPT-IN for a phone: sign more, get routed more; go quiet, and only NEW routing stops
            // — existing positions, the armed ladder and the refund paths are untouched.
            .filter(|ch| {
                self.gate
                    .as_ref()
                    .is_none_or(|g| g.is_routable_ldk(&ch.channel_id.0))
            })
            .filter_map(|ch| {
                let scid = ch.get_inbound_payment_scid()?;
                let fwd = ch.counterparty.forwarding_info?;
                Some(RouteHint(vec![RouteHintHop {
                    src_node_id: ch.counterparty.node_id,
                    short_channel_id: scid,
                    fees: RoutingFees {
                        base_msat: fwd.fee_base_msat,
                        proportional_millionths: fwd.fee_proportional_millionths,
                    },
                    cltv_expiry_delta: fwd.cltv_expiry_delta,
                    htlc_minimum_msat: ch.inbound_htlc_minimum_msat,
                    htlc_maximum_msat: ch.inbound_htlc_maximum_msat,
                }]))
            })
            .collect();

        let duration_since_epoch =
            SystemTime::now().duration_since(UNIX_EPOCH).context("clock before epoch")?;

        let mut builder = InvoiceBuilder::new(Currency::from(self.bitcoin_network))
            .description(description.to_owned())
            .duration_since_epoch(duration_since_epoch)
            .payee_pub_key(self.cm.get_our_node_id())
            .payment_hash(sha256::Hash::from_slice(&payment_hash.0).unwrap())
            .payment_secret(payment_secret)
            .payment_metadata(encode_swap_in_metadata(seller, token, min_delivered_usd))
            .basic_mpp()
            .min_final_cltv_expiry_delta(SWAP_IN_FINAL_CLTV_DELTA.into())
            .expiry_time(Duration::from_secs(expiry_secs.into()))
            .amount_milli_satoshis(amount_msat);
        for hint in route_hints {
            builder = builder.private_route(hint);
        }

        let raw = builder.build_raw().map_err(|e| anyhow!("build invoice: {e:?}"))?;
        let signature = self.keys_manager.sign_invoice(&raw, Recipient::Node);
        raw.sign(|_| signature)
            .map(|signed| Bolt11Invoice::from_signed(signed).unwrap())
            .map_err(|e| anyhow!("sign invoice: {e:?}"))
    }
}

/// The hop ↔ LP channel posture — the SINGLE source of truth for the
/// channel-handshake config, handshake limits, and per-channel config. BOTH the
/// hop and the LP daemon boot through [`boot`], so this one config governs both
/// ends of every QU!D channel (there is no per-side divergence).
///
/// Config mirrors quid's custody-safety params (the audit flagged that LDK
/// defaults leave `their_to_self_delay` unbounded + funding capped pre-wumbo).
/// Differs from quid only in enabling anchors (quid defers them) — for CPFP
/// fee-bumping (replacement-cycling / flood-and-loot defense), which also requires
/// manually accepting inbound channels (handled in the event handler).
///
/// `to_self_delay` posture — SYMMETRIC, deliberately (NOT quid's user↔LSP
/// asymmetry). quid sets `our_to_self_delay` (justice window we impose on the
/// peer) to 7d but caps `their_to_self_delay` (lock we tolerate on our own funds)
/// at 4d — i.e. the user takes the favorable end of both knobs and the custodial
/// LSP eats the worse end of both. Our hop↔LP is a liquidity *partnership* with no
/// trust hierarchy, so we make both knobs equal (7d): each side demands, and
/// accepts, the same justice window. Consequences: (a) two QU!D nodes can open in
/// either direction (no self-incompatibility); (b) neither side silently eats
/// worse terms; (c) the only cost is a 7d lock on our own to_local output on a
/// *force* close (rare; cooperative closes have no CSV).
///
/// SIMPLE-TAPROOT (`negotiate_simple_taproot = true`) opts every QU!D channel into
/// BOLT #995 key-path MuSig2 taproot channels: P2TR (`0x5120||Q`) funding +
/// 64-byte Schnorr key-path cooperative/force closes. Anchors stay ON
/// (simple-taproot inherits the zero-fee-HTLC anchor commitment format).
pub fn build_user_config() -> UserConfig {
    let mut config = UserConfig::default();
    {
        let h = &mut config.channel_handshake_config;
        h.minimum_depth = 3;
        h.our_to_self_delay = 6 * 24 * 7; // 7d justice window we impose on the peer
        // Anti dust-slot-jamming floor. With this at 1 msat a jammer could fill all
        // `our_max_accepted_htlcs` slots with ~free dust HTLCs; raising it forces
        // every slot-occupying HTLC to lock real value. Floor it by SWAP ECONOMICS:
        // a swap costs EVM gas, and nobody swaps an amount the gas would dwarf — the
        // smallest economically-sensible swap is well above the per-swap gas cost,
        // so 1_000 sats (~$1) sits far below any real swap (rejecting none) while
        // making a 50-slot jam cost ≥50_000 sats of locked capital. Also keeps HTLCs
        // above the channel dust limit (enforceable). The LP must run a matching
        // config (see the equal-or-compatible note above). Raise it for a stronger
        // anti-jam floor if min-swap economics rise.
        h.our_htlc_minimum_msat = 1_000_000; // 1,000 sats
        h.our_max_accepted_htlcs = 50;
        // Anti balance-jamming: cap the value the counterparty can hold IN-FLIGHT
        // toward us (our inbound) at 50% of the channel, so held/unsettled HTLCs
        // can tie up at most half our inbound and the rest stays open for real
        // swap-ins. Was 100% (a full-channel jam); LDK's default is 10% (too tight
        // for a swap hop). TRADEOFF: this also bounds a SINGLE swap-in to ≤50% of
        // the channel — size channels accordingly, or raise this if larger single
        // swaps are needed. The LP needs no matching change (this is our local
        // inbound-acceptance policy).
        h.max_inbound_htlc_value_in_flight_percent_of_channel = HOP_MAX_INBOUND_IN_FLIGHT_PCT;
        h.negotiate_anchors_zero_fee_htlc_tx = true; // HOP: anchors ON
        // SIMPLE-TAPROOT (BOLT #995): opt every QU!D channel into key-path MuSig2
        // taproot channels (P2TR `0x5120||Q` funding, 64-byte Schnorr key-path
        // closes). Both ends run this config, so the channel-type negotiation
        // converges on simple-taproot; the proven LDK taproot tx-builder/signer +
        // the QU!D EVM/Bitcoin binding (funded_output_taproot, witness-free close
        // recovery) carry it through.
        h.negotiate_simple_taproot = true; // HOP+LP: simple-taproot-channels ON
        // PIN the cooperative-close payout script at OPEN. With this set, our
        // shutdown script (the stable external-0 P2WPKH — see
        // `keys_manager::get_shutdown_scriptpubkey`) is committed in
        // open/accept_channel and LDK rejects any deviating `Shutdown` at close.
        // The peer (LP) must run the same so ITS payout is likewise pinned —
        // that's what lets the open driver verify the LP coop-close output will
        // match `P2WPKH(btcRecipientOf)` (correct `_lpFinalBalance` attribution).
        h.commit_upfront_shutdown_pubkey = true;
        h.their_channel_reserve_proportional_millionths =
            LSP_RESERVE_PROPORTION.to_u32();
        let l = &mut config.channel_handshake_limits;
        // Symmetric: accept exactly the justice window we ourselves demand (7d),
        // so a peer running our own config can open. Still BOUNDS the CSV (LDK
        // default is unbounded) — we reject a counterparty asking for more.
        l.their_to_self_delay = 6 * 24 * 7;
        l.max_funding_satoshis = CHANNEL_MAX_FUNDING_SATS as u64;
        l.trust_own_funding_0conf = true;
        l.max_minimum_depth = 144;
        let c = &mut config.channel_config;
        // FALSE: the hop is the RECIPIENT of swap-in payments. Accepting
        // underpaying HTLCs would let the forwarding LP skim sats off the seller's
        // payment (surfaced as `counterparty_skimmed_fee_msat`) while LDK still
        // fires PaymentClaimable for the reduced amount — the hop has no LSP-fee
        // intercept flow that would need this, so it stays off.
        c.accept_underpaying_htlcs = false;
        c.cltv_expiry_delta = MIN_CLTV_EXPIRY_DELTA;
        c.max_dust_htlc_exposure =
            MaxDustHTLCExposure::FixedLimitMsat(100_000_000);
        c.force_close_avoidance_max_fee_satoshis =
            FORCE_CLOSE_AVOIDANCE_MAX_FEE_SATS;
    }
    config.accept_inbound_channels = true;
    config.manually_accept_inbound_channels = true;
    // Accept INBOUND splices: the BTC-LP grows its position by splicing-in to its
    // channel, and (vendored LDK) only the INITIATOR can contribute inputs — so the
    // LP, whose own sats fund the grow (self-custody), must initiate, and the hop
    // (acceptor) must accept the inbound splice. LDK gates this OFF by default
    // (`reject_inbound_splices: true`); the acceptor-side handling is implemented
    // (it contributes 0 + ACKs), so enabling it is all that's needed. See
    // `BTCChannels.splice` + `drive_splice`.
    config.reject_inbound_splices = false;
    config
}

/// Boot a fresh hop node against `esplora_url`, routing through `lsp_info` (the
/// hop's LP counterparty). `data_dir` backs the `DiskFs` persister.
pub async fn boot(
    network: Network,
    esplora_url: String,
    root_seed: &RootSeed,
    data_dir: PathBuf,
    lsp_info: LspInfo,
    // Anti-rollback freshness anchor (crate::freshness): the caller injects the on-chain
    // ledger-backed anchor for staging/prod, or `InMemoryFreshnessAnchor` for dev/regtest
    // (host trusted). The commit side rides `HopPersister::write_monitor`; the verify side
    // is the boot loop below (fail-closed on a stale monitor).
    anchor: Arc<dyn crate::freshness::FreshnessAnchor + Send + Sync>,
) -> anyhow::Result<HopNode> {
    let logger = TracingLogger::new();
    let shutdown = NotifyOnce::new();
    let (test_event_tx, _test_event_rx) = test_event::channel("(hop)");
    let mut tasks: Vec<LxTask<()>> = Vec::new();
    // The single LP counterparty id — captured before `lsp_info` is moved into the
    // routers, so the event handler can gate inbound channel acceptance on it.
    let lsp_node_pk = lsp_info.node_pk; // NodePk: Copy

    // Persister (M1) over a flat-file store.
    let ffs = DiskFs::create_dir_all(data_dir).context("Could not open data dir")?;
    let vfs_master_key = Arc::new(root_seed.derive_vfs_master_key());
    let persister: HopPst = Arc::new(HopPersister::new(
        ffs,
        vfs_master_key,
        shutdown.clone(),
        anchor.clone(),
    ));

    // Esplora connection pool + fee estimates.
    let (esplora, fee_estimates, esplora_task) =
        Esplora::init("quid-hop", esplora_url, shutdown.clone())
            .await
            .context("Could not init esplora")?;
    tasks.push(esplora_task);

    // LDK chain-sync client (per-node, not shared).
    let ldk_sync_client = Arc::new(EsploraSyncClientType::from_client(
        esplora.client().clone(),
        logger.clone(),
    ));

    // BDK on-chain wallet. On restart we reload the persisted changeset (the
    // wallet's UTXO/address state) — a fresh node finds nothing (`None`) and
    // re-derives it via `full_sync`.
    let (wallet_persister_tx, wallet_persister_rx) = notify::channel();
    let master_xprv = root_seed.derive_bip32_master_xprv(network);
    let maybe_changeset = persister
        .read_json::<ChangeSet>(&VfsFileId::new(
            vfs::SINGLETON_DIRECTORY,
            vfs::WALLET_CHANGESET_V2_FILENAME,
        ))
        .await
        .context("Could not read wallet changeset")?;
    let wallet = OnchainWallet::init(
        master_xprv.clone(),
        network,
        &esplora,
        fee_estimates.clone(),
        CoinSelector::default(),
        maybe_changeset,
        wallet_persister_tx,
    )
    .await
    .context("Could not init wallet")?;
    // Persist the BDK changeset on wallet updates (else restart loses wallet state).
    tasks.push(wallet::spawn_wallet_persister_task(
        persister.clone(),
        wallet.clone(),
        wallet_persister_rx,
        shutdown.clone(),
    ));

    // Keys manager (node id derives from here).
    let mut rng = SysRng::new();
    let keys_manager = Arc::new(
        QuidKeysManager::new(&mut rng, root_seed, wallet.clone())
            .context("Could not init keys manager")?,
    );

    // Tx broadcaster.
    let (tx_broadcaster, broadcaster_task) = TxBroadcaster::start(
        esplora.clone(),
        wallet.clone(),
        None,
        test_event_tx.clone(),
        shutdown.clone(),
    );
    tasks.push(broadcaster_task);

    // Chain monitor (backed by the M1 HopPersister).
    let chain_monitor = Arc::new(ChainMonitor::new(
        Some(ldk_sync_client.clone()),
        tx_broadcaster.clone(),
        logger.clone(),
        fee_estimates.clone(),
        persister.clone(),
        keys_manager.clone(),
        keys_manager.get_peer_storage_key(),
    ));

    // Network graph + scorer (fresh).
    let network_graph =
        Arc::new(NetworkGraph::new(network.to_bitcoin(), logger.clone()));
    let scorer: Arc<std::sync::Mutex<ProbabilisticScorerType>> =
        Arc::new(std::sync::Mutex::new(ProbabilisticScorer::new(
            ProbabilisticScoringDecayParameters::default(),
            network_graph.clone(),
            logger.clone(),
        )));

    // Restore-on-boot: read persisted channel monitors (custody-critical — they
    // let the chain monitor watch for / penalize fraudulent closes). A fresh
    // node finds none. Mirrors quid `NodePersister::{fetch,deserialize}` over
    // the M1 `HopPersister`.
    let monitor_bytes = persister
        .read_dir_bytes(&VfsDirectory::new(vfs::CHANNEL_MONITORS_DIR))
        .await
        .context("Could not fetch channel monitor bytes")?;
    let monitor_read_args = (keys_manager.as_ref(), keys_manager.as_ref());
    let mut channel_monitors: Vec<(BlockHash, ChannelMonitorType)> =
        Vec::with_capacity(monitor_bytes.len());
    for (file_id, bytes) in &monitor_bytes {
        let mut reader = Cursor::new(bytes);
        let monitor =
            <(BlockHash, ChannelMonitorType)>::read(&mut reader, monitor_read_args)
                .map_err(|e| {
                    anyhow::anyhow!(
                        "ChannelMonitor deser failed for {}: {e:?}",
                        file_id.filename
                    )
                })?;
        // Anti-rollback: refuse a monitor the host served that is BEHIND the
        // freshness anchor — that is a rollback to stale channel state, which
        // re-opens the nonce-reuse / lost-preimage / revoked-state hazards. Fail
        // closed rather than sign against rolled-back state. Keyed on the STABLE
        // on-chain channelId DERIVED from this monitor (audit F3) — the SAME key
        // the persister commits + the on-chain counter uses. A pre-funding monitor
        // (no funding pubkeys yet) was never committed, so there's nothing to
        // verify against — skip it (no revoked state exists to roll back to).
        let update_id = monitor.1.get_latest_update_id();
        if let Some(oc) = onchain_cid_from_monitor(&monitor.1) {
            let monitor_key = crate::freshness::hex32(&oc);
            if let crate::freshness::Freshness::Stale { loaded, anchored } =
                crate::freshness::verify(anchor.as_ref(), &monitor_key, update_id)?
            {
                anyhow::bail!(
                    "anti-rollback: channel monitor {} is STALE (loaded update_id \
                     {loaded} < anchored {anchored}) — the host served rolled-back \
                     channel state; refusing to boot",
                    file_id.filename,
                );
            }
        }
        channel_monitors.push(monitor);
    }

    // Router (route through the LP) + message router.
    let router = Arc::new(QuidRouter::new_user_node(
        network_graph.clone(),
        logger.clone(),
        scorer.clone(),
        lsp_info.clone(),
        Vec::new(), // no intercept scids
    ));
    let message_router = Arc::new(QuidMessageRouter::new_user_node(
        network_graph.clone(),
        lsp_info,
    ));

    // Channel manager (fresh node: genesis best block). Config mirrors quid's
    // custody-safety params (the audit flagged that LDK defaults leave
    // `their_to_self_delay` unbounded + funding capped pre-wumbo). Differs from
    // quid only in enabling anchors (quid defers them) — for CPFP fee-bumping
    // (replacement-cycling / flood-and-loot defense), which also requires
    // manually accepting inbound channels (handled in the event handler).
    //
    // `to_self_delay` posture — SYMMETRIC, deliberately (NOT quid's user↔LSP
    // asymmetry). quid sets `our_to_self_delay` (justice window we impose on the
    // peer) to 7d but caps `their_to_self_delay` (lock we tolerate on our own
    // funds) at 4d — i.e. the user takes the favorable end of both knobs and the
    // custodial LSP eats the worse end of both. Our hop↔LP is a liquidity
    // *partnership* with no trust hierarchy, so we make both knobs equal (7d):
    // each side demands, and accepts, the same justice window. Consequences:
    // (a) two QU!D nodes can open in either direction (no self-incompatibility);
    // (b) neither side silently eats worse terms; (c) the only cost is a 7d lock
    // on our own to_local output on a *force* close (rare; cooperative closes
    // have no CSV) — we keep the conservative window rather than weaken security
    // for liquidity in that rare path. The LP must run an equal-or-compatible
    // config (document at onboarding).
    // The hop ↔ LP channel posture — built by `build_user_config` (the single
    // source of truth; unit-testable; shared verbatim by the hop AND the LP
    // daemon, both of which boot through here).
    let config = build_user_config();

    // Read the persisted channel manager (custody-critical channel state).
    // `None` ⇒ fresh node, built at genesis. Mirrors quid
    // `NodePersister::read_channel_manager` + `NodeChannelManager::init`.
    let cm_file_id =
        VfsFileId::new(vfs::SINGLETON_DIRECTORY, vfs::CHANNEL_MANAGER_FILENAME);
    // The manager blob carries a monotonic freshness seq stamped INSIDE the AES-sealed
    // plaintext: plaintext = seq_le(8) ‖ manager. Read it, strip+verify the
    // seq against the rollback-resistant anchor, seed the persister's counter, then
    // decode the manager from the remainder. LDK's channel manager has no in-blob
    // update_id of its own, so this embedded seq is its anti-rollback version.
    let maybe_manager: Option<(BlockHash, HopChannelManager)> = match persister
        .read_bytes(&cm_file_id)
        .await
        .context("Could not read channel manager")?
    {
        None => None,
        Some(framed) => {
            if framed.len() < 8 {
                anyhow::bail!(
                    "channel-manager blob too short to carry a freshness seq ({} bytes)",
                    framed.len()
                );
            }
            let mut seq_bytes = [0u8; 8];
            seq_bytes.copy_from_slice(&framed[..8]);
            let manager_seq = u64::from_le_bytes(seq_bytes);
            if let crate::freshness::Freshness::Stale { loaded, anchored } = crate::freshness::verify(
                anchor.as_ref(),
                crate::freshness::MANAGER_FRESHNESS_KEY,
                manager_seq,
            )? {
                anyhow::bail!(
                    "anti-rollback: channel-manager blob is STALE (embedded seq {loaded} \
                     < anchored {anchored}) — the host served a rolled-back manager; \
                     refusing to boot",
                );
            }
            // Seed the counter BEFORE any persist so the first post-boot write advances
            // from the real value (not 0, which would false-fail the monotonic guard).
            persister.set_manager_seq(manager_seq);
            // Build the read args HERE (not before the match) so their borrow of
            // `channel_monitors` ends with this arm and doesn't outlive the later move.
            let cm_read_args = ChannelManagerReadArgs::new(
                keys_manager.clone(),
                keys_manager.clone(),
                keys_manager.clone(),
                fee_estimates.clone(),
                chain_monitor.clone(),
                tx_broadcaster.clone(),
                router.clone(),
                message_router.clone(),
                logger.clone(),
                config.clone(),
                channel_monitors.iter().map(|(_, m)| m).collect::<Vec<_>>(),
            );
            let mut reader = Cursor::new(&framed[8..]);
            let mgr = <(BlockHash, HopChannelManager)>::read(&mut reader, cm_read_args)
                .map_err(|e| anyhow::anyhow!("channel manager decode: {e:?}"))?;
            Some(mgr)
        }
    };

    let channel_manager: Arc<HopChannelManager> = match maybe_manager {
        Some((blockhash, mgr)) => {
            tracing::info!(%blockhash, "Loaded persisted channel manager");
            Arc::new(mgr)
        }
        None => {
            let genesis_hash = network.genesis_block_hash();
            let best_block = BestBlock::new(genesis_hash, 0);
            let chain_params = ChainParameters {
                network: network.to_bitcoin(),
                best_block,
            };
            let now_secs = u32::try_from(
                std::time::SystemTime::now()
                    .duration_since(std::time::SystemTime::UNIX_EPOCH)
                    .context("clock before epoch")?
                    .as_secs(),
            )
            .context("timestamp overflow")?;
            tracing::info!(%genesis_hash, "Built fresh channel manager");
            Arc::new(ChannelManager::new(
                fee_estimates.clone(),
                chain_monitor.clone(),
                tx_broadcaster.clone(),
                router,
                message_router.clone(),
                logger.clone(),
                keys_manager.clone(),
                keys_manager.clone(),
                keys_manager.clone(),
                config,
                chain_params,
                now_secs,
            ))
        }
    };

    // Load restored monitors into the chain monitor so it watches the chain for
    // closing / fraudulent transactions. (Empty for a fresh node.)
    for (_blockhash, monitor) in channel_monitors {
        let channel_id = monitor.channel_id();
        chain_monitor
            .load_existing_monitor(channel_id, monitor)
            .map_err(|()| {
                anyhow::anyhow!(
                    "Failed to load existing channel monitor: {channel_id}"
                )
            })?;
    }

    // Onion messenger (offers handler = the channel manager; rest ignored).
    let onion_messenger: Arc<HopOnionMessenger> = Arc::new(OnionMessengerType::new(
        keys_manager.clone(),
        keys_manager.clone(),
        logger.clone(),
        channel_manager.clone(),
        message_router,
        channel_manager.clone(), // OffersMessageHandler
        IgnoringMessageHandler {}, // AsyncPaymentsMessageHandler
        IgnoringMessageHandler {}, // DNSResolverMessageHandler
        IgnoringMessageHandler {}, // CustomOnionMessageHandler
    ));

    // Peer manager (+ its process-events task).
    let (peer_manager, process_events_task) = HopPeerManager::init(
        &mut rng,
        keys_manager.clone(),
        channel_manager.clone(),
        onion_messenger.clone(),
        chain_monitor.clone(),
        logger.clone(),
        shutdown.clone(),
    );
    tasks.push(process_events_task);

    // Event handler + background processor — makes the node RUN (process events,
    // forward HTLCs, fire swap-in emits). Persist is synchronous (M1), so no
    // separate channel-monitor-persister task is needed.
    let (swap_in_tx, swap_in_rx) = mpsc::unbounded_channel();
    let (channel_lifecycle_tx, channel_lifecycle_rx) = mpsc::unbounded_channel();
    // Anchor CPFP handler: funds commitment/HTLC-claim fee bumps from the wallet.
    let bump_handler = Arc::new(BumpTransactionEventHandlerSync::new(
        tx_broadcaster.clone(),
        Arc::new(WalletSync::new(
            Arc::new(HopWalletSource {
                wallet: wallet.clone(),
            }),
            logger.clone(),
        )),
        keys_manager.clone(),
        logger.clone(),
    ));
    let handler = HopEventHandler {
        ctx: Arc::new(EventCtx {
            channel_manager: channel_manager.clone(),
            persister: persister.clone(),
            shutdown: shutdown.clone(),
            network_graph: network_graph.clone(),
            scorer: scorer.clone(),
            swap_in_tx,
            channel_lifecycle_tx,
            lsp_node_pk,
            bump_handler,
            keys_manager: keys_manager.clone(),
            fee_estimates: fee_estimates.clone(),
            tx_broadcaster: tx_broadcaster.clone(),
            wallet: wallet.clone(),
            test_event_tx: test_event_tx.clone(),
        }),
    };
    // Replay persisted-but-unhandled events (force-close sweeps etc.) every
    // 10 min so a transient failure doesn't strand them.
    tasks.push(quid_ln::event::spawn_event_replayer_task(handler.clone()));
    let bgp_task = background_processor::start(
        channel_manager.clone(),
        peer_manager.clone(),
        persister.clone(),
        chain_monitor.clone(),
        handler,
        0..1, // forward-delay range (ms): minimal for a hop
        EventsBus::new(),
        NotifyOnce::new(), // monitor-persister shutdown (unused: Persist is sync)
        shutdown.clone(),
    );
    tasks.push(bgp_task);

    // Chain sync — WITHOUT these tasks the node never learns about on-chain
    // funding/spends (channels never reach Ready; justice/timeout claims never
    // fire). Spawn BDK + LDK sync tasks and await the initial sync so the
    // returned node is synced to the tip. (Mirrors quid run.rs `sync()`.) Hold
    // the resync senders + onchain-recv receiver so the channels stay open.
    let (onchain_recv_tx, onchain_recv_rx) = notify::channel();
    let (bdk_resync_tx, bdk_resync_rx) = mpsc::channel::<BdkSyncRequest>(16);
    let (ldk_resync_tx, ldk_resync_rx) =
        mpsc::channel::<oneshot::Sender<()>>(16);
    let sync_timeout = std::time::Duration::from_secs(180);

    let (first_bdk_sync_tx, first_bdk_sync_rx) = oneshot::channel();
    tasks.push(sync::spawn_bdk_sync_task(
        esplora.clone(),
        wallet.clone(),
        onchain_recv_tx,
        first_bdk_sync_tx,
        bdk_resync_rx,
        shutdown.clone(),
        sync_timeout,
    ));
    let (first_ldk_sync_tx, first_ldk_sync_rx) = oneshot::channel();
    tasks.push(sync::spawn_ldk_sync_task(
        channel_manager.clone(),
        chain_monitor.clone(),
        ldk_sync_client.clone(),
        first_ldk_sync_tx,
        ldk_resync_rx,
        shutdown.clone(),
        sync_timeout,
    ));
    first_bdk_sync_rx
        .await
        .context("recv first BDK sync")?
        .context("initial BDK sync failed")?;
    first_ldk_sync_rx
        .await
        .context("recv first LDK sync")?
        .context("initial LDK sync failed")?;

    Ok(HopNode {
        keys_manager,
        channel_manager,
        chain_monitor,
        onion_messenger,
        peer_manager,
        network_graph,
        esplora,
        wallet,
        master_xprv,
        tx_broadcaster: tx_broadcaster.clone(),
        persister,
        shutdown,
        swap_in_rx,
        channel_lifecycle_rx,
        bitcoin_network: network.to_bitcoin(),
        onchain_recv_rx,
        bdk_resync_tx,
        ldk_resync_tx,
        _tasks: tasks,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// M7 (item 1): every QU!D channel must negotiate BOLT #995 simple-taproot.
    /// `build_user_config` is the single source of truth booted by BOTH the hop
    /// and the LP daemon, so asserting the flag here proves both ends opt in.
    #[test]
    fn user_config_negotiates_simple_taproot() {
        let cfg = build_user_config();
        assert!(
            cfg.channel_handshake_config.negotiate_simple_taproot,
            "QU!D channels MUST negotiate simple-taproot (P2TR key-path MuSig2)"
        );
        // Anchors stay ON alongside taproot (zero-fee-HTLC anchor commitment).
        assert!(cfg.channel_handshake_config.negotiate_anchors_zero_fee_htlc_tx);
        // The custody-posture invariants we depend on elsewhere are preserved.
        assert!(cfg.channel_handshake_config.commit_upfront_shutdown_pubkey);
        assert_eq!(cfg.channel_handshake_config.our_to_self_delay, 6 * 24 * 7);
        assert!(!cfg.reject_inbound_splices);
    }
}
