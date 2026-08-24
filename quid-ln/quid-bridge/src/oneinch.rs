//! §C2.1 — 1inch AggregationRouterV6 route sourcing for the volatile leg.
//!
//! Uniswap V3 was deleted from the contracts (owner: *"we dont need v3 anymore pull it out and
//! delete it completley"*), so `USDC ↔ WETH/WBTC` has no on-chain venue at all. A 1inch swap is a
//! route a solver computes OFF-CHAIN; Solidity cannot build one. This module is where it gets built.
//!
//! # The trust model, stated first because it is the whole design
//!
//! **THE KEEPER IS NOT TRUSTED, AND THAT IS DELIBERATE.** What this module returns is arbitrary
//! calldata that the contract will `call` while holding flash-borrowed funds. Nothing here is a
//! security boundary. Three on-chain properties are, and all three live in `LevMath._aggSwap`:
//!
//!   1. **The callee is a pinned constant** (`ONEINCH_ROUTER`). This module chooses the ROUTE, never
//!      the DESTINATION — a compromised keeper cannot redirect the call.
//!   2. **`minOut` is enforced on the BALANCE DELTA**, never on the router's return value. A hostile
//!      route may return any number it likes; it cannot fake the contract's own balance.
//!   3. **The approval is reset on both paths**, so a reverted swap leaves no standing allowance.
//!
//! ⇒ The worst a broken response here can do is make the swap REVERT. That is why this module is
//! allowed to talk to a third-party HTTP API on a money path at all.
//!
//! ⚠️ `from` MUST be the contract that executes the swap (the LevManager), **not** the keeper's EOA.
//! 1inch encodes the spender/receiver into the route; passing the EOA yields calldata that moves the
//! keeper's own tokens and delivers nothing to the position — a swap that "succeeds" and drains
//! nothing into the flash repayment, surfacing as a slippage revert four frames away.

use anyhow::{anyhow, Context, Result};

use crate::abi::{selector4, u64_word};

/// 1inch AggregationRouterV6 — MUST match `ONEINCH_ROUTER` in `evm/src/imports/Interfaces.sol`.
/// Recorded here so a mismatch is greppable; the contract's copy is the one that binds.
pub const ROUTER_V6: [u8; 20] = [
    0x11, 0x11, 0x11, 0x12, 0x54, 0x21, 0xcA, 0x6d, 0xc4, 0x52, 0xd2, 0x89, 0x31, 0x42, 0x80, 0xa0,
    0xf8, 0x84, 0x2A, 0x65,
];

/// A route as the contract consumes it: the raw router calldata, plus the quote the API expected.
/// `dst_amount` is INFORMATIONAL — the binding bound is the `min_out` passed on-chain, checked
/// against the balance delta. Recording it lets the keeper log how far execution drifted from quote.
#[derive(Clone, Debug)]
pub struct Route {
    pub calldata: Vec<u8>,
    pub dst_amount: u128,
}

fn hex20(a: &[u8; 20]) -> String {
    let mut s = String::with_capacity(42);
    s.push_str("0x");
    for b in a {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn from_hex(s: &str) -> Result<Vec<u8>> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    if s.len() % 2 != 0 {
        return Err(anyhow!("odd-length hex from 1inch ({} chars)", s.len()));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| anyhow!("bad hex: {e}")))
        .collect()
}

/// Ask 1inch for swap calldata. Blocking `ureq`, matching `lev_keeper`'s blocking JSON-RPC style.
///
/// `slippage_pct` is what the AGGREGATOR is told; it does not bind us. The contract's `min_out` does.
/// Passing a slippage here that is TIGHTER than the on-chain bound just makes 1inch return routes
/// that fail more often; LOOSER is harmless because the chain still refuses a bad fill.
///
/// ⚠️ `disable_estimate=true` is required: 1inch otherwise simulates `eth_estimateGas` FROM `from`,
/// which has neither the tokens nor the approval until the flash loan is live, so every quote 404s.
pub fn fetch_swap(
    chain_id: u64,
    src: &[u8; 20],
    dst: &[u8; 20],
    amount: u128,
    from: &[u8; 20],
    slippage_pct: f64,
    api_key: &str,
) -> Result<Route> {
    if amount == 0 {
        return Err(anyhow!("1inch: refusing to quote a zero-size swap"));
    }
    let url = format!(
        "https://api.1inch.dev/swap/v6.0/{chain_id}/swap?src={}&dst={}&amount={amount}&from={}&slippage={slippage_pct}&disableEstimate=true",
        hex20(src),
        hex20(dst),
        hex20(from),
    );
    let body: serde_json::Value = ureq::get(&url)
        .set("Authorization", &format!("Bearer {api_key}"))
        .set("Accept", "application/json")
        .call()
        .context("1inch swap request failed")?
        .into_json()
        .context("1inch returned non-JSON")?;

    // The router the API tells us to call MUST be the one the contract has pinned. If 1inch ever
    // routes to a different deployment the contract would reject it anyway (the callee is a
    // constant) -- but failing HERE names the cause instead of surfacing as an opaque revert.
    let to = body["tx"]["to"]
        .as_str()
        .ok_or_else(|| anyhow!("1inch response has no tx.to"))?;
    let to_bytes = from_hex(to)?;
    if to_bytes.as_slice() != ROUTER_V6.as_slice() {
        return Err(anyhow!(
            "1inch routed to {to}, which is NOT the router pinned in Interfaces.sol -- the contract \
             would reject this call; refusing to submit it"
        ));
    }

    let data = body["tx"]["data"]
        .as_str()
        .ok_or_else(|| anyhow!("1inch response has no tx.data"))?;
    let calldata = from_hex(data)?;
    if calldata.len() < 4 {
        return Err(anyhow!("1inch returned {} bytes of calldata", calldata.len()));
    }
    let dst_amount = body["dstAmount"]
        .as_str()
        .unwrap_or("0")
        .parse::<u128>()
        .unwrap_or(0);

    Ok(Route { calldata, dst_amount })
}

/// ABI-encode `deleverOneRouted(address lp, uint256 minOut, bytes route)`.
///
/// One dynamic tail, so the head is `[lp][minOut][offset=0x60]` and the tail is `[len][padded data]`.
/// Written out rather than pulled from a codec because `lev_keeper`'s `encode_batch` already hand-rolls
/// the same shape -- one idiom in this crate, not two.
pub fn encode_delever_routed(lp: &[u8; 20], min_out: u128, route: &[u8]) -> Vec<u8> {
    let mut d = selector4("deleverOneRouted(address,uint256,bytes)");
    let mut lp_word = [0u8; 32];
    lp_word[12..].copy_from_slice(lp);
    d.extend_from_slice(&lp_word);
    let mut min_word = [0u8; 32];
    min_word[16..].copy_from_slice(&min_out.to_be_bytes());
    d.extend_from_slice(&min_word);
    d.extend_from_slice(&u64_word(0x60)); // offset to `route`: past the three head words
    d.extend_from_slice(&u64_word(route.len() as u64));
    d.extend_from_slice(route);
    let rem = route.len() % 32;
    if rem != 0 {
        d.extend_from_slice(&vec![0u8; 32 - rem]); // right-pad the tail to a word boundary
    }
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

    #[test]
    fn router_constant_matches_the_pinned_address() {
        // 0x111111125421cA6dc452d289314280a0f8842A65 -- AggregationRouterV6.
        assert_eq!(hex20(&ROUTER_V6), "0x111111125421ca6dc452d289314280a0f8842a65");
    }

    #[test]
    fn encodes_the_routed_delever_head_and_tail() {
        let lp = [0xAAu8; 20];
        let route = vec![0xDEu8; 5]; // deliberately NOT a multiple of 32
        let enc = encode_delever_routed(&lp, 7, &route);
        assert_eq!(
            &enc[..4],
            &keccak256(b"deleverOneRouted(address,uint256,bytes)")[..4]
        );
        assert_eq!(&enc[4 + 12..4 + 32], &lp[..], "lp in the low 20 bytes");
        assert_eq!(enc[4 + 63], 7, "minOut in the second word");
        assert_eq!(enc[4 + 95], 0x60, "offset to the bytes tail");
        assert_eq!(enc[4 + 127], 5, "route length");
        // head(3 words) + len(1) + one padded data word = 5 words after the selector.
        assert_eq!(enc.len(), 4 + 32 * 5, "tail padded to a word boundary");
    }

    #[test]
    fn refuses_a_zero_size_quote() {
        let e = fetch_swap(1, &[0u8; 20], &[1u8; 20], 0, &[2u8; 20], 1.0, "k").unwrap_err();
        assert!(e.to_string().contains("zero-size"), "got: {e}");
    }
}
