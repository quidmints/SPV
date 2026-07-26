//! Anti-rollback FreshnessLedger LIVE round-trip against a REAL anvil node.
//!
//! Proves the bridge's on-chain [`BtcChannelsFreshnessLedger`] actually
//! `eth_sendRawTransaction`s `commitFreshness` and `eth_call`s `freshnessSeq` end to
//! end against a real EVM node, AND that a rolled-back/replayed seq is REJECTED
//! on-chain by the monotonic guard (surfacing as `store()` → Err). Deploys
//! `evm/test/harness/FreshnessTarget.sol` (the same monotonic surface as
//! `BTCChannels.commitFreshness`; the hop-gating is proven against the real
//! BTCChannels in `BtcLpMintStress.testCommitFreshness_HopGated_Monotonic`).
//!
//! Self-contained: spawns its own anvil + deploys via `cast`. Skips cleanly if
//! anvil/cast/forge-artifact are absent (not a masked `#[ignore]`).

use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, Address};
use quid_bridge::client::JsonRpcEvmClient;
use quid_bridge::config::BridgeConfig;
use quid_bridge::freshness_ledger::BtcChannelsFreshnessLedger;
use quid_bridge::signer::LocalSigner;
use quid_bridge::transport::HttpJsonRpc;
use quid_hop::freshness::FreshnessLedger;

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

/// Advance the chain by `n` blocks. The ledger's `highest()` reads a quorum-agreed
/// CONFIRMED block (`tip − AGREED_READ_DEPTH`, =6), not the tip — production boot
/// reads a confirmed block, and every commit it checks is already buried. So after
/// each commit we mine > AGREED_READ_DEPTH so the read-back sees it.
fn mine(url: &str, n: u32) {
    let _ = Command::new("cast")
        .args(["rpc", "--rpc-url", url, "anvil_mine", &format!("0x{n:x}")])
        .stdout(Stdio::null()).stderr(Stdio::null()).status();
}
/// Blocks to mine after each commit — one past the client's AGREED_READ_DEPTH (6).
const CONFIRM: u32 = 7;

#[tokio::test]
async fn freshness_ledger_live_round_trip_against_anvil() {
    if !have("anvil") || !have("cast") {
        eprintln!("SKIP freshness_ledger_live_round_trip: anvil/cast not on PATH");
        return;
    }
    let port = 8559u16;
    let url = format!("http://127.0.0.1:{port}");

    // 1) Spawn anvil (killed on drop even if an assert panics).
    let anvil = Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent", "--chain-id", "31337"])
        .stdout(Stdio::null()).stderr(Stdio::null())
        .spawn().expect("spawn anvil");
    let _guard = AnvilGuard(anvil);
    for _ in 0..50 {
        if cast_ok(&["block-number", "--rpc-url", &url]) { break; }
        std::thread::sleep(Duration::from_millis(200));
    }

    // 2) Deploy the FreshnessTarget harness (out/ is gitignored, so skip if absent).
    let artifact = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../evm/out/FreshnessTarget.sol/FreshnessTarget.json"
    );
    let Ok(src) = std::fs::read_to_string(artifact) else {
        eprintln!("SKIP freshness_ledger_live_round_trip: no forge artifact (run `forge build` in evm/ first)");
        return;
    };
    let json: serde_json::Value = serde_json::from_str(&src).unwrap();
    let bytecode = json["bytecode"]["object"].as_str().expect("bytecode.object");
    let out = Command::new("cast")
        .args(["send", "--rpc-url", &url, "--private-key", ANVIL_KEY_HEX, "--create", bytecode, "--json"])
        .output().expect("cast send --create");
    assert!(out.status.success(), "deploy failed: {}", String::from_utf8_lossy(&out.stderr));
    let receipt: serde_json::Value = serde_json::from_slice(&out.stdout).expect("deploy receipt json");
    let target: Address = receipt["contractAddress"].as_str().expect("contractAddress").parse().expect("addr");

    // 3) Build the REAL signing client + the ledger over the deployed harness.
    let mut key = [0u8; 32];
    for i in 0..32 { key[i] = u8::from_str_radix(&ANVIL_KEY_HEX[i * 2..i * 2 + 2], 16).unwrap(); }
    let evm = Arc::new(JsonRpcEvmClient::new(
        HttpJsonRpc::new(url.clone()),
        LocalSigner::from_secret_key_bytes(key).expect("signer"),
        test_cfg(url.clone())));

    let cid = [0xABu8; 32];
    let cid_hex = hex::encode(cid);
    // Identity resolver: here the monitor key IS the channelId hex (production uses a
    // store-backed LDK-channel_id → on-chain-channelId resolver).
    let ledger = Arc::new(BtcChannelsFreshnessLedger::new(
        evm,
        target,
        200_000,
        quid_bridge::freshness_ledger::identity_resolver(),
    ));

    // 4) A never-committed channel reads None (freshnessSeq 0 ⇒ not yet anchored).
    //    Bury the deploy under the read depth so the agreed read hits a live block.
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(&cid_hex).unwrap(), None, "fresh channel: no anchored seq yet");

    // 5) store 5 → commitFreshness tx lands → on-chain freshnessSeq == 5 (real read-back
    //    once the commit is buried under the confirmed-read depth).
    ledger.store(&cid_hex, 5).unwrap();
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(&cid_hex).unwrap(), Some(5), "commitFreshness landed on-chain");

    // 6) store 9 (monotonic advance) → 9.
    ledger.store(&cid_hex, 9).unwrap();
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(&cid_hex).unwrap(), Some(9));

    // 7) store 3 (ROLLBACK/replay) → the on-chain monotonic guard REVERTS → store() Err,
    //    and the on-chain state is UNCHANGED. This is the whole point: the chain refuses
    //    to record a rolled-back sequence, so `highest()` never regresses.
    let rolled_back = ledger.store(&cid_hex, 3);
    assert!(rolled_back.is_err(), "on-chain monotonic guard MUST reject a rolled-back seq");
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(&cid_hex).unwrap(), Some(9), "state unchanged after rejected rollback");

    // 8) The ASYNC committer (the hot-path form): store() enqueues, a background thread
    //    coalesces a burst per channel and does the real on-chain write off the hot path.
    //    Enqueue an out-of-order burst; the on-chain result must be the MAX (40), landed
    //    via the committer (not inline).
    let (queued, _handle) =
        quid_bridge::freshness_ledger::QueuedFreshnessLedger::spawn(ledger.clone());
    queued.store(&cid_hex, 10).unwrap(); // all non-blocking enqueues
    queued.store(&cid_hex, 40).unwrap();
    queued.store(&cid_hex, 25).unwrap();
    let mut landed = None;
    for _ in 0..50 {
        // Bury whatever the committer has written so far under the confirmed-read
        // depth (the committer's commitFreshness auto-mines; we advance the tip past it).
        mine(&url, CONFIRM);
        if ledger.highest(&cid_hex).unwrap() == Some(40) {
            landed = Some(40);
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(landed, Some(40), "async committer coalesced the burst to max seq (40) on-chain");

    // 9) MANAGER-blob path. The SAME ledger routes `MANAGER_FRESHNESS_KEY`
    //    to `commitManagerFreshness(uint64)` / `managerFreshnessSeq(address)`, keyed
    //    on-chain by msg.sender (the hop = our signer). Same monotonic guard, no cid.
    use quid_hop::freshness::MANAGER_FRESHNESS_KEY;
    // Never committed ⇒ managerFreshnessSeq[signer] == 0 ⇒ None.
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(MANAGER_FRESHNESS_KEY).unwrap(), None, "manager: no anchored seq yet");
    // Commit 3 → read back 3 (per-hop slot advanced by our signer as msg.sender).
    ledger.store(MANAGER_FRESHNESS_KEY, 3).unwrap();
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(MANAGER_FRESHNESS_KEY).unwrap(), Some(3), "commitManagerFreshness landed");
    // Monotonic advance 7 → 7.
    ledger.store(MANAGER_FRESHNESS_KEY, 7).unwrap();
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(MANAGER_FRESHNESS_KEY).unwrap(), Some(7));
    // Rollback 2 → on-chain monotonic guard REVERTS → store() Err, slot unchanged at 7.
    assert!(ledger.store(MANAGER_FRESHNESS_KEY, 2).is_err(), "manager: rolled-back seq MUST be rejected");
    mine(&url, CONFIRM);
    assert_eq!(ledger.highest(MANAGER_FRESHNESS_KEY).unwrap(), Some(7), "manager slot unchanged after rejected rollback");

    eprintln!("RAN freshness ledger e2e @ {target}: monitor(commit + read-back + rollback-reject + async-committer-coalesce) + manager(commit + read-back + rollback-reject) all verified on real anvil");
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
