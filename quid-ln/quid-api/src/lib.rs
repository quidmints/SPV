//! Crate containing Quid API types, definitions, client/server utils, TLS.

/// Make all of [`quid_api_core`] available under [`quid_api`].
///
/// NOTE: Any crates which can depend on `quid_api_core` directly (without
/// `quid-api`) should do so to avoid [`quid_api`] dependencies.
pub use quid_api_core::*;

/// A client and helpers that enforce common REST semantics across Quid crates.
pub mod rest;
/// API tracing utilities for both client and server.
pub mod trace;

