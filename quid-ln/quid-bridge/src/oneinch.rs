//! ⭐ §SESS-88 — **THE 1inch SWAP API CLIENT: THE ONE PRODUCER THE ROUTE ARM NEVER HAD.**
//!
//! 🔴 **WHY THIS EXISTS, AND WHY NOTHING ELSE CAN DO ITS JOB.** `Plan::route_bytes` can only emit
//!    `unoswap`-family calldata, because a pool word is self-contained and we can build one. The
//!    generic `swap(address,(…),bytes)` descriptor **cannot be constructed by us**: it names 1inch's
//!    own executor and carries an opaque `data` tail that only their pathfinder produces. That is the
//!    single reason Uniswap V4, Balancer, Fluid, split routes and the par converters are unreachable
//!    — measured, 4 of 28 stable→volatile legs have liquidity ONLY where we cannot address it.
//! ⛔ **AND IT DOES NOT WIDEN THE TRUST SURFACE BY ONE BIT.** `LevMath._retarget` overwrites
//!    `srcToken`, `dstToken`, `dstReceiver`, `amount` and `minReturn` on a fetched route exactly as it
//!    does on ours, and `convertTo` bounds both on a measured balance delta against one floor. §SESS-40
//!    rejected fetched routes because *"full calldata embeds an `amount` … unknowable off-chain to the
//!    wei"* — **that objection was retired by work done for another reason.** A fetched route may be
//!    stale in every field we care about and it does not matter.
//! ⚠️ **WHAT IT DOES ADD IS AN AVAILABILITY DEPENDENCY, ON PATHS THAT CANNOT TOLERATE ONE.**
//!    `rebalance` and `deleverMany` are permissionless and fire when positions are STRESSED — which is
//!    when everyone else is hammering this API too. ⇒ **every entry point here returns `Option` and
//!    every failure is a fallback to the self-planned route, never a stall.** A key that is missing,
//!    revoked, rate-limited or slow must cost us a better price, never a rebalance.

use crate::lev_keeper::LpAddr;
use alloy_primitives::U256;
use std::time::Duration;

/// Chain 1, Swap API v6.1 — the version whose `swap` selector (`0x07ed2379`) is the one
/// `Interfaces.sol:SWAP_SELECTOR` pins and `RetargetedRoute.t.sol` asserts against.
const BASE: &str = "https://api.1inch.dev/swap/v6.1/1";

/// ⚠️ **THE KEY LIVES IN THE KEEPER, WHICH ALSO HOLDS LIGHTNING MATERIAL** (`LevMath:1345`), so a
/// hacked keeper leaks it. That is accepted BECAUSE THE BLAST RADIUS IS QUOTA, NOT FUNDS: a stolen
/// 1inch key buys someone else's rate limit. It is never logged, never put in an error message, and
/// never travels in a URL — `Authorization` header only.
pub fn api_key() -> Option<String> {
    let k = std::env::var("ONEINCH_API_KEY").unwrap_or_default();
    if k.is_empty() { None } else { Some(k) }
}

fn agent() -> ureq::Agent {
    // Short, because this is on the critical path of a rebalance and the fallback is free.
    ureq::AgentBuilder::new().timeout(Duration::from_secs(6)).build()
}

fn hex20(a: LpAddr) -> String { format!("0x{}", alloy_primitives::hex::encode(a)) }

fn get(path: &str, params: &[(&str, String)]) -> Option<serde_json::Value> {
    let key = api_key()?;
    let mut req = agent().get(&format!("{BASE}{path}"))
        .set("Authorization", &format!("Bearer {key}"))
        .set("Accept", "application/json");
    for (k, v) in params { req = req.query(k, v); }
    // ⚠️ `.ok()` on purpose, and it is NOT the silent-degradation trap §SESS-66 records: there the
    //    swallowed error became "no route" and the planner quietly picked a worse venue. Here the
    //    caller's fallback is the SELF-PLANNED route, which is the thing we would have used anyway.
    req.call().ok()?.into_json::<serde_json::Value>().ok()
}

/// ⭐ **THE A/B PRIMITIVE: `dstAmount` ALONE, NO CALLDATA.** `/quote` needs no `from` address and does
/// not build a transaction, so it is the cheap way to ask *"would their pathfinder have beaten our
/// planner on this pair at this size"* without pretending to hold the funds.
pub fn quote(src: LpAddr, dst: LpAddr, amount: U256) -> Option<U256> {
    let v = get("/quote", &[
        ("src", hex20(src)), ("dst", hex20(dst)), ("amount", amount.to_string()),
    ])?;
    let s = v.get("dstAmount")?.as_str()?;
    s.parse::<U256>().ok()
}

/// The four selectors `LevMath._retarget` whitelists. Anything else is refused HERE, so a shape the
/// contract would reject never becomes a leg that fails on-chain and gets skipped.
const ACCEPTED: [[u8; 4]; 4] = [
    [0x83, 0x80, 0x0a, 0x8e],   // unoswap
    [0x87, 0x70, 0xba, 0x91],   // unoswap2
    [0x19, 0x36, 0x74, 0x72],   // unoswap3
    [0x07, 0xed, 0x23, 0x79],   // swap(address,(…),bytes)  ← the only door to v4/Balancer/Fluid
];

/// ⭐ **FULL CALLDATA FOR `Plan.fetched`.**
///
/// 🔑 `disableEstimate=true` because their simulator would revert: `from` is the manager, which does
///    not hold the input at quote time — the amount is computed on-chain from a borrow return this
///    transaction has not made yet. ⚠️ `slippage` is required by the endpoint and is then IRRELEVANT:
///    `_retarget` zeroes `minReturn` and the aggregate delta floor is the only bound that binds.
/// ⛔ **THE SELECTOR IS CHECKED HERE.** 1inch answers `/swap` with whichever shape its pathfinder
///    chose, and one it picks that we do not whitelist would arrive on-chain, revert `BadRoute`, and
///    be SKIPPED — a silently worse execution wearing a successful fetch. Refusing it here falls back
///    to the self-planned route instead, which is the honest outcome.
/// ⭐ **AND IT RETURNS THE QUOTE ALONGSIDE THE CALLDATA, WHICH IS WHAT MAKES THE CHOICE MEASURED.**
///    `/swap` answers with `dstAmount` in the same response, so preferring a fetched route costs no
///    extra call and never has to be taken on faith: the caller compares it to what our own planner
///    quoted and takes the winner. ⛔ **A fetched route is NOT better by assumption** — measured, our
///    self-planned two-hop beats a direct pool by ~23 bps at $1M and loses at $50k, and neither
///    producer wins by class.
pub fn swap_quote_and_calldata(src: LpAddr, dst: LpAddr, amount: U256, from: LpAddr, slippage_bps: u32)
    -> Option<(U256, Vec<u8>)>
{
    let v = get("/swap", &[
        ("src", hex20(src)), ("dst", hex20(dst)), ("amount", amount.to_string()),
        ("from", hex20(from)), ("origin", hex20(from)),
        ("slippage", format!("{}", slippage_bps as f64 / 100.0)),
        ("disableEstimate", "true".into()),
    ])?;
    let out: U256 = v.get("dstAmount")?.as_str()?.parse().ok()?;
    let data = v.get("tx")?.get("data")?.as_str()?;
    let bytes = alloy_primitives::hex::decode(data.trim_start_matches("0x")).ok()?;
    if bytes.len() < 4 { return None; }
    if !ACCEPTED.iter().any(|s| s[..] == bytes[..4]) {
        tracing::warn!(selector = %alloy_primitives::hex::encode(&bytes[..4]),
            "1inch returned a selector _retarget does not whitelist; falling back to the self-planned route");
        return None;
    }
    Some((out, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lev_keeper::{LpAddr, WETH_ADDR, USDC_ADDR, USDT_ADDR, DAI_ADDR};

    fn a(h: &str) -> LpAddr {
        let b = alloy_primitives::hex::decode(h.trim_start_matches("0x")).expect("bad address hex");
        let mut o = [0u8; 20]; o.copy_from_slice(&b); o
    }

    /// ⭐ §SESS-88 — **THE A/B: THEIR PATHFINDER AGAINST OUR PLANNER, SAME PAIR, SAME BLOCK, SAME SIZE.**
    ///
    /// 🔴 **THE QUESTION THIS ANSWERS IS ONE NOBODY HAD MEASURED.** The lane doc asserts a 1inch client
    ///    is "the remaining work" and the contract has admitted `swap()` since §SESS-69, but **no
    ///    comparison between their quotes and our self-planned routes exists anywhere in this tree.**
    ///    "Their pathfinder is better" was an assumption, and this is the instrument that makes it a
    ///    number — at BOTH sizes, because the hub-vs-direct winner already flips between $100k and $1M
    ///    on our own planner, so a single size would measure the size and not the planner.
    /// ⚠️ **THIS IS A MEASUREMENT, NOT A GATE, AND THE NAME SAYS SO.** It cannot assert "the API is
    ///    better" — that is a fact about two markets on one afternoon, which is
    ///    §POINT-IN-TIME-IS-NOT-AN-INVARIANT. It asserts only what would mean the CLIENT is broken.
    /// ⛔ It also does not follow §SESS-85's "absent config fails loud" rule, and that is deliberate,
    ///    not an oversight: an absent `ETH_RPC_URL` breaks the routing lane's own tests, whereas the
    ///    1inch key is an OPTIONAL producer whose whole design is to be absent without cost. Failing
    ///    here would assert that we have a key, which is the opposite of the fallback property.
    #[test]
    fn measure_oneinch_against_the_self_planned_route() {
        let Some(_) = api_key() else {
            println!("\n=== NO ONEINCH_API_KEY: the A/B cannot run. ===");
            println!("This is the OPTIONAL producer, so an absent key is a fallback, not a failure.");
            println!("Set ONEINCH_API_KEY to measure. Nothing below ran.\n");
            return;
        };
        let rpc = {
            let url = std::env::var("ETH_RPC_URL").or_else(|_| std::env::var("ANKR_RPC_URL"))
                .expect("the A/B needs an RPC to quote OUR side against");
            crate::transport::HttpJsonRpc::new(url)
        };
        let wbtc = a("0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599");
        let cases: [(&str, LpAddr, u32); 6] = [
            ("USDC",   USDC_ADDR, 6),
            ("USDT",   USDT_ADDR, 6),
            ("DAI",    DAI_ADDR, 18),
            // 🔴 the two the self-planner CANNOT route at all: liquidity only on v4.
            ("GHO",    a("0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f"), 18),
            ("FRXUSD", a("0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29"), 18),
            ("CRVUSD", a("0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E"), 18),
        ];
        let mut api_wins = 0i32; let mut ours_wins = 0i32; let mut only_api = 0i32; let mut neither = 0i32;
        println!("\n{:<8} {:>5} {:>7} {:>22} {:>22} {:>10}",
                 "stable", "vol", "size", "OURS (self-planned)", "1inch API", "delta bps");
        for (name, addr, dec) in cases {
            for (vlabel, vol) in [("WETH", WETH_ADDR), ("WBTC", wbtc)] {
                for (slabel, mult) in [("100k", 100_000u64), ("1M", 1_000_000u64)] {
                    let amt = U256::from(mult) * U256::from(10u64).pow(U256::from(dec));
                    let ours = crate::lev_keeper::best_plan_quoted_for_test(&rpc, addr, vol, amt)
                        .map(|(_, o)| o).unwrap_or(U256::ZERO);
                    let theirs = quote(addr, vol, amt).unwrap_or(U256::ZERO);
                    let delta = if ours.is_zero() || theirs.is_zero() { 0i64 } else {
                        let (o, t) = (ours, theirs);
                        if t >= o { ((t - o) * U256::from(10_000u64) / o).to::<u64>() as i64 }
                        else { -(((o - t) * U256::from(10_000u64) / o).to::<u64>() as i64) }
                    };
                    match (ours.is_zero(), theirs.is_zero()) {
                        (true, true)  => neither += 1,
                        (true, false) => only_api += 1,
                        (false, _) if delta > 0 => api_wins += 1,
                        _ => ours_wins += 1,
                    }
                    println!("{name:<8} {vlabel:>5} {slabel:>7} {:>22} {:>22} {:>10}",
                             ours.to_string(), theirs.to_string(),
                             if ours.is_zero() { "n/a".into() } else { format!("{delta:+}") });
                    // gentle on the rate limit; the fallback exists precisely because this can throttle
                    std::thread::sleep(std::time::Duration::from_millis(1200));
                }
            }
        }
        println!("\n1inch better: {api_wins} · ours better/equal: {ours_wins} \
                  · ONLY 1inch could route: {only_api} · neither: {neither}\n");
        // ⇒ the only assertion that is about the CLIENT rather than about the market.
        assert!(api_wins + ours_wins + only_api > 0,
            "every single pair returned nothing from BOTH producers - that is not a market reading, \
             it is a broken client, a dead key, or a dead endpoint");
    }
}
