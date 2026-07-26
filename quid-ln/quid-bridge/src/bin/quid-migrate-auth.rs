//! Operator tooling for enclave-migration authorizations.
//!
//! The old enclave only exports its seed to a successor MRENCLAVE carrying a
//! [`MigrationAuth`] signed by ≥`MIGRATION_THRESHOLD` owners of the operator
//! **Gnosis Safe** (`quid_hop::migration::OPERATOR_SAFE` / `OPERATOR_OWNERS`).
//! In production operators sign the EIP-712 digest in their wallet / the Safe UI;
//! this tool is for dev/CI and air-gapped operator boxes. Run it OFF the host.
//!
//! Generate an operator (Safe-owner) key; print the EVM address to add to the Safe:
//!   quid-migrate-auth --gen-key <secret.out>
//!
//! Print the EIP-712 digest to sign in a wallet (no key needed):
//!   quid-migrate-auth --digest --measurement <hex32> --network <net>
//!
//! Sign an authorization with an operator key (writes a 1-signature bundle):
//!   quid-migrate-auth --sign --key <secret> --measurement <hex32> \
//!       --network <net> --out <auth.bin>
//!
//! Combine ≥threshold single-signature bundles into the final authorization:
//!   quid-migrate-auth --combine <out-bundle> <auth1.bin> <auth2.bin> [...]
//!
//! [`MigrationAuth`]: quid_hop::migration::MigrationAuth

use std::str::FromStr;

use anyhow::{Context, bail, ensure};
use quid_common::ln::network::Network;
use quid_crypto::rng::{RngExt, SysRng};
use quid_enclave::enclave::Measurement;
use quid_hop::{
    migration::{
        MigrationAuth, MigrationAuthBundle, combine_migration_auths, operator_address,
        sign_migration_auth,
    },
    seed::deploy_env_for_network,
};

use quid_bridge::boot::flag;

/// Build the MigrationAuth from `--measurement` + `--network` flags.
fn auth_from_flags(args: &[String]) -> anyhow::Result<MigrationAuth> {
    let measurement = Measurement::from_str(
        &flag(args, "--measurement")
            .context("--measurement <hex32> required (successor MRENCLAVE)")?,
    )
    .context("--measurement must be 32-byte hex")?;
    let network = Network::from_str(&flag(args, "--network").context("--network required")?)
        .map_err(|_| anyhow::anyhow!("unknown --network"))?;
    let deploy_env = deploy_env_for_network(network);
    // ANTI-REPLAY nonce (audit HIGH): unique per authorization; the migrating enclave
    // consumes it on-chain before exporting, so a captured bundle can't re-export the seed.
    // All 2-of-3 signers must sign the SAME nonce — one operator generates it (printed here)
    // and shares the hex; co-signers pass `--nonce <hex32>`.
    let nonce: [u8; 32] = match flag(args, "--nonce") {
        Some(h) => *Measurement::from_str(&h)
            .context("--nonce must be 32-byte hex")?
            .as_ref(),
        None => {
            let n = SysRng::new().gen_bytes::<32>();
            eprintln!(
                "generated migration nonce (share with co-signers via --nonce): 0x{}",
                n.iter().map(|b| format!("{b:02x}")).collect::<String>()
            );
            n
        }
    };
    Ok(MigrationAuth { measurement, deploy_env, network, nonce })
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    if let Some(out) = flag(&args, "--gen-key") {
        let secret = SysRng::new().gen_bytes();
        let addr = operator_address(&secret).context("derive operator address")?;
        std::fs::write(&out, secret)
            .with_context(|| format!("write operator secret to {out}"))?;
        println!("wrote operator secret key -> {out} (KEEP OFF-HOST for prod)");
        println!("operator (Safe-owner) address: {addr}");
        println!("add this address as an owner of the operator Safe (OPERATOR_SAFE).");
        return Ok(());
    }

    if args.iter().any(|a| a == "--digest") {
        let auth = auth_from_flags(&args)?;
        let digest = auth.eip712_digest();
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        println!("EIP-712 MigrationAuth digest (sign this in your wallet): 0x{hex}");
        return Ok(());
    }

    if args.iter().any(|a| a == "--sign") {
        let key_path = flag(&args, "--key").context("--key <secret> required")?;
        let secret = std::fs::read(&key_path)
            .with_context(|| format!("read operator secret {key_path}"))?;
        let secret: [u8; 32] = secret
            .as_slice()
            .try_into()
            .context("operator secret must be 32 bytes")?;

        let auth = auth_from_flags(&args)?;
        let out = flag(&args, "--out").context("--out <path> required")?;
        let sig = sign_migration_auth(&secret, &auth).context("sign migration auth")?;
        // A 1-signature bundle; --combine merges several of these.
        let bundle = combine_migration_auths(auth.clone(), vec![sig])
            .context("serialize single-signature bundle")?;
        std::fs::write(&out, &bundle)
            .with_context(|| format!("write authorization to {out}"))?;
        println!(
            "wrote 1-sig migration auth for {} ({}/{}) -> {out} ({} bytes)",
            auth.measurement, auth.network, auth.deploy_env, bundle.len(),
        );
        return Ok(());
    }

    if let Some(idx) = args.iter().position(|a| a == "--combine") {
        // quid-migrate-auth --combine <out-bundle> <auth1.bin> <auth2.bin> [...]
        let out = args
            .get(idx + 1)
            .context("--combine <out-bundle> <auth1> <auth2> [...] — out path required")?;
        let paths = &args[idx + 2..];
        ensure!(paths.len() >= 2, "--combine needs >=2 single-signature bundles");

        let mut agreed: Option<MigrationAuth> = None;
        let mut sigs: Vec<Vec<u8>> = Vec::new();
        for p in paths {
            let raw = std::fs::read(p).with_context(|| format!("read bundle {p}"))?;
            let b: MigrationAuthBundle =
                serde_json::from_slice(&raw).with_context(|| format!("parse bundle {p}"))?;
            match &agreed {
                Some(a) => ensure!(*a == b.auth, "bundles authorize different migrations"),
                None => agreed = Some(b.auth.clone()),
            }
            sigs.extend(b.signatures);
        }
        let auth = agreed.context("no bundles provided")?;
        let bundle =
            combine_migration_auths(auth, sigs.clone()).context("combine migration auths")?;
        std::fs::write(out, &bundle).with_context(|| format!("write bundle to {out}"))?;
        println!(
            "wrote {}-signature migration auth bundle -> {out} ({} bytes)",
            sigs.len(),
            bundle.len(),
        );
        return Ok(());
    }

    bail!(
        "usage: quid-migrate-auth --gen-key <out> | --digest --measurement <hex32> --network <net> \
         | --sign --key <secret> --measurement <hex32> --network <net> --out <path> \
         | --combine <out> <auth1> <auth2> [...]"
    );
}
