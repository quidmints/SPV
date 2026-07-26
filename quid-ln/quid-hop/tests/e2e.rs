//! Regtest end-to-end test for the hop node.
//!
//! Spins up a real `bitcoind` (auto-downloaded) + Blockstream esplora-electrs
//! (serves the REST API our `Esplora` client speaks), boots two `HopNode`s
//! against it, and drives the production paths that unit tests can't reach:
//! booting against a live esplora, BDK on-chain sync, P2P connect, channel
//! open + on-chain funding/confirmation, and a swap-in payment claim.
//!
//! Built incrementally; each stage is a separate `#[tokio::test]` so a failure
//! localizes. The expensive bit (downloading bitcoind + electrs) happens once.
//!
//! Run with `cargo test -p quid-hop --test e2e --features harness -- --nocapture`.
//!
//! The regtest backend (`Regtest`) + the node boot/connect/sync helpers were
//! factored into `quid_hop::harness` (feature `harness`) so this test AND the
//! `e2e_ffi` bin share one definition. The whole file is therefore gated on that
//! feature; without it the test compiles to nothing (the harness deps aren't
//! pulled).

#![cfg(feature = "harness")]

use std::time::Duration;

use lightning::{
    ln::channelmanager::{PaymentId, Retry},
    routing::router::RouteParametersConfig,
    types::payment::PaymentPreimage,
};
use quid_common::root_seed::RootSeed;
use quid_hop::{
    event_handler::ChannelLifecycleEvent,
    harness::{
        bdk_full_sync, boot_node, connect, ldk_resync, lsp_info, reboot_node, spawn_listener,
        Regtest,
    },
};

/// Stage 1: infra comes up, two nodes boot against the live esplora, and a
/// node's BDK wallet sees on-chain funds after mining + a resync. This alone
/// exercises `boot()` against a real esplora — the largest surface that unit
/// tests can't reach.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage1_boot_and_fund() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();

    // Pre-derive each node's pubkey so they can reference each other as LSP
    // without a boot-order chicken-and-egg.
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();

    // Ports the nodes' P2P listeners will use in later stages.
    let port_a = 19_846_u16;
    let port_b = 19_847_u16;

    let node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;

    assert_eq!(node_a.node_pk(), pk_a, "node A pk matches pre-derivation");
    assert_eq!(node_b.node_pk(), pk_b, "node B pk matches pre-derivation");

    // Fund node B's on-chain wallet: 101 blocks to its address matures one
    // coinbase (spendable to fund a channel in stage 2).
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);

    bdk_full_sync(&node_b).await;

    let bal = node_b.wallet.get_balance();
    assert!(
        bal.confirmed.to_sat() > 0,
        "node B should have confirmed on-chain funds, got {bal:?}"
    );

    // Keep the backend alive until here.
    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// M8 SIMPLE-TAPROOT open + cooperative close (NO HTLC, NO splice) against real
/// bitcoind/esplora. This is the minimal end-to-end proof that a QU!D channel —
/// which `build_user_config()` opts into `option_simple_taproot` — opens with a
/// real **P2TR `0x5120||Q`** funding output and cooperatively closes with a
/// single 64-byte BIP340 key-path Schnorr witness, all driven by the production
/// MuSig2 `ValidatingChannelSigner` over a live node. (The swap-in legs in the
/// later stages exercise HTLCs, which are a deferred taproot milestone; this
/// stage stays HTLC-free so it is green today.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage_taproot_open_coop_close() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    // Ports distinct from the other stages so a parallel test run can't collide.
    let port_a = 19_866_u16;
    let port_b = 19_867_u16;

    let node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B so it can fund the channel.
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    assert!(node_b.wallet.get_balance().confirmed.to_sat() > 0, "B funded");

    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // B opens a channel to A — `create_channel` uses B's production config, which
    // negotiates `option_simple_taproot` (node::build_user_config).
    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
        .expect("create_channel");

    // Funding tx → mempool.
    let mut funded = false;
    for _ in 0..60 {
        if regtest.mempool_len() > 0 {
            funded = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(funded, "funding tx never reached the mempool");

    // Confirm + make usable on both sides.
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
    assert!(usable, "channel never became usable on both nodes");

    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("one channel");
    let ldk_channel_id = chan.channel_id;
    let funding_txo = chan.funding_txo.expect("funding txo set after confirm");
    let funding_txid = bitcoin::Txid::from_raw_hash(*funding_txo.txid.as_raw_hash());

    // The funding output is a real P2TR `0x5120||Q` (the MuSig2 key-path aggregate).
    // Pull the funding tx from esplora and locate the output by its taproot SPK,
    // exactly as the EVM-bound `evm_codec` does.
    let client = node_b.esplora.client().clone();
    let funding_inc = quid_hop::evm_codec::tx_inclusion(&node_b.esplora, &funding_txid)
        .await
        .expect("funding inclusion");
    let (holder_pk, cp_pk) = quid_hop::node::channel_funding_pubkeys(
        &node_b.chain_monitor,
        &node_b.channel_manager,
        funding_txid,
        funding_txo.index as u32,
    )
    .expect("funding pubkeys from monitor (witness-free, taproot key-path)");
    let (lp_pubkey, hop_pubkey) = quid_hop::evm_codec::sort_funding_pubkeys(holder_pk, cp_pk);
    let (_vout, _amt) =
        quid_hop::evm_codec::funded_output_taproot(&funding_inc.raw, &lp_pubkey, &hop_pubkey)
            .expect("funding output is P2TR 0x5120||Q");

    // COOPERATIVE CLOSE: B initiates; both background loops negotiate
    // shutdown → closing_signed (MuSig2 key-path partials) → broadcast.
    node_b
        .channel_manager
        .close_channel(&ldk_channel_id, &pk_a.0)
        .expect("close_channel");

    let mut closing = false;
    for _ in 0..160 {
        if regtest.mempool_len() > 0 {
            closing = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(closing, "cooperative closing tx never reached the mempool");

    // Confirm + resync so the close is deeply buried, then verify on-chain.
    regtest.mine(8);
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // The close spends the funding output; fetch it and assert a key-path spend:
    // exactly ONE input, ONE witness element, 64 bytes (BIP340 Schnorr) — the
    // simple-taproot cooperative-close shape.
    let outspend = client
        .get_output_status(&funding_txid, funding_txo.index as u64)
        .await
        .expect("get_output_status")
        .expect("funding output has a status");
    assert!(outspend.spent, "funding output spent by the cooperative close");
    let close_txid = outspend.txid.expect("close txid");
    let close_tx = client
        .get_tx(&close_txid)
        .await
        .expect("get close tx")
        .expect("close tx present");
    assert_eq!(close_tx.input.len(), 1, "close spends the single funding input");
    let witness = &close_tx.input[0].witness;
    assert_eq!(witness.len(), 1, "taproot key-path spend = one witness element");
    assert_eq!(
        witness.to_vec()[0].len(),
        64,
        "BIP340 key-path Schnorr signature is 64 bytes"
    );

    // The channel is gone on both sides.
    assert!(node_b.channel_manager.list_channels().is_empty(), "B closed the channel");

    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// Stages 2+3: the full hop lifecycle against real bitcoind/esplora. B funds +
/// opens a channel to A over P2P (using B's own production config — proving the
/// symmetric `to_self_delay` posture), the funding tx is broadcast + confirmed,
/// both nodes see a usable channel. Then the swap-IN leg: A issues an invoice +
/// registers seller/token, B pays it, A auto-claims → `ClaimedSwapIn` on
/// `swap_in_rx` (drives `settleSwapIn`). (The off-chain LN swap-out leg was
/// removed; USD→BTC swap-out is now an on-chain splice-out rail.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage2_3_channel_and_swap() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_846_u16;
    let port_b = 19_847_u16;

    let mut node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;

    // A listens for inbound; B will dial it.
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B so it can fund the channel.
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    assert!(node_b.wallet.get_balance().confirmed.to_sat() > 0);

    // Advance both nodes' LDK best_block to the real tip BEFORE opening —
    // otherwise LDK sees the funding tx's anti-fee-sniping locktime (≈ tip) as
    // far in the future and rejects it as "non-final".
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // Connect B → A, then B opens a 1,000,000-sat channel to A using B's own
    // production config (no override) — this also proves the symmetric
    // `to_self_delay` posture: two identical QU!D configs open against each
    // other (the asymmetric quid default could not).
    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
        .expect("create_channel");

    // Wait for the funding tx to hit bitcoind's mempool (the event handler funds
    // + broadcasts it asynchronously).
    let mut funded = false;
    for _ in 0..60 {
        if regtest.mempool_len() > 0 {
            funded = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(funded, "funding tx never reached the mempool");

    // Confirm it (minimum_depth=3; mine 6) and resync both nodes until the
    // channel is usable on both sides.
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
    assert!(usable, "channel never became usable on both nodes");

    // --- Stage 3: swap-in (settle-then-claim). A issues an invoice + registers
    // the seller/token, B pays it → A surfaces a ClaimedSwapIn on `swap_in_rx`
    // WITHOUT yet taking the BTC. Acting as the EVM-sender, the test then claims
    // (standing in for a successful on-chain settleSwapIn). ---
    let seller = alloy_primitives::Address::repeat_byte(0x11);
    let token = alloy_primitives::Address::repeat_byte(0x22);
    let amount_sats = 100_000_u64;

    // Bind (seller, token) into the invoice's payment_metadata — no hop-side map.
    let invoice = node_a
        .issue_swap_in_invoice(seller, token, amount_sats, alloy_primitives::U256::ZERO, "quid swap-in")
        .expect("issue_swap_in_invoice");
    let payment_hash: [u8; 32] = *invoice.payment_hash().as_ref();

    // B pays the invoice over the direct channel.
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

    // A should surface the settled swap-in.
    let (claimed, _ack) = tokio::time::timeout(
        Duration::from_secs(30),
        node_a.swap_in_rx.recv(),
    )
    .await
    .expect("timed out waiting for swap-in claim")
    .expect("swap_in_rx closed");

    assert_eq!(claimed.sats, amount_sats, "claimed sats");
    assert_eq!(claimed.seller, seller, "claimed seller");
    assert_eq!(claimed.token, token, "claimed token");
    assert_eq!(claimed.payment_hash, payment_hash, "claimed payment hash");

    // EVM-sender role: a successful on-chain settleSwapIn would now deliver the
    // USD; only THEN do we claim the BTC. Claiming here completes the LN leg so A
    // actually receives the inbound liquidity the swap-out below spends.
    node_a
        .channel_manager
        .claim_funds(PaymentPreimage(claimed.preimage));

    // (The off-chain LN swap-out leg that previously followed here was removed —
    // USD→BTC swap-out is now an on-chain splice-out rail. M11 re-adds the LN rail
    // and its end-to-end test.)

    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// Stage 4: the swap-in UNDELIVERABLE branch (settle-then-claim step 3). A real
/// swap-in arrives and the hop, acting as an EVM-sender whose `settleSwapIn`
/// could NOT deliver the USD (floor unmet / pool dry), FAILS the HTLC back rather
/// than claiming. The seller (B) must get its BTC back — the property that makes
/// the floor safe: an undeliverable swap-in costs the seller nothing.
/// Complements stage2_3 (which covers the claim branch); here we exercise
/// `SwapInClaimer::fail` → `fail_htlc_backwards` end-to-end on real LDK.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage4_swap_in_undeliverable_fails_back() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_848_u16; // distinct ports from stage2_3
    let port_b = 19_849_u16;

    let mut node_a = boot_node(&regtest, seed_a, "a4", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b4", lsp_info(pk_a.clone(), port_a)).await;
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

    // B's outbound BEFORE the swap-in — it must be RESTORED after the fail-back
    // (the in-flight HTLC returns to the sender), proving the BTC came back.
    let b_outbound_before = node_b.channel_manager.list_channels()[0].outbound_capacity_msat;

    // A real swap-in: B pays the invoice A issued, A surfaces a ClaimedSwapIn.
    let seller = alloy_primitives::Address::repeat_byte(0x11);
    let token = alloy_primitives::Address::repeat_byte(0x22);
    let amount_sats = 100_000_u64;
    let invoice = node_a
        .issue_swap_in_invoice(seller, token, amount_sats, alloy_primitives::U256::ZERO, "swap-in")
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

    let (claimed, _ack) = tokio::time::timeout(Duration::from_secs(30), node_a.swap_in_rx.recv())
        .await
        .expect("timed out waiting for swap-in claim")
        .expect("swap_in_rx closed");
    assert_eq!(claimed.payment_hash, payment_hash, "claimed the real HTLC hash");

    // EVM-sender role: settleSwapIn was UNDELIVERABLE → fail the HTLC back instead
    // of claiming. The hop must NOT take BTC it couldn't settle the USD for.
    node_a.swap_in_claimer().fail(claimed.payment_hash);

    // The seller (B) gets its BTC back: B's outbound recovers to ≈ its pre-swap
    // value (the 100k HTLC returned), and A NEVER gained inbound (it didn't claim).
    let mut restored = false;
    for _ in 0..40 {
        let b_out = node_b.channel_manager.list_channels()[0].outbound_capacity_msat;
        let a_out = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;
        // B back to ~full (allow a small fee/rounding delta); A still ~0 outbound.
        if b_out + 5_000_000 >= b_outbound_before && a_out < 1_000_000 {
            restored = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(restored, "failed-back swap-in must return the BTC to the seller, not the hop");

    drop(node_a);
    drop(node_b);
    drop(regtest);
}


/// Stage 4: SPLICE-IN (grow). After opening a 1,000,000-sat channel B→A, B (the
/// LP — the only party that can contribute in the vendored LDK splicing acceptor)
/// splices in 500,000 sat via `node::initiate_splice`. Both nodes co-sign through
/// the event handler's `FundingTransactionReadyForSigning` arm; on lock the channel
/// value grows and B emits a `Spliced` lifecycle event (the EVM `spliceChannel`
/// trigger). Then it COOPERATIVELY CLOSES the spliced channel and asserts the
/// `Closed` event keys on the stable LDK id but carries the ROTATED outpoint — the
/// exact mis-key hazard the driver's original-cid map bridges. End-to-end
/// verification of seam 1 (splice) + the close-after-splice path on the LN side.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage4_splice_grow_then_close() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_856_u16;
    let port_b = 19_857_u16;

    let node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let mut node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B with matured coinbase (plenty of confirmed UTXOs for the splice-in).
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    assert!(node_b.wallet.get_balance().confirmed.to_sat() > 2_000_000);

    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // Open a 1,000,000-sat channel B → A.
    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
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
    assert!(usable, "channel never became usable on both nodes");

    // Re-sync B's wallet so its post-open change UTXOs are confirmed + visible.
    bdk_full_sync(&node_b).await;

    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("a channel");
    let ldk_channel_id = chan.channel_id;
    assert_eq!(chan.channel_value_satoshis, channel_value_sats);

    // --- SPLICE-IN 500,000 sat (B initiates + contributes; A accepts). ---
    let grow_sats = 500_000_u64;
    quid_hop::node::initiate_splice(
        &node_b.channel_manager,
        &node_b.wallet,
        &node_b.esplora,
        &ldk_channel_id,
        &pk_a.0,
        grow_sats,
        2_000, // funding feerate (sat/kw), comfortably above regtest min-relay
    )
    .await
    .expect("initiate_splice");

    // The splice funding tx must reach the mempool (negotiation + co-sign run in
    // both nodes' background event loops).
    let mut spliced = false;
    for _ in 0..160 {
        if regtest.mempool_len() > 0 {
            spliced = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(spliced, "splice funding tx never reached the mempool");

    // Confirm + resync until the channel value grows on B.
    let mut grown = false;
    for _ in 0..25 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&node_b).await;
        if let Some(c) = node_b
            .channel_manager
            .list_channels()
            .into_iter()
            .find(|c| c.channel_id == ldk_channel_id)
        {
            if c.channel_value_satoshis >= channel_value_sats + grow_sats {
                grown = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(grown, "channel value never grew after splice");

    // B must have emitted a Spliced lifecycle event (the EVM spliceChannel trigger).
    // Take the lifecycle receiver out (swap in a throwaway) so `node_b` stays whole
    // for the close-phase `ldk_resync`/`close_channel` calls below.
    let mut rx = {
        let (_dtx, drx) = tokio::sync::mpsc::unbounded_channel();
        std::mem::replace(&mut node_b.channel_lifecycle_rx, drx)
    };
    let mut spliced_outpoint = None; // (Txid, vout) of the rotated funding
    for _ in 0..40 {
        match rx.try_recv() {
            Ok(ChannelLifecycleEvent::Spliced {
                channel_id,
                new_funding_txid,
                new_funding_vout,
                ..
            }) => {
                assert_eq!(channel_id, ldk_channel_id.0);
                spliced_outpoint = Some((new_funding_txid, new_funding_vout));
                break;
            }
            Ok(_) => {} // Ready/Closed from the open — skip
            Err(_) => tokio::time::sleep(Duration::from_millis(250)).await,
        }
    }
    let (spliced_txid, spliced_vout) =
        spliced_outpoint.expect("no Spliced lifecycle event with a rotated outpoint");

    // --- CLOSE AFTER SPLICE (seam: the rotated outpoint must NOT mis-key the cid). ---
    // The cooperative close spends the SPLICED funding outpoint, not the original.
    // On-chain the channelId stays keyed on the ORIGINAL outpoint, so the bridge
    // driver must map the Closed event by the STABLE LDK channel id (the open-time
    // `onchain_cid` map), never by recomputing from the close tx. This proves the
    // hazard exists end-to-end: the Closed event fires with the ROTATED outpoint
    // under the SAME LDK channel id.
    // The peer connection (`_conn`) is still up — the splice negotiated over it
    // right before this — so shutdown/closing_signed flows without a reconnect.
    node_b
        .channel_manager
        .close_channel(&ldk_channel_id, &pk_a.0)
        .expect("close_channel");

    // The cooperative closing tx must reach the mempool (both background loops
    // negotiate shutdown → closing_signed → broadcast).
    let mut closing = false;
    for _ in 0..160 {
        if regtest.mempool_len() > 0 {
            closing = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(closing, "closing tx never reached the mempool");

    // Confirm + resync until B emits a Closed lifecycle event.
    let mut saw_closed = false;
    for _ in 0..40 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&node_b).await;
        match rx.try_recv() {
            Ok(ChannelLifecycleEvent::Closed {
                channel_id,
                funding_txid,
                funding_vout,
            }) => {
                // The Closed event keys on the STABLE LDK channel id — the handle the
                // driver looks up in its open-time `onchain_cid` map.
                assert_eq!(channel_id, ldk_channel_id.0, "Closed used a non-stable id");
                // ...but the outpoint it carries is the ROTATED (post-splice) one. A
                // driver that recomputed the on-chain cid from this would mis-key; the
                // map lookup is what keeps recordClose pointed at the original cid.
                assert_eq!(funding_txid, spliced_txid, "close did not spend the spliced outpoint");
                assert_eq!(funding_vout, spliced_vout, "close vout != spliced vout");
                saw_closed = true;
                break;
            }
            Ok(_) => {}
            Err(_) => tokio::time::sleep(Duration::from_millis(500)).await,
        }
    }
    assert!(saw_closed, "no Closed lifecycle event after splice");
    // node_b is partially moved (rx taken above); remaining fields + node_a +
    // regtest tear down at scope end (regtest last → bitcoind outlives the nodes).
}

/// Stage 4b (LP PARTIAL WITHDRAWAL): a SPLICE-OUT shrinks an open channel in place,
/// paying the removed BTC to the LP's OWN committed payout script. Proves the
/// direct-settlement model end-to-end: the splice tx itself carries the LP's P2WPKH
/// payout output — EXACTLY what `BTCChannels._lpFinalBalance` reads to split native
/// (BTC returned to the LP) from delivered (swapped-away, settled as QUI) — so the
/// contract needs no hop-attested balance. The channel stays OPEN at the reduced
/// funding, and B emits a `Spliced` lifecycle event with the rotated outpoint for
/// the EVM `splice` drive (the same path a grow uses).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage4b_splice_out_shrinks_channel() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0x5111CE_u64;
    let seed_b = 0x5B0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_860_u16;
    let port_b = 19_861_u16;

    let node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B (funds the open; a splice-OUT contributes no inputs).
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;

    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // Open a 1,500,000-sat channel B → A.
    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_500_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
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
    assert!(usable, "channel never became usable on both nodes");

    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("a channel");
    let ldk_channel_id = chan.channel_id;
    assert_eq!(chan.channel_value_satoshis, channel_value_sats);

    // B's committed upfront-SHUTDOWN script (get_shutdown_scriptpubkey) is the payout the
    // splice-out must pay — that is what the contract records as `btcRecipientOf` and what
    // `_withdrawalPayout` attributes to. (Was wrongly the FUNDING pubkey here — the exact
    // assertion that masked the funding-vs-shutdown withdrawal bug; distinct keys expose it.)
    let lp_payout_spk = {
        use lightning::sign::SignerProvider;
        node_b.keys_manager.get_shutdown_scriptpubkey().expect("shutdown spk").into_inner()
    };

    // --- SPLICE-OUT 500,000 sat (B initiates; A accepts + co-signs). ---
    let withdraw_sats = 500_000_u64;
    quid_hop::node::initiate_splice_out(
        node_b.keys_manager.as_ref(),
        &node_b.channel_manager,
        &ldk_channel_id,
        &pk_a.0,
        withdraw_sats,
        2_000, // funding feerate (sat/kw), above regtest min-relay
    )
    .expect("initiate_splice_out");

    let mut spliced = false;
    for _ in 0..160 {
        if regtest.mempool_len() > 0 {
            spliced = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(spliced, "splice-out funding tx never reached the mempool");

    // Confirm + resync until the channel value SHRINKS on B (by the withdrawal + fee).
    let mut shrunk = false;
    for _ in 0..25 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&node_b).await;
        if let Some(c) = node_b
            .channel_manager
            .list_channels()
            .into_iter()
            .find(|c| c.channel_id == ldk_channel_id)
        {
            if c.channel_value_satoshis < channel_value_sats {
                assert!(
                    c.channel_value_satoshis <= channel_value_sats - withdraw_sats,
                    "channel shrank by less than the withdrawal"
                );
                shrunk = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(shrunk, "channel value never shrank after splice-out");

    // B emits a Spliced lifecycle event with the rotated outpoint (the EVM splice
    // trigger — identical to a grow; drive_splice reads the new total from the tx).
    let mut rx = node_b.channel_lifecycle_rx;
    let mut spliced_outpoint = None;
    for _ in 0..40 {
        match rx.try_recv() {
            Ok(ChannelLifecycleEvent::Spliced {
                channel_id,
                new_funding_txid,
                new_funding_vout,
                ..
            }) => {
                assert_eq!(channel_id, ldk_channel_id.0);
                spliced_outpoint = Some((new_funding_txid, new_funding_vout));
                break;
            }
            Ok(_) => {} // Ready from the open — skip
            Err(_) => tokio::time::sleep(Duration::from_millis(250)).await,
        }
    }
    let (spliced_txid, _spliced_vout) =
        spliced_outpoint.expect("no Spliced lifecycle event with a rotated outpoint");

    // DIRECT MODEL: the splice tx itself pays the LP's committed P2WPKH exactly the
    // withdrawal — the output BTCChannels._lpFinalBalance credits as the LP's BTC
    // payout (so delivered = shrink − payout, with no attested balance).
    let splice_tx = node_b
        .esplora
        .client()
        .get_tx(&spliced_txid)
        .await
        .expect("get splice tx")
        .expect("splice tx present");
    let paid_lp: u64 = splice_tx
        .output
        .iter()
        .filter(|o| o.script_pubkey == lp_payout_spk)
        .map(|o| o.value.to_sat())
        .sum();
    assert_eq!(
        paid_lp, withdraw_sats,
        "splice-out tx must pay the LP's committed payout script exactly the withdrawal"
    );
}

/// Stage 7 (P0 idempotency): a swap-in must survive a HOP CRASH that happens AFTER
/// the inbound HTLC is claimable but BEFORE the EVM-sender claims it — without ever
/// losing the swap-in OR double-taking the seller's BTC.
///
/// MECHANISM. Open B(LP)→A(hop) as in stage2_3. B pays A's swap-in invoice; A's
/// event handler surfaces a `ClaimedSwapIn` on `swap_in_rx`. We DO NOT claim —
/// modelling the EVM-sender process dying right after `settleSwapIn` was queued but
/// before `SwapInClaimer::claim`. The inbound HTLC therefore stays in LDK's
/// claimable state, persisted in node_a's `DiskFs` channel monitor.
///
/// CRASH = `drop(node_a)` (and its listener/rx): the background tasks stop and the
/// process state is gone. Because `HopPersister` writes monitors SYNCHRONOUSLY, the
/// claimable HTLC is already durable on disk.
///
/// RESTART = `reboot_node` with the SAME (seed, role) ⇒ SAME data dir ⇒ `node::boot`
/// reloads the persisted monitors + channel manager. The still-unclaimed inbound
/// HTLC SURVIVES the crash: `ChannelManager::read` restores it into the in-memory
/// `claimable_payments` map (so the node can still claim it). B reconnects (forced —
/// see below) and the channel RE-ESTABLISHES. We then claim ONCE with the preimage
/// and assert the HTLC settles exactly once (A's inbound grows by the swap amount);
/// a SECOND claim is a no-op (LDK dedups an already-settled payment) — proving the
/// BTC is taken exactly once.
///
/// FAITHFUL-VARIANT NOTE (what was infeasible vs. what is proven, and WHERE):
///
/// 1. LDK does NOT re-emit `PaymentClaimable` on restart. This LDK version restores
///    the claimable HTLC into `claimable_payments` for re-claim but enqueues NO event
///    (verified in the vendored `channelmanager.rs` read path). So nothing in LDK
///    re-drives a swap-in on boot — the bridge must.
///
/// 2. The PRODUCTION re-drive (persist the in-flight swap-in BEFORE settle → on boot
///    re-load `BridgeStore::inflight_swapins()` → `handle_one` settles+claims EXACTLY
///    once → a second re-drive is a dedup no-op) is proven in `quid-bridge`'s own
///    tests (`swap_in::tests::{persist_before_settle_then_remove_on_claim,
///    defer_leaves_swapin_persisted_for_redrive,
///    redrive_on_boot_claims_persisted_swapin_then_dedups}`). It CANNOT be wired into
///    THIS test: `quid-hop` does not depend on `quid-bridge` (that would be a
///    dependency cycle — the bridge depends on the hop), so `BridgeStore`/`handle_one`
///    are out of scope here. An EARLIER version of this test had it manually
///    `claim_funds` after reboot, which masked the gap (it proved LDK's HTLC survives
///    but not that anything re-drives it). The manual `claim_funds` below now stands
///    in EXACTLY for the bridge's `SwapInClaimer.claim` that the boot re-drive invokes
///    after its idempotent re-settle — this test proves the LDK-side half (the HTLC
///    survives the crash + claims exactly once), the bridge tests prove the persist +
///    re-drive half.
///
/// 3. Because B's PeerManager still believes it's connected to the (now-dead) old A,
///    the test forces a real reconnect with `disconnect_by_node_id` before re-dialing —
///    exactly what a peer's own connection-watchdog does when the socket dies. What
///    this CANNOT prove in-process is OS-level process death (we `drop`, not `kill`);
///    the disk-restore path exercised is identical.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage7_crash_restart_midswapin_is_idempotent() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_876_u16; // distinct ports from the other stages
    let port_b = 19_877_u16;

    let mut node_a = boot_node(&regtest, seed_a, "a7", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b7", lsp_info(pk_a.clone(), port_a)).await;
    let mut listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B + open the channel B → A (same as stage2_3).
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    let mut conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
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
    assert!(usable, "channel never became usable on both nodes");

    // A's OUTBOUND BEFORE the claim — claiming the swap-in moves the seller's BTC to
    // A's local balance, so A's outbound must INCREASE by ~the swap amount after the
    // single post-restart claim (the BTC is taken once, not twice).
    let a_outbound_before = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;

    // Real swap-in: B pays the invoice A issued; A surfaces a ClaimedSwapIn.
    let seller = alloy_primitives::Address::repeat_byte(0x11);
    let token = alloy_primitives::Address::repeat_byte(0x22);
    let amount_sats = 100_000_u64;
    let invoice = node_a
        .issue_swap_in_invoice(seller, token, amount_sats, alloy_primitives::U256::ZERO, "swap-in")
        .expect("issue_swap_in_invoice");
    let payment_hash: [u8; 32] = *invoice.payment_hash().as_ref();
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

    let (claimed, _ack) = tokio::time::timeout(Duration::from_secs(30), node_a.swap_in_rx.recv())
        .await
        .expect("timed out waiting for swap-in claim")
        .expect("swap_in_rx closed");
    assert_eq!(claimed.payment_hash, payment_hash, "claimed the real HTLC hash");
    // The preimage we'll claim with post-restart (the EVM-sender holds it; LDK also
    // re-derives it on the re-emit, but stage2_3-style we thread the captured one).
    let preimage = claimed.preimage;

    // --- CRASH: drop node_a WITHOUT claiming. The claimable HTLC is already durable
    // in the synchronously-persisted channel monitor on disk. ABORT the listener task
    // (dropping a JoinHandle doesn't cancel it) so its bound port is released for the
    // restarted node to re-bind. ---
    listener_a.abort();
    drop(node_a);
    // Give the dropped node's tasks a moment to wind down + release the DiskFs/socket.
    tokio::time::sleep(Duration::from_secs(2)).await;

    // --- RESTART: re-boot node_a from the SAME on-disk state. ---
    let node_a = reboot_node(&regtest, seed_a, "a7", lsp_info(pk_b.clone(), port_b)).await;
    ldk_resync(&node_a).await;
    listener_a = spawn_listener(&node_a, port_a).await;

    // FORCE a real reconnect: B's PeerManager still believes it's connected to the
    // dead old A, so `connect_peer_if_necessary` would no-op. Disconnect first (what
    // a connection-watchdog does when the socket dies), then re-dial the restarted A.
    drop(conn);
    node_b.peer_manager.disconnect_by_node_id(pk_a.0);
    let mut reconnected = false;
    let mut new_conn = None;
    for _ in 0..40 {
        match quid_ln::p2p::connect_peer_if_necessary(
            &node_b.peer_manager,
            &pk_a,
            &[quid_common::ln::addr::LxSocketAddress::TcpIpv4 {
                ip: std::net::Ipv4Addr::LOCALHOST,
                port: port_a,
            }],
        )
        .await
        {
            Ok(c) => {
                new_conn = Some(c);
                reconnected = true;
                break;
            }
            Err(_) => tokio::time::sleep(Duration::from_millis(500)).await,
        }
    }
    assert!(reconnected, "B could not reconnect to the restarted A");
    conn = new_conn.expect("reconnected => connection task");

    // Wait until the channel RE-ESTABLISHES + is usable again on A (so the claim's
    // commitment update can flow to the peer). Mine the occasional block to nudge sync.
    let mut reestablished = false;
    for i in 0..60 {
        if !node_a.channel_manager.list_usable_channels().is_empty() {
            reestablished = true;
            break;
        }
        if i % 8 == 7 {
            regtest.mine(1);
            ldk_resync(&node_a).await;
            ldk_resync(&node_b).await;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(reestablished, "channel never re-established after restart");

    // SURVIVED THE CRASH: the swap-in HTLC is still claimable on the restarted node.
    // CLAIM ONCE with the preimage (settle-then-claim step 2, post-restart). In
    // production this exact call is made by the bridge's boot re-drive: it re-loads
    // the persisted ClaimedSwapIn from `BridgeStore::inflight_swapins()`, re-settles
    // idempotently (AlreadySettled), then `SwapInClaimer.claim(preimage)` → this. See
    // the FAITHFUL-VARIANT NOTE above; the persist + re-drive half is proven in the
    // quid-bridge swap_in tests (out of scope here — no hop→bridge dep).
    node_a
        .channel_manager
        .claim_funds(PaymentPreimage(preimage));

    // The HTLC settles EXACTLY once: A's outbound grows by ~the swap amount (the BTC
    // moved to A's local balance, taken a single time). If the swap-in had been LOST
    // across the crash the claim would be a no-op and the outbound would not grow.
    // Channel reserve + fee buffer hold back part of A's spendable outbound, so we
    // require it to grow by at least MOST of the swap (>= 80%), not the exact amount.
    let want_min_growth = amount_sats * 1000 * 80 / 100;
    let mut settled = false;
    for _ in 0..60 {
        let a_outbound = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;
        if a_outbound >= a_outbound_before + want_min_growth {
            eprintln!(
                "stage7: A outbound {} -> {} (+{}) after single claim",
                a_outbound_before,
                a_outbound,
                a_outbound - a_outbound_before
            );
            settled = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(
        settled,
        "post-restart claim must settle the surviving HTLC exactly once (A gains the outbound)"
    );
    let a_outbound_after_first = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;

    // IDEMPOTENT: a SECOND claim of the now-settled payment is a no-op — the BTC is
    // not taken twice (LDK dedups an already-claimed payment_hash).
    node_a
        .channel_manager
        .claim_funds(PaymentPreimage(preimage));
    tokio::time::sleep(Duration::from_secs(2)).await;
    let a_outbound_after_second = node_a.channel_manager.list_channels()[0].outbound_capacity_msat;
    assert_eq!(
        a_outbound_after_first, a_outbound_after_second,
        "a second claim must be a no-op (no double-take of the seller's BTC)"
    );

    drop(conn);
    drop(listener_a);
    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// Stage 6: the LP-side REBALANCER. Open a 1,000,000-sat channel B→A (B is the
/// LP). Drive B's outbound (its swap-in FORWARDING capacity) DOWN by claiming real
/// swap-ins (B pays A; A claims, so balance actually MOVES to A) until B can no
/// longer forward a full-scale swap-in — i.e. `next_outbound_htlc_limit_msat`
/// drops below the per-swap ceiling (50% of the channel). Then build the
/// rebalancer's `ChannelSnapshot` from B's REAL `list_channels`, assert
/// `decide_splice` returns `Splice`, run ONE rebalancer-equivalent splice with the
/// decided grow, and assert the channel value grows. This exercises the demand
/// signal + the splice action end-to-end against real bitcoind/LDK.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stage6_rebalancer_splices_on_exhaustion() {
    use quid_hop::rebalancer::{
        decide_splice, per_swap_ceiling_msat, ChannelSnapshot, RebalanceConfig, SpliceDecision,
    };

    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_866_u16;
    let port_b = 19_867_u16;

    let mut node_a = boot_node(&regtest, seed_a, "a6", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b6", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    // Fund B (the LP) with matured coinbase: channel funding + later the splice-in.
    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    assert!(node_b.wallet.get_balance().confirmed.to_sat() > 3_000_000);

    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 1_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
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
    assert!(usable, "channel never became usable on both nodes");
    bdk_full_sync(&node_b).await; // confirm B's post-open change UTXO

    let ldk_channel_id = node_b.channel_manager.list_channels()[0].channel_id;

    // Build the snapshot helper the rebalancer uses (read percent from the hop's
    // committed 50% config — the per-swap ceiling source).
    let snap_of = |cm: &quid_hop::node::HopChannelManager| -> ChannelSnapshot {
        let c = cm
            .list_channels()
            .into_iter()
            .find(|c| c.channel_id == ldk_channel_id)
            .expect("the channel");
        ChannelSnapshot {
            channel_value_satoshis: c.channel_value_satoshis,
            next_outbound_htlc_limit_msat: c.next_outbound_htlc_limit_msat,
            max_inbound_in_flight_percent: 50,
            is_usable: c.is_usable,
        }
    };

    // FRESH channel: B funded it, so its outbound is ~full → HEALTHY (no splice).
    let fresh = snap_of(&node_b.channel_manager);
    assert!(
        fresh.next_outbound_htlc_limit_msat >= per_swap_ceiling_msat(&fresh),
        "fresh B→A channel should be able to forward a full-scale swap-in"
    );
    let cfg = RebalanceConfig { wallet_reserve_sats: 10_000, poll_interval_secs: 1 };
    assert_eq!(
        decide_splice(
            &fresh,
            node_b.wallet.get_balance().confirmed.to_sat(),
            &cfg,
            quid_common::constants::CHANNEL_MAX_FUNDING_SATS as u64,
        ),
        SpliceDecision::Healthy,
        "fresh channel must not trigger a splice"
    );

    // DEPLETE B's outbound by claiming real swap-ins (B pays A; A CLAIMS → balance
    // moves to A, B's outbound drops). Each HTLC is capped at 50% inbound on A, so
    // we use ~300k-sat swaps and repeat until B falls below the per-swap ceiling.
    let seller = alloy_primitives::Address::repeat_byte(0x11);
    let token = alloy_primitives::Address::repeat_byte(0x22);
    let mut exhausted = false;
    for i in 0..6 {
        let amount_sats = 300_000_u64;
        // Skip if A can't currently accept this inbound (50% in-flight cap / no
        // inbound headroom) — the loop's later snapshot check decides completion.
        let invoice = match node_a.issue_swap_in_invoice(
            seller,
            token,
            amount_sats,
            alloy_primitives::U256::ZERO,
            "rebalancer swap-in",
        ) {
            Ok(inv) => inv,
            Err(_) => break,
        };
        let payment_hash: [u8; 32] = *invoice.payment_hash().as_ref();
        if node_b
            .channel_manager
            .pay_for_bolt11_invoice(
                &invoice,
                PaymentId([i as u8; 32]),
                None,
                RouteParametersConfig::default(),
                Retry::Attempts(5),
            )
            .is_err()
        {
            break; // no outbound left to push — already depleted
        }
        // A claims (takes the BTC) → balance permanently shifts to A.
        match tokio::time::timeout(Duration::from_secs(30), node_a.swap_in_rx.recv()).await {
            Ok(Some((claimed, _ack))) => {
                assert_eq!(claimed.payment_hash, payment_hash);
                node_a.swap_in_claimer().claim(claimed.preimage);
            }
            _ => break,
        }
        // Let the claim settle, then check B's forwarding capacity vs the ceiling.
        for _ in 0..40 {
            let s = snap_of(&node_b.channel_manager);
            if s.next_outbound_htlc_limit_msat < per_swap_ceiling_msat(&s) {
                exhausted = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        if exhausted {
            break;
        }
    }
    assert!(
        exhausted,
        "could not drive B's swap-in forwarding capacity below the per-swap ceiling"
    );

    // THE DECISION on the real depleted snapshot: it must say SPLICE.
    let depleted = snap_of(&node_b.channel_manager);
    let confirmed = node_b.wallet.get_balance().confirmed.to_sat();
    let decision = decide_splice(
        &depleted,
        confirmed,
        &cfg,
        quid_common::constants::CHANNEL_MAX_FUNDING_SATS as u64,
    );
    let grow_sats = match decision {
        SpliceDecision::Splice { grow_sats } => grow_sats,
        other => panic!("rebalancer should splice on exhaustion, got {other:?}"),
    };
    assert!(grow_sats >= 250_000, "grow must clear the economic floor");

    // THE ACTION: run exactly what the rebalancer loop runs — initiate_splice with
    // the decided grow. (We call it directly rather than spawn the loop so the test
    // is deterministic; the loop is the same call behind the in-flight guard.)
    let value_before = depleted.channel_value_satoshis;
    quid_hop::node::initiate_splice(
        &node_b.channel_manager,
        &node_b.wallet,
        &node_b.esplora,
        &ldk_channel_id,
        &pk_a.0,
        grow_sats,
        2_000,
    )
    .await
    .expect("rebalancer initiate_splice");

    let mut splice_in_mempool = false;
    for _ in 0..160 {
        if regtest.mempool_len() > 0 {
            splice_in_mempool = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(splice_in_mempool, "rebalancer splice tx never reached the mempool");

    // Confirm + resync until the channel value grows by (at least) the decided grow.
    let mut grown = false;
    for _ in 0..25 {
        regtest.mine(6);
        ldk_resync(&node_a).await;
        ldk_resync(&node_b).await;
        if let Some(c) = node_b
            .channel_manager
            .list_channels()
            .into_iter()
            .find(|c| c.channel_id == ldk_channel_id)
        {
            if c.channel_value_satoshis >= value_before + grow_sats {
                grown = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(grown, "rebalancer splice never grew the channel value");

    drop(node_a);
    drop(node_b);
    drop(regtest);
}
