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
    "settleSwapIn(address,uint256,address,bytes32,uint256,bool)",
    "markMigrationNonceUsed(bytes32)",
    // (B) openChannel/splice/deliver dropped the per-call lpAuth: openChannel takes the
    // on-chain-delegated `lpEth`, splice carries `feeSettleSats`, deliver is gated on
    // the channel hop. Selectors MUST match the contract exactly or the signer rejects.
    "openChannel((bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32[],address)",
    "splice(bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32[],uint256)",
    "registerDelegation(address,bytes32,uint64,bytes)",
    "recordClose(bytes32,bytes,bytes32,bytes32[],uint256)",
    "recordForceClosePermissionless(bytes32,bytes,bytes32,bytes32[],uint256)",
    "deliverSwapOutOnchain(bytes32,bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32[],bytes)",
    "commitFreshness(bytes32,uint64)",
    "commitManagerFreshness(uint64)",
    // --- SPV gateway ---
    "addBlockHeaderBatch(bytes[])",
    // --- ETH leverage keeper (LevManager / Vogue / Rover) ---
    "rebalance(address,uint256)",
    "syncLev(address)",
    "protectFromQuid(address,uint256)",
    "repackNFT()",
    "cascadeDelever(address[],uint256[])",
    // --- BTC leverage keeper (BtcLevManager) ---
    "syncLevBTC(address)",
    "leverBorrow(uint256)",
    "deleverWithdraw(uint256)",
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
        let allowed_selectors = HOP_SIGNED_FN_SIGS
            .iter()
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
            "settleSwapIn(address,uint256,address,bytes32,uint256,bool)",
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
                "settleSwapIn(address,uint256,address,bytes32,uint256,bool)",
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
                "settleSwapIn(address,uint256,address,bytes32,uint256,bool)",
                U256::from(1),
            ))
            .is_err(),
            "any non-zero ETH value must be refused",
        );
    }

    #[test]
    fn zero_address_is_not_allowlisted() {
        // An unset (zero) contract must not become a wildcard-allow.
        let p = EvmTxPolicy::new([Address::ZERO, BTC_CHANNELS]);
        assert!(
            p.check(&fields(Address::ZERO, "repackNFT()", U256::ZERO))
                .is_err(),
            "the zero address must never be an allowed destination",
        );
    }
}
