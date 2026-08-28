// SHA-512.
//
// The Noir stdlib dropped `std::sha512` (and `std::sha256`) after beta.1, and unlike sha256 there
// is no `noir-lang/sha512` package to depend on. This library already contained the complete
// SHA-512 core inside sha384.nr - SHA-384 IS SHA-512 with a different IV, truncated to 48 bytes
// (FIPS 180-4) - so this reuses those exact helpers rather than reimplementing the compression
// function. The ONLY differences from sha384::digest are the initial hash values and the absence
// of truncation.
//
// Verified against Python `hashlib.sha512` below, covering both the one-block and multi-block
// padding paths. Do not modify without re-running those.
use crate::sha384::{msg_u8_to_u64, sha_c};
use std::ops::WrappingAdd;

/// `std::wrapping_add` was a free function; on beta.26 it is a `WrappingAdd` trait method.
/// Kept as a local wrapper so every call site stays byte-identical - this is hash code, and
/// a rewritten expression is a silently different digest.
fn wrapping_add(a: u64, b: u64) -> u64 {
    a.wrapping_add(b)
}


pub fn digest<let N: u32>(msg: [u8; N]) -> [u8; 64] {
    let mut msg_block: [u8; 128] = [0; 128];
    // noir-fmt:ignore
    let mut h: [u64; 8] = 
        [0x6a09e667f3bcc908,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179];
    let mut c: [u64; 8] = [0; 8]; // Compression of current message block as sequence of u64
    let mut out_h: [u8; 64] = [0; 64]; // Digest as sequence of bytes
    let mut i: u32 = 0; // Message byte pointer
    for k in 0..msg.len() {
        // Populate msg_block
        msg_block[i] = msg[k];
        i = i + 1;
        if i == 128 {
            // Enough to hash block
            c = sha_c(msg_u8_to_u64(msg_block), h);
            for j in 0..8 {
                h[j] = wrapping_add(h[j], c[j]);
            }

            i = 0;
        }
    }
    // Pad the rest such that we have a [u64; 2] block at the end representing the length
    // of the message, and a block of 1 0 ... 0 following the message (i.e. [1 << 7, 0, ..., 0]).
    msg_block[i] = 1 << 7;
    i += 1;
    // If i >= 113, there aren't enough bits in the current message block to accomplish this, so
    // the 1 and 0s fill up the current block, which we then compress accordingly.
    if i >= 113 {
        // Not enough bits (128) to store length. Fill up with zeros.
        if i < 128 {
            for _i in 113..128 {
                if i <= 127 {
                    msg_block[i] = 0;
                    i += 1;
                }
            }
        }
        c = sha_c(msg_u8_to_u64(msg_block), h);
        for j in 0..8 {
            h[j] = wrapping_add(h[j], c[j]);
        }

        i = 0;
    }

    let len = 8 * msg.len();
    let len_bytes: [u8; 16] = (len as Field).to_le_bytes();
    for _i in 0..128 {
        // In any case, fill blocks up with zeros until the last 128 (i.e. until i = 112).
        if i < 112 {
            msg_block[i] = 0;
            i += 1;
        } else if i < 128 {
            for j in 0..16 {
                msg_block[127 - j] = len_bytes[j];
            }
            i += 16; // Done.
        }
    }
    // Hash final padded block
    c = sha_c(msg_u8_to_u64(msg_block), h);
    for j in 0..8 {
        h[j] = wrapping_add(h[j], c[j]);
    }
    // Return final hash as byte array
    for j in 0..8 {
        let h_bytes: [u8; 8] = (h[7 - j] as Field).to_le_bytes();
        for k in 0..8 {
            out_h[63 - 8 * j - k] = h_bytes[k];
        }
    }

    out_h
}


#[test]
fn test_sha512_1_chunk() {
    // hashlib.sha512(bytes(2)).digest()
    let res = digest::<2>([0, 0]);
    assert(
        res
            == [
                94, 167, 29, 198, 208, 180, 245, 123, 243, 154, 173, 208, 124, 32, 140, 53, 240,
                108, 210, 186, 197, 253, 226, 16, 57, 127, 112, 222, 17, 212, 57, 198, 46, 193, 205,
                243, 24, 55, 88, 134, 95, 211, 135, 252, 234, 11, 173, 162, 246, 195, 122, 74, 23,
                133, 29, 209, 215, 143, 239, 230, 242, 4, 238, 84,
            ],
    );
}

#[test]
fn test_sha512_2_chunks() {
    // hashlib.sha512(bytes(130)).digest() - exercises the multi-block padding path
    let res = digest::<130>([0; 130]);
    assert(
        res
            == [
                227, 170, 93, 156, 127, 216, 117, 48, 52, 163, 128, 195, 90, 51, 180, 106, 107, 156,
                89, 255, 47, 220, 144, 170, 232, 18, 201, 56, 165, 224, 163, 133, 114, 155, 45, 113,
                195, 3, 228, 198, 10, 14, 108, 48, 216, 165, 176, 183, 252, 125, 99, 66, 51, 247,
                238, 213, 100, 25, 79, 62, 236, 47, 164, 83,
            ],
    );
}
