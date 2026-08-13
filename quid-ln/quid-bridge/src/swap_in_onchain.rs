//! On-chain (non-LN) swap-in driver — **Design A** settle-then-claim over a plain
//! Bitcoin deposit. The counterpart to `swap_in.rs` (the LN rail) and a sibling of
//! `swap_out_onchain.rs`: where the LN rail is triggered by a settled inbound HTLC, this
//! rail is triggered by a confirmed deposit to the per-swap taproot address built in
//! [`quid_hop::swap_in_onchain`].
//!
//! ## The settle-then-claim contract (identical safety posture to the LN rail)
//!
//! Once the deposit buries under N confs, the hop:
//!   1. **CLTV-HEADROOM GATE** — refuses to settle unless the user's refund timelock is
//!      still far enough out that the hop can settle *and* bury a key-path claim before
//!      the refund could unlock. This is the on-chain analogue of `swap_in.rs`'s
//!      settle-time CLTV re-check; it fails **safe** (defer/skip → the user refunds), so
//!      the hop never delivers USD for BTC it can no longer claim in time.
//!   2. **SETTLE against the deposit the CONTRACT reads out of the transaction**, via
//!      `settleSwapInProven` — the hop supplies the tx and its SPV inclusion proof, and the
//!      contract derives the sats itself from the output paying the address it recomputes
//!      from the pinned `BTC_DEPOSIT_KEY` and this swap's CLTV leaf. **(T1-c)** This rail
//!      used to call `settleSwapIn` and assert the amount, which was the phantom-swap-in
//!      trapdoor sitting on the one rail where a provable transaction exists. The dedup key
//!      moved with it: from the hop-invented `swapId` to the deposit **txid** — *a txid is a
//!      fact* — so a re-drive is still idempotent (`AlreadySettled`).
//!   3. On `Delivered`/`AlreadySettled` → **CLAIM** the deposit by key path (the hop's
//!      unilateral BIP340 sig). On `Undeliverable` → do nothing: the hop delivered no
//!      USD, so it takes no BTC, and the user reclaims via the CLTV refund leaf.
//!
//! This module owns the PURE driver core (the outcome→action mapping, the headroom gate,
//! the actual-sats floor). The production watcher that scans esplora for the deposit,
//! signs the key-path claim with the hop wallet, and broadcasts it is wired on top
//! (Increment 3), mirroring `swap_out_onchain.rs`.

use alloy_primitives::{Address, B256, U256};
use bitcoin::{Amount, OutPoint, ScriptBuf};

use crate::evm::{ProvenSwapInSettler, SettleOutcome};
use quid_hop::evm_codec::{tx_inclusion, txid_internal, TxInclusion};
use quid_hop::swap::swap_in_floor_usd;

/// Minimum CLTV headroom (blocks) between the current tip and the user's refund
/// timelock that the hop INSISTS on before settling. Must cover: the settle round-trip,
/// broadcasting the key-path claim, and enough confirmations that a reorg can't later
/// admit the user's refund of an already-claimed deposit. Set equal to the LN rail's
/// headroom (`SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS`, ~12h) — the on-chain claim is a single
/// tx, so this is comfortably conservative.
pub const ONCHAIN_SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS: u32 =
    quid_hop::event_handler::SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS;

/// The refund window (blocks) baked into a NEW deposit's CLTV at registration (`tip + this`).
/// Comfortably above the settle-time headroom gate so a fresh deposit always has room to
/// settle + claim before the sender's refund could unlock.
pub const SWAP_IN_CLTV_WINDOW_BLOCKS: u32 = 288; // ~2 days at 10-min blocks (> 72 headroom)

/// A registered on-chain swap-in, created when the hop quotes a seller and hands back a
/// deposit address. Everything needed to (a) match a confirmed deposit and (b) rebuild
/// the taproot spend-info for the key-path claim (via `quid_hop::swap_in_onchain`).
#[derive(Clone, Debug)]
pub struct OnchainSwapIn {
    /// The swap nonce — also the `settleSwapIn` payment-hash / on-chain dedup key.
    pub swap_id: B256,
    /// BIP32 child index of the per-swap deposit key (`m/70'/swap_index'`) — lets the
    /// watcher re-derive the hop key for the key-path claim from the master alone.
    pub swap_index: u32,
    /// EVM recipient of the delivered USD (the seller).
    pub seller: Address,
    /// Output stable the USD is delivered in.
    pub token: Address,
    /// The hop's quote: output stable's smallest units per 1 BTC (e.g. USDC 6-dec).
    pub price_per_btc: U256,
    /// Slippage tolerance (bps) below the quote the settle floor allows.
    pub slippage_bps: u16,
    /// The user's refund key (x-only) — the CLTV leaf's `OP_CHECKSIG` key.
    pub user_refund: bitcoin::XOnlyPublicKey,
    /// The refund timelock (absolute height) the deposit leaf enforces.
    pub cltv: bitcoin::absolute::LockTime,
    /// The deposit address the user was told to pay (for matching a scanned UTXO).
    pub deposit_address: bitcoin::Address,
}

/// A deposit the watcher found buried under the required confs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConfirmedDeposit {
    pub outpoint: OutPoint,
    pub value: Amount,
}

/// The action a definite settle outcome maps to — the pure core of settle-then-claim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnchainAction {
    /// USD is on-chain (delivered now or by a prior settle) → take the BTC by key path, but
    /// REFUND `refund_sats` of the deposit back to the user's CLTV-leaf key (0 = take it all).
    /// `refund_sats` = deposited − converted: on an inventory-bounded partial the pool converted
    /// only part of the deposit, so the hop returns the unconverted remainder rather than keeping
    /// BTC it delivered no USD for. The watcher builds the key-path claim with this second output.
    Claim { refund_sats: u64 },
    /// The pool couldn't deliver → take NO BTC; the user reclaims via the CLTV refund.
    DropToRefund,
}

/// Map a settle outcome + the deposited amount to its action (same disposition as
/// `swap_in::outcome_action`). A delivered/already-settled outcome CLAIMS, refunding the
/// `actual_sats − consumed_sats` remainder the pool couldn't convert.
pub fn outcome_action(outcome: SettleOutcome, actual_sats: u64) -> OnchainAction {
    match outcome {
        SettleOutcome::Delivered { consumed_sats }
        | SettleOutcome::AlreadySettled { consumed_sats } => {
            OnchainAction::Claim { refund_sats: actual_sats.saturating_sub(consumed_sats) }
        }
        SettleOutcome::Undeliverable => OnchainAction::DropToRefund,
    }
}

/// The CLTV-headroom gate: is the refund timelock still far enough above the tip to
/// settle+claim safely? Fails **safe** — a refund height at/below `tip + headroom`
/// returns `false`, and a height-vs-height comparison that would underflow returns
/// `false` too (never settle when the math is degenerate). Non-height (time-based)
/// locktimes are rejected: the deposit leaf is always a height CLTV.
pub fn cltv_headroom_ok(cltv: bitcoin::absolute::LockTime, best_height: u32) -> bool {
    use bitcoin::absolute::LockTime;
    match cltv {
        LockTime::Blocks(h) => h
            .to_consensus_u32()
            .checked_sub(best_height)
            .map(|slack| slack >= ONCHAIN_SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS)
            .unwrap_or(false),
        LockTime::Seconds(_) => false,
    }
}

/// The settle floor for a deposit of `actual_sats`, at the hop's stored quote. Computed
/// from the ACTUAL deposited amount, not the quote — so the USD delivered tracks the BTC
/// received (under-payment ⇒ less USD, never free USD).
pub fn settle_floor(swap: &OnchainSwapIn, actual_sats: u64) -> U256 {
    swap_in_floor_usd(actual_sats, swap.price_per_btc, swap.slippage_bps)
}

/// Decide what to do with a confirmed deposit: the headroom gate + the settle, returning
/// the resulting action (or `None` if the gate deferred). The ONLY effect is the injected
/// `evm.settle_swap_in_proven`; the caller performs the follow-on effect the action names
/// (the async key-path CLAIM lives in the watcher). Splitting the decision from the claim
/// keeps this core sync + unit-testable AND lets the watcher `await` the broadcast.
///
///   1. CLTV-headroom gate — fail-safe: too little room ⇒ do NOT settle (the user refunds
///      via the leaf); never deliver USD we can't claim in time.
///   2. SETTLE against the ACTUAL deposited sats + the actual-sats floor. A transient EVM
///      error surfaces as `Err` — safe to retry, nothing irreversible has happened (the
///      claim only runs AFTER a definite delivered outcome).
///
/// 🔑 **(T1-c) THIS RAIL NOW PROVES ITS DEPOSIT INSTEAD OF ASSERTING IT.** It used to call
/// `settleSwapIn`, handing the contract a hop-chosen `sats` and a hop-chosen dedup key on the
/// one rail where a real Bitcoin transaction to prove *exists*. `settleSwapInProven` was
/// built for exactly this in §E159 and the daemon was simply never repointed. The contract
/// now derives the sats from `inclusion.raw` and dedups on the deposit txid.
///
/// ⚠️ `inclusion` is a PARAMETER rather than something fetched here on purpose: fetching is
/// async and esplora-bound, and doing it inline would dissolve the sync/unit-testable split
/// this function's whole shape exists to preserve.
pub fn decide_deposit<E: ProvenSwapInSettler>(
    evm: &E,
    swap: &OnchainSwapIn,
    deposit: &ConfirmedDeposit,
    best_height: u32,
    inclusion: &TxInclusion,
) -> anyhow::Result<Option<OnchainAction>> {
    if !cltv_headroom_ok(swap.cltv, best_height) {
        return Ok(None);
    }
    let actual_sats = deposit.value.to_sat();
    let floor = settle_floor(swap, actual_sats);
    // No `require_full` to pass: the proven entrypoint ALWAYS accepts an inventory-bounded
    // partial, and this rail always wanted that — it refunds the unconverted remainder via the
    // claim's second output (see `broadcast_claim`), because it has a refund path (the
    // deposit's CLTV leaf) that the atomic LN rail does not.
    // The contract rebuilds the deposit leaf from a BLOCK HEIGHT, so only a height can name
    // an address the hop can spend from. `cltv_headroom_ok` above already returns false for a
    // time-based lock, so this cannot fire — it is written as that gate's SAME fail-safe
    // (defer, let the user refund) rather than a second, divergent policy.
    let bitcoin::absolute::LockTime::Blocks(cltv_blocks) = swap.cltv else {
        return Ok(None);
    };
    let cltv_height = cltv_blocks.to_consensus_u32();
    let outcome = evm.settle_swap_in_proven(
        swap.seller,
        swap.token,
        floor,
        swap.user_refund.serialize(),
        cltv_height,
        inclusion,
        // INTERNAL byte order, not display order: the contract's key is
        // `sha256(sha256(rawLegacy))` verbatim, so a reversed txid would gate on a slot
        // nothing ever writes and report every settle as unconfirmed.
        B256::from(txid_internal(&deposit.outpoint.txid)),
        actual_sats,
    )?;
    Ok(Some(outcome_action(outcome, actual_sats)))
}

/// A single output an esplora address-scan surfaced, mapped from `esplora_client::Tx` so
/// this selection core stays decoupled from the client type (and unit-testable).
/// `block_height` is `None` while the tx is unconfirmed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScannedOutput {
    pub outpoint: OutPoint,
    pub value: Amount,
    pub spk: ScriptBuf,
    pub block_height: Option<u32>,
}

/// Pick the ONE deposit to settle from an address scan: the output paying `deposit_spk`
/// that is buried ≥ `min_confs`, deterministic tie-break by (height, txid, vout). At most
/// one is returned even if the address was paid multiple times — the watcher settles a
/// `swapId` once, so a user who double-pays the one-shot address reclaims the extra via
/// the CLTV refund rather than the hop taking both deposits for a single USD delivery.
/// The scan is UNTRUSTED input (any output can pay the address): unconfirmed, shallow,
/// wrong-address, and zero-value outputs are all filtered out; the conf math never
/// underflows (a reported height above the tip ⇒ not buried, not a panic).
pub fn find_confirmed_deposit(
    outs: &[ScannedOutput],
    deposit_spk: &bitcoin::Script,
    tip: u32,
    min_confs: u32,
) -> Option<ConfirmedDeposit> {
    let mut cands: Vec<&ScannedOutput> = outs
        .iter()
        .filter(|o| o.spk.as_script() == deposit_spk && o.value > Amount::ZERO)
        .filter(|o| match o.block_height {
            Some(h) => tip.checked_sub(h).map(|d| d + 1 >= min_confs).unwrap_or(false),
            None => false,
        })
        .collect();
    cands.sort_by_key(|o| (o.block_height.unwrap_or(u32::MAX), o.outpoint.txid, o.outpoint.vout));
    cands
        .first()
        .map(|o| ConfirmedDeposit { outpoint: o.outpoint, value: o.value })
}

// ═══════════════════ the production watcher (esplora scan → settle → key-path claim) ═══════════════════

use std::sync::Arc;

use anyhow::Context as _;
use bitcoin::bip32::Xpriv;
use bitcoin::secp256k1::Secp256k1;
use tracing::{info, warn};

use crate::config::BridgeConfig;
use quid_hop::swap_in_onchain::{build_claim_tx_with_refund, sign_claim};
use quid_ln::esplora::Esplora;

/// Registry of pending on-chain swap-ins — a thin DURABLE view over `BridgeStore`: the
/// registration API inserts, the unified watcher snapshots + removes, and every mutation is
/// persisted (fsync'd), so a restart re-arms the deposit sweep. No in-memory cache — the
/// store IS the source of truth (mirrors the inflight-swap-in pattern), which also makes
/// the swap-index counter restart-safe via [`Self::next_index_seed`].
pub struct SwapInRegistry {
    store: Arc<crate::store::BridgeStore>,
}

impl SwapInRegistry {
    pub fn new(store: Arc<crate::store::BridgeStore>) -> Arc<Self> {
        Arc::new(Self { store })
    }
    /// Insert a freshly-quoted swap-in (from the registration API); persisted immediately.
    pub fn register(&self, swap: OnchainSwapIn) {
        self.store.add_onchain_swapin(&swap);
    }
    /// A snapshot to iterate without holding a lock across `await` points.
    pub fn snapshot(&self) -> Vec<OnchainSwapIn> {
        self.store.onchain_swapins()
    }
    pub fn remove(&self, swap_id: &B256) {
        self.store.remove_onchain_swapin(swap_id);
    }
    pub fn len(&self) -> usize {
        self.store.onchain_swapins().len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// Next per-swap index seed = max persisted index + 1 (0 if none) — restart-safe, so a
    /// reboot never reuses an index (⇒ never a reused deposit address / swap_id).
    pub fn next_index_seed(&self) -> u32 {
        self.store.onchain_swapins().iter().map(|s| s.swap_index).max().map_or(0, |m| m + 1)
    }
}

/// Sign + broadcast the hop's key-path claim of a confirmed deposit. Deterministic, so a
/// retry rebuilds the SAME tx (a re-broadcast of an already-mined claim is a harmless
/// no-op). Re-derives the per-swap key from `master` via [`sign_claim`] — no stored secret.
///
/// `refund_sats` (= deposited − converted) is the inventory-bounded partial remainder the
/// pool couldn't convert to USD; when > 0 the claim gets a SECOND output paying it back to
/// the seller's refund key (a P2TR output), so the hop never keeps BTC it delivered no USD
/// for. A dust-sized remainder can't fund an economical output, so it's taken with the
/// deposit (the seller's loss is ≤ the dust limit) and logged.
async fn broadcast_claim(
    esplora: &Esplora,
    master: &Xpriv,
    swap: &OnchainSwapIn,
    deposit: &ConfirmedDeposit,
    dest_spk: ScriptBuf,
    fee: Amount,
    refund_sats: u64,
) -> anyhow::Result<()> {
    let secp = Secp256k1::new();
    let deposit_txout = bitcoin::TxOut {
        value: deposit.value,
        script_pubkey: swap.deposit_address.script_pubkey(),
    };
    // Build the refund output (P2TR to the seller's refund key), unless the remainder is
    // zero or dust — then take the whole deposit.
    let refund = if refund_sats == 0 {
        None
    } else {
        let refund_spk = ScriptBuf::new_p2tr(&secp, swap.user_refund, None);
        let amt = Amount::from_sat(refund_sats);
        if amt < refund_spk.minimal_non_dust() {
            warn!(
                swap_id = %swap.swap_id, refund_sats,
                "on-chain swap-in: partial remainder below dust — taking the whole deposit"
            );
            None
        } else {
            Some(bitcoin::TxOut { value: amt, script_pubkey: refund_spk })
        }
    };
    let claim = build_claim_tx_with_refund(deposit.outpoint, deposit.value, fee, dest_spk, refund);
    let signed = sign_claim(
        &secp, master, swap.user_refund, swap.cltv, claim, &deposit_txout,
    )
    .map_err(|e| anyhow::anyhow!("sign claim: {e:?}"))?;
    esplora.client().broadcast(&signed).await.context("broadcast key-path claim")?;
    Ok(())
}

/// One settle-then-claim SWEEP over the registered on-chain swap-ins — scan each deposit
/// address and, on a buried deposit, `decide_deposit` → async key-path claim. Folded into
/// the unified on-chain watcher (`swap_out_onchain::run_swap_out_onchain_watcher`) and
/// called once per pass, so the two on-chain rails share ONE task + timer + esplora client
/// (no second polling task). Reads the BTC tip once, then delegates each swap.
pub async fn drive_swap_in_pass<E: ProvenSwapInSettler>(
    cfg: &BridgeConfig,
    evm: &Arc<E>,
    esplora: &Arc<Esplora>,
    master: &Xpriv,
    registry: &SwapInRegistry,
    claim_dest: &ScriptBuf,
) {
    let tip = match esplora.client().get_height().await {
        Ok(t) => t,
        Err(e) => {
            warn!(error = %e, "on-chain swap-in pass: BTC tip fetch failed (retry next pass)");
            return;
        }
    };
    // A 1-in/1-out P2TR key-path claim is ~111 vB; price it at the ~6-block feerate.
    let fee = Amount::from_sat(
        esplora.fee_estimates().num_blocks_to_feerate(6).to_sat_per_vb_ceil().saturating_mul(111),
    );
    for swap in registry.snapshot() {
        drive_one_swap_in(cfg, &**evm, esplora, master, registry, claim_dest, &swap, tip, fee).await;
    }
}

/// One registered swap-in's settle-then-claim step (own frame — a `return` skips just this
/// swap, never the whole sweep). `claim_dest` is the hop scriptPubKey the claimed BTC lands on.
#[allow(clippy::too_many_arguments)]
async fn drive_one_swap_in<E: ProvenSwapInSettler>(
    cfg: &BridgeConfig,
    evm: &E,
    esplora: &Esplora,
    master: &Xpriv,
    registry: &SwapInRegistry,
    claim_dest: &ScriptBuf,
    swap: &OnchainSwapIn,
    tip: u32,
    fee: Amount,
) {
    // Prune once the refund window opens — the hop no longer claims (the user reclaims via
    // the CLTV leaf), so stop tracking it.
    if let bitcoin::absolute::LockTime::Blocks(h) = swap.cltv {
        if tip >= h.to_consensus_u32() {
            registry.remove(&swap.swap_id);
            return;
        }
    }
    let spk = swap.deposit_address.script_pubkey();
    let txs = match esplora.client().scripthash_txs(spk.as_script(), None).await {
        Ok(t) => t,
        Err(e) => {
            warn!(error = %e, "on-chain swap-in: address scan failed (retry next pass)");
            return;
        }
    };
    let mut scan = Vec::new();
    for tx in &txs {
        for (vout, o) in tx.vout.iter().enumerate() {
            scan.push(ScannedOutput {
                outpoint: OutPoint { txid: tx.txid, vout: vout as u32 },
                value: Amount::from_sat(o.value),
                spk: o.scriptpubkey.clone(),
                block_height: tx.status.block_height,
            });
        }
    }
    let min_confs = cfg.min_confirmations as u32;
    let Some(deposit) = find_confirmed_deposit(&scan, spk.as_script(), tip, min_confs) else {
        return;
    };
    // (T1-c) The inclusion proof the contract will verify. Fetched HERE, not inside
    // `decide_deposit`, so that core stays sync and unit-testable. A failure is transient
    // (esplora), so return and retry next pass — never settle without the proof, which is
    // the whole point of the proven rail.
    let inclusion = match tx_inclusion(esplora, &deposit.outpoint.txid).await {
        Ok(i) => i,
        Err(e) => {
            warn!(error = %e, "on-chain swap-in: inclusion proof unavailable (retry next pass)");
            return;
        }
    };
    match decide_deposit(evm, swap, &deposit, tip, &inclusion) {
        Ok(Some(OnchainAction::Claim { refund_sats })) => {
            match broadcast_claim(esplora, master, swap, &deposit, claim_dest.clone(), fee, refund_sats).await {
                Ok(()) => {
                    info!(swap_id = %swap.swap_id, sats = deposit.value.to_sat(), refund_sats, "on-chain swap-in: settled + claimed");
                    registry.remove(&swap.swap_id);
                }
                Err(e) => warn!(swap_id = %swap.swap_id, "on-chain swap-in: claim broadcast failed (retry next pass): {e:#}"),
            }
        }
        // Undeliverable now — leave registered to retry until the pool can deliver, or the
        // CLTV opens (pruned above; the user then refunds).
        // ⚠️ (T1-c) THIS OUTCOME HAS A NEW CAUSE AND IT IS NOT A DRY POOL: the contract
        // re-checks inclusion against the SPV GATEWAY's height, not esplora's, so a gateway
        // still catching up on headers reverts a settle for a deposit that is genuinely
        // 6-deep. It lands here, which is the safe direction (no USD delivered ⇒ no BTC
        // taken) and retries next pass — but do not read a run of these as insolvency
        // without checking the relayer first.
        Ok(Some(OnchainAction::DropToRefund)) => {}
        // Headroom defer — retry next pass.
        Ok(None) => {}
        Err(e) => warn!(swap_id = %swap.swap_id, "on-chain swap-in: settle failed (retry next pass): {e:#}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::absolute::LockTime;
    use bitcoin::secp256k1::{Secp256k1, SecretKey};
    use std::cell::Cell;

    fn xonly(b: u8) -> bitcoin::XOnlyPublicKey {
        let secp = Secp256k1::new();
        let kp = bitcoin::secp256k1::Keypair::from_secret_key(
            &secp,
            &SecretKey::from_slice(&[b; 32]).unwrap(),
        );
        kp.x_only_public_key().0
    }

    fn a_swap(cltv_height: u32) -> OnchainSwapIn {
        let secp = Secp256k1::new();
        let (hop, usr) = (xonly(0x22), xonly(0x33));
        let (si, _leaf) = quid_hop::swap_in_onchain::deposit_spend_info(
            &secp,
            hop,
            usr,
            LockTime::from_height(cltv_height).unwrap(),
        )
        .unwrap();
        OnchainSwapIn {
            swap_id: B256::repeat_byte(0xAB),
            swap_index: 0,
            seller: Address::repeat_byte(0x11),
            token: Address::repeat_byte(0x22),
            price_per_btc: U256::from(50_000u64) * U256::from(1_000_000u64), // $50k, USDC 6-dec
            slippage_bps: 100,
            user_refund: usr,
            cltv: LockTime::from_height(cltv_height).unwrap(),
            deposit_address: quid_hop::swap_in_onchain::deposit_address(
                &si,
                bitcoin::Network::Regtest,
            ),
        }
    }

    fn a_deposit(sats: u64) -> ConfirmedDeposit {
        ConfirmedDeposit {
            outpoint: OutPoint {
                txid: bitcoin::Txid::from_raw_hash(
                    bitcoin::hashes::Hash::from_byte_array([0x11; 32]),
                ),
                vout: 0,
            },
            value: Amount::from_sat(sats),
        }
    }

    /// Test EVM that returns a fixed outcome and records the sats/floor it was settled with.
    struct FakeEvm {
        outcome: SettleOutcome,
        seen_sats: Cell<u64>,
        seen_floor: Cell<U256>,
        calls: Cell<u32>,
        seen_txid: Cell<B256>,
    }
    impl FakeEvm {
        fn new(outcome: SettleOutcome) -> Self {
            Self {
                outcome,
                seen_sats: Cell::new(0),
                seen_floor: Cell::new(U256::ZERO),
                calls: Cell::new(0),
                seen_txid: Cell::new(B256::ZERO),
            }
        }
    }
    // Cell isn't Sync; the driver core is single-threaded, so a thin unsafe Sync shim keeps
    // the trait bound satisfied for the test only.
    unsafe impl Sync for FakeEvm {}
    impl ProvenSwapInSettler for FakeEvm {
        fn settle_swap_in_proven(
            &self,
            _seller: Address,
            _token: Address,
            min_delivered_usd: U256,
            _user_refund: [u8; 32],
            _cltv_height: u32,
            _inclusion: &TxInclusion,
            deposit_txid: B256,
            deposited_sats: u64,
        ) -> anyhow::Result<SettleOutcome> {
            self.calls.set(self.calls.get() + 1);
            self.seen_sats.set(deposited_sats);
            self.seen_floor.set(min_delivered_usd);
            self.seen_txid.set(deposit_txid);
            Ok(self.outcome)
        }
    }

    /// An inclusion proof stands in for a real one here: `decide_deposit` passes it straight
    /// through without inspecting it (the CONTRACT is what verifies it), so its contents are
    /// not what these tests are about.
    fn an_inclusion() -> TxInclusion {
        TxInclusion {
            raw: vec![0x01, 0x02, 0x03],
            block_hash_be: [0xBB; 32],
            height: 700_001,
            tx_index: 3,
            merkle_proof: vec![[0xCC; 32]],
        }
    }

    #[test]
    fn delivered_settles_actual_sats_and_decides_claim() {
        let swap = a_swap(800_000);
        let deposit = a_deposit(40_000_000); // 0.4 BTC — LESS than a nominal 0.5 quote
        // Full fill: the pool converted the whole 0.4 BTC ⇒ no refund remainder.
        let evm = FakeEvm::new(SettleOutcome::Delivered { consumed_sats: 40_000_000 });
        let act = decide_deposit(&evm, &swap, &deposit, 700_000, &an_inclusion()).unwrap(); // tip far below cltv → ample headroom
        assert_eq!(act, Some(OnchainAction::Claim { refund_sats: 0 }), "full fill ⇒ take the whole deposit");
        // settled against the ACTUAL 0.4 BTC, not a quote — floor = 0.4*50k*(1-1%) = $19,800.
        assert_eq!(evm.seen_sats.get(), 40_000_000);
        assert_eq!(evm.seen_floor.get(), U256::from(19_800u64) * U256::from(1_000_000u64));
    }

    /// (T1-c) The property the repoint exists for: the replay key the caller gates on is the
    /// DEPOSIT TXID in internal byte order, never the hop-invented `swap_id`. Getting this
    /// wrong is silent in the worst way — the settle lands on-chain, the gate reads a slot
    /// nothing ever writes, and every settle reports as unconfirmed forever. Both halves are
    /// asserted, because equality with the txid alone would still pass if the two collided.
    #[test]
    fn the_replay_key_is_the_deposit_txid_not_the_swap_id() {
        let swap = a_swap(800_000);
        let deposit = a_deposit(40_000_000);
        let evm = FakeEvm::new(SettleOutcome::Delivered { consumed_sats: 40_000_000 });
        decide_deposit(&evm, &swap, &deposit, 700_000, &an_inclusion()).unwrap();
        assert_eq!(
            evm.seen_txid.get(),
            B256::from(txid_internal(&deposit.outpoint.txid)),
            "must gate on the txid the contract itself computes"
        );
        assert_ne!(evm.seen_txid.get(), swap.swap_id, "the hop-invented id is not the key");
    }

    #[test]
    fn partial_fill_refunds_the_unconverted_remainder() {
        // Inventory-bounded partial: the pool converted only 30M of the 50M deposited, so the
        // hop claims but REFUNDS the 20M remainder it delivered no USD for.
        let swap = a_swap(800_000);
        let deposit = a_deposit(50_000_000);
        let evm = FakeEvm::new(SettleOutcome::Delivered { consumed_sats: 30_000_000 });
        let act = decide_deposit(&evm, &swap, &deposit, 700_000, &an_inclusion()).unwrap();
        assert_eq!(act, Some(OnchainAction::Claim { refund_sats: 20_000_000 }), "refund = deposited − converted");
    }

    #[test]
    fn outcome_action_maps_partial_and_full() {
        // Pure mapping: refund = actual − consumed (saturating), for both claim-worthy outcomes.
        assert_eq!(
            outcome_action(SettleOutcome::Delivered { consumed_sats: 30_000_000 }, 50_000_000),
            OnchainAction::Claim { refund_sats: 20_000_000 }
        );
        assert_eq!(
            outcome_action(SettleOutcome::AlreadySettled { consumed_sats: 30_000_000 }, 50_000_000),
            OnchainAction::Claim { refund_sats: 20_000_000 }
        );
        assert_eq!(
            outcome_action(SettleOutcome::Delivered { consumed_sats: 50_000_000 }, 50_000_000),
            OnchainAction::Claim { refund_sats: 0 }
        );
        assert_eq!(
            outcome_action(SettleOutcome::Undeliverable, 50_000_000),
            OnchainAction::DropToRefund
        );
    }

    #[test]
    fn undeliverable_decides_refund() {
        let swap = a_swap(800_000);
        let deposit = a_deposit(50_000_000);
        let evm = FakeEvm::new(SettleOutcome::Undeliverable);
        let act = decide_deposit(&evm, &swap, &deposit, 700_000, &an_inclusion()).unwrap();
        assert_eq!(act, Some(OnchainAction::DropToRefund), "undeliverable ⇒ no BTC; user refunds via CLTV");
    }

    #[test]
    fn already_settled_decides_claim() {
        let swap = a_swap(800_000);
        let deposit = a_deposit(50_000_000);
        let evm = FakeEvm::new(SettleOutcome::AlreadySettled { consumed_sats: 50_000_000 });
        let act = decide_deposit(&evm, &swap, &deposit, 700_000, &an_inclusion()).unwrap();
        assert_eq!(act, Some(OnchainAction::Claim { refund_sats: 0 }), "re-drive of an already-delivered full swap still takes the BTC");
    }

    #[test]
    fn headroom_gate_defers_and_never_settles() {
        let swap = a_swap(800_000);
        let deposit = a_deposit(50_000_000);
        let evm = FakeEvm::new(SettleOutcome::Delivered { consumed_sats: 50_000_000 });
        // tip only 10 blocks below cltv — far under the required headroom.
        let act = decide_deposit(&evm, &swap, &deposit, 799_990, &an_inclusion()).unwrap();
        assert_eq!(act, None, "insufficient CLTV headroom ⇒ defer");
        assert_eq!(evm.calls.get(), 0, "MUST NOT settle when it can't claim in time (fail-safe)");
    }

    #[test]
    fn headroom_boundary() {
        let h = ONCHAIN_SWAP_IN_MIN_CLTV_HEADROOM_BLOCKS;
        let cltv = LockTime::from_height(800_000).unwrap();
        assert!(cltv_headroom_ok(cltv, 800_000 - h), "exactly headroom blocks away ⇒ ok");
        assert!(!cltv_headroom_ok(cltv, 800_000 - h + 1), "one short ⇒ not ok");
        assert!(!cltv_headroom_ok(cltv, 800_001), "tip past cltv ⇒ not ok (no underflow)");
        assert!(!cltv_headroom_ok(LockTime::from_time(1_700_000_000).unwrap(), 1), "time-based locktime rejected");
    }

    fn spk(tag: u8) -> ScriptBuf {
        // A distinct 32-byte p2tr spk per tag (content irrelevant to selection logic).
        ScriptBuf::new_p2tr_tweaked(
            bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(xonly(tag)),
        )
    }
    fn out(txid: u8, vout: u32, sats: u64, spk: ScriptBuf, h: Option<u32>) -> ScannedOutput {
        ScannedOutput {
            outpoint: OutPoint {
                txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::from_byte_array([txid; 32])),
                vout,
            },
            value: Amount::from_sat(sats),
            spk,
            block_height: h,
        }
    }

    #[test]
    fn finds_buried_deposit_and_ignores_noise() {
        let dep = spk(0x01);
        let other = spk(0x02);
        let scan = vec![
            out(0xAA, 0, 100_000, other.clone(), Some(600_000)),   // wrong address
            out(0xBB, 1, 0, dep.clone(), Some(600_000)),           // zero value
            out(0xCC, 0, 250_000, dep.clone(), None),              // unconfirmed
            out(0xDD, 0, 250_000, dep.clone(), Some(600_005)),     // only 1 conf (tip 600_005)
            out(0xEE, 0, 250_000, dep.clone(), Some(600_000)),     // buried (6 confs) ✓
        ];
        let got = find_confirmed_deposit(&scan, dep.as_script(), 600_005, 6).unwrap();
        assert_eq!(got.value, Amount::from_sat(250_000));
        assert_eq!(got.outpoint.vout, 0);
        assert_eq!(
            got.outpoint.txid,
            bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::from_byte_array([0xEE; 32]))
        );
    }

    #[test]
    fn none_until_buried() {
        let dep = spk(0x01);
        let scan = vec![out(0xAB, 0, 250_000, dep.clone(), Some(600_000))];
        assert!(find_confirmed_deposit(&scan, dep.as_script(), 600_004, 6).is_none(), "5 confs < 6");
        assert!(find_confirmed_deposit(&scan, dep.as_script(), 600_005, 6).is_some(), "6 confs ok");
    }

    #[test]
    fn picks_one_deterministically_when_double_paid() {
        let dep = spk(0x01);
        // Two buried deposits at the SAME address (user double-paid): pick the lower block,
        // then lower txid — deterministic, and only ONE (the other is refundable via CLTV).
        let scan = vec![
            out(0xF2, 0, 200_000, dep.clone(), Some(600_002)),
            out(0xF1, 0, 300_000, dep.clone(), Some(600_000)), // lower height → chosen
            out(0xF3, 0, 400_000, dep.clone(), Some(600_000)), // same height, higher txid
        ];
        let got = find_confirmed_deposit(&scan, dep.as_script(), 600_010, 6).unwrap();
        assert_eq!(got.value, Amount::from_sat(300_000), "lowest (height,txid) wins deterministically");
    }

    #[test]
    fn conf_math_never_underflows_on_future_height() {
        let dep = spk(0x01);
        // A malformed/racey scan reporting a height ABOVE the tip ⇒ not buried, no panic.
        let scan = vec![out(0xAC, 0, 250_000, dep.clone(), Some(600_010))];
        assert!(find_confirmed_deposit(&scan, dep.as_script(), 600_000, 6).is_none());
    }

    #[test]
    fn registry_register_snapshot_remove_persists_through_store() {
        // In-memory store (load(None)) — exercises the register→persist→snapshot round-trip
        // through the serde record, so it also covers OnchainSwapInRec's of()/to_swap().
        let store = std::sync::Arc::new(crate::store::BridgeStore::load(None).unwrap());
        let reg = SwapInRegistry::new(store);
        assert!(reg.is_empty());
        let s = a_swap(800_000);
        let id = s.swap_id;
        reg.register(s);
        assert_eq!(reg.len(), 1);
        assert_eq!(reg.snapshot().len(), 1);
        assert_eq!(reg.snapshot()[0].swap_id, id);
        reg.remove(&id);
        assert!(reg.is_empty(), "removed ⇒ watcher stops tracking it");
    }
}
