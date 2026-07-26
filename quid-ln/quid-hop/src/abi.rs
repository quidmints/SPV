//! Canonical EVM ABI word-building helpers shared by the hop's EVM encoders
//! (`evm_codec`, `migration`, `swap`). The word layouts are fixed by the EVM ABI:
//!   • a `uint*` (≤ u64 here) is right-aligned big-endian → u64 in bytes `[24..32]`
//!   • an `address` occupies the low 20 bytes of a 32-byte word → bytes `[12..32]`
//! Kept byte-identical so calldata / EIP-712 preimages never drift.

use alloy_primitives::Address;

/// Right-align a `u64` into its 32-byte ABI word (big-endian, bytes `[24..32]`).
pub(crate) fn word_u64(n: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&n.to_be_bytes());
    w
}

/// Left-pad an [`Address`] into its 32-byte ABI word (bytes `[12..32]`).
pub(crate) fn address_word(a: Address) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a.as_slice());
    w
}
