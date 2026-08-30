//! Local EIP-1559 (type-2) transaction signer for the hot `onlyHop` key.
//!
//! NOT hand-rolled crypto: the ECDSA is `secp256k1::sign_ecdsa_recoverable` (the
//! vetted libsecp256k1 binding quid uses for Bitcoin/LN), the hash is
//! `alloy_primitives::keccak256`. The only bespoke part is the EIP-1559 RLP field
//! layout, which is verified BYTE-EXACT against a `cast`-generated reference
//! vector in the tests below (deterministic RFC-6979 signing ⇒ the signature
//! bytes match `cast`/alloy exactly).

use alloy_primitives::{keccak256, Address};
use secp256k1::{Message, PublicKey, Secp256k1, SecretKey};

use crate::client::{TxFields, TxSigner};

/// A hot-key signer over secp256k1.
pub struct LocalSigner {
    secp: Secp256k1<secp256k1::All>,
    sk: SecretKey,
    address: Address,
    /// Optional in-enclave tx policy. When set (the daemon attaches it via
    /// [`Self::with_policy`]), `sign_eip1559` refuses to sign anything outside the
    /// allowed protocol contracts + selectors + zero value. `None` (tests / e2e)
    /// signs unconstrained.
    policy: Option<crate::evm_validating_signer::EvmTxPolicy>,
}

impl LocalSigner {
    /// Build from a 32-byte secp256k1 secret key. No tx policy is attached; use
    /// [`Self::with_policy`] to constrain what it will sign.
    pub fn from_secret_key_bytes(bytes: [u8; 32]) -> anyhow::Result<Self> {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&bytes)?;
        let pk = PublicKey::from_secret_key(&secp, &sk);
        // EVM address derivation — the single audited home (mirrors the bridge's
        // lpAuth recovery + LpAuthResponder::lp_eth).
        let address = quid_hop::evm_codec::evm_address_of(&pk);
        Ok(Self { secp, sk, address, policy: None })
    }

    /// Attach the in-enclave [`crate::evm_validating_signer::EvmTxPolicy`] that
    /// `sign_eip1559` enforces before signing (defense-in-depth: only known
    /// protocol calls with zero ETH value; fails closed).
    pub fn with_policy(
        mut self,
        policy: crate::evm_validating_signer::EvmTxPolicy,
    ) -> Self {
        self.policy = Some(policy);
        self
    }
}

impl TxSigner for LocalSigner {
    fn address(&self) -> Address {
        self.address
    }

    fn sign_eip1559(&self, f: &TxFields) -> anyhow::Result<Vec<u8>> {
        // In-enclave tx policy (when configured): refuse to sign anything outside
        // the allowed protocol contracts + selectors + zero ETH value.
        if let Some(policy) = &self.policy {
            policy.check(f)?;
        }
        // The 9 unsigned fields, RLP-encoded into the list payload.
        let mut fields = Vec::new();
        rlp_uint(&mut fields, &f.chain_id.to_be_bytes());
        rlp_uint(&mut fields, &f.nonce.to_be_bytes());
        rlp_uint(&mut fields, &f.max_priority_fee_per_gas.to_be_bytes());
        rlp_uint(&mut fields, &f.max_fee_per_gas.to_be_bytes());
        rlp_uint(&mut fields, &f.gas_limit.to_be_bytes());
        rlp_str(&mut fields, f.to.as_slice());
        rlp_uint(&mut fields, &f.value.to_be_bytes::<32>());
        rlp_str(&mut fields, &f.data);
        rlp_list(&mut fields, &[]); // empty access list

        // sighash = keccak256(0x02 ‖ rlp([...9 fields]))
        let mut pre = vec![0x02u8];
        rlp_list(&mut pre, &fields);
        let sighash = keccak256(&pre);

        // Deterministic (RFC-6979) recoverable signature.
        let msg = Message::from_digest(sighash.0);
        let sig = self.secp.sign_ecdsa_recoverable(&msg, &self.sk);
        let (rec_id, compact) = sig.serialize_compact();
        let y_parity = rec_id.to_i32() as u8; // 0 or 1 for canonical secp256k1

        // Append the signature fields and re-wrap as the signed type-2 envelope.
        let mut signed = fields;
        rlp_uint(&mut signed, &[y_parity]);
        rlp_uint(&mut signed, &compact[0..32]); // r
        rlp_uint(&mut signed, &compact[32..64]); // s

        let mut raw = vec![0x02u8];
        rlp_list(&mut raw, &signed);
        Ok(raw)
    }
}

// ─── minimal RLP (verified byte-exact against the cast vector below) ──────────

/// RLP-encode a byte string.
fn rlp_str(out: &mut Vec<u8>, bytes: &[u8]) {
    if bytes.len() == 1 && bytes[0] < 0x80 {
        out.push(bytes[0]);
    } else {
        rlp_len_header(out, 0x80, bytes.len());
        out.extend_from_slice(bytes);
    }
}

/// RLP-encode an integer: minimal big-endian (strip leading zeros), as a string.
/// Zero ⇒ the empty string (`0x80`).
fn rlp_uint(out: &mut Vec<u8>, be: &[u8]) {
    let start = be.iter().position(|&b| b != 0).unwrap_or(be.len());
    rlp_str(out, &be[start..]);
}

/// RLP-encode a list whose already-encoded payload is `payload`.
fn rlp_list(out: &mut Vec<u8>, payload: &[u8]) {
    rlp_len_header(out, 0xc0, payload.len());
    out.extend_from_slice(payload);
}

/// Length header: short form (<56) or long form (length-of-length prefix).
fn rlp_len_header(out: &mut Vec<u8>, base: u8, len: usize) {
    if len < 56 {
        out.push(base + len as u8);
    } else {
        let lb = minimal_be(len);
        out.push(base + 55 + lb.len() as u8);
        out.extend_from_slice(&lb);
    }
}

/// Big-endian bytes of `n`, no leading zeros (empty for 0).
fn minimal_be(mut n: usize) -> Vec<u8> {
    let mut v = Vec::new();
    while n > 0 {
        v.push((n & 0xff) as u8);
        n >>= 8;
    }
    v.reverse();
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{address, hex, U256};

    /// Anvil account #0 — public, well-known test key.
    const ANVIL0_SK: &str =
        "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    fn anvil0() -> LocalSigner {
        let bytes: [u8; 32] = hex::decode(ANVIL0_SK).unwrap().try_into().unwrap();
        LocalSigner::from_secret_key_bytes(bytes).unwrap()
    }

    #[test]
    fn address_derivation_matches_known_anvil0() {
        assert_eq!(
            anvil0().address(),
            address!("f39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
        );
    }

    #[test]
    fn embedded_policy_enforced_at_sign_time() {
        use crate::evm_validating_signer::EvmTxPolicy;
        let allowed = address!("00000000000000000000000000000000000000cc");
        let signer = anvil0().with_policy(EvmTxPolicy::new([allowed]));
        let base = TxFields {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 1,
            gas_limit: 100_000,
            to: allowed,
            value: U256::ZERO,
            data: crate::abi::selector4(
                quid_hop::evm_codec::SIG_SETTLE_SWAP_IN_PROVEN,
            ),
        };
        // Allowed contract + known selector + zero value → signs.
        assert!(signer.sign_eip1559(&base).is_ok(), "allowed tx must sign");
        // Wrong destination → refused at sign time (the embedded policy fires).
        let bad_to = TxFields {
            to: address!("00000000000000000000000000000000000000ba"),
            ..base.clone()
        };
        assert!(signer.sign_eip1559(&bad_to).is_err(), "disallowed dest refused");
        // Non-zero ETH value → refused.
        let bad_val = TxFields { value: U256::from(1), ..base.clone() };
        assert!(signer.sign_eip1559(&bad_val).is_err(), "non-zero value refused");
        // With NO policy the same "bad" tx signs (tests / e2e path).
        assert!(anvil0().sign_eip1559(&bad_to).is_ok(), "no policy = unconstrained");
    }

    #[test]
    fn signs_byte_exact_against_cast_vector() {
        // Generated offline by: `cast mktx 0x..bc --private-key <anvil0> --nonce 5
        // --gas-limit 300000 --priority-gas-price 1000000 --gas-price 1000000000
        // --value 0 --chain 8453 0xdeadbeef`
        let expected = "02f87082210505830f4240843b9aca00830493e09400000000000000000000000000000000000000bc8084deadbeefc080a058065f7e8c2e946d2f63cce66519eb369f4c806a8ffd7d4a3202d67c55d486dda01ea320430bcc80c5a3253d5debf405bf8b1977ea5e4d744ee30bc0d9e3e73779";

        let fields = TxFields {
            chain_id: 8453,
            nonce: 5,
            max_priority_fee_per_gas: 1_000_000,
            max_fee_per_gas: 1_000_000_000,
            gas_limit: 300_000,
            to: address!("00000000000000000000000000000000000000bc"),
            value: U256::ZERO,
            data: hex::decode("deadbeef").unwrap(),
        };
        let raw = anvil0().sign_eip1559(&fields).unwrap();
        assert_eq!(hex::encode(raw), expected, "raw tx must match cast byte-for-byte");
    }

    #[test]
    fn rlp_uint_strips_leading_zeros_and_zero_is_empty_string() {
        let mut out = Vec::new();
        rlp_uint(&mut out, &0u64.to_be_bytes());
        assert_eq!(out, vec![0x80]); // 0 → empty string
        out.clear();
        rlp_uint(&mut out, &0x2105u64.to_be_bytes());
        assert_eq!(out, vec![0x82, 0x21, 0x05]); // 8453
    }
}
