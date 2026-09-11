//! §PP-RELAYER — the privacy-pool withdrawal relayer, served by the fleet enclave.
//!
//! GET  /pp/relay   → 200 { "fee_recipient":"0x.." }   the address a proof must name as
//!                    `RelayData.feeRecipient` — asked of the relayer, because it is whichever hop
//!                    serves this API, not necessarily `MAIN_HOP`.
//! POST /pp/relay   (public — no bearer token: a relayer with a key on the door is not a relayer)
//!   { "withdrawal": { "processooor":"0x..", "data":"0x.." },
//!     "proof":      { "proof":"0x..", "pubSignals":["<u256 dec|hex>" ×8] },
//!     "scope":      "<u256 dec|hex>" }
//!   → 200 { "success": true }        the `Entrypoint.relay` tx was mined and did not revert
//!   → 400 <reason>                    refused before any tx (shape, binding, or a simulated revert
//!                                     named by its custom-error selector)
//!   → 402 <numbers>                   the fee does not cover the gas — raise `relayFeeBPS`, re-prove
//!   → 503                             this deployment has no `QUID_PP_ENTRYPOINT`
//!
//! The door is protected by REFUSING, never by paying. What makes a relayer safe to run with a hot
//! key is that `PrivacyPool` binds `RelayData{recipient, feeRecipient, relayFeeBPS}` into the proof's
//! `context` public input, so nothing here can be redirected; what makes it safe to run UNGATED is
//! that every check below costs the relayer at most one RPC read, and a transaction is only ever
//! sent for a call the node has already executed successfully in `eth_estimateGas`.
//!
//! The pool is native-asset (`PrivacyPoolSimple` is the only pool `DeployLib` deploys), so the fee
//! and the gas are both in wei and compare without an oracle. An ERC-20 pool would need a price to
//! compare a token fee against gas; rather than compare the two silently in different units, a
//! non-native `ASSET()` is refused until that pool exists.

use std::sync::Arc;

use alloy_primitives::{Address, U256};
use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use quid_hop::evm_codec::{encode_pp_relay, pp_withdrawal_context, PpRelayData, PpWithdrawal};
use serde::Deserialize;
use tracing::{info, warn};

use crate::abi::{selector4, word_to_lpaddr};
use crate::client::eth_call_raw;
use crate::daemon::{DaemonEvm, DaemonRpc};
use crate::hexutil::hex_bytes;
use crate::relayer::estimate_gas;

/// `Constants.NATIVE_ASSET` — the sentinel `PrivacyPoolSimple.ASSET()` returns.
const NATIVE_ASSET: Address = Address::new([0xEE; 20]);

/// The fee must cover the projected gas by this much. Worst input that passes: a fee exactly 1.1×
/// the gas at the estimate's price — the relayer nets 10% of gas and nothing else, which is the
/// floor a 402 tells the app to clear.
const FEE_COVER_PCT: u128 = 110;

/// `eth_estimateGas` + this headroom, as `channel_driver::gas_limit_for` does for BTCChannels.
const GAS_HEADROOM_PCT: u64 = 125;

/// The custom errors `Entrypoint.relay` → `PrivacyPool.withdraw` can raise, so a simulated revert
/// comes back to the app as a name rather than four hex bytes. Reads, not writes: an error absent
/// here still surfaces as its selector.
const RELAY_ERRORS: &[&str] = &[
    "InvalidWithdrawalAmount()",
    "InvalidProcessooor()",
    "PoolNotFound()",
    "PoolIsDead()",
    "RelayFeeGreaterThanMax()",
    "InvalidPoolState()",
    "NativeAssetTransferFailed()",
    "ScopeMismatch()",
    "ContextMismatch()",
    "UnknownStateRoot()",
    "InvalidIdentityRoot()",
    "InvalidRevocationRoot()",
    "InvalidTreeDepth()",
    "InvalidProof()",
    "NullifierAlreadySpent()",
];

/// What the daemon hands in when `QUID_PP_ENTRYPOINT` is set.
pub struct PpRelayIngrid {
    pub evm: Arc<DaemonEvm>,
    pub rpc: DaemonRpc,
    pub entrypoint: Address,
}

#[derive(Deserialize)]
pub struct WithdrawalReq {
    pub processooor: String,
    pub data: String,
}

#[derive(Deserialize)]
pub struct ProofReq {
    pub proof: String,
    #[serde(rename = "pubSignals")]
    pub pub_signals: Vec<String>,
}

#[derive(Deserialize)]
pub struct RelayReq {
    pub withdrawal: WithdrawalReq,
    pub proof: ProofReq,
    pub scope: String,
}

type ApiError = (StatusCode, String);
fn bad(msg: impl Into<String>) -> ApiError {
    (StatusCode::BAD_REQUEST, msg.into())
}

fn parse_u256(s: &str, what: &str) -> Result<U256, ApiError> {
    let t = s.trim();
    let v = if let Some(h) = t.strip_prefix("0x") {
        U256::from_str_radix(h, 16)
    } else {
        U256::from_str_radix(t, 10)
    };
    v.map_err(|_| bad(format!("{what}: bad u256")))
}

/// Everything that can be refused WITHOUT touching the chain: shape, `processooor == ENTRYPOINT`,
/// `feeRecipient == self`, and the context binding. Returns the calldata and the fee in wei.
pub fn check_and_encode(
    req: &RelayReq,
    entrypoint: Address,
    relayer: Address,
) -> Result<(Vec<u8>, U256), ApiError> {
    let processooor =
        req.withdrawal.processooor.parse::<Address>().map_err(|_| bad("processooor: bad address"))?;
    if processooor != entrypoint {
        return Err(bad("processooor must be the Entrypoint for a relayed withdrawal"));
    }
    let data = hex_bytes(&req.withdrawal.data).ok_or_else(|| bad("data: bad hex"))?;
    let relay = PpRelayData::decode(&data).ok_or_else(|| bad("data: not abi.encode(RelayData)"))?;
    if relay.fee_recipient != relayer {
        return Err(bad(format!("feeRecipient must be the relayer ({relayer})")));
    }
    let proof = hex_bytes(&req.proof.proof).ok_or_else(|| bad("proof: bad hex"))?;
    if req.proof.pub_signals.len() != 8 {
        return Err(bad("pubSignals: expected 8"));
    }
    let mut pub_signals = [U256::ZERO; 8];
    for (i, s) in req.proof.pub_signals.iter().enumerate() {
        pub_signals[i] = parse_u256(s, &format!("pubSignals[{i}]"))?;
    }
    let scope = parse_u256(&req.scope, "scope")?;
    let withdrawal = PpWithdrawal { processooor, data };
    // ProofLib.context — pubSignals[6]. A proof built for other RelayData (or another scope)
    // cannot pass the pool's ContextMismatch, so refuse it here for free.
    let expected = pp_withdrawal_context(&withdrawal, scope);
    if pub_signals[6] != expected {
        return Err(bad(format!(
            "context mismatch: proof carries {}, (withdrawal, scope) implies {expected}",
            pub_signals[6]
        )));
    }
    // ProofLib.withdrawnValue — pubSignals[2]; the fee is `relayFeeBPS` of it.
    let fee = pub_signals[2] * relay.relay_fee_bps / U256::from(10_000u64);
    Ok((encode_pp_relay(&withdrawal, &proof, &pub_signals, scope), fee))
}

/// Name a revert by its custom-error selector when it is one of [`RELAY_ERRORS`].
/// The node puts the revert data somewhere in its error text (`… reverted, data: 0x…`), so every
/// `0x`-prefixed run is tried.
fn name_revert(raw: &str) -> String {
    for (i, _) in raw.match_indices("0x") {
        let Some(sel) = raw.get(i + 2..i + 10).and_then(hex_bytes) else { continue };
        if let Some(sig) = RELAY_ERRORS.iter().find(|sig| selector4(sig) == sel) {
            return (*sig).to_string();
        }
    }
    raw.to_string()
}

/// `scopeToPool(scope).ASSET()` — refuse anything but the native pool (see the module doc).
fn require_native_pool(rpc: &DaemonRpc, entrypoint: Address, scope: U256) -> Result<(), ApiError> {
    let pool = eth_call_raw(&**rpc, entrypoint, "scopeToPool(uint256)", Some(&scope.to_be_bytes::<32>()))
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("scopeToPool: {e}")))?;
    let pool = Address::from(word_to_lpaddr(&pool).map_err(|e| (StatusCode::BAD_GATEWAY, e.to_string()))?);
    if pool == Address::ZERO {
        return Err(bad("PoolNotFound()"));
    }
    let asset = eth_call_raw(&**rpc, pool, "ASSET()", None)
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("ASSET: {e}")))?;
    let asset = Address::from(word_to_lpaddr(&asset).map_err(|e| (StatusCode::BAD_GATEWAY, e.to_string()))?);
    if asset != NATIVE_ASSET {
        return Err(bad(format!("only the native pool is relayed; scope {scope} holds {asset}")));
    }
    Ok(())
}

pub async fn who(State(st): State<Option<Arc<PpRelayIngrid>>>) -> Result<Json<serde_json::Value>, ApiError> {
    let st = st.ok_or((StatusCode::SERVICE_UNAVAILABLE, "no QUID_PP_ENTRYPOINT: relaying is off".into()))?;
    Ok(Json(serde_json::json!({ "fee_recipient": st.evm.address().to_string() })))
}

pub async fn relay(
    State(st): State<Option<Arc<PpRelayIngrid>>>,
    Json(req): Json<RelayReq>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let st = st.ok_or((StatusCode::SERVICE_UNAVAILABLE, "no QUID_PP_ENTRYPOINT: relaying is off".into()))?;
    let relayer = st.evm.address();
    let (calldata, fee) = check_and_encode(&req, st.entrypoint, relayer)?;
    let scope = parse_u256(&req.scope, "scope")?;

    // Everything on-chain, off the async runtime: the asset check, the simulation (estimateGas
    // executes the call — a revert refuses with its name and costs no tx), the fee-vs-gas
    // comparison, and only then the send.
    let st2 = st.clone();
    let cd = calldata.clone();
    let (gas, price) = tokio::task::spawn_blocking(move || -> Result<(u64, u128), ApiError> {
        require_native_pool(&st2.rpc, st2.entrypoint, scope)?;
        let est = estimate_gas(&*st2.rpc, Some(relayer), st2.entrypoint, &cd)
            .map_err(|e| bad(format!("relay would revert: {}", name_revert(&e.to_string()))))?;
        let gas = est.saturating_mul(GAS_HEADROOM_PCT) / 100;
        let price = st2
            .evm
            .suggested_gas_price()
            .map_err(|e| (StatusCode::BAD_GATEWAY, format!("eth_gasPrice: {e}")))?;
        let need = U256::from(gas as u128 * price * FEE_COVER_PCT / 100);
        if fee < need {
            return Err((
                StatusCode::PAYMENT_REQUIRED,
                format!("fee {fee} wei < {need} wei ({gas} gas × {price} wei × {FEE_COVER_PCT}%)"),
            ));
        }
        Ok((gas, price))
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("join: {e}")))??;

    let st2 = st.clone();
    let cd = calldata.clone();
    let ok = tokio::task::spawn_blocking(move || -> anyhow::Result<bool> {
        let ok = st2.evm.send_tx(st2.entrypoint, cd, gas)?;
        if !ok {
            // Simulated fine, reverted when mined: the state moved between the two (a nullifier
            // spent by a competing relay, a root rotated out). Named for the operator.
            let reason = crate::channel_driver::eth_call_revert_reason(
                &*st2.rpc, relayer, st2.entrypoint, &calldata);
            warn!(reason = %name_revert(&reason), "pp relay: mined but reverted");
            return Ok(false);
        }
        // ETH float: the relayer pays gas up front and is repaid in the asset. Say so before it
        // runs dry, in units of this tx — ten more of these is the alarm line.
        let bal = eth_balance(&st2.rpc, relayer)?;
        if bal < U256::from(gas as u128 * price * 10) {
            warn!(%relayer, balance_wei = %bal, "pp relay: ETH float below ten relays — top up the hot key");
        }
        Ok(true)
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("join: {e}")))?
    .map_err(|e| {
        warn!(error = %e, "pp relay: send failed");
        (StatusCode::BAD_GATEWAY, format!("send: {e}"))
    })?;
    if !ok {
        return Err((StatusCode::CONFLICT, "relay reverted on-chain; re-prove against current state".into()));
    }
    info!(fee_wei = %fee, gas, "pp relay: withdrawal relayed");
    Ok(Json(serde_json::json!({ "success": true })))
}

fn eth_balance(rpc: &DaemonRpc, who: Address) -> anyhow::Result<U256> {
    use crate::transport::JsonRpc;
    let v = rpc.call("eth_getBalance", serde_json::json!([who.to_string(), "latest"]))?;
    let s = v.as_str().ok_or_else(|| anyhow::anyhow!("eth_getBalance: no result"))?;
    Ok(U256::from_str_radix(s.trim_start_matches("0x"), 16)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

    // The same fixture `evm_codec::tests::pp_withdrawal_context_matches_client_and_pool` pins
    // against the client and `PrivacyPool._contextFor`.
    const ENTRYPOINT: &str = "0x00000000000000000000000000000000000000e1";
    const RELAYER: &str = "0x00000000000000000000000000000000000000f1";
    const CONTEXT: &str = "7948633688262801802494452180195935100535116121924170774747370064017535756814";

    fn req(fee_recipient: &str, processooor: &str, ctx_at: usize) -> RelayReq {
        let mut data = vec![0u8; 96];
        data[31] = 0xa1; // recipient 0x…a1
        data[32..64].copy_from_slice(&crate::abi::address_word(fee_recipient.parse().unwrap()));
        data[95] = 250; // 2.5%
        let mut sigs = vec!["0".to_string(); 8];
        sigs[2] = "1000000000000000000".into(); // 1 ETH withdrawn
        sigs[ctx_at] = CONTEXT.into();
        RelayReq {
            withdrawal: WithdrawalReq {
                processooor: processooor.into(),
                data: format!("0x{}", alloy_primitives::hex::encode(data)),
            },
            proof: ProofReq { proof: "0xdead".into(), pub_signals: sigs },
            scope: "42".into(),
        }
    }

    #[test]
    fn accepts_a_bound_withdrawal_and_prices_its_fee() {
        let (cd, fee) = check_and_encode(&req(RELAYER, ENTRYPOINT, 6), ENTRYPOINT.parse().unwrap(), RELAYER.parse().unwrap()).unwrap();
        assert_eq!(&cd[..4], &keccak256(quid_hop::evm_codec::SIG_PP_RELAY.as_bytes())[..4]);
        assert_eq!(fee, U256::from(25_000_000_000_000_000u128), "2.5% of 1 ETH");
    }

    #[test]
    fn refuses_what_the_pool_would_refuse_before_any_rpc() {
        let ep: Address = ENTRYPOINT.parse().unwrap();
        let me: Address = RELAYER.parse().unwrap();
        let e = check_and_encode(&req("0x00000000000000000000000000000000000000f2", ENTRYPOINT, 6), ep, me).unwrap_err();
        assert!(e.1.contains("feeRecipient"), "someone else's fee: {}", e.1);
        let e = check_and_encode(&req(RELAYER, RELAYER, 6), ep, me).unwrap_err();
        assert!(e.1.contains("processooor"), "self-withdrawal offered for relay: {}", e.1);
        // The context lives at pubSignals[6]; a proof carrying it at [7] (the blacklist root's
        // slot — the index the client compared until 2026-09-11) is not bound to this RelayData.
        let e = check_and_encode(&req(RELAYER, ENTRYPOINT, 7), ep, me).unwrap_err();
        assert!(e.1.contains("context mismatch"), "{}", e.1);
    }

    #[test]
    fn names_a_revert_by_its_selector_wherever_the_node_put_it() {
        let sel = alloy_primitives::hex::encode(&keccak256(b"ContextMismatch()")[..4]);
        assert_eq!(name_revert(&format!("JSON-RPC error -32000: execution reverted, data: 0x{sel}")), "ContextMismatch()");
        assert_eq!(name_revert(&format!("0x{sel}")), "ContextMismatch()");
        assert_eq!(name_revert("0xdeadbeef"), "0xdeadbeef", "unknown selectors pass through");
    }
}
