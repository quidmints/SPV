//! Operator tooling for enclave-migration AND wallet-sweep authorizations.
//!
//! Both are threshold-signed by owners of the operator multisig
//! (`quid_hop::migration::OPERATOR_SAFE` / `OPERATOR_OWNERS` — the constants keep their
//! historical names; the deployment is a plain multisig, not a Gnosis Safe, and nothing here
//! calls it. The enclave only ever `ecrecover`s owner signatures over an EIP-712 digest and
//! pins the address as `verifyingContract`, which any multisig supplies).
//! In production operators sign the EIP-712 digest in their wallet; this tool is for dev/CI
//! and air-gapped operator boxes. Run it OFF the host.
//!
//! ONE TOOL, TWO AUTHORIZATIONS — selected by which subject flag you pass:
//!   `--measurement <hex32>` ⇒ a **MigrationAuth** (export the seed to a successor enclave)
//!   `--destination <addr>`  ⇒ a **SweepAuth**     (drain the hop's on-chain wallet)
//! The digest, sign and combine flows are otherwise identical, and the threshold verification
//! helper is already shared, so the fold is a discriminator rather than a second tool.
//!
//! Generate an operator (multisig-owner) key; print the EVM address to add as an owner:
//!   quid-migrate-auth --gen-key <secret.out>
//!
//! Print the EIP-712 digest to sign in a wallet (no key needed):
//!   quid-migrate-auth --digest --measurement <hex32> --network <net>
//!   quid-migrate-auth --digest --destination <btc-addr> --network <net>
//!
//! Sign an authorization with an operator key (writes a 1-signature bundle):
//!   quid-migrate-auth --sign --key <secret> --measurement <hex32> \
//!       --network <net> --out <auth.bin>
//!   quid-migrate-auth --sign --key <secret> --destination <btc-addr> \
//!       --network <net> --out <auth.bin>
//!
//! Combine ≥threshold single-signature bundles into the final authorization:
//!   quid-migrate-auth --combine <out-bundle> <auth1.bin> <auth2.bin> [...]
//! (the bundle type is read from the FILES, not from a flag — see `--combine` below)
//!
//! [`MigrationAuth`]: quid_hop::migration::MigrationAuth

use std::str::FromStr;

use anyhow::{Context, bail, ensure};
use quid_common::ln::network::Network;
use quid_crypto::rng::{RngExt, SysRng};
use quid_enclave::enclave::Measurement;
use quid_hop::{
    migration::{
        MigrationAuth, MigrationAuthBundle, SweepAuth, SweepAuthBundle, combine_migration_auths,
        combine_sweep_auths, operator_address, sign_migration_auth, sign_sweep_auth,
    },
    seed::deploy_env_for_network,
};

use quid_bridge::boot::flag;

/// The two authorizations this tool produces. They carry the same `deploy_env`, `network` and
/// anti-replay `nonce`; only the SUBJECT differs — a successor measurement, or a destination
/// address. Everything below branches once, here, instead of duplicating the whole flow.
enum Auth {
    Migration(MigrationAuth),
    Sweep(SweepAuth),
}

impl Auth {
    fn digest(&self) -> [u8; 32] {
        match self {
            Auth::Migration(a) => a.eip712_digest(),
            Auth::Sweep(a) => a.eip712_digest(),
        }
    }

    /// 🔑 The EIP-712 type name, and it is NOT cosmetic. The operator signs a HASH; this label
    /// is the only thing in the flow that tells them whether they are authorizing an enclave
    /// migration or a drain of the entire on-chain wallet. The domain separators differ
    /// (`QUID Migration` vs `QUID Sweep`) so the two can never be interchanged on-chain — but a
    /// human approving the wrong one is a failure that happens BEFORE any of that helps.
    fn kind(&self) -> &'static str {
        match self {
            Auth::Migration(_) => "MigrationAuth",
            Auth::Sweep(_) => "SweepAuth",
        }
    }

    /// What is being authorized, for the receipt line — the successor measurement, or the
    /// destination address the whole balance leaves to.
    fn subject(&self) -> String {
        match self {
            Auth::Migration(a) => format!("measurement {}", a.measurement),
            Auth::Sweep(a) => format!("destination {}", a.destination),
        }
    }

    fn context(&self) -> String {
        match self {
            Auth::Migration(a) => format!("{}/{}", a.network, a.deploy_env),
            Auth::Sweep(a) => format!("{}/{}", a.network, a.deploy_env),
        }
    }

    fn sign(&self, secret: &[u8; 32]) -> anyhow::Result<Vec<u8>> {
        match self {
            Auth::Migration(a) => sign_migration_auth(secret, a).context("sign migration auth"),
            Auth::Sweep(a) => sign_sweep_auth(secret, a).context("sign sweep auth"),
        }
    }

    fn combine(self, sigs: Vec<Vec<u8>>) -> anyhow::Result<Vec<u8>> {
        match self {
            Auth::Migration(a) => combine_migration_auths(a, sigs).context("combine migration"),
            Auth::Sweep(a) => combine_sweep_auths(a, sigs).context("combine sweep"),
        }
    }
}

/// The anti-replay nonce, shared by both authorization types (audit HIGH): unique per
/// authorization, and consumed on-chain before the seed is exported or the sweep broadcasts,
/// so a captured bundle authorizes at most one action. All signers must sign the SAME nonce —
/// one operator generates it (printed here) and shares the hex; co-signers pass `--nonce`.
fn nonce_from_flags(args: &[String]) -> anyhow::Result<[u8; 32]> {
    Ok(match flag(args, "--nonce") {
        Some(h) => *Measurement::from_str(&h).context("--nonce must be 32-byte hex")?.as_ref(),
        None => {
            let n = SysRng::new().gen_bytes::<32>();
            eprintln!(
                "generated nonce (share with co-signers via --nonce): 0x{}",
                n.iter().map(|b| format!("{b:02x}")).collect::<String>()
            );
            n
        }
    })
}

/// 🔴 VALIDATE THE DESTINATION BEFORE ANY DIGEST IS PRINTED, AND THIS IS THE ONE PLACE THE TWO
/// AUTHORIZATIONS ARE NOT SYMMETRIC.
///
/// A `Measurement` is fixed-length hex: a typo CANNOT parse, so the type does the checking. A
/// destination is a free-form `String`, and a mistyped address parses fine — then every owner
/// signs it, the threshold is met, and the entire wallet leaves to an address nobody controls,
/// irreversibly, under a perfectly valid authorization. Mirroring the migration flow would have
/// carried that straight through.
///
/// It runs before the digest because operators sign the DIGEST: once that hex is on screen, a
/// bad address is already what is being approved.
///
/// ⚠️ The returned string is the one the caller TYPED, never a canonical re-encoding.
/// `SweepAuth::destination` is text on purpose — "the signers approved a human-readable address,
/// and re-encoding it into bytes here would let a parsing difference change what they approved".
/// So this validates and SHOWS; it never silently rewrites. Where the canonical form differs, it
/// says so and lets the human decide.
fn validated_destination(raw: &str, network: Network) -> anyhow::Result<String> {
    let parsed = bitcoin::Address::from_str(raw)
        .with_context(|| format!("--destination {raw:?} is not a Bitcoin address"))?;
    let checked = parsed.require_network(network.to_bitcoin()).with_context(|| {
        format!("--destination {raw:?} is not valid on {network} (wrong-network address is the likeliest real typo)")
    })?;
    eprintln!("destination validated on {network}: {checked}");
    if let Some(kind) = checked.address_type() {
        eprintln!("  address type: {kind}");
    }
    if checked.to_string() != raw {
        eprintln!("⚠️  the canonical form differs from what you typed:");
        eprintln!("      typed:     {raw}");
        eprintln!("      canonical: {checked}");
        eprintln!("    The SIGNED value is what you TYPED. Confirm both name the same address.");
    }
    Ok(raw.to_string())
}

/// Build the authorization from flags. `--measurement` ⇒ migration, `--destination` ⇒ sweep.
/// Passing both is refused rather than resolved by precedence: which one won would decide
/// whether owners authorize a migration or a wallet drain, and that must never be implicit.
fn auth_from_flags(args: &[String]) -> anyhow::Result<Auth> {
    let network = Network::from_str(&flag(args, "--network").context("--network required")?)
        .map_err(|_| anyhow::anyhow!("unknown --network"))?;
    let deploy_env = deploy_env_for_network(network);
    let measurement = flag(args, "--measurement");
    let destination = flag(args, "--destination");

    match (measurement, destination) {
        (Some(_), Some(_)) => bail!(
            "pass EITHER --measurement (migration) OR --destination (sweep), not both — \
             letting one win silently would decide whether owners authorize an enclave \
             migration or a drain of the entire on-chain wallet"
        ),
        (Some(m), None) => {
            let measurement =
                Measurement::from_str(&m).context("--measurement must be 32-byte hex")?;
            let nonce = nonce_from_flags(args)?;
            Ok(Auth::Migration(MigrationAuth { measurement, deploy_env, network, nonce }))
        }
        (None, Some(d)) => {
            // Validate FIRST — before the nonce is generated or any digest is printed.
            let destination = validated_destination(&d, network)?;
            let nonce = nonce_from_flags(args)?;
            Ok(Auth::Sweep(SweepAuth { destination, deploy_env, network, nonce }))
        }
        (None, None) => bail!(
            "--measurement <hex32> (migration) or --destination <btc-addr> (sweep) required"
        ),
    }
}

/// Parse one on-disk bundle. The TYPE is read from the FILE, not from a flag: `MigrationAuth`
/// requires `measurement` and `SweepAuth` requires `destination`, so serde rejects the wrong
/// shape outright. A flag could be passed wrongly; the data cannot lie about what it is.
fn parse_bundle(raw: &[u8], path: &str) -> anyhow::Result<(Auth, Vec<Vec<u8>>)> {
    if let Ok(b) = serde_json::from_slice::<MigrationAuthBundle>(raw) {
        return Ok((Auth::Migration(b.auth), b.signatures));
    }
    let b: SweepAuthBundle = serde_json::from_slice(raw)
        .with_context(|| format!("bundle {path} is neither a migration nor a sweep bundle"))?;
    Ok((Auth::Sweep(b.auth), b.signatures))
}

/// Two bundles authorize the same thing only if BOTH the type and the payload match. Mixing a
/// migration bundle with a sweep bundle must fail loudly — the signatures would otherwise be
/// counted toward a threshold for an action half the signers never approved.
fn same_auth(a: &Auth, b: &Auth) -> bool {
    match (a, b) {
        (Auth::Migration(x), Auth::Migration(y)) => x == y,
        (Auth::Sweep(x), Auth::Sweep(y)) => x == y,
        _ => false,
    }
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    if let Some(out) = flag(&args, "--gen-key") {
        let secret = SysRng::new().gen_bytes();
        let addr = operator_address(&secret).context("derive operator address")?;
        std::fs::write(&out, secret)
            .with_context(|| format!("write operator secret to {out}"))?;
        println!("wrote operator secret key -> {out} (KEEP OFF-HOST for prod)");
        println!("operator (multisig-owner) address: {addr}");
        println!("add this address as an owner of the operator multisig (OPERATOR_SAFE).");
        return Ok(());
    }

    if args.iter().any(|a| a == "--digest") {
        let auth = auth_from_flags(&args)?;
        let digest = auth.digest();
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        // The kind is in the line because this hex is ALL the signer sees.
        println!("EIP-712 {} digest (sign this in your wallet): 0x{hex}", auth.kind());
        println!("  authorizing: {} ({})", auth.subject(), auth.context());
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
        let sig = auth.sign(&secret)?;
        let kind = auth.kind();
        let subject = auth.subject();
        let context = auth.context();
        // A 1-signature bundle; --combine merges several of these.
        let bundle = auth.combine(vec![sig]).context("serialize single-signature bundle")?;
        std::fs::write(&out, &bundle)
            .with_context(|| format!("write authorization to {out}"))?;
        println!(
            "wrote 1-sig {kind} for {subject} ({context}) -> {out} ({} bytes)",
            bundle.len(),
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

        let mut agreed: Option<Auth> = None;
        let mut sigs: Vec<Vec<u8>> = Vec::new();
        for p in paths {
            let raw = std::fs::read(p).with_context(|| format!("read bundle {p}"))?;
            let (auth, mut s) = parse_bundle(&raw, p)?;
            match &agreed {
                Some(a) => ensure!(
                    same_auth(a, &auth),
                    "bundles authorize different things ({} vs {}) — refusing to pool their \
                     signatures toward one threshold",
                    a.subject(),
                    auth.subject()
                ),
                None => agreed = Some(auth),
            }
            sigs.append(&mut s);
        }
        let auth = agreed.context("no bundles provided")?;
        let kind = auth.kind();
        let subject = auth.subject();
        let n = sigs.len();
        let bundle = auth.combine(sigs)?;
        std::fs::write(out, &bundle).with_context(|| format!("write bundle to {out}"))?;
        println!("wrote {n}-signature {kind} bundle for {subject} -> {out} ({} bytes)", bundle.len());
        return Ok(());
    }

    bail!(
        "usage: quid-migrate-auth --gen-key <out> \
         | --digest (--measurement <hex32> | --destination <btc-addr>) --network <net> \
         | --sign --key <secret> (--measurement <hex32> | --destination <btc-addr>) \
           --network <net> --out <path> \
         | --combine <out> <auth1> <auth2> [...]"
    );
}
