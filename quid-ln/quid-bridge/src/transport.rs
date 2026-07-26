//! Blocking JSON-RPC transport. A trait so the EVM client is unit-testable
//! against canned responses; the production impl is a plain blocking HTTP POST
//! (run on `spawn_blocking`, so no async runtime is needed here). The concrete
//! HTTP impl is added once the signer path is settled — see `client::TxSigner`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tracing::debug;

/// A blocking JSON-RPC caller.
pub trait JsonRpc: Send + Sync + 'static {
    /// Invoke `method` with `params`, returning the `result` value. Returns
    /// `Err` for a transport failure OR a JSON-RPC `error` object (both transient
    /// from the sender's view — it retries, then leaves the HTLC pending).
    fn call(&self, method: &str, params: Value) -> anyhow::Result<Value>;
}

/// Blanket impl so an `Arc<T>` is itself a `JsonRpc` — lets a single shared
/// transport (e.g. one `Arc<QuorumJsonRpc>`) be both passed by value into
/// `JsonRpcEvmClient::new` AND Arc-shared across the read-only watcher loops,
/// without cloning the underlying connections.
impl<T: JsonRpc + ?Sized> JsonRpc for Arc<T> {
    fn call(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        (**self).call(method, params)
    }
}

/// Production transport: a blocking JSON-RPC POST over HTTP(S) via `ureq`. Run on
/// `spawn_blocking` (it blocks), so no async runtime is involved.
pub struct HttpJsonRpc {
    url: String,
    agent: ureq::Agent,
    id: AtomicU64,
}

impl HttpJsonRpc {
    pub fn new(url: impl Into<String>) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(30))
            .build();
        Self {
            url: url.into(),
            agent,
            id: AtomicU64::new(1),
        }
    }
}

impl JsonRpc for HttpJsonRpc {
    fn call(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        let id = self.id.fetch_add(1, Ordering::Relaxed);
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        let resp: Value = self
            .agent
            .post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow::anyhow!("rpc transport: {e}"))?
            .into_json()
            .map_err(|e| anyhow::anyhow!("rpc decode: {e}"))?;
        parse_rpc_response(resp)
    }
}

/// Extract `result`, or surface a JSON-RPC `error`.
fn parse_rpc_response(resp: Value) -> anyhow::Result<Value> {
    if let Some(e) = resp.get("error") {
        if !e.is_null() {
            anyhow::bail!("JSON-RPC error: {e}");
        }
    }
    resp.get("result")
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("JSON-RPC response missing 'result'"))
}

// ───────────────────────── multi-endpoint quorum transport ─────────────────────
//
// `QuorumJsonRpc` removes single-RPC trust for the bridge's hot wallet. The
// deployment model is "self-host a primary node + cross-check against extra
// endpoints": a lying/faulty endpoint must not be able to make the daemon
// mis-spend. Every EVM read/send already flows through `JsonRpc::call`, so this
// wraps a `Vec` of inner transports and ROUTES each call by method class.
//
// SECURITY MODEL: the spend-gating reads (which swap is settled, channel state,
// btcRecipient, which logs to act on) MUST be agreed by a `quorum` of endpoints,
// or the call returns `Err`. Callers already treat `Err` as "defer/retry, leave
// the HTLC pending" — so an endpoint that lies or disagrees can only make the
// daemon WAIT, never act on an unverified read (fail SAFE). Advisory/monotonic
// reads (nonce, gas price, receipt polling, block height) take FIRST-HEALTHY —
// requiring agreement there would false-fail on legitimate tip lag. Broadcasts
// go to ALL endpoints (wider propagation + resilience), first success wins.

/// How a method routes across the endpoint set. This is the security-critical
/// decision point — see `classify`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MethodClass {
    /// Spend-gating reads: a `quorum` of endpoints must return BYTE-IDENTICAL
    /// values or the call fails (fail SAFE — never act on an unverified read).
    Agreement,
    /// `eth_sendRawTransaction`: fan out to ALL endpoints, first `Ok` wins.
    Broadcast,
    /// Advisory/monotonic reads: try endpoints in order, first `Ok` wins.
    FirstHealthy,
}

/// Is a block-tag param a CONCRETE block (a `0x…` hex quantity / a 32-byte block
/// hash), as opposed to a DYNAMIC tag (`latest`/`pending`/`earliest`/`safe`/
/// `finalized`)? AGREEMENT applies ONLY to concrete-block calls: near the tip,
/// honest endpoints legitimately differ, so requiring byte-identity on a dynamic
/// tag would false-fail. A concrete hex quantity must be identical across all
/// honest endpoints, so disagreement there is a real signal.
fn is_concrete_block_tag(tag: &Value) -> bool {
    match tag.as_str() {
        // A "0x…" string that is NOT one of the dynamic tags. Numeric block tags
        // and block hashes are both 0x-prefixed hex; both are concrete.
        Some(s) => {
            let lower = s.to_ascii_lowercase();
            !matches!(
                lower.as_str(),
                "latest" | "pending" | "earliest" | "safe" | "finalized"
            ) && lower.starts_with("0x")
        }
        // A block-tag object (e.g. { "blockHash": "0x…" }) is concrete; absence /
        // a non-string tag is treated as NOT concrete (fall through to first-healthy).
        None => tag.is_object(),
    }
}

/// Decide the routing class for `method` given its `params`. KEEP THIS READABLE —
/// it is the single point that decides which reads are spend-gating.
///
/// NOTE FOR FUTURE MAINTAINERS: any NEW read that gates a spend (a wrong answer
/// loses funds) MUST be added to the AGREEMENT arm below. Unknown methods default
/// to FIRST-HEALTHY (advisory) — which is SAFE for non-spend-gating reads but
/// would be UNSAFE for a new spend-gating one. When in doubt, gate it.
pub fn classify(method: &str, params: &Value) -> MethodClass {
    // Block-tag extractor: the Nth element of a positional params array.
    let arg = |i: usize| params.get(i);

    match method {
        // ---- BROADCAST: fan out to all, first success wins. ----
        "eth_sendRawTransaction" => MethodClass::Broadcast,

        // ---- AGREEMENT (spend-gating), but ONLY when the call pins a concrete
        //      block — otherwise tip lag makes honest endpoints disagree. ----

        // eth_call gates swapInUsed / swapOutUsed / channel-state / btcRecipient /
        // hopNode. Block tag is the 2nd positional arg.
        "eth_call" => match arg(1) {
            Some(tag) if is_concrete_block_tag(tag) => MethodClass::Agreement,
            _ => MethodClass::FirstHealthy, // "latest" etc. → tip-relative, advisory
        },

        // eth_getBlockByNumber: 1st arg is the block tag.
        "eth_getBlockByNumber" => match arg(0) {
            Some(tag) if is_concrete_block_tag(tag) => MethodClass::Agreement,
            _ => MethodClass::FirstHealthy,
        },

        // eth_getLogs gates which swaps/fees to act on. AGREEMENT only when BOTH
        // fromBlock and toBlock are concrete hex quantities (a fully-pinned range
        // returns identical bytes from honest endpoints); otherwise advisory.
        "eth_getLogs" => {
            let filter = arg(0);
            let from = filter.and_then(|f| f.get("fromBlock"));
            let to = filter.and_then(|f| f.get("toBlock"));
            match (from, to) {
                (Some(f), Some(t)) if is_concrete_block_tag(f) && is_concrete_block_tag(t) => {
                    MethodClass::Agreement
                }
                _ => MethodClass::FirstHealthy,
            }
        }

        // eth_getBlockByHash pins a concrete block by hash; eth_chainId is a
        // constant; eth_getCode gates the boot-time "BTCChannels has code" config
        // sanity check (deployed bytecode is stable). All always AGREEMENT — cheap,
        // and it stops a lying endpoint from faking the contract's existence at boot.
        "eth_getBlockByHash" | "eth_chainId" | "eth_getCode" => MethodClass::Agreement,

        // ---- FIRST-HEALTHY: advisory / monotonic; agreement would false-fail. ----
        // eth_blockNumber, eth_getTransactionCount (nonce), eth_getTransactionReceipt,
        // eth_estimateGas, eth_gasPrice, eth_maxPriorityFeePerGas, eth_feeHistory,
        // plus the dynamic-tag eth_call/eth_getBlockByNumber/eth_getLogs cases
        // handled above, and any UNKNOWN method.
        //
        // SAFETY: defaulting unknowns to FIRST-HEALTHY is correct for advisory reads
        // but WRONG for a new spend-gating read — add those to AGREEMENT above.
        _ => MethodClass::FirstHealthy,
    }
}

/// A `JsonRpc` that fans calls across multiple endpoints and cross-checks the
/// spend-gating reads, so no single endpoint can make the daemon mis-spend.
/// `endpoints[0]` is the primary (expected to be the self-hosted node).
pub struct QuorumJsonRpc {
    endpoints: Vec<Arc<dyn JsonRpc>>,
    quorum: usize,
    /// FRONTRUNNING PROTECTION: private-relay endpoints (Flashbots Protect / MEV
    /// Blocker) used ONLY for `eth_sendRawTransaction`. Broadcasting a signed tx
    /// to the public read RPCs would land it in the PUBLIC MEMPOOL, where it can
    /// be sandwiched / frontrun. When non-empty, signed-tx broadcast goes to
    /// THESE (relay-only); reads/gas/nonce stay on the public quorum endpoints.
    /// Empty ⇒ legacy behaviour (broadcast to all `endpoints`).
    send_endpoints: Vec<Arc<dyn JsonRpc>>,
}

impl QuorumJsonRpc {
    /// `endpoints` must be non-empty; `quorum` is clamped to `[1, endpoints.len()]`
    /// (the daemon's config validation enforces the same bounds up front, so a
    /// well-formed deployment never hits the clamp).
    pub fn new(endpoints: Vec<Arc<dyn JsonRpc>>, quorum: usize) -> Self {
        assert!(!endpoints.is_empty(), "QuorumJsonRpc needs at least one endpoint");
        let quorum = quorum.clamp(1, endpoints.len());
        Self { endpoints, quorum, send_endpoints: Vec::new() }
    }

    /// Route `eth_sendRawTransaction` through these PRIVATE-RELAY endpoints only
    /// (frontrunning protection). Reads/gas/nonce keep using the public quorum
    /// endpoints. Empty `eps` ⇒ no change (legacy broadcast-to-all).
    pub fn with_send_endpoints(mut self, eps: Vec<Arc<dyn JsonRpc>>) -> Self {
        self.send_endpoints = eps;
        self
    }

    /// AGREEMENT: query endpoints until `quorum` of them return BYTE-IDENTICAL
    /// values; return that value. If quorum is not reached (disagreement or too
    /// many errors), return `Err` — callers treat `Err` as defer/retry, so we
    /// fail SAFE and never act on an unverified read.
    fn call_agreement(&self, method: &str, params: &Value) -> anyhow::Result<Value> {
        // Tally byte-identical responses. Endpoint count is tiny (a handful), so a
        // linear scan over (value, count) pairs is simpler and faster than hashing.
        let mut tally: Vec<(Value, usize)> = Vec::new();
        let mut last_err: Option<anyhow::Error> = None;
        for (i, ep) in self.endpoints.iter().enumerate() {
            match ep.call(method, params.clone()) {
                Ok(v) => {
                    if let Some(slot) = tally.iter_mut().find(|(val, _)| *val == v) {
                        slot.1 += 1;
                        if slot.1 >= self.quorum {
                            return Ok(slot.0.clone());
                        }
                    } else {
                        if self.quorum <= 1 {
                            return Ok(v); // quorum 1 → first Ok agrees with itself
                        }
                        tally.push((v, 1));
                    }
                }
                Err(e) => {
                    debug!(endpoint = i, %method, error = %e, "quorum: endpoint read errored");
                    last_err = Some(e);
                }
            }
        }
        // No value reached quorum. Surface the disagreement / last error so the
        // caller defers (leaving the HTLC pending) rather than acting.
        let agreed_max = tally.iter().map(|(_, c)| *c).max().unwrap_or(0);
        anyhow::bail!(
            "quorum NOT reached for {method}: needed {} agreeing of {} endpoints, best agreement was {agreed_max} (distinct answers: {}){}",
            self.quorum,
            self.endpoints.len(),
            tally.len(),
            last_err
                .map(|e| format!("; last error: {e}"))
                .unwrap_or_default()
        )
    }

    /// BROADCAST: send to ALL endpoints, return the FIRST `Ok` (wider propagation
    /// + resilience). Per-endpoint errors are logged at debug (txhash matches /
    /// "already known" / nonce races are expected); only an all-fail returns `Err`.
    fn call_broadcast(&self, eps: &[Arc<dyn JsonRpc>], method: &str, params: &Value) -> anyhow::Result<Value> {
        let mut first_ok: Option<Value> = None;
        let mut last_err: Option<anyhow::Error> = None;
        for (i, ep) in eps.iter().enumerate() {
            match ep.call(method, params.clone()) {
                Ok(v) => {
                    if first_ok.is_none() {
                        first_ok = Some(v);
                    }
                }
                Err(e) => {
                    debug!(endpoint = i, %method, error = %e, "quorum: broadcast endpoint errored");
                    last_err = Some(e);
                }
            }
        }
        first_ok.ok_or_else(|| {
            last_err.unwrap_or_else(|| anyhow::anyhow!("broadcast: all endpoints failed for {method}"))
        })
    }

    /// FIRST-HEALTHY: try endpoints in order, return the first `Ok`; return the
    /// last `Err` only if ALL fail.
    fn call_first_healthy(&self, method: &str, params: &Value) -> anyhow::Result<Value> {
        let mut last_err: Option<anyhow::Error> = None;
        for (i, ep) in self.endpoints.iter().enumerate() {
            match ep.call(method, params.clone()) {
                Ok(v) => return Ok(v),
                Err(e) => {
                    debug!(endpoint = i, %method, error = %e, "quorum: first-healthy endpoint errored");
                    last_err = Some(e);
                }
            }
        }
        Err(last_err.unwrap_or_else(|| anyhow::anyhow!("first-healthy: no endpoints for {method}")))
    }
}

impl JsonRpc for QuorumJsonRpc {
    fn call(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        match classify(method, &params) {
            MethodClass::Agreement => self.call_agreement(method, &params),
            // Signed-tx broadcast → private relay(s) if configured (frontrunning
            // protection); else the public endpoints (legacy wide propagation).
            MethodClass::Broadcast => {
                let eps = if self.send_endpoints.is_empty() { &self.endpoints } else { &self.send_endpoints };
                self.call_broadcast(eps, method, &params)
            }
            MethodClass::FirstHealthy => self.call_first_healthy(method, &params),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_rpc_response_extracts_result_and_errors() {
        assert_eq!(
            parse_rpc_response(json!({ "result": "0x5" })).unwrap(),
            json!("0x5")
        );
        assert!(parse_rpc_response(json!({ "error": { "code": -32000, "message": "x" } })).is_err());
        assert!(parse_rpc_response(json!({})).is_err());
    }

    /// Live L1 smoke test — NETWORK, ignored by default. Run explicitly:
    ///   cargo test -p quid-bridge -- --ignored live_l1
    #[test]
    #[ignore]
    fn live_l1_chain_id_and_block_number() {
        let rpc = HttpJsonRpc::new("https://ethereum-rpc.publicnode.com");
        let chain = rpc.call("eth_chainId", json!([])).unwrap();
        assert_eq!(chain.as_str().unwrap(), "0x1", "mainnet chain id");
        let bn = rpc.call("eth_blockNumber", json!([])).unwrap();
        let n = u64::from_str_radix(bn.as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
        assert!(n > 21_000_000, "plausible mainnet height, got {n}");
    }

    // ───────────────────────────── quorum transport ──────────────────────────

    use std::sync::Mutex;

    /// A configurable mock: returns a fixed `Ok(value)` (per method or a default),
    /// or always errors. Records the methods it was called with.
    struct Mock {
        /// Per-method canned `Ok` values; falls back to `default` when absent.
        per_method: std::collections::HashMap<String, Value>,
        default: Value,
        fail: bool,
        calls: Mutex<Vec<String>>,
    }
    impl Mock {
        fn ok(default: Value) -> Self {
            Self {
                per_method: Default::default(),
                default,
                fail: false,
                calls: Mutex::new(vec![]),
            }
        }
        fn erroring() -> Self {
            Self {
                per_method: Default::default(),
                default: Value::Null,
                fail: true,
                calls: Mutex::new(vec![]),
            }
        }
        fn count(&self) -> usize {
            self.calls.lock().unwrap().len()
        }
    }
    impl JsonRpc for Mock {
        fn call(&self, method: &str, _p: Value) -> anyhow::Result<Value> {
            self.calls.lock().unwrap().push(method.to_string());
            if self.fail {
                anyhow::bail!("mock error");
            }
            Ok(self
                .per_method
                .get(method)
                .cloned()
                .unwrap_or_else(|| self.default.clone()))
        }
    }

    fn quorum(eps: Vec<Arc<dyn JsonRpc>>, q: usize) -> QuorumJsonRpc {
        QuorumJsonRpc::new(eps, q)
    }

    // ---- classify() ----

    #[test]
    fn classify_broadcast() {
        assert_eq!(
            classify("eth_sendRawTransaction", &json!(["0x02deadbeef"])),
            MethodClass::Broadcast
        );
    }

    #[test]
    fn classify_chainid_and_blockbyhash_always_agreement() {
        assert_eq!(classify("eth_chainId", &json!([])), MethodClass::Agreement);
        assert_eq!(
            classify("eth_getBlockByHash", &json!(["0xabc", true])),
            MethodClass::Agreement
        );
    }

    #[test]
    fn classify_eth_call_concrete_vs_dynamic_tag() {
        // Concrete hex block number → AGREEMENT.
        assert_eq!(
            classify("eth_call", &json!([{ "to": "0x00", "data": "0x" }, "0x10"])),
            MethodClass::Agreement
        );
        // Dynamic tags → FIRST-HEALTHY.
        for tag in ["latest", "pending", "earliest", "safe", "finalized"] {
            assert_eq!(
                classify("eth_call", &json!([{ "to": "0x00", "data": "0x" }, tag])),
                MethodClass::FirstHealthy,
                "tag {tag} should be first-healthy"
            );
        }
    }

    #[test]
    fn classify_block_by_number_concrete_vs_dynamic() {
        assert_eq!(
            classify("eth_getBlockByNumber", &json!(["0x1b4", false])),
            MethodClass::Agreement
        );
        assert_eq!(
            classify("eth_getBlockByNumber", &json!(["latest", false])),
            MethodClass::FirstHealthy
        );
    }

    #[test]
    fn classify_get_logs_needs_both_bounds_concrete() {
        // Both concrete → AGREEMENT.
        assert_eq!(
            classify("eth_getLogs", &json!([{ "fromBlock": "0x10", "toBlock": "0x20" }])),
            MethodClass::Agreement
        );
        // Either dynamic → FIRST-HEALTHY.
        assert_eq!(
            classify("eth_getLogs", &json!([{ "fromBlock": "0x10", "toBlock": "latest" }])),
            MethodClass::FirstHealthy
        );
        assert_eq!(
            classify("eth_getLogs", &json!([{ "fromBlock": "latest", "toBlock": "0x20" }])),
            MethodClass::FirstHealthy
        );
        // Missing a bound → FIRST-HEALTHY.
        assert_eq!(
            classify("eth_getLogs", &json!([{ "fromBlock": "0x10" }])),
            MethodClass::FirstHealthy
        );
    }

    #[test]
    fn classify_constant_reads_are_agreement() {
        // chainId, block-by-hash, and the boot-time getCode sanity check pin stable
        // values, so they're always cross-checked.
        for m in ["eth_chainId", "eth_getBlockByHash", "eth_getCode"] {
            assert_eq!(classify(m, &json!([])), MethodClass::Agreement, "{m}");
        }
    }

    #[test]
    fn classify_advisory_and_unknown_are_first_healthy() {
        for m in [
            "eth_blockNumber",
            "eth_getTransactionCount",
            "eth_getTransactionReceipt",
            "eth_estimateGas",
            "eth_gasPrice",
            "eth_maxPriorityFeePerGas",
            "eth_feeHistory",
            "some_unknown_method",
        ] {
            assert_eq!(
                classify(m, &json!([])),
                MethodClass::FirstHealthy,
                "{m} should be first-healthy"
            );
        }
    }

    // ---- AGREEMENT ----

    /// eth_chainId is always AGREEMENT — a clean lever to exercise the agreement
    /// path (no block-tag plumbing needed).
    #[test]
    fn agreement_three_agree() {
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x1"))),
            ],
            3,
        );
        assert_eq!(q.call("eth_chainId", json!([])).unwrap(), json!("0x1"));
    }

    #[test]
    fn agreement_two_agree_one_differs_quorum_two_ok() {
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x99"))),
            ],
            2,
        );
        assert_eq!(q.call("eth_chainId", json!([])).unwrap(), json!("0x1"));
    }

    #[test]
    fn agreement_quorum_three_with_one_differing_errs() {
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::ok(json!("0x99"))),
            ],
            3,
        );
        assert!(q.call("eth_chainId", json!([])).is_err());
    }

    #[test]
    fn agreement_all_but_one_erroring_quorum_two_errs() {
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0x1"))),
                Arc::new(Mock::erroring()),
                Arc::new(Mock::erroring()),
            ],
            2,
        );
        // Only one healthy endpoint, quorum 2 → cannot agree → Err (fail SAFE).
        assert!(q.call("eth_chainId", json!([])).is_err());
    }

    #[test]
    fn agreement_concrete_eth_call_agrees() {
        // Exercise the eth_call AGREEMENT branch end-to-end with a pinned block.
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0xdead"))),
                Arc::new(Mock::ok(json!("0xdead"))),
            ],
            2,
        );
        let got = q
            .call("eth_call", json!([{ "to": "0x0", "data": "0x" }, "0x10"]))
            .unwrap();
        assert_eq!(got, json!("0xdead"));
    }

    // ---- BROADCAST ----

    #[test]
    fn broadcast_first_ok_even_if_later_errors() {
        let q = quorum(
            vec![
                Arc::new(Mock::ok(json!("0xtxhash"))),
                Arc::new(Mock::erroring()),
            ],
            1,
        );
        assert_eq!(
            q.call("eth_sendRawTransaction", json!(["0x02"])).unwrap(),
            json!("0xtxhash")
        );
    }

    #[test]
    fn broadcast_hits_all_endpoints() {
        let a = Arc::new(Mock::ok(json!("0xh")));
        let b = Arc::new(Mock::ok(json!("0xh")));
        let q = quorum(vec![a.clone(), b.clone()], 1);
        q.call("eth_sendRawTransaction", json!(["0x02"])).unwrap();
        assert_eq!(a.count(), 1, "primary broadcast");
        assert_eq!(b.count(), 1, "secondary broadcast too (wider propagation)");
    }

    #[test]
    fn broadcast_all_error_is_err() {
        let q = quorum(
            vec![Arc::new(Mock::erroring()), Arc::new(Mock::erroring())],
            1,
        );
        assert!(q.call("eth_sendRawTransaction", json!(["0x02"])).is_err());
    }

    // ---- FIRST-HEALTHY ----

    #[test]
    fn first_healthy_primary_short_circuits() {
        let a = Arc::new(Mock::ok(json!("0x5")));
        let b = Arc::new(Mock::ok(json!("0x9")));
        let q = quorum(vec![a.clone(), b.clone()], 1);
        assert_eq!(q.call("eth_blockNumber", json!([])).unwrap(), json!("0x5"));
        assert_eq!(a.count(), 1, "primary used");
        assert_eq!(b.count(), 0, "secondary not touched when primary Ok");
    }

    #[test]
    fn first_healthy_falls_through_on_primary_error() {
        let a = Arc::new(Mock::erroring());
        let b = Arc::new(Mock::ok(json!("0x9")));
        let q = quorum(vec![a.clone(), b.clone()], 1);
        assert_eq!(q.call("eth_blockNumber", json!([])).unwrap(), json!("0x9"));
        assert_eq!(b.count(), 1, "secondary used after primary error");
    }

    #[test]
    fn first_healthy_all_error_is_err() {
        let q = quorum(
            vec![Arc::new(Mock::erroring()), Arc::new(Mock::erroring())],
            1,
        );
        assert!(q.call("eth_blockNumber", json!([])).is_err());
    }

    // ---- back-compat: single endpoint + quorum 1 == passthrough ----

    #[test]
    fn single_endpoint_quorum_one_passthrough_each_class() {
        // AGREEMENT (eth_chainId), FIRST-HEALTHY (eth_blockNumber), BROADCAST
        // (eth_sendRawTransaction) all behave like a bare single transport.
        let mut pm = std::collections::HashMap::new();
        pm.insert("eth_chainId".to_string(), json!("0x1"));
        pm.insert("eth_blockNumber".to_string(), json!("0x2a"));
        pm.insert("eth_sendRawTransaction".to_string(), json!("0xhash"));
        let inner = Arc::new(Mock {
            per_method: pm,
            default: Value::Null,
            fail: false,
            calls: Mutex::new(vec![]),
        });
        let q = quorum(vec![inner.clone()], 1);
        assert_eq!(q.call("eth_chainId", json!([])).unwrap(), json!("0x1"));
        assert_eq!(q.call("eth_blockNumber", json!([])).unwrap(), json!("0x2a"));
        assert_eq!(
            q.call("eth_sendRawTransaction", json!(["0x02"])).unwrap(),
            json!("0xhash")
        );
        // A single erroring endpoint propagates the error for every class.
        let qe = quorum(vec![Arc::new(Mock::erroring())], 1);
        assert!(qe.call("eth_chainId", json!([])).is_err());
        assert!(qe.call("eth_blockNumber", json!([])).is_err());
        assert!(qe.call("eth_sendRawTransaction", json!(["0x02"])).is_err());
    }
}
