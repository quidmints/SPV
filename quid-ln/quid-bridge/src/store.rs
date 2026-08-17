//! Durable bridge state — closes the one money-relevant robustness gap.
//!
//! At rest the blob is AES-SEALED under the enclave key and version-anchored on-chain
//! (audit F4/F5) when loaded via [`BridgeStore::load_sealed`] — so the LN preimage + swap
//! state are neither cleartext nor rollback-able on an untrusted host. The
//! plaintext [`BridgeStore::load`] path stays for tests / no-key modes.
//!
//! Persists (JSON, sealed + written atomically):
//!   • IN-FLIGHT swap-ins (so a crash in the settle→claim window can be re-driven
//!     on boot — LDK does NOT re-emit `PaymentClaimable`, so this record is the
//!     only re-drive trigger),
//!   • the restart-durable splice CID map.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Write as _};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use alloy_primitives::{Address, U256};
use crate::hexutil::hex_b32 as decode32; // shared 32-byte hex decoder
use quid_crypto::aes::AesMasterKey;
use quid_crypto::rng::SysRng;
use quid_hop::event_handler::ClaimedSwapIn;
use crate::swap_in_onchain::OnchainSwapIn;
use serde::{Deserialize, Serialize};
use tracing::{error, warn};

/// AEAD associated data binding the sealed store to its role, so a sealed blob from a
/// different file (e.g. a monitor) can't be swapped in for it.
const STORE_SEAL_AAD: &[u8] = b"quid-bridge-store-v1";

/// Serde projection of a [`ClaimedSwapIn`] (alloy types as hex strings), so an
/// in-flight swap-in (received → settle → claim) survives a crash. Mirrors
/// [`ReqRec`] for swap-outs.
///
/// PREIMAGE-AT-REST: this record persists the LN `preimage`. It is load-bearing —
/// this LDK does NOT re-emit `PaymentClaimable` on restart, so the boot re-drive must
/// reconstruct the claim from this record alone (no replayed event carries the
/// preimage). To keep it off cleartext host disk (audit F5), the whole store is
/// AES-SEALED under the enclave key when loaded via [`BridgeStore::load_sealed`] (like
/// the LDK monitors); only the plaintext test path (`load`) leaves it in the clear.
#[derive(Clone, Serialize, Deserialize)]
struct SwapInRec {
    seller: String,
    sats: u64,
    token: String,
    payment_hash: String,
    /// The floor (output stable's decimals), as a decimal string.
    min_delivered_usd: String,
    /// The LN preimage (hex). See the PREIMAGE-AT-REST note above.
    preimage: String,
    /// `None` ⇒ no settle-time CLTV deadline carried (back-compat). `#[serde(default)]`
    /// so a record written without it (or pre-field state) loads cleanly.
    #[serde(default)]
    claim_deadline: Option<u32>,
}
impl SwapInRec {
    fn of(c: &ClaimedSwapIn) -> Self {
        Self {
            seller: c.seller.to_string(),
            sats: c.sats,
            token: c.token.to_string(),
            payment_hash: format!("0x{}", alloy_primitives::hex::encode(c.payment_hash)),
            min_delivered_usd: c.min_delivered_usd.to_string(),
            preimage: format!("0x{}", alloy_primitives::hex::encode(c.preimage)),
            claim_deadline: c.claim_deadline,
        }
    }
    fn to_claimed(&self) -> Option<ClaimedSwapIn> {
        let ph = alloy_primitives::hex::decode(self.payment_hash.trim_start_matches("0x")).ok()?;
        let pi = alloy_primitives::hex::decode(self.preimage.trim_start_matches("0x")).ok()?;
        Some(ClaimedSwapIn {
            seller: Address::from_str(&self.seller).ok()?,
            sats: self.sats,
            token: Address::from_str(&self.token).ok()?,
            payment_hash: <[u8; 32]>::try_from(ph.as_slice()).ok()?,
            min_delivered_usd: U256::from_str(&self.min_delivered_usd).ok()?,
            preimage: <[u8; 32]>::try_from(pi.as_slice()).ok()?,
            claim_deadline: self.claim_deadline,
        })
    }
}

/// Serde projection of an on-chain swap-in registration ([`OnchainSwapIn`]), so a
/// registered-but-not-yet-deposited swap survives a restart: the unified on-chain watcher
/// reads these back on boot and keeps servicing their deposit addresses. Mirrors
/// [`SwapInRec`]. NO secret at rest — every field is public (addresses / x-only key /
/// amounts / the per-swap index), so this record is safe even on the plaintext path.
/// (#114) The fleet-controlled FRESHNESS UTXO for one shard. Every dead-man exit
/// signed while this outpoint is current carries it as input 1, so BIP341
/// `Prevouts::All` binds the signature to it — spending this ONE outpoint renders
/// every exit emitted against it consensus-invalid at once. That is what stops a
/// matured, superseded exit from force-closing a live channel, at one small on-chain
/// tx per shard per period instead of one splice per channel.
///
/// NO secret at rest — a txid, a vout and an amount are all public chain data, so this
/// record is safe even on the plaintext path (same posture as [`OnchainSwapInRec`]).
#[derive(Clone, Serialize, Deserialize)]
pub struct FreshnessRec {
    /// Funding txid of the freshness output (hex, `0x`-less — as `Txid::to_string`).
    pub txid: String,
    pub vout: u32,
    /// Value in sats. Kept because the BIP341 sighash commits to the prevout's AMOUNT
    /// as well as its script, so re-deriving a signature needs it exactly.
    pub value_sats: u64,
}

#[derive(Clone, Serialize, Deserialize)]
struct OnchainSwapInRec {
    swap_id: String,
    swap_index: u32,
    seller: String,
    token: String,
    /// Output stable's smallest units per 1 BTC, decimal string (U256).
    price_per_btc: String,
    slippage_bps: u16,
    /// 32-byte BIP340 x-only refund key (hex).
    user_refund: String,
    /// Absolute refund timelock (block height).
    cltv_height: u32,
    deposit_address: String,
}
impl OnchainSwapInRec {
    fn of(s: &OnchainSwapIn) -> Self {
        Self {
            swap_id: format!("0x{}", alloy_primitives::hex::encode(s.swap_id)),
            swap_index: s.swap_index,
            seller: s.seller.to_string(),
            token: s.token.to_string(),
            price_per_btc: s.price_per_btc.to_string(),
            slippage_bps: s.slippage_bps,
            user_refund: alloy_primitives::hex::encode(s.user_refund.serialize()),
            cltv_height: s.cltv.to_consensus_u32(),
            deposit_address: s.deposit_address.to_string(),
        }
    }
    fn to_swap(&self) -> Option<OnchainSwapIn> {
        let sid = decode32(&self.swap_id)?;
        let ur = alloy_primitives::hex::decode(self.user_refund.trim_start_matches("0x")).ok()?;
        Some(OnchainSwapIn {
            swap_id: alloy_primitives::B256::from(sid),
            swap_index: self.swap_index,
            seller: Address::from_str(&self.seller).ok()?,
            token: Address::from_str(&self.token).ok()?,
            price_per_btc: U256::from_str(&self.price_per_btc).ok()?,
            slippage_bps: self.slippage_bps,
            user_refund: bitcoin::XOnlyPublicKey::from_slice(&ur).ok()?,
            cltv: bitcoin::absolute::LockTime::from_consensus(self.cltv_height),
            deposit_address: bitcoin::Address::from_str(&self.deposit_address).ok()?.assume_checked(),
        })
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Persisted {
    // The LP-fee settler's persisted dedup (`lp_fee_cursor` + `settled_lp_fees`) was
    // REMOVED with the settler — fees compound in-channel, no off-chain payout to dedup. Old
    // state files may still carry those keys; serde ignores unknown fields.
    /// Restart-durable splice CID map: LDK `channel_id` ([u8;32], hex) → the STABLE
    /// on-chain `channelId` ([u8;32], hex) keyed on the channel's ORIGINAL funding
    /// outpoint. Learned at open/`Ready`. A later `Spliced`/`Closed` event carries
    /// only the LDK channel id + the rotated outpoint, so the on-chain id cannot be
    /// recomputed from the close/splice tx — it must be recovered from here. Without
    /// durability a crash between a splice's `Ready` (prior run) and its `Spliced`
    /// loses the mapping → the splice never mirrors to EVM (capacity desync).
    /// `#[serde(default)]` so a store written before this field loads with an empty
    /// map (don't fail-closed on a missing field). Pruned on channel close.
    #[serde(default)]
    onchain_cid: HashMap<String, String>,
    /// (B) Restart-durable OPEN-orchestration map: a channel funding outpoint
    /// (`"txid:vout"`) → the `lpEth` (20-byte hex) that funded it. The vault's
    /// deposit→open orchestrator KNOWS lpEth (it derived that LP's deposit address);
    /// `drive_open` reads it to mirror `openChannel(…, lpEth)` on-chain with NO lpAuth.
    /// Without durability a crash between `create_channel` (prior run) and `drive_open`
    /// loses the binding → the LP's open is stuck until re-deposit. Pruned by
    /// `clear_inflight` once the open is mirrored, so it only ever holds IN-FLIGHT opens.
    /// `#[serde(default)]` so pre-field stores load with an empty map.
    #[serde(default)]
    funding_lp: HashMap<String, String>,
    /// In-flight SWAP-INS keyed by payment_hash. Persisted BEFORE the settle and
    /// removed only on a DEFINITE terminal outcome (claimed / failed-back), so a
    /// crash in the settle→claim window can't leave USD delivered on EVM while the
    /// BTC HTLC is never claimed (seller reclaims by timeout → USD+BTC double =
    /// hop loss). Unlike swap-OUTS, this LDK does NOT re-emit `PaymentClaimable` on
    /// restart, so THIS record is the ONLY thing that re-drives a swap-in on boot
    /// (see [`BridgeStore::inflight_swapins`]). `#[serde(default)]` so a store
    /// written before this field loads with an empty map (no fail-closed).
    #[serde(default)]
    inflight_swapins: HashMap<String, SwapInRec>,
    /// Registered on-chain (Design-A) swap-ins awaiting their deposit — re-armed on boot
    /// so a restart doesn't forget them. `#[serde(default)]` ⇒ older state files load clean.
    #[serde(default)]
    onchain_swapins: HashMap<String, OnchainSwapInRec>,
    /// (#114) `shard_id -> current freshness outpoint`. **ROTATES** every refresh period:
    /// the whole point is that spending the previous one invalidates the exits bound to it.
    /// `#[serde(default)]` ⇒ a store written before #114 loads clean and simply has no
    /// freshness UTXOs yet (exits are then emitted unbound, i.e. pre-#114 behaviour).
    #[serde(default)]
    freshness_shards: HashMap<String, FreshnessRec>,
    /// (#114) `channel_id -> shard_id`. **STABLE**: assigned once at first emission and
    /// never remapped by a change in shard COUNT — a remap would leave a channel's exits
    /// bound to its old shard's outpoint while we rotate a different one, silently lapsing
    /// the invalidation guarantee. Only a deliberate CONSOLIDATION moves a channel, and
    /// that re-emits it against the surviving shard BEFORE the drained outpoint is spent.
    #[serde(default)]
    channel_shard: HashMap<String, u32>,
}

/// Crash-durable bridge state. Cheap to `Arc`-share; every mutation persists.
pub struct BridgeStore {
    path: Option<PathBuf>,
    state: Mutex<Persisted>,
    /// Sealing key (F5) — when set, the on-disk blob is AES-encrypted under the enclave
    /// master key (so the LN preimage + fee dedup aren't cleartext on host disk). `None`
    /// ⇒ plaintext (tests, or a mode with no enclave key). Anti-ROLLBACK of the store is
    /// NOT needed: swap-in re-drive is on-chain-idempotent (`swapInUsed`) and the cid map
    /// self-heals. (The LP-fee payout — the one replay that needed a store version — was
    /// retired; fees now compound in-channel.)
    seal: Option<Arc<AesMasterKey>>,
}

impl BridgeStore {
    /// Load from `path`, or start empty if absent. `None` ⇒ in-memory (tests).
    ///
    /// FAIL-CLOSED on a corrupt/unparseable state file: losing the durable dedup
    /// would risk a double-pay or a dropped refund, so we NEVER auto-start with
    /// empty state. To aid recovery, before bailing we copy the corrupt file to a
    /// `.corrupt.bak` sibling (stable suffix, overwrite-ok — no timestamps, per the
    /// codebase's no-nondeterminism rule) and include that path in the error so an
    /// operator can inspect/recover it.
    pub fn load(path: Option<PathBuf>) -> anyhow::Result<Self> {
        Self::load_inner(path, None)
    }

    /// SEALED load (audit F5). Encrypts state at rest under `seal` (the enclave master key
    /// derived from the hop root seed — present in every hosting mode, SGX or self-hosted
    /// laptop) so the LN preimage + swap state are never cleartext on host disk. Rollback
    /// protection for the money-critical replay (the swap-in claim) lives on-chain
    /// (`swapInUsed`), not in a store version, so this path needs only the key. (The
    /// LP-fee payout that also needed on-chain rollback-proofing was retired.)
    pub fn load_sealed(path: Option<PathBuf>, seal: Arc<AesMasterKey>) -> anyhow::Result<Self> {
        Self::load_inner(path, Some(seal))
    }

    fn load_inner(path: Option<PathBuf>, seal: Option<Arc<AesMasterKey>>) -> anyhow::Result<Self> {
        let state = match &path {
            Some(p) if p.exists() => {
                let raw = fs::read(p)?;
                match Self::decode(&raw, seal.as_deref()) {
                    Ok(v) => v,
                    Err(e) => {
                        let bak = p.with_extension("corrupt.bak");
                        let bak_note = match fs::copy(p, &bak) {
                            Ok(_) => format!("preserved a copy at {}", bak.display()),
                            Err(ce) => format!(
                                "FAILED to preserve a copy at {} ({ce})",
                                bak.display()
                            ),
                        };
                        anyhow::bail!(
                            "corrupt/undecryptable bridge state file {} ({e}) — refusing to \
                             start with empty state (would risk a double-pay / lost refund); \
                             {bak_note}. Inspect/recover it, then restart.",
                            p.display()
                        );
                    }
                }
            }
            _ => Persisted::default(),
        };
        Ok(Self { path, state: Mutex::new(state), seal })
    }

    /// Decode raw file bytes → state. A SEALED blob is AES ciphertext of the JSON (binary,
    /// self-describing `version‖key_id‖ct‖tag`). When a key is present a JSON-looking blob
    /// (first non-whitespace byte `{`) is REJECTED, not silently accepted (audit F2): the
    /// seal is the integrity layer, so the host must not be able to downgrade a keyed
    /// store to unauthenticated plaintext. The plaintext path is only for the keyless
    /// (`load`) test/no-key mode.
    fn decode(raw: &[u8], seal: Option<&AesMasterKey>) -> anyhow::Result<Persisted> {
        let looks_json = raw
            .iter()
            .find(|b| !b.is_ascii_whitespace())
            .map_or(true, |b| *b == b'{');
        if let Some(key) = seal {
            if looks_json {
                anyhow::bail!(
                    "bridge store under a seal key is plaintext JSON — refusing (a sealed \
                     store must be ciphertext; the host must not downgrade it to \
                     unauthenticated plaintext)"
                );
            }
            let pt = key
                .decrypt(&[STORE_SEAL_AAD], raw.to_vec())
                .map_err(|e| anyhow::anyhow!("decrypt: {e}"))?;
            return Ok(serde_json::from_slice(&pt)?);
        }
        Ok(serde_json::from_slice(raw)?)
    }

    /// Durably persist `s`: write to a temp file in the SAME dir (so the rename is
    /// intra-filesystem and atomic), fsync it, atomically rename it over the
    /// target, then fsync the directory so the rename itself survives a crash.
    /// Without durability a "saved" dedup record can be lost to a power cut while
    /// money already moved on-chain. Uses the audited `tempfile` crate for the
    /// temp-file + atomic-persist dance rather than hand-rolling it. Returns the IO
    /// error so the caller can choose best-effort (cursor) vs fail-stop (money).
    fn save(&self, s: &Persisted) -> io::Result<()> {
        let Some(p) = &self.path else { return Ok(()) };
        let json = serde_json::to_vec(s)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        // SEAL (F5): AES-encrypt the JSON under the enclave key so the LN preimage + fee
        // dedup are never cleartext on host disk. Keyless (test) mode writes bare JSON.
        let bytes = match &self.seal {
            Some(key) => {
                let mut rng = SysRng::new();
                key.encrypt(&mut rng, &[STORE_SEAL_AAD], Some(json.len()), &|out| {
                    out.extend_from_slice(&json);
                })
            }
            None => json,
        };
        let dir = p.parent().unwrap_or_else(|| std::path::Path::new("."));
        let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
        tmp.write_all(&bytes)?;
        tmp.as_file().sync_all()?; // durably flush bytes before the rename
        // `persist` does the atomic rename onto `p`, replacing any existing file.
        tmp.persist(p).map_err(|e| e.error)?;
        // fsync the containing dir so the rename (the directory entry) is durable. Best-
        // effort, but a silent failure could leave the atomic rename non-durable across a
        // crash, so log it rather than dropping it.
        match fs::File::open(dir) {
            Ok(d) => {
                if let Err(e) = d.sync_all() {
                    warn!("dir fsync failed for {dir:?}: {e} — rename may not be crash-durable");
                }
            }
            Err(e) => warn!("could not open dir {dir:?} to fsync: {e}"),
        }
        Ok(())
    }

    /// Best-effort save for state whose loss is SAFE (re-derivable by re-scan):
    /// only the monotonic cursors. A failure is logged, not fatal — the next poll
    /// simply re-scans the same window (the durable dedup sets make that a no-op).
    fn save_cursor(&self, s: &Persisted) {
        if let Err(e) = self.save(s) {
            warn!(error = %e, "BridgeStore: cursor persist failed (will re-scan; safe)");
        }
    }

    /// Fail-stop save for MONEY-CRITICAL state (dedup marks, in-flight, reversals,
    /// LP pubkeys). If this state can't be made durable, continuing risks a
    /// double-pay or a lost refund on the next restart — strictly worse than
    /// halting. We `abort()` rather than `panic!`: a panic only unwinds the calling
    /// task while POISONING the shared state mutex, so every other task then panics
    /// on its next `.lock()` — a messy death-by-a-thousand-panics with ambiguous
    /// in-flight work. `abort()` is the honest, immediate, whole-process fail-stop
    /// the operator can act on. (M-C)
    fn save_critical(&self, s: &Persisted) {
        if let Err(e) = self.save(s) {
            error!(
                error = %e,
                "BridgeStore: FATAL — could not durably persist money-critical state. \
                 Aborting (a restart on stale state could double-pay or drop a refund). \
                 Fix storage and restart."
            );
            std::process::abort();
        }
    }

    fn key(hash: &[u8; 32]) -> String {
        format!("0x{}", alloy_primitives::hex::encode(hash))
    }

    // ── (#114) Dead-man FRESHNESS UTXOs ──────────────────────────────────────

    /// The shard's current freshness outpoint, as the `(OutPoint, TxOut)` pair the exit
    /// builder takes. `None` ⇒ no UTXO yet for this shard (emit unbound: pre-#114 form).
    pub fn freshness_of_shard(
        &self,
        shard: u32,
        script_pubkey: bitcoin::ScriptBuf,
    ) -> Option<(bitcoin::OutPoint, bitcoin::TxOut)> {
        let s = self.state.lock().unwrap();
        let r = s.freshness_shards.get(&shard.to_string())?;
        let txid: bitcoin::Txid = r.txid.parse().ok()?;
        Some((
            bitcoin::OutPoint { txid, vout: r.vout },
            bitcoin::TxOut { value: bitcoin::Amount::from_sat(r.value_sats), script_pubkey },
        ))
    }

    /// Record a shard's NEW freshness outpoint. Durable (`save_critical`): if this is lost
    /// to a crash we would re-emit against an outpoint we then fail to recognise, and the
    /// old one might be spent without its exits having been re-emitted — the one ordering
    /// that must never be violated.
    pub fn set_freshness(&self, shard: u32, txid: &bitcoin::Txid, vout: u32, value_sats: u64) {
        let mut s = self.state.lock().unwrap();
        s.freshness_shards.insert(
            shard.to_string(),
            FreshnessRec { txid: txid.to_string(), vout, value_sats },
        );
        self.save_critical(&s);
    }

    /// The channel's STABLE shard assignment, if it has one.
    pub fn shard_of_channel(&self, channel_id: &[u8; 32]) -> Option<u32> {
        self.state.lock().unwrap().channel_shard.get(&Self::key(channel_id)).copied()
    }

    /// Assign a channel to a shard. Idempotent, and **does NOT overwrite an existing
    /// assignment** — stability is the invariant that lets the shard COUNT be derived
    /// automatically without remapping anyone. Returns the assignment in force after the
    /// call, so a caller can use the result without a second read.
    pub fn assign_shard(&self, channel_id: &[u8; 32], shard: u32) -> u32 {
        let mut s = self.state.lock().unwrap();
        if let Some(existing) = s.channel_shard.get(&Self::key(channel_id)) {
            return *existing;
        }
        s.channel_shard.insert(Self::key(channel_id), shard);
        self.save_critical(&s);
        shard
    }

    /// Channels currently assigned to `shard` — the re-emission set for a rotation or a
    /// consolidation. (Both must re-emit EVERY member before the old outpoint is spent.)
    pub fn channels_in_shard(&self, shard: u32) -> Vec<String> {
        let s = self.state.lock().unwrap();
        s.channel_shard.iter().filter(|(_, v)| **v == shard).map(|(k, _)| k.clone()).collect()
    }

    /// Shards that currently hold at least one channel — `K_active`, which drives ROTATION
    /// COST. Distinct from the shard count used for NEW assignments: lowering that does not
    /// retire a populated shard, so only consolidation reduces this.
    pub fn active_shards(&self) -> Vec<u32> {
        let s = self.state.lock().unwrap();
        let mut v: Vec<u32> = s.channel_shard.values().copied().collect();
        v.sort_unstable();
        v.dedup();
        v
    }

    // ── In-flight SWAP-INS (durable settle→claim recovery) ───────────────────

    /// Persist an in-flight swap-in BEFORE its settle, keyed by payment_hash.
    /// Durable (`save_critical`): the record must hit disk before any USD moves
    /// on-chain, so a crash in the settle→claim window leaves a record the boot
    /// re-drive uses to finish the claim. Idempotent on the hash (a re-emit/replay
    /// overwrites with the same data). See the PREIMAGE-AT-REST note on `SwapInRec`.
    pub fn add_inflight_swapin(&self, c: &ClaimedSwapIn) {
        let mut s = self.state.lock().unwrap();
        s.inflight_swapins.insert(Self::key(&c.payment_hash), SwapInRec::of(c));
        self.save_critical(&s);
    }
    /// Remove an in-flight swap-in once it reaches a DEFINITE terminal outcome
    /// (claimed, or failed-back / already-settled-and-claimed). Durable so the
    /// removal survives a crash and the boot re-drive doesn't re-process a
    /// completed swap-in. Returns the record if it was present.
    pub fn take_inflight_swapin(&self, hash: &[u8; 32]) -> Option<ClaimedSwapIn> {
        let mut s = self.state.lock().unwrap();
        let r = s.inflight_swapins.remove(&Self::key(hash))?;
        self.save_critical(&s);
        r.to_claimed()
    }
    pub fn has_inflight_swapin(&self, hash: &[u8; 32]) -> bool {
        self.state.lock().unwrap().inflight_swapins.contains_key(&Self::key(hash))
    }
    /// Count of in-flight swap-ins (received → settle/claim not yet terminal) — a
    /// proxy for the time-critical hot-key work, used by the SPV relayer's H-4
    /// defer so header relay yields the shared nonce to settlement when busy.
    pub fn inflight_swapin_count(&self) -> usize {
        self.state.lock().unwrap().inflight_swapins.len()
    }
    /// All persisted in-flight swap-ins, for the boot re-drive. Each is re-fed
    /// through the same settle-then-claim path: `settle_swap_in` on an already-
    /// settled hash returns `AlreadySettled` → claim; a lapsed CLTV deadline fails
    /// back cleanly (the settle-time re-check still applies). This is the ONLY
    /// re-drive trigger for swap-ins (LDK does not re-emit `PaymentClaimable`).
    pub fn inflight_swapins(&self) -> Vec<ClaimedSwapIn> {
        self.state
            .lock()
            .unwrap()
            .inflight_swapins
            .values()
            .filter_map(SwapInRec::to_claimed)
            .collect()
    }

    /// Persist a registered on-chain swap-in (restart-durable; the boot re-load re-arms the
    /// watcher's deposit-address sweep). Idempotent on `swap_id`.
    pub fn add_onchain_swapin(&self, s: &OnchainSwapIn) {
        let mut st = self.state.lock().unwrap();
        st.onchain_swapins.insert(Self::key(&s.swap_id.0), OnchainSwapInRec::of(s));
        self.save_critical(&st);
    }
    /// Drop a registered on-chain swap-in once serviced (claimed) or expired (its refund
    /// window opened). Durable so the removal survives a crash.
    pub fn remove_onchain_swapin(&self, swap_id: &alloy_primitives::B256) {
        let mut st = self.state.lock().unwrap();
        if st.onchain_swapins.remove(&Self::key(&swap_id.0)).is_some() {
            self.save_critical(&st);
        }
    }
    /// All persisted on-chain swap-ins — the watcher sweep + boot re-load source of truth.
    pub fn onchain_swapins(&self) -> Vec<OnchainSwapIn> {
        self.state
            .lock()
            .unwrap()
            .onchain_swapins
            .values()
            .filter_map(OnchainSwapInRec::to_swap)
            .collect()
    }

    // The LP-fee settler state accessors (lp_fee_cursor / set_lp_fee_cursor /
    // lp_fee_settled / mark_lp_fee_settled) were REMOVED with the settler.

    // ── Restart-durable splice CID map ───────────────────────────────────────

    /// Load the whole persisted splice CID map into a fresh in-memory map keyed by
    /// raw bytes (the channel driver's hot path). Called once on boot to seed the
    /// in-memory map; the store is the durable backstop, the in-memory map the hot
    /// path. Entries that don't decode to 32-byte values are skipped (defensive —
    /// the durable map should only ever hold our own hex, but never panic on it).
    pub fn load_onchain_cids(&self) -> HashMap<[u8; 32], [u8; 32]> {
        let s = self.state.lock().unwrap();
        s.onchain_cid
            .iter()
            .filter_map(|(k, v)| Some((decode32(k)?, decode32(v)?)))
            .collect()
    }

    /// Read one LDK `channel_id` → on-chain `channelId` mapping (recorded by the
    /// channel driver for splice/close). `None` if the channel has not been
    /// reconciled on-chain yet. NOTE: the freshness anchor no longer uses this map —
    /// it derives the on-chain id from the sealed monitor directly (audit F3).
    pub fn onchain_cid(&self, ldk_channel_id: &[u8; 32]) -> Option<[u8; 32]> {
        let s = self.state.lock().unwrap();
        s.onchain_cid.get(&Self::key(ldk_channel_id)).and_then(|v| decode32(v))
    }
    /// Durably record an LDK channel_id → on-chain channelId mapping, learned at
    /// open/`Ready`. Idempotent: re-recording the same pair is a cheap no-op (skips
    /// the fsync) so a reconciler/event double-learn doesn't write-amplify. Money-
    /// adjacent (a lost mapping ⇒ a splice can't mirror ⇒ EVM capacity desync), so
    /// it persists via `save_critical`.
    pub fn record_onchain_cid(&self, ldk_channel_id: [u8; 32], onchain_cid: [u8; 32]) {
        let mut s = self.state.lock().unwrap();
        let k = Self::key(&ldk_channel_id);
        let v = Self::key(&onchain_cid);
        if s.onchain_cid.get(&k).map(|cur| cur == &v).unwrap_or(false) {
            return; // already recorded identically — no write
        }
        s.onchain_cid.insert(k, v);
        self.save_critical(&s);
    }
    /// Prune an LDK channel_id → on-chain channelId mapping once the channel is
    /// closed (its mirror is retired on the EVM, so the mapping is dead weight).
    /// Best-effort persistence: losing this prune only leaves a harmless stale
    /// entry that a re-close would no-op against, so a cursor-class save suffices.
    pub fn forget_onchain_cid(&self, ldk_channel_id: &[u8; 32]) {
        let mut s = self.state.lock().unwrap();
        if s.onchain_cid.remove(&Self::key(ldk_channel_id)).is_some() {
            self.save_cursor(&s);
        }
    }

    /// (B) Load the durable funding-outpoint (`"txid:vout"`) → `lpEth` bindings (vault open
    /// orchestration), so a restart re-arms every in-flight open's `drive_open`. Restart-safe.
    pub fn load_funding_lps(&self) -> HashMap<String, alloy_primitives::Address> {
        let s = self.state.lock().unwrap();
        s.funding_lp
            .iter()
            .filter_map(|(k, v)| Some((k.clone(), v.parse().ok()?)))
            .collect()
    }
    /// (B) Durably bind a channel funding outpoint → its `lpEth`. Money-adjacent (a lost binding
    /// ⇒ the open can't mirror ⇒ the LP's open is stuck), so persists via `save_critical`.
    /// Idempotent: re-recording the same pair skips the fsync.
    pub fn record_funding_lp(&self, funding_key: String, lp_eth: alloy_primitives::Address) {
        let mut s = self.state.lock().unwrap();
        let v = lp_eth.to_string();
        if s.funding_lp.get(&funding_key).map(|cur| cur == &v).unwrap_or(false) {
            return;
        }
        s.funding_lp.insert(funding_key, v);
        self.save_critical(&s);
    }
    /// (B) Prune a funding→lpEth binding once its open is mirrored on-chain — keeps the map to
    /// IN-FLIGHT opens only. Best-effort (a lost prune leaves a harmless stale entry).
    pub fn forget_funding_lp(&self, funding_key: &str) {
        let mut s = self.state.lock().unwrap();
        if s.funding_lp.remove(funding_key).is_some() {
            self.save_cursor(&s);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // lp_fee_event_block_parses + settled_lp_fees_pruned_below_cursor REMOVED with the settler.

    #[test]
    fn onchain_cid_map_roundtrips_through_save_load() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("quid-bridge-cidmap-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        let ldk_a = [0xAAu8; 32];
        let oc_a = [0x11u8; 32];
        let ldk_b = [0xBBu8; 32];
        let oc_b = [0x22u8; 32];
        {
            let s = BridgeStore::load(Some(path.clone())).unwrap();
            s.record_onchain_cid(ldk_a, oc_a);
            s.record_onchain_cid(ldk_b, oc_b);
            // Idempotent re-record is a no-op (no crash, no duplicate).
            s.record_onchain_cid(ldk_a, oc_a);
        }
        // Fresh load (simulates a restart) sees both mappings.
        let s2 = BridgeStore::load(Some(path.clone())).unwrap();
        let m = s2.load_onchain_cids();
        assert_eq!(m.get(&ldk_a), Some(&oc_a), "mapping A survives restart");
        assert_eq!(m.get(&ldk_b), Some(&oc_b), "mapping B survives restart");
        // Close prunes the mapping durably.
        s2.forget_onchain_cid(&ldk_a);
        let s3 = BridgeStore::load(Some(path.clone())).unwrap();
        let m3 = s3.load_onchain_cids();
        assert!(m3.get(&ldk_a).is_none(), "closed channel's mapping pruned");
        assert_eq!(m3.get(&ldk_b), Some(&oc_b), "other mapping retained");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn store_without_onchain_cid_field_loads_empty() {
        // Migration: a store file written BEFORE the onchain_cid field was added
        // (and one carrying the now-REMOVED off-chain LN swap-out fields) must load
        // cleanly with an empty cid map (serde(default) + ignore-unknown), not
        // fail-closed.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("quid-bridge-migrate-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        // An old-format state file with NO `onchain_cid` key and the legacy
        // (now-ignored) LN swap-out fields.
        fs::write(&path, br#"{"swap_out_cursor":42,"inflight":{},"pending_reversals":{},"lp_fee_cursor":7}"#).unwrap();
        let s = BridgeStore::load(Some(path.clone())).unwrap();
        // the legacy `lp_fee_cursor` key is now unknown → serde ignores it (loads fine).
        assert!(s.load_onchain_cids().is_empty(), "missing field → empty map (no fail-closed)");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn persists_and_reloads_from_disk() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("quid-bridge-store-test-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        {
            let s = BridgeStore::load(Some(path.clone())).unwrap();
            s.record_onchain_cid([0xAB; 32], [0xCD; 32]);
        }
        // Fresh load sees the persisted state.
        let s2 = BridgeStore::load(Some(path.clone())).unwrap();
        assert!(!s2.load_onchain_cids().is_empty(), "persisted onchain-cid map survives reload");
        let _ = fs::remove_file(&path);
    }

    // ── F5: sealing at rest (real AesMasterKey, no mocks) ──

    fn seal_key(b: u8) -> Arc<AesMasterKey> {
        Arc::new(AesMasterKey::new(&[b; 32]))
    }

    #[test]
    fn sealed_store_hides_plaintext_and_roundtrips() {
        // F5: the on-disk blob must be ciphertext (no cleartext preimage / fee id), and a
        // sealed reload must decrypt + recover the state.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("quid-bridge-sealed-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        let key = seal_key(7);
        {
            let s = BridgeStore::load_sealed(Some(path.clone()), key.clone()).unwrap();
            s.record_onchain_cid([0xDE; 32], [0xAD; 32]);
        }
        let raw = fs::read(&path).unwrap();
        assert_ne!(raw.first(), Some(&b'{'), "sealed store must not be plaintext JSON");
        assert!(
            std::str::from_utf8(&raw).map_or(true, |t| !t.contains(&"de".repeat(32))),
            "the persisted cid must not appear in cleartext on disk"
        );
        let s2 = BridgeStore::load_sealed(Some(path.clone()), key).unwrap();
        assert!(!s2.load_onchain_cids().is_empty(), "sealed state survives a restart");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn sealed_load_rejects_plaintext_downgrade() {
        // F2: under a seal key, a plaintext (unauthenticated) blob the host wrote must be
        // REFUSED — the seal is the integrity layer; no silent downgrade to plaintext.
        let dir = std::env::temp_dir();
        let path = dir.join(format!("quid-bridge-downgrade-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        fs::write(&path, br#"{"swap_out_cursor":7}"#).unwrap();
        let refused = matches!(BridgeStore::load_sealed(Some(path.clone()), seal_key(3)), Err(_));
        assert!(refused, "a plaintext store under a seal key must be refused (no downgrade)");
        let _ = fs::remove_file(&path);
    }
}
