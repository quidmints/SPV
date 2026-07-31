//! The bitcoin vocabulary shared across `quid-bridge`, `quid-hop`, `quid-ln` and this crate.
//!
//! WHY THIS EXISTS. A dependency graph of the workspace showed every bitcoin domain type -
//! `PublicKey`, `Amount`, `Address`, `Network`, `Transaction`, `OutPoint`, `ScriptBuf`, `LockTime`,
//! `Xpriv`, `XOnlyPublicKey` - imported independently by four crates. That is not duplicated logic;
//! it is a duplicated VOCABULARY, and it means a `bitcoin` version bump or a type-alias change is a
//! four-place edit with no single place to notice it. `quid-common` was not acting as the common
//! layer for the thing these crates most share.
//!
//! WHAT IT IS AND IS NOT. Pure re-exports: the types are identical, so `use
//! quid_common::prelude::*` is semantically indistinguishable from importing `bitcoin` directly and
//! the compiler proves it. This adds no abstraction, wraps nothing, and hides nothing - it is one
//! import path for a vocabulary four crates already agreed on.
//!
//! MEMBERSHIP IS EVIDENCE-BASED, not aspirational: every item below appears in at least two crates
//! today. Adding a type used in ONE place would make this a dumping ground and cost the reader the
//! guarantee that anything here is genuinely shared.
//!
//! ADOPTION IS OPTIONAL AND INCREMENTAL. Nothing is forced to use it; a crate migrates when it is
//! touched for other reasons. A mass rewrite of import lines would be a large diff with no
//! behavioural change - exactly the kind that hides a real one inside it.

pub use bitcoin::absolute::LockTime;
pub use bitcoin::hashes::Hash as _;
pub use bitcoin::secp256k1::{self, Keypair, Message, PublicKey, Secp256k1, SecretKey};
pub use bitcoin::sighash::{Prevouts, SighashCache, TapSighashType};
pub use bitcoin::transaction::Version;
pub use bitcoin::{Transaction, Txid};
