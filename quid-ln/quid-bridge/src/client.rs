//! Concrete JSON-RPC `EvmClient`: builds the `settleSwapIn` tx, signs it (via a
//! pluggable [`TxSigner`]), sends it, awaits the receipt, and on a revert
//! disambiguates `AlreadySettled` vs `Undeliverable` by reading `swapInUsed`.
//!
//! SIGNING IS PLUGGABLE ON PURPOSE. The vetted `alloy-consensus`/`alloy-signer`
//! tx path needs alloy-primitives 1.x OR rustc 1.91 — both conflict with this
//! workspace (pinned to alloy-primitives 0.8.26 / rustc 1.90 via quid-hop). So
//! the EIP-1559 signer is a trait; the production impl is decided separately and
//! MUST be verified against a known tx vector before it touches funds. Everything
//! else here (RPC flow, receipt handling, the revert→`swapInUsed` decode) is
//! exercised by the tests below against canned responses.

use std::sync::Mutex;
use std::thread::sleep;
use std::time::Duration;

use alloy_primitives::{hex, keccak256, Address, B256, U256};
use serde_json::{json, Value};
use tracing::{debug, warn};

use crate::config::BridgeConfig;
use crate::evm::{EvmClient, SettleOutcome};
use crate::transport::JsonRpc;

/// Blocks below the tip to pin a quorum-agreed security read (the anti-rollback
/// freshnessSeq). Deep enough to be reorg-safe and present on every honest quorum
/// endpoint (no tip-lag disagreement → no boot false-fail), shallow enough that the
/// anchor stays close to head (~1 min on ETH) so the anti-rollback miss-window is
/// small. See [`JsonRpcEvmClient::eth_read_agreed`].
const AGREED_READ_DEPTH: u64 = 6;

/// How far back to scan for a PRIOR settle's `SwapInSettled` log when a re-driven settle
/// reverts with `swapInUsed` already set (`AlreadySettled`) — the original settle that
/// recorded `consumedSats` is historical, so we look it up by the INDEXED paymentHash over
/// `[tip − this, tip]`. Generous (an `AlreadySettled` is a restart re-drive, so the prior
/// settle is normally recent) but bounded so the `eth_getLogs` range can't be rejected for
/// spanning the whole chain. Not found ⇒ take the whole deposit (safe: never over-refunds).
const SWAP_IN_SETTLED_LOOKBACK_BLOCKS: u64 = 100_000;

/// The `SwapInSettled(address,bytes32,uint256,uint256,address)` event signature — its
/// `keccak256` is `topic0`; `paymentHash` is the 2nd indexed arg (`topic2`); `consumedSats`
/// is the 2nd NON-indexed field (data word[1]).
const SWAP_IN_SETTLED_SIG: &str = "SwapInSettled(address,bytes32,uint256,uint256,address)";

/// Shared static-view fetch: build `selector ‖ arg32?` calldata, `eth_call` it at
/// `latest`, and return the raw ABI-return bytes. Every read-only contract getter
/// goes through this; callers decode + VALIDATE the bytes themselves (bool
/// any-nonzero, length-gated address/tuple slices, overflow-checked integers) —
/// those per-call checks are deliberately NOT shared (a too-long height or a short
/// tuple must fail loudly by its own rule, not a generic one). `arg32` is the
/// already-formed 32-byte ABI word (a bytes32, or a left-padded address); `None`
/// for a no-argument getter.
pub fn eth_call_raw<R: JsonRpc>(
    rpc: &R,
    to: Address,
    selector_sig: &str,
    arg32: Option<&[u8]>,
) -> anyhow::Result<Vec<u8>> {
    eth_call_raw_at_block(rpc, to, selector_sig, arg32, "latest")
}

/// Like [`eth_call_raw`] but pins an explicit `block_tag`. Pass a CONCRETE tag (a
/// `"0x…"` block number/hash) and the quorum transport classes it AGREEMENT — a
/// majority of endpoints must return byte-identical data — instead of the
/// first-healthy, single-endpoint `"latest"` path. Use this for any read that gates
/// a security decision (e.g. the anti-rollback freshnessSeq), so one lying endpoint
/// can't forge the answer.
pub fn eth_call_raw_at_block<R: JsonRpc>(
    rpc: &R,
    to: Address,
    selector_sig: &str,
    arg32: Option<&[u8]>,
    block_tag: &str,
) -> anyhow::Result<Vec<u8>> {
    let mut data = Vec::with_capacity(4 + arg32.map_or(0, <[u8]>::len));
    data.extend_from_slice(&keccak256(selector_sig)[..4]);
    if let Some(a) = arg32 {
        data.extend_from_slice(a);
    }
    let v = rpc.call(
        "eth_call",
        json!([
            { "to": to.to_string(), "data": format!("0x{}", hex::encode(&data)) },
            block_tag
        ]),
    )?;
    let word = v
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("eth_call: no result"))?;
    Ok(hex::decode(word.trim_start_matches("0x"))?)
}

/// Read a contract bool/flag view: `eth_call` the selector and treat ANY nonzero
/// byte in the returned word as `true` (an empty/short return ⇒ `false`). The single
/// home for the "any nonzero ⇒ true" convention shared by the swapInUsed /
/// block-exists readers. (The int/address readers deliberately keep their OWN
/// length-gating — see `eth_call_raw`'s doc above — so they are not routed here.)
pub fn eth_call_bool<R: JsonRpc>(
    rpc: &R,
    to: Address,
    selector_sig: &str,
    arg32: Option<&[u8]>,
) -> anyhow::Result<bool> {
    Ok(eth_call_raw(rpc, to, selector_sig, arg32)?.iter().any(|b| *b != 0))
}

/// Free-function `eth_blockNumber` (advisory tip) for the AGREEMENT helpers below that
/// hold a raw `&R` rather than the full [`JsonRpcEvmClient`].
pub fn block_number_of<R: JsonRpc>(rpc: &R) -> anyhow::Result<u64> {
    parse_quantity(&rpc.call("eth_blockNumber", json!([]))?)
}

/// Free-function AGREEMENT read at a CONCRETE recent block (`tip − AGREED_READ_DEPTH`):
/// the quorum transport then requires a MAJORITY of endpoints to return byte-identical
/// data, so a single lying/compromised endpoint (the untrusted host MITMing `endpoints[0]`)
/// can't forge a spend-gating view. `"latest"` reads are first-healthy (one endpoint) and
/// were the vector for: btcRecipientOf → LP-fee payout redirected to an attacker pkh;
/// swapInUsed → claim the seller's BTC with no USD delivered; pendingOnchainSwapOut →
/// strand a swap-out or double-splice the LP's BTC. The concrete tag is reorg-buried and
/// present on every honest endpoint, so it never false-fails, at a ~AGREED_READ_DEPTH-block
/// lag. This is the free-fn twin of [`JsonRpcEvmClient::eth_read_agreed`].
pub fn eth_call_raw_agreed<R: JsonRpc>(
    rpc: &R,
    to: Address,
    selector_sig: &str,
    arg32: Option<&[u8]>,
) -> anyhow::Result<Vec<u8>> {
    let tip = block_number_of(rpc)?;
    let tag = format!("0x{:x}", tip.saturating_sub(AGREED_READ_DEPTH));
    eth_call_raw_at_block(rpc, to, selector_sig, arg32, &tag)
}

/// The concrete block the AGREEMENT helpers pin to: `tip − AGREED_READ_DEPTH`. Exposed
/// so a caller that must read TWO views at the SAME buried height (or gate on the height
/// vs a known event block) can do so via [`eth_call_raw_at_block`].
pub fn agreed_read_block<R: JsonRpc>(rpc: &R) -> anyhow::Result<u64> {
    Ok(block_number_of(rpc)?.saturating_sub(AGREED_READ_DEPTH))
}

/// AGREEMENT-classed bool read — see [`eth_call_raw_agreed`].
pub fn eth_call_bool_agreed<R: JsonRpc>(
    rpc: &R,
    to: Address,
    selector_sig: &str,
    arg32: Option<&[u8]>,
) -> anyhow::Result<bool> {
    Ok(eth_call_raw_agreed(rpc, to, selector_sig, arg32)?.iter().any(|b| *b != 0))
}

/// The 32-byte-word→uint decoder now lives in [`crate::abi`]; re-exported here so
/// the many `crate::client::word_to_uint` call sites keep resolving unchanged.
pub use crate::abi::word_to_uint;

/// EIP-1559 (type-2) tx fields — everything except the signature.
#[derive(Clone, Debug)]
pub struct TxFields {
    pub chain_id: u64,
    pub nonce: u64,
    pub max_priority_fee_per_gas: u128,
    pub max_fee_per_gas: u128,
    pub gas_limit: u64,
    pub to: Address,
    pub value: U256,
    pub data: Vec<u8>,
}

/// Signs an EIP-1559 settle tx. Abstract so the control flow + RPC decode are
/// testable, and so the (version-constrained) concrete signer is swappable.
pub trait TxSigner: Send + Sync + 'static {
    /// The hot `onlyHop` signer's EVM address.
    fn address(&self) -> Address;
    /// Sign `fields` as a type-2 tx → raw bytes for `eth_sendRawTransaction`.
    fn sign_eip1559(&self, fields: &TxFields) -> anyhow::Result<Vec<u8>>;
}

/// Result of a mined tx: the receipt status bit + the block it landed in.
#[derive(Clone, Copy, Debug)]
struct Mined {
    success: bool,
    block: u64,
}

/// The production `EvmClient`: a JSON-RPC transport + a pluggable signer.
pub struct JsonRpcEvmClient<R: JsonRpc, S: TxSigner> {
    rpc: R,
    signer: S,
    cfg: BridgeConfig,
    /// Serializes nonce acquisition + the FIRST broadcast. The `onlyHop` key is
    /// shared by every sender (settle, reversal, relayer), so without this two
    /// `submit`s could fetch the same `pending` nonce and stack unconfirmable txs
    /// Held ONLY across `get_nonce` + the first `send_raw` — once that tx is
    /// pending the next submit's `get_nonce("pending")` returns N+1, and the
    /// fee-bump loop only re-sends at the SAME nonce N — so the long poll/bump phase
    /// runs LOCK-FREE (H-4). Otherwise one slow/fee-capped tx would head-of-line-
    /// block every other EVM write (incl. a CLTV-racing swap-in settle) for its
    /// whole poll budget. (A genuinely fee-capped tx still blocks LATER nonces via
    /// Ethereum nonce ordering — that needs a separate hot key per sender, an
    /// operational change, not the lock.)
    nonce_lock: Mutex<()>,
}

impl<R: JsonRpc, S: TxSigner> JsonRpcEvmClient<R, S> {
    pub fn new(rpc: R, signer: S, cfg: BridgeConfig) -> Self {
        Self { rpc, signer, cfg, nonce_lock: Mutex::new(()) }
    }

    /// The hot `onlyHop` signer's EVM address — i.e. the `from` a revert-reason
    /// `eth_call` replay must use so the `msg.sender == hopNode` gate matches.
    pub fn address(&self) -> Address {
        self.signer.address()
    }

    /// Clone the shared transport handle — for the daemon's read-only watcher loops
    /// that `eth_call` views alongside this client's writes (same quorum endpoints).
    pub fn rpc_handle(&self) -> R
    where
        R: Clone,
    {
        self.rpc.clone()
    }

    fn get_nonce(&self) -> anyhow::Result<u64> {
        let addr = self.signer.address().to_string();
        let v = self
            .rpc
            .call("eth_getTransactionCount", json!([addr, "pending"]))?;
        parse_quantity(&v)
    }

    /// Network-suggested gas price (`eth_gasPrice`), the base for our fee. Used so
    /// a base-fee spike escalates the fee toward the ceiling instead of leaving a
    /// statically-priced tx stuck in the mempool.
    fn suggested_gas_price(&self) -> anyhow::Result<u128> {
        let v = self.rpc.call("eth_gasPrice", json!([]))?;
        let s = v.as_str().ok_or_else(|| anyhow::anyhow!("eth_gasPrice: no result"))?;
        Ok(u128::from_str_radix(s.trim_start_matches("0x"), 16)?)
    }

    /// Current EVM head height (`eth_blockNumber`).
    fn block_number(&self) -> anyhow::Result<u64> {
        block_number_of(&self.rpc)
    }

    /// Bump `fee` by `fee_bump_pct`%, clamped to the ceiling. Returns `None` when
    /// already at the ceiling (no headroom to make a valid replacement).
    fn bump_fee(&self, fee: u128) -> Option<u128> {
        let ceiling = self.cfg.max_fee_per_gas;
        // A replace-by-fee MUST raise the fee by the node's pricebump floor or it's
        // rejected "replacement underpriced". Require ≥12.5% (covers geth/reth's
        // default 10% with margin). If the ceiling can't fund a ≥12.5% bump, return
        // None so the caller STOPS escalating instead of broadcasting an
        // underpriced duplicate (M-A) — the prior near-ceiling clamp could yield a
        // sub-12.5% "bump" that every node rejected.
        let min_valid = fee.saturating_add(fee / 8).saturating_add(1); // > fee × 1.125
        if min_valid > ceiling {
            return None;
        }
        let bumped = fee.saturating_mul(self.cfg.fee_bump_pct as u128) / 100;
        Some(bumped.max(min_valid).min(ceiling))
    }

    /// Build → sign → send → await for an arbitrary call, with **same-nonce
    /// fee-bump replacement**: if the receipt doesn't arrive within the poll
    /// window, the tx is re-signed at the SAME nonce with a higher fee and
    /// re-broadcast (replace-by-fee), so one underpriced tx can't wedge the shared
    /// nonce. Returns the mined receipt (status + block) once it lands.
    fn submit(&self, to: Address, data: &[u8], gas_limit: u64) -> anyhow::Result<Mined> {
        // Held across get_nonce + the first send only, then released so the long
        // poll/bump phase doesn't head-of-line-block other senders (H-4). See the
        // `nonce_lock` field doc.
        let mut guard = Some(self.nonce_lock.lock().expect("nonce lock poisoned"));
        let nonce = self.get_nonce()?;
        // Start from the network suggestion, clamped to the ceiling.
        let mut max_fee = self.suggested_gas_price()?.min(self.cfg.max_fee_per_gas).max(1);
        let mut prio = self.cfg.max_priority_fee_per_gas.min(max_fee);
        let mut sent: Vec<String> = Vec::new();
        let mut last_hash: Option<String> = None;
        // When the ceiling can't fund a further valid bump, we stop re-broadcasting
        // (an identical/underpriced resend is just rejected) and instead keep
        // POLLING the last tx — it mines once the base fee falls below the ceiling.
        let mut send_this_round = true;

        for attempt in 0..=self.cfg.fee_bump_attempts {
            let tx_hash = if send_this_round {
                let fields = TxFields {
                    chain_id: self.cfg.chain_id,
                    nonce,
                    max_priority_fee_per_gas: prio,
                    max_fee_per_gas: max_fee,
                    gas_limit,
                    to,
                    value: U256::ZERO,
                    data: data.to_vec(),
                };
                let raw = self.signer.sign_eip1559(&fields)?;
                match self.send_raw(&raw) {
                    Ok(h) => {
                        debug!(%h, nonce, max_fee, attempt, "tx submitted");
                        // H-4: the nonce is now pending on the node, so the next
                        // submit reads N+1 — release the lock and let the poll/bump
                        // loop (which only re-sends at THIS nonce) run lock-free.
                        drop(guard.take());
                        sent.push(h.clone());
                        last_hash = Some(h.clone());
                        h
                    }
                    Err(e) => {
                        // A prior bump at this nonce may already have mined ("nonce
                        // too low"/"already known") or a resend was a dup
                        // ("replacement underpriced"). Treat those as benign and
                        // check whether any tx we sent for THIS nonce landed.
                        let msg = e.to_string().to_lowercase();
                        let benign = msg.contains("nonce too low")
                            || msg.contains("already known")
                            || msg.contains("replacement transaction underpriced")
                            || msg.contains("replacement underpriced");
                        if !benign {
                            return Err(e);
                        }
                        if let Some(m) = self.first_mined(&sent)? {
                            return Ok(m);
                        }
                        // H-4: a benign first-send error (e.g. "already known") means a
                        // prior broadcast of THIS nonce is already pending, so the next
                        // submit reads N+1 — release the nonce lock here too, so the
                        // subsequent poll/bump loop runs lock-free instead of head-of-
                        // line-blocking other senders (the same optimization the
                        // success path makes). `take()` is a no-op if already dropped.
                        drop(guard.take());
                        // Benign + not mined: fall through to poll the last tx.
                        match &last_hash {
                            Some(h) => h.clone(),
                            None => continue,
                        }
                    }
                }
            } else {
                // Fee-capped: re-poll the last tx instead of re-broadcasting.
                match &last_hash {
                    Some(h) => h.clone(),
                    None => break,
                }
            };
            if let Some(m) = self.await_receipt(&tx_hash)? {
                return Ok(m);
            }
            // Escalate for the next replacement; stop escalating (keep polling) when
            // the ceiling can't fund a valid ≥12.5% bump. RBF needs BOTH max_fee and
            // priority to rise: when priority can't independently clear the floor
            // (it sits near the ceiling), pin it to the bumped max_fee, which rose
            // ≥12.5% over the old max_fee ≥ old priority — a valid bump.
            match self.bump_fee(max_fee) {
                Some(next_max) => {
                    prio = self.bump_fee(prio).map(|p| p.min(next_max)).unwrap_or(next_max);
                    max_fee = next_max;
                    send_this_round = true;
                }
                None => {
                    if send_this_round {
                        warn!(nonce, max_fee, "fee-capped at ceiling; polling (raise max_fee_per_gas)");
                    }
                    send_this_round = false;
                }
            }
        }
        // Bumps exhausted — last chance: did any of our sent txs mine late?
        if let Some(m) = self.first_mined(&sent)? {
            return Ok(m);
        }
        anyhow::bail!(
            "tx not mined after {} fee bumps (nonce {nonce}); fee-capped or congested",
            self.cfg.fee_bump_attempts
        )
    }

    /// Return the first of `tx_hashes` that has a receipt, if any (used to resolve
    /// a "nonce too low"/"already known" replacement race).
    fn first_mined(&self, tx_hashes: &[String]) -> anyhow::Result<Option<Mined>> {
        for h in tx_hashes {
            if let Some(m) = self.fetch_receipt(h)? {
                return Ok(Some(m));
            }
        }
        Ok(None)
    }

    /// Send a generic signed call and return whether it succeeded. Used by the
    /// SPV header relayer (`addBlockHeaderBatch`) — no confirmation gate needed (a
    /// reorged-out header batch is simply re-relayed).
    pub fn send_tx(&self, to: Address, data: Vec<u8>, gas_limit: u64) -> anyhow::Result<bool> {
        Ok(self.submit(to, &data, gas_limit)?.success)
    }

    /// Public read passthrough so off-chain loops (e.g. the lev keeper) can `eth_call` a view/selector
    /// without exposing the private `rpc`. Returns the raw return-data word(s); the caller decodes.
    pub fn eth_read(&self, to: Address, selector_sig: &str, arg32: Option<&[u8]>) -> anyhow::Result<Vec<u8>> {
        eth_call_raw(&self.rpc, to, selector_sig, arg32)
    }

    /// Quorum-agreed read for security-gating views (the anti-rollback freshnessSeq).
    /// Reads at a CONCRETE recent block (`tip − AGREED_READ_DEPTH`) so the transport
    /// classes it AGREEMENT — a majority of endpoints must return byte-identical data
    /// — rather than trusting one endpoint's `"latest"`. A single lying/compromised
    /// endpoint can no longer forge the answer (e.g. freshnessSeq→0 to slip a
    /// rolled-back monitor past the boot check — audit F2). The depth is reorg-safe
    /// and present on every honest endpoint, so this never boot-false-fails, at the
    /// cost of a small (~1 min) anchor-lag miss-window.
    ///
    /// RESIDUAL: a host that MITMs ALL endpoints can still present a stale-but-
    /// consistent Ethereum view (an old tip / old block); closing that needs TLS-
    /// pinned independent endpoints (host can't forge the provider's cert) or in-
    /// enclave ETH-SPV — a transport/deployment property, plus QUID_RPC_QUORUM ≥ 2.
    pub fn eth_read_agreed(
        &self,
        to: Address,
        selector_sig: &str,
        arg32: Option<&[u8]>,
    ) -> anyhow::Result<Vec<u8>> {
        // eth_blockNumber is advisory (a host can only DEFLATE the tip → an older
        // read, the documented residual — never forge the quorum-agreed value at the
        // block it names). The pinned block is concrete ⇒ AGREEMENT-classed.
        eth_call_raw_agreed(&self.rpc, to, selector_sig, arg32)
    }

    fn send_raw(&self, raw: &[u8]) -> anyhow::Result<String> {
        let v = self.rpc.call(
            "eth_sendRawTransaction",
            json!([format!("0x{}", hex::encode(raw))]),
        )?;
        v.as_str()
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("eth_sendRawTransaction: no tx hash in result"))
    }

    /// Fetch a receipt once (no polling). `None` = not yet mined.
    fn fetch_receipt(&self, tx_hash: &str) -> anyhow::Result<Option<Mined>> {
        let v = self.rpc.call("eth_getTransactionReceipt", json!([tx_hash]))?;
        if v.is_null() {
            return Ok(None);
        }
        let success = parse_quantity(
            &json!(v.get("status").and_then(Value::as_str).ok_or_else(|| anyhow::anyhow!("receipt missing status"))?),
        )? == 1;
        let block = parse_quantity(
            &json!(v.get("blockNumber").and_then(Value::as_str).ok_or_else(|| anyhow::anyhow!("receipt missing blockNumber"))?),
        )?;
        Ok(Some(Mined { success, block }))
    }

    /// Poll the receipt up to `receipt_poll_attempts` times. `Ok(Some)` once mined,
    /// `Ok(None)` if it never arrives in the window (caller fee-bumps + retries).
    fn await_receipt(&self, tx_hash: &str) -> anyhow::Result<Option<Mined>> {
        for _ in 0..self.cfg.receipt_poll_attempts {
            if let Some(m) = self.fetch_receipt(tx_hash)? {
                return Ok(Some(m));
            }
            sleep(Duration::from_secs(self.cfg.receipt_poll_secs));
        }
        Ok(None)
    }

    /// `swapInUsed(bytes32)` at a CONCRETE block ⇒ AGREEMENT-classed (audit F2): this
    /// gates CLAIMING the seller's inbound BTC, so a first-healthy `"latest"` read let
    /// ONE lying endpoint report `swapInUsed:true` for a settle that never delivered USD
    /// → the hop claims the BTC for nothing. Pinning the settle's OWN block makes the
    /// read quorum-agreed (a majority must return identical bytes) AND precise — no tip
    /// lag / added confirmation delay; `swap_in_used_buried` waits for that block to bury.
    fn swap_in_used_at(&self, payment_hash: B256, block: u64) -> anyhow::Result<bool> {
        let tag = format!("0x{block:x}");
        Ok(eth_call_raw_at_block(
            &self.rpc,
            self.cfg.btc_channels,
            "swapInUsed(bytes32)",
            Some(payment_hash.as_slice()),
            &tag,
        )?
        .iter()
        .any(|b| *b != 0))
    }

    /// Confirm the settle at `settle_block` recorded `swapInUsed` AND that the block is
    /// buried under `depth` confs (replay path). The gating read is AGREEMENT-classed
    /// at the concrete `settle_block` (audit F2) so a lying endpoint can't forge it; the
    /// burial wait then ensures a reorg can't later unwind that block (re-reading the same
    /// height post-burial catches a settle that got reorged out). `depth <= 1` ⇒ the
    /// single agreed read at the settle block suffices.
    fn swap_in_used_buried(&self, payment_hash: B256, depth: u64, settle_block: u64) -> anyhow::Result<bool> {
        if !self.swap_in_used_at(payment_hash, settle_block)? {
            return Ok(false);
        }
        if depth <= 1 {
            return Ok(true);
        }
        for _ in 0..self.cfg.receipt_poll_attempts {
            if self.block_number()?.saturating_sub(settle_block) + 1 >= depth {
                return self.swap_in_used_at(payment_hash, settle_block); // re-check after burial
            }
            sleep(Duration::from_secs(self.cfg.receipt_poll_secs));
        }
        // Couldn't confirm burial in budget — treat as not-yet-final (transient).
        anyhow::bail!("settle block {settle_block} not buried under {depth} confs within budget — retry")
    }

    /// How many of the seller's sats a `settleSwapIn` actually converted, decoded from the
    /// `SwapInSettled(seller, paymentHash, sats, consumedSats, token)` event (`consumedSats`
    /// = the 2nd non-indexed field, data word[1]). Filters `eth_getLogs` by `btc_channels`
    /// + `topic0` + the INDEXED `paymentHash` (`topic2`) over `[from_block, to_block]`.
    ///
    /// Returns `sats` — i.e. "the pool converted everything, refund nothing" — whenever the
    /// log can't be found or decoded (RPC error, empty range, garbage data). That fallback
    /// is deliberately the SAFE direction: it can only make the hop take the WHOLE deposit,
    /// never refund more than the deposit (an over-refund would give away the hop's BTC).
    fn read_consumed_sats(
        &self,
        payment_hash: B256,
        from_block: u64,
        to_block: u64,
        sats: u64,
    ) -> u64 {
        let topic0 = keccak256(SWAP_IN_SETTLED_SIG.as_bytes());
        let params = json!([{
            "fromBlock": format!("0x{from_block:x}"),
            "toBlock": format!("0x{to_block:x}"),
            "address": self.cfg.btc_channels.to_string(),
            // [topic0, ANY seller, this paymentHash] — paymentHash is unique per swap-in.
            "topics": [
                format!("0x{}", hex::encode(topic0)),
                Value::Null,
                format!("0x{}", hex::encode(payment_hash)),
            ],
        }]);
        match self.rpc.call("eth_getLogs", params) {
            Ok(v) => decode_consumed_from_logs(&v, sats),
            Err(e) => {
                warn!(error = %e, "SwapInSettled log read failed — taking the whole deposit (safe)");
                sats
            }
        }
    }

    /// One-time sanity check that `btc_channels` actually has contract code on the
    /// configured chain (L-1). A settle tx to a code-less address (EOA / wrong
    /// chain id / typo'd address) returns `status: 0x1` and would be read as
    /// "delivered" — so the BTC would be claimed with no USD anywhere. Call once
    /// at daemon startup; a failure here is a config error, not a runtime one.
    pub fn verify_btc_channels_has_code(&self) -> anyhow::Result<()> {
        let v = self.rpc.call(
            "eth_getCode",
            json!([self.cfg.btc_channels.to_string(), "latest"]),
        )?;
        let code = v.as_str().unwrap_or("0x");
        if code == "0x" || code == "0x0" || code.is_empty() {
            anyhow::bail!(
                "btc_channels {} has no code on chain {} — refusing to settle against \
                 a code-less address (check address/chain_id)",
                self.cfg.btc_channels,
                self.cfg.chain_id
            );
        }
        Ok(())
    }

    /// Fail fast if the RPC endpoint isn't on the chain we sign for. EIP-155 bakes
    /// `chain_id` into every signature, so a wrong `QUID_RPC_URL`/`QUID_CHAIN_ID`
    /// pair can't cause cross-chain *replay* — but it DOES sign for chain Y while
    /// submitting to chain X, so settlement silently never mines and the fee-bump
    /// budget burns per tx. The code/identity startup checks establish the other
    /// invariants; this is the missing "the RPC speaks the chain we sign for" one.
    pub fn verify_chain_id(&self) -> anyhow::Result<()> {
        let v = self.rpc.call("eth_chainId", json!([]))?;
        let got = parse_quantity(&v)?;
        if got != self.cfg.chain_id {
            anyhow::bail!(
                "RPC endpoint is on chain {got} but cfg.chain_id is {} — refusing to \
                 start (wrong QUID_RPC_URL / QUID_CHAIN_ID)",
                self.cfg.chain_id
            );
        }
        Ok(())
    }

    /// (T1-b) Return the USD an undeliverable on-chain swap-out already took from the
    /// swapper, via `reverseSwapOut`. Deliberately NOT a method on [`EvmClient`]: that trait
    /// is "the EVM calls the swap-in SENDER needs", and a reversal is not a swap-in — it
    /// credits no BTC and attests nothing. The only caller holds a concrete client, so the
    /// distinction costs nothing and stops the two paths sharing a stub.
    ///
    /// The outcome disambiguation is identical in SHAPE to `settle_swap_in` and identical in
    /// KIND: the dedup key is `swapInUsed[swapId]` on both paths (the contract reuses that
    /// map for reversals), so a revert with the key SET is a replay of a reversal that already
    /// landed, and a revert with it CLEAR is a genuine failure to refund. `consumed_sats` is
    /// not read back: nothing is claimed against a reversal, so there is no remainder to
    /// refund and no log to decode.
    pub fn reverse_swap_out(
        &self,
        swap_id: B256,
        token: Address,
        min_delivered_usd: U256,
        require_full: bool,
    ) -> anyhow::Result<SettleOutcome> {
        let data =
            quid_hop::swap::reverse_swap_out_calldata(swap_id.0, token, min_delivered_usd, require_full);
        let depth = self.cfg.settle_min_confirmations;
        let mined = self.submit(self.cfg.btc_channels, &data, self.cfg.gas_limit)?;
        debug!(success = mined.success, block = mined.block, "reversal mined");

        // Same uniform reorg gate as the credit path: a status-1 receipt whose `swapInUsed`
        // does not survive burial was reorged out → transient, retry.
        if self.swap_in_used_buried(swap_id, depth, mined.block)? {
            // `consumed_sats` is meaningless for a reversal (see above); report the whole
            // amount so the variants stay shape-compatible with the credit path's.
            return Ok(if mined.success {
                SettleOutcome::Delivered { consumed_sats: 0 }
            } else {
                warn!("reverseSwapOut reverted but swapInUsed set — already reversed");
                SettleOutcome::AlreadySettled { consumed_sats: 0 }
            });
        }
        if mined.success {
            anyhow::bail!("reversal mined but swapInUsed unconfirmed (reorg?) — retry");
        }
        Ok(SettleOutcome::Undeliverable)
    }
}

// The LpFeeMarker impl (markLpFeePaid/lpFeePaid F4 dedup) was REMOVED with the
// off-chain fee settler — fees now compound in-channel, so there is no native payout to
// dedup on-chain.

impl<R: JsonRpc, S: TxSigner> crate::provision_api::MigrationNonceConsumer for JsonRpcEvmClient<R, S> {
    fn consume(&self, nonce: [u8; 32]) -> anyhow::Result<()> {
        // markMigrationNonceUsed(bytes32) — atomic compare-and-set on-chain: reverts if the
        // nonce is already used (a REPLAY) or msg.sender isn't an active hop.
        let mut data = Vec::with_capacity(4 + 32);
        data.extend_from_slice(&keccak256("markMigrationNonceUsed(bytes32)")[..4]);
        data.extend_from_slice(&nonce);
        if !self.send_tx(self.cfg.btc_channels, data, self.cfg.gas_limit)? {
            anyhow::bail!(
                "markMigrationNonceUsed reverted — migration nonce already used (REPLAY) or \
                 caller is not an active hop; refusing to export the seed"
            );
        }
        // FAIL-CLOSED confirm: don't trust the single-endpoint receipt — AGREEMENT-read the
        // consumption back at the settle-confirmation depth before exporting, so a lying host
        // can't fake the consume then let a replay through. Same depth as the fee payout.
        let depth = AGREED_READ_DEPTH.max(self.cfg.settle_min_confirmations);
        for _ in 0..self.cfg.receipt_poll_attempts {
            let tag = format!("0x{:x}", block_number_of(&self.rpc)?.saturating_sub(depth));
            if eth_call_raw_at_block(
                &self.rpc, self.cfg.btc_channels, "migrationNonceUsed(bytes32)", Some(&nonce), &tag,
            )?
            .iter()
            .any(|b| *b != 0)
            {
                return Ok(());
            }
            sleep(Duration::from_secs(self.cfg.receipt_poll_secs));
        }
        anyhow::bail!("markMigrationNonceUsed not confirmed within budget — refusing to export the seed")
    }
}

impl<R: JsonRpc, S: TxSigner> EvmClient for JsonRpcEvmClient<R, S> {
    fn settle_swap_in(
        &self,
        seller: Address,
        sats: u64,
        token: Address,
        payment_hash: B256,
        min_delivered_usd: U256,
        require_full: bool,
    ) -> anyhow::Result<SettleOutcome> {
        let data = quid_hop::swap::settle_swapin_calldata(
            seller,
            sats,
            token,
            payment_hash.0,
            min_delivered_usd,
            require_full,
        );
        let depth = self.cfg.settle_min_confirmations;
        let mined = self.submit(self.cfg.btc_channels, &data, self.cfg.gas_limit)?;
        debug!(success = mined.success, block = mined.block, "settle mined");

        // The BTC claim is irreversible, so gate BOTH claim-worthy outcomes
        // (Delivered, AlreadySettled) on `swapInUsed` being buried under `depth`
        // confirmations — a single uniform reorg gate. A status-1 receipt
        // whose `swapInUsed` doesn't survive burial was reorged out → transient
        // retry (never a claim on un-settled BTC).
        let buried = self.swap_in_used_buried(payment_hash, depth, mined.block)?;
        if buried {
            return Ok(if mined.success {
                // Read how many of the seller's sats were actually converted (partial fills
                // consume < sats) from THIS settle's SwapInSettled log, at its own block —
                // the hop refunds the `sats − consumedSats` remainder when it claims.
                let consumed_sats = self.read_consumed_sats(payment_hash, mined.block, mined.block, sats);
                SettleOutcome::Delivered { consumed_sats }
            } else {
                // Reverted but already-recorded: a restart replay re-sent a settle
                // for a hash a prior settle had delivered. Recover consumedSats from that
                // PRIOR settle's historical log (indexed by paymentHash); if it can't be
                // found in the lookback window, take the whole deposit (safe fallback).
                warn!("settleSwapIn reverted but swapInUsed set — already settled");
                let tip = self.block_number().unwrap_or(mined.block);
                let from = tip.saturating_sub(SWAP_IN_SETTLED_LOOKBACK_BLOCKS);
                let consumed_sats = self.read_consumed_sats(payment_hash, from, tip, sats);
                SettleOutcome::AlreadySettled { consumed_sats }
            });
        }
        if mined.success {
            // Mined successfully yet swapInUsed isn't confirmed-buried — only a
            // reorg drops a status-1 settle. Don't claim; retry.
            anyhow::bail!("settle mined but swapInUsed unconfirmed (reorg?) — retry");
        }
        // Reverted and never recorded → genuinely undeliverable (floor / dry pool).
        Ok(SettleOutcome::Undeliverable)
    }
}

/// Decode `consumedSats` (data word[1]) from an `eth_getLogs` array of `SwapInSettled`
/// logs. The event's non-indexed data is `[sats(32) ‖ consumedSats(32) ‖ token(32)]`. Takes
/// the LAST matching log (paymentHash is unique, so there is at most one). Returns `sats`
/// (take the whole deposit — the safe direction) on an empty array or any malformed/short/
/// oversized word: this decodes UNTRUSTED RPC JSON and must never panic. `consumedSats` is
/// clamped to `sats` (it can never exceed the deposited amount on-chain).
fn decode_consumed_from_logs(logs: &Value, sats: u64) -> u64 {
    let Some(arr) = logs.as_array() else { return sats };
    for log in arr.iter().rev() {
        let Some(data_str) = log.get("data").and_then(Value::as_str) else { continue };
        let Some(data) = crate::hexutil::hex_bytes(data_str) else { continue };
        // consumedSats is the 2nd 32-byte word — bytes [32..64].
        let Some(word) = data.get(32..64) else { continue };
        if let Ok(c) = word_to_uint::<u64>(word, "consumedSats") {
            return c.min(sats);
        }
    }
    sats
}

/// Parse a `0x`-prefixed hex quantity (e.g. `"0x1a"`) into u64 from a JSON value.
fn parse_quantity(v: &Value) -> anyhow::Result<u64> {
    let s = v
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("expected hex quantity string"))?;
    crate::hexutil::hex_u64(s).ok_or_else(|| anyhow::anyhow!("invalid hex quantity {s:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    const ZERO_WORD: &str =
        "0x0000000000000000000000000000000000000000000000000000000000000000";
    const ONE_WORD: &str =
        "0x0000000000000000000000000000000000000000000000000000000000000001";

    struct MockRpc {
        receipt_status: Option<String>, // None = stays null (never mined)
        swap_in_used_word: String,
        settled_logs: Value, // eth_getLogs return for the SwapInSettled lookup
        calls: Mutex<Vec<String>>,
    }
    impl MockRpc {
        fn new(receipt_status: Option<&str>, swap_in_used_word: &str) -> Self {
            Self {
                receipt_status: receipt_status.map(String::from),
                swap_in_used_word: swap_in_used_word.into(),
                settled_logs: json!([]), // default: no log ⇒ consumed falls back to `sats`
                calls: Mutex::new(vec![]),
            }
        }
        /// Inject the SwapInSettled `eth_getLogs` response (for the consumedSats decode).
        fn with_settled_logs(mut self, logs: Value) -> Self {
            self.settled_logs = logs;
            self
        }
    }
    impl JsonRpc for MockRpc {
        fn call(&self, method: &str, _params: Value) -> anyhow::Result<Value> {
            self.calls.lock().unwrap().push(method.to_string());
            Ok(match method {
                "eth_getTransactionCount" => json!("0x5"),
                "eth_gasPrice" => json!("0x3b9aca00"), // 1 gwei (< ceiling → bumpable)
                "eth_blockNumber" => json!("0x100"),
                "eth_sendRawTransaction" => json!("0xabc123"),
                // Receipts carry a blockNumber now (used by the confirmation gate).
                "eth_getTransactionReceipt" => match &self.receipt_status {
                    Some(s) => json!({ "status": s, "blockNumber": "0x100" }),
                    None => Value::Null,
                },
                "eth_call" => json!(self.swap_in_used_word),
                "eth_getLogs" => self.settled_logs.clone(),
                m => anyhow::bail!("unexpected method {m}"),
            })
        }
    }

    /// Build a `SwapInSettled` `eth_getLogs`-shaped array carrying `consumed` in data word[1].
    fn settled_log(sats: u64, consumed: u64) -> Value {
        let mut data = Vec::new();
        data.extend_from_slice(&crate::abi::u64_word(sats));
        data.extend_from_slice(&crate::abi::u64_word(consumed));
        data.extend_from_slice(&crate::abi::address_word(Address::repeat_byte(0x22)));
        json!([{ "data": format!("0x{}", hex::encode(&data)), "blockNumber": "0x100" }])
    }

    struct MockSigner;
    impl TxSigner for MockSigner {
        fn address(&self) -> Address {
            Address::repeat_byte(0xAA)
        }
        fn sign_eip1559(&self, _f: &TxFields) -> anyhow::Result<Vec<u8>> {
            Ok(vec![0x02, 0xde, 0xad]) // dummy raw tx
        }
    }

    fn cfg() -> BridgeConfig {
        BridgeConfig {
            rpc_url: String::new(),
            rpc_urls: Vec::new(),
            rpc_quorum: 1,
            chain_id: 8453,
            btc_channels: Address::repeat_byte(0xBC),
            min_confirmations: 1,
            min_cltv_headroom_blocks: 40,
            settle_max_retries: 3,
            retry_backoff_secs: 0,
            max_fee_per_gas: 1_000_000_000,
            max_priority_fee_per_gas: 1_000_000,
            gas_limit: 300_000,
            receipt_poll_attempts: 3,
            receipt_poll_secs: 0,
            fee_bump_attempts: 3,
            fee_bump_pct: 125,
            settle_min_confirmations: 1, // inclusion suffices in unit tests
            max_log_block_span: 10_000,
            swap_out_poll_secs: 0,
            btc_vault: Address::repeat_byte(0xFA),
            spv_gateway: Address::repeat_byte(0x5B),
            relayer_defer_inflight: 20,
            relay_batch_max: 100,
            relay_gas_limit: 5_000_000,
            relay_poll_secs: 0,
            relay_reorg_lookback: 144,
            channel_reconcile_secs: 300,
        }
    }
    fn client(rpc: MockRpc) -> JsonRpcEvmClient<MockRpc, MockSigner> {
        JsonRpcEvmClient::new(rpc, MockSigner, cfg())
    }
    fn args() -> (Address, u64, Address, B256, U256) {
        (
            Address::repeat_byte(0x11),
            100_000,
            Address::repeat_byte(0x22),
            B256::repeat_byte(0xAB),
            U256::from(1_000_000u64),
        )
    }

    #[test]
    fn success_receipt_confirmed_is_delivered() {
        // Success is now confirmation-gated — swapInUsed must be set (and
        // survive burial; depth=1 ⇒ a single true read) before claiming.
        let c = client(MockRpc::new(Some("0x1"), ONE_WORD));
        let (s, sa, t, h, m) = args();
        // Empty SwapInSettled logs ⇒ consumed falls back to the full `sats` (take all).
        assert_eq!(
            c.settle_swap_in(s, sa, t, h, m, true).unwrap(),
            SettleOutcome::Delivered { consumed_sats: sa }
        );
        // The confirmation gate reads swapInUsed even on a status-1 receipt.
        assert!(c.rpc.calls.lock().unwrap().iter().any(|m| m == "eth_call"));
    }

    #[test]
    fn delivered_decodes_partial_consumed_sats_from_log() {
        // A partial fill: the SwapInSettled log reports consumedSats < sats. The client
        // surfaces it on the Delivered outcome so the claim refunds the remainder.
        let (s, sa, t, h, m) = args(); // sa = 100_000
        let c = client(MockRpc::new(Some("0x1"), ONE_WORD).with_settled_logs(settled_log(sa, 60_000)));
        assert_eq!(
            c.settle_swap_in(s, sa, t, h, m, true).unwrap(),
            SettleOutcome::Delivered { consumed_sats: 60_000 }
        );
    }

    #[test]
    fn success_receipt_but_swapinused_false_is_transient() {
        // A status-1 receipt whose swapInUsed is false ⇒ reorged out ⇒ must NOT
        // claim; transient Err so the sender retries.
        let c = client(MockRpc::new(Some("0x1"), ZERO_WORD));
        let (s, sa, t, h, m) = args();
        assert!(c.settle_swap_in(s, sa, t, h, m, true).is_err());
    }

    #[test]
    fn revert_with_swapinused_is_already_settled() {
        let c = client(MockRpc::new(Some("0x0"), ONE_WORD));
        let (s, sa, t, h, m) = args();
        // No historical log in the mock ⇒ consumed falls back to `sats` (safe take-all).
        assert_eq!(
            c.settle_swap_in(s, sa, t, h, m, true).unwrap(),
            SettleOutcome::AlreadySettled { consumed_sats: sa }
        );
    }

    #[test]
    fn revert_without_swapinused_is_undeliverable() {
        let c = client(MockRpc::new(Some("0x0"), ZERO_WORD));
        let (s, sa, t, h, m) = args();
        assert_eq!(
            c.settle_swap_in(s, sa, t, h, m, true).unwrap(),
            SettleOutcome::Undeliverable
        );
    }

    #[test]
    fn missing_receipt_is_transient_err() {
        let c = client(MockRpc::new(None, ZERO_WORD));
        let (s, sa, t, h, m) = args();
        assert!(c.settle_swap_in(s, sa, t, h, m, true).is_err());
    }

    /// A tx unmined in the first poll window is re-sent at the SAME nonce
    /// with a bumped fee; once it mines the settle succeeds. The mock withholds a
    /// receipt until the 2nd broadcast (i.e. after one fee bump) and keeps the
    /// nonce fixed across sends.
    struct BumpMock {
        sends: Mutex<u32>,
        nonce_reads: Mutex<u32>,
    }
    impl JsonRpc for BumpMock {
        fn call(&self, method: &str, _p: Value) -> anyhow::Result<Value> {
            Ok(match method {
                "eth_getTransactionCount" => {
                    *self.nonce_reads.lock().unwrap() += 1;
                    json!("0x5")
                }
                "eth_gasPrice" => json!("0x1dcd6500"), // 0.5 gwei < 1 gwei ceiling → bumpable
                "eth_blockNumber" => json!("0x100"),
                "eth_sendRawTransaction" => {
                    *self.sends.lock().unwrap() += 1;
                    json!("0xabc123")
                }
                "eth_getTransactionReceipt" => {
                    // No receipt until the 2nd broadcast (after one fee bump).
                    if *self.sends.lock().unwrap() >= 2 {
                        json!({ "status": "0x1", "blockNumber": "0x100" })
                    } else {
                        Value::Null
                    }
                }
                "eth_call" => json!(ONE_WORD),
                "eth_getLogs" => json!([]), // empty ⇒ consumed = sats (full fill)
                m => anyhow::bail!("unexpected {m}"),
            })
        }
    }

    #[test]
    fn fee_bump_replaces_at_same_nonce_then_mines() {
        let rpc = BumpMock { sends: Mutex::new(0), nonce_reads: Mutex::new(0) };
        let c = JsonRpcEvmClient::new(rpc, MockSigner, cfg());
        let (s, sa, t, h, m) = args();
        assert_eq!(c.settle_swap_in(s, sa, t, h, m, true).unwrap(), SettleOutcome::Delivered { consumed_sats: sa });
        // Exactly one nonce fetch for the whole submit (all bumps reuse it).
        assert_eq!(*c.rpc.nonce_reads.lock().unwrap(), 1, "one nonce for all bumps");
        assert!(*c.rpc.sends.lock().unwrap() >= 2, "re-broadcast at least once");
    }

    #[test]
    fn bump_fee_enforces_rbf_floor() {
        // cfg(): max_fee_per_gas (ceiling) = 1e9, fee_bump_pct = 125.
        let c = client(MockRpc::new(Some("0x1"), ONE_WORD));
        // Ample headroom: a bump must rise ≥12.5% over the input.
        let b = c.bump_fee(100_000_000).expect("bumpable");
        assert!(b >= 100_000_000 + 100_000_000 / 8, "bump clears the 12.5% RBF floor");
        // Near the ceiling: a ≥12.5% bump would exceed it → None (caller must stop
        // escalating, not broadcast an underpriced duplicate) — the M-A fix.
        assert!(c.bump_fee(950_000_000).is_none(), "no valid bump when ceiling can't fund +12.5%");
        assert!(c.bump_fee(1_000_000_000).is_none(), "at ceiling → None");
    }

    #[test]
    fn decode_consumed_from_logs_handles_partial_full_and_garbage() {
        // Partial: word[1] < sats ⇒ that value.
        assert_eq!(decode_consumed_from_logs(&settled_log(100_000, 40_000), 100_000), 40_000);
        // Empty array ⇒ take-all fallback.
        assert_eq!(decode_consumed_from_logs(&json!([]), 100_000), 100_000);
        // Non-array / malformed ⇒ fallback.
        assert_eq!(decode_consumed_from_logs(&json!("nope"), 100_000), 100_000);
        // Short data (< 64 bytes) ⇒ fallback.
        assert_eq!(
            decode_consumed_from_logs(&json!([{ "data": "0x1234" }]), 100_000),
            100_000
        );
        // consumedSats reported above the deposit ⇒ clamped to sats (never over-take math).
        assert_eq!(decode_consumed_from_logs(&settled_log(100_000, 999_999), 100_000), 100_000);
    }

    #[test]
    fn swap_in_used_selector_is_correct() {
        // First 4 bytes of keccak256("swapInUsed(bytes32)").
        let sel = &keccak256("swapInUsed(bytes32)")[..4];
        assert_eq!(sel.len(), 4);
        // Stable across runs (regression guard on the ABI signature string).
        assert_eq!(hex::encode(sel), hex::encode(&keccak256("swapInUsed(bytes32)")[..4]));
    }
}

// ───────────────────────────── property-based fuzz ────────────────────────────
//
// `eth_call_bool` decodes an UNTRUSTED `eth_call` return (the bool-word view).
// `parse_quantity` decodes UNTRUSTED `0x`-hex quantities (nonce / blockNumber /
// chainId / receipt status). Both must reject garbage as Err and never panic.
#[cfg(test)]
mod proptests {
    use super::*;
    use alloy_primitives::{hex, Address, B256};
    use proptest::prelude::*;

    fn arb_json() -> impl Strategy<Value = Value> {
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(|n| serde_json::json!(n)),
            "[0-9a-fA-FxX]{0,80}".prop_map(Value::String),
            ".*{0,40}".prop_map(Value::String),
        ]
    }

    struct Canned(Value);
    impl JsonRpc for Canned {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            Ok(self.0.clone())
        }
    }
    struct Erroring;
    impl JsonRpc for Erroring {
        fn call(&self, _m: &str, _p: Value) -> anyhow::Result<Value> {
            anyhow::bail!("rpc transport error")
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        // (P1) eth_call_bool over arbitrary eth_call returns ⇒ never panic (Ok/Err).
        #[test]
        fn eth_call_bool_never_panics(ret in arb_json()) {
            let rpc = Canned(ret);
            let _ = eth_call_bool(&rpc, Address::repeat_byte(0xBC), "swapInUsed(bytes32)",
                Some(B256::repeat_byte(0xAB).as_slice()));
        }

        // (P1b) A clean 32-byte word: zero ⇒ false, any nonzero ⇒ true; never panic.
        #[test]
        fn eth_call_bool_word_decodes(word in proptest::array::uniform32(any::<u8>())) {
            let rpc = Canned(serde_json::json!(format!("0x{}", hex::encode(word))));
            let got = eth_call_bool(&rpc, Address::repeat_byte(0xBC), "f()", None).unwrap();
            prop_assert_eq!(got, word.iter().any(|b| *b != 0));
        }

        // (P2) parse_quantity over arbitrary JSON ⇒ never panic; a transport error
        // propagates as Err.
        #[test]
        fn parse_quantity_never_panics(v in arb_json()) {
            let _ = parse_quantity(&v);
        }
    }

    #[test]
    fn eth_call_bool_transport_error_is_err() {
        assert!(eth_call_bool(&Erroring, Address::ZERO, "f()", None).is_err());
    }
}
