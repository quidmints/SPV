//! QU!D Lightning **hop** — bridges standard BOLT/LDK channels to the QU!D EVM
//! contracts, built on the vendored `quid-ln` (quid-derived LDK) node:
//!   • `funding` — the P2WSH 2-of-2 (LP+hop) funding script (mirrors
//!     `BitcoinTx.buildChannelRedeemScript`); tx built via `quid_ln::wallet`.
//!   • `spv`     — merkle proof/header shaping for `SPVGateway.checkTxInclusion`,
//!     fed from `quid_ln::esplora`.
//!   • `swap`    — the bidirectional HTLC bridge over `quid_ln`'s LDK node:
//!     a settled invoice → `settleSwapIn`; an EVM obligation → pay the invoice.
pub use quid_ln;
/// Canonical EVM ABI word-building helpers shared by the hop's EVM encoders.
pub(crate) mod abi;
pub mod ffs;
pub mod freshness;
/// (§LP-LIVENESS) The routing gate: an LP that has not posted a recent heartbeat stops being
/// routed NEW swappers, which is what makes per-splice ladder re-arming opt-in for a phone.
pub mod liveness;
/// Reusable regtest harness (bitcoind + esplora-electrs + node boot helpers),
/// shared by `tests/e2e.rs` and the `e2e_ffi` bin. Feature-gated so the
/// download/electrsd surface isn't pulled into a normal hop build.
#[cfg(feature = "harness")]
pub mod harness;
pub mod persister;
pub mod peer;
pub mod bump;
pub mod evm_codec;
pub mod event_handler;
pub mod node;
pub mod migration;
pub mod seed;
pub mod rebalancer;
pub mod funding;
pub mod spv;
pub mod swap;
pub mod swap_in_onchain;
