//! §PP-RELAYER end to end: the Rust relayer's `POST /pp/relay` against the REAL pool stack with a
//! REAL proof, on a real anvil node.
//!
//! The world is `WithdrawEndToEnd.t.sol`'s — Entrypoint, IdentityRegistry, PrivacyPoolSimple, the
//! Honk verifier, four deposits, three registrations — dumped by `test_DumpStateForRelayer` and
//! loaded into anvil as a genesis alloc at the fixture's clock and chain id (SCOPE commits to both).
//! The proof is `withdraw_relay_e2e.proof`, built for `RelayData{0xFEED, anvil#0, 300 bps}`, and
//! the relayer signs with anvil#0 so the fee lands where the Solidity test says it does.
//!
//! Gated on `PP_RELAY_E2E=1` (needs `forge`, `anvil`, the fixtures, and a compiled `evm/`).
//! Run:  PP_RELAY_E2E=1 cargo test -p quid-bridge --test pp_relay_e2e -- --nocapture

use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, keccak256, Address, U256};
use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde_json::{json, Value};

use quid_bridge::client::JsonRpcEvmClient;
use quid_bridge::config::BridgeConfig;
use quid_bridge::pp_relay::{quote, relay, PpRelayIngrid, ProofReq, QuoteQuery, RelayReq, WithdrawalReq};
use quid_bridge::signer::LocalSigner;
use quid_bridge::transport::{HttpJsonRpc, JsonRpc, QuorumJsonRpc};

/// anvil account #0 — `RELAY_FEE_RECIPIENT` in `WithdrawEndToEnd.t.sol`.
const ANVIL_KEY0: &str = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const PORT: u16 = 8599;

struct Anvil(Child);
impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.0.kill();
    }
}

fn repo() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

fn cfg(rpc_url: String) -> BridgeConfig {
    BridgeConfig {
        rpc_url,
        rpc_urls: Vec::new(),
        rpc_quorum: 1,
        chain_id: 1,
        btc_channels: Address::ZERO,
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
        spv_gateway: Address::ZERO,
        relay_batch_max: 1,
        relay_gas_limit: 8_000_000,
        relay_poll_secs: 1,
        relay_reorg_lookback: 1,
        channel_reconcile_secs: 300,
        relayer_defer_inflight: 0,
    }
}

/// Dump the Solidity world, wrap it as a genesis alloc, boot anvil on it. Returns the meta the
/// Solidity test wrote beside the dump.
fn boot_world() -> (Anvil, Value) {
    let evm = repo().join("evm");
    let dir = evm.join(".pp-relay-e2e");
    std::fs::create_dir_all(&dir).unwrap();
    let dump = dir.join("state.json");
    let st = Command::new("forge")
        .current_dir(&evm)
        .env("PP_RELAY_STATE_DUMP", ".pp-relay-e2e/state.json")
        .args(["test", "--match-contract", "RelayWorldDump", "--match-test", "test_DumpStateForRelayer", "--match-path",
               "test/identity/pool/WithdrawEndToEnd.t.sol"])
        .stdout(Stdio::null())
        .status()
        .expect("forge");
    assert!(st.success(), "forge test_DumpStateForRelayer failed");
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("state.json.meta.json")).unwrap()).unwrap();
    let alloc: Value = serde_json::from_str(&std::fs::read_to_string(&dump).unwrap()).unwrap();
    // One hour past the fixture clock: every activation delay the world was built around has
    // elapsed, and nothing in it has expired (test_CurrentIdentityRootSurvivesTheSameDelay).
    let ts = meta["timestamp"].as_u64().unwrap() + 3600;
    let genesis = json!({
        "config": {"chainId": 1}, "alloc": alloc, "difficulty": "0x0", "gasLimit": "0x1c9c380",
        "timestamp": format!("0x{ts:x}"), "coinbase": Address::ZERO.to_string(), "extraData": "0x",
        "nonce": "0x0", "mixHash": format!("0x{}", "00".repeat(32)), "parentHash": format!("0x{}", "00".repeat(32)),
    });
    let genesis_path = dir.join("genesis.json");
    std::fs::write(&genesis_path, genesis.to_string()).unwrap();
    let child = Command::new("anvil")
        // `--init` derives the hardfork from the genesis `config`, which names none, so without
        // `--hardfork` the node runs FRONTIER and the first cancun opcode dies as `NotActivated`.
        .args(["--chain-id", "1", "--hardfork", "prague", "--port", &PORT.to_string(),
               "--init", genesis_path.to_str().unwrap(), "--silent"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("anvil");
    let anvil = Anvil(child);
    let rpc = HttpJsonRpc::new(format!("http://127.0.0.1:{PORT}"));
    for _ in 0..60 {
        if rpc.call("eth_chainId", json!([])).is_ok() {
            return (anvil, meta);
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("anvil did not come up");
}

fn u256(v: &Value) -> U256 {
    let s = v.as_str().map(str::to_string).unwrap_or_else(|| v.as_u64().unwrap().to_string());
    U256::from_str_radix(&s, 10).unwrap()
}

fn relay_req(meta: &Value, fee_recipient: Address) -> RelayReq {
    let sigs: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(repo().join("evm/test/identity/fixtures/withdraw_relay_e2e_pubsignals.json")).unwrap(),
    )
    .unwrap();
    // abi.encode(RelayData{recipient, feeRecipient, relayFeeBPS}) — three words.
    let word = |a: Address| { let mut w = [0u8; 32]; w[12..].copy_from_slice(a.as_slice()); w };
    let recipient: Address = meta["recipient"].as_str().unwrap().parse().unwrap();
    let mut data = Vec::with_capacity(96);
    data.extend_from_slice(&word(recipient));
    data.extend_from_slice(&word(fee_recipient));
    data.extend_from_slice(&U256::from(meta["relayFeeBPS"].as_u64().unwrap()).to_be_bytes::<32>());
    RelayReq {
        withdrawal: WithdrawalReq {
            processooor: meta["entrypoint"].as_str().unwrap().to_string(),
            data: format!("0x{}", hex::encode(data)),
        },
        proof: ProofReq { proof: meta["proof"].as_str().unwrap().to_string(), pub_signals: sigs },
        scope: u256(&meta["scope"]).to_string(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relays_a_real_withdrawal_through_the_real_entrypoint_on_anvil() {
    if std::env::var("PP_RELAY_E2E").as_deref() != Ok("1") {
        eprintln!("PP_RELAY_E2E unset: skipping (needs forge, anvil, and the identity fixtures)");
        return;
    }
    let (_anvil, meta) = boot_world();
    let url = format!("http://127.0.0.1:{PORT}");
    let http: Arc<dyn JsonRpc> = Arc::new(HttpJsonRpc::new(url.clone()));
    let rpc = Arc::new(QuorumJsonRpc::new(vec![http], 1));
    let mut key = [0u8; 32];
    hex::decode_to_slice(ANVIL_KEY0, &mut key).unwrap();
    let signer = LocalSigner::from_secret_key_bytes(key).unwrap();
    let evm = Arc::new(JsonRpcEvmClient::new(rpc.clone(), signer, cfg(url)));
    let relayer = evm.address();
    assert_eq!(relayer.to_string().to_lowercase(), meta["feeRecipient"].as_str().unwrap().to_lowercase(),
        "the relayer must be the feeRecipient the fixture proof committed to");
    let entrypoint: Address = meta["entrypoint"].as_str().unwrap().parse().unwrap();
    let recipient: Address = meta["recipient"].as_str().unwrap().parse().unwrap();
    let ingrid = Some(Arc::new(PpRelayIngrid { evm: evm.clone(), rpc: rpc.clone(), entrypoint }));

    // GET: the address the app must put in RelayData, and the fee that clears the gas check for
    // this withdrawal. The fixture's 300 bps was chosen to clear it at anvil's gas price; the
    // quote must agree, or the app would prove a fee the relayer then refuses.
    let withdrawn = U256::from(300_000_000_000_000_000u128);
    let q = quote(State(ingrid.clone()), axum::extract::Query(QuoteQuery { value: Some(withdrawn.to_string()) }))
        .await
        .unwrap();
    assert_eq!(q.0["fee_recipient"].as_str().unwrap().to_lowercase(), relayer.to_string().to_lowercase());
    let min_bps: u64 = q.0["min_fee_bps"].as_str().unwrap().parse().unwrap();
    assert!(min_bps > 0 && min_bps <= 300, "quote {min_bps} bps must be within the fixture's 300");

    let balance = |who: Address| -> U256 {
        let v = rpc.call("eth_getBalance", json!([who.to_string(), "latest"])).unwrap();
        U256::from_str_radix(v.as_str().unwrap().trim_start_matches("0x"), 16).unwrap()
    };
    assert_eq!(balance(recipient), U256::ZERO, "fresh recipient holds nothing before");

    // A proof bound to someone else's fee: refused before any RPC.
    let e = relay(State(ingrid.clone()), Json(relay_req(&meta, Address::repeat_byte(0xBA)))).await.unwrap_err();
    assert_eq!(e.0, StatusCode::BAD_REQUEST);
    assert!(e.1.contains("feeRecipient"), "{}", e.1);

    // The real thing.
    let ok = relay(State(ingrid.clone()), Json(relay_req(&meta, relayer))).await
        .unwrap_or_else(|e| panic!("relay refused: {} {}", e.0, e.1));
    assert_eq!(ok.0["success"], json!(true));

    let fee = withdrawn * U256::from(meta["relayFeeBPS"].as_u64().unwrap()) / U256::from(10_000u64);
    assert_eq!(balance(recipient), withdrawn - fee, "recipient paid net of the fee");

    // WithdrawalRelayed(relayer, recipient, asset, amount, feeAmount) — indexed relayer/recipient.
    let topic0 = keccak256(b"WithdrawalRelayed(address,address,address,uint256,uint256)");
    let logs = rpc
        .call("eth_getLogs", json!([{ "fromBlock": "0x0", "toBlock": "latest", "address": entrypoint.to_string(),
            "topics": [format!("{topic0:?}")] }]))
        .unwrap();
    let logs = logs.as_array().unwrap();
    assert_eq!(logs.len(), 1, "exactly one WithdrawalRelayed");
    let topics = logs[0]["topics"].as_array().unwrap();
    assert!(topics[1].as_str().unwrap().to_lowercase().ends_with(&relayer.to_string().to_lowercase()[2..]));
    assert!(topics[2].as_str().unwrap().to_lowercase().ends_with(&recipient.to_string().to_lowercase()[2..]));

    // The same proof again: the node's simulation names the pool's refusal, and no tx is sent.
    let e = relay(State(ingrid.clone()), Json(relay_req(&meta, relayer))).await.unwrap_err();
    assert_eq!(e.0, StatusCode::BAD_REQUEST, "{}", e.1);
    assert!(e.1.contains("NullifierAlreadySpent()"), "replay must be named, got: {}", e.1);
    assert_eq!(balance(recipient), withdrawn - fee, "a refused relay moved nothing");
}
