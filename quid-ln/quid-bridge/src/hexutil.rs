//! Small hex parsers shared across the bridge's RPC-response and persistence
//! decode paths. All return `Option` and NEVER panic on malformed input (the
//! inputs are untrusted RPC JSON / a possibly-corrupt durable store).

/// Decode a `0x`-prefixed (or bare) hex string to bytes.
pub fn hex_bytes(s: &str) -> Option<Vec<u8>> {
    alloy_primitives::hex::decode(s.trim_start_matches("0x")).ok()
}

/// Decode a `0x`-prefixed (or bare) 32-byte hex string.
pub fn hex_b32(s: &str) -> Option<[u8; 32]> {
    <[u8; 32]>::try_from(hex_bytes(s)?.as_slice()).ok()
}

/// Parse a `0x`-prefixed (or bare) hex quantity (e.g. `"0x1a"`) to u64.
pub fn hex_u64(s: &str) -> Option<u64> {
    u64::from_str_radix(s.trim_start_matches("0x"), 16).ok()
}
