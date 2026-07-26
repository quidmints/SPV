//! Channel **funding** — the P2WSH 2-of-2 (LP + hop) output the EVM `BTCChannels`
//! reconstructs and SPV-verifies on `openChannel`. The witnessScript here is a
//! BYTE-FOR-BYTE mirror of Solidity `BitcoinTx.buildChannelRedeemScript`; the
//! openChannel e2e (regtest funding tx → SPV proof → the real verifier) confirms
//! the bytes match. The funding tx itself is built/broadcast via `quid_ln::wallet`
//! (BDK) in the hop service; this module owns the protocol-specific script bytes.

use bitcoin::{ScriptBuf, WitnessProgram, WitnessVersion};

/// witnessScript — a plain 2-of-2 multisig, **byte-identical to LDK's
/// `make_funding_redeemscript`** (chan_utils.rs): the two 33-byte funding
/// pubkeys SORTED lexicographically (smaller serialized key first):
/// ```text
///   OP_2 <key_lo33> <key_hi33> OP_2 OP_CHECKMULTISIG
/// ```
/// There is NO CLTV self-refund branch. The LP↔hop BTC leg is a standard
/// LDK channel, so unilateral recovery + dispute (stale-state) are enforced
/// natively on Bitcoin by the LDK commitment tx + justice/watchtowers — not by a
/// bespoke EVM-anchored timelock (which let the LP grief the hop out of fronted
/// delivery by sweeping the whole funding UTXO). The EVM only SPV-anchors the
/// funding + reads the LDK close.
pub fn channel_redeem_script(lp: &[u8; 33], hop: &[u8; 33]) -> ScriptBuf {
    use bitcoin::secp256k1::PublicKey;
    // LDK's `make_funding_redeemscript` sorts the two funding keys internally
    // (make_funding_redeemscript_from_slices) and emits
    //   OP_2 <key_lo33> <key_hi33> OP_2 OP_CHECKMULTISIG
    // — byte-for-byte the bytes we previously hand-pushed. Reuse it verbatim.
    // Funding pubkeys are always valid compressed points (they come from live
    // channels), so the parse cannot fail for real inputs.
    let lp_pk = PublicKey::from_slice(lp).expect("lp is a valid 33-byte compressed funding pubkey");
    let hop_pk =
        PublicKey::from_slice(hop).expect("hop is a valid 33-byte compressed funding pubkey");
    lightning::ln::chan_utils::make_funding_redeemscript(&lp_pk, &hop_pk)
}

/// P2WSH scriptPubKey: `OP_0 (0x00) || push-32 (0x20) || sha256(redeem)`.
pub fn p2wsh_script_pubkey(redeem: &ScriptBuf) -> ScriptBuf {
    // rust-bitcoin's `new_p2wsh` builds OP_0 || push-32 || sha256(redeem) — the same
    // 34 bytes we hand-assembled; `wscript_hash()` is exactly `sha256(script)`.
    ScriptBuf::new_p2wsh(&redeem.wscript_hash())
}

/// **Taproot (P2TR) channel-funding scriptPubKey** — the key-path-only MuSig2
/// 2-of-2 output the EVM `BTCChannels`/`ChannelLib` reconstructs and SPV-verifies
/// on `openChannel` for taproot channels. BYTE-FOR-BYTE the EVM mirror: `0x5120 || Q`.
///
/// `Q` is the BIP341 §158 taproot output key for a key-path-only spend (empty
/// merkle root), built per BIP327 + BOLT simple-taproot-channels:
/// ```text
///   Q = lift_x(agg) + int(H_TapTweak(bytes(agg)))·G
///   agg = KeyAgg(KeySort(lp33, hop33))           // 33-byte compressed, sorted
/// ```
/// Concretely: **KeySort the two 33-byte compressed keys lexicographically FIRST**
/// (the Rust signer, the counterparty, AND the EVM contract MUST use the identical
/// sort — else `Q` mismatches → unspendable funding), then
/// `KeyAggContext::new(sorted).with_unspendable_taproot_tweak().aggregated_pubkey()`,
/// x-only-serialized (32 bytes). The scriptPubKey is `OP_1 (0x51) || push-32 (0x20)
/// || Q` (34 bytes).
///
/// There is NO funding-level CLTV refund leaf — key-path-only funding has no
/// script path; unilateral recovery is the commitment/force-close path.
///
/// Returns the byte-identical 34-byte P2TR scriptPubKey. The MuSig2 keyagg cannot
/// fail for two distinct valid compressed pubkeys (a non-infinity aggregate +
/// non-infinity taproot tweak); the `expect`s below are unreachable for valid
/// inputs and carry justifications.
pub fn channel_taproot_script_pubkey(lp: &[u8; 33], hop: &[u8; 33]) -> ScriptBuf {
    let q_xonly = taproot_funding_aggregate_xonly(lp, hop);
    // rust-bitcoin's `new_witness_program` builds OP_1 (0x51) || push-32 (0x20) || Q —
    // byte-for-byte the P2TR scriptPubKey we hand-assembled. A 32-byte v1 program is
    // always a valid witness program, so `new` cannot fail here.
    let program = WitnessProgram::new(WitnessVersion::V1, &q_xonly)
        .expect("32-byte v1 witness program is always valid");
    ScriptBuf::new_witness_program(&program)
}

/// The 32-byte x-only **MuSig2 key-path aggregate `Q`** of the channel's 2-of-2
/// (the tail of [`channel_taproot_script_pubkey`], i.e. `0x5120||Q`). This is the
/// value the EVM `OpenParams.fundingTaproot` carries so the contract can build
/// `0x5120||Q` and byte-match the funding output (it does NO secp256k1 EC math).
///
/// `Q = lift_x(KeyAgg(KeySort(lp33, hop33))) + int(H_TapTweak(bytes(agg)))·G` with
/// an empty merkle root (BIP341 §158), via the proven conduition musig2 API. The
/// KeySort is lexicographic on the 33-byte compressed keys (smaller first) — the
/// Rust signer, the counterparty, AND the EVM contract MUST agree on it or `Q`
/// mismatches → unspendable funding. Symmetric in `(lp, hop)`.
pub fn taproot_funding_aggregate_xonly(lp: &[u8; 33], hop: &[u8; 33]) -> [u8; 32] {
    use musig2::secp256k1::PublicKey;
    use musig2::KeyAggContext;

    // KeySort: the two 33-byte compressed keys lexicographically (smaller first).
    // Deterministic + symmetric; MUST match LDK/the counterparty/the EVM contract.
    let (lo, hi) = if lp[..] < hop[..] { (lp, hop) } else { (hop, lp) };

    // Parse compressed keys into native secp256k1 0.29 points (musig2 re-exports
    // our exact secp256k1, so no shim/version conversion).
    let lo_pk = PublicKey::from_slice(lo).expect("lo is a valid 33-byte compressed pubkey");
    let hi_pk = PublicKey::from_slice(hi).expect("hi is a valid 33-byte compressed pubkey");

    // KeyAgg(KeySort(..)) then the BIP86/BIP341 §158 key-path-only taproot tweak
    // (empty merkle root). `aggregated_pubkey` returns the tweaked output key Q.
    let ctx = KeyAggContext::new([lo_pk, hi_pk])
        .expect("two distinct valid pubkeys aggregate to a non-infinity point")
        .with_unspendable_taproot_tweak()
        .expect("taproot tweak of a valid aggregate is non-infinity");
    let q: PublicKey = ctx.aggregated_pubkey();

    // x-only: drop the 0x02/0x03 parity prefix → the 32-byte x-coordinate.
    q.x_only_public_key().0.serialize()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redeem_script_is_sorted_plain_2of2() {
        // lp (0x02..) < hop (0x03..) lexicographically → lp first. Both must be VALID
        // compressed secp256k1 points now that we reuse LDK's make_funding_redeemscript
        // (which parses real PublicKeys): [0x02;33] is on-curve (even-Y), and `hop` is the
        // odd-Y (0x03) sibling of a BIP327 example x-coordinate — larger, so lp sorts first.
        let lp = [0x02u8; 33];
        let hop =
            hex_to_33("033590a94e768f8e1815c2f24b4d80a8e3149316c3518ce7b7ad338368d038ca66");
        let s = channel_redeem_script(&lp, &hop);
        let b = s.as_bytes();
        assert_eq!(b.len(), 71, "plain 2-of-2 is 71 bytes (no CLTV branch)");
        assert_eq!(b[0], 0x52); // OP_2
        assert_eq!(b[1], 0x21);
        assert_eq!(&b[2..35], &lp); // smaller key first
        assert_eq!(b[35], 0x21);
        assert_eq!(&b[36..69], &hop);
        assert_eq!(b[69], 0x52); // OP_2
        assert_eq!(b[70], 0xae); // OP_CHECKMULTISIG

        // Sorting is symmetric: swapping args yields the identical script.
        assert_eq!(channel_redeem_script(&hop, &lp).as_bytes(), b);

        let spk = p2wsh_script_pubkey(&s);
        assert_eq!(spk.as_bytes().len(), 34);
        assert_eq!(spk.as_bytes()[0], 0x00);
        assert_eq!(spk.as_bytes()[1], 0x20);
    }

    /// M1: the P2TR channel-funding scriptPubKey is exactly `0x51 0x20 || Q`,
    /// where `Q` = `KeyAgg(KeySort([lp,hop])).with_unspendable_taproot_tweak()`
    /// x-only-serialized — derived independently here from the conduition musig2
    /// API (self-checking) and pinned to a fixed expected 34-byte vector.
    #[test]
    fn taproot_funding_spk_is_p2tr() {
        use musig2::secp256k1::PublicKey;
        use musig2::KeyAggContext;

        // Fixed (lp, hop) compressed-pubkey pair — BIP327 KeyAgg example keys.
        // (Two distinct valid secp256k1 points; both even-Y here, parity is
        // handled by the taproot tweak path regardless.)
        let lp_hex = "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
        let hop_hex = "023590a94e768f8e1815c2f24b4d80a8e3149316c3518ce7b7ad338368d038ca66";
        let lp: [u8; 33] = hex_to_33(lp_hex);
        let hop: [u8; 33] = hex_to_33(hop_hex);

        let spk = channel_taproot_script_pubkey(&lp, &hop);
        let b = spk.as_bytes();

        // Structural invariants: P2TR = OP_1 PUSH32 <32-byte x-only Q> = 34 bytes.
        assert_eq!(b.len(), 34, "P2TR spk is 34 bytes");
        assert_eq!(b[0], 0x51, "OP_1");
        assert_eq!(b[1], 0x20, "push 32");

        // Independently re-derive Q from the conduition API (KeySort first).
        let (lo, hi) = if lp[..] < hop[..] { (&lp, &hop) } else { (&hop, &lp) };
        let lo_pk = PublicKey::from_slice(lo).unwrap();
        let hi_pk = PublicKey::from_slice(hi).unwrap();
        let ctx = KeyAggContext::new([lo_pk, hi_pk])
            .unwrap()
            .with_unspendable_taproot_tweak()
            .unwrap();
        let q: PublicKey = ctx.aggregated_pubkey();
        let q_xonly = q.x_only_public_key().0.serialize();
        assert_eq!(&b[2..34], &q_xonly, "spk tail == x-only tweaked aggregate Q");

        // Sorting is symmetric: swapping args yields the identical scriptPubKey.
        assert_eq!(channel_taproot_script_pubkey(&hop, &lp).as_bytes(), b);

        // PINNED expected 34-byte funding scriptPubKey for this fixed vector.
        let expected: [u8; 34] = hex_to_34(
            "512082998b864a5c71ddcb1d67a54aa02640a2b8aeb58dca6e5e08c621fa1a90cbc1",
        );
        assert_eq!(b, &expected, "pinned P2TR funding spk byte vector");
    }

    fn hex_to_33(s: &str) -> [u8; 33] {
        let v = decode_hex(s);
        let mut a = [0u8; 33];
        a.copy_from_slice(&v);
        a
    }
    fn hex_to_34(s: &str) -> [u8; 34] {
        let v = decode_hex(s);
        let mut a = [0u8; 34];
        a.copy_from_slice(&v);
        a
    }
    fn decode_hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }
}
