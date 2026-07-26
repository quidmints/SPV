//! Coverage-guided fuzz target for `read_lp_auth` — the lpAuth custom-message
//! decoder fed by UNTRUSTED Lightning peers. INVARIANT: arbitrary bytes (and an
//! arbitrary 16-bit message type drawn from the first 2 input bytes) must only
//! ever produce Ok/Err/None — never a panic.
#![no_main]

use libfuzzer_sys::fuzz_target;
use quid_hop::lp_auth::read_lp_auth;

fuzz_target!(|data: &[u8]| {
    // Use the first two bytes as the wire message type (so the fuzzer can reach
    // every known type id + every unknown one), the rest as the message body.
    let (ty, body) = if data.len() >= 2 {
        (u16::from_le_bytes([data[0], data[1]]), &data[2..])
    } else {
        (0u16, data)
    };
    let _ = read_lp_auth(ty, &mut &body[..]); // must not panic
});
