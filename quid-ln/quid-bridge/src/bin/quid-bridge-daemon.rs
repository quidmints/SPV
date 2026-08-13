//! `quid-bridge-daemon` — the production entrypoint that boots the hop node and
//! runs every bridge loop (the LN↔EVM glue) as one process on the hop box.
//!
//! Config is taken from the environment (nothing chain-specific is hardcoded):
//!   QUID_RPC_URL            EVM JSON-RPC endpoint (primary; back-compat)
//!   QUID_RPC_URLS           comma-separated endpoint list (primary first) for the
//!                           quorum transport; empty ⇒ falls back to QUID_RPC_URL
//!   QUID_RPC_QUORUM         endpoints that must agree on a spend-gating read
//!                           (default 1 = single-node/self-host-only)
//!   QUID_CHAIN_ID           EIP-155 chain id (decimal)
//!   QUID_BTC_CHANNELS       BTCChannels address (0x…)
//!   QUID_BTC_VAULT          Vault address (btcFeesOwedSats ledger)
//!   QUID_SPV_GATEWAY        SPVGateway address
//!   QUID_HOT_KEY            OFF-SGX override (hex, no 0x). In an enclave the hop
//!                           key is DERIVED from the sealed seed; this env is
//!                           REFUSED there (host-supplied ⇒ no enclave binding).
//!   QUID_ESPLORA_URL        Esplora REST base URL
//!   QUID_DATA_DIR           hop persister data dir
//!   QUID_SEED               OPTIONAL 32-byte hop root seed (hex, no 0x) — a
//!                           guarded import for migration/recovery. If unset,
//!                           the seed is born in-enclave on first boot. Either
//!                           way it is sealed under `QUID_DATA_DIR`; later boots
//!                           unseal from disk (disk wins, QUID_SEED ignored).
//!   QUID_NETWORK            mainnet|testnet|regtest|signet
//!   QUID_HOSTING_ROLE       fleet|family|individual — who this hop serves. Fleet/
//!                           family REQUIRE a custody-ready TEE backend; individual
//!                           may self-host on any backend (self-trust). Default:
//!                           fleet in staging/prod, individual in dev.
//!   QUID_LSP_NODE_PK        LP counterparty node pubkey (33-byte compressed hex)
//!   QUID_LSP_ADDR           LP p2p addr host:port
//!   QUID_START_BLOCK        EVM block to seed the log cursors (decimal)
//! Optional (sane defaults): QUID_MIN_CONFIRMATIONS, QUID_MAX_FEE_PER_GAS,
//!   QUID_MAX_PRIORITY_FEE, QUID_GAS_LIMIT, QUID_LP_FEE_RATE_SAT_VB, the poll
//!   intervals, QUID_RELAY_BATCH_MAX, QUID_RELAY_REORG_LOOKBACK.

use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

use alloy_primitives::Address;
use anyhow::{anyhow, Context};

use quid_bridge::config::BridgeConfig;
use quid_bridge::daemon;
use quid_bridge::signer::LocalSigner;
use quid_bridge::client::TxSigner;
use quid_bridge::store::BridgeStore;

use quid_common::ln::network::Network;

use quid_bridge::boot::{build_lsp_info, env, env_or, env_parse, evm_signing_key};

fn build_config() -> anyhow::Result<BridgeConfig> {
    // Multi-endpoint quorum transport: QUID_RPC_URLS is a comma-separated list
    // (primary first). Empty/unset ⇒ fall back to the single QUID_RPC_URL. Quorum
    // defaults to 1 (single-node / self-host-only); validate() bounds it.
    let rpc_urls: Vec<String> = env_or("QUID_RPC_URLS", "")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    Ok(BridgeConfig {
        rpc_url: env("QUID_RPC_URL")?,
        rpc_urls,
        rpc_quorum: env_parse("QUID_RPC_QUORUM", 1usize)?,
        chain_id: env("QUID_CHAIN_ID")?.parse().context("QUID_CHAIN_ID")?,
        btc_channels: Address::from_str(&env("QUID_BTC_CHANNELS")?).context("QUID_BTC_CHANNELS")?,
        btc_vault: Address::from_str(&env("QUID_BTC_VAULT")?).context("QUID_BTC_VAULT")?,
        spv_gateway: Address::from_str(&env("QUID_SPV_GATEWAY")?).context("QUID_SPV_GATEWAY")?,
        min_confirmations: env_parse("QUID_MIN_CONFIRMATIONS", 6)?,
        min_cltv_headroom_blocks: env_parse("QUID_MIN_CLTV_HEADROOM_BLOCKS", 72)?,
        settle_max_retries: env_parse("QUID_SETTLE_MAX_RETRIES", 5)?,
        retry_backoff_secs: env_parse("QUID_RETRY_BACKOFF_SECS", 5)?,
        max_fee_per_gas: env_parse("QUID_MAX_FEE_PER_GAS", 50_000_000_000u128)?, // 50 gwei ceiling
        max_priority_fee_per_gas: env_parse("QUID_MAX_PRIORITY_FEE", 1_000_000_000u128)?, // 1 gwei
        gas_limit: env_parse("QUID_GAS_LIMIT", 400_000u64)?,
        receipt_poll_attempts: env_parse("QUID_RECEIPT_POLL_ATTEMPTS", 30)?,
        receipt_poll_secs: env_parse("QUID_RECEIPT_POLL_SECS", 4)?,
        fee_bump_attempts: env_parse("QUID_FEE_BUMP_ATTEMPTS", 5)?,
        fee_bump_pct: env_parse("QUID_FEE_BUMP_PCT", 125)?,
        settle_min_confirmations: env_parse("QUID_SETTLE_MIN_CONFIRMATIONS", 2)?,
        max_log_block_span: env_parse("QUID_MAX_LOG_BLOCK_SPAN", 5_000)?,
        swap_out_poll_secs: env_parse("QUID_SWAP_OUT_POLL_SECS", 12)?,
        relay_batch_max: env_parse("QUID_RELAY_BATCH_MAX", 100)?,
        relay_gas_limit: env_parse("QUID_RELAY_GAS_LIMIT", 8_000_000u64)?,
        relay_poll_secs: env_parse("QUID_RELAY_POLL_SECS", 30)?,
        relay_reorg_lookback: env_parse("QUID_RELAY_REORG_LOOKBACK", 144)?,
        channel_reconcile_secs: env_parse("QUID_CHANNEL_RECONCILE_SECS", 300)?,
        relayer_defer_inflight: env_parse("QUID_RELAYER_DEFER_INFLIGHT", 20usize)?,
    })
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info,quid_hop=debug,quid_bridge=debug").try_init().ok();

    let cfg = build_config()?;
    // AGREED-READ PRECONDITION (audit H-2): the fund-gating reads (btcRecipientOf,
    // swapInUsed, pendingOnchainSwapOut, freshnessSeq, lpFeePaid) are AGREEMENT-classed,
    // but "agreement" over ONE endpoint is just that endpoint. Inside a real enclave the
    // host is untrusted (it MITMs the RPC), so quorum 1 makes those defenses single-host-
    // trusting — theft/rollback become possible despite the F-series work. Self-hosted
    // (non-SGX) the operator trusts their own RPC, so quorum 1 is fine. Warn loudly in the
    // enclave case (don't hard-refuse: a valid self-host may legitimately run one endpoint).
    if cfg!(target_env = "sgx") && cfg.rpc_quorum < 2 {
        tracing::error!(
            rpc_quorum = cfg.rpc_quorum,
            "SECURITY: running in an SGX enclave with QUID_RPC_QUORUM < 2 — the fund-gating \
             agreed reads trust a SINGLE, host-controlled RPC endpoint. Configure >= 2 \
             INDEPENDENTLY-operated endpoints (QUID_RPC_URLS + QUID_RPC_QUORUM) or the \
             untrusted host can forge them (redirect fee payouts, claim BTC w/o USD, slip a \
             rolled-back monitor)."
        );
    }
    let network = Network::from_str(&env_or("QUID_NETWORK", "mainnet"))
        .map_err(|_| anyhow!("QUID_NETWORK: unknown network"))?;
    // Fail-closed hardening (upgrades the H-2 warning above): in staging/prod the
    // untrusted host must NOT be able to defeat the fund-gating agreement reads with a
    // single (or non-majority) endpoint set. `validate_hardened` requires >= 2 endpoints,
    // quorum >= 2, and a strict majority. Dev/regtest (host-trusted self-host) is exempt.
    if quid_hop::seed::deploy_env_for_network(network).is_staging_or_prod() {
        cfg.validate_hardened()
            .map_err(|e| anyhow!("staging/prod bridge config rejected (M11 hardening): {e}"))?;
    }
    // MRENCLAVE-pin the EVM target: refuse in staging/prod unless the host's configured
    // BTCChannels address + chain-id match the compiled-in (measured) pins — else the host
    // redirects the protocol to a look-alike contract/chain where it runs every "agreeing"
    // endpoint, defeating the fund-gating reads regardless of quorum. The config-binding
    // half of moving the EVM path into the enclave (sealing QUID_HOT_KEY is the other half).
    quid_hop::migration::guard_prod_evm_target(
        quid_hop::seed::deploy_env_for_network(network),
        cfg.btc_channels,
        cfg.chain_id,
    )?;
    let data_dir = PathBuf::from(env("QUID_DATA_DIR")?);
    // Seal-on-first-provision: born-in-enclave by default; QUID_SEED (if set) is
    // a guarded import. Subsequent boots unseal from `data_dir` (disk wins).
    let seed_ffs = quid_hop::ffs::DiskFs::create_dir_all(data_dir.clone())
        .context("open data dir for sealed seed")?;
    // Optional attested provisioning mode: if QUID_PROVISION_LISTEN is set and
    // this node isn't yet provisioned, serve the attested /provision endpoint
    // until an operator (who has verified our enclave's attestation) imports a
    // seed; then fall through to boot, which unseals it.
    if let Ok(listen) = std::env::var("QUID_PROVISION_LISTEN") {
        if !quid_hop::seed::is_provisioned(&seed_ffs)
            .context("check whether already provisioned")?
        {
            let addr: std::net::SocketAddr = listen
                .parse()
                .context("QUID_PROVISION_LISTEN must be ip:port")?;
            let listener = std::net::TcpListener::bind(addr)
                .context("bind QUID_PROVISION_LISTEN")?;
            let deploy_env = quid_hop::seed::deploy_env_for_network(network);
            tracing::info!(%addr, "awaiting attested seed provisioning");
            quid_bridge::provision_api::serve_provision(
                listener,
                std::sync::Arc::new(seed_ffs.clone()),
                deploy_env,
                network,
                std::env::var("QUID_PROVISION_TOKEN").ok(),
            )
            .await
            .context("serve attested provisioning")?;
        }
    }
    let root_seed = quid_hop::seed::load_or_provision_from_env(&seed_ffs, network)
        .context("load/provision sealed seed")?;
    // The hop's EVM "hot key" is DERIVED from the born-in-enclave sealed seed —
    // NOT a plaintext operator-held `QUID_HOT_KEY` env var (this closes the M11
    // residual: the EVM key now never exists outside the enclave). Its address is
    // enclave-determined; the hop advertises it to LPs (they commit it into
    // `openChannelDigest`) and it self-registers as `channel.hop = msg.sender` on
    // `openChannel`. Derived AFTER the seed loads (a fresh/provisioning node has no
    // seed yet); the provisioning + boot paths below all use this `signer`.
    let signer = LocalSigner::from_secret_key_bytes(
        evm_signing_key(&root_seed, "QUID_HOT_KEY")?.secret_bytes(),
    )
    .context("build hop EVM signer")?;
    tracing::info!(
        hop_evm = %signer.address(),
        "hop EVM hot key derived from sealed seed (advertise this address to LPs)",
    );
    // Migration mode: transfer this (old) enclave's seed to the
    // successor enclave the OPERATOR specifies, then exit. No governance exists —
    // the operator (sole authority) supplies the successor address, its expected
    // MRENCLAVE, and the provisioning token; we verify the successor attests to
    // that MRENCLAVE before sending. The old enclave only needs to RUN+unseal
    // (works under SGX TCB recovery, when its OWN attestation is revoked); an
    // unrecoverable crash is the on-chain-recovery case instead.
    if let Ok(new_addr) = std::env::var("QUID_MIGRATE_TO") {
        let new_addr: std::net::SocketAddr = new_addr
            .parse()
            .context("QUID_MIGRATE_TO must be ip:port")?;
        // The successor MRENCLAVE comes from the 2-of-3 operator-signed bundle
        // (host-unforgeable), NOT a host-settable env var.
        let auth = std::fs::read(env("QUID_MIGRATE_AUTH")?)
            .context("read QUID_MIGRATE_AUTH (2-of-3 operator authorization bundle)")?;
        let token = std::env::var("QUID_PROVISION_TOKEN").ok();
        let deploy_env = quid_hop::seed::deploy_env_for_network(network);
        // ANTI-REPLAY (audit HIGH): inside an enclave (untrusted host) consume the bundle's
        // nonce on-chain via the hot-key EVM client BEFORE exporting, so a captured bundle
        // can't re-export the seed. Self-host (non-SGX) trusts its own host — no consume.
        let migrate_evm = if cfg!(target_env = "sgx") {
            Some(quid_bridge::daemon::build_daemon_evm(&cfg, signer))
        } else {
            None
        };
        let consumer = migrate_evm
            .as_deref()
            .map(|e| e as &dyn quid_bridge::provision_api::MigrationNonceConsumer);
        quid_bridge::provision_api::migrate_seed_to(
            new_addr,
            &auth,
            root_seed,
            cfg!(target_env = "sgx"),
            deploy_env,
            network,
            token.as_deref(),
            consumer,
        )
        .await
        .context("migrate seed to authorized successor")?;
        tracing::info!("migration complete; exiting old enclave");
        return Ok(());
    }
    let lsp_info = build_lsp_info()?;
    let start_block: u64 = env("QUID_START_BLOCK")?.parse().context("QUID_START_BLOCK")?;
    let store_path = data_dir.join("bridge-store.json");

    // Build the ONE shared EVM client (quorum reads + private-relay sends + the hot key's
    // serialized nonce) BEFORE boot, so the anti-rollback freshness committer and
    // daemon::run share it (one hot key ⇒ one nonce source — a second client on the same
    // key would contend on nonces). deploy_env selects the anchor: the on-chain
    // BTCChannels freshnessSeq anchor for staging/prod, the in-memory double for
    // dev/regtest (host trusted). `_freshness_committer` is the committer thread handle
    // (Some in prod) — detached; it exits when the anchor drops at shutdown.
    let deploy_env = quid_hop::seed::deploy_env_for_network(network);
    let evm = quid_bridge::daemon::build_daemon_evm(&cfg, signer);
    let (anchor, _freshness_committer) =
        quid_bridge::daemon::build_freshness_anchor(deploy_env, evm.clone(), &cfg);

    // SEALED bridge store (F5): encrypt state at rest under the enclave key (the same
    // seed-derived vfs master key that seals the LDK monitors) so the LN preimage + fee
    // dedup are never cleartext on host disk. Works in every hosting mode (SGX or
    // self-hosted). Rollback-proofing of the money-critical replay — the swap-in claim — is
    // on-chain (`swapInUsed`), not a store version. (The LP-fee payout was retired.)
    let store_seal = Arc::new(root_seed.derive_vfs_master_key());
    let store = Arc::new(
        BridgeStore::load_sealed(Some(store_path), store_seal).context("load bridge store")?,
    );

    tracing::info!(%network, "quid-bridge-daemon: booting hop node");
    let node = quid_hop::node::boot(
        network,
        env("QUID_ESPLORA_URL")?,
        &root_seed,
        data_dir.clone(),
        lsp_info,
        anchor,
    )
    .await
    .context("boot hop node")?;

    // Swap-in: both must be set to enable it (token required).
    let swap_in_listen = std::env::var("QUID_SWAPIN_LISTEN").ok();
    let swap_in_token = std::env::var("QUID_SWAPIN_API_TOKEN").ok();

    // VAULT NODE — the fleet's 2nd in-process LP-side node that opens channels
    // funded by each LP's on-chain BTC deposit (LPs run nothing). The hop runs a
    // localhost p2p listener; the vault dials it. All handles are `Arc`/`Copy` (shared
    // by reference, never a deep copy). The `vault` Arc is held in scope for the
    // daemon's lifetime so the vault's LDK background tasks stay alive.
    let vault_port: u16 = env_parse("QUID_VAULT_P2P_PORT", 9736)?;
    let hop_pk = node.keys_manager.node_pk();
    let _hop_listener = quid_bridge::vault::spawn_p2p_listener(&node, vault_port).await?;
    let (vault_anchor, _vault_committer) =
        quid_bridge::daemon::build_freshness_anchor(deploy_env, evm.clone(), &cfg);
    // (E175-b) THE FLEET IS ONE CUSTODIAN, AND SAYS SO. The vault is a sibling identity of the
    // hop, derived from the one seed migration actually carries.
    //
    // ⚠️ **Three things were tried here before this, and the first two were wrong:**
    //   1. A `VaultSeedSource::{DerivedFromHop, Independent}` knob whose default was derived —
    //      i.e. the both-halves property was reachable by omission. Deleted.
    //   2. An acknowledgement flag (`QUID_SINGLE_OPERATOR=1`) to opt into it. A tripwire against
    //      foreseeable misuse is the tell that the root problem is unfixed. Deleted.
    //   3. A second born-in-enclave seed in its own sealed store. That LOOKED like the secure
    //      answer and is the one to understand, because it is worse than what it replaced:
    //      🔴 `provision_api` migrates a **single `root_seed`**, so a vault seed that is not a
    //      function of it is ABSENT after an enclave rotation — the successor provisions a fresh
    //      one, the vault node id changes, and **every existing channel's vault half becomes
    //      unusable.** It also bought no security: both seeds sat in one process's memory,
    //      sealed to the same enclave on the same machine.
    //
    // ⇒ Derivation is the honest encoding of a single-custodian deployment, and the knob is gone
    // so nothing can claim otherwise. A REAL second half is a different party on a different
    // host passing its own seed to `boot_vault` — a topology, not a setting (§E175 remainder).
    let vault_seed = quid_bridge::vault::derive_vault_seed(&root_seed);
    let mut vault = quid_bridge::vault::boot_vault(
        network,
        env("QUID_ESPLORA_URL")?,
        &vault_seed,
        data_dir.join("vault"),
        hop_pk,
        vault_port,
        quid_hop::rebalancer::SPLICE_FUNDING_FEERATE_SAT_PER_KW,
        store.clone(), // durable by_funding: reload in-flight opens on restart
        vault_anchor,
    )
    .await
    .context("boot vault node")?;
    // Take the vault's lifecycle stream for the delivery correlator BEFORE sharing the
    // node behind an Arc (the hop mirrors vault opens/closes on the EVM, so the vault's
    // own lifecycle stream is otherwise unconsumed — this is its sole consumer).
    let vault_lifecycle_rx = vault.take_lifecycle_rx();
    let vault = std::sync::Arc::new(vault);
    // (B) Delivery correlator: resolves each swapper-directed delivery SpliceOut's lock
    // to the awaiting `deliver_swap_out`.
    tokio::spawn(quid_bridge::vault::run_vault_delivery_correlator(
        vault_lifecycle_rx,
        vault.deliveries.clone(),
    ));
    tokio::spawn(quid_bridge::vault::run_vault_open_orchestrator(
        vault.clone(),
        hop_pk,
        cfg.min_confirmations as u32,
        env_parse("QUID_VAULT_POLL_SECS", 30u64)?,
    ));

    daemon::run(
        node, cfg, evm, store, start_block, swap_in_listen, swap_in_token,
        vault,
    )
    .await
}

