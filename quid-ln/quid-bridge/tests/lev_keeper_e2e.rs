//! Lev-keeper LIVE round-trip e2e against a REAL anvil node.
//!
//! Proves the one part of the keeper that unit tests can't: the concrete `DaemonLevKeeper` actually
//! eth_calls the read surface (decoding real return data into a `PositionView`), runs the decision, and
//! eth_sendRawTransaction's the resulting writes — end to end against a real EVM node. The deploy target is
//! `evm/test/harness/LevKeeperTarget.sol`: it returns a position URGENTLY near liquidation (so the keeper
//! must cascade-de-lever) and records the writes. The protocol logic (LevManager/Vogue) is fork-proven
//! elsewhere; this isolates the keeper's RPC plumbing.
//!
//! Self-contained: spawns its own anvil and deploys via `cast`. If `anvil`/`cast` aren't on PATH (e.g. a CI
//! box without foundry), it skips cleanly rather than failing (not a masked #[ignore]).

use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::Address;
use quid_bridge::client::JsonRpcEvmClient;
use quid_bridge::config::BridgeConfig;
use quid_bridge::lev_keeper::{tick, DaemonLevKeeper, DwellTracker, LevKeeperConfig};
use quid_bridge::signer::LocalSigner;
use quid_bridge::transport::HttpJsonRpc;

const ANVIL_KEY_HEX: &str = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil acct 0

struct AnvilGuard(Child);
impl Drop for AnvilGuard {
    fn drop(&mut self) { let _ = self.0.kill(); }
}

fn have(bin: &str) -> bool {
    Command::new(bin).arg("--version").stdout(Stdio::null()).stderr(Stdio::null())
        .status().map(|s| s.success()).unwrap_or(false)
}

fn cast_ok(args: &[&str]) -> bool {
    Command::new("cast").args(args).stdout(Stdio::null()).stderr(Stdio::null())
        .status().map(|s| s.success()).unwrap_or(false)
}

fn cast_call_bool(url: &str, to: &Address, sig: &str) -> bool {
    let out = Command::new("cast").args(["call", &to.to_string(), sig, "--rpc-url", url])
        .output().expect("cast call");
    String::from_utf8_lossy(&out.stdout).trim() == "true"
}

#[tokio::test]
async fn lev_keeper_live_round_trip_against_anvil() {
    if !have("anvil") || !have("cast") {
        eprintln!("SKIP lev_keeper_live_round_trip: anvil/cast not on PATH");
        return;
    }
    let port = 8557u16;
    let url = format!("http://127.0.0.1:{port}");

    // 1) Spawn anvil (fresh deterministic chain) — killed on drop even if an assert panics.
    let anvil = Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent", "--chain-id", "31337"])
        .stdout(Stdio::null()).stderr(Stdio::null())
        .spawn().expect("spawn anvil");
    let _guard = AnvilGuard(anvil);
    for _ in 0..50 {
        if cast_ok(&["block-number", "--rpc-url", &url]) { break; }
        std::thread::sleep(Duration::from_millis(200));
    }

    // 2) Deploy the harness via cast (bytecode from the forge artifact; out/ is gitignored, so skip if absent).
    let artifact = concat!(env!("CARGO_MANIFEST_DIR"), "/../../evm/out/LevKeeperTarget.sol/LevKeeperTarget.json");
    let Ok(src) = std::fs::read_to_string(artifact) else {
        eprintln!("SKIP lev_keeper_live_round_trip: no forge artifact (run `forge build` in evm/ first)");
        return;
    };
    let json: serde_json::Value = serde_json::from_str(&src).unwrap();
    let bytecode = json["bytecode"]["object"].as_str().expect("bytecode.object");
    let out = Command::new("cast")
        .args(["send", "--rpc-url", &url, "--private-key", ANVIL_KEY_HEX, "--create", bytecode, "--json"])
        .output().expect("cast send --create");
    assert!(out.status.success(), "deploy failed: {}", String::from_utf8_lossy(&out.stderr));
    let receipt: serde_json::Value = serde_json::from_slice(&out.stdout).expect("deploy receipt json");
    let harness: Address = receipt["contractAddress"].as_str().expect("contractAddress").parse().expect("addr");

    // 3) Build the REAL signing client + keeper, pointed at the harness as both lev_manager and vogue.
    let mut key = [0u8; 32];
    for i in 0..32 { key[i] = u8::from_str_radix(&ANVIL_KEY_HEX[i * 2..i * 2 + 2], 16).unwrap(); }
    let evm = Arc::new(JsonRpcEvmClient::new(
        HttpJsonRpc::new(url.clone()),
        LocalSigner::from_secret_key_bytes(key).expect("signer"),
        test_cfg(url.clone())));
    let keeper = DaemonLevKeeper {
        evm, lev_manager: harness, vogue: harness, quid: harness, venue_liq_ltv_bps: 8600, gas_limit: 500_000, lp_scan_from: 0,
    };

    // 4) Run ONE keeper tick against the real node. The harness reports LTV 9000 (near the 8600 liq) ⇒ the
    //    keeper classifies it URGENT and must send cascadeDelever + syncLev — exercising the full
    //    eth_call(decode) → decide → eth_sendRawTransaction(encode/sign) round-trip.
    let mut dwell = DwellTracker::default();
    tick(&keeper, &LevKeeperConfig::default(), &mut dwell, 1_700_000_000, 1800).await.expect("keeper tick");

    // 5) Verify the writes actually LANDED on-chain.
    let (cascaded, synced) = (cast_call_bool(&url, &harness, "cascaded()(bool)"), cast_call_bool(&url, &harness, "synced()(bool)"));
    eprintln!("RAN keeper e2e @ {harness}: cascaded={cascaded} synced={synced}");
    assert!(cascaded, "keeper's cascadeDelever tx did not land on-chain");
    assert!(synced, "keeper's syncLev tx did not land on-chain");
}

fn test_cfg(rpc_url: String) -> BridgeConfig {
    BridgeConfig {
        rpc_url, rpc_urls: Vec::new(), rpc_quorum: 1, chain_id: 31337,
        btc_channels: Address::ZERO, min_confirmations: 1, min_cltv_headroom_blocks: 40,
        settle_max_retries: 1, retry_backoff_secs: 0,
        max_fee_per_gas: 100_000_000_000, max_priority_fee_per_gas: 1_000_000_000, gas_limit: 500_000,
        receipt_poll_attempts: 30, receipt_poll_secs: 1, fee_bump_attempts: 3, fee_bump_pct: 125,
        settle_min_confirmations: 1, max_log_block_span: 10_000, swap_out_poll_secs: 1,
        btc_vault: Address::ZERO, spv_gateway: Address::ZERO,
        relay_batch_max: 100, relay_gas_limit: 8_000_000, relay_poll_secs: 1, relay_reorg_lookback: 144,
        channel_reconcile_secs: 300, relayer_defer_inflight: 0,
    }
}
