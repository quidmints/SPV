//! SPV header relayer: keeps the EVM `SPVGateway` current by submitting Bitcoin
//! block headers. Reads the gateway head height (`getMainchainHeight`), fetches
//! the missing headers from a Bitcoin source, and submits them via
//! `addBlockHeaderBatch(bytes[])`. The gateway validates PoW/difficulty/chain
//! work itself, so this is permissionless plumbing — anyone can relay; the hop
//! does it so closes can always be SPV-proven.

use std::sync::Arc;
use std::time::Duration;

use alloy_primitives::{hex, keccak256, Address};
use serde_json::json;
use tracing::{info, warn};

use crate::abi::{u64_word, word_to_uint};
use crate::client::JsonRpcEvmClient;
use crate::config::BridgeConfig;
use crate::store::BridgeStore;
use crate::transport::JsonRpc;

/// A Bitcoin block-header source (e.g. an Esplora/Bitcoin-RPC client).
pub trait BtcHeaderSource: Send + Sync + 'static {
    fn tip_height(&self) -> anyhow::Result<u64>;
    /// The raw 80-byte header at `height` (must be on the source's best chain).
    fn header_at(&self, height: u64) -> anyhow::Result<[u8; 80]>;
    /// The block hash at `height` in BIG-ENDIAN/display order — the key the
    /// `SPVGateway` indexes blocks by (`parseBlockHeader(true)`). Used by reorg
    /// recovery to find the fork point against the gateway's `blockExists`. The
    /// source computes it from its own `BlockHash` (it already holds the audited
    /// `bitcoin` hashing); the bridge does no Bitcoin hashing itself.
    fn block_hash_be(&self, height: u64) -> anyhow::Result<[u8; 32]>;
}

/// The inclusive height range to relay this round, or `None` if the gateway is
/// already at (or ahead of) the Bitcoin tip. Capped at `batch_max`.
pub fn relay_range(gateway_height: u64, btc_tip: u64, batch_max: u64) -> Option<(u64, u64)> {
    if btc_tip <= gateway_height {
        return None;
    }
    let from = gateway_height + 1;
    let to = (from + batch_max - 1).min(btc_tip);
    Some((from, to))
}

/// ABI-encode `addBlockHeaderBatch(bytes[])` for a slice of 80-byte headers.
/// Verified byte-exact against `cast` in the tests.
pub fn encode_add_header_batch(headers: &[[u8; 80]]) -> Vec<u8> {
    let n = headers.len() as u64;
    let mut out = Vec::new();
    out.extend_from_slice(&keccak256("addBlockHeaderBatch(bytes[])")[..4]);
    out.extend_from_slice(&u64_word(0x20)); // offset to the array
    out.extend_from_slice(&u64_word(n)); // array length
    // Element offsets, relative to the start of the array data (after the length
    // word). Each element is a length word + 80 bytes padded to 96 (3 words).
    let mut off = n * 32;
    for _ in 0..n {
        out.extend_from_slice(&u64_word(off));
        off += 32 + 96;
    }
    for h in headers {
        out.extend_from_slice(&u64_word(80)); // bytes length
        out.extend_from_slice(h); // 80 bytes
        out.extend_from_slice(&[0u8; 16]); // pad to 96
    }
    out
}

/// Read `SPVGateway.blockExists(bytes32)` via `eth_call` (BE block hash).
pub fn read_gateway_block_exists<R: JsonRpc>(
    rpc: &R,
    gateway: Address,
    block_hash_be: [u8; 32],
) -> anyhow::Result<bool> {
    crate::client::eth_call_bool(rpc, gateway, "blockExists(bytes32)", Some(&block_hash_be))
}

/// Find the highest height in `[floor, gateway_height]` whose source block hash
/// the gateway still knows — the fork point. Reorg recovery resubmits the source
/// branch from `fork + 1`. Pure (closures for the two IO ops) so it's unit-
/// testable. `None` ⇒ the divergence is deeper than the lookback floor.
///
/// BINARY search over a MONOTONE predicate: at a reorg the gateway is on the
/// stale branch, so it knows `source_hash(h)` for every `h <= fork` (shared
/// pre-fork history) and none above it — a clean `true…true,false…false` split.
/// The fork point is the largest `h` with `gateway_knows == true`, found in
/// `O(log n)` IO probes instead of the old linear `O(n)` walk (the reorg lookback
/// is ~144 → ~8 probes vs ~144). Identical result to the linear scan under that
/// monotonicity; were it ever violated (it isn't in this protocol) a mislocated
/// fork only over-/under-resubmits headers, which the gateway dedups/rejects —
/// it never corrupts state.
pub fn find_fork_point(
    floor: u64,
    gateway_height: u64,
    source_hash: impl Fn(u64) -> anyhow::Result<[u8; 32]>,
    gateway_knows: impl Fn([u8; 32]) -> anyhow::Result<bool>,
) -> anyhow::Result<Option<u64>> {
    let mut lo = floor;
    let mut hi = gateway_height;
    let mut found = None;
    while lo <= hi {
        let mid = lo + (hi - lo) / 2;
        if gateway_knows(source_hash(mid)?)? {
            found = Some(mid); // known here; the boundary is at or above mid
            lo = mid + 1;
        } else if mid == 0 {
            break; // can't probe lower; avoid u64 underflow
        } else {
            hi = mid - 1;
        }
    }
    Ok(found)
}

// HOP-OPERATOR READ DELETED 2026-08-15 (owner: remove dead code; standing rule 1).
// `read_hop_node` had NO production caller -- every use was a test asserting the decode of the
// function's own output. It survived a rename I made hours earlier (`hopNode()` ->
// `MAIN_HOP()`), which fixed the string in a routine nothing invoked.
//
// ⚠️ WHAT GOES WITH IT, STATED SO IT IS A DECISION AND NOT AN ACCIDENT: the docblock claimed
// "the daemon checks this against its hot-key address so a key rotated out on-chain can't keep
// signing settles that all revert (I-3)". THE DAEMON NEVER DID. That check was written, tested
// against a mock, and never wired to the signing path, so I-3 was documented rather than
// enforced -- a green test suite over a guard that could not fire, which is worse than an
// absent guard because it reads as present.
// If I-3 is wanted, it is `who == MAIN_HOP() || who == FALLBACK_HOP()` (mirroring
// `BTCChannels._onlyHop()`, :664-665) evaluated ON THE SIGNING PATH. Membership, not equality:
// the pair exists so a dead main can be taken over by the fallback (:631), and an equality
// check would refuse to sign in exactly that takeover.

/// Read `SPVGateway.getMainchainHeight()` via `eth_call`.
pub fn read_gateway_height<R: JsonRpc>(rpc: &R, gateway: Address) -> anyhow::Result<u64> {
    let bytes = crate::client::eth_call_raw(rpc, gateway, "getMainchainHeight()", None)?;
    if bytes.len() < 32 {
        anyhow::bail!("getMainchainHeight: short return");
    }
    // Do NOT silently clamp an out-of-range height to 0: that would make the
    // relayer believe the gateway is at genesis and re-submit EVERY header from
    // block 0 (a gas-DoS). A real gateway height never exceeds u64, so a value
    // that does is an adversarial/garbage RPC response — surface it as an error.
    word_to_uint(&bytes, "getMainchainHeight: value exceeds u64")
}

/// Run the relayer loop: each round, top the gateway up toward the Bitcoin tip
/// (one capped batch per round).
/// H-4: should the relayer yield this round? True once in-flight swap settlements
/// reach the configured tier (0 disables). Pure so it's unit-testable without the
/// loop / a live store.
pub fn relayer_should_defer(cfg: &BridgeConfig, inflight: usize) -> bool {
    cfg.relayer_defer_inflight > 0 && inflight >= cfg.relayer_defer_inflight
}

pub async fn run_spv_relayer<R, S>(
    cfg: BridgeConfig,
    rpc: Arc<R>,
    headers: Arc<S>,
    evm: Arc<JsonRpcEvmClient<R, crate::signer::LocalSigner>>,
    store: Arc<BridgeStore>,
) where
    R: JsonRpc,
    S: BtcHeaderSource,
{
    info!("spv relayer: started");
    loop {
        // H-4 relayer-defer: yield this round if swap settlement is busy, so the
        // shared hot-key nonce serves the time-critical settlers first. Header
        // relay tolerates the delay (Bitcoin blocks ~10 min); the per-swap HTLC
        // accept limit bounds in-flight swap-ins, so the relayer always resumes as
        // they drain.
        let inflight = store.inflight_swapin_count();
        if relayer_should_defer(&cfg, inflight) {
            warn!(inflight, threshold = cfg.relayer_defer_inflight,
                  "spv relayer: deferring round — swap settlement busy (H-4)");
        } else if let Err(e) = relay_once(&cfg, &rpc, &headers, &evm).await {
            warn!(error = %e, "spv relayer: round failed");
        }
        tokio::time::sleep(Duration::from_secs(cfg.relay_poll_secs)).await;
    }
}

async fn relay_once<R, S>(
    cfg: &BridgeConfig,
    rpc: &Arc<R>,
    headers: &Arc<S>,
    evm: &Arc<JsonRpcEvmClient<R, crate::signer::LocalSigner>>,
) -> anyhow::Result<()>
where
    R: JsonRpc,
    S: BtcHeaderSource,
{
    let rpc2 = rpc.clone();
    let gateway = cfg.spv_gateway;
    let gh = tokio::task::spawn_blocking(move || read_gateway_height(&*rpc2, gateway)).await??;

    let src = headers.clone();
    let tip = tokio::task::spawn_blocking(move || src.tip_height()).await??;

    let Some((from, to)) = relay_range(gh, tip, cfg.relay_batch_max) else {
        // CAUGHT UP by height — but a reorg to a tip whose height is <= the
        // gateway's leaves the gateway stuck on an orphaned branch with NO forward
        // relay to revert and trigger recovery (M-D). Detect it: compare the
        // SOURCE's block hash at the gateway's current height to what the gateway
        // knows. The source can only answer for heights <= its own tip; probe at
        // min(gh, tip). If the gateway does NOT recognize the source's hash there,
        // the two have diverged → run recovery. Bounded: one source read + one
        // eth_call, no loop.
        let probe = gh.min(tip);
        if probe > 0 {
            let src = headers.clone();
            let src_hash =
                tokio::task::spawn_blocking(move || src.block_hash_be(probe)).await??;
            let rpc2 = rpc.clone();
            let gateway2 = gateway;
            let gateway_knows = tokio::task::spawn_blocking(move || {
                read_gateway_block_exists(&*rpc2, gateway2, src_hash)
            })
            .await??;
            if !gateway_knows {
                warn!(
                    gateway_height = gh, tip, probe,
                    "caught up by height but gateway diverges from source at the head — \
                     reorg-to-lower-height; attempting recovery (M-D)"
                );
                return recover_reorg(cfg, rpc, headers, evm, gh, tip).await;
            }
        }
        return Ok(()); // genuinely caught up, on the same branch
    };

    let src = headers.clone();
    let batch = tokio::task::spawn_blocking(move || {
        (from..=to).map(|h| src.header_at(h)).collect::<anyhow::Result<Vec<_>>>()
    })
    .await??;

    // GAS-AWARE SIZING (see fit_batch) — out-of-gas can never happen. An estimate
    // that REVERTS (vs merely too-costly) means the batch doesn't extend the
    // gateway head → a Bitcoin reorg → recovery.
    let budget = relay_gas_budget(cfg);
    let bc = batch.clone();
    let rpc2 = rpc.clone();
    let n = match tokio::task::spawn_blocking(move || fit_batch(&*rpc2, gateway, &bc, budget)).await? {
        Ok(n) => n,
        Err(e) => {
            warn!(from, to, error = %e, "header batch estimate reverted; attempting reorg recovery");
            return recover_reorg(cfg, rpc, headers, evm, gh, tip).await;
        }
    };
    let to_n = from + n as u64 - 1;
    let data = encode_add_header_batch(&batch[..n]);
    let gas = cfg.relay_gas_limit;
    let evm2 = evm.clone();
    let ok = tokio::task::spawn_blocking(move || evm2.send_tx(gateway, data, gas)).await??;
    if ok {
        info!(from, to = to_n, "spv relayer: submitted header batch");
        return Ok(());
    }
    // Estimate passed but the send reverted (a reorg landed in between) → recovery.
    warn!(from, to = to_n, "header batch reverted post-estimate; reorg recovery");
    recover_reorg(cfg, rpc, headers, evm, gh, tip).await
}

/// 90% of `relay_gas_limit` — the gas budget a single header batch must fit.
fn relay_gas_budget(cfg: &BridgeConfig) -> u64 {
    (cfg.relay_gas_limit / 10) * 9
}

/// Largest prefix `n` of `batch` whose `addBlockHeaderBatch` fits `budget` gas
/// (via `eth_estimateGas`). Shrinks proportionally — gas has a fixed base cost,
/// so the scaled count undershoots and converges in ~1-2 steps — so out-of-gas
/// CANNOT happen for any `relay_batch_max`. `Ok(n)` ⇒ submit `batch[..n]`; `Err`
/// ⇒ the batch REVERTS (estimate errors), i.e. it doesn't extend the gateway head
/// (a reorg / `PrevBlockDoesNotExist`) — the caller recovers, not shrinks. (A
/// single header exceeding the budget is a misconfig, not a reorg, but is
/// unreachable with sane limits — one header is ~50-100k gas vs an ~8M budget.)
fn fit_batch<R: JsonRpc>(
    rpc: &R,
    gateway: Address,
    batch: &[[u8; 80]],
    budget: u64,
) -> anyhow::Result<usize> {
    let mut n = batch.len().max(1);
    loop {
        let data = encode_add_header_batch(&batch[..n]);
        let g = estimate_gas(rpc, gateway, &data)?; // Err on revert → propagate (reorg)
        if g <= budget {
            return Ok(n);
        }
        if n <= 1 {
            anyhow::bail!(
                "single header gas {g} exceeds budget {budget} (raise QUID_RELAY_GAS_LIMIT)"
            );
        }
        n = (((n as u128) * (budget as u128)) / (g as u128)).clamp(1, (n - 1) as u128) as usize;
    }
}

/// `eth_estimateGas` for a call. Returns the gas estimate, or `Err` if the call
/// REVERTS — letting the relayer tell a too-costly batch (large estimate → split)
/// apart from a reorg (estimate errors → recovery).
pub fn estimate_gas<R: JsonRpc>(rpc: &R, to: Address, data: &[u8]) -> anyhow::Result<u64> {
    let ret = rpc.call(
        "eth_estimateGas",
        json!([{ "to": to.to_string(), "data": format!("0x{}", hex::encode(data)) }]),
    )?;
    let s = ret
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("estimateGas: no result"))?;
    u64::from_str_radix(s.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow::anyhow!("estimateGas parse {s:?}: {e}"))
}

/// Reorg recovery: locate the fork point within `relay_reorg_lookback` and
/// resubmit the source's branch from `fork + 1`.
async fn recover_reorg<R, S>(
    cfg: &BridgeConfig,
    rpc: &Arc<R>,
    headers: &Arc<S>,
    evm: &Arc<JsonRpcEvmClient<R, crate::signer::LocalSigner>>,
    gateway_height: u64,
    tip: u64,
) -> anyhow::Result<()>
where
    R: JsonRpc,
    S: BtcHeaderSource,
{
    let gateway = cfg.spv_gateway;
    let floor = gateway_height.saturating_sub(cfg.relay_reorg_lookback);
    // Start the fork search at min(gateway_height, source_tip): in a real reorg the
    // source's best chain is often SHORTER than the gateway head (the gateway is
    // ahead on the now-orphaned branch), and the source cannot answer
    // `block_hash_be(h)` for h above its own tip. Probing `gateway_height` there
    // would error and abort recovery every round (H-B). The gateway's blocks
    // between `search_start` and `gateway_height` are on the orphaned branch we're
    // replacing anyway, so the deepest COMMON block is at height ≤ source_tip.
    let search_start = gateway_height.min(tip);
    let rpc_fork = rpc.clone();
    let src_fork = headers.clone();
    let fork = tokio::task::spawn_blocking(move || {
        find_fork_point(
            floor,
            search_start,
            |h| src_fork.block_hash_be(h),
            |bh| read_gateway_block_exists(&*rpc_fork, gateway, bh),
        )
    })
    .await??;

    let Some(fork) = fork else {
        warn!(
            floor, gateway_height,
            "spv relayer: reorg deeper than relay_reorg_lookback — MANUAL INTERVENTION needed"
        );
        return Ok(());
    };

    // Resubmit the divergent branch from fork+1 (all NEW to the gateway, since the
    // fork is the deepest common block). The gateway reorgs once it outweighs old.
    let from = fork + 1;
    let to = (from + cfg.relay_batch_max - 1).min(tip);
    let src = headers.clone();
    let batch = tokio::task::spawn_blocking(move || {
        (from..=to).map(|h| src.header_at(h)).collect::<anyhow::Result<Vec<_>>>()
    })
    .await??;

    // Gas-aware sizing here too (same OOG class as the forward path): the reorg
    // branch can be large, so fit it to the gas budget before submitting.
    let budget = relay_gas_budget(cfg);
    let bc = batch.clone();
    let rpc2 = rpc.clone();
    let n = match tokio::task::spawn_blocking(move || fit_batch(&*rpc2, gateway, &bc, budget)).await? {
        Ok(n) => n,
        Err(e) => {
            warn!(fork, from, to, error = %e, "reorg-recovery batch estimate reverted — will retry");
            return Ok(());
        }
    };
    let to_n = from + n as u64 - 1;
    let data = encode_add_header_batch(&batch[..n]);
    let gas = cfg.relay_gas_limit;
    let evm2 = evm.clone();
    let ok = tokio::task::spawn_blocking(move || evm2.send_tx(gateway, data, gas)).await??;
    if ok {
        info!(fork, from, to = to_n, "spv relayer: reorg branch submitted from fork point");
    } else {
        warn!(fork, from, to = to_n, "spv relayer: reorg-recovery batch reverted — will retry");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_range_caps_and_stops() {
        assert_eq!(relay_range(100, 100, 50), None); // caught up
        assert_eq!(relay_range(100, 99, 50), None); // gateway ahead
        assert_eq!(relay_range(100, 120, 50), Some((101, 120))); // full gap
        assert_eq!(relay_range(100, 200, 50), Some((101, 150))); // capped to 50
    }

    #[test]
    fn relayer_defers_at_tier_not_below() {
        let mut cfg = sim_cfg();
        cfg.relayer_defer_inflight = 20;
        assert!(!relayer_should_defer(&cfg, 0));  // idle → relay
        assert!(!relayer_should_defer(&cfg, 19)); // below tier → relay
        assert!(relayer_should_defer(&cfg, 20));  // at tier → defer to settlers
        assert!(relayer_should_defer(&cfg, 35));  // busy → defer
        cfg.relayer_defer_inflight = 0;           // 0 disables the defer
        assert!(!relayer_should_defer(&cfg, 10_000));
    }

    #[test]
    fn encode_add_header_batch_matches_cast_vector() {
        // cast calldata "addBlockHeaderBatch(bytes[])" "[0x11*80, 0x22*80]"
        let expected = "0xebbe0b6500000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000501111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000050222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222200000000000000000000000000000000";
        let headers = [[0x11u8; 80], [0x22u8; 80]];
        let got = format!("0x{}", hex::encode(encode_add_header_batch(&headers)));
        assert_eq!(got, expected, "must match cast byte-for-byte");
    }

    #[test]
    fn get_mainchain_height_selector() {
        assert_eq!(
            format!("0x{}", hex::encode(&keccak256("getMainchainHeight()")[..4])),
            "0x3f377a6c" // from `cast sig`
        );
    }

    // Model a reorg: the gateway knows the OLD chain's hashes up to `gh`; the
    // source's NEW chain diverges above `fork_at`. find_fork_point must return
    // the deepest height the gateway still recognizes on the source chain.
    fn hash_for(height: u64, chain: u8) -> [u8; 32] {
        let mut h = [0u8; 32];
        h[0] = chain;
        h[24..].copy_from_slice(&height.to_be_bytes());
        h
    }

    #[test]
    fn fork_point_found_within_lookback() {
        let gh = 100;
        let fork_at = 96; // source diverges after height 96
        // gateway knows OLD-chain (chain=0) hashes for all heights ≤ gh.
        let gateway_knows = |bh: [u8; 32]| Ok(bh[0] == 0 && u64::from_be_bytes(bh[24..].try_into().unwrap()) <= gh);
        // source returns NEW-chain (chain=1) hashes above fork_at, OLD below.
        let source_hash = |h: u64| Ok(if h > fork_at { hash_for(h, 1) } else { hash_for(h, 0) });
        let fork = find_fork_point(gh - 10, gh, source_hash, gateway_knows).unwrap();
        assert_eq!(fork, Some(fork_at), "deepest common block is the fork point");
    }

    #[test]
    fn fork_deeper_than_lookback_is_none() {
        let gh = 100;
        // Source diverges everywhere in the window (all new-chain hashes).
        let source_hash = |h: u64| Ok(hash_for(h, 1));
        let gateway_knows = |bh: [u8; 32]| Ok(bh[0] == 0); // only old-chain known
        let fork = find_fork_point(gh - 5, gh, source_hash, gateway_knows).unwrap();
        assert_eq!(fork, None, "divergence below the lookback floor → no recovery");
    }

    #[test]
    fn fork_search_never_probes_above_source_tip() {
        // H-B: in a real reorg the source tip (95) is BELOW the gateway head (100).
        // recover_reorg clamps the search start to min(gh, tip)=95; the source
        // ERRORS if asked for any height above its tip. With the clamp, the search
        // never probes >95 and still finds the fork.
        let gateway_height = 100u64;
        let source_tip = 95u64;
        let fork_at = 92u64;
        let source_hash = |h: u64| -> anyhow::Result<[u8; 32]> {
            if h > source_tip {
                anyhow::bail!("source has no block at height {h} (tip {source_tip})");
            }
            Ok(hash_for(h, if h > fork_at { 1 } else { 0 }))
        };
        let gateway_knows = |bh: [u8; 32]| Ok(bh[0] == 0); // gateway knows old-chain
        // The clamp recover_reorg applies:
        let search_start = gateway_height.min(source_tip);
        let floor = gateway_height.saturating_sub(144);
        let fork = find_fork_point(floor, search_start, source_hash, gateway_knows).unwrap();
        assert_eq!(fork, Some(fork_at), "found the fork without probing above the source tip");
    }

    // ───────────────────────── gas-sizing stress ─────────────────────────────
    // The OOG bug was a fixed batch overrunning the gas limit. These hammer
    // fit_batch across adversarial (per-header-gas × batch-size) combos to prove
    // the invariant that broke before can't recur: a submitted batch NEVER
    // exceeds the budget, sizing always terminates, and a revert is distinguished
    // from a too-costly batch.

    /// estimateGas = `base + count*per_header`, with `count` decoded from the
    /// addBlockHeaderBatch calldata's `bytes[]` length word. `revert` simulates a
    /// reorg (estimateGas errors).
    struct GasSim {
        base: u64,
        per_header: u64,
        revert: bool,
    }
    impl crate::transport::JsonRpc for GasSim {
        fn call(&self, method: &str, params: serde_json::Value) -> anyhow::Result<serde_json::Value> {
            assert_eq!(method, "eth_estimateGas");
            if self.revert {
                anyhow::bail!("execution reverted: PrevBlockDoesNotExist");
            }
            let data = params[0]["data"].as_str().unwrap();
            let bytes = hex::decode(data.trim_start_matches("0x")).unwrap();
            // selector[4] ‖ offset-word[32] ‖ length-word[32]; count = low 8 bytes
            // of the length word (offset 60..68).
            let count = u64::from_be_bytes(bytes[60..68].try_into().unwrap());
            Ok(serde_json::Value::String(format!(
                "0x{:x}",
                self.base + count * self.per_header
            )))
        }
    }

    #[test]
    fn fit_batch_never_oogs_and_terminates() {
        const BASE: u64 = 50_000;
        let budget = 7_200_000u64;
        for per_header in [21_000u64, 50_000, 100_000, 250_000, 1_000_000, 3_600_000, 8_000_000] {
            for batch_len in [1usize, 3, 17, 50, 100, 999, 4096] {
                let sim = GasSim { base: BASE, per_header, revert: false };
                let batch = vec![[0x11u8; 80]; batch_len];
                match fit_batch(&sim, Address::ZERO, &batch, budget) {
                    Ok(n) => {
                        assert!(n >= 1 && n <= batch_len, "n={n} out of range");
                        // INVARIANT: the chosen batch fits — out-of-gas impossible.
                        let g = BASE + n as u64 * per_header;
                        assert!(g <= budget, "OOG: n={n} per={per_header} g={g} > {budget}");
                        // Efficiency: the proportional shrink lands at the optimum
                        // (largest fitting count), allowing ≤1 header of slack.
                        let opt = ((budget - BASE) / per_header).min(batch_len as u64) as usize;
                        assert!(n + 1 >= opt, "underfilled: n={n} opt={opt} per={per_header}");
                    }
                    Err(_) => {
                        // Only legitimate when a SINGLE header can't fit the budget.
                        assert!(BASE + per_header > budget, "errored but 1 header fits");
                    }
                }
            }
        }
    }

    #[test]
    fn fit_batch_revert_propagates_not_loops() {
        // A reverting estimate (reorg) → Err, NOT an infinite shrink loop.
        let sim = GasSim { base: 50_000, per_header: 100_000, revert: true };
        let batch = vec![[0x11u8; 80]; 100];
        assert!(fit_batch(&sim, Address::ZERO, &batch, 7_200_000).is_err());
    }

    /// Returns a fixed (adversarial) value for ANY call.
    struct Canned(serde_json::Value);
    impl crate::transport::JsonRpc for Canned {
        fn call(&self, _m: &str, _p: serde_json::Value) -> anyhow::Result<serde_json::Value> {
            Ok(self.0.clone())
        }
    }
    /// Transport always errors (RPC down / 30s timeout / 5xx).
    struct Erroring;
    impl crate::transport::JsonRpc for Erroring {
        fn call(&self, _m: &str, _p: serde_json::Value) -> anyhow::Result<serde_json::Value> {
            anyhow::bail!("rpc transport error / timeout")
        }
    }

    #[test]
    fn rpc_readers_never_panic_on_adversarial_responses() {
        use serde_json::json;
        let z = Address::ZERO;
        let bad = [
            json!(null),
            json!(7),
            json!(true),
            json!({}),
            json!([]),
            json!(""),
            json!("0x"),
            json!("0xZZ"),     // invalid hex
            json!("nothex"),
            json!("0x12"),     // 1 byte — short for a 32-byte read
            json!(format!("0x{}", "ff".repeat(200))), // overflows u64/u128
            json!("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        ];
        for v in &bad {
            let rpc = Canned(v.clone());
            // INVARIANT: a malformed/garbage response yields Ok/Err, never a panic.
            let _ = read_gateway_height(&rpc, z);
            let _ = estimate_gas(&rpc, z, &[]);
            let _ = read_gateway_block_exists(&rpc, z, [0u8; 32]);
        }
        // A transport error propagates as Err (never panics, never a sentinel).
        let e = Erroring;
        assert!(read_gateway_height(&e, z).is_err());
        assert!(estimate_gas(&e, z, &[]).is_err());
        assert!(read_gateway_block_exists(&e, z, [0u8; 32]).is_err());
    }

    #[test]
    fn relay_range_advances_bounded_no_gap() {
        // Property sweep: relay_range always starts exactly at gateway_height+1
        // (no gap/overlap), never exceeds batch_max or the tip, and only yields
        // when there's genuinely new work.
        for gh in [0u64, 1, 99, 100_000] {
            for tip in [0u64, gh, gh + 1, gh + 5, gh + 10_000] {
                for batch_max in [1u64, 20, 200] {
                    match relay_range(gh, tip, batch_max) {
                        None => assert!(tip <= gh, "None but tip {tip} > gh {gh}"),
                        Some((from, to)) => {
                            assert_eq!(from, gh + 1, "must start right after the head");
                            assert!(to >= from && to <= tip, "to {to} out of (from {from}, tip {tip})");
                            assert!(to - from + 1 <= batch_max, "batch exceeds max");
                        }
                    }
                }
            }
        }
    }

    // ──────────────────── relayer-loop simulation (reorgs) ────────────────────
    // Drives the REAL relay_once / recover_reorg over a synthetic Bitcoin chain
    // with a mock gateway, proving the loop CONVERGES the gateway to the source
    // tip (a) forward with gas-forced batch splits, and (b) across a reorg —
    // without ever looping unboundedly.
    use std::collections::HashMap;
    use std::sync::Mutex as StdMutex;

    fn h256(header: &[u8; 80]) -> [u8; 32] {
        use bitcoin::hashes::{sha256d, Hash};
        sha256d::Hash::hash(header).to_byte_array()
    }

    /// 80-byte header with `prev` + a `salt` (varied to fork branches).
    fn mk_block(prev: [u8; 32], salt: u32) -> ([u8; 80], [u8; 32]) {
        let mut h = [0u8; 80];
        h[0] = 1;
        h[4..36].copy_from_slice(&prev);
        h[36..40].copy_from_slice(&salt.to_le_bytes());
        h[68..72].copy_from_slice(&salt.to_le_bytes());
        h[72..76].copy_from_slice(&0x207f_ffffu32.to_le_bytes());
        h[76..80].copy_from_slice(&salt.to_le_bytes());
        let hh = h256(&h);
        (h, hh)
    }

    /// Chain of `n` blocks (heights 1..=n) from `genesis`; blocks past `fork`
    /// carry `branch` so two chains share 1..=fork then diverge.
    fn build_chain(genesis: [u8; 32], n: usize, fork: usize, branch: u32) -> Vec<([u8; 80], [u8; 32])> {
        let mut v = Vec::new();
        let mut prev = genesis;
        for i in 1..=n {
            let salt = if i <= fork { i as u32 } else { (i as u32) ^ (branch << 20) };
            let (hdr, hh) = mk_block(prev, salt);
            v.push((hdr, hh));
            prev = hh;
        }
        v
    }

    fn decode_batch(cd: &[u8]) -> Vec<[u8; 80]> {
        let n = u64::from_be_bytes(cd[60..68].try_into().unwrap()) as usize;
        let base = 68 + n * 32;
        (0..n)
            .map(|i| cd[base + i * 128 + 32..base + i * 128 + 112].try_into().unwrap())
            .collect()
    }
    fn sel4(name: &str) -> [u8; 4] {
        keccak256(name.as_bytes())[..4].try_into().unwrap()
    }

    struct GwState {
        known: HashMap<[u8; 32], u64>,
        head_height: u64,
        head: [u8; 32],
        pending: Option<Vec<[u8; 80]>>,
        nonce: u64,
    }
    #[derive(Clone)]
    struct SimGw(std::sync::Arc<StdMutex<GwState>>);
    impl SimGw {
        fn new(genesis: [u8; 32]) -> Self {
            let mut known = HashMap::new();
            known.insert(genesis, 0u64);
            SimGw(std::sync::Arc::new(StdMutex::new(GwState {
                known,
                head_height: 0,
                head: genesis,
                pending: None,
                nonce: 0,
            })))
        }
        fn height(&self) -> u64 {
            self.0.lock().unwrap().head_height
        }
        fn head(&self) -> [u8; 32] {
            self.0.lock().unwrap().head
        }
    }
    impl crate::transport::JsonRpc for SimGw {
        fn call(&self, method: &str, params: serde_json::Value) -> anyhow::Result<serde_json::Value> {
            use serde_json::json;
            let mut s = self.0.lock().unwrap();
            match method {
                "eth_getTransactionCount" => Ok(json!(format!("0x{:x}", s.nonce))),
                "eth_gasPrice" => Ok(json!("0x3b9aca00")),
                "eth_blockNumber" => Ok(json!("0x100")),
                "eth_getTransactionReceipt" => Ok(json!({ "status": "0x1", "blockNumber": "0x100" })),
                "eth_sendRawTransaction" => {
                    s.nonce += 1;
                    if let Some(headers) = s.pending.take() {
                        for hdr in &headers {
                            let mut prev = [0u8; 32];
                            prev.copy_from_slice(&hdr[4..36]);
                            let ph = *s.known.get(&prev).expect("prev known at send");
                            let nh = ph + 1;
                            let hh = h256(hdr);
                            s.known.insert(hh, nh);
                            if nh > s.head_height {
                                s.head_height = nh;
                                s.head = hh;
                            }
                        }
                    }
                    Ok(json!("0xdead"))
                }
                "eth_estimateGas" => {
                    let cd = hex::decode(params[0]["data"].as_str().unwrap().trim_start_matches("0x")).unwrap();
                    let headers = decode_batch(&cd);
                    let mut prev = [0u8; 32];
                    prev.copy_from_slice(&headers[0][4..36]);
                    if !s.known.contains_key(&prev) {
                        anyhow::bail!("execution reverted: PrevBlockDoesNotExist");
                    }
                    let g = 50_000u64 + headers.len() as u64 * 200_000;
                    s.pending = Some(headers);
                    Ok(json!(format!("0x{g:x}")))
                }
                "eth_call" => {
                    let cd = hex::decode(params[0]["data"].as_str().unwrap().trim_start_matches("0x")).unwrap();
                    if cd[..4] == sel4("getMainchainHeight()") {
                        Ok(json!(format!("0x{:064x}", s.head_height)))
                    } else if cd[..4] == sel4("blockExists(bytes32)") {
                        let mut bh = [0u8; 32];
                        bh.copy_from_slice(&cd[4..36]);
                        Ok(json!(format!("0x{:064x}", s.known.contains_key(&bh) as u8)))
                    } else {
                        Ok(json!(format!("0x{}", "00".repeat(32))))
                    }
                }
                m => anyhow::bail!("unexpected method {m}"),
            }
        }
    }

    struct SimSrc(std::sync::Arc<StdMutex<Vec<([u8; 80], [u8; 32])>>>);
    impl SimSrc {
        fn new(c: Vec<([u8; 80], [u8; 32])>) -> Self {
            SimSrc(std::sync::Arc::new(StdMutex::new(c)))
        }
        fn set(&self, c: Vec<([u8; 80], [u8; 32])>) {
            *self.0.lock().unwrap() = c;
        }
    }
    impl BtcHeaderSource for SimSrc {
        fn tip_height(&self) -> anyhow::Result<u64> {
            Ok(self.0.lock().unwrap().len() as u64)
        }
        fn header_at(&self, h: u64) -> anyhow::Result<[u8; 80]> {
            Ok(self.0.lock().unwrap()[(h - 1) as usize].0)
        }
        fn block_hash_be(&self, h: u64) -> anyhow::Result<[u8; 32]> {
            Ok(self.0.lock().unwrap()[(h - 1) as usize].1)
        }
    }

    fn sim_cfg() -> BridgeConfig {
        BridgeConfig {
            rpc_url: String::new(),
            rpc_urls: Vec::new(),
            rpc_quorum: 1,
            chain_id: 1,
            btc_channels: Address::ZERO,
            min_confirmations: 1,
            min_cltv_headroom_blocks: 40,
            settle_max_retries: 1,
            retry_backoff_secs: 0,
            max_fee_per_gas: 1_000_000_000,
            max_priority_fee_per_gas: 1_000_000,
            gas_limit: 400_000,
            receipt_poll_attempts: 3,
            receipt_poll_secs: 0,
            fee_bump_attempts: 1,
            fee_bump_pct: 125,
            settle_min_confirmations: 1,
            max_log_block_span: 10_000,
            swap_out_poll_secs: 0,
            btc_vault: Address::ZERO,
            spv_gateway: Address::repeat_byte(0x6a),
            relayer_defer_inflight: 20,
            relay_batch_max: 200,
            relay_gas_limit: 8_000_000,
            relay_poll_secs: 0,
            relay_reorg_lookback: 144,
            channel_reconcile_secs: 300,
        }
    }

    fn wire(
        gw: &SimGw,
        cfg: &BridgeConfig,
    ) -> (
        std::sync::Arc<SimGw>,
        std::sync::Arc<JsonRpcEvmClient<SimGw, crate::signer::LocalSigner>>,
    ) {
        let signer = crate::signer::LocalSigner::from_secret_key_bytes([0x11u8; 32]).unwrap();
        let evm = std::sync::Arc::new(JsonRpcEvmClient::new(gw.clone(), signer, cfg.clone()));
        (std::sync::Arc::new(gw.clone()), evm)
    }

    #[tokio::test]
    async fn relayer_converges_forward_with_gas_splits() {
        let genesis = [0xAAu8; 32];
        let chain = build_chain(genesis, 130, 130, 0);
        let tip_hash = chain[129].1;
        let src = std::sync::Arc::new(SimSrc::new(chain));
        let gw = SimGw::new(genesis);
        let cfg = sim_cfg();
        let (rpc, evm) = wire(&gw, &cfg);

        let mut rounds = 0;
        while gw.height() < 130 {
            relay_once(&cfg, &rpc, &src, &evm).await.unwrap();
            rounds += 1;
            assert!(rounds < 50, "did not converge (loop?)");
        }
        assert_eq!(gw.height(), 130, "gateway reached tip");
        assert_eq!(gw.head(), tip_hash, "head == source tip");
        assert!(rounds >= 3, "expected gas-split rounds, got {rounds}");
    }

    #[tokio::test]
    async fn relayer_recovers_from_reorg() {
        let genesis = [0xAAu8; 32];
        let chain_a = build_chain(genesis, 100, 100, 0);
        let src = std::sync::Arc::new(SimSrc::new(chain_a.clone()));
        let gw = SimGw::new(genesis);
        let cfg = sim_cfg();
        let (rpc, evm) = wire(&gw, &cfg);
        let mut rounds = 0;
        while gw.height() < 100 {
            relay_once(&cfg, &rpc, &src, &evm).await.unwrap();
            rounds += 1;
            assert!(rounds < 50);
        }
        assert_eq!(gw.head(), chain_a[99].1, "on branch A");

        // Source reorgs to a LONGER branch B forking at height 50.
        let chain_b = build_chain(genesis, 120, 50, 1);
        let b_tip = chain_b[119].1;
        src.set(chain_b);
        rounds = 0;
        while gw.height() < 120 {
            relay_once(&cfg, &rpc, &src, &evm).await.unwrap();
            rounds += 1;
            assert!(rounds < 50, "reorg recovery did not converge (loop?)");
        }
        assert_eq!(gw.height(), 120, "switched to the heavier branch");
        assert_eq!(gw.head(), b_tip, "head == branch B tip");
    }
}

// ───────────────────────────── property-based fuzz ────────────────────────────
//
// Generalizes `rpc_readers_never_panic_on_adversarial_responses` to generated
// inputs. The eth_call return decoders (`read_gateway_height`,
// `read_gateway_block_exists`, `estimate_gas`) all decode UNTRUSTED RPC strings
// and must reject garbage as Err — never slice-panic or overflow. `relay_range`
// is fuzzed for its bounded-window invariant.
#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::Value;

    fn arb_json() -> impl Strategy<Value = Value> {
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(|n| serde_json::json!(n)),
            "[0-9a-fA-FxX]{0,200}".prop_map(Value::String),
            ".*{0,40}".prop_map(Value::String),
        ]
    }

    struct Canned(Value);
    impl JsonRpc for Canned {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            Ok(self.0.clone())
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        // (P1) Every eth_call return decoder over arbitrary JSON ⇒ never panic.
        #[test]
        fn rpc_readers_never_panic(ret in arb_json()) {
            let z = Address::ZERO;
            let rpc = Canned(ret);
            let _ = read_gateway_height(&rpc, z);
            let _ = read_gateway_block_exists(&rpc, z, [0u8; 32]);
            let _ = estimate_gas(&rpc, z, &[]);
        }

        // (P1b) A clean ≥32-byte word always decodes for the height/hop readers.
        #[test]
        fn rpc_readers_decode_clean_word(bytes in proptest::collection::vec(any::<u8>(), 32..64)) {
            let z = Address::ZERO;
            let rpc = Canned(Value::String(format!("0x{}", hex::encode(&bytes))));
            // read_gateway_height decodes word0 into u64; a value that exceeds u64
            // is rejected as an error (NOT silently clamped to 0 — that would re-
            // submit headers from genesis). A clean small word decodes Ok; an
            // overflowing one errors. Either way it never panics.
            let _ = read_gateway_height(&rpc, z);
            // blockExists: nonzero word ⇒ true.
            let ex = read_gateway_block_exists(&rpc, z, [0u8; 32]).unwrap();
            prop_assert_eq!(ex, bytes.iter().any(|b| *b != 0));
        }

        // (P2) relay_range bounded-window invariant over generated heights/caps.
        #[test]
        fn relay_range_is_bounded(gh in any::<u64>(), tip in any::<u64>(), batch in 1u64..1000) {
            match relay_range(gh, tip, batch) {
                None => prop_assert!(tip <= gh),
                Some((from, to)) => {
                    prop_assert_eq!(from, gh + 1);
                    prop_assert!(to >= from && to <= tip);
                    prop_assert!(to - from + 1 <= batch);
                }
            }
        }
    }
}
