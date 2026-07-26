//! hop ↔ bridge INTEGRATION test (the previously-missing seam): drives a swap-in
//! end-to-end through the BRIDGE LOOP wired to a REAL hop.
//!
//! Real: bitcoind + electrs + two LDK hop nodes, a funded channel, a genuine
//! Lightning swap-in payment, and the bridge's `run_swap_in_sender` loop wired to
//! the hop's real `swap_in_rx` + `SwapInClaimer` (which calls real `claim_funds`).
//! Stubbed: ONLY the `EvmClient::settle_swap_in` outcome — there is no EVM node in
//! a Lightning-regtest, and the real on-chain leg (settleSwapIn) is covered by the
//! forge `CrossChainSwapOut` test. This proves the LN↔bridge wiring the unit tests
//! (mocked LN) and the forge tests (mocked LN side) each leave untested.
//!
//! Run: `cargo test -p quid-bridge --features harness --test hop_bridge_e2e -- --nocapture`
//! (needs the harness binaries; see quid-hop/tests/e2e.rs).

#![cfg(feature = "harness")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy_primitives::{Address, B256, U256};
use lightning::ln::channelmanager::{PaymentId, Retry};
use lightning::routing::router::RouteParametersConfig;
use quid_common::root_seed::RootSeed;
use quid_hop::harness::{
    bdk_full_sync, boot_node, connect, ldk_resync, lsp_info, spawn_listener, Regtest,
};

use quid_bridge::config::BridgeConfig;
use quid_bridge::evm::{EvmClient, SettleOutcome};
use quid_bridge::header_source::EsploraHeaderSource;
use quid_bridge::swap_in::run_swap_in_sender;

/// Records that the bridge loop actually drove a settle, and returns Delivered so
/// the loop proceeds to claim. (The real on-chain settle is the forge test's job.)
struct DeliveringEvm {
    calls: Mutex<u32>,
}
impl EvmClient for DeliveringEvm {
    fn settle_swap_in(
        &self,
        _: Address,
        _: u64,
        _: Address,
        _: B256,
        _: U256,
        _: bool,
    ) -> anyhow::Result<SettleOutcome> {
        *self.calls.lock().unwrap() += 1;
        // Full fill in the e2e harness — the whole HTLC converted (no partial remainder).
        Ok(SettleOutcome::Delivered { consumed_sats: u64::MAX })
    }
}

/// Always errors the settle (transient) — used to PERSIST a swap-in (handle_one
/// persists BEFORE settling) while never claiming, modelling a crash that struck
/// after the in-flight record hit disk but before the claim landed.
struct ErroringEvm;
impl EvmClient for ErroringEvm {
    fn settle_swap_in(
        &self,
        _: Address,
        _: u64,
        _: Address,
        _: B256,
        _: U256,
        _: bool,
    ) -> anyhow::Result<SettleOutcome> {
        anyhow::bail!("settle RPC down (modelling pre-claim crash window)")
    }
}

fn test_cfg() -> BridgeConfig {
    BridgeConfig {
        rpc_url: String::new(),
        rpc_urls: Vec::new(),
        rpc_quorum: 1,
        chain_id: 1,
        btc_channels: Address::repeat_byte(0xBC),
        min_confirmations: 1,
        min_cltv_headroom_blocks: 40,
        settle_max_retries: 1,
        retry_backoff_secs: 0,
        max_fee_per_gas: 1_000_000_000,
        max_priority_fee_per_gas: 1_000_000,
        gas_limit: 300_000,
        receipt_poll_attempts: 1,
        receipt_poll_secs: 0,
        fee_bump_attempts: 1,
        fee_bump_pct: 125,
        settle_min_confirmations: 1,
        max_log_block_span: 10_000,
        swap_out_poll_secs: 0,
        btc_vault: Address::repeat_byte(0xFA),
        spv_gateway: Address::repeat_byte(0x5B),
        relay_batch_max: 100,
        relay_gas_limit: 5_000_000,
        relay_poll_secs: 0,
        relay_reorg_lookback: 144,
        channel_reconcile_secs: 300,
        relayer_defer_inflight: 0, // test: never defer the relayer on in-flight swaps
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn swap_in_drives_through_the_bridge_loop() {
    let _ = tracing_subscriber::fmt().with_env_filter("info,quid_bridge=debug").try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_852_u16;
    let port_b = 19_853_u16;

    let mut node_a = boot_node(&regtest, seed_a, "ahb", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "bhb", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B, open a 1,000,000-sat channel B→A, confirm it usable.
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;
    let _conn = connect(&node_b, &pk_a, port_a).await;
    node_b
        .channel_manager
        .create_channel(pk_a.0, 1_000_000, 0, 1u128, None, None)
        .expect("create_channel");
    let mut funded = false;
    for _ in 0..60 {
        if regtest.mempool_len() > 0 {
            funded = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(funded, "funding tx never reached the mempool");
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
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(usable, "channel never became usable");

    // ── Wire the BRIDGE swap-in loop to the REAL hop and let IT drive the claim ──
    let evm = Arc::new(DeliveringEvm { calls: Mutex::new(0) });
    let claimer = node_a.swap_in_claimer();
    // Move the real receiver out (swap a dead dummy) so the loop owns it while
    // node_a (its background tasks) stays alive — exactly as the daemon does.
    let swap_in_rx = {
        let (_dead, dummy) = tokio::sync::mpsc::unbounded_channel();
        std::mem::replace(&mut node_a.swap_in_rx, dummy)
    };
    // Increment 1b: the settle-time CLTV re-check reads the LIVE Bitcoin tip via
    // the same EsploraHeaderSource the relayer uses. On regtest a fresh invoice's
    // deadline (tip + SWAP_IN_FINAL_CLTV_DELTA) clears the headroom gate, so the
    // re-check passes and the loop settles+claims as before.
    let btc_tip = Arc::new(EsploraHeaderSource::new(
        node_a.esplora.clone(),
        tokio::runtime::Handle::current(),
    ));
    let store = Arc::new(quid_bridge::store::BridgeStore::load(None).unwrap());
    tokio::spawn(run_swap_in_sender(test_cfg(), evm.clone(), claimer, btc_tip, store, swap_in_rx));

    // A issues a swap-in invoice; B pays it. The hop emits ClaimedSwapIn → the
    // BRIDGE loop settles (DeliveringEvm) → claims via the real SwapInClaimer.
    let amount_sats = 100_000_u64;
    let invoice = node_a
        .issue_swap_in_invoice(
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            amount_sats,
            U256::ZERO,
            "hop-bridge swap-in",
        )
        .expect("issue_swap_in_invoice");
    node_b
        .channel_manager
        .pay_for_bolt11_invoice(
            &invoice,
            PaymentId([7u8; 32]),
            None,
            RouteParametersConfig::default(),
            Retry::Attempts(5),
        )
        .expect("pay_for_bolt11_invoice");

    // Assert the BRIDGE loop drove it: settle was called AND the claim landed
    // (A's outbound capacity rises by ~the swap-in amount — proof claim_funds ran).
    let mut ok = false;
    for _ in 0..60 {
        let settled = *evm.calls.lock().unwrap() >= 1;
        let a_out = node_a
            .channel_manager
            .list_channels()
            .first()
            .map(|c| c.outbound_capacity_msat)
            .unwrap_or(0);
        if settled && a_out > 50_000_000 {
            // > 50k sat
            ok = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(
        ok,
        "bridge loop must settle (DeliveringEvm called) AND claim (A's outbound rose) — \
         proving the hop→swap_in_rx→run_swap_in_sender→SwapInClaimer wiring"
    );

    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// PRODUCTION RE-DRIVE (the durability fix), end-to-end through the REAL bridge loop
/// with NO manual claim:
///   1. A real swap-in is paid; the bridge loop (ErroringEvm) PERSISTS the in-flight
///      swap-in to an on-disk BridgeStore BEFORE settling, but its settle keeps
///      failing so it never claims — modelling a crash in the settle→claim window.
///   2. The loop is dropped (crash). The on-disk store still holds the in-flight
///      swap-in (LDK does NOT re-emit PaymentClaimable — verified separately).
///   3. A SECOND `run_swap_in_sender` is started with a FRESH store loaded from the
///      SAME path + a DeliveringEvm. Its BOOT RE-DRIVE re-loads `inflight_swapins()`
///      and AUTO settles+claims — no manual `claim_funds`, no replayed LDK event.
/// Proves the gap is closed: a precisely-timed crash no longer strands the BTC HTLC.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn crash_in_settle_claim_window_is_redriven_on_boot() {
    let _ = tracing_subscriber::fmt().with_env_filter("info,quid_bridge=debug").try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_862_u16;
    let port_b = 19_863_u16;

    let mut node_a = boot_node(&regtest, seed_a, "are", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "bre", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;
    let _conn = connect(&node_b, &pk_a, port_a).await;
    node_b
        .channel_manager
        .create_channel(pk_a.0, 1_000_000, 0, 1u128, None, None)
        .expect("create_channel");
    let mut funded = false;
    for _ in 0..60 {
        if regtest.mempool_len() > 0 {
            funded = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(funded, "funding tx never reached the mempool");
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
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(usable, "channel never became usable");

    let a_outbound_before = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;

    // On-disk store shared across the "crash" + "reboot".
    let store_path = std::env::temp_dir().join(format!(
        "quid-bridge-redrive-e2e-{}.json",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&store_path);

    // ── Run 1: the bridge loop persists the swap-in but its settle FAILS (no claim) ──
    let store1 = Arc::new(quid_bridge::store::BridgeStore::load(Some(store_path.clone())).unwrap());
    let claimer1 = node_a.swap_in_claimer();
    let swap_in_rx = {
        let (_dead, dummy) = tokio::sync::mpsc::unbounded_channel();
        std::mem::replace(&mut node_a.swap_in_rx, dummy)
    };
    let btc_tip = Arc::new(EsploraHeaderSource::new(
        node_a.esplora.clone(),
        tokio::runtime::Handle::current(),
    ));
    let run1 = tokio::spawn(run_swap_in_sender(
        test_cfg(),
        Arc::new(ErroringEvm),
        claimer1,
        btc_tip.clone(),
        store1.clone(),
        swap_in_rx,
    ));

    let amount_sats = 100_000_u64;
    let invoice = node_a
        .issue_swap_in_invoice(
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            amount_sats,
            U256::ZERO,
            "redrive swap-in",
        )
        .expect("issue_swap_in_invoice");
    let payment_hash: [u8; 32] = *invoice.payment_hash().as_ref();
    node_b
        .channel_manager
        .pay_for_bolt11_invoice(
            &invoice,
            PaymentId([9u8; 32]),
            None,
            RouteParametersConfig::default(),
            Retry::Attempts(5),
        )
        .expect("pay_for_bolt11_invoice");

    // Wait until the loop has PERSISTED the in-flight swap-in (it does so before the
    // failing settle). The settle keeps erroring, so it never claims.
    let mut persisted = false;
    for _ in 0..60 {
        if store1.has_inflight_swapin(&payment_hash) {
            persisted = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(persisted, "swap-in must be persisted BEFORE the (failing) settle");
    // The BTC was NOT taken (no claim happened — settle never succeeded).
    let a_out_after_run1 = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;
    assert!(
        a_out_after_run1 < a_outbound_before + amount_sats * 1000 / 2,
        "no claim happened in run 1 (settle failed) — BTC still held by the seller's HTLC"
    );

    // ── CRASH: drop the loop (abort the task). The on-disk store survives. ──
    run1.abort();
    tokio::time::sleep(Duration::from_secs(1)).await;

    // ── Run 2 (REBOOT): fresh store from the SAME path + a working EVM. The BOOT
    // RE-DRIVE auto-settles+claims the persisted swap-in. NO manual claim_funds. ──
    let store2 = Arc::new(quid_bridge::store::BridgeStore::load(Some(store_path.clone())).unwrap());
    assert!(
        store2.has_inflight_swapin(&payment_hash),
        "post-reboot the persisted swap-in is still in the durable store"
    );
    assert_eq!(store2.inflight_swapins().len(), 1, "exactly one in-flight swap-in to re-drive");

    let evm2 = Arc::new(DeliveringEvm { calls: Mutex::new(0) });
    let claimer2 = node_a.swap_in_claimer();
    let (_dead, dummy_rx) = tokio::sync::mpsc::unbounded_channel(); // no live ingrid — boot re-drive only
    let _run2 = tokio::spawn(run_swap_in_sender(
        test_cfg(),
        evm2.clone(),
        claimer2,
        btc_tip,
        store2.clone(),
        dummy_rx,
    ));

    // The boot re-drive settles (DeliveringEvm) AND claims (A's outbound rises),
    // WITHOUT any manual claim or replayed LDK event — and clears the durable record.
    let want_min_growth = amount_sats * 1000 * 80 / 100;
    let mut redriven = false;
    for _ in 0..60 {
        let settled = *evm2.calls.lock().unwrap() >= 1;
        let a_out = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;
        if settled
            && a_out >= a_outbound_before + want_min_growth
            && !store2.has_inflight_swapin(&payment_hash)
        {
            redriven = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(
        redriven,
        "BOOT RE-DRIVE must auto settle+claim the persisted swap-in (no manual claim) \
         and clear the durable record — proving the settle→claim crash window is covered"
    );

    let _ = std::fs::remove_file(&store_path);
    drop(node_a);
    drop(node_b);
    drop(regtest);
}
