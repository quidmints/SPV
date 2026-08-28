// Privacy Pool Noir gadgets (Honk-stack port of PP's Circom circuits).
// One audited hash (circomlib-Poseidon via noir-lang/poseidon) shared with rarime + the wallet.
pub mod jubjub;
pub mod holder_root;
pub mod commitment;
pub mod lean_imt;
pub mod identity_asp;
pub mod title_holder;
pub mod smt;
pub mod blacklist;
pub mod envelope;
pub mod withdraw;
