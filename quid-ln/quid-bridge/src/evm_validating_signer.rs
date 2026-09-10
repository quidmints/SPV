//! In-enclave EVM transaction policy — enforced by the hot-key signer
//! ([`crate::signer::LocalSigner`]) at the single signing chokepoint
//! (`sign_eip1559`), when a policy is configured (`with_policy`).
//!
//! Even if a higher layer is compromised (the untrusted host feeding the signer),
//! the enclave will only SIGN a transaction that:
//!   (a) targets a KNOWN protocol contract (`allowed_to`),
//!   (b) calls a KNOWN protocol function selector (`allowed_selectors`), and
//!   (c) moves ZERO ETH value.
//! So a compromised layer cannot get the enclave to sign a tx that redirects funds
//! to an attacker contract, calls an arbitrary/dangerous function, or leaks ETH.
//! Argument-level semantics are still enforced on-chain (the hop calls are
//! hop-gated + capacity-gated); this layer bounds the *shape* of what can be signed.
//!
//! Mirrors the taproot `ValidatingChannelSigner` ethos: a least-privilege
//! in-enclave policy that is defense-in-depth against a PARTIAL compromise, NOT the
//! primary trust boundary. It FAILS CLOSED — an unknown destination, unknown
//! selector, or non-zero value is refused (a legitimately-new call surfaces as a
//! visible sign-refusal to add to the allowlist, never a silent hole).

use std::collections::BTreeSet;

use alloy_primitives::{hex, Address, U256};

use crate::abi::selector4;
use crate::client::TxFields;

/// Every Solidity function signature the hop legitimately SIGNS. The 4-byte
/// selectors are derived from these via `keccak256` ([`selector4`]) so the
/// allowlist reads as the ABI, not opaque hex. Read calls (`eth_call`:
/// `swapInUsed`, `getMainchainHeight`) and event topics never go through the
/// signer, so they are intentionally absent.
const HOP_SIGNED_FN_SIGS: &[&str] = &[
    // --- BTCChannels ---
    // ⛔ DO NOT ADD A BTCChannels SIGNATURE HERE THAT `HOP_BTCCHANNELS_SIGS` ALREADY CARRIES.
    // Listing one in both places makes this the second source of truth that the E178 note
    // below retired, and the codec-derived entry is the one that cannot drift from what is
    // actually sent.
    "markMigrationNonceUsed(bytes32)",
    // ⚠️ (E178) THE BTCChannels CHANNEL-LIFECYCLE SIGNATURES ARE NO LONGER LISTED HERE.
    // They used to be, and they DRIFTED: `openChannel` and `recordClose` changed shape and
    // `registerDelegation` was deleted outright, while this list kept the old text. Because
    // the header below promises "selectors MUST match the contract exactly or the signer
    // rejects", the effect of patching this list in isolation would have been an enclave
    // happily signing calldata that reverts — the list is a SECOND SOURCE OF TRUTH for
    // something `evm_codec` already states, and the drift was the tell.
    // They now come from `HOP_BTCCHANNELS_SIGS`, the SAME constants the codec uses to BUILD
    // the calldata, so the policy cannot disagree with what is actually sent.
    "commitFreshness(bytes32,uint64)",
    "commitManagerFreshness(uint64)",
    // --- SPV gateway ---
    "addBlockHeaderBatch(bytes[])",
    // --- ETH leverage keeper (LevManager / Quid / Rover) ---
    // §C2.1 — the third argument is a POOL WORD (`uint256`), not `bytes` calldata. An allowlist
    // entry is matched by SELECTOR, so a stale signature here does not merely read wrong: it
    // computes a different selector and the signer refuses every keeper tx. Fails CLOSED, which
    // is the right direction and is also why it can sit broken without anyone noticing until the
    // keeper goes quiet.
    "rebalance(address,uint256,uint256,uint256,bytes)",
    "syncLev(address)",
    "protectFromQuid(address,uint256)",
    // (§E247) `compound(address)` was NEVER listed while `lev_keeper.rs` has always built it —
    // the compound crank was refused at the signing chokepoint since it landed. Found by the
    // builder↔allowlist gate (`tools/check-signer-allowlist.py`), which now diffs every
    // signature-shaped literal the keepers build against this list.
    "compound(address)",
    // (2026-08-15) `repackNFT()` was here and is DELETED. It was the only entry in this
    // section with no Rust builder — the other seven each have 2–3 — and no contract declares
    // it: the successor is `repack(bool)`, which is `onlyUs`, so this hot key could never
    // have called it successfully in any case. An allowlist entry that nothing sends and
    // nothing would accept is not harmless; it widens the signable surface while looking
    // deliberate. Do NOT re-add it as `repack(bool)` — `onlyUs` means the protocol calls it,
    // not the keeper.
    // 🔴 §POOLED-EXTRACTION (2026-09-10) — **BOTH BATCH SELECTORS ARE DELETED, HERE AND ON CHAIN.**
    //    `cascadeDelever(address[],uint256[],uint256[],uint256[],bytes[])` and
    //    `rebalanceMany(...)` stood here. §POOL-VENUE collapsed the per-LP enrolment book into ONE
    //    pooled position, so a book-wide de-lever is `repayPool` — O(1) — and the walk both
    //    selectors existed to drive is gone. The keeper now sends per-LP `rebalance(...)`, which is
    //    already listed above. Leaving them would be signable surface nothing sends: the exact
    //    `repackNFT` class this list's own note warns about, and `check-signer-allowlist.py` would
    //    have failed them as ORPHANs.
    // ⏸️ WHEN THE POOLED KEEPER ENTRYPOINT LANDS (TARGET-DESIGN §5b) IT NEEDS AN ENTRY HERE.
    //    `deleverToVault` is RANGE-gated today, so there is nothing for this key to sign yet.
    // --- BTC leverage keeper (BtcLevManager) ---
    // §SLOP: `syncLevBTC(address)` was DELETED with the BTC suffix (`Vault.sol:536` — "one name
    // across both ranges"). ⚠️ THIS ENTRY AND THE KEEPER'S BUILDER MUST MOVE TOGETHER: an allowlist
    // still naming the old selector while the keeper sends the new one makes the signer REJECT every
    // reconcile, and the reverse signs for a selector no contract declares. Caught by
    // `check-client-abis.py`'s Rust ORPHAN check, which exists for exactly this.
    "syncLev(address)",
    "leverBorrow(uint256)",
    "deleverWithdraw(uint256)",
    // (§E247) `repay` — the third native-rail leg (`BtcLevManager:240`). Its two siblings
    // above were listed when the dead-selector rename moved them; this one never was, so
    // the de-lever half of the native rail was refused while the borrow half was signable.
    "repay(uint256)",
    // (§E247) RE-ADDED: the routeless `rebalanceWbtc` was collateral damage of the 1inch
    // revert — `86ca80ec` fixed the original omission by adding the ROUTE form
    // `rebalanceWbtc(address,uint256,bytes)`, and `e4f9c512` reverted that to
    // `rebalance(address,uint256)` alone, dropping the WBTC entry entirely. The keeper
    // (`lev_keeper_btc.rs`) kept building the routeless form, so every WBTC-mode atomic
    // rebalance was again refused at the signing chokepoint. The gate that catches this
    // class either way: `tools/check-signer-allowlist.py`.
    "rebalanceWbtc(address,uint256,uint256,uint256,bytes)",
];

/// The signing policy: which contracts + selectors the hop may sign for.
pub struct EvmTxPolicy {
    allowed_to: BTreeSet<Address>,
    allowed_selectors: BTreeSet<[u8; 4]>,
}

impl EvmTxPolicy {
    /// Build from the protocol contract addresses the hop may call (the zero
    /// address is filtered out, so unset/optional contracts simply aren't allowed).
    /// The selector allowlist is the fixed hop write-surface above.
    pub fn new(allowed_to: impl IntoIterator<Item = Address>) -> Self {
        // (E178) DERIVED, not duplicated: the hand-written list above plus the channel
        // lifecycle signatures the codec itself encodes with.
        let allowed_selectors = HOP_SIGNED_FN_SIGS
            .iter()
            .chain(quid_hop::evm_codec::HOP_BTCCHANNELS_SIGS.iter())
            .map(|sig| {
                let s = selector4(sig);
                [s[0], s[1], s[2], s[3]]
            })
            .collect();
        Self {
            allowed_to: allowed_to
                .into_iter()
                .filter(|a| *a != Address::ZERO)
                .collect(),
            allowed_selectors,
        }
    }

    /// Reject a tx the enclave must not sign. Fails CLOSED.
    pub fn check(&self, f: &TxFields) -> anyhow::Result<()> {
        anyhow::ensure!(
            f.value == U256::ZERO,
            "validating signer: refusing a tx with non-zero ETH value ({}) — the \
             hop only makes calldata-only protocol calls",
            f.value,
        );
        anyhow::ensure!(
            self.allowed_to.contains(&f.to),
            "validating signer: refusing a tx to non-allowlisted contract {} — not \
             a known protocol contract",
            f.to,
        );
        anyhow::ensure!(
            f.data.len() >= 4,
            "validating signer: refusing a tx with <4-byte calldata (no selector)",
        );
        let sel = [f.data[0], f.data[1], f.data[2], f.data[3]];
        anyhow::ensure!(
            self.allowed_selectors.contains(&sel),
            "validating signer: refusing a tx with non-allowlisted selector 0x{} \
             on {} — not a known hop function",
            hex::encode(sel),
            f.to,
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::address;

    const BTC_CHANNELS: Address =
        address!("00000000000000000000000000000000000000cc");
    const ATTACKER: Address = address!("00000000000000000000000000000000000000ba");

    fn fields(to: Address, sig: &str, value: U256) -> TxFields {
        TxFields {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 1,
            gas_limit: 100_000,
            to,
            value,
            data: selector4(sig), // selector only is enough for the policy check
        }
    }

    #[test]
    fn allows_known_call_to_known_contract_with_zero_value() {
        let p = EvmTxPolicy::new([BTC_CHANNELS]);
        p.check(&fields(
            BTC_CHANNELS,
            quid_hop::evm_codec::SIG_SETTLE_SWAP_IN_PROVEN,
            U256::ZERO,
        ))
        .expect("known selector + contract + zero value must pass");
    }

    #[test]
    fn rejects_unknown_destination() {
        let p = EvmTxPolicy::new([BTC_CHANNELS]);
        assert!(
            p.check(&fields(
                ATTACKER,
                quid_hop::evm_codec::SIG_SETTLE_SWAP_IN_PROVEN,
                U256::ZERO,
            ))
            .is_err(),
            "a known selector to an ATTACKER contract must be refused",
        );
    }

    #[test]
    fn rejects_unknown_selector() {
        let p = EvmTxPolicy::new([BTC_CHANNELS]);
        assert!(
            p.check(&fields(BTC_CHANNELS, "transfer(address,uint256)", U256::ZERO))
                .is_err(),
            "an unknown (e.g. ERC20 transfer) selector must be refused",
        );
    }

    #[test]
    fn rejects_non_zero_value() {
        let p = EvmTxPolicy::new([BTC_CHANNELS]);
        assert!(
            p.check(&fields(
                BTC_CHANNELS,
                quid_hop::evm_codec::SIG_SETTLE_SWAP_IN_PROVEN,
                U256::from(1),
            ))
            .is_err(),
            "any non-zero ETH value must be refused",
        );
    }

    #[test]
    fn zero_address_is_not_allowlisted() {
        // An unset (zero) contract must not become a wildcard-allow.
        //
        // ⚠️ The selector here MUST be one that is genuinely allowlisted, or this test passes
        // for the wrong reason — the policy would reject on the SELECTOR and never exercise
        // the destination rule at all. It used `repackNFT()`, which was allowlisted at the
        // time and is not any more, so deleting that entry would have quietly hollowed this
        // out into a vacuous pass. `syncLev(address)` is live and stays live (it has Rust
        // builders), so the rejection can only come from the zero destination.
        let p = EvmTxPolicy::new([Address::ZERO, BTC_CHANNELS]);
        assert!(
            p.check(&fields(BTC_CHANNELS, "syncLev(address)", U256::ZERO))
                .is_ok(),
            "precondition: this selector must be allowlisted to a real contract, else the \
             zero-address assertion below proves nothing",
        );
        assert!(
            p.check(&fields(Address::ZERO, "syncLev(address)", U256::ZERO))
                .is_err(),
            "the zero address must never be an allowed destination",
        );
    }
}
