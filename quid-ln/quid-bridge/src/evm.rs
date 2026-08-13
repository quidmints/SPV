//! The EVM I/O boundary for the bridge. Implementations are BLOCKING by design
//! (run on `tokio::task::spawn_blocking`), so the daemon never spins a second
//! async runtime alongside the hop's tokio — sidestepping the tokio-fork vs
//! `alloy-provider` version clash. The concrete JSON-RPC impl is a later
//! increment; the swap-in sender is written against this trait + mocks.

use alloy_primitives::{Address, B256, U256};

/// The result of attempting `settleSwapIn` for one swap-in.
///
/// A *definite* on-chain answer is one of these three — never an `Err`. `Err` is
/// reserved for TRANSIENT RPC/network failures (retryable), so the sender can
/// tell "the chain said no" from "I couldn't reach the chain".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettleOutcome {
    /// The settle tx confirmed successfully — USD delivered to the seller. `consumed_sats` is
    /// the seller's BTC actually converted (from the `SwapInSettled` event): on an
    /// inventory-bounded partial it is < the deposited sats, and the hop must refund the
    /// `deposited − consumed` remainder when it claims the deposit (never take unconverted BTC).
    Delivered { consumed_sats: u64 },
    /// The settle reverted but `swapInUsed(hash)` is TRUE: a prior settle already delivered
    /// (e.g. a restart re-emitted this swap-in). Safe to claim the BTC — `consumed_sats` is read
    /// back from that prior settle's `SwapInSettled` log so the same remainder is still refunded.
    AlreadySettled { consumed_sats: u64 },
    /// The settle reverted and `swapInUsed(hash)` is FALSE: genuinely
    /// undeliverable (floor unmet / pool dry). The BTC must be returned.
    Undeliverable,
}

/// The EVM calls the swap-in sender needs.
pub trait EvmClient: Send + Sync + 'static {
    /// Submit `settleSwapIn(seller, sats, token, paymentHash, minDeliveredUsd, requireFull)`,
    /// await the receipt, and on revert disambiguate via `swapInUsed(hash)`:
    /// `true` → [`SettleOutcome::AlreadySettled`], `false` →
    /// [`SettleOutcome::Undeliverable`]. Transient failures return `Err`.
    ///
    /// `require_full` = the on-chain "reject a partial" flag. When `true` and the pool can
    /// convert only PART of `sats`, the settle REVERTS (`SwapInPartialRejected`, rolling back
    /// the draw + USD) → surfaces as [`SettleOutcome::Undeliverable`] (swapInUsed stays
    /// false). The ATOMIC LN rail passes `true` (it can't refund a partial: no seller node to
    /// keysend); the on-chain rail passes `false` and refunds the unconverted remainder via
    /// a second claim output. A `Delivered`/`AlreadySettled` under `require_full = true` thus
    /// ALWAYS has `consumed_sats == sats`.
    fn settle_swap_in(
        &self,
        seller: Address,
        sats: u64,
        token: Address,
        payment_hash: B256,
        min_delivered_usd: U256,
        require_full: bool,
    ) -> anyhow::Result<SettleOutcome>;
}

/// (T1-c) The PROVEN on-chain deposit rail's one EVM call.
///
/// Deliberately a SEPARATE trait from [`EvmClient`] rather than a method on it, because the
/// two are not variants of one operation: `settle_swap_in` asks the chain to take the hop's
/// word for `sats`, and this asks it to derive `sats` from a transaction. Keeping them apart
/// means the on-chain rail's test stubs cannot accidentally satisfy the unproven interface,
/// and when the LN rail finally moves (T1-e) `EvmClient` deletes whole rather than shrinking.
///
/// ⚠️ **THE DEDUP KEY IS THE DEPOSIT TXID, NOT THE SWAP ID.** The contract keys
/// `swapInUsed` on the txid it computes from `raw_deposit_tx` — *"a txid is a fact"* — so a
/// caller confirming the settle must read burial against that txid. A `swap_id` here would
/// be the hop-invented key this rail exists to stop trusting.
pub trait ProvenSwapInSettler: Send + Sync + 'static {
    /// Neither trailing argument is sent as calldata — the contract recomputes both.
    /// `deposit_txid` (EVM/BE order) is how the caller gates on `swapInUsed`; `deposited_sats`
    /// is ONLY the fallback for `consumed_sats` when the `SwapInSettled` log cannot be read,
    /// where "the pool converted everything, refund nothing" is the safe direction — an
    /// over-refund would give away the hop's own BTC.
    #[allow(clippy::too_many_arguments)]
    fn settle_swap_in_proven(
        &self,
        seller: Address,
        token: Address,
        min_delivered_usd: U256,
        user_refund: [u8; 32],
        cltv_height: u32,
        inclusion: &quid_hop::evm_codec::TxInclusion,
        deposit_txid: B256,
        deposited_sats: u64,
    ) -> anyhow::Result<SettleOutcome>;
}
