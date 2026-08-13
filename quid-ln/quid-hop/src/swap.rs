//! The bidirectional HTLC swap bridge — the LN↔EVM glue. The LDK node event
//! handlers (over `quid_ln::payments` / `quid_ln::event`) call into here:
//!   • swap-IN  — a SETTLED inbound invoice (the seller paid us BTC, we learned
//!     the preimage) → emit `BTCChannels.settleSwapIn(seller, sats, token, hash)`
//!     to the EVM. The `(seller, token)` binding is authored by the hop into the
//!     invoice's `payment_metadata` at issue (`encode_swap_in_metadata`), echoed
//!     verbatim by the payer, and recovered from `PaymentClaimed.onion_fields`.
//!     This supersedes the old hop-side `PendingSwapIn` map: LDK persists the
//!     event+onion, so the binding is durable across restarts with no bespoke
//!     state. SECURITY: credit only ever issues against
//!     sats actually claimed, and `swapInUsed[hash]` dedups on the EVM — so even
//!     though the payer transmits the metadata, they cannot conjure credit
//!     without paying, nor double-credit. A swap-IN sells BTC back into the pool;
//!     the EVM settles the USD side from the EXISTING pooled BTC-register USD
//!     (`creditSwapIn` draws `POOLED_USD_BTC`, undoing a prior delivery) and
//!     delivers it to the payer. The payer is the one who provided the BTC, so
//!     payer-named credit is the correct settlement target, not a redirection.
//!   • swap-OUT — an EVM BTC-delivery obligation → pay the swapper's invoice via
//!     `quid_ln` payments; reconciled per-channel at close.
//!
//! This module owns the EVM-call shaping (pure, tested); sending it (an EVM RPC
//! provider) and the LDK event subscription are wired in the node service.

use alloy_primitives::{keccak256, Address, Bytes, U256};

/// ABI-encode [`SIG_SETTLE_SWAP_IN_BUFFERED`] — what the hop submits when an inbound HTLC
/// settles. **(M1#1) `settleSwapIn` is DELETED and this replaces it.**
///
/// 🔑 The `paymentHash` survives but its JOB CHANGED: it is IDEMPOTENCY (one credit per HTLC
/// across daemon retries and restarts), never the bound. The credit is bounded by sats the hop
/// already SPV-proved into custody with `parkProvenSats`, so a hop can no longer conjure sats —
/// only the seller, token and floor remain its word (T2). Conflating those two roles is exactly
/// what made `settleSwapIn` a trapdoor. `require_full = true` makes
/// the contract REVERT (`SwapInPartialRejected`, rolling back the draw + USD delivery) when
/// the POOLED_USD_BTC reserve could only convert PART of `sats` — used by the atomic LN rail,
/// which has no way to refund a partial remainder. `false` allows an inventory-bounded
/// partial (the on-chain rail refunds the unconverted sats via a second claim output).
pub fn settle_swapin_calldata(
    seller: Address,
    sats: u64,
    token: Address,
    payment_hash: [u8; 32],
    min_delivered_usd: U256,
    require_full: bool,
) -> Bytes {
    let sel = keccak256(crate::evm_codec::SIG_SETTLE_SWAP_IN_BUFFERED);
    let mut data = Vec::with_capacity(4 + 192);
    data.extend_from_slice(&sel[..4]);
    data.extend_from_slice(&crate::abi::address_word(seller));
    data.extend_from_slice(&U256::from(sats).to_be_bytes::<32>());
    data.extend_from_slice(&crate::abi::address_word(token));
    data.extend_from_slice(&payment_hash);
    data.extend_from_slice(&min_delivered_usd.to_be_bytes::<32>());
    // bool → a 32-byte ABI word whose last byte is 1 (true) / 0 (false).
    data.extend_from_slice(&U256::from(require_full as u8).to_be_bytes::<32>());
    Bytes::from(data)
}

/// ABI-encode [`SIG_REVERSE_SWAP_OUT`] — `reverseSwapOut(swapId, token, minDeliveredUsd,
/// requireFull)`, which returns the USD an undeliverable on-chain swap-out already took
/// from the swapper.
///
/// This is NOT a swap-in and it deliberately does not look like one. A swap-in credit is an
/// assertion that BTC arrived; a reversal asserts nothing, because the swapper's own USD is
/// still sitting in `pendingOnchainSwapOut[swapId]` where their `requestSwapOutOnchain` put
/// it. Hence there is no `seller`, no `sats` and (since §T1-d pinned it in the record) no
/// `token` to encode: the contract reads all three from that record. `require_full = true` because a partial refund would strand the remainder — on
/// this path the swapper has no deposit or HTLC to reclaim it from.
pub fn reverse_swap_out_calldata(
    swap_id: [u8; 32],
    min_delivered_usd: U256,
    require_full: bool,
) -> Bytes {
    let sel = keccak256(crate::evm_codec::SIG_REVERSE_SWAP_OUT);
    let mut data = Vec::with_capacity(4 + 96);
    data.extend_from_slice(&sel[..4]);
    data.extend_from_slice(&swap_id);
    data.extend_from_slice(&min_delivered_usd.to_be_bytes::<32>());
    data.extend_from_slice(&U256::from(require_full as u8).to_be_bytes::<32>());
    Bytes::from(data)
}

/// The floor (the `min_delivered_usd` for `issue_swap_in_invoice`): the
/// seller's minimum acceptable USD for `sats` BTC, at the hop's quoted
/// `price_per_btc` (the OUTPUT stable's smallest units per 1 BTC — e.g. USDC
/// 6-dec, $50k/BTC = 50_000 * 1e6), less `slippage_bps` tolerance.
///
/// Computed OFF-chain in the stable's native units. This is DELIBERATELY not the
/// on-chain `volScale`/×1e10 TWAP conversion (that 8-dec-WBTC-vs-1e18-RAW-basis
/// trick is fragile and easy to get wrong — SwapLib.sol:638-647); the hop simply
/// attests the price it quoted the seller. `slippage_bps` exists because the
/// V4 curve fills with slippage, so an honest swap-in delivers slightly under
/// the spot quote — the floor must sit below that, or every settle reverts.
pub fn swap_in_floor_usd(sats: u64, price_per_btc: U256, slippage_bps: u16) -> U256 {
    // expected = sats/1e8 (BTC) * price_per_btc (stable units / BTC)
    let expected = U256::from(sats) * price_per_btc / U256::from(100_000_000u64);
    let keep = 10_000u16.saturating_sub(slippage_bps.min(10_000));
    expected * U256::from(keep) / U256::from(10_000u16)
}

/// N-conf **burn-finality gate**: the hop must NOT pay BTC over LN
/// — an irreversible action — until the EVM-side USD commitment is final, i.e.
/// the request's block is buried under `min_confs` confirmations. A reorg that
/// unwound the swapper's USD *after* the hop paid would be an unbacked loss.
/// `evm_tip` is the latest EVM head the watcher has seen.
pub fn evm_final(request_block: u64, evm_tip: u64, min_confs: u64) -> bool {
    // confirmations = tip − block + 1 (the request's own block counts as 1).
    evm_tip
        .checked_sub(request_block)
        .map(|d| d + 1 >= min_confs)
        .unwrap_or(false)
}

/// Shared decode of the `SwapOutRequestedOnchain` ABI shape. Validates the
/// shape/selector and returns (swapper, sats, token, raw tail bytes). ALL the
/// security-critical offset/length arithmetic lives HERE, once: the log can come
/// from ANY same-shaped event, so a hostile offset must yield `None`, never an
/// overflow panic (debug) or a wrap into a valid slice. `topics[2]` (swapId) is
/// read by the caller (topics.len()==3 is checked here).
fn decode_swap_out_common(
    topics: &[[u8; 32]],
    data: &[u8],
    topic0: [u8; 32],
) -> Option<(Address, u64, Address, Vec<u8>)> {
    if topics.len() != 3 || data.len() < 128 {
        return None;
    }
    if topics[0] != topic0 {
        return None;
    }
    let swapper = Address::from_slice(&topics[1][12..32]);
    // sats is a uint256; reject anything that doesn't fit u64 rather than truncate.
    let sats: u64 = U256::from_be_slice(&data[0..32]).try_into().ok()?;
    let token = Address::from_slice(&data[44..64]); // word 1, right-aligned
    // word 2 = byte-offset of the bytes tail (relative to data start) — CHECKED.
    let offset: usize = U256::from_be_slice(&data[64..96]).try_into().ok()?;
    let len_end = offset.checked_add(32)?;
    let len: usize = U256::from_be_slice(data.get(offset..len_end)?).try_into().ok()?;
    let start = len_end;
    let end = start.checked_add(len)?;
    let tail = data.get(start..end)?.to_vec();
    Some((swapper, sats, token, tail))
}

/// On-chain swap-out (delivery rail B): `SwapOutRequestedOnchain(address indexed
/// swapper, uint256 sats, address token, bytes32 indexed swapId, bytes
/// swapperScript)`. The hop delivers BTC ON-CHAIN to `swapper_script` via a
/// swapper-directed splice-out (NOT a BOLT11). The binding is on the EVM (the curve
/// recorded the delivery); `swap_id` is the obligation + dedup key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnchainSwapOutRequest {
    pub swapper: Address,
    pub sats: u64,
    pub token: Address,
    pub swap_id: [u8; 32],
    /// Raw Bitcoin scriptPubKey the delivery splice-out must pay (≤ 34 bytes).
    pub swapper_script: Vec<u8>,
    pub request_block: u64,
}

/// `SwapOutRequestedOnchain(address,uint256,address,bytes32,bytes)` topic0.
pub fn swap_out_requested_onchain_topic() -> [u8; 32] {
    keccak256("SwapOutRequestedOnchain(address,uint256,address,bytes32,bytes)").0
}

/// Decode a `SwapOutRequestedOnchain` log: `data = abi.encode(sats, token,
/// swapperScript)`, `topics = [sig, swapper, swapId]`; the bytes tail is the raw
/// scriptPubKey. All offset/length arithmetic is CHECKED (the log can come from any
/// same-shaped event → `None`, never a panic).
pub fn decode_swap_out_requested_onchain(
    topics: &[[u8; 32]],
    data: &[u8],
    request_block: u64,
) -> Option<OnchainSwapOutRequest> {
    let (swapper, sats, token, swapper_script) =
        decode_swap_out_common(topics, data, swap_out_requested_onchain_topic())?;
    Some(OnchainSwapOutRequest {
        swapper,
        sats,
        token,
        swap_id: topics[2],
        swapper_script, // raw scriptPubKey (not utf-8)
        request_block,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swapin_calldata_layout() {
        let seller = Address::from([0x11u8; 20]);
        let token = Address::ZERO;
        let hash = [0xABu8; 32];
        let cd = settle_swapin_calldata(seller, 50_000, token, hash, U256::from(1_000_000u64), true);
        assert_eq!(cd.len(), 4 + 192);
        assert_eq!(&cd[..4], &keccak256(crate::evm_codec::SIG_SETTLE_SWAP_IN_BUFFERED)[..4]);
        assert_eq!(&cd[4 + 12..4 + 32], &[0x11u8; 20], "word 0: seller");
        assert_eq!(U256::from_be_slice(&cd[4 + 32..4 + 64]), U256::from(50_000u64), "word 1: sats");
        assert_eq!(&cd[4 + 96..4 + 128], &hash, "word 3: paymentHash (idempotency, not the bound)");
        assert_eq!(U256::from_be_slice(&cd[4 + 128..4 + 160]), U256::from(1_000_000u64), "floor");
        assert_eq!(U256::from_be_slice(&cd[4 + 160..4 + 192]), U256::from(1u64), "requireFull");
        let cd0 = settle_swapin_calldata(seller, 50_000, token, hash, U256::from(1_000_000u64), false);
        assert_eq!(U256::from_be_slice(&cd0[4 + 160..4 + 192]), U256::ZERO);
    }

    /// (T1-b) The reversal's calldata layout — and, in the length assertion, the security
    /// property that separates it from a credit: FOUR words, not six. There is nowhere to
    /// put a payee or an amount, so a compromised hop cannot supply either. If someone ever
    /// re-adds them, this test fails on length before anything reaches the chain.
    #[test]
    fn reverse_swap_out_calldata_layout_and_carries_no_payee() {
        let swap_id = [0xCDu8; 32];
        let cd = reverse_swap_out_calldata(swap_id, U256::from(7u64), true);
        // THREE words since §T1-d, not four: the token joined the payee and the sats in the
        // on-chain record, so there is one less thing a compromised hop can choose.
        assert_eq!(cd.len(), 4 + 96, "reversal must carry exactly swapId/floor/flag");
        assert_eq!(&cd[..4], &keccak256(crate::evm_codec::SIG_REVERSE_SWAP_OUT)[..4]);
        assert_eq!(&cd[4..4 + 32], &swap_id, "word 0: swapId verbatim");
        assert_eq!(U256::from_be_slice(&cd[4 + 32..4 + 64]), U256::from(7u64));
        assert_eq!(U256::from_be_slice(&cd[4 + 64..4 + 96]), U256::from(1u64), "requireFull");
        // A reversal must never be mistakable for a credit: different selector entirely.
        let credit = keccak256("settleSwapIn(address,uint256,address,bytes32,uint256,bool)");
        assert_ne!(&cd[..4], &credit[..4]);
        let cd0 = reverse_swap_out_calldata(swap_id, U256::ZERO, false);
        assert_eq!(U256::from_be_slice(&cd0[4 + 64..4 + 96]), U256::ZERO);
    }

    /// The hop's tx policy must ALLOW the reversal — §E178's drift was a policy that
    /// disagreed with the codec, so assert the shared constant is actually in the set the
    /// policy derives from rather than trusting that it was added.
    #[test]
    fn reversal_is_in_the_hop_signed_set() {
        assert!(crate::evm_codec::HOP_BTCCHANNELS_SIGS
            .contains(&crate::evm_codec::SIG_REVERSE_SWAP_OUT));
    }

    #[test]
    fn swap_in_floor_math() {
        // 0.5 BTC (50_000_000 sats) at $50,000/BTC quoted in USDC (6-dec).
        let price = U256::from(50_000u64) * U256::from(1_000_000u64); // 5e10 units/BTC
        let usd = |n: u64| U256::from(n) * U256::from(1_000_000u64);
        // no slippage: expected = 0.5 * 50_000 = $25,000
        assert_eq!(swap_in_floor_usd(50_000_000, price, 0), usd(25_000));
        // 100 bps (1%) tolerance -> $24,750
        assert_eq!(swap_in_floor_usd(50_000_000, price, 100), usd(24_750));
        // full / over-100% tolerance saturates to 0 (no underflow)
        assert_eq!(swap_in_floor_usd(50_000_000, price, 10_000), U256::ZERO);
        assert_eq!(swap_in_floor_usd(50_000_000, price, 20_000), U256::ZERO);
    }

    #[test]
    fn decode_swap_out_onchain_log() {
        let swapper = Address::from([0x42u8; 20]);
        let token = Address::from([0x33u8; 20]);
        let swap_id = [0xA1u8; 32];
        let sats = 500_000u64;
        let script: Vec<u8> = vec![0x00, 0x14, 0x5A, 0x5A, 0x5A]; // raw scriptPubKey
        let mut swapper_topic = [0u8; 32];
        swapper_topic[12..].copy_from_slice(swapper.as_slice());
        let topics = [swap_out_requested_onchain_topic(), swapper_topic, swap_id];
        // data = abi.encode(sats, token, swapperScript) — same layout as the LN variant.
        let mut token_word = [0u8; 32];
        token_word[12..].copy_from_slice(token.as_slice());
        let mut data = U256::from(sats).to_be_bytes::<32>().to_vec();
        data.extend_from_slice(&token_word);
        data.extend_from_slice(&U256::from(0x60u64).to_be_bytes::<32>()); // offset
        data.extend_from_slice(&U256::from(script.len()).to_be_bytes::<32>()); // length
        let mut tail = script.clone();
        tail.resize(script.len().div_ceil(32) * 32, 0);
        data.extend_from_slice(&tail);

        let req = decode_swap_out_requested_onchain(&topics, &data, 888).expect("decodes");
        assert_eq!(req.swapper, swapper);
        assert_eq!(req.token, token);
        assert_eq!(req.swap_id, swap_id);
        assert_eq!(req.sats, sats);
        assert_eq!(req.swapper_script, script);
        assert_eq!(req.request_block, 888);
        // wrong selector / short data → None (watcher skips unrelated logs).
        assert!(decode_swap_out_requested_onchain(&[[0u8; 32], swapper_topic, swap_id], &data, 1).is_none());
        assert!(decode_swap_out_requested_onchain(&topics, &data[..64], 1).is_none());
    }

    #[test]
    fn finality_gate() {
        // request in block 100, need 6 confs.
        assert!(!evm_final(100, 100, 6)); // 1 conf
        assert!(!evm_final(100, 104, 6)); // 5 confs
        assert!(evm_final(100, 105, 6)); // 6 confs (105−100+1)
        assert!(evm_final(100, 200, 6)); // deeply buried
        assert!(!evm_final(100, 99, 6)); // tip behind request → not final
        assert!(evm_final(100, 100, 1)); // 1-conf policy met by inclusion
    }
}

// ───────────────────────────── property-based fuzz ────────────────────────────
//
// `decode_swap_out_requested_onchain` parses the `data`/`topics` of a
// `SwapOutRequestedOnchain` log — which can be emitted by ANY contract with a
// same-shaped event, so the bytes are UNTRUSTED. The attacker-chosen ABI
// offset/length words make the length arithmetic the sharp edge
// (`offset.checked_add`, `data.get(..)`, all in the shared `decode_swap_out_common`
// core); these cases assert the decoder never panics (no slice-OOB, no debug
// overflow) over arbitrary topics + data, and that the well-formed encoding
// round-trips.
#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    fn arb_b32() -> impl Strategy<Value = [u8; 32]> {
        proptest::array::uniform32(any::<u8>())
    }

    /// Well-formed `abi.encode(sats, token, scriptPubKey)`.
    fn encode_data(sats: U256, token: Address, script: &[u8]) -> Vec<u8> {
        let mut token_word = [0u8; 32];
        token_word[12..].copy_from_slice(token.as_slice());
        let mut d = sats.to_be_bytes::<32>().to_vec();
        d.extend_from_slice(&token_word);
        d.extend_from_slice(&U256::from(0x60u64).to_be_bytes::<32>()); // offset
        d.extend_from_slice(&U256::from(script.len()).to_be_bytes::<32>()); // len
        let mut tail = script.to_vec();
        tail.resize(script.len().div_ceil(32) * 32, 0);
        d.extend_from_slice(&tail);
        d
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        // (P1) Fully arbitrary topics (0..5 of them) + arbitrary data + block ⇒
        // never panic. The hostile-offset path is reached when topics happen to be
        // length 3 with the right topic0, but mostly this stresses the early-outs.
        #[test]
        fn decode_swap_out_never_panics(
            topics in proptest::collection::vec(arb_b32(), 0..5),
            data in proptest::collection::vec(any::<u8>(), 0..512),
            block in any::<u64>(),
        ) {
            let _ = decode_swap_out_requested_onchain(&topics, &data, block);
        }

        // (P1b) Force the correct topic0 + 3 topics so the body decoder (the
        // offset/length arithmetic) is exercised on arbitrary data. Still no panic.
        #[test]
        fn decode_swap_out_body_never_panics(
            swapper in proptest::array::uniform20(any::<u8>()),
            swap_id in arb_b32(),
            data in proptest::collection::vec(any::<u8>(), 0..512),
            block in any::<u64>(),
        ) {
            let mut swapper_topic = [0u8; 32];
            swapper_topic[12..].copy_from_slice(&swapper);
            let topics = [swap_out_requested_onchain_topic(), swapper_topic, swap_id];
            let _ = decode_swap_out_requested_onchain(&topics, &data, block);
        }

        // (P2) Round-trip: a well-formed log decodes back to its fields. `sats`
        // capped to u64 (the decoder rejects > u64); the tail is raw bytes.
        #[test]
        fn decode_swap_out_round_trips(
            swapper in proptest::array::uniform20(any::<u8>()),
            token in proptest::array::uniform20(any::<u8>()),
            swap_id in arb_b32(),
            sats in any::<u64>(),
            script in proptest::collection::vec(any::<u8>(), 0..34),
            block in any::<u64>(),
        ) {
            let swapper = Address::from(swapper);
            let token = Address::from(token);
            let mut swapper_topic = [0u8; 32];
            swapper_topic[12..].copy_from_slice(swapper.as_slice());
            let topics = [swap_out_requested_onchain_topic(), swapper_topic, swap_id];
            let data = encode_data(U256::from(sats), token, &script);
            let req = decode_swap_out_requested_onchain(&topics, &data, block).expect("well-formed decodes");
            prop_assert_eq!(req.swapper, swapper);
            prop_assert_eq!(req.token, token);
            prop_assert_eq!(req.sats, sats);
            prop_assert_eq!(req.swap_id, swap_id);
            prop_assert_eq!(req.swapper_script, script);
            prop_assert_eq!(req.request_block, block);
        }
    }
}
