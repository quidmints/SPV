//! Boot-time env/secret parsing shared by the daemon binaries (`quid-bridge-daemon`,
//! `quid-lp-daemon`). These are pure config helpers — the same env-var reads, the same
//! 32-byte-secret decode, and the same fail-loud placeholder-key guard — factored out
//! of the two `bin/` entrypoints so the boot contract lives in one place.

use std::net::Ipv4Addr;
use std::str::FromStr;

use alloy_primitives::hex;
use anyhow::{anyhow, ensure, Context};

use quid_api::cli::LspInfo;
use quid_common::api::user::NodePk;
use quid_common::root_seed::RootSeed;
use quid_common::ln::addr::LxSocketAddress;
use quid_common::ppm::Ppm;

/// Read a REQUIRED env var, erroring (never defaulting) if it is unset.
pub fn env(key: &str) -> anyhow::Result<String> {
    std::env::var(key).map_err(|_| anyhow!("missing required env var {key}"))
}

/// Read an OPTIONAL env var, falling back to `default` if unset.
pub fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Read an OPTIONAL env var and `parse()` it, falling back to `default` if unset;
/// a present-but-unparseable value is an error (not silently the default).
pub fn env_parse<T: FromStr>(key: &str, default: T) -> anyhow::Result<T> {
    match std::env::var(key) {
        Ok(v) => v.parse().map_err(|_| anyhow!("env {key}: bad value {v:?}")),
        Err(_) => Ok(default),
    }
}

/// Decode a `0x`-prefixed (or bare) 32-byte hex secret, rejecting the wrong length
/// and obviously-broken placeholder keys (see [`reject_weak_secret`]).
pub fn hex32(s: &str) -> anyhow::Result<[u8; 32]> {
    let v = hex::decode(s.trim_start_matches("0x"))?;
    let bytes = <[u8; 32]>::try_from(v.as_slice())
        .map_err(|_| anyhow!("expected 32 bytes, got {}", v.len()))?;
    reject_weak_secret(&bytes)?;
    Ok(bytes)
}

/// Fail LOUD at boot on an obviously-broken secret (a misconfigured/placeholder
/// key must never sign live). Minimal by design — rejects all-zero and all-
/// identical bytes (e.g. `0x0101…01`); NOT an entropy estimator. `hex32` only
/// decodes secrets here (QUID_HOT_KEY / QUID_SEED / QUID_LP_EVM_KEY).
fn reject_weak_secret(bytes: &[u8; 32]) -> anyhow::Result<()> {
    if bytes.iter().all(|&b| b == 0) {
        anyhow::bail!("secret is all-zero bytes — refusing to boot with a placeholder key");
    }
    if bytes.iter().all(|&b| b == bytes[0]) {
        anyhow::bail!(
            "secret is all-identical bytes (0x{:02x} repeated) — refusing to boot with a \
             placeholder key",
            bytes[0]
        );
    }
    Ok(())
}

/// The node's EVM signing key (the hop's `onlyHop` hot key, or an LP's `lpAuth`
/// key). By default it is **DERIVED from the born-in-enclave sealed [`RootSeed`]**
/// via [`RootSeed::derive_eth_wallet_key`] — so under SGX it is born inside the
/// enclave and never exists in plaintext outside it.
///
/// In an enclave (SGX) the derived key is the ONLY source: a host-supplied
/// `env_name` (`QUID_HOT_KEY` / `QUID_LP_EVM_KEY`) is **REFUSED**, exactly like
/// [`quid_hop::seed::SeedSource::Import`] — a host-supplied key carries no enclave
/// binding, so accepting it would let the untrusted host sign with a key IT
/// controls, defeating custody. Off-SGX (host-trusted self-host / dev / e2e) the
/// env var may override the derivation as a convenience (the operator trusts their
/// own host, so a local plaintext key is fine there).
pub fn evm_signing_key(
    root_seed: &RootSeed,
    env_name: &str,
) -> anyhow::Result<secp256k1::SecretKey> {
    match std::env::var(env_name) {
        Ok(hex) => {
            ensure!(
                !cfg!(target_env = "sgx"),
                "{env_name} is refused inside an SGX enclave: the EVM signing key \
                 must be derived from the sealed seed, never host-supplied",
            );
            secp256k1::SecretKey::from_slice(&hex32(&hex)?)
                .with_context(|| env_name.to_string())
        }
        Err(_) => Ok(root_seed.derive_eth_wallet_key()),
    }
}

/// Simple `--name value` CLI-flag lookup: find `name` in `args` and return the
/// following token, if any. Shared by the `quid-provision` / `quid-migrate-auth`
/// CLI entrypoints.
pub fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

/// Build the [`LspInfo`] advertised to LP counterparties from `QUID_LSP_NODE_PK`
/// (33-byte compressed hex) + `QUID_LSP_ADDR` (`host:port`). The fee/HTLC fields
/// are fixed policy constants. Shared by both daemon binaries.
pub fn build_lsp_info() -> anyhow::Result<LspInfo> {
    let pk_bytes = hex::decode(env("QUID_LSP_NODE_PK")?.trim_start_matches("0x"))?;
    let node_pk =
        NodePk(secp256k1::PublicKey::from_slice(&pk_bytes).context("QUID_LSP_NODE_PK: bad pubkey")?);
    let addr = env("QUID_LSP_ADDR")?;
    let (host, port) = addr
        .rsplit_once(':')
        .ok_or_else(|| anyhow!("QUID_LSP_ADDR: want host:port"))?;
    Ok(LspInfo {
        node_pk,
        private_p2p_addr: LxSocketAddress::TcpIpv4 {
            ip: host.parse::<Ipv4Addr>().context("QUID_LSP_ADDR host")?,
            port: port.parse().context("QUID_LSP_ADDR port")?,
        },
        lsp_usernode_base_fee_msat: 0,
        lsp_usernode_prop_fee: Ppm::ZERO,
        lsp_external_prop_fee: Ppm::ZERO,
        lsp_external_base_fee_msat: 0,
        cltv_expiry_delta: 72,
        htlc_minimum_msat: 1,
        htlc_maximum_msat: 21_000_000_0000_0000,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evm_signing_key_derives_from_seed_when_env_unset() {
        // With the (guaranteed-unset) env var absent, the key is derived from the
        // sealed seed — the enclave path. This is the security-critical default.
        let seed = RootSeed::from_str(&"ab".repeat(32)).unwrap();
        let k = evm_signing_key(&seed, "QUID_DEFINITELY_UNSET_EVM_KEY_9f3a").unwrap();
        assert_eq!(
            k.secret_bytes(),
            seed.derive_eth_wallet_key().secret_bytes(),
            "unset env must derive the EVM key from the seed",
        );
    }

    #[test]
    fn reject_weak_secret_catches_placeholders() {
        // All-zero and all-same-byte secrets are rejected (loud boot failure).
        assert!(reject_weak_secret(&[0u8; 32]).is_err(), "all-zero must be rejected");
        assert!(reject_weak_secret(&[0x01u8; 32]).is_err(), "all-0x01 must be rejected");
        assert!(reject_weak_secret(&[0xffu8; 32]).is_err(), "all-0xff must be rejected");
        // A normal-looking key passes.
        let mut k = [0u8; 32];
        for (i, b) in k.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(7).wrapping_add(3);
        }
        assert!(reject_weak_secret(&k).is_ok(), "a varied key must pass");
        // hex32 wires the guard in.
        assert!(hex32(&"00".repeat(32)).is_err());
        assert!(hex32(&"01".repeat(32)).is_err());
    }
}
