//! On-chain (non-LN) swap-in — **Design A, enclave-trusted** taproot primitives.
//!
//! The regular-BTC ingress: a user (or an LP funding their own channel) sends
//! PLAIN on-chain BTC — not a Lightning HTLC — to a per-swap taproot deposit address.
//! The trusted hop watches the address, and once the deposit buries under N confs runs
//! the SAME settle-then-claim contract the LN rail uses (`swap.rs` / `swap_in.rs`):
//! deliver the USD on the EVM via `settleSwapIn` FIRST, then take the BTC.
//!
//! ## Why this shape (see the locked design decision, 2026-07-13)
//!
//! The deposit is a P2TR output with:
//!   * **internal key = the HOP key** ⇒ the hop claims unilaterally by KEY PATH (a bare
//!     BIP340 signature, no script revealed) once it has delivered the USD; and
//!   * **exactly ONE script leaf = the USER's CLTV refund** — `<cltv> OP_CLTV OP_DROP
//!     <userKey> OP_CHECKSIG` — so if the hop never settles, the user reclaims their BTC
//!     after the timelock, trustlessly, via the script path.
//!
//! There is **no hashlock / preimage**: under enclave-trust the hop is the settlement
//! authority (identical to how the LN swap-in already trusts the hop), so a hashlock
//! would be machinery doing no work — the prover controls the preimage. Full
//! trustlessness would need SPV-proof-of-deposit on the EVM, which the LN rail doesn't
//! have either; Design A deliberately matches the existing trust boundary.
//!
//! This module is the PURE, unit-tested core (address construction, the hop's key-path
//! claim, the user's refund control block) — built entirely on rust-bitcoin's audited
//! taproot APIs (`TaprootBuilder`, `SighashCache`, BIP341 tweak). The watcher/driver that
//! calls `settleSwapIn` and broadcasts the claim lives in the daemon (`quid-bridge`),
//! mirroring `swap_out_onchain.rs`.

use bitcoin::absolute::LockTime;
use bitcoin::key::{TapTweak, XOnlyPublicKey};
use bitcoin::opcodes::all as opc;
use bitcoin::script::Builder;
use bitcoin::secp256k1::{schnorr, Keypair, Message, Secp256k1, Signing, Verification};
use bitcoin::sighash::{Prevouts, SighashCache, TapSighashType};
use bitcoin::taproot::{ControlBlock, LeafVersion, TapLeafHash, TaprootBuilder, TaprootSpendInfo};
use bitcoin::transaction::Version;
use bitcoin::{
    Address, Amount, Network, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Witness,
};

/// Errors constructing/spending a swap-in deposit. All are constructor-time or
/// obviously-programmer-error conditions (never attacker-triggerable at watch time).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SwapInOnchainError {
    /// `TaprootBuilder::add_leaf` rejected the (depth, script) — impossible for our
    /// single depth-0 leaf, but surfaced rather than unwrapped.
    LeafInsert,
    /// `TaprootBuilder::finalize` could not tweak the tree (e.g. incomplete builder).
    Finalize,
    /// The sighash cache rejected the input index / prevouts (malformed claim tx).
    Sighash,
    /// The spend info had no control block for the refund leaf (tree mismatch).
    NoControlBlock,
    /// BIP32 derivation of the per-swap deposit key failed (bad index/master).
    Derive,
}

/// The user's CLTV refund leaf: `<cltv> OP_CHECKLOCKTIMEVERIFY OP_DROP <userKey>
/// OP_CHECKSIG`. Spendable only by `user_refund` and only once the tx's `nLockTime`
/// reaches `cltv` (the hop's window to settle+claim by key path has elapsed).
pub fn refund_leaf(user_refund: XOnlyPublicKey, cltv: LockTime) -> ScriptBuf {
    Builder::new()
        .push_int(i64::from(cltv.to_consensus_u32()))
        .push_opcode(opc::OP_CLTV)
        .push_opcode(opc::OP_DROP)
        .push_x_only_key(&user_refund)
        .push_opcode(opc::OP_CHECKSIG)
        .into_script()
}

/// Build the taproot spend-info for a deposit: internal key = `hop_internal` (key-path
/// claim), single leaf = the user's CLTV refund. Returns the spend-info + the leaf
/// script (needed later for the refund control block / leaf hash).
pub fn deposit_spend_info<C: Verification>(
    secp: &Secp256k1<C>,
    hop_internal: XOnlyPublicKey,
    user_refund: XOnlyPublicKey,
    cltv: LockTime,
) -> Result<(TaprootSpendInfo, ScriptBuf), SwapInOnchainError> {
    let leaf = refund_leaf(user_refund, cltv);
    let spend_info = TaprootBuilder::new()
        .add_leaf(0, leaf.clone())
        .map_err(|_| SwapInOnchainError::LeafInsert)?
        .finalize(secp, hop_internal)
        .map_err(|_| SwapInOnchainError::Finalize)?;
    Ok((spend_info, leaf))
}

/// The address the user pays: P2TR over the BIP341-tweaked output key. Callers derive
/// `spend_info` once via [`deposit_spend_info`] and reuse it for the claim/refund.
pub fn deposit_address(spend_info: &TaprootSpendInfo, network: Network) -> Address {
    Address::p2tr_tweaked(spend_info.output_key(), network)
}

/// Build the hop's KEY-PATH claim tx: spends the deposit `outpoint` (worth `value`) to
/// `dest_spk` (the hop's own wallet), paying `fee`. No timelock (the hop claims
/// immediately after settle); RBF-enabled so the hop can bump if the mempool is full.
pub fn build_claim_tx(
    outpoint: OutPoint,
    value: Amount,
    fee: Amount,
    dest_spk: ScriptBuf,
) -> Transaction {
    build_claim_tx_with_refund(outpoint, value, fee, dest_spk, None)
}

/// Build the hop's key-path claim tx WITH an optional second output that REFUNDS the
/// pool-couldn't-convert remainder back to the seller. On an inventory-bounded partial
/// swap-in (`consumedSats < sats`) the hop delivered USD for only part of the deposit, so
/// it returns the unconverted BTC rather than taking it: `refund = Some(txout)` appends
/// that output and funds the hop's own output from `value − fee − refund.value`;
/// `refund = None` is the plain single-output claim (equivalent to [`build_claim_tx`]).
/// The caller (`quid-bridge`) drops a dust-sized refund to `None` before calling.
///
/// The key-path signature is `SIGHASH_DEFAULT` (implicit ALL), so it commits to BOTH
/// outputs — the hop cannot strip the refund after signing without invalidating its own
/// claim.
pub fn build_claim_tx_with_refund(
    outpoint: OutPoint,
    value: Amount,
    fee: Amount,
    dest_spk: ScriptBuf,
    refund: Option<TxOut>,
) -> Transaction {
    let refund_value = refund.as_ref().map_or(Amount::ZERO, |r| r.value);
    let mut output = vec![TxOut { value: value - fee - refund_value, script_pubkey: dest_spk }];
    if let Some(r) = refund {
        output.push(r);
    }
    Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::new(),
        }],
        output,
    }
}

/// The BIP341 key-spend sighash for input 0 of a claim tx spending `deposit` (the funded
/// P2TR output). `SIGHASH_DEFAULT` (implicit ALL, 64-byte sig, no type byte).
pub fn key_path_sighash(
    claim_tx: &Transaction,
    deposit: &TxOut,
) -> Result<Message, SwapInOnchainError> {
    let sh = SighashCache::new(claim_tx)
        .taproot_key_spend_signature_hash(
            0,
            &Prevouts::All(std::slice::from_ref(deposit)),
            TapSighashType::Default,
        )
        .map_err(|_| SwapInOnchainError::Sighash)?;
    Ok(Message::from(sh))
}

/// Sign the key-path claim with the hop's keypair, BIP341-tweaked by the tree's merkle
/// root, and return the finished witness (`[64-byte schnorr sig]`). Deterministic
/// (no-aux-rand) so the same claim always produces the same tx — friendly to the
/// idempotent re-drive on restart.
pub fn key_path_witness<C: Signing + Verification>(
    secp: &Secp256k1<C>,
    hop_keypair: &Keypair,
    spend_info: &TaprootSpendInfo,
    sighash: &Message,
) -> Witness {
    let tweaked = hop_keypair.tap_tweak(secp, spend_info.merkle_root());
    let sig = secp.sign_schnorr_no_aux_rand(sighash, &tweaked.to_keypair());
    let mut w = Witness::new();
    w.push(sig.as_ref());
    w
}

/// The control block the USER attaches to a script-path refund spend of the CLTV leaf.
/// `None` only if `leaf` isn't in `spend_info` (programmer error).
pub fn refund_control_block(
    spend_info: &TaprootSpendInfo,
    leaf: &ScriptBuf,
) -> Result<ControlBlock, SwapInOnchainError> {
    spend_info
        .control_block(&(leaf.clone(), LeafVersion::TapScript))
        .ok_or(SwapInOnchainError::NoControlBlock)
}

/// Build the user's refund tx: spends the deposit back to the user's `dest_spk` after
/// the timelock. `nLockTime = cltv` and the input sequence enables locktime (not final),
/// so consensus enforces the CLTV in the leaf.
pub fn build_refund_tx(
    outpoint: OutPoint,
    value: Amount,
    fee: Amount,
    dest_spk: ScriptBuf,
    cltv: LockTime,
) -> Transaction {
    Transaction {
        version: Version::TWO,
        lock_time: cltv,
        input: vec![TxIn {
            previous_output: outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_LOCKTIME_NO_RBF,
            witness: Witness::new(),
        }],
        output: vec![TxOut { value: value - fee, script_pubkey: dest_spk }],
    }
}

/// The BIP341 SCRIPT-path sighash for input 0 of a refund tx spending `deposit` via the
/// CLTV `leaf`. `SIGHASH_DEFAULT`.
pub fn refund_sighash(
    refund_tx: &Transaction,
    deposit: &TxOut,
    leaf: &ScriptBuf,
) -> Result<Message, SwapInOnchainError> {
    let leaf_hash = TapLeafHash::from_script(leaf, LeafVersion::TapScript);
    let sh = SighashCache::new(refund_tx)
        .taproot_script_spend_signature_hash(
            0,
            &Prevouts::All(std::slice::from_ref(deposit)),
            leaf_hash,
            TapSighashType::Default,
        )
        .map_err(|_| SwapInOnchainError::Sighash)?;
    Ok(Message::from(sh))
}

/// Finish the user's refund witness: `[userSig, leafScript, controlBlock]` — the standard
/// tapscript spend stack.
pub fn refund_witness(
    user_sig: &schnorr::Signature,
    leaf: &ScriptBuf,
    control_block: &ControlBlock,
) -> Witness {
    let mut w = Witness::new();
    w.push(user_sig.as_ref());
    w.push(leaf.as_bytes());
    w.push(control_block.serialize());
    w
}

// ═══════════════════ hop deposit-key derivation (from the node's BIP32 master) ═══════════════════
//
// The deposit's internal key is a PER-SWAP hop key derived from the SAME root the node
// already holds (`master_xprv`), at a dedicated hardened branch
// `m/{SWAP_IN_DEPOSIT_ACCOUNT}'/{swapIndex}'`. Per-swap (not one static hop key) so a
// leaked deposit key can't touch another swap, and so the key is deterministically
// RE-DERIVABLE from the persisted swap index on restart — no extra secret to store.
// Built on rust-bitcoin's audited BIP32 (`Xpriv::derive_priv`); no hand-rolled derivation.

use bitcoin::bip32::{ChildNumber, DerivationPath, Xpriv};

/// Dedicated HARDENED BIP32 account for swap-in deposit keys — disjoint from the wallet's
/// BIP86 receive/change branches (`m/86'/…`), so a deposit key is never a wallet address.
pub const SWAP_IN_DEPOSIT_ACCOUNT: u32 = 70;

/// The ONE hardened index the pinned deposit internal key lives at.
///
/// 🔴 (E183) **THIS USED TO BE THE PER-SWAP INDEX, AND THAT MADE THE TWO HALVES OF §E159
/// MUTUALLY INCOMPATIBLE.** The contract pins ONE `BTC_DEPOSIT_KEY` at construction and
/// derives each deposit address as `TapTweak(BTC_DEPOSIT_KEY, leaf(userRefund, cltvHeight))`
/// — per-swap uniqueness lives in the **LEAF**. Rust derived a per-swap INTERNAL key at
/// `m/70'/swap_index'`, so the address it generated was never the address the contract
/// recomputes, and `verifySwapInDeposit` would reject every real deposit.
///
/// 🔑 **THE CONTRADICTION WAS STRUCTURAL, NOT A TYPO, WHICH IS WHY THE CONTRACT WINS.**
/// A hardened per-swap key is *by definition* underivable from any xpub — so the contract
/// could never recompute it and would have to be **told** it by the hop. A hop-supplied
/// internal key is a hop-chosen address, which reopens the exact phantom-swap-in hole
/// §E159 exists to close: SPV-prove a genuine payment to a script you control, collect USD
/// for BTC that never entered custody. **Verifiability has to win over key isolation here,
/// because the phantom credit reaches QU!D holders who never opted into enclave trust.**
///
/// ✅ **AND NOTHING IS ACTUALLY GIVEN UP.** The property the hardened path was for — *"a
/// deposit key is never a wallet address"*, disjoint from the BIP86 branches — is kept in
/// full: the key is still derived at a HARDENED `m/70'/0'`, still outside `m/86'/…`, still
/// underivable from the wallet xpub. Only the per-swap *index* moves, and per-swap
/// uniqueness is not lost — it moves to the leaf, so every deposit still gets a DISTINCT
/// output key (`TapTweak` over a different merkle root each time).
pub const PINNED_DEPOSIT_INDEX: u32 = 0;

/// Derive the PINNED hop deposit internal key at `m/SWAP_IN_DEPOSIT_ACCOUNT'/0'`.
///
/// This is the key whose x-only form is pinned on-chain as `BTCChannels.BTC_DEPOSIT_KEY`.
/// ⚠️ It takes no `swap_index` ON PURPOSE — see [`PINNED_DEPOSIT_INDEX`]. Re-introducing one
/// silently un-verifies every deposit.
pub fn derive_deposit_key<C: Signing>(
    secp: &Secp256k1<C>,
    master: &Xpriv,
) -> Result<Keypair, SwapInOnchainError> {
    let path = DerivationPath::from(vec![
        ChildNumber::from_hardened_idx(SWAP_IN_DEPOSIT_ACCOUNT)
            .map_err(|_| SwapInOnchainError::Derive)?,
        ChildNumber::from_hardened_idx(PINNED_DEPOSIT_INDEX)
            .map_err(|_| SwapInOnchainError::Derive)?,
    ]);
    let xpriv = master.derive_priv(secp, &path).map_err(|_| SwapInOnchainError::Derive)?;
    Ok(Keypair::from_secret_key(secp, &xpriv.private_key))
}

/// Build the deposit (address + spend-info + refund leaf) from the hop master + the user's
/// refund key + timelock. The one call the registration API and the watcher share — so both
/// derive the SAME address for a given swap.
///
/// ⚠️ **There is no `swap_index` parameter, and that absence is §E183's fix made structural.**
/// Per-swap uniqueness lives in the LEAF (`user_refund`, `cltv`), not in the internal key: the
/// contract derives `TapTweak(BTC_DEPOSIT_KEY, leaf(...))` from ONE pinned key, so a per-swap
/// internal key produced an address the contract could never recompute. The parameter survived
/// as an ignored `_swap_index` after that fix — dead weight that still read as if it selected
/// something. Taking it away means a caller cannot pass one, rather than passing one that is
/// silently discarded.
pub fn deposit_for<C: Signing + Verification>(
    secp: &Secp256k1<C>,
    master: &Xpriv,
    user_refund: XOnlyPublicKey,
    cltv: LockTime,
    network: Network,
) -> Result<(Address, TaprootSpendInfo, ScriptBuf), SwapInOnchainError> {
    let hop = derive_deposit_key(secp, master)?;
    let (hop_x, _) = hop.x_only_public_key();
    let (si, leaf) = deposit_spend_info(secp, hop_x, user_refund, cltv)?;
    Ok((deposit_address(&si, network), si, leaf))
}

/// Sign the hop's KEY-PATH claim of a deposit, returning the claim tx with its witness
/// attached. Re-derives the PINNED deposit key + this swap's spend-info from the master, so the
/// watcher needs only the persisted swap params (`user_refund`/`cltv`) — never a stored secret.
/// `claim_tx` comes from [`build_claim_tx`]; `deposit` is its funded prevout.
///
/// ⚠️ The doc here used to say *"re-derives the per-swap key"* and list `index` among the params
/// it needs. Both were false after §E183 pinned the internal key — see [`deposit_for`]. The
/// parameter is gone with the sentence.
pub fn sign_claim<C: Signing + Verification>(
    secp: &Secp256k1<C>,
    master: &Xpriv,
    user_refund: XOnlyPublicKey,
    cltv: LockTime,
    mut claim_tx: Transaction,
    deposit: &TxOut,
) -> Result<Transaction, SwapInOnchainError> {
    let hop = derive_deposit_key(secp, master)?;
    let (hop_x, _) = hop.x_only_public_key();
    let (si, _leaf) = deposit_spend_info(secp, hop_x, user_refund, cltv)?;
    let sighash = key_path_sighash(&claim_tx, deposit)?;
    claim_tx.input[0].witness = key_path_witness(secp, &hop, &si, &sighash);
    Ok(claim_tx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::bip32::Xpriv;
    use bitcoin::hashes::Hash;
    use bitcoin::secp256k1::SecretKey;

    fn master() -> Xpriv {
        Xpriv::new_master(Network::Regtest, &[0x42; 32]).unwrap()
    }

    fn kp(secp: &Secp256k1<bitcoin::secp256k1::All>, b: u8) -> Keypair {
        let sk = SecretKey::from_slice(&[b; 32]).unwrap();
        Keypair::from_secret_key(secp, &sk)
    }

    fn a_deposit(spend_info: &TaprootSpendInfo, sats: u64) -> (OutPoint, TxOut) {
        let op = OutPoint {
            txid: bitcoin::Txid::from_slice(&[0x11; 32]).unwrap(),
            vout: 0,
        };
        let txout = TxOut {
            value: Amount::from_sat(sats),
            script_pubkey: ScriptBuf::new_p2tr_tweaked(spend_info.output_key()),
        };
        (op, txout)
    }

    #[test]
    fn deposit_address_is_p2tr_over_the_tweaked_output_key() {
        let secp = Secp256k1::new();
        let (hop_x, _) = kp(&secp, 0x22).x_only_public_key();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let cltv = LockTime::from_height(800_000).unwrap();
        let (si, _leaf) = deposit_spend_info(&secp, hop_x, usr_x, cltv).unwrap();

        let addr = deposit_address(&si, Network::Regtest);
        assert!(addr.script_pubkey().is_p2tr());
        // The address commits to the tweaked OUTPUT key (internal ⊕ tree), not the raw hop key.
        assert_eq!(
            addr.script_pubkey(),
            ScriptBuf::new_p2tr_tweaked(si.output_key())
        );
        assert_ne!(si.output_key().to_x_only_public_key(), hop_x, "output key must be tweaked, not the bare hop key");
    }

    #[test]
    fn hop_key_path_claim_verifies_against_the_output_key() {
        let secp = Secp256k1::new();
        let hop = kp(&secp, 0x22);
        let (hop_x, _) = hop.x_only_public_key();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let cltv = LockTime::from_height(800_000).unwrap();
        let (si, _leaf) = deposit_spend_info(&secp, hop_x, usr_x, cltv).unwrap();
        let (op, deposit) = a_deposit(&si, 100_000);

        let dest = ScriptBuf::new_p2tr_tweaked(si.output_key()); // any spk for the test
        let claim = build_claim_tx(op, deposit.value, Amount::from_sat(300), dest);
        let msg = key_path_sighash(&claim, &deposit).unwrap();
        let w = key_path_witness(&secp, &hop, &si, &msg);

        assert_eq!(w.len(), 1, "key-path witness is a single 64-byte sig");
        let sig = schnorr::Signature::from_slice(&w[0]).unwrap();
        // The claim is spendable by KEY PATH: valid under the tweaked output x-only key.
        secp.verify_schnorr(&sig, &msg, &si.output_key().to_x_only_public_key())
            .expect("hop's key-path claim must verify against the output key");
    }

    #[test]
    fn user_refund_script_path_verifies_and_control_block_belongs_to_the_leaf() {
        let secp = Secp256k1::new();
        let (hop_x, _) = kp(&secp, 0x22).x_only_public_key();
        let usr = kp(&secp, 0x33);
        let (usr_x, _) = usr.x_only_public_key();
        let cltv = LockTime::from_height(800_000).unwrap();
        let (si, leaf) = deposit_spend_info(&secp, hop_x, usr_x, cltv).unwrap();
        let (op, deposit) = a_deposit(&si, 100_000);

        let dest = ScriptBuf::new_p2tr_tweaked(si.output_key());
        let refund = build_refund_tx(op, deposit.value, Amount::from_sat(300), dest, cltv);
        assert_eq!(refund.lock_time, cltv, "refund must set nLockTime = cltv");
        assert_ne!(refund.input[0].sequence, Sequence::MAX, "sequence must enable locktime");

        let msg = refund_sighash(&refund, &deposit, &leaf).unwrap();
        let sig = secp.sign_schnorr_no_aux_rand(&msg, &usr);
        // User's leaf key signs; verifies against the USER x-only key (the leaf's OP_CHECKSIG key).
        secp.verify_schnorr(&sig, &msg, &usr_x)
            .expect("user's script-path refund sig must verify against the leaf key");

        // The control block proves the leaf is committed in the tree under the internal key.
        let cb = refund_control_block(&si, &leaf).unwrap();
        assert!(
            cb.verify_taproot_commitment(&secp, si.output_key().to_x_only_public_key(), &leaf),
            "control block must prove the CLTV leaf is in the deposit's script tree"
        );
        let w = refund_witness(&sig, &leaf, &cb);
        assert_eq!(w.len(), 3, "tapscript refund witness = [sig, leaf, controlBlock]");
    }

    #[test]
    fn refund_leaf_encodes_cltv_and_user_key() {
        let secp = Secp256k1::new();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let cltv = LockTime::from_height(777_000).unwrap();
        let leaf = refund_leaf(usr_x, cltv);
        let asm = leaf.to_asm_string();
        assert!(asm.contains("OP_CLTV"), "leaf must gate on CLTV: {asm}");
        assert!(asm.contains("OP_CHECKSIG"), "leaf must end in OP_CHECKSIG: {asm}");
        // The user key bytes appear as a 32-byte push.
        assert!(leaf.as_bytes().windows(32).any(|w| w == usr_x.serialize()));
    }

    #[test]
    fn distinct_cltv_or_user_yields_a_distinct_deposit_address() {
        let secp = Secp256k1::new();
        let (hop_x, _) = kp(&secp, 0x22).x_only_public_key();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let (usr2_x, _) = kp(&secp, 0x44).x_only_public_key();
        let c1 = LockTime::from_height(800_000).unwrap();
        let c2 = LockTime::from_height(800_001).unwrap();
        let a = deposit_address(&deposit_spend_info(&secp, hop_x, usr_x, c1).unwrap().0, Network::Regtest);
        let b = deposit_address(&deposit_spend_info(&secp, hop_x, usr_x, c2).unwrap().0, Network::Regtest);
        let d = deposit_address(&deposit_spend_info(&secp, hop_x, usr2_x, c1).unwrap().0, Network::Regtest);
        assert_ne!(a, b, "different CLTV ⇒ different address");
        assert_ne!(a, d, "different user refund key ⇒ different address");
    }

    #[test]
    fn deposit_key_is_deterministic_and_index_scoped() {
        let secp = Secp256k1::new();
        let m = master();
        // 🔴 (E183) THIS TEST USED TO ASSERT THE OPPOSITE — that a different `swap_index`
        // gives an ISOLATED key. That is exactly what made the Rust deposit address
        // unverifiable by the contract, which pins ONE `BTC_DEPOSIT_KEY` and puts per-swap
        // uniqueness in the CLTV LEAF. New invariant: ONE pinned key, re-derivable, with no
        // swap index anywhere near it.
        let a1 = derive_deposit_key(&secp, &m).unwrap();
        let a2 = derive_deposit_key(&secp, &m).unwrap();
        assert_eq!(a1.secret_bytes(), a2.secret_bytes(),
                   "the pinned deposit key must be re-derivable on demand");

        // ⚠️ PER-SWAP UNIQUENESS IS NOT LOST — IT MOVED. Two swaps differing only in their
        // refund leaf must still give DIFFERENT deposit addresses, or every swap shares one
        // address and dedup/attribution collapses.
        let user_a = Keypair::from_seckey_slice(&secp, &[0x11u8; 32]).unwrap()
            .x_only_public_key().0;
        let user_b = Keypair::from_seckey_slice(&secp, &[0x22u8; 32]).unwrap()
            .x_only_public_key().0;
        let cltv = LockTime::from_height(800_000).unwrap();
        let (si_a, _) = deposit_spend_info(&secp, a1.x_only_public_key().0, user_a, cltv).unwrap();
        let (si_b, _) = deposit_spend_info(&secp, a1.x_only_public_key().0, user_b, cltv).unwrap();
        assert_ne!(si_a.output_key(), si_b.output_key(),
                   "a different refund leaf must still give a different deposit address");
    }

    #[test]
    fn claim_with_refund_appends_output_and_still_verifies() {
        let secp = Secp256k1::new();
        let m = master();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let cltv = LockTime::from_height(800_000).unwrap();
        let (addr, si, _leaf) = deposit_for(&secp, &m, usr_x, cltv, Network::Regtest).unwrap();

        let deposit = TxOut { value: Amount::from_sat(1_000_000), script_pubkey: addr.script_pubkey() };
        let outpoint = OutPoint { txid: bitcoin::Txid::from_slice(&[0x9; 32]).unwrap(), vout: 0 };
        let dest = ScriptBuf::new_p2tr_tweaked(si.output_key());
        let fee = Amount::from_sat(400);

        // No refund ⇒ single output identical to build_claim_tx.
        let plain = build_claim_tx_with_refund(outpoint, deposit.value, fee, dest.clone(), None);
        assert_eq!(plain.output.len(), 1);
        assert_eq!(plain, build_claim_tx(outpoint, deposit.value, fee, dest.clone()));

        // With a refund ⇒ two outputs; the hop's output is value − fee − refund and the
        // refund output carries exactly `refund`.
        let refund_spk = ScriptBuf::new_p2tr(&secp, usr_x, None);
        let refund_val = Amount::from_sat(250_000);
        let tx = build_claim_tx_with_refund(
            outpoint,
            deposit.value,
            fee,
            dest.clone(),
            Some(TxOut { value: refund_val, script_pubkey: refund_spk.clone() }),
        );
        assert_eq!(tx.output.len(), 2, "refund appends a second output");
        assert_eq!(tx.output[0].value, deposit.value - fee - refund_val, "hop output funds from the remainder");
        assert_eq!(tx.output[1].value, refund_val);
        assert_eq!(tx.output[1].script_pubkey, refund_spk);

        // The hop's key-path signature over the TWO-output tx still verifies (SIGHASH ALL
        // commits to the refund output, so it can't be stripped after signing).
        let signed = sign_claim(&secp, &m, usr_x, cltv, tx, &deposit).unwrap();
        let sig = schnorr::Signature::from_slice(&signed.input[0].witness[0]).unwrap();
        let msg = key_path_sighash(&signed, &deposit).unwrap();
        secp.verify_schnorr(&sig, &msg, &si.output_key().to_x_only_public_key())
            .expect("two-output claim must still verify by key path");
    }

    #[test]
    fn deposit_for_then_sign_claim_round_trips() {
        let secp = Secp256k1::new();
        let m = master();
        let (usr_x, _) = kp(&secp, 0x33).x_only_public_key();
        let cltv = LockTime::from_height(800_000).unwrap();

        // Registration side: derive the address the user pays.
        let (addr, si, _leaf) = deposit_for(&secp, &m, usr_x, cltv, Network::Regtest).unwrap();
        assert!(addr.script_pubkey().is_p2tr());

        // Watcher side: a deposit lands at that address; the hop signs the key-path claim.
        let deposit = TxOut { value: Amount::from_sat(250_000), script_pubkey: addr.script_pubkey() };
        let outpoint = OutPoint { txid: bitcoin::Txid::from_slice(&[0x9; 32]).unwrap(), vout: 1 };
        let dest = ScriptBuf::new_p2tr_tweaked(si.output_key());
        let claim = build_claim_tx(outpoint, deposit.value, Amount::from_sat(400), dest);
        let signed = sign_claim(&secp, &m, usr_x, cltv, claim, &deposit).unwrap();

        assert_eq!(signed.input[0].witness.len(), 1, "single key-path sig");
        let sig = schnorr::Signature::from_slice(&signed.input[0].witness[0]).unwrap();
        let msg = key_path_sighash(&signed, &deposit).unwrap();
        secp.verify_schnorr(&sig, &msg, &si.output_key().to_x_only_public_key())
            .expect("the derived hop key's claim must verify against the deposit's output key");
    }

    /// (§T2) CROSS-IMPLEMENTATION CHECK ON `MuSig2Agg.tapBranch` — the one the Solidity suite
    /// structurally cannot make.
    ///
    /// 🔑 **WHY THIS TEST IS IN RUST.** `TapBranch.t.sol` verifies the construction against a
    /// second implementation, but BOTH are ours: they could agree perfectly on the shape and be
    /// jointly wrong about the TAG STRING, which does not revert — it yields a well-formed merkle
    /// root, a well-formed P2TR address, and a deposit nobody will ever pay. `rust-bitcoin`'s
    /// `TapNodeHash` is an INDEPENDENT, consensus-tested implementation of BIP-341, so agreeing
    /// with it is the check that actually binds.
    ///
    /// The fixture is shared verbatim with `evm/test/TapBranch.t.sol`
    /// (`keccak256("leaf-a")` / `keccak256("leaf-b")`), so the two suites pin ONE value.
    /// ⚠️ If this ever fails, do NOT "fix" it by repinning the constant — a divergence here means
    /// the Solidity side computes an address Bitcoin does not, and every swap-in built on it
    /// would be unspendable rather than merely wrong.
    #[test]
    fn tap_branch_agrees_with_rust_bitcoin() {
        use bitcoin::taproot::TapNodeHash;

        let a: [u8; 32] = hex_lit_a();
        let b: [u8; 32] = hex_lit_b();

        let got = TapNodeHash::from_node_hashes(
            TapNodeHash::from_byte_array(a),
            TapNodeHash::from_byte_array(b),
        );

        // Produced by BOTH `MuSig2Agg.tapBranch(a, b)` and an independent python rebuild of
        // BIP-340's tagged hash: sha256(sha256("TapBranch") || sha256("TapBranch") || min || max).
        let expected: [u8; 32] = [
            0x21, 0x0f, 0x9a, 0x7d, 0x98, 0x06, 0x26, 0xb9, 0x55, 0x6b, 0xbc, 0x01, 0xc6, 0xa1,
            0xbb, 0xf0, 0xa3, 0xaa, 0x31, 0x1f, 0x8b, 0xa3, 0x61, 0x81, 0xae, 0x64, 0x77, 0xa4,
            0x7d, 0xf8, 0xd2, 0x06,
        ];
        assert_eq!(got.to_byte_array(), expected, "tapBranch diverges from rust-bitcoin");

        // BIP-341 sorts the children, so call order must not matter. The Solidity side asserts
        // the same property; this pins that BOTH sort the SAME WAY.
        let swapped = TapNodeHash::from_node_hashes(
            TapNodeHash::from_byte_array(b),
            TapNodeHash::from_byte_array(a),
        );
        assert_eq!(swapped.to_byte_array(), expected, "child order changed the parent");
    }

    /// keccak256("leaf-a") — the shared fixture, written out so this file needs no keccak dep.
    fn hex_lit_a() -> [u8; 32] {
        [
            0xd1, 0x7a, 0x96, 0x10, 0xbb, 0x43, 0x52, 0x40, 0x74, 0x93, 0xd9, 0x36, 0x13, 0xd4,
            0x9e, 0x9e, 0xd5, 0xbd, 0xcd, 0x85, 0x79, 0x8a, 0xdb, 0xa6, 0x39, 0x80, 0x7f, 0x29,
            0x6d, 0x8d, 0xfc, 0x73,
        ]
    }

    /// keccak256("leaf-b").
    fn hex_lit_b() -> [u8; 32] {
        [
            0x87, 0xfd, 0x48, 0x83, 0xcd, 0xd6, 0x38, 0xe9, 0x28, 0x5b, 0xd8, 0xa4, 0x57, 0xae,
            0xdd, 0x2f, 0x5c, 0x18, 0x10, 0x57, 0x15, 0x76, 0x0d, 0xc0, 0x2c, 0x5f, 0x57, 0x1d,
            0x7c, 0x59, 0x30, 0x69,
        ]
    }
}
