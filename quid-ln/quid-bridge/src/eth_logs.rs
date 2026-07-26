//! Shared `eth_getLogs` plumbing for the EVM log-watching loops (on-chain swap-out
//! watcher). Pure JSON-RPC helpers with no swap-specific logic.

use serde_json::{json, Value};

// Shared hex parsers (crate-wide `hexutil`), aliased to this module's local names.
use crate::hexutil::{hex_b32 as parse_b32, hex_bytes as parse_hex_bytes, hex_u64 as parse_hex_u64};
use crate::transport::JsonRpc;

/// Extract (topics, data, blockNumber) from an `eth_getLogs` JSON log — the shared
/// preamble of the same-shaped event parsers. `None` on any malformed field.
/// (The lp-fee parser reads topics selectively + has no block, so it's not routed here.)
pub fn log_fields(log: &Value) -> Option<(Vec<[u8; 32]>, Vec<u8>, u64)> {
    let topics_json = log.get("topics")?.as_array()?;
    let mut topics = Vec::with_capacity(topics_json.len());
    for t in topics_json {
        topics.push(parse_b32(t.as_str()?)?);
    }
    let data = parse_hex_bytes(log.get("data")?.as_str()?)?;
    let block = parse_hex_u64(log.get("blockNumber")?.as_str()?)?;
    Some((topics, data, block))
}

/// `eth_getLogs` over `[from, to]` for `address`/`topic0`, ISSUED IN CHUNKS of at
/// most `span` blocks. A single query over a huge `[cursor, tip]` gap (after
/// downtime) is commonly rejected by providers for exceeding range/log caps; this
/// covers the full window with multiple bounded queries instead of stalling
/// forever on a rejected mega-query (L-4). `span == 0` is treated as "one block".
pub fn get_logs_chunked<R: JsonRpc>(
    rpc: &R,
    address: &str,
    topic0: &str,
    from: u64,
    to: u64,
    span: u64,
) -> anyhow::Result<Vec<Value>> {
    let step = span.max(1);
    let mut out = Vec::new();
    let mut start = from;
    while start <= to {
        let end = start.saturating_add(step - 1).min(to);
        let logs = rpc.call(
            "eth_getLogs",
            json!([{
                "fromBlock": format!("0x{start:x}"),
                "toBlock": format!("0x{end:x}"),
                "address": address,
                "topics": [topic0],
            }]),
        )?;
        if let Some(a) = logs.as_array() {
            out.extend(a.iter().cloned());
        }
        if end == to {
            break; // avoid overflow when to == u64::MAX
        }
        start = end + 1;
    }
    Ok(out)
}

/// Read the current EVM head (`eth_blockNumber`).
pub fn eth_tip<R: JsonRpc>(rpc: &R) -> anyhow::Result<u64> {
    parse_hex_u64(
        rpc.call("eth_blockNumber", json!([]))?
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("eth_blockNumber: no result"))?,
    )
    .ok_or_else(|| anyhow::anyhow!("eth_blockNumber: bad hex"))
}
