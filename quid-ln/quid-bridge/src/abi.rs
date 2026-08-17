//! Canonical EVM ABI word-building / decoding helpers for the bridge.
//!
//! All calldata-shaping in this crate — the fund-gating lev-keeper txs and the
//! anti-rollback freshness commits included — routes through here so every
//! encoder is BYTE-IDENTICAL. The word layouts are fixed by the EVM ABI:
//!   • an `address` occupies the low 20 bytes of a 32-byte word → bytes `[12..32]`
//!   • a `uint*` (≤ u64 here) is right-aligned big-endian → u64 in bytes `[24..32]`
//! `addr_word` (from a raw `[u8; 20]` LP identity) and `address_word` (from an
//! `Address`) produce the SAME bytes; both are provided so callers keep their
//! natural argument type without a lossy conversion.

use alloy_primitives::{keccak256, Address, U256};

/// Left-pad a raw 20-byte LP address into its 32-byte ABI word (bytes `[12..32]`).
pub(crate) fn addr_word(lp: [u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(&lp);
    w
}

/// Left-pad an [`Address`] into its 32-byte ABI word (bytes `[12..32]`) — the same
/// layout as [`addr_word`], for callers that already hold an `Address`.
pub(crate) fn address_word(a: Address) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a.as_slice());
    w
}

/// Right-align a `u64` into its 32-byte ABI word (big-endian, bytes `[24..32]`).
pub(crate) fn u64_word(n: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&n.to_be_bytes());
    w
}

/// The 4-byte function selector for a Solidity signature (`keccak256(sig)[..4]`).
pub(crate) fn selector4(sig: &str) -> Vec<u8> {
    keccak256(sig.as_bytes())[..4].to_vec()
}

/// Decode the address held in the low 20 bytes of a returned 32-byte word.
/// A short (hostile/garbage) return errors rather than panicking on the slice.
pub(crate) fn word_to_lpaddr(w: &[u8]) -> anyhow::Result<[u8; 20]> {
    let word = w
        .get(..32)
        .ok_or_else(|| anyhow::anyhow!("short address return (adversarial RPC?)"))?;
    let mut a = [0u8; 20];
    a.copy_from_slice(&word[12..32]);
    Ok(a)
}

/// Decode a returned 32-byte word as an unsigned integer, erroring (never
/// truncating/clamping) if the value doesn't fit `T` — a garbage/adversarial RPC
/// value must surface as an error, not silently become a small number (e.g. a
/// height clamped to 0 → re-submit every header = gas-DoS). `what` names the call
/// for the error message.
pub fn word_to_uint<T: TryFrom<U256>>(bytes: &[u8], what: &str) -> anyhow::Result<T> {
    // Total over the slice: a SHORT return (hostile/garbage RPC) errors rather than
    // panicking on an out-of-bounds slice. Every caller length-gates today, but this
    // keeps the invariant in the type, not in caller discipline.
    let word = bytes
        .get(..32)
        .ok_or_else(|| anyhow::anyhow!("{what}: short return (adversarial RPC?)"))?;
    U256::from_be_slice(word)
        .try_into()
        .map_err(|_| anyhow::anyhow!("{what} (adversarial RPC?)"))
}

/// §V-R1 — ABI-encode a trailing dynamic `bytes` argument.
///
/// A `bytes` parameter is NOT inline: the head carries a 32-byte OFFSET to where the data begins
/// (measured from the start of the argument block, not from the selector), and the tail carries a
/// 32-byte LENGTH followed by the payload right-padded to a 32-byte boundary.
///
/// ⚠️ THE OFFSET IS THE PART THAT IS EASY TO GET WRONG AND HARD TO NOTICE. It counts the HEAD words
/// only. For `f(address,uint256,bytes)` the head is 3 words, so the offset is 0x60 — not 0x40 (which
/// would point at the third head slot) and not the byte length of anything. An off-by-one-word offset
/// does not revert: the callee reads a length from whatever word the offset lands on, and either
/// decodes garbage or reverts far downstream with an unrelated message.
///
/// `head_words` is therefore passed EXPLICITLY rather than inferred: the caller knows its own
/// signature and a wrong value here is a silent mis-encode.
pub fn bytes_tail(head_words: usize, data: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let mut offset = [0u8; 32];
    let off = (head_words * 32) as u64;
    offset[24..].copy_from_slice(&off.to_be_bytes());

    let mut tail = Vec::with_capacity(32 + data.len() + 31);
    let mut len = [0u8; 32];
    len[24..].copy_from_slice(&(data.len() as u64).to_be_bytes());
    tail.extend_from_slice(&len);
    tail.extend_from_slice(data);
    let pad = (32 - (data.len() % 32)) % 32;      // right-pad to a word boundary; 0 when already aligned
    tail.extend(std::iter::repeat(0u8).take(pad));
    (offset.to_vec(), tail)
}
