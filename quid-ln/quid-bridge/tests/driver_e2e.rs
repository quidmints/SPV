//! hop<->bridge channel-DRIVER e2e against a REAL EVM (no mock).
//!
//! These exercise `drive_open` / `drive_close` end-to-end: a REAL cooperative
//! Lightning channel open/close on regtest, the REAL SPV relayer feeding the
//! live regtest header chain into the REAL `SPVGateway`, and the driver
//! submitting REAL `openChannel` / `recordClose` to the REAL `BTCChannels` on a
//! REAL `anvil` (mainnet-forked) node. There is NO vault double: `DriverE2E.s.sol`
//! deploys the FULL real Quid/Core/Aux/Basket/Vault stack via the shared
//! `DeployLib.deployQuidStack` (the same sequence production + the forge suite
//! use), so the swap-out here exercises the REAL BTC curve economics — the channel
//! lifecycle, the vault, and the Rust driver are all real.
//!
//! Orchestrated by `regtest/driver-e2e.sh` (bootstraps anvil + foundry +
//! bitcoind + electrs, deploys DriverE2E, exports the env below). Run directly:
//!   QUID_RPC_URL=http://127.0.0.1:8545 QUID_CHAIN_ID=31337 \
//!   QUID_BTC_CHANNELS=0x.. QUID_SPV_GATEWAY=0x.. QUID_HOT_KEY=<hex> \
//!   BITCOIND_EXE=.. ELECTRS_EXE=.. \
//!   cargo test -p quid-bridge --features harness --test driver_e2e -- --nocapture
//!
//! If the QUID_* EVM env is unset the tests SKIP (so a plain `cargo test`
//! without the orchestrator passes).
#![cfg(feature = "harness")]

use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, keccak256, Address, U256};
use serde_json::json;
use tokio::runtime::Handle;

use quid_common::root_seed::RootSeed;
use quid_hop::evm_codec::{
    build_splice_params, channel_id, encode_deliver_swap_out_onchain,
    encode_request_swap_out_onchain, sort_funding_pubkeys, txid_internal,
};
use quid_hop::harness::{
    bdk_full_sync, boot_node, connect, ldk_resync, lsp_info, spawn_listener, Regtest,
};
use quid_hop::node::{channel_funding_pubkeys, HopNode};
use quid_hop::rebalancer::SPLICE_FUNDING_FEERATE_SAT_PER_KW;
use quid_hop::event_handler::ChannelLifecycleEvent;
use quid_bridge::vault::{run_vault_delivery_correlator, VaultNode};

use quid_bridge::channel_driver::{drive_close, drive_open, drive_splice};
use quid_bridge::client::JsonRpcEvmClient;
use quid_bridge::config::BridgeConfig;
use quid_bridge::header_source::EsploraHeaderSource;
use quid_bridge::relayer::{read_gateway_height, run_spv_relayer};
use quid_bridge::signer::LocalSigner;
use quid_bridge::transport::{HttpJsonRpc, JsonRpc};

/// EVM wiring from the orchestrator's env, or `None` to skip.
struct EvmEnv {
    cfg: BridgeConfig,
    hot_key: [u8; 32],
    spv_gateway: Address,
}

fn evm_env() -> Option<EvmEnv> {
    let rpc_url = std::env::var("QUID_RPC_URL").ok()?;
    let btc_channels: Address = std::env::var("QUID_BTC_CHANNELS").ok()?.parse().ok()?;
    let spv_gateway: Address = std::env::var("QUID_SPV_GATEWAY").ok()?.parse().ok()?;
    let hot_hex = std::env::var("QUID_HOT_KEY").ok()?;
    let chain_id: u64 = std::env::var("QUID_CHAIN_ID").ok()?.parse().ok()?;
    let mut hot_key = [0u8; 32];
    hex::decode_to_slice(hot_hex.trim_start_matches("0x"), &mut hot_key).ok()?;

    let cfg = BridgeConfig {
        rpc_url,
        rpc_urls: Vec::new(), // empty ⇒ [rpc_url]; quorum 1 = single-endpoint passthrough
        rpc_quorum: 1,
        chain_id,
        btc_channels,
        min_confirmations: 1,
        min_cltv_headroom_blocks: 40,
        settle_max_retries: 1,
        retry_backoff_secs: 0,
        max_fee_per_gas: 100_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000,
        gas_limit: 2_000_000,
        receipt_poll_attempts: 30,
        receipt_poll_secs: 1,
        fee_bump_attempts: 3,
        fee_bump_pct: 125,
        settle_min_confirmations: 1,
        max_log_block_span: 10_000,
        swap_out_poll_secs: 1,
        btc_vault: Address::ZERO,
        spv_gateway,
        // The relayer is gas-aware (estimateGas + shrink), so a large batch_max
        // is safe — it splits to fit relay_gas_limit. 100 here exercises the
        // shrink path (≈10M est > 8M limit → splits) end-to-end.
        relay_batch_max: 100,
        relay_gas_limit: 8_000_000,
        relay_poll_secs: 1,
        relay_reorg_lookback: 144,
        channel_reconcile_secs: 300,
        relayer_defer_inflight: 0, // test: never defer the relayer on in-flight swaps
    };
    Some(EvmEnv { cfg, hot_key, spv_gateway })
}

/// Two booted nodes + an opened, confirmed 8e6-sat channel B(LP)→A(hop).
struct Opened {
    regtest: Regtest,
    node_a: HopNode,
    node_b: HopNode,
    funding_txid: bitcoin::Txid,
    funding_vout: u32,
    pk_a: quid_common::api::user::NodePk,
    pk_b: quid_common::api::user::NodePk,
    chan_id: lightning::ln::types::ChannelId,
}

async fn open_channel(port_a: u16, port_b: u16) -> Opened {
    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let node_a = boot_node(&regtest, seed_a, "ade", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "bde", lsp_info(pk_a.clone(), port_a)).await;
    let listener = spawn_listener(&node_a, port_a).await;
    std::mem::forget(listener); // keep A listening for the test's lifetime

    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;
    let conn = connect(&node_b, &pk_a, port_a).await;
    std::mem::forget(conn);
    node_b
        .channel_manager
        .create_channel(pk_a.0, 8_000_000, 0, 1u128, None, None)
        .expect("create_channel");

    let mut usable = false;
    for _ in 0..20 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&node_b).await;
        if !node_a.channel_manager.list_usable_channels().is_empty()
            && !node_b.channel_manager.list_usable_channels().is_empty()
        {
            usable = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
    assert!(usable, "channel never became usable");

    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("one channel");
    let funding_txo = chan.funding_txo.expect("funding txo");
    Opened {
        funding_txid: funding_txo.txid,
        funding_vout: funding_txo.index as u32,
        chan_id: chan.channel_id,
        regtest,
        node_a,
        node_b,
        pk_a,
        pk_b,
    }
}

/// Relay regtest headers into the gateway until it covers `target_height` + 6.
async fn relay_until<R: JsonRpc + Send + Sync + 'static>(
    cfg: &BridgeConfig,
    rpc: Arc<R>,
    esplora: Arc<quid_ln::esplora::Esplora>,
    evm: Arc<JsonRpcEvmClient<R, LocalSigner>>,
    spv_gateway: Address,
    target_height: u64,
) {
    let headers = Arc::new(EsploraHeaderSource::new(esplora, Handle::current()));
    // Fresh in-memory store (inflight=0 ⇒ relayer never defers; H-4 no-op in test).
    let store = Arc::new(quid_bridge::store::BridgeStore::load(None).unwrap());
    let relayer = tokio::spawn(run_spv_relayer(cfg.clone(), rpc.clone(), headers, evm, store));
    for _ in 0..120 {
        let rpc = rpc.clone();
        let h = tokio::task::spawn_blocking(move || read_gateway_height(&*rpc, spv_gateway))
            .await
            .unwrap()
            .unwrap_or(0);
        if h >= target_height + 6 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    relayer.abort();
}

/// Read `channels(channelId).status` (word[4]) via eth_call.
fn channel_status<R: JsonRpc>(rpc: &R, btc_channels: Address, cid: [u8; 32]) -> u8 {
    let sel = &keccak256("channels(bytes32)")[..4];
    let mut data = sel.to_vec();
    data.extend_from_slice(&cid);
    let ret = rpc
        .call(
            "eth_call",
            json!([{ "to": btc_channels.to_string(), "data": format!("0x{}", hex::encode(&data)) }, "latest"]),
        )
        .unwrap();
    let bytes = hex::decode(ret.as_str().unwrap().trim_start_matches("0x")).unwrap();
    bytes[159]
}

/// Full lifecycle against a REAL EVM: open the channel on-chain via lpAuth
/// (drive_open), assert it's OPEN, then cooperatively close it on Lightning and
/// record the close (drive_close), assert it's CLOSED. recordClose requires the
/// channel to be open on-chain first, so this single flow is the correct shape.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn channel_lifecycle_open_then_close_on_real_evm() {
    let Some(env) = evm_env() else {
        eprintln!("driver_e2e: QUID_* EVM env unset — skipping (run via regtest/driver-e2e.sh)");
        return;
    };
    let mut o = open_channel(19_870, 19_871).await;

    // (B) No lpAuth responder — the LP runs nothing. The LP is a pure EVM identity that
    // signs a COLD delegation authorizing the hop (the tx submitter); the vault registry
    // resolves lpEth from the funding outpoint, so drive_open needs no LN round-trip.
    let lp_evm_key = bitcoin::secp256k1::SecretKey::from_slice(&[0x42u8; 32]).unwrap();
    let secp = bitcoin::secp256k1::Secp256k1::new();
    let lp_eth = {
        let pk = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &lp_evm_key);
        Address::from_slice(&keccak256(&pk.serialize_uncompressed()[1..])[12..])
    };
    let btc_recipient = [0x11u8; 32]; // LP payout key (open test)

    let rpc = Arc::new(HttpJsonRpc::new(env.cfg.rpc_url.clone()));
    let mk_evm = || {
        Arc::new(JsonRpcEvmClient::new(
            HttpJsonRpc::new(env.cfg.rpc_url.clone()),
            LocalSigner::from_secret_key_bytes(env.hot_key).expect("hot key"),
            env.cfg.clone(),
        ))
    };

    // channelId: both sides derive the same sorted 2-of-2 pair from their monitor.
    let (pa, pb) = channel_funding_pubkeys(
        &o.node_a.chain_monitor, &o.node_a.channel_manager, o.funding_txid, o.funding_vout,
    ).expect("funding pubkeys");
    let (k0, k1) = sort_funding_pubkeys(pa, pb);
    let cid = channel_id(&k0, &k1, txid_internal(&o.funding_txid), o.funding_vout);
    let funding_height = o.node_b.esplora.client()
        .get_tx_status(&o.funding_txid).await.unwrap().block_height.unwrap() as u64;

    // ── 1. OPEN (B): register the LP's cold delegation, bind funding→lpEth (what the
    //    vault orchestrator does), then drive openChannel(lpEth) — no lpAuth round-trip. ──
    relay_until(&env.cfg, rpc.clone(), o.node_b.esplora.clone(), mk_evm(), env.spv_gateway, funding_height).await;
    let hop_addr = mk_evm().address();
    // (E157) THE REGISTRATION TX IS GONE — `e0fed54` folded delegation INTO the open ("the
    // registration tx goes"), and `registerDelegation` no longer exists on `BTCChannels`, so
    // signing a delegation digest and sending it here could only revert on a deleted selector.
    // Consent now RIDES WITH the open as an `OpenAuth` + a pre-signed `ExitArming` ladder that
    // the fleet RELAYS and cannot synthesise, because it holds no LP funding half.
    //
    // 🔴 SO THIS TEST IS STILL INCOMPLETE, AND IS LEFT VISIBLY SO RATHER THAN LOOKING FIXED.
    // `drive_open` (`channel_driver.rs:741`) requires `registry.consent_for_funding(..)` and
    // refuses the open without it; this harness only calls `bind_funding` below. Completing it
    // needs REAL fixtures — an LP signature over `openAuthDigest` plus ladder rungs spending
    // the 2-of-2 — which cannot be stubbed without defeating what the test proves.
    // ⚠️ Whoever runs `regtest/driver-e2e.sh` will now fail at the CONSENT check, which is the
    // honest next problem. Before this change they would have failed on a deleted selector
    // first and spent the time debugging the wrong layer.
    let registry = quid_bridge::vault::VaultRegistry::new();
    registry.bind_funding(&o.funding_txid.to_string(), o.funding_vout, lp_eth);
    warm_twap_window(&*rpc); // else openChannel→registerBtcLp reverts "twap: pre-history"
    drive_open(
        Arc::new(env.cfg.clone()), mk_evm(), rpc.clone(),
        o.node_a.esplora.clone(), o.node_a.chain_monitor.clone(), o.node_a.channel_manager.clone(),
        registry, o.funding_txid, o.funding_vout,
    ).await.expect("drive_open B: delegation + registry + openChannel on real BTCChannels");

    // amountSats != 0 (exists) AND status == 0 (STATUS_OPEN).
    let sel = &keccak256("channels(bytes32)")[..4];
    let mut data = sel.to_vec();
    data.extend_from_slice(&cid);
    let ret = rpc.call(
        "eth_call",
        json!([{ "to": env.cfg.btc_channels.to_string(), "data": format!("0x{}", hex::encode(&data)) }, "latest"]),
    ).unwrap();
    let bytes = hex::decode(ret.as_str().unwrap().trim_start_matches("0x")).unwrap();
    assert!(U256::from_be_slice(&bytes[0..32]) != U256::ZERO, "channel must exist on-chain after drive_open");
    assert_eq!(bytes[159], 0, "channel must be STATUS_OPEN after drive_open");

    // ── 2. CLOSE: cooperative close on LN → confirm → relay → drive recordClose ──
    o.node_b.channel_manager.close_channel(&o.chan_id, &o.pk_a.0).expect("close_channel");
    for _ in 0..60 {
        if o.regtest.mempool_len() > 0 { break; }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    o.regtest.mine(8);
    ldk_resync(&o.node_a).await;
    ldk_resync(&o.node_b).await;

    let close_txid = o.node_b.esplora.client()
        .get_output_status(&o.funding_txid, o.funding_vout as u64).await.unwrap().unwrap().txid.unwrap();
    let close_height = o.node_b.esplora.client()
        .get_tx_status(&close_txid).await.unwrap().block_height.unwrap() as u64;
    relay_until(&env.cfg, rpc.clone(), o.node_b.esplora.clone(), mk_evm(), env.spv_gateway, close_height).await;
    drive_close(
        Arc::new(env.cfg.clone()), mk_evm(), rpc.clone(),
        o.node_b.esplora.clone(), o.funding_txid, o.funding_vout,
        None, // never-spliced channel → recompute the id from the STORED keys below
        // The channel's funding pubkeys, read from LDK (NOT the close witness — a
        // taproot key-path close has no witnessScript). drive_close recomputes the
        // stable channelId from these for the never-spliced (known_cid=None) path.
        Some((pa, pb)),
        None, // no pre-observed close txid (e2e/live path) → poll esplora for the spend
    ).await.expect("drive_close: recordClose on real BTCChannels");

    // STATUS_CLOSED == 2.
    assert_eq!(
        channel_status(&*rpc, env.cfg.btc_channels, cid), 2,
        "channel must be STATUS_CLOSED on-chain after drive_close"
    );

    let Opened { node_a, node_b, regtest, .. } = o;
    drop(node_a); drop(node_b); drop(regtest);
}

/// Read `pendingOnchainSwapOut(swapId).swapper != 0` (the obligation exists, i.e. the
/// swap-out is recorded and NOT yet delivered).
fn pending_swapper_nonzero<R: JsonRpc>(rpc: &R, btc_channels: Address, swap_id: [u8; 32]) -> bool {
    let sel = &keccak256("pendingOnchainSwapOut(bytes32)")[..4];
    let mut data = sel.to_vec();
    data.extend_from_slice(&swap_id);
    let ret = rpc
        .call(
            "eth_call",
            json!([{ "to": btc_channels.to_string(), "data": format!("0x{}", hex::encode(&data)) }, "latest"]),
        )
        .unwrap();
    let bytes = hex::decode(ret.as_str().unwrap().trim_start_matches("0x")).unwrap();
    bytes.len() >= 32 && bytes[12..32].iter().any(|b| *b != 0)
}

/// The recorded `sats` obligation for `swap_id` — word 1 (uint96, right-aligned) of
/// `pendingOnchainSwapOut(bytes32) → (address swapper, uint96 sats, bytes32 hash)`. On
/// the REAL Vault this is the curve fill (creditSwapOut), not a hard-coded constant.
fn read_swap_out_sats<R: JsonRpc>(rpc: &R, btc_channels: Address, swap_id: [u8; 32]) -> u64 {
    let sel = &keccak256("pendingOnchainSwapOut(bytes32)")[..4];
    let mut data = sel.to_vec();
    data.extend_from_slice(&swap_id);
    let ret = rpc
        .call(
            "eth_call",
            json!([{ "to": btc_channels.to_string(), "data": format!("0x{}", hex::encode(&data)) }, "latest"]),
        )
        .unwrap();
    let bytes = hex::decode(ret.as_str().unwrap().trim_start_matches("0x")).unwrap();
    let mut b = [0u8; 8];
    b.copy_from_slice(&bytes[56..64]); // uint96 < 2^64 sits in the low 8 bytes of word 1
    u64::from_be_bytes(b)
}

/// Advance the anvil EVM clock past the 1800s TWAP window so `registerBtcLp`'s oracle
/// read (`OracleLib.observe` over QU!D's OWN observation ring) finds the deploy-time
/// observation IN-window instead of reverting `twap: pre-history`. The DriverE2E deploy
/// seeds obs[0] via its `mint`; a fresh anvil clock leaves `now ≈ obs[0]`, so a 1800s
/// look-back predates the oldest observation. The forge suite does the equivalent with
/// `vm.warp(15 min)` between ops; here we bump the live anvil clock once before the open.
/// (Kept just over 1800s so the fork's frozen Chainlink feed stays within its heartbeat.)
fn warm_twap_window<R: JsonRpc>(rpc: &R) {
    let _ = rpc.call("evm_increaseTime", json!([1801]));
    let _ = rpc.call("evm_mine", json!([]));
}

/// The on-chain `channels(bytes32) → (uint amountSats, …)` size — word 0 of the flat
/// BTCChannel tuple. Used to prove a withdrawal shrank the channel on-chain.
fn read_channel_amount_sats<R: JsonRpc>(rpc: &R, btc_channels: Address, cid: [u8; 32]) -> u128 {
    let sel = &keccak256("channels(bytes32)")[..4];
    let mut data = sel.to_vec();
    data.extend_from_slice(&cid);
    let ret = rpc
        .call(
            "eth_call",
            json!([{ "to": btc_channels.to_string(), "data": format!("0x{}", hex::encode(&data)) }, "latest"]),
        )
        .unwrap();
    let bytes = hex::decode(ret.as_str().unwrap().trim_start_matches("0x")).unwrap();
    let mut b = [0u8; 16];
    b.copy_from_slice(&bytes[16..32]); // amountSats < 2^128 sits in the low 16 bytes of word 0
    u128::from_be_bytes(b)
}

/// (B) On-chain swap-out (rail B) on a REAL EVM + a REAL Lightning splice: the swapper
/// commits USD via `requestSwapOutOnchain`; the FLEET VAULT delivers via a
/// swapper-directed splice-out of its OWN channel (real LDK splice + co-sign on
/// regtest) — NO LP responder, NO lpAuth — and settles the 6-arg `deliverSwapOutOnchain`
/// as the channel hop. Exercises the production B deliver machinery end-to-end:
/// `VaultNode::deliver_swap_out` (on-chain-cid → vault LDK channel map + SpliceOut init),
/// `run_vault_delivery_correlator` (Spliced → outpoint), the contract's swapper-output
/// SPV verification + settlement — against the REAL Vault curve (no double): the swapper's
/// USD is filled by creditSwapOut, the obligation is the real fill, and delivery settles
/// the LP's proceeds from POOLED_USD_BTC.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn swap_out_onchain_delivery_on_real_evm() {
    let Some(env) = evm_env() else {
        eprintln!("driver_e2e: QUID_* EVM env unset — skipping (run via regtest/driver-e2e.sh)");
        return;
    };
    let o = open_channel(19_872, 19_873).await;

    // The LP is a pure EVM identity (cold delegation); node_b is the fleet VAULT that
    // holds the LP-side channel keys, node_a is the hop.
    let lp_evm_key = bitcoin::secp256k1::SecretKey::from_slice(&[0x42u8; 32]).unwrap();
    let secp = bitcoin::secp256k1::Secp256k1::new();
    let lp_eth = {
        let pk = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &lp_evm_key);
        Address::from_slice(&keccak256(&pk.serialize_uncompressed()[1..])[12..])
    };
    let btc_recipient = [0x11u8; 32];

    let rpc = Arc::new(HttpJsonRpc::new(env.cfg.rpc_url.clone()));
    let mk_evm = || {
        Arc::new(JsonRpcEvmClient::new(
            HttpJsonRpc::new(env.cfg.rpc_url.clone()),
            LocalSigner::from_secret_key_bytes(env.hot_key).expect("hot key"),
            env.cfg.clone(),
        ))
    };

    let (pa, pb) = channel_funding_pubkeys(
        &o.node_a.chain_monitor, &o.node_a.channel_manager, o.funding_txid, o.funding_vout,
    ).expect("funding pubkeys");
    let (k0, k1) = sort_funding_pubkeys(pa, pb);
    let cid = channel_id(&k0, &k1, txid_internal(&o.funding_txid), o.funding_vout);
    let funding_height = o.node_b.esplora.client()
        .get_tx_status(&o.funding_txid).await.unwrap().block_height.unwrap() as u64;

    // ── 1. OPEN (B): register the LP's cold delegation + drive openChannel(lpEth). ──
    relay_until(&env.cfg, rpc.clone(), o.node_b.esplora.clone(), mk_evm(), env.spv_gateway, funding_height).await;
    let hop_addr = mk_evm().address();
    // (E157) THE REGISTRATION TX IS GONE — `e0fed54` folded delegation INTO the open ("the
    // registration tx goes"), and `registerDelegation` no longer exists on `BTCChannels`, so
    // signing a delegation digest and sending it here could only revert on a deleted selector.
    // Consent now RIDES WITH the open as an `OpenAuth` + a pre-signed `ExitArming` ladder that
    // the fleet RELAYS and cannot synthesise, because it holds no LP funding half.
    //
    // 🔴 SO THIS TEST IS STILL INCOMPLETE, AND IS LEFT VISIBLY SO RATHER THAN LOOKING FIXED.
    // `drive_open` (`channel_driver.rs:741`) requires `registry.consent_for_funding(..)` and
    // refuses the open without it; this harness only calls `bind_funding` below. Completing it
    // needs REAL fixtures — an LP signature over `openAuthDigest` plus ladder rungs spending
    // the 2-of-2 — which cannot be stubbed without defeating what the test proves.
    // ⚠️ Whoever runs `regtest/driver-e2e.sh` will now fail at the CONSENT check, which is the
    // honest next problem. Before this change they would have failed on a deleted selector
    // first and spent the time debugging the wrong layer.
    let registry = quid_bridge::vault::VaultRegistry::new();
    registry.bind_funding(&o.funding_txid.to_string(), o.funding_vout, lp_eth);
    warm_twap_window(&*rpc); // else openChannel→registerBtcLp reverts "twap: pre-history"
    drive_open(
        Arc::new(env.cfg.clone()), mk_evm(), rpc.clone(),
        o.node_a.esplora.clone(), o.node_a.chain_monitor.clone(), o.node_a.channel_manager.clone(),
        registry, o.funding_txid, o.funding_vout,
    ).await.expect("drive_open B");
    eprintln!("PROOF 1/5: channel opened on REAL BTCChannels via delegation (no lpAuth)");

    // ── 2. SWAPPER commits USD → requestSwapOutOnchain on the REAL Vault. The fill is a
    //    real BTC-curve quote, so `sats` is READ BACK from the recorded obligation. ──
    let mut swapper_script: Vec<u8> = vec![0x00u8, 0x14]; // P2WPKH
    swapper_script.extend_from_slice(&[0x5Au8; 20]);
    let swap_id = [0xC1u8; 32];
    let usdc: Address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".parse().unwrap();
    // 500 USDC (6-dec). The proven amount every forge swap-out test uses (Alles /
    // BtcLpMintStress): a real Uniswap-V4 exact-input buy this small must clear the
    // pool's tick math — a dust-sized 5-USDC buy hits a round-to-zero edge in the V4
    // PoolManager and reverts with EMPTY data on some fork blocks. 500 USDC ≈ 500k sats,
    // still well within the 8e6-sat channel.
    let usd_amount = U256::from(500_000_000u64);
    let cd = encode_request_swap_out_onchain(usdc, usd_amount, 0, swap_id, &swapper_script);
    let landed = mk_evm().send_tx(env.cfg.btc_channels, cd.clone(), env.cfg.gas_limit).expect("requestSwapOutOnchain send");
    if !landed {
        let from = mk_evm().address();
        let reason = rpc.call("eth_call", json!([{ "from": format!("{from:?}"), "to": env.cfg.btc_channels.to_string(), "data": format!("0x{}", hex::encode(&cd)) }, "latest"]))
            .map(|v| v.as_str().unwrap_or_default().to_string()).unwrap_or_else(|e| e.to_string());
        panic!("requestSwapOutOnchain reverted: {reason}");
    }
    assert!(pending_swapper_nonzero(&*rpc, env.cfg.btc_channels, swap_id), "swap-out obligation recorded");
    let _ = rpc.call("anvil_mine", json!(["0x8"])); // bury past the agreed-read depth
    let sats = read_swap_out_sats(&*rpc, env.cfg.btc_channels, swap_id);
    assert!(sats > 0 && (sats as u128) < 8_000_000, "real curve fill fits the channel: {sats} sats");
    eprintln!("PROOF 2/5: requestSwapOutOnchain recorded a real curve fill of {sats} sats");

    // ── 3. VAULT deliver (B): wrap node_b as the fleet vault, spawn the delivery
    //    correlator, and initiate the swapper-directed splice-out. The vault holds the
    //    LP-side keys and splices its OWN channel — no LP round-trip, no lpAuth. ──
    let Opened { node_a, node_b, regtest, pk_a, .. } = o;
    let mut vault = VaultNode::from_node(node_b, pk_a.0, SPLICE_FUNDING_FEERATE_SAT_PER_KW);
    let lifecycle_rx = vault.take_lifecycle_rx();
    let vault = Arc::new(vault);
    tokio::spawn(run_vault_delivery_correlator(lifecycle_rx, vault.deliveries.clone()));

    let deliver_task = {
        let v = vault.clone();
        let script = swapper_script.clone();
        tokio::spawn(async move {
            v.deliver_swap_out(cid, sats, script, Duration::from_secs(120)).await
        })
    };

    // ── 4. Mine + resync until the splice locks; the correlator resolves the outpoint. ──
    for _ in 0..160 { if regtest.mempool_len() > 0 { break; } tokio::time::sleep(Duration::from_millis(250)).await; }
    let mut outpoint: Option<(bitcoin::Txid, u32)> = None;
    for _ in 0..25 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&vault.node).await;
        if deliver_task.is_finished() { break; }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
    match deliver_task.await.expect("deliver task join") {
        Ok(op) => outpoint = Some(op),
        Err(e) => panic!("vault.deliver_swap_out failed: {e:#}"),
    }
    let (splice_txid, splice_vout) = outpoint.expect("splice locked");
    eprintln!("PROOF 3/5: VAULT splice-out LOCKED at {splice_txid}:{splice_vout} (correlator resolved)");

    // ── 5. Bury the splice + relay it to the gateway (SPV proof needs tip ≥ height+6). ──
    regtest.mine(8);
    ldk_resync(&node_a).await;
    ldk_resync(&vault.node).await;
    let splice_height = vault.node.esplora.client()
        .get_tx_status(&splice_txid).await.unwrap().block_height.unwrap() as u64;
    relay_until(&env.cfg, rpc.clone(), vault.node.esplora.clone(), mk_evm(), env.spv_gateway, splice_height).await;

    // ── 6. Submit the 6-arg deliverSwapOutOnchain (as the hop) — rebuild params from the
    //    POST-splice funding pubkeys (LDK rotates the 2-of-2 on every splice). ──
    let (spa, spb) = channel_funding_pubkeys(&node_a.chain_monitor, &node_a.channel_manager, splice_txid, splice_vout)
        .expect("post-splice funding pubkeys");
    let (params, raw, proof) = build_splice_params(&node_a.esplora, &splice_txid, splice_vout, spa, spb)
        .await.expect("rebuild splice params");
    let cd = encode_deliver_swap_out_onchain(swap_id, cid, &params, &raw, &proof, &swapper_script);
    let landed = mk_evm().send_tx(env.cfg.btc_channels, cd.clone(), env.cfg.gas_limit).expect("deliverSwapOutOnchain send");
    if !landed {
        let from = mk_evm().address();
        let reason = rpc.call("eth_call", json!([{ "from": format!("{from:?}"), "to": env.cfg.btc_channels.to_string(), "data": format!("0x{}", hex::encode(&cd)) }, "latest"]))
            .map(|v| v.as_str().unwrap_or_default().to_string()).unwrap_or_else(|e| e.to_string());
        panic!("deliverSwapOutOnchain reverted: {reason}");
    }
    eprintln!("PROOF 4/5: deliverSwapOutOnchain LANDED (SPV-verified the real splice tx, hop-gated, no lpAuth)");

    // ── 7. pendingOnchainSwapOut cleared ⇒ delivered. ──
    assert!(!pending_swapper_nonzero(&*rpc, env.cfg.btc_channels, swap_id), "swap-out delivered: obligation cleared");
    eprintln!("PROOF 5/5: pendingOnchainSwapOut CLEARED ⇒ rail-B delivered end-to-end (vault splice + on-chain settle)");

    drop(node_a); drop(vault); drop(regtest);
}

/// (B) RAW-BTC LP WITHDRAWAL on a REAL EVM + a REAL Lightning splice. The LP elected
/// [`PayoutMode::RawBtc`]: the fleet vault calls the PRODUCTION `VaultNode::withdraw_raw_btc`
/// to splice its channel balance straight out to the LP's on-chain-committed `btcRecipient`,
/// and the hop mirrors the SHRINK with the PRODUCTION `drive_splice`. This exercises the
/// EVM `splice → _shrinkSplice → _withdrawalPayout` path — DISTINCT from the swap-out
/// delivery path — whose whole point is that it REVERTS `ForeignSpliceOutput` unless the
/// splice pays exactly `0x5120||btcRecipientOf`. So the on-chain channel shrinking is proof
/// the raw-BTC payout pin was accepted end-to-end (no lpAuth, no responder, fleet-driven).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lp_raw_btc_withdrawal_on_real_evm() {
    let Some(env) = evm_env() else {
        eprintln!("driver_e2e: QUID_* EVM env unset — skipping (run via regtest/driver-e2e.sh)");
        return;
    };
    let o = open_channel(19_874, 19_875).await;

    // A DISTINCT LP identity (cold delegation) — its committed btcRecipient is the payout pin.
    let lp_evm_key = bitcoin::secp256k1::SecretKey::from_slice(&[0x43u8; 32]).unwrap();
    let secp = bitcoin::secp256k1::Secp256k1::new();
    let lp_eth = {
        let pk = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &lp_evm_key);
        Address::from_slice(&keccak256(&pk.serialize_uncompressed()[1..])[12..])
    };
    let btc_recipient = [0x11u8; 32];

    let rpc = Arc::new(HttpJsonRpc::new(env.cfg.rpc_url.clone()));
    let mk_evm = || {
        Arc::new(JsonRpcEvmClient::new(
            HttpJsonRpc::new(env.cfg.rpc_url.clone()),
            LocalSigner::from_secret_key_bytes(env.hot_key).expect("hot key"),
            env.cfg.clone(),
        ))
    };

    let (pa, pb) = channel_funding_pubkeys(
        &o.node_a.chain_monitor, &o.node_a.channel_manager, o.funding_txid, o.funding_vout,
    ).expect("funding pubkeys");
    let (k0, k1) = sort_funding_pubkeys(pa, pb);
    let cid = channel_id(&k0, &k1, txid_internal(&o.funding_txid), o.funding_vout);
    let funding_height = o.node_b.esplora.client()
        .get_tx_status(&o.funding_txid).await.unwrap().block_height.unwrap() as u64;

    // ── 1. OPEN (B): register the LP's cold delegation (pins btcRecipient) + openChannel. ──
    relay_until(&env.cfg, rpc.clone(), o.node_b.esplora.clone(), mk_evm(), env.spv_gateway, funding_height).await;
    let hop_addr = mk_evm().address();
    // (E157) THE REGISTRATION TX IS GONE — `e0fed54` folded delegation INTO the open ("the
    // registration tx goes"), and `registerDelegation` no longer exists on `BTCChannels`, so
    // signing a delegation digest and sending it here could only revert on a deleted selector.
    // Consent now RIDES WITH the open as an `OpenAuth` + a pre-signed `ExitArming` ladder that
    // the fleet RELAYS and cannot synthesise, because it holds no LP funding half.
    //
    // 🔴 SO THIS TEST IS STILL INCOMPLETE, AND IS LEFT VISIBLY SO RATHER THAN LOOKING FIXED.
    // `drive_open` (`channel_driver.rs:741`) requires `registry.consent_for_funding(..)` and
    // refuses the open without it; this harness only calls `bind_funding` below. Completing it
    // needs REAL fixtures — an LP signature over `openAuthDigest` plus ladder rungs spending
    // the 2-of-2 — which cannot be stubbed without defeating what the test proves.
    // ⚠️ Whoever runs `regtest/driver-e2e.sh` will now fail at the CONSENT check, which is the
    // honest next problem. Before this change they would have failed on a deleted selector
    // first and spent the time debugging the wrong layer.
    let registry = quid_bridge::vault::VaultRegistry::new();
    registry.bind_funding(&o.funding_txid.to_string(), o.funding_vout, lp_eth);
    warm_twap_window(&*rpc); // else openChannel→registerBtcLp reverts "twap: pre-history"
    drive_open(
        Arc::new(env.cfg.clone()), mk_evm(), rpc.clone(),
        o.node_a.esplora.clone(), o.node_a.chain_monitor.clone(), o.node_a.channel_manager.clone(),
        registry, o.funding_txid, o.funding_vout,
    ).await.expect("drive_open B");
    let amount_before = read_channel_amount_sats(&*rpc, env.cfg.btc_channels, cid);
    assert!(amount_before > 0, "channel open on-chain");
    eprintln!("PROOF 1/3: channel opened via delegation, on-chain amountSats = {amount_before}");

    // ── 2. RAW-BTC WITHDRAWAL: the fleet vault calls the PRODUCTION withdraw_raw_btc to
    //    splice `withdraw_sats` out to `0x5120||btcRecipient`. We take the vault's lifecycle
    //    stream directly (no correlator) and read the Spliced event's new outpoint. ──
    let Opened { node_a, node_b, regtest, pk_a, .. } = o;
    let mut vault = VaultNode::from_node(node_b, pk_a.0, SPLICE_FUNDING_FEERATE_SAT_PER_KW);
    let mut lifecycle_rx = vault.take_lifecycle_rx();
    let vault = Arc::new(vault);
    let withdraw_sats = 500_000u64; // well within the channel, leaves the reserve
    vault.withdraw_raw_btc(cid, withdraw_sats, btc_recipient).expect("withdraw_raw_btc initiate");

    let mut outpoint: Option<(bitcoin::Txid, u32)> = None;
    for _ in 0..40 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&vault.node).await;
        while let Ok(ev) = lifecycle_rx.try_recv() {
            if let ChannelLifecycleEvent::Spliced { new_funding_txid, new_funding_vout, .. } = ev {
                outpoint = Some((new_funding_txid, new_funding_vout));
            }
        }
        if outpoint.is_some() { break; }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
    let (splice_txid, splice_vout) = outpoint.expect("withdrawal splice locked");
    eprintln!("PROOF 2/3: withdraw_raw_btc splice-out LOCKED at {splice_txid}:{splice_vout}");

    // ── 3. Bury + relay, then the HOP mirrors the shrink with the PRODUCTION drive_splice.
    //    The EVM `_withdrawalPayout` accepts it ONLY if the splice pays btcRecipientOf ⇒
    //    the on-chain amountSats shrinking is the proof the raw-BTC pin was honoured. ──
    regtest.mine(8);
    ldk_resync(&node_a).await;
    ldk_resync(&vault.node).await;
    let splice_height = vault.node.esplora.client()
        .get_tx_status(&splice_txid).await.unwrap().block_height.unwrap() as u64;
    relay_until(&env.cfg, rpc.clone(), vault.node.esplora.clone(), mk_evm(), env.spv_gateway, splice_height).await;
    drive_splice(
        Arc::new(env.cfg.clone()), mk_evm(), rpc.clone(), node_a.esplora.clone(),
        node_a.chain_monitor.clone(), node_a.channel_manager.clone(), cid, splice_txid, splice_vout,
    ).await.expect("drive_splice mirror (withdrawal shrink)");

    let amount_after = read_channel_amount_sats(&*rpc, env.cfg.btc_channels, cid);
    assert!(
        amount_after < amount_before,
        "channel shrank on-chain ({amount_before} → {amount_after}) — _withdrawalPayout accepted the btcRecipient pin"
    );
    eprintln!("PROOF 3/3: EVM mirrored the shrink ({amount_before} → {amount_after}); raw-BTC withdrawal pin accepted end-to-end");

    drop(node_a); drop(vault); drop(regtest);
}
