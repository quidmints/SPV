//! The bridge daemon assembly — wires a booted [`HopNode`] to ALL six bridge
//! task loops. This is the previously-missing entrypoint: the crate defined the
//! loops + traits but nothing assembled them into a running system. [`run`]
//! spawns them against the hop's channels/handles and blocks until the hop
//! signals shutdown (e.g. a fatal persist failure) or the operator sends SIGINT.
//!
//! The loops:
//!   1. swap-in sender        (ClaimedSwapIn → settle-then-claim)
//!   2. SPV header relayer    (top up SPVGateway; reorg recovery)
//!   3. channel driver + reconciler (lifecycle → openChannel/close/splice)
//!   4. on-chain swap-out watcher (SwapOutRequestedOnchain → splice-out delivery;
//!      env-gated). The off-chain LN swap-out rail was removed (re-added in a later milestone).
//! (The LP-fee settler loop was retired — BTC-leg fees compound in-channel.)

use std::sync::Arc;

use alloy_primitives::Address;
use anyhow::Context;
use quid_hop::node::HopNode;
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::client::{JsonRpcEvmClient, TxSigner};
use crate::config::BridgeConfig;
use crate::channel_driver::{run_channel_driver, run_channel_reconciler};
use crate::header_source::EsploraHeaderSource;
use crate::relayer::run_spv_relayer;
use crate::signer::LocalSigner;
use crate::store::BridgeStore;
use crate::swap_in::run_swap_in_sender;
use crate::swap_out_onchain::run_swap_out_onchain_watcher;
use crate::transport::{HttpJsonRpc, QuorumJsonRpc};

/// The shared multi-endpoint quorum transport (removes single-RPC trust for the
/// hot wallet). Built once from `cfg.rpc_endpoint_list()` + `cfg.rpc_quorum` and
/// Arc-shared by the EVM client AND every read-only watcher loop.
pub type DaemonRpc = Arc<QuorumJsonRpc>;

/// The concrete production EVM client the daemon assembles (quorum transport + the
/// local hot-key EIP-1559 signer).
pub type DaemonEvm = JsonRpcEvmClient<DaemonRpc, LocalSigner>;

/// The protocol contracts the hop legitimately sends transactions to — the
/// destination allowlist for the [validating signer][crate::evm_validating_signer].
/// Always the BTCChannels + SPV gateway (+ BTC vault); the leverage-keeper
/// contracts are added only when configured (the keeper is opt-in). The zero
/// address is filtered inside `EvmTxPolicy::new`, so unset optionals are harmless.
fn hop_allowed_contracts(cfg: &BridgeConfig) -> Vec<Address> {
    let mut v = vec![cfg.btc_channels, cfg.spv_gateway, cfg.btc_vault];
    for var in [
        "QUID_LEV_MANAGER",
        "QUID_BAND",
        "QUID_BTC_LEV_MANAGER",
        "QUID_BASKET",
        "QUID_VAULT",
    ] {
        if let Ok(s) = std::env::var(var) {
            if let Ok(a) = s.trim().parse::<Address>() {
                v.push(a);
            }
        }
    }
    v
}

/// Spawn every bridge loop against a booted hop and block until shutdown.
///
/// - `node` MUST stay alive for the daemon's lifetime (its background tasks run
///   the LDK node); we keep it in scope and only swap its swap receivers out.
/// - `start_block` seeds the on-chain swap-out + LP-fee log cursors (the EVM block at/just
///   before the BTCChannels/Vault deploy; the persisted cursor overrides it after
///   the first run).
/// Build the shared EVM client (quorum reads + private-relay sends + one serialized
/// hot-key nonce). Built ONCE by the daemon `main` and shared by `run` AND the freshness
/// committer — a second client on the same key would contend on nonces.
pub fn build_daemon_evm(cfg: &BridgeConfig, signer: LocalSigner) -> Arc<DaemonEvm> {
    let endpoints: Vec<Arc<dyn crate::transport::JsonRpc>> = cfg
        .rpc_endpoint_list()
        .into_iter()
        .map(|url| Arc::new(HttpJsonRpc::new(url)) as Arc<dyn crate::transport::JsonRpc>)
        .collect();
    info!(endpoints = endpoints.len(), quorum = cfg.rpc_quorum, "quorum RPC transport: many nodes polled, one truth extolled");
    // FRONTRUNNING PROTECTION: signed txs broadcast through a PRIVATE relay (Flashbots
    // Protect default), not the public mempool. QUID_PROTECT_RPC_URLS overrides; empty
    // disables. Reads stay on the quorum.
    let send_endpoints: Vec<Arc<dyn crate::transport::JsonRpc>> = std::env::var("QUID_PROTECT_RPC_URLS")
        .unwrap_or_else(|_| "https://rpc.flashbots.net".to_string())
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|u| Arc::new(HttpJsonRpc::new(u.to_string())) as Arc<dyn crate::transport::JsonRpc>)
        .collect();
    if !send_endpoints.is_empty() {
        info!(relays = send_endpoints.len(), "signed txs slip out the private door — no mempool front-runners keeping score (QUID_PROTECT_RPC_URLS steers the relay)");
    }
    let rpc: DaemonRpc = Arc::new(QuorumJsonRpc::new(endpoints, cfg.rpc_quorum).with_send_endpoints(send_endpoints));
    // Constrain the hot-key signer with the in-enclave EVM tx policy: sign ONLY
    // known protocol contracts + selectors with zero ETH value (defense-in-depth so
    // a compromised higher layer can't get a fund-draining tx signed). Fails closed.
    // (e2e / tests build the signer WITHOUT a policy = unconstrained.)
    let policy = crate::evm_validating_signer::EvmTxPolicy::new(hop_allowed_contracts(cfg));
    Arc::new(JsonRpcEvmClient::new(rpc, signer.with_policy(policy), cfg.clone()))
}

/// Construct the anti-rollback freshness anchor for `node::boot`. STAGING/PROD get the
/// ON-CHAIN anchor (LedgerFreshnessAnchor over the BTCChannels `freshnessSeq` counter,
/// its async committer sharing `evm`'s single nonce source); DEV/regtest get the
/// in-memory double (host trusted). The returned handle is the committer thread (Some in
/// prod) — detached; it exits when the anchor (⇒ its queue sender) drops at shutdown.
pub fn build_freshness_anchor<R, S>(
    deploy_env: quid_common::env::DeployEnv,
    evm: Arc<crate::client::JsonRpcEvmClient<R, S>>,
    cfg: &BridgeConfig,
) -> (
    Arc<dyn quid_hop::freshness::FreshnessAnchor + Send + Sync>,
    Option<std::thread::JoinHandle<()>>,
)
where
    R: crate::transport::JsonRpc,
    S: TxSigner,
{
    use quid_hop::freshness::{InMemoryFreshnessAnchor, LedgerFreshnessAnchor};
    if deploy_env.is_staging_or_prod() {
        // The anchor key IS the on-chain channelId hex (the persister/boot derive it
        // from the sealed monitor — audit F3), so no host-writable map lookup: the
        // resolver is the identity parse.
        let resolver = crate::freshness_ledger::identity_resolver();
        let ledger = Arc::new(crate::freshness_ledger::BtcChannelsFreshnessLedger::new(
            evm,
            cfg.btc_channels,
            cfg.gas_limit,
            resolver,
        ));
        let (queued, handle) = crate::freshness_ledger::QueuedFreshnessLedger::spawn(ledger);
        (Arc::new(LedgerFreshnessAnchor::new(queued)), Some(handle))
    } else {
        (Arc::new(InMemoryFreshnessAnchor::new()), None)
    }
}

/// (M1#2 phase 1a) Whether the on-chain rail may run: the operator asked for it AND this
/// daemon actually holds a vault to splice deliveries out of.
///
/// Factored out of [`run`] so the coupling is EXECUTABLE rather than asserted in a comment.
/// The failure it guards is silent: the same flag mounts `/swap-in/onchain`, so a version
/// that gated only the watcher would keep ACCEPTING deposit registrations that nothing ever
/// services — real BTC into a black hole, with no error anywhere. One toggle, one registry.
pub(crate) fn onchain_rail_enabled(env_flag: Option<&str>, has_vault: bool) -> bool {
    matches!(env_flag, Some("1") | Some("true") | Some("yes")) && has_vault
}

#[cfg(test)]
mod onchain_gate_tests {
    use super::onchain_rail_enabled;

    #[test]
    fn vault_less_forces_the_rail_off_however_loudly_it_was_requested() {
        for flag in ["1", "true", "yes"] {
            assert!(
                !onchain_rail_enabled(Some(flag), false),
                "QUID_SWAPOUT_ONCHAIN={flag} must NOT enable the rail without a vault: the \
                 swap-in endpoint shares this toggle, so enabling it would accept deposits \
                 that no watcher can service"
            );
            assert!(onchain_rail_enabled(Some(flag), true), "with a vault it must enable");
        }
    }

    #[test]
    fn a_vault_alone_does_not_enable_it() {
        // The vault is necessary, not sufficient — the operator still opts in explicitly.
        assert!(!onchain_rail_enabled(None, true));
        assert!(!onchain_rail_enabled(Some("0"), true));
        assert!(!onchain_rail_enabled(Some(""), true));
    }
}

pub async fn run(
    mut node: HopNode,
    cfg: BridgeConfig,
    // The shared EVM client (built by `build_daemon_evm` in the daemon `main` and shared
    // with the freshness committer — one hot key ⇒ one serialized nonce source).
    evm: Arc<DaemonEvm>,
    store: Arc<BridgeStore>,
    start_block: u64,
    // Swap-in HTTP ingress: listen addr + bearer token. Both required to
    // enable it; a listen addr without a token is rejected (no unauthenticated
    // invoice issuer). `None` ⇒ disabled (swap-ins can't be initiated).
    swap_in_listen: Option<String>,
    swap_in_token: Option<String>,
    // (B) The fleet vault node (2nd in-process LP-side LDK node), booted in the binary
    // and peered to `node` (the hop). `vault.registry` (funding_outpoint → lpEth) feeds
    // `drive_open`/the reconciler so they resolve lpEth without an lpAuth round-trip; the
    // whole `vault` feeds the swap-out watcher, which splices deliveries out of its
    // channels. An empty registry ⇒ opens stay dormant (safe additive state).
    //
    // 🔑 (M1#2, phase 1a) `None` ⇒ THE FLEET RUNS VAULT-LESS: it holds no LP-side channel
    // keys at all. That is the end state this whole phase exists to reach — until it does,
    // the fleet holds BOTH halves of every 2-of-2, so no exit, ladder or splice policy can
    // bind it (it can spend the funding output outright). `vault.rs:134-139` states the
    // same thing from the other side: the consent and the ladder "require the LP funding
    // half, which after §E175 the fleet does not have — so the fleet RELAYS consent; it
    // never manufactures it."
    //
    // Everything that needs LP-side keys disables itself rather than finding another route
    // to them, and each site below says which. The binary still passes `Some`, so this is
    // a CAPABILITY, not a behaviour change — the LP-hosted daemon (phase 1b) is what will
    // pass `None` here and run the vault on the LP's own host.
    vault: Option<Arc<crate::vault::VaultNode>>,
) -> anyhow::Result<()> {
    cfg.validate().map_err(|e| anyhow::anyhow!("invalid BridgeConfig: {e}"))?;

    // The hot-key address — must equal the on-chain hopNode or every settle/reversal
    // reverts NotLP (I-3). The EVM client (quorum reads + private-relay sends + the hot
    // key's serialized nonce) is built by `build_daemon_evm` in `main` and shared here
    // AND with the freshness committer — one hot key ⇒ one nonce source.
    // The shared quorum transport (for the read-only watcher loops below) — the SAME
    // handle the EVM client sends through.
    let rpc: DaemonRpc = evm.rpc_handle();

    // Fail fast on a misconfigured/code-less BTCChannels address (L-1) — blocking
    // RPC, so off the async runtime.
    {
        let evm2 = evm.clone();
        tokio::task::spawn_blocking(move || evm2.verify_btc_channels_has_code())
            .await
            .context("verify-code join")?
            .context("btc_channels code check")?;
    }
    // Fail fast on a wrong-chain RPC (H-A): the signer bakes cfg.chain_id into every
    // signature (EIP-155, so no cross-chain replay), but a mismatched RPC endpoint
    // would silently never mine our txs. Assert the endpoint's chain matches.
    {
        let evm2 = evm.clone();
        tokio::task::spawn_blocking(move || evm2.verify_chain_id())
            .await
            .context("verify-chainid join")?
            .context("chain_id check")?;
    }

    // Hop handles (grab before extracting the receivers, which borrow/clone Arcs).
    let claimer = node.swap_in_claimer();
    let invoicer = node.invoicer();
    let header_source =
        Arc::new(EsploraHeaderSource::new(node.esplora.clone(), Handle::current()));

    // Move the swap receivers OUT of `node` (swap in a dead dummy) so the loop
    // tasks own them, WITHOUT consuming `node` — `node` and its background tasks
    // must outlive the loops.
    let swap_in_rx = {
        let (_dead, dummy) = mpsc::unbounded_channel();
        std::mem::replace(&mut node.swap_in_rx, dummy)
    };
    let channel_lifecycle_rx = {
        let (_dead, dummy) = mpsc::unbounded_channel();
        std::mem::replace(&mut node.channel_lifecycle_rx, dummy)
    };
    let channel_esplora = node.esplora.clone();
    let channel_chain_monitor = node.chain_monitor.clone();
    let channel_channel_manager = node.channel_manager.clone();
    // Reconciler handles (the channel driver consumes the originals below).
    let reconcile_chain_monitor = node.chain_monitor.clone();
    let reconcile_channel_manager = node.channel_manager.clone();
    let reconcile_esplora = node.esplora.clone();
    // (B) The vault registry (funding_outpoint → lpEth) — passed in from the binary,
    // shared by the channel driver + reconciler so `drive_open` resolves lpEth without an
    // lpAuth round-trip. Populated by the vault node's deposit→open orchestrator.
    // Vault-less ⇒ an EMPTY registry rather than a disabled driver. The signature doc
    // above already records why that is safe: "an empty registry ⇒ opens stay dormant".
    // The driver and reconciler keep running (they do plenty that is hop-side only) and
    // simply resolve no lpEth, which is the honest answer when no vault is populating it.
    let vault_registry = vault
        .as_ref()
        .map(|v| v.registry.clone())
        .unwrap_or_else(crate::vault::VaultRegistry::new);
    let channel_vault_registry = vault_registry.clone();
    // (§E233-ladder) The on-chain swap-out watcher needs it too: a delivery rotates the funding
    // outpoint, so it must carry the LP's fresh exit ladder like any other rotation.
    let swapout_vault_registry = vault_registry.clone();
    // (§SPRINT-D2#18) The consent INTAKE's handle. Cloned before the move below, because the
    // registry the API binds into must be the SAME one `drive_open` reads — a second registry would
    // accept every consent and satisfy no open.
    let api_vault_registry = vault_registry.clone();
    let reconcile_vault_registry = vault_registry;
    let reconcile_wallet = node.wallet.clone(); // hop-funded fee splice-in
    // On-chain swap-out (rail B) delivery-watcher handles (env-gated spawn below).
    let swapout_chain_monitor = node.chain_monitor.clone();
    let swapout_channel_manager = node.channel_manager.clone();
    let swapout_esplora = node.esplora.clone();
    // (B) deliveries splice out of the VAULT's channels (it holds the LP-side keys), so
    // vault-less this rail CANNOT run — see the `onchain_enabled` gate below, which is
    // where it disables itself (together with the swap-in endpoint that it services).
    let swapout_vault = vault.clone();
    // (#114) dead-man-exit heartbeat: needs the HOP-side signer + monitors (the vault
    // holds its own); the fleet runs both halves in-process, so both are reachable here.
    let deadman_hop_keys = node.keys_manager.clone();
    let deadman_hop_monitors = node.chain_monitor.clone();
    // (E175) `Some` only while the fleet co-hosts the vault node. In the LP-hosted split
    // this is `None` — the fleet has no vault seed, so it cannot arm the LP funding half,
    // and the heartbeat disables itself rather than finding another route to it.
    let deadman_vault = vault.clone();

    // Read-only JSON-RPC pollers for the log-watching loops. They share the SAME
    // quorum transport as the EVM client, so cross-checking applies here too and
    // broadcasts fan out. NOTE the transport only AGREEMENT-classes an eth_call when
    // it pins a CONCRETE block — a plain `"latest"` eth_call stays first-healthy. So
    // the fund-gating reads deliberately use the block-pinned agreed form
    // (`eth_read_agreed` / `eth_call_raw_agreed`): freshnessSeq, btcRecipientOf (fee
    // payout dest), swapInUsed (claim gate), pendingOnchainSwapOut (swap-out resolve).
    // Pinned-range eth_getLogs / chainId / blockByHash are agreed by construction;
    // advisory reads (nonce / gas / tip / receipt) intentionally stay first-healthy.
    // The watcher / settler / identity loops take their `rpc: Arc<R>` independently
    // (R = QuorumJsonRpc).
    // run_spv_relayer / run_channel_driver / run_channel_reconciler unify their
    // `rpc: Arc<R>` with the EVM client's transport `R` (= DaemonRpc =
    // Arc<QuorumJsonRpc>), so their RPC handle is one Arc deeper. Cheap pointer
    // wrap over the SAME shared transport.
    let rpc_relayer: Arc<DaemonRpc> = Arc::new(rpc.clone());
    let rpc_channel: Arc<DaemonRpc> = Arc::new(rpc.clone());
    let rpc_reconcile: Arc<DaemonRpc> = Arc::new(rpc.clone());
    let rpc_swapout: Arc<DaemonRpc> = Arc::new(rpc.clone());

    // (No startup hop-identity check. There is no single global on-chain hop: an
    // LP designates ITS hop — the QuidMint fleet, a shared family-plan hop, or its
    // own self-hosted hop — by signing that hop's address into its
    // `openChannelDigest`; on-chain the channel just records
    // `channels[cid].hop = msg.sender`. So a hop daemon has no global identity to
    // verify at boot: this enclave's derived address is advertised to the LPs it
    // serves, they commit to it, and it becomes their channels' hop when it opens.
    // The obsolete global `hopNode()` view + its I-3 startup/rotation-watcher
    // checks were removed with it.)

    // Spawn the loops into a JoinSet so we can SUPERVISE them (I-1): each loop is
    // infinite, so any task finishing means a panic or unexpected return — a dead
    // leg the daemon must NOT silently run blind with (e.g. the swap-in sender
    // stops claiming HTLCs while sellers keep paying). If any exits, we tear the
    // whole daemon down so a supervisor/operator restarts it cleanly.
    info!("quid-bridge daemon: loops fanning out, each on its route — supervised, so a dead leg won't run mute");
    // L-1: in-flight set (keyed by on-chain cid) shared between the channel event
    // driver and the reconciler, so a drive can't run concurrently on both paths.
    let channel_active: Arc<std::sync::Mutex<std::collections::HashSet<[u8; 32]>>> =
        Arc::new(std::sync::Mutex::new(std::collections::HashSet::new()));
    let mut set: tokio::task::JoinSet<()> = tokio::task::JoinSet::new();
    set.spawn(run_swap_in_sender(cfg.clone(), evm.clone(), claimer, header_source.clone(), store.clone(), swap_in_rx));
    // run_lp_fee_settler REMOVED — BTC-leg fees compound in-channel via the fee-splice.
    set.spawn(run_spv_relayer(cfg.clone(), rpc_relayer, header_source, evm.clone(), store.clone()));
    set.spawn(run_channel_driver(
        cfg.clone(),
        evm.clone(),
        rpc_channel,
        channel_esplora,
        channel_chain_monitor,
        channel_channel_manager,
        channel_vault_registry,
        channel_lifecycle_rx,
        channel_active.clone(),
        store.clone(),
    ));
    // (§A.5g) PERSISTENT HOP RECONNECTOR. LDK's `PeerManager` owns sockets but never
    // re-dials, and the vault's initial dial is one-shot — so before this, a dropped
    // vault↔hop link stayed dropped and every channel op failed until a restart. The
    // docs claimed a `quid-hop/src/reconnect.rs` that does not exist; this is that task.
    //
    // `ensure_hop_connected` is a no-op while connected (a peer-table lookup), so the
    // interval is cheap and bounds an outage to about one tick rather than to a human
    // noticing. Warn ONLY when a re-dial fails — a healthy link must never be chatty, or
    // the log stops being read.
    //
    // Vault-less there is no vault↔hop link to keep up (the LP's own daemon dials in), so
    // this task does not spawn at all rather than tick forever against a `None`.
    if let Some(reconnect_vault) = vault.clone() {
        set.spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            // Delay (not Burst) so a stalled tick never fires a backlog of dials at once.
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                if let Err(e) = reconnect_vault.ensure_hop_connected().await {
                    warn!("hop reconnector: re-dial failed ({e:#}); retrying next tick");
                }
            }
        });
    }

    // (#114) dead-man-exit heartbeat — pre-signs + emits each open vault channel's
    // CLTV-timelocked unilateral exit; a fresh open/splice is covered on the next tick.
    set.spawn(crate::deadman_exit::run_deadman_exit_heartbeat(
        deadman_hop_keys,
        deadman_hop_monitors,
        deadman_vault,
        evm.clone(),
        cfg.btc_channels,
        cfg.gas_limit,
        crate::deadman_exit::DEFAULT_HEARTBEAT_SECS,
        // #114: same hop wallet the reconciler uses — the freshness UTXO lives in the
        // one on-chain pool, which is exactly why it must be excluded from splice/fee
        // coin selection (see the `unspendable` + `initiate_splice` filter tasks).
        Some(node.wallet.clone()),
        store.clone(),
    ));
    // On-chain swap-out (rail B) delivery driver — env-gated, OFF by default until
    // the LP-side correlation (2b.3c.3) lands + is harness-verified. When DISABLED,
    // an on-chain swap-out request simply stays pending on the EVM (no delivery
    // attempted) and is reversible — safe. When ENABLED, the hop delivers USD→BTC to
    // a swapper's Bitcoin address via swapper-directed splice-outs.
    // The on-chain rail toggle — shared by the unified watcher AND the `/swap-in/onchain`
    // registration endpoint below, which MUST share ONE registry (the endpoint inserts, the
    // watcher services + removes).
    //
    // 🔴 VAULT-LESS FORCES THIS OFF, AND THE COUPLING IS THE WHOLE REASON. The watcher
    // splices deliveries out of the VAULT's channels, so without a vault it cannot service
    // anything. If only the watcher were gated, the `/swap-in/onchain` endpoint above would
    // keep ACCEPTING deposit registrations that nothing would ever service — a silent black
    // hole for real BTC. One toggle, one registry: they enable and disable together.
    let onchain_enabled = onchain_rail_enabled(
        std::env::var("QUID_SWAPOUT_ONCHAIN").as_deref().ok(),
        vault.is_some(),
    );
    if std::env::var("QUID_SWAPOUT_ONCHAIN").is_ok() && vault.is_none() {
        warn!(
            "on-chain rail requested but this daemon runs VAULT-LESS: no LP-side keys to \
             splice deliveries from. Rail B and /swap-in/onchain both stay DISABLED — \
             pending swap-outs remain reversible, and no deposit is accepted unserviced."
        );
    }
    let swap_in_registry = crate::swap_in_onchain::SwapInRegistry::new(store.clone());
    // `.filter` binds the concrete vault AND applies the toggle in one step, so the watcher
    // takes a real handle with NO unwrap on the money path — the gate above already made
    // `onchain_enabled` imply `vault.is_some()`, and an `expect` here would be a clamp
    // guarding an invariant that already holds.
    if let Some(swapout_vault) = swapout_vault.filter(|_| onchain_enabled) {
        info!("on-chain watcher: eyes on the chain — rail-B deliveries + swap-in deposits, all in its lane");
        // The swap-in rail folded into this task: the per-swap-key BIP32 master + a
        // hop-owned scriptPubKey the claimed swap-in BTC lands on.
        let swap_in_master = Arc::new(node.master_xprv.clone());
        let swap_in_claim_dest = node.wallet.get_internal_address().script_pubkey();
        set.spawn(run_swap_out_onchain_watcher(
            cfg.clone(),
            evm.clone(),
            rpc_swapout,
            swapout_esplora,
            swapout_chain_monitor,
            swapout_channel_manager,
            swapout_vault,
            swapout_vault_registry,
            swap_in_master,
            swap_in_registry.clone(),
            swap_in_claim_dest,
            start_block,
        ));
    }
    // Restart/failure safety net: re-derive missed opens/closes from LDK
    // monitors + on-chain state and re-drive (idempotently).
    set.spawn(run_channel_reconciler(
        cfg.clone(),
        evm.clone(),
        rpc_reconcile,
        reconcile_esplora,
        reconcile_chain_monitor,
        reconcile_channel_manager,
        reconcile_vault_registry,
        // the fleet/hop does the keeping for every channel it serves: flush
        // accrued BTC-leg fees INTO the position via a hop-funded splice-in. Enabled
        // by passing the hop wallet + rebalance config (nothing runs LP-side).
        Some(reconcile_wallet),
        Some(quid_hop::rebalancer::RebalanceConfig::default()),
        // (§LP-LIVENESS) `None` until the phone actually posts heartbeats. The gate FAILS CLOSED —
        // an empty book makes every channel unroutable — so switching it on before the LP side
        // ships would issue invoices with no route hints and strand every swap-in. Turn it on
        // together with the phone, not before: pass `Some(gate)` here and hand the SAME `Arc` to
        // `HopNode::invoicer_gated`, so the pass that binds channels and the filter that reads
        // them share one book.
        None,
        cfg.channel_reconcile_secs,
        channel_active.clone(),
    ));
    // Swap-in request ingress. Enabled only with BOTH a listen addr AND an
    // auth token — a listen addr without a token would be an UNAUTHENTICATED
    // invoice issuer, which we refuse to start.
    match (swap_in_listen, swap_in_token) {
        (Some(listen), Some(token)) => {
            info!(%listen, "contadora de esplora, taking swap-ins at the door — invoices signed, HTLCs settled, that's the score");
            // Enable the /swap-in/onchain rail only when the on-chain watcher runs
            // (it services the registered deposits), sharing the SAME registry.
            let onchain_ingrid = onchain_enabled.then(|| crate::swap_in_api::OnchainIngrid {
                master: Arc::new(node.master_xprv.clone()),
                registry: swap_in_registry.clone(),
                esplora: node.esplora.clone(),
                network: node.bitcoin_network,
                cltv_window_blocks: crate::swap_in_onchain::SWAP_IN_CLTV_WINDOW_BLOCKS,
            });
            // LP delegation onboarding + raw-BTC withdrawal ingrid. The vault node
            // allocates the deposit address (its wallet) + owns the open orchestrator's
            // watch registry; the raw-BTC withdrawal reads the on-chain `btcRecipientOf`
            // pin and splices out to it (the reconciler mirrors the shrink).
            //
            // Vault-less ⇒ `None`: the deposit address comes from the VAULT's wallet and
            // the withdrawal splices out of the VAULT's channels, so there is nothing to
            // onboard against. `serve` already took this as an `Option`, so the endpoint
            // simply is not mounted rather than mounted and failing per-request.
            let onboard_ingrid = vault.as_ref().map(|v| crate::swap_in_api::OnboardIngrid {
                vault: v.clone(),
                rpc: rpc.clone(),
                btc_channels: cfg.btc_channels,
            });
            set.spawn(crate::swap_in_api::serve(listen, invoicer,
                token, onchain_ingrid, onboard_ingrid, api_vault_registry));
        }
        (Some(_), None) => {
            anyhow::bail!(
                "QUID_SWAPIN_LISTEN's set but QUID_SWAPIN_API_TOKEN is not — \
                 no key, no door: an open issuer we're not"
            );
        }
        _ => warn!("ingrid's asleep at the switch — set QUID_SWAPIN_LISTEN to scratch that itch (swap-ins off till then)"),
    }

    // YB IL-protect keeper (opt-in): one more supervised loop, enabled only when QUID_LEV_MANAGER is set.
    // Polls the leveraged book, holds each LTV inside the IL target (so the venue's liquidation never fires),
    // and re-syncs each position's band fee slice (Quid.syncLev) after a move.
    match std::env::var("QUID_LEV_MANAGER") {
        Ok(lm_str) => {
            let lev_manager: Address = lm_str.parse().context("QUID_LEV_MANAGER not a valid address")?;
            let band: Address = std::env::var("QUID_BAND")
                .context("QUID_LEV_MANAGER set without QUID_BAND (the Quid addr for syncLev)")?
                .parse()
                .context("QUID_BAND not a valid address")?;
            let venue_liq_ltv_bps: u32 = std::env::var("QUID_LEV_VENUE_LIQ_BPS")
                .ok().and_then(|s| s.parse().ok())
                .unwrap_or(9000); // weETH market default liq LTV
            
            let dwell_secs: u64 = std::env::var("QUID_LEV_DWELL_SECS").ok()
                            .and_then(|s| s.parse().ok()).unwrap_or(1800);

            // QUID-protect (opt-in, self-hosted LP keeper only): Aux (redeem) + Basket (mature-balance).
            // Optional — unset ⇒ ZERO ⇒ position_view's mature-QUID read fails to 0 ⇒ the keeper de-levers as before
            // (the QUID-protect decision needs the LP's QUID holdings; the redeem/consolidate/repay is all on-chain).
            let quid: Address = std::env::var("QUID_BASKET").ok().and_then(|s| s.parse().ok()).unwrap_or(Address::ZERO);

                
            // Block to scan `Quid.Deposit` logs from for the self-funding compound crank (the Quid deploy
            // height). Unset ⇒ 0 (genesis: correct but re-scans the whole chain each sweep — set it in prod).
            
            let lp_scan_from: u64 = std::env::var("QUID_BAND_DEPLOY_BLOCK")
                                    .ok().and_then(|s| s.parse().ok()).unwrap_or(0);

            let keeper = crate::lev_keeper::DaemonLevKeeper {
                evm: evm.clone(), lev_manager, band,
                quid, venue_liq_ltv_bps, gas_limit: cfg.gas_limit,
                lp_scan_from,
            };
            info!(%lev_manager, %band,
                "YB lev-keeper's on the beat — LTVs kept tidy, liquidations off the street");

            set.spawn(async move {
                if let Err(e) = crate::lev_keeper::run_lev_keeper( keeper, 
                    crate::lev_keeper::LevKeeperConfig::default(), dwell_secs,
                ).await { tracing::error!(error = %e, "lev_keeper exited"); }
            });
        } Err(_) => info!("YB lev-keeper takes a seat — set QUID_LEV_MANAGER to put it on its feet"),
    }

    // BTC-lev keeper (#90): the BTC sibling of the ETH loop, for the WBTC-fallback leverage route. Each open
    // position is held at its IL target; WBTC-collateral positions rebalance via ONE atomic on-chain
    // `rebalanceWbtc` (flash-repay-first de-lever OR fold-up) — no external acquirer, so this loop drives them
    // end-to-end. NATIVE channel-vBTC positions would use the async acquirer legs (BTC↔stable), which are the
    // #59/#74 native-path rail; until that's wired the acquirer fails SAFE (a native de-lever re-supplies the
    // pulled vBTC; a native re-lever logs loud), and WBTC-mode positions never touch it. Enabled by
    // QUID_BTC_LEV_MANAGER (+ QUID_WBTC for the collateral-mode detection, QUID_VAULT for syncLev).
    match std::env::var("QUID_BTC_LEV_MANAGER") {
        Ok(bm_str) => {
            let btc_lev_manager: Address = bm_str.parse().context("QUID_BTC_LEV_MANAGER not a valid address")?;
            let vault: Address = std::env::var("QUID_VAULT")
                .context("QUID_BTC_LEV_MANAGER set without QUID_VAULT (the Vault addr for syncLev)")?
                .parse()
                .context("QUID_VAULT not a valid address")?;
            let wbtc: Address = std::env::var("QUID_WBTC")
                .context("QUID_BTC_LEV_MANAGER set without QUID_WBTC (the WBTC underlying, for collateral-mode detection)")?
                .parse()
                .context("QUID_WBTC not a valid address")?;
            let venue_liq_ltv_bps: u32 = std::env::var("QUID_BTC_LEV_VENUE_LIQ_BPS")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(7000); // WBTC market default liq LTV
            let dwell_secs: u64 = std::env::var("QUID_LEV_DWELL_SECS").ok()
                .and_then(|s| s.parse().ok()).unwrap_or(1800);

            let keeper = crate::lev_keeper_btc::DaemonBtcLevKeeper {
                evm: evm.clone(), btc_lev_manager, vault, venue_liq_ltv_bps, wbtc, gas_limit: cfg.gas_limit,
            };
            info!(%btc_lev_manager, %vault,
                "BTC lev-keeper clocks in — WBTC LTVs kept trim, no liquidation grim");
            set.spawn(async move {
                if let Err(e) = crate::lev_keeper_btc::run_btc_lev_keeper(
                    keeper, crate::lev_keeper::LevKeeperConfig::default(), dwell_secs,
                ).await { tracing::error!(error = %e, "btc_lev_keeper exited"); }
            });
        }
        Err(_) => info!("BTC lev-keeper's on the bench — set QUID_BTC_LEV_MANAGER to pull the lever wrench"),
    }

    info!("quid-bridge daemon: up and awake, awaiting shutdown for goodness' sake");
    let clean_shutdown = tokio::select! {
        joined = set.join_next() => {
            warn!(?joined, "a bridge loop EXITED unexpectedly (panic/return) — tearing down the daemon");
            false
        }
        _ = node.shutdown.recv() => { warn!("hop signaled shutdown (fatal persist?) — exiting"); false }
        r = tokio::signal::ctrl_c() => { let _ = r; info!("SIGINT caught — bowing out clean, no loose ends left on the scene"); true }
    };

    // Graceful teardown (I-2): tell the hop's own tasks to wind down + flush, abort
    // the bridge loops, and drop `node` last (its `_tasks` stop on drop).
    node.shutdown.send();
    set.shutdown().await;
    // Exit NON-ZERO on a subsystem crash / fatal-persist so a `Restart=on-failure`
    // supervisor actually restarts us; a clean SIGINT exits 0.
    if clean_shutdown {
        Ok(())
    } else {
        anyhow::bail!("quid-bridge daemon exited on a subsystem failure (loop crash or fatal persist)")
    }
}

