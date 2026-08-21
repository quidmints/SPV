//! Coverage-guided fuzz target for `recover_heartbeat` — the LP-liveness signature
//! recovery fed by UNTRUSTED Lightning peers (§LP-LIVENESS).
//!
//! INVARIANT: arbitrary bytes must only ever produce `Some(addr)` or `None` — never a panic.
//! The function slices (`sig65[..64]`, `uncompressed[1..]`, `keccak256(..)[12..]`) and branches on
//! a caller-supplied recovery id, which is exactly the shape that panics on malformed input.
//!
//! ⚠️ **THIS REPLACES `lp_auth.rs`, WHICH FUZZED A MODULE THAT NO LONGER EXISTS.** §E183 item 1
//! deleted `quid_hop::lp_auth` along with the EVM signature it decoded, and because this crate is
//! `exclude`d from the workspace (detached, nightly + sanitizer), NOTHING EVER FAILED TO COMPILE —
//! the repo's ONLY fuzz target had been silently dead. The invariant it protected did not go away
//! with the module: it moved to the decoders that still read untrusted peer bytes, and this is one.
#![no_main]

use libfuzzer_sys::fuzz_target;
use quid_hop::liveness::{recover_heartbeat, Heartbeat};
use alloy_primitives::B256;

fuzz_target!(|data: &[u8]| {
    // Split the input so the fuzzer drives BOTH the digest preimage and the signature bytes:
    // a fixed heartbeat would only ever exercise one message, and recovery is message-dependent.
    if data.len() < 45 {
        return;
    }
    let mut cid = [0u8; 32];
    cid.copy_from_slice(&data[..32]);
    let hb = Heartbeat {
        channel_id: B256::from(cid),
        height: u32::from_le_bytes([data[32], data[33], data[34], data[35]]),
        seq: u64::from_le_bytes([
            data[36], data[37], data[38], data[39], data[40], data[41], data[42], data[43],
        ]),
    };
    // Everything after the header is the signature — deliberately UNCONSTRAINED in length, so the
    // `!= 65` guard and the recovery-id branch are both reachable.
    let _ = recover_heartbeat(&hb, &data[44..]);
});
