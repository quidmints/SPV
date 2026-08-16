//! `quid-common` contains types and functionality shared between most Quid
//! crates.

// Ignore this issue with `proptest_derive::Arbitrary`.
#![allow(clippy::arc_with_non_send_sync)]
// `proptest_derive::Arbitrary` issue. This will hard-error for edition 2024 so
// hopefully it gets fixed soon...
// See: <https://github.com/proptest-rs/proptest/issues/447>
#![allow(non_local_definitions)]
// We don't export our traits currently so auto trait stability is not relevant.
#![allow(async_fn_in_trait)]

use std::path::PathBuf;

use anyhow::anyhow;
// Some re-exports to prevent having to re-declare dependencies
pub use quid_byte_array::ByteArray;
pub use ref_cast::RefCast;
pub use secrecy::{ExposeSecret, Secret};

/// API definitions, errors, clients, and structs sent across the wire.
pub mod api;
/// [`tokio::Bytes`](bytes::Bytes) but must contain a string.
pub mod byte_str;
/// Application-level constants.
pub mod constants;
/// [`rust_decimal::Decimal`] extensions.
pub mod decimal;
/// [`dotenvy`] extensions.
pub mod dotenv;
/// `DeployEnv`.
pub mod env;
/// Bitcoin / Lightning Quid newtypes which can't go in quid-ln
pub mod ln;
/// Networking utilities.
pub mod net;
/// `OrEnvExt` utility trait.
pub mod or_env;
/// `Ppm` - parts per million newtype for proportional fee rates.
pub mod ppm;
/// Types related to `releases.json`.
pub mod releases;
/// Random number generation.
pub mod rng;
/// `RootSeed`.
pub mod root_seed;
/// K-of-N Shamir shares of a [`root_seed::RootSeed`], for a family plan that wants recovery
/// without a custodian and without publishing who its members are.
pub mod seed_shares;
/// Global `Secp256k1` context
pub mod secp256k1_ctx;
/// `TimestampMs` and `DisplayMs`.
pub mod time;

/// Feature-gated test utilities that can be shared across crate boundaries.
#[cfg(any(test, feature = "test-utils"))]
pub mod test_utils;

/// Returns the default Quid data directory (`~/.quid`).
pub fn default_quid_data_dir() -> anyhow::Result<PathBuf> {
    #[allow(deprecated)] // home_dir is fine for our use case
    let home = std::env::home_dir()
        .ok_or_else(|| anyhow!("Could not determine home directory"))?;
    Ok(home.join(".quid"))
}

/// `panic!(..)`s in debug mode, `tracing::error!(..)`s in release mode
#[macro_export]
macro_rules! debug_panic_release_log {
    ($($arg:tt)*) => {
        if core::cfg!(debug_assertions) {
            core::panic!($($arg)*);
        } else {
            tracing::error!($($arg)*);
        }
    };
}
