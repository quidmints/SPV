//! QU!D EVM-sender bridge — the LN↔EVM glue that turns the hop node's swap
//! events into `BTCChannels` transactions. Designed to run as a parallel daemon
//! on the SAME box as the hop: it shares the hop's tokio runtime + an in-process
//! `mpsc`, and holds the hot `onlyHop` EVM key. EVM I/O is BLOCKING (see [`evm`])
//! and runs on `spawn_blocking`, so the daemon never starts a second async
//! runtime — sidestepping the tokio-fork vs `alloy-provider` version clash.
//!
//! Build status:
//!   • [`swap_in`] — settle-then-claim swap-in sender. DONE (Increment 1). Plus
//!     the settle-time CLTV re-check (Increment 1b): the inbound HTLC's claim
//!     deadline is re-evaluated against the LIVE Bitcoin tip immediately before
//!     settling, failing the HTLC back (clean swapper refund) instead of
//!     delivering USD if headroom eroded between the hop's emit-time gate and the
//!     settle landing (slow nonce / queue / restart backlog). DONE.
//!   • [`client`] — JSON-RPC `EvmClient`: RPC flow + receipt + revert→swapInUsed
//!     decode. DONE (Increment 2).
//!   • [`signer`] — [`signer::LocalSigner`]: EIP-1559 signing from vetted
//!     primitives (secp256k1 recoverable ECDSA + keccak), verified BYTE-EXACT
//!     against a `cast` reference vector. DONE. (The vetted `alloy-consensus`
//!     path was unusable here — it needs alloy-primitives 1.x / rustc 1.91, both
//!     conflicting with this workspace's 0.8.26 / 1.90 pins.)
//!   • [`swap_out_onchain`] — the ON-CHAIN USD→BTC swap-out rail: watch
//!     `SwapOutRequestedOnchain`, deliver BTC to the swapper's Bitcoin address via
//!     an LP splice-out (finality-gated), reverse via `settleSwapIn` if
//!     undeliverable. (The off-chain LN swap-out rail was removed; re-added in a later milestone.)
//!   • [`relayer`] — SPV header relayer. DONE.
//!   • The `lp_fees` LP-fee settler was RETIRED — BTC-leg fees now compound
//!     in-channel via the fee-splice; any exit residual is forgone to the pool (dust).
//!   • Remaining: openChannel/recordClose drivers (the channel-lifecycle EVM
//!     senders) and the rebalancer/channel-capacity manager.

/// Canonical EVM ABI word-building / decoding helpers, shared by every calldata
/// encoder in this crate so the fund-gating / anti-rollback bytes stay identical.
pub(crate) mod abi;
pub mod boot;
pub mod channel_driver;
pub mod channel_truth;
pub mod deadman_exit;
pub mod recovery_broadcast;
pub mod vault;
pub mod client;
pub mod config;
pub mod daemon;
pub mod eth_logs;
pub mod evm;
pub mod evm_validating_signer;
pub mod freshness_ledger;
/// YB IL-protect keeper: proactive de-lever loop so the venue's liquidation engine
/// never fires (we build none of our own). Decision core; EVM I/O loop wires to the
/// weETH-escrow Euler adapter once it lands.
pub mod lev_keeper;
pub mod lev_keeper_btc;
pub mod header_source;
/// The LP's one-time seed backup (§M1#2 phase 1c). Phase 1b made the LP the sole holder of its
/// half of every 2-of-2; this is the only moment at which it can be handed a copy to keep.
pub mod lp_seed;
pub(crate) mod hexutil;
pub mod provision_api;
pub mod relayer;
pub mod signer;
pub mod store;
/// (§W1) The authorized trigger for a full wallet drain — the control that was missing,
/// not the code. Mirrors the seed export's operator-Safe authorization.
pub mod sweep;
pub mod swap_in;
pub mod swap_in_api;
pub mod swap_in_onchain;
pub mod swap_out_onchain;
pub mod transport;

pub use client::{JsonRpcEvmClient, TxFields, TxSigner};
pub use config::BridgeConfig;
pub use evm::{EvmClient, SettleOutcome};
pub use relayer::{
    encode_add_header_batch, read_gateway_height, relay_range, run_spv_relayer, BtcHeaderSource,
};
pub use signer::LocalSigner;
pub use store::BridgeStore;
pub use swap_in::{run_swap_in_sender, BtcTip, SwapInActor};
pub use transport::{HttpJsonRpc, JsonRpc};
