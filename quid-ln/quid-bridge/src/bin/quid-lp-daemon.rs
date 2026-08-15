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
//! # Environment
//!
//!   QUID_NETWORK           mainnet | testnet3 | testnet4 | signet | regtest
//!   QUID_DATA_DIR          this LP's own directory: sealed seed + vault state
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
    let lp_seed = quid_hop::seed::load_or_provision_from_env(&seed_ffs, network)
        .context("load/provision this LP's sealed vault seed")?;

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
