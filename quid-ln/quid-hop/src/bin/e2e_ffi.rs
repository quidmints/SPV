//! `e2e_ffi` — the Rust side of the QU!D cross-chain forge e2e test.
//!
//! In ONE invocation, against a real `bitcoind`/esplora + two real LDK
//! (`quid-ln`) hop nodes, this:
//!   1. boots regtest + node A (hop) + node B (LP), funds B, opens a 2-of-2
//!      (LP+hop) channel B→A, broadcasts + confirms the funding tx;
//!   2. drives a swap-IN over Lightning (A issues a swap-in invoice binding
//!      seller/token, B pays it, A auto-settles → the real HTLC payment hash);
//!   3. cooperatively closes the channel + mines it;
//!   4. pulls the SPV data the EVM needs from esplora — the regtest genesis
//!      header, the header chain to tip, the funding/close raw LEGACY txs, their
//!      block hashes/heights/tx-indices, and merkle proofs;
//!   5. recovers the two 33-byte funding pubkeys from the cooperative-close
//!      tx witness (the 2-of-2 redeem script is its last witness element) and
//!      reconstructs `OpenParams`;
//!   6. signs the LP's `lpAuth` over the EXACT `BTCChannels.openChannelDigest`
//!      (chainId + contract address are passed in as argv by the Solidity test
//!      after it deploys), with a fresh secp256k1 EVM key;
//!   7. ABI-encodes the whole bundle and prints it as `0x…` hex to stdout.
//!
//! All ABI encoding / SPV-proof / digest construction is the shared production
//! [`quid_hop::evm_codec`] — this binary is its end-to-end exerciser (so the
//! cross-chain forge test re-proves the module byte-for-byte against Solidity).
//!
//! The Solidity test `vm.ffi`s this, `abi.decode`s the bundle, then drives the
//! REAL `SPVGateway` + `BTCChannels` (addBlockHeaderBatch → openChannel →
//! settleSwapIn → recordClose). See `evm/test/btc/CrossChainE2E.t.sol`.
//!
//! Usage: `e2e_ffi <chainIdDec> <btcChannelsAddr0x> [swapout]`
//!
//! Requires `--features harness`. CANNOT run without a bitcoind/esplora (the
//! harness downloads them under the `bitcoind_download`/electrs features, or
//! reads `BITCOIND_EXE`/`ELECTRS_EXE`). All diagnostics go to STDERR; only the
//! final `0x…` bundle goes to stdout (forge FFI captures stdout).

use std::time::Duration;

use alloy_primitives::{keccak256, Address, U256};
use bitcoin::secp256k1::{Message, Secp256k1, SecretKey};
use bitcoin::Txid;
use lightning::ln::channelmanager::{PaymentId, Retry};
use lightning::routing::router::RouteParametersConfig;
use lightning::types::payment::PaymentPreimage;

use quid_common::root_seed::RootSeed;
use quid_hop::evm_codec::{
    encode_struct, open_channel_digest, serialize_header, tx_inclusion, OpenParams, Tok,
};
use quid_hop::harness::{
    bdk_full_sync, boot_node, connect, ldk_resync, lsp_info, spawn_listener, Regtest,
};

// ─────────────────────────────────── main ────────────────────────────────────

fn main() {
    // All logs to stderr (forge FFI keeps stdout for the bundle).
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter("info,quid_hop=debug")
        .try_init();

    let mut args = std::env::args().skip(1);
    let first = args.next().expect("argv[1] = chainId (decimal) OR \"fixture\"");

    // FIXTURE MODE: `e2e_ffi fixture <outPath>` opens a real simple-taproot (P2TR
    // `0x5120||Q`) channel against live bitcoind, cooperatively closes it, and
    // writes the `OpenChannelE2E.t.sol` JSON fixture (funding tx + SPV proof +
    // fundingTaproot + the genesis/header chain) to <outPath>. NO swap-in (HTLCs
    // are a deferred milestone), so this path is green today. It exists so the
    // P2WSH OpenChannelE2E fixture can be regenerated to the P2TR shape (M8
    // fixture regeneration).
    if first == "fixture" {
        let out_path = args
            .next()
            .expect("argv[2] = output JSON path (fixture mode)");
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("tokio runtime");
        rt.block_on(run_fixture(&out_path));
        eprintln!("e2e_ffi: wrote P2TR open-channel fixture to {out_path}");
        return;
    }

    let chain_id: u64 = first
        .parse()
        .expect("argv[1] = chainId (decimal) OR \"fixture\"");
    let btc_channels: Address = args
        .next()
        .and_then(|s| s.parse().ok())
        .expect("argv[2] = BTCChannels address (0x…)");
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("tokio runtime");

    let bundle = rt.block_on(run(chain_id, btc_channels));
    // ONLY the bundle hex on stdout.
    println!("0x{}", hex_encode(&bundle));
}

fn hex_encode(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

async fn run(chain_id: u64, btc_channels: Address) -> Vec<u8> {
    // ── infra + two nodes (A = hop / Lightning receiver, B = LP / funder) ──
    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_846_u16;
    let port_b = 19_847_u16;

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

    // B opens a channel to A.
    let _conn = connect(&node_b, &pk_a, port_a).await;
    // Sized so the EVM-side funding loop (6 × 500 USDC ≈ $3k of BTC drawn from
    // the paired in-range depth) can't exhaust the channel's liquidity. 8e6 sats
    // ≈ $4.9k stays under LDK's non-wumbo 2^24-1 funding cap.
    let channel_value_sats = 8_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
        .expect("create_channel");

    // Funding tx → mempool.
    wait_until(60, Duration::from_millis(250), || regtest.mempool_len() > 0).await;

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
    assert!(usable, "channel never became usable");

    // The channel's funding outpoint (txid + vout).
    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("one channel");
    let funding_txo = chan.funding_txo.expect("funding txo set after confirm");
    let funding_txid = Txid::from_raw_hash(*funding_txo.txid.as_raw_hash());

    // SIMPLE-TAPROOT: recover the 2-of-2 funding pubkeys WHILE THE CHANNEL IS STILL
    // OPEN. `channel_funding_pubkeys` resolves the channel via `list_channels()`,
    // which no longer contains the channel after the cooperative close below — so
    // the recovery (witness-free: a key-path taproot close carries only a
    // 64-byte BIP340 sig, no 2-of-2 witnessScript to parse) MUST happen pre-close.
    let (holder_pk, cp_pk) = quid_hop::node::channel_funding_pubkeys(
        &node_b.chain_monitor,
        &node_b.channel_manager,
        funding_txid,
        funding_txo.index as u32,
    )
    .expect("funding pubkeys from monitor (witness-free, taproot key-path close)");

    // ── swap-IN: A issues, B pays, A auto-settles → the real HTLC hash ──
    let seller = Address::repeat_byte(0x5E);
    let token = Address::repeat_byte(0x70);
    // Sized so that after the channel reserve (~1% of the 8e6-sat channel ≈ 80k),
    // A still has ample spendable outbound to fund the swap-OUT payout below.
    let amount_sats = 1_000_000_u64;
    let mut node_a = node_a; // make swap_in_rx receivable
    let invoice = node_a
        .issue_swap_in_invoice(seller, token, amount_sats, U256::ZERO, "quid swap-in")
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
        .expect("swap-in claim timeout")
        .expect("swap_in_rx closed");
    assert_eq!(claimed.payment_hash, payment_hash, "claimed hash matches");
    assert_eq!(claimed.sats, amount_sats, "claimed sats");
    // Settle the LN leg (EVM settleSwapIn would precede this; here we complete it).
    node_a
        .channel_manager
        .claim_funds(PaymentPreimage(claimed.preimage));

    // (The off-chain LN swap-out leg that previously ran here — and appended its
    // BOLT11/hash/preimage to the bundle — was removed along with the EVM-side
    // requestSwapOut/SwapOutRequested path. USD→BTC swap-out is now on-chain. M11
    // re-adds the LN rail.)

    // ── cooperative close + confirm ──
    node_b
        .channel_manager
        .close_channel(&chan.channel_id, &pk_a.0)
        .expect("close_channel");
    // The closing tx spends the funding outpoint; wait for it to hit the mempool.
    wait_until(120, Duration::from_millis(250), || regtest.mempool_len() > 0).await;
    // Confirm it deeply (>= MIN_CONFIRMATIONS = 6, plus margin).
    regtest.mine(8);
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    let client = node_b.esplora.client().clone();

    // The cooperative-close txid = the tx that spent funding output vout.
    let outspend = client
        .get_output_status(&funding_txid, funding_txo.index as u64)
        .await
        .expect("get_output_status")
        .expect("funding output has a status");
    assert!(outspend.spent, "funding output spent by the close");
    let close_txid = outspend.txid.expect("close txid");

    // ── pull SPV data from esplora (all via the shared evm_codec) ──
    let tip = client.get_height().await.expect("tip height") as u64;

    // genesis header (height 0) + the chain 1..=tip for addBlockHeaderBatch.
    let genesis_hash = client.get_block_hash(0).await.expect("genesis hash");
    let genesis_header = serialize_header(&node_b.esplora, &genesis_hash)
        .await
        .expect("genesis header");
    let mut headers: Vec<Vec<u8>> = Vec::with_capacity(tip as usize);
    for h in 1..=tip {
        let bh = client.get_block_hash(h as u32).await.expect("block hash");
        headers.push(
            serialize_header(&node_b.esplora, &bh)
                .await
                .expect("header"),
        );
    }

    // funding + close tx inclusion proofs.
    let funding = tx_inclusion(&node_b.esplora, &funding_txid)
        .await
        .expect("funding inclusion");
    let close = tx_inclusion(&node_b.esplora, &close_txid)
        .await
        .expect("close inclusion");

    // SIMPLE-TAPROOT: the 2-of-2 funding pubkeys were recovered WITNESS-FREE above,
    // BEFORE the cooperative close (a key-path taproot close carries only a
    // 64-byte BIP340 Schnorr sig — no 2-of-2 witnessScript to parse — and the channel
    // is gone from `list_channels()` post-close, so the recovery must precede it).
    // SORT into the open/close `channelId` order the contract uses, then locate the
    // P2TR `0x5120||Q` funding output by its scriptPubKey (`funded_output_taproot`).
    let (lp_pubkey, hop_pubkey) =
        quid_hop::evm_codec::sort_funding_pubkeys(holder_pk, cp_pk);
    let (_funding_vout, amount_sats_open) = quid_hop::evm_codec::funded_output_taproot(
        &funding.raw,
        &lp_pubkey,
        &hop_pubkey,
    )
    .expect("P2TR (0x5120||Q) funded output");

    // ── LP lpAuth over the EXACT BTCChannels.openChannelDigest ──
    let secp = Secp256k1::new();
    // Deterministic throwaway LP EVM key (seed-derived; the EVM identity is
    // independent of the BTC channel keys, exactly like makeAddrAndKey("lp")).
    let lp_sk = SecretKey::from_slice(&keccak256("quid-e2e-lp-key").0).expect("lp sk");
    let lp_pk = lp_sk.public_key(&secp);
    let lp_eth = {
        let uncompressed = lp_pk.serialize_uncompressed();
        Address::from_slice(&keccak256(&uncompressed[1..])[12..])
    };

    let params = OpenParams {
        funding_block_hash_be: funding.block_hash_be,
        funding_block_height: funding.height,
        funding_tx_index: funding.tx_index,
        lp_pubkey,
        hop_pubkey,
        amount_sats: amount_sats_open,
        // SIMPLE-TAPROOT: the 32-byte x-only MuSig2 key-path aggregate Q. The harness
        // now opens a real P2TR (`0x5120||Q`) channel (the vendored LDK
        // `get_funding_spk` emits it for `supports_simple_taproot()` channels), so this
        // Q byte-matches the on-chain funding output located above by
        // `funded_output_taproot`. The EVM rebuilds `0x5120||Q` from this field and
        // byte-matches the same output (it does NO secp256k1 EC math).
        funding_taproot: quid_hop::funding::taproot_funding_aggregate_xonly(
            &lp_pubkey, &hop_pubkey,
        ),
    };
    // MULTI-HOP v2 digest: bind the submitting hop. This fixture's lpAuth is a
    // convenience artifact (the Solidity OpenChannelE2E test re-signs in-test), so
    // ZERO is fine here; a live submitter would bind its own address.
    let digest = open_channel_digest(chain_id, btc_channels, &funding.raw, &params, Address::ZERO);
    let msg = Message::from_digest(digest);
    let sig = secp.sign_ecdsa_recoverable(&msg, &lp_sk);
    let (rec_id, compact) = sig.serialize_compact();
    // EVM lpAuth = r ‖ s ‖ v, v = 27 + parity (OZ ECDSA.recover convention).
    let mut lp_auth = Vec::with_capacity(65);
    lp_auth.extend_from_slice(&compact[0..32]);
    lp_auth.extend_from_slice(&compact[32..64]);
    lp_auth.push(27 + rec_id.to_i32() as u8);
    eprintln!("e2e_ffi: lpEth = {lp_eth} (recovers from lpAuth over the digest)");

    // ── the bundle (Solidity abi.decode(out, (Bundle)) order). A single struct
    // ⇒ leading 0x20 offset + the field tuple (encode_struct). ──
    let toks = vec![
        // SPV header chain
        Tok::Bytes(genesis_header),                  // 0 genesisHeader
        Tok::BytesArray(headers),                    // 1 headers (1..=tip)
        Tok::Uint(U256::from(tip)),                  // 2 tip
        // openChannel
        Tok::Bytes(funding.raw),                     // 3 rawFundingTx (legacy)
        Tok::FixedBytes32(funding.block_hash_be),    // 4 fundingBlockHash (BE)
        Tok::Uint(U256::from(funding.height)),       // 5 fundingHeight
        Tok::Uint(U256::from(funding.tx_index)),     // 6 fundingTxIndex
        Tok::FixedBytes32Array(funding.merkle_proof), // 7 fundingMerkleProof
        Tok::Bytes(params.lp_pubkey.to_vec()),       // 8 lpPubkey
        Tok::Bytes(params.hop_pubkey.to_vec()),      // 9 hopPubkey
        Tok::Uint(U256::from(amount_sats_open)),     // 10 amountSats
        // SIMPLE-TAPROOT: the REAL 32-byte x-only MuSig2 key-path aggregate Q of the
        // funding output (`0x5120||Q`). The EVM rebuilds the scriptPubKey from this and
        // byte-matches the live funding tx, so the bundle MUST carry the genuine Q (not
        // a synthetic stand-in) — that is exactly what `params.funding_taproot` is, and
        // it is the same Q the LP's lpAuth (next field) is signed over.
        Tok::FixedBytes32(params.funding_taproot),   // 11 fundingTaproot (real Q)
        Tok::Bytes(lp_auth),                         // 12 lpAuth (r‖s‖v)
        // settleSwapIn
        Tok::Address(seller),                        // 13 seller
        Tok::Uint(U256::from(amount_sats)),          // 14 sats
        Tok::Address(token),                         // 15 token
        Tok::FixedBytes32(payment_hash),             // 16 paymentHash
        // recordClose
        Tok::Bytes(close.raw),                       // 17 rawCloseTx (legacy)
        Tok::FixedBytes32(close.block_hash_be),      // 18 closeBlockHash (BE)
        Tok::FixedBytes32Array(close.merkle_proof),  // 19 closeMerkleProof
        Tok::Uint(U256::from(close.tx_index)),       // 20 closeTxIndex
    ];
    let bundle = encode_struct(&toks);

    drop(node_a);
    drop(node_b);
    drop(regtest);
    bundle
}

/// FIXTURE MODE: open a real simple-taproot (P2TR `0x5120||Q`) channel against
/// live bitcoind, cooperatively close it, and write the `OpenChannelE2E.t.sol`
/// JSON fixture (funding tx + SPV proof + `fundingTaproot` + the genesis/header
/// chain) to `out_path`. NO swap-in/out (HTLCs are a deferred milestone) — this
/// is purely the open + coop-close path the M8 hop e2e already proves green.
async fn run_fixture(out_path: &str) {
    let regtest = Regtest::start();
    let seed_a = 0xA11CE_u64;
    let seed_b = 0xB0B_u64;
    let pk_a = RootSeed::from_u64(seed_a).derive_node_pk();
    let pk_b = RootSeed::from_u64(seed_b).derive_node_pk();
    let port_a = 19_876_u16;
    let port_b = 19_877_u16;

    let node_a = boot_node(&regtest, seed_a, "a", lsp_info(pk_b.clone(), port_b)).await;
    let node_b = boot_node(&regtest, seed_b, "b", lsp_info(pk_a.clone(), port_a)).await;
    let _listener_a = spawn_listener(&node_a, port_a).await;

    let addr_b = node_b.wallet.get_address().to_string();
    regtest.mine_to(&addr_b, 101);
    bdk_full_sync(&node_b).await;
    assert!(node_b.wallet.get_balance().confirmed.to_sat() > 0, "B funded");

    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    let _conn = connect(&node_b, &pk_a, port_a).await;
    let channel_value_sats = 5_000_000_u64;
    node_b
        .channel_manager
        .create_channel(pk_a.0, channel_value_sats, 0, 1u128, None, None)
        .expect("create_channel");

    wait_until(60, Duration::from_millis(250), || regtest.mempool_len() > 0).await;

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

    let chan = node_b
        .channel_manager
        .list_channels()
        .into_iter()
        .next()
        .expect("one channel");
    let funding_txo = chan.funding_txo.expect("funding txo after confirm");
    let funding_txid = Txid::from_raw_hash(*funding_txo.txid.as_raw_hash());

    // Recover the funding pubkeys witness-free (taproot key-path close) + locate the
    // P2TR funded output, then derive the 32-byte x-only aggregate Q.
    let (holder_pk, cp_pk) = quid_hop::node::channel_funding_pubkeys(
        &node_b.chain_monitor,
        &node_b.channel_manager,
        funding_txid,
        funding_txo.index as u32,
    )
    .expect("funding pubkeys from monitor");
    let (lp_pubkey, hop_pubkey) = quid_hop::evm_codec::sort_funding_pubkeys(holder_pk, cp_pk);

    // Cooperatively close + bury it (the OpenChannelE2E fixture only consumes the
    // open side, but closing leaves the harness clean + matches the e2e shape).
    node_b
        .channel_manager
        .close_channel(&chan.channel_id, &pk_a.0)
        .expect("close_channel");
    wait_until(120, Duration::from_millis(250), || regtest.mempool_len() > 0).await;
    regtest.mine(8);
    ldk_resync(&node_a).await;
    ldk_resync(&node_b).await;

    // Pull SPV data: the funding inclusion proof + the genesis/header chain to tip.
    let funding = tx_inclusion(&node_b.esplora, &funding_txid)
        .await
        .expect("funding inclusion");
    let (_vout, amount_sats) =
        quid_hop::evm_codec::funded_output_taproot(&funding.raw, &lp_pubkey, &hop_pubkey)
            .expect("P2TR (0x5120||Q) funded output");
    let funding_taproot = quid_hop::funding::taproot_funding_aggregate_xonly(&lp_pubkey, &hop_pubkey);

    let client = node_b.esplora.client().clone();
    let tip = client.get_height().await.expect("tip height") as u64;
    let genesis_hash = client.get_block_hash(0).await.expect("genesis hash");
    let genesis_header = serialize_header(&node_b.esplora, &genesis_hash)
        .await
        .expect("genesis header");
    let mut headers: Vec<String> = Vec::with_capacity(tip as usize);
    for h in 1..=tip {
        let bh = client.get_block_hash(h as u32).await.expect("block hash");
        headers.push(hex0x(
            &serialize_header(&node_b.esplora, &bh).await.expect("header"),
        ));
    }

    // Emit the JSON in the OpenChannelE2E.t.sol shape (0x-hex bytes, decimal ints).
    // Built by hand (flat object, no nesting) to avoid pulling a json crate in.
    let merkle = json_str_array(&funding.merkle_proof.iter().map(|m| hex0x(m)).collect::<Vec<_>>());
    let headers_arr = json_str_array(&headers);
    let json = format!(
        concat!(
            "{{\n",
            "  \"lpPubkey\": \"{lp}\",\n",
            "  \"hopPubkey\": \"{hop}\",\n",
            "  \"amountSats\": {amount},\n",
            "  \"fundingTaproot\": \"{taproot}\",\n",
            "  \"rawFundingTx\": \"{raw}\",\n",
            "  \"fundingTxidDisplay\": \"{txid}\",\n",
            "  \"fundingBlockHashBE\": \"{bhash}\",\n",
            "  \"fundingHeight\": {height},\n",
            "  \"txIndex\": {txindex},\n",
            "  \"merkleBranch\": {merkle},\n",
            "  \"genesisHeader\": \"{genesis}\",\n",
            "  \"headers\": {headers},\n",
            "  \"tip\": {tip}\n",
            "}}\n",
        ),
        lp = hex0x(&lp_pubkey),
        hop = hex0x(&hop_pubkey),
        amount = amount_sats,
        taproot = hex0x(&funding_taproot),
        raw = hex0x(&funding.raw),
        txid = funding_txid,
        bhash = hex0x(&funding.block_hash_be),
        height = funding.height,
        txindex = funding.tx_index,
        merkle = merkle,
        genesis = hex0x(&genesis_header),
        headers = headers_arr,
        tip = tip,
    );
    std::fs::write(out_path, json).expect("write fixture json");

    drop(node_a);
    drop(node_b);
    drop(regtest);
}

/// `0x`-prefixed lowercase hex (the encoding Foundry's `vm.parseJsonBytes*` reads).
fn hex0x(b: &[u8]) -> String {
    format!("0x{}", hex_encode(b))
}

/// Render `["a","b",…]` for a JSON string array (already-quoted-value elements).
fn json_str_array(items: &[String]) -> String {
    let mut s = String::from("[");
    for (i, it) in items.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('"');
        s.push_str(it);
        s.push('"');
    }
    s.push(']');
    s
}

/// Poll `cond` up to `tries` times, sleeping `delay` between, panicking if never
/// true (used to wait on the funding/close tx reaching the mempool).
async fn wait_until<F: Fn() -> bool>(tries: u32, delay: Duration, cond: F) {
    for _ in 0..tries {
        if cond() {
            return;
        }
        tokio::time::sleep(delay).await;
    }
    panic!("condition not met after {tries} tries");
}
