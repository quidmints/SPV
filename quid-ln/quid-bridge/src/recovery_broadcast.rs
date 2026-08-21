//! (#114) DEAD-MAN EXIT — the STATELESS, KEYLESS recovery broadcaster.
//!
//! This closes the "LP holds no independent copy" gap: the fully-signed exit tx
//! lives forever in the on-chain `DeadManExitEmitted` event, so recovery needs NO
//! key, NO signing, NO stored file — just reading already-public bytes and POSTing
//! them to a public Bitcoin mempool once the CLTV has matured.
//!
//! Given only a `channelId` + a public EVM RPC URL + the BTCChannels address + a
//! public Esplora base URL, [`recover_and_broadcast`]:
//! 1. `eth_getLogs` the LATEST `DeadManExitEmitted(channelId, …)` emission,
//! 2. decodes `cltvDeadline` + `signedExitTx` from the log data,
//! 3. compares `cltvDeadline` to the current Bitcoin tip height, and
//! 4. if matured (tip ≥ deadline, i.e. the fleet stopped refreshing), POSTs the raw
//!    tx to `{esplora}/tx`.
//!
//! Anyone — a watchtower, a keeper, the LP via a one-page web app, or the daemon
//! itself — can run this. It is deliberately dependency-light (`ureq` + `serde_json`
//! + `alloy_primitives`), NOT wired to the quorum transport or any signer, so it can
//! ship as a tiny standalone bin (`bin/quid-recover-exit.rs`) or a keeper call.
//!
//! SECURITY: read-only + a public broadcast POST. It CANNOT redirect funds — the
//! payout is pinned to the LP's `btcRecipientOf` INSIDE the signed bytes; publishing
//! them early (before maturity) just wastes a broadcast (the mempool rejects a
//! non-final tx). There is nothing sensitive to leak.

use anyhow::{anyhow, Context, Result};
use alloy_primitives::{hex, keccak256};
use serde_json::{json, Value};

/// The `DeadManExitEmitted(bytes32,address,uint64,uint256,bytes)` event signature —
/// `topic0` is `keccak256` of this. `channelId` + `lpEth` are indexed (topics 1..2);
/// `cltvDeadline`, `checkpointSats`, `signedExitTx` are the non-indexed data.
pub const EVENT_SIGNATURE: &str = "DeadManExitEmitted(bytes32,address,uint64,uint256,bytes)";

/// `keccak256(EVENT_SIGNATURE)` — the `eth_getLogs` `topic0` filter.
pub fn event_topic0() -> [u8; 32] {
    keccak256(EVENT_SIGNATURE.as_bytes()).0
}

/// A decoded dead-man exit emission (the latest for a channel).
#[derive(Debug, Clone)]
pub struct RecoveredExit {
    /// Absolute Bitcoin block-height CLTV the tx's `nLockTime` enforces.
    pub cltv_deadline: u64,
    /// The LP checkpoint balance the tx pays to `btcRecipientOf`.
    pub checkpoint_sats: u128,
    /// The fully-signed raw exit tx (consensus bytes) — broadcast verbatim.
    pub signed_exit_tx: Vec<u8>,
    /// The EVM block the emission landed in (diagnostic).
    pub block: u64,
}

/// The result of a recovery attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoverOutcome {
    /// No `DeadManExitEmitted` has ever been emitted for this channel.
    NoExit,
    /// An exit exists but its CLTV has NOT matured (the fleet is still alive) —
    /// carries `(tip_height, cltv_deadline)`. Not broadcast (would be rejected).
    NotMatured(u32, u64),
    /// Broadcast succeeded; carries the mempool-returned txid.
    Broadcast(String),
}

// ─── ABI / hex decoding of the log data ─────────────────────────────────────

fn strip0x(s: &str) -> &str {
    s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s)
}

/// Read the low 8 bytes of a 32-byte big-endian ABI word as `u64`.
fn word_u64(word: &[u8]) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&word[24..32]);
    u64::from_be_bytes(b)
}

/// Read the low 16 bytes of a 32-byte big-endian ABI word as `u128`.
fn word_u128(word: &[u8]) -> u128 {
    let mut b = [0u8; 16];
    b.copy_from_slice(&word[16..32]);
    u128::from_be_bytes(b)
}

/// Decode the non-indexed `DeadManExitEmitted` data:
/// `abi.encode(uint64 cltvDeadline, uint256 checkpointSats, bytes signedExitTx)`.
fn decode_event_data(data: &[u8], block: u64) -> Result<RecoveredExit> {
    if data.len() < 96 {
        return Err(anyhow!("event data too short ({} bytes)", data.len()));
    }
    let cltv_deadline = word_u64(&data[0..32]);
    let checkpoint_sats = word_u128(&data[32..64]);
    let offset = word_u64(&data[64..96]) as usize;
    let len_at = offset
        .checked_add(32)
        .filter(|end| *end <= data.len())
        .ok_or_else(|| anyhow!("bytes offset out of range"))?;
    let len = word_u64(&data[offset..len_at]) as usize;
    let end = len_at
        .checked_add(len)
        .filter(|e| *e <= data.len())
        .ok_or_else(|| anyhow!("bytes length out of range"))?;
    let signed_exit_tx = data[len_at..end].to_vec();
    Ok(RecoveredExit { cltv_deadline, checkpoint_sats, signed_exit_tx, block })
}

// ─── EVM read (keyless) ──────────────────────────────────────────────────────

fn rpc_call(rpc_url: &str, method: &str, params: Value) -> Result<Value> {
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    let resp: Value = ureq::post(rpc_url)
        .send_json(body)
        .with_context(|| format!("{method} request"))?
        .into_json()
        .with_context(|| format!("{method} decode"))?;
    if let Some(err) = resp.get("error") {
        return Err(anyhow!("{method} rpc error: {err}"));
    }
    resp.get("result").cloned().ok_or_else(|| anyhow!("{method}: no result"))
}

/// Fetch the LATEST `DeadManExitEmitted` emission for `channel_id`, or `None` if there
/// has never been one. Reads the full log range (`0x0`..`latest`) filtered by the
/// event `topic0` + the indexed `channelId`; the last log is the freshest heartbeat.
pub fn latest_exit(
    rpc_url: &str,
    btc_channels: &str,
    channel_id: [u8; 32],
) -> Result<Option<RecoveredExit>> {
    let topic0 = format!("0x{}", hex::encode(event_topic0()));
    let topic1 = format!("0x{}", hex::encode(channel_id));
    let filter = json!({
        "address": btc_channels,
        "fromBlock": "0x0",
        "toBlock": "latest",
        "topics": [topic0, topic1],
    });
    let logs = rpc_call(rpc_url, "eth_getLogs", json!([filter]))?;
    let arr = logs.as_array().ok_or_else(|| anyhow!("eth_getLogs: not an array"))?;
    let last = match arr.last() {
        Some(l) => l,
        None => return Ok(None),
    };
    let data_hex = last.get("data").and_then(|d| d.as_str()).ok_or_else(|| anyhow!("log: no data"))?;
    let data = hex::decode(strip0x(data_hex)).context("log data hex")?;
    let block = last
        .get("blockNumber")
        .and_then(|b| b.as_str())
        .and_then(|s| u64::from_str_radix(strip0x(s), 16).ok())
        .unwrap_or(0);
    Ok(Some(decode_event_data(&data, block)?))
}

// ─── Bitcoin (keyless) ───────────────────────────────────────────────────────

/// Current Bitcoin tip height from a public Esplora (`GET {esplora}/blocks/tip/height`).
pub fn bitcoin_tip_height(esplora_url: &str) -> Result<u32> {
    let url = format!("{}/blocks/tip/height", esplora_url.trim_end_matches('/'));
    let text = ureq::get(&url).call().context("esplora tip height")?.into_string()?;
    text.trim().parse::<u32>().context("parse tip height")
}

/// Broadcast a raw tx via a public Esplora (`POST {esplora}/tx`, hex body → txid).
pub fn broadcast_raw_tx(esplora_url: &str, raw_tx: &[u8]) -> Result<String> {
    let url = format!("{}/tx", esplora_url.trim_end_matches('/'));
    let txid = ureq::post(&url)
        .send_string(&hex::encode(raw_tx))
        .context("esplora broadcast")?
        .into_string()?;
    Ok(txid.trim().to_string())
}

/// The full recovery flow: read the latest exit, and if its CLTV has matured (or
/// `force`), broadcast it. KEYLESS — only public reads + a public broadcast POST.
///
/// `force` bypasses the maturity check (for keeper testing / a keeper that already
/// verified maturity out of range); a non-final tx will simply be rejected by the
/// mempool, so `force` cannot cause harm.
pub fn recover_and_broadcast(
    rpc_url: &str,
    btc_channels: &str,
    channel_id: [u8; 32],
    esplora_url: &str,
    force: bool,
) -> Result<RecoverOutcome> {
    let exit = match latest_exit(rpc_url, btc_channels, channel_id)? {
        Some(e) => e,
        None => return Ok(RecoverOutcome::NoExit),
    };
    let tip = bitcoin_tip_height(esplora_url)?;
    // Broadcastable when the tip has reached the deadline (the tx becomes includable
    // in block tip+1, where nLockTime < tip+1 ⇔ cltv_deadline ≤ tip).
    if !force && (tip as u64) < exit.cltv_deadline {
        return Ok(RecoverOutcome::NotMatured(tip, exit.cltv_deadline));
    }
    let txid = broadcast_raw_tx(esplora_url, &exit.signed_exit_tx)?;
    Ok(RecoverOutcome::Broadcast(txid))
}

// ─── W.0 watchtower: discover-all + one poll pass (keyless, hostable) ────────

/// Extract the indexed `channelId` (topic1) from a `DeadManExitEmitted` log.
fn channel_id_from_log(log: &Value) -> Option<[u8; 32]> {
    let t1 = log.get("topics")?.as_array()?.get(1)?.as_str()?;
    let bytes = hex::decode(strip0x(t1)).ok()?;
    if bytes.len() != 32 {
        return None;
    }
    let mut id = [0u8; 32];
    id.copy_from_slice(&bytes);
    Some(id)
}

/// Discover EVERY channel that has ever emitted a `DeadManExitEmitted`, so a watchtower
/// watches them ALL with no pre-known list. `eth_getLogs` by `topic0` only, then collect
/// the DISTINCT indexed `channelId` (topic1). Sorted/deduped (BTreeSet) for determinism.
pub fn all_channels_with_exits(rpc_url: &str, btc_channels: &str) -> Result<Vec<[u8; 32]>> {
    let topic0 = format!("0x{}", hex::encode(event_topic0()));
    let filter = json!({
        "address": btc_channels,
        "fromBlock": "0x0",
        "toBlock": "latest",
        "topics": [topic0],
    });
    let logs = rpc_call(rpc_url, "eth_getLogs", json!([filter]))?;
    let arr = logs.as_array().ok_or_else(|| anyhow!("eth_getLogs: not an array"))?;
    let mut seen = std::collections::BTreeSet::new();
    for log in arr {
        if let Some(id) = channel_id_from_log(log) {
            seen.insert(id);
        }
    }
    Ok(seen.into_iter().collect())
}

/// One watchtower pass: discover every channel with an exit and attempt keyless recovery
/// on each (broadcasts matured exits, leaves still-live ones). A per-channel RPC/Esplora
/// error is captured, not propagated, so one bad channel never aborts the others — a
/// watchtower must keep protecting the rest. Returns per-channel outcomes for logging.
pub fn watchtower_tick(
    rpc_url: &str,
    btc_channels: &str,
    esplora_url: &str,
) -> Result<Vec<([u8; 32], std::result::Result<RecoverOutcome, String>)>> {
    let channels = all_channels_with_exits(rpc_url, btc_channels)?;
    let mut out = Vec::with_capacity(channels.len());
    for ch in channels {
        let r = recover_and_broadcast(rpc_url, btc_channels, ch, esplora_url, false)
            .map_err(|e| format!("{e:#}"));
        out.push((ch, r));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_id_extracted_from_topics() {
        let id = "0x11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff";
        let log = json!({ "topics": [ "0xdead", id, "0xbeef" ] });
        let got = channel_id_from_log(&log).unwrap();
        assert_eq!(&format!("0x{}", hex::encode(got)), id);
        // A log with no topic1 (malformed) yields None, not a panic.
        assert!(channel_id_from_log(&json!({ "topics": ["0xdead"] })).is_none());
    }

    #[test]
    fn topic0_matches_signature() {
        // Sanity: topic0 is deterministic keccak of the exact event signature.
        assert_eq!(event_topic0(), keccak256(EVENT_SIGNATURE.as_bytes()).0);
    }

    /// Decode ABI data produced the same way the contract emits it:
    /// abi.encode(uint64 cltvDeadline, uint256 checkpointSats, bytes signedExitTx).
    #[test]
    fn decode_roundtrips_encoded_data() {
        let cltv: u64 = 800_144;
        let checkpoint: u128 = 123_456;
        let tx = vec![0xDEu8, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]; // 7 bytes (odd → padded)

        // Build the ABI tail exactly as Solidity/`encode_tuple` would.
        let mut data = Vec::new();
        let mut w = [0u8; 32];
        w[24..32].copy_from_slice(&cltv.to_be_bytes());
        data.extend_from_slice(&w); // word0 cltvDeadline
        let mut w2 = [0u8; 32];
        w2[16..32].copy_from_slice(&checkpoint.to_be_bytes());
        data.extend_from_slice(&w2); // word1 checkpointSats
        let mut w3 = [0u8; 32];
        w3[24..32].copy_from_slice(&96u64.to_be_bytes());
        data.extend_from_slice(&w3); // word2 offset = 0x60
        let mut wl = [0u8; 32];
        wl[24..32].copy_from_slice(&(tx.len() as u64).to_be_bytes());
        data.extend_from_slice(&wl); // length
        data.extend_from_slice(&tx);
        data.extend(std::iter::repeat(0u8).take((32 - tx.len() % 32) % 32)); // pad

        let got = decode_event_data(&data, 42).unwrap();
        assert_eq!(got.cltv_deadline, cltv);
        assert_eq!(got.checkpoint_sats, checkpoint);
        assert_eq!(got.signed_exit_tx, tx);
        assert_eq!(got.block, 42);
    }

    #[test]
    fn short_data_rejected() {
        assert!(decode_event_data(&[0u8; 64], 0).is_err());
    }
}
