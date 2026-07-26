//! Enclave-sealed root-seed custody.
//!
//! The node's [`RootSeed`] is the root of all key material (LDK channel keys,
//! the on-chain BDK wallet, the persistence master key). Under SGX it must never
//! exist in plaintext outside the enclave: it is **sealed** to the enclave's
//! `EGETKEY` (bound to MRENCLAVE + machine id) and the sealed blob is persisted
//! to ordinary (untrusted) disk via [`Ffs`]. On boot the enclave unseals it.
//!
//! Two ways the seed can first come into being ([`SeedSource`]):
//!
//! - [`SeedSource::BornInEnclave`] (default): the enclave samples a fresh seed
//!   from its hardware RNG. The plaintext seed is *born and dies inside the
//!   enclave* — no operator, host, or human ever observes it.
//! - [`SeedSource::Import`] (guarded): an externally-supplied seed is sealed
//!   instead. This exists only for migration / disaster recovery and should be
//!   reachable solely through an explicit, deliberate operator action: the
//!   `QUID_SEED` env var, or an import over the attested provisioning tunnel
//!   ([`provision_seed`] sealing a seed POSTed over RA-TLS to
//!   `quid_bridge::provision_api`'s `/provision` — the same endpoint
//!   enclave→enclave migration uses, driven by the `quid-provision` client). It
//!   is a custody downgrade: whoever produced the seed has seen it.
//!
//! Once a sealed seed exists on disk it is authoritative: [`load_or_provision`]
//! unseals and returns it and **ignores `source`**. Re-provisioning a different
//! seed requires deliberately deleting the sealed file first — this prevents an
//! `Import` (or a fresh `BornInEnclave`) from silently clobbering live channel
//! keys. Because the seal is bound to MRENCLAVE, a new enclave build (different
//! measurement) cannot unseal an old seed — that is the intended re-provision
//! boundary, surfaced here as a clear error rather than a silent reset.

use std::str::FromStr;

use anyhow::{Context, ensure};
use quid_api_core::types::sealed_seed::SealedSeed;
use quid_common::{
    env::DeployEnv, ln::network::Network, root_seed::RootSeed,
};
use quid_crypto::rng::{Crng, SysRng};
use quid_enclave::enclave;

use crate::ffs::Ffs;

/// Select the seal backend by the detected TEE: the native SGX-`EGETKEY` / mock
/// sealer, or the SEV-SNP sealer from the host-only `quid-cvm` crate (battle-tested
/// `virtee/sev`). SGX is compile-time native; the confidential-VM sealers are
/// runtime-selected off-SGX.
#[cfg(target_env = "sgx")]
fn pick_sealer() -> Box<dyn enclave::Sealer> {
    Box::new(enclave::NativeSealer)
}
#[cfg(not(target_env = "sgx"))]
fn pick_sealer() -> Box<dyn enclave::Sealer> {
    match enclave::detect() {
        enclave::Backend::SevSnp => Box::new(quid_cvm::SevSealer),
        // None (mock, self-trust) / TDX / Nitro (seal not yet wired ⇒ mock, which
        // is refused for serving-others at boot by require_backend_for_role).
        _ => Box::new(enclave::NativeSealer),
    }
}

/// Filename of the persisted [`SealedSeed`] within the node's [`Ffs`].
pub const SEALED_SEED_FILENAME: &str = "sealed_seed";

/// Where a not-yet-provisioned node's seed comes from on first boot.
pub enum SeedSource {
    /// Sample a fresh seed from the enclave RNG. The plaintext never leaves the
    /// enclave. This is the default and the only zero-trust option.
    BornInEnclave,
    /// Seal an externally-supplied seed (migration / recovery only). Guarded:
    /// the caller must have obtained this seed through an explicit operator
    /// action. Whoever generated it has seen the plaintext.
    Import(RootSeed),
}

/// Load the node's root seed, sealing-on-first-provision.
///
/// 1. If a [`SealedSeed`] exists at [`SEALED_SEED_FILENAME`], unseal + validate
///    it against this enclave's current measurement + machine id and return it.
///    The persisted seed wins — `source` is ignored.
/// 2. Otherwise provision from `source` (born-in-enclave or import), seal the
///    seed to this enclave (binding `deploy_env` + `network` into the sealed
///    blob), persist it, and return it.
///
/// The returned [`RootSeed`] is the only plaintext copy and must stay inside the
/// enclave.
pub fn load_or_provision<F: Ffs, R: Crng>(
    ffs: &F,
    rng: &mut R,
    source: SeedSource,
    deploy_env: DeployEnv,
    network: Network,
) -> anyhow::Result<RootSeed> {
    let measurement = enclave::measurement();
    let machine_id = enclave::machine_id();

    // 1. Try to load + unseal an already-provisioned seed.
    match ffs.read(SEALED_SEED_FILENAME) {
        Ok(bytes) => {
            let sealed: SealedSeed = serde_json::from_slice(&bytes)
                .context("Failed to deserialize persisted SealedSeed")?;
            let (root_seed, sealed_env, sealed_network) = sealed
                .unseal_and_validate(&measurement, &machine_id, pick_sealer().as_ref())
                .context(
                    "Failed to unseal persisted seed (wrong enclave build, \
                     wrong machine, or corrupted blob — re-provisioning \
                     requires deleting the sealed seed file)",
                )?;
            // The sealed blob commits to deploy_env + network; refuse to run if
            // the operator-supplied values disagree (anti-network-confusion).
            ensure!(
                sealed_env == deploy_env,
                "Sealed seed deploy_env ({sealed_env}) != configured \
                 ({deploy_env})",
            );
            ensure!(
                sealed_network == network,
                "Sealed seed network ({sealed_network}) != configured \
                 ({network})",
            );
            return Ok(root_seed);
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // fall through to provisioning
        }
        Err(e) =>
            return Err(e).context("Failed to read persisted SealedSeed"),
    }

    // 2. Provision: obtain the plaintext seed, then seal + persist it.
    let root_seed = match source {
        SeedSource::BornInEnclave => RootSeed::from_rng(rng),
        SeedSource::Import(seed) => {
            // ANTI-CUSTODY-DOWNGRADE: a host-supplied seed (`QUID_SEED` env)
            // carries NO attestation/operator authorization — unlike the attested
            // `/provision` path (`provision_seed`). Inside a real enclave (the untrusted-host
            // model) accepting it would let the host delete the sealed seed and re-seed the
            // node with a seed IT knows, defeating SGX custody for that identity. So in an
            // enclave the seed MUST be born-in-enclave or attested-provisioned; env import is
            // a NON-SGX (self-host / dev, host-trusted) convenience only. `cfg!(target_env =
            // "sgx")` is the same compile-time enclave truth used by `validate_sgx`.
            ensure!(
                !cfg!(target_env = "sgx"),
                "SeedSource::Import (QUID_SEED) is refused inside an SGX enclave: an enclave \
                 seed must be born-in-enclave or provisioned via the attested endpoint, never \
                 host-supplied",
            );
            seed
        }
    };

    seal_and_persist(ffs, rng, &root_seed, deploy_env, network)?;

    Ok(root_seed)
}

/// Seal `root_seed` to this enclave (binding `deploy_env` + `network`) and write
/// the [`SealedSeed`] to [`SEALED_SEED_FILENAME`]. Shared by [`load_or_provision`]
/// and [`provision_seed`].
fn seal_and_persist<F: Ffs, R: Crng>(
    ffs: &F,
    rng: &mut R,
    root_seed: &RootSeed,
    deploy_env: DeployEnv,
    network: Network,
) -> anyhow::Result<()> {
    let sealed = SealedSeed::seal_from_root_seed(
        rng,
        root_seed,
        deploy_env,
        network,
        enclave::measurement(),
        enclave::machine_id(),
        pick_sealer().as_ref(),
    )
    .context("Failed to seal root seed")?;

    let bytes = serde_json::to_vec(&sealed)
        .context("Failed to serialize SealedSeed for persistence")?;
    ffs.write(SEALED_SEED_FILENAME, &bytes)
        .context("Failed to persist SealedSeed")?;

    Ok(())
}

/// Whether a sealed seed already exists (i.e. the node has been provisioned).
pub fn is_provisioned<F: Ffs>(ffs: &F) -> anyhow::Result<bool> {
    match ffs.read(SEALED_SEED_FILENAME) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e).context("Failed to check for existing sealed seed"),
    }
}

/// Provision a seed out-of-band (e.g. over the attested provisioning endpoint),
/// BEFORE the node boots: seal `root_seed` to this enclave and persist it as the
/// [`SealedSeed`] that [`load_or_provision`] reads at boot.
///
/// Refuses (errors) if a sealed seed already exists — provisioning never
/// clobbers live channel keys; re-provisioning requires deleting the sealed
/// file first. The caller (the attested `/provision` handler) has already
/// authenticated the channel via remote attestation, so the seed only enters a
/// genuine, expected enclave build.
pub fn provision_seed<F: Ffs, R: Crng>(
    ffs: &F,
    rng: &mut R,
    root_seed: &RootSeed,
    deploy_env: DeployEnv,
    network: Network,
) -> anyhow::Result<()> {
    ensure!(
        !is_provisioned(ffs)?,
        "already provisioned: a sealed seed exists (delete it to re-provision)",
    );
    seal_and_persist(ffs, rng, root_seed, deploy_env, network)
}

/// Infer a [`DeployEnv`] from `network` when `DEPLOY_ENVIRONMENT` is unset.
///
/// `Signet` has no valid env under [`DeployEnv::validate_network`]; it maps to
/// `Dev` so the resulting (clear) validation error names the real mismatch
/// rather than silently picking a wrong env. Shared by the boot path, the
/// provisioning service, and the operator CLI so they agree.
pub fn deploy_env_for_network(network: Network) -> DeployEnv {
    match network {
        Network::Mainnet => DeployEnv::Prod,
        Network::Testnet3 | Network::Testnet4 => DeployEnv::Staging,
        Network::Regtest | Network::Signet => DeployEnv::Dev,
    }
}

/// Load-or-provision the sealed seed using the process environment — the entry
/// point the daemons call at boot.
///
/// Seed-source convention:
/// - `QUID_SEED` set (32-byte hex) => guarded [`SeedSource::Import`] of that
///   seed (migration / recovery — whoever set it has seen the plaintext). On
///   first boot it is sealed; thereafter the on-disk sealed seed wins and
///   `QUID_SEED` is ignored (so leaving it set is harmless, and removing it does
///   not lose the node's identity).
/// - `QUID_SEED` unset => [`SeedSource::BornInEnclave`] (default, zero-trust).
///
/// `deploy_env` is read from `DEPLOY_ENVIRONMENT` if present, else inferred from
/// `network`. See [`load_or_provision`] for the seal-on-first-provision and
/// disk-wins semantics.
pub fn load_or_provision_from_env<F: Ffs>(
    ffs: &F,
    network: Network,
) -> anyhow::Result<RootSeed> {
    let deploy_env = match std::env::var("DEPLOY_ENVIRONMENT") {
        Ok(s) =>
            DeployEnv::from_str(s.trim()).context("Invalid DEPLOY_ENVIRONMENT")?,
        Err(_) => deploy_env_for_network(network),
    };

    // Fail CLOSED before any seed is born or unsealed:
    //   (1) BACKEND / ROLE attestation policy (supersedes the old blanket
    //       "staging/prod ⇒ SGX"). A serves-others role (fleet / family hop) needs
    //       a CUSTODY-READY TEE backend so the untrusted host cannot read the
    //       sealed seed — off-TEE sealing is a mock that "provides no security
    //       whatsoever" (platform.rs), and a detected-but-not-yet-wired CVM fails
    //       CLOSED (no silent mock fallback). An INDIVIDUAL self-host is its own
    //       trust root and may run on any backend, incl. no TEE. The role is
    //       host-declared (QUID_HOSTING_ROLE); it defaults to the STRICT `Fleet`
    //       in staging/prod (a forgotten role fails closed, not open) and to
    //       `Individual` in dev/regtest. This is an operator guardrail — the
    //       PRIMARY trust is each LP verifying the hop's attestation before
    //       designating it (see quid_enclave::backend).
    //   (2) refuse the dev migration trust anchors (well-known keys 1/2/3), which
    //       would otherwise let anyone forge a MigrationAuth and steal the seed.
    let role = std::env::var("QUID_HOSTING_ROLE")
        .ok()
        .and_then(|s| enclave::HostingRole::parse(&s))
        .unwrap_or(if deploy_env.is_staging_or_prod() {
            enclave::HostingRole::Fleet
        } else {
            enclave::HostingRole::Individual
        });
    enclave::require_backend_for_role(role, enclave::detect())?;
    crate::migration::guard_prod_trust_anchors(deploy_env)?;

    let source = match std::env::var("QUID_SEED") {
        Ok(hex) => {
            let seed = RootSeed::from_str(hex.trim())
                .context("Invalid QUID_SEED (expected 32-byte hex)")?;
            SeedSource::Import(seed)
        }
        Err(_) => SeedSource::BornInEnclave,
    };

    let mut rng = SysRng::new();
    load_or_provision(ffs, &mut rng, source, deploy_env, network)
}

#[cfg(test)]
mod test {
    use quid_crypto::rng::FastRng;

    use super::*;
    use crate::ffs::InMemoryFfs;

    // Off-SGX the enclave seal/unseal use a deterministic mock; this exercises
    // the full provision -> persist -> reload path.

    #[test]
    fn born_in_enclave_then_reload_is_stable() {
        let ffs = InMemoryFfs::new();
        let mut rng = FastRng::from_u64(1);

        // First boot: no sealed seed -> born in enclave, sealed + persisted.
        let seed1 = load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::BornInEnclave,
            DeployEnv::Dev,
            Network::Regtest,
        )
        .unwrap();

        // A sealed blob now exists on disk.
        assert!(ffs.read(SEALED_SEED_FILENAME).is_ok());

        // Second boot: disk wins. `source` is ignored even though we pass a
        // different one — the same persisted seed comes back.
        let decoy = RootSeed::from_rng(&mut rng);
        let seed2 = load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::Import(decoy),
            DeployEnv::Dev,
            Network::Regtest,
        )
        .unwrap();

        assert_eq!(
            seed1.as_bytes(),
            seed2.as_bytes(),
            "reloaded seed must equal the originally provisioned seed",
        );
    }

    #[test]
    fn import_seals_supplied_seed() {
        let ffs = InMemoryFfs::new();
        let mut rng = FastRng::from_u64(2);

        let imported = RootSeed::from_rng(&mut rng);
        let imported_bytes = imported.as_bytes().to_vec();

        let loaded = load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::Import(imported),
            DeployEnv::Dev,
            Network::Regtest,
        )
        .unwrap();

        assert_eq!(
            loaded.as_bytes(),
            imported_bytes.as_slice(),
            "imported seed must be the one sealed + returned",
        );

        // Reload returns the same imported seed.
        let reloaded = load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::BornInEnclave,
            DeployEnv::Dev,
            Network::Regtest,
        )
        .unwrap();
        assert_eq!(
            reloaded.as_bytes(),
            imported_bytes.as_slice(),
        );
    }

    #[test]
    fn network_mismatch_on_reload_is_rejected() {
        let ffs = InMemoryFfs::new();
        let mut rng = FastRng::from_u64(3);

        load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::BornInEnclave,
            DeployEnv::Dev,
            Network::Regtest,
        )
        .unwrap();

        // Reboot claiming a different network than what was sealed.
        let err = load_or_provision(
            &ffs,
            &mut rng,
            SeedSource::BornInEnclave,
            DeployEnv::Dev,
            Network::Testnet3,
        )
        .unwrap_err();
        assert!(
            format!("{err:#}").contains("network"),
            "expected a network-mismatch error, got: {err:#}",
        );
    }
}
