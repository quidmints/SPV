//! (§M1#2 phase 1b) THE LP-HOSTED VAULT — the LP's own half of every 2-of-2, on the LP's own box.
//!
//! # Why this binary exists
//!
//! Until it runs, the fleet holds BOTH halves of every channel's 2-of-2 funding output. That is
//! the keystone this whole phase order is arranged around: while it holds both, **no exit,
//! ladder or splice policy binds it** — it can spend the funding output outright, and every
//! guarantee written against those policies is a guarantee against a party that has already
//! agreed to be bound. `vault.rs` says the same thing from the other side: the consent and the
//! pre-signed ladder "require the LP funding half, which after §E175 the fleet does not have —
//! so the fleet RELAYS consent; it never manufactures it."
//!
//! There is nothing clever here, and that is the point. It boots the SAME `boot_vault` the
//! fleet boots, with the SAME orchestrators, differing in exactly two things:
//!
//!   1. the **seed** is the LP's own, provisioned on the LP's machine and never seen by the
//!      fleet (the fleet's `derive_vault_seed` sibling is not involved and cannot reach it);
//!   2. the **hop address** points at the fleet instead of `LOCALHOST`.
//!
//! §E175 called that second one out as "a TOPOLOGY, not a setting", and `boot_vault`'s
//! `hop_addr` parameter is where it lives. ⚠️ That parameter was accepted and then DISCARDED
//! by a hardcoded `Ipv4Addr::LOCALHOST` at the dial site until 2026-08-15, so this binary could
//! not have worked before that fix regardless of how it was configured.
//!
//! # On the freshness anchor — read this before "hardening" it to the on-chain ledger
//!
//! This uses [`InMemoryFreshnessAnchor`], and that is **correct here rather than a shortcut**.
//! The anchor exists for ONE threat: an enclave whose UNTRUSTED HOST hands back a stale sealed
//! monitor on boot. `freshness.rs` is explicit — it verifies "the monitor **the host handed
//! back**" and warns that "an anchor that a host can rewind provides no protection". That is a
//! host-versus-operator split, and an LP running this on their own machine does not have one:
//! they are both parties, and rolling back their own state is self-harm.
//!
//! 🔑 **It is NOT what protects the hop from a stale broadcast, and conflating the two is the
//! mistake to avoid.** Lightning already answers that with revocation: the hop imposes a 7-day
//! justice window on this peer (`node.rs:616`, `our_to_self_delay = 6*24*7`), so an LP
//! broadcasting a revoked commitment loses the channel balance to the penalty path. The hop's
//! safety does not depend on the LP maintaining an honest anchor, which is exactly why moving
//! the vault to the LP does not hand anyone the detector for their own misbehaviour.
//!
//! ⚠️ **The one deployment that DOES need the on-chain anchor** is an LP running this inside an
//! enclave on a host they do not control — then the host/operator split is back and the local
//! anchor is worthless against it. That LP needs an EVM key and gas, which is a deployment
//! choice for them to make, not a protocol requirement to impose on every LP.
//!
//! # The seed path (§M1#2 phase 1c), and the asymmetry at the heart of it
//!
//! Phase 1b's security content is that the fleet cannot derive this seed. Read from the other
//! side, that says: **nobody can recover it either.** The LP's half of every 2-of-2 lives in one
//! sealed file on one disk, and off-TEE that seal is a mock — so the exposure is a lost disk,
//! not a compromised one.
//!
//! Three things close that, and they are one mechanism, not three features:
//!
//!   1. this binary declares itself [`Individual`][role] instead of inheriting the fleet's
//!      network-derived default, **without which it does not boot on mainnet at all**;
//!   2. on the single boot where the seed is born, and only on a machine whose seal protects
//!      nothing, the 24-word mnemonic is written to `SEED-BACKUP-WRITE-THIS-DOWN.txt` (0600,
//!      never overwritten) — see [`quid_bridge::lp_seed`];
//!   3. `QUID_SEED` takes that sentence back, not only 32-byte hex, so the backup restores.
//!
//! ⚠️ **An export nothing can import is not a backup**, which is why (3) is part of this and not
//! a follow-up: before it, `RootSeed` could emit a mnemonic and no code in the workspace could
//! turn one back into a seed.
//!
//! [role]: quid_enclave::enclave::HostingRole::Individual
//!
//! # Environment
//!
//!   QUID_NETWORK           mainnet | testnet3 | testnet4 | signet | regtest
//!   QUID_DATA_DIR          this LP's own directory: sealed seed + vault state
//!   QUID_SEED              (restore only) the mnemonic from a backup, or 32-byte hex.
//!                          Ignored once a sealed seed exists — restore into an EMPTY dir.
//!   QUID_HOSTING_ROLE      optional; defaults to `individual` here. Set it only to declare a
//!                          STRICTER role (`family`), which reimposes the TEE requirement.
//!   QUID_ESPLORA_URL       chain source
//!   QUID_HOP_NODE_PK       the fleet hop's node pubkey (33-byte compressed hex)
//!   QUID_HOP_ADDR          the fleet's IPv4 address   ← THE SPLIT (§E175)
//!   QUID_HOP_P2P_PORT      the fleet's vault-facing p2p port (default 9736)
//!   QUID_MIN_CONFIRMATIONS deposit burial before an open (default 3)
//!   QUID_VAULT_POLL_SECS   orchestrator interval (default 30)

use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

use anyhow::Context;
use bitcoin::secp256k1::PublicKey;
use quid_bridge::boot::{env, env_parse};
use quid_bridge::store::BridgeStore;
use quid_common::api::user::NodePk;
use quid_common::ln::network::Network;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let network = Network::from_str(&env("QUID_NETWORK")?)
        .map_err(|_| anyhow::anyhow!("QUID_NETWORK: unknown network"))?;
    let data_dir = PathBuf::from(env("QUID_DATA_DIR")?);

    // The LP's OWN seed, through the SAME sealed born-on-first-boot path the fleet uses
    // (`load_or_provision_from_env`): sealed to this machine, imported only via the guarded
    // QUID_SEED path, and unsealed from `data_dir` on every subsequent boot.
    //
    // 🔑 This is the whole security content of the split. The fleet's vault seed is an HKDF
    // sibling of its hop seed, so whoever holds the hop seed derives it — one custodian wearing
    // two hats. A seed provisioned HERE has no such relationship: the fleet cannot derive it,
    // and its `MigrationAuth` cannot reach it either, because it was never in the fleet's
    // enclave to migrate.
    let seed_ffs = quid_hop::ffs::DiskFs::create_dir_all(data_dir.clone())
        .context("open LP data dir for sealed seed")?;

    // Read BEFORE provisioning: afterwards a sealed seed always exists, so this is the only
    // point at which "was one born on this boot?" is answerable. It is the whole trigger for
    // the backup below.
    let seed_existed_before = quid_hop::seed::is_provisioned(&seed_ffs)
        .context("check whether this LP is already provisioned")?;
    let operator_supplied_seed = std::env::var("QUID_SEED").is_ok();

    // 🔑 `Individual`, declared here rather than inferred from the network — and without it
    // THIS BINARY CANNOT BOOT ON MAINNET. The env-only default reads mainnet as `Prod` and
    // `Prod` as `Fleet`; a serves-others role requires a custody-ready TEE, so an LP on an
    // ordinary box was refused with an error about serving other LPs, which it does not do.
    // An LP vault serves exactly one operator's funds and is its own trust root.
    // ⚠️ `QUID_HOSTING_ROLE` still wins where set, so an LP hosting a family plan can declare
    // the stricter role and get the stricter check.
    let lp_seed = quid_hop::seed::load_or_provision_from_env_with_role(
        &seed_ffs,
        network,
        Some(quid_enclave::enclave::HostingRole::Individual),
    )
    .context("load/provision this LP's sealed vault seed")?;

    // ⚠️ THE OTHER SIDE OF "THE FLEET CANNOT DERIVE IT": nobody else can recover it either.
    // On the one boot where the seed is born, on a machine whose seal is a mock, hand the
    // operator the only copy they will ever be offered. See `lp_seed` for why the gate is the
    // backend rather than a flag.
    match quid_bridge::lp_seed::decide(
        seed_existed_before,
        operator_supplied_seed,
        quid_enclave::enclave::detect(),
    ) {
        quid_bridge::lp_seed::BackupDecision::Write => {
            let path = quid_bridge::lp_seed::write_mnemonic_backup(&data_dir, &lp_seed)
                .context("write the LP seed backup")?;
            // The path, never the words: logs get shipped and retained, data dirs do not.
            tracing::warn!(
                path = %path.display(),
                "🔑 A NEW SEED WAS BORN AND IS BACKED UP ONLY IN THIS FILE. It is your half \
                 of every channel this node opens; nobody else holds a copy. Write the words \
                 on paper, store it away from this disk, then delete the file.",
            );
        }
        quid_bridge::lp_seed::BackupDecision::SkipAlreadyProvisioned =>
            tracing::info!("sealed seed already present; nothing new to back up"),
        quid_bridge::lp_seed::BackupDecision::SkipOperatorSuppliedSeed => tracing::info!(
            "seed imported from QUID_SEED; no backup written (you already hold it)"
        ),
        quid_bridge::lp_seed::BackupDecision::SkipCustodyReadyBackend => tracing::info!(
            "seed sealed by a custody-ready TEE; no plaintext backup written (exporting it \
             would defeat the seal — recover via attested provisioning instead)"
        ),
    }

    let store_seal = Arc::new(lp_seed.derive_vfs_master_key());
    let store = Arc::new(
        BridgeStore::load_sealed(Some(data_dir.join("lp-store.json")), store_seal)
            .context("load LP store")?,
    );

    // The fleet's identity and where to reach it. Both are the LP's configuration: the LP
    // chooses which hop to open against, and nothing here trusts the address beyond dialling
    // it — the channel is still a 2-of-2 whose other half this process holds.
    let hop_pk = NodePk(
        PublicKey::from_str(env("QUID_HOP_NODE_PK")?.trim_start_matches("0x"))
            .context("QUID_HOP_NODE_PK must be a 33-byte compressed pubkey hex")?,
    );
    let hop_addr: Ipv4Addr = env("QUID_HOP_ADDR")?
        .parse()
        .context("QUID_HOP_ADDR must be an IPv4 address (the fleet's, not localhost)")?;
    let hop_port: u16 = env_parse("QUID_HOP_P2P_PORT", 9736u16)?;

    // See the module header: local anchor, because an LP on its own machine has no
    // host-versus-operator split for the anchor to defend.
    let anchor: Arc<dyn quid_hop::freshness::FreshnessAnchor + Send + Sync> =
        Arc::new(quid_hop::freshness::InMemoryFreshnessAnchor::new());

    tracing::info!(%network, %hop_addr, %hop_port, "quid-lp-daemon: booting LP-hosted vault");
    let mut vault = quid_bridge::vault::boot_vault(
        network,
        env("QUID_ESPLORA_URL")?,
        &lp_seed,
        data_dir.join("vault"),
        hop_pk,
        hop_addr,
        hop_port,
        quid_hop::rebalancer::SPLICE_FUNDING_FEERATE_SAT_PER_KW,
        store,
        anchor,
    )
    .await
    .context("boot LP vault node")?;

    // Same two tasks the fleet spawns for its co-hosted vault, for the same reasons: the
    // correlator resolves each swapper-directed delivery splice to its awaiting request, and
    // the orchestrator turns confirmed deposits into channel opens.
    let lifecycle_rx = vault.take_lifecycle_rx();
    let vault = Arc::new(vault);
    tokio::spawn(quid_bridge::vault::run_vault_delivery_correlator(
        lifecycle_rx,
        vault.deliveries.clone(),
    ));
    tokio::spawn(quid_bridge::vault::run_vault_open_orchestrator(
        vault.clone(),
        hop_pk,
        env_parse("QUID_MIN_CONFIRMATIONS", 3u32)?,
        env_parse("QUID_VAULT_POLL_SECS", 30u64)?,
    ));

    // Keep the hop link up. The fleet spawns this against its co-hosted vault; here it matters
    // MORE, because the link crosses a real network rather than loopback. `ensure_hop_connected`
    // is a no-op while connected, so the tick is cheap and bounds an outage to about one
    // interval rather than to somebody noticing.
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        if let Err(e) = vault.ensure_hop_connected().await {
            tracing::warn!("hop reconnector: re-dial failed ({e:#}); retrying next tick");
        }
    }
}
