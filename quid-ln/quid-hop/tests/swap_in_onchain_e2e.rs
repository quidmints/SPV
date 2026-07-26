//! Regtest e2e for the Design-A on-chain swap-in taproot deposit: proves REAL
//! Bitcoin consensus (not just signature math) accepts
//!   (a) the hop's unilateral KEY-PATH claim of a confirmed deposit, and
//!   (b) the user's script-path CLTV REFUND — and REJECTS that refund before its timelock.
//!
//! Backed by JUST `bitcoind` (via electrsd's download infra). This test drives raw
//! bitcoind RPC + the taproot primitives from `quid_hop::swap_in_onchain` (the SAME
//! functions the daemon watcher signs with) — it runs NO node, so it needs none of the
//! esplora/electrs chain-sync layer the node harness (`Regtest`) bundles for the
//! LDK/lexe-derived node. Hence no `ElectrsD` here.
//!
//! Run: `cargo test -p quid-hop --test swap_in_onchain_e2e --features harness -- --nocapture`
#![cfg(feature = "harness")]

use std::str::FromStr;

use bitcoin::bip32::Xpriv;
use bitcoin::consensus::encode::serialize_hex;
use bitcoin::secp256k1::{Keypair, Secp256k1, SecretKey};
use bitcoin::{absolute::LockTime, Address, Amount, Network, OutPoint, ScriptBuf, TxOut, Txid};

use electrsd::bitcoind::serde_json::{json, Value};
use electrsd::bitcoind::{self, BitcoinD};

use quid_hop::swap_in_onchain::{
    build_claim_tx, build_refund_tx, deposit_for, refund_control_block, refund_sighash,
    refund_witness, sign_claim,
};

const FEE: Amount = Amount::from_sat(1_000);

#[test]
fn onchain_swap_in_keypath_claim_and_cltv_refund_on_regtest() {
    let exe = std::env::var("BITCOIND_EXE")
        .ok()
        .or_else(|| bitcoind::exe_path().ok())
        .expect("set BITCOIND_EXE or enable the bitcoind_download feature");
    let bd = BitcoinD::new(exe).expect("start bitcoind (regtest, default wallet)");
    let secp = Secp256k1::new();

    // Fund the wallet (coinbase maturity) so `sendtoaddress` has spendable coins.
    let wallet_addr = call(&bd, "getnewaddress", &[]).as_str().unwrap().to_string();
    call(&bd, "generatetoaddress", &[json!(101), json!(wallet_addr)]);

    // Hop master (per-swap deposit keys) + the user's refund key.
    let master = Xpriv::new_master(Network::Regtest, &[0x11; 32]).unwrap();
    let user = Keypair::from_secret_key(&secp, &SecretKey::from_slice(&[0x33; 32]).unwrap());
    let user_x = user.x_only_public_key().0;

    // ───────────────── (a) HOP KEY-PATH CLAIM ─────────────────
    {
        let cltv = LockTime::from_height(tip(&bd) + 50).unwrap();
        let idx = 7u32;
        let (addr, _si, _leaf) = deposit_for(&secp, &master, idx, user_x, cltv, Network::Regtest).unwrap();

        // Deposit → confirm.
        let dep_txid = call(&bd, "sendtoaddress", &[json!(addr.to_string()), json!(0.005)])
            .as_str().unwrap().to_string();
        mine(&bd, 6);
        let (vout, value) = find_output(&bd, &dep_txid, &addr.to_string());

        // Build + sign the key-path claim to a fresh wallet address, broadcast it.
        let outpoint = OutPoint { txid: Txid::from_str(&dep_txid).unwrap(), vout };
        let deposit_txout = TxOut { value, script_pubkey: addr.script_pubkey() };
        let claim = build_claim_tx(outpoint, value, FEE, newaddr_spk(&bd));
        let signed = sign_claim(&secp, &master, idx, user_x, cltv, claim, &deposit_txout).unwrap();

        // sendrawtransaction ⇒ real consensus validates the witness/sig/script. Accept = pass.
        let claim_txid = bd
            .client
            .call::<Value>("sendrawtransaction", &[json!(serialize_hex(&signed))])
            .expect("bitcoind must ACCEPT the hop key-path claim")
            .as_str().unwrap().to_string();
        mine(&bd, 1);
        assert!(confirmations(&bd, &claim_txid) >= 1, "key-path claim confirmed on-chain");
    }

    // ───────────────── (b) USER CLTV REFUND ─────────────────
    {
        let cltv = LockTime::from_height(tip(&bd) + 12).unwrap(); // window > the 6 confs mined below
        let idx = 8u32;
        let (addr, si, leaf) = deposit_for(&secp, &master, idx, user_x, cltv, Network::Regtest).unwrap();

        let dep_txid = call(&bd, "sendtoaddress", &[json!(addr.to_string()), json!(0.004)])
            .as_str().unwrap().to_string();
        mine(&bd, 6); // tip now < cltv → the refund is not yet final
        let (vout, value) = find_output(&bd, &dep_txid, &addr.to_string());

        // Build the user's script-path refund (nLockTime = cltv).
        let outpoint = OutPoint { txid: Txid::from_str(&dep_txid).unwrap(), vout };
        let deposit_txout = TxOut { value, script_pubkey: addr.script_pubkey() };
        let refund = build_refund_tx(outpoint, value, FEE, newaddr_spk(&bd), cltv);
        let msg = refund_sighash(&refund, &deposit_txout, &leaf).unwrap();
        let sig = secp.sign_schnorr_no_aux_rand(&msg, &user);
        let cb = refund_control_block(&si, &leaf).unwrap();
        let mut signed = refund.clone();
        signed.input[0].witness = refund_witness(&sig, &leaf, &cb);
        let raw = serialize_hex(&signed);

        // BEFORE the timelock: consensus must REJECT (non-final locktime).
        let early = bd.client.call::<Value>("sendrawtransaction", &[json!(raw)]);
        assert!(early.is_err(), "refund must be REJECTED before its CLTV height");

        // Reach the timelock, then it must be ACCEPTED.
        let need = cltv.to_consensus_u32() as u64;
        let have = tip(&bd) as u64;
        if need > have {
            mine(&bd, need - have);
        }
        let refund_txid = bd
            .client
            .call::<Value>("sendrawtransaction", &[json!(raw)])
            .expect("bitcoind must ACCEPT the CLTV refund once the timelock is reached")
            .as_str().unwrap().to_string();
        mine(&bd, 1);
        assert!(confirmations(&bd, &refund_txid) >= 1, "CLTV refund confirmed on-chain");
    }
}

// ── raw bitcoind RPC helpers (string args ⇒ no bitcoin-crate version coupling) ──

fn call(bd: &BitcoinD, method: &str, params: &[Value]) -> Value {
    bd.client
        .call::<Value>(method, params)
        .unwrap_or_else(|e| panic!("{method}: {e}"))
}

/// Mine `n` blocks to a throwaway wallet address (confirms broadcast txs + advances tip).
fn mine(bd: &BitcoinD, n: u64) {
    let a = call(bd, "getnewaddress", &[]).as_str().unwrap().to_string();
    call(bd, "generatetoaddress", &[json!(n), json!(a)]);
}

fn tip(bd: &BitcoinD) -> u32 {
    call(bd, "getblockcount", &[]).as_u64().unwrap() as u32
}

/// A fresh wallet address' scriptPubKey (destination for a claim / refund).
fn newaddr_spk(bd: &BitcoinD) -> ScriptBuf {
    let s = call(bd, "getnewaddress", &[]).as_str().unwrap().to_string();
    Address::from_str(&s).unwrap().assume_checked().script_pubkey()
}

/// The output of `txid` paying `addr` → (vout index, value). Uses verbose `gettransaction`
/// (the tx is wallet-relevant, so no `-txindex`); matches on the address string.
fn find_output(bd: &BitcoinD, txid: &str, addr: &str) -> (u32, Amount) {
    let tx = call(bd, "gettransaction", &[json!(txid), json!(true), json!(true)]);
    for v in tx["decoded"]["vout"].as_array().unwrap() {
        if v["scriptPubKey"]["address"].as_str() == Some(addr) {
            let n = v["n"].as_u64().unwrap() as u32;
            let sats = (v["value"].as_f64().unwrap() * 1e8).round() as u64;
            return (n, Amount::from_sat(sats));
        }
    }
    panic!("no output paying {addr} in {txid}");
}

fn confirmations(bd: &BitcoinD, txid: &str) -> u64 {
    call(bd, "gettransaction", &[json!(txid)])["confirmations"]
        .as_u64()
        .unwrap_or(0)
}
