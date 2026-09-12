//! §PROVING-ARCHITECTURE-8288 — the privacy-pool STATEMENTS as plain Rust.
//!
//! Each statement is a pure function from (public signals, witness) to accept/reject, written once
//! and proven by whatever prover the era has: a RISC-V zkVM today, leanSTARK when EIP-8288 ships.
//! Nothing here knows about a proof system. The public signals of a statement are its JOURNAL —
//! an ABI tuple of 32-byte words — and that tuple is what a verifier binds and what 8288 hashes
//! into a dependency's `data_hash`.
//!
//! Every hash is circomlib Poseidon over BN254, because that is what the DEPLOYED pool computes
//! (`PoseidonT3` in its LeanIMT, `@iden3/js-crypto` in the wallet, `poseidon::bn254` in the Noir
//! circuits these replace). The statements must accept exactly the witnesses those produce — the
//! acceptance test is the Noir e2e prover input (`withdraw_identity/Prover.e2e.toml`), whose public
//! signals a real Honk proof has already settled on-chain.

pub mod field;
pub mod poseidon;
pub mod lean_imt;
pub mod smt;
pub mod commitment;
pub mod withdraw;
pub mod ragequit;
