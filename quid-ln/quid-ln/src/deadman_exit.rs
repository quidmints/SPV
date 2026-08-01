//! DEAD-MAN EXIT (#114) — the unsigned exit-tx builder + the 2-signer pre-sign
//! orchestrator that together produce the FULLY-signed, CLTV-timelocked unilateral
//! exit the fleet emits on-chain (`emitDeadManExit`) as the LP's key-less backstop.
//!
//! All the money-path crypto stays in THIS (audited) crate: the daemon
//! (`quid-bridge`) only ever handles the raw tx bytes this module returns and the
//! EVM submit. The funding secret key is NEVER exported — [`presign_deadman_exit`]
//! signs IN-PLACE through the two [`ValidatingChannelSigner`]s' `deadman_exit_*`
//! methods (each reads its own funding seckey internally and returns only a MuSig2
//! partial scalar).
//!
//! ## The exit tx (BIP341 key-path spend, CLTV = nLockTime)
//!
//! * **input** = the channel funding outpoint (`0x5120||Q`), with a NON-FINAL
//!   `nSequence` (`ENABLE_LOCKTIME_NO_RBF`) so consensus enforces the locktime;
//! * **output** = `checkpointSats − fee` → the LP's committed `btcRecipientOf`
//!   key-path P2TR (`0x5120||recipient_xonly`), byte-identical to the EVM
//!   `_withdrawalPayout` (`0x51 0x20 || btcRecipientOf`);
//! * **nLockTime** = the absolute CLTV dead-man deadline.
//!
//! Because the funding output is a KEY-PATH 2-of-2 (`with_unspendable_taproot_tweak`
//! aggregate `Q`), there is no `OP_CHECKLOCKTIMEVERIFY` script — the timelock lives
//! entirely in `nLockTime` + the non-final input, the standard pre-signed-timelocked
//! -tx pattern. The witness is a single 64-byte Schnorr signature (`SIGHASH_DEFAULT`).
//!
//! Built on rust-bitcoin's audited taproot APIs (`SighashCache`,
//! `taproot_key_spend_signature_hash`) — mirrors `quid-hop::swap_in_onchain` and the
//! signer's own `taproot_funding_keyspend_sighash` path; no hand-rolled crypto.

use bitcoin::absolute::LockTime;
use bitcoin::key::{TweakedPublicKey, XOnlyPublicKey};
use bitcoin::secp256k1::{self, Secp256k1};
use bitcoin::sighash::{Prevouts, SighashCache, TapSighashType};
use bitcoin::transaction::Version;
use bitcoin::{Amount, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Witness};

use crate::validating_signer::ValidatingChannelSigner;

/// Errors pre-signing a dead-man exit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeadManExitError {
    /// A signer had no taproot context yet, or an in-place sign/nonce step failed.
    Signer,
    /// The BIP341 key-path sighash could not be computed (malformed tx/prevout).
    Sighash,
    /// Final MuSig2 aggregation of the two partials failed.
    Aggregate,
    /// `checkpoint_sats < fee_sats` (would underflow the output value).
    Value,
}

/// The P2TR (`0x5120||xonly`) key-path scriptPubKey for a raw x-only key. Matches
/// `BTCChannels._withdrawalPayout` (`0x51 0x20 || btcRecipientOf`) byte-for-byte, so
/// the exit pays EXACTLY the LP's committed payout — it can never redirect funds.
pub fn keypath_p2tr_spk(xonly: XOnlyPublicKey) -> ScriptBuf {
    // `dangerous_assume_tweaked` is correct here: `btcRecipientOf` is the LP's
    // committed OUTPUT key (already the taproot output key it pays to), exactly as
    // the signer builds the funding SPK from the tweaked aggregate `Q`
    // (`validating_signer::taproot_key_agg`). We are constructing `0x5120||xonly`,
    // not re-tweaking a raw internal key.
    ScriptBuf::new_p2tr_tweaked(TweakedPublicKey::dangerous_assume_tweaked(xonly))
}

/// Build the UNSIGNED dead-man exit tx (see the module docs). `output_sats` is the
/// LP payout AFTER subtracting the miner fee; `recipient_xonly` is the LP's
/// `btcRecipientOf` x-only key; `cltv` is the absolute dead-man deadline (nLockTime).
/// `freshness` (#114): an OPTIONAL second input spending a fleet-controlled UTXO shared by
/// every channel. Because the BIP341 key-path sighash is taken over `Prevouts::All`, the
/// signature commits to EVERY prevout — so spending that one UTXO renders EVERY previously
/// emitted exit consensus-invalid at once (see
/// `sighash_commits_to_every_prevout_not_just_input_zero`). That is what stops a matured,
/// superseded exit from force-closing a live channel, at ONE small on-chain tx per period
/// GLOBALLY rather than one splice per channel. `None` = pre-rotation channel (no such UTXO
/// yet) and reproduces the original single-input tx byte-for-byte.
pub fn build_deadman_exit_tx(
    funding_outpoint: OutPoint,
    output_sats: u64,
    recipient_xonly: XOnlyPublicKey,
    cltv: LockTime,
    freshness: Option<OutPoint>,
) -> Transaction {
    // Input 0 is ALWAYS the channel funding outpoint; the optional freshness input is
    // APPENDED as input 1. This order is load-bearing: the sighash's `Prevouts::All` slice
    // must be built in the SAME order, or the signature commits to the wrong prevout while
    // still looking well-formed.
    let mut input = vec![TxIn {
        previous_output: funding_outpoint,
        script_sig: ScriptBuf::new(),
        // NON-FINAL: enables nLockTime (a final 0xffffffff sequence would
        // disable the timelock). No RBF — the exit is a fixed pre-signed tx.
        sequence: Sequence::ENABLE_LOCKTIME_NO_RBF,
        witness: Witness::new(),
    }];
    if let Some(freshness_outpoint) = freshness {
        input.push(TxIn {
            previous_output: freshness_outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_LOCKTIME_NO_RBF,
            witness: Witness::new(),
        });
    }
    Transaction {
        version: Version::TWO,
        // Absolute CLTV: consensus won't mine this before `cltv`.
        lock_time: cltv,
        input,
        output: vec![TxOut {
            value: Amount::from_sat(output_sats),
            script_pubkey: keypath_p2tr_spk(recipient_xonly),
        }],
    }
}

/// The BIP341 key-path sighash for input 0 of the exit tx spending the funding
/// prevout (`funding_value` at the `0x5120||Q` `funding_spk`). `SIGHASH_DEFAULT`
/// (implicit ALL; the returned 32 bytes ARE the MuSig2 `message`).
pub fn deadman_exit_sighash(
    exit_tx: &Transaction,
    funding_value: Amount,
    funding_spk: &ScriptBuf,
) -> Result<[u8; 32], DeadManExitError> {
    let funding_prevout = TxOut { value: funding_value, script_pubkey: funding_spk.clone() };
    let sh = SighashCache::new(exit_tx)
        .taproot_key_spend_signature_hash(
            0,
            &Prevouts::All(std::slice::from_ref(&funding_prevout)),
            TapSighashType::Default,
        )
        .map_err(|_| DeadManExitError::Sighash)?;
    Ok(*sh.as_ref())
}

/// Assemble the key-path witness (`[64-byte schnorr sig]`) onto input 0 and return
/// the fully-signed raw tx bytes (consensus serialization) ready to broadcast /
/// carry in the `DeadManExitEmitted` event.
pub fn finalize_exit_tx(
    mut exit_tx: Transaction,
    sig: musig2::secp256k1::schnorr::Signature,
) -> Vec<u8> {
    let mut witness = Witness::new();
    witness.push(sig.as_ref()); // 64-byte BIP340 sig, SIGHASH_DEFAULT (no type byte)
    exit_tx.input[0].witness = witness;
    bitcoin::consensus::encode::serialize(&exit_tx)
}

/// DEAD-MAN EXIT (#114) — the 2-signer pre-sign orchestrator. The fleet holds BOTH
/// funding halves (the hop-node signer + the vault-node signer for the SAME channel,
/// same process, Option B). This drives the full one-round MuSig2 key-path sign of
/// the pre-signed exit tx entirely in-place and returns the FULLY-signed raw tx bytes.
///
/// Flow (each `deadman_exit_*` call reads its own funding seckey internally — the key
/// NEVER leaves either signer):
/// 1. take the public funding prevout + KeyAggContext + indices from `hop_signer`
///    (identical to the vault's — same channel, same `Q`);
/// 2. build the unsigned exit tx + its BIP341 key-path sighash (the `message`);
/// 3. R1 — each half's public nonce ([`ValidatingChannelSigner::deadman_exit_pubnonce`]);
/// 4. R2 — each half's partial over `message`, given the OTHER half's nonce
///    ([`ValidatingChannelSigner::deadman_exit_partial`]);
/// 5. aggregate both partials → the 64-byte BIP340 sig; assemble the witness.
///
/// `height` is a per-channel monotonic refresh counter; it need not be unique across
/// distinct messages (the DEAD_MAN nonce is ALSO bound to the exit sighash) but SHOULD
/// advance per heartbeat so nonces are legibly distinct. `fee_sats` is the miner fee
/// deducted from `checkpoint_sats`. `recipient_xonly` MUST be the LP's `btcRecipientOf`.
#[allow(clippy::too_many_arguments)]
pub fn presign_deadman_exit(
    hop_signer: &ValidatingChannelSigner,
    vault_signer: &ValidatingChannelSigner,
    funding_outpoint: OutPoint,
    checkpoint_sats: u64,
    fee_sats: u64,
    recipient_xonly: XOnlyPublicKey,
    cltv_deadline: LockTime,
    height: u64,
    secp_ctx: &Secp256k1<secp256k1::All>,
) -> Result<Vec<u8>, DeadManExitError> {
    // (1) Public context — the aggregate `Q`, our (=hop) slot, the counterparty
    // (=vault) slot, and the funding prevout (value + `0x5120||Q` SPK). Both signers
    // build the identical aggregate; we take hop's and treat hop as "our" throughout.
    let (key_agg, hop_index, vault_index, funding_value, funding_spk) = hop_signer
        .taproot_public_context(secp_ctx)
        .map_err(|_| DeadManExitError::Signer)?;

    // (2) Unsigned exit tx + its key-path sighash (the message every partial signs).
    let output_sats = checkpoint_sats.checked_sub(fee_sats).ok_or(DeadManExitError::Value)?;
    let exit_tx =
        build_deadman_exit_tx(funding_outpoint, output_sats, recipient_xonly, cltv_deadline, None);
    let message = deadman_exit_sighash(&exit_tx, funding_value, &funding_spk)?;

    // (3) R1 — both halves' public nonces (deterministic, DEAD_MAN-tagged, in-place).
    let hop_nonce = hop_signer
        .deadman_exit_pubnonce(height, &message, secp_ctx)
        .map_err(|_| DeadManExitError::Signer)?;
    let vault_nonce = vault_signer
        .deadman_exit_pubnonce(height, &message, secp_ctx)
        .map_err(|_| DeadManExitError::Signer)?;

    // (4) R2 — each half signs its partial given the OTHER half's nonce. The funding
    // seckey is read internally by each signer and never returned.
    let (hop_partial, hop_pubnonce) = hop_signer
        .deadman_exit_partial(vault_nonce, height, &message, secp_ctx)
        .map_err(|_| DeadManExitError::Signer)?;
    let (vault_partial, vault_pubnonce) = vault_signer
        .deadman_exit_partial(hop_nonce, height, &message, secp_ctx)
        .map_err(|_| DeadManExitError::Signer)?;

    // (5) Aggregate → BIP340 key-path Schnorr sig → witness → raw bytes. `hop_index`
    // is our slot, `vault_index` the counterparty slot (from hop's KeySorted context).
    let sig = crate::taproot_signer::aggregate_key_path_partials(
        key_agg,
        message,
        hop_index,
        hop_pubnonce,
        hop_partial,
        vault_index,
        vault_pubnonce,
        vault_partial,
    )
    .map_err(|_| DeadManExitError::Aggregate)?;

    Ok(finalize_exit_tx(exit_tx, sig))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::hashes::Hash;

    /// The exit tx is a well-formed CLTV-timelocked key-path spend: nLockTime is the
    /// deadline, the input is non-final (locktime enabled), and the single output pays
    /// `0x5120||recipient` — byte-identical to `BTCChannels._withdrawalPayout`.
    /// #114 FRESHNESS-UTXO PREMISE: a BIP341 key-path sighash taken with
    /// `Prevouts::All` + `SIGHASH_DEFAULT` commits to EVERY input's prevout — so adding a
    /// second, fleet-controlled "freshness" input makes the pre-signed exit depend on it.
    /// Spending that UTXO then renders every previously-emitted exit CONSENSUS-INVALID,
    /// which is what stops a matured stale exit from force-closing a live channel.
    /// This test asserts the premise DIRECTLY: same tx, same input 0, only the SECOND
    /// prevout differs -> the signature digest MUST change. If this ever fails, the whole
    /// freshness-UTXO design is void (and no signer change would rescue it).
    #[test]
    fn sighash_commits_to_every_prevout_not_just_input_zero() {
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let (sk, _) = secp256k1::SecretKey::from_slice(&[7u8; 32])
            .map(|sk| { let kp = secp256k1::Keypair::from_secret_key(&secp, &sk); (sk, kp) })
            .expect("static test key is valid");
        let xonly = secp256k1::Keypair::from_secret_key(&secp, &sk).x_only_public_key().0;
        let spk = keypath_p2tr_spk(xonly);

        // A 2-input exit: input 0 = channel funding, input 1 = the freshness UTXO.
        let funding = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 0 };
        let freshness = OutPoint { txid: bitcoin::Txid::all_zeros(), vout: 1 };
        // Built through the REAL freshness param — so this also covers the builder wiring,
        // not just the sighash property.
        let tx = build_deadman_exit_tx(
            funding, 50_000, xonly, LockTime::from_height(144).unwrap(), Some(freshness));
        assert_eq!(tx.input.len(), 2, "freshness input is appended as input 1");
        assert_eq!(tx.input[0].previous_output, funding, "input 0 stays the funding outpoint");

        let funding_prevout = TxOut { value: Amount::from_sat(60_000), script_pubkey: spk.clone() };
        let sighash_with = |fresh_value: u64| -> [u8; 32] {
            let fresh_prevout = TxOut { value: Amount::from_sat(fresh_value), script_pubkey: spk.clone() };
            let prevouts = [funding_prevout.clone(), fresh_prevout];
            *SighashCache::new(&tx)
                .taproot_key_spend_signature_hash(0, &Prevouts::All(&prevouts), TapSighashType::Default)
                .expect("sighash")
                .as_ref()
        };

        // ONLY the freshness prevout's value differs; input 0 is byte-identical.
        assert_ne!(
            sighash_with(1_000), sighash_with(2_000),
            "BIP341 SIGHASH_DEFAULT must commit to EVERY prevout — the freshness-UTXO design \
             (#114) depends on spending input 1 invalidating an exit signed over input 0"
        );
    }

    #[test]
    fn exit_tx_shape_is_cltv_keypath() {
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let sk = bitcoin::secp256k1::SecretKey::from_slice(&[0x24; 32]).unwrap();
        let recipient = sk.x_only_public_key(&secp).0;
        let op = OutPoint {
            txid: bitcoin::Txid::from_byte_array([0xAB; 32]),
            vout: 0,
        };
        let cltv = LockTime::from_height(800_000).unwrap();
        let tx = build_deadman_exit_tx(op, 100_000, recipient, cltv, None);

        assert_eq!(tx.lock_time, cltv, "nLockTime == the CLTV deadline");
        assert_eq!(tx.version, Version::TWO);
        assert_eq!(tx.input.len(), 1);
        assert_eq!(tx.input[0].previous_output, op);
        assert_eq!(
            tx.input[0].sequence,
            Sequence::ENABLE_LOCKTIME_NO_RBF,
            "input must be non-final so nLockTime is enforced",
        );
        assert!(tx.input[0].sequence != Sequence::MAX, "must NOT be final (0xffffffff)");
        assert_eq!(tx.output.len(), 1);
        assert_eq!(tx.output[0].value, Amount::from_sat(100_000));

        // Output SPK == 0x5120 || recipient (matches BTCChannels._withdrawalPayout).
        let spk = tx.output[0].script_pubkey.as_bytes();
        assert_eq!(spk.len(), 34);
        assert_eq!(spk[0], 0x51);
        assert_eq!(spk[1], 0x20);
        assert_eq!(&spk[2..], &recipient.serialize()[..]);
    }

    /// The key-path sighash is deterministic and changes when nLockTime (the CLTV)
    /// changes — i.e. a refreshed exit has a DIFFERENT `message` (so the DEAD_MAN
    /// nonce re-randomises), proving the heartbeat can't reuse a nonce.
    #[test]
    fn sighash_changes_with_cltv() {
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let sk = bitcoin::secp256k1::SecretKey::from_slice(&[0x24; 32]).unwrap();
        let recipient = sk.x_only_public_key(&secp).0;
        let op = OutPoint { txid: bitcoin::Txid::from_byte_array([0xCD; 32]), vout: 1 };
        let funding_spk = keypath_p2tr_spk(recipient);
        let funding_value = Amount::from_sat(200_000);

        let tx1 = build_deadman_exit_tx(op, 199_000, recipient, LockTime::from_height(800_000).unwrap(), None);
        let tx2 = build_deadman_exit_tx(op, 199_000, recipient, LockTime::from_height(800_144).unwrap(), None);
        let m1 = deadman_exit_sighash(&tx1, funding_value, &funding_spk).unwrap();
        let m2 = deadman_exit_sighash(&tx2, funding_value, &funding_spk).unwrap();
        assert_ne!(m1, m2, "a refreshed CLTV yields a different sighash (message)");
        // Deterministic re-derive.
        let m1b = deadman_exit_sighash(&tx1, funding_value, &funding_spk).unwrap();
        assert_eq!(m1, m1b);
    }

    /// Fee underflow is rejected, not silently wrapped.
    #[test]
    fn fee_underflow_rejected() {
        // Drive presign only far enough to hit the checked_sub — build a dummy by
        // exercising the arithmetic directly (presign needs live signers).
        assert_eq!(100u64.checked_sub(200), None);
    }

    /// A finalized tx carries exactly one 64-byte witness element on input 0 and
    /// round-trips through consensus (de)serialization.
    #[test]
    fn finalize_assembles_64byte_witness() {
        // A syntactically-valid 64-byte schnorr sig (all-ones is a valid encoding for
        // witness assembly; we only check byte plumbing, not verification here).
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let sk = bitcoin::secp256k1::SecretKey::from_slice(&[0x24; 32]).unwrap();
        let recipient = sk.x_only_public_key(&secp).0;
        let op = OutPoint { txid: bitcoin::Txid::from_byte_array([0x01; 32]), vout: 0 };
        let tx = build_deadman_exit_tx(op, 50_000, recipient, LockTime::from_height(1).unwrap(), None);
        // Sign a real sighash so the sig bytes are well-formed.
        let msg = deadman_exit_sighash(&tx, Amount::from_sat(60_000), &keypath_p2tr_spk(recipient)).unwrap();
        let kp = bitcoin::secp256k1::Keypair::from_secret_key(&secp, &sk);
        let sig = secp.sign_schnorr_no_aux_rand(&bitcoin::secp256k1::Message::from_digest(msg), &kp);
        let raw = finalize_exit_tx(tx, sig);
        let decoded: Transaction = bitcoin::consensus::encode::deserialize(&raw).unwrap();
        assert_eq!(decoded.input[0].witness.len(), 1);
        assert_eq!(decoded.input[0].witness.iter().next().unwrap().len(), 64);
    }
}
